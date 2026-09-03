import AppKit
import Foundation
import JidokaCodeCore
import Testing

@testable import JidokaCodeApp

@Suite("Application helper handoff")
struct ApplicationEngineClientTests {
  @Test("production activation notification identity is exact")
  func productionActivationNotification() {
    #expect(
      JidokaApplicationInstance.activationNotification == "com.maroffo.JidokaCode.ui.activate")
  }

  @Test("maintenance CLI accepts only closed evidence-bound commands")
  func maintenanceCLI() throws {
    let boundary = String(JobMaintenanceScope.authorizedBoundaryEpochSeconds)
    let evidence = String(repeating: "a", count: 64)
    #expect(
      try JobMaintenanceCLI.parse(["preview-retire-before", boundary])
        == .previewJobMaintenance(
          JobMaintenanceScope(
            operation: .retireBefore,
            boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
          )
        )
    )
    #expect(
      try JobMaintenanceCLI.parse([
        "apply-retry-resource-failures-after", boundary, "4", evidence,
      ])
        == .applyJobMaintenance(
          JobMaintenanceAuthorization(
            scope: JobMaintenanceScope(
              operation: .retryResourceFailuresAfter,
              boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
            ),
            expectedCount: 4,
            evidenceSHA256: evidence
          )
        )
    )
    for invalid in [
      ["preview-retire-before"],
      ["preview-retire-before", "not-an-epoch"],
      ["preview-retire-before", "1786924799"],
      ["apply-retire-before", boundary, "0", evidence],
      ["apply-retire-before", boundary, "1", "short"],
      ["unknown", boundary],
    ] {
      #expect(throws: EngineClientError(.invalidCommand)) {
        _ = try JobMaintenanceCLI.parse(invalid)
      }
    }
  }

  @Test("canary CLI accepts only exact bounded commands")
  func canaryCLI() throws {
    let id = "aaaaaaaa-1111-1111-1111-111111111111"
    let boundary = String(JobCanaryScope.authorizedBoundaryEpochSeconds)
    let repair = String(repeating: "a", count: 64)
    let preview = String(repeating: "b", count: 64)
    let recovery = String(repeating: "c", count: 64)
    let retry = String(repeating: "d", count: 64)
    let replacementEvidence = String(repeating: "e", count: 64)
    let q4Binding = JobCanaryRoleHostReplacementQ4Binding(
      descriptorSHA256: String(repeating: "1", count: 64),
      configurationSHA256: String(repeating: "2", count: 64),
      promptSHA256: String(repeating: "3", count: 64),
      workflowConfigurationSHA256: String(repeating: "4", count: 64),
      priorLaunchDescriptorSHA256: String(repeating: "5", count: 64),
      priorLaunchConfigurationSHA256: String(repeating: "6", count: 64),
      resourceTreeSHA256: String(repeating: "7", count: 64)
    )
    let q4Arguments = [
      q4Binding.descriptorSHA256,
      q4Binding.configurationSHA256,
      q4Binding.promptSHA256,
      q4Binding.workflowConfigurationSHA256,
      q4Binding.priorLaunchDescriptorSHA256,
      q4Binding.priorLaunchConfigurationSHA256,
      q4Binding.resourceTreeSHA256,
    ]
    let replacementHostID = "rolehost-11111111-1111-4111-8111-111111111111"
    let replacementLaunchID = "launch-22222222-2222-4222-8222-222222222222"
    let scope = JobCanaryScope(
      jobID: UUID(uuidString: id)!,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: repair,
      maximumCommentParts: 8
    )
    #expect(
      try JobCanaryCLI.parse(["preview", id, boundary, repair, "8"])
        == .previewJobCanary(scope)
    )
    let canary = JobCanaryAuthorization(scope: scope, previewEvidenceSHA256: preview)
    #expect(
      try JobCanaryCLI.parse(["execute", id, boundary, repair, "8", preview])
        == .executeJobCanary(canary)
    )
    #expect(
      try JobCanaryCLI.parse(["preview-recovery", id, boundary, repair, "8", preview])
        == .previewJobCanaryRecovery(canary)
    )
    let recoveryAuthorization = JobCanaryRecoveryAuthorization(
      canary: canary,
      recoveryEvidenceSHA256: recovery
    )
    #expect(
      try JobCanaryCLI.parse([
        "execute-recovery", id, boundary, repair, "8", preview, recovery,
      ])
        == .executeJobCanaryRecovery(recoveryAuthorization)
    )
    #expect(
      try JobCanaryCLI.parse([
        "preview-pi-retry", id, boundary, repair, "8", preview, recovery,
      ])
        == .previewJobCanaryPiRetry(recoveryAuthorization)
    )
    #expect(
      try JobCanaryCLI.parse([
        "execute-pi-retry", id, boundary, repair, "8", preview, recovery, retry,
      ])
        == .executeJobCanaryPiRetry(
          JobCanaryPiRetryAuthorization(
            recovery: recoveryAuthorization,
            retryEvidenceSHA256: retry
          )
        )
    )
    let retryAuthorization = JobCanaryPiRetryAuthorization(
      recovery: recoveryAuthorization,
      retryEvidenceSHA256: retry
    )
    let replacementRequest = JobCanaryRoleHostReplacementRequest(
      retry: retryAuthorization,
      incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
      plannedReplacementRoleHostID: replacementHostID,
      plannedLaunchAttemptID: replacementLaunchID
    )
    #expect(
      try JobCanaryCLI.parse([
        "preview-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
        JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
        replacementHostID, replacementLaunchID, "3", "true",
        JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
      ]) == .previewJobCanaryRoleHostReplacement(replacementRequest)
    )
    #expect(
      try JobCanaryCLI.parse(
        [
          "execute-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
          JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
          replacementHostID, replacementLaunchID, "3", "true",
          JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
          replacementEvidence,
        ] + q4Arguments
      )
        == .executeJobCanaryRoleHostReplacement(
          JobCanaryRoleHostReplacementAuthorization(
            request: replacementRequest,
            replacementEvidenceSHA256: replacementEvidence,
            q4Binding: q4Binding
          )
        )
    )
    for invalid in [
      ["preview", id, boundary, repair],
      ["preview", id.uppercased(), boundary, repair, "8"],
      ["preview", id, "1786924799", repair, "8"],
      ["preview", id, boundary, repair + "0", "8"],
      ["preview", id, boundary, repair, "0"],
      ["preview", id, boundary, repair, "65"],
      ["execute", id, boundary, repair, "8", "short"],
      ["preview-recovery", id, boundary, repair, "8", "short"],
      ["execute-recovery", id, boundary, repair, "8", preview, "short"],
      ["preview-pi-retry", id, boundary, repair, "8", preview, "short"],
      ["execute-pi-retry", id, boundary, repair, "8", preview, recovery, "short"],
      [
        "preview-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
        String(repeating: "f", count: 64), replacementHostID, replacementLaunchID,
        "3", "true", JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
      ],
      [
        "execute-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
        JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
        "rolehost-not-a-uuid", replacementLaunchID, "3", "true",
        JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
        replacementEvidence,
      ] + q4Arguments,
      [
        "preview-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
        JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
        replacementHostID, replacementLaunchID, "4", "true",
        JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
      ],
      [
        "execute-host-replacement", id, boundary, repair, "8", preview, recovery, retry,
        JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
        replacementHostID, replacementLaunchID, "3", "true",
        JobCanaryRoleHostReplacementRequest.authorizedStalePaneTokensSHA256,
        replacementEvidence,
      ] + ["short"] + Array(q4Arguments.dropFirst()),
    ] {
      #expect(throws: EngineClientError(.invalidCommand)) {
        _ = try JobCanaryCLI.parse(invalid)
      }
    }
  }

  @Test("generation rollover CLI accepts only canonical two-phase authority")
  func generationRolloverCLI() throws {
    let replacement = applicationReplacementAuthorization()
    let plannedHosts: [JobCanaryGenerationRolloverPlannedHost] = [
      .init(
        role: .architecture,
        roleHostID: "rolehost-71000000-0000-4000-8000-000000000071"
      ),
      .init(
        role: .security,
        roleHostID: "rolehost-72000000-0000-4000-8000-000000000072"
      ),
      .init(
        role: .synthesis,
        roleHostID: "rolehost-73000000-0000-4000-8000-000000000073"
      ),
      .init(
        role: .test,
        roleHostID: "rolehost-74000000-0000-4000-8000-000000000074"
      ),
    ]
    let request = JobCanaryGenerationRolloverRequest(
      retry: replacement.request.retry,
      successorRunID: "run-generation-rollover-cli",
      plannedHosts: plannedHosts
    )
    let roles = plannedHosts.map(\.role)
    let hostPairs = zip(roles, plannedHosts).enumerated().map { index, value in
      JobCanaryGenerationRolloverHostPair(
        role: value.0,
        predecessorRoleHostID: "rolehost-old-\(value.0.rawValue)",
        predecessorBootstrapDescriptorSHA256: String(
          repeating: Character(String(format: "%x", index + 1)),
          count: 64
        ),
        successorRoleHostID: value.1.roleHostID,
        successorBootstrapDescriptorSHA256: String(
          repeating: Character(String(format: "%x", index + 5)),
          count: 64
        ),
        predecessorHostExecutableSHA256: String(repeating: "d", count: 64),
        successorHostExecutableSHA256: String(repeating: "e", count: 64),
        successorExecutableEvidenceSHA256: String(repeating: "f", count: 64)
      )
    }
    let launches = [
      JobCanaryGenerationRolloverLaunchEvidence(
        launchAttemptID: "launch-cli-q1",
        queueSequence: 1,
        descriptorSHA256: String(repeating: "1", count: 64),
        failureCode: "RUNTIME_TIMEOUT",
        childProcess: HerdrChildProcessRecord(
          launchAttemptID: "launch-cli-q1",
          processID: 91,
          processGroupID: 91,
          startSeconds: 92,
          startMicroseconds: 93
        )
      ),
      JobCanaryGenerationRolloverLaunchEvidence(
        launchAttemptID: "launch-cli-q2",
        queueSequence: 2,
        descriptorSHA256: String(repeating: "2", count: 64),
        failureCode: "HERDR_TRANSACTION_FAILED",
        childProcess: nil
      ),
      JobCanaryGenerationRolloverLaunchEvidence(
        launchAttemptID: "launch-cli-q3",
        queueSequence: 3,
        descriptorSHA256: String(repeating: "3", count: 64),
        failureCode: "HERDR_TRANSACTION_FAILED",
        childProcess: nil
      ),
    ]
    let rollover = JobCanaryGenerationRolloverAuthorization(
      request: request,
      canaryAuthorizationSHA256: replacement.request.retry.recovery.canary.authorizationSHA256,
      rolloverEvidenceSHA256: String(repeating: "a", count: 64),
      isolationSHA256: String(repeating: "9", count: 64),
      repositoryID: UUID(uuidString: "76000000-0000-4000-8000-000000000076")!,
      jobID: replacement.request.retry.recovery.canary.scope.jobID,
      predecessorGeneration: 1,
      successorGeneration: 2,
      predecessorRunID: "run-generation-rollover-predecessor",
      predecessorLaunches: launches,
      hosts: hostPairs,
      workspaceID: "workspace-generation-rollover",
      socket: JobCanaryGenerationRolloverSocketEvidence(
        device: 1,
        inode: 2,
        owner: 501,
        permissions: 0o600,
        peerEvidenceSHA256: String(repeating: "f", count: 64)
      ),
      successorRunID: request.successorRunID
    )
    let q4 = JobCanaryGenerationRolloverQ4Authorization(
      rolloverAuthorizationSHA256: rollover.authorizationSHA256,
      q4EvidenceSHA256: String(repeating: "b", count: 64),
      successorRunID: request.successorRunID,
      plannedLaunchAttemptID: "launch-75000000-0000-4000-8000-000000000075",
      runNonce: String(repeating: "c", count: 64),
      requestSHA256: String(repeating: "d", count: 64),
      resourceVersion: "1",
      resourceHash: String(repeating: "e", count: 64),
      model: "fixture/model:off",
      sessionPath: "/tmp/jidoka-generation-rollover-session",
      channelPath: "/tmp/jidoka-generation-rollover-channel",
      q4Binding: JobCanaryRoleHostReplacementQ4Binding(
        descriptorSHA256: String(repeating: "1", count: 64),
        configurationSHA256: String(repeating: "2", count: 64),
        promptSHA256: String(repeating: "3", count: 64),
        workflowConfigurationSHA256: String(repeating: "4", count: 64),
        priorLaunchDescriptorSHA256: String(repeating: "5", count: 64),
        priorLaunchConfigurationSHA256: String(repeating: "6", count: 64),
        resourceTreeSHA256: String(repeating: "7", count: 64)
      )
    )
    let q4Request = JobCanaryGenerationRolloverQ4Request(
      rolloverAuthorization: rollover,
      plannedLaunchAttemptID: q4.plannedLaunchAttemptID
    )
    let q4Execution = JobCanaryGenerationRolloverQ4ExecutionAuthorization(
      rollover: rollover,
      q4: q4
    )
    try request.validate()
    try rollover.validate()
    try q4Request.validate()
    try q4Execution.validate()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func argument<T: Encodable>(_ value: T) throws -> String {
      try encoder.encode(value).base64EncodedString()
    }
    #expect(
      try JobCanaryCLI.parse(["preview-generation-rollover", argument(request)])
        == .previewJobCanaryGenerationRollover(request)
    )
    #expect(
      try JobCanaryCLI.parse(["execute-generation-rollover", argument(rollover)])
        == .executeJobCanaryGenerationRollover(rollover)
    )
    #expect(
      try JobCanaryCLI.parse(["preview-generation-rollover-q4", argument(q4Request)])
        == .previewJobCanaryGenerationRolloverQ4(q4Request)
    )
    #expect(
      try JobCanaryCLI.parse(["execute-generation-rollover-q4", argument(q4Execution)])
        == .executeJobCanaryGenerationRolloverQ4(q4Execution)
    )
    var noncanonical = try encoder.encode(request)
    noncanonical.append(0x20)
    #expect(throws: EngineClientError(.invalidCommand)) {
      _ = try JobCanaryCLI.parse([
        "preview-generation-rollover", noncanonical.base64EncodedString(),
      ])
    }
    #expect(throws: EngineClientError(.invalidCommand)) {
      _ = try JobCanaryCLI.parse(["execute-generation-rollover", "not-base64"])
    }
  }

  @Test(
    "application XPC and CLI JSON preserve every typed replacement outcome",
    arguments: ApplicationReplacementOutcomeCase.allCases
  )
  func replacementXPCAndCLIJSON(
    outcomeCase: ApplicationReplacementOutcomeCase
  ) throws {
    let authorization = applicationReplacementAuthorization()
    let command = EngineCommand.executeJobCanaryRoleHostReplacement(authorization)
    try command.validate()
    let request = EngineXPCRequest(
      requestID: "11111111-1111-4111-8111-111111111111",
      command: command
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let requestData = try encoder.encode(request)
    let decodedRequest = try JSONDecoder().decode(EngineXPCRequest.self, from: requestData)
    #expect(decodedRequest == request)
    try decodedRequest.validate()

    let replacement = try applicationReplacementReport(
      authorization: authorization,
      outcome: outcomeCase.outcome
    )
    let canary = applicationReplacementCanary(authorization: authorization)
    let checkpoint = EngineCheckpointReceipt(
      checkpointID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      completedAt: Date(timeIntervalSince1970: 2_000),
      nonterminalJobCount: 155,
      ambiguousMutationCount: 0,
      databaseCheckpointed: true
    )
    let report = JobCanaryCLIReport(
      action: EngineCommandKind.executeJobCanaryRoleHostReplacement.rawValue,
      canary: canary,
      recovery: nil,
      retry: nil,
      replacement: replacement,
      generationRollover: nil,
      generationRolloverQ4: nil,
      checkpoint: checkpoint
    )
    let reportData = try encoder.encode(report)
    let decoded = try JSONDecoder().decode(JobCanaryCLIReport.self, from: reportData)
    #expect(decoded.action == report.action)
    #expect(decoded.canary == canary)
    #expect(decoded.replacement == replacement)
    #expect(decoded.checkpoint == checkpoint)
    #expect(try encoder.encode(decoded) == reportData)
    let json = String(decoding: reportData, as: UTF8.self)
    #expect(json.contains("\"status\":\"\(replacement.status.rawValue)\""))
    #expect(json.contains("\"effectCertainty\":\"\(replacement.effectCertainty.rawValue)\""))
    #expect(!json.localizedCaseInsensitiveContains("credential"))
    #expect(!json.contains(String(repeating: "a", count: 32)))
    #expect(!json.contains(String(repeating: "b", count: 32)))

    let projectRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let clientSource = try String(
      contentsOf: projectRoot.appendingPathComponent(
        "Sources/JidokaCodeApp/ApplicationEngineClient.swift"
      ),
      encoding: .utf8
    )
    #expect(clientSource.contains("try request.validate()"))
    #expect(clientSource.contains("let requestData = try encoder.encode(request)"))
    #expect(clientSource.contains("JSONDecoder().decode(EngineXPCResponse.self"))
    #expect(clientSource.contains("box.finish(.success(try response.validate(for: request)))"))
  }

  @Test("canary CLI keeps the pane-inspection preview on the bounded long timeout")
  func canaryCLITimeouts() {
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .previewJobCanaryPiRetry) == 3_500)
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .executeJobCanary) == 3_500)
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .executeJobCanaryRecovery) == 3_500)
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .executeJobCanaryPiRetry) == 3_500)
    #expect(
      JobCanaryCLI.responseTimeoutSeconds(for: .previewJobCanaryRoleHostReplacement)
        == 3_500
    )
    #expect(
      JobCanaryCLI.responseTimeoutSeconds(for: .executeJobCanaryRoleHostReplacement)
        == 3_500
    )
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .previewJobCanary) == 30)
    #expect(JobCanaryCLI.responseTimeoutSeconds(for: .previewJobCanaryRecovery) == 30)
  }

  @Test(
    "first onboarding checkpoints bootstrap before registration and helper handoff",
    arguments: [LifecycleServiceStatus.notRegistered, .notFound]
  )
  func enableAndComplete(initialStatus: LifecycleServiceStatus) async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: initialStatus,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let preparer = BackgroundCredentialAccessPreparerFake(events: events)
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      backgroundCredentialAccess: preparer,
      bootstrapFactory: { await factory.make() }
    )

    _ = try await client.send(.snapshot)
    let enabled = try await client.send(.setLoginEnabled(true))
    #expect(enabled.state.settings.loginItemStatus == .enabled)
    #expect(enabled.state.settings.loginItemSelected)
    #expect(enabled.state.settings.repositories.isEmpty)
    let completed = try await client.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)

    let values = await events.values
    try expectOrder(
      values,
      [
        "credential-access:prepare",
        "bootstrap-1:prepareForHandoff",
        "bootstrap-1:close",
        "login:register",
        "helper:snapshot",
        "helper:synchronizeLoginStatus",
        "helper:completeOnboarding",
      ]
    )
    #expect(await factory.count == 1)
  }

  @Test("an enabled helper verifies the credential ACL once per UI process")
  func enabledHelperPreparesCredentialAccess() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events
    )
    let preparer = BackgroundCredentialAccessPreparerFake(events: events)
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      backgroundCredentialAccess: preparer,
      bootstrapFactory: { await factory.make() }
    )

    _ = try await client.send(.snapshot)
    _ = try await client.send(.snapshot)
    _ = try await client.send(.snapshot)

    #expect(await preparer.count == 1)
    #expect(await factory.count == 0)
    #expect(
      await events.values == [
        "credential-access:prepare",
        "helper:snapshot",
        "helper:snapshot",
        "helper:snapshot",
      ])
  }

  @Test("an interactive command waits for the active automatic snapshot")
  func interactiveCommandWaitsForSnapshot() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let snapshotGate = EngineCommandSuspension()
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events,
      suspendedKind: .snapshot,
      suspension: snapshotGate
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    let snapshot = Task { try await client.send(.snapshot) }
    await snapshotGate.waitUntilStarted()
    let result = CommandResultProbe()
    let addRepository = Task {
      do {
        let response = try await client.send(
          .addRepository(
            EngineRepositoryDraft(
              owner: "fixture",
              name: "sandbox",
              reviewEnabled: false,
              triageEnabled: false,
              implementationEnabled: false
            )
          )
        )
        await result.succeed(response.command)
      } catch {
        await result.fail(error)
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await result.isPending)
    await snapshotGate.release()
    _ = try await snapshot.value
    await addRepository.value

    #expect(await result.command == .addRepository)
    #expect(await result.error == nil)
    try expectOrder(
      await events.values,
      [
        "helper:snapshot",
        "helper:addRepository",
      ]
    )
  }

  @Test("two mutating commands remain fail-closed")
  func mutatingCommandsRemainExclusive() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let mutationGate = EngineCommandSuspension()
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events,
      suspendedKind: .addRepository,
      suspension: mutationGate
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )
    let addRepository = Task {
      try await client.send(
        .addRepository(
          EngineRepositoryDraft(
            owner: "fixture",
            name: "sandbox",
            reviewEnabled: false,
            triageEnabled: false,
            implementationEnabled: false
          )
        )
      )
    }
    await mutationGate.waitUntilStarted()

    await #expect(throws: EngineClientError(.busy)) {
      _ = try await client.send(.setMaxConcurrency(3))
    }
    await mutationGate.release()
    _ = try await addRepository.value
  }

  @Test("credential ACL migration failure never reaches the helper")
  func credentialAccessFailureIsClosed() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events
    )
    let preparer = BackgroundCredentialAccessPreparerFake(
      events: events,
      shouldFail: true
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      backgroundCredentialAccess: preparer,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.credentialAccessFailed)) {
      _ = try await client.send(.snapshot)
    }
    await #expect(throws: EngineClientError(.credentialAccessFailed)) {
      _ = try await client.send(.snapshot)
    }
    #expect(await preparer.count == 1)
    #expect(await events.values == ["credential-access:prepare"])
    #expect(await factory.count == 0)

    let disabled = try await client.send(.setLoginEnabled(false))
    #expect(!disabled.state.settings.loginItemSelected)
    #expect(disabled.state.settings.loginItemStatus == .notRegistered)
    try expectOrder(
      await events.values,
      [
        "credential-access:prepare",
        "helper:prepareForQuit",
        "login:unregister",
        "bootstrap-1:synchronizeLoginStatus",
      ]
    )
  }

  @Test("the production retry policy tolerates a slow helper and pins its exact bound")
  func helperStartupRetry() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events,
      unavailableAttempts: [.snapshot: 100]
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      helperStartupWait: { nanoseconds in
        await events.append("helper:wait:\(nanoseconds)")
      },
      bootstrapFactory: { await factory.make() }
    )

    let enabled = try await client.send(.setLoginEnabled(true))
    #expect(enabled.state.settings.loginItemSelected)
    #expect(enabled.state.settings.loginItemStatus == .enabled)
    #expect(ProductionEngineClient.productionHelperStartupAttemptLimit == 240)
    #expect(ProductionEngineClient.productionHelperStartupRetryNanoseconds == 250_000_000)
    let values = await events.values
    #expect(values.filter { $0 == "helper:snapshot" }.count == 101)
    #expect(
      values.filter {
        $0
          == "helper:wait:\(ProductionEngineClient.productionHelperStartupRetryNanoseconds)"
      }.count == 100
    )
    try expectOrder(values, ["login:register", "helper:synchronizeLoginStatus"])
  }

  @Test("helper startup does not retry a typed non-availability failure")
  func helperStartupTypedFailure() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events,
      failingCodes: [.snapshot: .timedOut]
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      helperStartupWait: { nanoseconds in
        await events.append("helper:wait:\(nanoseconds)")
      },
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    let values = await events.values
    #expect(values.filter { $0 == "helper:snapshot" }.count == 1)
    #expect(!values.contains(where: { $0.hasPrefix("helper:wait:") }))
  }

  @Test("a successful credential replacement avoids a second ACL prompt during handoff")
  func credentialReplacementCarriesPreparedAccessIntoHandoff() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let preparer = BackgroundCredentialAccessPreparerFake(events: events)
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      backgroundCredentialAccess: preparer,
      bootstrapFactory: { await factory.make() }
    )

    _ = try await client.send(
      .replaceCredential(Data(String(repeating: "t", count: 32).utf8))
    )
    _ = try await client.send(.setLoginEnabled(true))

    #expect(await preparer.count == 0)
    #expect(!(await events.values).contains("credential-access:prepare"))
  }

  @Test("credential deletion rechecks background access before the next helper request")
  func credentialDeletionResetsPreparedAccess() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events
    )
    let preparer = BackgroundCredentialAccessPreparerFake(events: events)
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      backgroundCredentialAccess: preparer,
      bootstrapFactory: { await factory.make() }
    )

    _ = try await client.send(
      .replaceCredential(Data(String(repeating: "t", count: 32).utf8))
    )
    _ = try await client.send(.deleteCredential)
    _ = try await client.send(.snapshot)

    #expect(await preparer.count == 1)
    try expectOrder(
      await events.values,
      [
        "helper:replaceCredential",
        "helper:deleteCredential",
        "credential-access:prepare",
        "helper:snapshot",
      ]
    )
  }

  @Test("an unregistered agent missing from BTM uses bootstrap and can quit durably")
  func notFoundUsesBootstrap() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notFound,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    let snapshot = try await client.send(.snapshot)
    #expect(snapshot.state.settings.loginItemStatus == .notFound)
    #expect(!snapshot.state.settings.loginItemSelected)
    let quitting = try await client.send(.prepareForQuit)
    #expect(quitting.checkpoint?.databaseCheckpointed == true)
    #expect(await factory.count == 1)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
    try expectOrder(
      await events.values,
      [
        "bootstrap-1:created",
        "bootstrap-1:snapshot",
        "bootstrap-1:synchronizeLoginStatus",
        "bootstrap-1:prepareForQuit",
      ]
    )
  }

  @Test("a cold agent missing from BTM can quit durably before any snapshot")
  func notFoundColdQuitUsesBootstrap() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notFound,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    let quitting = try await client.send(.prepareForQuit)
    #expect(quitting.checkpoint?.databaseCheckpointed == true)
    #expect(await factory.count == 1)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
    #expect(await events.values == ["bootstrap-1:created", "bootstrap-1:prepareForQuit"])
  }

  @Test("requires approval remains on the bootstrap control plane without starting jobs")
  func requiresApproval() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .requiresApproval,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    let enabled = try await client.send(.setLoginEnabled(true))
    #expect(enabled.state.settings.loginItemStatus == .requiresApproval)
    let completed = try await client.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)
    #expect(completed.state.operationalStatus == .warning)
    #expect(await factory.count == 2)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
  }

  @Test("disabling login checkpoints the helper before unregistering")
  func disableCheckpointsFirst() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      engineLockFactory: {
        await events.append("engine-lock:acquired")
        return TestEngineTopologyLock()
      },
      bootstrapFactory: { await factory.make() }
    )

    let response = try await client.send(.setLoginEnabled(false))
    #expect(!response.state.settings.loginItemSelected)
    #expect(response.state.settings.loginItemStatus == .notRegistered)
    try expectOrder(
      await events.values,
      [
        "helper:prepareForQuit",
        "engine-lock:acquired",
        "login:unregister",
        "bootstrap-1:created",
        "bootstrap-1:synchronizeLoginStatus",
      ]
    )
  }

  @Test("topology changes require an explicit durable checkpoint receipt")
  func checkpointReceiptRequired() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events,
      checkpointSucceeds: false
    )
    let factory = BootstrapFactory(
      events: events,
      onboardingReady: true,
      checkpointSucceeds: false
    )
    let enabling = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )
    await #expect(throws: EngineClientError(.checkpointFailed)) {
      _ = try await enabling.send(.setLoginEnabled(true))
    }
    #expect(!(await events.values).contains("login:register"))
    #expect(!(await events.values).contains("bootstrap-1:close"))

    let enabledLogin = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let disabling = ProductionEngineClient(
      loginItems: enabledLogin,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )
    await #expect(throws: EngineClientError(.checkpointFailed)) {
      _ = try await disabling.send(.setLoginEnabled(false))
    }
    #expect(!(await events.values).contains("login:unregister"))
  }

  @Test("ambiguous helper startup failure preserves registered recovery authority")
  func postRegistrationStartupFailureRemainsRegistered() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events,
      failingKinds: [.snapshot]
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      helperStartupWait: { nanoseconds in
        await events.append("helper:wait:\(nanoseconds)")
      },
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    let values = await events.values
    #expect(
      values.filter { $0 == "helper:snapshot" }.count
        == ProductionEngineClient.productionHelperStartupAttemptLimit
    )
    #expect(
      values.filter {
        $0
          == "helper:wait:\(ProductionEngineClient.productionHelperStartupRetryNanoseconds)"
      }.count == ProductionEngineClient.productionHelperStartupAttemptLimit - 1
    )
    try expectOrder(values, ["login:register", "helper:snapshot"])
    #expect(!(await events.values).contains("helper:prepareForQuit"))
    #expect(!(await events.values).contains("login:unregister"))
    #expect(await factory.count == 1)
  }

  @Test("post-registration control-plane failure checkpoints before rollback")
  func postRegistrationControlPlaneFailureRollsBack() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events,
      failingKinds: [.synchronizeLoginStatus]
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    try expectOrder(
      await events.values,
      [
        "login:register",
        "helper:snapshot",
        "helper:synchronizeLoginStatus",
        "helper:prepareForQuit",
        "login:unregister",
      ]
    )
    #expect(await factory.count == 2)
  }

  @Test("registration failure reopens bootstrap and returns a redacted code")
  func registrationFailure() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events,
      failRegistration: true
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    #expect(await factory.count == 2)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
  }

  @Test("every application termination path shares one durable checkpoint gate")
  @MainActor
  func durableTerminationGate() async throws {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var duplicateCompletions: [Bool] = []
    let first = gate.request(
      checkpoint: { await probe.checkpoint() },
      completion: { probe.complete($0) }
    )
    let duplicate = gate.request(
      checkpoint: {
        Issue.record("a duplicate termination request started another checkpoint")
        return false
      },
      completion: { duplicateCompletions.append($0) }
    )
    #expect(first == .terminateLater)
    #expect(duplicate == .terminateLater)
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    #expect(probe.callCount == 1)
    #expect(probe.continuation != nil)
    probe.resume(true)
    for _ in 0..<100 where duplicateCompletions.isEmpty { await Task.yield() }
    #expect(probe.completions == [true])
    #expect(duplicateCompletions == [true])
    #expect(
      gate.request(checkpoint: { false }, completion: { _ in }) == .terminateNow
    )
  }

  @Test("a notification checkpoint completes before synchronous termination")
  @MainActor
  func preparedTerminationGate() async {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var events: [String] = []
    gate.prepareAndRequestTermination(
      checkpoint: {
        events.append("checkpoint-start")
        let result = await probe.checkpoint()
        events.append("checkpoint-end")
        return result
      },
      requestTermination: { events.append("terminate") }
    )
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    #expect(events == ["checkpoint-start"])
    probe.resume(true)
    for _ in 0..<100 where events.count < 3 { await Task.yield() }
    #expect(events == ["checkpoint-start", "checkpoint-end", "terminate"])
    #expect(gate.request(checkpoint: { false }, completion: { _ in }) == .terminateNow)
  }

  @Test("a failed notification checkpoint resolves a concurrent AppKit quit")
  @MainActor
  func failedPreparedTerminationResolvesConcurrentRequest() async {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var requestCompletions: [Bool] = []
    var terminationRequests = 0
    gate.prepareAndRequestTermination(
      checkpoint: { await probe.checkpoint() },
      requestTermination: { terminationRequests += 1 }
    )
    let reply = gate.request(
      checkpoint: {
        Issue.record("a concurrent AppKit quit started another checkpoint")
        return true
      },
      completion: { requestCompletions.append($0) }
    )
    #expect(reply == .terminateLater)
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    probe.resume(false)
    for _ in 0..<100 where requestCompletions.isEmpty { await Task.yield() }
    #expect(requestCompletions == [false])
    #expect(terminationRequests == 0)
  }

  @Test("incomplete bootstrap never attempts registration")
  func incompleteBootstrap() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: false)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.onboardingIncomplete)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    #expect(!(await events.values).contains("login:register"))
  }

  private func expectOrder(_ values: [String], _ expected: [String]) throws {
    var position = values.startIndex
    for item in expected {
      let index = try #require(values[position...].firstIndex(of: item))
      position = values.index(after: index)
    }
  }
}

