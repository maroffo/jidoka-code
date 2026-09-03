import Darwin
import Foundation

public struct ProductionEngineRuntimeConfiguration: Sendable {
  public let applicationSupportRoot: URL
  public let piResourceRoot: URL
  public let releaseRuntimeRoot: URL
  public let containingApplicationURL: URL
  public let askPassExecutable: URL
  public let pushGuardExecutable: URL
  public let herdrHostExecutable: URL
  public let herdrSocketURL: URL
  public let contractVersion: String

  public init(
    applicationSupportRoot: URL,
    piResourceRoot: URL,
    releaseRuntimeRoot: URL,
    containingApplicationURL: URL,
    askPassExecutable: URL,
    pushGuardExecutable: URL,
    herdrHostExecutable: URL,
    herdrSocketURL: URL,
    contractVersion: String
  ) throws {
    guard applicationSupportRoot.isFileURL,
      applicationSupportRoot.path.hasPrefix("/"),
      piResourceRoot.isFileURL,
      piResourceRoot.path.hasPrefix("/"),
      releaseRuntimeRoot.isFileURL,
      releaseRuntimeRoot.path.hasPrefix("/"),
      containingApplicationURL.isFileURL,
      containingApplicationURL.path.hasPrefix("/"),
      askPassExecutable.isFileURL,
      askPassExecutable.path.hasPrefix("/"),
      pushGuardExecutable.isFileURL,
      pushGuardExecutable.path.hasPrefix("/"),
      herdrHostExecutable.isFileURL,
      herdrHostExecutable.path.hasPrefix("/"),
      herdrSocketURL.isFileURL,
      herdrSocketURL.path.hasPrefix("/"),
      !contractVersion.isEmpty,
      contractVersion.utf8.count <= 128
    else {
      throw EngineClientError(.internalFailure)
    }
    self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
    self.piResourceRoot = piResourceRoot.standardizedFileURL
    self.releaseRuntimeRoot = releaseRuntimeRoot.standardizedFileURL
    self.containingApplicationURL = containingApplicationURL.standardizedFileURL
    self.askPassExecutable = askPassExecutable.standardizedFileURL
    self.pushGuardExecutable = pushGuardExecutable.standardizedFileURL
    self.herdrHostExecutable = herdrHostExecutable.standardizedFileURL
    self.herdrSocketURL = herdrSocketURL.standardizedFileURL
    self.contractVersion = contractVersion
  }

  #if DEBUG
    init(
      applicationSupportRoot: URL,
      piResourceRoot: URL,
      askPassExecutable: URL,
      pushGuardExecutable: URL,
      herdrHostExecutable: URL,
      herdrSocketURL: URL,
      contractVersion: String
    ) throws {
      try self.init(
        applicationSupportRoot: applicationSupportRoot,
        piResourceRoot: piResourceRoot,
        releaseRuntimeRoot: piResourceRoot.appendingPathComponent("PiRuntime", isDirectory: true),
        containingApplicationURL: piResourceRoot,
        askPassExecutable: askPassExecutable,
        pushGuardExecutable: pushGuardExecutable,
        herdrHostExecutable: herdrHostExecutable,
        herdrSocketURL: herdrSocketURL,
        contractVersion: contractVersion
      )
    }
  #endif
}

private actor EngineDispatchGate {
  private var allowed = false

  func set(_ value: Bool) {
    allowed = value
  }

  func value() -> Bool {
    allowed
  }
}

struct ProductionEngineReloadComposition: Sendable {
  let setSchedulerPaused: @Sendable (Bool) async -> Void
  let recoverCoordinatorAtStartup: @Sendable () async throws -> Void
  let runStartupPass: @Sendable (SchedulerPass) async -> Void
  let requestStartup: @Sendable () async -> Void
}

struct ProductionRoleHostReplacementCandidate: Sendable {
  let report: JobCanaryRoleHostReplacementReport
  let activate: @Sendable () async throws -> Void
}

struct ProductionRoleHostReplacementBoundary: Sendable {
  let terminalReport:
    @Sendable (JobCanaryRoleHostReplacementRequest, Bool) async throws
      -> JobCanaryRoleHostReplacementReport?
  let resourceTreeSHA256: @Sendable () async throws -> String
  let admitCanary: @Sendable (JobCanaryAuthorization, String) async throws -> JobCanaryApplication
  let candidate:
    @Sendable (JobCanaryRoleHostReplacementAuthorization, String) async throws
      -> ProductionRoleHostReplacementCandidate
  let beginMarker: @Sendable (UUID) async throws -> Void
  let endMarker: @Sendable () async -> Void
  let beginLaunchAdmission: @Sendable (UUID) async -> Void
  let endLaunchAdmission: @Sendable () async -> Void
  let runCoordinator: @Sendable (JobCanaryRoleHostReplacementRequest) async throws -> Void
}

private struct ProductionJobComponents: Sendable {
  let coordinator: JobCoordinator
  let scheduler: DurableScheduler
  let workflows: JobWorkflowRegistry
  let herdrRuntime: HerdrPiWorkflowRuntime
  let repositories: RepositoryStore
  let canaryMarkerGate: JobCanaryMarkerAuthorizationGate

  var reloadComposition: ProductionEngineReloadComposition {
    ProductionEngineReloadComposition(
      setSchedulerPaused: { paused in await scheduler.setPaused(paused) },
      recoverCoordinatorAtStartup: { try await coordinator.recoverAtStartup() },
      runStartupPass: { pass in await coordinator.run(pass: pass) },
      requestStartup: { await scheduler.request(.startup) }
    )
  }
}

