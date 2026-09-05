# ABOUTME: Round-7 re-review (test role) of PR #18 fix commit d123a41 -> 157d57c: Major closure verdict, mutation sweep, Minor closures
# ABOUTME: Evidence: eleven-mutant sweep re-run, M8 equivalence probe, two extra mutants (M12, G1), parity checks against the store

# Test Review (re-review) — PR #18 round-7 fix commit, delta d123a41 -> 157d57c

Reviewer: test-reviewer (same role that opened the round-7 Major). Base SHA under review: `157d57c214001391b9bb406fafa6f3fd693e5dbf`. Isolation confirmed before any write: brief asserts `isolation: "worktree"` and names the SHA; `git rev-parse --git-dir` (`.git/worktrees/agent-a9f5a5f52c16f778e`) differs from `--git-common-dir` (`.git`). All builds ran in my own export (`<worktree>/export`, `git archive 157d57c | tar -x`), one `swift build`/`swift test` at a time, files restored and hash-checked after every mutant. No shared git state touched, no network, no provider calls. The primary checkout and `/private/tmp/jidoka-code-progressive-production-automation` were not touched.

## Scope covered

The seven files of `round7-delta.patch` (+506/-1, test-only plus docs, no `Sources/` change), read with `git show 157d57c:<path>`:

- `Tests/JidokaCodeCoreTests/RolloutAuthorityStoreTests.swift` (new tests at 1060-1470, `withTriggersLifted` at 2974-3005)
- `Tests/JidokaCodeCoreTests/RolloutEffectAuthorityTestSupport.swift` (double: `failGitReadSettlement`, `settleGitRemoteRead` override, `denyHistoricalContext` in verify/bind provider, bind command, historical guard in `verifyGitSendPermit`)
- `Tests/JidokaCodeCoreTests/HistoricalCanaryEffectDenialTests.swift` (`doubleDeniesWorkflowPermitsUnderHistoricalContext`)
- `Tests/JidokaCodeCoreTests/GitRolloutPreviewTests.swift` (`failedReadSettlementKeepsTransportErrorPrimary`)
- `Tests/JidokaCodeCoreTests/SQLiteStoreTests.swift` (`v10RemovedObjects`)
- `Tests/JidokaCodeCoreTests/HerdrPiWorkflowRuntimeTests.swift` (comment at 1610-1613)
- `docs/operations/progressive-production-rollout.md`

Source read for parity/tautology checks (unchanged since d123a41): `DatabaseSchema.swift` 1952-1995 (usage table, seed trigger), 2715-2830 (exact-insert gate), 2842-2870 (effect append), 3405-3445 (readback trigger); `RolloutEffectAuthorityStore.swift` 460-545, 677-687; `RolloutEffectAuthorityStoreTransactions.swift` 1040-1053; `RolloutEffectAuthority.swift` 555-567 (protocol default `settleGitRemoteRead`); `GitTransport.swift` 565-592 (`runRemoteRead`); `HerdrPiWorkflowExecutor.swift` 4912-4927, 5198-5213.

## 1. The Major (usage ledger single-fault forgeries)

### 1a. Mutation sweep re-run (my export, 157d57c)

