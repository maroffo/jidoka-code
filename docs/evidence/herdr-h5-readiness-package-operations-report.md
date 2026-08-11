# Herdr H5 readiness, package, and operations report

Date: 2026-08-10

Base: `origin/main@8cf8033e38e1710ecac23b1621051e9a73ed417f`

Branch: `feat/jidoka-code-herdr-readiness-package-operations`

## Scope and outcome

H5 adds a fail-closed production readiness boundary for the external Herdr runtime, explicit user-only focus, packaged host inventory and nested signing, an audited local installer package, and operations guidance.

It does not install the package, register ServiceManagement, access application GitHub or provider credentials, contact or focus the default Herdr session during automated verification, or run a live production canary. The initial H5 commit, non-force push, and pull request were separately authorized on 2026-08-10. The project owner merged PR #12 as `47c6ffa3da948239891fffbcf09b2e716c0ce925` before the signing/notarization follow-up was pushed; that follow-up remains a separate publication and no merge was executed by the assistant.

A follow-up authorization imported the existing matching Developer ID Application and Developer ID Installer private keys into the login Keychain, used a private App Store Connect key with mode `0600`, and submitted the signed package to Apple Notary Service. No certificate was created or revoked, no secret was written to the repository or build manifest, and no package was installed.

## Runtime attestation

`HerdrRuntimeResolver` starts from the fixed `/opt/homebrew/bin/herdr` link and packaged `Resources/Herdr` policy. It requires a regular, non-writable, single-link executable with the approved digest, exact `herdr 0.8.0` version output, and byte-identical `herdr api schema --json` output under a bounded credentialless environment. It reads files through `O_NOFOLLOW`, bounds every input and output, and verifies the executable again after both CLI calls.

Approved provenance:

- external executable SHA-256: `97bdb194a731262d2b70062621a5673b1cd409b9e6870df361bd65799217eaf3`;
- full protocol-19 schema SHA-256: `88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a`;
- packaged policy SHA-256: `3fdd7b5d6f273ab264c6c2f502e8c8902819cc353052191769c4ec22213d4673`;
- policy schema: `1`, architecture: `arm64`, Herdr: `0.8.0`, protocol: `19`.

Only after offline attestation does readiness perform the fixed socket handshake. Binary, schema, version, protocol, capability, socket ownership, and availability failures map to typed closed UI states. The engine protocol is version `2`; malformed ready states fail XPC response validation.

Onboarding, wake/network regain, manual preflight, and the production dispatch gate all require Herdr readiness. Regain rebuilds durable runtime state before requesting a scheduler pass. Local result import and approved-command recovery remain available while Herdr is unavailable; no fallback runner opens.

## Explicit visibility action

`Open in Herdr` is reachable only as an explicit UI command. It has no target parameters. The runtime selects the most recently updated live durable role host, then revalidates repository binding, generation, workspace, tab, pane, terminal, socket identity, PID/start identity, executable, and exact role-host argv.

It focuses workspace, tab, then pane through typed methods. It proves the process again immediately before pane focus and after the final snapshot. Startup, readiness, recovery, polling, and topology creation continue to use no-focus operations. A reused or foreign pane is not touched.

## Package and installer audit

`Packaging/app-inventory.txt` closes the application inventory. `scripts/package-app.sh` builds `JidokaCodeHerdrHost`, copies the two Herdr attestation resources, removes checkout rpaths, signs every nested executable before the outer app, verifies one concrete Team ID, rejects symlinks, and rejects a bundled external `herdr` executable. Ad-hoc signing is accepted only when S1 passes `ALLOW_ADHOC_SIGNING=1`; release packaging requires explicit Developer ID Application and Developer ID Installer SHA-1 identities.

`scripts/package-installer.sh` uses one `pkgbuild` and one `productbuild` step. It verifies:

- application identifier `com.maroffo.JidokaCode.Probe`, version `0.1.0`, minimum macOS `14.0`;
- receipt identifier `com.maroffo.JidokaCode.pkg` and destination `/Applications/Jidoka Code.app`;
- exact app and extended-attribute payload inventories;
- non-relocatable payload, no lifecycle scripts, and no postinstall action;
- nested app and host Developer ID Application signatures with Team ID `X3Q42VNZDC` and trusted timestamps;
- a Developer ID Installer product signature using certificate SHA-256 `F1A2E1056C5B3B4A994DA9D6F2427D782F643FBA2D048A26973E6A14FB938731`;
- no checkout path, symlink, test artifact, or external Herdr executable in the app;
- optional notarization that publishes output only after Apple returns `Accepted`, stapling succeeds, and Gatekeeper reports `Notarized Developer ID`.

