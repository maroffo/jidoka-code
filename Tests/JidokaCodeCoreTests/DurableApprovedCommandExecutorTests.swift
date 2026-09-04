import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Crash-safe approved command executor")
struct DurableApprovedCommandExecutorTests {
  @Test("an effect followed by lost evidence becomes unknown and never starts again")
  func effectWithoutEvidenceIsUnknown() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: true)
    defer { fixture.remove() }

    await #expect(throws: ApprovedCommandRunStoreError.self) {
      _ = try await fixture.executeBootstrap(using: fixture.executor)
    }
    #expect(await fixture.process.targetExecutions() == 1)
    #expect(try fixture.effectCount() == 1)
    let run = try #require(try await fixture.store.runs(jobID: fixture.job.id).first)
    #expect(run.state == .unknown)
    #expect(
      try await fixture.authority.latestStatus()?.reservations.first?.state == .sendStarted
    )

    let reopenedStore = ApprovedCommandRunStore(database: fixture.database)
    let reopenedExecutor = DurableApprovedCommandExecutor(
      job: fixture.job,
      store: reopenedStore,
      gate: fixture.gate,
      runner: fixture.runner,
      authority: fixture.authority,
      workspace: fixture.workspace,
      now: { Date(timeIntervalSince1970: 210_001) }
    )
    await #expect(throws: ApprovedCommandRunStoreError.outcomeUnknown(run.id)) {
      _ = try await fixture.executeBootstrap(using: reopenedExecutor)
    }
    #expect(await fixture.process.targetExecutions() == 1)
    #expect(try fixture.effectCount() == 1)
  }

  @Test("an accepted result replays after store reopen without another process effect")
  func acceptedEvidenceReplays() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }

    let first = try await fixture.executeBootstrap(using: fixture.executor)
    #expect(first.succeeded)
    #expect(await fixture.process.targetExecutions() == 1)
    #expect(try fixture.effectCount() == 1)

    let replayProcess = FaultAfterEffectProcess(
      targetExecutable: fixture.workspace.appendingPathComponent("scripts/effect").path,
      failAfterFirstEffect: false
    )
    let replayRunner = VerificationCommandRunner(
      process: replayProcess,
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let replayExecutor = DurableApprovedCommandExecutor(
      job: fixture.job,
      store: ApprovedCommandRunStore(database: fixture.database),
      gate: fixture.gate,
      runner: replayRunner,
      authority: fixture.authority,
      workspace: fixture.workspace,
      now: { Date(timeIntervalSince1970: 210_001) }
    )
    let replay = try await fixture.executeBootstrap(using: replayExecutor)

    #expect(replay == first)
    #expect(await replayProcess.targetExecutions() == 0)
    #expect(try fixture.effectCount() == 1)
  }

  @Test("an accepted local result settles its exact send-started reservation after restart")
  func acceptedLocalResultReconcilesAfterRestart() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }
    let effect = try await fixture.commandEffect()
    let run = try await fixture.prepareCommandRun()
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.job.id))
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      let permit = try await fixture.authority.reserveApprovedCommand(
        effect,
        now: Date(timeIntervalSince1970: 210_002)
      )
      try await fixture.authority.bindApprovedCommandReservation(
        permit,
        effect: effect,
        runID: run.id,
        now: Date(timeIntervalSince1970: 210_002)
      )
      _ = try await fixture.store.start(runID: run.id)
      try await fixture.authority.verifyApprovedCommandPermit(permit, effect: effect)
      return permit
    }
    guard case .reservation(let reservationID) = permit else {
      Issue.record("approved command did not receive a durable reservation")
      return
    }
    let evidence = try await fixture.acceptedEvidence()
    _ = try await fixture.store.accept(runID: run.id, evidence: evidence)
    #expect(
      try await fixture.authority.latestStatus()?.reservations.first?.state == .sendStarted
    )

    let reopened = RolloutAuthorityStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 210_003) }
    )
    #expect(
      try await reopened.reconcileLocalEffectResults(
        now: Date(timeIntervalSince1970: 210_003)
      ) == 1
    )
    #expect(
      try await reopened.reconcileLocalEffectResults(
        now: Date(timeIntervalSince1970: 210_004)
      ) == 0
    )
    #expect(try await reopened.latestStatus()?.reservations.first?.state == .settled)
    #expect(
      try await fixture.database.scalarText(
        """
        SELECT approved_command_run_id FROM rollout_local_effect_bindings
        WHERE reservation_id = ?
        """,
        bindings: [.text(reservationID)]
      ) == run.id
    )

    let replayProcess = FaultAfterEffectProcess(
      targetExecutable: fixture.workspace.appendingPathComponent("scripts/effect").path,
      failAfterFirstEffect: false
    )
    let replayExecutor = DurableApprovedCommandExecutor(
      job: fixture.job,
      store: ApprovedCommandRunStore(database: fixture.database),
      gate: fixture.gate,
      runner: VerificationCommandRunner(
        process: replayProcess,
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      ),
      authority: reopened,
      workspace: fixture.workspace,
      now: { Date(timeIntervalSince1970: 210_004) }
    )
    #expect(try await fixture.executeBootstrap(using: replayExecutor) == evidence)
    #expect(await replayProcess.targetExecutions() == 0)
    #expect(try await reopened.latestStatus()?.reservations.count == 1)
  }

  @Test("an approved-command permit is task-bound and consumed before process creation")
  func commandPermitIsSingleUse() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }
    let effect = try await fixture.commandEffect()
    let run = try await fixture.prepareCommandRun()
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.job.id))
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      let permit = try await fixture.authority.reserveApprovedCommand(
        effect,
        now: Date(timeIntervalSince1970: 210_002)
      )
      try await fixture.authority.bindApprovedCommandReservation(
        permit,
        effect: effect,
        runID: run.id,
        now: Date(timeIntervalSince1970: 210_002)
      )
      return permit
    }

    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await fixture.authority.verifyApprovedCommandPermit(permit, effect: effect)
    }
    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.verifyApprovedCommandPermit(permit, effect: effect)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.verifyApprovedCommandPermit(permit, effect: effect)
      }
    }
    #expect(await fixture.process.targetExecutions() == 0)
    try await fixture.authority.settleEffect(
      permit,
      evidenceSHA256: String(repeating: "e", count: 64),
      now: Date(timeIntervalSince1970: 210_003)
    )
  }

  @Test("closing admission after command reservation denies process creation")
  func stopAfterCommandReservationDeniesLaunch() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }
    let effect = try await fixture.commandEffect()
    let run = try await fixture.prepareCommandRun()
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.job.id))
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      let permit = try await fixture.authority.reserveApprovedCommand(
        effect,
        now: Date(timeIntervalSince1970: 210_002)
      )
      try await fixture.authority.bindApprovedCommandReservation(
        permit,
        effect: effect,
        runID: run.id,
        now: Date(timeIntervalSince1970: 210_002)
      )
      return permit
    }
    await fixture.authority.closeAdmission()

    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.verifyApprovedCommandPermit(permit, effect: effect)
      }
    }
    #expect(await fixture.process.targetExecutions() == 0)
    try await fixture.authority.settleEffect(
      permit,
      evidenceSHA256: String(repeating: "f", count: 64),
      now: Date(timeIntervalSince1970: 210_003)
    )
  }

  @Test("a Git send permit is task-bound and consumed before transport")
  func gitSendPermitIsSingleUse() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }
    try await fixture.moveJobToPush()
    let (intents, effect) = try await fixture.gitSendEffect()
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.job.id))
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.reserveGitSendAndMarkStarted(
        effect,
        now: Date(timeIntervalSince1970: 210_002)
      )
    }

    #expect(try await intents.intent(id: effect.intentID)?.state == .sendStarted)
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await fixture.authority.verifyGitSendPermit(permit, effect: effect)
    }
    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.verifyGitSendPermit(permit, effect: effect)
    }
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.verifyGitSendPermit(permit, effect: effect)
      }
    }
    let status = try await fixture.authority.latestStatus()
    #expect(status?.reservations.last?.state == .observationRequired)
    _ = try await intents.markReconcileRequired(
      id: effect.intentID,
      now: Date(timeIntervalSince1970: 210_003)
    )
    _ = try await intents.settle(
      id: effect.intentID,
      outcome: .safeRetry,
      evidenceDigest: String(repeating: "7", count: 64),
      now: Date(timeIntervalSince1970: 210_004)
    )
    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.recordMutationObservation(
        intentID: effect.intentID,
        observation: .settled,
        evidenceSHA256: String(repeating: "7", count: 64),
        now: Date(timeIntervalSince1970: 210_004)
      )
    }
  }
}

