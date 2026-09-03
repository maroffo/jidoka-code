# Jidoka Code production-readiness fast path

**Status:** W0 root-owned UAT preparation authorized; probe tooling implemented locally, fresh W5 gates and signed static audit pending
**Origin:** in-session request from Max on 2026-08-27
**Base:** `feat/settings-guided-configuration` at `944f4f489e732f871e749cfd61c6b2d7e3324343`
**Goal:** Produce one new notarized release that installs the complete application under a non-renamable authority, qualifies the exact current macOS 27 Git and Herdr 0.8.2 runtime, migrates production from schema 8 to 9 while continuously paused, rolls the stale four-host topology into a fresh generation without replaying remote effects, and settles one exact q4. Leave q5 and Resume behind one final queue-disposition plan and separate authorization.

**Critical path:** W0 read-only reproduction plus one separately authorized root-owned UAT package-pair rehearsal; W1 through W4 in one source cycle; W5 executable cutover runbook and final source gate; W6 one production signing/notary cycle; W7 installed-and-paused checkpoint; W8 one fresh generation and q4; W9 queue decision and Resume plan. Analysis may run in parallel, but source and package integration keep one writer. The one-notarization claim is invalid unless the W0 UAT clean-install, location-upgrade, exact-path lifecycle and containment rehearsal passes before W6.

## Analysis (verified 2026-08-27, do not re-derive without new evidence)

### Current behavior

- W0 through W7 of the host-replacement release are complete. The current notarized package is `build/settings-guided-w7-release-owned-runtime-71023263-uat-notarized/Jidoka Code.pkg`, SHA-256 `7102326303e2fe1f1394c42b4f919351f14ec3c37f5ac26dd962ac23c83ab0cb`, but W8 is blocked before mutation (`quality_reports/plans/active/2026-08-24_architecture-host-replacement-completion.md:198-210`, `quality_reports/plans/active/2026-08-25_release-owned-hermetic-pi-runtime.md:325-329`). A fresh read-only hash reproduced that package identity.
- The release resolver requires a direct `.app` and binds `PiRuntime` to the containing bundle at `Contents/Resources/PiRuntime` (`Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift:526-568`). In production it traverses every installed path component descriptor-relatively with `O_NOFOLLOW` (`Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift:569-612`) and requires every directory to be UID 0, free of allow ACLs, and not group/other writable (`Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift:731-748`). The recursive runtime tree has the same ownership/write constraints plus link-count and identity checks (`Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift:614-727`). These checks are not to be weakened.
- The current package fixes `INSTALL_LOCATION=/Applications`, places `Jidoka Code.app` at the component/payload root, and records `/Applications/Jidoka Code.app` in its manifest (`scripts/package-installer.sh:22`, `scripts/package-installer.sh:273-279`, `scripts/package-installer.sh:358-367`, `scripts/package-installer.sh:619-631`). The component is non-relocatable and strict-identifier (`Packaging/app-component.plist:5-17`). S1 asserts those exact assumptions (`scripts/spikes/test-s1-package.sh:429-450`, `scripts/spikes/test-s1-package.sh:846-889`).
- Fresh host evidence still shows `/Applications` as `root:admin 0775`, with the current user in `admin`; PID `3325` still runs `/Applications/Jidoka Code.app`, and persisted role-host PIDs `54262` through `54265` are absent. This reproduces the documented blocker (`quality_reports/plans/active/2026-08-24_architecture-host-replacement-completion.md:198-210`).
- `/Library` is `root:wheel 0755` and `/Library/Application Support` is `root:admin 0755`, with no displayed allow ACL. `/Library/Application Support/JidokaCode` does not exist. Therefore `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app` is a viable candidate only if PackageKit creates both app-owned parent directories as UID 0, mode `0755`, no allow ACL, and later upgrades preserve those facts. This is measured host evidence, not yet installed acceptance.
- The installed PackageKit receipt is `com.maroffo.JidokaCode.pkg` version `0.1.0`, location `Applications`. The application also declares `CFBundleShortVersionString=0.1.0` and `CFBundleVersion=1` (`Packaging/Info.plist:17-20`). A secure-location successor must be a real versioned upgrade, not another same-version package with ambiguous receipt semantics.
- Jidoka currently accepts only Herdr `0.8.0`, protocol `19`, an exact executable digest and the bundled `api-schema-0.8.0.json` (`Resources/Herdr/runtime-builds.json:4-9`, `Sources/JidokaCodeCore/Herdr/HerdrProtocol.swift:62-63`, `docs/operations.md:5-15`). S11 and S12 reject any other version before their isolated fixture work (`scripts/spikes/test-s11-herdr.sh:40-41`, `scripts/spikes/test-s12-pi-tui.sh:58-59`).
- The host has only Herdr `0.8.2`; exact executable SHA-256 is currently `3e0f0c2d5edc41f592963ef90f5d872db801cc7dbd0e01731023897ee428904a`. Its API schema reports protocol `20`, SHA-256 `c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150`, retains every method constant from the 0.8.0 schema and adds `pane.input.set`. This makes 0.8.2 the fastest candidate, but response semantics still require the complete protocol and S11/S12 gates.
- Production Git execution is fixed to `/usr/bin/git` (`Sources/JidokaCodeCore/Git/GitTransport.swift:195`, `Sources/JidokaCodeCore/Git/VerificationCommandRunner.swift:647-650`). The local spike expects Git SHA-256 `179301dcb41ea78accc3fa0048a7e6f6710d891945a751a34addd622020c1818` and git-http-backend SHA-256 `4026051f87a437197a913d4ca5d3196f1d749bf6060f84c74cc374263988110a` (`scripts/spikes/jidoka-local-spikes.mjs:23`, `scripts/spikes/jidoka-local-spikes.mjs:53-62`). On macOS `27.0`, `/usr/bin/git` is Apple Git `2.54.0 (157)` with SHA-256 `1685f2c90307faa05ef5ae8f707d3a18a519c9dad75882768f66abb475f1b3d7`; git-http-backend still matches. S5-S7 therefore fail closed for one exact, reproduced reason.
- The production database remains schema 8 and `paused=1`, mode `0600`, with `integrity_check=ok` and zero foreign-key violations. The amended source schema 9 now has 76 statements and digest `48201824a919a208a72eccea6a626b2a560e2cd93b0686e390e949045bbb7751`; all 76 statement cuts have focused rollback evidence. This source evidence is not production migration authority; a fresh schema-8 backup remains required immediately before the real migration.
- When Herdr readiness is ready, production startup calls `recoverDurableState`; otherwise it recovers results only (`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:269-278`). Recovery classifies missing hosts, invokes exact topology invalidation, marks role hosts and their job binding `lost`, and does not need to signal an already absent process (`Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:1744-2056`, `Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift:2278-2365`). A lost/closed job binding can advance only to generation plus one (`Sources/JidokaCodeCore/State/PiRunStore.swift:538-607`), and existing tests prove durable role results can replay into that new generation without a second child launch (`Tests/JidokaCodeCoreTests/HerdrPiWorkflowRuntimeTests.swift:1640-1715`). The exact four-host, q1-q3-to-fresh-q4 production shape is not yet one test.
- Fixture S11 and S12 are necessary regression evidence but do not prove the active production socket or authorize production Resume. `make test-e2e` runs S1, S10, S11 and S12, while `make jidoka-code-w7-acceptance` runs the complete source gate plus S10 and credential-free S4/S8 preflights (`Makefile:10-18`, `Makefile:72-78`). Resume remains a global admission event over the 155 queued jobs, not a one-job canary (`quality_reports/plans/active/2026-08-17_single-job-canary.md:10-35`).

### Root cause or design gap

The existing release is byte-qualified but encodes three host assumptions that are no longer true: a group-writable installation parent, Herdr 0.8.0/protocol 19, and the previous `/usr/bin/git` shim digest. W8 also couples package installation to a historical four-process topology that no longer exists. Installing the old package, allowing `/Applications`, changing only one digest, or recreating historical PIDs would turn observed drift into authority. The shortest defensible path is to combine the secure application location and both current-host compatibility qualifications into one new release, prove the existing lost-to-next-generation recovery on the exact four-host canary shape before packaging, then separate installed-and-paused acceptance from q4 and from Resume.

