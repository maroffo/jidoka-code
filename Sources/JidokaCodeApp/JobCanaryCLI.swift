import Foundation
import JidokaCodeCore

private final class JobCanaryXPCBox: @unchecked Sendable {
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

struct JobCanaryCLIReport: Codable, Sendable {
  let action: String
  let canary: JobCanaryReport?
  let recovery: JobCanaryRecoveryReport?
  let retry: JobCanaryPiRetryReport?
  let replacement: JobCanaryRoleHostReplacementReport?
  let generationRollover: JobCanaryGenerationRolloverReport?
  let generationRolloverQ4: JobCanaryGenerationRolloverQ4Report?
  let checkpoint: EngineCheckpointReceipt?
}

enum JobCanaryCLI {
  static func run(arguments: [String]) throws -> JobCanaryCLIReport {
    let command = try parse(arguments)
    let response = try send(command)
    switch command {
    case .previewJobCanary, .executeJobCanary:
      guard response.jobCanary != nil, response.jobCanaryRecovery == nil else {
        throw EngineClientError(.invalidResponse)
      }
    case .previewJobCanaryRecovery:
      guard response.jobCanary == nil, response.jobCanaryRecovery != nil else {
        throw EngineClientError(.invalidResponse)
      }
    case .executeJobCanaryRecovery:
      guard response.jobCanary != nil, response.jobCanaryRecovery != nil,
        response.jobCanaryPiRetry == nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .previewJobCanaryPiRetry:
      guard response.jobCanary == nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry != nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .executeJobCanaryPiRetry:
      guard response.jobCanary != nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry != nil,
        response.jobCanaryRoleHostReplacement == nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .previewJobCanaryRoleHostReplacement:
      guard response.jobCanary == nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry == nil,
        response.jobCanaryRoleHostReplacement != nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryRoleHostReplacement:
      guard response.jobCanary != nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry == nil,
        response.jobCanaryRoleHostReplacement != nil
      else { throw EngineClientError(.invalidResponse) }
    case .previewJobCanaryGenerationRollover,
      .executeJobCanaryGenerationRollover:
      guard response.jobCanary == nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry == nil,
        response.jobCanaryRoleHostReplacement == nil,
        response.jobCanaryGenerationRollover != nil,
        response.jobCanaryGenerationRolloverQ4 == nil
      else { throw EngineClientError(.invalidResponse) }
    case .previewJobCanaryGenerationRolloverQ4,
      .executeJobCanaryGenerationRolloverQ4:
      guard response.jobCanary == nil, response.jobCanaryRecovery == nil,
        response.jobCanaryPiRetry == nil,
        response.jobCanaryRoleHostReplacement == nil,
        response.jobCanaryGenerationRollover == nil,
        response.jobCanaryGenerationRolloverQ4 != nil
      else { throw EngineClientError(.invalidResponse) }
    default:
      throw EngineClientError(.invalidResponse)
    }
    return JobCanaryCLIReport(
      action: command.kind.rawValue,
      canary: response.jobCanary,
      recovery: response.jobCanaryRecovery,
      retry: response.jobCanaryPiRetry,
      replacement: response.jobCanaryRoleHostReplacement,
      generationRollover: response.jobCanaryGenerationRollover,
      generationRolloverQ4: response.jobCanaryGenerationRolloverQ4,
      checkpoint: response.checkpoint
    )
  }

