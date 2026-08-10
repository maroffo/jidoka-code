import CryptoKit
import Darwin
import Foundation

public struct HerdrRoleHostBootstrapDescriptor: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let roleHostID: String
  public let repositoryID: String
  public let jobID: String
  public let generation: Int
  public let role: String
  public let allowedWorkflows: [String]
  public let expectedWorkspaceID: String
  public let workingDirectory: String
  public let agentAlias: String
  public let title: String
  public let displayAgent: String
  public let hostExecutable: String
  public let hostExecutableSHA256: String

  public init(
    roleHostID: String,
    repositoryID: String,
    jobID: String,
    generation: Int,
    role: PiWorkflowRole,
    allowedWorkflows: Set<PiWorkflowKind>,
    expectedWorkspaceID: String,
    workingDirectory: URL,
    agentAlias: String,
    title: String,
    displayAgent: String,
    hostExecutable: URL
  ) throws {
    guard roleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation),
      !allowedWorkflows.isEmpty,
      allowedWorkflows.allSatisfy({
        PiWorkflowResourceCatalog.valid(role: role, for: $0)
      }),
      Self.validOpaqueID(expectedWorkspaceID),
      Self.directory(workingDirectory),
      agentAlias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      Self.validDisplay(title, maximumBytes: 160),
      Self.validDisplay(displayAgent, maximumBytes: 96),
      try PiTUIFileProtocol.safeRegularFile(hostExecutable),
      Self.executable(hostExecutable)
    else {
      throw HerdrHostError.invalidDescriptor
    }
    let canonicalExecutable = try PiTUIFileProtocol.canonicalExistingURL(hostExecutable)
    self.schemaVersion = 2
    self.roleHostID = roleHostID
    self.repositoryID = repositoryID
    self.jobID = jobID
    self.generation = generation
    self.role = role.rawValue
    self.allowedWorkflows = allowedWorkflows.map(\.rawValue).sorted()
    self.expectedWorkspaceID = expectedWorkspaceID
    self.workingDirectory = workingDirectory.standardizedFileURL.path
    self.agentAlias = agentAlias
    self.title = title
    self.displayAgent = displayAgent
    self.hostExecutable = canonicalExecutable.path
    self.hostExecutableSHA256 = try Self.sha256(canonicalExecutable)
  }

  func validate(roleHostID expectedRoleHostID: String) throws {
    guard schemaVersion == 2, roleHostID == expectedRoleHostID,
      repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation),
      let role = PiWorkflowRole(rawValue: role),
      !allowedWorkflows.isEmpty,
      Set(allowedWorkflows).count == allowedWorkflows.count,
      allowedWorkflows == allowedWorkflows.sorted(),
      allowedWorkflows.allSatisfy({ value in
        PiWorkflowKind(rawValue: value).map {
          PiWorkflowResourceCatalog.valid(role: role, for: $0)
        } == true
      }),
      Self.validOpaqueID(expectedWorkspaceID),
      Self.directory(URL(fileURLWithPath: workingDirectory, isDirectory: true)),
      agentAlias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      Self.validDisplay(title, maximumBytes: 160),
      Self.validDisplay(displayAgent, maximumBytes: 96),
      hostExecutableSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    else {
      throw HerdrHostError.invalidDescriptor
    }
    let executableURL = URL(fileURLWithPath: hostExecutable)
    guard try PiTUIFileProtocol.safeRegularFile(executableURL),
      Self.executable(executableURL),
      try Self.sha256(executableURL) == hostExecutableSHA256
    else {
      throw HerdrHostError.invalidDescriptor
    }
  }

  private static func validOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validDisplay(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func directory(_ url: URL) -> Bool {
    var value = stat()
    return url.isFileURL && url.path.hasPrefix("/")
      && url.standardizedFileURL.path == url.path
      && lstat(url.path, &value) == 0 && (value.st_mode & S_IFMT) == S_IFDIR
  }

  private static func executable(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0 && value.st_mode & 0o111 != 0
  }

  private static func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct HerdrRoleHostCommand: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let roleHostID: String
  public let sequence: Int
  public let launchAttemptID: String
  public let descriptorSHA256: String
  public let expectedWorkspaceID: String
  public let expectedTabID: String
  public let expectedPaneID: String
  public let expectedTerminalID: String

  public init(
    roleHostID: String,
    sequence: Int,
    launchAttemptID: String,
    descriptorSHA256: String,
    expectedWorkspaceID: String,
    expectedTabID: String,
    expectedPaneID: String,
    expectedTerminalID: String
  ) throws {
    guard roleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      sequence > 0, sequence <= Int.max / 2,
      launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      descriptorSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      [expectedWorkspaceID, expectedTabID, expectedPaneID, expectedTerminalID]
        .allSatisfy(Self.validOpaqueID)
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    self.schemaVersion = 2
    self.roleHostID = roleHostID
    self.sequence = sequence
    self.launchAttemptID = launchAttemptID
    self.descriptorSHA256 = descriptorSHA256
    self.expectedWorkspaceID = expectedWorkspaceID
    self.expectedTabID = expectedTabID
    self.expectedPaneID = expectedPaneID
    self.expectedTerminalID = expectedTerminalID
  }

  private static func validOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

public struct HerdrRoleHostStartRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let roleHostID: String
  public let processID: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64
  public let executable: String
  public let executableSHA256: String
}

