import CryptoKit
import Darwin
import Foundation
import Security
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

  @Test("later attested Node builds resolve through the stable candidate")
  func laterAttestedNodeBuild() throws {
    let fixture = try RuntimeResolverFixture(nodeVersion: "26.7.0")
    defer { fixture.remove() }

    let runtime = try fixture.resolver().resolve()

    #expect(runtime.nodeVersion.description == "26.7.0")
    #expect(runtime.nodeURL == fixture.nodeURL)
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

  @Test("Pi package rejects writable roots and hard-linked imported files")
  func unsafePiFilesystemAuthority() throws {
    let writableRoot = try RuntimeResolverFixture()
    defer { writableRoot.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: writableRoot.packageRootURL.path
    )
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try writableRoot.resolver().resolve()
    }

    let linkedRuntime = try RuntimeResolverFixture()
    defer { linkedRuntime.remove() }
    try FileManager.default.linkItem(
      at: linkedRuntime.cliURL,
      to: linkedRuntime.rootURL.appendingPathComponent("linked-cli.js")
    )
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try linkedRuntime.resolver().resolve()
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

  @Test("Node rejects writable executables and hard-linked dynamic libraries")
  func unsafeNodeFilesystemAuthority() throws {
    let writableNode = try RuntimeResolverFixture()
    defer { writableNode.remove() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: writableNode.nodeURL.path
    )
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try writableNode.resolver().resolve()
    }

    let linkedLibrary = try RuntimeResolverFixture()
    defer { linkedLibrary.remove() }
    try FileManager.default.linkItem(
      at: linkedLibrary.nodeLibraryURL,
      to: linkedLibrary.rootURL.appendingPathComponent("linked-node-library.dylib")
    )
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try linkedLibrary.resolver().resolve()
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

  @Test("one complete Node build cannot ambiguously attest two version labels")
  func duplicateNodeBuild() throws {
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

  @Test("a shared launcher digest can attest distinct Node closures")
  func sharedNodeLauncherDigest() throws {
    let fixture = try RuntimeResolverFixture(nodeVersion: "26.7.0")
    defer { fixture.remove() }
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.nodePolicyURL))
        as? [String: Any]
    )
    var builds = try #require(object["builds"] as? [String: Any])
    var prior = try #require(builds["26.7.0"] as? [String: Any])
    var executable = try #require(prior["executable"] as? [String: Any])
    executable["canonicalPath"] = fixture.rootURL.appendingPathComponent("node-26.6.0").path
    prior["executable"] = executable
    builds["26.6.0"] = prior
    let policy: [String: Any] = [
      "builds": builds,
      "runtime": "node",
      "schemaVersion": 2,
    ]
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])
      .write(to: fixture.nodePolicyURL)

    #expect(try fixture.resolver().resolve().nodeVersion.description == "26.7.0")
  }

  @Test("private runtime snapshot removes unsafe source ancestors from reopen authority")
  func privateRuntimeSnapshot() throws {
    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let runtime = try fixture.resolver().resolve()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: fixture.rootURL.path
    )
    let requestedSnapshotParent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-runtime-snapshot-test-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: requestedSnapshotParent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let snapshotParent = requestedSnapshotParent.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: snapshotParent) }

    let snapshot = try PiRuntimeResolver.materializePrivateSnapshot(
      of: runtime,
      in: snapshotParent
    )
    #expect(PiTUIFileProtocol.isChild(snapshot.nodeURL, of: snapshotParent))
    #expect(PiTUIFileProtocol.isChild(snapshot.piCLIURL, of: snapshotParent))
    #expect(
      snapshot.nodeDynamicLibraryDirectoryURL.map {
        PiTUIFileProtocol.isChild($0, of: snapshotParent)
      } == true
    )
    #expect(snapshot.nodeDynamicLibrarySHA256.count == 1)
    #expect(
      try PiRuntimeResolver.attestPackageTree(
        snapshot.piPackageRootURL,
        requireSafeAncestors: true
      ).sha256 == runtime.piRuntimeSHA256["package-tree-v1"]
    )

    try FileManager.default.linkItem(
      at: snapshot.piCLIURL,
      to: snapshotParent.appendingPathComponent("hostile-runtime-link")
    )
    let repaired = try PiRuntimeResolver.materializePrivateSnapshot(
      of: runtime,
      in: snapshotParent
    )
    #expect(repaired == snapshot)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: repaired.piCLIURL.path)[.referenceCount]
        as? NSNumber)?.intValue == 1
    )

    try FileManager.default.removeItem(at: fixture.cliURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.cliURL,
      withDestinationURL: fixture.packageRootURL.appendingPathComponent("dist/main.js")
    )
    let reopened = try PiRuntimeResolver.materializePrivateSnapshot(
      of: runtime,
      in: snapshotParent
    )
    #expect(reopened == repaired)
    #expect(reopened.piCLIRelativePath == "dist/cli.js")
    #expect(reopened.piCLIURL.lastPathComponent == "cli.js")
  }

  @Test("Darwin allow ACLs cannot authorize runtime source or snapshot mutation")
  func runtimeACLAuthority() throws {
    let sourceFixture = try RuntimeResolverFixture()
    defer { sourceFixture.remove() }
    try addEveryoneWriteACL(to: sourceFixture.cliURL)
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try sourceFixture.resolver().resolve()
    }

    let fixture = try RuntimeResolverFixture()
    defer { fixture.remove() }
    let runtime = try fixture.resolver().resolve()
    let requestedParent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-runtime-acl-test-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: requestedParent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: requestedParent) }
    try addEveryoneDirectoryACL(to: requestedParent)
    #expect(try !PiTUIFileProtocol.safePrivateDirectory(requestedParent))
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try PiRuntimeResolver.materializePrivateSnapshot(
        of: runtime,
        in: requestedParent
      )
    }

    try removeACL(from: requestedParent)
    let snapshot = try PiRuntimeResolver.materializePrivateSnapshot(
      of: runtime,
      in: requestedParent
    )
    try addEveryoneWriteACL(to: snapshot.nodeURL)
    let repaired = try PiRuntimeResolver.materializePrivateSnapshot(
      of: runtime,
      in: requestedParent
    )
    let nodeDescriptor = Darwin.open(
      repaired.nodeURL.path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(nodeDescriptor >= 0)
    if nodeDescriptor >= 0 {
      #expect(DarwinACLAuthority.hasNoAllowEntries(nodeDescriptor))
      _ = Darwin.close(nodeDescriptor)
    }
  }

  @Test("source release manifest matches the compiled production anchor")
  func sourceReleaseManifestAnchor() throws {
    let manifest = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi/runtime/release-runtime.json")
    let data = try Data(contentsOf: manifest)

    #expect(Self.sha256(data) == ReleaseOwnedPiRuntimeResolver.expectedManifestSHA256)
    let decoded = try ReleaseOwnedPiRuntimeManifest.parseCanonical(data)
    try decoded.validateLockedPolicy()
  }

  @Test("external closure drift cannot become release-owned production authority")
  func externalClosureDriftIsNotProductionAuthority() throws {
    let external = try RuntimeResolverFixture()
    defer { external.remove() }
    try Data("drifted-external-library".utf8).write(to: external.nodeLibraryURL)
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try external.resolver().resolve()
    }

    let owned = try ReleaseOwnedRuntimeFixture()
    defer { owned.remove() }
    let runtime = try owned.resolver().resolve()
    #expect(runtime.releaseIdentity?.runtimeID == owned.runtimeID)
    #expect(runtime.nodeDynamicLibrarySHA256.isEmpty)
    #expect(runtime.nodeDynamicLibraryDirectoryURL == nil)
  }

  @Test("release manifest and runtime mutations fail closed")
  func releaseManifestAndRuntimeMutations() throws {
    let manifestMutation = try ReleaseOwnedRuntimeFixture()
    defer { manifestMutation.remove() }
    try manifestMutation.rewriteManifest { object in
      object["runtimeID"] = "node-26.7.0-pi-0.84.2-darwin-arm64-v2"
    }
    do {
      _ = try manifestMutation.resolver().resolve()
      Issue.record("manifest-only drift passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseManifestDrift)
    }

    let transposedCodeDirectories = try ReleaseOwnedRuntimeFixture()
    defer { transposedCodeDirectories.remove() }
    try transposedCodeDirectories.rewriteManifest { object in
      var node = object["node"] as! [String: Any]
      let adHoc = node["adHocCodeDirectorySHA256"]
      node["adHocCodeDirectorySHA256"] = node["productionCodeDirectorySHA256"]
      node["productionCodeDirectorySHA256"] = adHoc
      object["node"] = node
    }
    do {
      _ = try transposedCodeDirectories.resolver().resolve()
      Issue.record("transposed release CodeDirectories passed the compiled anchor")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseManifestDrift)
    }

    let runtimeMutation = try ReleaseOwnedRuntimeFixture()
    defer { runtimeMutation.remove() }
    let coordinatedManifestSHA256 = try runtimeMutation.applyCoordinatedPiDrift()
    #expect(coordinatedManifestSHA256 != runtimeMutation.manifestSHA256)
    do {
      _ = try runtimeMutation.resolver().resolve()
      Issue.record("coordinated Pi and manifest drift passed the compiled anchor")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseManifestDrift)
      #expect(error.detail == "release runtime manifest digest differs")
    }

    let extraEntry = try ReleaseOwnedRuntimeFixture()
    defer { extraEntry.remove() }
    try Data("extra".utf8).write(to: extraEntry.root.appendingPathComponent("extra"))
    do {
      _ = try extraEntry.resolver().resolve()
      Issue.record("extra release runtime entry passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseRuntimeDrift)
    }
  }

  @Test("release manifest rejects non-canonical and unknown fields")
  func releaseManifestCanonicalShape() throws {
    let fixture = try ReleaseOwnedRuntimeFixture()
    defer { fixture.remove() }
    let canonical = try Data(contentsOf: fixture.manifestURL)
    let object = try #require(
      try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try ReleaseOwnedPiRuntimeManifest.parseCanonical(pretty + Data([0x0A]))
    }
    var unknown = object
    unknown["unknown"] = true
    let unknownData =
      try JSONSerialization.data(
        withJSONObject: unknown,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try ReleaseOwnedPiRuntimeManifest.parseCanonical(unknownData)
    }

    for field in ["adHocCodeDirectorySHA256", "productionCodeDirectorySHA256"] {
      var missing = object
      var node = try #require(missing["node"] as? [String: Any])
      node.removeValue(forKey: field)
      missing["node"] = node
      let missingData =
        try JSONSerialization.data(
          withJSONObject: missing,
          options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
      #expect(throws: PiRuntimeResolutionError.self) {
        _ = try ReleaseOwnedPiRuntimeManifest.parseCanonical(missingData)
      }
    }

    var legacy = object
    var legacyNode = try #require(legacy["node"] as? [String: Any])
    legacyNode["codeDirectorySHA256"] = legacyNode["adHocCodeDirectorySHA256"]
    legacy["node"] = legacyNode
    let legacyData =
      try JSONSerialization.data(
        withJSONObject: legacy,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    #expect(throws: PiRuntimeResolutionError.self) {
      _ = try ReleaseOwnedPiRuntimeManifest.parseCanonical(legacyData)
    }

    func addingUnknownField(
      to value: [String: Any],
      at path: ArraySlice<String>
    ) throws -> [String: Any] {
      var result = value
      guard let component = path.first else {
        result["unknown"] = true
        return result
      }
      let child = try #require(result[component] as? [String: Any])
      result[component] = try addingUnknownField(to: child, at: path.dropFirst())
      return result
    }

    for path in [
      ["licenses", "node"],
      ["node", "entitlementPolicy"],
      ["node", "upstream"],
      ["pi"],
      ["pi", "packageTree"],
    ] {
      let nestedUnknown = try addingUnknownField(to: object, at: path[...])
      let nestedUnknownData =
        try JSONSerialization.data(
          withJSONObject: nestedUnknown,
          options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
      #expect(throws: PiRuntimeResolutionError.self) {
        _ = try ReleaseOwnedPiRuntimeManifest.parseCanonical(nestedUnknownData)
      }
    }
  }

  @Test("release package and runtime root replacement fail before final authority")
  func releasePackageRootReplacement() throws {
    let rootFixture = try ReleaseOwnedRuntimeFixture()
    let root = rootFixture.root
    let movedRoot = root.deletingLastPathComponent().appendingPathComponent(
      "moved-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.moveItem(at: movedRoot, to: root)
      rootFixture.remove()
    }
    do {
      _ = try rootFixture.resolver { checkpoint in
        guard checkpoint == .packageTreeInspected else { return }
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      }.resolve()
      Issue.record("replacement runtime root obtained release authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseRuntimeDrift)
    }

    let packageFixture = try ReleaseOwnedRuntimeFixture()
    let packageRoot = packageFixture.packageRoot
    let movedPackageRoot = packageFixture.root.appendingPathComponent(
      "pi-inspected",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: packageRoot)
      try? FileManager.default.moveItem(at: movedPackageRoot, to: packageRoot)
      packageFixture.remove()
    }
    do {
      _ = try packageFixture.resolver { checkpoint in
        guard checkpoint == .packageTreeInspected else { return }
        try FileManager.default.moveItem(at: packageRoot, to: movedPackageRoot)
        try FileManager.default.createDirectory(
          at: packageRoot,
          withIntermediateDirectories: false
        )
      }.resolve()
      Issue.record("replacement package path obtained release authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseRuntimeDrift)
    }
  }

  @Test(
    "release-owned mutation matrix fails with typed authority errors",
    arguments: ReleaseOwnedMutationCase.allCases
  )
  func releaseOwnedMutationMatrix(mutation: ReleaseOwnedMutationCase) throws {
    let unsafeParent: URL?
    if mutation == .unsafeAncestor {
      unsafeParent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "jidoka-unsafe-runtime-parent-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: unsafeParent!,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: unsafeParent!.path
      )
    } else {
      unsafeParent = nil
    }
    defer {
      if let unsafeParent { try? FileManager.default.removeItem(at: unsafeParent) }
    }
    let includesInternalLink = mutation == .retargetedPiLink
    let fixture = try ReleaseOwnedRuntimeFixture(
      parentRoot: unsafeParent,
      includeInternalLink: includesInternalLink
    )
    defer { fixture.remove() }
    var evidence = fixture.signatureEvidence()
    var runtimeRoot = fixture.root
    var validationHook: (@Sendable (ReleaseOwnedPiRuntimeValidationCheckpoint) throws -> Void)?
    let sdk = fixture.packageRoot.appendingPathComponent("dist/core/sdk.js")
    let mutationState = ReleaseOwnedMutationState()

    switch mutation {
    case .rootSymlink:
      let link = fixture.root.deletingLastPathComponent().appendingPathComponent(
        "release-runtime-link-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
      mutationState.cleanup = { try? FileManager.default.removeItem(at: link) }
      runtimeRoot = link
    case .rootACL:
      try addEveryoneDirectoryACL(to: fixture.root)
    case .unsafeAncestor:
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o777],
        ofItemAtPath: unsafeParent!.path
      )
    case .missingRootEntry:
      try FileManager.default.removeItem(at: fixture.licenseURL)
    case .wrongRootEntryKind:
      try FileManager.default.removeItem(at: fixture.nodeURL)
      try FileManager.default.createDirectory(
        at: fixture.nodeURL, withIntermediateDirectories: false)
    case .hardLinkedPiFile:
      try FileManager.default.linkItem(
        at: sdk,
        to: fixture.packageRoot.appendingPathComponent("dist/core/sdk-hard-link.js")
      )
    case .piFileACL:
      try addEveryoneWriteACL(to: sdk)
    case .writablePiMode:
      try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: sdk.path)
    case .writableRuntimeRoot:
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o777],
        ofItemAtPath: fixture.root.path
      )
    case .nestedIntermediateTOCTOU:
      let original = fixture.packageRoot.appendingPathComponent("dist/core-original")
      let target = fixture.packageRoot.appendingPathComponent("dist/core")
      validationHook = { checkpoint in
        guard checkpoint == .packageDirectoryOpened("dist/core"),
          mutationState.beginMutation()
        else { return }
        try FileManager.default.moveItem(at: target, to: original)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        mutationState.cleanup = {
          try? FileManager.default.removeItem(at: target)
          try? FileManager.default.moveItem(at: original, to: target)
        }
      }
    case .nestedLeafTOCTOU:
      let original = fixture.packageRoot.appendingPathComponent("dist/core/sdk-original.js")
      validationHook = { checkpoint in
        guard checkpoint == .packageRegularFileOpened("dist/core/sdk.js"),
          mutationState.beginMutation()
        else { return }
        try FileManager.default.moveItem(at: sdk, to: original)
        try Data("replacement-sdk\n".utf8).write(to: sdk)
        mutationState.cleanup = {
          try? FileManager.default.removeItem(at: sdk)
          try? FileManager.default.moveItem(at: original, to: sdk)
        }
      }
    case .malformedNodeMachO:
      var node = try Data(contentsOf: fixture.nodeURL)
      node.replaceSubrange(0..<4, with: [UInt8](repeating: 0, count: 4))
      try fixture.replaceNode(with: node)
    case .wrongNodeArchitecture:
      var node = try Data(contentsOf: fixture.nodeURL)
      var x86 = UInt32(0x0100_0007).littleEndian
      withUnsafeBytes(of: &x86) { node.replaceSubrange(4..<8, with: $0) }
      try fixture.replaceNode(with: node)
    case .nonSystemNodeDependency:
      try fixture.replaceNode(
        with: RuntimeResolverFixture.machO(
          dependencies: ReleaseOwnedRuntimeFixture.dependencies + [
            "/opt/homebrew/lib/libuntrusted.dylib"
          ]
        )
      )
    case .unboundRelativeNodeDependency:
      try fixture.replaceNode(
        with: RuntimeResolverFixture.machO(
          dependencies: ReleaseOwnedRuntimeFixture.dependencies + ["@rpath/libuntrusted.dylib"]
        )
      )
    case .signatureIdentifier:
      evidence = fixture.signatureEvidence(identifier: "invalid.runtime.node")
    case .signatureTeam:
      evidence = fixture.signatureEvidence(teamIdentifier: "UNTRUSTED")
    case .signatureCodeDirectory:
      evidence = fixture.signatureEvidence(codeDirectorySHA256: String(repeating: "d", count: 64))
    case .signatureHardenedRuntime:
      evidence = fixture.signatureEvidence(hardenedRuntime: false)
    case .signatureEntitlements:
      evidence = fixture.signatureEvidence(entitlementSHA256: String(repeating: "e", count: 64))
    case .piBytes:
      try Data("mutated-pi-sdk\n".utf8).write(to: sdk)
    case .escapingRelativePiLink:
      try FileManager.default.createSymbolicLink(
        atPath: fixture.packageRoot.appendingPathComponent("escape-relative").path,
        withDestinationPath: "../../../outside"
      )
    case .absolutePiLink:
      try FileManager.default.createSymbolicLink(
        at: fixture.packageRoot.appendingPathComponent("escape-absolute"),
        withDestinationURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
      )
    case .cyclicPiLinks:
      try FileManager.default.createSymbolicLink(
        atPath: fixture.packageRoot.appendingPathComponent("cycle-a").path,
        withDestinationPath: "cycle-b"
      )
      try FileManager.default.createSymbolicLink(
        atPath: fixture.packageRoot.appendingPathComponent("cycle-b").path,
        withDestinationPath: "cycle-a"
      )
    case .retargetedPiLink:
      validationHook = { checkpoint in
        guard
          checkpoint
            == .packageLinkTargetOpened(
              link: "internal-cli-link", target: "dist/cli.js", isFinal: true
            ), mutationState.beginMutation()
        else { return }
        try FileManager.default.removeItem(at: fixture.internalLinkURL)
        try FileManager.default.createSymbolicLink(
          atPath: fixture.internalLinkURL.path,
          withDestinationPath: "dist/core/sdk.js"
        )
      }
    }

    defer {
      mutationState.cleanup?()
      if mutation == .rootACL { try? removeACL(from: fixture.root) }
    }
    do {
      _ = try fixture.resolver(
        runtimeRoot: runtimeRoot,
        signatureEvidence: evidence,
        validationHook: validationHook
      ).resolve()
      Issue.record("\(mutation) obtained release runtime authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == mutation.expectedCode)
    }
  }

  @Test("an attested internal relative Pi link is accepted")
  func acceptedInternalPiLink() throws {
    let fixture = try ReleaseOwnedRuntimeFixture(includeInternalLink: true)
    defer { fixture.remove() }
    let runtime = try fixture.resolver().resolve()
    #expect(runtime.releaseIdentity?.runtimeID == fixture.runtimeID)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.internalLinkURL.path)
        == "dist/cli.js"
    )
  }

  @Test("release signature evidence is exact and fail closed")
  func releaseSignatureEvidence() throws {
    let fixture = try ReleaseOwnedRuntimeFixture()
    defer { fixture.remove() }
    let mismatched = fixture.signatureEvidence(
      codeDirectorySHA256: String(repeating: "f", count: 64)
    )
    do {
      _ = try fixture.resolver(signatureEvidence: mismatched).resolve()
      Issue.record("mismatched CodeDirectory evidence passed")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseSignatureInvalid)
    }
  }

  @Test("release signing mode binds distinct exact Node CodeDirectories")
  func releaseSigningModeBindsCodeDirectory() throws {
    let fixture = try ReleaseOwnedRuntimeFixture()
    defer { fixture.remove() }

    let adHocRuntime = try fixture.resolver().resolve()
    #expect(
      adHocRuntime.releaseIdentity?.nodeCodeDirectorySHA256
        == ReleaseOwnedRuntimeFixture.adHocNodeCodeDirectorySHA256
    )
    #expect(adHocRuntime.nodeSHA256 == ReleaseOwnedRuntimeFixture.adHocNodeCodeDirectorySHA256)

    let productionEvidence = fixture.signatureEvidence(
      teamIdentifier: "X3Q42VNZDC",
      codeDirectorySHA256: ReleaseOwnedRuntimeFixture.productionNodeCodeDirectorySHA256
    )
    let productionRuntime = try fixture.resolver(
      signatureEvidence: productionEvidence,
      signaturePolicy: .production
    ).resolve()
    #expect(
      productionRuntime.releaseIdentity?.nodeCodeDirectorySHA256
        == ReleaseOwnedRuntimeFixture.productionNodeCodeDirectorySHA256
    )
    #expect(
      productionRuntime.nodeSHA256
        == ReleaseOwnedRuntimeFixture.productionNodeCodeDirectorySHA256
    )

    let transposedAdHoc = fixture.signatureEvidence(
      codeDirectorySHA256: ReleaseOwnedRuntimeFixture.productionNodeCodeDirectorySHA256
    )
    do {
      _ = try fixture.resolver(signatureEvidence: transposedAdHoc).resolve()
      Issue.record("production CodeDirectory obtained ad hoc runtime authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseSignatureInvalid)
    }

    let transposedProduction = fixture.signatureEvidence(
      teamIdentifier: "X3Q42VNZDC",
      codeDirectorySHA256: ReleaseOwnedRuntimeFixture.adHocNodeCodeDirectorySHA256
    )
    do {
      _ = try fixture.resolver(
        signatureEvidence: transposedProduction,
        signaturePolicy: .production
      ).resolve()
      Issue.record("ad hoc CodeDirectory obtained production runtime authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .releaseSignatureInvalid)
    }
  }

  @Test("production app and Node requirements are exact Apple-anchored Jidoka identities")
  func productionSignatureRequirementsAreLocked() throws {
    let requirements = ReleaseOwnedPiRuntimeResolver.productionSignatureRequirementsForTesting
    #expect(
      requirements.application
        == "anchor apple generic and identifier \"com.maroffo.JidokaCode\" "
        + "and certificate leaf[subject.OU] = \"X3Q42VNZDC\""
    )
    #expect(
      requirements.node
        == "anchor apple generic and identifier \"works.earendil.jidoka.runtime.node\" "
        + "and certificate leaf[subject.OU] = \"X3Q42VNZDC\""
    )
    for text in [requirements.application, requirements.node] {
      var requirement: SecRequirement?
      #expect(
        SecRequirementCreateWithString(
          text as CFString,
          SecCSFlags(),
          &requirement
        ) == errSecSuccess
      )
      #expect(requirement != nil)
    }
  }

  @Test("production rejects detached and user-renamable application runtime paths")
  func productionBundleBindingAndInstalledOwnership() throws {
    let detachedFixture = try ReleaseOwnedRuntimeFixture()
    defer { detachedFixture.remove() }
    let detachedApplication = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Detached-\(UUID().uuidString).app",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: detachedApplication, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: detachedApplication) }
    do {
      _ = try ReleaseOwnedPiRuntimeResolver(
        runtimeRoot: detachedFixture.root,
        containingApplicationURL: detachedApplication
      ).resolve()
      Issue.record("detached production runtime obtained authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unsafeReleaseRuntime)
    }

    let installedFixture = try ReleaseOwnedRuntimeFixture()
    let application = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UserOwned-\(UUID().uuidString).app",
      isDirectory: true
    )
    let resources = application.appendingPathComponent("Contents/Resources", isDirectory: true)
    let runtimeRoot = resources.appendingPathComponent("PiRuntime", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: installedFixture.root, to: runtimeRoot)
    defer { try? FileManager.default.removeItem(at: application) }
    do {
      _ = try ReleaseOwnedPiRuntimeResolver(
        runtimeRoot: runtimeRoot,
        containingApplicationURL: application
      ).resolve()
      Issue.record("user-renamable production application obtained authority")
    } catch let error as PiRuntimeResolutionError {
      #expect(error.code == .unsafeReleaseRuntime)
    }
  }

  @Test("production team mismatch rejects before strict nested signature validation")
  func productionTeamFailFastGate() throws {
    let expectedTeam = "X3Q42VNZDC"
    let mismatches: [(application: String?, node: String?)] = [
      (nil, expectedTeam),
      ("WRONGTEAM", expectedTeam),
      (expectedTeam, nil),
      (expectedTeam, "WRONGTEAM"),
    ]

    for mismatch in mismatches {
      var strictValidationStarted = false
      do {
        try ReleaseOwnedPiRuntimeResolver.observeProductionStrictSignatureValidationForTesting(
          preliminaryApplicationTeam: mismatch.application,
          preliminaryNodeTeam: mismatch.node
        ) {
          strictValidationStarted = true
        }
        Issue.record("mismatched preliminary team reached strict signature validation")
      } catch let error as PiRuntimeResolutionError {
        #expect(error.code == .releaseSignatureInvalid)
      }
      #expect(!strictValidationStarted)
    }

    var strictValidationStarted = false
    try ReleaseOwnedPiRuntimeResolver.observeProductionStrictSignatureValidationForTesting(
      preliminaryApplicationTeam: expectedTeam,
      preliminaryNodeTeam: expectedTeam
    ) {
      strictValidationStarted = true
    }
    #expect(strictValidationStarted)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

enum ReleaseOwnedMutationCase: CaseIterable, Equatable, Sendable {
  case rootSymlink
  case rootACL
  case unsafeAncestor
  case missingRootEntry
  case wrongRootEntryKind
  case hardLinkedPiFile
  case piFileACL
  case writablePiMode
  case writableRuntimeRoot
  case nestedIntermediateTOCTOU
  case nestedLeafTOCTOU
  case malformedNodeMachO
  case wrongNodeArchitecture
  case nonSystemNodeDependency
  case unboundRelativeNodeDependency
  case signatureIdentifier
  case signatureTeam
  case signatureCodeDirectory
  case signatureHardenedRuntime
  case signatureEntitlements
  case piBytes
  case escapingRelativePiLink
  case absolutePiLink
  case cyclicPiLinks
  case retargetedPiLink

  var expectedCode: PiRuntimeIssueCode {
    switch self {
    case .rootSymlink: .releaseRuntimeMissing
    case .rootACL, .unsafeAncestor, .wrongRootEntryKind, .hardLinkedPiFile,
      .piFileACL, .writablePiMode, .writableRuntimeRoot:
      .unsafeReleaseRuntime
    case .malformedNodeMachO, .wrongNodeArchitecture, .nonSystemNodeDependency,
      .unboundRelativeNodeDependency:
      .unattestedNodeBuild
    case .signatureIdentifier, .signatureTeam, .signatureCodeDirectory,
      .signatureHardenedRuntime, .signatureEntitlements:
      .releaseSignatureInvalid
    case .missingRootEntry, .nestedIntermediateTOCTOU, .nestedLeafTOCTOU,
      .piBytes, .escapingRelativePiLink, .absolutePiLink, .cyclicPiLinks,
      .retargetedPiLink:
      .releaseRuntimeDrift
    }
  }
}

private final class ReleaseOwnedMutationState: @unchecked Sendable {
  private let lock = NSLock()
  private var mutated = false
  var cleanup: (@Sendable () -> Void)?

  func beginMutation() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !mutated else { return false }
    mutated = true
    return true
  }
}

