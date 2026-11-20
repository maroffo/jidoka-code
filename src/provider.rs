use anyhow::{Context, Result, ensure};
use reqwest::{
    Url,
    blocking::Client,
    header::{AUTHORIZATION, HeaderValue},
    redirect::Policy,
};
use serde_json::{Value, json};
use std::{io::Read, time::Duration};

const MAX_BYTES: usize = 1_000_000;

pub struct Provider {
    client: Client,
    endpoint: Url,
    model: String,
    authorization: Option<HeaderValue>,
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
        Ok(Self {
            client,
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
        let body = serde_json::to_vec(&json!({
            "model": self.model, "messages": [
                {"role":"system","content":system},
                {"role":"user","content":serde_json::to_string(data)?}],
            "response_format":{"type":"json_object"}
        }))?;
        ensure!(
            body.len() <= MAX_BYTES,
            "Provider request exceeds the size limit"
        );
        let mut request = self
            .client
            .post(self.endpoint.clone())
            .header("Content-Type", "application/json")
            .body(body);
        if let Some(authorization) = &self.authorization {
            request = request.header(AUTHORIZATION, authorization.clone());
        }
        let response = request.send().context("Provider is unavailable")?;
        ensure!(
            response.status().is_success(),
            "The provider rejected the request"
        );
        let mut bytes = Vec::new();
        response
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_BYTES,
            "Provider response exceeds the size limit"
        );
        decode_reply(&bytes)
    }
}

fn decode_reply(bytes: &[u8]) -> Result<Value> {
    let reply: Value = serde_json::from_slice(bytes)?;
    let first = &reply["choices"][0];
    ensure!(
        first["finish_reason"] == "stop",
        "Incomplete provider response"
    );
    let value: Value = serde_json::from_str(
        first["message"]["content"]
            .as_str()
            .context("Provider response is missing text")?,
    )?;
    ensure!(value.is_object(), "Expected a JSON object");
    Ok(value)
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
                    .ask("instruction", &json!({"fixture": true}))
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
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap()["model"],
            "test"
        );
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
            "Provider request exceeds the size limit"
        );
    }
}
