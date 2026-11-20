use anyhow::{Context, Result, ensure};
use reqwest::{Url, blocking::Client, redirect::Policy};
use serde_json::{Value, json};
use std::{io::Read, time::Duration};

const MAX_BYTES: usize = 1_000_000;

pub struct Provider {
    client: Client,
    endpoint: Url,
    model: String,
    key: String,
    label: String,
}

impl Provider {
    pub fn new(address: &str, model: &str, key: String) -> Result<Self> {
        let endpoint = Url::parse(address).context("URL del provider non valido")?;
        let host = endpoint.host_str().unwrap_or("");
        ensure!(
            !host.is_empty()
                && endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none(),
            "URL del provider non valido"
        );
        ensure!(
            endpoint.scheme() == "https"
                || (endpoint.scheme() == "http"
                    && matches!(host, "localhost" | "127.0.0.1" | "[::1]")),
            "Il provider remoto richiede HTTPS"
        );
        ensure!(!model.trim().is_empty(), "Specificare il modello");
        let client = Client::builder()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(60))
            .build()?;
        Ok(Self {
            client,
            endpoint,
            model: model.to_owned(),
            key,
            label: format!("{address} ({model})"),
        })
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn ask(&self, system: &str, data: &Value) -> Result<Value> {
        let body = serde_json::to_vec(&json!({
            "model": self.model, "messages": [
                {"role":"system","content":system},
                {"role":"user","content":serde_json::to_string(data)?}],
            "response_format":{"type":"json_object"}
        }))?;
        ensure!(body.len() <= MAX_BYTES, "Richiesta troppo grande");
        let mut request = self
            .client
            .post(self.endpoint.clone())
            .header("Content-Type", "application/json")
            .body(body);
        if !self.key.is_empty() {
            request = request.bearer_auth(&self.key);
        }
        let response = request.send().context("Provider non disponibile")?;
        ensure!(
            response.status().is_success(),
            "Richiesta al provider rifiutata"
        );
        let mut bytes = Vec::new();
        response
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= MAX_BYTES, "Risposta troppo grande");
        decode_reply(&bytes)
    }
}

fn decode_reply(bytes: &[u8]) -> Result<Value> {
    let reply: Value = serde_json::from_slice(bytes)?;
    let first = &reply["choices"][0];
    ensure!(first["finish_reason"] == "stop", "Risposta incompleta");
    let value: Value = serde_json::from_str(
        first["message"]["content"]
            .as_str()
            .context("Testo assente")?,
    )?;
    ensure!(value.is_object(), "Oggetto JSON atteso");
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_remote_plaintext_and_embedded_credentials() {
        for url in [
            "http://example.com/chat",
            "https://key@example.com/chat",
            "https://example.com/chat?token=x",
        ] {
            assert!(Provider::new(url, "test", String::new()).is_err());
        }
    }
    #[test]
    fn rejects_incomplete_or_malformed_model_results() {
        for input in [
            json!({"choices":[]}),
            json!({"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}),
            json!({"choices":[{"finish_reason":"stop","message":{"content":"[]"}}]}),
            json!({"choices":[{"finish_reason":"stop","message":{"content":"{"}}]}),
        ] {
            assert!(decode_reply(&serde_json::to_vec(&input).unwrap()).is_err());
        }
    }

    #[test]
    fn caps_input_before_making_a_request() {
        let p = Provider::new("http://127.0.0.1:1/chat", "test", String::new()).unwrap();
        assert_eq!(
            p.ask("", &json!("x".repeat(MAX_BYTES)))
                .unwrap_err()
                .to_string(),
            "Richiesta troppo grande"
        );
    }
}