enum ApplicationReplacementOutcomeCase: CaseIterable, Sendable {
  case noRemoteEffectFailure
  case remoteEffectAmbiguous
  case q4Prepared
  case q4Enqueued
  case q4OutcomeAmbiguous
  case q4Failed
  case q4Settled
  case replacementHostLost

  var outcome: JobCanaryRoleHostReplacementOutcome {
    switch self {
    case .noRemoteEffectFailure:
      .noRemoteEffectFailure(failureCode: "INVALID_PREPARATION")
    case .remoteEffectAmbiguous: .remoteEffectAmbiguous
    case .q4Prepared: .q4Prepared
    case .q4Enqueued: .q4Enqueued
    case .q4OutcomeAmbiguous:
      .q4OutcomeAmbiguous(failureCode: "RUNTIME_INTERRUPTED")
    case .q4Failed: .q4Failed(failureCode: "CHILD_FAILED")
    case .q4Settled: .q4Settled
    case .replacementHostLost: .replacementHostLost
    }
  }
}

private func applicationReplacementAuthorization()
  -> JobCanaryRoleHostReplacementAuthorization
{
  let canary = JobCanaryAuthorization(
    scope: JobCanaryScope(
      jobID: UUID(uuidString: "aaaaaaaa-1111-4111-8111-111111111111")!,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "c", count: 64),
      maximumCommentParts: 8
    ),
    previewEvidenceSHA256: String(repeating: "d", count: 64)
  )
  let request = JobCanaryRoleHostReplacementRequest(
    retry: JobCanaryPiRetryAuthorization(
      recovery: JobCanaryRecoveryAuthorization(
        canary: canary,
        recoveryEvidenceSHA256: String(repeating: "e", count: 64)
      ),
      retryEvidenceSHA256: String(repeating: "f", count: 64)
    ),
    incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
    plannedReplacementRoleHostID: "rolehost-11111111-1111-4111-8111-111111111111",
    plannedLaunchAttemptID: "launch-22222222-2222-4222-8222-222222222222"
  )
  return JobCanaryRoleHostReplacementAuthorization(
    request: request,
    replacementEvidenceSHA256: String(repeating: "9", count: 64),
    q4Binding: JobCanaryRoleHostReplacementQ4Binding(
      descriptorSHA256: String(repeating: "1", count: 64),
      configurationSHA256: String(repeating: "2", count: 64),
      promptSHA256: String(repeating: "3", count: 64),
      workflowConfigurationSHA256: String(repeating: "4", count: 64),
      priorLaunchDescriptorSHA256: String(repeating: "5", count: 64),
      priorLaunchConfigurationSHA256: String(repeating: "6", count: 64),
      resourceTreeSHA256: String(repeating: "7", count: 64)
    )
  )
}

