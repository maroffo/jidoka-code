# ABOUTME: Redacted W0-W6 source review brief for progressive production automation.
# ABOUTME: Binds the working source, schema, authority graph, call sites, fault matrix, verification, and open gates.

# Review brief: progressive production automation W0-W6

## Review state

The W0-W6 implementation is present and every required local source gate below is green after
the last source or harness edit. Max explicitly authorized disposable SQLite fixture writes
and the local synthetic S12 provider; neither authorization covered production state or a live
provider. Source completion is not claimed because the four mandatory fresh artifact-only
reviewers remain unavailable: this runtime exposes no protected-child carrier or
`pi-forge.*-reviewer` tool. On 2026-09-04 Max explicitly directed commit, same-name branch push,
and one PR before those reviews so that they can run against the published source PR. Merge and
W7 remain excluded.

At artifact capture time no source commit or push had been performed. No merge, tag, signing,
notarization, installation, production database operation, rollout activation, live workflow
GitHub or Git operation, live or external provider call, finite promotion, rollback, deployment,
or historical-evidence cleanup has been performed.

## Source authority and artifact binding

- Worktree: `/private/tmp/jidoka-code-progressive-production-automation`
- Branch: `feat/progressive-production-automation`, a non-primary branch
- Baseline HEAD and delivery commit parent: `09e52bc47289205d17bc1bae99ff89cd33a0643b`
- Base tree: `cfeab7e8ec58e1dac091547615a3815dbb6977f9`
- Recorded `origin/main`: `09e52bc47289205d17bc1bae99ff89cd33a0643b`
- Required ancestor `b6cb62ba7d53d5de740d6e2983656f911db7bd1c`: present
- Approved plan source: `c728eb55af4a2af5c5c27d354ba635c9180821f5`
- Approved and merged plan blob: `c62cb3c05049bd6a372b683e557b585409782345`
- Plan SHA-256: `e8afa3a8a25238063cde9672d887c918655a3c4f769acc1d78d974c39a3e83c8`
- The plan in HEAD is byte-identical to the approved plan at `c728eb55`.
- Exactly one source writer operated in this worktree. No subagent or second writer edited it.
- Implementation roster: 109 source, test, script, packaging, and operations files, comprising
  86 baseline modifications and 23 additions. One evidence-only `.gitattributes` update scopes
  whitespace exemptions to the preserved raw logs and nested diff.

Artifact members:

- `status.txt`: complete 173-entry pre-commit delivery roster, including this evidence bundle,
  SHA-256 `3d8de9e61d6c029a2597d9c2a6316008c2a17007427340139beab9dd93adba3d`;
- `tracked-changes.diff`: exact full-index binary-capable diff for all 109 implementation files
  plus the evidence-only attribute update, 28,713 lines, 22,533 insertions and 870 deletions,
  SHA-256 `03c3aabcfebde066924d19c9e99f410738547cd810e7ad9d14c233ee59419eb4`;
- `untracked-source.sha256`: exact names and content hashes for all 23 new implementation
  files, SHA-256 `d2a1d8d5725b977aea73c2cafe83ab41f22b1e7bf60ef31dcd75453af8c80a94`;
- `schema-10-migration.swift.txt`: exact migration-10 source excerpt, 1,486 lines,
  SHA-256 `a2baf03d1dd15a280a6737ac9ed666c761b14261d4e1b03f6453d6ea4cd8f22e`;
- `call-site-inventory.txt`: 302 source matches covering rollout authority protocols,
  production composition, task contexts, reservations, verification, settlement, scheduler,
  creation, leases, recovery, and phase checkpoints, SHA-256
  `a4ba74d34e46fcf810996c47b522abbdd9d00a798151bc64ef5bd2dd74ff260f`;
- `w0-baseline.md`: preserved pre-fix controls and failures, SHA-256
  `c7c877053c53b92b656a9a7d8cec2652a6ea0278eed2404fd258f24bda1eaaee`;
- `logs/`: immutable command output retained for successful, failed, and superseded attempts.

