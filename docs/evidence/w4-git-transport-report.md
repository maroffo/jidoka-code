# W4 repository store and Git transport evidence report

Status: **implemented and locally verified**

Date: 2026-08-06

This report covers only W4. It does not claim production coordinators, Pi workflows, UI, installer, live Keychain access, live GitHub transport, or canary publication. No provider request, real credential access, GitHub request, or remote repository mutation was performed.

## Scope implemented

- app-managed bare mirrors keyed by repository UUID, with canonical repository metadata, private permissions, fixed remote identity, contained temporary paths, fetch validation, and symlink rejection;
- per-job workspaces cloned only from the local mirror, with local `origin`, exact base SHA, locked `agent/issue-<N>-<slug>` branch policy, durable workspace state, terminal-only cleanup authorization, orphan detection, and idempotent interrupted cleanup;
- review fetch of `refs/pull/<N>/head` into a namespaced local ref with exact expected-SHA assertion;
- strict `.gitmodules` inventory for local-relative or canonical public GitHub HTTPS sources, broker-supplied local mirror overrides, private mirror permissions, no recursive network invocation, and explicit nested-submodule escalation;
- bounded `posix_spawn` execution with argv arrays, exact credentialless environment, fixed developer directory, closed environment overrides, output ceilings, monotonic timeout, process-group termination, observed descendant identities, escaped-session cleanup, PID-reuse protection, and hostile-pipe abandonment;
- packaged `JidokaCodeAskPass` executable with one-shot Unix socket capability, nonce, exact remote and prompt binding, private short socket directory, deadline-aware reads, no token argv/file/environment persistence, fixed failure output, and explicit buffer zeroization;
- packaged `JidokaCodePushGuard` pre-push hook with exact remote/ref/SHA binding and strict old-zero advertisement validation before transfer; the ordinary non-force push packet retains server-side old-zero CAS for races after advertisement;
- closed verification registry for make, Swift, Xcode, repository scripts, Git reads, staging, and normal hook-enabled commits, with frozen definition/plan digests, source digest checks, relative cwd containment, safe local Git configuration, output evidence, and exact commit-head/configuration binding;
- workspace import into `refs/jidoka/jobs/<job>/head` with clean-workspace requirement, branch/head/base-ancestry/tree checks, strict UTF-8 changed-file parsing, changed-file allowlist, commit evidence, and post-commit Git configuration revalidation;
- create-only branch publication using an ordinary non-force push protected by the packaged pre-push old-zero guard, packet-trace assertion, exact read-back, and no force-class argument;
- durable branch publication through SQLite mutation intents, with `prepared` before transport work, `sendStarted` immediately before send, send epochs, read-only recovery from unknown sends, and exact `safe retry`, `attributable effect`, or `escalation` settlement;
- packaged helper provenance, Mach-O portability, nested signing, exact bundle inventory, minimum macOS version, and same-team validation for identity-signed app, engine helper, askpass helper, and push guard.

## Executed falsifiers

- branch traversal, extra path components, non-canonical issue numbers, uppercase or shell-metacharacter slugs, malformed SHA, and missing local commit;
- executable and cwd symlinks, mirror replacement by symlink, workspace path collision, orphan preservation, and cleanup before terminal state;
- process timeout, output overflow, child process group, escaped `setsid()` descendant, partial askpass client, wrong nonce, wrong prompt host, unsafe directory mode, and second askpass use;
- token-shaped environment injection, proxy override, invalid protocol override, and changed developer directory;
- malformed, duplicate, hostile, private, nested, and traversal-shaped submodule declarations, plus a missing local mirror;
- arbitrary command id, changed definition digest, changed repository-script digest, absolute Xcode output path, shell executable escape, cwd escape, unsafe Git config, failed hook, and forbidden hook bypass;
- dirty workspace, malformed UTF-8 changed path, changed-file violation, stale commit evidence, mutated Git configuration, and exact head mismatch;
- absent, same-SHA, divergent, raced, failed-send, effect-before-error, unreadable-post-send, concurrent, and repeated publication outcomes, including a fast-forwardable branch created before advertisement and a branch created after advertisement;
- workspace failures at clone, checkout, configuration, validation, and database-record phases, with exact pending/final directory cleanup;
- durable publication restart states `prepared`, `sendStarted`, `reconcileRequired`, `retryAllowed`, and terminal attribution, with zero blind second send.

## Verification

Executed after the final W4 source edit:

```text
make check
make test-e2e
xcrun swift test --sanitize=address
xcrun swift test --sanitize=thread
make jidoka-code-test-s4-preflight
make jidoka-code-test-s5-s7-preflight
make jidoka-code-test-s8-preflight
```