private func applicationReplacementCanary(
  authorization: JobCanaryRoleHostReplacementAuthorization
) -> JobCanaryReport {
  JobCanaryReport(
    scope: authorization.request.retry.recovery.canary.scope,
    previewEvidenceSHA256:
      authorization.request.retry.recovery.canary.previewEvidenceSHA256,
    authorizationSHA256:
      authorization.request.retry.recovery.canary.authorizationSHA256,
    status: .recoveryRequired,
    repositoryOwner: "fixture",
    repositoryName: "replacement",
    objectNumber: 42,
    revisionKey: String(repeating: "8", count: 40),
    provider: "fixture",
    model: "fixture",
    thinking: "off",
    resourceTreeSHA256: authorization.q4Binding.resourceTreeSHA256,
    replayed: false
  )
}

private func applicationReplacementReport(
  authorization: JobCanaryRoleHostReplacementAuthorization,
  outcome: JobCanaryRoleHostReplacementOutcome
) throws -> JobCanaryRoleHostReplacementReport {
  try JobCanaryRoleHostReplacementReport(
    jobID: authorization.request.retry.recovery.canary.scope.jobID,
    runID: "run-33333333-3333-4333-8333-333333333333",
    predecessorRoleHostID: "rolehost-44444444-4444-4444-8444-444444444444",
    replacementRoleHostID: authorization.request.plannedReplacementRoleHostID,
    plannedLaunchAttemptID: authorization.request.plannedLaunchAttemptID,
    incidentAuditSHA256: authorization.request.incidentAuditSHA256,
    replacementEvidenceSHA256: authorization.replacementEvidenceSHA256,
    replacementAuthorizationSHA256: authorization.authorizationSHA256,
    q4Binding: authorization.q4Binding,
    outcome: outcome,
    replayed: false
  )
}

