import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("SQLite durable store")
struct SQLiteStoreTests {
  @Test("empty database migrates with required pragmas and permissions")
  func emptyDatabaseMigrates() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }

    let store = try SQLiteStore(databaseURL: fixture.databaseURL)
    #expect(try await store.schemaVersion() == DatabaseSchema.migrations.last?.version)
    let pragmas = try await store.pragmas()
    #expect(pragmas.journalMode == "wal")
    #expect(pragmas.foreignKeysEnabled)
    #expect(pragmas.busyTimeoutMilliseconds == 5_000)
    #expect(store.migrationBackups.isEmpty)

    let tables = try await store.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    )
    let names = Set(
      tables.compactMap { row -> String? in
        guard case .text(let value)? = row["name"] else { return nil }
        return value
      })
    #expect(
      names.isSuperset(of: [
        "app_settings", "artifacts", "issue_claims", "job_steps",
        "job_transitions", "jobs", "model_profiles", "mutation_intents",
        "object_dispositions", "pi_runs", "reconciliation_events",
        "repositories", "repository_backoff", "repository_leases", "reviewed_revisions",
        "schema_migrations", "workspaces",
      ]))

    let databaseMode = try fileMode(fixture.databaseURL)
    let parentMode = try fileMode(fixture.root)
    #expect(databaseMode == 0o600)
    #expect(parentMode == 0o700)
    await store.close()
  }

  @Test("typed transaction commits once and rolls back on error")
  func typedTransactions() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(databaseURL: fixture.databaseURL)

    do {
      _ =
        try await store.transaction { database in
          try database.execute(
            "INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            bindings: repositoryBindings(id: "rollback")
          )
          throw TransactionFixtureError.expected
        } as Void
      Issue.record("transaction unexpectedly succeeded")
    } catch TransactionFixtureError.expected {
      // Expected.
    }
    #expect(try await store.scalarInt("SELECT COUNT(*) FROM repositories") == 0)

    let inserted: String = try await store.transaction { database in
      try database.execute(
        "INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        bindings: repositoryBindings(id: "committed")
      )
      return "committed"
    }
    #expect(inserted == "committed")
    #expect(try await store.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    try await store.execute("CREATE TABLE text_fixture(value TEXT NOT NULL) STRICT")
    let embeddedNull = "left\0right"
    try await store.execute(
      "INSERT INTO text_fixture(value) VALUES (?)",
      bindings: [.text(embeddedNull)]
    )
    #expect(try await store.scalarText("SELECT value FROM text_fixture") == embeddedNull)
    await #expect(
      throws: SQLiteStoreError.unexpectedResult("multiple SQL statements are not allowed")
    ) {
      try await store.execute(
        "CREATE TABLE first_unexpected(id INTEGER); CREATE TABLE second_unexpected(id INTEGER)"
      )
    }
    #expect(
      try await store.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('first_unexpected', 'second_unexpected')"
      ) == 0
    )
    await store.close()
  }

  @Test("irreversible upgrade creates a readable pre-migration backup")
  func migrationBackup() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let first = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: fixtureMigrations.prefix(1).map(\.self)
    )
    try await first.execute("INSERT INTO fixture(value) VALUES (?)", bindings: [.text("kept")])
    await first.close()

    let upgraded = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: fixtureMigrations
    )
    #expect(try await upgraded.schemaVersion() == 2)
    #expect(upgraded.migrationBackups.count == 1)
    let backupURL = try #require(upgraded.migrationBackups.first)
    #expect(try fileMode(backupURL) == 0o600)

    let backup = try SQLiteStore(
      databaseURL: backupURL,
      migrations: fixtureMigrations.prefix(1).map(\.self)
    )
    #expect(try await backup.schemaVersion() == 1)
    #expect(try await backup.scalarText("SELECT value FROM fixture") == "kept")
    await backup.close()
    await upgraded.close()
  }

  @Test("failed migration rolls back schema and migration version")
  func interruptedMigrationRollsBack() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let first = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: fixtureMigrations.prefix(1).map(\.self)
    )
    await first.close()

    let broken =
      fixtureMigrations + [
        SQLiteMigration(
          version: 3,
          name: "broken",
          requiresBackup: true,
          statements: [
            "CREATE TABLE must_rollback(id INTEGER PRIMARY KEY) STRICT",
            "THIS IS NOT SQL",
          ]
        )
      ]
    do {
      _ = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: broken)
      Issue.record("broken migration unexpectedly succeeded")
    } catch let error as SQLiteStoreError {
      guard case .statementFailed = error else {
        Issue.record("unexpected migration error: \(error)")
        return
      }
    }

    let reopened = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: fixtureMigrations
    )
    #expect(try await reopened.schemaVersion() == 2)
    #expect(
      try await reopened.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'must_rollback'"
      ) == 0
    )
    await reopened.close()
  }

  @Test("foreign keys and append-only triggers reject invalid writes")
  func constraintsAreEnforced() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(databaseURL: fixture.databaseURL)

    do {
      try await store.execute(
        "INSERT INTO jobs(id, repository_id, kind, object_node_id, revision_key, contract_version_used, priority, state, created_at, updated_at) VALUES ('job', 'missing', 'triage', 'object', 'revision', 'v1', 4, 'queued', 1, 1)"
      )
      Issue.record("foreign key violation unexpectedly succeeded")
    } catch let error as SQLiteStoreError {
      guard case .statementFailed = error else {
        Issue.record("unexpected foreign key error: \(error)")
        return
      }
    }

    try await insertRepositoryAndJob(store)
    try await store.execute(
      "INSERT INTO job_steps(job_id, ordinal, kind, state, completed_at) VALUES ('job', 0, 'fixture', 'completed', 1)"
    )
    do {
      try await store.execute("UPDATE job_steps SET state = 'changed' WHERE job_id = 'job'")
      Issue.record("append-only update unexpectedly succeeded")
    } catch let error as SQLiteStoreError {
      guard case .statementFailed = error else {
        Issue.record("unexpected append-only error: \(error)")
        return
      }
    }
    await #expect(throws: SQLiteStoreError.self) {
      try await store.execute("DELETE FROM schema_migrations")
    }
    #expect(try await store.schemaVersion() == DatabaseSchema.migrations.last?.version)
    await store.close()
  }

  @Test("explicit WAL checkpoint is durable and closed stores reject it")
  func checkpointAndClose() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(databaseURL: fixture.databaseURL)
    try await store.execute(
      "INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      bindings: repositoryBindings(id: "checkpoint")
    )
    let checkpoint = try await store.checkpoint()
    #expect(checkpoint.logFrameCount >= 0)
    #expect(checkpoint.checkpointedFrameCount >= 0)
    #expect(
      try await store.scalarInt(
        "SELECT COUNT(*) FROM repositories WHERE id = 'checkpoint'"
      ) == 1
    )
    await store.close()
    await #expect(throws: SQLiteStoreError.closed) {
      _ = try await store.checkpoint()
    }
  }

  @Test("explicit backup is consistent and closed stores fail closed")
  func backupAndClose() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(databaseURL: fixture.databaseURL)
    try await store.execute(
      "INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      bindings: repositoryBindings(id: "backup")
    )
    let backupURL = fixture.root.appendingPathComponent("explicit.sqlite3")
    try await store.backup(to: backupURL)

    let backup = try SQLiteStore(databaseURL: backupURL)
    #expect(try await backup.scalarInt("SELECT COUNT(*) FROM repositories") == 1)
    await backup.close()
    await store.close()

    do {
      _ = try await store.query("SELECT 1")
      Issue.record("closed store unexpectedly accepted a query")
    } catch SQLiteStoreError.closed {
      // Expected.
    }
  }

  @Test("symbolic-link database and parent paths fail closed")
  func symbolicLinksFailClosed() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let regular = fixture.root.appendingPathComponent("regular")
    try Data().write(to: regular)
    let linkedDatabase = fixture.root.appendingPathComponent("linked.sqlite3")
    try FileManager.default.createSymbolicLink(
      at: linkedDatabase,
      withDestinationURL: regular
    )
    #expect(throws: SQLiteStoreError.self) {
      _ = try SQLiteStore(databaseURL: linkedDatabase)
    }

    let realParent = fixture.root.appendingPathComponent("real-parent")
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
    let linkedParent = fixture.root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(
      at: linkedParent,
      withDestinationURL: realParent
    )
    #expect(throws: SQLiteStoreError.self) {
      _ = try SQLiteStore(databaseURL: linkedParent.appendingPathComponent("db.sqlite3"))
    }
  }
}