### Scope

- In: version `0.1.1`/build `2`; complete app installation at `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app`; PackageKit component/payload/receipt evidence; exact Herdr 0.8.2/protocol 20 qualification; exact current macOS 27 Git qualification; stale four-host recovery into generation plus one; schema-8-to-9 rehearsal and migration; installed runtime/signature/path probes; active-socket readiness; one exact q4; operations and fail-safe containment evidence.
- Out: an exception for `/Applications`; changing global `/Applications` permissions; a user-writable alias or launcher; release-owned Git or Herdr; dynamic PATH discovery; multi-macOS compatibility certification; q5; Resume; broad queue execution; provider/GitHub publication; hostile-child containment beyond decision 21; push, PR, promotion, cleanup or deletion of historical artifacts.
- Recover excluded context from: `quality_reports/plans/active/2026-08-24_architecture-host-replacement-completion.md`, `quality_reports/plans/active/2026-08-25_release-owned-hermetic-pi-runtime.md`, `quality_reports/plans/active/2026-08-17_single-job-canary.md`, and `docs/operations.md`.

### Candidate approaches

| Approach | Decision | Evidence and trade-off |
|---|---|---|
| Install the complete app beneath `/Library/Application Support/JidokaCode/Applications` | chosen | Preserves the current bundle/runtime binding and every ancestor check. Existing system parents are root-owned `0755`; the package must own and attest the two new parents. Exact launch, login item, XPC, upgrade and containment behavior remain W0 falsifiers. |
| Accept root-owned app bytes under `/Applications 0775` | rejected | The current user can rename the directory entry. Signature checks do not make the path stable across validation and launch; this directly reverses locked W8 decision 17. |
| Change `/Applications` globally to `0755` | rejected | Broad privileged host policy, affects unrelated installers and can drift after OS/management changes. It is not application-owned authority. |
| Keep UI in `/Applications` but move only Node/Pi or add a privileged helper | rejected for this release | Splits release authority and leaves launch confusion or a new IPC/confused-deputy boundary. More source and review cost than moving the already bound complete bundle. |
| Restore exact Herdr 0.8.0 | rejected for this draft | The exact old executable is absent, while 0.8.2 is present and its schema method set is additive. If W1 falsifies protocol 20, stop and amend this plan with an independently acquired and qualified 0.8.0 artifact; there is no implicit Homebrew or network fallback. |
| Qualify exact Herdr 0.8.2/protocol 20 | chosen | One current-host compatibility update in the same release cycle. No dual-version or compatibility fallback. Full S11/S12 and wire-fault suites remain mandatory. |
| Update the exact current `/usr/bin/git` digest | chosen for this host | Only the Apple shim digest changed; git-http-backend remains exact. This certifies the current production host, not every OS advertised by `LSMinimumSystemVersion`. |
| Ship release-owned Git now | rejected for speed | Better long-term portability, but adds a signed dependency closure, licensing and package/runtime authority work. Revisit before broad multi-OS distribution. |
| Install, migrate, recover hosts and execute q4 as one operation | rejected | These have different failure-containment boundaries. The plan stops and re-audits after each exact side effect. |

### Independent opinion

The required independent Expert Panel did not run. Automatic consent was disabled and made no provider call; the manual route then stopped before provider execution because local `pi-subagents` runtime `0.57.0` did not match the reviewed `0.37.2` contract. Reduced-confidence areas are PackageKit upgrade/location behavior, LaunchServices/SMAppService behavior outside `/Applications`, and Herdr protocol-20 compatibility. W0 executable falsifiers plus fresh architecture/security reviews are mandatory substitutes; they are not represented as an Expert Panel opinion.

Two read-only scout attempts returned useful repository evidence but exited non-zero because their requested `intercom` child tool was unavailable. The parent re-read and verified every claim used above; the scout runs are not credited as review acceptance.

A later local read-only reviewer also exited non-zero on the unavailable `intercom` tool but returned a substantive report. It correctly blocked the first draft because root-owned PackageKit/lifecycle behavior was deferred until after notarization, receipt rollback was promised without an executable artifact, the schema backup preceded process quiescence, active Herdr readiness followed the startup path that depends on it, and W7 lacked an exact runbook. This revision incorporates those findings through the W0 UAT package pair, fail-safe containment instead of fictitious receipt rollback, a post-quiescence backup, a prelaunch installed readiness probe, and a pre-W6 reviewed runbook. A final fresh `codex-exec` review attempt timed out after 600 seconds before producing a report and is not credited as evidence.

## Locked decisions

Append only. Reverse a decision with a new row that names the superseded row.

