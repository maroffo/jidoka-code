//! Poll approved repositories and publish at most one automatic review per PR head.

use std::{
    collections::{BTreeMap, HashSet},
    env,
    io::Read,
    path::Path,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use reqwest::{
    blocking::Client,
    header::{ACCEPT, AUTHORIZATION, HeaderMap, HeaderValue, LINK},
    redirect::Policy,
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::Deserialize;

use crate::{contracts::PublishedReport, source::valid_repo};

const PAGE_SIZE: usize = 100;
const MAX_PAGES: usize = 5;
const MAX_PAGE_BYTES: u64 = 8_000_000;
const MAX_FINISHED_PER_REPO: usize = 8;
const MAX_PUBLISH_ATTEMPTS: i64 = 3;
const FIRST_RETRY_SECONDS: i64 = 60;
const PROVIDER_CHANGED: &str =
    "The provider changed. Enable automation again to confirm the new provider.";
const DISABLED: &str = "Automation was turned off before the review started.";
const STALE: &str = "The pull request no longer matches this automatic review.";
const BOT_TOKEN_REQUIRED: &str = "Set JIDOKA_BOT_TOKEN to enable automatic reviews.";

pub fn init(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS automation_provider (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            label TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS automation_settings (
            repo TEXT PRIMARY KEY,
            mode TEXT NOT NULL CHECK (mode IN ('manual', 'summary', 'inline')),
            generation INTEGER NOT NULL DEFAULT 0,
            baselined INTEGER NOT NULL DEFAULT 0,
            poll_error TEXT,
            review_error TEXT,
            review_error_job INTEGER
        );
        CREATE TABLE IF NOT EXISTS automation_seen (
            repo TEXT NOT NULL,
            number INTEGER NOT NULL,
            head TEXT NOT NULL,
            ready INTEGER NOT NULL,
            PRIMARY KEY (repo, number)
        );
        CREATE TABLE IF NOT EXISTS automation_jobs (
            repo TEXT NOT NULL,
            number INTEGER NOT NULL,
            head TEXT NOT NULL,
            review_id INTEGER NOT NULL UNIQUE,
            state TEXT NOT NULL DEFAULT 'pending',
            publish_attempts INTEGER NOT NULL DEFAULT 0,
            retry_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (repo, number, head)
        );
        CREATE INDEX IF NOT EXISTS automation_jobs_pending
            ON automation_jobs (repo, review_id) WHERE state = 'pending';",
    )
}

/// Bind automatic consent to the provider currently configured at startup.
pub fn bind_provider(conn: &Connection, provider: &str) -> rusqlite::Result<()> {
    let tx = immediate(conn)?;
    let previous: Option<String> = tx
        .query_row(
            "SELECT label FROM automation_provider WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(previous) = previous {
        if previous != provider {
            tx.execute(
                "UPDATE automation_provider SET label = ?1 WHERE id = 1",
                [provider],
            )?;
            tx.execute(
                "UPDATE automation_settings SET mode = 'manual', generation = generation + 1,
                    baselined = 0, poll_error = ?1, review_error = NULL, review_error_job = NULL
                 WHERE mode <> 'manual'",
                [PROVIDER_CHANGED],
            )?;
            tx.execute("DELETE FROM automation_seen", [])?;
            cancel_jobs(&tx, None, PROVIDER_CHANGED)?;
        }
    } else {
        tx.execute(
            "INSERT INTO automation_provider (id, label) VALUES (1, ?1)",
            [provider],
        )?;
    }
    tx.commit()
}

pub fn mode(conn: &Connection, repo: &str) -> rusqlite::Result<String> {
    Ok(conn
        .query_row(
            "SELECT mode FROM automation_settings WHERE repo = ?1",
            [repo.to_ascii_lowercase()],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or_else(|| "manual".to_owned()))
}

/// The most recent polling error, or a review/publication error if polling succeeded.
pub fn last_error(conn: &Connection, repo: &str) -> rusqlite::Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT COALESCE(poll_error, review_error) FROM automation_settings WHERE repo = ?1",
            [repo.to_ascii_lowercase()],
            |row| row.get(0),
        )
        .optional()?
        .flatten())
}

