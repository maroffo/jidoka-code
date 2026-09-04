import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Pull request review job from exact commits to durable marker")
struct PullRequestReviewJobWorkflowTests {
  @Test("a late exact marker is read-only attributed and recovered without another send")
  func lateMarkerRecovery() async throws {
    let fixture = try await PullRequestReviewJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    await fixture.api.materializeDroppedComment()
    try await fixture.workflow.run(jobID: fixture.job.id)
    let queued = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(queued.state == .reconciliationQueued)
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:late-recovery-lease",
      event: .acquireRecoveryLease,
      context: JobTransitionContext(now: fixture.now, reason: "late recovery lease")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(await fixture.api.sendAttemptCount == 1)
    #expect(try await fixture.intents.intents(jobID: queued.id).map(\.state) == [.attributed])
  }

  @Test("authorized retry attributes the old generation if it becomes visible before resend")
  func humanRetryChecksOldGenerationFirst() async throws {
    let fixture = try await PullRequestReviewJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    let awaiting = try #require(try await fixture.jobs.job(id: fixture.job.id))
    _ = try await fixture.jobs.transition(
      jobID: awaiting.id,
      eventKey: "fixture:late-old-human-retry",
      event: .humanRetryAuthorized,
      context: JobTransitionContext(now: fixture.now, reason: "operator authorized retry")
    )
    await fixture.api.materializeDroppedComment()
    let queued = try #require(try await fixture.jobs.job(id: awaiting.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:late-old-retry-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "retry lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:late-old-retry-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "retry inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(await fixture.api.sendAttemptCount == 1)
    #expect(try await fixture.intents.intents(jobID: queued.id).map(\.state) == [.attributed])
  }

