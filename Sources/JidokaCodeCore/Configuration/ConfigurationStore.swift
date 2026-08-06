import Foundation

public struct RepositoryConfiguration: Equatable, Sendable {
  public let id: UUID
  public let nodeID: String
  public let owner: String
  public let name: String
  public let defaultBranch: String
  public let reviewEnabled: Bool
  public let triageEnabled: Bool
  public let implementationEnabled: Bool
  public let enabled: Bool

  public init(
    id: UUID,
    nodeID: String,
    owner: String,
    name: String,
    defaultBranch: String,
    reviewEnabled: Bool,
    triageEnabled: Bool,
    implementationEnabled: Bool,
    enabled: Bool
  ) {
    self.id = id
    self.nodeID = nodeID
    self.owner = owner
    self.name = name
    self.defaultBranch = defaultBranch
    self.reviewEnabled = reviewEnabled
    self.triageEnabled = triageEnabled
    self.implementationEnabled = implementationEnabled
    self.enabled = enabled
  }
}

public enum ModelProfileRole: String, CaseIterable, Codable, Sendable {
  case review
  case triage
  case planning
  case orchestration
}

public enum ModelThinkingLevel: String, CaseIterable, Codable, Sendable {
  case off
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
}

public struct ModelProfileConfiguration: Equatable, Sendable {
  public let role: ModelProfileRole
  public let provider: String
  public let model: String
  public let thinking: ModelThinkingLevel

  public init(
    role: ModelProfileRole,
    provider: String,
    model: String,
    thinking: ModelThinkingLevel
  ) {
    self.role = role
    self.provider = provider
    self.model = model
    self.thinking = thinking
  }
}

public struct AppConfiguration: Equatable, Sendable {
  public let maxConcurrency: Int
  public let paused: Bool
}

public struct ConfigurationSnapshot: Equatable, Sendable {
  public let repositories: [RepositoryConfiguration]
  public let profiles: [ModelProfileConfiguration]
  public let app: AppConfiguration
}

public enum ConfigurationStoreError: Error, Equatable, Sendable {
  case invalidNodeID
  case invalidOwner
  case invalidRepositoryName
  case invalidDefaultBranch
  case invalidProvider
  case invalidModel
  case credentialLikeValue
  case invalidMaxConcurrency
  case decode(String)
}

