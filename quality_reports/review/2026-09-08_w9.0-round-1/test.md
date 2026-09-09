# ABOUTME: Test-quality review of W9.0 commit 4dc9cbc, the exact rollout proposal producer
# ABOUTME: Mutation-probe evidence for every finding; run in an isolated clone, main tree untouched

# Test Review — W9.0 `4dc9cbc` (exact rollout proposal producer), test quality

Method: the commit was reviewed in an isolated clone at `4dc9cbc`
(`/private/tmp/.../scratchpad/w9copy`, `git status` clean at the end of the review; the
main tree at `/Users/maroffo/jidoka-code-w9` was never written except for this file).
Every finding below is backed by a mutation probe: the named source edit was applied to
that clone and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
was run to completion. Baseline before any probe: **790 tests / 89 suites green** (three
consecutive clean runs). "Survived" below means the full suite still reported
`Test run with 790 tests in 89 suites passed` with the mutation in place.

## Headline

The four new producer tests do not test the producer's guards. Not one of the seventeen
validation conditions in `RolloutExactProposalBuilder.observePullRequest` is killed by any
test in the repository, and neither is any guard on the engine-side path that reaches it
(`ProductionEngineJobRuntime`, `ProductionEngineExternalServices`, `EngineService`,
`EngineProtocol`, `RolloutCLI`, `SettingsViewModel`). What the new tests do pin is a set of
policy **constants** and one pre-existing `RolloutPreviewBuilder` guard.

Of the six properties the plan requires proof of, two are proven by a test, one is proven
only at a layer below the producer, and three are asserted in prose or pinned as a literal
that no behaviour depends on.

| Plan requirement | Proven by a test? | Where |
|---|---|---|
| Altered bytes rejected | **Yes** | `alteredProposalFailsClosed` + the revalidation in `exactProposalRoundTrips` |
| Producer and validator agree | **Yes** | `exactProposalRoundTrips` runs the real `RolloutRemotePreviewRevalidator` over the produced selector |
| Refusal for `review_enabled = 0` | **Yes, but one layer down** | `closedRepositoryProposalRefused` kills `RolloutAuthority.swift:1132`; it never exercises the producer |
| Fixed read ceilings | **No** | constants pinned; the wiring that applies them is unenforced (F2) |
| No provider session / no mutation / no Git send | **No** | pinned as literals in `RolloutBudgets`; no test observes the proposal path performing zero of them |
| Refusal for unpaused scheduler / open lane | **No** | F4, F6, F7 |

---

## CRITICAL

- **`Sources/JidokaCodeCore/Application/RolloutExactProposalBuilder.swift:37,45,57,72,90`**
  — F1. Every guard in the producer is untested. The three tests that construct a
  `RolloutExactProposalBuilder` all drive the same happy-path fixture; there is no negative
  case for account validity, repository node/owner/name/default-branch agreement, PR state
  (`open`, `!draft`, base ref, SHA validity, base != head), job-binding shape, or the
  REST-vs-fetch commit reconciliation. Fix: add one parameterised negative test per guard,
  driving a fixture whose single field is drifted, asserting the exact
  `RolloutAuthorityError` case. | evidence: all five `guard` conditions replaced by
  `guard true else` (the job-binding one reduced to `guard let jobID = UUID(uuidString:
  binding.jobID) else`) — full suite **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/ProductionEngineExternalServices.swift:432,447,452`**
  — F2. The read ceilings the plan calls fixed are pinned only as constants in
  `proposalPolicyCeilings`; nothing tests that they are the values actually handed to
  `BoundedRolloutPreviewReadAuthority`. A typo or a deliberate widening at the call site is
  invisible. Fix: add a test that drives `observeExactPullRequestReview` against a counting
  transport and asserts the request/byte/git-remote-read authority actually granted. |
  evidence: `maximumRequests: RolloutExactProposalPolicy.identityRequests` to `9_000`,
  `maximumRequests: RolloutExactProposalPolicy.repositoryRequests` to `9_000`,
  `maximumGitRemoteReads: RolloutExactProposalPolicy.gitRemoteReads` to `9_000` — suite
  **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:480`** — F4. The
  "the scheduler must be paused" refusal is untested. `guard paused, exclusiveOperations ==
  0, !checkpointing` in `proposeExactRollout`, plus the `UUID(uuidString: repository.id)`
  check immediately after it, can both be deleted without any test noticing. Fix: add a test
  that calls `proposeExactRollout` on an unpaused runtime and expects
  `EngineClientError(.busy)`. | evidence: both guards deleted from
  `proposeExactRollout` — suite **survived**, 790/790 green.

