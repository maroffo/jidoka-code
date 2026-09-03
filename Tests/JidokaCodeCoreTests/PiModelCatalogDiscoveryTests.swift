import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Pi model catalog discovery boundary")
struct PiModelCatalogDiscoveryTests {
  @Test("release-owned direct request is exact, bounded, and source inputs remain unchanged")
  func requestBoundary() async throws {
    let fixture = try CatalogDiscoveryFixture()
    defer { fixture.remove() }
    let runner = CatalogProcessRecorder(output: Self.output)
    let scriptDigest = Self.sha256(try Data(contentsOf: fixture.script))
    let discovery = PiModelCatalogDiscovery(
      runtimeResolver: fixture.runtimeResolver,
      scriptURL: fixture.script,
      expectedScriptSHA256: scriptDigest,
      piAgentDirectory: fixture.agent,
      applicationSupportRoot: fixture.root,
      privateRuntimeRoot: fixture.privateRuntime,
      runner: runner
    )
    let sourceBefore = try Self.sha256(Data(contentsOf: fixture.sourceMarker))
    let scriptBefore = try Self.sha256(Data(contentsOf: fixture.script))
    let agentBefore = try Self.sha256(Data(contentsOf: fixture.auth))
    #expect(!(try PiTUIFileProtocol.safeRegularFile(fixture.script)))

    let catalog = try await discovery.discover()
    let request = try #require(await runner.lastRequest)

    #expect(catalog.models.map(\.selectionID) == ["fixture/model"])
    #expect(fixture.runtimeResolver.boundaryCounts == [.modelCatalogProcess: 1])
    #expect(
      fixture.runtimeResolver.releaseIdentities[.modelCatalogProcess]
        == [try #require(fixture.runtime.releaseIdentity)]
    )
    #expect(request.timeoutSeconds == 15)
    #expect(request.maximumOutputBytes == PiModelCatalogDecoder.maximumOutputBytes)
    let privateScript = try PiTUIFileProtocol.canonicalExistingURL(fixture.root)
      .appendingPathComponent("ModelCatalog/Scripts", isDirectory: true)
      .appendingPathComponent(scriptDigest, isDirectory: true)
      .appendingPathComponent("jidoka-model-catalog.mjs")
    #expect(request.arguments.first == privateScript.path)
    #expect(request.arguments.count == 2)
    #expect(try PiTUIFileProtocol.safePrivateFile(privateScript, maximumBytes: 1_048_576))
    #expect(try Self.fileMode(privateScript) == 0o400)
    #expect(request.executable == fixture.node)
    #expect(request.arguments[1] == fixture.packageRoot.path)
    #expect(request.workingDirectory == fixture.privateRuntime)
    #expect(
      Set(request.environment.keys)
        == Set([
          "GIT_ASKPASS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
          "GIT_SSH_COMMAND", "GIT_TERMINAL_PROMPT", "HOME", "LANG", "LC_ALL", "PATH",
          "PI_CODING_AGENT_DIR", "PI_OFFLINE", "PI_SKIP_VERSION_CHECK", "TMPDIR",
        ]))
    #expect(request.environment["PI_OFFLINE"] == "1")
    #expect(request.environment["PI_SKIP_VERSION_CHECK"] == "1")
    #expect(request.environment["PI_CODING_AGENT_DIR"] == fixture.agent.path)
    #expect(
      request.environment["HOME"]
        == fixture.privateRuntime.appendingPathComponent("home", isDirectory: true).path
    )
    #expect(request.environment["PATH"] == "/usr/bin:/bin")
    #expect(request.environment["LANG"] == "en_US.UTF-8")
    #expect(request.environment["LC_ALL"] == "en_US.UTF-8")
    #expect(request.environment["GIT_ASKPASS"] == "/usr/bin/false")
    #expect(request.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(request.environment["GIT_CONFIG_NOSYSTEM"] == "1")
    #expect(request.environment["GIT_SSH_COMMAND"] == "/usr/bin/false")
    #expect(request.environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(
      request.environment["TMPDIR"]
        == fixture.privateRuntime.appendingPathComponent("tmp", isDirectory: true).path
    )
    #expect(request.environment["DYLD_LIBRARY_PATH"] == nil)
    #expect(
      try PiTUIFileProtocol.safePrivateDirectory(URL(fileURLWithPath: request.environment["HOME"]!))
    )
    #expect(
      try PiTUIFileProtocol.safePrivateDirectory(
        URL(fileURLWithPath: request.environment["TMPDIR"]!)))
    #expect(try Self.sha256(Data(contentsOf: fixture.sourceMarker)) == sourceBefore)
    #expect(try Self.sha256(Data(contentsOf: fixture.script)) == scriptBefore)
    #expect(try Self.sha256(Data(contentsOf: fixture.auth)) == agentBefore)
  }

  @Test("mutated script and unsafe Pi agent directory fail before process execution")
  func rejectsUnsafeInputs() async throws {
    let fixture = try CatalogDiscoveryFixture()
    defer { fixture.remove() }
    let runner = CatalogProcessRecorder(output: Self.output)
    let expected = Self.sha256(try Data(contentsOf: fixture.script))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fixture.script.path
    )
    try Data("mutated\n".utf8).append(to: fixture.script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: fixture.script.path
    )
    let mutated = PiModelCatalogDiscovery(
      runtimeResolver: fixture.runtimeResolver,
      scriptURL: fixture.script,
      expectedScriptSHA256: expected,
      piAgentDirectory: fixture.agent,
      applicationSupportRoot: fixture.root,
      privateRuntimeRoot: fixture.privateRuntime,
      runner: runner
    )
    await #expect(throws: PiModelCatalogError.unavailable) {
      _ = try await mutated.discover()
    }
    #expect(await runner.requestCount == 0)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.agent.path
    )
    let unsafeAgent = PiModelCatalogDiscovery(
      runtimeResolver: fixture.runtimeResolver,
      scriptURL: fixture.validScript,
      expectedScriptSHA256: Self.sha256(try Data(contentsOf: fixture.validScript)),
      piAgentDirectory: fixture.agent,
      applicationSupportRoot: fixture.root,
      privateRuntimeRoot: fixture.privateRuntime,
      runner: runner
    )
    await #expect(throws: PiModelCatalogError.unavailable) {
      _ = try await unsafeAgent.discover()
    }
    #expect(await runner.requestCount == 0)
  }

  private static let output = Data(
    """
    {"schemaVersion":1,"models":[{"provider":"fixture","id":"model","name":"Fixture","reasoning":false,"input":["text"],"contextWindow":1,"maxTokens":1,"thinkingLevels":["off"]}]}
    """.utf8)

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}

