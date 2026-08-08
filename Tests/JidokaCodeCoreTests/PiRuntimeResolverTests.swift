import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Digest-attested Pi and Node runtime resolver")
struct PiRuntimeResolverTests {
  @Test("Finder-style symlinks resolve to exact attested Pi and Node builds")
  func resolvesAttestedSymlinks() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }

    let runtime = try fixture.resolver().resolve()

    #expect(runtime.piVersion.description == "0.84.0")
    #expect(runtime.nodeVersion.description == "26.6.0")
    #expect(runtime.piCLIURL == fixture.cliURL)
    #expect(runtime.nodeURL == fixture.nodeURL)
    #expect(runtime.piRuntimeSHA256.count == 5)
    #expect(runtime.piRuntimeSHA256["package-tree-v1"]?.count == 64)
    #expect(runtime.nodeDynamicLibrarySHA256.count == 1)
    #expect(runtime.compatibility.minimumVersion.description == "0.84.0")
    #expect(runtime.compatibility.maximumVersionExclusive.description == "0.90.0")
    #expect(runtime.compatibility.policySHA256.count == 64)
  }

  @Test("range membership never authorizes an unattested Pi build")
  func unattestedInRangeBuild() throws {
    let fixture = try RuntimeResolverFixture(piVersion: "0.84.1")
    defer { fixture.remove() }

    #expect(throws: PiRuntimeResolutionError.self) {
      try fixture.resolver().resolve()
    }
    guard case .blocked(let issue) = fixture.resolver().preflight() else {
      Issue.record("unattested build unexpectedly passed preflight")
      return
    }
    #expect(issue.code == .unattestedPiBuild)
    #expect(issue.recovery.contains("exact supported Pi build"))
  }

  @Test("exclusive maximum and lower versions are rejected before digest acceptance")
  func unsupportedVersions() throws {
    for version in ["0.83.9", "0.90.0"] {
      let fixture = try RuntimeResolverFixture(piVersion: version)
      defer { fixture.remove() }
      do {
        _ = try fixture.resolver().resolve()
        Issue.record("unsupported Pi version passed: \(version)")
      } catch let error as PiRuntimeResolutionError {
        #expect(error.code == .unsupportedPiVersion)
      }
    }
  }

  @Test("one changed executable package byte outside the critical subset fails closed")
  func changedPiPackageByte() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let mainURL = fixture.packageRootURL.appendingPathComponent("dist/main.js")
    try Data("main-mutated".utf8).write(to: mainURL)

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("mutated package tree passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedPiBuild)
    }
  }

  @Test("one changed critical runtime byte fails closed")
  func changedPiRuntimeByte() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let sdkURL = fixture.packageRootURL.appendingPathComponent("dist/core/sdk.js")
    try Data("sdk-mutated".utf8).write(to: sdkURL)

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("mutated runtime passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedPiBuild)
    }
  }

  @Test("critical runtime symbolic links are rejected even with matching bytes")
  func runtimeSymbolicLink() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let sdkURL = fixture.packageRootURL.appendingPathComponent("dist/core/sdk.js")
    let externalURL = fixture.rootURL.appendingPathComponent("external-sdk.js")
    try FileManager.default.moveItem(at: sdkURL, to: externalURL)
    try FileManager.default.createSymbolicLink(at: sdkURL, withDestinationURL: externalURL)

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("symbolic runtime file passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedPiBuild)
    }
  }

  @Test("Node executable must match an exact packaged digest")
  func unattestedNode() throws {
    let fixture = try RuntimeResolverFixture(attestNode: false)
    defer { fixture.remove() }

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("unattested Node passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedNodeBuild)
    }
  }

  @Test("Node rpath resolution rejects an earlier unpinned shadow library")
  func nodeRPathShadow() throws {
    let fixture = try RuntimeResolverFixture(shadowNodeLibrary: true)
    defer { fixture.remove() }

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("earlier unpinned Node rpath candidate passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedNodeBuild)
    }
  }

  @Test("Node dependency closure rejects missing and additional policy entries")
  func exactNodeDependencyClosure() throws {
    for fixture in [
      try RuntimeResolverFixture(includeNodeLibraryInPolicy: false),
      try RuntimeResolverFixture(nodeLoadsLibrary: false),
    ] {
      defer { fixture.remove() }
      do {
        _ = try fixture.resolver().resolve()
        Issue.record("inexact Node dependency closure passed")
      } catch let error as PiRuntimeResolutionError {
        #expect(error.code == .unattestedNodeBuild)
      }
    }
  }

  @Test("one changed Node dynamic-library byte fails closed")
  func changedNodeLibrary() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    try Data("mutated-node-library".utf8).write(to: fixture.nodeLibraryURL)

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("mutated Node dynamic library passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unattestedNodeBuild)
    }
  }

  @Test("absolute Pi shebang binds the exact canonical Node executable")
  func absoluteShebang() throws {
    let fixture = try RuntimeResolverFixture(absoluteNodeShebang: true)
    defer { fixture.remove() }

    #expect(try fixture.resolver().resolve().nodeURL == fixture.nodeURL)
  }

  @Test("malformed compatibility policy produces an actionable packaged-app failure")
  func malformedPolicy() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    try Data(#"{"schemaVersion":2}"#.utf8).write(to: fixture.piPolicyURL)

    guard case .blocked(let issue) = fixture.resolver().preflight() else {
      Issue.record("malformed policy unexpectedly passed")
      return
    }
    #expect(issue.code == .malformedCompatibilityPolicy)
    #expect(issue.summary.contains("packaged runtime policy"))
    #expect(issue.recovery.contains("Reinstall or update Jidoka Code"))
  }

  @Test("one Node digest cannot ambiguously attest two version labels")
  func duplicateNodeDigest() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.nodePolicyURL))
        as? [String: Any]
    )
    let builds = try #require(object["builds"] as? [String: Any])
    let build = try #require(builds["26.6.0"] as? [String: Any])
    let policy: [String: Any] = [
      "builds": ["26.6.0": build, "26.6.1": build],
      "runtime": "node",
      "schemaVersion": 2,
    ]
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])
      .write(to: fixture.nodePolicyURL)

    do {
      _ = try fixture.resolver().resolve()
      Issue.record("ambiguous Node policy unexpectedly passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .malformedCompatibilityPolicy)
    }
  }

  @Test("system Pi and Node resolve through the packaged compatibility policies")
  func systemRuntime() throws {
    let resourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .resolvingSymlinksInPath()
    let runtime = try PiRuntimeResolver(
      configuration: .standard(resourceRoot: resourceRoot)
    ).resolve()

    #expect(runtime.piVersion.description == "0.84.0")
    #expect(runtime.nodeVersion.description == "26.6.0")
    #expect(runtime.piRuntimeSHA256.count == 5)
    #expect(runtime.nodeDynamicLibrarySHA256.count == 25)
    #expect(
      runtime.nodeSHA256
        == "1ef99ea25fe70c9b67e7efe768ef8ee22148d3cabc703db6131b57aeb617d040"
    )
  }

  @Test("semantic versions reject prefixes, prereleases, and leading zeroes")
  func strictSemanticVersion() {
    for value in ["v0.84.0", "0.84", "00.84.0", "0.84.0-beta.1"] {
      #expect(throws: PiRuntimeResolutionError.self) {
        try PiSemanticVersion(value)
      }
    }
  }
}

