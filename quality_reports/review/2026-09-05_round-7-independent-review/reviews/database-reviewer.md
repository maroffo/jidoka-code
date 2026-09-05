# ABOUTME: Round-7 fresh database review of PR #18 at d123a41 (schema-10 migration, triggers, store SQL)
# ABOUTME: Empirical: schema rebuilt from DatabaseSchema.swift on sqlite3 3.54.0, 98 + 8 + 1 probes, digest recomputed

## Database Review — PR #18 @ d123a41, migration 10 `progressive-production-rollout-authority`

Reviewer: database-reviewer (worktree-isolated; worktree HEAD is the merge base `09e52bc`, all reviewed content read from `SCRATCH/round7/export/` and `git show`). No Swift build or test was run. No database outside `SCRATCH/round7/db/` was opened.

### Scope actually covered
- `Sources/JidokaCodeCore/State/DatabaseSchema.swift` migration 10 (91 statements, lines 1708-3645) in full, plus the migration 1-9 objects it depends on (jobs, app_settings, repositories, repository_leases, mutation_intents, approved_command_runs/results, pi_runs).
- `SQLiteStore.swift` migration runner (:135-171, :381-546), `RolloutAuthorityStore.swift` `transitionLane` (:2040-2118) and reservation ordering (:2170-2180), `RolloutEffectAuthorityStoreTransactions.swift` reservation inserts (created_at_ms sources), `DurableJobStore.swift` lease writes (:616-626, :1690-1760), `JobCoordinator.swift:72`, callers of `heartbeat`.
- `JobCanary.swift` and `MutationIntentStore` (lives in `Reconciliation/MutationReconciler.swift:66`): grep shows neither touches any `rollout_*` table; only 7 source files do (ConfigurationStore, JobCoordinator, DatabaseSchema, DurableJobStore, RolloutAuthorityStore, RolloutEffectAuthorityStore, RolloutEffectAuthorityStoreTransactions). Not reviewed line by line beyond that.
- Plan decisions 2, 3, 10, 11, 22 and lines 123/198 (drain admits only exact readbacks of already-started operations).

### Method and artifacts (all under `SCRATCH/round7/db/`)
| Step | Command | Result |
|---|---|---|
| Extract Swift literals | `uv run python3 extract.py ../export/Sources/JidokaCodeCore/State/DatabaseSchema.swift out` | 10 migrations, 29/14/56/16/2/2/15/24/76/91 statements; migration 10 references only literals + `appendOnlyTrigger(table:operation:)` |
| Resolve refs, recompute digest | `uv run python3 build.py <schema.swift>` (reimplements `migrationDigest` from `SQLiteStoreTests.swift:1287-1300`: `version:`, `name:<b64>`, `backup:`, `statement:<i>:<b64>` joined by `\n`, SHA-256 hex; also reimplements the `piRunLaunchInsertAuthorityV8/V9` closures) | v9 = `48201824…7751` (pinned, match); **v10 = `04a5fdb3b2e6935a13a7418419a2aed3a3f0708e317fedf44ed34eebee659991` (pinned, match)** |
| Rebuild schema | `bash mkdb.sh p.db` (sqlite3 3.54.0; `journal_mode=WAL`, `foreign_keys=ON`, bootstrap ledger, digest column, one `BEGIN IMMEDIATE` per migration, ledger row, exactly as `SQLiteStore.runMigrations`) | `integrity_check ok`, `foreign_key_check` empty, 47 tables / 128 indexes / 142 triggers / 4 views, versions 1-10 |
| Probes | `uv run python3 probe.py p.db` (Python `sqlite3` lib 3.53.1 against the 3.54.0-built file) → `probe-run2.log` | 98 probes, 0 unexpected outcomes |
| Migration safety | `bash mkdb.sh m9.db 9 && uv run python3 migrate-probe.py m9.db` → `migrate-probe.log` | populated v9 → v10 applied; rows preserved |
| Lease shapes + Minor-11 timing | `bash mkdb.sh l.db && uv run python3 lease-and-timing.py l.db` → `lease-timing.log` | 8 probes pass; timing below |