Final local package evidence, not installed:

- `build/Jidoka Code.pkg` SHA-256: `4f215557d911412be45eca0fbfb290c1d03c203f0a566af8796e52d9c83cc78b`;
- `build/package-manifest.json` SHA-256: `77b26df99256873bc13cb3471d7cd3cfe8d5ba658e33e8bd996c2e75c6c278de`;
- `build/notarization-result.json` SHA-256: `fcd8c01800c58625c5fcc6e59b9ec6fdebfade9c6ee6efdd0253435fa0733122`;
- Apple notarization submission: `97cbda8c-f124-4eff-bcf5-3dc96db83315`, status `Accepted`;
- `Packaging/app-inventory.txt` SHA-256: `d3549c33827a038eea4ea36ac90c52c649c822cef7e55e2d6579cdd536b9ffaf`;
- `pkgutil`: Apple Developer ID Installer signature, trusted timestamp, trusted Apple notarization;
- `stapler validate`: pass;
- `spctl -t install`: accepted as `Notarized Developer ID`;
- package receipt present on host: no;
- `/Applications/Jidoka Code.app` present on host: no.

## Verification after the final source edit

- focused closure: 22 tests across engine protocol, readiness, dispatch regain, local result recovery, focus ownership, and production composition passed;
- `make test-e2e`: S1 package, S10 UI, S11 isolated Herdr, and S12 isolated exact Pi TUI passed;
- S10: `keychain:0,network:0,provider:0,service_management:0`;
- S11: `default_socket_contacts=0`, `focus_changes=0`;
- S12: `provider_network=0`, `focus_changes=0`;
- AddressSanitizer: 445 tests in 71 suites passed with no sanitizer finding;
- ThreadSanitizer: 445 tests in 71 suites passed with no data-race finding;
- Developer ID Application and Installer construction, Apple notarization, stapling, Gatekeeper assessment, and the independent package audit passed;
- strict Swift format, ShellCheck, and `git diff --check` passed before the post-document repository gate.

Evidence log SHA-256:

- `/tmp/jidoka-h5-focused-closure-1.log`: `ab755cda44be9759394045079e45b4ff192da2ccd68ff9e18d33613e8417bbbe`;
- `/tmp/jidoka-h5-test-e2e-final-1.log`: `c60e063f2be5b22b14bbbfdb8a11c8c14cf28d0de46db730960dc5d3a680220c`;
- `/tmp/jidoka-h5-asan-final-1.log`: `482dd64dd455458fca9ccc7c7fd09556c5a5ee15c31066c98c3078b9b1ce9200`;
- `/tmp/jidoka-h5-tsan-final-1.log`: `4a1e499d25e8d03d253c1498a8125eda1eaa4ce9b96540ad2b3b43819b09e6e4`;
- `/tmp/jidoka-h5-signed-package-final-1.log`: `c16277730fe1a33f37f04c1e9bf2c0e40396edeec284ebf22437c4d4599cd785`;
- `/tmp/jidoka-h5-package-audit-final-1.log`: `61d7acf816c1e7836801c6fb13a37fa14a3f4b44e430c20cb7c17c50783f618e`;
- `/tmp/jidoka-h5-developer-id-notarized-package-final-2.log`: `e6cb8b7123a2d76d1b1c0e0566255ae0c72abaec98535c8b77295ece5eba0a29`.

The final post-document `make check` is intentionally recorded in the session handoff rather than self-embedded here, so this report is not modified after that gate.

## Review and residual risk

The parent reviewed the complete diff for dispatch authority, focus mutation scope, attestation TOCTOU checks, XPC status validity, package payload, signing order, and installer actions. Independent H5 review agents were not launched because the approved boundary forbids hidden delegation and automated access to the real default Herdr session.

Residual boundaries:

- the schema digest proves the approved CLI output, not cryptographic identity of the socket peer;
- malicious same-UID process replacement remains outside the threat model;
- the Developer ID certificates expire on 2027-02-01 and require reviewed rotation before then;
- the notarized package remains uninstalled;
- the production bundle identifier still carries the historical `.Probe` suffix;
- disposable staging-checkout reproduction, installed ServiceManagement lifecycle, real accessibility, Keychain/provider access, and the default-session canary remain W8/W9 checkpoints requiring separate authorization.
