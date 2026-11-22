//! A per-review bare repository. Source, tools and diff all use the same two Git objects.
use super::*;
use crate::contracts::ContextRead;
use std::{
    io::{BufRead, BufReader},
    path::Path,
    process::{Command, Output, Stdio},
};
use tempfile::TempDir;

fn git(directory: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .current_dir(directory)
        .env_clear()
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .env("LC_ALL", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_ATTR_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.https.allow=always",
            "-c",
            "http.followRedirects=false",
            "-c",
            "http.lowSpeedLimit=1024",
            "-c",
            "http.lowSpeedTime=60",
            "-c",
            "gc.auto=0",
        ]);
    command
}

fn run(command: &mut Command, operation: &str) -> Result<Vec<u8>> {
    let output = command
        .output()
        .with_context(|| format!("Could not start Git to {operation}."))?;
    ensure!(output.status.success(), "Git could not {operation}.");
    Ok(output.stdout)
}

fn fetch(directory: &Path, repo: &str, commits: &[&str]) -> Result<()> {
    ensure!(valid_repo(repo), "Invalid GitHub repository.");
    for id in commits {
        sha(id)?;
    }
    let mut command = git(directory);
    if let Ok(token) = std::env::var("JIDOKA_GITHUB_TOKEN")
        && !token.is_empty()
    {
        // Never put credentials in argv, remote URLs, repository config or error output.
        let key = STANDARD.encode(format!("x-access-token:{token}"));
        command
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "http.https://github.com/.extraHeader")
            .env("GIT_CONFIG_VALUE_0", format!("Authorization: Basic {key}"));
    }
    run(
        command
            .args([
                "fetch",
                "--quiet",
                "--no-tags",
                "--no-recurse-submodules",
                "--depth=1",
                "--",
                &format!("https://github.com/{repo}.git"),
            ])
            .args(commits),
        "fetch the authorized pinned revision",
    )?;
    Ok(())
}

#[derive(Deserialize)]
struct ComparisonBase {
    total_commits: usize,
    base_commit: GitId,
    merge_base_commit: GitId,
}

fn commit_messages(hub: &mut GitHub<Http>, route: &str, total: usize) -> Vec<String> {
    let mut messages = Vec::new();
    for page in 1..=total
        .min(COMMITS_PER_PAGE * COMMIT_PAGES)
        .div_ceil(COMMITS_PER_PAGE)
    {
        let route = format!("{route}/commits?per_page={COMMITS_PER_PAGE}&page={page}");
        let Ok(batch) = hub.get::<Vec<ComparedCommit>>(&route, RESPONSE, false) else {
            break;
        };
        let count = batch.len();
        messages.extend(batch.into_iter().map(|item| item.commit.message));
        if count < COMMITS_PER_PAGE {
            break;
        }
    }
    messages
}

#[derive(Copy, Clone)]
enum ReviewTarget<'a> {
    Current(Option<&'a str>),
    AutomaticResume { base: &'a str, head: &'a str },
    Historical { base: &'a str, head: &'a str },
}

impl<'a> ReviewTarget<'a> {
    fn saved(self) -> Option<(&'a str, &'a str)> {
        match self {
            Self::Current(_) => None,
            Self::Historical { base, head } | Self::AutomaticResume { base, head } => {
                Some((base, head))
            }
        }
    }

    fn check_head(self, current: &str) -> Result<()> {
        let expected = match self {
            Self::Current(expected) => expected,
            Self::AutomaticResume { head, .. } => Some(head),
            Self::Historical { .. } => None,
        };
        ensure!(
            expected.is_none_or(|head| head.eq_ignore_ascii_case(current)),
            HeadChanged("The pull request changed before review.")
        );
        Ok(())
    }
}

#[derive(Deserialize)]
struct RepositoryPull {
    #[serde(flatten)]
    refs: DiffPull,
    title: String,
    body: Option<String>,
}

impl RepositoryPull {
    fn authorized(self, repo: &str, number: u64, allowed: &HashSet<String>) -> Result<Pull> {
        let refs = self.refs;
        let mut pull = Pull {
            number: refs.number, title: self.title, body: self.body, base: refs.base,
            head: Revision { sha: refs.head.sha, repo: refs.head.repo.context(
                "Cannot verify the pull request's source repository. Its fork may have been deleted.")? },
            changed_files: refs.changed_files,
        };
        pull.validate(repo, number, allowed)?;
        Ok(pull)
    }
}

