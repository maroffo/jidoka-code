import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Attested external Herdr readiness", .serialized)
struct HerdrRuntimeReadinessTests {
  @Test("resolver binds executable, version, schema, and credentialless argv")
  func resolverContract() async throws {
    let fixture = try HerdrResolverFixture()
    defer { fixture.remove() }
    let process = HerdrResolverProcessFake(
      version: fixture.versionOutput,
      schema: fixture.schemaData
    )
    let resolved = try await HerdrRuntimeResolver(
      configuration: fixture.configuration,
      process: process
    ).resolve()

    #expect(resolved.version == "0.8.0")
    #expect(resolved.protocolVersion == 19)
    #expect(resolved.executable == fixture.executable)
    #expect(resolved.executableSHA256 == fixture.executableSHA256)
    #expect(resolved.apiSchemaSHA256 == fixture.schemaSHA256)
    #expect(resolved.policySHA256 == fixture.policySHA256)
    let requests = await process.requests
    #expect(requests.map(\.arguments) == [["--version"], ["api", "schema", "--json"]])
    #expect(requests.allSatisfy { $0.executable == fixture.executable })
    #expect(requests.allSatisfy { $0.workingDirectory.path == "/" })
    let expectedEnvironmentKeys = Set([
      "DEVELOPER_DIR", "GIT_ASKPASS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
      "GIT_SSH_COMMAND", "GIT_TERMINAL_PROMPT", "HOME", "LANG", "LC_ALL", "PATH", "TMPDIR",
    ])
    #expect(requests.allSatisfy { Set($0.environment.keys) == expectedEnvironmentKeys })
    #expect(requests.allSatisfy { $0.environment["HOME"] == "/var/empty" })
    #expect(requests.allSatisfy { $0.environment["TMPDIR"] == "/tmp" })
    #expect(requests.allSatisfy { $0.environment["GIT_ASKPASS"] == "/usr/bin/false" })
    #expect(requests.allSatisfy { $0.environment["GIT_SSH_COMMAND"] == "/usr/bin/false" })
  }

  @Test("binary and schema drift fail before readiness")
  func driftFailsClosed() async throws {
    let executableFixture = try HerdrResolverFixture()
    defer { executableFixture.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableFixture.executable.path
    )
    try Data("changed-herdr".utf8).write(to: executableFixture.executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: executableFixture.executable.path
    )
    let executableProcess = HerdrResolverProcessFake(
      version: executableFixture.versionOutput,
      schema: executableFixture.schemaData
    )
    await #expect(throws: HerdrRuntimeResolutionError.executableDigestMismatch) {
      _ = try await HerdrRuntimeResolver(
        configuration: executableFixture.configuration,
        process: executableProcess
      ).resolve()
    }
    #expect(await executableProcess.requests.isEmpty)

    let schemaFixture = try HerdrResolverFixture(
      policySchemaSHA256: String(repeating: "0", count: 64))
    defer { schemaFixture.remove() }
    let schemaProcess = HerdrResolverProcessFake(
      version: schemaFixture.versionOutput,
      schema: schemaFixture.schemaData
    )
    await #expect(throws: HerdrRuntimeResolutionError.schemaDigestMismatch) {
      _ = try await HerdrRuntimeResolver(
        configuration: schemaFixture.configuration,
        process: schemaProcess
      ).resolve()
    }
    #expect(await schemaProcess.requests.isEmpty)
  }

  @Test("CLI output must be byte-identical to the packaged schema")
  func commandOutputMismatch() async throws {
    let fixture = try HerdrResolverFixture()
    defer { fixture.remove() }
    let process = HerdrResolverProcessFake(
      version: fixture.versionOutput,
      schema: Data("{}\n".utf8)
    )
    await #expect(throws: HerdrRuntimeResolutionError.schemaOutputMismatch) {
      _ = try await HerdrRuntimeResolver(
        configuration: fixture.configuration,
        process: process
      ).resolve()
    }
  }

  @Test("readiness requires attestation before the fixed handshake")
  func readinessOrdering() async throws {
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.0",
      protocolVersion: 19,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.0/bin/herdr"),
      executableSHA256: String(repeating: "e", count: 64),
      apiSchemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
    let handshaker = HerdrReadinessHandshakerFake()
    let ready = await HerdrRuntimeReadinessChecker(
      resolver: HerdrReadinessResolverFake(result: .success(attestation)),
      handshaker: handshaker
    ).preflight()
    #expect(ready.state == .ready)
    #expect(ready.version == "0.8.0")
    #expect(ready.protocolVersion == 19)
    #expect(await handshaker.calls == 1)

    let neverCalled = HerdrReadinessHandshakerFake()
    let blocked = await HerdrRuntimeReadinessChecker(
      resolver: HerdrReadinessResolverFake(result: .failure(.executableDigestMismatch)),
      handshaker: neverCalled
    ).preflight()
    #expect(blocked.state == .blocked)
    #expect(blocked.issueCode == .executableMismatch)
    #expect(await neverCalled.calls == 0)
  }

  @Test("socket and compatibility failures become actionable closed states")
  func readinessErrors() async throws {
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.0",
      protocolVersion: 19,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.0/bin/herdr"),
      executableSHA256: String(repeating: "e", count: 64),
      apiSchemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
    for (error, code) in [
      (HerdrSocketClientError.unsafeSocket as Error, EngineHerdrIssueCode.unsafeSocket),
      (HerdrSocketClientError.connectionClosed as Error, .socketUnavailable),
      (HerdrCompatibilityError.versionMismatch as Error, .versionMismatch),
      (HerdrCompatibilityError.protocolMismatch as Error, .protocolMismatch),
      (HerdrCompatibilityError.missingLiveHandoff as Error, .capabilityMismatch),
    ] {
      let status = await HerdrRuntimeReadinessChecker(
        resolver: HerdrReadinessResolverFake(result: .success(attestation)),
        handshaker: HerdrReadinessHandshakerFake(error: error)
      ).preflight()
      #expect(status.state == .blocked)
      #expect(status.issueCode == code)
      #expect(status.summary?.isEmpty == false)
      #expect(status.recovery?.isEmpty == false)
    }
  }

  @Test("the installed external CLI matches the packaged offline policy")
  func installedRuntime() async throws {
    let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/Herdr", isDirectory: true)
    let attestation = try await HerdrRuntimeResolver(
      configuration: .standard(resourceRoot: resources)
    ).resolve()
    #expect(attestation.version == "0.8.0")
    #expect(attestation.protocolVersion == 19)
    #expect(
      attestation.executableSHA256
        == "97bdb194a731262d2b70062621a5673b1cd409b9e6870df361bd65799217eaf3"
    )
    #expect(
      attestation.apiSchemaSHA256
        == "88ff414aa996e390c2db05a37b95d28dbe4e81b98329f6ed7f7a2cc5c6ebf51a"
    )
  }
}

