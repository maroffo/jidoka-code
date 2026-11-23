//! Cost reservations for standard-tier text requests at the pinned Google endpoint.
use super::{AnswerShape, Client, ModelReply, Provider, TokenUsage, system_content, user_content};
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::time::Duration;

const GOOGLE_CHAT: &str =
    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
const CARBON: &str = "gemini-4-carbon";
const FLASH: &str = "gemini-3.8-flash";

#[derive(Clone, Copy, Debug)]
struct Rates {
    input: u64,
    output: u64,
}

impl Rates {
    fn cost(self, input: u64, output: u64) -> u64 {
        input
            .saturating_mul(self.input)
            .saturating_add(output.saturating_mul(self.output))
    }
}

/// Reservations use nano-USD (1 USD = 1,000,000,000). No cache discount is assumed.
#[derive(Clone, Copy, Debug)]
pub struct BudgetQuote {
    rates: Rates,
    input: u64,
    output: u64,
}

impl BudgetQuote {
    pub fn input_tokens(self) -> u64 {
        self.input
    }
    pub fn output_tokens(self) -> u64 {
        self.output
    }
    pub fn max_nanousd(self) -> u64 {
        self.rates.cost(self.input, self.output)
    }

    /// Fall back independently for missing usage. Never conceal a reported overrun.
    pub fn charge(self, usage: TokenUsage) -> u64 {
        self.rates.cost(
            usage.input.unwrap_or(self.input),
            usage.output.unwrap_or(self.output),
        )
    }
}

pub struct PreparedGeneration<'p> {
    provider: &'p Provider,
    body: Value,
    shape: Option<AnswerShape>,
    quote: BudgetQuote,
}

impl PreparedGeneration<'_> {
    pub fn quote(&self) -> BudgetQuote {
        self.quote
    }

    /// Consumes the exact body that was quoted. A chargeable call cannot be
    /// transparently repeated by the HTTP client or the schema fallback.
    pub fn dispatch(self, timeout: Duration) -> Result<ModelReply> {
        let client = self
            .provider
            .budget_client
            .get()
            .context("Budgeted transport was not prepared")?;
        let response = self
            .provider
            .submit_with(client, self.body, timeout, false)?;
        self.provider
            .read_response(response, self.shape, Some(self.quote.output_tokens()))
    }
}

impl Provider {
    fn rates(&self) -> Option<Rates> {
        if self.endpoint.as_str().trim_end_matches('/') != GOOGLE_CHAT || self.context.is_none() {
            return None;
        }
        // https://ai.google.dev/gemini-api/docs/pricing
        // Published standard USD per million tokens (including thinking),
        // using the higher post-promotion rates. No tools or priority tier.
        match self.model.as_str() {
            CARBON => Some(Rates {
                input: 4_000,
                output: 20_000,
            }),
            FLASH => Some(Rates {
                input: 1_500,
                output: 7_500,
            }),
            _ => None,
        }
    }

    pub fn supports_budgeted(&self) -> bool {
        self.rates().is_some()
    }

    pub fn flash_companion(&self) -> Result<Option<Self>> {
        if self.model != CARBON || !self.supports_budgeted() {
            return Ok(None);
        }
        let context = self
            .context
            .as_ref()
            .context("Missing Gemini context")?
            .companion(FLASH)?;
        Ok(Some(Self {
            endpoint: self.endpoint.clone(),
            model: FLASH.into(),
            authorization: self.authorization.clone(),
            client: self.client.clone(),
            budget_client: Default::default(),
            context: Some(context),
            label: format!("{} ({FLASH})", self.endpoint),
        }))
    }

