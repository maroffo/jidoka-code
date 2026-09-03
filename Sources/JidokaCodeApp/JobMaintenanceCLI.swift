import Foundation
import JidokaCodeCore

private final class JobMaintenanceXPCBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<EngineCommandResponse, Error>?

  func store(_ result: Result<EngineCommandResponse, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<EngineCommandResponse, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

struct JobMaintenanceCLIReport: Codable, Sendable {
  let action: String
  let maintenance: JobMaintenanceReport
  let checkpoint: EngineCheckpointReceipt?
}

enum JobMaintenanceCLI {
  static func run(arguments: [String]) throws -> JobMaintenanceCLIReport {
    let command = try parse(arguments)
    let response = try send(command)
    guard let maintenance = response.jobMaintenance else {
      throw EngineClientError(.invalidResponse)
    }
    return JobMaintenanceCLIReport(
      action: command.kind.rawValue,
      maintenance: maintenance,
      checkpoint: response.checkpoint
    )
  }

  static func write(_ report: JobMaintenanceCLIReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func parse(_ arguments: [String]) throws -> EngineCommand {
    guard let action = arguments.first else { throw EngineClientError(.invalidCommand) }
    switch action {
    case "preview-retire-before" where arguments.count == 2:
      return .previewJobMaintenance(
        try scope(operation: .retireBefore, boundary: arguments[1])
      )
    case "preview-retry-resource-failures-after" where arguments.count == 2:
      return .previewJobMaintenance(
        try scope(operation: .retryResourceFailuresAfter, boundary: arguments[1])
      )
    case "apply-retire-before" where arguments.count == 4:
      return .applyJobMaintenance(
        try authorization(
          operation: .retireBefore,
          boundary: arguments[1],
          count: arguments[2],
          evidence: arguments[3]
        )
      )
    case "apply-retry-resource-failures-after" where arguments.count == 4:
      return .applyJobMaintenance(
        try authorization(
          operation: .retryResourceFailuresAfter,
          boundary: arguments[1],
          count: arguments[2],
          evidence: arguments[3]
        )
      )
    default:
      throw EngineClientError(.invalidCommand)
    }
  }

  private static func scope(
    operation: JobMaintenanceOperation,
    boundary: String
  ) throws -> JobMaintenanceScope {
    guard let epoch = Int64(boundary) else { throw EngineClientError(.invalidCommand) }
    let scope = JobMaintenanceScope(operation: operation, boundaryEpochSeconds: epoch)
    try scope.validate()
    return scope
  }

  private static func authorization(
    operation: JobMaintenanceOperation,
    boundary: String,
    count: String,
    evidence: String
  ) throws -> JobMaintenanceAuthorization {
    guard let expectedCount = Int(count) else { throw EngineClientError(.invalidCommand) }
    let value = JobMaintenanceAuthorization(
      scope: try scope(operation: operation, boundary: boundary),
      expectedCount: expectedCount,
      evidenceSHA256: evidence
    )
    try value.validate()
    return value
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
    let box = JobMaintenanceXPCBox()
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
    let timeoutSeconds = command.kind == .applyJobMaintenance ? 240 : 30
    guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
      connection.invalidate()
      throw EngineClientError(.timedOut)
    }
    connection.invalidate()
    guard let result = box.load() else { throw EngineClientError(.invalidResponse) }
    return try result.get()
  }
}
