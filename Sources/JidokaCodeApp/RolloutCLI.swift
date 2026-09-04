import Foundation
import JidokaCodeCore

private final class RolloutCLIXPCBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<EngineCommandResponse, Error>?

  func store(_ value: Result<EngineCommandResponse, Error>) {
    lock.lock()
    result = value
    lock.unlock()
  }

  func load() -> Result<EngineCommandResponse, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

struct RolloutCLIReport: Codable, Sendable {
  let action: String
  let rollout: RolloutOperatorReport?
  let preview: RolloutPreview?
  let recoveryPreview: RolloutRecoveryPreview?
  let checkpoint: EngineCheckpointReceipt?
}

enum RolloutCLI {
  static func run(arguments: [String]) throws -> RolloutCLIReport {
    let command = try parse(arguments)
    let response = try send(command)
    return RolloutCLIReport(
      action: command.kind.rawValue,
      rollout: response.state.rollout,
      preview: response.rolloutPreview,
      recoveryPreview: response.rolloutRecoveryPreview,
      checkpoint: response.checkpoint
    )
  }

  static func write(_ report: RolloutCLIReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func parse(_ arguments: [String]) throws -> EngineCommand {
    guard let action = arguments.first else { throw EngineClientError(.invalidCommand) }
    switch action {
    case "preview-exact" where arguments.count == 2:
      let input: RolloutPreviewInput = try canonicalArgument(arguments[1])
      guard input.scope.mode == .exactObject else {
        throw EngineClientError(.invalidCommand)
      }
      return .previewRollout(input)
    case "preview-finite" where arguments.count == 2:
      let input: RolloutPreviewInput = try canonicalArgument(arguments[1])
      guard input.scope.mode == .finiteWindow else {
        throw EngineClientError(.invalidCommand)
      }
      return .previewFiniteWindow(input)
    case "activate-exact" where arguments.count == 4:
      return .activateRollout(try activation(arguments, mode: .exactObject))
    case "activate-finite" where arguments.count == 4:
      return .activateFiniteWindow(try activation(arguments, mode: .finiteWindow))
    case "status" where arguments.count == 1:
      return .rolloutStatus
    case "stop" where arguments.count == 4:
      guard let timeout = Int(arguments[3]) else {
        throw EngineClientError(.invalidCommand)
      }
      let request = RolloutStopRequest(
        authorizationID: arguments[1],
        previewSHA256: arguments[2],
        timeoutMilliseconds: timeout
      )
      try request.validate()
      return .stopAndDrainRollout(request)
    case "preview-recovery" where arguments.count == 3:
      let request = RolloutRecoveryRequest(
        authorizationID: arguments[1],
        previewSHA256: arguments[2]
      )
      try request.validate()
      return .previewRolloutRecovery(request)
    case "execute-recovery" where arguments.count == 3:
      let authorization = RolloutRecoveryAuthorization(
        approvedCanonicalJSON: try canonicalData(arguments[1]),
        confirmedSHA256: arguments[2]
      )
      try authorization.validate()
      return .executeRolloutRecovery(authorization)
    case "poll-finite" where arguments.count == 1:
      return .pollNow
    default:
      throw EngineClientError(.invalidCommand)
    }
  }

  private static func activation(
    _ arguments: [String],
    mode: RolloutScopeMode
  ) throws -> RolloutActivationRequest {
    guard let authorizationID = UUID(uuidString: arguments[1]),
      authorizationID.uuidString.lowercased() == arguments[1]
    else {
      throw EngineClientError(.invalidCommand)
    }
    let request = RolloutActivationRequest(
      authorizationID: authorizationID,
      approvedCanonicalJSON: try canonicalData(arguments[2]),
      confirmedSHA256: arguments[3]
    )
    try request.validate(mode: mode)
    return request
  }

  private static func canonicalArgument<T: Codable>(_ value: String) throws -> T {
    let data = try canonicalData(value)
    do {
      return try RolloutCanonicalJSON.decodeCanonical(T.self, from: data)
    } catch {
      throw EngineClientError(.invalidCommand)
    }
  }

  private static func canonicalData(_ value: String) throws -> Data {
    guard value.utf8.count <= 1_398_104,
      let data = Data(base64Encoded: value),
      !data.isEmpty,
      data.count <= 1_048_576,
      data.base64EncodedString() == value
    else {
      throw EngineClientError(.invalidCommand)
    }
    return data
  }

  private static func send(_ command: EngineCommand) throws -> EngineCommandResponse {
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
    let semaphore = DispatchSemaphore(value: 0)
    let box = RolloutCLIXPCBox()
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
      box.store(.failure(EngineClientError(.unavailable)))
      semaphore.signal()
    }
    guard let service = proxy as? EngineProbeXPCProtocol else {
      connection.invalidate()
      throw EngineClientError(.invalidResponse)
    }
    connection.resume()
    service.handle(requestData) { responseData, errorCode in
      do {
        guard errorCode == nil, let responseData else {
          throw EngineClientError(.unavailable)
        }
        let response = try JSONDecoder().decode(EngineXPCResponse.self, from: responseData)
        box.store(.success(try response.validate(for: request)))
      } catch let error as EngineClientError {
        box.store(.failure(error))
      } catch {
        box.store(.failure(EngineClientError(.invalidResponse)))
      }
      semaphore.signal()
    }
    let timeout = command.kind == .stopAndDrainRollout ? 700 : 30
    guard semaphore.wait(timeout: .now() + .seconds(timeout)) == .success else {
      connection.invalidate()
      throw EngineClientError(.timedOut)
    }
    connection.invalidate()
    guard let result = box.load() else { throw EngineClientError(.invalidResponse) }
    return try result.get()
  }
}
