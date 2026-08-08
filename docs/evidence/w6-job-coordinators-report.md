# W6 end-to-end job coordinators evidence report

Status: **implemented, independently reviewed, and locally verified, including exact Pi 0.84.1 integration**

Date: 2026-08-08

This report covers W6 only. It does not claim SwiftUI integration, live provider quality, real GitHub or Keychain access, Apple Development signing, installer behavior, merge, or production deployment. Verification used fake GitHub transports, deterministic Pi fixtures and replay, temporary SQLite stores, and local Git repositories. No provider request, real credential access, GitHub request, remote mutation, or merge was performed.

## Baseline and scope

W6 was implemented in the dedicated branch and worktree `feat/jidoka-code-w6-job-coordinators` from merge-base `12f49a2499c8ddc29311d19577b4b1dd06955950`, the merge of W5 PR #7.

Implemented surfaces:

- application-only Pi preparation that preserves W5 ownership of runtime resolution, resource provenance, canonical argv and environment, private configuration, session identity, tool profile, workspace, and command inventory;
- PR review from exact discovery through independent REST and fetched-Git commit derivation, topological narrative validation, deterministic review routing, durable multipart marker publication, read-back attribution, reviewed revision persistence, and cleanup;
- issue triage from exact issue revision through deterministic rubric, marker-before-label ordering, workflow and domain labels, disposition persistence, stale-input invalidation, retry generation, and cleanup;
- issue implementation with ready and approved-complex claims, durable revision-bound plan envelopes, plan-first commits, frozen command execution, orchestration, exact-head import, create-only push, PR publication, issue link, QA, post-open review enqueue, blocked publication, and cleanup;
- prepared-before-send mutation intents for marker parts, labels, branch publication, PR creation, and issue links, including late visibility, multiple retry generations, and no blind duplicate create;
- coordinator startup recovery, lease reconciliation, exact retry deadlines, completed-step advancement, workflow-specific terminal cleanup sweeps, and preservation of dirty interrupted-writer workspaces;
- bounded PR derivation with commit-count, aggregate-byte, and monotonic wall-clock ceilings;
- reviewer profiles that are read-only for architecture, security, and test roles in planning and orchestration.

## Recovery and security falsifiers

Permanent tests cover these previously reproduced failure classes:

1. a crash after `appendCompletedStep` reruns the next transition rather than repeating Pi or a remote mutation;
2. triage input invalidation does not fabricate a completed publish or reconcile step;
3. an approved claim resumes orchestration without replanning;
4. stale approval completion is persisted only after exact label mutation attribution;
5. ambiguous or delayed marker and PR creates inspect every prior durable generation before an authorized resend;
6. multipart marker recovery collects all existing part intents across SQLite reopen and never sends after uncertainty;
7. label mutation resumes only an attributed prefix, preserves exact expected state, canonicalizes workflow label case, and keeps unknown composite operations safely retryable;
8. marker attribution filters exact author identity and binds repository, object, revision, generation, operation, and document digest;
9. dirty workspace evidence after an interrupted Pi writer is retained and blocked rather than blindly retried or cleaned;
10. cleanup authorization is workflow-specific and requires an exact completed terminal publication or reconciliation step;
11. symlinked private runtime directories, stale issue input, stale base revisions, REST/Git commit divergence, oversized commit narratives, and deadline exhaustion fail before Pi or publication;
12. crash-boundary recovery reconstructs fresh SQLite stores and production workflow components for PR review, triage, and implementation.

The excluded same-user threat model remains unchanged: a hostile concurrent process racing filesystem components, and an unobserved child that immediately escapes with `setsid()`.

## Independent review

A final narrow fresh-context review rechecked every prior Critical or Major finding against current source and tests:

- architecture reviewer: **96/100, READY**, all eight requested findings closed;
- security reviewer: **96/100, READY**, no Critical, Major, or Minor finding in scope;
- test reviewer: **100/100, READY**, no remaining requested test gap.

The reviewers were read-only. Their verdicts do not replace executable verification.

## Pi 0.84.1 integration validation

The installed global Pi advanced externally from `0.84.0` to `0.84.1`. The existing policy first rejected it through both JavaScript package-tree attestation and the Swift resolver. No semver-only bypass was introduced.

Validation was performed first in an isolated copy with a temporary exact policy. The policy entry binds four critical files and the complete package tree. Compared with 0.84.0, the three executed JavaScript critical-file digests remain identical; package metadata and the complete tree changed. The isolated copy passed `make check`, package E2E, and packaged S4, S5-S7, and S8 offline preflights before the same byte-identical 15-file delta was applied to this worktree.

The versioned policy retains the exact 0.84.0 build and adds only this exact 0.84.1 build:

```text
Pi policy:          324d6a1738c08fd7dfbc1ca8fb324ed64d8fc3ac5bd1e2c293062cf4d4238248
Pi 0.84.1 tree:     20,542 entries, 27c1f40f992ef0f550f67711e8c223f5f616167f97a20d2ed62b2ab5782c009e
Workflow manifest:  4d7be2b7ed582f2195bf19953dc74420be12c9066c2a9565b64f09afc204d566
Profile probe:      83d081f9337bc1531e8c516e4248c324de26e325a4f8ef3895eb3df3417d45e9
Workflow probe:     731267cc54cf7018258afc4393ca3357166c10c43b23601c420c597eb196f772
```

The preflights execute the real installed Pi with isolated homes, empty authentication, exact packaged provenance, and no provider request. They prove startup, attestation, RPC/profile preparation, timeout cleanup, and workflow resource compatibility. They do not prove provider-backed model quality.

## Final local verification

The complete `Sources` and `Tests` content hash after the final source edit was:

```text
9e127f439791c870b9312a848970d961421ff8c8193ca57978c5eb94a18db3e4
```

Fresh commands on the final worktree:

```text
make check
make test-e2e
make jidoka-code-test-s4-preflight
make jidoka-code-test-s5-s7-preflight
make jidoka-code-test-s8-preflight
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --sanitize=address
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --sanitize=thread
git diff --check
```

Observed results:

- `make check` passed toolchain verification, shellcheck, Node syntax and contract suites, strict Swift format, debug and release builds, and **302 tests in 52 suites**;
- package E2E passed with ad-hoc signing, copied execution and mutation falsifiers; the packaged extension RPC preflight reported `providerCalls=0`;
- S4 packaged Pi preflight passed exact provenance, bounded timeout/abort and ledger checks with `providerCalls=0`;
- S5-S7 packaged local preflight passed two receive requests, 120 mutation cases and cleanup with `providerCalls=0`;
- S8 packaged workflow preflight passed four command profiles, the 15-role matrix, historical ledger boundary and cleanup with `providerCalls=0`;
- AddressSanitizer and ThreadSanitizer each passed **302 tests in 52 suites**;
- `git diff --check` passed and the source/test content hash remained unchanged.

## Remaining risks and exclusions

- Pi 0.84.1 admission is exact to the locally validated package tree. A repack, dependency drift, changed permission, symlink, inventory change, or critical byte remains blocked.
- No live provider run was performed. Deterministic fixtures verify workflow contracts, not model quality.
- No real GitHub, Keychain, remote branch, issue, label, comment, or PR mutation was exercised by the application runtime.
- Package E2E used ad-hoc signing. Apple Development signing remains a later gate.
- W7 UI and lifecycle integration, W8 installer and operations documentation, and W9 installed canary remain open.
- The most likely integration risk is W7 exposing a recovery or authorization control that does not preserve W6's exact revision, mutation generation, and retained-workspace evidence boundaries.