fn check_collection(target: ReviewTarget<'_>, first: &Pull, last: &Pull) -> Result<()> {
    if matches!(target, ReviewTarget::Historical { .. }) {
        // The saved commits stay fixed across ordinary pushes and base updates.
        ensure!(
            first.head.repo == last.head.repo && first.base.repo == last.base.repo,
            "The source repository changed during collection."
        );
    } else {
        ensure!(
            first.head.sha == last.head.sha,
            HeadChanged("The pull request head changed during collection.")
        );
        ensure!(
            first.same_revisions(last),
            "The pull request base or metadata changed during collection."
        );
    }
    Ok(())
}

/// Collect all changed paths and retain a read-only handle to the pinned source for the review.
pub fn collect_repository(
    url: &str,
    allowed: &HashSet<String>,
    expected_head: Option<&str>,
    previous_head: Option<&str>,
    prior_paths: &[String],
) -> Result<(Snapshot, ReviewRepository)> {
    collect(
        url,
        allowed,
        ReviewTarget::Current(expected_head),
        previous_head,
        prior_paths,
    )
}

/// Resume an automatic run only while its recorded head is still the PR head.
pub fn resume_automatic_repository(
    url: &str,
    allowed: &HashSet<String>,
    base: &str,
    head: &str,
) -> Result<(Snapshot, ReviewRepository)> {
    collect(
        url,
        allowed,
        ReviewTarget::AutomaticResume {
            base: sha(base)?,
            head: sha(head)?,
        },
        None,
        &[],
    )
}

/// Re-open the exact revisions saved with a review, including after a merge.
pub fn collect_repository_at(
    url: &str,
    allowed: &HashSet<String>,
    base: &str,
    head: &str,
) -> Result<(Snapshot, ReviewRepository)> {
    collect(
        url,
        allowed,
        ReviewTarget::Historical {
            base: sha(base)?,
            head: sha(head)?,
        },
        None,
        &[],
    )
}

