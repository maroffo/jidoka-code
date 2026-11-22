pub mod automation;
pub mod contracts;
pub mod diff;
pub mod engine;
pub(crate) mod hunks;
pub mod provider;
pub mod publish;
pub mod scanner;
pub mod source;
pub mod web;

use anyhow::Result;
use contracts::{ContextRead, Finding, PublishedReport, Snapshot, SourceWindow};
use serde_json::Value;

/// Run the same review protocol for every collected text snapshot.
pub fn review_snapshot(
    snapshot: Snapshot,
    ask: impl FnMut(&str, &Value) -> Result<Value>,
) -> Result<PublishedReport> {
    review_snapshot_with_context(snapshot, ask, |_, _| Ok(Vec::new()), &[])
}

pub fn review_snapshot_with_context(
    snapshot: Snapshot,
    ask: impl FnMut(&str, &Value) -> Result<Value>,
    mut read: impl FnMut(&Snapshot, &[ContextRead]) -> Result<Vec<SourceWindow>>,
    prior: &[Finding],
) -> Result<PublishedReport> {
    let scan = scanner::scan(&snapshot);
    let report = engine::review_with_history(
        &snapshot,
        &scan,
        ask,
        |requests| read(&snapshot, requests),
        prior,
    )?;
    Ok(PublishedReport {
        repo: snapshot.repo,
        base: snapshot.base,
        head: snapshot.head,
        report,
        scan: Some(scan),
        diff: snapshot.diff,
        reviewed_files: None,
        patch_files: Some(
            snapshot
                .files
                .into_iter()
                .filter(|file| !file.patch.is_empty())
                .map(|file| file.path)
                .collect(),
        ),
    })
}

pub use engine::{ReviewContextExceeded, ReviewTurnLimit, review_snapshot_iterative};