Full probe transcripts: `probe-run2.log`, `migrate-probe.log`, `lease-timing.log`.

### CRITICAL
None.

### MAJOR
None supported. M1 and M2 are closed (evidence below). The digest matches. No new Major found.

### MINOR

- **DatabaseSchema.swift:1713-1714 (migration 10 statements 1-2)** Migration 10 drops the schema-9 guards `app_settings_generation_rollover_resume_denied` and `app_settings_generation_rollover_insert_resume_denied` ("Resume requires separate generation rollover authorization" while `herdr_generation_rollover_authorizations` is non-empty). The replacement `app_settings_rollout_scope_required` (:3582-3619) has no conjunct on `herdr_generation_rollover_authorizations`, so an active rollout lane now permits `paused=0` during a pending generation rollover. The drop is not mentioned in the plan, the round-6 report, the runbook, or any test (`SQLiteStoreTests.swift:746,781` only list the names under `v9AddedObjects`; nothing asserts their absence after v10). Residual safety is intact: the Q4 rollover launch authority still requires `(SELECT paused FROM app_settings WHERE singleton = 1) = 1` (`piRunLaunchInsertAuthorityV9`, DatabaseSchema.swift:6222), so no rollover launch can happen while resumed; the change is a silent replacement of a v9 invariant, not an admission hole. → Either document the decision (plan `## Decisions` row + a `v10RemovedObjects` assertion in `SQLiteStoreTests`) or add `AND NOT EXISTS (SELECT 1 FROM herdr_generation_rollover_authorizations)` under the `NEW.paused = 0` branch of `app_settings_rollout_scope_required`. | evidence: `migrate-probe.log` line "triggers dropped by m10: ['app_settings_generation_rollover_insert_resume_denied', 'app_settings_generation_rollover_resume_denied']"; `grep -rn resume_denied` over plan/report/docs/tests returns only the v9 list.

- **DatabaseSchema.swift:3430-3433 and :3507-3510 (`rollout_readback_reservations_exact_started_effect` :3405, `rollout_git_readback_reservations_exact_started_effect` :3481)** The readback gate admits an exact readback of a `sendStarted`/`observationRequired` effect not only while `draining`/`recoveryRequired` but also after the lane is terminal (`settled`, `revoked`, `expired`, `failed`) as long as `paused = 1`; the usage row is appended to the closed lane's ledger. Plan line 198 phrases the allowance as "once draining begins", decision 22 closes with "finally persists pause and terminal scope". Bounded (exact source row of the same lane, budget-capped, read-only), and arguably useful for recovery after a terminal lane with an uncertain send, but it is a post-terminal append the plan does not state. → Decide and pin: either restrict the second branch to `IN ('draining', 'recoveryRequired')`, or record the post-terminal readback allowance as a decision and add a test. | evidence: `probe-run2.log` "[PASS] OBSERVATION terminal(settled) + paused=1: readback of still-sendStarted E2 admitted: expected=ok got=ok" (lane moved `draining -> settled` while E2 stayed `sendStarted`; the SQL state-transition trigger does not require settled effects, only the store's `requireEffectsSettled` path does).

- **DatabaseSchema.swift:2180, :2213 (prior Minor 11, not applied, re-assessed)** `jobs_rollout_generation_insert/update_authority` filter `state = 'active'` and scan the append-only `rollout_authorizations`; the lease triggers' `state IN ('active','draining','recoveryRequired')` hits the one-open-lane partial index. Not a correctness defect: same rows are returned (active is a subset of the index predicate). Cost at app sizes: 301 authorizations (300 closed lanes), 6.4 us/eval SCAN vs 1.7 us/eval with the IN-conjunct; fires only on generation-1 job inserts and 0->1 promotions. → Optional: add the redundant `AND authorization.state IN ('active','draining','recoveryRequired')` conjunct. | evidence: `lease-timing.log` (EXPLAIN QUERY PLAN `SCAN authorization` vs `SCAN authorization USING INDEX rollout_authorizations_one_open_lane_idx`).

