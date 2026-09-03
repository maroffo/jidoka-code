import Foundation
import JidokaCodeCore
import ServiceManagement

private final class EngineXPCResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var continuation: CheckedContinuation<EngineCommandResponse, Error>?

  func install(
    connection: NSXPCConnection,
    continuation: CheckedContinuation<EngineCommandResponse, Error>
  ) {
    lock.lock()
    self.connection = connection
    self.continuation = continuation
    lock.unlock()
  }

  func finish(_ result: Result<EngineCommandResponse, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    let connection = connection
    self.continuation = nil
    self.connection = nil
    lock.unlock()
    connection?.invalidate()
    continuation.resume(with: result)
  }
}

private struct XPCApplicationEngineClient: EngineClient {
  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    try command.validate()
    let request = EngineXPCRequest(command: command)
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let requestData = try encoder.encode(request)
    let connection = NSXPCConnection(
      machServiceName: LifecycleProbeConstants.helperIdentifier,
      options: []
    )
    connection.remoteObjectInterface = NSXPCInterface(with: EngineProbeXPCProtocol.self)
    let box = EngineXPCResponseBox()
    return try await withCheckedThrowingContinuation { continuation in
      box.install(connection: connection, continuation: continuation)
      let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
        box.finish(.failure(EngineClientError(.unavailable)))
      }
      guard let service = proxy as? EngineProbeXPCProtocol else {
        box.finish(.failure(EngineClientError(.invalidResponse)))
        return
      }
      connection.resume()
      service.handle(requestData) { responseData, errorCode in
        do {
          guard errorCode == nil, let responseData else {
            throw EngineClientError(.unavailable)
          }
          let response = try JSONDecoder().decode(EngineXPCResponse.self, from: responseData)
          box.finish(.success(try response.validate(for: request)))
        } catch let error as EngineClientError {
          box.finish(.failure(error))
        } catch {
          box.finish(.failure(EngineClientError(.invalidResponse)))
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout(for: command.kind)) {
        box.finish(.failure(EngineClientError(.timedOut)))
      }
    }
  }

  private func timeout(for command: EngineCommandKind) -> TimeInterval {
    switch command {
    case .replaceCredential, .addRepository, .runPiPreflight, .refreshModelCatalog,
      .focusInHerdr:
      90
    case .executeJobCanary, .executeJobCanaryRecovery, .executeJobCanaryPiRetry,
      .executeJobCanaryRoleHostReplacement, .executeJobCanaryGenerationRollover,
      .previewJobCanaryGenerationRolloverQ4, .executeJobCanaryGenerationRolloverQ4:
      3_500
    case .setProfile, .recheckAmbiguousMutation, .authorizeRetry, .runHerdrPreflight,
      .prepareForHandoff, .prepareForQuit:
      700
    case .snapshot, .acknowledgeExternalAutomation, .acknowledgeProviderDisclosure,
      .deleteCredential, .updateRepository, .removeRepository, .setMaxConcurrency,
      .setPaused, .pollNow, .previewJobMaintenance, .applyJobMaintenance,
      .previewJobCanary, .previewJobCanaryRecovery, .previewJobCanaryPiRetry,
      .previewJobCanaryRoleHostReplacement, .previewJobCanaryGenerationRollover,
      .setLoginEnabled, .synchronizeLoginStatus,
      .completeOnboarding, .rollbackOnboarding:
      30
    }
  }
}

protocol EngineTopologyLocking: Sendable {
  func release()
}

extension SingleInstanceLock: EngineTopologyLocking {}

private final class NoopEngineTopologyLock: EngineTopologyLocking, @unchecked Sendable {
  func release() {}
}

protocol BootstrapEngineContaining: Sendable {
  var client: any EngineClient { get }
  func close() async
}

private final class LocalEngineContainer: BootstrapEngineContaining, @unchecked Sendable {
  let database: SQLiteStore
  let service: EngineService
  private let engineLock: any EngineTopologyLocking

  var client: any EngineClient { service }

  init(
    database: SQLiteStore,
    service: EngineService,
    engineLock: any EngineTopologyLocking
  ) {
    self.database = database
    self.service = service
    self.engineLock = engineLock
  }

