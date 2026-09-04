import CryptoKit
import Foundation

extension RolloutAuthorityStore {
  struct EffectBinding: Sendable {
    let authorizationID: String
    let stage: RolloutWorkflowStage
    let repositoryID: UUID
    let repositoryNodeID: String
    let repository: GitHubRepositoryCoordinates
    let objectNodeID: String
    let objectNumber: Int
    let revisionKey: String
    let canonicalInputSHA256: String
    let narrativeSHA256: String?
    let hasInputSnapshot: Bool
    let jobState: JobState
    let currentStepKind: JobStepKind
    let preview: RolloutPreview

    var scope: RolloutScope { preview.payload.scope }
  }

  func reserveJobEffect(
    jobID: UUID,
    kind: RolloutEffectKind,
    operationSHA256: String,
    targetSHA256: String,
    cost: RolloutEffectCost,
    requestedOrdinal: Int? = nil,
    mutationIntentID: UUID? = nil,
    attempt: Int = 1,
    reuseExactReservation: Bool = false,
    reattachRecoveredReservation: Bool = false,
    now: Date,
    validate: @escaping @Sendable (EffectBinding, isolated SQLiteStore) throws -> Void
  ) async throws -> RolloutEffectPermit {
    guard effectAdmissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    try cost.validate(for: kind)
    guard GitHubInputValidation.validSHA256(operationSHA256),
      GitHubInputValidation.validSHA256(targetSHA256),
      requestedOrdinal.map({ $0 >= 0 }) ?? true,
      attempt > 0
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let reattachmentClaim =
      reattachRecoveredReservation
      ? Self.digest([
        "recovery-reattach-v1", jobID.uuidString.lowercased(), kind.rawValue,
        operationSHA256, targetSHA256,
        mutationIntentID?.uuidString.lowercased() ?? "", String(attempt),
      ]) : nil
    if let reattachmentClaim,
      !effectReattachmentClaims.insert(reattachmentClaim).inserted
    {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    defer {
      if let reattachmentClaim {
        effectReattachmentClaims.remove(reattachmentClaim)
      }
    }
    let id = UUID().uuidString.lowercased()
    let nowMilliseconds = Self.milliseconds(now)
    let reservation = try await database.transaction { database -> (String, Bool) in
      let binding = try Self.loadActiveBinding(
        jobID: jobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      if binding.scope.mode == .finiteWindow,
        !binding.hasInputSnapshot,
        kind != .githubRead,
        kind != .gitRemoteRead
      {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try validate(binding, database)
      if reattachRecoveredReservation {
        let recovered = try database.query(
          """
          SELECT effect.*
          FROM rollout_effect_reservations AS effect
          JOIN rollout_authorizations AS authorization
            ON authorization.id = effect.authorization_id
          WHERE effect.authorization_id = ? AND effect.job_id = ?
            AND effect.kind = ? AND effect.operation_sha256 = ?
            AND effect.target_sha256 = ? AND effect.state = 'reserved'
            AND effect.mutation_intent_id IS ?
            AND authorization.scope_mode = 'exactObject'
            AND EXISTS (
              SELECT 1 FROM rollout_authorization_events AS event
              WHERE event.authorization_id = authorization.id
                AND event.kind = 'recoveryActivated'
                AND event.created_at_ms >= effect.updated_at_ms
            )
          ORDER BY effect.created_at_ms, effect.id
          """,
          bindings: [
            .text(binding.authorizationID), .text(jobID.uuidString.lowercased()),
            .text(kind.rawValue), .text(operationSHA256), .text(targetSHA256),
            mutationIntentID.map { .text($0.uuidString.lowercased()) } ?? .null,
          ]
        )
        guard recovered.count <= 1 else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        if let row = recovered.first {
          let existing = try Self.decodeReservation(row)
          guard existing.request.cost == cost,
            existing.request.attempt == attempt
          else {
            throw RolloutAuthorityError.effectIdentityMismatch
          }
          return (existing.id, true)
        }
      }
      let ordinal: Int
      if let requestedOrdinal {
        ordinal = requestedOrdinal
      } else {
        ordinal = Int(
          try database.scalarInt(
            "SELECT COUNT(*) FROM rollout_effect_reservations WHERE authorization_id = ? AND kind = ?",
            bindings: [.text(binding.authorizationID), .text(kind.rawValue)]
          ) ?? 0
        )
      }
      let request = RolloutEffectReservationRequest(
        authorizationID: binding.authorizationID,
        jobID: jobID,
        kind: kind,
        operationSHA256: operationSHA256,
        targetSHA256: targetSHA256,
        ordinal: ordinal,
        attempt: attempt,
        cost: cost,
        mutationIntentID: mutationIntentID?.uuidString.lowercased()
      )
      let existing = try database.query(
        """
        SELECT * FROM rollout_effect_reservations
        WHERE authorization_id = ? AND job_id = ? AND kind = ?
          AND ordinal = ? AND attempt = ?
        ORDER BY id
        """,
        bindings: [
          .text(binding.authorizationID), .text(jobID.uuidString.lowercased()),
          .text(kind.rawValue), .integer(Int64(ordinal)), .integer(Int64(attempt)),
        ]
      )
      if !existing.isEmpty {
        guard reuseExactReservation, existing.count == 1,
          let row = existing.first,
          try Self.text(row, "operation_sha256") == operationSHA256,
          try Self.text(row, "target_sha256") == targetSHA256,
          try Self.text(row, "state") == RolloutEffectReservationState.reserved.rawValue,
          try Self.optionalText(row, "mutation_intent_id")
            == mutationIntentID?.uuidString.lowercased(),
          try Self.decodeReservation(row).request.cost == cost
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        return (try Self.text(row, "id"), false)
      }
      try Self.requireBudget(
        authorizationID: binding.authorizationID,
        kind: kind,
        cost: cost,
        database: database
      )
      _ = try database.execute(
        """
        INSERT INTO rollout_effect_reservations(
          id, authorization_id, job_id, kind, operation_sha256, target_sha256,
          ordinal, attempt, github_read_requests, github_read_pages,
          github_read_bytes, git_remote_reads, provider_sessions, approved_commands,
          marker_parts, label_writes, branch_creates, pull_request_creates,
          github_sends, git_sends, state, mutation_intent_id,
          created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          'reserved', ?, ?, ?)
        """,
        bindings: Self.reservationBindings(
          id: id,
          request: request,
          nowMilliseconds: nowMilliseconds
        )
      )
      try Self.insertEvent(
        authorizationID: binding.authorizationID,
        eventKey: "reserve:\(id)",
        kind: .effectReserved,
        from: .active,
        to: .active,
        reasonCode: kind.rawValue,
        checkpointSHA256: operationSHA256,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      return (id, false)
    }
    if reservation.1,
      inFlightEffectPermits.contains(reservation.0)
        || verifiedReadPermits.contains(reservation.0)
    {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    inFlightEffectPermits.insert(reservation.0)
    return .reservation(id: reservation.0)
  }

  func reserveScopeRead(
    _ effect: RolloutGitHubReadEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard effectAdmissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let operationSHA256 = try Self.githubOperationSHA256(effect.operation)
    let targetSHA256 = try Self.githubTargetSHA256(effect.operation)
    let id = UUID().uuidString.lowercased()
    let nowMilliseconds = Self.milliseconds(now)
    let reservationID = try await database.transaction { database in
      guard
        let row = try database.query(
          """
          SELECT authorization.id, authorization.repository_id,
            authorization.workflow_stage, scope.preview_json
          FROM rollout_authorizations AS authorization
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = authorization.id
          JOIN app_settings AS settings ON settings.singleton = 1
          WHERE authorization.state = 'active'
            AND authorization.scope_mode = 'finiteWindow'
            AND authorization.expires_at_ms > ?
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
          """,
          bindings: [.integer(nowMilliseconds)]
        ).first,
        let stage = RolloutWorkflowStage(rawValue: try Self.text(row, "workflow_stage")),
        let data = try Self.text(row, "preview_json").data(using: .utf8)
      else {
        throw RolloutAuthorityError.effectAdmissionClosed
      }
      let preview = try RolloutPreviewBuilder.parseCanonical(data)
      guard
        let repositoryID = UUID(uuidString: try Self.text(row, "repository_id")),
        repositoryID.uuidString.lowercased() == preview.payload.scope.repository.id,
        let settings = try database.query(
          "SELECT github_account, github_author_id, max_concurrency FROM app_settings WHERE singleton = 1"
        ).first
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let local = try Self.localEvidence(
        repositoryID: repositoryID,
        scope: preview.payload.scope,
        authorizationID: try Self.text(row, "id"),
        database: database
      )
      guard
        local.repositoryConfigurationSHA256
          == preview.payload.releaseIdentity.repositoryConfigurationSHA256,
        local.modelProfilesSHA256 == preview.payload.releaseIdentity.modelProfilesSHA256,
        local.inventory == preview.payload.inventory
          || local.inventory.hasMatchingOutsideScope(preview.payload.inventory),
        try Self.optionalText(settings, "github_account")
          == preview.payload.releaseIdentity.githubAccount,
        try Self.optionalInteger(settings, "github_author_id")
          == preview.payload.releaseIdentity.githubAuthorID,
        try Self.integer(settings, "max_concurrency") == 1
      else {
        throw RolloutAuthorityError.previewDrift
      }
      try Self.validateDiscovery(
        operation: effect.operation, stage: stage, scope: preview.payload.scope)
      let authorizationID = try Self.text(row, "id")
      try Self.requireBudget(
        authorizationID: authorizationID,
        kind: .githubRead,
        cost: RolloutEffectCost(
          githubReadRequests: 1,
          githubReadPages: 1,
          githubReadBytes: effect.maximumResponseBytes
        ),
        database: database
      )
      let ordinal = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_scope_read_reservations WHERE authorization_id = ?",
          bindings: [.text(authorizationID)]
        ) ?? 0
      )
      _ = try database.execute(
        """
        INSERT INTO rollout_scope_read_reservations(
          id, authorization_id, operation_sha256, target_sha256, ordinal,
          github_read_requests, github_read_pages, github_read_bytes,
          state, evidence_sha256, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, 1, 1, ?, 'reserved', NULL, ?, ?)
        """,
        bindings: [
          .text(id), .text(authorizationID), .text(operationSHA256),
          .text(targetSHA256), .integer(Int64(ordinal)),
          .integer(effect.maximumResponseBytes), .integer(nowMilliseconds),
          .integer(nowMilliseconds),
        ]
      )
      return id
    }
    inFlightEffectPermits.insert(reservationID)
    return .scopeRead(id: reservationID)
  }

  func reserveReadback(
    _ effect: RolloutGitHubReadEffect,
    jobID: UUID,
    intentID: UUID,
    now: Date
  ) async throws -> RolloutEffectPermit {
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let operationSHA256 = try Self.githubOperationSHA256(effect.operation)
    let targetSHA256 = try Self.githubTargetSHA256(effect.operation)
    let reattachmentClaim = Self.digest([
      "github-readback-reattach-v1", jobID.uuidString.lowercased(),
      intentID.uuidString.lowercased(), operationSHA256, targetSHA256,
    ])
    guard effectReattachmentClaims.insert(reattachmentClaim).inserted else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    defer { effectReattachmentClaims.remove(reattachmentClaim) }
    let id = UUID().uuidString.lowercased()
    let nowMilliseconds = Self.milliseconds(now)
    let reservation = try await database.transaction { database -> (String, Bool) in
      guard
        let source = try database.query(
          """
          SELECT effect.id, effect.authorization_id, scope.preview_json,
            intent.operation AS mutation_operation, intent.target AS mutation_target
          FROM rollout_effect_reservations AS effect
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = effect.authorization_id
          JOIN mutation_intents AS intent ON intent.id = effect.mutation_intent_id
          WHERE effect.job_id = ? AND effect.mutation_intent_id = ?
            AND effect.state IN ('sendStarted', 'observationRequired')
          ORDER BY effect.attempt DESC, effect.created_at_ms DESC LIMIT 1
          """,
          bindings: [
            .text(jobID.uuidString.lowercased()),
            .text(intentID.uuidString.lowercased()),
          ]
        ).first,
        let data = try Self.text(source, "preview_json").data(using: .utf8)
      else {
        throw RolloutAuthorityError.readbackNotAllowed
      }
      let preview = try RolloutPreviewBuilder.parseCanonical(data)
      guard
        let mutation = MutationOperation(
          rawValue: try Self.text(source, "mutation_operation")
        )
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.validateReadback(
        operation: effect.operation,
        mutation: mutation,
        target: try Self.text(source, "mutation_target"),
        scope: preview.payload.scope
      )
      let authorizationID = try Self.text(source, "authorization_id")
      let sourceID = try Self.text(source, "id")
      let existing = try database.query(
        """
        SELECT id FROM rollout_readback_reservations
        WHERE authorization_id = ? AND job_id = ? AND source_reservation_id = ?
          AND operation_sha256 = ? AND target_sha256 = ? AND state = 'reserved'
        ORDER BY created_at_ms, id
        """,
        bindings: [
          .text(authorizationID), .text(jobID.uuidString.lowercased()),
          .text(sourceID), .text(operationSHA256), .text(targetSHA256),
        ]
      )
      guard existing.count <= 1 else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      if let row = existing.first {
        return (try Self.text(row, "id"), true)
      }
      try Self.requireBudget(
        authorizationID: authorizationID,
        kind: .githubRead,
        cost: RolloutEffectCost(
          githubReadRequests: 1,
          githubReadPages: 1,
          githubReadBytes: effect.maximumResponseBytes
        ),
        database: database
      )
      let ordinal = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_readback_reservations WHERE source_reservation_id = ?",
          bindings: [.text(sourceID)]
        ) ?? 0
      )
      _ = try database.execute(
        """
        INSERT INTO rollout_readback_reservations(
          id, authorization_id, job_id, source_reservation_id,
          operation_sha256, target_sha256, ordinal,
          github_read_requests, github_read_pages, github_read_bytes,
          state, evidence_sha256, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 1, ?, 'reserved', NULL, ?, ?)
        """,
        bindings: [
          .text(id), .text(authorizationID), .text(jobID.uuidString.lowercased()),
          .text(sourceID), .text(operationSHA256), .text(targetSHA256),
          .integer(Int64(ordinal)), .integer(effect.maximumResponseBytes),
          .integer(nowMilliseconds), .integer(nowMilliseconds),
        ]
      )
      return (id, false)
    }
    if reservation.1,
      inFlightEffectPermits.contains(reservation.0)
        || verifiedReadPermits.contains(reservation.0)
    {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    inFlightEffectPermits.insert(reservation.0)
    return .readback(id: reservation.0)
  }

  func reserveGitReadback(
    _ effect: RolloutGitRemoteReadEffect,
    intentID: UUID,
    now: Date
  ) async throws -> RolloutEffectPermit {
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let operationSHA256 = Self.digest([
      "git-remote-read-v1", effect.operation.rawValue,
      effect.repositoryID.uuidString.lowercased(), effect.repositoryNodeID, effect.target,
    ])
    let targetSHA256 = Self.digest([effect.repositoryNodeID, effect.target])
    let reattachmentClaim = Self.digest([
      "git-readback-reattach-v1", effect.jobID.uuidString.lowercased(),
      intentID.uuidString.lowercased(), operationSHA256, targetSHA256,
    ])
    guard effectReattachmentClaims.insert(reattachmentClaim).inserted else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    defer { effectReattachmentClaims.remove(reattachmentClaim) }
    let id = UUID().uuidString.lowercased()
    let nowMilliseconds = Self.milliseconds(now)
    let reservation = try await database.transaction { database -> (String, Bool) in
      guard
        let source = try database.query(
          """
          SELECT effect.id, effect.authorization_id, scope.repository_node_id,
            authorization.repository_id
          FROM rollout_effect_reservations AS effect
          JOIN rollout_authorizations AS authorization
            ON authorization.id = effect.authorization_id
          JOIN rollout_authorization_scopes AS scope
            ON scope.authorization_id = effect.authorization_id
          WHERE effect.job_id = ? AND effect.mutation_intent_id = ?
            AND effect.kind = 'branchCreate'
            AND effect.state IN ('sendStarted', 'observationRequired')
          ORDER BY effect.attempt DESC, effect.created_at_ms DESC LIMIT 1
          """,
          bindings: [
            .text(effect.jobID.uuidString.lowercased()),
            .text(intentID.uuidString.lowercased()),
          ]
        ).first,
        try Self.text(source, "repository_id")
          == effect.repositoryID.uuidString.lowercased(),
        try Self.text(source, "repository_node_id") == effect.repositoryNodeID
      else {
        throw RolloutAuthorityError.readbackNotAllowed
      }
      let authorizationID = try Self.text(source, "authorization_id")
      let sourceID = try Self.text(source, "id")
      let existing = try database.query(
        """
        SELECT id FROM rollout_git_readback_reservations
        WHERE authorization_id = ? AND job_id = ? AND source_reservation_id = ?
          AND operation_sha256 = ? AND target_sha256 = ? AND state = 'reserved'
        ORDER BY created_at_ms, id
        """,
        bindings: [
          .text(authorizationID), .text(effect.jobID.uuidString.lowercased()),
          .text(sourceID), .text(operationSHA256), .text(targetSHA256),
        ]
      )
      guard existing.count <= 1 else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      if let row = existing.first {
        return (try Self.text(row, "id"), true)
      }
      try Self.requireBudget(
        authorizationID: authorizationID,
        kind: .gitRemoteRead,
        cost: RolloutEffectCost(gitRemoteReads: 1),
        database: database
      )
      let ordinal = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_git_readback_reservations WHERE source_reservation_id = ?",
          bindings: [.text(sourceID)]
        ) ?? 0
      )
      _ = try database.execute(
        """
        INSERT INTO rollout_git_readback_reservations(
          id, authorization_id, job_id, source_reservation_id,
          operation_sha256, target_sha256, ordinal, git_remote_reads,
          state, evidence_sha256, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'reserved', NULL, ?, ?)
        """,
        bindings: [
          .text(id), .text(authorizationID),
          .text(effect.jobID.uuidString.lowercased()), .text(sourceID),
          .text(operationSHA256), .text(targetSHA256), .integer(Int64(ordinal)),
          .integer(nowMilliseconds), .integer(nowMilliseconds),
        ]
      )
      return (id, false)
    }
    if reservation.1,
      inFlightEffectPermits.contains(reservation.0)
        || verifiedReadPermits.contains(reservation.0)
    {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    inFlightEffectPermits.insert(reservation.0)
    return .gitReadback(id: reservation.0)
  }

  static func requireBudget(
    authorizationID: String,
    kind: RolloutEffectKind,
    cost: RolloutEffectCost,
    database: isolated SQLiteStore
  ) throws {
    guard
      let row = try database.query(
        """
        SELECT budget.github_read_requests AS budget_github_read_requests,
          budget.github_read_pages AS budget_github_read_pages,
          budget.github_read_bytes AS budget_github_read_bytes,
          budget.git_remote_reads AS budget_git_remote_reads,
          budget.provider_sessions AS budget_provider_sessions,
          budget.approved_commands AS budget_approved_commands,
          budget.marker_parts AS budget_marker_parts,
          budget.label_writes AS budget_label_writes,
          budget.branch_creates AS budget_branch_creates,
          budget.pull_request_creates AS budget_pull_request_creates,
          budget.github_sends AS budget_github_sends,
          budget.git_sends AS budget_git_sends,
          usage.github_read_requests, usage.github_read_pages,
          usage.github_read_bytes, usage.git_remote_reads,
          usage.provider_sessions, usage.approved_commands, usage.marker_parts,
          usage.label_writes, usage.branch_creates, usage.pull_request_creates,
          usage.github_sends, usage.git_sends
        FROM rollout_authorization_budgets AS budget
        JOIN rollout_authorization_usage AS usage
          ON usage.authorization_id = budget.authorization_id
        WHERE budget.authorization_id = ?
        ORDER BY usage.sequence DESC LIMIT 1
        """,
        bindings: [.text(authorizationID)]
      ).first
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let comparisons: [(String, String, Int64)] = [
      ("github_read_requests", "budget_github_read_requests", Int64(cost.githubReadRequests)),
      ("github_read_pages", "budget_github_read_pages", Int64(cost.githubReadPages)),
      ("github_read_bytes", "budget_github_read_bytes", cost.githubReadBytes),
      ("git_remote_reads", "budget_git_remote_reads", Int64(cost.gitRemoteReads)),
      ("provider_sessions", "budget_provider_sessions", Int64(cost.providerSessions)),
      ("approved_commands", "budget_approved_commands", Int64(cost.approvedCommands)),
      ("marker_parts", "budget_marker_parts", Int64(cost.markerParts)),
      ("label_writes", "budget_label_writes", Int64(cost.labelWrites)),
      ("branch_creates", "budget_branch_creates", Int64(cost.branchCreates)),
      (
        "pull_request_creates", "budget_pull_request_creates",
        Int64(cost.pullRequestCreates)
      ),
      ("github_sends", "budget_github_sends", Int64(cost.githubSends)),
      ("git_sends", "budget_git_sends", Int64(cost.gitSends)),
    ]
    for (usageColumn, budgetColumn, increment) in comparisons
    where try integer(row, usageColumn) + increment > integer(row, budgetColumn) {
      throw RolloutAuthorityError.budgetExceeded(kind)
    }
  }

  func settleReadTable(
    table: String,
    id: String,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    guard
      table == "rollout_scope_read_reservations"
        || table == "rollout_readback_reservations"
        || table == "rollout_git_readback_reservations"
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let changed = try await database.execute(
      "UPDATE \(table) SET state = 'settled', evidence_sha256 = ?, updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ? AND state = 'reserved'",
      bindings: [
        .text(evidenceSHA256), .integer(Self.milliseconds(now)), .text(id),
      ]
    )
    guard changed == 1 else { throw RolloutAuthorityError.invalidStateTransition }
  }

  /// `JobCanaryScope` is historical evidence, never a source of fresh authority.
  ///
  /// The return type is `Never` on purpose: it makes every historical-canary branch
  /// terminal at compile time, so no `return .historicalCanary(...)` can sit beside it
  /// and no later edit can restore the bypass by re-conditioning a single line. A
  /// recovery that needs a fresh provider, command, Git, GitHub, or generated-review
  /// effect must hold an ordinary matching schema-10 `.workflow` authorization.
  func requireHistoricalCanary(jobID: UUID) async throws -> Never {
    _ = jobID
    throw RolloutAuthorityError.effectAdmissionClosed
  }
}

extension RolloutAuthorityStore {
  public func reserveMarkerBatch(
    _ effect: RolloutMarkerBatchEffect,
    now: Date
  ) async throws -> [RolloutEffectPermit] {
    guard effectAdmissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    guard (1...64).contains(effect.intentIDs.count),
      Set(effect.intentIDs).count == effect.intentIDs.count,
      effect.objectNumber > 0,
      effect.authorID > 0,
      effect.generation >= 0,
      GitHubInputValidation.validSHA256(effect.documentSHA256),
      Self.markerOperations.contains(effect.operation)
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    if case .historicalCanary(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    {
      try await requireHistoricalCanary(jobID: jobID)
    }
    guard case .workflow(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let nowMilliseconds = Self.milliseconds(now)
    let ids = try await database.transaction { database in
      let binding = try Self.loadActiveBinding(
        jobID: effect.jobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      guard binding.repositoryID == effect.repositoryID,
        binding.repositoryNodeID == effect.repositoryNodeID,
        binding.repository.owner.caseInsensitiveCompare(effect.repository.owner) == .orderedSame,
        binding.repository.repository.caseInsensitiveCompare(effect.repository.repository)
          == .orderedSame,
        binding.objectNodeID == effect.objectNodeID,
        binding.objectNumber == effect.objectNumber,
        Self.validMarkerRevision(effect.revision, markerKind: effect.markerKind, binding: binding),
        binding.preview.payload.releaseIdentity.githubAuthorID == effect.authorID,
        Self.marker(
          effect.markerKind,
          operation: effect.operation,
          binding: binding
        )
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let firstOrdinal = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_effect_reservations WHERE authorization_id = ? AND kind = 'markerBatch'",
          bindings: [.text(binding.authorizationID)]
        ) ?? 0
      )
      var reservationIDs: [String] = []
      reservationIDs.reserveCapacity(effect.intentIDs.count)
      for (offset, intentID) in effect.intentIDs.enumerated() {
        let intent = try Self.loadIntent(id: intentID, database: database)
        guard intent.jobID == effect.jobID,
          intent.operation == effect.operation,
          intent.target == effect.expectedTarget,
          intent.expectedStateSHA256 == effect.documentSHA256,
          intent.state == .prepared || intent.state == .retryAllowed
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        let attempt = intent.sendEpoch + 1
        if let existing = try database.query(
          """
          SELECT id FROM rollout_effect_reservations
          WHERE authorization_id = ? AND job_id = ? AND kind = 'markerBatch'
            AND mutation_intent_id = ? AND attempt = ?
          """,
          bindings: [
            .text(binding.authorizationID), .text(effect.jobID.uuidString.lowercased()),
            .text(intentID.uuidString.lowercased()), .integer(Int64(attempt)),
          ]
        ).first {
          reservationIDs.append(try Self.text(existing, "id"))
          continue
        }
        let id = UUID().uuidString.lowercased()
        let request = RolloutEffectReservationRequest(
          authorizationID: binding.authorizationID,
          jobID: effect.jobID,
          kind: .markerBatch,
          operationSHA256: intent.requestSHA256,
          targetSHA256: Self.digest([
            "marker-target-v1", intent.target, effect.documentSHA256,
            String(effect.generation), String(offset),
          ]),
          ordinal: firstOrdinal + offset,
          attempt: attempt,
          cost: RolloutEffectCost(markerParts: 1, githubSends: 1),
          mutationIntentID: intentID.uuidString.lowercased()
        )
        try Self.insertReservation(
          id: id,
          request: request,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
        try Self.insertEvent(
          authorizationID: binding.authorizationID,
          eventKey: "reserve:\(id)",
          kind: .effectReserved,
          from: .active,
          to: .active,
          reasonCode: RolloutEffectKind.markerBatch.rawValue,
          checkpointSHA256: intent.requestSHA256,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
        reservationIDs.append(id)
      }
      return reservationIDs
    }
    return ids.map { .reservation(id: $0) }
  }

  public func reserveGitHubSendAndMarkStarted(
    _ effect: RolloutGitHubSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard effectAdmissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    guard effect.operation.kind.isWrite,
      GitHubInputValidation.validSHA256(effect.expectedStateSHA256),
      GitHubInputValidation.validSHA256(effect.requestSHA256),
      effect.requestSHA256 == (try Self.githubRequestSHA256(effect.operation)),
      Self.allows(mutation: effect.mutation, operation: effect.operation.kind),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      if case .historicalCanary(let jobID) = RolloutEffectTaskContext.current?.mode,
        jobID == effect.jobID
      {
        try await requireHistoricalCanary(jobID: jobID)
      }
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let nowMilliseconds = Self.milliseconds(now)
    let reservationID = try await database.transaction { database in
      let binding = try Self.loadActiveBinding(
        jobID: effect.jobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.validate(operation: effect.operation, binding: binding)
      try Self.validateMutationPreview(effect, binding: binding)
      let intent = try Self.loadIntent(id: effect.intentID, database: database)
      guard intent.jobID == effect.jobID,
        intent.operation == effect.mutation,
        intent.target == effect.target,
        intent.expectedStateSHA256 == effect.expectedStateSHA256,
        intent.requestSHA256 == effect.requestSHA256,
        intent.state == .prepared || intent.state == .retryAllowed
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let attempt = intent.sendEpoch + 1
      let kind = Self.effectKind(mutation: effect.mutation, operation: effect.operation.kind)
      let id: String
      if kind == .markerBatch {
        guard
          let row = try database.query(
            """
            SELECT id FROM rollout_effect_reservations
            WHERE authorization_id = ? AND job_id = ? AND kind = 'markerBatch'
              AND operation_sha256 = ? AND mutation_intent_id = ?
              AND attempt = ? AND state = 'reserved'
            """,
            bindings: [
              .text(binding.authorizationID), .text(effect.jobID.uuidString.lowercased()),
              .text(effect.requestSHA256), .text(effect.intentID.uuidString.lowercased()),
              .integer(Int64(attempt)),
            ]
          ).first
        else {
          throw RolloutAuthorityError.effectAdmissionClosed
        }
        id = try Self.text(row, "id")
      } else {
        id = UUID().uuidString.lowercased()
        let ordinal = Int(
          try database.scalarInt(
            "SELECT COUNT(*) FROM rollout_effect_reservations WHERE authorization_id = ? AND kind = ?",
            bindings: [.text(binding.authorizationID), .text(kind.rawValue)]
          ) ?? 0
        )
        let request = RolloutEffectReservationRequest(
          authorizationID: binding.authorizationID,
          jobID: effect.jobID,
          kind: kind,
          operationSHA256: effect.requestSHA256,
          targetSHA256: Self.digest([
            "github-send-target-v1", effect.target, effect.expectedStateSHA256,
            effect.mutation.rawValue,
          ]),
          ordinal: ordinal,
          attempt: attempt,
          cost: Self.cost(for: kind),
          mutationIntentID: effect.intentID.uuidString.lowercased()
        )
        try Self.insertReservation(
          id: id,
          request: request,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
        try Self.insertEvent(
          authorizationID: binding.authorizationID,
          eventKey: "reserve:\(id)",
          kind: .effectReserved,
          from: .active,
          to: .active,
          reasonCode: kind.rawValue,
          checkpointSHA256: effect.requestSHA256,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
      }
      try Self.markIntentAndReservationStarted(
        intent: intent,
        reservationID: id,
        authorizationID: binding.authorizationID,
        now: now,
        database: database
      )
      return id
    }
    inFlightEffectPermits.insert(reservationID)
    return .reservation(id: reservationID)
  }

  public func reserveGitSendAndMarkStarted(
    _ effect: RolloutGitSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard effectAdmissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    guard GitHubInputValidation.validGitSHA(effect.exactSHA),
      GitHubInputValidation.validSHA256(effect.expectedStateSHA256),
      GitHubInputValidation.validSHA256(effect.requestSHA256),
      GitBranchPolicy.validImplementationBranch(effect.branch),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let nowMilliseconds = Self.milliseconds(now)
    let reservationID = try await database.transaction { database in
      let binding = try Self.loadActiveBinding(
        jobID: effect.jobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      guard binding.stage == .implementationExecute,
        binding.jobState == .executing,
        binding.currentStepKind == .push,
        binding.repositoryID == effect.repositoryID,
        binding.repositoryNodeID == effect.repositoryNodeID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let intent = try Self.loadIntent(id: effect.intentID, database: database)
      guard intent.jobID == effect.jobID,
        intent.operation == .publishBranch,
        intent.target == effect.target,
        intent.expectedStateSHA256 == effect.expectedStateSHA256,
        intent.requestSHA256 == effect.requestSHA256,
        intent.state == .prepared || intent.state == .retryAllowed
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let id = UUID().uuidString.lowercased()
      let ordinal = Int(
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_effect_reservations WHERE authorization_id = ? AND kind = 'branchCreate'",
          bindings: [.text(binding.authorizationID)]
        ) ?? 0
      )
      let request = RolloutEffectReservationRequest(
        authorizationID: binding.authorizationID,
        jobID: effect.jobID,
        kind: .branchCreate,
        operationSHA256: effect.requestSHA256,
        targetSHA256: Self.gitTargetSHA256(effect),
        ordinal: ordinal,
        attempt: intent.sendEpoch + 1,
        cost: RolloutEffectCost(branchCreates: 1, gitSends: 1),
        mutationIntentID: effect.intentID.uuidString.lowercased()
      )
      try Self.insertReservation(
        id: id,
        request: request,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.insertEvent(
        authorizationID: binding.authorizationID,
        eventKey: "reserve:\(id)",
        kind: .effectReserved,
        from: .active,
        to: .active,
        reasonCode: RolloutEffectKind.branchCreate.rawValue,
        checkpointSHA256: effect.requestSHA256,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.markIntentAndReservationStarted(
        intent: intent,
        reservationID: id,
        authorizationID: binding.authorizationID,
        now: now,
        database: database
      )
      return id
    }
    inFlightEffectPermits.insert(reservationID)
    return .reservation(id: reservationID)
  }

  public func verifyGitHubSendPermit(
    _ permit: RolloutEffectPermit,
    operation: GitHubOperation
  ) async throws {
    switch permit {
    case .reservation(let id):
      guard effectAdmissionOpen else {
        throw RolloutAuthorityError.effectAdmissionClosed
      }
      guard operation.kind.isWrite,
        inFlightEffectPermits.contains(id),
        case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let operationSHA256 = try Self.githubRequestSHA256(operation)
      effectAdmissionsInProgress += 1
      defer { effectAdmissionsInProgress -= 1 }
      let now = currentTime()
      try await database.transaction { database in
        let reservation = try Self.requireReservation(id: id, database: database)
        let binding = try Self.loadActiveBinding(
          jobID: contextualJobID,
          nowMilliseconds: Self.milliseconds(now),
          database: database
        )
        guard reservation.state == .sendStarted,
          reservation.request.authorizationID == binding.authorizationID,
          reservation.request.jobID == contextualJobID,
          reservation.request.operationSHA256 == operationSHA256,
          reservation.request.cost.githubSends == 1,
          let mutationIntentID = reservation.request.mutationIntentID,
          let intentID = UUID(uuidString: mutationIntentID)
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        let intent = try Self.loadIntent(id: intentID, database: database)
        guard intent.jobID == contextualJobID,
          intent.requestSHA256 == operationSHA256
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        try Self.validateMutation(
          operation: operation,
          mutation: intent.operation,
          binding: binding
        )
        try Self.markTransportBoundary(
          reservation: reservation,
          now: now,
          database: database
        )
      }
    case .historicalCanary(let jobID):
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try await requireHistoricalCanary(jobID: jobID)
    default:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func verifyGitSendPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitSendEffect
  ) async throws {
    guard effectAdmissionOpen else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    guard case .reservation(let id) = permit else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    guard inFlightEffectPermits.contains(id),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let now = currentTime()
    try await database.transaction { database in
      let reservation = try Self.requireReservation(id: id, database: database)
      let binding = try Self.loadActiveBinding(
        jobID: contextualJobID,
        nowMilliseconds: Self.milliseconds(now),
        database: database
      )
      guard reservation.state == .sendStarted,
        reservation.request.authorizationID == binding.authorizationID,
        reservation.request.jobID == contextualJobID,
        reservation.request.kind == .branchCreate,
        reservation.request.operationSHA256 == effect.requestSHA256,
        reservation.request.targetSHA256 == Self.gitTargetSHA256(effect),
        reservation.request.cost.gitSends == 1,
        reservation.request.mutationIntentID == effect.intentID.uuidString.lowercased(),
        binding.jobState == .executing,
        binding.currentStepKind == .push
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.markTransportBoundary(
        reservation: reservation,
        now: now,
        database: database
      )
    }
  }

  public func recordMutationObservation(
    intentID: UUID,
    observation: RolloutMutationObservation,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    guard GitHubInputValidation.validSHA256(evidenceSHA256) else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let executionContext = RolloutEffectTaskContext.current
    if case .historicalCanary(let jobID) = executionContext?.mode {
      try await requireHistoricalCanary(jobID: jobID)
    }
    let terminalID = try await database.transaction { database -> String? in
      guard
        let row = try database.query(
          """
          SELECT effect.id, effect.authorization_id, effect.state, effect.operation_sha256,
            effect.job_id, intent.state AS intent_state
          FROM rollout_effect_reservations AS effect
          JOIN mutation_intents AS intent ON intent.id = effect.mutation_intent_id
          WHERE effect.mutation_intent_id = ?
          ORDER BY effect.attempt DESC, effect.created_at_ms DESC LIMIT 1
          """,
          bindings: [.text(intentID.uuidString.lowercased())]
        ).first
      else {
        guard
          let intent = try database.query(
            """
            SELECT intent.job_id, intent.state, job.rollout_generation
            FROM mutation_intents AS intent
            JOIN jobs AS job ON job.id = intent.job_id
            WHERE intent.id = ?
            """,
            bindings: [.text(intentID.uuidString.lowercased())]
          ).first,
          let jobID = UUID(uuidString: try Self.text(intent, "job_id")),
          try Self.integer(intent, "rollout_generation") == 0,
          let intentState = MutationIntentState(rawValue: try Self.text(intent, "state"))
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        // No `.historicalCanary` arm: the guard before this transaction already threw
        // for that mode, so only a readback can reach here.
        switch executionContext?.mode {
        case .readback(let contextualJobID, let contextualIntentID):
          guard contextualJobID == jobID,
            contextualIntentID == intentID,
            intentState == .sendStarted || intentState == .reconcileRequired
              || intentState == .attributed || intentState == .escalated
          else {
            throw RolloutAuthorityError.readbackNotAllowed
          }
        default:
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        return nil
      }
      let id = try Self.text(row, "id")
      guard let jobID = UUID(uuidString: try Self.text(row, "job_id")) else {
        throw RolloutAuthorityError.decode("rollout mutation observation job")
      }
      switch executionContext?.mode {
      case .workflow(let contextualJobID):
        guard contextualJobID == jobID else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
      case .readback(let contextualJobID, let contextualIntentID):
        guard contextualJobID == jobID, contextualIntentID == intentID else {
          throw RolloutAuthorityError.readbackNotAllowed
        }
      default:
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      guard
        let current = RolloutEffectReservationState(
          rawValue: try Self.text(row, "state")
        )
      else {
        throw RolloutAuthorityError.decode("rollout mutation observation")
      }
      let target: RolloutEffectReservationState =
        switch observation {
        case .observationRequired: .observationRequired
        case .attributed: .attributed
        case .settled: .settled
        }
      let intentState = MutationIntentState(rawValue: try Self.text(row, "intent_state"))
      if current == target || current == .settled { return id }
      let allowed: Bool =
        switch (current, target) {
        case (.reserved, .settled): intentState?.isTerminal == true
        case (.sendStarted, .observationRequired), (.sendStarted, .attributed),
          (.sendStarted, .settled), (.observationRequired, .attributed),
          (.observationRequired, .settled), (.attributed, .settled):
          true
        default:
          false
        }
      guard allowed else { throw RolloutAuthorityError.invalidStateTransition }
      _ = try database.execute(
        "UPDATE rollout_effect_reservations SET state = ?, updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ? AND state = ?",
        bindings: [
          .text(target.rawValue), .integer(Self.milliseconds(now)), .text(id),
          .text(current.rawValue),
        ]
      )
      let authorizationID = try Self.text(row, "authorization_id")
      let state = try Self.authorizationState(id: authorizationID, database: database)
      try Self.insertEvent(
        authorizationID: authorizationID,
        eventKey: "observe:\(id):\(target.rawValue)",
        kind: .effectObserved,
        from: state,
        to: state,
        reasonCode: "MUTATION_\(target.rawValue)",
        checkpointSHA256: evidenceSHA256,
        nowMilliseconds: Self.milliseconds(now),
        database: database
      )
      return id
    }
    if let terminalID { inFlightEffectPermits.remove(terminalID) }
  }

}

extension RolloutAuthorityStore {
  static func markTransportBoundary(
    reservation: RolloutEffectReservation,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    let changed = try database.execute(
      "UPDATE rollout_effect_reservations SET state = 'observationRequired', updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ? AND state = 'sendStarted'",
      bindings: [
        .integer(milliseconds(now)), .text(reservation.id),
      ]
    )
    guard changed == 1 else { throw RolloutAuthorityError.invalidStateTransition }
    let authorizationState = try authorizationState(
      id: reservation.request.authorizationID,
      database: database
    )
    try insertEvent(
      authorizationID: reservation.request.authorizationID,
      eventKey: "transport-boundary:\(reservation.id)",
      kind: .effectObserved,
      from: authorizationState,
      to: authorizationState,
      reasonCode: "TRANSPORT_BOUNDARY",
      checkpointSHA256: reservation.request.operationSHA256,
      nowMilliseconds: milliseconds(now),
      database: database
    )
  }
}

extension RolloutAuthorityStore {
  static func loadActiveBinding(
    jobID: UUID,
    nowMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws -> EffectBinding {
    guard
      let row = try database.query(
        """
        SELECT authorization.id AS authorization_id,
          authorization.workflow_stage, authorization.repository_id,
          authorization.preview_sha256,
          scope.repository_node_id, scope.repository_owner, scope.repository_name,
          scope.preview_json, binding.object_node_id, binding.revision_key,
          COALESCE(snapshot.canonical_input_sha256, binding.canonical_input_sha256)
            AS canonical_input_sha256,
          COALESCE(snapshot.narrative_sha256, scope.narrative_sha256) AS narrative_sha256,
          snapshot.ordinal AS snapshot_ordinal,
          job.object_number, job.state AS job_state,
          job.current_step_kind
        FROM rollout_job_bindings AS binding
        JOIN rollout_authorizations AS authorization
          ON authorization.id = binding.authorization_id
        JOIN rollout_authorization_scopes AS scope
          ON scope.authorization_id = authorization.id
        JOIN jobs AS job ON job.id = binding.job_id
        JOIN app_settings AS settings ON settings.singleton = 1
        LEFT JOIN rollout_job_input_snapshots AS snapshot
          ON snapshot.authorization_id = binding.authorization_id
         AND snapshot.job_id = binding.job_id
         AND snapshot.ordinal = (
           SELECT MAX(latest.ordinal)
           FROM rollout_job_input_snapshots AS latest
           WHERE latest.authorization_id = binding.authorization_id
             AND latest.job_id = binding.job_id
         )
        WHERE binding.job_id = ? AND authorization.state = 'active'
          AND authorization.expires_at_ms > ?
          AND settings.paused = 0
          AND settings.active_rollout_authorization_id = authorization.id
          AND job.rollout_generation = 1
          AND job.state NOT IN ('succeeded', 'blocked')
          AND NOT (
            authorization.workflow_stage = 'implementationPlan'
            AND job.current_step_kind = 'orchestrate'
          )
          AND NOT (
            authorization.workflow_stage = 'implementationExecute'
            AND job.current_step_kind = 'replan'
          )
        ORDER BY authorization.activated_at_ms DESC LIMIT 1
        """,
        bindings: [
          .text(jobID.uuidString.lowercased()), .integer(nowMilliseconds),
        ]
      ).first,
      let stage = RolloutWorkflowStage(rawValue: try text(row, "workflow_stage")),
      let repositoryID = UUID(uuidString: try text(row, "repository_id")),
      let objectNumber = try optionalInteger(row, "object_number").map(Int.init),
      let jobState = JobState(rawValue: try text(row, "job_state")),
      let currentStepKind = JobStepKind(rawValue: try text(row, "current_step_kind")),
      let previewData = try text(row, "preview_json").data(using: .utf8)
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    let preview = try RolloutPreviewBuilder.parseCanonical(previewData)
    let previewSHA256 = try text(row, "preview_sha256")
    let repositoryNodeID = try text(row, "repository_node_id")
    let local = try localEvidence(
      repositoryID: repositoryID,
      scope: preview.payload.scope,
      jobBinding: preview.payload.jobBinding,
      authorizationID: try text(row, "authorization_id"),
      database: database
    )
    let settings = try database.query(
      "SELECT github_account, github_author_id, max_concurrency FROM app_settings WHERE singleton = 1"
    ).first
    guard preview.sha256 == previewSHA256,
      preview.payload.scope.stage == stage,
      preview.payload.scope.repository.id == repositoryID.uuidString.lowercased(),
      preview.payload.scope.repository.nodeID == repositoryNodeID,
      local.inventory == preview.payload.inventory
        || local.inventory.hasMatchingOutsideScope(preview.payload.inventory),
      local.repositoryConfigurationSHA256
        == preview.payload.releaseIdentity.repositoryConfigurationSHA256,
      local.modelProfilesSHA256 == preview.payload.releaseIdentity.modelProfilesSHA256,
      let settings,
      try optionalText(settings, "github_account")
        == preview.payload.releaseIdentity.githubAccount,
      try optionalInteger(settings, "github_author_id")
        == preview.payload.releaseIdentity.githubAuthorID,
      try integer(settings, "max_concurrency") == 1
    else {
      throw RolloutAuthorityError.previewDrift
    }
    return EffectBinding(
      authorizationID: try text(row, "authorization_id"),
      stage: stage,
      repositoryID: repositoryID,
      repositoryNodeID: repositoryNodeID,
      repository: GitHubRepositoryCoordinates(
        owner: try text(row, "repository_owner"),
        repository: try text(row, "repository_name")
      ),
      objectNodeID: try text(row, "object_node_id"),
      objectNumber: objectNumber,
      revisionKey: try text(row, "revision_key"),
      canonicalInputSHA256: try text(row, "canonical_input_sha256"),
      narrativeSHA256: try optionalText(row, "narrative_sha256"),
      hasInputSnapshot: try optionalInteger(row, "snapshot_ordinal") != nil,
      jobState: jobState,
      currentStepKind: currentStepKind,
      preview: preview
    )
  }

  static func validate(
    operation: GitHubOperation,
    binding: EffectBinding
  ) throws {
    try validate(operation: operation, scope: binding.scope, objectNumber: binding.objectNumber)
  }

  static func validate(
    operation: GitHubOperation,
    scope: RolloutScope,
    objectNumber: Int? = nil
  ) throws {
    try validateRepository(operation: operation, scope: scope)
    guard
      operation.objectNumber.map({ $0 == (objectNumber ?? scope.object?.number) }) ?? true
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func validateWorkflowRead(
    operation: GitHubOperation,
    binding: EffectBinding
  ) throws {
    guard !operation.kind.isWrite,
      [.preparing, .runningPi, .executing, .reconciling, .waitingHuman, .awaitingResolution]
        .contains(binding.jobState),
      stage(binding.stage, accepts: binding.currentStepKind)
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    try validateRepository(operation: operation, scope: binding.scope)
    switch (binding.stage, operation.kind) {
    case (.prReview, .pullRequest), (.prReview, .listPullRequestCommits),
      (.prReview, .listComments), (.generatedPRReview, .pullRequest),
      (.generatedPRReview, .listPullRequestCommits), (.generatedPRReview, .listComments),
      (.issueTriage, .issue), (.issueTriage, .listComments),
      (.issueTriage, .listIssueLabels), (.issueTriage, .branchReference),
      (.issueTriage, .repositoryLabel), (.implementationPlan, .issue),
      (.implementationPlan, .listComments), (.implementationPlan, .listIssueLabels),
      (.implementationPlan, .branchReference), (.implementationPlan, .repositoryLabel),
      (.implementationExecute, .issue), (.implementationExecute, .listComments),
      (.implementationExecute, .listIssueLabels),
      (.implementationExecute, .branchReference),
      (.implementationExecute, .repositoryLabel):
      try validate(
        operation: operation,
        scope: binding.scope,
        objectNumber: binding.objectNumber
      )
    case (.implementationExecute, .listPullRequests):
      guard
        case .listPullRequests(_, _, _, let head, let base) = operation,
        head?.isEmpty == false,
        base == binding.scope.repository.defaultBranch
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    case (.implementationExecute, .pullRequest):
      guard operation.objectNumber.map({ $0 > 0 }) == true else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    default:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func validateReadback(
    operation: GitHubOperation,
    mutation: MutationOperation,
    target: String,
    scope: RolloutScope
  ) throws {
    guard !operation.kind.isWrite else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    try validateRepository(operation: operation, scope: scope)
    switch (mutation, operation) {
    case (.bootstrapLabel, .repositoryLabel(let owner, let repository, let label)):
      guard target == "\(owner)/\(repository)/labels/\(label)" else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    case (.createMarkerComment, .listComments), (.linkPullRequest, .listComments):
      try validate(operation: operation, scope: scope)
    case (.claimIssue, .listComments), (.claimIssue, .listIssueLabels),
      (.publishComplexPlan, .listComments), (.publishComplexPlan, .listIssueLabels),
      (.blockIssue, .listComments), (.blockIssue, .listIssueLabels),
      (.mutateWorkflowLabels, .listIssueLabels),
      (.pullRequestWorkflowLabel, .listIssueLabels):
      try validate(operation: operation, scope: scope)
    case (
      .createPullRequest,
      .listPullRequests(let owner, let repository, _, let head, let base)
    ):
      guard let head, let base,
        target == "\(owner)/\(repository)/pulls/\(head)-to-\(base)",
        base == scope.repository.defaultBranch
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    case (.createPullRequest, .pullRequest(_, _, let number)):
      guard number > 0 else { throw RolloutAuthorityError.effectIdentityMismatch }
    case (.publishBranch, .branchReference(_, _, let branch)):
      guard target == "repository:\(scope.repository.nodeID):refs/heads/\(branch)" else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    default:
      throw RolloutAuthorityError.readbackNotAllowed
    }
  }

  static func validateRepository(
    operation: GitHubOperation,
    scope: RolloutScope
  ) throws {
    guard let coordinates = operation.repositoryCoordinates,
      coordinates.owner.caseInsensitiveCompare(scope.repository.owner) == .orderedSame,
      coordinates.repository.caseInsensitiveCompare(scope.repository.name) == .orderedSame
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func validateDiscovery(
    operation: GitHubOperation,
    stage: RolloutWorkflowStage,
    scope: RolloutScope
  ) throws {
    try validate(operation: operation, scope: scope)
    switch (stage, operation.kind) {
    case (.prReview, .listPullRequests), (.generatedPRReview, .listPullRequests),
      (.issueTriage, .listIssues), (.implementationPlan, .listIssues),
      (.implementationExecute, .listIssues):
      return
    default:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func githubOperationSHA256(_ operation: GitHubOperation) throws -> String {
    let request = try GitHubRequestFactory.make(operation).request
    return digest([
      "github-operation-v1", request.httpMethod ?? "",
      request.url?.absoluteString ?? "",
      GitHubMarkerCodec.sha256(request.httpBody ?? Data()),
    ])
  }

  static func githubTargetSHA256(_ operation: GitHubOperation) throws -> String {
    let request = try GitHubRequestFactory.make(operation).request
    return digest([
      "github-target-v1", operation.kind.rawValue,
      operation.repositoryCoordinates?.owner.lowercased() ?? "",
      operation.repositoryCoordinates?.repository.lowercased() ?? "",
      operation.objectNumber.map(String.init) ?? "",
      request.url?.path ?? "",
    ])
  }

  static func digest(_ fields: [String]) -> String {
    var bytes = Data()
    for field in fields {
      var length = UInt64(field.utf8.count).bigEndian
      withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
      bytes.append(Data(field.utf8))
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func providerOrdinal(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int
  ) throws -> Int {
    switch workflow {
    case .pullRequestReview:
      let roles: [PiWorkflowRole] = [.architecture, .security, .test, .synthesis]
      guard round == 1, let index = roles.firstIndex(of: role) else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      return index
    case .issueTriage:
      guard round == 1, role == .triage else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      return 0
    case .planning, .orchestration:
      let roles: [PiWorkflowRole] = [.writer, .architecture, .security, .test, .synthesis]
      guard let index = roles.firstIndex(of: role) else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      return (round - 1) * roles.count + index
    }
  }

  static func expectedProviderResourceSHA256(binding: EffectBinding) -> String {
    RolloutCanonicalJSON.sha256(
      Data(
        "\(binding.preview.payload.releaseIdentity.workflowResourcesSHA256)|\(PiTUIResourceCatalog.manifestSHA256)"
          .utf8
      )
    )
  }

  static func expectedProviderProfileSHA256(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    database: isolated SQLiteStore
  ) throws -> String {
    let profileRole: ModelProfileRole
    if [.architecture, .security, .test].contains(role) {
      profileRole = .review
    } else {
      profileRole =
        switch workflow {
        case .pullRequestReview: .review
        case .issueTriage: .triage
        case .planning: .planning
        case .orchestration: .orchestration
        }
    }
    guard
      let row = try database.query(
        "SELECT provider, model, thinking FROM model_profiles WHERE role = ?",
        bindings: [.text(profileRole.rawValue)]
      ).first
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let identity = try PiTUIModelIdentity(
      provider: text(row, "provider"),
      modelID: text(row, "model"),
      thinkingLevel: text(row, "thinking")
    )
    return RolloutCanonicalJSON.sha256(Data(identity.argument.utf8))
  }

  static func stage(_ stage: RolloutWorkflowStage, accepts workflow: PiWorkflowKind) -> Bool {
    switch (stage, workflow) {
    case (.prReview, .pullRequestReview), (.generatedPRReview, .pullRequestReview),
      (.issueTriage, .issueTriage), (.implementationPlan, .planning),
      (.implementationExecute, .orchestration):
      true
    default:
      false
    }
  }

  static func stage(_ stage: RolloutWorkflowStage, accepts step: JobStepKind) -> Bool {
    switch stage {
    case .prReview, .generatedPRReview:
      [.review, .publish].contains(step)
    case .issueTriage:
      [.triage, .publish, .reconcile].contains(step)
    case .implementationPlan:
      [.claimReady, .plan, .replan, .writePlan, .publishPlan, .publish].contains(step)
    case .implementationExecute:
      [
        .publishPlan, .claimApprovedPlan, .consumeStaleApproval, .orchestrate, .push,
        .openPullRequest, .linkPullRequest, .qa, .enqueueReview, .publish,
      ].contains(step)
    }
  }

  static func validateGitRemoteRead(
    _ effect: RolloutGitRemoteReadEffect,
    binding: EffectBinding
  ) throws {
    guard binding.repositoryID == effect.repositoryID,
      binding.repositoryNodeID == effect.repositoryNodeID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    switch (binding.stage, binding.jobState, binding.currentStepKind, effect.operation) {
    case (.prReview, .preparing, .review, .cloneMirror),
      (.prReview, .preparing, .review, .fetchMirror),
      (.prReview, .preparing, .review, .fetchPullRequest),
      (.generatedPRReview, .preparing, .review, .cloneMirror),
      (.generatedPRReview, .preparing, .review, .fetchMirror),
      (.generatedPRReview, .preparing, .review, .fetchPullRequest),
      (.implementationPlan, .preparing, .plan, .cloneMirror),
      (.implementationPlan, .preparing, .plan, .fetchMirror),
      (.implementationPlan, .preparing, .replan, .cloneMirror),
      (.implementationPlan, .preparing, .replan, .fetchMirror),
      (.implementationExecute, .preparing, .orchestrate, .cloneMirror),
      (.implementationExecute, .preparing, .orchestrate, .fetchMirror),
      (.implementationExecute, .executing, .push, .readReference),
      (.implementationExecute, .reconciling, .push, .readReference):
      return
    default:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func validateProvider(
    _ effect: RolloutProviderEffect,
    binding: EffectBinding,
    database: isolated SQLiteStore
  ) throws {
    let expectedStep: JobStepKind =
      switch effect.workflow {
      case .pullRequestReview: .review
      case .issueTriage: .triage
      case .planning:
        binding.currentStepKind == .replan ? .replan : .plan
      case .orchestration: .orchestrate
      }
    guard binding.jobState == .runningPi,
      binding.currentStepKind == expectedStep,
      stage(binding.stage, accepts: effect.workflow),
      effect.artifactSHA256 == binding.canonicalInputSHA256,
      effect.narrativeSHA256 == binding.narrativeSHA256,
      binding.stage == .implementationExecute
        ? effect.planSHA256 == binding.scope.object?.planSHA256
        : effect.planSHA256 == nil,
      effect.resourceSHA256 == expectedProviderResourceSHA256(binding: binding),
      effect.profileSHA256
        == (try expectedProviderProfileSHA256(
          workflow: effect.workflow,
          role: effect.role,
          database: database
        ))
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

}

extension RolloutAuthorityStore {
  struct EffectIntent: Sendable {
    let id: UUID
    let jobID: UUID
    let operation: MutationOperation
    let target: String
    let expectedStateSHA256: String
    let requestSHA256: String
    let state: MutationIntentState
    let sendEpoch: Int
  }

  static let markerOperations: Set<MutationOperation> = [
    .createMarkerComment, .claimIssue, .publishComplexPlan, .linkPullRequest, .blockIssue,
  ]

  static func loadIntent(
    id: UUID,
    database: isolated SQLiteStore
  ) throws -> EffectIntent {
    guard
      let row = try database.query(
        "SELECT * FROM mutation_intents WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).first,
      let storedID = UUID(uuidString: try text(row, "id")),
      let jobID = UUID(uuidString: try text(row, "job_id")),
      let operation = MutationOperation(rawValue: try text(row, "operation")),
      let state = MutationIntentState(rawValue: try text(row, "state"))
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    return EffectIntent(
      id: storedID,
      jobID: jobID,
      operation: operation,
      target: try text(row, "target"),
      expectedStateSHA256: try text(row, "expected_state_digest"),
      requestSHA256: try text(row, "request_digest"),
      state: state,
      sendEpoch: Int(try integer(row, "send_epoch"))
    )
  }

  static func insertReservation(
    id: String,
    request: RolloutEffectReservationRequest,
    nowMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    try requireBudget(
      authorizationID: request.authorizationID,
      kind: request.kind,
      cost: request.cost,
      database: database
    )
    _ = try database.execute(
      """
      INSERT INTO rollout_effect_reservations(
        id, authorization_id, job_id, kind, operation_sha256, target_sha256,
        ordinal, attempt, github_read_requests, github_read_pages,
        github_read_bytes, git_remote_reads, provider_sessions, approved_commands,
        marker_parts, label_writes, branch_creates, pull_request_creates,
        github_sends, git_sends, state, mutation_intent_id,
        created_at_ms, updated_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        'reserved', ?, ?, ?)
      """,
      bindings: reservationBindings(
        id: id,
        request: request,
        nowMilliseconds: nowMilliseconds
      )
    )
  }

  static func markIntentAndReservationStarted(
    intent: EffectIntent,
    reservationID: String,
    authorizationID: String,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    try markIntentStarted(intent: intent, now: now, database: database)
    let changed = try database.execute(
      "UPDATE rollout_effect_reservations SET state = 'sendStarted', updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ? AND state = 'reserved'",
      bindings: [
        .integer(milliseconds(now)), .text(reservationID),
      ]
    )
    guard changed == 1 else { throw RolloutAuthorityError.invalidStateTransition }
    try insertEvent(
      authorizationID: authorizationID,
      eventKey: "send:\(reservationID)",
      kind: .sendStarted,
      from: .active,
      to: .active,
      reasonCode: "PREPARED_BEFORE_SEND",
      checkpointSHA256: intent.requestSHA256,
      nowMilliseconds: milliseconds(now),
      database: database
    )
  }

  static func markIntentStarted(
    intent: EffectIntent,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    let changed = try database.execute(
      """
      UPDATE mutation_intents
      SET state = 'sendStarted', send_epoch = send_epoch + 1, updated_at = ?
      WHERE id = ? AND state = ? AND send_epoch = ?
      """,
      bindings: [
        .real(now.timeIntervalSince1970), .text(intent.id.uuidString.lowercased()),
        .text(intent.state.rawValue), .integer(Int64(intent.sendEpoch)),
      ]
    )
    guard changed == 1 else { throw RolloutAuthorityError.invalidStateTransition }
    _ = try database.execute(
      """
      INSERT INTO reconciliation_events(
        job_id, probe, observation, classification, reason, created_at
      ) VALUES (?, ?, ?, 'sendStarted', 'prepared-before-send boundary', ?)
      """,
      bindings: [
        .text(intent.jobID.uuidString.lowercased()),
        .text("mutation:\(intent.operation.rawValue)"),
        .text("send epoch \(intent.sendEpoch + 1) started"),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  static func githubRequestSHA256(_ operation: GitHubOperation) throws -> String {
    let request = try GitHubRequestFactory.make(operation).request
    var bytes = Data()
    bytes.append(Data((request.httpMethod ?? "").utf8))
    bytes.append(0x0A)
    bytes.append(Data((request.url?.absoluteString ?? "").utf8))
    bytes.append(0x0A)
    if let body = request.httpBody { bytes.append(body) }
    return GitHubMarkerCodec.sha256(bytes)
  }

  static func gitTargetSHA256(_ effect: RolloutGitSendEffect) -> String {
    digest([
      "git-send-target-v1", effect.repositoryID.uuidString.lowercased(),
      effect.repositoryNodeID, effect.branch, effect.exactSHA, effect.target,
      effect.expectedStateSHA256,
    ])
  }

  static func effectKind(
    mutation: MutationOperation,
    operation: GitHubOperationKind
  ) -> RolloutEffectKind {
    if operation == .createComment, markerOperations.contains(mutation) { return .markerBatch }
    switch operation {
    case .createRepositoryLabel, .addIssueLabels, .removeIssueLabel:
      return .labelWrite
    case .createPullRequest:
      return .pullRequestCreate
    default:
      return .githubMutation
    }
  }

  static func cost(for kind: RolloutEffectKind) -> RolloutEffectCost {
    switch kind {
    case .labelWrite: RolloutEffectCost(labelWrites: 1, githubSends: 1)
    case .pullRequestCreate: RolloutEffectCost(pullRequestCreates: 1, githubSends: 1)
    case .githubMutation: RolloutEffectCost(githubSends: 1)
    default: RolloutEffectCost()
    }
  }

  static func allows(
    mutation: MutationOperation,
    operation: GitHubOperationKind
  ) -> Bool {
    switch mutation {
    case .bootstrapLabel:
      operation == .createRepositoryLabel
    case .createMarkerComment, .linkPullRequest:
      operation == .createComment
    case .mutateWorkflowLabels:
      operation == .addIssueLabels || operation == .removeIssueLabel
    case .claimIssue, .publishComplexPlan, .blockIssue:
      operation == .createComment
    case .pullRequestWorkflowLabel:
      false
    case .createPullRequest:
      operation == .createPullRequest
    case .publishBranch:
      false
    }
  }

  static func validateMutationPreview(
    _ effect: RolloutGitHubSendEffect,
    binding: EffectBinding
  ) throws {
    try validateMutation(
      operation: effect.operation,
      mutation: effect.mutation,
      binding: binding
    )
    if case .createRepositoryLabel(_, _, let request) = effect.operation {
      guard
        binding.preview.payload.missingLabels.contains(where: {
          $0.name == request.name && $0.color.caseInsensitiveCompare(request.color) == .orderedSame
            && $0.description == request.description
        })
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    }
    let kind = effectKind(mutation: effect.mutation, operation: effect.operation.kind)
    guard
      binding.preview.payload.effectEnvelope.allowances.contains(where: {
        $0.kind == kind && $0.maximumCount > 0
      })
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  static func validateMutation(
    operation: GitHubOperation,
    mutation: MutationOperation,
    binding: EffectBinding
  ) throws {
    guard allows(mutation: mutation, operation: operation.kind),
      stage(binding.stage, accepts: binding.currentStepKind)
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let allowed: Bool
    switch mutation {
    case .bootstrapLabel:
      allowed =
        (binding.stage == .issueTriage
          && binding.jobState == .preparing
          && binding.currentStepKind == .triage)
        || (binding.stage == .implementationPlan
          && binding.jobState == .executing
          && binding.currentStepKind == .claimReady)
        || (binding.stage == .implementationExecute
          && binding.jobState == .executing
          && binding.currentStepKind == .claimApprovedPlan)
    case .createMarkerComment:
      allowed =
        [.prReview, .generatedPRReview, .issueTriage].contains(binding.stage)
        && binding.currentStepKind == .publish
        && [.executing, .reconciling].contains(binding.jobState)
    case .claimIssue:
      allowed =
        operation.kind == .createComment
        && ((binding.stage == .implementationPlan && binding.currentStepKind == .claimReady)
          || (binding.stage == .implementationExecute
            && binding.currentStepKind == .claimApprovedPlan))
        && [.executing, .reconciling].contains(binding.jobState)
    case .publishComplexPlan:
      allowed =
        operation.kind == .createComment
        && binding.stage == .implementationPlan
        && binding.currentStepKind == .publishPlan
        && [.executing, .reconciling].contains(binding.jobState)
    case .linkPullRequest:
      allowed =
        operation.kind == .createComment
        && binding.stage == .implementationExecute
        && binding.currentStepKind == .linkPullRequest
        && [.executing, .reconciling].contains(binding.jobState)
    case .blockIssue:
      allowed =
        operation.kind == .createComment
        && [.implementationPlan, .implementationExecute].contains(binding.stage)
        && binding.currentStepKind == .publish
        && [.executing, .reconciling].contains(binding.jobState)
    case .mutateWorkflowLabels:
      allowed =
        [.executing, .reconciling].contains(binding.jobState)
        && validWorkflowLabelMutation(operation, binding: binding)
    case .createPullRequest:
      allowed =
        binding.stage == .implementationExecute
        && binding.currentStepKind == .openPullRequest
        && [.executing, .reconciling].contains(binding.jobState)
        && validPullRequestCreate(operation, binding: binding)
    case .pullRequestWorkflowLabel, .publishBranch:
      allowed = false
    }
    guard allowed else { throw RolloutAuthorityError.effectIdentityMismatch }
  }

  static func validWorkflowLabelMutation(
    _ operation: GitHubOperation,
    binding: EffectBinding
  ) -> Bool {
    let additions: Set<String>
    let removal: String?
    switch operation {
    case .addIssueLabels(_, _, _, let labels):
      guard labels.count == 1 else { return false }
      additions = Set(labels.map { $0.lowercased() })
      removal = nil
    case .removeIssueLabel(_, _, _, let label):
      additions = []
      removal = label.lowercased()
    default:
      return false
    }
    let permittedAdditions: Set<String>
    let permittedRemovals: Set<String>
    switch (binding.stage, binding.currentStepKind) {
    case (.issueTriage, .reconcile):
      permittedAdditions = ["agent:ready", "agent:needs-spec", "agent:human"]
      permittedRemovals = []
    case (.implementationPlan, .claimReady):
      permittedAdditions = ["agent:wip"]
      permittedRemovals = ["agent:ready"]
    case (.implementationPlan, .publishPlan):
      permittedAdditions = ["agent:plan-review"]
      permittedRemovals = ["agent:wip"]
    case (.implementationPlan, .publish):
      permittedAdditions = ["agent:human", "agent:blocked"]
      permittedRemovals = ["agent:wip"]
    case (.implementationExecute, .claimApprovedPlan):
      permittedAdditions = ["agent:wip"]
      permittedRemovals = ["agent:plan-review", "plan:approved"]
    case (.implementationExecute, .consumeStaleApproval):
      permittedAdditions = []
      permittedRemovals = ["plan:approved"]
    case (.implementationExecute, .qa):
      permittedAdditions = ["agent:qa"]
      permittedRemovals = ["agent:wip"]
    case (.implementationExecute, .publish):
      permittedAdditions = ["agent:blocked"]
      permittedRemovals = ["agent:wip"]
    default:
      return false
    }
    if let removal {
      return additions.isEmpty && permittedRemovals.contains(removal)
    }
    return additions.count == 1 && additions.isSubset(of: permittedAdditions)
  }

  static func validPullRequestCreate(
    _ operation: GitHubOperation,
    binding: EffectBinding
  ) -> Bool {
    guard case .createPullRequest(_, _, let request) = operation,
      request.base == binding.scope.repository.defaultBranch,
      GitBranchPolicy.validImplementationBranch(request.head),
      request.body.contains("Closes #\(binding.objectNumber)"),
      let planSHA256 = binding.scope.object?.planSHA256,
      request.body.contains("Plan digest: `\(planSHA256)`")
    else {
      return false
    }
    return true
  }

  static func marker(
    _ marker: GitHubMarkerKind,
    operation: MutationOperation,
    binding: EffectBinding
  ) -> Bool {
    guard [.executing, .reconciling].contains(binding.jobState) else { return false }
    return switch (binding.stage, binding.currentStepKind, marker, operation) {
    case (.prReview, .publish, .review, .createMarkerComment),
      (.generatedPRReview, .publish, .review, .createMarkerComment),
      (.issueTriage, .publish, .triage, .createMarkerComment),
      (.implementationPlan, .claimReady, .claim, .claimIssue),
      (.implementationPlan, .publishPlan, .plan, .publishComplexPlan),
      (.implementationPlan, .publish, .blocked, .blockIssue),
      (.implementationExecute, .claimApprovedPlan, .resume, .claimIssue),
      (.implementationExecute, .linkPullRequest, .link, .linkPullRequest),
      (.implementationExecute, .publish, .blocked, .blockIssue):
      true
    default:
      false
    }
  }

  static func validMarkerRevision(
    _ revision: String,
    markerKind: GitHubMarkerKind,
    binding: EffectBinding
  ) -> Bool {
    switch markerKind {
    case .review:
      return GitHubInputValidation.validGitSHA(revision)
        && revision == binding.revisionKey
    case .link:
      return GitHubInputValidation.validGitSHA(revision)
    case .triage, .claim, .resume, .plan, .blocked:
      return GitHubInputValidation.validSHA256(revision)
    }
  }
}

extension RolloutMarkerBatchEffect {
  fileprivate var expectedTarget: String {
    "\(repository.owner)/\(repository.repository)/issues/\(objectNumber)"
  }
}
