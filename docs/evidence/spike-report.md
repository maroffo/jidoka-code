# W1 packaged-context spike report

Status: **complete, S1-S9 pass, Checkpoint B accepted**

Date: 2026-08-06

This report records executed evidence. The project owner accepted Checkpoint B in-session on 2026-08-06. Acceptance unblocks W2 but does not start its implementation or authorize a commit or push.

## Authorization envelope

The project owner authorized the local lifecycle and Keychain probes, one temporary synthetic Keychain item, a local Hikma Apple Development identity, the fresh temporary signed identities `com.maroffo.JidokaCode.SignedProbe` and `com.maroffo.JidokaCode.SignedEngineProbe`, and at most 19 no-retry model calls to `openai-codex/gpt-5.6-sol:max` for S4/S8 using public workflows and synthetic fixtures.

The provider ledger reached exactly **19 of 19** calls:

- S4 profiles: 4 calls;
- S8 PR review and synthesis: 4 calls;
- S8 triage: 1 call;
- S8 planning fleet: 5 calls;
- S8 orchestration fleet: 5 calls.

Every ledger attempt is `settled`, has `providerRequestCount: 1`, records provider/model/usage, and has no retry. Aggregate measured usage was 19,550 input tokens, 8,038 output tokens, 27,588 total tokens, and USD 0.33889 in provider metadata.

No real GitHub token, GitHub write, external Git remote, installer execution, merge, login/logout, source-repository commit, or external push was performed. S5/S6 intentionally created temporary commits and loopback pushes inside disposable local fixtures; those fixtures were deleted.

## Environment

- macOS 26.5.2;
- Xcode 26.6, build 17F113;
- macOS SDK 26.5;
- Swift 6.3.3;
- Pi 0.83.0;
- Node 26.6.0;
- Git 2.50.1, Apple Git-155;
- per-process developer directory `/Applications/Xcode.app/Contents/Developer`;
- global developer selection unchanged.

## Executed command and evidence matrix

The exact reviewed paths, SHA-256 values, safe aggregate facts, signing modes, and rerun policy are recorded in the versionable redacted manifest `docs/evidence/w1-evidence-manifest.json`. Detailed transcripts remain local under ignored `build/evidence/` paths. The manifest makes their reviewed identity durable without publishing machine-specific transcripts or synthetic provider output.

