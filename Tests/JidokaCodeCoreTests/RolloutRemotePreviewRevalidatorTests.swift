import Foundation
import Testing

@testable import JidokaCodeCore

private enum ExactPullRequestDrift: CaseIterable {
  case identityID
  case identityLogin
  case repositoryNode
  case repositoryOwner
  case repositoryName
  case defaultBranch
  case pullRequestState
  case pullRequestDraft
  case pullRequestTitle
  case pullRequestBody
  case pullRequestHead
  case pullRequestBaseRef
  case pullRequestBaseSHA
  case restCommitOrder
  case fetchedBase
  case fetchedHead
  case fetchedCommits
  case fetchedNarrative
}

private enum TriageLabelDrift {
  case issueLabels
  case repositoryLabels
}

@Suite("Rollout remote preview revalidation")
struct RolloutRemotePreviewRevalidatorTests {
  @Test("exact PR preview rejects every independently drifted remote binding")
  func exactPullRequestDriftMatrix() async throws {
    for drift in ExactPullRequestDrift.allCases {
      let fixture = try await RolloutRemotePreviewFixture()
      defer { fixture.remove() }
      let preview = try fixture.exactPreview()
      try await fixture.revalidator.revalidate(preview)
      await fixture.apply(drift)
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await fixture.revalidator.revalidate(preview)
      }
      await fixture.database.close()
    }
  }

  @Test("finite preview binds the complete deterministic candidate set")
  func finiteCandidateDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    await fixture.api.appendPullRequest(fixture.pullRequest(number: 8, suffix: "8"))
    let preview = try await fixture.finitePreview()
    try await fixture.revalidator.revalidate(preview)

    await fixture.api.appendPullRequest(fixture.pullRequest(number: 9, suffix: "9"))
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
  }

  @Test("exact triage preview binds issue, labels, and default-branch base")
  func exactTriageDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try await fixture.exactTriagePreview()
    try await fixture.revalidator.revalidate(preview)

    await fixture.api.replaceIssue(body: "changed after preview")
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
  }

  @Test("exact triage preview rejects issue-label and repository-label drift")
  func exactTriageLabelDrift() async throws {
    for drift in [TriageLabelDrift.issueLabels, .repositoryLabels] {
      let fixture = try await RolloutRemotePreviewFixture()
      defer { fixture.remove() }
      let preview = try await fixture.exactTriagePreview()
      try await fixture.revalidator.revalidate(preview)
      switch drift {
      case .issueLabels:
        await fixture.api.setWorkflowLabels(["agent:ready"])
      case .repositoryLabels:
        await fixture.api.removeLastRepositoryLabel()
      }
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await fixture.revalidator.revalidate(preview)
      }
      await fixture.database.close()
    }
  }

  @Test("exact execution preview binds the approved waiting-human checkpoint")
  func exactWaitingExecutionDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try await fixture.exactWaitingExecutionPreview()
    try await fixture.revalidator.revalidate(preview)

    await fixture.api.setWorkflowLabels(["agent:plan-review"])
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.api.setWorkflowLabels(["agent:plan-review", "plan:approved"])
    _ = try await fixture.database.execute(
      "UPDATE jobs SET state = 'queued' WHERE id = ?",
      bindings: [.text(fixture.implementationJob.id.uuidString.lowercased())]
    )
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
  }

  // Audit of the 27 `previewDrift` guards in RolloutRemotePreviewRevalidator.
  //
  // Driven by an independent mutation: the canonical round-trip, authenticated
  // identity, repository identity, transport failure, repository-label inventory
  // (count, duplicate node, duplicate name, changed definition, expected set),
  // existing-job binding, pull-request identity, commit derivation, exact PR object
  // digests, issue identity and default-branch reference, triage object digests,
  // workflow-label expectations, and the finite candidate set with its observed
  // object-number upper bound.
  //
  // Not independently drivable from a valid preview, and therefore second-line
  // defensive arms. Each category is asserted at the edge that actually enforces it,
  // rather than argued in prose:
  //   - the review-stage missing-label guard, refused by the preview builder
  //     (`reviewStageRejectsMissingLabels`);
  //   - the malformed-binding arms, refused by the builder before a preview exists
  //     (`builderRefusesMissingJobBinding`);
  //   - the non-positive object number, refused by the object selector itself
  //     (`builderRefusesNonPositiveObjectNumber`);
  //   - the finite-window stage arms, refused by the builder for any stage other than
  //     the two it accepts (`builderRefusesFiniteWindowAtExactOnlyStages`);
  //   - unsupported implementation-stage steps, refused by
  //     `RolloutAuthority.validCurrentStep` before the workflow-label switch;
  //     `builderRefusesAStepTheLabelSwitchDoesNotCover` checks execution at `.replan`.
  // An earlier version of this comment called the last two unreachable "by
  // construction rather than by validation". That was wrong: they are refused by a
  // validating edge like the others, so they are asserted at it like the others.
  // Reaching any of them at the revalidator would need a hand-forged preview, which
  // the canonical round-trip guard rejects first.

  @Test("a preview whose canonical bytes no longer round-trip is rejected")
  func canonicalRoundTripDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try fixture.exactPreview()
    try await fixture.revalidator.revalidate(preview)

    let text = try #require(String(data: preview.canonicalJSON, encoding: .utf8))
    let tampered = RolloutPreview(
      payload: preview.payload,
      canonicalJSON: Data(
        text.replacingOccurrences(of: "\"bundleBuild\":7", with: "\"bundleBuild\":8").utf8
      ),
      sha256: preview.sha256
    )
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(tampered)
    }
    await fixture.database.close()
  }

  @Test("a transport failure during revalidation is drift, never a pass")
  func transportFailureIsDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try fixture.exactPreview()
    try await fixture.revalidator.revalidate(preview)

    await fixture.api.failNextRepositoryRead()
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
  }

  @Test("repository-label inventory drift is rejected in every shape")
  func repositoryLabelInventoryDrift() async throws {
    for drift in RepositoryLabelInventoryDrift.allCases {
      let fixture = try await RolloutRemotePreviewFixture()
      defer { fixture.remove() }
      let preview = try await fixture.exactTriagePreview()
      try await fixture.revalidator.revalidate(preview)
      switch drift {
      case .duplicateNodeID:
        await fixture.api.duplicateFirstRepositoryLabelNodeID()
      case .duplicateName:
        await fixture.api.duplicateFirstRepositoryLabelName()
      }
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await fixture.revalidator.revalidate(preview)
      }
      await fixture.database.close()
    }
  }

  @Test("a review-stage preview cannot be built with missing labels at all")
  func reviewStageRejectsMissingLabels() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    // The builder is the enforcing edge here: a review stage carrying label creates
    // never becomes a preview, so the revalidator's own missing-label guard is a
    // second line that no valid preview can reach.
    #expect(throws: RolloutAuthorityError.invalidEffectEnvelope) {
      _ = try fixture.exactPreview(missingLabels: [
        RolloutLabelDefinition(name: "agent:ready", color: "0e8a16", description: "ready")
      ])
    }
    await fixture.database.close()
  }

  @Test("the builder refuses a missing job binding, so no preview carries one")
  func builderRefusesMissingJobBinding() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    // An exact-object scope with no job binding is the malformed shape the
    // revalidator's binding arms exist to catch. The builder rejects it first, so
    // the arm is unreachable from a real preview rather than merely untested.
    #expect(throws: RolloutAuthorityError.invalidJobBinding) {
      _ = try fixture.exactPreview(jobBinding: .some(nil))
    }
    await fixture.database.close()
  }

  @Test("the builder refuses a non-positive object number, so discovery never sees one")
  func builderRefusesNonPositiveObjectNumber() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    #expect(throws: RolloutAuthorityError.invalidObjectSelector) {
      _ = try fixture.exactPreview(objectNumber: 0)
    }
    await fixture.database.close()
  }

  @Test("the builder refuses a step the workflow-label switch does not cover")
  func builderRefusesAStepTheLabelSwitchDoesNotCover() async throws {
    // Implementation execution reaches issue/label validation, unlike PR review.
    // Its `.publishPlan` preview is valid; `.replan` belongs to implementation
    // planning and is refused by the builder before the label switch's default arm.
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try await fixture.exactWaitingExecutionPreview()
    try await fixture.revalidator.revalidate(preview)
    await #expect(throws: RolloutAuthorityError.invalidObjectSelector) {
      _ = try await fixture.exactWaitingExecutionPreview(currentStep: .replan)
    }
    await fixture.database.close()
  }

  @Test("the builder refuses a finite window at the exact-only stages")
  func builderRefusesFiniteWindowAtExactOnlyStages() async throws {
    // `validateFinite`'s `.implementationExecute, .generatedPRReview` arm is one the
    // revalidator can never see, because no preview at those stages can be built in
    // finite-window mode at all.
    for stage in [RolloutWorkflowStage.implementationExecute, .generatedPRReview] {
      let fixture = try await RolloutRemotePreviewFixture()
      defer { fixture.remove() }
      await #expect(throws: RolloutAuthorityError.invalidFiniteWindow, "\(stage)") {
        _ = try await fixture.finitePreview(stage: stage)
      }
      await fixture.database.close()
    }
  }

  @Test("issue identity and default-branch reference drift are rejected")
  func issueIdentityDrift() async throws {
    for drift in IssueIdentityDrift.allCases {
      let fixture = try await RolloutRemotePreviewFixture()
      defer { fixture.remove() }
      let preview = try await fixture.exactTriagePreview()
      try await fixture.revalidator.revalidate(preview)
      switch drift {
      case .closed:
        await fixture.api.replaceIssue(state: "closed")
      case .becamePullRequest:
        await fixture.api.replaceIssue(asPullRequest: true)
      case .missingBranchReference:
        await fixture.api.removeBranchReference()
      }
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await fixture.revalidator.revalidate(preview)
      }
      await fixture.database.close()
    }
  }

  @Test("a finite window binds its observed object-number upper bound")
  func finiteObservedUpperBoundDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    await fixture.api.appendPullRequest(fixture.pullRequest(number: 8, suffix: "8"))
    let preview = try await fixture.finitePreview()
    try await fixture.revalidator.revalidate(preview)

    // A draft PR is not a candidate, so the candidate set is unchanged; only the
    // observed upper bound moves. The window must still refuse to run.
    await fixture.api.appendPullRequest(
      fixture.pullRequest(number: 12, suffix: "12", draft: true))
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
  }

  // The producer exists because two selector digests cannot be built outside the engine. These
  // tests hold it to the only standard that matters: what it produces is exactly what the
  // validator activation runs later re-derives and accepts.

  @Test("an exact proposal produces the selector its own revalidation accepts")
  func exactProposalRoundTrips() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let builder = RolloutExactProposalBuilder(
      identity: fixture.api,
      api: fixture.api,
      makeGit: { _ in fixture.git }
    )
    let binding = RolloutJobBinding(
      jobID: fixture.job.id,
      jobKind: .prReview,
      objectNumber: 10,
      contractVersion: fixture.job.contractVersionUsed,
      priority: .prReview,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    )
    let resolverCalls = RolloutProposalCallCounter()
    let observation = try await builder.observePullRequest(
      repository: fixture.rolloutRepository,
      number: 10,
      resolveBinding: { nodeID, number, revisionKey in
        await resolverCalls.record()
        #expect(nodeID == "PR_preview")
        #expect(number == 10)
        #expect(revisionKey == fixture.headSHA)
        return binding
      }
    )
    #expect(await resolverCalls.count == 1)
    #expect(observation.githubAccount == "owner")
    #expect(observation.githubAuthorID == 42)
    #expect(observation.jobBinding == binding)
    // Byte-for-byte the hand-built selector the revalidator tests above already pin.
    #expect(observation.object == (try fixture.exactPreview()).payload.scope.object)

    let proposed = try RolloutPreviewBuilder.make(
      fixture.previewInput(
        scope: RolloutScope(
          mode: .exactObject,
          stage: .prReview,
          repository: fixture.rolloutRepository,
          object: observation.object,
          finiteWindow: nil
        ),
        jobs: 1,
        jobBinding: observation.jobBinding
      )
    )
    try await fixture.revalidator.revalidate(proposed)
    await fixture.database.close()
  }

  @Test(
    "every producer guard refuses its own drift rather than minting a selector",
    arguments: RolloutProposalDrift.allCases
  )
  func proposalGuardsRefuseDrift(_ drift: RolloutProposalDrift) async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let repository = fixture.rolloutRepository
    var binding = RolloutJobBinding(
      jobID: fixture.job.id,
      jobKind: .prReview,
      objectNumber: 10,
      contractVersion: fixture.job.contractVersionUsed,
      priority: .prReview,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    )
    switch drift {
    case .accountLogin:
      await fixture.api.setIdentity(GitHubUser(id: 42, nodeID: "U_preview", login: "-not-valid-"))
    case .accountID:
      await fixture.api.setIdentity(GitHubUser(id: 0, nodeID: "U_preview", login: "owner"))
    case .repositoryNodeID:
      await fixture.api.replaceRepository(nodeID: "R_other")
    case .repositoryOwner:
      await fixture.api.replaceRepository(ownerLogin: "someone-else")
    case .repositoryName:
      await fixture.api.replaceRepository(name: "other-repo")
    case .defaultBranch:
      await fixture.api.replaceRepository(defaultBranch: "trunk")
    case .pullRequestClosed:
      await fixture.api.replacePullRequest(state: "closed")
    case .pullRequestDraft:
      await fixture.api.replacePullRequest(draft: true)
    case .baseReference:
      await fixture.api.replacePullRequest(baseRef: "release")
    case .baseSHA:
      await fixture.api.replacePullRequest(baseSHA: "not-a-sha")
    case .headSHA:
      await fixture.api.replacePullRequest(headSHA: "not-a-sha")
    case .emptyRange:
      await fixture.api.replacePullRequest(headSHA: fixture.baseSHA)
    case .bindingObjectNumber:
      break
    case .restCommitOrder:
      await fixture.api.setPullRequestCommits([
        fixture.headSHA, String(repeating: "7", count: 40),
      ])
    case .fetchedBase:
      await fixture.git.replace(
        PullRequestCommitDerivation(
          baseSHA: String(repeating: "8", count: 40),
          headSHA: fixture.headSHA,
          commitSHAs: [fixture.headSHA],
          narrative: []
        )
      )
    case .fetchedHead:
      await fixture.git.replace(
        PullRequestCommitDerivation(
          baseSHA: fixture.baseSHA,
          headSHA: String(repeating: "8", count: 40),
          commitSHAs: [fixture.headSHA],
          narrative: []
        )
      )
    }
    if drift == .bindingObjectNumber {
      binding = RolloutJobBinding(
        jobID: fixture.job.id,
        jobKind: .prReview,
        objectNumber: 11,
        contractVersion: fixture.job.contractVersionUsed,
        priority: .prReview,
        firstStep: .review,
        currentStep: JobStepKind.review.rawValue
      )
    }
    let builder = RolloutExactProposalBuilder(
      identity: fixture.api,
      api: fixture.api,
      makeGit: { _ in fixture.git }
    )
    let resolved = binding
    await #expect(throws: drift.expected) {
      _ = try await builder.observePullRequest(
        repository: repository,
        number: 10,
        resolveBinding: { _, _, _ in resolved }
      )
    }
    await fixture.database.close()
  }

  @Test("a proposal whose bytes are altered before activation fails closed")
  func alteredProposalFailsClosed() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let builder = RolloutExactProposalBuilder(
      identity: fixture.api,
      api: fixture.api,
      makeGit: { _ in fixture.git }
    )
    let observation = try await builder.observePullRequest(
      repository: fixture.rolloutRepository,
      number: 10,
      resolveBinding: { _, number, _ in
        RolloutJobBinding(
          jobID: fixture.job.id,
          jobKind: .prReview,
          objectNumber: number,
          contractVersion: fixture.job.contractVersionUsed,
          priority: .prReview,
          firstStep: .review,
          currentStep: JobStepKind.review.rawValue
        )
      }
    )
    let object = observation.object
    let tampered = RolloutObjectSelector(
      nodeID: object.nodeID,
      number: object.number,
      revisionKey: object.revisionKey,
      canonicalInputSHA256: String(repeating: "e", count: 64),
      headSHA: object.headSHA,
      baseSHA: object.baseSHA,
      narrativeSHA256: object.narrativeSHA256,
      currentStep: object.currentStep
    )
    let forged = try RolloutPreviewBuilder.make(
      fixture.previewInput(
        scope: RolloutScope(
          mode: .exactObject,
          stage: .prReview,
          repository: fixture.rolloutRepository,
          object: tampered,
          finiteWindow: nil
        ),
        jobs: 1,
        jobBinding: observation.jobBinding
      )
    )
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(forged)
    }
    await fixture.database.close()
  }

  @Test("a proposal for a closed or non-review repository never reaches a preview")
  func closedRepositoryProposalRefused() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let builder = RolloutExactProposalBuilder(
      identity: fixture.api,
      api: fixture.api,
      makeGit: { _ in fixture.git }
    )
    let observation = try await builder.observePullRequest(
      repository: fixture.rolloutRepository,
      number: 10,
      resolveBinding: { _, number, _ in
        RolloutJobBinding(
          jobID: fixture.job.id,
          jobKind: .prReview,
          objectNumber: number,
          contractVersion: fixture.job.contractVersionUsed,
          priority: .prReview,
          firstStep: .review,
          currentStep: JobStepKind.review.rawValue
        )
      }
    )
    let base = fixture.rolloutRepository
    for (enabled, reviewEnabled) in [(false, true), (true, false)] {
      let closed = RolloutRepositoryIdentity(
        id: fixture.repository.id,
        nodeID: base.nodeID,
        owner: base.owner,
        name: base.name,
        defaultBranch: base.defaultBranch,
        enabled: enabled,
        reviewEnabled: reviewEnabled,
        triageEnabled: base.triageEnabled,
        implementationEnabled: base.implementationEnabled
      )
      #expect(throws: RolloutAuthorityError.invalidRepositoryIdentity) {
        _ = try RolloutPreviewBuilder.make(
          fixture.previewInput(
            scope: RolloutScope(
              mode: .exactObject,
              stage: .prReview,
              repository: closed,
              object: observation.object,
              finiteWindow: nil
            ),
            jobs: 1,
            jobBinding: observation.jobBinding
          )
        )
      }
    }
    await fixture.database.close()
  }

  @Test("the proposal's Git reads are admitted by the authority production builds for them")
  func proposalGitReadAuthority() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let repository = fixture.rolloutRepository
    let binding = RolloutJobBinding(
      jobID: fixture.job.id,
      jobKind: .prReview,
      objectNumber: 10,
      contractVersion: fixture.job.contractVersionUsed,
      priority: .prReview,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    )
    // Exactly how ProductionEngineExternalServices builds the Git authority: bound to the job the
    // binding resolved to, with the policy ceiling. Two reads, because derivePullRequest fetches
    // the base and the head separately.
    func authority(jobID: UUID) throws -> BoundedRolloutPreviewReadAuthority {
      try BoundedRolloutPreviewReadAuthority(
        repository: GitHubRepositoryCoordinates(
          owner: repository.owner,
          repository: repository.name
        ),
        maximumRequests: 1,
        maximumBytes: Int64(GitHubBroker.maximumResponseBytes),
        repositoryID: fixture.repository.id,
        repositoryNodeID: repository.nodeID,
        jobID: jobID,
        maximumGitRemoteReads: RolloutExactProposalPolicy.gitRemoteReads
      )
    }

    let admitted = try authority(jobID: fixture.job.id)
    let observation = try await RolloutExactProposalBuilder(
      identity: fixture.api,
      api: fixture.api,
      makeGit: { jobID in
        RolloutAuthorityBoundGitFake(
          authority: admitted,
          derivation: PullRequestCommitDerivation(
            baseSHA: fixture.baseSHA,
            headSHA: fixture.headSHA,
            commitSHAs: [fixture.headSHA],
            narrative: [
              PiCommitNarrativeEntry(
                ordinal: 0,
                sha: fixture.headSHA,
                parentSHAs: [fixture.baseSHA],
                subject: "feat: bounded preview",
                patchSHA256: fixture.patchSHA256
              )
            ]
          ),
          repositoryID: fixture.repository.id,
          repositoryNodeID: repository.nodeID,
          jobID: jobID
        )
      }
    ).observePullRequest(
      repository: repository,
      number: 10,
      resolveBinding: { _, _, _ in binding }
    )
    #expect(observation.jobBinding == binding)
    #expect(await admitted.snapshot().reservedGitRemoteReads == 2)

    // The defect this pins: an authority bound to any other job admits nothing, and a ceiling of
    // one admits the base fetch and then refuses the head.
    let foreign = try authority(jobID: UUID())
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await foreign.reserveGitRemoteRead(
        RolloutGitRemoteReadEffect(
          jobID: fixture.job.id,
          repositoryID: fixture.repository.id,
          repositoryNodeID: repository.nodeID,
          operation: .fetchPreviewBase,
          target: "refs/heads/main:\(fixture.baseSHA)"
        ),
        now: Date(timeIntervalSince1970: 1_000)
      )
    }
    await fixture.database.close()
  }

  @Test("the pre-lane proposal ceilings are fixed and spend no provider session or mutation")
  func proposalPolicyCeilings() throws {
    #expect(RolloutExactProposalPolicy.identityRequests == 1)
    #expect(RolloutExactProposalPolicy.repositoryRequests == 40)
    // Two, because derivePullRequest fetches the base and the pull request head as separate
    // authorized reads; a ceiling of one admits the base and then refuses the head.
    #expect(RolloutExactProposalPolicy.gitRemoteReads == 2)
    // Every bounded read reserves the broker's whole response ceiling, so the byte ceiling is
    // the request ceiling and cannot be set below it.
    #expect(
      RolloutExactProposalPolicy.repositoryBytes
        == Int64(RolloutExactProposalPolicy.repositoryRequests)
        * Int64(GitHubBroker.maximumResponseBytes))
    #expect(
      RolloutExactProposalPolicy.identityBytes == Int64(GitHubBroker.maximumResponseBytes))

    let budgets = RolloutExactProposalPolicy.pullRequestReviewBudgets
    #expect(budgets.jobs == 1)
    #expect(budgets.providerSessions == 4)
    #expect(budgets.markerParts == 2)
    #expect(budgets.githubSends == 2)
    for zero in [
      budgets.approvedCommands, budgets.labelWrites, budgets.branchCreates,
      budgets.pullRequestCreates, budgets.gitSends,
    ] {
      #expect(zero == 0)
    }
    // A proposal that cannot be revalidated is not a proposal: the budgets it writes must
    // still admit the identity read plus the repository reads activation re-derives.
    let mapped = try ProductionEngineExternalServices.rolloutGitHubBudget(budgets)
    #expect(mapped.repositoryRequests == 39)
    #expect(
      mapped.repositoryBytes
        == RolloutExactProposalPolicy.repositoryBytes - Int64(GitHubBroker.maximumResponseBytes))
  }
}

