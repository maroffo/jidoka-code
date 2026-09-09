// ABOUTME: Migration tests against the schema 9 the installed 0.1.1 build 2 helper actually shipped
// ABOUTME: Built from a static SQL fixture with provenance, never from DatabaseSchema.migrations
import Foundation
import SQLite3
import Testing

@testable import JidokaCodeCore

/// Digest of `Fixtures/Schema/shipped-schema9.sql`. The fixture is derived only by
/// `scripts/tests/fixtures/derive-shipped-schema9-fixture.sh` from the evidence database
/// named in its header; a new digest here must come with a new derivation record.
private let shippedSchemaNineFixtureSHA256 =
  "918a57fd2bd7f8c6a1875907958b7b9d9c091e8f1512844c2c2507e061aa9663"
private let shippedSchemaNineEvidenceSHA256 =
  "68647463322c65da2476507fb6aae276dbc4f3c74c0b69ffdd5c421a35f587d8"
private let shippedSchemaNineMigrationName =
  "authorized-architecture-role-host-replacement-and-generation-rollover"

/// The migration list a binary that only knows schema 9 carries. It is the current list
/// truncated, which the fixture comparison below proves is the shipped list: migrations 1
/// to 9 must reproduce the fixture object for object.
private let shippedMigrations = Array(DatabaseSchema.migrations.prefix(9))

