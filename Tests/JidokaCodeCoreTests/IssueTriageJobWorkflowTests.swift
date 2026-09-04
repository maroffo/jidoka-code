import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Issue triage job from snapshot to durable verdict")
struct IssueTriageJobWorkflowTests {
  @Test("fresh stores and workflow recover a completed triage step after SQLite reopen")
  func completedTriageReopen() async throws {
    let fixture = try await IssueTriageJobFixture(crashAfterStep: .triage)
    defer { fixture.remove() }
    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    let reopened = try await fixture.reopen()
    _ = try await reopened.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await reopened.jobs.job(id: fixture.job.id))
    _ = try await reopened.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:triage-reopen-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "triage reopen recovery")
    )

    try await reopened.workflow.run(jobID: queued.id)

    #expect(try await reopened.jobs.job(id: queued.id)?.state == .succeeded)
    await reopened.database.close()
  }

  @Test("input invalidation crash recovers to triage without a false completed mutation")
  func inputInvalidationCrashBoundary() async throws {
    let fixture = try await IssueTriageJobFixture(
      mutateInputDuringFirstTriage: true,
      crashOnInputInvalidation: true
    )
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    #expect(try await fixture.jobs.steps(jobID: fixture.job.id).map(\.kind) == [.triage])
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:input-invalidation-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "input invalidation recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind) == [
        .triage, .triage, .publish, .reconcile,
      ])
  }

  @Test(
    "startup recovery advances each durably completed triage step exactly once",
    arguments: [JobStepKind.triage, .publish, .reconcile]
  )
  func completedStepCrashBoundary(kind: JobStepKind) async throws {
    let fixture = try await IssueTriageJobFixture(crashAfterStep: kind)
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:triage-completed-step-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "triage step recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind).filter { $0 == kind }.count == 1)
  }

  @Test("authorized triage retry attributes a newly visible old marker before resend")
  func authorizedRetryChecksOldMarker() async throws {
    let fixture = try await IssueTriageJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }
    try await fixture.workflow.run(jobID: fixture.job.id)
    let awaiting = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: awaiting.id,
      eventKey: "fixture:triage-human-retry",
      event: .humanRetryAuthorized,
      context: JobTransitionContext(now: fixture.now, reason: "triage retry authorized")
    )
    await fixture.api.materializeDroppedComment()
    let queued = try #require(try await fixture.jobs.job(id: awaiting.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:triage-retry-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "triage retry lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:triage-retry-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "triage retry inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(await fixture.api.commentSendAttempts == 1)
  }

  @Test("late marker after a stale-input rerun uses the paired latest issue revision")
  func staleRerunLateMarker() async throws {
    let fixture = try await IssueTriageJobFixture(
      mutateInputDuringFirstTriage: true,
      dropFirstCommentCreate: true
    )
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .awaitingResolution)
    #expect(!(await fixture.api.mutationOperations()).contains("issue-label"))
    await fixture.api.materializeDroppedComment()
    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .reconciliationQueued)
  }

  @Test("human input changed during triage discards stale output and reruns before mutation")
  func staleInputReruns() async throws {
    let fixture = try await IssueTriageJobFixture(mutateInputDuringFirstTriage: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(await fixture.api.humanMutationCount == 1)
    #expect(
      try await fixture.jobs.steps(jobID: fixture.job.id).map(\.kind) == [
        .triage, .triage, .publish, .reconcile,
      ])
  }

  @Test("marker, exact verdict label, domain labels, disposition, and cleanup complete once")
  func endToEndTriage() async throws {
    let fixture = try await IssueTriageJobFixture()
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: fixture.job.id).map(\.kind) == [
        .triage, .publish, .reconcile,
      ])
    #expect(await fixture.api.workflowLabels() == ["agent:ready"])
    #expect(await fixture.api.domainLabels() == ["bug"])
    #expect(await fixture.api.createCommentCount == 1)
    let operations = await fixture.api.mutationOperations()
    #expect(operations.firstIndex(of: "comment")! < operations.firstIndex(of: "issue-label")!)
    #expect(try await fixture.jobs.disposition(for: fixture.job.identity)?.state == .attributed)
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: fixture.job.id)?.cleanupState
        == .removed)
  }
}

