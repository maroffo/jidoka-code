use super::{HEAD_WINDOWS, SourceWindow, WINDOW_BYTES};
use std::collections::{BTreeMap, HashSet};

/// Names followed by a parenthesis are leads for locating related code, not a call graph.
fn call_names(line: &str) -> impl Iterator<Item = &str> {
    line.match_indices('(').filter_map(move |(at, _)| {
        let prefix = line[..at].trim_end();
        let name = prefix
            .rsplit(|c: char| !c.is_alphanumeric() && c != '_')
            .next()?;
        (name.len() >= 4
            && !matches!(
                name,
                "while" | "switch" | "catch" | "return" | "function" | "match"
            ))
        .then_some(name)
    })
}

pub(super) fn append(
    file: &super::SourceFile,
    text: &str,
    changed: &[usize],
    windows: &mut Vec<SourceWindow>,
    remaining: &mut usize,
) {
    let names: HashSet<_> = file
        .patch
        .lines()
        .filter_map(|line| line.strip_prefix('+'))
        .flat_map(call_names)
        .collect();
    if names.is_empty() || *remaining == 0 || windows.len() >= HEAD_WINDOWS {
        return;
    }
    let lines: Vec<_> = text.split_inclusive('\n').collect();
    let mut sites = BTreeMap::new();
    for (index, line) in lines.iter().enumerate() {
        if changed.binary_search(&(index + 1)).is_ok() {
            continue;
        }
        for name in call_names(line).filter(|name| names.contains(name)) {
            let matches = sites.entry(name).or_insert_with(Vec::new);
            if matches.last() != Some(&index) {
                matches.push(index);
            }
        }
    }
    // A distinctive name usually buys more context than another common helper call.
    let mut sites: Vec<_> = sites.into_iter().collect();
    sites.sort_by_key(|(name, matches)| (matches.len(), *name));
    let max_windows = (windows.len() + 2).min(HEAD_WINDOWS);
    for index in sites.iter().flat_map(|(_, matches)| matches) {
        if windows.len() == max_windows || *remaining == 0 {
            break;
        }
        let start = index.saturating_sub(3);
        let end = (index + 4).min(lines.len());
        if windows.iter().any(|w| {
            w.path == file.path && start < w.start - 1 + w.text.lines().count() && w.start - 1 < end
        }) {
            continue;
        }
        let bytes: usize = lines[start..end].iter().map(|line| line.len()).sum();
        if bytes <= WINDOW_BYTES.min(*remaining) {
            *remaining -= bytes;
            windows.push(SourceWindow {
                path: file.path.clone(),
                start: start + 1,
                text: lines[start..end].concat(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::SourceFile;

    #[test]
    fn includes_distant_uses_of_a_changed_function_within_budget() {
        let file = SourceFile {
            path: "app.rs".into(),
            patch: "@@ -1 +1 @@\n-old\n+fn normalize(input: &str) {".into(),
            before: String::new(),
            after: String::new(),
        };
        let text = format!(
            "fn normalize(input: &str) {{\n{}let stored = normalize(value);\n",
            "// other\n".repeat(60)
        );
        let mut windows = Vec::new();
        let mut budget = 200;
        append(&file, &text, &[1], &mut windows, &mut budget);
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].start, 59);
        assert!(
            windows[0]
                .text
                .ends_with("let stored = normalize(value);\n")
        );
        assert_eq!(budget + windows[0].text.len(), 200);
        append(&file, &text, &[1], &mut windows, &mut budget);
        assert_eq!(windows.len(), 1);
    }
}
