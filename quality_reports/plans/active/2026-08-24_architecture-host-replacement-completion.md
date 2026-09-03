# Schema-9 Architecture Host Replacement Completion

**Status:** approved; W0-W7 complete under decision 21; local Git delivery authorized; W8 installed authority blocked
**Origin:** in-session completion and restart request from Max on 2026-08-24
**Base:** `feat/settings-guided-configuration` at `7ba8eae88f029df360af01ffa7b5af669d1cfa01`, preserving the existing dirty checkout with 109 modified or untracked paths
**Goal:** Close every verified Critical and Major finding, obtain fresh complete verification and direct-source review, then prepare separately gated packaging and exact q4-only production execution while production remains paused and 155 unrelated queued jobs remain untouched.

## Analysis (verified 2026-08-24, do not re-derive without new evidence)

### Current behavior

- Production remains outside this source-only phase: schema 8, `paused=1`, exact canary job `f2ae31fe-123d-450d-aff5-1e958ddf251e`, run `run-e5bfc6ac-8312-4da1-8dc6-aad5c29363a4`, q1 through q3 only, q4/q5 absent, and no authorized live mutation since the terminal reset incident.
- The source checkout contains the uncommitted schema-9 first-class replacement implementation. Migration 9 still has 49 statements (`Tests/JidokaCodeCoreTests/SQLiteStoreTests.swift:200,850`).
- Post-review writer `ed5085cc` reports two Critical fixes in `Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift`, `Sources/JidokaCodeCore/State/DurableJobStore.swift`, `Sources/JidokaCodeCore/State/JobCanary.swift`, and `Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift`. The report is durable at `.pi-subagents/artifacts/ed5085cc_pi-forge.software-engineer_0_output.md`.
- Current source now guards the startup scheduler pass with `startupExecutionAllowed` (`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:250-263`) and scopes `recoverAtStartup` to the preserved canary when present (`Sources/JidokaCodeCore/State/DurableJobStore.swift:452-479`).
- Current source reconstructs an exact pre-cutover terminal-unknown predecessor (`Sources/JidokaCodeCore/State/JobCanary.swift:1371-1395,2973-3070`) and blocks its job instead of treating the predecessor as a generic lost host (`Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:1364-1627,2589`). These changes have not yet received a fresh independent direct-source acceptance review.
- Fresh post-`ed5085cc` unit evidence reported as passing: 11 replacement store tests, exact canary startup isolation, paused reload branch, `DurableJobStoreTests.startupRecovery`, four production composition tests, `swift test list` with 568 entries, strict format, debug build, and `git diff --check`.
- Three required slow replacement E2Es remain blocked during fixture setup with `PiRuntimeIssueCode.unattestedNodeBuild` or `invalidDescriptor`. The observed external Homebrew closure now points at `merve 1.2.2_2`, `simdjson 4.6.8`, and `simdutf 9.1.0`, while source policy attests earlier exact builds. This is fail-closed environmental evidence, not permission to alter runtime authority.
- No subagent is currently active. The attempted 2026-08-24 database writer returned no run result and made no evidenced fix: SQL still scopes ordinary-host collision checks by job/generation (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:2645-2670`), q4 still uses a wildcard replacement event (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:3380`), and topology-intent transitions still lack a timestamp monotonicity predicate (`Sources/JidokaCodeCore/State/DatabaseSchema.swift:1770-1805`; `Sources/JidokaCodeCore/State/PiRunStore.swift:3685-3740`).
- Max explicitly selected `/herdr-orchestrator` for restart execution. Current readiness observation passed with `HERDR_ENV=1`, caller pane `w8:p2`, Pi `0.84.2`, Herdr `0.8.2`, and `@ogulcancelik/pi-herdr` `0.4.0`. This evidence becomes stale on restart and must be repeated before any pane creation or delegation.
- Latest independent direct-source scores before `ed5085cc` were architecture 39/100, security 52/100, database 73/100, and test 70/100. They block packaging and production use.

### Root cause or design gap

The replacement mechanism is structurally present, but its remaining authorization, recovery, attestation, and validation boundaries do not yet form one restart-stable proof. Durable outcome reporting conflates known failure and ambiguity, preview authorization does not bind the exact q4 descriptor, connected socket evidence does not bind the actual peer, credentials and preserved executable identities are incompletely bound and scrubbed, SQL permits cross-job physical aliasing and a wrong-canary event, and tests do not yet execute every production boundary. Packaging or live execution before these gaps close would convert missing evidence into irreversible authority.

### Scope

- In: acceptance of the two startup Critical fixes; durable terminal outcome model; exact q4 descriptor binding; peer, process, resource, pane, and credential attestation; startup credential scrub; global schema-9 collision and event authority; missing production-boundary and fault tests; fresh verification and direct-source review; separately gated UAT package, install, migration, preview, replacement, and q4 settlement.
- Out: changing Node `26.7.0`, Pi `0.84.2`, runtime authority, packaged policy, Homebrew dependency paths, or descriptor validation to accept drift; replaying reset/clear/rename/prime/`execute-pi-retry`; q5; Resume; scheduler discovery or broad dispatch; replacing security/test/synthesis; generic terminal input; direct-RPC fallback; unrelated refactors; commit, push, PR, promotion, rollback, install, notarization, production DB/socket/process mutation, or temporary-alias removal without its explicit later gate.
- Threat boundary: configured repositories, their approved verification commands, and release-attested child runtimes are trusted not to deliberately evade supervision. Source completion does not claim hostile child containment against an immediate `fork`/leader-exit/reparent/`setsid` sequence.
- Recover historical context from: `quality_reports/plans/active/2026-08-23_architecture-host-replacement-fallback.md`, `quality_reports/plans/active/2026-08-17_single-job-canary.md`, and `.pi-subagents/artifacts/ed5085cc_pi-forge.software-engineer_0_output.md`.

### Candidate approaches

| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Continue in one large writer round | rejected | The dirty delta is already 109 paths and the remaining findings cross independent authority boundaries. A large round makes evidence stale and review attribution weak. |
| Weaken runtime attestation or update policy to current Homebrew drift | rejected | Exact Node/Pi closure is a fail-closed production boundary. External package drift is not authorization. |
| Treat blocked slow E2Es as passing because unit tests pass | rejected | The blocked tests never reach scoped behavior and provide no acceptance evidence. |
| Package first and use UAT to discover remaining defects | rejected | Packaging would be based on source with verified Major findings and would not make the source safer. |
| Bounded source rounds, fresh focused checks after each, then one final full gate and direct-source review | chosen | Keeps one writer, localizes regressions, and preserves a falsifiable evidence chain. |
| Use the selected Herdr overlay with one retained generic Pi writer and supervised process panes | chosen | Gives Max visible control while retaining the base verification and protected-review contracts. Herdr is not a sandbox or protected-agent route. |
| Use direct Claude Code through Herdr | rejected for this execution | Max selected Herdr, not a different provider/model. Any direct Claude launch would require exact readiness evidence, limitation disclosure, and fresh per-launch consent. |
| Combine source completion with live replacement or Resume | rejected | Source, package, install, replacement, q4, and Resume are separate mutation boundaries. |

### Independent opinion

Four direct-source reviewers inspected the checkout before `ed5085cc`: architecture 39/100, security 52/100, database 73/100, and test 70/100. Their verified open findings are incorporated below. No new Expert Panel is needed for this completion plan because those independent reviews already cover the non-trivial design choices. A fresh direct-source review remains mandatory after the final edit.

## Locked decisions

Append only. Reverse a decision with a new row naming the superseded row.

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Production state during source work | Read-only, `paused=1`; no DB, socket, process, package, provider, or GitHub mutation | 155 unrelated jobs must never be dispatched | Never inside W0 through W6 |
| 2 | Existing ambiguous operations | Never replay reset, clear, rename, prime, existing retry, or any `sendStarted` replacement | Durable unknown is irreversible | Never for this incident |
| 3 | Writer ownership | One writer at a time in the existing dirty checkout | Prevent overlapping edits and loss of user work | Only with isolated worktrees explicitly approved by Max |
| 4 | Runtime drift | Preserve exact attestation and report external closure drift as blocked | Unknown builds fail closed | An independently approved runtime-authority change outside this plan |
| 5 | Startup Criticals | Accept only after direct source inspection and production-composition tests | `ed5085cc` completion is not independent verification | Fresh evidence falsifies either fix |
| 6 | Terminal outcome | Persist and query distinct no-effect, possible-ambiguity, confirmed-effect, known-q4-failure, and replacement-loss shapes | `terminalUnknown` plus a Boolean is not truthful | A smaller typed model proves the same distinctions |
| 7 | Q4 authorization | Preview constructs the exact deterministic q4 descriptor/configuration digest and binds it through authorization, intent, replacement host, attribution, and SQL launch authority | Current payload binds only the replacement bootstrap digest | Descriptor generation becomes cryptographically immutable earlier |
| 8 | Socket authority | Every request binds authorized socket identity and connected peer PID/start/executable/code identity | Path vnode plus same UID cannot identify the peer | Herdr provides a stronger native authenticated channel |
| 9 | Final live check | Prepare inert intent first, then repeat all live authority checks immediately before `markSendStarted` | Existing await gap permits stale evidence | Herdr adds an atomic compare-and-mutate operation |
| 10 | Preserved hosts | Bind and recheck mapped executable device/inode and code identity for architecture predecessor plus security/test/synthesis | Path/hash/start record alone can follow a path swap | Native process code-signing identity provides a stronger proof |
| 11 | Credentials | Bind canonical projection digest and account identity; scrub final, prepared, staging, and orphan files before child certainty; cleanup failure is explicit | Metadata-only evidence and partial scrub are insufficient | A secretless provider transport replaces file projection |
| 12 | Database physical IDs | Pane, terminal, PID/start, and host IDs are globally non-aliasing across ordinary and replacement hosts in both directions | Physical ownership is database-wide | Schema introduces one normalized host table with equivalent constraints |
| 13 | Database event | Q4 requires exact equality with the authorized canary SHA and complete tuple | Wildcards cannot establish causal equality | None |
| 14 | Database chronology | Intent timestamps cannot regress or change without a valid state transition; Swift and SQL agree | Incident order must be durable | None |
| 15 | Validation | Blocked, timed-out, stale, pre-edit, truncated, or externally prevented checks are not passing | Fresh evidence only | Never |
| 16 | Reviews | Four fresh direct-source reviewers after the last edit; parent verifies every Critical/Major in source and executable evidence | Artifact-only or completion reports are not approval | Never |
| 17 | Package and live operation | Source completion, package/notary, install/migration, replacement/q4, rollback, Resume, cleanup, and Git delivery are separate gates | Each has different irreversible effects | Max explicitly combines exact named boundaries |
| 18 | Resume | Excluded even after q4, because it may run a global scheduler pass over 155 jobs | Concurrency limits do not bound selection | A separate proof and explicit authorization exist |
| 19 | Temporary Node alias | Do not remove `/opt/homebrew/Cellar/node/26.6.0/bin/node` in source work | Cleanup is a separate filesystem mutation | Max authorizes exact safe removal and verification |
| 20 | Herdr control plane | Use `/herdr-orchestrator` after a fresh readiness gate; one generic Pi writer on the exact current parent provider/model, one process pane at a time, and protected reviewers only through normal `subagent` routes | Herdr provides visibility, not sandboxing or protected Pi Forge identity | Max separately selects non-Herdr orchestration or explicitly consents to an allowed direct Claude launch |
| 21 | Process-containment threat model | Treat configured repositories, approved repository commands and release-attested children as trusted not to deliberately escape supervision; accept the immediate `fork`/leader-exit/reparent/`setsid` race as residual risk outside source-completion hostile-containment claims | Max selected option 2 on 2026-08-26 after local macOS evidence showed process-group cleanup is escapable and no supported public non-escapable coalition/adoption API was established. PID/start identity tracking and group cleanup remain required for cooperative and observed descendants | Jidoka must execute untrusted repository code, a model can select arbitrary child commands, or a supported kernel-backed isolation primitive becomes available |

