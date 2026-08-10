import CryptoKit
import Darwin
import Foundation

public enum PiTUIRuntimeError: Error, Equatable, Sendable {
  case invalidConfiguration
  case unsafePath
  case fileAlreadyExists
  case fileUnavailable
  case fileTooLarge
  case malformedFile
  case identityMismatch
  case divergentFile
  case writeFailed(Int32)
}

public enum PiTUILaunchMode: String, Codable, Sendable {
  case fresh
  case resume
}

public struct PiTUIModelIdentity: Equatable, Sendable {
  public let provider: String
  public let modelID: String
  public let thinkingLevel: String

  public init(provider: String, modelID: String, thinkingLevel: String) throws {
    guard provider.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,63}$/) != nil,
      modelID.wholeMatch(of: /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/) != nil,
      ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        .contains(thinkingLevel)
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    self.provider = provider
    self.modelID = modelID
    self.thinkingLevel = thinkingLevel
  }

  public var argument: String { "\(provider)/\(modelID):\(thinkingLevel)" }
}

public struct PiTUIRunConfiguration: Equatable, Sendable {
  public let runID: String
  public let runNonce: String
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let promptURL: URL
  public let promptSHA256: String
  public let channelDirectory: URL
  public let workspaceRoot: URL
  public let sessionDirectory: URL
  public let sessionName: String
  public let launchMode: PiTUILaunchMode
  public let expectedSessionID: String?
  public let resumeBoundarySHA256: String?
  public let model: PiTUIModelIdentity
  public let expectedCommands: [PiRPCCommandProvenance]
  public let acknowledgementTimeoutMilliseconds: Int

