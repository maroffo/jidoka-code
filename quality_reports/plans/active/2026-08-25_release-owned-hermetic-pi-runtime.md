# Release-owned hermetic Pi runtime

**Status:** approved; W0-W7 release package complete under decision 21; installed production authority blocked and separately gated
**Origin:** In-session decision by Max on 2026-08-25, Hold Scope option 1
**Base:** `feat/settings-guided-configuration` at `7ba8eae88f029df360af01ffa7b5af669d1cfa01`, with 109 pre-existing dirty paths and zero staged paths
**Goal:** Production and source verification resolve Node and Pi only from a release-owned, path-independent runtime carried by Jidoka Code, so Homebrew upgrades cannot change execution authority and runtime updates occur only with a Jidoka Code release.

## Analysis (verified 2026-08-25, do not re-derive without new evidence)

### Current behavior

- `PiRuntimeResolverConfiguration.standard` names `/opt/homebrew` and `/usr/local` Pi and Node candidates and loads the compatibility policies from the Pi resource root (`Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:190-213`).
- Pi authority is exact but external: package identity, semantic range, critical-file digests and the complete package-tree attestation must match a source policy (`Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:299-390`).
- Node authority is also exact but path-coupled: the executable canonical path, digest, every dynamic-library load path, canonical Cellar path, digest and Mach-O closure must match (`Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:394-469`, `Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:471-552`).
- The private snapshot machinery already copies Node, its libraries and the Pi package into a 0700 path and verifies the copied bytes (`Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:914-1039`, `Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:1210-1318`). Reopening still requires a previously resolved live source runtime and an expected marker derived from it, so the snapshot cannot become independent release authority (`Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:948-966`, `Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift:1035-1085`).
- Production still constructs the external resolver in the app client, engine process and job runtime (`Sources/JidokaCodeApp/ApplicationEngineClient.swift:455-478`, `Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift:375-397`, `Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:985-990`).
- Workflow execution resolves the external runtime directly in the RPC path and at three Herdr workflow boundaries (`Sources/JidokaCodeCore/Pi/PiRPCWorkflowExecutor.swift:80-88`, `Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:1220-1225`, `Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:3118-3124`, `Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:4189-4194`). Model discovery and TUI execution resolve first and only then materialize a private copy (`Sources/JidokaCodeCore/Pi/PiModelCatalog.swift:195-202`, `Sources/JidokaCodeCore/Pi/PiTUIRuntime.swift:904-949`).
- A Herdr host descriptor resolves its Pi TUI invocation with no supplied runtime in the public initializer, so decoding or reconstruction can independently hit the external resolver (`Sources/JidokaCodeCore/Herdr/HerdrHostRuntime.swift:228-280`).
- Debug path selection may fall back to checkout resources, while release builds require bundle resources (`Sources/JidokaCodeApp/ApplicationEngineClient.swift:539-558`, `Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift:451-468`). No separate release-runtime root exists.
- Packaging copies a small explicit resource set, expects a 66-entry application inventory, gives executable mode only to five binaries, signs those binaries and the app, and rejects every bundle symlink (`scripts/package-app.sh:207-360`, `scripts/package-app.sh:389-424`, `Packaging/app-inventory.txt:1-66`). Installer verification consumes the same static inventory and fixed mode model (`scripts/package-installer.sh:118-151`, `scripts/package-installer.sh:267-310`).
- The system-runtime test is intentionally coupled to exact installed Pi `0.84.2`, Node `26.7.0` and 25 external libraries (`Tests/JidokaCodeCoreTests/PiRuntimeResolverTests.swift:414-470`). This makes the ordinary source gate depend on mutable machine state.
- A prior private runtime snapshot is about 295 MiB with 20,588 entries and 26 internal symlinks. Its Pi tree is about 176 MiB and copied Homebrew libraries are about 119 MiB. This is measured evidence, not a proposed bundle shape.
- The existing strict static-code helper demonstrates the required validation flags: all architectures, nested code, strict validation and restricted symlinks (`Sources/JidokaCodeCore/Application/PackagedExecutableSnapshot.swift:200-224`).

### Root cause or design gap

Execution authority is attached to a package-manager installation rather than to the Jidoka Code release. Exact hashes make drift fail closed, but absolute Homebrew Cellar and `opt` paths ensure ordinary dependency upgrades eventually deny every production resolver call. The private snapshot is a derived cache, not an independent trust root, because it can only be reopened against live source evidence. Packaging has no input contract, manifest, signature order or inventory model for an owned Node/Pi runtime. The gap is falsifiable: an exact offline Pi `0.84.2` tree still produced 175 workflow-test issues because the unchanged Node executable loaded three newer Homebrew dependencies; the first error was `unattestedNodeBuild`.

### Scope

- In: a release-owned runtime manifest and resolver; a fixed bundle/runtime layout; strict bundle, Node, Pi tree and Mach-O validation; compiled manifest-digest authority; production wiring across app, engine, RPC, TUI, model catalog and Herdr host reconstruction; runtime identity in durable host descriptors; a packaging input contract and exhaustive generated runtime inventory; hermetic source tests; removal of Homebrew from production execution authority.
- In after plan approval but before source implementation: a bounded W0 qualification of one official macOS arm64 Node artifact and the already attested Pi `0.84.2` npm package. Downloaded public artifacts live only under ignored `build/` staging, are never executed before checksum/signature validation, and are never committed.
- Out: a runtime network updater; trust on first use; automatic enrollment of current Homebrew bytes; committing Node, Pi or binary archives to Git; changing provider credentials; database changes; q4, q5 or Resume behavior; production install or execution; Developer ID signing, notarization and package publication; commit, push or PR.
- Threat boundary: configured repositories, their approved verification commands, and release-attested child runtimes are trusted not to deliberately evade supervision. W6 does not claim hostile child containment against an immediate `fork`/leader-exit/reparent/`setsid` sequence.
- Recover excluded architecture-host replacement context from `quality_reports/plans/active/2026-08-24_architecture-host-replacement-completion.md` and `quality_reports/plans/active/2026-08-23_architecture-host-replacement-fallback.md`.