Script: `SCRATCH/round7/rr-m2/sweep.sh` (same eleven mutants and sed anchors as my round-7 sweep and the writer's `fix/m2-sweep.sh`; anchors verified against the export before running). Filter `RolloutAuthorityStoreTests`. Full logs and diffs under `SCRATCH/round7/rr-m2/`.

```
baseline build ok
baseline: exit=0 | Test run with 49 tests in 2 suites passed
M8_previous_is_latest: SURVIVED
M1_contiguity:          KILLED (18 issues, usageLedgerRefusesSingleFaultForgeries)
M2_provider_counter:    KILLED (10)
M3_source_id:           KILLED (16)
M4_source_kind:         KILLED (17)
M5_timestamp:           KILLED (15)
M6_seed_provider_zero:  KILLED (25)
M7_seed_activated_at:   KILLED (40)
M9_read_bytes_counter:  KILLED (12)
M10_seed_source_kind:   KILLED (46)
M11_whole_trigger:      KILLED (52; also usageInsertCannotForgeBudget)
restored sha256 bdfe12bb... (match=yes); restore build exit=0
```

Identical to the writer's `m2-sweep-summary.txt` (same kill set, same issue counts) and a full reversal of my round-7 sweep at d123a41, where all ten mutants survived (`SCRATCH/round7/tr-m2-mutants/summary.txt`). The seed mutants (M6, M7, M10) being killed is also the proof that the seed branch is not vacuous: under those mutants `fixture.activate()` succeeded with a forged seed and the `#expect(throws:)` at 1233 fired, so activation is not failing for some unrelated reason when the honest seed trigger is lifted.

### 1b. M8 equivalence

Claim: `previous.sequence = (SELECT MAX(sequence) ...)` (DatabaseSchema.swift:2806-2809) is subsumed by `PRIMARY KEY(authorization_id, sequence)` (1972) plus `NEW.sequence = previous.sequence + 1` (2810). Verified by reasoning and by a SQL probe.

Reasoning: `previous` is bound by `NEW.sequence = previous.sequence + 1`, and the PK makes the row at `NEW.sequence - 1` unique, so the MAX clause only adds "that row is also the latest". The two disagree only when `NEW.sequence - 1` exists and is not the maximum, i.e. `NEW.sequence <= MAX`. Sequences are contiguous from 0 by induction (seed writes 0, every append needs `previous` at `n-1`, `appendOnlyTrigger(UPDATE|DELETE)` on the ledger at 2831-2832 forbids removal or renumbering), so in that case the row at `NEW.sequence` already exists and the PK refuses the INSERT. Both variants refuse; only the refusal message differs (`RAISE(ABORT)` vs `UNIQUE constraint failed`), and the test asserts `SQLiteStoreError.self` plus an unchanged row count, which both satisfy.

Probe (`SCRATCH/round7/rr-m2/m8-probe.sql`, run with `sqlite3` on a temp database, output in `m8-probe.out`): reduced ledger with the same PK/UNIQUE, append-only triggers, and the gate with (A) and without (B) the MAX clause.

```
A1 seq 2 citing s3 (previous=1 not latest): A: lacks exact contiguous source
A2 seq 1 citing s3:                          A: lacks exact contiguous source
A3 seq 4 citing s3 (no previous):            A: lacks exact contiguous source
A4 seq 3 exact (honest):                     accepted
B1 seq 2 citing s4 (previous=1 not latest):  UNIQUE constraint failed: usage.auth, usage.seq
B2 seq 1 citing s4:                          UNIQUE constraint failed: usage.auth, usage.seq
B3 seq 5 citing s4 (no previous):            B: lacks exact contiguous source
B4 seq 4 exact (honest):                     accepted
delete row 1:   append only
renumber row 1: append only
```

Verdict: M8 is EQUIVALENT under every reachable ledger state. The writer's claim stands.

### 1c. Tautology and trigger-lift leak check

- Seed branch (1245-1290): every forgery is the honest seed row (1978-1992) with exactly one field changed (sequence, source_kind, source_id, created_at_ms, or one counter set to 1). Each replacement trigger is dropped after use (1288); activation must throw and leave zero authorization rows and zero usage rows. After restoration, honest activation writes the exact zero row (1292-1293). Non-vacuous per 1a.
- Append branch (1296-1368): with `rollout_effect_reservations_usage_append` lifted, two reservations leave unconsumed sources; `exactAppend` (1308-1319) recomputes the honest next row from the actual `rollout_effect_reservations` row and the actual sequence-0 row, so every forgery is the exact next row with one field changed. Refusals are checked with a row-count invariant after each (1241). The honest row is then accepted (1345-1349), the second citation of the same source is refused by `UNIQUE(authorization_id, source_kind, source_id)` (1352-1361, comment says so and is correct: the arithmetic passes the gate, the UNIQUE refuses), and a second honest row is accepted (1362-1367).
- Restoration: `withTriggersLifted` (2974-3005) records the trigger's own `sqlite_master.sql`, drops, and re-executes it on both the normal and the throwing path. The test then proves the restored append trigger is functional, not merely present: the store's own `reserveEffect` appends sequence 3 (1371-1385) and remaining `providerSessions == 1` (1386-1389); the final `sqlite_master` count of the two names is 2 (1390-1398). Each test owns a fresh temp database (`RolloutAuthorityFixture.make`, 2564-2575), so a dropped trigger cannot reach another test.
- Note (not a finding, no observable impact): in `withTriggersLifted`, if `DROP TRIGGER` for the second name in a multi-name call threw, the first name would already be dropped and not restored (the `do/catch` at 2986 starts after the loop). Both call sites pass one name, and a throw there fails the test anyway.

### Verdict on the Major: CLOSED

Evidence: the sweep above (10/11 killed, M8 equivalent by proof and probe), the seed branch shown non-vacuous by M6/M7/M10, restoration proven functional by the post-restore honest append.

## 2. Minor closures in the same commit

| Item | File:line (157d57c) | Assessment |
|------|---------------------|------------|
| `openLaneCloseRequiresPauseAtTheSQLLevel` | RolloutAuthorityStoreTests.swift:1400-1438 | Sound. Asserts `paused == 0` after activation (1409), the exact trigger message (1425-1429, matches DatabaseSchema.swift:2706), state unchanged (1431), then the same UPDATE accepted after `paused = 1` (1436-1437). Positive and negative path, deciding conjunct isolated. |
| `readbackTriggersShareTheLaneClause` | 1440-1473 | Sound as a drift guard. The slice from `AND source.state IN (...)` to the next `AND usage.` (1452-1459) covers the lane clause in both triggers (DatabaseSchema.swift:3428-3435 for GitHub; Git at 3481+), and 1464-1472 assert the clause's content, so the equality is not over an empty or off-target range. Same remedy as `bothTriggersShareTheSameGate`. |
| `workflowProviderPermitIsInertUnderHistoricalContext` (store) | 1475-1517 | Sound. Reservation issued under a workflow context, bind/verify under a historical context refused with `effectAdmissionClosed` (matches RolloutEffectAuthorityStore.swift:474-481 and 536-543: `.reservation` permit plus non-`.workflow` context hits the `effectAdmissionClosed` guard), state stays `reserved` (1508), then the same permit binds/verifies under the workflow and reaches `sendStarted` (1510-1516). |
| `doubleDeniesWorkflowPermitsUnderHistoricalContext` + double changes | HistoricalCanaryEffectDenialTests.swift:139-186; RolloutEffectAuthorityTestSupport.swift:132, 153, 188, 280-282 | Parity verified against the store by source: verify/bind provider -> `effectAdmissionClosed` (store 474-481, 536-543), bind command -> `effectAdmissionClosed` (store 677-687), verify gitSend -> `effectIdentityMismatch` (Transactions 1040-1053: admission open, `.reservation` permit, then the workflow-context guard throws identity mismatch). The test also proves the permits still serve the workflow afterwards (181-186), so the double did not become a blanket denier. No existing test now passes for the wrong reason: the only tests that run the double under a historical context are in `HistoricalCanaryEffectDenialTests` (grep of `historicalCanary` across `Tests/`: the four Herdr fixtures at 1687/4070/4342/4455 never enter a historical context; `DurableJobStoreTests.swift:1076` uses the real store). |
| `failedReadSettlementKeepsTransportErrorPrimary` | GitRolloutPreviewTests.swift:131-168; double 96-105 | Sound for its claim: with `failGitReadSettlement` the double throws from `settleGitRemoteRead`, the transport's `try?` at GitTransport.swift:581 swallows it, `invalidLimits` stays primary (152), one execution (163), permit still outstanding (166). The double's override replaces the protocol default (RolloutEffectAuthority.swift:561-567) only when the flag is set. I checked the obvious weakness, that this test alone cannot tell "settlement attempted and failed" from "settlement never attempted": mutant G1 (delete GitTransport.swift:581-587) leaves this test green but is KILLED by the neighbouring `readAdmissionClosesBeforeTransport` (128: `waitForDrain` false), so the suite covers it. Not a finding. |
| `v10RemovedObjects` | SQLiteStoreTests.swift:318-326, 333, 794-797 | Sound. Names match the migration (`DROP TRIGGER` at DatabaseSchema.swift:1713-1714; replacements at 3581 and 3621; schema-9 definitions at 5682, 5692). Upgraded DB is disjoint from the removed set and contains both replacements; the v9 backup is a superset of the removed set, so the assertion is not vacuous against an empty set. |
| Herdr comment | HerdrPiWorkflowRuntimeTests.swift:1610-1613 | Accurate. `executeCanaryGenerationRolloverQ4` reaches `verifyProviderLaunchAuthority` through the launch path whose `providerPermit` defaults to nil (HerdrPiWorkflowExecutor.swift:5198, 5209-5213), and the nil-permit branch throws `effectIdentityMismatch` (4924-4926). The double's new `denyHistoricalContext` in `verifyProviderPermit` is never reached on that path. |
| Runbook paragraph | docs/operations/progressive-production-rollout.md:32-37 | Consistent with the migration and the `v10RemovedObjects` test. |

## 3. Findings (new, all Minor)

### MINOR
- **Sources/JidokaCodeCore/State/DatabaseSchema.swift:2804** (test gap in `RolloutAuthorityStoreTests.swift:1296-1368`) The join conjunct `AS source ON source.authorization_id = previous.authorization_id` is the only clause that stops a ledger row from citing another lane's reservation, and no test exercises it. → Add a cross-lane case to `usageLedgerRefusesSingleFaultForgeries` (or a sibling): activate lane A, reserve one effect, close A (pause + `transitionLane` to a terminal state), activate lane B with a second `authorizationID`, lift `rollout_effect_reservations_usage_append`, and insert on B's ledger the exact next row citing A's reservation id (arithmetic exact against B's sequence-0 row) expecting `SQLiteStoreError` and an unchanged count. The FK on `rollout_effect_reservations.authorization_id` rules out a synthetic foreign reservation, so a real second lane is needed. | evidence: mutant `M12_cross_lane_source` (sed `2804s/ON source.authorization_id = previous.authorization_id/ON 1 = 1/`) builds and SURVIVES the full `RolloutAuthorityStoreTests` filter (49/49 green), log at `SCRATCH/round7/rr-m2/M12_cross_lane_source.test.log`. Severity Minor, not Major: the clause is present in source, the mutant's effect is fail-closed (it can only inflate a lane's consumed usage, never reset a cap), and the fixture is single-lane by design.

