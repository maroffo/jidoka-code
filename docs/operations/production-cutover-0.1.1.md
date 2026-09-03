# ABOUTME: Executable cutover runbook for Jidoka Code 0.1.1 (plan W5, decision 21).
# ABOUTME: Names every command, side effect, timeout, evidence file, stop condition and containment action for W6-W8.

# Production cutover runbook: Jidoka Code 0.1.1

This runbook is the single executable procedure for moving production from the
`/Applications` 0.1.0 install to the secure-root 0.1.1 install, migrating schema 8 to 9,
rolling the stale four-host topology into generation 2 and settling one q4. It is
parameterized (decision 21): every value is either pinned here, pinned in the
source-controlled expected-values artifact, or supplied by a named later input. It contains
no placeholders.

Companion artifacts, all source-controlled in this repository:

| Artifact | Role |
|---|---|
| `docs/operations/production-cutover-0.1.1-expected.json` | Expected values consumed by the preflight (identifiers, digests, counts, paths) |
| `scripts/production-readiness-preflight.sh` | Repeatable read-only audit; closed exit codes 0/64/65/66/67/68/69 |
| `scripts/tests/test-production-readiness-preflight.sh` | Proof that the preflight mutates nothing and rejects drift |

## 1. Authority model and side-effect classes

Every numbered command below carries exactly one side-effect class:

| Class | Meaning |
|---|---|
| READ-ONLY | No byte changes anywhere; SQLite only via `-readonly` plus `PRAGMA query_only=ON` |
| EVIDENCE-WRITE | Writes only beneath the evidence root defined in section 4 |
| PROCESS | Stops or starts a process, or changes login registration |
| ADMIN-INSTALL | Root-owned PackageKit installation |
| DB-MIGRATION | Mutates the production SQLite database |
| WORKFLOW-EFFECT | Mutates durable workflow state (rollover, q4) |

Rules that hold for the whole runbook:

- One operator, one command at a time, in order. No command is skipped and no command is
  improvised. A failed command means: stop, record, enter the containment action of the
  current checkpoint. Never retry a mutating command without a fresh approval.
- Every command uses absolute paths only and does not depend on `PATH`, cwd or inherited
  environment. Commands that must be environment-clean are written with `env -i` and run
  from `/`.
- Timeouts are enforced with the same alarm-bounded exec the preflight uses:
  `/usr/bin/perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV; exit 127;' <seconds> <absolute-command> <args>`.
  Exit 142 means timeout; treat it as the command's failure, never as success.
- Network denial: no runbook command invokes a network-capable tool. The only commands with
  network effects are the two W6 signing/notarization commands, each behind its own stop
  gate. Probes run with `env -i` from `/`; their effect denial (no engine start, no DB write,
  no credential acquisition, no provider call) is enforced by the probe implementations and
  covered by unit suites, not by operator discipline.
- The Herdr production socket is touched only by checkpoint D and F probe commands, which
  are the separately authorized live phase. The preflight never opens any socket.
- Forward-only recovery: there is no rollback of the PackageKit receipt and no relaunch of
  the old app after schema 9. Failure always lands in a stopped, paused, contained state
  that preserves evidence. `pkgutil --forget` and manual receipt edits are forbidden.

## 2. Fixed identity and digest table

Pinned now, verified by the preflight against
`docs/operations/production-cutover-0.1.1-expected.json`:

| Fact | Value |
|---|---|
| Package identifier | `com.maroffo.JidokaCode.pkg` |
| Bundle identifier | `com.maroffo.JidokaCode` |
| Successor version / build | `0.1.1` / `2` |
| Install root | `/Library/Application Support` |
| Payload root-relative app path | `JidokaCode/Applications/Jidoka Code.app` |
| Secure app path | `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app` |
| Successor executable | `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app/Contents/MacOS/Jidoka Code` |
| Legacy app | `/Applications/Jidoka Code.app`, currently PID 3325 |
| Legacy receipt | `com.maroffo.JidokaCode.pkg` version `0.1.0`, location `Applications` |
| Legacy notarized package (evidence only, never installed; decision 14) | SHA-256 `7102326303e2fe1f1394c42b4f919351f14ec3c37f5ac26dd962ac23c83ab0cb` |
| Production database | `/Users/maroffo/Library/Application Support/JidokaCode/jidoka-code.sqlite3`, schema 8, `paused=1` |
| Queue snapshot | 155 queued, 87 blocked, 1 runningPi, 243 total |
| Herdr | `/opt/homebrew/bin/herdr` resolving to `/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr`, SHA-256 `3e0f0c2d5edc41f592963ef90f5d872db801cc7dbd0e01731023897ee428904a`, protocol 20 |
| Git | `/usr/bin/git` SHA-256 `1685f2c90307faa05ef5ae8f707d3a18a519c9dad75882768f66abb475f1b3d7`; backend `/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-http-backend` SHA-256 `4026051f87a437197a913d4ca5d3196f1d749bf6060f84c74cc374263988110a` |
| Schema 9 migration | 76 statements, digest `48201824a919a208a72eccea6a626b2a560e2cd93b0686e390e949045bbb7751` (pinned by `Tests/JidokaCodeCoreTests/SQLiteStoreTests.swift`) |