### Candidate approaches

| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Release-owned official macOS arm64 Node plus one pinned Pi package | chosen, conditional on W0 | The exact candidate is `node-v26.7.0-darwin-arm64.tar.gz` from `https://nodejs.org/dist/v26.7.0/`, SHA-256 `7ee659a7768e641bbfd5360940660b8e8fd0052f77488f365562bac522fc15d4`, with `SHASUMS256.txt.sig` issued by fingerprint `5BE8A3F6C8A5C01D106C0AD820B1A390B168D356`. This removes Homebrew authority, but W0 must still prove macOS signature, architecture, dependency, JIT, entitlement, license and ad hoc container compatibility before source work. |
| Release-owned rewritten Homebrew snapshot | rejected as default | It can be made path-independent, but starts at about 295 MiB, carries 25 formula libraries and requires install-name rewriting plus broad nested signing. Use only after a new Max decision if the official artifact fails W0. |
| Reopen the existing private snapshot without live source | rejected as the complete solution | It can preserve an already enrolled machine, but does not solve clean installation and leaves the first trust decision external. Useful implementation code may be reused, but it is not the release trust root. |
| Accept whichever Homebrew closure is installed | rejected | This is automatic supply-chain enrollment and directly contradicts fail-closed authority. |
| Signed remote runtime update channel | deferred | Max selected Hold Scope. Runtime bytes change only with an application release. |

### Independent opinion

A sanitized manual Expert Panel operation `f1f4caa4-bb8a-494a-b6f0-c999db82c4cb` was launched after automatic consent was unavailable. The chain failed before final synthesis and the operation remained active after its bounded await, so it was not relaunched. One completed independent critic returned `revise`, not reject. The supported revisions incorporated here are:

- do not treat the bundle signature as the only manifest anchor; compare the canonical release-manifest SHA-256 to a constant compiled into production code;
- explicitly run strict static-code validation on the containing application and nested Node code before authority, rather than relying on Gatekeeper's prior launch decision;
- make Node architecture, signature, hardened-runtime/JIT behavior and entitlements a W0 and packaging gate;
- compile production without an external/Homebrew fallback.

The critic's same-user mutation counterexample is mitigated twice: installed bundle ownership/modes remain package-controlled, and manifest plus runtime mutation must fail both the compiled digest check and strict code-signature validation. Confidence remains reduced on the exact official Node signing/JIT model until W0 executes.

A fresh read-only plan review then found four Major planning defects: W0 had excluded the packaging compatibility it required, artifact trust predicates were not fixed before download, W7 terminology implied production-install evidence, and authority boundaries were not finite. The plan now fixes the exact Node archive/checksum/signer and pass/fail predicates, permits one disposable W0 ad hoc container, separates W7 from later production installation, and requires one oracle per named boundary. A fresh re-review reported no remaining Critical or Major plan defect.

## Locked decisions

