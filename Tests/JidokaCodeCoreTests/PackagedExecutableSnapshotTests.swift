import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Packaged executable private snapshot")
struct PackagedExecutableSnapshotTests {
  @Test("descriptor-bound source becomes an exact private executable snapshot")
  func exactPrivateSnapshot() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    let sourceData = Data("#!/bin/sh\nexit 0\n".utf8)
    try fixture.writeSource(sourceData)
    #expect(try PiTUIFileProtocol.safePrivateDirectory(fixture.applicationSupport))

    let snapshot = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: fixture.source,
      applicationSupportRoot: fixture.applicationSupport,
      signatureValidator: { _ in true }
    )
    let reused = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: fixture.source,
      applicationSupportRoot: fixture.applicationSupport,
      signatureValidator: { _ in true }
    )

    #expect(snapshot == reused)
    let canonicalApplicationSupport = try PiTUIFileProtocol.canonicalExistingURL(
      fixture.applicationSupport)
    #expect(snapshot.path.hasPrefix(canonicalApplicationSupport.path + "/Runtime/"))
    #expect(try Data(contentsOf: snapshot) == sourceData)
    #expect(try fileMode(snapshot) == 0o500)
    #expect(try PiTUIFileProtocol.safeRegularFile(snapshot))
  }

  @Test("signature rejection occurs before a private snapshot is created")
  func signatureRejection() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("unsigned executable".utf8))

    #expect(throws: PackagedExecutableSnapshotError.invalidSignature) {
      _ = try PackagedExecutableSnapshot.prepareHerdrHost(
        sourceURL: fixture.source,
        applicationSupportRoot: fixture.applicationSupport,
        signatureValidator: { _ in false }
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.applicationSupport.appendingPathComponent("Runtime").path)
    )
  }

  @Test("private destination must independently satisfy the signature policy")
  func destinationSignatureRejection() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("signed source executable".utf8))
    var validated: [URL] = []

    #expect(throws: PackagedExecutableSnapshotError.invalidSignature) {
      _ = try PackagedExecutableSnapshot.prepareHerdrHost(
        sourceURL: fixture.source,
        applicationSupportRoot: fixture.applicationSupport,
        signatureValidator: { candidate in
          validated.append(candidate)
          return candidate == fixture.source
        }
      )
    }
    #expect(validated.count == 2)
    #expect(validated.first == fixture.source)
    let destination = try #require(validated.last)
    #expect(
      destination.path.hasPrefix(try fixture.canonicalApplicationSupport().path + "/Runtime/"))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("signature cleanup never unlinks a swapped destination inode")
  func destinationSwapDuringRejection() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("signed source before destination swap".utf8))
    let replacement = Data("replacement private inode".utf8)
    var destination: URL?

    #expect(throws: PackagedExecutableSnapshotError.invalidSignature) {
      _ = try PackagedExecutableSnapshot.prepareHerdrHost(
        sourceURL: fixture.source,
        applicationSupportRoot: fixture.applicationSupport,
        signatureValidator: { candidate in
          guard candidate != fixture.source else { return true }
          destination = candidate
          let held = candidate.deletingLastPathComponent().appendingPathComponent("held-host")
          try? FileManager.default.moveItem(at: candidate, to: held)
          try? replacement.write(to: candidate, options: .withoutOverwriting)
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: candidate.path
          )
          return false
        }
      )
    }
    let swapped = try #require(destination)
    #expect(try Data(contentsOf: swapped) == replacement)
  }

  @Test("prepared and staging crash artifacts recover to one exact snapshot")
  func preparedCrashRecovery() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    let data = Data("crash-safe executable".utf8)
    try fixture.writeSource(data)
    let paths = try fixture.snapshotPaths(for: data)
    try data.write(to: paths.prepared, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: paths.prepared.path
    )
    try Data("stale staging".utf8).write(to: paths.staging, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: paths.staging.path
    )

    let snapshot = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: fixture.source,
      applicationSupportRoot: fixture.applicationSupport,
      signatureValidator: { _ in true }
    )

    let expected = try PiTUIFileProtocol.canonicalExistingURL(paths.destination)
    #expect(snapshot == expected)
    #expect(try Data(contentsOf: snapshot) == data)
    #expect(try fileMode(snapshot) == 0o500)
    #expect(!FileManager.default.fileExists(atPath: paths.prepared.path))
  }

  @Test("an exact final file from a pre-chmod crash resumes to executable mode")
  func finalFileCrashRecovery() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    let data = Data("pre-chmod executable".utf8)
    try fixture.writeSource(data)
    let paths = try fixture.snapshotPaths(for: data)
    try PiTUIFileProtocol.createPrivateFile(data: data, at: paths.destination)
    #expect(try fileMode(paths.destination) == 0o600)

    let snapshot = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: fixture.source,
      applicationSupportRoot: fixture.applicationSupport,
      signatureValidator: { _ in true }
    )

    let expected = try PiTUIFileProtocol.canonicalExistingURL(paths.destination)
    #expect(snapshot == expected)
    #expect(try fileMode(snapshot) == 0o500)
  }

  @Test("a source path swap during signature validation fails closed")
  func sourcePathSwap() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("original executable".utf8))
    let held = fixture.source.deletingLastPathComponent()
      .appendingPathComponent("held-host")

    #expect(throws: PackagedExecutableSnapshotError.unsafeSource) {
      _ = try PackagedExecutableSnapshot.prepareHerdrHost(
        sourceURL: fixture.source,
        applicationSupportRoot: fixture.applicationSupport,
        signatureValidator: { candidate in
          if candidate == fixture.source {
            try? FileManager.default.moveItem(at: fixture.source, to: held)
            try? fixture.writeSource(Data("replacement executable".utf8))
          }
          return true
        }
      )
    }
  }

  @Test("an existing divergent digest path is never overwritten")
  func divergentSnapshot() throws {
    let fixture = try SnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("stable executable".utf8))
    let snapshot = try PackagedExecutableSnapshot.prepareHerdrHost(
      sourceURL: fixture.source,
      applicationSupportRoot: fixture.applicationSupport,
      signatureValidator: { _ in true }
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: snapshot.path
    )
    try Data("divergent".utf8).write(to: snapshot)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: snapshot.path
    )

    #expect(throws: PackagedExecutableSnapshotError.unsafeDestination) {
      _ = try PackagedExecutableSnapshot.prepareHerdrHost(
        sourceURL: fixture.source,
        applicationSupportRoot: fixture.applicationSupport,
        signatureValidator: { _ in true }
      )
    }
    #expect(try Data(contentsOf: snapshot) == Data("divergent".utf8))
  }

  private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}

