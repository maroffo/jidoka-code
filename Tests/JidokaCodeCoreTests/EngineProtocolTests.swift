import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Versioned application engine protocol")
struct EngineProtocolTests {
  @Test("production helper allowlist covers every non-ServiceManagement command")
  func productionHelperAllowlist() {
    let applicationControlOnly: Set<EngineCommandKind> = [
      .setLoginEnabled,
      .prepareForHandoff,
    ]
    #expect(
      EngineCommandKind.productionHelperAllowedCommands
        == Set(EngineCommandKind.allCases).subtracting(applicationControlOnly)
    )
  }

  @Test("request and response bind version, identity, and operation")
  func exactEnvelope() throws {
    let request = EngineXPCRequest(
      requestID: "11111111-1111-1111-1111-111111111111",
      command: .setPaused(true)
    )
    #expect(request.protocolVersion == EngineProtocolVersion.current)
    try request.validate()
    let state = engineProtocolState()
    let result = EngineCommandResponse(command: .setPaused, state: state)
    let response = EngineXPCResponse(requestID: request.requestID, result: result)
    #expect(try response.validate(for: request) == result)

    let wrongID = EngineXPCResponse(
      requestID: "22222222-2222-2222-2222-222222222222",
      result: result
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try wrongID.validate(for: request)
    }
    let wrongCommand = EngineXPCResponse(
      requestID: request.requestID,
      result: EngineCommandResponse(command: .pollNow, state: state)
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try wrongCommand.validate(for: request)
    }
    let invalidCatalogState = engineProtocolState()
    let catalogData = try JSONEncoder().encode(invalidCatalogState)
    var catalogObject = try #require(
      JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
    )
    var settings = try #require(catalogObject["settings"] as? [String: Any])
    var catalog = try #require(settings["modelCatalog"] as? [String: Any])
    var models = try #require(catalog["models"] as? [[String: Any]])
    models[0]["reasoning"] = false
    catalog["models"] = models
    settings["modelCatalog"] = catalog
    catalogObject["settings"] = settings
    let malformedCatalogState = try JSONDecoder().decode(
      EngineUIState.self,
      from: JSONSerialization.data(withJSONObject: catalogObject)
    )
    let invalidCatalog = EngineXPCResponse(
      requestID: request.requestID,
      result: EngineCommandResponse(command: .setPaused, state: malformedCatalogState)
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try invalidCatalog.validate(for: request)
    }

    let incompleteReadiness = EngineXPCResponse(
      requestID: request.requestID,
      result: EngineCommandResponse(
        command: .setPaused,
        state: engineProtocolState(herdr: EngineHerdrStatus(state: .ready))
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try incompleteReadiness.validate(for: request)
    }
  }

  @Test("maintenance responses remain bound to exact scope count and evidence")
  func maintenanceResponseBoundary() throws {
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let state = engineProtocolState(paused: true)
    let previewRequest = EngineXPCRequest(
      requestID: "11111111-1111-1111-1111-111111111111",
      command: .previewJobMaintenance(scope)
    )
    let previewReport = JobMaintenanceReport(
      scope: scope,
      candidateCount: 87,
      evidenceSHA256: String(repeating: "a", count: 64),
      appliedCount: 0,
      replayed: false
    )
    let previewResponse = EngineXPCResponse(
      requestID: previewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobMaintenance,
        state: state,
        jobMaintenance: previewReport
      )
    )
    #expect(try previewResponse.validate(for: previewRequest).jobMaintenance == previewReport)

    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: 87,
      evidenceSHA256: previewReport.evidenceSHA256
    )
    let unpausedPreview = EngineXPCResponse(
      requestID: previewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobMaintenance,
        state: engineProtocolState(),
        jobMaintenance: previewReport
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try unpausedPreview.validate(for: previewRequest)
    }

    let applyRequest = EngineXPCRequest(
      requestID: "22222222-2222-2222-2222-222222222222",
      command: .applyJobMaintenance(authorization)
    )
    let checkpoint = EngineCheckpointReceipt(
      checkpointID: try #require(
        UUID(uuidString: "33333333-3333-3333-3333-333333333333")
      ),
      completedAt: Date(timeIntervalSince1970: 2_000),
      nonterminalJobCount: 156,
      ambiguousMutationCount: 0,
      databaseCheckpointed: true
    )
    let appliedReport = JobMaintenanceReport(
      scope: scope,
      candidateCount: 87,
      evidenceSHA256: previewReport.evidenceSHA256,
      appliedCount: 87,
      replayed: false
    )
    let validApply = EngineXPCResponse(
      requestID: applyRequest.requestID,
      result: EngineCommandResponse(
        command: .applyJobMaintenance,
        state: state,
        checkpoint: checkpoint,
        jobMaintenance: appliedReport
      )
    )
    #expect(try validApply.validate(for: applyRequest).jobMaintenance == appliedReport)

    let malformedReports = [
      JobMaintenanceReport(
        scope: scope,
        candidateCount: 86,
        evidenceSHA256: previewReport.evidenceSHA256,
        appliedCount: 86,
        replayed: false
      ),
      JobMaintenanceReport(
        scope: scope,
        candidateCount: 87,
        evidenceSHA256: String(repeating: "b", count: 64),
        appliedCount: 87,
        replayed: false
      ),
    ]
    for malformed in malformedReports {
      let response = EngineXPCResponse(
        requestID: applyRequest.requestID,
        result: EngineCommandResponse(
          command: .applyJobMaintenance,
          state: state,
          checkpoint: checkpoint,
          jobMaintenance: malformed
        )
      )
      #expect(throws: EngineClientError(.invalidResponse)) {
        try response.validate(for: applyRequest)
      }
    }
    let missingCheckpoint = EngineXPCResponse(
      requestID: applyRequest.requestID,
      result: EngineCommandResponse(
        command: .applyJobMaintenance,
        state: state,
        jobMaintenance: appliedReport
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try missingCheckpoint.validate(for: applyRequest)
    }
    let unrelatedRequest = EngineXPCRequest(
      requestID: "44444444-4444-4444-4444-444444444444",
      command: .snapshot
    )
    let unrelatedMaintenance = EngineXPCResponse(
      requestID: unrelatedRequest.requestID,
      result: EngineCommandResponse(
        command: .snapshot,
        state: state,
        jobMaintenance: previewReport
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try unrelatedMaintenance.validate(for: unrelatedRequest)
    }
  }

  @Test("canary responses require paused exact evidence and checkpoint authority")
  func canaryResponseBoundary() throws {
    let scope = JobCanaryScope(
      jobID: UUID(uuidString: "aaaaaaaa-1111-1111-1111-111111111111")!,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "a", count: 64),
      maximumCommentParts: 8
    )
    let evidence = String(repeating: "b", count: 64)
    let preview = JobCanaryReport(
      scope: scope,
      previewEvidenceSHA256: evidence,
      authorizationSHA256: nil,
      status: .preview,
      repositoryOwner: "owner",
      repositoryName: "repo",
      objectNumber: 42,
      revisionKey: String(repeating: "c", count: 40),
      provider: "openai-codex",
      model: "gpt-5.6-sol",
      thinking: "max",
      resourceTreeSHA256: String(repeating: "d", count: 64),
      replayed: false
    )
    let previewRequest = EngineXPCRequest(command: .previewJobCanary(scope))
    let previewResponse = EngineXPCResponse(
      requestID: previewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanary,
        state: engineProtocolState(paused: true),
        jobCanary: preview
      )
    )
    #expect(try previewResponse.validate(for: previewRequest).jobCanary == preview)
    let authorization = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: evidence
    )
    let settled = JobCanaryReport(
      scope: scope,
      previewEvidenceSHA256: evidence,
      authorizationSHA256: authorization.authorizationSHA256,
      status: .settled,
      repositoryOwner: preview.repositoryOwner,
      repositoryName: preview.repositoryName,
      objectNumber: preview.objectNumber,
      revisionKey: preview.revisionKey,
      provider: preview.provider,
      model: preview.model,
      thinking: preview.thinking,
      resourceTreeSHA256: preview.resourceTreeSHA256,
      replayed: false
    )
    let executeRequest = EngineXPCRequest(command: .executeJobCanary(authorization))
    let checkpoint = EngineCheckpointReceipt(
      checkpointID: UUID(), completedAt: Date(), nonterminalJobCount: 155,
      ambiguousMutationCount: 0, databaseCheckpointed: true
    )
    let executeResponse = EngineXPCResponse(
      requestID: executeRequest.requestID,
      result: EngineCommandResponse(
        command: .executeJobCanary,
        state: engineProtocolState(paused: true),
        checkpoint: checkpoint,
        jobCanary: settled
      )
    )
    #expect(try executeResponse.validate(for: executeRequest).jobCanary == settled)
    let unpaused = EngineXPCResponse(
      requestID: previewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanary,
        state: engineProtocolState(),
        jobCanary: preview
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try unpaused.validate(for: previewRequest)
    }
    let missingCheckpoint = EngineXPCResponse(
      requestID: executeRequest.requestID,
      result: EngineCommandResponse(
        command: .executeJobCanary,
        state: engineProtocolState(paused: true),
        jobCanary: settled
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try missingCheckpoint.validate(for: executeRequest)
    }

    let recoveryPreview = JobCanaryRecoveryReport(
      jobID: scope.jobID,
      canaryAuthorizationSHA256: authorization.authorizationSHA256,
      recoveryEvidenceSHA256: String(repeating: "e", count: 64),
      recoveryAuthorizationSHA256: nil,
      status: .preview,
      repositoryOwner: preview.repositoryOwner,
      repositoryName: preview.repositoryName,
      objectNumber: preview.objectNumber,
      revisionKey: preview.revisionKey,
      provider: preview.provider,
      model: preview.model,
      thinking: preview.thinking,
      resourceTreeSHA256: preview.resourceTreeSHA256,
      unknownIntentID: "layout-unknown",
      unknownIntentSHA256: String(repeating: "f", count: 64),
      unknownPayloadSHA256: String(repeating: "1", count: 64),
      layoutSHA256: String(repeating: "2", count: 64),
      hostExecutableSHA256: String(repeating: "4", count: 64),
      roles: [.architecture, .security, .test, .synthesis],
      replayed: false
    )
    let recoveryPreviewRequest = EngineXPCRequest(
      command: .previewJobCanaryRecovery(authorization)
    )
    let recoveryPreviewResponse = EngineXPCResponse(
      requestID: recoveryPreviewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanaryRecovery,
        state: engineProtocolState(paused: true),
        jobCanaryRecovery: recoveryPreview
      )
    )
    #expect(
      try recoveryPreviewResponse.validate(for: recoveryPreviewRequest).jobCanaryRecovery
        == recoveryPreview
    )
    let recoveryAuthorization = JobCanaryRecoveryAuthorization(
      canary: authorization,
      recoveryEvidenceSHA256: recoveryPreview.recoveryEvidenceSHA256
    )
    let recovered = JobCanaryRecoveryReport(
      jobID: recoveryPreview.jobID,
      canaryAuthorizationSHA256: recoveryPreview.canaryAuthorizationSHA256,
      recoveryEvidenceSHA256: recoveryPreview.recoveryEvidenceSHA256,
      recoveryAuthorizationSHA256: recoveryAuthorization.authorizationSHA256,
      status: .recovered,
      repositoryOwner: recoveryPreview.repositoryOwner,
      repositoryName: recoveryPreview.repositoryName,
      objectNumber: recoveryPreview.objectNumber,
      revisionKey: recoveryPreview.revisionKey,
      provider: recoveryPreview.provider,
      model: recoveryPreview.model,
      thinking: recoveryPreview.thinking,
      resourceTreeSHA256: recoveryPreview.resourceTreeSHA256,
      unknownIntentID: recoveryPreview.unknownIntentID,
      unknownIntentSHA256: recoveryPreview.unknownIntentSHA256,
      unknownPayloadSHA256: recoveryPreview.unknownPayloadSHA256,
      layoutSHA256: recoveryPreview.layoutSHA256,
      hostExecutableSHA256: recoveryPreview.hostExecutableSHA256,
      roles: recoveryPreview.roles,
      replayed: false
    )
    let recoveryExecuteRequest = EngineXPCRequest(
      command: .executeJobCanaryRecovery(recoveryAuthorization)
    )
    let recoveryExecuteResponse = EngineXPCResponse(
      requestID: recoveryExecuteRequest.requestID,
      result: EngineCommandResponse(
        command: .executeJobCanaryRecovery,
        state: engineProtocolState(paused: true),
        checkpoint: checkpoint,
        jobCanary: settled,
        jobCanaryRecovery: recovered
      )
    )
    #expect(
      try recoveryExecuteResponse.validate(for: recoveryExecuteRequest).jobCanaryRecovery
        == recovered
    )

    let retryPreview = JobCanaryPiRetryReport(
      jobID: scope.jobID,
      canaryAuthorizationSHA256: authorization.authorizationSHA256,
      recoveryEvidenceSHA256: recoveryAuthorization.recoveryEvidenceSHA256,
      retryEvidenceSHA256: String(repeating: "5", count: 64),
      retryAuthorizationSHA256: nil,
      agentAuthorityProtocol: JobCanaryPiRetryEvidence.agentAuthorityResetProtocolV1,
      failedPrimeIntentID: "prime-33333333-3333-4333-8333-333333333333",
      failedPrimeIntentSHA256: String(repeating: "6", count: 64),
      failedPrimePayloadSHA256: String(repeating: "7", count: 64),
      stalePaneRevision: 3,
      stalePaneHadTokens: true,
      stalePaneTokensSHA256: String(repeating: "8", count: 64),
      status: .preview,
      runID: "run-11111111-1111-1111-1111-111111111111",
      failedLaunchAttemptID: "launch-22222222-2222-2222-2222-222222222222",
      provider: preview.provider,
      model: preview.model,
      thinking: preview.thinking,
      credentialType: "oauth",
      credentialExpiresAtMilliseconds: 1_900_000_000_000,
      replayed: false
    )
    let retryPreviewRequest = EngineXPCRequest(
      command: .previewJobCanaryPiRetry(recoveryAuthorization)
    )
    let retryPreviewResponse = EngineXPCResponse(
      requestID: retryPreviewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanaryPiRetry,
        state: engineProtocolState(paused: true),
        jobCanaryPiRetry: retryPreview
      )
    )
    #expect(
      try retryPreviewResponse.validate(for: retryPreviewRequest).jobCanaryPiRetry
        == retryPreview
    )
    let retryAuthorization = JobCanaryPiRetryAuthorization(
      recovery: recoveryAuthorization,
      retryEvidenceSHA256: retryPreview.retryEvidenceSHA256
    )
    let retryAuthorized = JobCanaryPiRetryReport(
      jobID: retryPreview.jobID,
      canaryAuthorizationSHA256: retryPreview.canaryAuthorizationSHA256,
      recoveryEvidenceSHA256: retryPreview.recoveryEvidenceSHA256,
      retryEvidenceSHA256: retryPreview.retryEvidenceSHA256,
      retryAuthorizationSHA256: retryAuthorization.authorizationSHA256,
      agentAuthorityProtocol: retryPreview.agentAuthorityProtocol,
      failedPrimeIntentID: retryPreview.failedPrimeIntentID,
      failedPrimeIntentSHA256: retryPreview.failedPrimeIntentSHA256,
      failedPrimePayloadSHA256: retryPreview.failedPrimePayloadSHA256,
      stalePaneRevision: retryPreview.stalePaneRevision,
      stalePaneHadTokens: retryPreview.stalePaneHadTokens,
      stalePaneTokensSHA256: retryPreview.stalePaneTokensSHA256,
      status: .authorized,
      runID: retryPreview.runID,
      failedLaunchAttemptID: retryPreview.failedLaunchAttemptID,
      provider: retryPreview.provider,
      model: retryPreview.model,
      thinking: retryPreview.thinking,
      credentialType: retryPreview.credentialType,
      credentialExpiresAtMilliseconds: retryPreview.credentialExpiresAtMilliseconds,
      replayed: false
    )
    let retryExecuteRequest = EngineXPCRequest(
      command: .executeJobCanaryPiRetry(retryAuthorization)
    )
    let retryExecuteResponse = EngineXPCResponse(
      requestID: retryExecuteRequest.requestID,
      result: EngineCommandResponse(
        command: .executeJobCanaryPiRetry,
        state: engineProtocolState(paused: true),
        checkpoint: checkpoint,
        jobCanary: settled,
        jobCanaryPiRetry: retryAuthorized
      )
    )
    #expect(
      try retryExecuteResponse.validate(for: retryExecuteRequest).jobCanaryPiRetry
        == retryAuthorized
    )

    let replacementRequest = JobCanaryRoleHostReplacementRequest(
      retry: retryAuthorization,
      incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
      plannedReplacementRoleHostID: "rolehost-44444444-4444-4444-8444-444444444444",
      plannedLaunchAttemptID: "launch-55555555-5555-4555-8555-555555555555"
    )
    let q4Binding = replacementQ4Binding()
    let replacementPreview = try JobCanaryRoleHostReplacementReport(
      jobID: scope.jobID,
      runID: retryPreview.runID,
      predecessorRoleHostID: "rolehost-66666666-6666-4666-8666-666666666666",
      replacementRoleHostID: replacementRequest.plannedReplacementRoleHostID,
      plannedLaunchAttemptID: replacementRequest.plannedLaunchAttemptID,
      incidentAuditSHA256: replacementRequest.incidentAuditSHA256,
      replacementEvidenceSHA256: String(repeating: "9", count: 64),
      replacementAuthorizationSHA256: nil,
      q4Binding: q4Binding,
      outcome: .preview,
      replayed: false
    )
    let replacementPreviewRequest = EngineXPCRequest(
      command: .previewJobCanaryRoleHostReplacement(replacementRequest)
    )
    let replacementPreviewResponse = EngineXPCResponse(
      requestID: replacementPreviewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanaryRoleHostReplacement,
        state: engineProtocolState(paused: true),
        jobCanaryRoleHostReplacement: replacementPreview
      )
    )
    #expect(
      try replacementPreviewResponse.validate(for: replacementPreviewRequest)
        .jobCanaryRoleHostReplacement == replacementPreview
    )
    let replacementAuthorization = JobCanaryRoleHostReplacementAuthorization(
      request: replacementRequest,
      replacementEvidenceSHA256: replacementPreview.replacementEvidenceSHA256,
      q4Binding: q4Binding
    )
    let replacementAuthorized = try JobCanaryRoleHostReplacementReport(
      jobID: replacementPreview.jobID,
      runID: replacementPreview.runID,
      predecessorRoleHostID: replacementPreview.predecessorRoleHostID,
      replacementRoleHostID: replacementPreview.replacementRoleHostID,
      plannedLaunchAttemptID: replacementPreview.plannedLaunchAttemptID,
      incidentAuditSHA256: replacementPreview.incidentAuditSHA256,
      replacementEvidenceSHA256: replacementPreview.replacementEvidenceSHA256,
      replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
      q4Binding: q4Binding,
      outcome: .q4Settled,
      replayed: false
    )
    let replacementExecuteRequest = EngineXPCRequest(
      command: .executeJobCanaryRoleHostReplacement(replacementAuthorization)
    )
    let replacementExecuteResponse = EngineXPCResponse(
      requestID: replacementExecuteRequest.requestID,
      result: EngineCommandResponse(
        command: .executeJobCanaryRoleHostReplacement,
        state: engineProtocolState(paused: true),
        checkpoint: checkpoint,
        jobCanary: settled,
        jobCanaryRoleHostReplacement: replacementAuthorized
      )
    )
    #expect(
      try replacementExecuteResponse.validate(for: replacementExecuteRequest)
        .jobCanaryRoleHostReplacement == replacementAuthorized
    )

    let terminalQuery = try JobCanaryRoleHostReplacementReport(
      jobID: replacementPreview.jobID,
      runID: replacementPreview.runID,
      predecessorRoleHostID: replacementPreview.predecessorRoleHostID,
      replacementRoleHostID: replacementPreview.replacementRoleHostID,
      plannedLaunchAttemptID: replacementPreview.plannedLaunchAttemptID,
      incidentAuditSHA256: replacementPreview.incidentAuditSHA256,
      replacementEvidenceSHA256: replacementPreview.replacementEvidenceSHA256,
      replacementAuthorizationSHA256: replacementAuthorization.authorizationSHA256,
      q4Binding: q4Binding,
      outcome: .q4Failed(failureCode: "CHILD_FAILED"),
      replayed: true
    )
    let terminalQueryResponse = EngineXPCResponse(
      requestID: replacementPreviewRequest.requestID,
      result: EngineCommandResponse(
        command: .previewJobCanaryRoleHostReplacement,
        state: engineProtocolState(paused: true),
        jobCanaryRoleHostReplacement: terminalQuery
      )
    )
    #expect(
      try terminalQueryResponse.validate(for: replacementPreviewRequest)
        .jobCanaryRoleHostReplacement == terminalQuery
    )
  }

  @Test("replacement terminal outcomes serialize only closed status and effect shapes")
  func replacementTerminalOutcomeSerialization() throws {
    let binding = replacementQ4Binding()
    let outcomes: [JobCanaryRoleHostReplacementOutcome] = [
      .preview,
      .noRemoteEffectFailure(failureCode: "INVALID_PREPARATION"),
      .remoteEffectAmbiguous,
      .q4Prepared,
      .q4Enqueued,
      .q4OutcomeAmbiguous(failureCode: nil),
      .q4OutcomeAmbiguous(failureCode: "RUNTIME_INTERRUPTED"),
      .q4Failed(failureCode: "CHILD_FAILED"),
      .q4Settled,
      .replacementHostLost,
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for outcome in outcomes {
      let report = try JobCanaryRoleHostReplacementReport(
        jobID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        runID: "run-22222222-2222-4222-8222-222222222222",
        predecessorRoleHostID: "rolehost-33333333-3333-4333-8333-333333333333",
        replacementRoleHostID: "rolehost-44444444-4444-4444-8444-444444444444",
        plannedLaunchAttemptID: "launch-55555555-5555-4555-8555-555555555555",
        incidentAuditSHA256: String(repeating: "8", count: 64),
        replacementEvidenceSHA256: String(repeating: "9", count: 64),
        replacementAuthorizationSHA256: outcome == .preview
          ? nil : String(repeating: "a", count: 64),
        q4Binding: binding,
        outcome: outcome,
        replayed: false
      )
      let encoded = try encoder.encode(report)
      let decoded = try JSONDecoder().decode(
        JobCanaryRoleHostReplacementReport.self,
        from: encoded
      )
      #expect(decoded == report)
      #expect(decoded.status == outcome.status)
      #expect(decoded.effectCertainty == outcome.effectCertainty)
      #expect(decoded.failureCode == outcome.failureCode)
      let object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      #expect(object["remoteEffectsExecuted"] == nil)
      #expect(object["status"] as? String == outcome.status.rawValue)
      #expect(
        object["effectCertainty"] as? String == outcome.effectCertainty.rawValue
      )
    }

    let validFailure = try JobCanaryRoleHostReplacementReport(
      jobID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      runID: "run-22222222-2222-4222-8222-222222222222",
      predecessorRoleHostID: "rolehost-33333333-3333-4333-8333-333333333333",
      replacementRoleHostID: "rolehost-44444444-4444-4444-8444-444444444444",
      plannedLaunchAttemptID: "launch-55555555-5555-4555-8555-555555555555",
      incidentAuditSHA256: String(repeating: "8", count: 64),
      replacementEvidenceSHA256: String(repeating: "9", count: 64),
      replacementAuthorizationSHA256: String(repeating: "a", count: 64),
      q4Binding: binding,
      outcome: .q4Failed(failureCode: "CHILD_FAILED"),
      replayed: false
    )
    let validData = try encoder.encode(validFailure)
    let base = try #require(
      try JSONSerialization.jsonObject(with: validData) as? [String: Any]
    )
    let terminalRules:
      [(
        status: JobCanaryRoleHostReplacementStatus,
        effect: JobCanaryRoleHostReplacementEffectCertainty,
        allowsNoFailure: Bool,
        allowsValidFailure: Bool
      )] = [
        (.noRemoteEffectFailure, .knownNoRemoteEffect, false, true),
        (.remoteEffectAmbiguous, .possibleRemoteEffect, true, false),
        (.q4Prepared, .confirmedReplacementEffect, true, false),
        (.q4Enqueued, .confirmedReplacementEffect, true, false),
        (.q4OutcomeAmbiguous, .confirmedReplacementEffect, true, true),
        (.q4Failed, .confirmedReplacementEffect, false, true),
        (.q4Settled, .confirmedReplacementEffect, true, false),
        (.replacementHostLost, .confirmedReplacementEffect, true, false),
      ]
    let effects: [JobCanaryRoleHostReplacementEffectCertainty] = [
      .knownNoRemoteEffect, .possibleRemoteEffect, .confirmedReplacementEffect,
    ]
    let failureCodes: [String?] = [nil, "CHILD_FAILED", "lowercase"]
    for rule in terminalRules {
      for effect in effects {
        for failureCode in failureCodes {
          var object = base
          object["status"] = rule.status.rawValue
          object["effectCertainty"] = effect.rawValue
          if let failureCode {
            object["failureCode"] = failureCode
          } else {
            object.removeValue(forKey: "failureCode")
          }
          let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
          )
          let failureIsValid =
            failureCode == nil
            ? rule.allowsNoFailure
            : failureCode == "CHILD_FAILED" && rule.allowsValidFailure
          let shapeIsValid = effect == rule.effect && failureIsValid
          if shapeIsValid {
            let decoded = try JSONDecoder().decode(
              JobCanaryRoleHostReplacementReport.self,
              from: data
            )
            #expect(decoded.status == rule.status)
            #expect(decoded.effectCertainty == rule.effect)
            #expect(decoded.failureCode == failureCode)
          } else {
            #expect(throws: (any Error).self) {
              _ = try JSONDecoder().decode(
                JobCanaryRoleHostReplacementReport.self,
                from: data
              )
            }
          }
        }
      }
    }

    for (key, value) in [
      ("status", "unknownTerminalStatus"),
      ("effectCertainty", "unknownEffectCertainty"),
    ] {
      var object = base
      object[key] = value
      let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(
          JobCanaryRoleHostReplacementReport.self,
          from: data
        )
      }
    }
  }

  @Test("schema 9 decodes the immutable schema 7 retry report fixture")
  func schemaSevenRetryReportCompatibility() throws {
    let fixture = Data(
      """
      {"canaryAuthorizationSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","credentialExpiresAtMilliseconds":1900000000000,"credentialType":"oauth","failedLaunchAttemptID":"launch-22222222-2222-4222-8222-222222222222","jobID":"11111111-1111-4111-8111-111111111111","model":"gpt-5.6-sol","provider":"openai-codex","recoveryEvidenceSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","replayed":false,"retryEvidenceSHA256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","runID":"run-33333333-3333-4333-8333-333333333333","status":"preview","thinking":"max"}
      """.utf8
    )
    let report = try JSONDecoder().decode(JobCanaryPiRetryReport.self, from: fixture)
    #expect(report.agentAuthorityProtocol == nil)
    #expect(report.failedPrimeIntentID == nil)
    #expect(report.stalePaneTokensSHA256 == nil)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(report)
    let object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    for resetKey in [
      "agentAuthorityProtocol", "failedPrimeIntentID", "failedPrimeIntentSHA256",
      "failedPrimePayloadSHA256", "stalePaneRevision", "stalePaneHadTokens",
      "stalePaneTokensSHA256",
    ] {
      #expect(object[resetKey] == nil)
    }
  }

  @Test("unsupported versions and malformed request IDs fail closed")
  func versionBoundary() {
    #expect(throws: EngineClientError(.unsupportedVersion)) {
      try EngineXPCRequest(
        protocolVersion: EngineProtocolVersion.current + 1,
        command: .snapshot
      ).validate()
    }
    #expect(throws: EngineClientError(.invalidRequest)) {
      try EngineXPCRequest(requestID: "not-a-uuid", command: .snapshot).validate()
    }
    #expect(throws: EngineClientError(.invalidCommand)) {
      try EngineXPCRequest(command: .replaceCredential(Data("short".utf8))).validate()
    }
  }

  @Test("production XPC handler returns exact envelopes without reflecting credential bytes")
  func messageHandler() async throws {
    let client = EngineXPCClientFake()
    let handler = EngineXPCMessageHandler(client: client)
    let token = Data("github_pat_xpc_secret_1234567890".utf8)
    let request = EngineXPCRequest(
      requestID: "11111111-1111-1111-1111-111111111111",
      command: .replaceCredential(token)
    )
    let encoder = JSONEncoder()
    let payload = await handler.handle(try encoder.encode(request))
    #expect(!payload.contains(token))
    let response = try JSONDecoder().decode(EngineXPCResponse.self, from: payload)
    #expect(try response.validate(for: request).command == .replaceCredential)

    let unsupported = EngineXPCRequest(
      protocolVersion: EngineProtocolVersion.current + 1,
      requestID: "22222222-2222-2222-2222-222222222222",
      command: .snapshot
    )
    let unsupportedResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(try encoder.encode(unsupported))
    )
    #expect(unsupportedResponse.requestID == unsupported.requestID)
    #expect(unsupportedResponse.error == EngineClientError(.unsupportedVersion))
    #expect(throws: EngineClientError(.unsupportedVersion)) {
      try unsupportedResponse.validate(for: unsupported)
    }

    let malformedResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(Data("not-json".utf8))
    )
    #expect(malformedResponse.requestID == "invalid")
    #expect(malformedResponse.error == EngineClientError(.invalidRequest))

    let restricted = EngineXPCMessageHandler(
      client: client,
      allowedCommands: [.snapshot]
    )
    let topologyRequest = EngineXPCRequest(command: .setLoginEnabled(true))
    let topologyResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await restricted.handle(try encoder.encode(topologyRequest))
    )
    #expect(topologyResponse.error == EngineClientError(.invalidCommand))

    await client.fail(with: .busy)
    let busyRequest = EngineXPCRequest(command: .pollNow)
    let busyResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(try encoder.encode(busyRequest))
    )
    #expect(busyResponse.error == EngineClientError(.busy))

    await client.fail(with: .credentialAccessFailed)
    let credentialRequest = EngineXPCRequest(command: .snapshot)
    let credentialResponseData = await handler.handle(
      try encoder.encode(credentialRequest)
    )
    #expect(
      !String(decoding: credentialResponseData, as: UTF8.self)
        .localizedCaseInsensitiveContains("token")
    )
    let credentialResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: credentialResponseData
    )
    #expect(credentialResponse.error == EngineClientError(.credentialAccessFailed))
    #expect(throws: EngineClientError(.credentialAccessFailed)) {
      try credentialResponse.validate(for: credentialRequest)
    }
  }

  @Test("generation rollover responses bind phase authority and checkpoints")
  func generationRolloverResponses() throws {
    let scope = JobCanaryScope(
      jobID: UUID(uuidString: "97000000-0000-4000-8000-000000000097")!,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "a", count: 64),
      maximumCommentParts: 8
    )
    let retry = JobCanaryPiRetryAuthorization(
      recovery: JobCanaryRecoveryAuthorization(
        canary: JobCanaryAuthorization(
          scope: scope,
          previewEvidenceSHA256: String(repeating: "b", count: 64)
        ),
        recoveryEvidenceSHA256: String(repeating: "c", count: 64)
      ),
      retryEvidenceSHA256: String(repeating: "d", count: 64)
    )
    let fixture = try engineGenerationRolloverFixture(retry: retry)
    let state = engineProtocolState(paused: true)
    let checkpoint = EngineCheckpointReceipt(
      checkpointID: UUID(uuidString: "98000000-0000-4000-8000-000000000098")!,
      completedAt: Date(timeIntervalSince1970: 1),
      nonterminalJobCount: 156,
      ambiguousMutationCount: 0,
      databaseCheckpointed: true
    )

    let previewReport = try JobCanaryGenerationRolloverReport(
      authorization: fixture.authorization,
      status: .preview,
      replayed: false
    )
    let previewRequest = EngineXPCRequest(
      requestID: "99000000-0000-4000-8000-000000000099",
      command: .previewJobCanaryGenerationRollover(fixture.request)
    )
    let previewResult = EngineCommandResponse(
      command: previewRequest.command.kind,
      state: state,
      jobCanaryGenerationRollover: previewReport
    )
    #expect(
      try EngineXPCResponse(requestID: previewRequest.requestID, result: previewResult)
        .validate(for: previewRequest) == previewResult
    )

    let executeReport = try JobCanaryGenerationRolloverReport(
      authorization: fixture.authorization,
      status: .topologyActivated,
      replayed: false
    )
    let executeRequest = EngineXPCRequest(
      requestID: "9a000000-0000-4000-8000-00000000009a",
      command: .executeJobCanaryGenerationRollover(fixture.authorization)
    )
    let executeResult = EngineCommandResponse(
      command: executeRequest.command.kind,
      state: state,
      checkpoint: checkpoint,
      jobCanaryGenerationRollover: executeReport
    )
    #expect(
      try EngineXPCResponse(requestID: executeRequest.requestID, result: executeResult)
        .validate(for: executeRequest) == executeResult
    )

    let q4PreviewReport = try JobCanaryGenerationRolloverQ4Report(
      authorization: fixture.q4Execution.q4,
      status: .preview,
      replayed: false
    )
    let q4PreviewRequest = EngineXPCRequest(
      requestID: "9b000000-0000-4000-8000-00000000009b",
      command: .previewJobCanaryGenerationRolloverQ4(fixture.q4Request)
    )
    let q4PreviewResult = EngineCommandResponse(
      command: q4PreviewRequest.command.kind,
      state: state,
      jobCanaryGenerationRolloverQ4: q4PreviewReport
    )
    #expect(
      try EngineXPCResponse(requestID: q4PreviewRequest.requestID, result: q4PreviewResult)
        .validate(for: q4PreviewRequest) == q4PreviewResult
    )

    let q4ExecuteReport = try JobCanaryGenerationRolloverQ4Report(
      authorization: fixture.q4Execution.q4,
      status: .settled,
      replayed: false
    )
    let q4ExecuteRequest = EngineXPCRequest(
      requestID: "9c000000-0000-4000-8000-00000000009c",
      command: .executeJobCanaryGenerationRolloverQ4(fixture.q4Execution)
    )
    let q4ExecuteResult = EngineCommandResponse(
      command: q4ExecuteRequest.command.kind,
      state: state,
      checkpoint: checkpoint,
      jobCanaryGenerationRolloverQ4: q4ExecuteReport
    )
    #expect(
      try EngineXPCResponse(requestID: q4ExecuteRequest.requestID, result: q4ExecuteResult)
        .validate(for: q4ExecuteRequest) == q4ExecuteResult
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      _ = try EngineXPCResponse(
        requestID: q4ExecuteRequest.requestID,
        result: EngineCommandResponse(
          command: q4ExecuteRequest.command.kind,
          state: state,
          jobCanaryGenerationRolloverQ4: q4ExecuteReport
        )
      ).validate(for: q4ExecuteRequest)
    }
  }

  @Test("all commands survive a Codable round trip without changing kind")
  func codableCommands() throws {
    let mutation = EngineAmbiguousMutation(
      jobID: UUID(),
      repositoryID: UUID(),
      repositoryOwner: "owner",
      repositoryName: "repo",
      kind: .prReview,
      objectNodeID: "PR_node",
      objectNumber: 7,
      revisionKey: String(repeating: "a", count: 40),
      evidenceDigest: String(repeating: "b", count: 64),
      mutationGeneration: 2,
      mutationID: UUID().uuidString.lowercased()
    )
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "R_node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    let maintenanceScope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let canaryScope = JobCanaryScope(
      jobID: UUID(),
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "d", count: 64),
      maximumCommentParts: 8
    )
    let replacementRetry = JobCanaryPiRetryAuthorization(
      recovery: JobCanaryRecoveryAuthorization(
        canary: JobCanaryAuthorization(
          scope: canaryScope,
          previewEvidenceSHA256: String(repeating: "e", count: 64)
        ),
        recoveryEvidenceSHA256: String(repeating: "f", count: 64)
      ),
      retryEvidenceSHA256: String(repeating: "1", count: 64)
    )
    let replacementRequest = JobCanaryRoleHostReplacementRequest(
      retry: replacementRetry,
      incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
      plannedReplacementRoleHostID: "rolehost-77777777-7777-4777-8777-777777777777",
      plannedLaunchAttemptID: "launch-88888888-8888-4888-8888-888888888888"
    )
    let rollover = try engineGenerationRolloverFixture(retry: replacementRetry)
    let commands: [EngineCommand] = [
      .snapshot,
      .refreshModelCatalog,
      .acknowledgeExternalAutomation(true),
      .acknowledgeProviderDisclosure(true),
      .runPiPreflight,
      .runHerdrPreflight,
      .focusInHerdr,
      .replaceCredential(Data(String(repeating: "x", count: 20).utf8)),
      .deleteCredential,
      .addRepository(
        EngineRepositoryDraft(
          owner: "owner",
          name: "repo",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true
        )
      ),
      .updateRepository(repository),
      .removeRepository(repository.id),
      .setProfile(
        ModelProfileConfiguration(
          role: .review,
          provider: "openai-codex",
          model: "gpt-5.6-sol",
          thinking: .max
        )
      ),
      .setMaxConcurrency(4),
      .setPaused(true),
      .pollNow,
      .recheckAmbiguousMutation(EngineAmbiguousMutationEvidence(mutation)),
      .authorizeRetry(EngineAmbiguousMutationEvidence(mutation)),
      .previewJobMaintenance(maintenanceScope),
      .applyJobMaintenance(
        JobMaintenanceAuthorization(
          scope: maintenanceScope,
          expectedCount: 87,
          evidenceSHA256: String(repeating: "c", count: 64)
        )
      ),
      .previewJobCanary(canaryScope),
      .executeJobCanary(
        JobCanaryAuthorization(
          scope: canaryScope,
          previewEvidenceSHA256: String(repeating: "e", count: 64)
        )
      ),
      .previewJobCanaryRecovery(
        JobCanaryAuthorization(
          scope: canaryScope,
          previewEvidenceSHA256: String(repeating: "e", count: 64)
        )
      ),
      .executeJobCanaryRecovery(
        JobCanaryRecoveryAuthorization(
          canary: JobCanaryAuthorization(
            scope: canaryScope,
            previewEvidenceSHA256: String(repeating: "e", count: 64)
          ),
          recoveryEvidenceSHA256: String(repeating: "f", count: 64)
        )
      ),
      .previewJobCanaryPiRetry(
        JobCanaryRecoveryAuthorization(
          canary: JobCanaryAuthorization(
            scope: canaryScope,
            previewEvidenceSHA256: String(repeating: "e", count: 64)
          ),
          recoveryEvidenceSHA256: String(repeating: "f", count: 64)
        )
      ),
      .executeJobCanaryPiRetry(
        JobCanaryPiRetryAuthorization(
          recovery: JobCanaryRecoveryAuthorization(
            canary: JobCanaryAuthorization(
              scope: canaryScope,
              previewEvidenceSHA256: String(repeating: "e", count: 64)
            ),
            recoveryEvidenceSHA256: String(repeating: "f", count: 64)
          ),
          retryEvidenceSHA256: String(repeating: "1", count: 64)
        )
      ),
      .previewJobCanaryRoleHostReplacement(replacementRequest),
      .executeJobCanaryRoleHostReplacement(
        JobCanaryRoleHostReplacementAuthorization(
          request: replacementRequest,
          replacementEvidenceSHA256: String(repeating: "2", count: 64),
          q4Binding: replacementQ4Binding()
        )
      ),
      .previewJobCanaryGenerationRollover(rollover.request),
      .executeJobCanaryGenerationRollover(rollover.authorization),
      .previewJobCanaryGenerationRolloverQ4(rollover.q4Request),
      .executeJobCanaryGenerationRolloverQ4(rollover.q4Execution),
      .setLoginEnabled(true),
      .synchronizeLoginStatus(selected: true, status: .enabled),
      .completeOnboarding,
      .rollbackOnboarding,
      .prepareForHandoff,
      .prepareForQuit,
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for command in commands {
      let decoded = try decoder.decode(EngineCommand.self, from: encoder.encode(command))
      #expect(decoded == command)
      #expect(decoded.kind == command.kind)
    }
  }
}

