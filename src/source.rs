//! Collect pinned repository source without checking out or executing pull request code.

mod callers;
mod local_dependencies;
mod pull_files;
mod reads;
mod repository;

pub use reads::read_context;
pub use repository::{
    ReviewRepository, collect_repository, collect_repository_at, resume_automatic_repository,
};

#[derive(Debug)]
pub struct HeadChanged(pub(crate) &'static str);

impl std::fmt::Display for HeadChanged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for HeadChanged {}

use crate::contracts::{
    DiffFile, GitHubRateLimit, PinnedDiff, SNAPSHOT_TEXT_BYTES, Snapshot, SourceFile, SourceWindow,
};
use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use icu_properties::{
    CodePointMapData,
    props::{GeneralCategory, GeneralCategoryGroup},
};
use reqwest::{
    StatusCode,
    blocking::Client,
    header::{AUTHORIZATION, HeaderMap, HeaderValue},
    redirect::Policy,
};
use serde::{Deserialize, de::DeserializeOwned};
use sha1::{Digest, Sha1};
use std::{
    cmp::Reverse,
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    io::Read,
    time::{Duration, Instant},
};

const REQUESTS: usize = 48;
const DOWNLOAD: usize = 6_000_000;
const RESPONSE: usize = 2_000_000;
const PULL_BYTES: usize = 128_000;
const DEADLINE: Duration = Duration::from_secs(45);
const REQUEST_TIME: Duration = Duration::from_secs(5);
const INVENTORY_TIME: Duration = Duration::from_secs(15);
const COMMITS_PER_PAGE: usize = 20;
const COMMIT_PAGES: usize = 3;
// GitHub's pinned comparison lists at most 300 changed files.
const CHANGED_FILES: usize = 300;
const CONTEXT_FILES: usize = 8;
const CONTEXT_PROBES: usize = 12;
const WIDER_PROBES: usize = 3;
const INVENTORY_BYTES: usize = 12_000_000;
const CONTEXT_TEXT_BYTES: usize = 16_000;
const INTENT_BYTES: usize = 8_000;
const BLOB_BYTES: usize = 24_000;
const WINDOW_BLOB_BYTES: usize = 256 * 1024;
const HEAD_CONTEXT_BYTES: usize = 12_000;
const HEAD_WINDOWS: usize = 32;
const WINDOWS_PER_FILE: usize = 3;
const WINDOW_RADIUS: usize = 8;
const WINDOW_BYTES: usize = 2_000;

pub(crate) fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else {
        return false;
    };
    (1..=39).contains(&owner.len())
        && owner.as_bytes()[0].is_ascii_alphanumeric()
        && owner
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        && (1..=100).contains(&name.len())
        && !matches!(name, "." | "..")
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
}

fn pull_url(url: &str, allowed: &HashSet<String>) -> Result<(String, u64)> {
    fn parse(url: &str) -> Option<(String, u64)> {
        if url.len() > 2_048 || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return None;
        }
        let (scheme, rest) = url.split_once("://")?;
        let (host, path) = rest.split_once('/')?;
        if !scheme.eq_ignore_ascii_case("https") || !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        // Inspect the raw path so dot segments and URL escapes cannot be normalized away.
        let path = path.split(['#', '?']).next()?;
        let path = path.strip_suffix('/').unwrap_or(path);
        let (repo, tail) = path.rsplit_once('/')?;
        let (repo, pull) = repo.rsplit_once('/')?;
        if !valid_repo(repo)
            || !pull.eq_ignore_ascii_case("pull")
            || tail.starts_with('0')
            || !(1..=10).contains(&tail.len())
            || !tail.bytes().all(|c| c.is_ascii_digit())
        {
            return None;
        }
        Some((repo.to_ascii_lowercase(), tail.parse().ok()?))
    }
    let (repo, number) = parse(url).context("Enter an HTTPS URL for a GitHub pull request.")?;
    ensure!(
        allowed.iter().any(|name| name.eq_ignore_ascii_case(&repo)),
        "This repository is not on the allowlist."
    );
    Ok((repo, number))
}

pub(crate) fn printable(text: &str) -> bool {
    // Python str.isprintable excludes Unicode Other and Separator, except ASCII space.
    let categories = CodePointMapData::<GeneralCategory>::new();
    let excluded = GeneralCategoryGroup::Other.union(GeneralCategoryGroup::Separator);
    text.chars()
        .all(|ch| ch == ' ' || !excluded.contains(categories.get(ch)))
}

pub(crate) fn safe_path(path: &str) -> bool {
    path.len() <= 240
        && !path.contains('\\')
        && printable(path)
        && path.split('/').count() <= 16
        && path
            .split('/')
            .all(|part| !matches!(part, "" | "." | "..") && !part.eq_ignore_ascii_case(".git"))
}

pub(crate) fn safe_previous_path<'a>(path: &str, previous: Option<&'a str>) -> Option<&'a str> {
    previous.filter(|previous| *previous != path && safe_path(previous))
}

fn sha(sha: &str) -> Result<&str> {
    ensure!(
        sha.len() == 40
            && sha
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
        "Invalid Git object ID."
    );
    Ok(sha)
}

trait Transport {
    fn open(&mut self, route: &str, timeout: Duration) -> Result<Box<dyn Read>>;
}

struct Http(Client);

fn validate_status(status: StatusCode, remaining: Option<&HeaderValue>) -> Result<()> {
    if status == StatusCode::TOO_MANY_REQUESTS
        || (status == StatusCode::FORBIDDEN
            && remaining.is_some_and(|value| value.as_bytes() == b"0"))
    {
        return Err(GitHubRateLimit.into());
    }
    ensure!(
        status.is_success(),
        "GitHub failed to return the requested data."
    );
    Ok(())
}

impl Transport for Http {
    fn open(&mut self, route: &str, timeout: Duration) -> Result<Box<dyn Read>> {
        let response = self
            .0
            .get(format!("https://api.github.com/repos/{route}"))
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .timeout(timeout)
            .send()
            .map_err(|_| anyhow!("GitHub request failed."))?;
        validate_status(
            response.status(),
            response.headers().get("x-ratelimit-remaining"),
        )?;
        Ok(Box::new(response))
    }
}

struct GitHub<T> {
    transport: T,
    deadline: Instant,
    requests: usize,
    remaining: usize,
    inventory_remaining: usize,
    rate_limited: bool,
    blobs: HashMap<String, (usize, Option<String>)>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Request {
    Regular,
    Inventory,
    Final,
}

impl<T: Transport> GitHub<T> {
    fn new(transport: T) -> Self {
        Self {
            transport,
            deadline: Instant::now() + DEADLINE,
            requests: REQUESTS,
            remaining: DOWNLOAD,
            inventory_remaining: INVENTORY_BYTES,
            rate_limited: false,
            blobs: HashMap::new(),
        }
    }

    fn get<R: DeserializeOwned>(
        &mut self,
        route: &str,
        cap: usize,
        final_check: bool,
    ) -> Result<R> {
        let request = if final_check {
            Request::Final
        } else {
            Request::Regular
        };
        self.request(route, cap, request)
    }

    fn request<R: DeserializeOwned>(
        &mut self,
        route: &str,
        cap: usize,
        request: Request,
    ) -> Result<R> {
        if self.rate_limited {
            return Err(GitHubRateLimit.into());
        }
        // Reserve one request, its bytes, and time for the last PR metadata check.
        let final_check = request == Request::Final;
        let reserve = usize::from(!final_check);
        let (available, max_time) = if request == Request::Inventory {
            (&mut self.inventory_remaining, INVENTORY_TIME)
        } else {
            (&mut self.remaining, REQUEST_TIME)
        };
        let reserve_bytes = if request == Request::Inventory {
            0
        } else {
            reserve * PULL_BYTES
        };
        let budget = cap.min(available.saturating_sub(reserve_bytes));
        let timeout = self
            .deadline
            .saturating_duration_since(Instant::now())
            .saturating_sub(if final_check {
                Duration::ZERO
            } else {
                REQUEST_TIME
            })
            .min(max_time);
        ensure!(
            self.requests > reserve && budget > 0 && !timeout.is_zero(),
            "GitHub collection budget exhausted."
        );
        self.requests -= 1;
        let mut response = self
            .transport
            .open(route, timeout)
            .inspect_err(|error| {
                self.rate_limited = error.is::<GitHubRateLimit>();
            })?
            .take((budget + 1) as u64);
        let mut bytes = Vec::new();
        let read = response.read_to_end(&mut bytes);
        *available = available.saturating_sub(bytes.len());
        ensure!(
            read.is_ok() && bytes.len() <= budget,
            "GitHub response was incomplete or too large."
        );
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Invalid GitHub response data."))
    }

    fn blob(&mut self, repo: &str, id: &str, size: usize) -> Result<Option<String>> {
        sha(id)?;
        ensure!(size <= WINDOW_BLOB_BYTES, "File exceeds the size limit.");
        if let Some((known_size, text)) = self.blobs.get(id) {
            ensure!(*known_size == size, "Git blob size mismatch.");
            return Ok(text.clone());
        }
        // Account for base64, escaped line breaks, and GitHub's JSON envelope.
        let cap = if size <= BLOB_BYTES { 40_000 } else { 400_000 };
        let blob: GitBlob = self.get(&format!("{repo}/git/blobs/{id}"), cap, false)?;
        ensure!(blob.encoding == "base64", "Unsupported Git blob encoding.");
        let bytes = STANDARD.decode(blob.content.replace(['\n', '\r'], ""))?;
        ensure!(bytes.len() == size, "Git blob size mismatch.");
        let mut hash = Sha1::new();
        hash.update(format!("blob {size}\0"));
        hash.update(&bytes);
        ensure!(
            hex::encode(hash.finalize()) == id,
            "Git blob content mismatch."
        );
        let text = if bytes.contains(&0) {
            None
        } else {
            String::from_utf8(bytes).ok()
        };
        self.blobs.insert(id.to_owned(), (size, text.clone()));
        Ok(text)
    }
}

#[derive(Deserialize)]
struct GitBlob {
    encoding: String,
    content: String,
}

#[derive(Deserialize)]
struct GitId {
    sha: String,
}

#[derive(Deserialize, PartialEq, Eq)]
struct Repo {
    full_name: String,
    private: bool,
}

impl Repo {
    fn validate(&mut self, allowed: &HashSet<String>) -> Result<()> {
        ensure!(valid_repo(&self.full_name), "Invalid repository name.");
        ensure!(
            !self.private
                || allowed
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(&self.full_name)),
            "Private repository is not on the allowlist."
        );
        self.full_name.make_ascii_lowercase();
        Ok(())
    }
}

#[derive(Deserialize, PartialEq, Eq)]
struct Revision {
    sha: String,
    repo: Repo,
}

impl Revision {
    fn validate(&mut self, allowed: &HashSet<String>) -> Result<()> {
        sha(&self.sha)?;
        self.repo.validate(allowed)
    }
}

#[derive(Deserialize)]
struct Pull {
    number: u64,
    title: String,
    body: Option<String>,
    base: Revision,
    head: Revision,
    changed_files: u64,
}

impl Pull {
    fn validate(&mut self, repo: &str, number: u64, allowed: &HashSet<String>) -> Result<()> {
        self.base.validate(allowed)?;
        self.head.validate(allowed)?;
        ensure!(
            self.number == number && self.base.repo.full_name == repo,
            "Unexpected pull request."
        );
        Ok(())
    }

    fn same_revisions(&self, other: &Self) -> bool {
        self.base == other.base
            && self.head == other.head
            && self.changed_files == other.changed_files
    }
}

#[derive(Deserialize)]
struct Commit {
    sha: String,
    tree: GitId,
}

#[derive(Clone, Deserialize)]
struct Entry {
    path: String,
    mode: String,
    #[serde(rename = "type")]
    kind: String,
    sha: String,
    size: Option<usize>,
}

impl Entry {
    fn is_regular(&self) -> bool {
        self.kind == "blob" && matches!(self.mode.as_str(), "100644" | "100755")
    }

    fn file_size(&self) -> Option<usize> {
        self.is_regular().then_some(self.size).flatten()
    }
}

#[derive(Deserialize)]
struct TreeData {
    sha: String,
    truncated: bool,
    tree: Vec<Entry>,
}

type Directory = BTreeMap<String, Entry>;

struct Tree<'a> {
    repo: &'a str,
    commit: &'a str,
    root: Option<String>,
    directories: HashMap<String, Option<Directory>>,
}

impl<'a> Tree<'a> {
    fn new(repo: &'a str, commit: &'a str) -> Self {
        Self {
            repo,
            commit,
            root: None,
            directories: HashMap::new(),
        }
    }

    fn root<T: Transport>(&mut self, hub: &mut GitHub<T>) -> Result<&str> {
        if self.root.is_none() {
            let commit: Commit = hub.get(
                &format!("{}/git/commits/{}", self.repo, self.commit),
                64_000,
                false,
            )?;
            ensure!(commit.sha == self.commit, "Unexpected Git commit.");
            sha(&commit.tree.sha)?;
            self.root = Some(commit.tree.sha);
        }
        self.root.as_deref().context("Git tree is missing.")
    }

    fn directory<T: Transport>(&mut self, hub: &mut GitHub<T>, path: &str) -> Result<&Directory> {
        if !self.directories.contains_key(path) {
            self.directories.insert(path.to_owned(), None);
            let result = self.load_directory(hub, path)?;
            self.directories.insert(path.to_owned(), Some(result));
        }
        self.directories
            .get(path)
            .and_then(Option::as_ref)
            .context("Git directory is unavailable.")
    }

    fn load_directory<T: Transport>(
        &mut self,
        hub: &mut GitHub<T>,
        path: &str,
    ) -> Result<Directory> {
        let id = if path.is_empty() {
            self.root(hub)?.to_owned()
        } else {
            let (parent, name) = parent(path);
            let entries = self.directory(hub, parent)?;
            let Some(entry) = entries
                .get(name)
                .filter(|entry| entry.kind == "tree" && entry.mode == "040000")
            else {
                return Ok(Directory::new());
            };
            sha(&entry.sha)?.to_owned()
        };
        let data: TreeData = hub.get(&format!("{}/git/trees/{id}", self.repo), RESPONSE, false)?;
        ensure!(
            data.sha == id && !data.truncated,
            "Unexpected or truncated Git tree."
        );
        let mut entries = Directory::new();
        for entry in data.tree {
            ensure!(
                !entry.path.is_empty()
                    && !entry.path.contains('/')
                    && !entries.contains_key(&entry.path),
                "Ambiguous path in the Git tree."
            );
            entries.insert(entry.path.clone(), entry);
        }
        Ok(entries)
    }

    fn entry<T: Transport>(&mut self, hub: &mut GitHub<T>, path: &str) -> Result<Option<&Entry>> {
        let (dir, name) = parent(path);
        Ok(self.directory(hub, dir)?.get(name))
    }

    fn cached_entry(&self, path: &str) -> Option<&Entry> {
        let (dir, name) = parent(path);
        self.directories.get(dir)?.as_ref()?.get(name)
    }

    fn text<T: Transport>(
        &mut self,
        hub: &mut GitHub<T>,
        path: &str,
        remaining: usize,
    ) -> Result<Option<String>> {
        let repo = self.repo;
        let Some(entry) = self.entry(hub, path)? else {
            return Ok(None);
        };
        let size = entry
            .file_size()
            .context("Git entry must be a regular file.")?;
        ensure!(size <= remaining, "File exceeds the remaining text budget.");
        hub.blob(repo, &entry.sha, size)?
            .map(Some)
            .context("File must contain UTF-8 text.")
    }

    fn inventory<T: Transport>(
        &mut self,
        hub: &mut GitHub<T>,
        changed: &[SourceFile],
    ) -> Vec<Entry> {
        let repo = self.repo;
        let recursive = self.root(hub).and_then(|root| {
            let data: TreeData = hub.request(
                &format!("{repo}/git/trees/{root}?recursive=1"),
                INVENTORY_BYTES,
                Request::Inventory,
            )?;
            ensure!(data.sha == root, "Unexpected Git tree listing.");
            Ok(data)
        });
        if let Ok(data) = recursive {
            return data.tree;
        }
        // Large repositories can exceed the inventory cap. Keep the directly relevant directories.
        let mut dirs: BTreeSet<&str> = changed.iter().map(|file| parent(&file.path).0).collect();
        dirs.extend(["", "docs", "test", "tests", "spec"]);
        let mut entries = Vec::new();
        for dir in dirs {
            if let Ok(contents) = self.directory(hub, dir) {
                entries.extend(contents.values().cloned().map(|mut entry| {
                    if !dir.is_empty() {
                        entry.path = format!("{dir}/{}", entry.path);
                    }
                    entry
                }));
            }
        }
        entries
    }
}

