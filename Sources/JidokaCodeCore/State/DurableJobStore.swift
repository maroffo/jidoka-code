import CryptoKit
import Foundation

public enum JobKind: String, CaseIterable, Codable, Sendable {
  case prReview
  case issueTriage
  case issueImplementation
  case complexPlan
}

public struct LogicalJobIdentity: Hashable, Codable, Sendable {
  public let repositoryID: UUID
  public let kind: JobKind
  public let objectNodeID: String
  public let revisionKey: String

  public init(
    repositoryID: UUID,
    kind: JobKind,
    objectNodeID: String,
    revisionKey: String
  ) {
    self.repositoryID = repositoryID
    self.kind = kind
    self.objectNodeID = objectNodeID
    self.revisionKey = revisionKey
  }
}

public struct JobRecord: Equatable, Sendable {
  public let id: UUID
  public let identity: LogicalJobIdentity
  public let objectNumber: Int?
  public let contractVersionUsed: String
  public let priority: JobPriority
  public let state: JobState
  public let currentStep: Int
  public let currentStepKind: JobStepKind?
  public let attempt: Int
  public let notBefore: Date?
  public let createdAt: Date
  public let updatedAt: Date
  public let terminalReason: String?
}

public struct ObjectDispositionRecord: Equatable, Sendable {
  public let identity: LogicalJobIdentity
  public let state: ObjectDispositionState
  public let contractVersionUsed: String
  public let lastJobID: UUID?
  public let lastMutationID: String?
  public let evidenceDigest: String?
  public let mutationGeneration: Int
  public let updatedAt: Date
}

public enum JobCreationResult: Equatable, Sendable {
  case created(JobRecord)
  case suppressed(ObjectDispositionRecord)
}

public enum JobTransitionResult: Equatable, Sendable {
  case applied(JobRecord)
  case duplicate(JobRecord)
}

public struct JobTransitionRecord: Equatable, Sendable {
  public let eventKey: String
  public let from: JobState
  public let to: JobState
  public let reason: String
  public let attemptBefore: Int
  public let attemptAfter: Int
  public let stepBefore: Int
  public let stepAfter: Int
  public let createdAt: Date
}

public struct JobStepRecord: Equatable, Sendable {
  public let jobID: UUID
  public let ordinal: Int
  public let kind: JobStepKind
  public let inputDigest: String?
  public let outputDigest: String?
  public let mutationID: String?
  public let acceptanceEvidence: String?
  public let completedAt: Date
}

public struct RepositoryLease: Equatable, Sendable {
  public let repositoryID: UUID
  public let jobID: UUID
  public let generation: Int
  public let heartbeat: Date
}

public enum IssueClaimState: String, Codable, Sendable {
  case active
  case inactive
  case consumed
  case stale
}

public struct StartupRecoveryRecord: Equatable, Sendable {
  public let persistedState: JobState
  public let job: JobRecord
  public let scheduleLateChecks: Bool
}

public struct IssueClaimRecord: Equatable, Sendable {
  public let issueNodeID: String
  public let generation: Int
  public let jobID: UUID
  public let marker: String
  public let expectedLabels: [String]
  public let desiredLabels: [String]
  public let planDigest: String?
  public let priorGeneration: Int?
  public let state: IssueClaimState
}

public enum DurableJobStoreError: Error, Equatable, Sendable {
  case invalidIdentity(String)
  case invalidEventKey
  case eventKeyOwnedByAnotherJob
  case jobNotFound(UUID)
  case dispositionNotFound
  case decode(String)
  case globalConcurrencyReached
  case dispatchSuppressed
  case repositoryAlreadyLeased(UUID)
  case leaseMissing(UUID)
  case leaseOwnedByAnotherJob
  case invalidDigest
  case stepOrdinalMismatch(expected: Int, actual: Int)
  case stepKindMismatch(expected: JobStepKind?, actual: JobStepKind)
  case completedStepCollision(jobID: UUID, ordinal: Int)
  case retryDeadlineNotReached
  case activeClaimExists(String)
  case claimNotFound(issueNodeID: String, generation: Int)
  case staleApprovalRequiresAttribution
  case maintenanceEvidenceMismatch
  case maintenanceCandidateUnsafe(UUID)
  case maintenanceBatchCollision
  case canaryEvidenceMismatch
  case canaryUnsafe(UUID)
  case canaryEffectDenied
  case canaryRecoveryRequired
}

