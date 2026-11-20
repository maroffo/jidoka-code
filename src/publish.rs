//! Prepare and submit pinned GitHub reviews with durable duplicate prevention.

use std::{collections::BTreeSet, env, fmt::Write, io::Read, path::Path, time::Duration};

use anyhow::{Context, Result, bail, ensure};
use reqwest::{StatusCode, blocking::Client, header::HeaderValue, redirect::Policy};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    contracts::{Attribution, Finding, PublishedReport},
    diff::anchor,
    source::{safe_path, valid_repo},
};

const API: &str = "https://api.github.com";
const WEB: &str = "https://github.com";
const MARKER: &str = "<!-- jidoka-review:";
const REVIEW_BODY_BYTES: usize = 65_000;
const MAX_COMMENTS: usize = 100;
const PAGE_SIZE: usize = 100;
const MAX_PAGES: usize = 10;
const RESPONSE_BYTES: u64 = 8_000_000;
const STORAGE: &str = "Could not access the local GitHub publication record.";
const PENDING: &str = "GitHub has not confirmed this submission. Check the pull request before attempting to post it separately.";
const DIFFERENT: &str = "A review with this decision and revision was already submitted or is awaiting confirmation with different content.";
const DIFFERENT_ACTOR: &str =
    "A different GitHub account already reserved or submitted this automatic review.";
const UNREACHABLE: &str = "Could not reach GitHub.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prepared {
    pub body: String,
    pub comments: Vec<Inline>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inline {
    pub path: String,
    pub line: usize,
    pub body: String,
}

pub fn prepare(report: &PublishedReport, selected: &[usize], inline: bool) -> Prepared {
    let mut prepared = Prepared {
        body: String::from("## Jidoka Code review\n"),
        comments: Vec::new(),
    };
    let mut findings = selected
        .iter()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .filter_map(|index| report.report.findings.get(index))
        .peekable();
    if findings.peek().is_none() {
        let text = if report.report.findings.is_empty() {
            "No verified findings in this report."
        } else {
            "No verified findings selected."
        };
        writeln!(prepared.body, "\n{text}").unwrap();
    }
    for finding in findings {
        let title = markdown(&finding.title);
        let location = location(report, finding);
        let existing = prepared
            .comments
            .iter_mut()
            .find(|item| item.path == finding.path && item.line == finding.line);
        if let Some(comment) = existing {
            writeln!(prepared.body, "\n- **{title}** ({location}, inline)").unwrap();
            writeln!(comment.body, "\n**{title}**").unwrap();
            details(&mut comment.body, finding);
        } else if inline
            && prepared.comments.len() < MAX_COMMENTS
            && finding.line > 0
            && safe_path(&finding.path)
            && anchor(report, &finding.path, finding.line).is_some()
        {
            writeln!(prepared.body, "\n- **{title}** ({location}, inline)").unwrap();
            let mut body = format!("**{title}**\n");
            details(&mut body, finding);
            prepared.comments.push(Inline {
                path: finding.path.clone(),
                line: finding.line,
                body,
            });
        } else {
            writeln!(prepared.body, "\n**{title}** ({location})").unwrap();
            details(&mut prepared.body, finding);
        }
    }

    let limits = report
        .report
        .limits
        .iter()
        .chain(report.scan.iter().flat_map(|scan| &scan.limits))
        .collect::<BTreeSet<_>>();
    if !limits.is_empty() {
        prepared.body.push_str("\n### Partial coverage\n\n");
        for limit in limits {
            writeln!(prepared.body, "- {}", markdown(limit)).unwrap();
        }
    }
    prepared
}

fn details(body: &mut String, finding: &Finding) {
    writeln!(body, "\n{}", markdown(&finding.impact)).unwrap();
    match finding.attribution {
        Attribution::Introduced => (),
        Attribution::Preexisting => body.push_str("\nThis issue predates the pull request.\n"),
        Attribution::Unknown => body.push_str("\nWhen this issue was introduced is unclear.\n"),
    }
    if !finding.evidence.trim().is_empty() {
        body.push_str("\nEvidence\n\n");
        // Keep source text in a code block so its syntax, links and mentions stay literal.
        let evidence = finding.evidence.replace("\r\n", "\n").replace('\r', "\n");
        for line in evidence.lines() {
            writeln!(body, "    {line}").unwrap();
        }
    }
}

