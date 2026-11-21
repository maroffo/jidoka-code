//! Review pages and the persistent, single-user work queue.

mod workflow;

use std::{
    collections::{HashMap, HashSet},
    fmt::Write,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::Result;
use axum::{
    Router,
    body::to_bytes,
    extract::{Path as RoutePath, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::get,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::Sha256;

use crate::{
    contracts::{Attribution, Finding, GitHubRateLimit, PublishedReport, Scan, Snapshot},
    source::{safe_path, valid_repo},
};

const FAILED: &str =
    "The review failed. Resubmit the pull request from the home page to try again.";
const INTERRUPTED: &str = "The review was interrupted. Resubmit the pull request to try again.";
const PROVIDER_CHANGED: &str =
    "The provider changed. Resubmit the pull request to confirm the provider.";
const FORBIDDEN: &str = "Form submission was blocked. Open the home page and try again.";
const UNAPPROVED: &str = "This repository is not approved for review.";
const BAD_FORM: &str = "Could not read the form.";
const FORM_LIMIT: usize = 8192;
const CSRF_COOKIE: &str = "jidoka_csrf";
type TokenMac = Hmac<Sha256>;

struct WebState {
    db: PathBuf,
    provider: String,
    configured_repos: HashSet<String>,
    secret: [u8; 32],
}

fn connect(db: &Path) -> rusqlite::Result<Connection> {
    let connection = Connection::open(db)?;
    connection.busy_timeout(Duration::from_secs(5))?;
    Ok(connection)
}

fn init_db(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL,
            provider TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            report TEXT,
            error TEXT
        )",
    )
}

/// Recover interrupted work and invalidate old consent before starting the worker.
pub fn recover(db: &Path, provider: &str) -> Result<()> {
    let mut connection = connect(db)?;
    init_db(&connection)?;
    crate::automation::init(&connection)?;
    crate::automation::recover(&connection, provider)?;
    let transaction = connection.transaction()?;
    transaction.execute(
        "UPDATE reviews SET status = 'failed', error = ?1 WHERE status = 'running'",
        [INTERRUPTED],
    )?;
    transaction.execute(
        "UPDATE reviews SET status = 'failed', error = ?1 WHERE status = 'queued' AND provider <> ?2",
        [PROVIDER_CHANGED, provider],
    )?;
    transaction.commit()?;
    Ok(())
}

/// Latest reviewed head for the same PR and provider, including clean reviews.
pub fn latest_review(db: &Path, provider: &str, url: &str) -> Result<Option<PublishedReport>> {
    let Some((repo, _)) = parse_pull_url(url) else {
        return Ok(None);
    };
    let raw: Option<String> = connect(db)?
        .query_row(
            "SELECT report FROM reviews WHERE url = ?1 COLLATE NOCASE AND provider = ?2
         AND status IN ('completed','partial') AND CASE WHEN json_valid(report) THEN
         json_extract(report,'$.repo') = ?3 COLLATE NOCASE END ORDER BY id DESC LIMIT 1",
            params![url, provider, repo],
            |row| row.get(0),
        )
        .optional()?;
    Ok(raw.and_then(|raw| serde_json::from_str(&raw).ok()))
}

/// On a later revision the previous line may have moved or disappeared entirely.
/// Give discovery the old question without presenting its line or evidence as current.
pub fn add_previous_questions(previous: &PublishedReport, current: &mut Snapshot) {
    if previous.head == current.head
        || previous.base != current.base
        || !previous.repo.eq_ignore_ascii_case(&current.repo)
    {
        return;
    }
    for finding in previous
        .report
        .findings
        .iter()
        .filter(|finding| safe_path(&finding.path))
        .take(2)
    {
        let title: String = finding.title.chars().take(400).collect();
        current.intent.push(format!(
            "Earlier review question for {}: does the current revision still support the concern “{}”? Check the changed code and tests, including any fix. Cite only the current evidence.",
            finding.path, title
        ));
    }
}

/// Retrieve leads from an earlier reviewed copy of this exact change.
pub fn previous_findings(db: &Path, provider: &str, snapshot: &Snapshot) -> Result<Vec<Finding>> {
    // Recheck leads only when the PR, both revisions and the selected provider still match.
    let previous: Option<String> = connect(db)?
        .query_row(
            "SELECT json_extract(report, '$.findings') FROM reviews
         WHERE url = ?1 COLLATE NOCASE AND provider = ?2 AND status IN ('partial','completed')
           AND CASE WHEN json_valid(report) THEN
               json_extract(report, '$.repo') = ?3 COLLATE NOCASE
               AND json_extract(report, '$.base') = ?4 AND json_extract(report, '$.head') = ?5
               AND json_array_length(report, '$.findings') > 0 END
         ORDER BY id DESC LIMIT 1",
            params![
                snapshot.url,
                provider,
                snapshot.repo,
                snapshot.base,
                snapshot.head
            ],
            |row| row.get(0),
        )
        .optional()?;
    Ok(previous
        .and_then(|items| serde_json::from_str(&items).ok())
        .unwrap_or_default())
}

/// Claim at most one review, in queue order, and save its result.
pub fn run_one<F>(db: &Path, process: F) -> Result<bool>
where
    F: FnOnce(&str) -> Result<PublishedReport>,
{
    run_one_pinned(db, |url, _| process(url))
}

pub fn run_one_pinned<F>(db: &Path, process: F) -> Result<bool>
where
    F: FnOnce(&str, Option<&str>) -> Result<PublishedReport>,
{
    let mut connection = connect(db)?;
    let transaction = connection.transaction()?;
    let job: Option<(i64, String)> = transaction
        .query_row(
            "UPDATE reviews SET status = 'running'
            WHERE id = (SELECT id FROM reviews WHERE status = 'queued' ORDER BY id LIMIT 1)
            RETURNING id, url",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((id, url)) = job else {
        transaction.commit()?;
        return Ok(false);
    };
    let expected_head: Option<String> = transaction
        .query_row(
            "SELECT head FROM automation_jobs WHERE review_id = ?1",
            [id],
            |row| row.get(0),
        )
        .optional()?;
    transaction.commit()?;

    let outcome = process(&url, expected_head.as_deref()).and_then(|report| {
        anyhow::ensure!(
            expected_head
                .as_deref()
                .is_none_or(|head| report.head.eq_ignore_ascii_case(head)),
            crate::source::HeadChanged("The pull request changed before review.")
        );
        let status = if partial(&report) {
            "partial"
        } else {
            "completed"
        };
        Ok((status, serde_json::to_string(&report)?))
    });
    let (status, report, error) = match outcome {
        Ok((status, report)) => (status, Some(report), None),
        Err(error) if expected_head.is_some() && error.is::<crate::source::HeadChanged>() => {
            ("superseded", None, None)
        }
        Err(error) => {
            let reason = error
                .downcast_ref::<GitHubRateLimit>()
                .map_or_else(|| FAILED.to_owned(), ToString::to_string);
            ("failed", None, Some(reason))
        }
    };
    let tx = connection.transaction()?;
    let updated = tx.execute(
        "UPDATE reviews SET status = ?1, report = ?2, error = ?3 WHERE id = ?4 AND status = 'running'",
        params![status, report, error, id],
    )?;
    if updated != 0 && status == "superseded" {
        tx.execute("UPDATE automation_jobs SET state='canceled', retry_at=0 WHERE review_id=?1 AND state='pending'", [id])?;
        tx.execute("UPDATE automation_settings SET review_error=NULL, review_error_job=NULL WHERE review_error_job=?1", [id])?;
    }
    tx.commit()?;
    Ok(true)
}

pub fn router(db: &Path, provider: &str, allowed_repos: &HashSet<String>) -> Result<Router> {
    let connection = connect(db)?;
    init_db(&connection)?;
    crate::automation::init(&connection)?;
    let state = Arc::new(WebState {
        db: db.to_owned(),
        provider: provider.to_owned(),
        configured_repos: allowed_repos
            .iter()
            .map(|repo| repo.to_ascii_lowercase())
            .collect(),
        secret: rand::random(),
    });
    Ok(Router::new()
        .route("/", get(home).post(submit))
        .route("/reviews/{id}", get(review))
        .route(
            "/reviews/{id}/diff",
            axum::routing::post(workflow::load_diff),
        )
        .route(
            "/reviews/{id}/submit",
            get(workflow::compose).post(workflow::preview),
        )
        .route(
            "/reviews/{id}/publish",
            axum::routing::post(workflow::publish),
        )
        .route(
            "/repositories",
            get(workflow::settings).post(workflow::save_settings),
        )
        .route(
            "/repositories/authorize",
            axum::routing::post(workflow::authorize),
        )
        .fallback(|| async { not_found() })
        .method_not_allowed_fallback(|| async {
            error_page(StatusCode::METHOD_NOT_ALLOWED, "Method not allowed.")
        })
        .with_state(state)
        .layer(middleware::from_fn(local_only)))
}

fn single_header<'a>(headers: &'a HeaderMap, name: &str) -> Result<Option<&'a str>, ()> {
    let mut values = headers.get_all(name).into_iter();
    let value = values
        .next()
        .map(HeaderValue::to_str)
        .transpose()
        .map_err(|_| ())?;
    if values.next().is_some() {
        return Err(());
    }
    Ok(value)
}

