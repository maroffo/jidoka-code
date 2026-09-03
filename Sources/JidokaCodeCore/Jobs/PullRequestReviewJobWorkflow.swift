import Foundation

public protocol PullRequestReviewGitHubAPI: GitHubMutationReadAPI,
  GitHubPullRequestCommitAPI
{}

extension GitHubBroker: PullRequestReviewGitHubAPI {}

public struct PreparedPullRequestReviewJob: Sendable {
  public let repository: RepositoryConfiguration
  public let pullRequest: GitHubPullRequest
  public let restCommitSHAs: [String]
  public let fetched: PullRequestCommitDerivation
  public let workspaceURL: URL
  public let artifact: Data

  public init(
    repository: RepositoryConfiguration,
    pullRequest: GitHubPullRequest,
    restCommitSHAs: [String],
    fetched: PullRequestCommitDerivation,
    workspaceURL: URL,
    artifact: Data
  ) {
    self.repository = repository
    self.pullRequest = pullRequest
    self.restCommitSHAs = restCommitSHAs
    self.fetched = fetched
    self.workspaceURL = workspaceURL
    self.artifact = artifact
  }
}

public enum PullRequestReviewJobError: Error, Equatable, Sendable {
  case invalidJob
  case repositoryDisabled
  case remoteIdentityMismatch
  case commitSourcesMismatch
  case invalidArtifact
  case unexpectedState(JobState)
  case reviewBlocked
  case publicationEscalated
  case commentAttributionMissing
}

public protocol PullRequestReviewJobPreparing: Sendable {
  func prepare(job: JobRecord) async throws -> PreparedPullRequestReviewJob
}

public protocol GitRemoteRepositoryResolving: Sendable {
  func remote(for repository: RepositoryConfiguration) throws -> GitRemoteRepository
}

public struct GitHubRemoteRepositoryResolver: GitRemoteRepositoryResolving, Sendable {
  public init() {}

  public func remote(for repository: RepositoryConfiguration) throws -> GitRemoteRepository {
    try GitRemoteRepository(repository: repository)
  }
}

public struct SystemPullRequestReviewJobPreparer: PullRequestReviewJobPreparing, Sendable {
  private let configuration: ConfigurationStore
  private let api: any PullRequestReviewGitHubAPI
  private let repositories: RepositoryStore
  private let deriver: any PullRequestCommitDeriving
  private let remoteResolver: any GitRemoteRepositoryResolving
  private let credentials: (any GitCredentialSessionProviding)?

  public init(
    configuration: ConfigurationStore,
    api: any PullRequestReviewGitHubAPI,
    repositories: RepositoryStore,
    deriver: any PullRequestCommitDeriving,
    remoteResolver: any GitRemoteRepositoryResolving = GitHubRemoteRepositoryResolver(),
    credentials: (any GitCredentialSessionProviding)? = nil
  ) {
    self.configuration = configuration
    self.api = api
    self.repositories = repositories
    self.deriver = deriver
    self.remoteResolver = remoteResolver
    self.credentials = credentials
  }

