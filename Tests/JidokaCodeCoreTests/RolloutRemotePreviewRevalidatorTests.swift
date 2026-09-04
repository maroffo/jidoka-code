import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Rollout remote preview revalidation")
struct RolloutRemotePreviewRevalidatorTests {
  @Test("exact PR preview binds title, body, ordered commits, and Git narrative")
  func exactPullRequestDrift() async throws {
    let fixture = try await RolloutRemotePreviewFixture()
    defer { fixture.remove() }
    let preview = try fixture.exactPreview()
    try await fixture.revalidator.revalidate(preview)

    await fixture.api.replacePullRequest(body: "changed after preview")
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.revalidator.revalidate(preview)
    }
    await fixture.database.close()
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
}

private final class RolloutRemotePreviewFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let repository: RepositoryConfiguration
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let reviewedRevisions: ReviewedRevisionStore
  let api: RolloutRemotePreviewAPIFake
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
    jobs = DurableJobStore(database: database)
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
    revalidator = RolloutRemotePreviewRevalidator(
      identity: api,
      api: api,
      git: RolloutPreviewGitFake(
        derivation: PullRequestCommitDerivation(
          baseSHA: baseSHA,
          headSHA: headSHA,
          commitSHAs: [headSHA],
          narrative: [narrative]
        )
      ),
      jobs: jobs,
      intents: intents,
      reviewedRevisions: reviewedRevisions
    )
  }

  func exactPreview() throws -> RolloutPreview {
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
      number: pullRequest.number,
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
        jobBinding: RolloutJobBinding(
          jobID: job.id,
          jobKind: .prReview,
          objectNumber: 10,
          contractVersion: job.contractVersionUsed,
          priority: .prReview,
          firstStep: .review,
          currentStep: JobStepKind.review.rawValue
        )
      )
    )
  }

  func finitePreview() async throws -> RolloutPreview {
    let pullRequests = await api.currentPullRequests()
    let emptyScope = RolloutScope(
      mode: .finiteWindow,
      stage: .prReview,
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
      stage: .prReview,
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

  func pullRequest(number: Int, suffix: String) -> GitHubPullRequest {
    Self.makePullRequest(
      number: number,
      suffix: suffix,
      baseSHA: baseSHA,
      headSHA: String(repeating: String(String(number).suffix(1)), count: 40),
      user: GitHubUser(id: 42, nodeID: "U_preview", login: "owner")
    )
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

  private func previewInput(
    scope: RolloutScope,
    jobs: Int,
    jobBinding: RolloutJobBinding?
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
      missingLabels: [],
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
    user: GitHubUser
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
      draft: false,
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
  private let identityValue: GitHubUser
  private let repositoryValue: GitHubRepository
  private var pullRequestsValue: [GitHubPullRequest]
  private var issueValue: GitHubIssue
  private var issueLabelsValue: [GitHubLabel]
  private var commentsValue: [GitHubComment] = []
  private let repositoryLabelsValue: [GitHubLabel]
  private let branchSHA: String

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
  ) -> GitHubRepository {
    repositoryValue
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
    [GitHubPullRequestCommit(sha: String(repeating: "2", count: 40))]
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
    GitHubReference(
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

  func replacePullRequest(body: String) {
    guard let current = pullRequestsValue.first else { return }
    pullRequestsValue[0] = GitHubPullRequest(
      id: current.id,
      nodeID: current.nodeID,
      number: current.number,
      state: current.state,
      draft: current.draft,
      title: current.title,
      body: body,
      htmlURL: current.htmlURL,
      user: current.user,
      head: current.head,
      base: current.base
    )
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

private struct RolloutPreviewGitFake: RolloutPreviewGitInspecting {
  let derivation: PullRequestCommitDerivation

  func derivePullRequest(
    repository _: RolloutRepositoryIdentity,
    number _: Int,
    baseSHA _: String,
    headSHA _: String,
    jobID _: UUID
  ) -> PullRequestCommitDerivation {
    derivation
  }
}

private enum RolloutRemotePreviewTestError: Error {
  case fixture
}
