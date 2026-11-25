//! One Antigravity session for a pinned PR. The runner has its own OS environment.
use anyhow::{Context, Result, ensure};
use jidoka_code::{
    contracts::{
        Finding, FindingEvidence, PublishedReport, Report, Snapshot, valid_review_location,
        valid_review_text,
    },
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

const JOB_SUFFIX_LEN: usize = 6;

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

    /// A single controller owns this volume. Recover checkouts left by a killed process.
    pub fn recover_jobs(&self) -> Result<fs::File> {
        let lock = fs::File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.jobs.join(".jidoka-worker.lock"))?;
        lock.try_lock()
            .context("Another controller owns the AGY jobs directory")?;
        for entry in fs::read_dir(&self.jobs)? {
            let entry = entry?;
            let name = entry.file_name();
            if entry.file_type()?.is_dir()
                && name
                    .to_str()
                    .and_then(|s| s.strip_prefix("review-"))
                    .is_some_and(|s| {
                        s.len() == JOB_SUFFIX_LEN && s.bytes().all(|c| c.is_ascii_alphanumeric())
                    })
            {
                fs::remove_dir_all(entry.path())?;
            }
        }
        Ok(lock)
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
        let interrupted =
            "An earlier AGY invocation was interrupted. Replay this review to run it again.";
        if session.agy_invoked()? {
            output.report.limits.push(interrupted.into());
            return Ok(output);
        }
        let job = tempfile::Builder::new()
            .prefix("review-")
            .rand_bytes(JOB_SUFFIX_LEN)
            .tempdir_in(self.jobs.canonicalize()?)?;
        let directory = job.path();
        repository.export_head(&directory.join("source"))?;
        let input = json!({"base":output.base,"head":output.head,"intent":snapshot.intent,
            "changed_files":output.diff,"previous_findings":prior,
            "semgrep":output.scan.as_ref().map(|scan| &scan.signals)});
        fs::write(
            directory.join("review-method.txt"),
            session.review_method()?,
        )?;
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
            output.report.limits.push(interrupted.into());
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
        apply_verdict(&mut output, envelope, |path, line| {
            repository.head_line(path, line)
        });
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
    #[serde(default)]
    tests: Option<Vec<jidoka_code::contracts::SandboxTest>>,
}

#[derive(Deserialize)]
struct Verdict {
    reviewed_files: Vec<String>,
    findings: Vec<Value>,
    focus: Vec<jidoka_code::contracts::Focus>,
    #[serde(default)]
    notes: Vec<String>,
    limits: Vec<String>,
}

#[derive(Deserialize)]
struct CitedFinding {
    #[serde(flatten)]
    finding: Finding,
    quote: String,
    #[serde(default)]
    mergeability_score: Value,
}