private final class DurableCommandExecutorFixture: @unchecked Sendable {
  let gitFixture: GitTestRoot
  let root: URL
  let workspace: URL
  let effectFile: URL
  let database: SQLiteStore
  let store: ApprovedCommandRunStore
  let gate: ApprovedCommandExecutionGate
  let job: JobRecord
  let command: ApprovedCommand
  let plan: FrozenCommandPlan
  let repository: RepositoryConfiguration
  let process: FaultAfterEffectProcess
  let runner: VerificationCommandRunner
  let authority: RolloutAuthorityStore
  let executor: DurableApprovedCommandExecutor

  init(failAfterFirstEffect: Bool) async throws {
    gitFixture = try GitTestRoot(prefix: "jidoka-durable-command-executor")
    root = gitFixture.root
    workspace = try await gitFixture.initializeRepository()
    effectFile = root.appendingPathComponent("effect-count")
    let scripts = workspace.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(
      at: scripts,
      withIntermediateDirectories: false
    )
    let script = scripts.appendingPathComponent("effect")
    let source = "#!/bin/sh\nset -eu\nprintf 'effect\\n' >> '\(effectFile.path)'\n"
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: script.path
    )
    try await gitFixture.run(["-C", workspace.path, "add", "--", "scripts/effect"])
    try await gitFixture.run([
      "-C", workspace.path, "commit", "-m", "test: add durable effect fixture",
    ])

    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let configuration = ConfigurationStore(database: database)
    let repositoryID = UUID()
    repository = RepositoryConfiguration(
      id: repositoryID,
      nodeID: "repository-node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(
      repository,
      now: Date(timeIntervalSince1970: 210_000)
    )
    let jobs = DurableJobStore(database: database)
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "issue-node",
        revisionKey: String(repeating: "a", count: 64)
      ),
      objectNumber: 1,
      contractVersionUsed: "command-test",
      priority: .issueImplementation,
      firstStep: .orchestrate,
      now: Date(timeIntervalSince1970: 210_000)
    )
    guard case .created(let created) = creation else {
      throw DurableCommandExecutorFixtureError.suppressed
    }
    let leased = durableCommandJob(
      try await jobs.transition(
        jobID: created.id,
        eventKey: "durable-command:lease",
        event: .acquireLease,
        context: JobTransitionContext(now: created.createdAt, reason: "fixture lease")
      )
    )
    let preparing = durableCommandJob(
      try await jobs.transition(
        jobID: leased.id,
        eventKey: "durable-command:inputs",
        event: .inputsValidated,
        context: JobTransitionContext(now: created.createdAt, reason: "fixture inputs")
      )
    )
    job = durableCommandJob(
      try await jobs.transition(
        jobID: preparing.id,
        eventKey: "durable-command:pi",
        event: .selectPiStep,
        context: JobTransitionContext(now: created.createdAt, reason: "fixture Pi step")
      )
    )
    command = makeApprovedCommand(
      id: "effect",
      kind: .repositoryScript,
      executable: "scripts/effect",
      arguments: [],
      sourceDigest: GitHubMarkerCodec.sha256(try Data(contentsOf: script))
    )
    plan = try makeFrozenPlan([command])
    store = ApprovedCommandRunStore(database: database)
    gate = ApprovedCommandExecutionGate()
    await gate.open()
    process = FaultAfterEffectProcess(
      targetExecutable: script.path,
      failAfterFirstEffect: failAfterFirstEffect
    )
    runner = VerificationCommandRunner(
      process: process,
      homeDirectory: root.path,
      temporaryDirectory: root.path
    )
    let workspaceHeadSHA = try await gitFixture.output([
      "-C", workspace.path, "rev-parse", "HEAD",
    ])
    authority = try await activateTestImplementationRollout(
      database: database,
      repository: repository,
      job: job,
      plan: plan,
      workspaceHeadSHA: workspaceHeadSHA,
      now: Date(timeIntervalSince1970: 210_001),
      currentTime: { Date(timeIntervalSince1970: 210_002) },
      includeGitPublicationBudget: true
    )
    executor = DurableApprovedCommandExecutor(
      job: job,
      store: store,
      gate: gate,
      runner: runner,
      authority: authority,
      workspace: workspace,
      now: { Date(timeIntervalSince1970: 210_002) }
    )
  }

  func executeBootstrap(
    using executor: DurableApprovedCommandExecutor
  ) async throws -> VerificationCommandEvidence {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: job.id))
    ) {
      try await executor.executeBootstrap(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan
      )
    }
  }

  func commandEffect() async throws -> RolloutApprovedCommandEffect {
    let workspaceHeadSHA = try await gitFixture.output([
      "-C", workspace.path, "rev-parse", "HEAD",
    ])
    return RolloutApprovedCommandEffect(
      jobID: job.id,
      commandID: command.id,
      definitionSHA256: command.definitionDigest,
      planSHA256: plan.digest,
      workspaceHeadSHA: workspaceHeadSHA,
      phase: .bootstrap,
      round: 1,
      ordinal: 0
    )
  }

  func prepareCommandRun() async throws -> ApprovedCommandRunRecord {
    try await store.prepare(
      job: job,
      phase: .bootstrap,
      round: 1,
      commandOrdinal: 0,
      command: command,
      planSHA256: plan.digest,
      workspace: try ApprovedCommandWorkspaceIdentity(url: workspace)
    )
  }

  func acceptedEvidence() async throws -> VerificationCommandEvidence {
    VerificationCommandEvidence(
      commandID: command.id,
      registryKind: command.registryKind,
      definitionDigest: command.definitionDigest,
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      durationMilliseconds: 1,
      stdoutSHA256: String(repeating: "a", count: 64),
      stderrSHA256: String(repeating: "b", count: 64),
      stdoutExcerpt: "accepted before interrupted acknowledgement",
      stderrExcerpt: "",
      repositoryHeadSHA: nil,
      approvedHookPath: command.approvedHookPath,
      gitConfigurationDigest: nil,
      repositoryStateSHA256: try await runner.repositoryStateSHA256(
        workspace: workspace,
        plan: plan
      )
    )
  }

  func gitSendEffect() async throws -> (MutationIntentStore, RolloutGitSendEffect) {
    let intents = MutationIntentStore(database: database)
    let branch = "agent/issue-42-rollout"
    let exactSHA = try await gitFixture.output([
      "-C", workspace.path, "rev-parse", "HEAD",
    ])
    let target = "repository:\(repository.nodeID):refs/heads/\(branch)"
    let expectedStateSHA256 = GitHubMarkerCodec.sha256(Data("git-before-state".utf8))
    let requestSHA256 = GitHubMarkerCodec.sha256(
      Data("git-send:\(repository.nodeID):\(branch):\(exactSHA)".utf8)
    )
    let intent = try await intents.prepare(
      jobID: job.id,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("git-send-intent".utf8)),
      operation: .publishBranch,
      target: target,
      expectedStateDigest: expectedStateSHA256,
      requestDigest: requestSHA256,
      now: Date(timeIntervalSince1970: 210_002)
    )
    return (
      intents,
      RolloutGitSendEffect(
        jobID: job.id,
        intentID: intent.id,
        repositoryID: repository.id,
        repositoryNodeID: repository.nodeID,
        branch: branch,
        exactSHA: exactSHA,
        target: target,
        expectedStateSHA256: expectedStateSHA256,
        requestSHA256: requestSHA256
      )
    )
  }

  func moveJobToPush() async throws {
    guard
      try await database.execute(
        "UPDATE jobs SET state = 'executing', current_step = current_step + 1, current_step_kind = 'push', updated_at = ? WHERE id = ?",
        bindings: [
          .real(Date(timeIntervalSince1970: 210_002).timeIntervalSince1970),
          .text(job.id.uuidString.lowercased()),
        ]
      ) == 1
    else {
      throw DurableCommandExecutorFixtureError.suppressed
    }
  }

  func effectCount() throws -> Int {
    guard FileManager.default.fileExists(atPath: effectFile.path) else { return 0 }
    return try String(contentsOf: effectFile, encoding: .utf8)
      .split(separator: "\n").count
  }

  func remove() {
    gitFixture.remove()
  }
}

private actor FaultAfterEffectProcess: GitProcessExecuting {
  private let underlying = BoundedProcessRunner()
  private let targetExecutable: String
  private let failAfterFirstEffect: Bool
  private var targetCount = 0
  private var faultDelivered = false

  init(targetExecutable: String, failAfterFirstEffect: Bool) {
    self.targetExecutable = targetExecutable
    self.failAfterFirstEffect = failAfterFirstEffect
  }

  func run(_ request: GitProcessRequest) async throws -> GitProcessResult {
    let result = try await underlying.run(request)
    guard request.executable.path == targetExecutable else { return result }
    targetCount += 1
    if failAfterFirstEffect, !faultDelivered {
      faultDelivered = true
      throw URLError(.networkConnectionLost)
    }
    return result
  }

  func targetExecutions() -> Int {
    targetCount
  }
}

private func durableCommandJob(_ result: JobTransitionResult) -> JobRecord {
  switch result {
  case .applied(let job), .duplicate(let job): job
  }
}

private enum DurableCommandExecutorFixtureError: Error {
  case suppressed
}