pub fn set_mode(conn: &Connection, repo: &str, mode: &str) -> Result<()> {
    let token = env::var("JIDOKA_BOT_TOKEN").ok();
    save_mode(conn, repo, mode, token.as_deref())
}

fn save_mode(conn: &Connection, repo: &str, mode: &str, token: Option<&str>) -> Result<()> {
    ensure!(
        matches!(mode, "manual" | "summary" | "inline"),
        "Unknown automation mode."
    );
    ensure!(valid_repo(repo), "Invalid repository name.");
    let repo = repo.to_ascii_lowercase();
    let tx = immediate(conn)?;
    if mode != "manual" {
        ensure!(token.is_some_and(valid_token), "{BOT_TOKEN_REQUIRED}");
        let bound: bool = tx.query_row(
            "SELECT EXISTS (SELECT 1 FROM automation_provider WHERE id = 1)",
            [],
            |row| row.get(0),
        )?;
        ensure!(
            bound,
            "The review provider must be configured before enabling automation."
        );
    }
    let changed = tx.execute(
        "INSERT INTO automation_settings (repo, mode) VALUES (?1, ?2)
         ON CONFLICT (repo) DO UPDATE SET mode = excluded.mode,
            generation = generation + 1,
            baselined = CASE WHEN mode = 'manual' OR excluded.mode = 'manual' THEN 0 ELSE baselined END,
            poll_error = NULL, review_error = NULL, review_error_job = NULL
         WHERE mode <> excluded.mode",
        params![repo, mode],
    )?;
    if changed != 0 && mode == "manual" {
        tx.execute("DELETE FROM automation_seen WHERE repo = ?1", [&repo])?;
        cancel_jobs(&tx, Some(&repo), DISABLED)?;
    }
    tx.commit()?;
    Ok(())
}

fn immediate(conn: &Connection) -> rusqlite::Result<Transaction<'_>> {
    Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
}

fn cancel_jobs(conn: &Connection, repo: Option<&str>, reason: &str) -> rusqlite::Result<()> {
    let count = conn.execute(
        "UPDATE automation_jobs SET state = 'canceled'
         WHERE state IN ('pending', 'deferred') AND (?1 IS NULL OR repo = ?1)",
        [repo],
    )?;
    if count != 0 {
        cancel_queued(conn, repo, reason)?;
    }
    Ok(())
}

fn cancel_queued(conn: &Connection, repo: Option<&str>, reason: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE reviews SET status = 'failed', error = ?1
         WHERE status = 'queued' AND id IN (
            SELECT review_id FROM automation_jobs
            WHERE state IN ('canceled', 'deferred') AND (?2 IS NULL OR repo = ?2)
         )",
        params![reason, repo],
    )?;
    Ok(())
}

fn valid_token(token: &str) -> bool {
    !token.is_empty() && token.bytes().all(|byte| byte.is_ascii_graphic())
}

fn github_client() -> Result<Client> {
    let token = env::var("JIDOKA_BOT_TOKEN")
        .ok()
        .filter(|token| valid_token(token))
        .context(BOT_TOKEN_REQUIRED)?;
    let mut auth = HeaderValue::from_str(&format!("Bearer {token}"))
        .context("JIDOKA_BOT_TOKEN is not valid for GitHub requests.")?;
    auth.set_sensitive(true);
    let mut headers = HeaderMap::new();
    headers.insert(AUTHORIZATION, auth);
    headers.insert(
        ACCEPT,
        HeaderValue::from_static("application/vnd.github+json"),
    );
    headers.insert(
        "x-github-api-version",
        HeaderValue::from_static("2022-11-28"),
    );
    Client::builder()
        .default_headers(headers)
        .user_agent("jidoka-review-automation")
        .https_only(true)
        .no_proxy()
        .redirect(Policy::none())
        .retry(reqwest::retry::never())
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(5))
        .build()
        .context("Could not initialize GitHub polling.")
}

#[derive(Deserialize)]
struct PullHead {
    sha: String,
}

#[derive(Deserialize)]
struct ApiPull {
    number: i64,
    state: String,
    draft: bool,
    head: PullHead,
}

struct Pull {
    head: String,
    ready: bool,
}