fn collect(
    url: &str,
    allowed: &HashSet<String>,
    target: ReviewTarget<'_>,
    previous_head: Option<&str>,
    prior_paths: &[String],
) -> Result<(Snapshot, ReviewRepository)> {
    let (repo, number) = pull_url(url, allowed)?;
    let mut hub = github()?;
    let route = format!("{repo}/pulls/{number}");
    let metadata: RepositoryPull = hub.get(&route, PULL_BYTES, false)?;
    let pull = metadata.authorized(&repo, number, allowed)?;
    target.check_head(&pull.head.sha)?;

    // The first comparison page can contain megabytes of unrelated file JSON.
    // Later pages contain the same pinned commit metadata without the file list.
    let saved = target.saved();
    let saved_base = saved.map(|(base, _)| base);
    let head = saved.map_or(pull.head.sha.as_str(), |(_, head)| head);
    let head_repo = if matches!(target, ReviewTarget::Historical { .. }) {
        &repo
    } else {
        &pull.head.repo.full_name
    };
    let compare_base = match target {
        ReviewTarget::Historical { base, .. } => base,
        _ => &pull.base.sha,
    };
    let head_ref = if &repo == head_repo {
        head.to_owned()
    } else {
        let (owner, _) = head_repo.split_once('/').context("Invalid fork.")?;
        format!("{owner}:{head}")
    };
    let comparison: ComparisonBase = hub.get(
        &format!("{repo}/compare/{compare_base}...{head_ref}?per_page=1&page=2"),
        PULL_BYTES,
        false,
    )?;
    let base = sha(&comparison.merge_base_commit.sha)?;
    ensure!(
        comparison.base_commit.sha == compare_base && saved_base.is_none_or(|id| id == base),
        "GitHub returned an unexpected comparison base."
    );
    let messages = if head == pull.head.sha && comparison.total_commits > 1 {
        commit_messages(&mut hub, &route, comparison.total_commits)
    } else {
        Vec::new()
    };
    let pushed = pushed_paths(&mut hub, &pull.head, previous_head);
    let directory = tempfile::Builder::new().prefix("jidoka-git-").tempdir()?;
    run(
        git(directory.path()).args(["init", "--bare", "--template=", "--quiet"]),
        "initialize pinned source",
    )?;
    if &repo == head_repo {
        fetch(directory.path(), &repo, &[base, head])?;
    } else {
        fetch(directory.path(), &repo, &[base])?;
        fetch(directory.path(), head_repo, &[head])?;
    }
    let fork = (pull.head.repo.full_name != repo && pull.head.repo.private)
        .then(|| pull.head.repo.full_name.clone());
    let repository = ReviewRepository::open(directory, base, head, fork)?;
    let (mut files, diff, mut limits) = repository.changes()?;
    if !matches!(target, ReviewTarget::Historical { .. }) && diff.total_files != pull.changed_files
    {
        limits.push(format!(
            "The pinned Git diff lists {} changed files; GitHub reported {} for the pull request.",
            diff.total_files, pull.changed_files
        ));
    }
    let prior: HashSet<_> = prior_paths.iter().map(String::as_str).collect();
    files.sort_by_key(|file| {
        (
            !pushed.contains(&file.path),
            !prior.contains(file.path.as_str()),
        )
    });
    // Use a fresh HTTP deadline after fetching the Git objects.
    let final_metadata: RepositoryPull = github()?.get(&route, PULL_BYTES, true)?;
    let final_pull = final_metadata.authorized(&repo, number, allowed)?;
    check_collection(target, &pull, &final_pull)?;
    let mut intent = Vec::new();
    if head == pull.head.sha {
        intent.push(pull.title);
        intent.extend(pull.body.filter(|body| !body.is_empty()));
    }
    intent.extend(
        messages
            .into_iter()
            .filter(|message| !message.trim().is_empty()),
    );
    let message = run(
        repository.git().args(["show", "-s", "--format=%B", head]),
        "read the pinned commit message",
    )?;
    if let Ok(message) = String::from_utf8(message)
        && !message.trim().is_empty()
        && !intent
            .iter()
            .any(|item| item.trim_end() == message.trim_end())
    {
        intent.push(message.trim_end().to_owned());
    }

    let snapshot = Snapshot {
        url: format!("https://github.com/{repo}/pull/{number}"),
        repo,
        number,
        base: base.to_owned(),
        head: head.to_owned(),
        files,
        limits,
        intent,
        head_context: Vec::new(),
        diff: Some(diff),
    };
    Ok((snapshot, repository))
}

pub struct ReviewRepository {
    private_source_repo: Option<String>,
    directory: TempDir,
    base: String,
    head: String,
    // ls-tree lists gitlinks and symlinks too. Only regular files are readable.
    paths: BTreeMap<String, String>,
}

impl ReviewRepository {
    fn open(
        directory: TempDir,
        base: &str,
        head: &str,
        private_source_repo: Option<String>,
    ) -> Result<Self> {
        let data = run(
            git(directory.path()).args(["ls-tree", "-rz", "--full-tree", sha(head)?]),
            "list files in the pinned head",
        )?;
        let mut paths = BTreeMap::new();
        for entry in data.split(|c| *c == 0).filter(|v| !v.is_empty()) {
            let index = entry
                .iter()
                .position(|b| *b == b'\t')
                .context("Invalid Git tree.")?;
            let (meta, path) = entry.split_at(index);
            let Ok(path) = std::str::from_utf8(&path[1..]) else {
                continue;
            };
            if !safe_path(path) {
                continue;
            }
            let meta: Vec<_> = std::str::from_utf8(meta)?.split_whitespace().collect();
            if let ["100644" | "100755", "blob", id] = meta[..] {
                paths.insert(path.to_owned(), sha(id)?.to_owned());
            }
        }
        Ok(Self {
            private_source_repo,
            directory,
            base: sha(base)?.to_owned(),
            head: head.to_owned(),
            paths,
        })
    }

    /// The separate private fork whose approval must remain valid when resuming.
    pub fn private_source_repo(&self) -> Option<&str> {
        self.private_source_repo.as_deref()
    }

    fn git(&self) -> Command {
        git(self.directory.path())
    }

