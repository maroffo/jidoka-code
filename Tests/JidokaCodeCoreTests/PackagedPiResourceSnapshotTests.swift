import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Packaged Pi resource tree snapshot")
struct PackagedPiResourceSnapshotTests {
  @Test("workflow and TUI resources become one exact private tree")
  func exactPrivateTree() throws {
    let fixture = try PiResourceSnapshotFixture()
    defer { fixture.remove() }
    let unsafeLeaf = fixture.sourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
    #expect(!(try PiTUIFileProtocol.safeRegularFile(unsafeLeaf)))

    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    let reused = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )

    #expect(snapshot == reused)
    let catalog = try PiTUIResourceCatalog.inspect(resourceRoot: snapshot)
    #expect(
      catalog.workflowResources.resourceRoot.resolvingSymlinksInPath().path
        == snapshot.resolvingSymlinksInPath().path
    )
    let files = try fixture.relativeFiles(at: snapshot)
    #expect(files == fixture.expectedFiles)
    for file in files {
      let url = snapshot.appendingPathComponent(file)
      #expect(try fixture.mode(url) == 0o400)
      #expect(try PiTUIFileProtocol.safePrivateFile(url, maximumBytes: 1_048_576))
    }
    for directory in try fixture.relativeDirectories(at: snapshot) {
      let url = snapshot.appendingPathComponent(directory, isDirectory: true)
      #expect(try fixture.mode(url) == 0o700)
      #expect(try PiTUIFileProtocol.safePrivateDirectory(url))
    }
    let evidence = try PackagedPiResourceSnapshot.inspectEvidence(resourceRoot: snapshot)
    #expect(
      try PackagedPiResourceSnapshot.inspect(resourceRoot: snapshot) == evidence.inventorySHA256)
    #expect(evidence.rootPath == snapshot.path)
    #expect(evidence.rootDevice > 0)
    #expect(evidence.rootInode > 0)
    #expect(evidence.entries.map(\.path) == evidence.entries.map(\.path).sorted())
    #expect(Set(evidence.entries.filter { $0.kind == .file }.map(\.path)) == files)
    #expect(evidence.inventorySHA256 == snapshot.lastPathComponent)
    let mutated = snapshot.appendingPathComponent("extensions/jidoka-code.ts")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: mutated.path
    )
    try Data("mutated after preview\n".utf8).write(to: mutated)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: mutated.path
    )
    #expect(throws: (any Error).self) {
      _ = try PackagedPiResourceSnapshot.inspect(resourceRoot: snapshot)
    }
  }

  @Test("descriptor-pinned inspection rejects root, path, vnode, and read races")
  func descriptorPinnedInspection() throws {
    let rootSwap = try PiResourceSnapshotFixture()
    defer { rootSwap.remove() }
    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: rootSwap.sourceRoot,
      applicationSupportRoot: rootSwap.applicationSupport
    )
    let original = try PackagedPiResourceSnapshot.inspectEvidence(resourceRoot: snapshot)
    let heldRoot = rootSwap.root.appendingPathComponent("held-snapshot", isDirectory: true)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.inspectEvidence(
        resourceRoot: snapshot,
        entryInspection: { path, root in
          guard path.isEmpty else { return }
          try FileManager.default.moveItem(at: root, to: heldRoot)
          try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
          )
        }
      )
    }

    let fileSwap = try PiResourceSnapshotFixture()
    defer { fileSwap.remove() }
    let fileSnapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fileSwap.sourceRoot,
      applicationSupportRoot: fileSwap.applicationSupport
    )
    let relativePath = "extensions/jidoka-code.ts"
    let heldFile = fileSwap.root.appendingPathComponent("held-extension")
    var swapped = false
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.inspectEvidence(
        resourceRoot: fileSnapshot,
        entryInspection: { path, url in
          guard path == relativePath, !swapped else { return }
          swapped = true
          try FileManager.default.moveItem(at: url, to: heldFile)
          try FileManager.default.copyItem(at: heldFile, to: url)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: url.path
          )
        }
      )
    }

    let mutation = try PiResourceSnapshotFixture()
    defer { mutation.remove() }
    let mutationSnapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: mutation.sourceRoot,
      applicationSupportRoot: mutation.applicationSupport
    )
    var mutated = false
    #expect(throws: (any Error).self) {
      _ = try PackagedPiResourceSnapshot.inspectEvidence(
        resourceRoot: mutationSnapshot,
        entryInspection: { path, url in
          guard path == relativePath, !mutated else { return }
          mutated = true
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
          )
          try Data("mutation during descriptor read\n".utf8).write(to: url)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: url.path
          )
        }
      )
    }

    let renamed = heldRoot.deletingLastPathComponent().appendingPathComponent(
      "coherently-renamed-snapshot",
      isDirectory: true
    )
    try FileManager.default.moveItem(at: heldRoot, to: renamed)
    let renamedEvidence = try PackagedPiResourceSnapshot.inspectEvidence(resourceRoot: renamed)
    #expect(renamedEvidence.inventorySHA256 == original.inventorySHA256)
    #expect(renamedEvidence.evidenceSHA256 != original.evidenceSHA256)
    #expect(renamedEvidence.rootPath != original.rootPath)
  }

  @Test("nested intermediate rename and symlink substitution fails closed")
  func nestedIntermediateSubstitution() throws {
    let fixture = try PiResourceSnapshotFixture()
    defer { fixture.remove() }
    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    let relativePath = "skills/jidoka-code-plan/SKILL.md"
    let intermediate = snapshot.appendingPathComponent(
      "skills/jidoka-code-plan",
      isDirectory: true
    )
    let held = snapshot.appendingPathComponent(
      "skills/.held-jidoka-code-plan",
      isDirectory: true
    )
    var substituted = false

    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.inspectEvidence(
        resourceRoot: snapshot,
        entryInspection: { path, _ in
          guard path == relativePath, !substituted else { return }
          substituted = true
          try FileManager.default.moveItem(at: intermediate, to: held)
          try FileManager.default.createSymbolicLink(
            at: intermediate,
            withDestinationURL: held
          )
        }
      )
    }
    #expect(substituted)
  }

  @Test("owned partial staging and prepared crash artifacts recover exactly")
  func crashRecovery() throws {
    let fixture = try PiResourceSnapshotFixture()
    defer { fixture.remove() }
    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    let relativePath = "runtime/pi-runtime-builds.json"
    let target = snapshot.appendingPathComponent(relativePath)
    let expected = try Data(
      contentsOf: fixture.sourceRoot.appendingPathComponent(relativePath)
    )
    try FileManager.default.removeItem(at: target)
    let staging = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).11111111-1111-1111-1111-111111111111.staging"
    )
    try Data(expected.prefix(expected.count / 2)).write(to: staging)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: staging.path
    )

    let recovered = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    #expect(recovered == snapshot)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(try Data(contentsOf: target) == expected)
    #expect(try fixture.mode(target) == 0o400)

    let prepared = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).prepared"
    )
    try expected.write(to: prepared)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: prepared.path
    )
    _ = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
  }

  @Test("divergent crash artifacts are preserved and rejected")
  func divergentCrashArtifact() throws {
    let fixture = try PiResourceSnapshotFixture()
    defer { fixture.remove() }
    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: fixture.sourceRoot,
      applicationSupportRoot: fixture.applicationSupport
    )
    let target = snapshot.appendingPathComponent("runtime/pi-runtime-builds.json")
    try FileManager.default.removeItem(at: target)
    let staging = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).22222222-2222-2222-2222-222222222222.staging"
    )
    let divergent = Data("not an expected prefix".utf8)
    try divergent.write(to: staging)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: staging.path
    )
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: fixture.sourceRoot,
        applicationSupportRoot: fixture.applicationSupport
      )
    }
    #expect(try Data(contentsOf: staging) == divergent)
  }

  @Test("source swaps symlinks hard links and manifest drift fail closed")
  func unsafeSources() throws {
    let swapped = try PiResourceSnapshotFixture()
    defer { swapped.remove() }
    let held = swapped.root.appendingPathComponent("held-pi", isDirectory: true)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: swapped.sourceRoot,
        applicationSupportRoot: swapped.applicationSupport,
        sourceInspection: { source in
          try FileManager.default.moveItem(at: source, to: held)
        }
      )
    }

    let symlinked = try PiResourceSnapshotFixture()
    defer { symlinked.remove() }
    let sourceFile = symlinked.sourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
    let movedFile = symlinked.root.appendingPathComponent("moved-extension.ts")
    try FileManager.default.moveItem(at: sourceFile, to: movedFile)
    try FileManager.default.createSymbolicLink(at: sourceFile, withDestinationURL: movedFile)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: symlinked.sourceRoot,
        applicationSupportRoot: symlinked.applicationSupport
      )
    }

    let hardLinked = try PiResourceSnapshotFixture()
    defer { hardLinked.remove() }
    let hardLinkSource = hardLinked.sourceRoot.appendingPathComponent(
      "extensions/jidoka-code.ts")
    try FileManager.default.linkItem(
      at: hardLinkSource,
      to: hardLinked.root.appendingPathComponent("linked-extension.ts")
    )
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: hardLinked.sourceRoot,
        applicationSupportRoot: hardLinked.applicationSupport
      )
    }

    let linkedDirectory = try PiResourceSnapshotFixture()
    defer { linkedDirectory.remove() }
    let skills = linkedDirectory.sourceRoot.appendingPathComponent("skills", isDirectory: true)
    let movedSkills = linkedDirectory.root.appendingPathComponent("moved-skills", isDirectory: true)
    try FileManager.default.moveItem(at: skills, to: movedSkills)
    try FileManager.default.createSymbolicLink(at: skills, withDestinationURL: movedSkills)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: linkedDirectory.sourceRoot,
        applicationSupportRoot: linkedDirectory.applicationSupport
      )
    }

    let writable = try PiResourceSnapshotFixture()
    defer { writable.remove() }
    let writableFile = writable.sourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666],
      ofItemAtPath: writableFile.path
    )
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: writable.sourceRoot,
        applicationSupportRoot: writable.applicationSupport
      )
    }

    let acl = try PiResourceSnapshotFixture()
    defer { acl.remove() }
    let aclFile = acl.sourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
    try addSnapshotEveryoneWriteACL(to: aclFile)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeSource) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: acl.sourceRoot,
        applicationSupportRoot: acl.applicationSupport
      )
    }

    let resourceDrift = try PiResourceSnapshotFixture()
    defer { resourceDrift.remove() }
    let resource = resourceDrift.sourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
    try Data("changed resource\n".utf8).write(to: resource)
    #expect(
      throws: PackagedPiResourceSnapshotError.resourceDigestMismatch("extensions/jidoka-code.ts")
    ) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: resourceDrift.sourceRoot,
        applicationSupportRoot: resourceDrift.applicationSupport
      )
    }

    let drifted = try PiResourceSnapshotFixture()
    defer { drifted.remove() }
    let manifest = drifted.sourceRoot.appendingPathComponent("workflow-resources.json")
    try Data("{}\n".utf8).write(to: manifest)
    #expect(throws: PackagedPiResourceSnapshotError.invalidManifest) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: drifted.sourceRoot,
        applicationSupportRoot: drifted.applicationSupport
      )
    }
  }

  @Test("unsafe and divergent private destinations are preserved and rejected")
  func unsafeDestinations() throws {
    let unsafe = try PiResourceSnapshotFixture()
    defer { unsafe.remove() }
    let root = unsafe.applicationSupport.appendingPathComponent("PiResources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o775]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: root.path)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: unsafe.sourceRoot,
        applicationSupportRoot: unsafe.applicationSupport
      )
    }

    let divergent = try PiResourceSnapshotFixture()
    defer { divergent.remove() }
    let snapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: divergent.sourceRoot,
      applicationSupportRoot: divergent.applicationSupport
    )
    let target = snapshot.appendingPathComponent("extensions/jidoka-code.ts")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    let divergentData = Data("divergent private data\n".utf8)
    try divergentData.write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: divergent.sourceRoot,
        applicationSupportRoot: divergent.applicationSupport
      )
    }
    #expect(try Data(contentsOf: target) == divergentData)

    let hardLinked = try PiResourceSnapshotFixture()
    defer { hardLinked.remove() }
    let linkedSnapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: hardLinked.sourceRoot,
      applicationSupportRoot: hardLinked.applicationSupport
    )
    let linkedTarget = linkedSnapshot.appendingPathComponent("extensions/jidoka-code.ts")
    let extraLink = hardLinked.root.appendingPathComponent("private-resource-hard-link")
    try FileManager.default.linkItem(at: linkedTarget, to: extraLink)
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: hardLinked.sourceRoot,
        applicationSupportRoot: hardLinked.applicationSupport
      )
    }
    #expect(FileManager.default.fileExists(atPath: extraLink.path))

    let unexpected = try PiResourceSnapshotFixture()
    defer { unexpected.remove() }
    let unexpectedSnapshot = try PackagedPiResourceSnapshot.prepare(
      sourceRoot: unexpected.sourceRoot,
      applicationSupportRoot: unexpected.applicationSupport
    )
    let unexpectedFile = unexpectedSnapshot.appendingPathComponent("unexpected-resource")
    let unexpectedData = Data("preserve me\n".utf8)
    try unexpectedData.write(to: unexpectedFile)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: unexpectedFile.path
    )
    #expect(throws: PackagedPiResourceSnapshotError.unsafeDestination) {
      _ = try PackagedPiResourceSnapshot.prepare(
        sourceRoot: unexpected.sourceRoot,
        applicationSupportRoot: unexpected.applicationSupport
      )
    }
    #expect(try Data(contentsOf: unexpectedFile) == unexpectedData)
  }
}

