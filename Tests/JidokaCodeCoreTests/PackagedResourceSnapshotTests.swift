import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Packaged resource private snapshot")
struct PackagedResourceSnapshotTests {
  @Test("an exact script under a group-writable ancestor becomes one private snapshot")
  func exactPrivateSnapshot() throws {
    let fixture = try ResourceSnapshotFixture()
    defer { fixture.remove() }
    let data = Data("export const catalog = true;\n".utf8)
    try fixture.writeSource(data)
    let digest = Self.sha256(data)
    #expect(!(try PiTUIFileProtocol.safeRegularFile(fixture.source)))

    let snapshot = try PackagedResourceSnapshot.prepareModelCatalogScript(
      sourceURL: fixture.source,
      expectedSHA256: digest,
      applicationSupportRoot: fixture.applicationSupport
    )
    let reused = try PackagedResourceSnapshot.prepareModelCatalogScript(
      sourceURL: fixture.source,
      expectedSHA256: digest,
      applicationSupportRoot: fixture.applicationSupport
    )

    #expect(snapshot == reused)
    let expectedSnapshot = try fixture.snapshotPaths(for: data).destination
    #expect(snapshot == expectedSnapshot)
    #expect(try Data(contentsOf: snapshot) == data)
    #expect(try Self.fileMode(snapshot) == 0o400)
    #expect(try PiTUIFileProtocol.safePrivateFile(snapshot, maximumBytes: 1_048_576))
    let privateRoot = try PiTUIFileProtocol.canonicalExistingURL(fixture.applicationSupport)
    let snapshotDirectories = [
      privateRoot.appendingPathComponent("ModelCatalog", isDirectory: true),
      privateRoot.appendingPathComponent("ModelCatalog/Scripts", isDirectory: true),
      snapshot.deletingLastPathComponent(),
    ]
    for directory in snapshotDirectories {
      #expect(try Self.fileMode(directory) == 0o700)
      #expect(try PiTUIFileProtocol.safePrivateDirectory(directory))
    }
  }