  public func prepare(job: JobRecord) async throws -> PreparedPullRequestReviewJob {
    guard job.identity.kind == .prReview, let number = job.objectNumber, number > 0 else {
      throw PullRequestReviewJobError.invalidJob
    }
    guard let repository = try await configuration.repository(id: job.identity.repositoryID),
      repository.enabled,
      repository.reviewEnabled
    else {
      throw PullRequestReviewJobError.repositoryDisabled
    }
    let pullRequest = try await api.pullRequest(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    guard pullRequest.nodeID == job.identity.objectNodeID,
      pullRequest.number == number,
      pullRequest.state == "open",
      !pullRequest.draft,
      pullRequest.head.sha == job.identity.revisionKey,
      pullRequest.base.ref == repository.defaultBranch,
      GitHubInputValidation.validGitSHA(pullRequest.base.sha),
      GitHubInputValidation.validGitSHA(pullRequest.head.sha),
      pullRequest.base.sha != pullRequest.head.sha
    else {
      throw PullRequestReviewJobError.remoteIdentityMismatch
    }
    let restCommits = try await api.listPullRequestCommits(
      owner: repository.owner,
      repository: repository.name,
      number: number
    ).map(\.sha)
    guard restCommits.last == pullRequest.head.sha else {
      throw PullRequestReviewJobError.commitSourcesMismatch
    }
    let remote = try remoteResolver.remote(for: repository)
    let fetch = try await repositories.fetchPullRequestMaterialization(
      number: number,
      expectedSHA: pullRequest.head.sha,
      jobID: job.id,
      remote: remote,
      credentials: credentials
    )
    let fetched = try await deriver.derive(
      baseSHA: pullRequest.base.sha,
      headSHA: fetch.headSHA,
      mirror: fetch.mirrorURL
    )
    guard Set(restCommits) == Set(fetched.commitSHAs),
      restCommits.count == fetched.commitSHAs.count
    else {
      throw PullRequestReviewJobError.commitSourcesMismatch
    }
    let materialization = try await repositories.materializeReviewWorkspace(
      jobID: job.id,
      remote: remote,
      baseSHA: pullRequest.base.sha,
      headSHA: pullRequest.head.sha,
      mirrorURL: fetch.mirrorURL,
      credentials: credentials,
      now: job.updatedAt
    )
    let artifact = try Self.artifact(
      repository: repository,
      pullRequest: pullRequest,
      restCommitSHAs: restCommits,
      fetched: fetched
    )
    return PreparedPullRequestReviewJob(
      repository: repository,
      pullRequest: pullRequest,
      restCommitSHAs: restCommits,
      fetched: fetched,
      workspaceURL: materialization.workspaceURL,
      artifact: artifact
    )
  }

  private static func artifact(
    repository: RepositoryConfiguration,
    pullRequest: GitHubPullRequest,
    restCommitSHAs: [String],
    fetched: PullRequestCommitDerivation
  ) throws -> Data {
    let object: [String: Any] = [
      "base": [
        "ref": pullRequest.base.ref,
        "sha": pullRequest.base.sha,
      ],
      "commits": fetched.narrative.map { commit in
        [
          "ordinal": commit.ordinal,
          "parentSHAs": commit.parentSHAs,
          "patchSHA256": commit.patchSHA256,
          "sha": commit.sha,
          "subject": commit.subject,
        ] as [String: Any]
      },
      "fetchedCommitSHAs": fetched.commitSHAs,
      "head": [
        "ref": pullRequest.head.ref,
        "sha": pullRequest.head.sha,
      ],
      "pullRequest": [
        "body": pullRequest.body ?? "",
        "nodeID": pullRequest.nodeID,
        "number": pullRequest.number,
        "title": pullRequest.title,
        "url": pullRequest.htmlURL,
      ],
      "repository": [
        "name": repository.name,
        "nodeID": repository.nodeID,
        "owner": repository.owner,
      ],
      "restCommitSHAs": restCommitSHAs,
      "schemaVersion": 1,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PullRequestReviewJobError.invalidArtifact
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

public protocol PullRequestReviewExecuting: Sendable {
  func review(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) async throws -> PiPullRequestReviewOutput
  func reviewCanaryArchitecture(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) async throws -> PiWorkflowRoleResult
}

extension PullRequestReviewExecuting {
  public func reviewCanaryArchitecture(
    job _: JobRecord,
    prepared _: PreparedPullRequestReviewJob,
    artifactSHA256 _: String
  ) async throws -> PiWorkflowRoleResult {
    throw PullRequestReviewJobError.invalidJob
  }
}

public struct PiPullRequestReviewJobExecutor: PullRequestReviewExecuting, Sendable {
  private let executorFactory: any PiWorkflowExecutorBuilding
  private let sessionRoot: URL
  private let profiles: [ModelProfileConfiguration]
  private let offline: Bool
  private let timeoutSeconds: TimeInterval

  public init(
    executorFactory: any PiWorkflowExecutorBuilding,
    sessionRoot: URL,
    profiles: [ModelProfileConfiguration],
    offline: Bool = false,
    timeoutSeconds: TimeInterval = 600
  ) {
    self.executorFactory = executorFactory
    self.sessionRoot = sessionRoot
    self.profiles = profiles
    self.offline = offline
    self.timeoutSeconds = timeoutSeconds
  }

  public func review(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) async throws -> PiPullRequestReviewOutput {
    let context = PiJobWorkflowContext(
      artifact: prepared.artifact,
      workspaceRoot: prepared.workspaceURL,
      sessionRoot: sessionRoot,
      profiles: profiles,
      allowedWritePaths: [],
      offline: offline,
      timeoutSeconds: timeoutSeconds
    )
    let executor = executorFactory.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: context)
    )
    return try await PiPullRequestReviewRouter(executor: executor).run(
      Self.input(job: job, prepared: prepared, artifactSHA256: artifactSHA256)
    )
  }

  public func reviewCanaryArchitecture(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) async throws -> PiWorkflowRoleResult {
    let context = PiJobWorkflowContext(
      artifact: prepared.artifact,
      workspaceRoot: prepared.workspaceURL,
      sessionRoot: sessionRoot,
      profiles: profiles,
      allowedWritePaths: [],
      offline: offline,
      timeoutSeconds: timeoutSeconds
    )
    let executor = executorFactory.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: context)
    )
    return try await PiPullRequestReviewRouter(executor: executor).runCanaryArchitecture(
      Self.input(job: job, prepared: prepared, artifactSHA256: artifactSHA256)
    )
  }

