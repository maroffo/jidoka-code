import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable Pi and Herdr ownership store")
struct PiRunStoreTests {
  @Test("schema v4 preserves legacy RPC runs and creates each migration backup")
  func migrationPreservesLegacyRun() async throws {
    let root = try makePrivateTemporaryDirectory(prefix: "pi-run-migration")
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("state.sqlite3")
    let repositoryID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let jobID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let legacy = try SQLiteStore(
      databaseURL: databaseURL,
      migrations: Array(DatabaseSchema.migrations.prefix(2))
    )
    try await insertRepositoryAndJob(
      database: legacy,
      repositoryID: repositoryID,
      jobID: jobID
    )
    _ = try await legacy.execute(
      """
      INSERT INTO pi_runs(
        id, job_id, role, resource_version, resource_hash, model, session_path,
        accepted, settled, structured_result_digest, outcome, created_at
      ) VALUES (?, ?, 'triage', '1', ?, 'fixture/model:off', '/private/session',
        1, 1, ?, 'succeeded', 10)
      """,
      bindings: [
        .text("legacy-run"),
        .text(jobID.uuidString.lowercased()),
        .text(String(repeating: "a", count: 64)),
        .text(String(repeating: "b", count: 64)),
      ]
    )
    await legacy.close()

    let migrated = try SQLiteStore(databaseURL: databaseURL)
    #expect(try await migrated.schemaVersion() == 4)
    #expect(migrated.migrationBackups.count == 2)
    let v3Backup = try SQLiteStore(
      databaseURL: try #require(migrated.migrationBackups.first),
      migrations: Array(DatabaseSchema.migrations.prefix(2))
    )
    #expect(try await v3Backup.schemaVersion() == 2)
    #expect(
      try await v3Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v3Backup.close()
    let v4Backup = try SQLiteStore(
      databaseURL: try #require(migrated.migrationBackups.last),
      migrations: Array(DatabaseSchema.migrations.prefix(3))
    )
    #expect(try await v4Backup.schemaVersion() == 3)
    #expect(
      try await v4Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v4Backup.close()
    let rows = try await migrated.query("SELECT * FROM pi_runs WHERE id = 'legacy-run'")
    #expect(rows.count == 1)
    #expect(rows[0]["runtime_kind"] == .text("rpcLegacy"))
    #expect(rows[0]["structured_result_digest"] == .text(String(repeating: "b", count: 64)))
    #expect(rows[0]["updated_at"] == .real(10))
    #expect(try await migrated.query("PRAGMA foreign_key_check").isEmpty)
  }

  @Test("topology activation commits every role or rolls the whole generation back")
  func topologyActivationIsAtomic() async throws {
    let root = try makePrivateTemporaryDirectory(prefix: "pi-topology-activation")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let repositoryID = UUID(uuidString: "11000000-0000-0000-0000-000000000011")!
    let jobID = UUID(uuidString: "22000000-0000-0000-0000-000000000022")!
    try await insertRepositoryAndJob(
      database: database,
      repositoryID: repositoryID,
      jobID: jobID
    )
    let store = PiRunStore(database: database)
    _ = try await store.bindRepository(
      repositoryID: repositoryID,
      workspaceID: "workspace-atomic",
      identityRoot: root,
      handshake: handshake(workspaceID: "workspace-atomic"),
      now: Date(timeIntervalSince1970: 1)
    )
    _ = try await store.prepareJobBinding(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: "workspace-atomic",
      now: Date(timeIntervalSince1970: 2)
    )
    for (id, role) in [("host-atomic-0001", PiWorkflowRole.triage), ("host-atomic-0002", .test)] {
      _ = try await store.prepareRoleHost(
        id: id,
        jobID: jobID,
        generation: 1,
        role: role,
        workspaceID: "workspace-atomic",
        bootstrapDescriptorSHA256: String(repeating: role == .triage ? "a" : "b", count: 64),
        hostExecutableSHA256: String(repeating: "c", count: 64),
        now: Date(timeIntervalSince1970: 3)
      )
    }
    _ = try await database.execute(
      """
      CREATE TRIGGER fail_second_host_activation
      BEFORE UPDATE ON herdr_role_hosts WHEN OLD.id = 'host-atomic-0002'
      BEGIN SELECT RAISE(ABORT, 'injected activation failure'); END
      """
    )
    let identity = try HerdrHostProcessIdentity(
      processID: 42,
      startSeconds: 10,
      startMicroseconds: 20
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await store.activateTopology(
        jobID: jobID,
        tabID: "tab-atomic",
        hosts: [
          HerdrRoleHostActivation(
            roleHostID: "host-atomic-0001",
            workspaceID: "workspace-atomic",
            tabID: "tab-atomic",
            paneID: "pane-atomic-1",
            terminalID: "terminal-atomic-1",
            processIdentity: identity
          ),
          HerdrRoleHostActivation(
            roleHostID: "host-atomic-0002",
            workspaceID: "workspace-atomic",
            tabID: "tab-atomic",
            paneID: "pane-atomic-2",
            terminalID: "terminal-atomic-2",
            processIdentity: identity
          ),
        ],
        now: Date(timeIntervalSince1970: 4)
      )
    }
    #expect(try await store.jobBinding(jobID: jobID)?.state == .prepared)
    #expect(try await store.roleHosts(jobID: jobID).allSatisfy { $0.state == .prepared })
  }

