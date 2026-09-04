import Foundation

public struct PreparedIssueTriageJob: Sendable {
  public let repository: RepositoryConfiguration
  public let issue: GitHubIssue
  public let comments: [GitHubComment]
  public let labels: [GitHubLabel]
  public let issueRevision: IssueRevision
  public let baseRevision: BaseRevision
  public let workspaceURL: URL
  public let artifact: Data

  public init(
    repository: RepositoryConfiguration,
    issue: GitHubIssue,
    comments: [GitHubComment],
    labels: [GitHubLabel],
    issueRevision: IssueRevision,
    baseRevision: BaseRevision,
    workspaceURL: URL,
    artifact: Data
  ) {
    self.repository = repository
    self.issue = issue
    self.comments = comments
    self.labels = labels
    self.issueRevision = issueRevision
    self.baseRevision = baseRevision
    self.workspaceURL = workspaceURL
    self.artifact = artifact
  }
}

public enum IssueTriageJobError: Error, Equatable, Sendable {
  case invalidJob
  case repositoryDisabled
  case remoteIdentityMismatch
  case workflowLabelPresent
  case invalidArtifact
  case unexpectedState(JobState)
  case unsupportedVerdict(String)
  case publicationEscalated
}

public protocol IssueTriageJobPreparing: Sendable {
  func prepare(job: JobRecord) async throws -> PreparedIssueTriageJob
}

public struct SystemIssueTriageJobPreparer: IssueTriageJobPreparing, Sendable {
  private let configuration: ConfigurationStore
  private let api: any GitHubMutationReadAPI
  private let repositories: RepositoryStore
  private let revisionDeriver: DurableIssueRevisionDeriver
  private let remoteResolver: any GitRemoteRepositoryResolving
  private let credentials: (any GitCredentialSessionProviding)?

  public init(
    configuration: ConfigurationStore,
    api: any GitHubMutationReadAPI,
    repositories: RepositoryStore,
    intents: MutationIntentStore,
    appAuthorID: Int64,
    linkedInputs: any IssueLinkedInputResolving = NoIssueLinkedInputResolver(),
    remoteResolver: any GitRemoteRepositoryResolving = GitHubRemoteRepositoryResolver(),
    credentials: (any GitCredentialSessionProviding)? = nil
  ) {
    self.configuration = configuration
    self.api = api
    self.repositories = repositories
    revisionDeriver = DurableIssueRevisionDeriver(
      intents: intents,
      appAuthorID: appAuthorID,
      linkedInputs: linkedInputs
    )
    self.remoteResolver = remoteResolver
    self.credentials = credentials
  }

