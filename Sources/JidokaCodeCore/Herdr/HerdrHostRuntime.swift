import CryptoKit
import Darwin
import Foundation

public enum HerdrHostError: Error, Equatable, Sendable {
  case invalidArguments
  case invalidEnvironment
  case invalidDescriptor
  case unsafeDescriptorStore
  case unsafeDescriptorRoot
  case unsafeRunDirectory
  case descriptorAlreadyExists
  case descriptorReadFailed
  case descriptorDigestMismatch
  case incompatiblePane
  case herdrTransactionFailed
  case launchFailed
  case childFailed(Int32)
  case executionTimedOut
  case cancelled
  case processGroupCleanupFailed
  case terminalControlFailed
  case tuiRuntimeFailed(String)
  case settlementMissing
  case roleHostRestartNotAuthorized
  case queueSequenceGap
  case queueCommandMismatch

  public var code: String {
    switch self {
    case .invalidArguments: "INVALID_ARGUMENTS"
    case .invalidEnvironment: "INVALID_ENVIRONMENT"
    case .invalidDescriptor: "INVALID_DESCRIPTOR"
    case .unsafeDescriptorStore: "UNSAFE_DESCRIPTOR_STORE"
    case .unsafeDescriptorRoot: "UNSAFE_DESCRIPTOR_ROOT"
    case .unsafeRunDirectory: "UNSAFE_RUN_DIRECTORY"
    case .descriptorAlreadyExists: "DESCRIPTOR_ALREADY_EXISTS"
    case .descriptorReadFailed: "DESCRIPTOR_READ_FAILED"
    case .descriptorDigestMismatch: "DESCRIPTOR_DIGEST_MISMATCH"
    case .incompatiblePane: "INCOMPATIBLE_PANE"
    case .herdrTransactionFailed: "HERDR_TRANSACTION_FAILED"
    case .launchFailed: "LAUNCH_FAILED"
    case .childFailed: "CHILD_FAILED"
    case .executionTimedOut: "EXECUTION_TIMED_OUT"
    case .cancelled: "CANCELLED"
    case .processGroupCleanupFailed: "PROCESS_GROUP_CLEANUP_FAILED"
    case .terminalControlFailed: "TERMINAL_CONTROL_FAILED"
    case .tuiRuntimeFailed: "TUI_RUNTIME_FAILED"
    case .settlementMissing: "SETTLEMENT_MISSING"
    case .roleHostRestartNotAuthorized: "ROLE_HOST_RESTART_NOT_AUTHORIZED"
    case .queueSequenceGap: "QUEUE_SEQUENCE_GAP"
    case .queueCommandMismatch: "QUEUE_COMMAND_MISMATCH"
    }
  }
}

public struct HerdrHostSettlementDescriptor: Codable, Equatable, Sendable {
  public let channelDirectory: String
  public let runID: String
  public let runNonce: String
  public let workflow: String
  public let role: String
  public let nonce: String
  public let artifactSHA256: String
  public let allowedCommandIDs: [String]

  public init(
    channelDirectory: String,
    runID: String,
    runNonce: String,
    workflow: String,
    role: String,
    nonce: String,
    artifactSHA256: String,
    allowedCommandIDs: [String]
  ) throws {
    let expectation = try PiTUIResultExpectation(
      runID: runID,
      runNonce: runNonce,
      terminalIdentity: PiRPCTerminalResultIdentity(
        workflow: workflow,
        role: role,
        nonce: nonce,
        artifactSHA256: artifactSHA256,
        allowedCommandIDs: Set(allowedCommandIDs)
      )
    )
    let canonicalChannel = try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: channelDirectory, isDirectory: true)
    )
    _ = try PiTUIResultChannel(
      directory: canonicalChannel,
      expectation: expectation
    )
    guard allowedCommandIDs.count <= 256,
      Set(allowedCommandIDs).count == allowedCommandIDs.count,
      allowedCommandIDs.allSatisfy({
        $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil
      })
    else {
      throw HerdrHostError.invalidDescriptor
    }
    self.channelDirectory = canonicalChannel.path
    self.runID = runID
    self.runNonce = runNonce
    self.workflow = workflow
    self.role = role
    self.nonce = nonce
    self.artifactSHA256 = artifactSHA256
    self.allowedCommandIDs = allowedCommandIDs.sorted()
  }

  public func resultChannel() throws -> PiTUIResultChannel {
    try PiTUIResultChannel(
      directory: URL(fileURLWithPath: channelDirectory),
      expectation: PiTUIResultExpectation(
        runID: runID,
        runNonce: runNonce,
        terminalIdentity: PiRPCTerminalResultIdentity(
          workflow: workflow,
          role: role,
          nonce: nonce,
          artifactSHA256: artifactSHA256,
          allowedCommandIDs: Set(allowedCommandIDs)
        )
      )
    )
  }
}

