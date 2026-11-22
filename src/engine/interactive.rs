//! A tool turn can extend the evidence index only with verified, pinned source lines.

use super::*;
use crate::contracts::PublishedReport;
use std::{
    cell::{OnceCell, RefCell},
    fmt,
};

#[derive(Debug)]
pub struct ReviewTurnLimit;

impl ReviewTurnLimit {
    pub const MAX: usize = 500;
}

impl fmt::Display for ReviewTurnLimit {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("The review reached its model turn limit.")
    }
}
impl std::error::Error for ReviewTurnLimit {}

#[derive(Debug)]
pub struct ReviewContextExceeded;

impl fmt::Display for ReviewContextExceeded {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("The request exceeds the model context window.")
    }
}
impl std::error::Error for ReviewContextExceeded {}

const TOOLS: &str = r##"
Before answering this stage, you may inspect the pinned repository as often as useful.
To call a tool, return ONLY {"read":{"path":"repository/path","term":"literal"}}.
Use path "*" with a nonempty literal to search the proposed repository. Search returns
up to 12 matching paths at a time: use "*:13" for the next page, then "*:25", etc.
Use an exact path with an empty term to open it, or "#L81" to read from line 81. A path and literal
together locate matching passages. Results appear in snapshot.head_context, with
head citations you can use. A read returning no matches is not proof of absence.
Follow callers, relevant contracts and tests until evidence settles the question
or a concrete piece of evidence is unavailable. Acknowledge tool results already
in the input. To finish, return the requested hypotheses or assessments object.
"##;

#[derive(Default)]
struct Coverage {
    examined: HashSet<String>,
    missed: HashSet<String>,
}

impl Coverage {
    fn record(&mut self, snapshot: &Snapshot, complete: bool) {
        let set = if complete {
            &mut self.examined
        } else {
            &mut self.missed
        };
        for file in snapshot.files.iter().filter(|file| !file.patch.is_empty()) {
            set.insert(file.path.to_owned());
        }
    }
}

enum Stop {
    Context,
    TurnLimit,
    RepeatedRead,
    Error(anyhow::Error),
}

fn read_request(response: &Value) -> Result<Option<ContextRead>> {
    let Some(value) = response.get("read") else {
        return Ok(None);
    };
    let read: ContextRead = serde_json::from_value(value.clone())?;
    let valid_path = if read.path == "*" {
        !read.term.trim().is_empty()
    } else if let Some(start) = read.path.strip_prefix("*:") {
        !read.term.trim().is_empty() && start.parse::<usize>().is_ok_and(|n| n > 0)
    } else {
        safe_path(&read.path)
    };
    anyhow::ensure!(
        response.as_object().is_some_and(|object| object.len() == 1)
            && valid_path
            && read.term.len() <= MAX_READ_TERM_BYTES
            && printable(&read.term),
        "Invalid pinned repository read."
    );
    Ok(Some(read))
}

fn extend_evidence<'a>(
    data: &mut Value,
    evidence: &mut Evidence<'a>,
    windows: &'a [SourceWindow],
) -> usize {
    let index = evidence
        .references
        .as_mut()
        .expect("interactive references");
    let results = data["snapshot"]["head_context"]
        .as_array_mut()
        .expect("head context array");
    let before = index.head_lines.len();
    for window in windows.iter().filter(|window| safe_path(&window.path)) {
        let lines: Vec<_> = window.text.lines().collect();
        let full_head = evidence
            .source
            .get(window.path.as_str())
            .map_or(&[][..], |file| file.head.as_slice());
        let Some(end) = window.start.checked_add(lines.len()) else {
            continue;
        };
        if (window.start..end)
            .all(|line| index.head_lines.contains_key(&(window.path.as_str(), line)))
        {
            continue;
        }
        if let Some(rows) = index.context_rows(&window.path, window.start, &lines, full_head) {
            results.push(rows);
        }
    }
    data["snapshot"]["complete_head_paths"] = json!(index.complete_head_paths(&evidence.source));
    index.head_lines.len() - before
}

type Read<'f> = dyn FnMut(&Snapshot, &[ContextRead]) -> Result<Vec<SourceWindow>> + 'f;
type Fits<'f> = dyn FnMut(&str, &Value) -> Result<bool> + 'f;
type Model<'f> = dyn FnMut(&str, &Value) -> Result<Value> + 'f;

struct ChunkResult {
    report: Result<(Report, BatchCoverage)>,
    stop: Option<Stop>,
    displayed: HashSet<String>,
}