private final class IssueTriageJobFixture: @unchecked Sendable {
  let gitFixture: GitTestRoot
  let database: SQLiteStore
  let remoteURL: URL
  let repository: RepositoryConfiguration
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let repositories: RepositoryStore
  let api: IssueTriageGitHubFixture
  let job: JobRecord
  let workflow: IssueTriageJobWorkflow
  let now = Date(timeIntervalSince1970: 100_000)

  init(
    mutateInputDuringFirstTriage: Bool = false,
    dropFirstCommentCreate: Bool = false,
    crashAfterStep: JobStepKind? = nil,
    crashOnInputInvalidation: Bool = false
  ) async throws {
    gitFixture = try GitTestRoot(prefix: "jidoka-triage-job")
    let source = try await gitFixture.initializeRepository()
    let base = try await gitFixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "test: base"
    )
    remoteURL = try await gitFixture.bareRemote(from: source)
    database = try SQLiteStore(
      databaseURL: gitFixture.root.appendingPathComponent("state.sqlite3")
    )
    configuration = ConfigurationStore(database: database)
    repository = RepositoryConfiguration(
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
    jobs = DurableJobStore(database: database)
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueTriage,
        objectNodeID: "issue-node-9",
        revisionKey: "initial-triage"
      ),
      objectNumber: 9,
      contractVersionUsed: "w6-test",
      priority: .triage,
      firstStep: .triage,
      now: now
    )
    guard case .created(let value) = created else {
      throw IssueTriageJobFixtureError.suppressed
    }
    job = value
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: now, reason: "fixture lease")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: now, reason: "fixture inputs")
    )
    api = IssueTriageGitHubFixture(
      baseSHA: base,
      dropFirstCommentCreate: dropFirstCommentCreate
    )
    repositories = try RepositoryStore(
      rootURL: gitFixture.root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database,
      transport: gitFixture.git
    )
    let remote = try GitRemoteRepository(
      repositoryID: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      localFixtureURL: remoteURL
    )
    let intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    let input = SystemIssueTriageJobPreparer(
      configuration: configuration,
      api: api,
      repositories: repositories,
      intents: intents,
      appAuthorID: 7,
      remoteResolver: LocalTriageRemoteResolver(remote: remote)
    )
    let executor = GitHubMutationExecutor(
      intents: intents,
      broker: api,
      authority: authority
    )
    let sleeper = IssueTriageImmediateSleeper()
    let crashGate = TriageStepCrashGate(kind: crashAfterStep)
    let invalidationGate = TriageInputInvalidationCrashGate(
      enabled: crashOnInputInvalidation
    )
    workflow = IssueTriageJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      artifacts: try ArtifactStore(
        rootURL: gitFixture.root.appendingPathComponent("Artifacts", isDirectory: true),
        database: database
      ),
      inputs: input,
      triage: DeterministicIssueTriageExecutor(
        api: mutateInputDuringFirstTriage ? api : nil
      ),
      markerPublisher: GitHubMarkerPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_001) }
      ),
      labelBootstrapper: GitHubWorkflowLabelBootstrapper(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_001) }
      ),
      labelMutator: GitHubWorkflowLabelMutator(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_001) }
      ),
      repositories: repositories,
      authorID: 7,
      now: { Date(timeIntervalSince1970: 100_001) },
      afterStepPersisted: { kind in try await crashGate.afterPersisting(kind) },
      beforeInputsInvalidated: { try await invalidationGate.beforeTransition() }
    )
  }

  func reopen() async throws -> ReopenedTriageRuntime {
    await database.close()
    let reopenedDatabase = try SQLiteStore(
      databaseURL: gitFixture.root.appendingPathComponent("state.sqlite3")
    )
    let reopenedConfiguration = ConfigurationStore(database: reopenedDatabase)
    let reopenedJobs = DurableJobStore(database: reopenedDatabase)
    let reopenedRepositories = try RepositoryStore(
      rootURL: gitFixture.root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: reopenedDatabase,
      transport: gitFixture.git
    )
    let remote = try GitRemoteRepository(
      repositoryID: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      localFixtureURL: remoteURL
    )
    let intents = MutationIntentStore(database: reopenedDatabase)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    let inputs = SystemIssueTriageJobPreparer(
      configuration: reopenedConfiguration,
      api: api,
      repositories: reopenedRepositories,
      intents: intents,
      appAuthorID: 7,
      remoteResolver: LocalTriageRemoteResolver(remote: remote)
    )
    let executor = GitHubMutationExecutor(
      intents: intents,
      broker: api,
      authority: authority
    )
    let sleeper = IssueTriageImmediateSleeper()
    let reopenedWorkflow = IssueTriageJobWorkflow(
      jobs: reopenedJobs,
      configuration: reopenedConfiguration,
      artifacts: try ArtifactStore(
        rootURL: gitFixture.root.appendingPathComponent("Artifacts", isDirectory: true),
        database: reopenedDatabase
      ),
      inputs: inputs,
      triage: DeterministicIssueTriageExecutor(),
      markerPublisher: GitHubMarkerPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_002) }
      ),
      labelBootstrapper: GitHubWorkflowLabelBootstrapper(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_002) }
      ),
      labelMutator: GitHubWorkflowLabelMutator(
        executor: executor,
        intents: intents,
        reads: api,
        authority: authority,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 100_002) }
      ),
      repositories: reopenedRepositories,
      authorID: 7,
      now: { Date(timeIntervalSince1970: 100_002) }
    )
    return ReopenedTriageRuntime(
      database: reopenedDatabase,
      jobs: reopenedJobs,
      workflow: reopenedWorkflow
    )
  }

  func remove() { gitFixture.remove() }
}