public struct HerdrHostDescriptor: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let launchAttemptID: String
  public let runID: String
  public let runNonce: String
  public let repositoryID: String
  public let jobID: String
  public let generation: Int
  public let role: String
  public let agentAlias: String
  public let title: String
  public let displayAgent: String
  public let expectedWorkspaceID: String
  public let childExecutable: String
  public let childArguments: [String]
  public let childWorkingDirectory: String
  public let childEnvironment: [String: String]
  public let executionTimeoutMilliseconds: Int
  public let abortGraceMilliseconds: Int
  public let settlement: HerdrHostSettlementDescriptor?
  public let piTUIInvocation: PiTUIHostInvocationDescriptor?

  public init(
    launchAttemptID: String? = nil,
    runID: String,
    runNonce: String,
    repositoryID: String,
    jobID: String,
    generation: Int,
    role: String,
    agentAlias: String,
    title: String,
    displayAgent: String,
    expectedWorkspaceID: String,
    childExecutable: String,
    childArguments: [String],
    childWorkingDirectory: String,
    childEnvironment: [String: String],
    executionTimeoutMilliseconds: Int = 3_600_000,
    abortGraceMilliseconds: Int = 5_000,
    settlement: HerdrHostSettlementDescriptor? = nil
  ) throws {
    let attemptID = launchAttemptID ?? runID
    guard settlement == nil,
      attemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      runID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      runNonce.wholeMatch(of: /^[a-z0-9][a-z0-9-]{15,127}$/) != nil,
      repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation),
      role.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      agentAlias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      Self.validDisplay(title, maximumBytes: 160),
      Self.validDisplay(displayAgent, maximumBytes: 96),
      Self.validHerdrID(expectedWorkspaceID),
      Self.validAbsolutePath(childExecutable),
      Self.validAbsolutePath(childWorkingDirectory),
      childArguments.count <= 64,
      childArguments.allSatisfy({ Self.validValue($0, maximumBytes: 4_096) }),
      childArguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
      childEnvironment.count <= 32,
      (1_000...3_600_000).contains(executionTimeoutMilliseconds),
      (100...30_000).contains(abortGraceMilliseconds),
      childEnvironment.allSatisfy({ key, value in
        Self.validEnvironmentKey(key)
          && Self.validValue(value, maximumBytes: 4_096)
          && !Self.secretShaped(key)
          && !key.hasPrefix("HERDR_")
      })
    else {
      throw HerdrHostError.invalidDescriptor
    }
    self.schemaVersion = 1
    self.launchAttemptID = attemptID
    self.runID = runID
    self.runNonce = runNonce
    self.repositoryID = repositoryID
    self.jobID = jobID
    self.generation = generation
    self.role = role
    self.agentAlias = agentAlias
    self.title = title
    self.displayAgent = displayAgent
    self.expectedWorkspaceID = expectedWorkspaceID
    self.childExecutable = childExecutable
    self.childArguments = childArguments
    self.childWorkingDirectory = childWorkingDirectory
    self.childEnvironment = childEnvironment
    self.executionTimeoutMilliseconds = executionTimeoutMilliseconds
    self.abortGraceMilliseconds = abortGraceMilliseconds
    self.settlement = nil
    self.piTUIInvocation = nil
  }

  public init(
    launchAttemptID: String,
    runID: String,
    runNonce: String,
    repositoryID: String,
    jobID: String,
    generation: Int,
    role: String,
    agentAlias: String,
    title: String,
    displayAgent: String,
    expectedWorkspaceID: String,
    piTUIInvocation: PiTUIHostInvocationDescriptor,
    settlement: HerdrHostSettlementDescriptor
  ) throws {
    try self.init(
      launchAttemptID: launchAttemptID,
      runID: runID,
      runNonce: runNonce,
      repositoryID: repositoryID,
      jobID: jobID,
      generation: generation,
      role: role,
      agentAlias: agentAlias,
      title: title,
      displayAgent: displayAgent,
      expectedWorkspaceID: expectedWorkspaceID,
      piTUIInvocation: piTUIInvocation,
      settlement: settlement,
      resolvedRuntime: nil
    )
  }

  init(
    launchAttemptID: String,
    runID: String,
    runNonce: String,
    repositoryID: String,
    jobID: String,
    generation: Int,
    role: String,
    agentAlias: String,
    title: String,
    displayAgent: String,
    expectedWorkspaceID: String,
    piTUIInvocation: PiTUIHostInvocationDescriptor,
    settlement: HerdrHostSettlementDescriptor,
    resolvedRuntime: PiResolvedRuntime?
  ) throws {
    let resolved: PiTUIResolvedHostInvocation
    do {
      resolved = try piTUIInvocation.resolved(runtime: resolvedRuntime)
    } catch {
      throw HerdrHostError.invalidDescriptor
    }
    guard launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      runID == settlement.runID,
      runNonce == settlement.runNonce,
      role == settlement.role,
      resolved.tuiConfiguration.runID == runID,
      resolved.tuiConfiguration.runNonce == runNonce,
      resolved.tuiConfiguration.workflow.rawValue == settlement.workflow,
      resolved.tuiConfiguration.role.rawValue == role,
      resolved.workflowConfiguration.nonce == settlement.nonce,
      resolved.workflowConfiguration.artifactSHA256 == settlement.artifactSHA256,
      resolved.workflowConfiguration.allowedCommandIDs == settlement.allowedCommandIDs,
      resolved.tuiConfiguration.channelDirectory.path == settlement.channelDirectory,
      repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation),
      agentAlias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      Self.validDisplay(title, maximumBytes: 160),
      Self.validDisplay(displayAgent, maximumBytes: 96),
      Self.validHerdrID(expectedWorkspaceID)
    else {
      throw HerdrHostError.invalidDescriptor
    }
    self.schemaVersion = 3
    self.launchAttemptID = launchAttemptID
    self.runID = runID
    self.runNonce = runNonce
    self.repositoryID = repositoryID
    self.jobID = jobID
    self.generation = generation
    self.role = role
    self.agentAlias = agentAlias
    self.title = title
    self.displayAgent = displayAgent
    self.expectedWorkspaceID = expectedWorkspaceID
    self.childExecutable = resolved.executable.path
    self.childArguments = resolved.arguments
    self.childWorkingDirectory = resolved.workingDirectory.path
    self.childEnvironment = resolved.environment
    self.executionTimeoutMilliseconds = resolved.executionTimeoutMilliseconds
    self.abortGraceMilliseconds = resolved.abortGraceMilliseconds
    self.settlement = settlement
    self.piTUIInvocation = piTUIInvocation
  }

  func validate(
    for requestedLaunchAttemptID: String,
    resolvedRuntime: PiResolvedRuntime? = nil
  ) throws {
    guard launchAttemptID == requestedLaunchAttemptID else {
      throw HerdrHostError.invalidDescriptor
    }
    let reconstructed: HerdrHostDescriptor
    switch schemaVersion {
    case 1:
      guard settlement == nil, piTUIInvocation == nil else {
        throw HerdrHostError.invalidDescriptor
      }
      reconstructed = try HerdrHostDescriptor(
        launchAttemptID: launchAttemptID,
        runID: runID,
        runNonce: runNonce,
        repositoryID: repositoryID,
        jobID: jobID,
        generation: generation,
        role: role,
        agentAlias: agentAlias,
        title: title,
        displayAgent: displayAgent,
        expectedWorkspaceID: expectedWorkspaceID,
        childExecutable: childExecutable,
        childArguments: childArguments,
        childWorkingDirectory: childWorkingDirectory,
        childEnvironment: childEnvironment,
        executionTimeoutMilliseconds: executionTimeoutMilliseconds,
        abortGraceMilliseconds: abortGraceMilliseconds
      )
    case 3:
      guard let settlement, let piTUIInvocation else {
        throw HerdrHostError.invalidDescriptor
      }
      reconstructed = try HerdrHostDescriptor(
        launchAttemptID: launchAttemptID,
        runID: runID,
        runNonce: runNonce,
        repositoryID: repositoryID,
        jobID: jobID,
        generation: generation,
        role: role,
        agentAlias: agentAlias,
        title: title,
        displayAgent: displayAgent,
        expectedWorkspaceID: expectedWorkspaceID,
        piTUIInvocation: piTUIInvocation,
        settlement: settlement,
        resolvedRuntime: resolvedRuntime
      )
    default:
      throw HerdrHostError.invalidDescriptor
    }
    guard reconstructed == self else { throw HerdrHostError.invalidDescriptor }
  }

  private static func validDisplay(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty
      && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validHerdrID(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validAbsolutePath(_ value: String) -> Bool {
    let url = URL(fileURLWithPath: value)
    return value.hasPrefix("/")
      && !value.unicodeScalars.contains(where: { $0.value == 0 })
      && url.standardizedFileURL.path == value
      && url.resolvingSymlinksInPath().path == value
  }

  private static func validValue(_ value: String, maximumBytes: Int) -> Bool {
    value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains(where: { $0.value == 0 })
  }

  private static func validEnvironmentKey(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Z][A-Z0-9_]{0,63}$/) != nil
  }

  private static func secretShaped(_ value: String) -> Bool {
    let upper = value.uppercased()
    return [
      "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH", "PRIVATE_KEY", "API_KEY",
      "KEY", "COOKIE", "BEARER", "SOCKET", "NODE_OPTIONS", "DYLD_", "LD_",
    ].contains(where: upper.contains)
  }
}