private actor EngineXPCClientFake: EngineClient {
  private var error: EngineClientErrorCode?

  func fail(with error: EngineClientErrorCode) {
    self.error = error
  }

  func send(_ command: EngineCommand) throws -> EngineCommandResponse {
    if let error { throw EngineClientError(error) }
    return EngineCommandResponse(command: command.kind, state: engineProtocolState())
  }
}

private func replacementQ4Binding() -> JobCanaryRoleHostReplacementQ4Binding {
  JobCanaryRoleHostReplacementQ4Binding(
    descriptorSHA256: String(repeating: "1", count: 64),
    configurationSHA256: String(repeating: "2", count: 64),
    promptSHA256: String(repeating: "3", count: 64),
    workflowConfigurationSHA256: String(repeating: "4", count: 64),
    priorLaunchDescriptorSHA256: String(repeating: "5", count: 64),
    priorLaunchConfigurationSHA256: String(repeating: "6", count: 64),
    resourceTreeSHA256: String(repeating: "7", count: 64)
  )
}

struct EngineGenerationRolloverFixture {
  let request: JobCanaryGenerationRolloverRequest
  let authorization: JobCanaryGenerationRolloverAuthorization
  let q4Request: JobCanaryGenerationRolloverQ4Request
  let q4Execution: JobCanaryGenerationRolloverQ4ExecutionAuthorization
}

