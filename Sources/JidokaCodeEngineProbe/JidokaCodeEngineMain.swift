import AppKit
import Darwin
import Foundation
import JidokaCodeCore
import Network

private struct EngineProbeReport: Codable {
  let identifier: String
  let status: String
  let workingDirectory: String
}

private final class LifecycleEventRecorder: @unchecked Sendable {
  private let fileURL: URL
  private let lock = NSLock()
  private var nextSequence = 0

  init() throws {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/JidokaCode/Spike/S2", isDirectory: true)
    try PrivateDirectoryBoundary.ensure(directoryURL)
    fileURL = directoryURL.appendingPathComponent("helper-events.jsonl", isDirectory: false)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      guard
        FileManager.default.createFile(
          atPath: fileURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw LifecycleProbeError.remoteFailure("cannot create lifecycle event log")
      }
    }
    var metadata = stat()
    guard lstat(fileURL.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o077) == 0
    else {
      throw LifecycleProbeError.remoteFailure("unsafe lifecycle event log")
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func record(_ kind: LifecycleEventKind, snapshot: EngineSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    let event = LifecycleEvent(
      event: kind,
      generation: snapshot.generation,
      launchID: snapshot.launchID,
      pid: snapshot.pid,
      sequence: nextSequence
    )
    nextSequence += 1
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(event)
    data.append(0x0A)
    let descriptor = open(
      fileURL.path,
      O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw LifecycleProbeError.remoteFailure("cannot open lifecycle event log")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }
}

private final class XPCReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var reply: ((Data?, String?) -> Void)?

  init(reply: @escaping (Data?, String?) -> Void) {
    self.reply = reply
  }

  func send(data: Data?, error: String?) {
    lock.lock()
    let callback = reply
    reply = nil
    lock.unlock()
    callback?(data, error)
  }
}

private actor NetworkRegainState {
  private var previouslySatisfied: Bool?

  func update(isSatisfied: Bool) -> Bool {
    defer { previouslySatisfied = isSatisfied }
    return previouslySatisfied == false && isSatisfied
  }
}

@MainActor
private final class EngineLifecycleMonitor {
  private let application: EngineService
  private let networkMonitor = NWPathMonitor()
  private let networkState = NetworkRegainState()
  private let networkQueue = DispatchQueue(label: "com.maroffo.JidokaCode.network-monitor")
  private var wakeObserver: NSObjectProtocol?

  init(application: EngineService) {
    self.application = application
  }

  func start() {
    let application = application
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { await application.notifyLifecycleEvent(.wake) }
    }
    let networkState = networkState
    networkMonitor.pathUpdateHandler = { path in
      let isSatisfied = path.status == .satisfied
      Task {
        if await networkState.update(isSatisfied: isSatisfied) {
          await application.notifyLifecycleEvent(.networkRegained)
        }
      }
    }
    networkMonitor.start(queue: networkQueue)
  }
}

