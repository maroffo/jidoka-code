mod context;
mod shape;

use shape::AnswerShape;

use anyhow::{Context, Result, bail, ensure};
use context::GeminiContext;
use reqwest::{
    Url,
    blocking::{Client, RequestBuilder, Response},
    header::{AUTHORIZATION, HeaderValue},
    redirect::Policy,
};
use serde::{Deserialize, Serialize, Serializer, ser::SerializeMap};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Read},
    time::{Duration, Instant},
};

const MAX_REPLY_BYTES: usize = 1_000_000;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

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
            .connect_timeout(CONNECT_TIMEOUT)
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
        let format = AnswerShape::from_input(data).map(|shape| shape.format(data));
        match context.output_budget(&self.client, system, &user_content(data)?, format.as_ref()) {
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
        let answer_shape = self
            .context
            .as_ref()
            .and_then(|_| AnswerShape::from_input(data));
        if let Some(context) = &self.context {
            let format = answer_shape.map(|shape| shape.format(data));
            let max_tokens =
                context.output_budget(&self.client, system, &content, format.as_ref())?;
            if let Some(format) = format {
                body["response_format"] = format;
            }
            // Jidoka reads a pinned repository itself; Gemini returns only JSON text.
            body["tool_choice"] = "none".into();
            body["stream"] = true.into();
            body["stream_options"] = json!({"include_usage":true});
            body["max_tokens"] = max_tokens.into();
        }
        let mut request = self
            .client
            .post(self.endpoint.clone())
            .timeout(timeout)
            .json(&body);
        if self.context.is_some() {
            request = request.header(reqwest::header::ACCEPT, "text/event-stream");
        }
        if let Some(authorization) = &self.authorization {
            request = request.header(AUTHORIZATION, authorization.clone());
        }
        // A short caller-supplied deadline can expire during connection setup.
        let generation_deadline =
            (self.context.is_some() && timeout > CONNECT_TIMEOUT).then_some(timeout);
        let response = send_generation(request, generation_deadline)?;
        let response = check_status(response)?;
        // A gateway may return an ordinary JSON error envelope even for a streaming request.
        let is_json = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(';').next())
            .is_some_and(|s| s.trim().eq_ignore_ascii_case("application/json"));
        if self.context.is_some() && !is_json {
            return decode_stream(response, answer_shape);
        }
        let mut bytes = Vec::new();
        response
            .take(MAX_REPLY_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_REPLY_BYTES,
            "Provider response exceeds the size limit"
        );
        decode_reply(&bytes, answer_shape)
    }
}

fn send_generation(
    request: RequestBuilder,
    generation_deadline: Option<Duration>,
) -> Result<Response> {
    let started = Instant::now();
    match request.send() {
        Err(error)
            if error.is_timeout()
                && !error.is_connect()
                && generation_deadline.is_some_and(|deadline| started.elapsed() >= deadline) =>
        {
            // No response headers arrived. Retrying the identical generation
            // at the same deadline may use an entire additional model turn.
            Err(
                anyhow::Error::new(crate::ReviewBatchInterrupted).context(InvalidReply {
                    reason: "Provider generation timed out before response headers.",
                    usage: TokenUsage::default(),
                    diagnostics: None,
                }),
            )
        }
        result => result.context("Provider is unavailable"),
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

#[derive(Debug)]
pub struct RateLimited {
    pub retry_after: Option<Duration>,
    resource_exhausted: bool,
}

impl std::fmt::Display for RateLimited {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Provider HTTP 429 Too Many Requests")?;
        if self.resource_exhausted {
            f.write_str(" (RESOURCE_EXHAUSTED)")?;
        }
        if let Some(delay) = self.retry_after {
            write!(f, ". Retry after {} seconds", delay.as_secs_f64())?;
        }
        f.write_str(".")
    }
}
impl std::error::Error for RateLimited {}

impl RateLimited {
    fn from_response(header: Option<&str>, body: &Value, now: std::time::SystemTime) -> Self {
        let error = &body
            .as_array()
            .and_then(|list| list.first())
            .unwrap_or(body)["error"];
        let header = header.and_then(|s| {
            s.trim()
                .parse::<u64>()
                .ok()
                .map(Duration::from_secs)
                .or_else(|| {
                    httpdate::parse_http_date(s)
                        .ok()
                        .map(|time| time.duration_since(now).unwrap_or_default())
                })
        });
        let body_delay = error["details"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|detail| detail["@type"] == "type.googleapis.com/google.rpc.RetryInfo")
            .filter_map(|detail| {
                let seconds = detail["retryDelay"].as_str()?.strip_suffix('s')?;
                if !seconds.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
                    return None;
                }
                Duration::try_from_secs_f64(seconds.parse().ok()?).ok()
            })
            .max();
        Self {
            retry_after: header.max(body_delay),
            resource_exhausted: error["status"] == "RESOURCE_EXHAUSTED",
        }
    }

    pub fn new(retry_after: Option<Duration>) -> Self {
        Self {
            retry_after,
            resource_exhausted: false,
        }
    }
}

