# ABOUTME: Final W5 direct-source review brief for the production-readiness fast path.
# ABOUTME: Names base/head, changed paths, evidence, verification results and residual risks for the four routed reviewers.

# Review brief: production-readiness fast path, final W5 round

- Plan: `quality_reports/plans/active/2026-08-27_production-readiness-fast-path.md`
- Worktree: `/Users/maroffo/Development/public/jidoka-code-worktrees/feat-settings-guided-configuration`
- Base branch/HEAD: `feat/settings-guided-configuration` at `944f4f489e732f871e749cfd61c6b2d7e3324343`
- All W1-W5 work is uncommitted in this worktree (one writer, no commit authorized). Review
  the working tree, not HEAD.
- Complete tracked diff: `quality_reports/review/2026-08-27_w5-final/tracked-changes.diff`
  (19099 lines). Untracked additions listed in `status.txt`; read them directly from the
  worktree:
  - `Resources/Herdr/api-schema-0.8.2.json`
  - `Sources/JidokaCodeApp/HerdrReadinessProbeCLI.swift`
  - `Sources/JidokaCodeCore/State/JobCanaryGenerationRollover.swift`
  - `Sources/JidokaCodeCore/State/JobCanaryGenerationRolloverCommand.swift`
  - `scripts/tests/test-herdr-schema-compatibility.mjs`
  - `scripts/tests/test-local-spike-runtime-attestation.mjs`
  - `docs/operations/production-cutover-0.1.1.md` (W5 runbook)
  - `docs/operations/production-cutover-0.1.1-expected.json` (W5 expected values)
  - `scripts/production-readiness-preflight.sh` (W5 read-only preflight)
  - `scripts/tests/test-production-readiness-preflight.sh` (W5 preflight tests)

## What changed, by workstream

- **W1 Herdr 0.8.2/protocol 20**: replaced the 0.8.0 schema resource and one-build policy
  (`Resources/Herdr/runtime-builds.json`), protocol/readiness/store source updates, new
  DB-free installed `--herdr-readiness-probe` CLI, S11/S12 fixture updates.
- **W2 macOS 27 Git**: exact `/usr/bin/git` digest `1685f2c9...` replaces the previous shim
  digest in `scripts/spikes/jidoka-local-spikes.mjs`; backend digest unchanged
  (`4026051f...`); drift negatives retained.
- **W3 secure package authority**: `Packaging/Info.plist` 0.1.1 build 2;
  `scripts/package-installer.sh` targets
  `/Library/Application Support/JidokaCode/Applications/Jidoka Code.app` with explicit
  root-owned `0755` parent BOM entries, no relocation, no scripts; S1 negatives for
  `/Applications`, transposition, duplicates, stale versions.
- **W4 generation rollover and q4**: migration 9 (76 statements, digest `48201824...`,
  pinned by `SQLiteStoreTests`), append-only
  `herdr_generation_rollover_authorizations` and successor-run lineage with typed rollover
  and q4 authorities, durable Resume/unpause denial during rollover
  (`app_settings_generation_rollover_resume_denied` triggers,
  `Sources/JidokaCodeCore/State/DatabaseSchema.swift:3747-3767`), q4 at successor sequence 4
  with final transactional publication, recovery for partial binding/host/layout,
  process observations matching/replaced/absent/unknown, socket-peer and executable-identity
  binding, unrelated-state isolation digest, credential-artifact cleanup,
  prepared/enqueued/settled restart recovery, Herdr 0.8.0/19 to 0.8.2/20 invalidation and
  rebind. Distinct Engine/CLI commands: `preview/execute-generation-rollover`,
  `preview/execute-generation-rollover-q4` (canonical base64 JSON argument).