## MAJOR

- **`Sources/JidokaCodeCore/Application/ProductionEngineExternalServices.swift:500`** — F3.
  The cross-check that the account the builder observed on GitHub is the account the app is
  configured with (`githubAccount` / `githubAuthorID`) is untested. Fix: add a test with an
  identity reader returning a different login/id and expect
  `RolloutAuthorityError.invalidReleaseIdentity`. | evidence: the whole `guard
  observation.githubAccount.caseInsensitiveCompare(account) == .orderedSame,
  observation.githubAuthorID == authorID` block deleted — suite **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:414`** — F5. The
  ambiguous-repository refusal (`matches.count == 1`) is untested: with two configured
  repositories matching the same owner/name case-insensitively, the first one silently wins.
  Fix: add a test with two such rows expecting `invalidRepositoryIdentity`. | evidence:
  `guard matches.count == 1, let repository = matches.first` reduced to `guard let
  repository = matches.first` — suite **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:449`** — F6. The
  open-lane refusal in `rolloutExactJobBinding` is untested. Neither `existing.count <= 1`
  (more than one non-terminal job on the same logical identity) nor `job.objectNumber ==
  objectNumber` is killed by anything. This is the "open lane" proof the plan asks for.
  Fix: add two tests, two non-terminal jobs on one identity, and one job whose
  `objectNumber` disagrees; both expect `RolloutAuthorityError.jobBindingMismatch`. |
  evidence: the `existing.count <= 1` guard deleted and `job.objectNumber == objectNumber`
  dropped from the `currentStepKind` guard — suite **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/EngineService.swift:672`** — F7. The service-level
  `guard try await configuration.appConfiguration().paused` on `.proposeExactRollout` is
  untested. Fix: add an `EngineServiceTests` case issuing `.proposeExactRollout` while
  unpaused and expecting `.busy`. | evidence: guard deleted — suite **survived**, 790/790
  green across two independent runs.

- **`Sources/JidokaCodeCore/Application/EngineService.swift:698`** — F8. The commit's own
  central claim ("a proposal is not an authority: it must survive the same revalidation
  activation runs") is not tested at the service level. Removing the post-proposal
  `external.revalidateRollout(preview)` changes no test outcome. `exactProposalRoundTrips`
  proves the *revalidator* accepts a produced selector, but nothing proves the *service*
  calls it. Fix: add an `EngineServiceTests` case with an external fake that records
  `revalidateRollout` calls and asserts one occurred for `.proposeExactRollout`. | evidence:
  the `try await external.revalidateRollout(preview)` line at 698 deleted — suite
  **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/State/RolloutAuthority.swift:1519`** — F9.
  `RolloutExactProposalRequest.validate()` has no test at all. Owner/repository name
  validation, `number > 0 && number <= 1_000_000`, and the `(60...900)` expiry window are
  all unexercised. Fix: add a table-driven test over invalid owners, names, numbers and
  expiry values expecting `invalidObjectSelector`, plus one valid case. | evidence: the
  entire `guard`/`throw` body of `validate()` replaced by `_ = owner; _ = name; _ = number;
  _ = expiresInSeconds` — suite **survived**, 790/790 green.

