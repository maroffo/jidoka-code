# W8 production identifiers and disposable staging evidence

Date: 2026-08-11

Branch: `feat/jidoka-code-w8-w9-closure`

Base: `origin/main@6350acc454878b7fed2d84ea6802ef8ebf804b56`

## Outcome

W8 now uses the locked production identities:

- application: `com.maroffo.JidokaCode`;
- LaunchAgent and Mach service: `com.maroffo.JidokaCode.Engine`;
- installer receipt: `com.maroffo.JidokaCode.pkg`;
- install destination: `/Applications/Jidoka Code.app`.

The internal Swift target and executable name `JidokaCodeEngineProbe` remain unchanged. They are implementation names, not distributed bundle, signing, LaunchAgent, or Mach-service identities.

Packaging also closes two failures discovered by the disposable-staging run:

- Bash 3.2 under `set -u` rejected an empty optional Keychain argument array. The scripts now branch explicitly between an implicit login Keychain and an exact supplied Keychain.
- A combined temporary Keychain containing Application and Installer private keys caused `productbuild`/`productsign` to wait for Keychain UI or return `CSSMERR_CSP_USER_CANCELED`. The installer supports separate `APPLICATION_SIGNING_KEYCHAIN` and `INSTALLER_SIGNING_KEYCHAIN` paths, while `SIGNING_KEYCHAIN` remains a compatible common fallback.

The signed archive flow is now one bounded unsigned `productbuild` followed by one bounded `productsign --timestamp`. `scripts/run-bounded-command.pl` gives each step a 300-second monotonic deadline, a dedicated process group, same-group TERM-to-KILL cleanup, signal forwarding, exact status propagation, and fixed timeout diagnostics. It is not a sandbox and cannot reclaim descendants that daemonize or escape with `setsid()`; the package script exposes no caller-selected command and uses only Apple's fixed `/usr/bin/productbuild` and `/usr/bin/productsign` paths. Apple notarization wait has an explicit 30-minute limit.

## Falsifiers

Before the identifier change:

```text
observed_app_id=com.maroffo.JidokaCode.Probe
observed_helper_id=com.maroffo.JidokaCode.EngineProbe
production_identifier_reproduction=FAIL_AS_EXPECTED
```

S1 now proves:

- exact application and helper plist/Mach-service identities;
- exact runtime preflight identities from cwd `/`;
- exact `codesign` identifiers for app, engine, askpass, push guard, and Herdr host;
- implicit login-Keychain handling without an unbound variable;
- separate Keychain path validation;
- bounded-runner exact success/failure and immediate-signal propagation, one-second timeout, TERM-resistant same-group descendant cleanup, and relative-executable rejection;
- one `pkgbuild`, one unsigned `productbuild`, one `productsign --timestamp`, no `installer`, and explicit notarization timeout.

During investigation, a forced full-payload signing hang returned within 300 seconds and cleanup was observed for package publication, temp paths, descendants, disposable checkout, temporary Keychain, and the user search list. No redacted transcript from that run was retained, so this observation is context only and is not used as durable completion evidence. The executable S1 timeout and cleanup falsifiers remain in source and are rerun by `make test-e2e`.

## Historical disposable staging result

This retained staging run proves the production identifiers and bounded signing flow for source patch `7b4509e3…`, but it predates the later durable-termination and S9 ownership fixes from final review. It is historical evidence, not evidence that the complete current dirty tree is reproducible or ready for CHECKPOINT C. A new disposable staging run from the final tree remains required.

The historical staging checkout was created detached from the exact base, received a byte-identical patch plus the then-new untracked files, and matched the implementation worktree status at that time before build.

