mod context;

use anyhow::{Context, Result, bail, ensure};
use context::GeminiContext;
use reqwest::{
    Url,
    blocking::{Client, Response},
    header::{AUTHORIZATION, HeaderValue},
    redirect::Policy,
};
use serde::{Deserialize, Serialize, Serializer, ser::SerializeMap};
use serde_json::{Value, json};
use std::{io::Read, time::Duration};

const MAX_REPLY_BYTES: usize = 1_000_000;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct TokenUsage {
    pub input: Option<u64>,
    pub output: Option<u64>,
    pub cached: Option<u64>,
}

#[derive(Debug)]
pub struct ModelReply {
    pub value: Value,
    pub usage: TokenUsage,
}

pub struct Provider {
    client: Client,
    endpoint: Url,
    model: String,
    authorization: Option<HeaderValue>,
    context: Option<GeminiContext>,
    label: String,
}

impl Provider {
    pub fn new(address: &str, model: &str, key: String) -> Result<Self> {
        let endpoint = Url::parse(address).context("Invalid provider URL")?;
        let host = endpoint.host_str().unwrap_or("");
        ensure!(
            !host.is_empty()
                && endpoint.username().is_empty()
                && endpoint.password().is_none()
                && endpoint.query().is_none()
                && endpoint.fragment().is_none(),
            "Invalid provider URL"
        );
        ensure!(
            endpoint.scheme() == "https"
                || (endpoint.scheme() == "http"
                    && matches!(host, "localhost" | "127.0.0.1" | "[::1]")),
            "Remote providers require HTTPS"
        );
        let model = model.trim();
        ensure!(!model.is_empty(), "Specify a model");
        let authorization = if key.is_empty() {
            None
        } else {
            let mut value = HeaderValue::from_str(&format!("Bearer {key}"))
                .context("Invalid provider API key")?;
            value.set_sensitive(true);
            Some(value)
        };
        let client = Client::builder()
            .redirect(Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(300))
            .build()?;
        let context = GeminiContext::for_endpoint(&endpoint, model, &key)?;
        Ok(Self {
            client,
            context,
            endpoint,
            model: model.to_owned(),
            authorization,
            label: format!("{address} ({model})"),
        })
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn ask(&self, system: &str, data: &Value) -> Result<Value> {
        self.ask_with_timeout(system, data, Duration::from_secs(300))
    }

    pub fn ask_with_timeout(&self, system: &str, data: &Value, timeout: Duration) -> Result<Value> {
        Ok(self.ask_metered(system, data, timeout)?.value)
    }

    /// Check the same serialized user message that the chat adapter will receive.
    /// Generic chat endpoints can report a context overflow on the request itself.
    pub fn fits_context(&self, system: &str, data: &Value) -> Result<bool> {
        let Some(context) = &self.context else {
            return Ok(true);
        };
        match context.output_budget(&self.client, system, &user_content(data)?) {
            Ok(_) => Ok(true),
            Err(error) if error.is::<crate::ReviewContextExceeded>() => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn ask_metered(&self, system: &str, data: &Value, timeout: Duration) -> Result<ModelReply> {
        ensure!(
            !timeout.is_zero(),
            "The review exhausted its model time budget"
        );
        let content = user_content(data)?;
        let mut body = json!({
            "model": self.model, "messages": [
                {"role":"system","content":system},
                {"role":"user","content":content}],
            "response_format":{"type":"json_object"}
        });
        if let Some(context) = &self.context {
            body["max_tokens"] = context
                .output_budget(&self.client, system, &content)?
                .into();
        }
        let mut request = self
            .client
            .post(self.endpoint.clone())
            .timeout(timeout)
            .json(&body);
        if let Some(authorization) = &self.authorization {
            request = request.header(AUTHORIZATION, authorization.clone());
        }
        let response = request.send().context("Provider is unavailable")?;
        let response = check_status(response)?;
        let mut bytes = Vec::new();
        response
            .take(MAX_REPLY_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_REPLY_BYTES,
            "Provider response exceeds the size limit"
        );
        decode_reply(&bytes)
    }
}

// Implicit provider caching matches prompt prefixes. Keep the pinned diff ahead
// of appended tool results and the status that is replaced on each read.
fn user_content(data: &Value) -> Result<String> {
    if data["snapshot"]["files"].is_array() && data["snapshot"]["head_context"].is_array() {
        let fields = ReviewFields {
            object: data.as_object().context("Invalid review input")?,
            trailing: &["snapshot", "last_read"],
        };
        Ok(serde_json::to_string(&fields)?)
    } else {
        Ok(serde_json::to_string(data)?)
    }
}

struct ReviewFields<'a> {
    object: &'a serde_json::Map<String, Value>,
    trailing: &'static [&'static str],
}

impl Serialize for ReviewFields<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.object.len()))?;
        for (key, value) in self.object {
            if !self.trailing.contains(&key.as_str()) {
                map.serialize_entry(key, value)?;
            }
        }
        for &key in self.trailing {
            let Some(value) = self.object.get(key) else {
                continue;
            };
            if key == "snapshot"
                && let Some(object) = value.as_object()
            {
                map.serialize_entry(
                    key,
                    &ReviewFields {
                        object,
                        trailing: &["head_context", "complete_head_paths"],
                    },
                )?;
            } else {
                map.serialize_entry(key, value)?;
            }
        }
        map.end()
    }
}

