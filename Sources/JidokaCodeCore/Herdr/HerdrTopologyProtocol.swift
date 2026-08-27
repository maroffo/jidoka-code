import CryptoKit
import Darwin
import Foundation
import Security

public enum HerdrSplitDirection: String, Codable, Equatable, Sendable {
  case right
  case down
}

public struct HerdrLayoutPane: Equatable, Sendable {
  public let paneID: String?
  public let label: String?
  public let workingDirectory: String?
  public let command: [String]?
  public let environment: [String: String]

  init(
    paneID: String? = nil,
    label: String?,
    workingDirectory: String?,
    command: [String]?,
    environment: [String: String]
  ) {
    self.paneID = paneID
    self.label = label
    self.workingDirectory = workingDirectory
    self.command = command
    self.environment = environment
  }
}

public struct HerdrLayoutSplit: Equatable, Sendable {
  public let direction: HerdrSplitDirection
  public let ratio: Double
  public let first: HerdrLayoutNode
  public let second: HerdrLayoutNode
}

public indirect enum HerdrLayoutNode: Equatable, Sendable {
  case pane(HerdrLayoutPane)
  case split(HerdrLayoutSplit)
}

extension HerdrLayoutNode: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case paneID = "pane_id"
    case label
    case cwd
    case command
    case env
    case direction
    case ratio
    case first
    case second
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "pane":
      self = .pane(
        HerdrLayoutPane(
          paneID: try container.decodeIfPresent(String.self, forKey: .paneID),
          label: try container.decodeIfPresent(String.self, forKey: .label),
          workingDirectory: try container.decodeIfPresent(String.self, forKey: .cwd),
          command: try container.decodeIfPresent([String].self, forKey: .command),
          environment: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        )
      )
    case "split":
      self = .split(
        HerdrLayoutSplit(
          direction: try container.decode(HerdrSplitDirection.self, forKey: .direction),
          ratio: try container.decode(Double.self, forKey: .ratio),
          first: try container.decode(HerdrLayoutNode.self, forKey: .first),
          second: try container.decode(HerdrLayoutNode.self, forKey: .second)
        )
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unsupported Herdr layout node"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let pane):
      try container.encode("pane", forKey: .type)
      try container.encodeIfPresent(pane.paneID, forKey: .paneID)
      try container.encodeIfPresent(pane.label, forKey: .label)
      try container.encodeIfPresent(pane.workingDirectory, forKey: .cwd)
      try container.encodeIfPresent(pane.command, forKey: .command)
      try container.encode(pane.environment, forKey: .env)
    case .split(let split):
      try container.encode("split", forKey: .type)
      try container.encode(split.direction, forKey: .direction)
      try container.encode(split.ratio, forKey: .ratio)
      try container.encode(split.first, forKey: .first)
      try container.encode(split.second, forKey: .second)
    }
  }
}

public struct HerdrLayoutDescription: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let tabID: String
  public let zoomed: Bool
  public let focusedPaneID: String
  public let root: HerdrLayoutNode

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case zoomed
    case focusedPaneID = "focused_pane_id"
    case root
  }
}

struct HerdrWorkspaceCreateParameters: Codable, Equatable, Sendable {
  let label: String
  let cwd: String
  let env: [String: String]
  let focus: Bool
}

struct HerdrWorkspaceCreatedResult: Codable, Equatable, Sendable {
  let type: String
  let workspace: HerdrWorkspaceSnapshot
  let tab: HerdrTabSnapshot
  let rootPane: HerdrPaneSnapshot

  private enum CodingKeys: String, CodingKey {
    case type
    case workspace
    case tab
    case rootPane = "root_pane"
  }
}

struct HerdrWorkspaceTargetParameters: Codable, Equatable, Sendable {
  let workspaceID: String

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
  }
}

struct HerdrWorkspaceInfoResult: Codable, Equatable, Sendable {
  let type: String
  let workspace: HerdrWorkspaceSnapshot
}

struct HerdrTabTargetParameters: Codable, Equatable, Sendable {
  let tabID: String

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
  }
}

struct HerdrTabInfoResult: Codable, Equatable, Sendable {
  let type: String
  let tab: HerdrTabSnapshot
}

struct HerdrPaneInfoResult: Codable, Equatable, Sendable {
  let type: String
  let pane: HerdrPaneSnapshot
}

struct HerdrLayoutApplyParameters: Codable, Equatable, Sendable {
  let workspaceID: String
  let tabLabel: String
  let focus: Bool
  let root: HerdrLayoutNode

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case tabLabel = "tab_label"
    case focus
    case root
  }
}

struct HerdrLayoutApplyResult: Codable, Equatable, Sendable {
  let type: String
  let layout: HerdrLayoutDescription
}

struct HerdrLayoutExportParameters: Codable, Equatable, Sendable {
  let tabID: String

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
  }
}

struct HerdrLayoutExportResult: Codable, Equatable, Sendable {
  let type: String
  let layout: HerdrLayoutDescription
}

enum HerdrPaneReportedState: String, Codable, Equatable, Sendable {
  case idle
  case working
  case blocked
  case unknown
}

struct HerdrPaneReportAgentParameters: Codable, Equatable, Sendable {
  let paneID: String
  let source: String
  let agent: String
  let state: HerdrPaneReportedState
  let message: String
  let sequence: UInt64

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case source
    case agent
    case state
    case message
    case sequence = "seq"
  }
}

struct HerdrPaneReportMetadataParameters: Codable, Equatable, Sendable {
  let paneID: String
  let source: String
  let agent: String
  let appliesToSource: String
  let title: String
  let displayAgent: String
  let stateLabels: [String: String]
  let tokens: [String: String]
  let sequence: UInt64

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case source
    case agent
    case appliesToSource = "applies_to_source"
    case title
    case displayAgent = "display_agent"
    case stateLabels = "state_labels"
    case tokens
    case sequence = "seq"
  }
}