## Acceptance criteria

- [x] A fresh direct-source review and focused production tests prove paused reload does not run the coordinator startup pass and `DurableJobStore.recoverAtStartup` touches only the exact canary.
- [x] A fresh close/reopen test proves exact pre-cutover unknown preserves security/test/synthesis hosts, binding and lease, does not invoke generic topology invalidation, and never adopts or closes an unattributed pane.
- [x] Pre-cutover unknown, q4 failed/`interruptedUnknown`, and replacement `lost` are restart-stable and queryable without live-host revalidation or replay.
- [x] Structured output distinguishes no remote effect, possible ambiguity, confirmed replacement effect, known q4 failure with code, q4 prepared/enqueued/settled, and replacement loss.
- [x] Preview and execute bind the exact deterministic q4 descriptor/configuration digest and all backing-file digests through Swift and SQL authority.
- [x] Every authorized Herdr request is bound to the connected peer PID/start/executable/code identity, not only socket pathname, vnode and UID.
- [x] Immediately before `markSendStarted`, source rechecks `paused=1`, exact canary/lease/authorization, socket and peer, resource inventory, pane revision/token state, predecessor, preserved hosts including mapped executable vnodes, planned q4 descriptor, and credential projection digest.
- [x] Credential evidence binds canonical bytes and account; startup and failure cleanup scrub exact final/prepared/staging/orphan projections; any cleanup failure is `CREDENTIAL_CLEANUP_FAILED`; in-memory secret buffers are wiped as far as the Swift/platform boundary permits.
- [x] SQL and Swift reject every global ordinary/replacement host identity collision in either insertion order.
- [x] SQL q4 requires exact replacement event equality using the authorized canary SHA and exact tuple.
- [x] SQL and Swift reject topology-intent timestamp regression and timestamp-only mutation while preserving exact idempotent reads.
- [x] Tests cover post-preview one-field drift, pre-cutover credential cleanup, real production runtime and EngineService execution boundaries, created-pane disappearance/terminal drift, 155-job isolation with populated unrelated ownership, and deterministic short failure bounds.
- [x] Populated schema-8 to schema-9 migration, `0600` backup, integrity/FK checks, and every statement rollback cut pass after the final migration edit with a newly pinned statement count and digest.
- [x] Strict format, `git diff --check`, release build, full serialized suite, and all applicable E2Es pass after the last source edit under the exact attested runtime closure.
- [x] Four fresh direct-source reviews report no unresolved Critical or Major finding within decision 21's locked trusted-repository/trusted-child threat model.
- [x] No release/Developer ID package, install, production mutation, Resume, commit, push, PR, rollback, or promotion occurs during source completion. Disposable ad hoc S1 assembly remains W6 test evidence, not W7 release evidence.

## Workstreams

### W0: Re-establish the checkpoint and reproduce open findings

- Scope: read-only checkout and test inspection.
- Excluded: all source edits until the checkpoint is recorded.
- [x] Repeat the Herdr readiness gate after restart: require `HERDR_ENV=1`, structured Herdr tools, Pi in a Herdr-managed pane, Pi 0.80 or newer, `@ogulcancelik/pi-herdr` 0.4.0, and Herdr 0.7.5 or newer. If any check fails, stop without pane creation, ordinary `/orchestrator` fallback, or `subagent` writer substitution.
- [x] Declare the invocation budget before the first split: one retained generic Pi writer pane, one ordinary process pane at a time, zero direct Claude launches, exact current parent provider/model, one checkout writer lease, parent verification, and protected reviewers routed separately.
- [x] Initialize the invocation-local pane registry and continuous-custody record required by the Herdr overlay. Never register or retire the caller pane or foreign panes.
- [x] Confirm branch, HEAD, `git status --short`, no staged files, no active subagent, and no orphan Swift test processes.
- [x] Read this plan, the 2026-08-23 fallback plan, and `ed5085cc` output before delegating.
- [x] Inspect the actual `ed5085cc` source diff and tests, not only its report.
- [x] Reproduce the three database gaps with failing tests or raw-DML test cases before fixing: unrelated-host global collision, wrong-canary replacement event, and intent timestamp regression.
- [x] Attempt the required slow Critical restart/isolation E2Es once. If fixture setup still fails on exact runtime attestation, record the exact issue and stop treating them as runnable evidence. Do not change policy or Homebrew state.

### W1: Accept or repair the two startup Critical fixes

- Scope: `ProductionEngineJobRuntime.swift`, `DurableJobStore.swift`, `JobCanary.swift`, `HerdrPiWorkflowExecutor.swift`, `JobCoordinator.swift`, and focused production/runtime tests.
- Excluded: outcome, credential, and schema redesign unless a Critical fix requires it; recover from W2 through W4.
- [x] Prove production reload with admission false never calls the real coordinator startup pass, retry promotion, cleanup, or broad lease recovery.
- [x] Seed at least one unrelated active lease, retained workspace, backoff/reconciliation state, and nonterminal job; assert byte-equivalent state before/after paused startup.
- [x] Prove exact pre-cutover unknown preserves the three non-architecture hosts, binding and active canary lease through close/reopen and repeated recovery.
- [x] Prove no generic `invalidateJobTopology`, pane close, shutdown, adoption, q4/q5, provider, or GitHub operation occurs in that state.
- [x] Route a fresh focused architecture review. If either Critical remains, fix it before W2.

W1 status: accepted. Paused startup and exact-canary store isolation, pre-cutover unknown close/reopen preservation, repeated recovery, predecessor exclusion and no-remote-effect assertions all execute under the release-owned runtime and pass.

