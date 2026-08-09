# Herdr H1 protocol boundary evidence

Date: 2026-08-09

Base: `origin/main@282e849bdb4fdf573a1cf4f9bddb35c6fffebeed`

Branch: `feat/jidoka-code-herdr-runtime`

## Result

H1 is complete. Jidoka Code now has a typed, read-only Herdr `0.8.0` / protocol `19` handshake over an explicitly injected Unix socket. The production composition and every Herdr mutation remain unchanged and unavailable through this client tranche.

The client fails closed on version, protocol and required-capability drift. It validates the canonical parent directory, socket type, owner and mode, connected peer UID, before/after socket identity, checked close-on-exec, request identity, UTF-8 NDJSON framing, record bounds and monotonic deadlines. It has no default endpoint resolver and no retry path.

The observed Herdr API schema digest remains offline provenance only. H1 does not claim that the socket peer authenticates that schema or binary; binary/schema attestation remains H5.

## Changed surfaces

- `Sources/JidokaCodeCore/Herdr/HerdrProtocol.swift`
- `Sources/JidokaCodeCore/Herdr/HerdrSocketClient.swift`
- `Tests/JidokaCodeCoreTests/HerdrFakeSocket.swift`
- `Tests/JidokaCodeCoreTests/HerdrProtocolTests.swift`
- `Makefile`
- `docs/plans/active/2026-08-05_jidoka-code-macos-app.md`
- `docs/plans/active/2026-08-09_jidoka-code-herdr-runtime.md`

H1 source and test files contain 1,433 lines. Their aggregate SHA-256 is `f6fa1ce3c211a4c28dc1580dd2bf5816d9df33010640970ee7e4e11098221df2`. The aggregate `Sources` plus `Tests` SHA-256 after the final edit is `2b5452e6c490e9aea7cc38b60d1824955cd9283887683aa41cb176a5e6ace806`.

## Verification after the final source edit

- `make jidoka-code-test-herdr`: 11 tests in 1 suite passed.
- Ten valid repeated focused suite runs passed before final review; the loop stopped on the first command failure and verified ten success markers.
- `make check`: 355 tests in 61 suites passed in 72.733 seconds, including strict Swift format, lint, build and tests.
- `make test-e2e`: S1 package E2E passed; S10 UI passed with `keychain:0,network:0,provider:0,service_management:0`.
- `xcrun swift test --sanitize=address --filter Herdr`: 11 tests passed.
- `xcrun swift test --sanitize=thread --filter Herdr`: 11 tests passed.
- `git diff --check`: passed.

## Independent review

Six fresh Pi sessions ran as visible top-level Herdr agents in two architecture/security/test rounds. They were read-only and made no source edits.

The first round identified public trust-object bypasses, a weakenable owner seam, incomplete parent and descriptor checks, an invalid schema-authentication claim, and scheduler/packetization-dependent tests. The parent fixed each verified finding.

The final round reported no open Critical or Major security finding. Architecture confirmed `FIX VERIFIED` after `HerdrHandshake` became module-constructible only. Test review confirmed `FIXES VERIFIED` after fail-before-connect and no-fallback assertions began observing the production system exchanger synchronously immediately before `socket/connect`. All review agents exited; no transient Pi lock remains.

## Side-effect boundary and residual risk

Automatic tests used only private temporary Unix sockets. They did not contact the real default Herdr socket, mutate the global session, start a production Pi process, invoke an application provider, access Keychain, mutate GitHub, register ServiceManagement or install a package.

Not verified in H1:

- a canary through the real default Herdr socket;
- topology mutations, response-lost attribution or event recovery;
- exact host/Pi TUI launch and structured result settlement;
- Herdr binary and schema attestation;
- protection against a malicious process running as the same user.

These are explicit H2-H5 gates, not inferred from the H1 result.