@MainActor
private final class TerminationCheckpointProbe {
  var callCount = 0
  var completions: [Bool] = []
  var continuation: CheckedContinuation<Bool, Never>?

  func checkpoint() async -> Bool {
    callCount += 1
    return await withCheckedContinuation { continuation = $0 }
  }

  func resume(_ value: Bool) {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }

  func complete(_ value: Bool) {
    completions.append(value)
  }
}

private final class TestEngineTopologyLock: EngineTopologyLocking, @unchecked Sendable {
  func release() {}
}

private actor TopologyEventLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor BackgroundCredentialAccessPreparerFake: BackgroundCredentialAccessPreparing {
  private let events: TopologyEventLog
  private let shouldFail: Bool
  private let onPrepare: @Sendable () -> Void
  private(set) var count = 0

  init(
    events: TopologyEventLog,
    shouldFail: Bool = false,
    onPrepare: @escaping @Sendable () -> Void = {}
  ) {
    self.events = events
    self.shouldFail = shouldFail
    self.onPrepare = onPrepare
  }

  func prepare() async throws {
    count += 1
    onPrepare()
    await events.append("credential-access:prepare")
    if shouldFail { throw GitHubTokenStoreError.invalidAccessPolicy }
  }
}

private actor LoginItemControllerFake: LoginItemControlling {
  private var current: LifecycleServiceStatus
  private let registeredStatus: LifecycleServiceStatus
  private let events: TopologyEventLog
  private let failRegistration: Bool

  init(
    status: LifecycleServiceStatus,
    registeredStatus: LifecycleServiceStatus,
    events: TopologyEventLog,
    failRegistration: Bool = false
  ) {
    current = status
    self.registeredStatus = registeredStatus
    self.events = events
    self.failRegistration = failRegistration
  }

  func status() -> LifecycleServiceStatus {
    current
  }

  func register() async throws {
    await events.append("login:register")
    if failRegistration { throw EngineClientError(.loginItemFailed) }
    current = registeredStatus
  }

  func unregister() async {
    await events.append("login:unregister")
    current = .notRegistered
  }
}

