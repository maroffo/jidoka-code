//! Display and address lines from a saved, pinned pull request diff.

use crate::{
    contracts::{DiffFile, Finding, PinnedDiff, PublishedReport, Snapshot},
    hunks,
    source::{safe_path, safe_previous_path},
};
use std::{collections::HashMap, fmt::Write};

type Row<'a> = (Option<usize>, Option<usize>, &'a str);

pub fn available(report: &PublishedReport) -> bool {
    report.diff.is_some()
}

/// Attach a diff only when it belongs to the exact revisions recorded in the report.
pub fn attach(report: &mut PublishedReport, snapshot: &Snapshot) {
    if report.repo.eq_ignore_ascii_case(&snapshot.repo)
        && report.base == snapshot.base
        && report.head == snapshot.head
        && let Some(diff) = &snapshot.diff
    {
        report.diff = Some(diff.clone());
    }
}

fn rows<'a>(diff: &PinnedDiff, file: &'a DiffFile) -> Option<Vec<Row<'a>>> {
    if diff
        .files
        .iter()
        .filter(|other| other.path == file.path)
        .count()
        != 1
    {
        return None;
    }
    let patch = file.patch.as_deref()?;
    if patch.contains('\0') {
        return None;
    }
    let rows = hunks::lines(patch)?;
    let valid = match file.status.as_str() {
        "added" => rows.iter().all(|row| row.0.is_none()),
        "removed" => rows.iter().all(|row| row.1.is_none()),
        "renamed" | "copied" => previous_path(file).is_some(),
        "modified" | "changed" => true,
        _ => false,
    };
    (valid && rows.iter().any(|row| row.0.is_none() || row.1.is_none())).then_some(rows)
}

fn file_id(index: usize) -> String {
    format!("diff-file-{}", index + 1)
}

fn head_id(file: &str, line: usize) -> String {
    format!("{file}-head-{line}")
}

/// Return the rendered ID only for a head line in a saved hunk.
pub fn anchor(report: &PublishedReport, path: &str, line: usize) -> Option<String> {
    if !safe_path(path) || line == 0 {
        return None;
    }
    let diff = report.diff.as_ref()?;
    let (index, file) = diff
        .files
        .iter()
        .enumerate()
        .find(|(_, file)| file.path == path)?;
    rows(diff, file)?
        .iter()
        .any(|row| row.1 == Some(line))
        .then(|| head_id(&file_id(index), line))
}

/// A patch with no head lines can only cite the base revision.
pub fn base_citation_path<'a>(
    report: &'a PublishedReport,
    path: &str,
    line: usize,
) -> Option<&'a str> {
    let diff = report.diff.as_ref()?;
    let file = diff.files.iter().find(|f| f.path == path)?;
    let lines = rows(diff, file)?;
    (lines.iter().all(|(_, head, _)| head.is_none())
        && lines.iter().any(|(base, _, _)| *base == Some(line)))
    .then(|| previous_path(file).unwrap_or(&file.path))
}

/// Match the quoted source on the head, or on the base when a file was removed or emptied.
pub fn matches_quote(report: &PublishedReport, path: &str, line: usize, quote: &str) -> bool {
    let Some(diff) = &report.diff else {
        return false;
    };
    let Some(file) = diff.files.iter().find(|f| f.path == path) else {
        return false;
    };
    !quote.trim().is_empty()
        && rows(diff, file).is_some_and(|rows| {
            let removed = rows.iter().all(|(_, head, _)| head.is_none());
            rows.iter().any(|(base, head, text)| {
                (*head == Some(line) || (removed && *base == Some(line)))
                    && text.trim_end_matches('\r') == quote.trim_end_matches('\r')
            })
        })
}

