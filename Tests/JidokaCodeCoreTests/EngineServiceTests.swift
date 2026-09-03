import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Application engine service")
struct EngineServiceTests {
  @Test("typed startup failure preserves its phase and non-fallback error code")
  func typedStartupFailureIsRedacted() async throws {
    let logger = EngineServiceLogFake()
    let fixture = try await EngineServiceFixture(initialize: false, logger: logger)
    defer { fixture.remove() }
    await fixture.runtime.setReloadFailure(.client(EngineClientError(.piBlocked)))

    await #expect(throws: EngineClientError(.piBlocked)) {
      try await fixture.service.initialize()
    }
    let records = await logger.records
    #expect(
      records.filter({ $0.event == .startupPhase }).compactMap(\.phase)
        == [.credentialStatus, .piPreflight, .herdrPreflight, .dispatchGate, .runtimeReload]
    )
    #expect(
      records.last
        == EngineLogRecord(
          timestamp: fixture.now,
          event: .startupFailed,
          phase: .runtimeReload,
          command: nil,
          error: .piBlocked
        )
    )
    await fixture.database.close()
  }

  @Test("unknown startup failure cannot expand private data into the real log")
  func unknownStartupFailureIsRedacted() async throws {
    let root = startupRoot()
    let logger = try EngineRedactedLogger(
      rootURL: root.appendingPathComponent("Logs", isDirectory: true),
      filename: "engine.jsonl"
    )
    let fixture = try await EngineServiceFixture(
      rootURL: root,
      initialize: false,
      logger: logger
    )
    defer { fixture.remove() }
    let sentinels = [
      "github_pat_startup_private_value",
      "private-owner/private-repository",
      "/private/startup/secret/path",
      "provider-output-private-value",
      "underlying-error-private-description",
    ]
    let failure = EngineServiceUnknownStartupError(description: sentinels.joined(separator: "|"))
    await fixture.external.setCredentialStatus(
      EngineCredentialStatus(state: .valid, account: sentinels[0]))
    await fixture.runtime.setReloadFailure(.unknown(failure))

    do {
      try await fixture.service.initialize()
      Issue.record("unknown startup failure unexpectedly succeeded")
    } catch let caught as EngineServiceUnknownStartupError {
      #expect(caught == failure)
    } catch {
      Issue.record("unknown startup failure changed type")
    }

    let data = try Data(contentsOf: logger.fileURL)
    for sentinel in sentinels {
      #expect(!data.contains(Data(sentinel.utf8)))
    }
    let lastLine = try #require(data.split(separator: 0x0A).last)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(lastLine)) as? [String: Any])
    #expect(Set(object.keys) == ["error", "event", "phase", "timestamp"])
    #expect(object["event"] as? String == EngineLogEventCode.startupFailed.rawValue)
    #expect(object["phase"] as? String == EngineStartupPhase.runtimeReload.rawValue)
    #expect(object["error"] as? String == EngineClientErrorCode.internalFailure.rawValue)
    await fixture.database.close()
  }

  @Test("successful startup records its complete ordered tail")
  func successfulStartupPhaseOrder() async throws {
    let logger = EngineServiceLogFake()
    let fixture = try await EngineServiceFixture(initialize: false, logger: logger)
    defer { fixture.remove() }

    try await fixture.service.initialize()

    let records = await logger.records
    #expect(
      records.filter({ $0.event == .startupPhase }).compactMap(\.phase)
        == [
          .credentialStatus, .piPreflight, .herdrPreflight, .dispatchGate, .runtimeReload,
          .pausedState,
        ]
    )
    #expect(records.last?.event == .initialized)
    #expect(records.last?.phase == nil)
    await fixture.database.close()
  }

  @Test("database failures are attributed before and after runtime reload")
  func databaseStartupFailurePhases() async throws {
    let dispatchLogger = EngineServiceLogFake()
    let dispatchFixture = try await EngineServiceFixture(
      initialize: false,
      logger: dispatchLogger
    )
    defer { dispatchFixture.remove() }
    await dispatchFixture.database.close()
    do {
      try await dispatchFixture.service.initialize()
      Issue.record("closed dispatch database unexpectedly initialized")
    } catch {}
    #expect(await dispatchLogger.records.last?.event == .startupFailed)
    #expect(await dispatchLogger.records.last?.phase == .dispatchGate)
    #expect(await dispatchLogger.records.last?.error == .internalFailure)

    let pausedLogger = EngineServiceLogFake()
    let pausedFixture = try await EngineServiceFixture(initialize: false, logger: pausedLogger)
    defer { pausedFixture.remove() }
    await pausedFixture.runtime.closeDatabaseOnReload(pausedFixture.database)
    do {
      try await pausedFixture.service.initialize()
      Issue.record("closed paused-state database unexpectedly initialized")
    } catch {}
    #expect(await pausedLogger.records.last?.event == .startupFailed)
    #expect(await pausedLogger.records.last?.phase == .pausedState)
    #expect(await pausedLogger.records.last?.error == .internalFailure)
  }

  @Test("an unavailable real log sink cannot change startup authority")
  func loggerFailureIsNonAuthoritative() async throws {
    let successRoot = startupRoot()
    let successLogger = try EngineRedactedLogger(
      rootURL: successRoot.appendingPathComponent("Logs", isDirectory: true),
      filename: "engine.jsonl"
    )
    try FileManager.default.linkItem(
      at: successLogger.fileURL,
      to: successRoot.appendingPathComponent("linked-success.jsonl")
    )
    let successFixture = try await EngineServiceFixture(
      rootURL: successRoot,
      initialize: false,
      logger: successLogger
    )
    defer { successFixture.remove() }
    try await successFixture.service.initialize()
    #expect(await successFixture.runtime.reloadValues == [false])
    #expect(await successFixture.runtime.pauseValues == [false])
    #expect(try Data(contentsOf: successLogger.fileURL).isEmpty)
    await successFixture.database.close()

    let failureRoot = startupRoot()
    let failureLogger = try EngineRedactedLogger(
      rootURL: failureRoot.appendingPathComponent("Logs", isDirectory: true),
      filename: "engine.jsonl"
    )
    try FileManager.default.linkItem(
      at: failureLogger.fileURL,
      to: failureRoot.appendingPathComponent("linked-failure.jsonl")
    )
    let failureFixture = try await EngineServiceFixture(
      rootURL: failureRoot,
      initialize: false,
      logger: failureLogger
    )
    defer { failureFixture.remove() }
    await failureFixture.runtime.setReloadFailure(.client(EngineClientError(.piBlocked)))
    await #expect(throws: EngineClientError(.piBlocked)) {
      try await failureFixture.service.initialize()
    }
    #expect(try Data(contentsOf: failureLogger.fileURL).isEmpty)
    await failureFixture.database.close()
  }

  private func startupRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-engine-startup-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("onboarding persists exact prerequisites and never persists token bytes")
  func onboardingAndSecretBoundary() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let initial = try await fixture.service.snapshot()
    #expect(initial.lifecycle == .onboarding)
    #expect(Set(initial.settings.profiles.map(\.role)) == Set(ModelProfileRole.allCases))
    #expect(initial.settings.maxConcurrency == 2)
    #expect(initial.settings.modelCatalog.models.isEmpty)
    #expect(initial.onboarding.herdr.state == .ready)

    _ = try await fixture.service.send(.acknowledgeExternalAutomation(true))
    _ = try await fixture.service.send(.acknowledgeProviderDisclosure(true))
    let sentinel = "github_pat_" + String(repeating: "w7-secret", count: 5)
    _ = try await fixture.service.send(.replaceCredential(Data(sentinel.utf8)))
    _ = try await fixture.service.send(
      .addRepository(
        EngineRepositoryDraft(
          owner: "owner",
          name: "repo",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true
        )
      )
    )
    _ = try await fixture.service.send(
      .synchronizeLoginStatus(selected: true, status: .enabled)
    )
    let completed = try await fixture.service.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)
    #expect(completed.state.onboarding.complete)
    #expect(completed.state.onboarding.credential.account == "octocat")
    #expect(completed.state.settings.repositories.count == 1)
    #expect(await fixture.external.sawCredential)
    #expect(await fixture.runtime.dispatchValues.last == true)

    let persisted = try await fixture.configuration.appConfiguration()
    #expect(persisted.onboardingComplete)
    #expect(persisted.externalAutomationAcknowledged)
    #expect(persisted.providerDisclosureAcknowledged)
    #expect(persisted.loginItemSelected)
    #expect(persisted.loginItemStatus == .enabled)

    _ = try await fixture.database.checkpoint()
    let forbidden = Data(sentinel.utf8)
    for url in [
      fixture.database.databaseURL,
      URL(fileURLWithPath: fixture.database.databaseURL.path + "-wal"),
      URL(fileURLWithPath: fixture.database.databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      let bytes = try Data(contentsOf: url)
      #expect(!bytes.contains(forbidden))
    }
  }

  @Test("setup completes without a repository and resumes only after one is enabled")
  func repositoryIndependentOnboarding() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }

    _ = try await fixture.service.send(.acknowledgeExternalAutomation(true))
    _ = try await fixture.service.send(.acknowledgeProviderDisclosure(true))
    _ = try await fixture.service.send(
      .replaceCredential(Data(String(repeating: "t", count: 32).utf8))
    )
    _ = try await fixture.service.send(.setPaused(true))
    _ = try await fixture.service.send(
      .synchronizeLoginStatus(selected: true, status: .enabled)
    )

    let completed = try await fixture.service.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)
    #expect(completed.state.settings.repositories.isEmpty)
    #expect(!completed.state.paused)
    #expect(!(try await fixture.configuration.appConfiguration().paused))
    #expect(await fixture.runtime.reloadValues.last == false)

    let added = try await fixture.service.send(
      .addRepository(
        EngineRepositoryDraft(
          owner: "owner",
          name: "repo",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true
        )
      )
    )
    let repository = try #require(added.state.settings.repositories.first)
    #expect(await fixture.runtime.dispatchValues.last == true)

    _ = try await fixture.service.send(
      .updateRepository(
        RepositoryConfiguration(
          id: repository.id,
          nodeID: repository.nodeID,
          owner: repository.owner,
          name: repository.name,
          defaultBranch: repository.defaultBranch,
          reviewEnabled: repository.reviewEnabled,
          triageEnabled: repository.triageEnabled,
          implementationEnabled: repository.implementationEnabled,
          enabled: false
        )
      )
    )
    #expect(await fixture.runtime.dispatchValues.last == false)
  }

  @Test("model catalog refresh is explicit, informational, and fail-closed")
  func modelCatalogRefresh() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let initial = try await fixture.service.snapshot()
    #expect(initial.settings.modelCatalog.models.isEmpty)
    let refreshed = try await fixture.service.send(.refreshModelCatalog)
    #expect(
      refreshed.state.settings.modelCatalog.models.map(\.selectionID)
        == ["openai-codex/gpt-5.6-sol"]
    )
    await fixture.external.setCatalogFailure(true)
    await #expect(throws: EngineClientError(.piBlocked)) {
      _ = try await fixture.service.send(.refreshModelCatalog)
    }
    #expect(try await fixture.service.snapshot().settings.modelCatalog.models.isEmpty)
    #expect(await fixture.runtime.reloadValues.count == 1)
  }

  @Test("consent withdrawal and profile changes durably close dispatch")
  func consentAndProfileBinding() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()

    let withdrawn = try await fixture.service.send(
      .acknowledgeProviderDisclosure(false)
    )
    #expect(withdrawn.state.lifecycle == .onboarding)
    #expect(!withdrawn.state.onboarding.providerDisclosureAcknowledged)
    #expect(await fixture.runtime.dispatchValues.last == false)

    _ = try await fixture.service.send(.acknowledgeProviderDisclosure(true))
    _ = try await fixture.service.send(.completeOnboarding)
    let changed = try await fixture.service.send(
      .setProfile(
        ModelProfileConfiguration(
          role: .review,
          provider: "configured-provider",
          model: "configured/model",
          thinking: .high
        )
      )
    )
    #expect(changed.state.lifecycle == .onboarding)
    #expect(!changed.state.onboarding.providerDisclosureAcknowledged)
    #expect(await fixture.runtime.dispatchValues.last == false)
  }

  @Test("Herdr readiness closes dispatch and focus remains an explicit command")
  func herdrReadinessAndFocus() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()

    await fixture.external.setHerdr(
      EngineHerdrStatus(
        state: .blocked,
        issueCode: .versionMismatch,
        summary: "Incompatible Herdr.",
        recovery: "Restore Herdr 0.8.2."
      )
    )
    let blocked = try await fixture.service.send(.runHerdrPreflight)
    #expect(blocked.state.settings.herdr.state == .blocked)
    #expect(blocked.state.operationalStatus == .warning)
    #expect(await fixture.runtime.dispatchValues.last == false)
    await #expect(throws: EngineClientError(.herdrBlocked)) {
      _ = try await fixture.service.send(.focusInHerdr)
    }
    #expect(await fixture.runtime.focusCount == 0)

    await fixture.external.setHerdr(EngineServiceExternalFake.readyHerdr())
    _ = try await fixture.service.send(.runHerdrPreflight)
    _ = try await fixture.service.send(.focusInHerdr)
    #expect(await fixture.runtime.focusCount == 1)
  }

  @Test("wake and network regain forward only lifecycle scheduler reasons")
  func lifecycleTriggers() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.service.notifyLifecycleEvent(.wake)
    await fixture.service.notifyLifecycleEvent(.networkRegained)
    await fixture.service.notifyLifecycleEvent(.manual)
    #expect(await fixture.runtime.lifecycleReasons == [.wake, .networkRegained])
  }

  @Test("readiness regained on wake rebuilds runtime before requesting a pass")
  func readinessRegainReloadsRuntime() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()
    await fixture.external.setHerdr(
      EngineHerdrStatus(
        state: .blocked,
        issueCode: .socketUnavailable,
        summary: "Herdr is unavailable.",
        recovery: "Start Herdr."
      )
    )
    _ = try await fixture.service.send(.runHerdrPreflight)
    let reloadsBeforeRegain = await fixture.runtime.reloadValues.count

    await fixture.external.setHerdr(EngineServiceExternalFake.readyHerdr())
    await fixture.service.notifyLifecycleEvent(.wake)
    #expect(await fixture.runtime.reloadValues.count == reloadsBeforeRegain + 1)
    #expect(await fixture.runtime.reloadValues.last == true)
    #expect(await fixture.runtime.lifecycleReasons.last == .wake)
  }

  @Test("pause persists first and leaves an in-flight pass running")
  func pauseDoesNotInterruptInFlightPass() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.runtime.setPassRunning(true)

    let response = try await fixture.service.send(.setPaused(true))
    #expect(response.state.paused)
    #expect(response.state.passRunning)
    #expect(try await fixture.configuration.appConfiguration().paused)
    #expect(await fixture.runtime.pauseValues.last == true)
    #expect(await fixture.runtime.prePauseObservedPersistedValues.last == false)
    #expect(await fixture.runtime.pauseDrainObservedPersistedValues.last == true)
    #expect(await fixture.runtime.pauseObservedPersistedValues.last == true)
    #expect(await fixture.runtime.prepareCount == 0)

    _ = try await fixture.service.send(.setPaused(false))
    #expect(!(try await fixture.configuration.appConfiguration().paused))
    #expect(await fixture.runtime.pollCount == 0)
  }

  @Test("quit waits for the runtime checkpoint and returns durable evidence")
  func durableQuit() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.runtime.setPassRunning(true)

    let response = try await fixture.service.send(.prepareForQuit)
    #expect(response.state.lifecycle == .quitting)
    #expect(response.state.paused)
    #expect(response.checkpoint?.databaseCheckpointed == true)
    #expect(response.checkpoint?.nonterminalJobCount == 0)
    #expect(await fixture.runtime.prepareCount == 1)
    #expect(try await fixture.configuration.appConfiguration().paused)
    await #expect(throws: EngineClientError(.busy)) {
      _ = try await fixture.service.send(.pollNow)
    }
  }

  @Test("ambiguous retry requires byte-exact current evidence")
  func exactAmbiguousAuthorization() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let job = try await fixture.makeAmbiguousJob(repositoryID: repository.id)

    let state = try await fixture.service.snapshot()
    let mutation = try #require(state.ambiguousMutations.first)
    #expect(state.operationalStatus == .warning)
    #expect(mutation.jobID == job.id)
    #expect(mutation.evidenceDigest == String(repeating: "4", count: 64))
    #expect(mutation.revisionKey == String(repeating: "a", count: 40))

    let exact = EngineAmbiguousMutationEvidence(mutation)
    let stale = EngineAmbiguousMutation(
      jobID: mutation.jobID,
      repositoryID: mutation.repositoryID,
      repositoryOwner: mutation.repositoryOwner,
      repositoryName: mutation.repositoryName,
      kind: mutation.kind,
      objectNodeID: mutation.objectNodeID,
      objectNumber: mutation.objectNumber,
      revisionKey: mutation.revisionKey,
      evidenceDigest: String(repeating: "5", count: 64),
      mutationGeneration: mutation.mutationGeneration,
      mutationID: mutation.mutationID
    )
    await #expect(throws: EngineClientError(.staleEvidence)) {
      _ = try await fixture.service.send(
        .authorizeRetry(EngineAmbiguousMutationEvidence(stale))
      )
    }

    _ = try await fixture.service.send(.recheckAmbiguousMutation(exact))
    #expect(await fixture.runtime.recheckedJobs == [job.id])
    let authorized = try await fixture.service.send(.authorizeRetry(exact))
    #expect(authorized.state.ambiguousMutations.isEmpty)
    #expect(try await fixture.jobs.job(id: job.id)?.state == .queued)
    #expect(try await fixture.jobs.job(id: job.id)?.attempt == 2)
    #expect(await fixture.runtime.pollCount == 1)
    #expect(await fixture.runtime.exclusiveBeginCount == 3)
    #expect(await fixture.runtime.exclusiveEndCount == 3)
  }

  @Test("canary service remains paused and binds preview execute and checkpoint")
  func exactJobCanary() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()
    try await fixture.database.execute(
      "UPDATE app_settings SET github_account = 'octocat', github_author_id = 1 WHERE singleton = 1"
    )
    let repository = try #require(try await fixture.configuration.repositories().first)
    let boundary = JobCanaryScope.authorizedBoundaryEpochSeconds
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "PR_canary",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 42,
      contractVersionUsed: "w7-canary",
      priority: .prReview,
      firstStep: .review,
      now: Date(timeIntervalSince1970: TimeInterval(boundary))
    )
    guard case .created(let job) = creation else {
      Issue.record("canary fixture job was suppressed")
      return
    }
    for (key, event, reason) in [
      ("canary-service-lease", JobEvent.acquireLease, "lease"),
      ("canary-service-inputs", .inputsValidated, "inputs"),
      ("canary-service-pi", .selectPiStep, "pi"),
      (
        "canary-service-block", .piPermanentFailure,
        "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError"
      ),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: key,
        event: event,
        context: JobTransitionContext(now: fixture.now, reason: reason)
      )
    }
    _ = try await fixture.service.send(.setPaused(true))
    let repairScope = JobMaintenanceScope(
      operation: .retryResourceFailuresAfter,
      boundaryEpochSeconds: boundary
    )
    let repair = try await fixture.jobs.previewMaintenance(scope: repairScope)
    _ = try await fixture.jobs.applyMaintenance(
      JobMaintenanceAuthorization(
        scope: repairScope,
        expectedCount: 1,
        evidenceSHA256: repair.evidenceSHA256
      ),
      now: fixture.now
    )
    let scope = JobCanaryScope(
      jobID: job.id,
      boundaryEpochSeconds: boundary,
      repairEvidenceSHA256: repair.evidenceSHA256,
      maximumCommentParts: 8
    )
    let previewResponse = try await fixture.service.send(.previewJobCanary(scope))
    let preview = try #require(previewResponse.jobCanary)
    #expect(preview.status == .preview)
    #expect(previewResponse.checkpoint == nil)
    let authorization = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: preview.previewEvidenceSHA256
    )
    await fixture.runtime.setCanaryExecutionReport(
      JobCanaryReport(
        scope: scope,
        previewEvidenceSHA256: preview.previewEvidenceSHA256,
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
    )
    let beginsBefore = await fixture.runtime.exclusiveBeginCount
    let endsBefore = await fixture.runtime.exclusiveEndCount
    let executed = try await fixture.service.send(.executeJobCanary(authorization))
    #expect(executed.jobCanary?.status == .settled)
    #expect(executed.checkpoint?.databaseCheckpointed == true)
    #expect(executed.state.paused)
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 1)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 1)
    #expect(await fixture.runtime.pollCount == 0)

    let recoveryPreview = JobCanaryRecoveryReport(
      jobID: job.id,
      canaryAuthorizationSHA256: authorization.authorizationSHA256,
      recoveryEvidenceSHA256: String(repeating: "d", count: 64),
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
      unknownIntentSHA256: String(repeating: "e", count: 64),
      unknownPayloadSHA256: String(repeating: "f", count: 64),
      layoutSHA256: String(repeating: "1", count: 64),
      hostExecutableSHA256: String(repeating: "3", count: 64),
      roles: [.architecture, .security, .test, .synthesis],
      replayed: false
    )
    await fixture.runtime.setCanaryRecoveryPreviewReport(recoveryPreview)
    let recoveryPreviewResponse = try await fixture.service.send(
      .previewJobCanaryRecovery(authorization)
    )
    #expect(recoveryPreviewResponse.jobCanary == nil)
    #expect(recoveryPreviewResponse.jobCanaryRecovery == recoveryPreview)
    #expect(recoveryPreviewResponse.checkpoint == nil)
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
    let settled = try #require(executed.jobCanary)
    await fixture.runtime.setCanaryRecoveryExecution(
      JobCanaryRecoveryExecution(recovery: recovered, canary: settled)
    )
    let recoveryExecuted = try await fixture.service.send(
      .executeJobCanaryRecovery(recoveryAuthorization)
    )
    #expect(recoveryExecuted.jobCanary == settled)
    #expect(recoveryExecuted.jobCanaryRecovery == recovered)
    #expect(recoveryExecuted.checkpoint?.databaseCheckpointed == true)
    #expect(recoveryExecuted.state.paused)
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 2)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 2)
    #expect(await fixture.runtime.pollCount == 0)
  }

  @Test("generation rollover service keeps phases paused exclusive and checkpointed")
  func generationRolloverServiceBoundary() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()
    _ = try await fixture.service.send(.setPaused(true))
    let retry = engineServiceReplacementAuthorization().request.retry
    let rollover = try engineGenerationRolloverFixture(retry: retry)
    let previewReport = try JobCanaryGenerationRolloverReport(
      authorization: rollover.authorization,
      status: .preview,
      replayed: false
    )
    let executeReport = try JobCanaryGenerationRolloverReport(
      authorization: rollover.authorization,
      status: .topologyActivated,
      replayed: false
    )
    let q4PreviewReport = try JobCanaryGenerationRolloverQ4Report(
      authorization: rollover.q4Execution.q4,
      status: .preview,
      replayed: false
    )
    let q4ExecuteReport = try JobCanaryGenerationRolloverQ4Report(
      authorization: rollover.q4Execution.q4,
      status: .settled,
      replayed: false
    )
    await fixture.runtime.setGenerationRolloverReports(
      preview: previewReport,
      execution: executeReport,
      q4Preview: q4PreviewReport,
      q4Execution: q4ExecuteReport
    )

    let preview = try await fixture.service.send(
      .previewJobCanaryGenerationRollover(rollover.request)
    )
    #expect(preview.jobCanaryGenerationRollover == previewReport)
    #expect(preview.checkpoint == nil)
    #expect(preview.state.paused)

    let beginsBefore = await fixture.runtime.exclusiveBeginCount
    let endsBefore = await fixture.runtime.exclusiveEndCount
    let executed = try await fixture.service.send(
      .executeJobCanaryGenerationRollover(rollover.authorization)
    )
    #expect(executed.jobCanaryGenerationRollover == executeReport)
    #expect(executed.checkpoint?.databaseCheckpointed == true)
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 1)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 1)

    let q4Preview = try await fixture.service.send(
      .previewJobCanaryGenerationRolloverQ4(rollover.q4Request)
    )
    #expect(q4Preview.jobCanaryGenerationRolloverQ4 == q4PreviewReport)
    #expect(q4Preview.checkpoint == nil)
    let q4Executed = try await fixture.service.send(
      .executeJobCanaryGenerationRolloverQ4(rollover.q4Execution)
    )
    #expect(q4Executed.jobCanaryGenerationRolloverQ4 == q4ExecuteReport)
    #expect(q4Executed.checkpoint?.databaseCheckpointed == true)
    #expect(q4Executed.state.paused)
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 2)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 2)
    let request = EngineXPCRequest(
      command: .executeJobCanaryGenerationRolloverQ4(rollover.q4Execution)
    )
    #expect(
      try EngineXPCResponse(requestID: request.requestID, result: q4Executed)
        .validate(for: request) == q4Executed
    )
  }

  @Test(
    "replacement service checkpoints every typed terminal outcome with balanced exclusivity",
    arguments: EngineServiceReplacementOutcomeCase.allCases
  )
  func replacementTerminalOutcomeBoundary(
    outcomeCase: EngineServiceReplacementOutcomeCase
  ) async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()
    _ = try await fixture.service.send(.setPaused(true))
    let authorization = engineServiceReplacementAuthorization()
    let replacement = try engineServiceReplacementReport(
      authorization: authorization,
      outcome: outcomeCase.outcome
    )
    let canary = engineServiceReplacementCanary(authorization: authorization)
    await fixture.runtime.setReplacementExecution(
      JobCanaryRoleHostReplacementExecution(replacement: replacement, canary: canary)
    )
    let beginsBefore = await fixture.runtime.exclusiveBeginCount
    let endsBefore = await fixture.runtime.exclusiveEndCount
    let command = EngineCommand.executeJobCanaryRoleHostReplacement(authorization)
    let response = try await fixture.service.send(command)
    #expect(response.jobCanaryRoleHostReplacement == replacement)
    #expect(response.jobCanary == canary)
    #expect(response.checkpoint?.databaseCheckpointed == true)
    #expect(response.state.paused)
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 1)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 1)
    let request = EngineXPCRequest(command: command)
    let xpc = EngineXPCResponse(requestID: request.requestID, result: response)
    #expect(try xpc.validate(for: request) == response)
  }

  @Test("replacement service balances exclusivity when production runtime throws")
  func replacementThrownErrorBoundary() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()
    _ = try await fixture.service.send(.setPaused(true))
    let authorization = engineServiceReplacementAuthorization()
    await fixture.runtime.setReplacementError(EngineClientError(.staleEvidence))
    let beginsBefore = await fixture.runtime.exclusiveBeginCount
    let endsBefore = await fixture.runtime.exclusiveEndCount
    await #expect(throws: EngineClientError(.staleEvidence)) {
      _ = try await fixture.service.send(.executeJobCanaryRoleHostReplacement(authorization))
    }
    #expect(await fixture.runtime.exclusiveBeginCount == beginsBefore + 1)
    #expect(await fixture.runtime.exclusiveEndCount == endsBefore + 1)
  }

  @Test("job maintenance requires pause exact evidence checkpoint and cleanup")
  func exactJobMaintenance() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueTriage,
        objectNodeID: "issue-maintenance",
        revisionKey: "initial-triage"
      ),
      objectNumber: 42,
      contractVersionUsed: "w7-test",
      priority: .triage,
      firstStep: .triage,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("maintenance fixture job was suppressed")
      return
    }
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    await #expect(throws: EngineClientError(.busy)) {
      _ = try await fixture.service.send(.previewJobMaintenance(scope))
    }
    _ = try await fixture.service.send(.setPaused(true))
    let preview = try await fixture.service.send(.previewJobMaintenance(scope))
    let report = try #require(preview.jobMaintenance)
    #expect(report.candidateCount == 1)
    #expect(report.appliedCount == 0)
    #expect(preview.checkpoint == nil)

    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: report.candidateCount,
      evidenceSHA256: report.evidenceSHA256
    )
    let applied = try await fixture.service.send(.applyJobMaintenance(authorization))
    #expect(applied.jobMaintenance?.appliedCount == 1)
    #expect(applied.jobMaintenance?.replayed == false)
    #expect(applied.checkpoint?.databaseCheckpointed == true)
    #expect(try await fixture.jobs.job(id: job.id)?.state == .blocked)
    #expect(try await fixture.jobs.disposition(for: job.identity)?.state == .superseded)
    #expect(await fixture.runtime.cleanedRetiredJobs == [job.id])
    #expect(
      await fixture.runtime.cleanupEvidence == [try #require(preview.jobMaintenance).evidenceSHA256]
    )

    let replay = try await fixture.service.send(.applyJobMaintenance(authorization))
    #expect(replay.jobMaintenance?.replayed == true)
    #expect(await fixture.runtime.cleanedRetiredJobs == [job.id, job.id])
    #expect(await fixture.runtime.pollCount == 0)
    #expect(replay.state.paused)
  }

  @Test("retirement cleanup failure replays committed authority before checkpoint")
  func maintenanceCleanupRecovery() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let creation = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueTriage,
        objectNodeID: "issue-maintenance-recovery",
        revisionKey: "initial-triage"
      ),
      contractVersionUsed: "w7-test",
      priority: .triage,
      firstStep: .triage,
      now: fixture.now
    )
    guard case .created(let job) = creation else {
      Issue.record("maintenance recovery fixture was suppressed")
      return
    }
    _ = try await fixture.service.send(.setPaused(true))
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let preview = try #require(
      try await fixture.service.send(.previewJobMaintenance(scope)).jobMaintenance
    )
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    await fixture.runtime.setCleanupError(EngineClientError(.internalFailure))
    await #expect(throws: EngineClientError(.internalFailure)) {
      _ = try await fixture.service.send(.applyJobMaintenance(authorization))
    }
    #expect(try await fixture.jobs.job(id: job.id)?.state == .blocked)
    #expect(try await fixture.jobs.disposition(for: job.identity)?.state == .superseded)
    #expect(await fixture.runtime.exclusiveBeginCount == 1)
    #expect(await fixture.runtime.exclusiveEndCount == 1)

    await fixture.runtime.setCleanupError(nil)
    let recovered = try await fixture.service.send(.applyJobMaintenance(authorization))
    #expect(recovered.jobMaintenance?.replayed == true)
    #expect(recovered.checkpoint?.databaseCheckpointed == true)
    #expect(await fixture.runtime.cleanedRetiredJobs == [job.id])
    #expect(await fixture.runtime.pollCount == 0)
    #expect(recovered.state.paused)
  }
}

