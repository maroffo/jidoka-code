import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Issue implementation job from exact claim to post-open review")
struct IssueImplementationJobWorkflowTests {
  @Test("interrupted Pi writer with workspace changes blocks and preserves evidence")
  func interruptedWriterPreservesWorkspace() async throws {
    let fixture = try await IssueImplementationJobFixture(interruptPlanningAfterWrite: true)
    defer { fixture.remove() }

    await #expect(throws: PiRPCProcessError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    let running = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(running.state == .runningPi)
    _ = try await fixture.jobs.transition(
      jobID: running.id,
      eventKey: "fixture:pi-interrupted-unknown",
      event: .piInterruptedUnknown,
      context: JobTransitionContext(now: fixture.now, reason: "unknown writer interruption")
    )
    let queued = try #require(try await fixture.jobs.job(id: running.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:pi-interrupted-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "writer interruption recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .blocked)
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: queued.id)?.cleanupState == .retained)
    let workspace = try await fixture.repositories.retainedWorkspaceURL(jobID: queued.id)
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("interrupted-writer.txt").path
      ))
  }

  @Test("ambiguous complex-plan marker never sends the plan-review label mutation")
  func ambiguousPlanMarkerStopsPlanReviewLabel() async throws {
    let fixture = try await IssueImplementationJobFixture(
      requiresApproval: true,
      dropCommentCreateAttempt: 2
    )
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .awaitingResolution)
    #expect(await fixture.api.workflowLabels() == ["agent:wip"])
    let operations = await fixture.api.mutationOperations()
    #expect(operations.contains("comment:plan"))
    #expect(!operations.contains("label:add:agent:plan-review"))
  }

  @Test("ambiguous blocked publication retains workspace and does not publish blocked label")
  func ambiguousBlockedPublicationRetainsWorkspace() async throws {
    let fixture = try await IssueImplementationJobFixture(
      orchestrationBlocked: true,
      dropCommentCreateAttempt: 2
    )
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .awaitingResolution)
    #expect(await fixture.api.workflowLabels() == ["agent:wip"])
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: fixture.job.id)?.cleanupState
        == .retained)
  }

  @Test("authorized claim retry attributes a newly visible old marker before resend")
  func authorizedClaimRetryChecksOldMarker() async throws {
    let fixture = try await IssueImplementationJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }
    try await fixture.workflow.run(jobID: fixture.job.id)
    let awaiting = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: awaiting.id,
      eventKey: "fixture:claim-human-retry",
      event: .humanRetryAuthorized,
      context: JobTransitionContext(now: fixture.now, reason: "claim retry authorized")
    )
    await fixture.api.materializeDroppedComment()
    let queued = try #require(try await fixture.jobs.job(id: awaiting.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:claim-retry-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "claim retry lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:claim-retry-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "claim retry inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(await fixture.api.commentSendAttempts() == 2)
  }

  @Test("mixed-case workflow labels use the same canonical eligibility throughout")
  func mixedCaseWorkflowLabels() async throws {
    let fixture = try await IssueImplementationJobFixture()
    defer { fixture.remove() }
    await fixture.api.useMixedCaseReadyLabel()

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(await fixture.api.workflowLabels() == ["agent:qa"])
  }

  @Test("unknown claim marker never sends a workflow-label mutation")
  func unknownClaimMarkerStopsLabels() async throws {
    let fixture = try await IssueImplementationJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .awaitingResolution)
    #expect(await fixture.api.workflowLabels() == ["agent:ready"])
    #expect(await fixture.api.issueLabelMutationCount == 0)
    #expect(try await fixture.repositories.workspaceRecord(jobID: fixture.job.id) == nil)
  }

  @Test("fresh stores and workflow recover a completed plan after SQLite reopen")
  func completedPlanReopen() async throws {
    let fixture = try await IssueImplementationJobFixture(crashAfterStep: .plan)
    defer { fixture.remove() }
    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    let reopened = try await fixture.reopenSimple()
    _ = try await reopened.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await reopened.jobs.job(id: fixture.job.id))
    _ = try await reopened.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:implementation-reopen-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "implementation reopen recovery")
    )

    try await reopened.workflow.run(jobID: queued.id)

    #expect(try await reopened.jobs.job(id: queued.id)?.state == .succeeded)
    await reopened.database.close()
  }

  @Test("startup recovery imports durable orchestration evidence before workspace drift blocks")
  func orchestrationEvidenceCrashBoundary() async throws {
    let fixture = try await IssueImplementationJobFixture(crashAfterOrchestrationEvidence: true)
    defer { fixture.remove() }
    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    #expect(
      try await fixture.jobs.steps(jobID: fixture.job.id).allSatisfy { $0.kind != .orchestrate }
    )

    let reopened = try await fixture.reopenSimple()
    _ = try await reopened.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await reopened.jobs.job(id: fixture.job.id))
    #expect(queued.state == .reconciliationQueued)
    _ = try await reopened.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:orchestration-evidence-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "orchestration evidence recovery")
    )

    try await reopened.workflow.run(jobID: queued.id)

    #expect(try await reopened.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await reopened.jobs.steps(jobID: queued.id).map(\.kind).filter { $0 == .orchestrate }
        == [.orchestrate]
    )
    await reopened.database.close()
  }

  @Test(
    "startup recovery advances each durably completed implementation step exactly once",
    arguments: [
      JobStepKind.claimReady, .plan, .writePlan, .orchestrate, .push, .openPullRequest,
      .linkPullRequest, .qa,
    ]
  )
  func completedStepCrashBoundary(kind: JobStepKind) async throws {
    let fixture = try await IssueImplementationJobFixture(crashAfterStep: kind)
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    let interrupted = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect([JobState.runningPi, .executing, .reconciling].contains(interrupted.state))
    let completedBeforeRecovery = try await fixture.jobs.steps(jobID: fixture.job.id)
    #expect(completedBeforeRecovery.last?.kind == kind)
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(queued.state == .reconciliationQueued)
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:completed-plan-recovery-lease",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "completed plan recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind).filter { $0 == kind }.count == 1)
  }

  @Test("completed approved claim resumes orchestration without replanning")
  func completedApprovedClaimCrashBoundary() async throws {
    let fixture = try await IssueImplementationJobFixture(
      requiresApproval: true,
      crashAfterStep: .claimApprovedPlan
    )
    defer { fixture.remove() }
    try await fixture.workflow.run(jobID: fixture.job.id)
    await fixture.api.addPlanApproval()
    let approved = try await fixture.workflow.evaluateWaitingApproval(jobID: fixture.job.id)
    _ = try await fixture.jobs.transition(
      jobID: approved.id,
      eventKey: "fixture:approved-crash-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "approved crash lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: approved.id,
      eventKey: "fixture:approved-crash-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "approved crash inputs")
    )
    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: approved.id)
    }
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: approved.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:approved-crash-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "approved claim recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind).filter { $0 == .plan }.count == 1)
  }

  @Test("completed complex-plan publication recovers cleanup before returning to human gate")
  func completedPlanPublicationCrashBoundary() async throws {
    let fixture = try await IssueImplementationJobFixture(
      requiresApproval: true,
      crashAfterStep: .publishPlan
    )
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:completed-plan-publication-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "plan publication recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .waitingHuman)
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: queued.id)?.cleanupState == .removed)
  }

  @Test("completed blocked publication recovers cleanup before terminal state")
  func completedBlockedPublicationCrashBoundary() async throws {
    let fixture = try await IssueImplementationJobFixture(
      orchestrationBlocked: true,
      crashAfterStep: .publish
    )
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }
    _ = try await fixture.jobs.recoverAtStartup(now: fixture.now)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:completed-blocked-publication-recovery",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "blocked publication recovery")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .blocked)
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: queued.id)?.cleanupState == .removed)
  }

  @Test(
    "ready issue completes claim, plan, implementation, publication, QA, cleanup, and review enqueue"
  )
  func endToEndImplementation() async throws {
    let fixture = try await IssueImplementationJobFixture()
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    let completed = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(completed.state == .succeeded)
    #expect(
      try await fixture.jobs.steps(jobID: fixture.job.id).map(\.kind) == [
        .claimReady, .plan, .writePlan, .orchestrate, .push, .openPullRequest,
        .linkPullRequest, .qa,
      ])
    #expect(await fixture.api.workflowLabels() == ["agent:qa"])
    #expect(await fixture.api.domainLabels() == ["bug"])
    let publishedSHA = await fixture.branchTransport.publishedSHA
    let pullRequestHeadSHA = await fixture.api.pullRequestHeadSHA()
    #expect(publishedSHA == pullRequestHeadSHA)
    let claims = try await fixture.jobs.claims(issueNodeID: fixture.job.identity.objectNodeID)
    #expect(claims.count == 1)
    #expect(claims.first?.state == .consumed)
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: fixture.job.id)?.cleanupState
        == .removed)
    let reviews = try await fixture.jobs.jobs().filter {
      $0.identity.kind == .prReview && $0.state == .queued
    }
    #expect(reviews.count == 1)
    #expect(reviews.first?.identity.revisionKey == pullRequestHeadSHA)
    #expect(await fixture.api.pullRequestBody()?.contains("Closes #12") == true)
  }

  @Test("stale human input consumes only approval, replans, and returns to plan review")
  func staleComplexApprovalReplans() async throws {
    let fixture = try await IssueImplementationJobFixture(requiresApproval: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    let operationsBeforeStaleApproval = await fixture.api.labelOperations()
    await fixture.api.addPlanApproval()
    await fixture.api.addHumanComment()
    let queued = try await fixture.workflow.evaluateWaitingApproval(jobID: fixture.job.id)
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:stale-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "stale fixture lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:stale-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "stale fixture inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    let waiting = try #require(try await fixture.jobs.job(id: queued.id))
    #expect(waiting.state == .waitingHuman)
    #expect(await fixture.api.workflowLabels() == ["agent:plan-review"])
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind) == [
        .claimReady, .plan, .publishPlan, .consumeStaleApproval, .replan, .publishPlan,
      ])
    #expect(
      try await fixture.jobs.claims(issueNodeID: queued.identity.objectNodeID).map(\.state)
        == [.inactive])
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: queued.id)?.cleanupState == .removed)
    #expect(
      Array((await fixture.api.labelOperations()).dropFirst(operationsBeforeStaleApproval.count))
        == ["remove:plan:approved"])
  }

  @Test("stale base consumes only approval and publishes a replacement complex plan")
  func staleComplexApproval() async throws {
    let fixture = try await IssueImplementationJobFixture(requiresApproval: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    let operationsBeforeStaleApproval = await fixture.api.labelOperations()
    await fixture.api.addPlanApproval()
    try await fixture.advanceBase()

    let queued = try await fixture.workflow.evaluateWaitingApproval(jobID: fixture.job.id)

    #expect(queued.state == .queued)
    #expect(queued.currentStep == 3)
    #expect(queued.currentStepKind == .consumeStaleApproval)
    #expect(await fixture.api.workflowLabels() == ["agent:plan-review", "plan:approved"])
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:stale-base-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "stale base lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:stale-base-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "stale base inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    let final = try #require(try await fixture.jobs.job(id: queued.id))
    #expect(final.state == .waitingHuman)
    #expect(await fixture.api.workflowLabels() == ["agent:plan-review"])
    #expect(
      Array((await fixture.api.labelOperations()).dropFirst(operationsBeforeStaleApproval.count))
        == ["remove:plan:approved"])
  }

  @Test(
    "complex plan releases its claim and workspace, then exact approval resumes a new generation")
  func exactComplexApprovalResume() async throws {
    let fixture = try await IssueImplementationJobFixture(requiresApproval: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    let waiting = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(waiting.state == .waitingHuman)
    #expect(waiting.currentStep == 2)
    #expect(await fixture.api.workflowLabels() == ["agent:plan-review"])
    let publicationOrder = await fixture.api.mutationOperations()
    #expect(
      publicationOrder.firstIndex(of: "comment:plan")!
        < publicationOrder.firstIndex(of: "label:add:agent:plan-review")!
    )
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: fixture.job.id)?.cleanupState
        == .removed)
    #expect(
      try await fixture.jobs.claims(issueNodeID: fixture.job.identity.objectNodeID).map(\.state)
        == [.inactive])

    await fixture.api.addPlanApproval()
    let queued = try await fixture.workflow.evaluateWaitingApproval(jobID: fixture.job.id)
    #expect(queued.state == .queued)
    #expect(queued.currentStep == 3)
    #expect(queued.currentStepKind == .claimApprovedPlan)
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:approved-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "approved fixture lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:approved-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "approved fixture inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(
      try await fixture.jobs.claims(issueNodeID: queued.identity.objectNodeID).map(\.state) == [
        .inactive, .consumed,
      ])
    #expect(
      try await fixture.jobs.steps(jobID: queued.id).map(\.kind) == [
        .claimReady, .plan, .publishPlan, .claimApprovedPlan, .orchestrate, .push,
        .openPullRequest, .linkPullRequest, .qa,
      ])
  }
}

