//! Select the evidence planner and reserve the primary model's closing verdict.
use anyhow::{Context, Result, ensure};
use jidoka_code::{provider::Provider, web::session::Session};
use serde_json::Value;
use std::{cell::Cell, time::Duration};

const MODEL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const NANODOLLARS_PER_CENT: u64 = 10_000_000;

pub struct Reviewer {
    primary: Provider,
    pair: Option<BudgetedReview>,
    label: String,
}

struct BudgetedReview {
    scout: Provider,
    cap: u64,
}

impl Reviewer {
    pub fn new(primary: Provider, cents: Option<&str>) -> Result<Self> {
        let cents = cents.map(str::trim).filter(|s| !s.is_empty());
        let scout = primary.flash_companion()?;
        ensure!(
            cents.is_none() || scout.is_some(),
            "JIDOKA_REVIEW_BUDGET_CENTS requires Gemini 4 Carbon at the official Google endpoint"
        );
        let pair = scout
            .map(|scout| -> Result<_> {
                let cap = review_cap(cents.unwrap_or("100"))?;
                Ok(BudgetedReview { scout, cap })
            })
            .transpose()?;
        let label = match &pair {
            Some(_) => format!("{} + gemini-3.8-flash for evidence", primary.label()),
            None => primary.label().to_owned(),
        };
        Ok(Self {
            primary,
            pair,
            label,
        })
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn configure_session(&self, session: &mut Session) -> Result<()> {
        if let Some(pair) = &self.pair {
            session.configure_budget(pair.cap, pair.cap / 2)?;
        }
        Ok(())
    }

    pub fn uses_planner(&self) -> bool {
        self.pair.is_some()
    }

    fn model(&self, data: &Value) -> &Provider {
        match &self.pair {
            Some(pair) if data["review_role"] == "scout" => &pair.scout,
            _ => &self.primary,
        }
    }

    pub fn fits(&self, session: &Session, system: &str, data: &Value) -> Result<bool> {
        let model = self.model(data);
        if self.uses_planner() {
            // Let admission checkpoint a known denial without contacting the scout's tokenizer.
            if session.budget_remaining(data["review_role"] == "final")? == 0 {
                return Ok(true);
            }
            model.fits_budgeted_context(system, data, output_limits(data).0)
        } else {
            model.fits_context(system, data)
        }
    }

    pub fn ask(
        &self,
        session: &mut Session,
        system: &str,
        data: &Value,
        eligible: impl Fn() -> Result<()>,
    ) -> Result<Value> {
        let model = self.model(data);
        if self.pair.is_none() {
            return session.ask_when_eligible(system, data, eligible, || {
                model.ask_metered(system, data, MODEL_TIMEOUT)
            });
        }
        let quote = Cell::new(None);
        let (minimum, maximum) = output_limits(data);
        session.ask_budgeted(
            system,
            data,
            data["review_role"] == "final",
            eligible,
            |available| {
                let Some(request) =
                    model.prepare_budgeted(system, data, available, minimum, maximum)?
                else {
                    return Ok(None);
                };
                let price = request.quote();
                quote.set(Some(price));
                Ok(Some((price.max_nanousd(), request)))
            },
            |request| request.dispatch(MODEL_TIMEOUT),
            |usage| quote.get().map(|price| price.charge(usage)),
        )
    }
}

fn output_limits(data: &Value) -> (u64, u64) {
    if data["review_role"] == "scout" {
        (256, 2048)
    } else {
        (512, 8192)
    }
}

fn review_cap(cents: &str) -> Result<u64> {
    let cap = cents.parse::<u64>().ok().and_then(|v|v.checked_mul(NANODOLLARS_PER_CENT))
        .filter(|&v| v > 0 && v <= i64::MAX as u64)
        .context("JIDOKA_REVIEW_BUDGET_CENTS must be a positive whole number of US cents within the supported range")?;
    Ok(cap)
}

#[cfg(test)]
mod tests {
    use super::*;
    const GOOGLE: &str = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

    #[test]
    fn enables_the_budget_only_for_the_official_carbon_pair() {
        let pair = Reviewer::new(
            Provider::new(GOOGLE, "gemini-4-carbon", String::new()).unwrap(),
            None,
        )
        .unwrap();
        assert!(pair.uses_planner());
        assert_eq!(pair.pair.as_ref().unwrap().cap, 1_000_000_000);
        assert!(pair.label().contains("gemini-3.8-flash"));
        assert!(
            pair.model(&serde_json::json!({"review_role":"scout"}))
                .label()
                .contains("gemini-3.8-flash")
        );
        assert!(
            pair.model(&serde_json::json!({"review_role":"final"}))
                .label()
                .contains("gemini-4-carbon")
        );
        let generic =
            || Provider::new("https://example.com/chat", "gemini-4-carbon", String::new()).unwrap();
        assert!(!Reviewer::new(generic(), None).unwrap().uses_planner());
        assert!(Reviewer::new(generic(), Some("12")).is_err());
        assert!(review_cap("0").is_err());
        assert!(review_cap("1.25").is_err());
        assert!(review_cap("18446744073709551615").is_err());
        assert_eq!(review_cap("15").unwrap(), 150_000_000);
    }
}