private final class SnapshotFixture: @unchecked Sendable {
  let root: URL
  let source: URL
  let applicationSupport: URL

  init() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-host-snapshot-\(UUID().uuidString)", isDirectory: true)
    let packagedParent = root.appendingPathComponent("packaged", isDirectory: true)
    source = packagedParent.appendingPathComponent("JidokaCodeHerdrHost")
    applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path
    )
    try FileManager.default.createDirectory(
      at: packagedParent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o775]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775],
      ofItemAtPath: packagedParent.path
    )
    try PrivateDirectoryBoundary.ensure(applicationSupport)
  }

  func writeSource(_ data: Data) throws {
    try data.write(to: source, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: source.path
    )
  }

  func canonicalApplicationSupport() throws -> URL {
    try PiTUIFileProtocol.canonicalExistingURL(applicationSupport)
  }

  func snapshotPaths(for data: Data) throws -> SnapshotPaths {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let applicationSupport = try canonicalApplicationSupport()
    let runtime = applicationSupport.appendingPathComponent("Runtime", isDirectory: true)
    let snapshots = runtime.appendingPathComponent("HerdrHostSnapshots", isDirectory: true)
    let version = snapshots.appendingPathComponent(digest, isDirectory: true)
    for directory in [runtime, snapshots, version] {
      try PrivateDirectoryBoundary.ensure(directory)
    }
    let destination = version.appendingPathComponent("JidokaCodeHerdrHost")
    return SnapshotPaths(
      destination: destination,
      prepared: version.appendingPathComponent(".JidokaCodeHerdrHost.prepared"),
      staging: version.appendingPathComponent(".JidokaCodeHerdrHost.crash.staging")
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct SnapshotPaths {
  let destination: URL
  let prepared: URL
  let staging: URL
}