- **`Sources/JidokaCodeCore/Application/EngineProtocol.swift:616,919`** — F10. Both
  protocol-side guards for the new command are untested: the command-side `try
  request.validate()` branch, and the substantial client-side response-binding guard that
  ties the returned preview to the requested owner/name/number, to
  `.exactObject`/`.prReview`, to `RolloutExactProposalPolicy.pullRequestReviewBudgets`, and
  to the requested expiry window. That guard is the client's only defence against a
  substituted preview, and the comment above it explains exactly why it matters. Fix: add
  response-binding tests that mutate one field of the returned preview at a time and expect
  `.invalidResponse`. | evidence: the `.proposeExactRollout` case in the command validator
  reduced to `break`, and the response guard reduced to `guard result.state.paused, let
  preview = result.rolloutPreview` (dropping the recovery-preview, canonical round-trip,
  mode, stage, owner, name, object number, job-binding number, budget and expiry
  conditions) — suite **survived**, 790/790 green.

- **`Sources/JidokaCodeApp/RolloutCLI.swift:60,71`** — F11. The `propose-exact` argument
  parsing is untested. `RolloutCLITests` mentions `.proposeExactRollout` only in the timeout
  table; nothing parses the subcommand. Both the `owner/name` split and the `try
  request.validate()` gate can be removed silently. Fix: add parse tests for
  `propose-exact`: valid, missing slash, extra slash, non-numeric number, out-of-range
  expiry. | evidence: `coordinates.count == 2` relaxed to `>= 1` and `try
  request.validate()` deleted at line 71 — suite **survived**, 790/790 green.

## MINOR

