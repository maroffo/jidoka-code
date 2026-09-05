import Foundation

extension RolloutAuthorityStore: RolloutEffectAuthorizing {
  public func reserveGitHubRead(
    _ effect: RolloutGitHubReadEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard !effect.operation.kind.isWrite,
      effect.maximumResponseBytes > 0,
      effect.maximumResponseBytes <= Int64(GitHubBroker.maximumResponseBytes),
      RolloutEffectTaskContext.current == effect.context
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    switch effect.context.mode {
    case .discovery:
      return try await reserveScopeRead(effect, now: now)
    case .workflow(let jobID):
      return try await reserveJobEffect(
        jobID: jobID,
        kind: .githubRead,
        operationSHA256: try Self.githubOperationSHA256(effect.operation),
        targetSHA256: try Self.githubTargetSHA256(effect.operation),
        cost: RolloutEffectCost(
          githubReadRequests: 1,
          githubReadPages: 1,
          githubReadBytes: effect.maximumResponseBytes
        ),
        reattachRecoveredReservation: true,
        now: now,
        validate: { binding, _ in
          try Self.validateWorkflowRead(operation: effect.operation, binding: binding)
        }
      )
    case .readback(let jobID, let intentID):
      return try await reserveReadback(
        effect,
        jobID: jobID,
        intentID: intentID,
        now: now
      )
    case .historicalCanary(let jobID):
      try await requireHistoricalCanary(jobID: jobID)
    }
  }