func engineGenerationRolloverFixture(
  retry: JobCanaryPiRetryAuthorization
) throws -> EngineGenerationRolloverFixture {
  let planned: [JobCanaryGenerationRolloverPlannedHost] = [
    .init(role: .architecture, roleHostID: "rolehost-91000000-0000-4000-8000-000000000091"),
    .init(role: .security, roleHostID: "rolehost-92000000-0000-4000-8000-000000000092"),
    .init(role: .synthesis, roleHostID: "rolehost-93000000-0000-4000-8000-000000000093"),
    .init(role: .test, roleHostID: "rolehost-94000000-0000-4000-8000-000000000094"),
  ]
  let request = JobCanaryGenerationRolloverRequest(
    retry: retry,
    successorRunID: "run-engine-rollover-successor",
    plannedHosts: planned
  )
  let hosts = planned.enumerated().map { index, host in
    JobCanaryGenerationRolloverHostPair(
      role: host.role,
      predecessorRoleHostID: "rolehost-engine-old-\(host.role.rawValue)",
      predecessorBootstrapDescriptorSHA256: String(repeating: "1", count: 64),
      successorRoleHostID: host.roleHostID,
      successorBootstrapDescriptorSHA256: String(repeating: "2", count: 64),
      predecessorHostExecutableSHA256: String(repeating: "3", count: 64),
      successorHostExecutableSHA256: String(repeating: "4", count: 64),
      successorExecutableEvidenceSHA256: String(
        repeating: Character(String(format: "%x", index + 5)),
        count: 64
      )
    )
  }
  let launches = [
    JobCanaryGenerationRolloverLaunchEvidence(
      launchAttemptID: "launch-engine-q1", queueSequence: 1,
      descriptorSHA256: String(repeating: "1", count: 64),
      failureCode: "RUNTIME_TIMEOUT",
      childProcess: HerdrChildProcessRecord(
        launchAttemptID: "launch-engine-q1", processID: 81, processGroupID: 81,
        startSeconds: 82, startMicroseconds: 83
      )
    ),
    JobCanaryGenerationRolloverLaunchEvidence(
      launchAttemptID: "launch-engine-q2", queueSequence: 2,
      descriptorSHA256: String(repeating: "2", count: 64),
      failureCode: "HERDR_TRANSACTION_FAILED", childProcess: nil
    ),
    JobCanaryGenerationRolloverLaunchEvidence(
      launchAttemptID: "launch-engine-q3", queueSequence: 3,
      descriptorSHA256: String(repeating: "3", count: 64),
      failureCode: "HERDR_TRANSACTION_FAILED", childProcess: nil
    ),
  ]
  let authorization = JobCanaryGenerationRolloverAuthorization(
    request: request,
    canaryAuthorizationSHA256: retry.recovery.canary.authorizationSHA256,
    rolloverEvidenceSHA256: String(repeating: "5", count: 64),
    isolationSHA256: String(repeating: "6", count: 64),
    repositoryID: UUID(uuidString: "95000000-0000-4000-8000-000000000095")!,
    jobID: retry.recovery.canary.scope.jobID,
    predecessorGeneration: 1,
    successorGeneration: 2,
    predecessorRunID: "run-engine-rollover-predecessor",
    predecessorLaunches: launches,
    hosts: hosts,
    workspaceID: "workspace-engine-rollover",
    socket: JobCanaryGenerationRolloverSocketEvidence(
      device: 1, inode: 2, owner: 501, permissions: 0o600,
      peerEvidenceSHA256: String(repeating: "7", count: 64)
    ),
    successorRunID: request.successorRunID
  )
  let q4 = JobCanaryGenerationRolloverQ4Authorization(
    rolloverAuthorizationSHA256: authorization.authorizationSHA256,
    q4EvidenceSHA256: String(repeating: "8", count: 64),
    successorRunID: request.successorRunID,
    plannedLaunchAttemptID: "launch-96000000-0000-4000-8000-000000000096",
    runNonce: String(repeating: "9", count: 64),
    requestSHA256: String(repeating: "a", count: 64),
    resourceVersion: "1",
    resourceHash: String(repeating: "b", count: 64),
    model: "fixture/model:off",
    sessionPath: "/tmp/engine-rollover-session",
    channelPath: "/tmp/engine-rollover-channel",
    q4Binding: replacementQ4Binding()
  )
  let q4Request = JobCanaryGenerationRolloverQ4Request(
    rolloverAuthorization: authorization,
    plannedLaunchAttemptID: q4.plannedLaunchAttemptID
  )
  let q4Execution = JobCanaryGenerationRolloverQ4ExecutionAuthorization(
    rollover: authorization,
    q4: q4
  )
  try request.validate()
  try authorization.validate()
  try q4Request.validate()
  try q4Execution.validate()
  return EngineGenerationRolloverFixture(
    request: request,
    authorization: authorization,
    q4Request: q4Request,
    q4Execution: q4Execution
  )
}