private final class IssueImplementationJobFixture: @unchecked Sendable {
  let gitFixture: GitTestRoot
  let sourceRepository: URL
  let remoteURL: URL
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let repository: RepositoryConfiguration
  let jobs: DurableJobStore
  let repositories: RepositoryStore
  let api: IssueImplementationGitHubFixture
  let branchTransport: IssueImplementationBranchTransport
  let job: JobRecord
  let workflow: IssueImplementationJobWorkflow
  let now = Date(timeIntervalSince1970: 120_000)

  init(
    requiresApproval: Bool = false,
    dropFirstCommentCreate: Bool = false,
    orchestrationBlocked: Bool = false,
    dropCommentCreateAttempt: Int? = nil,
    crashAfterStep: JobStepKind? = nil,
    interruptPlanningAfterWrite: Bool = false,
    crashAfterOrchestrationEvidence: Bool = false
  ) async throws {
    gitFixture = try GitTestRoot(prefix: "jidoka-implementation-job")
    sourceRepository = try await gitFixture.initializeRepository()
    let base = try await gitFixture.commit(
      repository: sourceRepository,
      path: "README.md",
      contents: "base\n",
      message: "test: base"
    )
    remoteURL = try await gitFixture.bareRemote(from: sourceRepository)
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
    api = IssueImplementationGitHubFixture(
      baseSHA: base,
      dropCommentCreateAttempt: dropFirstCommentCreate ? 1 : dropCommentCreateAttempt
    )
    let revision = try IssueRevisionBuilder.make(
      input: IssueRevisionInput(
        issueNodeID: "issue-node-12",
        title: "Add bounded implementation",
        body: "Create a deterministic feature file.",
        authorID: 2,
        createdAt: "2026-08-08T00:00:00Z",
        labels: [IssueRevisionLabel(nodeID: "label-bug", name: "bug")],
        comments: [],
        linkedInputs: []
      )
    )
    jobs = DurableJobStore(database: database)
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueImplementation,
        objectNodeID: "issue-node-12",
        revisionKey: revision.sha256
      ),
      objectNumber: 12,
      contractVersionUsed: "w6-test",
      priority: .issueImplementation,
      firstStep: .claimReady,
      now: now
    )
    guard case .created(let value) = created else {
      throw IssueImplementationJobFixtureError.suppressed
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
    let inputs = SystemIssueImplementationJobPreparer(
      configuration: configuration,
      api: api,
      repositories: repositories,
      intents: intents,
      appAuthorID: 7,
      remoteResolver: LocalImplementationRemoteResolver(remote: remote)
    )
    let executor = GitHubMutationExecutor(intents: intents, broker: api)
    let sleeper = IssueImplementationImmediateSleeper()
    branchTransport = IssueImplementationBranchTransport()
    let crashGate = ImplementationStepCrashGate(kind: crashAfterStep)
    let evidenceCrashGate = ImplementationEvidenceCrashGate(
      enabled: crashAfterOrchestrationEvidence
    )
    workflow = IssueImplementationJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      artifacts: try ArtifactStore(
        rootURL: gitFixture.root.appendingPathComponent("Artifacts", isDirectory: true),
        database: database
      ),
      repositories: repositories,
      inputs: inputs,
      planner: DeterministicImplementationPlanner(
        requiresApproval: requiresApproval,
        interruptAfterWrite: interruptPlanningAfterWrite
      ),
      orchestrator: DeterministicImplementationOrchestrator(
        git: gitFixture.git,
        blocked: orchestrationBlocked
      ),
      markerPublisher: GitHubMarkerPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_001) }
      ),
      labelBootstrapper: GitHubWorkflowLabelBootstrapper(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_001) }
      ),
      labelMutator: GitHubWorkflowLabelMutator(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_001) }
      ),
      branchPublisher: DurableGitPublisher(intents: intents, transport: branchTransport),
      pullRequestPublisher: GitHubPullRequestPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_001) }
      ),
      authorID: 7,
      contractVersion: "w6-test",
      now: { Date(timeIntervalSince1970: 120_001) },
      afterStepPersisted: { kind in try await crashGate.afterPersisting(kind) },
      afterOrchestrationEvidencePersisted: {
        try await evidenceCrashGate.afterPersisting()
      }
    )
    await api.setBranchTransport(branchTransport)
  }

  func reopenSimple() async throws -> ReopenedImplementationRuntime {
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
    let inputs = SystemIssueImplementationJobPreparer(
      configuration: reopenedConfiguration,
      api: api,
      repositories: reopenedRepositories,
      intents: intents,
      appAuthorID: 7,
      remoteResolver: LocalImplementationRemoteResolver(remote: remote)
    )
    let executor = GitHubMutationExecutor(intents: intents, broker: api)
    let sleeper = IssueImplementationImmediateSleeper()
    let reopenedWorkflow = IssueImplementationJobWorkflow(
      jobs: reopenedJobs,
      configuration: reopenedConfiguration,
      artifacts: try ArtifactStore(
        rootURL: gitFixture.root.appendingPathComponent("Artifacts", isDirectory: true),
        database: reopenedDatabase
      ),
      repositories: reopenedRepositories,
      inputs: inputs,
      planner: DeterministicImplementationPlanner(
        requiresApproval: false,
        interruptAfterWrite: false
      ),
      orchestrator: DeterministicImplementationOrchestrator(
        git: gitFixture.git,
        blocked: false
      ),
      markerPublisher: GitHubMarkerPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_002) }
      ),
      labelBootstrapper: GitHubWorkflowLabelBootstrapper(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_002) }
      ),
      labelMutator: GitHubWorkflowLabelMutator(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_002) }
      ),
      branchPublisher: DurableGitPublisher(intents: intents, transport: branchTransport),
      pullRequestPublisher: GitHubPullRequestPublisher(
        executor: executor,
        intents: intents,
        reads: api,
        sleeper: sleeper,
        now: { Date(timeIntervalSince1970: 120_002) }
      ),
      authorID: 7,
      contractVersion: "w6-test",
      now: { Date(timeIntervalSince1970: 120_002) }
    )
    await api.setBranchTransport(branchTransport)
    return ReopenedImplementationRuntime(
      database: reopenedDatabase,
      jobs: reopenedJobs,
      workflow: reopenedWorkflow
    )
  }

  func advanceBase() async throws {
    let advanced = try await gitFixture.commit(
      repository: sourceRepository,
      path: "README.md",
      contents: "advanced base\n",
      message: "test: advance base"
    )
    try await gitFixture.run([
      "-C", sourceRepository.path, "push", remoteURL.path, "\(advanced):refs/heads/main",
    ])
    await api.setBaseSHA(advanced)
  }

  func remove() { gitFixture.remove() }
}