fn parent(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}

#[derive(Deserialize)]
struct Comparison {
    base_commit: GitId,
    merge_base_commit: GitId,
    total_commits: u64,
    commits: Vec<ComparedCommit>,
    files: Option<Vec<Change>>,
}

#[derive(Deserialize)]
struct ComparedCommit {
    commit: CommitMessage,
}

#[derive(Deserialize)]
struct CommitMessage {
    message: String,
}

#[derive(Deserialize)]
struct Change {
    filename: String,
    status: String,
    sha: Option<String>,
    previous_filename: Option<String>,
    patch: Option<String>,
    additions: Option<usize>,
    deletions: Option<usize>,
    changes: Option<usize>,
}

impl Change {
    fn text_status(&self) -> bool {
        matches!(
            self.status.as_str(),
            "added" | "removed" | "modified" | "renamed" | "changed"
        )
    }

    fn previous(&self) -> Option<&str> {
        if self.status == "renamed" {
            safe_previous_path(&self.filename, self.previous_filename.as_deref())
        } else {
            Some(&self.filename)
        }
    }

    fn complete_patch(&self) -> Option<&str> {
        let patch = self.patch.as_deref()?;
        let mut additions = 0;
        let mut deletions = 0;
        for (base, head, _) in crate::hunks::lines(patch)? {
            if (self.status == "added" && base.is_some())
                || (self.status == "removed" && head.is_some())
            {
                return None;
            }
            additions += usize::from(base.is_none() && head.is_some());
            deletions += usize::from(base.is_some() && head.is_none());
        }
        (additions + deletions > 0
            && !patch.contains('\0')
            && self.additions == Some(additions)
            && self.deletions == Some(deletions)
            && self
                .changes
                .is_none_or(|total| total == additions + deletions))
        .then_some(patch)
    }

    fn pinned_entries<'a, T: Transport>(
        &self,
        hub: &mut GitHub<T>,
        base: &'a mut Tree<'_>,
        head: &'a mut Tree<'_>,
        previous: &str,
    ) -> (Option<&'a Entry>, Option<&'a Entry>) {
        let old = if self.status == "added" {
            None
        } else {
            base.entry(hub, previous).ok().flatten()
        };
        let new = if self.status == "removed" {
            None
        } else {
            head.entry(hub, &self.filename).ok().flatten()
        };
        (old, new)
    }

    fn review_patchless<T: Transport>(
        &self,
        hub: &mut GitHub<T>,
        base: &mut Tree<'_>,
        head: &mut Tree<'_>,
        previous: &str,
        limits: &mut Vec<String>,
    ) -> bool {
        // Binary changes can also have zero line counts. Check the pinned tree entries.
        if self.patch.is_none()
            && self.changes == Some(0)
            && self.additions.is_none_or(|count| count == 0)
            && self.deletions.is_none_or(|count| count == 0)
        {
            let (old, new) = self.pinned_entries(hub, base, head, previous);
            if report_mode_limits(&self.filename, old, new, limits) {
                return false;
            }
            let unchanged = match (self.status.as_str(), old, new) {
                ("added", None, Some(entry)) | ("removed", Some(entry), None) => {
                    entry.file_size() == Some(0) && sha(&entry.sha).is_ok()
                }
                (_, Some(old), Some(new)) => {
                    old.file_size().is_some()
                        && old.file_size() == new.file_size()
                        && old.sha == new.sha
                        && sha(&old.sha).is_ok()
                }
                _ => false,
            };
            if unchanged {
                return true;
            }
        }
        limits.push(format!(
            "Patch is missing or incomplete for {}.",
            self.filename
        ));
        false
    }
}

// Record metadata outside text review. Return true when a side cannot have citable file text.
fn report_mode_limits(
    path: &str,
    old: Option<&Entry>,
    new: Option<&Entry>,
    limits: &mut Vec<String>,
) -> bool {
    let entries = [old, new];
    if entries
        .into_iter()
        .flatten()
        .any(|entry| entry.mode == "160000" || entry.kind == "commit")
    {
        limits.push(format!("Submodule change for {path} was not reviewed."));
        return true;
    }
    if entries
        .into_iter()
        .flatten()
        .any(|entry| entry.mode == "120000")
    {
        limits.push(format!("Symbolic link change for {path} was not reviewed."));
        return true;
    }
    if let (Some(old), Some(new)) = (old, new)
        && old.is_regular()
        && new.is_regular()
        && old.mode != new.mode
    {
        limits.push(format!(
            "Git file mode change for {path} ({} to {}) was not reviewed.",
            old.mode, new.mode
        ));
    }
    false
}

fn has_gitlink_pointer(patch: &str) -> bool {
    patch
        .lines()
        .filter_map(|line| line.strip_prefix(['+', '-']))
        .filter_map(|line| line.strip_prefix("Subproject commit "))
        .any(|id| sha(id).is_ok())
}

fn may_be_symlink(change: &Change, patch: &str) -> bool {
    (change.additions == Some(1) || change.deletions == Some(1))
        && patch
            .lines()
            .any(|line| line == r"\ No newline at end of file")
}

fn inspect_patch_modes<T: Transport>(
    change: &Change,
    patch: &str,
    hub: &mut GitHub<T>,
    base: &mut Tree<'_>,
    head: &mut Tree<'_>,
    previous: &str,
    limits: &mut Vec<String>,
) -> bool {
    let gitlink = has_gitlink_pointer(patch);
    if !gitlink && !may_be_symlink(change, patch) {
        return true;
    }
    let path = &change.filename;
    let (old, new) = change.pinned_entries(hub, base, head, previous);
    if report_mode_limits(path, old, new, limits) {
        return false;
    }
    let regular = |entry: &Entry| entry.is_regular() && sha(&entry.sha).is_ok();
    if gitlink
        && (!(change.status == "added" || old.is_some_and(regular))
            || !(change.status == "removed" || new.is_some_and(regular)))
    {
        limits.push(format!(
            "Could not verify the Git entry type for {path}. Its patch was excluded."
        ));
        return false;
    }
    true
}

fn intent<T: Transport>(
    hub: &mut GitHub<T>,
    pull: &Pull,
    route: &str,
    first: &Comparison,
    limits: &mut Vec<String>,
) -> Vec<String> {
    let total = first.total_commits;
    let mut messages: Vec<String> = first
        .commits
        .iter()
        .take(COMMITS_PER_PAGE)
        .map(|entry| entry.commit.message.clone())
        .collect();
    for page in 2..=COMMIT_PAGES {
        if messages.len() as u64 >= total {
            break;
        }
        let result: Result<Comparison> = hub.get(
            &format!("{route}?per_page={COMMITS_PER_PAGE}&page={page}"),
            RESPONSE,
            false,
        );
        let Ok(batch) = result else { break };
        if batch.commits.is_empty()
            || batch.base_commit.sha != first.base_commit.sha
            || batch.merge_base_commit.sha != first.merge_base_commit.sha
            || batch.total_commits != total
        {
            break;
        }
        messages.extend(
            batch
                .commits
                .into_iter()
                .take(COMMITS_PER_PAGE)
                .map(|entry| entry.commit.message),
        );
    }
    if messages.len() as u64 != total {
        limits.push(format!(
            "Commit messages are incomplete ({} of {total}).",
            (messages.len() as u64).min(total)
        ));
    }
    let mut remaining = INTENT_BYTES;
    let mut output = Vec::new();
    let mut truncated = false;
    for text in [Some(pull.title.as_str()), pull.body.as_deref()]
        .into_iter()
        .flatten()
        .chain(
            messages
                .iter()
                .take(total.min(messages.len() as u64) as usize)
                .map(String::as_str),
        )
    {
        truncated |= text.len() > remaining;
        let text = &text[..text.floor_char_boundary(remaining.min(text.len()))];
        if !text.is_empty() {
            remaining -= text.len();
            output.push(text.to_owned());
        }
    }
    if truncated {
        limits.push("The title, description, and commit messages exceed the text limit.".into());
    }
    output
}

fn read_source<T: Transport>(
    hub: &mut GitHub<T>,
    tree: &mut Tree<'_>,
    path: &str,
    remaining: &mut usize,
) -> String {
    if *remaining == 0 {
        return String::new();
    }
    let text = tree
        .text(hub, path, BLOB_BYTES.min(*remaining))
        .ok()
        .flatten()
        .unwrap_or_default();
    *remaining -= text.len();
    text
}

fn generated_path(path: &str) -> bool {
    let path = path.to_ascii_lowercase();
    let name = parent(&path).1;
    path.split('/').any(|part| {
        matches!(
            part,
            "generated" | "__generated__" | "vendor" | "dist" | "node_modules"
        )
    }) || name.starts_with("zz_generated")
        || name.ends_with(".lock")
        || [".generated.", ".gen.", ".pb.", ".min.", "-lock."]
            .iter()
            .any(|marker| name.contains(marker))
}

fn head_windows(
    path: &str,
    text: &str,
    positions: &[usize],
    windows: &mut Vec<SourceWindow>,
    remaining: &mut usize,
) {
    // Use exact original line bytes, including CRLF and an absent final newline.
    let lines: Vec<_> = text.split_inclusive('\n').collect();
    let positions = &positions[..positions.partition_point(|&line| line <= lines.len())];
    let anchors = positions
        .chunk_by(|a, b| a.checked_add(1) == Some(*b))
        .flat_map(|run| {
            let first = run[0];
            let last = run[run.len() - 1];
            if last - first <= WINDOW_RADIUS {
                [Some(first + (last - first) / 2), None]
            } else {
                [Some(first), Some(last)]
            }
        })
        .flatten();
    let mut next_start = 0;
    let max_windows = HEAD_WINDOWS.min(windows.len() + WINDOWS_PER_FILE);
    for anchor in anchors {
        if windows.len() == max_windows || *remaining == 0 {
            break;
        }
        let anchor = anchor - 1;
        if anchor < next_start {
            continue;
        }
        let mut start = anchor.saturating_sub(WINDOW_RADIUS).max(next_start);
        let mut end = (anchor + WINDOW_RADIUS + 1).min(lines.len());
        let mut bytes: usize = lines[start..end].iter().map(|line| line.len()).sum();
        let cap = WINDOW_BYTES.min(*remaining);
        // Trim only whole lines, keeping the anchor and the closest available context.
        while bytes > cap && end - start > 1 {
            if anchor - start > end - anchor - 1 {
                bytes -= lines[start].len();
                start += 1;
            } else {
                end -= 1;
                bytes -= lines[end].len();
            }
        }
        if bytes > cap || (start + 1..=end).all(|line| positions.binary_search(&line).is_ok()) {
            continue;
        }
        *remaining -= bytes;
        next_start = end;
        windows.push(SourceWindow {
            path: path.to_owned(),
            start: start + 1,
            text: lines[start..end].concat(),
        });
    }
}

fn collect_head_context<T: Transport>(
    hub: &mut GitHub<T>,
    head: &mut Tree<'_>,
    files: &[SourceFile],
    remaining: &mut usize,
) -> Vec<SourceWindow> {
    let mut candidates: Vec<_> = files.iter().filter(|file| !file.patch.is_empty()).collect();
    // Prefer handwritten paths, then files that already lack whole head text.
    candidates.sort_by_key(|file| (generated_path(&file.path), !file.after.is_empty()));
    let mut windows = Vec::new();
    for file in candidates {
        if *remaining == 0 || windows.len() == HEAD_WINDOWS {
            break;
        }
        let Some(rows) = crate::hunks::lines(&file.patch) else {
            continue;
        };
        let positions: Vec<_> = rows.into_iter().filter_map(|(_, head, _)| head).collect();
        if positions.is_empty() {
            continue;
        }
        let downloaded;
        let text = if file.after.is_empty() {
            let Ok(Some(text)) = head.text(hub, &file.path, WINDOW_BLOB_BYTES) else {
                continue;
            };
            downloaded = text;
            downloaded.as_str()
        } else {
            &file.after
        };
        head_windows(&file.path, text, &positions, &mut windows, remaining);
        if file.after.is_empty() && !generated_path(&file.path) {
            callers::append(file, text, &positions, &mut windows, remaining);
        }
    }
    windows
}

fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
        .filter(|word| !word.is_empty())
}

fn stem(path: &str) -> &str {
    let name = parent(path).1;
    name.rsplit_once('.').map_or(name, |(stem, _)| stem)
}

fn file_terms(path: &str) -> impl Iterator<Item = &str> {
    stem(path)
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|term| {
            term.len() >= 3 && !matches!(*term, "test" | "tests" | "spec" | "index" | "main")
        })
}

fn search_terms(changed: &[SourceFile]) -> HashSet<String> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for file in changed {
        for term in file_terms(&file.path) {
            *counts.entry(term.to_ascii_lowercase()).or_default() += 8;
        }
        let changed_lines = file
            .patch
            .lines()
            .filter_map(|line| line.strip_prefix(['+', '-']));
        let fallback = if !file.patch.is_empty() {
            ""
        } else if file.after.is_empty() {
            &file.before
        } else {
            &file.after
        };
        for token in changed_lines.flat_map(words).chain(words(fallback)) {
            if (4..=60).contains(&token.len())
                && token.as_bytes()[0].is_ascii_alphabetic()
                && !matches!(
                    token,
                    "true"
                        | "false"
                        | "null"
                        | "None"
                        | "return"
                        | "function"
                        | "class"
                        | "public"
                        | "private"
                        | "const"
                        | "import"
                        | "export"
                        | "from"
                        | "name"
                        | "self"
                        | "this"
                        | "string"
                        | "number"
                        | "async"
                        | "await"
                        | "def"
                        | "value"
                        | "print"
                )
            {
                *counts.entry(token.to_ascii_lowercase()).or_default() += 1;
            }
        }
    }
    let mut counts: Vec<_> = counts.into_iter().collect();
    counts.sort_by(|(a, x), (b, y)| y.cmp(x).then(a.cmp(b)));
    counts.into_iter().take(24).map(|(term, _)| term).collect()
}

fn contract(path: &str) -> bool {
    let name = stem(path).to_ascii_lowercase();
    matches!(
        name.as_str(),
        "agents"
            | "contributing"
            | "readme"
            | "requirements"
            | "contract"
            | "contracts"
            | "specification"
            | "specifications"
            | "specifiche" // Recognize repositories that use the Italian name for specifications.
            | "design"
            | "architecture"
            | "openapi"
            | "swagger"
    )
}

fn test_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    let (directory, _) = parent(&lower);
    let stem = stem(&lower);
    directory.split('/').any(|part| {
        matches!(
            part,
            "test" | "tests" | "__tests__" | "spec" | "specs" | "e2e"
        )
    }) || stem.starts_with("test_")
        || [".test", ".spec", "_test", "_spec", "-test", "-spec"]
            .iter()
            .any(|suffix| stem.ends_with(suffix))
        || stem.ends_with("test")
}

fn nearby(path: &str, changed: &str) -> bool {
    let (directory, _) = parent(path);
    let (changed_dir, _) = parent(changed);
    directory == changed_dir
        || (!directory.is_empty()
            && changed_dir
                .strip_prefix(directory)
                .is_some_and(|rest| rest.starts_with('/')))
        || (!changed_dir.is_empty()
            && directory
                .strip_prefix(changed_dir)
                .is_some_and(|rest| rest.starts_with('/')))
}

fn labels(text: &str) -> impl Iterator<Item = &str> {
    text.split(|ch: char| !ch.is_ascii_alphanumeric())
        .flat_map(|mut part| {
            std::iter::from_fn(move || {
                if part.is_empty() {
                    return None;
                }
                let end = part
                    .as_bytes()
                    .windows(2)
                    .position(|pair| pair[0].is_ascii_lowercase() && pair[1].is_ascii_uppercase())
                    .map_or(part.len(), |index| index + 1);
                let (label, rest) = part.split_at(end);
                part = rest;
                Some(label)
            })
        })
}

fn role(label: &str) -> Option<&'static str> {
    match label.trim_end_matches('s') {
        "admin" | "administrator" | "backoffice" => Some("admin"),
        "write" | "writer" | "edit" | "editor" | "save" | "persist" | "update" | "action"
        | "mutation" => Some("write"),
        "config" | "configuration" | "setting" | "preference" => Some("config"),
        "resource" | "controller" | "handler" | "api" | "route" | "endpoint" => Some("resource"),
        _ => None,
    }
}

