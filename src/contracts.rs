use std::collections::HashSet;

use serde::{Deserialize, Serialize};

/// Maximum combined size of patches and optional source text in a snapshot.
pub(crate) const SNAPSHOT_TEXT_BYTES: usize = 96_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourceFile {
    pub path: String,
    pub patch: String,
    pub before: String,
    pub after: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContextRead {
    pub path: String,
    pub term: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourceWindow {
    pub path: String,
    /// The 1-based head line at which this exact source text starts.
    pub start: usize,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiffFile {
    pub path: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PinnedDiff {
    pub total_files: u64,
    pub files: Vec<DiffFile>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub supporting_paths: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub url: String,
    pub repo: String,
    pub number: u64,
    pub base: String,
    pub head: String,
    pub intent: Vec<String>,
    pub files: Vec<SourceFile>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub head_context: Vec<SourceWindow>,
    pub limits: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<PinnedDiff>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Signal {
    pub rule: String,
    pub path: String,
    pub line: usize,
    pub message: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Scan {
    pub signals: Vec<Signal>,
    pub limits: Vec<String>,
    pub version: String,
    pub covered: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Focus {
    pub path: String,
    pub line: usize,
    pub checked: String,
    pub outcome: String,
    pub action: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Finding {
    pub path: String,
    pub line: usize,
    pub title: String,
    pub impact: String,
    pub evidence: String,
    pub attribution: Attribution,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Attribution {
    Introduced,
    Preexisting,
    Unknown,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SandboxTest {
    pub argv: Vec<String>,
    pub status: String,
    pub exit_code: Option<i32>,
    pub seconds: Option<u64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Report {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
    /// None distinguishes older reviews without execution records.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests: Option<Vec<SandboxTest>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dry_run: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mergeability_score: Option<u8>,
    pub focus: Vec<Focus>,
    pub findings: Vec<Finding>,
    pub limits: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublishedReport {
    pub repo: String,
    pub base: String,
    pub head: String,
    #[serde(flatten)]
    pub report: Report,
    #[serde(default)]
    pub scan: Option<Scan>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch_files: Option<Vec<String>>,
    /// Collected files whose changed hunks reached the end of the model review.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewed_files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<PinnedDiff>,
}

/// The lowest mergeability score that recommends merging.
pub const MERGE_READY: u8 = 90;

/// How many human follow-ups a report lists, on the page and in the GitHub summary.
pub const MANUAL_CHECKS: usize = 3;

/// The one signal shown for a finished review, wherever it appears.
///
/// `partial` is the displayed state, which also covers a stored status the report itself
/// does not explain. A score only counts for a complete review.
pub fn outcome_tone(partial: bool, score: Option<u8>, findings: usize) -> &'static str {
    match (partial, score) {
        (true, _) if findings == 0 => "hold",
        (false, Some(score)) if score >= MERGE_READY => "clear",
        (false, None) if findings == 0 => "clear",
        _ => "stop",
    }
}

impl PublishedReport {
    /// Older and incomplete reviews do not have a merge recommendation.
    pub fn score(&self) -> Option<u8> {
        self.report
            .mergeability_score
            .filter(|&n| n <= 100 && !self.is_partial())
    }

    pub fn mergeability_label(&self) -> Option<String> {
        let score = self.score()?;
        let decision = if score >= MERGE_READY {
            "Ready to merge"
        } else {
            "Hold merge"
        };
        Some(format!("Mergeability: {score}/100 · {decision}"))
    }

    pub fn is_partial(&self) -> bool {
        !self.report.limits.is_empty()
            || self
                .scan
                .as_ref()
                .is_some_and(|scan| !scan.limits.is_empty())
    }

    /// Available only for reviews that tracked completion of each collected patch.
    pub fn unfinished_patches(&self) -> Option<Vec<&String>> {
        let reviewed: HashSet<_> = self.reviewed_files.as_ref()?.iter().collect();
        Some(
            self.patch_files
                .as_ref()?
                .iter()
                .filter(|path| !reviewed.contains(path))
                .collect(),
        )
    }

    /// The human follow-ups a report page shows, capped so the list stays actionable.
    pub fn manual_checks(&self) -> impl Iterator<Item = &Focus> {
        self.human_focus().take(MANUAL_CHECKS)
    }

    /// Return distinct human follow-ups in report order, including for older saved reports.
    pub fn human_focus(&self) -> impl Iterator<Item = &Focus> {
        let mut seen = HashSet::new();
        self.report.focus.iter().filter(move |focus| {
            !focus.action.trim().is_empty()
                && !focus.checked.trim().is_empty()
                && !self.report.findings.iter().any(|finding| {
                    finding.path == focus.path
                        && finding.line == focus.line
                        && finding.impact.trim() == focus.outcome.trim()
                })
                // Older engines also kept confirmed priorities whose finding was deduplicated.
                && ![
                    "Documented behavior in ",
                    "Project rule in ",
                    "Static performance analysis in ",
                    "Comportamento documentato in ",
                    "Regola di progetto in ",
                    "Analisi statica delle prestazioni in ",
                ]
                .iter()
                .any(|prefix| focus.checked.trim_start().starts_with(prefix))
                && seen.insert(*focus)
        })
    }
}

/// Safe, operator-facing reason when GitHub's public API quota is exhausted.
#[derive(Debug)]
pub struct GitHubRateLimit;

impl std::fmt::Display for GitHubRateLimit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("GitHub API rate limit reached. Try again after the limit resets.")
    }
}
impl std::error::Error for GitHubRateLimit {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn legacy_focus_omits_finding_actions_and_exact_duplicates_only() {
        let follow_up = json!({
            "path": "client.ts", "line": 4, "checked": "Read the retry handler.",
            "outcome": "Retry timing needs a runtime check.", "action": "Run a timeout test."
        });
        let mut another = follow_up.clone();
        another["action"] = json!("Run an interrupted connection test.");
        let report: PublishedReport = serde_json::from_value(json!({
            "repo": "team/example", "base": "base", "head": "head", "limits": [],
            "findings": [{
                "path": "client.ts", "line": 4, "title": "Missing error handler",
                "impact": "The failure is swallowed.", "evidence": "Source evidence.",
                "attribution": "introduced"
            }],
            "focus": [
                {
                    "path": "client.ts", "line": 4, "checked": "Read the error handler.",
                    "outcome": "The failure is swallowed. ", "action": "Propagate the error."
                },
                {
                    "path": "client.ts", "line": 12, "checked": "Project rule in docs.md:1.",
                    "outcome": "The fallback hides a crash.", "action": "Fix the fallback."
                },
                follow_up.clone(), follow_up, another
            ]
        }))
        .unwrap();
        let actions: Vec<_> = report
            .human_focus()
            .map(|item| item.action.as_str())
            .collect();
        assert_eq!(
            actions,
            ["Run a timeout test.", "Run an interrupted connection test."]
        );
        assert_eq!(report.report.focus.len(), 5);
    }
}