Append only. Reverse a decision with a new row that names the superseded row.

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Scope mode | Hold Scope | Max selected option 1 on 2026-08-25 | Max explicitly selects a signed update channel or narrower scope |
| 2 | Runtime owner | Jidoka Code release | Homebrew drift is the reproduced blocker | Never |
| 3 | Runtime updates | Application release only, no runtime network | Preserves review, rollback and supply-chain authority | Max separately approves an updater threat model |
| 4 | Production fallback | None | A Homebrew fallback would silently restore the same failure and trust ambiguity | A new plan proves an equally strong authority source |
| 5 | Artifact storage | Explicit pre-staged release input, not Git | Binary trees are large and release-specific | Repository policy changes |
| 6 | First Node source | Exact Node `v26.7.0` darwin-arm64 archive, checksum and signer fixed in Candidate approaches | The signed checksum fixes the bytes before download; the executor cannot enroll a different artifact | W0 fails signature, JIT, dependency, license or packaging gates |
| 7 | Pi source | One exact npm package tree and critical-file set per release | Existing tree attestation is strong and reusable | Pi packaging semantics change |
| 8 | Runtime layout | Read-only bundle runtime separate from mutable Pi resources | Avoids a second mutable 200+ MiB copy and gives app-signature coverage | Qualified Node requires writable runtime files |
| 9 | Runtime execution | Direct from the validated bundle root | Node/Pi state already lives in HOME, agent, session and temporary directories | W0 or S1 proves direct execution incompatible |
| 10 | Manifest authority | Canonical schema, source-controlled digest compiled into release code | Prevents mutation of both manifest and runtime from creating authority | A stronger deterministic build-time code generation design is proved |
| 11 | Signature authority | Strict runtime validation of the containing app and Node, plus byte/tree hashes | Gatekeeper approval alone is not a per-authority check | Platform API evidence disproves the need |
| 12 | Descriptor authority | Bind runtime identity and canonical runtime root into the Pi TUI/Herdr descriptor | Durable reconstruction must not choose a different release runtime | Descriptor protocol is replaced wholesale |
| 13 | Upgrade semantics | New release identity cannot resume an old in-flight runtime descriptor; installation must quiesce first | Cross-release replay would mix executable authority | A migration protocol is separately designed |
| 14 | External resolver | Retain only as internal test/diagnostic code; production constructors cannot select it | Unit coverage remains useful without a release fallback | It can be removed without losing negative coverage |
| 15 | Runtime symlinks | Only manifest-bound, internal Pi-tree symlinks; no root, Node or escaping symlinks | Pi packages may contain valid internal links, but package authority must remain closed | Qualified Pi tree contains none and normalization is proven safe |
| 16 | Packaging network | Package assembly is offline and consumes one validated input root | Builds must not fetch mutable artifacts while signing | A separately reviewed reproducible-fetch phase is added |
| 17 | Real signing/notary | Separate W7 gate | Source and ad hoc evidence cannot establish Developer ID/notary behavior | Max authorizes exact identities and package operation |
| 18 | Prior W6 blocker treatment | Supersedes the assumption that restoring Homebrew is the completion path | The reproduced drift is architectural, not a one-time environment repair | Never |
| 19 | Node qualification predicates | Superseded by decision 20 after W0 proved the checksum-fixed upstream Node carries four forbidden entitlement categories | The original predicate correctly stopped execution before source edits | Historical only |
| 20 | Controlled Node re-sign | Validate and retain the exact upstream acquisition evidence, remove its signature in the staged copy, then sign Node with identifier `works.earendil.jidoka.runtime.node`, hardened runtime and only `com.apple.security.cs.allow-jit` plus `com.apple.security.cs.allow-unsigned-executable-memory`; W6 uses ad hoc identity, W7 must use the Jidoka Developer ID team and reproduce the manifest-bound CodeDirectory identity | Max selected option 1 after W0 found upstream `get-task-allow`, disabled library validation, DYLD environment and executable-page protection exceptions. CodeDirectory page hashes plus strict signature validation bind executable content while allowing CMS identity to change between ad hoc and Developer ID signing | Ad hoc and Developer ID signing cannot reproduce the same CodeDirectory under the fixed identifier/options/entitlements, or JIT/Pi execution fails |
| 21 | Process-containment threat model | Treat configured repositories, approved repository commands and release-attested children as trusted not to deliberately escape supervision; accept the immediate `fork`/leader-exit/reparent/`setsid` race as residual risk outside W6 hostile-containment claims | Max selected option 2 on 2026-08-26 after local macOS evidence showed process-group cleanup is escapable and no supported public non-escapable coalition/adoption API was established. PID/start identity tracking and group cleanup remain required for cooperative and observed descendants | Jidoka must execute untrusted repository code, a model can select arbitrary child commands, or a supported kernel-backed isolation primitive becomes available |

## Acceptance criteria

- [x] Release production code has no Pi/Node execution fallback to `/opt/homebrew`, `/usr/local`, `PATH`, npm global state or a user-selected runtime path.
- [x] One canonical release manifest uses only bounded relative paths and binds the Node version, CodeDirectory full SHA-256, architecture, identifier, Jidoka team relation, exact entitlement digest, Mach-O closure, Pi version, critical files, complete Pi tree, licenses and exact root inventory. Strict Node and outer-app signatures bind executable pages and final CMS bytes without requiring the ad hoc and Developer ID files to have the same whole-file SHA-256.
- [x] The manifest SHA-256 is compiled into production code. Unknown fields, non-canonical JSON, a manifest-only mutation, a runtime-only mutation and a coordinated manifest/runtime mutation all fail closed.
- [x] The resolver opens and revalidates the runtime with descriptor-relative, `O_NOFOLLOW` traversal; denies extra, missing, hard-linked, escaping, wrongly owned, writable or changed entries; and rechecks evidence at these finite authority boundaries: app/local-engine startup preflight, engine-helper startup preflight, model-catalog process construction, RPC process construction, TUI host resolution, initial Herdr preparation, Herdr recovery/retry reconstruction, Herdr host descriptor construction/decode, replacement candidate creation, replacement execution before credential installation, and the final replacement proof immediately before send-start authority.
- [x] The containing application and Node pass strict static-code validation at runtime. Production additionally requires Node and app to share the Jidoka Team Identifier and requires the exact manifest-bound identifier, CodeDirectory and two-key entitlement policy. Production cannot inject a permissive validator; tests can inject only through internal DEBUG-visible seams.
- [x] Node uses arm64 and either system-only dependencies or a fully relative, manifest-bound in-bundle closure. No execution relies on Homebrew paths or `DYLD_LIBRARY_PATH`.
- [x] A bounded JIT probe and representative Pi preflight run successfully against the qualified Node artifact before it becomes a release input.
- [x] App client, engine helper, local engine, model catalog, RPC executor, TUI host, Herdr workflow and descriptor reconstruction resolve the same runtime identity.
- [x] `PiTUIHostInvocationDescriptor` and `HerdrHostDescriptor` reject runtime-root or identity drift, and existing q4 descriptor/configuration digests bind the new fields without a parallel authorization channel.
- [x] `package-app.sh` accepts one canonical explicit runtime input, performs no download, verifies it before copy, preserves only allowed modes/symlinks, signs in the proven order and validates the final nested bundle.
- [x] Installer inventory remains exhaustive without committing a 20,000-line static list: static inventory plus inventory generated from an already validated runtime tree must equal app and BOM payload exactly.
- [x] Ordinary `make check` and the full Herdr runtime suite are hermetic and remain green when every Homebrew Pi/Node path is absent or divergent.
- [x] A source test proves release A and release B select only their own identity; release B cannot reopen or replay an in-flight release-A descriptor.
- [x] W6 source completion does not claim Developer ID signing, notarization, production installation, live Pi execution or hostile containment of deliberately escaping trusted children. W7 covers Developer ID/notary and clean signed-bundle probes only; production installation and production execution remain a later separately authorized gap outside this plan.
- [x] Process cleanup remains fail-safe for cooperative and observed descendants, but acceptance is evaluated under decision 21; no test or polling result is represented as proof of non-escapable hostile containment.