  static func write(_ report: JobCanaryCLIReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func parse(_ arguments: [String]) throws -> EngineCommand {
    guard let action = arguments.first else { throw EngineClientError(.invalidCommand) }
    switch action {
    case "preview" where arguments.count == 5:
      return .previewJobCanary(
        try scope(
          jobID: arguments[1], boundary: arguments[2],
          repairEvidence: arguments[3], maximumParts: arguments[4]
        )
      )
    case "execute" where arguments.count == 6:
      return .executeJobCanary(
        try canaryAuthorization(arguments)
      )
    case "preview-recovery" where arguments.count == 6:
      return .previewJobCanaryRecovery(
        try canaryAuthorization(arguments)
      )
    case "execute-recovery" where arguments.count == 7:
      return .executeJobCanaryRecovery(
        try recoveryAuthorization(arguments)
      )
    case "preview-pi-retry" where arguments.count == 7:
      return .previewJobCanaryPiRetry(
        try recoveryAuthorization(arguments)
      )
    case "execute-pi-retry" where arguments.count == 8:
      let authorization = JobCanaryPiRetryAuthorization(
        recovery: try recoveryAuthorization(arguments),
        retryEvidenceSHA256: arguments[7]
      )
      try authorization.validate()
      return .executeJobCanaryPiRetry(authorization)
    case "preview-host-replacement" where arguments.count == 14:
      return .previewJobCanaryRoleHostReplacement(
        try replacementRequest(arguments)
      )
    case "preview-generation-rollover" where arguments.count == 2:
      let request: JobCanaryGenerationRolloverRequest = try canonicalArgument(arguments[1])
      try request.validate()
      return .previewJobCanaryGenerationRollover(request)
    case "execute-generation-rollover" where arguments.count == 2:
      let authorization: JobCanaryGenerationRolloverAuthorization = try canonicalArgument(
        arguments[1]
      )
      try authorization.validate()
      return .executeJobCanaryGenerationRollover(authorization)
    case "preview-generation-rollover-q4" where arguments.count == 2:
      let request: JobCanaryGenerationRolloverQ4Request = try canonicalArgument(arguments[1])
      try request.validate()
      return .previewJobCanaryGenerationRolloverQ4(request)
    case "execute-generation-rollover-q4" where arguments.count == 2:
      let authorization: JobCanaryGenerationRolloverQ4ExecutionAuthorization =
        try canonicalArgument(arguments[1])
      try authorization.validate()
      return .executeJobCanaryGenerationRolloverQ4(authorization)
    case "execute-host-replacement" where arguments.count == 22:
      let authorization = JobCanaryRoleHostReplacementAuthorization(
        request: try replacementRequest(arguments),
        replacementEvidenceSHA256: arguments[14],
        q4Binding: JobCanaryRoleHostReplacementQ4Binding(
          descriptorSHA256: arguments[15],
          configurationSHA256: arguments[16],
          promptSHA256: arguments[17],
          workflowConfigurationSHA256: arguments[18],
          priorLaunchDescriptorSHA256: arguments[19],
          priorLaunchConfigurationSHA256: arguments[20],
          resourceTreeSHA256: arguments[21]
        )
      )
      try authorization.validate()
      return .executeJobCanaryRoleHostReplacement(authorization)
    default:
      throw EngineClientError(.invalidCommand)
    }
  }

  private static func canonicalArgument<T: Codable>(_ value: String) throws -> T {
    guard value.utf8.count <= 262_144,
      let data = Data(base64Encoded: value), !data.isEmpty, data.count <= 196_608,
      data.base64EncodedString() == value,
      let decoded = try? JSONDecoder().decode(T.self, from: data)
    else { throw EngineClientError(.invalidCommand) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard try encoder.encode(decoded) == data else {
      throw EngineClientError(.invalidCommand)
    }
    return decoded
  }

  private static func replacementRequest(
    _ arguments: [String]
  ) throws -> JobCanaryRoleHostReplacementRequest {
    let retry = JobCanaryPiRetryAuthorization(
      recovery: try recoveryAuthorization(arguments),
      retryEvidenceSHA256: arguments[7]
    )
    try retry.validate()
    guard let stalePaneRevision = UInt64(arguments[11]),
      let stalePaneHadTokens = Self.strictBoolean(arguments[12])
    else { throw EngineClientError(.invalidCommand) }
    let request = JobCanaryRoleHostReplacementRequest(
      retry: retry,
      incidentAuditSHA256: arguments[8],
      plannedReplacementRoleHostID: arguments[9],
      plannedLaunchAttemptID: arguments[10],
      stalePaneRevision: stalePaneRevision,
      stalePaneHadTokens: stalePaneHadTokens,
      stalePaneTokensSHA256: arguments[13]
    )
    try request.validate()
    return request
  }

  private static func strictBoolean(_ value: String) -> Bool? {
    switch value {
    case "true": true
    case "false": false
    default: nil
    }
  }

  private static func recoveryAuthorization(
    _ arguments: [String]
  ) throws -> JobCanaryRecoveryAuthorization {
    let authorization = JobCanaryRecoveryAuthorization(
      canary: try canaryAuthorization(arguments),
      recoveryEvidenceSHA256: arguments[6]
    )
    try authorization.validate()
    return authorization
  }

  private static func canaryAuthorization(
    _ arguments: [String]
  ) throws -> JobCanaryAuthorization {
    let authorization = JobCanaryAuthorization(
      scope: try scope(
        jobID: arguments[1],
        boundary: arguments[2],
        repairEvidence: arguments[3],
        maximumParts: arguments[4]
      ),
      previewEvidenceSHA256: arguments[5]
    )
    try authorization.validate()
    return authorization
  }

  private static func scope(
    jobID: String,
    boundary: String,
    repairEvidence: String,
    maximumParts: String
  ) throws -> JobCanaryScope {
    guard let id = UUID(uuidString: jobID), id.uuidString.lowercased() == jobID,
      let epoch = Int64(boundary), let maximum = Int(maximumParts)
    else { throw EngineClientError(.invalidCommand) }
    let value = JobCanaryScope(
      jobID: id,
      boundaryEpochSeconds: epoch,
      repairEvidenceSHA256: repairEvidence,
      maximumCommentParts: maximum
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
    let box = JobCanaryXPCBox()
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
    let timeout = responseTimeoutSeconds(for: command.kind)
    guard semaphore.wait(timeout: .now() + .seconds(timeout)) == .success else {
      connection.invalidate()
      throw EngineClientError(.timedOut)
    }
    connection.invalidate()
    guard let result = box.load() else { throw EngineClientError(.invalidResponse) }
    return try result.get()
  }

  static func responseTimeoutSeconds(for command: EngineCommandKind) -> Int {
    [
      .previewJobCanaryPiRetry,
      .previewJobCanaryRoleHostReplacement,
      .executeJobCanary,
      .executeJobCanaryRecovery,
      .executeJobCanaryPiRetry,
      .executeJobCanaryRoleHostReplacement,
      .executeJobCanaryGenerationRollover,
      .previewJobCanaryGenerationRolloverQ4,
      .executeJobCanaryGenerationRolloverQ4,
    ].contains(command) ? 3_500 : 30
  }
}