public struct HerdrHostFailureRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let launchAttemptID: String
  public let runID: String?
  public let code: String
  public let detailCode: String?
  public let childStatus: Int32?

  init(
    launchAttemptID: String,
    runID: String?,
    error: HerdrHostError
  ) {
    schemaVersion = 1
    self.launchAttemptID = launchAttemptID
    self.runID = runID
    code = error.code
    if case .tuiRuntimeFailed(let detail) = error {
      detailCode = detail
    } else {
      detailCode = nil
    }
    if case .childFailed(let status) = error {
      childStatus = status
    } else {
      childStatus = nil
    }
  }
}

public struct HerdrChildProcessRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let launchAttemptID: String
  public let processID: Int32
  public let processGroupID: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64

  init(
    launchAttemptID: String,
    processID: Int32,
    processGroupID: Int32,
    startSeconds: UInt64,
    startMicroseconds: UInt64
  ) {
    schemaVersion = 1
    self.launchAttemptID = launchAttemptID
    self.processID = processID
    self.processGroupID = processGroupID
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
  }

  public var processIdentity: HerdrHostProcessIdentity? {
    try? HerdrHostProcessIdentity(
      processID: processID,
      startSeconds: startSeconds,
      startMicroseconds: startMicroseconds
    )
  }
}

enum HerdrHostDescriptorPreparationPoint: CaseIterable, Sendable {
  case runDirectoryCreated
  case descriptorWritten
  case digestWritten
  case runDirectorySynced
}

public enum HerdrHostDescriptorStore {
  private static let descriptorName = "launch.json"
  private static let digestName = "launch.sha256"
  private static let failureName = "failure.json"
  private static let maximumDescriptorBytes = 1_048_576

  @discardableResult
  public static func prepare(
    _ descriptor: HerdrHostDescriptor,
    in root: URL
  ) throws -> String {
    try prepare(descriptor, in: root, failingAt: nil)
  }

  @discardableResult
  static func prepare(
    _ descriptor: HerdrHostDescriptor,
    in root: URL,
    resolvedRuntime: PiResolvedRuntime
  ) throws -> String {
    try prepare(
      descriptor,
      in: root,
      failingAt: nil,
      resolvedRuntime: resolvedRuntime
    )
  }