fn escape(text: &str) -> String {
    let mut escaped = String::new();
    for ch in text.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn previous_path(file: &DiffFile) -> Option<&str> {
    match file.status.as_str() {
        "renamed" | "copied" => safe_previous_path(&file.path, file.previous_path.as_deref()),
        _ => None,
    }
}

fn change_label(file: &DiffFile) -> &str {
    match file.status.as_str() {
        "added" => "Added",
        "removed" => "Removed",
        "renamed" if previous_path(file).is_some() => "Renamed",
        "copied" if previous_path(file).is_some() => "Copied",
        "modified" | "changed" => "Modified",
        _ => "Change type unavailable",
    }
}

type Findings<'a> = HashMap<(&'a str, usize), Vec<(usize, &'a Finding)>>;

fn render_rows(
    html: &mut String,
    file: &DiffFile,
    id: &str,
    rows: &[Row<'_>],
    findings: &Findings<'_>,
) {
    write!(html, r#"<div class="diff-scroll" role="region" aria-label="Diff for {}" tabindex="0">
        <table><thead><tr><th scope="col">Base</th><th scope="col">Head</th><th scope="col">Source</th></tr></thead><tbody>"#,
        escape(&file.path)).unwrap();
    let (mut last_base, mut last_head): (Option<usize>, Option<usize>) = (None, None);
    for &(base, head, text) in rows {
        let gap = |current: Option<usize>, previous: Option<usize>| {
            current
                .zip(previous)
                .is_some_and(|(current, previous)| previous.checked_add(1) != Some(current))
        };
        if gap(base, last_base) || gap(head, last_head) {
            html.push_str(
                r#"<tr class="diff-gap"><td colspan="3">Lines between hunks omitted</td></tr>"#,
            );
            last_base = None;
            last_head = None;
        }
        last_base = base.or(last_base);
        last_head = head.or(last_head);

        let (class, sign, label) = match (base, head) {
            (None, Some(_)) => ("diff-added", "+", "Added line"),
            (Some(_), None) => ("diff-removed", "−", "Removed line"),
            _ => ("diff-context", " ", "Context line"),
        };
        let noted = head.and_then(|line| findings.get(&(file.path.as_str(), line)));
        let flag = if noted.is_some() { " diff-flagged" } else { "" };
        write!(html, r#"<tr class="{class}{flag}""#).unwrap();
        let head_anchor = head.map(|line| head_id(id, line));
        if let Some(anchor) = &head_anchor {
            write!(html, r#" id="{anchor}""#).unwrap();
        }
        html.push_str(r#"><td class="diff-number">"#);
        if let Some(base) = base {
            write!(html, "{base}").unwrap();
        }
        html.push_str(r#"</td><td class="diff-number">"#);
        if let (Some(line), Some(anchor)) = (head, head_anchor) {
            write!(
                html,
                r##"<a href="#{anchor}" aria-label="Head line {line}">{line}</a>"##
            )
            .unwrap();
        }
        write!(html, r#"</td><td class="diff-code"><span class="diff-sr-only">{label} </span><span aria-hidden="true" class="diff-sign">{sign}</span><code>{}</code></td></tr>"#, escape(text)).unwrap();

        if let Some(items) = noted {
            html.push_str(
                r#"<tr class="diff-findings"><td colspan="3"><ul aria-label="Verified findings">"#,
            );
            for (number, item) in items {
                write!(
                    html,
                    r##"<li><strong>{}</strong><p>{}</p><a href="#{}">Read the finding</a></li>"##,
                    escape(&item.title),
                    escape(&item.impact),
                    finding_id(*number)
                )
                .unwrap();
            }
            html.push_str("</ul></td></tr>");
        }
    }
    html.push_str("</tbody></table></div>");
}

/// The ID of a finding card, shared by the report and the notes inside the diff.
pub fn finding_id(index: usize) -> String {
    format!("finding-{}", index + 1)
}

/// What the report says about a changed file. The order is the display order.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Mark {
    Finding(usize),
    Manual,
    Quiet,
}

impl Mark {
    fn group(self) -> (u8, &'static str) {
        match self {
            Mark::Finding(_) => (0, "Files with findings"),
            Mark::Manual => (1, "Files named in manual checks"),
            Mark::Quiet => (2, "Other changed files"),
        }
    }
}

struct Listed<'a> {
    index: usize,
    file: &'a DiffFile,
    mark: Mark,
    rows: Option<Vec<Row<'a>>>,
}

impl Listed<'_> {
    /// Added and removed line counts, when a text patch was saved.
    fn counts(&self) -> Option<(usize, usize)> {
        let rows = self.rows.as_ref()?;
        Some((
            rows.iter().filter(|row| row.0.is_none()).count(),
            rows.iter().filter(|row| row.1.is_none()).count(),
        ))
    }
}

fn listed<'a>(report: &'a PublishedReport, diff: &'a PinnedDiff) -> Vec<Listed<'a>> {
    diff.files
        .iter()
        .enumerate()
        .filter(|(_, file)| safe_path(&file.path))
        .map(|(index, file)| {
            let findings = report
                .report
                .findings
                .iter()
                .filter(|finding| finding.path == file.path)
                .count();
            let mark = if findings > 0 {
                Mark::Finding(findings)
            } else if report.manual_checks().any(|focus| focus.path == file.path) {
                Mark::Manual
            } else {
                Mark::Quiet
            };
            Listed {
                index,
                file,
                mark,
                rows: rows(diff, file),
            }
        })
        .collect()
}

fn split_path(path: &str) -> (&str, &str) {
    path.rfind('/')
        .map_or(("", path), |slash| path.split_at(slash + 1))
}

fn counts_html(counts: Option<(usize, usize)>) -> String {
    let Some((added, removed)) = counts else {
        return String::new();
    };
    let mut html = String::from(r#"<span class="diff-stat">"#);
    if added > 0 {
        write!(html, r#"<span class="diff-plus">+{added}</span>"#).unwrap();
    }
    if removed > 0 {
        write!(html, r#"<span class="diff-minus">−{removed}</span>"#).unwrap();
    }
    html.push_str("</span>");
    html
}

/// List the changed files by directory, in the order GitHub reported them.
fn navigation(files: &[Listed<'_>]) -> String {
    let mut html = String::from(r#"<h2>Changed files</h2><ul class="rail-files">"#);
    let mut last: Option<&str> = None;
    for item in files {
        let (dir, name) = split_path(&item.file.path);
        if last != Some(dir) && !(last.is_none() && dir.is_empty()) {
            let shown = if dir.is_empty() { "./" } else { dir };
            write!(
                html,
                r#"<li class="rail-dir" title="{0}">{0}</li>"#,
                escape(shown)
            )
            .unwrap();
        }
        last = Some(dir);
        let (tone, note) = match item.mark {
            Mark::Finding(1) => ("stop", " 1 finding".to_owned()),
            Mark::Finding(count) => ("stop", format!(" {count} findings")),
            Mark::Manual => ("hold", " manual check".to_owned()),
            Mark::Quiet => ("", String::new()),
        };
        let marked = if tone.is_empty() {
            ""
        } else {
            " class=\"marked\""
        };
        write!(
            html,
            r##"<li><a href="#{}"{marked}><span class="lamp {tone}" aria-hidden="true"></span><code>{}</code><span class="diff-sr-only">{note}</span>{}</a></li>"##,
            file_id(item.index),
            escape(name),
            counts_html(item.counts())
        )
        .unwrap();
    }
    html.push_str("</ul>");
    html
}

/// Render the file navigation for the side rail and the changed files section.
///
/// Files with findings come first, then files named in manual checks. Only those start open:
/// a long pull request stays readable, and every in-page citation lands on a visible row.
pub fn render(report: &PublishedReport) -> (String, String) {
    let mut html = String::from(
        r#"<section id="review-diff" class="review-diff" aria-labelledby="diff-heading"><h2 id="diff-heading">Changed files</h2>"#,
    );
    let Some(diff) = &report.diff else {
        html.push_str("<p>The pinned diff was not saved for this review.</p></section>");
        return (String::new(), html);
    };

    let mut files = listed(report, diff);
    let listed = files.len() as u64;
    if listed < diff.total_files {
        write!(
            html,
            "<p>The saved list includes {listed} of {} changed files.</p>",
            diff.total_files
        )
        .unwrap();
    } else if listed > diff.total_files {
        html.push_str("<p>The saved file list differs from the reported change count.</p>");
    } else if files.is_empty() {
        html.push_str("<p>No changed files were recorded.</p>");
    }

    let nav = if files.is_empty() {
        String::new()
    } else {
        navigation(&files)
    };
    let mut findings = Findings::new();
    for (number, item) in report.report.findings.iter().enumerate() {
        findings
            .entry((item.path.as_str(), item.line))
            .or_default()
            .push((number, item));
    }
    files.sort_by_key(|item| item.mark.group().0);
    let grouped = files
        .first()
        .zip(files.last())
        .is_some_and(|(first, last)| first.mark.group() != last.mark.group());
    let mut group = None;
    for item in &files {
        if grouped && group != Some(item.mark.group()) {
            group = Some(item.mark.group());
            write!(
                html,
                r#"<h3 class="diff-group">{}</h3>"#,
                item.mark.group().1
            )
            .unwrap();
        }
        let id = file_id(item.index);
        let (dir, name) = split_path(&item.file.path);
        let (open, tag) = match item.mark {
            Mark::Finding(1) => (
                " open",
                r#"<span class="diff-tag stop">1 finding</span>"#.to_owned(),
            ),
            Mark::Finding(count) => (
                " open",
                format!(r#"<span class="diff-tag stop">{count} findings</span>"#),
            ),
            Mark::Manual => (
                " open",
                r#"<span class="diff-tag hold">Manual check</span>"#.to_owned(),
            ),
            Mark::Quiet => ("", String::new()),
        };
        write!(
            html,
            r#"<details class="diff-file" id="{id}"{open}><summary><code class="diff-path"><span>{}</span>{}</code>{tag}<span class="diff-kind">{}"#,
            escape(dir),
            escape(name),
            change_label(item.file)
        )
        .unwrap();
        if let Some(previous) = previous_path(item.file) {
            write!(html, " from <code>{}</code>", escape(previous)).unwrap();
        }
        write!(html, "</span>{}</summary>", counts_html(item.counts())).unwrap();
        match &item.rows {
            Some(lines) => render_rows(&mut html, item.file, &id, lines, &findings),
            None => html.push_str(
                r#"<p class="diff-unavailable">No text patch was saved for this change.</p>"#,
            ),
        }
        html.push_str("</details>");
    }

    let mut supporting = diff
        .supporting_paths
        .iter()
        .filter(|path| safe_path(path))
        .peekable();
    if supporting.peek().is_some() {
        html.push_str(r#"<details class="diff-supporting"><summary>Supporting context</summary><p>These files were collected as context outside the saved diff.</p><ul>"#);
        for path in supporting {
            write!(html, "<li><code>{}</code></li>", escape(path)).unwrap();
        }
        html.push_str("</ul></details>");
    }
    html.push_str("</section>");
    (nav, html)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::{Attribution, Report};

    fn report(diff: Option<PinnedDiff>) -> PublishedReport {
        PublishedReport {
            repo: "owner/project".into(),
            base: "a".repeat(40),
            head: "b".repeat(40),
            report: Report::default(),
            scan: None,
            reviewed_files: None,
            patch_files: Some(vec!["original.rs".into()]),
            diff,
        }
    }

    fn file(path: &str, status: &str, patch: Option<&str>) -> DiffFile {
        DiffFile {
            path: path.into(),
            status: status.into(),
            previous_path: None,
            patch: patch.map(str::to_owned),
        }
    }

    #[test]
    fn removed_source_citations_publish_in_the_summary_at_the_base_revision() {
        for status in ["removed", "modified"] {
            let report = report(Some(PinnedDiff {
                total_files: 1,
                files: vec![file(
                    "gone.rs",
                    status,
                    Some("@@ -1 +0,0 @@\n-    old();\n"),
                )],
                supporting_paths: vec![],
            }));
            assert!(matches_quote(&report, "gone.rs", 1, "    old();"));
            assert!(!matches_quote(&report, "gone.rs", 1, "old();"));
            assert!(anchor(&report, "gone.rs", 1).is_none());
            let mut report = report;
            report.report.findings.push(Finding {
                path: "gone.rs".into(),
                line: 1,
                title: "Broken caller".into(),
                impact: "Impact".into(),
                evidence: "Evidence".into(),
                attribution: Attribution::Introduced,
            });
            let prepared = crate::publish::prepare(&report, &[0], true);
            assert!(prepared.comments.is_empty());
            assert!(
                prepared
                    .body
                    .contains(&format!("blob/{}/gone.rs#L1", report.base))
            );
        }
    }

    #[test]
    fn shows_one_navigation_and_uses_saved_head_rows_for_anchors_and_findings() {
        let path = "src/views<&>.rs";
        let patch = "@@ -8,2 +10,2 @@\n-old\n+<new & args>\n same\n@@ -21 +25 @@\n-before\n+later";
        let mut renamed = file(path, "renamed", Some(patch));
        renamed.previous_path = Some("src/old<&>.rs".into());
        let mut report = report(Some(PinnedDiff {
            total_files: 5,
            files: vec![
                renamed,
                file("assets/image.dat", "added", None),
                file("src/gone.rs", "removed", Some("@@ -1 +0,0 @@\n-gone")),
                file("src/quiet.rs", "added", Some("@@ -0,0 +1 @@\n+quiet")),
            ],
            supporting_paths: vec!["README.md".into()],
        }));
        report.report.findings.push(Finding {
            path: path.into(),
            line: 10,
            title: "Verify <range>".into(),
            impact: "A & B".into(),
            evidence: String::new(),
            attribution: Attribution::Unknown,
        });
        let (nav, html) = render(&report);
        assert!(!html.contains("<nav"));
        for text in ["views&lt;&amp;&gt;.rs", "image.dat", "gone.rs", "quiet.rs"] {
            assert_eq!(nav.matches(text).count(), 1, "{text}");
        }
        assert_eq!(nav.matches(r#"class="rail-dir""#).count(), 3);
        assert!(nav.contains(r##"<a href="#diff-file-1" class="marked"><span class="lamp stop""##));
        assert!(
            nav.contains(r#"<span class="diff-plus">+2</span><span class="diff-minus">−2</span>"#)
        );
        assert!(html.contains(r##"<a href="#finding-1">Read the finding</a>"##));
        assert!(html.contains("4 of 5 changed files"));
        assert!(html.contains("No text patch was saved for this change."));
        assert!(html.contains("Supporting context"));
        assert!(html.contains("README.md"));
        assert!(html.contains("src/old&lt;&amp;&gt;.rs"));
        assert!(html.contains("&lt;new &amp; args&gt;"));
        assert!(html.contains("Lines between hunks omitted"));
        assert!(html.contains("Verify &lt;range&gt;"));
        assert!(html.contains("A &amp; B"));
        assert!(html.contains("src/quiet.rs"));
        for (path, line) in [(path, 10), (path, 11), (path, 25), ("src/quiet.rs", 1)] {
            let id = anchor(&report, path, line).unwrap();
            assert_eq!(html.matches(&format!(r#"id="{id}""#)).count(), 1);
        }
        for (path, line) in [
            (path, 0),
            (path, 8),
            (path, 24),
            ("src/old<&>.rs", 10),
            ("assets/image.dat", 1),
            ("src/gone.rs", 1),
            ("README.md", 1),
        ] {
            assert!(anchor(&report, path, line).is_none(), "{path}:{line}");
        }
    }

    #[test]
    fn unsafe_paths_ambiguous_files_and_invalid_patches_have_no_head_anchor() {
        let patch = Some("@@ -0,0 +1 @@\n+new");
        let report = report(Some(PinnedDiff {
            total_files: 5,
            files: vec![
                file("../escape.rs", "added", patch),
                file("twice.rs", "added", patch),
                file("twice.rs", "added", patch),
                file("bad.rs", "modified", Some("@@ -1,2 +1,2 @@\n-old\n+new")),
                file("removed.rs", "removed", patch),
            ],
            supporting_paths: vec![],
        }));
        let (nav, html) = render(&report);
        assert!(!nav.contains("escape.rs"));
        assert!(!html.contains("escape.rs"));
        assert!(!html.contains("-head-1"));
        for path in ["../escape.rs", "twice.rs", "bad.rs", "removed.rs"] {
            assert!(anchor(&report, path, 1).is_none());
        }
    }

    #[test]
    fn unsafe_rename_sources_have_no_label_or_anchor() {
        let patch = Some("@@ -1 +1 @@\n-old\n+new");
        let mut invalid = file("src/current.rs", "renamed", patch);
        invalid.previous_path = Some("../unsafe.rs".into());
        let mut modified = file("src/other.rs", "modified", patch);
        modified.previous_path = Some("src/unrelated.rs".into());
        let report = report(Some(PinnedDiff {
            total_files: 2,
            files: vec![invalid, modified],
            supporting_paths: vec![],
        }));
        let (_, html) = render(&report);
        assert!(html.contains("Change type unavailable"));
        for text in ["Renamed", "../unsafe.rs", "src/unrelated.rs"] {
            assert!(!html.contains(text));
        }
        assert!(anchor(&report, "src/current.rs", 1).is_none());
        assert!(anchor(&report, "src/other.rs", 1).is_some());
    }

    #[test]
    fn attaches_for_matching_revisions_and_reads_legacy_reports() {
        let old = serde_json::to_value(report(None)).unwrap();
        assert!(old.get("diff").is_none());
        let mut report: PublishedReport = serde_json::from_value(old).unwrap();
        assert!(!available(&report));
        assert!(
            render(&report)
                .1
                .contains("The pinned diff was not saved for this review.")
        );
        assert!(anchor(&report, "original.rs", 1).is_none());
        let mut snapshot = Snapshot {
            url: "https://github.com/owner/project/pull/1".into(),
            repo: report.repo.clone(),
            number: 1,
            base: report.base.clone(),
            head: "c".repeat(40),
            intent: vec![],
            files: vec![],
            limits: vec![],
            head_context: vec![],
            diff: Some(PinnedDiff {
                total_files: 1,
                files: vec![file("fixture.rs", "added", Some("@@ -0,0 +1 @@\n+new"))],
                supporting_paths: vec![],
            }),
        };
        attach(&mut report, &snapshot);
        assert!(!available(&report));
        snapshot.head = report.head.clone();
        snapshot.base = "c".repeat(40);
        attach(&mut report, &snapshot);
        assert!(!available(&report));
        snapshot.base = report.base.clone();
        snapshot.repo = "other/project".into();
        attach(&mut report, &snapshot);
        assert!(!available(&report));
        snapshot.repo = report.repo.to_ascii_uppercase();
        attach(&mut report, &snapshot);
        assert!(available(&report));
        assert_eq!(report.patch_files.as_deref().unwrap(), ["original.rs"]);
        let saved: PublishedReport =
            serde_json::from_str(&serde_json::to_string(&report).unwrap()).unwrap();
        assert_eq!(
            anchor(&saved, "fixture.rs", 1),
            Some("diff-file-1-head-1".into())
        );
    }
}