enum EngineServiceReplacementOutcomeCase: CaseIterable, Sendable {
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

private func engineServiceReplacementAuthorization()
  -> JobCanaryRoleHostReplacementAuthorization
{
  let canary = JobCanaryAuthorization(
    scope: JobCanaryScope(
      jobID: UUID(uuidString: "aaaaaaaa-1111-4111-8111-111111111111")!,
      boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
      repairEvidenceSHA256: String(repeating: "a", count: 64),
      maximumCommentParts: 8
    ),
    previewEvidenceSHA256: String(repeating: "b", count: 64)
  )
  let request = JobCanaryRoleHostReplacementRequest(
    retry: JobCanaryPiRetryAuthorization(
      recovery: JobCanaryRecoveryAuthorization(
        canary: canary,
        recoveryEvidenceSHA256: String(repeating: "c", count: 64)
      ),
      retryEvidenceSHA256: String(repeating: "d", count: 64)
    ),
    incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
    plannedReplacementRoleHostID: "rolehost-11111111-1111-4111-8111-111111111111",
    plannedLaunchAttemptID: "launch-22222222-2222-4222-8222-222222222222"
  )
  return JobCanaryRoleHostReplacementAuthorization(
    request: request,
    replacementEvidenceSHA256: String(repeating: "e", count: 64),
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

private func engineServiceReplacementCanary(
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
    revisionKey: String(repeating: "f", count: 40),
    provider: "fixture",
    model: "fixture",
    thinking: "off",
    resourceTreeSHA256: authorization.q4Binding.resourceTreeSHA256,
    replayed: false
  )
}

private func engineServiceReplacementReport(
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

private actor EngineServiceExternalFake: EngineExternalServicing {
  private(set) var sawCredential = false
  private var status = EngineCredentialStatus.missing
  private var herdr = readyHerdr()
  private var catalogFailure = false

  func credentialStatus() -> EngineCredentialStatus {
    status
  }

  func replaceCredential(
    _ token: Data,
    allowAccountChange: Bool
  ) -> EngineCredentialStatus {
    sawCredential = token.count >= 20
    status = EngineCredentialStatus(state: .valid, account: "octocat")
    return status
  }

  func deleteCredential() {
    status = .missing
  }

  func validateRepository(
    _ draft: EngineRepositoryDraft,
    existingID: UUID?
  ) -> RepositoryConfiguration {
    RepositoryConfiguration(
      id: existingID ?? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      nodeID: "R_node",
      owner: draft.owner,
      name: draft.name,
      defaultBranch: "main",
      reviewEnabled: draft.reviewEnabled,
      triageEnabled: draft.triageEnabled,
      implementationEnabled: draft.implementationEnabled,
      enabled: true
    )
  }

  func preflightHerdr() -> EngineHerdrStatus {
    herdr
  }

  func discoverModelCatalog() throws -> PiModelCatalog {
    if catalogFailure { throw EngineClientError(.piBlocked) }
    return PiModelCatalog(
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
  }

  func setCatalogFailure(_ value: Bool) {
    catalogFailure = value
  }

  func setCredentialStatus(_ value: EngineCredentialStatus) {
    status = value
  }

  func setHerdr(_ status: EngineHerdrStatus) {
    herdr = status
  }

  static func readyHerdr() -> EngineHerdrStatus {
    EngineHerdrStatus(
      state: .ready,
      version: "0.8.2",
      protocolVersion: 20,
      executableSHA256: String(repeating: "e", count: 64),
      schemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
  }

  func preflightPi() -> EnginePiStatus {
    EnginePiStatus(
      state: .ready,
      executablePath: "/opt/homebrew/bin/pi",
      version: "0.84.1",
      policySHA256: String(repeating: "f", count: 64)
    )
  }
}

private struct EngineServiceUnknownStartupError: LocalizedError, Equatable, Sendable {
  let description: String

  var errorDescription: String? { description }
}

private enum EngineServiceReloadFailure: Sendable {
  case client(EngineClientError)
  case unknown(EngineServiceUnknownStartupError)
}

private actor EngineServiceLogFake: EngineEventLogging {
  private(set) var records: [EngineLogRecord] = []

  func record(_ record: EngineLogRecord) {
    records.append(record)
  }
}

private actor EngineServiceRuntimeFake: EngineJobRuntime {
  private(set) var dispatchValues: [Bool] = []
  private(set) var reloadValues: [Bool] = []
  private(set) var pauseValues: [Bool] = []
  private(set) var prePauseObservedPersistedValues: [Bool] = []
  private(set) var pauseDrainObservedPersistedValues: [Bool] = []
  private(set) var pauseObservedPersistedValues: [Bool] = []
  private(set) var pollCount = 0
  private(set) var lifecycleReasons: [SchedulerTriggerReason] = []
  private(set) var recheckedJobs: [UUID] = []
  private(set) var cleanedRetiredJobs: [UUID] = []
  private(set) var cleanupEvidence: [String] = []
  private var cleanupError: EngineClientError?
  private(set) var exclusiveBeginCount = 0
  private(set) var exclusiveEndCount = 0
  private(set) var prepareCount = 0
  private(set) var focusCount = 0
  private var passRunning = false
  private var pauseObserver: ConfigurationStore?
  private var reloadFailure: EngineServiceReloadFailure?
  private var databaseToCloseOnReload: SQLiteStore?
  private var canaryExecutionReport: JobCanaryReport?
  private var canaryRecoveryPreviewReport: JobCanaryRecoveryReport?
  private var canaryRecoveryExecution: JobCanaryRecoveryExecution?
  private var replacementExecution: JobCanaryRoleHostReplacementExecution?
  private var replacementError: EngineClientError?
  private var generationRolloverPreview: JobCanaryGenerationRolloverReport?
  private var generationRolloverExecution: JobCanaryGenerationRolloverReport?
  private var generationRolloverQ4Preview: JobCanaryGenerationRolloverQ4Report?
  private var generationRolloverQ4Execution: JobCanaryGenerationRolloverQ4Report?

  func reload(dispatchAllowed: Bool) async throws {
    reloadValues.append(dispatchAllowed)
    dispatchValues.append(dispatchAllowed)
    if let databaseToCloseOnReload {
      self.databaseToCloseOnReload = nil
      await databaseToCloseOnReload.close()
    }
    switch reloadFailure {
    case .client(let error):
      throw error
    case .unknown(let error):
      throw error
    case nil:
      return
    }
  }

  func setReloadFailure(_ failure: EngineServiceReloadFailure?) {
    reloadFailure = failure
  }

  func closeDatabaseOnReload(_ database: SQLiteStore) {
    databaseToCloseOnReload = database
  }

  func setDispatchAllowed(_ allowed: Bool) {
    dispatchValues.append(allowed)
  }

  func prepareForPause() async {
    if let pauseObserver,
      let persisted = try? await pauseObserver.appConfiguration().paused
    {
      prePauseObservedPersistedValues.append(persisted)
    }
  }

  func waitForPauseDrain() async {
    if let pauseObserver,
      let persisted = try? await pauseObserver.appConfiguration().paused
    {
      pauseDrainObservedPersistedValues.append(persisted)
    }
  }

  func setPaused(_ paused: Bool) async {
    pauseValues.append(paused)
    if let pauseObserver,
      let persisted = try? await pauseObserver.appConfiguration().paused
    {
      pauseObservedPersistedValues.append(persisted)
    }
  }

  func pollNow() {
    pollCount += 1
  }

  func requestLifecyclePass(_ reason: SchedulerTriggerReason) {
    lifecycleReasons.append(reason)
  }

  func beginExclusiveOperation() {
    exclusiveBeginCount += 1
  }

  func endExclusiveOperation() {
    exclusiveEndCount += 1
  }

  func recheckAmbiguousMutation(jobID: UUID) {
    recheckedJobs.append(jobID)
  }

  func cleanupRetiredJobs(jobIDs: [UUID], evidenceSHA256: String) throws {
    if let cleanupError { throw cleanupError }
    cleanedRetiredJobs.append(contentsOf: jobIDs)
    cleanupEvidence.append(evidenceSHA256)
  }

  func setCleanupError(_ error: EngineClientError?) {
    cleanupError = error
  }

  func canaryResourceTreeSHA256() -> String {
    String(repeating: "a", count: 64)
  }

  func setCanaryExecutionReport(_ report: JobCanaryReport) {
    canaryExecutionReport = report
  }

  func executeCanary(_ authorization: JobCanaryAuthorization) throws -> JobCanaryReport {
    guard let report = canaryExecutionReport,
      report.scope == authorization.scope,
      report.previewEvidenceSHA256 == authorization.previewEvidenceSHA256,
      report.authorizationSHA256 == authorization.authorizationSHA256
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func setCanaryRecoveryPreviewReport(_ report: JobCanaryRecoveryReport) {
    canaryRecoveryPreviewReport = report
  }

  func setCanaryRecoveryExecution(_ execution: JobCanaryRecoveryExecution) {
    canaryRecoveryExecution = execution
  }

  func previewCanaryRecovery(
    _ authorization: JobCanaryAuthorization
  ) throws -> JobCanaryRecoveryReport {
    guard let report = canaryRecoveryPreviewReport,
      report.jobID == authorization.scope.jobID,
      report.canaryAuthorizationSHA256 == authorization.authorizationSHA256
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func executeCanaryRecovery(
    _ authorization: JobCanaryRecoveryAuthorization
  ) throws -> JobCanaryRecoveryExecution {
    guard let execution = canaryRecoveryExecution,
      execution.recovery.recoveryEvidenceSHA256 == authorization.recoveryEvidenceSHA256,
      execution.recovery.recoveryAuthorizationSHA256 == authorization.authorizationSHA256
    else { throw EngineClientError(.staleEvidence) }
    return execution
  }

  func setReplacementExecution(_ execution: JobCanaryRoleHostReplacementExecution?) {
    replacementExecution = execution
  }

  func setReplacementError(_ error: EngineClientError?) {
    replacementError = error
  }

  func executeCanaryRoleHostReplacement(
    _ authorization: JobCanaryRoleHostReplacementAuthorization
  ) throws -> JobCanaryRoleHostReplacementExecution {
    if let replacementError { throw replacementError }
    guard let execution = replacementExecution,
      execution.replacement.replacementRoleHostID
        == authorization.request.plannedReplacementRoleHostID,
      execution.replacement.replacementEvidenceSHA256
        == authorization.replacementEvidenceSHA256,
      execution.replacement.q4Binding == authorization.q4Binding
    else { throw EngineClientError(.staleEvidence) }
    return execution
  }

  func setGenerationRolloverReports(
    preview: JobCanaryGenerationRolloverReport,
    execution: JobCanaryGenerationRolloverReport,
    q4Preview: JobCanaryGenerationRolloverQ4Report,
    q4Execution: JobCanaryGenerationRolloverQ4Report
  ) {
    generationRolloverPreview = preview
    generationRolloverExecution = execution
    generationRolloverQ4Preview = q4Preview
    generationRolloverQ4Execution = q4Execution
  }

  func previewCanaryGenerationRollover(
    _ request: JobCanaryGenerationRolloverRequest
  ) throws -> JobCanaryGenerationRolloverReport {
    guard let report = generationRolloverPreview,
      report.authorization.request == request
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func executeCanaryGenerationRollover(
    _ authorization: JobCanaryGenerationRolloverAuthorization
  ) throws -> JobCanaryGenerationRolloverReport {
    guard let report = generationRolloverExecution,
      report.authorization == authorization
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func previewCanaryGenerationRolloverQ4(
    _ request: JobCanaryGenerationRolloverQ4Request
  ) throws -> JobCanaryGenerationRolloverQ4Report {
    guard let report = generationRolloverQ4Preview,
      report.authorization.rolloverAuthorizationSHA256
        == request.rolloverAuthorization.authorizationSHA256,
      report.authorization.plannedLaunchAttemptID == request.plannedLaunchAttemptID
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func executeCanaryGenerationRolloverQ4(
    _ authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization
  ) throws -> JobCanaryGenerationRolloverQ4Report {
    guard let report = generationRolloverQ4Execution,
      report.authorization == authorization.q4
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  func waitUntilIdle() {}

  func timingSnapshot() -> SchedulerTimingSnapshot? {
    SchedulerTimingSnapshot(
      paused: pauseValues.last ?? false,
      passRunning: passRunning,
      pendingReasons: [],
      dueAt: nil,
      nextPeriodicAt: Date(timeIntervalSince1970: 999_999)
    )
  }

  func coordinatorSnapshot() -> JobCoordinatorSnapshot? {
    JobCoordinatorSnapshot(lastPass: nil, failures: [])
  }

  func prepareForCheckpoint() {
    prepareCount += 1
    passRunning = false
  }

  func focusInHerdr() {
    focusCount += 1
  }

  func setPassRunning(_ value: Bool) {
    passRunning = value
  }

  func observePausePersistence(using configuration: ConfigurationStore) {
    pauseObserver = configuration
  }
}

private final class EngineServiceFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let external: EngineServiceExternalFake
  let runtime: EngineServiceRuntimeFake
  let service: EngineService
  let now = Date(timeIntervalSince1970: 200_000)

  init(
    rootURL: URL? = nil,
    initialize: Bool = true,
    logger: any EngineEventLogging = NullEngineEventLogger()
  ) async throws {
    root =
      rootURL
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-engine-\(UUID().uuidString)", isDirectory: true)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    configuration = ConfigurationStore(database: database)
    jobs = DurableJobStore(database: database)
    intents = MutationIntentStore(database: database)
    external = EngineServiceExternalFake()
    runtime = EngineServiceRuntimeFake()
    await runtime.observePausePersistence(using: configuration)
    service = EngineService(
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      database: database,
      external: external,
      runtime: runtime,
      logger: logger,
      duplicateInstanceCheckPassed: true,
      now: { Date(timeIntervalSince1970: 200_000) }
    )
    if initialize {
      try await service.initialize()
    }
  }

  func completeOnboarding() async throws {
    _ = try await service.send(.acknowledgeExternalAutomation(true))
    _ = try await service.send(.acknowledgeProviderDisclosure(true))
    _ = try await service.send(
      .replaceCredential(Data(String(repeating: "t", count: 32).utf8))
    )
    _ = try await addRepository()
    _ = try await service.send(
      .synchronizeLoginStatus(selected: true, status: .enabled)
    )
    _ = try await service.send(.completeOnboarding)
  }

  func addRepository() async throws -> RepositoryConfiguration {
    let repository = RepositoryConfiguration(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      nodeID: "R_node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(repository, now: now)
    return repository
  }

  func makeAmbiguousJob(repositoryID: UUID) async throws -> JobRecord {
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .prReview,
        objectNodeID: "PR_node",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 7,
      contractVersionUsed: "w7-test",
      priority: .prReview,
      firstStep: .publish,
      now: now
    )
    guard case .created(let job) = created else {
      throw EngineClientError(.internalFailure)
    }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: now, reason: "fixture lease")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: now, reason: "fixture inputs")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:execute",
      event: .selectLocalStep,
      context: JobTransitionContext(now: now, reason: "fixture mutation")
    )
    let intent = try await intents.prepare(
      jobID: job.id,
      idempotencyKey: String(repeating: "1", count: 64),
      operation: .createMarkerComment,
      target: "owner/repo/issues/7",
      expectedStateDigest: String(repeating: "2", count: 64),
      requestDigest: String(repeating: "3", count: 64),
      now: now
    )
    _ = try await intents.markSendStarted(id: intent.id, now: now)
    _ = try await intents.markReconcileRequired(id: intent.id, now: now)
    _ = try await intents.settle(
      id: intent.id,
      outcome: .escalation,
      evidenceDigest: String(repeating: "4", count: 64),
      now: now
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:reconcile",
      event: .mutationNeedsAttribution,
      context: JobTransitionContext(now: now, reason: "fixture read-back")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:ambiguous",
      event: .ambiguousCreate,
      context: JobTransitionContext(now: now, reason: "fixture ambiguous")
    )
    return try #require(await jobs.job(id: job.id))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
