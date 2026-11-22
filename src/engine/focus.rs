//! Build assessment inputs from the canonical, discovery-indexed snapshot.
use super::*;
use std::collections::{BTreeMap, BTreeSet};

const NEIGHBOR_ROWS: usize = 12;

#[derive(Default)]
pub(super) struct VisibleEvidence {
    pub references: HashSet<String>,
    pub complete: HashSet<String>,
    pub next_pages: HashSet<String>,
    uncitable: HashMap<String, HashSet<usize>>,
}

type Windows = BTreeMap<String, Vec<Range<usize>>>;

#[derive(Default)]
pub(super) struct AssessmentContext {
    returned: HashMap<(String, String), Windows>,
    cited: HashMap<u64, HashSet<String>>,
    changed_paths: Vec<String>,
    supporting_paths: Vec<String>,
}

fn values(value: &Value) -> impl Iterator<Item = &Value> {
    value.as_array().into_iter().flatten()
}

fn fields_except(value: &Value, keys: &[&str]) -> Value {
    Value::Object(
        value
            .as_object()
            .expect("review object")
            .iter()
            .filter(|(key, _)| !keys.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    )
}

fn spans(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.sort_unstable_by_key(|r| r.start);
    let mut result: Vec<Range<usize>> = Vec::new();
    for r in ranges {
        if let Some(last) = result.last_mut()
            && r.start <= last.end
        {
            last.end = last.end.max(r.end);
        } else {
            result.push(r);
        }
    }
    result
}

fn cited_by(item: &Value) -> impl Iterator<Item = &str> {
    [
        &item["basis"],
        &item["comparison"]["basis"],
        &item["comparison"]["behavior"],
    ]
    .into_iter()
    .chain(values(&item["support"]))
    .chain(values(&item["counterevidence"]["references"]))
    .filter_map(Value::as_str)
}

impl AssessmentContext {
    pub fn new(snapshot: &Snapshot) -> Self {
        Self {
            changed_paths: snapshot
                .files
                .iter()
                .filter(|f| !f.patch.is_empty())
                .map(|f| f.path.clone())
                .collect(),
            supporting_paths: snapshot
                .files
                .iter()
                .filter(|f| f.patch.is_empty())
                .map(|f| f.path.clone())
                .collect(),
            ..Self::default()
        }
    }
    pub fn record(&mut self, read: &ContextRead, windows: &[SourceWindow]) {
        let returned = self
            .returned
            .entry((read.path.clone(), read.term.clone()))
            .or_default();
        for w in windows.iter().filter(|w| safe_path(&w.path) && w.start > 0) {
            if let Some(end) = w.start.checked_add(w.text.lines().count()) {
                returned
                    .entry(w.path.clone())
                    .or_default()
                    .push(w.start..end);
            }
        }
    }

    pub fn remember_reply(&mut self, reply: &Value, data: &Value, view: Option<&VisibleEvidence>) {
        let active: HashSet<_> = values(&data["hypotheses"])
            .filter_map(|h| h["id"].as_u64())
            .collect();
        for item in values(&reply["assessments"]) {
            let Some(id) = item["id"].as_u64().filter(|id| active.contains(id)) else {
                continue;
            };
            self.cited.entry(id).or_default().extend(
                cited_by(item)
                    .filter(|r| view.is_none_or(|v| v.references.contains(*r)))
                    .map(str::to_owned),
            );
        }
    }

    pub fn project(
        &self,
        data: &Value,
        evidence: &Evidence<'_>,
    ) -> Option<(Value, VisibleEvidence)> {
        let hypotheses = data.get("hypotheses")?.as_array()?;
        // With no proposed checks, the independent challenge still sees the complete batch.
        if hypotheses.is_empty() {
            return None;
        }
        let active: HashSet<_> = hypotheses.iter().filter_map(|h| h["id"].as_u64()).collect();
        let mut diff_pages = diff_read::DiffPages::new(&evidence.read_owners, &active);
        let mut seeds = HashSet::new();
        for h in hypotheses {
            seeds.extend(
                std::iter::once(&h["anchor"])
                    .chain(values(&h["related"]))
                    .filter_map(Value::as_str),
            );
        }
        for id in &active {
            seeds.extend(self.cited.get(id).into_iter().flatten().map(String::as_str));
        }
        let mut requested = Windows::new();
        for (key, owners) in &evidence.read_owners {
            if owners.is_disjoint(&active) {
                continue;
            }
            if let Some(result) = self.returned.get(key) {
                for (path, ranges) in result {
                    requested
                        .entry(path.clone())
                        .or_default()
                        .extend(ranges.iter().cloned());
                }
            }
        }
        let source = &data["snapshot"];
        let index = evidence.references.as_ref()?;
        let mut snapshot = fields_except(source, &["files", "head_context", "complete_head_paths"]);
        let mut view = VisibleEvidence::default();
        let mut selected_paths = HashSet::new();
        let mut files = Vec::new();
        for file in values(&source["files"]) {
            let path = file["path"].as_str()?;
            let mut requested_sections = diff_pages.open(path, file["sections"].as_array()?);
            let mut sections = Vec::new();
            for (section_index, section) in values(&file["sections"]).enumerate() {
                let rows = section.as_array()?;
                let opened = requested.get(path);
                let intersects = |row: &Value, side: usize, revision: Revision| {
                    opened.is_some_and(|ranges| {
                        index
                            .resolve(&row[side], revision)
                            .is_some_and(|cite| ranges.iter().any(|r| r.contains(&cite.line)))
                    })
                };
                let opened_hunk = file["scope"] == "hunks"
                    && opened.is_some()
                    && rows.iter().any(|row| intersects(row, 1, Revision::Head));
                let ranges = spans(
                    rows.iter()
                        .enumerate()
                        .filter(|(_, row)| {
                            [0, 1]
                                .into_iter()
                                .any(|side| row[side].as_str().is_some_and(|id| seeds.contains(id)))
                                || (opened_hunk
                                    && (intersects(row, 1, Revision::Head)
                                        || intersects(row, 0, Revision::Base)))
                        })
                        .map(|(i, _)| {
                            i.saturating_sub(NEIGHBOR_ROWS)..rows.len().min(i + NEIGHBOR_ROWS + 1)
                        })
                        .chain(
                            requested_sections
                                .remove(&section_index)
                                .into_iter()
                                .flatten(),
                        )
                        .collect(),
                );
                for range in ranges {
                    let start = range.start;
                    let slice = &rows[range];
                    for (offset, row) in slice.iter().enumerate() {
                        if let Some(line) =
                            index
                                .uncitable_rows
                                .get(&(path, section_index, start + offset))
                        {
                            view.uncitable
                                .entry(path.to_owned())
                                .or_default()
                                .insert(*line);
                        }
                        view.references.extend(
                            [0, 1]
                                .into_iter()
                                .filter_map(|side| row[side].as_str().map(str::to_owned)),
                        );
                    }
                    sections.push(json!(slice));
                }
            }
            if !sections.is_empty() {
                selected_paths.insert(path);
                files.push(json!({"path":path,"scope":file["scope"],"sections":sections}));
            }
        }
        // Head-only discovery windows may contain proposal anchors, contracts or prior caller references.
        for w in values(&source["head_context"]) {
            let path = w["path"].as_str()?;
            let start = usize::try_from(w["start"].as_u64()?).ok()?;
            let rows = w["rows"].as_array()?;
            for (i, row) in rows.iter().enumerate() {
                if row[1].as_str().is_some_and(|id| seeds.contains(id))
                    && let Some(end) = start.checked_add(rows.len().min(i + NEIGHBOR_ROWS + 1))
                {
                    requested
                        .entry(path.to_owned())
                        .or_default()
                        .push(start + i.saturating_sub(NEIGHBOR_ROWS)..end);
                }
            }
        }
        let mut head_context = Vec::new();
        let mut head_ranges = Windows::new();
        for (path, ranges) in requested {
            for r in spans(ranges) {
                let mut rows = Vec::new();
                for line in r.clone() {
                    let Some((quote, id)) = index.head_lines.get(&(path.as_str(), line)) else {
                        break;
                    };
                    let id = id.map(|n| format!("H{n}"));
                    if let Some(id) = &id {
                        view.references.insert(id.clone());
                    } else {
                        view.uncitable.entry(path.clone()).or_default().insert(line);
                    }
                    rows.push(json!([null, id, quote]));
                }
                if !rows.is_empty() {
                    head_ranges
                        .entry(path.clone())
                        .or_default()
                        .push(r.start..r.start + rows.len());
                    head_context.push(json!({"path":path,"start":r.start,"rows":rows}));
                }
            }
        }
        let mut complete = BTreeSet::new();
        for path in values(&source["complete_head_paths"]).filter_map(Value::as_str) {
            let Some(file) = evidence.source.get(path) else {
                continue;
            };
            // A previously complete canonical file may have only one hunk in the focused request.
            if (1..=file.head.len()).all(|line| {
                view.uncitable
                    .get(path)
                    .is_some_and(|lines| lines.contains(&line))
                    || head_ranges
                        .get(path)
                        .is_some_and(|ranges| ranges.iter().any(|r| r.contains(&line)))
                    || index
                        .head_lines
                        .get(&(path, line))
                        .and_then(|(_, id)| *id)
                        .is_some_and(|id| view.references.contains(&format!("H{id}")))
            }) {
                complete.insert(path);
            }
        }
        view.complete = complete.iter().map(|p| (*p).to_owned()).collect();
        snapshot["complete_head_paths"] = json!(complete);
        snapshot["files"] = json!(files);
        snapshot["changed_paths"] = json!(self.changed_paths);
        if !self.supporting_paths.is_empty() {
            snapshot["supporting_paths"] = json!(self.supporting_paths);
        }
        let pages = diff_pages.finish();
        if !pages.is_empty() {
            for page in &pages {
                if let (Some(path), Some(next)) = (page["path"].as_str(), page["next"].as_str()) {
                    view.next_pages.insert(format!("{path} {next}"));
                }
            }
            snapshot["diff_pages"] = json!(pages);
        }
        snapshot["head_context"] = json!(head_context);
        // Discovery already read all commit messages. Keep the PR intent and supplemental
        // messages that explicitly describe a file in the current assessment.
        if let Some(intent) = snapshot["intent"].as_array_mut() {
            intent.retain(|value| {
                value.as_str().is_none_or(|s| {
                    !s.starts_with("Commit message\n")
                        || selected_paths.iter().any(|path| s.contains(path))
                        || head_ranges.keys().any(|path| s.contains(path))
                })
            });
        }
        let mut request = fields_except(data, &["snapshot", "scan"]);
        request["snapshot"] = snapshot;
        let mut scan = data["scan"].clone();
        if let Some(signals) = scan["signals"].as_array_mut() {
            signals.retain(|s| {
                let (Some(path), Some(line)) = (
                    s["path"].as_str(),
                    s["line"].as_u64().and_then(|l| usize::try_from(l).ok()),
                ) else {
                    return false;
                };
                view.complete.contains(path)
                    || index
                        .head_lines
                        .get(&(path, line))
                        .and_then(|(_, id)| *id)
                        .is_some_and(|id| view.references.contains(&format!("H{id}")))
            });
        }
        if let Some(covered) = scan["covered"].as_array_mut() {
            covered.retain(|p| {
                p.as_str()
                    .is_some_and(|p| selected_paths.contains(p) || head_ranges.contains_key(p))
            });
        }
        request["scan"] = scan;
        Some((request, view))
    }
    pub fn adds_evidence(&self, data: &Value, evidence: &Evidence<'_>) -> bool {
        let Some(previous) = evidence.view.as_ref() else {
            return false;
        };
        let Some((_, next)) = self.project(data, evidence) else {
            return false;
        };
        !next.references.is_subset(&previous.references)
            || !next.complete.is_subset(&previous.complete)
            || !next.next_pages.is_subset(&previous.next_pages)
            || next.uncitable.iter().any(|(path, lines)| {
                previous
                    .uncitable
                    .get(path)
                    .is_none_or(|seen| !lines.is_subset(seen))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Snapshot {
        let guards: Vec<_> = (1..=70).map(|i| format!("check_{i}();")).collect();
        let guard_text = guards.join("\n");
        let guard_patch = format!(
            "@@ -1,70 +1,70 @@\n-previous_check();\n+{}\n{}",
            guards[0],
            guards[1..]
                .iter()
                .map(|s| format!(" {s}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
        let mut old = guards.clone();
        old[0] = "previous_check();".into();
        serde_json::from_value(json!({"url":"https://github.com/test/repo/pull/1","repo":"test/repo","number":1,"base":"before","head":"after","intent":[],"limits":[],"files":[
            {"path":"main.rs","before":old.join("\n"),"after":guard_text,"patch":guard_patch},
            {"path":"sibling.rs","before":"return old_state;","after":"return current_state;","patch":"@@ -1 +1 @@\n-return old_state;\n+return current_state;"}
        ]})).unwrap()
    }

    #[test]
    fn an_open_hidden_sibling_restores_stable_head_and_base_rows_even_when_already_indexed() {
        let mut stage = 0;
        let mut anchor = Value::Null;
        let mut sibling = Value::Null;
        let result=review_snapshot_iterative(fixture(),|_,data|{
            stage+=1;
            let files=data["snapshot"]["files"].as_array().unwrap();
            match stage {
                1=>{
                    anchor=files[0]["sections"][0][1][1].clone();
                    sibling=files[1].clone();
                    Ok(json!({"complete":true,"hypotheses":[{"anchor":anchor,"expected":"Preserve the caller contract.","scenario":"The sibling reads the current state.","consequence":"A consumer may see a different state."}]}))
                }
                2=>{
                    assert_eq!(files.len(),1);
                    assert!(!data["snapshot"]["complete_head_paths"].as_array().unwrap().contains(&json!("main.rs")));
                    Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"indeterminate","countercheck":"Compare the sibling before and after this change.","reads":[{"path":"sibling.rs","term":"#L1"}]}]}))
                }
                3=>{
                    assert!(files.contains(&sibling),"The request must include the original B/H rows for the opened sibling.");
                    let returned=&data["snapshot"]["head_context"][0]["rows"][0][1];
                    assert_eq!(returned,&sibling["sections"][0][1][1]);
                    Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"refuted","basis":returned,"countercheck":"The sibling reads the current state."}]}))
                }
                _=>panic!("Unexpected extra model turn")
            }
        },|_,_|Ok(vec![SourceWindow{path:"sibling.rs".into(),start:1,text:"return current_state;".into()}]),|_,_|Ok(true),&[]).unwrap();
        assert_eq!(stage, 3);
        assert!(result.report.limits.is_empty());
    }

    #[test]
    fn narrowed_evidence_rejects_guessed_citations_and_absence_in_a_partly_visible_file() {
        let snapshot = fixture();
        let mut limits = Vec::new();
        let source = source_index(&snapshot, &mut limits);
        let (mut data, refs) = indexed_input(&snapshot, &Scan::default(), &source, &mut limits);
        let anchor = data["snapshot"]["files"][0]["sections"][0][1][1].clone();
        let hidden = data["snapshot"]["files"][0]["sections"][0][69][1].clone();
        data["hypotheses"] = json!([{"id":1,"anchor":anchor}]);
        let mut evidence = Evidence {
            source,
            references: Some(refs),
            interactive: true,
            view: None,
            read_owners: HashMap::new(),
        };
        assert!(evidence.citation(&hidden, Revision::Head).is_some());
        let (_, visible) = AssessmentContext::default()
            .project(&data, &evidence)
            .unwrap();
        evidence.view = Some(visible);
        assert!(evidence.citation(&hidden, Revision::Head).is_none());
        assert!(evidence.citation(&anchor, Revision::Head).is_some());
        assert!(
            evidence
                .counterevidence(
                    &json!({"counterevidence":{"references":[anchor],"absence_paths":["main.rs"]}})
                )
                .is_err()
        );
    }
    #[test]
    fn blank_lines_count_only_when_present_in_the_projected_hunk_or_opened_window() {
        let snapshot=serde_json::from_value(json!({"url":"https://github.com/test/repo/pull/1","repo":"test/repo","number":1,"base":"before","head":"after","intent":[],"limits":[],
            "files":[
                {"path":"whole.rs","before":"","after":"first();\n \t\nlast();","patch":"@@ -0,0 +1,3 @@\n+first();\n+ \t\n+last();"},
                {"path":"partial.rs","before":"old_first();\n \t\nold_last();","after":"first();\n \t\nlast();","patch":"@@ -1 +1 @@\n-old_first();\n+first();\n@@ -3 +3 @@\n-old_last();\n+last();"}],
            "head_context":[{"path":"partial.rs","start":2,"text":" \t"}]
        })).unwrap();
        let mut turn = 0;
        let mut main = Value::Null;
        let mut partial = Value::Null;
        let result=review_snapshot_iterative(snapshot,|_,data|{
            turn+=1;
            let complete=data["snapshot"]["complete_head_paths"].as_array().unwrap();
            let files=data["snapshot"]["files"].as_array().unwrap();
            match turn {
                1=>{
                    assert_eq!(complete.len(),2);
                    main=files[0]["sections"][0][0][1].clone();
                    partial=files[1]["sections"][0][1][1].clone();
                    let last=files[1]["sections"][1][1][1].clone();
                    Ok(json!({"complete":true,"hypotheses":[{"anchor":main,"expected":"Preserve the input.","scenario":"The caller submits a value.","consequence":"The result changes."},{"anchor":partial,"related":[last],"expected":"Preserve the input.","scenario":"A second caller submits a value.","consequence":"The result changes."}]}))
                }
                2=>{
                    assert!(complete.contains(&json!("whole.rs")));
                    assert!(!complete.contains(&json!("partial.rs")));
                    Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"refuted","basis":main,"countercheck":"The first entry point preserves the input."},{"id":2,"outcome":"indeterminate","countercheck":"Read the omitted line to establish file coverage.","reads":[{"path":"partial.rs","term":"#L2"}]}]}))
                }
                3=>{
                    assert!(complete.contains(&json!("partial.rs")));
                    Ok(json!({"complete":true,"assessments":[{"id":2,"outcome":"refuted","basis":partial,"countercheck":"The entire second file preserves the input."}]}))
                }
                _=>panic!("Extra turn after viewing the missing line")
            }
        },|_,_|Ok(vec![SourceWindow{path:"partial.rs".into(),start:2,text:" \t".into()}]),|_,_|Ok(true),&[]).unwrap();
        assert_eq!(turn, 3);
        assert!(result.report.limits.is_empty());
    }

    #[test]
    fn a_pending_hypothesis_can_reopen_a_settled_siblings_cached_lookup() {
        let mut turn = 0;
        let mut calls = Vec::new();
        let question = |id, path| json!({"id":id,"outcome":"indeterminate","countercheck":"Inspect the code on the caller path.","reads":[{"path":path,"term":"guard"}]});
        let result=review_snapshot_iterative(fixture(),|_,data|{
            turn+=1;
            let windows=data["snapshot"]["head_context"].as_array().unwrap();
            let shared=windows.iter().find(|w|w["path"]=="shared.rs");
            match turn {
                1=>Ok(json!({"complete":true,"hypotheses":(["H1","H71"].map(|anchor|json!({"anchor":anchor,"expected":"Respect the guard.","scenario":"The caller changes state.","consequence":"An update could be lost."})))})),
                2=>Ok(json!({"complete":true,"assessments":[question(1,"shared.rs"),question(2,"first.rs")]})),
                3=>Ok(json!({"complete":true,"assessments":[{"id":1,"outcome":"refuted","countercheck":"The guard rejects invalid updates.","basis":shared.unwrap()["rows"][0][1]},question(2,"hop.rs")]})),
                4=>{
                    assert!(shared.is_none(),"The completed sibling no longer owns a visible window.");
                    Ok(json!({"complete":true,"assessments":[question(2,"shared.rs")]}))
                }
                5=>Ok(json!({"complete":true,"assessments":[{"id":2,"outcome":"refuted","countercheck":"The second caller shares the same guard.","basis":shared.unwrap()["rows"][0][1]}]})),
                _=>panic!("Extra turn after reviewing the cached lookup")
            }
        },|_,requests|{
            let path=&requests[0].path;calls.push(path.clone());
            Ok(vec![SourceWindow{path:path.clone(),start:10,text:"guard(input)".into()}])
        },|_,_|Ok(true),&[]).unwrap();
        assert_eq!(calls, ["shared.rs", "first.rs", "hop.rs"]);
        assert_eq!(turn, 5);
        assert!(result.report.limits.is_empty());
    }
}
