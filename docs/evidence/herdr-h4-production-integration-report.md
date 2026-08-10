# Herdr H4 production integration evidence

Date: 2026-08-10

Base: `origin/main@ec2e17a8f6436dda6619a1165b359fd07fc6cb3e`

Branch: `feat/jidoka-code-herdr-production-integration`

## Result

H4 is complete. Production review, triage, planning and orchestration now share one durable `HerdrPiWorkflowRuntime`. Every logical role is admitted through an exact 1, 4 or 5-role topology and a persistent visible role host. Production composition does not construct the direct Pi RPC process runner and does not fall back to `agent.start`, terminal input, bare `pi`, a private Herdr session or an invisible child agent.

SQLite schema v4 and the associated stores are the authority for repository/workspace bindings, job generations, role hosts, launch attempts, queue sequences, session origins, structured results, acknowledgement, release and approved local commands. Canonical result and command evidence is committed before acknowledgement or replay. Herdr lifecycle, pane state, process exit and terminal output remain telemetry.

Startup imports durable results first, reconstructs and rebinds exact topology from durable intent, recovers command authority, isolates unprovable jobs, and only then permits generic job recovery. Move and rename follow the same terminal/process identity. Subsequent commands use the current rebound workspace, tab and pane rather than stale launch environment. Quit re-proves current exact ownership before closing a pane, so a reused terminal ID or foreign takeover is preserved.

Pause closes topology, Pi launch and approved-command admission before persisting pause, then drains admitted operations and applies runtime pause. A started approved command without accepted evidence becomes irreversible `unknown` and cannot be rerun blindly. Accepted evidence replays only against the exact repository state.

H5 remains separate. It still owns Herdr readiness UI, packaged host inventory and signing, binary/schema attestation, operations documentation and any explicitly authorized default-session canary.

## Implementation surfaces

The exact H4 implementation roster, excluding this report and the living plan, is:

```text
Sources/JidokaCodeCore/Application/EngineService.swift
Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift
Sources/JidokaCodeCore/Git/RepositoryStore.swift
Sources/JidokaCodeCore/Git/VerificationCommandRunner.swift
Sources/JidokaCodeCore/Herdr/HerdrHostRuntime.swift
Sources/JidokaCodeCore/Herdr/HerdrRoleHostRuntime.swift
Sources/JidokaCodeCore/Herdr/HerdrSocketClient.swift
Sources/JidokaCodeCore/Herdr/HerdrTopologyCoordinator.swift
Sources/JidokaCodeCore/Herdr/HerdrTopologyProtocol.swift
Sources/JidokaCodeCore/Jobs/DurableApprovedCommandExecutor.swift
Sources/JidokaCodeCore/Jobs/IssueImplementationJobWorkflow.swift
Sources/JidokaCodeCore/Jobs/IssueTriageJobWorkflow.swift
Sources/JidokaCodeCore/Jobs/JobCoordinator.swift
Sources/JidokaCodeCore/Jobs/PiIssueImplementationExecutors.swift
Sources/JidokaCodeCore/Jobs/PullRequestReviewJobWorkflow.swift
Sources/JidokaCodeCore/Jobs/WorkspaceApprovedCommandExecutor.swift
Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift
Sources/JidokaCodeCore/Pi/PiRPCWorkflowExecutor.swift
Sources/JidokaCodeCore/Pi/PiTUIRuntime.swift
Sources/JidokaCodeCore/Pi/PiWorkflowExecutorFactory.swift
Sources/JidokaCodeCore/Pi/PiWorkflowReplay.swift
Sources/JidokaCodeCore/Pi/PiWorkflowRouters.swift
Sources/JidokaCodeCore/State/ApprovedCommandRunStore.swift
Sources/JidokaCodeCore/State/DatabaseSchema.swift
Sources/JidokaCodeCore/State/PiRunStore.swift
Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift
Sources/JidokaCodeUIFixture/JidokaCodeUIFixtureMain.swift
Tests/JidokaCodeCoreTests/ApprovedCommandRunStoreTests.swift
Tests/JidokaCodeCoreTests/ConfigurationStoreTests.swift
Tests/JidokaCodeCoreTests/DurableApprovedCommandExecutorTests.swift
Tests/JidokaCodeCoreTests/EngineServiceTests.swift
Tests/JidokaCodeCoreTests/HerdrHostRuntimeTests.swift
Tests/JidokaCodeCoreTests/HerdrPiWorkflowRuntimeTests.swift
Tests/JidokaCodeCoreTests/HerdrProtocolTests.swift
Tests/JidokaCodeCoreTests/HerdrRoleHostRuntimeTests.swift
Tests/JidokaCodeCoreTests/HerdrTopologyTests.swift
Tests/JidokaCodeCoreTests/IssueImplementationJobWorkflowTests.swift
Tests/JidokaCodeCoreTests/PiIssueImplementationOrchestratorTests.swift
Tests/JidokaCodeCoreTests/PiRunStoreTests.swift
Tests/JidokaCodeCoreTests/PiTUIRuntimeTests.swift
Tests/JidokaCodeCoreTests/PiWorkflowRouterTests.swift
Tests/JidokaCodeCoreTests/ProductionHerdrCompositionTests.swift
Tests/JidokaCodeCoreTests/VerificationCommandRunnerTests.swift
Tests/JidokaCodeCoreTests/WorkspaceApprovedCommandExecutorTests.swift
scripts/spikes/test-s12-pi-tui.sh
```

