# ABOUTME: Security review of W9.0 commit 4dc9cbc, the exact rollout preview producer
# ABOUTME: Authority boundaries, fail-closed behaviour, TOCTOU, secret handling, input validation

# Security Review — W9.0 `4dc9cbc` (exact rollout proposal producer)

Base: `git diff 88f8658..4dc9cbc`. Read-only review; the reviewed tree is
`/Users/maroffo/jidoka-code-w9` (the assigned worktree copy is based on a different
repository and does not share its object store, so no build or test probe was run against the
reviewed SHA — every finding below is derived from source and each names the executable
observation that settles it).

## Verdict on the three claims

**Claim 1 (a proposal is a READ, not an authority): holds, with one caveat.**
Traced every durable-state reachable path of `.proposeExactRollout`:

- `ProductionEngineJobRuntime.proposeExactRollout` → `rolloutAuthority.preview(input:)`
  (`RolloutAuthorityStore.swift:62-86`) opens a transaction that only *reads*
  (`localEvidence`, `requireRepository`) and compares; there is no INSERT/UPDATE, and no
  `rollout_authorizations` / `rollout_authorization_scopes` row is created. The durable
  authorization is still minted only by `activateRollout`.
- `rolloutExactJobBinding` *reads* `jobs.jobs(nonTerminalOnly:)` and synthesises a `UUID()` for
  the new-job case; it enqueues nothing.
- `BoundedRolloutPreviewReadAuthority` (`RolloutEffectAuthority.swift:91`) is an in-memory
  actor. It writes no ledger row, so a proposal consumes no lane budget — correct, since no
  lane exists yet.
- `pullRequestReviewBudgets` keeps `approvedCommands/labelWrites/branchCreates/pullRequestCreates/gitSends`
  at 0 and `githubSends (2) == markerParts (2)`, so `RolloutPreviewBuilder.effectEnvelope`
  (`RolloutAuthority.swift:722-767`) derives exactly `{githubRead, gitRemoteRead, providerSession,
  markerBatch}`, a subset of the `prReview` allowed set. No mutation kind is reachable.
- No provider session is opened on the proposal path; the two brokers carry a `.discovery`
  read context and a read-only authority (`reserveGitHubRead` rejects `operation.kind.isWrite`).

Caveat, filed as MINOR-1: the *client's* acceptance of the returned preview does not pin the
one field it could recompute (the policy budgets).

**Claim 1, "the produced preview can only activate for exactly what the operator named": holds.**
I could not steer it. `rolloutRepositoryIdentity` requires exactly one configured repository
matching owner/name case-insensitively; the builder re-checks the fetched repository's
`nodeID`/owner/name/defaultBranch against it; the selector's `nodeID`, `number`, `revisionKey`,
`headSHA`, `baseSHA` all come from the PR fetched at those coordinates, and
`RolloutRemotePreviewRevalidator.validatePullRequest` (`RolloutRemotePreviewRevalidator.swift:410-483`)
re-fetches the same coordinates and requires `pullRequest.nodeID == object.nodeID` and
`head.sha == object.revisionKey` before recomputing both digests. Everything an attacker
controls on GitHub (title, body, head, base, commit list) feeds `canonicalInputSHA256` /
`narrativeSHA256`, but only as the *content* that must match at activation: changing any of it
after the proposal moves the digest and yields `previewDrift`. The builder also emits
`labelStateSHA256 == nil` / `planSHA256 == nil`, which the revalidator demands
(`RolloutRemotePreviewRevalidator.swift:477-478`). A fork-origin head is not a hole: the git
inspector fetches `refs/pull/<n>/head` from the *configured* remote, so the derived commits are
that PR's, and `restCommits == fetched.commitSHAs` cross-checks REST against Git.

**Claim 2 (fixed pre-lane read authority): holds as written, but the constants are wrong —
see MAJOR-2.** `RolloutExactProposalPolicy` is source-controlled and no operator field reaches
`maximumRequests` / `maximumBytes` / `maximumGitRemoteReads`. `RolloutExactProposalRequest.validate()`
bounds `number` to `1...1_000_000` and `expiresInSeconds` to `60...900` (the latter is exactly
`RolloutPreviewBuilder.exactPreviewLifetimeMilliseconds`), and owner/name go through
`GitHubInputValidation`. No injection surface: git is invoked with argument arrays and
repository-derived remote URLs, and the only operator-derived strings are validated before use.

**Claim 3 (the persisted authorization stays honest about the minting release): mostly holds —
see MINOR-2** for the migration's silent repin of a non-empty table.