## 3. Later inputs: provenance, not placeholders

Two inputs cannot exist yet and are supplied by name at their stop gates:

1. **Signing identities** (`STOP-SIGNING`). Max supplies the exact Developer ID Application
   and Developer ID Installer identity strings in the W6 approval message. They are used
   only as `SIGN_IDENTITY` and `INSTALLER_SIGN_IDENTITY` for `scripts/package-installer.sh`
   and appear afterwards in the frozen package's signature evidence.
2. **Post-W6 hashes** (`build/production-cutover-0.1.1-values.env`). Generated by W6 step
   6.4 below from the frozen signed package, mode 0600, never a source edit. Consumed by
   `--cutover-values` at checkpoint C. Required keys: `package_path`, `package_sha256`,
   `package_manifest_path`, `package_manifest_sha256`. The preflight rejects missing keys,
   empty values and placeholder markers.

## 4. Evidence: ownership and cleanup

- Evidence root: `/Users/maroffo/JidokaCode-cutover-0.1.1-evidence`, created at the first
  checkpoint that needs it with mode 0700, owner `maroffo:staff`. All evidence files are
  mode 0600. The preflight refuses an evidence dir inside the production secure root or the
  production database directory.
- Every checkpoint writes into its own subdirectory (`checkpoint-a`, `checkpoint-b`, ...,
  `w8`). Preflight logs are named `preflight-<stage>-<UTC timestamp>.log` by the script.
- The operator shell for every checkpoint sets `umask 077` first, and the first command of
  every checkpoint is `/bin/mkdir -p <EV>/<checkpoint-dir> && /bin/chmod 700 <EV>/<checkpoint-dir>`
  (EVIDENCE-WRITE, 30s). Every redirected evidence file therefore lands 0600 without a
  per-file chmod; the preflight enforces the same modes for its own outputs.
- The schema-8 backup created at checkpoint B lives in `checkpoint-b/` and is the only
  authorized database restoration source (section 12).
- Cleanup: nothing under the evidence root is deleted during W6-W8. After W9 closes, Max
  decides retention. The UAT probe cleanup (its own package, receipt, directories) is part
  of the W0 UAT procedure and never touches this evidence root or any production path.

## 5. Stop gates

Each gate requires a fresh, explicit, named approval from Max. Approval of one gate never
implies another. The gates, in order:

| Gate | Covers | Never implied by |
|---|---|---|
| STOP-UAT-INSTALL | Root install of the W0 probe package pair and its exact cleanup | Plan approval |
| STOP-SIGNING | Developer ID signing (app and installer), including timestamp network use | UAT success |
| STOP-NOTARIZATION | Notarization submission and stapling (network) | Signing |
| STOP-QUIESCE | Deregistering and quitting the live old app (checkpoint B) | Anything |
| STOP-LEGACY-REMOVE | Removing only the archived, quiesced `/Applications/Jidoka Code.app` | Quiescence or backup |
| STOP-ROOT-INSTALL | `installer -pkg` of the frozen 0.1.1 package on production (checkpoint C) | Legacy removal or notarization |
| STOP-MIGRATION | First launch of the new app, which migrates schema 8 to 9 (checkpoint E) | Install |
| STOP-ROLLOVER | `execute-generation-rollover` (W8) | Migration |
| STOP-Q4 | `execute-generation-rollover-q4` (W8) | Rollover |
| STOP-Q5 / STOP-RESUME | Not grantable under this plan; requires the W9 ExecPlan | Anything |

## 6. Phase order

