import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable mutation reconciliation")
struct MutationReconcilerTests {
  @Test("operation-specific policy never retries an unknown non-idempotent create")
  func policyMatrix() {
    let evidence = String(repeating: "a", count: 64)
    for operation in MutationOperation.allCases {
      #expect(
        MutationReconciliationPolicy.classify(
          operation: operation,
          knowledge: .notSent,
          observation: .effectAbsent(evidenceDigest: evidence)
        ) == .safeRetry
      )
      #expect(
        MutationReconciliationPolicy.classify(
          operation: operation,
          knowledge: .unknown,
          observation: .effectExact(evidenceDigest: evidence)
        ) == .attributableEffect
      )
      let absentAfterUnknown = MutationReconciliationPolicy.classify(
        operation: operation,
        knowledge: .unknown,
        observation: .effectAbsent(evidenceDigest: evidence),
        branchCASCreateOnlyProven: operation == .publishBranch
      )
      if operation == .bootstrapLabel || operation == .publishBranch {
        #expect(absentAfterUnknown == .safeRetry)
      } else {
        #expect(absentAfterUnknown == .escalation)
      }
      #expect(
        MutationReconciliationPolicy.classify(
          operation: operation,
          knowledge: .unknown,
          observation: .conflict(evidenceDigest: evidence)
        ) == .escalation
      )
    }

    for operation in [
      MutationOperation.mutateWorkflowLabels,
      .pullRequestWorkflowLabel,
    ] {
      #expect(
        MutationReconciliationPolicy.classify(
          operation: operation,
          knowledge: .unknown,
          observation: .expectedStateExact(evidenceDigest: evidence)
        ) == .safeRetry
      )
      #expect(
        MutationReconciliationPolicy.classify(
          operation: operation,
          knowledge: .unknown,
          observation: .desiredStateExact(evidenceDigest: evidence)
        ) == .attributableEffect
      )
    }
    #expect(
      MutationReconciliationPolicy.classify(
        operation: .publishBranch,
        knowledge: .unknown,
        observation: .effectAbsent(evidenceDigest: evidence),
        branchCASCreateOnlyProven: false
      ) == .escalation
    )
  }

  @Test("system reconciliation sleeper rejects invalid durations")
  func invalidSleepDurations() async {
    let sleeper = SystemMutationReconciliationSleeper()
    for duration in [-1, .infinity, .nan] as [TimeInterval] {
      await #expect(throws: MutationReconciliationError.invalidDelay) {
        try await sleeper.sleep(seconds: duration)
      }
    }
  }

  @Test("prepared-before-send, send epoch, and terminal evidence persist across reopen")
  func durableState() async throws {
    let fixture = try await MutationFixture()
    defer { fixture.remove() }
    let key = GitHubMarkerCodec.sha256(Data("durable-key".utf8))
    let expected = String(repeating: "b", count: 64)
    let request = String(repeating: "c", count: 64)
    let evidence = String(repeating: "d", count: 64)

    await #expect(throws: MutationIntentStoreError.invalidTarget) {
      _ = try await fixture.store.prepare(
        jobID: fixture.jobID,
        idempotencyKey: GitHubMarkerCodec.sha256(Data("invalid-target".utf8)),
        operation: .createMarkerComment,
        target: "target with spaces",
        expectedStateDigest: expected,
        requestDigest: request,
        now: fixture.now
      )
    }

    let prepared = try await fixture.store.prepare(
      jobID: fixture.jobID,
      idempotencyKey: key,
      operation: .createMarkerComment,
      target: "issue:I_issue:comment",
      expectedStateDigest: expected,
      requestDigest: request,
      now: fixture.now
    )
    #expect(prepared.state == .prepared)
    #expect(prepared.sendEpoch == 0)
    let duplicate = try await fixture.store.prepare(
      jobID: fixture.jobID,
      idempotencyKey: key,
      operation: .createMarkerComment,
      target: "issue:I_issue:comment",
      expectedStateDigest: expected,
      requestDigest: request,
      now: fixture.now
    )
    #expect(duplicate.id == prepared.id)
    await #expect(throws: MutationIntentStoreError.idempotencyCollision) {
      _ = try await fixture.store.prepare(
        jobID: fixture.jobID,
        idempotencyKey: key,
        operation: .createPullRequest,
        target: "repository:R_repo",
        expectedStateDigest: expected,
        requestDigest: request,
        now: fixture.now
      )
    }

    let started = try await fixture.store.markSendStarted(id: prepared.id, now: fixture.now)
    #expect(started.state == .sendStarted)
    #expect(started.sendEpoch == 1)
    await #expect(throws: MutationIntentStoreError.sendNotAllowed(.sendStarted)) {
      _ = try await fixture.store.markSendStarted(id: prepared.id, now: fixture.now)
    }
    let reconciling = try await fixture.store.markReconcileRequired(
      id: prepared.id,
      now: fixture.now
    )
    #expect(reconciling.state == .reconcileRequired)
    let escalated = try await fixture.store.settle(
      id: prepared.id,
      outcome: .escalation,
      evidenceDigest: evidence,
      now: fixture.now
    )
    #expect(escalated.state == .escalated)
    #expect(escalated.readBackEvidence == evidence)
    await #expect(throws: MutationIntentStoreError.sendNotAllowed(.escalated)) {
      _ = try await fixture.store.markSendStarted(id: prepared.id, now: fixture.now)
    }

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = MutationIntentStore(database: reopenedDatabase)
    #expect(try await reopened.intent(id: prepared.id)?.state == .escalated)
    #expect(
      try await reopenedDatabase.scalarInt(
        "SELECT COUNT(*) FROM reconciliation_events WHERE job_id = ?",
        bindings: [.text(fixture.jobID.uuidString.lowercased())]
      ) == 3
    )
    await reopenedDatabase.close()
  }

  @Test("delayed visibility attributes exact effects without any second send")
  func delayedVisibility() async throws {
    let fixture = try await MutationFixture()
    defer { fixture.remove() }
    let intent = try await fixture.makeIntent(operation: .createPullRequest, seed: "visible")
    _ = try await fixture.store.markSendStarted(id: intent.id, now: fixture.now)
    let evidence = String(repeating: "e", count: 64)
    let reader = ScriptedMutationReader(observations: [
      .notVisibleYet,
      .notVisibleYet,
      .effectExact(evidenceDigest: evidence),
    ])
    let sleeper = RecordingMutationSleeper()
    let runner = MutationReconciliationRunner(
      store: fixture.store,
      reader: reader,
      sleeper: sleeper,
      now: { Date(timeIntervalSince1970: 10_001) }
    )

    let result = try await runner.reconcile(intentID: intent.id)
    #expect(result.state == .attributed)
    #expect(result.sendEpoch == 1)
    #expect(await reader.attempts() == [1, 2, 3])
    #expect(await sleeper.delays() == [1, 1, 3])
    await #expect(throws: MutationIntentStoreError.sendNotAllowed(.attributed)) {
      _ = try await fixture.store.markSendStarted(id: intent.id, now: fixture.now)
    }
  }

  @Test("unknown create absent after the full visibility window escalates")
  func unknownCreateAbsent() async throws {
    let fixture = try await MutationFixture()
    defer { fixture.remove() }
    let intent = try await fixture.makeIntent(operation: .createMarkerComment, seed: "absent")
    _ = try await fixture.store.markSendStarted(id: intent.id, now: fixture.now)
    let absentEvidence = String(repeating: "9", count: 64)
    let reader = ScriptedMutationReader(
      observations: Array(
        repeating: .effectAbsent(evidenceDigest: absentEvidence),
        count: 5
      )
    )
    let sleeper = RecordingMutationSleeper()
    let runner = MutationReconciliationRunner(
      store: fixture.store,
      reader: reader,
      sleeper: sleeper,
      now: { Date(timeIntervalSince1970: 10_002) }
    )

    let result = try await runner.reconcile(intentID: intent.id)
    #expect(result.state == .escalated)
    #expect(result.sendEpoch == 1)
    #expect(await sleeper.delays() == [1, 1, 3, 5, 20])
  }

  @Test("six crash windows across every operation have one conservative outcome")
  func crashWindowProperty() {
    let evidence = String(repeating: "f", count: 64)
    for operation in MutationOperation.allCases {
      for window in MutationCrashWindow.allCases {
        for visible in [false, true] {
          let knowledge: MutationSendKnowledge =
            window == .afterPrepared ? .notSent : .unknown
          let observation: MutationObservation
          switch window {
          case .afterPrepared:
            observation = .effectAbsent(evidenceDigest: evidence)
          case .betweenSendStartedAndSocket, .afterWriteBeforeResponse:
            observation =
              visible
              ? .effectExact(evidenceDigest: evidence)
              : .effectAbsent(evidenceDigest: evidence)
          case .afterResponseBeforeCommit, .afterReadBackBeforeTransition:
            observation = .effectExact(evidenceDigest: evidence)
          case .duringReadBack:
            observation =
              visible
              ? .effectExact(evidenceDigest: evidence)
              : .notVisibleYet
          }
          if observation == .notVisibleYet {
            continue
          }
          let outcome = MutationReconciliationPolicy.classify(
            operation: operation,
            knowledge: knowledge,
            observation: observation
          )
          #expect(MutationReconciliationOutcome.allCasesForTest.contains(outcome))
          if operation.isNonIdempotentCreate,
            knowledge == .unknown,
            case .effectAbsent = observation
          {
            #expect(outcome == .escalation)
          }
          if case .effectExact = observation {
            #expect(outcome == .attributableEffect)
          }
        }
      }
    }
  }
}