fn review_chunk(
    chunk: &Snapshot,
    full: &Snapshot,
    scan: &Scan,
    prior: &[Finding],
    model: &mut Model<'_>,
    read: &mut Read<'_>,
    fits: &mut Fits<'_>,
) -> ChunkResult {
    let read = RefCell::new(read);
    // Fixed slots provide stable references to tool evidence while citations are live.
    let evidence_turns: Vec<_> = (0..ReviewTurnLimit::MAX).map(|_| OnceCell::new()).collect();
    let mut turns = evidence_turns.iter();
    let mut stop = None;
    let mut displayed = None;
    let result = review_passes(
        chunk,
        scan,
        &mut |system, data, evidence| {
            let system = format!("{system}\n{TOOLS}");
            let mut attempted = HashMap::new();
            loop {
                if stop.is_some() {
                    anyhow::bail!("This batch was interrupted.")
                }
                match fits(&system, data) {
                    Ok(true) => {}
                    Ok(false) => {
                        stop = Some(Stop::Context);
                        anyhow::bail!("Context window exceeded.")
                    }
                    Err(error) => {
                        stop = Some(Stop::Error(error));
                        anyhow::bail!("Could not measure the request.")
                    }
                }
                let response = match model(&system, data) {
                    Err(error) if error.is::<ReviewTurnLimit>() => {
                        stop = Some(Stop::TurnLimit);
                        anyhow::bail!("Model turn limit reached.")
                    }
                    Err(error) if error.is::<ReviewContextExceeded>() => {
                        stop = Some(Stop::Context);
                        anyhow::bail!("Context window exceeded.")
                    }
                    other => other?,
                };
                displayed.get_or_insert_with(|| {
                    data["snapshot"]["files"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|file| file["scope"] == "hunks")
                        .filter_map(|file| file["path"].as_str().map(str::to_owned))
                        .collect::<HashSet<_>>()
                });
                let Some(request) = read_request(&response)? else {
                    return Ok(response);
                };
                let Some(slot) = turns.next() else {
                    stop = Some(Stop::TurnLimit);
                    anyhow::bail!("Model turn limit reached.")
                };
                let attempts = attempted
                    .entry((request.path.clone(), request.term.clone()))
                    .or_insert(0);
                *attempts += 1;
                if *attempts == 2 {
                    data["last_read"] = json!({"request": request, "result": "This lookup was already performed on the same revision. Choose a different query or finish with the available evidence."});
                    continue;
                } else if *attempts > 2 {
                    stop = Some(Stop::RepeatedRead);
                    anyhow::bail!("Repeated pinned source lookup.")
                }
                let result = read.borrow_mut()(full, std::slice::from_ref(&request));
                let status = match result {
                    Ok(windows) => {
                        let windows = slot.get_or_init(|| windows);
                        let count = extend_evidence(data, evidence, windows);
                        format!("{count} new source lines.")
                    }
                    Err(_) => "The pinned source lookup failed.".into(),
                };
                data["last_read"] = json!({"request": request, "result": status});
            }
        },
        RecheckReader {
            protocol: CitationProtocol::Interactive,
            read: |requests: &[ContextRead]| read.borrow_mut()(full, requests),
            windows: &mut Vec::new(),
        },
        prior,
        CitationProtocol::Interactive,
    );
    ChunkResult {
        report: result,
        stop,
        displayed: displayed.unwrap_or_default(),
    }
}

fn merge_report(report: &mut Report, next: Report) {
    for limit in next.limits {
        if !report.limits.contains(&limit) {
            report.limits.push(limit);
        }
    }
    for finding in next.findings {
        if !report.findings.contains(&finding) {
            report.findings.push(finding);
        }
    }
    for focus in next.focus {
        if !report.focus.contains(&focus) {
            report.focus.push(focus);
        }
    }
}

