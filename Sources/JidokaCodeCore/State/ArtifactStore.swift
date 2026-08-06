import CryptoKit
import Darwin
import Foundation

public enum ArtifactKind: String, CaseIterable, Codable, Sendable {
  case input
  case output
  case diff
  case verification
  case review
  case diagnostic

  fileprivate var fileExtension: String {
    switch self {
    case .input, .output, .review: "json"
    case .diff: "diff"
    case .verification, .diagnostic: "log"
    }
  }
}

public enum ArtifactRedactionClassification: String, CaseIterable, Codable, Sendable {
  case `public`
  case synthetic
  case sensitiveMetadata
  case secretForbidden
}

public struct ArtifactRecord: Equatable, Sendable {
  public let id: UUID
  public let jobID: UUID
  public let kind: ArtifactKind
  public let relativePath: String
  public let sha256: String
  public let classification: ArtifactRedactionClassification
  public let producerRunID: UUID?
  public let createdAt: Date
}

public enum ArtifactStoreError: Error, Equatable, Sendable {
  case unsafeRoot
  case invalidJobID
  case secretDataForbidden
  case artifactTooLarge
  case artifactAlreadyExists
  case writeFailed(Int32)
  case artifactNotFound(UUID)
  case unsafeArtifactPath
  case digestMismatch
  case decode(String)
}