  public init(
    runID: String,
    runNonce: String,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    promptURL: URL,
    promptSHA256: String,
    channelDirectory: URL,
    workspaceRoot: URL,
    sessionDirectory: URL,
    sessionName: String,
    launchMode: PiTUILaunchMode,
    expectedSessionID: String?,
    resumeBoundarySHA256: String? = nil,
    model: PiTUIModelIdentity,
    expectedCommands: [PiRPCCommandProvenance],
    acknowledgementTimeoutMilliseconds: Int = 300_000
  ) throws {
    guard runID.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) != nil,
      runNonce.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      PiWorkflowResourceCatalog.valid(role: role, for: workflow),
      promptSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      sessionName.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) != nil,
      (1_000...600_000).contains(acknowledgementTimeoutMilliseconds),
      Self.valid(commands: expectedCommands),
      try PiTUIFileProtocol.safePrivateDirectory(channelDirectory),
      try PiTUIFileProtocol.safePrivateDirectory(workspaceRoot),
      try PiTUIFileProtocol.safePrivateDirectory(sessionDirectory),
      PiTUIFileProtocol.rootsAreDisjoint([
        channelDirectory, workspaceRoot, sessionDirectory,
      ]),
      try PiTUIFileProtocol.safePrivateFile(promptURL, maximumBytes: 4 * 1_024 * 1_024),
      PiTUIFileProtocol.isChild(promptURL, of: channelDirectory),
      PiTUIFileProtocol.sha256(
        try PiTUIFileProtocol.readPrivateFile(
          promptURL,
          maximumBytes: 4 * 1_024 * 1_024
        )) == promptSHA256
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    switch launchMode {
    case .fresh:
      guard expectedSessionID == nil, resumeBoundarySHA256 == nil else {
        throw PiTUIRuntimeError.invalidConfiguration
      }
    case .resume:
      guard
        expectedSessionID?.wholeMatch(
          of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
        ) != nil,
        resumeBoundarySHA256 == nil
          || resumeBoundarySHA256?.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
      else {
        throw PiTUIRuntimeError.invalidConfiguration
      }
    }
    self.runID = runID
    self.runNonce = runNonce
    self.workflow = workflow
    self.role = role
    self.promptURL = try PiTUIFileProtocol.canonicalExistingURL(promptURL)
    self.promptSHA256 = promptSHA256
    self.channelDirectory = try PiTUIFileProtocol.canonicalExistingURL(channelDirectory)
    self.workspaceRoot = try PiTUIFileProtocol.canonicalExistingURL(workspaceRoot)
    self.sessionDirectory = try PiTUIFileProtocol.canonicalExistingURL(sessionDirectory)
    self.sessionName = sessionName
    self.launchMode = launchMode
    self.expectedSessionID = expectedSessionID
    self.resumeBoundarySHA256 = resumeBoundarySHA256
    self.model = model
    self.expectedCommands = expectedCommands
    self.acknowledgementTimeoutMilliseconds = acknowledgementTimeoutMilliseconds
  }

  public func encoded() throws -> Data {
    let commands: [[String: String]] = expectedCommands.map {
      [
        "name": $0.name,
        "origin": $0.origin,
        "path": $0.path,
        "scope": $0.scope,
        "source": $0.source,
      ]
    }
    let object: [String: Any] = [
      "acknowledgementTimeoutMilliseconds": acknowledgementTimeoutMilliseconds,
      "channelDirectory": channelDirectory.path,
      "expectedCommands": commands,
      "expectedSessionID": expectedSessionID ?? NSNull(),
      "launchMode": launchMode.rawValue,
      "modelID": model.modelID,
      "modelProvider": model.provider,
      "promptPath": promptURL.path,
      "promptSHA256": promptSHA256,
      "resumeBoundarySHA256": resumeBoundarySHA256 ?? NSNull(),
      "role": role.rawValue,
      "runID": runID,
      "runNonce": runNonce,
      "schemaVersion": 3,
      "sessionDirectory": sessionDirectory.path,
      "sessionName": sessionName,
      "thinkingLevel": model.thinkingLevel,
      "workflow": workflow.rawValue,
      "workspaceRoot": workspaceRoot.path,
    ]
    return try PiTUIFileProtocol.canonicalJSONData(object)
  }

  public func write(to destination: URL) throws {
    guard PiTUIFileProtocol.isChild(destination, of: channelDirectory) else {
      throw PiTUIRuntimeError.unsafePath
    }
    try PiTUIFileProtocol.createPrivateFile(data: encoded(), at: destination)
  }

  public static func load(from source: URL) throws -> Self {
    let data = try PiTUIFileProtocol.readPrivateFile(source, maximumBytes: 1_048_576)
    guard data.last == 0x0A,
      let object = try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys)
        == Set([
          "acknowledgementTimeoutMilliseconds", "channelDirectory", "expectedCommands",
          "expectedSessionID", "launchMode", "modelID", "modelProvider", "promptPath",
          "promptSHA256", "resumeBoundarySHA256", "role", "runID", "runNonce", "schemaVersion",
          "sessionDirectory",
          "sessionName", "thinkingLevel", "workflow", "workspaceRoot",
        ]),
      object["schemaVersion"] as? Int == 3,
      let runID = object["runID"] as? String,
      let runNonce = object["runNonce"] as? String,
      let workflowValue = object["workflow"] as? String,
      let workflow = PiWorkflowKind(rawValue: workflowValue),
      let roleValue = object["role"] as? String,
      let role = PiWorkflowRole(rawValue: roleValue),
      let promptPath = object["promptPath"] as? String,
      let promptSHA256 = object["promptSHA256"] as? String,
      let channelPath = object["channelDirectory"] as? String,
      let workspacePath = object["workspaceRoot"] as? String,
      let sessionPath = object["sessionDirectory"] as? String,
      let sessionName = object["sessionName"] as? String,
      let launchModeValue = object["launchMode"] as? String,
      let launchMode = PiTUILaunchMode(rawValue: launchModeValue),
      let modelProvider = object["modelProvider"] as? String,
      let modelID = object["modelID"] as? String,
      let thinkingLevel = object["thinkingLevel"] as? String,
      let commandObjects = object["expectedCommands"] as? [[String: Any]],
      let timeout = object["acknowledgementTimeoutMilliseconds"] as? Int
    else {
      throw PiTUIRuntimeError.malformedFile
    }
    let commands = try commandObjects.map { value -> PiRPCCommandProvenance in
      guard Set(value.keys) == Set(["name", "origin", "path", "scope", "source"]),
        let name = value["name"] as? String,
        let origin = value["origin"] as? String,
        let path = value["path"] as? String,
        let scope = value["scope"] as? String,
        let source = value["source"] as? String
      else {
        throw PiTUIRuntimeError.malformedFile
      }
      return PiRPCCommandProvenance(
        name: name,
        source: source,
        path: path,
        scope: scope,
        origin: origin
      )
    }
    let expectedSessionID: String?
    if object["expectedSessionID"] is NSNull {
      expectedSessionID = nil
    } else if let value = object["expectedSessionID"] as? String {
      expectedSessionID = value
    } else {
      throw PiTUIRuntimeError.malformedFile
    }
    let resumeBoundarySHA256: String?
    if object["resumeBoundarySHA256"] is NSNull {
      resumeBoundarySHA256 = nil
    } else if let value = object["resumeBoundarySHA256"] as? String {
      resumeBoundarySHA256 = value
    } else {
      throw PiTUIRuntimeError.malformedFile
    }
    let configuration = try Self(
      runID: runID,
      runNonce: runNonce,
      workflow: workflow,
      role: role,
      promptURL: URL(fileURLWithPath: promptPath),
      promptSHA256: promptSHA256,
      channelDirectory: URL(fileURLWithPath: channelPath, isDirectory: true),
      workspaceRoot: URL(fileURLWithPath: workspacePath, isDirectory: true),
      sessionDirectory: URL(fileURLWithPath: sessionPath, isDirectory: true),
      sessionName: sessionName,
      launchMode: launchMode,
      expectedSessionID: expectedSessionID,
      resumeBoundarySHA256: resumeBoundarySHA256,
      model: PiTUIModelIdentity(
        provider: modelProvider,
        modelID: modelID,
        thinkingLevel: thinkingLevel
      ),
      expectedCommands: commands,
      acknowledgementTimeoutMilliseconds: timeout
    )
    guard try configuration.encoded() == data,
      PiTUIFileProtocol.isChild(source, of: configuration.channelDirectory)
    else {
      throw PiTUIRuntimeError.malformedFile
    }
    return configuration
  }

  public static func writePrompt(_ prompt: Data, to destination: URL) throws -> String {
    guard !prompt.isEmpty, prompt.count <= 4 * 1_024 * 1_024,
      String(data: prompt, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    try PiTUIFileProtocol.createPrivateFile(data: prompt, at: destination)
    return PiTUIFileProtocol.sha256(prompt)
  }

  private static func valid(commands: [PiRPCCommandProvenance]) -> Bool {
    guard !commands.isEmpty, commands.count <= 8,
      Set(commands.map(\.name)).count == commands.count
    else {
      return false
    }
    return commands.allSatisfy {
      $0.name.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9:_-]{0,127}$/) != nil
        && ["extension", "skill"].contains($0.source)
        && !$0.path.isEmpty && $0.path.utf8.count <= 4_096
        && $0.scope == "temporary"
        && $0.origin == "top-level"
    }
  }
}

public struct PiTUIResultExpectation: Equatable, Sendable {
  public let runID: String
  public let runNonce: String
  public let terminalIdentity: PiRPCTerminalResultIdentity

  public init(
    runID: String,
    runNonce: String,
    terminalIdentity: PiRPCTerminalResultIdentity
  ) throws {
    guard runID.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/) != nil,
      runNonce.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    self.runID = runID
    self.runNonce = runNonce
    self.terminalIdentity = terminalIdentity
  }
}