fn path_parts(path: &str) -> impl Iterator<Item = &str> {
    std::iter::once(stem(path)).chain(parent(path).0.rsplit('/').take(4))
}

fn module_basename(path: &str) -> &str {
    let filename = parent(path).1;
    filename
        .split_once('.')
        .map_or(filename, |(module, _)| module)
}

fn feature_key(part: &str) -> String {
    labels(part)
        .map(str::to_ascii_lowercase)
        .filter(|label| {
            label.len() >= 3
                && role(label).is_none()
                && !matches!(
                    label.as_str(),
                    "app"
                        | "apps"
                        | "packages"
                        | "src"
                        | "lib"
                        | "feature"
                        | "features"
                        | "test"
                        | "tests"
                        | "spec"
                        | "specs"
                        | "generated"
                        | "client"
                        | "server"
                        | "frontend"
                        | "backend"
                        | "ui"
                        | "index"
                        | "main"
                        | "view"
                        | "views"
                )
        })
        .collect::<Vec<_>>()
        .join("-")
}

fn package<'a>(path: &'a str, roots: &HashSet<String>) -> &'a str {
    let (mut directory, _) = parent(path);
    while !directory.is_empty() {
        if roots.contains(directory) {
            return directory;
        }
        directory = parent(directory).0;
    }
    let Some((top, rest)) = path.split_once('/') else {
        return "";
    };
    if matches!(
        top,
        "apps" | "packages" | "services" | "modules" | "crates" | "libs"
    ) && let Some((name, _)) = rest.split_once('/')
    {
        return &path[..top.len() + 1 + name.len()];
    }
    top
}

struct ContextQuery<'a> {
    changed: &'a [SourceFile],
    terms: HashSet<String>,
    modules: HashSet<String>,
    stems: HashSet<String>,
    features: HashSet<String>,
    roles: HashSet<&'static str>,
    roots: HashSet<String>,
    packages: HashSet<&'a str>,
}

impl<'a> ContextQuery<'a> {
    fn new(changed: &'a [SourceFile], intent: &[String], entries: &[Entry]) -> Self {
        let roots = entries
            .iter()
            .filter(|entry| entry.is_regular() && safe_path(&entry.path))
            .map(|entry| parent(&entry.path))
            .filter(|(dir, name)| {
                !dir.is_empty()
                    && matches!(
                        *name,
                        "package.json"
                            | "composer.json"
                            | "Cargo.toml"
                            | "pyproject.toml"
                            | "go.mod"
                    )
            })
            .map(|(dir, _)| dir.to_owned())
            .collect();
        let packages = changed
            .iter()
            .map(|file| package(&file.path, &roots))
            .collect();
        let modules = changed
            .iter()
            .flat_map(|file| {
                let root = package(&file.path, &roots);
                let directories =
                    std::iter::successors(Some(parent(&file.path).0), |dir| Some(parent(dir).0))
                        .take_while(move |dir| !dir.is_empty() && *dir != root)
                        .take(4)
                        .map(|dir| parent(dir).1);
                std::iter::once(module_basename(&file.path)).chain(directories)
            })
            .filter(|name| !feature_key(name).is_empty())
            .map(str::to_ascii_lowercase)
            .collect();
        let stems: HashSet<_> = changed
            .iter()
            .flat_map(|file| path_parts(&file.path))
            .map(feature_key)
            .filter(|name| !name.is_empty())
            .collect();
        let features = stems
            .iter()
            .flat_map(|name| name.split('-'))
            .map(str::to_owned)
            .collect();
        let roles = intent
            .iter()
            .flat_map(|text| labels(text))
            .filter_map(|label| role(&label.to_ascii_lowercase()))
            .collect();
        Self {
            changed,
            terms: search_terms(changed),
            modules,
            stems,
            features,
            roles,
            roots,
            packages,
        }
    }
}

struct Candidate {
    entry: Entry,
    size: usize,
    score: u32,
    module_rank: u8,
    nearby: bool,
    plausible: bool,
    preferred: bool,
}

impl Candidate {
    fn new(entry: Entry, query: &ContextQuery<'_>) -> Option<Self> {
        let size = entry.file_size()?;
        if size == 0 || size > BLOB_BYTES || !safe_path(&entry.path) {
            return None;
        }
        let name = parent(&entry.path).1;
        if entry
            .path
            .split('/')
            .any(|part| matches!(part, "node_modules" | "target" | "__pycache__"))
            || name.rsplit_once('.').is_some_and(|(_, ext)| {
                matches!(
                    ext.to_ascii_lowercase().as_str(),
                    "png"
                        | "jpg"
                        | "jpeg"
                        | "gif"
                        | "ico"
                        | "webp"
                        | "zip"
                        | "gz"
                        | "pdf"
                        | "woff"
                        | "woff2"
                        | "exe"
                        | "bin"
                        | "lock"
                )
            })
        {
            return None;
        }
        let is_nearby = query
            .changed
            .iter()
            .any(|file| nearby(&entry.path, &file.path));
        let related =
            file_terms(&entry.path).any(|term| query.terms.contains(&term.to_ascii_lowercase()));
        let guidance = contract(&entry.path);
        let test = test_path(&entry.path);
        let root = !entry.path.contains('/');
        let keys: Vec<_> = path_parts(&entry.path)
            .map(feature_key)
            .filter(|key| !key.is_empty())
            .collect();
        let exact = keys.iter().any(|key| query.stems.contains(key));
        let features: HashSet<_> = keys
            .iter()
            .flat_map(|key| key.split('-'))
            .filter(|term| query.features.contains(*term))
            .collect();
        let matches_feature = exact || !features.is_empty();
        let roles: HashSet<_> = path_parts(&entry.path)
            .flat_map(labels)
            .filter_map(|label| role(&label.to_ascii_lowercase()))
            .collect();
        let intent_roles = roles.intersection(&query.roles).count() as u32;
        let implementation = !test
            && !generated_path(&entry.path)
            && !entry.path.split('/').any(|part| {
                matches!(
                    part,
                    "locales" | "i18n" | "l10n" | "translations" | "testdata"
                )
            });
        let external = !query.packages.contains(package(&entry.path, &query.roots));
        let literal_module = query
            .modules
            .contains(&module_basename(&entry.path).to_ascii_lowercase());
        let literal_directory = parent(&entry.path)
            .0
            .rsplit('/')
            .take(4)
            .any(|dir| query.modules.contains(&dir.to_ascii_lowercase()));
        // Keep literal module matches ahead of lexical and content matches after inspecting blobs.
        let module_rank = match (literal_module, literal_directory, implementation, external) {
            (true, _, true, true) => 3,
            (true, _, true, false) => 2,
            (false, true, true, true) => 1,
            _ => 0,
        };
        let score = (u32::from(related) * 30
            + u32::from(guidance) * 36
            + u32::from(test) * 12
            + u32::from(is_nearby) * 16
            + u32::from(root) * 3
            + u32::from(test && related) * 12
            + u32::from(exact) * 56
            + (features.len().min(3) as u32) * 16
            + u32::from(matches_feature && implementation) * (22 + intent_roles * 22))
            .saturating_sub(if implementation { 0 } else { 18 });
        let preferred = implementation && external && (matches_feature || module_rank > 0);
        Some(Self {
            entry,
            size,
            score,
            module_rank,
            nearby: is_nearby,
            plausible: related || guidance || is_nearby || matches_feature || module_rank > 0,
            preferred,
        })
    }
}

fn probe_indices(candidates: &[Candidate], roots: &HashSet<String>) -> (Vec<usize>, usize) {
    let rank = candidates
        .first()
        .map_or(0, |candidate| candidate.module_rank);
    let best = candidates
        .iter()
        .find(|candidate| candidate.preferred && candidate.module_rank == rank)
        .map_or(0, |candidate| candidate.score);
    let mut packages = HashSet::new();
    let mut picked: Vec<_> = candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| {
            candidate.preferred
                && candidate.module_rank == rank
                && candidate.score >= best.saturating_sub(45)
                && packages.insert(package(&candidate.entry.path, roots))
        })
        .take(WIDER_PROBES)
        .map(|(index, _)| index)
        .collect();
    let priority = picked.len();
    let primary = (CONTEXT_PROBES - WIDER_PROBES).min(candidates.len());
    for (index, candidate) in candidates.iter().enumerate() {
        if picked.len() == CONTEXT_PROBES || (picked.len() >= primary && candidate.module_rank == 0)
        {
            break;
        }
        if !picked.contains(&index) {
            picked.push(index);
        }
    }
    // Leave a few reads for tests or possible callers in other implementation stacks.
    for wider in [true, false] {
        for (index, candidate) in candidates.iter().enumerate() {
            if picked.len() == CONTEXT_PROBES {
                break;
            }
            if (!wider || !candidate.nearby) && !picked.contains(&index) {
                picked.push(index);
            }
        }
    }
    (picked, priority)
}

fn collect_context<T: Transport>(
    hub: &mut GitHub<T>,
    head: &mut Tree<'_>,
    excluded: &HashSet<&str>,
    changed: &[SourceFile],
    intent: &[String],
    remaining: &mut usize,
) -> Vec<SourceFile> {
    if changed.is_empty() || *remaining == 0 {
        return Vec::new();
    }
    let entries = head.inventory(hub, changed);
    let query = ContextQuery::new(changed, intent, &entries);
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    for entry in entries {
        if !excluded.contains(entry.path.as_str())
            && seen.insert(entry.path.clone())
            && let Some(candidate) = Candidate::new(entry, &query)
        {
            candidates.push(candidate);
        }
    }
    candidates.sort_by(|a, b| {
        b.module_rank
            .cmp(&a.module_rank)
            .then(b.score.cmp(&a.score))
            .then(a.entry.path.cmp(&b.entry.path))
    });
    let (picked, priority) = probe_indices(&candidates, &query.roots);
    let mut ranked = Vec::new();
    for (position, index) in picked.into_iter().enumerate() {
        let candidate = &candidates[index];
        let entry = &candidate.entry;
        if candidate.size > *remaining {
            continue;
        }
        let Ok(Some(text)) = hub.blob(head.repo, &entry.sha, candidate.size) else {
            continue;
        };
        let matches: HashSet<_> = words(&text)
            .map(str::to_ascii_lowercase)
            .filter(|word| query.terms.contains(word))
            .collect();
        let references_path = changed
            .iter()
            .any(|file| file.path.contains('/') && text.contains(&file.path));
        if candidate.plausible || !matches.is_empty() || references_path {
            let score = candidate.score
                + u32::from(references_path) * 80
                + matches.len().min(4) as u32 * 48;
            ranked.push((
                candidate.module_rank,
                position < priority,
                score,
                &entry.path,
                text,
            ));
        }
    }
    ranked.sort_by(|(rank_a, wide_a, x, a, _), (rank_b, wide_b, y, b, _)| {
        rank_b
            .cmp(rank_a)
            .then(wide_b.cmp(wide_a))
            .then(y.cmp(x))
            .then(a.cmp(b))
    });
    // Optional context may be limited without losing any of the retained patches.
    let mut files = Vec::new();
    for (_, _, _, path, after) in ranked {
        if files.len() == CONTEXT_FILES {
            break;
        }
        if after.len() > *remaining {
            continue;
        }
        *remaining -= after.len();
        files.push(SourceFile {
            path: path.clone(),
            patch: String::new(),
            before: String::new(),
            after,
        });
    }
    files
}

fn diff_manifest(
    changes: &[Change],
    total_files: u64,
    mut patch_for: impl FnMut(&Change) -> Option<String>,
) -> PinnedDiff {
    let mut changed = HashSet::new();
    let duplicates: HashSet<_> = changes
        .iter()
        .map(|change| change.filename.as_str())
        .filter(|path| !changed.insert(*path))
        .collect();
    let mut seen = HashSet::new();
    let diff_files = changes
        .iter()
        .take(CHANGED_FILES)
        .filter_map(|change| {
            let path = change.filename.as_str();
            if !safe_path(path) || !seen.insert(path) {
                return None;
            }
            let mut previous_path = None;
            let status = match change.status.as_str() {
                status @ ("renamed" | "copied") => {
                    previous_path = safe_previous_path(path, change.previous_filename.as_deref());
                    if previous_path.is_some() {
                        status
                    } else {
                        "unsupported"
                    }
                }
                status @ ("added" | "removed" | "modified" | "changed") => status,
                _ => "unsupported",
            };
            let patch = (status != "unsupported" && !duplicates.contains(path))
                .then(|| patch_for(change))
                .flatten();
            Some(DiffFile {
                path: path.to_owned(),
                status: status.to_owned(),
                previous_path: previous_path.map(str::to_owned),
                patch,
            })
        })
        .collect();
    PinnedDiff {
        total_files,
        files: diff_files,
        supporting_paths: Vec::new(),
    }
}

fn stored_diff(
    changes: &[Change],
    files: &[SourceFile],
    head_context: &[SourceWindow],
    total_files: u64,
) -> PinnedDiff {
    let patches: HashMap<_, _> = files
        .iter()
        .filter(|file| !file.patch.is_empty())
        .map(|file| (file.path.as_str(), file.patch.as_str()))
        .collect();
    let mut diff = diff_manifest(changes, total_files, |change| {
        patches
            .get(change.filename.as_str())
            .map(|text| (*text).to_owned())
    });
    let changed: HashSet<_> = changes
        .iter()
        .flat_map(|change| [Some(change.filename.as_str()), change.previous()])
        .flatten()
        .collect();
    let mut seen = HashSet::new();
    diff.supporting_paths = files
        .iter()
        .map(|file| file.path.as_str())
        .chain(head_context.iter().map(|window| window.path.as_str()))
        .filter(|path| safe_path(path) && !changed.contains(path) && seen.insert(*path))
        .map(str::to_owned)
        .collect();
    diff
}

#[derive(Deserialize)]
struct PushComparison {
    #[serde(flatten)]
    comparison: DiffComparison,
    status: String,
    behind_by: u64,
}

fn pushed_paths<T: Transport>(
    hub: &mut GitHub<T>,
    head: &Revision,
    previous_head: Option<&str>,
) -> HashSet<String> {
    let Some(previous) = previous_head.filter(|id| *id != head.sha && sha(id).is_ok()) else {
        return HashSet::new();
    };
    let route = format!(
        "{}/compare/{previous}...{}?per_page=1&page=1",
        head.repo.full_name, head.sha,
    );
    let Ok(push) = hub.get::<PushComparison>(&route, RESPONSE, false) else {
        return HashSet::new();
    };
    let comparison = push.comparison;
    if push.status != "ahead"
        || push.behind_by != 0
        || comparison.base_commit.sha != previous
        || comparison.merge_base_commit.sha != previous
    {
        return HashSet::new();
    }
    let mut paths = HashSet::new();
    for change in comparison
        .files
        .unwrap_or_default()
        .into_iter()
        .take(CHANGED_FILES)
    {
        if safe_path(&change.filename)
            && let Some(previous) = change.previous()
        {
            paths.insert(previous.to_owned());
            paths.insert(change.filename);
        }
    }
    paths
}

fn ancillary_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    let (directory, name) = parent(&lower);
    generated_path(path)
        || test_path(path)
        || directory.split('/').any(|part| {
            matches!(
                part,
                "docs"
                    | "documentation"
                    | "examples"
                    | "fixtures"
                    | "snapshots"
                    | "__snapshots__"
                    | "locales"
                    | "i18n"
                    | "l10n"
                    | "translations"
                    | "testdata"
            )
        })
        || matches!(
            stem(name),
            "readme" | "changelog" | "license" | "contributing"
        )
}