1. **Static preflight** (repeatable, unprivileged, READ-ONLY): section 7. Green static
   preflight is a precondition for every later phase.
2. **Root-owned UAT rehearsal** (W0, behind STOP-UAT-INSTALL): probe package pair with
   unique non-production identifiers. The preflight runs in `uat-probe` mode with a
   UAT-specific expected-values artifact; the script hard-rejects a UAT artifact that names
   production identifiers or the production secure root.
3. **W6 build, sign, notarize** (behind STOP-SIGNING and STOP-NOTARIZATION): section 8.
4. **W7 checkpoints A-F** (behind STOP-QUIESCE, STOP-LEGACY-REMOVE,
   STOP-ROOT-INSTALL and STOP-MIGRATION): section 9.
5. **W8 rollover and q4** (behind STOP-ROLLOVER and STOP-Q4): section 10.
6. **W9** is a separate ExecPlan; q5 and Resume are out of scope here.

### 6.1 Root-owned UAT location-probe pair

The UAT pair uses only these non-production authorities:

| Fact | Legacy probe | Successor probe |
|---|---|---|
| Bundle ID | `com.maroffo.JidokaCode.LocationProbe` | same |
| Helper and Mach service | `com.maroffo.JidokaCode.LocationProbe.Engine` | same |
| Package and receipt ID | `com.maroffo.JidokaCode.LocationProbe.pkg` | same |
| Version/build | `0.1.0` / `1` | `0.1.1` / `2` |
| Installed app | `/Applications/Jidoka Code Location Probe.app` | `/Library/Application Support/JidokaCode-LocationProbe/Applications/Jidoka Code Location Probe.app` |

The probe contains no production database, Herdr socket, credential or provider path. Its
main executable performs only bundle evidence, exact-path process lifetime, SMAppService
agent registration and one nonce-bound XPC round trip. The helper accepts only the exact
same-Team main executable in its containing bundle.

The historical directory `build/location-probe-uat-X3Q42VNZDC-20260827` is permanently
blocked. Its package hashes `c68ae65fce00645deedf94fa0f084f3787a4d826f58b74ec07ba3b61d187ec3e`
and `e5cd855e3059bb5ff250f04efce0cb0466f5f75fca3c3c695bc4397b3af54a32` must never be
installed; the auditor rejects them even during its bootstrap pass. The corrected reviewed
set is `build/location-probe-uat-X3Q42VNZDC-20260828-reviewed`, with legacy package
`c24d9883d6c6f2c77e2fdafb8c37699f06b7302d943bed843cbc83370102de34`, successor package
`4e880629579040ad2f36b2d4f114b77a17f6b339cce3a4d3ba03f6e389e16260` and artifact set
`65b86fc938cff2f7997f33aac9b0db28431465b011f0e8b1008b02d9a46c949a`.

After separate preparation/signing approval, build exactly once with the identities recorded
in the resulting manifest:

```sh
env -i \
  HOME=/Users/maroffo \
  TMPDIR=/tmp \
  SIGN_IDENTITY=42168752E0FB74059B87BCCF4870356745AAAFA0 \
  INSTALLER_SIGN_IDENTITY=44A3B34F4CCDE0AD66D2024CCB2F6E93483B9F2B \
  /bin/bash /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/scripts/build-location-probe-packages.sh \
  --output-dir /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed \
  --signing-mode developer-id
```

This command performs Developer ID timestamp network calls but no notarization, installation,
registration, launch or cleanup. A successful build retains a nonempty mode-0600
`static-audit.log` and prints separate SHA-256 values for `artifact-set.txt`,
`location-probe-artifacts.json` and `static-audit.log`. Re-audit the immutable result:

```sh
env -i TMPDIR=/tmp \
  /bin/bash /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/scripts/audit-location-probe-packages.sh \
  --artifact-dir /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed
```

Before requesting `STOP-UAT-INSTALL`, create only the private evidence parent, then run the
UAT clean-state preflight. The preflight creates exactly one leaf and refuses missing,
symlinked, foreign-owned, ACL-bearing or writable parents before any evidence write. It
requires the probe receipt, both probe apps and the probe secure root to be absent:

```sh
/bin/mkdir -m 0700 /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed/uat-evidence
env -i /bin/bash /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/scripts/production-readiness-preflight.sh \
  --stage static \
  --expected /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed/uat-probe-expected.json \
  --evidence-dir /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed/uat-evidence/pre-install
```