private struct ReopenedTriageRuntime {
  let database: SQLiteStore
  let jobs: DurableJobStore
  let workflow: IssueTriageJobWorkflow
}

private actor TriageInputInvalidationCrashGate {
  private let enabled: Bool
  private var fired = false

  init(enabled: Bool) {
    self.enabled = enabled
  }

  func beforeTransition() throws {
    guard enabled, !fired else { return }
    fired = true
    throw URLError(.networkConnectionLost)
  }
}

private actor TriageStepCrashGate {
  private let kind: JobStepKind?
  private var fired = false

  init(kind: JobStepKind?) {
    self.kind = kind
  }

  func afterPersisting(_ persisted: JobStepKind) throws {
    guard !fired, persisted == kind else { return }
    fired = true
    throw URLError(.networkConnectionLost)
  }
}

private struct LocalTriageRemoteResolver: GitRemoteRepositoryResolving {
  let remote: GitRemoteRepository
  func remote(for repository: RepositoryConfiguration) throws -> GitRemoteRepository { remote }
}

private struct DeterministicIssueTriageExecutor: IssueTriageExecuting {
  let api: IssueTriageGitHubFixture?

  init(api: IssueTriageGitHubFixture? = nil) {
    self.api = api
  }

  func triage(
    job: JobRecord,
    prepared: PreparedIssueTriageJob,
    artifactSHA256: String
  ) async throws -> PiIssueTriageOutput {
    await api?.addHumanCommentOnce()
    return PiIssueTriageOutput(
      result: PiIssueTriagePayload(
        verdict: "ready",
        severity: .info,
        summary: "The issue is bounded and mechanically verifiable.",
        rubric: PiTriageRubric(
          specified: "specified",
          testable: "testable",
          bounded: "bounded",
          safe: "safe"
        ),
        hardRiskFlags: [],
        rationale: "A local implementation and test can prove the requested behavior.",
        questions: [],
        complexityGuess: .simple
      ),
      effectiveVerdict: "ready"
    )
  }
}