fn loopback_host(value: &str) -> Option<(&'static str, u16)> {
    let (host, port) = if let Some(port) = value.strip_prefix("[::1]") {
        ("[::1]", port)
    } else {
        value.split_at(value.find(':').unwrap_or(value.len()))
    };
    let host = match host {
        "127.0.0.1" => "127.0.0.1",
        "[::1]" => "[::1]",
        host if host.eq_ignore_ascii_case("localhost") => "localhost",
        _ => return None,
    };
    let port = if port.is_empty() {
        80
    } else {
        let port = port.strip_prefix(':')?;
        if !port.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        port.parse::<u16>().ok()?
    };
    (port != 0).then_some((host, port))
}

async fn local_only(request: Request, next: Next) -> Response {
    let mut response = if single_header(request.headers(), "host")
        .ok()
        .flatten()
        .and_then(loopback_host)
        .is_some()
    {
        next.run(request).await
    } else {
        error_page(StatusCode::FORBIDDEN, "Open Jidoka using localhost.")
    };
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        ),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

fn same_origin(headers: &HeaderMap) -> bool {
    let (Ok(origin), Ok(referer), Ok(fetch_site)) = (
        single_header(headers, "origin"),
        single_header(headers, "referer"),
        single_header(headers, "sec-fetch-site"),
    ) else {
        return false;
    };
    if matches!(fetch_site, Some("cross-site" | "same-site")) {
        return false;
    }
    let Some(source) = origin.or(referer) else {
        return true;
    };
    let Some((scheme, rest)) = source.split_once("://") else {
        return false;
    };
    // The pilot serves HTTP directly on loopback.
    if !scheme.eq_ignore_ascii_case("http") {
        return false;
    }
    let authority = if origin.is_some() {
        rest
    } else {
        rest.split(['/', '?', '#']).next().unwrap_or_default()
    };
    let expected = single_header(headers, "host")
        .ok()
        .flatten()
        .and_then(loopback_host);
    expected.is_some() && expected == loopback_host(authority)
}

fn csrf_cookie(headers: &HeaderMap) -> Option<&str> {
    let mut cookies = single_header(headers, "cookie")
        .ok()??
        .split(';')
        .filter_map(|part| part.trim().strip_prefix("jidoka_csrf="));
    let cookie = cookies.next()?;
    if cookies.next().is_some() || cookie.len() != 43 || URL_SAFE_NO_PAD.decode(cookie).is_err() {
        return None;
    }
    Some(cookie)
}

fn token_mac(secret: &[u8; 32], cookie: &str) -> TokenMac {
    let mut mac = TokenMac::new_from_slice(secret).expect("HMAC accepts a 32-byte key");
    mac.update(cookie.as_bytes());
    mac
}

fn form_token(secret: &[u8; 32], cookie: &str) -> String {
    hex::encode(token_mac(secret, cookie).finalize().into_bytes())
}

fn parse_pull_url(value: &str) -> Option<(&str, &str)> {
    let value = value.trim();
    if value.len() > 2048
        || value
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return None;
    }
    let (scheme, rest) = value.split_once("://")?;
    let (host, path) = rest.split_once('/')?;
    if !scheme.eq_ignore_ascii_case("https") || !host.eq_ignore_ascii_case("github.com") {
        return None;
    }
    let path = path.split(['?', '#']).next()?;
    let path = path.strip_suffix('/').unwrap_or(path);
    let (path, number) = path.rsplit_once('/')?;
    let (repo, kind) = path.rsplit_once('/')?;
    if !kind.eq_ignore_ascii_case("pull")
        || !valid_repo(repo)
        || !(1..=10).contains(&number.len())
        || number.starts_with('0')
        || !number.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    Some((repo, number))
}

fn canonical_pull_url(repo: &str, number: &str) -> String {
    format!("https://github.com/{repo}/pull/{number}")
}

struct PageError(StatusCode, String);

impl PageError {
    fn new(status: StatusCode, message: &str) -> Self {
        Self(status, message.to_owned())
    }
    fn missing() -> Self {
        Self::new(StatusCode::NOT_FOUND, "Page not found.")
    }
}

impl IntoResponse for PageError {
    fn into_response(self) -> Response {
        error_page(self.0, &self.1)
    }
}

impl From<StorageError> for PageError {
    fn from(_: StorageError) -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not access reviews. Try again.",
        )
    }
}

struct StorageError;

impl IntoResponse for StorageError {
    fn into_response(self) -> Response {
        PageError::from(self).into_response()
    }
}

async fn with_db<T: Send + 'static>(
    state: &WebState,
    operation: impl FnOnce(Connection) -> rusqlite::Result<T> + Send + 'static,
) -> Result<T, StorageError> {
    let db = state.db.clone();
    tokio::task::spawn_blocking(move || operation(connect(&db)?))
        .await
        .map_err(|_| StorageError)?
        .map_err(|_| StorageError)
}

impl WebState {
    async fn repositories(&self) -> Result<HashSet<String>, StorageError> {
        let configured = self.configured_repos.clone();
        with_db(self, move |conn| {
            crate::automation::repositories(&conn, &configured)
        })
        .await
    }
}

async fn home(
    State(state): State<Arc<WebState>>,
    headers: HeaderMap,
) -> Result<Response, StorageError> {
    let (token, cookie) = page_token(&state, &headers);
    let html = home_page(&state, &token, "", "").await?;
    Ok(form_page(html, cookie))
}

fn page_token(state: &WebState, headers: &HeaderMap) -> (String, Option<String>) {
    if let Some(cookie) = csrf_cookie(headers) {
        return (form_token(&state.secret, cookie), None);
    }
    let cookie = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
    (form_token(&state.secret, &cookie), Some(cookie))
}

fn form_page(html: String, cookie: Option<String>) -> Response {
    let mut response = Html(html).into_response();
    if let Some(cookie) = cookie {
        let value = format!("{CSRF_COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Strict");
        response
            .headers_mut()
            .insert(header::SET_COOKIE, value.parse().unwrap());
    }
    response
}

async fn checked_form(
    state: &WebState,
    request: Request,
    max_fields: usize,
) -> Result<HashMap<String, String>, PageError> {
    let Some(cookie) = csrf_cookie(request.headers()).filter(|_| same_origin(request.headers()))
    else {
        return Err(PageError::new(StatusCode::FORBIDDEN, FORBIDDEN));
    };
    let mac = token_mac(&state.secret, cookie);
    let content_type = single_header(request.headers(), "content-type")
        .ok()
        .flatten();
    if !content_type.is_some_and(|value| {
        value
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .eq_ignore_ascii_case("application/x-www-form-urlencoded")
    }) {
        return Err(PageError::new(StatusCode::UNSUPPORTED_MEDIA_TYPE, BAD_FORM));
    }
    let Ok(body) = to_bytes(request.into_body(), FORM_LIMIT).await else {
        return Err(PageError::new(StatusCode::PAYLOAD_TOO_LARGE, BAD_FORM));
    };
    if std::str::from_utf8(&body).is_err() {
        return Err(PageError::new(StatusCode::BAD_REQUEST, BAD_FORM));
    }
    let mut fields = HashMap::new();
    for (name, value) in url::form_urlencoded::parse(&body) {
        if fields.len() == max_fields
            || fields
                .insert(name.into_owned(), value.into_owned())
                .is_some()
        {
            return Err(PageError::new(StatusCode::BAD_REQUEST, BAD_FORM));
        }
    }
    let token = fields.get("csrf_token").map_or("", |value| value.as_ref());
    let form_csrf = hex::decode(token).ok();
    if !form_csrf.is_some_and(|value| mac.verify_slice(&value).is_ok()) {
        return Err(PageError::new(StatusCode::FORBIDDEN, FORBIDDEN));
    }

    Ok(fields)
}

async fn submit(
    State(state): State<Arc<WebState>>,
    request: Request,
) -> Result<Response, StorageError> {
    let fields = match checked_form(&state, request, 8).await {
        Ok(fields) => fields,
        Err(error) => return Ok(error.into_response()),
    };
    let token = &fields["csrf_token"];
    let value = fields.get("url").map_or("", |value| value.as_ref());
    let consent = fields.get("consent").is_some_and(|value| value == "yes");
    let message = match (consent, parse_pull_url(value)) {
        (false, _) => "Confirm that the provider may receive the code before starting the review.",
        (true, None) => "Enter the HTTPS URL of a pull request on github.com.",
        (true, Some((repo, _)))
            if !state
                .repositories()
                .await?
                .contains(&repo.to_ascii_lowercase()) =>
        {
            UNAPPROVED
        }
        (true, Some((repo, number))) => {
            let url = canonical_pull_url(repo, number);
            let provider = state.provider.clone();
            let id = with_db(&state, move |connection| {
                connection.execute(
                    "INSERT INTO reviews (url, provider, status) VALUES (?1, ?2, 'queued')",
                    params![url, provider],
                )?;
                Ok(connection.last_insert_rowid())
            })
            .await?;
            let location = format!("/reviews/{id}");
            let html = page(
                "Review queued",
                &format!(r#"<p><a href="{location}">Open the review</a></p>"#),
            );
            return Ok((
                StatusCode::SEE_OTHER,
                [(header::LOCATION, location)],
                Html(html),
            )
                .into_response());
        }
    };
    let html = home_page(&state, token, value, message).await?;
    Ok((StatusCode::BAD_REQUEST, Html(html)).into_response())
}

// A legacy stale error also covered closed and draft PRs. Only call it superseded
// when automation has a review for another revision of the same pull request.
fn replacement_review(connection: &Connection, id: i64) -> rusqlite::Result<Option<i64>> {
    connection.query_row(
        "SELECT next.review_id FROM automation_jobs old
         JOIN automation_jobs next ON next.repo = old.repo AND next.number = old.number AND next.head <> old.head
         LEFT JOIN automation_seen seen ON seen.repo = next.repo AND seen.number = next.number
         WHERE old.review_id = ?1 AND (next.review_id > old.review_id OR next.head = seen.head)
         ORDER BY (next.head = seen.head) DESC, next.review_id DESC LIMIT 1",
        [id], |row| row.get(0),
    ).optional()
}

fn displayed_status<'a>(
    connection: &Connection,
    id: i64,
    status: &'a str,
    error: Option<&str>,
) -> rusqlite::Result<(&'a str, Option<i64>)> {
    if status == "superseded" || (status == "failed" && error == Some(crate::automation::STALE)) {
        let replacement = replacement_review(connection, id)?;
        return Ok((
            if replacement.is_some() || status == "superseded" {
                "superseded"
            } else {
                "canceled"
            },
            replacement,
        ));
    }
    Ok((status, None))
}