  @discardableResult
  static func prepare(
    _ descriptor: HerdrHostDescriptor,
    in root: URL,
    failingAt failurePoint: HerdrHostDescriptorPreparationPoint?,
    resolvedRuntime: PiResolvedRuntime? = nil
  ) throws -> String {
    try descriptor.validate(
      for: descriptor.launchAttemptID,
      resolvedRuntime: resolvedRuntime
    )
    let rootDescriptor = try openPrivateDirectory(root)
    defer { Darwin.close(rootDescriptor) }
    guard mkdirat(rootDescriptor, descriptor.launchAttemptID, 0o700) == 0 else {
      if errno == EEXIST { throw HerdrHostError.descriptorAlreadyExists }
      throw HerdrHostError.unsafeDescriptorStore
    }
    let runDescriptor = openat(
      rootDescriptor,
      descriptor.launchAttemptID,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard runDescriptor >= 0 else {
      _ = unlinkat(rootDescriptor, descriptor.launchAttemptID, AT_REMOVEDIR)
      _ = fsync(rootDescriptor)
      throw HerdrHostError.unsafeRunDirectory
    }
    defer { Darwin.close(runDescriptor) }

    do {
      try validatePrivateDirectory(runDescriptor, error: .unsafeRunDirectory)
      try failIfRequested(.runDirectoryCreated, failurePoint: failurePoint)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(descriptor)
      guard data.count <= maximumDescriptorBytes else {
        throw HerdrHostError.invalidDescriptor
      }
      data.append(0x0A)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try writeExclusive(data, name: descriptorName, in: runDescriptor)
      try failIfRequested(.descriptorWritten, failurePoint: failurePoint)
      try writeExclusive(Data("\(digest)\n".utf8), name: digestName, in: runDescriptor)
      try failIfRequested(.digestWritten, failurePoint: failurePoint)
      guard fsync(runDescriptor) == 0 else {
        throw HerdrHostError.unsafeDescriptorStore
      }
      try failIfRequested(.runDirectorySynced, failurePoint: failurePoint)
      guard fsync(rootDescriptor) == 0 else {
        throw HerdrHostError.unsafeDescriptorStore
      }
      return digest
    } catch {
      rollbackPreparation(
        launchAttemptID: descriptor.launchAttemptID,
        runDescriptor: runDescriptor,
        rootDescriptor: rootDescriptor
      )
      throw error
    }
  }

  private static func failIfRequested(
    _ point: HerdrHostDescriptorPreparationPoint,
    failurePoint: HerdrHostDescriptorPreparationPoint?
  ) throws {
    if point == failurePoint { throw HerdrHostError.unsafeDescriptorStore }
  }

  private static func rollbackPreparation(
    launchAttemptID: String,
    runDescriptor: Int32,
    rootDescriptor: Int32
  ) {
    _ = unlinkat(runDescriptor, digestName, 0)
    _ = unlinkat(runDescriptor, descriptorName, 0)
    _ = fsync(runDescriptor)
    _ = unlinkat(rootDescriptor, launchAttemptID, AT_REMOVEDIR)
    _ = fsync(rootDescriptor)
  }

  public static func load(
    launchAttemptID: String,
    from root: URL
  ) throws -> HerdrHostDescriptor {
    try load(
      launchAttemptID: launchAttemptID,
      from: root,
      resolvedRuntime: nil
    )
  }

  static func load(
    launchAttemptID: String,
    from root: URL,
    resolvedRuntime: PiResolvedRuntime?
  ) throws -> HerdrHostDescriptor {
    guard launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil else {
      throw HerdrHostError.invalidArguments
    }
    let rootDescriptor = try openPrivateDirectory(root)
    defer { Darwin.close(rootDescriptor) }
    let runDescriptor = openat(
      rootDescriptor,
      launchAttemptID,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard runDescriptor >= 0 else { throw HerdrHostError.unsafeRunDirectory }
    defer { Darwin.close(runDescriptor) }
    try validatePrivateDirectory(runDescriptor, error: .unsafeRunDirectory)
    let descriptorData = try readRegularFile(
      descriptorName,
      in: runDescriptor,
      maximumBytes: maximumDescriptorBytes
    )
    let digestData = try readRegularFile(digestName, in: runDescriptor, maximumBytes: 65)
    guard let digestLine = String(data: digestData, encoding: .utf8),
      digestLine.wholeMatch(of: /^[a-f0-9]{64}\n$/) != nil
    else {
      throw HerdrHostError.descriptorDigestMismatch
    }
    let observed = SHA256.hash(data: descriptorData)
      .map { String(format: "%02x", $0) }
      .joined()
    guard digestLine == "\(observed)\n" else {
      throw HerdrHostError.descriptorDigestMismatch
    }
    let descriptor: HerdrHostDescriptor
    do {
      descriptor = try JSONDecoder().decode(HerdrHostDescriptor.self, from: descriptorData)
    } catch {
      throw HerdrHostError.invalidDescriptor
    }
    try descriptor.validate(
      for: launchAttemptID,
      resolvedRuntime: resolvedRuntime
    )
    try validateExecutableAndWorkingDirectory(descriptor)
    return descriptor
  }

  public static func recordFailure(
    _ error: HerdrHostError,
    launchAttemptID: String,
    in root: URL
  ) throws {
    guard launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil else {
      throw HerdrHostError.invalidArguments
    }
    let runID = try? load(launchAttemptID: launchAttemptID, from: root).runID
    let record = HerdrHostFailureRecord(
      launchAttemptID: launchAttemptID,
      runID: runID,
      error: error
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(0x0A)
    try PiTUIFileProtocol.createPrivateFile(
      data: data,
      at: root.appendingPathComponent(launchAttemptID, isDirectory: true)
        .appendingPathComponent(failureName),
      idempotent: true
    )
  }

  public static func loadFailure(
    launchAttemptID: String,
    from root: URL
  ) throws -> HerdrHostFailureRecord? {
    let url = root.appendingPathComponent(launchAttemptID, isDirectory: true)
      .appendingPathComponent(failureName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 64 * 1_024)
    guard data.last == 0x0A,
      let record = try? JSONDecoder().decode(
        HerdrHostFailureRecord.self,
        from: Data(data.dropLast())
      ),
      record.schemaVersion == 1,
      record.launchAttemptID == launchAttemptID,
      record.code.wholeMatch(of: /^[A-Z][A-Z_]{2,63}$/) != nil,
      record.detailCode?.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
        || record.detailCode == nil
    else {
      throw HerdrHostError.descriptorReadFailed
    }
    return record
  }

  private static func openPrivateDirectory(_ root: URL) throws -> Int32 {
    guard root.isFileURL,
      root.path.hasPrefix("/"),
      root.standardizedFileURL.path == root.path,
      root.resolvingSymlinksInPath().path == root.path
    else {
      throw HerdrHostError.unsafeDescriptorRoot
    }
    let descriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw HerdrHostError.unsafeDescriptorRoot }
    do {
      try validatePrivateDirectory(descriptor, error: .unsafeDescriptorRoot)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func validatePrivateDirectory(
    _ descriptor: Int32,
    error: HerdrHostError
  ) throws {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == geteuid(),
      value.st_mode & 0o077 == 0
    else {
      throw error
    }
  }

  private static func writeExclusive(_ data: Data, name: String, in parent: Int32) throws {
    let descriptor = openat(
      parent,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else {
      if errno == EEXIST { throw HerdrHostError.descriptorAlreadyExists }
      throw HerdrHostError.unsafeDescriptorStore
    }
    defer { Darwin.close(descriptor) }
    guard DarwinACLAuthority.hasNoAllowEntries(descriptor) else {
      throw HerdrHostError.unsafeDescriptorStore
    }
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
          throw HerdrHostError.unsafeDescriptorStore
        }
      }
    }
    guard fsync(descriptor) == 0 else { throw HerdrHostError.unsafeDescriptorStore }
  }

  private static func readRegularFile(
    _ name: String,
    in parent: Int32,
    maximumBytes: Int
  ) throws -> Data {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HerdrHostError.descriptorReadFailed }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(),
      before.st_mode & 0o077 == 0,
      before.st_nlink == 1,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw HerdrHostError.descriptorReadFailed
    }
    let expectedCount = Int(before.st_size)
    var data = Data(count: expectedCount)
    var offset = 0
    while offset < expectedCount {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress?.advanced(by: offset), expectedCount - offset)
      }
      if count > 0 {
        offset += count
      } else if count == -1, errno == EINTR {
        continue
      } else {
        throw HerdrHostError.descriptorReadFailed
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_mode == after.st_mode,
      before.st_size == after.st_size,
      before.st_nlink == after.st_nlink
    else {
      throw HerdrHostError.descriptorReadFailed
    }
    return data
  }