  public func verifyGitHubReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitHubReadEffect
  ) async throws {
    guard !effect.operation.kind.isWrite,
      effect.maximumResponseBytes > 0,
      effect.maximumResponseBytes <= Int64(GitHubBroker.maximumResponseBytes),
      RolloutEffectTaskContext.current == effect.context
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    if case .historicalCanary(let jobID) = permit {
      guard case .historicalCanary(let contextualJobID) = effect.context.mode,
        contextualJobID == jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try await requireHistoricalCanary(jobID: jobID)
    }
    let permitID: String
    switch permit {
    case .reservation(let id), .scopeRead(let id), .readback(let id):
      permitID = id
    case .gitReadback, .boundedRead, .historicalCanary:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let isReadback: Bool
    if case .readback = permit { isReadback = true } else { isReadback = false }
    guard isReadback || effectAdmissionOpen,
      inFlightEffectPermits.contains(permitID)
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let operationSHA256 = try Self.githubOperationSHA256(effect.operation)
    let targetSHA256 = try Self.githubTargetSHA256(effect.operation)
    let nowMilliseconds = Self.milliseconds(currentTime())
    try await database.transaction { database in
      switch permit {
      case .reservation(let id):
        guard case .workflow(let jobID) = effect.context.mode else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        let reservation = try Self.requireReservation(id: id, database: database)
        let binding = try Self.loadActiveBinding(
          jobID: jobID,
          nowMilliseconds: nowMilliseconds,
          database: database
        )
        guard reservation.state == .reserved,
          reservation.request.authorizationID == binding.authorizationID,
          reservation.request.jobID == jobID,
          reservation.request.kind == .githubRead,
          reservation.request.operationSHA256 == operationSHA256,
          reservation.request.targetSHA256 == targetSHA256,
          reservation.request.cost
            == RolloutEffectCost(
              githubReadRequests: 1,
              githubReadPages: 1,
              githubReadBytes: effect.maximumResponseBytes
            )
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        try Self.validateWorkflowRead(operation: effect.operation, binding: binding)
      case .scopeRead(let id):
        guard case .discovery = effect.context.mode,
          let row = try database.query(
            """
            SELECT read.*, authorization.workflow_stage, scope.preview_json
            FROM rollout_scope_read_reservations AS read
            JOIN rollout_authorizations AS authorization
              ON authorization.id = read.authorization_id
            JOIN rollout_authorization_scopes AS scope
              ON scope.authorization_id = read.authorization_id
            JOIN app_settings AS settings ON settings.singleton = 1
            WHERE read.id = ? AND read.state = 'reserved'
              AND authorization.state = 'active'
              AND authorization.scope_mode = 'finiteWindow'
              AND authorization.expires_at_ms > ?
              AND settings.paused = 0
              AND settings.active_rollout_authorization_id = authorization.id
            """,
            bindings: [.text(id), .integer(nowMilliseconds)]
          ).first,
          let stage = RolloutWorkflowStage(
            rawValue: try Self.text(row, "workflow_stage")
          ),
          let data = try Self.text(row, "preview_json").data(using: .utf8),
          try Self.text(row, "operation_sha256") == operationSHA256,
          try Self.text(row, "target_sha256") == targetSHA256,
          try Self.integer(row, "github_read_requests") == 1,
          try Self.integer(row, "github_read_pages") == 1,
          try Self.integer(row, "github_read_bytes") == effect.maximumResponseBytes
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        let preview = try RolloutPreviewBuilder.parseCanonical(data)
        try Self.validateDiscovery(
          operation: effect.operation,
          stage: stage,
          scope: preview.payload.scope
        )
      case .readback(let id):
        guard case .readback(let jobID, let intentID) = effect.context.mode,
          let row = try database.query(
            """
            SELECT read.*, source.mutation_intent_id,
              source.state AS source_state, scope.preview_json
            FROM rollout_readback_reservations AS read
            JOIN rollout_effect_reservations AS source
              ON source.id = read.source_reservation_id
            JOIN rollout_authorization_scopes AS scope
              ON scope.authorization_id = read.authorization_id
            WHERE read.id = ? AND read.job_id = ? AND read.state = 'reserved'
            """,
            bindings: [.text(id), .text(jobID.uuidString.lowercased())]
          ).first,
          try Self.text(row, "mutation_intent_id")
            == intentID.uuidString.lowercased(),
          [
            RolloutEffectReservationState.sendStarted.rawValue,
            RolloutEffectReservationState.observationRequired.rawValue,
          ].contains(try Self.text(row, "source_state")),
          try Self.text(row, "operation_sha256") == operationSHA256,
          try Self.text(row, "target_sha256") == targetSHA256,
          try Self.integer(row, "github_read_requests") == 1,
          try Self.integer(row, "github_read_pages") == 1,
          try Self.integer(row, "github_read_bytes") == effect.maximumResponseBytes,
          let data = try Self.text(row, "preview_json").data(using: .utf8)
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        try Self.validate(
          operation: effect.operation,
          scope: try RolloutPreviewBuilder.parseCanonical(data).payload.scope
        )
      case .gitReadback, .boundedRead, .historicalCanary:
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    }
    guard inFlightEffectPermits.remove(permitID) != nil else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    verifiedReadPermits.insert(permitID)
  }

  public func settleGitHubRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    guard GitHubInputValidation.validSHA256(evidenceSHA256) else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    switch permit {
    case .reservation(let id):
      _ = try await settleReservation(
        id: id,
        attributed: false,
        evidenceSHA256: evidenceSHA256,
        now: now
      )
      inFlightEffectPermits.remove(id)
      verifiedReadPermits.remove(id)
    case .scopeRead(let id):
      try await settleReadTable(
        table: "rollout_scope_read_reservations",
        id: id,
        evidenceSHA256: evidenceSHA256,
        now: now
      )
      inFlightEffectPermits.remove(id)
      verifiedReadPermits.remove(id)
    case .readback(let id):
      try await settleReadTable(
        table: "rollout_readback_reservations",
        id: id,
        evidenceSHA256: evidenceSHA256,
        now: now
      )
      inFlightEffectPermits.remove(id)
      verifiedReadPermits.remove(id)
    case .historicalCanary(let jobID):
      try await requireHistoricalCanary(jobID: jobID)
    case .gitReadback, .boundedRead:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func reserveGitRemoteRead(
    _ effect: RolloutGitRemoteReadEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard effect.repositoryNodeID.utf8.count <= 256,
      !effect.repositoryNodeID.isEmpty,
      !effect.target.isEmpty,
      effect.target.utf8.count <= 2_048
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    if case .readback(let jobID, let intentID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    {
      return try await reserveGitReadback(
        effect,
        intentID: intentID,
        now: now
      )
    } else if case .historicalCanary(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    {
      try await requireHistoricalCanary(jobID: jobID)
    }
    guard case .workflow(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    return try await reserveJobEffect(
      jobID: effect.jobID,
      kind: .gitRemoteRead,
      operationSHA256: Self.digest([
        "git-remote-read-v1", effect.operation.rawValue,
        effect.repositoryID.uuidString.lowercased(), effect.repositoryNodeID, effect.target,
      ]),
      targetSHA256: Self.digest([effect.repositoryNodeID, effect.target]),
      cost: RolloutEffectCost(gitRemoteReads: 1),
      reattachRecoveredReservation: true,
      now: now,
      validate: { binding, _ in
        try Self.validateGitRemoteRead(effect, binding: binding)
      }
    )
  }

  public func verifyGitRemoteReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitRemoteReadEffect
  ) async throws {
    guard effect.repositoryNodeID.utf8.count <= 256,
      !effect.repositoryNodeID.isEmpty,
      !effect.target.isEmpty,
      effect.target.utf8.count <= 2_048
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID, jobID == effect.jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try await requireHistoricalCanary(jobID: jobID)
    }
    let permitID: String
    switch permit {
    case .reservation(let id), .gitReadback(let id):
      permitID = id
    case .scopeRead, .readback, .boundedRead, .historicalCanary:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let isReadback: Bool
    if case .gitReadback = permit { isReadback = true } else { isReadback = false }
    guard isReadback || effectAdmissionOpen,
      inFlightEffectPermits.contains(permitID)
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    let operationSHA256 = Self.digest([
      "git-remote-read-v1", effect.operation.rawValue,
      effect.repositoryID.uuidString.lowercased(), effect.repositoryNodeID, effect.target,
    ])
    let targetSHA256 = Self.digest([effect.repositoryNodeID, effect.target])
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    try await database.transaction { database in
      switch permit {
      case .reservation(let id):
        guard case .workflow(let jobID) = RolloutEffectTaskContext.current?.mode,
          jobID == effect.jobID
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        let reservation = try Self.requireReservation(id: id, database: database)
        let binding = try Self.loadActiveBinding(
          jobID: jobID,
          nowMilliseconds: Self.milliseconds(currentTime()),
          database: database
        )
        guard reservation.state == .reserved,
          reservation.request.authorizationID == binding.authorizationID,
          reservation.request.jobID == jobID,
          reservation.request.kind == .gitRemoteRead,
          reservation.request.operationSHA256 == operationSHA256,
          reservation.request.targetSHA256 == targetSHA256,
          reservation.request.cost == RolloutEffectCost(gitRemoteReads: 1),
          binding.repositoryID == effect.repositoryID,
          binding.repositoryNodeID == effect.repositoryNodeID
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        try Self.validateGitRemoteRead(effect, binding: binding)
      case .gitReadback(let id):
        guard
          case .readback(let jobID, let intentID) =
            RolloutEffectTaskContext.current?.mode,
          jobID == effect.jobID,
          let row = try database.query(
            """
            SELECT read.*, source.mutation_intent_id,
              source.state AS source_state, authorization.repository_id,
              scope.repository_node_id
            FROM rollout_git_readback_reservations AS read
            JOIN rollout_effect_reservations AS source
              ON source.id = read.source_reservation_id
            JOIN rollout_authorizations AS authorization
              ON authorization.id = read.authorization_id
            JOIN rollout_authorization_scopes AS scope
              ON scope.authorization_id = read.authorization_id
            WHERE read.id = ? AND read.job_id = ? AND read.state = 'reserved'
            """,
            bindings: [.text(id), .text(jobID.uuidString.lowercased())]
          ).first,
          try Self.text(row, "mutation_intent_id")
            == intentID.uuidString.lowercased(),
          [
            RolloutEffectReservationState.sendStarted.rawValue,
            RolloutEffectReservationState.observationRequired.rawValue,
          ].contains(try Self.text(row, "source_state")),
          try Self.text(row, "repository_id")
            == effect.repositoryID.uuidString.lowercased(),
          try Self.text(row, "repository_node_id") == effect.repositoryNodeID,
          try Self.text(row, "operation_sha256") == operationSHA256,
          try Self.text(row, "target_sha256") == targetSHA256,
          try Self.integer(row, "git_remote_reads") == 1
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
      case .scopeRead, .readback, .boundedRead, .historicalCanary:
        throw RolloutAuthorityError.effectIdentityMismatch
      }
    }
    guard inFlightEffectPermits.remove(permitID) != nil else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    verifiedReadPermits.insert(permitID)
  }

  public func reserveProvider(
    _ effect: RolloutProviderEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard (1...3).contains(effect.round),
      effect.runNonce.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      GitHubInputValidation.validSHA256(effect.artifactSHA256),
      effect.narrativeSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      effect.planSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      GitHubInputValidation.validSHA256(effect.resourceSHA256),
      GitHubInputValidation.validSHA256(effect.profileSHA256),
      GitHubInputValidation.validSHA256(effect.sessionDirectiveSHA256)
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
    let operationSHA256 = Self.providerOperationSHA256(effect)
    let expectedOrdinal = try Self.providerOrdinal(
      workflow: effect.workflow,
      role: effect.role,
      round: effect.round
    )
    return try await reserveJobEffect(
      jobID: effect.jobID,
      kind: .providerSession,
      operationSHA256: operationSHA256,
      targetSHA256: Self.providerTargetSHA256(effect),
      cost: RolloutEffectCost(providerSessions: 1),
      requestedOrdinal: expectedOrdinal,
      reuseExactReservation: true,
      now: now,
      validate: { binding, database in
        try Self.validateProvider(effect, binding: binding, database: database)
        let preceding =
          try database.scalarInt(
            """
            SELECT COUNT(*) FROM rollout_effect_reservations
            WHERE authorization_id = ? AND job_id = ?
              AND kind = 'providerSession' AND ordinal < ?
            """,
            bindings: [
              .text(binding.authorizationID), .text(effect.jobID.uuidString.lowercased()),
              .integer(Int64(expectedOrdinal)),
            ]
          ) ?? 0
        guard preceding == Int64(expectedOrdinal) else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
      }
    )
  }

  public func verifyProviderPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect
  ) async throws {
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID, jobID == effect.jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try await requireHistoricalCanary(jobID: jobID)
    }
    guard effectAdmissionOpen,
      case .reservation(let id) = permit,
      inFlightEffectPermits.contains(id),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
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
      try Self.validateProvider(effect, binding: binding, database: database)
      guard reservation.state == .reserved else {
        throw RolloutAuthorityError.effectAdmissionClosed
      }
      guard reservation.request.authorizationID == binding.authorizationID,
        reservation.request.jobID == contextualJobID,
        reservation.request.kind == .providerSession,
        reservation.request.operationSHA256 == Self.providerOperationSHA256(effect),
        reservation.request.targetSHA256 == Self.providerTargetSHA256(effect),
        reservation.request.cost == RolloutEffectCost(providerSessions: 1),
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM rollout_local_effect_bindings
          WHERE reservation_id = ? AND kind = 'providerSession'
            AND pi_run_id IS NOT NULL AND approved_command_run_id IS NULL
          """,
          bindings: [.text(id)]
        ) == 1
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.markProcessBoundary(
        reservation: reservation,
        reasonCode: "PROVIDER_LAUNCH",
        now: now,
        database: database
      )
    }
  }

  public func bindProviderReservation(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect,
    runID: String,
    now: Date
  ) async throws {
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID, jobID == effect.jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try await requireHistoricalCanary(jobID: jobID)
    }
    guard effectAdmissionOpen,
      case .reservation(let id) = permit,
      inFlightEffectPermits.contains(id),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let nowMilliseconds = Self.milliseconds(now)
    try await database.transaction { database in
      let reservation = try Self.requireReservation(id: id, database: database)
      let binding = try Self.loadActiveBinding(
        jobID: contextualJobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.validateProvider(effect, binding: binding, database: database)
      guard reservation.state == .reserved,
        reservation.request.authorizationID == binding.authorizationID,
        reservation.request.jobID == contextualJobID,
        reservation.request.kind == .providerSession,
        reservation.request.operationSHA256 == Self.providerOperationSHA256(effect),
        reservation.request.targetSHA256 == Self.providerTargetSHA256(effect),
        reservation.request.cost == RolloutEffectCost(providerSessions: 1),
        let run = try database.query(
          """
          SELECT job_id, runtime_kind, workflow, role, round, run_nonce
          FROM pi_runs WHERE id = ?
          """,
          bindings: [.text(runID)]
        ).first,
        try Self.text(run, "job_id") == contextualJobID.uuidString.lowercased(),
        try Self.text(run, "runtime_kind") == "herdr",
        try Self.text(run, "workflow") == effect.workflow.rawValue,
        try Self.text(run, "role") == effect.role.rawValue,
        try Self.integer(run, "round") == Int64(effect.round),
        try Self.text(run, "run_nonce") == effect.runNonce
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.bindLocalEffect(
        reservationID: id,
        kind: .providerSession,
        localRunID: runID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
    }
  }

  public func reserveApprovedCommand(
    _ effect: RolloutApprovedCommandEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    guard RolloutPreviewBuilder.validIdentifier(effect.commandID, maximum: 128),
      GitHubInputValidation.validSHA256(effect.definitionSHA256),
      GitHubInputValidation.validSHA256(effect.planSHA256),
      GitHubInputValidation.validGitSHA(effect.workspaceHeadSHA),
      (1...3).contains(effect.round), effect.ordinal >= 0
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    guard case .workflow(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    return try await reserveJobEffect(
      jobID: effect.jobID,
      kind: .approvedCommand,
      operationSHA256: Self.approvedCommandOperationSHA256(effect),
      targetSHA256: Self.approvedCommandTargetSHA256(effect),
      cost: RolloutEffectCost(approvedCommands: 1),
      reattachRecoveredReservation: true,
      now: now,
      validate: { binding, database in
        try Self.validateApprovedCommand(effect, binding: binding, database: database)
      }
    )
  }

  public func verifyApprovedCommandPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutApprovedCommandEffect
  ) async throws {
    guard effectAdmissionOpen,
      case .reservation(let id) = permit,
      inFlightEffectPermits.contains(id),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
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
      try Self.validateApprovedCommand(
        effect,
        binding: binding,
        database: database
      )
      guard reservation.state == .reserved else {
        throw RolloutAuthorityError.effectAdmissionClosed
      }
      guard reservation.request.authorizationID == binding.authorizationID,
        reservation.request.jobID == contextualJobID,
        reservation.request.kind == .approvedCommand,
        reservation.request.operationSHA256 == Self.approvedCommandOperationSHA256(effect),
        reservation.request.targetSHA256 == Self.approvedCommandTargetSHA256(effect),
        reservation.request.cost == RolloutEffectCost(approvedCommands: 1),
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM rollout_local_effect_bindings
          WHERE reservation_id = ? AND kind = 'approvedCommand'
            AND pi_run_id IS NULL AND approved_command_run_id IS NOT NULL
          """,
          bindings: [.text(id)]
        ) == 1
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.markProcessBoundary(
        reservation: reservation,
        reasonCode: "APPROVED_COMMAND_LAUNCH",
        now: now,
        database: database
      )
    }
  }

  public func bindApprovedCommandReservation(
    _ permit: RolloutEffectPermit,
    effect: RolloutApprovedCommandEffect,
    runID: String,
    now: Date
  ) async throws {
    guard effectAdmissionOpen,
      case .reservation(let id) = permit,
      inFlightEffectPermits.contains(id),
      case .workflow(let contextualJobID) = RolloutEffectTaskContext.current?.mode,
      contextualJobID == effect.jobID
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    effectAdmissionsInProgress += 1
    defer { effectAdmissionsInProgress -= 1 }
    let nowMilliseconds = Self.milliseconds(now)
    try await database.transaction { database in
      let reservation = try Self.requireReservation(id: id, database: database)
      let binding = try Self.loadActiveBinding(
        jobID: contextualJobID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
      try Self.validateApprovedCommand(effect, binding: binding, database: database)
      guard reservation.state == .reserved,
        reservation.request.authorizationID == binding.authorizationID,
        reservation.request.jobID == contextualJobID,
        reservation.request.kind == .approvedCommand,
        reservation.request.operationSHA256 == Self.approvedCommandOperationSHA256(effect),
        reservation.request.targetSHA256 == Self.approvedCommandTargetSHA256(effect),
        reservation.request.cost == RolloutEffectCost(approvedCommands: 1),
        let run = try database.query(
          """
          SELECT job_id, phase, round, command_ordinal, command_id,
            plan_sha256, definition_sha256
          FROM approved_command_runs WHERE id = ?
          """,
          bindings: [.text(runID)]
        ).first,
        try Self.text(run, "job_id") == contextualJobID.uuidString.lowercased(),
        try Self.text(run, "phase") == effect.phase.rawValue,
        try Self.integer(run, "round") == Int64(effect.round),
        try Self.integer(run, "command_ordinal") == Int64(effect.ordinal),
        try Self.text(run, "command_id") == effect.commandID,
        try Self.text(run, "plan_sha256") == effect.planSHA256,
        try Self.text(run, "definition_sha256") == effect.definitionSHA256
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      try Self.bindLocalEffect(
        reservationID: id,
        kind: .approvedCommand,
        localRunID: runID,
        nowMilliseconds: nowMilliseconds,
        database: database
      )
    }
  }

  @discardableResult
  public func reconcileLocalEffectResults(now: Date) async throws -> Int {
    let rows = try await database.query(
      """
      SELECT reservation.id, binding.kind,
        CASE binding.kind
          WHEN 'providerSession' THEN provider_result.result_sha256
          WHEN 'approvedCommand' THEN command_result.evidence_sha256
        END AS evidence_sha256
      FROM rollout_effect_reservations AS reservation
      JOIN rollout_local_effect_bindings AS binding
        ON binding.reservation_id = reservation.id
      LEFT JOIN pi_runs AS provider_run ON provider_run.id = binding.pi_run_id
      LEFT JOIN pi_run_results AS provider_result
        ON provider_result.run_id = provider_run.id
      LEFT JOIN approved_command_runs AS command_run
        ON command_run.id = binding.approved_command_run_id
      LEFT JOIN approved_command_results AS command_result
        ON command_result.run_id = command_run.id
      WHERE reservation.state = 'sendStarted'
        AND reservation.kind = binding.kind
        AND (
          (binding.kind = 'providerSession'
            AND provider_run.job_id = reservation.job_id
            AND provider_run.runtime_kind = 'herdr'
            AND provider_run.accepted = 1 AND provider_run.settled = 1
            AND provider_run.structured_result_digest = provider_result.result_sha256)
          OR
          (binding.kind = 'approvedCommand'
            AND command_run.job_id = reservation.job_id
            AND command_run.state = 'resultAccepted'
            AND command_result.evidence_sha256 IS NOT NULL)
        )
      ORDER BY reservation.id
      """
    )
    var reconciled = 0
    for row in rows {
      let id = try Self.text(row, "id")
      let kind = try Self.text(row, "kind")
      let evidenceSHA256 = try Self.text(row, "evidence_sha256")
      guard [.providerSession, .approvedCommand].contains(RolloutEffectKind(rawValue: kind)),
        GitHubInputValidation.validSHA256(evidenceSHA256)
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      _ = try await settleReservation(
        id: id,
        attributed: false,
        evidenceSHA256: evidenceSHA256,
        now: now
      )
      inFlightEffectPermits.remove(id)
      verifiedReadPermits.remove(id)
      reconciled += 1
    }
    return reconciled
  }

  public func settleEffect(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    switch permit {
    case .reservation:
      try await settleGitHubRead(permit, evidenceSHA256: evidenceSHA256, now: now)
    case .historicalCanary(let jobID):
      try await requireHistoricalCanary(jobID: jobID)
    case .gitReadback(let id):
      try await settleReadTable(
        table: "rollout_git_readback_reservations",
        id: id,
        evidenceSHA256: evidenceSHA256,
        now: now
      )
      inFlightEffectPermits.remove(id)
      verifiedReadPermits.remove(id)
    case .scopeRead, .readback, .boundedRead:
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func closeAdmission() async {
    effectAdmissionOpen = false
  }

  public func openAdmission() async throws {
    guard try await activeStatus(now: currentTime()) != nil else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    effectAdmissionOpen = true
  }

  public func waitForDrain(until deadline: Date) async -> Bool {
    let remaining = max(0, deadline.timeIntervalSince(currentTime()))
    let monotonicDeadline = ContinuousClock.now.advanced(by: .seconds(remaining))
    while ContinuousClock.now < monotonicDeadline {
      let durable =
        (try? await database.scalarInt(
          """
          SELECT
            (SELECT COUNT(*)
             FROM rollout_effect_reservations AS effect
             JOIN rollout_authorizations AS authorization
               ON authorization.id = effect.authorization_id
             WHERE effect.state IN (
               'reserved', 'sendStarted', 'observationRequired', 'attributed'
             ) AND authorization.state IN ('active', 'draining', 'recoveryRequired')) +
            (SELECT COUNT(*)
             FROM rollout_scope_read_reservations AS read
             JOIN rollout_authorizations AS authorization
               ON authorization.id = read.authorization_id
             WHERE read.state = 'reserved'
               AND authorization.state IN ('active', 'draining', 'recoveryRequired')) +
            (SELECT COUNT(*)
             FROM rollout_readback_reservations AS readback
             JOIN rollout_authorizations AS authorization
               ON authorization.id = readback.authorization_id
             WHERE readback.state = 'reserved'
               AND authorization.state IN ('active', 'draining', 'recoveryRequired')) +
            (SELECT COUNT(*)
             FROM rollout_git_readback_reservations AS readback
             JOIN rollout_authorizations AS authorization
               ON authorization.id = readback.authorization_id
             WHERE readback.state = 'reserved'
               AND authorization.state IN ('active', 'draining', 'recoveryRequired'))
          """
        )) ?? 1
      if effectAdmissionsInProgress == 0, inFlightEffectPermits.isEmpty,
        verifiedReadPermits.isEmpty, durable == 0
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return false
  }

  private static func providerOperationSHA256(_ effect: RolloutProviderEffect) -> String {
    digest([
      "provider-v1", effect.workflow.rawValue, effect.role.rawValue,
      String(effect.round), effect.runNonce, effect.artifactSHA256,
      effect.narrativeSHA256 ?? "", effect.planSHA256 ?? "",
      effect.resourceSHA256, effect.profileSHA256, effect.sessionDirectiveSHA256,
    ])
  }

  private static func providerTargetSHA256(_ effect: RolloutProviderEffect) -> String {
    digest([
      effect.workflow.rawValue, effect.role.rawValue, String(effect.round), effect.runNonce,
    ])
  }

  private static func bindLocalEffect(
    reservationID: String,
    kind: RolloutEffectKind,
    localRunID: String,
    nowMilliseconds: Int64,
    database: isolated SQLiteStore
  ) throws {
    guard kind == .providerSession || kind == .approvedCommand,
      !localRunID.isEmpty
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    if let existing = try database.query(
      "SELECT * FROM rollout_local_effect_bindings WHERE reservation_id = ?",
      bindings: [.text(reservationID)]
    ).first {
      let existingRunID =
        kind == .providerSession
        ? try optionalText(existing, "pi_run_id")
        : try optionalText(existing, "approved_command_run_id")
      guard try text(existing, "kind") == kind.rawValue,
        existingRunID == localRunID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      return
    }
    let localColumn =
      kind == .providerSession ? "pi_run_id" : "approved_command_run_id"
    guard
      try database.scalarInt(
        "SELECT COUNT(*) FROM rollout_local_effect_bindings WHERE \(localColumn) = ?",
        bindings: [.text(localRunID)]
      ) == 0
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    _ = try database.execute(
      """
      INSERT INTO rollout_local_effect_bindings(
        reservation_id, kind, pi_run_id, approved_command_run_id, created_at_ms
      ) VALUES (?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(reservationID),
        .text(kind.rawValue),
        kind == .providerSession ? .text(localRunID) : .null,
        kind == .approvedCommand ? .text(localRunID) : .null,
        .integer(nowMilliseconds),
      ]
    )
  }

  private static func authorizedCommandHead(
    binding: EffectBinding,
    effect: RolloutApprovedCommandEffect,
    database: isolated SQLiteStore
  ) throws -> String {
    guard let initialHead = binding.preview.payload.commands.first?.workspaceHeadSHA else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let rows = try database.query(
      """
      SELECT run.command_id, run.definition_sha256, run.registry_kind, result.envelope
      FROM approved_command_runs AS run
      JOIN approved_command_results AS result ON result.run_id = run.id
      JOIN jobs AS job ON job.id = run.job_id
      WHERE run.job_id = ?
        AND run.job_attempt = job.attempt
        AND run.job_step = job.current_step
        AND run.plan_sha256 = ?
        AND run.command_ordinal < ?
        AND run.state = 'resultAccepted'
        AND result.succeeded = 1
      ORDER BY run.command_ordinal DESC, run.round DESC, run.created_at DESC, run.id DESC
      """,
      bindings: [
        .text(effect.jobID.uuidString.lowercased()),
        .text(effect.planSHA256),
        .integer(Int64(effect.ordinal)),
      ]
    )
    for row in rows {
      guard case .blob(let envelope)? = row["envelope"],
        case .text(let commandID)? = row["command_id"],
        case .text(let definitionSHA256)? = row["definition_sha256"],
        case .text(let registryKind)? = row["registry_kind"]
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      let evidence: VerificationCommandEvidence
      do {
        evidence = try JSONDecoder().decode(VerificationCommandEvidence.self, from: envelope)
      } catch {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      guard evidence.commandID == commandID,
        evidence.definitionDigest == definitionSHA256,
        evidence.registryKind.rawValue == registryKind
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      if let head = evidence.repositoryHeadSHA {
        guard evidence.registryKind == .gitCommit,
          GitHubInputValidation.validGitSHA(head)
        else {
          throw RolloutAuthorityError.effectIdentityMismatch
        }
        return head
      }
    }
    return initialHead
  }

  private static func validateApprovedCommand(
    _ effect: RolloutApprovedCommandEffect,
    binding: EffectBinding,
    database: isolated SQLiteStore
  ) throws {
    guard binding.stage == .implementationExecute,
      binding.jobState == .runningPi,
      binding.currentStepKind == .orchestrate,
      binding.scope.object?.planSHA256 == effect.planSHA256,
      effect.ordinal < binding.preview.payload.commands.count
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let expected = binding.preview.payload.commands[effect.ordinal]
    guard expected.ordinal == effect.ordinal,
      expected.commandID == effect.commandID,
      expected.definitionSHA256 == effect.definitionSHA256,
      expected.frozenPlanSHA256 == effect.planSHA256,
      try authorizedCommandHead(
        binding: binding,
        effect: effect,
        database: database
      ) == effect.workspaceHeadSHA
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let used =
      try database.scalarInt(
        """
        SELECT COUNT(*) FROM rollout_effect_reservations
        WHERE authorization_id = ? AND kind = 'approvedCommand'
        """,
        bindings: [.text(binding.authorizationID)]
      ) ?? 0
    let matchingReserved =
      try database.scalarInt(
        """
        SELECT COUNT(*) FROM rollout_effect_reservations
        WHERE authorization_id = ? AND job_id = ? AND kind = 'approvedCommand'
          AND operation_sha256 = ? AND target_sha256 = ? AND state = 'reserved'
        """,
        bindings: [
          .text(binding.authorizationID), .text(effect.jobID.uuidString.lowercased()),
          .text(approvedCommandOperationSHA256(effect)),
          .text(approvedCommandTargetSHA256(effect)),
        ]
      ) ?? 0
    guard matchingReserved <= 1 else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    let preceding = Int(used - matchingReserved)
    guard !binding.preview.payload.commands.isEmpty,
      preceding >= 0,
      preceding % binding.preview.payload.commands.count == effect.ordinal
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  private static func approvedCommandOperationSHA256(
    _ effect: RolloutApprovedCommandEffect
  ) -> String {
    digest([
      "approved-command-v1", effect.phase.rawValue, String(effect.round),
      String(effect.ordinal), effect.commandID, effect.definitionSHA256,
      effect.planSHA256, effect.workspaceHeadSHA,
    ])
  }

  private static func approvedCommandTargetSHA256(
    _ effect: RolloutApprovedCommandEffect
  ) -> String {
    digest([
      effect.commandID, effect.definitionSHA256, effect.workspaceHeadSHA,
    ])
  }

  private static func markProcessBoundary(
    reservation: RolloutEffectReservation,
    reasonCode: String,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    let changed = try database.execute(
      "UPDATE rollout_effect_reservations SET state = 'sendStarted', updated_at_ms = MAX(updated_at_ms, ?) WHERE id = ? AND state = 'reserved'",
      bindings: [
        .integer(milliseconds(now)), .text(reservation.id),
      ]
    )
    guard changed == 1 else { throw RolloutAuthorityError.invalidStateTransition }
    try insertEvent(
      authorizationID: reservation.request.authorizationID,
      eventKey: "execute:\(reservation.id)",
      kind: .sendStarted,
      from: .active,
      to: .active,
      reasonCode: reasonCode,
      checkpointSHA256: reservation.request.operationSHA256,
      nowMilliseconds: milliseconds(now),
      database: database
    )
  }
}