    fn initial_source(&self, id: &str, limit: usize) -> Result<String> {
        let size = run(
            self.git().args(["cat-file", "-s", id]),
            "measure pinned source",
        )?;
        if std::str::from_utf8(&size)?.trim().parse::<usize>()? > limit {
            return Ok(String::new());
        }
        let bytes = run(
            self.git().args(["cat-file", "blob", id]),
            "read pinned source",
        )?;
        Ok(String::from_utf8(bytes)
            .ok()
            .filter(|v| !v.contains('\0'))
            .unwrap_or_default())
    }

    fn changes(&self) -> Result<(Vec<SourceFile>, PinnedDiff, Vec<String>)> {
        let output = run(
            self.git().args([
                "diff-tree",
                "-r",
                "--no-commit-id",
                "--no-abbrev",
                "-M",
                "-z",
                &self.base,
                &self.head,
                "--",
            ]),
            "enumerate the pinned diff",
        )?;
        let mut fields = output.split(|byte| *byte == 0);
        let mut files = Vec::new();
        let mut diff = PinnedDiff {
            total_files: 0,
            files: Vec::new(),
            supporting_paths: Vec::new(),
        };
        let mut limits = Vec::new();
        // Git needs a blob on both sides for a per-file diff, including added/deleted files.
        let empty = run(
            self.git().args(["hash-object", "-w", "--stdin"]),
            "prepare an empty blob",
        )?;
        let empty = std::str::from_utf8(&empty)?.trim();
        while let Some(header) = fields.next().filter(|value| !value.is_empty()) {
            let meta: Vec<_> = std::str::from_utf8(header)?
                .trim_start_matches(':')
                .split(' ')
                .collect();
            let [old_mode, new_mode, old_id, new_id, kind] = meta[..] else {
                bail!("Invalid Git diff entry.")
            };
            let mut path = fields.next().context("Missing Git diff path.")?;
            let previous = if kind.starts_with('R') || kind.starts_with('C') {
                Some(std::mem::replace(
                    &mut path,
                    fields.next().context("Missing Git rename destination.")?,
                ))
            } else {
                None
            };
            diff.total_files += 1;
            let previous_path = previous.map(String::from_utf8_lossy);
            let path = String::from_utf8_lossy(path);
            if matches!(path, std::borrow::Cow::Owned(_))
                || !safe_path(&path)
                || previous_path
                    .as_ref()
                    .is_some_and(|p| matches!(p, std::borrow::Cow::Owned(_)) || !safe_path(p))
            {
                limits.push(format!(
                    "Changed path {:?} cannot be represented safely.",
                    path.escape_default().to_string()
                ));
                continue;
            }
            let path = path.into_owned();
            let status = match kind.as_bytes().first() {
                Some(b'A') => "added",
                Some(b'D') => "removed",
                Some(b'M') => "modified",
                Some(b'R') => "renamed",
                Some(b'C') => "copied",
                _ => "changed",
            };
            let mut record = DiffFile {
                path: path.clone(),
                status: status.to_owned(),
                previous_path: previous_path.map(|p| p.into_owned()),
                patch: None,
            };
            if ![old_mode, new_mode]
                .iter()
                .all(|m| matches!(*m, "000000" | "100644" | "100755"))
            {
                limits.push(format!("File {path} has a symlink, submodule or unsupported mode ({old_mode} to {new_mode})."));
            } else {
                let from = if old_mode == "000000" {
                    empty
                } else {
                    sha(old_id)?
                };
                let to = if new_mode == "000000" {
                    empty
                } else {
                    sha(new_id)?
                };
                let bytes = run(
                    self.git().args([
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--no-color",
                        "--unified=3",
                        from,
                        to,
                        "--",
                    ]),
                    "read pinned file changes",
                )?;
                if from == to {
                    // Preserve path-only renames, empty file changes and executable-bit changes in the manifest.
                    limits.push(format!("File {path} has a metadata-only change ({status}, {old_mode} to {new_mode})."));
                } else if let Ok(text) = std::str::from_utf8(&bytes)
                    && let Some((_, hunks)) = text.split_once("\n@@ ")
                {
                    let patch = format!("@@ {hunks}");
                    ensure!(
                        crate::hunks::lines(&patch).is_some(),
                        "Git returned an incomplete diff for {path}."
                    );
                    record.patch = Some(patch.clone());
                    files.push(SourceFile {
                        path: path.clone(),
                        patch,
                        before: self.initial_source(from, BLOB_BYTES)?,
                        after: self.initial_source(
                            to,
                            crate::scanner::source_bytes(&path).unwrap_or(BLOB_BYTES),
                        )?,
                    });
                } else {
                    limits.push(format!("File {path} is binary or has non-UTF-8 changes."));
                }
            }
            diff.files.push(record);
        }
        Ok((files, diff, limits))
    }