- **DatabaseSchema.swift:2563-2564 (prior Minor 13, not applied, re-assessed)** `UNIQUE(authorization_id, operation_sha256, ordinal)` is implied by `UNIQUE(authorization_id, ordinal)`; a third autoindex (`sqlite_autoindex_rollout_scope_read_reservations_3`) is maintained on every scope-read insert and never chosen by the planner for the `(authorization_id, ordinal)` lookup (it uses `_2`). No correctness impact; write cost is one extra B-tree insert per scope read (bounded by `github_read_requests <= 10000`). → Optional: drop the subsumed constraint. | evidence: `probe-run2.log` section "## 4" (three autoindexes listed; lookup plan `USING COVERING INDEX sqlite_autoindex_rollout_scope_read_reservations_2`).

- **DatabaseSchema.swift:3169-3195 (prior Minor 14, not applied, re-assessed)** The `NOT EXISTS` in `rollout_job_input_snapshots_exact_insert` seeks `rollout_effect_reservations` via `sqlite_autoindex_rollout_effect_reservations_2 (authorization_id=?)` and filters `job_id`/`kind` in the loop: one lane's reservations (hundreds at most under the caps, `jobs <= 10`) are visited per snapshot insert; snapshot inserts are rare (once per job step). No full scan, no correctness impact. → Optional index `(authorization_id, job_id, kind)`. | evidence: `probe-run2.log` "M14 snapshot NOT EXISTS subquery: SEARCH effect USING INDEX sqlite_autoindex_rollout_effect_reservations_2 (authorization_id=?)".

### Closure verdicts on the writer's claims

**M2 (usage ledger INSERT) — CLOSED.** `rollout_authorization_usage_exact_insert` (DatabaseSchema.swift:2715-2830; statement 49) verified on the rebuilt schema:
- Honest paths: activation seed gives sequence 0 all-zero with `created_at_ms = activated_at_ms`; effect, scope-read, GitHub-readback and Git-readback `usage_append` triggers produced 0,1,2 then 4 (githubReadback) contiguously; the BEFORE INSERT trigger did not reject any honest append (probe "exact honest append accepted" in the isolated copy with the effect append trigger dropped, and every AFTER-trigger append in the live db).
- Forgeries refused (all in `probe-run2.log`, section "## 1/M2"): reset row (seq 3 activation zeros), duplicate seed (PK/UNIQUE), gap (seq 4), same source twice (UNIQUE on `authorization_id, source_kind, source_id`), invented source id, E1 re-declared as `scopeRead`, other lane's source (A2 seq 1 with A's E3), counters netting to the same total across two columns (`marker_parts+2, github_sends+0`), under-charged counter, wrong kind for an effect source, timestamp differing from the source's `created_at_ms`, negative and NULL counters, UPDATE and DELETE (append-only).
- Cap still reads the latest sequence (`ORDER BY latest.sequence DESC LIMIT 1`, plan `SEARCH latest USING PRIMARY KEY`); after two `markerBatch` sends exhausted `github_sends = 2`, a third was refused, the forged restore row was refused, and the third stayed refused (ledger latest `(3, marker_parts 2, github_sends 2)`).
- Structural note that makes forgery impossible in practice: every source row is consumed by its own AFTER INSERT trigger in the same statement, so a hand-written usage row can only reference an already-consumed source (UNIQUE) or none (trigger). The only way to obtain an unconsumed source is to drop a trigger, which the test suite's `dropRecordedMigrationDigestColumn`-style gymnastics cannot do in production.