    pub fn fits_budgeted_context(
        &self,
        system: &str,
        data: &Value,
        min_output_tokens: u64,
    ) -> Result<bool> {
        match self.prepare_budgeted(system, data, u64::MAX, min_output_tokens, min_output_tokens) {
            Ok(prepared) => Ok(prepared.is_some()),
            Err(error) if error.is::<crate::ReviewContextExceeded>() => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn prepare_budgeted(
        &self,
        system: &str,
        data: &Value,
        remaining_nanousd: u64,
        min_output_tokens: u64,
        max_output_tokens: u64,
    ) -> Result<Option<PreparedGeneration<'_>>> {
        let rates = self
            .rates()
            .context("This endpoint and model do not support budgeted reviews")?;
        ensure!(
            min_output_tokens > 0 && min_output_tokens <= max_output_tokens,
            "Invalid output budget"
        );
        if remaining_nanousd / rates.output < min_output_tokens {
            return Ok(None);
        }
        let shape = AnswerShape::from_input(data);
        ensure!(
            self.model != FLASH || matches!(shape, Some(AnswerShape::EvidenceReads)),
            "The budgeted Flash companion requires an evidence selection request"
        );
        let system = system_content(system, shape);
        let content = user_content(data)?;
        let mut format = shape.map(|shape| shape.format(data));
        // The exact-cardinality assessment schema can exceed Google's compiler
        // limits. Preserve the allowed IDs and the engine's completeness check.
        if let Some(format) = format.as_mut() {
            super::remove_format_count(format);
        }
        let context = self.context.as_ref().context("Missing Gemini context")?;
        let (input, output_room) =
            context.counted_limits(&self.client, &system, &content, format.as_ref())?;
        if output_room < min_output_tokens {
            return Err(crate::ReviewContextExceeded.into());
        }
        let affordable = remaining_nanousd.saturating_sub(rates.cost(input, 0)) / rates.output;
        let output = max_output_tokens.min(output_room).min(affordable);
        if output < min_output_tokens {
            return Ok(None);
        }
        let quote = BudgetQuote {
            rates,
            input,
            output,
        };
        let mut body = self.chat_body(&system, &content, format, Some(output));
        if self.model == FLASH && matches!(shape, Some(AnswerShape::EvidenceReads)) {
            body["reasoning_effort"] = "low".into();
        }
        if self.budget_client.get().is_none() {
            let client: Client = Self::client_builder()
                .retry(reqwest::retry::never())
                .build()?;
            self.budget_client.get_or_init(|| client);
        }
        Ok(Some(PreparedGeneration {
            provider: self,
            body,
            shape,
            quote,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pinned(model: &str) -> Provider {
        Provider::new(GOOGLE_CHAT, model, "fixture-key".into()).unwrap()
    }

    fn seed(provider: &mut Provider, data: &Value, window: u64) {
        let system = system_content("fixture", AnswerShape::from_input(data));
        provider.context.as_mut().unwrap().seed_count(
            &system,
            &user_content(data).unwrap(),
            500,
            window,
            9000,
        );
    }

    #[test]
    fn priced_models_and_companion_credentials_are_pinned_to_google() {
        let carbon = pinned(CARBON);
        let flash = carbon.flash_companion().unwrap().unwrap();
        assert_eq!(flash.model, FLASH);
        assert_eq!(flash.endpoint, carbon.endpoint);
        assert_eq!(flash.authorization, carbon.authorization);
        assert!(flash.authorization.unwrap().is_sensitive());
        assert!(
            Provider::new(&format!("{GOOGLE_CHAT}/"), CARBON, String::new())
                .unwrap()
                .supports_budgeted()
        );
        for (address, model) in [
            (GOOGLE_CHAT, "gemini-4-carbon-preview"),
            ("https://example.org/v1beta/openai/chat/completions", CARBON),
            (
                "https://generativelanguage.googleapis.com:444/v1beta/openai/chat/completions",
                CARBON,
            ),
            (
                "https://generativelanguage.googleapis.com/v1beta/other",
                CARBON,
            ),
        ] {
            let provider = Provider::new(address, model, String::new()).unwrap();
            assert!(!provider.supports_budgeted());
            assert!(provider.flash_companion().unwrap().is_none());
        }
    }

    #[test]
    fn reserve_and_meter_the_actual_body_using_integer_rates() {
        let mut carbon = pinned(CARBON);
        let data = json!({"answer_shape":"assessments","review_role":"final","hypotheses":[{"id":3}],"allow_assessment_reads":true});
        seed(&mut carbon, &data, 50_000);
        let prepared = carbon
            .prepare_budgeted("fixture", &data, u64::MAX, 512, 10_000)
            .unwrap()
            .unwrap();
        let q = prepared.quote();
        assert_eq!(
            q.input_tokens(),
            500 + 1024
                + serde_json::to_vec(&prepared.body["response_format"])
                    .unwrap()
                    .len() as u64
        );
        assert_eq!(q.output_tokens(), 9000);
        assert_eq!(prepared.body["max_tokens"], q.output);
        assert!(prepared.body.get("reasoning_effort").is_none());
        let props = &prepared.body["response_format"]["json_schema"]["schema"]["properties"];
        assert!(props.get("leads").is_none() && props["assessments"].get("minItems").is_none());
        assert_eq!(q.max_nanousd(), q.input * 4_000 + q.output * 20_000);
        assert_eq!(q.charge(TokenUsage::default()), q.max_nanousd());
        assert_eq!(
            q.charge(TokenUsage {
                input: Some(100),
                output: Some(25),
                cached: Some(98)
            }),
            900_000
        );
        assert_eq!(
            q.charge(TokenUsage {
                input: Some(100),
                ..Default::default()
            }),
            400_000 + q.output * 20_000
        );
        assert!(
            q.charge(TokenUsage {
                input: Some(q.input + 1),
                ..Default::default()
            }) > q.max_nanousd()
        );
        let dollars = q.input * 4_000 + 512 * 20_000;
        assert!(
            carbon
                .prepare_budgeted("fixture", &data, dollars - 1, 512, 8192)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            carbon
                .prepare_budgeted("fixture", &data, dollars + 19_999, 512, 8192)
                .unwrap()
                .unwrap()
                .quote()
                .output,
            512
        );
        seed(&mut carbon, &data, q.input + 512);
        assert!(carbon.fits_budgeted_context("fixture", &data, 512).unwrap());
        assert!(!carbon.fits_budgeted_context("fixture", &data, 513).unwrap());
        assert!(
            carbon
                .prepare_budgeted("fixture", &data, u64::MAX, 513, 8192)
                .err()
                .unwrap()
                .is::<crate::ReviewContextExceeded>()
        );
    }

    #[test]
    fn flash_prepares_only_a_bounded_read_plan() {
        let mut flash = pinned(CARBON).flash_companion().unwrap().unwrap();
        let data = json!({"answer_shape":"evidence_reads","review_role":"scout","hypotheses":[{"id":7},{"id":9}],"max_reads":4});
        seed(&mut flash, &data, 50_000);
        let prepared = flash
            .prepare_budgeted("fixture", &data, u64::MAX, 256, 2048)
            .unwrap()
            .unwrap();
        assert_eq!(prepared.body["reasoning_effort"], "low");
        assert_eq!(prepared.body["tool_choice"], "none");
        let reads =
            &prepared.body["response_format"]["json_schema"]["schema"]["properties"]["reads"];
        assert_eq!(reads["items"]["properties"]["id"]["enum"], json!([7, 9]));
        assert_eq!(reads["maxItems"], 4);
        let q = prepared.quote();
        assert_eq!(q.max_nanousd(), q.input * 1_500 + 2048 * 7_500);
        let shape = prepared.shape.unwrap();
        assert!(shape.accepts(&json!({"reads":[{"id":9,"path":"src/lib.rs","term":"run"}]})));
        assert!(!shape.accepts(&json!({"findings":[],"reads":[]})));
        assert!(!shape.accepts(
            &json!({"reads":[{"id":9,"path":"src/lib.rs","term":"run","outcome":"confirmed"}]})
        ));
        assert!(
            flash
                .prepare_budgeted(
                    "fixture",
                    &json!({"answer_shape":"assessments"}),
                    u64::MAX,
                    256,
                    2048
                )
                .is_err()
        );
    }

    #[test]
    fn dispatch_submits_the_reserved_body_once_on_schema_rejection() {
        let compiler = json!({"error":{"code":400,"status":"INVALID_ARGUMENT",
            "message":"The specified schema produces a constraint that has too many states for serving."}});
        let input = json!({"answer_shape":"assessments","hypotheses":[{"id":5}]});
        let shape = AnswerShape::from_input(&input);
        let body = json!({"model":CARBON,"max_tokens":512,"response_format":shape.unwrap().format(&input)});
        // Give the test a bounded schema that the ordinary chat path would resend.
        let (error, requests) =
            crate::provider::tests::with_http_fixture(true, vec![(400, compiler)], |provider| {
                provider.budget_client.get_or_init(|| {
                    Provider::client_builder()
                        .retry(reqwest::retry::never())
                        .build()
                        .unwrap()
                });
                PreparedGeneration {
                    provider,
                    body: body.clone(),
                    shape,
                    quote: BudgetQuote {
                        rates: Rates {
                            input: 4000,
                            output: 20000,
                        },
                        input: 100,
                        output: 512,
                    },
                }
                .dispatch(Duration::from_secs(3))
            });
        assert_eq!(
            error.unwrap_err().to_string(),
            crate::provider::SCHEMA_TOO_COMPLEX
        );
        assert_eq!(requests, [body]);
    }

    #[test]
    fn budgeted_usage_handles_reasoning_and_unverifiable_truncation() {
        let mut response = json!({"choices":[{"finish_reason":"stop","message":{"content":"{}"}}],
            "usage":{"prompt_tokens":120,"completion_tokens":3,"total_tokens":149}});
        let decoded = crate::provider::decode_message(&response, None, None, Some(512)).unwrap();
        assert_eq!(decoded.usage.output, Some(29));
        response["choices"][0]["finish_reason"] = json!("length");
        let error = crate::provider::decode_message(&response, None, None, Some(512)).unwrap_err();
        assert_eq!(
            error
                .downcast_ref::<crate::provider::InvalidReply>()
                .unwrap()
                .usage
                .output,
            None
        );
        response["choices"][0]["finish_reason"] = json!("stop");
        response["usage"]
            .as_object_mut()
            .unwrap()
            .remove("total_tokens");
        let decoded = crate::provider::decode_message(&response, None, None, Some(512)).unwrap();
        assert_eq!(decoded.usage.output, None);
    }
}
