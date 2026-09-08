# ABOUTME: Consolidated round-1 review of W9.0 (commit 4dc9cbc) and the disposition of every finding
# ABOUTME: One row per defect, however many reviewers reported it; evidence is what settles it

Round 1, budget 5, scope full. Four reviewers (architecture, security, database, test), all
returned, each in its own worktree, none touching the main tree.

## Critical

| # | Defect | Reported by | Disposition |
|---|--------|-------------|-------------|
| C1 | The proposal's read authority carried a synthetic `jobID: UUID()` while the Git effect carried the binding's, so `reserveGitRemoteRead`'s `effect.jobID == jobID` guard could never hold and every proposal fetch was refused | architecture (CRITICAL), security (MAJOR) | Fixed. The builder takes a Git-inspector factory and the authority is built once the binding resolves. Pinned by `proposalGitReadAuthority`, which drives a real `BoundedRolloutPreviewReadAuthority` |
| C2 | `gitRemoteReads = 1` against the two authorized reads `derivePullRequest` performs, so the head fetch was refused; the same constant went into the lane budget, making every produced preview unactivatable | architecture (CRITICAL), security (MAJOR) | Fixed: 2, with the reason in the source. Pinned by `proposalGitReadAuthority` and `proposalPolicyCeilings` |
| C3 | All 17 producer guards untested: replacing five of them with `guard true` left the suite green | test | Fixed. `proposalGuardsRefuseDrift` is one case per reachable guard (16); two guards were unreachable by construction and removed rather than tested vacuously |
| C4 | The read ceilings were pinned as constants but the wiring that applies them was unenforced: setting the call sites to 9_000 left the suite green | test | Fixed. `ProductionEngineExternalServices.exactProposalCeilings()` is the single source the three authorities use, pinned by `exactProposalCeilings` |
| C5 | The proposal's paused/exclusive/checkpointing refusal was untested | test | Fixed at the runtime by `proposalRefusesBeforeFetching`. The service-level re-check is unreachable in tests because the schema latch forbids an unpaused engine without an active lane; the dispatch ordering is pinned instead |

## Major

| # | Defect | Reported by | Disposition |
|---|--------|-------------|-------------|
| M1 | On a populated `rollout_authorization_scopes`, migration 11 silently relabels each row as minted by the new release: `ALTER TABLE` fires no row trigger, the drop discards the pins and the re-add refills them from the DEFAULT | database (MAJOR), security (MINOR) | Fixed. The migration opens with a guard that counts the rows and fails the whole migration closed if the table is not empty. Reproduced before fixing (`BEFORE|auth-1|10|12` then `AFTER|auth-1|11|13`) and pinned by `rolloutScopeRepinRefusesPopulatedTable` |
| M2 | The pins 11/13 were bare literals with no link to `EngineProtocolVersion.current` or the migration's own version | database | Fixed by `rolloutScopeRepinMatchesDeclaredIdentity`. The literals stay, because a shipped migration body is frozen; the test is what couples them |
| M3 | The production wiring of `.proposeExactRollout` was untested end to end | architecture | Fixed by `proposeExactRolloutDispatch`, `exactProposalCeilings`, `exactProposalIdentityBinding` |
| M4 | The observed-vs-configured GitHub account cross-check was untested | test | Fixed: extracted as `requireProposalIdentity` and pinned by `exactProposalIdentityBinding` |
| M5 | The ambiguous-repository refusal was untested | test | Fixed by `proposalRefusesBeforeFetching` |
| M6 | Neither job-binding guard was killed by a test | test | `job.objectNumber` is now pinned by `proposalJobBinding`; the duplicate-identity count was unreachable (`jobs` is UNIQUE on that tuple) and was removed |
| M7 | Nothing proved the service revalidates the proposal it just produced, which is the commit's central claim | test | Fixed by `proposeExactRolloutDispatch` |
| M8 | `RolloutExactProposalRequest.validate()` had no test | test | Fixed by `proposalRequestValidation` |
| M9 | The command validator branch and the whole client-side response binding were untested | test | Fixed by `proposalRequestValidation` and `proposalResponseBinding` |
| M10 | `propose-exact` argument parsing was untested | test | Fixed by `proposeExactParsing` |

## Minor

Fixed: the client now binds the policy budgets (security, architecture); the runtime refuses a
closed repository and a busy engine before spending the fetch (architecture); the producer takes
the repository ceiling from the same mapping revalidation uses, so a proposal at the ceiling no
longer fails its own revalidation (architecture); migration 10's "has never shipped" comment was
false once build 6 reached production (database); `SettingsViewModel.proposalRequest()` is pinned
by `rolloutProposalGate` (test).

Recorded as debt, not introduced by this change:

- `SQLiteStore` takes the pre-migration backup before `BEGIN IMMEDIATE`, so a concurrent writer
  could land outside the backup and inside the migration (database MINOR). Pre-existing in the
  generic migrator; the schema-11 guard closes the case that matters here because it counts
  inside the transaction.
- One unreproduced 7-issue suite failure (test MINOR): eight further runs of the same source were
  green, including two immediate re-runs. Not reproduced, not diagnosed.

Left as is: `closedRepositoryProposalRefused` builds a producer it does not need, but it does kill
the `reviewEnabled` mutant, so it is not a vacuous test.

## Verification after the fixes

`make check` exit 0. 803 tests / 89 suites. `swift-format lint --strict` clean over Sources and
Tests. Static rollout preflight PASS. Preflight script tests PASS.

## Harness defect

`isolation: "worktree"` gave every reviewer a worktree of the session's primary repository rather
than the checkout under review, so `4dc9cbc` did not resolve there. The database reviewer lost its
Swift-level leg and compensated with SQL probes against a read-only copy; the others worked from
the checkout directly. Worth fixing in the launch path.
