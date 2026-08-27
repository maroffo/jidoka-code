import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable Pi and Herdr ownership store")
struct PiRunStoreTests {
  @Test("schema v9 preserves legacy RPC runs and creates each migration backup")
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
    #expect(try await migrated.schemaVersion() == 9)
    #expect(migrated.migrationBackups.count == 7)
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
      databaseURL: migrated.migrationBackups[2],
      migrations: Array(DatabaseSchema.migrations.prefix(4))
    )
    #expect(try await v4Backup.schemaVersion() == 4)
    #expect(
      try await v4Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v4Backup.close()
    let v6Backup = try SQLiteStore(
      databaseURL: migrated.migrationBackups[4],
      migrations: Array(DatabaseSchema.migrations.prefix(6))
    )
    #expect(try await v6Backup.schemaVersion() == 6)
    #expect(
      try await v6Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v6Backup.close()
    let v7Backup = try SQLiteStore(
      databaseURL: migrated.migrationBackups[5],
      migrations: Array(DatabaseSchema.migrations.prefix(7))
    )
    #expect(try await v7Backup.schemaVersion() == 7)
    #expect(
      try await v7Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v7Backup.close()
    let v8Backup = try SQLiteStore(
      databaseURL: try #require(migrated.migrationBackups.last),
      migrations: Array(DatabaseSchema.migrations.prefix(8))
    )
    #expect(try await v8Backup.schemaVersion() == 8)
    #expect(
      try await v8Backup.scalarInt("SELECT COUNT(*) FROM pi_runs WHERE id = 'legacy-run'") == 1
    )
    await v8Backup.close()
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

  @Test(
    "one attributed agent authority commits q4 once and q5 remains impossible",
    arguments: [0, 1, 2]
  )
  func primedFourthLaunchIsAtomicAndBounded(scenario: Int) async throws {
    let reset = scenario != 0
    let crashAfterSendStarted = scenario == 2
    let root = try makePrivateTemporaryDirectory(prefix: "pi-prime-fourth")
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("state.sqlite3")
    let database = try SQLiteStore(databaseURL: databaseURL)
    let repositoryID = UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
    let jobID = UUID(uuidString: "41000000-0000-0000-0000-000000000004")!
    try await insertRepositoryAndJob(
      database: database,
      repositoryID: repositoryID,
      jobID: jobID,
      role: .architecture
    )
    let job = jobID.uuidString.lowercased()
    let repository = repositoryID.uuidString.lowercased()
    let replacementHostID = "rolehost-11111111-1111-4111-8111-111111111111"
    let replacementLaunchID = "launch-22222222-2222-4222-8222-222222222222"
    let replacementEvidenceSHA256 = String(repeating: "b", count: 64)
    let recoveryEvidenceSHA256 = String(repeating: "8", count: 64)
    let retryEvidenceSHA256 = String(repeating: "9", count: 64)
    let canary = JobCanaryAuthorization(
      scope: JobCanaryScope(
        jobID: jobID,
        boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
        repairEvidenceSHA256: String(repeating: "4", count: 64),
        maximumCommentParts: 8
      ),
      previewEvidenceSHA256: String(repeating: "5", count: 64)
    )
    let replacementAuthorization = JobCanaryRoleHostReplacementAuthorization(
      request: JobCanaryRoleHostReplacementRequest(
        retry: JobCanaryPiRetryAuthorization(
          recovery: JobCanaryRecoveryAuthorization(
            canary: canary,
            recoveryEvidenceSHA256: recoveryEvidenceSHA256
          ),
          retryEvidenceSHA256: retryEvidenceSHA256
        ),
        incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
        plannedReplacementRoleHostID: replacementHostID,
        plannedLaunchAttemptID: replacementLaunchID
      ),
      replacementEvidenceSHA256: replacementEvidenceSHA256,
      q4Binding: replacementQ4Binding()
    )
    try replacementAuthorization.validate()
    _ = try await database.execute(
      "UPDATE jobs SET kind = 'prReview', current_step_kind = 'review', attempt = 3 WHERE id = ?",
      bindings: [.text(job)]
    )
    _ = try await database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
    _ = try await database.execute(
      "INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active) VALUES (?, ?, 1, 10, 1)",
      bindings: [.text(repository), .text(job)]
    )
    let canaryAuthorization = canary.authorizationSHA256
    let prefix = "canary:\(canaryAuthorization):m8:"
    for (event, from, to) in [
      (prefix + "admit:" + job, "queued", "leased"),
      (prefix + "pi:architecture:r1", "runningPi", "runningPi"),
      (
        prefix + "topology-recovery:" + recoveryEvidenceSHA256,
        "preparing", "preparing"
      ),
    ] {
      _ = try await database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, ?, ?, 'exact fixture authority', 3, 3, 0, 0, 10)
        """,
        bindings: [.text(job), .text(event), .text(from), .text(to)]
      )
    }
    let store = PiRunStore(database: database)
    let socket = handshake(workspaceID: "workspace-prime")
    _ = try await store.bindRepository(
      repositoryID: repositoryID,
      workspaceID: "workspace-prime",
      identityRoot: root,
      handshake: socket,
      now: Date(timeIntervalSince1970: 1)
    )
    _ = try await store.prepareJobBinding(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: "workspace-prime",
      now: Date(timeIntervalSince1970: 2)
    )
    let roles: [PiWorkflowRole] = [.architecture, .security, .test, .synthesis]
    var activations: [HerdrRoleHostActivation] = []
    for (index, role) in roles.enumerated() {
      let hostID = "host-prime-\(role.rawValue)"
      _ = try await store.prepareRoleHost(
        id: hostID,
        jobID: jobID,
        generation: 1,
        role: role,
        workspaceID: "workspace-prime",
        bootstrapDescriptorSHA256: String(repeating: Character(String(index + 1)), count: 64),
        hostExecutableSHA256: String(repeating: "d", count: 64),
        now: Date(timeIntervalSince1970: 3)
      )
      activations.append(
        HerdrRoleHostActivation(
          roleHostID: hostID,
          workspaceID: "workspace-prime",
          tabID: "tab-prime",
          paneID: "pane-prime-\(index + 1)",
          terminalID: "terminal-prime-\(index + 1)",
          processIdentity: try HerdrHostProcessIdentity(
            processID: Int32(100 + index),
            startSeconds: UInt64(200 + index),
            startMicroseconds: UInt64(300 + index)
          )
        )
      )
    }
    try await store.activateTopology(
      jobID: jobID,
      tabID: "tab-prime",
      hosts: activations,
      now: Date(timeIntervalSince1970: 4)
    )
    let run = try await store.prepareRun(
      id: "run-prime-fourth",
      jobID: jobID,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      jobAttempt: 3,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "1", count: 64),
      requestSHA256: String(repeating: "2", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "3", count: 64),
      model: "fixture/model:max",
      sessionPath: root.appendingPathComponent("session"),
      channelPath: root.appendingPathComponent("channel"),
      now: Date(timeIntervalSince1970: 5)
    )
    let architectureHost = "host-prime-architecture"
    func authorize(_ launch: PiRunLaunchRecord, suffix: Character, at instant: Double) async throws
    {
      _ = try await database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, 'runningPi', 'runningPi', 'exact retry authority', 3, 3, 0, 0, ?)
        """,
        bindings: [
          .text(job),
          .text(
            prefix + "pi-fresh-retry:" + run.id + ":" + launch.launchAttemptID + ":"
              + String(repeating: suffix, count: 64)
          ),
          .real(instant),
        ]
      )
    }
    let first = try await store.prepareLaunch(
      launchAttemptID: "launch-prime-first",
      runID: run.id,
      roleHostID: architectureHost,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "4", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: Date(timeIntervalSince1970: 6)
    )
    _ = try await store.transitionLaunch(
      launchAttemptID: first.launchAttemptID,
      to: .enqueued,
      event: .enqueued,
      now: Date(timeIntervalSince1970: 7)
    )
    _ = try await store.transitionLaunch(
      launchAttemptID: first.launchAttemptID,
      to: .running,
      event: .running,
      now: Date(timeIntervalSince1970: 8)
    )
    _ = try await store.recordChildProcess(
      launchAttemptID: first.launchAttemptID,
      record: HerdrChildProcessRecord(
        launchAttemptID: first.launchAttemptID,
        processID: 999_991,
        processGroupID: 999_991,
        startSeconds: 9,
        startMicroseconds: 1
      ),
      now: Date(timeIntervalSince1970: 9)
    )
    _ = try await store.transitionLaunch(
      launchAttemptID: first.launchAttemptID,
      to: .failed,
      event: .failed,
      detailCode: "RUNTIME_TIMEOUT",
      now: Date(timeIntervalSince1970: 10)
    )
    try await authorize(first, suffix: "5", at: 11)
    let second = try await store.prepareLaunch(
      launchAttemptID: "launch-prime-second",
      runID: run.id,
      roleHostID: architectureHost,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "5", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: Date(timeIntervalSince1970: 12)
    )
    for (state, event, instant): (PiRunLaunchState, PiRunEventKind, Double) in [
      (.enqueued, .enqueued, 13), (.running, .running, 14), (.failed, .failed, 15),
    ] {
      _ = try await store.transitionLaunch(
        launchAttemptID: second.launchAttemptID,
        to: state,
        event: event,
        detailCode: state == .failed ? "HERDR_TRANSACTION_FAILED" : nil,
        now: Date(timeIntervalSince1970: instant)
      )
    }
    try await authorize(second, suffix: "6", at: 16)
    let third = try await store.prepareLaunch(
      launchAttemptID: "launch-prime-third",
      runID: run.id,
      roleHostID: architectureHost,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "6", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: Date(timeIntervalSince1970: 17)
    )
    for (state, event, instant): (PiRunLaunchState, PiRunEventKind, Double) in [
      (.enqueued, .enqueued, 18), (.running, .running, 19), (.failed, .failed, 20),
    ] {
      _ = try await store.transitionLaunch(
        launchAttemptID: third.launchAttemptID,
        to: state,
        event: event,
        detailCode: state == .failed ? "HERDR_TRANSACTION_FAILED" : nil,
        now: Date(timeIntervalSince1970: instant)
      )
    }
    try await authorize(third, suffix: "7", at: 21)
    let host = try #require(
      try await store.roleHosts(jobID: jobID).first(where: { $0.id == architectureHost })
    )
    let identity = try #require(host.processIdentity)
    let intentStore = SQLiteHerdrTopologyIntentStore(
      database: database,
      now: { Date(timeIntervalSince1970: 21.25) }
    )
    let failedPrimeIntentID = "prime-00000000-0000-4000-8000-000000000003"
    let failedPrimePayloadSHA256 = String(repeating: "e", count: 64)
    var failedPrimeReceipt: HerdrTopologyMutationReceipt?
    if reset {
      let failedIntent = HerdrTopologyMutationIntent(
        mutationID: failedPrimeIntentID,
        kind: .primeAgentAuthority,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: failedPrimePayloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
      )
      let receipt = try await intentStore.prepare(failedIntent)
      try await intentStore.markSendStarted(receipt)
      try await intentStore.markUnknown(receipt)
      failedPrimeReceipt = receipt
      for (id, kind) in [
        (
          "prime-00000000-0000-4000-8000-000000000099",
          HerdrTopologyMutationIntent.Kind.primeAgentAuthority
        ),
        (
          "reset-00000000-0000-4000-8000-000000000099",
          HerdrTopologyMutationIntent.Kind.resetAgentAuthority
        ),
      ] {
        await #expect(throws: SQLiteStoreError.self) {
          _ = try await intentStore.prepare(
            HerdrTopologyMutationIntent(
              mutationID: id,
              kind: kind,
              repositoryID: repository,
              jobID: job,
              generation: 1,
              payloadSHA256: String(repeating: "f", count: 64),
              socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
            )
          )
        }
      }
      try await authorize(third, suffix: "9", at: 21.5)
    }
    let planned = reset ? "launch-reset-fourth" : "launch-prime-fourth"
    let tokens = [
      "managed_by": "jidoka", "repository_id": repository, "job_id": job,
      "generation": "1", "role": "architecture", "run_id": run.id,
      "launch_attempt_id": planned, "summary": reset ? "running" : "primed",
    ]
    let payload = HerdrAgentAuthorityPrimePayload(
      schemaVersion: reset ? 2 : 1,
      canaryAuthorizationSHA256: canaryAuthorization,
      maximumCommentParts: 8,
      recoveryEvidenceSHA256: String(repeating: "8", count: 64),
      retryEvidenceSHA256: String(repeating: "9", count: 64),
      repositoryID: repository,
      jobID: job,
      generation: 1,
      runID: run.id,
      failedLaunchAttemptID: third.launchAttemptID,
      plannedLaunchAttemptID: planned,
      roleHostID: host.id,
      queueSequence: 4,
      hostProcessID: identity.processID,
      hostStartSeconds: identity.startSeconds,
      hostStartMicroseconds: identity.startMicroseconds,
      hostExecutableSHA256: host.hostExecutableSHA256,
      workspaceID: host.workspaceID,
      tabID: try #require(host.tabID),
      paneID: try #require(host.paneID),
      terminalID: try #require(host.terminalID),
      agentSource: reset ? "jidoka:host" : "jidoka:prime:fixture",
      metadataSource: reset ? "jidoka:coordination" : "jidoka:prime-metadata:fixture",
      alias: "jc-prime-architecture-q4",
      reportSequence: reset ? 7 : 1,
      tokens: tokens,
      failedPrimeIntentID: reset ? failedPrimeIntentID : nil,
      failedPrimeIntentSHA256: reset ? failedPrimeReceipt?.intentSHA256 : nil,
      failedPrimePayloadSHA256: reset ? failedPrimePayloadSHA256 : nil,
      stalePaneRevision: reset ? 3 : nil,
      stalePaneHadTokens: reset ? true : nil,
      stalePaneTokensSHA256: reset ? String(repeating: "f", count: 64) : nil
    )
    let authorityIntent = HerdrTopologyMutationIntent(
      mutationID: reset
        ? "reset-00000000-0000-4000-8000-000000000004"
        : "prime-intent-fourth",
      kind: payload.intentKind,
      repositoryID: repository,
      jobID: job,
      generation: 1,
      payloadSHA256: payload.payloadSHA256,
      socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
    )
    _ = try await database.execute("UPDATE app_settings SET paused = 0 WHERE singleton = 1")
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await intentStore.prepare(authorityIntent)
    }
    #expect(
      try await database.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(authorityIntent.mutationID)]
      ) == 0
    )
    _ = try await database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
    let receipt = try await intentStore.prepare(authorityIntent)
    try await intentStore.markSendStarted(receipt)
    if crashAfterSendStarted {
      await database.close()
      let restartedDatabase = try SQLiteStore(databaseURL: databaseURL)
      let restartedIntentStore = SQLiteHerdrTopologyIntentStore(
        database: restartedDatabase,
        now: { Date(timeIntervalSince1970: 21.75) }
      )
      try await restartedIntentStore.markSentAgentPrimesUnknown()
      #expect(
        try await restartedDatabase.scalarText(
          "SELECT state FROM herdr_topology_intents WHERE id = ?",
          bindings: [.text(receipt.mutationID)]
        ) == "unknown"
      )
      #expect(try await PiRunStore(database: restartedDatabase).launches(runID: run.id).count == 3)
      #expect(
        try await restartedDatabase.scalarInt(
          "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
          bindings: [.text(job), .text(prefix + "pi-agent-authority-reset:*")]
        ) == 0
      )
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await restartedIntentStore.prepare(
          HerdrTopologyMutationIntent(
            mutationID: "reset-00000000-0000-4000-8000-000000000005",
            kind: .resetAgentAuthority,
            repositoryID: repository,
            jobID: job,
            generation: 1,
            payloadSHA256: String(repeating: "1", count: 64),
            socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
          )
        )
      }
      #expect(
        try await restartedDatabase.scalarInt(
          "SELECT COUNT(*) FROM herdr_role_host_replacement_candidates WHERE run_id = ?",
          bindings: [.text(run.id)]
        ) == 1
      )
      let incidentAuditSHA256 = JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256
      let replacementBootstrapSHA256 = String(repeating: "c", count: 64)
      let credentialEvidenceSHA256 = String(repeating: "d", count: 64)
      let replacementTokens = [
        "managed_by": "jidoka", "repository_id": repository, "job_id": job,
        "generation": "1", "role": "architecture", "run_id": run.id,
        "launch_attempt_id": replacementLaunchID, "summary": "running",
      ]
      let replacementPayload = HerdrRoleHostReplacementPayload(
        schemaVersion: 2,
        canaryAuthorizationSHA256: canaryAuthorization,
        maximumCommentParts: 8,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        retryEvidenceSHA256: retryEvidenceSHA256,
        replacementEvidenceSHA256: replacementEvidenceSHA256,
        replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
        incidentAuditSHA256: incidentAuditSHA256,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        runID: run.id,
        failedLaunchAttemptID: third.launchAttemptID,
        plannedLaunchAttemptID: replacementLaunchID,
        predecessorRoleHostID: host.id,
        predecessorProcessID: identity.processID,
        predecessorStartSeconds: identity.startSeconds,
        predecessorStartMicroseconds: identity.startMicroseconds,
        predecessorBootstrapDescriptorSHA256: host.bootstrapDescriptorSHA256,
        hostExecutableSHA256: host.hostExecutableSHA256,
        hostExecutableDevice: 1,
        hostExecutableInode: 2,
        workspaceID: host.workspaceID,
        tabID: try #require(host.tabID),
        predecessorPaneID: try #require(host.paneID),
        predecessorTerminalID: try #require(host.terminalID),
        replacementRoleHostID: replacementHostID,
        replacementBootstrapDescriptorSHA256: replacementBootstrapSHA256,
        credentialEvidenceSHA256: credentialEvidenceSHA256,
        q4Binding: replacementAuthorization.q4Binding,
        anchorRoleHostID: "host-prime-security",
        anchorPaneID: "pane-prime-2",
        anchorTerminalID: "terminal-prime-2",
        queueSequence: 4,
        agentSource: "jidoka:replacement-host",
        metadataSource: "jidoka:replacement-coordination",
        alias: "jc-prime-architecture-q4",
        reportSequence: 1,
        tokens: replacementTokens
      )
      let replacementStore = PiRunStore(database: restartedDatabase)
      #expect(
        !(try await replacementStore.persistRoleHostReplacementAuthorization(
          replacementAuthorization,
          payload: replacementPayload,
          now: Date(timeIntervalSince1970: 21.75)
        ))
      )
      let replacementIntent = HerdrTopologyMutationIntent(
        mutationID: "replace-33333333-3333-4333-8333-333333333333",
        kind: .replaceRoleHost,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: try replacementPayload.payloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
      )
      let replacementReceipt = try await restartedIntentStore.prepare(replacementIntent)
      try await restartedIntentStore.markSendStarted(replacementReceipt)
      let replacementIdentity = try HerdrHostProcessIdentity(
        processID: 777,
        startSeconds: 888,
        startMicroseconds: 999
      )
      let replacementEncoder = JSONEncoder()
      replacementEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let replacementAttribution = try HerdrRoleHostReplacementAttribution(
        predecessorRoleHostID: host.id,
        replacementRoleHostID: replacementHostID,
        workspaceID: host.workspaceID,
        tabID: try #require(host.tabID),
        paneID: "pane-prime-replacement",
        terminalID: "terminal-prime-replacement",
        processIdentity: replacementIdentity,
        executableIdentity: try HerdrProcessExecutableIdentity(
          path: "/usr/bin/true", device: 1, inode: 2
        ),
        hostExecutableSHA256: host.hostExecutableSHA256,
        alias: replacementPayload.alias,
        paneRevision: 1,
        agentStateChangeSequence: 1,
        tokensSHA256: GitHubMarkerCodec.sha256(
          try replacementEncoder.encode(replacementTokens)
        ),
        incidentAuditSHA256: incidentAuditSHA256,
        replacementEvidenceSHA256: replacementEvidenceSHA256,
        replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
        credentialEvidenceSHA256: credentialEvidenceSHA256,
        q4Binding: replacementAuthorization.q4Binding
      )
      let replacementLaunch = try await replacementStore.prepareReplacementFreshLaunch(
        launchAttemptID: replacementLaunchID,
        runID: run.id,
        predecessorRoleHostID: host.id,
        replacementRoleHostID: replacementHostID,
        descriptorSHA256: String(repeating: "f", count: 64),
        bootstrapDescriptorSHA256: replacementBootstrapSHA256,
        authority: HerdrReplacementLaunchAuthority(
          receipt: replacementReceipt,
          payload: replacementPayload,
          attribution: replacementAttribution
        ),
        now: Date(timeIntervalSince1970: 22)
      )
      #expect(replacementLaunch.queueSequence == 4)
      #expect(replacementLaunch.roleHostID == host.id)
      #expect(replacementLaunch.executionRoleHostID == replacementHostID)
      #expect(try await replacementStore.launches(runID: run.id).count == 4)
      #expect(
        try await replacementStore.roleHosts(jobID: jobID).first(where: {
          $0.id == host.id
        })?.state == .stopped
      )
      #expect(
        try await replacementStore.replacementRoleHost(id: replacementHostID)?.state
          == .waiting
      )
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await restartedDatabase.execute(
          "UPDATE herdr_role_hosts SET pane_id = 'forged-pane' WHERE id = ?",
          bindings: [.text(host.id)]
        )
      }
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await restartedDatabase.execute(
          """
          INSERT INTO pi_run_launches(
            launch_attempt_id, run_id, role_host_id, execution_role_host_id,
            queue_sequence, launch_mode, descriptor_sha256,
            expected_session_id, resume_boundary_sha256, state, failure_code,
            created_at, updated_at
          ) VALUES ('launch-replacement-fifth', ?, ?, ?, 5, 'fresh', ?, NULL, NULL,
            'prepared', NULL, 23, 23)
          """,
          bindings: [
            .text(run.id), .text(host.id), .text(replacementHostID),
            .text(String(repeating: "7", count: 64)),
          ]
        )
      }
      try await replacementStore.markReplacementRoleHostLost(
        id: replacementHostID,
        now: Date(timeIntervalSince1970: 24)
      )
      #expect(
        try await replacementStore.replacementRoleHost(id: replacementHostID)?.state == .lost
      )
      #expect(
        try await replacementStore.launches(runID: run.id).last?.state == .interruptedUnknown
      )
      #expect(
        try await replacementStore.roleHosts(jobID: jobID).filter {
          $0.role != .architecture
        }.allSatisfy { $0.state == .waiting }
      )
      #expect(try await replacementStore.jobBinding(jobID: jobID)?.state == .active)
      await restartedDatabase.close()
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let attribution = HerdrAgentAuthorityPrimeAttribution(
      workspaceID: payload.workspaceID,
      tabID: payload.tabID,
      paneIDs: [payload.paneID],
      terminalID: payload.terminalID,
      alias: payload.alias,
      agent: "pi",
      agentSessionAbsent: true,
      paneRevision: 4,
      agentStateChangeSequence: reset ? 7 : 1,
      tokensSHA256: GitHubMarkerCodec.sha256(try encoder.encode(tokens))
    )
    let authority = HerdrPrimedLaunchAuthority(
      receipt: receipt,
      payload: payload,
      attribution: attribution
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, failure_code, created_at, updated_at
        ) VALUES (?, ?, ?, 4, 'fresh', ?, NULL, NULL, 'prepared', NULL, 21.75, 21.75)
        """,
        bindings: [
          .text(planned), .text(run.id), .text(host.id),
          .text(String(repeating: "a", count: 64)),
        ]
      )
    }
    let attempts = [
      Task {
        try await store.preparePrimedFreshLaunch(
          launchAttemptID: planned,
          runID: run.id,
          roleHostID: host.id,
          descriptorSHA256: String(repeating: "a", count: 64),
          authority: authority,
          now: Date(timeIntervalSince1970: 22)
        )
      },
      Task {
        try await store.preparePrimedFreshLaunch(
          launchAttemptID: planned,
          runID: run.id,
          roleHostID: host.id,
          descriptorSHA256: String(repeating: "a", count: 64),
          authority: authority,
          now: Date(timeIntervalSince1970: 22)
        )
      },
    ]
    var successes = 0
    var failures: [PiRunStoreError] = []
    for attempt in attempts {
      do {
        _ = try await attempt.value
        successes += 1
      } catch let error as PiRunStoreError {
        failures.append(error)
      }
    }
    #expect(successes == 1)
    #expect(failures == [.invalidTransition])
    #expect(try await store.launches(runID: run.id).count == 4)
    #expect(try await PiRunStore(database: database).launches(runID: run.id).count == 4)
    #expect(
      try await database.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE id = ? AND state = 'attributed'",
        bindings: [.text(receipt.mutationID)]
      ) == 1
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await database.execute(
        "UPDATE herdr_topology_intents SET state = 'unknown', attribution_json = NULL WHERE id = ?",
        bindings: [.text(receipt.mutationID)]
      )
    }
    _ = try await database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (?, ?, 'runningPi', 'runningPi', 'forged q5 authority', 3, 3, 0, 0, 23)
      """,
      bindings: [
        .text(job),
        .text(
          prefix + "pi-fresh-retry:" + run.id + ":" + planned + ":"
            + String(repeating: "b", count: 64)
        ),
      ]
    )
    let reopened = PiRunStore(database: database)
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await reopened.prepareLaunch(
        launchAttemptID: "launch-prime-fifth",
        runID: run.id,
        roleHostID: host.id,
        launchMode: .fresh,
        descriptorSHA256: String(repeating: "c", count: 64),
        expectedSessionID: nil,
        resumeBoundarySHA256: nil,
        now: Date(timeIntervalSince1970: 24)
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, failure_code, created_at, updated_at
        ) VALUES ('launch-prime-fifth-raw', ?, ?, 5, 'fresh', ?, NULL, NULL,
          'prepared', NULL, 24, 24)
        """,
        bindings: [
          .text(run.id), .text(host.id), .text(String(repeating: "c", count: 64)),
        ]
      )
    }
    #expect(try await store.launches(runID: run.id).count == 4)
  }

  @Test("paused topology intents require the exact open canary authority")
  func pausedTopologyIntentCanaryAuthority() async throws {
    let fixture = try await StoreFixture.make(role: .architecture)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.database.execute(
      "UPDATE jobs SET kind = 'prReview', current_step_kind = 'review' WHERE id = ?",
      bindings: [.text(fixture.jobID.uuidString.lowercased())]
    )
    let jobID = fixture.jobID.uuidString.lowercased()
    let repositoryID = fixture.repositoryID.uuidString.lowercased()
    let authorization = String(repeating: "a", count: 64)
    let prefix = "canary:\(authorization):m2:"
    _ = try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    _ = try await fixture.database.execute(
      """
      INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
      VALUES (?, ?, 1, 10, 1)
      """,
      bindings: [.text(repositoryID), .text(jobID)]
    )
    for (eventKey, from, to, reason) in [
      (prefix + "admit:" + jobID, "queued", "leased", "exact canary admission"),
      (prefix + "pi:architecture:r1", "runningPi", "runningPi", "exact Pi role"),
    ] {
      _ = try await fixture.database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, ?, ?, ?, 1, 1, 0, 0, 10)
        """,
        bindings: [
          .text(jobID), .text(eventKey), .text(from), .text(to), .text(reason),
        ]
      )
    }
    let intentStore = SQLiteHerdrTopologyIntentStore(database: fixture.database)
    await #expect(throws: PiRunStoreError.launchSuppressed) {
      _ = try await intentStore.prepare(
        HerdrTopologyMutationIntent(
          mutationID: "mutation-canary-wrong-repository",
          kind: .createWorkspace,
          repositoryID: "50000000-0000-0000-0000-000000000005",
          jobID: jobID,
          generation: 1,
          payloadSHA256: String(repeating: "d", count: 64),
          socketIdentity: HerdrSocketIdentityRecord(
            handshake(workspaceID: "workspace-1").socketIdentity
          )
        )
      )
    }
    let intent = HerdrTopologyMutationIntent(
      mutationID: "mutation-canary-open",
      kind: .createWorkspace,
      repositoryID: repositoryID,
      jobID: jobID,
      generation: 1,
      payloadSHA256: String(repeating: "b", count: 64),
      socketIdentity: HerdrSocketIdentityRecord(
        handshake(workspaceID: "workspace-1").socketIdentity
      )
    )
    let receipt = try await intentStore.prepare(intent)
    try await intentStore.markSendStarted(receipt)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE id = 'mutation-canary-open' AND state = 'sendStarted'"
      ) == 1
    )
    let run = try await fixture.store.prepareRun(
      id: "run-canary-paused",
      jobID: fixture.jobID,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      jobAttempt: 1,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "e", count: 64),
      requestSHA256: String(repeating: "f", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "0", count: 64),
      model: "fixture/model:max",
      sessionPath: fixture.root.appendingPathComponent("canary-session"),
      channelPath: fixture.root.appendingPathComponent("canary-channel"),
      now: Date(timeIntervalSince1970: 10)
    )
    let launch = try await fixture.store.prepareLaunch(
      launchAttemptID: "launch-canary-paused",
      runID: run.id,
      roleHostID: fixture.roleHostID,
      launchMode: .fresh,
      descriptorSHA256: String(repeating: "1", count: 64),
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      now: Date(timeIntervalSince1970: 11)
    )
    #expect(launch.state == .prepared)

    _ = try await fixture.database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (?, ?, 'retryBackoff', 'retryBackoff', 'canary closed', 1, 1, 0, 0, 11)
      """,
      bindings: [.text(jobID), .text(prefix + "close:" + jobID)]
    )
    await #expect(throws: PiRunStoreError.launchSuppressed) {
      _ = try await intentStore.prepare(
        HerdrTopologyMutationIntent(
          mutationID: "mutation-canary-closed",
          kind: .createWorkspace,
          repositoryID: repositoryID,
          jobID: jobID,
          generation: 1,
          payloadSHA256: String(repeating: "c", count: 64),
          socketIdentity: intent.socketIdentity
        )
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

    let unknownIntent = HerdrTopologyMutationIntent(
      mutationID: "mutation-unknown-0001",
      kind: .applyLayout,
      repositoryID: intent.repositoryID,
      jobID: intent.jobID,
      generation: intent.generation,
      payloadSHA256: String(repeating: "d", count: 64),
      socketIdentity: intent.socketIdentity
    )
    let unknownReceipt = try await intentStore.prepare(unknownIntent)
    try await intentStore.markSendStarted(unknownReceipt)
    try await intentStore.markUnknown(unknownReceipt)
    await #expect(throws: PiRunStoreError.invalidTransition) {
      try await intentStore.attribute(unknownReceipt, as: attribution)
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE herdr_topology_intents SET state = 'attributed', attribution_json = '{}' WHERE id = ?",
        bindings: [.text(unknownIntent.mutationID)]
      )
    }
    #expect(
      try await fixture.database.scalarText(
        "SELECT state FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(unknownIntent.mutationID)]
      ) == "unknown"
    )
  }

  @Test("topology intent timestamps are transition-bound while replays remain exact")
  func topologyIntentTimestampsAreTransitionBound() async throws {
    let fixture = try await StoreFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let intentStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 200) }
    )
    let intent = HerdrTopologyMutationIntent(
      mutationID: "mutation-timestamp-0001",
      kind: .applyLayout,
      repositoryID: fixture.repositoryID.uuidString.lowercased(),
      jobID: fixture.jobID.uuidString.lowercased(),
      generation: 1,
      payloadSHA256: String(repeating: "e", count: 64),
      socketIdentity: HerdrSocketIdentityRecord(
        handshake(workspaceID: "workspace-1").socketIdentity)
    )
    let receipt = try await intentStore.prepare(intent)
    let prepared = try #require(
      try await fixture.database.query(
        "SELECT * FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first
    )

    for timestamp in [199.0, 201.0] {
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await fixture.database.execute(
          "UPDATE herdr_topology_intents SET updated_at = ? WHERE id = ?",
          bindings: [.real(timestamp), .text(intent.mutationID)]
        )
      }
    }
    #expect(
      try await fixture.database.query(
        "SELECT * FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first == prepared
    )

    let regressiveStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 199) }
    )
    await #expect(throws: PiRunStoreError.invalidTransition) {
      try await regressiveStore.markSendStarted(receipt)
    }
    let nonFiniteStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: .nan) }
    )
    await #expect(throws: PiRunStoreError.invalidTransition) {
      try await nonFiniteStore.markSendStarted(receipt)
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        UPDATE herdr_topology_intents
        SET state = 'sendStarted', attribution_json = NULL, updated_at = 199
        WHERE id = ? AND state = 'prepared'
        """,
        bindings: [.text(intent.mutationID)]
      )
    }

    try await intentStore.markSendStarted(receipt)
    let beforeReplay = try #require(
      try await fixture.database.query(
        "SELECT * FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first
    )
    let replayStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 199) }
    )
    try await replayStore.markSendStarted(receipt)
    #expect(
      try await fixture.database.query(
        "SELECT * FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first == beforeReplay
    )

    let attribution = HerdrTopologyMutationAttribution(
      workspaceID: "workspace-1",
      tabID: "tab-1",
      paneIDs: ["pane-1"]
    )
    let monotonicStore = SQLiteHerdrTopologyIntentStore(
      database: fixture.database,
      now: { Date(timeIntervalSince1970: 301) }
    )
    try await monotonicStore.attribute(receipt, as: attribution)
    #expect(
      try await fixture.database.query(
        "SELECT updated_at FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first?["updated_at"] == .real(301)
    )

    for (index, timestamp) in [200.0, 201.0].enumerated() {
      let rawIntent = HerdrTopologyMutationIntent(
        mutationID: "mutation-timestamp-raw-\(index)",
        kind: .applyLayout,
        repositoryID: intent.repositoryID,
        jobID: intent.jobID,
        generation: intent.generation,
        payloadSHA256: String(repeating: Character(String(index + 1)), count: 64),
        socketIdentity: intent.socketIdentity
      )
      _ = try await intentStore.prepare(rawIntent)
      #expect(
        try await fixture.database.execute(
          """
          UPDATE herdr_topology_intents
          SET state = 'sendStarted', attribution_json = NULL, updated_at = ?
          WHERE id = ? AND state = 'prepared' AND updated_at = 200
          """,
          bindings: [.real(timestamp), .text(rawIntent.mutationID)]
        ) == 1
      )
    }

    do {
      _ =
        try await fixture.database.transaction { database in
          _ = try database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
          return try database.execute(
            "UPDATE herdr_topology_intents SET updated_at = 302 WHERE id = ?",
            bindings: [.text(intent.mutationID)]
          )
        }
      Issue.record("timestamp-only transaction unexpectedly committed")
    } catch is SQLiteStoreError {
      // Expected.
    }
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
    #expect(
      try await fixture.database.query(
        "SELECT updated_at FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first?["updated_at"] == .real(301)
    )
  }

  @Test(
    "replacement store rejects every ordinary-host physical identity collision",
    arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  )
  func replacementIdentityCollisionsAreRejectedByStore(collision: Int) async throws {
    if collision == 1 {
      await #expect(throws: PiRunStoreError.invalidTransition) {
        _ = try await ReplacementCutoverFixture.make(collision: collision)
      }
      return
    }
    let fixture = try await ReplacementCutoverFixture.make(collision: collision)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.prepareReplacement()
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement SQL rejects every ordinary-host physical identity collision",
    arguments: [2, 3, 4, 5, 6, 7, 8, 9, 10]
  )
  func replacementIdentityCollisionsAreRejectedBySQL(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make(collision: collision)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost()
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement store rejects global ordinary-host identities",
    arguments: [1, 2, 3, 4]
  )
  func replacementStoreRejectsGlobalOrdinaryHostIdentity(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.insertUnrelatedOrdinaryHost(collidingOn: collision)
    let before = try await fixture.snapshot()
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.prepareReplacement()
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement SQL rejects cross-job ordinary-host physical identity collisions",
    arguments: [1, 2, 3, 4]
  )
  func replacementCrossJobIdentityCollisionsAreRejectedBySQL(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let unrelatedHostID = try await fixture.insertUnrelatedOrdinaryHost(
      collidingOn: collision
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE id = ? AND job_id != ?",
        bindings: [
          .text(unrelatedHostID),
          .text(fixture.jobID.uuidString.lowercased()),
        ]
      ) == 1
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost()
    }
  }

  @Test(
    "replacement SQL rejects every global ordinary lifecycle collision",
    arguments: ordinaryFirstRawCollisionCases
  )
  func replacementSQLRejectsEveryGlobalOrdinaryLifecycleCollision(
    collisionCase: CrossTableHostCollisionCase
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let unrelatedHostID = try await fixture.insertUnrelatedOrdinaryHost(
      collidingOn: collisionCase.dimension,
      state: collisionCase.state,
      raw: true
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost()
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE id = ? AND state = ?",
        bindings: [.text(unrelatedHostID), .text(collisionCase.state)]
      ) == 1
    )
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM herdr_replacement_role_hosts")
        == 0
    )
  }

  @Test(
    "ordinary raw DML rejects every replacement lifecycle collision",
    arguments: replacementFirstRawCollisionCases
  )
  func ordinarySQLRejectsEveryReplacementLifecycleCollision(
    collisionCase: CrossTableHostCollisionCase
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    try await fixture.transitionReplacement(to: collisionCase.state)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.insertUnrelatedOrdinaryHost(
        collidingOn: collisionCase.dimension,
        raw: true
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ?",
        bindings: [.text("43000000-0000-0000-0000-000000000004")]
      ) == 0
    )
    #expect(
      try await fixture.database.query(
        "SELECT updated_at FROM herdr_job_bindings WHERE job_id = ?",
        bindings: [.text("43000000-0000-0000-0000-000000000004")]
      ).first?["updated_at"] == .real(22)
    )
  }

  @Test(
    "ordinary raw activation rejects replacement physical identities",
    arguments: replacementFirstPhysicalCollisionCases
  )
  func ordinaryRawActivationRejectsReplacementIdentity(
    collisionCase: CrossTableHostCollisionCase
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    try await fixture.transitionReplacement(to: collisionCase.state)
    let roleHostID = try await fixture.insertUnrelatedOrdinaryHost(
      collidingOn: 0,
      state: "prepared",
      raw: true
    )
    let attribution = fixture.authority.attribution
    let paneID =
      collisionCase.dimension == 1 ? attribution.paneID : "pane-unrelated-raw-activation"
    let terminalID =
      collisionCase.dimension == 2
      ? attribution.terminalID : "terminal-unrelated-raw-activation"
    let processID = collisionCase.dimension == 3 ? attribution.processID : 780
    let startSeconds = collisionCase.dimension == 3 ? attribution.startSeconds : 891
    let startMicroseconds = collisionCase.dimension == 3 ? attribution.startMicroseconds : 996
    do {
      _ =
        try await fixture.database.transaction { database in
          _ = try database.execute(
            "UPDATE herdr_job_bindings SET updated_at = 24 WHERE job_id = ?",
            bindings: [.text("43000000-0000-0000-0000-000000000004")]
          )
          return try database.execute(
            """
            UPDATE herdr_role_hosts
            SET tab_id = 'tab-unrelated', pane_id = ?, terminal_id = ?, host_pid = ?,
              host_start_seconds = ?, host_start_microseconds = ?, state = 'waiting',
              lifecycle_sequence = 1, updated_at = 24
            WHERE id = ? AND state = 'prepared'
            """,
            bindings: [
              .text(paneID),
              .text(terminalID),
              .integer(Int64(processID)),
              .integer(Int64(startSeconds)),
              .integer(Int64(startMicroseconds)),
              .text(roleHostID),
            ]
          )
        }
      Issue.record("cross-table physical collision unexpectedly committed")
    } catch is SQLiteStoreError {
      // Expected.
    }
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE id = ? AND state = 'prepared'
          AND pane_id IS NULL AND terminal_id IS NULL AND host_pid IS NULL
        """,
        bindings: [.text(roleHostID)]
      ) == 1
    )
    #expect(
      try await fixture.database.query(
        "SELECT updated_at FROM herdr_job_bindings WHERE job_id = ?",
        bindings: [.text("43000000-0000-0000-0000-000000000004")]
      ).first?["updated_at"] == .real(23)
    )
  }

  @Test(
    "ordinary store preparation and activation reject replacement identities",
    arguments: [1, 2, 3, 4]
  )
  func ordinaryStoreRejectsReplacementIdentity(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.insertUnrelatedOrdinaryHost(collidingOn: collision)
    }
    let unrelatedJobID = "43000000-0000-0000-0000-000000000004"
    #expect(
      try await fixture.database.scalarText(
        "SELECT state FROM herdr_job_bindings WHERE job_id = ?",
        bindings: [.text(unrelatedJobID)]
      ) == "prepared"
    )
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE job_id = ? AND state = 'prepared'
          AND pane_id IS NULL AND terminal_id IS NULL AND host_pid IS NULL
        """,
        bindings: [.text(unrelatedJobID)]
      ) == (collision == 4 ? 0 : 1)
    )
  }

  @Test(
    "ordinary physical identity updates never alias a replacement host",
    arguments: [1, 2, 3, 4]
  )
  func ordinaryIdentityUpdateRejectsReplacementIdentity(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let roleHostID = try await fixture.insertUnrelatedOrdinaryHost(collidingOn: 0)
    let before = try #require(
      try await fixture.database.query(
        "SELECT * FROM herdr_role_hosts WHERE id = ?",
        bindings: [.text(roleHostID)]
      ).first
    )
    let attribution = fixture.authority.attribution
    let update: String
    let bindings: [SQLiteValue]
    switch collision {
    case 1:
      update = "pane_id = ?"
      bindings = [.text(attribution.paneID), .text(roleHostID)]
    case 2:
      update = "terminal_id = ?"
      bindings = [.text(attribution.terminalID), .text(roleHostID)]
    case 3:
      update =
        "host_pid = ?, host_start_seconds = ?, host_start_microseconds = ?"
      bindings = [
        .integer(Int64(attribution.processID)),
        .integer(Int64(attribution.startSeconds)),
        .integer(Int64(attribution.startMicroseconds)),
        .text(roleHostID),
      ]
    case 4:
      update = "id = ?"
      bindings = [.text(fixture.replacementRoleHostID), .text(roleHostID)]
    default:
      throw PiRunStoreError.invalidRecord
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE herdr_role_hosts SET \(update) WHERE id = ?",
        bindings: bindings
      )
    }
    #expect(
      try await fixture.database.query(
        "SELECT * FROM herdr_role_hosts WHERE id = ?",
        bindings: [.text(roleHostID)]
      ).first == before
    )
  }

  @Test("ordinary store rebind rejects a replacement pane")
  func ordinaryStoreRebindRejectsReplacementPane() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let roleHostID = try await fixture.insertUnrelatedOrdinaryHost(collidingOn: 0)
    let ordinary = try #require(
      try await fixture.store.roleHosts().first(where: { $0.id == roleHostID })
    )
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.rebindRoleHost(
        id: roleHostID,
        workspaceID: ordinary.workspaceID,
        tabID: try #require(ordinary.tabID),
        paneID: fixture.authority.attribution.paneID,
        terminalID: try #require(ordinary.terminalID),
        processIdentity: try #require(ordinary.processIdentity),
        now: Date(timeIntervalSince1970: 24)
      )
    }
    #expect(try await fixture.store.roleHosts().first(where: { $0.id == roleHostID }) == ordinary)
  }

  @Test(
    "single-host activation rejects every replacement physical identity",
    arguments: [1, 2, 3]
  )
  func singleOrdinaryHostActivationRejectsReplacementIdentity(collision: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let roleHostID = try await fixture.insertUnrelatedOrdinaryHost(
      collidingOn: 0,
      state: "prepared"
    )
    let unrelatedJobID = "43000000-0000-0000-0000-000000000004"
    _ = try await fixture.database.execute(
      """
      UPDATE herdr_job_bindings
      SET tab_id = 'tab-unrelated', state = 'active', updated_at = 23
      WHERE job_id = ? AND state = 'prepared'
      """,
      bindings: [.text(unrelatedJobID)]
    )
    let attribution = fixture.authority.attribution
    let processIdentity = try HerdrHostProcessIdentity(
      processID: collision == 3 ? attribution.processID : 779,
      startSeconds: collision == 3 ? attribution.startSeconds : 890,
      startMicroseconds: collision == 3 ? attribution.startMicroseconds : 997
    )
    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.activateRoleHost(
        id: roleHostID,
        tabID: "tab-unrelated",
        paneID: collision == 1 ? attribution.paneID : "pane-unrelated-single",
        terminalID: collision == 2 ? attribution.terminalID : "terminal-unrelated-single",
        processIdentity: processIdentity,
        now: Date(timeIntervalSince1970: 24)
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE id = ? AND state = 'prepared'
          AND pane_id IS NULL AND terminal_id IS NULL AND host_pid IS NULL
        """,
        bindings: [.text(roleHostID)]
      ) == 1
    )
  }

  @Test("noncolliding ordinary and replacement hosts remain valid controls")
  func crossTableHostIdentityValidControls() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let ordinaryID = try await fixture.insertUnrelatedOrdinaryHost(collidingOn: 0)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE id = ? AND state = 'waiting'",
        bindings: [.text(ordinaryID)]
      ) == 1
    )
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM herdr_replacement_role_hosts")
        == 1
    )
  }

  @Test("replacement authorization is inert, idempotent, immutable, and exact")
  func replacementAuthorizationIsExactAndInert() async throws {
    let fixture = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_host_replacement_authorizations"
      ) == 1
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE kind = 'replaceRoleHost'"
      ) == 0
    )
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM herdr_replacement_role_hosts")
        == 0
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
    #expect(
      try await fixture.store.persistRoleHostReplacementAuthorization(
        fixture.replacementAuthorization,
        payload: fixture.authority.payload,
        now: Date(timeIntervalSince1970: 22)
      )
    )
    let differing = JobCanaryRoleHostReplacementAuthorization(
      request: fixture.replacementAuthorization.request,
      replacementEvidenceSHA256: String(repeating: "e", count: 64),
      q4Binding: fixture.replacementAuthorization.q4Binding
    )
    await #expect(throws: PiRunStoreError.invalidRecord) {
      _ = try await fixture.store.persistRoleHostReplacementAuthorization(
        differing,
        payload: fixture.authority.payload,
        now: Date(timeIntervalSince1970: 22)
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE herdr_role_host_replacement_authorizations SET created_at = 23"
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "DELETE FROM herdr_role_host_replacement_authorizations"
      )
    }
    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    #expect(
      try await PiRunStore(database: reopenedDatabase).persistRoleHostReplacementAuthorization(
        fixture.replacementAuthorization,
        payload: fixture.authority.payload,
        now: Date(timeIntervalSince1970: 23)
      )
    )
    #expect(
      try await reopenedDatabase.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE kind = 'replaceRoleHost'"
      ) == 0
    )
    #expect(
      try await reopenedDatabase.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
    await reopenedDatabase.close()
  }

  @Test(
    "replacement authorization rejects every one-field q4 backing digest drift",
    arguments: Array(0..<7)
  )
  func replacementAuthorizationRejectsQ4BindingDrift(field: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    let drifted = replacementQ4Binding(driftingField: field)
    await #expect(throws: PiRunStoreError.invalidRecord) {
      _ = try await fixture.store.persistRoleHostReplacementAuthorization(
        fixture.replacementAuthorization,
        payload: fixture.replacementPayload(q4Binding: drifted),
        now: Date(timeIntervalSince1970: 22)
      )
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement authorization rejects each adjacent q4 digest-role transposition",
    arguments: Array(0..<6)
  )
  func replacementAuthorizationRejectsQ4DigestRoleTransposition(
    leftField: Int
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    let transposed = replacementQ4Binding(transposingAt: leftField)
    await #expect(throws: PiRunStoreError.invalidRecord) {
      _ = try await fixture.store.persistRoleHostReplacementAuthorization(
        fixture.replacementAuthorization,
        payload: fixture.replacementPayload(q4Binding: transposed),
        now: Date(timeIntervalSince1970: 22)
      )
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement SQL denies every one-field q4 backing digest drift before cutover",
    arguments: Array(0..<7)
  )
  func replacementHostRejectsQ4BindingDrift(field: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost(
        q4Binding: replacementQ4Binding(driftingField: field)
      )
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement SQL rejects each adjacent q4 digest-role transposition before cutover",
    arguments: Array(0..<6)
  )
  func replacementHostRejectsQ4DigestRoleTransposition(leftField: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost(
        q4Binding: replacementQ4Binding(transposingAt: leftField)
      )
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test(
    "replacement attribution denies every one-field q4 backing digest drift",
    arguments: Array(0..<7)
  )
  func replacementAttributionRejectsQ4BindingDrift(field: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.attributeRawReplacement(
        try fixture.replacementAttributionJSON(
          q4Binding: replacementQ4Binding(driftingField: field)
        )
      )
    }
    #expect(
      try await fixture.database.scalarText(
        "SELECT state FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(fixture.authority.receipt.mutationID)]
      ) == "sendStarted"
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
  }

  @Test(
    "replacement attribution rejects each adjacent q4 digest-role transposition",
    arguments: Array(0..<6)
  )
  func replacementAttributionRejectsQ4DigestRoleTransposition(
    leftField: Int
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.attributeRawReplacement(
        try fixture.replacementAttributionJSON(
          q4Binding: replacementQ4Binding(transposingAt: leftField)
        )
      )
    }
    #expect(
      try await fixture.database.scalarText(
        "SELECT state FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(fixture.authority.receipt.mutationID)]
      ) == "sendStarted"
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
  }

  @Test("replacement rejects a coherent post-preview q4 authorization rebind")
  func replacementAuthorizationRejectsCoherentPostPreviewQ4Rebind() async throws {
    let fixture = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    let reboundBinding = replacementQ4Binding(driftingField: 0)
    let reboundAuthorization = JobCanaryRoleHostReplacementAuthorization(
      request: fixture.replacementAuthorization.request,
      replacementEvidenceSHA256: fixture.replacementAuthorization.replacementEvidenceSHA256,
      q4Binding: reboundBinding
    )
    let reboundPayload = fixture.replacementPayload(
      q4Binding: reboundBinding,
      replacementAuthorizationSHA256: reboundAuthorization.authorizationSHA256
    )
    try reboundAuthorization.validate()
    try reboundPayload.validate()
    #expect(reboundPayload.q4Binding == reboundAuthorization.q4Binding)
    #expect(
      reboundPayload.replacementAuthorizationSHA256
        == reboundAuthorization.authorizationSHA256
    )

    await #expect(throws: PiRunStoreError.bindingCollision) {
      _ = try await fixture.store.persistRoleHostReplacementAuthorization(
        reboundAuthorization,
        payload: reboundPayload,
        now: Date(timeIntervalSince1970: 23)
      )
    }
    #expect(try await fixture.snapshot() == before)

    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        """
        UPDATE herdr_role_host_replacement_authorizations
        SET replacement_authorization_sha256 = ?, payload_sha256 = ?,
          q4_descriptor_sha256 = ?, q4_configuration_sha256 = ?,
          q4_prompt_sha256 = ?, q4_workflow_configuration_sha256 = ?,
          q4_prior_launch_descriptor_sha256 = ?,
          q4_prior_launch_configuration_sha256 = ?, q4_resource_tree_sha256 = ?
        """,
        bindings: [
          .text(reboundAuthorization.authorizationSHA256),
          .text(try reboundPayload.payloadSHA256),
          .text(reboundBinding.descriptorSHA256),
          .text(reboundBinding.configurationSHA256),
          .text(reboundBinding.promptSHA256),
          .text(reboundBinding.workflowConfigurationSHA256),
          .text(reboundBinding.priorLaunchDescriptorSHA256),
          .text(reboundBinding.priorLaunchConfigurationSHA256),
          .text(reboundBinding.resourceTreeSHA256),
        ]
      )
    }
    #expect(try await fixture.snapshot() == before)
  }

  @Test("replacement durable state rejects a forged well-formed authorization digest")
  func replacementStateRejectsForgedAuthorizationDigest() async throws {
    let valid = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: valid.root) }
    let validState = try await DurableJobStore(database: valid.database)
      .canaryRoleHostReplacementState(request: valid.replacementAuthorization.request)
    #expect(validState.replacementHost == nil)
    #expect(validState.replacementLaunch == nil)

    let forged = try await ReplacementCutoverFixture.make(
      persistAuthorization: false,
      prepareIntent: false
    )
    defer { try? FileManager.default.removeItem(at: forged.root) }
    let forgedDigest = String(repeating: "f", count: 64)
    #expect(forgedDigest != forged.replacementAuthorization.authorizationSHA256)
    try await forged.insertRawReplacementAuthorization(
      authorizationSHA256: forgedDigest
    )
    #expect(
      try await forged.database.scalarText(
        "SELECT replacement_authorization_sha256 FROM herdr_role_host_replacement_authorizations"
      ) == forgedDigest
    )
    await #expect(throws: DurableJobStoreError.canaryRecoveryRequired) {
      _ = try await DurableJobStore(database: forged.database)
        .canaryRoleHostReplacementState(request: forged.replacementAuthorization.request)
    }
  }

  @Test("replacement intent requires the exact durable authorization payload")
  func replacementIntentRequiresAuthorizationPayload() async throws {
    let missing = try await ReplacementCutoverFixture.make(
      persistAuthorization: false,
      prepareIntent: false
    )
    defer { try? FileManager.default.removeItem(at: missing.root) }
    let missingStore = SQLiteHerdrTopologyIntentStore(database: missing.database)
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await missingStore.prepare(missing.replacementIntent)
    }

    let wrongPayload = try await ReplacementCutoverFixture.make(prepareIntent: false)
    defer { try? FileManager.default.removeItem(at: wrongPayload.root) }
    let wrongPayloadStore = SQLiteHerdrTopologyIntentStore(database: wrongPayload.database)
    let mismatched = HerdrTopologyMutationIntent(
      mutationID: wrongPayload.replacementIntent.mutationID,
      kind: .replaceRoleHost,
      repositoryID: wrongPayload.replacementIntent.repositoryID,
      jobID: wrongPayload.replacementIntent.jobID,
      generation: wrongPayload.replacementIntent.generation,
      payloadSHA256: String(repeating: "f", count: 64),
      socketIdentity: wrongPayload.replacementIntent.socketIdentity
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await wrongPayloadStore.prepare(mismatched)
    }
  }

  @Test("replacement host must use the authorization's planned durable identity")
  func replacementHostRequiresPlannedIdentity() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawReplacementRoleHost(
        id: "rolehost-70000000-0000-4000-8000-000000000007"
      )
    }
  }

  @Test(
    "replacement attribution rejects authorization and evidence drift",
    arguments: [1, 2]
  )
  func replacementAttributionRequiresAuthorizationTuple(drift: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    let json: String
    switch drift {
    case 1:
      json = try fixture.replacementAttributionJSON(
        replacementAuthorizationSHA256: String(repeating: "e", count: 64)
      )
    case 2:
      json = try fixture.replacementAttributionJSON(
        replacementEvidenceSHA256: String(repeating: "e", count: 64)
      )
    default:
      throw PiRunStoreError.invalidRecord
    }
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.attributeRawReplacement(json)
    }
  }

  @Test("replacement q4 must use the authorization's planned launch identity")
  func replacementQ4RequiresPlannedIdentity() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    try await fixture.attributeRawReplacement(try fixture.replacementAttributionJSON())
    try await fixture.insertRawReplacementEvent()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawQ4(
        launchAttemptID: "launch-70000000-0000-4000-8000-000000000007"
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
  }

  @Test("replacement q4 SQL requires the exact preview-bound descriptor digest")
  func replacementQ4RequiresBoundDescriptor() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    try await fixture.attributeRawReplacement(try fixture.replacementAttributionJSON())
    try await fixture.insertRawReplacementEvent()
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawQ4(
        launchAttemptID: fixture.replacementLaunchAttemptID,
        descriptorSHA256: String(repeating: "e", count: 64)
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
  }

  @Test(
    "replacement q4 SQL rejects every one-field event authority drift",
    arguments: Array(0..<10)
  )
  func replacementQ4RejectsEveryEventAuthorityDrift(field: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    try await fixture.attributeRawReplacement(try fixture.replacementAttributionJSON())
    try await fixture.insertRawReplacementEvent(driftingField: field)
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawQ4(
        launchAttemptID: fixture.replacementLaunchAttemptID
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
  }

  @Test("replacement store constructs the one exact q4 event authority")
  func replacementStoreConstructsExactQ4EventAuthority() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let exactEvent = try fixture.replacementEventKey()
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ?",
        bindings: [
          .text(fixture.jobID.uuidString.lowercased()),
          .text(exactEvent),
        ]
      ) == 1
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(fixture.runID)]
      ) == 1
    )
  }

  @Test("replacement q4 rejects a mismatched canary authorization SHA")
  func replacementQ4RejectsMismatchedCanaryAuthorization() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.insertRawReplacementRoleHost()
    try await fixture.stopRawPredecessor()
    try await fixture.attributeRawReplacement(try fixture.replacementAttributionJSON())
    let wrongCanaryAuthorizationSHA256 = String(repeating: "0", count: 64)
    #expect(
      wrongCanaryAuthorizationSHA256
        != fixture.authority.payload.canaryAuthorizationSHA256
    )
    try await fixture.insertRawReplacementEvent(driftingField: 1)
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertRawQ4(
        launchAttemptID: fixture.replacementLaunchAttemptID
      )
    }
  }

  @Test("prepared replacement intent remains the only nonterminal continuation after restart")
  func replacementPreparedIntentRemainsContinuable() async throws {
    let fixture = try await ReplacementCutoverFixture.make(sendIntentStarted: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(
      try await DurableJobStore(database: fixture.database)
        .canaryRoleHostReplacementTerminalReport(
          request: fixture.replacementAuthorization.request
        ) == nil
    )
    _ = try await DurableJobStore(database: fixture.database)
      .canaryRoleHostReplacementState(request: fixture.replacementAuthorization.request)
    await fixture.database.close()

    let reopened = try SQLiteStore(databaseURL: fixture.databaseURL)
    let jobs = DurableJobStore(database: reopened)
    #expect(
      try await jobs.canaryRoleHostReplacementTerminalReport(
        request: fixture.replacementAuthorization.request
      ) == nil
    )
    let state = try await jobs.canaryRoleHostReplacementState(
      request: fixture.replacementAuthorization.request
    )
    #expect(state.replacementHost == nil)
    #expect(state.replacementLaunch == nil)
    await reopened.close()
  }

  @Test(
    "replacement terminal outcomes reconstruct after close and reopen without replay",
    arguments: ReplacementTerminalShape.allCases
  )
  func replacementTerminalOutcomesSurviveRestart(
    shape: ReplacementTerminalShape
  ) async throws {
    let fixture = try await ReplacementCutoverFixture.make(
      sendIntentStarted: shape != .noRemoteEffectFailure
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let intentStore = SQLiteHerdrTopologyIntentStore(database: fixture.database)
    switch shape {
    case .noRemoteEffectFailure:
      try await intentStore.markFailedNoRemoteEffect(
        fixture.authority.receipt,
        failureCode: "INVALID_PREPARATION"
      )
    case .remoteEffectAmbiguous:
      try await intentStore.markUnknown(fixture.authority.receipt)
    case .q4Prepared, .q4Enqueued, .q4OutcomeAmbiguous, .q4Failed, .q4Settled,
      .replacementHostLost:
      let launch = try await fixture.prepareReplacement()
      if shape == .replacementHostLost {
        _ = try await fixture.store.transitionReplacementRoleHost(
          id: fixture.replacementRoleHostID,
          to: .lost,
          now: Date(timeIntervalSince1970: 23)
        )
      } else if shape != .q4Prepared {
        _ = try await fixture.store.transitionLaunch(
          launchAttemptID: launch.launchAttemptID,
          to: .enqueued,
          event: .enqueued,
          recordSHA256: launch.descriptorSHA256,
          now: Date(timeIntervalSince1970: 23)
        )
        if shape != .q4Enqueued {
          _ = try await fixture.store.transitionLaunch(
            launchAttemptID: launch.launchAttemptID,
            to: .running,
            event: .running,
            now: Date(timeIntervalSince1970: 24)
          )
        }
        switch shape {
        case .q4OutcomeAmbiguous:
          _ = try await fixture.store.transitionLaunch(
            launchAttemptID: launch.launchAttemptID,
            to: .interruptedUnknown,
            event: .interruptedUnknown,
            detailCode: "RUNTIME_INTERRUPTED",
            now: Date(timeIntervalSince1970: 25)
          )
        case .q4Failed:
          _ = try await fixture.store.transitionLaunch(
            launchAttemptID: launch.launchAttemptID,
            to: .failed,
            event: .failed,
            detailCode: "CHILD_FAILED",
            now: Date(timeIntervalSince1970: 25)
          )
        case .q4Settled:
          let envelope = Data("durable replacement q4 result".utf8)
          let resultSHA256 = GitHubMarkerCodec.sha256(envelope)
          _ = try await fixture.store.settle(
            runID: fixture.runID,
            launchAttemptID: launch.launchAttemptID,
            resultEnvelope: envelope,
            resultSHA256: resultSHA256,
            sessionID: "77777777-7777-4777-8777-777777777777",
            sessionBoundarySHA256: String(repeating: "8", count: 64),
            now: Date(timeIntervalSince1970: 25)
          )
          try await fixture.store.recordAcknowledgement(
            runID: fixture.runID,
            launchAttemptID: launch.launchAttemptID,
            resultSHA256: resultSHA256,
            now: Date(timeIntervalSince1970: 26)
          )
          try await fixture.store.recordRelease(
            runID: fixture.runID,
            launchAttemptID: launch.launchAttemptID,
            resultSHA256: resultSHA256,
            now: Date(timeIntervalSince1970: 27)
          )
        default:
          break
        }
      }
    }

    await fixture.database.close()
    let reopened = try SQLiteStore(databaseURL: fixture.databaseURL)
    let jobs = DurableJobStore(database: reopened)
    let report = try #require(
      try await jobs.canaryRoleHostReplacementTerminalReport(
        request: fixture.replacementAuthorization.request
      )
    )
    #expect(report.status == shape.status)
    #expect(report.effectCertainty == shape.effectCertainty)
    #expect(report.failureCode == shape.failureCode)
    #expect(report.replayed)
    #expect(report.q4Binding == fixture.replacementAuthorization.q4Binding)
    #expect(
      report.replacementAuthorizationSHA256
        == fixture.replacementAuthorization.authorizationSHA256
    )
    await #expect(throws: DurableJobStoreError.canaryRecoveryRequired) {
      _ = try await jobs.canaryRoleHostReplacementState(
        request: fixture.replacementAuthorization.request
      )
    }
    #expect(
      try await reopened.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence >= 5",
        bindings: [.text(fixture.runID)]
      ) == 0
    )
    await reopened.close()
  }

  @Test(
    "replacement lifecycle permits every declared edge with one durable sequence",
    arguments: [
      [HerdrRoleHostState.running],
      [.stopping],
      [.lost],
      [.running, .waiting],
      [.running, .stopping],
      [.running, .lost],
      [.stopping, .stopped],
      [.stopping, .lost],
    ]
  )
  func replacementRoleHostLifecycleIsClosed(path: [HerdrRoleHostState]) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    for (index, state) in path.enumerated() {
      let instant = Date(timeIntervalSince1970: 23 + Double(index))
      let record = try await fixture.store.transitionReplacementRoleHost(
        id: fixture.replacementRoleHostID,
        to: state,
        now: instant
      )
      #expect(record.state == state)
      #expect(record.lifecycleSequence == index + 2)
      #expect(record.lastQueueSequence == 4)
      #expect(record.updatedAt == instant)
    }
  }

  @Test("replacement lifecycle, sequence, identity, and q5 mutations fail closed")
  func replacementRoleHostMutationAuthorityIsClosed() async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await fixture.prepareReplacement()
    let initial = try #require(
      try await fixture.store.replacementRoleHost(id: fixture.replacementRoleHostID)
    )
    let forbiddenUpdates = [
      "last_queue_sequence = 5",
      "lifecycle_sequence = lifecycle_sequence + 1",
      "updated_at = updated_at + 1",
      "state = 'running'",
      "state = 'running', lifecycle_sequence = lifecycle_sequence + 2, updated_at = updated_at + 1",
      "state = 'running', lifecycle_sequence = lifecycle_sequence + 1, updated_at = updated_at - 1",
      "created_at = created_at + 1",
      "pane_id = 'pane-forged-replacement'",
      "q4_descriptor_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_configuration_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_prompt_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_workflow_configuration_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_prior_launch_descriptor_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_prior_launch_configuration_sha256 = '\(String(repeating: "e", count: 64))'",
      "q4_resource_tree_sha256 = '\(String(repeating: "e", count: 64))'",
    ]
    for update in forbiddenUpdates {
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await fixture.database.execute(
          "UPDATE herdr_replacement_role_hosts SET \(update) WHERE id = ?",
          bindings: [.text(fixture.replacementRoleHostID)]
        )
      }
      #expect(
        try await fixture.store.replacementRoleHost(id: fixture.replacementRoleHostID)
          == initial
      )
    }
    await #expect(throws: PiRunStoreError.invalidTransition) {
      _ = try await fixture.store.transitionReplacementRoleHost(
        id: fixture.replacementRoleHostID,
        to: .running,
        now: Date(timeIntervalSince1970: 21)
      )
    }
    let eventsBefore = try await fixture.database.scalarInt(
      "SELECT COUNT(*) FROM pi_run_events WHERE run_id = ?",
      bindings: [.text(fixture.runID)]
    )
    let sessionID = "77777777-7777-4777-8777-777777777777"
    let boundarySHA256 = String(repeating: "8", count: 64)
    let deniedModes: [(PiRunLaunchMode, String?, String?)] = [
      (.fresh, nil, nil),
      (.sameRunResume, sessionID, nil),
      (.crossRunResume, sessionID, boundarySHA256),
    ]
    for (index, denied) in deniedModes.enumerated() {
      await #expect(throws: PiRunStoreError.invalidTransition) {
        _ = try await fixture.store.prepareLaunch(
          launchAttemptID: "launch-replacement-fifth-store-\(index)",
          runID: fixture.runID,
          roleHostID: fixture.predecessorRoleHostID,
          launchMode: denied.0,
          descriptorSHA256: String(repeating: "7", count: 64),
          expectedSessionID: denied.1,
          resumeBoundarySHA256: denied.2,
          now: Date(timeIntervalSince1970: 23)
        )
      }
      await #expect(throws: SQLiteStoreError.self) {
        _ = try await fixture.database.execute(
          """
          INSERT INTO pi_run_launches(
            launch_attempt_id, run_id, role_host_id, execution_role_host_id,
            queue_sequence, launch_mode, descriptor_sha256,
            expected_session_id, resume_boundary_sha256, state, failure_code,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, 5, ?, ?, ?, ?, 'prepared', NULL, 23, 23)
          """,
          bindings: [
            .text("launch-replacement-fifth-raw-\(index)"),
            .text(fixture.runID),
            .text(fixture.predecessorRoleHostID),
            .text(fixture.replacementRoleHostID),
            .text(denied.0.rawValue),
            .text(String(repeating: "7", count: 64)),
            denied.1.map(SQLiteValue.text) ?? .null,
            denied.2.map(SQLiteValue.text) ?? .null,
          ]
        )
      }
    }
    #expect(try await fixture.store.launches(runID: fixture.runID).count == 4)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_events WHERE run_id = ?",
        bindings: [.text(fixture.runID)]
      ) == eventsBefore
    )
  }

  @Test(
    "replacement cutover rolls back at every durable write",
    arguments: [0, 1, 2, 3, 4]
  )
  func replacementCutoverIsAtomicAtEveryWrite(fault: Int) async throws {
    let fixture = try await ReplacementCutoverFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.snapshot()
    _ = try await fixture.database.execute(fixture.cutoverFaultTrigger(fault))
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.prepareReplacement()
    }
    await fixture.database.close()

    let reopened = try SQLiteStore(databaseURL: fixture.databaseURL)
    let after = try await fixture.snapshot(database: reopened)
    #expect(after == before)
    #expect(try await reopened.query("PRAGMA foreign_key_check").isEmpty)
    await reopened.close()
  }
}

struct CrossTableHostCollisionCase: Sendable {
  let dimension: Int
  let state: String
}

private let ordinaryFirstRawCollisionCases: [CrossTableHostCollisionCase] =
  ["prepared", "waiting", "running", "stopping", "stopped", "lost"].map {
    CrossTableHostCollisionCase(dimension: 4, state: $0)
  }
  + [1, 2, 3].flatMap { dimension in
    ["waiting", "running", "stopping", "stopped", "lost"].map {
      CrossTableHostCollisionCase(dimension: dimension, state: $0)
    }
  }

private let replacementFirstRawCollisionCases: [CrossTableHostCollisionCase] =
  ["waiting", "running", "stopping", "stopped", "lost"].flatMap { state in
    [1, 2, 3, 4].map { dimension in
      CrossTableHostCollisionCase(dimension: dimension, state: state)
    }
  }

private let replacementFirstPhysicalCollisionCases =
  replacementFirstRawCollisionCases.filter { $0.dimension != 4 }

enum ReplacementTerminalShape: CaseIterable, Sendable {
  case noRemoteEffectFailure
  case remoteEffectAmbiguous
  case q4Prepared
  case q4Enqueued
  case q4OutcomeAmbiguous
  case q4Failed
  case q4Settled
  case replacementHostLost

  var status: JobCanaryRoleHostReplacementStatus {
    switch self {
    case .noRemoteEffectFailure: .noRemoteEffectFailure
    case .remoteEffectAmbiguous: .remoteEffectAmbiguous
    case .q4Prepared: .q4Prepared
    case .q4Enqueued: .q4Enqueued
    case .q4OutcomeAmbiguous: .q4OutcomeAmbiguous
    case .q4Failed: .q4Failed
    case .q4Settled: .q4Settled
    case .replacementHostLost: .replacementHostLost
    }
  }

  var effectCertainty: JobCanaryRoleHostReplacementEffectCertainty {
    switch self {
    case .noRemoteEffectFailure: .knownNoRemoteEffect
    case .remoteEffectAmbiguous: .possibleRemoteEffect
    case .q4Prepared, .q4Enqueued, .q4OutcomeAmbiguous, .q4Failed, .q4Settled,
      .replacementHostLost:
      .confirmedReplacementEffect
    }
  }

  var failureCode: String? {
    switch self {
    case .noRemoteEffectFailure: "INVALID_PREPARATION"
    case .q4OutcomeAmbiguous: "RUNTIME_INTERRUPTED"
    case .q4Failed: "CHILD_FAILED"
    default: nil
    }
  }
}

private struct ReplacementCutoverSnapshot: Equatable {
  let authorization: String?
  let predecessor: String?
  let intent: String?
  let run: String?
  let launches: String?
  let replacementCount: Int64?
  let replacementEventCount: Int64?
  let q4Count: Int64?
}

private struct ReplacementCutoverFixture {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let store: PiRunStore
  let jobID: UUID
  let runID: String
  let predecessorRoleHostID: String
  let replacementRoleHostID: String
  let replacementLaunchAttemptID: String
  let replacementBootstrapDescriptorSHA256: String
  let replacementAuthorization: JobCanaryRoleHostReplacementAuthorization
  let replacementIntent: HerdrTopologyMutationIntent
  let authority: HerdrReplacementLaunchAuthority

  static func make(
    collision: Int = 0,
    persistAuthorization: Bool = true,
    prepareIntent: Bool = true,
    sendIntentStarted: Bool = true
  ) async throws -> Self {
    let root = try makePrivateTemporaryDirectory(prefix: "pi-replacement-cutover")
    let databaseURL = root.appendingPathComponent("state.sqlite3")
    let database = try SQLiteStore(databaseURL: databaseURL)
    do {
      let repositoryID = UUID(uuidString: "32000000-0000-0000-0000-000000000003")!
      let jobID = UUID(uuidString: "42000000-0000-0000-0000-000000000004")!
      try await insertRepositoryAndJob(
        database: database,
        repositoryID: repositoryID,
        jobID: jobID,
        role: .architecture
      )
      let repository = repositoryID.uuidString.lowercased()
      let job = jobID.uuidString.lowercased()
      let hostDefinitions: [(PiWorkflowRole, String)] = [
        (.architecture, "rolehost-10000000-0000-4000-8000-000000000001"),
        (.security, "rolehost-20000000-0000-4000-8000-000000000002"),
        (.test, "rolehost-30000000-0000-4000-8000-000000000003"),
        (.synthesis, "rolehost-40000000-0000-4000-8000-000000000004"),
      ]
      let replacementHostID =
        collision == 1
        ? hostDefinitions[1].1
        : "rolehost-50000000-0000-4000-8000-000000000005"
      let replacementLaunchAttemptID = "launch-60000000-0000-4000-8000-000000000006"
      let replacementEvidenceSHA256 = String(repeating: "b", count: 64)
      let recoveryEvidenceSHA256 = String(repeating: "8", count: 64)
      let retryEvidenceSHA256 = String(repeating: "9", count: 64)
      let canary = JobCanaryAuthorization(
        scope: JobCanaryScope(
          jobID: jobID,
          boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
          repairEvidenceSHA256: String(repeating: "4", count: 64),
          maximumCommentParts: 8
        ),
        previewEvidenceSHA256: String(repeating: "5", count: 64)
      )
      let retryAuthorization = JobCanaryPiRetryAuthorization(
        recovery: JobCanaryRecoveryAuthorization(
          canary: canary,
          recoveryEvidenceSHA256: recoveryEvidenceSHA256
        ),
        retryEvidenceSHA256: retryEvidenceSHA256
      )
      let replacementAuthorization = JobCanaryRoleHostReplacementAuthorization(
        request: JobCanaryRoleHostReplacementRequest(
          retry: retryAuthorization,
          incidentAuditSHA256:
            JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
          plannedReplacementRoleHostID: replacementHostID,
          plannedLaunchAttemptID: replacementLaunchAttemptID
        ),
        replacementEvidenceSHA256: replacementEvidenceSHA256,
        q4Binding: replacementQ4Binding()
      )
      try replacementAuthorization.validate()
      _ = try await database.execute(
        "UPDATE jobs SET kind = 'prReview', current_step_kind = 'review', attempt = 3 WHERE id = ?",
        bindings: [.text(job)]
      )
      _ = try await database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
      _ = try await database.execute(
        "INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active) VALUES (?, ?, 1, 12, 1)",
        bindings: [.text(repository), .text(job)]
      )
      let canaryAuthorization = canary.authorizationSHA256
      let eventPrefix = "canary:\(canaryAuthorization):m8:"
      for (event, from, to, instant) in [
        (eventPrefix + "admit:" + job, "queued", "leased", 9.0),
        (
          eventPrefix + "topology-recovery:" + recoveryEvidenceSHA256,
          "reconciliationQueued", "reconciliationQueued", 10.0
        ),
        (
          eventPrefix + "topology-resume:" + recoveryEvidenceSHA256,
          "reconciliationQueued", "preparing", 12.0
        ),
        (
          eventPrefix + "topology-run-review:" + recoveryEvidenceSHA256,
          "preparing", "runningPi", 13.0
        ),
        (eventPrefix + "pi:architecture:r1", "runningPi", "runningPi", 14.0),
      ] {
        _ = try await database.execute(
          """
          INSERT INTO job_transitions(
            job_id, event_key, from_state, to_state, reason,
            attempt_before, attempt_after, step_before, step_after, created_at
          ) VALUES (?, ?, ?, ?, 'exact replacement fixture authority', 3, 3, 0, 0, ?)
          """,
          bindings: [
            .text(job), .text(event), .text(from), .text(to), .real(instant),
          ]
        )
      }
      _ = try await database.execute(
        """
        INSERT INTO artifacts(
          id, job_id, kind, relative_path, sha256,
          redaction_classification, producer_run_id, created_at
        ) VALUES (
          'artifact-replacement-input', ?, 'input', 'replacement/input.json', ?,
          'synthetic', NULL, 14
        )
        """,
        bindings: [.text(job), .text(String(repeating: "a", count: 64))]
      )

      let store = PiRunStore(database: database)
      let socket = handshake(workspaceID: "workspace-replacement")
      _ = try await store.bindRepository(
        repositoryID: repositoryID,
        workspaceID: "workspace-replacement",
        identityRoot: root,
        handshake: socket,
        now: Date(timeIntervalSince1970: 1)
      )
      _ = try await store.prepareJobBinding(
        jobID: jobID,
        repositoryID: repositoryID,
        generation: 1,
        workspaceID: "workspace-replacement",
        now: Date(timeIntervalSince1970: 2)
      )
      var activations: [HerdrRoleHostActivation] = []
      for (index, definition) in hostDefinitions.enumerated() {
        let (role, hostID) = definition
        _ = try await store.prepareRoleHost(
          id: hostID,
          jobID: jobID,
          generation: 1,
          role: role,
          workspaceID: "workspace-replacement",
          bootstrapDescriptorSHA256: String(
            repeating: Character(String(index + 1)),
            count: 64
          ),
          hostExecutableSHA256: String(repeating: "d", count: 64),
          now: Date(timeIntervalSince1970: 3)
        )
        activations.append(
          HerdrRoleHostActivation(
            roleHostID: hostID,
            workspaceID: "workspace-replacement",
            tabID: "tab-replacement",
            paneID: "pane-replacement-\(index + 1)",
            terminalID: "terminal-replacement-\(index + 1)",
            processIdentity: try HerdrHostProcessIdentity(
              processID: Int32(100 + index),
              startSeconds: UInt64(200 + index),
              startMicroseconds: UInt64(300 + index)
            )
          )
        )
      }
      try await store.activateTopology(
        jobID: jobID,
        tabID: "tab-replacement",
        hosts: activations,
        now: Date(timeIntervalSince1970: 4)
      )
      let run = try await store.prepareRun(
        id: "run-replacement-cutover",
        jobID: jobID,
        workflow: .pullRequestReview,
        role: .architecture,
        round: 1,
        jobAttempt: 3,
        topologyGeneration: 1,
        jobStep: 0,
        runNonce: String(repeating: "1", count: 64),
        requestSHA256: String(repeating: "2", count: 64),
        resourceVersion: "1",
        resourceHash: String(repeating: "3", count: 64),
        model: "fixture/model:max",
        sessionPath: root.appendingPathComponent("session"),
        channelPath: root.appendingPathComponent("channel"),
        now: Date(timeIntervalSince1970: 5)
      )
      let predecessorID = hostDefinitions[0].1
      func authorize(
        _ launch: PiRunLaunchRecord,
        suffix: Character,
        at instant: Double
      ) async throws {
        _ = try await database.execute(
          """
          INSERT INTO job_transitions(
            job_id, event_key, from_state, to_state, reason,
            attempt_before, attempt_after, step_before, step_after, created_at
          ) VALUES (?, ?, 'runningPi', 'runningPi', 'exact retry authority',
            3, 3, 0, 0, ?)
          """,
          bindings: [
            .text(job),
            .text(
              eventPrefix + "pi-fresh-retry:" + run.id + ":"
                + launch.launchAttemptID + ":" + String(repeating: suffix, count: 64)
            ),
            .real(instant),
          ]
        )
      }
      let first = try await store.prepareLaunch(
        launchAttemptID: "launch-replacement-first",
        runID: run.id,
        roleHostID: predecessorID,
        launchMode: .fresh,
        descriptorSHA256: String(repeating: "4", count: 64),
        expectedSessionID: nil,
        resumeBoundarySHA256: nil,
        now: Date(timeIntervalSince1970: 6)
      )
      _ = try await store.transitionLaunch(
        launchAttemptID: first.launchAttemptID,
        to: .enqueued,
        event: .enqueued,
        now: Date(timeIntervalSince1970: 7)
      )
      _ = try await store.transitionLaunch(
        launchAttemptID: first.launchAttemptID,
        to: .running,
        event: .running,
        now: Date(timeIntervalSince1970: 8)
      )
      _ = try await store.recordChildProcess(
        launchAttemptID: first.launchAttemptID,
        record: HerdrChildProcessRecord(
          launchAttemptID: first.launchAttemptID,
          processID: 999_991,
          processGroupID: 999_991,
          startSeconds: 9,
          startMicroseconds: 1
        ),
        now: Date(timeIntervalSince1970: 9)
      )
      _ = try await store.transitionLaunch(
        launchAttemptID: first.launchAttemptID,
        to: .failed,
        event: .failed,
        detailCode: "RUNTIME_TIMEOUT",
        now: Date(timeIntervalSince1970: 10)
      )
      try await authorize(first, suffix: "5", at: 11)

      let second = try await store.prepareLaunch(
        launchAttemptID: "launch-replacement-second",
        runID: run.id,
        roleHostID: predecessorID,
        launchMode: .fresh,
        descriptorSHA256: String(repeating: "5", count: 64),
        expectedSessionID: nil,
        resumeBoundarySHA256: nil,
        now: Date(timeIntervalSince1970: 12)
      )
      for (state, event, instant): (PiRunLaunchState, PiRunEventKind, Double) in [
        (.enqueued, .enqueued, 13), (.running, .running, 14), (.failed, .failed, 15),
      ] {
        _ = try await store.transitionLaunch(
          launchAttemptID: second.launchAttemptID,
          to: state,
          event: event,
          detailCode: state == .failed ? "HERDR_TRANSACTION_FAILED" : nil,
          now: Date(timeIntervalSince1970: instant)
        )
      }
      try await authorize(second, suffix: "6", at: 16)

      let third = try await store.prepareLaunch(
        launchAttemptID: "launch-replacement-third",
        runID: run.id,
        roleHostID: predecessorID,
        launchMode: .fresh,
        descriptorSHA256: String(repeating: "6", count: 64),
        expectedSessionID: nil,
        resumeBoundarySHA256: nil,
        now: Date(timeIntervalSince1970: 17)
      )
      for (state, event, instant): (PiRunLaunchState, PiRunEventKind, Double) in [
        (.enqueued, .enqueued, 18), (.running, .running, 19), (.failed, .failed, 20),
      ] {
        _ = try await store.transitionLaunch(
          launchAttemptID: third.launchAttemptID,
          to: state,
          event: event,
          detailCode: state == .failed ? "HERDR_TRANSACTION_FAILED" : nil,
          now: Date(timeIntervalSince1970: instant)
        )
      }
      try await authorize(third, suffix: "7", at: 21)

      let predecessor = try #require(
        try await store.roleHosts(jobID: jobID).first(where: { $0.id == predecessorID })
      )
      let predecessorIdentity = try #require(predecessor.processIdentity)
      let intentStore = SQLiteHerdrTopologyIntentStore(
        database: database,
        now: { Date(timeIntervalSince1970: 21) }
      )
      let failedPrimePayloadSHA256 = String(repeating: "e", count: 64)
      let failedPrimeIntent = HerdrTopologyMutationIntent(
        mutationID: "prime-00000000-0000-4000-8000-000000000013",
        kind: .primeAgentAuthority,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: failedPrimePayloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
      )
      let failedPrimeReceipt = try await intentStore.prepare(failedPrimeIntent)
      try await intentStore.markSendStarted(failedPrimeReceipt)
      try await intentStore.markUnknown(failedPrimeReceipt)
      try await authorize(third, suffix: "9", at: 21.25)

      let resetTokens = [
        "managed_by": "jidoka", "repository_id": repository, "job_id": job,
        "generation": "1", "role": "architecture", "run_id": run.id,
        "launch_attempt_id": "launch-reset-terminal-unknown", "summary": "running",
      ]
      let resetPayload = HerdrAgentAuthorityPrimePayload(
        schemaVersion: 2,
        canaryAuthorizationSHA256: canaryAuthorization,
        maximumCommentParts: 8,
        recoveryEvidenceSHA256: String(repeating: "8", count: 64),
        retryEvidenceSHA256: String(repeating: "9", count: 64),
        repositoryID: repository,
        jobID: job,
        generation: 1,
        runID: run.id,
        failedLaunchAttemptID: third.launchAttemptID,
        plannedLaunchAttemptID: "launch-reset-terminal-unknown",
        roleHostID: predecessor.id,
        queueSequence: 4,
        hostProcessID: predecessorIdentity.processID,
        hostStartSeconds: predecessorIdentity.startSeconds,
        hostStartMicroseconds: predecessorIdentity.startMicroseconds,
        hostExecutableSHA256: predecessor.hostExecutableSHA256,
        workspaceID: predecessor.workspaceID,
        tabID: try #require(predecessor.tabID),
        paneID: try #require(predecessor.paneID),
        terminalID: try #require(predecessor.terminalID),
        agentSource: "jidoka:host",
        metadataSource: "jidoka:coordination",
        alias: "jc-prime-architecture-q4",
        reportSequence: 7,
        tokens: resetTokens,
        failedPrimeIntentID: failedPrimeIntent.mutationID,
        failedPrimeIntentSHA256: failedPrimeReceipt.intentSHA256,
        failedPrimePayloadSHA256: failedPrimePayloadSHA256,
        stalePaneRevision: 3,
        stalePaneHadTokens: true,
        stalePaneTokensSHA256: String(repeating: "f", count: 64)
      )
      let resetIntent = HerdrTopologyMutationIntent(
        mutationID: "reset-00000000-0000-4000-8000-000000000014",
        kind: .resetAgentAuthority,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: resetPayload.payloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
      )
      let resetReceipt = try await intentStore.prepare(resetIntent)
      try await intentStore.markSendStarted(resetReceipt)
      try await intentStore.markUnknown(resetReceipt)
      guard
        try await database.scalarInt(
          "SELECT COUNT(*) FROM herdr_role_host_replacement_candidates WHERE run_id = ?",
          bindings: [.text(run.id)]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }

      let anchorID = hostDefinitions[1].1
      var replacementPaneID = "pane-fresh-architecture"
      var replacementTerminalID = "terminal-fresh-architecture"
      var replacementProcessIdentity = try HerdrHostProcessIdentity(
        processID: 777,
        startSeconds: 888,
        startMicroseconds: 999
      )
      switch collision {
      case 0:
        break
      case 1:
        break
      case 2:
        replacementPaneID = "pane-replacement-1"
      case 3:
        replacementPaneID = "pane-replacement-2"
      case 4:
        replacementTerminalID = "terminal-replacement-1"
      case 5:
        replacementTerminalID = "terminal-replacement-2"
      case 6:
        replacementProcessIdentity = activations[0].processIdentity
      case 7:
        replacementProcessIdentity = activations[1].processIdentity
      case 8:
        replacementPaneID = "pane-replacement-3"
      case 9:
        replacementTerminalID = "terminal-replacement-4"
      case 10:
        replacementProcessIdentity = activations[2].processIdentity
      default:
        throw PiRunStoreError.invalidRecord
      }
      let replacementBootstrapDescriptorSHA256 = String(repeating: "c", count: 64)
      let incidentAuditSHA256 = JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256
      let credentialEvidenceSHA256 = String(repeating: "d", count: 64)
      let replacementTokens = [
        "managed_by": "jidoka", "repository_id": repository, "job_id": job,
        "generation": "1", "role": "architecture", "run_id": run.id,
        "launch_attempt_id": replacementLaunchAttemptID, "summary": "running",
      ]
      let replacementPayload = HerdrRoleHostReplacementPayload(
        schemaVersion: 2,
        canaryAuthorizationSHA256: canaryAuthorization,
        maximumCommentParts: 8,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        retryEvidenceSHA256: retryEvidenceSHA256,
        replacementEvidenceSHA256: replacementEvidenceSHA256,
        replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
        incidentAuditSHA256: incidentAuditSHA256,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        runID: run.id,
        failedLaunchAttemptID: third.launchAttemptID,
        plannedLaunchAttemptID: replacementLaunchAttemptID,
        predecessorRoleHostID: predecessor.id,
        predecessorProcessID: predecessorIdentity.processID,
        predecessorStartSeconds: predecessorIdentity.startSeconds,
        predecessorStartMicroseconds: predecessorIdentity.startMicroseconds,
        predecessorBootstrapDescriptorSHA256: predecessor.bootstrapDescriptorSHA256,
        hostExecutableSHA256: predecessor.hostExecutableSHA256,
        hostExecutableDevice: 1,
        hostExecutableInode: 2,
        workspaceID: predecessor.workspaceID,
        tabID: try #require(predecessor.tabID),
        predecessorPaneID: try #require(predecessor.paneID),
        predecessorTerminalID: try #require(predecessor.terminalID),
        replacementRoleHostID: replacementHostID,
        replacementBootstrapDescriptorSHA256: replacementBootstrapDescriptorSHA256,
        credentialEvidenceSHA256: credentialEvidenceSHA256,
        q4Binding: replacementAuthorization.q4Binding,
        anchorRoleHostID: anchorID,
        anchorPaneID: "pane-replacement-2",
        anchorTerminalID: "terminal-replacement-2",
        queueSequence: 4,
        agentSource: "jidoka:replacement-host",
        metadataSource: "jidoka:replacement-coordination",
        alias: "jc-prime-architecture-q4",
        reportSequence: 1,
        tokens: replacementTokens
      )
      if persistAuthorization {
        let authorizationWasReplayed = try await store.persistRoleHostReplacementAuthorization(
          replacementAuthorization,
          payload: replacementPayload,
          now: Date(timeIntervalSince1970: 21.5)
        )
        #expect(!authorizationWasReplayed)
        #expect(
          try await store.persistRoleHostReplacementAuthorization(
            replacementAuthorization,
            payload: replacementPayload,
            now: Date(timeIntervalSince1970: 21.75)
          )
        )
      }
      #expect(
        try await database.scalarInt(
          "SELECT COUNT(*) FROM herdr_role_host_replacement_authorizations"
        ) == (persistAuthorization ? 1 : 0)
      )
      #expect(
        try await database.scalarInt(
          "SELECT COUNT(*) FROM herdr_topology_intents WHERE kind = 'replaceRoleHost'"
        ) == 0
      )
      #expect(
        try await database.scalarInt("SELECT COUNT(*) FROM herdr_replacement_role_hosts") == 0
      )
      #expect(
        try await database.scalarInt(
          "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
          bindings: [.text(run.id)]
        ) == 0
      )
      let replacementIntent = HerdrTopologyMutationIntent(
        mutationID: "replace-00000000-0000-4000-8000-000000000015",
        kind: .replaceRoleHost,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: try replacementPayload.payloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(socket.socketIdentity)
      )
      let replacementReceipt: HerdrTopologyMutationReceipt
      if prepareIntent {
        guard persistAuthorization else { throw PiRunStoreError.invalidTransition }
        replacementReceipt = try await intentStore.prepare(replacementIntent)
        if sendIntentStarted {
          try await intentStore.markSendStarted(replacementReceipt)
        }
      } else {
        replacementReceipt = HerdrTopologyMutationReceipt(
          mutationID: replacementIntent.mutationID,
          intentSHA256: String(repeating: "0", count: 64)
        )
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let replacementAttribution = try HerdrRoleHostReplacementAttribution(
        predecessorRoleHostID: predecessor.id,
        replacementRoleHostID: replacementHostID,
        workspaceID: predecessor.workspaceID,
        tabID: try #require(predecessor.tabID),
        paneID: replacementPaneID,
        terminalID: replacementTerminalID,
        processIdentity: replacementProcessIdentity,
        executableIdentity: try HerdrProcessExecutableIdentity(
          path: "/usr/bin/true",
          device: 1,
          inode: 2
        ),
        hostExecutableSHA256: predecessor.hostExecutableSHA256,
        alias: replacementPayload.alias,
        paneRevision: 1,
        agentStateChangeSequence: 1,
        tokensSHA256: GitHubMarkerCodec.sha256(try encoder.encode(replacementTokens)),
        incidentAuditSHA256: incidentAuditSHA256,
        replacementEvidenceSHA256: replacementEvidenceSHA256,
        replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
        credentialEvidenceSHA256: credentialEvidenceSHA256,
        q4Binding: replacementAuthorization.q4Binding
      )
      return Self(
        root: root,
        databaseURL: databaseURL,
        database: database,
        store: store,
        jobID: jobID,
        runID: run.id,
        predecessorRoleHostID: predecessor.id,
        replacementRoleHostID: replacementHostID,
        replacementLaunchAttemptID: replacementLaunchAttemptID,
        replacementBootstrapDescriptorSHA256: replacementBootstrapDescriptorSHA256,
        replacementAuthorization: replacementAuthorization,
        replacementIntent: replacementIntent,
        authority: HerdrReplacementLaunchAuthority(
          receipt: replacementReceipt,
          payload: replacementPayload,
          attribution: replacementAttribution
        )
      )
    } catch {
      await database.close()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  func prepareReplacement() async throws -> PiRunLaunchRecord {
    try await store.prepareReplacementFreshLaunch(
      launchAttemptID: replacementLaunchAttemptID,
      runID: runID,
      predecessorRoleHostID: predecessorRoleHostID,
      replacementRoleHostID: replacementRoleHostID,
      descriptorSHA256: String(repeating: "f", count: 64),
      bootstrapDescriptorSHA256: replacementBootstrapDescriptorSHA256,
      authority: authority,
      now: Date(timeIntervalSince1970: 22)
    )
  }

  func transitionReplacement(to state: String) async throws {
    switch state {
    case "waiting":
      return
    case "running", "stopping", "lost":
      guard let value = HerdrRoleHostState(rawValue: state) else {
        throw PiRunStoreError.invalidRecord
      }
      _ = try await store.transitionReplacementRoleHost(
        id: replacementRoleHostID,
        to: value,
        now: Date(timeIntervalSince1970: 23)
      )
    case "stopped":
      _ = try await store.transitionReplacementRoleHost(
        id: replacementRoleHostID,
        to: .stopping,
        now: Date(timeIntervalSince1970: 23)
      )
      _ = try await store.transitionReplacementRoleHost(
        id: replacementRoleHostID,
        to: .stopped,
        now: Date(timeIntervalSince1970: 24)
      )
    default:
      throw PiRunStoreError.invalidRecord
    }
  }

  func replacementPayload(
    q4Binding: JobCanaryRoleHostReplacementQ4Binding,
    replacementAuthorizationSHA256: String? = nil
  ) -> HerdrRoleHostReplacementPayload {
    let payload = authority.payload
    return HerdrRoleHostReplacementPayload(
      schemaVersion: payload.schemaVersion,
      canaryAuthorizationSHA256: payload.canaryAuthorizationSHA256,
      maximumCommentParts: payload.maximumCommentParts,
      recoveryEvidenceSHA256: payload.recoveryEvidenceSHA256,
      retryEvidenceSHA256: payload.retryEvidenceSHA256,
      replacementEvidenceSHA256: payload.replacementEvidenceSHA256,
      replacementAuthorizationSHA256: replacementAuthorizationSHA256
        ?? payload.replacementAuthorizationSHA256,
      incidentAuditSHA256: payload.incidentAuditSHA256,
      repositoryID: payload.repositoryID,
      jobID: payload.jobID,
      generation: payload.generation,
      runID: payload.runID,
      failedLaunchAttemptID: payload.failedLaunchAttemptID,
      plannedLaunchAttemptID: payload.plannedLaunchAttemptID,
      predecessorRoleHostID: payload.predecessorRoleHostID,
      predecessorProcessID: payload.predecessorProcessID,
      predecessorStartSeconds: payload.predecessorStartSeconds,
      predecessorStartMicroseconds: payload.predecessorStartMicroseconds,
      predecessorBootstrapDescriptorSHA256: payload.predecessorBootstrapDescriptorSHA256,
      hostExecutableSHA256: payload.hostExecutableSHA256,
      hostExecutableDevice: payload.hostExecutableDevice,
      hostExecutableInode: payload.hostExecutableInode,
      workspaceID: payload.workspaceID,
      tabID: payload.tabID,
      predecessorPaneID: payload.predecessorPaneID,
      predecessorTerminalID: payload.predecessorTerminalID,
      replacementRoleHostID: payload.replacementRoleHostID,
      replacementBootstrapDescriptorSHA256: payload.replacementBootstrapDescriptorSHA256,
      credentialEvidenceSHA256: payload.credentialEvidenceSHA256,
      q4Binding: q4Binding,
      anchorRoleHostID: payload.anchorRoleHostID,
      anchorPaneID: payload.anchorPaneID,
      anchorTerminalID: payload.anchorTerminalID,
      queueSequence: payload.queueSequence,
      agentSource: payload.agentSource,
      metadataSource: payload.metadataSource,
      alias: payload.alias,
      reportSequence: payload.reportSequence,
      tokens: payload.tokens
    )
  }

  func insertRawReplacementAuthorization(
    authorizationSHA256: String
  ) async throws {
    let request = replacementAuthorization.request
    let payload = authority.payload
    _ = try await database.execute(
      """
      INSERT INTO herdr_role_host_replacement_authorizations(
        replacement_authorization_sha256, payload_sha256,
        replacement_evidence_sha256, incident_audit_sha256,
        canary_authorization_sha256, recovery_evidence_sha256,
        retry_evidence_sha256, repository_id, job_id, generation, run_id,
        failed_launch_attempt_id, predecessor_role_host_id,
        planned_replacement_role_host_id, planned_launch_attempt_id,
        stale_pane_revision, stale_pane_had_tokens, stale_pane_tokens_sha256,
        q4_descriptor_sha256, q4_configuration_sha256, q4_prompt_sha256,
        q4_workflow_configuration_sha256, q4_prior_launch_descriptor_sha256,
        q4_prior_launch_configuration_sha256, q4_resource_tree_sha256,
        replacement_bootstrap_descriptor_sha256, host_executable_sha256,
        credential_evidence_sha256, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 22)
      """,
      bindings: [
        .text(authorizationSHA256),
        .text(try payload.payloadSHA256),
        .text(replacementAuthorization.replacementEvidenceSHA256),
        .text(request.incidentAuditSHA256),
        .text(request.retry.recovery.canary.authorizationSHA256),
        .text(request.retry.recovery.recoveryEvidenceSHA256),
        .text(request.retry.retryEvidenceSHA256),
        .text(payload.repositoryID),
        .text(payload.jobID),
        .integer(Int64(payload.generation)),
        .text(payload.runID),
        .text(payload.failedLaunchAttemptID),
        .text(payload.predecessorRoleHostID),
        .text(request.plannedReplacementRoleHostID),
        .text(request.plannedLaunchAttemptID),
        .integer(Int64(request.stalePaneRevision)),
        .integer(request.stalePaneHadTokens ? 1 : 0),
        .text(request.stalePaneTokensSHA256),
        .text(payload.q4Binding.descriptorSHA256),
        .text(payload.q4Binding.configurationSHA256),
        .text(payload.q4Binding.promptSHA256),
        .text(payload.q4Binding.workflowConfigurationSHA256),
        .text(payload.q4Binding.priorLaunchDescriptorSHA256),
        .text(payload.q4Binding.priorLaunchConfigurationSHA256),
        .text(payload.q4Binding.resourceTreeSHA256),
        .text(payload.replacementBootstrapDescriptorSHA256),
        .text(payload.hostExecutableSHA256),
        .text(payload.credentialEvidenceSHA256),
      ]
    )
  }

  func insertUnrelatedOrdinaryHost(
    collidingOn collision: Int,
    state: String = "waiting",
    raw: Bool = false
  ) async throws -> String {
    let repositoryID = UUID(uuidString: "33000000-0000-0000-0000-000000000003")!
    let unrelatedJobID = UUID(uuidString: "43000000-0000-0000-0000-000000000004")!
    let workspaceID = "workspace-unrelated"
    let roleHostID =
      collision == 4 ? replacementRoleHostID : "rolehost-unrelated-ordinary"
    try await insertRepositoryAndJob(
      database: database,
      repositoryID: repositoryID,
      jobID: unrelatedJobID,
      role: .security,
      repositoryName: "repository-unrelated"
    )
    _ = try await store.bindRepository(
      repositoryID: repositoryID,
      workspaceID: workspaceID,
      identityRoot: root,
      handshake: handshake(workspaceID: workspaceID, inode: 30),
      now: Date(timeIntervalSince1970: 22)
    )
    _ = try await store.prepareJobBinding(
      jobID: unrelatedJobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: workspaceID,
      now: Date(timeIntervalSince1970: 22)
    )
    var paneID = "pane-unrelated-ordinary"
    var terminalID = "terminal-unrelated-ordinary"
    var processIdentity = try HerdrHostProcessIdentity(
      processID: 778,
      startSeconds: 889,
      startMicroseconds: 998
    )
    switch collision {
    case 0:
      break
    case 1:
      paneID = authority.attribution.paneID
    case 2:
      terminalID = authority.attribution.terminalID
    case 3:
      processIdentity = try HerdrHostProcessIdentity(
        processID: authority.attribution.processID,
        startSeconds: authority.attribution.startSeconds,
        startMicroseconds: authority.attribution.startMicroseconds
      )
    case 4:
      break
    default:
      throw PiRunStoreError.invalidRecord
    }
    if raw {
      let physical = state != "prepared"
      let selectedPaneID = paneID
      let selectedTerminalID = terminalID
      let selectedProcessIdentity = processIdentity
      _ = try await database.transaction { database in
        _ = try database.execute(
          "UPDATE herdr_job_bindings SET updated_at = 23 WHERE job_id = ?",
          bindings: [.text(unrelatedJobID.uuidString.lowercased())]
        )
        return try database.execute(
          """
          INSERT INTO herdr_role_hosts(
            id, job_id, generation, role, workspace_id, tab_id, pane_id, terminal_id,
            bootstrap_descriptor_sha256, host_executable_sha256,
            host_pid, host_start_seconds, host_start_microseconds,
            last_queue_sequence, lifecycle_sequence, state, created_at, updated_at
          ) VALUES (?, ?, 1, 'security', ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 22, 22)
          """,
          bindings: [
            .text(roleHostID),
            .text(unrelatedJobID.uuidString.lowercased()),
            .text(workspaceID),
            physical ? .text("tab-unrelated") : .null,
            physical ? .text(selectedPaneID) : .null,
            physical ? .text(selectedTerminalID) : .null,
            .text(String(repeating: "a", count: 64)),
            .text(String(repeating: "b", count: 64)),
            physical ? .integer(Int64(selectedProcessIdentity.processID)) : .null,
            physical ? .integer(Int64(selectedProcessIdentity.startSeconds)) : .null,
            physical ? .integer(Int64(selectedProcessIdentity.startMicroseconds)) : .null,
            .integer(physical ? 1 : 0),
            .text(state),
          ]
        )
      }
      return roleHostID
    }
    _ = try await store.prepareRoleHost(
      id: roleHostID,
      jobID: unrelatedJobID,
      generation: 1,
      role: .security,
      workspaceID: workspaceID,
      bootstrapDescriptorSHA256: String(repeating: "a", count: 64),
      hostExecutableSHA256: String(repeating: "b", count: 64),
      now: Date(timeIntervalSince1970: 22)
    )
    guard state != "prepared" else { return roleHostID }
    try await store.activateTopology(
      jobID: unrelatedJobID,
      tabID: "tab-unrelated",
      hosts: [
        HerdrRoleHostActivation(
          roleHostID: roleHostID,
          workspaceID: workspaceID,
          tabID: "tab-unrelated",
          paneID: paneID,
          terminalID: terminalID,
          processIdentity: processIdentity
        )
      ],
      now: Date(timeIntervalSince1970: 22)
    )
    if state != "waiting" {
      _ = try await database.execute(
        "UPDATE herdr_role_hosts SET state = ? WHERE id = ?",
        bindings: [.text(state), .text(roleHostID)]
      )
    }
    return roleHostID
  }

  func insertRawReplacementRoleHost(
    id: String? = nil,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding? = nil
  ) async throws {
    let q4Binding = q4Binding ?? authority.payload.q4Binding
    _ = try await database.execute(
      """
      INSERT INTO herdr_replacement_role_hosts(
        id, predecessor_role_host_id, replacement_intent_id, job_id, generation, role,
        workspace_id, tab_id, pane_id, terminal_id, bootstrap_descriptor_sha256,
        host_executable_sha256, q4_descriptor_sha256, q4_configuration_sha256,
        q4_prompt_sha256, q4_workflow_configuration_sha256,
        q4_prior_launch_descriptor_sha256, q4_prior_launch_configuration_sha256,
        q4_resource_tree_sha256, host_pid, host_start_seconds, host_start_microseconds,
        last_queue_sequence, lifecycle_sequence, state, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 1, 'architecture', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 4, 1,
        'waiting', 22, 22)
      """,
      bindings: [
        .text(id ?? replacementRoleHostID),
        .text(predecessorRoleHostID),
        .text(authority.receipt.mutationID),
        .text(jobID.uuidString.lowercased()),
        .text(authority.attribution.workspaceID),
        .text(authority.attribution.tabID),
        .text(authority.attribution.paneID),
        .text(authority.attribution.terminalID),
        .text(replacementBootstrapDescriptorSHA256),
        .text(authority.attribution.hostExecutableSHA256),
        .text(q4Binding.descriptorSHA256),
        .text(q4Binding.configurationSHA256),
        .text(q4Binding.promptSHA256),
        .text(q4Binding.workflowConfigurationSHA256),
        .text(q4Binding.priorLaunchDescriptorSHA256),
        .text(q4Binding.priorLaunchConfigurationSHA256),
        .text(q4Binding.resourceTreeSHA256),
        .integer(Int64(authority.attribution.processID)),
        .integer(Int64(authority.attribution.startSeconds)),
        .integer(Int64(authority.attribution.startMicroseconds)),
      ]
    )
  }

  func replacementAttributionJSON(
    replacementAuthorizationSHA256: String? = nil,
    replacementEvidenceSHA256: String? = nil,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding? = nil
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(authority.attribution)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw PiRunStoreError.invalidRecord
    }
    if let replacementAuthorizationSHA256 {
      object["replacementAuthorizationSHA256"] = replacementAuthorizationSHA256
    }
    if let replacementEvidenceSHA256 {
      object["replacementEvidenceSHA256"] = replacementEvidenceSHA256
    }
    if let q4Binding {
      object["q4Binding"] = try JSONSerialization.jsonObject(
        with: encoder.encode(q4Binding)
      )
    }
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    guard let value = String(data: data, encoding: .utf8) else {
      throw PiRunStoreError.invalidRecord
    }
    return value
  }

  func stopRawPredecessor() async throws {
    _ = try await database.execute(
      """
      UPDATE herdr_role_hosts
      SET state = 'stopped', lifecycle_sequence = lifecycle_sequence + 1, updated_at = 22
      WHERE id = ? AND state = 'waiting' AND last_queue_sequence = 3
      """,
      bindings: [.text(predecessorRoleHostID)]
    )
  }

  func attributeRawReplacement(_ attributionJSON: String) async throws {
    _ = try await database.execute(
      """
      UPDATE herdr_topology_intents
      SET state = 'attributed', attribution_json = ?, updated_at = 22
      WHERE id = ? AND state = 'sendStarted'
      """,
      bindings: [.text(attributionJSON), .text(authority.receipt.mutationID)]
    )
  }

  func replacementEventKey(driftingField field: Int? = nil) throws -> String {
    let payload = authority.payload
    var prefix = "canary:"
    var canary = payload.canaryAuthorizationSHA256
    var maximumCommentParts = "m8"
    var run = runID
    var failedLaunch = payload.failedLaunchAttemptID
    var plannedLaunch = replacementLaunchAttemptID
    var predecessor = predecessorRoleHostID
    var replacement = replacementRoleHostID
    var payloadSHA256 = try payload.payloadSHA256
    var suffix = ""
    switch field {
    case nil:
      break
    case 0:
      prefix = "forged:"
    case 1:
      canary = String(repeating: "0", count: 64)
    case 2:
      suffix = ":forged"
    case 3:
      maximumCommentParts = "m7"
    case 4:
      run = "run-forged-replacement"
    case 5:
      failedLaunch = "launch-forged-q3"
    case 6:
      plannedLaunch = "launch-forged-q4"
    case 7:
      predecessor = "rolehost-forged-predecessor"
    case 8:
      replacement = "rolehost-forged-replacement"
    case 9:
      payloadSHA256 = String(repeating: "0", count: 64)
    default:
      throw PiRunStoreError.invalidRecord
    }
    return prefix + canary + ":" + maximumCommentParts + ":pi-role-host-replacement:"
      + "\(run):\(failedLaunch):\(plannedLaunch):\(predecessor):\(replacement):"
      + payloadSHA256 + suffix
  }

  func insertRawReplacementEvent(driftingField field: Int? = nil) async throws {
    let eventKey = try replacementEventKey(driftingField: field)
    _ = try await database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (?, ?, 'runningPi', 'runningPi', 'raw exact replacement fixture',
        3, 3, 0, 0, 22)
      """,
      bindings: [.text(jobID.uuidString.lowercased()), .text(eventKey)]
    )
  }

  func insertRawQ4(
    launchAttemptID: String,
    descriptorSHA256: String = String(repeating: "f", count: 64)
  ) async throws {
    _ = try await database.execute(
      """
      INSERT INTO pi_run_launches(
        launch_attempt_id, run_id, role_host_id, execution_role_host_id,
        queue_sequence, launch_mode, descriptor_sha256, expected_session_id,
        resume_boundary_sha256, state, failure_code, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 4, 'fresh', ?, NULL, NULL, 'prepared', NULL, 22, 22)
      """,
      bindings: [
        .text(launchAttemptID),
        .text(runID),
        .text(predecessorRoleHostID),
        .text(replacementRoleHostID),
        .text(descriptorSHA256),
      ]
    )
  }

  func snapshot(database alternate: SQLiteStore? = nil) async throws
    -> ReplacementCutoverSnapshot
  {
    let database = alternate ?? database
    return try await ReplacementCutoverSnapshot(
      authorization: database.scalarText(
        """
        SELECT replacement_authorization_sha256 || ':' || payload_sha256 || ':' ||
          replacement_evidence_sha256 || ':' || planned_replacement_role_host_id || ':' ||
          planned_launch_attempt_id || ':' || created_at
        FROM herdr_role_host_replacement_authorizations WHERE job_id = ?
        """,
        bindings: [.text(jobID.uuidString.lowercased())]
      ),
      predecessor: database.scalarText(
        """
        SELECT state || ':' || lifecycle_sequence || ':' || last_queue_sequence || ':'
          || created_at || ':' || updated_at
        FROM herdr_role_hosts WHERE id = ?
        """,
        bindings: [.text(predecessorRoleHostID)]
      ),
      intent: database.scalarText(
        """
        SELECT state || ':' || COALESCE(attribution_json, '<null>') || ':' || updated_at
        FROM herdr_topology_intents WHERE id = ?
        """,
        bindings: [.text(authority.receipt.mutationID)]
      ),
      run: database.scalarText(
        "SELECT outcome || ':' || settled || ':' || updated_at FROM pi_runs WHERE id = ?",
        bindings: [.text(runID)]
      ),
      launches: database.scalarText(
        """
        SELECT group_concat(value, '|') FROM (
          SELECT launch_attempt_id || ':' || queue_sequence || ':' || state || ':'
            || descriptor_sha256 AS value
          FROM pi_run_launches WHERE run_id = ?
          ORDER BY queue_sequence
        )
        """,
        bindings: [.text(runID)]
      ),
      replacementCount: database.scalarInt(
        "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ?",
        bindings: [.text(jobID.uuidString.lowercased())]
      ),
      replacementEventCount: database.scalarInt(
        """
        SELECT COUNT(*) FROM job_transitions
        WHERE job_id = ? AND event_key GLOB 'canary:*:pi-role-host-replacement:*'
        """,
        bindings: [.text(jobID.uuidString.lowercased())]
      ),
      q4Count: database.scalarInt(
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence = 4",
        bindings: [.text(runID)]
      )
    )
  }

  func cutoverFaultTrigger(_ fault: Int) -> String {
    let action: String
    switch fault {
    case 0:
      action = "BEFORE INSERT ON herdr_replacement_role_hosts"
    case 1:
      action =
        "BEFORE UPDATE ON herdr_role_hosts WHEN OLD.id = '\(predecessorRoleHostID)'"
    case 2:
      action =
        "BEFORE UPDATE ON herdr_topology_intents WHEN OLD.id = '\(authority.receipt.mutationID)'"
    case 3:
      action =
        "BEFORE INSERT ON job_transitions WHEN NEW.event_key GLOB 'canary:*:pi-role-host-replacement:*'"
    case 4:
      action = "BEFORE INSERT ON pi_run_launches WHEN NEW.queue_sequence = 4"
    default:
      preconditionFailure("unknown replacement cutover fault")
    }
    return """
      CREATE TRIGGER injected_replacement_cutover_failure
      \(action)
      BEGIN
        SELECT RAISE(ABORT, 'injected replacement cutover failure');
      END
      """
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
  role: PiWorkflowRole = .triage,
  repositoryName: String = "repository"
) async throws {
  _ = try await database.execute(
    """
    INSERT INTO repositories(
      id, node_id, owner, name, default_branch,
      review_enabled, triage_enabled, implementation_enabled, enabled,
      created_at, updated_at
    ) VALUES (?, ?, 'owner', ?, 'main', 1, 1, 1, 1, 1, 1)
    """,
    bindings: [
      .text(repositoryID.uuidString.lowercased()),
      .text("node-\(repositoryID.uuidString.lowercased())"),
      .text(repositoryName),
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

private func replacementQ4BindingValues() -> [String] {
  ["f", "1", "2", "3", "4", "5", "6"].map {
    String(repeating: $0, count: 64)
  }
}

private func replacementQ4Binding(
  values: [String]
) -> JobCanaryRoleHostReplacementQ4Binding {
  JobCanaryRoleHostReplacementQ4Binding(
    descriptorSHA256: values[0],
    configurationSHA256: values[1],
    promptSHA256: values[2],
    workflowConfigurationSHA256: values[3],
    priorLaunchDescriptorSHA256: values[4],
    priorLaunchConfigurationSHA256: values[5],
    resourceTreeSHA256: values[6]
  )
}

private func replacementQ4Binding(
  driftingField: Int? = nil
) -> JobCanaryRoleHostReplacementQ4Binding {
  var values = replacementQ4BindingValues()
  if let driftingField {
    values[driftingField] = String(repeating: "e", count: 64)
  }
  return replacementQ4Binding(values: values)
}

private func replacementQ4Binding(
  transposingAt leftField: Int
) -> JobCanaryRoleHostReplacementQ4Binding {
  var values = replacementQ4BindingValues()
  values.swapAt(leftField, leftField + 1)
  return replacementQ4Binding(values: values)
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
