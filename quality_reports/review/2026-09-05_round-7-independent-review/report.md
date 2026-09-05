# ABOUTME: Round-7 independent review of PR #18 at d123a41 and the test-only fix round that followed
# ABOUTME: Reviewer provenance, consolidated verdict, Major fix with mutation evidence, Minor dispositions, fresh gates

# Round 7: independent review of `d123a41` and test-only fixes

Status: four fresh reviewers returned; one supported Major, fixed with test-only changes and re-measured by mutation; all required gates re-run after the last test edit (results below). Merge and W7 remain Max's separate gates.

## Review provenance and scope

Reviewed source: `d123a41023acc7002a05a4002510f17a2551e17b` (tree `a96f78bf644cfeb8d84b6f61f9d5fc5d0fd7c3c3`), byte-identical in Sources, Tests, Package.swift, scripts and docs to the branch HEAD `10d8feb` at review time. Merge base `09e52bc`.

Reviewers: the four harness review agents `architecture-reviewer`, `security-reviewer`, `database-reviewer` and `test-reviewer`, launched fresh, in parallel, each in its own isolated git worktree with the base SHA named in its brief and a read-only `git archive` export of `d123a41`. These are the same reviewer roles that produced the review that opened round 6 (PR comment 5551140217); no Gemini, DeepSeek or other provider was invoked, and no `pi-forge` protected-child reviewer was available. The plan's W6 wording names `pi-forge.*-reviewer`; whether harness reviewers satisfy the independent-review gate is Max's decision, stated here rather than assumed. Two reviewers (architecture, test) were cut once by a transient API server error and resumed by message with their context intact; the test reviewer verified its export clean against `git archive d123a41` before and after every probe.

Only the test reviewer ran Swift (one build or test at a time, inside its own export). The database and security reviewers rebuilt the schema from `DatabaseSchema.swift` on sqlite3 3.54.0 and both reproduced the pinned migration-10 digest `04a5fdb3…9991` byte-exact before probing. Full reports: [architecture](reviews/architecture-reviewer.md), [security](reviews/security-reviewer.md), [database](reviews/database-reviewer.md), [test](reviews/test-reviewer.md).

## Consolidated verdict at `d123a41`

| Severity | Count | Source |
|---|---:|---|
| Critical | 0 | all four |
| Major | 1 | test: the M2 trigger's predicates had no behavioural coverage |
| Minor | 20 raw, 17 after dedup | architecture 7, security 1, database 5, test 7 |

Independent closure of the round-6 Majors:

| Prior | Architecture | Security | Database | Test |
|---|---|---|---|---|
| M1 readback during drain | closed; Swift/SQL state table coherent, one unreachable cell | closed; retained lane id cannot mint | closed; admission matrix measured on the rebuilt schema | closed; SQL side under-evidenced (fixed below) |
| M2 usage INSERT gate | not in scope | closed empirically: 10 forged inserts refused, cap holds | closed empirically: reset, gap, double citation, other lane, netting, timestamp, negative, UPDATE/DELETE all refused; honest appends contiguous | source correct, test under-evidenced: 10/10 single-predicate mutants survived (the Major) |
| M3 historical canary | closed in source; single seam | closed; `Never` reached from 13 entry points | n/a | closed; no weakened assertion; ten functions retired, not nine |
| M4 operator surface | closed; seams internal only | closed; bounds and re-validation traced | n/a | closed; real runtime, store and gates asserted |

## The Major and its fix

`usageInsertCannotForgeBudget` rejects three rows that are each wrong in several ways at once, so deleting any single conjunct of `rollout_authorization_usage_exact_insert` left the store suite green. The reviewer's sweep (11 mutants, build success checked per mutant): 10 survived, only whole-trigger deletion was killed.