async fn review(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
    headers: HeaderMap,
) -> Result<Response, StorageError> {
    let Ok(id) = id.parse::<i64>() else {
        return Ok(not_found());
    };
    if id <= 0 {
        return Ok(not_found());
    }
    let (token, cookie) = page_token(&state, &headers);
    let html = with_db(&state, move |connection| {
        connection.query_row(
            "SELECT url, provider, status, created_at, report, error FROM reviews WHERE id = ?1",
            [id],
            |row| {
                let raw_report: Option<String> = row.get(4)?;
                let error: Option<String> = row.get(5)?;
                let stored: String = row.get(2)?;
                let (status, replacement) = displayed_status(&connection, id, &stored, error.as_deref())?;
                Ok(review_page((id, &token, replacement), &row.get::<_, String>(0)?, &row.get::<_, String>(1)?,
                    status, &row.get::<_, String>(3)?,
                    raw_report.as_deref(), error.as_deref()))
            },
        ).optional()
    })
    .await?;
    Ok(html.map_or_else(not_found, |html| form_page(html, cookie)))
}

fn status_label(status: &str) -> &str {
    match status {
        "queued" => "Queued",
        "running" => "In progress",
        "completed" => "Completed",
        "partial" => "Partial",
        "superseded" => "Superseded",
        "canceled" => "Canceled",
        _ => "Failed",
    }
}

fn escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#x27;"),
            value => escaped.push(value),
        }
    }
    escaped
}

fn page(title: &str, body: &str) -> String {
    format!(
        r##"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{} · Jidoka Code</title><style>{}{}</style></head>
<body><a class="skip" href="#main">Skip to content</a>
<header class="mast"><nav class="wrap nav" aria-label="Main navigation">
<a class="brand" href="/"><span class="mark" aria-hidden="true"><i></i><i></i><i></i></span>Jidoka<span class="brand-code">Code</span></a>
<a class="nav-history" href="/#history">Review history</a><a class="nav-settings" href="/repositories">Repositories</a><a class="nav-new" href="/#new-review"><span aria-hidden="true">+</span> New review</a>
</nav></header><main class="wrap" id="main">{body}</main></body></html>"##,
        escape(title),
        include_str!("review.css"),
        include_str!("diff.css")
    )
}

fn status_badge(status: &str) -> String {
    let tone = match status {
        "completed" => "done",
        "partial" => "partial",
        "canceled" | "superseded" => "inactive",
        "running" | "queued" => "active",
        _ => "failed",
    };
    format!(
        r#"<span class="status {tone}">{}</span>"#,
        status_label(status)
    )
}

fn provider_name(label: &str) -> &str {
    label
        .strip_suffix(')')
        .and_then(|s| s.rsplit_once(" ("))
        .map_or(label, |(_, name)| name)
}

fn error_page(status: StatusCode, message: &str) -> Response {
    let html = page(
        "Error",
        &format!(
            r#"<h1>{}</h1><p><a href="/">Back to the home page</a></p>"#,
            escape(message),
        ),
    );
    (status, Html(html)).into_response()
}

fn not_found() -> Response {
    error_page(StatusCode::NOT_FOUND, "Page not found.")
}

async fn home_page(
    state: &WebState,
    token: &str,
    value: &str,
    error: &str,
) -> Result<String, StorageError> {
    let history = with_db(state, |connection| {
        let mut stmt = connection.prepare(
            "SELECT id, url, status, created_at, CASE WHEN json_valid(report)
                THEN json_array_length(report, '$.findings') END, error
             FROM reviews ORDER BY id DESC",
        )?;
        let mut rows = stmt.query([])?;
        let mut items = String::new();
        while let Some(row) = rows.next()? {
            let id: i64 = row.get(0)?;
            let url: String = row.get(1)?;
            let stored: String = row.get(2)?;
            let error: Option<String> = row.get(5)?;
            let (status, _) = displayed_status(&connection, id, &stored, error.as_deref())?;
            let created: String = row.get(3)?;
            let findings = match row.get::<_, Option<usize>>(4)? {
                Some(1) => " · 1 finding".to_owned(),
                Some(n) => format!(" · {n} findings"),
                None => String::new(),
            };
            let name = parse_pull_url(&url).map_or_else(|| escape(&url), |(repo, number)| {
                format!("{} <b>#{number}</b>", escape(repo))
            });
            write!(
                items,
                r#"<li><a class="history-row" href="/reviews/{id}"><span><strong>{name}</strong>
                <small>Review {id}{findings} · {} UTC</small></span>{}<span class="arrow" aria-hidden="true">→</span></a></li>"#,
                escape(&created), status_badge(status)
            ).unwrap();
        }
        Ok(if items.is_empty() {
            "<p>No reviews yet.</p>".to_owned()
        } else {
            format!(r#"<ul class="history-list">{items}</ul>"#)
        })
    })
    .await?;
    let error = if error.is_empty() {
        String::new()
    } else if error == UNAPPROVED {
        format!(
            r#"<p class="error" role="alert">{UNAPPROVED} <a href="/repositories#authorize">Authorize repository</a></p>"#
        )
    } else {
        format!(r#"<p class="error" role="alert">{}</p>"#, escape(error))
    };
    Ok(page(
        "New review",
        &format!(
            r#"<div class="hero"><h1>Pull request reviews</h1></div>
<div class="workspace home">
<section class="panel history" id="history"><div class="panel-head"><h2>Review history</h2></div>{history}</section>
<section class="panel compose" id="new-review"><div class="panel-head"><h2>New review</h2></div>{error}
<form action="/" method="post">
<input type="hidden" name="csrf_token" value="{token}">
<label for="url">GitHub pull request URL</label>
<input id="url" name="url" type="url" placeholder="https://github.com/owner/repo/pull/123" value="{}" required>
<label class="consent"><input name="consent" type="checkbox" value="yes" required><span>Send this pull request’s code to <strong>{}</strong> for review.</span></label>
<details class="destination"><summary>Provider details</summary><code>{}</code></details>
<button type="submit">Start review <span aria-hidden="true">→</span></button></form></section></div>"#,
            escape(value),
            escape(provider_name(&state.provider)),
            escape(&state.provider),
        ),
    ))
}

fn html_list(tag: &str, items: &str, empty: &str) -> String {
    if items.is_empty() {
        format!("<p>{empty}</p>")
    } else {
        format!("<{tag}>{items}</{tag}>")
    }
}

fn text_list<'a>(values: impl IntoIterator<Item = &'a String>) -> String {
    values
        .into_iter()
        .map(|value| format!("<li>{}</li>", escape(value)))
        .collect()
}

fn position(report: &PublishedReport, path: &str, line: usize) -> String {
    match crate::diff::anchor(report, path, line) {
        Some(anchor) => format!(
            r##"<a href="#{}">{}, line {line}</a>"##,
            escape(&anchor),
            escape(path)
        ),
        None => source_link(report, &report.head, path, line),
    }
}

fn source_link(report: &PublishedReport, head: &str, path: &str, line: usize) -> String {
    let label = format!("{}, line {line}", escape(path));
    if line == 0
        || !valid_repo(&report.repo)
        || head.len() != 40
        || !head.bytes().all(|byte| byte.is_ascii_hexdigit())
        || !safe_path(path)
    {
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
        r#"<a href="https://github.com/{}/blob/{head}/{encoded}#L{line}">{label}</a>"#,
        report.repo
    )
}

fn partial(report: &PublishedReport) -> bool {
    !report.report.limits.is_empty()
        || report
            .scan
            .as_ref()
            .is_some_and(|scan| !scan.limits.is_empty())
}

fn scanner_html(report: &PublishedReport, scan: Option<&Scan>) -> String {
    let Some(scan) = scan else {
        return "<p>No Semgrep coverage data for this review.</p>".to_owned();
    };
    let version = if scan.version.is_empty() {
        "not recorded"
    } else {
        &scan.version
    };
    let files = html_list(
        "ul",
        &text_list(&scan.covered),
        "No files recorded as scanned by Semgrep.",
    );
    let mut signals = String::new();
    for signal in &scan.signals {
        write!(
            signals,
            "<li>{} · {}<br>{}</li>",
            escape(&signal.rule),
            position(report, &signal.path, signal.line),
            escape(&signal.message),
        )
        .unwrap();
    }
    let signals = html_list("ul", &signals, "No Semgrep signals recorded.");
    let coverage = if scan.version.is_empty()
        && scan.covered.is_empty()
        && scan.signals.is_empty()
        && scan.limits.is_empty()
    {
        "<p>No Semgrep rules apply to the available files.</p>"
    } else if scan.limits.is_empty() {
        ""
    } else {
        "<p>Semgrep coverage was limited.</p>"
    };
    let limits = if scan.limits.is_empty() {
        String::new()
    } else {
        format!(
            "<h4>Semgrep limits</h4><ul>{}</ul>",
            text_list(&scan.limits)
        )
    };
    format!(
        "<p>The bundled Semgrep rules cover Python files. Only files that Semgrep scanned are listed.</p>
        <p>Semgrep version <code>{}</code></p>{coverage}
        <h4>Files scanned</h4>{files}
        <h4>Signals to verify</h4>{signals}{limits}",
        escape(version),
    )
}

fn attribution_label(value: &Attribution) -> &'static str {
    match value {
        Attribution::Introduced => "Introduced by the pull request",
        Attribution::Preexisting => "Pre-existing",
        Attribution::Unknown => "Uncertain attribution",
    }
}