### W2: Make terminal outcomes and q4 authorization truthful and durable

- Scope: `EngineProtocol.swift`, `ProductionEngineJobRuntime.swift`, `JobCanary.swift`, `HerdrTopologyProtocol.swift`, `HerdrPiWorkflowExecutor.swift`, `PiRunStore.swift`, `DatabaseSchema.swift`, Engine/CLI tests.
- Excluded: peer and credential implementation; recover from W3.
- [x] Define a typed effect-certainty model and statuses for no-effect failure, possible ambiguity, confirmed replacement with q4 prepared/enqueued/settled, known q4 failure with code, and replacement lost.
- [x] Reconstruct each terminal report from durable authorization, intent, host, event, launch, result and release rows after restart without requiring a live replacement host.
- [x] Keep candidate/execute paths denied for every terminal shape; do not turn queryability into retry authority.
- [x] Construct the exact q4 descriptor and configuration digest during preview without publishing a command. Bind it into replacement evidence, authorization request and append-only table, replacement payload/intent, attribution, replacement host causal checks, and q4 SQL trigger.
- [x] At execute, reconstruct the descriptor from canonical backing inputs and require exact byte/digest equality before credentials or remote effects.
- [x] Add raw-DML and store tests proving any descriptor/config/backing-digest mismatch denies send, cutover, and q4.
- [x] Add restart tests for every terminal shape and protocol serialization tests for every status/effect combination.

W2 status: accepted. Source, store, migration, protocol and production-connected gates pass. Exact expected-binding revalidation executes immediately before `markSendStarted`, predecessor shutdown and the first remote effect; terminal restart reconstruction and replay denial are covered.

### W3: Close security authority and credential findings

- Scope: `HerdrSocketClient.swift`, `HerdrTopologyProtocol.swift`, `HerdrPiWorkflowExecutor.swift`, `PackagedPiResourceSnapshot.swift`, `PiProviderCredentialSnapshot.swift`, `PiTUIRuntime.swift`, `JobCanary.swift`, and security/runtime tests.
- Excluded: changes that broaden accepted Node/Pi/Homebrew builds.
- [x] Capture connected peer PID, process start, executable vnode and code identity from each Unix socket descriptor; require exact equality with the initially authorized Herdr peer on every request.
- [x] Fail closed if peer identity is unavailable, changes, exits, or cannot be mapped to the authorized executable.
- [x] Move intent preparation before the last inert boundary, then repeat every live authority check immediately before `markSendStarted` with no unrelated await between the final proof and durable claim.
- [x] Make resource attestation descriptor-pinned and bind complete exact inventory/root vnode evidence rather than trusting a digest-shaped directory name.
- [x] Bind mapped executable vnode/code evidence for predecessor and all three preserved hosts at preview, final send check, cutover, and recovery.
- [x] Add canonical credential projection SHA-256 plus provider account identity to evidence and authorization; verify exact bytes during install/reinstall.
- [x] On startup and every pre-child failure, scrub final `auth.json`, prepared names, staging names, and orphan launch projections. Do not scrub after command visibility is uncertain unless definitive child absence is proven. Map scrub failure to `CREDENTIAL_CLEANUP_FAILED`.
- [x] Use uniquely owned mutable buffers and explicit zeroing around inspection/install as far as practical; document unavoidable immutable `JSONSerialization` copies as residual risk if they cannot be eliminated locally.
- [x] Add peer-swap, final-check drift, credential-byte/account drift, staging/orphan crash, cleanup-failure, vnode-swap, and secret-absence tests.

### W4: Close schema-9 database authority findings

- Scope: `DatabaseSchema.swift`, `PiRunStore.swift`, `PiRunStoreTests.swift`, `SQLiteStoreTests.swift`.
- Excluded: production database migration.
- [x] Make replacement insertion reject ID, pane, terminal and PID/start collisions against all ordinary hosts globally. Make ordinary-host insertion reject the corresponding existing replacement identities in the reverse order.
- [x] Mirror global collision predicates in Swift store preparation and test unrelated jobs/repositories in both directions.
- [x] Replace the q4 event wildcard with exact string equality built from `replacement_authorization.canary_authorization_sha256`, literal `:m8:`, and exact run/q3/q4/predecessor/replacement/payload tuple.
- [x] Require `updated_at >= OLD.updated_at` on every real topology-intent transition, deny timestamp-only mutation, and guard the same instant in `SQLiteHerdrTopologyIntentStore.transition`.
- [x] Add raw-DML denial and valid-control tests for every predicate.
- [x] Re-pin migration statement count/digest/object inventory after the final schema edit, whatever the resulting exact count is.
- [x] Rerun populated migration success and every resulting schema-9 statement rollback cut; compare schema and row digests, backup mode `0600`, integrity, and foreign keys.

### W5: Close validation gaps through real production boundaries

- Scope: runtime, protocol, EngineService, application client/CLI, and isolation tests.
- Excluded: production process or socket access.
- [x] Table-drive post-preview drift for socket/peer, resource inventory, executable vnode/code, stale-pane revision, token presence/digest, preserved host, q4 descriptor/configuration, credential content/account, pause, lease, and authorization.
- [x] For each pre-cutover remote step, assert credential state, exact secret absence from requests/argv/environment/logs, q4/q5 absence, preserved-host equality, and explicit cleanup failure behavior.
- [x] Drive one happy and each terminal/error case through `ProductionEngineJobRuntime.executeCanaryRoleHostReplacement`, `EngineService`, XPC report validation, and CLI JSON serialization. Assert balanced exclusive operation, launch admission, marker gate, and checkpoint cleanup.
- [x] Extend real fake-socket cuts with created-pane disappearance and created-terminal remapping after split and after Enter, retaining exact request-prefix assertions.
- [x] Seed 155 queued unrelated jobs plus at least one populated unrelated ownership chain across repositories, workspaces, leases, backoff, dispositions, runs, launches, commands, intents, steps, bindings/hosts, and fake external-effect ledgers. Require canonical before/after equality.
- [x] Replace 660 to 900 second fixture polling with deterministic event gates or an injected clock and second-scale failure bounds.
- [x] Keep q5 and both Resume modes denied through public store/runtime APIs and raw SQL.