Only after Max approves the exact `artifactSetSHA256`, artifact-manifest SHA-256,
static-audit SHA-256 and both package SHA-256 values may the operator execute these
one-at-a-time admin and user-domain steps. The audit independently pins both install roots,
payload paths and installed paths, plus the exact Application and Installer certificate
fingerprints:

1. Install the legacy package with
   `/usr/bin/sudo /usr/sbin/installer -pkg "/Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed/Jidoka-Code-Location-Probe-0.1.0.pkg" -target /` (ADMIN-INSTALL, 900s).
2. Run the UAT preflight with `--stage cutover-pre` into `uat-evidence/legacy-installed`.
   It must report receipt `0.1.0` at `Applications`, the exact legacy app and no secure root.
3. Launch only `/Applications/Jidoka Code Location Probe.app` by exact URL, run its
   `self-check`, `agent register`, `helper round-trip`, `helper shutdown`, `agent unregister`
   and `main graceful-quit` commands, and prove both exact probe processes absent. Any
   `requiresApproval` status is a stop for explicit operator action, not an automatic pass.
4. While receipt `0.1.0` still names `Applications`, verify the exact root-owned legacy
   bundle, identifier, version/build, Team, Application certificate, closed payload, absent
   service and absent exact processes. Remove only `/Applications/Jidoka Code Location
   Probe.app`, then prove it absent and the receipt unchanged. This explicit step is required:
   the first corrected-pair attempt proved PackageKit leaves the old cross-prefix payload.
5. Install the successor package with
   `/usr/bin/sudo /usr/sbin/installer -pkg "/Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/build/location-probe-uat-X3Q42VNZDC-20260828-reviewed/Jidoka-Code-Location-Probe-0.1.1.pkg" -target /` (ADMIN-INSTALL, 900s).
6. Run the UAT preflight with `--stage cutover-post-install`, its generated
   `uat-cutover-values.env`, and evidence dir `uat-evidence/successor-installed`. Require
   receipt `0.1.1`, exact UID-0 `0755` parents, exact secure app and no legacy duplicate.
   It also requires the closed installed payload inventory, root ownership, exact modes,
   no ACL/symlink/hard-link authority, strict signatures, identifiers, Team, timestamps and
   the exact approved Application leaf certificate before any lifecycle command.
7. Repeat the exact secure-path lifecycle and XPC sequence, reinstall the same successor
   package once, then repeat the post-install preflight. Any receipt, path, owner, mode, ACL,
   signature, process or XPC drift stops before cleanup improvisation.
8. Cleanup only after the separately approved exact cleanup list: unregister and stop the
   probe helper/main process; remove only the two probe app paths; remove the empty
   `JidokaCode-LocationProbe/Applications` and `JidokaCode-LocationProbe` directories with
   `rmdir`; forget only `com.maroffo.JidokaCode.LocationProbe.pkg`; rerun the clean-state
   UAT preflight and the production static preflight. Production DB bytes, production
   receipt, app PID and secure-root absence must equal their pre-UAT evidence.

The package hashes and cleanup commands are not approved by this prose. They are copied from
the freshly audited artifact into the `STOP-UAT-INSTALL` request, together with the
artifact-manifest and static-audit digests. No UAT package is notarized, and no UAT artifact
may be used as production authority.

## 7. Static preflight (run now, rerun before every phase)

```
env -i /bin/bash /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/scripts/production-readiness-preflight.sh \
  --stage static \
  --expected /Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration/docs/operations/production-cutover-0.1.1-expected.json \
  --evidence-dir /Users/maroffo/JidokaCode-cutover-0.1.1-evidence/static
```

- Side effect: READ-ONLY plus EVIDENCE-WRITE. Timeout: script-internal (30s per tool, 600s
  overall). Expected: exit 0, 23 checks, `RESULT PASS` in the log.
- Go: exit 0. No-go: any nonzero exit; the log names the drifted fact. A drifted fact means
  the plan's analysis is stale: stop and re-plan, do not adjust the expected values to make
  the check pass without a decision row.

## 8. W6: build, sign, notarize, freeze (one cycle)

Preconditions: W5 gates green after the final source edit; UAT rehearsal complete; static
preflight green. Inputs: the two signing identities (section 3).