**Token handling: clean.** `observeExactPullRequestReview` reproduces the `revalidateRollout`
pattern exactly: `defer { token.resetBytes(in: 0..<token.count) }` covers both exits, and
`await provider.clear()` (which zeroes then nils, `ProductionEngineExternalServices.swift:45-49`)
runs on the success path and in the `catch` before rethrow. The observed GitHub identity *is*
bound to the configured account: `ProductionEngineExternalServices.swift:474-478` compares
`observation.githubAccount` case-insensitively to `app.githubAccount` and
`observation.githubAuthorID` to `app.githubAuthorID`, and the same pair is written into the
preview's release identity, where `revalidateRollout` re-checks it against `authenticatedIdentity()`.

**Paused precondition: adequate.** `EngineService` gates on `configuration.appConfiguration().paused`
before the fetch, and `ProductionEngineJobRuntime.proposeExactRollout` re-checks
`paused, exclusiveOperations == 0, !checkpointing` inside the actor before building the preview.
The window between them contains only reads. The `resolveBinding` closure captures `runtime` and
the already-resolved `repository` by value, so the binding cannot be steered to a different
repository than the one the coordinates resolved to.

---

## MAJOR

### MAJOR-1 — the proposal's Git-remote-read authority is bound to a synthetic UUID that can never match the effect it is meant to authorize

**Location:** `Sources/JidokaCodeCore/Application/ProductionEngineExternalServices.swift:451`

```swift
        repositoryNodeID: repository.nodeID,
        jobID: UUID(),                                   // <- synthetic, unrelated
        maximumGitRemoteReads: RolloutExactProposalPolicy.gitRemoteReads
```

**Claim.** `BoundedRolloutPreviewReadAuthority.reserveGitRemoteRead` admits a Git remote read
only when `effect.jobID == jobID` (`Sources/JidokaCodeCore/State/RolloutEffectAuthority.swift:204`).
The effect's `jobID` is taken from the task-local execution context
(`Sources/JidokaCodeCore/Git/GitTransport.swift:553-566`, `jobID: jobID` where
`let jobID = context.jobID`), and that context is set by
`ProductionRolloutPreviewGitInspector.derivePullRequest` to the `jobID` argument it was passed
(`Sources/JidokaCodeCore/Application/RolloutRemotePreviewRevalidator.swift:117-119`,
`RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))`). `RolloutExactProposalBuilder`
passes the *job binding's* id (`Sources/JidokaCodeCore/Application/RolloutExactProposalBuilder.swift:83-89`,
`jobID` decoded from `binding.jobID` at line 75). So the authority is constructed with a fresh
random UUID while the effect carries the binding's UUID: the equality can never hold, and every
proposal's `git fetch` is refused with `RolloutAuthorityError.effectAdmissionClosed`.

Compare the correct wiring twenty lines up: `revalidateRollout` builds the same authority with
`jobID: preview.payload.jobBinding.flatMap { UUID(uuidString: $0.jobID) }`
(`ProductionEngineExternalServices.swift:361`), i.e. exactly the value the revalidator later
passes to `derivePullRequest`.

**Threat model.** No attacker crosses a boundary: the failure is *closed*. What is broken is the
security property the parameter exists to express — "this Git remote read belongs to the job
this preview binds". Binding it to a value with no relation to the preview means the check
asserts nothing about the object being read; it only happens to deny everything. The consequence
today is that `proposeExactRollout` cannot complete against a real repository, so W9.0 ships a
producer that cannot produce. That is why this is a merge blocker rather than a note, and it is
the reason MAJOR-2 below is invisible: the first refusal masks the second.

**Fix.** Resolve the job binding before constructing the repository authority (it needs only the
PR head, available after the metadata fetch, so the fetch has to be split), or thread the
binding's `jobID` into the authority once known — the shape `revalidateRollout` already uses.
Do not weaken the `effect.jobID == jobID` guard.

**Evidence.** A test exercising `ProductionEngineExternalServices.observeExactPullRequestReview`
with a real `BoundedRolloutPreviewReadAuthority` and a git inspector that performs one remote
read: it fails today with `effectAdmissionClosed`. That no such test exists is itself checkable:
`grep -rn observeExactPullRequestReview Tests/ Sources/` returns only the protocol declaration in
`EngineService.swift` and the implementation in `ProductionEngineExternalServices.swift` — the
four new proposal tests
(`Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift:65,119,173,229`) all drive
`RolloutExactProposalBuilder` with fakes and never construct the production authority.

