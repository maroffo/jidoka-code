import CryptoKit
import Foundation

public struct PiModelCatalog: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let models: [PiModelCatalogEntry]

  public init(schemaVersion: Int = 1, models: [PiModelCatalogEntry]) {
    self.schemaVersion = schemaVersion
    self.models = models
  }

  public static let unavailable = PiModelCatalog(models: [])
}

public struct PiModelCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public let provider: String
  public let id: String
  public let name: String
  public let reasoning: Bool
  public let input: [PiModelInputKind]
  public let contextWindow: Int
  public let maxTokens: Int
  public let thinkingLevels: [ModelThinkingLevel]

  public var selectionID: String { "\(provider)/\(id)" }

  public init(
    provider: String,
    id: String,
    name: String,
    reasoning: Bool,
    input: [PiModelInputKind],
    contextWindow: Int,
    maxTokens: Int,
    thinkingLevels: [ModelThinkingLevel]
  ) {
    self.provider = provider
    self.id = id
    self.name = name
    self.reasoning = reasoning
    self.input = input
    self.contextWindow = contextWindow
    self.maxTokens = maxTokens
    self.thinkingLevels = thinkingLevels
  }
}

public enum PiModelInputKind: String, Codable, Sendable {
  case text
  case image
}

public enum PiModelCatalogError: Error, Equatable, Sendable {
  case unavailable
  case invalidOutput
}

public enum PiModelCatalogDecoder {
  public static let maximumOutputBytes = 2 * 1_048_576
  public static let maximumModelCount = 4_096

  public static func decode(_ data: Data) throws -> PiModelCatalog {
    guard !data.isEmpty, data.count <= maximumOutputBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schemaVersion", "models"]),
      object["schemaVersion"] as? Int == 1,
      let rawModels = object["models"] as? [[String: Any]],
      rawModels.count <= maximumModelCount
    else {
      throw PiModelCatalogError.invalidOutput
    }

    var seen = Set<String>()
    var models: [PiModelCatalogEntry] = []
    for raw in rawModels {
      guard
        Set(raw.keys)
          == Set([
            "provider", "id", "name", "reasoning", "input", "contextWindow", "maxTokens",
            "thinkingLevels",
          ]),
        let provider = raw["provider"] as? String,
        validProvider(provider),
        let id = raw["id"] as? String,
        validModelID(id),
        let name = raw["name"] as? String,
        validName(name),
        let reasoning = raw["reasoning"] as? Bool,
        let rawInput = raw["input"] as? [String],
        !rawInput.isEmpty,
        rawInput.count <= 2,
        let input = parseInput(rawInput),
        let contextWindow = raw["contextWindow"] as? Int,
        contextWindow > 0,
        let maxTokens = raw["maxTokens"] as? Int,
        maxTokens > 0,
        let rawThinking = raw["thinkingLevels"] as? [String],
        let thinking = parseThinking(rawThinking, reasoning: reasoning),
        seen.insert("\(provider)\u{0}\(id)").inserted
      else {
        throw PiModelCatalogError.invalidOutput
      }
      models.append(
        PiModelCatalogEntry(
          provider: provider,
          id: id,
          name: name,
          reasoning: reasoning,
          input: input,
          contextWindow: contextWindow,
          maxTokens: maxTokens,
          thinkingLevels: thinking
        ))
    }
    models.sort {
      if $0.provider != $1.provider { return $0.provider < $1.provider }
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.id < $1.id
    }
    return PiModelCatalog(models: models)
  }

  private static func validProvider(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/) != nil
  }

  private static func validModelID(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._\/-]{0,255}$/) != nil
  }

  private static func validName(_ value: String) -> Bool {
    guard (1...256).contains(value.utf8.count) else { return false }
    return !value.unicodeScalars.contains { scalar in
      scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7F
    }
  }

  private static func parseInput(_ values: [String]) -> [PiModelInputKind]? {
    let parsed = values.compactMap(PiModelInputKind.init(rawValue:))
    guard parsed.count == values.count, Set(parsed.map(\.rawValue)).count == parsed.count else {
      return nil
    }
    return parsed
  }

  private static func parseThinking(
    _ values: [String],
    reasoning: Bool
  ) -> [ModelThinkingLevel]? {
    let parsed = values.compactMap(ModelThinkingLevel.init(rawValue:))
    guard !parsed.isEmpty, parsed.count == values.count,
      Set(parsed.map(\.rawValue)).count == parsed.count,
      parsed == ModelThinkingLevel.allCases.filter(parsed.contains),
      reasoning ? true : parsed == [.off]
    else {
      return nil
    }
    return parsed
  }
}

public protocol PiModelCatalogDiscovering: Sendable {
  func discover() async throws -> PiModelCatalog
}

public struct PiModelCatalogDiscovery: PiModelCatalogDiscovering, Sendable {
  private let runtimeResolver: any PiRuntimeResolving
  private let scriptURL: URL
  private let expectedScriptSHA256: String
  private let piAgentDirectory: URL
  private let applicationSupportRoot: URL
  private let privateRuntimeRoot: URL
  private let runner: any GitProcessExecuting

