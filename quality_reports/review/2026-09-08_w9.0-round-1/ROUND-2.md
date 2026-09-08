# ABOUTME: Round-2 review of the W9.0 fix commits and the disposition of every finding
# ABOUTME: Scoped to the fixes themselves: does each one close its finding, or only look like it

Round 2, budget 5, scope full. Two reviewers (test, security), both told the real clone path
because `isolation: "worktree"` clones the session's primary repository instead. Measured against
`7357f55`; the fixes below land on top of `33bc49e`.

## What round 2 confirmed closed

Attacked and held: the job-id binding (C1) and the two-remote-read ceiling (C2) are correct in
source; 15 of 16 producer conditions are killed one mutation each by `proposalGuardsRefuseDrift`;
deleting `external.revalidateRollout(preview)` turns `proposeExactRolloutDispatch` red; the
migration statement-order pin holds; splitting one read authority into two widens nothing (GitHub
capacity went down from 40 to 39, the Git authority's single request is structurally unspendable
because its protocol has no `reserveGitHubRead`, and the identity and repository authorities admit
disjoint operations); `GitHubGitCredentialProvider` issues no request and no reservation; the repin
guard's abort really does roll the whole migration back, leaving schema 10 rather than a half
repin; and both guards removed as unreachable are genuinely unreachable.

## Major: the extraction made values testable, not the call sites

Four findings with one root cause. `exactProposalCeilings()` and `requireProposalIdentity` were
pinned by tests, but the code that consumed them was not: mutating the call sites left the suite
green. Restating a constant in a test is not the same as testing that production applies it.

Fixed by changing the shape rather than adding assertions:

- `exactProposalAuthorities(repository:)` now constructs both GitHub read authorities, and
  `exactProposalAuthorityWiring` exercises them: each admits exactly its allowance and then
  refuses, and the identity authority refuses a repository read. Widening either ceiling is now
  visible.
- `exactProposalGitInspecting(...)` returns the factory closure, so the job id is bound inside a
  tested function instead of at a call site. The same test drives it and asserts the bound
  authority admits two remote reads for that job, refuses a third, and refuses another job.
- The observed-versus-configured identity check moved into `RolloutExactProposalBuilder`, where
  the drift matrix already lives, as cases `foreignAccount` and `foreignAuthorID`. The caller can
  no longer forget to make the comparison, because it is not the caller's to make.

Verified by re-running the reviewer's own mutations against the fixes: binding the Git authority to
a fresh job id, widening the identity ceiling, and widening the repository ceiling each produce
four failures in `exactProposalAuthorityWiring`; neutralising the identity comparison turns
`foreignAccount` and `foreignAuthorID` red.

## Major: the migration guard test does not use the real table

`rolloutScopeRepinRefusesPopulatedTable` proves a CHECK aborts a transaction against a stand-in
table, not that migration 11 fails a real populated schema-10 database closed. This is accurate and
is NOT claimed as closed.

What is verified, and how: the guard statement names `main.rollout_authorization_scopes`, asserted
structurally; the abort-and-rollback behaviour was probed twice on copies of the real production
database carrying a seeded scope row, once by the database reviewer in round 1 and once by the
security reviewer in round 2, both reporting `CHECK constraint failed: existing_scopes = 0` with the
row still reading `10|12` and the guard table absent afterwards.

What is missing is automation, not evidence. A repo test cannot build the row: the table has 58
NOT NULL columns under tight CHECKs including a canonical `preview_json`, and no code path in this
binary can mint a scope row below schema 11, which is precisely why the guard protects databases
written by the previous release rather than by this one. Recorded as debt.

## Minor

Fixed: the repin guard's names are schema-qualified, because SQLite resolves an unqualified name
against `temp` first, and the test now creates an empty temporary table of that name and asserts
the guard still refuses. The Git allowance is spent per proposal rather than renewed per call.
`pullRequest.number == number` gained the drift case it was missing, so the matrix is now one case
per reachable producer guard (18).

Corrected rather than fixed: round 1 described the service-level `paused` guard as unreachable in
tests. It is expensive to reach, not unreachable, and CONSOLIDATED.md now says so.

## Verification

`make check` exit 0 on a quiet machine, 803 tests / 89 suites, strict lint clean over Sources and
Tests. The first attempt failed: `GitProcessTests` timed out at 80 s while the reviewer was running
its own full suite in a separate clone, against 4.1 s in isolation. That upgrades round 1's
unreproduced flake to a known cause, recorded in CONSOLIDATED.md.

## Process defect, mine

I edited the clone while the test reviewer was mutation-probing it, which could have destroyed its
work or mine. It caught the concurrent writer and stopped; I verified nothing was lost and then
committed to stabilise the tree. The lesson is not "coordinate better": it is that a reviewer given
ISOLATION-EXEMPT is sharing a tree with the author, and the author must hold still or the reviewer
must be given a copy.