  @Test("result settlement commits before idempotent acknowledgement and release")
  func settlementAndSignalsAreDurable() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 1_000)
    let prepared = try await fixture.store.prepareRun(
      id: "run-00000001",
      jobID: fixture.jobID,
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "1", count: 64),
      requestSHA256: String(repeating: "2", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "3", count: 64),
      model: "fixture/model:off",
      sessionPath: fixture.root.appendingPathComponent("sessions"),
      channelPath: fixture.root.appendingPathComponent("channel"),
      now: now
    )
    #expect(prepared.outcome == .prepared)
    let launch = try await fixture.store.prepareLaunch(
      launchAttemptID: "launch-00000001",
      runID: prepared.id,
      roleHostID: fixture.roleHostID,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "4", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: now.addingTimeInterval(1)
    )
    #expect(launch.queueSequence == 1)
    _ = try await fixture.store.transitionLaunch(
      launchAttemptID: launch.launchAttemptID,
      to: .enqueued,
      event: .enqueued,
      now: now.addingTimeInterval(2)
    )
    _ = try await fixture.store.transitionLaunch(
      launchAttemptID: launch.launchAttemptID,
      to: .running,
      event: .running,
      now: now.addingTimeInterval(3)
    )
    let child = HerdrChildProcessRecord(
      launchAttemptID: launch.launchAttemptID,
      processID: 4242,
      processGroupID: 4242,
      startSeconds: 100,
      startMicroseconds: 200
    )
    let childLaunch = try await fixture.store.recordChildProcess(
      launchAttemptID: launch.launchAttemptID,
      record: child,
      now: now.addingTimeInterval(3.5)
    )
    #expect(childLaunch.childProcess == child)
    _ = try await fixture.store.recordChildProcess(
      launchAttemptID: launch.launchAttemptID,
      record: child,
      now: now.addingTimeInterval(3.6)
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET child_pid = 4243 WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET state = 'settled' WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET created_at = created_at + 1 WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET outcome = 'arbitrary' WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET created_at = created_at + 1 WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        UPDATE pi_runs
        SET accepted = 1, settled = 1, session_id = ?, session_boundary_sha256 = ?,
          structured_result_digest = ?, outcome = 'settled'
        WHERE id = ?
        """,
        bindings: [
          .text("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
          .text(String(repeating: "6", count: 64)),
          .text(String(repeating: "7", count: 64)),
          .text(prepared.id),
        ]
      )
    }

    let resultEnvelope = Data("{\"result\":\"accepted\"}\n".utf8)
    let resultDigest = GitHubMarkerCodec.sha256(resultEnvelope)
    let boundary = String(repeating: "6", count: 64)
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let settled = try await fixture.store.settle(
      runID: prepared.id,
      launchAttemptID: launch.launchAttemptID,
      resultEnvelope: resultEnvelope,
      resultSHA256: resultDigest,
      sessionID: sessionID,
      sessionBoundarySHA256: boundary,
      now: now.addingTimeInterval(4)
    )
    #expect(settled.accepted)
    #expect(settled.settled)
    #expect(settled.outcome == .settled)
    #expect(settled.structuredResultDigest == resultDigest)
    #expect(settled.sessionBoundarySHA256 == boundary)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET session_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff' WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET role = 'writer' WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET outcome = 'running' WHERE id = ?",
        bindings: [.text(prepared.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET state = 'enqueued' WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }

    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        INSERT INTO pi_run_events(
          run_id, launch_attempt_id, sequence, kind, record_sha256, detail_code, created_at
        ) SELECT ?, ?, COALESCE(MAX(sequence), 0) + 1, 'acknowledged', ?, NULL, ?
        FROM pi_run_events WHERE run_id = ?
        """,
        bindings: [
          .text(prepared.id),
          .text(launch.launchAttemptID),
          .text(String(repeating: "f", count: 64)),
          .real(now.addingTimeInterval(4.5).timeIntervalSince1970),
          .text(prepared.id),
        ]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET state = 'released' WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }
    await #expect(throws: PiRunStoreError.invalidTransition) {
      try await fixture.store.recordRelease(
        runID: prepared.id,
        launchAttemptID: launch.launchAttemptID,
        resultSHA256: resultDigest,
        now: now.addingTimeInterval(5)
      )
    }
    try await fixture.store.recordAcknowledgement(
      runID: prepared.id,
      launchAttemptID: launch.launchAttemptID,
      resultSHA256: resultDigest,
      now: now.addingTimeInterval(5)
    )
    try await fixture.store.recordAcknowledgement(
      runID: prepared.id,
      launchAttemptID: launch.launchAttemptID,
      resultSHA256: resultDigest,
      now: now.addingTimeInterval(6)
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET state = 'released' WHERE launch_attempt_id = ?",
        bindings: [.text(launch.launchAttemptID)]
      )
    }
    try await fixture.store.recordRelease(
      runID: prepared.id,
      launchAttemptID: launch.launchAttemptID,
      resultSHA256: resultDigest,
      now: now.addingTimeInterval(7)
    )
    try await fixture.store.recordRelease(
      runID: prepared.id,
      launchAttemptID: launch.launchAttemptID,
      resultSHA256: resultDigest,
      now: now.addingTimeInterval(8)
    )

    let final = try #require(try await fixture.store.run(id: prepared.id))
    #expect(final.outcome == .released)
    #expect(try await fixture.store.launches(runID: prepared.id).map(\.state) == [.released])
    #expect(
      try await fixture.store.events(runID: prepared.id).map(\.kind)
        == [
          .prepared, .enqueued, .running, .childProcessRecorded, .resultPrepared, .settled,
          .acknowledged, .released,
        ]
    )
    let divergentEnvelope = Data("{\"result\":\"divergent\"}\n".utf8)
    await #expect(throws: PiRunStoreError.divergentResult) {
      _ = try await fixture.store.settle(
        runID: prepared.id,
        launchAttemptID: launch.launchAttemptID,
        resultEnvelope: divergentEnvelope,
        resultSHA256: GitHubMarkerCodec.sha256(divergentEnvelope),
        sessionID: sessionID,
        sessionBoundarySHA256: boundary,
        now: now.addingTimeInterval(9)
      )
    }
  }

  @Test("bindings are exact and append-only events reject mutation")
  func bindingAndEventIntegrity() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let same = try await fixture.store.repositoryBinding(repositoryID: fixture.repositoryID)
    #expect(same?.workspaceID == "workspace-1")
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.prepareJobBinding(
        jobID: fixture.jobID,
        repositoryID: fixture.repositoryID,
        generation: 1,
        workspaceID: "workspace-foreign",
        now: Date(timeIntervalSince1970: 99)
      )
    }
    let different = handshake(workspaceID: "workspace-2")
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.bindRepository(
        repositoryID: fixture.repositoryID,
        workspaceID: "workspace-2",
        identityRoot: fixture.root,
        handshake: different,
        now: Date(timeIntervalSince1970: 100)
      )
    }

    let run = try await fixture.store.prepareRun(
      id: "run-00000002",
      jobID: fixture.jobID,
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "8", count: 64),
      requestSHA256: String(repeating: "9", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "a", count: 64),
      model: "fixture/model:off",
      sessionPath: fixture.root.appendingPathComponent("session-two"),
      channelPath: fixture.root.appendingPathComponent("channel-two"),
      now: Date(timeIntervalSince1970: 101)
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_events SET kind = 'failed' WHERE run_id = ?",
        bindings: [.text(run.id)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "DELETE FROM pi_run_events WHERE run_id = ?",
        bindings: [.text(run.id)]
      )
    }
    _ = try await fixture.database.execute(
      """
      INSERT INTO pi_runs(
        id, job_id, runtime_kind, role, resource_version, resource_hash, model,
        session_path, accepted, settled, outcome, created_at, updated_at
      ) VALUES (?, ?, 'rpcLegacy', 'triage', '1', ?, 'fixture/model:off',
        '/private/legacy', 0, 0, 'prepared', 1, 1)
      """,
      bindings: [
        .text("legacy-runtime-kind"),
        .text(fixture.jobID.uuidString.lowercased()),
        .text(String(repeating: "a", count: 64)),
      ]
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_runs SET runtime_kind = 'herdr' WHERE id = 'legacy-runtime-kind'"
      )
    }
  }

  @Test("cross-run boundary and same-run retry preserve causal session provenance")
  func causalResumeIsExact() async throws {
    let fixture = try await StoreFixture.make(role: .writer)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 2_000)
    let first = try await fixture.store.prepareRun(
      id: "run-causal-0001",
      jobID: fixture.jobID,
      workflow: .planning,
      role: .writer,
      round: 1,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "1", count: 64),
      requestSHA256: String(repeating: "2", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "3", count: 64),
      model: "fixture/model:off",
      sessionPath: fixture.root.appendingPathComponent("causal-sessions"),
      channelPath: fixture.root.appendingPathComponent("causal-channel-one"),
      now: now
    )
    let firstLaunch = try await fixture.store.prepareLaunch(
      launchAttemptID: "launch-causal-0001",
      runID: first.id,
      roleHostID: fixture.roleHostID,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "4", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: now.addingTimeInterval(1)
    )
    _ = try await fixture.store.transitionLaunch(
      launchAttemptID: firstLaunch.launchAttemptID,
      to: .enqueued,
      event: .enqueued,
      now: now.addingTimeInterval(2)
    )
    let envelope = Data("{\"causal\":true}\n".utf8)
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let boundary = String(repeating: "5", count: 64)
    _ = try await fixture.store.settle(
      runID: first.id,
      launchAttemptID: firstLaunch.launchAttemptID,
      resultEnvelope: envelope,
      resultSHA256: GitHubMarkerCodec.sha256(envelope),
      sessionID: sessionID,
      sessionBoundarySHA256: boundary,
      now: now.addingTimeInterval(3)
    )
    #expect(
      try await fixture.store.settledRunForResume(
        jobID: fixture.jobID,
        workflow: .planning,
        role: .writer,
        priorRound: 1,
        jobStep: 0,
        sessionID: sessionID,
        sessionBoundarySHA256: boundary
      )?.id == first.id
    )
    #expect(
      try await fixture.store.settledRunForReplay(
        jobID: fixture.jobID,
        workflow: .planning,
        role: .writer,
        round: 1,
        jobStep: 0,
        requestSHA256: first.requestSHA256
      )?.id == first.id
    )
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.prepareRun(
        id: "run-causal-wrong-workflow",
        jobID: fixture.jobID,
        workflow: .orchestration,
        role: .writer,
        round: 2,
        jobAttempt: 1,
        topologyGeneration: 1,
        jobStep: 0,
        resumesRunID: first.id,
        runNonce: String(repeating: "6", count: 64),
        requestSHA256: String(repeating: "7", count: 64),
        resourceVersion: "1",
        resourceHash: String(repeating: "8", count: 64),
        model: "fixture/model:off",
        sessionPath: fixture.root.appendingPathComponent("causal-sessions"),
        channelPath: fixture.root.appendingPathComponent("causal-wrong-workflow"),
        now: now.addingTimeInterval(4)
      )
    }
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.prepareRun(
        id: "run-causal-nonwriter",
        jobID: fixture.jobID,
        workflow: .planning,
        role: .architecture,
        round: 2,
        jobAttempt: 1,
        topologyGeneration: 1,
        jobStep: 0,
        resumesRunID: first.id,
        runNonce: String(repeating: "6", count: 64),
        requestSHA256: String(repeating: "7", count: 64),
        resourceVersion: "1",
        resourceHash: String(repeating: "8", count: 64),
        model: "fixture/model:off",
        sessionPath: fixture.root.appendingPathComponent("causal-sessions"),
        channelPath: fixture.root.appendingPathComponent("causal-nonwriter"),
        now: now.addingTimeInterval(4)
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        INSERT INTO pi_runs(
          id, job_id, runtime_kind, workflow, role, round, job_attempt,
          topology_generation, job_step, resumes_run_id, run_nonce, request_sha256,
          resource_version, resource_hash, model, session_path, channel_path,
          accepted, settled, outcome, created_at, updated_at
        ) SELECT
          'run-causal-raw-invalid', job_id, runtime_kind, 'orchestration', role, 2, job_attempt,
          topology_generation, job_step, id, ?, ?, resource_version, resource_hash, model,
          session_path, ?, 0, 0, 'prepared', 4, 4
        FROM pi_runs WHERE id = ?
        """,
        bindings: [
          .text(String(repeating: "8", count: 64)),
          .text(String(repeating: "9", count: 64)),
          .text(fixture.root.appendingPathComponent("causal-raw-invalid").path),
          .text(first.id),
        ]
      )
    }

    let second = try await fixture.store.prepareRun(
      id: "run-causal-0002",
      jobID: fixture.jobID,
      workflow: .planning,
      role: .writer,
      round: 2,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      resumesRunID: first.id,
      runNonce: String(repeating: "6", count: 64),
      requestSHA256: String(repeating: "7", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "8", count: 64),
      model: "fixture/model:off",
      sessionPath: fixture.root.appendingPathComponent("causal-sessions"),
      channelPath: fixture.root.appendingPathComponent("causal-channel-two"),
      now: now.addingTimeInterval(4)
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, created_at, updated_at
        ) VALUES (?, ?, ?, 2, 'fresh', ?, NULL, NULL, 'prepared', 5, 5)
        """,
        bindings: [
          .text("launch-causal-raw-fresh"),
          .text(second.id),
          .text(fixture.roleHostID),
          .text(String(repeating: "9", count: 64)),
        ]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, created_at, updated_at
        ) VALUES (?, ?, ?, 2, 'crossRunResume', ?, ?, ?, 'prepared', 5, 5)
        """,
        bindings: [
          .text("launch-causal-raw-boundary"),
          .text(second.id),
          .text(fixture.roleHostID),
          .text(String(repeating: "9", count: 64)),
          .text(sessionID),
          .text(String(repeating: "0", count: 64)),
        ]
      )
    }
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.prepareLaunch(
        launchAttemptID: "launch-causal-wrong-boundary",
        runID: second.id,
        roleHostID: fixture.roleHostID,
        launchMode: .crossRunResume,
        descriptorSHA256: String(repeating: "9", count: 64),
        expectedSessionID: sessionID,
        resumeBoundarySHA256: String(repeating: "0", count: 64),
        now: now.addingTimeInterval(5)
      )
    }
    let crossRun = try await fixture.store.prepareLaunch(
      launchAttemptID: "launch-causal-z002",
      runID: second.id,
      roleHostID: fixture.roleHostID,
      launchMode: .crossRunResume,
      descriptorSHA256: String(repeating: "9", count: 64),
      expectedSessionID: sessionID,
      resumeBoundarySHA256: boundary,
      now: now.addingTimeInterval(5)
    )
    _ = try await fixture.store.transitionLaunch(
      launchAttemptID: crossRun.launchAttemptID,
      to: .enqueued,
      event: .enqueued,
      now: now.addingTimeInterval(6)
    )
    _ = try await fixture.store.transitionLaunch(
      launchAttemptID: crossRun.launchAttemptID,
      to: .interruptedUnknown,
      event: .interruptedUnknown,
      detailCode: "PROCESS_INTERRUPTED",
      now: now.addingTimeInterval(7)
    )
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.recordSessionOrigin(
        runID: second.id,
        launchAttemptID: crossRun.launchAttemptID,
        sessionID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        originResumeBoundarySHA256: boundary,
        now: now.addingTimeInterval(7.5)
      )
    }
    _ = try await fixture.store.recordSessionOrigin(
      runID: second.id,
      launchAttemptID: crossRun.launchAttemptID,
      sessionID: sessionID,
      originResumeBoundarySHA256: boundary,
      now: now.addingTimeInterval(7.5)
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_session_origins SET session_id = ? WHERE run_id = ?",
        bindings: [
          .text("ffffffff-ffff-4fff-8fff-ffffffffffff"),
          .text(second.id),
        ]
      )
    }
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.prepareLaunch(
        launchAttemptID: "launch-causal-bad",
        runID: second.id,
        roleHostID: fixture.roleHostID,
        launchMode: .sameRunResume,
        descriptorSHA256: String(repeating: "a", count: 64),
        expectedSessionID: sessionID,
        resumeBoundarySHA256: nil,
        now: now.addingTimeInterval(8)
      )
    }
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.prepareLaunch(
        launchAttemptID: "launch-causal-wrong-session",
        runID: second.id,
        roleHostID: fixture.roleHostID,
        launchMode: .sameRunResume,
        descriptorSHA256: String(repeating: "a", count: 64),
        expectedSessionID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        resumeBoundarySHA256: boundary,
        now: now.addingTimeInterval(8)
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, created_at, updated_at
        ) VALUES (?, ?, ?, 3, 'sameRunResume', ?, ?, ?, 'prepared', 8, 8)
        """,
        bindings: [
          .text("launch-causal-raw-session"),
          .text(second.id),
          .text(fixture.roleHostID),
          .text(String(repeating: "a", count: 64)),
          .text("ffffffff-ffff-4fff-8fff-ffffffffffff"),
          .text(boundary),
        ]
      )
    }
    let retry = try await fixture.store.prepareLaunch(
      launchAttemptID: "launch-causal-a003",
      runID: second.id,
      roleHostID: fixture.roleHostID,
      launchMode: .sameRunResume,
      descriptorSHA256: String(repeating: "b", count: 64),
      expectedSessionID: sessionID,
      resumeBoundarySHA256: boundary,
      now: now.addingTimeInterval(9)
    )
    #expect(retry.queueSequence == 3)
    #expect(retry.resumeBoundarySHA256 == boundary)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE pi_run_launches SET created_at = ? WHERE run_id = ?",
        bindings: [.real(now.timeIntervalSince1970), .text(second.id)]
      )
    }
    #expect(
      try await fixture.store.launches(runID: second.id).map(\.launchAttemptID)
        == ["launch-causal-z002", "launch-causal-a003"]
    )
  }

  @Test("logical slots collide explicitly and durable pause blocks prepare")
  func slotAndPauseGates() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date(timeIntervalSince1970: 3_000)
    _ = try await fixture.store.prepareRun(
      id: "run-slot-000001",
      jobID: fixture.jobID,
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "c", count: 64),
      requestSHA256: String(repeating: "d", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "e", count: 64),
      model: "fixture/model:off",
      sessionPath: fixture.root.appendingPathComponent("slot-session"),
      channelPath: fixture.root.appendingPathComponent("slot-channel"),
      now: now
    )
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.prepareRun(
        id: "run-slot-000002",
        jobID: fixture.jobID,
        workflow: .issueTriage,
        role: .triage,
        round: 1,
        jobAttempt: 1,
        topologyGeneration: 1,
        jobStep: 0,
        runNonce: String(repeating: "f", count: 64),
        requestSHA256: String(repeating: "0", count: 64),
        resourceVersion: "1",
        resourceHash: String(repeating: "1", count: 64),
        model: "fixture/model:off",
        sessionPath: fixture.root.appendingPathComponent("slot-session-two"),
        channelPath: fixture.root.appendingPathComponent("slot-channel-two"),
        now: now.addingTimeInterval(1)
      )
    }
    let intentStore = SQLiteHerdrTopologyIntentStore(database: fixture.database)
    let preparedIntent = try await intentStore.prepare(
      HerdrTopologyMutationIntent(
        mutationID: "mutation-paused-prepare",
        kind: .applyLayout,
        repositoryID: fixture.repositoryID.uuidString.lowercased(),
        jobID: fixture.jobID.uuidString.lowercased(),
        generation: 1,
        payloadSHA256: String(repeating: "5", count: 64),
        socketIdentity: HerdrSocketIdentityRecord(
          handshake(workspaceID: "workspace-1").socketIdentity
        )
      )
    )
    _ = try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    await #expect(throws: PiRunStoreError.launchSuppressed) {
      try await intentStore.markSendStarted(preparedIntent)
    }
    await #expect(throws: PiRunStoreError.launchSuppressed) {
      _ = try await fixture.store.prepareRun(
        id: "run-paused-0001",
        jobID: fixture.jobID,
        workflow: .issueTriage,
        role: .triage,
        round: 2,
        jobAttempt: 1,
        topologyGeneration: 1,
        jobStep: 0,
        runNonce: String(repeating: "2", count: 64),
        requestSHA256: String(repeating: "3", count: 64),
        resourceVersion: "1",
        resourceHash: String(repeating: "4", count: 64),
        model: "fixture/model:off",
        sessionPath: fixture.root.appendingPathComponent("paused-session"),
        channelPath: fixture.root.appendingPathComponent("paused-channel"),
        now: now.addingTimeInterval(2)
      )
    }
  }

  @Test("cold Herdr socket replacement preserves history and advances topology generation")
  func coldSocketReplacement() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let replacement = handshake(workspaceID: "workspace-2", inode: 21)
    try await fixture.store.invalidateRepositoryBinding(
      repositoryID: fixture.repositoryID,
      observedHandshake: replacement,
      now: Date(timeIntervalSince1970: 4_000)
    )
    #expect(
      try await fixture.store.repositoryBinding(repositoryID: fixture.repositoryID)?.state == .lost
    )
    #expect(try await fixture.store.jobBinding(jobID: fixture.jobID)?.state == .lost)
    #expect(try await fixture.store.roleHosts(jobID: fixture.jobID).first?.state == .lost)
    let history = try await fixture.database.query(
      "SELECT * FROM herdr_repository_binding_history WHERE repository_id = ?",
      bindings: [.text(fixture.repositoryID.uuidString.lowercased())]
    )
    #expect(history.count == 1)
    #expect(history[0]["workspace_id"] == .text("workspace-1"))
    #expect(history[0]["reason"] == .text("SOCKET_CHANGED"))

    _ = try await fixture.store.bindRepository(
      repositoryID: fixture.repositoryID,
      workspaceID: "workspace-2",
      identityRoot: fixture.root,
      handshake: replacement,
      now: Date(timeIntervalSince1970: 4_001)
    )
    let next = try await fixture.store.prepareJobBinding(
      jobID: fixture.jobID,
      repositoryID: fixture.repositoryID,
      generation: 2,
      workspaceID: "workspace-2",
      now: Date(timeIntervalSince1970: 4_002)
    )
    #expect(next.generation == 2)
    #expect(next.state == .prepared)
    #expect(next.tabID == nil)
  }

  @Test("topology intent transitions are digest-bound and idempotent")
  func topologyIntentLifecycle() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let intentStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 200) }
    )
    let intent = HerdrTopologyMutationIntent(
      mutationID: "mutation-00000001",
      kind: .applyLayout,
      repositoryID: fixture.repositoryID.uuidString.lowercased(),
      jobID: fixture.jobID.uuidString.lowercased(),
      generation: 1,
      payloadSHA256: String(repeating: "b", count: 64),
      socketIdentity: HerdrSocketIdentityRecord(
        handshake(workspaceID: "workspace-1").socketIdentity)
    )
    let receipt = try await intentStore.prepare(intent)
    #expect(receipt.intentSHA256.count == 64)
    try await intentStore.markSendStarted(receipt)
    try await intentStore.markSendStarted(receipt)
    let attribution = HerdrTopologyMutationAttribution(
      workspaceID: "workspace-1",
      tabID: "tab-1",
      paneIDs: ["pane-1"]
    )
    try await intentStore.attribute(receipt, as: attribution)
    try await intentStore.attribute(receipt, as: attribution)
    let rows = try await fixture.database.query(
      "SELECT state, intent_sha256, attribution_json FROM herdr_topology_intents WHERE id = ?",
      bindings: [.text(intent.mutationID)]
    )
    #expect(rows.first?["state"] == .text("attributed"))
    #expect(rows.first?["intent_sha256"] == .text(receipt.intentSHA256))
    #expect(rows.first?["attribution_json"] != .null)
    let stored = try await intentStore.storedIntent(
      kind: intent.kind,
      repositoryID: intent.repositoryID,
      jobID: intent.jobID,
      generation: intent.generation,
      payloadSHA256: intent.payloadSHA256,
      socketIdentity: intent.socketIdentity
    )
    #expect(stored?.receipt == receipt)
    #expect(stored?.state == .attributed)
    #expect(stored?.attribution == attribution)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE herdr_topology_intents SET payload_sha256 = ? WHERE id = ?",
        bindings: [
          .text(String(repeating: "c", count: 64)),
          .text(intent.mutationID),
        ]
      )
    }
  }
}

