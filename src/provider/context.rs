use anyhow::{Context, Result, ensure};
use reqwest::{
    Url,
    blocking::{Client, RequestBuilder, Response},
    header::HeaderValue,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::{Mutex, OnceLock};

// Leave enough space for a structured review response even near the end of the window.
const MIN_OUTPUT_TOKENS: u64 = 4_096;
// The chat adapter adds its own instructions and message markers around our text.
const CHAT_FRAMING_TOKENS: u64 = 1_024;

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Limits {
    input_token_limit: u64,
    output_token_limit: u64,
}

pub(super) struct GeminiContext {
    model_url: Url,
    count_url: Url,
    model_id: String,
    api_key: Option<HeaderValue>,
    limits: OnceLock<Limits>,
    last_count: Mutex<Option<([u8; 32], u64)>>,
}

impl GeminiContext {
    pub(super) fn for_endpoint(endpoint: &Url, model: &str, key: &str) -> Result<Option<Self>> {
        if endpoint.origin().ascii_serialization() != "https://generativelanguage.googleapis.com"
            || endpoint.path().trim_end_matches('/') != "/v1beta/openai/chat/completions"
            || !model.starts_with("gemini-")
            || !model
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        {
            return Ok(None);
        }
        let model_id = format!("models/{model}");
        let model_url = endpoint.join(&format!("/v1beta/{model_id}"))?;
        let count_url = endpoint.join(&format!("/v1beta/{model_id}:countTokens"))?;
        let api_key = if key.is_empty() {
            None
        } else {
            let mut header = HeaderValue::from_str(key).context("Invalid provider API key")?;
            header.set_sensitive(true);
            Some(header)
        };
        Ok(Some(Self {
            model_url,
            count_url,
            model_id,
            api_key,
            limits: OnceLock::new(),
            last_count: Mutex::new(None),
        }))
    }

    fn authenticate(&self, request: RequestBuilder) -> RequestBuilder {
        match &self.api_key {
            Some(key) => request.header("x-goog-api-key", key),
            None => request,
        }
    }

    // Metadata and count requests can run before a turn has been dispatched.
    fn query(&self, build: impl Fn() -> RequestBuilder) -> Result<Response> {
        let mut retries = 0;
        loop {
            let result = self
                .authenticate(build())
                .send()
                .map_err(anyhow::Error::from)
                .and_then(super::check_status);
            let retry = result
                .as_ref()
                .err()
                .and_then(|error| error.downcast_ref::<reqwest::Error>())
                .is_some_and(|error| {
                    error.is_connect()
                        || error.is_timeout()
                        || error.status().is_some_and(|s| {
                            s == reqwest::StatusCode::TOO_MANY_REQUESTS || s.is_server_error()
                        })
                });
            if !retry || retries >= 2 {
                return result;
            }
            retries += 1;
            std::thread::sleep(std::time::Duration::from_secs(5 * retries));
        }
    }

    fn limits(&self, client: &Client) -> Result<Limits> {
        if let Some(limits) = self.limits.get() {
            return Ok(*limits);
        }
        let response = self
            .query(|| client.get(self.model_url.clone()))
            .context("Could not read the provider's model limits")?;
        let limits: Limits = response
            .json()
            .context("The provider returned invalid model limits")?;
        ensure!(
            limits.input_token_limit > 1 && limits.output_token_limit > 0,
            "The provider returned empty model limits"
        );
        Ok(*self.limits.get_or_init(|| limits))
    }

    pub(super) fn output_budget(
        &self,
        client: &Client,
        system: &str,
        content: &str,
        format: Option<&Value>,
    ) -> Result<u64> {
        let limits = self.limits(client)?;
        let max_output = limits.output_token_limit.min(limits.input_token_limit - 1);
        let min_output = MIN_OUTPUT_TOKENS
            .min(max_output)
            .min(limits.input_token_limit / 2);
        // countTokens measures the messages. Reserve a conservative byte bound
        // for the separate response schema in both budgeting paths.
        let schema_bytes =
            format.map_or(Ok(0), |f| serde_json::to_vec(f).map(|v| v.len() as u64))?;
        let framing = CHAT_FRAMING_TOKENS.saturating_add(schema_bytes);
        let text_bytes = system.len().saturating_add(content.len()) as u64;
        // UTF-8 bytes bound the text tokens. Use the tokenizer only when that
        // conservative bound would reduce the available context or output.
        if text_bytes
            .saturating_add(framing)
            .saturating_add(max_output)
            <= limits.input_token_limit
        {
            return Ok(max_output);
        }
        let input_tokens = self.count(client, system, content)?;
        let available = limits
            .input_token_limit
            .saturating_sub(input_tokens.saturating_add(framing));
        if available < min_output {
            return Err(crate::ReviewContextExceeded.into());
        }
        Ok(max_output.min(available))
    }

    fn count(&self, client: &Client, system: &str, content: &str) -> Result<u64> {
        let mut hasher = Sha256::new();
        hasher.update(system.len().to_le_bytes());
        hasher.update(system);
        hasher.update(content);
        let digest: [u8; 32] = hasher.finalize().into();
        if let Some((last, tokens)) = *self.last_count.lock().expect("token count cache poisoned")
            && last == digest
        {
            return Ok(tokens);
        }
        let body = json!({"generateContentRequest": {
            "model": self.model_id,
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role":"user", "parts":[{"text":content}]}],
            "generationConfig": {"responseMimeType":"application/json"}
        }});
        let response = self
            .query(|| client.post(self.count_url.clone()).json(&body))
            .context("The provider tokenizer is unavailable")?;
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Count {
            total_tokens: u64,
        }
        let count: Count = response
            .json()
            .context("Invalid token count from the provider")?;
        *self.last_count.lock().expect("token count cache poisoned") =
            Some((digest, count.total_tokens));
        Ok(count.total_tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenizer_requests_stay_at_the_configured_google_origin() {
        let make = |address: &str, model: &str| {
            GeminiContext::for_endpoint(&Url::parse(address).unwrap(), model, "fixture").unwrap()
        };
        let provider = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
        let context = make(provider, "gemini-4-carbon").unwrap();
        assert_eq!(
            context.count_url.as_str(),
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-carbon:countTokens"
        );
        for address in [
            "https://proxy.example/v1beta/openai/chat/completions",
            "https://generativelanguage.googleapis.com:8443/v1beta/openai/chat/completions",
            "https://generativelanguage.googleapis.com/other",
        ] {
            assert!(make(address, "gemini-4-carbon").is_none());
        }
        assert!(make(provider, "gemini-../escape").is_none());
    }

    #[test]
    fn a_large_request_uses_the_actual_count_and_keeps_response_room() {
        let endpoint =
            Url::parse("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
                .unwrap();
        let context = GeminiContext::for_endpoint(&endpoint, "gemini-4-carbon", "")
            .unwrap()
            .unwrap();
        context
            .limits
            .set(Limits {
                input_token_limit: 1_048_576,
                output_token_limit: 32_768,
            })
            .ok()
            .unwrap();
        let system = "Review this code";
        let content = "x".repeat(2_000_000);
        let mut hasher = Sha256::new();
        hasher.update(system.len().to_le_bytes());
        hasher.update(system);
        hasher.update(&content);
        let digest: [u8; 32] = hasher.finalize().into();
        let client = Client::new();
        for (tokens, expected) in [
            (500_000, Some(32_768)),
            (1_032_000, Some(15_552)),
            (1_047_000, None),
        ] {
            *context.last_count.lock().unwrap() = Some((digest, tokens));
            let result = context.output_budget(&client, system, &content, None);
            if let Some(expected) = expected {
                assert_eq!(result.unwrap(), expected);
                if tokens == 1_032_000 {
                    let format = super::super::FinalAnswer::Assessments { leads: true }.format();
                    let size = serde_json::to_vec(&format).unwrap().len() as u64;
                    assert_eq!(
                        context
                            .output_budget(&client, system, &content, Some(&format))
                            .unwrap(),
                        expected - size
                    );
                }
            } else {
                assert!(result.unwrap_err().is::<crate::ReviewContextExceeded>());
            }
        }
    }
}