type OpenPulls = BTreeMap<i64, Pull>;

fn paginate(mut page: impl FnMut(usize) -> Result<(Vec<ApiPull>, bool)>) -> Result<OpenPulls> {
    let mut pulls = BTreeMap::new();
    for number in 1..=MAX_PAGES {
        let (entries, has_next) = page(number)?;
        ensure!(
            entries.len() <= PAGE_SIZE,
            "GitHub returned too many pull requests on a page."
        );
        for entry in entries.into_iter().filter(|entry| entry.state == "open") {
            let mut head = entry.head.sha;
            ensure!(
                entry.number > 0
                    && head.len() == 40
                    && head.bytes().all(|byte| byte.is_ascii_hexdigit()),
                "GitHub returned an invalid pull request."
            );
            head.make_ascii_lowercase();
            ensure!(
                pulls
                    .insert(
                        entry.number,
                        Pull {
                            head,
                            ready: !entry.draft
                        }
                    )
                    .is_none(),
                "GitHub returned a duplicate pull request across pages. Polling will try again."
            );
        }
        if !has_next {
            return Ok(pulls);
        }
    }
    bail!(
        "The repository exceeds the automatic polling limit of {} open pull requests.",
        PAGE_SIZE * MAX_PAGES
    );
}

fn poll(client: &Client, repo: &str) -> Result<OpenPulls> {
    ensure!(valid_repo(repo), "Invalid repository name.");
    paginate(|page| {
        let response = client.get(format!(
            "https://api.github.com/repos/{repo}/pulls?state=open&sort=created&direction=asc&per_page={PAGE_SIZE}&page={page}"
        )).send().context("Could not poll GitHub for open pull requests.")?;
        ensure!(
            response.status().is_success(),
            "GitHub polling returned HTTP {}.",
            response.status().as_u16()
        );
        let has_next = response.headers().get_all(LINK).iter().any(|value| {
            value.to_str().is_ok_and(|value| {
                value.split(',').any(|link| {
                    link.split(';')
                        .skip(1)
                        .any(|attribute| attribute.trim() == "rel=\"next\"")
                })
            })
        });
        let mut body = Vec::new();
        response
            .take(MAX_PAGE_BYTES + 1)
            .read_to_end(&mut body)
            .context("Could not read the GitHub polling response.")?;
        ensure!(
            body.len() as u64 <= MAX_PAGE_BYTES,
            "The GitHub polling response exceeded its size limit."
        );
        let results = serde_json::from_slice(&body)
            .context("GitHub returned an invalid pull request list.")?;
        Ok((results, has_next))
    })
}

fn generation(conn: &Connection, repo: &str) -> rusqlite::Result<Option<i64>> {
    conn.query_row(
        "SELECT generation FROM automation_settings WHERE repo = ?1 AND mode <> 'manual'",
        [repo],
        |row| row.get(0),
    )
    .optional()
}

fn record_poll_error(
    conn: &Connection,
    repo: &str,
    generation: i64,
    error: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE automation_settings SET poll_error = ?1 WHERE repo = ?2 AND generation = ?3",
        params![error, repo, generation],
    )?;
    Ok(())
}