  public init(
    runtimeResolver: ReleaseOwnedPiRuntimeResolver,
    scriptURL: URL,
    expectedScriptSHA256: String,
    piAgentDirectory: URL,
    applicationSupportRoot: URL,
    privateRuntimeRoot: URL,
    runner: any GitProcessExecuting = BoundedProcessRunner()
  ) {
    self.runtimeResolver = runtimeResolver
    self.scriptURL = scriptURL
    self.expectedScriptSHA256 = expectedScriptSHA256
    self.piAgentDirectory = piAgentDirectory
    self.applicationSupportRoot = applicationSupportRoot
    self.privateRuntimeRoot = privateRuntimeRoot
    self.runner = runner
  }

  #if DEBUG
    init(
      runtimeResolver: any PiRuntimeResolving,
      scriptURL: URL,
      expectedScriptSHA256: String,
      piAgentDirectory: URL,
      applicationSupportRoot: URL,
      privateRuntimeRoot: URL,
      runner: any GitProcessExecuting = BoundedProcessRunner()
    ) {
      self.runtimeResolver = runtimeResolver
      self.scriptURL = scriptURL
      self.expectedScriptSHA256 = expectedScriptSHA256
      self.piAgentDirectory = piAgentDirectory
      self.applicationSupportRoot = applicationSupportRoot
      self.privateRuntimeRoot = privateRuntimeRoot
      self.runner = runner
    }
  #endif

  public func discover() async throws -> PiModelCatalog {
    let runtime = try ReleaseOwnedPiRuntimeBoundaryAuthority.modelCatalogProcess(
      using: runtimeResolver
    )
    let script = try validatedScript()
    let agent = try validatedAgentDirectory()
    let root = try validatedPrivateRuntimeRoot()
    let home = root.appendingPathComponent("home", isDirectory: true)
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    try ensurePrivateDirectory(home, beneath: root)
    try ensurePrivateDirectory(temporary, beneath: root)
    let environment = [
      "GIT_ASKPASS": "/usr/bin/false",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_SSH_COMMAND": "/usr/bin/false",
      "GIT_TERMINAL_PROMPT": "0",
      "HOME": home.path,
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "PATH": "/usr/bin:/bin",
      "PI_CODING_AGENT_DIR": agent.path,
      "PI_OFFLINE": "1",
      "PI_SKIP_VERSION_CHECK": "1",
      "TMPDIR": temporary.path,
    ]
    let result = try await runner.run(
      GitProcessRequest(
        executable: runtime.nodeURL,
        arguments: [script.path, runtime.piPackageRootURL.path],
        workingDirectory: root,
        environment: environment,
        timeoutSeconds: 15,
        maximumOutputBytes: PiModelCatalogDecoder.maximumOutputBytes
      ))
    guard result.succeeded, result.stderr.isEmpty else {
      throw PiModelCatalogError.unavailable
    }
    return try PiModelCatalogDecoder.decode(result.stdout)
  }

  private func validatedScript() throws -> URL {
    guard GitHubInputValidation.validSHA256(expectedScriptSHA256) else {
      throw PiModelCatalogError.unavailable
    }
    do {
      let script = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: scriptURL,
        expectedSHA256: expectedScriptSHA256,
        applicationSupportRoot: applicationSupportRoot
      )
      guard script.lastPathComponent == "jidoka-model-catalog.mjs",
        try PiTUIFileProtocol.safePrivateFile(script, maximumBytes: 1_048_576)
      else {
        throw PiModelCatalogError.unavailable
      }
      let data = try Data(contentsOf: script, options: .mappedIfSafe)
      guard Self.sha256(data) == expectedScriptSHA256 else {
        throw PiModelCatalogError.unavailable
      }
      return script
    } catch {
      throw PiModelCatalogError.unavailable
    }
  }

  private func validatedAgentDirectory() throws -> URL {
    let agent = piAgentDirectory.standardizedFileURL
    guard agent.isFileURL, agent.path.hasPrefix("/"),
      agent.resolvingSymlinksInPath().path == agent.path
    else {
      throw PiModelCatalogError.unavailable
    }
    guard try PiTUIFileProtocol.safePrivateDirectory(agent)
    else {
      throw PiModelCatalogError.unavailable
    }
    return agent
  }

  private func ensurePrivateDirectory(_ directory: URL, beneath root: URL) throws {
    guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    else {
      throw PiModelCatalogError.unavailable
    }
    try PrivateDirectoryBoundary.ensure(directory)
    guard try PiTUIFileProtocol.safePrivateDirectory(directory) else {
      throw PiModelCatalogError.unavailable
    }
  }

  private func validatedPrivateRuntimeRoot() throws -> URL {
    try PrivateDirectoryBoundary.ensure(privateRuntimeRoot)
    let root = privateRuntimeRoot.standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard root.isFileURL, root.path.hasPrefix("/"),
      root.resolvingSymlinksInPath().path == root.path,
      values.isDirectory == true,
      values.isSymbolicLink != true
    else {
      throw PiModelCatalogError.unavailable
    }
    return root
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