private struct StoreFixture {
  let root: URL
  let database: SQLiteStore
  let store: PiRunStore
  let repositoryID: UUID
  let jobID: UUID
  let roleHostID: String

  static func make(role: PiWorkflowRole = .triage) async throws -> Self {
    let root = try makePrivateTemporaryDirectory(prefix: "pi-run-store")
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let repositoryID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let jobID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    try await insertRepositoryAndJob(
      database: database,
      repositoryID: repositoryID,
      jobID: jobID,
      role: role
    )
    let store = PiRunStore(database: database)
    let handshake = handshake(workspaceID: "workspace-1")
    _ = try await store.bindRepository(
      repositoryID: repositoryID,
      workspaceID: "workspace-1",
      identityRoot: root,
      handshake: handshake,
      now: Date(timeIntervalSince1970: 1)
    )
    _ = try await store.prepareJobBinding(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: "workspace-1",
      now: Date(timeIntervalSince1970: 2)
    )
    let roleHostID = "host-00000001"
    _ = try await store.prepareRoleHost(
      id: roleHostID,
      jobID: jobID,
      generation: 1,
      role: role,
      workspaceID: "workspace-1",
      bootstrapDescriptorSHA256: String(repeating: "c", count: 64),
      hostExecutableSHA256: String(repeating: "d", count: 64),
      now: Date(timeIntervalSince1970: 4)
    )
    try await store.activateTopology(
      jobID: jobID,
      tabID: "tab-1",
      hosts: [
        HerdrRoleHostActivation(
          roleHostID: roleHostID,
          workspaceID: "workspace-1",
          tabID: "tab-1",
          paneID: "pane-1",
          terminalID: "terminal-1",
          processIdentity: try HerdrHostProcessIdentity(
            processID: 42,
            startSeconds: 10,
            startMicroseconds: 20
          )
        )
      ],
      now: Date(timeIntervalSince1970: 5)
    )
    return Self(
      root: root,
      database: database,
      store: store,
      repositoryID: repositoryID,
      jobID: jobID,
      roleHostID: roleHostID
    )
  }
}

