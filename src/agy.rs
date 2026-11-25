//! One Antigravity session for a pinned PR. The runner has its own OS environment.
use anyhow::{Context, Result, ensure};
use jidoka_code::{
    contracts::{Finding, PublishedReport, Report, Snapshot},
    diff,
    provider::TokenUsage,
    scanner,
    source::ReviewRepository,
    web::session::Session,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    env, fs,
    io::{ErrorKind, Read, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    time::{Duration, Instant},
};

pub struct Reviewer {
    model: String,
    label: String,
    jobs: PathBuf,
    socket: PathBuf,
}

impl Reviewer {
    pub fn from_env() -> Result<Self> {
        ensure!(
            env::var_os("JIDOKA_REVIEW_BUDGET_CENTS").is_none_or(|s| s.is_empty()),
            "AGY bills through its own account. Remove JIDOKA_REVIEW_BUDGET_CENTS to acknowledge that AGY cannot enforce this per-review spending limit."
        );
        let model = env::var("JIDOKA_MODEL").unwrap_or_else(|_| "Gemini 4 Carbon (High)".into());
        ensure!(
            !model.trim().is_empty() && model.len() <= 200 && !model.chars().any(char::is_control),
            "Invalid AGY model name"
        );
        Ok(Self {
            label: format!("Antigravity CLI · {model}"),
            model,
            jobs: env::var_os("JIDOKA_AGY_JOBS").map_or_else(|| "/jobs".into(), PathBuf::from),
            socket: env::var_os("JIDOKA_AGY_SOCKET")
                .map_or_else(|| "/control/agy.sock".into(), PathBuf::from),
        })
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn review(
        &self,
        session: &mut Session,
        snapshot: Snapshot,
        repository: &ReviewRepository,
        prior: &[Finding],
        mut eligible: impl FnMut() -> Result<()>,
    ) -> Result<PublishedReport> {
        let scan = scanner::scan(&snapshot);
        let mut output = PublishedReport {
            repo: snapshot.repo,
            base: snapshot.base,
            head: snapshot.head,
            patch_files: Some(
                snapshot
                    .files
                    .iter()
                    .filter(|f| !f.patch.is_empty())
                    .map(|f| f.path.clone())
                    .collect(),
            ),
            reviewed_files: Some(Vec::new()),
            diff: snapshot.diff,
            scan: Some(scan),
            report: Report {
                limits: snapshot.limits,
                ..Default::default()
            },
        };
        if output.patch_files.as_ref().is_none_or(Vec::is_empty) {
            output
                .report
                .limits
                .push("No reviewable text patch was available.".into());
            return Ok(output);
        }
        let job = tempfile::Builder::new()
            .prefix("review-")
            .tempdir_in(self.jobs.canonicalize()?)?;
        let directory = job.path();
        repository.export_head(&directory.join("source"))?;
        let input = json!({"base":output.base,"head":output.head,"intent":snapshot.intent,
            "changed_files":output.diff,"previous_findings":prior,
            "semgrep":output.scan.as_ref().map(|scan| &scan.signals)});
        fs::write(directory.join("review.json"), serde_json::to_vec(&input)?)?;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o755))?;
        eligible()?;
        // Connect before claiming: an unavailable runner has made no chargeable call.
        let ready_by = Instant::now() + Duration::from_secs(75);
        let stream = loop {
            match UnixStream::connect(&self.socket) {
                Ok(stream) => break stream,
                Err(e)
                    if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::ConnectionRefused)
                        && Instant::now() < ready_by =>
                {
                    eligible()?;
                    std::thread::sleep(Duration::from_millis(500));
                }
                Err(e) => return Err(e).context("AGY runner unavailable"),
            }
        };
        if !session.claim_agy()? {
            output.report.limits.push(
                "An earlier AGY invocation was interrupted. Replay this review to run it again."
                    .into(),
            );
            return Ok(output);
        }
        let started = Instant::now();
        let name = directory
            .file_name()
            .and_then(|s| s.to_str())
            .context("Invalid review directory")?;
        let result = exchange(stream, name, &self.model, &mut eligible);
        eligible()?;
        let envelope = result
            .ok()
            .and_then(|raw| serde_json::from_slice::<Envelope>(&raw).ok());
        let usage = envelope.as_ref().and_then(|e| e.usage.as_ref());
        session.record_agy_usage(
            TokenUsage {
                input: usage.and_then(|u| u.input_tokens),
                output: usage.and_then(|u| u.output_tokens),
                cached: usage.and_then(|u| u.cache_read_tokens),
            },
            started.elapsed().as_millis().try_into().unwrap_or(i64::MAX),
        )?;
        apply_verdict(&mut output, envelope);
        Ok(output)
    }
}

fn exchange(
    mut stream: UnixStream,
    job: &str,
    model: &str,
    mut eligible: impl FnMut() -> Result<()>,
) -> Result<Vec<u8>> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    writeln!(stream, "{job}\n{model}")?;
    let mut raw = Vec::new();
    let mut block = [0u8; 16384];
    let deadline = Instant::now() + Duration::from_secs(40 * 60);
    loop {
        ensure!(Instant::now() < deadline, "AGY runner timed out");
        match stream.read(&mut block) {
            Ok(0) => return Ok(raw),
            Ok(n) => {
                ensure!(
                    raw.len() + n <= 8 * 1024 * 1024,
                    "AGY result exceeds the response limit"
                );
                raw.extend_from_slice(&block[..n]);
            }
            Err(e)
                if matches!(
                    e.kind(),
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                ) =>
            {
                eligible()?
            }
            Err(e) => return Err(e.into()),
        }
    }
}

