import Foundation

public enum MutationOperation: String, CaseIterable, Codable, Sendable {
  case bootstrapLabel
  case createMarkerComment
  case mutateWorkflowLabels
  case claimIssue
  case publishBranch
  case createPullRequest
  case pullRequestWorkflowLabel
  case linkPullRequest
  case publishComplexPlan
  case blockIssue

  public var isNonIdempotentCreate: Bool {
    switch self {
    case .createMarkerComment, .claimIssue, .createPullRequest,
      .linkPullRequest, .publishComplexPlan, .blockIssue:
      true
    default:
      false
    }
  }
}

public enum MutationIntentState: String, CaseIterable, Codable, Sendable {
  case prepared
  case sendStarted
  case reconcileRequired
  case attributed
  case retryAllowed
  case escalated

  public var isTerminal: Bool {
    self == .attributed || self == .escalated
  }
}

public struct MutationIntentRecord: Equatable, Sendable {
  public let id: UUID
  public let jobID: UUID
  public let idempotencyKey: String
  public let operation: MutationOperation
  public let target: String
  public let expectedStateDigest: String
  public let requestDigest: String
  public let state: MutationIntentState
  public let sendEpoch: Int
  public let readBackEvidence: String?
  public let createdAt: Date
  public let updatedAt: Date
}

public enum MutationIntentStoreError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidTarget
  case invalidDigest
  case intentNotFound(UUID)
  case idempotencyCollision
  case sendNotAllowed(MutationIntentState)
  case transitionNotAllowed(from: MutationIntentState, to: MutationIntentState)
  case concurrentTransition
  case decode(String)
}