fn check_status(response: Response) -> Result<Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        let header = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let body = serde_json::from_reader(response.take(32_768)).unwrap_or_default();
        return Err(RateLimited::from_response(
            header.as_deref(),
            &body,
            std::time::SystemTime::now(),
        )
        .into());
    }
    if status.is_server_error() {
        return response.error_for_status().map_err(Into::into);
    }
    if status == reqwest::StatusCode::PAYLOAD_TOO_LARGE {
        return Err(crate::ReviewContextExceeded.into());
    }
    if matches!(status.as_u16(), 400 | 422) {
        // Provider errors may quote private input. Classify them without logging the body.
        let error: Value = serde_json::from_reader(response.take(32_768)).unwrap_or_default();
        if context_overflow(&error) {
            return Err(crate::ReviewContextExceeded.into());
        }
    }
    bail!("The provider rejected the request (HTTP {status})")
}

fn context_overflow(body: &Value) -> bool {
    // vLLM can return a flat ErrorResponse. Other chat adapters nest the same
    // fields under "error". A policy refusal takes precedence over its message.
    let error = body.get("error").filter(|e| e.is_object()).unwrap_or(body);
    let fields = [error["code"].as_str(), error["type"].as_str()];
    if fields.iter().flatten().any(|code| {
        matches!(
            *code,
            "content_filter" | "content_policy_violation" | "safety" | "refusal"
        )
    }) {
        return false;
    }
    if fields.iter().flatten().any(|code| {
        matches!(
            *code,
            "context_length_exceeded" | "exceed_context_size_error"
        )
    }) {
        return true;
    }
    let message = error["message"]
        .as_str()
        .unwrap_or_default()
        .to_ascii_lowercase();
    (message.contains("maximum context length")
        && (message.contains("requested")
            || message.contains("exceed")
            || message.contains("reduce the length of the input")))
        || (message.contains("context window")
            && (message.contains("exceed") || message.contains("too long")))
        || (message.contains("input token count") && message.contains("exceed"))
        || message.contains("exceeds the available context size")
        || (message.contains("prompt is too long")
            && message.contains("tokens >")
            && message.contains("maximum"))
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

// Google can append a provider-specific explanation to a Chat Completions
// finish reason. Persist only exact protocol labels, never the explanation.
fn finish_label(value: &Value) -> &'static str {
    let known = label(value, FINISH);
    if known != "unrecognized" {
        return known;
    }
    let Some(text) = value.as_str() else {
        return "unrecognized_non_string";
    };
    let text = text.to_ascii_lowercase();
    if text == "function_call_filter: malformed_function_call" {
        return "malformed_function_call";
    }
    if text
        .split_once(':')
        .is_some_and(|(prefix, _)| prefix.trim() == "content_filter")
    {
        return "content_filter";
    }
    let words = text.split(|c: char| !c.is_ascii_alphanumeric() && c != '_');
    if words.clone().any(|w| {
        restricted(w)
            || [
                "policy",
                "blocked",
                "refusal",
                "model_armor",
                "content_policy_violation",
            ]
            .contains(&w)
    }) {
        return "unrecognized_policy_marker";
    }
    if words.into_iter().any(|w| {
        [
            "deadline_exceeded",
            "resource_exhausted",
            "model_timeout",
            "timeout",
            "deadline",
            "unavailable",
            "internal",
        ]
        .contains(&w)
    }) {
        return "unrecognized_technical_marker";
    }
    known
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
    "escalation",
    "pup_limited_disabled",
    "continuation",
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
            | "escalation"
            | "pup_limited_disabled"
    )
}

