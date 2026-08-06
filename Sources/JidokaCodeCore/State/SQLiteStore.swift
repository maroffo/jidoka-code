import Foundation
import SQLite3

public enum SQLiteValue: Equatable, Sendable {
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)
  case null
}

public struct SQLiteRow: Equatable, Sendable {
  private let values: [String: SQLiteValue]

  public init(values: [String: SQLiteValue]) {
    self.values = values
  }

  public subscript(_ column: String) -> SQLiteValue? {
    values[column]
  }

  public var columns: [String] {
    values.keys.sorted()
  }
}

public struct SQLiteMigration: Equatable, Sendable {
  public let version: Int
  public let name: String
  public let requiresBackup: Bool
  public let statements: [String]

  public init(
    version: Int,
    name: String,
    requiresBackup: Bool,
    statements: [String]
  ) {
    self.version = version
    self.name = name
    self.requiresBackup = requiresBackup
    self.statements = statements
  }
}

public struct SQLitePragmas: Equatable, Sendable {
  public let journalMode: String
  public let foreignKeysEnabled: Bool
  public let busyTimeoutMilliseconds: Int
}

public enum SQLiteStoreError: Error, Equatable, Sendable {
  case unsafePath(String)
  case openFailed(String)
  case closed
  case invalidMigrations(String)
  case migrationTooNew(database: Int, supported: Int)
  case statementFailed(code: Int32, message: String)
  case transactionAlreadyActive
  case backupFailed(String)
  case unexpectedResult(String)
}

private final class SQLiteConnection: @unchecked Sendable {
  var handle: OpaquePointer?

  init(handle: OpaquePointer) {
    self.handle = handle
  }

  func close() {
    guard let handle else { return }
    sqlite3_close_v2(handle)
    self.handle = nil
  }

  deinit {
    close()
  }
}

