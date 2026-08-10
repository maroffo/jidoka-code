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
    case .replaceCredential, .addRepository, .runPiPreflight, .focusInHerdr:
      90
    case .setProfile, .recheckAmbiguousMutation, .authorizeRetry, .runHerdrPreflight,
      .prepareForHandoff, .prepareForQuit:
      700
    case .snapshot, .acknowledgeExternalAutomation, .acknowledgeProviderDisclosure,
      .deleteCredential, .updateRepository, .removeRepository, .setMaxConcurrency,
      .setPaused, .pollNow, .setLoginEnabled, .synchronizeLoginStatus,
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
  private let bootstrapFactory: @Sendable () async throws -> any BootstrapEngineContaining
  private let engineLockFactory: @Sendable () async throws -> any EngineTopologyLocking
  private var local: (any BootstrapEngineContaining)?
  private var commandInProgress = false

  init(duplicateInstanceCheckPassed: Bool) {
    loginItems = SystemLoginItemController()
    helper = XPCApplicationEngineClient()
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
    engineLockFactory: @escaping @Sendable () async throws -> any EngineTopologyLocking = {
      NoopEngineTopologyLock()
    },
    bootstrapFactory: @escaping @Sendable () async throws -> any BootstrapEngineContaining
  ) {
    self.loginItems = loginItems
    self.helper = helper
    self.engineLockFactory = engineLockFactory
    self.bootstrapFactory = bootstrapFactory
  }

  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    try command.validate()
    guard !commandInProgress else { throw EngineClientError(.busy) }
    commandInProgress = true
    defer { commandInProgress = false }
    switch command {
    case .setLoginEnabled(let enabled):
      return try await setLoginEnabled(enabled)
    case .completeOnboarding:
      return try await completeOnboarding()
    default:
      let status = try await loginItems.status()
      let response = try await send(command, status: status)
      guard command.kind != .synchronizeLoginStatus,
        command.kind != .prepareForQuit,
        command.kind != .prepareForHandoff
      else {
        return response
      }
      return try await synchronize(
        response: response,
        status: status,
        selected: status == .enabled || status == .requiresApproval
      )
    }
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
        readiness.repositoryCount > 0,
        Set(readiness.configuredProfileRoles) == Set(ModelProfileRole.allCases)
      else {
        throw EngineClientError(.onboardingIncomplete)
      }
      _ = try await bootstrap.client.send(
        .synchronizeLoginStatus(selected: false, status: .notRegistered)
      )
      let handoff = try await bootstrap.client.send(.prepareForHandoff)
      guard handoff.checkpoint?.databaseCheckpointed == true else {
        throw EngineClientError(.checkpointFailed)
      }
      await bootstrap.close()
      local = nil
      do {
        try await loginItems.register()
        let registered = try await loginItems.status()
        guard registered == .enabled || registered == .requiresApproval else {
          throw EngineClientError(.loginItemFailed)
        }
        let response = try await send(.snapshot, status: registered)
        return try await synchronize(response: response, status: registered, selected: true)
      } catch {
        if (try? await loginItems.status()) == .enabled {
          _ = try? await helper.send(.prepareForQuit)
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
      let quit = try await helper.send(.prepareForQuit)
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
      if let local {
        await local.close()
        self.local = nil
      }
      return try await helper.send(command)
    case .requiresApproval, .notRegistered:
      return try await localClient().client.send(command)
    case .notFound:
      throw EngineClientError(.loginItemFailed)
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
    let external = ProductionEngineExternalServices(
      configuration: configuration,
      runtimeResolver: PiRuntimeResolver(
        configuration: .standard(resourceRoot: paths.piResources)
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
    let herdrResources: URL
    let herdrSocket: URL
  }

  private static func paths() throws -> Paths {
    let packaged = Bundle.main.resourceURL?.appendingPathComponent("Pi", isDirectory: true)
    let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/Pi", isDirectory: true)
    let piResources =
      packaged.flatMap {
        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
      } ?? source
    guard FileManager.default.fileExists(atPath: piResources.path) else {
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
      herdrResources: herdrResources,
      herdrSocket: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
    )
  }
}