### W6: Fresh final source gate

- Scope: complete checkout, no source edits after evidence begins.
- Excluded: package and live state.
- [x] Run focused tests for `HerdrProtocolTests`, replacement-filtered `PiRunStoreTests`, populated `SQLiteStoreTests`, `DurableJobStoreTests`, `HerdrPiWorkflowRuntimeTests`, `ProductionHerdrCompositionTests`, `EngineServiceTests`, and `ApplicationEngineClientTests`.
- [x] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test list` and confirm the expected final test inventory.
- [x] Run strict recursive swift-format, `git diff --check`, debug build, and release build with Xcode 26.6 build 17F113, SDK 26.5, Swift 6.3.3, and swift-format 6.3.0.
- [x] Run the complete serialized `make check` only when exact runtime attestation passes. If external closure drift still blocks setup, source completion remains blocked; do not waive the check.
- [x] Run all applicable non-live E2Es after the final edit.
- [x] Route fresh direct-source architecture, security and test reviewers plus a fresh direct-source database-impact reviewer after the final source edit.
- [x] Parent verifies every Critical/Major against current source and executable evidence. Fix verified blockers, then rerun every affected check and affected review. Completion requires zero unresolved Critical/Major within decision 21's locked threat model; polling must not be represented as hostile-containment proof.
- [x] Update this plan's Progress, Surprises and discoveries, Execution decisions, and Outcomes with exact commands, exit status, artifacts and residual risk.

### W7: Separately gated package and notarization

- Scope: only after W6 is green and Max explicitly authorizes this gate.
- [x] Build a new UAT successor package from the final source, not v11 and not stale build output.
- [x] Record source-tree content digest, package manifest schema 4, exact component/final-payload tree, app/helper/host bytes, signatures, Gatekeeper, notarization submission/result, stapling and package audit.
- [x] Prove the old installed helper fails closed on an isolated schema-9 copy without changing its bytes or backup count; preserve the exact production schema-8 backup. Do not execute rollback.
- [x] Keep product installation and production data/process/socket effects outside W7. Developer ID and notarization were authorized and executed; no install or publication occurred.

### W8: Separately gated install, migration, preview, replacement and q4

- Scope: only after W7 and a fresh production read-only audit, with exact approval for each mutation boundary.
- [ ] Reverify production `paused=1`, exact socket/peer, exact canary/run/lease/q1-q3/four authorizations, q4/q5 zero, immutable unknown intents, and zero unrelated state change.
- [ ] Reverify PIDs `54262` through `54265`, process starts, argv, executable vnode/code identity, panes/terminals, descriptors and DB rows. Stop on any drift.
- [ ] Install while preserving all role hosts and unrelated state; migrate schema 8 to 9 from a hash-verified backup; keep `paused=1` throughout.
- [ ] Generate one new read-only digest-bound preview and obtain explicit execution approval. Never reuse stale preview or failed wrapper output.
- [ ] Execute exactly one typed replacement operation, retiring only architecture PID `54262` and pane `wM:p2`; never replay an uncertain result.
- [ ] Admit and settle exactly q4 on the new `execution_role_host_id`. Accept only canonical SQLite result, acknowledgement and release rows.
- [ ] Prove q5 remains zero, security/test/synthesis are byte/process/pane exact, 155 unrelated jobs remain queued and undispatched, no GitHub effect occurred, and `paused=1` remains set.
- [ ] Stop after q4 outcome. Resume remains unauthorized and outside this plan's execution.

W8 preflight is blocked before any mutation. The current installed app is root-owned and running as PID `3325`; production remains schema 8 and paused. Durable host rows still name PIDs `54262` through `54265`, but all four processes are absent. More fundamentally, `/Applications` is `root:admin` mode `0775` and Max's account belongs to `admin`, so the locked production resolver correctly rejects that user-renamable ancestor. Do not install, migrate, stop the app, or relax the ownership policy without a new installation-authority design and approval.

### W9: Separate cleanup and Git delivery decisions

- [ ] Ask for exact authorization before removing the temporary Node `26.6.0` alias; verify the target Node `26.7.0` bytes remain untouched.
- [x] Max authorized exact local staging and commit on `feat/settings-guided-configuration` after W7. Push, PR, rollback, Resume, promotion and GitHub publication remain unauthorized.
- [ ] Stage specific files only, inspect the complete index, run the source-control commit gate with hooks active, and record the resulting commit.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Paused startup | exact canary plus unrelated active/retry/cleanup state | only canary recovery, no startup scheduler pass | behavior+edge+error |
| 2 | Pre-cutover unknown | close/reopen and repeated recovery | preserved hosts/binding/lease exact, no adoption or invalidation | behavior+error |
| 3 | Terminal outcomes | no effect, ambiguity, q4 failure, lost host, prepared/enqueued/settled | restart-stable typed report with exact certainty and code | behavior+edge+error |
| 4 | Q4 descriptor | exact descriptor and one-field backing drift | only exact preview digest reaches send/cutover/q4 | behavior+error |
| 5 | Socket peer | path swap, peer swap, PID/start/vnode/code drift | request rejected before authority/effect | behavior+error |
| 6 | Live final check | every one-field drift after preview | rejection before `sendStarted`, no credential residue | behavior+error |
| 7 | Preserved hosts | path restoration around process/vnode substitution | mapped vnode/code mismatch rejected | behavior+error |
| 8 | Credentials | content/account drift, crash/staging/orphan/cleanup cuts | exact binding; scrub or explicit cleanup failure | behavior+edge+error |
| 9 | Global physical identity | ordinary then replacement, replacement then ordinary, unrelated job | every ID/pane/terminal/process alias denied | behavior+error |
| 10 | Q4 event | exact event and wrong canary/prefix/tuple | only exact equality authorizes raw/store q4 | behavior+error |
| 11 | Intent chronology | valid transition, regression, timestamp-only, idempotent read | monotonic transition only | behavior+edge+error |
| 12 | Migration | populated schema 8, every final statement cut, reopen backup | exact schema 9 or unchanged schema 8, `0600`, integrity/FK clean | behavior+error |
| 13 | Remote protocol | every split/text/Enter response/fault plus created-pane loss/drift | terminal unknown after claim, no replay, exact request prefix | behavior+error |
| 14 | Production boundary | runtime, coordinator, EngineService, XPC and CLI | balanced gates and truthful serialized result | behavior+error |
| 15 | Isolation | 155 queued jobs plus populated unrelated ownership | canonical durable and side-effect equality | behavior+edge |
| 16 | Denial | q5, fresh retry, replacement replay, both Resume modes | denied before durable or remote effect | behavior+error |
| 17 | Regression | settings, H1-H5, W8, model catalog, keychain, ordinary role hosts | complete suite and applicable E2Es green | regression |
| 18 | Package/live | notarized bytes, schema backup/migration, exact q4 | separately authorized evidence chain, no unrelated effect | operational |

**Coverage:** 18/18 identified authority, recovery, security, database, validation, regression and operational families. Gaps remain explicit until W6 through W8 complete.

**Exhaustiveness rationale:** The matrix is the union of durable state shape, irreversible remote steps, physical identity dimensions, credential lifecycle, migration statement boundaries, production API layers, isolation cardinality, and denial paths. Each family is parameterized by one-field drift or fault position rather than combinatorial duplication.

## Review plan

- Planned routed agents: `pi-forge.architecture-reviewer`, `pi-forge.security-reviewer`, `pi-forge.database-reviewer`, `pi-forge.test-reviewer`.
- Final W6 execution: fresh direct-source `architecture-reviewer`, `security-reviewer`, `test-reviewer`, and a direct-source database-impact `reviewer`. The package database route rejected its effective contract before launch and was not credited as review evidence.
- Protected routing: every package-qualified Pi Forge reviewer remains on the normal protected `subagent` route. Never launch or represent a generic Herdr agent as a protected reviewer.
- Review artifact: current direct source, complete changed-file roster, schema migration and triggers, state/outcome model, peer and credential evidence, focused/final test output, format/build results, and explicit external blocker evidence.
- Critical/Major evidence gate: parent reproduces each executable trace where practical, inspects the cited source directly, rejects stale or artifact-only assertions, and reruns affected evidence after any fix.

## Budget

- Fix rounds: maximum 5 initially. Max's 2026-08-25 extension in the release-owned runtime plan superseded that cap with all bounded one-writer fix/review rounds necessary for zero unresolved Critical/Major findings.
- Herdr agents: one retained generic Pi writer pane, using the exact current parent provider/model with `read,bash,edit,write,grep,find,ls`, `--no-session`, no Herdr/subagent tools, no nested agents or CLI bypass. Reuse it for at most 5 bounded prompt rounds after each lease is explicitly released.
- Process panes: at most one ordinary test/build pane active at a time. Treat builds, tests and uncertain commands as potentially mutating and serialize them under the same writer lease.
- Protected delegated launches: 4 final reviewers and at most one focused Critical reviewer initially; Max's bounded-round extension covered the additional independent fix reviews and network retries, always through normal `subagent`, never through Herdr.
- Writer concurrency: exactly 1 across parent, Herdr writer, and potentially mutating process panes.
- Pane retirement: only exact invocation-created panes under continuous exclusive custody, after complete result capture, confirmed process stop and fresh structured revalidation. Retain and report every ambiguous pane.
- Final evidence: focused filters, test discovery, strict format, diff check, debug and release builds, full serialized `make check`, applicable E2Es, then four direct-source reviews after the final edit.

## Risks and rollback

- Risk: Homebrew closure drift keeps slow E2Es and `make check` blocked. Mitigation: preserve exact policy, report the blocker, and require a separately authorized restoration of the exact attested environment. Do not normalize or bypass it.
- Risk: extending schema 9 changes the 49-statement migration evidence. Mitigation: re-pin the final count/digest and rerun every prefix rollback cut after the last schema edit.
- Risk: terminal queryability accidentally creates retry authority. Mitigation: separate read-only report reconstruction from candidate/execute admission and test replay denial for every terminal shape.
- Risk: peer/process attestation depends on macOS APIs or Herdr behavior not available in fixtures. Mitigation: fail closed, add adapter-level tests, and require real non-mutating UAT evidence before packaging.
- Risk: credential scrub after command visibility could remove a live child's credential. Mitigation: retain credentials whenever visibility or child existence is uncertain; scrub only with definitive pre-child evidence and release on canonical completion.
- Risk: the large dirty checkout can hide unrelated regressions. Mitigation: preserve all user changes, use narrow edits, run the complete suite, and route direct-source reviewers after the final edit.
- Accepted residual: a deliberately hostile trusted child can evade polling and POSIX process-group cleanup by forking, allowing its leader to exit before observation, reparenting, and calling `setsid`. Mitigation within the selected threat model is limited to exact release/repository trust, PID plus start-time identity, cleanup of observed descendants and fail-safe refusal to signal reused identities. This is not non-escapable containment and must be revisited before untrusted repository execution is considered safe.
- Rollback: source edits remain reversible through targeted review and explicit edits. Do not use reset/checkout/stash. Production rollback is not authorized and requires the exact schema-8 backup plus a separate decision.

## External side effects

- Authorized now: writing and reviewing this plan; after Max approves it, source-only implementation, bounded Herdr workflow-pane creation/supervision/eligible retirement, and local non-live tests.
- Not authorized: commit, push, PR, release/Developer ID package, notarization, install, production migration, production socket/process action, provider/GitHub action, live replacement, q4 execution, rollback, Resume, promotion, or temporary-alias removal. Disposable ad hoc S1 assembly is authorized test evidence only.

## Progress

- [x] Analysis and draft completion plan
- [x] Confirmed no active subagent and no evidenced database-writer result
- [x] Preserved `ed5085cc` report and external runtime blocker
- [x] Max selected `/herdr-orchestrator`; fresh readiness passed with Pi `0.84.2`, `pi-herdr` `0.4.0`, Herdr `0.8.2`, and `openai-codex/gpt-5.6-sol`
- [x] Max approval of this completion plan
- [x] W0 checkpoint and reproduction
- [x] W1 Critical acceptance: paused startup, exact-canary isolation and pre-cutover unknown restart paths pass
- [x] W2 durable outcome and q4 descriptor authority: typed restart-stable outcomes and production boundary evidence pass
- [x] W3 security authority and credentials: peer, resource, executable, credential and cleanup boundaries pass
- [x] W4 database authority: schema 9 finalized at 51 statements with all migration cuts and reviews green
- [x] W5 validation gaps: 51 drift, 28 fault, production boundary, protocol and 155-job isolation matrices pass
- [x] W6 fresh final source gate and reviews: zero unresolved Critical/Major under decision 21
- [x] W7 package/notary: final package `71023263…`, Apple Accepted, exact payload and schema-compatibility evidence complete
- [ ] W8 install/replacement/q4: blocked before mutation by stale live-host evidence and `/Applications` mode `0775`
- [ ] W9 cleanup or Git delivery: local commit authorized and in progress; cleanup/push/PR remain separate

## Surprises and discoveries

- `ed5085cc` completed and made a coherent narrow source change, but the required slow restart/isolation E2Es are externally blocked before scoped behavior executes.
- The 2026-08-24 database writer invocation returned no result and left no active fleet owner. Current source still exhibits all three targeted database predicates, so it must not be credited as a fix.
- External Homebrew upgrades occurred independently while the exact attested runtime policy remained unchanged. This correctly causes fail-closed fixture setup.
- W0 reproduced the three schema defects independently: cross-job ordinary/replacement physical aliasing, wrong-canary q4 event authorization, and topology-intent timestamp mutation/regression.
- W2 required a second source round after security review identified a gap between q4 validation and the `markSendStarted`/shutdown boundaries. Expected-binding rechecks and production-connected checkpoints now sit at both boundaries.
- The new production boundary oracle, authorized-binding integration cases, and slow restart E2Es all fail before their assertions at the same `.invalidDescriptor` fixture boundary. Pure, store, raw-SQL and protocol checks remain green, but they do not replace the missing production evidence.
- W3 closed connected-peer, descriptor-pinned resource, mapped executable/code, exact credential and cleanup authority. A security review found and the next round fixed one intermediate-directory `O_NOFOLLOW` gap by retaining the complete parent FD chain.
- W4 finalized schema 9 at 51 statements with migration digest `5e8b3b5d76399b933405c211a42f6ea796cea0e2f376dcfe18c9644d9c1e33f4`; all 51 rollback cuts, populated migration, integrity, foreign keys and mode-0600 backup evidence passed.
- Final runtime discovery first exposed installed Pi `0.84.3`, while packaged authority has no attested `0.84.3` build. A separately authorized offline staging of Pi `0.84.2` matched all four critical digests, all 14,543 package entries and package-tree digest `ded47bd3a428cce5a379b70b7f8e398e8b18b86498d3e75cd41e472fbfc9c25a`; its temporary symlink was activated and restored exactly.
- The exact Pi restoration falsified the Pi-only blocker hypothesis. With attested Pi `0.84.2`, the runtime suite still ended with the same 36 test functions and 175 issues after 562 seconds. The first failures are `unattestedNodeBuild`; later `.invalidDescriptor`, `.resultDivergent` and timeout issues are cascades.
- Node `26.7.0` itself matches the packaged executable, but its closure has three exact mismatches: `merve` resolves to `1.2.2_2` instead of `1.2.2_1`, `simdjson` to `4.6.8` instead of `4.6.7`, and `simdutf` lacks the expected `9.0.0` soname. All three expected Cellar directories are absent. The retained `26.6.0` alias now resolves to `26.7.0` and has six policy mismatches, so it is not restoration evidence.
- Max completed Xcode first-launch tasks. `xcodebuild -checkFirstLaunchStatus` and the complete toolchain verifier now pass with Xcode 26.6 build 17F113, SDK 26.5, Swift 6.3.3 and swift-format 6.3.0.
- The release-owned runtime removed the environmental fixture blocker without enrolling current Homebrew state: exact Node/Pi authority now comes from the staged release input, and production-compilable external fallback is absent.
- Final security review found and the last bounded round fixed three Major defects: readiness now binds the live peer path/hash to the attested Herdr executable, fresh-retry authority binds credential content/account through a privacy-preserving digest, and accepted settlement cannot mask process cleanup failure.
- W7 first falsified the assumption that ad hoc and Developer ID Node CodeDirectories match, then Apple rejected the first installer because five Pi native modules lacked Developer ID timestamps. Separate mode-bound Node digests and a signed complete Pi tree closed both failures without adding entitlements.
- Package re-review exposed a mutable component/payload gap and stale S4/S8 diagnostic expectations. The final package validates current verifier products, component and expanded signed payload bytes, exact release compatibility/digests, and records `payloadTreeSHA256`; all three final review domains scored 100/100.
- The standard target `/Applications` is mode `0775`, not a non-renamable authority boundary for an admin user. This makes W8 impossible under the current secure policy; the finding is a blocker, not permission to weaken the policy.

## Execution decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Restart handoff | Create this self-contained completion plan instead of continuing from compacted chat memory | A fresh Pi can recover exact scope, findings, gates and first action from disk |
| 2 | Failed database launch | Treat as not run, not failed implementation and not evidence | No run ID, output, active agent or source predicate change exists |
| 3 | Critical fix status | Implemented but review-required | Writer completion and partial focused checks do not meet independent acceptance |
| 4 | Execution control plane | Use the explicit Herdr overlay with a generic Pi writer and ordinary process panes; keep protected reviews on their required route | Max requested `/herdr-orchestrator`; fresh readiness passed before pane creation |
| 5 | W1 verification gap | Continue source-only work after direct review found no demonstrated code defect, but keep the restart Critical unaccepted | `.invalidDescriptor` prevents the reviewed control path from executing; no production-code remedy is evidence-backed |
| 6 | W2 same-UID race | Add exact expected-binding rechecks at the named W2 effect boundaries; defer descriptor-pinned vnode and stronger same-UID authority to W3 | The W2 requirement is exact revalidation before credentials and remote effects; absolute same-UID exclusion requires the separately planned W3 authority design |
| 7 | External runtime drift | Preserve runtime policy and record production-path tests as blocked rather than weakening descriptor authority | The attested Homebrew Node/Pi closure changed outside this workflow; environment mutation is not authorized |
| 8 | W3 resource traversal | Retain and revalidate every intermediate directory FD; never rely on leaf-only `O_NOFOLLOW` | Security review proved a rename/symlink attack against slash-containing `openat` paths |
| 9 | W4 final authority | Keep schema version 9, add two reverse collision triggers, and re-pin to 51 statements | Global bidirectional physical identity needs ordinary INSERT and activation UPDATE authority without table normalization |
| 10 | W6 outcome | Stop source completion as environmentally blocked after final reviews; do not run package/live gates | Test review reports two unresolved Major verification blockers and completion requires zero unresolved Critical/Major |
| 11 | Authorized environment retry | Stage and attest Pi `0.84.2` offline, atomically redirect only the Pi symlink under a trap, and restore/delete it on every exit | This tests the Pi hypothesis without changing source policy, installed package bytes or Node |
| 12 | Node closure after Pi retry | Do not reconstruct absent Homebrew Cellar versions or repoint shared `opt` links under the Pi-only authorization | Restoring the remaining closure would mutate shared Node dependency authority and needs a separate explicit decision |
| 13 | Immediate process-group escape | Accept as an explicit trusted-child residual instead of expanding source completion into sandbox/broker architecture | Max selected option 2 on 2026-08-26. Local macOS evidence supports `setsid` escape from process-group cleanup and did not establish a supported public non-escapable containment API; claiming closure from polling would be false |
| 14 | W6 final outcome | Supersede decision 10 and accept W0-W6 source completion under decision 21 | Release-owned runtime authority made every source gate executable; the final three security defects were fixed, complete lifecycle evidence passed and fresh focused reviews report zero unresolved Critical/Major |
| 15 | W7 release identity | Bind distinct controlled ad hoc and Developer ID Node CodeDirectories and prequalify all Darwin Pi native modules | Real signing and Apple notarization falsified the single-digest/unsigned-native assumptions; no entitlement or policy broadening was used |
| 16 | Final package authority | Validate current verifier builds, copied component and expanded signed product payload, then bind `payloadTreeSHA256` | Inventory and signature of mutable staging alone were insufficient to prove the installer contained the validated bytes |
| 17 | W8 installed path | Stop before install and reject standard `/Applications` as production authority | Root-owned app bytes do not close a group-writable parent-directory rename attack; relaxing the ancestor check would violate the locked policy |
| 18 | Git delivery | Accept Max's authorization for one local commit only; no push or PR | The non-primary branch is verified, the index is empty, and remote publication remains a separate decision |

## Outcomes and retrospective

W0 through W7 are complete under decision 21. W1 proves paused startup, exact-canary isolation and pre-cutover unknown restart preservation. W2 provides typed restart-stable outcomes and exact q4 authority. W3 binds the live peer, descriptor-pinned resources, mapped executables/code and privacy-preserving credential evidence through the final send proof. W4 closes global identity, exact-event and chronology defects with schema 9 fixed at 51 statements and migration digest `5e8b3b5d76399b933405c211a42f6ea796cea0e2f376dcfe18c9644d9c1e33f4`. W5 executes the 51-case drift matrix, 28-case fault matrix, production boundaries, protocol cuts, exact 155-job isolation, deterministic event gates and denial coverage.

Final W7 artifact: `build/settings-guided-w7-release-owned-runtime-71023263-uat-notarized/Jidoka Code.pkg`, SHA-256 `7102326303e2fe1f1394c42b4f919351f14ec3c37f5ac26dd962ac23c83ab0cb`; manifest SHA-256 `3e1d62dd237383e39724992946e0735e32e7819391904630c0d0fe318fd9608a`; payload-tree SHA-256 `40e12b9c8da810ef19f5b19d606310e29263fda379916d85441842bea8fbfea4`; notarization `9ed36ebb-a727-451c-90fe-8124041387e2`, status `Accepted`. Gatekeeper, stapling, exact component/payload equality, Developer ID Node/JIT/native/Pi probes and old-binary schema-9 denial passed. The preserved schema-8 backup SHA-256 is `e2c1a073c5ae3638466fa9fe4a63bf79035e3bbe1130b46ea7ad02cf18543f41`, mode `0600`, integrity `ok`, zero FK violations.

Fresh after the last source edit: S1 passed; `make jidoka-code-w7-acceptance` passed 646 tests in 78 suites, S10 with zero external effects, and credential-free S4/S8 preflights with zero provider calls; recursive strict format, debug/release builds and `git diff --check` passed. Final W7 architecture, security and test re-reviews each scored 100/100 with zero Critical/Major/Minor. Decision 21's immediate hostile `fork`/leader-exit/reparent/`setsid` escape remains accepted and is not represented as closed containment.

No product installation, production database/socket/process mutation, q4, q5, Resume, push, PR, rollback, promotion or publication occurred. W8 is blocked because current host rows reference absent PIDs and `/Applications` mode `0775` violates production ancestor authority. Max authorized one local commit; staging and commit evidence remain W9 work.