  func close() async {
    await database.close()
    engineLock.release()
  }
}

protocol LoginItemControlling: Sendable {
  func status() async throws -> LifecycleServiceStatus
  func register() async throws
  func unregister() async throws
}

protocol BackgroundCredentialAccessPreparing: Sendable {
  func prepare() async throws
}

private actor SystemBackgroundCredentialAccessPreparer: BackgroundCredentialAccessPreparing {
  func prepare() throws {
    try GitHubTokenBackgroundAccess().prepare()
  }
}

private struct NoopBackgroundCredentialAccessPreparer: BackgroundCredentialAccessPreparing {
  func prepare() {}
}

private enum BackgroundCredentialAccessState {
  case unchecked
  case prepared
  case failed
}

private actor SystemLoginItemController: LoginItemControlling {
  private let service = SMAppService.agent(
    plistName: LifecycleProbeConstants.launchAgentPlistName
  )

  func status() throws -> LifecycleServiceStatus {
    try LifecycleServiceStatus(rawServiceManagementValue: service.status.rawValue)
  }

  func register() throws {
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }
}

actor ProductionEngineClient: EngineClient {
  private let loginItems: any LoginItemControlling
  private let helper: any EngineClient
  private let backgroundCredentialAccess: any BackgroundCredentialAccessPreparing
  private let bootstrapFactory: @Sendable () async throws -> any BootstrapEngineContaining
  private let engineLockFactory: @Sendable () async throws -> any EngineTopologyLocking
  private let helperStartupAttemptLimit: Int
  private let helperStartupRetryNanoseconds: UInt64
  private let helperStartupWait: @Sendable (UInt64) async -> Void
  private var local: (any BootstrapEngineContaining)?
  private var backgroundCredentialAccessState = BackgroundCredentialAccessState.unchecked
  private var activeCommand: EngineCommandKind?
  private var snapshotCompletionWaiters: [CheckedContinuation<Void, Never>] = []

  static let productionHelperStartupAttemptLimit = 240
  static let productionHelperStartupRetryNanoseconds: UInt64 = 250_000_000

  init(duplicateInstanceCheckPassed: Bool) {
    loginItems = SystemLoginItemController()
    helper = XPCApplicationEngineClient()
    backgroundCredentialAccess = SystemBackgroundCredentialAccessPreparer()
    helperStartupAttemptLimit = Self.productionHelperStartupAttemptLimit
    helperStartupRetryNanoseconds = Self.productionHelperStartupRetryNanoseconds
    helperStartupWait = { nanoseconds in
      try? await Task.sleep(nanoseconds: nanoseconds)
    }
    engineLockFactory = {
      try await Self.acquireEngineLock()
    }
    bootstrapFactory = {
      try await Self.makeLocalContainer(
        duplicateInstanceCheckPassed: duplicateInstanceCheckPassed
      )
    }
  }

  init(
    loginItems: any LoginItemControlling,
    helper: any EngineClient,
    backgroundCredentialAccess: any BackgroundCredentialAccessPreparing =
      NoopBackgroundCredentialAccessPreparer(),
    engineLockFactory: @escaping @Sendable () async throws -> any EngineTopologyLocking = {
      NoopEngineTopologyLock()
    },
    helperStartupAttemptLimit: Int = ProductionEngineClient.productionHelperStartupAttemptLimit,
    helperStartupRetryNanoseconds: UInt64 =
      ProductionEngineClient.productionHelperStartupRetryNanoseconds,
    helperStartupWait: @escaping @Sendable (UInt64) async -> Void = { _ in },
    bootstrapFactory: @escaping @Sendable () async throws -> any BootstrapEngineContaining
  ) {
    self.loginItems = loginItems
    self.helper = helper
    precondition(helperStartupAttemptLimit > 0)
    precondition(helperStartupRetryNanoseconds > 0)
    self.backgroundCredentialAccess = backgroundCredentialAccess
    self.engineLockFactory = engineLockFactory
    self.helperStartupAttemptLimit = helperStartupAttemptLimit
    self.helperStartupRetryNanoseconds = helperStartupRetryNanoseconds
    self.helperStartupWait = helperStartupWait
    self.bootstrapFactory = bootstrapFactory
  }

  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    try command.validate()
    while activeCommand == .snapshot, command.kind != .snapshot {
      await waitForSnapshotCompletion()
    }
    guard activeCommand == nil else { throw EngineClientError(.busy) }
    activeCommand = command.kind
    defer { completeActiveCommand() }
    switch command {
    case .setLoginEnabled(let enabled):
      return try await setLoginEnabled(enabled)
    case .completeOnboarding:
      return try await completeOnboarding()
    default:
      let status = try await loginItems.status()
      let response = try await send(command, status: status)
      let result: EngineCommandResponse
      if command.kind == .synchronizeLoginStatus
        || command.kind == .prepareForQuit
        || command.kind == .prepareForHandoff
      {
        result = response
      } else {
        result = try await synchronize(
          response: response,
          status: status,
          selected: status == .enabled || status == .requiresApproval
        )
      }
      if command.kind == .replaceCredential {
        backgroundCredentialAccessState = .prepared
      } else if command.kind == .deleteCredential {
        backgroundCredentialAccessState = .unchecked
      }
      return result
    }
  }

  private func waitForSnapshotCompletion() async {
    await withCheckedContinuation { snapshotCompletionWaiters.append($0) }
  }

  private func completeActiveCommand() {
    activeCommand = nil
    let waiters = snapshotCompletionWaiters
    snapshotCompletionWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func setLoginEnabled(_ enabled: Bool) async throws -> EngineCommandResponse {
    let current = try await loginItems.status()
    if enabled {
      if current == .enabled || current == .requiresApproval {
        let response = try await send(.snapshot, status: current)
        return try await synchronize(response: response, status: current, selected: true)
      }
      let bootstrap = try await localClient()
      let readiness = try await bootstrap.client.send(.snapshot).state.onboarding
      guard readiness.duplicateInstanceCheckPassed,
        readiness.externalAutomationAcknowledged,
        readiness.providerDisclosureAcknowledged,
        readiness.pi.state == .ready,
        readiness.herdr.state == .ready,
        readiness.credential.state == .valid,
        Set(readiness.configuredProfileRoles) == Set(ModelProfileRole.allCases)
      else {
        throw EngineClientError(.onboardingIncomplete)
      }
      try await prepareBackgroundCredentialAccess()
      _ = try await bootstrap.client.send(
        .synchronizeLoginStatus(selected: false, status: .notRegistered)
      )
      let handoff = try await bootstrap.client.send(.prepareForHandoff)
      guard handoff.checkpoint?.databaseCheckpointed == true else {
        throw EngineClientError(.checkpointFailed)
      }
      await bootstrap.close()
      local = nil
      var registrationCompleted = false
      var helperReachedControlPlane = false
      do {
        try await loginItems.register()
        registrationCompleted = true
        let registered = try await loginItems.status()
        guard registered == .enabled || registered == .requiresApproval else {
          throw EngineClientError(.loginItemFailed)
        }
        let response = try await waitForHelperSnapshot(status: registered)
        helperReachedControlPlane = registered == .enabled
        return try await synchronize(response: response, status: registered, selected: true)
      } catch {
        guard registrationCompleted else {
          _ = try? await localClient()
          throw EngineClientError(.loginItemFailed)
        }
        guard helperReachedControlPlane else {
          throw EngineClientError(.loginItemFailed)
        }
        if (try? await loginItems.status()) == .enabled {
          _ = try? await send(.prepareForQuit, status: .enabled)
        }
        let quiescence = try await engineLockFactory()
        do {
          try await loginItems.unregister()
        } catch {
          quiescence.release()
          throw EngineClientError(.loginItemFailed)
        }
        quiescence.release()
        _ = try? await localClient()
        throw EngineClientError(.loginItemFailed)
      }
    }

    switch current {
    case .enabled:
      let quit = try await send(.prepareForQuit, status: .enabled)
      guard quit.checkpoint?.databaseCheckpointed == true else {
        throw EngineClientError(.checkpointFailed)
      }
      let quiescence = try await engineLockFactory()
      do {
        try await loginItems.unregister()
      } catch {
        quiescence.release()
        throw EngineClientError(.loginItemFailed)
      }
      quiescence.release()
    case .requiresApproval:
      let quiescence = try await engineLockFactory()
      do {
        try await loginItems.unregister()
      } catch {
        quiescence.release()
        throw EngineClientError(.loginItemFailed)
      }
      quiescence.release()
    case .notRegistered, .notFound:
      break
    }
    let bootstrap = try await localClient()
    return try await bootstrap.client.send(
      .synchronizeLoginStatus(selected: false, status: .notRegistered)
    )
  }

  private func completeOnboarding() async throws -> EngineCommandResponse {
    let status = try await loginItems.status()
    guard status == .enabled || status == .requiresApproval else {
      throw EngineClientError(.loginItemFailed)
    }
    let response = try await send(.snapshot, status: status)
    _ = try await synchronize(response: response, status: status, selected: true)
    return try await send(.completeOnboarding, status: status)
  }

  private func send(
    _ command: EngineCommand,
    status: LifecycleServiceStatus
  ) async throws -> EngineCommandResponse {
    switch status {
    case .enabled:
      if requiresBackgroundCredentialAccess(for: command) {
        try await prepareBackgroundCredentialAccess()
      }
      if let local {
        await local.close()
        self.local = nil
      }
      return try await helper.send(command)
    case .requiresApproval, .notRegistered, .notFound:
      return try await localClient().client.send(command)
    }
  }

  private func synchronize(
    response: EngineCommandResponse,
    status: LifecycleServiceStatus,
    selected: Bool
  ) async throws -> EngineCommandResponse {
    guard
      response.state.settings.loginItemStatus != status
        || response.state.settings.loginItemSelected != selected
    else {
      return response
    }
    return try await send(
      .synchronizeLoginStatus(selected: selected, status: status),
      status: status
    )
  }

  private func requiresBackgroundCredentialAccess(for command: EngineCommand) -> Bool {
    switch command {
    case .replaceCredential, .deleteCredential, .synchronizeLoginStatus,
      .rollbackOnboarding, .prepareForHandoff, .prepareForQuit:
      false
    case .setPaused(let paused):
      !paused
    default:
      true
    }
  }

  private func waitForHelperSnapshot(
    status: LifecycleServiceStatus
  ) async throws -> EngineCommandResponse {
    for attempt in 1...helperStartupAttemptLimit {
      do {
        return try await send(.snapshot, status: status)
      } catch let error as EngineClientError
        where error.code == .unavailable && attempt < helperStartupAttemptLimit
      {
        await helperStartupWait(helperStartupRetryNanoseconds)
      }
    }
    throw EngineClientError(.unavailable)
  }

  private func prepareBackgroundCredentialAccess() async throws {
    switch backgroundCredentialAccessState {
    case .prepared:
      return
    case .failed:
      throw EngineClientError(.credentialAccessFailed)
    case .unchecked:
      break
    }
    do {
      try await backgroundCredentialAccess.prepare()
      backgroundCredentialAccessState = .prepared
    } catch {
      backgroundCredentialAccessState = .failed
      throw EngineClientError(.credentialAccessFailed)
    }
  }

  private func localClient() async throws -> any BootstrapEngineContaining {
    if let local { return local }
    let container = try await bootstrapFactory()
    local = container
    return container
  }

  private static func makeLocalContainer(
    duplicateInstanceCheckPassed: Bool
  ) async throws -> any BootstrapEngineContaining {
    let paths = try Self.paths()
    let engineLock = try await acquireEngineLock(
      applicationSupport: paths.applicationSupport
    )
    let database: SQLiteStore
    do {
      database = try SQLiteStore(
        databaseURL: paths.applicationSupport.appendingPathComponent(
          "jidoka-code.sqlite3", isDirectory: false)
      )
    } catch {
      engineLock.release()
      throw error
    }
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(
      database: database,
      enforceApplicationDispatchGate: true
    )
    let intents = MutationIntentStore(database: database)
    let runtimeResolver = ReleaseOwnedPiRuntimeResolver(
      runtimeRoot: paths.releaseRuntime,
      containingApplicationURL: paths.containingApplication
    )
    _ = try ReleaseOwnedPiRuntimeBoundaryAuthority.applicationStartup(
      using: runtimeResolver
    )
    let external = ProductionEngineExternalServices(
      configuration: configuration,
      runtimeResolver: runtimeResolver,
      modelCatalogDiscovery: PiModelCatalogDiscovery(
        runtimeResolver: runtimeResolver,
        scriptURL: paths.modelCatalogScript,
        expectedScriptSHA256: "6057a1a9be5bef7fc029504b1599fcdae4079c3b3eb5829bfa1580c319fb95ba",
        piAgentDirectory: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".pi/agent", isDirectory: true),
        applicationSupportRoot: paths.applicationSupport,
        privateRuntimeRoot: paths.applicationSupport.appendingPathComponent(
          "ModelCatalog/Runtime", isDirectory: true
        )
      ),
      herdrReadiness: try HerdrRuntimeReadinessChecker(
        resourceRoot: paths.herdrResources,
        socketURL: paths.herdrSocket
      )
    )
    let service = EngineService(
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      database: database,
      external: external,
      runtime: InactiveEngineJobRuntime(),
      logger: try EngineRedactedLogger(
        rootURL: paths.applicationSupport.appendingPathComponent("Logs", isDirectory: true),
        filename: "bootstrap.jsonl"
      ),
      duplicateInstanceCheckPassed: duplicateInstanceCheckPassed
    )
    do {
      try await service.initialize()
      return LocalEngineContainer(
        database: database,
        service: service,
        engineLock: engineLock
      )
    } catch {
      await database.close()
      engineLock.release()
      throw error
    }
  }

  private static func acquireEngineLock() async throws -> SingleInstanceLock {
    try await acquireEngineLock(
      applicationSupport: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JidokaCode", isDirectory: true)
    )
  }

  private static func acquireEngineLock(
    applicationSupport: URL
  ) async throws -> SingleInstanceLock {
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while ProcessInfo.processInfo.systemUptime < deadline {
      let lock = try SingleInstanceLock(
        directoryURL: applicationSupport.appendingPathComponent("IPC", isDirectory: true),
        filename: "engine-instance.lock"
      )
      if lock.ownsLock { return lock }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw EngineClientError(.timedOut)
  }

  private struct Paths {
    let applicationSupport: URL
    let piResources: URL
    let releaseRuntime: URL
    let containingApplication: URL
    let modelCatalogScript: URL
    let herdrResources: URL
    let herdrSocket: URL
  }

  private static func paths() throws -> Paths {
    let packaged = Bundle.main.resourceURL?.appendingPathComponent("Pi", isDirectory: true)
    #if DEBUG
      let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/Pi", isDirectory: true)
      let piResources =
        packaged.flatMap {
          FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? development
    #else
      guard
        let piResources = packaged,
        FileManager.default.fileExists(atPath: piResources.path)
      else {
        throw EngineClientError(.piBlocked)
      }
    #endif
    guard FileManager.default.fileExists(atPath: piResources.path),
      let bundleResources = Bundle.main.resourceURL
    else {
      throw EngineClientError(.piBlocked)
    }
    let releaseRuntime = bundleResources.appendingPathComponent(
      ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
      isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: releaseRuntime.path) else {
      throw EngineClientError(.piBlocked)
    }
    let packagedHerdr = Bundle.main.resourceURL?.appendingPathComponent(
      "Herdr", isDirectory: true
    )
    guard
      let herdrResources = packagedHerdr.flatMap({
        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
      })
    else {
      throw EngineClientError(.herdrBlocked)
    }
    return Paths(
      applicationSupport: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JidokaCode", isDirectory: true),
      piResources: piResources,
      releaseRuntime: releaseRuntime,
      containingApplication: Bundle.main.bundleURL,
      modelCatalogScript: piResources.appendingPathComponent(
        "runtime/jidoka-model-catalog.mjs", isDirectory: false
      ),
      herdrResources: herdrResources,
      herdrSocket: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
    )
  }
}
