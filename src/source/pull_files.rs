use super::*;

const FILES_PER_PAGE: usize = 30;
const NO_NEWLINE: &str = "\\ No newline at end of file";

pub(super) fn candidates<'a, T: Transport>(
    hub: &mut GitHub<T>,
    pull_route: &str,
    total_files: u64,
    changes: &'a [Change],
) -> HashMap<&'a str, Change> {
    let mut needed = HashMap::new();
    for change in changes.iter().take(CHANGED_FILES) {
        let usable = safe_path(&change.filename)
            && change.previous().is_some()
            && change.text_status()
            && change.sha.as_deref().is_some_and(|id| sha(id).is_ok())
            && change.complete_patch().is_none();
        // Repeated comparison paths cannot identify an unambiguous file.
        needed
            .entry(change.filename.as_str())
            .and_modify(|entry| *entry = None)
            .or_insert(usable.then_some(change));
    }
    needed.retain(|_, change| change.is_some());

    let mut patches = HashMap::new();
    let mut seen = HashSet::new();
    let pages = total_files.min(CHANGED_FILES as u64) as usize;
    for page in 1..=pages.div_ceil(FILES_PER_PAGE) {
        if seen.len() == needed.len() {
            break;
        }
        let route = format!("{pull_route}/files?per_page={FILES_PER_PAGE}&page={page}");
        let Ok(batch) = hub.get::<Vec<Change>>(&route, RESPONSE, false) else {
            break;
        };
        let count = batch.len();
        if count > FILES_PER_PAGE {
            break;
        }
        for file in batch {
            let Some((&path, Some(original))) = needed.get_key_value(file.filename.as_str()) else {
                continue;
            };
            if !seen.insert(path) {
                patches.remove(path);
            } else if file.status == original.status
                && file.previous_filename == original.previous_filename
                && file.sha == original.sha
                && consistent_counts(original, &file)
                && file.complete_patch().is_some()
            {
                patches.insert(path, file);
            }
        }
        if count < FILES_PER_PAGE {
            break;
        }
    }
    patches
}

fn consistent_counts(original: &Change, file: &Change) -> bool {
    let counts = [
        (original.additions, file.additions),
        (original.deletions, file.deletions),
        (original.changes, file.changes),
    ];
    // GitHub can zero the comparison counts when it omits the patch.
    !counts
        .iter()
        .any(|(expected, _)| expected.is_some_and(|count| count > 0))
        || counts
            .into_iter()
            .all(|(expected, actual)| expected.is_none() || expected == actual)
}

pub(super) fn verify<'a, T: Transport>(
    hub: &mut GitHub<T>,
    before: &mut Tree<'_>,
    after: &mut Tree<'_>,
    change: &'a Change,
    previous: &str,
) -> Option<&'a str> {
    let patch = change.patch.as_deref()?;
    // Matching file metadata alone cannot guard against a base change that was
    // reverted between the initial and final PR reads.
    let (base_repo, head_repo) = (before.repo, after.repo);
    let (old, new) = change.pinned_entries(hub, before, after, previous);
    if Some(new.or(old)?.sha.as_str()) != change.sha.as_deref() {
        return None;
    }
    let mut text = |repo, entry: Option<&Entry>, absent| {
        if absent {
            return Some(String::new());
        }
        let entry = entry?;
        hub.blob(repo, &entry.sha, entry.file_size()?)
            .ok()
            .flatten()
    };
    let base = text(base_repo, old, change.status == "added")?;
    let head = text(head_repo, new, change.status == "removed")?;
    if base == head {
        return None;
    }
    verify_lines(patch, &base, &head)?;
    Some(patch)
}

fn hunk_start(range: &str) -> Option<usize> {
    let (line, count) = range.split_once(',').unwrap_or((range, "1"));
    line.parse::<usize>()
        .ok()?
        .checked_sub(usize::from(count.parse::<usize>().ok()? != 0))
}

fn matches_line(line: &str, text: &str, newline: bool) -> bool {
    if newline {
        line.strip_suffix('\n') == Some(text)
    } else {
        line == text
    }
}

// The patch already passed the hunk parser. Check exact line bytes and every
// unchanged gap against the two blobs, including empty ranges and EOF markers.
fn verify_lines(patch: &str, base: &str, head: &str) -> Option<()> {
    let base: Vec<_> = base.split_inclusive('\n').collect();
    let head: Vec<_> = head.split_inclusive('\n').collect();
    let (mut old, mut new) = (0, 0);
    let mut rows = patch.split_terminator('\n').peekable();
    while let Some(row) = rows.next() {
        if let Some(header) = row.strip_prefix("@@ -") {
            let (from, to) = header.split_once(" +")?;
            let from = hunk_start(from)?;
            let to = hunk_start(to.split_once(" @@")?.0)?;
            if base.get(old..from)? != head.get(new..to)? {
                return None;
            }
            (old, new) = (from, to);
            continue;
        }
        let (marker, text) = row.split_at_checked(1)?;
        let newline = rows
            .next_if(|line| line.strip_suffix('\r').unwrap_or(line) == NO_NEWLINE)
            .is_none();
        if marker != "+" {
            if !matches_line(base.get(old)?, text, newline) {
                return None;
            }
            old += 1;
        }
        if marker != "-" {
            if !matches_line(head.get(new)?, text, newline) {
                return None;
            }
            new += 1;
        }
    }
    (base[old..] == head[new..]).then_some(())
}
