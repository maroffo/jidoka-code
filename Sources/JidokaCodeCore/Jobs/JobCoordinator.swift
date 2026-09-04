import Foundation

public protocol JobWorkflowRunning: Sendable {
  func run(jobID: UUID) async throws
  func runRecoveredCanary(jobID: UUID, recoveryEvidenceSHA256: String) async throws
  func runCanaryPiFreshRetry(
    jobID: UUID,
    recoveryEvidenceSHA256: String,
    retryEvidenceSHA256: String
  ) async throws
  func runCanaryRoleHostReplacement(
    request: JobCanaryRoleHostReplacementRequest
  ) async throws
}

extension JobWorkflowRunning {
  public func runRecoveredCanary(
    jobID _: UUID,
    recoveryEvidenceSHA256 _: String
  ) async throws {
    throw JobCoordinatorInternalError.invalidCanary
  }

  public func runCanaryPiFreshRetry(
    jobID _: UUID,
    recoveryEvidenceSHA256 _: String,
    retryEvidenceSHA256 _: String
  ) async throws {
    throw JobCoordinatorInternalError.invalidCanary
  }

  public func runCanaryRoleHostReplacement(
    request _: JobCanaryRoleHostReplacementRequest
  ) async throws {
    throw JobCoordinatorInternalError.invalidCanary
  }
}

public protocol IssueImplementationApprovalEvaluating: Sendable {
  @discardableResult
  func evaluateWaitingApproval(jobID: UUID) async throws -> JobRecord
}

public protocol RolloutStartedEffectReconciling: Sendable {
  func reconcileStartedEffects(now: Date) async throws
}

public actor RolloutWorkflowReadbackReconciler: RolloutStartedEffectReconciling {
  private let database: SQLiteStore
  private let jobs: DurableJobStore
  private let workflows: JobWorkflowRegistry
  private let authority: any RolloutEffectAuthorizing

  public init(
    database: SQLiteStore,
    jobs: DurableJobStore,
    workflows: JobWorkflowRegistry,
    authority: any RolloutEffectAuthorizing
  ) {
    self.database = database
    self.jobs = jobs
    self.workflows = workflows
    self.authority = authority
  }

  public func reconcileStartedEffects(now: Date) async throws {
    _ = try await authority.reconcileLocalEffectResults(now: now)
    let rows = try await database.query(
      """
      SELECT jobs.id, MIN(reservation.mutation_intent_id) AS intent_id
      FROM jobs
      JOIN rollout_effect_reservations AS reservation ON reservation.job_id = jobs.id
      WHERE jobs.state IN ('reconciling', 'awaitingResolution')
        AND reservation.state IN ('sendStarted', 'observationRequired')
        AND reservation.mutation_intent_id IS NOT NULL
      GROUP BY jobs.id
      ORDER BY jobs.priority, jobs.created_at, jobs.id
      """
    )
    for row in rows {
      guard case .text(let idText)? = row["id"],
        let id = UUID(uuidString: idText),
        id.uuidString.lowercased() == idText,
        case .text(let intentIDText)? = row["intent_id"],
        let intentID = UUID(uuidString: intentIDText),
        intentID.uuidString.lowercased() == intentIDText,
        let job = try await jobs.job(id: id)
      else {
        throw JobCoordinatorInternalError.invalidRolloutReadback
      }
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .readback(jobID: id, intentID: intentID))
      ) {
        try await workflows.workflow(for: job.identity.kind).run(jobID: id)
      }
    }
  }
}

public enum JobWorkflowFailureDisposition: Equatable, Sendable {
  case transient(notBefore: Date)
  case piInterruptedUnknown
  case permanent
}

public protocol JobWorkflowFailureClassifying: Sendable {
  func classify(_ error: Error, now: Date) -> JobWorkflowFailureDisposition
}

public struct DefaultJobWorkflowFailureClassifier: JobWorkflowFailureClassifying, Sendable {
  public init() {}

  public func classify(_ error: Error, now: Date) -> JobWorkflowFailureDisposition {
    if error is URLError {
      return .transient(notBefore: now.addingTimeInterval(60))
    }
    if let broker = error as? GitHubBrokerError,
      case .unexpectedDisposition(_, let disposition) = broker
    {
      switch disposition {
      case .rateLimited(let directive):
        return .transient(notBefore: max(directive.notBefore, now.addingTimeInterval(1)))
      case .retryableRead, .reconcileRequired:
        return .transient(notBefore: now.addingTimeInterval(60))
      default:
        return .permanent
      }
    }
    if let process = error as? PiRPCProcessError {
      switch process {
      case .timeout, .spawnFailed, .readFailed, .writeFailed, .waitFailed:
        return .piInterruptedUnknown
      default:
        return .permanent
      }
    }
    if let herdr = error as? HerdrPiWorkflowError {
      switch herdr {
      case .launchSuppressed, .recoveryBoundaryReached:
        return .transient(notBefore: now.addingTimeInterval(1))
      case .topologyUnavailable, .roleHostUnavailable, .resultUnavailable,
        .runtimeFailure, .timedOut:
        return .piInterruptedUnknown
      case .invalidRequest, .invalidPreparation, .jobNotFound, .repositoryNotFound,
        .requestCollision, .resultDivergent:
        return .permanent
      }
    }
    if let command = error as? ApprovedCommandRunStoreError {
      switch command {
      case .launchSuppressed:
        return .transient(notBefore: now.addingTimeInterval(1))
      case .outcomeUnknown, .workspaceDiverged, .identityCollision, .divergentResult,
        .invalidRecord, .jobNotFound, .runNotFound, .invalidTransition, .decode:
        return .permanent
      }
    }
    if error as? GitPublicationError == .readBackUnavailable {
      return .transient(notBefore: now.addingTimeInterval(60))
    }
    return .permanent
  }
}