fn apply_poll(
    conn: &Connection,
    repo: &str,
    generation: i64,
    provider: &str,
    pulls: OpenPulls,
) -> rusqlite::Result<bool> {
    let tx = immediate(conn)?;
    let baselined: Option<bool> = tx
        .query_row(
            "SELECT baselined FROM automation_settings
         WHERE repo = ?1 AND generation = ?2 AND mode <> 'manual'",
            params![repo, generation],
            |row| row.get(0),
        )
        .optional()?;
    let Some(baselined) = baselined else {
        return Ok(false);
    };

    let previous: OpenPulls = {
        let mut statements =
            tx.prepare("SELECT number, head, ready FROM automation_seen WHERE repo = ?1")?;
        statements
            .query_map([repo], |row| {
                Ok((
                    row.get(0)?,
                    Pull {
                        head: row.get(1)?,
                        ready: row.get(2)?,
                    },
                ))
            })?
            .collect::<rusqlite::Result<_>>()?
    };
    tx.execute("DELETE FROM automation_seen WHERE repo = ?1", [repo])?;
    for (number, pull) in pulls {
        if baselined
            && pull.ready
            && previous
                .get(&number)
                .is_none_or(|last| !last.ready || last.head != pull.head)
        {
            enqueue(&tx, repo, provider, number, &pull.head)?;
        }
        tx.execute(
            "INSERT INTO automation_seen (repo, number, head, ready) VALUES (?1, ?2, ?3, ?4)",
            params![repo, number, pull.head, pull.ready],
        )?;
    }
    let canceled = tx.execute(
        "UPDATE automation_jobs AS job SET state = CASE WHEN EXISTS (
           SELECT 1 FROM reviews WHERE id = job.review_id AND provider = ?2 AND status = 'queued'
         ) THEN 'deferred' ELSE 'canceled' END
         WHERE repo = ?1 AND state = 'pending' AND (
           NOT EXISTS (SELECT 1 FROM automation_seen AS seen
                       WHERE seen.repo = job.repo AND seen.number = job.number
                         AND seen.head = job.head AND seen.ready = 1)
           OR NOT EXISTS (SELECT 1 FROM reviews WHERE id = job.review_id AND provider = ?2)
         )",
        params![repo, provider],
    )?;
    if canceled != 0 {
        cancel_queued(&tx, Some(repo), STALE)?;
    }
    tx.execute(
        "UPDATE automation_settings SET baselined = 1, poll_error = NULL WHERE repo = ?1",
        [repo],
    )?;
    tx.commit()?;
    Ok(true)
}

fn pr_url(repo: &str, number: i64) -> String {
    format!("https://github.com/{repo}/pull/{number}")
}

fn enqueue(
    conn: &Connection,
    repo: &str,
    provider: &str,
    number: i64,
    head: &str,
) -> rusqlite::Result<()> {
    let existing: Option<(i64, String)> = conn.query_row(
        "SELECT review_id, state FROM automation_jobs WHERE repo = ?1 AND number = ?2 AND head = ?3",
        params![repo, number, head],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).optional()?;
    if let Some((id, state)) = existing {
        // A head that became a draft or closed before the worker started retains its slot.
        if state == "deferred"
            && conn.execute(
                "UPDATE reviews SET status = 'queued', error = NULL
             WHERE id = ?1 AND provider = ?2 AND status = 'failed'",
                params![id, provider],
            )? != 0
        {
            conn.execute(
                "UPDATE automation_jobs SET state = 'pending' WHERE review_id = ?1",
                [id],
            )?;
        }
        return Ok(());
    }
    conn.execute(
        "INSERT INTO reviews (url, provider, status) VALUES (?1, ?2, 'queued')",
        params![pr_url(repo, number), provider],
    )?;
    conn.execute(
        "INSERT INTO automation_jobs (repo, number, head, review_id) VALUES (?1, ?2, ?3, ?4)",
        params![repo, number, head, conn.last_insert_rowid()],
    )?;
    Ok(())
}

struct Finished {
    review_id: i64,
    number: i64,
    head: String,
    status: String,
    report: Option<String>,
    url: String,
    inline: bool,
    publish_attempts: i64,
}

fn next_finished(
    conn: &Connection,
    repo: &str,
    generation: i64,
    provider: &str,
) -> rusqlite::Result<Option<Finished>> {
    conn.query_row(
        "SELECT job.review_id, job.number, job.head, review.status, review.report, review.url,
                settings.mode = 'inline', job.publish_attempts
         FROM automation_jobs AS job JOIN reviews AS review ON review.id = job.review_id
         JOIN automation_settings AS settings ON settings.repo = job.repo
         WHERE job.repo = ?1 AND job.state = 'pending' AND review.provider = ?2
           AND review.status NOT IN ('queued', 'running')
           AND settings.generation = ?3 AND settings.mode <> 'manual'
           AND job.retry_at <= unixepoch()
           AND EXISTS (SELECT 1 FROM automation_seen AS seen
                       WHERE seen.repo = job.repo AND seen.number = job.number
                         AND seen.head = job.head AND seen.ready = 1)
         ORDER BY job.review_id LIMIT 1",
        params![repo, provider, generation],
        |row| {
            Ok(Finished {
                review_id: row.get(0)?,
                number: row.get(1)?,
                head: row.get(2)?,
                status: row.get(3)?,
                report: row.get(4)?,
                url: row.get(5)?,
                inline: row.get(6)?,
                publish_attempts: row.get(7)?,
            })
        },
    )
    .optional()
}