public struct HerdrRoleHostCommandStarted: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let roleHostID: String
  public let sequence: Int
  public let launchAttemptID: String
  public let descriptorSHA256: String
  public let status: String
}

public struct HerdrRoleHostCommandCompletion: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let roleHostID: String
  public let sequence: Int
  public let launchAttemptID: String
  public let descriptorSHA256: String
  public let status: String
  public let failureCode: String?
}

struct HerdrRoleHostRuntimeIdentity: Equatable, Sendable {
  let process: HerdrHostProcessIdentity
  let executable: URL
  let executableSHA256: String
}

public enum HerdrRoleHostDescriptorStore {
  private static let descriptorName = "role-host.json"
  private static let digestName = "role-host.sha256"
  private static let startName = "host-start.json"
  private static let shutdownName = "shutdown.json"
  private static let maximumRecordBytes = 1_048_576

  @discardableResult
  public static func prepare(
    _ descriptor: HerdrRoleHostBootstrapDescriptor,
    in root: URL
  ) throws -> String {
    try descriptor.validate(roleHostID: descriptor.roleHostID)
    guard try PiTUIFileProtocol.safePrivateDirectory(root) else {
      throw HerdrHostError.unsafeDescriptorRoot
    }
    let directory = root.appendingPathComponent(descriptor.roleHostID, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw HerdrHostError.descriptorAlreadyExists
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      guard try PiTUIFileProtocol.safePrivateDirectory(directory) else {
        throw HerdrHostError.unsafeRunDirectory
      }
      let data = try encoded(descriptor)
      let digest = PiTUIFileProtocol.sha256(data)
      try PiTUIFileProtocol.createPrivateFile(
        data: data,
        at: directory.appendingPathComponent(descriptorName)
      )
      try PiTUIFileProtocol.createPrivateFile(
        data: Data("\(digest)\n".utf8),
        at: directory.appendingPathComponent(digestName)
      )
      return digest
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  public static func load(
    roleHostID: String,
    from root: URL
  ) throws -> HerdrRoleHostBootstrapDescriptor {
    guard roleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      try PiTUIFileProtocol.safePrivateDirectory(root)
    else {
      throw HerdrHostError.invalidArguments
    }
    let directory = root.appendingPathComponent(roleHostID, isDirectory: true)
    guard try PiTUIFileProtocol.safePrivateDirectory(directory) else {
      throw HerdrHostError.unsafeRunDirectory
    }
    let data = try PiTUIFileProtocol.readPrivateFile(
      directory.appendingPathComponent(descriptorName),
      maximumBytes: maximumRecordBytes
    )
    let digestData = try PiTUIFileProtocol.readPrivateFile(
      directory.appendingPathComponent(digestName),
      maximumBytes: 65
    )
    guard digestData == Data("\(PiTUIFileProtocol.sha256(data))\n".utf8),
      let descriptor = try? JSONDecoder().decode(
        HerdrRoleHostBootstrapDescriptor.self,
        from: data
      ),
      try encoded(descriptor) == data
    else {
      throw HerdrHostError.descriptorDigestMismatch
    }
    try descriptor.validate(roleHostID: roleHostID)
    return descriptor
  }

  public static func enqueue(
    _ command: HerdrRoleHostCommand,
    in root: URL
  ) throws {
    let directory = try roleDirectory(command.roleHostID, root: root)
    try PiTUIFileProtocol.createPrivateFile(
      data: try encoded(command),
      at: directory.appendingPathComponent(commandName(command.sequence)),
      idempotent: true
    )
  }

  public static func requestShutdown(roleHostID: String, in root: URL) throws {
    let directory = try roleDirectory(roleHostID, root: root)
    let data = try PiTUIFileProtocol.canonicalJSONData([
      "roleHostID": roleHostID,
      "schemaVersion": 1,
      "status": "shutdown",
    ])
    try PiTUIFileProtocol.createPrivateFile(
      data: data,
      at: directory.appendingPathComponent(shutdownName),
      idempotent: true
    )
  }

  static func command(
    roleHostID: String,
    sequence: Int,
    root: URL
  ) throws -> HerdrRoleHostCommand? {
    let directory = try roleDirectory(roleHostID, root: root)
    let url = directory.appendingPathComponent(commandName(sequence))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard let command = try? JSONDecoder().decode(HerdrRoleHostCommand.self, from: data),
      try encoded(command) == data,
      command.schemaVersion == 2,
      command.roleHostID == roleHostID,
      command.sequence == sequence
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    return command
  }

  static func hasHigherCommand(
    roleHostID: String,
    than sequence: Int,
    root: URL
  ) throws -> Bool {
    let directory = try roleDirectory(roleHostID, root: root)
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { name in
      guard name.hasPrefix("command-"), name.hasSuffix(".json"),
        let value = Int(name.dropFirst(8).dropLast(5))
      else {
        return false
      }
      return value > sequence
    }
  }

  static func shutdownRequested(roleHostID: String, root: URL) throws -> Bool {
    let directory = try roleDirectory(roleHostID, root: root)
    let url = directory.appendingPathComponent(shutdownName)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard data.last == 0x0A,
      let object = try JSONSerialization.jsonObject(
        with: Data(data.dropLast())
      ) as? [String: Any],
      Set(object.keys) == Set(["roleHostID", "schemaVersion", "status"]),
      object["roleHostID"] as? String == roleHostID,
      object["schemaVersion"] as? Int == 1,
      object["status"] as? String == "shutdown"
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    return true
  }

  static func recordStart(
    roleHostID: String,
    identity: HerdrRoleHostRuntimeIdentity,
    root: URL
  ) throws {
    let directory = try roleDirectory(roleHostID, root: root)
    let record = HerdrRoleHostStartRecord(
      schemaVersion: 1,
      roleHostID: roleHostID,
      processID: identity.process.processID,
      startSeconds: identity.process.startSeconds,
      startMicroseconds: identity.process.startMicroseconds,
      executable: identity.executable.path,
      executableSHA256: identity.executableSHA256
    )
    let url = directory.appendingPathComponent(startName)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw HerdrHostError.roleHostRestartNotAuthorized
    }
    try PiTUIFileProtocol.createPrivateFile(data: try encoded(record), at: url)
  }

  public static func startRecord(
    roleHostID: String,
    from root: URL
  ) throws -> HerdrRoleHostStartRecord? {
    let directory = try roleDirectory(roleHostID, root: root)
    let url = directory.appendingPathComponent(startName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard let record = try? JSONDecoder().decode(HerdrRoleHostStartRecord.self, from: data),
      try encoded(record) == data,
      record.schemaVersion == 1,
      record.roleHostID == roleHostID,
      record.processID > 0,
      record.startMicroseconds < 1_000_000,
      record.executableSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    return record
  }

  static func recordStarted(
    command: HerdrRoleHostCommand,
    in root: URL
  ) throws {
    let directory = try roleDirectory(command.roleHostID, root: root)
    let record = HerdrRoleHostCommandStarted(
      schemaVersion: 1,
      roleHostID: command.roleHostID,
      sequence: command.sequence,
      launchAttemptID: command.launchAttemptID,
      descriptorSHA256: command.descriptorSHA256,
      status: "started"
    )
    try PiTUIFileProtocol.createPrivateFile(
      data: try encoded(record),
      at: directory.appendingPathComponent(startedName(command.sequence))
    )
  }

  public static func started(
    roleHostID: String,
    sequence: Int,
    from root: URL
  ) throws -> HerdrRoleHostCommandStarted? {
    let directory = try roleDirectory(roleHostID, root: root)
    let url = directory.appendingPathComponent(startedName(sequence))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard let record = try? JSONDecoder().decode(HerdrRoleHostCommandStarted.self, from: data),
      try encoded(record) == data,
      record.schemaVersion == 1,
      record.roleHostID == roleHostID,
      record.sequence == sequence,
      record.status == "started",
      record.descriptorSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    return record
  }

  static func recordCompletion(
    _ completion: HerdrRoleHostCommandCompletion,
    in root: URL
  ) throws {
    let directory = try roleDirectory(completion.roleHostID, root: root)
    try PiTUIFileProtocol.createPrivateFile(
      data: try encoded(completion),
      at: directory.appendingPathComponent(completionName(completion.sequence)),
      idempotent: true
    )
  }

  public static func completion(
    roleHostID: String,
    sequence: Int,
    from root: URL
  ) throws -> HerdrRoleHostCommandCompletion? {
    let directory = try roleDirectory(roleHostID, root: root)
    let url = directory.appendingPathComponent(completionName(sequence))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard
      let record = try? JSONDecoder().decode(
        HerdrRoleHostCommandCompletion.self,
        from: data
      ),
      try encoded(record) == data,
      record.schemaVersion == 1,
      record.roleHostID == roleHostID,
      record.sequence == sequence,
      ["released", "failed"].contains(record.status),
      record.failureCode?.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
        || record.failureCode == nil
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    return record
  }

  static func descriptorDigest(
    launchAttemptID: String,
    root: URL
  ) throws -> String {
    let url = root.appendingPathComponent(launchAttemptID, isDirectory: true)
      .appendingPathComponent("launch.sha256")
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 65)
    guard let value = String(data: data, encoding: .utf8),
      value.wholeMatch(of: /^[0-9a-f]{64}\n$/) != nil
    else {
      throw HerdrHostError.descriptorDigestMismatch
    }
    return String(value.dropLast())
  }

  private static func roleDirectory(_ roleHostID: String, root: URL) throws -> URL {
    guard roleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      try PiTUIFileProtocol.safePrivateDirectory(root)
    else {
      throw HerdrHostError.unsafeDescriptorRoot
    }
    let directory = root.appendingPathComponent(roleHostID, isDirectory: true)
    guard try PiTUIFileProtocol.safePrivateDirectory(directory) else {
      throw HerdrHostError.unsafeRunDirectory
    }
    return directory
  }

  private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
  }

