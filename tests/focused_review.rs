use jidoka_code::{
    contracts::{Snapshot, SourceFile, SourceWindow},
    review_snapshot_iterative,
};
use serde_json::{Value, json};

const RULE: &str = "A one-slot pool must admit exactly one worker.";
const CAPACITY: &str = "fn capacity(slots: usize) -> usize { slots.saturating_sub(1) }";
const EXPORT: &str = "const EXPORT_ENABLED: bool = true;";
const AUDIT: &str = "fn publish(audit: &Audit) { if audit.redacted() { audit.send(); } }";
const DISTANT: &str = "// Distant change to replica maintenance.";
const UNRELATED: &str = "Archived accounting note";

fn added_file(path: &str, text: String) -> SourceFile {
    let rows: String = text.lines().map(|line| format!("+{line}\n")).collect();
    SourceFile {
        path: path.into(),
        patch: format!("@@ -0,0 +1,{} @@\n{rows}", text.lines().count()),
        before: String::new(),
        after: text,
    }
}

fn reference(data: &Value, path: &str, quote: &str) -> String {
    let snapshot = &data["snapshot"];
    let files = snapshot["files"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|f| f["path"] == path)
        .flat_map(|f| f["sections"].as_array().unwrap())
        .flat_map(|section| section.as_array().unwrap());
    let windows = snapshot["head_context"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|w| w["path"] == path)
        .flat_map(|w| w["rows"].as_array().unwrap());
    let row = files
        .chain(windows)
        .find(|row| row[2] == quote)
        .unwrap_or_else(|| panic!("Missing head citation for {path}: {quote}"));
    row[1].as_str().unwrap().into()
}

fn model_reply(data: &Value) -> Value {
    let Some(hypotheses) = data["hypotheses"].as_array() else {
        let questions = [
            ("pool.rs", CAPACITY, "A caller asks for one worker."),
            ("policy.rs", EXPORT, "The deployment enables export."),
            ("audit.rs", AUDIT, "An audit record is published."),
        ];
        let proposals = questions.map(|(path, quote, scenario)| {
            json!({
                "anchor":reference(data,path,quote),"expected":"Honor the documented policy.",
                "scenario":scenario,"consequence":"The caller could observe an incorrect result."
            })
        });
        return json!({"complete":true,"hypotheses":proposals});
    };
    let unknown = json!({
        "id":2,"outcome":"indeterminate",
        "countercheck":"The deployment permission for the export destination is unavailable in the repository."
    });
    if data.get("recheck").is_none() {
        assert_eq!(hypotheses.len(), 3);
        return json!({"complete":true,"assessments":[
            {"id":1,"outcome":"indeterminate","countercheck":"The capacity contract is outside the patch.",
             "reads":[{"path":"worker-contract.md","term":"one-slot"}]},
            unknown,
            {"id":3,"outcome":"refuted","basis":reference(data,"audit.rs",AUDIT),
             "countercheck":"The audit is sent only after its redaction check."}
        ]});
    }
    let ids: Vec<_> = hypotheses
        .iter()
        .map(|h| h["id"].as_u64().unwrap())
        .collect();
    assert_eq!(ids, [1, 2]);
    json!({"complete":true,"assessments":[
        {"id":1,"outcome":"confirmed","kind":"contract","severity":"high","title":"One-slot pools admit no workers",
         "basis":reference(data,"worker-contract.md",RULE),"support":[],"comparison":null,
         "impact":"A caller asking for a single worker receives zero capacity.",
         "reason":"Subtracting one from a one-slot request returns zero.",
         "countercheck":"The capacity expression subtracts directly from slots.",
         "counterevidence":{"references":[reference(data,"pool.rs",CAPACITY)],"absence_paths":[]}},
        unknown
    ]})
}

#[test]
fn focused_requests_keep_pinned_proof_and_report_unresolved_coverage() {
    let mut files = vec![
        added_file(
            "pool.rs",
            format!(
                "{CAPACITY}\n{}{DISTANT}\n",
                "// Replica operation.\n".repeat(150)
            ),
        ),
        added_file("policy.rs", format!("{EXPORT}\n")),
        added_file("audit.rs", format!("{AUDIT}\n")),
    ];
    for n in 0..64 {
        files.push(added_file(
            &format!("archive-{n}.md"),
            format!("{UNRELATED} {n}\n"),
        ));
    }
    let count = files.len();
    let snapshot: Snapshot = serde_json::from_value(json!({
        "repo":"example/workers","url":"https://github.com/example/workers/pull/1",
        "number":1,"base":"base","head":"pinned","files":files,"intent":[],"limits":[]
    }))
    .unwrap();
    let mut calls = 0;
    let mut reads = 0;
    let result = review_snapshot_iterative(
        snapshot,
        |_, data| {
            calls += 1;
            let text = data.to_string();
            let discovery = data.get("hypotheses").is_none();
            assert_eq!(text.contains(UNRELATED), discovery);
            assert_eq!(text.contains(DISTANT), discovery);
            assert_eq!(text.contains(AUDIT), data.get("recheck").is_none());
            let complete = data["snapshot"]["complete_head_paths"].as_array().unwrap();
            assert_eq!(complete.iter().any(|p| p == "pool.rs"), discovery);
            if discovery {
                assert_eq!(data["snapshot"]["files"].as_array().unwrap().len(), count);
                assert!(!text.contains(RULE));
            }
            Ok(model_reply(data))
        },
        |full, requests| {
            assert_eq!(full.head, "pinned");
            assert_eq!(full.files.len(), count);
            assert_eq!(requests.len(), 1);
            assert_eq!(
                (requests[0].path.as_str(), requests[0].term.as_str()),
                ("worker-contract.md", "one-slot")
            );
            reads += 1;
            Ok(vec![SourceWindow {
                path: "worker-contract.md".into(),
                start: 1,
                text: RULE.into(),
            }])
        },
        |_, data| {
            if data.get("hypotheses").is_some() {
                assert!(
                    !data.to_string().contains(UNRELATED),
                    "Context sizing included unrelated source"
                );
            }
            Ok(true)
        },
        &[],
    )
    .unwrap();
    assert_eq!((calls, reads), (3, 1));
    assert_eq!(result.report.findings.len(), 1);
    let jidoka_code::contracts::FindingEvidence::Text(proof) = &result.report.findings[0].evidence
    else {
        panic!("expected archived evidence")
    };
    assert!(proof.contains(&format!("pool.rs:1 “{CAPACITY}”")));
    assert!(proof.contains(&format!("worker-contract.md:1 “{RULE}”")));
    assert_eq!(result.reviewed_files.as_ref().unwrap().len(), count - 1);
    assert_eq!(result.unfinished_patches().unwrap(), ["policy.rs"]);
    assert_eq!(result.report.limits.len(), 1);
    assert!(result.report.limits[0].contains("deployment permission"));
}