private enum TransactionFixtureError: Error {
  case expected
}

private let fixtureMigrations = [
  SQLiteMigration(
    version: 1,
    name: "fixture-base",
    requiresBackup: false,
    statements: ["CREATE TABLE fixture(value TEXT NOT NULL) STRICT"]
  ),
  SQLiteMigration(
    version: 2,
    name: "fixture-upgrade",
    requiresBackup: true,
    statements: ["ALTER TABLE fixture ADD COLUMN generation INTEGER NOT NULL DEFAULT 1"]
  ),
]

private final class DatabaseFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-sqlite-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func repositoryBindings(id: String) -> [SQLiteValue] {
  [
    .text(id),
    .text("node-\(id)"),
    .text("owner"),
    .text("repo-\(id)"),
    .text("main"),
    .real(1),
    .real(1),
  ]
}

private func insertRepositoryAndJob(_ store: SQLiteStore) async throws {
  try await store.execute(
    "INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at) VALUES ('repo', 'node', 'owner', 'repo', 'main', 1, 1)"
  )
  try await store.execute(
    "INSERT INTO jobs(id, repository_id, kind, object_node_id, revision_key, contract_version_used, priority, state, created_at, updated_at) VALUES ('job', 'repo', 'issueTriage', 'object', 'revision', 'v1', 4, 'queued', 1, 1)"
  )
}

private func fileMode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