Fix, test-only: `usageLedgerRefusesSingleFaultForgeries` in `RolloutAuthorityStoreTests`. Honest sources are consumed by their own AFTER INSERT triggers in the same statement, so the test lifts those fixture-database triggers through a new `withTriggersLifted` helper (recorded SQL, dropped, restored on both paths, presence asserted at the end). Seed branch: the honest seed trigger is replaced by a test trigger that emits the exact seed with one field changed; activation must then fail atomically, leaving zero authorizations and zero ledger rows, for sequence, source kind, source id, timestamp and each of the twelve counters. Append branch: with the effect append lifted, two reservations leave unconsumed sources; the exact next row is computed from the reservation row and each forgery changes exactly one field (sequence gap, kind, id, timestamp, each counter +1); the exact row is then accepted, a second citation of the same source is refused by the UNIQUE key, and with the triggers restored the store's own reservation appends sequence 3 with the expected remaining budget.

Re-measured in an isolated export (`git archive HEAD` plus the six edited test files), same eleven mutants, build success confirmed before every verdict, schema restored byte-exact afterwards (`build/round7/m2-mutants/summary.txt`):

| Mutant | Round-6 tests | Round-7 tests |
|---|---|---|
| M1 contiguity | survived | killed (18 issues) |
| M2 provider counter | survived | killed (10) |
| M3 source_id | survived | killed (16) |
| M4 source_kind | survived | killed (17) |
| M5 timestamp | survived | killed (15) |
| M6 seed provider zero | survived | killed (25) |
| M7 seed activated_at | survived | killed (40) |
| M8 previous-is-latest | survived | **survived: equivalent mutant.** With the primary key on `(authorization_id, sequence)` and `NEW.sequence = previous.sequence + 1`, any `previous` that is not the latest row implies `NEW.sequence` already exists, so the insert is refused by the key whether or not the conjunct is present. It is redundant, harmless, and not claimed killed |
| M9 read_bytes counter | survived | killed (12) |
| M10 seed source_kind | survived | killed (46) |
| M11 whole trigger | killed | killed (52) |

## Minor dispositions (deduplicated)

