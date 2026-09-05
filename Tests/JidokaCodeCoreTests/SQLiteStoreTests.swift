import CryptoKit
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

  @Test("production schema upgrades through architecture role-host replacement authority")
  func productionFreshRetryMigration() async throws {
    let migration = try productionSchemaNineMigration()
    let fixture = try await PopulatedSchemaEightFixture.make()
    defer { fixture.remove() }

    let upgraded = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaNineMigrations
    )
    #expect(try await upgraded.schemaVersion() == 9)
    #expect(
      try await upgraded.scalarText(
        "SELECT name FROM schema_migrations WHERE version = 9"
      ) == migration.name
    )
    #expect(upgraded.migrationBackups.count == 1)
    let backupURLs = try migrationBackupURLs(in: fixture.root)
    #expect(backupURLs.count == 1)
    #expect(
      backupURLs.first?.lastPathComponent == upgraded.migrationBackups.first?.lastPathComponent
    )

    let preservedRows = try await applicationRows(
      in: upgraded,
      tableColumns: fixture.snapshot.tableColumns
    )
    #expect(preservedRows == fixture.snapshot.applicationRows)
    #expect(
      try await upgraded.scalarInt(
        """
        SELECT COUNT(*)
        FROM pi_run_launches AS launch
        JOIN pi_runs AS run ON run.id = launch.run_id
        JOIN herdr_role_hosts AS host ON host.id = launch.role_host_id
        WHERE run.id = ?
          AND host.id = ?
          AND launch.execution_role_host_id IS NULL
          AND launch.queue_sequence BETWEEN 1 AND 3
        """,
        bindings: [.text(schemaEightRunID), .text(schemaEightArchitectureHostID)]
      ) == 3
    )
    #expect(
      try await upgraded.scalarInt(
        "SELECT COUNT(*) FROM herdr_topology_intents WHERE state = 'unknown'"
      ) == 2
    )
    let migratedRunStore = PiRunStore(database: upgraded)
    try await migratedRunStore.invalidateRepositoryBinding(
      repositoryID: UUID(uuidString: "51000000-0000-4000-8000-000000000001")!,
      observedHandshake: schemaNineHandshake(),
      now: Date(timeIntervalSince1970: 99)
    )
    #expect(
      try await upgraded.scalarText(
        "SELECT reason FROM herdr_repository_binding_history ORDER BY id DESC LIMIT 1"
      ) == "RUNTIME_CHANGED"
    )
    #expect(
      try await upgraded.scalarInt(
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE state = 'lost'"
      ) == 4
    )
    #expect(
      try await upgraded.scalarText(
        "SELECT state FROM herdr_job_bindings WHERE job_id = (SELECT job_id FROM pi_runs WHERE id = ?)",
        bindings: [.text(schemaEightRunID)]
      ) == "lost"
    )
    try await assertDatabaseIntegrity(upgraded)

    let upgradedObjectNames = try await schemaObjectNames(in: upgraded)
    #expect(upgradedObjectNames.subtracting(fixture.snapshot.schemaObjectNames) == v9AddedObjects)
    #expect(fixture.snapshot.schemaObjectNames.subtracting(upgradedObjectNames).isEmpty)
    for expectedObject in v9AddedObjects {
      #expect(upgradedObjectNames.contains(expectedObject))
    }

    let backupURL = try #require(backupURLs.first)
    #expect(try fileMode(backupURL) == 0o600)
    let backup = try SQLiteStore(
      databaseURL: backupURL,
      migrations: schemaEightMigrations
    )
    #expect(try await backup.schemaVersion() == 8)
    #expect(try await schemaEightSnapshot(of: backup) == fixture.snapshot)
    try await assertDatabaseIntegrity(backup)
    await backup.close()
    await upgraded.close()
  }

  @Test(
    "production schema 8 to 9 rolls back after every exact migration statement",
    arguments: Array(1...76)
  )
  func productionArchitectureReplacementMigrationRollsBack(
    afterStatement completedStatementCount: Int
  ) async throws {
    let migration = try productionSchemaNineMigration()
    let fixture = try await PopulatedSchemaEightFixture.make()
    defer { fixture.remove() }
    let failingMigration = SQLiteMigration(
      version: migration.version,
      name: migration.name,
      requiresBackup: migration.requiresBackup,
      statements: Array(migration.statements.prefix(completedStatementCount)) + [
        "THIS IS THE TEST-ONLY SCHEMA 8 TO 9 FAILURE"
      ]
    )

    do {
      _ = try SQLiteStore(
        databaseURL: fixture.databaseURL,
        migrations: schemaEightMigrations + [failingMigration]
      )
      Issue.record("migration unexpectedly passed after statement \(completedStatementCount)")
    } catch let error as SQLiteStoreError {
      guard case .statementFailed = error else {
        Issue.record(
          "unexpected migration error after statement \(completedStatementCount): \(error)")
        return
      }
    }

    let backupURLs = try migrationBackupURLs(in: fixture.root)
    #expect(backupURLs.count == 1)
    let original = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaEightMigrations
    )
    #expect(try await original.schemaVersion() == 8)
    #expect(try await schemaEightSnapshot(of: original) == fixture.snapshot)
    #expect(try await schemaObjectNames(in: original).isDisjoint(with: v9AddedObjects))
    try await assertDatabaseIntegrity(original)
    await original.close()

    let backupURL = try #require(backupURLs.first)
    #expect(try fileMode(backupURL) == 0o600)
    let backup = try SQLiteStore(
      databaseURL: backupURL,
      migrations: schemaEightMigrations
    )
    #expect(try await backup.schemaVersion() == 8)
    #expect(try await schemaEightSnapshot(of: backup) == fixture.snapshot)
    #expect(try await schemaObjectNames(in: backup).isDisjoint(with: v9AddedObjects))
    try await assertDatabaseIntegrity(backup)
    await backup.close()
  }

  @Test("production schema upgrades to rollout authority without manufacturing authority")
  func productionRolloutAuthorityMigration() async throws {
    _ = try productionSchemaTenMigration()
    let fixture = try await PopulatedSchemaNineFixture.make()
    defer { fixture.remove() }

    let upgraded = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: DatabaseSchema.migrations
    )
    #expect(try await upgraded.schemaVersion() == 10)
    #expect(upgraded.migrationBackups.count == 1)
    let backupURL = try #require(upgraded.migrationBackups.first)
    #expect(backupURL.lastPathComponent.contains(".before-v10-"))
    #expect(try fileMode(backupURL) == 0o600)
    #expect(
      try await historicalRows(in: upgraded, snapshot: fixture.snapshot) == fixture.snapshot.rows)
    #expect(try await upgraded.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(try await upgraded.scalarInt("SELECT max_concurrency FROM app_settings") == 1)
    #expect(
      try await upgraded.scalarText("SELECT active_rollout_authorization_id FROM app_settings")
        == nil
    )
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0
    )
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM rollout_job_bindings") == 0
    )
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM rollout_job_input_snapshots") == 0
    )
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM rollout_effect_reservations") == 0
    )
    #expect(
      try await upgraded.scalarInt(
        "SELECT COUNT(*) FROM jobs WHERE rollout_generation != 0"
      ) == 0
    )
    try await assertDatabaseIntegrity(upgraded)
    await upgraded.close()

    let backup = try SQLiteStore(databaseURL: backupURL, migrations: schemaNineMigrations)
    #expect(try await backup.schemaVersion() == 9)
    #expect(
      try await historicalRows(in: backup, snapshot: fixture.snapshot) == fixture.snapshot.rows)
    try await assertDatabaseIntegrity(backup)
    await backup.close()

    let reopened = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: DatabaseSchema.migrations
    )
    #expect(try await reopened.schemaVersion() == 10)
    #expect(reopened.migrationBackups.isEmpty)
    #expect(try await reopened.scalarInt("SELECT paused FROM app_settings") == 1)
    await reopened.close()

    #expect(throws: SQLiteStoreError.migrationTooNew(database: 10, supported: 9)) {
      _ = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: schemaNineMigrations)
    }
  }

  @Test("a schema-10 database stamped by an unshipped migration body fails closed")
  func schemaTenStampedByAnotherBodyFailsClosed() async throws {
    let migration = try productionSchemaTenMigration()
    let fixture = try await PopulatedSchemaNineFixture.make()
    defer { fixture.remove() }

    // Exactly the shape a database carries after eb01640: version 10, the same
    // migration name, and no recorded content digest, because that binary had none.
    let unshipped = SQLiteMigration(
      version: migration.version,
      name: migration.name,
      requiresBackup: false,
      statements: ["CREATE TABLE unshipped_schema_ten_marker (id TEXT PRIMARY KEY) STRICT"]
    )
    let stamped = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaNineMigrations + [unshipped]
    )
    #expect(try await stamped.schemaVersion() == 10)
    await stamped.close()

    #expect(
      throws: SQLiteStoreError.migrationContentMismatch(
        version: 10,
        recorded: unshipped.statementsSHA256,
        expected: migration.statementsSHA256
      )
    ) {
      _ = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: DatabaseSchema.migrations)
    }

    // The refusal is read-only: no statement of the real migration 10 ran, and the
    // database is still exactly what the other body left behind.
    let untouched = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaNineMigrations + [unshipped]
    )
    #expect(
      try await untouched.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'rollout_authorizations'"
      ) == 0
    )
    #expect(
      try await untouched.scalarInt(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'unshipped_schema_ten_marker'"
      ) == 1
    )
    #expect(
      try await historicalRows(in: untouched, snapshot: fixture.snapshot) == fixture.snapshot.rows)
    await untouched.close()

    // eb01640 predates the digest column entirely: its ledger has no such column at
    // all, not a NULL in one. Reproduce that exact shape — dropping the column, not
    // blanking it — because the column's absence is what a real pre-digest database
    // presents and the guard has to read it without erroring.
    let legacy = try await PopulatedSchemaNineFixture.make()
    defer { legacy.remove() }
    let legacyStamped = try SQLiteStore(
      databaseURL: legacy.databaseURL,
      migrations: schemaNineMigrations + [unshipped]
    )
    try await dropRecordedMigrationDigestColumn(in: legacyStamped)
    #expect(
      try await legacyStamped.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('schema_migrations') WHERE name = 'statements_sha256'"
      ) == 0
    )
    await legacyStamped.close()
    #expect(
      throws: SQLiteStoreError.migrationContentMismatch(
        version: 10,
        recorded: nil,
        expected: migration.statementsSHA256
      )
    ) {
      _ = try SQLiteStore(databaseURL: legacy.databaseURL, migrations: DatabaseSchema.migrations)
    }

    // And the refusal happened before this binary wrote anything: the column it would
    // have added is still absent. Reopening with the list that created the database
    // has nothing pending, so the check itself does not add it either.
    let legacyAfter = try SQLiteStore(
      databaseURL: legacy.databaseURL,
      migrations: schemaNineMigrations + [unshipped]
    )
    #expect(
      try await legacyAfter.scalarInt(
        """
        SELECT COUNT(*) FROM pragma_table_info('schema_migrations')
        WHERE name = 'statements_sha256'
        """
      ) == 0
    )
    await legacyAfter.close()
  }

  @Test("a database this binary refuses as too new is never written to")
  func tooNewDatabaseIsNotWrittenTo() async throws {
    let fixture = try await PopulatedSchemaNineFixture.make()
    defer { fixture.remove() }
    let unshipped = SQLiteMigration(
      version: 10,
      name: "progressive-production-rollout-authority",
      requiresBackup: false,
      statements: ["CREATE TABLE unshipped_schema_ten_marker (id TEXT PRIMARY KEY) STRICT"]
    )
    let creating = schemaNineMigrations + [unshipped]
    let store = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: creating)
    try await dropRecordedMigrationDigestColumn(in: store)
    await store.close()

    // Refusing an unsupported database must not be the moment this binary first
    // writes to it: the digest column is added only after both guards have passed.
    #expect(throws: SQLiteStoreError.migrationTooNew(database: 10, supported: 9)) {
      _ = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: schemaNineMigrations)
    }
    let reopened = try SQLiteStore(databaseURL: fixture.databaseURL, migrations: creating)
    #expect(
      try await reopened.scalarInt(
        """
        SELECT COUNT(*) FROM pragma_table_info('schema_migrations')
        WHERE name = 'statements_sha256'
        """
      ) == 0
    )
    // No row comparison here: this test drops a ledger column on purpose, so the
    // fixture's own snapshot no longer describes the database. Historical row
    // preservation is pinned by the migration tests that leave the schema alone.
    await reopened.close()
  }

  @Test("applied migrations record their body digest and reopen idempotently")
  func appliedMigrationsRecordContentDigest() async throws {
    let fixture = try await PopulatedSchemaNineFixture.make()
    defer { fixture.remove() }

    // Migrations 1 through 9 shipped in binaries that had no digest column, so a real
    // schema-9 database has nine blank rows. Blank below version 10 must still migrate.
    let beforeUpgrade = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaNineMigrations
    )
    for version in 1...9 {
      try await clearRecordedMigrationDigest(in: beforeUpgrade, version: version)
    }
    #expect(
      try await beforeUpgrade.scalarInt(
        "SELECT COUNT(*) FROM schema_migrations WHERE statements_sha256 IS NULL"
      ) == 9
    )
    await beforeUpgrade.close()

    let upgraded = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: DatabaseSchema.migrations
    )
    let recorded = try await upgraded.query(
      "SELECT statements_sha256 FROM schema_migrations WHERE version = 10"
    )
    let expected = try productionSchemaTenMigration().statementsSHA256
    #expect(recorded.first?["statements_sha256"] == .text(expected))
    await upgraded.close()

    let reopened = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: DatabaseSchema.migrations
    )
    #expect(try await reopened.schemaVersion() == 10)
    #expect(reopened.migrationBackups.isEmpty)
    await reopened.close()
  }

  @Test(
    "production schema 9 to 10 rolls back after every exact migration statement",
    arguments: schemaTenStatementCuts
  )
  func productionRolloutAuthorityMigrationRollsBack(
    afterStatement completedStatementCount: Int
  ) async throws {
    let migration = try productionSchemaTenMigration()
    let fixture = try await PopulatedSchemaNineFixture.make()
    defer { fixture.remove() }
    let failingMigration = SQLiteMigration(
      version: migration.version,
      name: migration.name,
      requiresBackup: migration.requiresBackup,
      statements: Array(migration.statements.prefix(completedStatementCount)) + [
        "THIS IS THE TEST-ONLY SCHEMA 9 TO 10 FAILURE"
      ]
    )

    do {
      _ = try SQLiteStore(
        databaseURL: fixture.databaseURL,
        migrations: schemaNineMigrations + [failingMigration]
      )
      Issue.record("migration unexpectedly passed after statement \(completedStatementCount)")
    } catch let error as SQLiteStoreError {
      guard case .statementFailed = error else {
        Issue.record(
          "unexpected migration error after statement \(completedStatementCount): \(error)"
        )
        return
      }
    }

    let original = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaNineMigrations
    )
    #expect(try await original.schemaVersion() == 9)
    #expect(
      try await historicalRows(in: original, snapshot: fixture.snapshot) == fixture.snapshot.rows)
    try await assertDatabaseIntegrity(original)
    await original.close()

    let backupURLs = try migrationBackupURLs(in: fixture.root, beforeVersion: 10)
    #expect(backupURLs.count == 1)
    let backup = try SQLiteStore(
      databaseURL: try #require(backupURLs.first),
      migrations: schemaNineMigrations
    )
    #expect(try await backup.schemaVersion() == 9)
    #expect(
      try await historicalRows(in: backup, snapshot: fixture.snapshot) == fixture.snapshot.rows)
    try await assertDatabaseIntegrity(backup)
    await backup.close()
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