public actor ArtifactStore {
  public nonisolated let rootURL: URL

  private static let maximumArtifactBytes = 10 * 1_024 * 1_024
  private let database: SQLiteStore

  public init(rootURL: URL, database: SQLiteStore) throws {
    guard rootURL.isFileURL else { throw ArtifactStoreError.unsafeRoot }
    try Self.ensureDirectory(rootURL)
    self.rootURL = rootURL
    self.database = database
  }

  public func write(
    id: UUID = UUID(),
    jobID: UUID,
    kind: ArtifactKind,
    data: Data,
    classification: ArtifactRedactionClassification,
    producerRunID: UUID?,
    now: Date
  ) async throws -> ArtifactRecord {
    guard classification != .secretForbidden else {
      throw ArtifactStoreError.secretDataForbidden
    }
    guard data.count <= Self.maximumArtifactBytes else {
      throw ArtifactStoreError.artifactTooLarge
    }
    let jobComponent = jobID.uuidString.lowercased()
    guard
      try await database.scalarInt(
        "SELECT COUNT(*) FROM jobs WHERE id = ?",
        bindings: [.text(jobComponent)]
      ) == 1
    else {
      throw ArtifactStoreError.invalidJobID
    }
    let jobDirectory = rootURL.appendingPathComponent(jobComponent, isDirectory: true)
    try Self.ensureDirectory(jobDirectory)
    let filename = "\(id.uuidString.lowercased()).\(kind.fileExtension)"
    let destination = jobDirectory.appendingPathComponent(filename)
    try Self.validateContained(destination, root: rootURL)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw ArtifactStoreError.artifactAlreadyExists
    }

    var ownsDestination = false
    do {
      try Self.writeExclusive(data, to: destination)
      ownsDestination = true
      let digest = Self.sha256(data)
      let relativePath = "\(jobComponent)/\(filename)"
      _ = try await database.execute(
        """
        INSERT INTO artifacts(
          id, job_id, kind, relative_path, sha256,
          redaction_classification, producer_run_id, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(id.uuidString.lowercased()),
          .text(jobComponent),
          .text(kind.rawValue),
          .text(relativePath),
          .text(digest),
          .text(classification.rawValue),
          producerRunID.map { .text($0.uuidString.lowercased()) } ?? .null,
          .real(now.timeIntervalSince1970),
        ]
      )
      return ArtifactRecord(
        id: id,
        jobID: jobID,
        kind: kind,
        relativePath: relativePath,
        sha256: digest,
        classification: classification,
        producerRunID: producerRunID,
        createdAt: now
      )
    } catch {
      if ownsDestination {
        try? FileManager.default.removeItem(at: destination)
      }
      throw error
    }
  }

  public func read(id: UUID) async throws -> Data {
    let record = try await record(id: id)
    let destination = try Self.resolve(
      relativePath: record.relativePath,
      expectedJobID: record.jobID,
      expectedArtifactID: record.id,
      expectedKind: record.kind,
      root: rootURL
    )
    let values = try destination.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ArtifactStoreError.unsafeArtifactPath
    }
    let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
    guard Self.sha256(data) == record.sha256 else {
      throw ArtifactStoreError.digestMismatch
    }
    return data
  }

  public func record(id: UUID) async throws -> ArtifactRecord {
    guard
      let row = try await database.query(
        "SELECT * FROM artifacts WHERE id = ?",
        bindings: [.text(id.uuidString.lowercased())]
      ).first
    else {
      throw ArtifactStoreError.artifactNotFound(id)
    }
    return try Self.decode(row)
  }

  public func records(jobID: UUID) async throws -> [ArtifactRecord] {
    try await database.query(
      "SELECT * FROM artifacts WHERE job_id = ? ORDER BY created_at, id",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).map(Self.decode)
  }

  private static func ensureDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw ArtifactStoreError.unsafeRoot }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw ArtifactStoreError.unsafeRoot
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

  private static func writeExclusive(_ data: Data, to destination: URL) throws {
    let descriptor = Darwin.open(
      destination.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      mode_t(S_IRUSR | S_IWUSR)
    )
    if descriptor == -1 {
      if errno == EEXIST { throw ArtifactStoreError.artifactAlreadyExists }
      throw ArtifactStoreError.writeFailed(errno)
    }
    var completed = false
    defer {
      Darwin.close(descriptor)
      if !completed { Darwin.unlink(destination.path) }
    }

    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let result = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if result == -1 {
          if errno == EINTR { continue }
          throw ArtifactStoreError.writeFailed(errno)
        }
        guard result > 0 else { throw ArtifactStoreError.writeFailed(EIO) }
        offset += result
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw ArtifactStoreError.writeFailed(errno)
    }
    completed = true
  }

  private static func validateContained(_ url: URL, root: URL) throws {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalParent = url.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL.path
    guard canonicalParent.hasPrefix(canonicalRoot + "/") else {
      throw ArtifactStoreError.unsafeArtifactPath
    }
  }

  private static func resolve(
    relativePath: String,
    expectedJobID: UUID,
    expectedArtifactID: UUID,
    expectedKind: ArtifactKind,
    root: URL
  ) throws -> URL {
    guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
      throw ArtifactStoreError.unsafeArtifactPath
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let expectedFilename =
      "\(expectedArtifactID.uuidString.lowercased()).\(expectedKind.fileExtension)"
    guard components.count == 2,
      components[0] == expectedJobID.uuidString.lowercased(),
      components[1] == Substring(expectedFilename)
    else {
      throw ArtifactStoreError.unsafeArtifactPath
    }
    let destination = root.appendingPathComponent(relativePath)
    try validateContained(destination, root: root)
    return destination
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func decode(_ row: SQLiteRow) throws -> ArtifactRecord {
    guard let id = UUID(uuidString: try text(row, "id")),
      let jobID = UUID(uuidString: try text(row, "job_id")),
      let kind = ArtifactKind(rawValue: try text(row, "kind")),
      let classification = ArtifactRedactionClassification(
        rawValue: try text(row, "redaction_classification")
      )
    else {
      throw ArtifactStoreError.decode("unknown artifact value")
    }
    return ArtifactRecord(
      id: id,
      jobID: jobID,
      kind: kind,
      relativePath: try text(row, "relative_path"),
      sha256: try text(row, "sha256"),
      classification: classification,
      producerRunID: try optionalText(row, "producer_run_id").flatMap(UUID.init(uuidString:)),
      createdAt: Date(timeIntervalSince1970: try real(row, "created_at"))
    )
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw ArtifactStoreError.decode("expected text column \(column)")
    }
    return value
  }

  private static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): value
    case .null: nil
    default: throw ArtifactStoreError.decode("expected optional text column \(column)")
    }
  }

  private static func real(_ row: SQLiteRow, _ column: String) throws -> Double {
    switch row[column] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: throw ArtifactStoreError.decode("expected real column \(column)")
    }
  }
}