## Workstreams

### W0: Qualify the first release artifact and preserve the reproduced failure

- Scope: ignored `build/runtime-input/`, public Node release metadata, local npm cache, one bounded qualification script and evidence logs.
- Excluded: Homebrew mutation, global npm install, product/release packaging and source implementation. One disposable ad hoc app container is allowed solely to falsify nested Node signing, strict verification and JIT compatibility before W1.
- [x] Preserve `/tmp/jidoka-w6-restored/herdr-runtime.log` under ignored W0 evidence: exact Pi passed; first production failure is `unattestedNodeBuild`; 36 tests reported 175 issues.
- [x] Before W1 production wiring, add a deterministic failing test showing external closure drift cannot satisfy the new owned-runtime production contract.
- [x] Download only `https://nodejs.org/dist/v26.7.0/node-v26.7.0-darwin-arm64.tar.gz`, `SHASUMS256.txt` and `SHASUMS256.txt.sig` into ignored staging. Archive SHA-256 and signer fingerprint matched exactly.
- [x] Extract only Node and its license after signature verification; archive paths, duplicates and selected file kinds passed.
- [x] Record upstream `file`, `lipo`, `codesign`, designated requirement, CodeDirectory flags and entitlements before execution. Exact checksum/signature/arm64/hardened-runtime checks passed; upstream execution was denied because `get-task-allow`, disabled library validation, DYLD environment and executable-page protection exceptions violate decision 19.
- [x] Apply decision 20 to two staged copies. Both produced full CodeDirectory SHA-256 `da0ef1cc83b51b610819c85f6275a043ec2af3e14ad02b0e715578694efd0b5c`, identical whole-file SHA-256 `578a6822daab86d3ceb7c85f0c9885e4e6f9b6cd521422344bbb4f53d512cf3a`, exact entitlement digest `7faab808f2696c84032a67166b79e0d9b49128fcf990cdcf696383ac62558a08`, strict signatures and system-only Mach-O closure.
- [x] Re-signed Node `v26.7.0`, bounded JavaScript/WebAssembly JIT, built-in module load, Pi CLI `0.84.2` and SDK import passed in a rebuilt clean environment.
- [x] A disposable hardened ad hoc app passed strict deep validation; outer signing preserved the Node CodeDirectory and the in-bundle JIT probe passed.
- [x] Stage cached Pi `0.84.2` with npm lifecycle scripts and network disabled. Exact 14,543-entry tree, digest `ded47bd3a428cce5a379b70b7f8e398e8b18b86498d3e75cd41e472fbfc9c25a` and all critical hashes passed.
- [x] Produce canonical manifest proposal SHA-256 `fdff34c9b2a91d7426930a17dee3ac4c8a7029aaff4281bbfbfafd046d2be678`. Qualified staging is 283,264 KiB, including 142,112 KiB for Pi.

### W1: Release manifest and resolver authority

- Scope: new `Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift`, focused changes to `PiRuntimeResolver.swift`, new `Resources/Pi/runtime/release-runtime.json`, manifest tests.
- Excluded: production call-site rewiring and package scripts.
- [x] Define the minimal schema and canonical encoder/decoder with exact key sets, bounded values and relative-path grammar.
- [x] Add a compiled expected manifest digest and a test that recomputes it from the source manifest.
- [x] Validate exact root inventory, Node CodeDirectory/content identity, exact identifier/team/entitlements, Pi package tree, internal symlinks, licenses, modes, ownership, ACLs, link counts and before/after descriptor evidence.
- [x] Reuse the existing package-tree and Mach-O parsers instead of duplicating hash or closure rules.
- [x] Validate the containing app with strict all-architectures, nested-code, strict and restrict-symlinks flags, then validate Node against the manifest's designated requirement and entitlements policy.
- [x] Return `PiResolvedRuntime` with explicit release identity/provenance and no external dynamic-library environment requirement.
- [x] Keep the existing external resolver internal to negative tests and diagnostics; make no production initializer capable of selecting it.

### W2: Production wiring and one runtime identity

- Scope: `ApplicationEngineClient.swift`, `JidokaCodeEngineMain.swift`, `ProductionEngineJobRuntime.swift`, `ProductionEngineExternalServices.swift`, `PiModelCatalog.swift`, `PiRPCWorkflowExecutor.swift`, `PiTUIRuntime.swift`, probe CLIs and corresponding tests.
- Excluded: Herdr descriptor schema, package assembly.
- [x] Add one validated release-runtime root to app and engine path discovery. Release builds require it inside the same bundle; DEBUG tests use only internal explicit fixtures.
- [x] Construct one release-owned resolver and pass it through every production component rather than reconstructing an external standard resolver.
- [x] Execute model discovery, RPC and TUI directly from the read-only owned runtime. Remove private materialization where it is no longer needed; retain the old materializer only for focused legacy/negative tests if useful.
- [x] Ensure child environments contain writable HOME, agent, session and temp paths but no Homebrew path, no runtime-root write permission and no DYLD override.
- [x] Make preflight errors distinguish missing, malformed, unsigned and drifted release runtime without leaking absolute private paths.

### W3: Herdr descriptor and restart authority