### MAJOR-2 — `RolloutExactProposalPolicy.gitRemoteReads = 1` is one short of the two remote reads a PR preview performs, so every produced preview is also unrevalidatable

**Location:** `Sources/JidokaCodeCore/State/RolloutAuthority.swift:1537`

**Claim.** `SystemGitTransport.preparePullRequestPreviewRepository` issues **two** authorized
remote reads: the base fetch (`Sources/JidokaCodeCore/Git/GitTransport.swift:371-375`,
`operation: .fetchPreviewBase`) and the head fetch (`GitTransport.swift:397-401`,
`operation: .fetchPullRequest`). Each takes one reservation
(`RolloutEffectAuthority.swift:198-212`, `reservedGitRemoteReads < maximumGitRemoteReads`).
With the ceiling at 1, the head fetch is refused.

This is not confined to the proposal's own authority. The constant is *also* written into the
lane budget the preview carries (`RolloutAuthority.swift:1552`, `gitRemoteReads: gitRemoteReads`
inside `pullRequestReviewBudgets`), and `revalidateRollout` derives its own ceiling from that
budget: `previewGitReads = budget.gitRemoteReads` (`ProductionEngineExternalServices.swift:367`).
So even after MAJOR-1 is fixed, the follow-up `external.revalidateRollout(preview)` at the end of
`EngineService`'s `.proposeExactRollout` case — and the identical revalidation activation runs —
would refuse the head fetch and surface `previewDrift`. Every preview minted by this policy is
permanently unactivatable.

**Threat model.** Again fail-closed, no attacker. The security-relevant part is that the budget
written into a *durable authorization* is provably insufficient for the lane's own PR review job,
so the lane, once activated, dies on its first PR fetch — a correctness failure of the authority
envelope, not an escape from it.

**Fix.** `gitRemoteReads = 2`, matching the two reads `preparePullRequestPreviewRepository`
actually makes, and confirm separately whether the activated lane needs more than the preview
path does.

**Evidence.** The pre-existing revalidator test fixture already encodes the right number:
`Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift:1094`,
`gitRemoteReads: scope.stage == .prReview || scope.stage == .generatedPRReview ? 2 : 0`. The new
policy test (`RolloutRemotePreviewRevalidatorTests.swift:485`,
`#expect(RolloutExactProposalPolicy.gitRemoteReads == 1)`) is a tautology that restates the
constant instead of deriving it from the transport, which is why it did not catch this. A test
driving a real `BoundedRolloutPreviewReadAuthority(maximumGitRemoteReads: 1)` through
`preparePullRequestPreviewRepository` fails on the second reservation.

---

## MINOR

### MINOR-1 — the client accepts a proposal without pinning the one preview field it can recompute

**Location:** `Sources/JidokaCodeCore/Application/EngineProtocol.swift:916-935`

**Claim.** The comment is right that the client cannot recompute a proposal it did not build —
but `budgets` is the exception: `RolloutExactProposalPolicy.pullRequestReviewBudgets` is a
source-controlled constant in the same module the client links, and it is the field that becomes
the lane's spending authority. Today the client checks scope mode/stage, coordinates, object
number, binding number and the expiry delta, and leaves budgets to `parseCanonical`. That
validation is loose: `RolloutAuthority.swift:1020-1058` admits up to 10 000 read requests, 1 GiB
of read bytes, 1 000 Git remote reads and 64 marker parts, and the `prReview` effect envelope
constrains only the *kinds* the policy zeroes, not the magnitudes. So a preview claiming 250x the
policy's read authority and 32x its marker parts passes client validation.

