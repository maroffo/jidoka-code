import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("End-to-end scheduler job coordinator")
struct JobCoordinatorTests {
  @Test("Pi transport interruption is classified as unknown writer state, never blind retry")
  func piInterruptionClassification() {
    let classification = DefaultJobWorkflowFailureClassifier().classify(
      PiRPCProcessError.timeout(abortAcknowledged: true),
      now: Date(timeIntervalSince1970: 50_000)
    )
    #expect(classification == .piInterruptedUnknown)
  }

  @Test("W0: an unscoped pass cannot dispatch two serial queued jobs")
  func unscopedPassDoesNotWalkQueue() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    try await fixture.configuration.setMaxConcurrency(1, now: fixture.now)
    for number in 1...2 {
      _ = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .prReview,
          objectNodeID: "unscoped-pr-\(number)",
          revisionKey: String(repeating: String(number), count: 40)
        ),
        objectNumber: number,
        contractVersionUsed: "w0-rollout-baseline",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now.addingTimeInterval(TimeInterval(number))
      )
    }

    await fixture.coordinator().run(
      pass: SchedulerPass(reasons: [.resume], startedAt: fixture.now)
    )

    #expect(await fixture.workflows.order().isEmpty)
    #expect(try await fixture.jobs.jobs().allSatisfy { $0.state == .queued })
  }

  @Test("one pass dispatches only the exact bound workflow and leaves other jobs queued")
  func exactScopeIsolation() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    try await fixture.configuration.setMaxConcurrency(1, now: fixture.now)
    guard
      case .created(let reviewJob) = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .prReview,
          objectNodeID: "exact-review",
          revisionKey: String(repeating: "a", count: 40)
        ),
        objectNumber: 4,
        contractVersionUsed: "w6-test",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now
      ),
      case .created(let implementationJob) = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .issueImplementation,
          objectNodeID: "outside-implementation",
          revisionKey: "claim-1"
        ),
        objectNumber: 11,
        contractVersionUsed: "w6-test",
        priority: .issueImplementation,
        firstStep: .claimReady,
        now: fixture.now.addingTimeInterval(1)
      ),
      case .created(let triageJob) = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .issueTriage,
          objectNodeID: "outside-triage",
          revisionKey: "initial-triage"
        ),
        objectNumber: 10,
        contractVersionUsed: "w6-test",
        priority: .triage,
        firstStep: .triage,
        now: fixture.now.addingTimeInterval(2)
      )
    else {
      Issue.record("coordinator isolation fixture was suppressed")
      return
    }
    await fixture.api.configure(pullRequests: [], issues: [])
    let coordinator = fixture.coordinator(rolloutAuthority: fixture.rolloutAuthority)
    try await coordinator.recoverAtStartup()
    try await fixture.activateExactReviewScope(
      repository: repository,
      job: reviewJob
    )

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now)
    )

    let jobs = try await fixture.jobs.jobs()
    #expect(jobs.count == 3)
    #expect(try await fixture.jobs.job(id: reviewJob.id)?.state == .blocked)
    #expect(try await fixture.jobs.job(id: implementationJob.id)?.state == .queued)
    #expect(try await fixture.jobs.job(id: triageJob.id)?.state == .queued)
    #expect(await fixture.workflows.order() == [.prReview])
    #expect((await coordinator.snapshot()).failures.isEmpty)
  }

  @Test("direct canary runs exactly one leased job and never walks the queue")
  func directCanaryDoesNotWalkQueue() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    var jobs: [JobRecord] = []
    for number in 1...2 {
      let creation = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .prReview,
          objectNodeID: "canary-pr-\(number)",
          revisionKey: String(repeating: String(number), count: 40)
        ),
        objectNumber: number,
        contractVersionUsed: "w7-canary-test",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now.addingTimeInterval(TimeInterval(number))
      )
      guard case .created(let job) = creation else {
        Issue.record("canary queue fixture was suppressed")
        return
      }
      jobs.append(job)
    }
    try await fixture.activateExactReviewScope(repository: repository, job: jobs[0])
    _ = try await fixture.jobs.transition(
      jobID: jobs[0].id,
      eventKey: "direct-canary:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "exact canary lease")
    )

    try await fixture.coordinator().runCanary(jobID: jobs[0].id)

    #expect((await fixture.workflows.order()) == [.prReview])
    #expect(try await fixture.jobs.job(id: jobs[0].id)?.state == .blocked)
    #expect(try await fixture.jobs.job(id: jobs[1].id)?.state == .queued)
  }

  @Test("W0: repository flag drift leaves an already queued job inert")
  func disabledRepositoryFiltersQueuedJob() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "already-queued-pr",
        revisionKey: String(repeating: "9", count: 40)
      ),
      objectNumber: 9,
      contractVersionUsed: "w7-canary-reproduction",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("queued reproduction job was suppressed")
      return
    }
    try await fixture.configuration.upsertRepository(
      RepositoryConfiguration(
        id: repository.id,
        nodeID: repository.nodeID,
        owner: repository.owner,
        name: repository.name,
        defaultBranch: repository.defaultBranch,
        reviewEnabled: repository.reviewEnabled,
        triageEnabled: repository.triageEnabled,
        implementationEnabled: repository.implementationEnabled,
        enabled: false
      ),
      now: fixture.now
    )

    await fixture.coordinator().run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now)
    )

    #expect((await fixture.workflows.order()).isEmpty)
    #expect(try await fixture.jobs.job(id: job.id)?.state == .queued)
  }

  @Test("reconciliation dispatch runs before any new discovery read")
  func recoveryFirst() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    let created = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "recovery-pr",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 3,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = created else {
      Issue.record("recovery job was suppressed")
      return
    }
    try await fixture.activateExactReviewScope(repository: repository, job: job)
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'reconciliationQueued' WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )
    await fixture.api.configure(pullRequests: [], issues: [])
    let coordinator = fixture.coordinator()

    await coordinator.run(
      pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now)
    )

    let events = await fixture.events.values()
    #expect(events.first == "workflow:prReview:reconciling")
    #expect(events.contains("api:pulls"))
    #expect(
      events.firstIndex(of: "workflow:prReview:reconciling")! < events.firstIndex(of: "api:pulls")!)
    #expect(try await fixture.jobs.job(id: job.id)?.state == .blocked)
  }

  @Test("W0: pause suppresses unbound recovery as well as discovery")
  func pausedDispatchGateSuppressesRecovery() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "gated-recovery-pr",
        revisionKey: String(repeating: "d", count: 40)
      ),
      objectNumber: 19,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let recoveryJob) = creation else {
      Issue.record("gated recovery job was suppressed")
      return
    }
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'reconciliationQueued' WHERE id = ?",
      bindings: [.text(recoveryJob.id.uuidString.lowercased())]
    )
    try await fixture.configuration.setPaused(true, now: fixture.now)
    await fixture.api.configure(
      pullRequests: [pullRequest(number: 4)],
      issues: [issue(number: 10, labels: [])]
    )
    let coordinator = fixture.coordinator(newDispatchAllowed: { false })

    await coordinator.run(
      pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now)
    )

    let jobs = try await fixture.jobs.jobs()
    #expect(jobs.count == 1)
    #expect(jobs.first?.id == recoveryJob.id)
    #expect(jobs.first?.state == .reconciliationQueued)
    #expect(!(await fixture.events.values()).contains("workflow:prReview:reconciling"))
    #expect(!(await fixture.events.values()).contains("api:pulls"))
    #expect(!(await fixture.events.values()).contains("api:issues"))
    #expect((await coordinator.snapshot()).failures.isEmpty)
  }

  @Test("durable pause atomically rejects discovery creation and new leases")
  func durablePauseGate() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    try await fixture.configuration.setPaused(true, now: fixture.now)
    await #expect(throws: DurableJobStoreError.dispatchSuppressed) {
      _ = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .prReview,
          objectNodeID: "paused-discovery",
          revisionKey: String(repeating: "e", count: 40)
        ),
        objectNumber: 20,
        contractVersionUsed: "w7-pause-test",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now,
        requiresDispatchEligibility: true
      )
    }
    let queued = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "paused-lease",
        revisionKey: String(repeating: "f", count: 40)
      ),
      objectNumber: 21,
      contractVersionUsed: "w7-pause-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = queued else {
      Issue.record("pause lease fixture was suppressed")
      return
    }
    await #expect(throws: DurableJobStoreError.dispatchSuppressed) {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: "pause-gate:lease",
        event: .acquireLease,
        context: JobTransitionContext(now: fixture.now, reason: "must be suppressed")
      )
    }
  }

  @Test("startup sweep finishes cleanup stranded by a terminal crash boundary")
  func startupCleanupSweep() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    await fixture.api.configure(pullRequests: [], issues: [])
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "terminal-cleanup-pr",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 14,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("cleanup recovery job was suppressed")
      return
    }
    try await fixture.activateExactReviewScope(repository: repository, job: job)
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "cleanup-fixture:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "cleanup fixture lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "cleanup-fixture:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "cleanup fixture inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "cleanup-fixture:execute",
      event: .selectLocalStep,
      context: JobTransitionContext(now: fixture.now, reason: "cleanup fixture execute")
    )
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "cleanup-fixture:blocked",
      event: .localPermanentFailure,
      context: JobTransitionContext(now: fixture.now, reason: "terminal before cleanup")
    )
    let jobDirectory = fixture.repositories.workspacesURL.appendingPathComponent(
      job.id.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: jobDirectory.appendingPathComponent("repository", isDirectory: true),
      withIntermediateDirectories: true
    )
    try await fixture.database.execute(
      """
      INSERT INTO workspaces(
        job_id, relative_path, base_branch, base_sha,
        local_head_sha, cleanup_state, updated_at
      ) VALUES (?, ?, 'main', ?, ?, 'eligible', ?)
      """,
      bindings: [
        .text(job.id.uuidString.lowercased()),
        .text("\(job.id.uuidString.lowercased())/repository"),
        .text(String(repeating: "a", count: 40)),
        .text(String(repeating: "a", count: 40)),
        .real(fixture.now.timeIntervalSince1970),
      ]
    )

    await fixture.coordinator().run(
      pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now)
    )

    #expect(try await fixture.repositories.workspaceRecord(jobID: job.id)?.cleanupState == .removed)
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test("the first real scheduler pass recovers an interrupted leased job before discovery")
  func firstPassRunsStartupRecovery() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    await fixture.api.configure(pullRequests: [], issues: [])
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "startup-interrupted-pr",
        revisionKey: String(repeating: "f", count: 40)
      ),
      objectNumber: 12,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("startup recovery job was suppressed")
      return
    }
    try await fixture.activateExactReviewScope(repository: repository, job: job)
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "startup-fixture:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "interrupted lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "startup-fixture:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "interrupted preparation")
    )
    let workflow = CoordinatorPassiveRecoveryWorkflow()
    let coordinator = JobCoordinator(
      configuration: fixture.configuration,
      discovery: GitHubDiscovery(
        api: fixture.api,
        jobs: fixture.jobs,
        reviewedRevisions: fixture.reviewed
      ),
      jobs: fixture.jobs,
      repositories: fixture.repositories,
      schedulerPersistence: fixture.persistence,
      workflows: JobWorkflowRegistry(
        pullRequestReview: workflow,
        issueTriage: workflow,
        issueImplementation: workflow,
        complexPlan: workflow
      ),
      contractVersion: "w6-test",
      rolloutAuthority: nil,
      now: { fixture.now }
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now))

    let recovered = try #require(try await fixture.jobs.job(id: job.id))
    #expect(recovered.state == .retryBackoff)
    #expect(recovered.currentStepKind == .review)
    #expect(try await fixture.jobs.activeLeases().isEmpty)
  }

  @Test("recovery that needs a guarded rerun preserves the current step in backoff")
  func recoveryRetry() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    await fixture.api.configure(pullRequests: [], issues: [])
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "recoverable-pr",
        revisionKey: String(repeating: "e", count: 40)
      ),
      objectNumber: 6,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("recoverable job was suppressed")
      return
    }
    try await fixture.activateExactReviewScope(repository: repository, job: job)
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'reconciliationQueued', current_step = 4 WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )
    let workflow = CoordinatorPassiveRecoveryWorkflow()
    let registry = JobWorkflowRegistry(
      pullRequestReview: workflow,
      issueTriage: workflow,
      issueImplementation: workflow,
      complexPlan: workflow
    )
    let coordinator = JobCoordinator(
      configuration: fixture.configuration,
      discovery: GitHubDiscovery(
        api: fixture.api,
        jobs: fixture.jobs,
        reviewedRevisions: fixture.reviewed
      ),
      jobs: fixture.jobs,
      repositories: fixture.repositories,
      schedulerPersistence: fixture.persistence,
      workflows: registry,
      contractVersion: "w6-test",
      rolloutAuthority: nil,
      now: { fixture.now }
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now))

    let retrying = try #require(try await fixture.jobs.job(id: job.id))
    #expect(retrying.state == .retryBackoff)
    #expect(retrying.currentStep == 4)
    #expect(retrying.currentStepKind == .review)
    #expect(retrying.notBefore == fixture.now.addingTimeInterval(1))
  }

  @Test("paused legacy passes promote exactly-due and overdue retries but not future deadlines")
  func retryDeadlineBoundaries() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    try await fixture.configuration.setPaused(true, now: fixture.now)
    let coordinator = fixture.coordinator()
    await coordinator.run(pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now))

    var createdJobs: [JobRecord] = []
    for index in 0..<3 {
      let creation = try await fixture.jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repository.id,
          kind: .prReview,
          objectNodeID: "retry-boundary-\(index)",
          revisionKey: String(repeating: String(index + 1), count: 40)
        ),
        objectNumber: 20 + index,
        contractVersionUsed: "w6-test",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now
      )
      guard case .created(let job) = creation else {
        Issue.record("retry boundary job was suppressed")
        return
      }
      createdJobs.append(job)
    }
    let deadlines = [
      fixture.now.addingTimeInterval(1),
      fixture.now,
      fixture.now.addingTimeInterval(-1),
    ]
    for (job, deadline) in zip(createdJobs, deadlines) {
      try await fixture.database.execute(
        "UPDATE jobs SET state = 'retryBackoff', not_before = ? WHERE id = ?",
        bindings: [
          .real(deadline.timeIntervalSince1970),
          .text(job.id.uuidString.lowercased()),
        ]
      )
    }

    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    #expect(try await fixture.jobs.job(id: createdJobs[0].id)?.state == .retryBackoff)
    #expect(try await fixture.jobs.job(id: createdJobs[1].id)?.state == .queued)
    #expect(try await fixture.jobs.job(id: createdJobs[2].id)?.state == .queued)
  }

  @Test("transient workflow failure enters durable backoff instead of terminal block")
  func workflowBackoff() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository(activateDispatch: false)
    await fixture.api.configure(pullRequests: [], issues: [])
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "transient-pr",
        revisionKey: String(repeating: "d", count: 40)
      ),
      objectNumber: 8,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("transient job was suppressed")
      return
    }
    try await fixture.activateExactReviewScope(repository: repository, job: job)
    let workflow = CoordinatorTransientWorkflow()
    let registry = JobWorkflowRegistry(
      pullRequestReview: workflow,
      issueTriage: workflow,
      issueImplementation: workflow,
      complexPlan: workflow
    )
    let coordinator = JobCoordinator(
      configuration: fixture.configuration,
      discovery: GitHubDiscovery(
        api: fixture.api,
        jobs: fixture.jobs,
        reviewedRevisions: fixture.reviewed
      ),
      jobs: fixture.jobs,
      repositories: fixture.repositories,
      schedulerPersistence: fixture.persistence,
      workflows: registry,
      contractVersion: "w6-test",
      rolloutAuthority: nil,
      now: { fixture.now }
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    let retrying = try #require(try await fixture.jobs.job(id: job.id))
    #expect(retrying.state == .retryBackoff)
    #expect(retrying.notBefore == fixture.now.addingTimeInterval(60))
    #expect(retrying.terminalReason == nil)
    try await fixture.database.execute(
      "UPDATE jobs SET not_before = ? WHERE id = ?",
      bindings: [
        .real(fixture.now.addingTimeInterval(-1).timeIntervalSince1970),
        .text(job.id.uuidString.lowercased()),
      ]
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.periodic], startedAt: fixture.now))

    let retried = try #require(try await fixture.jobs.job(id: job.id))
    #expect(retried.state == .retryBackoff)
    #expect(retried.attempt == retrying.attempt + 1)
  }

  @Test("discovery failure persists repository backoff without terminal skip")
  func discoveryBackoff() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    await fixture.api.failReads()
    let coordinator = fixture.coordinator()

    await coordinator.run(
      pass: SchedulerPass(reasons: [.periodic], startedAt: fixture.now)
    )

    #expect(try await fixture.jobs.jobs().isEmpty)
    let backoff = try #require(
      try await fixture.persistence.backoff(repositoryID: repository.id)
    )
    #expect(backoff.failureCount == 1)
    #expect(backoff.notBefore == fixture.now.addingTimeInterval(60))
    let failures = await coordinator.snapshot().failures
    #expect(failures.count == 1)
    #expect(failures.first?.stage == "discovery")
  }
}

