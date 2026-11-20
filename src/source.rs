//! Collect a pinned, bounded snapshot without cloning or executing repository code.

use crate::contracts::{GitHubRateLimit, Snapshot, SourceFile};
use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use reqwest::{StatusCode, blocking::Client, header::HeaderValue, redirect::Policy};
use serde::{Deserialize, de::DeserializeOwned};
use sha1::{Digest, Sha1};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    io::Read,
    time::{Duration, Instant},
};

const REQUESTS: usize = 48;
const DOWNLOAD: usize = 6_000_000;
const RESPONSE: usize = 2_000_000;
const PULL_BYTES: usize = 128_000;
const DEADLINE: Duration = Duration::from_secs(30);
const REQUEST_TIME: Duration = Duration::from_secs(5);
const COMMITS_PER_PAGE: usize = 20;
const COMMIT_PAGES: usize = 3;
const CHANGED_FILES: usize = 20;
const CONTEXT_FILES: usize = 8;
const CONTEXT_PROBES: usize = 12;
const WIDER_PROBES: usize = 3;
const INVENTORY_BYTES: usize = 700_000;
const INTENT_BYTES: usize = 8_000;
const BLOB_BYTES: usize = 24_000;
const PATCH_BYTES: usize = 16_000;
const SOURCE_BYTES: usize = 96_000;

fn valid_repo(repo: &str) -> bool {
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
    let (repo, number) = parse(url).context("Serve un URL HTTPS di una pull request GitHub.")?;
    ensure!(
        allowed.iter().any(|name| name.eq_ignore_ascii_case(&repo)),
        "Il repository non è nell'elenco autorizzato."
    );
    Ok((repo, number))
}