private func insertRepositoryAndJob(
  database: SQLiteStore,
  repositoryID: UUID,
  jobID: UUID,
  role: PiWorkflowRole = .triage
) async throws {
  _ = try await database.execute(
    """
    INSERT INTO repositories(
      id, node_id, owner, name, default_branch,
      review_enabled, triage_enabled, implementation_enabled, enabled,
      created_at, updated_at
    ) VALUES (?, ?, 'owner', 'repository', 'main', 1, 1, 1, 1, 1, 1)
    """,
    bindings: [
      .text(repositoryID.uuidString.lowercased()),
      .text("node-\(repositoryID.uuidString.lowercased())"),
    ]
  )
  _ = try await database.execute(
    """
    INSERT INTO jobs(
      id, repository_id, kind, object_node_id, object_number, revision_key,
      contract_version_used, priority, state, current_step, current_step_kind,
      attempt, created_at, updated_at
    ) VALUES (?, ?, ?, 'issue-node', 1, 'initial-revision',
      'test', 4, 'runningPi', 0, ?, 1, 1, 1)
    """,
    bindings: [
      .text(jobID.uuidString.lowercased()),
      .text(repositoryID.uuidString.lowercased()),
      .text(role == .writer ? JobKind.issueImplementation.rawValue : JobKind.issueTriage.rawValue),
      .text(role == .writer ? JobStepKind.orchestrate.rawValue : JobStepKind.triage.rawValue),
    ]
  )
}

private func handshake(workspaceID: String, inode: UInt64 = 20) -> HerdrHandshake {
  HerdrHandshake(
    pong: HerdrPong(
      version: "0.8.0",
      protocolVersion: 19,
      capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
    ),
    snapshot: HerdrSessionSnapshot(
      version: "0.8.0",
      protocolVersion: 19,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: [],
      tabs: [],
      panes: [],
      agents: []
    ),
    socketIdentity: HerdrSocketIdentity(
      device: 10,
      inode: inode,
      owner: 501,
      permissions: 0o600
    )
  )
}

private func makePrivateTemporaryDirectory(prefix: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(prefix)-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  return root.standardizedFileURL
}
