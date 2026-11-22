//! Durable model replies for one review at one pinned revision.
use super::{connect, parse_pull_url};
use crate::contracts::{Finding, PublishedReport, Snapshot};
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

pub(crate) fn init(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS review_runs (
        review_id INTEGER PRIMARY KEY, base TEXT, head TEXT, snapshot TEXT, prior TEXT,
        turns INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER, output_tokens INTEGER,
        cached_tokens INTEGER, model_ms INTEGER NOT NULL DEFAULT 0, stop_reason TEXT
    );
    CREATE TABLE IF NOT EXISTS review_turns (
        review_id INTEGER NOT NULL, step INTEGER NOT NULL, fingerprint BLOB NOT NULL, reply TEXT NOT NULL,
        PRIMARY KEY(review_id,step)
    );
    CREATE TABLE IF NOT EXISTS review_splits (
        review_id INTEGER NOT NULL,step INTEGER NOT NULL,fingerprint BLOB NOT NULL,interrupted INTEGER NOT NULL,
        PRIMARY KEY(review_id,step)
    );
    CREATE TABLE IF NOT EXISTS review_replays (review_id INTEGER PRIMARY KEY,source_id INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS review_origins (review_id INTEGER PRIMARY KEY,repo TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS review_reads (review_id INTEGER NOT NULL,path TEXT NOT NULL,start INTEGER NOT NULL,end INTEGER NOT NULL,PRIMARY KEY(review_id,path,start,end));")
}

/// Enqueue a manual review of the exact revisions in a previous report.
pub fn replay(
    db: &Path,
    id: i64,
    provider: &str,
    configured: &std::collections::HashSet<String>,
) -> Result<i64> {
    let mut conn = connect(db)?;
    super::init_db(&conn)?;
    crate::automation::init(&conn)?;
    let tx = conn.transaction()?;
    let (url, raw): (String, String) = tx.query_row(
        "SELECT url,report FROM reviews WHERE id=? AND status IN ('completed','partial')",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let original: PublishedReport = serde_json::from_str(&raw)?;
    ensure!(
        parse_pull_url(&url).is_some_and(|(repo, _)| repo.eq_ignore_ascii_case(&original.repo)),
        "Stored review repository does not match URL"
    );
    ensure!(
        crate::automation::repositories(&tx, configured)?
            .contains(&original.repo.to_ascii_lowercase()),
        "This repository is not approved for review."
    );
    tx.execute(
        "INSERT INTO reviews(url,provider,status) VALUES(?,?,'queued')",
        params![url, provider],
    )?;
    let new_id = tx.last_insert_rowid();
    tx.execute(
        "INSERT INTO review_runs(review_id,base,head) VALUES(?,?,?)",
        params![new_id, original.base, original.head],
    )?;
    tx.execute("INSERT INTO review_origins(review_id,repo) SELECT ?1,repo FROM review_origins WHERE review_id=?2",params![new_id,id])?;
    tx.execute(
        "INSERT INTO review_replays(review_id,source_id) VALUES(?,?)",
        params![new_id, id],
    )?;
    tx.commit()?;
    Ok(new_id)
}

pub struct Session {
    db: Connection,
    id: i64,
    step: usize,
}

impl Session {
    pub fn open(db: &Path, id: i64) -> Result<Self> {
        let db = connect(db)?;
        db.execute(
            "INSERT OR IGNORE INTO review_runs(review_id) VALUES (?)",
            [id],
        )?;
        Ok(Self { db, id, step: 0 })
    }

    pub fn replay_source(&self) -> Result<Option<PublishedReport>> {
        let raw:Option<String>=self.db.query_row("SELECT source.report FROM review_replays
            JOIN reviews source ON source.id=review_replays.source_id
            JOIN reviews current ON current.id=review_replays.review_id
            WHERE current.id=? AND source.provider=current.provider AND source.url=current.url COLLATE NOCASE",[self.id],|r|r.get(0)).optional()?;
        Ok(raw.map(|text| serde_json::from_str(&text)).transpose()?)
    }

    pub fn reset(&mut self) -> Result<()> {
        let tx = self.db.transaction()?;
        clear(&tx, self.id)?;
        tx.execute("INSERT INTO review_runs(review_id) VALUES(?)", [self.id])?;
        tx.commit()?;
        self.step = 0;
        Ok(())
    }

    pub fn remember_origin(&self, repo: Option<&str>) -> Result<Option<String>> {
        if let Some(repo) = repo {
            self.db.execute(
                "INSERT OR IGNORE INTO review_origins(review_id,repo) VALUES(?,?)",
                params![self.id, repo.to_ascii_lowercase()],
            )?;
        }
        Ok(self
            .db
            .query_row(
                "SELECT repo FROM review_origins WHERE review_id=?",
                [self.id],
                |r| r.get(0),
            )
            .optional()?)
    }

    pub fn revisions(&self) -> Result<Option<(String, String)>> {
        Ok(self
            .db
            .query_row(
                "SELECT base,head FROM review_runs WHERE review_id=? AND head IS NOT NULL",
                [self.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?)
    }

    pub fn saved_inputs(&self) -> Result<Option<(Snapshot, Vec<Finding>)>> {
        let saved: Option<(String, String)> = self
            .db
            .query_row(
                "SELECT snapshot,prior FROM review_runs WHERE review_id=? AND snapshot IS NOT NULL",
                [self.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        saved
            .map(|(s, p)| Ok((serde_json::from_str(&s)?, serde_json::from_str(&p)?)))
            .transpose()
    }

    pub fn save_inputs(&self, snapshot: &Snapshot, prior: &[Finding]) -> Result<()> {
        self.db.execute(
            "UPDATE review_runs SET base=?,head=?,snapshot=?,prior=? WHERE review_id=?",
            params![
                snapshot.base,
                snapshot.head,
                serde_json::to_string(snapshot)?,
                serde_json::to_string(prior)?,
                self.id
            ],
        )?;
        Ok(())
    }

    fn fingerprint(system: &str, data: &Value) -> Result<Vec<u8>> {
        let mut hash = Sha256::new();
        hash.update(system.len().to_be_bytes());
        hash.update(system);
        serde_json::to_writer(&mut hash, data)?;
        Ok(hash.finalize().to_vec())
    }

    /// A matching saved outcome is returned by ask, including a saved split.
    /// Peeking must not advance the step; a fresh input may be partitioned before dispatch.
    pub fn fits_context(
        &self,
        system: &str,
        data: &Value,
        measure: impl FnOnce() -> Result<bool>,
    ) -> Result<bool> {
        let fingerprint = Self::fingerprint(system, data)?;
        let restored: bool = self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM review_turns WHERE review_id=?1 AND step=?2 AND fingerprint=?3
             UNION ALL SELECT 1 FROM review_splits WHERE review_id=?1 AND step=?2 AND fingerprint=?3)",
            params![self.id, self.step + 1, fingerprint], |row| row.get(0),
        )?;
        if restored { Ok(true) } else { measure() }
    }

    pub fn ask(
        &mut self,
        system: &str,
        data: &Value,
        mut call: impl FnMut() -> Result<crate::provider::ModelReply>,
    ) -> Result<Value> {
        self.step += 1;
        let fingerprint = Self::fingerprint(system, data)?;
        let cached: Option<String> = self
            .db
            .query_row(
                "SELECT reply FROM review_turns WHERE review_id=? AND step=? AND fingerprint=?",
                params![self.id, self.step, fingerprint],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(reply) = cached {
            return Ok(serde_json::from_str(&reply)?);
        }

        let split:Option<bool>=self.db.query_row("SELECT interrupted FROM review_splits WHERE review_id=? AND step=? AND fingerprint=?",params![self.id,self.step,fingerprint],|r|r.get(0)).optional()?;
        if let Some(interrupted) = split {
            return if interrupted {
                Err(crate::ReviewBatchInterrupted.into())
            } else {
                Err(crate::ReviewContextExceeded.into())
            };
        }

        let mut retries = 0;
        loop {
            let result = self.dispatch(&fingerprint, &mut call);
            let retry = result.as_ref().err().is_some_and(|e| {
                e.downcast_ref::<reqwest::Error>().is_some_and(|r| {
                    r.is_timeout()
                        || r.is_connect()
                        || r.is_body()
                        || (r.is_request() && r.status().is_none())
                        || r.status().is_some_and(|s| {
                            s == reqwest::StatusCode::TOO_MANY_REQUESTS || s.is_server_error()
                        })
                }) || e
                    .downcast_ref::<crate::provider::InvalidReply>()
                    .is_some_and(|r| {
                        matches!(
                            r.reason,
                            "Provider returned incomplete JSON."
                                | "Provider returned invalid review JSON."
                        )
                    })
            });
            if !retry || retries >= 2 {
                return result;
            }
            retries += 1;
            std::thread::sleep(std::time::Duration::from_secs(5 * retries));
        }
    }

    fn dispatch(
        &mut self,
        fingerprint: &[u8],
        call: impl FnOnce() -> Result<crate::provider::ModelReply>,
    ) -> Result<Value> {
        // Reserve before dispatch, including an in-flight request lost to a crash.
        let turn: Option<u32> = self.db.query_row("UPDATE review_runs SET turns=turns+1 WHERE review_id=?1 AND turns < ?2 RETURNING turns", params![self.id,crate::ReviewTurnLimit::MAX], |r| r.get(0)).optional()?;
        let turn = turn.ok_or(crate::ReviewTurnLimit)?;
        let started = std::time::Instant::now();
        let result = call();
        let ms = i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX);
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE review_runs SET model_ms=model_ms+?,stop_reason=? WHERE review_id=?",
            params![ms, result.as_ref().err().map(turn_error), self.id],
        )?;
        let usage = match &result {
            Ok(reply) => Some(reply.usage),
            Err(error) => error
                .downcast_ref::<crate::provider::InvalidReply>()
                .map(|r| r.usage),
        };
        if let Some(usage) = usage {
            tx.execute("UPDATE review_runs SET
                input_tokens=CASE WHEN ?1 IS NULL THEN input_tokens ELSE coalesce(input_tokens,0)+?1 END,
                output_tokens=CASE WHEN ?2 IS NULL THEN output_tokens ELSE coalesce(output_tokens,0)+?2 END,
                cached_tokens=CASE WHEN ?3 IS NULL THEN cached_tokens ELSE coalesce(cached_tokens,0)+?3 END
                WHERE review_id=?4",params![usage.input,usage.output,usage.cached,self.id])?;
        }
        if let Ok(reply) = &result {
            tx.execute("INSERT OR REPLACE INTO review_turns(review_id,step,fingerprint,reply) VALUES(?,?,?,?)",params![self.id,self.step,fingerprint,serde_json::to_string(&reply.value)?])?;
        }
        if let Err(error) = &result
            && (error.is::<crate::ReviewContextExceeded>()
                || error.is::<crate::ReviewBatchInterrupted>())
        {
            tx.execute("INSERT OR REPLACE INTO review_splits(review_id,step,fingerprint,interrupted) VALUES(?,?,?,?)",params![self.id,self.step,fingerprint,error.is::<crate::ReviewBatchInterrupted>()])?;
        }
        tx.commit()?;
        let status = match &result {
            Ok(_) => "received".to_owned(),
            Err(error) => turn_error(error),
        };
        eprintln!("Review {} turn {turn}: {status} ({ms} ms)", self.id);
        result.map(|r| r.value)
    }
}

fn turn_error(error: &anyhow::Error) -> String {
    if let Some(reply) = error.downcast_ref::<crate::provider::InvalidReply>() {
        return reply.to_string();
    }
    if let Some(err) = error.downcast_ref::<reqwest::Error>() {
        if let Some(status) = err.status() {
            return format!("Provider HTTP {status}.");
        }
        if err.is_timeout() {
            return "Provider timed out.".into();
        }
        return "Provider connection interrupted.".into();
    }
    if error.is::<crate::ReviewContextExceeded>() {
        return "Provider context window exceeded.".into();
    }
    "Model call failed.".into()
}

/// Forget every checkpoint tied to an automatic job that will start a fresh analysis.
pub(crate) fn clear(db: &Connection, id: i64) -> rusqlite::Result<()> {
    for table in [
        "review_turns",
        "review_splits",
        "review_reads",
        "review_origins",
        "review_replays",
        "review_runs",
    ] {
        db.execute(&format!("DELETE FROM {table} WHERE review_id=?"), [id])?;
    }
    Ok(())
}

pub(super) fn finish(db: &Connection, id: i64, status: &str, reason: &str) -> Result<()> {
    db.execute(
        "UPDATE review_runs SET stop_reason=CASE WHEN ?1='failed' THEN coalesce(stop_reason,?2) ELSE ?2 END WHERE review_id=?3",
        params![status,reason, id],
    )?;
    if matches!(status, "completed" | "partial" | "superseded") {
        db.execute("DELETE FROM review_splits WHERE review_id=?", [id])?;
        db.execute("DELETE FROM review_turns WHERE review_id=?", [id])?;
        db.execute(
            "UPDATE review_runs SET snapshot=NULL,prior=NULL WHERE review_id=?",
            [id],
        )?;
    }
    Ok(())
}

pub fn running(db: &Path, id: i64) -> Result<bool> {
    Ok(connect(db)?.query_row(
        "SELECT status='running' FROM reviews WHERE id=?",
        [id],
        |r| r.get(0),
    )?)
}

/// Record which pinned lines the repository returned to the model.
pub fn record_reads(db: &Path, id: i64, windows: &[crate::contracts::SourceWindow]) -> Result<()> {
    if windows.is_empty() {
        return Ok(());
    }
    let mut conn = connect(db)?;
    let tx = conn.transaction()?;
    {
        let mut insert = tx.prepare(
            "INSERT OR IGNORE INTO review_reads (review_id,path,start,end) VALUES (?,?,?,?)",
        )?;
        for window in windows {
            let end = window
                .start
                .saturating_add(window.text.lines().count().saturating_sub(1));
            insert.execute(params![id, window.path, window.start, end])?;
        }
    }
    tx.commit()?;
    Ok(())
}

pub(super) fn metrics(db: &Connection, id: i64) -> rusqlite::Result<Option<String>> {
    db.query_row(
        "SELECT turns,input_tokens,output_tokens,model_ms,CASE WHEN (SELECT status FROM reviews WHERE id=review_id)='failed' THEN stop_reason END FROM review_runs WHERE review_id=?",
        [id],
        |r| {
            let turns: i64 = r.get(0)?;
            let ms: i64 = r.get(3)?;
            let unit = if turns == 1 { "turn" } else { "turns" };
            let mut summary = format!("{turns} model {unit} · {}s waiting for model", ms / 1000);
            if let Some(tokens) = r.get::<_, Option<i64>>(1)? {
                summary.push_str(&format!(" · {tokens} input tokens"));
            }
            if let Some(tokens) = r.get::<_, Option<i64>>(2)? {
                summary.push_str(&format!(" · {tokens} output tokens"));
            }
            if let Some(reason)=r.get::<_,Option<String>>(4)? { summary.push_str(&format!(" · {reason}")); }
            Ok(summary)
        },
    )
    .optional()
}

#[derive(Debug)]
pub struct Paused;
impl std::fmt::Display for Paused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Review paused for shutdown")
    }
}
impl std::error::Error for Paused {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ModelReply, TokenUsage};
    use serde_json::json;

    #[test]
    fn manual_replay_keeps_the_selected_report_and_has_no_publication_job() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        crate::web::recover(&path, "provider").unwrap();
        let conn = connect(&path).unwrap();
        let record = json!({"repo":"owner/repo","base":"a".repeat(40),"head":"b".repeat(40),"findings":[],"focus":[],"limits":["Undecided at src/file.rs:1. Inspect the caller."]});
        conn.execute("INSERT INTO reviews(url,provider,status,report) VALUES ('https://github.com/owner/repo/pull/1','provider','partial',?)",[record.to_string()]).unwrap();
        let source = conn.last_insert_rowid();
        assert!(replay(&path, source, "provider", &Default::default()).is_err());
        let new = replay(
            &path,
            source,
            "provider",
            &["owner/repo".to_string()].into(),
        )
        .unwrap();
        let session = Session::open(&path, new).unwrap();
        assert_eq!(
            session
                .replay_source()
                .unwrap()
                .unwrap()
                .report
                .limits
                .len(),
            1
        );
        assert_eq!(session.revisions().unwrap().unwrap().1, "b".repeat(40));
        let jobs: i64 = conn
            .query_row(
                "SELECT count(*) FROM automation_jobs WHERE review_id=?",
                [new],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(jobs, 0);
        let other = Session::open(
            &path,
            replay(
                &path,
                source,
                "other-provider",
                &["owner/repo".to_string()].into(),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(other.replay_source().unwrap().is_none());
    }

    #[test]
    fn recovery_requeues_checkpointed_manual_work_for_the_same_provider() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        crate::web::recover(&path, "local").unwrap();
        let db = connect(&path).unwrap();
        db.execute("INSERT INTO reviews(url,provider,status) VALUES ('https://github.com/o/r/pull/1','local','running')",[]).unwrap();
        let input = json!({"stage":"confirm"});
        let mut session = Session::open(&path, db.last_insert_rowid()).unwrap();
        session
            .ask("review", &input, || {
                Ok(ModelReply {
                    value: json!({"assessments":[]}),
                    usage: TokenUsage::default(),
                })
            })
            .unwrap();
        drop(session);
        crate::web::recover(&path, "local").unwrap();
        assert!(
            crate::web::run_one_session(&path, |id, _, _| {
                let mut resumed = Session::open(&path, id)?;
                assert_eq!(
                    resumed.ask("review", &input, || panic!("repeated completed call"))?,
                    json!({"assessments":[]})
                );
                Err(Paused.into())
            })
            .unwrap()
        );
        let state: String = db
            .query_row("SELECT status FROM reviews", [], |r| r.get(0))
            .unwrap();
        assert_eq!(state, "queued");
    }

    #[test]
    fn restarting_replays_a_split_without_sending_the_failed_request_again() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        super::super::init_db(&connect(&path).unwrap()).unwrap();
        let input = json!({"source":"wide diff"});
        let mut original = Session::open(&path, 1).unwrap();
        assert!(
            original
                .ask("review", &input, || Err(
                    crate::ReviewBatchInterrupted.into()
                ))
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        drop(original);
        let mut resumed = Session::open(&path, 1).unwrap();
        assert!(
            resumed
                .fits_context("review", &input, || panic!("resized a saved split"))
                .unwrap()
        );
        assert!(
            resumed
                .ask("review", &input, || panic!("already partitioned"))
                .unwrap_err()
                .is::<crate::ReviewBatchInterrupted>()
        );
        assert!(
            metrics(&resumed.db, 1)
                .unwrap()
                .unwrap()
                .contains("1 model turn")
        );
    }

    #[test]
    fn resuming_reuses_only_matching_turns_and_keeps_one_budget() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        super::super::init_db(&connect(&path).unwrap()).unwrap();
        let input = json!({"source":"patch"});
        let answer = || {
            Ok(ModelReply {
                value: json!({"reads":[]}),
                usage: TokenUsage {
                    input: Some(20),
                    output: Some(4),
                    cached: None,
                },
            })
        };
        let mut session = Session::open(&path, 1).unwrap();
        session.ask("review", &input, answer).unwrap();
        drop(session);
        let mut resumed = Session::open(&path, 1).unwrap();
        assert!(
            !resumed
                .fits_context("different", &input, || Ok(false))
                .unwrap()
        );
        assert!(
            !resumed
                .fits_context("review", &json!({"source":"changed"}), || Ok(false))
                .unwrap()
        );
        assert!(
            resumed
                .fits_context("review", &input, || panic!("resized a saved reply"))
                .unwrap()
        );
        resumed
            .ask("review", &input, || panic!("repeated a completed call"))
            .unwrap();
        assert!(
            metrics(&resumed.db, 1)
                .unwrap()
                .unwrap()
                .contains("1 model turn")
        );
        resumed
            .db
            .execute("UPDATE review_runs SET turns=499", [])
            .unwrap();
        resumed.ask("followup", &input, answer).unwrap();
        assert!(
            resumed
                .ask("another", &input, || panic!())
                .unwrap_err()
                .is::<crate::ReviewTurnLimit>()
        );
        drop(resumed);
        let mut restarted = Session::open(&path, 1).unwrap();
        assert!(
            restarted
                .ask("different", &input, || panic!())
                .unwrap_err()
                .is::<crate::ReviewTurnLimit>()
        );
        assert!(
            metrics(&restarted.db, 1)
                .unwrap()
                .unwrap()
                .contains("40 input tokens")
        );
    }
}
