//! Structured proposals and assessments for interactive reviews.
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AnswerShape {
    Hypotheses,
    EvidenceReads,
    Assessments { leads: bool, reads: bool },
}

impl AnswerShape {
    pub(super) fn from_input(data: &Value) -> Option<Self> {
        // PR text, metadata and source rows are nested under snapshot, never merged here.
        match data.get("answer_shape")?.as_str()? {
            "hypotheses" => Some(Self::Hypotheses),
            "evidence_reads" if data["review_role"] == "scout" => Some(Self::EvidenceReads),
            "assessments" if data["review_role"] == "final" => Some(Self::Assessments {
                leads: false,
                reads: false,
            }),
            "assessments" => Some(Self::Assessments {
                leads: data["hypotheses"].is_array() && data.get("recheck").is_none(),
                reads: data["allow_assessment_reads"].as_bool() == Some(true),
            }),
            _ => None,
        }
    }

    fn key(self) -> &'static str {
        match self {
            Self::Hypotheses => "hypotheses",
            Self::EvidenceReads => "reads",
            Self::Assessments { .. } => "assessments",
        }
    }

    pub(super) fn format(self, data: &Value) -> Value {
        let key = self.key();
        // The engine replaces the hypotheses list with the unresolved subset
        // before each recheck. Use only its validated, distinct positive IDs.
        let ids = match self {
            Self::EvidenceReads | Self::Assessments { .. } => {
                data["hypotheses"].as_array().and_then(|items| {
                    let ids: BTreeSet<_> = items
                        .iter()
                        .map(|item| item["id"].as_u64().filter(|id| *id > 0))
                        .collect::<Option<_>>()?;
                    (ids.len() == items.len()).then_some(ids)
                })
            }
            Self::Hypotheses => None,
        };
        if self == Self::EvidenceReads {
            let mut id = json!({"type":"integer"});
            if let Some(ids) = ids.as_ref().filter(|ids| !ids.is_empty()) {
                id["enum"] = json!(ids);
            }
            let mut reads = json!({"type":"array","items":{"type":"object","additionalProperties":false,
                "properties":{"id":id,"path":{"type":"string"},"term":{"type":"string"}},"required":["id","path","term"]}});
            if let Some(max) = data["max_reads"].as_u64() {
                reads["maxItems"] = max.into();
            }
            return json!({"type":"json_schema","json_schema":{"name":"evidence_reads","schema":{"type":"object",
                "additionalProperties":false,"properties":{"reads":reads},"required":["reads"]}}});
        }
        let limit_ids = ids.as_ref().is_some_and(|ids| !ids.is_empty());
        let item = match self {
            Self::Hypotheses => hypothesis(),
            Self::EvidenceReads => unreachable!("evidence reads use their own response envelope"),
            Self::Assessments { reads, .. } => assessment(reads, limit_ids),
        };
        let mut schema = json!({
            "type":"object", "additionalProperties":false,
            "properties":{"complete":{"type":"boolean"}, key:{"type":"array","items":item}},
            "required":["complete",key]
        });
        if let Some(ids) = ids {
            schema["properties"][key]["minItems"] = ids.len().into();
            schema["properties"][key]["maxItems"] = ids.len().into();
            if !ids.is_empty() {
                schema["$defs"] = json!({"assessmentId":{"type":"integer","enum":ids}});
            }
        }
        if matches!(self, Self::Assessments { leads: true, .. }) {
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
        let Some(items) = value[self.key()].as_array() else {
            return false;
        };
        if self == Self::EvidenceReads {
            return object.len() == 1
                && items.iter().all(|row| {
                    row.as_object().is_some_and(|o| o.len() == 3)
                        && row["id"].as_u64().is_some_and(|id| id > 0)
                        && row["path"].is_string()
                        && row["term"].is_string()
                });
        }
        let allowed_reads = matches!(self, Self::Assessments { reads: true, .. });
        value["complete"].is_boolean()
            && items.iter().all(|item| {
                item.get("reads").is_none() || (allowed_reads && item["outcome"] == "indeterminate")
            })
            && object.keys().all(|key| {
                key == "complete"
                    || key == self.key()
                    || (key == "leads"
                        && matches!(self, Self::Assessments { leads: true, .. })
                        && value[key].is_array())
            })
    }
}