/// Reserves the two remote reads `ProductionRolloutPreviewGitInspector.derivePullRequest` makes,
/// so the ceiling and the job binding are exercised rather than assumed.
private struct RolloutAuthorityBoundGitFake: RolloutPreviewGitInspecting {
  let authority: BoundedRolloutPreviewReadAuthority
  let derivation: PullRequestCommitDerivation
  let repositoryID: UUID
  let repositoryNodeID: String
  let jobID: UUID

  func derivePullRequest(
    repository _: RolloutRepositoryIdentity,
    number: Int,
    baseSHA: String,
    headSHA: String,
    jobID _: UUID
  ) async throws -> PullRequestCommitDerivation {
    for (operation, target) in [
      (RolloutGitRemoteOperation.fetchPreviewBase, "refs/heads/main:\(baseSHA)"),
      (RolloutGitRemoteOperation.fetchPullRequest, "refs/pull/\(number)/head:\(headSHA)"),
    ] {
      _ = try await authority.reserveGitRemoteRead(
        RolloutGitRemoteReadEffect(
          jobID: jobID,
          repositoryID: repositoryID,
          repositoryNodeID: repositoryNodeID,
          operation: operation,
          target: target
        ),
        now: Date(timeIntervalSince1970: 1_000)
      )
    }
    return derivation
  }
}