fn check_status(response: Response) -> Result<Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        return response.error_for_status().map_err(Into::into);
    }
    if status == reqwest::StatusCode::PAYLOAD_TOO_LARGE {
        return Err(crate::ReviewContextExceeded.into());
    }
    if matches!(status.as_u16(), 400 | 422) {
        // Provider errors may quote private input. Classify them without logging the body.
        let error: Value = serde_json::from_reader(response.take(32_768)).unwrap_or_default();
        let error = &error["error"];
        let message = error["message"]
            .as_str()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if error["code"] == "context_length_exceeded"
            || message.contains("maximum context length")
            || message.contains("context window")
                && (message.contains("exceed") || message.contains("too long"))
            || message.contains("input token count") && message.contains("exceed")
        {
            return Err(crate::ReviewContextExceeded.into());
        }
    }
    bail!("The provider rejected the request (HTTP {status})")
}

#[derive(Debug)]
pub struct InvalidReply {
    pub reason: &'static str,
    pub usage: TokenUsage,
    diagnostics: Option<ReplyDiagnostics>,
}

impl std::fmt::Display for InvalidReply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.reason)?;
        if let Some(d) = &self.diagnostics {
            write!(
                f,
                " (choices={:?}, finish={}, native_finish={}, block={}, error_code={}, error_status={}, output_tokens={:?})",
                d.choices,
                d.finish,
                d.native_finish,
                d.block,
                d.error_code,
                d.error_status,
                self.usage.output
            )?;
        }
        Ok(())
    }
}
impl std::error::Error for InvalidReply {}

// Persist only fixed protocol labels and counts. Provider fields and error
// messages can contain user input, so an unknown label must never be echoed.
#[derive(Clone, Copy, Debug)]
struct ReplyDiagnostics {
    choices: Option<usize>,
    finish: &'static str,
    native_finish: &'static str,
    block: &'static str,
    error_code: &'static str,
    error_status: &'static str,
}

