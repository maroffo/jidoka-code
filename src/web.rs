//! Review pages and the persistent, single-user work queue.

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
    source::safe_path,
};

const FAILED: &str =
    "The review failed. Resubmit the pull request from the home page to try again.";
const INTERRUPTED: &str = "The review was interrupted. Resubmit the pull request to try again.";
const PROVIDER_CHANGED: &str =
    "The provider changed. Resubmit the pull request to confirm the provider.";
const FORBIDDEN: &str = "Form submission was blocked. Open the home page and try again.";
const BAD_FORM: &str = "Could not read the form.";
const FORM_LIMIT: usize = 8192;
const CSRF_COOKIE: &str = "jidoka_csrf";
type TokenMac = Hmac<Sha256>;

struct WebState {
    db: PathBuf,
    provider: String,
    allowed_repos: HashSet<String>,
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
    transaction.commit()?;
    let Some((id, url)) = job else {
        return Ok(false);
    };

    let outcome = process(&url).and_then(|report| {
        let status = if partial(&report) {
            "partial"
        } else {
            "completed"
        };
        Ok((status, serde_json::to_string(&report)?))
    });
    let (status, report, error) = match outcome {
        Ok((status, report)) => (status, Some(report), None),
        Err(error) => {
            let reason = error
                .downcast_ref::<GitHubRateLimit>()
                .map_or_else(|| FAILED.to_owned(), ToString::to_string);
            ("failed", None, Some(reason))
        }
    };
    connection.execute(
        "UPDATE reviews SET status = ?1, report = ?2, error = ?3 WHERE id = ?4 AND status = 'running'",
        params![status, report, error, id],
    )?;
    Ok(true)
}

