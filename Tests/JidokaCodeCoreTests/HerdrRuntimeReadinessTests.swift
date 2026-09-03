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

    #expect(resolved.version == "0.8.2")
    #expect(resolved.protocolVersion == 20)
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
      version: "0.8.2",
      protocolVersion: 20,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr"),
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
    #expect(ready.version == "0.8.2")
    #expect(ready.protocolVersion == 20)
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

  @Test("readiness binds the connected peer to the attested executable")
  func readinessPeerBinding() async throws {
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.2",
      protocolVersion: 20,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr"),
      executableSHA256: String(repeating: "e", count: 64),
      apiSchemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
    let handshakers = [
      HerdrReadinessHandshakerFake(peerExecutablePath: nil),
      HerdrReadinessHandshakerFake(peerExecutablePath: "/tmp/unattested-herdr"),
      HerdrReadinessHandshakerFake(
        peerExecutableSHA256: String(repeating: "f", count: 64)
      ),
    ]
    for handshaker in handshakers {
      let status = await HerdrRuntimeReadinessChecker(
        resolver: HerdrReadinessResolverFake(result: .success(attestation)),
        handshaker: handshaker
      ).preflight()
      #expect(status.state == .blocked)
      #expect(status.issueCode == .unsafeSocket)
    }
  }

  @Test("socket and compatibility failures become actionable closed states")
  func readinessErrors() async throws {
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.2",
      protocolVersion: 20,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr"),
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

  @Test("the packaged external-CLI policy is deterministic without an installed runtime")
  func packagedRuntimePolicy() throws {
    let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/Herdr", isDirectory: true)
    let policyData = try Data(contentsOf: resources.appendingPathComponent("runtime-builds.json"))
    let schemaData = try Data(
      contentsOf: resources.appendingPathComponent("api-schema-0.8.2.json")
    )
    let policy = try #require(
      JSONSerialization.jsonObject(with: policyData) as? [String: Any]
    )
    let builds = try #require(policy["builds"] as? [[String: Any]])

    #expect(policy["schemaVersion"] as? Int == 1)
    #expect(builds.count == 1)
    #expect(builds[0]["version"] as? String == "0.8.2")
    #expect(builds[0]["protocolVersion"] as? Int == 20)
    #expect(
      SHA256.hash(data: schemaData).map { String(format: "%02x", $0) }.joined()
        == "c48f1f54ee0150ca27e11fd44455fe94aeadb20fdf4e4a62393ed822a4e5b150"
    )
  }

  @Test("installed readiness evidence binds release, socket, peer, and code twice")
  func installedReadinessEvidence() async throws {
    let releaseIdentity = try PiReleaseRuntimeIdentity(
      runtimeID: "node-26.7.0-pi-0.84.2-darwin-arm64-v1",
      manifestSHA256: String(repeating: "b", count: 64),
      canonicalRoot:
        "/Library/Application Support/JidokaCode/Applications/Jidoka Code.app/Contents/Resources/PiRuntime",
      rootDevice: 10,
      rootInode: 11,
      nodeCodeDirectorySHA256: String(repeating: "c", count: 64),
      piPackageTreeSHA256: String(repeating: "d", count: 64)
    )
    let releaseResolver = HerdrReleaseIdentitySequenceFake([
      releaseIdentity, releaseIdentity,
    ])
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.2",
      protocolVersion: 20,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr"),
      executableSHA256: String(repeating: "e", count: 64),
      apiSchemaSHA256: String(repeating: "f", count: 64),
      policySHA256: String(repeating: "1", count: 64)
    )
    let resolver = HerdrReadinessSequenceResolverFake([attestation, attestation])
    let handshaker = HerdrReadinessHandshakerFake()
    let report = try await HerdrRuntimeReadinessProbe(
      resolveReleaseRuntime: { try releaseResolver.resolve() },
      resolver: resolver,
      handshaker: handshaker
    ).inspect()

    #expect(report.schemaVersion == 1)
    #expect(report.releaseRuntime == releaseIdentity)
    #expect(report.herdr.version == "0.8.2")
    #expect(report.herdr.protocolVersion == 20)
    #expect(report.herdr.executablePath == attestation.executable.path)
    #expect(report.herdr.executableSHA256 == attestation.executableSHA256)
    #expect(report.socket.owner == UInt32(geteuid()))
    #expect(report.socket.permissions == 0o600)
    #expect(report.peer.processID == 12_345)
    #expect(report.peer.startSeconds == 100)
    #expect(report.peer.startMicroseconds == 200)
    #expect(report.peer.executablePath == attestation.executable.path)
    #expect(report.peer.executableSHA256 == attestation.executableSHA256)
    #expect(report.peer.code.identifier == "works.earendil.herdr.fixture")
    #expect(report.peer.code.teamIdentifier == nil)
    #expect(
      report.peer.code.designatedRequirementSHA256
        == SHA256.hash(data: Data("identifier works.earendil.herdr.fixture".utf8))
        .map { String(format: "%02x", $0) }.joined()
    )
    #expect(report.capabilities.liveHandoff)
    #expect(report.capabilities.detachedServerDaemon)
    #expect(report.snapshotWorkspaceCount == 0)
    #expect(report.snapshotTabCount == 0)
    #expect(report.snapshotPaneCount == 0)
    #expect(releaseResolver.calls == 2)
    #expect(await resolver.calls == 2)
    #expect(await handshaker.calls == 2)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let first = try encoder.encode(report)
    let second = try encoder.encode(report)
    #expect(first == second)
    #expect(first.count < 16_384)
    #expect(try JSONDecoder().decode(HerdrRuntimeReadinessProbeReport.self, from: first) == report)
  }

  @Test("installed readiness evidence rejects mid-probe authority drift")
  func installedReadinessDrift() async throws {
    let releaseIdentity = try PiReleaseRuntimeIdentity(
      runtimeID: "node-26.7.0-pi-0.84.2-darwin-arm64-v1",
      manifestSHA256: String(repeating: "b", count: 64),
      canonicalRoot:
        "/Library/Application Support/JidokaCode/Applications/Jidoka Code.app/Contents/Resources/PiRuntime",
      rootDevice: 10,
      rootInode: 11,
      nodeCodeDirectorySHA256: String(repeating: "c", count: 64),
      piPackageTreeSHA256: String(repeating: "d", count: 64)
    )
    let changedReleaseIdentity = try PiReleaseRuntimeIdentity(
      runtimeID: releaseIdentity.runtimeID,
      manifestSHA256: releaseIdentity.manifestSHA256,
      canonicalRoot: releaseIdentity.canonicalRoot,
      rootDevice: releaseIdentity.rootDevice,
      rootInode: 12,
      nodeCodeDirectorySHA256: releaseIdentity.nodeCodeDirectorySHA256,
      piPackageTreeSHA256: releaseIdentity.piPackageTreeSHA256
    )
    let attestation = HerdrRuntimeAttestation(
      version: "0.8.2",
      protocolVersion: 20,
      architecture: "arm64",
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr"),
      executableSHA256: String(repeating: "e", count: 64),
      apiSchemaSHA256: String(repeating: "f", count: 64),
      policySHA256: String(repeating: "1", count: 64)
    )
    let releaseResolver = HerdrReleaseIdentitySequenceFake([
      releaseIdentity, changedReleaseIdentity,
    ])
    await #expect(throws: PiRuntimeResolutionError.self) {
      _ = try await HerdrRuntimeReadinessProbe(
        resolveReleaseRuntime: { try releaseResolver.resolve() },
        resolver: HerdrReadinessSequenceResolverFake([attestation]),
        handshaker: HerdrReadinessHandshakerFake()
      ).inspect()
    }

    let changedHerdr = HerdrRuntimeAttestation(
      version: attestation.version,
      protocolVersion: attestation.protocolVersion,
      architecture: attestation.architecture,
      executable: attestation.executable,
      executableSHA256: attestation.executableSHA256,
      apiSchemaSHA256: attestation.apiSchemaSHA256,
      policySHA256: String(repeating: "2", count: 64)
    )
    let stableReleaseResolver = HerdrReleaseIdentitySequenceFake([
      releaseIdentity, releaseIdentity,
    ])
    await #expect(throws: HerdrRuntimeResolutionError.executableDigestMismatch) {
      _ = try await HerdrRuntimeReadinessProbe(
        resolveReleaseRuntime: { try stableReleaseResolver.resolve() },
        resolver: HerdrReadinessSequenceResolverFake([attestation, changedHerdr]),
        handshaker: HerdrReadinessHandshakerFake()
      ).inspect()
    }
  }
}

