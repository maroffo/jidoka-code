//! The local operator's GitHub review and repository settings forms.
use super::*;
use crate::{automation, publish as github};
use axum::response::Redirect;

struct Target {
    number: u64,
    report: PublishedReport,
}

fn review_id(raw: &str) -> Result<i64, PageError> {
    raw.parse::<i64>()
        .ok()
        .filter(|id| *id > 0)
        .ok_or_else(PageError::missing)
}

async fn target(state: &WebState, id: i64) -> Result<Target, PageError> {
    let row = with_db(state, move |connection| {
        connection.query_row(
            "SELECT url, report FROM reviews WHERE id = ?1 AND status IN ('completed','partial')",
            [id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        ).optional()
    })
    .await?;
    let (url, raw) = row.ok_or_else(PageError::missing)?;
    let (repo, number) = parse_pull_url(&url).ok_or_else(PageError::missing)?;
    let report: PublishedReport = serde_json::from_str(&raw).map_err(|_| PageError::missing())?;
    if !report.repo.eq_ignore_ascii_case(repo)
        || !state
            .repositories()
            .await?
            .contains(&repo.to_ascii_lowercase())
    {
        return Err(PageError::new(
            StatusCode::FORBIDDEN,
            "Review submission is unavailable for this repository.",
        ));
    }
    Ok(Target {
        number: number.parse().map_err(|_| PageError::missing())?,
        report,
    })
}

const EVENTS: [(&str, &str); 3] = [
    ("COMMENT", "Comment"),
    ("APPROVE", "Approve"),
    ("REQUEST_CHANGES", "Request changes"),
];

fn heading(id: i64, report: &PublishedReport, number: u64, title: &str) -> String {
    format!(
        r#"<div class="hero"><div class="trail"><a href="/reviews/{id}">Back to review</a></div><h1>{title}</h1><p class="meta">{} #{} · <code>{}</code></p></div>"#,
        escape(&report.repo),
        number,
        escape(&report.head.chars().take(12).collect::<String>())
    )
}

pub(super) async fn compose(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
    headers: HeaderMap,
) -> Result<Response, PageError> {
    let id = review_id(&id)?;
    let target = target(&state, id).await?;
    let (token, cookie) = page_token(&state, &headers);
    let mut body = heading(id, &target.report, target.number, "Submit review");
    write!(body,r#"<form class="panel workflow" method="post" action="/reviews/{id}/submit"><input type="hidden" name="csrf_token" value="{token}"><fieldset><legend>Verified findings</legend>"#).unwrap();
    if target.report.report.findings.is_empty() {
        body.push_str("<p>No verified findings in this report.</p>");
    }
    for (i, finding) in target.report.report.findings.iter().enumerate() {
        write!(body, r#"<label class="pick"><input type="checkbox" name="finding-{i}" value="yes" checked><span><strong>{}</strong><small>{}, line {}</small></span></label>"#,escape(&finding.title),escape(&finding.path),finding.line).unwrap();
    }
    body.push_str("</fieldset><fieldset><legend>GitHub review decision</legend>");
    for (value, label) in EVENTS {
        let checked = if value == "COMMENT" { " checked" } else { "" };
        write!(body,r#"<label class="choice"><input type="radio" name="event" value="{value}"{checked}> {label}</label>"#).unwrap();
    }
    body.push_str(r#"</fieldset><button>Preview review</button></form>"#);
    Ok(form_page(page("Submit review", &body), cookie))
}

// Render the submitted Markdown locally. Literal source stays text, and the
// only links the review generator emits point to pinned files on GitHub.
fn markdown_preview(source: &str) -> String {
    use pulldown_cmark::{Event, Parser, Tag, TagEnd, html::push_html};
    let events = Parser::new(source).filter_map(|event| {
        Some(match event {
            Event::Html(text) | Event::InlineHtml(text) => Event::Text(text),
            Event::Start(Tag::Image { .. }) | Event::End(TagEnd::Image) => return None,
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest_url = if dest_url.starts_with("https://github.com/") {
                    dest_url
                } else {
                    "#".into()
                };
                Event::Start(Tag::Link {
                    link_type,
                    dest_url,
                    title,
                    id,
                })
            }
            other => other,
        })
    });
    let mut rendered = String::new();
    push_html(&mut rendered, events);
    rendered
}

async fn decision(
    state: &WebState,
    request: Request,
    id: i64,
    confirm: bool,
) -> Result<Response, PageError> {
    let target = target(state, id).await?;
    let fields = checked_form(
        state,
        request,
        target.report.report.findings.len().saturating_add(8),
    )
    .await?;
    let report = target.report;
    let bad_form = || PageError::new(StatusCode::BAD_REQUEST, BAD_FORM);
    let (event, label) = EVENTS
        .iter()
        .find(|(event, _)| fields.get("event").is_some_and(|v| v == event))
        .ok_or_else(bad_form)?;
    let mut selected = Vec::new();
    for (key, value) in &fields {
        if let Some(index) = key.strip_prefix("finding-") {
            let index: usize = index.parse().map_err(|_| bad_form())?;
            if index >= report.report.findings.len()
                || value != "yes"
                || key != &format!("finding-{index}")
            {
                return Err(bad_form());
            }
            selected.push(index);
        }
    }
    selected.sort_unstable();
    let prepared = github::prepare(&report, &selected, true);
    let token = &fields["csrf_token"];
    // Bind confirmation to the exact content and decision shown to this browser.
    let mut signature = token_mac(&state.secret, token);
    let inline: Vec<_> = prepared
        .comments
        .iter()
        .map(|c| (&c.path, c.line, &c.body))
        .collect();
    let payload = serde_json::to_vec(&(
        id,
        &report.repo,
        target.number,
        &report.head,
        event,
        &prepared.body,
        inline,
    ))
    .expect("serializable preview");
    signature.update(&payload);
    if confirm {
        let signed = fields.get("preview").and_then(|s| hex::decode(s).ok());
        if !signed.is_some_and(|s| signature.verify_slice(&s).is_ok()) {
            return Err(PageError::new(
                StatusCode::CONFLICT,
                "Open the preview again before submitting this review.",
            ));
        }
        let db = state.db.clone();
        let number = target.number;
        let result = tokio::task::spawn_blocking(move || {
            github::submit(&db, &report, number, &prepared, event, false)
        })
        .await
        .map_err(|_| PageError::from(StorageError))?;
        let url = result.map_err(|e| PageError::new(StatusCode::CONFLICT, &e.to_string()))?;
        return Ok(Html(page("Review submitted", &format!(r#"<div class="hero"><h1>Review submitted</h1></div><p><a href="{}">Open review on GitHub ↗</a></p><p><a href="/reviews/{id}">Back to report</a></p>"#,escape(&url)))).into_response());
    }
    let signature = hex::encode(signature.finalize().into_bytes());
    let mut html = heading(id, &report, target.number, "Preview review");
    write!(
        html,
        r#"<div class="panel workflow"><h2>{label}</h2><div class="markdown-preview">{}</div>"#,
        markdown_preview(&prepared.body)
    )
    .unwrap();
    if !prepared.comments.is_empty() {
        write!(
            html,
            "<h3>Inline comments ({})</h3>",
            prepared.comments.len()
        )
        .unwrap();
    }
    for item in &prepared.comments {
        write!(
            html,
            r#"<div class="preview-comment"><b>{}, line {}</b><div class="markdown-preview">{}</div></div>"#,
            escape(&item.path),
            item.line,
            markdown_preview(&item.body)
        )
        .unwrap();
    }
    write!(html,r#"<form method="post" action="/reviews/{id}/publish"><input type="hidden" name="csrf_token" value="{token}"><input type="hidden" name="event" value="{event}"><input type="hidden" name="preview" value="{signature}">"#).unwrap();
    for i in selected {
        write!(
            html,
            r#"<input type="hidden" name="finding-{i}" value="yes">"#
        )
        .unwrap();
    }
    write!(html,r#"<button>Submit to GitHub · {label}</button></form><a href="/reviews/{id}/submit">Edit selection</a></div>"#).unwrap();
    Ok(Html(page("Preview review", &html)).into_response())
}

pub(super) async fn preview(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
    request: Request,
) -> Result<Response, PageError> {
    let id = review_id(&id)?;
    decision(&state, request, id, false).await
}

pub(super) async fn publish(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
    request: Request,
) -> Result<Response, PageError> {
    let id = review_id(&id)?;
    decision(&state, request, id, true).await
}

const MODES: [(&str, &str); 3] = [
    ("manual", "Manual"),
    ("summary", "Automatic summary"),
    ("inline", "Automatic summary and inline comments"),
];

pub(super) async fn settings(
    State(state): State<Arc<WebState>>,
    headers: HeaderMap,
) -> Result<Response, StorageError> {
    settings_page(&state, &headers, false, None).await
}

async fn settings_page(
    state: &WebState,
    headers: &HeaderMap,
    show_setup: bool,
    invalid_repo: Option<&str>,
) -> Result<Response, StorageError> {
    let (token, cookie) = page_token(state, headers);
    let mut repos: Vec<_> = state.repositories().await?.into_iter().collect();
    repos.sort();
    let rows = with_db(state, move |c| {
        repos
            .into_iter()
            .map(|repo| {
                Ok((
                    automation::mode(&c, &repo)?,
                    automation::last_error(&c, &repo)?,
                    repo,
                ))
            })
            .collect::<rusqlite::Result<Vec<_>>>()
    })
    .await?;
    let validation = if invalid_repo.is_some() {
        r#"<p class="error" role="alert">Enter owner/repository or its GitHub repository URL.</p>"#
    } else {
        ""
    };
    let mut html = format!(
        r#"<div class="hero"><h1>Repositories</h1></div>
<form id="authorize" class="panel workflow" method="post" action="/repositories/authorize">
<input type="hidden" name="csrf_token" value="{token}"><label for="repository">GitHub repository</label>
<input id="repository" type="text" name="repo" placeholder="owner/repository or https://github.com/owner/repository" value="{}" required>
{validation}<button>Authorize repository</button></form><div class="settings-intro"><p>Automatic reviews send new PR changes to {} and post a GitHub review as the configured bot. Existing open PRs enter the queue on their next update.</p></div>"#,
        escape(invalid_repo.unwrap_or_default()),
        escape(&state.provider)
    );
    let bot_configured = automation::bot_configured();
    if !bot_configured {
        if show_setup {
            html.push_str(r#"<p class="settings-feedback" role="alert">Mode change could not be saved. Automatic reviews need a GitHub bot token.</p>"#);
        }
        let open = if show_setup { " open" } else { "" };
        write!(html, r#"<details class="setup-help"{open}><summary>Set up automatic GitHub reviews</summary><p>Manual reviews are available. To let a bot post reviews automatically, set <code>JIDOKA_BOT_TOKEN</code> to its GitHub token with pull request write access and recreate the container.</p></details>"#).unwrap();
    }
    for (mode, error, repo) in rows {
        write!(html,r#"<form id="repo-{}" class="panel workflow" method="post" action="/repositories"><input type="hidden" name="csrf_token" value="{token}"><input type="hidden" name="repo" value="{}"><h2>{}</h2><label>Review mode <select name="mode">"#,escape(&repo),escape(&repo),escape(&repo)).unwrap();
        for (value, label) in MODES {
            let selected = if mode == value { " selected" } else { "" };
            let disabled = if !bot_configured && value != "manual" && mode != value {
                " disabled"
            } else {
                ""
            };
            write!(
                html,
                r#"<option value="{value}"{selected}{disabled}>{label}</option>"#
            )
            .unwrap();
        }
        html.push_str("</select></label><button>Save mode</button>");
        if let Some(message) = error {
            write!(html, "<p class=warning>{}</p>", escape(&message)).unwrap();
        }
        html.push_str("</form>");
    }
    Ok(form_page(page("Repositories", &html), cookie))
}

pub(super) async fn authorize(
    State(state): State<Arc<WebState>>,
    request: Request,
) -> Result<Response, PageError> {
    let headers = request.headers().clone();
    let fields = checked_form(&state, request, 2).await?;
    let input = fields.get("repo").map(String::as_str).unwrap_or("").trim();
    let canonical = input.to_ascii_lowercase();
    let path = canonical
        .strip_prefix("https://github.com/")
        .unwrap_or(&canonical);
    let path = path.strip_suffix('/').unwrap_or(path);
    let repo = path.strip_suffix(".git").unwrap_or(path).to_owned();
    if repo.ends_with(".git") || !valid_repo(&repo) {
        let mut response = settings_page(&state, &headers, false, Some(input)).await?;
        *response.status_mut() = StatusCode::BAD_REQUEST;
        return Ok(response);
    }
    let preconfigured = state.configured_repos.contains(&repo);
    let location = format!("/repositories#repo-{repo}");
    with_db(&state, move |conn| {
        automation::authorize(&conn, &repo, preconfigured)
    })
    .await?;
    Ok(Redirect::to(&location).into_response())
}

pub(super) async fn save_settings(
    State(state): State<Arc<WebState>>,
    request: Request,
) -> Result<Response, PageError> {
    let headers = request.headers().clone();
    let fields = checked_form(&state, request, 3).await?;
    let allowed = state.repositories().await?;
    let repo = fields
        .get("repo")
        .filter(|s| allowed.contains(*s))
        .cloned()
        .ok_or_else(PageError::missing)?;
    let mode = fields
        .get("mode")
        .filter(|s| MODES.iter().any(|(v, _)| v == s))
        .cloned()
        .ok_or_else(|| PageError::new(StatusCode::BAD_REQUEST, BAD_FORM))?;
    if mode != "manual" && !automation::bot_configured() {
        let mut response = settings_page(&state, &headers, true, None).await?;
        *response.status_mut() = StatusCode::BAD_REQUEST;
        return Ok(response);
    }
    let db = state.db.clone();
    tokio::task::spawn_blocking(move || automation::set_mode(&connect(&db)?, &repo, &mode))
        .await
        .map_err(|_| PageError::from(StorageError))?
        .map_err(|e| PageError::new(StatusCode::BAD_REQUEST, &e.to_string()))?;
    Ok(Redirect::to("/repositories").into_response())
}

pub(super) async fn load_diff(
    State(state): State<Arc<WebState>>,
    RoutePath(id): RoutePath<String>,
    request: Request,
) -> Result<Response, PageError> {
    checked_form(&state, request, 1).await?;
    let id = review_id(&id)?;
    let target = target(&state, id).await?;
    if !crate::diff::available(&target.report) {
        let db = state.db.clone();
        let repos = state.repositories().await?;
        let loaded =
            tokio::task::spawn_blocking(move || store_archived_diff(&db, &repos, id, target))
                .await
                .map_err(|_| PageError::from(StorageError))??;
        if !loaded {
            return Err(PageError::new(
                StatusCode::CONFLICT,
                "The pull request has changed since this review. Start a new review to see its current diff.",
            ));
        }
    }
    Ok(Redirect::to(&format!("/reviews/{id}#review-diff")).into_response())
}

fn store_archived_diff(
    db: &Path,
    repos: &HashSet<String>,
    id: i64,
    target: Target,
) -> Result<bool, PageError> {
    let report = target.report;
    let url = canonical_pull_url(&report.repo, &target.number.to_string());
    let diff = crate::source::collect_pinned_diff(&url, &report.base, &report.head, repos)
        .map_err(|error| match error.downcast_ref::<GitHubRateLimit>() {
            Some(limit) => PageError::new(StatusCode::TOO_MANY_REQUESTS, &limit.to_string()),
            None => PageError::new(StatusCode::BAD_GATEWAY, "Could not load the reviewed diff from GitHub. Check repository access and try again."),
        })?;
    let Some(mut diff) = diff else {
        return Ok(false);
    };
    if let Some(paths) = report.patch_files {
        for file in &mut diff.files {
            if !paths.contains(&file.path) {
                file.patch = None;
            }
        }
    }
    let json = serde_json::to_string(&diff).map_err(|_| StorageError)?;
    connect(db)
        .and_then(|conn| {
            conn.execute(
                "UPDATE reviews SET report = json_set(report, '$.diff', json(?1))
         WHERE id = ?2 AND json_extract(report, '$.diff') IS NULL",
                params![json, id],
            )
        })
        .map_err(|_| StorageError)?;
    Ok(true)
}