#[derive(Deserialize)]
struct Usage {
    input_tokens: Option<u64>,
    output_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct Envelope {
    status: String,
    reason: Option<String>,
    usage: Option<Usage>,
    structured_output: Option<Value>,
    #[serde(default)]
    denied_actions: Vec<Value>,
}

#[derive(Deserialize)]
struct Verdict {
    reviewed_files: Vec<String>,
    findings: Vec<CitedFinding>,
    focus: Vec<jidoka_code::contracts::Focus>,
    limits: Vec<String>,
}

#[derive(Deserialize)]
struct CitedFinding {
    #[serde(flatten)]
    finding: Finding,
    quote: String,
    countercheck: String,
}

fn apply_verdict(output: &mut PublishedReport, envelope: Option<Envelope>) {
    if envelope.as_ref().and_then(|e| e.reason.as_deref()) == Some("credentials") {
        output
            .report
            .limits
            .push("AGY could not authenticate. Check the reviewer ADC and Cloud project.".into());
        return;
    }
    let Some(verdict) = envelope
        .filter(|e| e.status == "SUCCESS" && e.denied_actions.is_empty())
        .and_then(|e| e.structured_output)
        .and_then(|v| serde_json::from_value::<Verdict>(v).ok())
    else {
        output.report.limits.push("AGY did not return a successful structured verdict. See the runner status before replaying.".into());
        return;
    };
    let expected = output.patch_files.as_deref().unwrap_or_default();
    let mut seen = HashSet::new();
    let coverage: Vec<_> = verdict
        .reviewed_files
        .into_iter()
        .filter(|path| expected.contains(path) && seen.insert(path.clone()))
        .collect();
    if coverage.len() != expected.len() {
        output
            .report
            .limits
            .push("AGY did not confirm reviewing every changed text file.".into());
    }
    output.reviewed_files = Some(coverage);
    output.report.limits.extend(verdict.limits);
    for cited in verdict.findings {
        let mut finding = cited.finding;
        if !diff::matches_quote(output, &finding.path, finding.line, &cited.quote)
            || cited.countercheck.trim().is_empty()
            || [&finding.title, &finding.impact, &finding.evidence]
                .iter()
                .any(|s| s.trim().is_empty())
        {
            output.report.limits.push(
                "An AGY finding lacked a valid patch reference or supporting evidence.".into(),
            );
        } else {
            finding.evidence.push_str("\nCountercheck: ");
            finding.evidence.push_str(cited.countercheck.trim());
            output.report.findings.push(finding);
        }
    }
    for focus in verdict.focus {
        if diff::anchor(output, &focus.path, focus.line).is_some()
            && [&focus.checked, &focus.outcome, &focus.action]
                .iter()
                .all(|s| !s.trim().is_empty())
        {
            output.report.focus.push(focus);
        } else {
            output
                .report
                .limits
                .push("An AGY manual check lacked a valid patch reference or instructions.".into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jidoka_code::contracts::{DiffFile, PinnedDiff};

    fn run(status: &str, content: Value) -> PublishedReport {
        let mut report = PublishedReport {
            repo: "o/r".into(),
            base: "a".into(),
            head: "b".into(),
            report: Report::default(),
            scan: None,
            patch_files: Some(vec!["x.rs".into()]),
            reviewed_files: Some(vec![]),
            diff: Some(PinnedDiff {
                total_files: 1,
                files: vec![DiffFile {
                    path: "x.rs".into(),
                    status: "modified".into(),
                    previous_path: None,
                    patch: Some("@@ -1 +1 @@\n-old\n+new\n".into()),
                }],
                supporting_paths: vec![],
            }),
        };
        apply_verdict(
            &mut report,
            Some(Envelope {
                status: status.to_owned(),
                reason: None,
                usage: None,
                structured_output: Some(content),
                denied_actions: vec![],
            }),
        );
        report
    }
    #[test]
    fn complete_requires_terminal_success_coverage_and_exact_citations() {
        let mut v = json!({"reviewed_files":["x.rs"],"findings":[{"path":"x.rs","line":1,"title":"Title","impact":"Impact","evidence":"Evidence","attribution":"introduced","quote":"new","countercheck":"Checked the caller."}],"focus":[],"limits":[]});
        let report = run("SUCCESS", v.clone());
        assert!(!report.is_partial());
        assert_eq!(report.report.findings.len(), 1);
        assert!(run("ERROR", v.clone()).is_partial());
        assert!(run("SUCCESS", Value::Null).is_partial());
        v["reviewed_files"] = json!([]);
        assert!(run("SUCCESS", v.clone()).is_partial());
        v["reviewed_files"] = json!(["x.rs"]);
        v["findings"][0]["quote"] = json!("old");
        let rejected = run("SUCCESS", v);
        assert!(rejected.is_partial());
        assert!(rejected.report.findings.is_empty());
    }

    #[test]
    fn paid_invocation_survives_reopen_and_base_reset() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("db");
        jidoka_code::web::recover(&db, "agy").unwrap();
        let mut session = Session::open(&db, 1).unwrap();
        assert!(session.claim_agy().unwrap());
        drop(session);
        let mut resumed = Session::open(&db, 1).unwrap();
        resumed.reset().unwrap();
        assert!(!resumed.claim_agy().unwrap());
        assert!(Session::open(&db, 2).unwrap().claim_agy().unwrap());
    }
}