public struct PiTUISessionIdentity: Equatable, Sendable {
  public let sessionID: String
  public let sessionFile: URL
  public let originLaunchMode: PiTUILaunchMode
  public let originResumeBoundarySHA256: String?

  public static func load(
    from channelDirectory: URL,
    configuration: PiTUIRunConfiguration
  ) throws -> Self {
    guard try PiTUIFileProtocol.safePrivateDirectory(channelDirectory),
      try PiTUIFileProtocol.canonicalExistingURL(channelDirectory)
        == configuration.channelDirectory
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    let data = try PiTUIFileProtocol.readPrivateFile(
      channelDirectory.appendingPathComponent("session.json"),
      maximumBytes: 64 * 1_024
    )
    guard data.last == 0x0A,
      let object = try JSONSerialization.jsonObject(
        with: Data(data.dropLast())
      ) as? [String: Any],
      Set(object.keys)
        == Set([
          "originLaunchMode", "originResumeBoundarySHA256", "runID", "runNonce",
          "schemaVersion", "sessionFile", "sessionID",
        ]),
      object["schemaVersion"] as? Int == 2,
      object["runID"] as? String == configuration.runID,
      object["runNonce"] as? String == configuration.runNonce,
      let sessionID = object["sessionID"] as? String,
      sessionID.wholeMatch(
        of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil,
      let sessionFile = object["sessionFile"] as? String,
      let originValue = object["originLaunchMode"] as? String,
      let origin = PiTUILaunchMode(rawValue: originValue)
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    let boundary: String?
    if object["originResumeBoundarySHA256"] is NSNull {
      boundary = nil
    } else if let value = object["originResumeBoundarySHA256"] as? String,
      value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    {
      boundary = value
    } else {
      throw PiTUIRuntimeError.identityMismatch
    }
    let sessionURL = URL(fileURLWithPath: sessionFile)
    guard PiTUIFileProtocol.isChild(sessionURL, of: configuration.sessionDirectory),
      try PiTUIFileProtocol.safePrivateFile(sessionURL, maximumBytes: 64 * 1_024 * 1_024),
      configuration.expectedSessionID.map({ $0 == sessionID }) ?? true,
      (configuration.launchMode == .fresh && origin == .fresh && boundary == nil
        && configuration.resumeBoundarySHA256 == nil)
        || (configuration.launchMode == .resume
          && ((configuration.resumeBoundarySHA256 == nil && origin == .fresh && boundary == nil)
            || (configuration.resumeBoundarySHA256 != nil && origin == .resume
              && boundary == configuration.resumeBoundarySHA256)))
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    return PiTUISessionIdentity(
      sessionID: sessionID,
      sessionFile: try PiTUIFileProtocol.canonicalExistingURL(sessionURL),
      originLaunchMode: origin,
      originResumeBoundarySHA256: boundary
    )
  }
}

public struct PiTUIPreparedResult: Equatable, Sendable {
  public let terminalResult: PiRPCTerminalResult
  public let envelope: Data
}

public struct PiTUIResultChannel: Sendable {
  public static let resultFileName = "result.json"
  public static let acknowledgementFileName = "acknowledgement.json"
  public static let releaseFileName = "release.json"
  public static let runtimeFailureFileName = "runtime-failure.json"

  public let directory: URL
  public let expectation: PiTUIResultExpectation

  public init(directory: URL, expectation: PiTUIResultExpectation) throws {
    guard try PiTUIFileProtocol.safePrivateDirectory(directory) else {
      throw PiTUIRuntimeError.unsafePath
    }
    self.directory = directory.standardizedFileURL
    self.expectation = expectation
  }

  public func preparedResult() throws -> PiRPCTerminalResult? {
    try preparedResultRecord()?.terminalResult
  }

  public func preparedResultRecord() throws -> PiTUIPreparedResult? {
    let url = directory.appendingPathComponent(Self.resultFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 4 * 1_024 * 1_024)
    return try Self.decodePreparedResult(data, expectation: expectation)
  }

  public static func decodePreparedResult(
    _ data: Data,
    expectation: PiTUIResultExpectation
  ) throws -> PiTUIPreparedResult {
    guard data.last == 0x0A,
      data.count <= 4 * 1_024 * 1_024,
      let object = try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys)
        == Set([
          "approvedCommandIDs", "artifactSHA256", "nonce", "payload", "role", "runID",
          "runNonce", "schemaVersion", "sessionBoundarySHA256", "workflow",
        ]),
      object["schemaVersion"] as? Int == 1,
      object["runID"] as? String == expectation.runID,
      object["runNonce"] as? String == expectation.runNonce,
      object["workflow"] as? String == expectation.terminalIdentity.workflow,
      object["role"] as? String == expectation.terminalIdentity.role,
      object["nonce"] as? String == expectation.terminalIdentity.nonce,
      object["artifactSHA256"] as? String == expectation.terminalIdentity.artifactSHA256,
      let sessionBoundarySHA256 = object["sessionBoundarySHA256"] as? String,
      sessionBoundarySHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      let approvedCommandIDs = object["approvedCommandIDs"] as? [String],
      Set(approvedCommandIDs).count == approvedCommandIDs.count,
      Set(approvedCommandIDs).isSubset(of: expectation.terminalIdentity.allowedCommandIDs),
      let payloadObject = object["payload"] as? [String: Any]
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    let boundaryObject: [String: Any] = [
      "approvedCommandIDs": approvedCommandIDs,
      "artifactSHA256": expectation.terminalIdentity.artifactSHA256,
      "nonce": expectation.terminalIdentity.nonce,
      "payload": payloadObject,
      "resultSequence": 1,
      "role": expectation.terminalIdentity.role,
      "schemaVersion": 1,
      "workflow": expectation.terminalIdentity.workflow,
    ]
    let boundaryData = try PiTUIFileProtocol.canonicalJSONData(boundaryObject)
    guard PiTUIFileProtocol.sha256(Data(boundaryData.dropLast())) == sessionBoundarySHA256 else {
      throw PiTUIRuntimeError.identityMismatch
    }
    let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
    let payload = try JSONDecoder().decode([String: PiJSONValue].self, from: payloadData)
    let result = PiRPCTerminalResult(
      workflow: expectation.terminalIdentity.workflow,
      role: expectation.terminalIdentity.role,
      nonce: expectation.terminalIdentity.nonce,
      artifactSHA256: expectation.terminalIdentity.artifactSHA256,
      approvedCommandIDs: approvedCommandIDs,
      payload: payload,
      recordSHA256: PiTUIFileProtocol.sha256(data),
      sessionBoundarySHA256: sessionBoundarySHA256
    )
    do {
      _ = try PiWorkflowResultDecoder.decode(result)
    } catch {
      throw PiTUIRuntimeError.malformedFile
    }
    return PiTUIPreparedResult(terminalResult: result, envelope: data)
  }