fn markdown(text: &str) -> String {
    let mut escaped = String::new();
    for ch in text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
    {
        if ch.is_control() {
            continue;
        }
        match ch {
            '@' | '#' => {
                escaped.push(ch);
                escaped.push('\u{200b}');
            }
            '\\' | '`' | '*' | '_' | '[' | ']' | '(' | ')' | '<' | '>' | '&' | '!' | '~' | '|'
            | ':' | '.' | '+' | '-' | '=' => {
                escaped.push('\\');
                escaped.push(ch);
            }
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn location(report: &PublishedReport, finding: &Finding) -> String {
    let Finding { path, line, .. } = finding;
    if !safe_path(path) {
        return format!("{}, line {line}", markdown(path));
    }
    // A delimiter longer than any run of backticks in the path keeps its spelling verbatim.
    let ticks = "`".repeat(1 + path.split(|ch| ch != '`').map(str::len).max().unwrap_or(0));
    let label = format!("{ticks} {path} {ticks}, line {line}");
    if *line == 0 || !valid_repo(&report.repo) || !valid_sha(&report.head) {
        return label;
    }
    let mut encoded = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            encoded.push(char::from(byte));
        } else {
            write!(encoded, "%{byte:02X}").unwrap();
        }
    }
    format!(
        "[{label}]({WEB}/{}/blob/{}/{encoded}#L{line})",
        report.repo, report.head
    )
}

fn valid_sha(sha: &str) -> bool {
    sha.len() == 40 && sha.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Submit a pinned review, or recover the existing review after an interrupted submission.
///
/// Automatic publishing requires a token for a GitHub bot account that can call
/// `GET /user` and write pull request reviews. Operator tokens must identify a user.
pub fn submit(
    db: &Path,
    report: &PublishedReport,
    number: u64,
    prepared: &Prepared,
    event: &str,
    automatic: bool,
) -> Result<String> {
    let submission = Submission::new(report, number, prepared, event, automatic)?;
    let token = token(automatic, |name| env::var(name).ok())?;
    let github = GitHub::new(&token)?;
    submission.send(db, &github)
}

fn token(automatic: bool, lookup: impl Fn(&str) -> Option<String>) -> Result<String> {
    let configured = |name| lookup(name).filter(|value| !value.trim().is_empty());
    if automatic {
        configured("JIDOKA_BOT_TOKEN")
            .context("Set JIDOKA_BOT_TOKEN to a GitHub bot account token.")
    } else {
        configured("JIDOKA_REVIEWER_TOKEN")
            .or_else(|| configured("GITHUB_TOKEN"))
            .context("Set JIDOKA_REVIEWER_TOKEN or GITHUB_TOKEN to publish a review.")
    }
}

struct GitHub {
    client: Client,
    authorization: HeaderValue,
}

trait Transport {
    fn exchange(&self, route: &str, payload: Option<&Value>) -> Result<(StatusCode, Vec<u8>)>;

    fn request<T: DeserializeOwned>(&self, route: &str, payload: Option<&Value>) -> Result<T> {
        let (status, bytes) = self.exchange(route, payload)?;
        if !status.is_success() {
            return Err(GitHubFailure::Status(status).into());
        }
        serde_json::from_slice(&bytes)
            .ok()
            .context("GitHub returned an invalid response.")
    }
}

impl GitHub {
    fn new(token: &str) -> Result<Self> {
        let mut authorization = HeaderValue::from_str(&format!("Bearer {}", token.trim()))
            .ok()
            .context("The configured GitHub token is invalid.")?;
        authorization.set_sensitive(true);
        let client = Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(Policy::none())
            .retry(reqwest::retry::never())
            .timeout(Duration::from_secs(8))
            .build()
            .ok()
            .context("Could not initialize the GitHub client.")?;
        Ok(Self {
            client,
            authorization,
        })
    }
}

impl Transport for GitHub {
    fn exchange(&self, route: &str, payload: Option<&Value>) -> Result<(StatusCode, Vec<u8>)> {
        let url = format!("{API}{route}");
        let request = match payload {
            Some(value) => self.client.post(&url).json(value),
            None => self.client.get(&url),
        };
        let response = request
            .header("Authorization", self.authorization.clone())
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header("User-Agent", "jidoka-code")
            .send()
            .map_err(|error| {
                if error.is_connect() {
                    GitHubFailure::Connect.into()
                } else {
                    anyhow::anyhow!(UNREACHABLE)
                }
            })?;
        let status = response.status();
        if !status.is_success() {
            return Ok((status, Vec::new()));
        }
        let mut bytes = Vec::new();
        response
            .take(RESPONSE_BYTES + 1)
            .read_to_end(&mut bytes)
            .ok()
            .context("Could not read the GitHub response.")?;
        ensure!(
            bytes.len() as u64 <= RESPONSE_BYTES,
            "The GitHub response was too large."
        );
        Ok((status, bytes))
    }
}

#[derive(Debug)]
enum GitHubFailure {
    Connect,
    Status(StatusCode),
}

impl std::fmt::Display for GitHubFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Status(status) = self else {
            return f.write_str(UNREACHABLE);
        };
        f.write_str(match *status {
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                "GitHub denied access. Check the configured token and its permissions."
            }
            StatusCode::NOT_FOUND => "GitHub could not find the pull request or account.",
            StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => {
                "GitHub rejected the review."
            }
            StatusCode::TOO_MANY_REQUESTS => "GitHub is rate limiting review requests.",
            _ => "GitHub returned an unexpected response.",
        })
    }
}

impl std::error::Error for GitHubFailure {}

fn definitely_unsent(error: &anyhow::Error) -> bool {
    matches!(
        error.downcast_ref::<GitHubFailure>(),
        Some(
            GitHubFailure::Connect
                | GitHubFailure::Status(
                    StatusCode::BAD_REQUEST
                        | StatusCode::UNAUTHORIZED
                        | StatusCode::FORBIDDEN
                        | StatusCode::NOT_FOUND
                        | StatusCode::UNPROCESSABLE_ENTITY
                        | StatusCode::TOO_MANY_REQUESTS
                )
        )
    )
}

#[derive(Deserialize)]
struct Actor {
    id: i64,
    #[serde(rename = "type", default)]
    kind: String,
}