  public func prepare(job: JobRecord) async throws -> PreparedIssueTriageJob {
    guard job.identity.kind == .issueTriage, let number = job.objectNumber, number > 0,
      job.identity.revisionKey == "initial-triage"
    else {
      throw IssueTriageJobError.invalidJob
    }
    guard let repository = try await configuration.repository(id: job.identity.repositoryID),
      repository.enabled,
      repository.triageEnabled
    else {
      throw IssueTriageJobError.repositoryDisabled
    }
    async let issueRead = api.issue(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let commentsRead = api.listComments(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let labelsRead = api.listIssueLabels(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let referenceRead = api.branchReference(
      owner: repository.owner,
      repository: repository.name,
      branch: repository.defaultBranch
    )
    let issue = try await issueRead
    let comments = try await commentsRead
    let labels = try await labelsRead
    guard let reference = try await referenceRead else {
      throw IssueTriageJobError.remoteIdentityMismatch
    }
    guard issue.nodeID == job.identity.objectNodeID,
      issue.number == number,
      issue.state == "open",
      !issue.isPullRequest,
      reference.ref == "refs/heads/\(repository.defaultBranch)",
      GitHubInputValidation.validGitSHA(reference.object.sha)
    else {
      throw IssueTriageJobError.remoteIdentityMismatch
    }
    let workflowLabels = labels.map(\.name).filter(Self.isWorkflowLabel)
      .map { $0.lowercased() }
    guard workflowLabels.isEmpty else {
      throw IssueTriageJobError.workflowLabelPresent
    }
    let issueRevision = try await revisionDeriver.derive(
      repositoryNodeID: repository.nodeID,
      issue: issue,
      comments: comments,
      labels: labels
    )
    let baseRevision = try BaseRevision(
      branch: repository.defaultBranch,
      sha: reference.object.sha
    )
    let remote = try remoteResolver.remote(for: repository)
    let mirror = try await repositories.ensureMirror(
      remote: remote,
      credentials: credentials
    )
    let materialization = try await repositories.materializeSnapshotWorkspace(
      jobID: job.id,
      remote: remote,
      exactSHA: reference.object.sha,
      mirrorURL: mirror,
      credentials: credentials,
      now: job.updatedAt
    )
    let artifact = try Self.artifact(
      repository: repository,
      issue: issue,
      comments: comments,
      labels: labels,
      issueRevision: issueRevision,
      baseRevision: baseRevision
    )
    return PreparedIssueTriageJob(
      repository: repository,
      issue: issue,
      comments: comments,
      labels: labels,
      issueRevision: issueRevision,
      baseRevision: baseRevision,
      workspaceURL: materialization.workspaceURL,
      artifact: artifact
    )
  }

  static func artifact(
    repository: RepositoryConfiguration,
    issue: GitHubIssue,
    comments: [GitHubComment],
    labels: [GitHubLabel],
    issueRevision: IssueRevision,
    baseRevision: BaseRevision
  ) throws -> Data {
    let object: [String: Any] = [
      "baseRevision": [
        "branch": baseRevision.branch,
        "digest": baseRevision.sha256,
        "sha": baseRevision.sha,
      ],
      "comments": comments.filter { !issueRevision.excludedCommentIDs.contains($0.id) }.map {
        [
          "authorID": $0.user.nodeID,
          "body": $0.body,
          "createdAt": $0.createdAt,
          "id": $0.id,
          "updatedAt": $0.updatedAt,
        ] as [String: Any]
      },
      "issue": [
        "authorID": issue.user.nodeID,
        "body": issue.body ?? "",
        "createdAt": issue.createdAt,
        "domainLabels": labels.map(\.name).filter { !isWorkflowLabel($0) }.sorted(),
        "nodeID": issue.nodeID,
        "number": issue.number,
        "title": issue.title,
      ],
      "issueRevisionSHA256": issueRevision.sha256,
      "repository": [
        "name": repository.name,
        "nodeID": repository.nodeID,
        "owner": repository.owner,
      ],
      "schemaVersion": 1,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw IssueTriageJobError.invalidArtifact
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func isWorkflowLabel(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
  }
}

public protocol IssueTriageExecuting: Sendable {
  func triage(
    job: JobRecord,
    prepared: PreparedIssueTriageJob,
    artifactSHA256: String
  ) async throws -> PiIssueTriageOutput
}

public struct PiIssueTriageJobExecutor: IssueTriageExecuting, Sendable {
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

  public func triage(
    job: JobRecord,
    prepared: PreparedIssueTriageJob,
    artifactSHA256: String
  ) async throws -> PiIssueTriageOutput {
    let executor = executorFactory.makeExecutor(
      preparer: PiJobWorkflowPreparer(
        context: PiJobWorkflowContext(
          artifact: prepared.artifact,
          workspaceRoot: prepared.workspaceURL,
          sessionRoot: sessionRoot,
          profiles: profiles,
          allowedWritePaths: [],
          offline: offline,
          timeoutSeconds: timeoutSeconds
        )
      )
    )
    return try await PiIssueTriageRouter(executor: executor).run(
      PiIssueTriageInput(
        jobID: "job-\(job.id.uuidString.lowercased())",
        artifactSHA256: artifactSHA256
      )
    )
  }
}

public actor IssueTriageJobWorkflow: JobWorkflowRunning {
  private let jobs: DurableJobStore
  private let configuration: ConfigurationStore
  private let artifacts: ArtifactStore
  private let inputs: any IssueTriageJobPreparing
  private let triage: any IssueTriageExecuting
  private let markerPublisher: GitHubMarkerPublisher
  private let labelBootstrapper: GitHubWorkflowLabelBootstrapper
  private let labelMutator: GitHubWorkflowLabelMutator
  private let repositories: RepositoryStore
  private let rolloutSnapshots: (any RolloutJobInputSnapshotRecording)?
  private let authorID: Int64
  private let now: @Sendable () -> Date
  private let afterStepPersisted: @Sendable (JobStepKind) async throws -> Void
  private let beforeInputsInvalidated: @Sendable () async throws -> Void

  public init(
    jobs: DurableJobStore,
    configuration: ConfigurationStore,
    artifacts: ArtifactStore,
    inputs: any IssueTriageJobPreparing,
    triage: any IssueTriageExecuting,
    markerPublisher: GitHubMarkerPublisher,
    labelBootstrapper: GitHubWorkflowLabelBootstrapper,
    labelMutator: GitHubWorkflowLabelMutator,
    repositories: RepositoryStore,
    rolloutSnapshots: (any RolloutJobInputSnapshotRecording)? = nil,
    authorID: Int64,
    now: @escaping @Sendable () -> Date = Date.init,
    afterStepPersisted: @escaping @Sendable (JobStepKind) async throws -> Void = { _ in },
    beforeInputsInvalidated: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.jobs = jobs
    self.configuration = configuration
    self.artifacts = artifacts
    self.inputs = inputs
    self.triage = triage
    self.markerPublisher = markerPublisher
    self.labelBootstrapper = labelBootstrapper
    self.labelMutator = labelMutator
    self.repositories = repositories
    self.rolloutSnapshots = rolloutSnapshots
    self.authorID = authorID
    self.now = now
    self.afterStepPersisted = afterStepPersisted
    self.beforeInputsInvalidated = beforeInputsInvalidated
  }

  public func run(jobID: UUID) async throws {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
    ) {
      try await self.runAuthorized(jobID: jobID)
    }
  }

  private func runAuthorized(jobID: UUID) async throws {
    guard let job = try await jobs.job(id: jobID), job.identity.kind == .issueTriage else {
      throw IssueTriageJobError.invalidJob
    }
    switch (job.state, job.currentStepKind) {
    case (.preparing, .triage):
      try await runTriage(job)
    case (.preparing, .publish):
      let executing = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "select-marker-publication"),
          event: .selectLocalStep,
          context: JobTransitionContext(now: now(), reason: "triage marker retry selected")
        )
      )
      try await publishMarker(executing)
    case (.executing, .publish):
      try await publishMarker(job)
    case (.preparing, .reconcile):
      try await runLabelMutation(job)
    case (.executing, .reconcile):
      try await mutateLabel(job)
    case (.awaitingResolution, .publish):
      try await readBackLateMarker(job)
    case (.reconciling, _):
      try await resumeCompletedTriage(job)
    case (.awaitingResolution, _):
      return
    default:
      throw IssueTriageJobError.unexpectedState(job.state)
    }
  }

  private func resumeCompletedTriage(_ job: JobRecord) async throws {
    guard let kind = job.currentStepKind,
      let step = try await jobs.completedStep(jobID: job.id, ordinal: job.currentStep),
      step.kind == kind
    else {
      if job.currentStepKind == .triage {
        try await blockInterruptedTriageIfWorkspaceChanged(job)
      } else if let kind = job.currentStepKind,
        [.publish, .reconcile].contains(kind)
      {
        let fresh = try await inputs.prepare(job: job)
        _ = try await restartIfInputsChanged(job, fresh: fresh)
      }
      return
    }
    switch kind {
    case .triage, .publish:
      let next: JobStepKind = kind == .triage ? .publish : .reconcile
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-completed-\(kind.rawValue)"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "durable \(kind.rawValue) step completed before interruption",
          nextStep: next
        )
      )
      try await run(jobID: job.id)
    case .reconcile:
      try await repositories.authorizeCleanup(jobID: job.id, now: now())
      try await repositories.cleanupWorkspace(jobID: job.id, now: now())
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-completed-reconcile"),
        event: .acceptanceComplete,
        context: JobTransitionContext(
          now: now(),
          reason: "durable triage reconciliation and cleanup completed",
          acceptanceEvidenceDigest: step.outputDigest
        )
      )
    default:
      return
    }
  }

  private func blockInterruptedTriageIfWorkspaceChanged(_ job: JobRecord) async throws {
    guard try await repositories.workspaceRecord(jobID: job.id) != nil,
      !(try await repositories.workspaceIsCleanAtRecordedHead(jobID: job.id))
    else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "interrupted-triage-workspace-changed"),
      event: .reconciliationPermanentFailure,
      context: JobTransitionContext(
        now: now(),
        reason: "interrupted triage workspace changed before durable completion"
      )
    )
  }

  private func readBackLateMarker(_ job: JobRecord) async throws {
    let repository = try await requiredRepository(job)
    let publication = try await markerPublisher.readBackLate(
      GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .createMarkerComment,
        repositoryID: repository.id,
        repository: GitHubRepositoryCoordinates(
          owner: repository.owner,
          repository: repository.name
        ),
        repositoryNodeID: repository.nodeID,
        objectNodeID: job.identity.objectNodeID,
        number: try requiredNumber(job),
        revision: try await originalIssueRevision(jobID: job.id),
        kind: .triage,
        authorID: authorID,
        document: try await triageDocument(jobID: job.id),
        now: now(),
        generation: try await mutationGeneration(job)
      )
    )
    guard publication.disposition == .attributed else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "late-triage-attributed"),
      event: .lateEffectAttributed,
      context: JobTransitionContext(now: now(), reason: "late triage marker became exact")
    )
  }

  private func runTriage(_ job: JobRecord) async throws {
    let prepared = try await inputs.prepare(job: job)
    if let rolloutSnapshots {
      try await rolloutSnapshots.freezeJobInputSnapshot(
        RolloutJobInputSnapshot(
          jobID: job.id,
          canonicalInputSHA256: GitHubMarkerCodec.sha256(prepared.artifact),
          baseSHA: prepared.baseRevision.sha,
          labelStateSHA256: try RolloutPreviewBuilder.labelStateSHA256(prepared.labels)
        ),
        now: now()
      )
    }
    let bootstrap = try await labelBootstrapper.bootstrap(
      jobID: job.id,
      repository: GitHubRepositoryCoordinates(
        owner: prepared.repository.owner,
        repository: prepared.repository.name
      ),
      at: now()
    )
    guard bootstrap.disposition == .ready else {
      throw IssueTriageJobError.repositoryDisabled
    }
    let input = try await artifacts.write(
      jobID: job.id,
      kind: .input,
      data: prepared.artifact,
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: now()
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "run-triage"),
      event: .selectPiStep,
      context: JobTransitionContext(now: now(), reason: "validated issue inputs selected")
    )
    let output = try await triage.triage(
      job: job,
      prepared: prepared,
      artifactSHA256: input.sha256
    )
    let document = Self.triageDocument(output)
    let result = try await artifacts.write(
      jobID: job.id,
      kind: .review,
      data: Data(document.utf8),
      classification: .public,
      producerRunID: nil,
      now: now()
    )
    try await appendStep(
      job: job,
      kind: .triage,
      inputDigest: input.sha256,
      outputDigest: result.sha256,
      mutationID: nil,
      evidence: "artifact:\(result.id.uuidString.lowercased())"
    )
    let completed = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "triage-completed"),
        event: .piCompleted,
        context: JobTransitionContext(
          now: now(),
          reason: "one schema-valid settled triage result completed",
          nextStep: .publish
        )
      )
    )
    try await publishMarker(completed)
  }

  private func publishMarker(_ job: JobRecord) async throws {
    let repository = try await requiredRepository(job)
    let number = try requiredNumber(job)
    let document = try await triageDocument(jobID: job.id)
    let generation = try await mutationGeneration(job)
    guard generation <= 1_024 else { throw IssueTriageJobError.invalidJob }
    let priorGenerations = Array(0..<generation)
    let prior: GitHubMarkerPublicationResult?
    if generation > 0 {
      let priorTemplate = triagePublicationRequest(
        job: job,
        repository: repository,
        number: number,
        revision: try await originalIssueRevision(jobID: job.id),
        document: document,
        generation: generation
      )
      prior = try await markerPublisher.readBackFirstAttributed(
        priorTemplate,
        priorGenerations: priorGenerations
      )
    } else {
      prior = nil
    }
    let prepared = try await inputs.prepare(job: job)
    if try await restartIfInputsChanged(job, fresh: prepared) { return }
    let request = triagePublicationRequest(
      job: job,
      repository: repository,
      number: number,
      revision: prepared.issueRevision.sha256,
      document: document,
      generation: generation
    )
    let publication: GitHubMarkerPublicationResult
    if let prior {
      publication = prior
    } else {
      publication = try await markerPublisher.publishCheckingPriorGenerations(
        request,
        priorGenerations: priorGenerations
      )
    }
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "marker-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "triage marker requires read-back")
      )
    )
    guard publication.disposition == .attributed else {
      _ = try await jobs.transition(
        jobID: reconciling.id,
        eventKey: eventKey(reconciling, "marker-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "triage marker was not attributable")
      )
      return
    }
    try await appendStep(
      job: reconciling,
      kind: .publish,
      inputDigest: GitHubMarkerCodec.sha256(Data(document.utf8)),
      outputDigest: publication.documentSHA256,
      mutationID: publication.intentIDs.map(\.uuidString).joined(separator: ","),
      evidence: publication.comments.map { String($0.id) }.joined(separator: ",")
    )
    let next = Self.job(
      try await jobs.transition(
        jobID: reconciling.id,
        eventKey: eventKey(reconciling, "marker-attributed"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "triage marker exact read-back completed",
          nextStep: .reconcile
        )
      )
    )
    try await runLabelMutation(next)
  }

  private func runLabelMutation(_ job: JobRecord) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-label-mutation"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "verdict label selected")
      )
    )
    try await mutateLabel(executing)
  }

  private func mutateLabel(_ job: JobRecord) async throws {
    let fresh = try await inputs.prepare(job: job)
    if try await restartIfInputsChanged(job, fresh: fresh) { return }
    let verdict = try await verdict(jobID: job.id)
    let desired = try Self.label(for: verdict)
    let repository = try await requiredRepository(job)
    let mutation = try await labelMutator.mutate(
      GitHubWorkflowLabelMutationRequest(
        jobID: job.id,
        operation: .mutateWorkflowLabels,
        repository: GitHubRepositoryCoordinates(
          owner: repository.owner,
          repository: repository.name
        ),
        number: try requiredNumber(job),
        expected: [],
        desired: [desired],
        generation: 0,
        now: now()
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "label-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "verdict label requires read-back")
      )
    )
    switch mutation.disposition {
    case .retryAllowed:
      _ = try await jobs.transition(
        jobID: reconciling.id,
        eventKey: eventKey(reconciling, "label-retry"),
        event: .safeRetry,
        context: JobTransitionContext(
          now: now(),
          reason: "verdict label mutation is safely retryable",
          notBefore: now().addingTimeInterval(60)
        )
      )
      return
    case .escalated:
      _ = try await jobs.transition(
        jobID: reconciling.id,
        eventKey: eventKey(reconciling, "label-blocked"),
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(now: now(), reason: "verdict label conflicted")
      )
      return
    case .attributed:
      break
    }
    try await appendStep(
      job: reconciling,
      kind: .reconcile,
      inputDigest: GitHubMarkerCodec.sha256(Data(verdict.utf8)),
      outputDigest: mutation.evidenceDigest,
      mutationID: mutation.intentIDs.map(\.uuidString).joined(separator: ","),
      evidence: desired
    )
    try await repositories.authorizeCleanup(jobID: job.id, now: now())
    try await repositories.cleanupWorkspace(jobID: job.id, now: now())
    _ = try await jobs.transition(
      jobID: reconciling.id,
      eventKey: eventKey(reconciling, "triage-accepted"),
      event: .acceptanceComplete,
      context: JobTransitionContext(
        now: now(),
        reason: "triage marker, verdict label, and cleanup are exact",
        acceptanceEvidenceDigest: mutation.evidenceDigest
      )
    )
  }

  private func restartIfInputsChanged(
    _ job: JobRecord,
    fresh: PreparedIssueTriageJob
  ) async throws -> Bool {
    guard
      let original = try await artifacts.records(jobID: job.id)
        .last(where: { $0.kind == .input })
    else {
      throw IssueTriageJobError.invalidArtifact
    }
    let freshDigest = GitHubMarkerCodec.sha256(fresh.artifact)
    guard original.sha256 != freshDigest else { return false }
    try await beforeInputsInvalidated()
    let preparing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "inputs-changed"),
        event: .inputsInvalidated,
        context: JobTransitionContext(
          now: now(),
          reason: "issue or base revision changed before mutation"
        )
      )
    )
    try await runTriage(preparing)
    return true
  }

  private func appendStep(
    job: JobRecord,
    kind: JobStepKind,
    inputDigest: String?,
    outputDigest: String?,
    mutationID: String?,
    evidence: String?
  ) async throws {
    try await jobs.appendCompletedStep(
      jobID: job.id,
      ordinal: job.currentStep,
      kind: kind,
      inputDigest: inputDigest,
      outputDigest: outputDigest,
      mutationID: mutationID,
      acceptanceEvidence: evidence,
      now: now()
    )
    try await afterStepPersisted(kind)
  }

  private func triagePublicationRequest(
    job: JobRecord,
    repository: RepositoryConfiguration,
    number: Int,
    revision: String,
    document: String,
    generation: Int
  ) -> GitHubMarkerPublicationRequest {
    GitHubMarkerPublicationRequest(
      jobID: job.id,
      operation: .createMarkerComment,
      repositoryID: repository.id,
      repository: GitHubRepositoryCoordinates(
        owner: repository.owner,
        repository: repository.name
      ),
      repositoryNodeID: repository.nodeID,
      objectNodeID: job.identity.objectNodeID,
      number: number,
      revision: revision,
      kind: .triage,
      authorID: authorID,
      document: document,
      now: now(),
      generation: generation
    )
  }

  private func mutationGeneration(_ job: JobRecord) async throws -> Int {
    try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
  }

  private func requiredRepository(_ job: JobRecord) async throws -> RepositoryConfiguration {
    guard let repository = try await configuration.repository(id: job.identity.repositoryID) else {
      throw IssueTriageJobError.repositoryDisabled
    }
    return repository
  }

  private func requiredNumber(_ job: JobRecord) throws -> Int {
    guard let number = job.objectNumber, number > 0 else {
      throw IssueTriageJobError.invalidJob
    }
    return number
  }

  private func originalIssueRevision(jobID: UUID) async throws -> String {
    guard
      let record = try await artifacts.records(jobID: jobID)
        .last(where: { $0.kind == .input })
    else {
      throw IssueTriageJobError.invalidArtifact
    }
    let data = try await artifacts.read(id: record.id)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = object["issueRevisionSHA256"] as? String,
      GitHubInputValidation.validSHA256(value)
    else {
      throw IssueTriageJobError.invalidArtifact
    }
    return value
  }

  private func triageDocument(jobID: UUID) async throws -> String {
    let records = try await artifacts.records(jobID: jobID).filter { $0.kind == .review }
    guard let record = records.last,
      let value = String(data: try await artifacts.read(id: record.id), encoding: .utf8)
    else {
      throw IssueTriageJobError.invalidArtifact
    }
    return value
  }

  private func verdict(jobID: UUID) async throws -> String {
    let document = try await triageDocument(jobID: jobID)
    guard let line = document.split(separator: "\n").first(where: { $0.hasPrefix("Verdict: ") })
    else {
      throw IssueTriageJobError.invalidArtifact
    }
    return String(line.dropFirst("Verdict: ".count))
  }

  private func eventKey(_ job: JobRecord, _ suffix: String) -> String {
    "triage:\(job.id.uuidString.lowercased()):a\(job.attempt):s\(job.currentStep):\(suffix)"
  }

  private static func triageDocument(_ output: PiIssueTriageOutput) -> String {
    let payload = output.result
    var lines = [
      "# Jidoka Code issue triage",
      "",
      "Verdict: \(output.effectiveVerdict)",
      "Severity: \(payload.severity.rawValue)",
      "Complexity guess: \(payload.complexityGuess.rawValue)",
      "",
      payload.summary,
      "",
      "## Rationale",
      payload.rationale,
      "",
      "## Rubric",
      "- Specified: \(payload.rubric.specified)",
      "- Testable: \(payload.rubric.testable)",
      "- Bounded: \(payload.rubric.bounded)",
      "- Safe: \(payload.rubric.safe)",
    ]
    if !payload.questions.isEmpty {
      lines += ["", "## Questions"]
      lines += payload.questions.map { "- \($0)" }
    }
    if !payload.hardRiskFlags.isEmpty {
      lines += ["", "## Hard risks"]
      lines += payload.hardRiskFlags.map { "- \($0.rawValue)" }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func label(for verdict: String) throws -> String {
    switch verdict {
    case "ready": "agent:ready"
    case "needs-spec": "agent:needs-spec"
    case "human": "agent:human"
    default: throw IssueTriageJobError.unsupportedVerdict(verdict)
    }
  }

  private static func job(_ result: JobTransitionResult) -> JobRecord {
    switch result {
    case .applied(let job), .duplicate(let job): job
    }
  }
}