private final class JobCoordinatorFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let rolloutAuthority: RolloutAuthorityStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let repositories: RepositoryStore
  let reviewed: ReviewedRevisionStore
  let persistence: SchedulerPersistence
  let api: CoordinatorGitHubAPI
  let events: CoordinatorEventLog
  let workflows: CoordinatorWorkflowRunner
  let now = Date(timeIntervalSince1970: 50_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-job-coordinator-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    rolloutAuthority = RolloutAuthorityStore(
      database: database,
      enforceFinitePromotion: false
    )
    configuration = ConfigurationStore(database: database)
    jobs = DurableJobStore(
      database: database,
      enforceApplicationDispatchGate: true,
      enforceRolloutAuthority: false
    )
    repositories = try RepositoryStore(
      rootURL: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database,
      transport: SystemGitTransport()
    )
    reviewed = ReviewedRevisionStore(database: database)
    persistence = SchedulerPersistence(database: database)
    events = CoordinatorEventLog()
    api = CoordinatorGitHubAPI(events: events)
    workflows = CoordinatorWorkflowRunner(jobs: jobs, events: events, now: now)
    try await configuration.setExternalAutomationAcknowledged(true, now: now)
    try await configuration.setProviderDisclosureAcknowledged(true, now: now)
    try await configuration.setLoginItem(selected: true, status: .enabled, now: now)
    try await configuration.setOnboardingComplete(true, now: now)
    try await database.execute(
      """
      UPDATE app_settings
      SET github_account = 'owner', github_author_id = 1, updated_at = ?
      WHERE singleton = 1
      """,
      bindings: [.real(now.timeIntervalSince1970)]
    )
  }

  func addRepository(activateDispatch: Bool = true) async throws -> RepositoryConfiguration {
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "repository-node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(repository, now: now)
    if activateDispatch {
      try await activateCompatibilityScope(repository: repository)
    }
    return repository
  }

  func activateExactReviewScope(
    repository: RepositoryConfiguration,
    job: JobRecord
  ) async throws {
    guard job.identity.repositoryID == repository.id,
      job.identity.kind == .prReview,
      let objectNumber = job.objectNumber,
      job.currentStepKind == .review
    else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    let canonicalInputSHA256 = String(repeating: "b", count: 64)
    let object = RolloutObjectSelector(
      nodeID: job.identity.objectNodeID,
      number: objectNumber,
      revisionKey: job.identity.revisionKey,
      canonicalInputSHA256: canonicalInputSHA256,
      headSHA: job.identity.revisionKey,
      baseSHA: String(repeating: "c", count: 40),
      narrativeSHA256: String(repeating: "d", count: 64),
      currentStep: JobStepKind.review.rawValue
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: .prReview,
      repository: rolloutRepository(repository),
      object: object,
      finiteWindow: nil
    )
    let binding = RolloutJobBinding(
      jobID: job.id,
      jobKind: job.identity.kind,
      objectNumber: objectNumber,
      contractVersion: job.contractVersionUsed,
      priority: job.priority,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    )
    let evidence = try await rolloutAuthority.localEvidence(scope: scope, jobBinding: binding)
    let input = RolloutPreviewInput(
      releaseIdentity: releaseIdentity(evidence: evidence),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: 1,
        githubReadRequests: 10,
        githubReadPages: 10,
        githubReadBytes: 1_000_000,
        gitRemoteReads: 0,
        providerSessions: 4,
        approvedCommands: 0,
        markerParts: 1,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: 1,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: binding,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
    )
    let preview = try await rolloutAuthority.preview(input: input)
    _ = try await rolloutAuthority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      now: now
    )
  }

  private func activateCompatibilityScope(repository: RepositoryConfiguration) async throws {
    let previewExpiresAt = now.addingTimeInterval(600)
    let windowExpiresAt = now.addingTimeInterval(3_600)
    let scope = RolloutScope(
      mode: .finiteWindow,
      stage: .prReview,
      repository: rolloutRepository(repository),
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: 1,
        expiresAtMilliseconds: Int64(windowExpiresAt.timeIntervalSince1970 * 1_000),
        observedObjectNumberUpperBound: 1,
        maximumFutureObjectNumber: 1,
        candidates: [
          RolloutWindowCandidate(
            ordinal: 0,
            nodeID: "compatibility-candidate",
            number: 1,
            revisionKey: String(repeating: "1", count: 40),
            canonicalInputSHA256: String(repeating: "b", count: 64)
          )
        ]
      )
    )
    let evidence = try await rolloutAuthority.localEvidence(scope: scope, jobBinding: nil)
    let input = RolloutPreviewInput(
      releaseIdentity: releaseIdentity(evidence: evidence),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: 1,
        githubReadRequests: 10,
        githubReadPages: 10,
        githubReadBytes: 1_000_000,
        gitRemoteReads: 0,
        providerSessions: 4,
        approvedCommands: 0,
        markerParts: 1,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: 1,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: nil,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(previewExpiresAt.timeIntervalSince1970 * 1_000)
    )
    let preview = try await rolloutAuthority.preview(input: input)
    _ = try await rolloutAuthority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      now: now
    )
  }

  private func rolloutRepository(
    _ repository: RepositoryConfiguration
  ) -> RolloutRepositoryIdentity {
    RolloutRepositoryIdentity(
      id: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      enabled: repository.enabled,
      reviewEnabled: repository.reviewEnabled,
      triageEnabled: repository.triageEnabled,
      implementationEnabled: repository.implementationEnabled
    )
  }

  private func releaseIdentity(
    evidence: RolloutLocalStateEvidence
  ) -> RolloutReleaseIdentity {
    let digest = String(repeating: "a", count: 64)
    return RolloutReleaseIdentity(
      sourceCommit: String(repeating: "1", count: 40),
      sourceTree: String(repeating: "2", count: 40),
      bundleVersion: "0.2.0",
      bundleBuild: 4,
      applicationSHA256: digest,
      helperSHA256: digest,
      askPassSHA256: digest,
      pushGuardSHA256: digest,
      herdrHostSHA256: digest,
      schemaVersion: 10,
      engineProtocolVersion: 12,
      runtimeManifestSHA256: digest,
      runtimeTreeSHA256: digest,
      modelProfilesSHA256: evidence.modelProfilesSHA256,
      workflowResourcesSHA256: digest,
      githubAccount: "owner",
      githubAuthorID: 1,
      repositoryConfigurationSHA256: evidence.repositoryConfigurationSHA256,
      maxConcurrency: 1
    )
  }

  func coordinator(
    rolloutAuthority: RolloutAuthorityStore? = nil,
    newDispatchAllowed: @escaping @Sendable () async -> Bool = { true }
  ) -> JobCoordinator {
    let discovery = GitHubDiscovery(api: api, jobs: jobs, reviewedRevisions: reviewed)
    let registry = JobWorkflowRegistry(
      pullRequestReview: workflows,
      issueTriage: workflows,
      issueImplementation: workflows,
      complexPlan: workflows
    )
    return JobCoordinator(
      configuration: configuration,
      discovery: discovery,
      jobs: jobs,
      repositories: repositories,
      schedulerPersistence: persistence,
      workflows: registry,
      contractVersion: "w6-test",
      rolloutAuthority: rolloutAuthority,
      newDispatchAllowed: newDispatchAllowed,
      now: { self.now }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct CoordinatorPassiveRecoveryWorkflow: JobWorkflowRunning {
  func run(jobID: UUID) async throws {}
}

private struct CoordinatorTransientWorkflow: JobWorkflowRunning {
  func run(jobID: UUID) async throws {
    throw URLError(.timedOut)
  }
}

private actor CoordinatorWorkflowRunner: JobWorkflowRunning {
  private let jobs: DurableJobStore
  private let events: CoordinatorEventLog
  private let now: Date
  private var kinds: [JobKind] = []

  init(jobs: DurableJobStore, events: CoordinatorEventLog, now: Date) {
    self.jobs = jobs
    self.events = events
    self.now = now
  }

  func run(jobID: UUID) async throws {
    guard let job = try await jobs.job(id: jobID) else {
      throw CoordinatorFixtureError.missingJob
    }
    kinds.append(job.identity.kind)
    await events.append("workflow:\(job.identity.kind.rawValue):\(job.state.rawValue)")
    let event: JobEvent
    switch job.state {
    case .preparing:
      _ = try await jobs.transition(
        jobID: job.id,
        eventKey: "fixture:\(job.id.uuidString):execute",
        event: .selectLocalStep,
        context: JobTransitionContext(now: now, reason: "fixture execution")
      )
      event = .localPermanentFailure
    case .reconciling:
      event = .reconciliationPermanentFailure
    default:
      throw CoordinatorFixtureError.unexpectedState(job.state)
    }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:\(job.id.uuidString):blocked",
      event: event,
      context: JobTransitionContext(now: now, reason: "fixture terminal")
    )
  }

  func order() -> [JobKind] { kinds }
}

private actor CoordinatorGitHubAPI: GitHubReadAPI {
  private let events: CoordinatorEventLog
  private var pullRequests: [GitHubPullRequest] = []
  private var issues: [GitHubIssue] = []
  private var failing = false

  init(events: CoordinatorEventLog) {
    self.events = events
  }

  func configure(pullRequests: [GitHubPullRequest], issues: [GitHubIssue]) {
    self.pullRequests = pullRequests
    self.issues = issues
    failing = false
  }

  func failReads() {
    failing = true
  }

  func listPullRequests(owner: String, repository: String) async throws
    -> [GitHubPullRequest]
  {
    await events.append("api:pulls")
    if failing { throw CoordinatorFixtureError.remoteRead }
    return pullRequests
  }

  func listIssues(owner: String, repository: String) async throws -> [GitHubIssue] {
    await events.append("api:issues")
    if failing { throw CoordinatorFixtureError.remoteRead }
    return issues
  }
}

private actor CoordinatorEventLog {
  private var events: [String] = []

  func append(_ value: String) { events.append(value) }
  func values() -> [String] { events }
}

private enum CoordinatorFixtureError: Error {
  case missingJob
  case unexpectedState(JobState)
  case remoteRead
}

private func pullRequest(number: Int) -> GitHubPullRequest {
  let user = GitHubUser(id: 1, nodeID: "user-node", login: "author")
  let repository = GitHubPullRepository(
    id: 1,
    nodeID: "repository-node",
    fullName: "owner/repo"
  )
  return GitHubPullRequest(
    id: Int64(number),
    nodeID: "pr-node-\(number)",
    number: number,
    state: "open",
    draft: false,
    title: "PR \(number)",
    body: "body",
    htmlURL: "https://github.com/owner/repo/pull/\(number)",
    user: user,
    head: GitHubPullReference(
      ref: "feature-\(number)",
      sha: String(format: "%040llx", Int64(number)),
      repository: repository
    ),
    base: GitHubPullReference(
      ref: "main",
      sha: String(repeating: "0", count: 40),
      repository: repository
    )
  )
}

private func issue(number: Int, labels: [GitHubLabel]) -> GitHubIssue {
  GitHubIssue(
    id: Int64(number),
    nodeID: "issue-node-\(number)",
    number: number,
    state: "open",
    title: "Issue \(number)",
    body: "body",
    user: GitHubUser(id: 1, nodeID: "user-node", login: "author"),
    labels: labels,
    createdAt: "2026-08-08T00:00:00Z",
    pullRequest: nil
  )
}

private func label(_ name: String) -> GitHubLabel {
  GitHubLabel(
    id: Int64(name.utf8.count),
    nodeID: "label-\(name)",
    name: name,
    color: "abcdef",
    description: nil
  )
}