private struct ReopenedImplementationRuntime {
  let database: SQLiteStore
  let jobs: DurableJobStore
  let workflow: IssueImplementationJobWorkflow
}

private struct LocalImplementationRemoteResolver: GitRemoteRepositoryResolving {
  let remote: GitRemoteRepository
  func remote(for repository: RepositoryConfiguration) throws -> GitRemoteRepository { remote }
}

private actor ImplementationStepCrashGate {
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

private actor ImplementationEvidenceCrashGate {
  private let enabled: Bool
  private var fired = false

  init(enabled: Bool) {
    self.enabled = enabled
  }

  func afterPersisting() throws {
    guard enabled, !fired else { return }
    fired = true
    throw URLError(.networkConnectionLost)
  }
}

private struct DeterministicImplementationPlanner: IssueImplementationPlanning {
  let requiresApproval: Bool
  let interruptAfterWrite: Bool

  func plan(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    artifactSHA256: String
  ) async throws -> PiPlanningOutput {
    if interruptAfterWrite {
      try Data("interrupted\n".utf8).write(
        to: workspaceURL.appendingPathComponent("interrupted-writer.txt")
      )
      throw PiRPCProcessError.timeout(abortAcknowledged: true)
    }
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"],
      rationale: "Fixture command remains digest-bound."
    )
    let facts =
      requiresApproval
      ? ComplexityFacts(
        workstreamCount: 1,
        publicAPI: true,
        nonDestructiveSchema: false,
        crossModuleConcurrency: false,
        operationalRollback: false,
        designAlternatives: false,
        humanDecisionGap: false,
        securityOrSecretCore: false,
        dataLossMigration: false,
        releaseOrTag: false,
        infrastructureBlastRadius: false,
        crossRepositoryCoordination: false,
        unresolvedDesignDebate: false,
        unverifiable: false
      ) : nil
    let plan = try makeFrozenPlan(
      [command],
      decisionEvidenceSeed: "implementation",
      planningFacts: facts,
      proposedComplexity: requiresApproval ? .complex : .simple,
      artifactSHA256: artifactSHA256,
      planMarkdown: "# Plan\n\nCreate the approved feature file and verify it.\n"
    )
    return PiPlanningOutput(
      disposition: requiresApproval ? .requiresApproval : .ready,
      rounds: 1,
      complexity: try #require(plan.planningDecision?.complexity),
      frozenPlan: plan,
      planMarkdown: plan.planMarkdown,
      roleResults: try #require(plan.planningDecision?.roleResults),
      engineFailures: []
    )
  }
}

