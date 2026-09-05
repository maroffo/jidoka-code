import Foundation

public protocol EngineExternalServicing: Sendable {
  func credentialStatus() async -> EngineCredentialStatus
  func replaceCredential(
    _ token: Data,
    allowAccountChange: Bool
  ) async throws -> EngineCredentialStatus
  func deleteCredential() async throws
  func validateRepository(
    _ draft: EngineRepositoryDraft,
    existingID: UUID?
  ) async throws -> RepositoryConfiguration
  func preflightPi() async -> EnginePiStatus
  func preflightHerdr() async -> EngineHerdrStatus
  func discoverModelCatalog() async throws -> PiModelCatalog
  func revalidateRollout(_ preview: RolloutPreview) async throws
}

extension EngineExternalServicing {
  public func revalidateRollout(_ preview: RolloutPreview) async throws {
    throw EngineClientError(.unavailable)
  }
}

public protocol EngineJobRuntime: Sendable {
  func reload(dispatchAllowed: Bool) async throws
  func setDispatchAllowed(_ allowed: Bool) async
  func prepareForPause() async
  func waitForPauseDrain() async
  func setPaused(_ paused: Bool) async
  func pollNow() async
  func previewRollout(_ input: RolloutPreviewInput) async throws -> RolloutPreview
  func activateRollout(_ request: RolloutActivationRequest) async throws -> RolloutStatusReport
  func rolloutStatus() async throws -> RolloutStatusReport?
  func stopAndDrainRollout(_ request: RolloutStopRequest) async throws -> RolloutStatusReport
  func previewRolloutRecovery(
    _ request: RolloutRecoveryRequest
  ) async throws -> RolloutRecoveryPreview
  func executeRolloutRecovery(
    _ authorization: RolloutRecoveryAuthorization
  ) async throws -> RolloutStatusReport
  func requestLifecyclePass(_ reason: SchedulerTriggerReason) async
  func beginExclusiveOperation() async throws
  func endExclusiveOperation() async
  func recheckAmbiguousMutation(jobID: UUID) async throws
  func cleanupRetiredJobs(jobIDs: [UUID], evidenceSHA256: String) async throws
  func canaryResourceTreeSHA256() async throws -> String
  func executeCanary(_ authorization: JobCanaryAuthorization) async throws -> JobCanaryReport
  func previewCanaryRecovery(
    _ authorization: JobCanaryAuthorization
  ) async throws -> JobCanaryRecoveryReport
  func executeCanaryRecovery(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryRecoveryExecution
  func previewCanaryPiRetry(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryPiRetryReport
  func executeCanaryPiRetry(
    _ authorization: JobCanaryPiRetryAuthorization
  ) async throws -> JobCanaryPiRetryExecution
  func previewCanaryRoleHostReplacement(
    _ request: JobCanaryRoleHostReplacementRequest
  ) async throws -> JobCanaryRoleHostReplacementReport
  func executeCanaryRoleHostReplacement(
    _ authorization: JobCanaryRoleHostReplacementAuthorization
  ) async throws -> JobCanaryRoleHostReplacementExecution
  func previewCanaryGenerationRollover(
    _ request: JobCanaryGenerationRolloverRequest
  ) async throws -> JobCanaryGenerationRolloverReport
  func executeCanaryGenerationRollover(
    _ authorization: JobCanaryGenerationRolloverAuthorization
  ) async throws -> JobCanaryGenerationRolloverReport
  func previewCanaryGenerationRolloverQ4(
    _ request: JobCanaryGenerationRolloverQ4Request
  ) async throws -> JobCanaryGenerationRolloverQ4Report
  func executeCanaryGenerationRolloverQ4(
    _ authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization
  ) async throws -> JobCanaryGenerationRolloverQ4Report
  func waitUntilIdle() async throws
  func timingSnapshot() async -> SchedulerTimingSnapshot?
  func coordinatorSnapshot() async -> JobCoordinatorSnapshot?
  func prepareForCheckpoint() async throws
  func focusInHerdr() async throws
}

extension EngineJobRuntime {
  public func prepareForPause() async {}
  public func waitForPauseDrain() async {}
  public func previewRollout(_ input: RolloutPreviewInput) async throws -> RolloutPreview {
    throw EngineClientError(.unavailable)
  }
  public func activateRollout(
    _ request: RolloutActivationRequest
  ) async throws -> RolloutStatusReport {
    throw EngineClientError(.unavailable)
  }
  public func rolloutStatus() async throws -> RolloutStatusReport? { nil }
  public func stopAndDrainRollout(
    _ request: RolloutStopRequest
  ) async throws -> RolloutStatusReport {
    throw EngineClientError(.unavailable)
  }
  public func previewRolloutRecovery(
    _ request: RolloutRecoveryRequest
  ) async throws -> RolloutRecoveryPreview {
    throw EngineClientError(.unavailable)
  }
  public func executeRolloutRecovery(
    _ authorization: RolloutRecoveryAuthorization
  ) async throws -> RolloutStatusReport {
    throw EngineClientError(.unavailable)
  }
  public func canaryResourceTreeSHA256() async throws -> String {
    throw EngineClientError(.unavailable)
  }
  public func executeCanary(_ authorization: JobCanaryAuthorization) async throws
    -> JobCanaryReport
  {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryRecovery(
    _ authorization: JobCanaryAuthorization
  ) async throws -> JobCanaryRecoveryReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryRecovery(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryRecoveryExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryPiRetry(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryPiRetryReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryPiRetry(
    _ authorization: JobCanaryPiRetryAuthorization
  ) async throws -> JobCanaryPiRetryExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryRoleHostReplacement(
    _ request: JobCanaryRoleHostReplacementRequest
  ) async throws -> JobCanaryRoleHostReplacementReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryRoleHostReplacement(
    _ authorization: JobCanaryRoleHostReplacementAuthorization
  ) async throws -> JobCanaryRoleHostReplacementExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryGenerationRollover(
    _ request: JobCanaryGenerationRolloverRequest
  ) async throws -> JobCanaryGenerationRolloverReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryGenerationRollover(
    _ authorization: JobCanaryGenerationRolloverAuthorization
  ) async throws -> JobCanaryGenerationRolloverReport {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryGenerationRolloverQ4(
    _ request: JobCanaryGenerationRolloverQ4Request
  ) async throws -> JobCanaryGenerationRolloverQ4Report {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryGenerationRolloverQ4(
    _ authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization
  ) async throws -> JobCanaryGenerationRolloverQ4Report {
    throw EngineClientError(.unavailable)
  }
}

public actor InactiveEngineJobRuntime: EngineJobRuntime {
  public init() {}

  public func reload(dispatchAllowed: Bool) {}
  public func setDispatchAllowed(_ allowed: Bool) {}
  public func setPaused(_ paused: Bool) {}
  public func pollNow() {}
  public func requestLifecyclePass(_ reason: SchedulerTriggerReason) {}
  public func beginExclusiveOperation() {}
  public func endExclusiveOperation() {}
  public func recheckAmbiguousMutation(jobID: UUID) {}
  public func cleanupRetiredJobs(jobIDs: [UUID], evidenceSHA256: String) {}
  public func canaryResourceTreeSHA256() throws -> String {
    throw EngineClientError(.unavailable)
  }
  public func executeCanary(_ authorization: JobCanaryAuthorization) throws -> JobCanaryReport {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryRecovery(
    _ authorization: JobCanaryAuthorization
  ) throws -> JobCanaryRecoveryReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryRecovery(
    _ authorization: JobCanaryRecoveryAuthorization
  ) throws -> JobCanaryRecoveryExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryPiRetry(
    _ authorization: JobCanaryRecoveryAuthorization
  ) throws -> JobCanaryPiRetryReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryPiRetry(
    _ authorization: JobCanaryPiRetryAuthorization
  ) throws -> JobCanaryPiRetryExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryRoleHostReplacement(
    _ request: JobCanaryRoleHostReplacementRequest
  ) throws -> JobCanaryRoleHostReplacementReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryRoleHostReplacement(
    _ authorization: JobCanaryRoleHostReplacementAuthorization
  ) throws -> JobCanaryRoleHostReplacementExecution {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryGenerationRollover(
    _ request: JobCanaryGenerationRolloverRequest
  ) throws -> JobCanaryGenerationRolloverReport {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryGenerationRollover(
    _ authorization: JobCanaryGenerationRolloverAuthorization
  ) throws -> JobCanaryGenerationRolloverReport {
    throw EngineClientError(.unavailable)
  }
  public func previewCanaryGenerationRolloverQ4(
    _ request: JobCanaryGenerationRolloverQ4Request
  ) throws -> JobCanaryGenerationRolloverQ4Report {
    throw EngineClientError(.unavailable)
  }
  public func executeCanaryGenerationRolloverQ4(
    _ authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization
  ) throws -> JobCanaryGenerationRolloverQ4Report {
    throw EngineClientError(.unavailable)
  }
  public func waitUntilIdle() {}
  public func timingSnapshot() -> SchedulerTimingSnapshot? { nil }
  public func coordinatorSnapshot() -> JobCoordinatorSnapshot? { nil }
  public func prepareForCheckpoint() {}
  public func focusInHerdr() throws { throw EngineClientError(.herdrBlocked) }
}

public actor EngineService: EngineClient {
  private let configuration: ConfigurationStore
  private let jobs: DurableJobStore
  private let intents: MutationIntentStore
  private let database: SQLiteStore
  private let external: any EngineExternalServicing
  private let runtime: any EngineJobRuntime
  private let logger: any EngineEventLogging
  private let duplicateInstanceCheckPassed: Bool
  private let now: @Sendable () -> Date

  private var credentialStatus = EngineCredentialStatus.missing
  private var piStatus = EnginePiStatus.unchecked
  private var herdrStatus = EngineHerdrStatus.unchecked
  private var modelCatalog = PiModelCatalog.unavailable
  private var initialized = false
  private var quitting = false
  private var commandInProgress = false
  private var revision = 0

  public init(
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    database: SQLiteStore,
    external: any EngineExternalServicing,
    runtime: any EngineJobRuntime,
    logger: any EngineEventLogging = NullEngineEventLogger(),
    duplicateInstanceCheckPassed: Bool,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.jobs = jobs
    self.intents = intents
    self.database = database
    self.external = external
    self.runtime = runtime
    self.logger = logger
    self.duplicateInstanceCheckPassed = duplicateInstanceCheckPassed
    self.now = now
  }

  public func initialize() async throws {
    guard !initialized else { return }
    var phase = EngineStartupPhase.credentialStatus
    do {
      await recordStartupPhase(phase)
      credentialStatus = await external.credentialStatus()
      phase = .piPreflight
      await recordStartupPhase(phase)
      piStatus = await external.preflightPi()
      phase = .herdrPreflight
      await recordStartupPhase(phase)
      herdrStatus = await external.preflightHerdr()
      phase = .dispatchGate
      await recordStartupPhase(phase)
      let dispatchAllowed = try await dispatchAllowed()
      phase = .runtimeReload
      await recordStartupPhase(phase)
      try await runtime.reload(dispatchAllowed: dispatchAllowed)
      phase = .pausedState
      await recordStartupPhase(phase)
      let app = try await configuration.appConfiguration()
      await runtime.setPaused(app.paused)
      initialized = true
      await logger.record(
        EngineLogRecord(
          timestamp: now(),
          event: .initialized,
          command: nil,
          error: nil
        )
      )
    } catch let error as EngineClientError {
      await recordStartupFailure(phase: phase, error: error.code)
      throw error
    } catch {
      await recordStartupFailure(phase: phase, error: .internalFailure)
      throw error
    }
  }

  private func recordStartupPhase(_ phase: EngineStartupPhase) async {
    await logger.record(
      EngineLogRecord(
        timestamp: now(),
        event: .startupPhase,
        phase: phase,
        command: nil,
        error: nil
      )
    )
  }

  private func recordStartupFailure(
    phase: EngineStartupPhase,
    error: EngineClientErrorCode
  ) async {
    await logger.record(
      EngineLogRecord(
        timestamp: now(),
        event: .startupFailed,
        phase: phase,
        command: nil,
        error: error
      )
    )
  }

  public func notifyLifecycleEvent(_ reason: SchedulerTriggerReason) async {
    guard initialized, !quitting, reason == .wake || reason == .networkRegained else { return }
    let wasReady = herdrStatus.state == .ready
    herdrStatus = await external.preflightHerdr()
    let allowed = (try? await dispatchAllowed()) == true
    if !wasReady, herdrStatus.state == .ready {
      do {
        try await runtime.reload(dispatchAllowed: allowed)
      } catch {
        await runtime.setDispatchAllowed(false)
        return
      }
    } else {
      await runtime.setDispatchAllowed(allowed)
    }
    guard herdrStatus.state == .ready else { return }
    await runtime.requestLifecyclePass(reason)
  }

  public func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    do {
      try command.validate()
      guard !commandInProgress else {
        throw EngineClientError(.busy)
      }
      commandInProgress = true
      defer { commandInProgress = false }
      guard initialized else {
        throw EngineClientError(.unavailable)
      }
      if quitting, command.kind != .snapshot {
        throw EngineClientError(.busy)
      }
      let response = try await perform(command)
      await logger.record(
        EngineLogRecord(
          timestamp: now(),
          event: .commandSucceeded,
          command: command.kind,
          error: nil
        )
      )
      return response
    } catch let error as EngineClientError {
      await logger.record(
        EngineLogRecord(
          timestamp: now(),
          event: .commandRejected,
          command: command.kind,
          error: error.code
        )
      )
      throw error
    } catch {
      let mapped = EngineClientError(Self.errorCode(for: command.kind))
      await logger.record(
        EngineLogRecord(
          timestamp: now(),
          event: .commandRejected,
          command: command.kind,
          error: mapped.code
        )
      )
      throw mapped
    }
  }

  private func perform(_ command: EngineCommand) async throws -> EngineCommandResponse {
    let checkpoint: EngineCheckpointReceipt?
    var jobMaintenance: JobMaintenanceReport? = nil
    var jobCanary: JobCanaryReport? = nil
    var jobCanaryRecovery: JobCanaryRecoveryReport? = nil
    var jobCanaryPiRetry: JobCanaryPiRetryReport? = nil
    var jobCanaryRoleHostReplacement: JobCanaryRoleHostReplacementReport? = nil
    var jobCanaryGenerationRollover: JobCanaryGenerationRolloverReport? = nil
    var jobCanaryGenerationRolloverQ4: JobCanaryGenerationRolloverQ4Report? = nil
    var rolloutPreview: RolloutPreview? = nil
    var rolloutRecoveryPreview: RolloutRecoveryPreview? = nil
    switch command {
    case .snapshot:
      checkpoint = nil
    case .refreshModelCatalog:
      modelCatalog = .unavailable
      do {
        modelCatalog = try await external.discoverModelCatalog()
      } catch {
        didMutate()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .acknowledgeExternalAutomation(let acknowledged):
      try await configuration.setExternalAutomationAcknowledged(acknowledged, now: now())
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .acknowledgeProviderDisclosure(let acknowledged):
      try await configuration.setProviderDisclosureAcknowledged(acknowledged, now: now())
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .runPiPreflight:
      piStatus = await external.preflightPi()
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .runHerdrPreflight:
      herdrStatus = await external.preflightHerdr()
      try await runtime.reload(dispatchAllowed: try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .focusInHerdr:
      guard herdrStatus.state == .ready else {
        throw EngineClientError(.herdrBlocked)
      }
      try await runtime.focusInHerdr()
      checkpoint = nil
      didMutate()
    case .replaceCredential(let token):
      try await runtime.beginExclusiveOperation()
      do {
        let hasNonterminalJobs = !(try await jobs.jobs(nonTerminalOnly: true)).isEmpty
        credentialStatus = try await external.replaceCredential(
          token,
          allowAccountChange: !hasNonterminalJobs
        )
        try await runtime.reload(dispatchAllowed: try await dispatchAllowed())
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.setDispatchAllowed(false)
        await runtime.endExclusiveOperation()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .deleteCredential:
      try await runtime.beginExclusiveOperation()
      do {
        guard try await jobs.jobs(nonTerminalOnly: true).isEmpty,
          try await jobs.ambiguousDispositions().isEmpty
        else {
          throw EngineClientError(.credentialInUse)
        }
        try await external.deleteCredential()
        credentialStatus = .missing
        await runtime.setDispatchAllowed(false)
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.setDispatchAllowed(false)
        await runtime.endExclusiveOperation()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .addRepository(let draft):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      let existing = try await configuration.repositories().first {
        $0.owner.caseInsensitiveCompare(draft.owner) == .orderedSame
          && $0.name.caseInsensitiveCompare(draft.name) == .orderedSame
      }
      let repository = try await external.validateRepository(draft, existingID: existing?.id)
      try await configuration.upsertRepository(repository, now: now())
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .updateRepository(let repository):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      guard let existing = try await configuration.repository(id: repository.id),
        existing.nodeID == repository.nodeID,
        existing.owner == repository.owner,
        existing.name == repository.name,
        existing.defaultBranch == repository.defaultBranch
      else {
        throw EngineClientError(.repositoryRejected)
      }
      try await configuration.upsertRepository(repository, now: now())
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .removeRepository(let id):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      guard
        try await jobs.jobs(nonTerminalOnly: true).allSatisfy({
          $0.identity.repositoryID != id
        })
      else {
        throw EngineClientError(.busy)
      }
      try await configuration.removeRepository(id: id)
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .setProfile(let profile):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      try await runtime.beginExclusiveOperation()
      do {
        try await configuration.setProfileAndInvalidateProviderDisclosure(profile, now: now())
        try await runtime.reload(dispatchAllowed: false)
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.setDispatchAllowed(false)
        await runtime.endExclusiveOperation()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .setMaxConcurrency(let value):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      try await configuration.setMaxConcurrency(value, now: now())
      checkpoint = nil
      didMutate()
    case .setPaused(let paused):
      let rollout = try await runtime.rolloutStatus()
      guard paused, rollout?.authorization.state.isOpenLane != true else {
        throw EngineClientError(.invalidCommand)
      }
      if paused { await runtime.prepareForPause() }
      do {
        try await configuration.setPaused(paused, now: now())
      } catch ConfigurationStoreError.generationRolloverRequiresAuthorization {
        if paused { await runtime.setDispatchAllowed(try await dispatchAllowed()) }
        throw EngineClientError(.staleEvidence)
      } catch {
        if paused { await runtime.setDispatchAllowed(try await dispatchAllowed()) }
        throw error
      }
      if paused {
        await runtime.waitForPauseDrain()
        await runtime.setDispatchAllowed(false)
        await runtime.setPaused(true)
      } else {
        await runtime.setPaused(false)
        await runtime.setDispatchAllowed(try await dispatchAllowed())
      }
      checkpoint = nil
      didMutate()
    case .pollNow:
      guard let rollout = try await runtime.rolloutStatus(),
        rollout.authorization.state == .active,
        rollout.scope.mode == .finiteWindow
      else {
        throw EngineClientError(.invalidCommand)
      }
      await runtime.pollNow()
      checkpoint = nil
      didMutate()
    case .previewRollout(let input), .previewFiniteWindow(let input):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      let preview = try await runtime.previewRollout(input)
      try await external.revalidateRollout(preview)
      rolloutPreview = preview
      checkpoint = nil
    case .activateRollout(let request), .activateFiniteWindow(let request):
      guard try await rolloutActivationReady() else {
        throw EngineClientError(.onboardingIncomplete)
      }
      let approved = try RolloutPreviewBuilder.parseCanonical(
        request.approvedCanonicalJSON
      )
      try await external.revalidateRollout(approved)
      _ = try await runtime.activateRollout(request)
      await runtime.setPaused(false)
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      await runtime.pollNow()
      _ = try await database.checkpoint()
      checkpoint = try await checkpointReceipt()
      didMutate()
    case .rolloutStatus:
      _ = try await runtime.rolloutStatus()
      checkpoint = nil
    case .stopAndDrainRollout(let request):
      _ = try await runtime.stopAndDrainRollout(request)
      await runtime.setDispatchAllowed(false)
      await runtime.setPaused(true)
      _ = try await database.checkpoint()
      checkpoint = try await checkpointReceipt()
      didMutate()
    case .previewRolloutRecovery(let request):
      rolloutRecoveryPreview = try await runtime.previewRolloutRecovery(request)
      checkpoint = nil
    case .executeRolloutRecovery(let authorization):
      guard try await rolloutActivationReady() else {
        throw EngineClientError(.onboardingIncomplete)
      }
      try await runtime.beginExclusiveOperation()
      do {
        let report = try await runtime.executeRolloutRecovery(authorization)
        let resumeDispatch =
          report.authorization.state == .active
          ? try await dispatchAllowed() : false
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
        if resumeDispatch {
          await runtime.setPaused(false)
          await runtime.setDispatchAllowed(true)
          await runtime.pollNow()
        }
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .recheckAmbiguousMutation(let evidence):
      try await runtime.beginExclusiveOperation()
      do {
        _ = try await exactAmbiguousMutation(matching: evidence)
        try await runtime.recheckAmbiguousMutation(jobID: evidence.jobID)
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .authorizeRetry(let evidence):
      try await runtime.beginExclusiveOperation()
      do {
        _ = try await exactAmbiguousMutation(matching: evidence)
        _ = try await jobs.transition(
          jobID: evidence.jobID,
          eventKey:
            "ui:\(evidence.jobID.uuidString.lowercased()):g\(evidence.mutationGeneration):authorize-retry",
          event: .humanRetryAuthorized,
          context: JobTransitionContext(
            now: now(),
            reason: "human authorized exact ambiguous mutation retry"
          )
        )
        await runtime.pollNow()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      checkpoint = nil
      didMutate()
    case .previewJobMaintenance(let scope):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      jobMaintenance = try await jobs.previewMaintenance(scope: scope)
      checkpoint = nil
    case .applyJobMaintenance(let authorization):
      guard try await configuration.appConfiguration().paused else {
        throw EngineClientError(.busy)
      }
      try await runtime.beginExclusiveOperation()
      do {
        let application = try await jobs.applyMaintenance(authorization, now: now())
        if authorization.scope.operation == .retireBefore {
          try await runtime.cleanupRetiredJobs(
            jobIDs: application.jobIDs,
            evidenceSHA256: authorization.evidenceSHA256
          )
        }
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        jobMaintenance = application.report
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanary(let scope):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanary = try await jobs.previewCanary(
        scope: scope,
        resourceTreeSHA256: try await runtime.canaryResourceTreeSHA256()
      )
      checkpoint = nil
    case .executeJobCanary(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        jobCanary = try await runtime.executeCanary(authorization)
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanaryRecovery(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanaryRecovery = try await runtime.previewCanaryRecovery(authorization)
      checkpoint = nil
    case .executeJobCanaryRecovery(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        let execution = try await runtime.executeCanaryRecovery(authorization)
        jobCanaryRecovery = execution.recovery
        jobCanary = execution.canary
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanaryPiRetry(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanaryPiRetry = try await runtime.previewCanaryPiRetry(authorization)
      checkpoint = nil
    case .executeJobCanaryPiRetry(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        let execution = try await runtime.executeCanaryPiRetry(authorization)
        jobCanaryPiRetry = execution.retry
        jobCanary = execution.canary
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanaryRoleHostReplacement(let request):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanaryRoleHostReplacement = try await runtime.previewCanaryRoleHostReplacement(
        request
      )
      checkpoint = nil
    case .executeJobCanaryRoleHostReplacement(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready,
        herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        let execution = try await runtime.executeCanaryRoleHostReplacement(authorization)
        jobCanaryRoleHostReplacement = execution.replacement
        jobCanary = execution.canary
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanaryGenerationRollover(let request):
      guard try await configuration.appConfiguration().paused,
        piStatus.state == .ready, herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanaryGenerationRollover = try await runtime.previewCanaryGenerationRollover(
        request
      )
      checkpoint = nil
    case .executeJobCanaryGenerationRollover(let authorization):
      guard try await configuration.appConfiguration().paused,
        piStatus.state == .ready, herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        jobCanaryGenerationRollover = try await runtime.executeCanaryGenerationRollover(
          authorization
        )
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .previewJobCanaryGenerationRolloverQ4(let request):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready, herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      jobCanaryGenerationRolloverQ4 = try await runtime.previewCanaryGenerationRolloverQ4(
        request
      )
      checkpoint = nil
    case .executeJobCanaryGenerationRolloverQ4(let authorization):
      guard try await configuration.appConfiguration().paused,
        credentialStatus.state == .valid,
        piStatus.state == .ready, herdrStatus.state == .ready
      else { throw EngineClientError(.busy) }
      try await runtime.beginExclusiveOperation()
      do {
        jobCanaryGenerationRolloverQ4 = try await runtime.executeCanaryGenerationRolloverQ4(
          authorization
        )
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        await runtime.endExclusiveOperation()
      } catch {
        await runtime.endExclusiveOperation()
        throw error
      }
      didMutate()
    case .setLoginEnabled(let selected):
      let current = try await configuration.appConfiguration()
      try await configuration.setLoginItem(
        selected: selected,
        status: selected ? current.loginItemStatus : .notRegistered,
        now: now()
      )
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .synchronizeLoginStatus(let selected, let status):
      try await configuration.setLoginItem(selected: selected, status: status, now: now())
      await runtime.setDispatchAllowed(try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .completeOnboarding:
      let state = try await makeState()
      guard Self.onboardingReady(state.onboarding) else {
        throw EngineClientError(.onboardingIncomplete)
      }
      do {
        try await configuration.setOnboardingComplete(true, now: now())
      } catch ConfigurationStoreError.generationRolloverRequiresAuthorization {
        throw EngineClientError(.staleEvidence)
      }
      try await runtime.reload(dispatchAllowed: try await dispatchAllowed())
      checkpoint = nil
      didMutate()
    case .rollbackOnboarding:
      try await configuration.setOnboardingComplete(false, now: now())
      await runtime.setDispatchAllowed(false)
      checkpoint = nil
      didMutate()
    case .prepareForHandoff:
      try await runtime.waitUntilIdle()
      _ = try await database.checkpoint()
      checkpoint = try await checkpointReceipt()
      didMutate()
    case .prepareForQuit:
      quitting = true
      do {
        await runtime.prepareForPause()
        try await configuration.setPaused(true, now: now())
        await runtime.waitForPauseDrain()
        await runtime.setPaused(true)
        try await runtime.prepareForCheckpoint()
        _ = try await database.checkpoint()
        checkpoint = try await checkpointReceipt()
        didMutate()
      } catch {
        _ = try? await database.checkpoint()
        checkpoint = try? await checkpointReceipt()
        quitting = false
        throw error
      }
    }
    return EngineCommandResponse(
      command: command.kind,
      state: try await makeState(),
      checkpoint: checkpoint,
      jobMaintenance: jobMaintenance,
      jobCanary: jobCanary,
      jobCanaryRecovery: jobCanaryRecovery,
      jobCanaryPiRetry: jobCanaryPiRetry,
      jobCanaryRoleHostReplacement: jobCanaryRoleHostReplacement,
      jobCanaryGenerationRollover: jobCanaryGenerationRollover,
      jobCanaryGenerationRolloverQ4: jobCanaryGenerationRolloverQ4,
      rolloutPreview: rolloutPreview,
      rolloutRecoveryPreview: rolloutRecoveryPreview
    )
  }

  private func dispatchAllowed() async throws -> Bool {
    let snapshot = try await configuration.snapshot()
    return snapshot.app.onboardingComplete
      && snapshot.app.externalAutomationAcknowledged
      && snapshot.app.providerDisclosureAcknowledged
      && snapshot.app.loginItemSelected
      && snapshot.app.loginItemStatus == .enabled
      && !snapshot.app.paused
      && credentialStatus.state == .valid
      && piStatus.state == .ready
      && herdrStatus.state == .ready
      && snapshot.repositories.contains(where: { $0.enabled })
      && Set(snapshot.profiles.map(\.role)) == Set(ModelProfileRole.allCases)
  }

  private func rolloutActivationReady() async throws -> Bool {
    let snapshot = try await configuration.snapshot()
    return snapshot.app.onboardingComplete
      && snapshot.app.externalAutomationAcknowledged
      && snapshot.app.providerDisclosureAcknowledged
      && snapshot.app.loginItemSelected
      && snapshot.app.loginItemStatus == .enabled
      && snapshot.app.paused
      && snapshot.app.maxConcurrency == 1
      && snapshot.app.githubAccount != nil
      && snapshot.app.githubAuthorID.map({ $0 > 0 }) == true
      && credentialStatus.state == .valid
      && piStatus.state == .ready
      && herdrStatus.state == .ready
      && Set(snapshot.profiles.map(\.role)) == Set(ModelProfileRole.allCases)
  }

  private func makeState() async throws -> EngineUIState {
    let configuration = try await configuration.snapshot()
    let currentJobs = try await jobs.jobs(nonTerminalOnly: true)
    let ambiguous = try await ambiguousMutations(
      dispositions: try await jobs.ambiguousDispositions(),
      jobs: currentJobs,
      repositories: configuration.repositories
    )
    let timing = await runtime.timingSnapshot()
    let coordinator = await runtime.coordinatorSnapshot()
    let rollout = try await runtime.rolloutStatus()
    let rolloutReport: RolloutOperatorReport?
    if let rollout {
      rolloutReport = try await operatorReport(rollout)
    } else {
      rolloutReport = nil
    }
    let coordinatorFailures =
      coordinator?.failures.map {
        "\($0.stage):\($0.errorType)"
      }.sorted() ?? []
    let lifecycle: EngineLifecycleState =
      quitting ? .quitting : configuration.app.onboardingComplete ? .ready : .onboarding
    let operationalStatus: EngineOperationalStatus
    if !ambiguous.isEmpty || !coordinatorFailures.isEmpty
      || (configuration.app.onboardingComplete && piStatus.state == .blocked)
      || (configuration.app.onboardingComplete && herdrStatus.state == .blocked)
      || (configuration.app.onboardingComplete && credentialStatus.state != .valid)
      || (configuration.app.onboardingComplete
        && (!configuration.app.loginItemSelected
          || configuration.app.loginItemStatus != .enabled))
    {
      operationalStatus = .warning
    } else if timing?.passRunning == true {
      operationalStatus = .running
    } else if configuration.app.paused {
      operationalStatus = .paused
    } else {
      operationalStatus = .active
    }
    let roles = configuration.profiles.map(\.role).sorted(by: Self.rolePrecedes)
    let onboarding = EngineOnboardingSnapshot(
      duplicateInstanceCheckPassed: duplicateInstanceCheckPassed,
      externalAutomationAcknowledged: configuration.app.externalAutomationAcknowledged,
      providerDisclosureAcknowledged: configuration.app.providerDisclosureAcknowledged,
      pi: piStatus,
      herdr: herdrStatus,
      credential: credentialStatus,
      repositoryCount: configuration.repositories.count,
      configuredProfileRoles: roles,
      loginItemSelected: configuration.app.loginItemSelected,
      loginItemStatus: configuration.app.loginItemStatus,
      complete: configuration.app.onboardingComplete
    )
    return EngineUIState(
      revision: revision,
      lifecycle: lifecycle,
      operationalStatus: operationalStatus,
      paused: configuration.app.paused,
      passRunning: timing?.passRunning ?? false,
      activities: Self.activities(currentJobs, repositories: configuration.repositories),
      ambiguousMutations: ambiguous,
      onboarding: onboarding,
      settings: EngineSettingsSnapshot(
        repositories: configuration.repositories,
        profiles: configuration.profiles,
        maxConcurrency: configuration.app.maxConcurrency,
        loginItemSelected: configuration.app.loginItemSelected,
        loginItemStatus: configuration.app.loginItemStatus,
        credential: credentialStatus,
        herdr: herdrStatus,
        modelCatalog: modelCatalog
      ),
      diagnostics: EngineDiagnostics(
        schemaVersion: try await database.schemaVersion(),
        nonterminalJobCount: currentJobs.count,
        ambiguousMutationCount: ambiguous.count,
        coordinatorFailureCodes: coordinatorFailures,
        piIssueCode: piStatus.issueCode,
        herdrIssueCode: herdrStatus.issueCode
      ),
      rollout: rolloutReport
    )
  }

  private func operatorReport(_ status: RolloutStatusReport) async throws
    -> RolloutOperatorReport
  {
    var boundJobs: [RolloutOperatorJob] = []
    boundJobs.reserveCapacity(status.boundJobIDs.count)
    for id in status.boundJobIDs {
      guard let job = try await jobs.job(id: id) else {
        throw EngineClientError(.invalidResponse)
      }
      boundJobs.append(
        RolloutOperatorJob(
          id: job.id,
          kind: job.identity.kind,
          objectNumber: job.objectNumber,
          revisionKey: job.identity.revisionKey,
          state: job.state,
          attempt: job.attempt,
          currentStep: job.currentStep,
          currentStepKind: job.currentStepKind,
          terminalReason: job.terminalReason
        )
      )
    }
    let checkpoint = status.events.last(where: {
      $0.kind == .settled || $0.kind == .recoveryRequired || $0.kind == .failed
        || $0.kind == .revoked || $0.kind == .expired
    })?.checkpointSHA256
    return RolloutOperatorReport(
      status: status,
      jobs: boundJobs,
      checkpointSHA256: checkpoint
    )
  }

  private func ambiguousMutations(
    dispositions: [ObjectDispositionRecord],
    jobs currentJobs: [JobRecord],
    repositories: [RepositoryConfiguration]
  ) async throws -> [EngineAmbiguousMutation] {
    let jobsByID = Dictionary(uniqueKeysWithValues: currentJobs.map { ($0.id, $0) })
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var values: [EngineAmbiguousMutation] = []
    for disposition in dispositions {
      guard let jobID = disposition.lastJobID,
        let job = jobsByID[jobID],
        job.state == .awaitingResolution,
        let repository = repositoriesByID[disposition.identity.repositoryID]
      else {
        continue
      }
      let mutationIntents = try await intents.intents(jobID: jobID)
      let latest = mutationIntents.last(where: {
        $0.state == .escalated || $0.state == .reconcileRequired
      })
      let evidence =
        disposition.evidenceDigest ?? latest?.readBackEvidence
        ?? GitHubMarkerCodec.sha256(
          Data(
            [
              jobID.uuidString.lowercased(),
              disposition.identity.revisionKey,
              String(disposition.mutationGeneration),
              latest?.id.uuidString.lowercased() ?? "no-intent",
            ].joined(separator: "|").utf8
          )
        )
      values.append(
        EngineAmbiguousMutation(
          jobID: jobID,
          repositoryID: repository.id,
          repositoryOwner: repository.owner,
          repositoryName: repository.name,
          kind: disposition.identity.kind,
          objectNodeID: disposition.identity.objectNodeID,
          objectNumber: job.objectNumber,
          revisionKey: disposition.identity.revisionKey,
          evidenceDigest: evidence,
          mutationGeneration: disposition.mutationGeneration,
          mutationID: latest?.id.uuidString.lowercased() ?? disposition.lastMutationID
        )
      )
    }
    return values.sorted {
      if $0.repositoryOwner != $1.repositoryOwner {
        return $0.repositoryOwner < $1.repositoryOwner
      }
      if $0.repositoryName != $1.repositoryName {
        return $0.repositoryName < $1.repositoryName
      }
      return $0.jobID.uuidString < $1.jobID.uuidString
    }
  }

  private func exactAmbiguousMutation(
    matching evidence: EngineAmbiguousMutationEvidence
  ) async throws -> EngineAmbiguousMutation {
    let state = try await makeState()
    guard let current = state.ambiguousMutations.first(where: { $0.jobID == evidence.jobID }),
      EngineAmbiguousMutationEvidence(current) == evidence
    else {
      throw EngineClientError(.staleEvidence)
    }
    return current
  }

  private func checkpointReceipt() async throws -> EngineCheckpointReceipt {
    EngineCheckpointReceipt(
      checkpointID: UUID(),
      completedAt: now(),
      nonterminalJobCount: try await jobs.jobs(nonTerminalOnly: true).count,
      ambiguousMutationCount: try await jobs.ambiguousDispositions().count,
      databaseCheckpointed: true
    )
  }

  private func didMutate() {
    revision &+= 1
  }

  private static func onboardingReady(_ snapshot: EngineOnboardingSnapshot) -> Bool {
    snapshot.duplicateInstanceCheckPassed
      && snapshot.externalAutomationAcknowledged
      && snapshot.providerDisclosureAcknowledged
      && snapshot.pi.state == .ready
      && snapshot.herdr.state == .ready
      && snapshot.credential.state == .valid
      && Set(snapshot.configuredProfileRoles) == Set(ModelProfileRole.allCases)
      && snapshot.loginItemSelected
      && [.enabled, .requiresApproval].contains(snapshot.loginItemStatus)
  }

  private static func activities(
    _ jobs: [JobRecord],
    repositories: [RepositoryConfiguration]
  ) -> [EngineActivity] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    return jobs.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id.uuidString < $1.id.uuidString
    }.prefix(5).map { job in
      let repository = repositoriesByID[job.identity.repositoryID]
      let coordinates = repository.map { "\($0.owner)/\($0.name)" } ?? "Configured repository"
      let object = job.objectNumber.map { " #\($0)" } ?? ""
      let kind: String =
        switch job.identity.kind {
        case .prReview: "pull request review"
        case .issueTriage: "issue triage"
        case .issueImplementation, .complexPlan: "issue implementation"
        }
      return EngineActivity(
        id: job.id.uuidString.lowercased(),
        summary: "\(coordinates): \(kind)\(object), \(Self.stateSummary(job.state)).",
        occurredAt: job.updatedAt
      )
    }
  }

  private static func stateSummary(_ state: JobState) -> String {
    switch state {
    case .discovered, .queued: "queued"
    case .leased, .preparing: "preparing"
    case .runningPi, .executing: "running"
    case .reconciling, .reconciliationQueued: "reconciling"
    case .retryBackoff: "waiting to retry"
    case .waitingHuman: "waiting for approval"
    case .awaitingResolution: "awaiting exact resolution"
    case .succeeded: "completed"
    case .blocked: "blocked"
    }
  }

  private static func rolePrecedes(_ lhs: ModelProfileRole, _ rhs: ModelProfileRole) -> Bool {
    let order: [ModelProfileRole: Int] = [
      .review: 0,
      .triage: 1,
      .planning: 2,
      .orchestration: 3,
    ]
    return order[lhs, default: 0] < order[rhs, default: 0]
  }

  private static func errorCode(for command: EngineCommandKind) -> EngineClientErrorCode {
    switch command {
    case .replaceCredential, .deleteCredential: .credentialRejected
    case .addRepository, .updateRepository, .removeRepository: .repositoryRejected
    case .runPiPreflight: .piBlocked
    case .runHerdrPreflight, .focusInHerdr: .herdrBlocked
    case .setLoginEnabled, .synchronizeLoginStatus: .loginItemFailed
    case .authorizeRetry, .recheckAmbiguousMutation, .previewJobMaintenance,
      .applyJobMaintenance, .previewJobCanary, .executeJobCanary,
      .previewJobCanaryRecovery, .executeJobCanaryRecovery,
      .previewJobCanaryPiRetry, .executeJobCanaryPiRetry,
      .previewJobCanaryRoleHostReplacement, .executeJobCanaryRoleHostReplacement,
      .previewJobCanaryGenerationRollover, .executeJobCanaryGenerationRollover,
      .previewJobCanaryGenerationRolloverQ4, .executeJobCanaryGenerationRolloverQ4:
      .staleEvidence
    case .previewRollout, .activateRollout, .rolloutStatus, .stopAndDrainRollout,
      .previewRolloutRecovery, .executeRolloutRecovery, .previewFiniteWindow,
      .activateFiniteWindow:
      .staleEvidence
    case .completeOnboarding: .onboardingIncomplete
    case .prepareForHandoff, .prepareForQuit: .checkpointFailed
    case .snapshot, .refreshModelCatalog, .acknowledgeExternalAutomation,
      .acknowledgeProviderDisclosure, .setProfile, .setMaxConcurrency, .setPaused, .pollNow,
      .rollbackOnboarding:
      .internalFailure
    }
  }
}