    /// Read literal evidence in the pinned regular files. A wildcard path searches all files.
    /// Use "*:13" to start at the thirteenth matching path.
    /// A blank term starts at line 1. A term such as #L81 requests the next page at line 81.
    pub fn read_context(
        &self,
        snapshot: &Snapshot,
        requests: &[ContextRead],
    ) -> Result<Vec<SourceWindow>> {
        ensure!(
            snapshot.head == self.head && snapshot.base == self.base,
            "Source revision mismatch."
        );
        let mut windows = Vec::new();
        let mut remaining = TOOL_PAGE_BYTES;
        for request in requests {
            if remaining == 0 {
                break;
            }
            let term = &request.term;
            ensure!(
                term.len() <= 256 && !term.contains(['\0', '\n', '\r']),
                "Invalid source query."
            );
            let mut paths = Vec::new();
            let search = if request.path == "*" {
                Some(0)
            } else if let Some(page) = request.path.strip_prefix("*:") {
                Some(
                    page.parse::<usize>()
                        .ok()
                        .and_then(|start| start.checked_sub(1))
                        .context("Invalid repository search offset.")?,
                )
            } else {
                None
            };
            if search.is_some() {
                ensure!(!term.is_empty(), "Repository search needs a literal term.");
                let output: Output = self
                    .git()
                    .args([
                        "grep",
                        "--no-textconv",
                        "-I",
                        "-F",
                        "-l",
                        "-z",
                        "-e",
                        term,
                        &self.head,
                        "--",
                    ])
                    .output()?;
                if output.status.code() == Some(1) {
                    continue;
                }
                ensure!(
                    output.status.success(),
                    "Could not search the pinned revision."
                );
                let prefix = format!("{}:", self.head);
                for name in output.stdout.split(|byte| *byte == 0) {
                    if let Ok(key) = std::str::from_utf8(name)
                        && let Some(name) = key.strip_prefix(&prefix)
                        && self.paths.contains_key(name)
                    {
                        paths.push(name.to_owned())
                    }
                }
            } else {
                ensure!(safe_path(&request.path), "Invalid source path.");
                if self.paths.contains_key(&request.path) {
                    paths.push(request.path.clone());
                } else if !request.path.contains('/') {
                    paths.extend(
                        self.paths
                            .keys()
                            .filter(|path| {
                                module_basename(path).eq_ignore_ascii_case(&request.path)
                            })
                            .cloned(),
                    );
                }
            }
            let start = if search.is_some() {
                None
            } else if term.is_empty() {
                Some(1)
            } else {
                term.strip_prefix("#L")
                    .and_then(|n| n.parse::<usize>().ok())
                    .filter(|n| *n > 0)
            };
            for path in paths.into_iter().skip(search.unwrap_or(0)).take(12) {
                if remaining == 0 {
                    break;
                }
                let id = &self.paths[&path];
                let mut child = self
                    .git()
                    .args(["cat-file", "blob", id])
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .context("Could not open pinned source.")?;
                let stdout = child
                    .stdout
                    .take()
                    .context("Missing pinned source stream.")?;
                let result = file_windows(
                    BufReader::new(stdout),
                    &path,
                    term,
                    start,
                    &mut remaining,
                    &mut windows,
                );
                // A page usually ends before the blob. Stop the writer once its pipe closes.
                if !matches!(result, Ok(true)) {
                    let _ = child.kill();
                }
                let status = child.wait()?;
                ensure!(
                    !result? || status.success(),
                    "Could not finish reading {path}."
                );
            }
        }
        Ok(windows)
    }
}

// A tool page is already paginated by line. This bounds memory even for a
// minified file containing a single very long line. The patch budget is separate.
const TOOL_PAGE_BYTES: usize = 1024 * 1024;