**M1 (readback during drain) — CLOSED at schema level, store path consistent.** `rollout_authorizations_open_lane_close_requires_pause` (:2696-2708) refuses any transition out of an open state while `paused = 0 AND active_rollout_authorization_id = OLD.id` (probes: active->draining and active->settled refused with paused=0; admitted after pause). Admission matrix measured:
| lane state / paused | fresh effect | scope read | exact readback of sendStarted |
|---|---|---|---|
| active / 0 | admitted | admitted | admitted |
| active / 1 | refused | refused | refused (pause without drain freezes readbacks; observation, decision 22 makes drain the stop path) |
| draining / 1 | refused | refused | admitted (reserved-state source refused; githubRead source without intent refused; Git readback needs `branchCreate`) |
| draining / 0 | unreachable: resume while draining refused by `app_settings_rollout_scope_required` (requires `state = 'active'`) |
| terminal / 1 | refused | refused | admitted (see Minor above) |
No combination admits both fresh effects and drain-time readbacks. Twin triggers diffed (`difflib`): the only differences are the table names, `source.kind = 'branchCreate'`, the git_remote_reads cap, and the message; the two `usage_append` twins differ only in which counter they add. Store side (`RolloutAuthorityStore.swift:2079-2091`): `transitionLane` writes `paused = 1` and keeps `active_rollout_authorization_id` when the target is an open lane, nulls it when terminal, in the same `database.transaction` as the state UPDATE and the event insert.

**Prior Minor 12 — CLOSED.** `approved_command_run_state_transition` (:1716-1731): `started -> superseded` with a durable result row refused ("invalid approved command transition"), `started -> resultAccepted` admitted, `started -> superseded` without result admitted, `superseded -> started` refused. The intermediate `started` state was manufactured by dropping `approved_command_start_authority` in the temp db only (documented in `probe.py`). Also holds for a historical started run migrated from v9 (`migrate-probe.log`).

**Prior Minors 11/13/14 — no correctness defect; Minor (optional) as above.**

**Digest (item 7) — MATCH.** Recomputed with the test's exact method: v10 `04a5fdb3…9991`, v9 `48201824…7751` (the v9 match also validates the closure reimplementation used to build the pi_run_launches trigger).

### Schema-10 invariants (plan decisions 2, 3, 10, 11), all probed in `probe-run2.log`
- One open lane: second `active` insert refused by `rollout_authorizations_one_open_lane_idx`; insert in a non-active state refused; activation requires `paused = 1 AND active_rollout_authorization_id IS NULL AND max_concurrency = 1` (a closed lane whose id is still in `app_settings` blocks the next activation until cleared).
- Immutable scope/budget: UPDATE/DELETE refused on scopes and budgets (increase and decrease); authorization identity columns immutable; `terminal_reason`/`updated_at_ms` change only with state; `updated_at_ms` regression refused.
- Append-only: usage, events, authorizations, scopes, budgets, candidates, bindings, snapshots, all four reservation tables (DELETE refused).
- State graph: draining->active, settled->active refused; recoveryRequired->active admitted; terminal needs `terminal_reason` (CHECK); events must evidence the current state.
- `paused = 0` only with exactly one matching active scope: refused with no lane, refused before the single exactObject binding, admitted after; `max_concurrency != 1` refused.
- Exact job binding: cross-repository, wrong canonical input, second slot beyond `budget.jobs` refused; gen 1->0 demotion and out-of-scope promotion refused; gen-1 insert without authority refused.
- Lease gate `(rollout_generation = 1 OR open lane on repository)`: unbound gen-0 job on the lane's repository refused while open (INSERT and the exact reacquisition UPDATE shape from `DurableJobStore.swift:1699-1707`), gen-0 job on another repository admitted, bound gen-1 job admitted with paused=0, gen-1 job refused after the lane closed (INSERT and heartbeat), release (`active = 0`) always admitted, startup release-all admitted, reacquisition admitted after close. Bounded continuation: heartbeat of the bound job admitted during drain, generation bump refused; heartbeat of an unbound gen-0 job refused while a lane is open (consistent with the trigger comment: `DurableJobStore.heartbeat` has no caller in Sources, confirmed by grep).