private actor IssueTriageGitHubFixture: GitHubMutationReadAPI, GitHubMutationSending {
  private let baseSHA: String
  private var comments: [GitHubComment] = []
  private var labels: [GitHubLabel] = [IssueTriageGitHubFixture.label("bug")]
  private var repositoryLabels: [String: GitHubLabel] = [:]
  private var dropFirstCommentCreate: Bool
  private var droppedCommentBody: String?
  private var recordedMutationOperations: [String] = []
  private(set) var createCommentCount = 0
  private(set) var commentSendAttempts = 0
  private(set) var humanMutationCount = 0

  init(baseSHA: String, dropFirstCommentCreate: Bool) {
    self.baseSHA = baseSHA
    self.dropFirstCommentCreate = dropFirstCommentCreate
  }

  func workflowLabels() -> Set<String> {
    Set(labels.map(\.name).filter { $0.lowercased().hasPrefix("agent:") })
  }

  func mutationOperations() -> [String] {
    recordedMutationOperations
  }

  func materializeDroppedComment() {
    guard let body = droppedCommentBody else { return }
    droppedCommentBody = nil
    createCommentCount += 1
    comments.append(Self.comment(id: Int64(createCommentCount), body: body, authorID: 7))
  }

  func addHumanCommentOnce() {
    guard humanMutationCount == 0 else { return }
    humanMutationCount = 1
    comments.append(
      GitHubComment(
        id: 900,
        nodeID: "human-triage-change",
        body: "Please account for this late human triage detail.",
        user: GitHubUser(id: 2, nodeID: "author-node", login: "author"),
        createdAt: "2026-08-08T01:00:00Z",
        updatedAt: "2026-08-08T01:00:00Z",
        htmlURL: "https://github.com/owner/repo/issues/9#issuecomment-900"
      )
    )
  }

  func domainLabels() -> Set<String> {
    Set(labels.map(\.name).filter { !$0.lowercased().hasPrefix("agent:") })
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    throw IssueTriageJobFixtureError.unexpectedOperation
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    GitHubIssue(
      id: 9,
      nodeID: "issue-node-9",
      number: 9,
      state: "open",
      title: "Bounded issue",
      body: "Implement a local behavior.",
      user: GitHubUser(id: 2, nodeID: "author-node", login: "author"),
      labels: labels,
      createdAt: "2026-08-08T00:00:00Z",
      pullRequest: nil
    )
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    comments
  }

  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  {
    labels
  }

  func lookupPullRequests(
    owner: String,
    repository: String,
    head: String,
    base: String
  ) async throws -> [GitHubPullRequest] {
    []
  }

  func repositoryLabel(owner: String, repository: String, label: String) async throws
    -> GitHubLabel?
  {
    repositoryLabels[label]
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    GitHubReference(
      ref: "refs/heads/main",
      nodeID: "ref-node",
      object: GitHubGitObject(
        sha: baseSHA,
        type: "commit",
        url: "https://api.github.com/repos/owner/repo/git/commits/\(baseSHA)"
      )
    )
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse {
    _ = try await beforeSend()
    switch operation {
    case .createComment(_, _, _, let body):
      commentSendAttempts += 1
      recordedMutationOperations.append("comment")
      if dropFirstCommentCreate {
        dropFirstCommentCreate = false
        droppedCommentBody = body
        throw URLError(.networkConnectionLost)
      }
      createCommentCount += 1
      comments.append(Self.comment(id: Int64(createCommentCount), body: body, authorID: 7))
    case .addIssueLabels(_, _, _, let values):
      recordedMutationOperations.append("issue-label")
      for value in values where !labels.contains(where: { $0.name == value }) {
        labels.append(Self.label(value))
      }
    case .removeIssueLabel(_, _, _, let value):
      recordedMutationOperations.append("issue-label")
      labels.removeAll { $0.name == value }
    case .createRepositoryLabel(_, _, let request):
      repositoryLabels[request.name] = GitHubLabel(
        id: Int64(repositoryLabels.count + 100),
        nodeID: "repository-label-\(request.name)",
        name: request.name,
        color: request.color,
        description: request.description
      )
    default:
      throw IssueTriageJobFixtureError.unexpectedOperation
    }
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: operation.kind.isCreate ? 201 : 200,
      headers: [:],
      body: Data()
    )
  }

  private static func comment(id: Int64, body: String, authorID: Int64) -> GitHubComment {
    GitHubComment(
      id: id,
      nodeID: "comment-\(id)",
      body: body,
      user: GitHubUser(
        id: authorID,
        nodeID: authorID == 7 ? "jidoka-user" : "author-node",
        login: authorID == 7 ? "jidoka-code" : "author"
      ),
      createdAt: "2026-08-08T00:00:00Z",
      updatedAt: "2026-08-08T00:00:00Z",
      htmlURL: "https://github.com/owner/repo/issues/9#issuecomment-\(id)"
    )
  }

  private static func label(_ name: String) -> GitHubLabel {
    GitHubLabel(
      id: Int64(name.utf8.count),
      nodeID: "label-\(name)",
      name: name,
      color: "abcdef",
      description: nil
    )
  }
}

private struct IssueTriageImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum IssueTriageJobFixtureError: Error {
  case suppressed
  case unexpectedOperation
}