private func addSnapshotEveryoneWriteACL(to url: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = ["+a", "everyone allow write", url.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw CocoaError(.fileWriteNoPermission)
  }
}

private final class PiResourceSnapshotFixture: @unchecked Sendable {
  let root: URL
  let sourceRoot: URL
  let applicationSupport: URL
  let expectedFiles: Set<String>

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-pi-resource-snapshot-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let packaged = root.appendingPathComponent("packaged", isDirectory: true)
    sourceRoot = packaged.appendingPathComponent("Pi", isDirectory: true)
    applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    expectedFiles = Set(
      ["workflow-resources.json", "tui-resources.json"]
        + PiWorkflowResourceCatalog.expectedResourcePaths
        + PiTUIResourceCatalog.expectedResourcePaths
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: packaged,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o775]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: packaged.path)
    try FileManager.default.createDirectory(
      at: sourceRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    let repositoryResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/Pi", isDirectory: true)
    for relativePath in expectedFiles.sorted() {
      let source = repositoryResources.appendingPathComponent(relativePath)
      let destination = sourceRoot.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
      try FileManager.default.copyItem(at: source, to: destination)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: destination.path
      )
    }
    try PrivateDirectoryBoundary.ensure(applicationSupport)
  }

  func relativeFiles(at root: URL) throws -> Set<String> {
    try relativeEntries(at: root, directories: false)
  }

  func relativeDirectories(at root: URL) throws -> Set<String> {
    try relativeEntries(at: root, directories: true)
  }

  func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private func relativeEntries(at root: URL, directories: Bool) throws -> Set<String> {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
    else {
      return []
    }
    var result = Set<String>()
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == directories {
        result.insert(String(url.path.dropFirst(root.path.count + 1)))
      }
    }
    return result
  }
}