| # | Command (absolute, bounded) | Class | Timeout | Expected evidence | Stop condition |
|---|---|---|---|---|---|
| 6.1 | `SIGN_IDENTITY=<app identity> INSTALLER_SIGN_IDENTITY=<installer identity> /usr/bin/make -C <worktree> jidoka-code-package` | Local build + signing (STOP-SIGNING; timestamp network use) | 1800s | `build/Jidoka Code.pkg`, `build/package-manifest.json`, signature/timestamp blocks | Any signing or inventory validation failure inside `scripts/package-installer.sh` |
| 6.2 | Notarize and staple per `scripts/package-installer.sh` notarization path | STOP-NOTARIZATION (network) | 3600s | `build/notarization-result.json` accepted; stapled package | Any status other than `Accepted` |
| 6.3 | Re-expand and re-audit the stapled package: `/usr/sbin/pkgutil --expand-full "build/Jidoka Code.pkg" <evidence>/w6/expanded` then re-run the S1 assertions | READ-ONLY + EVIDENCE-WRITE | 600s | Exact secure payload path, no relocation, no scripts, parents `root:wheel 0755` in BOM | Any S1 assertion failure |
| 6.4 | Generate `build/production-cutover-0.1.1-values.env` (`printf` of the four required keys with `/usr/bin/shasum -a 256` outputs; `/bin/chmod 600`) | EVIDENCE-WRITE | 60s | File with the four keys, mode 0600 | Missing artifact or hash mismatch on re-read |

After 6.4 the package, manifest and values file are frozen: no source edit, no rebuild, no
re-signing without a new decision (Budget: one notarized candidate). Architecture and
security re-review the expanded payload and this runbook before checkpoint A (plan, Review
plan). Stop without installing.

## 9. W7: checkpoints A-F

Each checkpoint starts with the read-only preflight and ends with a go/no-go record in its
evidence subdirectory. `<EV>` is the evidence root, `<APP_OLD>` is
`/Applications/Jidoka Code.app`, `<APP_NEW>` is the secure app path, `<DB>` is the
production database path, `<WT>` is this worktree's absolute path.

### Checkpoint A: live evidence only

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| A.1 | Preflight `--stage cutover-pre` with evidence dir `<EV>/checkpoint-a` | READ-ONLY | 600s | Exit 0; records PID 3325 and WAL/SHM state |
| A.2 | `/usr/bin/codesign -dv --verbose=4 "<APP_OLD>"` capturing stderr to `<EV>/checkpoint-a/old-app-codesign.txt` | READ-ONLY + EVIDENCE-WRITE | 60s | Identifier `com.maroffo.JidokaCode`, valid signature |
| A.3 | `/usr/bin/ditto -c -k --keepParent "<APP_OLD>" "<EV>/checkpoint-a/old-app-archive.zip"` then `/usr/bin/shasum -a 256` of the archive | EVIDENCE-WRITE | 600s | Archive plus hash line. This archive is forensic evidence, explicitly not a receipt rollback artifact |
| A.4 | Row inventory: `/usr/bin/sqlite3 -readonly <DB> "PRAGMA query_only=ON; SELECT state, COUNT(*) FROM jobs GROUP BY state ORDER BY state;"` to `<EV>/checkpoint-a/rows.txt` | READ-ONLY + EVIDENCE-WRITE | 60s | `blocked\|87`, `queued\|155`, `runningPi\|1` |
| A.5 | `/usr/sbin/pkgutil --pkg-info com.maroffo.JidokaCode.pkg` to `<EV>/checkpoint-a/receipt.txt` | READ-ONLY + EVIDENCE-WRITE | 60s | version 0.1.0, location Applications |
| A.6 | LaunchServices state: `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -dump \| /usr/bin/grep -A2 "Jidoka Code.app"` to `<EV>/checkpoint-a/lsregister.txt` | READ-ONLY + EVIDENCE-WRITE | 300s | Exactly one registration, at `<APP_OLD>` |
| A.7 | Login registration: `env -i "<APP_OLD>/Contents/MacOS/Jidoka Code" --lifecycle main status` to `<EV>/checkpoint-a/lifecycle-status.json` | READ-ONLY + EVIDENCE-WRITE | 60s | Current SMAppService status recorded |

Go: all expected values match. No-go: any drift; nothing was mutated, so containment is
simply: stop, report, leave production running.