private let schemaEightMigrations = Array(DatabaseSchema.migrations.prefix(8))
private let schemaNineMigrations = Array(DatabaseSchema.migrations.prefix(9))
private let schemaTenStatementCuts = Array(1...91)
private let schemaEightRunID = "run-schema8-architecture"
private let schemaEightArchitectureHostID = "rolehost-schema8-architecture"
private let expectedSchemaNineMigrationDigest =
  "48201824a919a208a72eccea6a626b2a560e2cd93b0686e390e949045bbb7751"
private let expectedSchemaTenMigrationDigest =
  "04a5fdb3b2e6935a13a7418419a2aed3a3f0708e317fedf44ed34eebee659991"
// Widened when `schema_migrations` gained `statements_sha256`: the snapshot projects
// every column of every table, so one added column moves the digest. The historical
// row values themselves are unchanged and still compared row-for-row above.
private let expectedPopulatedSchemaEightDigest =
  "2974d081eb94497cacd50bb1badb19ab2f761a287812e3fc976fb5b78cc2f186"
private let v9AddedObjects: Set<String> = [
  "app_settings_generation_rollover_delete_denied",
  "app_settings_generation_rollover_insert_resume_denied",
  "herdr_generation_rollover_authorization_delete_denied",
  "herdr_generation_rollover_authorization_insert_authority",
  "herdr_generation_rollover_authorization_update_denied",
  "herdr_generation_rollover_authorizations",
  "herdr_generation_rollover_predecessor_host_immutable",
  "herdr_generation_rollover_predecessor_launch_immutable",
  "herdr_generation_rollover_predecessor_run_immutable",
  "herdr_job_binding_generation_rollover_authority",
  "herdr_ordinary_role_host_replacement_insert_collision_denied",
  "herdr_ordinary_role_host_replacement_physical_collision_denied",
  "herdr_replaced_predecessor_immutable",
  "herdr_replacement_intent_attribution_authority",
  "herdr_replacement_intent_insert_authority",
  "herdr_replacement_intent_send_authority",
  "herdr_role_host_replacement_authorization_delete_denied",
  "herdr_role_host_replacement_authorization_insert_authority",
  "herdr_role_host_replacement_authorization_update_denied",
  "herdr_role_host_replacement_authorizations",
  "herdr_replacement_role_host_delete_denied",
  "herdr_replacement_role_host_identity_immutable",
  "herdr_replacement_role_host_insert_authority",
  "herdr_replacement_role_host_state_transition",
  "herdr_replacement_role_hosts",
  "herdr_replacement_role_hosts_active_pane_idx",
  "herdr_replacement_role_hosts_active_process_idx",
  "herdr_replacement_role_hosts_active_terminal_idx",
  "herdr_role_host_initial_queue_authority",
  "herdr_role_host_replacement_candidates",
  "herdr_pi_run_rollover_delete_denied",
  "herdr_pi_run_rollover_insert_authority",
  "herdr_pi_run_rollover_update_denied",
  "herdr_pi_run_rollovers",
  "pi_run_launches_one_active_execution_host_idx",
  "pi_runs_generation_rollover_insert_authority",
  "app_settings_generation_rollover_resume_denied",
]

