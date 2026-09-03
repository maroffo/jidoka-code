# Exact Single-Job Canary While Globally Paused

**Status:** in progress, exact topology recovery authorized 2026-08-18
**Origin:** in-session authorization from Max on 2026-08-17
**Base:** `feat/settings-guided-configuration` at `7ba8eae88f029df360af01ffa7b5af669d1cfa01`, with the existing guided-settings, resource-repair, and maintenance worktree changes preserved
**Goal:** Preview and execute at most one exact repaired PR-review job while durable global pause remains enabled, without scheduler discovery or access to the other 155 queued jobs, and with durable fail-closed authority at Pi-launch and GitHub-publication boundaries.

## Analysis (verified 2026-08-17, do not re-derive without new evidence)

### Current behavior
- Unpausing schedules a resume pass automatically (`Sources/JidokaCodeCore/Scheduler/DurableScheduler.swift:61-69`).
- One coordinator pass snapshots and walks every queued job in global priority/creation/UUID order; after a job settles, the loop can admit the next (`Sources/JidokaCodeCore/Jobs/JobCoordinator.swift:411-450`, `543-546`).
- `maxConcurrency` is checked as an active-lease ceiling, not a cumulative pass budget (`Sources/JidokaCodeCore/State/DurableJobStore.swift:1312-1368`).
- Repository and workflow toggles govern discovery and initial workflow validation, but queued dispatch does not select by an enabled repository (`Sources/JidokaCodeCore/Jobs/JobCoordinator.swift:176-185`, `411-450`).
- Pausing closes future dispatch and drains admitted work, but an external observer cannot atomically couple lease observation to gate closure (`Sources/JidokaCodeCore/Application/EngineService.swift:369-384`, `Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:219-238`).
- The repaired production state contains 156 queued post-boundary jobs. The first four in dispatch order are the repaired PR reviews; the fifth and sixth are unrelated PR reviews. Production remains `paused=1` with zero Pi runs and launches.
- A PR review executes architecture, security, and test roles followed by synthesis (`Sources/JidokaCodeCore/Pi/PiWorkflowRouters.swift:277-365`) and then may publish multipart marker comments (`Sources/JidokaCodeCore/Jobs/PullRequestReviewJobWorkflow.swift:432-500`, `Sources/JidokaCodeCore/Jobs/GitHubMarkerPublisher.swift:105-205`).
- Pi launch admission is currently a global Boolean (`Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:82-212`). GitHub send authority becomes irreversible at `markSendStarted` (`Sources/JidokaCodeCore/Reconciliation/GitHubMutationExecutor.swift:43-83`).
- Durable pause is enforced by existing store-side dispatch eligibility, so a dedicated canary admission cannot reuse the generic queued lease path without a narrowly scoped alternative (`Sources/JidokaCodeCore/State/DurableJobStore.swift:1288-1368`).
- Existing append-only `job_transitions`, durable `pi_runs`/`pi_run_launches`, and `mutation_intents` can carry canary authority and effect accounting without a schema migration (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:42-193`). Avoiding a migration preserves compatibility with the installed rollback package.

### Root cause or design gap
The production protocol has only a global pause toggle and unrestricted scheduler passes. No existing authority binds one exact queued job to a one-shot admission, and no durable scope constrains Pi launches or GitHub sends to that job. Therefore Resume, configuration toggles, `pollNow`, or an external pause watcher cannot prove an at-most-one-job canary under fast failure, success, cancellation, or crash.

### Scope
- In: exact repaired PR-review job selection; preview/evidence authorization; paused-store lease admission; direct one-job coordinator execution; exact Pi job scope; pre-send multipart cap; crash/replay status; protocol-v5 and CLI support; production and failure-path tests.
- Out: generic canaries for triage/implementation; multi-job cohorts; Resume; scheduler changes that introduce a batch limit; provider calls; GitHub writes; production database mutation; packaging, signing, notarization, installation, helper restart; UI controls; commit, push, PR, promotion, or release.
- Recover excluded context from: `quality_reports/plans/active/2026-08-17_single-job-canary.md`, the current worktree diff, and the installed repair evidence in this session.

### Candidate approaches
| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Resume with `maxConcurrency=1` | rejected | Limits simultaneous leases only; the same pass continues serially. |
| Disable repositories or workflow flags | rejected | Does not remove queued jobs from dispatch and can block unrelated durable work. |
| Resume plus an external SQLite watcher that pauses after one lease | rejected | Observation, pause persistence, dispatch-gate checks, and next lease acquisition are not atomic. |
| Add a scheduler pass budget | rejected | Broadens normal scheduler semantics and still needs durable external-effect scoping and crash authority. |
| Exact direct canary while global pause stays true | chosen | Keeps scheduler and discovery closed; atomically admits one evidence-bound job and scopes every new external effect to it. |
| Add a schema-v5 canary table | rejected | Breaks compatibility with the preserved rollback package unless a second compatible rollback is built. Existing append-only transition/effect records are sufficient. |

### Independent opinion
- `architecture-reviewer`, read-only, concluded no existing command is fail-closed and recommended a durable exact job permit consumed atomically with lease admission. Canary-readiness score: 28/100 before this change.
- `security-reviewer`, read-only partial report before its turn-budget abort, independently rejected Resume/watchers/toggles and required exact provider/GitHub effect bounds plus crash-safe non-replenishing replay. Canary-readiness score: 25/100 before this change.
- External Expert Panel was not run because no new cross-provider disclosure consent was requested. Reduced-confidence area: ergonomic shape of a future generalized canary API. This plan remains single-job and incident-specific.

## Locked decisions

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Scope mode | Hold Scope, one PR-review job only | Max approved the recommended single-job implementation; other job kinds have different command and mutation surfaces. | A later request explicitly adds another kind. |
| 2 | Global scheduler state | `app_settings.paused` remains `1` for preview, admission, execution, replay, and response | Resume is the unbounded behavior being avoided. | A proven durable scheduler batch primitive replaces this path. |
| 3 | Selection | Caller supplies one exact job UUID, fixed incident boundary, and exact repair evidence SHA | Human authorization must bind the target; no implicit “next job” substitution is allowed. | A future signed cohort format is approved. |
| 4 | Candidate predicate | Queued post-boundary PR review, exact `humanRetryAuthorized` repair disposition/evidence, exact maintenance transition, no prior steps/runs/commands/mutations/active lease, enabled review repository | Reuses the failure-detecting repair guards and prevents canarying unrelated or partially executed work. | Recovery of an already admitted canary is designed separately. |
| 5 | Evidence | Canonical sorted JSON binds job/disposition/repair transition, repository configuration, review model profile, resource-tree digest, attempt/step, and closed external-effect policy | Count-only or UUID-only approval becomes stale if configuration or code authority changes. | Additional decision-relevant fields are introduced. |
| 6 | Durable authority | Reuse append-only `job_transitions` event keys for admit, role authorization, marker-batch authorization, and close; reuse `pi_runs`, launches, and mutation intents for exact effect evidence | Preserves rollback schema compatibility while making crash windows inspectable and idempotent. | Event-key bounds or rollback behavior falsify this encoding. |
| 7 | Admission | Add a store-private canary transition that atomically revalidates evidence, requires durable pause, proves no other active canary, and acquires only the exact repository/job lease | Generic dispatch eligibility must not gain a pause bypass. | None without a new security review. |
| 8 | Execution | Invoke a dedicated exact-job coordinator method; never invoke scheduler discovery, `run(pass:)`, `pollNow`, or `setPaused(false)` | Prevents the remaining queue from entering the execution path. | A generalized bounded coordinator API is separately approved. |
| 9 | Pi scope | Permit only the exact job and the fixed PR-review role sequence `architecture`, `security`, `test`, `synthesis`; no fifth logical run and no substitution | One PR review has exactly four role executions. | PR workflow contract changes. |
| 10 | GitHub scope | Before any send, atomically authorize one exact marker document batch for the canary job; authorization supplies a bounded maximum part count, and the whole part count must fit before part one | Prevents partial publication caused only by exceeding an operator-approved cap. Existing prepared-before-send and read-back authority remains unchanged. | GitHub publication ceases to be multipart marker comments. |
| 11 | Crash behavior | Admit and effect records never replenish. A crash with admit but no close reports recovery-required and launches nothing automatically; no replacement job is selected | At-most-one admission is preserved under arbitrary crash windows. | A separately authorized recovery protocol is added. |
| 12 | Rollback | No database migration or new persisted state enum; rollback may read the existing schema and remains safe only while global pause remains set | The preserved rollback package cannot understand a new schema version. | A migration-compatible rollback package is separately built and verified. |
| 13 | Delivery boundary | Source and tests only in this loop; no package/install/provider/GitHub/Resume/commit/push | Those mutations remain separately authorized. | Max explicitly authorizes one named boundary. |

## Acceptance criteria
- [x] A preview for one exact repaired job returns one canonical evidence SHA and a closed disclosure of repository target, model profile, four Pi roles, resource digest, and caller-selected maximum comment parts; it performs no mutation.
- [x] Preview rejects wrong boundary, wrong repair SHA, lexical near-matches, wrong job kind/state/disposition, prior steps/runs/launches/commands/mutations, active leases, disabled review configuration, unsafe resource digest, or any active canary.
- [x] Execute requires `paused=1`, exact current preview evidence, and no active work; in one SQLite transaction it records exact canary admission and acquires only that job/repository lease.
- [x] The production scheduler remains paused and receives no Resume, manual, or lifecycle pass from the canary command.
- [x] The direct coordinator path executes only the admitted job. A fast success or failure cannot lease the next queued job.
- [x] Pi launch admission rejects every other job, wrong workflow, wrong role order, duplicate replacement role, and a fifth logical run before any process effect.
- [x] Marker publication authorizes the exact document digest and complete part count before part one; a count over the approved cap or any other GitHub mutation fails before `markSendStarted`.
- [x] Success, permanent failure, retry/backoff, or human/ambiguous settlement closes the canary without selecting a replacement. Unresolved crash state remains active and reports recovery-required.
- [x] Exact replay of a closed authorization returns prior authority without another lease, Pi launch, or GitHub send. Replay of an unresolved authorization launches nothing.
- [x] Protocol responses remain paused and exactly bind scope/evidence/policy/checkpoint; unrelated commands carry no canary report.
- [x] The installed repair state is never touched during implementation or tests; production remains paused with zero Pi runs/launches.
- [x] No schema migration is added, and all existing migrations plus rollback-open compatibility tests pass.

## Workstreams

### W0: Reproduce the unsafe alternatives
- Scope: `Tests/JidokaCodeCoreTests/JobCoordinatorTests.swift` or nearest existing coordinator test file; canary-specific new tests.
- Excluded: production database and provider paths.
- [ ] Preserve a test proving one unrestricted pass can dispatch a second queued job after the first releases a concurrency-one lease.
- [ ] Preserve a test proving repository toggles are not a safe selector for already queued jobs.
- [ ] Add failing tests showing no exact paused admission/effect authority exists before implementation.

### W1: Canary models and canonical evidence
- Scope: new `Sources/JidokaCodeCore/State/JobCanary.swift`; `DurableJobStore.swift`; state-machine event cases only where required.
- Excluded: `DatabaseSchema.swift` migration list.
- [ ] Define strict scope, authorization, policy, status, and report types with fixed boundary and SHA/UUID/count validation.
- [ ] Canonically hash every decision-relevant job, disposition, repair transition, repository, model-profile, resource, and policy field.
- [ ] Implement exact preview, atomic admission, active/closed/recovery inspection, role effect recording, marker-batch recording, and safe closure using existing append-only tables.
- [ ] Prove idempotence, event-key bounds, no schema change, and all guard failures.

### W2: Exact execution and effect gates
- Scope: `JobCoordinator.swift`, `ProductionEngineJobRuntime.swift`, `HerdrPiWorkflowExecutor.swift`, `GitHubMarkerPublisher.swift` and the narrow supporting protocols.
- Excluded: normal scheduler ordering and generic workflow behavior.
- [ ] Add `runCanary` for one already admitted PR-review job, with existing failure classification but no queue loop or discovery.
- [ ] Add exact job/role canary launch scope to the Herdr runtime while leaving normal launch admission unchanged.
- [ ] Add whole-marker-batch authorization before first send and prove other GitHub operations cannot use canary authority.
- [ ] Close and drain scoped admission on every return/error/cancellation path.
- [ ] On startup, suppress automatic coordinator execution when an unresolved canary admission exists; durable result import/read-only evidence remains allowed.

### W3: Engine protocol and CLI
- Scope: `EngineProtocol.swift`, `EngineService.swift`, `JidokaCodeEngineMain.swift`, new `Sources/JidokaCodeApp/JobCanaryCLI.swift`, `JidokaCodeApp.swift`, app/client tests.
- Excluded: SwiftUI controls.
- [ ] Bump the engine protocol version and add preview/execute canary commands to the closed production helper allowlist.
- [ ] Validate paused state, exact scope/evidence/policy, checkpoint requirements, report absence on unrelated commands, and recovery-required replay.
- [ ] Add a bounded CLI whose preview is read-only and whose execute timeout covers four role deadlines without becoming an unbounded shell mechanism.
- [ ] Keep all errors closed and credential-free.

### W4: Integration and rollback-safe tests
- Scope: core/app tests, production composition tests, package inventory only if a built bundle adds a node.
- Excluded: live provider, GitHub, installation, or real production DB.
- [ ] Fake one exact four-role PR review and marker publication; assert exactly one job, four logical roles, bounded comment parts, and zero admission for the next job.
- [ ] Inject failures at preview, admission transaction, each role boundary, before marker-batch authorization, before/after send-start, closure, response loss, cancellation, and helper restart.
- [ ] Prove a crash never consumes a replacement, exact replay never replenishes, and unresolved replay performs no launch/send.
- [ ] Reopen the database with the existing migration set and demonstrate no schema version change.

### W5: Final verification and review
- Scope: complete changed tree.
- [ ] Run focused failure-detecting tests after each fix.
- [ ] Run strict recursive swift-format, `git diff --check`, release app/helper builds, and fresh `make check` after the final source edit.
- [ ] Prepare redacted parent-owned review artifacts and route architecture, security, test, database, and performance reviews.
- [ ] Resolve every verified Critical/Major finding within the fix-round budget and rerun affected checks.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Canary scope/evidence | exact candidate, each changed field, lexical SHA near-match | only byte-exact current evidence previews/executes | behavior+edge+error |
| 2 | Store admission | paused/unpaused, active lease, other canary, transaction fault | exactly one atomic lease/event or zero writes | behavior+edge+error |
| 3 | Coordinator | first job succeeds/fails instantly, second queued | second job remains byte-for-byte queued | behavior+edge+error |
| 4 | Pi gate | four roles, wrong order/job/workflow, duplicate/fifth | only fixed four logical roles may prepare/launch | behavior+edge+error |
| 5 | Marker gate | part count below/equal/above cap, changed digest, replay | batch authorized before part one; no over-cap send-start | behavior+edge+error |
| 6 | Crash/replay | before/after admit, each effect record, close, response | no replacement; closed replay inert; unresolved replay launch-free | behavior+edge+error |
| 7 | Protocol/XPC | malformed command/report, wrong scope/evidence/checkpoint | strict protocol rejection and closed errors | behavior+edge+error |
| 8 | Production composition | globally paused exact canary path | scheduler remains paused, no generic pass, one exact workflow | behavior+edge+error |
| 9 | Rollback/schema | reopen migration-v4 database after canary records | no migration-v5 and old schema remains readable | behavior+edge+error |
| 10 | Existing behavior | normal unpaused scheduler/workflows | unchanged existing tests pass | regression |

**Coverage:** 10/10 identified path families. Gaps: no live provider, GitHub, signing, notarization, installation, or production database exercise in this source loop.

**Exhaustiveness rationale:** The matrix covers the Cartesian boundaries that alter authority: candidate evidence, admission transaction, job selection, Pi effect, GitHub effect, crash/replay, protocol, composition, rollback, and normal regression. Parameterized fault boundaries avoid duplicating equivalent cases.

## Review plan
- Routed agents: `pi-forge.architecture-reviewer`, `pi-forge.security-reviewer`, `pi-forge.test-reviewer`, `pi-forge.database-reviewer`, `pi-forge.performance-reviewer`.
- Review artifact: redacted goal/criteria, changed-file roster, relevant complete diff excerpts, test evidence, protocol/event-key/state invariants, and declared live-side-effect exclusions.
- Critical/Major evidence gate: the parent verifies each finding against source and a focused executable test before accepting or rejecting it.

## Budget
- Fix rounds: 3.
- Delegated launches: 1 implementation writer, then 5 independent final reviewers; one targeted reviewer resume is allowed only to close a verified finding within the same round.
- Writer concurrency: 1.
- Final evidence: focused canary suites; strict recursive swift-format; `git diff --check`; release `JidokaCodeApp` and `JidokaCodeEngineProbe` builds; fresh `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check`.

## Risks and rollback
- Risk: event-key authority is incomplete or ambiguous. Mitigation: closed grammar, exact cardinality, canonical evidence, append-only records, collision tests, and no fallback parsing.
- Risk: opening global Herdr launch admission permits another job. Mitigation: exact job scope at `execute`, scheduler remains paused, direct coordinator path, and drain in `defer`.
- Risk: multipart cap fails after partial publication. Mitigation: authorize the full document digest and total part count before sending part one.
- Risk: crash recovery executes automatically while paused. Mitigation: detect unresolved canary admission before coordinator recovery and return recovery-required without launch.
- Risk: old rollback binary ignores canary event semantics. Mitigation: no schema/state-enum migration and durable pause is mandatory; never Resume the rollback binary while an unresolved canary admission exists.
- Rollback: before installation, discard only this canary change if separately authorized. After a future installation, restore the preserved package only through the existing user-mediated rollback checkpoint while paused; rollback is not authorized by this plan.

## External side effects
- Source edits and local test/build artifacts only.
- No production database mutation, provider call, GitHub read/write, Resume, package, notarization, installation, helper restart, commit, push, PR, or release.
- Authorization status: source implementation authorized by Max on 2026-08-17; every named external mutation remains unauthorized.

## Progress
- [x] Analysis and draft plan
- [x] User approval for exact single-job implementation
- [x] Reproduce unsafe alternatives
- [x] Implementation
- [x] Final verification and review

## Surprises and discoveries
- The first four dispatch-ranked jobs are exactly the repaired PR-review cohort, but this does not create a safe four-job boundary because the fifth job is unrelated and the same pass continues.
- `maxConcurrency=1` is not a canary count.
- Avoiding a schema migration is necessary to preserve the already notarized rollback package’s database compatibility.
- The Pi role permit must bind round `1` as well as role; role-only idempotence would otherwise permit a second logical run in another round.
- Engine-service tests require the durable GitHub account identity in `app_settings`; an in-memory credential status alone is intentionally insufficient canary evidence.
- A parallel `make check` run exposed host-contention failures in pre-existing 5-second socket and one-shot askpass tests. Those suites passed in isolation, and the complete 518-test suite passed with `--no-parallel`; the failed parallel run is not completion evidence.
- The historical eager Herdr topology test became CPU-bound under host contention and took 730.669 seconds, but completed inside the project’s bounded process group.

## Execution decisions
| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Independent review before implementation | Reuse the completed read-only architecture review and the security reviewer’s substantial partial report | Both independently falsified every existing operational shortcut; no private payload was sent to an external panel. |
| 2 | Authorization digest | Use a closed newline-framed `jidoka-job-canary-authorization-v1` domain over exact scope and preview SHA | Cannot fail encoding and prevents cross-protocol digest reuse. |
| 3 | Marker limit | Caller chooses `1...64` parts in the preview scope; the full digest/count batch is durably authorized before part one | Keeps the external write ceiling explicit without partial sends caused by the ceiling itself. |
| 4 | Persistence | Encode admit, Pi-role/round, marker-batch, and close records in append-only `job_transitions` | Keeps the migration count at four and rollback schema-readable. |
| 5 | Normal marker hot path | Insert an in-memory exact-job marker gate and reach SQLite canary authority only while a canary is active | Prevents historical canary records from adding database work to ordinary publication. |
| 6 | Active lookup | Inspect only the latest serialized admission and its exact close record | Admissions are serialized and cannot overlap; this removes historical N+1 lookup while preserving fail-closed parsing. |

## Recovery addendum, 2026-08-18

The live UAT exposed two pre-provider failures while `paused=1`. The first was a store-side pause guard that rejected exact canary topology intents; the focused fix is installed and verified. The second is now the active recovery boundary: Herdr 0.8 applied the exact four-role layout and started four idle role hosts, but `layout.export` redacts `env`, while the coordinator required exported environment equality. The `applyLayout` intent is therefore durably `unknown`, the job is `reconciliationQueued`, and the canary reports `recoveryRequired`. Durable evidence proves Pi runs/launches `0/0`, no selected-job mutation intent, no active lease, no role-host command, and no provider or GitHub effect.

Max authorized source implementation of an explicit fail-closed recovery on 2026-08-18. The recovery keeps the unknown intent immutable, introduces a read-only canonical recovery preview and separately authorized execute path, binds exact live layout/process/descriptor/no-effect evidence, and resumes only the same active canary. Generic unresolved execute replay remains launch-free. A newly built role host will have a different digest, so this incident recovery may admit the prior host digest `699e8ee0c5cf4936cc358dc33f12f8b29f681d4f060cb3d2f74f447942dedb49` only through a closed compatibility allowlist plus exact private snapshot, start-record, PID/start/executable/argv, pane, terminal, and descriptor evidence.

Recovery acceptance criteria:
- [x] Protocol-v6 recovery preview is read-only and binds the existing active canary, exact repository/revision/model configuration, exact unknown intent, redacted live layout, four host identities, no-effect counts, and resource tree. The separately audited package/install checkpoint binds helper authority because `/Applications` is intentionally rejected by `safeAncestorChain`.
- [x] Recovery execute recomputes the exact evidence, appends one authorization record, never changes or deletes the unknown intent, and never creates topology.
- [x] Only the exact prepared topology can become active; empty exported environment is treated as redacted only when exact host runtime evidence closes the authority gap. Non-empty environment must still match.
- [x] Only the exact no-Pi `reconciliationQueued` job can transition back to `preparing` with one recovery lease and the same attempt; any Pi run, launch, command, step, mutation, lease, process mismatch, or changed evidence fails closed.
- [x] Startup and ordinary unresolved replay preserve the topology but launch nothing. Recovery crash points before a Pi run are idempotent only through the explicit recovery command; any Pi run permanently disables no-Pi recovery.
- [ ] Fresh focused tests, strict formatting, release app/helper builds, full serialized tests, and independent architecture/security/test/database review contain no unresolved Critical or Major defect before packaging.
- [ ] Package, installation, helper restart, recovery execution, provider/GitHub effects, commit, push, and promotion remain separate checkpoints.

Recovery budget: three fix rounds, one parent writer, focused test-first implementation, then five independent artifact-only reviewers. The attempted pre-implementation protected architecture/security review could not launch because the local subagent harness still resolves the removed `/opt/homebrew/Cellar/node/26.6.0/bin/node`; this is a review gap, not favorable evidence.

## Outcomes and retrospective
- Implemented protocol-v5 preview/execute CLI, paused atomic admission, direct one-job coordinator execution, exact Pi role/round gating, exact-job marker gating, whole-marker-batch authorization, settled/recovery-required replay, and startup recovery suppression for unresolved canaries.
- Kept schema migrations at four. Canary authority is append-only and remains readable by the preserved rollback binary while durable pause stays enabled.
- Added failure-detecting store, protocol, service, coordinator, marker, Herdr cross-job, CLI, rollback, stale-evidence, and unsafe-alternative tests.
- Final evidence after the last source edit: 82 focused tests across seven suites; one direct Herdr cross-job test; release `JidokaCodeApp` and `JidokaCodeEngineProbe` builds; strict recursive swift-format; `git diff --check`; complete serialized test run of 518 tests across 77 suites in 2053.294 seconds.
- The parallel `make check` test phase is explicitly not claimed: host contention caused six failures in pre-existing deadline/socket tests. Isolated reruns passed Herdr 14/14 and askpass 7/7, then the complete serialized run passed.
- Architecture and security closure reported no Critical/Major findings. Test, database, and performance reviewers’ three Major root causes were fixed and independently closed.
- No production database mutation, provider/GitHub call, Resume, package, notarization, installation, helper restart, commit, push, PR, promotion, or release occurred.
- Residual risk: a complete fake production PR-review canary spanning all four Herdr roles through multipart publication is represented by component and existing workflow tests rather than one new monolithic composition test. The next delivery boundary is packaging protocol-v5 app/helper together, not live execution.

## Supersession record, 2026-09-03

- This plan is immutable historical evidence, not current execution authority. Its exact paused PR-review objective was ultimately satisfied by the ninth-candidate sandbox job `7584cb7e-ba4b-4083-940f-1c48c7998360`: four accepted/settled roles, one attributed marker, and zero unrelated effects are preserved in `/Users/maroffo/JidokaCode-live-canary-evidence/20260902-pr1-ninth-terminal-theme`, inventory SHA-256 `21ed3ff062481dfc16d8b7b4e6137c18e6ea3f488cbb640a375bcf4e06595644`.
- The delivered source, including the later recovery, host-replacement, privacy, runtime, theme, and narrative-binding fixes, merged through PR `#16` at `b6cb62ba7d53d5de740d6e2983656f911db7bd1c` on 2026-09-03.
- Do not reuse this fixed-epoch `JobCanaryScope`, its incident predicates, or its historical authorization events for triage, implementation, or future rollout. Do not recover or rewrite its blocked predecessor jobs or late results.
- Current operational planning is `quality_reports/plans/active/2026-09-03_progressive-production-automation.md`. It requires a separate schema-10 rollout authority and fresh approval for every source, release, installation, provider, GitHub, and promotion boundary. Unchecked historical addendum items above grant no remaining action.