  private static func validateExecutableAndWorkingDirectory(
    _ descriptor: HerdrHostDescriptor
  ) throws {
    let executableDescriptor = Darwin.open(
      descriptor.childExecutable,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard executableDescriptor >= 0 else { throw HerdrHostError.invalidDescriptor }
    defer { _ = Darwin.close(executableDescriptor) }
    let directoryDescriptor = Darwin.open(
      descriptor.childWorkingDirectory,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else { throw HerdrHostError.invalidDescriptor }
    defer { _ = Darwin.close(directoryDescriptor) }
    var executable = stat()
    var directory = stat()
    guard fstat(executableDescriptor, &executable) == 0,
      DarwinACLAuthority.hasNoAllowEntries(executableDescriptor),
      executable.st_mode & S_IFMT == S_IFREG,
      executable.st_mode & 0o111 != 0,
      executable.st_mode & 0o022 == 0,
      executable.st_nlink == 1,
      executable.st_uid == 0 || executable.st_uid == geteuid(),
      fstat(directoryDescriptor, &directory) == 0,
      DarwinACLAuthority.hasNoAllowEntries(directoryDescriptor),
      directory.st_mode & S_IFMT == S_IFDIR,
      directory.st_mode & 0o022 == 0,
      directory.st_uid == geteuid()
    else {
      throw HerdrHostError.invalidDescriptor
    }
  }
}

public enum HerdrHostRuntime {
  static func childProcessRecord(
    launchAttemptID: String,
    channelDirectory: URL
  ) throws -> HerdrChildProcessRecord? {
    guard launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil else {
      throw HerdrHostError.invalidDescriptor
    }
    let url = childProcessRecordURL(
      launchAttemptID: launchAttemptID,
      channelDirectory: channelDirectory
    )
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try PiTUIFileProtocol.readPrivateFile(url, maximumBytes: 4_096)
    let decoder = JSONDecoder()
    guard let record = try? decoder.decode(HerdrChildProcessRecord.self, from: data),
      record.schemaVersion == 1,
      record.launchAttemptID == launchAttemptID,
      record.processID > 0,
      record.processGroupID == record.processID,
      record.startMicroseconds < 1_000_000,
      try encodedChildProcessRecord(record) == data
    else {
      throw HerdrHostError.invalidDescriptor
    }
    return record
  }

  static func childProcessIsAbsent(_ record: HerdrChildProcessRecord) -> Bool {
    guard record.processIdentity != nil else { return false }
    return !processGroupExists(record.processGroupID)
  }

  static func terminateChildProcess(
    _ record: HerdrChildProcessRecord,
    graceMilliseconds: Int = 1_000
  ) async throws {
    guard graceMilliseconds > 0, let identity = record.processIdentity,
      record.processGroupID == record.processID
    else {
      throw HerdrHostError.invalidDescriptor
    }
    guard processGroupExists(record.processGroupID) else { return }
    if let current = try? HerdrRoleHostRuntime.processIdentity(identity.processID) {
      guard current == identity, getpgid(record.processID) == record.processGroupID else {
        throw HerdrHostError.processGroupCleanupFailed
      }
    }
    try await terminateProcessGroup(
      record.processGroupID,
      graceMilliseconds: graceMilliseconds
    )
  }

  public static func run(
    arguments: [String],
    environment: [String: String]
  ) async throws -> Int32 {
    if arguments.first == "--role-host-id" {
      return try await HerdrRoleHostRuntime.run(
        arguments: arguments,
        environment: environment
      )
    }
    do {
      return try await run(
        arguments: arguments,
        environment: environment,
        responseTimeoutSeconds: 2,
        launchOperation: { try await launch($0) }
      )
    } catch let error as HerdrHostError {
      if arguments.count == 2,
        arguments[0] == "--launch-attempt-id",
        let rootValue = environment["JIDOKA_CODE_HERDR_RUN_ROOT"]
      {
        try? HerdrHostDescriptorStore.recordFailure(
          error,
          launchAttemptID: arguments[1],
          in: URL(fileURLWithPath: rootValue, isDirectory: true)
        )
      }
      throw error
    }
  }

  static func run(
    arguments: [String],
    environment: [String: String],
    responseTimeoutSeconds: TimeInterval = 30,
    descriptorLoader: @escaping @Sendable (String, URL) throws -> HerdrHostDescriptor = {
      try HerdrHostDescriptorStore.load(launchAttemptID: $0, from: $1)
    },
    launchOperation: @escaping @Sendable (HerdrHostDescriptor) async throws -> Int32
  ) async throws -> Int32 {
    guard arguments.count == 2,
      arguments[0] == "--launch-attempt-id",
      arguments[1].wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      let rootValue = environment["JIDOKA_CODE_HERDR_RUN_ROOT"],
      let socketValue = environment["HERDR_SOCKET_PATH"],
      let paneID = environment["HERDR_PANE_ID"],
      let workspaceID = environment["HERDR_WORKSPACE_ID"],
      let tabID = environment["HERDR_TAB_ID"]
    else {
      throw HerdrHostError.invalidArguments
    }
    let launchAttemptID = arguments[1]
    let sequenceBase: UInt64
    if let value = environment["JIDOKA_CODE_HERDR_SEQUENCE_BASE"] {
      guard let parsed = UInt64(value), parsed > 0, parsed.isMultiple(of: 2) == false,
        parsed < UInt64.max
      else {
        throw HerdrHostError.invalidEnvironment
      }
      sequenceBase = parsed
    } else {
      sequenceBase = 1
    }
    let expectedTerminalID = environment["JIDOKA_CODE_HERDR_EXPECTED_TERMINAL_ID"]
    guard expectedTerminalID == nil || expectedTerminalID.map(Self.validHerdrEnvironmentID) == true
    else {
      throw HerdrHostError.invalidEnvironment
    }
    let root = URL(fileURLWithPath: rootValue, isDirectory: true)
    let descriptor = try descriptorLoader(launchAttemptID, root)
    let herdrCapabilities = [socketValue, paneID, workspaceID, tabID]
    guard descriptor.expectedWorkspaceID == workspaceID,
      descriptor.childEnvironment.values.allSatisfy({ value in
        !herdrCapabilities.contains(where: value.contains)
      })
    else {
      throw HerdrHostError.incompatiblePane
    }
    let reporter: HerdrHostPaneReporter
    do {
      reporter = try HerdrHostPaneReporter(
        socketPath: socketValue,
        paneID: paneID,
        workspaceID: workspaceID,
        tabID: tabID,
        expectedTerminalID: expectedTerminalID,
        responseTimeoutSeconds: responseTimeoutSeconds,
        sequenceBase: sequenceBase
      )
    } catch {
      throw HerdrHostError.invalidEnvironment
    }
    try await reporter.start(descriptor: descriptor)

    let settlementChannel: PiTUIResultChannel?
    do {
      settlementChannel = try descriptor.settlement?.resultChannel()
      if let channel = settlementChannel, try channel.preparedResult() != nil {
        try await waitForAcceptance(channel: channel)
        await waitForRelease(channel: channel)
        await Task.detached {
          try? await reporter.finish(descriptor: descriptor, status: 0)
        }.value
        return 0
      }
    } catch {
      try? await reporter.finish(descriptor: descriptor, status: -1)
      throw HerdrHostError.settlementMissing
    }

    let launchResult: Result<Int32, HerdrHostError>
    do {
      launchResult = .success(try await launchOperation(descriptor))
    } catch let error as HerdrHostError {
      launchResult = .failure(error)
    } catch {
      launchResult = .failure(.launchFailed)
    }

    if let channel = settlementChannel {
      let accepted: Bool
      do {
        accepted = try channel.acceptedResult() != nil
      } catch {
        try? await reporter.finish(descriptor: descriptor, status: -1)
        throw HerdrHostError.settlementMissing
      }
      if accepted {
        await waitForRelease(channel: channel)
        await Task.detached {
          try? await reporter.finish(descriptor: descriptor, status: 0)
        }.value
        return 0
      }
      let runtimeFailureCode = try? channel.runtimeFailureCode()
      await Task.detached {
        try? await reporter.finish(descriptor: descriptor, status: -1)
      }.value
      if let runtimeFailureCode {
        throw HerdrHostError.tuiRuntimeFailed(runtimeFailureCode)
      }
      switch launchResult {
      case .failure(let error): throw error
      case .success(let status) where status != 0: throw HerdrHostError.childFailed(status)
      case .success: throw HerdrHostError.settlementMissing
      }
    }

    switch launchResult {
    case .failure(let error):
      await Task.detached {
        try? await reporter.finish(descriptor: descriptor, status: -1)
      }.value
      throw error
    case .success(let status) where status != 0:
      await Task.detached {
        try? await reporter.finish(descriptor: descriptor, status: status)
      }.value
      throw HerdrHostError.childFailed(status)
    case .success(let status):
      try await reporter.finish(descriptor: descriptor, status: status)
      return status
    }
  }

  private static func waitForAcceptance(channel: PiTUIResultChannel) async throws {
    while true {
      if try channel.acceptedResult() != nil { return }
      await noncancellableDelay(milliseconds: 50)
    }
  }

  private static func waitForRelease(channel: PiTUIResultChannel) async {
    while true {
      if (try? channel.isReleased()) == true { return }
      await noncancellableDelay(milliseconds: 50)
    }
  }

  private static func launch(_ descriptor: HerdrHostDescriptor) async throws -> Int32 {
    let timeout = descriptor.executionTimeoutMilliseconds
    let grace = descriptor.abortGraceMilliseconds
    let pid = try spawn(descriptor)
    if descriptor.settlement != nil {
      do {
        try recordChildProcess(pid, descriptor: descriptor)
      } catch {
        _ = Darwin.kill(-pid, SIGKILL)
        _ = waitForChild(pid)
        throw error
      }
    }
    let transfersTerminal = descriptor.settlement != nil && isatty(STDIN_FILENO) == 1
    let originalForegroundGroup = transfersTerminal ? tcgetpgrp(STDIN_FILENO) : -1
    if transfersTerminal {
      guard originalForegroundGroup > 0,
        setForegroundProcessGroup(pid) == 0
      else {
        _ = Darwin.kill(-pid, SIGKILL)
        _ = waitForChild(pid)
        throw HerdrHostError.terminalControlFailed
      }
    }
    guard Darwin.kill(-pid, SIGCONT) == 0 else {
      _ = Darwin.kill(-pid, SIGKILL)
      _ = waitForChild(pid)
      throw HerdrHostError.launchFailed
    }

    do {
      let status = try await awaitChild(
        pid: pid,
        timeoutMilliseconds: timeout,
        abortGraceMilliseconds: grace
      )
      if transfersTerminal, setForegroundProcessGroup(originalForegroundGroup) != 0 {
        throw HerdrHostError.terminalControlFailed
      }
      return status
    } catch {
      if transfersTerminal, setForegroundProcessGroup(originalForegroundGroup) != 0 {
        throw HerdrHostError.terminalControlFailed
      }
      throw error
    }
  }

  private static func recordChildProcess(
    _ processID: pid_t,
    descriptor: HerdrHostDescriptor
  ) throws {
    guard let settlement = descriptor.settlement,
      getpgid(processID) == processID
    else {
      throw HerdrHostError.invalidDescriptor
    }
    let identity = try HerdrRoleHostRuntime.processIdentity(processID)
    let record = HerdrChildProcessRecord(
      launchAttemptID: descriptor.launchAttemptID,
      processID: processID,
      processGroupID: processID,
      startSeconds: identity.startSeconds,
      startMicroseconds: identity.startMicroseconds
    )
    try PiTUIFileProtocol.createPrivateFile(
      data: try encodedChildProcessRecord(record),
      at: childProcessRecordURL(
        launchAttemptID: descriptor.launchAttemptID,
        channelDirectory: URL(fileURLWithPath: settlement.channelDirectory, isDirectory: true)
      ),
      idempotent: true
    )
  }

  private static func encodedChildProcessRecord(
    _ record: HerdrChildProcessRecord
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(record)
    data.append(0x0A)
    return data
  }

  private static func childProcessRecordURL(
    launchAttemptID: String,
    channelDirectory: URL
  ) -> URL {
    channelDirectory.appendingPathComponent("child-process-\(launchAttemptID).json")
  }

  private enum ChildRace: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled

    var isCancellation: Bool {
      if case .cancelled = self { return true }
      return false
    }
  }

  private static func awaitChild(
    pid: pid_t,
    timeoutMilliseconds: Int,
    abortGraceMilliseconds: Int
  ) async throws -> Int32 {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: ChildRace.self, returning: Int32.self) { group in
        group.addTask { .exited(waitForChild(pid)) }
        group.addTask {
          do {
            try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
            return .timedOut
          } catch {
            return .cancelled
          }
        }
        guard let first = try await group.next() else { throw HerdrHostError.launchFailed }
        switch first {
        case .exited(let status):
          group.cancelAll()
          if Task.isCancelled {
            try await terminateProcessGroup(pid, graceMilliseconds: abortGraceMilliseconds)
            throw HerdrHostError.cancelled
          }
          try await terminateRemainingDescendants(
            pid,
            graceMilliseconds: abortGraceMilliseconds
          )
          return status
        case .timedOut, .cancelled:
          group.cancelAll()
          try await terminateProcessGroup(pid, graceMilliseconds: abortGraceMilliseconds)
          while let event = try await group.next() {
            if case .exited = event { break }
          }
          if Task.isCancelled || first.isCancellation {
            throw HerdrHostError.cancelled
          }
          throw HerdrHostError.executionTimedOut
        }
      }
    } onCancel: {
      _ = Darwin.kill(-pid, SIGTERM)
    }
  }

  private static func terminateRemainingDescendants(
    _ processGroup: pid_t,
    graceMilliseconds: Int
  ) async throws {
    guard processGroupExists(processGroup) else { return }
    _ = Darwin.kill(-processGroup, SIGTERM)
    await noncancellableDelay(milliseconds: graceMilliseconds)
    if processGroupExists(processGroup) {
      _ = Darwin.kill(-processGroup, SIGKILL)
      await noncancellableDelay(milliseconds: 1_000)
    }
    guard !processGroupExists(processGroup) else {
      throw HerdrHostError.processGroupCleanupFailed
    }
  }

  private static func terminateProcessGroup(
    _ processGroup: pid_t,
    graceMilliseconds: Int
  ) async throws {
    _ = Darwin.kill(-processGroup, SIGTERM)
    await noncancellableDelay(milliseconds: graceMilliseconds)
    if processGroupExists(processGroup) {
      _ = Darwin.kill(-processGroup, SIGKILL)
      await noncancellableDelay(milliseconds: 1_000)
    }
    guard !processGroupExists(processGroup) else {
      throw HerdrHostError.processGroupCleanupFailed
    }
  }

  private static func processGroupExists(_ processGroup: pid_t) -> Bool {
    if Darwin.kill(-processGroup, 0) == 0 { return true }
    return errno == EPERM
  }

  private static func noncancellableDelay(milliseconds: Int) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
        continuation.resume()
      }
    }
  }

  private static func waitForChild(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
      if errno == EINTR { continue }
      return 255
    }
    if status & 0x7F == 0 { return (status >> 8) & 0xFF }
    return 128 + (status & 0x7F)
  }

  private static func spawn(_ descriptor: HerdrHostDescriptor) throws -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0,
      posix_spawn_file_actions_addchdir_np(&actions, descriptor.childWorkingDirectory) == 0,
      posix_spawnattr_init(&attributes) == 0
    else {
      if actions != nil { posix_spawn_file_actions_destroy(&actions) }
      throw HerdrHostError.launchFailed
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    var mask = sigset_t()
    var defaults = sigset_t()
    sigemptyset(&mask)
    sigemptyset(&defaults)
    for signal in [SIGINT, SIGTERM, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
      sigaddset(&defaults, signal)
    }
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_START_SUSPENDED
    )
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawnattr_setsigmask(&attributes, &mask) == 0,
      posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
    else {
      throw HerdrHostError.launchFailed
    }
    let argumentValues = [descriptor.childExecutable] + descriptor.childArguments
    let environmentValues = descriptor.childEnvironment.keys.sorted().map {
      "\($0)=\(descriptor.childEnvironment[$0]!)"
    }
    var pid: pid_t = 0
    let result = withCStringArray(argumentValues) { arguments in
      withCStringArray(environmentValues) { environment in
        posix_spawn(
          &pid,
          descriptor.childExecutable,
          &actions,
          &attributes,
          arguments,
          environment
        )
      }
    }
    guard result == 0, pid > 0, getpgid(pid) == pid else {
      if pid > 0 {
        _ = Darwin.kill(pid, SIGKILL)
        _ = waitForChild(pid)
      }
      throw HerdrHostError.launchFailed
    }
    return pid
  }

  private static func withCStringArray<Result>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    let strings: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    defer {
      for string in strings { free(string) }
    }
    var pointers = strings + [nil]
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
  }

  private static func validHerdrEnvironmentID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func setForegroundProcessGroup(_ processGroup: pid_t) -> Int32 {
    var blocked = sigset_t()
    var previous = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGTTOU)
    guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { return EINVAL }
    defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
    return tcsetpgrp(STDIN_FILENO, processGroup) == 0 ? 0 : errno
  }
}

