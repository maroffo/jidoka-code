import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable approved command authority")
struct ApprovedCommandRunStoreTests {
  @Test("prepare start result and replay are immutable and idempotent")
  func lifecycle() async throws {
    let fixture = try await ApprovedCommandStoreFixture(prefix: "command-lifecycle")
    defer { fixture.remove() }
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let plan = try makeFrozenPlan([command])

    let prepared = try await fixture.prepare(command: command, plan: plan)
    let duplicate = try await fixture.prepare(command: command, plan: plan)
    #expect(duplicate == prepared)
    let started = try await fixture.store.start(runID: prepared.id)
    #expect(started.state == .started)
    await #expect(throws: ApprovedCommandRunStoreError.outcomeUnknown(prepared.id)) {
      _ = try await fixture.store.start(runID: prepared.id)
    }

    let evidence = Self.evidence(command: command, succeeded: true)
    let accepted = try await fixture.store.accept(runID: prepared.id, evidence: evidence)
    #expect(accepted.state == .resultAccepted)
    #expect(try await fixture.store.acceptedEvidence(runID: prepared.id) == evidence)
    #expect(try await fixture.store.accept(runID: prepared.id, evidence: evidence) == accepted)
    await #expect(throws: ApprovedCommandRunStoreError.divergentResult) {
      _ = try await fixture.store.accept(
        runID: prepared.id,
        evidence: Self.evidence(command: command, succeeded: false)
      )
    }
    #expect(
      try await fixture.store.events(runID: prepared.id).map(\.kind)
        == [.prepared, .started, .resultAccepted]
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE approved_command_results SET evidence_sha256 = ? WHERE run_id = ?",
        bindings: [
          .text(String(repeating: "f", count: 64)),
          .text(prepared.id),
        ]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "DELETE FROM approved_command_events WHERE run_id = ?",
        bindings: [.text(prepared.id)]
      )
    }
  }

  @Test("started commands become irreversible unknown and a new generation cannot bypass them")
  func unknownAcrossGeneration() async throws {
    let fixture = try await ApprovedCommandStoreFixture(prefix: "command-unknown")
    defer { fixture.remove() }
    let command = makeApprovedCommand(
      id: "commit",
      kind: .gitCommit,
      executable: "git",
      arguments: ["test: durable command"],
      approvedHookPath: ".githooks"
    )
    let plan = try makeFrozenPlan([command])
    let prepared = try await fixture.prepare(command: command, plan: plan)
    _ = try await fixture.store.start(runID: prepared.id)

    let recovered = try await fixture.store.recoverAtStartup()
    #expect(recovered.map(\.id) == [prepared.id])
    #expect(try await fixture.store.run(id: prepared.id)?.state == .unknown)
    #expect(
      try await fixture.store.events(runID: prepared.id).map(\.kind)
        == [.prepared, .started, .unknown]
    )

    try await fixture.insertLostTopologyGeneration()
    let replay = try await fixture.prepare(command: command, plan: plan)
    #expect(replay.id == prepared.id)
    await #expect(throws: ApprovedCommandRunStoreError.outcomeUnknown(prepared.id)) {
      _ = try await fixture.store.start(runID: replay.id)
    }
  }

  @Test("logical slot collisions and durable pause fail before start")
  func collisionAndPause() async throws {
    let fixture = try await ApprovedCommandStoreFixture(prefix: "command-collision")
    defer { fixture.remove() }
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let plan = try makeFrozenPlan([command])
    let prepared = try await fixture.prepare(command: command, plan: plan)
    let changed = makeApprovedCommand(
      id: "test",
      kind: .makeTargets,
      executable: "make",
      arguments: ["test"]
    )
    let changedPlan = try makeFrozenPlan([changed])
    await #expect(throws: ApprovedCommandRunStoreError.identityCollision) {
      _ = try await fixture.store.prepare(
        job: fixture.job,
        phase: .bootstrap,
        round: 1,
        commandOrdinal: 0,
        command: changed,
        planSHA256: changedPlan.digest,
        workspace: fixture.workspaceIdentity
      )
    }

    _ = try await fixture.database.execute(
      "UPDATE jobs SET state = 'blocked' WHERE id = ?",
      bindings: [.text(fixture.job.id.uuidString.lowercased())]
    )
    await #expect(throws: ApprovedCommandRunStoreError.identityCollision) {
      _ = try await fixture.store.start(runID: prepared.id)
    }
    _ = try await fixture.database.execute(
      "UPDATE jobs SET state = 'runningPi' WHERE id = ?",
      bindings: [.text(fixture.job.id.uuidString.lowercased())]
    )
    try await fixture.configuration.setPaused(
      true,
      now: Date(timeIntervalSince1970: 200_001)
    )
    await #expect(throws: ApprovedCommandRunStoreError.launchSuppressed) {
      _ = try await fixture.store.start(runID: prepared.id)
    }
    #expect(try await fixture.store.run(id: prepared.id)?.state == .prepared)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE approved_command_runs SET state = 'started' WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
  }

  @Test("pause closure waits for admitted commands and rejects later starts")
  func pauseBarrier() async throws {
    let gate = ApprovedCommandExecutionGate(initiallyAllowed: true)
    let lease = try await gate.acquire()
    let probe = ApprovedCommandGateProbe()
    let closing = Task {
      await gate.closeAndWait()
      await probe.markClosed()
    }
    await Task.yield()
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(!(await probe.closed))
    await gate.release(lease)
    await closing.value
    #expect(await probe.closed)
    await #expect(throws: ApprovedCommandRunStoreError.launchSuppressed) {
      _ = try await gate.acquire()
    }
  }

  @Test("a stale never-started attempt is superseded before a new start grant")
  func stalePreparedAttemptIsSuperseded() async throws {
    let fixture = try await ApprovedCommandStoreFixture(prefix: "command-supersede")
    defer { fixture.remove() }
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let plan = try makeFrozenPlan([command])
    let stale = try await fixture.prepare(command: command, plan: plan)
    _ = try await fixture.database.execute(
      "UPDATE jobs SET attempt = attempt + 1 WHERE id = ?",
      bindings: [.text(fixture.job.id.uuidString.lowercased())]
    )
    let current = try #require(try await fixture.jobs.job(id: fixture.job.id))
    let replacement = try await fixture.store.prepare(
      job: current,
      phase: .bootstrap,
      round: 1,
      commandOrdinal: 0,
      command: command,
      planSHA256: plan.digest,
      workspace: fixture.workspaceIdentity
    )

    #expect(replacement.id != stale.id)
    #expect(replacement.jobAttempt == current.attempt)
    #expect(try await fixture.store.run(id: stale.id)?.state == .superseded)
    #expect(try await fixture.store.start(runID: replacement.id).state == .started)
    await #expect(throws: ApprovedCommandRunStoreError.invalidTransition) {
      _ = try await fixture.store.start(runID: stale.id)
    }
  }

  @Test("command prefix ordering requires accepted evidence")
  func prefixOrdering() async throws {
    let fixture = try await ApprovedCommandStoreFixture(prefix: "command-order")
    defer { fixture.remove() }
    let first = makeApprovedCommand(
      id: "first",
      kind: .makeTargets,
      executable: "make",
      arguments: ["first"]
    )
    let second = makeApprovedCommand(
      id: "second",
      kind: .makeTargets,
      executable: "make",
      arguments: ["second"]
    )
    let plan = try makeFrozenPlan([first, second])
    let firstRun = try await fixture.prepare(command: first, plan: plan, ordinal: 0)
    let secondRun = try await fixture.prepare(command: second, plan: plan, ordinal: 1)
    await #expect(throws: ApprovedCommandRunStoreError.invalidTransition) {
      _ = try await fixture.store.start(runID: secondRun.id)
    }
    _ = try await fixture.store.start(runID: firstRun.id)
    _ = try await fixture.store.accept(
      runID: firstRun.id,
      evidence: Self.evidence(command: first, succeeded: true)
    )
    #expect(try await fixture.store.start(runID: secondRun.id).state == .started)
  }

  private static func evidence(
    command: ApprovedCommand,
    succeeded: Bool
  ) -> VerificationCommandEvidence {
    VerificationCommandEvidence(
      commandID: command.id,
      registryKind: command.registryKind,
      definitionDigest: command.definitionDigest,
      exitCode: succeeded ? 0 : 1,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      durationMilliseconds: 1,
      stdoutSHA256: String(repeating: "a", count: 64),
      stderrSHA256: String(repeating: "b", count: 64),
      stdoutExcerpt: succeeded ? "pass" : "failed",
      stderrExcerpt: "",
      repositoryHeadSHA: nil,
      approvedHookPath: command.approvedHookPath,
      gitConfigurationDigest: nil,
      repositoryStateSHA256: String(repeating: succeeded ? "c" : "d", count: 64)
    )
  }
}