| # | Finding (reviewer) | Disposition |
|---|---|---|
| 1 | Readback trigger pair duplicates the lane clause with no drift test (architecture 7, test 1) | Fixed: `readbackTriggersShareTheLaneClause` pins byte-equality of the lane-and-pause clause across the GitHub and Git readback triggers, the same remedy E12 applied to the lease pair |
| 2 | `open_lane_close_requires_pause` and the `draining AND paused = 1` disjunct proven only through the Swift path (test 1) | Fixed: `openLaneCloseRequiresPauseAtTheSQLLevel` drives the same UPDATE while resumed (refused with the guard's exact message, lane still active) and after pause (admitted) |
| 3 | Double grants verify/bind of workflow-issued permits under a historical context where the store denies (test 2) | Fixed: the double now denies `verifyProviderPermit`, `bindProviderReservation`, `bindApprovedCommandReservation` (admission closed) and `verifyGitSendPermit` (identity mismatch) under `.historicalCanary`; `doubleDeniesWorkflowPermitsUnderHistoricalContext` pins the double and `workflowProviderPermitIsInertUnderHistoricalContext` pins the store with a real reservation that stays `reserved` and then serves its workflow |
| 4 | `try? settleGitRemoteRead` failure path untested (test 4) | Fixed: `failedReadSettlementKeepsTransportErrorPrimary` uses a double whose settlement throws and a runner that throws; the runner's error surfaces and the reservation stays outstanding |
| 5 | Round-6 report lists nine retired functions, ten were removed (test 5) | Corrected here, not by rewriting the round-6 report: the unlisted tenth is `roleHostReplacementHappyPathIsIsolated`, replaced by `historicalReplacementDenialPreservesEvidence` |
| 6 | `generationRolloverCannotLaunchQ4` expects `effectIdentityMismatch` without saying which boundary (test 7) | Fixed: comment names `verifyProviderLaunchAuthority` reached with no permit |
| 7 | Migration 10 silently drops the schema-9 rollover-resume guards (database 1) | Documented as decision E20, stated in the runbook, pinned by `v10RemovedObjects` in the migration test; the replacement guard is stricter and the Q4 launch authority still requires pause. No schema edit |
| 8 | Readback gate admits exact readbacks after a terminal lane with `paused = 1` (database 2) | By design: locked decision 20 allows read-only lookup and exact late attribution after expiry/revocation; already pinned by `revocation denies fresh effects but preserves exact uncertain-effect readback`. Plan line 198's "once draining begins" is a lower bound, not an upper one |
| 9 | Prior Minors 11/13/14, DDL optimizations (database 3-5) | Re-assessed with EXPLAIN QUERY PLAN: no correctness defect, no full scan on a hot path. Still pending Max's explicit decision because they change the migration body and digest |
| 10 | 1 s real-clock drain timeout vs 2 s poll (test 6) | Recorded as a bounded low-probability race, note only per the reviewer; not changed |
| 11 | 49/51 drift cases hit one guard; fault catalogue referenced by a count (test 3) | Recorded as test debt |
| 12 | Coordinator `.historicalCanary`/`.readback` wrappers inert; quarantine implicit (architecture 1-2) | Recorded as debt; fail-closed and pinned by `JobCoordinatorTests` |
| 13 | Readback reservation has no Swift-side lane/pause guard, SQL refusal untyped (architecture 3) | Recorded as debt; the refused cell is unreachable in production |
| 14 | Retained canary launch machinery can only throw (architecture 4) | Recorded as debt; decision 30 keeps settled replay |
| 15 | Un-pause split between runtime and service; stop/recovery skip the exclusive guard (architecture 5) | Recorded as debt; safe under `EngineService.send` serialization |
| 16 | `JobCoordinator.rolloutAuthority` optional with a nil arm (architecture 6) | Recorded as debt; production passes non-nil, effect and lease gates deny regardless |
| 17 | Executor self-mints a `.workflow` task-local when none is installed (security 1) | Recorded as debt; every production caller installs a context, durable binding checks unaffected |

Debt entries are in `quality_reports/plans/tech-debt.md`; decisions E20-E21 are in the plan.

## Files changed in this round

Tests only, plus documentation: `RolloutAuthorityStoreTests.swift` (four tests, one fixture helper), `RolloutEffectAuthorityTestSupport.swift` (historical-context denial in four methods, opt-in Git settlement failure), `HistoricalCanaryEffectDenialTests.swift`, `GitRolloutPreviewTests.swift`, `SQLiteStoreTests.swift` (`v10RemovedObjects`), a comment in `HerdrPiWorkflowRuntimeTests.swift`, the runbook, the plan (E20, E21, progress) and the tech-debt register. No file under `Sources/` changed; the migration-10 digest is unchanged at `04a5fdb3b2e6935a13a7418419a2aed3a3f0708e317fedf44ed34eebee659991`.

The seed-branch test replaces a trigger and the SQL guard test issues a raw UPDATE, both in the disposable fixture database created by the test; no operational database was opened.

## Fresh verification

All eight required gates ran sequentially after the last test edit, from the [gate status file](logs/15-gate-status.txt), with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `JIDOKA_RELEASE_RUNTIME_ROOT=/private/tmp/jidoka-code-progressive-production-automation/build/runtime-input/qualified-runtime`, each with its own exit code; a failure would have stopped the chain.

| Required command | Result | Raw evidence |
|---|---|---|
| `make check` | PASS, 776 tests / 88 suites, test execution 62.517s; completed 20:27:10 UTC | [07-make-check.log](logs/07-make-check.log) |
| `make test-e2e` | PASS, S1 package, S10 UI flow, S11 Herdr, S12 exact Pi TUI; completed 20:33:15 UTC | [08-test-e2e.log](logs/08-test-e2e.log) |
| `make jidoka-code-production-automation-acceptance` | PASS, 776 tests / 88 suites, all 21 required suites; completed 20:34:20 UTC | [09-acceptance.log](logs/09-acceptance.log) |
| `xcrun swift-format lint --recursive --strict Sources Tests` | PASS, exit 0, empty output | [10-format-lint.log](logs/10-format-lint.log) |
| `xcrun swift build --configuration release --product JidokaCodeApp` | PASS, complete (cached, 0.20s) | [11-release-app.log](logs/11-release-app.log) |
| `xcrun swift build --configuration release --product JidokaCodeEngineProbe` | PASS, complete (cached, 0.11s) | [12-release-engine.log](logs/12-release-engine.log) |
| `xcrun swift build --configuration release --product JidokaCodeHerdrHost` | PASS, complete (cached, 0.11s) | [13-release-herdr-host.log](logs/13-release-herdr-host.log) |
| `git diff --check` | PASS, exit 0, empty output | [14-diff-check.log](logs/14-diff-check.log) |

All times are 2026-09-05. The six new tests bring the suite from 770 to 776 tests; the suite count stays 88. Final aggregate logs contain no known issues and no `.cleanupFailed`. `make check` itself runs `xcrun swift build --configuration release` (log line 89), so the three separately required release commands completed against inputs the preceding gate had just rebuilt, not a timed-out or partial run; no file under `Sources/` changed in this round, so the release inputs are those of `d123a41`. E2E shows the same 16 `write: Permission denied` lines as the accepted round-5 and round-6 logs and then completes every check; S12 reports local synthetic provider exchanges with `provider_network=0`, not live provider calls; the UI stage's accessibility evidence remains the declared contract plus rendered screenshots, not a runtime accessibility-tree claim.

Logs 01, 03 are diagnostic red runs (compile errors in the first draft of the new tests, then a wrong seed-branch strategy that activation refused with `decode("rollout usage ledger")`); 02, 04, 05 are the green rebuild and store-suite runs; 06 is the mutation sweep summary; 07-14 are the required gates; 15 binds their order and exit codes. Pre-existing Keychain deprecation warnings are unchanged.

## Focused re-review of the fix

The test reviewer re-reviewed the delta `d123a41 -> 157d57c` in a fresh isolated worktree ([report](reviews/test-reviewer-rereview.md)). Verdict on the Major: closed. It re-ran the eleven-mutant sweep in its own export with the same result (ten killed, M8 survived; [16-rereview-m2-sweep-summary.txt](logs/16-rereview-m2-sweep-summary.txt)), confirmed M8 equivalent by a SQL probe on a temp database in which every forgery is refused with and without the conjunct ([17-rereview-m8-equivalence-probe.out](logs/17-rereview-m8-equivalence-probe.out)), and checked that the test is not a tautology and that `withTriggersLifted` cannot leak a dropped trigger. The five Minor closures were found sound; the double's new denials were verified against store source and no existing test runs the double under a historical context for the wrong reason.

One new Minor, recorded as debt, not fixed: the cross-lane conjunct `source.authorization_id = previous.authorization_id` (DatabaseSchema.swift:2804) has no test; mutant M12 (`ON 1 = 1`) builds and survives. It is fail-closed (a cross-lane citation could only inflate usage, never reset a cap), the clause is present in source, and the database reviewer's SQL probe refused a foreign-lane source on the rebuilt schema. A two-lane Swift test needs a second activation on a settled first lane and is deferred to the tech-debt register.

Round-7 totals on the fixed HEAD `157d57c`: 0 Critical, 0 Major supported; 18 Minor dispositioned (17 above plus this one).

## Gates that remain closed

No rollout activation, finite promotion, live provider/model call, live workflow Git/GitHub effect, Developer ID signing, notarization, installation, deploy, merge, rollback, tag, release or W7 is performed. Authorized publication is limited to this branch and PR #18. The preceding UI fixture was preserved at `build/round7/preserved-ui-d123a41` (verified identical) before E2E recreated its working fixture; `build/round6/preserved-ui-4206456` is untouched.
