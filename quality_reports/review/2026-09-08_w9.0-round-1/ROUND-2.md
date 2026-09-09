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
per reachable producer guard (19).

Corrected rather than fixed: round 1 described the service-level `paused` guard as unreachable in
tests. It is expensive to reach, not unreachable, and CONSOLIDATED.md now says so.

## The residue the end-to-end test left, and the one it cannot close

Re-probed against `8a1a116`, the reviewer ran eight mutations; seven died. The survivor was the
residue of the ceiling finding one level up: `exactProposalAuthorities` is well tested, but nothing
obliged the call site to *use* what it returned. Replacing `authorities.repository` with an inline
authority of 60 requests (budget-legal, so it does not die on `invalidBudget`) left the whole suite
green, because a well-formed proposal makes three repository reads and no test that counts URLs can
tell 39 from 60.

Closed by `exactProposalRepositoryAllowanceStopsAtTheCeiling`, which spends the allowance instead of
describing it: the transport serves a pull request whose commit pages never stop being full, so the
fetch keeps paginating until the authority refuses. The assertion is
`identityRequests + repositoryRequests` recorded URLs and the last one being commit page 37. Under
the reviewer's mutation it records 61 and stops at page 58.

The symmetric residue on the identity leg stays open and is stated rather than closed: a call site
that discards `authorities.identity` for a wider one is invisible to any end-to-end test, because
this path calls `authenticatedIdentity()` exactly once and an unspent allowance has no observable
width. Its blast radius is smaller in kind, not only in degree: that authority is built with
`repository: nil` and admits only the identity operation, so a widening buys extra `/user` reads and
no repository data, no Git read and no mutation. `exactProposalAuthorityWiring` pins the value the
factory returns; nothing pins that the call site used it. Adding another factory level would move
the seam rather than remove it, which is the mutation-chasing this section exists to avoid.

The reviewer measured the symmetric mutation independently (inline identity authority, 20 requests,
`repository: nil`, bytes scaled: 790/790 green) and agreed it should be stated, with two arguments
better than the one above. The containment is itself under test, not merely asserted:
`exactProposalAuthorityWiring` already pins that the identity authority refuses a repository read,
so the property that makes a widening harmless is verified even though the width is not. And the
hole is unobservable in principle, not merely untested: closing it would mean either making the
production path paginate `/user`, which does not exist, or asserting on the authority object instead
of on behaviour, which is exactly the shape that failed three times in this review. A test writable
only by abandoning the discipline that found these defects is not worth having. The reason to state
this one is the containment, not the difficulty.

Two corrections the reviewer volunteered against itself, both worth keeping. First, the ask-pass
refusal does mask the Git-side admission: with the real factory's `gitRemoteReads` widened from 2 to
9 the two end-to-end tests stay green, because `derivePullRequest` builds the credential provider
before the only `reserveGitRemoteRead` downstream of it. That leg is covered by
`exactProposalAuthorityWiring` (the widening kills it), and the end-to-end test now says in a
comment where it actually stops. Second, the transport's 404 default is not what catches an extra
read: the recorder appends the URL before the response is served, so a fifth read is caught by the
order assertion. The 404 is belt-and-braces.

The reviewer also withdrew its own second prediction: the caller passing the *observed* account as
the expected one is not constructible here, because the builder fetches the identity itself and
returns only after the comparison. Moving the check inside closed the hatch rather than relocating
it.

## Reviewer re-measurement of the round-2 fixes

The test reviewer re-probed `ab5c0d5` (787 tests / 87 suites green, with the two load-flaky process
suites skipped so its verdicts do not depend on that suite's mood) and reported four call-site
findings closed on behaviour, not on added assertions:

| What was mutated | Result |
|------------------|--------|
| `jobID: jobID` -> `jobID: UUID()` in `exactProposalGitInspecting` | `exactProposalAuthorityWiring` red, `effectAdmissionClosed` |
| identity ceiling 1 -> 5, bytes scaled to match | red on the admission assertion and on `reservedRequests` |
| repository ceiling 39 -> 60, bytes scaled | red on the admission assertion |
| both new identity conditions -> `true, true` | `proposalGuardsRefuseDrift` red on `foreignAccount` and `foreignAuthorID` |
| memoization consultation deleted from the box | red in two places |

It also corrected its own method, which is the more useful half of the report: its first attempt at
the two ceiling widenings used 9,000 requests and 9 GB, and both died on the authority's
`invalidBudget` constructor check rather than on any admission assertion. That would have reported
the ceilings closed on evidence proving nothing about them. Only budget-legal widenings probe a
ceiling.

The one finding it left open was the authority swap at the two `GitHubBroker` constructions, which
left its whole suite green. It graded it Minor rather than Major on the argument that the failure is
loud (the repository broker inherits a one-request allowance and the proposal dies on its second
repository read) rather than a quiet weakening. That reasoning is right about severity and does not
change what the test owed: a call site the suite cannot see is a call site. It is now killed by both end-to-end tests,
which is the first mutation row of "Closing the class" above.

## Score derivation

One finding stays open and attributable to this change: the identity-leg call site, whose width no
test observes. It is graded Major under "missing test coverage for new code" rather than Minor,
because the code is new and the call site genuinely has none, and accepting it is a judgement about
blast radius, not evidence that it is covered.

```
100 - 10 (identity call site, open and accepted) = 90
```

The flaky process suites (`GitProcessTests.swift:325`, `PiRPCProcessTests.swift:130`) are a real
Major and are not scored here: they pre-date this change, no line of this diff touches them, and
they are tracked from round 1. Scoring them against this PR would make every future PR in this
repository carry the same ten points until someone fixes them, which is a worse accounting than
naming them separately.

Finding D and the authority swap are two different mutations and were briefly conflated in a message
to the reviewer, not in this artifact. The swap makes the repository allowance *smaller*, so the
proposal dies on its second read and every assertion fires: loud. D makes it *larger*, so everything
behaves identically until something spends the difference: silent. The reviewer's Major grade for D
was right on exactly that distinction.

## Verification

Read the test count with the flake in mind. `make check` runs everything, including the two suites
that fail under load; the reviewer's 790/87 figures come from runs with `GitProcessTests` and
`PiRPCProcessTests` skipped, so its mutation verdicts do not depend on that suite's mood. Both are
green. If `make check` goes red on another machine, check those two suites before re-opening this
change.

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