private struct DeterministicImplementationOrchestrator: IssueImplementationOrchestrating {
  let git: any GitLocalCommanding
  let blocked: Bool

  func orchestrate(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    envelope: IssueImplementationPlanEnvelope,
    artifactSHA256: String
  ) async throws -> IssueImplementationExecutionResult {
    if blocked {
      return IssueImplementationExecutionResult(
        orchestration: PiOrchestrationOutput(
          disposition: .blocked,
          rounds: 1,
          roleResults: [],
          commandEvidence: [],
          engineFailures: ["fixture-blocked"]
        ),
        importEvidence: nil,
        headSHA: nil,
        treeSHA: nil
      )
    }
    let feature = workspaceURL.appendingPathComponent("Feature.txt")
    try Data("implemented\n".utf8).write(to: feature)
    try await requireSuccess(["-C", workspaceURL.path, "add", "--", "Feature.txt"], workspaceURL)
    try await requireSuccess(
      ["-C", workspaceURL.path, "commit", "-m", "feat: add bounded implementation"],
      workspaceURL
    )
    let head = try await output(["-C", workspaceURL.path, "rev-parse", "HEAD"], workspaceURL)
    let tree = try await output(
      ["-C", workspaceURL.path, "rev-parse", "\(head)^{tree}"],
      workspaceURL
    )
    let evidenceDigest = GitHubMarkerCodec.sha256(
      Data("\(head):\(tree):Feature.txt".utf8)
    )
    let orchestration = PiOrchestrationOutput(
      disposition: .succeeded,
      rounds: 1,
      roleResults: [],
      commandEvidence: [],
      engineFailures: []
    )
    return IssueImplementationExecutionResult(
      orchestration: orchestration,
      importEvidence: WorkspaceImportEvidence(
        localReference: "refs/jidoka/jobs/\(job.id.uuidString.lowercased())/head",
        exactHeadSHA: head,
        treeSHA: tree,
        changedFiles: ["Feature.txt"],
        evidenceDigest: evidenceDigest
      ),
      headSHA: head,
      treeSHA: tree
    )
  }