@Suite("Shipped schema 9 compatibility")
struct ShippedSchemaNineMigrationTests {
  @Test("the fixture is derived from the evidence database with provenance")
  func fixtureCarriesProvenance() throws {
    let data = try shippedSchemaNineFixture()
    #expect(sha256(data) == shippedSchemaNineFixtureSHA256)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("SHA-256 \(shippedSchemaNineEvidenceSHA256)"))
    #expect(
      text.contains(
        "SHA-256 3aeb9f172d8c0dbffd0a70552008c6c2d5994b74fbc34a8258ce9b19378f7779"))
    #expect(
      text.contains(
        "production DDL sha3-256:  9fe91dab565079947cdf85bb7c93571809e83475954b08cb0a5cf458c3e71ad6"
      ))
    #expect(text.contains("scripts/tests/fixtures/derive-shipped-schema9-fixture.sh"))
    // The shipped ledger predates the digest column; a fixture whose ledger carries one
    // was regenerated from a store, not from the evidence database.
    #expect(
      text.contains(
        """
        CREATE TABLE schema_migrations (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          applied_at REAL NOT NULL
        ) STRICT;
        """))
  }

  @Test("migrations 1 to 9 reproduce the shipped schema 9 object for object")
  func freshMigrationsReproduceShippedSchema() async throws {
    let shipped = try ShippedSchemaNineDatabase.make()
    defer { shipped.remove() }
    let fresh = try ShippedSchemaNineDatabase.emptyLocation()
    defer { fresh.remove() }

    let shippedStore = try SQLiteStore(
      databaseURL: shipped.databaseURL, migrations: shippedMigrations)
    #expect(try await shippedStore.schemaVersion() == 9)
    #expect(shippedStore.migrationBackups.isEmpty)
    // Opening at the supported version is read-only: the digest column is not added.
    #expect(try await hasDigestColumn(shippedStore) == false)
    let freshStore = try SQLiteStore(
      databaseURL: fresh.databaseURL, migrations: shippedMigrations)
    #expect(try await freshStore.schemaVersion() == 9)
    #expect(try await hasDigestColumn(freshStore) == true)

    // The ledger table differs only by the store-owned digest column, which is not
    // migration output. Every migration-created object must match exactly.
    let shippedObjects = try await schemaObjects(in: shippedStore, excluding: ["schema_migrations"])
    let freshObjects = try await schemaObjects(in: freshStore, excluding: ["schema_migrations"])
    #expect(freshObjects == shippedObjects)
    #expect(freshObjects.count == 143)
    var freshColumns = try await tableColumns(in: freshStore)
    freshColumns["schema_migrations"] = nil
    var shippedColumns = try await tableColumns(in: shippedStore)
    shippedColumns["schema_migrations"] = nil
    #expect(freshColumns == shippedColumns)
    #expect(try await ledger(in: freshStore).map(\.name) == ledger(in: shippedStore).map(\.name))
    #expect(try await ledger(in: shippedStore).last?.name == shippedSchemaNineMigrationName)
    #expect(try await ledger(in: shippedStore).allSatisfy { $0.digest == nil })
    await shippedStore.close()
    await freshStore.close()
  }

  @Test("the shipped schema 9 upgrades to the current schema and converges with the fresh path")
  func shippedSchemaUpgradesAndConverges() async throws {
    let migrationTen = try #require(DatabaseSchema.migrations.first { $0.version == 10 })
    let migrationEleven = try #require(DatabaseSchema.migrations.first { $0.version == 11 })
    let shipped = try ShippedSchemaNineDatabase.make()
    defer { shipped.remove() }

    let seeded = try SQLiteStore(databaseURL: shipped.databaseURL, migrations: shippedMigrations)
    try await insertSyntheticRows(into: seeded)
    // The shipped binding-history table already accepts RUNTIME_CHANGED (the rebuild is
    // part of the shipped migration 9); the resume guards it carries allow this resume
    // because no generation rollover is pending.
    try await insertBindingHistory(into: seeded, id: 2, reason: "RUNTIME_CHANGED")
    let before = try await rowSnapshot(in: seeded)
    let onboardingBefore = try await seeded.scalarInt(
      "SELECT onboarding_complete FROM app_settings")
    let shippedLedgerNames = try await ledger(in: seeded).map(\.name)
    _ = try await seeded.checkpoint()
    await seeded.close()

    let upgraded = try SQLiteStore(databaseURL: shipped.databaseURL)
    #expect(try await upgraded.schemaVersion() == 11)
    #expect(upgraded.migrationBackups.count == 2)
    let backupURL = try #require(upgraded.migrationBackups.first)
    #expect(backupURL.lastPathComponent.contains(".before-v10-"))
    #expect(upgraded.migrationBackups[1].lastPathComponent.contains(".before-v11-"))
    let after = try await rowSnapshot(in: upgraded)
    for (table, rows) in before where !["app_settings", "schema_migrations"].contains(table) {
      #expect(after[table] == rows, "\(table)")
    }
    #expect(try await upgraded.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(try await upgraded.scalarInt("SELECT max_concurrency FROM app_settings") == 1)
    #expect(
      try await upgraded.scalarText("SELECT active_rollout_authorization_id FROM app_settings")
        == nil)
    #expect(
      try await upgraded.scalarInt("SELECT onboarding_complete FROM app_settings")
        == onboardingBefore)
    let upgradedLedger = try await ledger(in: upgraded)
    #expect(upgradedLedger.map(\.version) == Array(1...11))
    #expect(upgradedLedger.prefix(9).allSatisfy { $0.digest == nil })
    #expect(upgradedLedger[9].digest == migrationTen.statementsSHA256)
    #expect(upgradedLedger.last?.digest == migrationEleven.statementsSHA256)
    // Both history rows survived; the table still accepts every reason.
    try await insertBindingHistory(into: upgraded, id: 3, reason: "RUNTIME_CHANGED")
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM herdr_repository_binding_history") == 3)
    // Migration 10 replaced the shipped rollover resume guards with the rollout scope latch.
    for dropped in [
      "app_settings_generation_rollover_resume_denied",
      "app_settings_generation_rollover_insert_resume_denied",
    ] {
      #expect(
        try await upgraded.scalarInt(
          "SELECT COUNT(*) FROM sqlite_schema WHERE name = ?", bindings: [.text(dropped)]) == 0,
        "\(dropped)")
    }
    #expect(
      try await upgraded.scalarInt(
        "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'app_settings_rollout_scope_required'")
        == 1)
    #expect(
      try await upgraded.scalarInt("SELECT COUNT(*) FROM herdr_generation_rollover_authorizations")
        == 0)
    #expect(try await upgraded.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0)
    try await assertIntegrity(upgraded)

    // The backup is taken after the store adds the additive ledger column, so its
    // ledger rows carry a NULL digest; every application row is the pre-migration row.
    let backup = try SQLiteStore(databaseURL: backupURL, migrations: shippedMigrations)
    #expect(try await backup.schemaVersion() == 9)
    let backupRows = try await rowSnapshot(in: backup)
    for (table, rows) in before where table != "schema_migrations" {
      #expect(backupRows[table] == rows, "\(table)")
    }
    #expect(try await ledger(in: backup).map(\.name) == shippedLedgerNames)
    try await assertIntegrity(backup)
    await backup.close()

    let fresh = try ShippedSchemaNineDatabase.emptyLocation()
    defer { fresh.remove() }
    let freshStore = try SQLiteStore(databaseURL: fresh.databaseURL)
    #expect(try await freshStore.schemaVersion() == 11)
    #expect(try await schemaObjects(in: freshStore) == schemaObjects(in: upgraded))
    #expect(try await tableColumns(in: freshStore) == tableColumns(in: upgraded))
    let freshLedger = try await ledger(in: freshStore)
    #expect(freshLedger.map(\.version) == upgradedLedger.map(\.version))
    #expect(freshLedger.map(\.name) == upgradedLedger.map(\.name))
    #expect(freshLedger.allSatisfy { $0.digest != nil })
    #expect(freshLedger.last?.digest == migrationEleven.statementsSHA256)
    #expect(try await freshStore.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(try await freshStore.scalarInt("SELECT max_concurrency FROM app_settings") == 1)
    try await assertIntegrity(freshStore)
    await freshStore.close()
    await upgraded.close()

    let reopened = try SQLiteStore(databaseURL: shipped.databaseURL)
    #expect(try await reopened.schemaVersion() == 11)
    #expect(reopened.migrationBackups.isEmpty)
    await reopened.close()
  }

  @Test("a binary that only knows the shipped schema 9 refuses a newer schema without writing")
  func shippedBinaryRefusesSchemaTen() async throws {
    let shipped = try ShippedSchemaNineDatabase.make()
    defer { shipped.remove() }
    let seeded = try SQLiteStore(databaseURL: shipped.databaseURL, migrations: shippedMigrations)
    try await insertSyntheticRows(into: seeded)
    await seeded.close()
    let upgraded = try SQLiteStore(databaseURL: shipped.databaseURL)
    #expect(try await upgraded.schemaVersion() == 11)
    _ = try await upgraded.checkpoint()
    await upgraded.close()

    let current = try SQLiteStore(databaseURL: shipped.databaseURL)
    let objectsBefore = try await schemaObjects(in: current)
    let rowsBefore = try await rowSnapshot(in: current)
    _ = try await current.checkpoint()
    await current.close()
    let directoryBefore = try shipped.directoryDigests()
    #expect(directoryBefore.keys.filter { $0.contains(".before-v10-") }.count == 1)
    #expect(!directoryBefore.values.contains { $0.hasPrefix("wal:") })

    #expect(throws: SQLiteStoreError.migrationTooNew(database: 11, supported: 9)) {
      _ = try SQLiteStore(databaseURL: shipped.databaseURL, migrations: shippedMigrations)
    }

    // Every file in the directory, not only the main database: a refused open must
    // leave no sidecar, journal or backup behind and change no byte of what was there.
    #expect(try shipped.directoryDigests() == directoryBefore)
    let reopened = try SQLiteStore(databaseURL: shipped.databaseURL)
    #expect(try await schemaObjects(in: reopened) == objectsBefore)
    #expect(try await rowSnapshot(in: reopened) == rowsBefore)
    #expect(reopened.migrationBackups.isEmpty)
    await reopened.close()
  }
}

