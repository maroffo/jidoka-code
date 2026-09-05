# Round 6: authority and operator review fixes

Status: implementation committed and all required fresh gates passed. Independent source-completion review remains required. No merge or W7 authorization.

## Scope and authority

Max requested continuation from [comment 5551401363](https://github.com/maroffo/jidoka-code/pull/18#issuecomment-5551401363), which adds executable M1/M3 evidence from [review 5551140217](https://github.com/maroffo/jidoka-code/pull/18#issuecomment-5551140217).
The starting commit is `42064568a83d8f5cb9ab04062bdf649370401c07`; its supplied tests are preserved as ordinary regressions, with the `withKnownIssue` wrappers removed alongside the fixes. Max's unlimited source fix-round authorization is recorded in plan E14; round-6 decisions are E16-E19.

One source writer, only `/private/tmp/jidoka-code-progressive-production-automation` on `feat/progressive-production-automation`. The primary worktree remains `main@282e849`.
No operational SQLite database was opened or edited. No historical log, tracked diff, job/canary record or evidence artifact was removed or rewritten.

Implementation commit: `d123a41023acc7002a05a4002510f17a2551e17b`, tree `a96f78bf644cfeb8d84b6f61f9d5fc5d0fd7c3c3`. The subsequent evidence commit changes reports only.

Changed source areas: `RolloutAuthorityStore.swift`, `DatabaseSchema.swift`, `RolloutEffectAuthorityStore.swift`, `DurableJobStore.swift`, `HerdrPiWorkflowExecutor.swift`, `ProductionEngineJobRuntime.swift`, `GitTransport.swift`, `RolloutCLI.swift`; matching core/app/settings tests, test-only fixture target, acceptance roster, process fixture, runbook and active plan. No Keychain, pagination, reconciliation or atomic mark-send-started implementation is weakened.

## Major findings

| Finding | Implemented disposition | Executable evidence and limits |
|---|---|---|
| M1, readback during drain | `transitionLane` writes durable pause atomically with draining and retains the authorization ID. The SQL lane-close guard also requires pause for draining. Existing GitHub/Git readback admission predicates are retained. | The supplied `readbackDuringDrain` reproduces SQLite code 19 before the fix. It now reserves, verifies and settles an exact GitHub readback during drain; `gitReadbackDuringDrain` does the same for a started Git publication. Both deny fresh effects. |
| M2, usage INSERT can reset the cap oracle | A `BEFORE INSERT` trigger requires the zero activation seed or the next contiguous sequence with exact source kind/ID/authorization/time and all twelve totals equal to previous totals plus source cost. Honest source kinds are effect, scopeRead, githubReadback and gitReadback. | `usageInsertCannotForgeBudget` accepts two forged rows on the baseline and leaves the wrong ledger count. With the fix it rejects all three reset/gap/invented-source attempts, retains five usage rows and zero remaining provider budget, and denies the fifth session. The baseline test does not itself show a successful fifth session: its second forged row restores the exhausted counter; that separate bypass was demonstrated by the reviewer. Full store tests exercise all four honest append paths. This is defense in depth, not a currently exploited production writer. |
| M3, double grants historical canary authority | Align the double's historical reserve/verify/send/settle paths with production denial. Delete the executor's historical provider-permit fallback; deny historical fresh execution before preparing, retrying or republishing a durable slot. Settled result replay remains above that boundary. | Store/double parity is parameterized across reserve, send, verify and settle. Historical topology, generation rollover, reopen and job isolation now assert denial/preservation. Counterfactual fresh-canary test paths are retired explicitly below, not represented as preserved coverage. |
| M4, operator surface untested | Add all-action CLI parsing/bounds/timeout tests, settings preview eligibility (including busy state), and actual runtime preview/activate/status/stop/recovery tests with the real store, command gate and dispatch gate. Canonical inputs are shared in a test-only target. | Five runtime tests cover paused/exclusive/checkpoint gates, scheduler pause, stale/release/configuration evidence, command-drain timeout and recovery. They exposed and fixed a duplicate terminal transition in status and a recovery preview outliving exact authorization. Internal test seams do not replace the public production constructor's authority. |

These are implementation dispositions, not independent closure of M1-M4. A fresh review of the resulting source commit must still report zero supported Critical and Major findings. The explicit double remains a simplified unit-test permit tracker, not proof of aggregate budgets or complete ordinary workflow identity validation; those invariants are tested against the real store.

## All 24 Minor dispositions

| # | Disposition |
|---|---|
| 1 | Fixed: CLI recovery and stop both use the existing 700-second timeout. All command kinds are checked against the timeout matrix. |
| 2 | Fixed failure-path error masking: Git read settlement is attempted without replacing the original verification/transport error. An unsettled reservation remains consumed. Successful Git reads still require settlement; this conservative success-path behavior is not changed or claimed identical to every GitHub path. |
| 3 | Fixed: activation parses the canonical preview once. |
| 4 | Fixed: invalid phase checkpoints report their actual job state and optional step through `invalidPhaseCheckpoint`, not a hardcoded `writePlan`. |
| 5 | Retained as naming debt: canonical/scope validation still uses the existing error enum vocabulary. No acceptance predicate is changed for a naming-only finding. |
| 6 | Fixed: reservation identity/parameter mismatches report `effectIdentityMismatch`; admission closure and already-consumed reservation state still report `effectAdmissionClosed`. Existing provider/command single-use tests pin the latter distinction. |
| 7 | Fixed: exact activation explicitly refuses an existing disposition with `previewDrift`, preserving its prior job and evidence instead of overwriting it or surfacing a PK error. `existingDispositionRefusesAnotherExactJob` creates the earlier job through the store API and checks atomic rollback. |
| 8 | The proposed broker-default removal is deferred, but the claimed dependence solely on finite-window validation is refuted by source: `reserveGitHubRead` first requires `RolloutEffectTaskContext.current == effect.context`. A nil task-local plus a broker default is refused before `reserveScopeRead`; the broker does not install that default as a task-local. This disposition is a read-only call-path trace, not an executed lost-context probe. |
| 9 | Retained maintainability debt: no broad trigger emitter refactor. M1 changes the central pause boundary, not two divergent readback predicates; both real readback paths are tested. These behavioral tests are not claimed to be full byte-equivalence coverage of all duplicated triggers. |
| 10 | Intentional fail-closed asymmetry retained: command reservation requires workflow context and therefore rejects historical context as identity mismatch. Parameterized parity tests document the exact errors; no historical command authority is added. |
| 11 | Not applied: redundant predicate for the one-open-lane partial index is a separate SQL optimization, pending Max's explicit scope decision after the safety gate refused the batch. Active-only semantics remain unchanged. |
| 12 | Fixed: started-to-superseded additionally requires absence of a durable command result. The test covers legitimate launch denial and accepted-result preservation through the store API, plus an exact migration-definition pin. It does not claim a Swift red-green reproduction of the intermediate started-plus-result-row state: that direct fixture SQL edit was refused by the safety gate and was not applied. |
| 13 | Not applied: removing the subsumed scope-read UNIQUE is grouped with the separately pending DDL optimization decision. No constraint was removed. |
| 14 | Not applied: the proposed authorization/job/kind reservation index is grouped with that same pending DDL decision. No performance improvement is claimed. |
| 15 | Fixed: the runbook no longer infers that a migration-content mismatch means a disposable database. Stop, preserve files/backups/binary identity and escalate to Max; no deletion or restore-overwrite remedy is prescribed. The guard remains permanent after release. |
| 16 | Fixed: the runbook explicitly describes quarantine of ordinary interrupted/unbound generation-zero jobs. The historical reload test now calls the actual authority-bearing JobCoordinator, not generic job recovery through a misleading fake composition. |
| 17 | Fixed: [per-file historical log index](../2026-09-03_progressive-production-automation/log-index.md) links all 89 logs, with line counts, terminal markers and byte digests. No old log changed; none is treated as current evidence. |
| 18 | Not changed: retain useful descriptive headers. The review itself confirms there is no repository-wide ABOUTME convention to enforce; this is not a behavioral defect. |
| 19 | Fixed: the process-identity fixture writes/fsyncs a private temporary record before create-only hard-link publication, then unlinks only its own temporary path. The final path cannot expose an empty/partial record and an existing destination is not replaced. |
| 20 | Fixed: historical Git-send verification requires the exact `effectIdentityMismatch` case. |
| 21 | Fixed: migration catalog count is `>= 10`; exact version-10 position, statement count and digest checks remain. |
| 22 | Fixed: each preview-revalidation loop installs cleanup with `defer` immediately after fixture creation. |
| 23 | Fixed: the double checks command identifier/digests/head/round/ordinal and exact workflow job context. `commandReservationParity` checks nil/wrong context, each malformed field against double and store, and a positive finite double permit lifecycle. |
| 24 | Fixed: the unbound continuation test expects `SQLiteStoreError`, retaining its durable no-change assertion. |

## Historical coverage correction

The pre-fix double alignment produced 164 issues in the preserved diagnostic run. This is evidence that the earlier green suite encoded counterfactual authority, not evidence of 164 live production vulnerabilities.

Nine test functions that required fresh historical provider authority are retired from `HerdrPiWorkflowRuntimeTests`:

- `roleHostReplacementRevalidatesQ4AtEffectBoundaries`
- `roleHostReplacementPreCutoverFaultMatrix`
- `roleHostReplacementCleanupFailureIsExact`
- `roleHostReplacementAmbiguityIsTerminal`
- `roleHostReplacementTerminalUnknownCloseReopenIsolation`
- `roleHostReplacementCrashRecoveryIsIdempotent`
- `roleHostReplacementCloseReopenRecovery`
- `roleHostReplacementPreparedIntentRestartContinuesOriginalReceipt`
- `roleHostReplacementSentIntentRestartIsTerminal`

Their source remains in Git at `4206456`; old logs remain untouched. `explicitUnknownTopologyRecovery` retains no-Pi topology recovery and replaces its obsolete fresh-retry chain with denial. Retained replacement/rollover cases preserve recorded Q4/history without asking the executor to manufacture it. The 51 post-preview scenarios prove denial, not reachability of downstream fault guards. The 28-entry fault catalog's shape assertion is retained and explicitly does not claim execution coverage. Production process-identity, credential, publication and atomic-send guards are not relaxed.

The first full run also found `PullRequestReviewJobWorkflowTests.topologyRecoveryReviewSelection` expecting a fresh historical publication. Its idempotent selection and evidence assertions remain, but workflow execution must now deny with no publication, new intent or changed artifact/job record. The counterfactual historical publication is not counted as live workflow coverage.

## Fresh verification

The [25-file log index](log-index.md) gives the purpose, disposition, exit status and SHA-256 for every diagnostic and final run. [Post-commit checks](logs/25-post-commit-audit.log) confirm that the verified source matches `d123a41` and that committed historical evidence is unchanged; they are not independent review.

All required final gates run sequentially after the final source/test edit. Environment:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
JIDOKA_RELEASE_RUNTIME_ROOT=/private/tmp/jidoka-code-progressive-production-automation/build/runtime-input/qualified-runtime
```

| Required command | Result | Raw evidence |
|---|---|---|
| `make check` | PASS, 770 tests / 88 suites; test execution 60.118s; completed 16:06:55 UTC | [16-make-check.log](logs/16-make-check.log) |
| `make test-e2e` | PASS, S1 package, S10 UI, S11 Herdr and S12 exact Pi TUI; completed 16:16:57 UTC | [17-test-e2e.log](logs/17-test-e2e.log) |
| `make jidoka-code-production-automation-acceptance` | PASS, 770 tests / 88 suites, all 21 required suites; test execution 56.930s; completed 16:18:31 UTC | [18-acceptance.log](logs/18-acceptance.log) |
| `xcrun swift-format lint --recursive --strict Sources Tests` | PASS, exit 0; completed 16:18:35 UTC | [19-format-lint.log](logs/19-format-lint.log) |
| `xcrun swift build --configuration release --product JidokaCodeApp` | PASS, complete (cached, 0.20s) | [20-release-app.log](logs/20-release-app.log) |
| `xcrun swift build --configuration release --product JidokaCodeEngineProbe` | PASS, complete (cached, 0.11s) | [21-release-engine.log](logs/21-release-engine.log) |
| `xcrun swift build --configuration release --product JidokaCodeHerdrHost` | PASS, complete (cached, 0.11s) | [22-release-herdr-host.log](logs/22-release-herdr-host.log) |
| `git diff --check` | PASS, exit 0; completed 16:18:37 UTC | [23-diff-check.log](logs/23-diff-check.log) |

All times are 2026-09-05. Final aggregate logs contain no known issues and no `.cleanupFailed`. Release products were rebuilt during the preceding full gates; the three separately required final commands completed against those unchanged inputs, not a timed-out or partial run. Pre-existing Keychain deprecation warnings remain; strict format is clean and no Keychain behavior was changed.

E2E includes the same 16 `write: Permission denied` lines present in the previous accepted round-5 log, then completes the package and all later fixture checks. S10 records a network-denying sandbox and zero Keychain/network/provider/service-management effects. S12 reports two local synthetic provider exchanges and measured `provider_network=0`, not two calls to a live provider. Its offscreen UI accessibility limitation remains explicitly reported, not upgraded to a live accessibility-tree claim.

Failed, partial, zero-test and pre-edit runs in the log index are diagnostic history only. The normal source commit is recorded in [24-source-commit.log](logs/24-source-commit.log). No hook was bypassed or edited; inspection found no configured `core.hooksPath` override and only sample hooks in the default directory, so this report does not invent a passing custom hook run.

Schema 10 has 91 statements. Pinned test digest:
`04a5fdb3b2e6935a13a7418419a2aed3a3f0708e317fedf44ed34eebee659991`.
This is `migrationDigest` in the schema tests, not an interchangeable claim about every digest format.

## Review and operational gates

No protected-child reviewer tools are exposed in this session (fresh tool discovery found none). No fallback model/provider route is authorized or invoked. The writer's read-only audit cannot substitute for architecture, security, database and test review of the resulting commit. Source completion is not claimed.

The preceding UI fixture is preserved at `build/round6/preserved-ui-4206456`; `diff -qr` verified identical content before the E2E harness recreates its working fixture. Committed historical evidence and prior `build/evidence` are not cleaned up. Required harnesses use isolated local fixtures; their ad-hoc fixture signatures are not Developer ID signing or production packaging.

No rollout activation, finite promotion, live provider/model call, live workflow Git/GitHub effect, Developer ID signing, notarization, installation, deploy, merge, rollback, tag, release or W7 is performed. Authorized publication is limited to this source branch and PR #18.

Most important remaining risk: fresh independent review is still required, especially for the exact-source SQL append predicate and the intentionally reduced historical-canary execution surface.
