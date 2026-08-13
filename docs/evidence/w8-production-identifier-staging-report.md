# W8 production identifiers and disposable staging evidence

Date: 2026-08-12

Product branch: `feat/jidoka-code-w8-w9-closure`

Evidence branch: `chore/jidoka-code-w8-final-package`

Original W8 base: `origin/main@6350acc454878b7fed2d84ea6802ef8ebf804b56`

Product-bearing merge: `origin/main@c218e52bec331b3380e619cd2c6bfff8ae1e7b31`

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

## Revoked disposable staging and notarization result

The complete product-bearing merge was reproduced without a patch in a clean detached disposable worktree. The package was signed through separate temporary Application and Installer Keychains, submitted to Apple, accepted, stapled, and copied with the portable application outside staging. The exact staging worktree was then removed before the copied application and helper ran their credentialless preflights from cwd `/`. The later authorized installation falsified the package destination guarantee, so this package is revoked despite its valid signature and notarization.

```text
product_commit=c218e52bec331b3380e619cd2c6bfff8ae1e7b31
source_tree=d8e64a3d0343b33bf17a287a47a1b13460ad4243
source_archive_sha256=fd2f87c246af831bd4205713a65e9ce629d3e4ea4c86eee1883740b55195467d
staging_removed=true
package_path=build/w8-final-portable/Jidoka Code.pkg
package_sha256=94382d030a09e796b06d8cc8d79403b98f5cc0d384ca6c6366f4afea49b72366
manifest_sha256=3e9b86c7889678776136a9fcbf4395e39838f0ade772d5808e1662ff630e1ddb
notarization_result_sha256=2e617836ec35ab7be5f1bc90271fdac328581a534aa92aa52e0b6a81ae024cc2
notarization_submission_id=28ff9634-1006-42a4-b1f5-c567100c0a7e
notarization_status=Accepted
trusted_installer_timestamp=2026-08-12 06:06:33 +0000
preflight_sha256=8c0eb9aadbfd8962f27f492977de2a2935fb284ad465b8fb5ed6330c3b3827ff
engine_preflight_sha256=dcd600f7477568aef6c1d4ae33e0f708d0a1dc22158870c95746fe1a234878e3
app_bundle_identifier=com.maroffo.JidokaCode
helper_identifier=com.maroffo.JidokaCode.Engine
package_identifier=com.maroffo.JidokaCode.pkg
install_location=/Applications/Jidoka Code.app
launch_cwd=/
keychain_search_list_restored=true
temporary_keychains_removed=true
installed=false
receipt_present=false
launchd_job_present=false
```

Independent parent audit recomputed the commit tree, source archive, package, manifest, notarization result, application preflight, and helper preflight digests listed above, and matched the package and notarization digests recorded by the manifest. It also checked `codesign --verify --strict --deep`, `stapler validate`, package and application Gatekeeper assessments, and the Developer ID Installer signature with trusted timestamp. Gatekeeper reported `Notarized Developer ID` for both app and package. The closed installer audit matched 65 payload entries and 65 AppleDouble metadata entries to `Packaging/app-inventory.txt`, found zero lifecycle scripts, and verified receipt, version, the declared destination, no postinstall action, exact app/helper identities, no symlinks, and no staging or credential path. Its non-relocation check was insufficient: `PackageInfo` had a top-level `relocatable="false"` attribute while still containing one `/pkg-info/relocate/bundle` target.

The authorized CHECKPOINT C install wrote receipt `com.maroffo.JidokaCode.pkg`, but PackageKit logged `Applications/Jidoka Code.app relocated to .../build/Jidoka Code.app`. `/Applications/Jidoka Code.app` remained absent. The relocated root-owned bundle and the receipt are retained as failure evidence; no application or helper process and no production launchd job appeared. The installed payload also exposed caller-umask drift: directory and executable modes were `0700`, which would be unsuitable for a root-owned application in `/Applications`.

The fix replaces `pkgbuild --component` with a controlled root plus `Packaging/app-component.plist`, where `BundleIsRelocatable=false` and the other Apple defaults remain locked. Package audit now requires zero `/pkg-info/relocate/bundle` nodes, one strict production identifier, and upgrade-only overwrite policy. `package-app.sh` fixes `umask 022` and verifies directory `0755`, executable `0755`, and resource `0644` modes after all Mach-O mutation and signing. S1 permanently reproduces the vulnerable relocation metadata, proves the locked package has no relocation target, and invokes packaging under hostile `umask 077`.

The revoked local artifacts are retained under ignored path `build/w8-final-portable/`. Package `94382d03…` must not be installed again or presented as a CHECKPOINT C candidate. A new source-bound package, signing/notarization run, and digest are required.

## Historical disposable staging result

The earlier staging run proves the production identifiers and bounded signing flow for source patch `7b4509e3…`, but it predates the later durable-termination and S9 ownership fixes from final review. It remains historical evidence and is superseded by the final merge-bound result above.

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

The pre-installation product merge and evidence-only closure passed their recorded gates, including direct `make check` with 448 tests in 71 suites. Those runs predate CHECKPOINT C and do not attest the relocation and mode fix. The retained merged-tree log remains historical evidence at `build/evidence/w8-merged-final-check.log`, mode `0600`, SHA-256 `a8d48fd2206a42b39557b1a3c1e4847704880329519492b8046eb3938083df42`.