  private static func commandName(_ sequence: Int) -> String {
    String(format: "command-%08d.json", sequence)
  }

  private static func startedName(_ sequence: Int) -> String {
    String(format: "started-%08d.json", sequence)
  }

  private static func completionName(_ sequence: Int) -> String {
    String(format: "completed-%08d.json", sequence)
  }
}

public enum HerdrRoleHostRuntime {
  public static func run(
    arguments: [String],
    environment: [String: String]
  ) async throws -> Int32 {
    try await run(
      arguments: arguments,
      environment: environment,
      pollNanoseconds: 50_000_000,
      identity: try runtimeIdentity(),
      validateCommand: validateCommand,
      execute: { command, root, environment in
        try await HerdrHostRuntime.run(
          arguments: ["--launch-attempt-id", command.launchAttemptID],
          environment: environment.merging([
            "JIDOKA_CODE_HERDR_RUN_ROOT": root.path
          ]) { _, replacement in replacement }
        )
      }
    )
  }

  static func run(
    arguments: [String],
    environment: [String: String],
    pollNanoseconds: UInt64,
    identity: HerdrRoleHostRuntimeIdentity,
    validateCommand:
      @escaping @Sendable (
        HerdrRoleHostCommand,
        HerdrRoleHostBootstrapDescriptor,
        URL
      ) throws -> Void,
    execute:
      @escaping @Sendable (HerdrRoleHostCommand, URL, [String: String]) async throws -> Int32
  ) async throws -> Int32 {
    guard arguments.count == 2, arguments[0] == "--role-host-id",
      arguments[1].wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      let rootValue = environment["JIDOKA_CODE_HERDR_RUN_ROOT"],
      let workspaceID = environment["HERDR_WORKSPACE_ID"],
      environment["HERDR_SOCKET_PATH"] != nil,
      environment["HERDR_PANE_ID"] != nil,
      environment["HERDR_TAB_ID"] != nil,
      pollNanoseconds > 0
    else {
      throw HerdrHostError.invalidArguments
    }
    let roleHostID = arguments[1]
    let root = URL(fileURLWithPath: rootValue, isDirectory: true)
    let descriptor = try HerdrRoleHostDescriptorStore.load(
      roleHostID: roleHostID,
      from: root
    )
    guard descriptor.expectedWorkspaceID == workspaceID,
      descriptor.hostExecutable == identity.executable.path,
      descriptor.hostExecutableSHA256 == identity.executableSHA256
    else {
      throw HerdrHostError.incompatiblePane
    }
    try HerdrRoleHostDescriptorStore.recordStart(
      roleHostID: roleHostID,
      identity: identity,
      root: root
    )

    var sequence = 1
    while true {
      if Task.isCancelled { throw HerdrHostError.cancelled }
      if try HerdrRoleHostDescriptorStore.shutdownRequested(
        roleHostID: roleHostID,
        root: root
      ) {
        return 0
      }
      guard
        let command = try HerdrRoleHostDescriptorStore.command(
          roleHostID: roleHostID,
          sequence: sequence,
          root: root
        )
      else {
        if try HerdrRoleHostDescriptorStore.hasHigherCommand(
          roleHostID: roleHostID,
          than: sequence,
          root: root
        ) {
          throw HerdrHostError.queueSequenceGap
        }
        do {
          try await Task.sleep(nanoseconds: pollNanoseconds)
        } catch {
          throw HerdrHostError.cancelled
        }
        continue
      }
      try validateCommand(command, descriptor, root)
      try HerdrRoleHostDescriptorStore.recordStarted(command: command, in: root)
      let completion: HerdrRoleHostCommandCompletion
      do {
        let commandEnvironment = environment.merging([
          "HERDR_PANE_ID": command.expectedPaneID,
          "HERDR_TAB_ID": command.expectedTabID,
          "HERDR_WORKSPACE_ID": command.expectedWorkspaceID,
          "JIDOKA_CODE_HERDR_EXPECTED_TERMINAL_ID": command.expectedTerminalID,
          "JIDOKA_CODE_HERDR_SEQUENCE_BASE": String(command.sequence * 2 - 1),
        ]) { _, replacement in replacement }
        let status = try await execute(command, root, commandEnvironment)
        guard status == 0 else { throw HerdrHostError.childFailed(status) }
        completion = HerdrRoleHostCommandCompletion(
          schemaVersion: 1,
          roleHostID: roleHostID,
          sequence: sequence,
          launchAttemptID: command.launchAttemptID,
          descriptorSHA256: command.descriptorSHA256,
          status: "released",
          failureCode: nil
        )
      } catch let error as HerdrHostError {
        completion = HerdrRoleHostCommandCompletion(
          schemaVersion: 1,
          roleHostID: roleHostID,
          sequence: sequence,
          launchAttemptID: command.launchAttemptID,
          descriptorSHA256: command.descriptorSHA256,
          status: "failed",
          failureCode: error.code
        )
      } catch {
        completion = HerdrRoleHostCommandCompletion(
          schemaVersion: 1,
          roleHostID: roleHostID,
          sequence: sequence,
          launchAttemptID: command.launchAttemptID,
          descriptorSHA256: command.descriptorSHA256,
          status: "failed",
          failureCode: HerdrHostError.launchFailed.code
        )
      }
      try HerdrRoleHostDescriptorStore.recordCompletion(completion, in: root)
      sequence += 1
    }
  }

