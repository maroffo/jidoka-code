//! Response formats for interactive stages where repository reads have ended.
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum FinalAnswer {
    Hypotheses,
    Assessments { leads: bool },
}

impl FinalAnswer {
    pub(super) fn from_input(data: &Value) -> Option<Self> {
        // PR text, metadata and source rows are nested under snapshot, never merged here.
        match data.get("answer_shape")?.as_str()? {
            "hypotheses" => Some(Self::Hypotheses),
            "assessments" => Some(Self::Assessments {
                leads: data["hypotheses"].is_array() && data.get("recheck").is_none(),
            }),
            _ => None,
        }
    }

    fn key(self) -> &'static str {
        match self {
            Self::Hypotheses => "hypotheses",
            Self::Assessments { .. } => "assessments",
        }
    }

    pub(super) fn format(self) -> Value {
        let key = self.key();
        let item = match self {
            Self::Hypotheses => hypothesis(),
            Self::Assessments { .. } => assessment(),
        };
        let mut schema = json!({
            "type":"object", "additionalProperties":false,
            "properties":{"complete":{"type":"boolean"}, key:{"type":"array","items":item}},
            "required":["complete",key]
        });
        if self == (Self::Assessments { leads: true }) {
            schema["properties"]["leads"] = json!({"type":"array","items":hypothesis()});
        }
        json!({"type":"json_schema","json_schema":{"name":key,"schema":schema}})
    }

    // Validate the stage envelope even when the provider ignores the schema.
    // The engine validates every citation, assessment and coverage decision.
    pub(super) fn accepts(self, value: &Value) -> bool {
        let Some(object) = value.as_object() else {
            return false;
        };
        value["complete"].is_boolean()
            && value[self.key()].is_array()
            && object.keys().all(|key| {
                key == "complete"
                    || key == self.key()
                    || (key == "leads"
                        && self == (Self::Assessments { leads: true })
                        && value[key].is_array())
            })
    }
}

fn hypothesis() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "properties":{
            "anchor":{"type":"string","description":"Head reference from a source row (H ID)"},
            "expected":{"type":"string"},"scenario":{"type":"string"},"consequence":{"type":"string"}
        },
        "required":["anchor","expected","scenario","consequence"]
    })
}

fn assessment() -> Value {
    let text = json!({"type":"string"});
    let head = json!({"type":"string","description":"Head reference from a source row (H ID)"});
    let base = json!({"type":"string","description":"Base reference from a source row (B ID)"});
    let severity = json!({"type":"string","enum":["high","medium","low"]});
    let comparison = json!({"anyOf":[{"type":"null"}, {
        "type":"object","additionalProperties":false,
        "properties":{"behavior":base,"basis":base,"affected":{"type":"boolean"}},
        "required":["behavior","basis","affected"]
    }]});
    let counterevidence = json!({
        "type":"object","additionalProperties":false,
        "properties":{"references":{"type":"array","minItems":1,"maxItems":6,"items":head},
            "absence_paths":{"type":"array","items":text}},
        "required":["references","absence_paths"]
    });
    let fields = json!({
        "kind":{"type":"string","enum":["contract","convention","performance"]}, "basis":head,
        "support":{"type":"array","maxItems":4,"items":head}, "severity":severity, "title":text,
        "impact":text, "reason":text, "comparison":comparison, "counterevidence":counterevidence,
        "question":text, "alternatives":{"type":"array","minItems":2,"maxItems":2,"items":text},
        "action":text,"expected":text
    });
    let variant = |outcome: &str, names: &[&str]| {
        let mut properties = json!({"id":{"type":"integer"},"outcome":{"type":"string","enum":[outcome]},"countercheck":text});
        let mut required = vec!["id", "outcome", "countercheck"];
        for &name in names {
            properties[name] = fields[name].clone();
            required.push(name);
        }
        json!({"type":"object","additionalProperties":false,"properties":properties,"required":required})
    };
    let manual = ["basis", "severity", "action", "expected"];
    json!({"anyOf":[
        variant("confirmed",&["kind","basis","support","severity","title","impact","reason","comparison","counterevidence"]),
        variant("refuted",&["basis"]), variant("refuted",&["basis","severity","action"]),
        variant("human",&["basis","severity","reason","question","alternatives"]),
        variant("manual_test",&manual), variant("indeterminate",&[]), variant("indeterminate",&manual)
    ]})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_engine_stage_markers_select_formats_and_leads() {
        for data in [
            json!({"snapshot":{"answer_shape":"assessments","hypotheses":[]}}),
            json!({"last_read":{"answer_shape":"hypotheses"}}),
            json!({"answer_shape":"read"}),
        ] {
            assert_eq!(FinalAnswer::from_input(&data), None);
        }
        let challenge =
            FinalAnswer::from_input(&json!({"answer_shape":"assessments","hypotheses":[]}))
                .unwrap();
        let recheck = FinalAnswer::from_input(
            &json!({"answer_shape":"assessments","hypotheses":[],"recheck":[]}),
        )
        .unwrap();
        let hypothesis = FinalAnswer::from_input(&json!({"answer_shape":"hypotheses"})).unwrap();
        let with_leads = json!({"complete":true,"assessments":[],"leads":[]});
        assert!(challenge.accepts(&with_leads));
        assert!(!recheck.accepts(&with_leads));
        assert!(!hypothesis.accepts(&with_leads));
        let challenge = challenge.format();
        assert_eq!(
            challenge["json_schema"]["schema"]["properties"]["leads"]["items"],
            super::hypothesis()
        );
        assert!(
            recheck.format()["json_schema"]["schema"]["properties"]
                .get("leads")
                .is_none()
        );
        assert_eq!(
            hypothesis.format()["json_schema"]["schema"]["properties"]["hypotheses"]["items"]["properties"]
                ["anchor"]["type"],
            "string"
        );
    }
}
