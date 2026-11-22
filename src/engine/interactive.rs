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

/// The provider received this batch but ended generation without a usable answer.
#[derive(Debug)]
pub struct ReviewBatchInterrupted;

impl fmt::Display for ReviewBatchInterrupted {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("The provider ended generation without a completed answer.")
    }
}
impl std::error::Error for ReviewBatchInterrupted {}

const TOOLS: &str = r##"
Return an assessment for every supplied hypothesis now. For a specific unresolved
ID, use outcome "indeterminate", describe the missing evidence in countercheck,
and add "reads":[{"path":"repository/path","term":"literal"}] on that assessment.
Ask only for source that can change that verdict. Other IDs still need a disposition.
Use path "*" with a nonempty literal to search the pinned repository; "*:13" opens
the next page of matching paths. Use an exact path with an empty term to open
the file, "#L81" for a particular line, or a literal for matching passages.
Rechecks include the last assessments and all previous pinned evidence. A search
with no hits does not establish absence. If no further source can help, describe
the concrete remaining human check. Set complete to true when every required ID
has a disposition, including an explicit indeterminate outcome.
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
    ShorterIntent(Vec<String>),
    Metadata,
    Interrupted,
    TurnLimit,
    RepeatedRead,
    Error(anyhow::Error),
}

pub(crate) fn read_request(response: &Value) -> Result<Option<ContextRead>> {
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

pub(super) fn extend_evidence<'a>(
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

fn returned_source(windows: &[SourceWindow]) -> bool {
    windows
        .iter()
        .any(|window| safe_path(&window.path) && window.start > 0 && !window.text.is_empty())
}

type Read<'f> = dyn FnMut(&Snapshot, &[ContextRead]) -> Result<Vec<SourceWindow>> + 'f;
type Fits<'f> = dyn FnMut(&str, &Value) -> Result<bool> + 'f;
type Model<'f> = dyn FnMut(&str, &Value) -> Result<Value> + 'f;

fn shorten_intent(intent: &mut Vec<String>) {
    let commits = intent
        .iter()
        .filter(|entry| entry.starts_with("Commit message\n"))
        .count();
    if commits > 0 {
        let mut kept = 0;
        intent.retain(|entry| {
            if !entry.starts_with("Commit message\n") {
                return true;
            }
            kept += 1;
            kept <= commits / 2
        });
    } else {
        let mut bytes = intent.iter().map(String::len).sum::<usize>() / 2;
        intent.retain_mut(|entry| {
            let end = entry.floor_char_boundary(bytes.min(entry.len()));
            entry.truncate(end);
            bytes -= end;
            end > 0
        });
    }
}

/// Keep ordinary requests intact. When the repeated metadata alone exceeds the real window,
/// reduce supplemental commit history first, then the tail of the remaining PR text.
fn context_overflow(
    system: &str,
    data: &Value,
    chunk: &Snapshot,
    fits: &mut Fits<'_>,
    rejected_by_provider: bool,
) -> Result<Stop> {
    if !rejected_by_provider
        && (data.get("hypotheses").is_some() || data.get("last_read").is_some())
        || chunk.intent.is_empty()
    {
        return Ok(Stop::Context);
    }
    let mut metadata = json!({
        "snapshot":{"url":chunk.url,"repo":chunk.repo,"number":chunk.number,"base":chunk.base,"head":chunk.head,
            "intent":chunk.intent,"limits":chunk.limits,"files":[],"head_context":[],"complete_head_paths":[]},
        "scan": data["scan"],
    });
    if fits(system, &metadata)? {
        if rejected_by_provider {
            // OpenAI-compatible endpoints may expose no counter at all. An actual rejection
            // establishes overflow. Size below only chooses which part to reduce first.
            let intent_bytes = chunk.intent.iter().map(String::len).sum::<usize>();
            let diff_bytes = chunk
                .files
                .iter()
                .map(|file| {
                    if file.patch.is_empty() {
                        file.before.len() + file.after.len()
                    } else {
                        file.patch.len()
                    }
                })
                .sum::<usize>();
            let extras = data["snapshot"]["head_context"].to_string().len()
                + data
                    .get("hypotheses")
                    .map_or(0, |items| items.to_string().len())
                + data
                    .get("recheck")
                    .map_or(0, |items| items.to_string().len());
            let indivisible =
                chunk.files.len() == 1 && chunk.files[0].patch.lines().take(3).count() <= 2;
            if indivisible || intent_bytes >= diff_bytes.saturating_add(extras) {
                let mut intent = chunk.intent.clone();
                shorten_intent(&mut intent);
                return Ok(Stop::ShorterIntent(intent));
            }
        }
        return Ok(Stop::Context);
    }
    let mut intent = chunk.intent.clone();
    while !intent.is_empty() {
        shorten_intent(&mut intent);
        metadata["snapshot"]["intent"] = json!(&intent);
        if fits(system, &metadata)? {
            return Ok(Stop::ShorterIntent(intent));
        }
    }
    Ok(Stop::Metadata)
}

struct ChunkResult {
    report: Result<BatchResult>,
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
    let turns = RefCell::new(evidence_turns.iter());
    let mut stop = None;
    let mut displayed = None;
    let recheck_has_reads = std::cell::Cell::new(false);
    let result = review_passes(
        chunk,
        scan,
        &mut |instructions, data, evidence| {
            let recheck_hint = if data.get("recheck").is_some() {
                "If a function body or SQL statement is cut off and it can settle the question, request the next source window in that file starting at the first missing line."
            } else {
                ""
            };
            let with_tools = format!("{instructions}\n{TOOLS}{recheck_hint}");
            let (stage, answer_key) = if data.get("recheck").is_some() {
                ("recheck", "assessments")
            } else if data.get("hypotheses").is_some() {
                ("challenge", "assessments")
            } else {
                ("discovery", "hypotheses")
            };
            let planning = stage == "discovery";
            let synthesis = if planning {
                format!(
                    "{instructions}\nPlan the review using the supplied diff, intent, prior leads and pinned context. Return the hypotheses now. The challenge stage investigates them against additional repository source."
                )
            } else {
                format!(
                    "{instructions}\nRepository reads are closed for this {stage} stage. {CLOSED_READS} Return the final assessments from the collected diff, source references and lookup results. Give every required hypothesis a disposition. Use indeterminate for a specific unresolved question."
                )
            };
            let mut attempted = HashMap::new();
            let mut synthesis_turn = usize::from(planning);
            let mut has_source = stage == "recheck" && recheck_has_reads.get();
            let mut interrupted = false;
            loop {
                data["answer_shape"] = json!(answer_key);
                let system = if synthesis_turn == 0 {
                    data["allow_assessment_reads"] = json!(true);
                    with_tools.as_str()
                } else {
                    data.as_object_mut()
                        .expect("review request")
                        .remove("allow_assessment_reads");
                    synthesis.as_str()
                };
                if stop.is_some() {
                    anyhow::bail!("This batch was interrupted.")
                }
                match fits(system, data) {
                    Ok(true) => {}
                    Ok(false) => {
                        stop = Some(
                            context_overflow(system, data, chunk, fits, false)
                                .unwrap_or_else(Stop::Error),
                        );
                        anyhow::bail!("Context window exceeded.")
                    }
                    Err(error) => {
                        stop = Some(Stop::Error(error));
                        anyhow::bail!("Could not measure the request.")
                    }
                }
                let response = match model(system, data) {
                    Err(error) if error.is::<ReviewTurnLimit>() => {
                        stop = Some(Stop::TurnLimit);
                        anyhow::bail!("Model turn limit reached.")
                    }
                    Err(error) if error.is::<ReviewContextExceeded>() => {
                        stop = Some(
                            context_overflow(system, data, chunk, fits, true)
                                .unwrap_or_else(Stop::Error),
                        );
                        anyhow::bail!("Context window exceeded.")
                    }
                    Err(error) if error.is::<ReviewBatchInterrupted>() => {
                        if has_source && synthesis_turn == 0 {
                            interrupted = true;
                            synthesis_turn = 1;
                            data["last_read"] = json!({"result":"The provider interrupted the previous answer. The pinned source already read is included. Finish the assessments using that evidence."});
                            continue;
                        }
                        stop = Some(Stop::Interrupted);
                        anyhow::bail!("Generation ended before a reply.")
                    }
                    Err(error) => {
                        stop = Some(Stop::Error(error));
                        anyhow::bail!("The provider stopped the review.")
                    }
                    Ok(response) => response,
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
                if synthesis_turn > 0 {
                    if response["complete"].is_boolean()
                        && response[answer_key].is_array()
                        && !response[answer_key].as_array().is_some_and(|items| {
                            items.iter().any(|item| item.get("reads").is_some())
                        })
                        && response.as_object().is_some_and(|object| {
                            object.keys().all(|key| {
                                key == "complete"
                                    || key == answer_key
                                    || (stage == "challenge" && key == "leads")
                            })
                        })
                    {
                        // The next stage may use tools again; its evidence includes all pinned source windows.
                        let request = data.as_object_mut().expect("review request");
                        request.remove("last_read");
                        request.remove("answer_shape");
                        return Ok(response);
                    }
                    if synthesis_turn == 2 {
                        stop = Some(if interrupted || planning {
                            Stop::Interrupted
                        } else {
                            Stop::RepeatedRead
                        });
                        anyhow::bail!(
                            "The model did not finish the stage with the available evidence."
                        )
                    }
                    synthesis_turn += 1;
                    data["last_read"] = json!({"result": format!("No further lookup will be executed. Return the final {stage} JSON with complete and {answer_key}.")});
                    continue;
                }
                let Some(request) = read_request(&response)? else {
                    let request = data.as_object_mut().expect("review request");
                    request.remove("last_read");
                    request.remove("answer_shape");
                    request.remove("allow_assessment_reads");
                    return Ok(response);
                };
                let attempts = attempted
                    .entry((request.path.clone(), request.term.clone()))
                    .or_insert(0);
                *attempts += 1;
                if *attempts == 2 {
                    data["last_read"] = json!({"request": request, "result": "This lookup was already performed on the same revision. Choose a different query or finish with the available evidence."});
                    continue;
                }
                if *attempts > 2 {
                    synthesis_turn = 1;
                    data["last_read"] = json!({"request": request, "result": "This lookup was already performed. Its results remain in the supplied evidence. No further reads will be executed during this stage."});
                    continue;
                }
                let Some(slot) = turns.borrow_mut().next() else {
                    stop = Some(Stop::TurnLimit);
                    anyhow::bail!("Model turn limit reached.")
                };
                let result = read.borrow_mut()(full, std::slice::from_ref(&request));
                let status = match result {
                    Ok(windows) => {
                        let windows = slot.get_or_init(|| windows);
                        let count = extend_evidence(data, evidence, windows);
                        has_source |= returned_source(windows);
                        format!("{count} new source lines.")
                    }
                    Err(_) => "The pinned source lookup failed.".into(),
                };
                data["last_read"] = json!({"request": request, "result": status});
            }
        },
        RecheckReader {
            protocol: CitationProtocol::Interactive,
            read: |requests: &[ContextRead]| {
                let mut windows = Vec::new();
                let mut failure = None;
                // Each lookup has its own page budget, even when different IDs ask in the same round.
                for request in requests {
                    match read.borrow_mut()(full, std::slice::from_ref(request)) {
                        Ok(result) => windows.extend(result),
                        Err(error) => failure = Some(error),
                    }
                }
                if windows.is_empty()
                    && let Some(error) = failure
                {
                    return Err(error);
                }
                recheck_has_reads.set(recheck_has_reads.get() || returned_source(&windows));
                let slot = turns.borrow_mut().next().ok_or(ReviewTurnLimit)?;
                Ok(slot.get_or_init(|| windows).as_slice())
            },
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

fn merge_limits(report: &mut Report, next: Report) {
    for limit in next.limits {
        if !report.limits.contains(&limit) {
            report.limits.push(limit);
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
    let mut items = RankedItems::default();
    let mut first = snapshot.clone();
    first.diff = None; // The review representation consists of indexed source, never a second copy of the diff.
    let mut queue = vec![first];
    let mut interrupted = 0;
    while let Some(chunk) = queue.pop() {
        let ChunkResult {
            report: mut result,
            stop,
            displayed,
        } = review_chunk(
            &chunk, &snapshot, &scan, prior, &mut ask, &mut read, &mut fits,
        );
        // Accepted items survive interrupted rechecks. Rank once across every batch, including retries.
        if let Ok(batch) = &mut result {
            items.append(&mut batch.items);
        }
        match stop {
            None => {
                let batch = result?;
                let outcome = batch.coverage;
                interrupted = 0;
                // A supporting file can establish evidence, but cannot identify which changed
                // patch an unresolved hypothesis affects without a corresponding displayed hunk.
                let finished =
                    outcome.stages_finished && outcome.unfinished_paths.is_subset(&displayed);
                coverage.record(&chunk, finished);
                coverage.missed.extend(outcome.unfinished_paths);
                if finished {
                    for file in chunk
                        .files
                        .iter()
                        .filter(|file| !file.patch.is_empty() && !displayed.contains(&file.path))
                    {
                        coverage.missed.insert(file.path.to_owned());
                    }
                }
                merge_limits(&mut report, batch.report);
            }
            Some(Stop::Interrupted) => {
                interrupted += 1;
                if interrupted >= 3 {
                    coverage.record(&chunk, false);
                    for outstanding in &queue {
                        coverage.record(outstanding, false);
                    }
                    report.limits.push("The provider returned no completed answer on three consecutive batches, including smaller inputs. The remaining review was stopped.".into());
                    break;
                }
                // Changing optional context alone may reproduce the same request. Always reduce the diff.
                let path = chunk.files.first().map(|file| file.path.clone());
                let mut smaller = chunk;
                smaller.head_context.clear();
                if let Some(mut parts) = split_chunk(smaller) {
                    if interrupted == 2 {
                        parts = probe_smaller_batch(parts);
                    }
                    queue.extend(parts.into_iter().rev());
                } else if let Some(path) = path {
                    coverage.missed.insert(path.clone());
                    report.limits.push(format!("The provider returned no completed answer for the smallest reviewable change in {path}."));
                } else {
                    report.limits.push(
                        "The provider returned no completed answer for the review metadata.".into(),
                    );
                }
            }
            Some(Stop::ShorterIntent(intent)) => {
                let limit =
                    "Pull request or commit text was shortened to fit the model context window."
                        .to_owned();
                if !report.limits.contains(&limit) {
                    report.limits.push(limit);
                }
                let mut next = chunk;
                next.intent = intent.clone();
                for remaining in &mut queue {
                    remaining.intent.clone_from(&intent);
                }
                queue.push(next);
            }
            Some(Stop::Metadata) => {
                coverage.record(&chunk, false);
                for remaining in &queue {
                    coverage.record(remaining, false);
                }
                report.limits.push("The review instructions and metadata exceed the model context window even without source or pull request text.".into());
                break;
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
                if let Ok(partial) = result {
                    merge_limits(&mut report, partial.report);
                }
                coverage.record(&chunk, false);
                match reason {
                    Stop::TurnLimit => {
                        for outstanding in &queue { coverage.record(outstanding, false); }
                        report.limits.push(ReviewTurnLimit.to_string());
                        break;
                    }
                    Stop::RepeatedRead => report.limits.push("The model repeated the same pinned lookup and did not return a final stage result after two requests to use the collected evidence.".into()),
                    _ => unreachable!()
                }
            }
            Some(Stop::Error(error)) => return Err(error),
        }
    }
    items.publish(&mut report);
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

/// Before declaring repeated provider interruptions, try an inexpensive, real part of the change.
/// Its pending siblings still cover the rest of the original batch if that probe succeeds.
fn probe_smaller_batch(mut parts: Vec<Snapshot>) -> Vec<Snapshot> {
    let weight = |part: &Snapshot| {
        part.files
            .iter()
            .map(|file| file.patch.len())
            .sum::<usize>()
    };
    let mut pending = Vec::new();
    loop {
        let smallest = parts
            .iter()
            .enumerate()
            .min_by_key(|(_, part)| weight(part))
            .unwrap()
            .0;
        let probe = parts.remove(smallest);
        pending.extend(parts);
        if probe.files.len() == 1 && probe.files[0].patch.lines().take(17).count() <= 16 {
            pending.insert(0, probe);
            return pending;
        }
        match split_chunk(probe.clone()) {
            Some(children) => parts = children,
            None => {
                pending.insert(0, probe);
                return pending;
            }
        }
    }
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
                1 => json!({"complete":true,"hypotheses":[{
                    "anchor":"H1","expected":"Only queued jobs run.","scenario":"A paused job is submitted.","consequence":"It could run twice."
                }]}),
                2..=5 => json!({"read":{"path":"*","term":format!("lookup_{turns}")}}),
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
                if turns == 1 {
                    return Ok(json!({"complete":true,"hypotheses":[]}));
                }
                if turns == 4 {
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
        assert_eq!((turns, reads), (6, 1));
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

    fn multi_file_snapshot(count: usize) -> Snapshot {
        let mut source = snapshot("@@ -0,0 +1 @@\n+run();");
        let original = source.files.pop().unwrap();
        source.files = (0..count)
            .map(|i| {
                let mut file = original.clone();
                file.path = format!("src/file{i}.rs");
                file
            })
            .collect();
        source
    }

    #[test]
    fn interrupted_large_batch_completes_on_smaller_distinct_batches() {
        let source = multi_file_snapshot(8);
        let mut rejected = HashSet::new();
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                let files = data["snapshot"]["files"].as_array().unwrap();
                if files.len() > 2 {
                    assert!(
                        rejected.insert(
                            files
                                .iter()
                                .map(|f| f["path"].as_str().unwrap().to_owned())
                                .collect::<Vec<_>>()
                        )
                    );
                    return Err(ReviewBatchInterrupted.into());
                }
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert!(!rejected.is_empty());
        assert_eq!(result.reviewed_files.unwrap().len(), 8);
        assert!(
            result.report.limits.is_empty(),
            "{:?}",
            result.report.limits
        );
    }

    #[test]
    fn persistent_interruptions_stop_after_a_small_probe() {
        let source = multi_file_snapshot(107);
        let mut sizes = Vec::new();
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                sizes.push(data["snapshot"]["files"].as_array().unwrap().len());
                Err(ReviewBatchInterrupted.into())
            },
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert_eq!(sizes, [107, 53, 1]);
        assert!(result.reviewed_files.unwrap().is_empty());
        assert_eq!(result.patch_files.unwrap().len(), 107);
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("three consecutive batches"))
        );
    }

    #[test]
    fn unanswerable_single_line_does_not_prevent_reviewing_its_sibling() {
        let source = multi_file_snapshot(2);
        let mut calls = 0;
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                calls += 1;
                let files = data["snapshot"]["files"].as_array().unwrap();
                if files[0]["path"] == "src/file0.rs" {
                    return Err(ReviewBatchInterrupted.into());
                }
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert_eq!(calls, 4);
        assert_eq!(result.reviewed_files.unwrap(), ["src/file1.rs"]);
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("smallest reviewable change in src/file0.rs"))
        );
    }

    #[test]
    fn terminal_rejection_during_challenge_does_not_retry_or_partition() {
        let source = multi_file_snapshot(4);
        let mut turns = 0;
        let result = review_snapshot_iterative(
            source,
            |_, _| {
                turns += 1;
                match turns {
                    1 => Ok(
                        json!({"complete":true,"hypotheses":[{"anchor":"H1","expected":"Jobs complete.","scenario":"A caller queues a job.","consequence":"The job could fail."}]}),
                    ),
                    2 => anyhow::bail!("Terminal provider rejection."),
                    _ => panic!("A terminal rejection must not be retried."),
                }
            },
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        );
        assert_eq!(turns, 2);
        assert_eq!(
            result.unwrap_err().to_string(),
            "Terminal provider rejection."
        );
    }

    #[test]
    fn published_manual_focus_keeps_the_highest_three_distinct_priorities_across_batches() {
        let result = review_snapshot_iterative(multi_file_snapshot(6), |_,data| {
            let path = data["snapshot"]["files"][0]["path"].as_str().unwrap();
            let action = if path.ends_with("5.rs") { "Try job src/file4.rs".to_owned() } else {format!("Try job {path}")};
            if data.get("hypotheses").is_none() {
                Ok(json!({"complete":true,"hypotheses":[{"anchor":"H1","expected":"The job completes.","scenario":"A caller queues a job.","consequence":"The job could fail."}]}))
            } else {
                let severity = if path.ends_with("4.rs") || path.ends_with("5.rs") { "high" } else { "low" };
                Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"manual_test","basis":"H1","action":action,"expected":"The submitted job completes once.","severity":severity,"countercheck":"Dispatching the job requires a running queue."}]}))
            }
        }, |_,_| Ok(Vec::new()), |_,data| Ok(data["snapshot"]["files"].as_array().unwrap().len() <= 1), &[]).unwrap();
        let paths: Vec<_> = result
            .report
            .focus
            .iter()
            .map(|focus| focus.path.as_str())
            .collect();
        assert_eq!(paths, ["src/file4.rs", "src/file0.rs", "src/file1.rs"]);
    }

    #[test]
    fn oversized_shared_intent_is_compacted_once_for_all_patches() {
        let mut source = multi_file_snapshot(107);
        source.intent = vec![
            "PR title".into(),
            format!("Commit message\n{}", "á".repeat(10000)),
        ];
        let mut fits_calls = 0;
        let mut model_calls = 0;
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                model_calls += 1;
                assert_eq!(data["snapshot"]["files"].as_array().unwrap().len(), 107);
                assert_eq!(data["snapshot"]["intent"], json!(["PR title"]));
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(Vec::new()),
            |_, data| {
                fits_calls += 1;
                Ok(data["snapshot"]["intent"].to_string().len() <= 1024)
            },
            &[],
        )
        .unwrap();
        assert_eq!(model_calls, 2);
        assert_eq!(fits_calls, 5);
        assert_eq!(result.reviewed_files.unwrap().len(), 107);
    }

    #[test]
    fn terminal_provider_failure_after_a_complete_chunk_is_returned_to_the_queue() {
        let mut calls = 0;
        let result = review_snapshot_iterative(
            multi_file_snapshot(2),
            |_, data| {
                calls += 1;
                if data["snapshot"]["files"][0]["path"] == "src/file1.rs" {
                    anyhow::bail!("Synthetic authentication failure");
                }
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(Vec::new()),
            |_, data| Ok(data["snapshot"]["files"].as_array().unwrap().len() == 1),
            &[],
        );
        assert_eq!(calls, 3);
        assert_eq!(
            result.unwrap_err().to_string(),
            "Synthetic authentication failure"
        );
    }

    #[test]
    fn provider_reported_overflow_compacts_shared_intent_without_splitting_the_pr_into_rows() {
        let mut source = multi_file_snapshot(107);
        source.intent = vec![
            "PR title".into(),
            format!("Commit message\n{}", "á".repeat(30000)),
        ];
        let mut calls = 0;
        let result = review_snapshot_iterative(
            source,
            |_, data| {
                calls += 1;
                assert!(
                    calls <= 3,
                    "The reported context failure must reduce shared PR metadata."
                );
                assert_eq!(data["snapshot"]["files"].as_array().unwrap().len(), 107);
                if data["snapshot"]["intent"].to_string().len() > 1024 {
                    return Err(ReviewContextExceeded.into());
                }
                assert_eq!(data["snapshot"]["intent"], json!(["PR title"]));
                if data.get("hypotheses").is_some() {
                    Ok(json!({"complete":true,"assessments":[]}))
                } else {
                    Ok(json!({"complete":true,"hypotheses":[]}))
                }
            },
            |_, _| Ok(Vec::new()),
            |_, _| Ok(true),
            &[],
        )
        .unwrap();
        assert_eq!(calls, 3);
        assert_eq!(result.reviewed_files.unwrap().len(), 107);
        assert!(
            result
                .report
                .limits
                .iter()
                .any(|l| l.contains("text was shortened"))
        );
    }
}
