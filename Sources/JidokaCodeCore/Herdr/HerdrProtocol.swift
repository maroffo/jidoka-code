import Foundation

public enum HerdrAgentStatus: String, Codable, Equatable, Sendable {
  case idle
  case working
  case blocked
  case done
  case unknown
}

public struct HerdrCapabilities: Codable, Equatable, Sendable {
  public let liveHandoff: Bool
  public let detachedServerDaemon: Bool

  public init(liveHandoff: Bool, detachedServerDaemon: Bool) {
    self.liveHandoff = liveHandoff
    self.detachedServerDaemon = detachedServerDaemon
  }

  private enum CodingKeys: String, CodingKey {
    case liveHandoff = "live_handoff"
    case detachedServerDaemon = "detached_server_daemon"
  }
}

public struct HerdrPong: Codable, Equatable, Sendable {
  public let type: String
  public let version: String
  public let protocolVersion: Int
  public let capabilities: HerdrCapabilities

  public init(
    type: String = "pong",
    version: String,
    protocolVersion: Int,
    capabilities: HerdrCapabilities
  ) {
    self.type = type
    self.version = version
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case version
    case protocolVersion = "protocol"
    case capabilities
  }
}

public struct HerdrCompatibilityManifest: Equatable, Sendable {
  public let version: String
  public let protocolVersion: Int

  private init(version: String, protocolVersion: Int) {
    self.version = version
    self.protocolVersion = protocolVersion
  }

  public static let approved = HerdrCompatibilityManifest(
    version: "0.8.2",
    protocolVersion: 20
  )
}

public enum HerdrCompatibilityError: Error, Equatable, Sendable {
  case invalidPong
  case versionMismatch
  case protocolMismatch
  case missingLiveHandoff
  case missingDetachedServerDaemon
  case snapshotMismatch
}

public struct HerdrAgentSessionReference: Codable, Equatable, Sendable {
  public let agent: String
  public let kind: String
  public let source: String
  public let value: String

  public init(agent: String, kind: String, source: String, value: String) {
    self.agent = agent
    self.kind = kind
    self.source = source
    self.value = value
  }
}

public struct HerdrWorkspaceWorktreeSnapshot: Codable, Equatable, Sendable {
  public let repositoryKey: String
  public let repositoryName: String
  public let repositoryRoot: String
  public let checkoutPath: String
  public let isLinkedWorktree: Bool

  private enum CodingKeys: String, CodingKey {
    case repositoryKey = "repo_key"
    case repositoryName = "repo_name"
    case repositoryRoot = "repo_root"
    case checkoutPath = "checkout_path"
    case isLinkedWorktree = "is_linked_worktree"
  }
}

public struct HerdrWorkspaceSnapshot: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let activeTabID: String
  public let label: String
  public let number: Int
  public let paneCount: Int
  public let tabCount: Int
  public let focused: Bool
  public let agentStatus: HerdrAgentStatus
  public let tokens: [String: String]?
  public let worktree: HerdrWorkspaceWorktreeSnapshot?

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case activeTabID = "active_tab_id"
    case label
    case number
    case paneCount = "pane_count"
    case tabCount = "tab_count"
    case focused
    case agentStatus = "agent_status"
    case tokens
    case worktree
  }
}

public struct HerdrTabSnapshot: Codable, Equatable, Sendable {
  public let tabID: String
  public let workspaceID: String
  public let label: String
  public let number: Int
  public let paneCount: Int
  public let focused: Bool
  public let agentStatus: HerdrAgentStatus

  private enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
    case workspaceID = "workspace_id"
    case label
    case number
    case paneCount = "pane_count"
    case focused
    case agentStatus = "agent_status"
  }
}

public struct HerdrPaneSnapshot: Codable, Equatable, Sendable {
  public let paneID: String
  public let terminalID: String
  public let workspaceID: String
  public let tabID: String
  public let revision: UInt64
  public let focused: Bool
  public let agentStatus: HerdrAgentStatus
  public let cwd: String?
  public let foregroundCWD: String?
  public let label: String?
  public let agent: String?
  public let displayAgent: String?
  public let title: String?
  public let stateLabels: [String: String]?
  public let tokens: [String: String]?
  public let agentSession: HerdrAgentSessionReference?

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case terminalID = "terminal_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case revision
    case focused
    case agentStatus = "agent_status"
    case cwd
    case foregroundCWD = "foreground_cwd"
    case label
    case agent
    case displayAgent = "display_agent"
    case title
    case stateLabels = "state_labels"
    case tokens
    case agentSession = "agent_session"
  }
}

public struct HerdrAgentSnapshot: Codable, Equatable, Sendable {
  public let agent: String
  public let name: String?
  public let paneID: String
  public let terminalID: String
  public let workspaceID: String
  public let tabID: String
  public let revision: UInt64
  public let stateChangeSequence: UInt64
  public let focused: Bool
  public let agentStatus: HerdrAgentStatus
  public let cwd: String?
  public let foregroundCWD: String?
  public let screenDetectionSkipped: Bool?
  public let displayAgent: String?
  public let title: String?
  public let tokens: [String: String]?
  public let agentSession: HerdrAgentSessionReference?

  private enum CodingKeys: String, CodingKey {
    case agent
    case name
    case paneID = "pane_id"
    case terminalID = "terminal_id"
    case workspaceID = "workspace_id"
    case tabID = "tab_id"
    case revision
    case stateChangeSequence = "state_change_seq"
    case focused
    case agentStatus = "agent_status"
    case cwd
    case foregroundCWD = "foreground_cwd"
    case screenDetectionSkipped = "screen_detection_skipped"
    case displayAgent = "display_agent"
    case title
    case tokens
    case agentSession = "agent_session"
  }
}

public struct HerdrSessionSnapshot: Codable, Equatable, Sendable {
  public let version: String
  public let protocolVersion: Int
  public let focusedWorkspaceID: String?
  public let focusedTabID: String?
  public let focusedPaneID: String?
  public let workspaces: [HerdrWorkspaceSnapshot]
  public let tabs: [HerdrTabSnapshot]
  public let panes: [HerdrPaneSnapshot]
  public let agents: [HerdrAgentSnapshot]

  private enum CodingKeys: String, CodingKey {
    case version
    case protocolVersion = "protocol"
    case focusedWorkspaceID = "focused_workspace_id"
    case focusedTabID = "focused_tab_id"
    case focusedPaneID = "focused_pane_id"
    case workspaces
    case tabs
    case panes
    case agents
  }
}

public struct HerdrSessionSnapshotResult: Codable, Equatable, Sendable {
  public let type: String
  public let snapshot: HerdrSessionSnapshot

  public init(type: String = "session_snapshot", snapshot: HerdrSessionSnapshot) {
    self.type = type
    self.snapshot = snapshot
  }
}

public struct HerdrHandshake: Equatable, Sendable {
  public let pong: HerdrPong
  public let snapshot: HerdrSessionSnapshot
  public let socketIdentity: HerdrSocketIdentity
}