  private static func input(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) -> PiPullRequestReviewInput {
    PiPullRequestReviewInput(
      jobID: "job-\(job.id.uuidString.lowercased())",
      artifactSHA256: artifactSHA256,
      baseSHA: prepared.pullRequest.base.sha,
      restHeadSHA: prepared.pullRequest.head.sha,
      fetchedHeadSHA: prepared.fetched.headSHA,
      restCommitSHAs: prepared.restCommitSHAs,
      fetchedCommitSHAs: prepared.fetched.commitSHAs,
      commits: prepared.fetched.narrative
    )
  }
}

public actor PullRequestReviewJobWorkflow: JobWorkflowRunning {
  private let jobs: DurableJobStore
  private let configuration: ConfigurationStore
  private let intents: MutationIntentStore
  private let artifacts: ArtifactStore
  private let inputs: any PullRequestReviewJobPreparing
  private let reviewer: any PullRequestReviewExecuting
  private let markerPublisher: GitHubMarkerPublisher
  private let reviewedRevisions: ReviewedRevisionStore
  private let repositories: RepositoryStore
  private let authorID: Int64
  private let now: @Sendable () -> Date

  public init(
    jobs: DurableJobStore,
    configuration: ConfigurationStore,
    intents: MutationIntentStore,
    artifacts: ArtifactStore,
    inputs: any PullRequestReviewJobPreparing,
    reviewer: any PullRequestReviewExecuting,
    markerPublisher: GitHubMarkerPublisher,
    reviewedRevisions: ReviewedRevisionStore,
    repositories: RepositoryStore,
    authorID: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.jobs = jobs
    self.configuration = configuration
    self.intents = intents
    self.artifacts = artifacts
    self.inputs = inputs
    self.reviewer = reviewer
    self.markerPublisher = markerPublisher
    self.reviewedRevisions = reviewedRevisions
    self.repositories = repositories
    self.authorID = authorID
    self.now = now
  }

  public func run(jobID: UUID) async throws {
    guard let job = try await jobs.job(id: jobID), job.identity.kind == .prReview else {
      throw PullRequestReviewJobError.invalidJob
    }
    switch (job.state, job.currentStepKind) {
    case (.preparing, .review):
      try await runReview(job)
    case (.preparing, .publish):
      let executing = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "select-review-publication"),
          event: .selectLocalStep,
          context: JobTransitionContext(now: now(), reason: "review publication retry selected")
        )
      )
      try await publishReview(executing)
    case (.executing, .publish):
      try await publishReview(job)
    case (.reconciling, .publish):
      try await recoverPublication(job)
    case (.awaitingResolution, .publish):
      try await readBackLatePublication(job)
    case (.reconciling, .review):
      try await resumeCompletedReview(job)
    case (.reconciling, _), (.awaitingResolution, _):
      return
    default:
      throw PullRequestReviewJobError.unexpectedState(job.state)
    }
  }

  public func runRecoveredCanary(
    jobID: UUID,
    recoveryEvidenceSHA256: String
  ) async throws {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw PullRequestReviewJobError.invalidJob
    }
    let recovered = try await jobs.resumedCanaryTopologyRecoveryJob(
      jobID: jobID,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256
    )
    guard recovered.identity.kind == .prReview,
      [.preparing, .runningPi].contains(recovered.state),
      recovered.currentStep == 0,
      recovered.currentStepKind == .review
    else { throw PullRequestReviewJobError.unexpectedState(recovered.state) }
    let prepared = try await inputs.prepare(job: recovered)
    let inputArtifact = try await reusableInputArtifact(
      jobID: recovered.id,
      data: prepared.artifact
    )
    let selected = try await jobs.selectCanaryReviewAfterTopologyRecovery(
      jobID: recovered.id,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256,
      now: now()
    )
    try await completeReview(
      job: selected,
      prepared: prepared,
      inputArtifact: inputArtifact
    )
  }

  public func runCanaryPiFreshRetry(
    jobID: UUID,
    recoveryEvidenceSHA256: String,
    retryEvidenceSHA256: String
  ) async throws {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256),
      GitHubInputValidation.validSHA256(retryEvidenceSHA256)
    else {
      throw PullRequestReviewJobError.invalidJob
    }
    let state = try await jobs.canaryPiFreshRetryState(
      jobID: jobID,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256,
      authorizedRetryEvidenceSHA256: retryEvidenceSHA256
    )
    let prepared = try await inputs.prepare(job: state.job)
    let inputArtifact = try await reusableInputArtifact(
      jobID: state.job.id,
      data: prepared.artifact
    )
    try await completeReview(
      job: state.job,
      prepared: prepared,
      inputArtifact: inputArtifact
    )
  }

  public func runCanaryRoleHostReplacement(
    request: JobCanaryRoleHostReplacementRequest
  ) async throws {
    try request.validate()
    let state = try await jobs.canaryRoleHostReplacementState(request: request)
    let prepared = try await inputs.prepare(job: state.retry.job)
    let inputArtifact = try await requiredInputArtifact(
      jobID: state.retry.job.id,
      data: prepared.artifact
    )
    _ = try await reviewer.reviewCanaryArchitecture(
      job: state.retry.job,
      prepared: prepared,
      artifactSHA256: inputArtifact.sha256
    )
  }

  private func requiredInputArtifact(
    jobID: UUID,
    data: Data
  ) async throws -> ArtifactRecord {
    let digest = GitHubMarkerCodec.sha256(data)
    let matches = try await artifacts.records(jobID: jobID).filter {
      $0.kind == .input
        && $0.sha256 == digest
        && $0.classification == .sensitiveMetadata
        && $0.producerRunID == nil
    }
    guard matches.count == 1, let existing = matches.first,
      try await artifacts.read(id: existing.id) == data
    else { throw PullRequestReviewJobError.invalidArtifact }
    return existing
  }

  private func reusableInputArtifact(
    jobID: UUID,
    data: Data
  ) async throws -> ArtifactRecord {
    let digest = GitHubMarkerCodec.sha256(data)
    let matches = try await artifacts.records(jobID: jobID).filter {
      $0.kind == .input
        && $0.sha256 == digest
        && $0.classification == .sensitiveMetadata
        && $0.producerRunID == nil
    }
    if let existing = matches.last {
      guard try await artifacts.read(id: existing.id) == data else {
        throw PullRequestReviewJobError.invalidArtifact
      }
      return existing
    }
    return try await artifacts.write(
      jobID: jobID,
      kind: .input,
      data: data,
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: now()
    )
  }

  private func resumeCompletedReview(_ job: JobRecord) async throws {
    guard
      let step = try await jobs.completedStep(
        jobID: job.id,
        ordinal: job.currentStep
      ), step.kind == .review
    else {
      try await blockInterruptedReviewIfWorkspaceChanged(job)
      return
    }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "recover-completed-review"),
      event: .effectAttributedMore,
      context: JobTransitionContext(
        now: now(),
        reason: "durable review output completed before interruption",
        nextStep: .publish
      )
    )
    try await run(jobID: job.id)
  }

  private func blockInterruptedReviewIfWorkspaceChanged(_ job: JobRecord) async throws {
    guard try await repositories.workspaceRecord(jobID: job.id) != nil,
      !(try await repositories.workspaceIsCleanAtRecordedHead(jobID: job.id))
    else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "interrupted-review-workspace-changed"),
      event: .reconciliationPermanentFailure,
      context: JobTransitionContext(
        now: now(),
        reason: "interrupted review workspace changed before durable completion"
      )
    )
  }

  private func runReview(_ job: JobRecord) async throws {
    let prepared = try await inputs.prepare(job: job)
    let inputArtifact = try await artifacts.write(
      jobID: job.id,
      kind: .input,
      data: prepared.artifact,
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: now()
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "run-review"),
      event: .selectPiStep,
      context: JobTransitionContext(now: now(), reason: "validated PR inputs selected")
    )
    try await completeReview(
      job: job,
      prepared: prepared,
      inputArtifact: inputArtifact
    )
  }

  private func completeReview(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    inputArtifact: ArtifactRecord
  ) async throws {
    let output = try await reviewer.review(
      job: job,
      prepared: prepared,
      artifactSHA256: inputArtifact.sha256
    )
    let document = Self.reviewDocument(output)
    let reviewArtifact = try await artifacts.write(
      jobID: job.id,
      kind: .review,
      data: Data(document.utf8),
      classification: .public,
      producerRunID: nil,
      now: now()
    )
    try await appendStepIfNeeded(
      job: job,
      kind: .review,
      inputDigest: inputArtifact.sha256,
      outputDigest: reviewArtifact.sha256,
      mutationID: nil,
      acceptanceEvidence: "artifact:\(reviewArtifact.id.uuidString.lowercased())"
    )
    let completed = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "review-completed"),
      event: .piCompleted,
      context: JobTransitionContext(
        now: now(),
        reason: "one schema-valid settled PR review completed",
        nextStep: .publish
      )
    )
    try await publishReview(Self.job(completed))
  }

  private func publishReview(_ job: JobRecord) async throws {
    guard job.state == .executing, job.currentStepKind == .publish,
      let number = job.objectNumber
    else {
      throw PullRequestReviewJobError.unexpectedState(job.state)
    }
    let document = try await reviewDocument(jobID: job.id)
    let repository = try await repository(job)
    let generation = try await mutationGeneration(job)
    let request = reviewPublicationRequest(
      job: job,
      repository: repository,
      number: number,
      document: document,
      generation: generation
    )
    guard generation <= 1_024 else {
      throw PullRequestReviewJobError.invalidJob
    }
    let priorGenerations = Array(0..<generation)
    let publication: GitHubMarkerPublicationResult
    do {
      publication = try await markerPublisher.publishCheckingPriorGenerations(
        request,
        priorGenerations: priorGenerations
      )
    } catch {
      let pending = try await intents.intents(jobID: job.id).contains {
        [.sendStarted, .reconcileRequired].contains($0.state)
      }
      guard pending else { throw error }
      _ = try await transitionToReconciliation(job)
      publication = try await markerPublisher.publishCheckingPriorGenerations(
        request,
        priorGenerations: priorGenerations
      )
    }
    let reconciling = try await transitionToReconciliation(job)
    try await finalizePublication(
      job: reconciling,
      publication: publication,
      document: document
    )
  }

  private func readBackLatePublication(_ job: JobRecord) async throws {
    let document = try await reviewDocument(jobID: job.id)
    let repository = try await repository(job)
    let publication = try await markerPublisher.readBackLate(
      GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .createMarkerComment,
        repository: GitHubRepositoryCoordinates(
          owner: repository.owner,
          repository: repository.name
        ),
        repositoryNodeID: repository.nodeID,
        objectNodeID: job.identity.objectNodeID,
        number: try requiredObjectNumber(job),
        revision: job.identity.revisionKey,
        kind: .review,
        authorID: authorID,
        document: document,
        now: now(),
        generation: try await mutationGeneration(job)
      )
    )
    guard publication.disposition == .attributed else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "late-review-attributed"),
      event: .lateEffectAttributed,
      context: JobTransitionContext(now: now(), reason: "late review marker became exact")
    )
  }

  private func recoverPublication(_ job: JobRecord) async throws {
    guard job.currentStepKind == .publish else {
      throw PullRequestReviewJobError.unexpectedState(job.state)
    }
    let mutationIntents = try await intents.intents(jobID: job.id)
    guard !mutationIntents.isEmpty else {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "safe-resume"),
        event: .safeRetry,
        context: JobTransitionContext(
          now: now(),
          reason: "no publication send was durably started",
          notBefore: now().addingTimeInterval(1)
        )
      )
      return
    }
    let document = try await reviewDocument(jobID: job.id)
    let repository = try await repository(job)
    let publication = try await markerPublisher.publish(
      GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .createMarkerComment,
        repository: GitHubRepositoryCoordinates(
          owner: repository.owner,
          repository: repository.name
        ),
        repositoryNodeID: repository.nodeID,
        objectNodeID: job.identity.objectNodeID,
        number: try requiredObjectNumber(job),
        revision: job.identity.revisionKey,
        kind: .review,
        authorID: authorID,
        document: document,
        now: now(),
        generation: try await mutationGeneration(job)
      )
    )
    try await finalizePublication(job: job, publication: publication, document: document)
  }

  private func finalizePublication(
    job: JobRecord,
    publication: GitHubMarkerPublicationResult,
    document: String
  ) async throws {
    guard publication.disposition == .attributed else {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "publication-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "review marker was not attributable")
      )
      return
    }
    try await appendStepIfNeeded(
      job: job,
      kind: .publish,
      inputDigest: GitHubMarkerCodec.sha256(Data(document.utf8)),
      outputDigest: publication.documentSHA256,
      mutationID: publication.intentIDs.map(\.uuidString).joined(separator: ","),
      acceptanceEvidence: publication.comments.map { String($0.id) }.joined(separator: ",")
    )
    guard let comment = publication.comments.first else {
      throw PullRequestReviewJobError.commentAttributionMissing
    }
    let repository = try await repository(job)
    try await reviewedRevisions.record(
      ReviewedRevisionRecord(
        repositoryNodeID: repository.nodeID,
        pullRequestNodeID: job.identity.objectNodeID,
        headSHA: job.identity.revisionKey,
        reviewContractVersionUsed: job.contractVersionUsed,
        commentID: String(comment.id),
        commentURL: comment.htmlURL,
        commentDigest: publication.documentSHA256,
        createdAt: job.createdAt
      )
    )
    try await repositories.authorizeCleanup(jobID: job.id, now: now())
    try await repositories.cleanupWorkspace(jobID: job.id, now: now())
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "review-accepted"),
      event: .acceptanceComplete,
      context: JobTransitionContext(
        now: now(),
        reason: "review marker read-back, reviewed revision, and cleanup are exact",
        acceptanceEvidenceDigest: publication.evidenceDigest
      )
    )
  }

  private func transitionToReconciliation(_ job: JobRecord) async throws -> JobRecord {
    if let current = try await jobs.job(id: job.id), current.state == .reconciling {
      return current
    }
    return Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "publication-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "review marker send requires read-back")
      )
    )
  }

  private func reviewPublicationRequest(
    job: JobRecord,
    repository: RepositoryConfiguration,
    number: Int,
    document: String,
    generation: Int
  ) -> GitHubMarkerPublicationRequest {
    GitHubMarkerPublicationRequest(
      jobID: job.id,
      operation: .createMarkerComment,
      repository: GitHubRepositoryCoordinates(
        owner: repository.owner,
        repository: repository.name
      ),
      repositoryNodeID: repository.nodeID,
      objectNodeID: job.identity.objectNodeID,
      number: number,
      revision: job.identity.revisionKey,
      kind: .review,
      authorID: authorID,
      document: document,
      now: now(),
      generation: generation
    )
  }

  private func mutationGeneration(_ job: JobRecord) async throws -> Int {
    try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
  }

  private func repository(_ job: JobRecord) async throws -> RepositoryConfiguration {
    guard
      let repository = try await configuration.repository(
        id: job.identity.repositoryID
      )
    else {
      throw PullRequestReviewJobError.repositoryDisabled
    }
    return repository
  }

  private func requiredObjectNumber(_ job: JobRecord) throws -> Int {
    guard let number = job.objectNumber, number > 0 else {
      throw PullRequestReviewJobError.invalidJob
    }
    return number
  }

  private func reviewDocument(jobID: UUID) async throws -> String {
    let records = try await artifacts.records(jobID: jobID).filter { $0.kind == .review }
    guard let record = records.last,
      let value = String(data: try await artifacts.read(id: record.id), encoding: .utf8)
    else {
      throw PullRequestReviewJobError.invalidArtifact
    }
    return value
  }

  private func appendStepIfNeeded(
    job: JobRecord,
    kind: JobStepKind,
    inputDigest: String?,
    outputDigest: String?,
    mutationID: String?,
    acceptanceEvidence: String?
  ) async throws {
    try await jobs.appendCompletedStep(
      jobID: job.id,
      ordinal: job.currentStep,
      kind: kind,
      inputDigest: inputDigest,
      outputDigest: outputDigest,
      mutationID: mutationID,
      acceptanceEvidence: acceptanceEvidence,
      now: now()
    )
  }

  private func eventKey(_ job: JobRecord, _ suffix: String) -> String {
    "pr:\(job.id.uuidString.lowercased()):a\(job.attempt):s\(job.currentStep):\(suffix)"
  }

  private static func reviewDocument(_ output: PiPullRequestReviewOutput) -> String {
    var lines = [
      "# Jidoka Code pull request review",
      "",
      "Verdict: \(output.effectiveVerdict)",
      "Severity: \(output.effectiveSeverity.rawValue)",
      "Commit narrative SHA-256: \(output.commitNarrativeSHA256)",
      "",
      output.synthesis.summary,
    ]
    if !output.synthesis.findings.isEmpty {
      lines += ["", "## Findings"]
      for finding in output.synthesis.findings {
        lines.append(
          "- [\(finding.severity.rawValue)] \(finding.path):\(finding.line), \(finding.evidence) Recommendation: \(finding.recommendation)"
        )
      }
    }
    if !output.synthesis.evidence.isEmpty {
      lines += ["", "## Evidence"]
      lines += output.synthesis.evidence.map { "- \($0)" }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func job(_ result: JobTransitionResult) -> JobRecord {
    switch result {
    case .applied(let job), .duplicate(let job): job
    }
  }
}
