import AppKit
import Foundation
import JidokaCodeCore
import ServiceManagement

struct LifecycleCLIReport: Codable, Sendable {
  let action: String
  let keychainSHA256: String?
  let roundTrips: EngineRoundTripReport?
  let snapshot: EngineSnapshot?
  let status: LifecycleServiceStatus?

  init(
    action: String,
    keychainSHA256: String? = nil,
    roundTrips: EngineRoundTripReport?,
    snapshot: EngineSnapshot?,
    status: LifecycleServiceStatus?
  ) {
    self.action = action
    self.keychainSHA256 = keychainSHA256
    self.roundTrips = roundTrips
    self.snapshot = snapshot
    self.status = status
  }
}

enum LifecycleCLI {
  static func run(arguments: [String]) throws -> LifecycleCLIReport {
    let command = try LifecycleCommand.parse(arguments)
    switch command {
    case .mainStatus:
      return try statusReport(action: "main.status", service: .mainApp)
    case .mainRegister:
      try SMAppService.mainApp.register()
      return try statusReport(action: "main.register", service: .mainApp)
    case .mainUnregister:
      try SMAppService.mainApp.unregister()
      return try statusReport(action: "main.unregister", service: .mainApp)
    case .mainGracefulQuit:
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(LifecycleProbeConstants.mainQuitNotification),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
      )
      return LifecycleCLIReport(
        action: "main.graceful-quit", roundTrips: nil, snapshot: nil, status: nil)
    case .agentStatus:
      return try statusReport(action: "agent.status", service: agentService)
    case .agentRegister:
      try agentService.register()
      return try statusReport(action: "agent.register", service: agentService)
    case .agentUnregister:
      try agentService.unregister()
      return try statusReport(action: "agent.unregister", service: agentService)
    case .directRoundTrips(let count):
      let report = try DirectEngineClient().run(roundTrips: count)
      return LifecycleCLIReport(
        action: "direct.round-trips", roundTrips: report, snapshot: report.snapshot, status: nil)
    case .helperSnapshot:
      let snapshot = try HelperEngineClient().snapshot()
      return LifecycleCLIReport(
        action: "helper.snapshot", roundTrips: nil, snapshot: snapshot, status: nil)
    case .helperRoundTrips(let count):
      let report = try HelperEngineClient().run(roundTrips: count)
      return LifecycleCLIReport(
        action: "helper.round-trips", roundTrips: report, snapshot: report.snapshot, status: nil)
    case .helperCrash:
      let snapshot = try HelperEngineClient().control(.crash)
      return LifecycleCLIReport(
        action: "helper.crash", roundTrips: nil, snapshot: snapshot, status: nil)
    case .helperGracefulQuit:
      let snapshot = try HelperEngineClient().control(.gracefulQuit)
      return LifecycleCLIReport(
        action: "helper.graceful-quit", roundTrips: nil, snapshot: snapshot, status: nil)
    case .helperKeychainDigest:
      let response = try HelperEngineClient().keychainDigest()
      return LifecycleCLIReport(
        action: "helper.keychain-digest",
        keychainSHA256: response.keychainSHA256,
        roundTrips: nil,
        snapshot: response.snapshot,
        status: nil
      )
    }
  }

  static func write(_ report: LifecycleCLIReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private static var agentService: SMAppService {
    SMAppService.agent(plistName: LifecycleProbeConstants.launchAgentPlistName)
  }

  private static func statusReport(
    action: String,
    service: SMAppService
  ) throws -> LifecycleCLIReport {
    let status = try LifecycleServiceStatus(
      rawServiceManagementValue: service.status.rawValue)
    return LifecycleCLIReport(
      action: action,
      roundTrips: nil,
      snapshot: nil,
      status: status
    )
  }
}

private final class MainQuitObserver: @unchecked Sendable {
  static let shared = MainQuitObserver()
  private var token: NSObjectProtocol?

  @MainActor
  func start() {
    guard token == nil else { return }
    token = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(LifecycleProbeConstants.mainQuitNotification),
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in
        NSApplication.shared.terminate(nil)
      }
    }
  }
}

@MainActor
func startMainQuitObserver() {
  MainQuitObserver.shared.start()
}

private final class XPCResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<EngineProbeXPCResponse, Error>?

  func store(_ result: Result<EngineProbeXPCResponse, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<EngineProbeXPCResponse, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

private struct HelperEngineClient: LifecycleProbeClient {
  func snapshot() throws -> EngineSnapshot {
    try send(EngineProbeXPCRequest(operation: .snapshot)).snapshot
  }

  func roundTrip(_ request: EngineRoundTripRequest) throws -> EngineRoundTripResponse {
    let envelope = EngineProbeXPCRequest(operation: .roundTrip, roundTrip: request)
    let response = try send(envelope)
    guard let roundTrip = response.roundTrip else {
      throw LifecycleProbeError.invalidResponse
    }
    return roundTrip
  }

  func control(_ operation: EngineProbeXPCOperation) throws -> EngineSnapshot {
    guard operation == .crash || operation == .gracefulQuit else {
      throw LifecycleProbeError.unsupportedOperation(operation.rawValue)
    }
    return try send(EngineProbeXPCRequest(operation: operation)).snapshot
  }

  func keychainDigest() throws -> EngineProbeXPCResponse {
    try send(EngineProbeXPCRequest(operation: .keychainDigest))
  }

  private func send(_ request: EngineProbeXPCRequest) throws -> EngineProbeXPCResponse {
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let requestData = try encoder.encode(request)
    let connection = NSXPCConnection(
      machServiceName: LifecycleProbeConstants.helperIdentifier,
      options: []
    )
    connection.remoteObjectInterface = NSXPCInterface(with: EngineProbeXPCProtocol.self)
    let semaphore = DispatchSemaphore(value: 0)
    let box = XPCResultBox()
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
      box.store(.failure(LifecycleProbeError.remoteFailure("XPC_REMOTE_FAILURE")))
      semaphore.signal()
    }
    guard let service = proxy as? EngineProbeXPCProtocol else {
      connection.invalidate()
      throw LifecycleProbeError.invalidResponse
    }
    connection.resume()
    service.handle(requestData) { responseData, errorMessage in
      do {
        if let errorMessage {
          throw LifecycleProbeError.remoteFailure(errorMessage)
        }
        guard let responseData else {
          throw LifecycleProbeError.invalidResponse
        }
        let response = try JSONDecoder().decode(
          EngineProbeXPCResponse.self, from: responseData)
        try response.validate(for: request)
        box.store(.success(response))
      } catch {
        box.store(.failure(error))
      }
      semaphore.signal()
    }
    let timeout: DispatchTimeInterval =
      request.operation == .keychainDigest ? .seconds(60) : .seconds(10)
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
      connection.invalidate()
      throw LifecycleProbeError.timeout
    }
    connection.invalidate()
    guard let result = box.load() else {
      throw LifecycleProbeError.invalidResponse
    }
    return try result.get()
  }
}
