import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Persistent configuration")
struct ConfigurationStoreTests {
  @Test("repository toggles, model profiles, and app settings survive reopen")
  func persistence() async throws {
    let fixture = try ConfigurationFixture()
    defer { fixture.remove() }
    let database = try SQLiteStore(databaseURL: fixture.databaseURL)
    let store = ConfigurationStore(database: database)
    let now = Date(timeIntervalSince1970: 30_000)
    let repositoryID = UUID()

    try await store.upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "R_node",
        owner: "maroffo",
        name: "jidoka-code",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: false,
        implementationEnabled: true,
        enabled: true
      ),
      now: now
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await store.upsertRepository(
        RepositoryConfiguration(
          id: UUID(),
          nodeID: "R_other",
          owner: "MAROFFO",
          name: "JIDOKA-CODE",
          defaultBranch: "main",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true,
          enabled: true
        ),
        now: now
      )
    }
    let publicModel = [
      "openai-codex",
      ["gpt", "5.6", "sol:max"].joined(separator: "-"),
    ].joined(separator: "/")
    let profiles = [
      ModelProfileConfiguration(
        role: .review,
        provider: "openai-codex",
        model: publicModel,
        thinking: .max
      ),
      ModelProfileConfiguration(
        role: .triage,
        provider: "openai-codex",
        model: publicModel,
        thinking: .high
      ),
      ModelProfileConfiguration(
        role: .planning,
        provider: "openai-codex",
        model: publicModel,
        thinking: .max
      ),
      ModelProfileConfiguration(
        role: .orchestration,
        provider: "openai-codex",
        model: publicModel,
        thinking: .max
      ),
    ]
    for profile in profiles {
      try await store.setProfile(profile, now: now)
    }
    await #expect(throws: ConfigurationStoreError.invalidMaxConcurrency) {
      try await store.setMaxConcurrency(4, now: now)
    }
    try await store.setMaxConcurrency(1, now: now)
    try await store.setPaused(true, now: now)
    await database.close()

    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = ConfigurationStore(database: reopenedDatabase)
    let snapshot = try await reopened.snapshot()
    #expect(snapshot.repositories.count == 1)
    #expect(snapshot.repositories.first?.id == repositoryID)
    #expect(snapshot.repositories.first?.triageEnabled == false)
    #expect(snapshot.repositories.first?.implementationEnabled == true)
    #expect(snapshot.profiles == profiles)
    #expect(snapshot.app == AppConfiguration(maxConcurrency: 1, paused: true))
    await reopenedDatabase.close()
  }

  @Test("W8 settings migrate from W6 and credential replacement metadata is durable")
  func applicationSettingsMigration() async throws {
    let fixture = try ConfigurationFixture()
    defer { fixture.remove() }
    let firstMigration = try #require(DatabaseSchema.migrations.first)
    let legacy = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: [firstMigration]
    )
    let now = Date(timeIntervalSince1970: 31_000)
    let legacyConfiguration = ConfigurationStore(database: legacy)
    let legacyRepository = RepositoryConfiguration(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      nodeID: "R_legacy",
      owner: "owner",
      name: "legacy",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: false,
      implementationEnabled: false,
      enabled: true
    )
    try await legacyConfiguration.upsertRepository(legacyRepository, now: now)
    try await legacy.execute(
      "UPDATE app_settings SET max_concurrency = 4, updated_at = ? WHERE singleton = 1",
      bindings: [.real(now.timeIntervalSince1970)]
    )
    try await legacyConfiguration.setPaused(true, now: now)
    #expect(try await legacy.schemaVersion() == 1)
    await legacy.close()

    let upgraded = try SQLiteStore(databaseURL: fixture.databaseURL)
    #expect(upgraded.migrationBackups.count == 9)
    let settingsBackupURL = try #require(upgraded.migrationBackups.first)
    let herdrBackupURL = try #require(upgraded.migrationBackups.dropFirst().first)
    let commandBackupURL = upgraded.migrationBackups[2]
    let primeBackupURL = upgraded.migrationBackups[5]
    let resetBackupURL = upgraded.migrationBackups[6]
    let replacementBackupURL = upgraded.migrationBackups[7]
    let rolloutBackupURL = try #require(upgraded.migrationBackups.last)
    let settingsBackup = try SQLiteStore(
      databaseURL: settingsBackupURL,
      migrations: [firstMigration]
    )
    #expect(try await settingsBackup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    #expect(try await settingsBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    #expect(try await settingsBackup.scalarInt("SELECT max_concurrency FROM app_settings") == 4)
    #expect(try await settingsBackup.scalarInt("SELECT paused FROM app_settings") == 1)
    await settingsBackup.close()
    let herdrBackup = try SQLiteStore(
      databaseURL: herdrBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(2))
    )
    #expect(try await herdrBackup.schemaVersion() == 2)
    #expect(try await herdrBackup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    #expect(try await herdrBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    await herdrBackup.close()
    let commandBackup = try SQLiteStore(
      databaseURL: commandBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(3))
    )
    #expect(try await commandBackup.schemaVersion() == 3)
    #expect(try await commandBackup.scalarInt("SELECT COUNT(*) FROM pi_runs") == 0)
    #expect(
      try await commandBackup.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'approved_command_runs'"
      ) == 0
    )
    await commandBackup.close()
    let primeBackup = try SQLiteStore(
      databaseURL: primeBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(6))
    )
    #expect(try await primeBackup.schemaVersion() == 6)
    #expect(try await primeBackup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    #expect(try await primeBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    await primeBackup.close()
    let resetBackup = try SQLiteStore(
      databaseURL: resetBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(7))
    )
    #expect(try await resetBackup.schemaVersion() == 7)
    #expect(try await resetBackup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    #expect(try await resetBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    await resetBackup.close()
    let replacementBackup = try SQLiteStore(
      databaseURL: replacementBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(8))
    )
    #expect(try await replacementBackup.schemaVersion() == 8)
    #expect(try await replacementBackup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    #expect(try await replacementBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    await replacementBackup.close()
    let rolloutBackup = try SQLiteStore(
      databaseURL: rolloutBackupURL,
      migrations: Array(DatabaseSchema.migrations.prefix(9))
    )
    #expect(try await rolloutBackup.schemaVersion() == 9)
    #expect(try await rolloutBackup.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
    #expect(try await rolloutBackup.scalarInt("SELECT max_concurrency FROM app_settings") == 4)
    await rolloutBackup.close()

    let store = ConfigurationStore(database: upgraded)
    var snapshot = try await store.snapshot()
    #expect(Set(snapshot.profiles.map(\.role)) == Set(ModelProfileRole.allCases))
    #expect(
      snapshot.profiles.allSatisfy {
        $0.provider == "openai-codex" && $0.model == "gpt-5.6-sol" && $0.thinking == .max
      })
    #expect(snapshot.repositories == [legacyRepository])
    #expect(snapshot.app.maxConcurrency == 1)
    #expect(snapshot.app.paused)
    #expect(!snapshot.app.onboardingComplete)
    #expect(!snapshot.app.externalAutomationAcknowledged)
    #expect(!snapshot.app.providerDisclosureAcknowledged)
    #expect(snapshot.app.githubAccount == nil)
    #expect(!snapshot.app.credentialDeletionPending)
    #expect(snapshot.app.loginItemStatus == .notRegistered)

    try await store.setExternalAutomationAcknowledged(true, now: now)
    try await store.setProviderDisclosureAcknowledged(true, now: now)
    #expect(
      try await store.prepareCredentialReplacement(
        account: "octocat",
        authorID: 7,
        tokenSHA256: String(repeating: "a", count: 64),
        now: now
      ) == nil
    )
    snapshot = try await store.snapshot()
    #expect(snapshot.app.pendingGitHubAccount == "octocat")
    #expect(snapshot.app.pendingGitHubTokenSHA256 == String(repeating: "a", count: 64))
    #expect(snapshot.app.githubAccount == nil)
    try await store.commitCredentialReplacement(
      account: "octocat",
      authorID: 7,
      tokenSHA256: String(repeating: "a", count: 64),
      now: now
    )
    #expect(
      try await store.prepareCredentialReplacement(
        account: "hubot",
        authorID: 8,
        tokenSHA256: String(repeating: "b", count: 64),
        now: now
      ) == "octocat"
    )
    try await store.commitCredentialReplacement(
      account: "hubot",
      authorID: 8,
      tokenSHA256: String(repeating: "b", count: 64),
      now: now
    )
    try await store.completeCredentialCleanup(account: "octocat", now: now)
    try await store.setLoginItem(selected: true, status: .requiresApproval, now: now)
    try await store.setOnboardingComplete(true, now: now)
    await upgraded.close()

    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = try await ConfigurationStore(database: reopenedDatabase).snapshot()
    #expect(reopened.app.onboardingComplete)
    #expect(reopened.app.paused)
    #expect(reopened.app.externalAutomationAcknowledged)
    #expect(reopened.app.providerDisclosureAcknowledged)
    #expect(reopened.app.githubAccount == "hubot")
    #expect(reopened.app.githubAuthorID == 8)
    #expect(reopened.app.pendingGitHubAccount == nil)
    #expect(reopened.app.pendingGitHubTokenSHA256 == nil)
    #expect(reopened.app.previousGitHubAccount == nil)
    #expect(!reopened.app.credentialDeletionPending)
    #expect(reopened.app.loginItemSelected)
    #expect(reopened.app.loginItemStatus == .requiresApproval)
    await reopenedDatabase.close()
  }

  @Test("repository and branch validation fail closed")
  func repositoryValidation() async throws {
    let fixture = try ConfigurationFixture()
    defer { fixture.remove() }
    let database = try SQLiteStore(databaseURL: fixture.databaseURL)
    let store = ConfigurationStore(database: database)
    let base = RepositoryConfiguration(
      id: UUID(),
      nodeID: "node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )

    for repository in [
      RepositoryConfiguration(
        id: base.id, nodeID: "", owner: base.owner, name: base.name,
        defaultBranch: base.defaultBranch, reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: "-owner", name: base.name,
        defaultBranch: base.defaultBranch, reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: "ownér", name: base.name,
        defaultBranch: base.defaultBranch, reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: base.owner, name: "..",
        defaultBranch: base.defaultBranch, reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: base.owner, name: base.name,
        defaultBranch: "refs/../escape", reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: base.owner, name: base.name,
        defaultBranch: "feature/.hidden", reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: base.owner, name: base.name,
        defaultBranch: "feature/topic.lock", reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
      RepositoryConfiguration(
        id: base.id, nodeID: base.nodeID, owner: base.owner, name: base.name,
        defaultBranch: "@", reviewEnabled: true,
        triageEnabled: true, implementationEnabled: true, enabled: true),
    ] {
      await #expect(throws: ConfigurationStoreError.self) {
        try await store.upsertRepository(repository, now: Date())
      }
    }
    #expect(try await store.repositories().isEmpty)
    await database.close()
  }

  @Test("configuration schema and API reject credential-shaped values")
  func noSecretPersistence() async throws {
    let fixture = try ConfigurationFixture()
    defer { fixture.remove() }
    let database = try SQLiteStore(databaseURL: fixture.databaseURL)
    let store = ConfigurationStore(database: database)
    let sentinel = ["ghp", "this-value-must-never-reach-sqlite"]
      .joined(separator: "_")

    await #expect(throws: ConfigurationStoreError.credentialLikeValue) {
      try await store.setProfile(
        ModelProfileConfiguration(
          role: .review,
          provider: "openai-codex",
          model: sentinel,
          thinking: .high
        ),
        now: Date()
      )
    }
    let definitions = try await database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND sql IS NOT NULL"
    )
    let schema = definitions.compactMap { row -> String? in
      guard case .text(let sql)? = row["sql"] else { return nil }
      return sql.lowercased()
    }.joined(separator: "\n")
    for forbidden in ["access_token", "github_token", "authorization_header", "credential_value"] {
      #expect(!schema.contains(forbidden))
    }
    await database.close()
    let bytes = try Data(contentsOf: fixture.databaseURL)
    #expect(!bytes.contains(Data(sentinel.utf8)))
  }

  @Test("max concurrency is bounded and drives durable lease admission")
  func concurrencyIntegration() async throws {
    let fixture = try ConfigurationFixture()
    defer { fixture.remove() }
    let database = try SQLiteStore(databaseURL: fixture.databaseURL)
    let configuration = ConfigurationStore(database: database)
    await #expect(throws: ConfigurationStoreError.invalidMaxConcurrency) {
      try await configuration.setMaxConcurrency(0, now: Date())
    }
    await #expect(throws: ConfigurationStoreError.invalidMaxConcurrency) {
      try await configuration.setMaxConcurrency(9, now: Date())
    }
    await #expect(throws: ConfigurationStoreError.invalidMaxConcurrency) {
      try await configuration.setMaxConcurrency(2, now: Date())
    }
    await #expect(throws: SQLiteStoreError.self) {
      try await database.execute(
        "UPDATE app_settings SET max_concurrency = 9 WHERE singleton = 1"
      )
    }
    try await configuration.setMaxConcurrency(1, now: Date())

    let now = Date(timeIntervalSince1970: 40_000)
    let firstRepository = UUID()
    let secondRepository = UUID()
    for (id, name) in [(firstRepository, "first"), (secondRepository, "second")] {
      try await configuration.upsertRepository(
        RepositoryConfiguration(
          id: id,
          nodeID: "node-\(name)",
          owner: "owner",
          name: name,
          defaultBranch: "main",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true,
          enabled: true
        ),
        now: now
      )
    }
    let jobs = DurableJobStore(database: database)
    let first = try await createConfigurationJob(
      jobs: jobs,
      repositoryID: firstRepository,
      revision: "first",
      now: now
    )
    let second = try await createConfigurationJob(
      jobs: jobs,
      repositoryID: secondRepository,
      revision: "second",
      now: now
    )
    _ = try await jobs.transition(
      jobID: first.id,
      eventKey: "first-lease",
      event: .acquireLease,
      context: JobTransitionContext(now: now, reason: "first")
    )
    await #expect(throws: DurableJobStoreError.globalConcurrencyReached) {
      _ = try await jobs.transition(
        jobID: second.id,
        eventKey: "second-lease",
        event: .acquireLease,
        context: JobTransitionContext(now: now, reason: "second")
      )
    }
    await database.close()
  }
}

private final class ConfigurationFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-configuration-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func createConfigurationJob(
  jobs: DurableJobStore,
  repositoryID: UUID,
  revision: String,
  now: Date
) async throws -> JobRecord {
  let result = try await jobs.createJob(
    identity: LogicalJobIdentity(
      repositoryID: repositoryID,
      kind: .prReview,
      objectNodeID: "object-\(revision)",
      revisionKey: revision
    ),
    contractVersionUsed: "v1",
    priority: .prReview,
    firstStep: .review,
    now: now
  )
  guard case .created(let job) = result else {
    throw ConfigurationStoreError.decode("job unexpectedly suppressed")
  }
  return job
}