  private func requireSuccess(_ arguments: [String], _ workspace: URL) async throws {
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard result.succeeded else { throw IssueImplementationJobFixtureError.gitFailure }
  }

  private func output(_ arguments: [String], _ workspace: URL) async throws -> String {
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      throw IssueImplementationJobFixtureError.gitFailure
    }
    return value
  }
}

private actor IssueImplementationBranchTransport: GitPublicationTransporting {
  private(set) var publishedSHA: String?

  func containsLocalCommit(_ exactSHA: String, repository: URL) async throws -> Bool { true }

  func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String? {
    publishedSHA
  }

  func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> GitProcessResult {
    publishedSHA = exactSHA
    return GitProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      stdout: Data(),
      stderr: Data(),
      durationSeconds: 0
    )
  }
}

private actor IssueImplementationGitHubFixture: GitHubMutationReadAPI, GitHubMutationSending {
  private var baseSHA: String
  private var labels: [GitHubLabel]
  private var repositoryLabels: [String: GitHubLabel] = [:]
  private var comments: [GitHubComment] = []
  private var pullRequestValue: GitHubPullRequest?
  private weak var branchTransport: IssueImplementationBranchTransport?
  private let dropCommentCreateAttempt: Int?
  private var commentCreateAttempts = 0
  private var droppedCommentBody: String?
  private var recordedLabelOperations: [String] = []
  private var recordedMutationOperations: [String] = []
  private(set) var issueLabelMutationCount = 0

  init(baseSHA: String, dropCommentCreateAttempt: Int?) {
    self.baseSHA = baseSHA
    self.dropCommentCreateAttempt = dropCommentCreateAttempt
    labels = [Self.label("bug"), Self.label("agent:ready")]
  }

  func setBranchTransport(_ value: IssueImplementationBranchTransport) {
    branchTransport = value
  }

  func workflowLabels() -> Set<String> {
    Set(labels.map(\.name).filter(Self.isWorkflowLabel).map { $0.lowercased() })
  }

  func labelOperations() -> [String] {
    recordedLabelOperations
  }

  func mutationOperations() -> [String] {
    recordedMutationOperations
  }

  func commentSendAttempts() -> Int {
    commentCreateAttempts
  }

  func materializeDroppedComment() {
    guard let body = droppedCommentBody else { return }
    droppedCommentBody = nil
    comments.append(Self.comment(body: body, id: Int64(comments.count + 1)))
  }

  func domainLabels() -> Set<String> {
    Set(labels.map(\.name).filter { !Self.isWorkflowLabel($0) })
  }

  func pullRequestHeadSHA() -> String? { pullRequestValue?.head.sha }
  func pullRequestBody() -> String? { pullRequestValue?.body }

  func useMixedCaseReadyLabel() {
    labels = labels.map { label in
      label.name == "agent:ready" ? Self.label("Agent:Ready") : label
    }
  }

  func addPlanApproval() {
    if !labels.contains(where: { $0.name == "plan:approved" }) {
      labels.append(Self.label("plan:approved"))
    }
  }

  func setBaseSHA(_ value: String) {
    baseSHA = value
  }

  func addHumanComment() {
    comments.append(
      GitHubComment(
        id: Int64(comments.count + 1),
        nodeID: "human-comment-\(comments.count + 1)",
        body: "The implementation must also preserve the revised human requirement.",
        user: GitHubUser(id: 2, nodeID: "author-node", login: "author"),
        createdAt: "2026-08-08T01:00:00Z",
        updatedAt: "2026-08-08T01:00:00Z",
        htmlURL: "https://github.com/owner/repo/issues/12#issuecomment-human"
      )
    )
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> Void
  ) async throws -> GitHubBrokerResponse {
    try await beforeSend()
    switch operation {
    case .createComment(_, _, _, let body):
      let markerKind = (try? GitHubMarkerCodec.parse(body).identity.kind.rawValue) ?? "unknown"
      recordedMutationOperations.append("comment:\(markerKind)")
      commentCreateAttempts += 1
      if commentCreateAttempts == dropCommentCreateAttempt {
        droppedCommentBody = body
        throw URLError(.networkConnectionLost)
      }
      comments.append(Self.comment(body: body, id: Int64(comments.count + 1)))
    case .addIssueLabels(_, _, _, let values):
      issueLabelMutationCount += 1
      recordedLabelOperations.append("add:\(values.sorted().joined(separator: ","))")
      recordedMutationOperations.append("label:add:\(values.sorted().joined(separator: ","))")
      for value in values where !labels.contains(where: { $0.name == value }) {
        labels.append(Self.label(value))
      }
    case .removeIssueLabel(_, _, _, let value):
      issueLabelMutationCount += 1
      recordedLabelOperations.append("remove:\(value)")
      recordedMutationOperations.append("label:remove:\(value)")
      labels.removeAll { $0.name.caseInsensitiveCompare(value) == .orderedSame }
    case .createRepositoryLabel(_, _, let request):
      repositoryLabels[request.name] = GitHubLabel(
        id: Int64(repositoryLabels.count + 100),
        nodeID: "repository-label-\(request.name)",
        name: request.name,
        color: request.color,
        description: request.description
      )
    case .createPullRequest(_, _, let request):
      guard let headSHA = await branchTransport?.publishedSHA else {
        throw IssueImplementationJobFixtureError.unexpectedOperation
      }
      let repository = GitHubPullRepository(
        id: 1,
        nodeID: "repository-node",
        fullName: "owner/repo"
      )
      pullRequestValue = GitHubPullRequest(
        id: 88,
        nodeID: "pr-node-88",
        number: 88,
        state: "open",
        draft: false,
        title: request.title,
        body: request.body,
        htmlURL: "https://github.com/owner/repo/pull/88",
        user: GitHubUser(id: 7, nodeID: "jidoka-user", login: "jidoka-code"),
        head: GitHubPullReference(ref: request.head, sha: headSHA, repository: repository),
        base: GitHubPullReference(ref: request.base, sha: baseSHA, repository: repository)
      )
    default:
      throw IssueImplementationJobFixtureError.unexpectedOperation
    }
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: operation.kind.isCreate ? 201 : 200,
      headers: [:],
      body: Data()
    )
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    guard let value = pullRequestValue, value.number == number else {
      throw IssueImplementationJobFixtureError.unexpectedOperation
    }
    return value
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    GitHubIssue(
      id: 12,
      nodeID: "issue-node-12",
      number: 12,
      state: "open",
      title: "Add bounded implementation",
      body: "Create a deterministic feature file.",
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
    guard let value = pullRequestValue,
      value.head.ref == head,
      value.base.ref == base
    else { return [] }
    return [value]
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

  private static func isWorkflowLabel(_ value: String) -> Bool {
    value.lowercased().hasPrefix("agent:") || value.lowercased().hasPrefix("plan:")
  }

  private static func comment(body: String, id: Int64) -> GitHubComment {
    GitHubComment(
      id: id,
      nodeID: "comment-\(id)",
      body: body,
      user: GitHubUser(id: 7, nodeID: "jidoka-user", login: "jidoka-code"),
      createdAt: "2026-08-08T00:00:00Z",
      updatedAt: "2026-08-08T00:00:00Z",
      htmlURL: "https://github.com/owner/repo/issues/12#issuecomment-\(id)"
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

private struct IssueImplementationImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum IssueImplementationJobFixtureError: Error {
  case suppressed
  case gitFailure
  case unexpectedOperation
}