private actor EngineCommandSuspension {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func suspend() async {
    if released { return }
    started = true
    let waiters = startWaiters
    startWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { releaseContinuation = $0 }
  }

  func release() {
    released = true
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }
}

private actor CommandResultProbe {
  private(set) var command: EngineCommandKind?
  private(set) var error: EngineClientErrorCode?
  private(set) var isPending = true

  func succeed(_ command: EngineCommandKind) {
    self.command = command
    isPending = false
  }

  func fail(_ error: Error) {
    self.error = (error as? EngineClientError)?.code ?? .internalFailure
    isPending = false
  }
}

private actor TopologyEngineClientFake: EngineClient {
  private let name: String
  private let onboardingReady: Bool
  private let events: TopologyEventLog
  private let checkpointSucceeds: Bool
  private let failingKinds: Set<EngineCommandKind>
  private let failingCodes: [EngineCommandKind: EngineClientErrorCode]
  private let suspendedKind: EngineCommandKind?
  private let suspension: EngineCommandSuspension?
  private var unavailableAttempts: [EngineCommandKind: Int]
  private var lifecycle = EngineLifecycleState.onboarding
  private var loginSelected: Bool
  private var loginStatus: LifecycleServiceStatus

  init(
    name: String,
    onboardingReady: Bool,
    loginSelected: Bool,
    loginStatus: LifecycleServiceStatus,
    events: TopologyEventLog,
    checkpointSucceeds: Bool = true,
    failingKinds: Set<EngineCommandKind> = [],
    unavailableAttempts: [EngineCommandKind: Int] = [:],
    failingCodes: [EngineCommandKind: EngineClientErrorCode] = [:],
    suspendedKind: EngineCommandKind? = nil,
    suspension: EngineCommandSuspension? = nil
  ) {
    self.name = name
    self.onboardingReady = onboardingReady
    self.loginSelected = loginSelected
    self.loginStatus = loginStatus
    self.events = events
    self.checkpointSucceeds = checkpointSucceeds
    self.failingKinds = failingKinds
    self.unavailableAttempts = unavailableAttempts
    self.failingCodes = failingCodes
    self.suspendedKind = suspendedKind
    self.suspension = suspension
  }

  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    await events.append("\(name):\(command.kind.rawValue)")
    if command.kind == suspendedKind, let suspension {
      await suspension.suspend()
    }
    if let remaining = unavailableAttempts[command.kind], remaining > 0 {
      unavailableAttempts[command.kind] = remaining - 1
      throw EngineClientError(.unavailable)
    }
    if let code = failingCodes[command.kind] {
      throw EngineClientError(code)
    }
    if failingKinds.contains(command.kind) {
      throw EngineClientError(.unavailable)
    }
    var checkpoint: EngineCheckpointReceipt?
    switch command {
    case .synchronizeLoginStatus(let selected, let status):
      loginSelected = selected
      loginStatus = status
    case .completeOnboarding:
      lifecycle = .ready
    case .prepareForHandoff, .prepareForQuit:
      if checkpointSucceeds {
        checkpoint = EngineCheckpointReceipt(
          checkpointID: UUID(),
          completedAt: Date(timeIntervalSince1970: 600_000),
          nonterminalJobCount: 0,
          ambiguousMutationCount: 0,
          databaseCheckpointed: true
        )
      }
    default:
      break
    }
    return EngineCommandResponse(
      command: command.kind,
      state: state(),
      checkpoint: checkpoint
    )
  }

  private func state() -> EngineUIState {
    let credential =
      onboardingReady
      ? EngineCredentialStatus(state: .valid, account: "octocat") : .missing
    let pi =
      onboardingReady
      ? EnginePiStatus(
        state: .ready,
        executablePath: "/opt/homebrew/bin/pi",
        version: "0.84.1",
        policySHA256: String(repeating: "f", count: 64)
      ) : .unchecked
    let herdr =
      onboardingReady
      ? EngineHerdrStatus(
        state: .ready,
        version: "0.8.2",
        protocolVersion: 20,
        executableSHA256: String(repeating: "e", count: 64),
        schemaSHA256: String(repeating: "d", count: 64),
        policySHA256: String(repeating: "c", count: 64)
      ) : .unchecked
    let profiles = ModelProfileRole.allCases.map {
      ModelProfileConfiguration(
        role: $0,
        provider: "openai-codex",
        model: "gpt-5.6-sol",
        thinking: .max
      )
    }
    let repositories: [RepositoryConfiguration] = []
    let onboarding = EngineOnboardingSnapshot(
      duplicateInstanceCheckPassed: true,
      externalAutomationAcknowledged: onboardingReady,
      providerDisclosureAcknowledged: onboardingReady,
      pi: pi,
      herdr: herdr,
      credential: credential,
      repositoryCount: repositories.count,
      configuredProfileRoles: profiles.map(\.role),
      loginItemSelected: loginSelected,
      loginItemStatus: loginStatus,
      complete: lifecycle == .ready
    )
    return EngineUIState(
      revision: 1,
      lifecycle: lifecycle,
      operationalStatus: lifecycle == .ready && loginStatus != .enabled ? .warning : .active,
      paused: false,
      passRunning: false,
      activities: [],
      ambiguousMutations: [],
      onboarding: onboarding,
      settings: EngineSettingsSnapshot(
        repositories: repositories,
        profiles: profiles,
        maxConcurrency: 2,
        loginItemSelected: loginSelected,
        loginItemStatus: loginStatus,
        credential: credential,
        herdr: herdr
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
}

private final class TopologyBootstrapContainer: BootstrapEngineContaining, @unchecked Sendable {
  let client: any EngineClient
  private let name: String
  private let events: TopologyEventLog

  init(client: any EngineClient, name: String, events: TopologyEventLog) {
    self.client = client
    self.name = name
    self.events = events
  }

  func close() async {
    await events.append("\(name):close")
  }
}

private actor BootstrapFactory {
  private let events: TopologyEventLog
  private let onboardingReady: Bool
  private let checkpointSucceeds: Bool
  private(set) var count = 0

  init(
    events: TopologyEventLog,
    onboardingReady: Bool,
    checkpointSucceeds: Bool = true
  ) {
    self.events = events
    self.onboardingReady = onboardingReady
    self.checkpointSucceeds = checkpointSucceeds
  }

  func make() async -> any BootstrapEngineContaining {
    count += 1
    let name = "bootstrap-\(count)"
    await events.append("\(name):created")
    return TopologyBootstrapContainer(
      client: TopologyEngineClientFake(
        name: name,
        onboardingReady: onboardingReady,
        loginSelected: false,
        loginStatus: .notRegistered,
        events: events,
        checkpointSucceeds: checkpointSucceeds
      ),
      name: name,
      events: events
    )
  }
}