private actor RolloutProposalCallCounter {
  private(set) var count = 0
  func record() { count += 1 }
}

/// One case per guard in `RolloutExactProposalBuilder.observePullRequest`, so deleting any of
/// them turns a test red instead of minting a selector from drifted remote state.
enum RolloutProposalDrift: CaseIterable {
  case accountLogin
  case accountID
  case repositoryNodeID
  case repositoryOwner
  case repositoryName
  case defaultBranch
  case pullRequestClosed
  case pullRequestDraft
  case baseReference
  case baseSHA
  case headSHA
  case emptyRange
  case bindingObjectNumber
  case restCommitOrder
  case fetchedBase
  case fetchedHead

  var expected: RolloutAuthorityError {
    switch self {
    case .accountLogin, .accountID: .invalidReleaseIdentity
    case .repositoryNodeID, .repositoryOwner, .repositoryName, .defaultBranch:
      .invalidRepositoryIdentity
    case .pullRequestClosed, .pullRequestDraft, .baseReference, .baseSHA, .headSHA, .emptyRange:
      .invalidObjectSelector
    case .bindingObjectNumber: .invalidJobBinding
    case .restCommitOrder, .fetchedBase, .fetchedHead: .previewDrift
    }
  }
}

private enum RepositoryLabelInventoryDrift: CaseIterable {
  case duplicateNodeID
  case duplicateName
}