### Migration safety (item 6)
- Backup: `SQLiteStore.runMigrations` (:511-520) takes an `sqlite3_backup` copy before each `requiresBackup` migration when the file pre-existed; migration 10 declares `requiresBackup: true`.
- Digest column: `addStatementsDigestColumn` (:507-509) runs only after `migrationTooNew` (:500-502) and `verifyAppliedMigrationContent` (:503) pass and only when a migration is pending; `bootstrapMigrationTable` is `CREATE TABLE IF NOT EXISTS` (read-only on an existing ledger).
- Idempotent reopen: only `version > current` runs; an already-current database is not written (no column add, no statements). Re-running statement 5 would fail (`duplicate column name`), so the version gate is the only thing standing between a double application and an error, which is the intended design.
- Old binary fail-closed: `main` (`09e52bc`) `SQLiteStore.swift:394-395` throws `migrationTooNew` when `current > supported`; migration 10 is `verifiesContent: true` (DatabaseSchema.swift:3642), so a database stamped by a different migration-10 body is refused with `migrationContentMismatch`.
- Historical rows: populated v9 database (repository, job in `runningPi`, active lease gen 7, started approved command with result, `sendStarted` mutation intent, `app_settings paused=0 max_concurrency=4`) migrated in one transaction; repositories, leases, approved_command_runs/results, mutation_intents byte-identical; jobs identical plus `rollout_generation = 0`; `app_settings` is the only historical row rewritten, to `paused = 1, max_concurrency = 1, active_rollout_authorization_id NULL, updated_at = unixepoch('subsec')` (intended fail-closed, statement 38). No migration-10 statement rebuilds or copies a table; the two `ALTER TABLE ... ADD COLUMN` are metadata-only (the `REFERENCES` column defaults to NULL, legal with `foreign_keys = ON`). Post-migration: resume without a lane refused, `max_concurrency` back to 4 refused, historical lease heartbeat/release admitted.
- Triggers dropped by migration 10: the two rollover-resume guards (Minor above); `approved_command_run_state_transition` is dropped and recreated narrower.

### Observations (no finding, recorded for the coordinator)
- Ledger `created_at_ms` is coherent with its source but not enforced monotonic across sequences; readback/scope-read `created_at_ms` come from `nowMilliseconds` in the store (`RolloutEffectAuthorityStoreTransactions.swift:310-311, 426, 534`); no reader orders the ledger by time (cap and appends use `sequence`). `RolloutAuthorityStore.swift:2177` orders reservations by `created_at_ms, id` for status only.
- An `INSERT OR REPLACE` on `repository_leases` is not a store shape (the store uses UPDATE for reacquisition); my probe "lease for gen-0 job-0 on repo-1 after lane closed admitted" used it, so the reacquisition shape was re-probed separately in `lease-timing.log`.
- Probes ran through Python's bundled SQLite 3.53.1 against a file built by the 3.54.0 CLI; no feature in migration 10 changed between those releases.

### Could not verify
- Any Swift behaviour: `transitionLane`, `requireEffectsSettled`, real GitHub/Git readback tests during drain, the round-6 test additions (test-reviewer owns execution). Source reading only.
- Whether the post-terminal readback allowance and the rollover-resume guard removal are intended (no decision row found; Max's call).
- Backup-file creation and permissions (`enforceDatabasePermissions`) require running the store.

### Summary
Deployment risk: LOW (additive columns, one intended singleton rewrite, backup + digest + too-new guards, transaction-per-migration).
Recommendation: ACCEPTABLE from the database side. Zero Critical, zero Major; 5 Minor (2 new: undocumented removal of the v9 rollover-resume guards, post-terminal readback admission; 3 re-assessed prior optimizations, none a defect).