private func currentEngineExecutableURL() throws -> URL {
  var buffer = [CChar](repeating: 0, count: 4_096)
  let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
  guard length > 0 else { throw EngineClientError(.internalFailure) }
  let end = buffer.firstIndex(of: 0) ?? Int(length)
  let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
  let executable = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
  let canonical = executable.resolvingSymlinksInPath()
  var metadata = stat()
  guard executable.path.hasPrefix("/"),
    executable.path == canonical.path,
    lstat(executable.path, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG
  else {
    throw EngineClientError(.internalFailure)
  }
  return executable
}

private final class EngineServiceContainer: @unchecked Sendable {
  let application: EngineService
  let database: SQLiteStore

  init(application: EngineService, database: SQLiteStore) {
    self.application = application
    self.database = database
  }
}

private actor EngineStartupRecorder {
  private let logger: any EngineEventLogging

  init(logger: any EngineEventLogging) {
    self.logger = logger
  }

  func begin(_ phase: EngineStartupPhase) async {
    await logger.record(
      EngineLogRecord(
        timestamp: Date(),
        event: .startupPhase,
        phase: phase,
        command: nil,
        error: nil
      )
    )
  }
}

private final class EngineProbeService: NSObject, EngineProbeXPCProtocol, @unchecked Sendable {
  private let application: EngineServiceContainer
  private let messageHandler: EngineXPCMessageHandler
  private let recorder: LifecycleEventRecorder
  private let snapshotValue: EngineSnapshot

  init(
    generation: Int,
    recorder: LifecycleEventRecorder,
    application: EngineServiceContainer
  ) {
    snapshotValue = EngineSnapshot(
      generation: generation,
      launchID: UUID().uuidString.lowercased(),
      pid: ProcessInfo.processInfo.processIdentifier,
      reconciled: true,
      topology: .helper
    )
    self.recorder = recorder
    self.application = application
    messageHandler = EngineXPCMessageHandler(
      client: application.application,
      allowedCommands: EngineCommandKind.productionHelperAllowedCommands
    )
  }

  func reconcileBeforeListening() throws {
    try recorder.record(.reconciliation, snapshot: snapshotValue)
  }

  func handle(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
    let box = XPCReplyBox(reply: reply)
    do {
      guard
        let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
      else {
        throw LifecycleProbeError.invalidRequest
      }
      if object["command"] != nil {
        handleApplication(requestData, reply: box)
      } else {
        try handleLifecycleProbe(requestData, reply: box)
      }
    } catch {
      box.send(data: nil, error: "ENGINE_REQUEST_REJECTED")
    }
  }

  private func handleApplication(_ requestData: Data, reply: XPCReplyBox) {
    let application = application
    let handler = messageHandler
    let recorder = recorder
    let snapshot = snapshotValue
    Task {
      let request = try? JSONDecoder().decode(EngineXPCRequest.self, from: requestData)
      if let request, (try? request.validate()) != nil {
        try? recorder.record(.dispatch, snapshot: snapshot)
      }
      let responseData = await handler.handle(requestData)
      reply.send(data: responseData, error: nil)
      guard request?.command.kind == .prepareForQuit,
        let request,
        let response = try? JSONDecoder().decode(EngineXPCResponse.self, from: responseData),
        let result = try? response.validate(for: request),
        result.checkpoint?.databaseCheckpointed == true
      else {
        return
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
      await application.database.close()
      exit(EXIT_SUCCESS)
    }
  }

  private func handleLifecycleProbe(_ requestData: Data, reply: XPCReplyBox) throws {
    let request = try JSONDecoder().decode(EngineProbeXPCRequest.self, from: requestData)
    try request.validate()
    try recorder.record(.dispatch, snapshot: snapshotValue)

    let roundTrip: EngineRoundTripResponse?
    if let requestRoundTrip = request.roundTrip {
      roundTrip = EngineRoundTripResponse(
        requestID: requestRoundTrip.requestID,
        sequence: requestRoundTrip.sequence,
        snapshot: snapshotValue
      )
    } else {
      roundTrip = nil
    }
    let keychainSHA256: String?
    if request.operation == .keychainDigest {
      keychainSHA256 = try KeychainProbeStore().readDigest().sentinelSHA256
    } else {
      keychainSHA256 = nil
    }
    let response = EngineProbeXPCResponse(
      operation: request.operation,
      keychainSHA256: keychainSHA256,
      roundTrip: roundTrip,
      snapshot: snapshotValue
    )

    switch request.operation {
    case .gracefulQuit:
      let application = application
      Task {
        do {
          _ = try await application.application.send(.prepareForQuit)
          reply.send(data: try Self.encoder().encode(response), error: nil)
          try? await Task.sleep(nanoseconds: 250_000_000)
          await application.database.close()
          exit(EXIT_SUCCESS)
        } catch {
          reply.send(data: nil, error: "ENGINE_CHECKPOINT_FAILED")
        }
      }
    case .crash:
      reply.send(data: try Self.encoder().encode(response), error: nil)
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
        exit(EXIT_FAILURE)
      }
    case .snapshot, .roundTrip, .keychainDigest:
      reply.send(data: try Self.encoder().encode(response), error: nil)
    }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private final class EngineProbeListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  private let service: EngineProbeService
  private let peerValidator: EngineXPCPeerValidator

  init(service: EngineProbeService) throws {
    self.service = service
    peerValidator = EngineXPCPeerValidator(
      helperExecutableURL: try currentEngineExecutableURL()
    )
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard
      peerValidator.accepts(
        processID: newConnection.processIdentifier,
        effectiveUserID: newConnection.effectiveUserIdentifier
      )
    else {
      newConnection.invalidate()
      return false
    }
    newConnection.exportedInterface = NSXPCInterface(with: EngineProbeXPCProtocol.self)
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

private enum EngineServiceFactory {
  static func validatePathLayout() throws {
    _ = try enginePaths(executable: currentEngineExecutableURL())
  }

  static func validatePaths() throws {
    let paths = try enginePaths(executable: currentEngineExecutableURL())
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      _ = try ReleaseOwnedPiRuntimeVerifier.verifyAdHocBundle(
        runtimeRoot: paths.releaseRuntime,
        containingApplicationURL: paths.containingApplication
      )
    #else
      _ = try ReleaseOwnedPiRuntimeBoundaryAuthority.engineHelperStartup(
        using: ReleaseOwnedPiRuntimeResolver(
          runtimeRoot: paths.releaseRuntime,
          containingApplicationURL: paths.containingApplication
        )
      )
    #endif
  }

  static func make(
    logger: any EngineEventLogging,
    startup: EngineStartupRecorder
  ) async throws -> EngineServiceContainer {
    await startup.begin(.paths)
    let paths = try enginePaths(executable: currentEngineExecutableURL())
    await startup.begin(.resourceSnapshot)
    let privatePiResources = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: paths.piResources,
      applicationSupportRoot: paths.applicationSupport
    )
    await startup.begin(.database)
    let database = try SQLiteStore(
      databaseURL: paths.applicationSupport.appendingPathComponent(
        "jidoka-code.sqlite3", isDirectory: false)
    )
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(
      database: database,
      enforceApplicationDispatchGate: true,
      enforceRolloutAuthority: true
    )
    let intents = MutationIntentStore(database: database)
    let resolver = ReleaseOwnedPiRuntimeResolver(
      runtimeRoot: paths.releaseRuntime,
      containingApplicationURL: paths.containingApplication
    )
    _ = try ReleaseOwnedPiRuntimeBoundaryAuthority.engineHelperStartup(using: resolver)
    await startup.begin(.herdrReadiness)
    let herdrReadiness = try HerdrRuntimeReadinessChecker(
      resourceRoot: paths.herdrResources,
      socketURL: paths.herdrSocket
    )
    let external = ProductionEngineExternalServices(
      configuration: configuration,
      runtimeResolver: resolver,
      modelCatalogDiscovery: PiModelCatalogDiscovery(
        runtimeResolver: resolver,
        scriptURL: paths.modelCatalogScript,
        expectedScriptSHA256: "6057a1a9be5bef7fc029504b1599fcdae4079c3b3eb5829bfa1580c319fb95ba",
        piAgentDirectory: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".pi/agent", isDirectory: true),
        applicationSupportRoot: paths.applicationSupport,
        privateRuntimeRoot: paths.applicationSupport.appendingPathComponent(
          "ModelCatalog/Runtime", isDirectory: true
        )
      ),
      herdrReadiness: herdrReadiness,
      rolloutDatabase: database,
      rolloutJobs: jobs,
      rolloutIntents: intents,
      rolloutApplicationSupportRoot: paths.applicationSupport,
      rolloutAskPassExecutable: paths.askPass
    )
    await startup.begin(.hostSnapshot)
    let herdrHost = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: paths.herdrHost,
      applicationSupportRoot: paths.applicationSupport
    )
    await startup.begin(.runtimeConfiguration)
    let runtimeConfiguration = try ProductionEngineRuntimeConfiguration(
      applicationSupportRoot: paths.applicationSupport,
      piResourceRoot: privatePiResources,
      releaseRuntimeRoot: paths.releaseRuntime,
      containingApplicationURL: paths.containingApplication,
      askPassExecutable: paths.askPass,
      pushGuardExecutable: paths.pushGuard,
      herdrHostExecutable: herdrHost,
      herdrSocketURL: paths.herdrSocket,
      contractVersion: "jidoka-code-v1"
    )
    let runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: runtimeConfiguration,
      database: database,
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      herdrReadiness: herdrReadiness,
      logger: logger
    )
    await startup.begin(.serviceConstruction)
    let service = EngineService(
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      database: database,
      external: external,
      runtime: runtime,
      logger: logger,
      duplicateInstanceCheckPassed: true
    )
    try await service.initialize()
    return EngineServiceContainer(application: service, database: database)
  }

  private struct Paths {
    let applicationSupport: URL
    let piResources: URL
    let releaseRuntime: URL
    let containingApplication: URL
    let modelCatalogScript: URL
    let herdrResources: URL
    let askPass: URL
    let pushGuard: URL
    let herdrHost: URL
    let herdrSocket: URL
  }

  private static func enginePaths(executable: URL) throws -> Paths {
    let helperDirectory = executable.deletingLastPathComponent()
    let contents = helperDirectory.deletingLastPathComponent()
    let packagedResources = contents.appendingPathComponent("Resources/Pi", isDirectory: true)
    #if DEBUG
      let developmentResources = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath
      ).appendingPathComponent("Resources/Pi", isDirectory: true)
      let piResources =
        FileManager.default.fileExists(atPath: packagedResources.path)
        ? packagedResources : developmentResources
    #else
      let piResources = packagedResources
    #endif
    guard FileManager.default.fileExists(atPath: piResources.path) else {
      throw EngineClientError(.piBlocked)
    }
    let releaseRuntime = contents.appendingPathComponent(
      "Resources/\(ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName)",
      isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: releaseRuntime.path) else {
      throw EngineClientError(.piBlocked)
    }
    let containingApplication = contents.deletingLastPathComponent()
    guard containingApplication.pathExtension == "app" else {
      throw EngineClientError(.piBlocked)
    }
    let packagedHerdrResources = contents.appendingPathComponent(
      "Resources/Herdr", isDirectory: true
    )
    let herdrResources = packagedHerdrResources
    guard FileManager.default.fileExists(atPath: herdrResources.path) else {
      throw EngineClientError(.herdrBlocked)
    }
    let packagedPushGuard = helperDirectory.appendingPathComponent(
      "GitHooks/pre-push", isDirectory: false)
    let developmentPushGuard = helperDirectory.appendingPathComponent(
      "JidokaCodePushGuard", isDirectory: false)
    return Paths(
      applicationSupport: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JidokaCode", isDirectory: true),
      piResources: piResources,
      releaseRuntime: releaseRuntime,
      containingApplication: containingApplication,
      modelCatalogScript: piResources.appendingPathComponent(
        "runtime/jidoka-model-catalog.mjs", isDirectory: false
      ),
      herdrResources: herdrResources,
      askPass: helperDirectory.appendingPathComponent("JidokaCodeAskPass", isDirectory: false),
      pushGuard: FileManager.default.fileExists(atPath: packagedPushGuard.path)
        ? packagedPushGuard : developmentPushGuard,
      herdrHost: helperDirectory.appendingPathComponent(
        "JidokaCodeHerdrHost", isDirectory: false
      ),
      herdrSocket: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
    )
  }
}

