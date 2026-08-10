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
      _ = try await fixture.executor.executeBootstrap(
        commandID: fixture.command.id,
        expectedPlanDigest: fixture.plan.digest,
        plan: fixture.plan
      )
    }
    #expect(await fixture.process.targetExecutions() == 1)
    #expect(try fixture.effectCount() == 1)
    let run = try #require(try await fixture.store.runs(jobID: fixture.job.id).first)
    #expect(run.state == .unknown)

    let reopenedStore = ApprovedCommandRunStore(database: fixture.database)
    let reopenedExecutor = DurableApprovedCommandExecutor(
      job: fixture.job,
      store: reopenedStore,
      gate: fixture.gate,
      runner: fixture.runner,
      workspace: fixture.workspace
    )
    await #expect(throws: ApprovedCommandRunStoreError.outcomeUnknown(run.id)) {
      _ = try await reopenedExecutor.executeBootstrap(
        commandID: fixture.command.id,
        expectedPlanDigest: fixture.plan.digest,
        plan: fixture.plan
      )
    }
    #expect(await fixture.process.targetExecutions() == 1)
    #expect(try fixture.effectCount() == 1)
  }

  @Test("an accepted result replays after store reopen without another process effect")
  func acceptedEvidenceReplays() async throws {
    let fixture = try await DurableCommandExecutorFixture(failAfterFirstEffect: false)
    defer { fixture.remove() }

    let first = try await fixture.executor.executeBootstrap(
      commandID: fixture.command.id,
      expectedPlanDigest: fixture.plan.digest,
      plan: fixture.plan
    )
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
    let replay = try await DurableApprovedCommandExecutor(
      job: fixture.job,
      store: ApprovedCommandRunStore(database: fixture.database),
      gate: fixture.gate,
      runner: replayRunner,
      workspace: fixture.workspace
    ).executeBootstrap(
      commandID: fixture.command.id,
      expectedPlanDigest: fixture.plan.digest,
      plan: fixture.plan
    )

    #expect(replay == first)
    #expect(await replayProcess.targetExecutions() == 0)
    #expect(try fixture.effectCount() == 1)
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
  let process: FaultAfterEffectProcess
  let runner: VerificationCommandRunner
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
    try await configuration.upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "repository-node",
        owner: "owner",
        name: "repo",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: true,
        implementationEnabled: true,
        enabled: true
      ),
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
    executor = DurableApprovedCommandExecutor(
      job: job,
      store: store,
      gate: gate,
      runner: runner,
      workspace: workspace
    )
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