private actor ApprovedCommandGateProbe {
  private(set) var closed = false

  func markClosed() {
    closed = true
  }
}

private final class ApprovedCommandStoreFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let store: ApprovedCommandRunStore
  let repositoryID: UUID
  let repository: RepositoryConfiguration
  let job: JobRecord
  let workspaceIdentity: ApprovedCommandWorkspaceIdentity
  private var rolloutAuthority: RolloutAuthorityStore?

  init(prefix: String) async throws {
    root = try makeApprovedCommandTemporaryDirectory(prefix: prefix)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    configuration = ConfigurationStore(database: database)
    repositoryID = UUID()
    repository = RepositoryConfiguration(
      id: repositoryID,
      nodeID: "repository-\(repositoryID.uuidString.lowercased())",
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
      now: Date(timeIntervalSince1970: 200_000)
    )
    jobs = DurableJobStore(database: database)
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "issue-\(UUID().uuidString.lowercased())",
        revisionKey: String(repeating: "e", count: 64)
      ),
      objectNumber: 1,
      contractVersionUsed: "command-test",
      priority: .issueImplementation,
      firstStep: .orchestrate,
      now: Date(timeIntervalSince1970: 200_000)
    )
    guard case .created(let value) = creation else {
      throw ApprovedCommandStoreFixtureError.suppressed
    }
    let leased = approvedCommandJob(
      try await jobs.transition(
        jobID: value.id,
        eventKey: "command-fixture:lease",
        event: .acquireLease,
        context: JobTransitionContext(now: value.createdAt, reason: "command fixture lease")
      )
    )
    let preparing = approvedCommandJob(
      try await jobs.transition(
        jobID: leased.id,
        eventKey: "command-fixture:inputs",
        event: .inputsValidated,
        context: JobTransitionContext(now: value.createdAt, reason: "command fixture inputs")
      )
    )
    job = approvedCommandJob(
      try await jobs.transition(
        jobID: preparing.id,
        eventKey: "command-fixture:pi",
        event: .selectPiStep,
        context: JobTransitionContext(now: value.createdAt, reason: "command fixture Pi step")
      )
    )
    store = ApprovedCommandRunStore(
      database: database,
      now: { Date(timeIntervalSince1970: 200_000) }
    )
    workspaceIdentity = try ApprovedCommandWorkspaceIdentity(url: workspace)
  }

  func prepare(
    command: ApprovedCommand,
    plan: FrozenCommandPlan,
    ordinal: Int = 0
  ) async throws -> ApprovedCommandRunRecord {
    if rolloutAuthority == nil {
      rolloutAuthority = try await activateTestImplementationRollout(
        database: database,
        repository: repository,
        job: job,
        plan: plan,
        workspaceHeadSHA: String(repeating: "a", count: 40),
        now: Date(timeIntervalSince1970: 200_000),
        currentTime: { Date(timeIntervalSince1970: 200_002) }
      )
    }
    return try await store.prepare(
      job: job,
      phase: .bootstrap,
      round: 1,
      commandOrdinal: ordinal,
      command: command,
      planSHA256: plan.digest,
      workspace: workspaceIdentity
    )
  }

  func insertLostTopologyGeneration() async throws {
    let repository = repositoryID.uuidString.lowercased()
    let jobID = job.id.uuidString.lowercased()
    _ = try await database.execute(
      """
      INSERT INTO herdr_repository_bindings(
        repository_id, workspace_id, identity_root, herdr_version, herdr_protocol,
        socket_device, socket_inode, socket_owner, socket_permissions,
        state, created_at, updated_at
      ) VALUES (?, 'w1', ?, '0.8.2', 20, 1, 2, 501, 384, 'active', 1, 1)
      """,
      bindings: [
        .text(repository),
        .text(workspaceIdentity.path),
      ]
    )
    _ = try await database.execute(
      """
      INSERT INTO herdr_job_bindings(
        job_id, repository_id, generation, workspace_id, tab_id, state, created_at, updated_at
      ) VALUES (?, ?, 1, 'w1', NULL, 'lost', 1, 1)
      """,
      bindings: [.text(jobID), .text(repository)]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func approvedCommandJob(_ result: JobTransitionResult) -> JobRecord {
  switch result {
  case .applied(let job), .duplicate(let job): job
  }
}

private enum ApprovedCommandStoreFixtureError: Error {
  case suppressed
}

private func makeApprovedCommandTemporaryDirectory(prefix: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(prefix)-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: root.path
  )
  return root
}