public actor SQLiteStore {
  public nonisolated let databaseURL: URL
  public nonisolated let migrationBackups: [URL]

  private let connection: SQLiteConnection
  private var transactionActive = false

  public init(
    databaseURL: URL,
    migrations: [SQLiteMigration] = DatabaseSchema.migrations,
    backupDirectory: URL? = nil,
    busyTimeoutMilliseconds: Int = 5_000
  ) throws {
    guard busyTimeoutMilliseconds > 0 else {
      throw SQLiteStoreError.invalidMigrations("busy timeout must be positive")
    }
    try Self.validate(migrations: migrations)
    let existedBeforeOpen = try Self.prepareDatabaseLocation(databaseURL)
    let connection = try Self.open(databaseURL)
    self.databaseURL = databaseURL
    self.connection = connection

    var backups: [URL] = []
    do {
      try Self.configure(
        connection,
        busyTimeoutMilliseconds: busyTimeoutMilliseconds
      )
      try Self.bootstrapMigrationTable(connection)
      try Self.runMigrations(
        migrations,
        connection: connection,
        databaseURL: databaseURL,
        databaseExistedBeforeOpen: existedBeforeOpen,
        backupDirectory: backupDirectory ?? databaseURL.deletingLastPathComponent(),
        backups: &backups
      )
      try Self.enforceDatabasePermissions(databaseURL)
    } catch {
      connection.close()
      throw error
    }
    self.migrationBackups = backups
  }

  public func close() {
    connection.close()
  }

  @discardableResult
  public func execute(
    _ sql: String,
    bindings: [SQLiteValue] = []
  ) throws -> Int {
    try Self.execute(sql, bindings: bindings, connection: connection)
  }

  public func query(
    _ sql: String,
    bindings: [SQLiteValue] = []
  ) throws -> [SQLiteRow] {
    try Self.query(sql, bindings: bindings, connection: connection)
  }

  public func scalarInt(
    _ sql: String,
    bindings: [SQLiteValue] = []
  ) throws -> Int64? {
    let rows = try query(sql, bindings: bindings)
    guard let first = rows.first, let column = first.columns.first else { return nil }
    switch first[column] {
    case .integer(let value):
      return value
    case .null:
      return nil
    default:
      throw SQLiteStoreError.unexpectedResult("expected integer scalar")
    }
  }

  public func scalarText(
    _ sql: String,
    bindings: [SQLiteValue] = []
  ) throws -> String? {
    let rows = try query(sql, bindings: bindings)
    guard let first = rows.first, let column = first.columns.first else { return nil }
    switch first[column] {
    case .text(let value):
      return value
    case .null:
      return nil
    default:
      throw SQLiteStoreError.unexpectedResult("expected text scalar")
    }
  }

  public func lastInsertedRowID() throws -> Int64 {
    guard let handle = connection.handle else { throw SQLiteStoreError.closed }
    return sqlite3_last_insert_rowid(handle)
  }

  public func transaction<T: Sendable>(
    _ body: @Sendable (_ store: isolated SQLiteStore) throws -> T
  ) throws -> T {
    guard !transactionActive else {
      throw SQLiteStoreError.transactionAlreadyActive
    }
    transactionActive = true
    do {
      try Self.executeRaw("BEGIN IMMEDIATE", connection: connection)
      let result = try body(self)
      try Self.executeRaw("COMMIT", connection: connection)
      transactionActive = false
      return result
    } catch {
      try? Self.executeRaw("ROLLBACK", connection: connection)
      transactionActive = false
      throw error
    }
  }

  public func schemaVersion() throws -> Int {
    Int(
      try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") ?? 0
    )
  }

  public func pragmas() throws -> SQLitePragmas {
    let journalMode = try scalarText("PRAGMA journal_mode") ?? ""
    let foreignKeys = try scalarInt("PRAGMA foreign_keys") == 1
    let busyTimeout = Int(try scalarInt("PRAGMA busy_timeout") ?? 0)
    return SQLitePragmas(
      journalMode: journalMode,
      foreignKeysEnabled: foreignKeys,
      busyTimeoutMilliseconds: busyTimeout
    )
  }

  public func backup(to destinationURL: URL) throws {
    try Self.prepareBackupDestination(destinationURL)
    try Self.backup(
      connection: connection,
      destinationURL: destinationURL
    )
  }

  private static func validate(migrations: [SQLiteMigration]) throws {
    var previous = 0
    for migration in migrations {
      guard migration.version > previous else {
        throw SQLiteStoreError.invalidMigrations(
          "migration versions must be positive and strictly increasing"
        )
      }
      guard !migration.name.isEmpty, !migration.statements.isEmpty else {
        throw SQLiteStoreError.invalidMigrations(
          "migration name and statements must be non-empty"
        )
      }
      previous = migration.version
    }
  }

  private static func prepareDatabaseLocation(_ databaseURL: URL) throws -> Bool {
    guard databaseURL.isFileURL else {
      throw SQLiteStoreError.unsafePath("database URL must be a file URL")
    }
    let parent = databaseURL.deletingLastPathComponent()
    try ensureDirectory(parent)

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: databaseURL.path,
      isDirectory: &isDirectory
    )
    if exists {
      guard !isDirectory.boolValue else {
        throw SQLiteStoreError.unsafePath("database path is a directory")
      }
      let values = try databaseURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw SQLiteStoreError.unsafePath("database path is not a regular file")
      }
    }
    return exists
  }

  private static func ensureDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw SQLiteStoreError.unsafePath("parent path is not a directory")
      }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw SQLiteStoreError.unsafePath("parent directory is unsafe")
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }

  private static func open(_ databaseURL: URL) throws -> SQLiteConnection {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
    guard result == SQLITE_OK, let handle else {
      let message =
        handle.map { String(cString: sqlite3_errmsg($0)) }
        ?? "unknown SQLite open error"
      if let handle { sqlite3_close_v2(handle) }
      throw SQLiteStoreError.openFailed(message)
    }
    return SQLiteConnection(handle: handle)
  }

  private static func configure(
    _ connection: SQLiteConnection,
    busyTimeoutMilliseconds: Int
  ) throws {
    guard let handle = connection.handle else { throw SQLiteStoreError.closed }
    guard sqlite3_busy_timeout(handle, Int32(busyTimeoutMilliseconds)) == SQLITE_OK else {
      throw statementError(connection)
    }
    let rows = try query("PRAGMA journal_mode = WAL", connection: connection)
    guard case .text(let mode)? = rows.first?["journal_mode"], mode.lowercased() == "wal"
    else {
      throw SQLiteStoreError.unexpectedResult("SQLite did not enable WAL")
    }
    try executeRaw("PRAGMA foreign_keys = ON", connection: connection)
    let foreignKeys = try query("PRAGMA foreign_keys", connection: connection)
    guard case .integer(1)? = foreignKeys.first?["foreign_keys"] else {
      throw SQLiteStoreError.unexpectedResult("SQLite did not enable foreign keys")
    }
  }

  private static func bootstrapMigrationTable(_ connection: SQLiteConnection) throws {
    try executeRaw(
      """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at REAL NOT NULL
      ) STRICT
      """,
      connection: connection
    )
  }

  private static func runMigrations(
    _ migrations: [SQLiteMigration],
    connection: SQLiteConnection,
    databaseURL: URL,
    databaseExistedBeforeOpen: Bool,
    backupDirectory: URL,
    backups: inout [URL]
  ) throws {
    let current = Int(
      try scalarInt(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
        connection: connection
      ) ?? 0
    )
    let supported = migrations.last?.version ?? 0
    guard current <= supported else {
      throw SQLiteStoreError.migrationTooNew(database: current, supported: supported)
    }

    for migration in migrations where migration.version > current {
      if migration.requiresBackup && databaseExistedBeforeOpen {
        try ensureDirectory(backupDirectory)
        let backupURL = backupDirectory.appendingPathComponent(
          "\(databaseURL.lastPathComponent).before-v\(migration.version)-\(UUID().uuidString.lowercased()).sqlite3"
        )
        try prepareBackupDestination(backupURL)
        try backup(connection: connection, destinationURL: backupURL)
        backups.append(backupURL)
      }

      try executeRaw("BEGIN IMMEDIATE", connection: connection)
      do {
        for statement in migration.statements {
          try executeRaw(statement, connection: connection)
        }
        _ = try execute(
          "INSERT INTO schema_migrations(version, name, applied_at) VALUES (?, ?, ?)",
          bindings: [
            .integer(Int64(migration.version)),
            .text(migration.name),
            .real(Date().timeIntervalSince1970),
          ],
          connection: connection
        )
        try executeRaw("COMMIT", connection: connection)
      } catch {
        try? executeRaw("ROLLBACK", connection: connection)
        throw error
      }
    }
  }

  private static func prepareBackupDestination(_ destinationURL: URL) throws {
    guard destinationURL.isFileURL else {
      throw SQLiteStoreError.unsafePath("backup URL must be a file URL")
    }
    try ensureDirectory(destinationURL.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      throw SQLiteStoreError.unsafePath("backup destination already exists")
    }
  }

  private static func backup(
    connection: SQLiteConnection,
    destinationURL: URL
  ) throws {
    guard let source = connection.handle else { throw SQLiteStoreError.closed }
    var destination: OpaquePointer?
    let result = sqlite3_open_v2(
      destinationURL.path,
      &destination,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let destination else {
      if let destination { sqlite3_close_v2(destination) }
      throw SQLiteStoreError.backupFailed("could not open backup destination")
    }
    defer { sqlite3_close_v2(destination) }

    guard let operation = sqlite3_backup_init(destination, "main", source, "main") else {
      throw SQLiteStoreError.backupFailed(
        String(cString: sqlite3_errmsg(destination))
      )
    }
    let stepResult = sqlite3_backup_step(operation, -1)
    let finishResult = sqlite3_backup_finish(operation)
    guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
      throw SQLiteStoreError.backupFailed(
        String(cString: sqlite3_errmsg(destination))
      )
    }
    try enforceDatabasePermissions(destinationURL)
  }

  private static func enforceDatabasePermissions(_ databaseURL: URL) throws {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: databaseURL.path
    )
    for suffix in ["-wal", "-shm"] {
      let path = databaseURL.path + suffix
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: path
        )
      }
    }
  }

  @discardableResult
  private static func execute(
    _ sql: String,
    bindings: [SQLiteValue] = [],
    connection: SQLiteConnection
  ) throws -> Int {
    guard let handle = connection.handle else { throw SQLiteStoreError.closed }
    let statement = try prepare(sql, connection: connection)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement, connection: connection)
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else { throw statementError(connection) }
    return Int(sqlite3_changes(handle))
  }

  private static func query(
    _ sql: String,
    bindings: [SQLiteValue] = [],
    connection: SQLiteConnection
  ) throws -> [SQLiteRow] {
    let statement = try prepare(sql, connection: connection)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement, connection: connection)

    var rows: [SQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else { throw statementError(connection) }
      var values: [String: SQLiteValue] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, index))
        values[name] = columnValue(statement, index: index)
      }
      rows.append(SQLiteRow(values: values))
    }
  }

  private static func scalarInt(
    _ sql: String,
    connection: SQLiteConnection
  ) throws -> Int64? {
    let rows = try query(sql, connection: connection)
    guard let row = rows.first, let column = row.columns.first else { return nil }
    guard case .integer(let value)? = row[column] else {
      throw SQLiteStoreError.unexpectedResult("expected integer scalar")
    }
    return value
  }

  private static func prepare(
    _ sql: String,
    connection: SQLiteConnection
  ) throws -> OpaquePointer {
    guard let handle = connection.handle else { throw SQLiteStoreError.closed }
    var statement: OpaquePointer?
    let prepared: (result: Int32, remainder: String) = sql.withCString { sqlPointer in
      var tail: UnsafePointer<CChar>?
      let result = sqlite3_prepare_v2(
        handle,
        sqlPointer,
        -1,
        &statement,
        &tail
      )
      return (result, tail.map(String.init(cString:)) ?? "")
    }
    guard prepared.result == SQLITE_OK, let statement else {
      if let statement { sqlite3_finalize(statement) }
      throw statementError(connection)
    }
    let remainder = prepared.remainder.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if !remainder.isEmpty {
      sqlite3_finalize(statement)
      throw SQLiteStoreError.unexpectedResult("multiple SQL statements are not allowed")
    }
    return statement
  }

  private static func bind(
    _ bindings: [SQLiteValue],
    to statement: OpaquePointer,
    connection: SQLiteConnection
  ) throws {
    guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
      throw SQLiteStoreError.unexpectedResult("binding count differs from SQL")
    }
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let integer):
        result = sqlite3_bind_int64(statement, index, integer)
      case .real(let real):
        result = sqlite3_bind_double(statement, index, real)
      case .text(let text):
        guard text.utf8.count <= Int32.max else {
          throw SQLiteStoreError.unexpectedResult("text binding is too large")
        }
        result = text.withCString { pointer in
          sqlite3_bind_text(
            statement,
            index,
            pointer,
            Int32(text.utf8.count),
            sqliteTransientDestructor()
          )
        }
      case .blob(let data):
        guard data.count <= Int32.max else {
          throw SQLiteStoreError.unexpectedResult("blob binding is too large")
        }
        result = data.withUnsafeBytes { bytes in
          sqlite3_bind_blob(
            statement,
            index,
            bytes.baseAddress,
            Int32(bytes.count),
            sqliteTransientDestructor()
          )
        }
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw statementError(connection) }
    }
  }

  private static func columnValue(
    _ statement: OpaquePointer,
    index: Int32
  ) -> SQLiteValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER:
      return .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT:
      return .real(sqlite3_column_double(statement, index))
    case SQLITE_TEXT:
      guard let pointer = sqlite3_column_text(statement, index) else { return .null }
      let count = Int(sqlite3_column_bytes(statement, index))
      return .text(
        String(
          decoding: UnsafeBufferPointer(start: pointer, count: count),
          as: UTF8.self
        )
      )
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
        return .blob(Data())
      }
      return .blob(Data(bytes: pointer, count: count))
    default:
      return .null
    }
  }

  private static func executeRaw(
    _ sql: String,
    connection: SQLiteConnection
  ) throws {
    guard let handle = connection.handle else { throw SQLiteStoreError.closed }
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
    if result != SQLITE_OK {
      let message =
        errorPointer.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorPointer)
      throw SQLiteStoreError.statementFailed(code: result, message: message)
    }
  }

  private static func statementError(
    _ connection: SQLiteConnection
  ) -> SQLiteStoreError {
    guard let handle = connection.handle else { return .closed }
    return .statementFailed(
      code: sqlite3_errcode(handle),
      message: String(cString: sqlite3_errmsg(handle))
    )
  }
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
  unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
