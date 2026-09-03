# ABOUTME: Session log for the W5 close-out of the production-readiness fast path (runbook, preflight, final gates, reviews).
# ABOUTME: Records decisions, verification evidence and open items for the next session.

## 2026-08-27: W5 runbook, read-only preflight, fresh final gates, protected reviews

Goal: close W5 of `quality_reports/plans/active/2026-08-27_production-readiness-fast-path.md`
with an executable runbook and repeatable read-only preflight, re-verify W4 after the last
edit, obtain the four routed reviews, and prepare the approval packet for root-owned UAT and
signing, without executing any privileged or external operation.

### Delivered

- `docs/operations/production-cutover-0.1.1.md`: executable runbook, checkpoints A-F plus
  W8, side-effect classes, per-command timeouts (alarm-bounded exec), evidence
  ownership/cleanup, go/no-go table, separate stop gates (UAT install, signing,
  notarization, quiesce, root install, migration, rollover, q4; q5/Resume not grantable),
  forward-only containment with no receipt rollback.
- `docs/operations/production-cutover-0.1.1-expected.json`: source-controlled expected
  values (identifiers, digests, counts, paths, parents).
- `scripts/production-readiness-preflight.sh`: read-only audit; absolute tools, fixed PATH,
  closed exit codes 0/64/65/66/67/68/69, stages static/cutover-pre/cutover-post-install,
  production vs uat-probe modes with containment guards, SQLite readonly+query_only with
  before/after byte guard, evidence dir 0700 with 0600 logs.
- `scripts/tests/test-production-readiness-preflight.sh`: fixture proof of zero mutation
  (full tree snapshot), cwd/PATH independence (env -i from /), closed-code coverage, drift
  and placeholder rejection, uat-probe production-identifier rejection; wired into
  `make check` plus new `jidoka-code-test-w5-preflight` target.
- Review artifact `quality_reports/review/2026-08-27_w5-final/` (brief, full tracked diff,
  status list).

### Decisions

- Preflight reads the flat receipt plist directly (`pkgutil --volume` cannot resolve
  fixture receipts; key parity with `pkgutil --pkg-info` verified on the real production
  receipt). Runbook keeps pkgutil as independent evidence. Plan decision row 11.
- Raised three 2s wall-clock promptness bounds in `HerdrPiWorkflowRuntimeTests.swift` to 5s
  after a demonstrated 2.24s/2.69s flake under load (`make check` red once, suite green in
  isolation when quiet). No product code changed. Plan decision row 12.

### Verification (fresh, after the last source edit)

- Focused W4 suites: 151 tests in 6 suites green.
- `make check`: 657 tests in 78 suites green plus lint/shellcheck/builds.
- `make test-e2e`: S1, S10, S11, S12 green on exact Herdr 0.8.2.
- `make jidoka-code-w7-acceptance`: green, providerCalls=0.
- `make jidoka-code-test-s5-s7-preflight`: green, 120 mutation cases, cleanup verified.
- Ad-hoc S1: green. `git diff --check` and `--cached --check`: clean.
- Live static preflight against production: PASS, 23 checks, DB byte guard unchanged.
- Production reconfirmed read-only: schema 8, paused=1, integrity ok, FK 0, 155 queued,
  87 blocked, 1 runningPi; receipt 0.1.0 at Applications; secure root absent; Herdr
  0.8.2 and Git digests exact; PID 3325 alive.

### Reviews

All four protected reviews completed (architecture, security, database, test); the
previously reported Pi Forge contract error did not reproduce. Machine-sleep stalls hit
three of the four agents and were resumed via follow-up messages. Consolidated verdict:
0 Critical, 5 accepted Major (all fixed: probe error detail, bounded pgrep, three missing
negative families in the preflight test), 1 Major rejected with git-diff counter-evidence,
13 Minor (10 fixed, 3 deferred to tech-debt). The fix round also flushed out a real
preflight defect (timeout exit 68 remapped to 66) via the demanded exit-68 negative.
Every gate reran green after the last fix edit; score 91/100, PR gate.

### Flakes observed (pre-existing, not fixed)

- `HerdrPiWorkflowRuntimeTests` promptness bounds 2s → 5s (decision row 12, fixed).
- `GitProcessTests` session-escape cleanup threw `.cleanupFailed` once under full-suite
  load; 3/3 green isolated; acceptance rerun green. Product cleanup budget, left alone.

### Open items

- Root-owned W0 UAT package-pair rehearsal (STOP-UAT-INSTALL, needs Max).
- W6 signing/notarization (STOP-SIGNING, STOP-NOTARIZATION, needs Developer ID identities).
- Full S5-S7 remains blocked without Developer ID; not bypassed.
- W7 checkpoints, W8 rollover/q4, W9 plan: all behind their gates.