private final class CatalogDiscoveryFixture: @unchecked Sendable {
  let root: URL
  let sourceRoot: URL
  let packagedResourceRoot: URL
  let packageRoot: URL
  let library: URL
  let sourceMarker: URL
  let node: URL
  let script: URL
  let validScript: URL
  let agent: URL
  let auth: URL
  let privateRuntime: URL
  let runtime: PiResolvedRuntime
  let runtimeResolver: CountingReleaseOwnedRuntimeResolver
  private let releaseRuntimeFixture: ReleaseOwnedRuntimeFixture

  init() throws {
    releaseRuntimeFixture = try ReleaseOwnedRuntimeFixture()
    runtimeResolver = try CountingReleaseOwnedRuntimeResolver(
      resolver: releaseRuntimeFixture.resolver()
    )
    runtime = try releaseRuntimeFixture.resolver().resolve()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-model-catalog-boundary-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    sourceRoot = root.appendingPathComponent("source", isDirectory: true)
    packagedResourceRoot = root.appendingPathComponent("packaged", isDirectory: true)
    packageRoot = runtime.piPackageRootURL
    library = sourceRoot.appendingPathComponent("libfixture.dylib")
    sourceMarker = sourceRoot.appendingPathComponent("pi/dist/cli.js")
    node = runtime.nodeURL
    script = packagedResourceRoot.appendingPathComponent("jidoka-model-catalog.mjs")
    validScript = packagedResourceRoot.appendingPathComponent(
      "valid/jidoka-model-catalog.mjs")
    agent = root.appendingPathComponent("agent", isDirectory: true)
    auth = agent.appendingPathComponent("auth.json")
    privateRuntime = root.appendingPathComponent("private", isDirectory: true)
    for directory in [
      root, sourceRoot, packagedResourceRoot,
      sourceMarker.deletingLastPathComponent(), validScript.deletingLastPathComponent(), agent,
      privateRuntime,
    ] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o775],
      ofItemAtPath: packagedResourceRoot.path
    )
    try Self.write(Data("library".utf8), to: library, permissions: 0o400)
    try Self.write(Data("{}\n".utf8), to: sourceMarker, permissions: 0o400)
    try Self.write(Data("probe\n".utf8), to: script, permissions: 0o400)
    try Self.write(Data("probe\n".utf8), to: validScript, permissions: 0o400)
    try Self.write(Data("{}\n".utf8), to: auth, permissions: 0o600)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
    releaseRuntimeFixture.remove()
  }

  private static func write(_ data: Data, to url: URL, permissions: Int) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: permissions)],
      ofItemAtPath: url.path
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private actor CatalogProcessRecorder: GitProcessExecuting {
  private let output: Data
  private(set) var lastRequest: GitProcessRequest?
  private(set) var requestCount = 0

  init(output: Data) {
    self.output = output
  }

  func run(_ request: GitProcessRequest) -> GitProcessResult {
    requestCount += 1
    lastRequest = request
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

extension Data {
  fileprivate func append(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: self)
  }
}
