import Foundation

public struct JobCanaryGenerationRolloverLaunchEvidence: Codable, Equatable, Sendable {
  public let launchAttemptID: String
  public let queueSequence: Int
  public let descriptorSHA256: String
  public let failureCode: String
  public let childProcess: HerdrChildProcessRecord?

  public init(
    launchAttemptID: String,
    queueSequence: Int,
    descriptorSHA256: String,
    failureCode: String,
    childProcess: HerdrChildProcessRecord?
  ) {
    self.launchAttemptID = launchAttemptID
    self.queueSequence = queueSequence
    self.descriptorSHA256 = descriptorSHA256
    self.failureCode = failureCode
    self.childProcess = childProcess
  }

  public func validate() throws {
    guard launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...3).contains(queueSequence),
      GitHubInputValidation.validSHA256(descriptorSHA256),
      JobCanaryRoleHostReplacementOutcome.validFailureCode(failureCode),
      childProcess == nil || childProcess?.launchAttemptID == launchAttemptID
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryGenerationRolloverHostPair: Codable, Equatable, Sendable {
  public let role: PiWorkflowRole
  public let predecessorRoleHostID: String
  public let predecessorBootstrapDescriptorSHA256: String
  public let successorRoleHostID: String
  public let successorBootstrapDescriptorSHA256: String
  public let predecessorHostExecutableSHA256: String
  public let successorHostExecutableSHA256: String
  public let successorExecutableEvidenceSHA256: String

  public init(
    role: PiWorkflowRole,
    predecessorRoleHostID: String,
    predecessorBootstrapDescriptorSHA256: String,
    successorRoleHostID: String,
    successorBootstrapDescriptorSHA256: String,
    predecessorHostExecutableSHA256: String,
    successorHostExecutableSHA256: String,
    successorExecutableEvidenceSHA256: String
  ) {
    self.role = role
    self.predecessorRoleHostID = predecessorRoleHostID
    self.predecessorBootstrapDescriptorSHA256 = predecessorBootstrapDescriptorSHA256
    self.successorRoleHostID = successorRoleHostID
    self.successorBootstrapDescriptorSHA256 = successorBootstrapDescriptorSHA256
    self.predecessorHostExecutableSHA256 = predecessorHostExecutableSHA256
    self.successorHostExecutableSHA256 = successorHostExecutableSHA256
    self.successorExecutableEvidenceSHA256 = successorExecutableEvidenceSHA256
  }

  public func validate() throws {
    guard predecessorRoleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      successorRoleHostID.wholeMatch(
        of: /^rolehost-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil,
      predecessorRoleHostID != successorRoleHostID,
      [
        predecessorBootstrapDescriptorSHA256,
        successorBootstrapDescriptorSHA256,
        predecessorHostExecutableSHA256,
        successorHostExecutableSHA256,
        successorExecutableEvidenceSHA256,
      ].allSatisfy(GitHubInputValidation.validSHA256)
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryGenerationRolloverSocketEvidence: Codable, Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let owner: UInt32
  public let permissions: UInt16
  public let peerEvidenceSHA256: String

  public init(
    device: UInt64,
    inode: UInt64,
    owner: UInt32,
    permissions: UInt16,
    peerEvidenceSHA256: String
  ) {
    self.device = device
    self.inode = inode
    self.owner = owner
    self.permissions = permissions
    self.peerEvidenceSHA256 = peerEvidenceSHA256
  }

  init(_ identity: HerdrSocketIdentity) throws {
    guard let peer = identity.peerEvidence else {
      throw EngineClientError(.invalidCommand)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    device = identity.device
    inode = identity.inode
    owner = identity.owner
    permissions = identity.permissions
    peerEvidenceSHA256 = try GitHubMarkerCodec.sha256(encoder.encode(peer))
  }

  public func validate() throws {
    guard inode > 0, permissions <= 0o777,
      GitHubInputValidation.validSHA256(peerEvidenceSHA256)
    else {
      throw EngineClientError(.invalidCommand)
    }
  }
}

public struct JobCanaryGenerationRolloverAuthorization: Codable, Equatable, Sendable {
  public let request: JobCanaryGenerationRolloverRequest
  public let canaryAuthorizationSHA256: String
  public let rolloverEvidenceSHA256: String
  public let isolationSHA256: String
  public let repositoryID: UUID
  public let jobID: UUID
  public let predecessorGeneration: Int
  public let successorGeneration: Int
  public let predecessorRunID: String
  public let predecessorLaunches: [JobCanaryGenerationRolloverLaunchEvidence]
  public let hosts: [JobCanaryGenerationRolloverHostPair]
  public let workspaceID: String
  public let socket: JobCanaryGenerationRolloverSocketEvidence
  public let successorRunID: String

  public init(
    request: JobCanaryGenerationRolloverRequest,
    canaryAuthorizationSHA256: String,
    rolloverEvidenceSHA256: String,
    isolationSHA256: String,
    repositoryID: UUID,
    jobID: UUID,
    predecessorGeneration: Int,
    successorGeneration: Int,
    predecessorRunID: String,
    predecessorLaunches: [JobCanaryGenerationRolloverLaunchEvidence],
    hosts: [JobCanaryGenerationRolloverHostPair],
    workspaceID: String,
    socket: JobCanaryGenerationRolloverSocketEvidence,
    successorRunID: String
  ) {
    self.request = request
    self.canaryAuthorizationSHA256 = canaryAuthorizationSHA256
    self.rolloverEvidenceSHA256 = rolloverEvidenceSHA256
    self.isolationSHA256 = isolationSHA256
    self.repositoryID = repositoryID
    self.jobID = jobID
    self.predecessorGeneration = predecessorGeneration
    self.successorGeneration = successorGeneration
    self.predecessorRunID = predecessorRunID
    self.predecessorLaunches = predecessorLaunches
    self.hosts = hosts
    self.workspaceID = workspaceID
    self.socket = socket
    self.successorRunID = successorRunID
  }

  public func validate() throws {
    try request.validate()
    for launch in predecessorLaunches { try launch.validate() }
    for host in hosts { try host.validate() }
    try socket.validate()
    let sortedHosts = hosts.sorted { $0.role.rawValue < $1.role.rawValue }
    let requiredRoles: Set<PiWorkflowRole> = [.architecture, .security, .test, .synthesis]
    guard
      canaryAuthorizationSHA256
        == request.retry.recovery.canary.authorizationSHA256,
      jobID == request.retry.recovery.canary.scope.jobID,
      successorRunID == request.successorRunID,
      Set(hosts.map(\.successorRoleHostID)) == Set(request.plannedHosts.map(\.roleHostID)),
      GitHubInputValidation.validSHA256(canaryAuthorizationSHA256),
      GitHubInputValidation.validSHA256(rolloverEvidenceSHA256),
      GitHubInputValidation.validSHA256(isolationSHA256),
      (1..<1_000_000).contains(predecessorGeneration),
      successorGeneration == predecessorGeneration + 1,
      predecessorRunID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      successorRunID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      successorRunID != predecessorRunID,
      predecessorLaunches.map(\.queueSequence) == [1, 2, 3],
      predecessorLaunches.map(\.failureCode)
        == ["RUNTIME_TIMEOUT", "HERDR_TRANSACTION_FAILED", "HERDR_TRANSACTION_FAILED"],
      predecessorLaunches[0].childProcess != nil,
      predecessorLaunches[1].childProcess == nil,
      predecessorLaunches[2].childProcess == nil,
      Set(predecessorLaunches.map(\.launchAttemptID)).count == 3,
      hosts == sortedHosts,
      Set(hosts.map(\.role)) == requiredRoles,
      Set(hosts.map(\.predecessorRoleHostID)).count == 4,
      Set(hosts.map(\.successorRoleHostID)).count == 4,
      workspaceID.utf8.count <= 128,
      !workspaceID.isEmpty,
      !workspaceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      GitHubInputValidation.validSHA256(lineageSHA256),
      GitHubInputValidation.validSHA256(authorizationSHA256)
    else { throw EngineClientError(.invalidCommand) }
  }

  public var lineageSHA256: String {
    let lineage = Lineage(
      predecessorGeneration: predecessorGeneration,
      successorGeneration: successorGeneration,
      predecessorRunID: predecessorRunID,
      predecessorLaunches: predecessorLaunches,
      hosts: hosts
    )
    return Self.sha256(lineage)
  }

  public var authorizationSHA256: String { Self.sha256(self) }

  private struct Lineage: Codable {
    let predecessorGeneration: Int
    let successorGeneration: Int
    let predecessorRunID: String
    let predecessorLaunches: [JobCanaryGenerationRolloverLaunchEvidence]
    let hosts: [JobCanaryGenerationRolloverHostPair]
  }

  private static func sha256<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? GitHubMarkerCodec.sha256(encoder.encode(value))) ?? ""
  }
}

public struct JobCanaryGenerationRolloverQ4Authorization: Codable, Equatable, Sendable {
  public let rolloverAuthorizationSHA256: String
  public let q4EvidenceSHA256: String
  public let successorRunID: String
  public let plannedLaunchAttemptID: String
  public let runNonce: String
  public let requestSHA256: String
  public let resourceVersion: String
  public let resourceHash: String
  public let model: String
  public let sessionPath: String
  public let channelPath: String
  public let q4Binding: JobCanaryRoleHostReplacementQ4Binding

  public init(
    rolloverAuthorizationSHA256: String,
    q4EvidenceSHA256: String,
    successorRunID: String,
    plannedLaunchAttemptID: String,
    runNonce: String,
    requestSHA256: String,
    resourceVersion: String,
    resourceHash: String,
    model: String,
    sessionPath: String,
    channelPath: String,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding
  ) {
    self.rolloverAuthorizationSHA256 = rolloverAuthorizationSHA256
    self.q4EvidenceSHA256 = q4EvidenceSHA256
    self.successorRunID = successorRunID
    self.plannedLaunchAttemptID = plannedLaunchAttemptID
    self.runNonce = runNonce
    self.requestSHA256 = requestSHA256
    self.resourceVersion = resourceVersion
    self.resourceHash = resourceHash
    self.model = model
    self.sessionPath = sessionPath
    self.channelPath = channelPath
    self.q4Binding = q4Binding
  }

  public func validate() throws {
    try q4Binding.validate()
    guard
      [
        rolloverAuthorizationSHA256, q4EvidenceSHA256, runNonce, requestSHA256,
        resourceHash,
      ].allSatisfy(GitHubInputValidation.validSHA256),
      successorRunID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      plannedLaunchAttemptID.wholeMatch(
        of: /^launch-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil,
      !resourceVersion.isEmpty, resourceVersion.utf8.count <= 128,
      !model.isEmpty, model.utf8.count <= 512,
      Self.validAbsolutePath(sessionPath), Self.validAbsolutePath(channelPath),
      GitHubInputValidation.validSHA256(authorizationSHA256)
    else { throw EngineClientError(.invalidCommand) }
  }

  public var authorizationSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? GitHubMarkerCodec.sha256(encoder.encode(self))) ?? ""
  }

  private static func validAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 4_096
      && !value.contains("//")
      && !value.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." })
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && URL(fileURLWithPath: value).standardizedFileURL.path.hasPrefix("/")
  }
}