private func addEveryoneWriteACL(to url: URL) throws {
  try runChmod(["+a", "everyone allow write", url.path])
}

private func addEveryoneDirectoryACL(to url: URL) throws {
  try runChmod([
    "+a", "everyone allow list,search,add_file,delete_child", url.path,
  ])
}

private func removeACL(from url: URL) throws {
  try runChmod(["-N", url.path])
}

private func runChmod(_ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw CocoaError(.fileWriteNoPermission)
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
    nodeVersion: String = "26.6.0",
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
    nodeURL = rootURL.appendingPathComponent("node-\(nodeVersion)")
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
        nodeVersion: [
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

  static func machO(
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

final class ReleaseOwnedRuntimeFixture: @unchecked Sendable {
  static let entitlementSHA256 =
    "7faab808f2696c84032a67166b79e0d9b49128fcf990cdcf696383ac62558a08"
  static let adHocNodeCodeDirectorySHA256 = String(repeating: "c", count: 64)
  static let productionNodeCodeDirectorySHA256 = String(repeating: "d", count: 64)
  static let dependencies = [
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
    "/System/Library/Frameworks/Security.framework/Versions/A/Security",
    "/usr/lib/libSystem.B.dylib",
    "/usr/lib/libc++.1.dylib",
  ].sorted()

  let root: URL
  let packageRoot: URL
  let manifestURL: URL
  let nodeURL: URL
  let licenseURL: URL
  let internalLinkURL: URL
  let runtimeID = "node-26.7.0-pi-0.84.2-test-arm64-v1"
  let manifestSHA256: String

  init(parentRoot: URL? = nil, includeInternalLink: Bool = false) throws {
    let parent = parentRoot ?? FileManager.default.temporaryDirectory
    root = parent.appendingPathComponent(
      "jidoka-release-owned-runtime-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    packageRoot = root.appendingPathComponent("pi", isDirectory: true)
    manifestURL = root.appendingPathComponent("runtime-manifest.json")
    nodeURL = root.appendingPathComponent("node/bin/node")
    licenseURL = root.appendingPathComponent("licenses/node-LICENSE")
    internalLinkURL = packageRoot.appendingPathComponent("internal-cli-link")
    for directory in [
      root,
      root.appendingPathComponent("licenses", isDirectory: true),
      root.appendingPathComponent("node", isDirectory: true),
      root.appendingPathComponent("node/bin", isDirectory: true),
      packageRoot,
      packageRoot.appendingPathComponent("dist", isDirectory: true),
      packageRoot.appendingPathComponent("dist/core", isDirectory: true),
      packageRoot.appendingPathComponent(
        "node_modules/@earendil-works/pi-ai/dist/api",
        isDirectory: true
      ),
    ] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: directory.path
      )
    }

    let nodeData = RuntimeResolverFixture.machO(dependencies: Self.dependencies)
    let license = Data("synthetic Node license\n".utf8)
    let runtimeFiles: [String: Data] = [
      "dist/cli.js": Data("#!/usr/bin/env node\nconsole.log('pi');\n".utf8),
      "dist/core/sdk.js": Data("synthetic-sdk\n".utf8),
      "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js":
        Data("synthetic-codex\n".utf8),
      "package.json": Data(
        "{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"0.84.2\"}\n".utf8
      ),
    ]
    try nodeData.write(to: nodeURL)
    try license.write(to: licenseURL)
    for (path, data) in runtimeFiles {
      try data.write(to: packageRoot.appendingPathComponent(path))
    }
    if includeInternalLink {
      try FileManager.default.createSymbolicLink(
        atPath: internalLinkURL.path,
        withDestinationPath: "dist/cli.js"
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: nodeURL.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: licenseURL.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: packageRoot.appendingPathComponent("dist/cli.js").path
    )
    let tree = try PiRuntimeResolver.attestPackageTree(
      packageRoot,
      maximumFileBytes: 64 * 1_048_576,
      requireSafeAncestors: true
    )
    let criticalFiles = runtimeFiles.mapValues(Self.sha256)
    let manifest: [String: Any] = [
      "licenses": [
        "node": [
          "mode": 0o444,
          "relativePath": "licenses/node-LICENSE",
          "sha256": Self.sha256(license),
          "size": license.count,
        ]
      ],
      "node": [
        "adHocCodeDirectorySHA256": Self.adHocNodeCodeDirectorySHA256,
        "architecture": "arm64",
        "entitlementPolicy": [
          "canonicalSHA256": Self.entitlementSHA256,
          "keys": [
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory",
          ],
        ],
        "identifier": "works.earendil.jidoka.runtime.node",
        "machoDependencies": Self.dependencies,
        "mode": 0o555,
        "productionCodeDirectorySHA256": Self.productionNodeCodeDirectorySHA256,
        "relativePath": "node/bin/node",
        "signatureTeam": "same-as-containing-application",
        "sizeAtAdHocQualification": nodeData.count,
        "upstream": [
          "archiveSHA256": String(repeating: "a", count: 64),
          "nodeSHA256": String(repeating: "b", count: 64),
          "signerFingerprint": String(repeating: "A", count: 40),
        ],
        "version": "26.7.0",
      ],
      "pi": [
        "cliRelativePath": "dist/cli.js",
        "criticalFiles": criticalFiles,
        "package": "@earendil-works/pi-coding-agent",
        "packageTree": [
          "entryCount": tree.entryCount,
          "sha256": tree.sha256,
        ],
        "relativeRoot": "pi",
        "version": "0.84.2",
      ],
      "rootEntries": ["licenses", "node", "pi", "runtime-manifest.json"],
      "runtimeID": runtimeID,
      "schemaVersion": 2,
    ]
    let manifestData =
      try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    try manifestData.write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
    manifestSHA256 = Self.sha256(manifestData)
  }

  func resolver(
    runtimeRoot: URL? = nil,
    signatureEvidence: ReleaseOwnedPiRuntimeSyntheticSignatureEvidence? = nil,
    signaturePolicy: ReleaseOwnedPiRuntimeSyntheticSignaturePolicy = .adHoc,
    validationHook: (@Sendable (ReleaseOwnedPiRuntimeValidationCheckpoint) throws -> Void)? = nil
  ) -> ReleaseOwnedPiRuntimeResolver {
    ReleaseOwnedPiRuntimeResolver(
      testingRuntimeRoot: runtimeRoot ?? root,
      expectedManifestSHA256: manifestSHA256,
      signatureEvidence: signatureEvidence ?? self.signatureEvidence(),
      signaturePolicy: signaturePolicy,
      validationHook: validationHook
    )
  }

  func resolver(
    validationHook:
      @escaping @Sendable (
        ReleaseOwnedPiRuntimeValidationCheckpoint
      ) throws -> Void
  ) -> ReleaseOwnedPiRuntimeResolver {
    resolver(signatureEvidence: nil, validationHook: validationHook)
  }

  func replaceNode(with data: Data) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: nodeURL.path
    )
    try data.write(to: nodeURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: nodeURL.path
    )
  }

  func signatureEvidence(
    identifier: String = "works.earendil.jidoka.runtime.node",
    teamIdentifier: String? = nil,
    codeDirectorySHA256: String = ReleaseOwnedRuntimeFixture.adHocNodeCodeDirectorySHA256,
    entitlementSHA256: String = ReleaseOwnedRuntimeFixture.entitlementSHA256,
    hardenedRuntime: Bool = true
  ) -> ReleaseOwnedPiRuntimeSyntheticSignatureEvidence {
    ReleaseOwnedPiRuntimeSyntheticSignatureEvidence(
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      codeDirectorySHA256: codeDirectorySHA256,
      entitlementSHA256: entitlementSHA256,
      hardenedRuntime: hardenedRuntime
    )
  }

  func applyCoordinatedPiDrift() throws -> String {
    let sdk = packageRoot.appendingPathComponent("dist/core/sdk.js")
    let sdkData = Data("coordinated-runtime-drift\n".utf8)
    try sdkData.write(to: sdk)
    let tree = try PiRuntimeResolver.attestPackageTree(
      packageRoot,
      maximumFileBytes: 64 * 1_048_576,
      requireSafeAncestors: true
    )
    try rewriteManifest { object in
      var pi = object["pi"] as! [String: Any]
      var criticalFiles = pi["criticalFiles"] as! [String: String]
      criticalFiles["dist/core/sdk.js"] = Self.sha256(sdkData)
      pi["criticalFiles"] = criticalFiles
      pi["packageTree"] = [
        "entryCount": tree.entryCount,
        "sha256": tree.sha256,
      ]
      object["pi"] = pi
    }
    return Self.sha256(try Data(contentsOf: manifestURL))
  }

  func rewriteManifest(_ transform: (inout [String: Any]) -> Void) throws {
    var object =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: manifestURL)
      ) as! [String: Any]
    transform(&object)
    let data =
      try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: manifestURL.path
    )
    try data.write(to: manifestURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: manifestURL.path
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