  @discardableResult
  public func acknowledgePreparedResult() throws -> PiRPCTerminalResult {
    guard let result = try preparedResult() else { throw PiTUIRuntimeError.fileUnavailable }
    try writeSignal(status: "accepted", resultSHA256: result.recordSHA256)
    return result
  }

  public func acceptedResult() throws -> PiRPCTerminalResult? {
    guard let result = try preparedResult() else { return nil }
    return try hasSignal(status: "accepted", resultSHA256: result.recordSHA256)
      ? result
      : nil
  }

  public func releaseAcceptedResult() throws {
    guard let result = try acceptedResult() else { throw PiTUIRuntimeError.fileUnavailable }
    try writeSignal(status: "release", resultSHA256: result.recordSHA256)
  }

  public func isReleased() throws -> Bool {
    guard let result = try acceptedResult() else { return false }
    return try hasSignal(status: "release", resultSHA256: result.recordSHA256)
  }

  public func runtimeFailureCode() throws -> String? {
    let url = directory.appendingPathComponent(Self.runtimeFailureFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard data.last == 0x0A,
      let object = try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys) == Set(["code", "runID", "runNonce", "schemaVersion", "status"]),
      object["schemaVersion"] as? Int == 1,
      object["status"] as? String == "failed",
      object["runID"] as? String == expectation.runID,
      object["runNonce"] as? String == expectation.runNonce,
      let code = object["code"] as? String,
      code.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    return code
  }

  private func writeSignal(status: String, resultSHA256: String) throws {
    let fileName = status == "accepted" ? Self.acknowledgementFileName : Self.releaseFileName
    let object: [String: Any] = [
      "resultSHA256": resultSHA256,
      "runID": expectation.runID,
      "runNonce": expectation.runNonce,
      "schemaVersion": 1,
      "status": status,
    ]
    let data = try PiTUIFileProtocol.canonicalJSONData(object)
    try PiTUIFileProtocol.createPrivateFile(
      data: data,
      at: directory.appendingPathComponent(fileName),
      idempotent: true
    )
  }

  private func hasSignal(status: String, resultSHA256: String) throws -> Bool {
    let fileName = status == "accepted" ? Self.acknowledgementFileName : Self.releaseFileName
    let url = directory.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard data.last == 0x0A,
      let object = try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys) == Set(["resultSHA256", "runID", "runNonce", "schemaVersion", "status"]),
      object["schemaVersion"] as? Int == 1,
      object["status"] as? String == status,
      object["runID"] as? String == expectation.runID,
      object["runNonce"] as? String == expectation.runNonce,
      object["resultSHA256"] as? String == resultSHA256
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    return true
  }
}

public enum PiTUIInvocationBuilder {
  private static let lockedSettings = Data(
    "{\"compaction\":{\"enabled\":false},\"defaultProjectTrust\":\"never\",\"enableInstallTelemetry\":false,\"retry\":{\"enabled\":false,\"provider\":{\"maxRetries\":0}},\"transport\":\"sse\"}\n"
      .utf8
  )

  public static func arguments(
    runtime: PiResolvedRuntime,
    resources: PiTUIResourceCatalog,
    configuration: PiTUIRunConfiguration
  ) throws -> [String] {
    try arguments(
      runtime: runtime,
      resources: resources,
      configuration: configuration,
      fixtureProviderExtension: nil
    )
  }

  static func fixtureArguments(
    runtime: PiResolvedRuntime,
    resources: PiTUIResourceCatalog,
    configuration: PiTUIRunConfiguration,
    fixtureProviderExtension: URL
  ) throws -> [String] {
    #if DEBUG
      guard fixtureProviderExtension.lastPathComponent == "pi-tui-fixture-provider.ts",
        try PiTUIFileProtocol.safeRegularFile(fixtureProviderExtension)
      else {
        throw PiRPCProcessError.invalidRequest
      }
      return try arguments(
        runtime: runtime,
        resources: resources,
        configuration: configuration,
        fixtureProviderExtension: fixtureProviderExtension
      )
    #else
      throw PiRPCProcessError.invalidRequest
    #endif
  }

  public static func environment(
    homeDirectory: URL,
    agentDirectory: URL,
    temporaryDirectory: URL,
    workflowConfiguration: URL,
    tuiConfiguration: URL,
    piVersion: PiSemanticVersion,
    offline: Bool
  ) throws -> [String: String] {
    let configuration = try PiTUIRunConfiguration.load(from: tuiConfiguration)
    guard try PiTUIFileProtocol.safePrivateFile(workflowConfiguration, maximumBytes: 1_048_576),
      try PiTUIFileProtocol.safePrivateDirectory(homeDirectory),
      try PiTUIFileProtocol.safePrivateDirectory(agentDirectory),
      try PiTUIFileProtocol.safePrivateDirectory(temporaryDirectory),
      try validateLockedSettings(in: agentDirectory, piVersion: piVersion),
      PiTUIFileProtocol.rootsAreDisjoint([
        configuration.channelDirectory,
        configuration.workspaceRoot,
        configuration.sessionDirectory,
        homeDirectory,
        agentDirectory,
        temporaryDirectory,
      ])
    else {
      throw PiRPCProcessError.invalidRequest
    }
    var environment = try PiRPCInvocationBuilder.environment(
      homeDirectory: homeDirectory,
      agentDirectory: agentDirectory,
      temporaryDirectory: temporaryDirectory,
      workflowConfiguration: workflowConfiguration,
      offline: offline
    )
    environment["JIDOKA_CODE_TUI_CONFIG"] = tuiConfiguration.path
    environment["TERM"] = "xterm-256color"
    return environment
  }

