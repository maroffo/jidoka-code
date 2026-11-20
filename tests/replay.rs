// Expected reports come from jidoka.engine.review at Python pilot commit 75700b6.
use jidoka_code::{
    contracts::{Scan, Snapshot},
    engine,
};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct Case {
    name: String,
    snapshot: Snapshot,
    scan: Scan,
    replies: Vec<Value>,
    expected: Value,
}

#[test]
fn replays_complete_python_reports_without_scanner_signals() {
    let cases: Vec<Case> =
        serde_json::from_str(include_str!("fixtures/pilot-replay.json")).unwrap();
    for case in cases {
        let mut replies = case.replies.into_iter();
        let report = engine::review(&case.snapshot, &case.scan, |_, _| {
            Ok(replies
                .next()
                .unwrap_or_else(|| panic!("{}: unexpected provider call", case.name)))
        })
        .unwrap_or_else(|error| panic!("{}: {error}", case.name));
        assert!(
            replies.next().is_none(),
            "{}: unused provider reply",
            case.name
        );
        assert_eq!(
            serde_json::to_value(report).unwrap(),
            case.expected,
            "{}",
            case.name
        );
    }
}