private final class RuntimeResolverFixture {
  let rootURL: URL
  let packageRootURL: URL
  let cliURL: URL
  let nodeURL: URL
  let nodeLibraryURL: URL
  let piPolicyURL: URL
  let nodePolicyURL: URL
  private let piLinkURL: URL
  private let nodeLinkURL: URL

  init(
    piVersion: String = "0.84.0",
    attestNode: Bool = true,
    absoluteNodeShebang: Bool = false,
    nodeLoadsLibrary: Bool = true,
    includeNodeLibraryInPolicy: Bool = true,
    shadowNodeLibrary: Bool = false
  ) throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-pi-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
    packageRootURL = rootURL.appendingPathComponent("pi-package", isDirectory: true)
    cliURL = packageRootURL.appendingPathComponent("dist/cli.js")
    nodeURL = rootURL.appendingPathComponent("node-26.6.0")
    nodeLibraryURL = rootURL.appendingPathComponent("libnode-fixture.dylib")
    piPolicyURL = rootURL.appendingPathComponent("pi-runtime-builds.json")
    nodePolicyURL = rootURL.appendingPathComponent("node-runtime-builds.json")
    piLinkURL = rootURL.appendingPathComponent("bin/pi")
    nodeLinkURL = rootURL.appendingPathComponent("bin/node")