```text
base=6350acc454878b7fed2d84ea6802ef8ebf804b56
staging_path=/private/tmp/jidoka-code-w8-staging.FirgSA
staging_removed=true
portable_launch_path=/private/tmp/jidoka-code-w8-portable.xQEt1r/Jidoka Code.app
portable_removed_after_copy=true
source_patch_sha256=7b4509e33b5d74a06e0bf4d0a8a37a2a8df98e88d37c15ecdeffdb32523a295f
app_bundle_identifier=com.maroffo.JidokaCode
helper_identifier=com.maroffo.JidokaCode.Engine
package_sha256=c73d85457ac2f8124de0b668a6bf0b515decfa306df8f40874fa6f389a4b21c3
manifest_sha256=377b4090c95ef76aad42b03b25253835eeca4aa4624edf664f79edf231b84ac7
preflight_sha256=8c0eb9aadbfd8962f27f492977de2a2935fb284ad465b8fb5ed6330c3b3827ff
launch_cwd=/
installed=false
```

The app and package were copied outside staging before that exact checkout was removed. Only after removal, the copied app ran `--preflight` from cwd `/` with a credentialless environment. `codesign --verify --strict --deep` passed, and `pkgutil --check-signature` reported Developer ID Installer, Team ID `X3Q42VNZDC`, and a trusted timestamp.

Historical local evidence is retained under ignored path `build/w8-staging-portable/`; it must not be relabeled as the final package.

## Verification status

Fresh after the final reviewer-fix source edits and before only this evidence-text update:

- direct `make check`: passed 448 tests in 71 suites; retained local log `build/evidence/w8-final-source-check.log`, SHA-256 `233254cd461d66e7ce0fafa1f2bb7ad557445c6786d33a1e2396e1fdce631211`;
- direct `make test-e2e`: S1 package, S10 UI, S11 isolated Herdr, and S12 exact Pi TUI passed;
- `make jidoka-code-test-s2-preflight jidoka-code-test-s3-preflight jidoka-code-test-s9-preflight`: passed; S9 reported `normal_app_launch=not-run default_socket_contacts=0`;
- strict Swift format, Bash syntax, ShellCheck, Perl syntax, and `git diff --check`: passed;
- focused durable-termination tests cover successful notification ordering plus concurrent AppKit true/false completion; S1 covers distinctive exit 37, immediate TERM status 143, TERM-resistant same-group cleanup, both common-Keychain fallback arms, and exact package command plans.

These gates validate the current source behavior, but they do not replace the still-open final disposable staging, Developer ID build/notarization, installed lifecycle, or W9 canary evidence.

## Side effects and remaining gates

Temporary Application and Installer Keychains were created from the already authorized local P12 archives, kept unlocked only for the bounded signing run, added temporarily to the user search list, then deleted. The original search list containing only `login.keychain-db` was restored. No secret, Key ID, Issuer ID, password, P12 path, Keychain path, or private-key material is stored in source or package manifests.

The historical staging package is Developer ID signed but deliberately unnotarized. It is not an installation candidate. `/Applications/Jidoka Code.app`, receipt `com.maroffo.JidokaCode.pkg`, and launchd job `com.maroffo.JidokaCode.Engine` remain absent.

During reviewer-fix validation, an earlier `S9 --preflight-only` implementation launched the packaged production app with a synthetic `HOME`. On macOS, `FileManager.homeDirectoryForCurrentUser` still resolved the real account home, so those runs updated the persistent `~/Library/Application Support/JidokaCode/IPC/ui-instance.lock`. Exact build-app processes were terminated and the owned temporary directories were removed; no installed app, receipt, helper process, or launchd job remained. Retained evidence cannot prove that these starts never attempted the default Herdr socket, so default-session contact for those runs is `unknown`, not a W9 canary or completion signal. The lock file was not deleted. S9 preflight now exits after static package/topology checks without launching production composition and reports `normal_app_launch=not-run default_socket_contacts=0`; the production launch remains live-mode and authorization gated.

Open gates:

1. reproduce the complete final tree in a new disposable staging checkout and replace the historical staging hashes;
2. rerun fresh full local verification and independent closure review after the final staging evidence update;
3. build and notarize the final production-identifier package;
4. present CHECKPOINT C with exact final package path, digest, receipt, destination, signature, installed-state precondition, and rollback;
5. only after explicit authorization, install and verify the installed user flow and ServiceManagement lifecycle;
6. CHECKPOINT D remains separate for credentials, provider calls, GitHub mutations, and the default-session canary.