public actor DurableJobStore {
  let database: SQLiteStore
  private let enforceApplicationDispatchGate: Bool

  public init(
    database: SQLiteStore,
    enforceApplicationDispatchGate: Bool = false
  ) {
    self.database = database
    self.enforceApplicationDispatchGate = enforceApplicationDispatchGate
  }

  public func createJob(
    id: UUID = UUID(),
    identity: LogicalJobIdentity,
    objectNumber: Int? = nil,
    contractVersionUsed: String,
    priority: JobPriority,
    firstStep: JobStepKind,
    now: Date,
    requiresDispatchEligibility: Bool = false
  ) async throws -> JobCreationResult {
    try Self.validate(identity: identity, contractVersion: contractVersionUsed)
    return try await database.transaction { database in
      if requiresDispatchEligibility {
        try Self.requireNewDispatchEligibility(database: database)
      }
      if let disposition = try Self.loadDisposition(identity, database: database),
        disposition.state.suppressesDiscovery
      {
        return .suppressed(disposition)
      }

      let idText = id.uuidString.lowercased()
      let identityBindings = Self.identityBindings(identity)
      _ = try database.execute(
        """
        INSERT INTO jobs(
          id, repository_id, kind, object_node_id, object_number, revision_key,
          contract_version_used, priority, state, current_step, current_step_kind,
          attempt, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'discovered', 0, ?, 0, ?, ?)
        """,
        bindings: [
          .text(idText),
          .text(identity.repositoryID.uuidString.lowercased()),
          .text(identity.kind.rawValue),
          .text(identity.objectNodeID),
          objectNumber.map { .integer(Int64($0)) } ?? .null,
          .text(identity.revisionKey),
          .text(contractVersionUsed),
          .integer(Int64(priority.rawValue)),
          .text(firstStep.rawValue),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      _ = try database.execute(
        """
        INSERT INTO object_dispositions(
          repository_id, kind, object_node_id, revision_key, state,
          contract_version_used, last_job_id, mutation_generation, updated_at
        ) VALUES (?, ?, ?, ?, 'inFlight', ?, ?, 0, ?)
        ON CONFLICT(repository_id, kind, object_node_id, revision_key) DO UPDATE SET
          state = 'inFlight',
          contract_version_used = excluded.contract_version_used,
          last_job_id = excluded.last_job_id,
          updated_at = excluded.updated_at
        """,
        bindings: identityBindings + [
          .text(contractVersionUsed),
          .text(idText),
          .real(now.timeIntervalSince1970),
        ]
      )

      let discovered = try Self.loadJob(id, database: database)
      let effect = try JobStateMachine.transition(
        from: .discovered,
        event: .enqueue,
        context: JobTransitionContext(now: now, reason: "logical identity discovered")
      )
      return .created(
        try Self.apply(
          effect,
          to: discovered,
          eventKey: "create:\(idText)",
          context: JobTransitionContext(now: now, reason: "logical identity discovered"),
          database: database
        )
      )
    }
  }

  public func job(id: UUID) async throws -> JobRecord? {
    try await database.query(
      "SELECT * FROM jobs WHERE id = ?",
      bindings: [.text(id.uuidString.lowercased())]
    ).first.map(Self.decodeJob)
  }

  public func jobs(nonTerminalOnly: Bool = false) async throws -> [JobRecord] {
    let predicate =
      nonTerminalOnly
      ? "WHERE state NOT IN ('succeeded', 'blocked')"
      : ""
    return try await database.query(
      "SELECT * FROM jobs \(predicate) ORDER BY priority, created_at, id"
    ).map(Self.decodeJob)
  }

  public func disposition(
    for identity: LogicalJobIdentity
  ) async throws -> ObjectDispositionRecord? {
    try await database.query(
      """
      SELECT * FROM object_dispositions
      WHERE repository_id = ? AND kind = ? AND object_node_id = ? AND revision_key = ?
      """,
      bindings: Self.identityBindings(identity)
    ).first.map(Self.decodeDisposition)
  }

  public func ambiguousDispositions() async throws -> [ObjectDispositionRecord] {
    try await database.query(
      """
      SELECT * FROM object_dispositions
      WHERE state = 'ambiguous'
      ORDER BY updated_at, repository_id, kind, object_node_id, revision_key
      """
    ).map(Self.decodeDisposition)
  }

  public func transition(
    jobID: UUID,
    eventKey: String,
    event: JobEvent,
    context: JobTransitionContext
  ) async throws -> JobTransitionResult {
    guard Self.validEventKey(eventKey) else {
      throw DurableJobStoreError.invalidEventKey
    }
    return try await database.transaction { database in
      let current = try Self.loadJob(jobID, database: database)
      if let duplicate = try database.query(
        "SELECT job_id FROM job_transitions WHERE event_key = ?",
        bindings: [.text(eventKey)]
      ).first {
        guard try Self.text(duplicate, "job_id") == jobID.uuidString.lowercased() else {
          throw DurableJobStoreError.eventKeyOwnedByAnotherJob
        }
        return .duplicate(current)
      }
      if event == .retryDeadlineReached {
        guard let notBefore = current.notBefore, notBefore <= context.now else {
          throw DurableJobStoreError.retryDeadlineNotReached
        }
      }
      let baseEffect = try JobStateMachine.transition(
        from: current.state,
        event: event,
        context: context
      )
      let effect = try Self.enforceStepInvariants(
        current: current,
        event: event,
        effect: baseEffect
      )
      try Self.applyLeaseEffect(
        effect.lease,
        job: current,
        now: context.now,
        enforceApplicationDispatchGate: enforceApplicationDispatchGate,
        database: database
      )
      return .applied(
        try Self.apply(
          effect,
          to: current,
          eventKey: eventKey,
          context: context,
          database: database
        )
      )
    }
  }

  public func appendCompletedStep(
    jobID: UUID,
    ordinal: Int,
    kind: JobStepKind,
    inputDigest: String?,
    outputDigest: String?,
    mutationID: String?,
    acceptanceEvidence: String?,
    now: Date
  ) async throws {
    for digest in [inputDigest, outputDigest].compactMap({ $0 }) where !Self.isSHA256(digest) {
      throw DurableJobStoreError.invalidDigest
    }
    try await database.transaction { database in
      let job = try Self.loadJob(jobID, database: database)
      guard ordinal == job.currentStep else {
        throw DurableJobStoreError.stepOrdinalMismatch(
          expected: job.currentStep,
          actual: ordinal
        )
      }
      guard job.currentStepKind == kind else {
        throw DurableJobStoreError.stepKindMismatch(
          expected: job.currentStepKind,
          actual: kind
        )
      }
      if let existing = try database.query(
        "SELECT * FROM job_steps WHERE job_id = ? AND ordinal = ?",
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .integer(Int64(ordinal)),
        ]
      ).first.map(Self.decodeStep) {
        guard existing.kind == kind,
          existing.inputDigest == inputDigest,
          existing.outputDigest == outputDigest,
          existing.mutationID == mutationID,
          existing.acceptanceEvidence == acceptanceEvidence
        else {
          throw DurableJobStoreError.completedStepCollision(jobID: jobID, ordinal: ordinal)
        }
        return
      }
      _ = try database.execute(
        """
        INSERT INTO job_steps(
          job_id, ordinal, kind, state, input_digest, output_digest,
          mutation_id, acceptance_evidence, completed_at
        ) VALUES (?, ?, ?, 'completed', ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .integer(Int64(ordinal)),
          .text(kind.rawValue),
          inputDigest.map(SQLiteValue.text) ?? .null,
          outputDigest.map(SQLiteValue.text) ?? .null,
          mutationID.map(SQLiteValue.text) ?? .null,
          acceptanceEvidence.map(SQLiteValue.text) ?? .null,
          .real(now.timeIntervalSince1970),
        ]
      )
    }
  }

  public func transitions(jobID: UUID) async throws -> [JobTransitionRecord] {
    try await database.query(
      "SELECT * FROM job_transitions WHERE job_id = ? ORDER BY id",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).map(Self.decodeTransition)
  }

  public func steps(jobID: UUID) async throws -> [JobStepRecord] {
    try await database.query(
      "SELECT * FROM job_steps WHERE job_id = ? ORDER BY ordinal",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).map(Self.decodeStep)
  }

  public func completedStep(
    jobID: UUID,
    ordinal: Int
  ) async throws -> JobStepRecord? {
    guard ordinal >= 0 else {
      throw DurableJobStoreError.stepOrdinalMismatch(expected: 0, actual: ordinal)
    }
    return try await database.query(
      "SELECT * FROM job_steps WHERE job_id = ? AND ordinal = ?",
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .integer(Int64(ordinal)),
      ]
    ).first.map(Self.decodeStep)
  }

  public func activeLeases() async throws -> [RepositoryLease] {
    try await database.query(
      "SELECT * FROM repository_leases WHERE active = 1 ORDER BY repository_id"
    ).map(Self.decodeLease)
  }

  public func heartbeat(jobID: UUID, now: Date) async throws {
    try await database.transaction { database in
      let changed = try database.execute(
        "UPDATE repository_leases SET heartbeat = ? WHERE job_id = ? AND active = 1",
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(jobID.uuidString.lowercased()),
        ]
      )
      guard changed == 1 else { throw DurableJobStoreError.leaseMissing(jobID) }
    }
  }

  public func recoverAtStartup(now: Date) async throws -> [StartupRecoveryRecord] {
    let startupID = UUID().uuidString.lowercased()
    return try await database.transaction { database in
      let preservedCanaryJobID = try Self.resumedCanaryRecoveryJobIDForStartup(
        database: database
      )
      let rows: [SQLiteRow]
      if let preservedCanaryJobID {
        rows = try database.query(
          "SELECT * FROM jobs WHERE id = ?",
          bindings: [.text(preservedCanaryJobID.uuidString.lowercased())]
        )
      } else {
        _ = try database.execute(
          "UPDATE repository_leases SET active = 0 WHERE active = 1"
        )
        rows = try database.query(
          """
          SELECT * FROM jobs
          WHERE state NOT IN ('succeeded', 'blocked')
          ORDER BY priority, created_at, id
          """
        )
      }
      var recovered: [StartupRecoveryRecord] = []
      for row in rows {
        let job = try Self.decodeJob(row)
        if job.id == preservedCanaryJobID {
          _ = try database.execute(
            """
            INSERT INTO reconciliation_events(
              job_id, probe, observation, classification, reason, created_at
            ) VALUES (?, 'startup', ?, ?, 'exact canary topology recovery preserved', ?)
            """,
            bindings: [
              .text(job.id.uuidString.lowercased()),
              .text(job.state.rawValue),
              .text(job.state.rawValue),
              .real(now.timeIntervalSince1970),
            ]
          )
          recovered.append(
            StartupRecoveryRecord(
              persistedState: job.state,
              job: job,
              scheduleLateChecks: false
            )
          )
          continue
        }
        let recovery = JobRecovery.recover(
          JobRuntimeSnapshot(
            state: job.state,
            attempt: job.attempt,
            currentStep: job.currentStep,
            notBefore: job.notBefore
          ),
          now: now
        )
        var resultingJob = job
        if recovery.transitionRequired {
          let eventKey = "startup:\(startupID):\(job.id.uuidString.lowercased())"
          _ = try database.execute(
            """
            UPDATE jobs
            SET state = ?, attempt = ?, not_before = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
              .text(recovery.state.rawValue),
              .integer(Int64(recovery.attempt)),
              recovery.notBefore.map { .real($0.timeIntervalSince1970) } ?? .null,
              .real(now.timeIntervalSince1970),
              .text(job.id.uuidString.lowercased()),
            ]
          )
          _ = try database.execute(
            """
            INSERT INTO job_transitions(
              job_id, event_key, from_state, to_state, reason,
              attempt_before, attempt_after, step_before, step_after, created_at
            ) VALUES (?, ?, ?, ?, 'startup recovery', ?, ?, ?, ?, ?)
            """,
            bindings: [
              .text(job.id.uuidString.lowercased()),
              .text(eventKey),
              .text(job.state.rawValue),
              .text(recovery.state.rawValue),
              .integer(Int64(job.attempt)),
              .integer(Int64(recovery.attempt)),
              .integer(Int64(job.currentStep)),
              .integer(Int64(recovery.currentStep)),
              .real(now.timeIntervalSince1970),
            ]
          )
          resultingJob = try Self.loadJob(job.id, database: database)
        }
        _ = try database.execute(
          """
          INSERT INTO reconciliation_events(
            job_id, probe, observation, classification, reason, created_at
          ) VALUES (?, 'startup', ?, ?, 'total recovery matrix', ?)
          """,
          bindings: [
            .text(job.id.uuidString.lowercased()),
            .text(job.state.rawValue),
            .text(recovery.state.rawValue),
            .real(now.timeIntervalSince1970),
          ]
        )
        recovered.append(
          StartupRecoveryRecord(
            persistedState: job.state,
            job: resultingJob,
            scheduleLateChecks: recovery.scheduleLateChecks
          )
        )
      }
      return recovered
    }
  }

  public func beginClaim(
    issueNodeID: String,
    jobID: UUID,
    kind: ClaimKind,
    marker: String,
    planDigest: String?,
    now: Date
  ) async throws -> IssueClaimRecord {
    guard !issueNodeID.isEmpty, !marker.isEmpty else {
      throw DurableJobStoreError.invalidIdentity("claim")
    }
    if kind == .approvedComplex, planDigest == nil {
      throw DurableJobStoreError.invalidDigest
    }
    if let planDigest, !Self.isSHA256(planDigest) {
      throw DurableJobStoreError.invalidDigest
    }
    return try await database.transaction { database in
      _ = try Self.loadJob(jobID, database: database)
      let activeRows = try database.query(
        "SELECT * FROM issue_claims WHERE issue_node_id = ? AND state = 'active'",
        bindings: [.text(issueNodeID)]
      )
      if let activeRow = activeRows.first {
        let active = try Self.decodeClaim(activeRow)
        guard activeRows.count == 1, active.jobID == jobID, active.marker == marker,
          active.planDigest == planDigest
        else {
          throw DurableJobStoreError.activeClaimExists(issueNodeID)
        }
        return active
      }
      let prior = try database.scalarInt(
        "SELECT MAX(generation) FROM issue_claims WHERE issue_node_id = ?",
        bindings: [.text(issueNodeID)]
      ).map(Int.init)
      let generation = (prior ?? 0) + 1
      let claim = try ClaimStateMachine.next(
        kind: kind,
        generation: generation,
        priorGeneration: prior
      )
      _ = try database.execute(
        """
        INSERT INTO issue_claims(
          issue_node_id, generation, job_id, marker, expected_labels,
          desired_labels, plan_digest, prior_generation, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
        """,
        bindings: [
          .text(issueNodeID),
          .integer(Int64(generation)),
          .text(jobID.uuidString.lowercased()),
          .text(marker),
          .text(try Self.encodeLabels(claim.expectedLabels)),
          .text(try Self.encodeLabels(claim.desiredLabels)),
          planDigest.map(SQLiteValue.text) ?? .null,
          prior.map { .integer(Int64($0)) } ?? .null,
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.loadClaim(
        issueNodeID: issueNodeID,
        generation: generation,
        database: database
      )
    }
  }

  public func finishClaim(
    issueNodeID: String,
    generation: Int,
    state: IssueClaimState,
    now: Date
  ) async throws {
    guard state != .active else {
      throw DurableJobStoreError.invalidIdentity("claim terminal state")
    }
    try await database.transaction { database in
      let changed = try database.execute(
        """
        UPDATE issue_claims SET state = ?, updated_at = ?
        WHERE issue_node_id = ? AND generation = ? AND state = 'active'
        """,
        bindings: [
          .text(state.rawValue),
          .real(now.timeIntervalSince1970),
          .text(issueNodeID),
          .integer(Int64(generation)),
        ]
      )
      if changed == 0 {
        let existing = try Self.loadClaim(
          issueNodeID: issueNodeID,
          generation: generation,
          database: database
        )
        guard existing.state == state else {
          throw DurableJobStoreError.claimNotFound(
            issueNodeID: issueNodeID,
            generation: generation
          )
        }
      }
    }
  }

  public func claims(issueNodeID: String) async throws -> [IssueClaimRecord] {
    try await database.query(
      "SELECT * FROM issue_claims WHERE issue_node_id = ? ORDER BY generation",
      bindings: [.text(issueNodeID)]
    ).map(Self.decodeClaim)
  }

  public func nextClaimGeneration(issueNodeID: String) async throws -> Int {
    guard !issueNodeID.isEmpty else {
      throw DurableJobStoreError.invalidIdentity("claim")
    }
    return try await database.transaction { database in
      let active =
        try database.scalarInt(
          "SELECT COUNT(*) FROM issue_claims WHERE issue_node_id = ? AND state = 'active'",
          bindings: [.text(issueNodeID)]
        ) ?? 0
      guard active == 0 else {
        throw DurableJobStoreError.activeClaimExists(issueNodeID)
      }
      let prior = try database.scalarInt(
        "SELECT MAX(generation) FROM issue_claims WHERE issue_node_id = ?",
        bindings: [.text(issueNodeID)]
      ).map(Int.init)
      return (prior ?? 0) + 1
    }
  }

  public func supersedeDisposition(
    _ identity: LogicalJobIdentity,
    evidenceDigest: String,
    now: Date
  ) async throws {
    guard Self.isSHA256(evidenceDigest) else {
      throw DurableJobStoreError.invalidDigest
    }
    try await database.transaction { database in
      guard try Self.loadDisposition(identity, database: database) != nil else {
        throw DurableJobStoreError.dispositionNotFound
      }
      _ = try database.execute(
        """
        UPDATE object_dispositions
        SET state = 'superseded', evidence_digest = ?, updated_at = ?
        WHERE repository_id = ? AND kind = ? AND object_node_id = ? AND revision_key = ?
        """,
        bindings: [
          .text(evidenceDigest),
          .real(now.timeIntervalSince1970),
        ] + Self.identityBindings(identity)
      )
    }
  }

  public func previewMaintenance(
    scope: JobMaintenanceScope
  ) async throws -> JobMaintenanceReport {
    try scope.validate()
    return try await database.transaction { database in
      let candidates = try Self.maintenanceCandidates(scope: scope, database: database)
      try Self.validateMaintenanceCandidates(
        candidates,
        operation: scope.operation,
        database: database
      )
      let evidence = try Self.maintenanceEvidence(
        scope: scope,
        candidates: candidates,
        database: database
      )
      return JobMaintenanceReport(
        scope: scope,
        candidateCount: candidates.count,
        evidenceSHA256: evidence,
        appliedCount: 0,
        replayed: false
      )
    }
  }

  public func applyMaintenance(
    _ authorization: JobMaintenanceAuthorization,
    now: Date
  ) async throws -> JobMaintenanceApplication {
    try authorization.validate()
    return try await database.transaction { database in
      guard
        let settings = try database.query(
          "SELECT paused FROM app_settings WHERE singleton = 1"
        ).first,
        try Self.integer(settings, "paused") == 1
      else {
        throw DurableJobStoreError.dispatchSuppressed
      }
      if let replay = try Self.replayedMaintenance(
        authorization: authorization,
        database: database
      ) {
        return replay
      }
      let candidates = try Self.maintenanceCandidates(
        scope: authorization.scope,
        database: database
      )
      try Self.validateMaintenanceCandidates(
        candidates,
        operation: authorization.scope.operation,
        database: database
      )
      let evidence = try Self.maintenanceEvidence(
        scope: authorization.scope,
        candidates: candidates,
        database: database
      )
      guard candidates.count == authorization.expectedCount,
        evidence == authorization.evidenceSHA256
      else {
        throw DurableJobStoreError.maintenanceEvidenceMismatch
      }
      let reason =
        switch authorization.scope.operation {
        case .retireBefore:
          "operator retired exact pre-activation job cohort"
        case .retryResourceFailuresAfter:
          "operator authorized retry after Pi workflow resource repair"
        }
      let event: JobEvent =
        authorization.scope.operation == .retireBefore
        ? .operatorRetire : .operatorRetryConfigurationRepair
      for candidate in candidates {
        let context = JobTransitionContext(
          now: now,
          reason: reason,
          acceptanceEvidenceDigest: authorization.evidenceSHA256
        )
        let effect = try JobStateMachine.transition(
          from: candidate.state,
          event: event,
          context: context
        )
        guard effect.lease == .none else {
          throw DurableJobStoreError.maintenanceCandidateUnsafe(candidate.id)
        }
        let eventKey = Self.maintenanceEventKey(
          operation: authorization.scope.operation,
          boundaryEpochSeconds: authorization.scope.boundaryEpochSeconds,
          evidence: authorization.evidenceSHA256,
          jobID: candidate.id
        )
        guard Self.validEventKey(eventKey) else {
          throw DurableJobStoreError.invalidEventKey
        }
        _ = try Self.apply(
          effect,
          to: candidate,
          eventKey: eventKey,
          context: context,
          database: database
        )
      }
      return JobMaintenanceApplication(
        report: JobMaintenanceReport(
          scope: authorization.scope,
          candidateCount: candidates.count,
          evidenceSHA256: authorization.evidenceSHA256,
          appliedCount: candidates.count,
          replayed: false
        ),
        jobIDs: candidates.map(\.id)
      )
    }
  }

  private struct MaintenanceEvidenceEnvelope: Codable {
    let operation: String
    let boundaryEpochSeconds: Int64
    let candidates: [MaintenanceCandidateEvidence]
  }

  private struct MaintenanceCandidateEvidence: Codable {
    let id: String
    let repositoryID: String
    let kind: String
    let objectNodeID: String
    let objectNumber: Int?
    let revisionKey: String
    let contractVersionUsed: String
    let priority: Int
    let state: String
    let attempt: Int
    let currentStep: Int
    let currentStepKind: String?
    let notBeforeBits: String?
    let createdAtBits: String
    let updatedAtBits: String
    let terminalReason: String?
    let disposition: MaintenanceDispositionEvidence
    let mutationIntents: [MaintenanceMutationEvidence]
    let jobSteps: [MaintenanceJobStepEvidence]
    let issueClaims: [MaintenanceIssueClaimEvidence]
    let workspace: MaintenanceWorkspaceEvidence?
  }

  private struct MaintenanceDispositionEvidence: Codable {
    let state: String
    let contractVersionUsed: String
    let lastJobID: String?
    let lastMutationID: String?
    let evidenceDigest: String?
    let mutationGeneration: Int
    let updatedAtBits: String
  }

  private struct MaintenanceMutationEvidence: Codable {
    let id: String
    let idempotencyKey: String
    let operation: String
    let target: String
    let expectedStateDigest: String
    let requestDigest: String
    let state: String
    let sendEpoch: Int64
    let readBackEvidence: String?
    let createdAtBits: String
    let updatedAtBits: String
  }

  private struct MaintenanceJobStepEvidence: Codable {
    let ordinal: Int64
    let kind: String
    let state: String
    let inputDigest: String?
    let outputDigest: String?
    let mutationID: String?
    let acceptanceEvidence: String?
    let completedAtBits: String
  }

  private struct MaintenanceIssueClaimEvidence: Codable {
    let issueNodeID: String
    let generation: Int64
    let marker: String
    let expectedLabels: String
    let desiredLabels: String
    let planDigest: String?
    let priorGeneration: Int64?
    let state: String
    let createdAtBits: String
    let updatedAtBits: String
  }

  private struct MaintenanceWorkspaceEvidence: Codable {
    let relativePath: String
    let baseBranch: String
    let baseSHA: String
    let localHeadSHA: String
    let cleanupState: String
    let updatedAtBits: String
  }

  private static let resourceFailureTerminalReason =
    "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError"

  private static func maintenanceCandidates(
    scope: JobMaintenanceScope,
    database: isolated SQLiteStore
  ) throws -> [JobRecord] {
    let comparison: String
    let predicate: String
    switch scope.operation {
    case .retireBefore:
      comparison = "jobs.created_at < ?"
      predicate =
        """
        jobs.state IN ('queued', 'blocked')
        AND NOT EXISTS (
          SELECT 1 FROM object_dispositions
          WHERE object_dispositions.repository_id = jobs.repository_id
            AND object_dispositions.kind = jobs.kind
            AND object_dispositions.object_node_id = jobs.object_node_id
            AND object_dispositions.revision_key = jobs.revision_key
            AND object_dispositions.state = 'superseded'
        )
        """
    case .retryResourceFailuresAfter:
      comparison = "created_at >= ?"
      predicate = "state = 'blocked' AND terminal_reason = ?"
    }
    var bindings: [SQLiteValue] = [.real(Double(scope.boundaryEpochSeconds))]
    if scope.operation == .retryResourceFailuresAfter {
      bindings.append(.text(resourceFailureTerminalReason))
    }
    return try database.query(
      """
      SELECT jobs.* FROM jobs
      WHERE \(comparison) AND \(predicate)
      ORDER BY jobs.created_at, jobs.id
      LIMIT 1025
      """,
      bindings: bindings
    ).map(decodeJob)
  }

  private static func validateMaintenanceCandidates(
    _ candidates: [JobRecord],
    operation: JobMaintenanceOperation,
    database: isolated SQLiteStore
  ) throws {
    guard candidates.count <= 1_024 else {
      throw DurableJobStoreError.maintenanceEvidenceMismatch
    }
    for candidate in candidates {
      let validState =
        switch operation {
        case .retireBefore:
          candidate.state == .queued || candidate.state == .blocked
        case .retryResourceFailuresAfter:
          candidate.state == .blocked
            && candidate.terminalReason == resourceFailureTerminalReason
        }
      guard validState,
        try loadDisposition(candidate.identity, database: database) != nil,
        try database.scalarInt(
          "SELECT COUNT(*) FROM repository_leases WHERE job_id = ? AND active = 1",
          bindings: [.text(candidate.id.uuidString.lowercased())]
        ) == 0,
        try database.scalarInt(
          "SELECT COUNT(*) FROM pi_runs WHERE job_id = ?",
          bindings: [.text(candidate.id.uuidString.lowercased())]
        ) == 0,
        try database.scalarInt(
          "SELECT COUNT(*) FROM approved_command_runs WHERE job_id = ?",
          bindings: [.text(candidate.id.uuidString.lowercased())]
        ) == 0
      else {
        throw DurableJobStoreError.maintenanceCandidateUnsafe(candidate.id)
      }
      let mutationStates = try database.query(
        "SELECT state FROM mutation_intents WHERE job_id = ? ORDER BY id",
        bindings: [.text(candidate.id.uuidString.lowercased())]
      ).map { try text($0, "state") }
      switch operation {
      case .retireBefore:
        guard mutationStates.allSatisfy({ $0 == "attributed" }) else {
          throw DurableJobStoreError.maintenanceCandidateUnsafe(candidate.id)
        }
      case .retryResourceFailuresAfter:
        guard mutationStates.isEmpty,
          try database.scalarInt(
            "SELECT COUNT(*) FROM job_steps WHERE job_id = ?",
            bindings: [.text(candidate.id.uuidString.lowercased())]
          ) == 0
        else {
          throw DurableJobStoreError.maintenanceCandidateUnsafe(candidate.id)
        }
      }
    }
  }

  private static func bits(_ value: Double) -> String {
    String(value.bitPattern, radix: 16)
  }

  private static func maintenanceEvidence(
    scope: JobMaintenanceScope,
    candidates: [JobRecord],
    database: isolated SQLiteStore
  ) throws -> String {
    let evidenceCandidates = try candidates.map { candidate in
      let jobID = candidate.id.uuidString.lowercased()
      guard let disposition = try loadDisposition(candidate.identity, database: database) else {
        throw DurableJobStoreError.maintenanceCandidateUnsafe(candidate.id)
      }
      let mutations = try database.query(
        "SELECT * FROM mutation_intents WHERE job_id = ? ORDER BY id",
        bindings: [.text(jobID)]
      ).map { row in
        MaintenanceMutationEvidence(
          id: try text(row, "id"),
          idempotencyKey: try text(row, "idempotency_key"),
          operation: try text(row, "operation"),
          target: try text(row, "target"),
          expectedStateDigest: try text(row, "expected_state_digest"),
          requestDigest: try text(row, "request_digest"),
          state: try text(row, "state"),
          sendEpoch: try integer(row, "send_epoch"),
          readBackEvidence: try optionalText(row, "read_back_evidence"),
          createdAtBits: bits(try real(row, "created_at")),
          updatedAtBits: bits(try real(row, "updated_at"))
        )
      }
      let steps = try database.query(
        "SELECT * FROM job_steps WHERE job_id = ? ORDER BY ordinal",
        bindings: [.text(jobID)]
      ).map { row in
        MaintenanceJobStepEvidence(
          ordinal: try integer(row, "ordinal"),
          kind: try text(row, "kind"),
          state: try text(row, "state"),
          inputDigest: try optionalText(row, "input_digest"),
          outputDigest: try optionalText(row, "output_digest"),
          mutationID: try optionalText(row, "mutation_id"),
          acceptanceEvidence: try optionalText(row, "acceptance_evidence"),
          completedAtBits: bits(try real(row, "completed_at"))
        )
      }
      let claims = try database.query(
        "SELECT * FROM issue_claims WHERE job_id = ? ORDER BY issue_node_id, generation",
        bindings: [.text(jobID)]
      ).map { row in
        MaintenanceIssueClaimEvidence(
          issueNodeID: try text(row, "issue_node_id"),
          generation: try integer(row, "generation"),
          marker: try text(row, "marker"),
          expectedLabels: try text(row, "expected_labels"),
          desiredLabels: try text(row, "desired_labels"),
          planDigest: try optionalText(row, "plan_digest"),
          priorGeneration: try optionalInteger(row, "prior_generation"),
          state: try text(row, "state"),
          createdAtBits: bits(try real(row, "created_at")),
          updatedAtBits: bits(try real(row, "updated_at"))
        )
      }
      let workspace = try database.query(
        "SELECT * FROM workspaces WHERE job_id = ?",
        bindings: [.text(jobID)]
      ).first.map { row in
        MaintenanceWorkspaceEvidence(
          relativePath: try text(row, "relative_path"),
          baseBranch: try text(row, "base_branch"),
          baseSHA: try text(row, "base_sha"),
          localHeadSHA: try text(row, "local_head_sha"),
          cleanupState: try text(row, "cleanup_state"),
          updatedAtBits: bits(try real(row, "updated_at"))
        )
      }
      return MaintenanceCandidateEvidence(
        id: jobID,
        repositoryID: candidate.identity.repositoryID.uuidString.lowercased(),
        kind: candidate.identity.kind.rawValue,
        objectNodeID: candidate.identity.objectNodeID,
        objectNumber: candidate.objectNumber,
        revisionKey: candidate.identity.revisionKey,
        contractVersionUsed: candidate.contractVersionUsed,
        priority: candidate.priority.rawValue,
        state: candidate.state.rawValue,
        attempt: candidate.attempt,
        currentStep: candidate.currentStep,
        currentStepKind: candidate.currentStepKind?.rawValue,
        notBeforeBits: candidate.notBefore.map { bits($0.timeIntervalSince1970) },
        createdAtBits: bits(candidate.createdAt.timeIntervalSince1970),
        updatedAtBits: bits(candidate.updatedAt.timeIntervalSince1970),
        terminalReason: candidate.terminalReason,
        disposition: MaintenanceDispositionEvidence(
          state: disposition.state.rawValue,
          contractVersionUsed: disposition.contractVersionUsed,
          lastJobID: disposition.lastJobID?.uuidString.lowercased(),
          lastMutationID: disposition.lastMutationID,
          evidenceDigest: disposition.evidenceDigest,
          mutationGeneration: disposition.mutationGeneration,
          updatedAtBits: bits(disposition.updatedAt.timeIntervalSince1970)
        ),
        mutationIntents: mutations,
        jobSteps: steps,
        issueClaims: claims,
        workspace: workspace
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      MaintenanceEvidenceEnvelope(
        operation: scope.operation.rawValue,
        boundaryEpochSeconds: scope.boundaryEpochSeconds,
        candidates: evidenceCandidates
      )
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func replayedMaintenance(
    authorization: JobMaintenanceAuthorization,
    database: isolated SQLiteStore
  ) throws -> JobMaintenanceApplication? {
    let prefix = maintenanceEventPrefix(
      operation: authorization.scope.operation,
      boundaryEpochSeconds: authorization.scope.boundaryEpochSeconds,
      evidence: authorization.evidenceSHA256
    )
    let rows = try database.query(
      """
      SELECT job_id FROM job_transitions
      WHERE event_key GLOB ?
      ORDER BY job_id
      LIMIT 1025
      """,
      bindings: [.text(prefix + "*")]
    )
    guard !rows.isEmpty else { return nil }
    guard rows.count == authorization.expectedCount else {
      throw DurableJobStoreError.maintenanceBatchCollision
    }
    let jobIDs = try rows.map { row -> UUID in
      guard let id = UUID(uuidString: try text(row, "job_id")) else {
        throw DurableJobStoreError.maintenanceBatchCollision
      }
      return id
    }
    guard Set(jobIDs).count == authorization.expectedCount else {
      throw DurableJobStoreError.maintenanceBatchCollision
    }
    for jobID in jobIDs {
      let job = try loadJob(jobID, database: database)
      let disposition = try loadDisposition(job.identity, database: database)
      let insideScope =
        authorization.scope.operation == .retireBefore
        ? job.createdAt.timeIntervalSince1970 < Double(authorization.scope.boundaryEpochSeconds)
        : job.createdAt.timeIntervalSince1970 >= Double(authorization.scope.boundaryEpochSeconds)
      let settled =
        switch authorization.scope.operation {
        case .retireBefore:
          job.state == .blocked && disposition?.state == .superseded
        case .retryResourceFailuresAfter:
          job.state == .queued && job.terminalReason == nil
            && disposition?.state == .humanRetryAuthorized
        }
      guard insideScope, settled else {
        throw DurableJobStoreError.maintenanceBatchCollision
      }
    }
    return JobMaintenanceApplication(
      report: JobMaintenanceReport(
        scope: authorization.scope,
        candidateCount: authorization.expectedCount,
        evidenceSHA256: authorization.evidenceSHA256,
        appliedCount: authorization.expectedCount,
        replayed: true
      ),
      jobIDs: jobIDs
    )
  }

  private static func maintenanceEventKey(
    operation: JobMaintenanceOperation,
    boundaryEpochSeconds: Int64,
    evidence: String,
    jobID: UUID
  ) -> String {
    maintenanceEventPrefix(
      operation: operation,
      boundaryEpochSeconds: boundaryEpochSeconds,
      evidence: evidence
    ) + jobID.uuidString.lowercased()
  }

  private static func maintenanceEventPrefix(
    operation: JobMaintenanceOperation,
    boundaryEpochSeconds: Int64,
    evidence: String
  ) -> String {
    "maintenance:\(operation.rawValue):\(boundaryEpochSeconds):\(evidence):"
  }

  private static func enforceStepInvariants(
    current: JobRecord,
    event: JobEvent,
    effect: JobTransitionEffect
  ) throws -> JobTransitionEffect {
    guard current.currentStepKind == .consumeStaleApproval else { return effect }
    if current.state == .executing, event == .localStepCompletedMore {
      throw DurableJobStoreError.staleApprovalRequiresAttribution
    }
    guard current.state == .reconciling, event == .effectAttributedMore else {
      return effect
    }
    return JobTransitionEffect(
      from: effect.from,
      to: effect.to,
      lease: effect.lease,
      attemptDelta: effect.attemptDelta,
      stepDelta: effect.stepDelta,
      deadline: effect.deadline,
      nextStep: .replan,
      disposition: effect.disposition,
      mutationGenerationDelta: effect.mutationGenerationDelta,
      terminalReason: effect.terminalReason,
      clearsTerminalReason: effect.clearsTerminalReason
    )
  }

  private static func apply(
    _ effect: JobTransitionEffect,
    to current: JobRecord,
    eventKey: String,
    context: JobTransitionContext,
    database: isolated SQLiteStore
  ) throws -> JobRecord {
    let nextAttempt = current.attempt + effect.attemptDelta
    let nextStep = current.currentStep + effect.stepDelta
    let nextDeadline: Date? =
      switch effect.deadline {
      case .retain: current.notBefore
      case .clear: nil
      case .set(let date): date
      }
    let nextStepKind = effect.nextStep ?? current.currentStepKind
    let terminalReason =
      effect.clearsTerminalReason
      ? nil : effect.terminalReason ?? current.terminalReason

    _ = try database.execute(
      """
      UPDATE jobs
      SET state = ?, current_step = ?, current_step_kind = ?, attempt = ?,
          not_before = ?, updated_at = ?, terminal_reason = ?
      WHERE id = ?
      """,
      bindings: [
        .text(effect.to.rawValue),
        .integer(Int64(nextStep)),
        nextStepKind.map { .text($0.rawValue) } ?? .null,
        .integer(Int64(nextAttempt)),
        nextDeadline.map { .real($0.timeIntervalSince1970) } ?? .null,
        .real(context.now.timeIntervalSince1970),
        terminalReason.map(SQLiteValue.text) ?? .null,
        .text(current.id.uuidString.lowercased()),
      ]
    )
    _ = try database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason, artifact_id,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(current.id.uuidString.lowercased()),
        .text(eventKey),
        .text(effect.from.rawValue),
        .text(effect.to.rawValue),
        .text(context.reason),
        context.artifactID.map(SQLiteValue.text) ?? .null,
        .integer(Int64(current.attempt)),
        .integer(Int64(nextAttempt)),
        .integer(Int64(current.currentStep)),
        .integer(Int64(nextStep)),
        .real(context.now.timeIntervalSince1970),
      ]
    )
    if let disposition = effect.disposition {
      _ = try database.execute(
        """
        UPDATE object_dispositions
        SET state = ?, evidence_digest = COALESCE(?, evidence_digest),
            mutation_generation = mutation_generation + ?, updated_at = ?
        WHERE repository_id = ? AND kind = ? AND object_node_id = ? AND revision_key = ?
        """,
        bindings: [
          .text(disposition.rawValue),
          context.acceptanceEvidenceDigest.map(SQLiteValue.text) ?? .null,
          .integer(Int64(effect.mutationGenerationDelta)),
          .real(context.now.timeIntervalSince1970),
        ] + identityBindings(current.identity)
      )
    }
    if effect.to == .waitingHuman || effect.to == .succeeded || effect.to == .blocked {
      _ = try database.execute(
        """
        UPDATE issue_claims
        SET state = 'inactive', updated_at = ?
        WHERE job_id = ? AND state = 'active'
        """,
        bindings: [
          .real(context.now.timeIntervalSince1970),
          .text(current.id.uuidString.lowercased()),
        ]
      )
    }
    return try loadJob(current.id, database: database)
  }

  private static func requireNewDispatchEligibility(
    database: isolated SQLiteStore
  ) throws {
    guard
      let settings = try database.query(
        "SELECT * FROM app_settings WHERE singleton = 1"
      ).first,
      try integer(settings, "paused") == 0,
      try integer(settings, "onboarding_complete") == 1,
      try integer(settings, "external_automation_acknowledged") == 1,
      try integer(settings, "provider_disclosure_acknowledged") == 1,
      try integer(settings, "login_item_selected") == 1,
      try text(settings, "login_item_status") == LifecycleServiceStatus.enabled.rawValue
    else {
      throw DurableJobStoreError.dispatchSuppressed
    }
  }

  private static func applyLeaseEffect(
    _ effect: JobLeaseEffect,
    job: JobRecord,
    now: Date,
    enforceApplicationDispatchGate: Bool,
    database: isolated SQLiteStore
  ) throws {
    switch effect {
    case .none:
      return
    case .acquire, .acquireRecovery:
      if effect == .acquire, enforceApplicationDispatchGate {
        try requireNewDispatchEligibility(database: database)
      }
      let maxConcurrency = Int(
        try database.scalarInt(
          "SELECT max_concurrency FROM app_settings WHERE singleton = 1"
        ) ?? 0
      )
      let activeCount = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM repository_leases WHERE active = 1"
        ) ?? 0
      )
      guard activeCount < maxConcurrency else {
        throw DurableJobStoreError.globalConcurrencyReached
      }
      let existing = try database.query(
        "SELECT * FROM repository_leases WHERE repository_id = ?",
        bindings: [.text(job.identity.repositoryID.uuidString.lowercased())]
      ).first
      if let existing {
        let active = try integer(existing, "active") == 1
        if active {
          throw DurableJobStoreError.repositoryAlreadyLeased(job.identity.repositoryID)
        }
        _ = try database.execute(
          """
          UPDATE repository_leases
          SET job_id = ?, generation = generation + 1, heartbeat = ?, active = 1
          WHERE repository_id = ?
          """,
          bindings: [
            .text(job.id.uuidString.lowercased()),
            .real(now.timeIntervalSince1970),
            .text(job.identity.repositoryID.uuidString.lowercased()),
          ]
        )
      } else {
        _ = try database.execute(
          """
          INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
          VALUES (?, ?, 1, ?, 1)
          """,
          bindings: [
            .text(job.identity.repositoryID.uuidString.lowercased()),
            .text(job.id.uuidString.lowercased()),
            .real(now.timeIntervalSince1970),
          ]
        )
      }
    case .retain:
      let count =
        try database.scalarInt(
          "SELECT COUNT(*) FROM repository_leases WHERE repository_id = ? AND job_id = ? AND active = 1",
          bindings: [
            .text(job.identity.repositoryID.uuidString.lowercased()),
            .text(job.id.uuidString.lowercased()),
          ]
        ) ?? 0
      guard count == 1 else { throw DurableJobStoreError.leaseMissing(job.id) }
    case .release, .clearStale:
      let rows = try database.query(
        "SELECT job_id, active FROM repository_leases WHERE repository_id = ?",
        bindings: [.text(job.identity.repositoryID.uuidString.lowercased())]
      )
      guard let row = rows.first else {
        if effect == .clearStale { return }
        throw DurableJobStoreError.leaseMissing(job.id)
      }
      guard try text(row, "job_id") == job.id.uuidString.lowercased() else {
        throw DurableJobStoreError.leaseOwnedByAnotherJob
      }
      if try integer(row, "active") == 1 {
        _ = try database.execute(
          "UPDATE repository_leases SET active = 0, heartbeat = ? WHERE repository_id = ?",
          bindings: [
            .real(now.timeIntervalSince1970),
            .text(job.identity.repositoryID.uuidString.lowercased()),
          ]
        )
      }
    }
  }

  private static func loadJob(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> JobRecord {
    guard let job = try loadJobIfPresent(id, database: database) else {
      throw DurableJobStoreError.jobNotFound(id)
    }
    return job
  }

  private static func loadJobIfPresent(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> JobRecord? {
    try database.query(
      "SELECT * FROM jobs WHERE id = ?",
      bindings: [.text(id.uuidString.lowercased())]
    ).first.map(decodeJob)
  }

  private static func loadDisposition(
    _ identity: LogicalJobIdentity,
    database: isolated SQLiteStore
  ) throws -> ObjectDispositionRecord? {
    try database.query(
      """
      SELECT * FROM object_dispositions
      WHERE repository_id = ? AND kind = ? AND object_node_id = ? AND revision_key = ?
      """,
      bindings: identityBindings(identity)
    ).first.map(decodeDisposition)
  }

  private static func decodeJob(_ row: SQLiteRow) throws -> JobRecord {
    let id = try uuid(row, "id")
    let repositoryID = try uuid(row, "repository_id")
    guard let kind = JobKind(rawValue: try text(row, "kind")) else {
      throw DurableJobStoreError.decode("unknown job kind")
    }
    guard let priority = JobPriority(rawValue: Int(try integer(row, "priority"))) else {
      throw DurableJobStoreError.decode("unknown priority")
    }
    guard let state = JobState(rawValue: try text(row, "state")) else {
      throw DurableJobStoreError.decode("unknown job state")
    }
    let stepKind: JobStepKind?
    if let rawStep = try optionalText(row, "current_step_kind") {
      guard let decoded = JobStepKind(rawValue: rawStep) else {
        throw DurableJobStoreError.decode("unknown step kind")
      }
      stepKind = decoded
    } else {
      stepKind = nil
    }
    return JobRecord(
      id: id,
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: kind,
        objectNodeID: try text(row, "object_node_id"),
        revisionKey: try text(row, "revision_key")
      ),
      objectNumber: try optionalInteger(row, "object_number").map(Int.init),
      contractVersionUsed: try text(row, "contract_version_used"),
      priority: priority,
      state: state,
      currentStep: Int(try integer(row, "current_step")),
      currentStepKind: stepKind,
      attempt: Int(try integer(row, "attempt")),
      notBefore: try optionalReal(row, "not_before").map(Date.init(timeIntervalSince1970:)),
      createdAt: Date(timeIntervalSince1970: try real(row, "created_at")),
      updatedAt: Date(timeIntervalSince1970: try real(row, "updated_at")),
      terminalReason: try optionalText(row, "terminal_reason")
    )
  }

  private static func decodeDisposition(_ row: SQLiteRow) throws -> ObjectDispositionRecord {
    guard let kind = JobKind(rawValue: try text(row, "kind")),
      let state = ObjectDispositionState(rawValue: try text(row, "state"))
    else {
      throw DurableJobStoreError.decode("unknown disposition value")
    }
    return ObjectDispositionRecord(
      identity: LogicalJobIdentity(
        repositoryID: try uuid(row, "repository_id"),
        kind: kind,
        objectNodeID: try text(row, "object_node_id"),
        revisionKey: try text(row, "revision_key")
      ),
      state: state,
      contractVersionUsed: try text(row, "contract_version_used"),
      lastJobID: try optionalText(row, "last_job_id").flatMap(UUID.init(uuidString:)),
      lastMutationID: try optionalText(row, "last_mutation_id"),
      evidenceDigest: try optionalText(row, "evidence_digest"),
      mutationGeneration: Int(try integer(row, "mutation_generation")),
      updatedAt: Date(timeIntervalSince1970: try real(row, "updated_at"))
    )
  }

  private static func decodeTransition(_ row: SQLiteRow) throws -> JobTransitionRecord {
    guard let from = JobState(rawValue: try text(row, "from_state")),
      let to = JobState(rawValue: try text(row, "to_state"))
    else {
      throw DurableJobStoreError.decode("unknown transition state")
    }
    return JobTransitionRecord(
      eventKey: try text(row, "event_key"),
      from: from,
      to: to,
      reason: try text(row, "reason"),
      attemptBefore: Int(try integer(row, "attempt_before")),
      attemptAfter: Int(try integer(row, "attempt_after")),
      stepBefore: Int(try integer(row, "step_before")),
      stepAfter: Int(try integer(row, "step_after")),
      createdAt: Date(timeIntervalSince1970: try real(row, "created_at"))
    )
  }

  private static func decodeStep(_ row: SQLiteRow) throws -> JobStepRecord {
    guard let kind = JobStepKind(rawValue: try text(row, "kind")),
      try text(row, "state") == "completed"
    else {
      throw DurableJobStoreError.decode("unknown job step value")
    }
    return JobStepRecord(
      jobID: try uuid(row, "job_id"),
      ordinal: Int(try integer(row, "ordinal")),
      kind: kind,
      inputDigest: try optionalText(row, "input_digest"),
      outputDigest: try optionalText(row, "output_digest"),
      mutationID: try optionalText(row, "mutation_id"),
      acceptanceEvidence: try optionalText(row, "acceptance_evidence"),
      completedAt: Date(timeIntervalSince1970: try real(row, "completed_at"))
    )
  }

  private static func decodeLease(_ row: SQLiteRow) throws -> RepositoryLease {
    RepositoryLease(
      repositoryID: try uuid(row, "repository_id"),
      jobID: try uuid(row, "job_id"),
      generation: Int(try integer(row, "generation")),
      heartbeat: Date(timeIntervalSince1970: try real(row, "heartbeat"))
    )
  }

  private static func loadClaim(
    issueNodeID: String,
    generation: Int,
    database: isolated SQLiteStore
  ) throws -> IssueClaimRecord {
    guard
      let row = try database.query(
        "SELECT * FROM issue_claims WHERE issue_node_id = ? AND generation = ?",
        bindings: [.text(issueNodeID), .integer(Int64(generation))]
      ).first
    else {
      throw DurableJobStoreError.claimNotFound(
        issueNodeID: issueNodeID,
        generation: generation
      )
    }
    return try decodeClaim(row)
  }

  private static func decodeClaim(_ row: SQLiteRow) throws -> IssueClaimRecord {
    guard let state = IssueClaimState(rawValue: try text(row, "state")) else {
      throw DurableJobStoreError.decode("unknown claim state")
    }
    return IssueClaimRecord(
      issueNodeID: try text(row, "issue_node_id"),
      generation: Int(try integer(row, "generation")),
      jobID: try uuid(row, "job_id"),
      marker: try text(row, "marker"),
      expectedLabels: try decodeLabels(text(row, "expected_labels")),
      desiredLabels: try decodeLabels(text(row, "desired_labels")),
      planDigest: try optionalText(row, "plan_digest"),
      priorGeneration: try optionalInteger(row, "prior_generation").map(Int.init),
      state: state
    )
  }

  private static func encodeLabels(_ labels: [String]) throws -> String {
    let data = try JSONEncoder().encode(labels)
    guard let value = String(data: data, encoding: .utf8) else {
      throw DurableJobStoreError.decode("could not encode claim labels")
    }
    return value
  }

  private static func decodeLabels(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else {
      throw DurableJobStoreError.decode("could not decode claim labels")
    }
    return try JSONDecoder().decode([String].self, from: data)
  }

  private static func validate(
    identity: LogicalJobIdentity,
    contractVersion: String
  ) throws {
    for (name, value) in [
      ("object node id", identity.objectNodeID),
      ("revision key", identity.revisionKey),
      ("contract version", contractVersion),
    ] {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 256, trimmed == value else {
        throw DurableJobStoreError.invalidIdentity(name)
      }
    }
  }

  private static func identityBindings(
    _ identity: LogicalJobIdentity
  ) -> [SQLiteValue] {
    [
      .text(identity.repositoryID.uuidString.lowercased()),
      .text(identity.kind.rawValue),
      .text(identity.objectNodeID),
      .text(identity.revisionKey),
    ]
  }

  private static func validEventKey(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 200 else { return false }
    return value.allSatisfy { character in
      character.isLetter || character.isNumber || ":._-".contains(character)
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 64
      && bytes.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw DurableJobStoreError.decode("expected text column \(column)")
    }
    return value
  }

  private static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): value
    case .null: nil
    default: throw DurableJobStoreError.decode("expected optional text column \(column)")
    }
  }

  private static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw DurableJobStoreError.decode("expected integer column \(column)")
    }
    return value
  }

  private static func optionalInteger(_ row: SQLiteRow, _ column: String) throws -> Int64? {
    switch row[column] {
    case .integer(let value): value
    case .null: nil
    default: throw DurableJobStoreError.decode("expected optional integer column \(column)")
    }
  }

  private static func real(_ row: SQLiteRow, _ column: String) throws -> Double {
    switch row[column] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: throw DurableJobStoreError.decode("expected real column \(column)")
    }
  }

  private static func optionalReal(_ row: SQLiteRow, _ column: String) throws -> Double? {
    switch row[column] {
    case .real(let value): value
    case .integer(let value): Double(value)
    case .null: nil
    default: throw DurableJobStoreError.decode("expected optional real column \(column)")
    }
  }

  private static func uuid(_ row: SQLiteRow, _ column: String) throws -> UUID {
    let value = try text(row, column)
    guard let uuid = UUID(uuidString: value) else {
      throw DurableJobStoreError.decode("expected UUID column \(column)")
    }
    return uuid
  }
}
