import Foundation

public protocol JobWorkflowRunning: Sendable {
  func run(jobID: UUID) async throws
}

public protocol IssueImplementationApprovalEvaluating: Sendable {
  @discardableResult
  func evaluateWaitingApproval(jobID: UUID) async throws -> JobRecord
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
  private let contractVersion: String
  private let failureClassifier: any JobWorkflowFailureClassifying
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
    failureClassifier: any JobWorkflowFailureClassifying = DefaultJobWorkflowFailureClassifier(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.discovery = discovery
    self.jobs = jobs
    self.repositories = repositories
    self.schedulerPersistence = schedulerPersistence
    self.workflows = workflows
    self.contractVersion = contractVersion
    self.failureClassifier = failureClassifier
    self.now = now
  }

  public func run(pass: SchedulerPass) async {
    lastPass = pass
    failures = []
    do {
      if !startupRecoveryCompleted {
        _ = try await jobs.recoverAtStartup(now: now())
        startupRecoveryCompleted = true
      }
      let snapshot = try await configuration.snapshot()
      try await dispatchCleanupRecovery()
      try await dispatchRecovery()
      try await dispatchDueRetries()
      if snapshot.app.paused {
        try await dispatchCleanupRecovery()
        return
      }
      for repository in snapshot.repositories where repository.enabled {
        await discover(repository)
      }
      try await dispatchQueuedJobs()
      try await dispatchCleanupRecovery()
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

  public func snapshot() -> JobCoordinatorSnapshot {
    JobCoordinatorSnapshot(lastPass: lastPass, failures: failures)
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

  private func dispatchRecovery() async throws {
    let current = try await jobs.jobs(nonTerminalOnly: true)
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
        try await workflows.workflow(for: job.identity.kind).run(jobID: job.id)
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
      } catch {
        await failJob(job, error: error, stage: "recovery")
      }
    }
    for job in current.filter({ $0.state == .awaitingResolution }).sorted(by: Self.precedes) {
      do {
        try await workflows.workflow(for: job.identity.kind).run(jobID: job.id)
      } catch {
        await record(job: job, stage: "late-read", error: error)
      }
    }
  }

  private func dispatchDueRetries() async throws {
    let instant = now()
    let due = try await jobs.jobs(nonTerminalOnly: true)
      .filter { job in
        job.state == .retryBackoff && job.notBefore.map { $0 <= instant } == true
      }
      .sorted(by: Self.precedes)
    for job in due {
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: eventKey(job: job, suffix: "retry-deadline"),
        event: .retryDeadlineReached,
        context: JobTransitionContext(now: instant, reason: "persisted retry deadline reached")
      )
    }
  }

  private func discover(_ repository: RepositoryConfiguration) async {
    let instant = now()
    do {
      if let backoff = try await schedulerPersistence.backoff(repositoryID: repository.id),
        backoff.notBefore > instant
      {
        return
      }
      if repository.reviewEnabled {
        for observation in try await discovery.pullRequests(
          owner: repository.owner,
          repository: repository.name,
          repositoryID: repository.id,
          repositoryNodeID: repository.nodeID
        ) where observation.disposition == .candidate {
          _ = try await jobs.createJob(
            identity: LogicalJobIdentity(
              repositoryID: repository.id,
              kind: .prReview,
              objectNodeID: observation.pullRequest.nodeID,
              revisionKey: observation.pullRequest.head.sha
            ),
            objectNumber: observation.pullRequest.number,
            contractVersionUsed: contractVersion,
            priority: .prReview,
            firstStep: .review,
            now: instant
          )
        }
      }
      if repository.triageEnabled {
        for observation in try await discovery.issues(
          owner: repository.owner,
          repository: repository.name,
          repositoryID: repository.id
        ) where observation.disposition == .candidate {
          _ = try await jobs.createJob(
            identity: LogicalJobIdentity(
              repositoryID: repository.id,
              kind: .issueTriage,
              objectNodeID: observation.issue.nodeID,
              revisionKey: "initial-triage"
            ),
            objectNumber: observation.issue.number,
            contractVersionUsed: contractVersion,
            priority: .triage,
            firstStep: .triage,
            now: instant
          )
        }
      }
      if repository.implementationEnabled {
        try await discoverImplementation(repository, now: instant)
      }
      try await schedulerPersistence.recordSuccess(repositoryID: repository.id)
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
    now instant: Date
  ) async throws {
    let observations = try await discovery.implementationIssues(
      owner: repository.owner,
      repository: repository.name,
      repositoryID: repository.id
    )
    for observation in observations {
      guard case .candidate(let kind) = observation.disposition else { continue }
      switch kind {
      case .ready:
        let generation = try await jobs.nextClaimGeneration(
          issueNodeID: observation.issue.nodeID
        )
        _ = try await jobs.createJob(
          identity: LogicalJobIdentity(
            repositoryID: repository.id,
            kind: .issueImplementation,
            objectNodeID: observation.issue.nodeID,
            revisionKey: "claim-\(generation)"
          ),
          objectNumber: observation.issue.number,
          contractVersionUsed: contractVersion,
          priority: .issueImplementation,
          firstStep: .claimReady,
          now: instant
        )
      case .approvedComplex:
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
        _ = try await approval.evaluateWaitingApproval(jobID: job.id)
      }
    }
  }

  private func dispatchQueuedJobs() async throws {
    let queued = try await jobs.jobs(nonTerminalOnly: true)
      .filter { $0.state == .queued }
      .sorted(by: Self.precedes)
    for original in queued {
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
        try await workflows.workflow(for: original.identity.kind).run(
          jobID: Self.job(from: preparing).id
        )
      } catch DurableJobStoreError.globalConcurrencyReached {
        return
      } catch DurableJobStoreError.repositoryAlreadyLeased {
        continue
      } catch {
        await failJob(original, error: error)
      }
    }
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

  private static func job(from transition: JobTransitionResult) -> JobRecord {
    switch transition {
    case .applied(let job), .duplicate(let job): job
    }
  }

  private static func errorType(_ error: Error) -> String {
    String(reflecting: type(of: error))
  }
}

private enum JobCoordinatorInternalError: Error {
  case approvalWithoutWaitingJob
  case approvalEvaluatorMissing
}