The artifact contains no token, credential, private key, raw provider transcript, or private
repository payload. A pattern audit found no bearer token, GitHub token prefix, password value,
or private-key header. Source-controlled redacted logs are ordinary `0644` files; protected
runtime sessions, descriptors, databases, backups, and prior evidence were neither opened nor
changed by this work.

## W0 baseline failures preserved

`w0-baseline.md` records the clean merged baseline before production source edits. New
fail-closed assertions reproduced all stated gaps:

- an unscoped coordinator pass dispatched two serial queued jobs;
- repository flag drift did not make an already queued job inert;
- paused startup still entered unbound recovery;
- onboarding completion unpaused persisted settings and dispatch;
- an implementation-created PR review child was directly leasable without separate generated
  review authority.

The 101-item pagination control passed before implementation and is covered again in the final
suite. The baseline gap therefore reproduced exactly, so no plan amendment was required.

## Workstream result

- W1: schema 10 adds one durable rollout lane, canonical previews, exact activation, immutable
  bindings, non-replenishing budgets, events, candidates, input snapshots, generated-child
  links, effect reservations, local-effect bindings, and exact readback authority.
- W2: scheduler admission is denied without an active scope; discovery, creation, normal lease,
  retry, waiting-human evaluation, recovery, direct execution, and completion require the same
  binding. Legacy jobs stay inert. A planning job releases its lease at the simple-plan
  boundary and remains queued at `orchestrate`.
- W3: GitHub reads, Git remote reads, provider launches, approved commands, marker batches,
  labels, GitHub mutations, branch creation, and PR creation pass through a closed authority.
  Git and GitHub sends reserve authority atomically with mutation-intent send start.
- W4: PR review, triage, implementation planning, implementation execution, and generated PR
  review have separate stage envelopes and durable checkpoints. Execution and generated review
  cannot inherit planning authority.
- W5: engine protocol 12 exposes typed preview, exact activation, status, stop and drain,
  recovery preview and execution, plus finite-window commands. The UI renders canonical bytes,
  target, budgets, missing labels and predicted effects, and requires the displayed digest.
  Generic Resume is absent. New repositories and every workflow flag default off.
- W6: deterministic acceptance targets, fixed-value schema, read-only preflight, package release
  identity, operations runbook, focused evidence, full source tests, and this review artifact are
  present. Max explicitly moved source delivery before independent review so the reviewers can
  operate on the PR; source completion and merge remain gated on their findings.

## Schema-10 SQL and preservation contract

The production migration is `progressive-production-rollout-authority`, requires a backup, has
exactly 74 ordered statements, and is pinned by the migration digest:

```text
0c411528a84fa412eeee2d359571fa6df21b2355b044620e3342def88ec95099
```

The exact Swift SQL source is in `schema-10-migration.swift.txt` and in
`tracked-changes.diff`. It creates these authority families:

- `rollout_authorizations`, scopes, budgets, and append-only events;
- finite-window candidates;
- exact job bindings and job input snapshots;
- append-only generated job links;
- effect reservations and provider or command local-effect bindings;
- finite discovery reads and terminal uncertain-effect GitHub or Git readbacks.

Schema constraints enforce one open lane, exact repository and stage flags, concurrency one,
fixed scope and budget identity, immutable binding and reservation identity, state-only
transitions, append-only evidence, per-kind costs, stage ceilings, cumulative caps, exact
mutation-intent linkage, and `paused = 1` before terminal lane closure. Migration sets
`paused = 1`, `max_concurrency = 1`, clears the active rollout ID, and leaves every existing job
at `rollout_generation = 0`. It creates no authorization, binding, snapshot, reservation, or
effect from historical data.

`SQLiteStoreTests.productionRolloutAuthorityMigration` verifies a populated schema-9 database,
one mode-`0600` pre-v10 backup, exact historical rows, no manufactured authority, integrity,
and idempotent reopen. `production schema 9 to 10 rolls back after every exact migration
statement` passes all 74 cuts, requiring the original schema-9 bytes and rows or the complete
schema 10 result, never a partial migration. Old schema fixtures, JobCanaryScope, jobs, runs,
results, intents, sessions, descriptors, backups, and evidence remain represented and are not
deleted or rewritten.

