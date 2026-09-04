import CryptoKit
import Foundation

public actor RolloutAuthorityStore {
  public static let maximumInventoryRows = 100_000

  let database: SQLiteStore
  let currentTime: @Sendable () -> Date
  let enforcesFinitePromotion: Bool
  var effectAdmissionOpen = true
  var inFlightEffectPermits: Set<String> = []
  var verifiedReadPermits: Set<String> = []
  var effectReattachmentClaims: Set<String> = []
  var effectAdmissionsInProgress = 0

  public init(
    database: SQLiteStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    currentTime = now
    enforcesFinitePromotion = true
  }

  init(
    database: SQLiteStore,
    now: @escaping @Sendable () -> Date = Date.init,
    enforceFinitePromotion: Bool
  ) {
    self.database = database
    currentTime = now
    enforcesFinitePromotion = enforceFinitePromotion
  }

  public func localEvidence(repositoryID: UUID) async throws -> RolloutLocalStateEvidence {
    return try await database.transaction { database in
      try Self.localEvidence(repositoryID: repositoryID, database: database)
    }
  }

  public func localEvidence(
    scope: RolloutScope,
    jobBinding: RolloutJobBinding?
  ) async throws -> RolloutLocalStateEvidence {
    try await database.transaction { database in
      try Self.localEvidence(
        repositoryID: try scope.repositoryUUID,
        scope: scope,
        jobBinding: jobBinding,
        authorizationID: nil,
        database: database
      )
    }
  }

  public func inventory() async throws -> RolloutInventory {
    try await database.transaction { database in
      try Self.inventory(database: database)
    }
  }

  public func preview(input: RolloutPreviewInput) async throws -> RolloutPreview {
    let preview = try RolloutPreviewBuilder.make(input)
    try await database.transaction { database in
      let evidence = try Self.localEvidence(
        repositoryID: try input.scope.repositoryUUID,
        scope: input.scope,
        jobBinding: input.jobBinding,
        authorizationID: nil,
        database: database
      )
      guard evidence.inventory == input.inventory,
        evidence.repositoryConfigurationSHA256
          == input.releaseIdentity.repositoryConfigurationSHA256,
        evidence.modelProfilesSHA256 == input.releaseIdentity.modelProfilesSHA256
      else {
        throw RolloutAuthorityError.previewDrift
      }
      try Self.requireRepository(
        input.scope.repository,
        release: input.releaseIdentity,
        database: database
      )
    }
    return preview
  }

  public func activate(
    approvedCanonicalJSON: Data,
    confirmedSHA256: String,
    recomputedInput: RolloutPreviewInput,
    authorizationID: UUID = UUID(),
    now: Date
  ) async throws -> RolloutStatusReport {
    guard GitHubInputValidation.validSHA256(confirmedSHA256) else {
      throw RolloutAuthorityError.previewDigestMismatch
    }
    let approved = try RolloutPreviewBuilder.parseCanonical(approvedCanonicalJSON)
    guard approved.sha256 == confirmedSHA256 else {
      throw RolloutAuthorityError.previewDigestMismatch
    }
    let recomputed = try RolloutPreviewBuilder.make(recomputedInput)
    guard recomputed.sha256 == approved.sha256,
      recomputed.canonicalJSON == approvedCanonicalJSON
    else {
      throw RolloutAuthorityError.previewDrift
    }
    let nowMilliseconds = Self.milliseconds(now)
    guard nowMilliseconds >= approved.payload.createdAtMilliseconds,
      nowMilliseconds < approved.payload.expiresAtMilliseconds
    else {
      throw RolloutAuthorityError.previewExpired
    }

    let authorizationIDText = authorizationID.uuidString.lowercased()
    let activatedID: String = try await database.transaction { database in
      if let existing = try database.query(
        "SELECT id, preview_sha256, state FROM rollout_authorizations WHERE preview_sha256 = ? OR id = ?",
        bindings: [.text(approved.sha256), .text(authorizationIDText)]
      ).first {
        guard try Self.text(existing, "id") == authorizationIDText,
          try Self.text(existing, "preview_sha256") == approved.sha256,
          try Self.text(existing, "state") == RolloutAuthorizationState.active.rawValue,
          let settings = try database.query(
            "SELECT paused, max_concurrency, active_rollout_authorization_id FROM app_settings WHERE singleton = 1"
          ).first,
          try Self.integer(settings, "paused") == 0,
          try Self.integer(settings, "max_concurrency") == 1,
          try Self.optionalText(settings, "active_rollout_authorization_id")
            == authorizationIDText
        else {
          throw RolloutAuthorityError.authorizationCollision
        }
        let evidence = try Self.localEvidence(
          repositoryID: try approved.payload.scope.repositoryUUID,
          database: database
        )
        guard
          evidence.repositoryConfigurationSHA256
            == approved.payload.releaseIdentity.repositoryConfigurationSHA256,
          evidence.modelProfilesSHA256 == approved.payload.releaseIdentity.modelProfilesSHA256
        else {
          throw RolloutAuthorityError.previewDrift
        }
        try Self.requireRepository(
          approved.payload.scope.repository,
          release: approved.payload.releaseIdentity,
          database: database
        )
        return authorizationIDText
      }

      let evidence = try Self.localEvidence(
        repositoryID: try approved.payload.scope.repositoryUUID,
        scope: approved.payload.scope,
        jobBinding: approved.payload.jobBinding,
        authorizationID: nil,
        database: database
      )
      guard evidence.inventory == approved.payload.inventory,
        evidence.repositoryConfigurationSHA256
          == approved.payload.releaseIdentity.repositoryConfigurationSHA256,
        evidence.modelProfilesSHA256 == approved.payload.releaseIdentity.modelProfilesSHA256
      else {
        throw RolloutAuthorityError.previewDrift
      }
      try Self.requireRepository(
        approved.payload.scope.repository,
        release: approved.payload.releaseIdentity,
        database: database
      )
      try Self.requireActivationSettings(database: database)
      if approved.payload.scope.mode == .finiteWindow, enforcesFinitePromotion {
        try Self.requireFinitePromotion(
          preview: approved,
          activatedAtMilliseconds: nowMilliseconds,
          database: database
        )
      }
      try Self.insertAuthorization(
        id: authorizationIDText,
        preview: approved,
        activatedAtMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.insertScope(
        authorizationID: authorizationIDText,
        preview: approved,
        database: database
      )
      try Self.insertBudget(
        authorizationID: authorizationIDText,
        budgets: approved.payload.budgets,
        database: database
      )
      try Self.insertCandidates(
        authorizationID: authorizationIDText,
        candidates: approved.payload.scope.finiteWindow?.candidates ?? [],
        database: database
      )
      try Self.insertEvent(
        authorizationID: authorizationIDText,
        eventKey: "activate:\(authorizationIDText)",
        kind: .activated,
        from: nil,
        to: .active,
        reasonCode: "PREVIEW_CONFIRMED",
        checkpointSHA256: approved.sha256,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      if approved.payload.scope.mode == .exactObject {
        guard let binding = approved.payload.jobBinding,
          let object = approved.payload.scope.object
        else {
          throw RolloutAuthorityError.invalidJobBinding
        }
        try Self.ensureExactJob(
          binding: binding,
          object: object,
          scope: approved.payload.scope,
          now: now,
          database: database
        )
        try Self.insertJobBinding(
          authorizationID: authorizationIDText,
          binding: binding,
          scope: approved.payload.scope,
          objectNodeID: object.nodeID,
          revisionKey: object.revisionKey,
          canonicalInputSHA256: object.canonicalInputSHA256,
          jobSlot: 1,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
        try Self.insertEvent(
          authorizationID: authorizationIDText,
          eventKey: "bind:\(authorizationIDText):\(binding.jobID)",
          kind: .jobBound,
          from: .active,
          to: .active,
          reasonCode: "EXACT_OBJECT_BOUND",
          checkpointSHA256: object.canonicalInputSHA256,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
      }
      _ = try database.execute(
        """
        UPDATE app_settings
        SET paused = 0, active_rollout_authorization_id = ?, max_concurrency = 1, updated_at = ?
        WHERE singleton = 1 AND paused = 1 AND active_rollout_authorization_id IS NULL
        """,
        bindings: [.text(authorizationIDText), .real(now.timeIntervalSince1970)]
      )
      guard try database.scalarInt("SELECT changes()") == 1 else {
        throw RolloutAuthorityError.authorizationCollision
      }
      return authorizationIDText
    }
    effectAdmissionOpen = true
    return try await status(authorizationID: activatedID)
  }

  public func activeAuthorization() async throws -> RolloutAuthorization? {
    try await database.query(
      """
      SELECT * FROM rollout_authorizations
      WHERE state IN ('active', 'draining', 'recoveryRequired')
      ORDER BY activated_at_ms DESC LIMIT 1
      """
    ).first.map(Self.decodeAuthorization)
  }

  public func activeStatus(now: Date) async throws -> RolloutStatusReport? {
    let active = try await activeAuthorization()
    if let authorization = active,
      authorization.expiresAtMilliseconds <= Self.milliseconds(now)
    {
      await closeAdmission()
      _ = try await transitionLane(
        authorizationID: authorization.id,
        target: .expired,
        eventKind: .expired,
        reasonCode: "AUTHORIZATION_EXPIRED",
        requireEffectsSettled: false,
        now: now
      )
      return nil
    }
    do {
      return try await database.transaction { database in
        guard
          let settings = try database.query(
            "SELECT * FROM app_settings WHERE singleton = 1"
          ).first,
          try Self.integer(settings, "paused") == 0,
          let authorizationID = try Self.optionalText(
            settings,
            "active_rollout_authorization_id"
          )
        else {
          return nil
        }
        let report = try Self.status(authorizationID: authorizationID, database: database)
        guard report.authorization.state == .active,
          report.authorization.expiresAtMilliseconds > Self.milliseconds(now)
        else {
          return nil
        }
        let evidence = try Self.localEvidence(
          repositoryID: report.authorization.repositoryID,
          database: database
        )
        guard
          evidence.repositoryConfigurationSHA256
            == report.releaseIdentity.repositoryConfigurationSHA256,
          evidence.modelProfilesSHA256 == report.releaseIdentity.modelProfilesSHA256,
          try Self.optionalText(settings, "github_account")
            == report.releaseIdentity.githubAccount,
          try Self.optionalInteger(settings, "github_author_id")
            == report.releaseIdentity.githubAuthorID,
          try Self.integer(settings, "max_concurrency") == 1
        else {
          throw RolloutAuthorityError.previewDrift
        }
        return report
      }
    } catch RolloutAuthorityError.previewDrift {
      if let active, active.state == .active {
        await closeAdmission()
        _ = try await transitionLane(
          authorizationID: active.id,
          target: .failed,
          eventKind: .failed,
          reasonCode: "CONFIGURATION_DRIFT",
          requireEffectsSettled: false,
          now: now
        )
      }
      throw RolloutAuthorityError.previewDrift
    }
  }

  public func schedulerAdmission(now: Date) async throws -> RolloutSchedulerAdmission {
    if let report = try await activeStatus(now: now) {
      return .active(report.authorization.scopeMode)
    }
    return try await database.transaction { database in
      let uncertain =
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM rollout_effect_reservations
          WHERE state IN ('sendStarted', 'observationRequired')
          """
        ) ?? 0
      return uncertain > 0 ? .readbackOnly : .denied
    }
  }

  public func status(authorizationID: String) async throws -> RolloutStatusReport {
    try await database.transaction { database in
      try Self.status(authorizationID: authorizationID, database: database)
    }
  }

  public func latestStatus() async throws -> RolloutStatusReport? {
    try await database.transaction { database in
      guard
        let authorizationID = try database.scalarText(
          """
          SELECT id FROM rollout_authorizations
          ORDER BY activated_at_ms DESC, id DESC LIMIT 1
          """
        )
      else {
        return nil
      }
      return try Self.status(authorizationID: authorizationID, database: database)
    }
  }

  func reserveEffect(
    _ request: RolloutEffectReservationRequest,
    reservationID: UUID = UUID(),
    now: Date
  ) async throws -> RolloutEffectReservation {
    guard effectAdmissionOpen else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try request.cost.validate(for: request.kind)
    guard RolloutPreviewBuilder.validLowercaseUUID(request.authorizationID),
      GitHubInputValidation.validSHA256(request.operationSHA256),
      GitHubInputValidation.validSHA256(request.targetSHA256),
      request.ordinal >= 0,
      request.attempt > 0,
      request.mutationIntentID.map({ RolloutPreviewBuilder.validIdentifier($0, maximum: 256) })
        ?? true
    else {
      throw RolloutAuthorityError.invalidEffectCost
    }
    let reservationIDText = reservationID.uuidString.lowercased()
    let nowMilliseconds = Self.milliseconds(now)
    return try await database.transaction { database in
      if let row = try database.query(
        """
        SELECT * FROM rollout_effect_reservations
        WHERE authorization_id = ? AND kind = ? AND operation_sha256 = ?
          AND ordinal = ? AND attempt = ?
        """,
        bindings: [
          .text(request.authorizationID),
          .text(request.kind.rawValue),
          .text(request.operationSHA256),
          .integer(Int64(request.ordinal)),
          .integer(Int64(request.attempt)),
        ]
      ).first {
        let existing = try Self.decodeReservation(row)
        guard existing.request == request else {
          throw RolloutAuthorityError.authorizationCollision
        }
        return existing
      }
      guard
        try database.scalarInt(
          """
          SELECT COUNT(*)
          FROM rollout_authorizations AS authorization
          JOIN app_settings AS settings ON settings.singleton = 1
          JOIN rollout_job_bindings AS binding
            ON binding.authorization_id = authorization.id
          WHERE authorization.id = ? AND authorization.state = 'active'
            AND authorization.expires_at_ms > ?
            AND settings.paused = 0
            AND settings.active_rollout_authorization_id = authorization.id
            AND binding.job_id = ?
          """,
          bindings: [
            .text(request.authorizationID),
            .integer(nowMilliseconds),
            .text(request.jobID.uuidString.lowercased()),
          ]
        ) == 1
      else {
        throw RolloutAuthorityError.authorizationNotActive(request.authorizationID)
      }
      try Self.requireBudget(
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
        bindings: Self.reservationBindings(
          id: reservationIDText,
          request: request,
          nowMilliseconds: nowMilliseconds
        )
      )
      try Self.insertEvent(
        authorizationID: request.authorizationID,
        eventKey: "reserve:\(reservationIDText)",
        kind: .effectReserved,
        from: .active,
        to: .active,
        reasonCode: request.kind.rawValue,
        checkpointSHA256: request.operationSHA256,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      guard
        let row = try database.query(
          "SELECT * FROM rollout_effect_reservations WHERE id = ?",
          bindings: [.text(reservationIDText)]
        ).first
      else {
        throw RolloutAuthorityError.decode("effect reservation insert")
      }
      return try Self.decodeReservation(row)
    }
  }

  func settleReservation(
    id: String,
    attributed: Bool,
    evidenceSHA256: String,
    now: Date
  ) async throws -> RolloutEffectReservation {
    guard RolloutPreviewBuilder.validLowercaseUUID(id),
      GitHubInputValidation.validSHA256(evidenceSHA256)
    else {
      throw RolloutAuthorityError.invalidDigest("effect evidence")
    }
    return try await database.transaction { database in
      let current = try Self.requireReservation(id: id, database: database)
      let target: RolloutEffectReservationState = attributed ? .attributed : .settled
      if current.state == .settled || current.state == target {
        return current
      }
      guard
        current.state == .reserved || current.state == .sendStarted
          || current.state == .observationRequired || current.state == .attributed
      else {
        throw RolloutAuthorityError.invalidStateTransition
      }
      if target == .attributed, current.state == .reserved {
        throw RolloutAuthorityError.invalidStateTransition
      }
      _ = try database.execute(
        "UPDATE rollout_effect_reservations SET state = ?, updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ?",
        bindings: [
          .text(target.rawValue),
          .integer(Self.milliseconds(now)),
          .text(id),
        ]
      )
      try Self.insertEvent(
        authorizationID: current.request.authorizationID,
        eventKey: "observe:\(id):\(target.rawValue)",
        kind: .effectObserved,
        from: try Self.authorizationState(
          id: current.request.authorizationID,
          database: database
        ),
        to: try Self.authorizationState(
          id: current.request.authorizationID,
          database: database
        ),
        reasonCode: attributed ? "EFFECT_ATTRIBUTED" : "EFFECT_SETTLED",
        checkpointSHA256: evidenceSHA256,
        nowMilliseconds: Self.milliseconds(now),
        database: database
      )
      return try Self.requireReservation(id: id, database: database)
    }
  }

  public func beginDrain(
    authorizationID: String,
    reasonCode: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    await closeAdmission()
    return try await transitionLane(
      authorizationID: authorizationID,
      target: .draining,
      eventKind: .drainStarted,
      reasonCode: reasonCode,
      requireEffectsSettled: false,
      now: now
    )
  }

  public func markRecoveryRequired(
    authorizationID: String,
    reasonCode: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    await closeAdmission()
    return try await transitionLane(
      authorizationID: authorizationID,
      target: .recoveryRequired,
      eventKind: .recoveryRequired,
      reasonCode: reasonCode,
      requireEffectsSettled: false,
      now: now
    )
  }

  public func resumeExactRecovery(
    authorizationID: String,
    checkpointSHA256: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    guard RolloutPreviewBuilder.validLowercaseUUID(authorizationID),
      GitHubInputValidation.validSHA256(checkpointSHA256),
      !effectAdmissionOpen,
      effectAdmissionsInProgress == 0,
      inFlightEffectPermits.isEmpty,
      verifiedReadPermits.isEmpty
    else {
      throw RolloutAuthorityError.invalidStateTransition
    }
    let nowMilliseconds = Self.milliseconds(now)
    try await database.transaction { database in
      let report = try Self.status(authorizationID: authorizationID, database: database)
      guard report.authorization.state == .recoveryRequired,
        report.scope.mode == .exactObject,
        report.authorization.expiresAtMilliseconds > nowMilliseconds,
        report.boundJobIDs.count == 1,
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM jobs
          WHERE id = ? AND rollout_generation = 1
            AND state NOT IN ('succeeded', 'blocked')
          """,
          bindings: [.text(report.boundJobIDs[0].uuidString.lowercased())]
        ) == 1,
        try database.scalarInt(
          """
          SELECT
            (SELECT COUNT(*) FROM rollout_effect_reservations
             WHERE authorization_id = ? AND state NOT IN ('settled', 'reserved')) +
            (SELECT COUNT(*) FROM rollout_scope_read_reservations
             WHERE authorization_id = ? AND state != 'settled') +
            (SELECT COUNT(*) FROM rollout_readback_reservations
             WHERE authorization_id = ? AND state != 'settled') +
            (SELECT COUNT(*) FROM rollout_git_readback_reservations
             WHERE authorization_id = ? AND state != 'settled')
          """,
          bindings: Array(repeating: .text(authorizationID), count: 4)
        ) == 0
      else {
        throw RolloutAuthorityError.invalidStateTransition
      }
      let evidence = try Self.localEvidence(
        repositoryID: report.authorization.repositoryID,
        database: database
      )
      guard
        evidence.repositoryConfigurationSHA256
          == report.releaseIdentity.repositoryConfigurationSHA256,
        evidence.modelProfilesSHA256 == report.releaseIdentity.modelProfilesSHA256
      else {
        throw RolloutAuthorityError.previewDrift
      }
      try Self.requireRepository(
        report.scope.repository,
        release: report.releaseIdentity,
        database: database
      )
      let changed = try database.execute(
        """
        UPDATE rollout_authorizations
        SET state = 'active', updated_at_ms = ?, terminal_reason = NULL
        WHERE id = ? AND state = 'recoveryRequired'
        """,
        bindings: [.integer(nowMilliseconds), .text(authorizationID)]
      )
      guard changed == 1 else {
        throw RolloutAuthorityError.invalidStateTransition
      }
      _ = try database.execute(
        """
        UPDATE app_settings
        SET paused = 0, active_rollout_authorization_id = ?,
            max_concurrency = 1, updated_at = ?
        WHERE singleton = 1 AND paused = 1
          AND active_rollout_authorization_id = ?
        """,
        bindings: [
          .text(authorizationID), .real(now.timeIntervalSince1970),
          .text(authorizationID),
        ]
      )
      guard try database.scalarInt("SELECT changes()") == 1 else {
        throw RolloutAuthorityError.invalidStateTransition
      }
      try Self.insertEvent(
        authorizationID: authorizationID,
        eventKey: "recovery-activate:\(authorizationID):\(checkpointSHA256)",
        kind: .recoveryActivated,
        from: .recoveryRequired,
        to: .active,
        reasonCode: "RECOVERY_PREVIEW_CONFIRMED",
        checkpointSHA256: checkpointSHA256,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
    }
    effectAdmissionOpen = true
    return try await status(authorizationID: authorizationID)
  }

  public func revoke(
    authorizationID: String,
    reasonCode: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    await closeAdmission()
    return try await transitionLane(
      authorizationID: authorizationID,
      target: .revoked,
      eventKind: .revoked,
      reasonCode: reasonCode,
      requireEffectsSettled: false,
      now: now
    )
  }

  public func settle(
    authorizationID: String,
    checkpointSHA256: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    guard GitHubInputValidation.validSHA256(checkpointSHA256) else {
      throw RolloutAuthorityError.invalidDigest("settlement checkpoint")
    }
    await closeAdmission()
    return try await transitionLane(
      authorizationID: authorizationID,
      target: .settled,
      eventKind: .settled,
      reasonCode: "STAGE_SETTLED",
      checkpointSHA256: checkpointSHA256,
      requireEffectsSettled: true,
      now: now
    )
  }

  public func fail(
    authorizationID: String,
    reasonCode: String,
    now: Date
  ) async throws -> RolloutStatusReport {
    await closeAdmission()
    return try await transitionLane(
      authorizationID: authorizationID,
      target: .failed,
      eventKind: .failed,
      reasonCode: reasonCode,
      requireEffectsSettled: false,
      now: now
    )
  }

  public func markInterruptedLaneRecoveryRequired(now: Date) async throws -> RolloutStatusReport? {
    guard let authorization = try await activeAuthorization() else { return nil }
    if authorization.state == .recoveryRequired {
      return try await status(authorizationID: authorization.id)
    }
    return try await markRecoveryRequired(
      authorizationID: authorization.id,
      reasonCode: "STARTUP_INTERRUPTED",
      now: now
    )
  }
}

extension RolloutAuthorityStore: RolloutJobInputSnapshotRecording {
  public func freezeJobInputSnapshot(
    _ snapshot: RolloutJobInputSnapshot,
    now: Date
  ) async throws {
    guard case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == snapshot.jobID,
      GitHubInputValidation.validSHA256(snapshot.canonicalInputSHA256),
      GitHubInputValidation.validGitSHA(snapshot.baseSHA),
      snapshot.narrativeSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      snapshot.labelStateSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      snapshot.planSHA256.map(GitHubInputValidation.validSHA256) ?? true
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let nowMilliseconds = Self.milliseconds(now)
    try await database.transaction { database in
      let binding = try Self.loadActiveBinding(
        jobID: snapshot.jobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.validate(snapshot: snapshot, binding: binding)
      let existing = try database.query(
        """
        SELECT canonical_input_sha256, narrative_sha256, base_sha,
          label_state_sha256, plan_sha256
        FROM rollout_job_input_snapshots
        WHERE authorization_id = ? AND job_id = ?
        ORDER BY ordinal DESC LIMIT 1
        """,
        bindings: [
          .text(binding.authorizationID),
          .text(snapshot.jobID.uuidString.lowercased()),
        ]
      ).first
      if let existing,
        try Self.text(existing, "canonical_input_sha256") == snapshot.canonicalInputSHA256,
        try Self.optionalText(existing, "narrative_sha256") == snapshot.narrativeSHA256,
        try Self.text(existing, "base_sha") == snapshot.baseSHA,
        try Self.optionalText(existing, "label_state_sha256") == snapshot.labelStateSHA256,
        try Self.optionalText(existing, "plan_sha256") == snapshot.planSHA256
      {
        return
      }
      guard
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM rollout_effect_reservations
          WHERE authorization_id = ? AND job_id = ?
            AND kind NOT IN ('githubRead', 'gitRemoteRead')
          """,
          bindings: [
            .text(binding.authorizationID),
            .text(snapshot.jobID.uuidString.lowercased()),
          ]
        ) == 0
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let ordinal =
        try database.scalarInt(
          """
          SELECT COALESCE(MAX(ordinal), -1) + 1
          FROM rollout_job_input_snapshots
          WHERE authorization_id = ? AND job_id = ?
          """,
          bindings: [
            .text(binding.authorizationID),
            .text(snapshot.jobID.uuidString.lowercased()),
          ]
        ) ?? 0
      _ = try database.execute(
        """
        INSERT INTO rollout_job_input_snapshots(
          authorization_id, job_id, ordinal, canonical_input_sha256,
          narrative_sha256, base_sha, label_state_sha256, plan_sha256,
          created_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(binding.authorizationID),
          .text(snapshot.jobID.uuidString.lowercased()),
          .integer(ordinal),
          .text(snapshot.canonicalInputSHA256),
          snapshot.narrativeSHA256.map(SQLiteValue.text) ?? .null,
          .text(snapshot.baseSHA),
          snapshot.labelStateSHA256.map(SQLiteValue.text) ?? .null,
          snapshot.planSHA256.map(SQLiteValue.text) ?? .null,
          .integer(nowMilliseconds),
        ]
      )
    }
  }

  private static func validate(
    snapshot: RolloutJobInputSnapshot,
    binding: EffectBinding
  ) throws {
    let fieldsMatchStage: Bool
    switch binding.stage {
    case .prReview, .generatedPRReview:
      fieldsMatchStage =
        snapshot.narrativeSHA256 != nil
        && snapshot.labelStateSHA256 == nil && snapshot.planSHA256 == nil
    case .issueTriage, .implementationPlan:
      fieldsMatchStage =
        snapshot.narrativeSHA256 == nil
        && snapshot.labelStateSHA256 != nil && snapshot.planSHA256 == nil
    case .implementationExecute:
      fieldsMatchStage =
        snapshot.narrativeSHA256 == nil
        && snapshot.labelStateSHA256 != nil && snapshot.planSHA256 != nil
    }
    guard fieldsMatchStage else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    guard binding.scope.mode == .exactObject, let object = binding.scope.object else {
      return
    }
    guard snapshot.canonicalInputSHA256 == object.canonicalInputSHA256,
      snapshot.narrativeSHA256 == object.narrativeSHA256,
      snapshot.baseSHA == object.baseSHA,
      snapshot.labelStateSHA256 == object.labelStateSHA256,
      snapshot.planSHA256 == object.planSHA256
    else {
      throw RolloutAuthorityError.previewDrift
    }
  }
}

extension RolloutScope {
  fileprivate var repositoryUUID: UUID {
    get throws {
      guard let value = UUID(uuidString: repository.id),
        value.uuidString.lowercased() == repository.id
      else {
        throw RolloutAuthorityError.invalidRepositoryIdentity
      }
      return value
    }
  }
}

extension RolloutAuthorityStore {
  private struct ProfileDigestEntry: Codable {
    let role: String
    let provider: String
    let model: String
    let thinking: String
  }

  static func localEvidence(
    repositoryID: UUID,
    scope: RolloutScope? = nil,
    jobBinding: RolloutJobBinding? = nil,
    authorizationID: String? = nil,
    database: isolated SQLiteStore
  ) throws -> RolloutLocalStateEvidence {
    let repository = try loadRepository(repositoryID: repositoryID, database: database)
    let repositoryJSON = try RolloutCanonicalJSON.encode(repository)
    let profiles = try database.query(
      "SELECT role, provider, model, thinking FROM model_profiles ORDER BY role"
    ).map { row in
      ProfileDigestEntry(
        role: try text(row, "role"),
        provider: try text(row, "provider"),
        model: try text(row, "model"),
        thinking: try text(row, "thinking")
      )
    }
    return RolloutLocalStateEvidence(
      inventory: try inventory(
        scope: scope,
        jobBinding: jobBinding,
        authorizationID: authorizationID,
        database: database
      ),
      repositoryConfigurationSHA256: RolloutCanonicalJSON.sha256(repositoryJSON),
      modelProfilesSHA256: RolloutCanonicalJSON.sha256(
        try RolloutCanonicalJSON.encode(profiles)
      )
    )
  }

  private static func inventory(
    scope: RolloutScope? = nil,
    jobBinding: RolloutJobBinding? = nil,
    authorizationID: String? = nil,
    database: isolated SQLiteStore
  ) throws -> RolloutInventory {
    let queue = try boundedRows(
      name: "queue",
      countSQL: """
        SELECT COUNT(*) FROM jobs
        WHERE state IN ('discovered', 'queued', 'retryBackoff', 'waitingHuman',
          'reconciliationQueued')
        """,
      rowsSQL: """
        SELECT * FROM jobs
        WHERE state IN ('discovered', 'queued', 'retryBackoff', 'waitingHuman',
          'reconciliationQueued')
        ORDER BY priority, created_at, id
        """,
      database: database
    )
    let recoveryCollections = try [
      (
        "jobs",
        boundedRows(
          name: "recovery jobs",
          countSQL: "SELECT COUNT(*) FROM jobs WHERE state NOT IN ('succeeded', 'blocked')",
          rowsSQL: """
            SELECT * FROM jobs WHERE state NOT IN ('succeeded', 'blocked')
            ORDER BY priority, created_at, id
            """,
          database: database
        )
      ),
      (
        "leases",
        boundedRows(
          name: "recovery leases",
          countSQL: "SELECT COUNT(*) FROM repository_leases WHERE active = 1",
          rowsSQL: "SELECT * FROM repository_leases WHERE active = 1 ORDER BY repository_id",
          database: database
        )
      ),
      (
        "piRuns",
        boundedRows(
          name: "recovery Pi runs",
          countSQL: "SELECT COUNT(*) FROM pi_runs WHERE settled = 0",
          rowsSQL: "SELECT * FROM pi_runs WHERE settled = 0 ORDER BY id",
          database: database
        )
      ),
      (
        "piLaunches",
        boundedRows(
          name: "recovery Pi launches",
          countSQL: """
            SELECT COUNT(*) FROM pi_run_launches
            WHERE state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
            """,
          rowsSQL: """
            SELECT * FROM pi_run_launches
            WHERE state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
            ORDER BY launch_attempt_id
            """,
          database: database
        )
      ),
      (
        "commands",
        boundedRows(
          name: "recovery commands",
          countSQL: """
            SELECT COUNT(*) FROM approved_command_runs
            WHERE state NOT IN ('succeeded', 'failed', 'timedOut', 'terminated')
            """,
          rowsSQL: """
            SELECT * FROM approved_command_runs
            WHERE state NOT IN ('succeeded', 'failed', 'timedOut', 'terminated')
            ORDER BY id
            """,
          database: database
        )
      ),
      (
        "rolloutEffects",
        boundedRows(
          name: "recovery rollout effects",
          countSQL: "SELECT COUNT(*) FROM rollout_effect_reservations WHERE state != 'settled'",
          rowsSQL: """
            SELECT * FROM rollout_effect_reservations
            WHERE state != 'settled' ORDER BY id
            """,
          database: database
        )
      ),
      (
        "rolloutLocalEffectBindings",
        boundedRows(
          name: "recovery rollout local effect bindings",
          countSQL: """
            SELECT COUNT(*)
            FROM rollout_local_effect_bindings AS binding
            JOIN rollout_effect_reservations AS effect
              ON effect.id = binding.reservation_id
            WHERE effect.state != 'settled'
            """,
          rowsSQL: """
            SELECT binding.*
            FROM rollout_local_effect_bindings AS binding
            JOIN rollout_effect_reservations AS effect
              ON effect.id = binding.reservation_id
            WHERE effect.state != 'settled'
            ORDER BY binding.reservation_id
            """,
          database: database
        )
      ),
      (
        "rolloutScopeReads",
        boundedRows(
          name: "recovery rollout scope reads",
          countSQL: "SELECT COUNT(*) FROM rollout_scope_read_reservations WHERE state != 'settled'",
          rowsSQL:
            "SELECT * FROM rollout_scope_read_reservations WHERE state != 'settled' ORDER BY id",
          database: database
        )
      ),
      (
        "rolloutReadbacks",
        boundedRows(
          name: "recovery rollout readbacks",
          countSQL: "SELECT COUNT(*) FROM rollout_readback_reservations WHERE state != 'settled'",
          rowsSQL:
            "SELECT * FROM rollout_readback_reservations WHERE state != 'settled' ORDER BY id",
          database: database
        )
      ),
      (
        "rolloutGitReadbacks",
        boundedRows(
          name: "recovery rollout Git readbacks",
          countSQL:
            "SELECT COUNT(*) FROM rollout_git_readback_reservations WHERE state != 'settled'",
          rowsSQL:
            "SELECT * FROM rollout_git_readback_reservations WHERE state != 'settled' ORDER BY id",
          database: database
        )
      ),
    ]
    let mutationCollections = try [
      (
        "mutationIntents",
        boundedRows(
          name: "mutation intents",
          countSQL: "SELECT COUNT(*) FROM mutation_intents",
          rowsSQL: "SELECT * FROM mutation_intents ORDER BY id",
          database: database
        )
      ),
      (
        "herdrTopologyIntents",
        boundedRows(
          name: "Herdr topology intents",
          countSQL: "SELECT COUNT(*) FROM herdr_topology_intents",
          rowsSQL: "SELECT * FROM herdr_topology_intents ORDER BY id",
          database: database
        )
      ),
    ]
    let recoveryCount = recoveryCollections.reduce(0) { $0 + $1.1.count }
    let mutationCount = mutationCollections.reduce(0) { $0 + $1.1.count }
    guard recoveryCount <= maximumInventoryRows else {
      throw RolloutAuthorityError.inventoryLimitExceeded("recovery")
    }
    guard mutationCount <= maximumInventoryRows else {
      throw RolloutAuthorityError.inventoryLimitExceeded("mutation")
    }
    let full = RolloutInventory(
      queueSHA256: digest(collections: [("jobs", queue)]),
      recoverySHA256: digest(collections: recoveryCollections),
      mutationIntentSHA256: digest(collections: mutationCollections),
      queueItemCount: queue.count,
      recoveryItemCount: recoveryCount,
      mutationItemCount: mutationCount,
      outsideScopeQueueSHA256: digest(collections: [("jobs", queue)]),
      outsideScopeRecoverySHA256: digest(collections: recoveryCollections),
      outsideScopeMutationIntentSHA256: digest(collections: mutationCollections),
      outsideScopeQueueItemCount: queue.count,
      outsideScopeRecoveryItemCount: recoveryCount,
      outsideScopeMutationItemCount: mutationCount
    )
    guard let scope else { return full }
    let selectedJobIDs = try selectedJobIDs(
      scope: scope,
      jobBinding: jobBinding,
      authorizationID: authorizationID,
      database: database
    )
    guard !selectedJobIDs.isEmpty || authorizationID != nil else { return full }
    let outside = try outsideScopeInventory(
      selectedJobIDs: selectedJobIDs,
      authorizationID: authorizationID,
      database: database
    )
    return RolloutInventory(
      queueSHA256: full.queueSHA256,
      recoverySHA256: full.recoverySHA256,
      mutationIntentSHA256: full.mutationIntentSHA256,
      queueItemCount: full.queueItemCount,
      recoveryItemCount: full.recoveryItemCount,
      mutationItemCount: full.mutationItemCount,
      outsideScopeQueueSHA256: outside.queueSHA256,
      outsideScopeRecoverySHA256: outside.recoverySHA256,
      outsideScopeMutationIntentSHA256: outside.mutationIntentSHA256,
      outsideScopeQueueItemCount: outside.queueItemCount,
      outsideScopeRecoveryItemCount: outside.recoveryItemCount,
      outsideScopeMutationItemCount: outside.mutationItemCount
    )
  }

  private static func selectedJobIDs(
    scope: RolloutScope,
    jobBinding: RolloutJobBinding?,
    authorizationID: String?,
    database: isolated SQLiteStore
  ) throws -> Set<String> {
    var selected = Set<String>()
    if let jobBinding {
      selected.insert(jobBinding.jobID)
    }
    if let authorizationID {
      let rows = try database.query(
        "SELECT job_id FROM rollout_job_bindings WHERE authorization_id = ?",
        bindings: [.text(authorizationID)]
      )
      for row in rows { selected.insert(try text(row, "job_id")) }
    }
    guard scope.mode == .finiteWindow, let window = scope.finiteWindow else {
      return selected
    }
    let candidates = Set(
      window.candidates.map {
        "\($0.nodeID)\u{0}\($0.number)\u{0}\($0.revisionKey)"
      }
    )
    let rows = try database.query(
      "SELECT id, kind, object_node_id, object_number, revision_key FROM jobs WHERE repository_id = ?",
      bindings: [.text(scope.repository.id)]
    )
    for row in rows {
      guard let kind = JobKind(rawValue: try text(row, "kind")), scope.stage.accepts(jobKind: kind),
        let number = try optionalInteger(row, "object_number").map(Int.init),
        candidates.contains(
          "\(try text(row, "object_node_id"))\u{0}\(number)\u{0}\(try text(row, "revision_key"))"
        )
      else { continue }
      selected.insert(try text(row, "id"))
    }
    return selected
  }

  private struct OutsideScopeInventory {
    let queueSHA256: String
    let recoverySHA256: String
    let mutationIntentSHA256: String
    let queueItemCount: Int
    let recoveryItemCount: Int
    let mutationItemCount: Int
  }

  private static func outsideScopeInventory(
    selectedJobIDs: Set<String>,
    authorizationID: String?,
    database: isolated SQLiteStore
  ) throws -> OutsideScopeInventory {
    let jobIDs = selectedJobIDs.sorted()
    let exclusion =
      jobIDs.isEmpty
      ? ""
      : " AND job_id NOT IN (\(Array(repeating: "?", count: jobIDs.count).joined(separator: ",")))"
    let jobExclusion =
      jobIDs.isEmpty
      ? "" : " AND id NOT IN (\(Array(repeating: "?", count: jobIDs.count).joined(separator: ",")))"
    let bindings = jobIDs.map(SQLiteValue.text)
    let queue = try boundedRows(
      name: "outside-scope queue",
      rowsSQL: """
        SELECT * FROM jobs
        WHERE state IN ('discovered', 'queued', 'retryBackoff', 'waitingHuman',
          'reconciliationQueued')\(jobExclusion)
        ORDER BY priority, created_at, id
        """,
      bindings: bindings,
      database: database
    )
    let recoveryJobs = try boundedRows(
      name: "outside-scope recovery jobs",
      rowsSQL: """
        SELECT * FROM jobs WHERE state NOT IN ('succeeded', 'blocked')\(jobExclusion)
        ORDER BY priority, created_at, id
        """,
      bindings: bindings,
      database: database
    )
    let leases = try boundedRows(
      name: "outside-scope recovery leases",
      rowsSQL:
        "SELECT * FROM repository_leases WHERE active = 1\(exclusion) ORDER BY repository_id",
      bindings: bindings,
      database: database
    )
    let piRuns = try boundedRows(
      name: "outside-scope recovery Pi runs",
      rowsSQL: "SELECT * FROM pi_runs WHERE settled = 0\(exclusion) ORDER BY id",
      bindings: bindings,
      database: database
    )
    let runExclusion =
      jobIDs.isEmpty
      ? ""
      : " AND run_id NOT IN (SELECT id FROM pi_runs WHERE job_id IN (\(Array(repeating: "?", count: jobIDs.count).joined(separator: ","))))"
    let piLaunches = try boundedRows(
      name: "outside-scope recovery Pi launches",
      rowsSQL: """
        SELECT * FROM pi_run_launches
        WHERE state IN ('prepared', 'enqueued', 'running', 'resultPrepared')\(runExclusion)
        ORDER BY launch_attempt_id
        """,
      bindings: bindings,
      database: database
    )
    let commands = try boundedRows(
      name: "outside-scope recovery commands",
      rowsSQL: """
        SELECT * FROM approved_command_runs
        WHERE state NOT IN ('succeeded', 'failed', 'timedOut', 'terminated')\(exclusion)
        ORDER BY id
        """,
      bindings: bindings,
      database: database
    )
    let authorizationExclusion = authorizationID.map { _ in " AND authorization_id != ?" } ?? ""
    let authorizationBindings: [SQLiteValue] =
      authorizationID.map {
        [SQLiteValue.text($0)]
      } ?? []
    let effects = try boundedRows(
      name: "outside-scope recovery rollout effects",
      rowsSQL: """
        SELECT * FROM rollout_effect_reservations
        WHERE state != 'settled'\(exclusion)\(authorizationExclusion) ORDER BY id
        """,
      bindings: bindings + authorizationBindings,
      database: database
    )
    let localEffectJobExclusion =
      jobIDs.isEmpty
      ? ""
      : " AND effect.job_id NOT IN (\(Array(repeating: "?", count: jobIDs.count).joined(separator: ",")))"
    let localEffectAuthorizationExclusion =
      authorizationID.map { _ in " AND effect.authorization_id != ?" } ?? ""
    let localEffectBindings = try boundedRows(
      name: "outside-scope rollout local effect bindings",
      rowsSQL: """
        SELECT binding.*
        FROM rollout_local_effect_bindings AS binding
        JOIN rollout_effect_reservations AS effect
          ON effect.id = binding.reservation_id
        WHERE effect.state != 'settled'\(localEffectJobExclusion)\(localEffectAuthorizationExclusion)
        ORDER BY binding.reservation_id
        """,
      bindings: bindings + authorizationBindings,
      database: database
    )
    let scopeReads = try boundedRows(
      name: "outside-scope recovery rollout scope reads",
      rowsSQL: """
        SELECT * FROM rollout_scope_read_reservations
        WHERE state != 'settled'\(authorizationExclusion) ORDER BY id
        """,
      bindings: authorizationBindings,
      database: database
    )
    let readbacks = try boundedRows(
      name: "outside-scope recovery rollout readbacks",
      rowsSQL: """
        SELECT * FROM rollout_readback_reservations
        WHERE state != 'settled'\(exclusion)\(authorizationExclusion) ORDER BY id
        """,
      bindings: bindings + authorizationBindings,
      database: database
    )
    let gitReadbacks = try boundedRows(
      name: "outside-scope recovery rollout Git readbacks",
      rowsSQL: """
        SELECT * FROM rollout_git_readback_reservations
        WHERE state != 'settled'\(exclusion)\(authorizationExclusion) ORDER BY id
        """,
      bindings: bindings + authorizationBindings,
      database: database
    )
    let intents = try boundedRows(
      name: "outside-scope mutation intents",
      rowsSQL: "SELECT * FROM mutation_intents WHERE 1 = 1\(exclusion) ORDER BY id",
      bindings: bindings,
      database: database
    )
    let topology = try boundedRows(
      name: "outside-scope Herdr topology intents",
      rowsSQL: "SELECT * FROM herdr_topology_intents WHERE 1 = 1\(exclusion) ORDER BY id",
      bindings: bindings,
      database: database
    )
    let recovery: [(String, [SQLiteRow])] = [
      ("jobs", recoveryJobs), ("leases", leases), ("piRuns", piRuns),
      ("piLaunches", piLaunches), ("commands", commands), ("rolloutEffects", effects),
      ("rolloutLocalEffectBindings", localEffectBindings),
      ("rolloutScopeReads", scopeReads), ("rolloutReadbacks", readbacks),
      ("rolloutGitReadbacks", gitReadbacks),
    ]
    let mutations: [(String, [SQLiteRow])] = [
      ("mutationIntents", intents), ("herdrTopologyIntents", topology),
    ]
    let recoveryCount = recovery.reduce(0) { $0 + $1.1.count }
    let mutationCount = mutations.reduce(0) { $0 + $1.1.count }
    guard recoveryCount <= maximumInventoryRows, mutationCount <= maximumInventoryRows else {
      throw RolloutAuthorityError.inventoryLimitExceeded("outside scope")
    }
    return OutsideScopeInventory(
      queueSHA256: digest(collections: [("jobs", queue)]),
      recoverySHA256: digest(collections: recovery),
      mutationIntentSHA256: digest(collections: mutations),
      queueItemCount: queue.count,
      recoveryItemCount: recoveryCount,
      mutationItemCount: mutationCount
    )
  }

  private static func boundedRows(
    name: String,
    rowsSQL: String,
    bindings: [SQLiteValue],
    database: isolated SQLiteStore
  ) throws -> [SQLiteRow] {
    let rows = try database.query(rowsSQL, bindings: bindings)
    guard rows.count <= maximumInventoryRows else {
      throw RolloutAuthorityError.inventoryLimitExceeded(name)
    }
    return rows
  }

  private static func boundedRows(
    name: String,
    countSQL: String,
    rowsSQL: String,
    database: isolated SQLiteStore
  ) throws -> [SQLiteRow] {
    let count = Int(try database.scalarInt(countSQL) ?? 0)
    guard count <= maximumInventoryRows else {
      throw RolloutAuthorityError.inventoryLimitExceeded(name)
    }
    let rows = try database.query(rowsSQL)
    guard rows.count == count else {
      throw RolloutAuthorityError.previewDrift
    }
    return rows
  }

  private static func digest(collections: [(String, [SQLiteRow])]) -> String {
    var hasher = SHA256()
    for (name, rows) in collections {
      update(&hasher, value: "collection")
      update(&hasher, value: name)
      update(&hasher, value: String(rows.count))
      for row in rows {
        update(&hasher, value: "row")
        for column in row.columns {
          update(&hasher, value: column)
          switch row[column] {
          case .integer(let value):
            update(&hasher, value: "integer")
            update(&hasher, value: String(value))
          case .real(let value):
            update(&hasher, value: "real")
            update(&hasher, value: String(value.bitPattern, radix: 16))
          case .text(let value):
            update(&hasher, value: "text")
            update(&hasher, data: Data(value.utf8))
          case .blob(let value):
            update(&hasher, value: "blob")
            update(&hasher, data: value)
          case .null:
            update(&hasher, value: "null")
          case nil:
            update(&hasher, value: "missing")
          }
        }
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func update(_ hasher: inout SHA256, value: String) {
    update(&hasher, data: Data(value.utf8))
  }

  private static func update(_ hasher: inout SHA256, data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }
}

extension RolloutAuthorityStore {
  private static func loadRepository(
    repositoryID: UUID,
    database: isolated SQLiteStore
  ) throws -> RolloutRepositoryIdentity {
    guard
      let row = try database.query(
        "SELECT * FROM repositories WHERE id = ?",
        bindings: [.text(repositoryID.uuidString.lowercased())]
      ).first
    else {
      throw RolloutAuthorityError.invalidRepositoryIdentity
    }
    return RolloutRepositoryIdentity(
      id: repositoryID,
      nodeID: try text(row, "node_id"),
      owner: try text(row, "owner"),
      name: try text(row, "name"),
      defaultBranch: try text(row, "default_branch"),
      enabled: try integer(row, "enabled") == 1,
      reviewEnabled: try integer(row, "review_enabled") == 1,
      triageEnabled: try integer(row, "triage_enabled") == 1,
      implementationEnabled: try integer(row, "implementation_enabled") == 1
    )
  }

  private static func requireRepository(
    _ expected: RolloutRepositoryIdentity,
    release: RolloutReleaseIdentity,
    database: isolated SQLiteStore
  ) throws {
    guard let repositoryID = UUID(uuidString: expected.id),
      try loadRepository(repositoryID: repositoryID, database: database) == expected,
      try database.schemaVersion() == 10,
      let settings = try database.query(
        "SELECT * FROM app_settings WHERE singleton = 1"
      ).first,
      try integer(settings, "max_concurrency") == 1,
      try optionalText(settings, "github_account") == release.githubAccount,
      try optionalInteger(settings, "github_author_id") == release.githubAuthorID
    else {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private static func requireActivationSettings(database: isolated SQLiteStore) throws {
    guard
      let row = try database.query(
        "SELECT paused, max_concurrency, active_rollout_authorization_id FROM app_settings WHERE singleton = 1"
      ).first,
      try integer(row, "paused") == 1,
      try integer(row, "max_concurrency") == 1,
      try optionalText(row, "active_rollout_authorization_id") == nil,
      try database.scalarInt(
        """
        SELECT COUNT(*) FROM rollout_authorizations
        WHERE state IN ('active', 'draining', 'recoveryRequired')
        """
      ) == 0
    else {
      throw RolloutAuthorityError.authorizationCollision
    }
  }

  private static func insertAuthorization(
    id: String,
    preview: RolloutPreview,
    activatedAtMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    let payload = preview.payload
    _ = try database.execute(
      """
      INSERT INTO rollout_authorizations(
        id, preview_sha256, policy_version, state, scope_mode, workflow_stage,
        repository_id, activated_at_ms, expires_at_ms, updated_at_ms
      ) VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(id),
        .text(preview.sha256),
        .integer(Int64(payload.policyVersion.rawValue)),
        .text(payload.scope.mode.rawValue),
        .text(payload.scope.stage.rawValue),
        .text(payload.scope.repository.id),
        .integer(activatedAtMilliseconds),
        .integer(
          payload.scope.finiteWindow?.expiresAtMilliseconds
            ?? payload.expiresAtMilliseconds
        ),
        .integer(activatedAtMilliseconds),
      ]
    )
  }

  private static func requireFinitePromotion(
    preview: RolloutPreview,
    activatedAtMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    guard let window = preview.payload.scope.finiteWindow else {
      throw RolloutAuthorityError.invalidFiniteWindow
    }
    let repositoryID = preview.payload.scope.repository.id
    let stage = preview.payload.scope.stage.rawValue
    let exactReceiptCount =
      try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM rollout_authorizations AS authorization
        WHERE authorization.repository_id = ?
          AND authorization.workflow_stage = ?
          AND authorization.scope_mode = 'exactObject'
          AND authorization.state = 'settled'
          AND EXISTS (
            SELECT 1 FROM rollout_authorization_events AS event
            WHERE event.authorization_id = authorization.id
              AND event.kind = 'settled'
              AND event.checkpoint_sha256 IS NOT NULL
          )
          AND NOT EXISTS (
            SELECT 1 FROM rollout_effect_reservations AS effect
            WHERE effect.authorization_id = authorization.id
              AND effect.state != 'settled'
          )
          AND NOT EXISTS (
            SELECT 1 FROM rollout_scope_read_reservations AS read
            WHERE read.authorization_id = authorization.id
              AND read.state != 'settled'
          )
          AND NOT EXISTS (
            SELECT 1 FROM rollout_readback_reservations AS readback
            WHERE readback.authorization_id = authorization.id
              AND readback.state != 'settled'
          )
          AND NOT EXISTS (
            SELECT 1 FROM rollout_git_readback_reservations AS readback
            WHERE readback.authorization_id = authorization.id
              AND readback.state != 'settled'
          )
        """,
        bindings: [.text(repositoryID), .text(stage)]
      ) ?? 0
    guard exactReceiptCount > 0 else {
      throw RolloutAuthorityError.finitePromotionRequired
    }

    let priorFiniteCount =
      try database.scalarInt(
        """
        SELECT COUNT(*) FROM rollout_authorizations
        WHERE repository_id = ? AND workflow_stage = ?
          AND scope_mode = 'finiteWindow'
        """,
        bindings: [.text(repositoryID), .text(stage)]
      ) ?? 0
    if priorFiniteCount == 0 {
      guard window.maximumJobs <= 3,
        window.expiresAtMilliseconds - activatedAtMilliseconds
          <= RolloutPreviewBuilder.firstFiniteWindowLifetimeMilliseconds
      else {
        throw RolloutAuthorityError.finitePromotionRequired
      }
      return
    }

    guard window.maximumJobs <= 10,
      window.expiresAtMilliseconds - activatedAtMilliseconds
        <= RolloutPreviewBuilder.laterFiniteWindowLifetimeMilliseconds,
      try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM rollout_authorizations AS authorization
        WHERE authorization.repository_id = ?
          AND authorization.workflow_stage = ?
          AND authorization.scope_mode = 'finiteWindow'
          AND authorization.state = 'settled'
          AND EXISTS (
            SELECT 1 FROM rollout_authorization_events AS event
            WHERE event.authorization_id = authorization.id
              AND event.kind = 'settled'
              AND event.checkpoint_sha256 IS NOT NULL
          )
          AND NOT EXISTS (
            SELECT 1 FROM rollout_effect_reservations AS effect
            WHERE effect.authorization_id = authorization.id
              AND effect.state != 'settled'
          )
        """,
        bindings: [.text(repositoryID), .text(stage)]
      ) == priorFiniteCount
    else {
      throw RolloutAuthorityError.finitePromotionRequired
    }
  }

  private static func insertScope(
    authorizationID: String,
    preview: RolloutPreview,
    database: isolated SQLiteStore
  ) throws {
    let payload = preview.payload
    let scope = payload.scope
    let repository = scope.repository
    let object = scope.object
    let window = scope.finiteWindow
    let candidateData = try RolloutCanonicalJSON.encode(window?.candidates ?? [])
    let labelData = try RolloutCanonicalJSON.encode(payload.missingLabels)
    let commandData = try RolloutCanonicalJSON.encode(payload.commands)
    let envelopeData = try RolloutCanonicalJSON.encode(payload.effectEnvelope)
    guard let previewJSON = String(data: preview.canonicalJSON, encoding: .utf8) else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    _ = try database.execute(
      """
      INSERT INTO rollout_authorization_scopes(
        authorization_id,
        repository_node_id, repository_owner, repository_name, default_branch,
        repository_enabled, review_enabled, triage_enabled, implementation_enabled,
        object_node_id, object_number, revision_key, canonical_input_sha256,
        head_sha, base_sha, plan_sha256, narrative_sha256, label_state_sha256,
        current_step, finite_predicate_version, finite_candidates_sha256,
        finite_candidate_count,
        source_commit, source_tree, bundle_version, bundle_build,
        application_sha256, helper_sha256, ask_pass_sha256, push_guard_sha256,
        herdr_host_sha256,
        schema_version, engine_protocol_version,
        runtime_manifest_sha256, runtime_tree_sha256, model_profiles_sha256,
        workflow_resources_sha256, github_account, github_author_id,
        repository_configuration_sha256,
        queue_inventory_sha256, recovery_inventory_sha256, mutation_inventory_sha256,
        queue_item_count, recovery_item_count, mutation_item_count,
        outside_scope_queue_sha256, outside_scope_recovery_sha256,
        outside_scope_mutation_sha256, outside_scope_queue_item_count,
        outside_scope_recovery_item_count, outside_scope_mutation_item_count,
        missing_labels_sha256, missing_label_count,
        command_plan_sha256, command_count,
        effect_envelope_sha256, preview_json
      ) VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      )
      """,
      bindings: [
        .text(authorizationID),
        .text(repository.nodeID),
        .text(repository.owner),
        .text(repository.name),
        .text(repository.defaultBranch),
        .integer(repository.enabled ? 1 : 0),
        .integer(repository.reviewEnabled ? 1 : 0),
        .integer(repository.triageEnabled ? 1 : 0),
        .integer(repository.implementationEnabled ? 1 : 0),
        object.map { .text($0.nodeID) } ?? .null,
        object.map { .integer(Int64($0.number)) } ?? .null,
        object.map { .text($0.revisionKey) } ?? .null,
        object.map { .text($0.canonicalInputSHA256) } ?? .null,
        object?.headSHA.map(SQLiteValue.text) ?? .null,
        object?.baseSHA.map(SQLiteValue.text) ?? .null,
        object?.planSHA256.map(SQLiteValue.text) ?? .null,
        object?.narrativeSHA256.map(SQLiteValue.text) ?? .null,
        object?.labelStateSHA256.map(SQLiteValue.text) ?? .null,
        .text(object?.currentStep ?? "discovery"),
        window.map { .integer(Int64($0.predicateVersion)) } ?? .null,
        window.map { _ in .text(RolloutCanonicalJSON.sha256(candidateData)) } ?? .null,
        window.map { .integer(Int64($0.candidates.count)) } ?? .null,
        .text(payload.releaseIdentity.sourceCommit),
        .text(payload.releaseIdentity.sourceTree),
        .text(payload.releaseIdentity.bundleVersion),
        .integer(Int64(payload.releaseIdentity.bundleBuild)),
        .text(payload.releaseIdentity.applicationSHA256),
        .text(payload.releaseIdentity.helperSHA256),
        .text(payload.releaseIdentity.askPassSHA256),
        .text(payload.releaseIdentity.pushGuardSHA256),
        .text(payload.releaseIdentity.herdrHostSHA256),
        .integer(Int64(payload.releaseIdentity.schemaVersion)),
        .integer(Int64(payload.releaseIdentity.engineProtocolVersion)),
        .text(payload.releaseIdentity.runtimeManifestSHA256),
        .text(payload.releaseIdentity.runtimeTreeSHA256),
        .text(payload.releaseIdentity.modelProfilesSHA256),
        .text(payload.releaseIdentity.workflowResourcesSHA256),
        .text(payload.releaseIdentity.githubAccount),
        .integer(payload.releaseIdentity.githubAuthorID),
        .text(payload.releaseIdentity.repositoryConfigurationSHA256),
        .text(payload.inventory.queueSHA256),
        .text(payload.inventory.recoverySHA256),
        .text(payload.inventory.mutationIntentSHA256),
        .integer(Int64(payload.inventory.queueItemCount)),
        .integer(Int64(payload.inventory.recoveryItemCount)),
        .integer(Int64(payload.inventory.mutationItemCount)),
        .text(payload.inventory.outsideScopeQueueSHA256),
        .text(payload.inventory.outsideScopeRecoverySHA256),
        .text(payload.inventory.outsideScopeMutationIntentSHA256),
        .integer(Int64(payload.inventory.outsideScopeQueueItemCount)),
        .integer(Int64(payload.inventory.outsideScopeRecoveryItemCount)),
        .integer(Int64(payload.inventory.outsideScopeMutationItemCount)),
        .text(RolloutCanonicalJSON.sha256(labelData)),
        .integer(Int64(payload.missingLabels.count)),
        .text(RolloutCanonicalJSON.sha256(commandData)),
        .integer(Int64(payload.commands.count)),
        .text(RolloutCanonicalJSON.sha256(envelopeData)),
        .text(previewJSON),
      ]
    )
  }

  private static func insertBudget(
    authorizationID: String,
    budgets: RolloutBudgets,
    database: isolated SQLiteStore
  ) throws {
    _ = try database.execute(
      """
      INSERT INTO rollout_authorization_budgets(
        authorization_id, jobs, github_read_requests, github_read_pages,
        github_read_bytes, git_remote_reads, provider_sessions, approved_commands,
        marker_parts, label_writes, branch_creates, pull_request_creates,
        github_sends, git_sends
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: budgetBindings(authorizationID: authorizationID, budgets: budgets)
    )
  }

  private static func budgetBindings(
    authorizationID: String,
    budgets: RolloutBudgets
  ) -> [SQLiteValue] {
    [
      .text(authorizationID),
      .integer(Int64(budgets.jobs)),
      .integer(Int64(budgets.githubReadRequests)),
      .integer(Int64(budgets.githubReadPages)),
      .integer(budgets.githubReadBytes),
      .integer(Int64(budgets.gitRemoteReads)),
      .integer(Int64(budgets.providerSessions)),
      .integer(Int64(budgets.approvedCommands)),
      .integer(Int64(budgets.markerParts)),
      .integer(Int64(budgets.labelWrites)),
      .integer(Int64(budgets.branchCreates)),
      .integer(Int64(budgets.pullRequestCreates)),
      .integer(Int64(budgets.githubSends)),
      .integer(Int64(budgets.gitSends)),
    ]
  }
}

extension RolloutAuthorityStore {
  private static func insertCandidates(
    authorizationID: String,
    candidates: [RolloutWindowCandidate],
    database: isolated SQLiteStore
  ) throws {
    for candidate in candidates {
      _ = try database.execute(
        """
        INSERT INTO rollout_window_candidates(
          authorization_id, ordinal, object_node_id, object_number,
          revision_key, canonical_input_sha256
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(authorizationID),
          .integer(Int64(candidate.ordinal)),
          .text(candidate.nodeID),
          .integer(Int64(candidate.number)),
          .text(candidate.revisionKey),
          .text(candidate.canonicalInputSHA256),
        ]
      )
    }
  }

  private static func ensureExactJob(
    binding: RolloutJobBinding,
    object: RolloutObjectSelector,
    scope: RolloutScope,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    guard let jobID = UUID(uuidString: binding.jobID),
      jobID.uuidString.lowercased() == binding.jobID,
      binding.objectNumber == object.number
    else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    let rows = try database.query(
      "SELECT * FROM jobs WHERE id = ?",
      bindings: [.text(binding.jobID)]
    )
    if let row = rows.first {
      let generatedLinkCount =
        try database.scalarInt(
          "SELECT COUNT(*) FROM rollout_generated_job_links WHERE child_job_id = ?",
          bindings: [.text(binding.jobID)]
        ) ?? 0
      guard rows.count == 1,
        scope.stage == .generatedPRReview
          ? generatedLinkCount == 1
          : scope.stage == .prReview ? generatedLinkCount == 0 : true,
        try text(row, "repository_id") == scope.repository.id,
        try text(row, "kind") == binding.jobKind.rawValue,
        try text(row, "object_node_id") == object.nodeID,
        try optionalInteger(row, "object_number") == Int64(binding.objectNumber),
        try text(row, "revision_key") == object.revisionKey,
        try text(row, "contract_version_used") == binding.contractVersion,
        try integer(row, "priority") == Int64(binding.priority.rawValue),
        try optionalText(row, "current_step_kind") == binding.currentStep,
        let state = JobState(rawValue: try text(row, "state")),
        scope.stage != .implementationExecute
          || binding.currentStep != JobStepKind.publishPlan.rawValue
          || state == .waitingHuman,
        !state.isTerminal
      else {
        throw RolloutAuthorityError.previewDrift
      }
    } else {
      guard binding.currentStep == binding.firstStep.rawValue,
        validNewExactJob(binding: binding, stage: scope.stage)
      else {
        throw RolloutAuthorityError.invalidJobBinding
      }
      _ = try database.execute(
        """
        INSERT INTO jobs(
          id, repository_id, kind, object_node_id, object_number, revision_key,
          contract_version_used, priority, state, current_step, current_step_kind,
          attempt, created_at, updated_at, rollout_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, 0, ?, ?, 1)
        """,
        bindings: [
          .text(binding.jobID),
          .text(scope.repository.id),
          .text(binding.jobKind.rawValue),
          .text(object.nodeID),
          .integer(Int64(object.number)),
          .text(object.revisionKey),
          .text(binding.contractVersion),
          .integer(Int64(binding.priority.rawValue)),
          .text(binding.firstStep.rawValue),
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
        """,
        bindings: [
          .text(scope.repository.id),
          .text(binding.jobKind.rawValue),
          .text(object.nodeID),
          .text(object.revisionKey),
          .text(binding.contractVersion),
          .text(binding.jobID),
          .real(now.timeIntervalSince1970),
        ]
      )
      _ = try database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, 'discovered', 'queued', 'rollout exact activation',
          0, 0, 0, 0, ?)
        """,
        bindings: [
          .text(binding.jobID),
          .text("rollout-create:\(binding.jobID)"),
          .real(now.timeIntervalSince1970),
        ]
      )
    }
    _ = try database.execute(
      "UPDATE jobs SET rollout_generation = 1 WHERE id = ? AND rollout_generation IN (0, 1)",
      bindings: [.text(binding.jobID)]
    )
    guard try database.scalarInt("SELECT changes()") == 1 else {
      throw RolloutAuthorityError.jobBindingMismatch
    }
  }

  private static func validNewExactJob(
    binding: RolloutJobBinding,
    stage: RolloutWorkflowStage
  ) -> Bool {
    switch stage {
    case .prReview:
      binding.jobKind == .prReview
        && binding.priority == .prReview
        && binding.firstStep == .review
    case .issueTriage:
      binding.jobKind == .issueTriage
        && binding.priority == .triage
        && binding.firstStep == .triage
    case .implementationPlan:
      binding.jobKind == .issueImplementation
        && binding.priority == .issueImplementation
        && binding.firstStep == .claimReady
    case .implementationExecute, .generatedPRReview:
      false
    }
  }

  static func insertJobBinding(
    authorizationID: String,
    binding: RolloutJobBinding,
    scope: RolloutScope,
    objectNodeID: String,
    revisionKey: String,
    canonicalInputSHA256: String,
    jobSlot: Int,
    nowMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    _ = try database.execute(
      """
      INSERT INTO rollout_job_bindings(
        authorization_id, job_id, repository_id, workflow_stage,
        object_node_id, revision_key, canonical_input_sha256,
        current_step, job_slot, created_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(authorizationID),
        .text(binding.jobID),
        .text(scope.repository.id),
        .text(scope.stage.rawValue),
        .text(objectNodeID),
        .text(revisionKey),
        .text(canonicalInputSHA256),
        .text(binding.currentStep),
        .integer(Int64(jobSlot)),
        .integer(nowMilliseconds),
      ]
    )
  }

  static func insertEvent(
    authorizationID: String,
    eventKey: String,
    kind: RolloutAuthorizationEventKind,
    from: RolloutAuthorizationState?,
    to: RolloutAuthorizationState,
    reasonCode: String,
    checkpointSHA256: String?,
    nowMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    _ = try database.execute(
      """
      INSERT INTO rollout_authorization_events(
        authorization_id, event_key, kind, from_state, to_state,
        reason_code, checkpoint_sha256, created_at_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(authorizationID),
        .text(eventKey),
        .text(kind.rawValue),
        from.map { .text($0.rawValue) } ?? .null,
        .text(to.rawValue),
        .text(reasonCode),
        checkpointSHA256.map(SQLiteValue.text) ?? .null,
        .integer(nowMilliseconds),
      ]
    )
  }
}

extension RolloutAuthorityStore {
  private func transitionLane(
    authorizationID: String,
    target: RolloutAuthorizationState,
    eventKind: RolloutAuthorizationEventKind,
    reasonCode: String,
    checkpointSHA256: String? = nil,
    requireEffectsSettled: Bool,
    now: Date
  ) async throws -> RolloutStatusReport {
    guard RolloutPreviewBuilder.validLowercaseUUID(authorizationID),
      RolloutPreviewBuilder.validIdentifier(reasonCode, maximum: 128),
      checkpointSHA256.map(GitHubInputValidation.validSHA256) ?? true
    else {
      throw RolloutAuthorityError.invalidStateTransition
    }
    try await database.transaction { database in
      let current = try Self.authorizationState(id: authorizationID, database: database)
      if current == target { return }
      if requireEffectsSettled {
        guard
          try database.scalarInt(
            """
            SELECT
              (SELECT COUNT(*) FROM rollout_effect_reservations
               WHERE authorization_id = ? AND state != 'settled') +
              (SELECT COUNT(*) FROM rollout_scope_read_reservations
               WHERE authorization_id = ? AND state != 'settled') +
              (SELECT COUNT(*) FROM rollout_readback_reservations
               WHERE authorization_id = ? AND state != 'settled') +
              (SELECT COUNT(*) FROM rollout_git_readback_reservations
               WHERE authorization_id = ? AND state != 'settled')
            """,
            bindings: Array(repeating: .text(authorizationID), count: 4)
          ) == 0
        else {
          throw RolloutAuthorityError.invalidStateTransition
        }
      }
      if target != .draining {
        _ = try database.execute(
          """
          UPDATE app_settings
          SET paused = 1,
              active_rollout_authorization_id = CASE WHEN ? = 1 THEN NULL
                ELSE active_rollout_authorization_id END,
              updated_at = ?
          WHERE singleton = 1
          """,
          bindings: [
            .integer(target.isOpenLane ? 0 : 1),
            .real(now.timeIntervalSince1970),
          ]
        )
      }
      let changed = try database.execute(
        """
        UPDATE rollout_authorizations
        SET state = ?, updated_at_ms = ?, terminal_reason = ?
        WHERE id = ? AND state = ?
        """,
        bindings: [
          .text(target.rawValue),
          .integer(Self.milliseconds(now)),
          target.isOpenLane ? .null : .text(reasonCode),
          .text(authorizationID),
          .text(current.rawValue),
        ]
      )
      guard changed == 1 else {
        throw RolloutAuthorityError.invalidStateTransition
      }
      try Self.insertEvent(
        authorizationID: authorizationID,
        eventKey: "state:\(authorizationID):\(target.rawValue)",
        kind: eventKind,
        from: current,
        to: target,
        reasonCode: reasonCode,
        checkpointSHA256: checkpointSHA256,
        nowMilliseconds: Self.milliseconds(now),
        database: database
      )
    }
    return try await status(authorizationID: authorizationID)
  }

  private static func status(
    authorizationID: String,
    database: isolated SQLiteStore
  ) throws -> RolloutStatusReport {
    guard RolloutPreviewBuilder.validLowercaseUUID(authorizationID),
      let authorizationRow = try database.query(
        "SELECT * FROM rollout_authorizations WHERE id = ?",
        bindings: [.text(authorizationID)]
      ).first,
      let scopeRow = try database.query(
        "SELECT preview_json FROM rollout_authorization_scopes WHERE authorization_id = ?",
        bindings: [.text(authorizationID)]
      ).first,
      let budgetRow = try database.query(
        "SELECT * FROM rollout_authorization_budgets WHERE authorization_id = ?",
        bindings: [.text(authorizationID)]
      ).first
    else {
      throw RolloutAuthorityError.authorizationNotFound(authorizationID)
    }
    let authorization = try decodeAuthorization(authorizationRow)
    let previewText = try text(scopeRow, "preview_json")
    guard let previewData = previewText.data(using: .utf8) else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    let preview = try RolloutPreviewBuilder.parseCanonical(previewData)
    guard preview.sha256 == authorization.previewSHA256,
      preview.payload.scope.mode == authorization.scopeMode,
      preview.payload.scope.stage == authorization.workflowStage,
      preview.payload.scope.repository.id == authorization.repositoryID.uuidString.lowercased()
    else {
      throw RolloutAuthorityError.previewDrift
    }
    let initial = try decodeBudgets(budgetRow)
    guard initial == preview.payload.budgets else {
      throw RolloutAuthorityError.previewDrift
    }
    let jobRows = try database.query(
      "SELECT job_id FROM rollout_job_bindings WHERE authorization_id = ? ORDER BY job_slot",
      bindings: [.text(authorizationID)]
    )
    let boundJobs = try jobRows.map { row -> UUID in
      let value = try text(row, "job_id")
      guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
        throw RolloutAuthorityError.decode("rollout job binding")
      }
      return id
    }
    let reservationRows = try database.query(
      """
      SELECT * FROM rollout_effect_reservations
      WHERE authorization_id = ? ORDER BY created_at_ms, id
      """,
      bindings: [.text(authorizationID)]
    )
    let reservations = try reservationRows.map(decodeReservation)
    guard
      let usageRow = try database.query(
        """
        SELECT * FROM rollout_authorization_usage
        WHERE authorization_id = ?
        ORDER BY sequence DESC LIMIT 1
        """,
        bindings: [.text(authorizationID)]
      ).first
    else {
      throw RolloutAuthorityError.decode("rollout usage ledger")
    }
    let usage = RolloutBudgets(
      jobs: boundJobs.count,
      githubReadRequests: Int(try integer(usageRow, "github_read_requests")),
      githubReadPages: Int(try integer(usageRow, "github_read_pages")),
      githubReadBytes: try integer(usageRow, "github_read_bytes"),
      gitRemoteReads: Int(try integer(usageRow, "git_remote_reads")),
      providerSessions: Int(try integer(usageRow, "provider_sessions")),
      approvedCommands: Int(try integer(usageRow, "approved_commands")),
      markerParts: Int(try integer(usageRow, "marker_parts")),
      labelWrites: Int(try integer(usageRow, "label_writes")),
      branchCreates: Int(try integer(usageRow, "branch_creates")),
      pullRequestCreates: Int(try integer(usageRow, "pull_request_creates")),
      githubSends: Int(try integer(usageRow, "github_sends")),
      gitSends: Int(try integer(usageRow, "git_sends"))
    )
    let events = try database.query(
      """
      SELECT * FROM rollout_authorization_events
      WHERE authorization_id = ? ORDER BY id
      """,
      bindings: [.text(authorizationID)]
    ).map(decodeEvent)
    return RolloutStatusReport(
      authorization: authorization,
      releaseIdentity: preview.payload.releaseIdentity,
      scope: preview.payload.scope,
      effectEnvelope: preview.payload.effectEnvelope,
      missingLabels: preview.payload.missingLabels,
      commands: preview.payload.commands,
      initialBudgets: initial,
      remainingBudgets: initial.subtracting(usage),
      boundJobIDs: boundJobs,
      reservations: reservations,
      events: events
    )
  }

  static func reservationBindings(
    id: String,
    request: RolloutEffectReservationRequest,
    nowMilliseconds: Int64
  ) -> [SQLiteValue] {
    let cost = request.cost
    return [
      .text(id),
      .text(request.authorizationID),
      .text(request.jobID.uuidString.lowercased()),
      .text(request.kind.rawValue),
      .text(request.operationSHA256),
      .text(request.targetSHA256),
      .integer(Int64(request.ordinal)),
      .integer(Int64(request.attempt)),
      .integer(Int64(cost.githubReadRequests)),
      .integer(Int64(cost.githubReadPages)),
      .integer(cost.githubReadBytes),
      .integer(Int64(cost.gitRemoteReads)),
      .integer(Int64(cost.providerSessions)),
      .integer(Int64(cost.approvedCommands)),
      .integer(Int64(cost.markerParts)),
      .integer(Int64(cost.labelWrites)),
      .integer(Int64(cost.branchCreates)),
      .integer(Int64(cost.pullRequestCreates)),
      .integer(Int64(cost.githubSends)),
      .integer(Int64(cost.gitSends)),
      request.mutationIntentID.map(SQLiteValue.text) ?? .null,
      .integer(nowMilliseconds),
      .integer(nowMilliseconds),
    ]
  }

  static func requireReservation(
    id: String,
    database: isolated SQLiteStore
  ) throws -> RolloutEffectReservation {
    guard
      let row = try database.query(
        "SELECT * FROM rollout_effect_reservations WHERE id = ?",
        bindings: [.text(id)]
      ).first
    else {
      throw RolloutAuthorityError.decode("effect reservation not found")
    }
    return try decodeReservation(row)
  }

  static func authorizationState(
    id: String,
    database: isolated SQLiteStore
  ) throws -> RolloutAuthorizationState {
    guard
      let raw = try database.scalarText(
        "SELECT state FROM rollout_authorizations WHERE id = ?",
        bindings: [.text(id)]
      ), let state = RolloutAuthorizationState(rawValue: raw)
    else {
      throw RolloutAuthorityError.authorizationNotFound(id)
    }
    return state
  }
}

extension RolloutAuthorityStore {
  private static func decodeAuthorization(_ row: SQLiteRow) throws -> RolloutAuthorization {
    let id = try text(row, "id")
    let repositoryIDText = try text(row, "repository_id")
    guard RolloutPreviewBuilder.validLowercaseUUID(id),
      let state = RolloutAuthorizationState(rawValue: try text(row, "state")),
      let mode = RolloutScopeMode(rawValue: try text(row, "scope_mode")),
      let stage = RolloutWorkflowStage(rawValue: try text(row, "workflow_stage")),
      let repositoryID = UUID(uuidString: repositoryIDText),
      repositoryID.uuidString.lowercased() == repositoryIDText
    else {
      throw RolloutAuthorityError.decode("rollout authorization")
    }
    return RolloutAuthorization(
      id: id,
      previewSHA256: try text(row, "preview_sha256"),
      state: state,
      scopeMode: mode,
      workflowStage: stage,
      repositoryID: repositoryID,
      activatedAtMilliseconds: try integer(row, "activated_at_ms"),
      expiresAtMilliseconds: try integer(row, "expires_at_ms"),
      updatedAtMilliseconds: try integer(row, "updated_at_ms"),
      terminalReason: try optionalText(row, "terminal_reason")
    )
  }

  private static func decodeBudgets(_ row: SQLiteRow) throws -> RolloutBudgets {
    RolloutBudgets(
      jobs: Int(try integer(row, "jobs")),
      githubReadRequests: Int(try integer(row, "github_read_requests")),
      githubReadPages: Int(try integer(row, "github_read_pages")),
      githubReadBytes: try integer(row, "github_read_bytes"),
      gitRemoteReads: Int(try integer(row, "git_remote_reads")),
      providerSessions: Int(try integer(row, "provider_sessions")),
      approvedCommands: Int(try integer(row, "approved_commands")),
      markerParts: Int(try integer(row, "marker_parts")),
      labelWrites: Int(try integer(row, "label_writes")),
      branchCreates: Int(try integer(row, "branch_creates")),
      pullRequestCreates: Int(try integer(row, "pull_request_creates")),
      githubSends: Int(try integer(row, "github_sends")),
      gitSends: Int(try integer(row, "git_sends"))
    )
  }

  static func decodeReservation(_ row: SQLiteRow) throws -> RolloutEffectReservation {
    let id = try text(row, "id")
    let jobIDText = try text(row, "job_id")
    guard RolloutPreviewBuilder.validLowercaseUUID(id),
      let jobID = UUID(uuidString: jobIDText),
      jobID.uuidString.lowercased() == jobIDText,
      let kind = RolloutEffectKind(rawValue: try text(row, "kind")),
      let state = RolloutEffectReservationState(rawValue: try text(row, "state"))
    else {
      throw RolloutAuthorityError.decode("rollout effect reservation")
    }
    let cost = RolloutEffectCost(
      githubReadRequests: Int(try integer(row, "github_read_requests")),
      githubReadPages: Int(try integer(row, "github_read_pages")),
      githubReadBytes: try integer(row, "github_read_bytes"),
      gitRemoteReads: Int(try integer(row, "git_remote_reads")),
      providerSessions: Int(try integer(row, "provider_sessions")),
      approvedCommands: Int(try integer(row, "approved_commands")),
      markerParts: Int(try integer(row, "marker_parts")),
      labelWrites: Int(try integer(row, "label_writes")),
      branchCreates: Int(try integer(row, "branch_creates")),
      pullRequestCreates: Int(try integer(row, "pull_request_creates")),
      githubSends: Int(try integer(row, "github_sends")),
      gitSends: Int(try integer(row, "git_sends"))
    )
    try cost.validate(for: kind)
    return RolloutEffectReservation(
      id: id,
      request: RolloutEffectReservationRequest(
        authorizationID: try text(row, "authorization_id"),
        jobID: jobID,
        kind: kind,
        operationSHA256: try text(row, "operation_sha256"),
        targetSHA256: try text(row, "target_sha256"),
        ordinal: Int(try integer(row, "ordinal")),
        attempt: Int(try integer(row, "attempt")),
        cost: cost,
        mutationIntentID: try optionalText(row, "mutation_intent_id")
      ),
      state: state,
      createdAtMilliseconds: try integer(row, "created_at_ms"),
      updatedAtMilliseconds: try integer(row, "updated_at_ms")
    )
  }

  private static func decodeEvent(_ row: SQLiteRow) throws -> RolloutAuthorizationEvent {
    guard let kind = RolloutAuthorizationEventKind(rawValue: try text(row, "kind")),
      let to = RolloutAuthorizationState(rawValue: try text(row, "to_state"))
    else {
      throw RolloutAuthorityError.decode("rollout authorization event")
    }
    let from: RolloutAuthorizationState?
    if let raw = try optionalText(row, "from_state") {
      guard let value = RolloutAuthorizationState(rawValue: raw) else {
        throw RolloutAuthorityError.decode("rollout event source state")
      }
      from = value
    } else {
      from = nil
    }
    return RolloutAuthorizationEvent(
      id: try integer(row, "id"),
      authorizationID: try text(row, "authorization_id"),
      eventKey: try text(row, "event_key"),
      kind: kind,
      fromState: from,
      toState: to,
      reasonCode: try text(row, "reason_code"),
      checkpointSHA256: try optionalText(row, "checkpoint_sha256"),
      createdAtMilliseconds: try integer(row, "created_at_ms")
    )
  }

  static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw RolloutAuthorityError.decode("expected text column \(column)")
    }
    return value
  }

  static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): return value
    case .null: return nil
    default: throw RolloutAuthorityError.decode("expected optional text column \(column)")
    }
  }

  static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw RolloutAuthorityError.decode("expected integer column \(column)")
    }
    return value
  }

  static func optionalInteger(_ row: SQLiteRow, _ column: String) throws -> Int64? {
    switch row[column] {
    case .integer(let value): return value
    case .null: return nil
    default: throw RolloutAuthorityError.decode("expected optional integer column \(column)")
    }
  }

  static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
  }
}

extension RolloutAuthorityStore {
  static func authorizeJobCreation(
    binding: RolloutJobCreationBinding,
    identity: LogicalJobIdentity,
    objectNumber: Int?,
    firstStep: JobStepKind,
    now: Date,
    database: isolated SQLiteStore
  ) throws -> Int {
    guard RolloutPreviewBuilder.validLowercaseUUID(binding.authorizationID),
      GitHubInputValidation.validSHA256(binding.canonicalInputSHA256),
      binding.workflowStage.accepts(jobKind: identity.kind),
      let objectNumber, objectNumber > 0
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    let nowMilliseconds = milliseconds(now)
    guard
      let scopeRow = try database.query(
        "SELECT preview_json FROM rollout_authorization_scopes WHERE authorization_id = ?",
        bindings: [.text(binding.authorizationID)]
      ).first,
      let previewData = try text(scopeRow, "preview_json").data(using: .utf8)
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    let preview = try RolloutPreviewBuilder.parseCanonical(previewData)
    guard preview.payload.scope.mode == .finiteWindow,
      preview.payload.scope.stage == binding.workflowStage,
      preview.payload.scope.repository.id == identity.repositoryID.uuidString.lowercased(),
      let window = preview.payload.scope.finiteWindow
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    let currentCandidate = window.candidates.first {
      $0.nodeID == identity.objectNodeID && $0.number == objectNumber
        && $0.revisionKey == identity.revisionKey
    }
    if let currentCandidate {
      guard currentCandidate.canonicalInputSHA256 == binding.canonicalInputSHA256 else {
        throw DurableJobStoreError.rolloutAuthorityRequired
      }
    } else {
      guard window.allowsFutureObjects,
        objectNumber > window.observedObjectNumberUpperBound,
        objectNumber <= window.maximumFutureObjectNumber,
        try RolloutPreviewBuilder.futureCandidateSHA256(
          scope: preview.payload.scope,
          nodeID: identity.objectNodeID,
          number: objectNumber,
          revisionKey: identity.revisionKey
        ) == binding.canonicalInputSHA256
      else {
        throw DurableJobStoreError.rolloutAuthorityRequired
      }
      let nextOrdinal = Int(
        try database.scalarInt(
          "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM rollout_window_candidates WHERE authorization_id = ?",
          bindings: [.text(binding.authorizationID)]
        ) ?? 0
      )
      _ = try database.execute(
        """
        INSERT INTO rollout_window_candidates(
          authorization_id, ordinal, object_node_id, object_number,
          revision_key, canonical_input_sha256
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(binding.authorizationID), .integer(Int64(nextOrdinal)),
          .text(identity.objectNodeID), .integer(Int64(objectNumber)),
          .text(identity.revisionKey), .text(binding.canonicalInputSHA256),
        ]
      )
    }
    guard
      try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM rollout_authorizations AS authorization
        JOIN rollout_authorization_scopes AS scope
          ON scope.authorization_id = authorization.id
        JOIN rollout_authorization_budgets AS budget
          ON budget.authorization_id = authorization.id
        JOIN rollout_window_candidates AS candidate
          ON candidate.authorization_id = authorization.id
        JOIN repositories AS repository ON repository.id = authorization.repository_id
        JOIN app_settings AS settings ON settings.singleton = 1
        WHERE authorization.id = ? AND authorization.state = 'active'
          AND authorization.scope_mode = 'finiteWindow'
          AND authorization.workflow_stage = ?
          AND authorization.repository_id = ?
          AND authorization.expires_at_ms > ?
          AND candidate.object_node_id = ? AND candidate.object_number = ?
          AND candidate.revision_key = ? AND candidate.canonical_input_sha256 = ?
          AND repository.enabled = 1
          AND repository.node_id = scope.repository_node_id
          AND repository.owner = scope.repository_owner
          AND repository.name = scope.repository_name
          AND repository.default_branch = scope.default_branch
          AND repository.review_enabled = scope.review_enabled
          AND repository.triage_enabled = scope.triage_enabled
          AND repository.implementation_enabled = scope.implementation_enabled
          AND settings.paused = 0
          AND settings.active_rollout_authorization_id = authorization.id
          AND (SELECT COUNT(*) FROM rollout_job_bindings AS existing
               WHERE existing.authorization_id = authorization.id) < budget.jobs
        """,
        bindings: [
          .text(binding.authorizationID),
          .text(binding.workflowStage.rawValue),
          .text(identity.repositoryID.uuidString.lowercased()),
          .integer(nowMilliseconds),
          .text(identity.objectNodeID),
          .integer(Int64(objectNumber)),
          .text(identity.revisionKey),
          .text(binding.canonicalInputSHA256),
        ]
      ) == 1
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    guard step(firstStep, belongsTo: binding.workflowStage) else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    return Int(
      try database.scalarInt(
        "SELECT COUNT(*) + 1 FROM rollout_job_bindings WHERE authorization_id = ?",
        bindings: [.text(binding.authorizationID)]
      ) ?? 0
    )
  }

  static func bindCreatedJob(
    job: JobRecord,
    binding: RolloutJobCreationBinding,
    jobSlot: Int,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    guard
      let row = try database.query(
        "SELECT preview_json FROM rollout_authorization_scopes WHERE authorization_id = ?",
        bindings: [.text(binding.authorizationID)]
      ).first,
      let data = try text(row, "preview_json").data(using: .utf8)
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    let preview = try RolloutPreviewBuilder.parseCanonical(data)
    let jobBinding = RolloutJobBinding(
      jobID: job.id,
      jobKind: job.identity.kind,
      objectNumber: job.objectNumber ?? 0,
      contractVersion: job.contractVersionUsed,
      priority: job.priority,
      firstStep: job.currentStepKind ?? .review,
      currentStep: job.currentStepKind?.rawValue ?? ""
    )
    try insertJobBinding(
      authorizationID: binding.authorizationID,
      binding: jobBinding,
      scope: preview.payload.scope,
      objectNodeID: job.identity.objectNodeID,
      revisionKey: job.identity.revisionKey,
      canonicalInputSHA256: binding.canonicalInputSHA256,
      jobSlot: jobSlot,
      nowMilliseconds: milliseconds(now),
      database: database
    )
    try insertEvent(
      authorizationID: binding.authorizationID,
      eventKey: "bind:\(binding.authorizationID):\(job.id.uuidString.lowercased())",
      kind: .jobBound,
      from: .active,
      to: .active,
      reasonCode: "FINITE_WINDOW_BOUND",
      checkpointSHA256: binding.canonicalInputSHA256,
      nowMilliseconds: milliseconds(now),
      database: database
    )
  }

  static func requireActiveJobBinding(
    jobID: UUID,
    now: Date,
    recovery _: Bool,
    database: isolated SQLiteStore
  ) throws {
    guard
      try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM rollout_job_bindings AS binding
        JOIN rollout_authorizations AS authorization
          ON authorization.id = binding.authorization_id
        JOIN jobs AS job ON job.id = binding.job_id
        JOIN repositories AS repository ON repository.id = job.repository_id
        JOIN app_settings AS settings ON settings.singleton = 1
        WHERE binding.job_id = ?
          AND authorization.state = 'active'
          AND authorization.expires_at_ms > ?
          AND authorization.repository_id = job.repository_id
          AND authorization.workflow_stage = binding.workflow_stage
          AND job.rollout_generation = 1
          AND job.state NOT IN ('succeeded', 'blocked')
          AND NOT (
            binding.workflow_stage = 'implementationPlan'
            AND job.current_step_kind = 'orchestrate'
          )
          AND NOT (
            binding.workflow_stage = 'implementationExecute'
            AND job.current_step_kind = 'replan'
          )
          AND repository.enabled = 1
          AND (
            (binding.workflow_stage IN ('prReview', 'generatedPRReview') AND
              job.kind = 'prReview' AND repository.review_enabled = 1) OR
            (binding.workflow_stage = 'issueTriage' AND
              job.kind = 'issueTriage' AND repository.triage_enabled = 1) OR
            (binding.workflow_stage IN ('implementationPlan', 'implementationExecute') AND
              job.kind IN ('issueImplementation', 'complexPlan') AND
              repository.implementation_enabled = 1)
          )
          AND settings.paused = 0
          AND settings.active_rollout_authorization_id = authorization.id
        """,
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .integer(milliseconds(now)),
        ]
      ) == 1
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
  }

  static func requireActivePhaseCheckpoint(
    jobID: UUID,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    guard
      try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM rollout_job_bindings AS binding
        JOIN rollout_authorizations AS authorization
          ON authorization.id = binding.authorization_id
        JOIN jobs AS job ON job.id = binding.job_id
        JOIN app_settings AS settings ON settings.singleton = 1
        WHERE binding.job_id = ?
          AND authorization.state = 'active'
          AND authorization.expires_at_ms > ?
          AND authorization.repository_id = job.repository_id
          AND job.kind IN ('issueImplementation', 'complexPlan')
          AND (
            binding.workflow_stage = 'implementationPlan' OR
            (
              binding.workflow_stage = 'implementationExecute'
              AND job.state = 'reconciling'
              AND job.current_step_kind = 'consumeStaleApproval'
              AND EXISTS (
                SELECT 1 FROM job_steps AS step
                WHERE step.job_id = job.id
                  AND step.ordinal = job.current_step
                  AND step.kind = 'consumeStaleApproval'
              )
            )
          )
          AND settings.paused = 0
          AND settings.active_rollout_authorization_id = authorization.id
        """,
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .integer(milliseconds(now)),
        ]
      ) == 1
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
  }

  static func requireActiveGeneratedReviewParent(
    jobID: UUID,
    now: Date,
    database: isolated SQLiteStore
  ) throws -> String {
    let rows = try database.query(
      """
      SELECT authorization.id
      FROM rollout_job_bindings AS binding
      JOIN rollout_authorizations AS authorization
        ON authorization.id = binding.authorization_id
      JOIN jobs AS job ON job.id = binding.job_id
      JOIN app_settings AS settings ON settings.singleton = 1
      WHERE binding.job_id = ?
        AND binding.workflow_stage = 'implementationExecute'
        AND authorization.state = 'active'
        AND authorization.expires_at_ms > ?
        AND authorization.repository_id = job.repository_id
        AND job.kind IN ('issueImplementation', 'complexPlan')
        AND job.state = 'reconciling'
        AND job.current_step_kind = 'qa'
        AND settings.paused = 0
        AND settings.active_rollout_authorization_id = authorization.id
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .integer(milliseconds(now)),
      ]
    )
    guard rows.count == 1,
      let authorizationID = try rows.first.map({
        try text($0, "id")
      })
    else {
      throw DurableJobStoreError.rolloutAuthorityRequired
    }
    return authorizationID
  }

  private static func step(
    _ step: JobStepKind,
    belongsTo stage: RolloutWorkflowStage
  ) -> Bool {
    switch stage {
    case .prReview, .generatedPRReview:
      return step == .review
    case .issueTriage:
      return step == .triage
    case .implementationPlan:
      return step == .claimReady || step == .plan || step == .replan
    case .implementationExecute:
      return step == .claimApprovedPlan || step == .orchestrate
    }
  }
}