pub fn review_snapshot_iterative(
    snapshot: Snapshot,
    mut ask: impl FnMut(&str, &Value) -> Result<Value>,
    mut read: impl FnMut(&Snapshot, &[ContextRead]) -> Result<Vec<SourceWindow>>,
    mut fits: impl FnMut(&str, &Value) -> Result<bool>,
    prior: &[Finding],
) -> Result<PublishedReport> {
    let scan = crate::scanner::scan(&snapshot);
    let mut report = collection_report(&snapshot, &scan);
    let mut coverage = Coverage::default();
    let mut first = snapshot.clone();
    first.diff = None; // The review representation consists of indexed source, never a second copy of the diff.
    let mut queue = vec![first];
    while let Some(chunk) = queue.pop() {
        let ChunkResult {
            report: result,
            stop,
            displayed,
        } = review_chunk(
            &chunk, &snapshot, &scan, prior, &mut ask, &mut read, &mut fits,
        );
        match stop {
            None => {
                let (batch, outcome) = result?;
                coverage.record(&chunk, outcome.stages_finished);
                coverage.missed.extend(outcome.unfinished_paths);
                if outcome.stages_finished {
                    for file in chunk
                        .files
                        .iter()
                        .filter(|file| !file.patch.is_empty() && !displayed.contains(&file.path))
                    {
                        coverage.missed.insert(file.path.to_owned());
                    }
                }
                merge_report(&mut report, batch);
            }
            Some(Stop::Context) => {
                if let Some(parts) = split_chunk(chunk.clone()) {
                    queue.extend(parts.into_iter().rev());
                } else {
                    coverage.record(&chunk, false);
                    let path = chunk
                        .files
                        .first()
                        .map_or("review metadata", |file| file.path.as_str());
                    report.limits.push(format!(
                        "The model context window cannot fit the remaining source for {path}."
                    ));
                }
            }
            Some(reason @ (Stop::TurnLimit | Stop::RepeatedRead)) => {
                // live_assessments can have accepted independent findings before a recheck was stopped.
                if let Ok((partial, _)) = result {
                    merge_report(&mut report, partial);
                }
                coverage.record(&chunk, false);
                match reason {
                    Stop::TurnLimit => {
                        for outstanding in &queue { coverage.record(outstanding, false); }
                        report.limits.push(ReviewTurnLimit.to_string());
                        break;
                    }
                    Stop::RepeatedRead => report.limits.push("The model repeated the same pinned lookup after it was asked to choose a different query or finish.".into()),
                    _ => unreachable!()
                }
            }
            Some(Stop::Error(error)) => return Err(error),
        }
    }
    let reviewed_files = snapshot
        .files
        .iter()
        .filter(|file| {
            coverage.examined.contains(&file.path) && !coverage.missed.contains(&file.path)
        })
        .map(|file| file.path.clone())
        .collect();
    Ok(PublishedReport {
        repo: snapshot.repo,
        base: snapshot.base,
        head: snapshot.head,
        diff: snapshot.diff,
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
        reviewed_files: Some(reviewed_files),
    })
}

/// Split one unified hunk by source row, retaining the original 1-based coordinates on both sides.
fn split_patch(patch: &str) -> Option<Vec<String>> {
    let lines = hunks::lines(patch)?;
    let headers = patch.match_indices("\n@@ ").map(|(offset, _)| offset + 1);
    if let Some(boundary) = headers.min_by_key(|offset| offset.abs_diff(patch.len() / 2)) {
        return Some(vec![patch[..boundary].into(), patch[boundary..].into()]);
    }
    if lines.len() < 2 {
        return None;
    }
    let header = patch
        .lines()
        .next()?
        .strip_prefix("@@ -")?
        .split_once(" @@")?
        .0;
    let (base_range, head_range) = header.split_once(" +")?;
    let cursor = |range: &str| -> Option<usize> {
        let (start, count) = range.split_once(',').unwrap_or((range, "1"));
        let start = start.parse::<usize>().ok()?;
        if count == "0" {
            Some(start)
        } else {
            start.checked_sub(1)
        }
    };
    let mut base = cursor(base_range)?;
    let mut head = cursor(head_range)?;
    let middle = lines.len() / 2;
    let mut patches = Vec::new();
    for segment in [&lines[..middle], &lines[middle..]] {
        let base_count = segment.iter().filter(|(line, _, _)| line.is_some()).count();
        let head_count = segment.iter().filter(|(_, line, _)| line.is_some()).count();
        if segment
            .iter()
            .any(|(old, new, _)| old.is_none() || new.is_none())
        {
            let old = base + usize::from(base_count > 0);
            let new = head + usize::from(head_count > 0);
            let mut patch = format!("@@ -{old},{base_count} +{new},{head_count} @@\n");
            for (old, new, text) in segment {
                patch.push(match (old, new) {
                    (Some(_), Some(_)) => ' ',
                    (Some(_), _) => '-',
                    _ => '+',
                });
                patch.push_str(text);
                patch.push('\n');
            }
            patches.push(patch);
        }
        base += base_count;
        head += head_count;
    }
    (!patches.is_empty()).then_some(patches)
}