Fresh fix verification runs in a byte-identical detached worktree under the canonical `/Users` tree, leaving the failed receipt and relocated root-owned bundle untouched. The current source delta is based on `22692c3e14e55aed300d1bbef8b3a028e05e69d5`. Delta digests recorded before later evidence edits are provenance snapshots only; the final commit tree will supersede them as source authority.

Fresh passing gates:

- final direct `make check` on the definitive code and test tree: 448 tests in 71 suites passed in 843.978 seconds. The detached verifier log is `build/evidence/w8-install-fix-final-check.log`, mode `0600`, SHA-256 `a6836a5dae0a37d1d77c91c4807f0ae2a2b0bb3a19e379cef68c5dac14a744e9`. This evidence-only result recording followed the run;
- direct `make test-e2e`: S1 package, S10 UI, S11 isolated Herdr, and S12 exact Pi TUI passed together after all fixture and review fixes;
- `make jidoka-code-test-s2-preflight jidoka-code-test-s3-preflight jidoka-code-test-s9-preflight` passed after all fixture and review fixes, with S9 reporting `normal_app_launch=not-run default_socket_contacts=0`;
- Bash syntax, ShellCheck, Node syntax, plist validation, and `git diff --check` passed after the review fixes;
- S1 runs `package-app.sh` below hostile `umask 077`, reproduces exactly one legacy relocation target for `com.maroffo.JidokaCode`, and requires the locked package to have exact singleton receipt, bundle/path, bundle-version, strict-identifier and upgrade-bundle metadata, zero relocation/update/atomic-update targets, and the expected component-package BOM modes;
- S11 now creates its private descriptor root below canonical `build/evidence`, rather than the `/tmp` symlink spelling rejected by the host's canonical-path boundary. S11 harness SHA-256 is `a4f5e2f0f88380596868e206ba6c47a3b7642ab522453a20572647adc25aac3d`;
- S12 gives runtime-snapshot attestation a separate bounded 120-second pre-spawn window, validates the host's atomically written child-process record, then requires locked-editor visibility before the deterministic fixture provider emits its first output. S12 harness SHA-256 is `1f250e898a20ba88643c887367332ead4ce0b82190daa8cf4470fc486c7ea8d1`; fixture-provider SHA-256 is `132c605ddce5e6871a133098f19958fe734399d0ec79c5aaa2759e0d6ce48d35`.

Independent architecture, security, test, and DX reviews initially found two PackageInfo-closure concerns and two S12/S1 test concerns. Exact singleton PackageInfo assertions and the child-spawn/editor/provider-output causal ordering resolved the actionable findings. A suggested AppleDouble `0644` rule was rejected against executable evidence: the actual component BOM gives each `._` entry the same type/mode as its associated payload, and the separate normalized metadata inventory must match the complete application inventory. Targeted closure reported 0 Critical, 0 Major, and 0 Minor findings.

Disposable signed/notarized staging and installation remain open. Installed lifecycle, runtime accessibility, application credentials, and the W9 default-session canary remain separate unchecked surfaces.

## Side effects and remaining gates

The exact Application and Installer identities were exported separately from the login Keychain into short-lived P12 files protected by distinct random passwords. Those P12 files populated separate temporary Application and Installer Keychains. The export files, passwords, Keychains, and credential input were deleted after the bounded build; the original search list containing only `login.keychain-db` was restored. No secret, Key ID, Issuer ID, password, P12 path, Keychain path, or private-key material is stored in source, package manifests, or retained logs.

The historical `c73d854…` package remains signed but unnotarized and is not an installation candidate. Package `94382d03…` is signed and notarized but revoked by the installed relocation and mode falsifiers. `/Applications/Jidoka Code.app` and launchd job `com.maroffo.JidokaCode.Engine` remain absent; receipt `com.maroffo.JidokaCode.pkg` and the relocated root-owned worktree bundle remain present as failure evidence pending explicit cleanup authorization.

During reviewer-fix validation, an earlier `S9 --preflight-only` implementation launched the packaged production app with a synthetic `HOME`. On macOS, `FileManager.homeDirectoryForCurrentUser` still resolved the real account home, so those runs updated the persistent `~/Library/Application Support/JidokaCode/IPC/ui-instance.lock`. Exact build-app processes were terminated and the owned temporary directories were removed; no installed app, receipt, helper process, or launchd job remained. Retained evidence cannot prove that these starts never attempted the default Herdr socket, so default-session contact for those runs is `unknown`, not a W9 canary or completion signal. The lock file was not deleted. S9 preflight now exits after static package/topology checks without launching production composition and reports `normal_app_launch=not-run default_socket_contacts=0`; the production launch remains live-mode and authorization gated.

Open gates:

1. obtain owner merge of this verified source fix;
2. reproduce the exact merged source in disposable staging, sign and notarize a replacement package, and record a new digest;
3. obtain explicit cleanup authorization for the retained failed receipt and relocated bundle;
4. present a new CHECKPOINT C for the replacement digest before any second installation;
5. only after explicit authorization, install and verify the installed user flow and ServiceManagement lifecycle;
6. CHECKPOINT D remains separate for application credentials, provider calls, GitHub mutations, and the default-session canary.