private final class HerdrResolverFixture: @unchecked Sendable {
  let root: URL
  let resources: URL
  let executable: URL
  let configuration: HerdrRuntimeResolverConfiguration
  let schemaData: Data
  let versionOutput = Data("herdr 0.8.2\n".utf8)
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
        "protocol": 20,
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
    let schemaURL = resources.appendingPathComponent("api-schema-0.8.2.json")
    try schemaData.write(to: schemaURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: schemaURL.path
    )

    let policyData = try JSONSerialization.data(
      withJSONObject: [
        "builds": [
          [
            "apiSchemaResource": "api-schema-0.8.2.json",
            "apiSchemaSHA256": policySchemaSHA256 ?? schemaSHA256,
            "architecture": "arm64",
            "executableSHA256": executableSHA256,
            "protocolVersion": 20,
            "version": "0.8.2",
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

private final class HerdrReleaseIdentitySequenceFake: @unchecked Sendable {
  private let lock = NSLock()
  private var identities: [PiReleaseRuntimeIdentity]
  private var callCount = 0

  init(_ identities: [PiReleaseRuntimeIdentity]) {
    self.identities = identities
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func resolve() throws -> PiReleaseRuntimeIdentity {
    lock.lock()
    defer { lock.unlock() }
    guard !identities.isEmpty else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "unexpected release runtime inspection"
      )
    }
    callCount += 1
    return identities.removeFirst()
  }
}

private actor HerdrReadinessSequenceResolverFake: HerdrRuntimeResolving {
  private var attestations: [HerdrRuntimeAttestation]
  private(set) var calls = 0

  init(_ attestations: [HerdrRuntimeAttestation]) {
    self.attestations = attestations
  }

  func resolve() throws -> HerdrRuntimeAttestation {
    guard !attestations.isEmpty else {
      throw HerdrRuntimeResolutionError.runtimeCommandFailed
    }
    calls += 1
    return attestations.removeFirst()
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
  private let peerExecutablePath: String?
  private let peerExecutableSHA256: String
  private(set) var calls = 0

  init(
    error: Error? = nil,
    peerExecutablePath: String? = "/opt/homebrew/Cellar/herdr/0.8.2/bin/herdr",
    peerExecutableSHA256: String = String(repeating: "e", count: 64)
  ) {
    self.error = error
    self.peerExecutablePath = peerExecutablePath
    self.peerExecutableSHA256 = peerExecutableSHA256
  }

  func handshake() throws -> HerdrHandshake {
    calls += 1
    if let error { throw error }
    let peerEvidence: HerdrConnectedPeerEvidence?
    if let peerExecutablePath {
      peerEvidence = try HerdrConnectedPeerEvidence(
        processID: 12_345,
        startSeconds: 100,
        startMicroseconds: 200,
        effectiveUserID: UInt32(geteuid()),
        executable: try HerdrProcessExecutableIdentity(
          path: peerExecutablePath,
          device: 3,
          inode: 4,
          contentSHA256: peerExecutableSHA256,
          codeIdentity: try HerdrExecutableCodeIdentity(
            identifier: "works.earendil.herdr.fixture",
            teamIdentifier: nil,
            codeDirectoryHashSHA256: String(repeating: "a", count: 64),
            designatedRequirement: "identifier works.earendil.herdr.fixture"
          )
        )
      )
    } else {
      peerEvidence = nil
    }
    return HerdrHandshake(
      pong: HerdrPong(
        version: "0.8.2",
        protocolVersion: 20,
        capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
      ),
      snapshot: HerdrSessionSnapshot(
        version: "0.8.2",
        protocolVersion: 20,
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
        permissions: 0o600,
        peerEvidence: peerEvidence
      )
    )
  }
}
