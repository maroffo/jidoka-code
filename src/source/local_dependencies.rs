//! Resolve a small set of local static imports used by edited JavaScript and TypeScript lines.

use super::{GitHub, Transport, Tree, WINDOW_BLOB_BYTES, parent, read_source, safe_path};
use crate::contracts::SourceFile;
use std::{cmp::Reverse, collections::HashSet};

pub(super) const TEXT_BYTES: usize = 8_000;
const MAX_FILES: usize = 4;
const IMPORTER_FETCHES: usize = 8;
const MODULE_PROBES: usize = 8;
const SCRIPT_EXTENSIONS: &[&str] = &["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"];

fn identifiers(text: &str) -> impl Iterator<Item = &str> {
    text.split(|ch: char| !ch.is_ascii_alphanumeric() && !matches!(ch, '_' | '$'))
        .filter(|word| !word.is_empty())
}

fn import_statement(statement: &str) -> Option<(&str, &str)> {
    let (bindings, tail) = statement.split_once(" from ")?;
    let mut tail = tail.trim_start().chars();
    let quote = tail.next().filter(|ch| matches!(ch, '\'' | '"'))?;
    let (target, _) = tail.as_str().split_once(quote)?;
    ["./", "../", "@/", "~/"]
        .into_iter()
        .any(|prefix| target.starts_with(prefix))
        .then_some((bindings, target))
}

fn import_score(bindings: &str, target: &str, edited: &str, names: &HashSet<&str>) -> usize {
    let named = bindings
        .split_once('{')
        .and_then(|(_, rest)| rest.split_once('}'))
        .map_or("", |(named, _)| named);
    let matches = named
        .split(',')
        .filter_map(|binding| identifiers(binding).last())
        .filter(|name| names.contains(name))
        .count();
    let other = bindings
        .split_once('{')
        .map_or(bindings, |(before, _)| before);
    let uses_binding = identifiers(other)
        .filter(|name| !matches!(*name, "as" | "type"))
        .any(|name| names.contains(name));
    let imports_path = ['\'', '"']
        .into_iter()
        .any(|quote| edited.contains(&format!("{quote}{target}{quote}")));
    matches.min(4) * 3 + usize::from(uses_binding) * 2 + usize::from(imports_path)
}

fn referenced_imports(text: &str, edited: &str) -> Vec<(usize, String)> {
    let names: HashSet<_> = identifiers(edited).collect();
    let mut lines = text.lines().peekable();
    let mut candidates = Vec::new();
    while let Some(line) = lines.next() {
        let Some(start) = line
            .trim_start()
            .strip_prefix("import")
            .filter(|rest| rest.starts_with(char::is_whitespace))
        else {
            continue;
        };
        let start = start.trim_start();
        if start.starts_with(['\'', '"', '(']) {
            continue;
        }
        let mut statement = start.to_owned();
        // Collect conventional multiline import lists without parsing general script syntax.
        for _ in 0..8 {
            if statement.len() > 1_024 {
                break;
            }
            if let Some((bindings, target)) = import_statement(&statement) {
                let score = import_score(bindings, target, edited, &names);
                if score > 0 {
                    candidates.push((score, target.to_owned()));
                }
                break;
            }
            if statement.contains(" from ") || statement.ends_with(';') {
                break;
            }
            let Some(next) = lines.next_if(|next| !next.trim_start().starts_with("import")) else {
                break;
            };
            statement.push(' ');
            statement.push_str(next.trim());
        }
    }
    candidates
}

fn join_relative(directory: &str, target: &str) -> Option<String> {
    let mut parts: Vec<_> = directory
        .split('/')
        .filter(|part| !part.is_empty())
        .collect();
    for part in target.split('/') {
        match part {
            "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    let path = parts.join("/");
    safe_path(&path).then_some(path)
}

fn package_root<'a, T: Transport>(
    hub: &mut GitHub<T>,
    head: &mut Tree<'_>,
    mut directory: &'a str,
) -> &'a str {
    while !directory.is_empty() {
        if head.directory(hub, directory).is_ok_and(|entries| {
            ["package.json", "tsconfig.json", "jsconfig.json"]
                .iter()
                .any(|name| entries.get(*name).is_some_and(|entry| entry.is_regular()))
        }) {
            return directory;
        }
        directory = parent(directory).0;
    }
    ""
}