private struct SchemaEightSnapshot: Equatable {
  let schemaObjects: [String]
  let schemaObjectNames: Set<String>
  let tableColumns: [String: [String]]
  let applicationRows: [String: [String]]
  let digest: String
}

private struct HistoricalSchemaNineSnapshot: Equatable {
  let columns: [String: [String]]
  let rows: [String: [String]]
}

private struct PopulatedSchemaNineFixture {
  let root: URL
  let databaseURL: URL
  let snapshot: HistoricalSchemaNineSnapshot

  static func make() async throws -> Self {
    let schemaEight = try await PopulatedSchemaEightFixture.make()
    let database = try SQLiteStore(
      databaseURL: schemaEight.databaseURL,
      migrations: schemaNineMigrations
    )
    #expect(try await database.schemaVersion() == 9)
    let allColumns = try await tableColumns(in: database)
    var preservedColumns = allColumns
    preservedColumns["app_settings"] = (allColumns["app_settings"] ?? []).filter {
      !["max_concurrency", "paused", "updated_at"].contains($0)
    }
    let empty = HistoricalSchemaNineSnapshot(columns: preservedColumns, rows: [:])
    let snapshot = HistoricalSchemaNineSnapshot(
      columns: preservedColumns,
      rows: try await historicalRows(in: database, snapshot: empty)
    )
    try await assertDatabaseIntegrity(database)
    _ = try await database.checkpoint()
    await database.close()
    return Self(root: schemaEight.root, databaseURL: schemaEight.databaseURL, snapshot: snapshot)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct PopulatedSchemaEightFixture {
  let root: URL
  let databaseURL: URL
  let snapshot: SchemaEightSnapshot

  static func make() async throws -> Self {
    let fixture = try DatabaseFixture()
    let database = try SQLiteStore(
      databaseURL: fixture.databaseURL,
      migrations: schemaEightMigrations
    )
    #expect(try await database.schemaVersion() == 8)
    #expect(database.migrationBackups.isEmpty)

    let repositoryID = UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
    let jobID = UUID(uuidString: "52000000-0000-4000-8000-000000000002")!
    let unrelatedRepositoryID = "53000000-0000-4000-8000-000000000003"
    let unrelatedJobID = "54000000-0000-4000-8000-000000000004"
    let repository = repositoryID.uuidString.lowercased()
    let job = jobID.uuidString.lowercased()

    for (id, nodeID, name) in [
      (repository, "node-schema8-canary", "schema8-canary"),
      (unrelatedRepositoryID, "node-schema8-unrelated", "schema8-unrelated"),
    ] {
      _ = try await database.execute(
        """
        INSERT INTO repositories(
          id, node_id, owner, name, default_branch,
          review_enabled, triage_enabled, implementation_enabled, enabled,
          created_at, updated_at
        ) VALUES (?, ?, 'fixture-owner', ?, 'main', 1, 1, 1, 1, 100, 100)
        """,
        bindings: [.text(id), .text(nodeID), .text(name)]
      )
    }
    _ = try await database.execute(
      """
      INSERT INTO jobs(
        id, repository_id, kind, object_node_id, object_number, revision_key,
        contract_version_used, priority, state, current_step, current_step_kind,
        attempt, created_at, updated_at
      ) VALUES (?, ?, 'prReview', 'pr-node-schema8', 834, 'schema8-head',
        'schema8-contract', 4, 'runningPi', 0, 'review', 3, 101, 101)
      """,
      bindings: [.text(job), .text(repository)]
    )
    _ = try await database.execute(
      """
      INSERT INTO jobs(
        id, repository_id, kind, object_node_id, object_number, revision_key,
        contract_version_used, priority, state, current_step, current_step_kind,
        attempt, created_at, updated_at
      ) VALUES (?, ?, 'issueTriage', 'issue-node-unrelated', 99, 'unrelated-revision',
        'schema8-contract', 1, 'queued', 0, 'triage', 0, 102, 102)
      """,
      bindings: [.text(unrelatedJobID), .text(unrelatedRepositoryID)]
    )
    _ = try await database.execute(
      "UPDATE app_settings SET paused = 1, updated_at = 100 WHERE singleton = 1"
    )
    _ = try await database.execute("UPDATE model_profiles SET updated_at = 100")
    _ = try await database.execute(
      """
      INSERT INTO repository_leases(
        repository_id, job_id, generation, heartbeat, active
      ) VALUES (?, ?, 1, 103, 1)
      """,
      bindings: [.text(repository), .text(job)]
    )
    for (eventKey, fromState, toState) in [
      (
        "canary:\(String(repeating: "d", count: 64)):m8:admit:\(job)",
        "queued",
        "leased"
      ),
      (
        "canary:\(String(repeating: "d", count: 64)):m8:pi:architecture:r1",
        "runningPi",
        "runningPi"
      ),
    ] {
      _ = try await database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, ?, ?, 'schema8 paused canary authority', 3, 3, 0, 0, 104)
        """,
        bindings: [.text(job), .text(eventKey), .text(fromState), .text(toState)]
      )
    }
    _ = try await database.execute(
      """
      INSERT INTO repository_backoff(
        repository_id, failure_count, not_before, reason, updated_at
      ) VALUES (?, 2, 500, 'unrelated fixture backoff', 104)
      """,
      bindings: [.text(unrelatedRepositoryID)]
    )
    _ = try await database.execute(
      """
      INSERT INTO artifacts(
        id, job_id, kind, relative_path, sha256,
        redaction_classification, producer_run_id, created_at
      ) VALUES (
        'artifact-schema8-unrelated', ?, 'fixture', 'unrelated/fixture.json', ?,
        'synthetic', NULL, 105
      )
      """,
      bindings: [.text(unrelatedJobID), .text(String(repeating: "9", count: 64))]
    )
    _ = try await database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (
        ?, 'unrelated:queued', 'discovered', 'queued', 'unrelated fixture transition',
        0, 0, 0, 0, 106
      )
      """,
      bindings: [.text(unrelatedJobID)]
    )

    let store = PiRunStore(database: database)
    let handshake = schemaEightHandshake()
    _ = try await store.bindRepository(
      repositoryID: repositoryID,
      workspaceID: "workspace-schema8",
      identityRoot: URL(fileURLWithPath: "/private/tmp/jidoka-schema8-migration/worktree"),
      handshake: handshake,
      now: Date(timeIntervalSince1970: 110)
    )
    _ = try await store.prepareJobBinding(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: "workspace-schema8",
      now: Date(timeIntervalSince1970: 111)
    )

    let roles: [PiWorkflowRole] = [.architecture, .security, .test, .synthesis]
    var activations: [HerdrRoleHostActivation] = []
    for (index, role) in roles.enumerated() {
      let hostID = "rolehost-schema8-\(role.rawValue)"
      _ = try await store.prepareRoleHost(
        id: hostID,
        jobID: jobID,
        generation: 1,
        role: role,
        workspaceID: "workspace-schema8",
        bootstrapDescriptorSHA256: String(repeating: Character(String(index + 1)), count: 64),
        hostExecutableSHA256: String(repeating: "e", count: 64),
        now: Date(timeIntervalSince1970: 112)
      )
      activations.append(
        HerdrRoleHostActivation(
          roleHostID: hostID,
          workspaceID: "workspace-schema8",
          tabID: "tab-schema8",
          paneID: "wM:p\(index + 2)",
          terminalID: "terminal-schema8-\(role.rawValue)",
          processIdentity: try HerdrHostProcessIdentity(
            processID: Int32(54_262 + index),
            startSeconds: UInt64(1_000 + index),
            startMicroseconds: UInt64(2_000 + index)
          )
        )
      )
    }
    try await store.activateTopology(
      jobID: jobID,
      tabID: "tab-schema8",
      hosts: activations,
      now: Date(timeIntervalSince1970: 113)
    )

    let run = try await store.prepareRun(
      id: schemaEightRunID,
      jobID: jobID,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      jobAttempt: 3,
      topologyGeneration: 1,
      jobStep: 0,
      runNonce: String(repeating: "a", count: 64),
      requestSHA256: String(repeating: "b", count: 64),
      resourceVersion: "schema8-fixture",
      resourceHash: String(repeating: "c", count: 64),
      model: "fixture/model:max",
      sessionPath: URL(fileURLWithPath: "/private/tmp/jidoka-schema8-migration/session"),
      channelPath: URL(fileURLWithPath: "/private/tmp/jidoka-schema8-migration/channel"),
      now: Date(timeIntervalSince1970: 114)
    )
    let authorizationPrefix = "canary:\(String(repeating: "d", count: 64)):m8:"
    func authorize(
      _ launchAttemptID: String,
      evidence: Character,
      at instant: Double
    ) async throws {
      _ = try await database.execute(
        """
        INSERT INTO job_transitions(
          job_id, event_key, from_state, to_state, reason,
          attempt_before, attempt_after, step_before, step_after, created_at
        ) VALUES (?, ?, 'runningPi', 'runningPi', 'schema8 exact retry authority',
          3, 3, 0, 0, ?)
        """,
        bindings: [
          .text(job),
          .text(
            authorizationPrefix + "pi-fresh-retry:" + run.id + ":"
              + launchAttemptID + ":" + String(repeating: evidence, count: 64)
          ),
          .real(instant),
        ]
      )
    }
    func insertFailedLaunch(
      id: String,
      queueSequence: Int,
      descriptor: Character,
      failureCode: String,
      childProcess: Bool,
      createdAt: Double,
      updatedAt: Double,
      firstEventSequence: Int
    ) async throws {
      _ = try await database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, failure_code,
          child_pid, child_process_group_id, child_start_seconds, child_start_microseconds,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'fresh', ?, NULL, NULL, 'failed', ?,
          ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(id),
          .text(run.id),
          .text(schemaEightArchitectureHostID),
          .integer(Int64(queueSequence)),
          .text(String(repeating: descriptor, count: 64)),
          .text(failureCode),
          childProcess ? .integer(60_001) : .null,
          childProcess ? .integer(60_001) : .null,
          childProcess ? .integer(123) : .null,
          childProcess ? .integer(1) : .null,
          .real(createdAt),
          .real(updatedAt),
        ]
      )
      var events: [(String, String?, Double)] = [
        ("prepared", nil, createdAt),
        ("enqueued", nil, createdAt + 1),
        ("running", nil, createdAt + 2),
      ]
      if childProcess {
        events.append(("childProcessRecorded", String(repeating: "1", count: 64), createdAt + 3))
      }
      events.append(("failed", nil, updatedAt))
      for (offset, event) in events.enumerated() {
        _ = try await database.execute(
          """
          INSERT INTO pi_run_events(
            run_id, launch_attempt_id, sequence, kind,
            record_sha256, detail_code, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(run.id),
            .text(id),
            .integer(Int64(firstEventSequence + offset)),
            .text(event.0),
            event.1.map(SQLiteValue.text) ?? .null,
            event.0 == "failed" ? .text(failureCode) : .null,
            .real(event.2),
          ]
        )
      }
    }

    let firstLaunchID = "launch-schema8-q1"
    try await insertFailedLaunch(
      id: firstLaunchID,
      queueSequence: 1,
      descriptor: "4",
      failureCode: "RUNTIME_TIMEOUT",
      childProcess: true,
      createdAt: 120,
      updatedAt: 124,
      firstEventSequence: 2
    )
    _ = try await database.execute(
      "UPDATE pi_runs SET outcome = 'running', updated_at = 124 WHERE id = ?",
      bindings: [.text(run.id)]
    )
    try await authorize(firstLaunchID, evidence: "5", at: 125)

    let secondLaunchID = "launch-schema8-q2"
    try await insertFailedLaunch(
      id: secondLaunchID,
      queueSequence: 2,
      descriptor: "5",
      failureCode: "HERDR_TRANSACTION_FAILED",
      childProcess: false,
      createdAt: 126,
      updatedAt: 129,
      firstEventSequence: 7
    )
    try await authorize(secondLaunchID, evidence: "6", at: 130)

    let thirdLaunchID = "launch-schema8-q3"
    try await insertFailedLaunch(
      id: thirdLaunchID,
      queueSequence: 3,
      descriptor: "6",
      failureCode: "HERDR_TRANSACTION_FAILED",
      childProcess: false,
      createdAt: 131,
      updatedAt: 134,
      firstEventSequence: 11
    )
    _ = try await database.execute(
      """
      UPDATE herdr_role_hosts
      SET last_queue_sequence = 3, updated_at = 134
      WHERE id = ?
      """,
      bindings: [.text(schemaEightArchitectureHostID)]
    )
    try await authorize(thirdLaunchID, evidence: "7", at: 135)

    let intentStore = SQLiteHerdrTopologyIntentStore(
      database: database,
      now: { Date(timeIntervalSince1970: 140) }
    )
    let socketIdentity = HerdrSocketIdentityRecord(handshake.socketIdentity)
    let primeReceipt = try await intentStore.prepare(
      HerdrTopologyMutationIntent(
        mutationID: "prime-schema8-unknown",
        kind: .primeAgentAuthority,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: String(repeating: "7", count: 64),
        socketIdentity: socketIdentity
      )
    )
    try await intentStore.markSendStarted(primeReceipt)
    try await intentStore.markUnknown(primeReceipt)
    try await authorize(thirdLaunchID, evidence: "8", at: 141)

    let resetReceipt = try await intentStore.prepare(
      HerdrTopologyMutationIntent(
        mutationID: "reset-schema8-unknown",
        kind: .resetAgentAuthority,
        repositoryID: repository,
        jobID: job,
        generation: 1,
        payloadSHA256: String(repeating: "8", count: 64),
        socketIdentity: socketIdentity
      )
    )
    try await intentStore.markSendStarted(resetReceipt)
    try await intentStore.markUnknown(resetReceipt)

    try await assertSchemaEightIncidentShape(
      database,
      repositoryID: repository,
      jobID: job,
      runID: run.id
    )
    try await assertDatabaseIntegrity(database)
    let snapshot = try await schemaEightSnapshot(of: database)
    #expect(snapshot.digest == expectedPopulatedSchemaEightDigest)
    _ = try await database.checkpoint()
    await database.close()
    return Self(root: fixture.root, databaseURL: fixture.databaseURL, snapshot: snapshot)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func productionSchemaNineMigration() throws -> SQLiteMigration {
  #expect(DatabaseSchema.migrations.count >= 9)
  let migration = try #require(
    DatabaseSchema.migrations.first(where: { $0.version == 9 })
  )
  #expect(DatabaseSchema.migrations.firstIndex(of: migration) == 8)
  #expect(migration.version == 9)
  #expect(
    migration.name
      == "authorized-architecture-role-host-replacement-and-generation-rollover"
  )
  #expect(migration.requiresBackup)
  #expect(migration.statements.count == 76)
  #expect(migrationDigest(migration) == expectedSchemaNineMigrationDigest)
  return migration
}

private func productionSchemaTenMigration() throws -> SQLiteMigration {
  #expect(DatabaseSchema.migrations.count >= 10)
  let migration = try #require(
    DatabaseSchema.migrations.first(where: { $0.version == 10 })
  )
  #expect(DatabaseSchema.migrations.firstIndex(of: migration) == 9)
  #expect(migration.name == "progressive-production-rollout-authority")
  #expect(migration.requiresBackup)
  #expect(migration.statements.count == schemaTenStatementCuts.count)
  #expect(migrationDigest(migration) == expectedSchemaTenMigrationDigest)
  return migration
}

/// Reproduce a row written before `schema_migrations.statements_sha256` existed.
///
/// The table is append-only by trigger, so the guard is lifted for exactly this edit
/// and restored immediately: the test needs the historical shape, not a lasting hole.
/// Reproduce a ledger written before `statements_sha256` existed: no column at all.
private func dropRecordedMigrationDigestColumn(in database: SQLiteStore) async throws {
  let present =
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM pragma_table_info('schema_migrations')
      WHERE name = 'statements_sha256'
      """
    ) ?? 0
  guard present == 1 else { return }
  try await database.execute("ALTER TABLE schema_migrations DROP COLUMN statements_sha256")
}

private func clearRecordedMigrationDigest(
  in database: SQLiteStore,
  version: Int
) async throws {
  try await database.execute("DROP TRIGGER schema_migrations_no_update")
  try await database.execute(
    "UPDATE schema_migrations SET statements_sha256 = NULL WHERE version = ?",
    bindings: [.integer(Int64(version))]
  )
  try await database.execute(
    """
    CREATE TRIGGER schema_migrations_no_update
    BEFORE UPDATE ON schema_migrations
    BEGIN
      SELECT RAISE(ABORT, 'schema_migrations is append-only');
    END
    """
  )
}

private func migrationDigest(_ migration: SQLiteMigration) -> String {
  var components = [
    "version:\(migration.version)",
    "name:\(Data(migration.name.utf8).base64EncodedString())",
    "backup:\(migration.requiresBackup ? 1 : 0)",
  ]
  components.append(
    contentsOf: migration.statements.enumerated().map { index, statement in
      "statement:\(index + 1):\(Data(statement.utf8).base64EncodedString())"
    }
  )
  return sha256(components.joined(separator: "\n"))
}

private func schemaEightSnapshot(of database: SQLiteStore) async throws -> SchemaEightSnapshot {
  let schemaRows = try await database.query(
    """
    SELECT type, name, tbl_name, sql
    FROM sqlite_schema
    WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
    ORDER BY type, name
    """
  )
  let schemaObjects = schemaRows.map {
    canonicalRow($0, columns: ["type", "name", "tbl_name", "sql"])
  }.sorted()
  let names = Set(
    schemaRows.compactMap { row -> String? in
      guard case .text(let name)? = row["name"] else { return nil }
      return name
    }
  )
  let tableRows = try await database.query(
    """
    SELECT name FROM sqlite_schema
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """
  )
  var tableColumns: [String: [String]] = [:]
  for row in tableRows {
    guard case .text(let table)? = row["name"] else {
      throw SQLiteStoreError.unexpectedResult("schema table name is not text")
    }
    let columns = try await database.query("PRAGMA table_info(\(quotedIdentifier(table)))")
      .compactMap { column -> (Int, String)? in
        guard case .integer(let identifier)? = column["cid"],
          case .text(let name)? = column["name"]
        else { return nil }
        return (Int(identifier), name)
      }
      .sorted { $0.0 < $1.0 }
      .map(\.1)
    tableColumns[table] = columns
  }
  let rows = try await applicationRows(in: database, tableColumns: tableColumns)
  var digestComponents = ["schema8-snapshot-v1"]
  digestComponents.append(contentsOf: schemaObjects.map { "schema:\($0)" })
  for table in tableColumns.keys.sorted() {
    let columns = tableColumns[table] ?? []
    digestComponents.append(
      "columns:\(Data(table.utf8).base64EncodedString()):"
        + columns.map { Data($0.utf8).base64EncodedString() }.joined(separator: ",")
    )
    digestComponents.append(contentsOf: (rows[table] ?? []).map { "row:\($0)" })
  }
  return SchemaEightSnapshot(
    schemaObjects: schemaObjects,
    schemaObjectNames: names,
    tableColumns: tableColumns,
    applicationRows: rows,
    digest: sha256(digestComponents.joined(separator: "\n"))
  )
}

private func tableColumns(in database: SQLiteStore) async throws -> [String: [String]] {
  let tables = try await database.query(
    """
    SELECT name FROM sqlite_schema
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """
  )
  var result: [String: [String]] = [:]
  for row in tables {
    guard case .text(let table)? = row["name"] else {
      throw SQLiteStoreError.unexpectedResult("schema table name is not text")
    }
    result[table] = try await database.query(
      "PRAGMA table_info(\(quotedIdentifier(table)))"
    ).compactMap { column -> (Int, String)? in
      guard case .integer(let identifier)? = column["cid"],
        case .text(let name)? = column["name"]
      else { return nil }
      return (Int(identifier), name)
    }.sorted { $0.0 < $1.0 }.map(\.1)
  }
  return result
}

private func historicalRows(
  in database: SQLiteStore,
  snapshot: HistoricalSchemaNineSnapshot
) async throws -> [String: [String]] {
  var result: [String: [String]] = [:]
  for table in snapshot.columns.keys.sorted() {
    let columns = snapshot.columns[table] ?? []
    guard !columns.isEmpty else {
      result[table] = []
      continue
    }
    let projection = columns.map(quotedIdentifier).joined(separator: ", ")
    let filter = table == "schema_migrations" ? " WHERE version <= 9" : ""
    result[table] = try await database.query(
      "SELECT \(projection) FROM \(quotedIdentifier(table))\(filter)"
    ).map {
      canonicalRow($0, columns: columns, table: table)
    }.sorted()
  }
  return result
}

private func applicationRows(
  in database: SQLiteStore,
  tableColumns: [String: [String]]
) async throws -> [String: [String]] {
  var result: [String: [String]] = [:]
  for table in tableColumns.keys.sorted() {
    let columns = tableColumns[table] ?? []
    guard !columns.isEmpty else {
      result[table] = []
      continue
    }
    let projection = columns.map(quotedIdentifier).joined(separator: ", ")
    let schemaVersionFilter = table == "schema_migrations" ? " WHERE version <= 8" : ""
    let rows = try await database.query(
      "SELECT \(projection) FROM \(quotedIdentifier(table))\(schemaVersionFilter)"
    )
    result[table] = rows.map {
      canonicalRow($0, columns: columns, table: table)
    }.sorted()
  }
  return result
}

private func canonicalRow(
  _ row: SQLiteRow,
  columns: [String],
  table: String? = nil
) -> String {
  columns.map { column in
    let name = Data(column.utf8).base64EncodedString()
    if table == "schema_migrations", column == "applied_at" {
      return "\(name)=normalized-schema-migration-time"
    }
    return "\(name)=\(canonicalValue(row[column]))"
  }.joined(separator: "|")
}

private func canonicalValue(_ value: SQLiteValue?) -> String {
  switch value {
  case .integer(let value):
    return "integer:\(value)"
  case .real(let value):
    return "real:\(String(format: "%016llx", value.bitPattern))"
  case .text(let value):
    return "text:\(Data(value.utf8).base64EncodedString())"
  case .blob(let value):
    return "blob:\(value.base64EncodedString())"
  case .null:
    return "null"
  case nil:
    return "missing"
  }
}

private func quotedIdentifier(_ value: String) -> String {
  "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func schemaObjectNames(in database: SQLiteStore) async throws -> Set<String> {
  Set(
    try await database.query(
      "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL"
    ).compactMap { row -> String? in
      guard case .text(let name)? = row["name"] else { return nil }
      return name
    }
  )
}

private func assertSchemaEightIncidentShape(
  _ database: SQLiteStore,
  repositoryID: String,
  jobID: String,
  runID: String
) async throws {
  #expect(try await database.scalarInt("SELECT paused FROM app_settings WHERE singleton = 1") == 1)
  #expect(
    try await database.scalarInt(
      "SELECT COUNT(*) FROM jobs WHERE id = ? AND kind = 'prReview' AND state = 'runningPi'",
      bindings: [.text(jobID)]
    ) == 1
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM repository_leases
      WHERE repository_id = ? AND job_id = ? AND active = 1
      """,
      bindings: [.text(repositoryID), .text(jobID)]
    ) == 1
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM herdr_repository_bindings AS repository_binding
      JOIN herdr_job_bindings AS job_binding
        ON job_binding.repository_id = repository_binding.repository_id
      WHERE repository_binding.repository_id = ?
        AND repository_binding.state = 'active'
        AND job_binding.job_id = ?
        AND job_binding.state = 'active'
      """,
      bindings: [.text(repositoryID), .text(jobID)]
    ) == 1
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM herdr_role_hosts
      WHERE job_id = ? AND generation = 1 AND state = 'waiting'
        AND role IN ('architecture', 'security', 'test', 'synthesis')
      """,
      bindings: [.text(jobID)]
    ) == 4
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM pi_run_launches
      WHERE run_id = ? AND queue_sequence = 1 AND state = 'failed'
        AND failure_code = 'RUNTIME_TIMEOUT' AND child_pid IS NOT NULL
      """,
      bindings: [.text(runID)]
    ) == 1
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM pi_run_launches
      WHERE run_id = ? AND queue_sequence IN (2, 3) AND state = 'failed'
        AND failure_code = 'HERDR_TRANSACTION_FAILED' AND child_pid IS NULL
      """,
      bindings: [.text(runID)]
    ) == 2
  )
  #expect(
    try await database.scalarInt(
      "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence >= 4",
      bindings: [.text(runID)]
    ) == 0
  )
  #expect(
    try await database.scalarInt(
      "SELECT COUNT(*) FROM job_transitions WHERE event_key GLOB 'canary:*:pi-fresh-retry:*'"
    ) == 4
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM herdr_topology_intents
      WHERE job_id = ? AND state = 'unknown'
        AND kind IN ('primeAgentAuthority', 'resetAgentAuthority')
      """,
      bindings: [.text(jobID)]
    ) == 2
  )
  #expect(
    try await database.scalarInt(
      """
      SELECT
        (SELECT COUNT(*) FROM repositories WHERE id = '53000000-0000-4000-8000-000000000003')
        + (SELECT COUNT(*) FROM jobs WHERE id = '54000000-0000-4000-8000-000000000004')
        + (SELECT COUNT(*) FROM repository_backoff
          WHERE repository_id = '53000000-0000-4000-8000-000000000003')
        + (SELECT COUNT(*) FROM artifacts WHERE id = 'artifact-schema8-unrelated')
        + (SELECT COUNT(*) FROM job_transitions WHERE event_key = 'unrelated:queued')
      """
    ) == 5
  )
}