fn hypothesis() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "properties":{
            "anchor":{"type":"string","description":"Head reference from a source row (H ID)"},
            "related":{"type":"array","items":{"type":"string"}},
            "expected":{"type":"string"},"scenario":{"type":"string"},"consequence":{"type":"string"}
        },
        "required":["anchor","expected","scenario","consequence"]
    })
}

fn assessment(allow_reads: bool, limit_ids: bool) -> Value {
    let id = if limit_ids {
        json!({"$ref":"#/$defs/assessmentId"})
    } else {
        json!({"type":"integer"})
    };
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
        let mut properties =
            json!({"id":id,"outcome":{"type":"string","enum":[outcome]},"countercheck":text});
        let mut required = vec!["id", "outcome", "countercheck"];
        for &name in names {
            properties[name] = fields[name].clone();
            required.push(name);
        }
        if allow_reads && outcome == "indeterminate" {
            properties["reads"] = json!({
                "type":"array","maxItems":crate::engine::MAX_CONTEXT_READS,
                "items":{"type":"object","additionalProperties":false,
                    "properties":{"path":{"type":"string","description":"Pinned repository path or exact file stem"},
                        "term":{"type":"string","description":"A nonempty literal symbol or property without whitespace"}},
                    "required":["path","term"]}
            });
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
    fn assessments_match_current_hypothesis_ids_and_share_one_id_schema() {
        let data = json!({"answer_shape":"assessments","hypotheses":[{"id":9},{"id":2}],
            "recheck":[{"id":2,"prior_assessments":[{"id":1}]}], "snapshot":{"hypotheses":[{"id":1}]}});
        let shape = AnswerShape::from_input(&data).unwrap();
        let format = shape.format(&data);
        let schema = &format["json_schema"]["schema"];
        let array = &schema["properties"]["assessments"];
        assert_eq!(array["minItems"], 2);
        assert_eq!(array["maxItems"], 2);
        assert_eq!(schema["$defs"]["assessmentId"]["enum"], json!([2, 9]));
        for variant in array["items"]["anyOf"].as_array().unwrap() {
            assert_eq!(
                variant["properties"]["id"],
                json!({"$ref":"#/$defs/assessmentId"})
            );
        }
        assert!(schema["properties"].get("leads").is_none());

        let empty = json!({"answer_shape":"assessments","hypotheses":[]});
        let format = AnswerShape::from_input(&empty).unwrap().format(&empty);
        let schema = &format["json_schema"]["schema"];
        assert_eq!(schema["properties"]["assessments"]["maxItems"], 0);
        assert_eq!(schema["properties"]["assessments"]["minItems"], 0);
        assert!(schema["properties"]["leads"].is_object());
        assert!(schema.get("$defs").is_none());

        for hypotheses in [
            Value::Null,
            json!([{"id":1},{"id":1}]),
            json!([{"id":0}]),
            json!([{"id":"2"}]),
            json!([{"id":1},{}]),
        ] {
            let data = json!({"answer_shape":"assessments","hypotheses":hypotheses});
            let format = AnswerShape::from_input(&data).unwrap().format(&data);
            let schema = &format["json_schema"]["schema"];
            assert!(
                schema["properties"]["assessments"]
                    .get("minItems")
                    .is_none()
            );
            assert!(
                schema["properties"]["assessments"]
                    .get("maxItems")
                    .is_none()
            );
            assert!(schema.get("$defs").is_none());
        }
    }

    #[test]
    fn only_indeterminate_assessments_can_request_reads_during_evidence_rounds() {
        let mut input = json!({"answer_shape":"assessments","hypotheses":[],
            "snapshot":{"allow_assessment_reads":true}});
        let read = json!({"path":"src/lib.rs","term":"work"});
        let assessment = json!({"id":1,"outcome":"indeterminate","countercheck":"The caller is missing.","reads":[read]});
        let mut answer = json!({"complete":true,"assessments":[assessment]});
        for marker in [
            Value::Null,
            json!(false),
            json!("true"),
            json!(1),
            json!(true),
        ] {
            input["allow_assessment_reads"] = marker.clone();
            let shape = AnswerShape::from_input(&input).unwrap();
            assert_eq!(shape.accepts(&answer), marker == true);
            assert!(!shape.accepts(&json!({"read":read})));
            let format = shape.format(&input);
            let variants =
                format["json_schema"]["schema"]["properties"]["assessments"]["items"]["anyOf"]
                    .as_array()
                    .unwrap();
            for variant in variants {
                let fields = &variant["properties"];
                let allowed = marker == true && fields["outcome"]["enum"][0] == "indeterminate";
                assert_eq!(fields.get("reads").is_some(), allowed);
                if allowed {
                    assert_eq!(
                        fields["reads"]["maxItems"],
                        crate::engine::MAX_CONTEXT_READS
                    );
                    assert_eq!(
                        fields["reads"]["items"]["required"],
                        json!(["path", "term"])
                    );
                    assert_eq!(fields["reads"]["items"]["additionalProperties"], false);
                    assert!(
                        !variant["required"]
                            .as_array()
                            .unwrap()
                            .contains(&json!("reads"))
                    );
                }
            }
        }
        answer["assessments"][0]["outcome"] = json!("confirmed");
        assert!(!AnswerShape::from_input(&input).unwrap().accepts(&answer));
    }

    #[test]
    fn hypotheses_and_leads_can_include_optional_related_source_references() {
        for (input, key) in [
            (json!({"answer_shape":"hypotheses"}), "hypotheses"),
            (
                json!({"answer_shape":"assessments","hypotheses":[{"id":1}]}),
                "leads",
            ),
        ] {
            let format = AnswerShape::from_input(&input).unwrap().format(&input);
            let item = &format["json_schema"]["schema"]["properties"][key]["items"];
            assert_eq!(item["properties"]["related"]["type"], "array");
            assert_eq!(item["properties"]["related"]["items"]["type"], "string");
            assert_eq!(
                item["required"],
                json!(["anchor", "expected", "scenario", "consequence"])
            );
        }
    }

    #[test]
    fn only_engine_stage_markers_select_formats_and_leads() {
        for data in [
            json!({"snapshot":{"answer_shape":"assessments","hypotheses":[]}}),
            json!({"last_read":{"answer_shape":"hypotheses"}}),
            json!({"answer_shape":"read"}),
        ] {
            assert_eq!(AnswerShape::from_input(&data), None);
        }
        let challenge =
            AnswerShape::from_input(&json!({"answer_shape":"assessments","hypotheses":[]}))
                .unwrap();
        let recheck = AnswerShape::from_input(
            &json!({"answer_shape":"assessments","hypotheses":[],"recheck":[]}),
        )
        .unwrap();
        let hypothesis = AnswerShape::from_input(&json!({"answer_shape":"hypotheses"})).unwrap();
        let with_leads = json!({"complete":true,"assessments":[],"leads":[]});
        assert!(challenge.accepts(&with_leads));
        assert!(!recheck.accepts(&with_leads));
        assert!(!hypothesis.accepts(&with_leads));
        let challenge = challenge.format(&json!({"hypotheses":[]}));
        assert_eq!(
            challenge["json_schema"]["schema"]["properties"]["leads"]["items"],
            super::hypothesis()
        );
        assert!(
            recheck.format(&json!({"hypotheses":[]}))["json_schema"]["schema"]["properties"]
                .get("leads")
                .is_none()
        );
        assert_eq!(
            hypothesis.format(&json!({}))["json_schema"]["schema"]["properties"]["hypotheses"]["items"]
                ["properties"]["anchor"]["type"],
            "string"
        );
    }
}