struct HerdrAgentTargetParameters: Codable, Equatable, Sendable {
  let target: String
}

struct HerdrPaneClearAgentAuthorityParameters: Codable, Equatable, Sendable {
  let paneID: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
  }
}

struct HerdrAgentAuthorityPrime: Equatable, Sendable {
  let workspaceID: String
  let tabID: String
  let paneID: String
  let terminalID: String
  let agent: HerdrPaneReportAgentParameters
  let metadata: HerdrPaneReportMetadataParameters
  let alias: String
}

struct HerdrAgentAuthorityPrimeEvidence: Equatable, Sendable {
  let socketIdentity: HerdrSocketIdentity
  let pane: HerdrPaneSnapshot
  let agent: HerdrAgentSnapshot
}

struct HerdrAgentAuthorityReset: Equatable, Sendable {
  let prime: HerdrAgentAuthorityPrime
  let expectedPaneRevision: UInt64
  let expectedTokens: [String: String]?
}

struct HerdrAgentAuthorityPrimePayload: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let canaryAuthorizationSHA256: String
  let maximumCommentParts: Int
  let recoveryEvidenceSHA256: String
  let retryEvidenceSHA256: String
  let repositoryID: String
  let jobID: String
  let generation: Int
  let runID: String
  let failedLaunchAttemptID: String
  let plannedLaunchAttemptID: String
  let roleHostID: String
  let queueSequence: Int
  let hostProcessID: Int32
  let hostStartSeconds: UInt64
  let hostStartMicroseconds: UInt64
  let hostExecutableSHA256: String
  let workspaceID: String
  let tabID: String
  let paneID: String
  let terminalID: String
  let agentSource: String
  let metadataSource: String
  let alias: String
  let reportSequence: UInt64
  let tokens: [String: String]
  let failedPrimeIntentID: String?
  let failedPrimeIntentSHA256: String?
  let failedPrimePayloadSHA256: String?
  let stalePaneRevision: UInt64?
  let stalePaneHadTokens: Bool?
  let stalePaneTokensSHA256: String?

  func validate() throws {
    guard
      [
        canaryAuthorizationSHA256, recoveryEvidenceSHA256, retryEvidenceSHA256,
        hostExecutableSHA256,
      ].allSatisfy(GitHubInputValidation.validSHA256),
      (1...JobCanaryScope.maximumCommentPartLimit).contains(maximumCommentParts),
      [repositoryID, jobID, runID, failedLaunchAttemptID, plannedLaunchAttemptID, roleHostID]
        .allSatisfy({ $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil }),
      generation > 0,
      queueSequence == 4,
      hostProcessID > 0,
      hostStartMicroseconds < 1_000_000,
      [workspaceID, tabID, paneID, terminalID, agentSource, metadataSource]
        .allSatisfy(Self.validOpaqueID),
      agentSource != metadataSource,
      alias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      (1...16).contains(tokens.count),
      tokens.allSatisfy({ Self.validToken($0.key, $0.value) })
    else { throw HerdrTopologyError.invalidPlan }
    let failedPrimeEvidence = [failedPrimeIntentSHA256, failedPrimePayloadSHA256]
    switch schemaVersion {
    case 1:
      guard reportSequence == 1,
        failedPrimeIntentID == nil,
        failedPrimeEvidence.allSatisfy({ $0 == nil }),
        stalePaneRevision == nil,
        stalePaneHadTokens == nil,
        stalePaneTokensSHA256 == nil
      else { throw HerdrTopologyError.invalidPlan }
    case 2:
      guard reportSequence == 7,
        agentSource == "jidoka:host",
        metadataSource == "jidoka:coordination",
        failedPrimeIntentID?.wholeMatch(of: /^prime-[0-9a-f-]{36}$/) != nil,
        failedPrimeEvidence.allSatisfy({ $0.map(GitHubInputValidation.validSHA256) == true }),
        stalePaneRevision.map({ $0 > 0 }) == true,
        stalePaneHadTokens != nil,
        stalePaneTokensSHA256.map(GitHubInputValidation.validSHA256) == true
      else { throw HerdrTopologyError.invalidPlan }
    default:
      throw HerdrTopologyError.invalidPlan
    }
  }

  var intentKind: HerdrTopologyMutationIntent.Kind {
    schemaVersion == 2 ? .resetAgentAuthority : .primeAgentAuthority
  }

  var payloadSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return GitHubMarkerCodec.sha256(data)
  }

  var attribution: HerdrTopologyMutationAttribution {
    HerdrTopologyMutationAttribution(
      workspaceID: workspaceID,
      tabID: tabID,
      paneIDs: [paneID]
    )
  }

  private static func validOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validToken(_ key: String, _ value: String) -> Bool {
    key.wholeMatch(of: /^[A-Za-z0-9_-]{1,32}$/) != nil
      && !value.isEmpty && value.utf8.count <= 256
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct HerdrAgentAuthorityPrimeAttribution: Codable, Equatable, Sendable {
  let workspaceID: String
  let tabID: String
  let paneIDs: [String]
  let terminalID: String
  let alias: String
  let agent: String
  let agentSessionAbsent: Bool
  let paneRevision: UInt64
  let agentStateChangeSequence: UInt64
  let tokensSHA256: String

  init(
    workspaceID: String,
    tabID: String,
    paneIDs: [String],
    terminalID: String,
    alias: String,
    agent: String,
    agentSessionAbsent: Bool,
    paneRevision: UInt64,
    agentStateChangeSequence: UInt64,
    tokensSHA256: String
  ) {
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.paneIDs = paneIDs
    self.terminalID = terminalID
    self.alias = alias
    self.agent = agent
    self.agentSessionAbsent = agentSessionAbsent
    self.paneRevision = paneRevision
    self.agentStateChangeSequence = agentStateChangeSequence
    self.tokensSHA256 = tokensSHA256
  }

  init(payload: HerdrAgentAuthorityPrimePayload, evidence: HerdrAgentAuthorityPrimeEvidence) {
    workspaceID = payload.workspaceID
    tabID = payload.tabID
    paneIDs = [payload.paneID]
    terminalID = payload.terminalID
    alias = payload.alias
    agent = "pi"
    agentSessionAbsent = evidence.pane.agentSession == nil && evidence.agent.agentSession == nil
    paneRevision = evidence.pane.revision
    agentStateChangeSequence = evidence.agent.stateChangeSequence
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    tokensSHA256 = (try? encoder.encode(payload.tokens)).map(GitHubMarkerCodec.sha256) ?? ""
  }

  var topology: HerdrTopologyMutationAttribution {
    HerdrTopologyMutationAttribution(
      workspaceID: workspaceID,
      tabID: tabID,
      paneIDs: paneIDs
    )
  }
}

struct HerdrExecutableCodeIdentity: Codable, Equatable, Sendable {
  let identifier: String
  let teamIdentifier: String?
  let codeDirectoryHashSHA256: String
  let designatedRequirement: String

  init(
    identifier: String,
    teamIdentifier: String?,
    codeDirectoryHashSHA256: String,
    designatedRequirement: String
  ) throws {
    guard !identifier.isEmpty, identifier.utf8.count <= 512,
      !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      teamIdentifier.map({
        !$0.isEmpty && $0.utf8.count <= 128
          && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      }) ?? true,
      GitHubInputValidation.validSHA256(codeDirectoryHashSHA256),
      !designatedRequirement.isEmpty, designatedRequirement.utf8.count <= 16_384,
      !designatedRequirement.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw HerdrTopologyError.invalidPlan }
    self.identifier = identifier
    self.teamIdentifier = teamIdentifier
    self.codeDirectoryHashSHA256 = codeDirectoryHashSHA256
    self.designatedRequirement = designatedRequirement
  }

  static func inspectStatic(at executable: URL) throws -> Self {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    else { throw HerdrTopologyError.invalidPlan }
    return try inspect(code)
  }

  static func inspectRunning(processID: Int32, executable: URL) throws -> Self {
    var running: SecCode?
    let attributes =
      [
        kSecGuestAttributePid as String: NSNumber(value: processID)
      ] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &running) == errSecSuccess,
      let running,
      SecCodeCheckValidity(running, SecCSFlags(), nil) == errSecSuccess
    else { throw HerdrTopologyError.invalidPlan }
    var code: SecStaticCode?
    guard SecCodeCopyStaticCode(running, SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    else { throw HerdrTopologyError.invalidPlan }
    var path: CFURL?
    guard SecCodeCopyPath(code, SecCSFlags(), &path) == errSecSuccess,
      let path,
      (path as URL).resolvingSymlinksInPath().standardizedFileURL == executable
    else { throw HerdrTopologyError.invalidPlan }
    return try inspect(code)
  }

  private static func inspect(_ code: SecStaticCode) throws -> Self {
    var requirement: SecRequirement?
    var requirementText: CFString?
    var information: CFDictionary?
    guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
      let requirement,
      SecRequirementCopyString(requirement, SecCSFlags(), &requirementText) == errSecSuccess,
      let requirementText,
      SecCodeCopySigningInformation(
        code,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any],
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let unique = values[kSecCodeInfoUnique as String] as? Data
    else { throw HerdrTopologyError.invalidPlan }
    let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
    return try Self(
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      codeDirectoryHashSHA256: SHA256.hash(data: unique)
        .map { String(format: "%02x", $0) }.joined(),
      designatedRequirement: requirementText as String
    )
  }
}