fn eligible_report(finished: &Finished, repo: &str) -> Option<PublishedReport> {
    if !matches!(finished.status.as_str(), "completed" | "partial")
        || finished.url != pr_url(repo, finished.number)
    {
        return None;
    }
    let report: PublishedReport = serde_json::from_str(finished.report.as_deref()?).ok()?;
    (report.repo.eq_ignore_ascii_case(repo) && report.head.eq_ignore_ascii_case(&finished.head))
        .then_some(report)
}

fn publish_finished(
    conn: &Connection,
    repo: &str,
    expected_generation: i64,
    provider: &str,
    mut publish: impl FnMut(&PublishedReport, u64, bool) -> Result<()>,
) -> rusqlite::Result<bool> {
    let mut failed = false;
    for _ in 0..MAX_FINISHED_PER_REPO {
        let Some(finished) = next_finished(conn, repo, expected_generation, provider)? else {
            break;
        };
        if generation(conn, repo)? != Some(expected_generation) {
            break;
        }
        let number = finished.number;
        let (error, wait) = match eligible_report(&finished, repo) {
            Some(report) => match publish(&report, number as u64, finished.inline) {
                Ok(()) => (None, None),
                Err(_) => {
                    let retry = (finished.publish_attempts + 1 < MAX_PUBLISH_ATTEMPTS)
                        .then(|| FIRST_RETRY_SECONDS << finished.publish_attempts);
                    let next = if retry.is_some() {
                        "Will retry automatically."
                    } else {
                        "Automatic attempts stopped."
                    };
                    (
                        Some(format!(
                            "Could not publish the automatic review for PR #{number}. {next}"
                        )),
                        retry,
                    )
                }
            },
            None if finished.status == "failed" => (
                Some(format!("The automatic review for PR #{number} failed.")),
                None,
            ),
            None => (
                Some(format!(
                    "The automatic review for PR #{number} did not match the expected pull request and head."
                )),
                None,
            ),
        };
        failed |= error.is_some();
        finish_publication(
            conn,
            repo,
            expected_generation,
            finished.review_id,
            error.as_deref(),
            wait,
        )?;
    }
    Ok(failed)
}

fn finish_publication(
    conn: &Connection,
    repo: &str,
    generation: i64,
    review_id: i64,
    error: Option<&str>,
    wait: Option<i64>,
) -> rusqlite::Result<()> {
    // The publisher owns POST idempotency. A crash before this transaction leaves the job pending.
    let tx = immediate(conn)?;
    tx.execute(
        "UPDATE automation_jobs SET state = CASE WHEN ?1 IS NULL THEN 'handled' ELSE 'pending' END,
            retry_at = COALESCE(unixepoch() + ?1, 0), publish_attempts = publish_attempts + 1
         WHERE review_id = ?2 AND state = 'pending'",
        params![wait, review_id],
    )?;
    if let Some(error) = error {
        tx.execute(
            "UPDATE automation_settings SET review_error = ?1, review_error_job = ?2
             WHERE repo = ?3 AND generation = ?4",
            params![error, review_id, repo, generation],
        )?;
    } else {
        tx.execute(
            "UPDATE automation_settings SET review_error = NULL, review_error_job = NULL
             WHERE repo = ?1 AND generation = ?2 AND review_error_job = ?3",
            params![repo, generation, review_id],
        )?;
    }
    tx.commit()
}