These 45 files contain 37,241 lines. Hashing each sorted filename, a NUL separator and its bytes produces aggregate SHA-256 `be8b542934a43c144a8f241e69d8f8356c0523fc82619ce5a0f8f0f1890cecb7`. Applying the same filename-plus-bytes method to every sorted regular file under `Sources` and `Tests` produces `c61a185c980e23e4e9ce17c76b9b5b868974e6e7bf65b286b223e9044e1ab1d9`.

H3 runtime anchors remain unchanged:

- TUI extension: `d7c46bf43840613d932c19db36196f741f783d99f666f3b6e89629feb887a031`
- TUI contract: `3019e69f4e92356b55b8c149a420d2ab9816014a6be670ccd4db6887553d64ac`
- TUI resource manifest: `5392fec5eb544dbe0c721692440e8445604d3c05509a39b450f2bb964245f07f`
- H4 S12 harness: `0ef61482718f413b6870d388b978b93b8d7455776650db45f4d3fad01302cf74`

## Durable authority

- Migration v3 adds repository, job topology, role-host, launch, result, event and topology-intent records, with generation, logical-slot, queue and active-launch uniqueness.
- Migration v4 adds approved-command runs, results and events plus immutable identity, append-only and state-transition triggers.
- An exact digest-bound `released` event requires the matching settled result and acknowledgement. Its trigger updates the launch and run atomically. Direct release without that event is denied.
- `pi_run_session_origins` records the exact first failed or interruption-unknown launch. Same-run resume requires that exact session and causal boundary. Cross-run continuity requires the prior settled boundary.
- Role-host bootstrap, start, queue command, child process and completion evidence is private, create-only, immutable and sequence-bound.
- Approved commands follow `prepared -> started -> resultAccepted`. Startup converts ambiguous `started` records to `unknown`; later generations cannot bypass them.
- Verification and implementation publication evidence binds the exact command plan, artifact, job step, repository state, head and tree before replay or workspace import.

## Topology, recovery and lifecycle evidence

- Job kind deterministically selects one triage host, four review hosts or five planning/orchestration hosts. Activation commits the complete role set or rolls every sibling back.
- Recovery attributes a prepared layout by exact durable intent, socket identity, opaque tab ID, ordered pane IDs, split structure, command, working directory and environment. Mutable or duplicate labels are ignored.
- Partial live and startup activation matrices cover every failure index for exact 1, 4 and 5-role layouts, including a renamed owned tab and a foreign duplicate label.
- Persistent hosts consume one contiguous create-only queue. Durable `.enqueued` state precedes command publication; recovery republishes only an exact missing command.
- A moved persistent terminal executes the next logical round against the rebound workspace, tab and pane without another host launch.
- Socket replacement imports exact results, shuts down still-owned old hosts, retains `SOCKET_CHANGED` history and advances topology generation.
- Pause closes admission before durable pause and waits for admitted commands and results. The live pause test settles and releases the in-flight run, then suppresses round two.
- Quit and rollback require exact current PID/start identity, generation, repository/socket/version/protocol, unique terminal and role-host argv. Foreign takeover and terminal-ID reuse fail closed.
- All four production workflow adapters fail closed on Herdr handshake failure with zero Pi run, zero host command and no direct-RPC fallback.

## Verification after the final source edit

- `make check`: toolchain verification, ShellCheck, Node syntax and contract tests, strict Swift format, debug/release builds and 434 tests in 70 suites passed.
- `make test-e2e`: S1 package, S10 UI, S11 isolated Herdr and S12 isolated exact Pi TUI passed. S10 reported `keychain:0,network:0,provider:0,service_management:0`; S11 reported `default_socket_contacts=0`; S12 reported `provider_network=0`.
- AddressSanitizer: all 434 tests in 70 suites passed with no sanitizer finding.
- ThreadSanitizer: all 434 tests in 70 suites passed with no data-race finding.
- S10 teardown regression: five consecutive isolated runs passed with the three unchanged screenshot digests after screenshot views were separated from subsequently mutated alert models.
- Final strict Swift format and `git diff --check` are rerun again before staging.

