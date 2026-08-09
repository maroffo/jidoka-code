# Herdr H2 topology and synthetic host evidence

Date: 2026-08-09

Base: `origin/main@282e849bdb4fdf573a1cf4f9bddb35c6fffebeed`

Branch: `feat/jidoka-code-herdr-runtime`

## Result

H2 is complete. Jidoka Code now has a typed, closed Herdr topology coordinator and an exact-path synthetic host boundary. Production job composition remains unchanged until H4, and the child remains a synthetic fixture until the H3 Pi parity gate.

The coordinator adopts only one exact repository workspace, otherwise prepares a workspace intent before create. It prepares a second intent before `layout.apply`, preserves focus, serializes topology mutation per repository across jobs and generations, and never blindly retries a response-lost mutation. Attribution requires exact pre/post snapshots and, for a tab, exact `layout.export` evidence. Move and rename follow stable terminal identity plus Jidoka run metadata; a missing terminal becomes `bindingLost`.

Every post-handshake request pins the attested socket device/inode before connect and write. The host is launched only through a raw argv array. Its run descriptor is private, create-only and SHA-256 bound; incomplete preparation rolls back descriptor, digest and run directory before the run ID can be reused. The host proves its own pane from a fresh snapshot, publishes custom lifecycle without `agent_session`, launches only the descriptor child argv/cwd/environment, strips every `HERDR_*` and secret-shaped key, publishes `blocked` on launch or nonzero failure, and treats lifecycle-report failure as an explicit Herdr transaction failure.

S11 uses an attached TUI in a named throwaway Herdr session because a named headless server reports `detached_server_daemon=false`. It creates a real no-focus workspace, applies and exports a right split, launches independent plan and review hosts, observes both terminals read-only, verifies both authoritative Herdr visible screens, waits for both custom agents, checks the absence of native session references and child Herdr capabilities, checks unchanged focus and closed settled panes, then verifies session/socket/directory deletion before printing PASS. It never targets the default socket.

## Changed surfaces

- `Package.swift`
- `Makefile`
- `Sources/JidokaCodeCore/Herdr/HerdrProtocol.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrSocketClient.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrTopologyProtocol.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrTopologyCoordinator.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrHostRuntime.swift`
- `Sources/JidokaCodeHerdrHost/main.swift`
- `Sources/JidokaCodeHerdrFixture/main.swift`
- `Tests/JidokaCodeCoreTests/HerdrFakeSocket.swift`
- `Tests/JidokaCodeCoreTests/HerdrProtocolTests.swift`
- `Tests/JidokaCodeCoreTests/HerdrTopologyTests.swift`
- `Tests/JidokaCodeCoreTests/HerdrHostRuntimeTests.swift`
- `scripts/spikes/herdr-s11-fixture.mjs`
- `scripts/spikes/test-s11-herdr.sh`
- `docs/plans/active/2026-08-05_jidoka-code-macos-app.md`
- `docs/plans/active/2026-08-09_jidoka-code-herdr-runtime.md`

The 11 Herdr source and test files contain 4,933 lines. Their aggregate SHA-256 is `f40ba34e2352b65c398fa64ba3d6f93d3fa41d3c51d3b1ac4c9bd64f1ae292d9`. The aggregate `Sources` plus `Tests` SHA-256 after the final source edit is `4a371f2c279976738a7e83f9444d113dcc0c56d1d3c57cf912c68402a4cece5b`. The two S11 files aggregate to `63fbabf1f1d5a4b9df0133ad5eca0a547c236f15b915f574997af567b9befaae`.

## Verification after the final source edit

- Focused Herdr suite: 26 tests in 3 suites passed.
- Five consecutive final two-role S11 runs passed with stop-on-first-failure; a final session-list check found no `jidoka-s11-*` session.
- `make check`: 370 tests in 63 suites passed in 76.266 seconds, including strict Swift format, debug/release builds, ShellCheck and Node syntax/contract checks.
- `make test-e2e`: S1 package E2E, S10 UI and the final two-role S11 all passed. S10 remained `keychain:0,network:0,provider:0,service_management:0`.
- `xcrun swift test --sanitize=address --filter Herdr`: 26 tests passed.
- `xcrun swift test --sanitize=thread --filter Herdr`: 26 tests passed.
- Final `git diff --check`, strict `swift-format`, ShellCheck and Node syntax checks passed.
- No temporary named Herdr session, host/fixture/observer process or Pi lock remained.

Evidence logs and SHA-256:

- `/tmp/jidoka-herdr-h2-make-check.log`: `7e10b37ce9568d509792131390107dddaf4aebc79dc93ddcc7cbc91b617d32e9`
- `/tmp/jidoka-herdr-h2-e2e.log`: `b4c52a64a3f2d641a6a2e428337242cac658a8f4a3fe3aeac183f56c3df35aa1`
- `/tmp/jidoka-herdr-h2-asan.log`: `18d30b19102763339d0868ef39462c9ae48b466d1e0fb1d73a204dfe5e9873b2`
- `/tmp/jidoka-herdr-h2-tsan.log`: `96b65583f1b7fa45e69be42ba77d001720ac9a5492eda0f999123498c99c32d5`

## Independent review

Two fresh architecture/security/test rounds ran as visible top-level Pi agents in the global Herdr session. They were read-only and made no source edits.

Round 1 found cross-request socket identity drift, insufficient repository mutation serialization, cleanup that could pass with a leaked named session, historical ANSI matching, and incomplete request-schema assertions. The system exchanger now rejects a changed socket before connect/write, a process-wide gate serializes one repository topology mutation, cleanup postconditions precede PASS, Herdr's authoritative visible screen is used for content evidence, and both unit and real protocol schemas are checked. Architecture and security reported `FIX VERIFIED`; test reported `FIXES VERIFIED`.

Round 2 architecture and security reported no Critical or Major findings. Test review found partial descriptor poisoning, missing blocked lifecycle on launch failure, single-role S11 coverage, and an incomplete custom terminal emulator. Descriptor rollback and lifecycle failure tests were added; S11 became a real two-role split; the custom screen emulator was removed in favor of Herdr's authoritative `pane read --source visible`. The reviewer reported `FIXES VERIFIED`. All reviewer Pi processes exited.

## Side-effect boundary and residual risk

Automatic Herdr mutation used only named temporary sessions with explicit named sockets. No automatic command targeted the default Herdr socket, changed global Herdr configuration, installed or updated Herdr, invoked a provider, accessed real Keychain credentials, mutated GitHub, registered ServiceManagement or installed a package. The pre-existing global H0 review workspace/tab and foreign terminals were not changed by S11.

Not verified in H2:

- exact packaged Pi/Node/resources/model/tool parity and structured result settlement;
- keeping or resuming a completed Pi TUI pane under Jidoka recovery authority;
- SQLite-backed topology intent, run ownership, event replay and production composition;
- package inclusion/signing, readiness UI, binary/schema attestation and operations documentation;
- an explicitly authorized canary through the default Herdr session;
- protection against a malicious process running as the same user.

These remain H3-H5 gates. Herdr lifecycle and terminal output are telemetry only and cannot complete a Jidoka job.