public actor ConfigurationStore {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  public func upsertRepository(
    _ repository: RepositoryConfiguration,
    now: Date
  ) async throws {
    try Self.validate(repository)
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, review_enabled,
        triage_enabled, implementation_enabled, enabled, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        node_id = excluded.node_id,
        owner = excluded.owner,
        name = excluded.name,
        default_branch = excluded.default_branch,
        review_enabled = excluded.review_enabled,
        triage_enabled = excluded.triage_enabled,
        implementation_enabled = excluded.implementation_enabled,
        enabled = excluded.enabled,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(repository.id.uuidString.lowercased()),
        .text(repository.nodeID),
        .text(repository.owner),
        .text(repository.name),
        .text(repository.defaultBranch),
        .integer(repository.reviewEnabled ? 1 : 0),
        .integer(repository.triageEnabled ? 1 : 0),
        .integer(repository.implementationEnabled ? 1 : 0),
        .integer(repository.enabled ? 1 : 0),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  public func repository(id: UUID) async throws -> RepositoryConfiguration? {
    try await database.query(
      "SELECT * FROM repositories WHERE id = ?",
      bindings: [.text(id.uuidString.lowercased())]
    ).first.map(Self.decodeRepository)
  }

  public func repositories() async throws -> [RepositoryConfiguration] {
    try await database.query(
      "SELECT * FROM repositories ORDER BY owner, name"
    ).map(Self.decodeRepository)
  }

  public func setProfile(
    _ profile: ModelProfileConfiguration,
    now: Date
  ) async throws {
    try Self.validate(profile)
    try await database.execute(
      """
      INSERT INTO model_profiles(role, provider, model, thinking, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(role) DO UPDATE SET
        provider = excluded.provider,
        model = excluded.model,
        thinking = excluded.thinking,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(profile.role.rawValue),
        .text(profile.provider),
        .text(profile.model),
        .text(profile.thinking.rawValue),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  public func profiles() async throws -> [ModelProfileConfiguration] {
    let decoded = try await database.query(
      "SELECT * FROM model_profiles ORDER BY role"
    ).map(Self.decodeProfile)
    return decoded.sorted {
      Self.roleOrder($0.role) < Self.roleOrder($1.role)
    }
  }

  public func setMaxConcurrency(_ value: Int, now: Date) async throws {
    guard (1...8).contains(value) else {
      throw ConfigurationStoreError.invalidMaxConcurrency
    }
    try await database.execute(
      "UPDATE app_settings SET max_concurrency = ?, updated_at = ? WHERE singleton = 1",
      bindings: [
        .integer(Int64(value)), .real(now.timeIntervalSince1970),
      ]
    )
  }

  public func setPaused(_ paused: Bool, now: Date) async throws {
    try await database.execute(
      "UPDATE app_settings SET paused = ?, updated_at = ? WHERE singleton = 1",
      bindings: [
        .integer(paused ? 1 : 0), .real(now.timeIntervalSince1970),
      ]
    )
  }

  public func appConfiguration() async throws -> AppConfiguration {
    guard
      let row = try await database.query(
        "SELECT max_concurrency, paused FROM app_settings WHERE singleton = 1"
      ).first
    else {
      throw ConfigurationStoreError.decode("app settings are absent")
    }
    return AppConfiguration(
      maxConcurrency: Int(try Self.integer(row, "max_concurrency")),
      paused: try Self.integer(row, "paused") == 1
    )
  }

  public func snapshot() async throws -> ConfigurationSnapshot {
    try await database.transaction { database in
      let repositories = try database.query(
        "SELECT * FROM repositories ORDER BY owner, name"
      ).map(Self.decodeRepository)
      let profiles = try database.query(
        "SELECT * FROM model_profiles ORDER BY role"
      ).map(Self.decodeProfile).sorted {
        Self.roleOrder($0.role) < Self.roleOrder($1.role)
      }
      guard
        let row = try database.query(
          "SELECT max_concurrency, paused FROM app_settings WHERE singleton = 1"
        ).first
      else {
        throw ConfigurationStoreError.decode("app settings are absent")
      }
      return ConfigurationSnapshot(
        repositories: repositories,
        profiles: profiles,
        app: AppConfiguration(
          maxConcurrency: Int(try Self.integer(row, "max_concurrency")),
          paused: try Self.integer(row, "paused") == 1
        )
      )
    }
  }

  private static func validate(_ repository: RepositoryConfiguration) throws {
    guard validComponent(repository.nodeID, maximum: 200) else {
      throw ConfigurationStoreError.invalidNodeID
    }
    guard validOwner(repository.owner) else {
      throw ConfigurationStoreError.invalidOwner
    }
    guard validRepositoryName(repository.name) else {
      throw ConfigurationStoreError.invalidRepositoryName
    }
    guard validBranch(repository.defaultBranch) else {
      throw ConfigurationStoreError.invalidDefaultBranch
    }
  }

  private static func validate(_ profile: ModelProfileConfiguration) throws {
    if credentialLike(profile.provider) || credentialLike(profile.model) {
      throw ConfigurationStoreError.credentialLikeValue
    }
    guard validModelComponent(profile.provider, allowSlash: false) else {
      throw ConfigurationStoreError.invalidProvider
    }
    guard validModelComponent(profile.model, allowSlash: true) else {
      throw ConfigurationStoreError.invalidModel
    }
  }

  private static func validComponent(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty
      && value.count <= maximum
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validOwner(_ value: String) -> Bool {
    guard validComponent(value, maximum: 39),
      value.first != "-", value.last != "-"
    else { return false }
    return value.utf8.allSatisfy { byte in
      Self.isASCIILetterOrNumber(byte) || byte == 45
    }
  }

  private static func validRepositoryName(_ value: String) -> Bool {
    guard validComponent(value, maximum: 100), value != ".", value != ".." else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      Self.isASCIILetterOrNumber(byte) || [45, 46, 95].contains(byte)
    }
  }

  private static func validBranch(_ value: String) -> Bool {
    guard validComponent(value, maximum: 255), value != "@",
      !value.hasPrefix("/"), !value.hasSuffix("/"),
      !value.hasSuffix("."), !value.contains(".."),
      !value.contains("//"), !value.contains("@{")
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.allSatisfy({
        !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
      })
    else { return false }
    let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
    return !value.unicodeScalars.contains(where: forbidden.contains)
  }

  private static func validModelComponent(
    _ value: String,
    allowSlash: Bool
  ) -> Bool {
    guard validComponent(value, maximum: 200) else { return false }
    return value.utf8.allSatisfy { byte in
      Self.isASCIILetterOrNumber(byte)
        || [45, 46, 58, 95].contains(byte)
        || (allowSlash && byte == 47)
    }
  }

  private static func isASCIILetterOrNumber(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...90).contains(byte)
      || (97...122).contains(byte)
  }

  private static func credentialLike(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("ghp_")
      || lowered.hasPrefix("github_pat_")
      || lowered.hasPrefix("sk-")
      || lowered.hasPrefix("bearer ")
      || lowered.contains("-----begin")
  }

  private static func decodeRepository(
    _ row: SQLiteRow
  ) throws -> RepositoryConfiguration {
    RepositoryConfiguration(
      id: try uuid(row, "id"),
      nodeID: try text(row, "node_id"),
      owner: try text(row, "owner"),
      name: try text(row, "name"),
      defaultBranch: try text(row, "default_branch"),
      reviewEnabled: try integer(row, "review_enabled") == 1,
      triageEnabled: try integer(row, "triage_enabled") == 1,
      implementationEnabled: try integer(row, "implementation_enabled") == 1,
      enabled: try integer(row, "enabled") == 1
    )
  }

  private static func decodeProfile(
    _ row: SQLiteRow
  ) throws -> ModelProfileConfiguration {
    guard let role = ModelProfileRole(rawValue: try text(row, "role")),
      let thinking = ModelThinkingLevel(rawValue: try text(row, "thinking"))
    else {
      throw ConfigurationStoreError.decode("unknown profile enum")
    }
    return ModelProfileConfiguration(
      role: role,
      provider: try text(row, "provider"),
      model: try text(row, "model"),
      thinking: thinking
    )
  }

  private static func roleOrder(_ role: ModelProfileRole) -> Int {
    switch role {
    case .review: 0
    case .triage: 1
    case .planning: 2
    case .orchestration: 3
    }
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw ConfigurationStoreError.decode("expected text column \(column)")
    }
    return value
  }

  private static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw ConfigurationStoreError.decode("expected integer column \(column)")
    }
    return value
  }

  private static func uuid(_ row: SQLiteRow, _ column: String) throws -> UUID {
    let value = try text(row, column)
    guard let id = UUID(uuidString: value) else {
      throw ConfigurationStoreError.decode("expected UUID column \(column)")
    }
    return id
  }
}
