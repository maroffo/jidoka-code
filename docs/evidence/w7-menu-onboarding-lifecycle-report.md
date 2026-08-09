# W7 menu bar, onboarding, and lifecycle evidence report

Status: **implemented and locally verified within the fake-first W7 scope**

Date: 2026-08-09

This report covers W7 only. It does not claim an installed Apple Development signed lifecycle, a real ServiceManagement transition, runtime VoiceOver enumeration, live Keychain or GitHub access, provider-backed Pi quality, installer behavior, or production deployment. Verification used injected Keychain, GitHub, Pi, and ServiceManagement fakes, temporary SQLite stores, an ad-hoc signed package fixture, and a sandboxed UI fixture. No provider request, real credential access, GitHub request, remote mutation, ServiceManagement registration, commit, push, merge, or package installation was performed.

## Baseline and scope

W7 was implemented in the dedicated branch and worktree `feat/jidoka-code-w7-menu-onboarding-lifecycle` from merge-base `bec66293350fb5813923677bd1604b5c806c64a9`, the merge of W6 PR #8.

Implemented surfaces:

- a production `EngineClient` async contract with immutable `Sendable` snapshots, closed commands, protocol version 1, request identity, command-kind validation, and byte-bounded XPC envelopes;
- the selected LaunchAgent helper topology with production engine composition, startup recovery before dispatch, scheduler lifecycle triggers, XPC request handling, same-user peer checks, exact executable-path checks, and designated-signing-requirement validation;
- a bootstrap control plane that keeps the UI available while ServiceManagement is disabled or requires approval, checkpoints before topology transitions, rolls registration failures back, and hands off to the helper only after durable preparation;
- one production engine lock shared by helper and local bootstrap, plus a UI single-instance lock that activates the existing app and terminates the second UI instance without unloading unrelated processes;
- `MenuBarExtra` status for active, paused, running, and warning states, concise activity, poll, pause or resume, settings, redacted logs, ambiguous evidence controls, and durable quit;
- `@Observable @MainActor` app, onboarding, and settings view models that depend only on `EngineClient`; SwiftUI views do not import or access SQLite, Keychain, GitHub, Git, or Pi adapters;
- strict onboarding for automation coexistence disclosure, Pi preflight, credential validation and import, provider and source disclosure, repository validation and toggles, and login registration at final completion;
- settings for repositories, four model profiles, maximum concurrency, login item state, credential replacement and deletion, and redacted diagnostics;
- exact ambiguous-mutation presentation with only read-only late recheck or a confirmation-bound `Authorize Retry` using the current repository, object, revision, generation, operation, evidence, and snapshot digest;
- durable pause semantics that close discovery and new lease admission while preserving reconciliation, cleanup, exact retry promotion, and already in-flight work;
- durable quit and handoff receipts backed by explicit SQLite WAL checkpointing, without unregistering the login item on normal quit;
- configuration schema 2 migration with pre-migration backup, four default model profiles, onboarding and login state, provider disclosure invalidation on profile change, and no persisted token bytes;
- crash-safe credential replacement and deletion journals. Replacement records only the expected old account, new account, phase, and exact SHA-256 of the pending replacement value; startup converges every persisted boundary without a blind second mutation;
- a closed-vocabulary redacted engine log with private owner and type checks, `0700` directory, `0600` files, symlink rejection, fixed filenames, and bounded rotation;
- a separate `JidokaCodeUIFixture` executable and S10 harness. Production code has no test flag or fake-adapter backdoor.

## Lifecycle and security falsifiers

Permanent tests cover these W7 failure classes:

1. pausing persists before scheduler policy changes, lets an in-flight pass finish, and suppresses discovery and new dispatch while recovery remains eligible;
2. credential removal, profile changes, and incomplete onboarding durably close dispatch;
3. exact retry authorization fails when repository, object, revision, generation, operation, evidence, or snapshot digest changes;
4. the ambiguous UI exposes only late recheck and exact authorization, never Abort or global retry;
5. quit and every app termination path await one shared durable checkpoint gate before termination reply;
6. login registration is attempted only after every onboarding prerequisite, with checkpoint before registration and helper handoff;
7. registration failure or post-registration helper failure returns to bootstrap and performs the bounded rollback in the tested order;
8. disabling login checkpoints the helper before unregistering and does not change persisted state on failed topology mutation;
9. XPC rejects wrong UID, PID, executable path, signing identity, protocol version, request identity, response identity, command kind, malformed archive, and oversized message;
10. one engine and one UI owner hold their private locks; later owners can start only after release;
11. configuration migration preserves W6 rows, writes a readable backup, creates W7 defaults, and rejects credential-shaped schema values;
12. credential replacement and deletion converge across every durable crash boundary without storing or logging a token;
13. redacted logs reject symlinks, non-private directories, arbitrary filenames, and secret sentinels while preserving bounded rotation;
14. provider disclosure is revoked when any configured provider or model profile changes;
15. menu, onboarding, settings, pause, ambiguous evidence, and quit flows run against fakes with zero Keychain, network, provider, or ServiceManagement calls.

The excluded same-user threat model remains unchanged: a hostile same-user filesystem racer and an unobserved child that immediately escapes through `setsid()`.

## Independent review