pub fn router(db: &Path, provider: &str, allowed_repos: &HashSet<String>) -> Result<Router> {
    init_db(&connect(db)?)?;
    let state = Arc::new(WebState {
        db: db.to_owned(),
        provider: provider.to_owned(),
        allowed_repos: allowed_repos
            .iter()
            .map(|repo| repo.to_ascii_lowercase())
            .collect(),
        secret: rand::random(),
    });
    Ok(Router::new()
        .route("/", get(home).post(submit))
        .route("/reviews/{id}", get(review))
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

fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else {
        return false;
    };
    let owner = owner.as_bytes();
    (1..=39).contains(&owner.len())
        && owner[0].is_ascii_alphanumeric()
        && owner
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
        && (1..=100).contains(&name.len())
        && !matches!(name, "." | "..")
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
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

struct StorageError;

impl IntoResponse for StorageError {
    fn into_response(self) -> Response {
        error_page(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not access reviews. Try again.",
        )
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

async fn home(
    State(state): State<Arc<WebState>>,
    headers: HeaderMap,
) -> Result<Response, StorageError> {
    let existing = csrf_cookie(&headers);
    let cookie = match existing {
        Some(cookie) => cookie.to_owned(),
        None => URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>()),
    };
    let token = form_token(&state.secret, &cookie);
    let html = home_page(&state, &token, "", "").await?;
    let mut response = Html(html).into_response();
    if existing.is_none() {
        let cookie = format!("{CSRF_COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Strict");
        response
            .headers_mut()
            .insert(header::SET_COOKIE, cookie.parse().unwrap());
    }
    Ok(response)
}

async fn submit(
    State(state): State<Arc<WebState>>,
    request: Request,
) -> Result<Response, StorageError> {
    let Some(cookie) = csrf_cookie(request.headers()).filter(|_| same_origin(request.headers()))
    else {
        return Ok(error_page(StatusCode::FORBIDDEN, FORBIDDEN));
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
        return Ok(error_page(StatusCode::UNSUPPORTED_MEDIA_TYPE, BAD_FORM));
    }
    let Ok(body) = to_bytes(request.into_body(), FORM_LIMIT).await else {
        return Ok(error_page(StatusCode::PAYLOAD_TOO_LARGE, BAD_FORM));
    };
    if std::str::from_utf8(&body).is_err() {
        return Ok(error_page(StatusCode::BAD_REQUEST, BAD_FORM));
    }
    let mut fields = HashMap::new();
    for (name, value) in url::form_urlencoded::parse(&body) {
        if fields.len() == 8 || fields.insert(name, value).is_some() {
            return Ok(error_page(StatusCode::BAD_REQUEST, BAD_FORM));
        }
    }
    let token = fields.get("csrf_token").map_or("", |value| value.as_ref());
    let form_csrf = hex::decode(token).ok();
    if !form_csrf.is_some_and(|value| mac.verify_slice(&value).is_ok()) {
        return Ok(error_page(StatusCode::FORBIDDEN, FORBIDDEN));
    }

    let value = fields.get("url").map_or("", |value| value.as_ref());
    let consent = fields.get("consent").is_some_and(|value| value == "yes");
    let message = match (consent, parse_pull_url(value)) {
        (false, _) => "Confirm that the provider may receive the code before starting the review.",
        (true, None) => "Enter the HTTPS URL of a pull request on github.com.",
        (true, Some((repo, _))) if !state.allowed_repos.contains(&repo.to_ascii_lowercase()) => {
            "This repository is not approved for review."
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

async fn review(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
) -> Result<Response, StorageError> {
    let Ok(id) = id.parse::<i64>() else {
        return Ok(not_found());
    };
    if id <= 0 {
        return Ok(not_found());
    }
    let html = with_db(&state, move |connection| {
        connection.query_row(
            "SELECT url, provider, status, created_at, report, error FROM reviews WHERE id = ?1",
            [id],
            |row| {
                let raw_report: Option<String> = row.get(4)?;
                let error: Option<String> = row.get(5)?;
                Ok(review_page(id, &row.get::<_, String>(0)?, &row.get::<_, String>(1)?,
                    &row.get::<_, String>(2)?, &row.get::<_, String>(3)?,
                    raw_report.as_deref(), error.as_deref()))
            },
        ).optional()
    })
    .await?;
    Ok(html.map_or_else(not_found, |page| Html(page).into_response()))
}

fn status_label(status: &str) -> &str {
    match status {
        "queued" => "Queued",
        "running" => "In progress",
        "completed" => "Completed",
        "partial" => "Partial",
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
        r#"<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{} · Jidoka Code</title>
<style>
  :root {{ color-scheme: light dark }}
  body {{ font: 1rem/1.55 system-ui, sans-serif; margin: 1.5rem auto; padding: 0 1rem;
          max-width: 48rem; overflow-wrap: anywhere }}
  input, button {{ font: inherit }}
  input[type="url"] {{ box-sizing: border-box; width: 100%; padding: .5rem }}
  button {{ padding: .4rem .9rem }}
  section {{ margin-block: 2rem }}
  li + li {{ margin-top: .65rem }}
  dd {{ margin: 0 0 .4rem }}
  .error {{ border-inline-start: .25rem solid currentColor; padding-inline-start: .75rem }}
  .evidence {{ white-space: pre-wrap }}
</style>
<header><a href="/">Jidoka Code</a></header>
<main>{body}</main>
</html>"#,
        escape(title)
    )
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
        let mut stmt = connection
            .prepare("SELECT id, url, status, created_at FROM reviews ORDER BY id DESC")?;
        let mut rows = stmt.query([])?;
        let mut items = String::new();
        while let Some(row) = rows.next()? {
            write!(
                items,
                r#"<li><a href="/reviews/{}">{}</a> · {} · {} UTC</li>"#,
                row.get::<_, i64>(0)?,
                escape(&row.get::<_, String>(1)?),
                status_label(&row.get::<_, String>(2)?),
                escape(&row.get::<_, String>(3)?),
            )
            .unwrap();
        }
        Ok(html_list("ul", &items, "No reviews yet."))
    })
    .await?;
    let error = if error.is_empty() {
        String::new()
    } else {
        format!(r#"<p class="error" role="alert">{}</p>"#, escape(error))
    };
    Ok(page(
        "New review",
        &format!(
            r#"<h1>New review</h1>
{error}
<form action="/" method="post">
  <input type="hidden" name="csrf_token" value="{token}">
  <label for="url">GitHub pull request URL</label>
  <input id="url" name="url" type="url" value="{}" required>
  <p>The code will be sent to <strong>{}</strong> for review.</p>
  <p><label><input name="consent" type="checkbox" value="yes" required>
    I agree to send the code to this provider.</label></p>
  <button type="submit">Start review</button>
</form>
<section><h2>Review history</h2>{history}</section>"#,
            escape(value),
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
    let label = format!("{}, line {line}", escape(path));
    let head = &report.head;
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

fn report_html(report: &PublishedReport, is_partial: bool) -> String {
    let mut focus = String::new();
    for item in report.report.focus.iter().take(3) {
        write!(
            focus,
            "<li><p>{}</p><dl><dt>Check</dt><dd>{}</dd><dt>Outcome</dt><dd>{}</dd>\
            <dt>Action</dt><dd>{}</dd></dl></li>",
            position(report, &item.path, item.line),
            escape(&item.checked),
            escape(&item.outcome),
            escape(&item.action),
        )
        .unwrap();
    }
    let focus = html_list("ol", &focus, "No focus areas identified.");
    let mut findings = String::new();
    for item in &report.report.findings {
        let attribution = match item.attribution {
            Attribution::Introduced => "Introduced by the pull request",
            Attribution::Preexisting => "Pre-existing",
            Attribution::Unknown => "Uncertain attribution",
        };
        write!(
            findings,
            r#"<li><h3>{}</h3><p>{} · {attribution}</p>
            <dl><dt>Impact</dt><dd>{}</dd><dt>Evidence</dt><dd class="evidence">{}</dd></dl></li>"#,
            escape(&item.title),
            position(report, &item.path, item.line),
            escape(&item.impact),
            escape(&item.evidence),
        )
        .unwrap();
    }
    let empty = if is_partial {
        "No verified findings in the material reviewed."
    } else {
        "No verified findings."
    };
    let findings = html_list("ul", &findings, empty);
    let patches = report
        .patch_files
        .as_ref()
        .map_or_else(String::new, |files| {
            format!(
                "<details><summary>Files supplied with a patch ({})</summary><p>Surrounding source is sampled within the review budget.</p>{}</details>",
                files.len(),
                html_list("ul", &text_list(files), "No patches were supplied.")
            )
        });
    let limits = text_list(report.report.limits.iter().filter(|limit| {
        !report
            .scan
            .as_ref()
            .is_some_and(|scan| scan.limits.contains(limit))
    }));
    let general_limits = if report
        .scan
        .as_ref()
        .is_some_and(|scan| !scan.limits.is_empty())
    {
        "The recorded limits apply to Semgrep."
    } else {
        "No limits reported."
    };
    let limits = html_list("ul", &limits, general_limits);
    let scan = scanner_html(report, report.scan.as_ref());
    format!(
        "<section><h2>Where to focus</h2>{focus}</section>
<dl>
  <dt>Repository</dt><dd>{}</dd>
  <dt>Base revision</dt><dd><code>{}</code></dd>
  <dt>Reviewed revision</dt><dd><code>{}</code></dd>
</dl>
<section><h2>Verified findings</h2>{findings}</section>
<section><h2>Coverage limits</h2>{patches}{limits}<h3>Semgrep scan</h3>{scan}</section>",
        escape(&report.repo),
        escape(&report.base),
        escape(&report.head),
    )
}

fn review_page(
    id: i64,
    url: &str,
    provider: &str,
    status: &str,
    created: &str,
    raw_report: Option<&str>,
    failure: Option<&str>,
) -> String {
    let label = escape(url);
    let url = parse_pull_url(url).map_or(label.clone(), |(repo, number)| {
        let url = canonical_pull_url(repo, number);
        format!(r#"<a href="{url}">{label}</a>"#)
    });
    let (status, details) = match status {
        "queued" | "running" => (
            status,
            format!(r#"<p><a href="/reviews/{id}">Refresh status</a></p>"#),
        ),
        "completed" | "partial" => {
            match raw_report.and_then(|raw| serde_json::from_str::<PublishedReport>(raw).ok()) {
                Some(report) => (status, report_html(&report, status == "partial")),
                None => ("failed", failure_html(None)),
            }
        }
        _ => ("failed", failure_html(failure)),
    };
    page(
        &format!("Review {id}"),
        &format!(
            r#"<h1>Review {id}</h1>
<p><strong>{}</strong></p>
<p>{url}</p>
<p>{} UTC · Provider <strong>{}</strong></p>
{details}
<p><a href="/">Back to review history</a></p>"#,
            status_label(status),
            escape(created),
            escape(provider),
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
        assert!(history.contains(&format!(r#"href="{first}">{URL}</a> · Completed"#)));
        assert!(history.contains(&format!(r#"href="{second}">{SECOND_URL}</a> · Partial"#)));
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
        assert!(history.contains(&format!(r#"href="/reviews/9">{URL}</a> · Partial"#)));
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
        assert!(html.find("Verified findings").unwrap() < html.find("Coverage limits").unwrap());
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