struct HerdrProcessExecutableIdentity: Codable, Equatable, Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let contentSHA256: String
  let codeIdentity: HerdrExecutableCodeIdentity

  init(
    path: String,
    device: UInt64,
    inode: UInt64,
    contentSHA256: String,
    codeIdentity: HerdrExecutableCodeIdentity
  ) throws {
    guard path.hasPrefix("/"), path.utf8.count <= 4_096,
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      device > 0, inode > 0,
      GitHubInputValidation.validSHA256(contentSHA256)
    else { throw HerdrTopologyError.invalidPlan }
    self.path = path
    self.device = device
    self.inode = inode
    self.contentSHA256 = contentSHA256
    self.codeIdentity = codeIdentity
  }

  init(path: String, device: UInt64, inode: UInt64) throws {
    let executable = try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: path, isDirectory: false)
    )
    let data = try Data(contentsOf: executable, options: [.mappedIfSafe])
    try self.init(
      path: executable.path,
      device: device,
      inode: inode,
      contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      codeIdentity: HerdrExecutableCodeIdentity.inspectStatic(at: executable)
    )
  }
}

struct HerdrInspectedProcessAuthority: Equatable, Sendable {
  let process: HerdrHostProcessIdentity
  let executable: HerdrProcessExecutableIdentity
}

enum HerdrProcessAuthorityInspector {
  private static let maximumExecutableBytes = 512 * 1_024 * 1_024

  static func inspect(processID: Int32) throws -> HerdrInspectedProcessAuthority {
    let process = try processIdentity(processID)
    let executable = try processExecutableURL(processID)
    let mapped = try mappedExecutableVnode(processID: processID, executable: executable)
    let contentSHA256 = try executableSHA256(executable, expectedVnode: mapped)
    let codeIdentity = try HerdrExecutableCodeIdentity.inspectRunning(
      processID: processID,
      executable: executable
    )
    guard try processIdentity(processID) == process,
      try processExecutableURL(processID) == executable,
      try mappedExecutableVnode(processID: processID, executable: executable) == mapped
    else { throw HerdrTopologyError.invalidPlan }
    return HerdrInspectedProcessAuthority(
      process: process,
      executable: try HerdrProcessExecutableIdentity(
        path: executable.path,
        device: mapped.device,
        inode: mapped.inode,
        contentSHA256: contentSHA256,
        codeIdentity: codeIdentity
      )
    )
  }