public struct JobWorkflowRegistry: Sendable {
  public let pullRequestReview: any JobWorkflowRunning
  public let issueTriage: any JobWorkflowRunning
  public let issueImplementation: any JobWorkflowRunning
  public let complexPlan: any JobWorkflowRunning

  public init(
    pullRequestReview: any JobWorkflowRunning,
    issueTriage: any JobWorkflowRunning,
    issueImplementation: any JobWorkflowRunning,
    complexPlan: any JobWorkflowRunning
  ) {
    self.pullRequestReview = pullRequestReview
    self.issueTriage = issueTriage
    self.issueImplementation = issueImplementation
    self.complexPlan = complexPlan
  }

  public func workflow(for kind: JobKind) -> any JobWorkflowRunning {
    switch kind {
    case .prReview: pullRequestReview
    case .issueTriage: issueTriage
    case .issueImplementation: issueImplementation
    case .complexPlan: complexPlan
    }
  }
}

public struct JobCoordinatorFailure: Equatable, Sendable {
  public let repositoryID: UUID?
  public let jobID: UUID?
  public let stage: String
  public let errorType: String
}

public struct JobCoordinatorSnapshot: Equatable, Sendable {
  public let lastPass: SchedulerPass?
  public let failures: [JobCoordinatorFailure]
}