## Authority state graph

The SQL trigger, store transitions, protocol reports, and UI use the same state set:

```text
no row
  -> active

active
  -> draining
  -> recoveryRequired
  -> settled | revoked | expired | failed

draining
  -> recoveryRequired
  -> settled | revoked | expired | failed

recoveryRequired
  -> active                 exact recovery preview and checkpoint only
  -> settled | revoked | expired | failed

settled | revoked | expired | failed
  -> no transition, no delete
```

`active -> draining` first closes in-memory effect admission. Every other transition out of an
open lane requires durable pause. Expiry and configuration drift close admission before the
transition. Exact recovery requires one nonterminal bound job, unchanged release and
configuration evidence, no outstanding nonsettled read or effect, the matching checkpoint,
and an unexpired exact-object authorization.

Effect reservations are independent append-only state machines:

```text
reserved -> settled
reserved -> sendStarted -> observationRequired -> attributed -> settled
                       \-> attributed -------------------------> settled
                       \-> settled
```

Identity and cost columns never change. Revocation, expiry, failure, or drain denies every new
reservation. A GitHub or Git readback can still be created only for the exact original
`sendStarted` or `observationRequired` reservation and mutation intent, and consumes the
original lane's remaining read budget.

## Scheduler, job, and phase admission inventory

The raw inventory is in `call-site-inventory.txt`. Critical admission points are:

| Surface | Mandatory authority point | Source |
| --- | --- | --- |
| Scheduler startup and triggers | `schedulerAdmission`, active or readback-only | `DurableScheduler.swift:374,399,412` |
| Interrupted startup lane | mark recovery-required before coordinator recovery | `JobCoordinator.swift:253` |
| Discovery | task-local `.discovery`, exact repository, stage and selector | `JobCoordinator.swift:300-499` |
| Job creation | atomic slot authorization then binding | `DurableJobStore.swift:189,264` |
| Generated review child | active parent checkpoint plus append-only link | `DurableJobStore.swift:310` |
| Normal lease | active matching rollout binding | `DurableJobStore.swift:411` |
| Waiting-human or phase lease | active phase checkpoint and exact stage | `DurableJobStore.swift:488` |
| Retry and recovery lease | active matching binding and current snapshot | `DurableJobStore.swift:1668` |
| Direct workflow execution | task-local `.workflow(jobID)` | `JobCoordinator.swift:816,1031` |
| Workflow calls | same task-local job context through all three workflows | `PullRequestReviewJobWorkflow.swift`, `IssueTriageJobWorkflow.swift`, `IssueImplementationJobWorkflow.swift` |
| Planning handoff | frozen plan, durable checkpoint, lease release, same queued job | `IssueImplementationJobWorkflow.swift`, `JobStateMachine.swift` |
| Scope completion | status, failure, recovery-required or settlement on the same ID | `JobCoordinator.swift:884-947` |

Exact scopes admit one job only. Finite windows bind deterministically ordered candidates and
consume a job slot at first binding. They cannot cover `implementationExecute` or
`generatedPRReview`, cannot use another scope's budget, and expire without replenishment.

## External-effect call-site inventory

Production composition injects the same `RolloutAuthorityStore` into broker, Git transport,
mutation executor, publishers, durable command executor, Pi or Herdr runtime, scheduler,
coordinator, and job store. There is no production allow-all implementation. Optional generic
transport constructors remain for local or test composition, but a remote operation without
the matching production authority fails with `rolloutAuthorityRequired` before transport.

| Effect class | Reserve and bind | Last check before effect | Actual boundary | Settlement or recovery |
| --- | --- | --- | --- | --- |
| GitHub read | `reserveGitHubRead` | `verifyGitHubReadPermit` after credential parse | `GitHubBroker.transport.send` | response or typed failure digest |
| Git remote read | `reserveGitRemoteRead` | `verifyGitRemoteReadPermit` | `SystemGitTransport.runGit` | process evidence digest |
| Provider | `reserveProvider` plus durable run binding | `verifyProviderPermit` | Herdr child launch | exact result, interruption or recovery evidence |
| Approved command | `reserveApprovedCommand` | `verifyApprovedCommandPermit` | process creation | accepted, failed, timeout or unknown evidence |
| Marker batch | `reserveMarkerBatch` reserves all parts | per-part GitHub send permit | first comment send only after full batch authority | exact multipart reconciliation |
| GitHub send | `reserveGitHubSendAndMarkStarted` | `verifyGitHubSendPermit` | broker write transport | attributed, settled or observation-required |
| Git create-only send | `reserveGitSendAndMarkStarted` | `verifyGitSendPermit` | guarded `git push` | exact ref readback or terminal ambiguity |