  private static func processIdentity(_ processID: Int32) throws -> HerdrHostProcessIdentity {
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
    else { throw HerdrTopologyError.invalidPlan }
    return try HerdrHostProcessIdentity(
      processID: processID,
      startSeconds: information.pbi_start_tvsec,
      startMicroseconds: information.pbi_start_tvusec
    )
  }

  private static func processExecutableURL(_ processID: Int32) throws -> URL {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_pidpath(processID, &buffer, UInt32(buffer.count))
    guard count > 0 else { throw HerdrTopologyError.invalidPlan }
    let end = buffer.firstIndex(of: 0) ?? Int(count)
    let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: path, isDirectory: false)
    )
  }

  private static func mappedExecutableVnode(
    processID: Int32,
    executable: URL
  ) throws -> (device: UInt64, inode: UInt64) {
    var address: UInt64 = 0
    for _ in 0..<4_096 {
      var region = proc_regionwithpathinfo()
      let count = withUnsafeMutablePointer(to: &region) { pointer in
        proc_pidinfo(
          processID,
          PROC_PIDREGIONPATHINFO,
          address,
          pointer,
          Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        )
      }
      guard count == MemoryLayout<proc_regionwithpathinfo>.size else { break }
      let information = region.prp_prinfo
      let next = information.pri_address.addingReportingOverflow(information.pri_size)
      guard !next.overflow, next.partialValue > address else { break }
      address = next.partialValue
      guard information.pri_protection & 0x04 != 0 else { continue }
      let path = withUnsafePointer(to: &region.prp_vip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      guard !path.isEmpty,
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == executable
      else { continue }
      let vnode = region.prp_vip.vip_vi.vi_stat
      guard vnode.vst_dev > 0, vnode.vst_ino > 0 else { break }
      return (UInt64(vnode.vst_dev), vnode.vst_ino)
    }
    throw HerdrTopologyError.invalidPlan
  }

  private static func executableSHA256(
    _ executable: URL,
    expectedVnode: (device: UInt64, inode: UInt64)
  ) throws -> String {
    let descriptor = Darwin.open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HerdrTopologyError.invalidPlan }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      UInt64(before.st_dev) == expectedVnode.device,
      before.st_ino == expectedVnode.inode,
      before.st_nlink == 1,
      before.st_size > 0,
      before.st_size <= maximumExecutableBytes
    else { throw HerdrTopologyError.invalidPlan }
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
        throw HerdrTopologyError.invalidPlan
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_mode == after.st_mode,
      before.st_uid == after.st_uid,
      before.st_nlink == after.st_nlink,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw HerdrTopologyError.invalidPlan }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct HerdrRoleHostReplacementPayload: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let canaryAuthorizationSHA256: String
  let maximumCommentParts: Int
  let recoveryEvidenceSHA256: String
  let retryEvidenceSHA256: String
  let replacementEvidenceSHA256: String
  let replacementAuthorizationSHA256: String
  let incidentAuditSHA256: String
  let repositoryID: String
  let jobID: String
  let generation: Int
  let runID: String
  let failedLaunchAttemptID: String
  let plannedLaunchAttemptID: String
  let predecessorRoleHostID: String
  let predecessorProcessID: Int32
  let predecessorStartSeconds: UInt64
  let predecessorStartMicroseconds: UInt64
  let predecessorBootstrapDescriptorSHA256: String
  let hostExecutableSHA256: String
  let hostExecutableDevice: UInt64
  let hostExecutableInode: UInt64
  let workspaceID: String
  let tabID: String
  let predecessorPaneID: String
  let predecessorTerminalID: String
  let replacementRoleHostID: String
  let replacementBootstrapDescriptorSHA256: String
  let credentialEvidenceSHA256: String
  let q4Binding: JobCanaryRoleHostReplacementQ4Binding
  let anchorRoleHostID: String
  let anchorPaneID: String
  let anchorTerminalID: String
  let queueSequence: Int
  let agentSource: String
  let metadataSource: String
  let alias: String
  let reportSequence: UInt64
  let tokens: [String: String]

  func validate() throws {
    do {
      try q4Binding.validate()
    } catch {
      throw HerdrTopologyError.invalidPlan
    }
    let runtimeIDs = [
      repositoryID, jobID, runID, failedLaunchAttemptID, plannedLaunchAttemptID,
      predecessorRoleHostID, replacementRoleHostID, anchorRoleHostID,
    ]
    let hashes = [
      canaryAuthorizationSHA256, recoveryEvidenceSHA256, retryEvidenceSHA256,
      replacementEvidenceSHA256, replacementAuthorizationSHA256,
      incidentAuditSHA256, predecessorBootstrapDescriptorSHA256, hostExecutableSHA256,
      replacementBootstrapDescriptorSHA256, credentialEvidenceSHA256,
    ]
    guard schemaVersion == 2,
      maximumCommentParts == 8,
      runtimeIDs.allSatisfy({ $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil }),
      hashes.allSatisfy(GitHubInputValidation.validSHA256),
      predecessorRoleHostID != replacementRoleHostID,
      generation > 0,
      predecessorProcessID > 0,
      hostExecutableDevice > 0,
      hostExecutableInode > 0,
      predecessorStartMicroseconds < 1_000_000,
      [
        workspaceID, tabID, predecessorPaneID, predecessorTerminalID, anchorPaneID,
        anchorTerminalID,
      ].allSatisfy(Self.validOpaqueID),
      predecessorPaneID != anchorPaneID,
      predecessorTerminalID != anchorTerminalID,
      queueSequence == 4,
      agentSource == "jidoka:replacement-host",
      metadataSource == "jidoka:replacement-coordination",
      alias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      reportSequence == 1,
      (1...16).contains(tokens.count),
      tokens.allSatisfy({ key, value in
        key.wholeMatch(of: /^[A-Za-z0-9_-]{1,32}$/) != nil
          && !value.isEmpty && value.utf8.count <= 256
          && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      })
    else { throw HerdrTopologyError.invalidPlan }
  }

  var payloadSHA256: String {
    get throws {
      try validate()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return GitHubMarkerCodec.sha256(try encoder.encode(self))
    }
  }

  private static func validOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct HerdrRoleHostReplacementAttribution: Codable, Equatable, Sendable {
  let predecessorRoleHostID: String
  let replacementRoleHostID: String
  let workspaceID: String
  let tabID: String
  let paneID: String
  let terminalID: String
  let processID: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let hostExecutableSHA256: String
  let hostExecutableDevice: UInt64
  let hostExecutableInode: UInt64
  let agent: String
  let alias: String
  let agentSessionAbsent: Bool
  let paneRevision: UInt64
  let agentStateChangeSequence: UInt64
  let tokensSHA256: String
  let incidentAuditSHA256: String
  let replacementEvidenceSHA256: String
  let replacementAuthorizationSHA256: String
  let credentialEvidenceSHA256: String
  let q4Binding: JobCanaryRoleHostReplacementQ4Binding

  init(
    predecessorRoleHostID: String,
    replacementRoleHostID: String,
    workspaceID: String,
    tabID: String,
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity,
    executableIdentity: HerdrProcessExecutableIdentity,
    hostExecutableSHA256: String,
    alias: String,
    paneRevision: UInt64,
    agentStateChangeSequence: UInt64,
    tokensSHA256: String,
    incidentAuditSHA256: String,
    replacementEvidenceSHA256: String,
    replacementAuthorizationSHA256: String,
    credentialEvidenceSHA256: String,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding
  ) throws {
    guard predecessorRoleHostID != replacementRoleHostID,
      [predecessorRoleHostID, replacementRoleHostID].allSatisfy({
        $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil
      }),
      [workspaceID, tabID, paneID, terminalID].allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 128
          && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      }),
      executableIdentity.device > 0, executableIdentity.inode > 0,
      [
        hostExecutableSHA256, tokensSHA256, incidentAuditSHA256,
        replacementEvidenceSHA256, replacementAuthorizationSHA256,
        credentialEvidenceSHA256,
      ]
      .allSatisfy(GitHubInputValidation.validSHA256),
      alias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      paneRevision > 0, agentStateChangeSequence > 0
    else { throw HerdrTopologyError.invalidPlan }
    do {
      try q4Binding.validate()
    } catch {
      throw HerdrTopologyError.invalidPlan
    }
    self.predecessorRoleHostID = predecessorRoleHostID
    self.replacementRoleHostID = replacementRoleHostID
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.paneID = paneID
    self.terminalID = terminalID
    processID = processIdentity.processID
    startSeconds = processIdentity.startSeconds
    startMicroseconds = processIdentity.startMicroseconds
    self.hostExecutableSHA256 = hostExecutableSHA256
    hostExecutableDevice = executableIdentity.device
    hostExecutableInode = executableIdentity.inode
    agent = "pi"
    self.alias = alias
    agentSessionAbsent = true
    self.paneRevision = paneRevision
    self.agentStateChangeSequence = agentStateChangeSequence
    self.tokensSHA256 = tokensSHA256
    self.incidentAuditSHA256 = incidentAuditSHA256
    self.replacementEvidenceSHA256 = replacementEvidenceSHA256
    self.replacementAuthorizationSHA256 = replacementAuthorizationSHA256
    self.credentialEvidenceSHA256 = credentialEvidenceSHA256
    self.q4Binding = q4Binding
  }

  init(
    payload: HerdrRoleHostReplacementPayload,
    processIdentity: HerdrHostProcessIdentity,
    executableIdentity: HerdrProcessExecutableIdentity,
    evidence: HerdrAgentAuthorityPrimeEvidence
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let tokensSHA256 = GitHubMarkerCodec.sha256(try encoder.encode(payload.tokens))
    guard executableIdentity.path.hasPrefix("/"),
      executableIdentity.device == payload.hostExecutableDevice,
      executableIdentity.inode == payload.hostExecutableInode,
      evidence.pane.workspaceID == payload.workspaceID,
      evidence.pane.tabID == payload.tabID,
      evidence.pane.agent == "pi",
      evidence.pane.agentSession == nil,
      evidence.pane.tokens == payload.tokens,
      evidence.agent.paneID == evidence.pane.paneID,
      evidence.agent.terminalID == evidence.pane.terminalID,
      evidence.agent.name == payload.alias,
      evidence.agent.stateChangeSequence == payload.reportSequence
    else { throw HerdrTopologyError.invalidResponse }
    predecessorRoleHostID = payload.predecessorRoleHostID
    replacementRoleHostID = payload.replacementRoleHostID
    workspaceID = payload.workspaceID
    tabID = payload.tabID
    paneID = evidence.pane.paneID
    terminalID = evidence.pane.terminalID
    processID = processIdentity.processID
    startSeconds = processIdentity.startSeconds
    startMicroseconds = processIdentity.startMicroseconds
    hostExecutableSHA256 = payload.hostExecutableSHA256
    hostExecutableDevice = executableIdentity.device
    hostExecutableInode = executableIdentity.inode
    agent = "pi"
    alias = payload.alias
    agentSessionAbsent = true
    paneRevision = evidence.pane.revision
    agentStateChangeSequence = evidence.agent.stateChangeSequence
    self.tokensSHA256 = tokensSHA256
    incidentAuditSHA256 = payload.incidentAuditSHA256
    replacementEvidenceSHA256 = payload.replacementEvidenceSHA256
    replacementAuthorizationSHA256 = payload.replacementAuthorizationSHA256
    credentialEvidenceSHA256 = payload.credentialEvidenceSHA256
    q4Binding = payload.q4Binding
  }
}