fn rank_changes(
    changes: &mut [(&Change, &str)],
    intent: &[String],
    pushed: &HashSet<String>,
    prior_paths: &[String],
    fallback: &HashMap<&str, Change>,
) {
    let bytes = |change: &Change| {
        fallback
            .get(change.filename.as_str())
            .unwrap_or(change)
            .patch
            .as_ref()
            .map_or(0, String::len)
    };
    let oversubscribed = changes
        .iter()
        .map(|(change, _)| bytes(change))
        .sum::<usize>()
        > SNAPSHOT_TEXT_BYTES;
    if !oversubscribed && pushed.is_empty() && prior_paths.is_empty() {
        return;
    }
    let title = intent.first().map_or("", String::as_str);
    let title_names: HashSet<_> = title
        .split(|ch: char| !ch.is_alphanumeric() && !"_-/.".contains(ch))
        .filter(|word| word.len() >= 3)
        .map(str::to_ascii_lowercase)
        .collect();
    let title_terms: HashSet<_> = labels(title)
        .filter(|term| term.len() >= 3)
        .map(str::to_ascii_lowercase)
        .collect();

    let prior: HashSet<_> = prior_paths
        .iter()
        .map(String::as_str)
        .filter(|path| safe_path(path))
        .collect();
    let terms: HashSet<_> = intent
        .iter()
        .flat_map(|text| labels(text))
        .map(str::to_ascii_lowercase)
        .filter(|term| {
            term.len() >= 3
                && !matches!(
                    term.as_str(),
                    "the"
                        | "and"
                        | "for"
                        | "with"
                        | "from"
                        | "this"
                        | "that"
                        | "into"
                        | "use"
                        | "add"
                        | "fix"
                        | "file"
                        | "files"
                        | "change"
                        | "changes"
                )
        })
        .collect();
    let literals: HashSet<_> = intent
        .iter()
        .flat_map(|text| {
            text.split(|ch: char| !ch.is_alphanumeric() && !"/._-".contains(ch))
                .map(|word| word.trim_end_matches('.'))
        })
        .collect();
    let matches = |part: &str| {
        labels(part)
            .filter(|term| terms.contains(&term.to_ascii_lowercase()))
            .count()
    };
    changes.sort_by_cached_key(|(change, previous)| {
        let path = change.filename.as_str();
        let explicit = literals.contains(path) || literals.contains(previous);
        let name = stem(path);
        let title_matches = labels(name)
            .filter(|label| title_terms.contains(&label.to_ascii_lowercase()))
            .count();
        // After the named implementation, collect small related changes before
        // a second large patch can consume the remaining evidence budget.
        let ancillary = ancillary_path(path);
        let compact_related =
            !ancillary && title_matches > 0 && (1..=WINDOW_BYTES).contains(&bytes(change));
        (
            !(pushed.contains(path) || pushed.contains(*previous)),
            !(prior.contains(path) || prior.contains(previous)),
            ancillary || !title_names.contains(&name.to_ascii_lowercase()),
            !compact_related,
            !explicit,
            ancillary,
            Reverse(title_matches),
            Reverse(matches(stem(path)).max(matches(stem(previous)))),
            Reverse(path_parts(path).skip(1).map(matches).max().unwrap_or(0)),
        )
    });
}

fn pinned<T: Transport>(
    hub: &mut GitHub<T>,
    repo: String,
    number: u64,
    allowed: &HashSet<String>,
    expected_head: Option<&str>,
    previous_head: Option<&str>,
    prior_paths: &[String],
) -> Result<Snapshot> {
    let pull_route = format!("{repo}/pulls/{number}");
    let mut pull: Pull = hub.get(&pull_route, PULL_BYTES, false)?;
    pull.validate(&repo, number, allowed)?;
    ensure!(
        expected_head.is_none_or(|head| head.eq_ignore_ascii_case(&pull.head.sha)),
        HeadChanged("The pull request changed before review.")
    );
    let head_ref = if pull.head.repo.full_name == repo {
        pull.head.sha.clone()
    } else {
        let (owner, _) = pull
            .head
            .repo
            .full_name
            .split_once('/')
            .context("Invalid GitHub fork.")?;
        format!("{owner}:{}", pull.head.sha)
    };
    let route = format!("{repo}/compare/{}...{head_ref}", pull.base.sha);
    let first: Comparison = hub.get(
        &format!("{route}?per_page={COMMITS_PER_PAGE}&page=1"),
        RESPONSE,
        false,
    )?;
    ensure!(
        first.base_commit.sha == pull.base.sha,
        "Unexpected base commit in the Git comparison."
    );
    let base = sha(&first.merge_base_commit.sha)?;
    let changes = first
        .files
        .as_deref()
        .context("GitHub's list of changed files is missing.")?;
    let mut limits = Vec::new();
    if changes.len() as u64 != pull.changed_files || changes.len() > CHANGED_FILES {
        limits.push(format!(
            "Changed file list is incomplete ({} of {}).",
            changes.len().min(CHANGED_FILES),
            pull.changed_files
        ));
    }

    let mut seen = HashSet::new();
    let excluded = changes
        .iter()
        .flat_map(|change| [Some(change.filename.as_str()), change.previous()])
        .flatten()
        .collect();
    let mut ranked = Vec::new();
    for change in changes.iter().take(CHANGED_FILES) {
        let path = &change.filename;
        let Some(previous) = change.previous().filter(|previous| safe_path(previous)) else {
            limits.push("Some changes have invalid or duplicate paths.".into());
            continue;
        };
        if !safe_path(path) || !seen.insert(path) {
            limits.push("Some changes have invalid or duplicate paths.".into());
            continue;
        }
        if !change.text_status() {
            limits.push(format!("Unsupported change type for {path}."));
            continue;
        }
        ranked.push((change, previous));
    }
    let intent = intent(hub, &pull, &route, &first, &mut limits);
    let pushed = pushed_paths(hub, &pull.head, previous_head);
    let fallback = pull_files::candidates(hub, &pull_route, pull.changed_files, changes);
    rank_changes(&mut ranked, &intent, &pushed, prior_paths, &fallback);

    let mut files = Vec::new();
    let mut selected = Vec::new();
    let mut remaining = SNAPSHOT_TEXT_BYTES;
    let prior_names: HashSet<_> = prior_paths.iter().map(String::as_str).collect();
    let reserve_prior_head = !pushed.is_empty() && !prior_names.is_empty();
    let mut before = Tree::new(&repo, base);
    let mut after = Tree::new(&pull.head.repo.full_name, &pull.head.sha);
    for (change, previous) in ranked {
        let path = &change.filename;
        let candidate = fallback.get(path.as_str());
        let patch = change.complete_patch();
        // Keep the latest push first. Spend some of the remaining allowance on
        // reading the whole file behind an earlier concern before unrelated patches.
        let patch_budget = if reserve_prior_head
            && !pushed.contains(path)
            && !prior_names.contains(path.as_str())
            && !prior_names.contains(previous)
        {
            remaining.saturating_sub(HEAD_CONTEXT_BYTES)
        } else {
            remaining
        };
        if patch
            .or_else(|| candidate.and_then(|file| file.patch.as_deref()))
            .or(change.patch.as_deref())
            .is_some_and(|patch| patch.len() > patch_budget)
        {
            limits.push(format!(
                "Patch for {path} exceeds the remaining review text limit."
            ));
            continue;
        }
        let patch = patch
            .or_else(|| pull_files::verify(hub, &mut before, &mut after, candidate?, previous))
            .unwrap_or_default();
        if !inspect_patch_modes(
            change,
            patch,
            hub,
            &mut before,
            &mut after,
            previous,
            &mut limits,
        ) {
            continue;
        }
        remaining -= patch.len();
        selected.push((files.len(), change, previous));
        files.push(SourceFile {
            path: path.clone(),
            patch: patch.to_owned(),
            before: String::new(),
            after: String::new(),
        });
    }
    selected.retain(|&(index, change, previous)| {
        !files[index].patch.is_empty()
            || change.review_patchless(hub, &mut before, &mut after, previous, &mut limits)
    });

    if reserve_prior_head {
        let available = remaining.min(HEAD_CONTEXT_BYTES);
        let mut budget = available;
        for &(index, change, previous) in &selected {
            if change.status != "removed"
                && (prior_names.contains(change.filename.as_str())
                    || prior_names.contains(previous))
            {
                files[index].after = read_source(hub, &mut after, &change.filename, &mut budget);
            }
        }
        remaining -= available - budget;
    }
    // Reserve source for supporting heads before full changed bodies and their base copies.
    let context_allotment = remaining.min(CONTEXT_TEXT_BYTES);
    let mut context_budget = context_allotment;
    let mut supporting = collect_context(
        hub,
        &mut after,
        &excluded,
        &files,
        &intent,
        &mut context_budget,
    );
    remaining -= context_allotment - context_budget;
    let excluded = excluded
        .into_iter()
        .chain(supporting.iter().map(|file| file.path.as_str()))
        .collect();
    // Patches and any checks for missing ones take priority over full source bodies.
    let mut dependency_budget = local_dependencies::TEXT_BYTES.min(remaining / 2);
    remaining -= dependency_budget;
    let mut window_budget = remaining.min(HEAD_CONTEXT_BYTES);
    remaining -= window_budget;
    for &(index, change, _) in &selected {
        if change.status != "removed" && files[index].after.is_empty() {
            files[index].after = read_source(hub, &mut after, &change.filename, &mut remaining);
        }
    }
    let dependencies = local_dependencies::collect(
        hub,
        &mut before,
        &mut after,
        &files,
        &excluded,
        &mut dependency_budget,
    );
    remaining += dependency_budget;
    let mut head_context = collect_head_context(hub, &mut after, &files, &mut window_budget);
    remaining += window_budget;
    for file in &mut supporting {
        file.before = read_source(hub, &mut before, &file.path, &mut remaining);
    }
    let mut metadata_paths = HashSet::new();
    for (index, change, previous) in selected {
        if change.status != "added" {
            files[index].before = read_source(hub, &mut before, previous, &mut remaining);
        }
        // Read known modes from optional tree lookups without charging more requests for ordinary patches.
        let old = (change.status != "added")
            .then(|| before.cached_entry(previous))
            .flatten();
        let new = (change.status != "removed")
            .then(|| after.cached_entry(&change.filename))
            .flatten();
        if report_mode_limits(&change.filename, old, new, &mut limits) {
            files[index].patch.clear();
            files[index].before.clear();
            files[index].after.clear();
            metadata_paths.insert(change.filename.as_str());
        }
    }
    head_context.retain(|window| !metadata_paths.contains(window.path.as_str()));
    files.extend(dependencies);
    files.extend(supporting);
    let mut final_pull: Pull = hub.get(&pull_route, PULL_BYTES, true)?;
    final_pull.validate(&repo, number, allowed)?;
    if !pull.same_revisions(&final_pull) {
        let message = "The pull request changed during collection. Submit it again.";
        if pull.head.sha != final_pull.head.sha {
            bail!(HeadChanged(message));
        }
        bail!(message);
    }
    let mut unique = HashSet::new();
    limits.retain(|limit| unique.insert(limit.clone()));
    let diff = stored_diff(changes, &files, &head_context, pull.changed_files);
    Ok(Snapshot {
        url: format!("https://github.com/{repo}/pull/{number}"),
        repo,
        number,
        base: base.to_owned(),
        head: pull.head.sha,
        intent,
        files,
        head_context,
        limits,
        diff: Some(diff),
    })
}

pub fn collect(url: &str, allowed: &HashSet<String>) -> Result<Snapshot> {
    collect_at(url, allowed, None)
}

pub fn collect_at(
    url: &str,
    allowed: &HashSet<String>,
    expected_head: Option<&str>,
) -> Result<Snapshot> {
    collect_with_previous(url, allowed, expected_head, None, &[])
}

/// Collect pinned PR source, prioritizing paths from a fast-forward push and prior findings.
pub fn collect_with_previous(
    url: &str,
    allowed: &HashSet<String>,
    expected_head: Option<&str>,
    previous_head: Option<&str>,
    prior_paths: &[String],
) -> Result<Snapshot> {
    let (repo, number) = pull_url(url, allowed)?;
    pinned(
        &mut github()?,
        repo,
        number,
        allowed,
        expected_head,
        previous_head,
        prior_paths,
    )
}

#[derive(Deserialize)]
struct DiffPull {
    number: u64,
    base: Revision,
    head: DiffHead,
    changed_files: u64,
    #[serde(default)]
    merged: bool,
}

#[derive(Deserialize)]
struct DiffHead {
    sha: String,
    repo: Option<Repo>,
}

#[derive(Deserialize)]
struct DiffComparison {
    base_commit: GitId,
    merge_base_commit: GitId,
    files: Option<Vec<Change>>,
}

fn pinned_diff<T: Transport>(
    hub: &mut GitHub<T>,
    repo: &str,
    number: u64,
    base: &str,
    head: &str,
    allowed: &HashSet<String>,
) -> Result<Option<PinnedDiff>> {
    let mut pull: DiffPull = hub.get(&format!("{repo}/pulls/{number}"), PULL_BYTES, false)?;
    pull.base.validate(allowed)?;
    ensure!(
        pull.number == number && pull.base.repo.full_name == repo,
        "Unexpected pull request."
    );
    if sha(&pull.head.sha)? != head {
        return Ok(None);
    }
    if let Some(fork) = &mut pull.head.repo {
        fork.validate(allowed)?;
    } else if !pull.merged {
        return Ok(None);
    }

    // A merged PR's current base tip may already contain the head. An unmerged
    // PR uses its current base tip to detect changes to the reviewed merge base.
    let compare_base = if pull.merged { base } else { &pull.base.sha };
    let first: DiffComparison = hub.get(
        &format!("{repo}/compare/{compare_base}...{head}?per_page=1&page=1"),
        RESPONSE,
        false,
    )?;
    ensure!(
        sha(&first.base_commit.sha)? == compare_base,
        "Unexpected base commit in the Git comparison."
    );
    if sha(&first.merge_base_commit.sha)? != base {
        return Ok(None);
    }
    let changes = first
        .files
        .as_deref()
        .context("GitHub's list of changed files is missing.")?;
    let total_files = pull.changed_files.max(changes.len() as u64);
    let mut remaining = SNAPSHOT_TEXT_BYTES;
    Ok(Some(diff_manifest(changes, total_files, |change| {
        if change.patch.as_deref()?.len() > remaining {
            return None;
        }
        let patch = change.complete_patch()?;
        // Historical display does not look up tree modes.
        if has_gitlink_pointer(patch) || may_be_symlink(change, patch) {
            return None;
        }
        remaining -= patch.len();
        Some(patch.to_owned())
    })))
}

/// Reload a saved pull request diff with two bounded GitHub requests at most.
pub fn collect_pinned_diff(
    url: &str,
    base: &str,
    head: &str,
    allowed: &HashSet<String>,
) -> Result<Option<PinnedDiff>> {
    let (repo, number) = pull_url(url, allowed)?;
    sha(base)?;
    sha(head)?;
    pinned_diff(&mut github()?, &repo, number, base, head, allowed)
}