private final class HerdrResolverFixture: @unchecked Sendable {
  let root: URL
  let resources: URL
  let executable: URL
  let configuration: HerdrRuntimeResolverConfiguration
  let schemaData: Data
  let versionOutput = Data("herdr 0.8.0\n".utf8)
  let executableSHA256: String
  let schemaSHA256: String
  let policySHA256: String

  init(policySchemaSHA256: String? = nil) throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-herdr-readiness-\(UUID().uuidString)", isDirectory: true)
    resources = root.appendingPathComponent("Resources", isDirectory: true)
    executable = root.appendingPathComponent("herdr", isDirectory: false)
    try FileManager.default.createDirectory(
      at: resources,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let executableData = Data("fixture-herdr-executable".utf8)
    try executableData.write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: executable.path
    )
    executableSHA256 = Self.sha256(executableData)

    schemaData = try JSONSerialization.data(
      withJSONObject: [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "Herdr API",
        "protocol": 19,
        "schema_version": 1,
        "schemas": [
          "error_response": [:],
          "event": [:],
          "request": [:],
          "subscription_event": [:],
          "success_response": [:],
        ],
      ],
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    schemaSHA256 = Self.sha256(schemaData)
    let schemaURL = resources.appendingPathComponent("api-schema-0.8.0.json")
    try schemaData.write(to: schemaURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: schemaURL.path
    )

    let policyData = try JSONSerialization.data(
      withJSONObject: [
        "builds": [
          [
            "apiSchemaResource": "api-schema-0.8.0.json",
            "apiSchemaSHA256": policySchemaSHA256 ?? schemaSHA256,
            "architecture": "arm64",
            "executableSHA256": executableSHA256,
            "protocolVersion": 19,
            "version": "0.8.0",
          ]
        ],
        "schemaVersion": 1,
      ],
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    policySHA256 = Self.sha256(policyData)
    let policyURL = resources.appendingPathComponent("runtime-builds.json")
    try policyData.write(to: policyURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: policyURL.path
    )
    configuration = try HerdrRuntimeResolverConfiguration(
      resourceRoot: resources,
      executableLink: executable
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private actor HerdrResolverProcessFake: GitProcessExecuting {
  private let version: Data
  private let schema: Data
  private(set) var requests: [GitProcessRequest] = []

  init(version: Data, schema: Data) {
    self.version = version
    self.schema = schema
  }

  func run(_ request: GitProcessRequest) -> GitProcessResult {
    requests.append(request)
    let output = request.arguments == ["--version"] ? version : schema
    return GitProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      stdout: output,
      stderr: Data(),
      durationSeconds: 0.01
    )
  }
}

private struct HerdrReadinessResolverFake: HerdrRuntimeResolving {
  let result: Result<HerdrRuntimeAttestation, HerdrRuntimeResolutionError>

  func resolve() throws -> HerdrRuntimeAttestation {
    try result.get()
  }
}

private actor HerdrReadinessHandshakerFake: HerdrRuntimeHandshaking {
  private let error: Error?
  private(set) var calls = 0

  init(error: Error? = nil) {
    self.error = error
  }

  func handshake() throws -> HerdrHandshake {
    calls += 1
    if let error { throw error }
    return HerdrHandshake(
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
        device: 1,
        inode: 2,
        owner: UInt32(geteuid()),
        permissions: 0o600
      )
    )
  }
}