struct HerdrPaneProcessInfoParameters: Codable, Equatable, Sendable {
  let paneID: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
  }
}

struct HerdrPaneProcessSnapshot: Codable, Equatable, Sendable {
  let processID: UInt32
  let name: String
  let arguments: [String]?
  let argumentZero: String?
  let commandLine: String?
  let workingDirectory: String?

  private enum CodingKeys: String, CodingKey {
    case processID = "pid"
    case name
    case arguments = "argv"
    case argumentZero = "argv0"
    case commandLine = "cmdline"
    case workingDirectory = "cwd"
  }
}

struct HerdrPaneProcessInfo: Codable, Equatable, Sendable {
  let paneID: String
  let shellProcessID: UInt32?
  let foregroundProcessGroupID: UInt32?
  let foregroundProcesses: [HerdrPaneProcessSnapshot]
  let tty: String?

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case shellProcessID = "shell_pid"
    case foregroundProcessGroupID = "foreground_process_group_id"
    case foregroundProcesses = "foreground_processes"
    case tty
  }
}

struct HerdrPaneProcessInfoResult: Codable, Equatable, Sendable {
  let type: String
  let processInfo: HerdrPaneProcessInfo

  private enum CodingKeys: String, CodingKey {
    case type
    case processInfo = "process_info"
  }
}