- Scope: `PiTUIRuntime.swift`, `HerdrHostRuntime.swift`, `HerdrPiWorkflowExecutor.swift`, protocol tests and replacement/restart tests.
- Excluded: q5 and Resume changes.
- [x] Version the Pi TUI/Herdr descriptor to include canonical runtime root and release identity.
- [x] Independently resolve and compare the exact descriptor-bound runtime at each named boundary: initial descriptor construction, decode, recovery/retry reconstruction, replacement candidate creation, replacement execution before credential installation, and final proof immediately before send-start authority.
- [x] Fail old v1 external-runtime descriptors closed. Add an explicit operational note that release installation requires quiescence; do not invent cross-release resume.
- [x] Prove descriptor/root/identity field drift, coordinated manifest/tree drift and release-A to release-B reconstruction all deny before credential or remote effect.
- [x] Prove existing descriptor/configuration/q4 digests change when runtime identity changes and no new unbound field exists.

### W4: Offline package assembly and inventory

- Scope: `scripts/package-app.sh`, `scripts/package-installer.sh`, `scripts/spikes/test-s1-package.sh`, `Packaging/app-inventory.txt`, Make targets and packaging tests.
- Excluded: Developer ID use, notarization, installation and publication.
- [x] Require one canonical `JIDOKA_RELEASE_RUNTIME_ROOT`; reject absence, symlink, unsafe ownership/mode, unvalidated identity and any path inside the checkout source tree other than ignored `build/` staging.
- [x] Package assembly performs no curl, npm, brew or other network/package-manager operation.
- [x] Validate the runtime with a release-built Jidoka verifier before copy and again at the W4/W6 assembled ad hoc bundle path.
- [x] Validate the exact upstream Node input, copy it, remove only the copied signature and re-sign the copy using decision 20. Assemble and ad hoc sign only a W4/W6 test bundle in the W0-proven order, then prove the manifest-bound CodeDirectory remains exact. Never mutate the upstream staging input.
- [x] Replace the five-executable mode assumption with exact static modes plus manifest-derived runtime modes.
- [x] Permit only internal, manifest-bound Pi symlinks and continue rejecting every other bundle symlink.
- [x] Merge static inventory with the inventory emitted from the already validated runtime tree; compare exact app tree, installer payload, metadata and BOM.
- [x] Add mutation cases for Node, Pi, manifest, mode, extra file, symlink escape, signature and generated inventory.

### W5: Hermetic source and production-path tests

- Scope: `PiRuntimeResolverTests.swift`, `HerdrPiWorkflowRuntimeTests.swift`, application/engine/protocol tests and small test fixtures.
- Excluded: committing real runtime binaries.
- [x] Replace `systemRuntime` as an ordinary source-gate dependency with a synthetic release-owned runtime fixture. Keep external resolver coverage deterministic and isolated.
- [x] Drive all 36 Herdr workflow tests and the 51 drift plus 28 fault matrices through the production release-owned resolver seam, not `fastRuntime` shortcuts at the behavior under review.
- [x] Add one explicit revalidation assertion and call-count oracle for each finite boundary named in Acceptance criteria: both startup preflights, model catalog, RPC, TUI host, initial Herdr preparation, Herdr recovery/retry, descriptor construction/decode, candidate creation, pre-credential execution and final pre-send proof.
- [x] Prove tests stay green with `/opt/homebrew/bin/pi`, `/opt/homebrew/bin/node`, `/usr/local/bin/pi` and `/usr/local/bin/node` absent or divergent by injecting a denied external lookup and observing zero access.
- [x] Test strict signature behavior with injectable internal validators plus an S1 executable artifact. Do not claim synthetic signature tests prove Developer ID behavior.
- [x] Preserve the 155-unrelated-job oracle, terminal restart reconstruction, credential cleanup and no-replay/q5 assertions.

### W6: Source completion gate