#[derive(Deserialize)]
struct Pull {
    number: u64,
    state: String,
    draft: bool,
    head: Head,
    user: Option<Actor>,
}

#[derive(Deserialize)]
struct Head {
    sha: String,
}

#[derive(Deserialize)]
struct RemoteReview {
    id: i64,
    user: Option<Actor>,
    body: Option<String>,
    commit_id: Option<String>,
    state: String,
    html_url: String,
}

struct Record {
    scope: String,
    actor: i64,
    fingerprint: String,
    id: Option<i64>,
}

struct Submission<'a> {
    repo: &'a str,
    number: u64,
    head: &'a str,
    event: &'a str,
    automatic: bool,
    legacy_scope: String,
    fingerprint: String,
    payload: Value,
}

impl<'a> Submission<'a> {
    fn new(
        report: &'a PublishedReport,
        number: u64,
        prepared: &Prepared,
        event: &'a str,
        automatic: bool,
    ) -> Result<Self> {
        ensure!(
            valid_repo(&report.repo) && valid_sha(&report.head) && number > 0,
            "The report has an invalid GitHub pull request or revision."
        );
        ensure!(
            matches!(event, "COMMENT" | "APPROVE" | "REQUEST_CHANGES"),
            "Choose a valid GitHub review decision."
        );
        ensure!(
            !automatic || event == "COMMENT",
            "Automatic reviews can only comment."
        );
        ensure!(
            !prepared.body.trim().is_empty()
                && prepared.body.len() <= REVIEW_BODY_BYTES
                && !prepared.body.lines().any(|line| line.starts_with(MARKER))
                && prepared.comments.len() <= MAX_COMMENTS
                && prepared.comments.iter().all(|comment| {
                    comment.line > 0
                        && safe_path(&comment.path)
                        && anchor(report, &comment.path, comment.line).is_some()
                        && !comment.body.trim().is_empty()
                        && comment.body.len() <= REVIEW_BODY_BYTES
                }),
            "The review is too large or contains an invalid comment."
        );

        let legacy_scope = hash(format!(
            "{}:{number}:{}:{automatic}:{event}",
            report.repo.to_ascii_lowercase(),
            report.head.to_ascii_lowercase()
        ));
        let comments: Vec<_> = prepared
            .comments
            .iter()
            .map(|comment| {
                json!({
                    "path": comment.path,
                    "line": comment.line,
                    "side": "RIGHT",
                    "body": comment.body,
                })
            })
            .collect();
        let payload = json!({
            "body": prepared.body,
            "commit_id": report.head,
            "event": event,
            "comments": comments,
        });
        let fingerprint = hash(
            serde_json::to_vec(&payload)
                .ok()
                .context("Could not encode the GitHub review.")?,
        );
        Ok(Self {
            repo: &report.repo,
            number,
            head: &report.head,
            event,
            automatic,
            legacy_scope,
            fingerprint,
            payload,
        })
    }

    fn send(&self, db: &Path, github: &impl Transport) -> Result<String> {
        let actor: Actor = github.request("/user", None)?;
        ensure!(actor.id > 0, "GitHub did not identify the review account.");
        ensure!(
            self.automatic || actor.kind == "User",
            "Operator reviews require a GitHub user token."
        );
        let scope = self.scope(actor.id);

        // A committed reservation outlives both the process and a lost POST response.
        // Never retry a POST on an existing reservation, even if GitHub lists no marker yet.
        let connection = Connection::open(db).ok().context(STORAGE)?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .ok()
            .context(STORAGE)?;
        connection
            .execute_batch(
                "PRAGMA synchronous = FULL;
                 CREATE TABLE IF NOT EXISTS github_publications (
                     scope TEXT PRIMARY KEY,
                     actor INTEGER NOT NULL,
                     fingerprint TEXT NOT NULL,
                     review_id INTEGER
                 )",
            )
            .ok()
            .context(STORAGE)?;

        let route = format!("/repos/{}/pulls/{}", self.repo, self.number);
        let reviews = format!("{route}/reviews");
        if let Some(record) = Self::load(&connection, &scope)? {
            return self.resume(&connection, github, &reviews, actor.id, record);
        }
        if !self.automatic
            && let Some(record) = Self::load(&connection, &self.legacy_scope)?
            && record.actor == actor.id
            && self.matches_slot(&record.fingerprint)
        {
            return self.resume(&connection, github, &reviews, actor.id, record);
        }
        let keys = [scope.as_str(), self.legacy_scope.as_str()];
        if let Some(mut record) = self.find_remote(github, &reviews, actor.id, &keys)? {
            record.scope.clone_from(&scope);
            Self::insert(&connection, &record)?;
            let stored = Self::load(&connection, &scope)?.context(STORAGE)?;
            return self.resume(&connection, github, &reviews, actor.id, stored);
        }

        let pull: Pull = github.request(&route, None)?;
        ensure!(
            pull.number == self.number,
            "GitHub returned a different pull request."
        );
        ensure!(pull.state == "open", "The pull request is closed.");
        ensure!(!pull.draft, "The pull request is still a draft.");
        ensure!(
            pull.head.sha.eq_ignore_ascii_case(self.head),
            "The pull request has changed. Review its current revision before publishing."
        );
        if self.event != "COMMENT" {
            let author = pull
                .user
                .filter(|user| user.id > 0)
                .context("GitHub could not verify the pull request author.")?;
            ensure!(
                author.id != actor.id,
                "The pull request author cannot approve or request changes on their own pull request."
            );
        }

        let record = Record {
            scope,
            actor: actor.id,
            fingerprint: self.fingerprint.clone(),
            id: None,
        };
        if !Self::insert(&connection, &record)? {
            let stored = Self::load(&connection, &record.scope)?.context(STORAGE)?;
            return self.resume(&connection, github, &reviews, actor.id, stored);
        }

        let mut payload = self.payload.clone();
        let body = payload["body"].as_str().expect("review body was validated");
        let scope = &record.scope;
        let fingerprint = &record.fingerprint;
        payload["body"] = json!(format!("{body}\n\n{MARKER}{scope}:{fingerprint} -->"));
        let keys = [scope.as_str()];
        let posted = github
            .request::<RemoteReview>(&reviews, Some(&payload))
            .and_then(|review| {
                let result = self.match_review(&review, actor.id, &keys)?;
                result
                    .filter(|record| record.fingerprint == self.fingerprint)
                    .context("GitHub did not identify the submitted review.")
            });
        match posted {
            Ok(result) => self.confirm(&connection, &record, result.id.context(STORAGE)?),
            Err(error) if definitely_unsent(&error) => {
                // Only the caller that inserted this reservation issued the POST.
                connection
                    .execute(
                        "DELETE FROM github_publications
                     WHERE scope = ?1 AND actor = ?2 AND fingerprint = ?3 AND review_id IS NULL",
                        params![scope, actor.id, fingerprint],
                    )
                    .ok()
                    .context(STORAGE)?;
                Err(error)
            }
            Err(error) => {
                if let Ok(Some(result)) = self.find_remote(github, &reviews, actor.id, &keys)
                    && result.fingerprint == self.fingerprint
                {
                    return self.confirm(&connection, &record, result.id.context(STORAGE)?);
                }
                bail!("{error} {PENDING}");
            }
        }
    }

