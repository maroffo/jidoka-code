import Foundation

public enum IssueImplementationJobError: Error, Equatable, Sendable {
  case invalidJob
  case repositoryDisabled
  case unexpectedState(JobState, JobStepKind?)
  case staleIssueRevision
  case staleBaseRevision
  case workflowLabelMismatch
  case planMissing
  case planningBlocked
  case executionBlocked
  case publicationEscalated
  case publicationEvidenceMissing
  case pullRequestMissing
  case claimMissing
  case invalidArtifact
}

public actor IssueImplementationJobWorkflow: JobWorkflowRunning,
  IssueImplementationApprovalEvaluating
{
  private let jobs: DurableJobStore
  private let configuration: ConfigurationStore
  private let artifacts: ArtifactStore
  private let repositories: RepositoryStore
  private let inputs: any IssueImplementationJobPreparing
  private let planner: any IssueImplementationPlanning
  private let orchestrator: any IssueImplementationOrchestrating
  private let markerPublisher: GitHubMarkerPublisher
  private let labelBootstrapper: GitHubWorkflowLabelBootstrapper
  private let labelMutator: GitHubWorkflowLabelMutator
  private let branchPublisher: DurableGitPublisher
  private let pullRequestPublisher: GitHubPullRequestPublisher
  private let credentials: (any GitCredentialSessionProviding)?
  private let rolloutSnapshots: (any RolloutJobInputSnapshotRecording)?
  private let authorID: Int64
  private let contractVersion: String
  private let now: @Sendable () -> Date
  private let afterStepPersisted: @Sendable (JobStepKind) async throws -> Void
  private let afterOrchestrationEvidencePersisted: @Sendable () async throws -> Void

  public init(
    jobs: DurableJobStore,
    configuration: ConfigurationStore,
    artifacts: ArtifactStore,
    repositories: RepositoryStore,
    inputs: any IssueImplementationJobPreparing,
    planner: any IssueImplementationPlanning,
    orchestrator: any IssueImplementationOrchestrating,
    markerPublisher: GitHubMarkerPublisher,
    labelBootstrapper: GitHubWorkflowLabelBootstrapper,
    labelMutator: GitHubWorkflowLabelMutator,
    branchPublisher: DurableGitPublisher,
    pullRequestPublisher: GitHubPullRequestPublisher,
    credentials: (any GitCredentialSessionProviding)? = nil,
    rolloutSnapshots: (any RolloutJobInputSnapshotRecording)? = nil,
    authorID: Int64,
    contractVersion: String,
    now: @escaping @Sendable () -> Date = Date.init,
    afterStepPersisted: @escaping @Sendable (JobStepKind) async throws -> Void = { _ in },
    afterOrchestrationEvidencePersisted: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.jobs = jobs
    self.configuration = configuration
    self.artifacts = artifacts
    self.repositories = repositories
    self.inputs = inputs
    self.planner = planner
    self.orchestrator = orchestrator
    self.markerPublisher = markerPublisher
    self.labelBootstrapper = labelBootstrapper
    self.labelMutator = labelMutator
    self.branchPublisher = branchPublisher
    self.pullRequestPublisher = pullRequestPublisher
    self.credentials = credentials
    self.rolloutSnapshots = rolloutSnapshots
    self.authorID = authorID
    self.contractVersion = contractVersion
    self.now = now
    self.afterStepPersisted = afterStepPersisted
    self.afterOrchestrationEvidencePersisted = afterOrchestrationEvidencePersisted
  }

  public func run(jobID: UUID) async throws {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
    ) {
      try await self.runAuthorized(jobID: jobID)
    }
  }

  private func runAuthorized(jobID: UUID) async throws {
    guard let job = try await jobs.job(id: jobID), job.identity.kind == .issueImplementation else {
      throw IssueImplementationJobError.invalidJob
    }
    switch (job.state, job.currentStepKind) {
    case (.preparing, .claimReady), (.preparing, .claimApprovedPlan):
      try await startClaim(job)
    case (.executing, .claimReady), (.executing, .claimApprovedPlan):
      try await executeClaim(job)
    case (.preparing, .plan), (.preparing, .replan):
      try await runPlanning(job)
    case (.preparing, .publishPlan):
      try await startRecoveredLocalStep(job, action: publishPlan)
    case (.executing, .publishPlan):
      try await publishPlan(job)
    case (.preparing, .orchestrate):
      try await runOrchestration(job)
    case (.preparing, .push):
      try await startRecoveredLocalStep(job, action: publishBranch)
    case (.executing, .push):
      try await publishBranch(job)
    case (.preparing, .openPullRequest):
      try await startPullRequestPublication(job)
    case (.executing, .openPullRequest):
      try await publishPullRequest(job)
    case (.preparing, .linkPullRequest):
      try await startRecoveredLocalStep(job, action: publishIssueLink)
    case (.executing, .linkPullRequest):
      try await publishIssueLink(job)
    case (.preparing, .qa):
      try await startQA(job)
    case (.executing, .qa):
      try await publishQA(job)
    case (.reconciling, _):
      try await resumeCompletedStep(job)
    case (.preparing, .consumeStaleApproval):
      try await startConsumeStaleApproval(job)
    case (.executing, .consumeStaleApproval):
      try await consumeStaleApproval(job)
    case (.preparing, .publish):
      try await startRecoveredLocalStep(job, action: publishBlocked)
    case (.executing, .publish):
      try await publishBlocked(job)
    case (.awaitingResolution, _):
      try await readBackLateEffect(job)
    case (.waitingHuman, _), (.reconciliationQueued, _):
      return
    default:
      throw IssueImplementationJobError.unexpectedState(job.state, job.currentStepKind)
    }
  }

  @discardableResult
  public func evaluateWaitingApproval(jobID: UUID) async throws -> JobRecord {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
    ) {
      try await self.evaluateWaitingApprovalAuthorized(jobID: jobID)
    }
  }

  private func evaluateWaitingApprovalAuthorized(jobID: UUID) async throws -> JobRecord {
    guard let job = try await jobs.job(id: jobID),
      job.identity.kind == .issueImplementation,
      job.state == .waitingHuman
    else {
      throw IssueImplementationJobError.invalidJob
    }
    let prepared = try await inputs.prepare(job: job)
    let envelope = try await planEnvelope(jobID: job.id)
    guard prepared.workflowLabels == ["agent:plan-review", "plan:approved"] else {
      throw IssueImplementationJobError.workflowLabelMismatch
    }
    let fresh =
      prepared.issueRevision.sha256 == envelope.issueRevisionSHA256
      && prepared.baseRevision == envelope.baseRevision
    return Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, fresh ? "approval-fresh" : "approval-stale"),
        event: fresh ? .approvalFresh : .approvalStale,
        context: JobTransitionContext(
          now: now(),
          reason: fresh
            ? "plan approval matches exact issue and base revisions"
            : "plan approval is stale against issue or base revision"
        )
      )
    )
  }

  private func resumeCompletedStep(_ job: JobRecord) async throws {
    guard let kind = job.currentStepKind,
      let step = try await jobs.completedStep(jobID: job.id, ordinal: job.currentStep),
      step.kind == kind
    else {
      if job.currentStepKind == .orchestrate,
        try await recoverInterruptedOrchestration(job)
      {
        return
      }
      if let kind = job.currentStepKind,
        [.plan, .replan, .orchestrate].contains(kind)
      {
        try await blockInterruptedPiIfWorkspaceChanged(job)
      }
      return
    }
    switch kind {
    case .claimReady, .claimApprovedPlan:
      let next: JobStepKind = kind == .claimApprovedPlan ? .orchestrate : .plan
      _ = try await advanceRecovered(
        job,
        nextStep: next,
        reason: "durable \(kind.rawValue) claim completed before interruption"
      )
      try await run(jobID: job.id)
    case .plan, .replan:
      try await resumeCompletedPlanning(job, step: step)
    case .writePlan:
      let preparing = try await advanceRecovered(
        job,
        nextStep: .orchestrate,
        reason: "frozen plan step completed before interruption"
      )
      _ = try await jobs.transition(
        jobID: preparing.id,
        eventKey: eventKey(preparing, "recover-plan-checkpoint"),
        event: .phaseCheckpoint,
        context: JobTransitionContext(
          now: now(),
          reason: "frozen plan persisted at the execution authorization boundary",
          nextStep: .orchestrate
        )
      )
    case .publishPlan:
      let claim = try await currentClaim(job)
      try await jobs.finishClaim(
        issueNodeID: claim.issueNodeID,
        generation: claim.generation,
        state: .inactive,
        now: now()
      )
      try await cleanup(jobID: job.id)
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-completed-plan-publication"),
        event: .humanGatePublished,
        context: JobTransitionContext(
          now: now(), reason: "durable plan publication and cleanup completed")
      )
    case .orchestrate:
      let evidence = try await publicationEvidence(jobID: job.id)
      let next: JobStepKind =
        evidence.disposition == PiOrchestrationDisposition.succeeded.rawValue
        ? .push : .publish
      if next == .push {
        _ = try await repositories.refreshWorkspaceHead(jobID: job.id, now: now())
      }
      _ = try await advanceRecovered(
        job,
        nextStep: next,
        reason: "durable orchestration evidence completed before interruption"
      )
      try await run(jobID: job.id)
    case .push:
      _ = try await advanceRecovered(
        job,
        nextStep: .openPullRequest,
        reason: "durable branch publication completed before interruption"
      )
      try await run(jobID: job.id)
    case .openPullRequest:
      _ = try await advanceRecovered(
        job,
        nextStep: .linkPullRequest,
        reason: "durable pull request publication completed before interruption"
      )
      try await run(jobID: job.id)
    case .linkPullRequest:
      _ = try await advanceRecovered(
        job,
        nextStep: .qa,
        reason: "durable issue link completed before interruption"
      )
      try await run(jobID: job.id)
    case .qa:
      try await finalizeQA(job)
    case .consumeStaleApproval:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-stale-approval-checkpoint"),
        event: .phaseCheckpoint,
        context: JobTransitionContext(
          now: now(),
          reason: "stale approval consumption completed at the planning authorization boundary",
          nextStep: .replan
        )
      )
    case .publish:
      let claim = try await currentClaim(job)
      try await jobs.finishClaim(
        issueNodeID: claim.issueNodeID,
        generation: claim.generation,
        state: .inactive,
        now: now()
      )
      try await cleanup(jobID: job.id)
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-completed-blocked-publication"),
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(
          now: now(), reason: "durable blocked publication and cleanup completed")
      )
    default:
      return
    }
  }

  private func recoverInterruptedOrchestration(_ job: JobRecord) async throws -> Bool {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    let envelope = try await planEnvelope(jobID: job.id)
    guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256,
      envelope.baseRevision == prepared.baseRevision,
      let recovered = try await recoverableOrchestrationEvidence(
        job: job,
        envelope: envelope,
        artifactSHA256: GitHubMarkerCodec.sha256(prepared.artifact)
      )
    else { return false }
    try await appendStep(
      job: job,
      kind: .orchestrate,
      inputDigest: envelope.plan.digest,
      outputDigest: recovered.record.sha256,
      mutationID: nil,
      evidence: recovered.evidence.importEvidenceDigest
    )
    _ = try await repositories.refreshWorkspaceHead(jobID: job.id, now: now())
    let pushing = try await advanceRecovered(
      job,
      nextStep: .push,
      reason: "durable orchestration evidence completed before interruption"
    )
    try await run(jobID: pushing.id)
    return true
  }

  private func blockInterruptedPiIfWorkspaceChanged(_ job: JobRecord) async throws {
    guard try await repositories.workspaceRecord(jobID: job.id) != nil,
      !(try await repositories.workspaceIsCleanAtRecordedHead(jobID: job.id))
    else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "interrupted-pi-workspace-changed"),
      event: .reconciliationPermanentFailure,
      context: JobTransitionContext(
        now: now(),
        reason: "interrupted Pi writer changed workspace before durable completion"
      )
    )
  }

  private func resumeCompletedPlanning(
    _ job: JobRecord,
    step: JobStepRecord
  ) async throws {
    guard let reviewDigest = step.outputDigest else {
      throw IssueImplementationJobError.invalidArtifact
    }
    let records = try await artifacts.records(jobID: job.id)
    guard
      let reviewIndex = records.lastIndex(where: {
        $0.kind == .review && $0.sha256 == reviewDigest
      })
    else {
      throw IssueImplementationJobError.invalidArtifact
    }
    let following = records.suffix(from: records.index(after: reviewIndex))
    if let diagnostic = following.last(where: { $0.kind == .diagnostic }) {
      _ = diagnostic
      _ = try await advanceRecovered(
        job,
        nextStep: .publish,
        reason: "durable blocked planning output completed before interruption"
      )
      try await run(jobID: job.id)
      return
    }
    guard let output = following.last(where: { $0.kind == .output }) else {
      throw IssueImplementationJobError.invalidArtifact
    }
    let envelope = try IssueImplementationPlanEnvelopeCodec.decode(
      try await artifacts.read(id: output.id)
    )
    if envelope.plan.planningDecision?.complexity.requiresPlanApproval == true {
      _ = try await advanceRecovered(
        job,
        nextStep: .publishPlan,
        reason: "durable complex plan completed before interruption"
      )
      try await run(jobID: job.id)
      return
    }
    let freezing = try await advanceRecovered(
      job,
      nextStep: .writePlan,
      reason: "durable automated plan completed before interruption"
    )
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(freezing, "recover-select-plan-freeze"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "recover frozen plan step")
      )
    )
    try await appendStep(
      job: executing,
      kind: .writePlan,
      inputDigest: reviewDigest,
      outputDigest: envelope.plan.digest,
      mutationID: nil,
      evidence: envelope.plan.planningDecisionSHA256
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(executing, "recover-plan-frozen"),
      event: .phaseCheckpoint,
      context: JobTransitionContext(
        now: now(),
        reason: "recovered plan persisted at the execution authorization boundary",
        nextStep: .orchestrate
      )
    )
  }

  private func advanceRecovered(
    _ job: JobRecord,
    nextStep: JobStepKind,
    reason: String
  ) async throws -> JobRecord {
    Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "recover-completed-\(nextStep.rawValue)"),
        event: .effectAttributedMore,
        context: JobTransitionContext(now: now(), reason: reason, nextStep: nextStep)
      )
    )
  }

  private func readBackLateEffect(_ job: JobRecord) async throws {
    let repository = try await requiredRepository(job)
    let coordinates = Self.coordinates(repository)
    let attributed: Bool
    switch job.currentStepKind {
    case .claimReady, .claimApprovedPlan:
      let claim = try await currentClaim(job)
      let publication = try await markerPublisher.readBackLate(
        GitHubMarkerPublicationRequest(
          jobID: job.id,
          operation: .claimIssue,
          repositoryID: repository.id,
          repository: coordinates,
          repositoryNodeID: repository.nodeID,
          objectNodeID: job.identity.objectNodeID,
          number: try requiredNumber(job),
          revision: try Self.field("Issue revision", in: claim.marker),
          kind: job.currentStepKind == .claimApprovedPlan ? .resume : .claim,
          authorID: authorID,
          document: claim.marker,
          now: now(),
          generation: try await markerGeneration(job, claimGeneration: claim.generation)
        )
      )
      attributed = publication.disposition == .attributed
    case .publishPlan:
      let envelope = try await planEnvelope(jobID: job.id)
      let publication = try await markerPublisher.readBackLate(
        GitHubMarkerPublicationRequest(
          jobID: job.id,
          operation: .publishComplexPlan,
          repositoryID: repository.id,
          repository: coordinates,
          repositoryNodeID: repository.nodeID,
          objectNodeID: job.identity.objectNodeID,
          number: try requiredNumber(job),
          revision: Self.planMarkerRevision(envelope),
          kind: .plan,
          authorID: authorID,
          document: Self.planDocument(envelope),
          now: now(),
          generation: try await markerGeneration(job)
        )
      )
      attributed = publication.disposition == .attributed
    case .publish:
      let diagnostic = try await latestArtifact(jobID: job.id, kind: .diagnostic)
      let data = try await artifacts.read(id: diagnostic.id)
      guard let document = String(data: data, encoding: .utf8) else {
        throw IssueImplementationJobError.invalidArtifact
      }
      let envelope = try await planEnvelope(jobID: job.id)
      let publication = try await markerPublisher.readBackLate(
        GitHubMarkerPublicationRequest(
          jobID: job.id,
          operation: .blockIssue,
          repositoryID: repository.id,
          repository: coordinates,
          repositoryNodeID: repository.nodeID,
          objectNodeID: job.identity.objectNodeID,
          number: try requiredNumber(job),
          revision: envelope.issueRevisionSHA256,
          kind: .blocked,
          authorID: authorID,
          document: document,
          now: now(),
          generation: try await markerGeneration(job)
        )
      )
      attributed = publication.disposition == .attributed
    case .linkPullRequest:
      let pullRequest = try await pullRequestEvidence(jobID: job.id)
      let issue = try await inputs.prepare(job: job).issue
      let publication = try await markerPublisher.readBackLate(
        GitHubMarkerPublicationRequest(
          jobID: job.id,
          operation: .linkPullRequest,
          repositoryID: repository.id,
          repository: coordinates,
          repositoryNodeID: repository.nodeID,
          objectNodeID: job.identity.objectNodeID,
          number: try requiredNumber(job),
          revision: pullRequest.headSHA,
          kind: .link,
          authorID: authorID,
          document: Self.linkDocument(issue: issue, pullRequest: pullRequest),
          now: now(),
          generation: try await markerGeneration(job)
        )
      )
      attributed = publication.disposition == .attributed
    case .openPullRequest:
      let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
      let envelope = try await planEnvelope(jobID: job.id)
      let evidence = try await publicationEvidence(jobID: job.id)
      guard let headSHA = evidence.headSHA else {
        throw IssueImplementationJobError.publicationEvidenceMissing
      }
      let result = try await pullRequestPublisher.readBackLate(
        GitHubPullRequestPublicationRequest(
          jobID: job.id,
          repository: coordinates,
          title: "Agent implementation for #\(prepared.issue.number): \(prepared.issue.title)",
          head: envelope.branch,
          base: repository.defaultBranch,
          body: "Closes #\(prepared.issue.number)\n\nPlan digest: `\(envelope.plan.digest)`\n",
          expectedHeadSHA: headSHA,
          generation: try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0,
          now: now()
        )
      )
      if let pullRequest = result.pullRequest {
        _ = try await artifacts.write(
          jobID: job.id,
          kind: .output,
          data: try JSONEncoder.sorted.encode(PullRequestPublicationEvidence(pullRequest)),
          classification: .sensitiveMetadata,
          producerRunID: nil,
          now: now()
        )
      }
      attributed = result.disposition == .attributed
    default:
      return
    }
    guard attributed else { return }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "late-effect-attributed"),
      event: .lateEffectAttributed,
      context: JobTransitionContext(now: now(), reason: "late remote effect became exact")
    )
  }

  private func startRecoveredLocalStep(
    _ job: JobRecord,
    action: (JobRecord) async throws -> Void
  ) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-recovered-local-step"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "recovered local step selected")
      )
    )
    try await action(executing)
  }

  private func startClaim(_ job: JobRecord) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-claim"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "claim mutation selected")
      )
    )
    try await executeClaim(executing)
  }

  private func executeClaim(_ job: JobRecord) async throws {
    let approved = job.currentStepKind == .claimApprovedPlan
    let activeClaim = try await jobs.claims(issueNodeID: job.identity.objectNodeID).last
      .flatMap { $0.state == .active && $0.jobID == job.id ? $0 : nil }
    let mutationGeneration = try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
    let priorMarker: GitHubMarkerPublicationResult?
    if mutationGeneration > 0, let activeClaim {
      guard mutationGeneration <= 1_024 else {
        throw IssueImplementationJobError.invalidJob
      }
      let repository = try await requiredRepository(job)
      let currentGeneration = try await markerGeneration(
        job,
        claimGeneration: activeClaim.generation
      )
      let request = GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .claimIssue,
        repositoryID: repository.id,
        repository: Self.coordinates(repository),
        repositoryNodeID: repository.nodeID,
        objectNodeID: job.identity.objectNodeID,
        number: try requiredNumber(job),
        revision: try Self.field("Issue revision", in: activeClaim.marker),
        kind: approved ? .resume : .claim,
        authorID: authorID,
        document: activeClaim.marker,
        now: now(),
        generation: currentGeneration
      )
      priorMarker = try await markerPublisher.readBackFirstAttributed(
        request,
        priorGenerations: Array(
          (currentGeneration - mutationGeneration)..<currentGeneration
        )
      )
    } else {
      priorMarker = nil
    }
    let prepared = try await inputs.prepare(job: job)
    let expected: Set<String> =
      approved ? ["agent:plan-review", "plan:approved"] : ["agent:ready"]
    guard prepared.workflowLabels == expected else {
      throw IssueImplementationJobError.workflowLabelMismatch
    }
    let envelope = approved ? try await planEnvelope(jobID: job.id) : nil
    if let envelope {
      guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256 else {
        throw IssueImplementationJobError.staleIssueRevision
      }
      guard envelope.baseRevision == prepared.baseRevision else {
        throw IssueImplementationJobError.staleBaseRevision
      }
    }
    try await freezeRolloutSnapshot(
      job: job,
      prepared: prepared,
      planSHA256: envelope?.plan.digest
    )
    let bootstrap = try await labelBootstrapper.bootstrap(
      jobID: job.id,
      repository: Self.coordinates(prepared.repository),
      at: now()
    )
    guard bootstrap.disposition == .ready else {
      throw IssueImplementationJobError.repositoryDisabled
    }
    let input = try await writeInput(prepared.artifact, jobID: job.id)
    let kind: ClaimKind = approved ? .approvedComplex : .ready
    let claim: IssueClaimRecord
    if let activeClaim,
      activeClaim.planDigest == envelope?.plan.digest
    {
      claim = activeClaim
    } else {
      let generation = try await jobs.nextClaimGeneration(
        issueNodeID: job.identity.objectNodeID
      )
      let markerDocument = Self.claimDocument(
        job: job,
        prepared: prepared,
        generation: generation,
        planDigest: envelope?.plan.digest
      )
      claim = try await jobs.beginClaim(
        issueNodeID: job.identity.objectNodeID,
        jobID: job.id,
        kind: kind,
        marker: markerDocument,
        planDigest: envelope?.plan.digest,
        now: now()
      )
      guard claim.generation == generation else {
        throw IssueImplementationJobError.claimMissing
      }
    }
    let markerDocument = claim.marker
    let coordinates = Self.coordinates(prepared.repository)
    let markerRequest = GitHubMarkerPublicationRequest(
      jobID: job.id,
      operation: .claimIssue,
      repositoryID: prepared.repository.id,
      repository: coordinates,
      repositoryNodeID: prepared.repository.nodeID,
      objectNodeID: prepared.issue.nodeID,
      number: prepared.issue.number,
      revision: try Self.field("Issue revision", in: markerDocument),
      kind: approved ? .resume : .claim,
      authorID: authorID,
      document: markerDocument,
      now: now(),
      generation: try await markerGeneration(job, claimGeneration: claim.generation)
    )
    let marker: GitHubMarkerPublicationResult
    if let priorMarker {
      marker = priorMarker
    } else {
      marker = try await publishMarker(job: job, request: markerRequest)
    }
    guard marker.disposition == .attributed else {
      let reconciling = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "claim-marker-readback"),
          event: .mutationNeedsAttribution,
          context: JobTransitionContext(now: now(), reason: "claim marker requires read-back")
        )
      )
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "claim-marker-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "claim marker was not attributable")
      )
      return
    }
    let labels = try await labelMutator.mutate(
      GitHubWorkflowLabelMutationRequest(
        jobID: job.id,
        operation: .claimIssue,
        repository: coordinates,
        number: prepared.issue.number,
        expected: Set(claim.expectedLabels),
        desired: Set(claim.desiredLabels),
        generation: try await markerGeneration(job, claimGeneration: claim.generation),
        now: now()
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "claim-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(
          now: now(), reason: "attributed claim marker and labels require read-back")
      )
    )
    switch labels.disposition {
    case .retryAllowed:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "claim-label-retry"),
        event: .safeRetry,
        context: retryContext(reason: "claim label mutation is safely retryable")
      )
      return
    case .escalated:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "claim-label-conflict"),
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(now: now(), reason: "claim label mutation conflicted")
      )
      return
    case .attributed:
      break
    }
    try await appendStep(
      job: job,
      kind: job.currentStepKind ?? (approved ? .claimApprovedPlan : .claimReady),
      inputDigest: input.sha256,
      outputDigest: labels.evidenceDigest,
      mutationID: (marker.intentIDs + labels.intentIDs).map(\.uuidString).joined(separator: ","),
      evidence: "claim-generation:\(claim.generation)"
    )
    let next = approved ? JobStepKind.orchestrate : .plan
    let preparing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "claim-attributed"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "claim marker and exact workflow labels attributed",
          nextStep: next
        )
      )
    )
    if approved {
      try await runOrchestration(preparing)
    } else {
      try await runPlanning(preparing)
    }
  }

  private func runPlanning(_ job: JobRecord) async throws {
    let replanning = job.currentStepKind == .replan
    let prepared = try await exactPrepared(
      job,
      expectedLabels: replanning ? ["agent:plan-review"] : ["agent:wip"]
    )
    let materialization = try await repositories.materializeWorkspace(
      jobID: job.id,
      remote: prepared.remote,
      baseSHA: prepared.baseRevision.sha,
      branch: prepared.branch,
      credentials: credentials,
      now: now()
    )
    let input = try await writeInput(prepared.artifact, jobID: job.id)
    let running = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-planning"),
        event: .selectPiStep,
        context: JobTransitionContext(now: now(), reason: "bounded planning fleet selected")
      )
    )
    let output = try await planner.plan(
      job: running,
      prepared: prepared,
      workspaceURL: materialization.workspaceURL,
      artifactSHA256: input.sha256
    )
    let document = Self.planningDocument(output)
    let review = try await artifacts.write(
      jobID: job.id,
      kind: .review,
      data: Data(document.utf8),
      classification: .public,
      producerRunID: nil,
      now: now()
    )
    switch output.disposition {
    case .ready, .requiresApproval:
      guard let plan = output.frozenPlan, plan.artifactSHA256 == input.sha256,
        let planningDecision = plan.planningDecision,
        output.disposition == .requiresApproval
          ? planningDecision.complexity.requiresPlanApproval
          : planningDecision.complexity.permitsAutomatedImplementation
      else {
        throw IssueImplementationJobError.planMissing
      }
      let envelope = try IssueImplementationPlanEnvelope(
        issueRevisionSHA256: prepared.issueRevision.sha256,
        baseRevision: prepared.baseRevision,
        branch: prepared.branch,
        planPath: prepared.planPath,
        plan: plan
      )
      let encoded = try IssueImplementationPlanEnvelopeCodec.encode(envelope)
      _ = try await artifacts.write(
        jobID: job.id,
        kind: .output,
        data: encoded,
        classification: .sensitiveMetadata,
        producerRunID: nil,
        now: now()
      )
      if replanning, output.disposition != .requiresApproval {
        throw IssueImplementationJobError.planningBlocked
      }
      try await appendStep(
        job: running,
        kind: job.currentStepKind ?? .plan,
        inputDigest: input.sha256,
        outputDigest: review.sha256,
        mutationID: nil,
        evidence: "planning-rounds:\(output.rounds)"
      )
      if output.disposition == .requiresApproval {
        let publishing = Self.job(
          try await jobs.transition(
            jobID: job.id,
            eventKey: eventKey(running, "planning-requires-approval"),
            event: .piCompleted,
            context: JobTransitionContext(
              now: now(),
              reason: "complex frozen plan requires approval",
              nextStep: .publishPlan
            )
          )
        )
        try await publishPlan(publishing)
      } else {
        let freezing = Self.job(
          try await jobs.transition(
            jobID: job.id,
            eventKey: eventKey(running, "planning-ready"),
            event: .piCompleted,
            context: JobTransitionContext(
              now: now(),
              reason: "simple or moderate plan passed all planning roles",
              nextStep: .writePlan
            )
          )
        )
        try await appendStep(
          job: freezing,
          kind: .writePlan,
          inputDigest: review.sha256,
          outputDigest: plan.digest,
          mutationID: nil,
          evidence: plan.planningDecisionSHA256
        )
        _ = try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(freezing, "plan-frozen-checkpoint"),
          event: .phaseCheckpoint,
          context: JobTransitionContext(
            now: now(),
            reason: "plan and command registry frozen at the execution authorization boundary",
            nextStep: .orchestrate
          )
        )
      }
    case .humanOwned, .blocked:
      let label = output.disposition == .humanOwned ? "agent:human" : "agent:blocked"
      let diagnostic = try await artifacts.write(
        jobID: job.id,
        kind: .diagnostic,
        data: Data(Self.blockedDocument(label: label, planning: output).utf8),
        classification: .public,
        producerRunID: nil,
        now: now()
      )
      try await appendStep(
        job: running,
        kind: job.currentStepKind ?? .plan,
        inputDigest: input.sha256,
        outputDigest: review.sha256,
        mutationID: nil,
        evidence: "planning-rounds:\(output.rounds)"
      )
      let publishing = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(running, "planning-blocked"),
          event: .piCompleted,
          context: JobTransitionContext(
            now: now(),
            reason: "planning safety gate blocked implementation",
            nextStep: .publish
          )
        )
      )
      try await publishBlocked(publishing, diagnostic: diagnostic, label: label)
    }
  }

  private func publishPlan(_ job: JobRecord) async throws {
    let priorSteps = try await jobs.steps(jobID: job.id)
    let replanning = priorSteps.last?.kind == .replan
    let prepared = try await exactPrepared(
      job,
      expectedLabels: replanning ? ["agent:plan-review"] : ["agent:wip"]
    )
    let envelope = try await planEnvelope(jobID: job.id)
    guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256,
      envelope.baseRevision == prepared.baseRevision
    else {
      throw IssueImplementationJobError.staleBaseRevision
    }
    let document = Self.planDocument(envelope)
    let coordinates = Self.coordinates(prepared.repository)
    let marker = try await publishMarker(
      job: job,
      request: GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .publishComplexPlan,
        repositoryID: prepared.repository.id,
        repository: coordinates,
        repositoryNodeID: prepared.repository.nodeID,
        objectNodeID: prepared.issue.nodeID,
        number: prepared.issue.number,
        revision: Self.planMarkerRevision(envelope),
        kind: .plan,
        authorID: authorID,
        document: document,
        now: now(),
        generation: try await markerGeneration(job)
      )
    )
    guard marker.disposition == .attributed else {
      let reconciling = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "plan-marker-readback"),
          event: .mutationNeedsAttribution,
          context: JobTransitionContext(
            now: now(), reason: "complex plan marker requires read-back")
        )
      )
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "plan-marker-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(
          now: now(), reason: "complex plan marker was not attributable")
      )
      return
    }

    var mutationIDs = marker.intentIDs
    var outputDigest = marker.evidenceDigest
    if !replanning {
      let labels = try await labelMutator.mutate(
        GitHubWorkflowLabelMutationRequest(
          jobID: job.id,
          operation: .publishComplexPlan,
          repository: coordinates,
          number: prepared.issue.number,
          expected: ["agent:wip"],
          desired: ["agent:plan-review"],
          generation: try await markerGeneration(job),
          now: now()
        )
      )
      let reconciling = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "plan-readback"),
          event: .mutationNeedsAttribution,
          context: JobTransitionContext(now: now(), reason: "plan-review label requires read-back")
        )
      )
      switch labels.disposition {
      case .retryAllowed:
        _ = try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(reconciling, "plan-label-retry"),
          event: .safeRetry,
          context: retryContext(reason: "plan-review label mutation is safely retryable")
        )
        return
      case .escalated:
        _ = try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(reconciling, "plan-label-conflict"),
          event: .reconciliationPermanentFailure,
          context: JobTransitionContext(now: now(), reason: "plan-review label mutation conflicted")
        )
        return
      case .attributed:
        mutationIDs += labels.intentIDs
        outputDigest = labels.evidenceDigest
        try await finishPlanPublication(
          job: job,
          reconciling: reconciling,
          envelope: envelope,
          marker: marker,
          mutationIDs: mutationIDs,
          outputDigest: outputDigest
        )
      }
      return
    }
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "replacement-plan-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "replacement plan marker attributed")
      )
    )
    try await finishPlanPublication(
      job: job,
      reconciling: reconciling,
      envelope: envelope,
      marker: marker,
      mutationIDs: mutationIDs,
      outputDigest: outputDigest
    )
  }

  private func finishPlanPublication(
    job: JobRecord,
    reconciling: JobRecord,
    envelope: IssueImplementationPlanEnvelope,
    marker: GitHubMarkerPublicationResult,
    mutationIDs: [UUID],
    outputDigest: String
  ) async throws {
    try await appendStep(
      job: job,
      kind: .publishPlan,
      inputDigest: envelope.plan.digest,
      outputDigest: outputDigest,
      mutationID: mutationIDs.map(\.uuidString).joined(separator: ","),
      evidence: marker.documentSHA256
    )
    let claim = try await currentClaim(job)
    try await jobs.finishClaim(
      issueNodeID: claim.issueNodeID,
      generation: claim.generation,
      state: .inactive,
      now: now()
    )
    try await cleanup(jobID: job.id)
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(reconciling, "await-plan-approval"),
      event: .humanGatePublished,
      context: JobTransitionContext(
        now: now(), reason: "complex plan awaits exact plan:approved label after cleanup")
    )
  }

  private func runOrchestration(_ job: JobRecord) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    let envelope = try await planEnvelope(jobID: job.id)
    guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256 else {
      throw IssueImplementationJobError.staleIssueRevision
    }
    guard envelope.baseRevision == prepared.baseRevision else {
      throw IssueImplementationJobError.staleBaseRevision
    }
    let resumedApprovedPlan = try await jobs.steps(jobID: job.id).contains {
      $0.kind == .claimApprovedPlan
    }
    if !resumedApprovedPlan {
      try await freezeRolloutSnapshot(
        job: job,
        prepared: prepared,
        planSHA256: envelope.plan.digest
      )
    }
    let artifactSHA256 = GitHubMarkerCodec.sha256(prepared.artifact)
    if let recovered = try await recoverableOrchestrationEvidence(
      job: job,
      envelope: envelope,
      artifactSHA256: artifactSHA256
    ) {
      let running = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "select-recovered-orchestration"),
          event: .selectPiStep,
          context: JobTransitionContext(
            now: now(), reason: "durable orchestration evidence selected")
        )
      )
      try await appendStep(
        job: running,
        kind: .orchestrate,
        inputDigest: envelope.plan.digest,
        outputDigest: recovered.record.sha256,
        mutationID: nil,
        evidence: recovered.evidence.importEvidenceDigest
      )
      _ = try await repositories.refreshWorkspaceHead(jobID: job.id, now: now())
      let pushing = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(running, "recovered-orchestration-completed"),
          event: .piCompleted,
          context: JobTransitionContext(
            now: now(),
            reason: "durable implementation, verification and import evidence recovered",
            nextStep: .push
          )
        )
      )
      try await publishBranch(pushing)
      return
    }
    let materialization = try await repositories.materializeWorkspace(
      jobID: job.id,
      remote: prepared.remote,
      baseSHA: prepared.baseRevision.sha,
      branch: prepared.branch,
      credentials: credentials,
      now: now()
    )
    let input = try await writeInput(prepared.artifact, jobID: job.id)
    let running = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-orchestration"),
        event: .selectPiStep,
        context: JobTransitionContext(now: now(), reason: "bounded implementation fleet selected")
      )
    )
    let execution = try await orchestrator.orchestrate(
      job: running,
      prepared: prepared,
      workspaceURL: materialization.workspaceURL,
      envelope: envelope,
      artifactSHA256: input.sha256
    )
    let evidence = try ImplementationPublicationEvidence(
      execution: execution,
      planSHA256: envelope.plan.digest,
      artifactSHA256: input.sha256,
      jobStep: running.currentStep
    )
    let encoded = try JSONEncoder.sorted.encode(evidence)
    let record = try await artifacts.write(
      jobID: job.id,
      kind: .verification,
      data: encoded,
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: now()
    )
    try await afterOrchestrationEvidencePersisted()
    guard execution.orchestration.disposition == .succeeded,
      evidence.headSHA != nil,
      evidence.importEvidenceDigest != nil
    else {
      let diagnostic = try await artifacts.write(
        jobID: job.id,
        kind: .diagnostic,
        data: Data(Self.blockedDocument(execution.orchestration).utf8),
        classification: .public,
        producerRunID: nil,
        now: now()
      )
      try await appendStep(
        job: running,
        kind: .orchestrate,
        inputDigest: envelope.plan.digest,
        outputDigest: record.sha256,
        mutationID: nil,
        evidence: evidence.importEvidenceDigest
      )
      let publishing = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(running, "orchestration-blocked"),
          event: .piCompleted,
          context: JobTransitionContext(
            now: now(),
            reason: "implementation or final verification remained blocked",
            nextStep: .publish
          )
        )
      )
      try await publishBlocked(publishing, diagnostic: diagnostic, label: "agent:blocked")
      return
    }
    try await appendStep(
      job: running,
      kind: .orchestrate,
      inputDigest: envelope.plan.digest,
      outputDigest: record.sha256,
      mutationID: nil,
      evidence: evidence.importEvidenceDigest
    )
    _ = try await repositories.refreshWorkspaceHead(jobID: job.id, now: now())
    let pushing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(running, "orchestration-completed"),
        event: .piCompleted,
        context: JobTransitionContext(
          now: now(),
          reason: "implementation, hooks, checks, review and import passed",
          nextStep: .push
        )
      )
    )
    try await publishBranch(pushing)
  }

  private func freezeRolloutSnapshot(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    planSHA256: String?
  ) async throws {
    guard let rolloutSnapshots else { return }
    try await rolloutSnapshots.freezeJobInputSnapshot(
      RolloutJobInputSnapshot(
        jobID: job.id,
        canonicalInputSHA256: GitHubMarkerCodec.sha256(prepared.artifact),
        baseSHA: prepared.baseRevision.sha,
        labelStateSHA256: try RolloutPreviewBuilder.labelStateSHA256(
          prepared.labels
        ),
        planSHA256: planSHA256
      ),
      now: now()
    )
  }

  private func publishBranch(_ job: JobRecord) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    let envelope = try await planEnvelope(jobID: job.id)
    try Self.requireFresh(envelope, prepared: prepared)
    let evidence = try await publicationEvidence(jobID: job.id)
    guard let headSHA = evidence.headSHA,
      let importDigest = evidence.importEvidenceDigest
    else {
      throw IssueImplementationJobError.publicationEvidenceMissing
    }
    let workspaceURL = try await repositories.retainedWorkspaceURL(jobID: job.id)
    let key = Self.digest([
      job.id.uuidString.lowercased(), "push", envelope.branch, headSHA,
    ])
    let dispatch = try await branchPublisher.publishCreateOnly(
      request: GitBranchPublicationRequest(
        jobID: job.id,
        idempotencyKey: key,
        branch: envelope.branch,
        exactSHA: headSHA,
        expectedStateDigest: importDigest
      ),
      remote: prepared.remote,
      repository: workspaceURL,
      credentials: credentials,
      now: now()
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "push-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(
          now: now(), reason: "create-only branch publication requires read-back")
      )
    )
    guard dispatch.intent.state == .attributed else {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "push-not-attributed"),
        event: dispatch.intent.state == .retryAllowed
          ? .safeRetry : .reconciliationPermanentFailure,
        context: retryContext(reason: "branch publication was not attributable")
      )
      return
    }
    try await appendStep(
      job: job,
      kind: .push,
      inputDigest: importDigest,
      outputDigest: dispatch.publication?.evidenceDigest ?? dispatch.intent.readBackEvidence,
      mutationID: dispatch.intent.id.uuidString.lowercased(),
      evidence: headSHA
    )
    let preparing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "push-attributed"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "remote branch exact SHA attributed",
          nextStep: .openPullRequest
        )
      )
    )
    try await startPullRequestPublication(preparing)
  }

  private func startPullRequestPublication(_ job: JobRecord) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-pr-create"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "pull request create selected")
      )
    )
    try await publishPullRequest(executing)
  }

  private func publishPullRequest(_ job: JobRecord) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    let envelope = try await planEnvelope(jobID: job.id)
    try Self.requireFresh(envelope, prepared: prepared)
    let evidence = try await publicationEvidence(jobID: job.id)
    guard let headSHA = evidence.headSHA else {
      throw IssueImplementationJobError.publicationEvidenceMissing
    }
    let mutationGeneration = try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
    guard mutationGeneration <= 1_024 else {
      throw IssueImplementationJobError.invalidJob
    }
    let result = try await pullRequestPublisher.publishCheckingPriorGenerations(
      GitHubPullRequestPublicationRequest(
        jobID: job.id,
        repository: Self.coordinates(prepared.repository),
        title: "Agent implementation for #\(prepared.issue.number): \(prepared.issue.title)",
        head: envelope.branch,
        base: prepared.repository.defaultBranch,
        body: "Closes #\(prepared.issue.number)\n\nPlan digest: `\(envelope.plan.digest)`\n",
        expectedHeadSHA: headSHA,
        generation: mutationGeneration,
        now: now()
      ),
      priorGenerations: Array(0..<mutationGeneration)
    )
    if let pullRequest = result.pullRequest {
      _ = try await artifacts.write(
        jobID: job.id,
        kind: .output,
        data: try JSONEncoder.sorted.encode(PullRequestPublicationEvidence(pullRequest)),
        classification: .sensitiveMetadata,
        producerRunID: nil,
        now: now()
      )
    }
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "pr-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(
          now: now(), reason: "pull request create requires exact lookup")
      )
    )
    guard result.disposition == .attributed, result.pullRequest != nil else {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "pr-not-attributed"),
        event: result.disposition == .retryAllowed ? .safeRetry : .ambiguousCreate,
        context: retryContext(reason: "pull request create was not attributable")
      )
      return
    }
    try await appendStep(
      job: job,
      kind: .openPullRequest,
      inputDigest: evidence.importEvidenceDigest,
      outputDigest: result.evidenceDigest,
      mutationID: result.intentID.uuidString.lowercased(),
      evidence: result.pullRequest.map { "pr:\($0.number):\($0.nodeID)" }
    )
    let preparing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "pr-attributed"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "pull request exact head attributed",
          nextStep: .linkPullRequest
        )
      )
    )
    try await startRecoveredLocalStep(preparing, action: publishIssueLink)
  }

  private func publishIssueLink(_ job: JobRecord) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    try Self.requireFresh(try await planEnvelope(jobID: job.id), prepared: prepared)
    let pullRequest = try await pullRequestEvidence(jobID: job.id)
    let publication = try await publishMarker(
      job: job,
      request: GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .linkPullRequest,
        repositoryID: prepared.repository.id,
        repository: Self.coordinates(prepared.repository),
        repositoryNodeID: prepared.repository.nodeID,
        objectNodeID: prepared.issue.nodeID,
        number: prepared.issue.number,
        revision: pullRequest.headSHA,
        kind: .link,
        authorID: authorID,
        document: Self.linkDocument(issue: prepared.issue, pullRequest: pullRequest),
        now: now(),
        generation: try await markerGeneration(job)
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "issue-link-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "issue link marker requires read-back")
      )
    )
    guard publication.disposition == .attributed else {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "issue-link-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "issue link marker was not attributable")
      )
      return
    }
    try await appendStep(
      job: job,
      kind: .linkPullRequest,
      inputDigest: GitHubMarkerCodec.sha256(Data(pullRequest.headSHA.utf8)),
      outputDigest: publication.documentSHA256,
      mutationID: publication.intentIDs.map(\.uuidString).joined(separator: ","),
      evidence: publication.evidenceDigest
    )
    let preparing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "issue-link-attributed"),
        event: .effectAttributedMore,
        context: JobTransitionContext(
          now: now(),
          reason: "issue link marker attributed",
          nextStep: .qa
        )
      )
    )
    try await startQA(preparing)
  }

  private func startQA(_ job: JobRecord) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-qa-label"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "final QA label selected")
      )
    )
    try await publishQA(executing)
  }

  private func publishQA(_ job: JobRecord) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    try Self.requireFresh(try await planEnvelope(jobID: job.id), prepared: prepared)
    let result = try await labelMutator.mutate(
      GitHubWorkflowLabelMutationRequest(
        jobID: job.id,
        operation: .mutateWorkflowLabels,
        repository: Self.coordinates(prepared.repository),
        number: prepared.issue.number,
        expected: ["agent:wip"],
        desired: ["agent:qa"],
        generation: try await markerGeneration(job),
        now: now()
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "qa-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(now: now(), reason: "QA label requires exact read-back")
      )
    )
    switch result.disposition {
    case .retryAllowed:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "qa-label-retry"),
        event: .safeRetry,
        context: retryContext(reason: "QA label mutation is safely retryable")
      )
      return
    case .escalated:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "qa-label-conflict"),
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(now: now(), reason: "QA label conflicted")
      )
      return
    case .attributed:
      break
    }
    try await appendStep(
      job: job,
      kind: .qa,
      inputDigest: try await publicationEvidence(jobID: job.id).importEvidenceDigest,
      outputDigest: result.evidenceDigest,
      mutationID: result.intentIDs.map(\.uuidString).joined(separator: ","),
      evidence: "agent:qa"
    )
    try await finalizeQA(reconciling)
  }

  private func finalizeQA(_ job: JobRecord) async throws {
    let pullRequest = try await pullRequestEvidence(jobID: job.id)
    let evidence = try await publicationEvidence(jobID: job.id)
    guard let headSHA = evidence.headSHA else {
      throw IssueImplementationJobError.publicationEvidenceMissing
    }
    let reviewCreation = try await jobs.createQuarantinedGeneratedReviewJob(
      parentJobID: job.id,
      identity: LogicalJobIdentity(
        repositoryID: job.identity.repositoryID,
        kind: .prReview,
        objectNodeID: pullRequest.nodeID,
        revisionKey: headSHA
      ),
      objectNumber: pullRequest.number,
      contractVersionUsed: contractVersion,
      now: now()
    )
    if case .created(let reviewJob) = reviewCreation {
      guard reviewJob.state == .queued else {
        throw IssueImplementationJobError.publicationEvidenceMissing
      }
    }
    let claim = try await currentClaim(job)
    try await jobs.finishClaim(
      issueNodeID: claim.issueNodeID,
      generation: claim.generation,
      state: .consumed,
      now: now()
    )
    try await cleanup(jobID: job.id)
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(job, "implementation-accepted"),
      event: .acceptanceComplete,
      context: JobTransitionContext(
        now: now(),
        reason: "branch, pull request, QA label, review enqueue, and cleanup are durable",
        acceptanceEvidenceDigest: evidence.importEvidenceDigest
      )
    )
  }

  private func startConsumeStaleApproval(_ job: JobRecord) async throws {
    let executing = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "select-stale-approval-consume"),
        event: .selectLocalStep,
        context: JobTransitionContext(now: now(), reason: "stale approval consumption selected")
      )
    )
    try await consumeStaleApproval(executing)
  }

  private func consumeStaleApproval(_ job: JobRecord) async throws {
    let prepared = try await inputs.prepare(job: job)
    guard prepared.workflowLabels == ["agent:plan-review", "plan:approved"] else {
      throw IssueImplementationJobError.workflowLabelMismatch
    }
    let claim = try await currentClaim(job)
    let result = try await labelMutator.mutate(
      GitHubWorkflowLabelMutationRequest(
        jobID: job.id,
        operation: .publishComplexPlan,
        repository: Self.coordinates(prepared.repository),
        number: prepared.issue.number,
        expected: ["agent:plan-review", "plan:approved"],
        desired: ["agent:plan-review"],
        generation: claim.generation + 1,
        now: now()
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "stale-approval-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(
          now: now(), reason: "stale approval removal requires read-back")
      )
    )
    switch result.disposition {
    case .retryAllowed:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "stale-approval-retry"),
        event: .safeRetry,
        context: retryContext(reason: "stale approval removal is safely retryable")
      )
      return
    case .escalated:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "stale-approval-conflict"),
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(
          now: now(), reason: "stale approval could not be consumed exactly")
      )
      return
    case .attributed:
      break
    }
    try await appendStep(
      job: job,
      kind: .consumeStaleApproval,
      inputDigest: try await planEnvelope(jobID: job.id).plan.digest,
      outputDigest: result.evidenceDigest,
      mutationID: result.intentIDs.map(\.uuidString).joined(separator: ","),
      evidence: "stale-approval-consumed"
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(reconciling, "stale-approval-checkpoint"),
      event: .phaseCheckpoint,
      context: JobTransitionContext(
        now: now(),
        reason: "stale approval consumed at the planning authorization boundary",
        nextStep: .replan
      )
    )
  }

  private func publishBlocked(_ job: JobRecord) async throws {
    let record = try await latestArtifact(jobID: job.id, kind: .diagnostic)
    let data = try await artifacts.read(id: record.id)
    guard let document = String(data: data, encoding: .utf8),
      let first = document.split(separator: "\n").first,
      first.hasPrefix("Label: ")
    else {
      throw IssueImplementationJobError.invalidArtifact
    }
    try await publishBlocked(
      job,
      diagnostic: record,
      label: String(first.dropFirst("Label: ".count))
    )
  }

  private func publishBlocked(
    _ job: JobRecord,
    diagnostic: ArtifactRecord,
    label: String
  ) async throws {
    let prepared = try await exactPrepared(job, expectedLabels: ["agent:wip"])
    let documentData = try await artifacts.read(id: diagnostic.id)
    guard let document = String(data: documentData, encoding: .utf8) else {
      throw IssueImplementationJobError.invalidArtifact
    }
    let coordinates = Self.coordinates(prepared.repository)
    let marker = try await publishMarker(
      job: job,
      request: GitHubMarkerPublicationRequest(
        jobID: job.id,
        operation: .blockIssue,
        repositoryID: prepared.repository.id,
        repository: coordinates,
        repositoryNodeID: prepared.repository.nodeID,
        objectNodeID: prepared.issue.nodeID,
        number: prepared.issue.number,
        revision: prepared.issueRevision.sha256,
        kind: .blocked,
        authorID: authorID,
        document: document,
        now: now(),
        generation: try await markerGeneration(job)
      )
    )
    guard marker.disposition == .attributed else {
      let reconciling = Self.job(
        try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job, "blocked-marker-readback"),
          event: .mutationNeedsAttribution,
          context: JobTransitionContext(now: now(), reason: "blocked marker requires read-back")
        )
      )
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "blocked-marker-ambiguous"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "blocked marker was not attributable")
      )
      return
    }
    let labels = try await labelMutator.mutate(
      GitHubWorkflowLabelMutationRequest(
        jobID: job.id,
        operation: .blockIssue,
        repository: coordinates,
        number: prepared.issue.number,
        expected: ["agent:wip"],
        desired: [label],
        generation: try await markerGeneration(job),
        now: now()
      )
    )
    let reconciling = Self.job(
      try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job, "blocked-readback"),
        event: .mutationNeedsAttribution,
        context: JobTransitionContext(
          now: now(), reason: "blocked rationale and label require read-back")
      )
    )
    switch labels.disposition {
    case .retryAllowed:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "blocked-label-retry"),
        event: .safeRetry,
        context: retryContext(reason: "blocked label mutation is safely retryable")
      )
      return
    case .escalated:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(reconciling, "blocked-label-conflict"),
        event: .ambiguousCreate,
        context: JobTransitionContext(now: now(), reason: "blocked label mutation conflicted")
      )
      return
    case .attributed:
      break
    }
    try await appendStep(
      job: job,
      kind: .publish,
      inputDigest: diagnostic.sha256,
      outputDigest: labels.evidenceDigest,
      mutationID: (marker.intentIDs + labels.intentIDs).map(\.uuidString).joined(separator: ","),
      evidence: label
    )
    let claim = try await currentClaim(job)
    try await jobs.finishClaim(
      issueNodeID: claim.issueNodeID,
      generation: claim.generation,
      state: .inactive,
      now: now()
    )
    try await cleanup(jobID: job.id)
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: eventKey(reconciling, "implementation-blocked"),
      event: .reconciliationPermanentFailure,
      context: JobTransitionContext(
        now: now(), reason: "implementation safety gate blocked publication after cleanup")
    )
  }

  private func publishMarker(
    job: JobRecord,
    request: GitHubMarkerPublicationRequest
  ) async throws -> GitHubMarkerPublicationResult {
    let mutationGeneration = try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
    guard mutationGeneration <= 1_024,
      request.generation >= mutationGeneration
    else {
      throw IssueImplementationJobError.invalidJob
    }
    let firstGeneration = request.generation - mutationGeneration
    return try await markerPublisher.publishCheckingPriorGenerations(
      request,
      priorGenerations: Array(firstGeneration..<request.generation)
    )
  }

  private func markerGeneration(_ job: JobRecord) async throws -> Int {
    try await markerGeneration(job, claimGeneration: currentClaim(job).generation)
  }

  private func markerGeneration(
    _ job: JobRecord,
    claimGeneration: Int
  ) async throws -> Int {
    let mutationGeneration = try await jobs.disposition(for: job.identity)?.mutationGeneration ?? 0
    guard claimGeneration >= 0, mutationGeneration >= 0,
      claimGeneration <= (Int.max - mutationGeneration) / 1_000_000
    else {
      throw IssueImplementationJobError.invalidJob
    }
    return claimGeneration * 1_000_000 + mutationGeneration
  }

  private func requiredRepository(_ job: JobRecord) async throws -> RepositoryConfiguration {
    guard let repository = try await configuration.repository(id: job.identity.repositoryID) else {
      throw IssueImplementationJobError.repositoryDisabled
    }
    return repository
  }

  private func requiredNumber(_ job: JobRecord) throws -> Int {
    guard let number = job.objectNumber, number > 0 else {
      throw IssueImplementationJobError.invalidJob
    }
    return number
  }

  private func exactPrepared(
    _ job: JobRecord,
    expectedLabels: Set<String>
  ) async throws -> PreparedIssueImplementationJob {
    let prepared = try await inputs.prepare(job: job)
    guard prepared.workflowLabels == expectedLabels else {
      throw IssueImplementationJobError.workflowLabelMismatch
    }
    return prepared
  }

  private func writeInput(_ data: Data, jobID: UUID) async throws -> ArtifactRecord {
    try await artifacts.write(
      jobID: jobID,
      kind: .input,
      data: data,
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: now()
    )
  }

  private func planEnvelope(jobID: UUID) async throws -> IssueImplementationPlanEnvelope {
    let records = try await artifacts.records(jobID: jobID).filter { $0.kind == .output }
    for record in records.reversed() {
      let data = try await artifacts.read(id: record.id)
      if let envelope = try? IssueImplementationPlanEnvelopeCodec.decode(data) {
        return envelope
      }
    }
    throw IssueImplementationJobError.planMissing
  }

  private func recoverableOrchestrationEvidence(
    job: JobRecord,
    envelope: IssueImplementationPlanEnvelope,
    artifactSHA256: String
  ) async throws -> RecoveredOrchestrationEvidence? {
    let records = try await artifacts.records(jobID: job.id).filter { $0.kind == .verification }
    for record in records.reversed() {
      let data = try await artifacts.read(id: record.id)
      guard
        let evidence = try? JSONDecoder().decode(
          ImplementationPublicationEvidence.self,
          from: data
        ),
        evidence.schemaVersion == 2,
        evidence.disposition == PiOrchestrationDisposition.succeeded.rawValue,
        evidence.planSHA256 == envelope.plan.digest,
        evidence.artifactSHA256 == artifactSHA256,
        evidence.jobStep == job.currentStep,
        let headSHA = evidence.headSHA,
        GitHubInputValidation.validGitSHA(headSHA),
        evidence.treeSHA.map(GitHubInputValidation.validGitSHA) == true,
        evidence.importEvidenceDigest.map(GitHubInputValidation.validSHA256) == true,
        try await repositories.workspaceIsClean(jobID: job.id, exactHeadSHA: headSHA)
      else { continue }
      return RecoveredOrchestrationEvidence(record: record, evidence: evidence)
    }
    return nil
  }

  private func publicationEvidence(jobID: UUID) async throws -> ImplementationPublicationEvidence {
    let records = try await artifacts.records(jobID: jobID).filter { $0.kind == .verification }
    for record in records.reversed() {
      let data = try await artifacts.read(id: record.id)
      if let evidence = try? JSONDecoder().decode(
        ImplementationPublicationEvidence.self,
        from: data
      ) {
        return evidence
      }
    }
    throw IssueImplementationJobError.publicationEvidenceMissing
  }

  private func pullRequestEvidence(jobID: UUID) async throws -> PullRequestPublicationEvidence {
    let records = try await artifacts.records(jobID: jobID).filter { $0.kind == .output }
    for record in records.reversed() {
      let data = try await artifacts.read(id: record.id)
      if let evidence = try? JSONDecoder().decode(
        PullRequestPublicationEvidence.self,
        from: data
      ), evidence.schemaVersion == 1, evidence.number > 0,
        !evidence.nodeID.isEmpty, GitHubInputValidation.validGitSHA(evidence.headSHA)
      {
        return evidence
      }
    }
    throw IssueImplementationJobError.pullRequestMissing
  }

  private func latestArtifact(jobID: UUID, kind: ArtifactKind) async throws -> ArtifactRecord {
    guard let value = try await artifacts.records(jobID: jobID).last(where: { $0.kind == kind })
    else {
      throw IssueImplementationJobError.invalidArtifact
    }
    return value
  }

  private func currentClaim(_ job: JobRecord) async throws -> IssueClaimRecord {
    guard
      let claim = try await jobs.claims(issueNodeID: job.identity.objectNodeID)
        .filter({ $0.jobID == job.id }).last
    else {
      throw IssueImplementationJobError.claimMissing
    }
    return claim
  }

  private func cleanup(jobID: UUID) async throws {
    guard let record = try await repositories.workspaceRecord(jobID: jobID) else { return }
    if record.cleanupState == .retained {
      try await repositories.authorizeCleanup(jobID: jobID, now: now())
    }
    try await repositories.cleanupWorkspace(jobID: jobID, now: now())
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

  private func eventKey(_ job: JobRecord, _ suffix: String) -> String {
    "implementation:\(job.id.uuidString.lowercased()):a\(job.attempt):s\(job.currentStep):\(suffix)"
  }

  private func retryContext(reason: String) -> JobTransitionContext {
    JobTransitionContext(
      now: now(),
      reason: reason,
      notBefore: now().addingTimeInterval(60)
    )
  }

  private static func field(_ name: String, in document: String) throws -> String {
    let prefix = "\(name): "
    guard let line = document.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
      throw IssueImplementationJobError.invalidArtifact
    }
    return String(line.dropFirst(prefix.count))
  }

  private static func requireFresh(
    _ envelope: IssueImplementationPlanEnvelope,
    prepared: PreparedIssueImplementationJob
  ) throws {
    guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256 else {
      throw IssueImplementationJobError.staleIssueRevision
    }
    guard envelope.baseRevision == prepared.baseRevision else {
      throw IssueImplementationJobError.staleBaseRevision
    }
  }

  private static func coordinates(
    _ repository: RepositoryConfiguration
  ) -> GitHubRepositoryCoordinates {
    GitHubRepositoryCoordinates(owner: repository.owner, repository: repository.name)
  }

  private static func claimDocument(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    generation: Int,
    planDigest: String?
  ) -> String {
    [
      "# Jidoka Code issue claim",
      "",
      "Issue: #\(prepared.issue.number)",
      "Issue revision: \(prepared.issueRevision.sha256)",
      "Base revision: \(prepared.baseRevision.sha)",
      "Claim generation: \(generation)",
      "Plan digest: \(planDigest ?? "pending")",
      "Job: \(job.id.uuidString.lowercased())",
    ].joined(separator: "\n") + "\n"
  }

  private static func planningDocument(_ output: PiPlanningOutput) -> String {
    var lines = [
      "# Jidoka Code planning result",
      "",
      "Disposition: \(output.disposition.rawValue)",
      "Complexity: \(output.complexity.classification.rawValue)",
      "Classifier digest: \(output.complexity.digest)",
      "Rounds: \(output.rounds)",
      "",
      output.planMarkdown,
    ]
    if !output.engineFailures.isEmpty {
      lines += ["", "## Engine failures"] + output.engineFailures.map { "- \($0)" }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func planMarkerRevision(
    _ envelope: IssueImplementationPlanEnvelope
  ) -> String {
    digest([
      envelope.issueRevisionSHA256,
      envelope.baseRevision.branch,
      envelope.baseRevision.sha,
      envelope.plan.digest,
    ])
  }

  private static func planDocument(_ envelope: IssueImplementationPlanEnvelope) -> String {
    [
      "# Jidoka Code complex implementation plan",
      "",
      "Issue revision: \(envelope.issueRevisionSHA256)",
      "Base revision: \(envelope.baseRevision.sha)",
      "Base digest: \(envelope.baseRevision.sha256)",
      "Plan digest: \(envelope.plan.digest)",
      "Classifier digest: \(envelope.plan.planningDecision?.complexity.digest ?? "missing")",
      "",
      envelope.plan.planMarkdown,
    ].joined(separator: "\n") + "\n"
  }

  private static func linkDocument(
    issue: GitHubIssue,
    pullRequest: PullRequestPublicationEvidence
  ) -> String {
    [
      "# Jidoka Code implementation link",
      "",
      "Issue: #\(issue.number)",
      "Pull request: #\(pullRequest.number)",
      "Pull request node: \(pullRequest.nodeID)",
      "Exact head: \(pullRequest.headSHA)",
    ].joined(separator: "\n") + "\n"
  }

  private static func blockedDocument(
    label: String,
    planning: PiPlanningOutput
  ) -> String {
    [
      "Label: \(label)",
      "# Jidoka Code implementation blocked",
      "",
      "Planning disposition: \(planning.disposition.rawValue)",
      "Complexity: \(planning.complexity.classification.rawValue)",
      "Classifier digest: \(planning.complexity.digest)",
      "Failures: \(planning.engineFailures.joined(separator: ", "))",
    ].joined(separator: "\n") + "\n"
  }

  private static func blockedDocument(_ output: PiOrchestrationOutput) -> String {
    [
      "Label: agent:blocked",
      "# Jidoka Code implementation blocked",
      "",
      "Orchestration disposition: \(output.disposition.rawValue)",
      "Rounds: \(output.rounds)",
      "Failures: \(output.engineFailures.joined(separator: ", "))",
    ].joined(separator: "\n") + "\n"
  }

  private static func digest(_ fields: [String]) -> String {
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }

  private static func job(_ result: JobTransitionResult) -> JobRecord {
    switch result {
    case .applied(let job), .duplicate(let job): job
    }
  }
}

private struct RecoveredOrchestrationEvidence: Sendable {
  let record: ArtifactRecord
  let evidence: ImplementationPublicationEvidence
}

private struct ImplementationPublicationEvidence: Codable, Sendable {
  let schemaVersion: Int
  let disposition: String
  let headSHA: String?
  let treeSHA: String?
  let importEvidenceDigest: String?
  let changedFiles: [String]
  let rounds: Int
  let planSHA256: String?
  let artifactSHA256: String?
  let jobStep: Int?

  init(
    execution: IssueImplementationExecutionResult,
    planSHA256: String,
    artifactSHA256: String,
    jobStep: Int
  ) throws {
    schemaVersion = 2
    disposition = execution.orchestration.disposition.rawValue
    headSHA = execution.headSHA
    treeSHA = execution.treeSHA
    importEvidenceDigest = execution.importEvidence?.evidenceDigest
    changedFiles = execution.importEvidence?.changedFiles ?? []
    rounds = execution.orchestration.rounds
    self.planSHA256 = planSHA256
    self.artifactSHA256 = artifactSHA256
    self.jobStep = jobStep
    guard GitHubInputValidation.validSHA256(planSHA256),
      GitHubInputValidation.validSHA256(artifactSHA256), jobStep >= 0
    else {
      throw IssueImplementationJobError.publicationEvidenceMissing
    }
    if execution.orchestration.disposition == .succeeded {
      guard let headSHA, let treeSHA, let importEvidenceDigest,
        GitHubInputValidation.validGitSHA(headSHA),
        GitHubInputValidation.validGitSHA(treeSHA),
        GitHubInputValidation.validSHA256(importEvidenceDigest)
      else {
        throw IssueImplementationJobError.publicationEvidenceMissing
      }
    }
  }
}

private struct PullRequestPublicationEvidence: Codable, Sendable {
  let schemaVersion: Int
  let nodeID: String
  let number: Int
  let headSHA: String

  init(_ pullRequest: GitHubPullRequest) {
    schemaVersion = 1
    nodeID = pullRequest.nodeID
    number = pullRequest.number
    headSHA = pullRequest.head.sha
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let value = JSONEncoder()
    value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return value
  }
}