`RolloutEffectAuthorityStoreTransactions.swift` performs GitHub or Git reservation insertion,
budget consumption, mutation-intent `markSendStarted`, send epoch update, and authority event in
one SQLite transaction. Transport receives only the returned task-bound, single-use permit.
Pause or drain between reservation and verification prevents the process or network effect.

## Stage envelopes and simple-plan boundary

| Stage | Provider ceiling per job | Permitted effect shape | Required durable boundary |
| --- | ---: | --- | --- |
| `prReview` | 4 | bounded GitHub and Git reads, four roles, one marker batch | exact open PR revision and narrative |
| `issueTriage` | 1 | reads, missing-label bootstrap, one role, marker and verdict | exact issue, comments, labels and base |
| `implementationPlan` | 15 | reads, claim or planning publications, planning roles | `claimReady` or separately authorized replan |
| `implementationExecute` | 15 | reads, orchestration roles, approved commands, create-only branch, PR, link and QA | frozen plan at `orchestrate` or exact approved-plan checkpoint |
| `generatedPRReview` | 4 | bounded reads, four roles, one marker batch | append-only generated child link |

A simple or moderate planning result persists its frozen plan and command definitions, releases
the repository lease, and queues the same job at `orchestrate`. Planning authority cannot run a
command, orchestration role, Git push, PR creation, or generated review. Complex approval is
bound to exact plan, issue, base and label state; stale approval is consumed without execution
and returns to separately authorized planning.

## Protocol-12, UI, defaults, and operations

- `EngineProtocolVersion.current` is 12. Request and response validation binds version, request
  ID, operation, canonical preview, authorization ID, digest, state, and recovery result.
- `RolloutCLI.swift` accepts only the closed rollout command grammar and canonical base64 JSON.
- The UI exposes `jidoka.rollout.input`, `jidoka.rollout.preview`, canonical preview, digest
  confirmation, activation, `jidoka.menu.rollout-stop`, and
  `jidoka.menu.rollout-recovery`. The former `jidoka.menu.pause-resume` contract is absent.
- `setPaused(false)` is denied by the service, configuration store, and schema trigger.
  Activation performs the only atomic paused-to-active transition.
- Poll now requires an active finite window. Stop closes admission, drains with a bound timeout,
  checkpoints, and reports `revoked` or `recoveryRequired` rather than a false success.
- Settings creates a repository with `enabled = false`; review, triage and implementation draft
  defaults are all `false`. Onboarding remains paused.
- `docs/operations/progressive-production-rollout.md` documents qualification, preview,
  activation, stage ceilings, planning handoff, stop, recovery, finite promotion and every
  excluded live action. Expected values are locked by a strict JSON schema with unknown fields
  denied and all source-only side-effect counters fixed at zero.

## Deterministic fault matrix