fn github() -> Result<GitHub<Http>> {
    let mut headers = HeaderMap::new();
    if let Some(token) = std::env::var_os("JIDOKA_GITHUB_TOKEN").filter(|value| !value.is_empty()) {
        let token = token.to_str().context("Invalid GitHub token")?;
        let mut value =
            HeaderValue::from_str(&format!("Bearer {token}")).context("Invalid GitHub token")?;
        value.set_sensitive(true);
        headers.insert(AUTHORIZATION, value);
    }
    let client = Client::builder()
        .default_headers(headers)
        .redirect(Policy::none())
        .no_proxy()
        .https_only(true)
        .connect_timeout(REQUEST_TIME)
        .user_agent("jidoka-review")
        .build()?;
    Ok(GitHub::new(Http(client)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::{collections::VecDeque, io::Cursor};

    const REPO: &str = "owner/project";
    const FORK: &str = "contributor/project";
    const BASE: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const TIP: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const HEAD: &str = "cccccccccccccccccccccccccccccccccccccccc";
    const MOVED: &str = "dddddddddddddddddddddddddddddddddddddddd";
    const PULL: &str = "owner/project/pulls/3";

    enum File<'a> {
        Text(&'a str),
        Executable(&'a str),
        Bytes(&'a [u8]),
        Symlink,
        Gitlink(&'a str),
    }

    #[derive(Default)]
    struct Fixture {
        responses: HashMap<String, Value>,
        pulls: VecDeque<Value>,
        requests: Vec<String>,
        quota_on: Option<String>,
    }

    fn pull(head: &str, changes: u64) -> Value {
        json!({
            "number": 3, "title": "Synthetic change", "body": "Fixture intent",
            "base": {"sha": TIP, "repo": {"full_name": REPO, "private": false}},
            "head": {"sha": head, "repo": {"full_name": FORK, "private": false}},
            "changed_files": changes,
        })
    }

    fn comparison(page: usize) -> String {
        format!("{REPO}/compare/{TIP}...contributor:{HEAD}?per_page={COMMITS_PER_PAGE}&page={page}")
    }

    fn change(path: &str) -> Value {
        json!({
            "filename": path, "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new",
            "additions": 1, "deletions": 1, "changes": 2,
        })
    }

    fn id(text: &[u8]) -> String {
        hex::encode(Sha1::digest(text))
    }

    fn blob_id(text: &[u8]) -> String {
        id(&[format!("blob {}\0", text.len()).as_bytes(), text].concat())
    }

    fn pull_files_page(page: usize) -> String {
        format!("{PULL}/files?per_page=30&page={page}")
    }

    impl Fixture {
        fn new(changes: Vec<Value>) -> Self {
            let mut fixture = Self {
                pulls: VecDeque::from([
                    pull(HEAD, changes.len() as u64),
                    pull(HEAD, changes.len() as u64),
                ]),
                ..Self::default()
            };
            fixture.page(1, Some(changes), 1, &["Rename the synthetic value."]);
            fixture
        }

        fn page(&mut self, page: usize, files: Option<Vec<Value>>, total: u64, messages: &[&str]) {
            let commits: Vec<_> = messages
                .iter()
                .map(|message| json!({"commit": {"message": message}}))
                .collect();
            self.responses.insert(
                comparison(page),
                json!({
                    "base_commit": {"sha": TIP}, "merge_base_commit": {"sha": BASE},
                    "total_commits": total, "files": files, "commits": commits,
                }),
            );
        }

        fn revision(&mut self, repo: &str, commit: &str, files: &[(&str, File<'_>)]) -> String {
            let tree_id = |dir: &str| id(format!("{repo}/{commit}/{dir}").as_bytes());
            let root = tree_id("");
            let mut dirs = BTreeMap::<&str, Vec<Value>>::from([("", Vec::new())]);
            let mut inventory = Vec::new();
            for (path, file) in files {
                let mut entry = match file {
                    File::Symlink => {
                        json!({"mode": "120000", "type": "blob", "sha": MOVED, "size": 1})
                    }
                    File::Gitlink(sha) => json!({"mode": "160000", "type": "commit", "sha": sha}),
                    _ => {
                        let bytes = match file {
                            File::Text(text) | File::Executable(text) => text.as_bytes(),
                            File::Bytes(bytes) => bytes,
                            File::Symlink | File::Gitlink(_) => unreachable!(),
                        };
                        let hash = blob_id(bytes);
                        self.responses.insert(
                            format!("{repo}/git/blobs/{hash}"),
                            json!({
                                "encoding": "base64", "content": STANDARD.encode(bytes),
                            }),
                        );
                        let mode = if matches!(file, File::Executable(_)) {
                            "100755"
                        } else {
                            "100644"
                        };
                        json!({"mode": mode, "type": "blob", "sha": hash, "size": bytes.len()})
                    }
                };
                entry["path"] = json!(path);
                inventory.push(entry.clone());
                let (dir, name) = parent(path);
                entry["path"] = json!(name);
                dirs.entry(dir).or_default().push(entry);
                let mut ancestor = dir;
                while !ancestor.is_empty() {
                    ancestor = parent(ancestor).0;
                    dirs.entry(ancestor).or_default();
                }
            }
            let dir_names: Vec<_> = dirs.keys().copied().collect();
            for dir in dir_names.into_iter().filter(|dir| !dir.is_empty()) {
                let (parent, name) = parent(dir);
                dirs.get_mut(parent).unwrap().push(json!({
                    "path": name, "mode": "040000", "type": "tree", "sha": tree_id(dir),
                }));
            }
            for (dir, entries) in dirs {
                let sha = tree_id(dir);
                self.responses.insert(
                    format!("{repo}/git/trees/{sha}"),
                    json!({
                        "sha": sha, "truncated": false, "tree": entries,
                    }),
                );
            }
            self.responses.insert(
                format!("{repo}/git/commits/{commit}"),
                json!({"sha": commit, "tree": {"sha": root}}),
            );
            self.responses.insert(
                format!("{repo}/git/trees/{root}?recursive=1"),
                json!({
                    "sha": root, "truncated": false, "tree": inventory,
                }),
            );
            root
        }
    }

    impl Transport for Fixture {
        fn open(&mut self, route: &str, timeout: Duration) -> Result<Box<dyn Read>> {
            assert!(!route.starts_with('/') && !route.contains("://"));
            let cap = if route.ends_with("?recursive=1") {
                INVENTORY_TIME
            } else {
                REQUEST_TIME
            };
            assert!(!timeout.is_zero() && timeout <= cap);
            self.requests.push(route.to_owned());
            if self.quota_on.as_deref() == Some(route)
                && (route != PULL || self.requests.iter().filter(|r| *r == PULL).count() > 1)
            {
                return Err(GitHubRateLimit.into());
            }
            let value = if route == PULL {
                self.pulls.pop_front()
            } else {
                self.responses.get(route).cloned()
            };
            Ok(Box::new(Cursor::new(serde_json::to_vec(
                &value.context("Missing fixture response")?,
            )?)))
        }
    }

    fn snapshot(hub: &mut GitHub<Fixture>) -> Result<Snapshot> {
        snapshot_since(hub, None, &[])
    }

    fn snapshot_since(
        hub: &mut GitHub<Fixture>,
        previous_head: Option<&str>,
        prior_paths: &[String],
    ) -> Result<Snapshot> {
        pinned(
            hub,
            REPO.into(),
            3,
            &HashSet::from([REPO.to_owned()]),
            None,
            previous_head,
            prior_paths,
        )
    }

    #[test]
    fn stale_automatic_head_stops_after_reading_pr_metadata() {
        let mut hub = GitHub::new(Fixture::new(vec![change("main.rs")]));
        let error = pinned(
            &mut hub,
            REPO.to_owned(),
            3,
            &HashSet::from([REPO.to_owned()]),
            Some(BASE),
            None,
            &[],
        )
        .unwrap_err();
        assert!(error.to_string().contains("changed before review"));
        assert_eq!(hub.transport.requests, [PULL]);
    }

    fn diff_comparison(base: &str) -> String {
        format!("{REPO}/compare/{base}...{HEAD}?per_page=1&page=1")
    }

    fn load_diff(hub: &mut GitHub<Fixture>, allowed: &[&str]) -> Result<Option<PinnedDiff>> {
        pinned_diff(
            hub,
            REPO,
            3,
            BASE,
            HEAD,
            &allowed.iter().map(|repo| (*repo).to_owned()).collect(),
        )
    }

    #[test]
    fn legacy_diff_stops_after_a_stale_head_or_a_changed_merge_base() {
        let mut fixture = Fixture::default();
        fixture.pulls.extend([pull(MOVED, 1), pull(HEAD, 1)]);
        let route = diff_comparison(TIP);
        fixture.responses.insert(
            route.clone(),
            json!({"base_commit": {"sha": TIP}, "merge_base_commit": {"sha": MOVED}}),
        );
        let mut hub = GitHub::new(fixture);
        assert!(load_diff(&mut hub, &[REPO]).unwrap().is_none());
        assert_eq!(hub.transport.requests, [PULL]);
        hub.transport.requests.clear();
        assert!(load_diff(&mut hub, &[REPO]).unwrap().is_none());
        assert_eq!(hub.transport.requests, [PULL, &route]);
    }

    #[test]
    fn legacy_diff_uses_saved_base_for_a_merged_pr_with_a_deleted_fork() {
        let mut pr = pull(HEAD, 1);
        pr["head"]["repo"] = Value::Null;
        pr["merged"] = json!(true);
        pr["base"]["sha"] = json!(MOVED);
        let route = diff_comparison(BASE);
        let response = json!({
            "base_commit": {"sha": BASE}, "merge_base_commit": {"sha": BASE},
            "files": [change("main.rs")],
        });
        let mut hub = GitHub::new(Fixture {
            pulls: [pr].into(),
            responses: HashMap::from([(route.clone(), response)]),
            ..Fixture::default()
        });
        let diff = load_diff(&mut hub, &[REPO]).unwrap().unwrap();
        assert_eq!(diff.total_files, 1);
        assert!(diff.files[0].patch.is_some());
        assert!(diff.supporting_paths.is_empty());
        assert_eq!(hub.transport.requests, [PULL, &route]);
    }

    #[test]
    fn legacy_diff_requires_private_fork_access_and_preserves_rate_limits() {
        let mut pr = pull(HEAD, 1);
        pr["head"]["repo"]["private"] = json!(true);
        let route = diff_comparison(TIP);
        let mut hub = GitHub::new(Fixture {
            pulls: [pr.clone(), pr].into(),
            quota_on: Some(route.clone()),
            ..Fixture::default()
        });
        let error = load_diff(&mut hub, &[REPO]).unwrap_err();
        assert!(error.to_string().contains("Private repository"));
        assert_eq!(hub.transport.requests, [PULL]);
        hub.transport.requests.clear();
        let error = load_diff(&mut hub, &[REPO, FORK]).unwrap_err();
        assert!(error.is::<GitHubRateLimit>());
        assert_eq!(hub.transport.requests, [PULL, &route]);
    }

    #[test]
    fn legacy_diff_keeps_only_safe_complete_patches_within_the_text_budget() {
        let large = |path: &str| {
            let mut file = change(path);
            file["patch"] = json!(format!("@@ -1 +1 @@\n-old\n+{}", "x".repeat(60_000)));
            file
        };
        let mut rename = change("renamed.rs");
        rename["status"] = json!("renamed");
        rename["previous_filename"] = json!("../unsafe.rs");
        let mut partial = change("partial.rs");
        partial["additions"] = json!(2);
        let mut gitlink = change("submodule");
        gitlink["patch"] = json!(format!(
            "@@ -1 +1 @@\n-Subproject commit {BASE}\n+Subproject commit {HEAD}"
        ));
        let mut symlink = change("link");
        symlink["patch"] = json!(
            "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file"
        );
        let files = [
            large("fits.rs"),
            large("too-large.rs"),
            rename,
            partial,
            gitlink,
            symlink,
            change("../unsafe.rs"),
            change("duplicate.rs"),
            change("duplicate.rs"),
            change("last.rs"),
        ];
        let route = diff_comparison(TIP);
        let mut hub = GitHub::new(Fixture {
            pulls: [pull(HEAD, files.len() as u64)].into(),
            responses: HashMap::from([(
                route.clone(),
                json!({
                    "base_commit": {"sha": TIP}, "merge_base_commit": {"sha": BASE},
                    "files": files,
                }),
            )]),
            ..Fixture::default()
        });
        let diff = load_diff(&mut hub, &[REPO]).unwrap().unwrap();
        assert_eq!(diff.total_files, 10);
        assert_eq!(diff.files.len(), 8);
        let patched: Vec<_> = diff
            .files
            .iter()
            .filter(|file| file.patch.is_some())
            .map(|file| file.path.as_str())
            .collect();
        assert_eq!(patched, ["fits.rs", "last.rs"]);
        assert_eq!(diff.files[2].path, "renamed.rs");
        assert_eq!(diff.files[2].status, "unsupported");
        assert!(diff.files[2].previous_path.is_none());
        assert_eq!(hub.transport.requests, [PULL, &route]);
    }

    #[test]
    fn stored_diff_includes_supporting_paths_from_head_windows_once() {
        let mut renamed = change("new.rs");
        renamed["status"] = json!("renamed");
        renamed["previous_filename"] = json!("old.rs");
        let changes = [serde_json::from_value(renamed).unwrap()];
        let files = [SourceFile {
            path: "README.md".into(),
            patch: String::new(),
            before: String::new(),
            after: "Notes.".into(),
        }];
        let windows = [
            "new.rs",
            "old.rs",
            "README.md",
            "src/caller.rs",
            "../unsafe.rs",
            "src/caller.rs",
        ]
        .map(|path| SourceWindow {
            path: path.into(),
            start: 1,
            text: "Context.".into(),
        });
        let diff = stored_diff(&changes, &files, &windows, 1);
        assert_eq!(diff.supporting_paths, ["README.md", "src/caller.rs"]);
    }

    #[test]
    fn persists_pinned_changes_separately_from_supporting_source() {
        let mut fixture = Fixture::new(vec![
            change("src/task.rs"),
            json!({"filename": "assets/sample.bin", "status": "added", "changes": 0}),
            change("../outside.rs"),
        ]);
        fixture.revision(REPO, BASE, &[("src/task.rs", File::Text("old\n"))]);
        fixture.revision(
            FORK,
            HEAD,
            &[
                ("src/task.rs", File::Text("new\n")),
                ("assets/sample.bin", File::Bytes(&[0])),
                ("README.md", File::Text("The repository contract.\n")),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let snapshot = snapshot(&mut hub).unwrap();
        let diff = snapshot.diff.as_ref().unwrap();
        assert_eq!(diff.total_files, 3);
        assert_eq!(diff.files.len(), 2);
        assert_eq!(diff.files[0].path, "src/task.rs");
        assert_eq!(
            diff.files[0].patch.as_deref(),
            Some("@@ -1 +1 @@\n-old\n+new")
        );
        assert_eq!(diff.files[1].path, "assets/sample.bin");
        assert!(diff.files[1].patch.is_none());
        assert_eq!(diff.supporting_paths, ["README.md"]);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);

        let report = crate::review_snapshot(snapshot, |_, data| {
            assert!(data["snapshot"].get("diff").is_none());
            if data.get("hypotheses").is_some() {
                Ok(json!({"complete": true, "assessments": []}))
            } else {
                Ok(json!({"complete": true, "hypotheses": []}))
            }
        })
        .unwrap();
        let saved: crate::contracts::PublishedReport =
            serde_json::from_str(&serde_json::to_string(&report).unwrap()).unwrap();
        assert!(saved.report.findings.is_empty());
        assert!(crate::diff::anchor(&saved, "src/task.rs", 1).is_some());
        assert!(crate::diff::render(&saved).contains("assets/sample.bin"));
    }

    fn context_snapshot(changed: &str) -> Snapshot {
        Snapshot {
            url: format!("https://github.com/{REPO}/pull/3"),
            repo: REPO.into(),
            number: 3,
            base: BASE.into(),
            head: HEAD.into(),
            intent: Vec::new(),
            files: vec![SourceFile {
                path: changed.into(),
                patch: "@@ -1 +1 @@\n-old\n+new".into(),
                before: String::new(),
                after: String::new(),
            }],
            head_context: Vec::new(),
            limits: Vec::new(),
            diff: None,
        }
    }

    fn context_read(path: &str, term: &str) -> crate::contracts::ContextRead {
        crate::contracts::ContextRead {
            path: path.into(),
            term: term.into(),
        }
    }

    #[test]
    fn contextual_stem_prefers_qualified_implementation_and_finds_later_uses() {
        let sample = "ui/widget/widget.component.tsx";
        let declaration = "export interface Options { minLength: number }\r\n";
        let padding = "// Fixture padding.\r\n".repeat(26);
        let text = format!(
            "{declaration}{padding}const valid = value.length >= minLength;\r\n{padding}return <input minLength={{minLength}} />;"
        );
        let mut fixture = Fixture::new(Vec::new());
        for pull in &mut fixture.pulls {
            pull["head"]["repo"]["private"] = json!(true);
        }
        fixture.revision(
            FORK,
            HEAD,
            &[
                (sample, File::Text(&text)),
                ("ui/widget.test.tsx", File::Text(declaration)),
                ("ui/widget.types.ts", File::Text(declaration)),
                ("ui/widget.stories.tsx", File::Text(declaration)),
                ("ui/widget.mdx", File::Text(declaration)),
                ("ui/widget/index.ts", File::Text(declaration)),
                (
                    "archive/widget/widget.component.tsx",
                    File::Text(declaration),
                ),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let windows = reads::read_with(
            &mut hub,
            &context_snapshot("ui/panel.tsx"),
            &HashSet::from([REPO.into(), FORK.into()]),
            &[context_read("Widget", "minLength")],
        )
        .unwrap();
        assert_eq!(windows.len(), 2);
        assert!(windows.iter().all(|window| window.path == sample));
        assert!(windows[0].text.contains("return <input"));
        assert!(windows[1].text.contains("value.length >= minLength"));
        let lines: Vec<_> = text.split_inclusive('\n').collect();
        for window in windows {
            let start = window.start - 1;
            assert_eq!(
                window.text,
                lines[start..start + window.text.lines().count()].concat()
            );
        }
        assert_eq!(hub.transport.requests.first().unwrap(), PULL);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
        assert!(
            hub.transport.requests[1..hub.transport.requests.len() - 1]
                .iter()
                .all(|route| route.starts_with(FORK))
        );
    }

    #[test]
    fn contextual_reads_keep_two_tied_paths_and_bound_each_batch() {
        let text = format!(
            "first token\n{}last token\n",
            ("Fixture line for budget testing. ".repeat(4) + "\n").repeat(30)
        );
        let mut fixture = Fixture::new(Vec::new());
        fixture.revision(
            FORK,
            HEAD,
            &[
                ("packages/alpha/widget.ts", File::Text(&text)),
                ("packages/beta/widget.component.tsx", File::Text(&text)),
                ("packages/gamma/widget.ts", File::Text(&text)),
                ("docs/config.txt", File::Text(&text)),
                ("docs/options.txt", File::Text(&text)),
                ("docs/unrequested.txt", File::Text(&text)),
            ],
        );
        let windows = reads::read_with(
            &mut GitHub::new(fixture),
            &context_snapshot("packages/ui/main.ts"),
            &HashSet::from([REPO.into()]),
            &[
                context_read("widget", "token"),
                context_read("docs/config.txt", "token"),
                context_read("docs/options.txt", "token"),
                context_read("docs/unrequested.txt", "token"),
            ],
        )
        .unwrap();
        assert_eq!(windows.len(), 6);
        assert_eq!(windows[0].path, "packages/alpha/widget.ts");
        assert_eq!(windows[1].path, "packages/beta/widget.component.tsx");
        assert!(
            windows[2..4]
                .iter()
                .all(|window| window.path == "docs/config.txt")
        );
        assert!(
            windows[4..6]
                .iter()
                .all(|window| window.path == "docs/options.txt")
        );
        assert!(
            windows
                .iter()
                .map(|window| window.text.len())
                .sum::<usize>()
                <= 12_000
        );
    }

    #[test]
    fn contextual_reads_validate_the_snapshot_and_fork_before_reading_blobs() {
        let view = context_snapshot("ui/panel.tsx");
        let allowed = HashSet::from([REPO.into()]);
        let request = [context_read("ui/helper.ts", "const")];
        let mut fixture = Fixture::new(Vec::new());
        fixture.pulls[0] = pull(MOVED, 0);
        let mut hub = GitHub::new(fixture);
        assert!(reads::read_with(&mut hub, &view, &allowed, &request).is_err());
        assert_eq!(hub.transport.requests, [PULL]);

        let mut fixture = Fixture::new(Vec::new());
        fixture.pulls[0]["head"]["repo"]["private"] = json!(true);
        let mut hub = GitHub::new(fixture);
        assert!(reads::read_with(&mut hub, &view, &allowed, &request).is_err());
        assert_eq!(hub.transport.requests, [PULL]);

        let mut hub = GitHub::new(Fixture::new(Vec::new()));
        let mut wrong = view;
        wrong.number = 4;
        assert!(reads::read_with(&mut hub, &wrong, &allowed, &request).is_err());
        assert!(hub.transport.requests.is_empty());
    }

    #[test]
    fn contextual_reads_skip_unsafe_paths_unverified_blobs_and_nonliteral_hits() {
        let mut fixture = Fixture::new(Vec::new());
        let file = "ui/helper.ts";
        fixture.revision(
            FORK,
            HEAD,
            &[
                (file, File::Text("const option = true;\n")),
                ("ui/link.ts", File::Symlink),
                ("ui/literal.ts", File::Text("const value = 'ab';\n")),
            ],
        );
        let blob = id(b"blob 21\0const option = true;\n");
        let corrupt = format!("{FORK}/git/blobs/{blob}");
        fixture.responses.get_mut(&corrupt).unwrap()["content"] =
            json!(STANDARD.encode("const option = fake;\n"));
        let mut hub = GitHub::new(fixture);
        let view = context_snapshot("ui/panel.tsx");
        let allowed = HashSet::from([REPO.into()]);
        let invalid = [
            context_read("../ui/helper.ts", "const"),
            context_read("ui/literal.ts", " "),
        ];
        assert!(
            reads::read_with(&mut hub, &view, &allowed, &invalid)
                .unwrap()
                .is_empty()
        );
        assert!(hub.transport.requests.is_empty());
        let rejected = [
            context_read(file, "const"),
            context_read("ui/link.ts", "const"),
            context_read("ui/literal.ts", "a.b"),
        ];
        assert!(
            reads::read_with(&mut hub, &view, &allowed, &rejected)
                .unwrap()
                .is_empty()
        );
        assert!(hub.transport.requests.contains(&corrupt));
        assert!(
            hub.transport
                .requests
                .iter()
                .all(|route| !route.ends_with(MOVED))
        );
    }

    #[test]
    fn validates_raw_pr_url_and_allowlist_before_transport() {
        let allowed = HashSet::from([REPO.to_ascii_uppercase()]);
        assert_eq!(
            pull_url(
                "https://GitHub.com/OWNER/Project/pull/3/#discussion",
                &allowed
            )
            .unwrap(),
            (REPO.into(), 3)
        );
        for url in [
            "http://github.com/owner/project/pull/3",
            "https://github.com:443/owner/project/pull/3",
            "https://github.com.evil.test/owner/project/pull/3",
            "https://github.com@evil.test/owner/project/pull/3",
            "https://github.com/x/../owner/project/pull/3",
            "https://github.com/owner/%2e%2e/pull/3",
            "https://github.com/owner/project/pull/03",
            "https://github.com/owner/project/pull/3/files",
            "https://github.com/other/project/pull/3",
        ] {
            assert!(pull_url(url, &allowed).is_err(), "{url}");
        }
    }

    #[test]
    fn safe_paths_allow_unicode_marks_and_reject_invisible_and_reserved_components() {
        for path in [
            "src/テ\u{3099}ータ.py",
            "src/데이터.py",
            "src/कि.py",
            "src/a\u{20dd}.py",
            "src/✈\u{fe0f}.py",
            "src/sample #.py",
        ] {
            assert!(safe_path(path), "rejected {path:?}");
        }
        for path in [
            "",
            "/src/file.py",
            "src//file.py",
            "src/./file.py",
            "src/../file.py",
            "src/.GiT/file.py",
            "src\\file.py",
            "src/a\0b.py",
            "src/a\u{0085}b.py",
            "src/a\u{00a0}b.py",
            "src/a\u{061c}b.py",
            "src/a\u{200d}b.py",
            "src/a\u{2028}b.py",
            "src/a\u{2029}b.py",
            "src/a\u{202e}b.py",
            "src/a\u{2066}b.py",
            "src/a\u{e000}b.py",
            "src/a\u{0378}b.py",
        ] {
            assert!(!safe_path(path), "accepted {path:?}");
        }
        assert!(safe_path(&"\u{00e9}".repeat(120)));
        assert!(!safe_path(&"\u{00e9}".repeat(121)));
        assert!(safe_path(&format!("{}file.py", "dir/".repeat(15))));
        assert!(!safe_path(&format!("{}file.py", "dir/".repeat(16))));
    }

    #[test]
    fn pins_fork_and_merge_base_and_ranks_context_across_stacks() {
        let path = "ui/routing.ts";
        let mut entry = change(path);
        entry["patch"] = json!(
            "@@ -1 +1 @@\n-export function routeParcel() { return 1; }\n+export function routeParcel() { return 2; }"
        );
        let mut fixture = Fixture::new(vec![entry]);
        fixture.revision(
            REPO,
            BASE,
            &[
                (
                    path,
                    File::Text("export function routeParcel() { return 1; }\n"),
                ),
                ("backend/dispatcher.rs", File::Text("routeParcel();\n")),
            ],
        );
        fixture.revision(
            FORK,
            HEAD,
            &[
                (
                    path,
                    File::Text("export function routeParcel() { return 2; }\n"),
                ),
                (
                    "ui/adjacent.ts",
                    File::Text("export const unrelated = 3;\n"),
                ),
                ("backend/dispatcher.rs", File::Text("routeParcel();\n")),
                (
                    "ui/spec/routing.test.js",
                    File::Text("assert(routeParcel());\n"),
                ),
                (
                    "docs/contracts.md",
                    File::Text("The public interface is stable.\n"),
                ),
                ("notes/sample.txt", File::Text("Unrelated note.\n")),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert_eq!((view.base.as_str(), view.head.as_str()), (BASE, HEAD));
        assert_eq!(
            view.intent,
            [
                "Synthetic change",
                "Fixture intent",
                "Rename the synthetic value."
            ]
        );
        assert_eq!(view.files[0].path, path);
        assert!(view.files[0].before.contains("return 1"));
        assert!(view.files[0].after.contains("return 2"));
        assert_eq!(
            view.files
                .iter()
                .map(|file| file.path.as_str())
                .collect::<Vec<_>>(),
            [
                path,
                "ui/spec/routing.test.js",
                "backend/dispatcher.rs",
                "docs/contracts.md",
                "ui/adjacent.ts",
            ]
        );
        assert_eq!(view.files[2].before, view.files[2].after);
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(
            hub.transport
                .requests
                .contains(&format!("{REPO}/git/commits/{BASE}"))
        );
        assert!(
            hub.transport
                .requests
                .contains(&format!("{FORK}/git/commits/{HEAD}"))
        );
        assert!(
            !hub.transport
                .requests
                .contains(&format!("{REPO}/git/commits/{TIP}"))
        );
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn reserves_every_mixed_language_patch_before_reading_full_files() {
        let paths = ["server/task.go", "api/task.rs", "db/task.sql", "ui/task.ts"];
        let normal = "fixture\n".repeat(2_900);
        let large = "fixture\n".repeat(4_000);
        let mut entries = Vec::new();
        let mut old = Vec::new();
        let mut new = Vec::new();
        for (index, path) in paths.into_iter().enumerate() {
            let prefix = if index == paths.len() - 1 {
                &large
            } else {
                &normal
            };
            let line = prefix.lines().count() + 1;
            let mut entry = change(path);
            entry["patch"] = json!(format!("@@ -{line} +{line} @@\n-old\n+new"));
            entries.push(entry);
            old.push((path, format!("{prefix}old\n")));
            new.push((path, format!("{prefix}new\n")));
        }
        let mut fixture = Fixture::new(entries);
        fn files<'a>(versions: &'a [(&'a str, String)]) -> Vec<(&'a str, File<'a>)> {
            versions
                .iter()
                .map(|(path, text)| (*path, File::Text(text)))
                .collect()
        }
        fixture.revision(REPO, BASE, &files(&old));
        fixture.revision(FORK, HEAD, &files(&new));
        let large_blob = id(&[
            format!("blob {}\0", new[3].1.len()).as_bytes(),
            new[3].1.as_bytes(),
        ]
        .concat());
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert_eq!(view.files.len(), paths.len());
        for (file, path) in view.files.iter().zip(paths) {
            assert_eq!(file.path, path);
            assert!(file.patch.ends_with("\n-old\n+new"), "{path}");
        }
        assert_eq!(view.files[0].after, new[0].1);
        assert_eq!(view.files[3].patch, "@@ -4001 +4001 @@\n-old\n+new");
        assert!(view.files[3].after.is_empty());
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(
            view.files
                .iter()
                .map(|file| file.patch.len() + file.before.len() + file.after.len())
                .sum::<usize>()
                + view
                    .head_context
                    .iter()
                    .map(|window| window.text.len())
                    .sum::<usize>()
                <= SNAPSHOT_TEXT_BYTES
        );
        assert_eq!(
            hub.transport
                .requests
                .iter()
                .filter(|route| route.ends_with(&large_blob))
                .count(),
            1
        );
        assert!(
            view.head_context
                .iter()
                .any(|window| window.path == paths[3])
        );
    }

    #[test]
    fn collects_nonoverlapping_windows_from_sparse_large_head_and_prefers_handwritten_files() {
        let path = "src/sparse.rs";
        let generated = "generated/schema.pb.go";
        let text = (1..=3_300)
            .map(|line| format!("fixture_{line:05}"))
            .collect::<Vec<_>>()
            .join("\r\n");
        assert!(text.len() > BLOB_BYTES && text.len() < WINDOW_BLOB_BYTES);
        let mut sparse = change(path);
        sparse["patch"] = json!(
            "@@ -500 +500 @@\n-old\n+fixture_00500\r\n@@ -505 +505 @@\n-old\n+fixture_00505\r\n@@ -3300 +3300 @@\n-old\n\\ No newline at end of file\n+fixture_03300\n\\ No newline at end of file"
        );
        for field in ["additions", "deletions"] {
            sparse[field] = json!(3);
        }
        sparse["changes"] = json!(6);
        let mut generated_change = change(generated);
        generated_change["patch"] = json!("@@ -2 +2 @@\n-old\n+new");
        let mut fixture = Fixture::new(vec![generated_change, sparse]);
        fixture.revision(REPO, BASE, &[]);
        fixture.revision(
            FORK,
            HEAD,
            &[
                (generated, File::Text("first\nnew\nlast\n")),
                (path, File::Text(&text)),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(view.files[1].after.is_empty());
        assert!(view.files.iter().all(|file| !file.patch.is_empty()));
        let source: Vec<_> = text.split_inclusive('\n').collect();
        let windows = &view.head_context;
        assert_eq!(windows.len(), 3);
        assert_eq!((&*windows[0].path, windows[0].start), (path, 492));
        assert_eq!(windows[0].text, source[491..508].concat());
        assert_eq!((&*windows[1].path, windows[1].start), (path, 3292));
        assert_eq!(windows[1].text, source[3291..].concat());
        assert!(!windows[1].text.ends_with('\n'));
        assert_eq!((&*windows[2].path, windows[2].start), (generated, 1));
        assert_eq!(windows[2].text, "first\nnew\nlast\n");
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn oversized_and_corrupt_blobs_cannot_supply_head_windows() {
        let changed = ["src/oversized.rs", "src/corrupt.rs"];
        let oversized = "line\n".repeat(WINDOW_BLOB_BYTES / 5 + 1);
        let corrupt = "line\n".repeat(BLOB_BYTES / 5 + 1);
        let mut fixture = Fixture::new(changed.iter().map(|path| change(path)).collect());
        fixture.revision(REPO, BASE, &[]);
        fixture.revision(
            FORK,
            HEAD,
            &[
                (changed[0], File::Text(&oversized)),
                (changed[1], File::Text(&corrupt)),
            ],
        );
        let route = |text: &str| {
            let sha = id(&[format!("blob {}\0", text.len()).as_bytes(), text.as_bytes()].concat());
            format!("{FORK}/git/blobs/{sha}")
        };
        let corrupt_route = route(&corrupt);
        fixture.responses.get_mut(&corrupt_route).unwrap()["content"] =
            json!(STANDARD.encode(corrupt.replace("line", "fake")));
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.files.iter().all(|file| !file.patch.is_empty()));
        assert!(view.head_context.is_empty());
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(hub.transport.requests.contains(&corrupt_route));
        assert!(!hub.transport.requests.contains(&route(&oversized)));
        let old_format = serde_json::to_value(&view).unwrap();
        assert!(old_format.get("head_context").is_none());
        assert!(
            serde_json::from_value::<Snapshot>(old_format)
                .unwrap()
                .head_context
                .is_empty()
        );
    }

    #[test]
    fn reports_a_patch_that_cannot_fit_and_keeps_later_complete_patches() {
        let mut first = change("db/migration.sql");
        first["patch"] = json!(format!("@@ -1 +1 @@\n-old\n+{}", "a".repeat(60_000)));
        let mut omitted = change("server/routes.go");
        omitted["patch"] = json!(format!("@@ -1 +1 @@\n-old\n+{}", "b".repeat(50_000)));
        let mut entries = vec![first, omitted];
        entries.extend((0..25).map(|index| change(&format!("ui/view_{index}.ts"))));
        let mut fixture = Fixture::new(entries);
        fixture.revision(REPO, BASE, &[]);
        fixture.revision(FORK, HEAD, &[]);
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert_eq!(view.files.len(), 26);
        assert!(view.files[0].patch.len() > 60_000);
        assert_eq!(view.files[25].path, "ui/view_24.ts");
        assert!(view.files.iter().all(|file| !file.patch.is_empty()));
        assert_eq!(
            view.limits,
            ["Patch for server/routes.go exceeds the remaining review text limit."]
        );
        assert!(
            view.files
                .iter()
                .map(|file| file.patch.len())
                .sum::<usize>()
                <= SNAPSHOT_TEXT_BYTES
        );
    }

    #[test]
    fn validates_complete_hunks_and_comparison_counts() {
        let complete = "@@ -2,2 +2,2 @@\n same\n-old\n+new\n@@ -9 +9 @@\n-last old\n\\ No newline at end of file\n+last new\n\\ No newline at end of file";
        let mut entry = change("source.rs");
        entry["patch"] = json!(complete);
        entry["additions"] = json!(2);
        entry["deletions"] = json!(2);
        entry["changes"] = json!(4);
        let change: Change = serde_json::from_value(entry.clone()).unwrap();
        assert_eq!(change.complete_patch(), Some(complete));

        let mut missing_count = entry.clone();
        missing_count["additions"] = Value::Null;
        let mut mismatched_total = entry.clone();
        mismatched_total["changes"] = json!(5);
        entry["patch"] = json!(complete.replace(" same\n", ""));
        for invalid in [missing_count, mismatched_total, entry] {
            let change: Change = serde_json::from_value(invalid).unwrap();
            assert!(change.complete_patch().is_none());
        }
    }

    #[test]
    fn fallback_stops_when_the_only_missing_path_was_seen_without_a_patch() {
        let mut file = change("image.bin");
        file["patch"] = Value::Null;
        file["sha"] = json!(HEAD);
        let changes: Vec<Change> = vec![serde_json::from_value(file.clone()).unwrap()];
        let mut page = vec![file];
        page.extend((1..30).map(|n| change(&format!("other-{n}"))));
        let mut fixture = Fixture::default();
        fixture.responses.insert(pull_files_page(1), json!(page));
        let mut hub = GitHub::new(fixture);
        assert!(pull_files::candidates(&mut hub, PULL, 300, &changes).is_empty());
        assert_eq!(hub.transport.requests, [pull_files_page(1)]);
    }

    #[test]
    fn recovers_missing_and_invalid_patches_across_pinned_pull_file_pages() {
        let edited = "service/handler.rs";
        let added = "web/entry.ts";
        let before = "kept\r\nold";
        let after = "kept\r\nnew";
        let mut edited_file = change(edited);
        edited_file["sha"] = json!(blob_id(after.as_bytes()));
        edited_file["patch"] = json!(
            "@@ -1,2 +1,2 @@\n kept\r\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file"
        );
        let mut invalid = edited_file.clone();
        invalid["patch"] = json!("@@ -1,2 +1,2 @@\n-old\n+new");
        let added_file = json!({
            "filename": added, "status": "added", "sha": blob_id(b"entry\n"),
            "additions": 1, "deletions": 0, "changes": 1, "patch": "@@ -0,0 +1 @@\n+entry",
        });
        let mut omitted = added_file.clone();
        omitted["patch"] = Value::Null;
        omitted["additions"] = json!(0);
        omitted["changes"] = json!(0);
        let mut first_page: Vec<_> = (0..29)
            .map(|index| change(&format!("docs/sample_{index}.md")))
            .collect();
        let mut comparisons = first_page.clone();
        comparisons.extend([invalid, omitted]);
        let mut fixture = Fixture::new(comparisons);
        first_page.push(edited_file.clone());
        fixture
            .responses
            .insert(pull_files_page(1), json!(first_page));
        fixture
            .responses
            .insert(pull_files_page(2), json!([added_file.clone()]));
        fixture.revision(REPO, BASE, &[(edited, File::Text(before))]);
        fixture.revision(
            FORK,
            HEAD,
            &[(edited, File::Text(after)), (added, File::Text("entry\n"))],
        );
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        for (path, expected) in [(edited, edited_file), (added, added_file)] {
            let expected = expected["patch"].as_str().unwrap();
            assert_eq!(
                view.files
                    .iter()
                    .find(|file| file.path == path)
                    .unwrap()
                    .patch,
                expected
            );
            let diff = view.diff.as_ref().unwrap();
            assert_eq!(
                diff.files
                    .iter()
                    .find(|file| file.path == path)
                    .unwrap()
                    .patch
                    .as_deref(),
                Some(expected)
            );
        }
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(hub.transport.requests.starts_with(&[
            PULL.to_owned(),
            comparison(1),
            pull_files_page(1),
            pull_files_page(2),
        ]));
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn rejects_pull_file_metadata_and_patch_text_from_a_different_revision() {
        let path = "app/file.txt";
        let previous = "app/old.txt";
        let mut file = change(path);
        file["status"] = json!("renamed");
        file["previous_filename"] = json!(previous);
        file["sha"] = json!(blob_id(b"new\n"));
        let mut missing = file.clone();
        missing["patch"] = Value::Null;

        for (field, changed) in [
            ("sha", json!(MOVED)),
            ("status", json!("modified")),
            ("previous_filename", json!("app/elsewhere.txt")),
            ("patch", json!("@@ -1 +1 @@\n-wrong base\n+new")),
            ("patch", json!("@@ -1 +1 @@\n-old\n+wrong head")),
        ] {
            let mut candidate = file.clone();
            candidate[field] = changed;
            let mut fixture = Fixture::new(vec![missing.clone()]);
            fixture.responses.insert(
                pull_files_page(1),
                json!([candidate, change("unlisted.rs")]),
            );
            fixture.revision(REPO, BASE, &[(previous, File::Text("old\n"))]);
            fixture.revision(FORK, HEAD, &[(path, File::Text("new\n"))]);
            let mut hub = GitHub::new(fixture);
            let view = snapshot(&mut hub).unwrap();
            assert_eq!(view.files.len(), 1, "{field}");
            assert!(view.files[0].patch.is_empty(), "{field}");
            assert_eq!(
                view.limits,
                [format!("Patch is missing or incomplete for {path}.")]
            );
            assert_eq!(hub.transport.requests.last().unwrap(), PULL);
        }
    }

    #[test]
    fn rejects_a_complete_pull_file_patch_when_comparison_counts_disagree() {
        let path = "app/file.txt";
        let mut file = change(path);
        file["sha"] = json!(blob_id(b"new\n"));
        let mut missing = file.clone();
        missing["patch"] = Value::Null;
        missing["additions"] = json!(2);
        missing["changes"] = json!(3);
        let mut fixture = Fixture::new(vec![missing]);
        fixture.responses.insert(pull_files_page(1), json!([file]));
        fixture.revision(REPO, BASE, &[(path, File::Text("old\n"))]);
        fixture.revision(FORK, HEAD, &[(path, File::Text("new\n"))]);
        let view = snapshot(&mut GitHub::new(fixture)).unwrap();
        assert!(view.files[0].patch.is_empty());
        assert_eq!(
            view.limits,
            [format!("Patch is missing or incomplete for {path}.")]
        );
    }

    #[test]
    fn pull_file_fallback_reserves_the_final_metadata_request() {
        let path = "script.sh";
        let mut file = change(path);
        file["sha"] = json!(blob_id(b"new\n"));
        let mut missing = file.clone();
        missing["patch"] = Value::Null;
        let mut fixture = Fixture::new(vec![missing]);
        fixture.responses.insert(pull_files_page(1), json!([file]));
        fixture.revision(REPO, BASE, &[(path, File::Text("old\n"))]);
        fixture.revision(FORK, HEAD, &[(path, File::Text("new\n"))]);
        let mut hub = GitHub::new(fixture);
        hub.requests = 4;
        let view = snapshot(&mut hub).unwrap();
        assert!(view.files[0].patch.is_empty());
        assert_eq!(
            hub.transport.requests,
            [
                PULL.to_owned(),
                comparison(1),
                pull_files_page(1),
                PULL.to_owned()
            ]
        );
    }

    #[test]
    fn discards_pull_file_fallback_if_either_pr_revision_moves() {
        let path = "feature.rb";
        let mut file = change(path);
        file["sha"] = json!(blob_id(b"new\n"));
        let mut missing = file.clone();
        missing["patch"] = Value::Null;
        for revision in ["base", "head"] {
            let mut fixture = Fixture::new(vec![missing.clone()]);
            fixture
                .responses
                .insert(pull_files_page(1), json!([file.clone()]));
            fixture.revision(REPO, BASE, &[(path, File::Text("old\n"))]);
            fixture.revision(FORK, HEAD, &[(path, File::Text("new\n"))]);
            fixture.pulls[1][revision]["sha"] = json!(MOVED);
            let mut hub = GitHub::new(fixture);
            let error = snapshot(&mut hub).unwrap_err();
            assert!(error.to_string().contains("changed during collection"));
            assert_eq!(error.is::<HeadChanged>(), revision == "head");
            assert!(hub.transport.requests.contains(&pull_files_page(1)));
            assert_eq!(hub.transport.requests.last().unwrap(), PULL);
        }
    }

    #[test]
    fn intent_keeps_core_files_ahead_of_tests_and_localization_under_budget() {
        let paths = [
            "tests/payment/settlement.test.js",
            "locales/settlement.json",
            "docs/settlement.md",
            "src/unrelated.rb",
            "server/payment/SettlementHandler.kt",
        ];
        let mut fixture = Fixture::new(paths.map(|path| large_change(path, 55_000)).to_vec());
        for pull in &mut fixture.pulls {
            pull["title"] = json!("Fix payment settlement after retry");
        }
        let view = snapshot(&mut GitHub::new(fixture)).unwrap();
        assert_eq!(view.files.len(), 1);
        assert_eq!(view.files[0].path, paths[4]);
        assert_eq!(view.limits.len(), 4);
    }

    fn large_change(path: &str, bytes: usize) -> Value {
        let mut file = change(path);
        file["patch"] = json!(format!("@@ -1 +1 @@\n-old\n+{}", "x".repeat(bytes)));
        file
    }

    #[test]
    fn prioritizes_fast_forward_and_previous_finding_paths_without_changing_review_base() {
        let unchanged = "app/first.go";
        let pushed = "app/second.py";
        let prior = "app/finding.java";
        let prior_name = "legacy/finding.java";
        let route = format!("{FORK}/compare/{MOVED}...{HEAD}?per_page=1&page=1");
        let mut renamed = large_change(prior, 41_000);
        renamed["status"] = json!("renamed");
        renamed["previous_filename"] = json!(prior_name);
        let paths = [prior_name.to_owned()];

        for (status, behind_by, merge_base, expected) in [
            ("ahead", 0, MOVED, [pushed, prior]),
            ("diverged", 1, BASE, [prior, unchanged]),
            ("ahead", 0, BASE, [prior, unchanged]),
        ] {
            let mut fixture = Fixture::new(vec![
                large_change(unchanged, 51_000),
                large_change(pushed, 51_000),
                renamed.clone(),
            ]);
            let mut delta = change(pushed);
            delta["patch"] = json!("@@ -1 +1 @@\n-last push\n+new push");
            fixture.responses.insert(
                route.clone(),
                json!({
                    "status": status, "behind_by": behind_by,
                    "base_commit": {"sha": MOVED}, "merge_base_commit": {"sha": merge_base},
                    "files": [delta],
                }),
            );
            let mut hub = GitHub::new(fixture);
            let view = snapshot_since(&mut hub, Some(MOVED), &paths).unwrap();
            assert_eq!((view.base.as_str(), view.head.as_str()), (BASE, HEAD));
            assert_eq!(
                view.files
                    .iter()
                    .map(|file| file.path.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
            assert!(
                view.files
                    .iter()
                    .all(|file| !file.patch.contains("last push"))
            );
            assert!(hub.transport.requests.contains(&route));
        }
    }

    #[test]
    fn skips_the_incremental_request_without_a_distinct_valid_previous_head() {
        for previous in [None, Some(HEAD), Some("invalid/ref")] {
            let mut hub = GitHub::new(Fixture::new(vec![change("app.rs")]));
            snapshot_since(&mut hub, previous, &[]).unwrap();
            assert_eq!(
                hub.transport
                    .requests
                    .iter()
                    .filter(|route| route.contains("/compare/"))
                    .count(),
                1
            );
        }
    }

    #[test]
    fn reports_mode_only_changes_without_charging_a_regular_patch() {
        let mode_only = json!({
            "filename": "script.sh", "status": "modified", "changes": 0,
            "additions": 0, "deletions": 0,
        });
        let mut fixture = Fixture::new(vec![mode_only, change("other.rs")]);
        fixture.revision(
            REPO,
            BASE,
            &[
                ("script.sh", File::Text("exit 0\n")),
                ("other.rs", File::Text("old\n")),
            ],
        );
        fixture.revision(
            FORK,
            HEAD,
            &[
                ("script.sh", File::Executable("exit 0\n")),
                ("other.rs", File::Text("new\n")),
            ],
        );
        let view = snapshot(&mut GitHub::new(fixture)).unwrap();
        assert_eq!(
            view.limits,
            ["Git file mode change for script.sh (100644 to 100755) was not reviewed."]
        );
        assert!(view.files[0].patch.is_empty());
        assert_eq!(view.files[1].patch, "@@ -1 +1 @@\n-old\n+new");
    }

    #[test]
    fn excludes_gitlink_and_symlink_pointers_and_preserves_the_same_regular_text() {
        let old_pointer = format!("Subproject commit {BASE}");
        let new_pointer = format!("Subproject commit {HEAD}");
        let pointer_patch = format!("@@ -1 +1 @@\n-{old_pointer}\n+{new_pointer}");
        let mut entries = ["vendor/module", "example.txt", "external.py"].map(change);
        entries[0]["patch"] = json!(&pointer_patch);
        entries[1]["patch"] = json!(&pointer_patch);
        let mut fixture = Fixture::new(entries.to_vec());
        fixture.revision(
            REPO,
            BASE,
            &[
                ("vendor/module", File::Gitlink(BASE)),
                ("example.txt", File::Text(&old_pointer)),
                ("external.py", File::Symlink),
            ],
        );
        fixture.revision(
            FORK,
            HEAD,
            &[
                ("vendor/module", File::Gitlink(HEAD)),
                ("example.txt", File::Text(&new_pointer)),
                ("external.py", File::Symlink),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert_eq!(
            view.limits,
            [
                "Submodule change for vendor/module was not reviewed.",
                "Symbolic link change for external.py was not reviewed.",
            ]
        );
        let citable: Vec<_> = view
            .files
            .iter()
            .filter(|file| !file.patch.is_empty())
            .collect();
        assert_eq!(citable.len(), 1);
        assert_eq!(citable[0].path, "example.txt");
        assert_eq!(citable[0].patch, pointer_patch);
        assert!(
            view.files
                .iter()
                .filter(|file| file.path != "example.txt")
                .all(|file| file.before.is_empty() && file.after.is_empty())
        );
        assert!(
            view.head_context
                .iter()
                .all(|window| window.path == "example.txt")
        );
        assert!(hub.transport.requests.iter().all(|route| {
            ![BASE, HEAD, MOVED]
                .iter()
                .any(|sha| route.ends_with(&format!("/git/blobs/{sha}")))
        }));
    }

    #[test]
    fn withholds_an_unverified_submodule_pointer_when_only_the_final_request_remains() {
        let mut pointer = change("vendor/module");
        pointer["patch"] = json!(format!(
            "@@ -1 +1 @@\n-Subproject commit {BASE}\n+Subproject commit {HEAD}"
        ));
        let mut hub = GitHub::new(Fixture::new(vec![pointer, change("keep.rs")]));
        hub.requests = 4;
        let view = snapshot(&mut hub).unwrap();
        assert_eq!(view.files.len(), 1);
        assert_eq!(view.files[0].path, "keep.rs");
        assert!(!view.files[0].patch.is_empty());
        assert_eq!(
            view.limits,
            ["Could not verify the Git entry type for vendor/module. Its patch was excluded.",]
        );
        assert_eq!(hub.transport.requests.len(), 4);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn finds_edited_local_imports_above_a_large_hunk_when_recursive_inventory_is_oversized() {
        let importer = "apps/client/src/features/panel.ts";
        let metric = "apps/client/src/tools/metric.ts";
        let formatter = "apps/client/src/formatters/key/index.ts";
        let unused = "apps/client/src/tools/unused.ts";
        let metric_text = "export function measure(value: string) { return value.length; }\n";
        let formatter_text =
            "export function encodeToken(value: string) { return value.trim(); }\n";
        let imports = "import {\n  measure as measureLabel,\n} from '@/tools/metric';\nimport { encodeToken } from '../formatters/key';\nimport { other } from '@/tools/unused';\n";
        let edit = "const displayed = measureLabel(encodeToken(input));";
        let head_text = format!("{imports}{}{edit}\n", "// Fixture padding.\n".repeat(2_000));
        assert!(head_text.len() > BLOB_BYTES);
        let line = head_text.lines().count();
        let mut change = change(importer);
        change["patch"] = json!(format!(
            "@@ -{line} +{line} @@\n-const displayed = 0;\n+{edit}"
        ));
        let mut fixture = Fixture::new(vec![change]);
        let dependencies = [
            (metric, File::Text(metric_text)),
            (formatter, File::Text(formatter_text)),
        ];
        fixture.revision(REPO, BASE, &dependencies);
        let mut head_files = Vec::from(dependencies);
        head_files.extend([
            ("apps/client/package.json", File::Text("{}")),
            (importer, File::Text(&head_text)),
            (unused, File::Text("export const other = 0;\n")),
            (
                "src/tools/metric.ts",
                File::Text("export const unrelated = 0;\n"),
            ),
        ]);
        let root = fixture.revision(FORK, HEAD, &head_files);
        let inventory = format!("{FORK}/git/trees/{root}?recursive=1");
        let inventory_cap = 700_000;
        fixture.responses.get_mut(&inventory).unwrap()["padding"] =
            json!("x".repeat(inventory_cap));
        let mut hub = GitHub::new(fixture);
        hub.inventory_remaining = inventory_cap;

        let view = snapshot(&mut hub).unwrap();
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert_eq!(view.files[0].path, importer);
        assert!(view.files[0].after.is_empty());
        assert!(!view.files[0].patch.is_empty());
        assert_eq!(
            (&*view.files[1].path, &*view.files[1].after),
            (metric, metric_text)
        );
        assert_eq!(
            (&*view.files[2].path, &*view.files[2].after),
            (formatter, formatter_text)
        );
        assert!(
            view.files[1..3]
                .iter()
                .all(|file| file.patch.is_empty() && file.before == file.after)
        );
        assert!(
            !view
                .files
                .iter()
                .any(|file| [unused, "src/tools/metric.ts"].contains(&file.path.as_str()))
        );
        assert!(hub.transport.requests.contains(&inventory));
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn renamed_removed_added_and_unsafe_sources() {
        let mut fixture = Fixture::new(vec![
            json!({"filename": "new.proto", "status": "renamed", "previous_filename": "old.proto", "changes": 0}),
            json!({"filename": "gone.rs", "status": "removed", "changes": 1, "patch": "@@ -1 +0,0 @@\n-old", "additions": 0, "deletions": 1}),
            json!({"filename": "Makefile", "status": "added", "changes": 1, "patch": "@@ -0,0 +1 @@\n+new", "additions": 1, "deletions": 0}),
            change("../outside"),
            change("/absolute"),
            change("dir\\escape"),
            change("dir/.GiT/config"),
            change("new.proto"),
            json!({"filename": "binary.dat", "status": "modified", "changes": 0, "additions": 0, "deletions": 0}),
            change("link.py"),
        ]);
        fixture.revision(
            REPO,
            BASE,
            &[
                ("old.proto", File::Text("same\n")),
                ("gone.rs", File::Text("old\n")),
                ("binary.dat", File::Bytes(&[255])),
            ],
        );
        fixture.revision(
            FORK,
            HEAD,
            &[
                ("new.proto", File::Text("same\n")),
                ("Makefile", File::Text("new\n")),
                ("binary.dat", File::Bytes(&[0])),
                ("link.py", File::Symlink),
            ],
        );
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert_eq!(
            view.files
                .iter()
                .map(|file| file.path.as_str())
                .collect::<Vec<_>>(),
            ["new.proto", "gone.rs", "Makefile", "binary.dat", "link.py"]
        );
        assert_eq!(view.files[0].before, "same\n");
        assert_eq!(view.files[0].after, "same\n");
        assert_eq!(view.files[1].after, "");
        assert_eq!(view.files[2].before, "");
        assert_eq!(view.files[2].after, "new\n");
        assert_eq!(view.files[3].after, "");
        assert!(view.files[3].patch.is_empty());
        assert!(view.files[4].after.is_empty());
        assert!(view.files[4].patch.is_empty());
        assert!(
            view.limits
                .iter()
                .any(|limit| limit.contains("duplicate paths"))
        );
        assert!(view.limits.iter().any(|limit| limit.contains("binary.dat")));
        assert!(
            view.limits
                .iter()
                .any(|limit| limit.contains("Symbolic link change for link.py"))
        );
        assert!(!view.limits.iter().any(|limit| limit.contains("new.proto")));
        assert!(
            hub.transport
                .requests
                .iter()
                .all(|route| !route.ends_with(MOVED))
        );
    }

    #[test]
    fn detects_a_moved_pr_after_file_reads_and_rejects_private_forks() {
        let mut fixture = Fixture::new(vec![change("source.rs")]);
        fixture.revision(REPO, BASE, &[("source.rs", File::Text("old\n"))]);
        fixture.revision(FORK, HEAD, &[("source.rs", File::Text("new\n"))]);
        fixture.pulls[1] = pull(MOVED, 1);
        let mut hub = GitHub::new(fixture);
        assert!(
            snapshot(&mut hub)
                .unwrap_err()
                .to_string()
                .contains("changed during collection")
        );
        assert!(
            hub.transport
                .requests
                .iter()
                .any(|route| route.contains("/git/blobs/"))
        );
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);

        let mut fixture = Fixture::new(vec![change("source.rs")]);
        fixture.pulls[0]["head"]["repo"]["private"] = json!(true);
        let mut hub = GitHub::new(fixture);
        assert!(snapshot(&mut hub).is_err());
        assert_eq!(hub.transport.requests, [PULL]);
    }

    #[test]
    fn accepts_private_revisions_only_for_approved_repositories() {
        let allowed = HashSet::from([REPO.to_owned(), FORK.to_ascii_uppercase()]);
        for head in [REPO, FORK] {
            let mut data = pull(HEAD, 1);
            data["base"]["repo"]["private"] = json!(true);
            data["head"]["repo"] = json!({"full_name": head, "private":true});
            let mut pr: Pull = serde_json::from_value(data).unwrap();
            pr.validate(REPO, 3, &allowed).unwrap();
            assert!(pr.validate(REPO, 3, &HashSet::new()).is_err());
        }
    }

    #[test]
    fn paginates_pinned_commits_and_reports_truncation() {
        let mut fixture = Fixture::new(vec![change("source.rs")]);
        fixture.pulls = VecDeque::from([pull(HEAD, 301), pull(HEAD, 301)]);
        for page in 1..=COMMIT_PAGES {
            fixture.page(
                page,
                (page == 1).then(|| vec![change("source.rs")]),
                65,
                &[["first", "second", "third"][page - 1]; COMMITS_PER_PAGE],
            );
        }
        fixture.revision(REPO, BASE, &[("source.rs", File::Text("old\n"))]);
        fixture.revision(FORK, HEAD, &[("source.rs", File::Text("new\n"))]);
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.intent.iter().any(|message| message == "third"));
        assert!(view.limits.iter().any(|limit| limit.contains("60 of 65")));
        assert!(view.limits.iter().any(|limit| limit.contains("1 of 301")));
        assert!(hub.transport.requests.contains(&comparison(3)));
        assert!(!hub.transport.requests.contains(&comparison(4)));
    }

    #[test]
    fn rejects_inconsistent_patch_and_ignores_a_bad_optional_blob() {
        let mut incomplete = change("incomplete.rs");
        incomplete["patch"] = json!("@@ -1,2 +1,2 @@\n-old\n+new");
        let mut missing = change("missing.ts");
        missing["patch"] = Value::Null;
        missing["changes"] = Value::Null;
        let mut fixture = Fixture::new(vec![incomplete, missing, change("source.rs")]);
        fixture.revision(REPO, BASE, &[("source.rs", File::Text("old\n"))]);
        fixture.revision(FORK, HEAD, &[("source.rs", File::Text("new\n"))]);
        let route = fixture
            .responses
            .keys()
            .find(|route| route.starts_with(&format!("{FORK}/git/blobs/")))
            .unwrap()
            .clone();
        fixture.responses.get_mut(&route).unwrap()["content"] = json!(STANDARD.encode(b"bad\n"));
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.files[0].patch.is_empty());
        assert!(view.files[1].patch.is_empty());
        assert_eq!(view.files[2].patch, "@@ -1 +1 @@\n-old\n+new");
        assert!(view.files[2].after.is_empty());
        assert!(hub.transport.requests.contains(&route));
        assert_eq!(
            view.limits,
            [
                "Patch is missing or incomplete for incomplete.rs.",
                "Patch is missing or incomplete for missing.ts.",
            ]
        );
    }

    #[test]
    fn preserves_exact_cross_package_writers_in_a_large_monorepo() {
        let paths = [
            "apps/console/src/views/config-delivery-window.form.ts",
            "apps/console/src/views/calendar.ts",
            "apps/console/src/views/filter.ts",
            "apps/console/src/views/timeline.ts",
        ];
        let resource = "packages/office-api/src/resources/config-delivery-window.resource.ts";
        let actions = "packages/office-api/src/actions/config-delivery-window.actions.ts";
        let writer = "packages/storage/src/config-delivery-window.writer.ts";
        let weak = "packages/analytics/src/delivery-window.controller.ts";
        let guidance = "packages/office-api/AGENTS.md";
        let edit = "const duration = editWindow;";
        let changed_text = format!(
            "{edit}\n{}",
            "// Synthetic supporting source.\n".repeat(710)
        );
        let reference = format!("{}\nconst duration = editWindow;\n", paths[0]);
        let weak_text = reference.repeat(85);
        let guidance_text = format!("{weak_text}{}", "Read this guide.\n".repeat(120));
        assert!(guidance_text.len() > 8_000);
        let support_padding = "// Synthetic package source.\n".repeat(140);
        let resource_text = format!("export const storesEdits = true;\n{support_padding}");
        let action_text = format!("export const appliesEdits = true;\n{support_padding}");
        let writer_text = format!("export const persistsEdits = true;\n{support_padding}");
        let locale = format!("{{\"label\":\"{}\"}}\n", "l".repeat(16_740));
        let mut fixture = Fixture::new(
            paths
                .iter()
                .map(|path| {
                    let mut entry = change(path);
                    entry["patch"] = json!(format!(
                        "@@ -1 +1 @@\n-const duration = defaultWindow;\n+{edit}"
                    ));
                    entry
                })
                .collect(),
        );
        for pull in &mut fixture.pulls {
            pull["title"] = json!("Keep resource settings when admins edit the delivery window");
        }
        fixture.revision(REPO, BASE, &[]);
        let mut head_files: Vec<_> = paths
            .iter()
            .map(|path| (*path, File::Text(&changed_text)))
            .collect();
        head_files.extend([
            (resource, File::Text(&resource_text)),
            (actions, File::Text(&action_text)),
            (writer, File::Text(&writer_text)),
            (weak, File::Text(&weak_text)),
            (guidance, File::Text(&guidance_text)),
            (
                "apps/console/src/views/config-delivery-window.controller.ts",
                File::Text(&weak_text),
            ),
            (
                "apps/console/src/views/locales/en.json",
                File::Text(&locale),
            ),
            (
                "apps/console/src/views/locales/fr.json",
                File::Text(&locale),
            ),
            (
                "packages/office-api/generated/config-delivery-window.spec.ts",
                File::Text(&weak_text),
            ),
        ]);
        let root = fixture.revision(FORK, HEAD, &head_files);
        let inventory_route = format!("{FORK}/git/trees/{root}?recursive=1");
        let inventory = fixture.responses.get_mut(&inventory_route).unwrap();
        let tree = inventory["tree"].as_array_mut().unwrap();
        let filler = "component-segment-".repeat(7);
        let blob_url = format!("https://api.github.com/repos/{FORK}/git/blobs/{MOVED}");
        for index in 0..28_000 {
            tree.push(json!({
                "path": format!("packages/archive/generated/{filler}/{index:05}.ts"),
                "mode": "100644", "type": "blob", "sha": MOVED, "size": 50, "url": blob_url,
            }));
        }
        let inventory_bytes = serde_json::to_vec(inventory).unwrap().len();
        assert!(
            (8_000_000..INVENTORY_BYTES).contains(&inventory_bytes),
            "{inventory_bytes}"
        );

        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(
            view.files[..paths.len()]
                .iter()
                .all(|file| !file.patch.is_empty())
        );
        assert!(
            view.files[..paths.len()]
                .iter()
                .any(|file| file.after.is_empty())
        );
        let supporting = &view.files[paths.len()..];
        let strongest: HashMap<_, _> = supporting
            .iter()
            .take(3)
            .map(|file| (file.path.as_str(), file.after.as_str()))
            .collect();
        assert_eq!(
            strongest,
            HashMap::from([
                (resource, resource_text.as_str()),
                (writer, writer_text.as_str()),
                (actions, action_text.as_str()),
            ])
        );
        assert_eq!(supporting[1].path, writer);
        assert_eq!(supporting[1].after, writer_text);
        assert!(
            !supporting
                .iter()
                .any(|file| file.path == guidance || file.path.contains("/locales/"))
        );
        assert_eq!(hub.inventory_remaining, INVENTORY_BYTES - inventory_bytes);
        assert!(hub.remaining > DOWNLOAD / 2);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
        let source_bytes = view
            .files
            .iter()
            .map(|file| file.patch.len() + file.before.len() + file.after.len())
            .sum::<usize>()
            + view
                .head_context
                .iter()
                .map(|window| window.text.len())
                .sum::<usize>();
        assert!(source_bytes <= SNAPSHOT_TEXT_BYTES);
    }

    #[test]
    fn preserves_final_request_budget_when_optional_context_is_unavailable() {
        let mut hub = GitHub::new(Fixture::new(vec![change("source.rs")]));
        hub.requests = 4;
        let view = snapshot(&mut hub).unwrap();
        assert!(!view.files[0].patch.is_empty());
        assert!(view.limits.is_empty());
        assert_eq!(hub.transport.requests.len(), 4);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn bounds_responses_and_uses_partial_inventory_as_optional_context() {
        let mut fixture = Fixture::new(vec![change("source.rs")]);
        fixture.revision(REPO, BASE, &[("source.rs", File::Text("old\n"))]);
        let head = fixture.revision(
            FORK,
            HEAD,
            &[
                ("source.rs", File::Text("new\n")),
                ("README.md", File::Text("contract")),
            ],
        );
        fixture
            .responses
            .get_mut(&format!("{FORK}/git/trees/{head}?recursive=1"))
            .unwrap()["truncated"] = json!(true);
        let mut hub = GitHub::new(fixture);
        let view = snapshot(&mut hub).unwrap();
        assert!(view.limits.is_empty(), "{:?}", view.limits);
        assert!(view.files.iter().any(|file| file.path == "README.md"));
        let remaining = hub.remaining;
        assert!(hub.get::<Pull>(PULL, 10, false).is_err());
        // A present, oversized response is read only one byte past the cap.
        assert!(hub.get::<Value>(&comparison(1), 10, false).is_err());
        assert_eq!(hub.remaining, remaining - 11);
    }

    #[test]
    fn classifies_rate_limits_and_propagates_through_final_check() {
        let zero = HeaderValue::from_static("0");
        let one = HeaderValue::from_static("1");
        for (status, remaining, limited) in [
            (StatusCode::TOO_MANY_REQUESTS, None, true),
            (StatusCode::FORBIDDEN, Some(&zero), true),
            (StatusCode::FORBIDDEN, Some(&one), false),
            (StatusCode::FORBIDDEN, None, false),
            (StatusCode::NOT_FOUND, Some(&zero), false),
        ] {
            assert_eq!(
                validate_status(status, remaining)
                    .unwrap_err()
                    .is::<GitHubRateLimit>(),
                limited
            );
        }
        assert!(validate_status(StatusCode::OK, Some(&zero)).is_ok());

        let mut fixture = Fixture::new(vec![change("source.rs")]);
        fixture.revision(REPO, BASE, &[("source.rs", File::Text("old\n"))]);
        let root = fixture.revision(FORK, HEAD, &[("source.rs", File::Text("new\n"))]);
        for route in [
            PULL.to_owned(),
            format!("{FORK}/git/trees/{root}?recursive=1"),
        ] {
            fixture.quota_on = Some(route.clone());
            let mut hub = GitHub::new(std::mem::take(&mut fixture));
            assert!(snapshot(&mut hub).unwrap_err().is::<GitHubRateLimit>());
            assert_eq!(hub.transport.requests.last(), Some(&route));
            fixture = hub.transport;
            fixture.requests.clear();
            fixture.pulls = VecDeque::from([pull(HEAD, 1), pull(HEAD, 1)]);
        }
    }
}
