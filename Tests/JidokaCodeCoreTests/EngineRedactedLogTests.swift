import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Redacted engine log")
struct EngineRedactedLogTests {
  @Test("log accepts only closed event fields and rotates private files")
  func closedVocabularyAndRotation() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = try EngineRedactedLogger(rootURL: root, filename: "engine.jsonl")
    let sentinel = "github_pat_log_secret"
    await logger.record(
      EngineLogRecord(
        timestamp: Date(timeIntervalSince1970: 500_000),
        event: .commandRejected,
        command: .replaceCredential,
        error: .credentialRejected
      )
    )
    let data = try Data(contentsOf: logger.fileURL)
    #expect(!data.contains(Data(sentinel.utf8)))
    let line = try #require(data.split(separator: 0x0A).first)
    let decoded = try JSONDecoder().decode(EngineLogRecord.self, from: Data(line))
    #expect(decoded.command == .replaceCredential)
    #expect(decoded.error == .credentialRejected)
    #expect(try fileMode(logger.fileURL) == 0o600)

    try Data(repeating: 0, count: EngineRedactedLogger.maximumBytes).write(to: logger.fileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: logger.fileURL.path)
    await logger.record(
      EngineLogRecord(
        timestamp: Date(timeIntervalSince1970: 500_001),
        event: .commandSucceeded,
        command: .snapshot,
        error: nil
      )
    )
    #expect(FileManager.default.fileExists(atPath: logger.archiveURL.path))
    #expect(try fileMode(logger.archiveURL) == 0o600)
    #expect(try Data(contentsOf: logger.fileURL).count < 1_024)
    let linked = root.appendingPathComponent("linked-engine.jsonl")
    try FileManager.default.linkItem(at: logger.fileURL, to: linked)
    let sizeBeforeRejectedAppend = try Data(contentsOf: logger.fileURL).count
    await logger.record(
      EngineLogRecord(
        timestamp: Date(timeIntervalSince1970: 500_002),
        event: .commandSucceeded,
        command: .snapshot,
        error: nil
      )
    )
    #expect(try Data(contentsOf: logger.fileURL).count == sizeBeforeRejectedAppend)
  }

  @Test("unsafe directory and filename fail closed")
  func unsafePaths() throws {
    let target = temporaryRoot()
    let link = target.deletingLastPathComponent()
      .appendingPathComponent("jidoka-log-link-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: target)
    }
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: EngineRedactedLogError.unsafeDirectory) {
      _ = try EngineRedactedLogger(rootURL: link, filename: "engine.jsonl")
    }
    #expect(throws: EngineRedactedLogError.unsafeDirectory) {
      _ = try EngineRedactedLogger(rootURL: target, filename: "arbitrary.log")
    }
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-log-\(UUID().uuidString)", isDirectory: true)
  }

  private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