fn apply_verdict(
    output: &mut PublishedReport,
    mut envelope: Option<Envelope>,
    mut head_line: impl FnMut(&str, usize) -> Option<String>,
) {
    output.report.tests = envelope.as_mut().and_then(|e| e.tests.take());
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
    for limit in verdict.limits {
        if valid_review_text(&limit, 400) {
            output.report.limits.push(limit);
        } else {
            output
                .report
                .limits
                .push("AGY returned an invalid coverage limit.".into());
        }
    }
    for note in verdict.notes {
        if valid_review_text(&note, 400) {
            output.report.notes.push(note);
        } else {
            output
                .report
                .notes
                .push("An invalid reviewer note was omitted.".into());
        }
    }
    let mut score = 100;
    for value in verdict.findings {
        // A malformed finding should not erase valid siblings or the file coverage record.
        let Ok(cited) = serde_json::from_value::<CitedFinding>(value) else {
            output
                .report
                .limits
                .push("An AGY finding had malformed structured evidence.".into());
            continue;
        };
        let finding = cited.finding;
        let quote = cited.quote.strip_suffix('\r').unwrap_or(&cited.quote);
        let valid_quote = valid_review_location(&finding.path, finding.line)
            && valid_review_text(quote, 4096)
            && !quote.contains(['\n', '\r'])
            && (diff::matches_quote(output, &finding.path, finding.line, &cited.quote)
                || head_line(&finding.path, finding.line)
                    .is_some_and(|line| line == cited.quote.trim_end_matches('\r')));
        let valid_evidence = matches!(&finding.evidence, FindingEvidence::Structured(proof)
            if proof.valid(&finding.impact, |path, line|
                diff::anchor(output, path, line).is_some()
                    || diff::base_citation_path(output, path, line).is_some()
                    || head_line(path, line).is_some()));
        if !valid_quote
            || !valid_review_text(&finding.title, 400)
            || finding.title.contains(['\n', '\r', '\t'])
            || !valid_evidence
        {
            output.report.limits.push(
                "An AGY finding lacked a verified source line or supporting evidence.".into(),
            );
        } else {
            if let Some(rating) = cited.mergeability_score.as_u64().filter(|&n| n <= 100) {
                score = score.min(rating as u8);
            } else {
                output.report.limits.push(
                    "A verified finding lacks a valid mergeability score from 0 to 100.".into(),
                );
            }
            output.report.findings.push(finding);
        }
    }
    for focus in verdict.focus {
        if valid_review_location(&focus.path, focus.line)
            && [&focus.checked, &focus.outcome, &focus.action]
                .iter()
                .all(|s| valid_review_text(s, 400))
            && (diff::anchor(output, &focus.path, focus.line).is_some()
                || diff::base_citation_path(output, &focus.path, focus.line).is_some()
                || head_line(&focus.path, focus.line).is_some())
        {
            output.report.focus.push(focus);
        } else {
            output
                .report
                .limits
                .push("An AGY manual check lacked a verified source line or instructions.".into());
        }
    }
    if !output.is_partial() {
        output.report.mergeability_score = Some(score);
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
                tests: None,
            }),
            |_, _| None,
        );
        report
    }
    fn sample_finding() -> Value {
        json!({
            "path":"x.rs","line":1,"quote":"new","attribution":"introduced",
            "title":"Empty lists cannot be saved","impact":"Saving an empty list loses the draft.",
            "mergeability_score":89,
            "evidence":{
                "trigger":"[]",
                "steps":[{"explanation":"The caller sends an empty list.","path":"x.rs","line":1}],
                "test_gap":"The fixture always contains an item.",
                "countercheck":"The caller accepts empty lists."
            }
        })
    }

    #[test]
    fn invalid_evidence_marks_the_review_partial_and_keeps_valid_siblings() {
        let good = sample_finding();
        for (pointer, invalid) in [
            ("/evidence", json!("Old unstructured result")),
            ("/title", json!("t".repeat(401))),
            ("/title", json!("Invalid\nheading")),
            ("/impact", json!("Invalid\u{1b}impact")),
            ("/evidence/trigger", json!("t".repeat(601))),
            ("/evidence/test_gap", json!("g".repeat(401))),
            ("/evidence/countercheck", json!("c".repeat(401))),
            ("/evidence/steps/0/explanation", json!("e".repeat(241))),
            (
                "/evidence/steps/0/explanation",
                json!("Hidden\u{202e}direction"),
            ),
            ("/impact", json!("a".repeat(241))),
            ("/evidence/trigger", json!("   ")),
            ("/evidence/steps", json!([])),
            ("/evidence/steps/0/path", json!("../x.rs")),
            ("/evidence/steps/0/line", json!(2)),
            ("/evidence/steps/0/explanation", json!("")),
            ("/evidence/test_gap", Value::Null),
            ("/evidence/countercheck", json!("")),
        ] {
            let mut bad = good.clone();
            *bad.pointer_mut(pointer).unwrap() = invalid;
            let report = run(
                "SUCCESS",
                json!({"reviewed_files":["x.rs"],"findings":[bad, good],"focus":[],"limits":[]}),
            );
            assert!(report.is_partial(), "{pointer}");
            assert_eq!(report.report.findings.len(), 1, "{pointer}");
            assert_eq!(report.mergeability_label(), None);
        }
    }

    #[test]
    fn bounds_model_prose_before_storage_and_preserves_real_coverage_limits() {
        let allowed = "é".repeat(400);
        let over = format!("{allowed}é");
        let base = json!({"reviewed_files":["x.rs"], "findings":[], "focus":[],
                          "notes":[allowed, over], "limits":[]});
        let report = run("SUCCESS", base.clone());
        assert!(!report.is_partial());
        assert_eq!(
            report.report.notes,
            [allowed.as_str(), "An invalid reviewer note was omitted."]
        );
        let mut verdict = base;
        let formatted = "First paragraph.\r\n\tSecond paragraph.";
        verdict["limits"] = json!([formatted, over]);
        verdict["focus"] = json!([{"path":"x.rs","line":1,"action":"Verify the store","outcome":"Needs confirmation","checked":over}]);
        let report = run("SUCCESS", verdict);
        assert!(report.is_partial());
        assert!(report.report.focus.is_empty());
        assert!(report.report.limits.iter().any(|s| s == formatted));
        assert!(
            report
                .report
                .limits
                .iter()
                .any(|s| s == "AGY returned an invalid coverage limit.")
        );
        assert!(!serde_json::to_string(&report).unwrap().contains(&over));
    }

    #[test]
    fn verified_evidence_survives_storage_and_formats_both_github_destinations() {
        use jidoka_code::publish::prepare;
        let mut report = run(
            "SUCCESS",
            json!({"reviewed_files":["x.rs"],"findings":[sample_finding()],"focus":[],"limits":[]}),
        );
        report.head = "b".repeat(40);
        let saved: PublishedReport =
            serde_json::from_slice(&serde_json::to_vec(&report).unwrap()).unwrap();
        assert!(!saved.is_partial());
        for inline in [false, true] {
            let preview = prepare(&saved, &[0], inline);
            let body = if inline {
                &preview.comments[0].body
            } else {
                &preview.body
            };
            for part in [
                "**Triggering input**",
                "    []",
                "**How it fails**",
                "1. The caller",
                "/x.rs#L1",
                "**Test coverage**",
                "**What was ruled out**",
            ] {
                assert!(body.contains(part), "{part}");
            }
        }
    }

    #[test]
    fn complete_requires_terminal_success_coverage_and_exact_citations() {
        let mut v =
            json!({"reviewed_files":["x.rs"],"findings":[sample_finding()],"focus":[],"limits":[]});
        v["notes"] = json!([
            "Static inspection was sufficient.",
            "Unchanged documentation was outside the patch."
        ]);
        let report = run("SUCCESS", v.clone());
        assert_eq!(report.report.notes.len(), 2);
        let mut blocked = v.clone();
        blocked["limits"] = json!(["The required integration fixture was unavailable."]);
        assert!(run("SUCCESS", blocked).is_partial());
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
    fn only_complete_reviews_publish_the_lowest_verified_mergeability_score() {
        use jidoka_code::publish::prepare;
        let finding = sample_finding();
        let clean = json!({"reviewed_files":["x.rs"],"findings":[],"focus":[],"limits":[]});
        let report = run("SUCCESS", clean.clone());
        assert_eq!(
            report.mergeability_label().as_deref(),
            Some("Mergeability: 100/100 · Ready to merge")
        );

        for (score, decision) in [
            (0, "Hold merge"),
            (89, "Hold merge"),
            (90, "Ready to merge"),
            (100, "Ready to merge"),
        ] {
            let mut verdict = clean.clone();
            let mut first = finding.clone();
            first["mergeability_score"] = json!(score);
            let mut other = finding.clone();
            other["title"] = json!("Other issue");
            other["mergeability_score"] = json!(100);
            verdict["findings"] = json!([first, other]);
            let report = run("SUCCESS", verdict);
            assert!(!report.is_partial());
            let expected = format!("**Mergeability: {score}/100 · {decision}**");
            for inline in [false, true] {
                assert!(prepare(&report, &[1], inline).body.contains(&expected));
            }
        }
        for invalid in [Value::Null, json!(-1), json!(101), json!(90.5), json!("90")] {
            let mut verdict = clean.clone();
            let mut item = finding.clone();
            if invalid.is_null() {
                item.as_object_mut().unwrap().remove("mergeability_score");
            } else {
                item["mergeability_score"] = invalid;
            }
            verdict["findings"] = json!([item]);
            let report = run("SUCCESS", verdict);
            assert!(report.is_partial());
            assert_eq!(report.report.findings.len(), 1);
            assert!(report.mergeability_label().is_none());
        }
        let mut partial = clean;
        partial["reviewed_files"] = json!([]);
        assert!(run("SUCCESS", partial).mergeability_label().is_none());
    }

    #[test]
    fn recovery_removes_only_abandoned_jobs_while_holding_the_worker_lock() {
        let dir = tempfile::tempdir().unwrap();
        let reviewer = Reviewer {
            jobs: dir.path().into(),
            socket: "unused".into(),
            model: "model".into(),
            label: "label".into(),
        };
        let abandoned = tempfile::Builder::new()
            .prefix("review-")
            .rand_bytes(JOB_SUFFIX_LEN)
            .tempdir_in(dir.path())
            .unwrap()
            .keep();
        fs::write(abandoned.join("source"), "private").unwrap();
        let unrelated = dir.path().join("keep");
        fs::create_dir(&unrelated).unwrap();
        let lock = reviewer.recover_jobs().unwrap();
        assert!(!abandoned.exists());
        assert!(unrelated.exists());
        let active = tempfile::Builder::new()
            .prefix("review-")
            .tempdir_in(dir.path())
            .unwrap();
        assert!(reviewer.recover_jobs().is_err());
        assert!(active.path().exists());
        drop(lock);
    }

    #[test]
    fn paid_invocation_survives_reopen_and_base_reset() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("db");
        jidoka_code::web::recover(&db, "agy").unwrap();
        let mut session = Session::open(&db, 1).unwrap();
        assert!(!session.agy_invoked().unwrap());
        assert!(session.claim_agy().unwrap());
        assert!(session.agy_invoked().unwrap());
        drop(session);
        let mut resumed = Session::open(&db, 1).unwrap();
        resumed.reset().unwrap();
        assert!(!resumed.claim_agy().unwrap());
        assert!(Session::open(&db, 2).unwrap().claim_agy().unwrap());
    }
}