fn evidence_html(report: &PublishedReport, evidence: &str) -> String {
    let mut html = String::new();
    let mut prose = Vec::new();
    for line in evidence.lines() {
        let citation = ["Proposed revision ", "Base revision "]
            .iter()
            .find_map(|prefix| {
                let (location, quote) = line.strip_prefix(prefix)?.split_once(" “")?;
                let (path, number) = location.rsplit_once(':')?;
                let n = number.parse::<usize>().ok()?;
                let quote = quote.strip_suffix('”')?;
                Some((prefix.starts_with("Base"), path, n, quote))
            });
        if let Some((base, path, n, quote)) = citation {
            if !prose.is_empty() {
                write!(
                    html,
                    r#"<p class="verbatim">{}</p>"#,
                    escape(&prose.join("\n"))
                )
                .unwrap();
                prose.clear();
            }
            let revision = if base { &report.base } else { &report.head };
            let label = if base { "Base" } else { "Head" };
            write!(html, r#"<figure><figcaption><b>{label}</b> {}</figcaption><pre><code>{}</code></pre></figure>"#,
                source_link(report, revision, path, n), escape(quote)).unwrap();
        } else {
            prose.push(line);
        }
    }
    if !prose.is_empty() {
        write!(
            html,
            r#"<p class="verbatim">{}</p>"#,
            escape(&prose.join("\n"))
        )
        .unwrap();
    }
    html
}

fn finding_card(
    report: &PublishedReport,
    item: &Finding,
    focus: Option<&crate::contracts::Focus>,
) -> String {
    let action = focus.map_or_else(String::new, |f| {
        format!(
            r#"<div class="action"><b>Reviewer action</b><p>{}</p></div>"#,
            escape(&f.action)
        )
    });
    let check = focus.map_or_else(String::new, |f| format!("<p>{}</p>", escape(&f.checked)));
    format!(
        r#"<article class="card"><span class="kind"><i></i>Verified finding</span><h3>{}</h3>
        <div class="location">{}</div><p>{}</p>{action}
        <details class="proof"><summary>View evidence</summary><div class="detail-body"><b>{}</b>{check}{}</div></details></article>"#,
        escape(&item.title),
        position(report, &item.path, item.line),
        escape(&item.impact),
        attribution_label(&item.attribution),
        evidence_html(report, &item.evidence)
    )
}

fn report_html(report: &PublishedReport, is_partial: bool) -> String {
    let manual: Vec<_> = report.human_focus().take(3).collect();
    let mut focus = String::new();
    for item in &manual {
        write!(focus,r#"<article class="card manual"><span class="kind"><i></i>Manual check</span><h3>{}</h3><div class="location">{}</div><p>{}</p>
            <details class="proof"><summary>What Jidoka checked</summary><div class="detail-body">{}</div></details></article>"#,
            escape(&item.action),position(report,&item.path,item.line),escape(&item.outcome),evidence_html(report,&item.checked)).unwrap();
    }
    let mut content = format!(
        "<section><h2>Where to focus</h2>{}</section>",
        if focus.is_empty() {
            "<p class=empty>No additional manual checks.</p>".into()
        } else {
            focus
        }
    );
    let mut extra = String::new();
    for item in &report.report.findings {
        // Earlier reports stored the suggested action for a finding in its focus row.
        let suggestion = report.report.focus.iter().find(|focus| {
            focus.path == item.path && focus.line == item.line && focus.outcome == item.impact
        });
        extra.push_str(&finding_card(report, item, suggestion));
    }
    if report.report.findings.is_empty() {
        let empty = if is_partial {
            "No verified findings in the material reviewed."
        } else {
            "No verified findings."
        };
        write!(
            content,
            "<section><h2>Verified findings</h2><p class=empty>{empty}</p></section>"
        )
        .unwrap();
    } else if !extra.is_empty() {
        write!(
            content,
            "<section><h2>Verified findings</h2>{extra}</section>"
        )
        .unwrap();
    }
    let patches = report
        .patch_files
        .as_ref()
        .map_or_else(String::new, |files| {
            format!(
                "<details><summary>Files supplied with a patch ({})</summary>{}</details>",
                files.len(),
                html_list("ul", &text_list(files), "No patches were supplied.")
            )
        });
    let limits = text_list(report.report.limits.iter().filter(|limit| {
        !report
            .scan
            .as_ref()
            .is_some_and(|s| s.limits.contains(limit))
    }));
    let coverage_limits = if limits.is_empty() {
        String::new()
    } else {
        format!("<details><summary>Review limits</summary><ul>{limits}</ul></details>")
    };
    let warnings = if is_partial {
        r##"<div class="warning"><b>Partial coverage</b><a href="#coverage">See coverage details ↓</a></div>"##.to_owned()
    } else {
        String::new()
    };
    let files = report.patch_files.as_ref().map_or_else(String::new, |v| {
        format!("<div><dt>Files with patches</dt><dd>{}</dd></div>", v.len())
    });
    format!(
        r##"<div class="workspace"><div>{warnings}{content}</div>
        <aside><section class="panel inspect"><div class="panel-head"><h2>Review summary</h2></div><dl>
        <div><dt>Verified findings</dt><dd>{}</dd></div><div><dt>Manual checks</dt><dd>{}</dd></div>{files}</dl>
        <details><summary>Git revisions</summary><div class="detail-body"><b>Reviewed revision</b><code>{}</code><b>Base revision</b><code>{}</code></div></details></section>
        <section class="panel inspect" id="coverage"><div class="panel-head"><h2>Review coverage</h2></div>{coverage_limits}{patches}
        <details{scan_open}><summary>Semgrep scan</summary><div class="detail-body">{}</div></details></section></aside></div>"##,
        report.report.findings.len(),
        manual.len(),
        escape(&report.head),
        escape(&report.base),
        scanner_html(report, report.scan.as_ref()),
        scan_open = if report.scan.as_ref().is_some_and(|s| !s.limits.is_empty()) {
            " open"
        } else {
            ""
        }
    )
}

