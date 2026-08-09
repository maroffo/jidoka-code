import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Single UI instance lock")
struct SingleInstanceLockTests {
  @Test("one owner holds the lock and release permits a later owner")
  func exclusiveLifetime() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var first: SingleInstanceLock? = try SingleInstanceLock(directoryURL: root)
    #expect(first?.ownsLock == true)
    let second = try SingleInstanceLock(directoryURL: root)
    #expect(!second.ownsLock)
    let engine = try SingleInstanceLock(
      directoryURL: root,
      filename: "engine-instance.lock"
    )
    #expect(engine.ownsLock)
    first?.release()
    let third = try SingleInstanceLock(directoryURL: root)
    #expect(third.ownsLock)
    first = nil
  }

  @Test("symbolic links and permissive directories fail closed")
  func unsafePaths() throws {
    let parent = temporaryRoot().deletingLastPathComponent()
    let target = temporaryRoot()
    let link = parent.appendingPathComponent("jidoka-instance-link-\(UUID().uuidString)")
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
    #expect(throws: SingleInstanceLockError.unsafeDirectory) {
      _ = try SingleInstanceLock(directoryURL: link)
    }
    #expect(throws: PrivateDirectoryBoundaryError.unsafePath) {
      try PrivateDirectoryBoundary.ensure(link)
    }

    let permissive = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: permissive) }
    try FileManager.default.createDirectory(
      at: permissive,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: permissive.path)
    #expect(throws: SingleInstanceLockError.unsafeDirectory) {
      _ = try SingleInstanceLock(directoryURL: permissive)
    }
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-instance-\(UUID().uuidString)", isDirectory: true)
  }
}