| Fault family | Injected boundary or drift | Expected closed outcome | Executable evidence |
| --- | --- | --- | --- |
| W0 unscoped dispatch | serial queue, flag drift, paused recovery, auto-unpause | no discovery, lease or workflow | `JobCoordinatorTests`, `EngineServiceTests` |
| Migration | every one of 74 statements, populated v9, reopen | exact v9 plus backup or complete v10 | `SQLiteStoreTests` |
| Canonical authority | unknown field, byte change, stale digest, expiry | no activation row or effect | `RolloutAuthorityStoreTests` |
| SQL immutability and cap race | UPDATE, DELETE, overlap, concurrent reservations | transaction abort, no partial row or cap overrun | `RolloutAuthorityStoreTests` |
| Scheduler and lease | startup, periodic, wake, retry, waiting-human, legacy job | only bound repository, stage and job proceeds | `DurableSchedulerTests`, `DurableJobStoreTests`, `JobCoordinatorTests` |
| Preview reads | 101 items, duplicate, redirect, node drift, oversize, close-after-reserve | complete bounded inventory or pre-transport denial | `GitHubHTTPTests`, `GitRolloutPreviewTests`, `RolloutRemotePreviewRevalidatorTests` |
| Provider | extra or wrong role, round, nonce, artifact, narrative, resource, profile, reuse | no child or exact recovery-required state | `RolloutAuthorityStoreTests`, `HerdrPiWorkflowRuntimeTests` |
| Approved command | wrong order or digest, close-after-reserve, fail, timeout, lost evidence | no process, stop at first failure, or irreversible unknown | `DurableApprovedCommandExecutorTests` |
| GitHub send | six crash windows, retry generation, delayed visibility, loss | atomic send-start, readback only, never blind second send | `GitHubMutationExecutorTests`, `MutationReconcilerTests` |
| Git publication | absent, same, conflicting ref, race, malformed SHA, loss | old-zero create, attribution or terminal stop | `GitPublicationTests`, `GitPushGuardTests` |
| Marker and labels | whole-batch cap, multipart loss, missing or conflicting definition | all parts authorized before part one, exact create or block | marker and label publisher tests |
| Stop, drain and recovery | every open state, admitted effect, timeout, restart | fresh effects denied, exact drain or recovery-required | `RolloutAuthorityStoreTests`, `ProductionEngineExternalServicesTests` |
| PR review | head or base drift, narrative divergence, ambiguous marker | no provider or write on stale input, exact readback on uncertainty | `PullRequestReviewJobWorkflowTests` |
| Triage | issue, comment, label, base drift, marker or label ambiguity | stale scope closes or bounded finite retry | `IssueTriageJobWorkflowTests` |
| Implementation | plan, approval, command, publication and cleanup crash points | durable phase checkpoint, no cross-stage execution | `IssueImplementationJobWorkflowTests` |
| Generated child | missing or forged parent link | child remains inert | `RolloutAuthorityStoreTests`, `IssueImplementationJobWorkflowTests` |
| Protocol and UI | unsupported version, malformed command, stale digest, busy click | typed denial, no duplicate activation | protocol, client, view-model and S10 tests |
| Privacy and package identity | mutated nested binary, runtime, resource, secret-shaped output | fail closed before authority, redacted evidence only | release-attestor tests and S1 |

## Verification evidence

Fresh after the last production source or harness edit:

- `make check`: PASS. Toolchain validation, ShellCheck, deterministic preflights, Node contract
  checks, strict Swift format, debug and release builds, and 721 tests in 83 suites passed in
  146.150 seconds. Log SHA-256
  `2ff9f57501e19b68d89ceba7ddcab70712cde42e6e9d41db45ad6de551fd9ac5`.
- `make test-e2e`: PASS. S1 packaging, S10 UI, S11 Herdr, and S12 exact Pi TUI all passed.
  S10 reported `keychain:0,network:0,provider:0,service_management:0`; S11 reported zero
  default-socket contacts; S12 used the authorized local synthetic provider twice and reported
  `provider_network=0`, exact process group and child identity. Log SHA-256
  `d357635691ea143384b37b9bad81aba7f81a563e69f0d73f4ee0d8c856148867`.
- `make jidoka-code-production-automation-acceptance`: PASS. The preflight reported
  `credentialReads=0 providerCalls=0 githubMutations=0 gitRemoteReads=0`, then 171 tests in all
  16 required suites passed. Log SHA-256
  `7bdd2d1140da897e6b0d29133c3084ad5bec887a392e7e896b052599d2e05a01`.
- `xcrun swift-format lint --recursive --strict Sources Tests`: PASS with no diagnostic. Log
  SHA-256 `349fa6491d9a99d4421f70f32c10f60a565611fe8d822cbf247dc760cde7cb2a`.