fn first_present<const N: usize>(values: [&Value; N]) -> &Value {
    values
        .into_iter()
        .find(|v| !v.is_null())
        .unwrap_or(&Value::Null)
}

fn decode_stream(reader: impl Read, answer_shape: Option<AnswerShape>) -> Result<ModelReply> {
    // SSE adds a JSON envelope to each output chunk. Bound both transport overhead
    // and reassembled model text, including the case of one unterminated long line.
    const MAX_STREAM_BYTES: usize = 16 * MAX_REPLY_BYTES;
    let mut reader = BufReader::new(reader.take(MAX_STREAM_BYTES as u64 + 1));
    let mut reply = json!({"choices":[]});
    let mut text = String::new();
    let mut line = Vec::new();
    let mut event = Vec::new();
    let mut wire_bytes = 0;
    let mut error_event = false;
    let mut terminal = false;
    let done = loop {
        line.clear();
        let read = match reader.read_until(b'\n', &mut line) {
            Ok(read) => read,
            Err(_) => break false,
        };
        wire_bytes += read;
        ensure!(
            wire_bytes <= MAX_STREAM_BYTES,
            "Provider stream exceeds the size limit"
        );
        if line.last() == Some(&b'\n') {
            line.pop();
        }
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        if let Some(kind) = line.strip_prefix(b"event:") {
            error_event = kind.trim_ascii() == b"error";
            if error_event && reply["error"].is_null() {
                // Keep the explicit error terminal even if its final data frame is cut off.
                reply["error"] = json!({});
            }
            continue;
        }
        if let Some(data) = line.strip_prefix(b"data:") {
            if !event.is_empty() {
                event.push(b'\n');
            }
            event.extend_from_slice(data.strip_prefix(b" ").unwrap_or(data));
            continue;
        }
        // A blank line dispatches an SSE event. Comments and other SSE fields
        // do not contribute to model content.
        if !line.is_empty() {
            continue;
        }
        if !event.is_empty() {
            if event.trim_ascii() == b"[DONE]" {
                break true;
            }
            let Ok(frame) = serde_json::from_slice::<Value>(&event) else {
                break false;
            };
            if !frame["usage"].is_null() {
                reply["usage"] = frame["usage"].clone();
            }
            if !terminal {
                if error_event || frame["type"] == "error" {
                    reply["error"] = if frame["error"].is_null() {
                        frame.clone()
                    } else {
                        frame["error"].clone()
                    };
                }
                append_chunk(&mut reply, &mut text, &frame)?;
                terminal = !reply["error"].is_null()
                    || !reply["choices"][0]["error"].is_null()
                    || ReplyDiagnostics::read(&reply).withheld(&reply);
            }
            event.clear();
        }
        error_event = false;
        if read == 0 {
            break false;
        }
    };
    if !reply["choices"][0].is_null() {
        reply["choices"][0]["message"]["content"] = text.into();
    }
    decode_message(&reply, Some(done), answer_shape)
}

fn append_chunk(reply: &mut Value, text: &mut String, frame: &Value) -> Result<()> {
    for field in ["error", "promptFeedback", "prompt_feedback", "candidates"] {
        if !frame[field].is_null() {
            reply[field] = frame[field].clone();
        }
    }
    let Some(choice) = frame["choices"].as_array().and_then(|choices| {
        choices
            .iter()
            .find(|choice| choice["index"].as_u64().unwrap_or(0) == 0)
    }) else {
        return Ok(());
    };
    if reply["choices"][0].is_null() {
        reply["choices"] = json!([{"message":{}}]);
    }
    let collected = &mut reply["choices"][0];
    for field in ["finish_reason", "native_finish_reason", "error"] {
        if !choice[field].is_null() {
            collected[field] = choice[field].clone();
        }
    }
    let delta = &choice["delta"];
    if let Some(part) = delta["content"].as_str() {
        ensure!(
            part.len() <= MAX_REPLY_BYTES.saturating_sub(text.len()),
            "Provider response exceeds the size limit"
        );
        text.push_str(part);
    }
    if delta["refusal"].as_str().is_some_and(|s| !s.is_empty())
        || delta["content"]
            .as_array()
            .is_some_and(|parts| parts.iter().any(|p| p["type"] == "refusal"))
    {
        collected["message"]["refusal"] = json!("refused");
    }
    if !delta["tool_calls"].is_null() && !delta["tool_calls"].as_array().is_some_and(Vec::is_empty)
    {
        collected["message"]["tool_calls"] = json!([{}]);
    }
    if !delta["function_call"].is_null() {
        collected["message"]["function_call"] = json!({});
    }
    Ok(())
}