public actor ProductionEngineJobRuntime: EngineJobRuntime {
  private static let idleWaitLimitSeconds: TimeInterval = 660

  private let runtimeConfiguration: ProductionEngineRuntimeConfiguration
  private let database: SQLiteStore
  private let configuration: ConfigurationStore
  private let jobs: DurableJobStore
  private let intents: MutationIntentStore
  private let dispatchGate = EngineDispatchGate()
  private let herdrReadiness: any HerdrRuntimeReadinessChecking
  private let commandRuns: ApprovedCommandRunStore
  private let commandGate = ApprovedCommandExecutionGate()
  private let clock: any SchedulerClock
  private let logger: any EngineEventLogging
  private let now: @Sendable () -> Date
  private let reloadComposition: ProductionEngineReloadComposition?
  private let roleHostReplacementBoundary: ProductionRoleHostReplacementBoundary?

  private var components: ProductionJobComponents?
  private var ownershipRuntime: HerdrPiWorkflowRuntime?
  private var schedulerTask: Task<Void, Never>?
  private var desiredDispatchAllowed = false
  private var paused = false
  private var exclusiveOperations = 0
  private var checkpointing = false
  private var initialReload = true

  public init(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    herdrReadiness: any HerdrRuntimeReadinessChecking,
    clock: any SchedulerClock = SystemSchedulerClock(),
    logger: any EngineEventLogging = NullEngineEventLogger(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.runtimeConfiguration = runtimeConfiguration
    self.database = database
    self.configuration = configuration
    self.jobs = jobs
    self.intents = intents
    self.herdrReadiness = herdrReadiness
    commandRuns = ApprovedCommandRunStore(database: database, now: now)
    self.clock = clock
    self.logger = logger
    self.now = now
    reloadComposition = nil
    roleHostReplacementBoundary = nil
  }

  init(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    herdrReadiness: any HerdrRuntimeReadinessChecking,
    ownershipRuntime: HerdrPiWorkflowRuntime?,
    reloadComposition: ProductionEngineReloadComposition,
    roleHostReplacementBoundary: ProductionRoleHostReplacementBoundary? = nil,
    clock: any SchedulerClock = SystemSchedulerClock(),
    logger: any EngineEventLogging = NullEngineEventLogger(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.runtimeConfiguration = runtimeConfiguration
    self.database = database
    self.configuration = configuration
    self.jobs = jobs
    self.intents = intents
    self.herdrReadiness = herdrReadiness
    self.ownershipRuntime = ownershipRuntime
    self.reloadComposition = reloadComposition
    self.roleHostReplacementBoundary = roleHostReplacementBoundary
    commandRuns = ApprovedCommandRunStore(database: database, now: now)
    self.clock = clock
    self.logger = logger
    self.now = now
  }

  public func reload(dispatchAllowed: Bool) async throws {
    let recordsStartupPhases = initialReload
    defer { initialReload = false }
    await recordInitialReloadPhase(.runtimeQuiesce, enabled: recordsStartupPhases)
    desiredDispatchAllowed = dispatchAllowed
    checkpointing = false
    await dispatchGate.set(false)
    await ownershipRuntime?.setLaunchAllowed(false)
    await commandGate.closeAndWait()
    try await waitUntilSchedulerIdle()
    await stopScheduler()
    await recordInitialReloadPhase(.runtimeSnapshot, enabled: recordsStartupPhases)
    let snapshot = try await configuration.snapshot()
    paused = snapshot.app.paused
    let account = snapshot.app.githubAccount
    let authorID = snapshot.app.githubAuthorID
    let readiness = await herdrReadiness.preflight()
    let durableOwnershipCount =
      try await database.scalarInt(
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE state IN ('prepared', 'waiting', 'running', 'stopping')
        """
      ) ?? 0
    await recordInitialReloadPhase(.runtimeOwnership, enabled: recordsStartupPhases)
    guard
      ownershipRuntime != nil || durableOwnershipCount > 0
        || (account != nil && authorID.map({ $0 > 0 }) == true)
    else {
      _ = try await commandRuns.recoverAtStartup()
      components = nil
      return
    }
    let herdrRuntime: HerdrPiWorkflowRuntime
    if let ownershipRuntime {
      herdrRuntime = ownershipRuntime
    } else {
      herdrRuntime = try Self.makeHerdrRuntime(
        runtimeConfiguration: runtimeConfiguration,
        database: database,
        configuration: configuration,
        jobs: jobs,
        now: now
      )
      ownershipRuntime = herdrRuntime
    }
    await recordInitialReloadPhase(.runtimeRecovery, enabled: recordsStartupPhases)
    guard readiness.state == .ready else {
      try await herdrRuntime.recoverDurableResults()
      _ = try await commandRuns.recoverAtStartup()
      components = nil
      return
    }
    if reloadComposition == nil {
      try await herdrRuntime.recoverDurableState()
    } else {
      try await herdrRuntime.recoverDurableResults()
    }
    _ = try await commandRuns.recoverAtStartup()
    await recordInitialReloadPhase(.runtimeComponents, enabled: recordsStartupPhases)
    let activeReloadComposition: ProductionEngineReloadComposition
    if let reloadComposition {
      components = nil
      activeReloadComposition = reloadComposition
    } else {
      guard let account, let authorID, authorID > 0 else {
        components = nil
        return
      }
      let built = try Self.build(
        runtimeConfiguration: runtimeConfiguration,
        database: database,
        configuration: configuration,
        jobs: jobs,
        intents: intents,
        account: account,
        authorID: authorID,
        profiles: snapshot.profiles,
        herdrRuntime: herdrRuntime,
        commandRuns: commandRuns,
        commandGate: commandGate,
        dispatchGate: dispatchGate,
        clock: clock,
        now: now
      )
      components = built
      activeReloadComposition = built.reloadComposition
    }
    await activeReloadComposition.setSchedulerPaused(paused)
    await recordInitialReloadPhase(.runtimeCoordinatorRecovery, enabled: recordsStartupPhases)
    try await activeReloadComposition.recoverCoordinatorAtStartup()
    let startupExecutionAllowed =
      desiredDispatchAllowed && !paused && exclusiveOperations == 0
    await herdrRuntime.setLaunchAllowed(startupExecutionAllowed)
    if startupExecutionAllowed { await commandGate.open() }
    await recordInitialReloadPhase(.runtimeStartupPass, enabled: recordsStartupPhases)
    if startupExecutionAllowed {
      await activeReloadComposition.runStartupPass(
        SchedulerPass(reasons: [.startup], startedAt: now())
      )
    }
    await applyDispatchGate()
    if startupExecutionAllowed {
      await activeReloadComposition.requestStartup()
    }
    if exclusiveOperations == 0, !checkpointing {
      startScheduler()
    }
  }

  public func setDispatchAllowed(_ allowed: Bool) async {
    desiredDispatchAllowed = allowed
    await applyDispatchGate()
  }

  public func prepareForPause() async {
    await dispatchGate.set(false)
    await ownershipRuntime?.closeLaunchAdmission()
    await commandGate.close()
  }

  public func waitForPauseDrain() async {
    await ownershipRuntime?.waitForLaunchAdmissionDrain()
    await commandGate.waitUntilIdle()
  }

  public func setPaused(_ paused: Bool) async {
    self.paused = paused
    await components?.scheduler.setPaused(paused)
    await applyDispatchGate()
  }

  public func pollNow() async {
    await components?.scheduler.request(.manual)
  }

  public func requestLifecyclePass(_ reason: SchedulerTriggerReason) async {
    guard reason == .wake || reason == .networkRegained else { return }
    await components?.scheduler.request(reason)
  }

  public func beginExclusiveOperation() async throws {
    guard exclusiveOperations == 0, !checkpointing else {
      throw EngineClientError(.busy)
    }
    exclusiveOperations = 1
    await dispatchGate.set(false)
    await ownershipRuntime?.setLaunchAllowed(false)
    await commandGate.closeAndWait()
    await stopScheduler()
  }

  public func endExclusiveOperation() async {
    guard exclusiveOperations > 0 else { return }
    exclusiveOperations -= 1
    if exclusiveOperations == 0, !checkpointing {
      startScheduler()
    }
    await applyDispatchGate()
  }

  public func recheckAmbiguousMutation(jobID: UUID) async throws {
    guard exclusiveOperations == 1, let components,
      let job = try await jobs.job(id: jobID),
      job.state == .awaitingResolution
    else {
      throw EngineClientError(.staleEvidence)
    }
    try await components.workflows.workflow(for: job.identity.kind).run(jobID: jobID)
  }

  public func cleanupRetiredJobs(
    jobIDs: [UUID],
    evidenceSHA256: String
  ) async throws {
    guard exclusiveOperations == 1,
      GitHubInputValidation.validSHA256(evidenceSHA256)
    else {
      throw EngineClientError(.busy)
    }
    let repositories: RepositoryStore
    if let components {
      repositories = components.repositories
    } else {
      repositories = try maintenanceRepositoryStore()
    }
    for jobID in jobIDs {
      guard let job = try await jobs.job(id: jobID), job.state == .blocked,
        try await jobs.disposition(for: job.identity)?.state == .superseded
      else {
        throw EngineClientError(.staleEvidence)
      }
      guard let workspace = try await repositories.workspaceRecord(jobID: jobID) else {
        continue
      }
      if workspace.cleanupState == .retained {
        guard try await repositories.workspaceIsCleanAtRecordedHead(jobID: jobID) else {
          throw EngineClientError(.staleEvidence)
        }
        try await repositories.authorizeOperatorRetirementCleanup(
          jobID: jobID,
          evidenceSHA256: evidenceSHA256,
          now: now()
        )
      }
      try await repositories.cleanupWorkspace(jobID: jobID, now: now())
    }
  }

  public func canaryResourceTreeSHA256() async throws -> String {
    do {
      return try PackagedPiResourceSnapshot.inspect(
        resourceRoot: runtimeConfiguration.piResourceRoot
      )
    } catch {
      throw EngineClientError(.staleEvidence)
    }
  }

  public func executeCanary(
    _ authorization: JobCanaryAuthorization
  ) async throws -> JobCanaryReport {
    guard exclusiveOperations == 1, paused, let components else {
      throw EngineClientError(.busy)
    }
    let resource = try await canaryResourceTreeSHA256()
    let application = try await jobs.admitCanary(
      authorization,
      resourceTreeSHA256: resource,
      now: now()
    )
    guard application.shouldExecute else {
      if application.report.status == .recoveryRequired,
        let job = try await jobs.job(id: authorization.scope.jobID),
        [.succeeded, .blocked, .waitingHuman, .retryBackoff, .awaitingResolution].contains(
          job.state)
      {
        return try await requireSuccessfulCanary(
          try await jobs.closeCanary(
            authorization: authorization,
            resourceTreeSHA256: resource,
            now: now()
          )
        )
      }
      return try await requireSuccessfulCanary(application.report)
    }
    try await components.canaryMarkerGate.begin(jobID: authorization.scope.jobID)
    await components.herdrRuntime.beginCanaryLaunchAdmission(
      jobID: authorization.scope.jobID
    )
    do {
      try await components.coordinator.runCanary(jobID: authorization.scope.jobID)
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      do {
        let report = try await jobs.closeCanary(
          authorization: authorization,
          resourceTreeSHA256: resource,
          now: now()
        )
        return try await requireSuccessfulCanary(report)
      } catch DurableJobStoreError.canaryRecoveryRequired {
        let report = application.report
        return JobCanaryReport(
          scope: report.scope,
          previewEvidenceSHA256: report.previewEvidenceSHA256,
          authorizationSHA256: report.authorizationSHA256,
          status: .recoveryRequired,
          repositoryOwner: report.repositoryOwner,
          repositoryName: report.repositoryName,
          objectNumber: report.objectNumber,
          revisionKey: report.revisionKey,
          provider: report.provider,
          model: report.model,
          thinking: report.thinking,
          resourceTreeSHA256: report.resourceTreeSHA256,
          replayed: false
        )
      }
    } catch {
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      throw error
    }
  }

  public func previewCanaryRecovery(
    _ authorization: JobCanaryAuthorization
  ) async throws -> JobCanaryRecoveryReport {
    guard exclusiveOperations == 0, paused, let components else {
      throw EngineClientError(.busy)
    }
    let resource = try await canaryResourceTreeSHA256()
    let candidate = try await components.herdrRuntime.canaryRecoveryCandidate(
      authorization: authorization,
      resourceTreeSHA256: resource
    )
    guard
      let report = candidate.evidence.report(
        authorization: nil,
        status: .preview,
        replayed: false
      )
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  public func executeCanaryRecovery(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryRecoveryExecution {
    guard exclusiveOperations == 1, paused, let components else {
      throw EngineClientError(.busy)
    }
    let resource = try await canaryResourceTreeSHA256()
    let existing = try await jobs.admitCanary(
      authorization.canary,
      resourceTreeSHA256: resource,
      now: now()
    )
    guard !existing.shouldExecute, existing.report.status == .recoveryRequired else {
      throw EngineClientError(.staleEvidence)
    }
    let candidate = try await components.herdrRuntime.canaryRecoveryCandidate(
      authorization: authorization.canary,
      resourceTreeSHA256: resource,
      resumedRecoveryEvidenceSHA256: authorization.recoveryEvidenceSHA256
    )
    guard candidate.evidence.evidenceSHA256 == authorization.recoveryEvidenceSHA256 else {
      throw EngineClientError(.staleEvidence)
    }
    let alreadyAuthorized = try await jobs.hasCanaryTopologyRecoveryAuthorization(
      authorization
    )
    let authorizationReplayed: Bool
    if alreadyAuthorized {
      authorizationReplayed = true
    } else {
      authorizationReplayed = try await jobs.authorizeCanaryTopologyRecovery(
        authorization,
        evidence: candidate.evidence,
        now: now()
      )
    }
    let revalidated = try await components.herdrRuntime.canaryRecoveryCandidate(
      authorization: authorization.canary,
      resourceTreeSHA256: resource,
      resumedRecoveryEvidenceSHA256: authorization.recoveryEvidenceSHA256
    )
    guard revalidated.evidence == candidate.evidence else {
      throw EngineClientError(.staleEvidence)
    }
    try await components.canaryMarkerGate.begin(jobID: authorization.canary.scope.jobID)
    await components.herdrRuntime.beginCanaryLaunchAdmission(
      jobID: authorization.canary.scope.jobID
    )
    do {
      try await components.herdrRuntime.activateCanaryRecovery(
        revalidated,
        authorization: authorization
      )
      let resumeReplayed = try await jobs.resumeCanaryAfterTopologyRecovery(
        authorization,
        evidence: revalidated.evidence,
        now: now()
      )
      try await components.coordinator.runRecoveredCanary(
        jobID: authorization.canary.scope.jobID,
        recoveryEvidenceSHA256: authorization.recoveryEvidenceSHA256
      )
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      let canary: JobCanaryReport
      do {
        canary = try await requireSuccessfulCanary(
          try await jobs.closeCanary(
            authorization: authorization.canary,
            resourceTreeSHA256: resource,
            now: now()
          )
        )
      } catch DurableJobStoreError.canaryRecoveryRequired {
        canary = JobCanaryReport(
          scope: existing.report.scope,
          previewEvidenceSHA256: existing.report.previewEvidenceSHA256,
          authorizationSHA256: existing.report.authorizationSHA256,
          status: .recoveryRequired,
          repositoryOwner: existing.report.repositoryOwner,
          repositoryName: existing.report.repositoryName,
          objectNumber: existing.report.objectNumber,
          revisionKey: existing.report.revisionKey,
          provider: existing.report.provider,
          model: existing.report.model,
          thinking: existing.report.thinking,
          resourceTreeSHA256: existing.report.resourceTreeSHA256,
          replayed: false
        )
      }
      guard
        let recovery = revalidated.evidence.report(
          authorization: authorization,
          status: canary.status == .settled ? .recovered : .recoveryRequired,
          replayed: authorizationReplayed || resumeReplayed
        )
      else { throw EngineClientError(.internalFailure) }
      return JobCanaryRecoveryExecution(recovery: recovery, canary: canary)
    } catch {
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      throw error
    }
  }

  public func previewCanaryPiRetry(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> JobCanaryPiRetryReport {
    guard exclusiveOperations == 0, paused, let components else {
      throw EngineClientError(.busy)
    }
    let resource = try await canaryResourceTreeSHA256()
    let candidate = try await components.herdrRuntime.canaryPiFreshRetryCandidate(
      authorization: authorization,
      resourceTreeSHA256: resource
    )
    guard
      let report = candidate.evidence.report(
        authorization: nil,
        status: .preview,
        replayed: false
      )
    else { throw EngineClientError(.staleEvidence) }
    return report
  }

  public func executeCanaryPiRetry(
    _ authorization: JobCanaryPiRetryAuthorization
  ) async throws -> JobCanaryPiRetryExecution {
    guard exclusiveOperations == 1, paused, let components else {
      throw EngineClientError(.busy)
    }
    let resource = try await canaryResourceTreeSHA256()
    let existing = try await jobs.admitCanary(
      authorization.recovery.canary,
      resourceTreeSHA256: resource,
      now: now()
    )
    guard !existing.shouldExecute, existing.report.status == .recoveryRequired else {
      throw EngineClientError(.staleEvidence)
    }
    let candidate = try await components.herdrRuntime.canaryPiFreshRetryCandidate(
      authorization: authorization.recovery,
      resourceTreeSHA256: resource
    )
    guard candidate.evidence.evidenceSHA256 == authorization.retryEvidenceSHA256 else {
      throw EngineClientError(.staleEvidence)
    }
    let authorizationReplayed = try await jobs.authorizeCanaryPiFreshRetry(
      authorization,
      evidence: candidate.evidence,
      now: now()
    )
    let revalidated = try await components.herdrRuntime.canaryPiFreshRetryCandidate(
      authorization: authorization.recovery,
      resourceTreeSHA256: resource,
      authorizedRetryEvidenceSHA256: authorization.retryEvidenceSHA256
    )
    guard revalidated.evidence == candidate.evidence else {
      throw EngineClientError(.staleEvidence)
    }
    try await components.canaryMarkerGate.begin(
      jobID: authorization.recovery.canary.scope.jobID
    )
    await components.herdrRuntime.beginCanaryLaunchAdmission(
      jobID: authorization.recovery.canary.scope.jobID
    )
    do {
      try await components.herdrRuntime.activateCanaryPiFreshRetry(
        revalidated,
        authorization: authorization
      )
      try await components.coordinator.runCanaryPiFreshRetry(
        jobID: authorization.recovery.canary.scope.jobID,
        recoveryEvidenceSHA256: authorization.recovery.recoveryEvidenceSHA256,
        retryEvidenceSHA256: authorization.retryEvidenceSHA256
      )
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      let canary: JobCanaryReport
      do {
        canary = try await requireSuccessfulCanary(
          try await jobs.closeCanary(
            authorization: authorization.recovery.canary,
            resourceTreeSHA256: resource,
            now: now()
          )
        )
      } catch DurableJobStoreError.canaryRecoveryRequired {
        canary = JobCanaryReport(
          scope: existing.report.scope,
          previewEvidenceSHA256: existing.report.previewEvidenceSHA256,
          authorizationSHA256: existing.report.authorizationSHA256,
          status: .recoveryRequired,
          repositoryOwner: existing.report.repositoryOwner,
          repositoryName: existing.report.repositoryName,
          objectNumber: existing.report.objectNumber,
          revisionKey: existing.report.revisionKey,
          provider: existing.report.provider,
          model: existing.report.model,
          thinking: existing.report.thinking,
          resourceTreeSHA256: existing.report.resourceTreeSHA256,
          replayed: false
        )
      }
      guard
        let retry = revalidated.evidence.report(
          authorization: authorization,
          status: canary.status == .settled ? .authorized : .recoveryRequired,
          replayed: authorizationReplayed
        )
      else { throw EngineClientError(.internalFailure) }
      return JobCanaryPiRetryExecution(retry: retry, canary: canary)
    } catch {
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      throw error
    }
  }

  public func previewCanaryRoleHostReplacement(
    _ request: JobCanaryRoleHostReplacementRequest
  ) async throws -> JobCanaryRoleHostReplacementReport {
    guard exclusiveOperations == 0, paused, let components else {
      throw EngineClientError(.busy)
    }
    if let terminal = try await jobs.canaryRoleHostReplacementTerminalReport(
      request: request,
      replayed: true
    ) {
      return terminal
    }
    let candidate = try await components.herdrRuntime.canaryRoleHostReplacementCandidate(
      request: request,
      resourceTreeSHA256: try await canaryResourceTreeSHA256()
    )
    return candidate.report
  }

  public func executeCanaryRoleHostReplacement(
    _ authorization: JobCanaryRoleHostReplacementAuthorization
  ) async throws -> JobCanaryRoleHostReplacementExecution {
    try authorization.validate()
    guard exclusiveOperations == 1, paused else {
      throw EngineClientError(.busy)
    }
    let boundary: ProductionRoleHostReplacementBoundary
    if let roleHostReplacementBoundary {
      boundary = roleHostReplacementBoundary
    } else {
      guard let components else { throw EngineClientError(.busy) }
      boundary = productionRoleHostReplacementBoundary(components: components)
    }
    guard
      try await boundary.terminalReport(authorization.request, false) == nil
    else { throw EngineClientError(.staleEvidence) }
    let resource = try await boundary.resourceTreeSHA256()
    let existing = try await boundary.admitCanary(
      authorization.request.retry.recovery.canary,
      resource
    )
    guard !existing.shouldExecute, existing.report.status == .recoveryRequired else {
      throw EngineClientError(.staleEvidence)
    }
    let candidate = try await boundary.candidate(authorization, resource)
    guard
      candidate.report.replacementEvidenceSHA256
        == authorization.replacementEvidenceSHA256
    else { throw EngineClientError(.staleEvidence) }
    let jobID = authorization.request.retry.recovery.canary.scope.jobID
    try await boundary.beginMarker(jobID)
    await boundary.beginLaunchAdmission(jobID)
    do {
      try await candidate.activate()
      try await boundary.runCoordinator(authorization.request)
    } catch {
      await boundary.endLaunchAdmission()
      await boundary.endMarker()
      guard
        let report = try await boundary.terminalReport(authorization.request, false)
      else { throw error }
      return JobCanaryRoleHostReplacementExecution(
        replacement: report,
        canary: existing.report
      )
    }
    await boundary.endLaunchAdmission()
    await boundary.endMarker()
    guard
      let report = try await boundary.terminalReport(authorization.request, false),
      report.status == .q4Settled
    else { throw EngineClientError(.internalFailure) }
    return JobCanaryRoleHostReplacementExecution(
      replacement: report,
      canary: existing.report
    )
  }

  public func previewCanaryGenerationRollover(
    _ request: JobCanaryGenerationRolloverRequest
  ) async throws -> JobCanaryGenerationRolloverReport {
    guard exclusiveOperations == 0, paused, let components else {
      throw EngineClientError(.busy)
    }
    let candidate = try await components.herdrRuntime.canaryGenerationRolloverCandidate(
      request: request
    )
    return try JobCanaryGenerationRolloverReport(
      authorization: candidate.authorization,
      status: .preview,
      replayed: false
    )
  }

  public func executeCanaryGenerationRollover(
    _ authorization: JobCanaryGenerationRolloverAuthorization
  ) async throws -> JobCanaryGenerationRolloverReport {
    try authorization.validate()
    guard exclusiveOperations == 1, paused, let components else {
      throw EngineClientError(.busy)
    }
    if try await components.herdrRuntime.generationRolloverTopologyIsActive(
      authorization
    ) {
      return try JobCanaryGenerationRolloverReport(
        authorization: authorization,
        status: .topologyActivated,
        replayed: true
      )
    }
    let candidate: HerdrGenerationRolloverCandidate
    if try await components.herdrRuntime.hasGenerationRolloverAuthorization(
      authorization
    ) {
      candidate = try await components.herdrRuntime.canaryGenerationRolloverCandidate(
        authorization: authorization
      )
    } else {
      candidate = try await components.herdrRuntime.canaryGenerationRolloverCandidate(
        request: authorization.request,
        authorizedRolloverEvidenceSHA256: authorization.rolloverEvidenceSHA256
      )
    }
    guard candidate.authorization == authorization else {
      throw EngineClientError(.staleEvidence)
    }
    try await components.canaryMarkerGate.begin(jobID: authorization.jobID)
    await components.herdrRuntime.beginCanaryLaunchAdmission(jobID: authorization.jobID)
    do {
      let replayed = try await components.herdrRuntime.activateCanaryGenerationRollover(
        candidate,
        authorization: authorization
      )
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      return try JobCanaryGenerationRolloverReport(
        authorization: authorization,
        status: .topologyActivated,
        replayed: replayed
      )
    } catch {
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      throw error
    }
  }

  public func previewCanaryGenerationRolloverQ4(
    _ request: JobCanaryGenerationRolloverQ4Request
  ) async throws -> JobCanaryGenerationRolloverQ4Report {
    guard exclusiveOperations == 0, paused, let components else {
      throw EngineClientError(.busy)
    }
    let candidate = try await components.herdrRuntime.canaryGenerationRolloverQ4Candidate(
      request: request,
      resourceTreeSHA256: try await canaryResourceTreeSHA256()
    )
    return try JobCanaryGenerationRolloverQ4Report(
      authorization: candidate.authorization,
      status: .preview,
      replayed: false
    )
  }

  public func executeCanaryGenerationRolloverQ4(
    _ authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization
  ) async throws -> JobCanaryGenerationRolloverQ4Report {
    try authorization.validate()
    guard exclusiveOperations == 1, paused, let components else {
      throw EngineClientError(.busy)
    }
    let request = JobCanaryGenerationRolloverQ4Request(
      rolloverAuthorization: authorization.rollover,
      plannedLaunchAttemptID: authorization.q4.plannedLaunchAttemptID
    )
    let candidate = try await components.herdrRuntime.canaryGenerationRolloverQ4Candidate(
      request: request,
      resourceTreeSHA256: try await canaryResourceTreeSHA256(),
      authorizedQ4: authorization.q4
    )
    guard candidate.authorization == authorization.q4 else {
      throw EngineClientError(.staleEvidence)
    }
    try await components.canaryMarkerGate.begin(jobID: authorization.rollover.jobID)
    await components.herdrRuntime.beginCanaryLaunchAdmission(
      jobID: authorization.rollover.jobID
    )
    do {
      let report = try await components.herdrRuntime.executeCanaryGenerationRolloverQ4(
        candidate,
        authorization: authorization
      )
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      return report
    } catch {
      await components.herdrRuntime.closeLaunchAdmission()
      await components.canaryMarkerGate.end()
      throw error
    }
  }

  private func productionRoleHostReplacementBoundary(
    components: ProductionJobComponents
  ) -> ProductionRoleHostReplacementBoundary {
    let jobs = jobs
    let resourceRoot = runtimeConfiguration.piResourceRoot
    let now = now
    return ProductionRoleHostReplacementBoundary(
      terminalReport: { request, replayed in
        try await jobs.canaryRoleHostReplacementTerminalReport(
          request: request,
          replayed: replayed
        )
      },
      resourceTreeSHA256: {
        do {
          return try PackagedPiResourceSnapshot.inspect(resourceRoot: resourceRoot)
        } catch {
          throw EngineClientError(.staleEvidence)
        }
      },
      admitCanary: { authorization, resourceTreeSHA256 in
        try await jobs.admitCanary(
          authorization,
          resourceTreeSHA256: resourceTreeSHA256,
          now: now()
        )
      },
      candidate: { authorization, resourceTreeSHA256 in
        let candidate = try await components.herdrRuntime.canaryRoleHostReplacementCandidate(
          request: authorization.request,
          resourceTreeSHA256: resourceTreeSHA256,
          authorizedReplacementEvidenceSHA256: authorization.replacementEvidenceSHA256,
          authorizedQ4Binding: authorization.q4Binding
        )
        return ProductionRoleHostReplacementCandidate(
          report: candidate.report,
          activate: {
            try await components.herdrRuntime.activateCanaryRoleHostReplacement(
              candidate,
              authorization: authorization
            )
          }
        )
      },
      beginMarker: { jobID in
        try await components.canaryMarkerGate.begin(jobID: jobID)
      },
      endMarker: { await components.canaryMarkerGate.end() },
      beginLaunchAdmission: { jobID in
        await components.herdrRuntime.beginCanaryLaunchAdmission(jobID: jobID)
      },
      endLaunchAdmission: { await components.herdrRuntime.closeLaunchAdmission() },
      runCoordinator: { request in
        try await components.coordinator.runCanaryRoleHostReplacement(request: request)
      }
    )
  }

  private func requireSuccessfulCanary(
    _ report: JobCanaryReport
  ) async throws -> JobCanaryReport {
    if report.status == .settled {
      guard try await jobs.job(id: report.scope.jobID)?.state == .succeeded else {
        throw EngineClientError(.internalFailure)
      }
    }
    return report
  }

  public func waitUntilIdle() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.idleWaitLimitSeconds
    while true {
      let schedulerBusy = await components?.scheduler.snapshot().passRunning == true
      let herdrBusy = await ownershipRuntime?.isBusy() == true
      let commandBusy = await commandGate.isBusy()
      guard schedulerBusy || herdrBusy || commandBusy || exclusiveOperations > 0 else { return }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw EngineClientError(.timedOut)
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  public func timingSnapshot() async -> SchedulerTimingSnapshot? {
    await components?.scheduler.snapshot()
  }

  public func coordinatorSnapshot() async -> JobCoordinatorSnapshot? {
    await components?.coordinator.snapshot()
  }

  public func focusInHerdr() async throws {
    guard await herdrReadiness.preflight().state == .ready,
      let ownershipRuntime
    else {
      throw EngineClientError(.herdrBlocked)
    }
    do {
      try await ownershipRuntime.focusMostRecentOwnedPane()
    } catch {
      throw EngineClientError(.herdrBlocked)
    }
  }

  public func prepareForCheckpoint() async throws {
    checkpointing = true
    await dispatchGate.set(false)
    await ownershipRuntime?.setLaunchAllowed(false)
    await commandGate.closeAndWait()
    do {
      try await waitUntilIdle()
      await stopScheduler()
      if let components {
        await components.coordinator.run(
          pass: SchedulerPass(reasons: [.manual], startedAt: now())
        )
        try await components.herdrRuntime.waitUntilIdle()
      }
      try await ownershipRuntime?.shutdownOwnedRoleHosts()
    } catch {
      checkpointing = false
      await applyDispatchGate()
      throw error
    }
  }

  private func recordInitialReloadPhase(
    _ phase: EngineStartupPhase,
    enabled: Bool
  ) async {
    guard enabled else { return }
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

  private func waitUntilSchedulerIdle() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.idleWaitLimitSeconds
    while await components?.scheduler.snapshot().passRunning == true {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw EngineClientError(.timedOut)
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func applyDispatchGate() async {
    let herdrReady = await herdrReadiness.preflight().state == .ready
    let allowed =
      desiredDispatchAllowed && herdrReady && !paused
      && exclusiveOperations == 0 && !checkpointing
    if allowed {
      await ownershipRuntime?.setLaunchAllowed(true)
      await commandGate.open()
      await dispatchGate.set(true)
    } else {
      await dispatchGate.set(false)
      await ownershipRuntime?.setLaunchAllowed(false)
      await commandGate.closeAndWait()
    }
  }

  private func startScheduler() {
    guard schedulerTask == nil, let scheduler = components?.scheduler else { return }
    schedulerTask = Task {
      await scheduler.run()
    }
  }

  private func stopScheduler() async {
    guard let scheduler = components?.scheduler else {
      schedulerTask = nil
      return
    }
    await scheduler.stop()
    let task = schedulerTask
    schedulerTask = nil
    await task?.value
  }

  private static func makeHerdrRuntime(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    now: @escaping @Sendable () -> Date
  ) throws -> HerdrPiWorkflowRuntime {
    let resolver = ReleaseOwnedPiRuntimeResolver(
      runtimeRoot: runtimeConfiguration.releaseRuntimeRoot,
      containingApplicationURL: runtimeConfiguration.containingApplicationURL
    )
    _ = try ReleaseOwnedPiRuntimeBoundaryAuthority.localEngineStartup(using: resolver)
    return try HerdrPiWorkflowRuntime(
      applicationSupportRoot: runtimeConfiguration.applicationSupportRoot,
      resourceRoot: runtimeConfiguration.piResourceRoot,
      hostExecutable: runtimeConfiguration.herdrHostExecutable,
      socketURL: runtimeConfiguration.herdrSocketURL,
      runtimeResolver: resolver,
      database: database,
      jobs: jobs,
      configuration: configuration,
      now: now
    )
  }

  private func maintenanceRepositoryStore() throws -> RepositoryStore {
    try Self.ensurePrivateDirectory(runtimeConfiguration.applicationSupportRoot)
    let temporary = runtimeConfiguration.applicationSupportRoot.appendingPathComponent(
      "Temporary", isDirectory: true
    )
    try Self.ensurePrivateDirectory(temporary)
    let git = SystemGitTransport(
      temporaryDirectory: temporary.path,
      pushGuardExecutable: runtimeConfiguration.pushGuardExecutable
    )
    return try RepositoryStore(
      rootURL: runtimeConfiguration.applicationSupportRoot,
      database: database,
      transport: git
    )
  }

  private static func build(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    account: String,
    authorID: Int64,
    profiles: [ModelProfileConfiguration],
    herdrRuntime: HerdrPiWorkflowRuntime,
    commandRuns: ApprovedCommandRunStore,
    commandGate: ApprovedCommandExecutionGate,
    dispatchGate: EngineDispatchGate,
    clock: any SchedulerClock,
    now: @escaping @Sendable () -> Date
  ) throws -> ProductionJobComponents {
    try ensurePrivateDirectory(runtimeConfiguration.applicationSupportRoot)
    let sessions = runtimeConfiguration.applicationSupportRoot.appendingPathComponent(
      "Sessions", isDirectory: true)
    let artifactsRoot = runtimeConfiguration.applicationSupportRoot.appendingPathComponent(
      "Artifacts", isDirectory: true)
    let ipc = runtimeConfiguration.applicationSupportRoot.appendingPathComponent(
      "IPC", isDirectory: true)
    let temporary = runtimeConfiguration.applicationSupportRoot.appendingPathComponent(
      "Temporary", isDirectory: true)
    for directory in [sessions, artifactsRoot, ipc, temporary] {
      try ensurePrivateDirectory(directory)
    }

    let tokenStore = try GitHubTokenStore(account: account)
    let broker = GitHubBroker(tokenStore: tokenStore)
    let git = SystemGitTransport(
      temporaryDirectory: temporary.path,
      pushGuardExecutable: runtimeConfiguration.pushGuardExecutable
    )
    let credentials = try GitHubGitCredentialProvider(
      broker: broker,
      socketDirectory: ipc,
      askPassExecutable: runtimeConfiguration.askPassExecutable
    )
    let repositories = try RepositoryStore(
      rootURL: runtimeConfiguration.applicationSupportRoot,
      database: database,
      transport: git
    )
    let artifacts = try ArtifactStore(rootURL: artifactsRoot, database: database)
    let reviewedRevisions = ReviewedRevisionStore(database: database)
    let schedulerPersistence = SchedulerPersistence(database: database)
    let mutationExecutor = GitHubMutationExecutor(intents: intents, broker: broker)
    let canaryMarkerGate = JobCanaryMarkerAuthorizationGate(authority: jobs)
    let markerPublisher = GitHubMarkerPublisher(
      executor: mutationExecutor,
      intents: intents,
      reads: broker,
      canaryAuthorizer: canaryMarkerGate,
      now: now
    )
    let labelBootstrapper = GitHubWorkflowLabelBootstrapper(
      executor: mutationExecutor,
      intents: intents,
      reads: broker,
      now: now
    )
    let labelMutator = GitHubWorkflowLabelMutator(
      executor: mutationExecutor,
      intents: intents,
      reads: broker,
      now: now
    )
    let pullRequestPublisher = GitHubPullRequestPublisher(
      executor: mutationExecutor,
      intents: intents,
      reads: broker,
      now: now
    )
    let pullRequestReview = PullRequestReviewJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      intents: intents,
      artifacts: artifacts,
      inputs: SystemPullRequestReviewJobPreparer(
        configuration: configuration,
        api: broker,
        repositories: repositories,
        deriver: GitPullRequestCommitDeriver(git: git),
        credentials: credentials
      ),
      reviewer: PiPullRequestReviewJobExecutor(
        executorFactory: herdrRuntime,
        sessionRoot: sessions,
        profiles: profiles
      ),
      markerPublisher: markerPublisher,
      reviewedRevisions: reviewedRevisions,
      repositories: repositories,
      authorID: authorID,
      now: now
    )

    let issueTriage = IssueTriageJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      artifacts: artifacts,
      inputs: SystemIssueTriageJobPreparer(
        configuration: configuration,
        api: broker,
        repositories: repositories,
        intents: intents,
        appAuthorID: authorID,
        credentials: credentials
      ),
      triage: PiIssueTriageJobExecutor(
        executorFactory: herdrRuntime,
        sessionRoot: sessions,
        profiles: profiles
      ),
      markerPublisher: markerPublisher,
      labelBootstrapper: labelBootstrapper,
      labelMutator: labelMutator,
      repositories: repositories,
      authorID: authorID,
      now: now
    )

    let issueImplementation = IssueImplementationJobWorkflow(
      jobs: jobs,
      configuration: configuration,
      artifacts: artifacts,
      repositories: repositories,
      inputs: SystemIssueImplementationJobPreparer(
        configuration: configuration,
        api: broker,
        repositories: repositories,
        intents: intents,
        appAuthorID: authorID,
        credentials: credentials
      ),
      planner: PiIssueImplementationPlanner(
        executorFactory: herdrRuntime,
        sessionRoot: sessions,
        profiles: profiles
      ),
      orchestrator: PiIssueImplementationOrchestrator(
        executorFactory: herdrRuntime,
        sessionRoot: sessions,
        profiles: profiles,
        verificationRunner: VerificationCommandRunner(
          temporaryDirectory: temporary.path
        ),
        commandRuns: commandRuns,
        commandGate: commandGate,
        importer: WorkspaceImporter(git: git),
        git: git
      ),
      markerPublisher: markerPublisher,
      labelBootstrapper: labelBootstrapper,
      labelMutator: labelMutator,
      branchPublisher: DurableGitPublisher(intents: intents, transport: git),
      pullRequestPublisher: pullRequestPublisher,
      credentials: credentials,
      authorID: authorID,
      contractVersion: runtimeConfiguration.contractVersion,
      now: now
    )

    let workflows = JobWorkflowRegistry(
      pullRequestReview: pullRequestReview,
      issueTriage: issueTriage,
      issueImplementation: issueImplementation,
      complexPlan: issueImplementation
    )
    let coordinator = JobCoordinator(
      configuration: configuration,
      discovery: GitHubDiscovery(
        api: broker,
        jobs: jobs,
        reviewedRevisions: reviewedRevisions
      ),
      jobs: jobs,
      repositories: repositories,
      schedulerPersistence: schedulerPersistence,
      workflows: workflows,
      contractVersion: runtimeConfiguration.contractVersion,
      newDispatchAllowed: { await dispatchGate.value() },
      now: now
    )
    let scheduler = DurableScheduler(
      clock: clock,
      runner: coordinator,
      initialNow: now()
    )
    return ProductionJobComponents(
      coordinator: coordinator,
      scheduler: scheduler,
      workflows: workflows,
      herdrRuntime: herdrRuntime,
      repositories: repositories,
      canaryMarkerGate: canaryMarkerGate
    )
  }

  private static func ensurePrivateDirectory(_ url: URL) throws {
    var metadata = stat()
    if FileManager.default.fileExists(atPath: url.path) {
      guard lstat(url.path, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0
      else {
        throw EngineClientError(.internalFailure)
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }
}