    fn scope(&self, actor: i64) -> String {
        if self.automatic {
            // The bot gets one slot per head, even if its configured account changes.
            self.legacy_scope.clone()
        } else if self.event == "COMMENT" {
            hash(format!(
                "{}:{actor}:{}",
                self.legacy_scope, self.fingerprint
            ))
        } else {
            hash(format!("{}:{actor}", self.legacy_scope))
        }
    }

    fn matches_slot(&self, fingerprint: &str) -> bool {
        self.automatic || self.event != "COMMENT" || fingerprint == self.fingerprint
    }

    fn insert(connection: &Connection, record: &Record) -> Result<bool> {
        let rows = connection
            .execute(
                "INSERT INTO github_publications (scope, actor, fingerprint, review_id)
                 VALUES (?1, ?2, ?3, ?4) ON CONFLICT(scope) DO NOTHING",
                params![record.scope, record.actor, record.fingerprint, record.id],
            )
            .ok()
            .context(STORAGE)?;
        Ok(rows == 1)
    }

    fn load(connection: &Connection, scope: &str) -> Result<Option<Record>> {
        connection
            .query_row(
                "SELECT actor, fingerprint, review_id FROM github_publications WHERE scope = ?1",
                [scope],
                |row| {
                    Ok(Record {
                        scope: scope.to_owned(),
                        actor: row.get(0)?,
                        fingerprint: row.get(1)?,
                        id: row.get(2)?,
                    })
                },
            )
            .optional()
            .ok()
            .context(STORAGE)
    }

    fn resume(
        &self,
        connection: &Connection,
        github: &impl Transport,
        route: &str,
        actor: i64,
        record: Record,
    ) -> Result<String> {
        ensure!(record.actor == actor, "{DIFFERENT_ACTOR}");
        ensure!(record.fingerprint == self.fingerprint, "{DIFFERENT}");
        if let Some(id) = record.id {
            return self.url(id);
        }
        if let Some(found) = self.find_remote(github, route, actor, &[&record.scope])? {
            ensure!(found.fingerprint == self.fingerprint, "{DIFFERENT}");
            return self.confirm(connection, &record, found.id.context(STORAGE)?);
        }
        bail!("{PENDING}")
    }

    fn confirm(&self, connection: &Connection, record: &Record, id: i64) -> Result<String> {
        connection
            .execute(
                "UPDATE github_publications SET review_id = ?4
                 WHERE scope = ?1 AND actor = ?2 AND fingerprint = ?3 AND review_id IS NULL",
                params![record.scope, record.actor, record.fingerprint, id],
            )
            .ok()
            .context(STORAGE)?;
        self.url(
            Self::load(connection, &record.scope)?
                .filter(|stored| {
                    stored.actor == record.actor && stored.fingerprint == record.fingerprint
                })
                .and_then(|record| record.id)
                .context(STORAGE)?,
        )
    }

    fn find_remote(
        &self,
        github: &impl Transport,
        route: &str,
        actor: i64,
        keys: &[&str],
    ) -> Result<Option<Record>> {
        for page in 1..=MAX_PAGES {
            let reviews: Vec<RemoteReview> =
                github.request(&format!("{route}?per_page={PAGE_SIZE}&page={page}"), None)?;
            for review in &reviews {
                if let Some(record) = self.match_review(review, actor, keys)? {
                    return Ok(Some(record));
                }
            }
            if reviews.len() < PAGE_SIZE {
                return Ok(None);
            }
        }
        bail!("Could not check all existing GitHub reviews for a matching submission.")
    }

