# ABOUTME: Architecture review of W9.0 (commit 4dc9cbc), the exact-rollout proposal producer
# ABOUTME: Findings on the pre-lane read-authority seam, with executable probe evidence

# Architecture Review — W9.0 exact-rollout producer (`4dc9cbc`, diff `88f8658..4dc9cbc`)

Scope: `RolloutExactProposalBuilder`, `EngineService` protocol additions and `.proposeExactRollout`
dispatch, `ProductionEngineJobRuntime` (`rolloutRepositoryIdentity`, `rolloutExactJobBinding`,
`proposeExactRollout`), `ProductionEngineExternalServices.observeExactPullRequestReview`,
`RolloutReleaseIdentityAttestor.observedIdentity`, `EngineProtocol`, `RolloutCLI`, AppSupport.
Read-only against the main checkout; all probes ran in an exported copy of `4dc9cbc`
(`git --git-dir=.../jidoka-code-w9/.git archive 4dc9cbc`), built and tested with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift {build,test}`.

## CRITICAL

- **`Sources/JidokaCodeCore/Application/ProductionEngineExternalServices.swift:451`** — the
  proposal's repository read authority is constructed with `jobID: UUID()`, a throwaway value, but
  the only Git remote reads the proposal makes are attributed to the *binding's* job id: the
  builder passes `UUID(uuidString: binding.jobID)` into `git.derivePullRequest`
  (`RolloutExactProposalBuilder.swift:83`), `SystemGitTransport` puts that id into the effect
  (`Git/GitTransport.swift:559-565`), and `BoundedRolloutPreviewReadAuthority.reserveGitRemoteRead`
  requires `effect.jobID == jobID` (`State/RolloutEffectAuthority.swift:204`). The two never match,
  so `observeExactPullRequestReview` throws `effectAdmissionClosed` on the base fetch and
  `propose-exact` cannot succeed against real GitHub. The revalidation path does it correctly
  (`ProductionEngineExternalServices.swift:362` binds `preview.payload.jobBinding` job id), which
  is what makes the asymmetry a defect rather than a design choice.
  → Root cause is ordering, not layering: the read authority is sealed before the binding exists,
  because the binding can only be resolved after the PR metadata fetch (`resolveBinding` at
  `RolloutExactProposalBuilder.swift:67`). Fix by splitting the external call in two — a small
  metadata-only authority for `authenticatedIdentity`/`repository`/`pullRequest`, then resolve the
  binding, then build the repository+git authority with `binding.jobID` — or by letting the
  authority adopt the job id at its first Git remote read. Passing `UUID()` only satisfies the
  initializer's `jobID != nil` precondition syntactically.
  | evidence: probe `ProbeExactProposalGitAuthorityTests` (exported `4dc9cbc` tree, 2 tests, both
  pass): with the proposal's construction (`jobID: UUID()`) the reservation of an effect carrying
  the binding job id throws `RolloutAuthorityError.effectAdmissionClosed`; with the revalidator's
  construction (`jobID: bindingJobID`) the same reservation is admitted.

- **`Sources/JidokaCodeCore/State/RolloutAuthority.swift:1537`** —
  `RolloutExactProposalPolicy.gitRemoteReads = 1` is below the number of Git remote reads a PR
  preview actually performs. `SystemGitTransport.preparePullRequestPreviewRepository` issues two:
  `.fetchPreviewBase` (`Git/GitTransport.swift:372`) and `.fetchPullRequest`
  (`Git/GitTransport.swift:399`), both inside the single `derivePullRequest` call the builder
  makes. `reservedGitRemoteReads` is monotonic (`settleGitRemoteRead` does not release it), so the
  head fetch is refused. The same constant is written into the preview
  (`pullRequestReviewBudgets.gitRemoteReads`), and revalidation derives its ceiling from it
  (`ProductionEngineExternalServices.swift:367`), so the produced preview would also fail its own
  revalidation and its later activation. The runbook repeats the wrong number
  (`docs/operations/progressive-production-rollout.md:317` "one Git remote read").
  → Set `gitRemoteReads = 2` in the policy and correct the runbook and the W9.0 plan wording.
  | evidence: probe `ProbeExactProposalGitCeilingTests` (exported `4dc9cbc` tree, passes): after
  one settled `.fetchPreviewBase` reservation under `RolloutExactProposalPolicy.gitRemoteReads`,
  the `.fetchPullRequest` reservation throws `effectAdmissionClosed`. Corroborated by the
  pre-existing exact-preview fixture, which sets `gitRemoteReads: 2` for `.prReview`
  (`Tests/JidokaCodeCoreTests/RolloutRemotePreviewRevalidatorTests.swift:1094`).

## MAJOR

- **`Sources/JidokaCodeCore/Application/EngineService.swift:671-700`** — the whole production
  wiring of the new command is untested. `grep -rn "observeExactPullRequestReview|proposeExactRollout|rolloutExactJobBinding|rolloutRepositoryIdentity" Tests`
  returns only two exhaustive-`switch` mentions (`RolloutCLITests.swift:148`,
  `ViewModelFlowTests.swift:694`); no test constructs `ProductionEngineExternalServices`,
  `ProductionEngineJobRuntime.proposeExactRollout`, or drives `EngineService` through
  `.proposeExactRollout`. The four new tests exercise `RolloutExactProposalBuilder` against
  fixture doubles that never touch `BoundedRolloutPreviewReadAuthority`, which is exactly why both
  Criticals above are invisible to `make check`.
  → Add an engine-level test with a fake `EngineExternalServicing`/`EngineJobRuntime` pair for the
  dispatch order, and an external-services test that runs the builder through a real
  `BoundedRolloutPreviewReadAuthority` and a stubbed transport, so the effect-authority contract
  (job id, request and Git-read ceilings) is enforced at the seam that owns it.
  | evidence: the two probes above are red against the shipped wiring and green against the
  revalidator's wiring, yet the committed suite is green.

## MINOR

- **`Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift:400-421`** —
  `rolloutRepositoryIdentity` copies `enabled` / `reviewEnabled` out of configuration without
  checking them. A repository with `review_enabled = 0` is refused only much later, inside
  `RolloutPreviewBuilder.make`, after the identity request, up to 40 repository requests and the
  Git fetches have been spent. The refusal is fail-closed, so this is cost and diagnosis quality,
  not authority.
  → Guard `repository.enabled && repository.reviewEnabled` in `rolloutRepositoryIdentity`, before
  any I/O.
  | evidence: `closedRepositoryProposalRefused`
  (`RolloutRemotePreviewRevalidatorTests.swift`) builds the observation first and only then asserts
  the refusal; a test asserting zero reservations on the repository read authority for a
  review-disabled repository would fail today.

- **`Sources/JidokaCodeCore/State/RolloutAuthority.swift:1536`** — the producer grants itself 40
  repository requests, but the consumer of the budget it writes gets 39: `rolloutGitHubBudget`
  reserves one request for the identity read (`ProductionEngineExternalServices.swift:554`). A
  proposal that legitimately consumes the 40th request is produced and then immediately fails the
  revalidation `EngineService` runs on it, with no operator-legible reason.
  → Build the proposal authority from `rolloutGitHubBudget(pullRequestReviewBudgets)` too, so
  producer and revalidator have identical ceilings by construction.
  | evidence: `proposalPolicyCeilings` asserts `mapped.repositoryRequests == 39` while
  `observeExactPullRequestReview` passes `RolloutExactProposalPolicy.repositoryRequests` (40) to
  `BoundedRolloutPreviewReadAuthority`.

- **`Sources/JidokaCodeCore/Application/EngineService.swift:672`** — the only pre-fetch guard is
  `configuration.appConfiguration().paused`; the runtime's real readiness check
  (`paused, exclusiveOperations == 0, !checkpointing`, `ProductionEngineJobRuntime.swift:471`) runs
  only after the external fetch, which the client allows up to 700 seconds. A checkpoint or handoff
  started while the fetch is in flight is discovered only after all of that I/O has been spent.
  → Ask the runtime for readiness before calling `external.observeExactPullRequestReview`, and keep
  the existing post-check as the write-time guard.
  | evidence: dispatch order at `EngineService.swift:672-694`; `ApplicationEngineClient.swift:89`
  puts `.proposeExactRollout` in the 700-second bucket.

## Answers to the questions in the brief

- **Is the three-way split the right seam, and does `resolveBinding` smuggle a layering
  violation?** The split is right and the closure is not a layering violation: `EngineService`
  composes, and the external service receives a plain
  `(String, Int, String) async throws -> RolloutJobBinding` function with no knowledge of the
  runtime type — dependency inversion at the call site. It is also unavoidable: the artifact digest
  needs the job id, and the job id needs the head SHA, which needs the metadata fetch. What the
  closure *does* smuggle is an ordering constraint the effect authority cannot satisfy — the
  authority must be sealed with a job id before the binding that determines that job id exists.
  That is Critical 1, and it is a seam problem, not a closure problem: the fix is a two-phase
  external API, which keeps the same three-way split.
- **Is the mirroring of `validatePullRequest` by `observePullRequest` a duplication defect?** No.
  The two must agree byte-for-byte, and `exactProposalRoundTrips` pins that agreement by feeding
  the produced selector straight into the real revalidator, so a divergence in the artifact
  assembly is caught by an existing test rather than by production. The duplication is bounded
  (about forty lines) and its failure mode is `previewDrift`, i.e. fail-closed. Extracting a shared
  derivation would be a marginal improvement; leaving it is defensible.
- **Do the `.unavailable` protocol defaults hide a conformance a real type should provide?** No.
  `InactiveEngineJobRuntime` (`EngineService.swift:223`) is a real conformer that must not
  implement any rollout method, so the defaults are load-bearing and their behaviour is
  fail-closed. The cost is that a future conformer gets a runtime `.unavailable` instead of a
  compile error; that cost is pre-existing and unchanged by this commit.

## Also verified, no finding

- The release identity the producer assembles maps field-for-field onto what
  `RolloutPackagedReleaseIdentity.matches` compares, including `applicationSHA256` coming from the
  observation rather than the packaged manifest, so a self-produced preview passes `requireCurrent`.
- `rolloutExactJobBinding` produces bindings that satisfy both revalidator branches: the existing-job
  branch (identity, object number, contract, priority, current step) and the new-job branch
  (`validNewExactJob`: `.prReview` kind, `.prReview` priority, `.review` first step, current step
  equal to first step).
- `EngineCommandKind`/`EngineCommand` additions reach every classification site; the remaining
  `switch`es over command kinds are exhaustive, so no allowlist was silently missed.
- `EngineXPCResponse` binds the returned preview to the requested coordinates, mode, stage and
  expiry window, so a client cannot be handed a preview for another object.

## Summary

Overall structure assessment: the layering is sound and the producer/validator symmetry is the right
shape for a path that must reproduce bytes exactly. The defects are all at one seam — the pre-lane
read authority — where the new code satisfies the authority's preconditions syntactically (a
placeholder job id, a ceiling copied from prose rather than from the two fetches the code performs)
instead of semantically. Both make `propose-exact` non-functional against real GitHub, and both
survived because no test drives the production wiring through a real
`BoundedRolloutPreviewReadAuthority`.

Recommendation: BLOCK.