fn split_chunk(mut chunk: Snapshot) -> Option<Vec<Snapshot>> {
    // Supporting context can be reopened at its pinned revision. Preserve every changed hunk.
    if !chunk.head_context.is_empty() {
        chunk.head_context.clear();
        return Some(vec![chunk]);
    }
    if chunk.files.len() > 1 {
        let right = chunk.files.split_off(chunk.files.len() / 2);
        let mut next = chunk.clone();
        next.files = right;
        return Some(vec![chunk, next]);
    }
    // Keep both pinned texts for validation even when a large hunk is partitioned.
    let file = chunk.files.first()?;
    let patches = split_patch(&file.patch)?;
    Some(
        patches
            .into_iter()
            .map(|patch| {
                let mut part = chunk.clone();
                part.files[0].patch = patch;
                part
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(patch: &str) -> Snapshot {
        serde_json::from_value(json!({
            "url":"https://github.com/team/repo/pull/1", "repo":"team/repo","number":1,
            "base":"base","head":"head","intent":[],"limits":[],
            "files":[{"path":"src/feature.rs","before":"","after":"","patch":patch}]
        }))
        .unwrap()
    }

    #[test]
    fn follows_multiple_tool_turns_and_validates_the_final_citation() {
        let source = snapshot("@@ -0,0 +1 @@\n+run_job();");
        let mut turns = 0;
        let mut reads = 0;
        let result = review_snapshot_iterative(source, |_, data| {
            turns += 1;
            let reply = match turns {
                1..=4 => json!({"read":{"path":"*","term":format!("lookup_{turns}")}}),
                5 => json!({"complete":true,"hypotheses":[{
                    "anchor":"H1","expected":"Only queued jobs run.","scenario":"A paused job is submitted.","consequence":"It could run twice."
                }]}),
                6 => json!({"read":{"path":"src/guard.rs","term":"#L41"}}),
                7 => {
                    let windows = data["snapshot"]["head_context"].as_array().unwrap();
                    let guard = windows.last().unwrap();
                    assert_eq!(guard["start"],41);
                    json!({"complete":true,"assessments":[{
                        "id":1, "outcome":"refuted", "basis":guard["rows"][0][1],
                        "countercheck":"The entry point checks the queue before dispatch."
                    }]})
                }
                _ => panic!("Unexpected additional turn")
            };
            Ok(reply)
        }, |snapshot, requests| {
            assert_eq!(snapshot.head,"head");
            reads += 1;
            let path = if reads == 5 { "src/guard.rs".into() } else { format!("src/helper{reads}.rs") };
            assert_eq!(requests.len(),1);
            Ok(vec![SourceWindow { path, start:if reads == 5 {41} else {1}, text:format!("let value = lookup_{reads}();") }])
        }, |_, _| Ok(true), &[]).unwrap();
        assert_eq!((turns, reads), (7, 5));
        assert!(
            result.report.limits.is_empty(),
            "{:?}",
            result.report.limits
        );
        assert!(result.report.findings.is_empty());
        assert_eq!(result.reviewed_files.unwrap(), ["src/feature.rs"]);
    }

    #[test]
    fn over_context_hunk_is_partitioned_without_losing_changed_rows() {
        let source = snapshot("@@ -8,3 +8,3 @@\n-old1\n-old2\n-old3\n+new1\n+new2\n+new3");
        let mut lines = Vec::new();
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    for section in data["snapshot"]["files"][0]["sections"].as_array().unwrap() {
                        for row in section.as_array().unwrap() {
                            lines.push(row[2].as_str().unwrap().to_owned());
                        }
                    }
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(vec![]),
            |_, data| {
                let count: usize = data["snapshot"]["files"][0]["sections"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|s| s.as_array().unwrap().len())
                    .sum();
                Ok(count <= 2)
            },
            &[],
        )
        .unwrap();
        assert_eq!(lines, ["old1", "old2", "old3", "new1", "new2", "new3"]);
        assert_eq!(result.reviewed_files.unwrap(), ["src/feature.rs"]);
        assert!(result.report.limits.is_empty());
        let input = "@@ -8,3 +8,3 @@\n-old1\n-old2\n-old3\n+new1\n+new2\n+new3";
        let parts = split_patch(input).unwrap();
        let rows: Vec<_> = parts
            .iter()
            .flat_map(|patch| hunks::lines(patch).unwrap())
            .collect();
        assert_eq!(rows, hunks::lines(input).unwrap());
    }

    #[test]
    fn turn_limit_while_reviewing_part_of_a_file_keeps_it_incomplete() {
        let source = snapshot("@@ -0,0 +1,2 @@\n+first();\n+second();");
        let mut calls = 0;
        let result = review_snapshot_iterative(
            source,
            |_, _| {
                calls += 1;
                match calls {
                    1 => Ok(json!({"complete":true,"hypotheses":[]})),
                    2 => Ok(json!({"complete":true,"assessments":[]})),
                    _ => Err(ReviewTurnLimit.into()),
                }
            },
            |_, _| Ok(vec![]),
            |_, data| {
                Ok(!data["snapshot"]["files"][0]["sections"]
                    .to_string()
                    .contains("second")
                    || !data["snapshot"]["files"][0]["sections"]
                        .to_string()
                        .contains("first"))
            },
            &[],
        )
        .unwrap();
        assert_eq!(calls, 3);
        assert_eq!(result.unfinished_patches().unwrap().len(), 1);
        assert_eq!(result.patch_files.unwrap(), ["src/feature.rs"]);
        assert!(result.reviewed_files.unwrap().is_empty());
        assert!(result.report.limits.contains(&ReviewTurnLimit.to_string()));
    }

    #[test]
    fn repeated_read_receives_feedback_before_stopping_and_keeps_coverage_partial() {
        let source = snapshot("@@ -0,0 +1 @@\n+run_job();");
        let mut turns = 0;
        let mut reads = 0;
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                turns += 1;
                if turns == 3 {
                    assert!(
                        data["last_read"]["result"]
                            .as_str()
                            .unwrap()
                            .contains("different query")
                    );
                }
                Ok(json!({"read":{"path":"*","term":"run_job"}}))
            },
            |_, _| {
                reads += 1;
                Ok(Vec::new())
            },
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert_eq!((turns, reads), (3, 1));
        assert!(result.reviewed_files.unwrap().is_empty());
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("repeated the same pinned lookup"))
        );
    }

    #[test]
    fn unvalidated_proposal_does_not_count_its_diff_as_fully_examined() {
        let source = snapshot("@@ -0,0 +1 @@\n+run_job();");
        let mut replies = [
            json!({"complete":true, "hypotheses":[{"anchor":"H99"}]}),
            json!({"complete":true, "assessments":[]}),
        ]
        .into_iter();
        let result = review_snapshot_iterative(
            source,
            |_, _| Ok(replies.next().unwrap()),
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert!(result.reviewed_files.unwrap().is_empty());
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("invalid details or citations"))
        );
    }

    #[test]
    fn partitioning_never_discards_pinned_text_that_disproves_a_patch() {
        assert!(split_patch("@@ -0,0 +1 @@\n+one\n@@ -0,0 +1 @@\n+overlap").is_none());
        let mut source = snapshot("@@ -0,0 +1 @@\n+forged();");
        source.files[0].after = "actual();".into();
        let result = review_snapshot_iterative(
            source,
            |_, _| panic!("The contradictory patch must never become eligible evidence."),
            |_, _| Ok(Vec::new()),
            |_, data| {
                Ok(!data["snapshot"]["files"][0]["sections"]
                    .to_string()
                    .contains("actual"))
            },
            &[],
        )
        .unwrap();
        assert!(result.reviewed_files.unwrap().is_empty());
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("model context window"))
        );
    }

    #[test]
    fn small_context_review_can_recheck_a_tiny_patch_in_a_large_pinned_file() {
        let mut source = snapshot("@@ -1 +1 @@\n-old();\n+new();");
        let surrounding = "unchanged".repeat(3000);
        source.files[0].before = format!("old();\n{surrounding}");
        source.files[0].after = format!("new();\n{surrounding}");
        let mut calls = 0;
        let result = review_snapshot_iterative(source, |_, data| {
            calls += 1;
            match calls {
                1 => Ok(json!({"complete":true,"hypotheses":[{
                    "anchor":"H1","expected":"The job completes.","scenario":"A caller runs a job.","consequence":"It could exit early."
                }]})),
                2 => Ok(json!({"complete":true,"assessments":[]})),
                3 => {
                    assert!(data.get("recheck").is_some());
                    Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"refuted","basis":"H1","countercheck":"The entry point dispatches the job."}]}))
                },
                _ => panic!("The patch already fits.")
            }
        }, |_,_| Ok(Vec::new()), |_,data| Ok(data.to_string().len()<8192), &[]).unwrap();
        assert_eq!(result.reviewed_files.unwrap(), ["src/feature.rs"]);
        assert!(
            result.report.limits.is_empty(),
            "{:?}",
            result.report.limits
        );
        assert_eq!(calls, 3);
    }
}