| Spike | Accepted command and setup | Signing | Provider calls | Rerun policy |
|---|---|---:|---:|---|
| S1 | `make test-e2e` | ad-hoc | 0 | offline rerun allowed |
| S2 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s2-lifecycle.sh` in the authorized fresh-identifier probe copy | Apple Development | 0 | requires fresh authorized identifiers |
| S3 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s3-keychain.sh` in the same fresh-identifier probe copy | Apple Development | 0 | requires fresh identifiers and Keychain fixture authorization |
| S4 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s4-pi.sh` | Apple Development | 4 | **do not rerun: provider authorization exhausted** |
| S5-S7 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s5-s7-local.sh` | Apple Development | 0 | local rerun requires explicit signing identity |
| S8 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s8-workflows.sh` | Apple Development | 15 | **do not rerun: provider authorization exhausted** |
| S9 | `SIGN_IDENTITY=<authorized-apple-development-sha1> ./scripts/spikes/test-s9-topology.sh` | Apple Development | 0 | local rerun requires explicit signing identity |

Output retained in the manifest is redacted to results, counts, signing mode, artifact path, and digest. Provider payloads, Keychain values, authentication material, and signing identity SHA-1 are not included.

## S1, package and resource loading

Result: **PASS**

Executed gates included `make check`, `make test-e2e`, package creation, `plutil`, `codesign --verify --strict --deep`, exact inventory checks, and packaged execution from `/`.

Evidence proves:

- Swift 6 debug/release builds, XCTest, and Swift Testing;
- app and helper minimum macOS 14;
- exact bundle inventory and regular-file allowlist;
- helper-before-app signing and shared TeamIdentifier when Apple Development signed;
- Mach-O dependency and rpath allowlists;
- no checkout or Xcode path embedded in the bundle;
- exact resource SHA-256 values;
- manifest and packaged-runner mutation detection;
- malformed, oversized, missing, and symlinked resource failures;
- bounded cleanup guards.

Evidence: `build/evidence/w1-checkpoint-b-review/s1-test-e2e.log`, SHA-256 recorded in `docs/evidence/w1-evidence-manifest.json`.

## S2, lifecycle

Result: **PASS for the signed helper; monolith rejected**

The in-process monolith completed direct `EngineClient` round trips but did not restart within 30 seconds after SIGKILL. It failed the mandatory crash-restart threshold.

The LaunchAgent helper passed, under the fresh Apple Development identities:

- `SMAppService` enabled status;
- exactly one helper process;
- 100 ordered XPC round trips with no duplicate IDs;
- nonzero crash and restart within 30 seconds;
- reconciliation as the first event after launch and restart;
- graceful exit without a crash loop;
- on-demand reopen;
- generation 1 to 2 update, re-sign, unregister, re-register, and restart;
- exact unregister and cleanup.

Ad-hoc update behavior was independently falsified by AMFI `OS_REASON_CODESIGNING | Launch Constraint Violation`. No Background Task Management reset, logout, or reboot was used. Apple Development signing with one stable team satisfied the signing gate.

Evidence: `build/evidence/signed-hikma-fresh-probe/s2/summary.json`.

## S3, Keychain and credential boundary

Result: **PASS**

The harness created only the fixed temporary generic-password fixture. Synthetic values entered through stdin, never argv or environment. ACL trust was restricted to the exact app and helper. Evidence retained only SHA-256.

The signed run proved app read/replace, helper XPC read without a prompt, exact deletion, and cleanup. A prior falsifier showed that Pi RPC `bash` still executes under `--no-tools`; therefore the package includes a SHA-pinned `user_bash` blocker that returns exit 126 before spawn. The accepted run required the blocker marker, zero provider calls, and process-group cleanup.

Evidence: `build/evidence/signed-hikma-fresh-probe/s3/summary.json`.

## S4, packaged Pi RPC profiles

Result: **PASS, 4 provider calls**

The signed packaged app launched a digest-pinned runner, exact Node and Pi 0.83.0, one packaged skill per profile, and two packaged extensions. The app exposed only a closed `--pi-probe` command. Arbitrary argv was rejected.

Before live execution, local falsifiers proved:

- exact resource and system-runtime digests;
- exact `get_commands` inventory;
- direct RPC Bash denial before spawn;
- timeout abort and process-group cleanup;
- duplicate attempt and duplicate fixture rejection;
- concurrent ledger-lock rejection;
- hard cap 19;
- isolated `PI_CODING_AGENT_DIR` containing only `openai-codex` authentication;
- workflow retry zero and provider retry zero;
- compaction disabled;
- strict no-tools JSON output;
- a simulated second provider request exits with status 86 before reaching the provider.

A critical falsifier found that Codex `transport: auto` can attempt WebSocket and then SSE behind one `before_provider_request` event. The accepted run therefore pins `transport: sse` and the reviewed Pi SDK/Codex implementation digests. With provider `maxRetries: 0`, that path performs one network request per reservation.

All review, triage, planning, and orchestration profile fixtures returned one schema-valid result, one `agent_settled`, expected verdict/invariant, empty stderr, and cleanup.

Evidence: `build/evidence/jidoka-code-s4.G1gnat/`.

## S5, composed Git security

Result: **PASS**

The Apple Development signed app ran the fixture with a sanitized environment while the real host context had one redacted global `insteadOf` entry and an active SSH agent.

The fixture proved:

- malicious credential-helper configuration detected but never invoked;
- `insteadOf`, remote URL, and `core.sshCommand` detected but never followed;
- fake SSH endpoint invocation count zero;
- Pi direct remote command blocked by the packaged Bash extension;
- remote receive count zero for Pi;
- a tracked pre-commit hook blocked commit without `--no-verify`;
- local submodule URL classified locally;
- network submodule URL escalated without access;
- synthetic credential absent from artifacts and argv;
- app-owned workspace cleanup.

Evidence: `build/evidence/jidoka-code-s5-s7.vf3Zv9/s5-security.json`.

## S6, authenticated local Git transport

Result: **PASS**

A loopback smart-HTTP Git server required Basic authentication. The token reached five one-shot askpass invocations through inherited file descriptor 3, not argv, environment, or a regular file. All read-backs were authenticated.

The fixture proved:

- exact branch creation and exact SHA read-back;
- same SHA classified as `attributable effect`;
- divergent SHA classified as `escalation`;
- no force-class argument;
- packet trace showed expected-old all-zero SHA for create;
- a fixture actor created the branch at base SHA after advertisement and before receive;
- the zero-old CAS command was rejected;
- the raced ref remained at base SHA and never advanced;
- exactly two receive requests, one accepted create and one rejected race;
- token sentinel absent from artifacts and argv.

This satisfies the create-only atomicity requirement without `--force`, `--force-with-lease`, or equivalent force-class semantics.

Evidence: `build/evidence/jidoka-code-s5-s7.vf3Zv9/s6-git-transport.json`.

## S7, mutation recovery

Result: **PASS**

A stateful fake GitHub fixture executed 10 mutation operations across 6 crash windows and 2 visibility scenarios, 120 cases total. It used the read schedule 1, 2, 5, 10, and 30 seconds, plus visibility at 31 seconds.

Observed classifications:

- 56 `safe retry`;
- 40 `attributable effect`;
- 24 `escalation`.

There were zero second create attempts and zero successes without attribution. Unknown marker-comment and PR creates absent through 30 seconds escalated and suppressed rediscovery. Twenty-four later read-only checks attributed effects visible at 31 seconds without recreating them.

Evidence: `build/evidence/jidoka-code-s5-s7.vf3Zv9/s7-mutation-recovery.json`.

## S8, workflow fidelity

Result: **PASS, 15 provider calls**

The signed packaged app ran 15 fresh Pi sessions with no tools, SSE transport, both retry layers zero, exact runtime/resource digests, direct Bash denial, and one durable ledger reservation per request.

Matrix:

- PR review: architecture, security, test, synthesis;
- issue triage: one authoritative triage role;
- planning: writer, architecture, security, test, synthesis;
- orchestration: writer, architecture, security, test, synthesis.

Every role returned the exact workflow/role/fixture schema, expected verdict and severity, aligned precondition/action/postcondition evidence, one `agent_settled`, zero tool executions, one provider request, usage, empty stderr, and cleanup. Synthesis received only schema-validated synthetic role results. The run produced 29 invariant-evidence mappings covering 18 unique invariants.

Notable enforced outcomes include untrusted PR instructions blocked, domain labels preserved, hard risk human-owned, unknown/disagreement at least complex, complex work requiring `plan:approved`, one writer and frozen plan digest, credentialless never-merge, hooks and verification gates retained, and failed gates never lowered.

Evidence: `build/evidence/jidoka-code-s8.JHFouK/`.

## S9, topology decision

Result: **PASS, helper selected**

Locked decision 53 supersedes provisional decision 35. The LaunchAgent helper is selected because it is the only topology that met lifecycle, signing, Keychain, IPC, Pi, and composed-security thresholds. The monolith failed crash restart and was not retained by preference.

The monolith probe source and normal-launch execution were removed. The final signed bundle contains the selected helper and service declaration, contains no monolith probe strings, and starts normally without producing monolith evidence.

An initial S9 cleanup assertion followed only the launcher PID and was falsified by three reparented exact app processes. Those exact probe processes were terminated, the harness was changed to enumerate the full executable path, use the acknowledged graceful-quit command, and require an exact zero-process postcondition. Both ad-hoc and Apple Development runs then passed with no surviving app process.

Decision: `docs/evidence/topology-decision.json`.

Evidence: `build/evidence/jidoka-code-s9.0LSqRD/`. Its decision snapshot is byte-identical to the current `docs/evidence/topology-decision.json`; both have SHA-256 `5d86cdc21d6f10c5a633eaf49c8a4f50acd1b2ba177f9d9d5ceaa53f6365625f`.

## Cleanup and remaining effects

Verified absent after accepted runs:

- temporary Keychain item;
- original and fresh signed probe jobs;
- probe app under user Applications;
- probe app/helper and Pi processes;
- S2/S3 locks and temporary source copy;
- S4/S8 Pi workspaces and authentication copies;
- S5-S7 repositories, loopback server processes, askpass state, hooks, and token sentinel;
- S9 normal-launch process and temporary home.

The local Apple Development certificate/private key remains intentionally in the login Keychain. The canonical provider ledger remains intentionally at Application Support with 19 non-secret accounting records and no lock. Detailed generated evidence remains under ignored `build/evidence/` paths; its redacted identity and aggregate results are durable in `docs/evidence/w1-evidence-manifest.json`.

No GitHub mutation, external Git publication, installer execution, merge, source-repository commit, or external push occurred. Disposable S5/S6 fixtures performed local commits and loopback pushes only, then were removed.

## Residual risks

- W1 used temporary probe identities. Production identifiers and login registration UX remain W9 work.
- Notarization and distribution remain outside W1.
- The W1 local spike runners are evidence harnesses, not the W2 production engine.
- Production persistence, scheduler, broker, UI, installer, and live GitHub canary remain unimplemented and gated.
- The provider-call authorization is exhausted at 19 of 19. Any further real provider run requires new explicit authorization.

## Checkpoint B

**Accepted by the project owner in-session on 2026-08-06.** S1-S9 are executable-pass with no omitted category. W2 is unblocked but has not started; implementation, commit, and push require their own explicit instruction or authorization.