private actor HerdrHostPaneReporter {
  private let client: HerdrSocketClient
  private let paneID: String
  private let workspaceID: String
  private let tabID: String
  private let expectedTerminalID: String?
  private let sequenceBase: UInt64
  private var terminalID: String?

  init(
    socketPath: String,
    paneID: String,
    workspaceID: String,
    tabID: String,
    expectedTerminalID: String?,
    responseTimeoutSeconds: TimeInterval,
    sequenceBase: UInt64
  ) throws {
    guard Self.validID(paneID), Self.validID(workspaceID), Self.validID(tabID) else {
      throw HerdrHostError.invalidEnvironment
    }
    client = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: URL(fileURLWithPath: socketPath),
        timeoutSeconds: responseTimeoutSeconds
      )
    )
    self.paneID = paneID
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.expectedTerminalID = expectedTerminalID
    self.sequenceBase = sequenceBase
  }

  func start(descriptor: HerdrHostDescriptor) async throws {
    let evidence: (handshake: HerdrHandshake, terminalID: String)
    do {
      evidence = try await client.startHostPane(
        paneID: paneID,
        workspaceID: workspaceID,
        tabID: tabID,
        expectedTerminalID: expectedTerminalID,
        agent: HerdrPaneReportAgentParameters(
          paneID: paneID,
          source: "jidoka:host",
          agent: "pi",
          state: .working,
          message: "running",
          sequence: sequenceBase
        ),
        metadata: metadata(
          descriptor: descriptor,
          summary: "running",
          sequence: sequenceBase
        ),
        alias: descriptor.agentAlias
      )
    } catch {
      throw HerdrHostError.herdrTransactionFailed
    }
    terminalID = evidence.terminalID
  }

  func finish(descriptor: HerdrHostDescriptor, status: Int32) async throws {
    guard let terminalID else { throw HerdrHostError.incompatiblePane }
    let success = status == 0
    do {
      try await client.finishHostPane(
        paneID: paneID,
        workspaceID: workspaceID,
        tabID: tabID,
        terminalID: terminalID,
        agent: HerdrPaneReportAgentParameters(
          paneID: paneID,
          source: "jidoka:host",
          agent: "pi",
          state: success ? .idle : .blocked,
          message: success ? "settled" : "failed",
          sequence: sequenceBase + 1
        ),
        metadata: metadata(
          descriptor: descriptor,
          summary: success ? "settled" : "failed",
          sequence: sequenceBase + 1
        )
      )
    } catch {
      throw HerdrHostError.herdrTransactionFailed
    }
  }

  private func metadata(
    descriptor: HerdrHostDescriptor,
    summary: String,
    sequence: UInt64
  ) -> HerdrPaneReportMetadataParameters {
    HerdrPaneReportMetadataParameters(
      paneID: paneID,
      source: "jidoka:coordination",
      agent: "pi",
      appliesToSource: "jidoka:host",
      title: descriptor.title,
      displayAgent: descriptor.displayAgent,
      stateLabels: [
        "working": "running",
        "blocked": "needs attention",
        "idle": "settled",
        "done": "settled",
      ],
      tokens: [
        "managed_by": "jidoka",
        "repository_id": descriptor.repositoryID,
        "job_id": descriptor.jobID,
        "generation": String(descriptor.generation),
        "role": descriptor.role,
        "run_id": descriptor.runID,
        "launch_attempt_id": descriptor.launchAttemptID,
        "summary": summary,
      ],
      sequence: sequence
    )
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

}