- release builds: `JidokaCodeApp`, `JidokaCodeEngineProbe`, and `JidokaCodeHerdrHost` PASS.
  App log SHA-256 `0953ede3b9c9689fe88370ff9c8cade620bf8552f87dd4752b387865f34eefd2`;
  helper log SHA-256 `3c56fcd5234c9359c3cbec7a12fab284d1dca988e5366ce73dcb50093d917826`;
  host log SHA-256 `da187197ff5791c85a6cd7f32cad3ece7fe23d1432d2bbb0a8cf2c55006981f0`.
- `git diff --check`: PASS with no diagnostic. Log SHA-256
  `349fa6491d9a99d4421f70f32c10f60a565611fe8d822cbf247dc760cde7cb2a`.
- Every runtime-bearing command used only
  `JIDOKA_RELEASE_RUNTIME_ROOT=/private/tmp/jidoka-code-progressive-production-automation/build/runtime-input/qualified-runtime`.
- The three final aggregate logs contain no `.cleanupFailed`, `.observationTimedOut`, failed
  test summary, timeout, zero-test summary, or malformed invocation.

Retained and investigated failures:

- the first aggregate E2E run failed in S1 because the manifest described the staged runtime
  before final nested ad-hoc signing; the focused S1 pass proves the corrected final identity;
- the next aggregate E2E run, despite the filename `make-test-e2e-pass.log`, failed in S10
  because the harness still required the deleted blind Resume identifier; the focused S10 pass
  proves the corrected rollout contract;
- S11 first rejected `/private/tmp` versus Foundation's standardized `/tmp`, then rejected the
  corresponding Node realpath mismatch; the retained failed artifacts establish both causes and
  the focused S11 pass proves the explicit cross-runtime canonical mapping;
- an acceptance attempt failed after its preflight because sandboxed SwiftPM could not write its
  module cache. A later aggregate attempt exposed a Bash `pipefail` false negative: `grep -q`
  closed a long test-list pipe after finding the suite, so the producer reported broken pipe.
  The harness now uses an in-memory exact substring check, and the full 171-test target passes;
- full-suite concurrency reproduced six `.cleanupFailed` results across `GitProcessTests` and
  `PiRPCProcessTests`. A process-group reuse hypothesis reduced but did not remove the failures,
  so that production change was reverted. A native test-thread diagnostic then produced six
  distinct `.observationTimedOut` results, proving that the asynchronous test executor could be
  starved while the short-lived child existed;
- the final deterministic fixture creates its own session, records its exact Darwin
  `proc_bsdinfo` identity to a create-only mode-`0600` file, closes inherited descriptors, and
  remains alive for cleanup. Both focused process suites and the fresh 721-test aggregate pass.
  `ProcessIdentityTracker.swift` remains byte-identical to the merged baseline;
- every failed and superseded log is retained. The successful full-suite log is evidence of the
  fix, not a substitute for the retained recurrence evidence.

## Reviewer contract and remaining risk

When the protected-child carrier works and model-facing provider use is separately authorized,
route this artifact and the bound worktree read-only to:

- `pi-forge.architecture-reviewer`: one-lane design, production composition, scheduler liveness,
  phase handoff, stop and recovery;
- `pi-forge.security-reviewer`: complete effect gates, task-bound permits, redirect and
  credential boundaries, readback-only exception, privacy;
- `pi-forge.database-reviewer`: all 74 statements, transition and append-only triggers, atomic
  send-start, populated migration and fault cuts;
- `pi-forge.test-reviewer`: call-site exhaustiveness, fault matrix, deterministic acceptance,
  E2E gaps and evidence validity.

Each finding must name severity, current `file:line`, claim, fix, and executable evidence. The
parent must verify it against current source, fix every supported Critical or Major, and rerun
the affected focused checks plus every final gate. A missing reviewer is not zero findings.

The most likely residual defect is one external call path missing the authority composition or
one recovery path gaining liveness by starting a fresh effect. The raw 302-line inventory,
deny-by-default production tests, reservation race tests, readback-only cases, and green local
gates reduce that risk but do not replace the four independent reviews. Max explicitly
authorized publishing the source branch and PR for review; source completion and merge remain
blocked until those reviews complete with zero unresolved Critical or Major findings.