fn decode_reply(bytes: &[u8], answer_shape: Option<AnswerShape>) -> Result<ModelReply> {
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
    decode_message(&reply, None, answer_shape)
}

impl ReplyDiagnostics {
    fn read(reply: &Value) -> Self {
        let first = &reply["choices"][0];
        let candidate = &reply["candidates"][0];
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
        Self {
            choices: reply["choices"].as_array().map(Vec::len),
            finish: finish_label(&first["finish_reason"]),
            native_finish: finish_label(first_present([
                &candidate["finishReason"],
                &candidate["finish_reason"],
                &first["native_finish_reason"],
            ])),
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
        }
    }

    fn withheld(&self, reply: &Value) -> bool {
        let first = &reply["choices"][0];
        let message = &first["message"];
        let candidate = &reply["candidates"][0];
        let feedback = first_present([&reply["promptFeedback"], &reply["prompt_feedback"]]);
        let flagged = [
            &feedback["safetyRatings"],
            &candidate["safetyRatings"],
            &feedback["safety_ratings"],
            &candidate["safety_ratings"],
        ]
        .into_iter()
        .filter_map(Value::as_array)
        .flatten()
        .any(|rating| rating["blocked"] == true);
        let refused = message["refusal"].as_str().is_some_and(|s| !s.is_empty())
            || message["content"]
                .as_array()
                .is_some_and(|parts| parts.iter().any(|p| p["type"] == "refusal"));
        restricted(self.finish)
            || restricted(self.native_finish)
            || !matches!(self.block, "absent" | "block_reason_unspecified")
            || flagged
            || refused
    }
}

fn read_hint(text: &str) -> Option<Value> {
    // Deserialize to structs first so duplicate fields are rejected as well.
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Hint {
        read: crate::contracts::ContextRead,
    }
    let hint: Hint = serde_json::from_str(text).ok()?;
    let value = json!({"read": hint.read});
    crate::engine::read_request(&value)
        .ok()
        .flatten()
        .map(|_| value)
}