    fn match_review(
        &self,
        review: &RemoteReview,
        actor: i64,
        keys: &[&str],
    ) -> Result<Option<Record>> {
        let expected_state = match self.event {
            "APPROVE" => "APPROVED",
            "REQUEST_CHANGES" => "CHANGES_REQUESTED",
            _ => "COMMENTED",
        };
        if !review.user.as_ref().is_some_and(|user| user.id == actor)
            || !review
                .commit_id
                .as_deref()
                .is_some_and(|sha| sha.eq_ignore_ascii_case(self.head))
            || !(review.state == expected_state || review.state == "DISMISSED")
        {
            return Ok(None);
        }
        let Some((scope, fingerprint)) = review
            .body
            .as_deref()
            .and_then(|body| body.trim_end().lines().last())
            .and_then(|line| {
                line.strip_prefix(MARKER)?
                    .strip_suffix(" -->")?
                    .split_once(':')
            })
            .filter(|(scope, fingerprint)| {
                keys.contains(scope)
                    && fingerprint.len() == 64
                    && fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
                    && self.matches_slot(fingerprint)
            })
        else {
            return Ok(None);
        };
        let url = self.url(review.id)?;
        ensure!(
            review.html_url.starts_with("https://github.com/")
                && review.html_url.eq_ignore_ascii_case(&url),
            "GitHub returned an invalid review URL."
        );
        Ok(Some(Record {
            scope: scope.to_owned(),
            actor,
            fingerprint: fingerprint.to_owned(),
            id: Some(review.id),
        }))
    }

    fn url(&self, id: i64) -> Result<String> {
        ensure!(id > 0, "GitHub returned an invalid review identifier.");
        Ok(format!(
            "{WEB}/{}/pull/{}#pullrequestreview-{id}",
            self.repo, self.number
        ))
    }
}