- **W5 runbook and preflight**: `docs/operations/production-cutover-0.1.1.md` (checkpoints
  A-F plus W8, stop gates for signing/notarization/root-install/quiesce/migration/
  rollover/q4, forward-only containment, no receipt rollback),
  `docs/operations/production-cutover-0.1.1-expected.json` (source-controlled expected
  values), `scripts/production-readiness-preflight.sh` (read-only audit, absolute tools,
  fixed PATH, closed exit codes 0/64/65/66/67/68/69, alarm-bounded tools, 0700/0600
  evidence, SQLite `-readonly` + `query_only` with byte guard, uat-probe containment
  guards), `scripts/tests/test-production-readiness-preflight.sh` (fixture proof of
  zero mutation, cwd/PATH independence, drift/missing/placeholder rejection), Makefile
  wiring into `jidoka-code-check` plus `jidoka-code-test-w5-preflight` target, operations.md
  pointer.

## Verification already on record for this round

- Focused suites after the final W4 edit: 151 tests in 6 suites passed
  (`SQLiteStoreTests`, `PiRunStoreTests`, `HerdrPiWorkflowRuntimeTests`,
  `HerdrHostRuntimeTests`, `HerdrRuntimeReadinessTests`, `HerdrProtocolTests`).
- W5 preflight test suite green; live static preflight against real production passed with
  23 checks (schema 8, `paused=1`, 155/87/1 jobs, receipt 0.1.0 at `Applications`, secure
  root absent, Herdr/Git digests exact, DB byte-guard unchanged).
- Full final gates rerun after the last source edit (the last edit raised three
  load-marginal promptness bounds in `HerdrPiWorkflowRuntimeTests.swift` from 2s to 5s
  after a demonstrated 2.24s/2.69s wall-clock flake under load; no product code changed):
  - `make check`: 657 tests in 78 suites passed, plus lint/shellcheck/format/builds;
  - `make test-e2e`: S1, S10, S11, S12 all PASS against exact Herdr 0.8.2;
  - `make jidoka-code-w7-acceptance`: PASS (full check rerun, S10, S4 and S8 preflights,
    providerCalls=0);
  - `make jidoka-code-test-s5-s7-preflight`: PASS, providerCalls=0, 120 mutation cases,
    cleanup verified;
  - ad-hoc `./scripts/spikes/test-s1-package.sh`: PASS, preflight/engine probes ok from `/`;
  - `git diff --check` and `git diff --cached --check`: clean.
- Full S5-S7 remains correctly blocked without the separately authorized Developer ID
  identity; the root-owned W0 UAT package pair has not run (separate approval).

## Review contract

- Severity vocabulary and finding contract per `rules/quality-gates.md`: severity,
  `file:line`, claim, fix, evidence. A finding without nameable evidence is dropped, not
  downgraded.
- Reviewers are read-only with respect to this worktree and production. Do not run mutating
  commands against `/Users/maroffo/Library/Application Support/JidokaCode`, the production
  receipt, Keychain, sockets or processes. The preflight may be exercised only against
  fixtures (see its test) or with `--stage static`, which is read-only by contract.
- Focus areas per route:
  - architecture: package/path authority model, probe/CLI composition, runbook checkpoint
    ordering and containment semantics;
  - security: parent/ACL/symlink checks, uat-probe containment guards, credentialless
    probes, evidence permissions, no-network claims;
  - database: migration 9 cuts and digest, append-only triggers, Resume-denial latch,
    successor-run lineage FKs, read-only audit SQL;
  - test: preflight test coverage (zero-mutation proof, closed exit codes), W4 matrices,
    gaps between fixture and production shape.

## Residual risks (disclosed)

- PackageKit location-upgrade behavior is unverified until the root-owned UAT probe pair
  (STOP-UAT-INSTALL) runs; the preflight cannot substitute for it.
- The preflight reads the flat receipt plist directly instead of `pkgutil --volume` (which
  does not resolve fabricated fixture receipts); the runbook keeps pkgutil commands as
  independent checkpoint evidence.
- lsof/pgrep quiesce evidence is sampling-based; checkpoint B pairs it with explicit
  process-exit verification.
- SQLite may touch the transient `-shm` file even for read-only connections; the byte guard
  covers the main DB and WAL.
- Full S5-S7, signing, notarization, install, migration, q4, q5 and Resume remain behind
  their named stop gates and are not claimed.
