pub mod contracts;
pub mod engine;
pub(crate) mod hunks;
pub mod provider;
pub mod scanner;
pub mod source;
pub mod web;

use anyhow::Result;
use contracts::{PublishedReport, Snapshot};
use serde_json::Value;

/// Run the same review protocol for every collected text snapshot.
pub fn review_snapshot(
    snapshot: Snapshot,
    ask: impl FnMut(&str, &Value) -> Result<Value>,
) -> Result<PublishedReport> {
    let scan = scanner::scan(&snapshot);
    let report = engine::review(&snapshot, &scan, ask)?;
    Ok(PublishedReport {
        repo: snapshot.repo,
        base: snapshot.base,
        head: snapshot.head,
        report,
        scan: Some(scan),
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