fn tick_with(
    conn: &Connection,
    provider: &str,
    repos: &HashSet<String>,
    mut poll_repo: impl FnMut(&str) -> Result<OpenPulls>,
    mut publish: impl FnMut(&PublishedReport, u64, bool) -> Result<()>,
) -> Result<()> {
    bind_provider(conn, provider)?;
    let mut repos: Vec<_> = repos.iter().map(|repo| repo.to_ascii_lowercase()).collect();
    repos.sort_unstable();
    repos.dedup();
    let mut failed = false;
    for repo in repos {
        let Some(generation) = generation(conn, &repo)? else {
            continue;
        };
        match poll_repo(&repo) {
            Ok(pulls) => {
                if apply_poll(conn, &repo, generation, provider, pulls)? {
                    failed |= publish_finished(conn, &repo, generation, provider, &mut publish)?;
                }
            }
            Err(error) => {
                record_poll_error(conn, &repo, generation, &error.to_string())?;
                failed = true;
            }
        }
    }
    ensure!(
        !failed,
        "Automatic review encountered an error. Check the repository settings."
    );
    Ok(())
}

/// Poll once. The worker calls this periodically between reviews.
pub fn tick(db: &Path, provider: &str, repos: &HashSet<String>) -> Result<()> {
    let conn = Connection::open(db)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    init(&conn)?;
    let mut client = None;
    tick_with(
        &conn,
        provider,
        repos,
        |repo| {
            if client.is_none() {
                client = Some(github_client()?);
            }
            poll(client.as_ref().expect("GitHub client initialized"), repo)
        },
        |report, number, inline| {
            let indexes: Vec<_> = (0..report.report.findings.len()).collect();
            let prepared = crate::publish::prepare(report, &indexes, inline);
            crate::publish::submit(db, report, number, &prepared, "COMMENT", true).map(|_| ())
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const REPO: &str = "example/demo";
    const PROVIDER: &str = "example.invalid (fixture model)";
    const TOKEN: &str = "synthetic_bot_token";
    const OLD: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const NEW: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn setup(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE reviews (
                id INTEGER PRIMARY KEY, url TEXT NOT NULL, provider TEXT NOT NULL,
                status TEXT NOT NULL, report TEXT, error TEXT
            );",
        )
        .unwrap();
        init(conn).unwrap();
        bind_provider(conn, PROVIDER).unwrap();
    }

    fn fixture(mode: &str) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        setup(&conn);
        save_mode(&conn, REPO, mode, Some(TOKEN)).unwrap();
        conn
    }

    fn repos() -> HashSet<String> {
        HashSet::from(["Example/Demo".to_owned()])
    }

    fn pulls(entries: &[(i64, &str, bool)]) -> OpenPulls {
        entries
            .iter()
            .map(|&(number, head, ready)| {
                (
                    number,
                    Pull {
                        head: head.to_owned(),
                        ready,
                    },
                )
            })
            .collect()
    }

    fn snapshot(conn: &Connection, entries: &[(i64, &str, bool)]) {
        tick_with(
            conn,
            PROVIDER,
            &repos(),
            |_| Ok(pulls(entries)),
            |_, _, _| panic!("fixture has no result to publish"),
        )
        .unwrap();
    }

    fn states(conn: &Connection) -> Vec<(i64, String, String)> {
        let mut query = conn
            .prepare(
                "SELECT job.number, job.head, reviews.status FROM automation_jobs AS job
             JOIN reviews ON reviews.id = job.review_id ORDER BY reviews.id",
            )
            .unwrap();
        query
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    fn report(repo: &str, head: &str, limits: &[&str]) -> String {
        json!({
            "repo": repo, "base": OLD, "head": head, "focus": [], "findings": [], "limits": limits,
        })
        .to_string()
    }

    fn finish(conn: &Connection, number: i64, status: &str, report: Option<String>) {
        assert_eq!(
            conn.execute(
                "UPDATE reviews SET status = ?1, report = ?2 WHERE url = ?3",
                params![status, report, pr_url(REPO, number)],
            )
            .unwrap(),
            1
        );
    }

    #[test]
    fn baseline_skips_ready_pulls_but_queues_ready_transitions_and_pushes_once() {
        let conn = fixture("summary");
        snapshot(&conn, &[(1, OLD, true), (2, OLD, false)]);
        assert!(states(&conn).is_empty());
        let latest = [(1, NEW, true), (2, OLD, true), (3, OLD, true)];
        snapshot(&conn, &latest);
        snapshot(&conn, &latest);
        assert_eq!(
            states(&conn),
            [
                (1, NEW.into(), "queued".into()),
                (2, OLD.into(), "queued".into()),
                (3, OLD.into(), "queued".into()),
            ]
        );
        snapshot(&conn, &[(1, NEW, true), (2, OLD, false)]);
        assert_eq!(states(&conn)[1].2, "failed");
        assert_eq!(states(&conn)[2].2, "failed");
        snapshot(&conn, &latest);
        assert_eq!(states(&conn).len(), 3);
        assert!(states(&conn).iter().all(|(_, _, state)| state == "queued"));
    }

    #[test]
    fn requires_bot_token_and_resets_consent_on_provider_change_across_restart() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("reviews.sqlite3");
        let conn = Connection::open(&path).unwrap();
        setup(&conn);
        assert_eq!(mode(&conn, REPO).unwrap(), "manual");
        for token in [None, Some(" "), Some("invalid\nfixture")] {
            assert_eq!(
                save_mode(&conn, REPO, "inline", token)
                    .unwrap_err()
                    .to_string(),
                BOT_TOKEN_REQUIRED
            );
        }
        assert!(save_mode(&conn, REPO, "invalid", Some(TOKEN)).is_err());
        save_mode(&conn, REPO, "inline", Some(TOKEN)).unwrap();
        snapshot(&conn, &[]);
        snapshot(&conn, &[(1, OLD, true), (2, OLD, true)]);
        finish(&conn, 2, "completed", Some(report(REPO, OLD, &[])));
        drop(conn);

        let conn = Connection::open(path).unwrap();
        bind_provider(&conn, PROVIDER).unwrap();
        assert_eq!(mode(&conn, REPO).unwrap(), "inline");
        bind_provider(&conn, "another provider").unwrap();
        assert_eq!(mode(&conn, "EXAMPLE/DEMO").unwrap(), "manual");
        assert_eq!(
            last_error(&conn, REPO).unwrap().as_deref(),
            Some(PROVIDER_CHANGED)
        );
        assert_eq!(states(&conn)[0].2, "failed");
        tick_with(
            &conn,
            "another provider",
            &repos(),
            |_| panic!("manual repo was polled"),
            |_, _, _| panic!("old consent published"),
        )
        .unwrap();
        save_mode(&conn, REPO, "summary", Some(TOKEN)).unwrap();
        tick_with(
            &conn,
            "another provider",
            &repos(),
            |_| Ok(pulls(&[(2, OLD, true), (3, OLD, true)])),
            |_, _, _| panic!("old result was published"),
        )
        .unwrap();
        assert_eq!(states(&conn).len(), 2);
    }

    #[test]
    fn only_matching_completed_or_partial_reports_publish_in_current_mode() {
        let conn = fixture("inline");
        snapshot(&conn, &[]);
        let latest = [
            (1, OLD, true),
            (2, OLD, true),
            (3, OLD, true),
            (4, OLD, true),
            (5, OLD, true),
            (6, OLD, true),
        ];
        snapshot(&conn, &latest);
        finish(&conn, 1, "completed", Some(report(REPO, OLD, &[])));
        finish(
            &conn,
            2,
            "partial",
            Some(report(REPO, OLD, &["Coverage was limited."])),
        );
        finish(&conn, 3, "completed", Some(report(REPO, NEW, &[])));
        finish(&conn, 4, "completed", Some(report("other/demo", OLD, &[])));
        finish(&conn, 5, "failed", Some(report(REPO, OLD, &[])));
        finish(&conn, 6, "completed", None);
        save_mode(&conn, REPO, "summary", Some(TOKEN)).unwrap();
        let mut submissions = Vec::new();
        let result = tick_with(
            &conn,
            PROVIDER,
            &repos(),
            |_| Ok(pulls(&latest)),
            |report, number, inline| {
                submissions.push((number, inline, report.report.limits.len()));
                Ok(())
            },
        );
        assert!(result.is_err());
        assert_eq!(submissions, [(1, false, 0), (2, false, 1)]);
        assert!(last_error(&conn, REPO).unwrap().unwrap().contains("PR #6"));
        snapshot(&conn, &latest);
    }

    #[test]
    fn transient_publication_retries_after_restart_and_other_success_keeps_its_error() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("reviews.sqlite3");
        let conn = Connection::open(&path).unwrap();
        setup(&conn);
        save_mode(&conn, REPO, "inline", Some(TOKEN)).unwrap();
        snapshot(&conn, &[]);
        let latest = [(1, OLD, true), (2, OLD, true), (3, OLD, true)];
        snapshot(&conn, &latest);
        finish(&conn, 1, "completed", Some(report(REPO, OLD, &[])));
        finish(&conn, 2, "completed", Some(report(REPO, OLD, &[])));
        let mut attempted = Vec::new();
        let result = tick_with(
            &conn,
            PROVIDER,
            &repos(),
            |_| Ok(pulls(&latest)),
            |_, number, inline| {
                assert!(inline);
                attempted.push(number);
                if number == 1 {
                    bail!("synthetic 503 before POST");
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert_eq!(attempted, [1, 2]);
        assert_eq!(
            last_error(&conn, REPO).unwrap().as_deref(),
            Some("Could not publish the automatic review for PR #1. Will retry automatically.")
        );
        drop(conn);

        let conn = Connection::open(path).unwrap();
        // Reopening the database preserves both the pending job and its delay.
        snapshot(&conn, &latest);
        conn.execute(
            "UPDATE automation_jobs SET retry_at = 0 WHERE number = 1",
            [],
        )
        .unwrap();
        tick_with(
            &conn,
            PROVIDER,
            &repos(),
            |_| Ok(pulls(&latest)),
            |_, number, _| {
                attempted.push(number);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(attempted, [1, 2, 1]);
        assert!(last_error(&conn, REPO).unwrap().is_none());
        snapshot(&conn, &latest);

        tick_with(
            &conn,
            PROVIDER,
            &repos(),
            |_| {
                save_mode(&conn, REPO, "manual", None)?;
                Ok(pulls(&[
                    (1, OLD, true),
                    (2, OLD, true),
                    (3, OLD, true),
                    (4, OLD, true),
                ]))
            },
            |_, _, _| panic!("disabled work was published"),
        )
        .unwrap();
        assert_eq!(states(&conn).len(), 3);
        assert_eq!(states(&conn)[2].2, "failed");
    }

    #[test]
    fn repeated_publish_failure_stops_after_the_attempt_limit() {
        let conn = fixture("summary");
        let latest = [(1, OLD, true)];
        snapshot(&conn, &[]);
        snapshot(&conn, &latest);
        finish(&conn, 1, "completed", Some(report(REPO, OLD, &[])));
        let mut attempts = 0;
        for _ in 0..MAX_PUBLISH_ATTEMPTS {
            assert!(
                tick_with(
                    &conn,
                    PROVIDER,
                    &repos(),
                    |_| Ok(pulls(&latest)),
                    |_, _, _| {
                        attempts += 1;
                        bail!("synthetic unavailable publisher")
                    }
                )
                .is_err()
            );
            conn.execute("UPDATE automation_jobs SET retry_at = 0", [])
                .unwrap();
        }
        assert_eq!(attempts, MAX_PUBLISH_ATTEMPTS);
        snapshot(&conn, &latest);
        assert!(
            last_error(&conn, REPO)
                .unwrap()
                .unwrap()
                .contains("Automatic attempts stopped.")
        );
    }

    #[test]
    fn an_incomplete_poll_never_advances_the_baseline_or_publishes() {
        let conn = fixture("summary");
        let mut requests = 0;
        let result = tick_with(
            &conn,
            PROVIDER,
            &repos(),
            |_| {
                paginate(|page| {
                    requests += 1;
                    Ok((
                        vec![ApiPull {
                            number: page as i64,
                            state: "open".into(),
                            draft: false,
                            head: PullHead { sha: OLD.into() },
                        }],
                        true,
                    ))
                })
            },
            |_, _, _| panic!("failed poll tried to publish"),
        );
        assert!(result.is_err());
        assert_eq!(requests, MAX_PAGES);
        assert!(
            last_error(&conn, REPO)
                .unwrap()
                .unwrap()
                .contains("polling limit")
        );
        snapshot(&conn, &[(1, OLD, true)]);
        assert!(states(&conn).is_empty());
        assert!(last_error(&conn, REPO).unwrap().is_none());
    }
}