fn resolve<T: Transport>(
    hub: &mut GitHub<T>,
    head: &mut Tree<'_>,
    importer: &str,
    target: &str,
) -> Option<String> {
    let directory = parent(importer).0;
    let mut bases = Vec::new();
    if let Some(alias) = target
        .strip_prefix("@/")
        .or_else(|| target.strip_prefix("~/"))
    {
        if !safe_path(alias) {
            return None;
        }
        let root = package_root(hub, head, directory);
        bases.extend([
            join_relative(root, &format!("src/{alias}"))?,
            join_relative(root, alias)?,
        ]);
    } else {
        bases.push(join_relative(directory, target)?);
    }
    for base in bases {
        let direct = std::iter::once(base.clone());
        let with_extension = SCRIPT_EXTENSIONS.iter().map(|ext| format!("{base}.{ext}"));
        let with_index = SCRIPT_EXTENSIONS
            .iter()
            .map(|ext| format!("{base}/index.{ext}"));
        for candidate in direct.chain(with_extension).chain(with_index) {
            if safe_path(&candidate)
                && head
                    .entry(hub, &candidate)
                    .ok()
                    .flatten()
                    .is_some_and(|entry| entry.is_regular())
            {
                return Some(candidate);
            }
        }
    }
    None
}

pub(super) fn collect<T: Transport>(
    hub: &mut GitHub<T>,
    base: &mut Tree<'_>,
    head: &mut Tree<'_>,
    changed: &[SourceFile],
    excluded: &HashSet<&str>,
    remaining: &mut usize,
) -> Vec<SourceFile> {
    if *remaining == 0 {
        return Vec::new();
    }
    let mut requests = Vec::new();
    let mut head_fetches = 0;
    for file in changed {
        if !file
            .path
            .rsplit_once('.')
            .is_some_and(|(_, ext)| SCRIPT_EXTENSIONS.contains(&ext))
        {
            continue;
        }
        let Some(rows) = crate::hunks::lines(&file.patch) else {
            continue;
        };
        let edited = rows
            .into_iter()
            .filter_map(|(base, head, text)| (base.is_none() && head.is_some()).then_some(text))
            .collect::<Vec<_>>()
            .join("\n");
        if identifiers(&edited).next().is_none() {
            continue;
        }
        let downloaded;
        let text = if file.after.is_empty() {
            if head_fetches == IMPORTER_FETCHES {
                continue;
            }
            head_fetches += 1;
            let Ok(Some(text)) = head.text(hub, &file.path, WINDOW_BLOB_BYTES) else {
                continue;
            };
            downloaded = text;
            downloaded.as_str()
        } else {
            &file.after
        };
        requests.extend(
            referenced_imports(text, &edited)
                .into_iter()
                .map(|(score, target)| (score, file.path.as_str(), target)),
        );
    }
    requests.sort_by_key(|request| Reverse(request.0));
    let mut seen_imports = HashSet::new();
    let mut seen_paths = HashSet::new();
    let mut files = Vec::new();
    for (_, importer, target) in requests
        .into_iter()
        .filter(|(_, from, target)| seen_imports.insert((*from, target.clone())))
        .take(MODULE_PROBES)
    {
        if *remaining == 0 || files.len() == MAX_FILES {
            break;
        }
        let Some(path) = resolve(hub, head, importer, &target) else {
            continue;
        };
        if excluded.contains(path.as_str()) || !seen_paths.insert(path.clone()) {
            continue;
        }
        let after = read_source(hub, head, &path, remaining);
        if !after.is_empty() {
            files.push(SourceFile {
                path,
                patch: String::new(),
                before: String::new(),
                after,
            });
        }
    }
    for file in &mut files {
        file.before = read_source(hub, base, &file.path, remaining);
    }
    files
}