  public static func writeLockedSettings(in agentDirectory: URL) throws {
    guard try PiTUIFileProtocol.safePrivateDirectory(agentDirectory) else {
      throw PiRPCProcessError.invalidRequest
    }
    try PiTUIFileProtocol.createPrivateFile(
      data: lockedSettings,
      at: agentDirectory.appendingPathComponent("settings.json")
    )
  }

  public static func validateLockedSettings(
    in agentDirectory: URL,
    piVersion: PiSemanticVersion
  ) throws -> Bool {
    let settings = agentDirectory.appendingPathComponent("settings.json")
    guard try PiTUIFileProtocol.safePrivateDirectory(agentDirectory),
      try PiTUIFileProtocol.safePrivateFile(settings, maximumBytes: 64 * 1_024)
    else {
      return false
    }
    let data = try PiTUIFileProtocol.readPrivateFile(settings, maximumBytes: 64 * 1_024)
    if data == lockedSettings { return true }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys)
        == Set([
          "compaction", "defaultProjectTrust", "enableInstallTelemetry", "lastChangelogVersion",
          "retry", "transport",
        ]),
      let compaction = object["compaction"] as? [String: Any],
      Set(compaction.keys) == Set(["enabled"]),
      compaction["enabled"] as? Bool == false,
      object["defaultProjectTrust"] as? String == "never",
      object["enableInstallTelemetry"] as? Bool == false,
      object["lastChangelogVersion"] as? String == piVersion.description,
      let retry = object["retry"] as? [String: Any],
      Set(retry.keys) == Set(["enabled", "provider"]),
      retry["enabled"] as? Bool == false,
      let provider = retry["provider"] as? [String: Any],
      Set(provider.keys) == Set(["maxRetries"]),
      provider["maxRetries"] as? Int == 0,
      object["transport"] as? String == "sse"
    else {
      return false
    }
    return true
  }

  private static func arguments(
    runtime: PiResolvedRuntime,
    resources: PiTUIResourceCatalog,
    configuration: PiTUIRunConfiguration,
    fixtureProviderExtension: URL?
  ) throws -> [String] {
    let workflowResources = resources.workflowResources
    let skills = try workflowResources.skillURLs(
      workflow: configuration.workflow,
      role: configuration.role
    )
    let activeTools = try PiWorkflowResourceCatalog.activeToolNames(
      workflow: configuration.workflow,
      role: configuration.role
    )
    let expectedCommands = try workflowResources.expectedCommandProvenance(
      workflow: configuration.workflow,
      role: configuration.role
    )
    guard configuration.expectedCommands == expectedCommands,
      runtime.piCLIURL.path.hasPrefix(runtime.piPackageRootURL.path + "/"),
      try PiTUIFileProtocol.safePrivateDirectory(configuration.sessionDirectory),
      try PiTUIFileProtocol.safeRegularFile(workflowResources.blockerExtensionURL),
      try PiTUIFileProtocol.safeRegularFile(workflowResources.runtimeExtensionURL),
      try PiTUIFileProtocol.safeRegularFile(resources.tuiRuntimeExtensionURL),
      try skills.allSatisfy(PiTUIFileProtocol.safeRegularFile)
    else {
      throw PiRPCProcessError.invalidRequest
    }
    var values = [
      runtime.piCLIURL.path,
      "--no-approve",
      "--no-context-files",
      "--no-themes",
      "--no-prompt-templates",
      "--model",
      configuration.model.argument,
      "--session-dir",
      configuration.sessionDirectory.path,
      "--name",
      configuration.sessionName,
      "--no-extensions",
      "--extension",
      workflowResources.blockerExtensionURL.path,
      "--extension",
      workflowResources.runtimeExtensionURL.path,
      "--extension",
      resources.tuiRuntimeExtensionURL.path,
    ]
    if let fixtureProviderExtension {
      values.append(contentsOf: ["--extension", fixtureProviderExtension.path])
    }
    values.append("--no-skills")
    if configuration.launchMode == .resume {
      guard let sessionID = configuration.expectedSessionID else {
        throw PiRPCProcessError.invalidRequest
      }
      values.append(contentsOf: ["--session", sessionID])
    }
    for skill in skills { values.append(contentsOf: ["--skill", skill.path]) }
    values.append(contentsOf: ["--tools", activeTools.joined(separator: ",")])
    return values
  }
}