**Threat model.** The engine helper crosses the engine -> client boundary. This is the same
boundary the sibling case defends completely (`EngineProtocol.swift:908-914`, `.previewRollout`
asserts `result.rolloutPreview == expected` against the client's own recomputation), so the
codebase already treats it as real. Impact is bounded because the UI renders the effect envelope
allowances and the canonical JSON before the operator types the digest
(`Sources/JidokaCodeAppSupport/JidokaViews.swift:666-673`), so an inflated budget is
operator-visible — hence MINOR, not MAJOR.

**Fix.** Add `preview.payload.budgets == RolloutExactProposalPolicy.pullRequestReviewBudgets`
(and, for the same price, `preview.payload.commands.isEmpty` and
`preview.payload.missingLabels.isEmpty`) to the `.proposeExactRollout` guard.

**Evidence.** A response-validation test handing `EngineXPCResponse.validate` a
`.proposeExactRollout` result whose preview matches the requested coordinates but carries
`githubReadRequests: 10_000, markerParts: 64`: accepted today, rejected with `.invalidResponse`
after the fix.

### MINOR-2 — migration 11 silently rewrites the release pins of any existing scope row instead of failing closed

**Location:** `Sources/JidokaCodeCore/State/DatabaseSchema.swift:3645-3672`

**Claim.** The migration drops and re-adds `schema_version` and `engine_protocol_version` with
`NOT NULL DEFAULT 11 / 13`. On a non-empty `rollout_authorization_scopes` the re-added columns
take those defaults for every existing row, so an authorization minted by build 6 at engine
protocol 12 emerges recorded as having been minted at 13. The commit's own justification —
"the table is empty in production" — is a comment, not a guard, and the plan's own W9.1 step
activates a lane, so a row can exist before build 7 is installed. Absence of the migration's
precondition is not distinguishable from its satisfaction.

**Threat model.** Release -> authority boundary: a lane minted by one release presenting itself
as minted by another. Impact is contained by defence in depth, which is why this is MINOR: the
same row still pins `application_sha256`, `helper_sha256`, `source_commit` and `bundle_build`
(`DatabaseSchema.swift:1824-1847`), which the migration does not touch, and the row's
`preview_json` still carries `engineProtocolVersion: 12`, which `RolloutPreviewBuilder.validate`
now rejects (`RolloutAuthority.swift:829-830`). So a stale authorization still fails closed on
re-parse — but on a *different* check than the one designed to catch it, and the provenance
evidence is destroyed rather than preserved.

**Fix.** Prepend a guard statement that aborts when the table is non-empty, e.g.
`SELECT RAISE(ABORT, 'rollout scopes present at protocol repin') WHERE EXISTS (SELECT 1 FROM rollout_authorization_scopes)`,
so the precondition the comment asserts is enforced by the database.

**Evidence.** A `SQLiteStoreTests` case that opens at schema 10, inserts one
`rollout_authorization_scopes` row, then migrates to 11: today it succeeds and
`SELECT engine_protocol_version` returns 13; after the fix the migration aborts and rolls back.
The new tests at `Tests/JidokaCodeCoreTests/SQLiteStoreTests.swift:69-117` only assert
`COUNT(*) == 0` on an already-empty table, so they cannot see this.

---

## Checked and clean (no finding)

- `RolloutCLI.propose-exact` parsing (`Sources/JidokaCodeApp/RolloutCLI.swift:58-72`):
  `omittingEmptySubsequences: false` with `count == 2` rejects `a`, `a/b/c` and `a/`; a
  non-numeric or negative PR number is rejected by `Int(...)` or by `validate()`; the optional
  fourth argument is range-checked. Same shape in `SettingsViewModel.proposalRequest()`.
- Repository enablement: `RolloutPreviewBuilder.validate(scope:)` requires `repository.enabled`
  and `workflowEnabled(stage:)`, so a disabled or review-disabled repository cannot reach a
  preview even though `rolloutRepositoryIdentity` returns it (covered by the new test at
  `RolloutRemotePreviewRevalidatorTests.swift:173`).
- `gitSends` inflation is inert: no effect kind maps to it, and the only consumer requires
  `branchCreates == 1 && gitSends == 1` (`RolloutAuthority.swift:1329`,
  `RolloutEffectAuthorityStoreTransactions.swift:940`), while `branchCreate` is not in the
  `prReview` allowed set.
- Positional-column risk from the migration's column reorder: every read and write of
  `rollout_authorization_scopes` names its columns (`RolloutAuthorityStore.swift:1666`,
  `:2136`, `:2467`, `:2590`); no `SELECT *`.
- Job-binding drift between builder and revalidator: for an existing job the runtime copies
  `priority`, `contractVersion` and `currentStep` from the record the revalidator re-reads by id;
  for a new job it emits `.prReview / .prReview / .review`, exactly what `validNewExactJob`
  demands. The engine is paused throughout, so no step can advance in between.

## Summary

0 critical, 2 major, 2 minor findings
Recommendation: **BLOCK** — MAJOR-1 and MAJOR-2 each make `proposeExactRollout` fail on every
real invocation, so the commit's central claim ("the engine performs one bounded read-only fetch"
returning a revalidated preview) is not exercisable. Both fail closed, so nothing unsafe ships;
what ships is a non-functional producer whose authority binding asserts nothing. Fix both, and
add the missing production-wiring test that would have caught them.
