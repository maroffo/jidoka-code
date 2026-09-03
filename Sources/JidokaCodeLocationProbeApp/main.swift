import AppKit
import Foundation
import JidokaCodeCore
import JidokaCodeLocationProbeSupport
import ServiceManagement

private struct LocationProbeReport: Codable {
  let action: String
  let applicationPath: String
  let bundleIdentifier: String
  let bundleVersion: String
  let helperResponse: LocationProbeResponse?
  let processIdentifier: Int32
  let serviceStatus: String?
  let shortVersion: String
}

private final class LocationProbeResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<LocationProbeResponse, Error>?

  func store(_ result: Result<LocationProbeResponse, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<LocationProbeResponse, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

@main
private struct JidokaCodeLocationProbeApp {
  @MainActor
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments.isEmpty || arguments == ["serve"] {
        try serve()
      }
      let report = try execute(arguments: arguments)
      try write(report)
      exit(EXIT_SUCCESS)
    } catch {
      FileHandle.standardError.write(Data("location probe failed: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  @MainActor
  private static func execute(arguments: [String]) throws -> LocationProbeReport {
    switch arguments {
    case ["self-check"]:
      return try report(action: "self-check", serviceStatus: nil, helperResponse: nil)
    case ["agent", "status"]:
      return try report(
        action: "agent.status",
        serviceStatus: serviceStatus(agentService.status),
        helperResponse: nil
      )
    case ["agent", "register"]:
      try agentService.register()
      return try report(
        action: "agent.register",
        serviceStatus: serviceStatus(agentService.status),
        helperResponse: nil
      )
    case ["agent", "unregister"]:
      try agentService.unregister()
      return try report(
        action: "agent.unregister",
        serviceStatus: serviceStatus(agentService.status),
        helperResponse: nil
      )
    case ["helper", "round-trip"]:
      return try report(
        action: "helper.round-trip",
        serviceStatus: nil,
        helperResponse: send(operation: .roundTrip)
      )
    case ["helper", "shutdown"]:
      return try report(
        action: "helper.shutdown",
        serviceStatus: nil,
        helperResponse: send(operation: .shutdown)
      )
    case ["main", "graceful-quit"]:
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(LocationProbeConstants.quitNotification),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
      )
      return try report(action: "main.graceful-quit", serviceStatus: nil, helperResponse: nil)
    default:
      throw LocationProbeError.invalidArguments
    }
  }

  @MainActor
  private static func serve() throws -> Never {
    _ = try bundleEvidence()
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let token = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(LocationProbeConstants.quitNotification),
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        NSApplication.shared.terminate(nil)
      }
    }
    withExtendedLifetime(token) {
      application.run()
    }
    throw LocationProbeError.remoteFailure("application run loop exited unexpectedly")
  }

  @MainActor
  private static var agentService: SMAppService {
    SMAppService.agent(plistName: LocationProbeConstants.launchAgentPlistName)
  }

  private static func serviceStatus(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
  }

  private static func send(operation: LocationProbeOperation) throws -> LocationProbeResponse {
    let evidence = try bundleEvidence()
    let helperPeerValidator = EngineXPCPeerValidator(
      expectedPeerExecutableURL: URL(fileURLWithPath: evidence.helperPath, isDirectory: false)
    )
    let request = LocationProbeRequest(
      operation: operation,
      nonce: UUID().uuidString.lowercased()
    )
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let requestData = try encoder.encode(request)
    let connection = NSXPCConnection(
      machServiceName: LocationProbeConstants.helperIdentifier,
      options: []
    )
    connection.remoteObjectInterface = NSXPCInterface(with: LocationProbeXPCProtocol.self)
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = LocationProbeResultBox()
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
      resultBox.store(.failure(LocationProbeError.remoteFailure(String(describing: error))))
      semaphore.signal()
    }
    guard let service = proxy as? LocationProbeXPCProtocol else {
      throw LocationProbeError.invalidResponse
    }
    connection.resume()
    service.handle(requestData) { responseData, errorMessage in
      do {
        if let errorMessage {
          throw LocationProbeError.remoteFailure(errorMessage)
        }
        guard let responseData else {
          throw LocationProbeError.invalidResponse
        }
        let response = try JSONDecoder().decode(LocationProbeResponse.self, from: responseData)
        let peerProcessID = connection.processIdentifier
        guard
          helperPeerValidator.accepts(
            processID: peerProcessID,
            effectiveUserID: connection.effectiveUserIdentifier
          )
        else {
          throw LocationProbeError.invalidResponse
        }
        try response.validate(
          for: request,
          expectedApplicationPath: evidence.applicationPath,
          expectedHelperPath: evidence.helperPath,
          expectedHelperProcessID: peerProcessID
        )
        resultBox.store(.success(response))
      } catch {
        resultBox.store(.failure(error))
      }
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(10)) == .success else {
      connection.invalidate()
      throw LocationProbeError.timeout
    }
    connection.invalidate()
    guard let result = resultBox.load() else {
      throw LocationProbeError.invalidResponse
    }
    return try result.get()
  }

  private static func report(
    action: String,
    serviceStatus: String?,
    helperResponse: LocationProbeResponse?
  ) throws -> LocationProbeReport {
    let evidence = try bundleEvidence()
    return LocationProbeReport(
      action: action,
      applicationPath: evidence.applicationPath,
      bundleIdentifier: evidence.bundleIdentifier,
      bundleVersion: evidence.bundleVersion,
      helperResponse: helperResponse,
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      serviceStatus: serviceStatus,
      shortVersion: evidence.shortVersion
    )
  }

  private struct BundleEvidence {
    let applicationPath: String
    let bundleIdentifier: String
    let bundleVersion: String
    let helperPath: String
    let shortVersion: String
  }

  private static func bundleEvidence() throws -> BundleEvidence {
    let bundle = Bundle.main
    guard bundle.bundleIdentifier == LocationProbeConstants.applicationIdentifier,
      bundle.bundleURL.pathExtension == "app",
      let executableURL = bundle.executableURL,
      executableURL.lastPathComponent == LocationProbeConstants.mainExecutableName,
      let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
      let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    else {
      throw LocationProbeError.invalidBundle
    }
    let applicationPath = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    let helperPath = bundle.bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
      .appendingPathComponent(LocationProbeConstants.helperExecutableName, isDirectory: false)
      .resolvingSymlinksInPath().standardizedFileURL.path
    return BundleEvidence(
      applicationPath: applicationPath,
      bundleIdentifier: LocationProbeConstants.applicationIdentifier,
      bundleVersion: bundleVersion,
      helperPath: helperPath,
      shortVersion: shortVersion
    )
  }

  private static func write(_ report: LocationProbeReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}