public struct PiTUIHostInvocationDescriptor: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let resourceRoot: String
  public let homeDirectory: String
  public let agentDirectory: String
  public let temporaryDirectory: String
  public let workflowConfiguration: String
  public let workflowConfigurationSHA256: String
  public let tuiConfiguration: String
  public let tuiConfigurationSHA256: String
  public let offline: Bool
  public let executionTimeoutMilliseconds: Int
  public let abortGraceMilliseconds: Int
  public let fixtureProviderExtension: String?
  public let fixtureProviderCall: String?

  public init(
    resourceRoot: URL,
    homeDirectory: URL,
    agentDirectory: URL,
    temporaryDirectory: URL,
    workflowConfiguration: URL,
    tuiConfiguration: URL,
    offline: Bool,
    executionTimeoutMilliseconds: Int = 3_600_000,
    abortGraceMilliseconds: Int = 5_000,
    fixtureProviderExtension: URL? = nil,
    fixtureProviderCall: URL? = nil
  ) throws {
    guard
      try PiTUIFileProtocol.safePrivateFile(
        workflowConfiguration,
        maximumBytes: 1_048_576
      ),
      try PiTUIFileProtocol.safePrivateFile(tuiConfiguration, maximumBytes: 1_048_576),
      (1_000...3_600_000).contains(executionTimeoutMilliseconds),
      (100...30_000).contains(abortGraceMilliseconds),
      (fixtureProviderExtension == nil) == (fixtureProviderCall == nil)
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    self.schemaVersion = 1
    self.resourceRoot = try PiTUIFileProtocol.canonicalExistingURL(resourceRoot).path
    self.homeDirectory = try PiTUIFileProtocol.canonicalExistingURL(homeDirectory).path
    self.agentDirectory = try PiTUIFileProtocol.canonicalExistingURL(agentDirectory).path
    self.temporaryDirectory = try PiTUIFileProtocol.canonicalExistingURL(temporaryDirectory).path
    self.workflowConfiguration = try PiTUIFileProtocol.canonicalExistingURL(
      workflowConfiguration
    ).path
    self.workflowConfigurationSHA256 = PiTUIFileProtocol.sha256(
      try PiTUIFileProtocol.readPrivateFile(workflowConfiguration, maximumBytes: 1_048_576)
    )
    self.tuiConfiguration = try PiTUIFileProtocol.canonicalExistingURL(tuiConfiguration).path
    self.tuiConfigurationSHA256 = PiTUIFileProtocol.sha256(
      try PiTUIFileProtocol.readPrivateFile(tuiConfiguration, maximumBytes: 1_048_576)
    )
    self.offline = offline
    self.executionTimeoutMilliseconds = executionTimeoutMilliseconds
    self.abortGraceMilliseconds = abortGraceMilliseconds
    self.fixtureProviderExtension = fixtureProviderExtension?.standardizedFileURL.path
    self.fixtureProviderCall = fixtureProviderCall?.standardizedFileURL.path
  }

  func resolved(runtime resolvedRuntime: PiResolvedRuntime? = nil) throws
    -> PiTUIResolvedHostInvocation
  {
    guard schemaVersion == 1,
      workflowConfigurationSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      tuiConfigurationSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      (1_000...3_600_000).contains(executionTimeoutMilliseconds),
      (100...30_000).contains(abortGraceMilliseconds),
      (fixtureProviderExtension == nil) == (fixtureProviderCall == nil)
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    let resourceRootURL = URL(fileURLWithPath: resourceRoot, isDirectory: true)
    let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
    let agentURL = URL(fileURLWithPath: agentDirectory, isDirectory: true)
    let temporaryURL = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
    let workflowURL = URL(fileURLWithPath: workflowConfiguration)
    let tuiURL = URL(fileURLWithPath: tuiConfiguration)
    let resources = try PiTUIResourceCatalog.inspect(resourceRoot: resourceRootURL)
    let sourceRuntime =
      try resolvedRuntime
      ?? PiRuntimeResolver(
        configuration: .standard(resourceRoot: resources.workflowResources.resourceRoot)
      ).resolve()
    let workflow = try PiWorkflowRuntimeConfiguration.load(from: workflowURL)
    let tui = try PiTUIRunConfiguration.load(from: tuiURL)
    let expectedCommands = try resources.workflowResources.expectedCommandProvenance(
      workflow: workflow.workflow,
      role: workflow.role
    )
    let workflowWorkspace = try PiTUIFileProtocol.canonicalExistingURL(workflow.workspaceRoot)
    guard workflow.resources == resources.workflowResources,
      workflowWorkspace.path == tui.workspaceRoot.path,
      workflow.workflow == tui.workflow,
      workflow.role == tui.role,
      tui.expectedCommands == expectedCommands,
      PiTUIFileProtocol.isChild(workflowURL, of: tui.channelDirectory),
      PiTUIFileProtocol.isChild(tuiURL, of: tui.channelDirectory),
      PiTUIFileProtocol.sha256(
        try PiTUIFileProtocol.readPrivateFile(workflowURL, maximumBytes: 1_048_576)
      ) == workflowConfigurationSHA256,
      PiTUIFileProtocol.sha256(
        try PiTUIFileProtocol.readPrivateFile(tuiURL, maximumBytes: 1_048_576)
      ) == tuiConfigurationSHA256,
      PiTUIFileProtocol.rootsAreDisjoint([
        tui.channelDirectory,
        tui.workspaceRoot,
        tui.sessionDirectory,
        homeURL,
        agentURL,
        temporaryURL,
      ])
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    let runtime =
      if resolvedRuntime == nil {
        try PiRuntimeResolver.materializePrivateSnapshot(
          of: sourceRuntime,
          in: temporaryURL
        )
      } else {
        sourceRuntime
      }

    let arguments: [String]
    var environment = try PiTUIInvocationBuilder.environment(
      homeDirectory: homeURL,
      agentDirectory: agentURL,
      temporaryDirectory: temporaryURL,
      workflowConfiguration: workflowURL,
      tuiConfiguration: tuiURL,
      piVersion: runtime.piVersion,
      offline: offline
    )
    if let libraryDirectory = runtime.nodeDynamicLibraryDirectoryURL {
      guard PiTUIFileProtocol.isChild(libraryDirectory, of: temporaryURL) else {
        throw PiTUIRuntimeError.invalidConfiguration
      }
      environment["DYLD_LIBRARY_PATH"] = libraryDirectory.path
    } else if resolvedRuntime == nil {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    if let fixtureProviderExtension, let fixtureProviderCall {
      #if DEBUG
        let extensionURL = URL(fileURLWithPath: fixtureProviderExtension)
        let callURL = URL(fileURLWithPath: fixtureProviderCall)
        let repositoryRoot = resources.workflowResources.resourceRoot
          .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureMode: String
        switch callURL.lastPathComponent {
        case "provider-call.json": fixtureMode = "multi-turn"
        case "causal-provider-call.json": fixtureMode = "crash-after-recorded-result"
        case "failure-provider-call.json": fixtureMode = "command-provenance-mismatch"
        default: throw PiTUIRuntimeError.invalidConfiguration
        }
        let callExists = FileManager.default.fileExists(atPath: callURL.path)
        let validCallState: Bool
        if tui.launchMode == .fresh, !callExists {
          validCallState = true
        } else if callExists {
          validCallState = try PiTUIFileProtocol.safePrivateFile(
            callURL,
            maximumBytes: 64 * 1_024
          )
        } else {
          validCallState = false
        }
        guard
          extensionURL
            == repositoryRoot.appendingPathComponent(
              "scripts/spikes/pi-tui-fixture-provider.ts"
            ).standardizedFileURL,
          PiTUIFileProtocol.isChild(callURL, of: tui.channelDirectory),
          validCallState
        else {
          throw PiTUIRuntimeError.invalidConfiguration
        }
        arguments = try PiTUIInvocationBuilder.fixtureArguments(
          runtime: runtime,
          resources: resources,
          configuration: tui,
          fixtureProviderExtension: extensionURL
        )
        environment["JIDOKA_TUI_FIXTURE_MODE"] = fixtureMode
        environment["JIDOKA_TUI_FIXTURE_PROVIDER_CALL"] = callURL.path
      #else
        throw PiTUIRuntimeError.invalidConfiguration
      #endif
    } else {
      arguments = try PiTUIInvocationBuilder.arguments(
        runtime: runtime,
        resources: resources,
        configuration: tui
      )
    }
    return PiTUIResolvedHostInvocation(
      executable: runtime.nodeURL,
      arguments: arguments,
      workingDirectory: tui.workspaceRoot,
      environment: environment,
      tuiConfiguration: tui,
      workflowConfiguration: workflow,
      executionTimeoutMilliseconds: executionTimeoutMilliseconds,
      abortGraceMilliseconds: abortGraceMilliseconds
    )
  }
}