private enum IssueIdentityDrift: CaseIterable {
  case closed
  case becamePullRequest
  case missingBranchReference
}

private final class RolloutRemotePreviewFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let repository: RepositoryConfiguration
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let reviewedRevisions: ReviewedRevisionStore
  let api: RolloutRemotePreviewAPIFake
  let git: RolloutPreviewGitFake
  let revalidator: RolloutRemotePreviewRevalidator
  let job: JobRecord
  let triageJob: JobRecord
  let implementationJob: JobRecord
  let baseSHA = String(repeating: "1", count: 40)
  let headSHA = String(repeating: "2", count: 40)
  let patchSHA256 = String(repeating: "3", count: 64)

  init() async throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "jidoka-rollout-remote-preview-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "R_preview",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await ConfigurationStore(database: database).upsertRepository(
      repository,
      now: Date(timeIntervalSince1970: 1_000)
    )
    jobs = DurableJobStore(database: database, enforceRolloutAuthority: false)
    let created = try await jobs.createJob(
      id: UUID(),
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "PR_preview",
        revisionKey: headSHA
      ),
      objectNumber: 10,
      contractVersionUsed: "jidoka-code-v1",
      priority: .prReview,
      firstStep: .review,
      now: Date(timeIntervalSince1970: 1_000)
    )
    guard case .created(let job) = created else {
      throw RolloutRemotePreviewTestError.fixture
    }
    self.job = job
    let triageCreation = try await jobs.createJob(
      id: UUID(),
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueTriage,
        objectNodeID: "I_preview",
        revisionKey: "initial-triage"
      ),
      objectNumber: 11,
      contractVersionUsed: "jidoka-code-v1",
      priority: .triage,
      firstStep: .triage,
      now: Date(timeIntervalSince1970: 1_000)
    )
    guard case .created(let triageJob) = triageCreation else {
      throw RolloutRemotePreviewTestError.fixture
    }
    self.triageJob = triageJob
    let implementationCreation = try await jobs.createJob(
      id: UUID(),
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueImplementation,
        objectNodeID: "I_preview",
        revisionKey: "claim-1"
      ),
      objectNumber: 11,
      contractVersionUsed: "jidoka-code-v1",
      priority: .issueImplementation,
      firstStep: .claimReady,
      now: Date(timeIntervalSince1970: 1_000)
    )
    guard case .created(let implementationJob) = implementationCreation else {
      throw RolloutRemotePreviewTestError.fixture
    }
    self.implementationJob = implementationJob
    _ = try await database.execute(
      "UPDATE jobs SET state = 'waitingHuman', current_step = 2, current_step_kind = 'publishPlan' WHERE id = ?",
      bindings: [.text(implementationJob.id.uuidString.lowercased())]
    )
    intents = MutationIntentStore(database: database)
    reviewedRevisions = ReviewedRevisionStore(database: database)
    let user = GitHubUser(id: 42, nodeID: "U_preview", login: "owner")
    let remoteRepository = GitHubRepository(
      id: 7,
      nodeID: repository.nodeID,
      name: repository.name,
      fullName: "owner/repo",
      defaultBranch: repository.defaultBranch,
      owner: user
    )
    let pullRequest = Self.makePullRequest(
      number: 10,
      suffix: "preview",
      baseSHA: baseSHA,
      headSHA: headSHA,
      user: user
    )
    let issueLabels = [
      GitHubLabel(
        id: 100,
        nodeID: "L_bug",
        name: "bug",
        color: "d73a4a",
        description: "Something is not working"
      )
    ]
    let issue = GitHubIssue(
      id: 11,
      nodeID: "I_preview",
      number: 11,
      state: "open",
      title: "Preview triage",
      body: "bounded issue body",
      user: GitHubUser(id: 9, nodeID: "U_author", login: "author"),
      labels: issueLabels,
      createdAt: "2026-09-03T10:00:00Z",
      pullRequest: nil
    )
    let repositoryLabels = GitHubWorkflowLabelBootstrapper.definitions.enumerated().map {
      ordinal, definition in
      GitHubLabel(
        id: Int64(200 + ordinal),
        nodeID: "L_workflow_\(ordinal)",
        name: definition.name,
        color: definition.color,
        description: definition.description
      )
    }
    api = RolloutRemotePreviewAPIFake(
      identity: user,
      repository: remoteRepository,
      pullRequests: [pullRequest],
      issue: issue,
      issueLabels: issueLabels,
      repositoryLabels: repositoryLabels,
      branchSHA: baseSHA
    )
    let narrative = PiCommitNarrativeEntry(
      ordinal: 0,
      sha: headSHA,
      parentSHAs: [baseSHA],
      subject: "feat: bounded preview",
      patchSHA256: patchSHA256
    )
    git = RolloutPreviewGitFake(
      derivation: PullRequestCommitDerivation(
        baseSHA: baseSHA,
        headSHA: headSHA,
        commitSHAs: [headSHA],
        narrative: [narrative]
      )
    )
    revalidator = RolloutRemotePreviewRevalidator(
      identity: api,
      api: api,
      git: git,
      jobs: jobs,
      intents: intents,
      reviewedRevisions: reviewedRevisions
    )
  }

  func exactPreview(
    missingLabels: [RolloutLabelDefinition] = [],
    objectNumber: Int? = nil,
    jobBinding: RolloutJobBinding?? = nil
  ) throws -> RolloutPreview {
    let pullRequest = Self.makePullRequest(
      number: 10,
      suffix: "preview",
      baseSHA: baseSHA,
      headSHA: headSHA,
      user: GitHubUser(id: 42, nodeID: "U_preview", login: "owner")
    )
    let narrative = PiCommitNarrativeEntry(
      ordinal: 0,
      sha: headSHA,
      parentSHAs: [baseSHA],
      subject: "feat: bounded preview",
      patchSHA256: patchSHA256
    )
    let derivation = PullRequestCommitDerivation(
      baseSHA: baseSHA,
      headSHA: headSHA,
      commitSHAs: [headSHA],
      narrative: [narrative]
    )
    let artifact = try SystemPullRequestReviewJobPreparer.artifact(
      repository: repository,
      pullRequest: pullRequest,
      restCommitSHAs: [headSHA],
      fetched: derivation
    )
    let object = RolloutObjectSelector(
      nodeID: pullRequest.nodeID,
      number: objectNumber ?? pullRequest.number,
      revisionKey: headSHA,
      canonicalInputSHA256: GitHubMarkerCodec.sha256(artifact),
      headSHA: headSHA,
      baseSHA: baseSHA,
      narrativeSHA256: try PiPullRequestReviewRouter.commitNarrativeDigest(
        derivation.narrative,
        baseSHA: baseSHA
      ),
      currentStep: JobStepKind.review.rawValue
    )
    return try RolloutPreviewBuilder.make(
      previewInput(
        scope: RolloutScope(
          mode: .exactObject,
          stage: .prReview,
          repository: rolloutRepository,
          object: object,
          finiteWindow: nil
        ),
        jobs: 1,
        jobBinding: jobBinding
          ?? RolloutJobBinding(
            jobID: job.id,
            jobKind: .prReview,
            objectNumber: objectNumber ?? 10,
            contractVersion: job.contractVersionUsed,
            priority: .prReview,
            firstStep: .review,
            currentStep: JobStepKind.review.rawValue
          ),
        missingLabels: missingLabels
      )
    )
  }

  func finitePreview(
    stage: RolloutWorkflowStage = .prReview
  ) async throws -> RolloutPreview {
    let pullRequests = await api.currentPullRequests()
    let emptyScope = RolloutScope(
      mode: .finiteWindow,
      stage: stage,
      repository: rolloutRepository,
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: 2,
        expiresAtMilliseconds: 20_000_000,
        observedObjectNumberUpperBound: 10,
        maximumFutureObjectNumber: 10,
        candidates: []
      )
    )
    let eligible = pullRequests.filter { $0.nodeID != job.identity.objectNodeID }
    let candidates = try eligible.sorted { $0.number < $1.number }.enumerated().map {
      ordinal, pullRequest in
      RolloutWindowCandidate(
        ordinal: ordinal,
        nodeID: pullRequest.nodeID,
        number: pullRequest.number,
        revisionKey: pullRequest.head.sha,
        canonicalInputSHA256: try RolloutPreviewBuilder.futureCandidateSHA256(
          scope: emptyScope,
          nodeID: pullRequest.nodeID,
          number: pullRequest.number,
          revisionKey: pullRequest.head.sha
        )
      )
    }
    let scope = RolloutScope(
      mode: .finiteWindow,
      stage: stage,
      repository: rolloutRepository,
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: 2,
        expiresAtMilliseconds: 20_000_000,
        observedObjectNumberUpperBound: 10,
        maximumFutureObjectNumber: 10,
        candidates: candidates
      )
    )
    return try RolloutPreviewBuilder.make(
      previewInput(scope: scope, jobs: 2, jobBinding: nil)
    )
  }

  func exactTriagePreview() async throws -> RolloutPreview {
    let issue = await api.currentIssue()
    let labels = await api.currentIssueLabels()
    let comments = await api.currentComments()
    let revision = try await DurableIssueRevisionDeriver(
      intents: intents,
      appAuthorID: 42
    ).derive(
      repositoryNodeID: repository.nodeID,
      issue: issue,
      comments: comments,
      labels: labels
    )
    let base = try BaseRevision(branch: repository.defaultBranch, sha: baseSHA)
    let artifact = try SystemIssueTriageJobPreparer.artifact(
      repository: repository,
      issue: issue,
      comments: comments,
      labels: labels,
      issueRevision: revision,
      baseRevision: base
    )
    let object = RolloutObjectSelector(
      nodeID: issue.nodeID,
      number: issue.number,
      revisionKey: triageJob.identity.revisionKey,
      canonicalInputSHA256: GitHubMarkerCodec.sha256(artifact),
      baseSHA: base.sha,
      labelStateSHA256: try RolloutPreviewBuilder.labelStateSHA256(labels),
      currentStep: JobStepKind.triage.rawValue
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: .issueTriage,
      repository: rolloutRepository,
      object: object,
      finiteWindow: nil
    )
    return try RolloutPreviewBuilder.make(
      previewInput(
        scope: scope,
        jobs: 1,
        jobBinding: RolloutJobBinding(
          jobID: triageJob.id,
          jobKind: .issueTriage,
          objectNumber: issue.number,
          contractVersion: triageJob.contractVersionUsed,
          priority: .triage,
          firstStep: .triage,
          currentStep: JobStepKind.triage.rawValue
        )
      )
    )
  }

  func exactWaitingExecutionPreview(
    currentStep: JobStepKind = .publishPlan
  ) async throws -> RolloutPreview {
    await api.setWorkflowLabels(["agent:plan-review", "plan:approved"])
    let issue = await api.currentIssue()
    let labels = await api.currentIssueLabels()
    let comments = await api.currentComments()
    let revision = try await DurableIssueRevisionDeriver(
      intents: intents,
      appAuthorID: 42
    ).derive(
      repositoryNodeID: repository.nodeID,
      issue: issue,
      comments: comments,
      labels: labels
    )
    let base = try BaseRevision(branch: repository.defaultBranch, sha: baseSHA)
    let branch = try SystemIssueImplementationJobPreparer.branch(
      number: issue.number,
      title: issue.title
    )
    let artifact = try SystemIssueImplementationJobPreparer.artifact(
      repository: repository,
      issue: issue,
      comments: comments,
      labels: labels,
      revision: revision,
      base: base,
      branch: branch,
      planPath: "docs/plans/jidoka-code-issue-\(issue.number).md"
    )
    let object = RolloutObjectSelector(
      nodeID: issue.nodeID,
      number: issue.number,
      revisionKey: implementationJob.identity.revisionKey,
      canonicalInputSHA256: GitHubMarkerCodec.sha256(artifact),
      baseSHA: base.sha,
      planSHA256: String(repeating: "d", count: 64),
      labelStateSHA256: try RolloutPreviewBuilder.labelStateSHA256(labels),
      currentStep: currentStep.rawValue
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: .implementationExecute,
      repository: rolloutRepository,
      object: object,
      finiteWindow: nil
    )
    return try RolloutPreviewBuilder.make(
      previewInput(
        scope: scope,
        jobs: 1,
        jobBinding: RolloutJobBinding(
          jobID: implementationJob.id,
          jobKind: .issueImplementation,
          objectNumber: issue.number,
          contractVersion: implementationJob.contractVersionUsed,
          priority: .issueImplementation,
          firstStep: .claimApprovedPlan,
          currentStep: currentStep.rawValue
        )
      )
    )
  }

  func pullRequest(number: Int, suffix: String, draft: Bool = false) -> GitHubPullRequest {
    Self.makePullRequest(
      number: number,
      suffix: suffix,
      baseSHA: baseSHA,
      headSHA: String(repeating: String(String(number).suffix(1)), count: 40),
      user: GitHubUser(id: 42, nodeID: "U_preview", login: "owner"),
      draft: draft
    )
  }

  func apply(_ drift: ExactPullRequestDrift) async {
    let alternateGitSHA = String(repeating: "4", count: 40)
    switch drift {
    case .identityID:
      await api.setIdentity(GitHubUser(id: 43, nodeID: "U_preview", login: "owner"))
    case .identityLogin:
      await api.setIdentity(GitHubUser(id: 42, nodeID: "U_preview", login: "other"))
    case .repositoryNode:
      await api.replaceRepository(nodeID: "R_redirected")
    case .repositoryOwner:
      await api.replaceRepository(ownerLogin: "other")
    case .repositoryName:
      await api.replaceRepository(name: "other")
    case .defaultBranch:
      await api.replaceRepository(defaultBranch: "trunk")
    case .pullRequestState:
      await api.replacePullRequest(state: "closed")
    case .pullRequestDraft:
      await api.replacePullRequest(draft: true)
    case .pullRequestTitle:
      await api.replacePullRequest(title: "changed after preview")
    case .pullRequestBody:
      await api.replacePullRequest(body: "changed after preview")
    case .pullRequestHead:
      await api.replacePullRequest(headSHA: alternateGitSHA)
    case .pullRequestBaseRef:
      await api.replacePullRequest(baseRef: "trunk")
    case .pullRequestBaseSHA:
      await api.replacePullRequest(baseSHA: alternateGitSHA)
    case .restCommitOrder:
      await api.setPullRequestCommits([alternateGitSHA, headSHA])
    case .fetchedBase:
      await git.replace(
        derivation(baseSHA: alternateGitSHA, headSHA: headSHA, commits: [headSHA])
      )
    case .fetchedHead:
      await git.replace(
        derivation(baseSHA: baseSHA, headSHA: alternateGitSHA, commits: [headSHA])
      )
    case .fetchedCommits:
      await git.replace(
        derivation(baseSHA: baseSHA, headSHA: headSHA, commits: [alternateGitSHA])
      )
    case .fetchedNarrative:
      await git.replace(
        derivation(
          baseSHA: baseSHA,
          headSHA: headSHA,
          commits: [headSHA],
          patchSHA256: String(repeating: "5", count: 64)
        )
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  var rolloutRepository: RolloutRepositoryIdentity {
    RolloutRepositoryIdentity(
      id: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      enabled: true,
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true
    )
  }

  private func derivation(
    baseSHA: String,
    headSHA: String,
    commits: [String],
    patchSHA256: String? = nil
  ) -> PullRequestCommitDerivation {
    PullRequestCommitDerivation(
      baseSHA: baseSHA,
      headSHA: headSHA,
      commitSHAs: commits,
      narrative: [
        PiCommitNarrativeEntry(
          ordinal: 0,
          sha: self.headSHA,
          parentSHAs: [self.baseSHA],
          subject: "feat: bounded preview",
          patchSHA256: patchSHA256 ?? self.patchSHA256
        )
      ]
    )
  }

  func previewInput(
    scope: RolloutScope,
    jobs: Int,
    jobBinding: RolloutJobBinding?,
    missingLabels: [RolloutLabelDefinition] = []
  ) -> RolloutPreviewInput {
    let digest = String(repeating: "a", count: 64)
    return RolloutPreviewInput(
      releaseIdentity: RolloutReleaseIdentity(
        sourceCommit: String(repeating: "b", count: 40),
        sourceTree: String(repeating: "c", count: 40),
        bundleVersion: "0.2.0",
        bundleBuild: 7,
        applicationSHA256: digest,
        helperSHA256: digest,
        askPassSHA256: digest,
        pushGuardSHA256: digest,
        herdrHostSHA256: digest,
        schemaVersion: 11,
        engineProtocolVersion: 13,
        runtimeManifestSHA256: digest,
        runtimeTreeSHA256: digest,
        modelProfilesSHA256: digest,
        workflowResourcesSHA256: digest,
        githubAccount: "owner",
        githubAuthorID: 42,
        repositoryConfigurationSHA256: digest,
        maxConcurrency: 1
      ),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: jobs,
        githubReadRequests: 20,
        githubReadPages: 20,
        githubReadBytes: 200 * 1_024 * 1_024,
        gitRemoteReads: scope.stage == .prReview || scope.stage == .generatedPRReview ? 2 : 0,
        providerSessions: scope.stage.providerSessionLimit * jobs,
        approvedCommands: 0,
        markerParts: jobs,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: jobs,
        gitSends: 0
      ),
      inventory: RolloutInventory(
        queueSHA256: digest,
        recoverySHA256: digest,
        mutationIntentSHA256: digest,
        queueItemCount: 0,
        recoveryItemCount: 0,
        mutationItemCount: 0,
        outsideScopeQueueSHA256: digest,
        outsideScopeRecoverySHA256: digest,
        outsideScopeMutationIntentSHA256: digest,
        outsideScopeQueueItemCount: 0,
        outsideScopeRecoveryItemCount: 0,
        outsideScopeMutationItemCount: 0
      ),
      missingLabels: missingLabels,
      commands: [],
      jobBinding: jobBinding,
      createdAtMilliseconds: 1_000,
      expiresAtMilliseconds: 500_000
    )
  }

  private static func makePullRequest(
    number: Int,
    suffix: String,
    baseSHA: String,
    headSHA: String,
    user: GitHubUser,
    draft: Bool = false
  ) -> GitHubPullRequest {
    let pullRepository = GitHubPullRepository(
      id: 7,
      nodeID: "R_preview",
      fullName: "owner/repo"
    )
    return GitHubPullRequest(
      id: Int64(number),
      nodeID: number == 10 ? "PR_preview" : "PR_\(suffix)",
      number: number,
      state: "open",
      draft: draft,
      title: "Preview \(suffix)",
      body: "body \(suffix)",
      htmlURL: "https://github.com/owner/repo/pull/\(number)",
      user: user,
      head: GitHubPullReference(
        ref: "feature-\(suffix)",
        sha: headSHA,
        repository: pullRepository
      ),
      base: GitHubPullReference(
        ref: "main",
        sha: baseSHA,
        repository: pullRepository
      )
    )
  }
}

private actor RolloutRemotePreviewAPIFake: RolloutPreviewIdentityReading,
  RolloutPreviewRepositoryReading
{
  private var identityValue: GitHubUser
  private var repositoryValue: GitHubRepository
  private var pullRequestsValue: [GitHubPullRequest]
  private var pullRequestCommitsValue: [GitHubPullRequestCommit]
  private var issueValue: GitHubIssue
  private var issueLabelsValue: [GitHubLabel]
  private var commentsValue: [GitHubComment] = []
  private var repositoryLabelsValue: [GitHubLabel]
  private var branchSHA: String
  private var branchReferenceAvailable = true
  private var repositoryReadFails = false

  init(
    identity: GitHubUser,
    repository: GitHubRepository,
    pullRequests: [GitHubPullRequest],
    issue: GitHubIssue,
    issueLabels: [GitHubLabel],
    repositoryLabels: [GitHubLabel],
    branchSHA: String
  ) {
    identityValue = identity
    repositoryValue = repository
    pullRequestsValue = pullRequests
    pullRequestCommitsValue = [GitHubPullRequestCommit(sha: String(repeating: "2", count: 40))]
    issueValue = issue
    issueLabelsValue = issueLabels
    repositoryLabelsValue = repositoryLabels
    self.branchSHA = branchSHA
  }

  func authenticatedIdentity() -> GitHubUser { identityValue }

  func repository(
    owner _: String,
    repository _: String,
    expectedNodeID _: String?
  ) throws -> GitHubRepository {
    if repositoryReadFails { throw RolloutRemotePreviewTestError.fixture }
    return repositoryValue
  }

  func listPullRequests(owner _: String, repository _: String) -> [GitHubPullRequest] {
    pullRequestsValue
  }

  func pullRequest(
    owner _: String,
    repository _: String,
    number: Int
  ) throws -> GitHubPullRequest {
    guard let value = pullRequestsValue.first(where: { $0.number == number }) else {
      throw RolloutRemotePreviewTestError.fixture
    }
    return value
  }

  func listPullRequestCommits(
    owner _: String,
    repository _: String,
    number _: Int
  ) -> [GitHubPullRequestCommit] {
    pullRequestCommitsValue
  }

  func listIssues(owner _: String, repository _: String) -> [GitHubIssue] { [issueValue] }
  func issue(owner _: String, repository _: String, number: Int) async throws -> GitHubIssue {
    guard number == issueValue.number else { throw RolloutRemotePreviewTestError.fixture }
    return issueValue
  }
  func listComments(
    owner _: String,
    repository _: String,
    number _: Int
  ) -> [GitHubComment] { commentsValue }
  func listIssueLabels(
    owner _: String,
    repository _: String,
    number _: Int
  ) -> [GitHubLabel] { issueLabelsValue }
  func lookupPullRequests(
    owner _: String,
    repository _: String,
    head _: String,
    base _: String
  ) -> [GitHubPullRequest] { [] }
  func repositoryLabel(
    owner _: String,
    repository _: String,
    label _: String
  ) -> GitHubLabel? { nil }
  func branchReference(
    owner _: String,
    repository _: String,
    branch _: String
  ) -> GitHubReference? {
    guard branchReferenceAvailable else { return nil }
    return GitHubReference(
      ref: "refs/heads/main",
      nodeID: "REF_main",
      object: GitHubGitObject(
        sha: branchSHA,
        type: "commit",
        url: "https://api.github.com/repos/owner/repo/git/commits/\(branchSHA)"
      )
    )
  }
  func listRepositoryLabels(owner _: String, repository _: String) -> [GitHubLabel] {
    repositoryLabelsValue
  }

  func setIdentity(_ identity: GitHubUser) {
    identityValue = identity
  }

  func replaceRepository(
    nodeID: String? = nil,
    ownerLogin: String? = nil,
    name: String? = nil,
    defaultBranch: String? = nil
  ) {
    let owner = GitHubUser(
      id: repositoryValue.owner.id,
      nodeID: repositoryValue.owner.nodeID,
      login: ownerLogin ?? repositoryValue.owner.login
    )
    let resolvedName = name ?? repositoryValue.name
    repositoryValue = GitHubRepository(
      id: repositoryValue.id,
      nodeID: nodeID ?? repositoryValue.nodeID,
      name: resolvedName,
      fullName: "\(owner.login)/\(resolvedName)",
      defaultBranch: defaultBranch ?? repositoryValue.defaultBranch,
      owner: owner
    )
  }

  func replacePullRequest(
    state: String? = nil,
    draft: Bool? = nil,
    title: String? = nil,
    body: String? = nil,
    headSHA: String? = nil,
    baseRef: String? = nil,
    baseSHA: String? = nil
  ) {
    guard let current = pullRequestsValue.first else { return }
    pullRequestsValue[0] = GitHubPullRequest(
      id: current.id,
      nodeID: current.nodeID,
      number: current.number,
      state: state ?? current.state,
      draft: draft ?? current.draft,
      title: title ?? current.title,
      body: body ?? current.body,
      htmlURL: current.htmlURL,
      user: current.user,
      head: GitHubPullReference(
        ref: current.head.ref,
        sha: headSHA ?? current.head.sha,
        repository: current.head.repository
      ),
      base: GitHubPullReference(
        ref: baseRef ?? current.base.ref,
        sha: baseSHA ?? current.base.sha,
        repository: current.base.repository
      )
    )
  }

  func setPullRequestCommits(_ shas: [String]) {
    pullRequestCommitsValue = shas.map { GitHubPullRequestCommit(sha: $0) }
  }

  func appendPullRequest(_ pullRequest: GitHubPullRequest) {
    pullRequestsValue.append(pullRequest)
  }

  func replaceIssue(body: String) {
    issueValue = GitHubIssue(
      id: issueValue.id,
      nodeID: issueValue.nodeID,
      number: issueValue.number,
      state: issueValue.state,
      title: issueValue.title,
      body: body,
      user: issueValue.user,
      labels: issueLabelsValue,
      createdAt: issueValue.createdAt,
      pullRequest: issueValue.pullRequest
    )
  }

  func currentIssue() -> GitHubIssue { issueValue }
  func currentIssueLabels() -> [GitHubLabel] { issueLabelsValue }
  func currentComments() -> [GitHubComment] { commentsValue }

  func currentPullRequests() -> [GitHubPullRequest] { pullRequestsValue }

  func removeLastRepositoryLabel() {
    _ = repositoryLabelsValue.popLast()
  }

  func duplicateFirstRepositoryLabelNodeID() {
    guard let first = repositoryLabelsValue.first else { return }
    repositoryLabelsValue.append(
      GitHubLabel(
        id: first.id + 9_000,
        nodeID: first.nodeID,
        name: "duplicate-node-\(first.id)",
        color: first.color,
        description: first.description
      )
    )
  }

  func duplicateFirstRepositoryLabelName() {
    guard let first = repositoryLabelsValue.first else { return }
    repositoryLabelsValue.append(
      GitHubLabel(
        id: first.id + 8_000,
        nodeID: "\(first.nodeID)-duplicate-name",
        name: first.name,
        color: first.color,
        description: first.description
      )
    )
  }

  func replaceIssue(state: String? = nil, asPullRequest: Bool? = nil) {
    issueValue = GitHubIssue(
      id: issueValue.id,
      nodeID: issueValue.nodeID,
      number: issueValue.number,
      state: state ?? issueValue.state,
      title: issueValue.title,
      body: issueValue.body,
      user: issueValue.user,
      labels: issueLabelsValue,
      createdAt: issueValue.createdAt,
      pullRequest: (asPullRequest ?? (issueValue.pullRequest != nil))
        ? GitHubIssuePullMarker(url: "https://api.github.com/repos/owner/repo/pulls/1")
        : nil
    )
  }

  func removeBranchReference() {
    branchReferenceAvailable = false
  }

  func failNextRepositoryRead() {
    repositoryReadFails = true
  }

  func setWorkflowLabels(_ names: Set<String>) {
    let domain = issueLabelsValue.filter {
      !$0.name.lowercased().hasPrefix("agent:")
        && !$0.name.lowercased().hasPrefix("plan:")
    }
    let workflow = repositoryLabelsValue.filter { names.contains($0.name.lowercased()) }
    issueLabelsValue = domain + workflow
    issueValue = GitHubIssue(
      id: issueValue.id,
      nodeID: issueValue.nodeID,
      number: issueValue.number,
      state: issueValue.state,
      title: issueValue.title,
      body: issueValue.body,
      user: issueValue.user,
      labels: issueLabelsValue,
      createdAt: issueValue.createdAt,
      pullRequest: issueValue.pullRequest
    )
  }
}

private actor RolloutPreviewGitFake: RolloutPreviewGitInspecting {
  private var derivation: PullRequestCommitDerivation

  init(derivation: PullRequestCommitDerivation) {
    self.derivation = derivation
  }

  func derivePullRequest(
    repository _: RolloutRepositoryIdentity,
    number _: Int,
    baseSHA _: String,
    headSHA _: String,
    jobID _: UUID
  ) -> PullRequestCommitDerivation {
    derivation
  }

  func replace(_ derivation: PullRequestCommitDerivation) {
    self.derivation = derivation
  }
}

private enum RolloutRemotePreviewTestError: Error {
  case fixture
}