public actor MutationIntentStore {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  public func prepare(
    id: UUID = UUID(),
    jobID: UUID,
    idempotencyKey: String,
    operation: MutationOperation,
    target: String,
    expectedStateDigest: String,
    requestDigest: String,
    now: Date
  ) async throws -> MutationIntentRecord {
    try Self.validate(
      idempotencyKey: idempotencyKey,
      target: target,
      expectedStateDigest: expectedStateDigest,
      requestDigest: requestDigest
    )
    return try await database.transaction { database in
      if let existing = try Self.load(
        idempotencyKey: idempotencyKey,
        database: database
      ) {
        guard existing.jobID == jobID,
          existing.operation == operation,
          existing.target == target,
          existing.expectedStateDigest == expectedStateDigest,
          existing.requestDigest == requestDigest
        else {
          throw MutationIntentStoreError.idempotencyCollision
        }
        return existing
      }
      _ = try database.execute(
        """
        INSERT INTO mutation_intents(
          id, job_id, idempotency_key, operation, target,
          expected_state_digest, request_digest, state, send_epoch,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'prepared', 0, ?, ?)
        """,
        bindings: [
          .text(id.uuidString.lowercased()),
          .text(jobID.uuidString.lowercased()),
          .text(idempotencyKey),
          .text(operation.rawValue),
          .text(target),
          .text(expectedStateDigest),
          .text(requestDigest),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.load(id: id, database: database)
    }
  }

  public func markSendStarted(id: UUID, now: Date) async throws -> MutationIntentRecord {
    try await database.transaction { database in
      let current = try Self.load(id: id, database: database)
      guard current.state == .prepared || current.state == .retryAllowed else {
        throw MutationIntentStoreError.sendNotAllowed(current.state)
      }
      let changed = try database.execute(
        """
        UPDATE mutation_intents
        SET state = 'sendStarted', send_epoch = send_epoch + 1, updated_at = ?
        WHERE id = ? AND state = ?
        """,
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(id.uuidString.lowercased()),
          .text(current.state.rawValue),
        ]
      )
      guard changed == 1 else { throw MutationIntentStoreError.concurrentTransition }
      try Self.appendEvent(
        intent: current,
        observation: "send epoch \(current.sendEpoch + 1) started",
        classification: MutationIntentState.sendStarted.rawValue,
        reason: "prepared-before-send boundary",
        now: now,
        database: database
      )
      return try Self.load(id: id, database: database)
    }
  }

  public func markReconcileRequired(
    id: UUID,
    now: Date
  ) async throws -> MutationIntentRecord {
    try await database.transaction { database in
      let current = try Self.load(id: id, database: database)
      if current.state == .reconcileRequired { return current }
      guard current.state == .sendStarted else {
        throw MutationIntentStoreError.transitionNotAllowed(
          from: current.state,
          to: .reconcileRequired
        )
      }
      return try Self.transition(
        current,
        to: .reconcileRequired,
        evidenceDigest: nil,
        observation: "send outcome unknown",
        reason: "read-back required before another mutation",
        now: now,
        database: database
      )
    }
  }

  public func settle(
    id: UUID,
    outcome: MutationReconciliationOutcome,
    evidenceDigest: String,
    now: Date
  ) async throws -> MutationIntentRecord {
    guard GitHubInputValidation.validSHA256(evidenceDigest) else {
      throw MutationIntentStoreError.invalidDigest
    }
    return try await database.transaction { database in
      let current = try Self.load(id: id, database: database)
      let next: MutationIntentState =
        switch outcome {
        case .safeRetry: .retryAllowed
        case .attributableEffect: .attributed
        case .escalation: .escalated
        }
      guard [.prepared, .sendStarted, .reconcileRequired, .retryAllowed].contains(current.state)
      else {
        if current.state == next, current.readBackEvidence == evidenceDigest {
          return current
        }
        throw MutationIntentStoreError.transitionNotAllowed(from: current.state, to: next)
      }
      return try Self.transition(
        current,
        to: next,
        evidenceDigest: evidenceDigest,
        observation: outcome.rawValue,
        reason: "operation-specific read-back classification",
        now: now,
        database: database
      )
    }
  }

  public func intent(id: UUID) async throws -> MutationIntentRecord? {
    try await database.query(
      "SELECT * FROM mutation_intents WHERE id = ?",
      bindings: [.text(id.uuidString.lowercased())]
    ).first.map(Self.decode)
  }

  public func intent(idempotencyKey: String) async throws -> MutationIntentRecord? {
    try await database.query(
      "SELECT * FROM mutation_intents WHERE idempotency_key = ?",
      bindings: [.text(idempotencyKey)]
    ).first.map(Self.decode)
  }

  public func intents(jobID: UUID) async throws -> [MutationIntentRecord] {
    try await database.query(
      "SELECT * FROM mutation_intents WHERE job_id = ? ORDER BY created_at, id",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).map(Self.decode)
  }

  private static func transition(
    _ current: MutationIntentRecord,
    to state: MutationIntentState,
    evidenceDigest: String?,
    observation: String,
    reason: String,
    now: Date,
    database: isolated SQLiteStore
  ) throws -> MutationIntentRecord {
    let changed = try database.execute(
      """
      UPDATE mutation_intents
      SET state = ?, read_back_evidence = ?, updated_at = ?
      WHERE id = ? AND state = ?
      """,
      bindings: [
        .text(state.rawValue),
        evidenceDigest.map(SQLiteValue.text) ?? .null,
        .real(now.timeIntervalSince1970),
        .text(current.id.uuidString.lowercased()),
        .text(current.state.rawValue),
      ]
    )
    guard changed == 1 else { throw MutationIntentStoreError.concurrentTransition }
    try appendEvent(
      intent: current,
      observation: observation,
      classification: state.rawValue,
      reason: reason,
      now: now,
      database: database
    )
    return try load(id: current.id, database: database)
  }

  private static func appendEvent(
    intent: MutationIntentRecord,
    observation: String,
    classification: String,
    reason: String,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    _ = try database.execute(
      """
      INSERT INTO reconciliation_events(
        job_id, probe, observation, classification, reason, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(intent.jobID.uuidString.lowercased()),
        .text("mutation:\(intent.operation.rawValue)"),
        .text(observation),
        .text(classification),
        .text(reason),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  private static func load(
    id: UUID,
    database: isolated SQLiteStore
  ) throws -> MutationIntentRecord {
    guard
      let row = try database.query(
        "SELECT * FROM mutation_intents WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).first
    else {
      throw MutationIntentStoreError.intentNotFound(id)
    }
    return try decode(row)
  }

  private static func load(
    idempotencyKey: String,
    database: isolated SQLiteStore
  ) throws -> MutationIntentRecord? {
    try database.query(
      "SELECT * FROM mutation_intents WHERE idempotency_key = ?",
      bindings: [.text(idempotencyKey)]
    ).first.map(decode)
  }

  private static func decode(_ row: SQLiteRow) throws -> MutationIntentRecord {
    guard let id = UUID(uuidString: try text(row, "id")),
      let jobID = UUID(uuidString: try text(row, "job_id")),
      let operation = MutationOperation(rawValue: try text(row, "operation")),
      let state = MutationIntentState(rawValue: try text(row, "state"))
    else {
      throw MutationIntentStoreError.decode("unknown mutation value")
    }
    return MutationIntentRecord(
      id: id,
      jobID: jobID,
      idempotencyKey: try text(row, "idempotency_key"),
      operation: operation,
      target: try text(row, "target"),
      expectedStateDigest: try text(row, "expected_state_digest"),
      requestDigest: try text(row, "request_digest"),
      state: state,
      sendEpoch: Int(try integer(row, "send_epoch")),
      readBackEvidence: try optionalText(row, "read_back_evidence"),
      createdAt: Date(timeIntervalSince1970: try real(row, "created_at")),
      updatedAt: Date(timeIntervalSince1970: try real(row, "updated_at"))
    )
  }

  private static func validate(
    idempotencyKey: String,
    target: String,
    expectedStateDigest: String,
    requestDigest: String
  ) throws {
    guard GitHubInputValidation.validSHA256(idempotencyKey) else {
      throw MutationIntentStoreError.invalidIdentifier
    }
    guard !target.isEmpty, target.utf8.count <= 1_024,
      target.utf8.allSatisfy({ byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || [43, 45, 46, 47, 58, 61, 64, 95].contains(byte)
      })
    else {
      throw MutationIntentStoreError.invalidTarget
    }
    guard GitHubInputValidation.validSHA256(expectedStateDigest),
      GitHubInputValidation.validSHA256(requestDigest)
    else {
      throw MutationIntentStoreError.invalidDigest
    }
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw MutationIntentStoreError.decode("expected text column \(column)")
    }
    return value
  }

  private static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): value
    case .null: nil
    default: throw MutationIntentStoreError.decode("expected optional text column \(column)")
    }
  }

  private static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw MutationIntentStoreError.decode("expected integer column \(column)")
    }
    return value
  }

  private static func real(_ row: SQLiteRow, _ column: String) throws -> Double {
    switch row[column] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: throw MutationIntentStoreError.decode("expected real column \(column)")
    }
  }
}

public enum MutationSendKnowledge: Equatable, Sendable {
  case notSent
  case unknown
}

public enum MutationObservation: Equatable, Sendable {
  case effectExact(evidenceDigest: String)
  case desiredStateExact(evidenceDigest: String)
  case expectedStateExact(evidenceDigest: String)
  case effectAbsent(evidenceDigest: String)
  case notVisibleYet
  case conflict(evidenceDigest: String)
  case duplicate(evidenceDigest: String)
  case digestMismatch(evidenceDigest: String)
  case incomplete(evidenceDigest: String)

  public var evidenceDigest: String? {
    switch self {
    case .effectExact(let digest), .desiredStateExact(let digest),
      .expectedStateExact(let digest), .effectAbsent(let digest),
      .conflict(let digest), .duplicate(let digest),
      .digestMismatch(let digest), .incomplete(let digest):
      digest
    case .notVisibleYet:
      nil
    }
  }
}

public enum MutationReconciliationOutcome: String, Equatable, Sendable {
  case safeRetry
  case attributableEffect
  case escalation
}

public enum MutationReconciliationPolicy {
  public static let delayedReadSeconds: [TimeInterval] = [1, 2, 5, 10, 30]

  public static func classify(
    operation: MutationOperation,
    knowledge: MutationSendKnowledge,
    observation: MutationObservation,
    branchCASCreateOnlyProven: Bool = false
  ) -> MutationReconciliationOutcome {
    switch observation {
    case .effectExact, .desiredStateExact:
      return .attributableEffect
    case .conflict, .duplicate, .digestMismatch, .incomplete, .notVisibleYet:
      return .escalation
    case .expectedStateExact:
      if knowledge == .notSent { return .safeRetry }
      switch operation {
      case .mutateWorkflowLabels, .pullRequestWorkflowLabel:
        return .safeRetry
      case .bootstrapLabel:
        return .safeRetry
      case .publishBranch where branchCASCreateOnlyProven:
        return .safeRetry
      default:
        return .escalation
      }
    case .effectAbsent:
      if knowledge == .notSent { return .safeRetry }
      switch operation {
      case .bootstrapLabel:
        return .safeRetry
      case .publishBranch where branchCASCreateOnlyProven:
        return .safeRetry
      default:
        return .escalation
      }
    }
  }
}

public protocol MutationObservationReader: Sendable {
  func observe(intent: MutationIntentRecord, attempt: Int) async throws
    -> MutationObservation
}

public protocol MutationReconciliationSleeper: Sendable {
  func sleep(seconds: TimeInterval) async throws
}

public enum MutationReconciliationError: Error, Equatable, Sendable {
  case invalidDelay
}

public struct SystemMutationReconciliationSleeper: MutationReconciliationSleeper {
  public init() {}

  public func sleep(seconds: TimeInterval) async throws {
    guard seconds.isFinite, (0...3_600).contains(seconds) else {
      throw MutationReconciliationError.invalidDelay
    }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

public actor MutationReconciliationRunner {
  private let store: MutationIntentStore
  private let reader: any MutationObservationReader
  private let sleeper: any MutationReconciliationSleeper
  private let branchCASCreateOnlyProven: Bool
  private let now: @Sendable () -> Date

  public init(
    store: MutationIntentStore,
    reader: any MutationObservationReader,
    sleeper: any MutationReconciliationSleeper = SystemMutationReconciliationSleeper(),
    branchCASCreateOnlyProven: Bool = false,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.reader = reader
    self.sleeper = sleeper
    self.branchCASCreateOnlyProven = branchCASCreateOnlyProven
    self.now = now
  }

  public func reconcile(intentID: UUID) async throws -> MutationIntentRecord {
    guard var intent = try await store.intent(id: intentID) else {
      throw MutationIntentStoreError.intentNotFound(intentID)
    }
    let knowledge: MutationSendKnowledge
    switch intent.state {
    case .prepared:
      knowledge = .notSent
    case .sendStarted:
      intent = try await store.markReconcileRequired(id: intentID, now: now())
      knowledge = .unknown
    case .reconcileRequired:
      knowledge = .unknown
    case .attributed, .retryAllowed, .escalated:
      return intent
    }

    var lastEvidence = GitHubMarkerCodec.sha256(Data("read-back-empty".utf8))
    var previousOffset: TimeInterval = 0
    for (index, offset) in MutationReconciliationPolicy.delayedReadSeconds.enumerated() {
      try await sleeper.sleep(seconds: offset - previousOffset)
      previousOffset = offset
      let observation = try await reader.observe(intent: intent, attempt: index + 1)
      if let evidence = observation.evidenceDigest {
        guard GitHubInputValidation.validSHA256(evidence) else {
          throw MutationIntentStoreError.invalidDigest
        }
        lastEvidence = evidence
      }
      if observation == .notVisibleYet { continue }
      if knowledge == .unknown, intent.operation.isNonIdempotentCreate,
        case .effectAbsent = observation,
        index < MutationReconciliationPolicy.delayedReadSeconds.count - 1
      {
        continue
      }
      let outcome = MutationReconciliationPolicy.classify(
        operation: intent.operation,
        knowledge: knowledge,
        observation: observation,
        branchCASCreateOnlyProven: branchCASCreateOnlyProven
      )
      return try await store.settle(
        id: intentID,
        outcome: outcome,
        evidenceDigest: lastEvidence,
        now: now()
      )
    }

    let outcome = MutationReconciliationPolicy.classify(
      operation: intent.operation,
      knowledge: knowledge,
      observation: .effectAbsent(evidenceDigest: lastEvidence),
      branchCASCreateOnlyProven: branchCASCreateOnlyProven
    )
    return try await store.settle(
      id: intentID,
      outcome: outcome,
      evidenceDigest: lastEvidence,
      now: now()
    )
  }
}