Evidence logs and SHA-256:

- `/tmp/jidoka-h4-make-check-final-7.log`: `0097059fe8372745413b3467309185216662fd221dd373cb069fdc6d382a6dd9`
- `/tmp/jidoka-h4-test-e2e-final-7.log`: `e96991f074d7540218bc78cbf59820065df375a655e494b4ad6de4e6957768dd`
- `/tmp/jidoka-h4-asan-final-5.log`: `2e4c8dceebe4dc80d749be55fd3aca9429f559b7feee76b82e8c1f9bd15affeb`
- `/tmp/jidoka-h4-tsan-final-4.log`: `b1d5e6c439f558045e20d7f3e1d91635120b3cd9f6294c6861b95c4749e743c2`
- `/tmp/jidoka-h4-s10-snapshot-repeat-1.log`: `63bccf2575b6eb6c943a246c3fe239de0d00f6aa2c00833ddd5a2d2cf7bd12d8`
- `/tmp/jidoka-h4-review-blockers-focused-1.log`: `953ca1fc2556f36c5ab6eed88a6af4b287fcb6fcfe7bf0babeb4822d37308d95`

## Independent review

Read-only, network-disabled closure reviews inspected the current H4 source, schema and focused executable evidence:

- Architecture: 100/100, no Critical or Major findings. It verified durable intent attribution, opaque-ID and label-independent recovery, structural launch matching and per-job failure isolation.
- Security: 100/100 in the targeted closure scope, no Critical or Major findings. It verified exact ownership before cleanup, rebound host command identity, attributed rollback, pause/start gates and durable settlement authority.
- Database: 100/100, no Critical, Major or Minor findings. It verified trigger-owned release, append-only session origin, settlement coupling, resume lineage and approved-command start authority.
- Test: 96/100 and attested for blocker closure, no Critical or Major H4 blocker. It verified the migration regressions, moved-host second round, foreign-pane preservation, live pause/result settlement, partial topology matrices and four-workflow fail-closed behavior. The parent subsequently completed the repository-wide full suite and both sanitizer suites.
- Final test delta: ACCEPTABLE, no Critical, Major or Minor finding. A fresh artifact-only reviewer verified that the sanitizer allowances do not weaken production authority and that immutable screenshot models preserve rendered evidence while removing the observed hidden-window alert race.

Review artifact SHA-256:

- `/tmp/jidoka-h4-architecture-label-closure.md`: `64243f4b393f96b65c6b29c092ee80a8f93db0ecec38973feff006e94418f310`
- `/tmp/jidoka-h4-security-targeted-closure.md`: `007c028276b79afeeda0e236d21904a31c664597efba36684ad94f34b20e1002`
- `/tmp/jidoka-h4-database-final-closure.md`: `3ef39b082b8f9ad998108a95e1f37dc59587e976e0a773c073cc5b406abfccf6`
- `/tmp/jidoka-h4-test-targeted-rereview.md`: `e0aeb7686ec0d3a602602520cdf34de915e664c5f052a4423575bf07ca70fc0d`
- `/tmp/jidoka-h4-final-delta-test-review.md`: `b19f09cb332bb9b675d3e243cfc581910d7aee7da1aba41dcefe9a8c7286b4a2`

## Side-effect boundary and residual risk

Automatic tests used fake APIs or named temporary Herdr sessions and did not contact the real default Herdr socket. They did not invoke a live provider, access real Keychain credentials, mutate GitHub, register ServiceManagement, install software or alter global Herdr configuration. Temporary sessions were removed before PASS.

A fresh E2E attempt exposed a pre-existing AppKit/SwiftUI crash when an offscreen screenshot view remained subscribed to later `.alert` mutations. The fixture now renders onboarding and menu screenshots from immutable snapshot view models. Five consecutive S10 runs and the final complete E2E passed with unchanged screenshot digests.

Not verified in H4:

- a default-session production canary or live provider request;
- Herdr binary/schema attestation beyond the fixed version/protocol handshake;
- packaged host inventory, nested signing and installation behavior;
- readiness and operations UI/documentation;
- protection against a malicious process running as the same user.

Those are H5 or explicitly out of scope. The principal future risk is protocol or ownership drift across a Herdr upgrade; production remains fail-closed on version, protocol, socket or exact identity mismatch.