    try FileManager.default.createDirectory(
      at: cliURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageRootURL.appendingPathComponent("dist/core"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: packageRootURL.appendingPathComponent(
        "node_modules/@earendil-works/pi-ai/dist/api"
      ),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: piLinkURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let dependency =
      shadowNodeLibrary
      ? "@rpath/\(nodeLibraryURL.lastPathComponent)" : nodeLibraryURL.path
    let nodeData = Self.machO(
      dependencies: nodeLoadsLibrary ? [dependency] : [],
      rpaths: shadowNodeLibrary ? ["@loader_path/shadow", "@loader_path"] : []
    )
    let nodeLibraryData = Self.machO(dependencies: [])
    try nodeData.write(to: nodeURL)
    try nodeLibraryData.write(to: nodeLibraryURL)
    if shadowNodeLibrary {
      let shadowDirectory = rootURL.appendingPathComponent("shadow", isDirectory: true)
      try FileManager.default.createDirectory(
        at: shadowDirectory, withIntermediateDirectories: true)
      try Self.machO(dependencies: []).write(
        to: shadowDirectory.appendingPathComponent(nodeLibraryURL.lastPathComponent)
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: nodeURL.path
    )
    let shebang =
      absoluteNodeShebang
      ? "#!\(nodeURL.path)\n"
      : "#!/usr/bin/env node\n"
    let runtimeFiles: [String: Data] = [
      "dist/cli.js": Data("\(shebang)console.log('pi');\n".utf8),
      "dist/core/sdk.js": Data("sdk".utf8),
      "dist/main.js": Data("main".utf8),
      "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js":
        Data("codex".utf8),
      "package.json": Data(
        "{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"\(piVersion)\"}\n".utf8
      ),
    ]
    for (relativePath, data) in runtimeFiles {
      let url = packageRootURL.appendingPathComponent(relativePath)
      try data.write(to: url)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: cliURL.path
    )
    try FileManager.default.createSymbolicLink(at: piLinkURL, withDestinationURL: cliURL)
    try FileManager.default.createSymbolicLink(at: nodeLinkURL, withDestinationURL: nodeURL)

    let attestedFiles: [String: Data] = [
      "dist/cli.js": runtimeFiles["dist/cli.js"]!,
      "dist/core/sdk.js": runtimeFiles["dist/core/sdk.js"]!,
      "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js":
        runtimeFiles[
          "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js"
        ]!,
      "package.json": piVersion == "0.84.0"
        ? runtimeFiles["package.json"]!
        : Data(
          "{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"0.84.0\"}\n".utf8
        ),
    ]
    let criticalFiles = attestedFiles.mapValues(Self.sha256)
    let packageTree = try PiRuntimeResolver.attestPackageTree(
      packageRootURL.resolvingSymlinksInPath()
    )
    let piPolicy: [String: Any] = [
      "builds": [
        "0.84.0": [
          "criticalFiles": criticalFiles,
          "packageTree": [
            "entryCount": packageTree.entryCount,
            "sha256": packageTree.sha256,
          ],
        ]
      ],
      "maximumVersionExclusive": "0.90.0",
      "minimumVersion": "0.84.0",
      "package": "@earendil-works/pi-coding-agent",
      "schemaVersion": 2,
    ]
    try JSONSerialization.data(withJSONObject: piPolicy, options: [.sortedKeys])
      .write(to: piPolicyURL)
    let nodePolicy: [String: Any] = [
      "builds": [
        "26.6.0": [
          "dynamicLibraries": includeNodeLibraryInPolicy
            ? [
              [
                "canonicalPath": nodeLibraryURL.path,
                "loadPath": nodeLibraryURL.path,
                "sha256": Self.sha256(nodeLibraryData),
              ]
            ] : [],
          "executable": [
            "canonicalPath": nodeURL.path,
            "sha256": attestNode ? Self.sha256(nodeData) : String(repeating: "a", count: 64),
          ],
        ]
      ],
      "runtime": "node",
      "schemaVersion": 2,
    ]
    try JSONSerialization.data(withJSONObject: nodePolicy, options: [.sortedKeys])
      .write(to: nodePolicyURL)
  }

  private static func machO(
    dependencies: [String],
    rpaths: [String] = []
  ) -> Data {
    let dependencyCommands = dependencies.map { dependency -> Data in
      let string = Data(dependency.utf8) + Data([0])
      let commandSize = ((24 + string.count + 7) / 8) * 8
      var command = Data()
      appendUInt32(0x0000_000C, to: &command)
      appendUInt32(UInt32(commandSize), to: &command)
      appendUInt32(24, to: &command)
      appendUInt32(0, to: &command)
      appendUInt32(0, to: &command)
      appendUInt32(0, to: &command)
      command.append(string)
      command.append(Data(repeating: 0, count: commandSize - command.count))
      return command
    }
    let rpathCommands = rpaths.map { rpath -> Data in
      let string = Data(rpath.utf8) + Data([0])
      let commandSize = ((12 + string.count + 7) / 8) * 8
      var command = Data()
      appendUInt32(0x8000_001C, to: &command)
      appendUInt32(UInt32(commandSize), to: &command)
      appendUInt32(12, to: &command)
      command.append(string)
      command.append(Data(repeating: 0, count: commandSize - command.count))
      return command
    }
    let commands = dependencyCommands + rpathCommands
    var data = Data()
    appendUInt32(0xFEED_FACF, to: &data)
    appendUInt32(0x0100_000C, to: &data)
    appendUInt32(0, to: &data)
    appendUInt32(2, to: &data)
    appendUInt32(UInt32(commands.count), to: &data)
    appendUInt32(UInt32(commands.reduce(0) { $0 + $1.count }), to: &data)
    appendUInt32(0, to: &data)
    appendUInt32(0, to: &data)
    for command in commands { data.append(command) }
    return data
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }

  func resolver() -> PiRuntimeResolver {
    PiRuntimeResolver(
      configuration: PiRuntimeResolverConfiguration(
        piCandidates: [piLinkURL],
        nodeCandidates: [nodeLinkURL],
        piPolicyURL: piPolicyURL,
        nodePolicyURL: nodePolicyURL
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