private enum MutationCrashWindow: CaseIterable {
  case afterPrepared
  case betweenSendStartedAndSocket
  case afterWriteBeforeResponse
  case afterResponseBeforeCommit
  case duringReadBack
  case afterReadBackBeforeTransition
}

extension MutationReconciliationOutcome {
  fileprivate static let allCasesForTest: [Self] = [
    .safeRetry, .attributableEffect, .escalation,
  ]
}

private actor ScriptedMutationReader: MutationObservationReader {
  private var observations: [MutationObservation]
  private var recordedAttempts: [Int] = []

  init(observations: [MutationObservation]) {
    self.observations = observations
  }

  func observe(intent: MutationIntentRecord, attempt: Int) async throws
    -> MutationObservation
  {
    recordedAttempts.append(attempt)
    guard !observations.isEmpty else { return .notVisibleYet }
    return observations.removeFirst()
  }

  func attempts() -> [Int] { recordedAttempts }
}

private actor RecordingMutationSleeper: MutationReconciliationSleeper {
  private var recorded: [TimeInterval] = []

  func sleep(seconds: TimeInterval) async throws {
    recorded.append(seconds)
  }

  func delays() -> [TimeInterval] { recorded }
}

private final class MutationFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let store: MutationIntentStore
  let jobID: UUID
  let now = Date(timeIntervalSince1970: 10_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-mutation-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
    let repositoryID = UUID()
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', 'repo', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text("R_\(repositoryID.uuidString.lowercased())"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    let jobs = DurableJobStore(database: database)
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueTriage,
        objectNodeID: "I_issue",
        revisionKey: "initial-triage"
      ),
      contractVersionUsed: "v1",
      priority: .triage,
      firstStep: .triage,
      now: now
    )
    guard case .created(let job) = created else {
      throw MutationIntentStoreError.decode("job suppressed")
    }
    jobID = job.id
    store = MutationIntentStore(database: database)
  }

  func makeIntent(
    operation: MutationOperation,
    seed: String
  ) async throws -> MutationIntentRecord {
    try await store.prepare(
      jobID: jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("key-\(seed)".utf8)),
      operation: operation,
      target: "target:\(seed)",
      expectedStateDigest: GitHubMarkerCodec.sha256(Data("expected-\(seed)".utf8)),
      requestDigest: GitHubMarkerCodec.sha256(Data("request-\(seed)".utf8)),
      now: now
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