  private static func validateCommand(
    _ command: HerdrRoleHostCommand,
    descriptor: HerdrRoleHostBootstrapDescriptor,
    root: URL
  ) throws {
    guard
      try HerdrRoleHostDescriptorStore.descriptorDigest(
        launchAttemptID: command.launchAttemptID,
        root: root
      ) == command.descriptorSHA256
    else {
      throw HerdrHostError.queueCommandMismatch
    }
    let launchDescriptor = try HerdrHostDescriptorStore.load(
      launchAttemptID: command.launchAttemptID,
      from: root
    )
    guard launchDescriptor.repositoryID == descriptor.repositoryID,
      launchDescriptor.jobID == descriptor.jobID,
      launchDescriptor.generation == descriptor.generation,
      launchDescriptor.role == descriptor.role,
      launchDescriptor.expectedWorkspaceID == command.expectedWorkspaceID,
      descriptor.allowedWorkflows.contains(launchDescriptor.settlement?.workflow ?? "")
    else {
      throw HerdrHostError.queueCommandMismatch
    }
  }

  static func runtimeIdentity() throws -> HerdrRoleHostRuntimeIdentity {
    var executableBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    var executableSize = UInt32(executableBuffer.count)
    guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else {
      throw HerdrHostError.invalidEnvironment
    }
    let end = executableBuffer.firstIndex(of: 0) ?? executableBuffer.endIndex
    let executablePath = String(
      decoding: executableBuffer[..<end].map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    let executable = try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: executablePath)
    )
    let data = try Data(contentsOf: executable, options: [.mappedIfSafe])
    return HerdrRoleHostRuntimeIdentity(
      process: try currentProcessIdentity(),
      executable: executable,
      executableSHA256: SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }.joined()
    )
  }

  static func processIdentity(_ processID: Int32) throws -> HerdrHostProcessIdentity {
    var information = proc_bsdinfo()
    let size = proc_pidinfo(
      processID,
      PROC_PIDTBSDINFO,
      0,
      &information,
      Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard size == MemoryLayout<proc_bsdinfo>.size,
      information.pbi_pid == UInt32(processID),
      information.pbi_status != UInt32(SZOMB)
    else {
      throw HerdrHostError.invalidEnvironment
    }
    return try HerdrHostProcessIdentity(
      processID: processID,
      startSeconds: information.pbi_start_tvsec,
      startMicroseconds: information.pbi_start_tvusec
    )
  }

  private static func currentProcessIdentity() throws -> HerdrHostProcessIdentity {
    try processIdentity(getpid())
  }
}