fn review_page(
    (id, token, replacement): (i64, &str, Option<i64>),
    url: &str,
    provider: &str,
    status: &str,
    created: &str,
    raw_report: Option<&str>,
    failure: Option<&str>,
) -> String {
    let (heading, link) = parse_pull_url(url).map_or_else(
        || (format!("Review {id}"), escape(url)),
        |(repo, number)| {
            (
                format!("Pull request <span>#{number}</span>"),
                format!(
                    r#"<a href="{}">{} ↗</a>"#,
                    canonical_pull_url(repo, number),
                    escape(repo)
                ),
            )
        },
    );
    let (status, details) = match status {
        "queued" | "running" => (
            status,
            format!(r#"<p><a href="/reviews/{id}">Refresh status</a></p>"#),
        ),
        "superseded" => (
            status,
            replacement.map_or_else(|| "<p>A newer revision replaced this review.</p>".into(),
                |next| format!(r#"<p>A newer revision replaced this review. <a href="/reviews/{next}">View replacement review #{next}</a></p>"#)),
        ),
        "canceled" => (status, "<p>This pull request was no longer eligible for automatic review.</p>".into()),
        "completed" | "partial" => {
            match raw_report.and_then(|raw| serde_json::from_str::<PublishedReport>(raw).ok()) {
                Some(report) => {
                    let load = if crate::diff::available(&report) {
                        String::new()
                    } else {
                        format!(
                            r#"<form method="post" class="archive" action="/reviews/{id}/diff"><input type="hidden" name="csrf_token" value="{token}"><button>Load reviewed diff from GitHub</button></form>"#
                        )
                    };
                    let details = format!(
                        r##"<nav class="review-tools" aria-label="Review actions"><a href="#review-diff">View diff</a><a class="primary-link" href="/reviews/{id}/submit">Submit review</a></nav>{}{}{load}"##,
                        report_html(&report, status == "partial"),
                        crate::diff::render(&report)
                    );
                    (status, details)
                }
                None => ("failed", failure_html(None)),
            }
        }
        _ => ("failed", failure_html(failure)),
    };
    page(
        &format!("Review {id}"),
        &format!(
            r##"<div class="hero"><div class="trail"><a href="/#history">Review history</a><span>/</span>Review {id}</div>
<div class="title-line"><h1>{heading}</h1>{}</div>
<div class="meta">{link}<span>·</span>{} UTC<span>·</span>{}</div></div>{details}"##,
            status_badge(status),
            escape(created),
            escape(provider_name(provider)),
        ),
    )
}

fn failure_html(stored: Option<&str>) -> String {
    // Localize known service messages on read. The database may contain older Italian text.
    let rate_limit = GitHubRateLimit.to_string();
    let message = match stored {
        Some(
            INTERRUPTED
            | "L’analisi è stata interrotta prima della fine. Invia di nuovo la PR per riprovare.",
        ) => INTERRUPTED,
        Some(
            PROVIDER_CHANGED
            | "Il provider è cambiato. Invia di nuovo la PR per confermare il destinatario.",
        ) => PROVIDER_CHANGED,
        Some("Quota GitHub esaurita. Riprova dopo il rinnovo della quota.") => &rate_limit,
        Some(message) if message == rate_limit => &rate_limit,
        _ => FAILED,
    };
    format!(r#"<p class="error" role="alert">{}</p>"#, escape(message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::{Finding, Focus, Report, Signal};
    use anyhow::anyhow;
    use axum::{body::Body, http::Method};
    use std::sync::{
        Barrier,
        atomic::{AtomicUsize, Ordering},
    };
    use tempfile::TempDir;
    use tower::ServiceExt;

    const HOST: &str = "127.0.0.1:8080";
    const ORIGIN: &str = "http://127.0.0.1:8080";
    const URL: &str = "https://github.com/test/demo/pull/7";
    const SECOND_URL: &str = "https://github.com/test/demo/pull/8";
    const PROVIDER: &str = "synthetic provider <model>";
    const RATE_LIMIT_MESSAGE: &str =
        "GitHub API rate limit reached. Try again after the limit resets.";

    fn assert_history_row(html: &str, link: &str, repo: &str, number: &str, status: &str) {
        let (_, row) = html
            .split_once(&format!(r#"class="history-row" href="{link}">"#))
            .unwrap();
        let (row, _) = row.split_once("</a>").unwrap();
        assert!(row.contains(&format!("{repo} <b>#{number}</b>")));
        assert!(row.contains(&format!(">{status}</span>")));
    }

    #[test]
    fn priority_and_matching_finding_share_a_card_with_pinned_evidence() {
        let mut report = report(None);
        let path = "src/task.rs";
        report.report.findings.push(Finding {
            title: "An update drops pending work".into(),
            path: path.into(),
            line: 2,
            impact: "A job can be lost.".into(),
            evidence: format!("Base revision {path}:9 “queue.wait();”"),
            attribution: Attribution::Introduced,
        });
        report.report.focus.push(Focus {
            path: path.into(),
            line: 2,
            outcome: "A job can be lost.".into(),
            checked: "Checked pending jobs.".into(),
            action: "Repeat the update with a pending job.".into(),
        });
        let html = report_html(&report, false);
        assert_eq!(html.matches("<article").count(), 1);
        assert!(html.contains("Repeat the update with a pending job."));
        assert!(html.contains(&format!("/blob/{}/{path}#L9", report.base)));
        assert!(html.contains("<code>queue.wait();</code>"));
    }

    struct Fixture {
        _tmp: TempDir,
        db: PathBuf,
        app: Router,
    }

    impl Fixture {
        fn new() -> Self {
            let tmp = tempfile::tempdir().unwrap();
            let db = tmp.path().join("reviews.sqlite3");
            let app = router(&db, PROVIDER, &allowed_repos()).unwrap();
            Self { _tmp: tmp, db, app }
        }

        async fn request(
            &self,
            method: Method,
            path: &str,
            headers: &[(&str, &str)],
            body: impl Into<Body>,
        ) -> (StatusCode, HeaderMap, String) {
            let mut request = Request::builder().method(method).uri(path);
            if !headers
                .iter()
                .any(|(name, _)| name.eq_ignore_ascii_case("host"))
            {
                request = request.header(header::HOST, HOST);
            }
            for (name, value) in headers {
                request = request.header(*name, *value);
            }
            let response = self
                .app
                .clone()
                .oneshot(request.body(body.into()).unwrap())
                .await
                .unwrap();
            let (parts, body) = response.into_parts();
            let html =
                String::from_utf8(to_bytes(body, 1_000_000).await.unwrap().to_vec()).unwrap();
            (parts.status, parts.headers, html)
        }

        async fn get(&self, path: &str) -> String {
            let (status, _, html) = self.request(Method::GET, path, &[], "").await;
            assert_eq!(status, StatusCode::OK, "{html}");
            html
        }

        async fn form(&self) -> (String, String) {
            let (status, headers, html) = self.request(Method::GET, "/", &[], "").await;
            assert_eq!(status, StatusCode::OK);
            let cookie = headers[header::SET_COOKIE].to_str().unwrap();
            assert!(cookie.contains("HttpOnly; SameSite=Strict"));
            let cookie = cookie.split(';').next().unwrap().to_owned();
            let token = html
                .split_once(r#"name="csrf_token" value=""#)
                .unwrap()
                .1
                .split('"')
                .next()
                .unwrap()
                .to_owned();
            (cookie, token)
        }

        async fn post(
            &self,
            cookie: &str,
            body: String,
            mut extra: Vec<(&str, &str)>,
        ) -> (StatusCode, HeaderMap, String) {
            extra.extend([
                ("cookie", cookie),
                ("content-type", "application/x-www-form-urlencoded"),
            ]);
            self.request(Method::POST, "/", &extra, body).await
        }

        async fn enqueue(&self, url: &str) -> String {
            let (cookie, token) = self.form().await;
            let (status, headers, html) = self
                .post(
                    &cookie,
                    form_body(&token, url, Some("yes")),
                    vec![("origin", ORIGIN)],
                )
                .await;
            assert_eq!(status, StatusCode::SEE_OTHER, "{html}");
            headers[header::LOCATION].to_str().unwrap().to_owned()
        }
    }

    #[tokio::test]
    async fn github_review_preview_binds_the_event_and_selected_findings() {
        let f = Fixture::new();
        let path = f.enqueue(URL).await;
        let mut r = report(None);
        for title in ["First selected finding", "Second unselected finding"] {
            r.report.findings.push(Finding {
                title: title.into(),
                path: "readme.md".into(),
                line: 1,
                impact: "An operation fails.".into(),
                evidence: "A fixture confirms the failure.".into(),
                attribution: Attribution::Introduced,
            });
        }
        run_one(&f.db, |_| Ok(r)).unwrap();
        let edit = format!("{path}/submit");
        assert!(f.get(&edit).await.contains("Preview review"));
        let (cookie, token) = f.form().await;
        let headers = [
            ("cookie", cookie.as_str()),
            ("origin", ORIGIN),
            ("content-type", "application/x-www-form-urlencoded"),
        ];
        let body = format!("csrf_token={token}&event=COMMENT&finding-0=yes");
        let (status, _, preview) = f.request(Method::POST, &edit, &headers, body.clone()).await;
        assert_eq!(status, StatusCode::OK, "{preview}");
        assert!(preview.contains("First selected finding"));
        assert!(!preview.contains("Second unselected finding"));
        let signature = preview
            .split_once("name=\"preview\" value=\"")
            .unwrap()
            .1
            .split('"')
            .next()
            .unwrap();
        let publish = format!("{path}/publish");
        for fields in [
            body.clone(),
            format!("csrf_token={token}&event=APPROVE&finding-0=yes&preview={signature}"),
            format!("{body}&finding-1=yes&preview={signature}"),
        ] {
            let (status, _, _) = f.request(Method::POST, &publish, &headers, fields).await;
            assert_eq!(status, StatusCode::CONFLICT);
        }
        let (status, _, _) = f.request(Method::POST, &publish, &[], body).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn repository_forms_default_to_manual_and_enforce_the_allowlist() {
        let f = Fixture::new();
        let (cookie, token) = f.form().await;
        let html = f.get("/repositories").await;
        assert!(html.contains("value=\"manual\" selected"));
        let headers = [
            ("cookie", cookie.as_str()),
            ("origin", ORIGIN),
            ("content-type", "application/x-www-form-urlencoded"),
        ];
        for (repo, status) in [
            ("test/demo", StatusCode::SEE_OTHER),
            ("outside/other", StatusCode::NOT_FOUND),
        ] {
            let body = format!("csrf_token={token}&repo={repo}&mode=manual");
            assert_eq!(
                f.request(Method::POST, "/repositories", &headers, body)
                    .await
                    .0,
                status
            );
        }
    }

    #[tokio::test]
    async fn authorize_from_empty_install_and_use_repository_after_restart() {
        let mut f = Fixture::new();
        let empty = HashSet::new();
        f.app = router(&f.db, PROVIDER, &empty).unwrap();
        let (cookie, token) = f.form().await;
        let headers = [
            ("cookie", cookie.as_str()),
            ("origin", ORIGIN),
            ("content-type", "application/x-www-form-urlencoded"),
        ];
        let path = "/repositories/authorize";
        let body = format!("csrf_token={token}&repo=HTTPS://GitHub.com/Acme/Tools.GIT/");
        assert_eq!(
            f.request(Method::POST, path, &[], body.clone()).await.0,
            StatusCode::FORBIDDEN
        );
        for invalid in [
            "https://evil.example/acme/tools",
            "acme/tools/pull/1",
            "owner/..",
            "acme/.git",
            "acme/tools.git.git",
        ] {
            let (status, _, html) = f
                .request(
                    Method::POST,
                    path,
                    &headers,
                    format!("csrf_token={token}&repo={invalid}"),
                )
                .await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert!(html.contains("Enter owner/repository"));
        }
        assert!(
            crate::automation::repositories_at(&f.db, &empty)
                .unwrap()
                .is_empty()
        );
        let url = "https://github.com/acme/tools/pull/1";
        let blocked = f
            .post(
                &cookie,
                form_body(&token, url, Some("yes")),
                vec![("origin", ORIGIN)],
            )
            .await;
        assert_eq!(blocked.0, StatusCode::BAD_REQUEST);
        assert!(blocked.2.contains("/repositories#authorize"));
        let conn = connect(&f.db).unwrap();
        conn.execute(
            "INSERT INTO automation_settings (repo, mode) VALUES ('acme/tools','inline')",
            [],
        )
        .unwrap();
        let (status, redirect, _) = f.request(Method::POST, path, &headers, body.clone()).await;
        assert_eq!(status, StatusCode::SEE_OTHER);
        assert_eq!(redirect[header::LOCATION], "/repositories#repo-acme/tools");
        assert_eq!(
            crate::automation::mode(&conn, "acme/tools").unwrap(),
            "manual"
        );
        assert_eq!(f.enqueue(url).await, "/reviews/1");
        assert!(
            crate::automation::repositories_at(&f.db, &empty)
                .unwrap()
                .contains("acme/tools")
        );
        conn.execute(
            "UPDATE automation_settings SET mode='summary' WHERE repo='acme/tools'",
            [],
        )
        .unwrap();
        assert_eq!(
            f.request(
                Method::POST,
                path,
                &headers,
                format!("csrf_token={token}&repo=Acme/Tools.git")
            )
            .await
            .0,
            StatusCode::SEE_OTHER
        );
        f.app = router(&f.db, PROVIDER, &empty).unwrap();
        assert_eq!(
            crate::automation::repositories_at(&f.db, &empty)
                .unwrap()
                .len(),
            1
        );
        let page = f.get("/repositories").await;
        assert_eq!(page.matches("<h2>acme/tools</h2>").count(), 1);
        assert!(page.contains(r#"value="summary" selected"#));
        assert_eq!(f.enqueue(url).await, "/reviews/2");
    }

    #[test]
    fn constructing_another_router_preserves_the_running_provider() {
        let f = Fixture::new();
        recover(&f.db, PROVIDER).unwrap();
        let conn = connect(&f.db).unwrap();
        conn.execute(
            "INSERT INTO automation_settings(repo,mode) VALUES ('test/demo','summary')",
            [],
        )
        .unwrap();
        let _unused_router = router(&f.db, "other provider", &allowed_repos()).unwrap();
        assert_eq!(
            crate::automation::mode(&conn, "test/demo").unwrap(),
            "summary"
        );
    }

    #[test]
    fn automatic_queue_passes_the_pinned_head_and_rejects_a_mismatch() {
        let f = Fixture::new();
        let conn = connect(&f.db).unwrap();
        conn.execute(
            "INSERT INTO reviews(url,provider,status) VALUES (?1,?2,'queued')",
            [URL, PROVIDER],
        )
        .unwrap();
        let id = conn.last_insert_rowid();
        let expected = "a".repeat(40);
        conn.execute(
            "INSERT INTO automation_jobs(repo,number,head,review_id) VALUES ('test/demo',7,?1,?2)",
            params![expected, id],
        )
        .unwrap();
        run_one_pinned(&f.db, |_, head| {
            assert_eq!(head, Some(expected.as_str()));
            Ok(report(None))
        })
        .unwrap();
        let stored: (String, Option<String>) = conn
            .query_row("SELECT status,report FROM reviews WHERE id=?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(stored, ("failed".to_owned(), None));
    }

    fn form_body(token: &str, url: &str, consent: Option<&str>) -> String {
        let mut body = url::form_urlencoded::Serializer::new(String::new());
        body.append_pair("csrf_token", token)
            .append_pair("url", url);
        if let Some(consent) = consent {
            body.append_pair("consent", consent);
        }
        body.finish()
    }

    fn allowed_repos() -> HashSet<String> {
        HashSet::from(["TEST/Demo".to_owned()])
    }

    fn report(scan: Option<Scan>) -> PublishedReport {
        PublishedReport {
            repo: "test/demo".into(),
            base: "a".repeat(40),
            head: "b".repeat(40),
            report: Report::default(),
            patch_files: None,
            diff: None,
            scan,
        }
    }

    #[test]
    fn repeat_review_only_reads_findings_for_the_same_pr_revisions_and_provider() {
        let fixture = Fixture::new();
        let db = connect(&fixture.db).unwrap();
        let snapshot = Snapshot {
            repo: "test/demo".into(),
            url: URL.into(),
            number: 7,
            base: "a".repeat(40),
            head: "b".repeat(40),
            intent: vec![],
            files: vec![],
            head_context: vec![],
            limits: vec![],
            diff: None,
        };
        for (url, provider, base, head, title) in [
            (
                URL,
                PROVIDER,
                &snapshot.base[..],
                &snapshot.head[..],
                "Existing concern",
            ),
            (
                SECOND_URL,
                PROVIDER,
                &snapshot.base,
                &snapshot.head,
                "Other PR",
            ),
            (
                URL,
                "another provider",
                &snapshot.base,
                &snapshot.head,
                "Other provider",
            ),
            (URL, PROVIDER, "other base", &snapshot.head, "Other base"),
            (URL, PROVIDER, &snapshot.base, "other head", "Other head"),
            (URL, PROVIDER, &snapshot.base, &snapshot.head, ""),
        ] {
            let mut old = report(None);
            old.repo = snapshot.repo.clone();
            old.base = base.into();
            old.head = head.into();
            if !title.is_empty() {
                old.report.findings.push(Finding {
                    path: "worker.rs".into(),
                    line: 4,
                    title: title.into(),
                    impact: "A job can be lost.".into(),
                    evidence: "Pinned code.".into(),
                    attribution: Attribution::Unknown,
                });
            }
            db.execute(
                "INSERT INTO reviews (url,provider,status,report) VALUES (?1,?2,'partial',?3)",
                params![url, provider, serde_json::to_string(&old).unwrap()],
            )
            .unwrap();
        }
        let prior = previous_findings(&fixture.db, PROVIDER, &snapshot).unwrap();
        assert_eq!(prior.len(), 1);
        assert_eq!(prior[0].title, "Existing concern");
    }

    #[tokio::test]
    async fn moved_head_before_poll_finishes_without_a_retry_or_repository_error() {
        let fixture = Fixture::new();
        let db = connect(&fixture.db).unwrap();
        let url = fixture.enqueue(URL).await;
        let id: i64 = url.rsplit('/').next().unwrap().parse().unwrap();
        db.execute("INSERT INTO automation_jobs(repo,number,head,review_id,state) VALUES ('test/demo',7,'old',?1,'pending')", [id]).unwrap();
        db.execute("INSERT INTO automation_settings(repo,mode,review_error_job,review_error) VALUES ('test/demo','summary',?1,'Earlier retry')", [id]).unwrap();
        assert!(
            run_one_pinned(&fixture.db, |_, head| {
                assert_eq!(head, Some("old"));
                Err(crate::source::HeadChanged("Head moved").into())
            })
            .unwrap()
        );
        let state: String = db
            .query_row(
                "SELECT state FROM automation_jobs WHERE review_id=?1",
                [id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(state, "canceled");
        assert!(fixture.get(&url).await.contains("Superseded"));
        assert!(
            crate::automation::last_error(&db, "test/demo")
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn legacy_stale_reviews_link_to_the_replacement_for_that_pr_only() {
        let fixture = Fixture::new();
        let db = connect(&fixture.db).unwrap();
        for (id, number, head, state) in [
            (20, 7, "a", "canceled"),
            (21, 7, "b", "pending"),
            (22, 8, "c", "canceled"),
        ] {
            db.execute(
                "INSERT INTO reviews (id,url,provider,status,error) VALUES (?1,?2,?3,?4,?5)",
                params![
                    id,
                    canonical_pull_url("test/demo", &number.to_string()),
                    PROVIDER,
                    if state == "canceled" {
                        "failed"
                    } else {
                        "queued"
                    },
                    crate::automation::STALE
                ],
            )
            .unwrap();
            db.execute("INSERT INTO automation_jobs(repo,number,head,review_id,state) VALUES ('test/demo',?1,?2,?3,?4)",
                params![number,head,id,state]).unwrap();
        }
        let old = fixture.get("/reviews/20").await;
        assert!(old.contains("Superseded") && old.contains(r#"href="/reviews/21""#));
        assert!(!old.contains("Failed"));
        let closed = fixture.get("/reviews/22").await;
        assert!(closed.contains("Canceled") && !closed.contains(r#"href="/reviews/21""#));
        assert_history_row(
            &fixture.get("/").await,
            "/reviews/20",
            "test/demo",
            "7",
            "Superseded",
        );
    }

    #[test]
    fn an_earlier_finding_without_a_surviving_line_is_only_a_question() {
        let mut old = report(None);
        old.report.findings.push(Finding {
            path: "check.yml".into(),
            line: 117,
            title: "A test is omitted".into(),
            impact: "Example".into(),
            evidence: "Obsolete proof".into(),
            attribution: Attribution::Unknown,
        });
        let mut current = Snapshot {
            repo: old.repo.clone(),
            base: old.base.clone(),
            head: "c".repeat(40),
            url: URL.into(),
            number: 7,
            intent: vec![],
            limits: vec![],
            head_context: vec![],
            diff: None,
            files: vec![],
        };
        add_previous_questions(&old, &mut current);
        assert_eq!(current.intent.len(), 1);
        let hint = &current.intent[0];
        assert!(hint.contains("A test is omitted") && hint.contains("check.yml"));
        assert!(!hint.contains("117") && !hint.contains("Obsolete proof"));
        current.base = "d".repeat(40);
        add_previous_questions(&old, &mut current);
        assert_eq!(current.intent.len(), 1);
    }

    #[tokio::test]
    async fn checks_loopback_host_on_all_routes() {
        let fixture = Fixture::new();
        for host in ["localhost", "LOCALHOST:8080", "127.0.0.1", "[::1]:8080"] {
            let (status, _, _) = fixture
                .request(Method::GET, "/", &[("host", host)], "")
                .await;
            assert_eq!(status, StatusCode::OK, "{host}");
        }
        for host in [
            "example.test",
            "localhost.example.test",
            "localhost:0",
            "localhost:",
            "localhost:+80",
            "localhost:65536",
            "localhost/",
            "localhost@127.0.0.1",
            "localhost:80,localhost",
            "[::1]suffix",
        ] {
            let (status, headers, example) = fixture
                .request(
                    Method::GET,
                    "/reviews/1",
                    &[("host", host), ("x-forwarded-host", "localhost")],
                    "",
                )
                .await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{host}");
            assert_eq!(headers[header::CACHE_CONTROL], "no-store");
            assert!(example.contains("Open Jidoka using localhost."));
        }
        let response = fixture
            .app
            .clone()
            .oneshot(Request::new(Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let (status, _, _) = fixture
            .request(
                Method::GET,
                "/",
                &[("host", "localhost"), ("host", HOST)],
                "",
            )
            .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn rejects_cross_origin_requests_even_with_valid_token() {
        let fixture = Fixture::new();
        let (cookie, token) = fixture.form().await;
        let body = form_body(&token, URL, Some("yes"));
        for headers in [
            vec![("origin", "http://localhost:8080")],
            vec![("origin", "http://127.0.0.1:8081")],
            vec![("origin", "https://127.0.0.1:8080")],
            vec![("origin", "null")],
            vec![("origin", ORIGIN), ("origin", ORIGIN)],
            vec![("referer", "https://other.example/form")],
            vec![("sec-fetch-site", "cross-site")],
            vec![("sec-fetch-site", "same-site")],
        ] {
            let (status, _, html) = fixture.post(&cookie, body.clone(), headers).await;
            assert_eq!(status, StatusCode::FORBIDDEN);
            assert!(html.contains("Form submission was blocked"));
        }
        let (other_cookie, _) = fixture.form().await;
        for cookie in ["", &other_cookie] {
            let (status, _, _) = fixture.post(cookie, body.clone(), vec![]).await;
            assert_eq!(status, StatusCode::FORBIDDEN);
        }
        let (status, _, _) = fixture
            .post(&cookie, form_body("", URL, Some("yes")), vec![])
            .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert!(!run_one(&fixture.db, |_| panic!("rejected requests cannot enqueue")).unwrap());
        let (_, headers, html) = fixture
            .request(Method::GET, "/", &[("cookie", &cookie)], "")
            .await;
        assert!(headers.get(header::SET_COOKIE).is_none());
        assert!(html.contains(&token));
        let referer = format!("{ORIGIN}/");
        let (status, _, _) = fixture
            .post(&cookie, body, vec![("referer", &referer)])
            .await;
        assert_eq!(status, StatusCode::SEE_OTHER);
    }

    #[tokio::test]
    async fn validates_form_consent_body_and_pr_url() {
        let fixture = Fixture::new();
        let html = fixture.get("/").await;
        assert!(html.contains(r#"lang="en""#));
        assert!(html.contains("synthetic provider &lt;model&gt;"));
        assert!(html.contains(r#"name="consent" type="checkbox" value="yes" required"#));
        let (cookie, token) = fixture.form().await;
        let (status, _, html) = fixture
            .post(&cookie, form_body(&token, URL, None), vec![])
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(html.contains("Confirm that the provider may receive the code"));
        for url in [
            "http://github.com/test/demo/pull/7",
            "https://github.com.example/test/demo/pull/7",
            "https://github.com@other.example/test/demo/pull/7",
            "https://github.com/test/../pull/7",
            "https://github.com/test/demo/issues/7",
            "https://github.com/test/demo/pull/0",
            r#""><script>alert(1)</script>"#,
        ] {
            let (status, _, html) = fixture
                .post(&cookie, form_body(&token, url, Some("yes")), vec![])
                .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{url}");
            assert!(html.contains("Enter the HTTPS URL"));
            assert!(!html.contains("<script>"));
        }
        let valid = form_body(&token, URL, Some("yes"));
        let (status, _, _) = fixture
            .post(&cookie, format!("{valid}&consent=yes"), vec![])
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _, _) = fixture
            .post(&cookie, "a".repeat(FORM_LIMIT + 1), vec![])
            .await;
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
        let (status, _, _) = fixture
            .request(
                Method::POST,
                "/",
                &[("cookie", &cookie), ("content-type", "text/plain")],
                valid,
            )
            .await;
        assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
        assert!(!run_one(&fixture.db, |_| panic!("invalid request cannot enqueue")).unwrap());
    }

    #[tokio::test]
    async fn rejects_unlisted_repository_before_it_reaches_history_or_queue() {
        let fixture = Fixture::new();
        let (cookie, token) = fixture.form().await;
        let unlisted = "https://github.com/test/demo-fork/pull/7";
        let (status, headers, html) = fixture
            .post(
                &cookie,
                form_body(&token, unlisted, Some("yes")),
                vec![("origin", ORIGIN)],
            )
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(headers.get(header::LOCATION).is_none());
        assert!(html.contains("This repository is not approved for review."));
        assert!(html.contains(unlisted));
        let history = fixture.get("/").await;
        assert!(history.contains("No reviews yet."));
        assert!(!history.contains(unlisted));
        assert!(!run_one(&fixture.db, |_| panic!("unlisted review cannot dispatch")).unwrap());

        let allowed = "https://github.com/TeSt/dEmO/pull/7";
        let location = fixture.enqueue(allowed).await;
        assert!(fixture.get(&location).await.contains(allowed));
    }

    #[tokio::test]
    async fn processes_one_queued_review_in_order_and_persists_distinct_outcomes() {
        let mut fixture = Fixture::new();
        let first = fixture
            .enqueue(&format!("{URL}?synthetic=1#discussion"))
            .await;
        let second = fixture.enqueue(SECOND_URL).await;
        assert!(fixture.get(&first).await.contains("Queued"));
        fixture.app = router(&fixture.db, PROVIDER, &allowed_repos()).unwrap();
        recover(&fixture.db, PROVIDER).unwrap();
        assert!(
            run_one(&fixture.db, |url| {
                assert_eq!(url, URL);
                let connection = connect(&fixture.db)?;
                let running: String =
                    connection
                        .query_row("SELECT status FROM reviews WHERE id = 1", [], |r| r.get(0))?;
                assert_eq!(running, "running");
                Ok(report(Some(Scan::default())))
            })
            .unwrap()
        );
        let html = fixture.get(&first).await;
        assert!(html.contains("Completed"));
        assert!(html.contains("No verified findings."));
        assert!(html.contains("No Semgrep rules apply"));
        assert!(html.contains("No files recorded as scanned by Semgrep."));
        assert!(fixture.get(&second).await.contains("Queued"));
        assert!(
            run_one(&fixture.db, |url| {
                assert_eq!(url, SECOND_URL);
                Ok(report(Some(Scan {
                    limits: vec!["Scanner unavailable".into()],
                    ..Scan::default()
                })))
            })
            .unwrap()
        );
        let html = fixture.get(&second).await;
        assert!(html.contains("Partial"));
        assert!(html.contains("No verified findings in the material reviewed."));
        assert!(html.contains("Scanner unavailable"));
        assert!(!html.contains("No Semgrep rules apply"));
        assert!(!run_one(&fixture.db, |_| panic!("empty queue cannot dispatch")).unwrap());
        fixture.app = router(&fixture.db, PROVIDER, &allowed_repos()).unwrap();
        let history = fixture.get("/").await;
        assert_history_row(&history, &first, "test/demo", "7", "Completed");
        assert_history_row(&history, &second, "test/demo", "8", "Partial");
    }

    #[tokio::test]
    async fn restart_discards_stale_consent_and_running_jobs_before_dispatch() {
        let mut fixture = Fixture::new();
        let running = fixture.enqueue(URL).await;
        let old_job = fixture.enqueue(SECOND_URL).await;
        let (old_cookie, old_token) = fixture.form().await;
        connect(&fixture.db)
            .unwrap()
            .execute("UPDATE reviews SET status = 'running' WHERE id = 1", [])
            .unwrap();
        assert!(fixture.get(&running).await.contains("In progress"));

        fixture.app = router(&fixture.db, "another provider", &allowed_repos()).unwrap();
        recover(&fixture.db, "another provider").unwrap();
        recover(&fixture.db, "another provider").unwrap();
        assert!(fixture.get(&running).await.contains(INTERRUPTED));
        let html = fixture.get(&old_job).await;
        assert!(html.contains("Failed"));
        assert!(html.contains(PROVIDER_CHANGED));
        assert!(
            !run_one(&fixture.db, |_| panic!(
                "consent was for a different provider"
            ))
            .unwrap()
        );
        let (status, _, _) = fixture
            .post(&old_cookie, form_body(&old_token, URL, Some("yes")), vec![])
            .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        let new_job = fixture.enqueue(URL).await;
        assert!(
            run_one(&fixture.db, |url| {
                assert_eq!(url, URL);
                Ok(report(None))
            })
            .unwrap()
        );
        let html = fixture.get(&new_job).await;
        assert!(html.contains("another provider"));
        assert!(html.contains("Completed"));
    }

    #[tokio::test]
    async fn router_reads_python_database_and_flattened_report() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("python.sqlite3");
        let original = connect(&db).unwrap();
        original
            .execute_batch(
                "CREATE TABLE reviews (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL, provider TEXT NOT NULL, status TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, report TEXT, error TEXT
        )",
            )
            .unwrap();
        let legacy_report = serde_json::json!({
            "repo": "test/demo", "base": "a".repeat(40), "head": "b".repeat(40),
            "focus": [], "limits": ["Copertura originale"],
            "findings": [{
                "path": "test.py", "line": 2, "title": "Python finding", "impact": "Impact",
                "evidence": "Risultato originale <esempio>", "attribution": "preexisting"
            }]
        })
        .to_string();
        let legacy_provider = "Modello storico <test>";
        original.execute(
            "INSERT INTO reviews (id, url, provider, status, created_at, report) VALUES (9, ?1, ?2, 'partial', '2026-11-20 10:00:00', ?3)",
            params![URL, legacy_provider, legacy_report],
        ).unwrap();
        let app = router(&db, PROVIDER, &allowed_repos()).unwrap();
        recover(&db, PROVIDER).unwrap();
        let fixture = Fixture { _tmp: tmp, db, app };
        let html = fixture.get("/reviews/9").await;
        assert!(html.contains(r#"<html lang="en">"#));
        assert!(html.contains("Where to focus"));
        assert!(html.contains("Python finding"));
        assert!(html.contains("Pre-existing"));
        assert!(html.contains("Risultato originale &lt;esempio&gt;"));
        assert!(html.contains("Modello storico &lt;test&gt;"));
        assert!(html.contains("Copertura originale"));
        assert!(html.contains("Partial"));
        assert!(html.contains("2026-11-20 10:00:00 UTC"));
        assert!(html.contains("No Semgrep coverage data for this review."));
        assert!(!html.contains("No Semgrep rules apply"));
        let history = fixture.get("/").await;
        assert_history_row(&history, "/reviews/9", "test/demo", "7", "Partial");
        let stored: (String, String) = original
            .query_row(
                "SELECT report, provider FROM reviews WHERE id = 9",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(stored, (legacy_report, legacy_provider.to_owned()));
        let job = fixture.enqueue(SECOND_URL).await;
        assert_eq!(job, "/reviews/10");
        assert!(run_one(&fixture.db, |_| Ok(report(Some(Scan::default())))).unwrap());
        let raw: String = original
            .query_row("SELECT report FROM reviews WHERE id = 10", [], |r| r.get(0))
            .unwrap();
        let json: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert!(json.get("report").is_none());
        assert!(json.get("focus").unwrap().is_array());
        assert!(json.get("scan").unwrap().is_object());
    }

    #[test]
    fn position_links_decomposed_paths_and_keeps_unsafe_paths_as_text() {
        let report = report(None);
        assert!(
            position(&report, "src/テ\u{3099}ータ.py", 1)
                .contains("/src/%E3%83%86%E3%82%99%E3%83%BC%E3%82%BF.py#L1")
        );
        for path in ["src/.GiT/file.py", "src/a\u{200d}b.py"] {
            assert_eq!(position(&report, path, 1), format!("{path}, line 1"));
        }
    }

    #[tokio::test]
    async fn escapes_report_and_uses_links_at_head_for_findings_and_scanner_leads() {
        let fixture = Fixture::new();
        let location = fixture.enqueue(URL).await;
        let path = r#"src/sample #"<.py"#;
        let mut report = report(Some(Scan {
            version: "1.2.3 <b>".into(),
            covered: vec![path.into()],
            signals: vec![Signal {
                rule: "<rule>".into(),
                path: path.into(),
                line: 28,
                message: "<message>".into(),
            }],
            limits: vec![],
        }));
        report.report.focus = (12..16)
            .map(|line| Focus {
                path: path.into(),
                line,
                checked: "Check".into(),
                outcome: "<outcome>".into(),
                action: "Check that the import completed.".into(),
            })
            .collect();
        report.report.findings = vec![Finding {
            path: "../other".into(),
            line: 2,
            title: "<script>title</script>".into(),
            impact: "Incomplete result".into(),
            evidence: "Line 2\n<evidence>".into(),
            attribution: Attribution::Unknown,
        }];
        assert!(run_one(&fixture.db, |_| Ok(report)).unwrap());
        let html = fixture.get(&location).await;
        assert!(html.find("Where to focus").unwrap() < html.find("Verified findings").unwrap());
        assert!(html.find("Verified findings").unwrap() < html.find("Review coverage").unwrap());
        let link = format!(
            "https://github.com/test/demo/blob/{}/src/sample%20%23%22%3C.py",
            "b".repeat(40)
        );
        for line in [12, 13, 14, 28] {
            assert!(html.contains(&format!(r#"href="{link}#L{line}""#)));
        }
        assert!(!html.contains("#L15"));
        assert!(!html.contains("/../other#L2"));
        assert!(!html.contains("<script>"));
        assert!(html.contains("Line 2\n&lt;evidence&gt;"));
        assert!(html.contains("Uncertain attribution"));
        assert!(html.contains("1.2.3 &lt;b&gt;"));
        assert!(html.contains("Signals to verify"));
        assert!(html.contains("&lt;rule&gt;"));
        assert!(html.contains("&lt;message&gt;"));
        assert!(!html.contains("No Semgrep rules apply"));
    }

    #[tokio::test]
    async fn masks_processor_errors_and_shows_missing_pages() {
        let fixture = Fixture::new();
        let location = fixture.enqueue(URL).await;
        assert!(run_one(&fixture.db, |_| Err(anyhow!("synthetic secret"))).unwrap());
        let html = fixture.get(&location).await;
        assert!(html.contains("Failed"));
        assert!(html.contains(FAILED));
        assert!(!html.contains("synthetic secret"));
        assert!(!html.contains("No verified findings"));
        for url in ["/other", "/reviews/99", "/reviews/9223372036854775808"] {
            assert_eq!(
                fixture.request(Method::GET, url, &[], "").await.0,
                StatusCode::NOT_FOUND
            );
        }
        assert_eq!(
            fixture.request(Method::DELETE, "/", &[], "").await.0,
            StatusCode::METHOD_NOT_ALLOWED
        );
    }

    #[tokio::test]
    async fn renders_only_the_safe_reason_for_github_rate_limits() {
        assert_eq!(GitHubRateLimit.to_string(), RATE_LIMIT_MESSAGE);
        let fixture = Fixture::new();
        let location = fixture.enqueue(URL).await;
        assert!(
            run_one(&fixture.db, |_| {
                Err(anyhow!(GitHubRateLimit).context("private transport detail"))
            })
            .unwrap()
        );
        let html = fixture.get(&location).await;
        assert!(html.contains("Failed"));
        assert!(html.contains(RATE_LIMIT_MESSAGE));
        assert!(!html.contains("private transport detail"));
        assert!(!html.contains(FAILED));
    }

    #[tokio::test]
    async fn localizes_legacy_service_failures_without_rewriting_stored_errors() {
        let fixture = Fixture::new();
        let cases = [
            (
                "L’analisi non è riuscita. Puoi inviare di nuovo la PR dalla pagina iniziale.",
                FAILED,
            ),
            (
                "L’analisi è stata interrotta prima della fine. Invia di nuovo la PR per riprovare.",
                INTERRUPTED,
            ),
            (
                "Il provider è cambiato. Invia di nuovo la PR per confermare il destinatario.",
                PROVIDER_CHANGED,
            ),
            (
                "Quota GitHub esaurita. Riprova dopo il rinnovo della quota.",
                RATE_LIMIT_MESSAGE,
            ),
            ("<script>private stored detail</script>", FAILED),
        ];
        let connection = connect(&fixture.db).unwrap();
        for (original, expected) in cases {
            connection.execute(
                "INSERT INTO reviews (url, provider, status, error) VALUES (?1, ?2, 'failed', ?3)",
                params![URL, PROVIDER, original],
            ).unwrap();
            let id = connection.last_insert_rowid();
            let html = fixture.get(&format!("/reviews/{id}")).await;
            assert!(
                html.contains(expected),
                "Expected {expected:?} for {original:?}"
            );
            assert!(!html.contains(&escape(original)));
            let stored: String = connection
                .query_row("SELECT error FROM reviews WHERE id = ?1", [id], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(stored, original);
        }
    }

    #[tokio::test]
    async fn two_workers_only_claim_a_review_once() {
        let fixture = Fixture::new();
        let job = fixture.enqueue(URL).await;
        let ready = Barrier::new(2);
        let processed = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            let workers: Vec<_> = (0..2)
                .map(|_| {
                    scope.spawn(|| {
                        ready.wait();
                        run_one(&fixture.db, |_| {
                            processed.fetch_add(1, Ordering::Relaxed);
                            Ok(report(None))
                        })
                        .unwrap()
                    })
                })
                .collect();
            assert_eq!(
                workers
                    .into_iter()
                    .filter_map(|worker| worker.join().unwrap().then_some(()))
                    .count(),
                1
            );
        });
        assert_eq!(processed.load(Ordering::Relaxed), 1);
        assert!(fixture.get(&job).await.contains("Completed"));
    }
}
