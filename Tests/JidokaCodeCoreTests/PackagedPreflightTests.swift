import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Packaged preflight")
struct PackagedPreflightTests {
  private let validManifest = Data(#"{"name":"jidoka-code","schemaVersion":1}"#.utf8)

  @Test("valid manifest produces exact attributable evidence")
  func validManifestProducesGoldenDigest() throws {
    let fixture = try Fixture(manifest: validManifest)
    defer { fixture.remove() }

    let report = try inspect(fixture)

    #expect(report.status == "ok")
    #expect(report.resourceName == "jidoka-code")
    #expect(report.schemaVersion == 1)
    #expect(report.workingDirectory == "/")
    #expect(
      report.manifestSHA256 == "f097dfd8d13e4f7c5e5aecdf2b723296b6ef0ef9189ba502e6a4d5db7dd41489")
  }

  @Test("one-byte manifest change changes digest")
  func manifestChangeChangesDigest() throws {
    let fixture = try Fixture(manifest: validManifest + Data(" ".utf8))
    defer { fixture.remove() }

    #expect(
      try inspect(fixture).manifestSHA256
        != "f097dfd8d13e4f7c5e5aecdf2b723296b6ef0ef9189ba502e6a4d5db7dd41489")
  }

  @Test("unexpected bundle identity fails closed")
  func unexpectedBundleIdentity() throws {
    let fixture = try Fixture(manifest: validManifest)
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.unexpectedBundleIdentifier("other")) {
      try PackagedPreflight.inspect(
        bundleURL: fixture.bundleURL,
        bundleIdentifier: "other",
        workingDirectory: "/"
      )
    }
  }

  @Test("missing manifest fails closed")
  func missingManifest() throws {
    let fixture = try Fixture(manifest: nil)
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.manifestMissing) {
      try inspect(fixture)
    }
  }

  @Test("every unsupported schema fails closed", arguments: [-1, 0, 2, Int.max])
  func unsupportedSchema(schemaVersion: Int) throws {
    let manifest = Data("{\"name\":\"jidoka-code\",\"schemaVersion\":\(schemaVersion)}".utf8)
    let fixture = try Fixture(manifest: manifest)
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.unsupportedSchema(schemaVersion)) {
      try inspect(fixture)
    }
  }

  @Test(
    "malformed or incomplete manifest fails closed",
    arguments: [
      Data(),
      Data("{".utf8),
      Data(#"{"name":"jidoka-code"}"#.utf8),
      Data(#"{"name":1,"schemaVersion":1}"#.utf8),
      Data(#"{"name":"jidoka-code","schemaVersion":"1"}"#.utf8),
    ])
  func malformedManifest(manifest: Data) throws {
    let fixture = try Fixture(manifest: manifest)
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.manifestInvalid) {
      try inspect(fixture)
    }
  }

  @Test("unexpected resource name fails closed")
  func unexpectedResourceName() throws {
    let fixture = try Fixture(manifest: Data(#"{"name":"other","schemaVersion":1}"#.utf8))
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.unexpectedResourceName("other")) {
      try inspect(fixture)
    }
  }

  @Test("oversized manifest fails before decoding")
  func oversizedManifest() throws {
    let fixture = try Fixture(manifest: Data(repeating: 0x20, count: 65_537))
    defer { fixture.remove() }

    #expect(throws: PackagedPreflightError.manifestTooLarge(65_537)) {
      try inspect(fixture)
    }
  }

  @Test("manifest symbolic link is rejected")
  func manifestSymbolicLink() throws {
    let fixture = try Fixture(manifest: nil)
    defer { fixture.remove() }
    try fixture.installManifestSymbolicLink(to: validManifest)

    #expect(throws: PackagedPreflightError.resourcePathInvalid) {
      try inspect(fixture)
    }
  }

  @Test("resource-directory symbolic link is rejected")
  func resourceDirectorySymbolicLink() throws {
    let fixture = try Fixture(manifest: nil)
    defer { fixture.remove() }
    try fixture.installResourceDirectorySymbolicLink(with: validManifest)

    #expect(throws: PackagedPreflightError.resourcePathInvalid) {
      try inspect(fixture)
    }
  }

  private func inspect(_ fixture: Fixture) throws -> PackagedPreflightReport {
    try PackagedPreflight.inspect(
      bundleURL: fixture.bundleURL,
      bundleIdentifier: PackagedPreflight.expectedBundleIdentifier,
      workingDirectory: "/"
    )
  }
}

private struct Fixture {
  let rootURL: URL
  let bundleURL: URL
  let resourcesURL: URL
  let piURL: URL
  let manifestURL: URL

  init(manifest: Data?) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("jidoka-preflight-\(UUID().uuidString)", isDirectory: true)
    bundleURL = rootURL.appendingPathComponent("Probe.app", isDirectory: true)
    resourcesURL =
      bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
    piURL = resourcesURL.appendingPathComponent("Pi", isDirectory: true)
    manifestURL = piURL.appendingPathComponent("manifest.json", isDirectory: false)
    try FileManager.default.createDirectory(at: piURL, withIntermediateDirectories: true)
    if let manifest {
      try manifest.write(to: manifestURL)
    }
  }

  func installManifestSymbolicLink(to data: Data) throws {
    let externalURL = rootURL.appendingPathComponent("external-manifest.json")
    try data.write(to: externalURL)
    try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: externalURL)
  }

  func installResourceDirectorySymbolicLink(with data: Data) throws {
    try FileManager.default.removeItem(at: piURL)
    let externalDirectory = rootURL.appendingPathComponent("external-pi", isDirectory: true)
    try FileManager.default.createDirectory(
      at: externalDirectory, withIntermediateDirectories: true)
    try data.write(to: externalDirectory.appendingPathComponent("manifest.json"))
    try FileManager.default.createSymbolicLink(at: piURL, withDestinationURL: externalDirectory)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