private enum ShippedSchemaNineFixtureError: Error {
  case missingResource
  case openFailed(String)
  case replayFailed(String)
}

private func shippedSchemaNineFixture() throws -> Data {
  guard
    let url = Bundle.module.url(
      forResource: "shipped-schema9", withExtension: "sql", subdirectory: "Fixtures/Schema")
  else {
    throw ShippedSchemaNineFixtureError.missingResource
  }
  return try Data(contentsOf: url)
}

private struct ShippedSchemaNineDatabase {
  let root: URL
  let databaseURL: URL

  static func emptyLocation() throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-shipped-schema9-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return Self(root: root, databaseURL: root.appendingPathComponent("jidoka-code.sqlite3"))
  }

  /// Replay the fixture through SQLite directly. Going through `SQLiteStore` would run
  /// the mutable migration list, which is exactly what this fixture must not depend on.
  static func make() throws -> Self {
    let location = try emptyLocation()
    let script = String(decoding: try shippedSchemaNineFixture(), as: UTF8.self)
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(location.databaseURL.path, &handle, flags, nil) == SQLITE_OK,
      let handle
    else {
      throw ShippedSchemaNineFixtureError.openFailed(location.databaseURL.path)
    }
    defer { sqlite3_close_v2(handle) }
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, script, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(message)
      throw ShippedSchemaNineFixtureError.replayFailed(text)
    }
    return location
  }

  /// Every file in the directory by digest. The WAL index (`-shm`) is a memory-mapped
  /// lock table that SQLite keeps after close and rewrites on every open, so it is
  /// recorded by presence only; the WAL itself must stay empty for "no write" to hold.
  func directoryDigests() throws -> [String: String] {
    var digests: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
      let data = try Data(contentsOf: root.appendingPathComponent(name))
      if name.hasSuffix("-shm") {
        digests[name] = "wal-index"
      } else if name.hasSuffix("-wal") {
        digests[name] = data.isEmpty ? "empty-wal" : "wal:\(sha256(data))"
      } else {
        digests[name] = sha256(data)
      }
    }
    return digests
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private let syntheticRepositoryID = "61000000-0000-4000-8000-000000000001"