fn file_windows(
    mut reader: impl BufRead,
    path: &str,
    term: &str,
    start: Option<usize>,
    remaining: &mut usize,
    windows: &mut Vec<SourceWindow>,
) -> Result<bool> {
    let mut buffer = Vec::new();
    let mut number: usize = 0;
    let mut through = 0;
    let mut count = 0;
    loop {
        if *remaining == 0 || (through != 0 && number == through && (start.is_some() || count == 3))
        {
            return Ok(false);
        }
        number += 1;
        // Skip directly to the requested line without allocating the intervening source.
        if start.is_some_and(|start| number < start) {
            if reader.skip_until(b'\n')? == 0 {
                return Ok(true);
            }
            continue;
        }
        buffer.clear();
        let bytes = (&mut reader)
            .take((TOOL_PAGE_BYTES + 1) as u64)
            .read_until(b'\n', &mut buffer)?;
        if bytes == 0 {
            return Ok(true);
        }
        if bytes > TOOL_PAGE_BYTES {
            if start.is_some() {
                bail!("Line {number} of {path} exceeds a source tool page.")
            }
            if !buffer.ends_with(b"\n") {
                reader.skip_until(b'\n')?;
            }
            through = 0;
            continue;
        }
        let Ok(line) = std::str::from_utf8(&buffer) else {
            return Ok(false);
        };
        if line.contains('\0') {
            return Ok(false);
        }
        if through < number {
            if let Some(start) = start {
                through = start.saturating_add(79)
            } else if line.contains(term) {
                through = number.saturating_add(WINDOW_RADIUS);
            } else {
                continue;
            }
            if bytes > *remaining {
                return Ok(false);
            }
            windows.push(SourceWindow {
                path: path.to_owned(),
                start: number,
                text: String::new(),
            });
            count += 1;
        }
        if bytes > *remaining {
            return Ok(false);
        }
        windows
            .last_mut()
            .expect("an active source window")
            .text
            .push_str(line);
        *remaining -= bytes;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::symlink};

    fn commit(directory: &Path) -> String {
        run(git(directory).args(["add", "--all"]), "stage fixture").unwrap();
        run(
            git(directory).args([
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.com",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            ]),
            "commit fixture",
        )
        .unwrap();
        let bytes = run(
            git(directory).args(["rev-parse", "HEAD"]),
            "read fixture commit",
        )
        .unwrap();
        String::from_utf8(bytes).unwrap().trim().to_owned()
    }

    fn pr(head: &str, base: &str, origin: serde_json::Value) -> RepositoryPull {
        serde_json::from_value(serde_json::json!({
            "number": 1, "title": "Fix", "body": null, "changed_files": 2,
            "base": {"sha": base, "repo":{"full_name":"review/project","private":true}},
            "head": {"sha": head, "repo": origin}
        }))
        .unwrap()
    }

    #[test]
    fn automatic_checkpoints_require_the_current_head_and_historical_replays_keep_their_sha() {
        let saved = "a".repeat(40);
        let pushed = "b".repeat(40);
        let base = "c".repeat(40);
        let target = ReviewTarget::AutomaticResume {
            base: &base,
            head: &saved,
        };
        assert!(target.check_head(&saved).is_ok());
        assert!(target.check_head(&pushed).unwrap_err().is::<HeadChanged>());
        let replay = ReviewTarget::Historical {
            base: &base,
            head: &saved,
        };
        assert!(replay.check_head(&pushed).is_ok());
        assert_eq!(replay.saved(), Some((base.as_str(), saved.as_str())));

        let repo = "review/project";
        let allowed = HashSet::from([repo.to_owned()]);
        let origin = serde_json::json!({"full_name":repo, "private":true});
        let authorized = |head: &str, base: &str| {
            pr(head, base, origin.clone())
                .authorized(repo, 1, &allowed)
                .unwrap()
        };
        let before = authorized(&saved, &base);
        let after = authorized(&pushed, &base);
        assert!(
            check_collection(target, &before, &after)
                .unwrap_err()
                .is::<HeadChanged>()
        );
        assert!(check_collection(replay, &before, &after).is_ok());
        let new_base = authorized(&saved, &pushed);
        assert!(
            !check_collection(target, &before, &new_base)
                .unwrap_err()
                .is::<HeadChanged>()
        );
    }

    #[test]
    fn source_fetch_requires_verifiable_and_approved_fork_metadata() {
        let repo = "review/project";
        let allowed = HashSet::from([repo.to_owned()]);
        let denied = serde_json::json!({"full_name":"private/fork", "private":true});
        let head = "a".repeat(40);
        let base = "b".repeat(40);
        for origin in [denied, serde_json::Value::Null] {
            let meta = pr(&head, &base, origin);
            assert!(meta.authorized(repo, 1, &allowed).is_err());
        }
        let public = serde_json::json!({"full_name":"public/fork", "private":false});
        assert!(
            pr(&head, &base, public)
                .authorized(repo, 1, &allowed)
                .is_ok()
        );
    }

    #[test]
    fn paginates_large_blobs_without_returning_partial_lines_as_evidence() {
        let bytes = format!("{}\nselect checked;\n", "x".repeat(TOOL_PAGE_BYTES + 16));
        let mut windows = Vec::new();
        let mut remaining = TOOL_PAGE_BYTES;
        file_windows(
            bytes.as_bytes(),
            "query.sql",
            "select",
            None,
            &mut remaining,
            &mut windows,
        )
        .unwrap();
        assert_eq!(windows[0].start, 2);
        assert_eq!(windows[0].text, "select checked;\n");
        assert!(
            file_windows(
                bytes.as_bytes(),
                "query.sql",
                "",
                Some(1),
                &mut remaining,
                &mut windows
            )
            .is_err()
        );
        file_windows(
            bytes.as_bytes(),
            "query.sql",
            "",
            Some(2),
            &mut remaining,
            &mut windows,
        )
        .unwrap();
        assert_eq!(windows[1].text, "select checked;\n");
    }

    #[test]
    fn reviews_large_patches_and_uses_pinned_files_for_reads_and_search() {
        let temp = tempfile::tempdir().unwrap();
        let work = temp.path();
        run(
            git(work).args(["init", "--template=", "--quiet"]),
            "create fixture",
        )
        .unwrap();
        fs::write(
            work.join("helper.sql"),
            (1..=100)
                .map(|line| format!("-- line {line}\n"))
                .collect::<String>()
                + "select claim_once();\n",
        )
        .unwrap();
        fs::write(work.join("old name.txt"), "old content\n").unwrap();
        let base = commit(work);
        fs::rename(work.join("old name.txt"), work.join("new name.txt")).unwrap();
        fs::write(work.join("large.py"), "a changed line\n".repeat(10_000)).unwrap();
        fs::write(work.join("binary.bin"), [0, 1, 2]).unwrap();
        symlink("helper.sql", work.join("unsafe.sql")).unwrap();
        let head = commit(work);
        let repo = ReviewRepository::open(temp, &base, &head, Some("fork/project".into())).unwrap();
        assert_eq!(repo.private_source_repo(), Some("fork/project"));
        let (files, diff, limits) = repo.changes().unwrap();
        assert_eq!(diff.total_files, 4);
        assert_eq!(diff.files.len(), 4);
        assert!(limits.iter().any(|reason| reason.contains("binary.bin")));
        assert!(limits.iter().any(|reason| reason.contains("unsafe.sql")));
        let rename = diff
            .files
            .iter()
            .find(|f| f.path == "new name.txt")
            .unwrap();
        assert_eq!(rename.previous_path.as_deref(), Some("old name.txt"));
        assert_eq!(files.len(), 1);
        assert!(files[0].patch.len() > 96_000);
        assert!(files[0].after.len() > 96_000);
        assert_eq!(crate::hunks::lines(&files[0].patch).unwrap().len(), 10_000);
        let snapshot = Snapshot {
            base,
            head,
            repo: "test/fixture".into(),
            url: String::new(),
            number: 1,
            intent: Vec::new(),
            files,
            limits,
            diff: Some(diff),
            head_context: Vec::new(),
        };
        fs::write(
            repo.directory.path().join("helper.sql"),
            "changed after commit",
        )
        .unwrap();
        let query = |path: &str, term: &str| ContextRead {
            path: path.into(),
            term: term.into(),
        };
        let result = repo
            .read_context(&snapshot, &[query("*", "claim_once")])
            .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, "helper.sql");
        assert!(result[0].text.contains("claim_once"));
        let result = repo
            .read_context(
                &snapshot,
                &[query("helper.sql", "#L81"), query("unsafe.sql", "")],
            )
            .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].start, 81);
        assert!(result[0].text.starts_with("-- line 81\n"));
    }
}
