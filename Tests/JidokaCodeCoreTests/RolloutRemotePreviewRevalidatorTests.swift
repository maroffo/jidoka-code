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
      let preview = try fixture.exactPreview()
      try await fixture.revalidator.revalidate(preview)
      await fixture.apply(drift)
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await fixture.revalidator.revalidate(preview)
      }
      await fixture.database.close()
      fixture.remove()
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
      fixture.remove()
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
  //   - the workflow-label default arm, refused by `RolloutAuthority.validCurrentStep`,
  //     whose whitelist is exactly that switch's case set
  //     (`builderRefusesAStepTheLabelSwitchDoesNotCover`).
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
        text.replacingOccurrences(of: "\"bundleBuild\":3", with: "\"bundleBuild\":4").utf8
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
      fixture.remove()
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
    // The workflow-label switch's `default:` arm exists for a stage/step pair outside
    // its case set. `RolloutAuthority.validCurrentStep` enumerates exactly that set
    // per stage and refuses anything else, so the arm cannot be reached from a built
    // preview. `.replan` belongs to `implementationPlan`, never to `prReview`.
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    #expect(throws: RolloutAuthorityError.invalidObjectSelector) {
      _ = try fixture.exactPreview(currentStep: .replan)
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
      await #expect(throws: RolloutAuthorityError.invalidFiniteWindow, "\(stage)") {
        _ = try await fixture.finitePreview(stage: stage)
      }
      await fixture.database.close()
      fixture.remove()
    }
  }

  @Test("issue identity and default-branch reference drift are rejected")
  func issueIdentityDrift() async throws {
    for drift in IssueIdentityDrift.allCases {
      let fixture = try await RolloutRemotePreviewFixture()
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
      fixture.remove()
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
    jobBinding: RolloutJobBinding?? = nil,
    currentStep: JobStepKind = .review
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
      currentStep: currentStep.rawValue
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
            currentStep: currentStep.rawValue
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

  func exactWaitingExecutionPreview() async throws -> RolloutPreview {
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
      currentStep: JobStepKind.publishPlan.rawValue
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
          currentStep: JobStepKind.publishPlan.rawValue
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

  private var rolloutRepository: RolloutRepositoryIdentity {
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

  private func previewInput(
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
        bundleBuild: 3,
        applicationSHA256: digest,
        helperSHA256: digest,
        askPassSHA256: digest,
        pushGuardSHA256: digest,
        herdrHostSHA256: digest,
        schemaVersion: 10,
        engineProtocolVersion: 12,
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