private func insertSyntheticRows(into database: SQLiteStore) async throws {
  _ = try await database.execute(
    """
    INSERT INTO repositories(
      id, node_id, owner, name, default_branch,
      review_enabled, triage_enabled, implementation_enabled, enabled, created_at, updated_at
    ) VALUES (?, 'node-shipped-schema9', 'fixture-owner', 'fixture-repository', 'main',
      1, 1, 1, 1, 10, 10)
    """,
    bindings: [.text(syntheticRepositoryID)]
  )
  try await insertBindingHistory(into: database, id: 1, reason: "SOCKET_CHANGED")
  // The evidence row is unpaused with two lanes; pause it first so the upgrade's forced
  // single-lane pause is proven from both directions of the shipped resume guard.
  _ = try await database.execute(
    "UPDATE app_settings SET paused = 1, updated_at = 11 WHERE singleton = 1")
  _ = try await database.execute(
    "UPDATE app_settings SET paused = 0, updated_at = 12 WHERE singleton = 1")
}

private func insertBindingHistory(
  into database: SQLiteStore, id: Int64, reason: String
) async throws {
  _ = try await database.execute(
    """
    INSERT INTO herdr_repository_binding_history(
      id, repository_id, workspace_id, identity_root, herdr_version, herdr_protocol,
      socket_device, socket_inode, socket_owner, socket_permissions, reason, invalidated_at
    ) VALUES (?, ?, 'workspace-1', '/private/fixture/identity', '0.8.0', 19,
      1, 2, 501, 384, ?, 11)
    """,
    bindings: [.integer(id), .text(syntheticRepositoryID), .text(reason)]
  )
}

private struct LedgerRow: Equatable {
  let version: Int
  let name: String
  let digest: String?
}

private func hasDigestColumn(_ database: SQLiteStore) async throws -> Bool {
  try await database.scalarInt(
    """
    SELECT COUNT(*) FROM pragma_table_info('schema_migrations')
    WHERE name = 'statements_sha256'
    """
  ) == 1
}

private func ledger(in database: SQLiteStore) async throws -> [LedgerRow] {
  let projection =
    try await hasDigestColumn(database)
    ? "version, name, statements_sha256" : "version, name, NULL AS statements_sha256"
  return try await database.query(
    "SELECT \(projection) FROM schema_migrations ORDER BY version"
  ).map { row in
    guard case .integer(let version)? = row["version"], case .text(let name)? = row["name"]
    else { return LedgerRow(version: -1, name: "", digest: nil) }
    if case .text(let digest)? = row["statements_sha256"] {
      return LedgerRow(version: Int(version), name: name, digest: digest)
    }
    return LedgerRow(version: Int(version), name: name, digest: nil)
  }
}

private func schemaObjects(
  in database: SQLiteStore, excluding excluded: Set<String> = []
) async throws -> [String] {
  try await database.query(
    """
    SELECT type, name, tbl_name, sql FROM sqlite_schema
    WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
    ORDER BY type, name
    """
  ).compactMap { row in
    guard case .text(let name)? = row["name"], !excluded.contains(name) else { return nil }
    return ["type", "name", "tbl_name", "sql"].map { describe(row[$0]) }.joined(separator: "\u{1F}")
  }
}

private func tableNames(in database: SQLiteStore) async throws -> [String] {
  try await database.query(
    """
    SELECT name FROM sqlite_schema
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """
  ).compactMap { row in
    guard case .text(let name)? = row["name"] else { return nil }
    return name
  }
}

private func tableColumns(in database: SQLiteStore) async throws -> [String: [String]] {
  var result: [String: [String]] = [:]
  for table in try await tableNames(in: database) {
    result[table] = try await database.query("PRAGMA table_info(\(quoted(table)))")
      .compactMap { column -> (Int64, String)? in
        guard case .integer(let identifier)? = column["cid"],
          case .text(let name)? = column["name"]
        else { return nil }
        return (identifier, name)
      }
      .sorted { $0.0 < $1.0 }
      .map(\.1)
  }
  return result
}

/// Every row of every table, canonicalised and sorted, so two databases can be compared
/// without depending on rowid order or on which columns a schema version has.
private func rowSnapshot(in database: SQLiteStore) async throws -> [String: [String]] {
  var result: [String: [String]] = [:]
  for table in try await tableNames(in: database) {
    result[table] = try await database.query("SELECT * FROM \(quoted(table))")
      .map { row in
        row.columns.map { "\($0)=\(describe(row[$0]))" }.joined(separator: "\u{1F}")
      }
      .sorted()
  }
  return result
}

private func describe(_ value: SQLiteValue?) -> String {
  switch value {
  case .integer(let value): return "integer:\(value)"
  case .real(let value): return "real:\(String(format: "%016llx", value.bitPattern))"
  case .text(let value): return "text:\(value)"
  case .blob(let value): return "blob:\(value.base64EncodedString())"
  case .null: return "null"
  case nil: return "missing"
  }
}

private func quoted(_ identifier: String) -> String {
  "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func assertIntegrity(_ database: SQLiteStore) async throws {
  #expect(try await database.scalarText("PRAGMA integrity_check") == "ok")
  #expect(try await database.query("PRAGMA foreign_key_check").isEmpty)
}
