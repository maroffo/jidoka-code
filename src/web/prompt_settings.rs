//! The single-user prompt editor and its local-only paid trials.
use super::*;
use crate::prompt;
use axum::response::Redirect;
use sha2::Digest;

pub(super) fn init(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS prompt_settings (
        id INTEGER PRIMARY KEY CHECK(id=1), instructions TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS review_prompts (
        review_id INTEGER PRIMARY KEY, instructions TEXT NOT NULL, dry_run INTEGER NOT NULL DEFAULT 0,
        trial_key TEXT UNIQUE);",
    )?;
    db.execute(
        "INSERT OR IGNORE INTO prompt_settings(id,instructions) VALUES(1,?)",
        [prompt::DEFAULT_METHOD],
    )?;
    db.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS pin_review_prompt AFTER INSERT ON reviews
        BEGIN INSERT INTO review_prompts(review_id,instructions) VALUES
        (NEW.id,(SELECT instructions FROM prompt_settings WHERE id=1)); END;",
    )
}

fn editor(token: &str, method: &str, url: &str, preview: bool, message: &str) -> String {
    let preview = if preview {
        format!(
            "<section id=\"prompt-preview\" class=\"panel workflow\"><h2>Prompt preview</h2><p>The workspace path is assigned when the review runs.</p><pre>{}</pre></section>",
            escape(&prompt::render(method, "/jobs/review-{id}"))
        )
    } else {
        String::new()
    };
    let status = if message.is_empty() {
        String::new()
    } else {
        format!("<p role=\"status\">{}</p>", escape(message))
    };
    let nonce = hex::encode(rand::random::<[u8; 16]>());
    page(
        "Review prompt",
        &format!(
            r#"<div class="hero"><h1>Review prompt</h1></div>
<div class="prompt-editor"><form class="panel workflow" method="post" action="/review-prompt">
<input type="hidden" name="csrf_token" value="{token}"><input type="hidden" name="nonce" value="{nonce}">
<label for="instructions">Review instructions</label>
<p>New reviews use the saved instructions. Jidoka adds its evidence, scoring and output requirements.</p>
<textarea id="instructions" name="instructions" rows="8" required>{method}</textarea>
<div class="prompt-actions"><button name="action" value="preview" formaction="/review-prompt#prompt-preview" formnovalidate>Preview prompt</button>
<button name="action" value="save" formnovalidate>Save prompt</button></div>{status}
<h2>Test the draft on a pull request</h2><label for="trial-url">Authorized pull request URL</label>
<input type="url" id="trial-url" name="url" value="{url}" placeholder="https://github.com/owner/repo/pull/123">
<label class="consent"><input type="checkbox" name="consent" value="yes"><span>Send this PR to AGY and use model credits for a local-only review.</span></label>
<button name="action" value="trial" formtarget="_blank">Run AGY dry run</button></form>{preview}</div>"#,
            method = escape(method),
            url = escape(url)
        ),
    )
}

pub(super) async fn show(
    State(state): State<Arc<WebState>>,
    headers: HeaderMap,
) -> Result<Response, StorageError> {
    let method = with_db(&state, |db| {
        db.query_row(
            "SELECT instructions FROM prompt_settings WHERE id=1",
            [],
            |r| r.get::<_, String>(0),
        )
        .optional()
    })
    .await?;
    let (token, cookie) = page_token(&state, &headers);
    Ok(form_page(
        editor(
            &token,
            method.as_deref().unwrap_or(prompt::DEFAULT_METHOD),
            "",
            false,
            "",
        ),
        cookie,
    ))
}

pub(super) async fn update(
    State(state): State<Arc<WebState>>,
    request: Request,
) -> Result<Response, PageError> {
    let fields = checked_form_with_limit(
        &state,
        request,
        6,
        3 * prompt::MAX_METHOD_BYTES + FORM_LIMIT,
    )
    .await?;
    let method = fields
        .get("instructions")
        .map_or("", String::as_str)
        .replace("\r\n", "\n");
    let token = &fields["csrf_token"];
    let url = fields.get("url").map_or("", String::as_str);
    let invalid = |message: &str| {
        (
            StatusCode::BAD_REQUEST,
            Html(editor(token, &method, url, false, message)),
        )
            .into_response()
    };
    if !prompt::valid(&method) {
        return Ok(invalid("Enter review instructions of up to 8 KiB."));
    }
    match fields.get("action").map(String::as_str) {
        Some("preview") => Ok(Html(editor(token, &method, url, true, "")).into_response()),
        Some("save") => {
            let saved = method.clone();
            with_db(&state, move |db| db.execute("INSERT INTO prompt_settings(id,instructions) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET instructions=excluded.instructions", [saved])).await?;
            Ok(Html(editor(
                token,
                &method,
                url,
                false,
                "Prompt saved for new reviews.",
            ))
            .into_response())
        }
        Some("trial") => {
            if fields.get("consent").is_none_or(|s| s != "yes") {
                return Ok(invalid("Confirm the use of AGY credits for this dry run."));
            }
            let Some((repo, number)) = parse_pull_url(url) else {
                return Ok(invalid("Enter a GitHub pull request URL."));
            };
            let Some(nonce) = fields
                .get("nonce")
                .filter(|s| s.len() == 32 && s.bytes().all(|c| c.is_ascii_hexdigit()))
            else {
                return Err(PageError::new(StatusCode::BAD_REQUEST, BAD_FORM));
            };
            let url = canonical_pull_url(repo, number);
            let provider = state.provider.clone();
            let key = hex::encode(Sha256::digest(format!(
                "{nonce}\0{url}\0{provider}\0{method}"
            )));
            let configured = state.configured_repos.clone();
            let repo = repo.to_ascii_lowercase();
            let draft = method.clone();
            let id = with_db(&state, move |mut db| {
                let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                if !crate::automation::repositories(&tx,&configured)?.contains(&repo) {return Ok(None);}
                if let Some(id) = tx.query_row("SELECT review_id FROM review_prompts WHERE trial_key=?", [&key], |r| r.get::<_,i64>(0)).optional()? {
                    return Ok(Some(id));
                }
                tx.execute("INSERT INTO reviews(url,provider,status) VALUES(?,?,'queued')",params![url,provider])?;
                let id = tx.last_insert_rowid();
                tx.execute("UPDATE review_prompts SET instructions=?,dry_run=1,trial_key=? WHERE review_id=?",params![draft,key,id])?;
                tx.commit()?;
                Ok(Some(id))
            }).await?;
            match id {
                Some(id) => Ok(Redirect::to(&format!("/reviews/{id}")).into_response()),
                None => Ok(invalid(UNAPPROVED)),
            }
        }
        _ => Err(PageError::new(StatusCode::BAD_REQUEST, BAD_FORM)),
    }
}