struct HerdrPaneTargetParameters: Codable, Equatable, Sendable {
  let paneID: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
  }
}

struct HerdrPaneSplitParameters: Codable, Equatable, Sendable {
  let direction: HerdrSplitDirection
  let ratio: Double?
  let targetPaneID: String?
  let workspaceID: String?
  let workingDirectory: String?
  let environment: [String: String]
  let focus: Bool

  private enum CodingKeys: String, CodingKey {
    case direction
    case ratio
    case targetPaneID = "target_pane_id"
    case workspaceID = "workspace_id"
    case workingDirectory = "cwd"
    case environment = "env"
    case focus
  }
}

struct HerdrPaneSendTextParameters: Codable, Equatable, Sendable {
  let paneID: String
  let text: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case text
  }
}

struct HerdrPaneSendKeysParameters: Codable, Equatable, Sendable {
  let paneID: String
  let keys: [String]

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case keys
  }
}

struct HerdrPaneCreatedResult: Codable, Equatable, Sendable {
  let type: String
  let pane: HerdrPaneSnapshot
}

struct HerdrReplacementRoleHostLaunch: Equatable, Sendable {
  let targetPaneID: String
  let workspaceID: String
  let workingDirectory: URL
  let hostExecutable: URL
  let hostExecutableSHA256: String
  let descriptorRoot: URL
  let roleHostID: String

  init(
    targetPaneID: String,
    workspaceID: String,
    workingDirectory: URL,
    hostExecutable: URL,
    hostExecutableSHA256: String,
    descriptorRoot: URL,
    roleHostID: String
  ) throws {
    guard Self.validOpaqueID(targetPaneID), Self.validOpaqueID(workspaceID),
      roleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      GitHubInputValidation.validSHA256(hostExecutableSHA256),
      Self.validPathCharacters(workingDirectory.path),
      Self.validPathCharacters(hostExecutable.path),
      Self.validPathCharacters(descriptorRoot.path),
      try PiTUIFileProtocol.safeRegularFile(hostExecutable),
      try PiTUIFileProtocol.safePrivateDirectory(descriptorRoot)
    else { throw HerdrTopologyError.invalidPlan }
    let canonicalWorkingDirectory = try PiTUIFileProtocol.canonicalExistingURL(
      workingDirectory
    )
    let canonicalHostExecutable = try PiTUIFileProtocol.canonicalExistingURL(hostExecutable)
    let canonicalDescriptorRoot = try PiTUIFileProtocol.canonicalExistingURL(descriptorRoot)
    guard Self.regularPathWithoutSymlink(workingDirectory, directory: true),
      Self.regularPathWithoutSymlink(hostExecutable, directory: false),
      Self.regularPathWithoutSymlink(descriptorRoot, directory: true),
      try Self.executableSHA256(canonicalHostExecutable) == hostExecutableSHA256
    else { throw HerdrTopologyError.invalidPlan }
    self.targetPaneID = targetPaneID
    self.workspaceID = workspaceID
    self.workingDirectory = canonicalWorkingDirectory
    self.hostExecutable = canonicalHostExecutable
    self.hostExecutableSHA256 = hostExecutableSHA256
    self.descriptorRoot = canonicalDescriptorRoot
    self.roleHostID = roleHostID
  }

  func shellCommand(
    pane: HerdrPaneSnapshot,
    socketPath: String
  ) throws -> String {
    guard pane.paneID != targetPaneID,
      pane.workspaceID == workspaceID,
      Self.validOpaqueID(pane.paneID), Self.validOpaqueID(pane.tabID),
      Self.validOpaqueID(pane.terminalID),
      Self.validPathCharacters(socketPath), socketPath.hasPrefix("/"),
      try Self.executableSHA256(hostExecutable) == hostExecutableSHA256
    else { throw HerdrTopologyError.invalidPlan }
    let hostArguments = [
      "/usr/bin/env",
      "-i",
      "HOME=/var/empty",
      "PATH=/usr/bin:/bin",
      "TMPDIR=/tmp",
      "HERDR_PANE_ID=\(pane.paneID)",
      "HERDR_SOCKET_PATH=\(socketPath)",
      "HERDR_TAB_ID=\(pane.tabID)",
      "HERDR_WORKSPACE_ID=\(pane.workspaceID)",
      "JIDOKA_CODE_HERDR_RUN_ROOT=\(descriptorRoot.path)",
      hostExecutable.path,
      "--role-host-id",
      roleHostID,
    ]
    let arguments =
      [
        "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "/bin/sh", "-c", "exec \"$@\"",
        "jidoka-role-host",
      ] + hostArguments
    return arguments.map(Self.quotePOSIXArgument).joined(separator: " ")
  }