pub(crate) fn safe_path(path: &str) -> bool {
    path.len() <= 240
        && !path.contains('\\')
        && !path.chars().any(|c| {
            c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        && path.split('/').count() <= 16
        && path
            .split('/')
            .all(|part| !matches!(part, "" | "." | "..") && !part.eq_ignore_ascii_case(".git"))
}

fn sha(sha: &str) -> Result<&str> {
    ensure!(
        sha.len() == 40
            && sha
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
        "Identificativo Git non valido."
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
        "GitHub non ha restituito i dati richiesti."
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
            .map_err(|_| anyhow!("Richiesta a GitHub non riuscita."))?;
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
    rate_limited: bool,
    blobs: HashMap<String, (usize, Option<String>)>,
}

impl<T: Transport> GitHub<T> {
    fn new(transport: T) -> Self {
        Self {
            transport,
            deadline: Instant::now() + DEADLINE,
            requests: REQUESTS,
            remaining: DOWNLOAD,
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
        if self.rate_limited {
            return Err(GitHubRateLimit.into());
        }
        // Reserve one request, its bytes, and time for the last PR metadata check.
        let reserve = usize::from(!final_check);
        let budget = cap.min(self.remaining.saturating_sub(reserve * PULL_BYTES));
        let timeout = self
            .deadline
            .saturating_duration_since(Instant::now())
            .saturating_sub(if final_check {
                Duration::ZERO
            } else {
                REQUEST_TIME
            })
            .min(REQUEST_TIME);
        ensure!(
            self.requests > reserve && budget > 0 && !timeout.is_zero(),
            "Limite GitHub raggiunto."
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
        self.remaining = self.remaining.saturating_sub(bytes.len());
        ensure!(
            read.is_ok() && bytes.len() <= budget,
            "Risposta GitHub incompleta o troppo grande."
        );
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Dati GitHub non validi."))
    }

    fn blob(&mut self, repo: &str, id: &str, size: usize) -> Result<Option<String>> {
        sha(id)?;
        ensure!(size <= BLOB_BYTES, "File troppo grande.");
        if let Some((known_size, text)) = self.blobs.get(id) {
            ensure!(*known_size == size, "Dimensione Git incoerente.");
            return Ok(text.clone());
        }
        let blob: GitBlob = self.get(&format!("{repo}/git/blobs/{id}"), 40_000, false)?;
        ensure!(blob.encoding == "base64", "Codifica Git non supportata.");
        let bytes = STANDARD.decode(blob.content.replace(['\n', '\r'], ""))?;
        ensure!(bytes.len() == size, "Dimensione Git incoerente.");
        let mut hash = Sha1::new();
        hash.update(format!("blob {size}\0"));
        hash.update(&bytes);
        ensure!(
            hex::encode(hash.finalize()) == id,
            "Contenuto Git incoerente."
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

#[derive(Deserialize, PartialEq, Eq)]
struct Revision {
    sha: String,
    repo: Repo,
}

impl Revision {
    fn validate(&mut self) -> Result<()> {
        sha(&self.sha)?;
        ensure!(
            !self.repo.private && valid_repo(&self.repo.full_name),
            "Il repository deve essere pubblico."
        );
        self.repo.full_name.make_ascii_lowercase();
        Ok(())
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
    fn validate(&mut self, repo: &str, number: u64) -> Result<()> {
        self.base.validate()?;
        self.head.validate()?;
        ensure!(
            self.number == number && self.base.repo.full_name == repo,
            "Pull request inattesa."
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
    fn file_size(&self) -> Option<usize> {
        (self.kind == "blob" && matches!(self.mode.as_str(), "100644" | "100755"))
            .then_some(self.size)
            .flatten()
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
            ensure!(commit.sha == self.commit, "Commit Git inatteso.");
            sha(&commit.tree.sha)?;
            self.root = Some(commit.tree.sha);
        }
        self.root.as_deref().context("Albero Git assente.")
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
            .context("Directory Git non disponibile.")
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
            "Albero Git inatteso o troncato."
        );
        let mut entries = Directory::new();
        for entry in data.tree {
            ensure!(
                !entry.path.is_empty()
                    && !entry.path.contains('/')
                    && !entries.contains_key(&entry.path),
                "Percorso ambiguo nell'albero Git."
            );
            entries.insert(entry.path.clone(), entry);
        }
        Ok(entries)
    }

    fn text<T: Transport>(&mut self, hub: &mut GitHub<T>, path: &str) -> Result<Option<String>> {
        let (dir, name) = parent(path);
        let repo = self.repo;
        let Some(entry) = self.directory(hub, dir)?.get(name) else {
            return Ok(None);
        };
        let size = entry
            .file_size()
            .context("La voce Git non è un file regolare.")?;
        hub.blob(repo, &entry.sha, size)?
            .map(Some)
            .context("Il file non è testo UTF-8.")
    }

    fn inventory<T: Transport>(
        &mut self,
        hub: &mut GitHub<T>,
        changed: &[SourceFile],
        limits: &mut Vec<String>,
    ) -> Vec<Entry> {
        let repo = self.repo;
        let recursive = self.root(hub).and_then(|root| {
            let data: TreeData = hub.get(
                &format!("{repo}/git/trees/{root}?recursive=1"),
                INVENTORY_BYTES,
                false,
            )?;
            ensure!(data.sha == root, "Inventario Git inatteso.");
            Ok(data)
        });
        if let Ok(data) = recursive {
            if data.truncated {
                limits.push("L'inventario Git del contesto è troncato.".into());
            }
            return data.tree;
        }
        // Large repositories can exceed the inventory cap. Keep the directly relevant directories.
        limits.push(
            "Inventario Git non disponibile. La ricerca di contesto usa le directory vicine."
                .into(),
        );
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
    previous_filename: Option<String>,
    patch: Option<String>,
    additions: Option<usize>,
    deletions: Option<usize>,
    changes: Option<usize>,
}

impl Change {
    fn previous(&self) -> Option<&str> {
        if self.status == "renamed" {
            self.previous_filename.as_deref()
        } else {
            Some(&self.filename)
        }
    }

    fn patch(&self, limits: &mut Vec<String>) -> String {
        if let Some(patch) = &self.patch
            && patch.starts_with("@@ ")
            && patch.len() <= PATCH_BYTES
            && self.additions == Some(patch.lines().filter(|line| line.starts_with('+')).count())
            && self.deletions == Some(patch.lines().filter(|line| line.starts_with('-')).count())
        {
            return patch.clone();
        }
        if self.changes != Some(0) || self.patch.is_some() {
            limits.push(format!(
                "Patch mancante, incompleta o troppo grande per {}.",
                self.filename
            ));
        }
        String::new()
    }
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
            "Messaggi dei commit parziali ({} su {total}).",
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
        limits.push("Titolo, descrizione e messaggi superano il limite di testo.".into());
    }
    output
}

fn read_source<T: Transport>(
    hub: &mut GitHub<T>,
    tree: &mut Tree<'_>,
    path: &str,
    required: bool,
    limits: &mut Vec<String>,
) -> String {
    match tree.text(hub, path) {
        Ok(Some(text)) => return text,
        Ok(None) if !required => return String::new(),
        _ => {}
    }
    limits.push(format!(
        "Testo non disponibile o fuori limite per {path} a {}.",
        &tree.commit[..12]
    ));
    String::new()
}

fn add_file(
    file: SourceFile,
    files: &mut Vec<SourceFile>,
    remaining: &mut usize,
    limits: &mut Vec<String>,
) {
    let size = file.before.len() + file.after.len() + file.patch.len();
    if size <= *remaining {
        *remaining -= size;
        files.push(file);
    } else {
        limits.push(format!("Il limite di testo esclude {}.", file.path));
    }
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
            | "specifiche"
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

struct Candidate {
    entry: Entry,
    size: usize,
    score: u32,
    nearby: bool,
    plausible: bool,
}

impl Candidate {
    fn new(entry: Entry, changed: &[SourceFile], terms: &HashSet<String>) -> Option<Self> {
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
        let is_nearby = changed.iter().any(|file| nearby(&entry.path, &file.path));
        let related =
            file_terms(&entry.path).any(|term| terms.contains(&term.to_ascii_lowercase()));
        let guidance = contract(&entry.path);
        let test = test_path(&entry.path);
        let root = !entry.path.contains('/');
        let score = u32::from(related) * 30
            + u32::from(guidance) * 36
            + u32::from(test) * 12
            + u32::from(is_nearby) * 16
            + u32::from(root) * 3
            + u32::from(test && related) * 12;
        Some(Self {
            entry,
            size,
            score,
            nearby: is_nearby,
            plausible: related || guidance || is_nearby,
        })
    }
}

fn probe_indices(candidates: &[Candidate]) -> Vec<usize> {
    let primary = (CONTEXT_PROBES - WIDER_PROBES).min(candidates.len());
    let mut picked: Vec<_> = (0..primary).collect();
    // Leave a few reads for tests or possible callers in other implementation stacks.
    picked.extend(
        candidates
            .iter()
            .enumerate()
            .skip(primary)
            .filter(|(_, candidate)| !candidate.nearby)
            .take(WIDER_PROBES)
            .map(|(index, _)| index),
    );
    for index in primary..candidates.len() {
        if picked.len() == CONTEXT_PROBES {
            break;
        }
        if !picked.contains(&index) {
            picked.push(index);
        }
    }
    picked
}

fn append_context<T: Transport>(
    hub: &mut GitHub<T>,
    base: &mut Tree<'_>,
    head: &mut Tree<'_>,
    excluded: &HashSet<&str>,
    files: &mut Vec<SourceFile>,
    remaining: &mut usize,
    limits: &mut Vec<String>,
) {
    if files.is_empty() {
        return;
    }
    let entries = head.inventory(hub, files, limits);
    let terms = search_terms(files);
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    for entry in entries {
        if !excluded.contains(entry.path.as_str())
            && seen.insert(entry.path.clone())
            && let Some(candidate) = Candidate::new(entry, files, &terms)
        {
            candidates.push(candidate);
        }
    }
    candidates.sort_by(|a, b| b.score.cmp(&a.score).then(a.entry.path.cmp(&b.entry.path)));
    let picked = probe_indices(&candidates);
    if candidates
        .iter()
        .enumerate()
        .any(|(index, candidate)| candidate.plausible && !picked.contains(&index))
    {
        limits.push(format!(
            "La ricerca ha letto al massimo {CONTEXT_PROBES} file di contesto candidati."
        ));
    }
    let mut ranked = Vec::new();
    for index in picked {
        let candidate = &candidates[index];
        let entry = &candidate.entry;
        match hub.blob(head.repo, &entry.sha, candidate.size) {
            Ok(Some(text)) => {
                let matches: HashSet<_> = words(&text)
                    .map(str::to_ascii_lowercase)
                    .filter(|word| terms.contains(word))
                    .collect();
                let references_path = files
                    .iter()
                    .any(|file| file.path.contains('/') && text.contains(&file.path));
                if candidate.plausible || !matches.is_empty() || references_path {
                    let score = candidate.score
                        + u32::from(references_path) * 80
                        + matches.len().min(4) as u32 * 48;
                    ranked.push((score, &entry.path, text));
                }
            }
            Ok(None) => {}
            Err(_) => limits.push("Alcuni file di contesto non sono disponibili.".into()),
        }
    }
    ranked.sort_by(|(x, a, _), (y, b, _)| y.cmp(x).then(a.cmp(b)));
    if ranked.len() > CONTEXT_FILES {
        limits.push(format!("Contesto limitato a {CONTEXT_FILES} file."));
    }
    for (_, path, after) in ranked.into_iter().take(CONTEXT_FILES) {
        let before = read_source(hub, base, path, false, limits);
        add_file(
            SourceFile {
                path: path.clone(),
                patch: String::new(),
                before,
                after,
            },
            files,
            remaining,
            limits,
        );
    }
}

fn pinned<T: Transport>(hub: &mut GitHub<T>, repo: String, number: u64) -> Result<Snapshot> {
    let pull_route = format!("{repo}/pulls/{number}");
    let mut pull: Pull = hub.get(&pull_route, PULL_BYTES, false)?;
    pull.validate(&repo, number)?;
    let head_ref = if pull.head.repo.full_name == repo {
        pull.head.sha.clone()
    } else {
        let (owner, _) = pull
            .head
            .repo
            .full_name
            .split_once('/')
            .context("Fork GitHub non valido.")?;
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
        "Base del confronto Git inattesa."
    );
    let base = sha(&first.merge_base_commit.sha)?;
    let changes = first
        .files
        .as_deref()
        .context("Elenco modifiche GitHub assente.")?;
    let mut limits = Vec::new();
    if changes.len() as u64 != pull.changed_files || changes.len() > CHANGED_FILES {
        limits.push(format!(
            "Elenco modifiche parziale ({} su {}).",
            changes.len().min(CHANGED_FILES),
            pull.changed_files
        ));
    }

    let mut files = Vec::new();
    let mut remaining = SOURCE_BYTES;
    let mut seen = HashSet::new();
    let mut before = Tree::new(&repo, base);
    let mut after = Tree::new(&pull.head.repo.full_name, &pull.head.sha);
    let excluded = changes
        .iter()
        .flat_map(|change| [Some(change.filename.as_str()), change.previous()])
        .flatten()
        .collect();
    for change in changes.iter().take(CHANGED_FILES) {
        let path = &change.filename;
        let Some(previous) = change.previous().filter(|previous| safe_path(previous)) else {
            limits.push("Alcune modifiche hanno percorsi non validi o duplicati.".into());
            continue;
        };
        if !safe_path(path) || !seen.insert(path) {
            limits.push("Alcune modifiche hanno percorsi non validi o duplicati.".into());
            continue;
        }
        if !matches!(
            change.status.as_str(),
            "added" | "removed" | "modified" | "renamed" | "changed"
        ) {
            limits.push(format!("Tipo di modifica non supportato per {path}."));
            continue;
        }
        let patch = change.patch(&mut limits);
        let old_text = if change.status == "added" {
            String::new()
        } else {
            read_source(hub, &mut before, previous, true, &mut limits)
        };
        let new_text = if change.status == "removed" {
            String::new()
        } else {
            read_source(hub, &mut after, path, true, &mut limits)
        };
        add_file(
            SourceFile {
                path: path.clone(),
                patch,
                before: old_text,
                after: new_text,
            },
            &mut files,
            &mut remaining,
            &mut limits,
        );
    }
    let intent = intent(hub, &pull, &route, &first, &mut limits);
    append_context(
        hub,
        &mut before,
        &mut after,
        &excluded,
        &mut files,
        &mut remaining,
        &mut limits,
    );
    let mut final_pull: Pull = hub.get(&pull_route, PULL_BYTES, true)?;
    final_pull.validate(&repo, number)?;
    if !pull.same_revisions(&final_pull) {
        bail!("La pull request è cambiata durante l'acquisizione. Invia di nuovo la richiesta.");
    }
    let mut unique = HashSet::new();
    limits.retain(|limit| unique.insert(limit.clone()));
    Ok(Snapshot {
        url: format!("https://github.com/{repo}/pull/{number}"),
        repo,
        number,
        base: base.to_owned(),
        head: pull.head.sha,
        intent,
        files,
        limits,
    })
}

pub fn collect(url: &str, allowed: &HashSet<String>) -> Result<Snapshot> {
    let (repo, number) = pull_url(url, allowed)?;
    let client = Client::builder()
        .redirect(Policy::none())
        .no_proxy()
        .https_only(true)
        .connect_timeout(REQUEST_TIME)
        .user_agent("jidoka-review")
        .build()?;
    pinned(&mut GitHub::new(Http(client)), repo, number)
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
        Bytes(&'a [u8]),
        Symlink,
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
                    _ => {
                        let bytes = match file {
                            File::Text(text) => text.as_bytes(),
                            File::Bytes(bytes) => bytes,
                            File::Symlink => unreachable!(),
                        };
                        let hash =
                            id(&[format!("blob {}\0", bytes.len()).as_bytes(), bytes].concat());
                        self.responses.insert(
                            format!("{repo}/git/blobs/{hash}"),
                            json!({
                                "encoding": "base64", "content": STANDARD.encode(bytes),
                            }),
                        );
                        json!({"mode": "100644", "type": "blob", "sha": hash, "size": bytes.len()})
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
            assert!(!timeout.is_zero() && timeout <= REQUEST_TIME);
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
        pinned(hub, REPO.into(), 3)
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
            change("binary.dat"),
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
        assert_eq!(view.files[0].before, view.files[0].after);
        assert_eq!(view.files[1].after, "");
        assert_eq!(view.files[2].before, "");
        assert_eq!(view.files[2].after, "new\n");
        assert_eq!(view.files[3].after, "");
        assert!(view.limits.iter().any(|limit| limit.contains("duplicati")));
        assert!(view.limits.iter().any(|limit| limit.contains("link.py")));
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
                .contains("cambiata")
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
        assert!(view.limits.iter().any(|limit| limit.contains("60 su 65")));
        assert!(view.limits.iter().any(|limit| limit.contains("1 su 301")));
        assert!(hub.transport.requests.contains(&comparison(3)));
        assert!(!hub.transport.requests.contains(&comparison(4)));
    }

    #[test]
    fn rejects_inconsistent_patch_and_blob_and_preserves_final_request_budget() {
        let mut entry = change("source.rs");
        entry["additions"] = json!(2);
        let mut fixture = Fixture::new(vec![entry]);
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
        assert!(view.files[0].after.is_empty());
        assert!(view.limits.iter().any(|limit| limit.contains("Patch")));
        assert!(
            view.limits
                .iter()
                .any(|limit| limit.contains("Testo non disponibile"))
        );

        let mut hub = GitHub::new(Fixture::new(vec![change("source.rs")]));
        hub.requests = 4;
        let view = snapshot(&mut hub).unwrap();
        assert!(!view.limits.is_empty());
        assert_eq!(hub.transport.requests.len(), 4);
        assert_eq!(hub.transport.requests.last().unwrap(), PULL);
    }

    #[test]
    fn bounded_response_and_context_inventory_report_gaps() {
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
        assert!(
            view.limits
                .iter()
                .any(|limit| limit.contains("inventario Git"))
        );
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