  @Test("authorized retry uses a fresh mutation generation after an ambiguous marker send")
  func humanRetryUsesFreshGeneration() async throws {
    let fixture = try await PullRequestReviewJobFixture(dropFirstCommentCreate: true)
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)
    let awaiting = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(awaiting.state == .awaitingResolution)
    _ = try await fixture.jobs.transition(
      jobID: awaiting.id,
      eventKey: "fixture:human-retry",
      event: .humanRetryAuthorized,
      context: JobTransitionContext(now: fixture.now, reason: "operator authorized retry")
    )
    let queued = try #require(try await fixture.jobs.job(id: awaiting.id))
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:retry-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: fixture.now, reason: "retry lease")
    )
    _ = try await fixture.jobs.transition(
      jobID: queued.id,
      eventKey: "fixture:retry-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: fixture.now, reason: "retry inputs")
    )

    try await fixture.workflow.run(jobID: queued.id)

    #expect(try await fixture.jobs.job(id: queued.id)?.state == .succeeded)
    #expect(try await fixture.jobs.disposition(for: queued.identity)?.mutationGeneration == 1)
    #expect(await fixture.api.createCommentCount == 1)
    #expect(try await fixture.intents.intents(jobID: queued.id).count == 2)
  }

  @Test("reopen advances a durably completed review without rerunning Pi")
  func completedReviewCrashBoundary() async throws {
    let fixture = try await PullRequestReviewJobFixture()
    defer { fixture.remove() }
    let input = try await fixture.artifacts.write(
      jobID: fixture.job.id,
      kind: .input,
      data: Data("durable-input".utf8),
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: fixture.now
    )
    let review = try await fixture.artifacts.write(
      jobID: fixture.job.id,
      kind: .review,
      data: Data("# Durable recovered review\n\nVerdict: accept\n".utf8),
      classification: .public,
      producerRunID: nil,
      now: fixture.now
    )
    try await fixture.jobs.appendCompletedStep(
      jobID: fixture.job.id,
      ordinal: 0,
      kind: .review,
      inputDigest: input.sha256,
      outputDigest: review.sha256,
      mutationID: nil,
      acceptanceEvidence: "durable-review",
      now: fixture.now
    )
    let workspaceDirectory = fixture.repositories.workspacesURL.appendingPathComponent(
      fixture.job.id.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspaceDirectory.appendingPathComponent("repository", isDirectory: true),
      withIntermediateDirectories: true
    )
    try await fixture.database.execute(
      """
      INSERT INTO workspaces(
        job_id, relative_path, base_branch, base_sha,
        local_head_sha, cleanup_state, updated_at
      ) VALUES (?, ?, 'main', ?, ?, 'retained', ?)
      """,
      bindings: [
        .text(fixture.job.id.uuidString.lowercased()),
        .text("\(fixture.job.id.uuidString.lowercased())/repository"),
        .text(fixture.pullRequest.base.sha),
        .text(fixture.pullRequest.head.sha),
        .real(fixture.now.timeIntervalSince1970),
      ]
    )
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'runningPi' WHERE id = ?",
      bindings: [.text(fixture.job.id.uuidString.lowercased())]
    )
    let reopened = try await fixture.reopen()
    let coordinator = JobCoordinator(
      configuration: reopened.configuration,
      discovery: GitHubDiscovery(
        api: fixture.api,
        jobs: reopened.jobs,
        reviewedRevisions: reopened.reviewed
      ),
      jobs: reopened.jobs,
      repositories: reopened.repositories,
      schedulerPersistence: SchedulerPersistence(database: reopened.database),
      workflows: JobWorkflowRegistry(
        pullRequestReview: reopened.workflow,
        issueTriage: reopened.workflow,
        issueImplementation: reopened.workflow,
        complexPlan: reopened.workflow
      ),
      contractVersion: "w6-test",
      now: { Date(timeIntervalSince1970: 90_001) }
    )

    await coordinator.run(pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now))

    #expect(try await reopened.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(await fixture.api.createCommentCount == 1)
    #expect(
      try await reopened.jobs.steps(jobID: fixture.job.id).map(\.kind) == [
        .review, .publish,
      ])
    await reopened.database.close()
  }

  @Test("a fresh coordinator recovers an interrupted production review and replays it to success")
  func startupRecoveryReplay() async throws {
    let fixture = try await PullRequestReviewJobFixture()
    defer { fixture.remove() }
    _ = try await activateTestPullRequestRollout(
      database: fixture.database,
      repository: fixture.repository,
      job: fixture.job,
      baseSHA: fixture.pullRequest.base.sha,
      headSHA: fixture.pullRequest.head.sha,
      now: fixture.now
    )
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'runningPi' WHERE id = ?",
      bindings: [.text(fixture.job.id.uuidString.lowercased())]
    )
    let reopened = try await fixture.reopen()
    let registry = JobWorkflowRegistry(
      pullRequestReview: reopened.workflow,
      issueTriage: reopened.workflow,
      issueImplementation: reopened.workflow,
      complexPlan: reopened.workflow
    )
    let coordinator = JobCoordinator(
      configuration: reopened.configuration,
      discovery: GitHubDiscovery(
        api: fixture.api,
        jobs: reopened.jobs,
        reviewedRevisions: reopened.reviewed
      ),
      jobs: reopened.jobs,
      repositories: reopened.repositories,
      schedulerPersistence: SchedulerPersistence(database: reopened.database),
      workflows: registry,
      contractVersion: "w6-test",
      now: { Date(timeIntervalSince1970: 90_001) }
    )

    await coordinator.run(
      pass: SchedulerPass(reasons: [.startup], startedAt: fixture.now)
    )
    #expect(try await reopened.jobs.job(id: fixture.job.id)?.state == .retryBackoff)
    #expect(try await reopened.jobs.activeLeases().isEmpty)
    try await reopened.database.execute(
      "UPDATE jobs SET not_before = ? WHERE id = ?",
      bindings: [
        .real(fixture.now.addingTimeInterval(-1).timeIntervalSince1970),
        .text(fixture.job.id.uuidString.lowercased()),
      ]
    )

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now)
    )

    #expect(try await reopened.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(await fixture.api.createCommentCount == 1)
    await reopened.database.close()
  }

  @Test("topology recovery bypasses a stale attempt review-selection event exactly once")
  func topologyRecoveryReviewSelection() async throws {
    let fixture = try await PullRequestReviewJobFixture()
    defer { fixture.remove() }
    _ = try await activateTestPullRequestRollout(
      database: fixture.database,
      repository: fixture.repository,
      job: fixture.job,
      baseSHA: fixture.pullRequest.base.sha,
      headSHA: fixture.pullRequest.head.sha,
      now: fixture.now
    )
    let jobID = fixture.job.id.uuidString.lowercased()
    let scope = JobCanaryScope(
      jobID: fixture.job.id,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "a", count: 64),
      maximumCommentParts: 8
    )
    let canary = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: String(repeating: "b", count: 64)
    )
    let evidenceSHA256 = String(repeating: "c", count: 64)
    let prefix = "canary:\(canary.authorizationSHA256):m8:"
    let attempt = try #require(try await fixture.jobs.job(id: fixture.job.id)).attempt
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    try await fixture.database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES
        (?, ?, 'queued', 'leased', 'exact canary admission', \(attempt), \(attempt), 0, 0, 1),
        (?, ?, 'preparing', 'runningPi', 'stale review selection', \(attempt), \(attempt), 0, 0, 2),
        (?, ?, 'runningPi', 'runningPi', 'architecture authorized', \(attempt), \(attempt), 0, 0, 3),
        (?, ?, 'runningPi', 'reconciliationQueued', 'Pi interrupted', \(attempt), \(attempt), 0, 0, 4),
        (?, ?, 'reconciliationQueued', 'reconciliationQueued', 'recovery authorized', \(attempt), \(attempt), 0, 0, 5),
        (?, ?, 'reconciliationQueued', 'preparing', 'recovery resumed', \(attempt), \(attempt), 0, 0, 6)
      """,
      bindings: [
        .text(jobID), .text(prefix + "admit:" + jobID),
        .text(jobID), .text("pr:\(jobID):a\(attempt):s0:run-review"),
        .text(jobID), .text(prefix + "pi:architecture:r1"),
        .text(jobID), .text("job:\(jobID):a\(attempt):s0:pi-interrupted"),
        .text(jobID), .text(prefix + "topology-recovery:" + evidenceSHA256),
        .text(jobID), .text(prefix + "topology-resume:" + evidenceSHA256),
      ]
    )
    try await fixture.database.execute(
      "UPDATE repository_leases SET heartbeat = 6 WHERE job_id = ? AND active = 1",
      bindings: [.text(jobID)]
    )

    await #expect(throws: DurableJobStoreError.canaryRecoveryRequired) {
      _ = try await fixture.jobs.selectCanaryReviewAfterTopologyRecovery(
        jobID: fixture.job.id,
        recoveryEvidenceSHA256: String(repeating: "d", count: 64),
        now: fixture.now
      )
    }
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 0 WHERE singleton = 1"
    )
    await #expect(throws: DurableJobStoreError.canaryRecoveryRequired) {
      _ = try await fixture.jobs.selectCanaryReviewAfterTopologyRecovery(
        jobID: fixture.job.id,
        recoveryEvidenceSHA256: evidenceSHA256,
        now: fixture.now
      )
    }
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    try await fixture.database.execute(
      "UPDATE repository_leases SET heartbeat = 7 WHERE job_id = ? AND active = 1",
      bindings: [.text(jobID)]
    )
    await #expect(throws: DurableJobStoreError.canaryRecoveryRequired) {
      _ = try await fixture.jobs.selectCanaryReviewAfterTopologyRecovery(
        jobID: fixture.job.id,
        recoveryEvidenceSHA256: evidenceSHA256,
        now: fixture.now
      )
    }
    try await fixture.database.execute(
      "UPDATE repository_leases SET heartbeat = 6 WHERE job_id = ? AND active = 1",
      bindings: [.text(jobID)]
    )
    let selected = try await fixture.jobs.selectCanaryReviewAfterTopologyRecovery(
      jobID: fixture.job.id,
      recoveryEvidenceSHA256: evidenceSHA256,
      now: fixture.now
    )
    #expect(selected.state == .runningPi)
    let replayed = try await fixture.jobs.selectCanaryReviewAfterTopologyRecovery(
      jobID: fixture.job.id,
      recoveryEvidenceSHA256: evidenceSHA256,
      now: fixture.now
    )
    #expect(replayed.state == .runningPi)

    try await fixture.workflow.runRecoveredCanary(
      jobID: fixture.job.id,
      recoveryEvidenceSHA256: evidenceSHA256
    )

    #expect(try await fixture.jobs.job(id: fixture.job.id)?.state == .succeeded)
    #expect(await fixture.api.createCommentCount == 1)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
        bindings: [
          .text(jobID),
          .text(prefix + "topology-run-review:*"),
        ]
      ) == 1
    )
  }

  @Test("REST and fetched Git commit divergence stops before review or publication")
  func commitSourceMismatch() async throws {
    let fixture = try await PullRequestReviewJobFixture()
    defer { fixture.remove() }
    await fixture.api.setCommits([
      GitHubPullRequestCommit(sha: String(repeating: "c", count: 40)),
      GitHubPullRequestCommit(sha: fixture.pullRequest.head.sha),
    ])

    await #expect(throws: PullRequestReviewJobError.commitSourcesMismatch) {
      try await fixture.workflow.run(jobID: fixture.job.id)
    }

    #expect(await fixture.api.createCommentCount == 0)
    #expect(try await fixture.artifacts.records(jobID: fixture.job.id).isEmpty)
    #expect(
      !(try await fixture.reviewed.contains(
        repositoryNodeID: fixture.repository.nodeID,
        pullRequestNodeID: fixture.pullRequest.nodeID,
        headSHA: fixture.pullRequest.head.sha
      )))
  }

  @Test("real local Git, review routing, multipart-safe publication, and cleanup complete once")
  func endToEndReview() async throws {
    let fixture = try await PullRequestReviewJobFixture()
    defer { fixture.remove() }

    try await fixture.workflow.run(jobID: fixture.job.id)

    let completed = try #require(try await fixture.jobs.job(id: fixture.job.id))
    #expect(completed.state == .succeeded)
    #expect(
      try await fixture.reviewed.contains(
        repositoryNodeID: fixture.repository.nodeID,
        pullRequestNodeID: fixture.pullRequest.nodeID,
        headSHA: fixture.pullRequest.head.sha
      )
    )
    #expect(
      try await fixture.jobs.steps(jobID: fixture.job.id).map(\.kind) == [
        .review, .publish,
      ])
    #expect(
      try await fixture.intents.intents(jobID: fixture.job.id).allSatisfy {
        $0.state == .attributed
      })
    #expect(
      try await fixture.repositories.workspaceRecord(jobID: fixture.job.id)?.cleanupState
        == .removed)
    #expect(await fixture.api.createCommentCount == 1)
    #expect(
      Set(try await fixture.artifacts.records(jobID: fixture.job.id).map(\.kind)) == [
        .input, .review,
      ])
  }
}

private final class PullRequestReviewJobFixture: @unchecked Sendable {
  let root: URL
  let gitFixture: GitTestRoot
  let database: SQLiteStore
  let remoteURL: URL
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let artifacts: ArtifactStore
  let reviewed: ReviewedRevisionStore
  let repositories: RepositoryStore
  let repository: RepositoryConfiguration
  let pullRequest: GitHubPullRequest
  let api: PullRequestReviewGitHubFixture
  let job: JobRecord
  let workflow: PullRequestReviewJobWorkflow
  let now = Date(timeIntervalSince1970: 90_000)

  init(dropFirstCommentCreate: Bool = false) async throws {
    gitFixture = try GitTestRoot(prefix: "jidoka-pr-review-job")
    root = gitFixture.root
    let source = try await gitFixture.initializeRepository()
    let base = try await gitFixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "test: base"
    )
    let head = try await gitFixture.commit(
      repository: source,
      path: "Sources/Feature.swift",
      contents: "let feature = true\n",
      message: "feat: add feature"
    )
    remoteURL = try await gitFixture.bareRemote(from: source)
    try await gitFixture.run([
      "-C", source.path, "push", remoteURL.path, "\(head):refs/pull/7/head",
    ])

    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
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
        kind: .prReview,
        objectNodeID: "pr-node-7",
        revisionKey: head
      ),
      objectNumber: 7,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: now
    )
    guard case .created(let createdJob) = created else {
      throw PullRequestReviewJobFixtureError.suppressed
    }
    job = createdJob
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

    pullRequest = Self.makePullRequest(base: base, head: head)
    api = PullRequestReviewGitHubFixture(
      pullRequest: pullRequest,
      commits: [GitHubPullRequestCommit(sha: head)],
      dropFirstCommentCreate: dropFirstCommentCreate
    )
    repositories = try RepositoryStore(
      rootURL: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
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
    let inputPreparer = SystemPullRequestReviewJobPreparer(
      configuration: configuration,
      api: api,
      repositories: repositories,
      deriver: GitPullRequestCommitDeriver(git: gitFixture.git),
      remoteResolver: LocalPullRequestRemoteResolver(remote: remote)
    )
    intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    artifacts = try ArtifactStore(
      rootURL: root.appendingPathComponent("Artifacts", isDirectory: true),
      database: database
    )
    reviewed = ReviewedRevisionStore(database: database)
    let publisher = GitHubMarkerPublisher(
      executor: GitHubMutationExecutor(
        intents: intents,
        broker: api,
        authority: authority
      ),
      intents: intents,
      reads: api,
      authority: authority,
      sleeper: PullRequestImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 90_001) }
    )
    workflow = PullRequestReviewJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      intents: intents,
      artifacts: artifacts,
      inputs: inputPreparer,
      reviewer: DeterministicPullRequestReviewer(),
      markerPublisher: publisher,
      reviewedRevisions: reviewed,
      repositories: repositories,
      authorID: 7,
      now: { Date(timeIntervalSince1970: 90_001) }
    )
  }

  func reopen() async throws -> ReopenedPullRequestReviewRuntime {
    await database.close()
    let reopenedDatabase = try SQLiteStore(
      databaseURL: root.appendingPathComponent("state.sqlite3")
    )
    let reopenedConfiguration = ConfigurationStore(database: reopenedDatabase)
    let reopenedJobs = DurableJobStore(database: reopenedDatabase)
    let reopenedRepositories = try RepositoryStore(
      rootURL: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
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
    let input = SystemPullRequestReviewJobPreparer(
      configuration: reopenedConfiguration,
      api: api,
      repositories: reopenedRepositories,
      deriver: GitPullRequestCommitDeriver(git: gitFixture.git),
      remoteResolver: LocalPullRequestRemoteResolver(remote: remote)
    )
    let reopenedIntents = MutationIntentStore(database: reopenedDatabase)
    let authority = ExplicitTestRolloutEffectAuthority(intents: reopenedIntents)
    let reopenedArtifacts = try ArtifactStore(
      rootURL: root.appendingPathComponent("Artifacts", isDirectory: true),
      database: reopenedDatabase
    )
    let reopenedReviewed = ReviewedRevisionStore(database: reopenedDatabase)
    let publisher = GitHubMarkerPublisher(
      executor: GitHubMutationExecutor(
        intents: reopenedIntents,
        broker: api,
        authority: authority
      ),
      intents: reopenedIntents,
      reads: api,
      authority: authority,
      sleeper: PullRequestImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 90_001) }
    )
    let reopenedWorkflow = PullRequestReviewJobWorkflow(
      jobs: reopenedJobs,
      configuration: reopenedConfiguration,
      intents: reopenedIntents,
      artifacts: reopenedArtifacts,
      inputs: input,
      reviewer: DeterministicPullRequestReviewer(),
      markerPublisher: publisher,
      reviewedRevisions: reopenedReviewed,
      repositories: reopenedRepositories,
      authorID: 7,
      now: { Date(timeIntervalSince1970: 90_001) }
    )
    return ReopenedPullRequestReviewRuntime(
      database: reopenedDatabase,
      configuration: reopenedConfiguration,
      jobs: reopenedJobs,
      reviewed: reopenedReviewed,
      repositories: reopenedRepositories,
      workflow: reopenedWorkflow
    )
  }

  func remove() {
    gitFixture.remove()
  }

  private static func makePullRequest(base: String, head: String) -> GitHubPullRequest {
    let repository = GitHubPullRepository(
      id: 1,
      nodeID: "repository-node",
      fullName: "owner/repo"
    )
    return GitHubPullRequest(
      id: 7,
      nodeID: "pr-node-7",
      number: 7,
      state: "open",
      draft: false,
      title: "Add feature",
      body: "Untrusted body",
      htmlURL: "https://github.com/owner/repo/pull/7",
      user: GitHubUser(id: 2, nodeID: "author-node", login: "author"),
      head: GitHubPullReference(ref: "feature", sha: head, repository: repository),
      base: GitHubPullReference(ref: "main", sha: base, repository: repository)
    )
  }
}

private struct ReopenedPullRequestReviewRuntime {
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let reviewed: ReviewedRevisionStore
  let repositories: RepositoryStore
  let workflow: PullRequestReviewJobWorkflow
}

private struct LocalPullRequestRemoteResolver: GitRemoteRepositoryResolving {
  let remote: GitRemoteRepository

  func remote(for repository: RepositoryConfiguration) throws -> GitRemoteRepository {
    remote
  }
}

private struct DeterministicPullRequestReviewer: PullRequestReviewExecuting {
  func review(
    job: JobRecord,
    prepared: PreparedPullRequestReviewJob,
    artifactSHA256: String
  ) async throws -> PiPullRequestReviewOutput {
    let digest = try PiPullRequestReviewRouter.commitNarrativeDigest(
      prepared.fetched.narrative,
      baseSHA: prepared.fetched.baseSHA
    )
    let synthesis = PiPRReviewPayload(
      verdict: "pass",
      severity: .minor,
      summary: "The exact fetched revision passed deterministic review.",
      domain: .synthesis,
      commitNarrativeSHA256: digest,
      evidence: ["local Git and REST commit sets match"],
      findings: [
        PiWorkflowFinding(
          severity: .minor,
          path: "Sources/Feature.swift",
          line: 1,
          evidence: "fixture evidence",
          recommendation: "retain the bounded implementation"
        )
      ]
    )
    return PiPullRequestReviewOutput(
      commitNarrativeSHA256: digest,
      roleResults: [],
      synthesis: synthesis,
      effectiveVerdict: "pass",
      effectiveSeverity: .minor
    )
  }
}

private actor PullRequestReviewGitHubFixture: GitHubReadAPI, PullRequestReviewGitHubAPI,
  GitHubMutationSending
{
  let pullRequestValue: GitHubPullRequest
  private var commits: [GitHubPullRequestCommit]
  private var comments: [GitHubComment] = []
  private var dropFirstCommentCreate: Bool
  private var droppedCommentBody: String?
  private(set) var createCommentCount = 0
  private(set) var sendAttemptCount = 0

  init(
    pullRequest: GitHubPullRequest,
    commits: [GitHubPullRequestCommit],
    dropFirstCommentCreate: Bool
  ) {
    pullRequestValue = pullRequest
    self.commits = commits
    self.dropFirstCommentCreate = dropFirstCommentCreate
  }

  func setCommits(_ values: [GitHubPullRequestCommit]) {
    commits = values
  }

  func materializeDroppedComment() {
    guard let body = droppedCommentBody else { return }
    droppedCommentBody = nil
    createCommentCount += 1
    appendComment(body: body)
  }

  func listPullRequestCommits(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> [GitHubPullRequestCommit] {
    commits
  }

  func listPullRequests(owner: String, repository: String) async throws
    -> [GitHubPullRequest]
  {
    [pullRequestValue]
  }

  func listIssues(owner: String, repository: String) async throws -> [GitHubIssue] {
    []
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    pullRequestValue
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw PullRequestReviewJobFixtureError.unexpectedOperation
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    comments
  }

  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  {
    []
  }

  func lookupPullRequests(
    owner: String,
    repository: String,
    head: String,
    base: String
  ) async throws -> [GitHubPullRequest] {
    [pullRequestValue]
  }

  func repositoryLabel(owner: String, repository: String, label: String) async throws
    -> GitHubLabel?
  {
    nil
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse {
    _ = try await beforeSend()
    guard case .createComment(_, _, _, let body) = operation else {
      throw PullRequestReviewJobFixtureError.unexpectedOperation
    }
    sendAttemptCount += 1
    if dropFirstCommentCreate {
      dropFirstCommentCreate = false
      droppedCommentBody = body
      throw URLError(.networkConnectionLost)
    }
    createCommentCount += 1
    appendComment(body: body)
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: 201,
      headers: [:],
      body: Data()
    )
  }

  private func appendComment(body: String) {
    comments.append(
      GitHubComment(
        id: Int64(createCommentCount),
        nodeID: "comment-\(createCommentCount)",
        body: body,
        user: GitHubUser(id: 7, nodeID: "jidoka-user", login: "jidoka-code"),
        createdAt: "2026-08-08T00:00:00Z",
        updatedAt: "2026-08-08T00:00:00Z",
        htmlURL: "https://github.com/owner/repo/pull/7#issuecomment-\(createCommentCount)"
      )
    )
  }
}

private struct PullRequestImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum PullRequestReviewJobFixtureError: Error {
  case suppressed
  case unexpectedOperation
}
