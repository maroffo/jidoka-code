use jidoka_code::{
    contracts::{Snapshot, SourceFile},
    engine::review_snapshot_with_planner,
    provider::{ModelReply, TokenUsage},
    web::{self, session::Session},
};
use serde_json::{Value, json};

fn model_reply(data: &Value, final_turn: bool) -> ModelReply {
    let rows = &data["snapshot"]["files"][0]["sections"][0];
    let contract = &rows[0][1];
    let implementation = &rows[1][1];
    let value = if final_turn {
        assert_eq!(data["hypotheses"][0]["id"], 1);
        json!({"complete":true,"assessments":[{
            "id":1, "outcome":"confirmed", "kind":"contract", "severity":"high",
            "title":"One-slot pools admit no workers", "basis":contract,
            "support":[], "comparison":null, "impact":"A one-slot pool cannot run its worker.",
            "reason":"Subtracting one from the requested capacity returns zero.",
            "countercheck":"For one slot the subtraction evaluates to zero before the worker starts.",
            "counterevidence":{"references":[implementation], "absence_paths":[]}
        }]})
    } else {
        assert_eq!(data["answer_shape"], "hypotheses");
        json!({"complete":true,"hypotheses":[{
            "anchor":implementation, "expected":"Keep the one requested worker.",
            "scenario":"The caller requests a one-slot pool.",
            "consequence":"The queue could stop accepting work."
        }]})
    };
    ModelReply {
        value,
        usage: TokenUsage::default(),
    }
}

fn pool_patch() -> Snapshot {
    let contract = "// A one-slot pool must admit one worker.";
    let line = "return workers.saturating_sub(1);";
    Snapshot {
        url: "https://github.com/test/pool/pull/1".into(),
        repo: "test/pool".into(),
        number: 1,
        base: "a".repeat(40),
        head: "b".repeat(40),
        intent: vec![],
        limits: vec![],
        head_context: vec![],
        diff: None,
        files: vec![SourceFile {
            path: "pool.rs".into(),
            patch: format!("@@ -0,0 +1,2 @@\n+{contract}\n+{line}\n"),
            before: String::new(),
            after: format!("{contract}\n{line}\n"),
        }],
    }
}

#[test]
fn the_last_dollars_close_the_review_and_replay_without_a_second_generation() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("reviews.sqlite3");
    web::recover(&path, "fixture").unwrap();
    let snapshot = pool_patch();

    let mut sent = Vec::new();
    for run in 0..2 {
        let mut session = Session::open(&path, 1).unwrap();
        session.configure_budget(100, 50).unwrap();
        let report = review_snapshot_with_planner(
            snapshot.clone(),
            |system, data| {
                let final_turn = data["review_role"] == "final";
                session.ask_budgeted(
                    system,
                    data,
                    final_turn,
                    || Ok(()),
                    |available| Ok((available >= 50).then_some((50, ()))),
                    |()| {
                        assert_eq!(run, 0, "A resumed review repeated a generation");
                        sent.push(if final_turn { "verdict" } else { "discovery" });
                        Ok(model_reply(data, final_turn))
                    },
                    |_| Some(50),
                )
            },
            |_, _| panic!("No lookup was funded"),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert_eq!(report.report.findings.len(), 1);
        assert_eq!(
            report.report.findings[0].title,
            "One-slot pools admit no workers"
        );
    }
    assert_eq!(sent, ["discovery", "verdict"]);
    let db = rusqlite::Connection::open(path).unwrap();
    assert_eq!(
        db.query_row(
            "SELECT spent FROM review_budgets WHERE review_id=1",
            [],
            |r| r.get::<_, u64>(0)
        )
        .unwrap(),
        100
    );
}

#[test]
fn an_unfunded_independent_check_preserves_its_budget_and_marks_the_patch_unreviewed() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("reviews.sqlite3");
    web::recover(&path, "fixture").unwrap();
    let mut session = Session::open(&path, 1).unwrap();
    session.configure_budget(100, 50).unwrap();
    let report = review_snapshot_with_planner(
        pool_patch(),
        |system, data| {
            session.ask_budgeted(
                system,
                data,
                data["review_role"] == "final",
                || Ok(()),
                |available| Ok((available >= 50).then_some((50, ()))),
                |()| {
                    let value = if data["answer_shape"] == "hypotheses" {
                        json!({"complete":true,"hypotheses":[]})
                    } else {
                        json!({"complete":true,"assessments":[]})
                    };
                    Ok(ModelReply {
                        value,
                        usage: TokenUsage::default(),
                    })
                },
                |_| Some(50),
            )
        },
        |_, _| panic!("No source reads expected"),
        |_, _| Ok(true),
        &[],
    )
    .unwrap();
    assert!(report.reviewed_files.unwrap().is_empty());
    assert!(
        report
            .report
            .limits
            .iter()
            .any(|s| s.to_lowercase().contains("budget"))
    );
    assert_eq!(session.budget_remaining(true).unwrap(), 50);
}