private func assertDatabaseIntegrity(_ database: SQLiteStore) async throws {
  #expect(try await database.scalarText("PRAGMA integrity_check") == "ok")
  #expect(try await database.query("PRAGMA foreign_key_check").isEmpty)
}

private func migrationBackupURLs(in root: URL, beforeVersion: Int = 9) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: root,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
  ).filter {
    $0.lastPathComponent.hasPrefix("jidoka-code.sqlite3.before-v\(beforeVersion)-")
      && $0.pathExtension == "sqlite3"
  }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func schemaEightHandshake() -> HerdrHandshake {
  HerdrHandshake(
    pong: HerdrPong(
      version: "0.8.0",
      protocolVersion: 19,
      capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
    ),
    snapshot: HerdrSessionSnapshot(
      version: "0.8.0",
      protocolVersion: 19,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: [],
      tabs: [],
      panes: [],
      agents: []
    ),
    socketIdentity: HerdrSocketIdentity(
      device: 10,
      inode: 20,
      owner: 501,
      permissions: 0o600
    )
  )
}

private func schemaNineHandshake() -> HerdrHandshake {
  HerdrHandshake(
    pong: HerdrPong(
      version: "0.8.2",
      protocolVersion: 20,
      capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
    ),
    snapshot: HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: [],
      tabs: [],
      panes: [],
      agents: []
    ),
    socketIdentity: HerdrSocketIdentity(
      device: 10,
      inode: 20,
      owner: 501,
      permissions: 0o600
    )
  )
}

private func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
