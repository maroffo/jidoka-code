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

## Closing the class rather than the mutations: the end-to-end test

Extraction made the proposal's *values* testable and left its *call sites* unenforced, and the
reviewer named the two mutations that class still admitted. Chasing them one at a time would have
produced two more value assertions and left the third one open, so the fix is a test that drives
`ProductionEngineExternalServices.observeExactPullRequestReview` end to end against a recording
transport: `exactProposalObservationSpendsBothAuthorities` and `exactProposalRefusesAnotherAccount`
in `ProductionEngineExternalServicesTests.swift`. They assert what a call site can actually get
wrong: which four URLs are fetched and in what order, that the binding is keyed by the head the
metadata fetch returned, and that a foreign identity is refused after exactly one request. The run
never reaches the network because the ask-pass helper is a regular non-executable file, so the Git
step refuses with `GitAskPassError.credentialRejected` once every GitHub read the proposal owes has
happened.

Measured against three call-site mutations, with the pre-existing tests as the control:

| Mutation | Pre-existing tests | New end-to-end tests |
|----------|--------------------|----------------------|
| Swap the two authorities, so the identity authority backs the repository broker | all green | both red: `effectAdmissionClosed` after 1 request |
| Neutralise the identity comparison in the builder | `foreignAccount`, `foreignAuthorID` red | also red: the foreign account reaches the Git step |
| Pass `repository.owner` as the expected account | all green | red: `invalidReleaseIdentity` after 1 request |

Two of the three survive every unit test in the suite, including `exactProposalCeilings` and
`exactProposalAuthorityWiring`, which is the measurement that says the class was open. The
reviewer's second prediction (the caller passing the *observed* account as the expected one) is not
constructible at this call site: the builder fetches the identity itself and the caller never holds
it, so the nearest reachable form is the third row above.

## Withdrawn: the migration guard test does not use the real table

Raised as Major, then retracted by the same reviewer with evidence, and NOT carried as debt.
Booking work against a defect its author no longer claims would be worse than the defect.

The retraction decomposes the guard's contract into four parts, each covered: the CHECK aborts on a
non-zero count (behavioural on the stand-in with the real statements); `COUNT(*)` is non-zero on a
populated real table (the guard's SQL is column-agnostic, which is why the stand-in's different
shape does not matter); an abort at statement 2 leaves a real schema-10 database at 10 with its DDL,
ten triggers and integrity intact (`productionRolloutScopeProtocolMigrationRollsBack(afterStatement:
2)` injects a failing statement at exactly that point on a real fixture, and the migrator cannot
tell that abort from the CHECK's); and the temp-shadow hazard is closed by the `main.` qualification
and its own case. The only join the composition leaves open is name resolution, which is the very
thing the qualification fixes. A 58-column fixture would re-prove parts 1 and 3 together and buy
nothing else.

## Test-design defect found while probing: the digest pin masks behaviour

Every migration-11 test calls `productionSchemaElevenMigration()`, which pins the body digest. Any
mutation of the migration body therefore fails the digest assertion first, so an unrepinned probe
measures the change-detector rather than the behaviour. The reviewer re-probed with the digest
neutralised each time and confirmed the behavioural assertions do fire: reordering the guard trio
after both drop/re-add pairs fails four structural assertions plus the admission assertion,
weakening `CHECK (existing_scopes = 0)` to `>= 0` fails admission twice, and un-qualifying the table
name fails the temp-shadow case twice. Worth remembering for any future migration: a digest pin and
a behavioural test in the same suite hide each other unless the probe repins.

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