Results:

- strict Swift format, shell checks, Node syntax checks, debug build, release build, XCTest 1 of 1, and Swift Testing 153 of 153 in 30 suites passed;
- the W4-focused matrix passed 36 tests in 9 suites, including repository interruption injection, both publication race windows, and durable publication recovery;
- AddressSanitizer passed XCTest 1 of 1 and all 153 Swift Testing cases;
- ThreadSanitizer passed XCTest 1 of 1 and all 153 Swift Testing cases;
- copied ad-hoc packaged execution from `/`, strict signature verification, exact inventory, normalized binary provenance, runtime runner/policy mutation falsifiers, and cleanup passed;
- the packaged askpass and push-guard helpers have macOS 14 minimum deployment, fail with fixed diagnostics without their capabilities, and are byte-equivalent to the normalized SwiftPM products;
- a real system-Git test proved the previous pre-read plus ordinary-push window could fast-forward a branch created before advertisement, then proved the packaged guard rejects that same race before transfer while the competing ref remains unchanged;
- the packaged S4 preflight passed with Pi `0.84.0`, exact runtime digests, auth-free isolated configuration, bounded timeout and ledger checks, cleanup, and zero provider calls;
- packaged local fixtures S5, S6, and S7 passed through the combined gate: zero credential-helper or SSH invocation, expected-old zero packet observed, race rejected without ref advance, two receive requests, 120 recovery cases, zero second creates, zero success without attribution, and cleanup verified;
- the packaged S8 workflow preflight passed four offline command-profile checks, validated the static 15-role matrix and 15 historical settled ledger records, with no credential access and zero provider calls;
- fresh ignored evidence was written under `build/evidence/jidoka-code-s4.THodHL/`, `build/evidence/jidoka-code-s5-s7.MdH7Ne/`, and `build/evidence/jidoka-code-s8.w29euH/`, with mode `0700/0600` and no credential payload;
- the canonical provider ledger remained byte-identical at SHA-256 `9bb94a32fac85a75a5365ed4578f205eaf7d4a55eeddf114b16c7cf4f3f79bc5`, 19 of 19 settled attempts and one request each;
- no provider, live GitHub, real Keychain, installer, or ServiceManagement side effect was issued.

## Pi compatibility policy

Decision #54 supersedes the initial exact-version runtime policy for future execution. The accepted semantic range is `>=0.84.0 <0.90.0`, but a version is executable only when its exact critical-file digests are present in the packaged allowlist. The allowlist currently contains only Pi `0.84.0`; `0.84.1` and unlisted `0.85` through `0.89` builds remain fail-closed.

The shared policy parser has synthetic lower-bound, exclusive-upper-bound, malformed-version, missing/extra digest, out-of-range build, and in-range-but-unattested falsifiers. Both packaged Pi runners and their shared attestation module are independently digest-pinned by the Swift launchers. Pi `0.84.0` passed S4, S5-S7, and S8 offline preflights without reading the real auth file or issuing a provider request.

## Remaining risks and exclusions

- Production HTTPS Git transport and the one-shot helper were exercised only with local fixtures and the built helper. Real Keychain token retrieval and GitHub authentication remain authorization-gated.
- W4 package execution was ad-hoc signed. The new push guard's Apple Development signing and same-team check are implemented but were not re-executed without authorization for the signing identity.
- No live GitHub branch was created. Checkpoint D still controls capability proof and canary writes.
- Nested submodules are intentionally unsupported in this tranche. Detection escalates after top-level local-only materialization and before any recursive network invocation.
- Repository scripts and hooks are same-user native execution, not a sandbox. W4 removes credentials, bounds processes and output, and validates definitions; W5 must preserve the closed Pi tool boundary.
- Pi `0.84.0` introduced documented breaking RPC changes, including delta-only `message_update` events. Offline command, state, cleanup, and policy contracts pass, but S4/S8 provider response fidelity was not rerun because the authorized provider ledger is exhausted.
- The first post-policy `make check` had two transient local Git fixture failures. Both failed suites then passed in isolation, the complete 153-test suite passed, and a fresh complete `make check` passed. The failed run is not evidence; resource-sensitive Git fixture timing remains the most likely local flake.
- Future Pi versions inside the declared range still require an explicit digest allowlist entry and the same offline gates; the range alone never authorizes execution.
- W5 and W6 must connect the Git store, command evidence, mutation intents, and job state machine into production workflows.
- The provider ledger remains exhausted at 19 of 19. W4 used zero provider calls and no model-based independent review.