  @Test("an existing non-private destination ancestor is rejected")
  func unsafeDestinationAncestor() throws {
    let fixture = try ResourceSnapshotFixture()
    defer { fixture.remove() }
    let data = Data("stable script\n".utf8)
    try fixture.writeSource(data)
    let modelCatalog = fixture.applicationSupport.appendingPathComponent(
      "ModelCatalog", isDirectory: true)
    try FileManager.default.createDirectory(
      at: modelCatalog,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o775]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775],
      ofItemAtPath: modelCatalog.path
    )

    #expect(throws: PackagedResourceSnapshotError.unsafeDestination) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: fixture.source,
        expectedSHA256: Self.sha256(data),
        applicationSupportRoot: fixture.applicationSupport
      )
    }
    #expect(
      !FileManager.default.fileExists(atPath: modelCatalog.appendingPathComponent("Scripts").path))
  }

  @Test("a digest mismatch creates no private catalog directory")
  func digestMismatch() throws {
    let fixture = try ResourceSnapshotFixture()
    defer { fixture.remove() }
    try fixture.writeSource(Data("mutated script\n".utf8))

    #expect(throws: PackagedResourceSnapshotError.digestMismatch) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: fixture.source,
        expectedSHA256: String(repeating: "a", count: 64),
        applicationSupportRoot: fixture.applicationSupport
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.applicationSupport.appendingPathComponent("ModelCatalog").path
      ))
  }

  @Test("source symlinks, hard links, and path swaps fail closed")
  func unsafeSourceIdentity() throws {
    let symlinkFixture = try ResourceSnapshotFixture()
    defer { symlinkFixture.remove() }
    let data = Data("stable script\n".utf8)
    let target = symlinkFixture.packagedRoot.appendingPathComponent("target.mjs")
    try data.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: symlinkFixture.source,
      withDestinationURL: target
    )
    #expect(throws: PackagedResourceSnapshotError.unsafeSource) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: symlinkFixture.source,
        expectedSHA256: Self.sha256(data),
        applicationSupportRoot: symlinkFixture.applicationSupport
      )
    }

    let hardLinkFixture = try ResourceSnapshotFixture()
    defer { hardLinkFixture.remove() }
    try hardLinkFixture.writeSource(data)
    try FileManager.default.linkItem(
      at: hardLinkFixture.source,
      to: hardLinkFixture.packagedRoot.appendingPathComponent("linked-script.mjs")
    )
    #expect(throws: PackagedResourceSnapshotError.unsafeSource) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: hardLinkFixture.source,
        expectedSHA256: Self.sha256(data),
        applicationSupportRoot: hardLinkFixture.applicationSupport
      )
    }

    let swapFixture = try ResourceSnapshotFixture()
    defer { swapFixture.remove() }
    try swapFixture.writeSource(data)
    let held = swapFixture.packagedRoot.appendingPathComponent("held-script.mjs")
    #expect(throws: PackagedResourceSnapshotError.unsafeSource) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: swapFixture.source,
        expectedSHA256: Self.sha256(data),
        applicationSupportRoot: swapFixture.applicationSupport,
        sourceInspection: { _ in
          try FileManager.default.moveItem(at: swapFixture.source, to: held)
          try swapFixture.writeSource(data)
        }
      )
    }
  }

  @Test("prepared crash state recovers without overwriting divergent final data")
  func crashRecoveryAndDivergence() throws {
    let fixture = try ResourceSnapshotFixture()
    defer { fixture.remove() }
    let data = Data("crash-safe script\n".utf8)
    try fixture.writeSource(data)
    let paths = try fixture.snapshotPaths(for: data)
    try data.write(to: paths.prepared, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: paths.prepared.path
    )

    let snapshot = try PackagedResourceSnapshot.prepareModelCatalogScript(
      sourceURL: fixture.source,
      expectedSHA256: Self.sha256(data),
      applicationSupportRoot: fixture.applicationSupport
    )
    #expect(snapshot == paths.destination)
    #expect(!FileManager.default.fileExists(atPath: paths.prepared.path))
    #expect(try Self.fileMode(snapshot) == 0o400)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: snapshot.path
    )
    let divergent = Data("divergent private data\n".utf8)
    try divergent.write(to: snapshot)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: snapshot.path
    )
    #expect(throws: PackagedResourceSnapshotError.unsafeDestination) {
      _ = try PackagedResourceSnapshot.prepareModelCatalogScript(
        sourceURL: fixture.source,
        expectedSHA256: Self.sha256(data),
        applicationSupportRoot: fixture.applicationSupport
      )
    }
    #expect(try Data(contentsOf: snapshot) == divergent)
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}

private final class ResourceSnapshotFixture: @unchecked Sendable {
  let root: URL
  let packagedRoot: URL
  let source: URL
  let applicationSupport: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-resource-snapshot-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    packagedRoot = root.appendingPathComponent("packaged", isDirectory: true)
    source = packagedRoot.appendingPathComponent("jidoka-model-catalog.mjs")
    applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path
    )
    try FileManager.default.createDirectory(
      at: packagedRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o775]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775],
      ofItemAtPath: packagedRoot.path
    )
    try PrivateDirectoryBoundary.ensure(applicationSupport)
  }

  func writeSource(_ data: Data) throws {
    try data.write(to: source, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: source.path
    )
  }

  func snapshotPaths(for data: Data) throws -> ResourceSnapshotPaths {
    let digest = PackagedResourceSnapshotTests.sha256(data)
    let applicationSupport = try PiTUIFileProtocol.canonicalExistingURL(self.applicationSupport)
    let modelCatalog = applicationSupport.appendingPathComponent(
      "ModelCatalog", isDirectory: true)
    let scripts = modelCatalog.appendingPathComponent("Scripts", isDirectory: true)
    let version = scripts.appendingPathComponent(digest, isDirectory: true)
    for directory in [modelCatalog, scripts, version] {
      try PrivateDirectoryBoundary.ensure(directory)
    }
    return ResourceSnapshotPaths(
      destination: version.appendingPathComponent("jidoka-model-catalog.mjs"),
      prepared: version.appendingPathComponent(".jidoka-model-catalog.mjs.prepared")
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct ResourceSnapshotPaths {
  let destination: URL
  let prepared: URL
}