- [x] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/verify-toolchain.sh`.
- [x] Run shellcheck and syntax checks for every modified script.
- [x] Run focused release-runtime, descriptor, production composition and package-manifest tests.
- [x] Run the complete `HerdrPiWorkflowRuntimeTests` without temporary Homebrew or Pi aliases.
- [x] Run `make check` serialized.
- [x] Run S10 if its source-only preconditions remain applicable.
- [x] Run recursive strict Swift format, debug build, release build, test inventory and `git diff --check` after the last edit.
- [x] Route fresh architecture, security and test reviews against the explicit decision-21 threat model. Zero unresolved Critical/Major within that locked threat model is required.
- [x] Update this plan and the 2026-08-24 completion plan with exact evidence and remaining W7 boundary.

### W7: Separately authorized real package and release evidence

- [x] Build the actual runtime-bearing app with the qualified artifact and explicit signing identity. Re-sign Node with the Jidoka Developer ID, fixed identifier/options/entitlements and no timestamp-dependent field in the compiled runtime identity.
- [x] Bind the controlled ad hoc Node CodeDirectory `da0ef1cc…0b5c` and deterministic Developer ID CodeDirectory `5bc21eac…25df` as distinct schema-2 manifest authorities; production requires the latter plus the app Team Identifier.
- [x] Verify the final Developer ID Node signature, exact two entitlements, WebAssembly/JIT, three arm64/universal native modules, Pi CLI `0.84.2`, SDK import, S1, and credential-free S4/S8 preflights with network denied where applicable.
- [x] Build, sign and notarize the installer; validate the copied component and expanded signed payload byte-for-byte, then inspect ticket, stapling, Gatekeeper, signature, payload and manifest schema 4.
- [x] Preserve S11 active-socket and S12 Resume as explicit exclusions. Neither is inferred from W7 package evidence.
- [x] Keep installation and installed execution separate. Authorization was later received, but the standard `/Applications` ancestor is group-writable and fails the locked production ownership policy; no install occurred.
- [x] Never infer W7 from ad hoc or synthetic W6 evidence.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Manifest parser | valid canonical manifest | exact typed identity | happy |
| 2 | Manifest parser | missing, extra, duplicate, reordered/non-canonical or oversized fields | fail closed | behavior+edge+error |
| 3 | Compiled anchor | manifest byte changed with otherwise valid JSON | digest mismatch | behavior+error |
| 4 | Coordinated attack | manifest and Node/Pi changed together | compiled anchor or signature rejects | behavior+error |
| 5 | Runtime root | extra, missing, renamed or wrong-kind entry | exact inventory rejection | behavior+edge+error |
| 6 | Runtime root | symlink/hardlink/ACL/owner/mode/ancestor attack | no authority | behavior+edge+error |
| 7 | Runtime TOCTOU | replace file or directory between inspect/read/final compare | descriptor evidence mismatch | behavior+error |
| 8 | Node | wrong architecture, CodeDirectory, identifier, team relation, entitlement digest or signature | no authority | behavior+edge+error |
| 9 | Node Mach-O | non-system absolute dependency or unbound relative dependency | no authority | behavior+error |
| 10 | Node execution | version, bounded JIT and module load | exact successful output | happy+smoke |
| 11 | Pi | critical byte, package metadata or package-tree drift | no authority | behavior+error |
| 12 | Pi symlink | internal exact link vs escaping/absolute/cyclic link | exact accepted, others denied | behavior+edge+error |
| 13 | Startup authority | app/local engine and engine helper preflights | each independently validates the same release identity | behavior+error |
| 14 | Process authority | model catalog, RPC construction and TUI host resolution | each revalidates owned paths; no DYLD/Homebrew | behavior+error |
| 15 | Herdr execution | initial prepare and recovery/retry reconstruction | each revalidates exact runtime identity | behavior+error |
| 16 | Replacement authority | descriptor create/decode, candidate, pre-credential execute and final pre-send proof | one assertion per boundary; drift denies before effect | behavior+error |
| 17 | q4 binding | runtime identity changes descriptor/config digest | old authorization rejected | behavior+error |
| 18 | Package input | exact pre-staged runtime | offline validated copy | happy |
| 19 | Package input | absent, unsafe, changed or checkout-leaking input | package fails before sign | behavior+error |
| 20 | Ad hoc bundle signing | W4/W6 assembled app and nested Node exact | strict ad hoc verification passes without implying W7 | behavior+happy |
| 21 | Ad hoc bundle signing | post-sign resource/manifest/Node/Pi mutation | strict verification and resolver fail | behavior+error |
| 22 | Inventory | static plus runtime tree equals app/BOM/payload | exact equality | behavior+happy |
| 23 | Inventory | one extra/missing runtime path or wrong mode | package test fails | behavior+error |
| 24 | Source isolation | all external candidates absent/divergent | full source gate unchanged | behavior+error |
| 25 | Existing replacement | 51 drift, 28 fault, restart, cleanup, 155 jobs | prior assertions remain green | behavior+edge+error |
| 26 | Real release | clean Developer ID signed bundle without Homebrew | S1, S4/S8 preflights, JIT/native/Pi probes, payload audit and notarization pass; S11/S12 and production install remain outside this gate | W7 smoke+behavior |

**Coverage:** 26 identified paths across manifest, filesystem, code signature, Node/Pi identity, production wiring, durable descriptor, package, inventory, source isolation and real release. W7 Developer ID/notary evidence is complete; S11/S12 and a non-renamable installed-production path remain explicit gaps.

**Exhaustiveness rationale:** The matrix is the union of trust-root selection, input shape, filesystem identity, executable identity, execution call sites, durable reconstruction, package transformation and release operation. Field and fault matrices are parameterized by field/boundary rather than multiplied pairwise.

## Review plan

- Planned routed agents: `pi-forge.architecture-reviewer`, `pi-forge.security-reviewer`, `pi-forge.test-reviewer` through protected pi-subagents routing. Database review was initially not required because no database or schema change was in scope.
- Final W6 execution: fresh direct-source `architecture-reviewer`, `security-reviewer` and `test-reviewer` passes, plus a direct-source database-impact review after the final credential-binding change. The package database route rejected its effective contract before launch and was not credited as evidence.
- Review artifact: exact source diff; canonical manifest and compiled anchor; resolver/descriptor excerpts; W0 artifact evidence; mutation matrix; package inventory and W4/W6 ad hoc signing logs; full source test logs; explicit W7 and production-install omissions.
- Critical/Major evidence gate: the parent verifies every finding against source and executable evidence, fixes supported blockers within budget, reruns all affected checks after the final edit, and stops with options if a real artifact or signing claim cannot be established.

## Budget

- Fix rounds: 4 initially. After the fourth round, the final architecture, security and test reviews found supported Major blockers; Max explicitly extended the budget on 2026-08-25 to as many bounded fix/review rounds as are necessary to reach zero unresolved Critical/Major findings.
- Delegated launches: 12 initially. The same 2026-08-25 authorization extends launches only as required by those additional one-writer fix rounds and independent post-fix reviews.
- Writer concurrency: 1 in this checkout. The parent alone owns integration, Git, plan updates and external operations.
- Final evidence: toolchain verification; modified-script shellcheck/syntax; focused runtime and descriptor tests; full Herdr runtime suite; serialized `make check`; applicable S10; recursive strict format; debug/release builds; test inventory; `git diff --check`; zero staged paths; original dirty-tree preservation.

## Risks and rollback

- Risk: controlled re-signing changes Node's whole-file SHA and could produce different CodeDirectories under ad hoc and Developer ID identities. Mitigation: bind code pages, identifier, flags and entitlement slots through the full CodeDirectory SHA-256; prove deterministic ad hoc signing in W0 and require exact Developer ID reproduction in W7.
- Risk: removing upstream entitlements breaks JIT or Pi. Mitigation: W0 runs bounded JIT, module and Pi probes before source edits; failure is a hard stop rather than permission broadening.
- Risk: outer app signing does not preserve or accept the controlled Node signature. Mitigation: W0/S1 verify exact nested/outer signing order and recheck CodeDirectory identity after outer signing.
- Risk: package size remains large because Pi has about 14,543 entries. Mitigation: measure W0 staged and compressed sizes; do not weaken tree coverage or invent runtime downloads to reduce size.
- Risk: bundle hashing on every authority boundary is expensive. Mitigation: measure focused tests; cache only immutable descriptor evidence and always recheck vnode/ctime/signature before reuse. Never cache a Boolean authorization across a mutation boundary.
- Risk: descriptor versioning strands in-flight jobs across an app update. Mitigation: fail closed and require quiescence before W7 installation; terminal durable reporting remains readable without replay.
- Risk: real runtime licenses are incomplete. Mitigation: bind exact license inventory and stop W0 before packaging.
- Risk: the 109-path dirty tree hides accidental changes. Mitigation: preserve baseline, inspect exact changed paths after every workstream, zero staging and never discard unrelated work.
- Accepted residual: a deliberately hostile trusted child can evade polling and POSIX process-group cleanup by forking, allowing its leader to exit before observation, reparenting, and calling `setsid`. Mitigation within the selected threat model is limited to exact release/repository trust, PID plus start-time identity, cleanup of observed descendants and fail-safe refusal to signal reused identities. This is not non-escapable containment and must be revisited before untrusted repository execution is considered safe.
- Rollback: revert only this plan's source/package changes and reinstall the prior complete app release. No database rollback is required. Runtime artifacts staged under ignored `build/` are deleted by exact owned-path cleanup. Rollback is described, not authorized.

## External side effects

- Authorized: source/test/package-script edits; bounded public download of the exact official Node release archive plus checksum/signature into ignored `build/`; controlled ad hoc re-signing of staging copies under decision 20; use of the local cached Pi package; local synthetic/ad hoc tests. No global install or Homebrew mutation.
- Executed under later explicit authorization: Developer ID Application/Installer use, App Store Connect submission, notarization, stapling, Gatekeeper and local package evidence. No credential value or private key entered source, manifest or retained logs.
- Still not authorized or not executable: push, PR, product install, production process/socket/database action, q4/q5, Resume, deployment, publication or remote runtime update. Local commit was separately authorized; installed authority is blocked by the `/Applications` ancestor policy.

## Progress

- [x] Requirements refined: Max selected Hold Scope option 1
- [x] Verified current resolver, snapshot, call-site and packaging mechanics
- [x] Preserved exact Pi retry and Node-closure blocker evidence
- [x] Attempted independent opinion; one critic completed, panel synthesis failed
- [x] Analysis and draft plan
- [x] Fresh plan review; four Major issues fixed; re-review found no Critical/Major blocker
- [x] Max approval of this plan
- [x] W0 upstream acquisition validation; execution denied on forbidden upstream entitlements
- [x] Max selected controlled re-sign option 1
- [x] W0 controlled re-sign and artifact qualification
- [x] W1 release manifest and resolver
- [x] W2 production wiring
- [x] W3 Herdr descriptor/restart authority
- [x] W4 offline package assembly
- [x] W5 hermetic tests
- [x] W6 final source verification and review
- [x] W7 separately authorized real package evidence

## Surprises and discoveries

- Restoring exact Pi `0.84.2` did not reduce the 175 runtime issues. The earliest error changed the diagnosis from a Pi-only mismatch to the Node dynamic-library closure.
- Node `26.7.0` executable bytes remained attested while only three transitive Homebrew formula revisions invalidated the complete runtime. Exact security worked, but the authority source was operationally wrong.
- Existing private snapshots already prove a path-independent execution shape with local libraries, but their trust marker cannot be reopened without the vanished source runtime.
- Current package assumptions are much smaller than a real runtime: 66 static app entries versus a measured 20,588-entry snapshot.
- The independent critic did not reject the release-owned model. It exposed manifest anchoring and Node JIT/signing as preconditions that must be falsified before implementation commits to an artifact.
- The exact official Node archive passed SHA-256, GPG, Developer ID, arm64 and hardened-runtime checks but carried six entitlements, including `get-task-allow`, disabled library validation, DYLD environment and executable-page protection exceptions. Decision 19 stopped execution as designed; Max selected controlled re-signing.
- Controlled ad hoc signing with only the two JIT entitlements is deterministic for this artifact and remains stable through outer app signing. JIT, built-in module, Pi CLI and Pi SDK probes pass without DYLD or Homebrew runtime paths.
- Exact Pi reconstruction requires npm subprocess `umask 022`; `umask 077` preserves entry count but intentionally changes the package-tree digest through modes.
- Final security review found three independent Major defects after the first 642-test gate: readiness did not bind the live socket peer to the attested Herdr executable, fresh-retry authorization omitted the credential content/account binding, and accepted settlement masked process cleanup failure. The final bounded round fixed all three with direct behavior regressions; focused security re-review scored 100/100.
- W7 proved that ad hoc and Developer ID CodeDirectories cannot be one digest: the exact production value is `5bc21eacac48789dfa7e0c259516144a70a57362715cc8f241c658fc12fe25df`. Manifest schema 2 binds both modes without allowing transposition.
- Apple rejected the first W7 package because five Pi native Mach-O modules lacked Developer ID signatures and trusted timestamps. Qualifying those exact bytes with no entitlements produced signed Pi tree `534e4aa6ca73afbf31c48fc0c666978e3ab0114e7c1952f08ddae5139a9e9e37`; the replacement and final packages were accepted.
- Final review exposed a component-to-package payload race and stale S4/S8 release semantics. Exact component/final-payload validation, `payloadTreeSHA256`, explicit verifier builds, and exact release report assertions closed them; architecture, security and test re-reviews all scored 100/100.
- `/Applications` is root-owned but mode `0775` and the current user is in `admin`. Accepting it would violate the locked non-renamable ancestor policy, so installed production authority remains blocked rather than weakened.

## Execution decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Panel failure | Continue the plan with the completed critic evidence and disclose reduced confidence | The operation was not safely relaunchable; the code evidence is sufficient to make W0 a hard checkpoint |
| 2 | Completion speed | Stop reconstructing obsolete Homebrew versions and solve ownership once | Temporary global closure repair would consume time without surviving the next upgrade |
| 3 | Plan-review blockers | Fix all four Major issues before requesting approval | W0 trust, ad hoc versus W7 evidence and finite authority boundaries must not be decided by the implementation writer |
| 4 | Upstream Node entitlements | Controlled re-sign option 1 | Max selected the secure path after exact W0 evidence; accepting upstream entitlements would undermine W3 same-user resistance |
| 5 | Final-review budget exhaustion | Extend to all bounded rounds necessary for zero unresolved Critical/Major findings | The first four fix rounds removed four prior release blockers, but fresh final review demonstrated remaining source-hermeticity, production-signature, path-race, process-cleanup and test-oracle defects; stopping would leave W5/W6 knowingly incomplete |
| 6 | Immediate process-group escape | Accept as an explicit trusted-child residual instead of expanding W6 into sandbox/broker architecture | Max selected option 2 on 2026-08-26. Local macOS evidence supports `setsid` escape from process-group cleanup and did not establish a supported public non-escapable containment API; claiming closure from polling would be false |
| 7 | Final security findings | Fix all three verified Major defects, rerun the complete lifecycle, and require focused post-fix review | Peer binding, credential authorization and cleanup-error precedence are independent fail-closed boundaries; the post-fix architecture/security/test/database reviews found no unresolved Critical/Major |
| 8 | W7 CodeDirectory model | Version the canonical manifest and bind separate exact ad hoc and Developer ID CodeDirectories | Developer ID adds Team-bound CodeDirectory data, so equality with the ad hoc digest is impossible; mode selection is explicit and transposition fails closed |
| 9 | Pi native code | Prequalify the five exact Darwin modules with Developer ID, hardened runtime, trusted timestamp and no entitlements | Apple notarization rejected unsigned/ad hoc native modules; the signed complete tree remains release-owned and digest-bound |
| 10 | Package payload authority | Validate the copied component and the expanded signed product payload, then bind a deterministic payload-tree digest | Signing the archive alone did not prove that packaged bytes were the same bytes validated before packaging |
| 11 | Installed path | Keep production ownership strict and block W8 on standard `/Applications` mode `0775` | The current admin user can rename children of that ancestor without authorization; allowing it would contradict the selected same-user resistance policy |

## Outcomes and retrospective

W0 through W7 are complete under decision 21. Production authority resolves only release-owned Node `26.7.0` and Pi `0.84.2`, now bound by canonical manifest SHA-256 `fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83`, exact ad hoc/production Node CodeDirectories, signed Pi tree `534e4aa6ca73afbf31c48fc0c666978e3ab0114e7c1952f08ddae5139a9e9e37`, strict signature/entitlement policy, descriptor-relative tree verification and finite call-site revalidation. Homebrew, PATH and external runtime selection have no production execution authority.

Final W7 artifact: `build/settings-guided-w7-release-owned-runtime-71023263-uat-notarized/Jidoka Code.pkg`, SHA-256 `7102326303e2fe1f1394c42b4f919351f14ec3c37f5ac26dd962ac23c83ab0cb`; package manifest SHA-256 `3e1d62dd237383e39724992946e0735e32e7819391904630c0d0fe318fd9608a`; payload-tree SHA-256 `40e12b9c8da810ef19f5b19d606310e29263fda379916d85441842bea8fbfea4`; notarization submission `9ed36ebb-a727-451c-90fe-8124041387e2`, status `Accepted`. Stapler, Gatekeeper, Developer ID Application/Installer timestamps, component/final-payload equality, Node JIT/WebAssembly, native loading, Pi CLI and SDK passed.

Fresh after the last source edit: S1 package E2E passed; `make jidoka-code-w7-acceptance` passed 646 tests in 78 suites, S10 with `keychain:0,network:0,provider:0,service_management:0`, and S4/S8 credential-free preflights with `providerCalls=0`; `git diff --check` passed. Final architecture, security and test re-reviews each scored 100/100 with zero W7 Critical/Major/Minor.

No Homebrew mutation, product installation, production database/socket/process mutation, active-socket S11, Resume S12, q4/q5, push, PR or publication occurred. Installed execution is blocked because standard `/Applications` mode `0775` violates the non-renamable ancestor policy. Decision 21's immediate hostile `fork`/leader-exit/reparent/`setsid` escape remains an accepted residual and is not represented as closed containment.
