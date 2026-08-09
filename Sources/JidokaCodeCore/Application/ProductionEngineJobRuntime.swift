import Darwin
import Foundation

public struct ProductionEngineRuntimeConfiguration: Sendable {
  public let applicationSupportRoot: URL
  public let piResourceRoot: URL
  public let askPassExecutable: URL
  public let pushGuardExecutable: URL
  public let contractVersion: String

  public init(
    applicationSupportRoot: URL,
    piResourceRoot: URL,
    askPassExecutable: URL,
    pushGuardExecutable: URL,
    contractVersion: String
  ) throws {
    guard applicationSupportRoot.isFileURL,
      applicationSupportRoot.path.hasPrefix("/"),
      piResourceRoot.isFileURL,
      piResourceRoot.path.hasPrefix("/"),
      askPassExecutable.isFileURL,
      askPassExecutable.path.hasPrefix("/"),
      pushGuardExecutable.isFileURL,
      pushGuardExecutable.path.hasPrefix("/"),
      !contractVersion.isEmpty,
      contractVersion.utf8.count <= 128
    else {
      throw EngineClientError(.internalFailure)
    }
    self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
    self.piResourceRoot = piResourceRoot.standardizedFileURL
    self.askPassExecutable = askPassExecutable.standardizedFileURL
    self.pushGuardExecutable = pushGuardExecutable.standardizedFileURL
    self.contractVersion = contractVersion
  }
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

private struct ProductionJobComponents: Sendable {
  let coordinator: JobCoordinator
  let scheduler: DurableScheduler
  let workflows: JobWorkflowRegistry
}

public actor ProductionEngineJobRuntime: EngineJobRuntime {
  private static let idleWaitLimitSeconds: TimeInterval = 660

  private let runtimeConfiguration: ProductionEngineRuntimeConfiguration
  private let database: SQLiteStore
  private let configuration: ConfigurationStore
  private let jobs: DurableJobStore
  private let intents: MutationIntentStore
  private let dispatchGate = EngineDispatchGate()
  private let clock: any SchedulerClock
  private let now: @Sendable () -> Date

  private var components: ProductionJobComponents?
  private var schedulerTask: Task<Void, Never>?
  private var desiredDispatchAllowed = false
  private var paused = false
  private var exclusiveOperations = 0
  private var checkpointing = false

  public init(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    clock: any SchedulerClock = SystemSchedulerClock(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.runtimeConfiguration = runtimeConfiguration
    self.database = database
    self.configuration = configuration
    self.jobs = jobs
    self.intents = intents
    self.clock = clock
    self.now = now
  }

  public func reload(dispatchAllowed: Bool) async throws {
    desiredDispatchAllowed = dispatchAllowed
    checkpointing = false
    await dispatchGate.set(false)
    try await waitUntilSchedulerIdle()
    await stopScheduler()
    let snapshot = try await configuration.snapshot()
    paused = snapshot.app.paused
    guard let account = snapshot.app.githubAccount,
      let authorID = snapshot.app.githubAuthorID,
      authorID > 0
    else {
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
      dispatchGate: dispatchGate,
      clock: clock,
      now: now
    )
    components = built
    await built.scheduler.setPaused(paused)
    await built.coordinator.run(
      pass: SchedulerPass(reasons: [.startup], startedAt: now())
    )
    await applyDispatchGate()
    if !paused {
      await built.scheduler.request(.startup)
    }
    if exclusiveOperations == 0, !checkpointing {
      startScheduler()
    }
  }

  public func setDispatchAllowed(_ allowed: Bool) async {
    desiredDispatchAllowed = allowed
    await applyDispatchGate()
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

  public func waitUntilIdle() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + Self.idleWaitLimitSeconds
    while await components?.scheduler.snapshot().passRunning == true
      || exclusiveOperations > 0
    {
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

  public func prepareForCheckpoint() async throws {
    checkpointing = true
    await dispatchGate.set(false)
    do {
      try await waitUntilIdle()
      await stopScheduler()
      if let coordinator = components?.coordinator {
        await coordinator.run(
          pass: SchedulerPass(reasons: [.manual], startedAt: now())
        )
      }
    } catch {
      checkpointing = false
      await applyDispatchGate()
      throw error
    }
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
    await dispatchGate.set(
      desiredDispatchAllowed && !paused && exclusiveOperations == 0 && !checkpointing
    )
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

  private static func build(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration,
    database: SQLiteStore,
    configuration: ConfigurationStore,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    account: String,
    authorID: Int64,
    profiles: [ModelProfileConfiguration],
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
    let markerPublisher = GitHubMarkerPublisher(
      executor: mutationExecutor,
      intents: intents,
      reads: broker,
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
    let runtimeResolver = PiRuntimeResolver(
      configuration: .standard(resourceRoot: runtimeConfiguration.piResourceRoot)
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
        runtimeResolver: runtimeResolver,
        resourceRoot: runtimeConfiguration.piResourceRoot,
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
        runtimeResolver: runtimeResolver,
        resourceRoot: runtimeConfiguration.piResourceRoot,
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
        runtimeResolver: runtimeResolver,
        resourceRoot: runtimeConfiguration.piResourceRoot,
        sessionRoot: sessions,
        profiles: profiles
      ),
      orchestrator: PiIssueImplementationOrchestrator(
        runtimeResolver: runtimeResolver,
        resourceRoot: runtimeConfiguration.piResourceRoot,
        sessionRoot: sessions,
        profiles: profiles,
        verificationRunner: VerificationCommandRunner(
          temporaryDirectory: temporary.path
        ),
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
      workflows: workflows
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