private func engineProtocolState(
  herdr: EngineHerdrStatus = .unchecked,
  paused: Bool = false
) -> EngineUIState {
  let credential = EngineCredentialStatus.missing
  let pi = EnginePiStatus.unchecked
  let onboarding = EngineOnboardingSnapshot(
    duplicateInstanceCheckPassed: true,
    externalAutomationAcknowledged: false,
    providerDisclosureAcknowledged: false,
    pi: pi,
    herdr: herdr,
    credential: credential,
    repositoryCount: 0,
    configuredProfileRoles: [],
    loginItemSelected: false,
    loginItemStatus: .notRegistered,
    complete: false
  )
  return EngineUIState(
    revision: 0,
    lifecycle: .onboarding,
    operationalStatus: .active,
    paused: paused,
    passRunning: false,
    activities: [],
    ambiguousMutations: [],
    onboarding: onboarding,
    settings: EngineSettingsSnapshot(
      repositories: [],
      profiles: [],
      maxConcurrency: 2,
      loginItemSelected: false,
      loginItemStatus: .notRegistered,
      credential: credential,
      herdr: herdr,
      modelCatalog: PiModelCatalog(
        models: [
          PiModelCatalogEntry(
            provider: "openai-codex",
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            reasoning: true,
            input: [.text, .image],
            contextWindow: 200_000,
            maxTokens: 64_000,
            thinkingLevels: ModelThinkingLevel.allCases
          )
        ])
    ),
    diagnostics: EngineDiagnostics(
      schemaVersion: 2,
      nonterminalJobCount: 0,
      ambiguousMutationCount: 0,
      coordinatorFailureCodes: [],
      piIssueCode: nil,
      herdrIssueCode: nil
    )
  )
}