- **`Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift:483-509`** — F12.
  `proposalPolicyCeilings` is a change-detector, not a behavioural test: it restates the
  constants declared in `RolloutExactProposalPolicy`. It does catch an accidental edit to
  the declaration, but the test name promises something the test does not deliver ("spend no
  provider session or mutation" is never observed). The `mapped.repositoryRequests == 39`
  assertion is the one line in it that checks a derivation rather than a literal. Fix: keep
  it, rename it to what it is (the proposal policy constants are pinned), and add the
  behavioural test F2 asks for. | evidence: `repositoryRequests = 40` to `41`, `labelWrites:
  0` to `9`, `gitSends: 0` to `9` — **killed**, 4 issues at lines 484, 504 (x2) and 509. The
  constants are genuinely pinned; nothing downstream of them is.

- **`Sources/JidokaCodeAppSupport/SettingsViewModel.swift:528,535`** — F13.
  `proposalRequest()` is untested: `ViewModelFlowTests` adds `.proposeExactRollout` only to
  the `invalidCommand`-throwing branch of `AppSupportEngineFake`, and no test calls
  `model.proposeExactRollout()`. Fix: add a view-model test covering a valid reference, a
  reference with no slash, and a non-numeric number. | evidence: `coordinates.count == 2`
  relaxed to `>= 1` and the `guard (try? request.validate()) != nil` line deleted — suite
  **survived**, 790/790 green.

- **`Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift:429-437`** — F14.
  `closedRepositoryProposalRefused` constructs a `RolloutExactProposalBuilder` and calls
  `observePullRequest`, but the assertion it makes is about `RolloutPreviewBuilder.make`
  with a hand-mutated repository identity. The builder call is dead setup, the test would
  pass identically with a literal selector, so the name over-promises about the producer.
  Fix: either assert that `observePullRequest` itself refuses a disabled repository (it
  currently does not check `enabled`/`reviewEnabled` at all: see F1), or drop the builder
  from the test and name it after the preview-builder guard it really covers. | evidence:
  `RolloutAuthority.swift:1132` `case .prReview, .generatedPRReview:
  repository.reviewEnabled` replaced by `true` — **killed**, and killed by exactly one test
  in the whole suite: this one, at line 462, `Expectation failed: an error was expected but
  none was thrown`. The guard it covers lives in `RolloutPreviewBuilder`, not in the
  producer.

- **Suite-wide** — F15. One non-deterministic failure was observed: a run with the F7+F9
  mutations applied reported `Test run with 790 tests in 89 suites failed after 62.049
  seconds with 7 issues`, while two immediately following runs of that same source, and six
  further runs of other sources, all passed. The failing test names were not captured (the
  reporter writes failures to stderr and that run's output was filtered). This is weak
  evidence, but it is evidence of a suite that can fail without a source change. Fix: re-run
  the suite under `--repetitions` or in a loop and capture full stderr, to find whether a
  test is order- or timing-dependent. | evidence: the divergent run above, against source
  that two subsequent identical runs passed.

---

## Part (A) — assessment of the four new producer tests

**`exactProposalRoundTrips` — genuine, and the best test in the change.** It does not
compare the producer against itself. It compares `observation.object` against the selector
the fixture builds by hand from literals (`exactPreview()`, line 865), and then feeds the
produced selector through the real `RolloutRemotePreviewRevalidator`, which independently
re-derives the two digests from the mock API and Git readers. Producer and validator are
two distinct code paths and the test does prove they agree. Two caveats, neither a finding:
the hand-built oracle calls the same derivation helpers (`SystemPullRequestReviewJobPreparer
.artifact`, `GitHubMarkerCodec.sha256`, `PiPullRequestReviewRouter.commitNarrativeDigest`),
so a change to canonicalisation moves both sides in lockstep and no golden digest catches
it; and the `#expect`s inside the `resolveBinding` closure, plus the actor-based call
counter, correctly pin that the binding is resolved exactly once with the head SHA as the
revision key.

**`alteredProposalFailsClosed` — passes, but adds little over what already existed.** It
tampers `canonicalInputSHA256` and expects `previewDrift`. The pre-existing test "exact PR
preview rejects every independently drifted remote binding" already covers selector drift
across every field. Its value is that it starts from a *produced* selector rather than a
hand-built one. I did not find a mutant it uniquely kills, so I raise no finding.

**`closedRepositoryProposalRefused` — real coverage, misattributed.** See F14: it is the
only test in the suite that kills the `reviewEnabled` guard, which is worth having, but it
covers `RolloutPreviewBuilder`, not the producer, despite constructing one.

**`proposalPolicyCeilings` — a constant pin.** See F12.

### Guards for which no test goes red

`RolloutExactProposalBuilder.swift`: account login validity and `account.id > 0` (37);
repository `nodeID` (45), `owner` (46), `name` (47), `defaultBranch` (48); PR `number` (57),
`state == "open"` (58), `!draft` (59), `base.ref` (60), base SHA validity (61), head SHA
validity (62), `base.sha != head.sha` (63); job-binding UUID canonical lowercase (73) and
`objectNumber` (74); `restCommits == fetched.commitSHAs` (90), `fetched.baseSHA` (91),
`fetched.headSHA` (92).

`ProductionEngineExternalServices.swift`: identity/repository/git-remote read ceilings (432,
447, 452); account and author-id cross-check (500).

`ProductionEngineJobRuntime.swift`: `matches.count == 1` (414); `existing.count <= 1` (449)
and `job.objectNumber == objectNumber` (441); `paused, exclusiveOperations == 0,
!checkpointing` (480) and the repository UUID check that follows it.

`EngineService.swift`: `.proposeExactRollout` paused guard (672); post-proposal
`revalidateRollout` (698).

`RolloutAuthority.swift`: the whole of `RolloutExactProposalRequest.validate()` (1519).

`EngineProtocol.swift`: the command-side `validate()` branch (616); every clause of the
client-side response-binding guard except `result.state.paused` and the presence of a
preview (919-937).

`RolloutCLI.swift`: `propose-exact` coordinate split and `validate()` (60, 71).

`SettingsViewModel.swift`: `proposalRequest()` coordinate split and `validate()` (528, 535).

---

## Part (B) — the edited existing tests

All of these were checked for silent weakening. **None of them weakened its test.**

**`SQLiteStoreTests.swift` — the `schemaTenMigrations` repointing is legitimate scoping, not
a loss of coverage.** The five repointed call sites belong to tests whose subject is the
8-to-10 and 9-to-10 transitions and which pin `schemaVersion() == 10`; running them against
the full chain would have carried them to 11 and made their own assertions false. The full
chain is still exercised, in three places: the new `productionRolloutScopeProtocolMigration`
(9 to 10 to 11 with `DatabaseSchema.migrations`), `ShippedSchemaNineMigrationTests` (ledger
pinned to `Array(1...11)`), and `PiRunStoreTests.migrationPreservesLegacyRun`
(`schemaVersion() == 11`, 9 backups). Nothing that used to run the whole chain stopped
running it.

The two new migration tests are the strongest tests in the commit.
`productionRolloutScopeProtocolMigration` pins the migration digest, the backup filename and
its `0o600` mode, asserts the DDL both gains `schema_version = 11` /
`engine_protocol_version = 13` and loses the old values, asserts the ten triggers
referencing `rollout_authorization_scopes` survive a drop-and-re-add of two columns by
comparing the exact name list before and after, asserts no row is manufactured, runs an
integrity check, asserts idempotent reopen, and asserts an older binary refuses with
`migrationTooNew(database: 11, supported: 10)`.
`productionRolloutScopeProtocolMigrationRollsBack` cuts the migration after each of its four
statements and verifies the database is left at 10 with the old DDL, the ten triggers, and
integrity intact.

**`ShippedSchemaNineMigrationTests.swift` — intent preserved and slightly strengthened.**
The ledger assertion went from `last?.digest == migrationTen...` to pinning `[9]` and
`last` separately, so both digests are now checked rather than only the tail; the backup
count went 1 to 2 with both filenames (`.before-v10-`, `.before-v11-`) asserted
individually. No assertion was loosened.

**`HerdrPiWorkflowRuntimeTests.swift:3998` — the `== 10` to `>= 10` change is correct and
load-bearing, not a weakening.** With schema 11 as the fresh version, `== 10` would have
made the gate false for every fixture and silently stopped activating the rollout lane in
every test that asks for one. Evidence: reverting `>= 10` to `== 10` in the clone made the
suite report `Suite "Production Herdr Pi workflow runtime" failed ... with 70 issues` (33
tests). The `>=` form activates the lane in exactly the state the fixture intends: the
companion release-identity fixture in the same file was bumped to `schemaVersion: 11,
engineProtocolVersion: 13` in the same commit, so the admission it writes matches the new
column CHECK. Historical generation-0 incidents still opt out via `activateRollout: false`,
not via the schema number, so widening the schema comparison does not reach them.

**`ConfigurationStoreTests.swift`** — backup count 9 to 10, the rollout backup moved from
`.last` to index `[8]`, and a new index `[8]`/`last` pair added with its own reopened-store
assertions on schema 10 and row counts. Strictly more assertions than before.

**`PiRunStoreTests.swift`** — same shape: the v9 backup moved from `.last` to `[7]` and a
new v10 backup block was added asserting `schemaVersion() == 10` and the legacy row's
survival. The second edit (`migrationBackups.count == 1` to `2`) is the shipped-schema-9
path and is consistent with migration 11 requiring a backup.

**`RolloutCLITests.swift`** — `responseBudgets` was rewritten from a two-way ternary to a
set membership test. Same exhaustiveness over `EngineCommandKind.allCases`, same assertion
per kind; the new command is correctly placed in the 700 s set. No weakening.

**`RolloutAuthorityStoreTests.swift`, `RolloutEffectAuthorityTestSupport.swift`,
`RolloutReleaseIdentityAttestorTests.swift`, `JobCoordinatorTests.swift`,
`DurableJobStoreTests.swift`, `ViewModelFlowTests.swift`** — faithful constant bumps
(build 6 to 7, schema 10 to 11, protocol 12 to 13, migration count 10 to 11). The attestor's
drift matrix correctly moved its *drifted* values too (`databaseSchema` drift 9 to 10,
`engineProtocol` drift 11 to 12, `bundleBuild` drift 7 to 8), so each drift case still
differs from its baseline by exactly one field. `RolloutOperatorReleaseIdentity` gained an
`observedIdentity()` conformance that returns a stored value or throws; it is never given a
non-nil `observed` in this commit, which is consistent with no test reaching
`proposeExactRollout` (F4).

---

## Missing Test Cases

1. One negative case per `RolloutExactProposalBuilder` guard (17 cases), parameterised over
   a single-field-drifted fixture, each asserting its specific `RolloutAuthorityError`.
2. `observeExactPullRequestReview` against a counting transport: assert the granted read
   authority equals `identityRequests`/`repositoryRequests`/`gitRemoteReads`, and that
   exceeding it fails closed.
3. `observeExactPullRequestReview` with a GitHub identity whose login or id differs from the
   configured account, expecting `invalidReleaseIdentity`.
4. `proposeExactRollout` on an unpaused runtime, on a runtime with `exclusiveOperations > 0`,
   and while checkpointing, expecting `EngineClientError(.busy)`.
5. `rolloutRepositoryIdentity` with two case-insensitively matching configured repositories,
   expecting `invalidRepositoryIdentity`.
6. `rolloutExactJobBinding` with two non-terminal jobs on one logical identity, and with one
   job whose `objectNumber` disagrees, both expecting `jobBindingMismatch`; plus the
   no-existing-job path asserting a fresh binding at `.review`.
7. `EngineService` `.proposeExactRollout`: unpaused expecting `.busy`; and an external fake
   recording that `revalidateRollout` was called on the produced preview.
8. `RolloutExactProposalRequest.validate()` table test over invalid owner, invalid name,
   `number <= 0`, `number > 1_000_000`, `expiresInSeconds` at 59, 60, 900 and 901.
9. `EngineProtocol` response-binding: one test per clause of the guard at 919, each mutating
   one field of the returned preview (owner, name, object number, job-binding number, mode,
   stage, budgets, expiry window, recovery preview present), expecting `.invalidResponse`.
10. `RolloutCLI` `propose-exact` parsing: valid 3-arg and 4-arg forms, no slash, two slashes,
    non-numeric number, non-numeric expiry, out-of-range expiry.
11. `SettingsViewModel.proposeExactRollout()` end to end against a fake that returns a
    preview, asserting `pendingRolloutInput`/`pendingRolloutPreview` are set and
    `rolloutConfirmationSHA256` is cleared; plus the three `proposalRequest()` rejection
    paths.
12. A behavioural counterpart to `proposalPolicyCeilings`: drive the proposal against an
    effect authority that records every effect kind, and assert zero provider sessions, zero
    label writes, zero branch creates, zero PR creates, zero Git sends and zero approved
    commands actually occurred.

## Summary

Coverage assessment: the migration half of this commit (schema 10 to 11) is tested to a high
standard, with the digest pinned, per-statement rollback, trigger survival, integrity,
idempotent reopen and old-binary refusal. The producer half is not tested at all in the
sense that matters: seventeen guards in the new type plus every guard on the path that
reaches it survive deletion with the full 790-test suite green. The four new tests prove
that a produced selector round-trips through the validator (real and valuable), and
otherwise pin constants. Three of the six properties the plan requires proof of are prose,
not tests, and the edited existing tests are clean.

Recommendation: **FIX BEFORE MERGE** — F1, F2 and F4 at minimum. The round-trip test is the
right idea and should stay; what is missing is the negative half of every guard it walks
past.