### Checkpoint B: quiesce and authoritative backup (STOP-QUIESCE)

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| B.1 | `env -i "<APP_OLD>/Contents/MacOS/Jidoka Code" --lifecycle main unregister` | PROCESS | 60s | Login item deregistered |
| B.2 | `env -i "<APP_OLD>/Contents/MacOS/Jidoka Code" --lifecycle main graceful-quit` | PROCESS | 120s | PID 3325 exits |
| B.3 | `/usr/bin/pgrep -f "/Applications/Jidoka Code.app/Contents/MacOS/"` | READ-ONLY | 30s | No output, exit 1 |
| B.4 | `/usr/sbin/lsof "<DB>" "<DB>-wal" "<DB>-shm"` | READ-ONLY | 60s | No output: no writer or open descriptor remains |
| B.5 | Preflight `--stage cutover-pre --require-quiesced`, evidence dir `<EV>/checkpoint-b` | READ-ONLY | 600s | Exit 0: still schema 8, paused, counts exact, no process, no opener |
| B.6 | Backup: `/usr/bin/sqlite3 -readonly "<DB>" ".backup '<EV>/checkpoint-b/jidoka-code.schema8.backup.sqlite3'"` then `/bin/sync`, `/bin/chmod 600` on the backup | EVIDENCE-WRITE | 600s | Backup file exists, mode 0600 |
| B.7 | Verify backup: `/usr/bin/sqlite3 -readonly` on the backup: `PRAGMA integrity_check;` `PRAGMA foreign_key_check;` `SELECT MAX(version) FROM schema_migrations;` plus `/usr/bin/shasum -a 256` of backup and source DB into `<EV>/checkpoint-b/backup-binding.txt` | READ-ONLY + EVIDENCE-WRITE | 600s | `ok`, empty, `8`; hashes recorded, WAL empty (0 bytes) recorded |

Go: B.3, B.4, B.5 empty/green and B.7 clean. No-go containment: do not proceed to C; the
system is stopped and paused; re-registering and relaunching the old app is permitted only
at this checkpoint (schema is still 8 and nothing was installed), and only with a fresh
approval.

### Checkpoint C: retire the legacy path and install

Checkpoint C has two independent root gates. `STOP-LEGACY-REMOVE` covers only C.1; after its
evidence is accepted, `STOP-ROOT-INSTALL` covers only C.3. Neither approval implies the other.

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| C.1 | Revalidate A.2/A.3, receipt 0.1.0, B.3/B.4 quiescence and B.7 backup binding, then `/usr/bin/sudo /bin/rm -rf -- "<APP_OLD>"` | READ-ONLY + ADMIN-INSTALL (`STOP-LEGACY-REMOVE`) | 600s | Only the exact archived, root-owned legacy bundle becomes absent; receipt remains 0.1.0 at `Applications`; DB hash and backup remain unchanged |
| C.2 | Recheck `<APP_OLD>` absent, secure root absent, receipt 0.1.0, schema 8, `paused=1`, DB hash/counts equal B.7 and no app/helper/DB opener | READ-ONLY | 600s | All exact; otherwise do not install |
| C.3 | `/usr/bin/sudo /usr/sbin/installer -pkg "<frozen package path from values.env>" -target /` | ADMIN-INSTALL (`STOP-ROOT-INSTALL`) | 900s | Exit 0 |
| C.4 | Preflight `--stage cutover-post-install --cutover-values <WT>/build/production-cutover-0.1.1-values.env`, evidence dir `<EV>/checkpoint-c` | READ-ONLY | 600s | Exit 0: receipt 0.1.1 at `Library/Application Support`, secure path present, legacy path absent, parents `0:0 40755` no ACL, app Info.plist 0.1.1/2, package and manifest digests match, DB still schema 8 paused |
| C.5 | `/usr/sbin/pkgutil --pkg-info com.maroffo.JidokaCode.pkg` and `/usr/sbin/pkgutil --files com.maroffo.JidokaCode.pkg` to `<EV>/checkpoint-c/` | READ-ONLY + EVIDENCE-WRITE | 300s | Receipt agrees with C.4; file list has only expected paths |
| C.6 | `/usr/bin/codesign --verify --deep --strict "<APP_NEW>"` and `/usr/sbin/spctl --assess --type install "<frozen package path>"` to `<EV>/checkpoint-c/` | READ-ONLY + EVIDENCE-WRITE | 600s | Both clean |
| C.7 | Duplicate-bundle audit: `/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'com.maroffo.JidokaCode'"` to `<EV>/checkpoint-c/duplicates.txt` | READ-ONLY + EVIDENCE-WRITE | 120s | Exactly `<APP_NEW>`; `<APP_OLD>` remains absent |

