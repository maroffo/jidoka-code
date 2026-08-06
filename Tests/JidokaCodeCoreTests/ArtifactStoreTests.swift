import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Contained artifact store")
struct ArtifactStoreTests {
  @Test("write and read persist typed digest evidence with strict permissions")
  func roundTrip() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    let artifactID = UUID()
    let producerID = UUID()
    let payload = Data("synthetic-result".utf8)
    let record = try await fixture.artifacts.write(
      id: artifactID,
      jobID: fixture.jobID,
      kind: .output,
      data: payload,
      classification: .synthetic,
      producerRunID: producerID,
      now: fixture.now
    )
    #expect(
      record.relativePath
        == "\(fixture.jobID.uuidString.lowercased())/\(artifactID.uuidString.lowercased()).json")
    #expect(record.sha256.count == 64)
    #expect(record.producerRunID == producerID)
    #expect(try await fixture.artifacts.read(id: artifactID) == payload)
    #expect(try await fixture.artifacts.records(jobID: fixture.jobID) == [record])

    let jobDirectory = fixture.artifactRoot.appendingPathComponent(
      fixture.jobID.uuidString.lowercased()
    )
    let fileURL = fixture.artifactRoot.appendingPathComponent(record.relativePath)
    #expect(try artifactFileMode(fixture.artifactRoot) == 0o700)
    #expect(try artifactFileMode(jobDirectory) == 0o700)
    #expect(try artifactFileMode(fileURL) == 0o600)
  }

  @Test("mutated artifact fails digest verification")
  func mutationFails() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    let record = try await fixture.artifacts.write(
      jobID: fixture.jobID,
      kind: .verification,
      data: Data("original".utf8),
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: fixture.now
    )
    let fileURL = fixture.artifactRoot.appendingPathComponent(record.relativePath)
    try Data("mutated".utf8).write(to: fileURL)
    await #expect(throws: ArtifactStoreError.digestMismatch) {
      _ = try await fixture.artifacts.read(id: record.id)
    }
  }

  @Test("symlink and persisted traversal paths fail closed")
  func pathAttacksFail() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    let record = try await fixture.artifacts.write(
      jobID: fixture.jobID,
      kind: .diagnostic,
      data: Data("inside".utf8),
      classification: .sensitiveMetadata,
      producerRunID: nil,
      now: fixture.now
    )
    let fileURL = fixture.artifactRoot.appendingPathComponent(record.relativePath)
    let external = fixture.root.appendingPathComponent("external")
    try Data("outside".utf8).write(to: external)
    try FileManager.default.removeItem(at: fileURL)
    try FileManager.default.createSymbolicLink(
      at: fileURL,
      withDestinationURL: external
    )
    await #expect(throws: ArtifactStoreError.unsafeArtifactPath) {
      _ = try await fixture.artifacts.read(id: record.id)
    }

    try await fixture.database.execute(
      "UPDATE artifacts SET relative_path = '../external' WHERE id = ?",
      bindings: [.text(record.id.uuidString.lowercased())]
    )
    await #expect(throws: ArtifactStoreError.unsafeArtifactPath) {
      _ = try await fixture.artifacts.read(id: record.id)
    }
  }

  @Test("secret-classified and oversized payloads are rejected before write")
  func forbiddenPayloads() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    await #expect(throws: ArtifactStoreError.secretDataForbidden) {
      _ = try await fixture.artifacts.write(
        jobID: fixture.jobID,
        kind: .input,
        data: Data("must-not-write".utf8),
        classification: .secretForbidden,
        producerRunID: nil,
        now: fixture.now
      )
    }
    await #expect(throws: ArtifactStoreError.artifactTooLarge) {
      _ = try await fixture.artifacts.write(
        jobID: fixture.jobID,
        kind: .input,
        data: Data(repeating: 0, count: 10 * 1_024 * 1_024 + 1),
        classification: .synthetic,
        producerRunID: nil,
        now: fixture.now
      )
    }
    #expect(try await fixture.artifacts.records(jobID: fixture.jobID).isEmpty)
    let jobDirectory = fixture.artifactRoot.appendingPathComponent(
      fixture.jobID.uuidString.lowercased()
    )
    if FileManager.default.fileExists(atPath: jobDirectory.path) {
      let contents = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
      #expect(contents.isEmpty)
    }
  }

  @Test("exclusive-write collision preserves the unowned existing file")
  func collisionPreservesExistingFile() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    let artifactID = UUID()
    let jobDirectory = fixture.artifactRoot.appendingPathComponent(
      fixture.jobID.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: false)
    let destination = jobDirectory.appendingPathComponent(
      "\(artifactID.uuidString.lowercased()).json"
    )
    let existing = Data("existing".utf8)
    try existing.write(to: destination)

    await #expect(throws: ArtifactStoreError.artifactAlreadyExists) {
      _ = try await fixture.artifacts.write(
        id: artifactID,
        jobID: fixture.jobID,
        kind: .output,
        data: Data("replacement".utf8),
        classification: .synthetic,
        producerRunID: nil,
        now: fixture.now
      )
    }
    #expect(try Data(contentsOf: destination) == existing)
  }

  @Test("invalid job and database failure leave no newly written file")
  func databaseFailureCleansFile() async throws {
    let fixture = try await ArtifactFixture()
    defer { fixture.remove() }
    let missingJobID = UUID()
    await #expect(throws: ArtifactStoreError.invalidJobID) {
      _ = try await fixture.artifacts.write(
        jobID: missingJobID,
        kind: .output,
        data: Data("orphan".utf8),
        classification: .synthetic,
        producerRunID: nil,
        now: fixture.now
      )
    }
    let missingDirectory = fixture.artifactRoot.appendingPathComponent(
      missingJobID.uuidString.lowercased()
    )
    #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))

    let artifactID = UUID()
    let relativePath =
      "\(fixture.jobID.uuidString.lowercased())/\(artifactID.uuidString.lowercased()).json"
    try await fixture.database.execute(
      """
      INSERT INTO artifacts(
        id, job_id, kind, relative_path, sha256,
        redaction_classification, created_at
      ) VALUES (?, ?, 'output', ?, ?, 'synthetic', ?)
      """,
      bindings: [
        .text(artifactID.uuidString.lowercased()),
        .text(fixture.jobID.uuidString.lowercased()),
        .text(relativePath),
        .text(String(repeating: "0", count: 64)),
        .real(fixture.now.timeIntervalSince1970),
      ]
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.artifacts.write(
        id: artifactID,
        jobID: fixture.jobID,
        kind: .output,
        data: Data("must-be-removed".utf8),
        classification: .synthetic,
        producerRunID: nil,
        now: fixture.now
      )
    }
    let directory = fixture.artifactRoot.appendingPathComponent(
      fixture.jobID.uuidString.lowercased()
    )
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents.isEmpty)
  }
}

private final class ArtifactFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let artifactRoot: URL
  let database: SQLiteStore
  let artifacts: ArtifactStore
  let jobID: UUID
  let now = Date(timeIntervalSince1970: 50_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-artifact-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    artifactRoot = root.appendingPathComponent("Artifacts", isDirectory: true)
    database = try SQLiteStore(databaseURL: databaseURL)
    let repositoryID = UUID()
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', 'repo', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text("node-\(repositoryID.uuidString.lowercased())"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    jobID = UUID()
    try await database.execute(
      """
      INSERT INTO jobs(
        id, repository_id, kind, object_node_id, revision_key,
        contract_version_used, priority, state, created_at, updated_at
      ) VALUES (?, ?, 'prReview', 'object', 'revision', 'v1', 2, 'queued', ?, ?)
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .text(repositoryID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    artifacts = try ArtifactStore(rootURL: artifactRoot, database: database)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func artifactFileMode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
