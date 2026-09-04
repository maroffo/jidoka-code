import CryptoKit
import Darwin
import Foundation

public enum ApprovedCommandRunPhase: String, Codable, Sendable {
  case bootstrap
  case orchestration
}

public enum ApprovedCommandRunState: String, Codable, Sendable {
  case prepared
  case started
  case resultAccepted
  case unknown
  case superseded
}

public enum ApprovedCommandRunEventKind: String, Codable, Sendable {
  case prepared
  case started
  case resultAccepted
  case unknown
  case superseded
}

public struct ApprovedCommandWorkspaceIdentity: Equatable, Sendable {
  public let path: String
  public let device: UInt64
  public let inode: UInt64

  public init(url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_dev >= 0,
      metadata.st_ino > 0
    else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.path == url.path else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    path = canonical.path
    device = UInt64(metadata.st_dev)
    inode = UInt64(metadata.st_ino)
  }
}

public struct ApprovedCommandRunRecord: Equatable, Sendable {
  public let id: String
  public let jobID: UUID
  public let jobAttempt: Int
  public let jobStep: Int
  public let phase: ApprovedCommandRunPhase
  public let round: Int
  public let commandOrdinal: Int
  public let commandID: String
  public let planSHA256: String
  public let definitionSHA256: String
  public let registryKind: ApprovedCommandRegistryKind
  public let workspace: ApprovedCommandWorkspaceIdentity
  public let state: ApprovedCommandRunState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct ApprovedCommandRunEventRecord: Equatable, Sendable {
  public let runID: String
  public let sequence: Int
  public let kind: ApprovedCommandRunEventKind
  public let recordSHA256: String?
  public let detailCode: String?
  public let createdAt: Date
}

public enum ApprovedCommandRunStoreError: Error, Equatable, Sendable {
  case invalidRecord
  case jobNotFound(UUID)
  case identityCollision
  case runNotFound(String)
  case invalidTransition
  case launchSuppressed
  case outcomeUnknown(String)
  case divergentResult
  case workspaceDiverged
  case decode(String)
}

struct ApprovedCommandExecutionLease: Equatable, Sendable {
  let token: UUID
}

public actor ApprovedCommandExecutionGate {
  private var allowed: Bool
  private var active: Set<UUID> = []
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  public init(initiallyAllowed: Bool = false) {
    allowed = initiallyAllowed
  }

  func acquire() throws -> ApprovedCommandExecutionLease {
    guard allowed else { throw ApprovedCommandRunStoreError.launchSuppressed }
    let lease = ApprovedCommandExecutionLease(token: UUID())
    active.insert(lease.token)
    return lease
  }

  func release(_ lease: ApprovedCommandExecutionLease) {
    guard active.remove(lease.token) != nil, active.isEmpty else { return }
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func close() {
    allowed = false
  }

  func waitUntilIdle() async {
    guard !active.isEmpty else { return }
    await withCheckedContinuation { continuation in
      closeWaiters.append(continuation)
    }
  }

  func closeAndWait() async {
    close()
    await waitUntilIdle()
  }

  func open() {
    allowed = true
  }

  func isBusy() -> Bool {
    !active.isEmpty
  }
}

public actor ApprovedCommandRunStore {
  private let database: SQLiteStore
  private let now: @Sendable () -> Date

  public init(
    database: SQLiteStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.now = now
  }

  @discardableResult
  public func prepare(
    job: JobRecord,
    phase: ApprovedCommandRunPhase,
    round: Int,
    commandOrdinal: Int,
    command: ApprovedCommand,
    planSHA256: String,
    workspace: ApprovedCommandWorkspaceIdentity
  ) async throws -> ApprovedCommandRunRecord {
    guard (1...3).contains(round), commandOrdinal >= 0,
      Self.validID(command.id), Self.isSHA256(planSHA256),
      Self.isSHA256(command.definitionDigest), Self.validPath(workspace.path),
      workspace.device <= UInt64(Int64.max), workspace.inode <= UInt64(Int64.max)
    else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let timestamp = now()
    return try await database.transaction { database in
      guard
        let jobRow = try database.query(
          "SELECT state, attempt, current_step FROM jobs WHERE id = ?",
          bindings: [.text(Self.uuid(job.id))]
        ).first
      else {
        throw ApprovedCommandRunStoreError.jobNotFound(job.id)
      }
      guard try Self.text(jobRow, "state") == JobState.runningPi.rawValue,
        try Self.integer(jobRow, "attempt") == Int64(job.attempt),
        try Self.integer(jobRow, "current_step") == Int64(job.currentStep)
      else {
        throw ApprovedCommandRunStoreError.identityCollision
      }
      if let existing = try Self.loadLogicalRun(
        jobID: job.id,
        jobStep: job.currentStep,
        phase: phase,
        round: round,
        commandOrdinal: commandOrdinal,
        database: database
      ) {
        if existing.state == .prepared, existing.jobAttempt != job.attempt {
          let changed = try database.execute(
            """
            UPDATE approved_command_runs
            SET state = 'superseded', updated_at = ?
            WHERE id = ? AND state = 'prepared'
            """,
            bindings: [
              .real(timestamp.timeIntervalSince1970),
              .text(existing.id),
            ]
          )
          guard changed == 1 else {
            throw ApprovedCommandRunStoreError.invalidTransition
          }
          try Self.appendEvent(
            runID: existing.id,
            kind: .superseded,
            recordSHA256: nil,
            detailCode: "JOB_ATTEMPT_SUPERSEDED",
            at: timestamp,
            database: database
          )
        } else {
          guard existing.commandID == command.id,
            existing.planSHA256 == planSHA256,
            existing.definitionSHA256 == command.definitionDigest,
            existing.registryKind == command.registryKind,
            existing.workspace == workspace
          else {
            throw ApprovedCommandRunStoreError.identityCollision
          }
          return existing
        }
      }
      let runID = "command-\(UUID().uuidString.lowercased())"
      _ = try database.execute(
        """
        INSERT INTO approved_command_runs(
          id, job_id, job_attempt, job_step, phase, round,
          command_ordinal, command_id, plan_sha256, definition_sha256, registry_kind,
          workspace_path, workspace_device, workspace_inode, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
        """,
        bindings: [
          .text(runID),
          .text(Self.uuid(job.id)),
          .integer(Int64(job.attempt)),
          .integer(Int64(job.currentStep)),
          .text(phase.rawValue),
          .integer(Int64(round)),
          .integer(Int64(commandOrdinal)),
          .text(command.id),
          .text(planSHA256),
          .text(command.definitionDigest),
          .text(command.registryKind.rawValue),
          .text(workspace.path),
          .integer(Int64(workspace.device)),
          .integer(Int64(workspace.inode)),
          .real(timestamp.timeIntervalSince1970),
          .real(timestamp.timeIntervalSince1970),
        ]
      )
      try Self.appendEvent(
        runID: runID,
        kind: .prepared,
        recordSHA256: nil,
        detailCode: nil,
        at: timestamp,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  @discardableResult
  public func start(runID: String) async throws -> ApprovedCommandRunRecord {
    guard Self.validRunID(runID) else { throw ApprovedCommandRunStoreError.invalidRecord }
    let timestamp = now()
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      switch run.state {
      case .resultAccepted:
        return run
      case .started, .unknown:
        throw ApprovedCommandRunStoreError.outcomeUnknown(runID)
      case .superseded:
        throw ApprovedCommandRunStoreError.invalidTransition
      case .prepared:
        break
      }
      let launchAllowed =
        try database.scalarInt(
          "SELECT COUNT(*) FROM app_settings WHERE singleton = 1 AND paused = 0"
        ) ?? 0
      guard launchAllowed == 1 else {
        throw ApprovedCommandRunStoreError.launchSuppressed
      }
      guard
        let jobRow = try database.query(
          "SELECT state, attempt, current_step FROM jobs WHERE id = ?",
          bindings: [.text(Self.uuid(run.jobID))]
        ).first,
        try Self.text(jobRow, "state") == JobState.runningPi.rawValue,
        try Self.integer(jobRow, "attempt") == Int64(run.jobAttempt),
        try Self.integer(jobRow, "current_step") == Int64(run.jobStep)
      else {
        throw ApprovedCommandRunStoreError.identityCollision
      }
      let unresolved =
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM approved_command_runs
          WHERE job_id = ? AND job_step = ? AND id != ?
            AND state IN ('started', 'unknown')
          """,
          bindings: [
            .text(Self.uuid(run.jobID)),
            .integer(Int64(run.jobStep)),
            .text(run.id),
          ]
        ) ?? 0
      guard unresolved == 0 else {
        throw ApprovedCommandRunStoreError.outcomeUnknown(runID)
      }
      let incompletePrefix =
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM approved_command_runs AS runs
          LEFT JOIN approved_command_results AS results ON results.run_id = runs.id
          WHERE runs.job_id = ? AND runs.job_step = ? AND runs.command_ordinal < ?
            AND (
              runs.phase = 'bootstrap'
              OR (runs.phase = 'orchestration' AND runs.round = ?)
            )
            AND runs.state != 'superseded'
          AND (runs.state != 'resultAccepted' OR results.succeeded != 1)
          """,
          bindings: [
            .text(Self.uuid(run.jobID)),
            .integer(Int64(run.jobStep)),
            .integer(Int64(run.commandOrdinal)),
            .integer(Int64(run.round)),
          ]
        ) ?? 0
      guard incompletePrefix == 0 else {
        throw ApprovedCommandRunStoreError.invalidTransition
      }
      let changed = try database.execute(
        """
        UPDATE approved_command_runs
        SET state = 'started', updated_at = ?
        WHERE id = ? AND state = 'prepared'
        """,
        bindings: [
          .real(timestamp.timeIntervalSince1970),
          .text(runID),
        ]
      )
      guard changed == 1 else { throw ApprovedCommandRunStoreError.invalidTransition }
      try Self.appendEvent(
        runID: runID,
        kind: .started,
        recordSHA256: nil,
        detailCode: nil,
        at: timestamp,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  @discardableResult
  public func accept(
    runID: String,
    evidence: VerificationCommandEvidence
  ) async throws -> ApprovedCommandRunRecord {
    guard Self.validRunID(runID), let repositoryStateSHA256 = evidence.repositoryStateSHA256,
      Self.isSHA256(repositoryStateSHA256)
    else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let envelope = try Self.encode(evidence)
    guard !envelope.isEmpty, envelope.count <= 1_048_576 else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let evidenceSHA256 = Self.sha256(envelope)
    let timestamp = now()
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      guard evidence.commandID == run.commandID,
        evidence.registryKind == run.registryKind,
        evidence.definitionDigest == run.definitionSHA256
      else {
        throw ApprovedCommandRunStoreError.divergentResult
      }
      if run.state == .resultAccepted {
        let stored = try Self.requireResult(runID: runID, database: database)
        guard stored.envelope == envelope,
          stored.evidenceSHA256 == evidenceSHA256,
          stored.repositoryStateSHA256 == repositoryStateSHA256
        else {
          throw ApprovedCommandRunStoreError.divergentResult
        }
        return run
      }
      guard run.state == .started else {
        if run.state == .unknown {
          throw ApprovedCommandRunStoreError.outcomeUnknown(runID)
        }
        throw ApprovedCommandRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        INSERT INTO approved_command_results(
          run_id, envelope, evidence_sha256, repository_state_sha256, succeeded, created_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(runID),
          .blob(envelope),
          .text(evidenceSHA256),
          .text(repositoryStateSHA256),
          .integer(evidence.succeeded ? 1 : 0),
          .real(timestamp.timeIntervalSince1970),
        ]
      )
      let changed = try database.execute(
        """
        UPDATE approved_command_runs
        SET state = 'resultAccepted', updated_at = ?
        WHERE id = ? AND state = 'started'
        """,
        bindings: [
          .real(timestamp.timeIntervalSince1970),
          .text(runID),
        ]
      )
      guard changed == 1 else { throw ApprovedCommandRunStoreError.invalidTransition }
      try Self.appendEvent(
        runID: runID,
        kind: .resultAccepted,
        recordSHA256: evidenceSHA256,
        detailCode: evidence.succeeded ? "COMMAND_SUCCEEDED" : "COMMAND_FAILED",
        at: timestamp,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  @discardableResult
  public func markUnknown(
    runID: String,
    detailCode: String = "COMMAND_OUTCOME_UNKNOWN"
  ) async throws -> ApprovedCommandRunRecord {
    guard Self.validRunID(runID), Self.validDetailCode(detailCode) else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let timestamp = now()
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      switch run.state {
      case .resultAccepted, .unknown:
        return run
      case .prepared, .superseded:
        throw ApprovedCommandRunStoreError.invalidTransition
      case .started:
        break
      }
      let changed = try database.execute(
        """
        UPDATE approved_command_runs
        SET state = 'unknown', updated_at = ?
        WHERE id = ? AND state = 'started'
        """,
        bindings: [
          .real(timestamp.timeIntervalSince1970),
          .text(runID),
        ]
      )
      guard changed == 1 else { throw ApprovedCommandRunStoreError.invalidTransition }
      try Self.appendEvent(
        runID: runID,
        kind: .unknown,
        recordSHA256: nil,
        detailCode: detailCode,
        at: timestamp,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  @discardableResult
  func recordLaunchDenied(
    runID: String,
    detailCode: String = "LAUNCH_DENIED_BEFORE_PROCESS"
  ) async throws -> ApprovedCommandRunRecord {
    guard Self.validRunID(runID), Self.validDetailCode(detailCode) else {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let timestamp = now()
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      if run.state == .superseded { return run }
      guard run.state == .started else {
        if run.state == .unknown {
          throw ApprovedCommandRunStoreError.outcomeUnknown(runID)
        }
        throw ApprovedCommandRunStoreError.invalidTransition
      }
      let changed = try database.execute(
        """
        UPDATE approved_command_runs
        SET state = 'superseded', updated_at = ?
        WHERE id = ? AND state = 'started'
        """,
        bindings: [
          .real(timestamp.timeIntervalSince1970),
          .text(runID),
        ]
      )
      guard changed == 1 else { throw ApprovedCommandRunStoreError.invalidTransition }
      try Self.appendEvent(
        runID: runID,
        kind: .superseded,
        recordSHA256: nil,
        detailCode: detailCode,
        at: timestamp,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  public func recoverAtStartup() async throws -> [ApprovedCommandRunRecord] {
    let timestamp = now()
    return try await database.transaction { database in
      let started = try database.query(
        "SELECT * FROM approved_command_runs WHERE state = 'started' ORDER BY id"
      ).map(Self.decodeRun)
      for run in started {
        let changed = try database.execute(
          """
          UPDATE approved_command_runs
          SET state = 'unknown', updated_at = ?
          WHERE id = ? AND state = 'started'
          """,
          bindings: [
            .real(timestamp.timeIntervalSince1970),
            .text(run.id),
          ]
        )
        guard changed == 1 else { throw ApprovedCommandRunStoreError.invalidTransition }
        try Self.appendEvent(
          runID: run.id,
          kind: .unknown,
          recordSHA256: nil,
          detailCode: "STARTUP_OUTCOME_UNKNOWN",
          at: timestamp,
          database: database
        )
      }
      return try database.query(
        "SELECT * FROM approved_command_runs WHERE state = 'unknown' ORDER BY id"
      ).map(Self.decodeRun)
    }
  }

  public func run(id: String) async throws -> ApprovedCommandRunRecord? {
    guard Self.validRunID(id) else { throw ApprovedCommandRunStoreError.invalidRecord }
    return try await database.query(
      "SELECT * FROM approved_command_runs WHERE id = ?",
      bindings: [.text(id)]
    ).first.map(Self.decodeRun)
  }

  public func runs(jobID: UUID) async throws -> [ApprovedCommandRunRecord] {
    try await database.query(
      """
      SELECT * FROM approved_command_runs
      WHERE job_id = ?
      ORDER BY job_step, phase, round, command_ordinal
      """,
      bindings: [.text(Self.uuid(jobID))]
    ).map(Self.decodeRun)
  }

  public func acceptedEvidence(runID: String) async throws -> VerificationCommandEvidence? {
    guard Self.validRunID(runID) else { throw ApprovedCommandRunStoreError.invalidRecord }
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      guard run.state == .resultAccepted else { return nil }
      return try Self.decodeEvidence(
        try Self.requireResult(runID: runID, database: database),
        run: run
      )
    }
  }

  public func requiresRepositoryStateValidation(runID: String) async throws -> Bool {
    guard Self.validRunID(runID) else { throw ApprovedCommandRunStoreError.invalidRecord }
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      guard run.state == .resultAccepted else {
        throw ApprovedCommandRunStoreError.invalidTransition
      }
      let laterAccepted =
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM approved_command_runs
          WHERE job_id = ? AND job_step = ? AND state = 'resultAccepted' AND id != ?
            AND (
              (? = 'bootstrap' AND (
                phase = 'orchestration'
                OR (phase = 'bootstrap' AND command_ordinal > ?)
              ))
              OR (? = 'orchestration' AND phase = 'orchestration' AND (
                round > ? OR (round = ? AND command_ordinal > ?)
              ))
            )
          """,
          bindings: [
            .text(Self.uuid(run.jobID)),
            .integer(Int64(run.jobStep)),
            .text(run.id),
            .text(run.phase.rawValue),
            .integer(Int64(run.commandOrdinal)),
            .text(run.phase.rawValue),
            .integer(Int64(run.round)),
            .integer(Int64(run.round)),
            .integer(Int64(run.commandOrdinal)),
          ]
        ) ?? 0
      return laterAccepted == 0
    }
  }

  public func events(runID: String) async throws -> [ApprovedCommandRunEventRecord] {
    guard Self.validRunID(runID) else { throw ApprovedCommandRunStoreError.invalidRecord }
    return try await database.query(
      "SELECT * FROM approved_command_events WHERE run_id = ? ORDER BY sequence",
      bindings: [.text(runID)]
    ).map(Self.decodeEvent)
  }

  private struct StoredResult {
    let envelope: Data
    let evidenceSHA256: String
    let repositoryStateSHA256: String
    let succeeded: Bool
  }

  private static func loadLogicalRun(
    jobID: UUID,
    jobStep: Int,
    phase: ApprovedCommandRunPhase,
    round: Int,
    commandOrdinal: Int,
    database: isolated SQLiteStore
  ) throws -> ApprovedCommandRunRecord? {
    try database.query(
      """
      SELECT * FROM approved_command_runs
      WHERE job_id = ? AND job_step = ? AND phase = ? AND round = ?
        AND command_ordinal = ? AND state != 'superseded'
      """,
      bindings: [
        .text(uuid(jobID)),
        .integer(Int64(jobStep)),
        .text(phase.rawValue),
        .integer(Int64(round)),
        .integer(Int64(commandOrdinal)),
      ]
    ).first.map(decodeRun)
  }

  private static func requireRun(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> ApprovedCommandRunRecord {
    guard
      let row = try database.query(
        "SELECT * FROM approved_command_runs WHERE id = ?",
        bindings: [.text(id)]
      ).first
    else {
      throw ApprovedCommandRunStoreError.runNotFound(id)
    }
    return try decodeRun(row)
  }

  private static func requireResult(
    runID: String,
    database: isolated SQLiteStore
  ) throws -> StoredResult {
    guard
      let row = try database.query(
        "SELECT * FROM approved_command_results WHERE run_id = ?",
        bindings: [.text(runID)]
      ).first
    else {
      throw ApprovedCommandRunStoreError.divergentResult
    }
    let succeeded = try integer(row, "succeeded")
    guard succeeded == 0 || succeeded == 1 else {
      throw ApprovedCommandRunStoreError.decode("succeeded")
    }
    return StoredResult(
      envelope: try blob(row, "envelope"),
      evidenceSHA256: try text(row, "evidence_sha256"),
      repositoryStateSHA256: try text(row, "repository_state_sha256"),
      succeeded: succeeded == 1
    )
  }

  private static func decodeEvidence(
    _ stored: StoredResult,
    run: ApprovedCommandRunRecord
  ) throws -> VerificationCommandEvidence {
    guard sha256(stored.envelope) == stored.evidenceSHA256,
      let evidence = try? JSONDecoder().decode(
        VerificationCommandEvidence.self,
        from: stored.envelope
      ),
      evidence.commandID == run.commandID,
      evidence.registryKind == run.registryKind,
      evidence.definitionDigest == run.definitionSHA256,
      evidence.repositoryStateSHA256 == stored.repositoryStateSHA256,
      evidence.succeeded == stored.succeeded
    else {
      throw ApprovedCommandRunStoreError.divergentResult
    }
    return evidence
  }

  private static func appendEvent(
    runID: String,
    kind: ApprovedCommandRunEventKind,
    recordSHA256: String?,
    detailCode: String?,
    at date: Date,
    database: isolated SQLiteStore
  ) throws {
    if let recordSHA256, !isSHA256(recordSHA256) {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    if let detailCode, !validDetailCode(detailCode) {
      throw ApprovedCommandRunStoreError.invalidRecord
    }
    let sequence =
      (try database.scalarInt(
        "SELECT COALESCE(MAX(sequence), 0) + 1 FROM approved_command_events WHERE run_id = ?",
        bindings: [.text(runID)]
      ) ?? 1)
    _ = try database.execute(
      """
      INSERT INTO approved_command_events(
        run_id, sequence, kind, record_sha256, detail_code, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(runID),
        .integer(sequence),
        .text(kind.rawValue),
        recordSHA256.map(SQLiteValue.text) ?? .null,
        detailCode.map(SQLiteValue.text) ?? .null,
        .real(date.timeIntervalSince1970),
      ]
    )
  }

  private static func decodeRun(_ row: SQLiteRow) throws -> ApprovedCommandRunRecord {
    guard let jobID = UUID(uuidString: try text(row, "job_id")),
      let phase = ApprovedCommandRunPhase(rawValue: try text(row, "phase")),
      let registryKind = ApprovedCommandRegistryKind(rawValue: try text(row, "registry_kind")),
      let state = ApprovedCommandRunState(rawValue: try text(row, "state"))
    else {
      throw ApprovedCommandRunStoreError.decode("approved command run")
    }
    return ApprovedCommandRunRecord(
      id: try text(row, "id"),
      jobID: jobID,
      jobAttempt: Int(try integer(row, "job_attempt")),
      jobStep: Int(try integer(row, "job_step")),
      phase: phase,
      round: Int(try integer(row, "round")),
      commandOrdinal: Int(try integer(row, "command_ordinal")),
      commandID: try text(row, "command_id"),
      planSHA256: try text(row, "plan_sha256"),
      definitionSHA256: try text(row, "definition_sha256"),
      registryKind: registryKind,
      workspace: ApprovedCommandWorkspaceIdentity(
        path: try text(row, "workspace_path"),
        device: try uint64(row, "workspace_device"),
        inode: try uint64(row, "workspace_inode")
      ),
      state: state,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  private static func decodeEvent(_ row: SQLiteRow) throws -> ApprovedCommandRunEventRecord {
    guard let kind = ApprovedCommandRunEventKind(rawValue: try text(row, "kind")) else {
      throw ApprovedCommandRunStoreError.decode("approved command event")
    }
    return ApprovedCommandRunEventRecord(
      runID: try text(row, "run_id"),
      sequence: Int(try integer(row, "sequence")),
      kind: kind,
      recordSHA256: try optionalText(row, "record_sha256"),
      detailCode: try optionalText(row, "detail_code"),
      createdAt: try date(row, "created_at")
    )
  }

  private static func encode(_ evidence: VerificationCommandEvidence) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(evidence)
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw ApprovedCommandRunStoreError.decode(column)
    }
    return value
  }

  private static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): value
    case .null: nil
    default: throw ApprovedCommandRunStoreError.decode(column)
    }
  }

  private static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw ApprovedCommandRunStoreError.decode(column)
    }
    return value
  }

  private static func blob(_ row: SQLiteRow, _ column: String) throws -> Data {
    guard case .blob(let value)? = row[column] else {
      throw ApprovedCommandRunStoreError.decode(column)
    }
    return value
  }

  private static func date(_ row: SQLiteRow, _ column: String) throws -> Date {
    guard case .real(let value)? = row[column] else {
      throw ApprovedCommandRunStoreError.decode(column)
    }
    return Date(timeIntervalSince1970: value)
  }

  private static func uint64(_ row: SQLiteRow, _ column: String) throws -> UInt64 {
    let value = try integer(row, column)
    guard value >= 0 else { throw ApprovedCommandRunStoreError.decode(column) }
    return UInt64(value)
  }

  private static func uuid(_ value: UUID) -> String {
    value.uuidString.lowercased()
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validRunID(_ value: String) -> Bool {
    value.wholeMatch(of: /^command-[0-9a-f-]{36}$/) != nil
  }

  private static func validPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 4_096 && !value.contains("\u{0}")
  }

  private static func validDetailCode(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
  }
}

extension ApprovedCommandWorkspaceIdentity {
  fileprivate init(path: String, device: UInt64, inode: UInt64) {
    self.path = path
    self.device = device
    self.inode = inode
  }
}