struct PiTUIResolvedHostInvocation: Sendable {
  let executable: URL
  let arguments: [String]
  let workingDirectory: URL
  let environment: [String: String]
  let tuiConfiguration: PiTUIRunConfiguration
  let workflowConfiguration: PiWorkflowRuntimeConfiguration
  let executionTimeoutMilliseconds: Int
  let abortGraceMilliseconds: Int
}

enum PiTUIFileProtocol {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalJSONData(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PiTUIRuntimeError.malformedFile
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    ) + Data([0x0A])
  }

  static func isChild(_ child: URL, of parent: URL) -> Bool {
    guard let childPath = canonicalPathAllowingMissingLeaf(child),
      let parentPath = try? canonicalExistingURL(parent).path
    else {
      return false
    }
    return childPath != parentPath && childPath.hasPrefix(parentPath + "/")
  }

  static func rootsAreDisjoint(_ roots: [URL]) -> Bool {
    let paths = roots.compactMap { try? canonicalExistingURL($0).path }
    guard paths.count == roots.count else { return false }
    guard Set(paths).count == paths.count else { return false }
    for left in paths.indices {
      for right in paths.indices where left < right {
        if paths[left].hasPrefix(paths[right] + "/")
          || paths[right].hasPrefix(paths[left] + "/")
        {
          return false
        }
      }
    }
    return true
  }

  static func safePrivateDirectory(_ url: URL) throws -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/"),
      let path = try? canonicalExistingURL(url),
      safeAncestorChain(path)
    else {
      return false
    }
    let descriptor = Darwin.open(
      path.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    var value = stat()
    return fstat(descriptor, &value) == 0
      && DarwinACLAuthority.hasNoAllowEntries(descriptor)
      && value.st_mode & S_IFMT == S_IFDIR
      && value.st_uid == geteuid()
      && value.st_mode & 0o077 == 0
  }

  static func safeRegularFile(_ url: URL) throws -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/"),
      let path = try? canonicalExistingURL(url),
      safeAncestorChain(path.deletingLastPathComponent())
    else {
      return false
    }
    let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    var value = stat()
    return fstat(descriptor, &value) == 0
      && DarwinACLAuthority.hasNoAllowEntries(descriptor)
      && value.st_mode & S_IFMT == S_IFREG
      && (value.st_uid == geteuid() || value.st_uid == 0)
      && value.st_mode & 0o022 == 0
      && value.st_nlink == 1
  }

  static func safePrivateFile(_ url: URL, maximumBytes: Int) throws -> Bool {
    guard try safeRegularFile(url) else { return false }
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return false }
    return value.st_uid == geteuid()
      && value.st_mode & 0o077 == 0
      && value.st_size >= 1
      && value.st_size <= maximumBytes
  }

  static func createPrivateFile(data: Data, at destination: URL, idempotent: Bool = false) throws {
    let requestedParent = destination.deletingLastPathComponent()
    let finalName = destination.lastPathComponent
    guard !data.isEmpty,
      destination.isFileURL,
      destination.path.hasPrefix("/"),
      !finalName.isEmpty,
      !finalName.contains("/"),
      try safePrivateDirectory(requestedParent)
    else {
      throw PiTUIRuntimeError.unsafePath
    }
    let parent = try canonicalExistingURL(requestedParent)
    let destination = parent.appendingPathComponent(finalName)
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0,
      DarwinACLAuthority.hasNoAllowEntries(parentDescriptor)
    else {
      if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
      throw PiTUIRuntimeError.writeFailed(errno)
    }
    defer { _ = Darwin.close(parentDescriptor) }

    if fileExists(finalName, in: parentDescriptor) {
      if idempotent {
        let existing = try readPrivateFile(destination, maximumBytes: max(data.count, 1))
        guard existing == data else { throw PiTUIRuntimeError.divergentFile }
        return
      }
      throw PiTUIRuntimeError.fileAlreadyExists
    }

    let preparedName = ".\(finalName).prepared"
    let stagingName = ".\(finalName).\(UUID().uuidString.lowercased()).staging"
    let stagingDescriptor = openat(
      parentDescriptor,
      stagingName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard stagingDescriptor >= 0,
      DarwinACLAuthority.hasNoAllowEntries(stagingDescriptor)
    else {
      if stagingDescriptor >= 0 {
        _ = Darwin.close(stagingDescriptor)
        _ = unlinkat(parentDescriptor, stagingName, 0)
      }
      throw PiTUIRuntimeError.writeFailed(errno)
    }
    do {
      try writeAll(data, to: stagingDescriptor)
      guard fsync(stagingDescriptor) == 0 else {
        throw PiTUIRuntimeError.writeFailed(errno)
      }
      guard Darwin.close(stagingDescriptor) == 0 else {
        throw PiTUIRuntimeError.writeFailed(errno)
      }
    } catch {
      _ = Darwin.close(stagingDescriptor)
      _ = unlinkat(parentDescriptor, stagingName, 0)
      throw error
    }

    if renameatx_np(
      parentDescriptor,
      stagingName,
      parentDescriptor,
      preparedName,
      UInt32(RENAME_EXCL)
    ) != 0 {
      let renameError = errno
      _ = unlinkat(parentDescriptor, stagingName, 0)
      guard renameError == EEXIST else { throw PiTUIRuntimeError.writeFailed(renameError) }
      let preparedURL = parent.appendingPathComponent(preparedName)
      let prepared = try readPrivateFile(preparedURL, maximumBytes: max(data.count, 1))
      guard prepared == data else { throw PiTUIRuntimeError.divergentFile }
    }
    guard fsync(parentDescriptor) == 0 else { throw PiTUIRuntimeError.writeFailed(errno) }

    if renameatx_np(
      parentDescriptor,
      preparedName,
      parentDescriptor,
      finalName,
      UInt32(RENAME_EXCL)
    ) != 0 {
      let renameError = errno
      guard renameError == EEXIST else { throw PiTUIRuntimeError.writeFailed(renameError) }
      let existing = try readPrivateFile(destination, maximumBytes: max(data.count, 1))
      guard existing == data else { throw PiTUIRuntimeError.divergentFile }
      _ = unlinkat(parentDescriptor, preparedName, 0)
      if !idempotent { throw PiTUIRuntimeError.fileAlreadyExists }
    }
    guard fsync(parentDescriptor) == 0 else { throw PiTUIRuntimeError.writeFailed(errno) }
  }

  static func readPrivateFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let requestedParent = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    guard url.isFileURL,
      url.path.hasPrefix("/"),
      !name.isEmpty,
      !name.contains("/"),
      try safePrivateDirectory(requestedParent)
    else {
      throw PiTUIRuntimeError.unsafePath
    }
    let parent = try canonicalExistingURL(requestedParent)
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0,
      DarwinACLAuthority.hasNoAllowEntries(parentDescriptor)
    else {
      if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
      throw PiTUIRuntimeError.fileUnavailable
    }
    defer { _ = Darwin.close(parentDescriptor) }
    let descriptor = openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PiTUIRuntimeError.fileUnavailable }
    defer { _ = Darwin.close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_mode & S_IFMT == S_IFREG,
      value.st_uid == geteuid(),
      value.st_mode & 0o077 == 0,
      value.st_nlink == 1,
      value.st_size >= 1,
      value.st_size <= maximumBytes
    else {
      throw PiTUIRuntimeError.unsafePath
    }
    var bytes = [UInt8](repeating: 0, count: Int(value.st_size))
    var offset = 0
    try bytes.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      while offset < buffer.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw PiTUIRuntimeError.fileUnavailable
        }
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_dev == after.st_dev,
      value.st_ino == after.st_ino,
      value.st_size == after.st_size,
      value.st_mode == after.st_mode,
      value.st_nlink == after.st_nlink
    else {
      throw PiTUIRuntimeError.unsafePath
    }
    return Data(bytes)
  }

  static func canonicalExistingURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw PiTUIRuntimeError.unsafePath
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
      throw PiTUIRuntimeError.unsafePath
    }
    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
    let path = String(
      decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    return URL(fileURLWithPath: path, isDirectory: false)
  }

  private static func canonicalPathAllowingMissingLeaf(_ url: URL) -> String? {
    if let existing = try? canonicalExistingURL(url) { return existing.path }
    guard let parent = try? canonicalExistingURL(url.deletingLastPathComponent()) else {
      return nil
    }
    return parent.appendingPathComponent(url.lastPathComponent).path
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw PiTUIRuntimeError.writeFailed(errno)
        }
      }
    }
  }

  private static func fileExists(_ name: String, in parent: Int32) -> Bool {
    var value = stat()
    return fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0
  }

  private static func safeAncestorChain(_ url: URL) -> Bool {
    var current = url.path
    while true {
      let descriptor = Darwin.open(
        current,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else { return false }
      var value = stat()
      let safe =
        fstat(descriptor, &value) == 0
        && DarwinACLAuthority.hasNoAllowEntries(descriptor)
        && value.st_mode & S_IFMT == S_IFDIR
        && (value.st_uid == 0 || value.st_uid == geteuid())
        && (value.st_mode & 0o022 == 0 || value.st_mode & S_ISVTX != 0)
      _ = Darwin.close(descriptor)
      guard safe else { return false }
      if current == "/" { return true }
      let parent = (current as NSString).deletingLastPathComponent
      guard !parent.isEmpty, parent != current else { return false }
      current = parent
    }
  }
}