Go: C.4 through C.7 clean. If C.1 fails, stop without installing. After C.1 succeeds, the
system is intentionally stopped/paused with no installed UI path, but the forensic archive
and schema-8 backup remain. If C.3 or a later check fails, stop before launch, never relaunch
the removed old app, do not run `pkgutil --forget`, and do not edit the receipt. Record the
exact mismatch. If PackageKit changes or removes any path outside the declared old/new app
paths and receipt, that is a plan-level stop requiring re-audit.

### Checkpoint D: prelaunch readiness (live socket, separately authorized)

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| D.1 | `cd / && env -i "<APP_NEW>/Contents/MacOS/Jidoka Code" --herdr-readiness-probe > <EV>/checkpoint-d/readiness-prelaunch.json` | READ-ONLY (DB-free, credentialless; opens only the Herdr socket) + EVIDENCE-WRITE | 120s | Exit 0; canonical evidence binds socket, peer PID/start/path/hash/code, Herdr 0.8.2/protocol 20, release runtime and resources |

Go: exit 0 with all bindings exact. No-go: stop before migration; nothing was mutated;
containment as at checkpoint C.

### Checkpoint E: migrate and start paused (STOP-MIGRATION)

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| E.1 | Repeat D.1 to `<EV>/checkpoint-e/readiness-final.json`; `/usr/bin/diff` of canonical fields against D.1 | READ-ONLY + EVIDENCE-WRITE | 120s | Unchanged |
| E.2 | `/usr/bin/open "<APP_NEW>"` (exact bundle path, never `-a`) | DB-MIGRATION + PROCESS | 600s for migration completion | App starts, migrates 8 to 9, stays paused |
| E.3 | `/usr/bin/sqlite3 -readonly <DB> "PRAGMA query_only=ON; SELECT MAX(version) FROM schema_migrations;"` | READ-ONLY | 60s | `9` |
| E.4 | `/usr/bin/sqlite3 -readonly <DB>` integrity, foreign keys, `paused`, job counts | READ-ONLY | 300s | `ok`, empty, `1`, counts unchanged (155/87/1) |
| E.5 | Startup delta audit: compare pre/post canonical inventories of the four stale role hosts and their binding (`herdr_role_hosts`, `herdr_job_bindings`, rollover authority tables) to `<EV>/checkpoint-e/startup-delta.txt` | READ-ONLY + EVIDENCE-WRITE | 300s | Only the rehearsed absent-host recovery delta; no scheduler pass, no provider or GitHub effect |

Go: E.3 through E.5 exact. No-go containment: quit the new app
(`env -i "<APP_NEW>/Contents/MacOS/Jidoka Code" --lifecycle main graceful-quit`), remain
stopped and paused, preserve all evidence. If schema is still 8: the checkpoint B state
holds; restoration is not needed. If schema is 9 or the migration is indeterminate: never
relaunch the old app; database restoration uses only the checkpoint B backup under a
separately approved operation (section 12).

### Checkpoint F: installed probe equality

| # | Command | Class | Timeout | Expected |
|---|---|---|---|---|
| F.1 | Repeat D.1 to `<EV>/checkpoint-f/readiness-postlaunch.json`; diff canonical fields against D.1 | READ-ONLY + EVIDENCE-WRITE | 120s | Equal to prelaunch authority |
| F.2 | `/usr/bin/sqlite3 -readonly <DB>`: q4/q5 zero, no unknown mutation intents, queue equality, `paused=1` | READ-ONLY | 300s | All exact |

Go: F.1 and F.2 exact; W7 acceptance is complete: installed, migrated, paused. No-go:
containment as checkpoint E.

## 10. W8: fresh generation and one q4

Preconditions: W7 accepted; fresh read-only re-audit (repeat A.4, F.2). All commands run
against the installed successor binary `<APP_NEW>/Contents/MacOS/Jidoka Code`.