Three bounded architecture, security, and test review and fix cycles were completed with read-only reviewers. Findings reproduced against source included non-atomic pause admission, recovery suppression, unsafe topology rollback, termination paths outside the checkpoint gate, incomplete XPC peer validation, credential replacement crash ambiguity, provider-consent drift, path and log boundary weaknesses, missing wake and network triggers, and false-green UI evidence. Source and permanent tests were changed for each material in-scope finding.

The final test review rated the revised coverage **94/100, READY**. The last architecture artifact rated its pre-fix revision **85/100, NOT READY** because `pending_replacement_digest` was still a credential-shaped schema name. It is now `pending_replacement_sha256`, and the final source contract and migration tests pass. The last security artifact rated its revision **72/100, NOT READY**, with remaining confidence tied to the renamed schema field, best-effort in-memory token lifetime, and authorization-gated installed signing, XPC, Keychain, and ServiceManagement canaries. A fourth independent review was not run because W7's three-cycle budget was exhausted. This report therefore does not claim an independent final READY verdict; executable final-source evidence is reported separately below.

## Sandboxed UI flow evidence

`./scripts/spikes/test-s10-ui.sh` builds and ad-hoc signs a dedicated fixture app, launches the real production SwiftUI views with injected fakes under a deny-network sandbox, executes invalid and valid onboarding inputs, pause and resume, ambiguous late recheck, exact retry authorization, and durable quit, then scans generated evidence for secret sentinels and forbidden side effects.

Observed flow facts:

```text
invalidCredentialRejected=true
invalidRepositoryRejected=true
tokenFieldCleared=true
pausePreservedInFlight=true
ambiguousLateRecheckCount=1
ambiguousAuthorizationCount=1
quitCheckpointed=true
keychainCalls=0
networkCalls=0
piProviderCalls=0
serviceManagementCalls=0
```

The report declares 22 production accessibility identifiers and 23 labels for the rendered controls. The offscreen `NSHostingView` fixture exposed only its host accessibility label and did not enumerate SwiftUI child identifiers. Accessibility evidence is therefore explicit rather than inferred: source-level identifier and label contracts, unit tests for stable secret-free identifiers and user-facing errors, keyboard shortcuts in production views, and full-size rendered screenshots including enlarged accessibility text. Runtime child identifier enumeration and a foreground VoiceOver pass remain an installed-app canary.

Screenshot evidence:

```text
80b7616cd4ce5ff33df669fed841300643ed1970a97aa8f6d1f4c9fc3844a146  build/w7-ui-flow/evidence/onboarding-first-run.png       1440x2600
900f4399e2f671a4a37d190a783d75cf4cb44dec655aab555fac20d5dab5ac11  build/w7-ui-flow/evidence/settings-accessibility-type.png  1800x3600
5d426b39ce14ef72b7a4a3b3b61f1a1926f2e8a9cd6952cc545775e07fd60aa3  build/w7-ui-flow/evidence/menu-warning.png               1040x1240
```

Machine-readable evidence is at `build/w7-ui-flow/evidence/ui-flow-report.json`.

## Final local verification

The complete `Sources` and `Tests` content hash after the final source edit was:

```text
f7710d9cd6ee5fb5ca1029a09590ce8a121bc7f51b49a3e9c68c41d946904697
```

Fresh commands on that source revision:

```text
make jidoka-code-w7-acceptance
make test-e2e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --sanitize=address
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --sanitize=thread
git diff --check
```

Observed results:

- `make jidoka-code-w7-acceptance` passed toolchain verification, shellcheck, Node syntax and contract suites, strict Swift format, debug and release Swift 6 builds, **344 tests in 60 suites**, and the sandboxed S10 UI flow;
- `make test-e2e` passed the S1 ad-hoc package and copied-execution preflight plus S10 after the final CLI source edit. This closed a caught regression where packaged closed-command failures no longer emitted their structured enum diagnostics;
- AddressSanitizer and ThreadSanitizer each passed **344 tests in 60 suites** after the final source edit;
- `git diff --check` passed;
- the final S10 report recorded `keychain:0`, `network:0`, `provider:0`, and `service_management:0`.

## Remaining risks and exclusions

- The production LaunchAgent, XPC signing requirement, activation handoff, intentional exit behavior, and `SMAppService` approval state compile and are fake-tested, but were not installed or exercised with the Apple Development identity. Reusing W1's old authorization would change payload and target bytes, so a new explicit canary authorization is required.
- The UI fixture proves rendered layout, enlarged text, declared accessibility contracts, keyboard actions, and secret-free evidence. It does not prove runtime SwiftUI child accessibility identifiers or an end-user VoiceOver flow in an installed foreground app.
- Swift `String` and framework internals do not provide deterministic zeroization. Token fields and command payloads are cleared at bounded application points and never persisted or logged, but best-effort in-memory lifetime remains.
- No live Keychain item, GitHub request, provider-backed Pi session, remote branch, issue, label, comment, PR, ServiceManagement registration, package installation, or Apple Development signing occurred.
- Package E2E remains ad-hoc and W8 installer work is open. W9 supervised canaries and final package review are also open.
- The most likely later integration failure is a signed installed helper being rejected by the exact designated-requirement or ServiceManagement approval path despite the fake topology tests. The second most likely is runtime accessibility exposure differing from the explicit SwiftUI contract.