fn hash(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::{DiffFile, PinnedDiff, Report, Scan};
    use std::{
        sync::{
            Arc, Barrier, Mutex,
            atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering::SeqCst},
        },
        thread,
    };

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
    const PULL: &str = "/repos/team/example/pulls/7";
    const REVIEWS: &str = "/repos/team/example/pulls/7/reviews";
    const LINK: &str = "https://github.com/team/example/pull/7#pullrequestreview-91";
    const PATH: &str = "src/main.rs";

    fn report() -> PublishedReport {
        let finding = |path: &str, line, title: &str| Finding {
            path: path.to_owned(),
            line,
            title: title.to_owned(),
            impact: "[image](https://untrusted.invalid/) @team/review #104".to_owned(),
            evidence: "    let label = \"@company\";\r\n<!-- jidoka-review:example -->".to_owned(),
            attribution: Attribution::Introduced,
        };
        PublishedReport {
            repo: "team/example".to_owned(),
            base: "a".repeat(40),
            head: HEAD.to_owned(),
            report: Report {
                findings: vec![
                    finding(PATH, 8, "First"),
                    finding(PATH, 8, "Second"),
                    finding("src/@helpers/café (old).rs", 75, "Fallback"),
                    finding("../untrusted", 1, "Unsafe path"),
                ],
                ..Report::default()
            },
            scan: None,
            patch_files: None,
            diff: Some(PinnedDiff {
                total_files: 1,
                files: vec![DiffFile {
                    path: PATH.to_owned(),
                    status: "modified".to_owned(),
                    previous_path: None,
                    patch: Some("@@ -8 +8 @@\n-old()\n+new()".to_owned()),
                }],
                supporting_paths: vec![],
            }),
        }
    }

    #[test]
    fn groups_inline_and_escapes_source_with_pinned_fallbacks() {
        let report = report();
        let prepared = prepare(&report, &[2, 1, 0, 3, 0, 999], true);
        assert_eq!(prepared.comments.len(), 1);
        let comment = &prepared.comments[0];
        assert_eq!((&*comment.path, comment.line), (PATH, 8));
        assert_eq!(comment.body.matches("**First**").count(), 1);
        assert!(comment.body.contains("**Second**"));
        assert!(comment.body.contains("\\[image\\]\\(https\\://"));
        assert!(comment.body.contains("@\u{200b}team/review #\u{200b}104"));
        assert!(comment.body.contains("        let label = \"@company\";"));
        assert!(
            comment
                .body
                .contains("\n    <!-- jidoka-review:example -->")
        );
        assert!(!comment.body.contains("\n<!-- jidoka-review:example -->"));
        assert!(prepared.body.contains(&format!(
            "/blob/{HEAD}/src/%40helpers/caf%C3%A9%20%28old%29.rs#L75"
        )));
        assert!(!prepared.body.contains("/../untrusted"));
        assert!(prepared.body.contains("**Fallback**"));

        let summary = prepare(&report, &[0], false);
        assert!(summary.comments.is_empty());
        assert!(summary.body.contains(&format!("/blob/{HEAD}/{PATH}#L8")));
        assert!(summary.body.contains("Evidence"));
        assert!(Submission::new(&report, 7, &summary, "COMMENT", false).is_ok());
    }

    #[test]
    fn labels_partial_report_and_scan_coverage_even_without_selected_findings() {
        let mut report = report();
        assert!(
            !prepare(&report, &[], true)
                .body
                .contains("Partial coverage")
        );
        report.report.limits.push("Missing file".to_owned());
        assert!(
            prepare(&report, &[0], true)
                .body
                .contains("Partial coverage")
        );
        report.report.limits.clear();
        report.report.findings.clear();
        report.scan = Some(Scan {
            limits: vec!["Scan budget reached".to_owned()],
            ..Scan::default()
        });
        let summary = prepare(&report, &[], false);
        assert!(
            summary
                .body
                .contains("No verified findings in this report.")
        );
        assert!(summary.body.contains("Partial coverage"));
        assert!(summary.body.contains("Scan budget reached"));
    }

    #[test]
    fn selects_the_right_credential_and_rejects_automatic_decisions() {
        let all = |name: &str| Some(name.to_owned());
        assert_eq!(token(false, all).unwrap(), "JIDOKA_REVIEWER_TOKEN");
        assert_eq!(token(true, all).unwrap(), "JIDOKA_BOT_TOKEN");
        let fallback = |name: &str| (name == "GITHUB_TOKEN").then(|| "user-token".to_owned());
        assert_eq!(token(false, fallback).unwrap(), "user-token");
        assert!(token(true, fallback).is_err());

        let report = report();
        let prepared = prepare(&report, &[], false);
        for event in ["APPROVE", "REQUEST_CHANGES", "PENDING"] {
            assert!(Submission::new(&report, 7, &prepared, event, true).is_err());
        }
    }

    #[test]
    fn blocks_unsafe_operator_writes_at_preflight() {
        for (event, actor, author, state, draft, head, message) in [
            ("APPROVE", "User", 31, "open", false, HEAD, "their own"),
            (
                "REQUEST_CHANGES",
                "User",
                31,
                "open",
                false,
                HEAD,
                "their own",
            ),
            (
                "APPROVE",
                "User",
                0,
                "open",
                false,
                HEAD,
                "verify the pull request author",
            ),
            (
                "COMMENT",
                "Bot",
                32,
                "open",
                false,
                HEAD,
                "require a GitHub user token",
            ),
            ("COMMENT", "User", 32, "closed", false, HEAD, "closed"),
            ("COMMENT", "User", 32, "open", true, HEAD, "draft"),
            (
                "COMMENT",
                "User",
                32,
                "open",
                false,
                "old-head",
                "has changed",
            ),
        ] {
            let mock = Mock(move |request| {
                assert_eq!(request.method, "GET");
                ok(match request.path.as_str() {
                    "/user" => json!({"id": 31, "type": actor}),
                    PULL => pull(author, state, draft, head),
                    _ => json!([]),
                })
            });
            let db = tempfile::tempdir().unwrap();
            let report = report();
            let prepared = prepare(&report, &[0], true);
            let submission = Submission::new(&report, 7, &prepared, event, false).unwrap();
            let error = submission
                .send(&db.path().join("app.db"), &mock)
                .unwrap_err();
            assert!(error.to_string().contains(message), "{error}");
        }
    }

    #[test]
    fn allows_retry_after_a_definitive_write_rejection_or_connection_failure() {
        for status in [Some(403), Some(422), Some(429), None] {
            let writes = Arc::new(AtomicUsize::new(0));
            let mock = Mock({
                let writes = Arc::clone(&writes);
                move |request| {
                    if request.method == "POST" {
                        assert_eq!(request.path, REVIEWS);
                        let payload = request.payload;
                        assert_eq!(payload["commit_id"], HEAD);
                        assert_eq!(payload["event"], "COMMENT");
                        assert!(
                            payload["body"]
                                .as_str()
                                .unwrap()
                                .contains("Partial coverage")
                        );
                        if writes.fetch_add(1, SeqCst) == 0 {
                            assert_eq!(payload["comments"][0]["side"], "RIGHT");
                            assert_eq!(payload["comments"][0]["line"], 8);
                            assert_eq!(payload["comments"][0]["path"], PATH);
                            return status.map_or(Reply::Connect, |status| {
                                Reply::Http(
                                    status,
                                    json!({"message": "private upstream diagnostic"}),
                                )
                            });
                        }
                        assert_eq!(payload["comments"], json!([]));
                        return ok(remote(&payload));
                    }
                    preflight(&request)
                }
            });
            let db = tempfile::tempdir().unwrap();
            let db = db.path().join("app.db");
            let mut report = report();
            report
                .report
                .limits
                .push("Some files were omitted".to_owned());
            let original = prepare(&report, &[0], true);
            let corrected = prepare(&report, &[], false);
            let error = Submission::new(&report, 7, &original, "COMMENT", true)
                .unwrap()
                .send(&db, &mock)
                .unwrap_err()
                .to_string();
            assert!(!error.contains("private upstream diagnostic"));
            assert!(!error.contains(PENDING));
            let retry = Submission::new(&report, 7, &corrected, "COMMENT", true).unwrap();
            assert_eq!(retry.send(&db, &mock).unwrap(), LINK);
            assert_eq!(retry.send(&db, &mock).unwrap(), LINK);
            assert_eq!(writes.load(SeqCst), 2);
        }
    }

    #[test]
    fn reconciles_a_lost_response_after_restart_and_ignores_false_markers() {
        let visible = Arc::new(AtomicBool::new(false));
        let writes = Arc::new(AtomicUsize::new(0));
        let mock = Mock({
            let visible = Arc::clone(&visible);
            let writes = Arc::clone(&writes);
            let posted = Mutex::new(None);
            move |request| {
                if request.method == "POST" {
                    writes.fetch_add(1, SeqCst);
                    *posted.lock().unwrap() = Some(remote(&request.payload));
                    return Reply::Lost;
                }
                if request.path.starts_with(REVIEWS)
                    && let Some(review) = posted.lock().unwrap().as_ref()
                {
                    let mut wrong_actor = review.clone();
                    wrong_actor["user"]["id"] = json!(88);
                    let mut wrong_head = review.clone();
                    wrong_head["commit_id"] = json!("a".repeat(40));
                    let mut pending = review.clone();
                    pending["state"] = json!("PENDING");
                    let mut reviews = vec![wrong_actor, wrong_head, pending];
                    if visible.load(SeqCst) {
                        reviews.push(review.clone());
                    }
                    return ok(json!(reviews));
                }
                preflight(&request)
            }
        });

        let local = tempfile::tempdir().unwrap();
        let db = local.path().join("app.db");
        let report = report();
        let prepared = prepare(&report, &[1], true);
        let submit = |path: &Path| {
            Submission::new(&report, 7, &prepared, "APPROVE", false)
                .unwrap()
                .send(path, &mock)
        };
        assert!(submit(&db).unwrap_err().to_string().contains(PENDING));
        assert!(submit(&db).unwrap_err().to_string().contains(PENDING));
        visible.store(true, SeqCst);
        assert_eq!(submit(&db).unwrap(), LINK);
        assert_eq!(submit(&local.path().join("fresh.db")).unwrap(), LINK);
        assert_eq!(writes.load(SeqCst), 1);
    }

    #[test]
    fn preserves_reservation_on_server_errors_and_rejects_untrusted_review_urls() {
        for return_review in [false, true] {
            let writes = Arc::new(AtomicUsize::new(0));
            let mock = Mock({
                let writes = Arc::clone(&writes);
                move |request| {
                    if request.method == "POST" {
                        writes.fetch_add(1, SeqCst);
                        if return_review {
                            let mut invalid = remote(&request.payload);
                            invalid["html_url"] = json!("https://github.com.evil.invalid/review");
                            return ok(invalid);
                        }
                        return Reply::Http(503, json!({"message": "unknown write outcome"}));
                    }
                    preflight(&request)
                }
            });
            let db = tempfile::tempdir().unwrap();
            let db = db.path().join("app.db");
            let report = report();
            let prepared = prepare(&report, &[0], true);
            let submission = Submission::new(&report, 7, &prepared, "COMMENT", true).unwrap();
            for _ in 0..2 {
                let message = submission.send(&db, &mock).unwrap_err().to_string();
                assert!(message.contains(PENDING));
                assert!(!message.contains("evil.invalid"));
                assert!(!message.contains("unknown write outcome"));
            }
            let different = prepare(&report, &[], false);
            let different = Submission::new(&report, 7, &different, "COMMENT", true).unwrap();
            assert_eq!(
                different.send(&db, &mock).unwrap_err().to_string(),
                DIFFERENT
            );
            assert_eq!(writes.load(SeqCst), 1);
        }
    }

    #[test]
    fn deduplicates_manual_comments_by_account_and_payload_and_preserves_the_bot_slot() {
        let actor = AtomicI64::new(31);
        let remote_reviews = Mutex::new(Vec::new());
        let mock = Mock(|request| {
            let actor = actor.load(SeqCst);
            if request.path == "/user" {
                return ok(json!({"id": actor, "type": "User"}));
            }
            let mut reviews = remote_reviews.lock().unwrap();
            if request.method == "POST" {
                let id = 91 + reviews.len();
                let mut review = remote(&request.payload);
                review["user"]["id"] = json!(actor);
                review["id"] = json!(id);
                review["html_url"] =
                    json!(format!("{WEB}/team/example/pull/7#pullrequestreview-{id}"));
                reviews.push(review.clone());
                return ok(review);
            }
            if request.path.starts_with(REVIEWS) {
                return ok(json!(*reviews));
            }
            preflight(&request)
        });
        let local = tempfile::tempdir().unwrap();
        let db = local.path().join("app.db");
        let report = report();
        let first = prepare(&report, &[0], true);
        let second = prepare(&report, &[1], true);
        let submit = |db: &Path, prepared, automatic| {
            Submission::new(&report, 7, prepared, "COMMENT", automatic)
                .unwrap()
                .send(db, &mock)
        };

        assert_eq!(submit(&db, &first, false).unwrap(), LINK);
        assert_eq!(submit(&db, &first, false).unwrap(), LINK);
        let other_selection = submit(&db, &second, false).unwrap();
        assert_ne!(other_selection, LINK);
        assert_eq!(submit(&db, &second, false).unwrap(), other_selection);
        assert_eq!(
            submit(&local.path().join("fresh.db"), &second, false).unwrap(),
            other_selection
        );

        actor.store(0, SeqCst);
        assert!(submit(&db, &first, false).is_err());
        actor.store(44, SeqCst);
        let other_operator = submit(&db, &first, false).unwrap();
        assert_ne!(other_operator, LINK);
        assert_eq!(submit(&db, &first, false).unwrap(), other_operator);

        let bot = submit(&db, &first, true).unwrap();
        assert_eq!(submit(&db, &first, true).unwrap(), bot);
        assert_eq!(
            submit(&db, &second, true).unwrap_err().to_string(),
            DIFFERENT
        );
        actor.store(31, SeqCst);
        assert_eq!(
            submit(&db, &first, true).unwrap_err().to_string(),
            DIFFERENT_ACTOR
        );
        assert_eq!(submit(&db, &first, false).unwrap(), LINK);
        assert_eq!(remote_reviews.lock().unwrap().len(), 4);
    }

    #[test]
    fn reconciles_a_legacy_manual_marker_for_the_original_actor_and_content() {
        let report = report();
        let prepared = prepare(&report, &[0], true);
        let submission = Submission::new(&report, 7, &prepared, "COMMENT", false).unwrap();
        let mut payload = submission.payload.clone();
        payload["body"] = json!(format!(
            "{}\n\n{MARKER}{}:{} -->",
            prepared.body, submission.legacy_scope, submission.fingerprint
        ));
        let original = remote(&payload);
        let mock = Mock(|request| {
            if request.path.starts_with(REVIEWS) {
                assert_eq!(request.method, "GET");
                return ok(json!([original]));
            }
            preflight(&request)
        });
        let local = tempfile::tempdir().unwrap();
        let db = local.path().join("app.db");
        assert_eq!(submission.send(&db, &mock).unwrap(), LINK);
        assert_eq!(submission.send(&db, &mock).unwrap(), LINK);
    }

    #[test]
    fn concurrent_calls_write_only_one_review() {
        let writes = Arc::new(AtomicUsize::new(0));
        let mock = Mock({
            let writes = Arc::clone(&writes);
            let both_preflights = Barrier::new(2);
            move |request| {
                if request.method == "POST" {
                    writes.fetch_add(1, SeqCst);
                    return ok(remote(&request.payload));
                }
                if request.path == PULL {
                    both_preflights.wait();
                }
                preflight(&request)
            }
        });
        let db = tempfile::tempdir().unwrap();
        let db = db.path().join("app.db");
        let report = report();
        let prepared = prepare(&report, &[0], true);
        let submission = Submission::new(&report, 7, &prepared, "COMMENT", false).unwrap();

        thread::scope(|scope| {
            let first = scope.spawn(|| submission.send(&db, &mock));
            let second = scope.spawn(|| submission.send(&db, &mock));
            let results = [first.join().unwrap(), second.join().unwrap()];
            assert!(
                results
                    .iter()
                    .any(|result| result.as_deref().is_ok_and(|url| url == LINK))
            );
            for result in results {
                match result {
                    Ok(url) => assert_eq!(url, LINK),
                    Err(error) => assert!(error.to_string().contains(PENDING), "{error}"),
                }
            }
        });
        assert_eq!(submission.send(&db, &mock).unwrap(), LINK);
        assert_eq!(writes.load(SeqCst), 1);
    }

    fn remote(payload: &Value) -> Value {
        let state = match payload["event"].as_str().unwrap() {
            "APPROVE" => "APPROVED",
            "REQUEST_CHANGES" => "CHANGES_REQUESTED",
            "COMMENT" => "COMMENTED",
            event => panic!("unexpected review event {event}"),
        };
        json!({
            "id": 91, "user": {"id": 31}, "body": payload["body"],
            "commit_id": payload["commit_id"], "state": state, "html_url": LINK,
        })
    }

    fn pull(author: i64, state: &str, draft: bool, head: &str) -> Value {
        json!({
            "number": 7, "state": state, "draft": draft, "head": {"sha": head}, "user": {"id": author},
        })
    }

    enum Reply {
        Http(u16, Value),
        Connect,
        Lost,
    }

    fn ok(value: Value) -> Reply {
        Reply::Http(200, value)
    }

    fn preflight(request: &Request) -> Reply {
        assert_eq!(request.method, "GET");
        ok(match request.path.as_str() {
            "/user" => json!({"id": 31, "type": "User"}),
            PULL => pull(32, "open", false, HEAD),
            path if path.starts_with(REVIEWS) => json!([]),
            path => panic!("unexpected request {path}"),
        })
    }

    struct Request {
        method: String,
        path: String,
        payload: Value,
    }

    struct Mock<F: Fn(Request) -> Reply>(F);

    impl<F: Fn(Request) -> Reply> Transport for Mock<F> {
        fn exchange(&self, route: &str, payload: Option<&Value>) -> Result<(StatusCode, Vec<u8>)> {
            let request = Request {
                method: if payload.is_some() { "POST" } else { "GET" }.to_owned(),
                path: route.to_owned(),
                payload: payload.cloned().unwrap_or(Value::Null),
            };
            match (self.0)(request) {
                Reply::Http(status, value) => Ok((
                    StatusCode::from_u16(status).unwrap(),
                    serde_json::to_vec(&value).unwrap(),
                )),
                Reply::Connect => Err(GitHubFailure::Connect.into()),
                Reply::Lost => bail!(UNREACHABLE),
            }
        }
    }
}
