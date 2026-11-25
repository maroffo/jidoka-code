//! Durable model replies for one review at one pinned revision.
use super::{connect, parse_pull_url};
use crate::contracts::{Finding, PublishedReport, Snapshot};
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

pub(crate) fn init(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS review_runs (
        review_id INTEGER PRIMARY KEY, base TEXT, head TEXT, snapshot TEXT, prior TEXT,
        turns INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER, output_tokens INTEGER,
        cached_tokens INTEGER, model_ms INTEGER NOT NULL DEFAULT 0, stop_reason TEXT
    );
    CREATE TABLE IF NOT EXISTS review_subjects (review_id INTEGER PRIMARY KEY, subject TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS review_turns (
        review_id INTEGER NOT NULL, step INTEGER NOT NULL, fingerprint BLOB NOT NULL, reply TEXT NOT NULL,
        PRIMARY KEY(review_id,step)
    );
    CREATE TABLE IF NOT EXISTS agy_invocations (review_id INTEGER PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS review_splits (
        review_id INTEGER NOT NULL,step INTEGER NOT NULL,fingerprint BLOB NOT NULL,interrupted INTEGER NOT NULL,
        PRIMARY KEY(review_id,step)
    );
    CREATE TABLE IF NOT EXISTS review_budgets (
        review_id INTEGER PRIMARY KEY, cap INTEGER NOT NULL, final_reserve INTEGER NOT NULL,
        spent INTEGER NOT NULL DEFAULT 0 CHECK(spent>=0),
        CHECK(cap>0 AND final_reserve>0 AND final_reserve<=cap)
    );
    CREATE TABLE IF NOT EXISTS review_budget_closures (
        review_id INTEGER NOT NULL, step INTEGER NOT NULL, fingerprint BLOB NOT NULL, attempt INTEGER,
        PRIMARY KEY(review_id,step,fingerprint)
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
    if original.report.dry_run {
        ensure!(tx.execute("UPDATE review_prompts SET (instructions,dry_run)=(SELECT instructions,1 FROM review_prompts WHERE review_id=?1 AND dry_run) WHERE review_id=?2", params![id,new_id])? == 1,
            "The original dry-run prompt is unavailable.");
    }
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

enum Admission {
    Dispatch(u32),
    Cached(Value),
    Closed,
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

    pub fn review_method(&self) -> Result<String> {
        let saved: Option<String> = self.db.query_row(
            "SELECT (SELECT instructions FROM review_prompts WHERE review_id=?)",
            [self.id],
            |r| r.get(0),
        )?;
        Ok(saved.unwrap_or_else(|| crate::prompt::DEFAULT_METHOD.to_owned()))
    }

    pub fn agy_invoked(&self) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM agy_invocations WHERE review_id=?)",
            [self.id],
            |r| r.get(0),
        )?)
    }

    /// Claim one AGY process per review. An interrupted paid run needs an explicit replay.
    pub fn claim_agy(&mut self) -> Result<bool> {
        let tx = self.db.transaction()?;
        let claimed = tx.execute(
            "INSERT OR IGNORE INTO agy_invocations(review_id) VALUES(?)",
            [self.id],
        )? == 1;
        if claimed {
            tx.execute(
                "UPDATE review_runs SET turns=1 WHERE review_id=?",
                [self.id],
            )?;
        }
        tx.commit()?;
        Ok(claimed)
    }

    pub fn record_agy_usage(
        &self,
        usage: crate::provider::TokenUsage,
        elapsed_ms: i64,
    ) -> Result<()> {
        self.db.execute("UPDATE review_runs SET input_tokens=?,output_tokens=?,cached_tokens=?,model_ms=? WHERE review_id=?",
            params![usage.input,usage.output,usage.cached,elapsed_ms,self.id])?;
        Ok(())
    }

    /// Pin a prospective spending limit on first use. Existing reviews keep their original limit.
    pub fn configure_budget(&self, cap: u64, final_reserve: u64) -> Result<()> {
        ensure!(
            final_reserve > 0 && final_reserve <= cap,
            "Invalid final review reserve"
        );
        self.db.execute(
            "INSERT INTO review_budgets(review_id, cap, final_reserve) VALUES(?,?,?)
             ON CONFLICT(review_id) DO NOTHING",
            params![self.id, i64::try_from(cap)?, i64::try_from(final_reserve)?],
        )?;
        Ok(())
    }

    /// Available nanoUSD for this stage, or zero when its remaining turns are exhausted.
    pub fn budget_remaining(&self, final_turn: bool) -> Result<u64> {
        Ok(self.db.query_row(
            "SELECT CASE WHEN turns < ?3 THEN max(0,cap-spent-CASE WHEN ?2 THEN 0 ELSE final_reserve END) ELSE 0 END
             FROM review_budgets JOIN review_runs USING(review_id) WHERE review_id=?1",
            params![self.id, final_turn, Self::turn_limit(final_turn)], |row| row.get(0),
        )?)
    }

    fn turn_limit(final_turn: bool) -> usize {
        crate::ReviewTurnLimit::MAX - usize::from(!final_turn)
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
        tx.execute(
            "INSERT OR IGNORE INTO review_runs(review_id) VALUES(?)",
            [self.id],
        )?;
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
             UNION ALL SELECT 1 FROM review_splits WHERE review_id=?1 AND step=?2 AND fingerprint=?3
             UNION ALL SELECT 1 FROM review_budget_closures WHERE review_id=?1 AND step=?2 AND fingerprint=?3)",
            params![self.id, self.step + 1, fingerprint], |row| row.get(0),
        )?;
        if restored { Ok(true) } else { measure() }
    }

    pub fn ask(
        &mut self,
        system: &str,
        data: &Value,
        call: impl FnMut() -> Result<crate::provider::ModelReply>,
    ) -> Result<Value> {
        self.ask_when_eligible(system, data, || Ok(()), call)
    }

    pub fn ask_when_eligible(
        &mut self,
        system: &str,
        data: &Value,
        eligible: impl Fn() -> Result<()>,
        mut call: impl FnMut() -> Result<crate::provider::ModelReply>,
    ) -> Result<Value> {
        self.run_step(system, data, eligible, |session, fingerprint| {
            let turn: Option<u32> = session.db.query_row("UPDATE review_runs SET turns=turns+1
                WHERE review_id=?1 AND turns < ?2 AND NOT EXISTS(SELECT 1 FROM review_budgets WHERE review_id=?1)
                RETURNING turns", params![session.id,crate::ReviewTurnLimit::MAX], |r| r.get(0)).optional()?;
            session.dispatch(fingerprint, turn.ok_or(crate::ReviewTurnLimit)?, None, &mut call, |_| None)
        })
    }

    /// Prepare the exact bounded request outside a write transaction. Admission rechecks both
    /// money and turns under the write lock before any provider generation can start.
    #[allow(clippy::too_many_arguments)]
    pub fn ask_budgeted<T>(
        &mut self,
        system: &str,
        data: &Value,
        final_turn: bool,
        eligible: impl Fn() -> Result<()>,
        mut prepare: impl FnMut(u64) -> Result<Option<(u64, T)>>,
        mut call: impl FnMut(T) -> Result<crate::provider::ModelReply>,
        charge: impl Fn(crate::provider::TokenUsage) -> Option<u64>,
    ) -> Result<Value> {
        self.run_step(system, data, &eligible, |session, fingerprint| {
            let available = session.budget_remaining(final_turn)?;
            if available == 0 {
                return session.close_budget(fingerprint);
            }
            let Some((maximum, request)) = prepare(available)? else {
                return session.close_budget(fingerprint);
            };
            ensure!(maximum > 0, "Review call has no positive cost estimate");
            if maximum > available {
                return session.close_budget(fingerprint);
            }
            eligible()?;
            let maximum = i64::try_from(maximum)?;
            let turn = match session.reserve_budgeted(maximum, final_turn, fingerprint)? {
                Admission::Dispatch(turn) => turn,
                Admission::Cached(value) => return Ok(value),
                Admission::Closed => return session.close_budget(fingerprint),
            };
            // A crash from here on leaves the complete maximum charged for the unknown outcome.
            session.dispatch(fingerprint, turn, Some(maximum), || call(request), &charge)
        })
    }

    fn reserve_budgeted(
        &mut self,
        maximum: i64,
        final_turn: bool,
        fingerprint: &[u8],
    ) -> Result<Admission> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(reply) = Self::saved_step(&tx, self.id, self.step, fingerprint)? {
            return Ok(Admission::Cached(reply));
        }
        let admitted = tx.execute(
            "UPDATE review_budgets SET spent=spent+?2 WHERE review_id=?1
             AND cap-spent-CASE WHEN ?3 THEN 0 ELSE final_reserve END >= ?2",
            params![self.id, maximum, final_turn],
        )?;
        if admitted == 0 {
            return Ok(Admission::Closed);
        }
        let turn: Option<u32> = tx.query_row(
            "UPDATE review_runs SET turns=turns+1 WHERE review_id=?1 AND turns < ?2 RETURNING turns",
            params![self.id, Self::turn_limit(final_turn)], |row| row.get(0),
        ).optional()?;
        let Some(turn) = turn else {
            return Ok(Admission::Closed);
        };
        // Until reply and usage commit together, the outcome is unknown. A restart follows
        // the same budget-close path instead of paying a second time for this generation.
        tx.execute(
            "INSERT INTO review_budget_closures(review_id,step,fingerprint,attempt) VALUES(?,?,?,?)",
            params![self.id, self.step, fingerprint, turn],
        )?;
        tx.commit()?;
        Ok(Admission::Dispatch(turn))
    }

    fn close_budget(&self, fingerprint: &[u8]) -> Result<Value> {
        self.db.execute("INSERT OR IGNORE INTO review_budget_closures(review_id,step,fingerprint) VALUES(?,?,?)",
            params![self.id,self.step,fingerprint])?;
        Err(crate::engine::ReviewBudgetClosed.into())
    }

    fn saved_step(
        db: &Connection,
        id: i64,
        step: usize,
        fingerprint: &[u8],
    ) -> Result<Option<Value>> {
        let cached: Option<String> = db
            .query_row(
                "SELECT reply FROM review_turns WHERE review_id=? AND step=? AND fingerprint=?",
                params![id, step, fingerprint],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(reply) = cached {
            return Ok(Some(serde_json::from_str(&reply)?));
        }

        let split:Option<bool>=db.query_row("SELECT interrupted FROM review_splits WHERE review_id=? AND step=? AND fingerprint=?",params![id,step,fingerprint],|r|r.get(0)).optional()?;
        if let Some(interrupted) = split {
            return if interrupted {
                Err(crate::ReviewBatchInterrupted.into())
            } else {
                Err(crate::ReviewContextExceeded.into())
            };
        }

        if db.query_row("SELECT EXISTS(SELECT 1 FROM review_budget_closures WHERE review_id=? AND step=? AND fingerprint=?)",
            params![id,step,fingerprint], |r|r.get::<_,bool>(0))? {
            return Err(crate::engine::ReviewBudgetClosed.into());
        }
        Ok(None)
    }

    fn run_step(
        &mut self,
        system: &str,
        data: &Value,
        eligible: impl Fn() -> Result<()>,
        mut dispatch: impl FnMut(&mut Self, &[u8]) -> Result<Value>,
    ) -> Result<Value> {
        self.step += 1;
        let fingerprint = Self::fingerprint(system, data)?;
        if let Some(reply) = Self::saved_step(&self.db, self.id, self.step, &fingerprint)? {
            return Ok(reply);
        }
        let mut retries = 0;
        loop {
            eligible()?;
            let result = dispatch(self, &fingerprint);
            if result.as_ref().is_err_and(|e| {
                e.is::<crate::ReviewBatchInterrupted>() || e.is::<crate::ReviewContextExceeded>()
            }) {
                return result;
            }
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
        turn: u32,
        maximum: Option<i64>,
        call: impl FnOnce() -> Result<crate::provider::ModelReply>,
        charge: impl Fn(crate::provider::TokenUsage) -> Option<u64>,
    ) -> Result<Value> {
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
        let mut current = true;
        if let Some(maximum) = maximum {
            current = tx.execute(
                "DELETE FROM review_budget_closures WHERE review_id=? AND step=? AND fingerprint=? AND attempt=?",
                params![self.id, self.step, fingerprint, turn],
            )? == 1;
            // A length stop can be reported as a context error after paid generation.
            // Only an explicit quota rejection with no usage establishes no generation.
            let actual = settled_charge(maximum, result.as_ref().err(), usage.and_then(charge));
            // Saturate the ledger on unrepresentable provider overruns, always denying later calls.
            tx.execute(
                "UPDATE review_budgets SET spent=min(spent-?2,9223372036854775807-?3)+?3
                WHERE review_id=?1",
                params![self.id, maximum, actual],
            )?;
        }
        if let Some(usage) = usage {
            tx.execute("UPDATE review_runs SET
                input_tokens=CASE WHEN ?1 IS NULL THEN input_tokens ELSE coalesce(input_tokens,0)+?1 END,
                output_tokens=CASE WHEN ?2 IS NULL THEN output_tokens ELSE coalesce(output_tokens,0)+?2 END,
                cached_tokens=CASE WHEN ?3 IS NULL THEN cached_tokens ELSE coalesce(cached_tokens,0)+?3 END
                WHERE review_id=?4",params![usage.input,usage.output,usage.cached,self.id])?;
        }
        if !current {
            // A reset while this generation was in flight supersedes its checkpoint.
            tx.commit()?;
            return Err(Paused.into());
        }
        if let Ok(reply) = &result {
            tx.execute("INSERT OR REPLACE INTO review_turns(review_id,step,fingerprint,reply) VALUES(?,?,?,?)",params![self.id,self.step,fingerprint,serde_json::to_string(&reply.value)?])?;
            tx.execute("DELETE FROM provider_cooldowns WHERE provider=(SELECT provider FROM reviews WHERE id=?)
                AND retry_at<=unixepoch()", [self.id])?;
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

fn settled_charge(maximum: i64, error: Option<&anyhow::Error>, priced: Option<u64>) -> i64 {
    match priced {
        Some(cost) => i64::try_from(cost).unwrap_or(i64::MAX),
        None if error.is_some_and(|e| e.is::<crate::provider::RateLimited>()) => 0,
        None => maximum,
    }
}

fn turn_error(error: &anyhow::Error) -> String {
    if let Some(limited) = error.downcast_ref::<crate::provider::RateLimited>() {
        return limited.to_string();
    }
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
        "review_budget_closures",
        "review_reads",
        "review_subjects",
        "review_origins",
        "review_replays",
    ] {
        db.execute(&format!("DELETE FROM {table} WHERE review_id=?"), [id])?;
    }
    // Paid attempts belong to the review ID, including when an automatic review restarts
    // on a fresh merge base. Legacy unbudgeted jobs retain their original reset behavior.
    db.execute("DELETE FROM review_runs WHERE review_id=?1 AND NOT EXISTS (SELECT 1 FROM review_budgets WHERE review_id=?1) AND NOT EXISTS (SELECT 1 FROM agy_invocations WHERE review_id=?1)",[id])?;
    db.execute("UPDATE review_runs SET base=NULL,head=NULL,snapshot=NULL,prior=NULL,stop_reason=NULL WHERE review_id=?",[id])?;
    Ok(())
}

pub(super) fn finish(db: &Connection, id: i64, status: &str, reason: &str) -> Result<()> {
    db.execute(
        "UPDATE review_runs SET stop_reason=CASE WHEN ?1='failed' THEN coalesce(stop_reason,?2) ELSE ?2 END WHERE review_id=?3",
        params![status,reason, id],
    )?;
    if matches!(status, "completed" | "partial" | "superseded" | "canceled") {
        db.execute("DELETE FROM review_splits WHERE review_id=?", [id])?;
        db.execute("DELETE FROM review_turns WHERE review_id=?", [id])?;
        db.execute("DELETE FROM review_budget_closures WHERE review_id=?", [id])?;
        // Keep the short change subject after discarding the full review input.
        db.execute(
            "INSERT OR REPLACE INTO review_subjects(review_id, subject)
             SELECT review_id, substr(json_extract(snapshot, '$.intent[0]'),1,240)
             FROM review_runs WHERE review_id=? AND CASE WHEN json_valid(snapshot)
             THEN json_type(snapshot,'$.intent[0]')='text' ELSE 0 END",
            [id],
        )?;
        db.execute(
            "UPDATE review_runs SET snapshot=NULL,prior=NULL WHERE review_id=?",
            [id],
        )?;
    }
    Ok(())
}

pub fn running(db: &Path, id: i64) -> Result<bool> {
    Ok(connect(db)?.query_row(
        "SELECT status='running' AND NOT EXISTS (
             SELECT 1 FROM ineligible_automatic_reviews WHERE review_id=reviews.id
         ) FROM reviews WHERE id=?",
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
        "SELECT turns,input_tokens,output_tokens,model_ms,CASE WHEN (SELECT status FROM reviews WHERE id=review_id)='failed' THEN stop_reason END, EXISTS(SELECT 1 FROM agy_invocations a WHERE a.review_id=review_runs.review_id), cached_tokens FROM review_runs WHERE review_id=?",
        [id],
        |r| {
            let turns: i64 = r.get(0)?;
            let ms: i64 = r.get(3)?;
            let unit = if turns == 1 { "turn" } else { "turns" };
            let agy = r.get::<_,bool>(5)?;
            let mut summary = if agy && ms == 0 { "AGY session started · elapsed time not yet recorded".to_owned() }
                else if agy { format!("AGY session · {}m {}s elapsed", ms / 60_000, ms / 1000 % 60) }
                else { format!("{turns} model {unit} · {}s waiting for model", ms / 1000) };
            if agy && let Some(cached) = r.get::<_,Option<i64>>(6)? {
                summary.push_str(&format!(" · {cached} cached input tokens"));
            }
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
    fn a_rate_limit_returns_to_the_queue_without_another_model_call() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        super::super::init_db(&connect(&path).unwrap()).unwrap();
        let mut session = Session::open(&path, 1).unwrap();
        let error = session
            .ask("review", &json!({}), || {
                Err(crate::provider::RateLimited::new(None).into())
            })
            .unwrap_err();
        assert!(error.is::<crate::provider::RateLimited>());
        let (turns, reason): (i64, String) = session
            .db
            .query_row(
                "SELECT turns, stop_reason FROM review_runs WHERE review_id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(turns, 1);
        assert!(reason.contains("429"));
    }

    #[test]
    fn a_paused_request_does_not_consume_a_model_turn() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        super::super::init_db(&connect(&path).unwrap()).unwrap();
        let mut session = Session::open(&path, 1).unwrap();
        assert!(
            session
                .ask_when_eligible(
                    "review",
                    &json!({}),
                    || Err(Paused.into()),
                    || panic!("provider was called")
                )
                .unwrap_err()
                .is::<Paused>()
        );
        assert!(
            metrics(&session.db, 1)
                .unwrap()
                .unwrap()
                .contains("0 model turns")
        );
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

    fn budget_fixture() -> (tempfile::TempDir, Session) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviews.db");
        super::super::init_db(&connect(&path).unwrap()).unwrap();
        let session = Session::open(&path, 1).unwrap();
        session.configure_budget(100, 20).unwrap();
        (dir, session)
    }

    fn ledger(session: &Session) -> (u64, u32) {
        session.db.query_row("SELECT spent,turns FROM review_budgets JOIN review_runs USING(review_id) WHERE review_id=?",
            [session.id],|r| Ok((r.get(0)?,r.get(1)?))).unwrap()
    }

    fn priced_reply(actual: Option<u64>) -> Result<ModelReply> {
        Ok(ModelReply {
            value: json!({"complete":true}),
            usage: TokenUsage {
                input: actual,
                ..Default::default()
            },
        })
    }

    fn saved(session: &mut Session, step: &str) -> Result<Value> {
        let input = json!({});
        assert!(session.fits_context(step, &input, || panic!("resized a saved step"))?);
        session.ask_budgeted(
            step,
            &input,
            false,
            || panic!("rechecked a saved step"),
            |_| -> Result<Option<(u64, ())>> { panic!("repriced a saved step") },
            |_| panic!("sent a saved step"),
            |_| panic!("recharged a saved step"),
        )
    }

    fn send(
        session: &mut Session,
        system: &str,
        final_turn: bool,
        mut quote: impl FnMut(u64) -> Option<u64>,
        mut generate: impl FnMut() -> Result<ModelReply>,
    ) -> Result<Value> {
        session.ask_budgeted(
            system,
            &json!({}),
            final_turn,
            || Ok(()),
            |available| Ok(quote(available).map(|maximum| (maximum, ()))),
            |_| generate(),
            |usage| usage.input,
        )
    }

    #[test]
    fn admission_rechecks_a_stale_quote_and_replays_the_same_close_and_final() {
        let (dir, mut outer) = budget_fixture();
        let path = dir.path().join("reviews.db");
        let mut concurrent = Session::open(&path, 1).unwrap();
        let denied = send(
            &mut outer,
            "work",
            false,
            |available| {
                assert_eq!(available, 80);
                send(
                    &mut concurrent,
                    "other",
                    false,
                    |_| Some(60),
                    || priced_reply(Some(35)),
                )
                .unwrap();
                Some(80)
            },
            || panic!("stale quote crossed the final reserve"),
        )
        .unwrap_err();
        assert!(denied.is::<crate::engine::ReviewBudgetClosed>());
        assert_eq!(ledger(&outer), (35, 1));
        send(
            &mut outer,
            "final",
            true,
            |available| {
                assert_eq!(available, 65);
                Some(available)
            },
            || priced_reply(None),
        )
        .unwrap();
        assert_eq!(ledger(&outer), (100, 2));
        let mut resumed = Session::open(&path, 1).unwrap();
        resumed.configure_budget(1_000, 100).unwrap();
        assert!(
            saved(&mut resumed, "work")
                .unwrap_err()
                .is::<crate::engine::ReviewBudgetClosed>()
        );
        assert_eq!(
            saved(&mut resumed, "final").unwrap(),
            json!({"complete":true})
        );
        resumed.reset().unwrap();
        assert_eq!(ledger(&resumed), (100, 2));
        assert!(
            send(
                &mut resumed,
                "after base change",
                true,
                |_| panic!("changed cap"),
                || panic!()
            )
            .unwrap_err()
            .is::<crate::engine::ReviewBudgetClosed>()
        );
    }

    #[test]
    fn an_inflight_unknown_charge_survives_process_loss_without_duplicate_generation() {
        let (dir, mut session) = budget_fixture();
        let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            send(
                &mut session,
                "work",
                false,
                |_| Some(50),
                || panic!("simulated worker exit"),
            )
        }));
        assert!(crashed.is_err());
        drop(session);
        let mut resumed = Session::open(&dir.path().join("reviews.db"), 1).unwrap();
        assert!(
            saved(&mut resumed, "work")
                .unwrap_err()
                .is::<crate::engine::ReviewBudgetClosed>()
        );
        assert_eq!(ledger(&resumed), (50, 1));
        resumed
            .db
            .execute("UPDATE review_runs SET turns=499", [])
            .unwrap();
        assert!(
            send(
                &mut resumed,
                "next",
                false,
                |_| panic!("priced a protected turn"),
                || panic!()
            )
            .unwrap_err()
            .is::<crate::engine::ReviewBudgetClosed>()
        );
        send(&mut resumed, "final", true, Some, || priced_reply(Some(22))).unwrap();
        assert_eq!(ledger(&resumed), (72, 500));
    }

    #[test]
    fn quota_rejections_refund_but_context_errors_with_unknown_usage_retain_the_reservation() {
        let (dir, mut session) = budget_fixture();
        assert!(
            send(
                &mut session,
                "limited",
                false,
                |_| Some(40),
                || Err(crate::provider::RateLimited::new(None).into())
            )
            .unwrap_err()
            .is::<crate::provider::RateLimited>()
        );
        assert_eq!(ledger(&session), (0, 1));
        let mut resumed = Session::open(&dir.path().join("reviews.db"), 1).unwrap();
        assert!(
            send(
                &mut resumed,
                "limited",
                false,
                |_| Some(40),
                || Err(crate::ReviewContextExceeded.into())
            )
            .unwrap_err()
            .is::<crate::ReviewContextExceeded>()
        );
        assert_eq!(ledger(&resumed), (40, 2));
        let mut replay = Session::open(&dir.path().join("reviews.db"), 1).unwrap();
        assert!(
            saved(&mut replay, "limited")
                .unwrap_err()
                .is::<crate::ReviewContextExceeded>()
        );
        assert_eq!(ledger(&replay), (40, 2));
        let length = anyhow::Error::new(crate::ReviewContextExceeded);
        assert_eq!(settled_charge(40, Some(&length), Some(11)), 11);
    }

    #[test]
    fn a_reported_overrun_charges_the_actual_amount_and_blocks_further_spend() {
        let (_dir, mut session) = budget_fixture();
        send(
            &mut session,
            "work",
            false,
            |_| Some(50),
            || priced_reply(Some(130)),
        )
        .unwrap();
        assert_eq!(ledger(&session), (130, 1));
        assert!(
            send(
                &mut session,
                "final",
                true,
                |_| panic!("priced overrun"),
                || panic!()
            )
            .unwrap_err()
            .is::<crate::engine::ReviewBudgetClosed>()
        );
    }

    #[test]
    fn a_transient_generation_failure_cannot_retry_into_the_reserved_money() {
        let (_dir, mut session) = budget_fixture();
        let mut quoted = Vec::new();
        let mut calls = 0;
        let error = send(
            &mut session,
            "work",
            false,
            |available| {
                quoted.push(available);
                (available >= 60).then_some(60)
            },
            || {
                calls += 1;
                let response = axum::http::Response::builder()
                    .status(503)
                    .body("")
                    .unwrap();
                Err(reqwest::Response::from(response)
                    .error_for_status()
                    .unwrap_err()
                    .into())
            },
        )
        .unwrap_err();
        assert!(error.is::<crate::engine::ReviewBudgetClosed>());
        assert_eq!(quoted, [80, 20]);
        assert_eq!(calls, 1);
        assert_eq!(ledger(&session), (60, 1));
    }
}