| # | Decision | Choice | Evidence/rationale | Revisit if |
|---|---|---|---|---|
| 1 | Threat model | Keep UID-0, no-allow-ACL, no group/other write and descriptor-relative traversal unchanged | `/Applications 0775` is the blocker, not a resolver defect | Never for this release |
| 2 | Installed authority | Entire app at `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app` | Keeps app, helper and embedded runtime under one existing authority model | W0 proves a required macOS API cannot operate there |
| 3 | Package-owned parents | Payload and BOM include `JidokaCode/Applications` as root-owned `0755`; install root is `/Library/Application Support` | Avoids relying on PackageKit's implicit creation modes | Expanded payload or real install cannot preserve exact metadata |
| 4 | Installer scripts | Keep zero lifecycle scripts | Existing package is declarative and fully auditable | PackageKit cannot create or upgrade the exact parent tree declaratively |
| 5 | Launch path | Launch and register only the exact secure bundle path; create no `/Applications` symlink or launcher | A writable convenience entry would reintroduce launch confusion | A separately authenticated launcher design is reviewed |
| 6 | Release version | Bump app/package to `0.1.1`, `CFBundleVersion=2`; keep package and bundle identifiers | Existing receipt is version 0.1.0 at a different location | PackageKit falsifier requires a different compatible version strategy |
| 7 | Herdr | Single approved build 0.8.2, protocol 20, exact executable and schema digests | Current host has no 0.8.0 and schema methods are additive | Any W1 used-method, response, fault or lifecycle test fails for protocol behavior |
| 8 | Git | Pin current macOS 27 `/usr/bin/git` and unchanged git-http-backend exactly | Closes reproduced host drift without PATH fallback | Multi-OS release becomes in scope |
| 9 | Release cycles | Integrate location, Herdr, Git and any required stale-topology fix before one W7 rebuild/notarization | Each changes signed payload evidence | A blocker cannot be resolved without a separately versioned release |
| 10 | Installed checkpoint | Prove install, migration and paused startup before topology recovery/q4 | Makes the first production checkpoint fail-safe and provider-free, without claiming receipt rollback | No safe separation exists in executable evidence |
| 11 | Stale hosts | Use existing lost-binding and generation-plus-one semantics; never recreate historical PIDs or reuse old q4 authorization | Current processes are absent and source already models lost generations | W4 proves the exact canary cannot reach a fresh generation truthfully |
| 12 | q4 | Generate one new digest-bound preview and authorization after installed/live re-audit; execute once and never replay ambiguity | Old evidence is stale and host identities change | Never for this incident |
| 13 | Resume | Excluded; first produce a separate plan that classifies all 155 queued jobs and q5 | Resume is global admission, not canary completion | Explicit queue policy and authorization exist |
| 14 | Current package | Preserve `71023263…` as W7 evidence only; never install it | Its PackageInfo targets the rejected authority | Never |
| 15 | Current-host scope | Certify macOS 27 production only; do not claim the plan validates all macOS 14+ variants | One exact Apple Git build is pinned | Multi-host distribution is requested |
| 16 | Concurrency | One source/package writer; parallel work is read-only analysis/review only | Avoids conflicting manifest, digest and package edits | Never during this plan |
| 17 | Production effects | Source work, signing, installation, process changes, migration, q4 and Resume remain separate authorization boundaries | Each has a different recovery point | Max explicitly combines named boundaries |
| 18 | Residual containment | Preserve decision 21's trusted-child model and disclosed `fork`/reparent/`setsid` residual | This plan changes deployment authority, not process sandboxing | Untrusted repositories enter scope |
| 19 | Pre-notary root rehearsal | Install a unique-ID probe package pair as root on the current macOS 27 host before W6 | No disposable VM is available; the probe pair exercises the same `/Applications` to secure-root receipt move without touching production IDs, app, DB or socket | A disposable macOS 27 VM becomes available and gives stronger isolation |
| 20 | Failure response | Promise fail-safe containment, not immediate service rollback or receipt rewind | No exact old installer/receipt restoration mechanism is qualified; claiming rollback would be false | A separately notarized rollback package and rehearsal are approved |
| 21 | Operational commands | Freeze a parameterized, reviewed cutover runbook and read-only audit tool before W6 | Prose-only W7 gates are not executable or repeatable | Never for this release |
| 22 | Herdr startup ordering | Add and run an installed-binary, DB-free, read-only readiness command before normal first launch | Startup chooses full topology recovery only when readiness is ready | An existing command is proven to supply the same exact evidence without opening/migrating the DB |
| 23 | W4 executability (supersedes decision 11's sufficiency claim, not its lost-generation policy) | Stop before W4/W5 pending approval of a two-phase append-only generation-rollover and successor-run authority | Source proves generation 2 is legal after loss, but q1-q3 and q4 remain immutably bound to the generation-1 run/host; no existing safe bridge exists | Max approves the durable authority model or chooses a different bounded response |
| 24 | UAT preparation and admin approval | Build and Developer-ID-sign the unique probe pair only after identity approval, then bind `STOP-UAT-INSTALL` to the freshly audited artifact-set and package digests | Static PackageInfo/BOM/signature evidence must exist before an exact privileged target can be approved; signing authority never implies installation | The signed static audit cannot produce a closed payload and cleanup set |

## Acceptance criteria

### Release candidate

- [ ] The current three failures are reproduced independently: `/Applications` authority, Herdr 0.8.2 versus 0.8.0, and `/usr/bin/git` digest drift.
- [x] A unique production-isolated probe pair proves root-owned PackageKit clean install, exact legacy lifecycle, explicit removal of the quiesced legacy app while preserving its `0.1.0` receipt, same-receipt `0.1.1` secure-root upgrade, repeat upgrade, exact parent owner/group/mode/ACL, no old/new duplicate, secure-path lifecycle, SMAppService register/unregister, XPC, safe containment and exact probe cleanup before production notarization.
- [ ] App `0.1.1` build `2` and package `com.maroffo.JidokaCode.pkg` target only `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app`.
- [ ] Expanded `PackageInfo`, BOM and payload contain exact root-relative parent/app paths, root ownership intent, `0755` directories, no relocation targets and no scripts; component and final payload inventories remain byte/mode/symlink identical.
- [ ] No `/Applications` symlink, alias, launcher, fallback or runtime search path exists.
- [ ] Herdr 0.8.2/protocol 20 exact executable/schema policy passes unit, protocol, readiness, S11 and S12 fixture suites; version, protocol, schema, executable and live-peer drift each fail closed.
- [ ] The installed app exposes one strict DB-free read-only readiness command that resolves the release runtime, resources, socket and live peer, produces bounded canonical evidence, and cannot start the engine, migrate/open production SQLite for writing, register services, acquire credentials or invoke providers.
- [ ] S5-S7 pass with the exact macOS 27 Git and unchanged backend, while either digest drift fails before network/provider/GitHub effects.
- [ ] The four-host/q1-q3 stale fixture proves generation 1 becomes lost, generation 2 is the only legal successor, immutable canonical q1-q3 failed-attempt lineage is consumed without new child/provider calls, and only a fresh generation-2 q4 descriptor can be authorized.
- [ ] A source-controlled `docs/operations/production-cutover-0.1.1.md` and read-only `scripts/production-readiness-preflight.sh` define exact paths, commands, timeouts, expected IDs/counts, evidence files, side-effect class and stop/containment action for every W7/W8 step. Post-W6 hashes are supplied through a generated evidence file, not a source edit.
- [ ] Fresh `make check`, `make test-e2e`, `make jidoka-code-w7-acceptance`, S5-S7 preflight/full local spike, S1, runbook/preflight-script checks, `git diff --check`, architecture, security, database-impact and test reviews pass after the final source edit.
- [ ] One new Developer ID package is notarized, stapled and re-audited from its expanded final payload. No production installation occurs during W6.

### Installed and paused production

- [ ] A fresh read-only audit proves the exact package, existing receipt/app/process state, schema 8, `paused=1`, integrity/FK, queue counts, canary state, q4/q5 zero and no new unknown intent.
- [ ] The exact old installed app has mode, signature/tree and SHA-256 archive evidence, but that archive is explicitly not treated as a PackageKit receipt rollback artifact.
- [ ] After exact quit/deregistration approval, PID `3325` is absent and no helper or SQLite writer from the old bundle remains. Only then is the authoritative fresh schema-8 `0600` backup created, synced and bound to source DB hash, integrity/FK, WAL/SHM disposition and canonical row inventory.
- [ ] Duplicate bundle-ID launch paths are removed from the active launch set without deleting old-app forensic evidence. Failure before migration has a tested stopped/paused containment state; immediate old-service restoration is not claimed.
- [ ] Interactive administrative installation produces the exact secure path; `/`, `/Library`, `/Library/Application Support`, `JidokaCode`, `Applications`, the app and PiRuntime all satisfy production ownership, ACL, mode and non-symlink checks.
- [ ] The installed app/helper/runtime bytes equal the notarized payload; Developer ID, timestamp, Gatekeeper, stapling, manifest, Pi tree, Node/JIT/native modules and SDK probes pass from cwd `/` with network denied.
- [ ] Before normal first launch, the installed DB-free readiness command binds the exact installed runtime, socket, peer PID/start/path/hash/code, Herdr 0.8.2/protocol 20, resources and capabilities. Passing isolated S11 alone is not accepted.
- [ ] Schema 8 migrates atomically to exact schema 9 from the post-quiescence `0600` backup; integrity and foreign keys remain clean. The old app is not relaunched after schema 9.
- [ ] Installed startup observes the same readiness evidence, keeps `paused=1`, runs no scheduler pass, makes no provider/GitHub call, and changes only the pre-authorized stale-topology rows demonstrated on the exact database-copy rehearsal.
- [ ] The DB-free active production-socket probe is repeated after startup and must match the prelaunch authority.

### Canary-ready production

- [ ] The old generation is durably terminal/lost without replay authority; unrelated jobs, repository ownership and credentials are unchanged.
- [ ] One fresh generation creates exact role hosts from new process/pane/executable evidence and reuses only canonical settled q1-q3 results.
- [ ] One new preview and explicit authorization bind the exact generation-2 q4 descriptor and all seven backing digests.
- [ ] Exactly one q4 settles through canonical SQLite result, acknowledgement and release; q5 remains zero, 155 unrelated jobs remain queued/undispatched, `paused=1` remains set, and no GitHub effect occurs.
- [ ] A separate Resume/q5 ExecPlan records the disposition of every queued job and the expected external-effect policy. Until approved and executed, report the system as installed, migrated and canary-ready, not live-unpaused production.

## Workstreams

### W0: Reproduce and kill cheap hypotheses

- Scope: read-only host inspection and package expansion first; then one separately authorized root-owned UAT probe-pair installation using unique non-production bundle, package, service, app and directory names.
- Excluded: production package ID/app/receipt/socket/database/process mutation; production app quit; source-policy weakening. The UAT admin install and exact cleanup are not authorized by plan approval alone.
- [ ] Record exact branch/tree, package/manifest/payload hashes, OS build, PackageKit receipt, `/Applications` and candidate-parent metadata, app/helper PIDs, database schema/pause/integrity, Herdr version/schema/digests, Git/backend digests.
- [ ] Run `make jidoka-code-test-s5-s7-preflight` and preserve the exact `/usr/bin/git` drift failure.
- [ ] Run S11 and S12 only far enough to preserve the exact Herdr 0.8.0-versus-0.8.2 failure; confirm no isolated session survives.
- [ ] Expand the current package and prove it has only `/Applications` authority. Do not install it.
- [ ] Build a unique probe package `0.1.0` at `/Applications/Jidoka Code Location Probe.app` and successor `0.1.1` at `/Library/Application Support/JidokaCode-LocationProbe/Applications/Jidoka Code Location Probe.app`, sharing only their unique probe package/bundle/service IDs. Mirror production non-relocation, component/BOM and parent metadata rules. Use the exact approved Developer ID Team so SMAppService/XPC code identity is representative, but do not notarize the probe; signing/network/admin effects require their own W0 approval.
- [ ] Before requesting admin approval, statically verify both probe `PackageInfo` files, component policies, payload paths, BOMs, signatures and exact cleanup targets. Reject any reference to production IDs, paths, DB or socket.
- [ ] The first Developer-ID pair (`c68ae65f…` / `e5cd855e…`, artifact set `a396fa90…`) is review-blocked and has no installation authority. Never install it; a corrected pair requires fresh signing approval, fresh hashes and a fresh review.
- [x] After exact approval, exercise clean `0.1.0` install, full legacy lifecycle, explicit verified removal of only the quiesced legacy probe while its receipt remains 0.1.0, same-receipt `0.1.1` secure-root upgrade, repeated `0.1.1` install, owner/group/mode/ACL/symlink checks, duplicate denial, secure full-path launch, SMAppService registration/deregistration and XPC. Preserve command/output/receipt evidence.
- [x] Exercise fail-safe containment: stop/deregister the probe, remove only exact probe paths, remove only empty probe parents, forget only the probe receipt, and prove production IDs/receipt/app/DB/socket unchanged. Retain hashed UAT evidence; do not claim this restores an old production receipt.
- [x] Falsify hidden literal `/Applications` coupling in XPC peer derivation, Keychain app derivation, lifecycle and app probes. The same signed binary passed exact lifecycle and peer validation from both legacy and secure paths.

### W1: Qualify Herdr 0.8.2/protocol 20

- Scope: `Resources/Herdr`, Herdr protocol/readiness/store source, package inventory, S11/S12 and focused tests.
- Excluded: production socket and Homebrew mutation.
- [ ] Replace the 0.8.0 schema resource and one-build policy with freshly generated canonical 0.8.2 evidence. Recompute every dependent digest and closed inventory.
- [ ] Update the single supported protocol/version in source and operator recovery text. Do not add dual-version fallback.
- [ ] Diff every Jidoka-used request/result/error schema, not only method names. Preserve unknown-field, malformed-frame, protocol, capability, process-info and topology fault tests.
- [ ] Add a strict installed-binary `--herdr-readiness-probe` command before normal app composition. It must resolve the release runtime and perform only bounded resource/socket/peer readiness, use a DB-free credentialless environment, and emit canonical evidence suitable for pre/post-launch comparison.
- [ ] Run focused `HerdrProtocolTests`, `HerdrRuntimeReadinessTests`, `HerdrHostRuntimeTests`, `PiRunStoreTests`, readiness-probe effect-denial tests and production composition tests.
- [ ] Run isolated S11 and S12 against exact 0.8.2. Verify session/process cleanup and zero production-socket contact.
- [ ] If any used 0.8.2 contract requires broad redesign, stop. Exact 0.8.0 restoration requires a separately amended acquisition/qualification plan and authorization; do not fetch or mutate Homebrew implicitly.

### W2: Qualify current macOS 27 Git

- Scope: `scripts/spikes/jidoka-local-spikes.mjs`, S5-S7 expectations, package inventory and targeted tests.
- Excluded: PATH fallback, Xcode Git substitution, release-owned Git, Homebrew mutation.
- [ ] Record `/usr/bin/git` version, file kind, SHA-256 and Apple code evidence; record `git --exec-path` and exact backend identity.
- [ ] Replace only the observed Git digest after qualification; retain the unchanged backend digest and exact paths.
- [ ] Recompute the packaged runner digest and every closed package/runtime inventory that covers it.
- [ ] Add/retain one-field Git and backend drift negatives that stop before opening a network listener or provider/GitHub path.
- [ ] Run S5-S7 preflight and full local spike under the existing bounded, local-only network trap.

### W3: Move the complete package authority

- Scope: `Packaging/Info.plist`, `Packaging/app-component.plist`, `scripts/package-installer.sh`, `scripts/spikes/test-s1-package.sh`, path-derived tests and operations docs.
- Excluded: resolver policy changes, installer lifecycle scripts, aliases, live installation.
- [ ] Bump app/package to `0.1.1`, build `2`; preserve identifiers and strict non-relocatable upgrade semantics.
- [ ] Make the component root contain `JidokaCode/Applications/Jidoka Code.app`; set install root `/Library/Application Support`; update component and expanded payload app paths accordingly.
- [ ] Bind parent directories as explicit payload/BOM entries with directory kind, `0755`, no symlink and unambiguous tab/LF/CR-safe inventory records.
- [ ] Bump the package-manifest schema and record the exact final app path plus parent-tree metadata digest. Derive all evidence from the expanded signed payload.
- [ ] Add negatives for `/Applications`, missing/writable/redirected parents, payload-path transposition, relocation records, duplicate apps, stale package version and component/payload parent mismatch.
- [ ] Prove `EngineXPCPeerValidator`, GitHub token authority, Bundle resource lookup, app/helper probes and lifecycle registration derive from the actual containing bundle, not a literal path.
- [ ] Update `docs/operations.md` with exact launch, registration, upgrade, duplicate-bundle and fail-safe containment procedure. Do not recommend `open -a`; use the exact secure bundle URL.

### W4: Prove stale topology advances without replay

- Scope: exact fixture and, only if executable evidence requires it, narrow recovery/store source. Prefer no schema change.
- Excluded: restoring historical PIDs, generic reset/clear/prime replay, q5, Resume, production mutation.
- **Resolved discovery:** the existing source could mark generation 1 lost and select generation 2, but it could not truthfully carry the immutable q1-q3 retry lineage into q4. Standard generation-2 execution created sequence 1; cross-generation reuse violated `pi_runs`, role-host and launch generation triggers.
- **Approved decision:** Max approved the two-phase append-only successor-run model on 2026-08-27. Migration 9 now adds generation-rollover authorization and successor-run lineage tables, keeps generation-1 rows immutable, creates four ordinary generation-2 hosts without Pi/provider calls, seeds only the authorized architecture host at offset 3, and permits one descriptor-bound q4 at sequence 4. Distinct Engine/CLI preview and execute commands exist for rollover and q4. Final recovery matrices and direct reviews remain pending.
- **Safe alternative:** narrow this release to installed-and-paused W7 and move rollover/q4 into a new approved ExecPlan. Do not relabel a generation-2 sequence-1 launch as q4.
- [x] Add production-shaped coverage spanning populated schema-8 migration/current-runtime reopen and an exact four-host q1-q3 fixture with q4/q5 zero and 155 unrelated queued jobs.
- [x] Prove recovery marks only those four hosts and binding lost, coordinator reconciliation is truthful, and no pane/process mutation is requested for absent identities.
- [x] Prove only generation 2 can bind next; generation 1 and old q4/retry/replacement authorizations remain unusable.
- [x] Prove q1-q3 canonical failed-attempt evidence is consumed without a new child/provider invocation, then construct a fresh generation-2 q4 preview. Missing or divergent attempt evidence stops.
- [x] Preserve the complete unrelated-state isolation digest, credential cleanup, q5/Resume denial and prepared/enqueued/settled restart/no-replay matrices.
- [x] Amend schema 9 with append-only successor authority, full peer/executable evidence, predecessor immutability, deferred run-lineage FK, runtime compatibility invalidation and 76 re-pinned migration cuts.

### W5: Freeze source and obtain direct review

- Scope: all W1-W4 source, tests, package policy and docs.
- [x] Run focused checks after each final W4 workstream edit.
- [x] Run `make check` with a command form recognized by the Pi Forge lifecycle gate: 657 tests in 78 suites passed.
- [x] Run `make test-e2e`, including exact Herdr 0.8.2 S11/S12 fixtures.
- [ ] Rerun `make check`, `make test-e2e`, `make jidoka-code-w7-acceptance`, S5-S7 preflight, S1 and both diff checks after the final UAT-tooling source edit. The prior 657-test W5 evidence remains historical until this rerun completes; full S5-S7 remains a separately signed gate.
- [x] Add `docs/operations/production-cutover-0.1.1.md` and `scripts/production-readiness-preflight.sh`, with source-controlled expected values in `docs/operations/production-cutover-0.1.1-expected.json`. The runbook names exact executable paths, package/DB/backup locations, receipt and LaunchServices queries, process/open-file checks, immutable/query-only SQL, expected cardinalities, network-denial method, readiness/q4 commands, timeouts, evidence filenames, side-effect class, stop condition and fail-safe containment command for each W7/W8 checkpoint.
- [x] Test that the preflight script is read-only, credential-safe, cwd/PATH independent, bounded and rejects missing/drifted values: `scripts/tests/test-production-readiness-preflight.sh` (fixture zero-mutation snapshot, closed exit codes 0/64/65/67 plus placeholder and uat-probe containment cases), wired into `make check`. Mutating runbook commands are documented, never executed by `make check`. A live `--stage static` run against real production passed with 23 checks and an unchanged DB byte guard.
- [x] Produce a redacted direct-source review artifact: `quality_reports/review/2026-08-27_w5-final/` (review-brief.md, tracked-changes.diff, status.txt).
- [x] Route architecture, security, database-impact and test reviews. All four worktree-isolated reviewers completed on the protected route on 2026-08-27 (several infrastructure stalls from machine sleep were resumed; no Pi Forge contract error occurred). Consolidated: 0 Critical; 5 accepted Major (probe error swallowing, unbounded pgrep, and three missing negative-coverage families in the preflight test), all fixed; 1 Major rejected with evidence (the claim that the 2s-to-5s bound raise was absent from the tree is disproven by `git diff 944f4f4`, which shows all three `startedAt < 2` to `< 5` edits; the reviewer's grep pattern could not match those lines); 13 consolidated Minor, 10 fixed (evidence-dir symlink/owner/ordering guards, uat-probe case/path normalization, fail-open quiesce rc handling, runbook evidence-mode rule, W9 schema-10 and single-incident notes, timeout-through-script test, snapshot widening, WAL fixture, uat/quiesced usage guard), 3 deferred to `quality_reports/plans/tech-debt.md` (socket-path constant hoist, trigger-message matching, exit-69 seam). All final gates rerun green after the last fix edit.

### W6: Build one new W7 release

- Scope: only after the root-owned W0 UAT clean-install/location-upgrade/lifecycle/containment rehearsal and W5 are green, and Max separately authorizes Developer ID/notary effects.
- [ ] Build from the exact reviewed tree and qualified runtime, never from the previous package or stale app output.
- [ ] Validate nested signatures, timestamps, Team ID, entitlements, complete native inventory, app/runtime/Pi tree and exact parent/payload inventories before and after package signing.
- [ ] Expand the final signed package and validate the exact secure payload path, PackageInfo, BOM, no relocation, no scripts, component/payload equality and manifest schema.
- [ ] Notarize once, staple, run Gatekeeper, then repeat network-denied Node/Pi/JIT/native/SDK and credential-free S4/S8 probes from final payload bytes.
- [ ] Freeze package, package-manifest and payload/parent-tree digests. Generate a mode-`0600` cutover-values evidence file containing exact package/payload hashes and identifiers consumed by the already reviewed runbook; do not edit source after signing. Re-review the rendered commands before requesting W7 approval. Stop without installation.

### W7: Controlled install, migration and paused acceptance

- Scope: separate Checkpoints A through F; each uses the frozen runbook, needs exact approval and begins with the read-only preflight.
- Excluded: host-generation creation, q4, q5, Resume, provider/GitHub effects. No checkpoint promises immediate old-service or receipt rollback; failure enters the declared stopped/paused containment state.
- [ ] **Checkpoint A, live evidence only:** record current DB hash/integrity/FK/WAL/SHM/row inventory, old app signature/tree/archive hash, production receipt, login registration, open files and process inventory. Do not treat this pre-quiescence DB copy as rollback authority.
- [ ] **Checkpoint B, quiesce and backup:** after exact approval, disable old login registration and quit only the old app/helper. Prove PID `3325`, helper processes and every SQLite writer/open writable descriptor are absent; prove role-host PIDs remain absent and production is paused/schema 8. Then create, sync and verify the authoritative `0600` schema-8 backup, binding it to exact source DB hash, integrity/FK, WAL/SHM disposition and row inventory.
- [ ] **Checkpoint C, install:** after exact interactive-admin approval, install only the frozen package. Before launch, validate receipt, exact secure path, ancestor ownership/modes/ACLs, payload equality, signatures and duplicate-bundle launch state. Stop in safe containment if PackageKit changes or removes anything outside the runbook's declared old/new app paths and receipt; do not improvise receipt rewrites.
- [ ] **Checkpoint D, prelaunch readiness:** run the installed full-path `--herdr-readiness-probe` from cwd `/` under the runbook's credentialless/network-denied environment. Bind socket/peer PID/start/path/hash/code, Herdr 0.8.2/protocol 20, capabilities, resources and release runtime. Stop before database migration on any drift.
- [ ] **Checkpoint E, migrate/start paused:** after exact approval and a final unchanged D probe, launch the secure app by full path. Accept only exact schema 9, the rehearsed absent-host recovery delta, no startup scheduler pass, no external effects and `paused=1`. On migration failure require either unchanged schema 8 or a stopped state pending separately approved DB restoration; after schema 9 never relaunch the old app.
- [ ] **Checkpoint F, installed probe:** repeat the DB-free readiness probe and require equality with D. Then run installed path/runtime/app/helper probes and recheck DB, q4/q5 zero, unknown intents, queue equality and pause.

### W8: Fresh generation and q4 only

- Scope: only after W7 evidence is accepted and separately approved.
- Excluded: q5, Resume and unrelated queue admission.
- [ ] Re-audit lost generation 1, active repository/socket authority, no live stale PID, credentials, exact canary/run/lease and 155 unrelated jobs.
- [ ] Create only generation 2 under the existing lost-to-next-generation rule. Bind every new role host to exact process/start/executable/code/pane/terminal evidence.
- [ ] Reconstruct the q4 lineage only from canonical durable q1-q3 failed-attempt evidence and prove zero provider calls.
- [ ] Generate one new q4 preview and present its exact digest and expected mutations for explicit approval.
- [ ] Execute once. Stop on any send-start ambiguity or cleanup uncertainty; never replay.
- [ ] Accept only canonical q4 result, acknowledgement and release. Prove q5 zero, 155 jobs unchanged, no GitHub effect and `paused=1`; then stop.

### W9: Define the final live-production gate

- Scope: a separate ExecPlan, not execution under this plan.
- [ ] Classify all 155 queued jobs as run, retire or investigate with exact counts and repository ownership.
- [ ] Decide whether q5 is required for the canary and bind its expected provider/GitHub effects.
- [ ] Specify capacity, monitoring, stop conditions, reconciliation and rollback-after-effect semantics for Resume.
- [ ] Obtain separate approval before q5, queue retirement, Resume or any broad external effect.

## Verification matrix

| # | Surface/path | Scenario | Expected evidence | Depth |
|---|---|---|---|---|
| 1 | Installed ancestor policy | `/Applications 0775`, candidate `0755`, writable/ACL/symlink/rename drift | unsafe path rejected; exact secure root accepted only when every descriptor fact matches | behavior+edge+error |
| 2 | Package layout | static payload plus root-owned probe clean install, receipt move, repeat upgrade and exact cleanup | one exact nested app, parents `0755`, no relocation/scripts/duplicate/transposition; production IDs unchanged | behavior+edge+error+operational |
| 3 | Bundle-derived authority | exact-path app, SMAppService, helper/XPC, token authority, resources and lifecycle | secure probe/bundle derives every path; literal/alias/duplicate path rejected | behavior+error+operational |
| 4 | Herdr policy | exact 0.8.2/20 and version/protocol/schema/executable drift | exact runtime passes; each one-field drift fails before topology effect | behavior+edge+error |
| 5 | Herdr protocol | every used request/result/error plus S11/S12 cleanup | protocol-20 behavior matches; malformed/fault paths remain fail-closed | behavior+edge+error |
| 6 | Git system runtime | exact shim/backend and one-field drift | current pair passes; either drift stops before network/effect | behavior+error |
| 7 | Migration | populated schema 8, every final cut, reopen/backup | exact schema 9 or unchanged schema 8; `0600`, integrity/FK clean | behavior+error |
| 8 | Stale topology | four absent hosts, one unexpectedly live, identity reuse, terminal unknown | only exact absent set becomes lost; live/ambiguous identities block | behavior+edge+error |
| 9 | Generation rollover | generation 1 lost, generation 2 creation, old authorization replay | only `generation+1`; old evidence denied; exact new host evidence required | behavior+error |
| 10 | Durable attempt-lineage reuse | q1-q3 canonical/missing/divergent | exact failed-attempt lineage is consumed locally; missing/divergent evidence stops without provider | behavior+edge+error |
| 11 | Installed runtime | signature, manifest, Node/Pi/native/tree and final revalidation | final payload identity passes from `/`; byte/path/signature drift fails | behavior+error+smoke |
| 12 | Paused startup | install/migration/reload with 155 jobs | no scheduler request/pass, provider or GitHub effect; pause remains 1 | behavior+edge |
| 13 | Active socket | DB-free prelaunch and post-start socket/peer/path/hash/protocol evidence plus drift | canonical readiness is equal across launch and passes only for the installed release/live peer | behavior+error+operational |
| 14 | q4 | fresh exact descriptor, every backing drift, send/first-effect faults | one canonical settlement or typed terminal ambiguity; no replay | behavior+edge+error |
| 15 | Isolation/denial | q5, Resume, unrelated state, cleanup failure | q5/Resume zero/denied; 155-job equality; cleanup failure cannot be masked | behavior+error |
| 16 | Upgrade/containment | duplicate old bundle, receipt move, pre/post schema-9 failure | UAT upgrade succeeds; production failure stops safely without false receipt rewind; post-quiescence DB backup is exact | operational+error |

**Coverage:** 16/16 identified families across filesystem authority, PackageKit, bundle/XPC, Herdr, Git, migration, stale recovery, generation, runtime, startup, socket, q4, isolation and containment. W0 provides a root-owned structural UAT install, but the exact production bundle/package/receipt path remains unverified until W7. Gap until W9: live Resume and q5 are deliberately unverified.

**Exhaustiveness rationale:** The matrix is the union of trust roots (path, code, runtime, socket), host compatibility dimensions (Herdr and Git), durable boundaries (migration, host generation, result reuse), irreversible steps (install, startup recovery, q4, Resume), and one-field drift/fault positions. Parameterized one-field and checkpoint tests avoid combinatorial repetition while covering every authority transition.

## Review plan

- Routed agents: `pi-forge.architecture-reviewer`, `pi-forge.security-reviewer`, `pi-forge.database-reviewer`, `pi-forge.test-reviewer`.
- Review artifact: exact base/head, complete changed paths and diff, candidate path/PackageInfo/BOM/payload evidence, Herdr 0.8.2 schema and wire comparison, Git qualification, stale-generation fixture, migration evidence, focused/final checks, package manifest and explicit side-effect boundaries.
- Critical/Major evidence gate: the parent reads each cited source location and reproduces executable findings where practical. Any accepted blocker is fixed by the one writer; affected focused checks and all final gates rerun after the last edit. No score alone is acceptance.
- Pre-install re-review: architecture and security inspect the final expanded signed payload and W7 runbook before Checkpoint A. Database review inspects the exact schema-8 copy rehearsal and expected startup delta.

## Budget

- Fix rounds: 3. Stop and re-plan if the same boundary fails twice for different assumed causes or if a fourth round would be needed.
- Delegated launches: 4 final source reviewers plus at most 2 focused re-reviews for accepted Critical/Major findings.
- Writer concurrency: exactly 1.
- Packaging cycles: one unique-ID root-installed UAT probe pair before source freeze, then 1 notarized production candidate. The UAT admin installation needs separate approval and must be cleaned exactly. A second production notarization requires a new decision.
- Final source evidence: `make check`; `make test-e2e`; `make jidoka-code-w7-acceptance`; S5-S7 preflight/full; S1; strict format/builds included by `make check`; `git diff --check`, all after the final source edit.
- Final installed evidence: exact package/payload/receipt/ancestor/signature/runtime probes, schema backup/migration/integrity, startup delta, active socket, q4 isolation and pause checks at their named checkpoints.

## Risks and rollback

- Risk: LaunchServices or SMAppService refuses or ambiguously resolves an app outside `/Applications`. Mitigation: W0 unique-ID root-installed lifecycle probe and exact-path launch only; stop before W6 if not proven. Never add a writable alias as a workaround.
- Risk: PackageKit's existing 0.1.0 receipt relocates, removes or leaves an ambiguous duplicate during the 0.1.1 location change. Mitigation: rehearse the same location/version transition with a unique probe receipt before W6, preserve exact old-app evidence, and stop after production install before launch on any mismatch.
- Risk: PackageKit changes parent owner/mode/ACL on creation or upgrade. Mitigation: explicit BOM entries, root-installed UAT descriptor evidence and immediate production descriptor audit before launch.
- Risk: no exact old production installer/receipt rollback is qualified. Mitigation: this plan promises stopped/paused fail-safe containment, not service restoration. If availability rollback is required, stop before W6 and prepare a separately signed/notarized rollback package and rehearsal.
- Risk: Herdr protocol 20 is not behaviorally compatible despite an additive method set. Mitigation: request/result/error schema diff and complete isolated S11/S12/protocol tests before package freeze; stop and amend an exact 0.8.0 acquisition plan rather than adding permissive negotiation.
- Risk: pinning macOS 27 Git leaves the package unusable after another OS update or on macOS 14-26. Mitigation: state current-host certification explicitly and fail closed. Long-term remedy is a separate multi-build policy or release-owned Git plan.
- Risk: startup recovery changes more durable state than the four absent hosts/binding. Mitigation: exact production-shaped copy rehearsal and pre/post canonical database inventories; stop on any extra delta.
- Risk: generation rollover needs a new schema transition. Mitigation: discover in W4 before package freeze; amend/re-pin all migration evidence or stop. Never patch production state manually.
- Risk: the old app is launched after schema 9. Mitigation: exact-path launch, old login-item deregistration, duplicate-bundle quarantine and old-helper fail-closed evidence. Database rollback requires the exact fresh schema-8 backup.
- Risk: q4 becomes ambiguous after send-start. Mitigation: typed terminal state, no replay, remain paused and preserve evidence.
- Accepted residual: trusted child processes can escape process-group cleanup through immediate fork/leader-exit/reparent/`setsid`. This plan does not claim hostile containment.
- Failure before migration: stop/deregister the new app, preserve schema 8 and both app/receipt evidence, and remain offline/paused. Do not use `pkgutil --forget`, manually rewrite receipts or relaunch the old app unless a separately qualified corrective/rollback package authorizes that exact state.
- Failure after schema 9: never run the old binary against schema 9. Database restoration uses only the post-quiescence schema-8 backup under a separately approved operation and still requires a coherent package/receipt recovery artifact.
- Failure after q4 or Resume: cannot erase external effects. Close further admission, preserve durable evidence and reconcile; Resume is therefore outside this plan.

## External side effects

- Authorized now: source-only implementation, plan updates, review and unprivileged local/disposable non-production verification under Max's 2026-08-27 approval.
- Consumed named approvals on 2026-08-28/29 covered exactly one corrected UAT Developer ID signing cycle with timestamp, the hash-bound probe PackageKit rehearsal, one explicitly approved retry after a malformed invocation, explicit legacy-probe removal, successor reinstall and exact UAT cleanup. They grant no standing authority for another signing, install or cleanup.
- Not authorized: commit, push, PR, production Developer ID signing or timestamp use, notarization, production PackageKit installation, production sudo/admin action, production login-item or app/helper/Herdr process mutation, production database migration/mutation, q4, q5, Resume, provider/GitHub effect, rollback, publication or historical cleanup.
- Every W6-W9 external boundary still requires its named exact approval.

## Progress

- [x] Verified repository, package, host, Herdr, Git and database blockers
- [x] Drafted the fast-path plan
- [x] Attempted independent Expert Panel; no provider run occurred because consent/runtime gates blocked it
- [x] User approval
- [x] W0 read-only falsifiers
- [x] W0 separately authorized root-owned UAT package-pair rehearsal, including explicit legacy-path retirement, secure-root lifecycle, reinstall and exact cleanup
- [x] W1 Herdr qualification
- [x] W2 Git qualification
- [x] W3 secure package source and unsigned layout
- [x] W4 stale-generation proof: source authority, migration, recovery, isolation, restart, q4 and denial matrices pass locally
- [x] W5 final source gate and reviews (runbook, expected values, read-only preflight plus tests shipped; four protected reviews consolidated and fixed; every final gate rerun green after the last edit)
- [ ] W6 one new notarized release
- [ ] W7 installed-and-paused production
- [ ] W8 fresh q4 canary
- [ ] W9 q5/Resume plan

## Surprises and discoveries

- The W8 path blocker is not the only current-host drift. Herdr has advanced from the approved 0.8.0/protocol 19 to 0.8.2/protocol 20, so S11/S12 cannot currently run against the approved policy.
- Herdr 0.8.2's exported method set is additive relative to 0.8.0, but this is not sufficient to claim wire compatibility; result/error shape checks remain mandatory.
- macOS 27 changed only the attested `/usr/bin/git` shim in the local-spike closure; the exact Xcode git-http-backend still matches. The plan therefore avoids a broader Git dependency redesign for this host.
- The existing PackageKit receipt is version 0.1.0 at `Applications`. Moving the same package identifier requires a real version increment and duplicate-bundle checkpoint.
- The corrected UAT's first successor install updated the receipt and installed the complete signed secure app but left the old cross-prefix payload in `/Applications`. Cleanup returned UAT and production to their exact baselines. A separately approved rerun proved the accepted sequence: lifecycle and archive-quality identity checks, explicit removal of only the quiesced legacy app while preserving receipt 0.1.0, successor install, 80-check post-install audit, secure lifecycle/XPC, reinstall, second 80-check audit and exact cleanup. Production before/after evidence is identical.
- Existing source already models lost job bindings and exact generation-plus-one recovery, including local replay of canonical durable results. The missing proof is the complete four-host q1-q3-to-fresh-q4 shape, not necessarily a new recovery architecture.
- Fresh W0 evidence is preserved at `/tmp/jidoka-w0-readonly.jnxs8T/audit.log`: schema 8, `paused=1`, 155 queued jobs, one `runningPi`, four absent persisted host PIDs, package `71023263…`, Herdr 0.8.2/protocol 20, Git shim `1685f2c9…`, and unchanged Xcode git-http-backend `4026051f…`.
- The packaged S5-S7 wrapper redacts the underlying attestation error as `runnerFailed(1)`. A credentialless direct invocation of the same qualified Node and source runner preserved the exact blocker `system runtime digest drift: /usr/bin/git`; S11 and S12 both rejected 0.8.2 before creating a session or evidence directory.
- W1/W2 now pass against Herdr 0.8.2/protocol 20 and the exact macOS 27 Git closure. S12 exposed and closed two stale fixture assumptions: release-owned Pi descriptors now require schema 4/identity-bound debug injection, and Pi 0.84.2 persists locked settings without the old `theme` key.
- W3 produced a real unsigned nested PackageKit product at `/tmp/jidoka-w3-unsigned-layout.zRjEnh`: exact PackageInfo path, no relocation, root:wheel `0755` BOM parent entries, component/payload equality and parent-tree digest `1655d216b6b4c7e2b25d0d00a4864612583f68a97f5b64ebde96e0e97bfb723f` passed. This is not root-installed UAT evidence.
- W4 falsified decision 11's sufficiency assumption. A lost generation-1 binding can advance to generation 2, but the existing q1-q3 run and launch authority cannot cross generations, while a new generation-2 host starts at sequence 1. Reusing or rewriting old rows would violate current Swift and SQL generation invariants.
- Read-only oracle run `e72d41ba-ea61-4997-9ee9-affbe3060dcd` found no missed safe path and recommended two append-only authority tables plus a successor run with prior-attempt count 3. It classified this as a material database/API decision requiring Max before implementation.
- The Expert Panel was unavailable for infrastructure reasons before provider execution. Confidence is intentionally recovered through cheap falsifiers and direct reviewers, not by pretending an opinion ran.
- A local reviewer blocked the first draft because its first root-owned install was post-notary, receipt rollback was undefined, backup preceded quiescence, Herdr readiness followed readiness-dependent startup, and production steps were prose-only. The revised UAT, containment, backup, readiness and runbook gates close those plan defects before user approval.
- `pkgutil --volume` does not resolve fabricated receipts on a fixture volume (verified 2026-08-27 with a byte-identical flat plist plus mkbom-generated bom). The W5 preflight therefore reads the flat receipt plist at `<volume>/var/db/receipts/<id>.plist` directly (key names PackageVersion/InstallPrefixPath verified identical to `pkgutil --pkg-info` output for the real production receipt); the runbook keeps pkgutil commands as independent checkpoint evidence.
- The first fresh `make check` of the final W5 round failed on a wall-clock promptness bound: `HerdrPiWorkflowRuntimeTests.swift:2847` asserts the fault path errors out in under 2s and measured 2.24s/2.69s under concurrent build load, while the identical suite passed when run alone. The three 2s bounds were raised to 5s (the real timeouts they guard are 30s+); no product code changed; all gates rerun green afterwards.
- W5 final gates, fresh on 2026-08-27 after the last edit: `make check` 657/78 green; `make test-e2e` S1+S10+S11+S12 green; `make jidoka-code-w7-acceptance` green (providerCalls=0); S5-S7 preflight green (120 mutation cases, cleanup verified); ad-hoc S1 green; `git diff --check` and `--cached --check` clean. Live static preflight against production: 23 checks PASS, schema 8, paused=1, 155/87/1 jobs, receipt 0.1.0 at Applications, secure root absent, Herdr/Git digests exact, DB byte guard unchanged. The whole battery was rerun a second time after the review-fix edits and is green again.
- A second load-marginal flake surfaced once during the post-fix acceptance rerun: `GitProcessTests` "timeout removes an observed session escape by PID and microsecond start time" threw `.cleanupFailed` after 10.5s (session-escape cleanup racing under full-suite load). The file is untouched since base `944f4f48`, the test passed 3/3 in isolation and the immediate acceptance rerun was green. Recorded as pre-existing flakiness, not fixed here: the tight budget lives in product cleanup code, and loosening product timeouts for a test flake is the wrong trade without a dedicated decision.
- A later host remount changed only the qualified runtime root `st_dev`, invalidating S12's stale fixed vnode-identity digest while manifest and bytes remained exact. S12 now derives one fresh identity through the independent release-runtime verifier and requires the prepared launch to match it.
- The first signed UAT pair passed the then-current static audit but a filesystem-capable security review blocked installation with seven Major findings: launchd-controlled `argv[0]`, missing client-side XPC peer authentication, pre-validation evidence-directory creation, self-reported package roots, incomplete installed payload/signature checks, Team-only rather than exact certificate validation, and unbound audit evidence. Its hashes are permanently non-installable; corrected source is verified ad hoc before any separately approved second signing cycle.
- The exit-68 negative exposed a real preflight defect the first suite run: `sha256_of` remapped an inner bounded-timeout exit 68 to prerequisite exit 66. Fixed by propagating already-reported closed codes; the test now pins 68 through the script.

## Execution decisions

Append only.

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Delivery strategy | One combined source/package release | Location, Herdr and Git all invalidate signed payload evidence; combining them avoids repeated notarization |
| 2 | First production milestone | Installed, schema 9 and paused before any fresh host/q4 work | Separates fail-safe install/migration containment from workflow effects |
| 3 | Stale topology strategy | Prove lost-to-generation-2 recovery and canonical q1-q3 reuse | Historical PIDs cannot be restored or treated as authority |
| 4 | Live activation | Stop after q4 and write a queue-disposition/Resume plan | The remaining 155 jobs are a separate global-effect decision |
| 5 | Root install evidence | Use a unique-ID UAT package pair on the current host before production notarization | No disposable VM is available; production IDs and state remain out of scope |
| 6 | Failed deployment | Contain offline/paused instead of claiming receipt rollback | No exact old installer or tested receipt rewind exists |
| 7 | Startup readiness | Probe installed runtime/socket/peer before and after normal launch | `recoverDurableState` is readiness-dependent and must not be selected nondeterministically |
| 8 | Source authorization | Execute W1-W5 locally, but stop before every named external boundary | Max approved the ExecPlan while expressly withholding commit, publication, signing, admin install, production mutation, q4/q5 and Resume |
| 9 | W4 authority gap | Pause implementation before W4/W5 and preserve W1-W3 | Existing generation-plus-one state is truthful but cannot carry immutable q1-q3 lineage into one logical generation-2 q4; the proposed fix adds durable tables and Engine/CLI commands |
| 10 | W4 successor authority | Approved by Max's “andiamo avanti” on 2026-08-27: two append-only phases, topology rollover then separately authorized q4 | Preserves immutable generation-1 failed-attempt history, keeps q5/Resume denied, and avoids relabeling a generation-2 sequence-1 launch as q4; “reuse” means consuming lineage metadata, never synthesizing result rows or replaying effects |
| 11 | W5 preflight receipt source | Read the flat PackageKit receipt plist directly instead of `pkgutil --volume` | `pkgutil --volume` cannot resolve fixture receipts, which would make the preflight untestable; key parity with `pkgutil --pkg-info` verified on the real receipt; runbook retains pkgutil as independent evidence |
| 12 | Promptness-bound flake | Raise the three 2s wall-clock bounds in `HerdrPiWorkflowRuntimeTests.swift` to 5s | Demonstrated 2.24s/2.69s failures under load with the identical suite green when quiet; the bound guards against 30s+ hidden timeouts, so 5s keeps the guard meaningful |
| 13 | UAT signing boundary | Max authorized Keychain identity discovery and Developer ID/timestamp preparation for the unique probe pair; the sole valid identities are Application `42168752E0FB74059B87BCCF4870356745AAAFA0` and Installer `44A3B34F4CCDE0AD66D2024CCB2F6E93483B9F2B`, Team `X3Q42VNZDC` | Admin install remains unapproved until the signed package and artifact-set hashes are presented |
| 14 | Cross-prefix legacy disposition | Remove only the exact signed, root-owned, quiesced and forensically archived legacy app under a separate stop gate before installing the same-receipt successor | Direct UAT proved PackageKit updated the receipt and installed the successor but retained the old payload; the rerun proved explicit removal preserves receipt authority and yields one secure bundle with exact cleanup |

## Outcomes and retrospective

W1 qualifies Herdr 0.8.2/protocol 20 and adds a DB-free installed readiness probe; W2 qualifies the exact macOS 27 Git closure; W3 moves the declarative package source to the secure nested path and passes S1 plus an unsigned PackageKit product rehearsal. W4 has local append-only rollover authority, schema-4 architecture bootstrap, distinct Engine/CLI commands, exact historical-runtime invalidation, one generation-2 q4 path, full unrelated-state isolation, q5/Resume denial, credential cleanup proof and prepared/enqueued/settled restart handling; its structural claims (durable Resume-denial triggers, typed rollover/q4 authority, sequence-4 q4, 76-statement digest pin) were re-verified in source and by 151 focused tests after the last edit.

W5 closed on 2026-08-27: the executable runbook (`docs/operations/production-cutover-0.1.1.md`), the source-controlled expected values, the read-only preflight and its zero-mutation test suite shipped and are wired into `make check`; a live static preflight against real production passed 23 checks with an unchanged DB byte guard. The protected four-review route worked this time (the previously reported Pi Forge contract error did not reproduce; the only failures were machine-sleep infrastructure stalls, resumed): architecture, security, database and test reviews completed, 0 Critical, 5 accepted Major all fixed, 1 Major rejected with reproduced counter-evidence, 10 of 13 Minor fixed, 3 deferred to tech-debt with pointers. Every final gate reran green after the last fix edit. Score 91/100 against the consolidated list (3 open Minor), above the PR threshold.

W0 is complete on the corrected reviewed pair. The first root attempt exposed the retained cross-prefix legacy payload and was contained; the separately approved explicit-removal rerun passed legacy lifecycle, receipt-preserving retirement, successor install, two 80-check audits, secure lifecycle/XPC, reinstall and exact cleanup. Final UAT clean-state passed 18 checks, production passed 23 checks, and production before/after DB, receipt, app PID, counts and secure-root state are identical. UAT Developer ID signing and root installation occurred only under their consumed approvals; no UAT artifact is production authority.

Still open, each behind its named stop gate: W6 production Developer ID signing/notarization, W7 legacy removal plus installed-and-paused production, W8 rollover/q4 and the W9 q5/Resume plan. No production signing, notarization, installation or mutation, q4/q5, Resume, commit, push or PR occurred. Do not mark production ready while W7 or W8 is incomplete; do not mark live production while W9 remains unapproved or unexecuted.

## Supersession record, 2026-09-03

- Later authorized work completed the source and secure nested-path installation mechanics, protocol-11 lifecycle/Keychain handoff, generation rollover, q4, release-owned Pi/Herdr runtime checks, session privacy, exact PR narrative binding, and the ninth four-role paused sandbox canary. Source commits `e22c32a191892425fefaae9549e4d14207ae1062` and `c67943130e535da65274b77601e36241ce781454` merged through PR `#16` as `b6cb62ba7d53d5de740d6e2983656f911db7bd1c`.
- Final ninth-canary evidence is preserved at `/Users/maroffo/JidokaCode-live-canary-evidence/20260902-pr1-ninth-terminal-theme`, inventory SHA-256 `21ed3ff062481dfc16d8b7b4e6137c18e6ea3f488cbb640a375bcf4e06595644`. It proves PR review under the historical exact canary only.
- The ninth candidate is intentionally unnotarized and unstapled; Gatekeeper reports `rejected`, `source=Unnotarized Developer ID`. Real issue triage and issue implementation remain unproven. Consequently the W6-W9 checkboxes and old package/runbook identities above are stale operational labels, not authorization to finish them literally or invoke global Resume.
- Current operational planning is `quality_reports/plans/active/2026-09-03_progressive-production-automation.md`. It supersedes the old W9 Resume concept with schema-10 exact-stage and finite-window authority, while preserving every historical job, run, intent, descriptor, session, backup, and evidence bundle. No signing, notarization, installation, provider, GitHub, triage, implementation, promotion, merge, rollback, or cleanup action is inherited from this plan.