#[test]
fn focused_review_can_reopen_deleted_rows_and_pinned_support_across_diff_pages() {
    let deleted: Vec<_> = (1..=40).map(|n| format!("old entry {n}")).collect();
    let contract = "A one-slot pool must admit exactly one worker.";
    let before = "fn capacity(slots: usize) -> usize { slots }";
    let files = json!([
        {"path":"pool.rs","before":before,"after":CAPACITY,"patch":format!("@@ -1 +1 @@\n-{before}\n+{CAPACITY}")},
        {"path":"removed.md","before":deleted.join("\n"),"after":"","patch":format!("@@ -1,40 +0,0 @@\n{}",deleted.iter().map(|s| format!("-{s}")).collect::<Vec<_>>().join("\n"))},
        {"path":"retained.md","before":"Old safeguard.\nOther section.","after":"Other section.","patch":"@@ -1 +0,0 @@\n-Old safeguard."},
        {"path":"policy.md","before":contract,"after":contract,"patch":""}
    ]);
    let snapshot: Snapshot = serde_json::from_value(json!({
        "repo":"example/workers","url":"https://github.com/example/workers/pull/1",
        "number":1,"base":"base","head":"pinned","files":files,"intent":[],"limits":[]
    }))
    .unwrap();
    let mut turns = 0;
    let mut last_deletion = Value::Null;
    let result = review_snapshot_iterative(snapshot, |_, data| {
        turns += 1;
        let files = data["snapshot"]["files"].as_array().unwrap();
        let file = |path| files.iter().find(|f| f["path"] == path).unwrap();
        let anchor = reference(data,"pool.rs",CAPACITY);
        let pending = |reads:Value| json!({"complete":true,"assessments":[{"id":1,"outcome":"indeterminate","countercheck":"Compare the removed safeguards and the pinned capacity contract.","reads":reads}]});
        Ok(match turns {
            1 => {
                last_deletion = file("removed.md")["sections"][0][39].clone();
                json!({"complete":true,"hypotheses":[{"anchor":anchor,"expected":"A requested worker is available.","scenario":"A pool is given one slot.","consequence":"No worker can enter."}]})
            }
            2 => {
                assert_eq!(files.len(), 1);
                assert_eq!(data["snapshot"]["supporting_paths"], json!(["policy.md"]));
                pending(json!([{"path":"removed.md","term":"#diff"},{"path":"retained.md","term":"#diff"},{"path":"policy.md","term":"#diff"}]))
            }
            3 => {
                let deleted = &file("removed.md")["sections"][0];
                assert_eq!(deleted.as_array().unwrap().len(),32);
                assert!(deleted[0][0].is_string() && deleted[0][1].is_null());
                assert!(!data.to_string().contains("old entry 40"));
                assert_eq!(file("retained.md")["sections"][0][0][2],"Old safeguard.");
                assert_eq!(file("policy.md")["scope"],"file");
                let page = data["snapshot"]["diff_pages"].as_array().unwrap().iter()
                    .find(|p| p["path"]=="removed.md").unwrap();
                pending(json!([{"path":"removed.md","term":page["next"]}]))
            }
            4 => {
                assert_eq!(file("removed.md")["sections"][0][39],last_deletion);
                let rule = &file("policy.md")["sections"][0][0];
                let old = &file("pool.rs")["sections"][0][0][0];
                json!({"complete":true,"assessments":[{"id":1,"outcome":"confirmed","kind":"contract","severity":"high","title":"One-slot pools admit no workers", "basis":rule[1],"support":[],"comparison":{"behavior":old,"basis":rule[0],"affected":false},"impact":"No worker can enter a pool with one slot.","reason":"The new calculation subtracts one even when only one slot is requested.","countercheck":"The old capacity calculation accepted the single slot.","counterevidence":{"references":[anchor],"absence_paths":[]}}]})
            }
            _ => panic!("Unexpected review turn {turns}"),
        })
    }, |_,_| panic!("Indexed diff reads must not consult the head tree"), |_,_| Ok(true), &[]).unwrap();
    assert_eq!(turns, 4);
    assert!(
        result.report.limits.is_empty(),
        "{:?}",
        result.report.limits
    );
    assert_eq!(result.report.findings.len(), 1);
    assert_eq!(
        result.report.findings[0].attribution,
        jidoka_code::contracts::Attribution::Introduced
    );
    assert!(result.unfinished_patches().unwrap().is_empty());
}
