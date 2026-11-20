// Decision-level parity with the Python pilot at 75700b6 on identical model replies.
use jidoka_code::{
    contracts::{Scan, Snapshot},
    engine,
};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Case {
    name: String,
    snapshot: Snapshot,
    scan: Scan,
    replies: Vec<Value>,
    expected: Value,
}

#[test]
fn replay_pilot_decisions_without_language_rules() {
    let cases: Vec<Case> =
        serde_json::from_str(include_str!("fixtures/pilot-replay.json")).unwrap();
    for case in cases {
        let mut replies = case.replies.into_iter();
        let report = engine::review(&case.snapshot, &case.scan, |_, _| {
            Ok(replies.next().expect("unexpected provider call"))
        })
        .unwrap();
        assert!(replies.next().is_none());
        let result = json!({
            "findings":report.findings.iter().map(|f|json!([f.path,f.line,f.attribution])).collect::<Vec<_>>(),
            "focus":report.focus.iter().map(|f|json!([f.path,f.line,f.action])).collect::<Vec<_>>(),
            "partial":!report.limits.is_empty()
        });
        assert_eq!(result, case.expected, "{}", case.name);
    }
}