  private static func quotePOSIXArgument(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func executableSHA256(_ executable: URL) throws -> String {
    GitHubMarkerCodec.sha256(
      try Data(contentsOf: executable, options: [.mappedIfSafe])
    )
  }

  private static func regularPathWithoutSymlink(
    _ url: URL,
    directory: Bool
  ) -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/") else { return false }
    var value = stat()
    guard lstat(url.path, &value) == 0 else { return false }
    return value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
  }

  private static func validOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validPathCharacters(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct HerdrAgentRenameParameters: Codable, Equatable, Sendable {
  let target: String
  let name: String?
}

struct HerdrOKResult: Codable, Equatable, Sendable {
  let type: String
}

struct HerdrAgentInfoResult: Codable, Equatable, Sendable {
  let type: String
  let agent: HerdrAgentSnapshot
}

struct HerdrTopologyFocus: Equatable, Sendable {
  let workspaceID: String?
  let tabID: String?
  let paneID: String?

  init(snapshot: HerdrSessionSnapshot) {
    workspaceID = snapshot.focusedWorkspaceID
    tabID = snapshot.focusedTabID
    paneID = snapshot.focusedPaneID
  }
}

enum HerdrHostLaunchKind: Equatable, Sendable {
  case oneShot
  case roleHost
}

struct HerdrHostLaunchPlan: Equatable, Sendable {
  private(set) var kind: HerdrHostLaunchKind
  let role: String
  let paneLabel: String
  let runID: String
  let launchAttemptID: String
  let agentAlias: String
  let hostExecutable: URL
  let descriptorRoot: URL
  let workingDirectory: URL

  init(
    role: String,
    paneLabel: String,
    runID: String,
    launchAttemptID: String,
    agentAlias: String,
    hostExecutable: URL,
    descriptorRoot: URL,
    workingDirectory: URL
  ) throws {
    guard role.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      paneLabel.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      runID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      launchAttemptID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      agentAlias.wholeMatch(of: /^[a-z][a-z0-9_-]{0,31}$/) != nil,
      hostExecutable.isFileURL,
      hostExecutable.path.hasPrefix("/"),
      hostExecutable.standardizedFileURL.path == hostExecutable.path,
      hostExecutable.resolvingSymlinksInPath().path == hostExecutable.path,
      descriptorRoot.isFileURL,
      descriptorRoot.path.hasPrefix("/"),
      descriptorRoot.standardizedFileURL.path == descriptorRoot.path,
      descriptorRoot.resolvingSymlinksInPath().path == descriptorRoot.path,
      workingDirectory.isFileURL,
      workingDirectory.path.hasPrefix("/"),
      workingDirectory.standardizedFileURL.path == workingDirectory.path,
      workingDirectory.resolvingSymlinksInPath().path == workingDirectory.path
    else {
      throw HerdrTopologyError.invalidPlan
    }
    self.kind = .oneShot
    self.role = role
    self.paneLabel = paneLabel
    self.runID = runID
    self.launchAttemptID = launchAttemptID
    self.agentAlias = agentAlias
    self.hostExecutable = hostExecutable
    self.descriptorRoot = descriptorRoot
    self.workingDirectory = workingDirectory
  }

  init(
    roleHostID: String,
    role: PiWorkflowRole,
    paneLabel: String,
    agentAlias: String,
    hostExecutable: URL,
    descriptorRoot: URL,
    workingDirectory: URL
  ) throws {
    try self.init(
      role: role.rawValue,
      paneLabel: paneLabel,
      runID: roleHostID,
      launchAttemptID: roleHostID,
      agentAlias: agentAlias,
      hostExecutable: hostExecutable,
      descriptorRoot: descriptorRoot,
      workingDirectory: workingDirectory
    )
    self.kind = .roleHost
  }

  var command: [String] {
    switch kind {
    case .oneShot:
      [hostExecutable.path, "--launch-attempt-id", launchAttemptID]
    case .roleHost:
      [hostExecutable.path, "--role-host-id", launchAttemptID]
    }
  }

  var environment: [String: String] {
    ["JIDOKA_CODE_HERDR_RUN_ROOT": descriptorRoot.path]
  }
}

struct HerdrWorkspacePlan: Equatable, Sendable {
  let repositoryID: String
  let repositoryRoot: URL
  let workspaceLabel: String
  let boundWorkspaceID: String?

  init(
    repositoryID: String,
    repositoryRoot: URL,
    workspaceLabel: String,
    boundWorkspaceID: String?
  ) throws {
    guard repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...96).contains(workspaceLabel.utf8.count),
      !workspaceLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      boundWorkspaceID.map(Self.validHerdrID) ?? true,
      repositoryRoot.isFileURL,
      repositoryRoot.path.hasPrefix("/"),
      repositoryRoot.standardizedFileURL.path == repositoryRoot.path,
      repositoryRoot.resolvingSymlinksInPath().path == repositoryRoot.path
    else {
      throw HerdrTopologyError.invalidPlan
    }
    self.repositoryID = repositoryID
    self.repositoryRoot = repositoryRoot
    self.workspaceLabel = workspaceLabel
    self.boundWorkspaceID = boundWorkspaceID
  }

  private static func validHerdrID(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct HerdrWorkspaceBinding: Sendable {
  let workspaceID: String
  let handshake: HerdrHandshake
}

struct HerdrTopologyPlan: Equatable, Sendable {
  let repositoryID: String
  let repositoryRoot: URL
  let workspaceLabel: String
  let boundWorkspaceID: String?
  let jobID: String
  let generation: Int
  let tabLabel: String
  let launches: [HerdrHostLaunchPlan]

  init(
    repositoryID: String,
    repositoryRoot: URL,
    workspaceLabel: String,
    boundWorkspaceID: String?,
    jobID: String,
    generation: Int,
    tabLabel: String,
    launches: [HerdrHostLaunchPlan]
  ) throws {
    guard repositoryID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation),
      (1...96).contains(workspaceLabel.utf8.count),
      (1...96).contains(tabLabel.utf8.count),
      !workspaceLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !tabLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      boundWorkspaceID.map(Self.validHerdrID) ?? true,
      repositoryRoot.isFileURL,
      repositoryRoot.path.hasPrefix("/"),
      repositoryRoot.standardizedFileURL.path == repositoryRoot.path,
      repositoryRoot.resolvingSymlinksInPath().path == repositoryRoot.path,
      (1...8).contains(launches.count),
      Set(launches.map(\.role)).count == launches.count,
      Set(launches.map(\.paneLabel)).count == launches.count,
      Set(launches.map(\.runID)).count == launches.count,
      Set(launches.map(\.launchAttemptID)).count == launches.count,
      Set(launches.map(\.agentAlias)).count == launches.count
    else {
      throw HerdrTopologyError.invalidPlan
    }
    self.repositoryID = repositoryID
    self.repositoryRoot = repositoryRoot
    self.workspaceLabel = workspaceLabel
    self.boundWorkspaceID = boundWorkspaceID
    self.jobID = jobID
    self.generation = generation
    self.tabLabel = tabLabel
    self.launches = launches
  }

  private static func validHerdrID(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct HerdrRolePaneBinding: Codable, Equatable, Sendable {
  let role: String
  let runID: String
  let launchAttemptID: String
  let workspaceID: String
  let tabID: String
  let paneID: String
  let terminalID: String
}

struct HerdrTopologyBinding: Codable, Equatable, Sendable {
  let repositoryID: String
  let workspaceID: String
  let tabID: String
  let generation: Int
  let roles: [HerdrRolePaneBinding]
}

struct HerdrTopologyMutationIntent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case createWorkspace
    case applyLayout
    case primeAgentAuthority
    case resetAgentAuthority
    case replaceRoleHost
  }

  let mutationID: String
  let kind: Kind
  let repositoryID: String
  let jobID: String
  let generation: Int
  let payloadSHA256: String
  let socketIdentity: HerdrSocketIdentityRecord
}

struct HerdrSocketIdentityRecord: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
  let permissions: UInt16

  init(_ identity: HerdrSocketIdentity) {
    device = identity.device
    inode = identity.inode
    owner = identity.owner
    permissions = identity.permissions
  }
}

struct HerdrTopologyMutationReceipt: Codable, Equatable, Sendable {
  let mutationID: String
  let intentSHA256: String
}

struct HerdrTopologyMutationAttribution: Codable, Equatable, Sendable {
  let workspaceID: String
  let tabID: String?
  let paneIDs: [String]
}

enum HerdrTopologyStoredIntentState: String, Equatable, Sendable {
  case prepared
  case sendStarted
  case attributed
  case unknown
}

struct HerdrTopologyStoredIntent: Equatable, Sendable {
  let receipt: HerdrTopologyMutationReceipt
  let state: HerdrTopologyStoredIntentState
  let attribution: HerdrTopologyMutationAttribution?
  let failureCode: String?