| # | Command | Class | Gate | Expected |
|---|---|---|---|---|
| 10.1 | `--job-canary preview-generation-rollover <base64 canonical JobCanaryGenerationRolloverRequest>` | READ-ONLY preview | none | Canonical preview JSON naming generation 1 lost evidence, the four hosts, and the generation-2 successor plan; digests recorded to `<EV>/w8/` |
| 10.2 | Max approves the exact preview digest | approval | STOP-ROLLOVER | Written approval quoting the digest |
| 10.3 | `--job-canary execute-generation-rollover <base64 canonical JobCanaryGenerationRolloverAuthorization>` | WORKFLOW-EFFECT | STOP-ROLLOVER | Append-only rollover rows; generation 1 durably lost; four generation-2 hosts; no Pi/provider call |
| 10.4 | `--job-canary preview-generation-rollover-q4 <base64 canonical JobCanaryGenerationRolloverQ4Request>` | READ-ONLY preview | none | One descriptor-bound q4 preview with all seven backing digests |
| 10.5 | Max approves the exact q4 descriptor digest | approval | STOP-Q4 | Written approval quoting the digest |
| 10.6 | `--job-canary execute-generation-rollover-q4 <base64 canonical JobCanaryGenerationRolloverQ4ExecutionAuthorization>` | WORKFLOW-EFFECT | STOP-Q4 | Exactly one q4 settles: canonical SQLite result, acknowledgement, release; q5 zero; 155 jobs untouched; `paused=1`; no GitHub effect |

The base64 argument is the canonical sorted-keys JSON of the named request/authorization
type, produced from the preview output; the CLI rejects any non-canonical encoding. Stop
conditions: any send-start ambiguity or cleanup uncertainty is terminal for this incident;
never replay (decision 12). After 10.6: stop. Resume, q5 and queue disposition belong to
the W9 ExecPlan.

## 11. Go/no-go summary

| Boundary | Go requires |
|---|---|
| Enter UAT install | Static preflight green; probe artifacts statically verified; STOP-UAT-INSTALL approval |
| Enter W6 signing | UAT rehearsal complete with exact cleanup; W5 gates green after final source edit; four direct reviews obtained |
| Enter checkpoint A | Frozen stapled package re-audited (8.3); values file present (8.4); pre-install re-review of payload and this runbook |
| Enter checkpoint C.1 | A and B green, backup bound and verified; STOP-LEGACY-REMOVE approved |
| Enter checkpoint C.3 | C.1/C.2 green; frozen package rechecked; STOP-ROOT-INSTALL approved |
| Enter checkpoint E | C and D green, final readiness equal |
| Declare W7 accepted | F equality plus paused/queue/q4/q5 checks exact |
| Enter W8 execution | W7 accepted; preview digests approved per gate |

## 12. Forward-only recovery and containment

- There is no immediate receipt rollback and none is promised (decision 20). The archive
  from A.3 and the legacy package `71023263...` are forensic evidence only (decision 14).
- Failure before migration: the state is stopped, paused, schema 8. Containment: no forget
  and no receipt edit. The old app may be relaunched only after a checkpoint-B failure and
  fresh approval; after C.1 removes it, never reconstruct or relaunch it from the forensic archive.
- Failure after schema 9: never run the old binary. The only restoration source is the
  checkpoint B backup (`<EV>/checkpoint-b/jidoka-code.schema8.backup.sqlite3`), applied only
  under a separately approved corrective operation together with a coherent package/receipt
  recovery artifact.
- Failure after a WORKFLOW-EFFECT command (10.3, 10.6): external effects cannot be erased;
  close further admission, keep `paused=1`, preserve durable evidence, reconcile in W9.
- The held Herdr session and its credential artifacts are cleaned only by the already
  implemented and tested credential-cleanup path during authorized execution, never by
  manual runbook action.

## 13. Explicitly out of scope

q5, Resume/unpause, queue disposition of the 155 jobs, provider or GitHub calls, any second
notarization cycle, multi-OS certification, and cleanup of historical artifacts. Each
requires the W9 ExecPlan or a new decision row in the active plan.

Two schema-9 facts the W9 plan must budget for (database review, 2026-08-27):

- The Resume/unpause denial latch is durable by construction: the
  `app_settings_generation_rollover_*` triggers deny `paused = 0` whenever any rollover
  authorization row exists, and that table is append-only with no release predicate.
  After the first W8 authorization lands, Resume is unreachable under schema 9; W9's
  Resume therefore requires a schema-10 migration that retires or replaces those triggers.
- Migration 9's role-host replacement path is single-incident by construction: its insert
  authority hard-codes the exact incident audit and stale-pane digests. A future
  legitimate replacement is planned as a new migration, never attempted as data.
