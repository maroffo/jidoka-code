import Foundation

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

struct HerdrAgentRenameParameters: Codable, Equatable, Sendable {
  let target: String
  let name: String
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
