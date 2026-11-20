//! Bounded, on-demand reads from the pinned head of a pull request.

use super::{
    Entry, GitHub, PULL_BYTES, Pull, Transport, Tree, WINDOW_BLOB_BYTES, WINDOW_BYTES,
    WINDOW_RADIUS, generated_path, github, module_basename, parent, pull_url, safe_path, sha,
    test_path,
};
use crate::contracts::{ContextRead, Snapshot, SourceWindow};
use anyhow::{Result, ensure};
use std::{cmp::Reverse, collections::HashSet};

const MAX_READS: usize = 3;
const WINDOWS_PER_READ: usize = 2;
const MAX_TEXT: usize = 12_000;

/// Read literal matches from at most three paths or module stems at the pinned PR head.
pub fn read_context(
    snapshot: &Snapshot,
    allowed: &HashSet<String>,
    requests: &[ContextRead],
) -> Result<Vec<SourceWindow>> {
    read_with(&mut github()?, snapshot, allowed, requests)
}

pub(super) fn read_with<T: Transport>(
    hub: &mut GitHub<T>,
    snapshot: &Snapshot,
    allowed: &HashSet<String>,
    requests: &[ContextRead],
) -> Result<Vec<SourceWindow>> {
    let (repo, number) = pull_url(&snapshot.url, allowed)?;
    ensure!(
        repo.eq_ignore_ascii_case(&snapshot.repo) && number == snapshot.number,
        "Snapshot does not match the pull request."
    );
    sha(&snapshot.head)?;
    let requests: Vec<_> = requests
        .iter()
        .take(MAX_READS)
        .filter(|request| {
            safe_path(&request.path)
                && request.term.len() <= 256
                && !request.term.trim().is_empty()
                && !request.term.contains(['\0', '\r', '\n'])
        })
        .collect();
    if requests.is_empty() {
        return Ok(Vec::new());
    }

    let route = format!("{repo}/pulls/{number}");
    let mut pull: Pull = hub.get(&route, PULL_BYTES, false)?;
    pull.validate(&repo, number, allowed)?;
    ensure!(
        pull.head.sha == snapshot.head,
        "The pull request head has changed."
    );
    let mut head = Tree::new(&pull.head.repo.full_name, &snapshot.head);
    let mut inventory = None;
    let mut remaining = MAX_TEXT;
    let mut windows = Vec::new();
    for request in requests {
        if remaining == 0 {
            break;
        }
        let stem = request
            .path
            .chars()
            .all(|ch| ch.is_alphanumeric() || matches!(ch, '-' | '_' | '$'));
        let paths = if !stem || head.entry(hub, &request.path).ok().flatten().is_some() {
            vec![request.path.as_str()]
        } else {
            let entries = inventory.get_or_insert_with(|| head.inventory(hub, &snapshot.files));
            stem_paths(entries, &request.path, snapshot)
        };
        let files: Vec<_> = paths
            .into_iter()
            .filter_map(|path| {
                head.text(hub, path, WINDOW_BLOB_BYTES)
                    .ok()
                    .flatten()
                    .map(|text| (path, text))
            })
            .collect();
        let limit = windows.len() + WINDOWS_PER_READ;
        // Give tied files one excerpt each before spending a second slot on either file.
        for _ in 0..WINDOWS_PER_READ {
            for (path, text) in &files {
                if windows.len() == limit || remaining == 0 {
                    break;
                }
                if let Some(window) = next_window(path, text, &request.term, &windows, remaining) {
                    remaining -= window.text.len();
                    windows.push(window);
                }
            }
        }
    }
    let mut final_pull: Pull = hub.get(&route, PULL_BYTES, true)?;
    final_pull.validate(&repo, number, allowed)?;
    ensure!(
        pull.same_revisions(&final_pull),
        "The pull request changed during context reads."
    );
    Ok(windows)
}