fn decode_message(
    reply: &Value,
    stream_done: Option<bool>,
    answer_shape: Option<AnswerShape>,
) -> Result<ModelReply> {
    let first = &reply["choices"][0];
    let message = &first["message"];
    let d = ReplyDiagnostics::read(reply);
    let usage = &reply["usage"];
    let reasoning_tokens = usage["completion_tokens_details"]["reasoning_tokens"].as_u64();
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
    if d.withheld(reply) {
        return Err(issue("Provider withheld the reply.").into());
    }
    if !reply["error"].is_null() || !first["error"].is_null() {
        return Err(issue("Provider reported an error in its reply.").into());
    }
    if [d.finish, d.native_finish]
        .iter()
        .any(|reason| matches!(*reason, "length" | "max_tokens"))
    {
        return Err(anyhow::Error::new(crate::ReviewContextExceeded)
            .context(issue("Provider reached the output token limit.")));
    }
    if stream_done.is_some_and(|done| !done || d.finish == "absent")
        && [d.finish, d.native_finish]
            .iter()
            .all(|reason| matches!(*reason, "stop" | "absent"))
    {
        return Err(interrupted(
            "Provider stream ended before completing its reply.",
        ));
    }
    let text = message["content"].as_str();
    let empty_content = message["content"].is_null() || text.is_some_and(|s| s.trim().is_empty());
    let no_tool_call = !message["tool_calls"]
        .as_array()
        .is_some_and(|calls| !calls.is_empty())
        && message["function_call"].is_null();
    let reasoning_only = usage
        .output
        .is_some_and(|total| total > 0 && Some(total) == reasoning_tokens);
    // Google may reject a native function call while also sending separate
    // JSON text. A complete read-only hint can be revalidated by the engine.
    // Findings and all native calls stay unusable on this stop.
    if stream_done.is_some()
        && d.finish == "malformed_function_call"
        && matches!(d.native_finish, "absent" | "malformed_function_call")
    {
        if answer_shape.is_none()
            && stream_done == Some(true)
            && no_tool_call
            && let Some(value) = text.and_then(read_hint)
        {
            return Ok(ModelReply { value, usage });
        }
        return Err(interrupted(
            "Provider generated a malformed native function call.",
        ));
    }
    // Positive evidence of an empty chat completion. Unknown finish reasons and
    // native/foreign payloads are never reinterpreted as a transient stop.
    if d.choices.is_some()
        && empty_content
        && no_tool_call
        && [d.finish, d.native_finish]
            .iter()
            .all(|reason| matches!(*reason, "stop" | "absent"))
        && (d.finish == "stop" || usage.output == Some(0) || reasoning_only)
    {
        return Err(interrupted("Provider returned an empty model completion."));
    }
    if d.finish != "stop" || !matches!(d.native_finish, "absent" | "stop") {
        return Err(issue("Provider stopped before completing its reply.").into());
    }
    if answer_shape.is_some()
        && ((!message["tool_calls"].is_null()
            && !message["tool_calls"].as_array().is_some_and(Vec::is_empty))
            || !message["function_call"].is_null())
    {
        return Err(interrupted(
            "Provider returned a native call instead of its structured stage response.",
        ));
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
    if answer_shape.is_some_and(|shape| !shape.accepts(&value)) {
        return Err(interrupted(
            "Provider returned a different response from the requested review stage.",
        ));
    }
    Ok(ModelReply { value, usage })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode_reply(bytes: &[u8]) -> Result<ModelReply> {
        super::decode_reply(bytes, None)
    }

    fn decode_stream(reader: impl Read) -> Result<ModelReply> {
        super::decode_stream(reader, None)
    }
    use std::{
        env,
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        process::Command,
        thread,
        time::Instant,
    };

    #[test]
    fn rate_limits_honor_both_retry_after_formats_and_google_retry_info() {
        let time = std::time::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        let date = httpdate::fmt_http_date(time + Duration::from_secs(90));
        let body = json!({"error":{"status":"RESOURCE_EXHAUSTED","message":"private",
            "details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"70.25s"}]}});
        let seconds = RateLimited::from_response(Some("45"), &body, time);
        assert_eq!(seconds.retry_after, Some(Duration::from_millis(70_250)));
        assert!(!seconds.to_string().contains("private"));
        assert_eq!(
            RateLimited::from_response(Some(&date), &body, time).retry_after,
            Some(Duration::from_secs(90))
        );
        assert_eq!(
            RateLimited::from_response(Some("83"), &Value::Null, time).retry_after,
            Some(Duration::from_secs(83))
        );
        let unknown = RateLimited::from_response(
            Some("private-header"),
            &json!([{
                "error":{"status":"RESOURCE_EXHAUSTED","details":[{"@type":"other","retryDelay":"80s"}]}
            }]),
            time,
        );
        assert_eq!(unknown.retry_after, None);
        assert_eq!(
            unknown.to_string(),
            "Provider HTTP 429 Too Many Requests (RESOURCE_EXHAUSTED)."
        );
    }

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
    fn a_generation_deadline_before_headers_is_distinct_from_an_interrupted_stream() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/chat", listener.local_addr().unwrap());
        let client = Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_millis(30))
            .build()
            .unwrap();
        let timeout = Duration::from_millis(180);
        // The socket completes the handshake but sends no HTTP headers.
        let error = send_generation(client.post(&url).timeout(timeout), Some(timeout)).unwrap_err();
        assert!(error.is::<crate::ReviewBatchInterrupted>());
        assert_eq!(
            error.downcast_ref::<InvalidReply>().unwrap().reason,
            "Provider generation timed out before response headers."
        );
        drop(listener);
        let error = send_generation(client.post(url).timeout(timeout), Some(timeout)).unwrap_err();
        assert!(
            error
                .downcast_ref::<reqwest::Error>()
                .is_some_and(reqwest::Error::is_connect)
        );
        assert!(!error.is::<crate::ReviewBatchInterrupted>());

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/chat", listener.local_addr().unwrap());
        let worker = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            // A delta arrives normally; the final usage and [DONE] never arrive.
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"{\"}}]}\n\n").unwrap();
            thread::sleep(timeout * 2);
        });
        let response = send_generation(client.post(url).timeout(timeout), Some(timeout)).unwrap();
        let error = super::decode_stream(response, None).unwrap_err();
        assert!(error.is::<crate::ReviewBatchInterrupted>());
        assert_eq!(
            error.downcast_ref::<InvalidReply>().unwrap().reason,
            "Provider stream ended before completing its reply."
        );
        worker.join().unwrap();
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
        assert!(body.get("stream").is_none() && body.get("stream_options").is_none());
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

    fn stream_events(events: &[Value], done: bool) -> Result<ModelReply> {
        let mut wire = String::from(": keepalive\r\n\r\n");
        for event in events {
            wire.push_str(&format!("data: {event}\r\n\r\n"));
        }
        if done {
            wire.push_str("data: [DONE]\r\n\r\n");
        }
        decode_stream(wire.as_bytes())
    }

    #[test]
    fn combines_streamed_text_with_the_usage_after_the_stop() {
        let reply = stream_events(&[
            json!({"choices":[{"index":0,"delta":{"role":"assistant"}}]}),
            json!({"choices":[{"index":1,"delta":{"content":"ignored"}},{"index":0,"delta":{"content":"{\"ok\":"}}]}),
            json!({"choices":[{"index":0,"delta":{"content":"true}"},"finish_reason":"stop"}]}),
            json!({"choices":[],"usage":{"prompt_tokens":40,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":7}}})
        ], true).unwrap();
        assert_eq!(reply.value, json!({"ok":true}));
        assert_eq!(
            reply.usage,
            TokenUsage {
                input: Some(40),
                output: Some(5),
                cached: Some(7)
            }
        );
    }

    #[test]
    fn unfinished_streams_and_empty_turns_request_batch_recovery() {
        let stop = json!({"choices":[{"finish_reason":"stop","delta":{"content":"{}"}}]});
        let no_finish = json!({"choices":[{"delta":{"content":"{}"}}]});
        let empty = json!({"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":0}});
        for error in [
            stream_events(&[stop], false).unwrap_err(),
            stream_events(&[no_finish], true).unwrap_err(),
            stream_events(&[empty], true).unwrap_err(),
            decode_stream(&b"data: {\"choices\":["[..]).unwrap_err(),
        ] {
            assert!(error.is::<crate::ReviewBatchInterrupted>());
        }
    }

    #[test]
    fn streamed_refusals_and_upstream_errors_remain_terminal_even_without_done() {
        for frame in [
            json!({"choices":[{"delta":{"refusal":"withheld"}}]}),
            json!({"choices":[{"delta":{"content":[{"type":"refusal","refusal":"withheld"}]}}]}),
            json!({"choices":[{"finish_reason":"content_filter"}]}),
            json!({"choices":[{"native_finish_reason":"RECITATION"}]}),
            json!({"promptFeedback":{"blockReason":"SAFETY"}}),
            json!({"error":{"code":403,"message":"private text"}}),
        ] {
            let error = stream_events(
                &[
                    frame,
                    json!({"choices":[{"delta":{"content":"{}"},"finish_reason":"stop"}]}),
                    json!({"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":0}}),
                ],
                false,
            )
            .unwrap_err();
            assert!(
                !error.is::<crate::ReviewBatchInterrupted>()
                    && !error.is::<crate::ReviewContextExceeded>()
            );
            let invalid = error.downcast_ref::<InvalidReply>().unwrap();
            assert_eq!(invalid.usage.output, Some(0));
            assert!(!invalid.to_string().contains("private text"));
        }
        let error = decode_stream(
            &b"event: error\ndata: {\"code\":403,\"message\":\"private text\"}\n\n"[..],
        )
        .unwrap_err();
        assert_eq!(
            error.downcast_ref::<InvalidReply>().unwrap().reason,
            "Provider reported an error in its reply."
        );
    }

    #[test]
    fn explicit_stream_error_event_stays_terminal_if_its_data_is_cut_off() {
        let error = decode_stream(&b"event: error\ndata: {\"code\":"[..]).unwrap_err();
        assert!(!error.is::<crate::ReviewBatchInterrupted>());
        assert_eq!(
            error.downcast_ref::<InvalidReply>().unwrap().reason,
            "Provider reported an error in its reply."
        );
    }

    #[test]
    fn compound_content_filter_stays_terminal_without_logging_its_explanation() {
        let err=stream_events(&[json!({"choices":[{"finish_reason":"content_filter: PRIVATE_NOTE","delta":{"content":"{}"}}]})],true).unwrap_err();
        let info = err.downcast_ref::<InvalidReply>().unwrap();
        assert_eq!(info.reason, "Provider withheld the reply.");
        assert!(
            !err.is::<crate::ReviewBatchInterrupted>()
                && !info.to_string().contains("PRIVATE_NOTE")
        );
        for (tag, expected) in [
            (json!(7), "finish=unrecognized_non_string"),
            (
                json!("private-tag: deadline exceeded"),
                "finish=unrecognized_technical_marker",
            ),
            (
                json!("private-tag: safety"),
                "finish=unrecognized_policy_marker",
            ),
        ] {
            let err = stream_events(
                &[json!({"choices":[{"finish_reason":tag,"delta":{"content":"{}"}}]})],
                true,
            )
            .unwrap_err();
            let details = err.downcast_ref::<InvalidReply>().unwrap().to_string();
            assert!(details.contains(expected) && !details.contains("private-tag"));
            assert!(!err.is::<crate::ReviewBatchInterrupted>());
        }
    }

    #[test]
    fn final_only_responses_reject_read_hints_and_native_calls_even_with_json_text() {
        let shape = Some(AnswerShape::Assessments {
            leads: false,
            reads: false,
        });
        let answer = json!({"complete":true,"assessments":[]});
        let read = json!({"read":{"path":"src/lib.rs","term":"run"}});
        for (finish, content, tool) in [
            ("stop", read.clone(), Value::Null),
            (
                "function_call_filter: MALFORMED_FUNCTION_CALL",
                read,
                Value::Null,
            ),
            (
                "function_call_filter: MALFORMED_FUNCTION_CALL",
                answer.clone(),
                Value::Null,
            ),
            ("stop", answer.clone(), json!([{}])),
            ("stop", answer.clone(), json!({})),
        ] {
            let reply = json!({"choices":[{"finish_reason":finish,"message":{"content":content.to_string(),"tool_calls":tool}}]});
            let error = super::decode_message(&reply, Some(true), shape).unwrap_err();
            assert!(error.is::<crate::ReviewBatchInterrupted>());
        }
        let normal =
            json!({"choices":[{"finish_reason":"stop","message":{"content":answer.to_string()}}]});
        assert_eq!(
            super::decode_message(&normal, Some(true), shape)
                .unwrap()
                .value,
            answer
        );
        assert!(
            super::decode_message(&normal, Some(false), shape)
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        let refusal = json!({"choices":[{"finish_reason":"content_filter","message":{"content":answer.to_string()}}]});
        assert_eq!(
            super::decode_message(&refusal, Some(true), shape)
                .unwrap_err()
                .downcast_ref::<InvalidReply>()
                .unwrap()
                .reason,
            "Provider withheld the reply."
        );
    }

    #[test]
    fn malformed_native_call_allows_only_a_complete_independent_read_only_hint() {
        let frame = |text: &str| json!({"choices":[{"finish_reason":"function_call_filter: MALFORMED_FUNCTION_CALL", "delta":{"content":text}}]});
        let valid = r##"{"read":{"path":"src/main.rs","term":"#L7"}}"##;
        let good = stream_events(&[frame(valid)], true).unwrap();
        assert_eq!(good.value, serde_json::from_str::<Value>(valid).unwrap());
        for text in [
            r#"{"complete":true,"hypotheses":[]}"#,
            r#"{"assessments":[]}"#,
            r#"{"read":{"path":"../private","term":""}}"#,
            r#"{"read":{"path":"src","term":"","command":"pwd"}}"#,
            r#"{"read":{"path":"src","term":"","term":"other"}}"#,
            r#"{"read":{"path":"src","term":""},"read":{"path":"other","term":""}}"#,
            "{}",
        ] {
            assert!(
                stream_events(&[frame(text)], true)
                    .unwrap_err()
                    .is::<crate::ReviewBatchInterrupted>()
            );
        }
        assert!(
            stream_events(&[frame(valid)], false)
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        let mut native = frame(valid);
        native["choices"][0]["delta"]["tool_calls"] = json!([{"function":{"name":"read"}}]);
        assert!(
            stream_events(&[native], true)
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        let mut malformed_native = frame(valid);
        malformed_native["choices"][0]["delta"]["tool_calls"] = json!({"unexpected":"shape"});
        assert!(
            stream_events(&[malformed_native], true)
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        let mut blocked = frame(valid);
        blocked["choices"][0]["native_finish_reason"] = json!("SAFETY");
        let error = stream_events(&[blocked], true).unwrap_err();
        assert!(!error.is::<crate::ReviewBatchInterrupted>());
        assert_eq!(
            error.downcast_ref::<InvalidReply>().unwrap().reason,
            "Provider withheld the reply."
        );
    }

    #[test]
    fn streamed_output_limits_still_require_partition_and_large_replies_are_bounded() {
        let error = stream_events(
            &[json!({"choices":[{"finish_reason":"length","delta":{"content":"{"}}]})],
            true,
        )
        .unwrap_err();
        assert!(error.is::<crate::ReviewContextExceeded>());
        let error = stream_events(
            &[json!({"choices":[{"delta":{"content":"x".repeat(MAX_REPLY_BYTES+1)}}]})],
            false,
        )
        .unwrap_err();
        assert!(error.to_string().contains("size limit"));
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
    fn only_fully_accounted_reasoning_tokens_confirm_zero_visible_output() {
        let mut reply = json!({"choices":[{"finish_reason":null,"message":{"content":null}}],"usage":{"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":9}}});
        let recoverable = |v: &Value| {
            decode_reply(&serde_json::to_vec(v).unwrap())
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        };
        assert!(recoverable(&reply));
        reply["choices"][0]["native_finish_reason"] = json!("ESCALATION");
        assert!(!recoverable(&reply));
        reply["choices"][0]["native_finish_reason"] = json!("PUP_LIMITED_DISABLED");
        assert!(!recoverable(&reply));
        reply["choices"][0]["native_finish_reason"] = Value::Null;
        for n in [json!(8), json!(10), Value::Null] {
            reply["usage"]["completion_tokens_details"]["reasoning_tokens"] = n;
            assert!(!recoverable(&reply));
        }
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
    fn compatible_context_errors_select_a_smaller_batch() {
        for body in [
            json!({"object":"error", "type":"BadRequestError", "message":"This model's maximum context length is 4096 tokens. However, you requested 5010 tokens."}),
            json!({"error":{"type":"invalid_request_error","message":"prompt is too long: 204901 tokens > 200000 maximum"}}),
            json!({"error":{"message":"litellm.BadRequestError: prompt is too long: 5000 tokens > 4096 maximum"}}),
            json!({"error":{"type":"exceed_context_size_error","message":"Request cannot fit"}}),
            json!({"error":{"code":400,"message":"request (4390 tokens) exceeds the available context size (4096 tokens)"}}),
            json!({"error":{"code":"context_length_exceeded"}}),
        ] {
            assert!(context_overflow(&body));
        }
        for body in [
            json!({"error":{"code":"content_policy_violation","message":"prompt is too long: 5000 tokens > 4096 maximum"}}),
            json!({"error":{"message":"The value of maximum context length must be positive"}}),
            json!({"type":"BadRequestError","message":"The prompt is too long for the preview field"}),
            json!({"error":{"message":"Too many requests for your rate limit"}}),
        ] {
            assert!(!context_overflow(&body));
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
