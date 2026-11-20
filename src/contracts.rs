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
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Focus {
    pub path: String,
    pub line: usize,
    pub checked: String,
    pub outcome: String,
    pub action: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Finding {
    pub path: String,
    pub line: usize,
    pub title: String,
    pub impact: String,
    pub evidence: String,
    pub attribution: Attribution,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Attribution {
    Introduced,
    Preexisting,
    Unknown,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Report {
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<PinnedDiff>,
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