fn implementation(path: &str) -> bool {
    !test_path(path)
        && !generated_path(path)
        && !parent(path)
            .1
            .to_ascii_lowercase()
            .split('.')
            .skip(1)
            .any(|part| {
                matches!(
                    part,
                    "d" | "types"
                        | "type"
                        | "stories"
                        | "story"
                        | "md"
                        | "mdx"
                        | "rst"
                        | "adoc"
                        | "txt"
                )
            })
        && !["index", "mod", "__init__"]
            .iter()
            .any(|barrel| module_basename(path).eq_ignore_ascii_case(barrel))
}

fn proximity(path: &str, snapshot: &Snapshot) -> (usize, Reverse<usize>) {
    let directory = parent(path).0;
    snapshot
        .files
        .iter()
        .filter(|file| !file.patch.is_empty())
        .map(|file| {
            let changed = parent(&file.path).0;
            let shared = directory
                .split('/')
                .zip(changed.split('/'))
                .take_while(|(a, b)| !a.is_empty() && a == b)
                .count();
            let distance = directory.split('/').filter(|part| !part.is_empty()).count()
                + changed.split('/').filter(|part| !part.is_empty()).count()
                - 2 * shared;
            (shared, Reverse(distance))
        })
        .max()
        .unwrap_or((0, Reverse(0)))
}

fn stem_paths<'a>(inventory: &'a [Entry], stem: &str, snapshot: &Snapshot) -> Vec<&'a str> {
    let folded = stem.to_lowercase();
    let mut matches: Vec<_> = inventory
        .iter()
        .filter(|entry| {
            let module = module_basename(&entry.path);
            (module.eq_ignore_ascii_case(stem) || module.to_lowercase() == folded)
                && safe_path(&entry.path)
                && entry
                    .file_size()
                    .is_some_and(|size| size <= WINDOW_BLOB_BYTES)
        })
        .map(|entry| {
            let path = entry.path.as_str();
            ((implementation(path), proximity(path, snapshot)), path)
        })
        .collect();
    matches.sort_unstable_by_key(|&(rank, path)| (Reverse(rank), path));
    matches.dedup_by_key(|item| item.1);
    let Some(&(best, _)) = matches.first() else {
        return Vec::new();
    };
    matches
        .into_iter()
        .take_while(|&(rank, _)| rank == best)
        .take(2)
        .map(|(_, path)| path)
        .collect()
}

fn next_window(
    path: &str,
    text: &str,
    term: &str,
    windows: &[SourceWindow],
    remaining: usize,
) -> Option<SourceWindow> {
    let lines: Vec<_> = text.split_inclusive('\n').collect();
    let used: Vec<_> = windows
        .iter()
        .filter(|window| window.path == path)
        .map(|window| {
            let start = window.start - 1;
            start..start + window.text.split_terminator('\n').count()
        })
        .collect();
    let cap = WINDOW_BYTES.min(remaining);
    // Later occurrences can show how a value is used beyond its first declaration.
    for (anchor, line) in lines.iter().enumerate().rev() {
        if line.len() > cap
            || !line.contains(term)
            || used.iter().any(|range| range.contains(&anchor))
        {
            continue;
        }
        let mut start = anchor.saturating_sub(WINDOW_RADIUS);
        let mut end = (anchor + WINDOW_RADIUS + 1).min(lines.len());
        for range in &used {
            if range.end <= anchor {
                start = start.max(range.end);
            } else {
                end = end.min(range.start);
            }
        }
        let mut size: usize = lines[start..end].iter().map(|line| line.len()).sum();
        while size > cap {
            if anchor - start > end - anchor - 1 {
                size -= lines[start].len();
                start += 1;
            } else {
                end -= 1;
                size -= lines[end].len();
            }
        }
        return Some(SourceWindow {
            path: path.to_owned(),
            start: start + 1,
            text: lines[start..end].concat(),
        });
    }
    None
}