private func runOneShotProbe(validateRuntime: Bool = true) throws -> Never {
  if validateRuntime {
    try EngineServiceFactory.validatePaths()
  } else {
    try EngineServiceFactory.validatePathLayout()
  }
  let report = EngineProbeReport(
    identifier: LifecycleProbeConstants.helperIdentifier,
    status: "ok",
    workingDirectory: FileManager.default.currentDirectoryPath
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
  exit(EXIT_SUCCESS)
}

private func runService(arguments: [String]) async throws -> Never {
  let configuration = try EngineServiceArguments.parse(arguments)
  let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JidokaCode", isDirectory: true)
  try PrivateDirectoryBoundary.ensure(applicationSupport)
  let logger = try EngineRedactedLogger(
    rootURL: applicationSupport.appendingPathComponent("Logs", isDirectory: true),
    filename: "engine.jsonl"
  )
  let startup = EngineStartupRecorder(logger: logger)
  await startup.begin(.privateDirectory)
  await startup.begin(.instanceLock)
  let engineLock = try SingleInstanceLock(
    directoryURL: applicationSupport.appendingPathComponent("IPC", isDirectory: true),
    filename: "engine-instance.lock"
  )
  guard engineLock.ownsLock else {
    throw EngineClientError(.busy)
  }
  await startup.begin(.lifecycleRecorder)
  let recorder = try LifecycleEventRecorder()
  let application = try await EngineServiceFactory.make(logger: logger, startup: startup)
  let service = EngineProbeService(
    generation: configuration.generation,
    recorder: recorder,
    application: application
  )
  await startup.begin(.reconciliation)
  try service.reconcileBeforeListening()
  let lifecycleMonitor = await MainActor.run {
    let monitor = EngineLifecycleMonitor(application: application.application)
    monitor.start()
    return monitor
  }
  await startup.begin(.listener)
  let delegate = try EngineProbeListenerDelegate(service: service)
  let listener = NSXPCListener(machServiceName: LifecycleProbeConstants.helperIdentifier)
  listener.delegate = delegate
  listener.resume()
  let lifetime = EngineServiceLifetime(
    retaining: [delegate, listener, engineLock, lifecycleMonitor]
  )
  await lifetime.wait()
  throw EngineClientError(.internalFailure)
}

@main
private struct JidokaCodeEngineMain {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["--probe"] {
        try runOneShotProbe()
      }
      #if DEBUG
        if arguments == ["--path-probe"] {
          try runOneShotProbe(validateRuntime: false)
        }
      #endif
      if arguments.first == "--service" {
        try await runService(arguments: arguments)
      }
      throw LifecycleProbeError.invalidArguments
    } catch {
      FileHandle.standardError.write(Data("engine probe failed: ENGINE_START_FAILED\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