fn label(value: &Value, names: &[&'static str]) -> &'static str {
    match value {
        Value::Null => "absent",
        Value::String(s) => names
            .iter()
            .copied()
            .find(|name| name.eq_ignore_ascii_case(s))
            .unwrap_or("unrecognized"),
        _ => "unrecognized",
    }
}

const FINISH: &[&str] = &[
    "stop",
    "length",
    "max_tokens",
    "content_filter",
    "safety",
    "recitation",
    "language",
    "blocklist",
    "prohibited_content",
    "spii",
    "image_safety",
    "image_prohibited_content",
    "image_recitation",
    "other",
    "image_other",
    "no_image",
    "tool_calls",
    "function_call",
    "malformed_function_call",
    "unexpected_tool_call",
    "too_many_tool_calls",
    "missing_thought_signature",
    "malformed_response",
    "error",
    "finish_reason_unspecified",
];

fn restricted(reason: &str) -> bool {
    matches!(
        reason,
        "content_filter"
            | "safety"
            | "recitation"
            | "language"
            | "blocklist"
            | "prohibited_content"
            | "spii"
            | "image_safety"
            | "image_prohibited_content"
            | "image_recitation"
    )
}

fn first_present<const N: usize>(values: [&Value; N]) -> &Value {
    values
        .into_iter()
        .find(|v| !v.is_null())
        .unwrap_or(&Value::Null)
}

fn decode_reply(bytes: &[u8]) -> Result<ModelReply> {
    let reply: Value = serde_json::from_slice(bytes).map_err(|error| {
        let issue = InvalidReply {
            reason: "Provider returned incomplete JSON.",
            usage: TokenUsage::default(),
            diagnostics: None,
        };
        if error.is_eof() {
            anyhow::Error::new(crate::ReviewBatchInterrupted).context(issue)
        } else {
            anyhow::Error::new(issue)
        }
    })?;
    let first = &reply["choices"][0];
    let candidate = &reply["candidates"][0];
    let message = &first["message"];
    let error = first_present([&reply["error"], &first["error"]]);
    let feedback = first_present([&reply["promptFeedback"], &reply["prompt_feedback"]]);
    let code = &error["code"];
    let status_names = &[
        "cancelled",
        "unknown",
        "invalid_argument",
        "deadline_exceeded",
        "not_found",
        "already_exists",
        "permission_denied",
        "resource_exhausted",
        "failed_precondition",
        "aborted",
        "out_of_range",
        "unimplemented",
        "internal",
        "unavailable",
        "data_loss",
        "unauthenticated",
        "content_filter",
        "content_policy_violation",
        "rate_limit_exceeded",
        "context_length_exceeded",
        "server_error",
    ];
    let d = ReplyDiagnostics {
        choices: reply["choices"].as_array().map(Vec::len),
        finish: label(&first["finish_reason"], FINISH),
        native_finish: label(
            first_present([
                &candidate["finishReason"],
                &candidate["finish_reason"],
                &first["native_finish_reason"],
            ]),
            FINISH,
        ),
        block: label(
            first_present([&feedback["blockReason"], &feedback["block_reason"]]),
            &[
                "block_reason_unspecified",
                "safety",
                "other",
                "blocklist",
                "prohibited_content",
                "image_safety",
                "model_armor",
            ],
        ),
        error_code: match code.as_u64() {
            Some(400) => "400",
            Some(401) => "401",
            Some(403) => "403",
            Some(404) => "404",
            Some(408) => "408",
            Some(413) => "413",
            Some(422) => "422",
            Some(429) => "429",
            Some(500) => "500",
            Some(502) => "502",
            Some(503) => "503",
            Some(504) => "504",
            _ => label(code, status_names),
        },
        error_status: label(&error["status"], status_names),
    };
    let usage = &reply["usage"];
    let usage = TokenUsage {
        input: usage["prompt_tokens"].as_u64(),
        output: usage["completion_tokens"].as_u64(),
        cached: usage["prompt_tokens_details"]["cached_tokens"].as_u64(),
    };
    let issue = |reason| InvalidReply {
        reason,
        usage,
        diagnostics: Some(d),
    };
    let interrupted =
        |reason| anyhow::Error::new(crate::ReviewBatchInterrupted).context(issue(reason));
    let flagged = [&feedback["safetyRatings"], &candidate["safetyRatings"]]
        .into_iter()
        .filter_map(Value::as_array)
        .flatten()
        .any(|rating| rating["blocked"] == true);
    let refused = message["refusal"].as_str().is_some_and(|s| !s.is_empty())
        || message["content"]
            .as_array()
            .is_some_and(|parts| parts.iter().any(|p| p["type"] == "refusal"));
    if restricted(d.finish)
        || restricted(d.native_finish)
        || !matches!(d.block, "absent" | "block_reason_unspecified")
        || flagged
        || refused
    {
        return Err(issue("Provider withheld the reply.").into());
    }
    if !error.is_null() {
        return Err(issue("Provider reported an error in its reply.").into());
    }
    if [d.finish, d.native_finish]
        .iter()
        .any(|reason| matches!(*reason, "length" | "max_tokens"))
    {
        return Err(anyhow::Error::new(crate::ReviewContextExceeded)
            .context(issue("Provider reached the output token limit.")));
    }
    let text = message["content"].as_str();
    let empty_content = message["content"].is_null() || text.is_some_and(|s| s.trim().is_empty());
    let no_tool_call = !message["tool_calls"]
        .as_array()
        .is_some_and(|calls| !calls.is_empty())
        && message["function_call"].is_null();
    // Positive evidence of an empty chat completion. Unknown finish reasons and
    // native/foreign payloads are never reinterpreted as a transient stop.
    if d.choices.is_some()
        && empty_content
        && no_tool_call
        && [d.finish, d.native_finish]
            .iter()
            .all(|reason| matches!(*reason, "stop" | "absent"))
        && (d.finish == "stop" || usage.output == Some(0))
    {
        return Err(interrupted("Provider returned an empty model completion."));
    }
    if d.finish != "stop" || !matches!(d.native_finish, "absent" | "stop") {
        return Err(issue("Provider stopped before completing its reply.").into());
    }
    let text = text.ok_or_else(|| issue("Provider response is missing text."))?;
    let value: Value = serde_json::from_str(text).map_err(|error| {
        if error.is_eof() {
            interrupted("Provider returned truncated review JSON.")
        } else {
            anyhow::Error::new(issue("Provider returned invalid review JSON."))
        }
    })?;
    ensure!(
        value.is_object(),
        issue("Provider returned an unexpected review format.")
    );
    Ok(ModelReply { value, usage })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        env,
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        process::Command,
        thread,
        time::Instant,
    };

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
    fn rejects_malformed_api_key_at_startup_without_disclosing_it() {
        for suffix in ["\r", "\n", "\r\n", "\0"] {
            let result = Provider::new(
                "https://example.com/chat",
                "test",
                format!("synthetic-secret{suffix}"),
            );
            let error = result.err().expect("Expected an invalid API key");
            assert!(error.to_string().contains("API key"));
            assert!(!format!("{error:#}").contains("synthetic-secret"));
        }
    }

    #[test]
    fn review_requests_respect_the_remaining_time_budget() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/chat", listener.local_addr().unwrap());
        let provider = Provider::new(&endpoint, "fixture", String::new()).unwrap();
        let exhausted = provider
            .ask_with_timeout("", &json!({}), Duration::ZERO)
            .unwrap_err();
        assert!(exhausted.to_string().contains("exhausted"));
        // The listening socket accepts a TCP handshake but sends no HTTP response.
        let error = provider
            .ask_with_timeout("", &json!({}), Duration::from_millis(100))
            .unwrap_err();
        assert!(
            error
                .downcast_ref::<reqwest::Error>()
                .is_some_and(reqwest::Error::is_timeout)
        );
    }

    #[test]
    fn uses_trimmed_model_name() {
        let provider = Provider::new(
            "https://example.com/chat",
            "  fixture-model\t",
            String::new(),
        )
        .unwrap();
        assert_eq!(provider.label(), "https://example.com/chat (fixture-model)");
        assert_eq!(provider.model, "fixture-model");
        assert!(provider.authorization.is_none());
        assert!(Provider::new("https://example.com/chat", " \t ", String::new()).is_err());
    }

    #[test]
    fn bypasses_ambient_proxy_for_local_provider() {
        const CHILD_PORT: &str = "JIDOKA_TEST_DIRECT_PROVIDER_PORT";
        if let Ok(port) = env::var(CHILD_PORT) {
            let port: u16 = port.parse().unwrap();
            let endpoint = format!("http://127.0.0.1:{port}/chat");
            let provider = Provider::new(&endpoint, "  test  ", "fixture-token".into()).unwrap();
            assert_eq!(
                provider
                    .ask("instruction", &json!({"diff": "x".repeat(1_200_000)}))
                    .unwrap(),
                json!({})
            );
            return;
        }

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let origin = format!("http://{address}");
        let mut child = Command::new(env::current_exe().unwrap())
            .args([
                "--exact",
                "provider::tests::bypasses_ambient_proxy_for_local_provider",
            ])
            .env_clear()
            .env(CHILD_PORT, address.port().to_string())
            .env("HTTP_PROXY", &origin)
            .env("HTTPS_PROXY", &origin)
            .env("ALL_PROXY", &origin)
            .spawn()
            .unwrap();

        // One listener acts as both destinations. A proxy request uses the absolute URL.
        let timeout = Duration::from_secs(5);
        let deadline = Instant::now() + timeout;
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline || child.try_wait().unwrap().is_some() {
                        let _ = child.kill();
                        let _ = child.wait();
                        panic!("Synthetic provider did not receive a request");
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("Synthetic provider accept failed: {error}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream.set_read_timeout(Some(timeout)).unwrap();
        let mut reader = BufReader::new(&mut stream);
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        let mut length = 0;
        let mut authorized = false;
        for line in reader.by_ref().lines() {
            let line = line.unwrap();
            if line.is_empty() {
                break;
            }
            let (name, value) = line.split_once(':').unwrap();
            if name.eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().unwrap();
            } else if name.eq_ignore_ascii_case("authorization") {
                authorized = value.trim() == "Bearer fixture-token";
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        let response = r#"{"choices":[{"finish_reason":"stop","message":{"content":"{}"}}]}"#;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",
            response.len()
        )
        .unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(request, "POST /chat HTTP/1.1\r\n");
        assert!(authorized);
        let body: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(body["model"], "test");
        let user: Value =
            serde_json::from_str(body["messages"][1]["content"].as_str().unwrap()).unwrap();
        assert_eq!(user["diff"].as_str().unwrap().len(), 1_200_000);
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
    fn exhausted_output_is_partitioned_and_counts_actual_usage() {
        let result=decode_reply(br#"{"choices":[{"finish_reason":"length"}],"usage":{"prompt_tokens":18000,"completion_tokens":4096}}"#).unwrap_err();
        assert!(result.is::<crate::ReviewContextExceeded>());
        let failure = result.downcast_ref::<InvalidReply>().unwrap();
        assert_eq!(failure.usage.output, Some(4096));
    }

    #[test]
    fn empty_and_truncated_completions_can_be_recovered_without_losing_usage() {
        let cases = [
            json!({"choices":[],"usage":{"completion_tokens":0}}),
            json!({"choices":[{"finish_reason":null,"message":{"content":null}}],"usage":{"completion_tokens":0}}),
            json!({"choices":[{"finish_reason":"stop","message":{"content":" "}}]}),
            json!({"choices":[{"finish_reason":"stop","message":{"content":"{\"hypotheses\":"}}]}),
        ];
        for case in cases {
            let error = decode_reply(&serde_json::to_vec(&case).unwrap()).unwrap_err();
            assert!(error.is::<crate::ReviewBatchInterrupted>());
            let reply = error.downcast_ref::<InvalidReply>().unwrap();
            assert_eq!(
                reply.usage.output,
                case["usage"]["completion_tokens"].as_u64()
            );
            assert!(reply.to_string().contains("choices="));
        }
        assert!(
            decode_reply(b"{\"choices\":")
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
    }

    #[test]
    fn policy_signals_and_unclassified_stops_are_never_rebatched() {
        let cases = [
            json!({"choices": [{"finish_reason": "content_filter"}]}),
            json!({"choices":[{"finish_reason":"stop","message":{"refusal":"private-provider-text"}}]}),
            json!({"choices":[{"finish_reason":null,"native_finish_reason":"SPII"}],"usage":{"completion_tokens":0}}),
            json!({"choices":[],"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"},"usage":{"completion_tokens":0}}),
            json!({"choices":[],"candidates":[{"finishReason":"RECITATION"}],"usage":{"completion_tokens":0}}),
            json!({"choices":[],"candidates":[{"safetyRatings":[{"blocked":true}]}],"usage":{"completion_tokens":0}}),
            json!({"choices":[],"error":{"code":403,"status":"PERMISSION_DENIED"},"usage":{"completion_tokens":0}}),
            json!({"choices":[{"finish_reason":"private-provider-text"}],"usage":{"completion_tokens":0}}),
            json!({"choices":[{"finish_reason":"stop","message":{"tool_calls":[{"id":"1"}]}}],"usage":{"completion_tokens":0}}),
            json!({"choices":[],"usage":{"prompt_tokens":2048}}),
            json!({"choices":[{"finish_reason":"error","error":{"code":"private-provider-text"}}],"usage":{"completion_tokens":0}}),
        ];
        for case in cases {
            let error = decode_reply(&serde_json::to_vec(&case).unwrap()).unwrap_err();
            assert!(
                !error.is::<crate::ReviewBatchInterrupted>()
                    && !error.is::<crate::ReviewContextExceeded>()
            );
            let failure = error.downcast_ref::<InvalidReply>().unwrap();
            assert_ne!(failure.reason, "Provider returned invalid review JSON.");
            assert!(!failure.to_string().contains("private-provider-text"));
        }
    }

    #[test]
    fn generic_provider_offers_the_whole_request_to_its_model() {
        let provider = Provider::new("http://127.0.0.1:1/chat", "test", String::new()).unwrap();
        assert!(
            provider
                .fits_context("review", &json!("x".repeat(2_000_000)))
                .unwrap()
        );
    }

    #[test]
    fn reports_token_usage_without_inventing_provider_counts() {
        let mut response = json!({"choices":[{"finish_reason":"stop","message":{"content":"{}"}}]});
        assert_eq!(
            decode_reply(&serde_json::to_vec(&response).unwrap())
                .unwrap()
                .usage,
            TokenUsage::default()
        );
        response["usage"] = json!({"prompt_tokens":512,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":256}});
        assert_eq!(
            decode_reply(&serde_json::to_vec(&response).unwrap())
                .unwrap()
                .usage,
            TokenUsage {
                input: Some(512),
                output: Some(20),
                cached: Some(256),
            }
        );
    }

    #[test]
    fn successive_tool_turns_keep_the_full_diff_in_the_common_prefix() {
        let patch = "function sample() {}\n".repeat(10_000);
        let mut data = json!({
            "snapshot":{"files":[{"patch":patch}], "complete_head_paths":["old"], "head_context":[{"line":1}],"head":"abc"},
            "scan":{"ran":true}, "last_read":{"term":"a"},
        });
        let start = user_content(&data).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&start).unwrap(), data);
        data["snapshot"]["head_context"]
            .as_array_mut()
            .unwrap()
            .push(json!({"line":2}));
        data["last_read"]["term"] = json!("other");
        data["snapshot"]["complete_head_paths"] = json!(["new", "old"]);
        let next = user_content(&data).unwrap();
        let shared = start
            .bytes()
            .zip(next.bytes())
            .take_while(|(a, b)| a == b)
            .count();
        assert!(shared > patch.len());
        assert_eq!(serde_json::from_str::<Value>(&next).unwrap(), data);
        for other in [
            json!({"last_read":"first","snapshot":{"unknown":true}}),
            json!(42),
        ] {
            assert_eq!(
                user_content(&other).unwrap(),
                serde_json::to_string(&other).unwrap()
            );
        }
    }
}