No Critical, no Major.

## 4. Probes run (exact commands)

```
mkdir -p <worktree>/export && git archive 157d57c | tar -x -C <worktree>/export
/bin/zsh SCRATCH/round7/rr-m2/sweep.sh        # baseline + 11 mutants, summary.txt
/bin/zsh SCRATCH/round7/rr-m2/extra.sh        # M12 + G1, extra-summary.txt
sqlite3 SCRATCH/round7/rr-m2/m8-probe.sqlite3 < SCRATCH/round7/rr-m2/m8-probe.sql
```

Both scripts print the restored-file sha256 match (`match=yes` for DatabaseSchema.swift `bdfe12bb...` and GitTransport.swift `9becb417...`) and a green restore build. The export was removed after the review.

## 5. Could not verify

- The writer's full gates (`make check`, 776 tests / 88 suites): not re-run here (brief limits me to one build at a time and the sweep already needed 15 builds); I ran only the two filtered suites the delta touches. The delta is test-only, so the risk is confined to the new tests themselves, which I ran under baseline and every mutant.
- Store parity for `bindApprovedCommandReservation` and `verifyGitSendPermit` under a historical context is verified by source reading (store 677-687, Transactions 1040-1053), not by a store-side test; only the provider pair has one (`workflowProviderPermitIsInertUnderHistoricalContext`). I do not raise this as a finding: `historicalCanaryCannotVerifyOrSettle` already runs both store and double for the `.historicalCanary` permit, and the parity comment in the new double test is accurate.

## Summary

Coverage assessment: the round-7 Major is closed with the strongest evidence available for a SQL gate (10/11 mutants killed by a single-fault test, the survivor proven equivalent). The Minor closures are each sound, non-vacuous, and parity-checked against the store.
Recommendation: ACCEPTABLE (one new Minor, a coverage gap for the cross-lane source clause; fix-optional for merge).
