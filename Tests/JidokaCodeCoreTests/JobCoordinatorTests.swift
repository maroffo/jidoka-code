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

  @Test("one pass discovers and dispatches PR, implementation, and triage in locked priority")
  func discoveryAndPriority() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    _ = try await fixture.addRepository()
    await fixture.api.configure(
      pullRequests: [pullRequest(number: 4)],
      issues: [
        issue(number: 10, labels: []),
        issue(number: 11, labels: [label("agent:ready")]),
      ]
    )
    let coordinator = fixture.coordinator()

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now)
    )

    let jobs = try await fixture.jobs.jobs()
    #expect(jobs.count == 3)
    #expect(jobs.allSatisfy { $0.state == .blocked })
    #expect(await fixture.workflows.order() == [.prReview, .issueImplementation, .issueTriage])
    #expect(
      jobs.first(where: { $0.identity.kind == .issueImplementation })?.identity.revisionKey
        == "claim-1"
    )
    #expect((try await fixture.jobs.claims(issueNodeID: "issue-node-11")).isEmpty)
    #expect((await coordinator.snapshot()).failures.isEmpty)
  }

  @Test("reconciliation dispatch runs before any new discovery read")
  func recoveryFirst() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
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

  @Test("startup sweep finishes cleanup stranded by a terminal crash boundary")
  func startupCleanupSweep() async throws {
    let fixture = try await JobCoordinatorFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
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
    let repository = try await fixture.addRepository()
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
    let repository = try await fixture.addRepository()
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
      firstStep: .publish,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("recoverable job was suppressed")
      return
    }
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
      now: { fixture.now }
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now))

    let retrying = try #require(try await fixture.jobs.job(id: job.id))
    #expect(retrying.state == .retryBackoff)
    #expect(retrying.currentStep == 4)
    #expect(retrying.currentStepKind == .publish)
    #expect(retrying.notBefore == fixture.now.addingTimeInterval(1))
  }

  @Test("paused passes promote exactly-due and overdue retries but not future deadlines")
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
    let repository = try await fixture.addRepository()
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
    configuration = ConfigurationStore(database: database)
    jobs = DurableJobStore(database: database)
    repositories = try RepositoryStore(
      rootURL: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database
    )
    reviewed = ReviewedRevisionStore(database: database)
    persistence = SchedulerPersistence(database: database)
    events = CoordinatorEventLog()
    api = CoordinatorGitHubAPI(events: events)
    workflows = CoordinatorWorkflowRunner(jobs: jobs, events: events, now: now)
  }

  func addRepository() async throws -> RepositoryConfiguration {
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
    return repository
  }

  func coordinator() -> JobCoordinator {
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