  init(
    receipt: HerdrTopologyMutationReceipt,
    state: HerdrTopologyStoredIntentState,
    attribution: HerdrTopologyMutationAttribution?,
    failureCode: String? = nil
  ) {
    self.receipt = receipt
    self.state = state
    self.attribution = attribution
    self.failureCode = failureCode
  }
}

protocol HerdrTopologyIntentStoring: Sendable {
  func prepare(_ intent: HerdrTopologyMutationIntent) async throws
    -> HerdrTopologyMutationReceipt
  func markSendStarted(_ receipt: HerdrTopologyMutationReceipt) async throws
  func attribute(
    _ receipt: HerdrTopologyMutationReceipt,
    as attribution: HerdrTopologyMutationAttribution
  ) async throws
  func markUnknown(_ receipt: HerdrTopologyMutationReceipt) async throws
  func markFailedNoRemoteEffect(
    _ receipt: HerdrTopologyMutationReceipt,
    failureCode: String
  ) async throws
  func markSentAgentPrimesUnknown() async throws
  func storedIntent(
    kind: HerdrTopologyMutationIntent.Kind,
    repositoryID: String,
    jobID: String,
    generation: Int,
    payloadSHA256: String,
    socketIdentity: HerdrSocketIdentityRecord
  ) async throws -> HerdrTopologyStoredIntent?
}

extension HerdrTopologyIntentStoring {
  func markFailedNoRemoteEffect(
    _: HerdrTopologyMutationReceipt,
    failureCode _: String
  ) async throws {
    throw HerdrTopologyError.invalidPlan
  }

  func markSentAgentPrimesUnknown() async throws {}

  func storedIntent(
    kind: HerdrTopologyMutationIntent.Kind,
    repositoryID: String,
    jobID: String,
    generation: Int,
    payloadSHA256: String,
    socketIdentity: HerdrSocketIdentityRecord
  ) async throws -> HerdrTopologyStoredIntent? {
    nil
  }
}

public enum HerdrTopologyError: Error, Equatable, Sendable {
  case invalidPlan
  case incompatibleSocket
  case ambiguousWorkspace
  case workspaceIdentityMismatch
  case tabAlreadyExists
  case invalidResponse
  case focusChanged
  case mutationUnknown
  case concurrentMutation
  case bindingLost
}