public actor JobCoordinator: SchedulerPassRunner {
  private let configuration: ConfigurationStore
  private let discovery: GitHubDiscovery
  private let jobs: DurableJobStore
  private let repositories: RepositoryStore
  private let schedulerPersistence: SchedulerPersistence
  private let workflows: JobWorkflowRegistry
  private let rolloutAuthority: RolloutAuthorityStore?
  private let rolloutReadbacks: (any RolloutStartedEffectReconciling)?
  private let contractVersion: String
  private let failureClassifier: any JobWorkflowFailureClassifying
  private let newDispatchAllowed: @Sendable () async -> Bool
  private let now: @Sendable () -> Date
  private var lastPass: SchedulerPass?
  private var failures: [JobCoordinatorFailure] = []
  private var startupRecoveryCompleted = false

  public init(
    configuration: ConfigurationStore,
    discovery: GitHubDiscovery,
    jobs: DurableJobStore,
    repositories: RepositoryStore,
    schedulerPersistence: SchedulerPersistence,
    workflows: JobWorkflowRegistry,
    contractVersion: String,
    rolloutAuthority: RolloutAuthorityStore? = nil,
    rolloutReadbacks: (any RolloutStartedEffectReconciling)? = nil,
    failureClassifier: any JobWorkflowFailureClassifying = DefaultJobWorkflowFailureClassifier(),
    newDispatchAllowed: @escaping @Sendable () async -> Bool = { true },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.discovery = discovery
    self.jobs = jobs
    self.repositories = repositories
    self.schedulerPersistence = schedulerPersistence
    self.workflows = workflows
    self.contractVersion = contractVersion
    self.rolloutAuthority = rolloutAuthority
    self.rolloutReadbacks = rolloutReadbacks
    self.failureClassifier = failureClassifier
    self.newDispatchAllowed = newDispatchAllowed
    self.now = now
  }

  public func recoverAtStartup() async throws {
    guard !startupRecoveryCompleted else { return }
    if let rolloutAuthority {
      if let interrupted = try await rolloutAuthority.markInterruptedLaneRecoveryRequired(
        now: now()
      ) {
        _ = try await jobs.recoverRolloutAtStartup(
          authorizationID: interrupted.authorization.id,
          now: now()
        )
      }
    } else {
      _ = try await jobs.recoverAtStartup(now: now())
    }
    startupRecoveryCompleted = true
  }

  public func run(pass: SchedulerPass) async {
    lastPass = pass
    failures = []
    do {
      try await recoverAtStartup()
      let snapshot = try await configuration.snapshot()
      let rollout = try await rolloutAuthority?.activeStatus(now: now())
      if rolloutAuthority != nil, rollout == nil {
        guard let rolloutReadbacks else {
          throw JobCoordinatorInternalError.rolloutReadbackReconcilerMissing
        }
        try await rolloutReadbacks.reconcileStartedEffects(now: now())
        return
      }
      if rolloutAuthority == nil {
        try await dispatchCleanupRecovery()
      }
      try await dispatchRecovery(rollout: rollout)
      // Deadline promotion is durable bookkeeping only. The lease and workflow remain
      // behind the pause and dispatch gates below.
      try await dispatchDueRetries(rollout: rollout)
      let dispatchAllowed = await newDispatchAllowed()
      if snapshot.app.paused || !dispatchAllowed {
        try await dispatchCleanupRecovery()
        return
      }
      if let rollout {
        if rollout.scope.mode == .finiteWindow,
          let repository = snapshot.repositories.first(where: {
            $0.id == rollout.authorization.repositoryID
          })
        {
          guard await newDispatchAllowed() else { return }
          await RolloutEffectTaskContext.$current.withValue(
            RolloutEffectExecutionContext(mode: .discovery)
          ) {
            await discover(repository, rollout: rollout)
          }
        }
      } else {
        for repository in snapshot.repositories where repository.enabled {
          guard await newDispatchAllowed() else { break }
          await RolloutEffectTaskContext.$current.withValue(
            RolloutEffectExecutionContext(mode: .discovery)
          ) {
            await discover(repository, rollout: nil)
          }
        }
      }
      if await newDispatchAllowed() {
        try await dispatchWaitingHuman(rollout: rollout)
      }
      if await newDispatchAllowed() {
        try await dispatchQueuedJobs(rollout: rollout)
      }
      if let rollout {
        try await finalizeRollout(rollout)
      } else {
        try await dispatchCleanupRecovery()
      }
    } catch {
      failures.append(
        JobCoordinatorFailure(
          repositoryID: nil,
          jobID: nil,
          stage: "scheduler-pass",
          errorType: Self.errorType(error)
        )
      )
    }
  }

  private func dispatchWaitingHuman(rollout: RolloutStatusReport?) async throws {
    guard let rollout,
      rollout.scope.mode == .exactObject,
      rollout.scope.stage == .implementationExecute
    else { return }
    let waiting = try await jobs.jobs(nonTerminalOnly: true)
      .filter { $0.state == .waitingHuman && Self.admitted($0, by: rollout) }
      .sorted(by: Self.precedes)
    for job in waiting {
      guard await newDispatchAllowed() else { return }
      do {
        guard
          let repository = try await configuration.repository(
            id: job.identity.repositoryID
          ), Self.repository(repository, allows: job.identity.kind)
        else {
          throw JobCoordinatorInternalError.rolloutRepositoryUnavailable
        }
        try await jobs.requireActiveRolloutBinding(jobID: job.id, now: now())
        let workflow = workflows.workflow(for: job.identity.kind)
        guard let approval = workflow as? any IssueImplementationApprovalEvaluating else {
          throw JobCoordinatorInternalError.approvalEvaluatorMissing
        }
        _ = try await RolloutEffectTaskContext.$current.withValue(
          RolloutEffectExecutionContext(mode: .workflow(jobID: job.id))
        ) {
          try await approval.evaluateWaitingApproval(jobID: job.id)
        }
      } catch {
        await record(job: job, stage: "waiting-human-approval", error: error)
      }
    }
  }

  public func runReadbackOnly(pass: SchedulerPass) async {
    lastPass = pass
    failures = []
    do {
      guard rolloutAuthority != nil, let rolloutReadbacks else {
        throw JobCoordinatorInternalError.rolloutReadbackReconcilerMissing
      }
      try await rolloutReadbacks.reconcileStartedEffects(now: now())
    } catch {
      failures.append(
        JobCoordinatorFailure(
          repositoryID: nil,
          jobID: nil,
          stage: "rollout-readback",
          errorType: Self.errorType(error)
        )
      )
    }
  }

  public func snapshot() -> JobCoordinatorSnapshot {
    JobCoordinatorSnapshot(lastPass: lastPass, failures: failures)
  }

  public func runCanary(jobID: UUID) async throws {
    guard let leased = try await jobs.job(id: jobID),
      leased.identity.kind == .prReview,
      leased.state == .leased
    else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    do {
      let preparing = try await jobs.transition(
        jobID: leased.id,
        eventKey: eventKey(job: leased, suffix: "canary-inputs"),
        event: .inputsValidated,
        context: JobTransitionContext(
          now: now(),
          reason: "exact paused canary inputs selected"
        )
      )
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .historicalCanary(jobID: jobID))
      ) {
        try await workflows.workflow(for: .prReview).run(
          jobID: Self.job(from: preparing).id
        )
      }
    } catch {
      await failJob(leased, error: error, stage: "canary")
    }
  }

  public func runRecoveredCanary(
    jobID: UUID,
    recoveryEvidenceSHA256: String
  ) async throws {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    let recovered = try await jobs.resumedCanaryTopologyRecoveryJob(
      jobID: jobID,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256
    )
    guard recovered.identity.kind == .prReview,
      [.preparing, .runningPi].contains(recovered.state),
      recovered.currentStep == 0,
      recovered.currentStepKind == .review
    else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    do {
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .historicalCanary(jobID: jobID))
      ) {
        try await workflows.workflow(for: .prReview).runRecoveredCanary(
          jobID: recovered.id,
          recoveryEvidenceSHA256: recoveryEvidenceSHA256
        )
      }
    } catch {
      await failJob(recovered, error: error, stage: "canary-recovery")
    }
  }

  public func runCanaryPiFreshRetry(
    jobID: UUID,
    recoveryEvidenceSHA256: String,
    retryEvidenceSHA256: String
  ) async throws {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256),
      GitHubInputValidation.validSHA256(retryEvidenceSHA256)
    else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    let state = try await jobs.canaryPiFreshRetryState(
      jobID: jobID,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256,
      authorizedRetryEvidenceSHA256: retryEvidenceSHA256
    )
    guard state.job.identity.kind == .prReview else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    do {
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .historicalCanary(jobID: jobID))
      ) {
        try await workflows.workflow(for: .prReview).runCanaryPiFreshRetry(
          jobID: jobID,
          recoveryEvidenceSHA256: recoveryEvidenceSHA256,
          retryEvidenceSHA256: retryEvidenceSHA256
        )
      }
    } catch {
      await record(job: state.job, stage: "canary-pi-fresh-retry", error: error)
    }
  }

  public func runCanaryRoleHostReplacement(
    request: JobCanaryRoleHostReplacementRequest
  ) async throws {
    try request.validate()
    let state = try await jobs.canaryRoleHostReplacementState(request: request)
    guard state.retry.job.identity.kind == .prReview else {
      throw JobCoordinatorInternalError.invalidCanary
    }
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .historicalCanary(jobID: state.retry.job.id))
    ) {
      try await workflows.workflow(for: .prReview).runCanaryRoleHostReplacement(
        request: request
      )
    }
  }

  private func dispatchCleanupRecovery() async throws {
    let recoverable = try await jobs.jobs().filter {
      [.succeeded, .blocked, .waitingHuman].contains($0.state)
    }
    for job in recoverable {
      guard let workspace = try await repositories.workspaceRecord(jobID: job.id),
        workspace.cleanupState != .removed
      else { continue }
      if workspace.cleanupState == .retained {
        do {
          try await repositories.authorizeCleanup(jobID: job.id, now: now())
        } catch RepositoryStoreError.cleanupNotAuthorized {
          continue
        }
      }
      try await repositories.cleanupWorkspace(jobID: job.id, now: now())
    }
  }

  private func dispatchRecovery(rollout: RolloutStatusReport?) async throws {
    // An admitted canary without its append-only close record is human recovery
    // authority, never permission for startup to launch or substitute work.
    guard try await jobs.unresolvedCanaryJobID() == nil else { return }
    let current = try await jobs.jobs(nonTerminalOnly: true).filter {
      Self.admitted($0, by: rollout)
    }
    let recovery = current.filter { $0.state == .reconciliationQueued }.sorted(by: Self.precedes)
    for job in recovery {
      do {
        _ = try await jobs.transition(
          jobID: job.id,
          eventKey: eventKey(job: job, suffix: "recovery-lease"),
          event: .acquireRecoveryLease,
          context: JobTransitionContext(
            now: now(),
            reason: "recovery reconciliation acquired repository lease"
          )
        )
        if rolloutAuthority != nil {
          try await jobs.requireActiveRolloutBinding(
            jobID: job.id,
            now: now(),
            recovery: true
          )
        }
        try await runWorkflow(job)
        if let unresolved = try await jobs.job(id: job.id), unresolved.state == .reconciling {
          _ = try await jobs.transition(
            jobID: unresolved.id,
            eventKey: eventKey(job: unresolved, suffix: "recovery-retry"),
            event: .safeRetry,
            context: JobTransitionContext(
              now: now(),
              reason: "recovery completed read-back before a guarded step retry",
              notBefore: now().addingTimeInterval(1)
            )
          )
        }
      } catch DurableJobStoreError.rolloutAuthorityRequired,
        DurableJobStoreError.dispatchSuppressed
      {
        return
      } catch {
        await failJob(job, error: error, stage: "recovery")
      }
    }
    for job in current.filter({ $0.state == .awaitingResolution }).sorted(by: Self.precedes) {
      do {
        if rolloutAuthority != nil {
          try await jobs.requireActiveRolloutBinding(
            jobID: job.id,
            now: now(),
            recovery: true
          )
        }
        try await runWorkflow(job)
      } catch DurableJobStoreError.rolloutAuthorityRequired,
        DurableJobStoreError.dispatchSuppressed
      {
        return
      } catch {
        await record(job: job, stage: "late-read", error: error)
      }
    }
  }

  private func dispatchDueRetries(rollout: RolloutStatusReport?) async throws {
    if rollout?.scope.mode == .exactObject { return }
    let instant = now()
    let due = try await jobs.jobs(nonTerminalOnly: true)
      .filter { job in
        job.state == .retryBackoff && job.notBefore.map { $0 <= instant } == true
          && Self.admitted(job, by: rollout)
      }
      .sorted(by: Self.precedes)
    for job in due {
      if rolloutAuthority != nil {
        try await jobs.requireActiveRolloutBinding(jobID: job.id, now: instant)
      }
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job: job, suffix: "retry-deadline"),
        event: .retryDeadlineReached,
        context: JobTransitionContext(now: instant, reason: "persisted retry deadline reached")
      )
    }
  }

  private func discover(
    _ repository: RepositoryConfiguration,
    rollout: RolloutStatusReport?
  ) async {
    let instant = now()
    do {
      if let backoff = try await schedulerPersistence.backoff(repositoryID: repository.id),
        backoff.notBefore > instant
      {
        return
      }
      let reviewStageAllowed =
        rollout.map {
          [.prReview, .generatedPRReview].contains($0.scope.stage)
        } ?? true
      if repository.reviewEnabled && reviewStageAllowed {
        let observations = try await discovery.pullRequests(
          owner: repository.owner,
          repository: repository.name,
          repositoryID: repository.id,
          repositoryNodeID: repository.nodeID
        )
        guard await newDispatchAllowed() else { return }
        let candidates = observations.filter { $0.disposition == .candidate }.sorted {
          Self.candidatePrecedes(
            number: $0.pullRequest.number,
            nodeID: $0.pullRequest.nodeID,
            revisionKey: $0.pullRequest.head.sha,
            number: $1.pullRequest.number,
            nodeID: $1.pullRequest.nodeID,
            revisionKey: $1.pullRequest.head.sha
          )
        }
        for observation in candidates {
          guard await newDispatchAllowed() else { return }
          let revisionKey = observation.pullRequest.head.sha
          let rolloutBinding = Self.creationBinding(
            rollout: rollout,
            objectNodeID: observation.pullRequest.nodeID,
            objectNumber: observation.pullRequest.number,
            revisionKey: revisionKey
          )
          if rollout != nil, rolloutBinding == nil { continue }
          _ = try await jobs.createJob(
            identity: LogicalJobIdentity(
              repositoryID: repository.id,
              kind: .prReview,
              objectNodeID: observation.pullRequest.nodeID,
              revisionKey: revisionKey
            ),
            objectNumber: observation.pullRequest.number,
            contractVersionUsed: contractVersion,
            priority: .prReview,
            firstStep: .review,
            now: instant,
            requiresDispatchEligibility: true,
            rolloutBinding: rolloutBinding
          )
        }
      }
      let triageStageAllowed = rollout.map { $0.scope.stage == .issueTriage } ?? true
      if repository.triageEnabled && triageStageAllowed {
        let observations = try await discovery.issues(
          owner: repository.owner,
          repository: repository.name,
          repositoryID: repository.id
        )
        guard await newDispatchAllowed() else { return }
        let candidates = observations.filter { $0.disposition == .candidate }.sorted {
          Self.candidatePrecedes(
            number: $0.issue.number,
            nodeID: $0.issue.nodeID,
            revisionKey: "initial-triage",
            number: $1.issue.number,
            nodeID: $1.issue.nodeID,
            revisionKey: "initial-triage"
          )
        }
        for observation in candidates {
          guard await newDispatchAllowed() else { return }
          let revisionKey = "initial-triage"
          let rolloutBinding = Self.creationBinding(
            rollout: rollout,
            objectNodeID: observation.issue.nodeID,
            objectNumber: observation.issue.number,
            revisionKey: revisionKey
          )
          if rollout != nil, rolloutBinding == nil { continue }
          _ = try await jobs.createJob(
            identity: LogicalJobIdentity(
              repositoryID: repository.id,
              kind: .issueTriage,
              objectNodeID: observation.issue.nodeID,
              revisionKey: revisionKey
            ),
            objectNumber: observation.issue.number,
            contractVersionUsed: contractVersion,
            priority: .triage,
            firstStep: .triage,
            now: instant,
            requiresDispatchEligibility: true,
            rolloutBinding: rolloutBinding
          )
        }
      }
      let implementationStageAllowed =
        rollout.map {
          $0.scope.stage == .implementationPlan || $0.scope.stage == .implementationExecute
        } ?? true
      let implementationDispatchAllowed = await newDispatchAllowed()
      if repository.implementationEnabled
        && implementationStageAllowed
        && implementationDispatchAllowed
      {
        try await discoverImplementation(repository, rollout: rollout, now: instant)
      }
      try await schedulerPersistence.recordSuccess(repositoryID: repository.id)
    } catch DurableJobStoreError.dispatchSuppressed {
      return
    } catch {
      _ = try? await schedulerPersistence.recordFailure(
        repositoryID: repository.id,
        reason: "discovery-\(Self.errorType(error))",
        now: instant
      )
      failures.append(
        JobCoordinatorFailure(
          repositoryID: repository.id,
          jobID: nil,
          stage: "discovery",
          errorType: Self.errorType(error)
        )
      )
    }
  }

  private func discoverImplementation(
    _ repository: RepositoryConfiguration,
    rollout: RolloutStatusReport?,
    now instant: Date
  ) async throws {
    let observations = try await discovery.implementationIssues(
      owner: repository.owner,
      repository: repository.name,
      repositoryID: repository.id
    )
    guard await newDispatchAllowed() else { return }
    for observation in observations.sorted(by: {
      if $0.issue.number != $1.issue.number { return $0.issue.number < $1.issue.number }
      return $0.issue.nodeID < $1.issue.nodeID
    }) {
      guard await newDispatchAllowed() else { return }
      guard case .candidate(let kind) = observation.disposition else { continue }
      switch kind {
      case .ready:
        if let rollout, rollout.scope.stage != .implementationPlan { continue }
        let generation = try await jobs.nextClaimGeneration(
          issueNodeID: observation.issue.nodeID
        )
        let revisionKey = "claim-\(generation)"
        let rolloutBinding = Self.creationBinding(
          rollout: rollout,
          objectNodeID: observation.issue.nodeID,
          objectNumber: observation.issue.number,
          revisionKey: revisionKey
        )
        if rollout != nil, rolloutBinding == nil { continue }
        _ = try await jobs.createJob(
          identity: LogicalJobIdentity(
            repositoryID: repository.id,
            kind: .issueImplementation,
            objectNodeID: observation.issue.nodeID,
            revisionKey: revisionKey
          ),
          objectNumber: observation.issue.number,
          contractVersionUsed: contractVersion,
          priority: .issueImplementation,
          firstStep: .claimReady,
          now: instant,
          requiresDispatchEligibility: true,
          rolloutBinding: rolloutBinding
        )
      case .approvedComplex:
        if let rollout, rollout.scope.stage != .implementationExecute { continue }
        let waiting = try await jobs.jobs(nonTerminalOnly: true).filter {
          $0.identity.repositoryID == repository.id
            && $0.identity.objectNodeID == observation.issue.nodeID
            && ($0.identity.kind == .issueImplementation || $0.identity.kind == .complexPlan)
            && $0.state == .waitingHuman
        }
        guard waiting.count == 1, let job = waiting.first else {
          throw JobCoordinatorInternalError.approvalWithoutWaitingJob
        }
        let workflow = workflows.workflow(for: job.identity.kind)
        guard let approval = workflow as? any IssueImplementationApprovalEvaluating else {
          throw JobCoordinatorInternalError.approvalEvaluatorMissing
        }
        if rolloutAuthority != nil {
          try await jobs.requireActiveRolloutBinding(jobID: job.id, now: now())
        }
        _ = try await RolloutEffectTaskContext.$current.withValue(
          RolloutEffectExecutionContext(mode: .workflow(jobID: job.id))
        ) {
          try await approval.evaluateWaitingApproval(jobID: job.id)
        }
      }
    }
  }

  private func dispatchQueuedJobs(rollout: RolloutStatusReport?) async throws {
    let queued = try await jobs.jobs(nonTerminalOnly: true)
      .filter { $0.state == .queued && Self.admitted($0, by: rollout) }
      .sorted(by: Self.precedes)
    for original in queued {
      guard await newDispatchAllowed() else { return }
      guard
        let repository = try await configuration.repository(
          id: original.identity.repositoryID
        ), Self.repository(repository, allows: original.identity.kind)
      else {
        if rollout != nil {
          await record(
            job: original,
            stage: "dispatch",
            error: JobCoordinatorInternalError.rolloutRepositoryUnavailable
          )
        }
        continue
      }
      do {
        let leased = try await jobs.transition(
          jobID: original.id,
          eventKey: eventKey(job: original, suffix: "lease"),
          event: .acquireLease,
          context: JobTransitionContext(
            now: now(),
            reason: "scheduler selected queued job"
          )
        )
        let leasedJob = Self.job(from: leased)
        let preparing = try await jobs.transition(
          jobID: leasedJob.id,
          eventKey: eventKey(job: leasedJob, suffix: "inputs"),
          event: .inputsValidated,
          context: JobTransitionContext(
            now: now(),
            reason: "job inputs selected for validation"
          )
        )
        if rolloutAuthority != nil {
          try await jobs.requireActiveRolloutBinding(jobID: original.id, now: now())
        }
        try await runWorkflow(Self.job(from: preparing))
      } catch DurableJobStoreError.globalConcurrencyReached,
        DurableJobStoreError.dispatchSuppressed,
        DurableJobStoreError.rolloutAuthorityRequired
      {
        return
      } catch DurableJobStoreError.repositoryAlreadyLeased {
        continue
      } catch {
        await failJob(original, error: error)
      }
    }
  }

  private func finalizeRollout(_ rollout: RolloutStatusReport) async throws {
    guard let rolloutAuthority else { return }
    let current = try await rolloutAuthority.status(
      authorizationID: rollout.authorization.id
    )
    var boundJobs: [JobRecord] = []
    boundJobs.reserveCapacity(current.boundJobIDs.count)
    for id in current.boundJobIDs {
      if let job = try await jobs.job(id: id) {
        boundJobs.append(job)
      }
    }
    guard boundJobs.count == current.boundJobIDs.count else {
      _ = try await rolloutAuthority.markRecoveryRequired(
        authorizationID: current.authorization.id,
        reasonCode: "BOUND_JOB_MISSING",
        now: now()
      )
      return
    }

    let unsettled = current.reservations.filter { $0.state != .settled }
    if boundJobs.contains(where: Self.requiresReadback)
      || unsettled.contains(where: Self.requiresReadback)
    {
      _ = try await rolloutAuthority.markRecoveryRequired(
        authorizationID: current.authorization.id,
        reasonCode: "EFFECT_READBACK_REQUIRED",
        now: now()
      )
      return
    }

    if current.scope.mode == .exactObject,
      !failures.filter({ failure in
        failure.jobID.map(current.boundJobIDs.contains) ?? true
      }).isEmpty || boundJobs.contains(where: { $0.state == .retryBackoff })
    {
      _ = try await rolloutAuthority.fail(
        authorizationID: current.authorization.id,
        reasonCode: "EXACT_STAGE_FAILED",
        now: now()
      )
      return
    }

    let completed = boundJobs.allSatisfy { Self.completed($0, for: current.scope.stage) }
    let reachedWindowCap =
      current.scope.mode == .exactObject
      || current.remainingBudgets.jobs == 0
    guard completed, reachedWindowCap else { return }
    guard unsettled.isEmpty else {
      _ = try await rolloutAuthority.fail(
        authorizationID: current.authorization.id,
        reasonCode: "UNSETTLED_EFFECT",
        now: now()
      )
      return
    }

    let checkpoint = try Self.checkpointSHA256(
      authorizationID: current.authorization.id,
      stage: current.scope.stage,
      jobs: boundJobs
    )
    _ = try await rolloutAuthority.settle(
      authorizationID: rollout.authorization.id,
      checkpointSHA256: checkpoint,
      now: now()
    )
  }

  private func failJob(
    _ original: JobRecord,
    error: Error,
    stage: String = "dispatch"
  ) async {
    await record(job: original, stage: stage, error: error)
    guard let current = try? await jobs.job(id: original.id) else { return }
    if current.state == .leased {
      do {
        _ = try await jobs.transition(
          jobID: current.id,
          eventKey: eventKey(job: current, suffix: "failed-inputs"),
          event: .inputsValidated,
          context: JobTransitionContext(
            now: now(),
            reason: "job setup failed before input validation completed"
          )
        )
        guard let preparing = try await jobs.job(id: current.id) else { return }
        await failJob(preparing, error: error, stage: stage)
      } catch {
        await record(job: current, stage: "block", error: error)
      }
      return
    }
    let instant = now()
    let classification = failureClassifier.classify(error, now: instant)
    let event: JobEvent
    let context: JobTransitionContext
    switch classification {
    case .transient(let notBefore):
      switch current.state {
      case .preparing: event = .transientSetupFailure
      case .runningPi: event = .transientPiFailure
      case .executing: event = .transientLocalFailure
      case .reconciling: event = .safeRetry
      default: return
      }
      context = JobTransitionContext(
        now: instant,
        reason: "job coordinator scheduled retry after \(Self.errorType(error))",
        notBefore: notBefore
      )
    case .piInterruptedUnknown:
      guard current.state == .runningPi else { return }
      event = .piInterruptedUnknown
      context = JobTransitionContext(
        now: instant,
        reason: "Pi interruption requires workspace reconciliation"
      )
    case .permanent:
      switch current.state {
      case .preparing: event = .permanentSetupFailure
      case .runningPi: event = .piPermanentFailure
      case .executing: event = .localPermanentFailure
      case .reconciling: event = .reconciliationPermanentFailure
      default: return
      }
      context = JobTransitionContext(
        now: instant,
        reason: "job coordinator blocked after \(Self.errorType(error))"
      )
    }
    _ = try? await jobs.transition(
      jobID: current.id,
      eventKey: eventKey(
        job: current,
        suffix: classification == .permanent
          ? "blocked"
          : classification == .piInterruptedUnknown ? "pi-interrupted" : "retry"
      ),
      event: event,
      context: context
    )
  }

  private func runWorkflow(_ job: JobRecord) async throws {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: job.id))
    ) {
      try await workflows.workflow(for: job.identity.kind).run(jobID: job.id)
    }
  }

  private func record(job: JobRecord, stage: String, error: Error) async {
    failures.append(
      JobCoordinatorFailure(
        repositoryID: job.identity.repositoryID,
        jobID: job.id,
        stage: stage,
        errorType: Self.errorType(error)
      )
    )
  }

  private func eventKey(job: JobRecord, suffix: String) -> String {
    "job:\(job.id.uuidString.lowercased()):a\(job.attempt):s\(job.currentStep):\(suffix)"
  }

  private static func precedes(_ lhs: JobRecord, _ rhs: JobRecord) -> Bool {
    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func admitted(
    _ job: JobRecord,
    by rollout: RolloutStatusReport?
  ) -> Bool {
    guard let rollout else { return true }
    return rollout.boundJobIDs.contains(job.id)
      && rollout.authorization.repositoryID == job.identity.repositoryID
      && rollout.scope.stage.accepts(jobKind: job.identity.kind)
  }

  private static func repository(
    _ repository: RepositoryConfiguration,
    allows kind: JobKind
  ) -> Bool {
    guard repository.enabled else { return false }
    switch kind {
    case .prReview: return repository.reviewEnabled
    case .issueTriage: return repository.triageEnabled
    case .issueImplementation, .complexPlan: return repository.implementationEnabled
    }
  }

  private static func completed(
    _ job: JobRecord,
    for stage: RolloutWorkflowStage
  ) -> Bool {
    if job.state.isTerminal { return true }
    switch stage {
    case .implementationPlan:
      return job.state == .waitingHuman
        || (job.state == .queued && job.currentStepKind == .orchestrate)
    case .implementationExecute:
      return job.state == .queued && job.currentStepKind == .replan
    case .prReview, .issueTriage, .generatedPRReview:
      return false
    }
  }

  private static func requiresReadback(_ job: JobRecord) -> Bool {
    [.reconciling, .reconciliationQueued, .awaitingResolution].contains(job.state)
  }

  private static func requiresReadback(_ reservation: RolloutEffectReservation) -> Bool {
    [.sendStarted, .observationRequired, .attributed].contains(reservation.state)
  }

  private static func checkpointSHA256(
    authorizationID: String,
    stage: RolloutWorkflowStage,
    jobs: [JobRecord]
  ) throws -> String {
    let receipt = RolloutStageCheckpoint(
      authorizationID: authorizationID,
      stage: stage,
      jobs: jobs.sorted(by: Self.precedes).map {
        RolloutStageCheckpoint.Job(
          id: $0.id.uuidString.lowercased(),
          state: $0.state,
          attempt: $0.attempt,
          currentStep: $0.currentStep,
          currentStepKind: $0.currentStepKind,
          terminalReason: $0.terminalReason
        )
      }
    )
    return RolloutCanonicalJSON.sha256(try RolloutCanonicalJSON.encode(receipt))
  }

  private static func creationBinding(
    rollout: RolloutStatusReport?,
    objectNodeID: String,
    objectNumber: Int,
    revisionKey: String
  ) -> RolloutJobCreationBinding? {
    guard let rollout else { return nil }
    guard rollout.scope.mode == .finiteWindow,
      let window = rollout.scope.finiteWindow
    else {
      return nil
    }
    let candidateSHA256: String
    if let candidate = window.candidates.first(where: {
      $0.nodeID == objectNodeID && $0.number == objectNumber
        && $0.revisionKey == revisionKey
    }) {
      candidateSHA256 = candidate.canonicalInputSHA256
    } else {
      guard window.allowsFutureObjects,
        objectNumber > window.observedObjectNumberUpperBound,
        objectNumber <= window.maximumFutureObjectNumber,
        let digest = try? RolloutPreviewBuilder.futureCandidateSHA256(
          scope: rollout.scope,
          nodeID: objectNodeID,
          number: objectNumber,
          revisionKey: revisionKey
        )
      else {
        return nil
      }
      candidateSHA256 = digest
    }
    return RolloutJobCreationBinding(
      authorizationID: rollout.authorization.id,
      workflowStage: rollout.scope.stage,
      canonicalInputSHA256: candidateSHA256
    )
  }

  private static func candidatePrecedes(
    number lhsNumber: Int,
    nodeID lhsNodeID: String,
    revisionKey lhsRevisionKey: String,
    number rhsNumber: Int,
    nodeID rhsNodeID: String,
    revisionKey rhsRevisionKey: String
  ) -> Bool {
    if lhsNumber != rhsNumber { return lhsNumber < rhsNumber }
    if lhsNodeID != rhsNodeID { return lhsNodeID < rhsNodeID }
    return lhsRevisionKey < rhsRevisionKey
  }

  private static func job(from transition: JobTransitionResult) -> JobRecord {
    switch transition {
    case .applied(let job), .duplicate(let job): job
    }
  }

  private static func errorType(_ error: Error) -> String {
    String(reflecting: type(of: error))
  }
}

private struct RolloutStageCheckpoint: Codable {
  struct Job: Codable {
    let id: String
    let state: JobState
    let attempt: Int
    let currentStep: Int
    let currentStepKind: JobStepKind?
    let terminalReason: String?
  }

  let authorizationID: String
  let stage: RolloutWorkflowStage
  let jobs: [Job]
}

private enum JobCoordinatorInternalError: Error {
  case approvalWithoutWaitingJob
  case approvalEvaluatorMissing
  case invalidCanary
  case invalidRolloutReadback
  case rolloutReadbackReconcilerMissing
  case rolloutRepositoryUnavailable
}
