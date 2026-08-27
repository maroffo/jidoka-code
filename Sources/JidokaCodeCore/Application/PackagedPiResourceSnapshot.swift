import CryptoKit
import Darwin
import Foundation

public enum PackagedPiResourceSnapshotError: Error, Equatable, Sendable {
  case unsafeSource
  case invalidManifest
  case resourceDigestMismatch(String)
  case unsafeDestination
  case readFailed
}

struct PackagedPiResourceEntryEvidence: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case directory
    case file
  }

  let path: String
  let kind: Kind
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
  let permissions: UInt16
  let linkCount: UInt64
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let contentSHA256: String?
}

struct PackagedPiResourceEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let rootPath: String
  let rootDevice: UInt64
  let rootInode: UInt64
  let rootOwner: UInt32
  let rootPermissions: UInt16
  let entries: [PackagedPiResourceEntryEvidence]

  var evidenceSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map(PiTUIFileProtocol.sha256) ?? ""
  }

  var inventorySHA256: String {
    let inventory = Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        entry.contentSHA256.map { (entry.path, $0) }
      }
    )
    return (try? JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys]))
      .map(PiTUIFileProtocol.sha256) ?? ""
  }
}

public enum PackagedPiResourceSnapshot {
  private static let maximumResourceBytes = 1_048_576
  private static let manifestPaths = ["tui-resources.json", "workflow-resources.json"]

  public static func inspect(resourceRoot: URL) throws -> String {
    let evidence = try inspectEvidence(resourceRoot: resourceRoot)
    guard GitHubInputValidation.validSHA256(evidence.inventorySHA256) else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    return evidence.inventorySHA256
  }

  static func inspectEvidence(
    resourceRoot: URL,
    entryInspection: (String, URL) throws -> Void = { _, _ in }
  ) throws -> PackagedPiResourceEvidence {
    let root: URL
    do {
      root = try PiTUIFileProtocol.canonicalExistingURL(resourceRoot)
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    guard root.standardizedFileURL.path == resourceRoot.standardizedFileURL.path,
      try PiTUIFileProtocol.safePrivateDirectory(root)
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    let rootDescriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    defer { _ = Darwin.close(rootDescriptor) }
    let openedRoot = try destinationDirectoryMetadata(descriptor: rootDescriptor)
    try entryInspection("", root)
    try requirePath(root, matches: openedRoot, source: false)

    let workflowManifest = try readDestinationFile(
      relativePath: "workflow-resources.json",
      root: root,
      rootDescriptor: rootDescriptor,
      entryInspection: entryInspection
    ).data
    let tuiManifest = try readDestinationFile(
      relativePath: "tui-resources.json",
      root: root,
      rootDescriptor: rootDescriptor,
      entryInspection: entryInspection
    ).data
    let workflowResources = try decodeManifest(
      workflowManifest,
      expectedDigest: PiWorkflowResourceCatalog.workflowManifestSHA256,
      expectedPaths: PiWorkflowResourceCatalog.expectedResourcePaths
    )
    let tuiResources = try decodeManifest(
      tuiManifest,
      expectedDigest: PiTUIResourceCatalog.manifestSHA256,
      expectedPaths: PiTUIResourceCatalog.expectedResourcePaths
    )
    var expectedDigests = workflowResources
    for (path, digest) in tuiResources {
      if let existing = expectedDigests[path], existing != digest {
        throw PackagedPiResourceSnapshotError.invalidManifest
      }
      expectedDigests[path] = digest
    }
    expectedDigests["workflow-resources.json"] = Self.sha256(workflowManifest)
    expectedDigests["tui-resources.json"] = Self.sha256(tuiManifest)
    let expectedFiles = Set(expectedDigests.keys)
    let expectedDirectories = directoryPaths(for: expectedFiles)
    var entries: [PackagedPiResourceEntryEvidence] = []
    for relativePath in ([""] + expectedDirectories.sorted(by: directoryPrecedes)) {
      let inspected = try inspectDestinationDirectory(
        relativePath: relativePath,
        root: root,
        rootDescriptor: rootDescriptor,
        expectedFiles: expectedFiles,
        expectedDirectories: expectedDirectories,
        entryInspection: entryInspection
      )
      if relativePath != "" { entries.append(inspected) }
    }
    for relativePath in expectedFiles.sorted() {
      let inspected = try readDestinationFile(
        relativePath: relativePath,
        root: root,
        rootDescriptor: rootDescriptor,
        entryInspection: entryInspection
      )
      guard inspected.entry.contentSHA256 == expectedDigests[relativePath] else {
        throw PackagedPiResourceSnapshotError.resourceDigestMismatch(relativePath)
      }
      entries.append(inspected.entry)
    }
    entries.sort { $0.path < $1.path }
    var finalRoot = stat()
    guard fstat(rootDescriptor, &finalRoot) == 0,
      sameFile(openedRoot, finalRoot),
      openedRoot.st_ctimespec.tv_sec == finalRoot.st_ctimespec.tv_sec,
      openedRoot.st_ctimespec.tv_nsec == finalRoot.st_ctimespec.tv_nsec
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    try requirePath(root, matches: finalRoot, source: false)
    let evidence = PackagedPiResourceEvidence(
      schemaVersion: 1,
      rootPath: root.path,
      rootDevice: UInt64(finalRoot.st_dev),
      rootInode: finalRoot.st_ino,
      rootOwner: finalRoot.st_uid,
      rootPermissions: UInt16(finalRoot.st_mode & 0o777),
      entries: entries
    )
    guard GitHubInputValidation.validSHA256(evidence.evidenceSHA256) else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    return evidence
  }

  public static func prepare(
    sourceRoot: URL,
    applicationSupportRoot: URL
  ) throws -> URL {
    try prepare(
      sourceRoot: sourceRoot,
      applicationSupportRoot: applicationSupportRoot,
      sourceInspection: { _ in }
    )
  }

  static func prepare(
    sourceRoot: URL,
    applicationSupportRoot: URL,
    sourceInspection: (URL) throws -> Void
  ) throws -> URL {
    let source = try canonicalSourceRoot(sourceRoot)
    let rootDescriptor = Darwin.open(
      source.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else { throw PackagedPiResourceSnapshotError.unsafeSource }
    defer { _ = Darwin.close(rootDescriptor) }

    let openedRoot = try sourceDirectoryMetadata(descriptor: rootDescriptor)
    try sourceInspection(source)
    try requirePath(source, matches: openedRoot, source: true)

    let workflowManifest = try readSourceFile(
      relativePath: "workflow-resources.json",
      rootDescriptor: rootDescriptor
    )
    let tuiManifest = try readSourceFile(
      relativePath: "tui-resources.json",
      rootDescriptor: rootDescriptor
    )
    let workflowResources = try decodeManifest(
      workflowManifest,
      expectedDigest: PiWorkflowResourceCatalog.workflowManifestSHA256,
      expectedPaths: PiWorkflowResourceCatalog.expectedResourcePaths
    )
    let tuiResources = try decodeManifest(
      tuiManifest,
      expectedDigest: PiTUIResourceCatalog.manifestSHA256,
      expectedPaths: PiTUIResourceCatalog.expectedResourcePaths
    )

    var expectedDigests = workflowResources
    for (path, digest) in tuiResources {
      if let existing = expectedDigests[path], existing != digest {
        throw PackagedPiResourceSnapshotError.invalidManifest
      }
      expectedDigests[path] = digest
    }
    expectedDigests["workflow-resources.json"] = Self.sha256(workflowManifest)
    expectedDigests["tui-resources.json"] = Self.sha256(tuiManifest)

    var sourceData: [String: Data] = [
      "workflow-resources.json": workflowManifest,
      "tui-resources.json": tuiManifest,
    ]
    for path in expectedDigests.keys.sorted() where sourceData[path] == nil {
      let data = try readSourceFile(relativePath: path, rootDescriptor: rootDescriptor)
      guard Self.sha256(data) == expectedDigests[path] else {
        throw PackagedPiResourceSnapshotError.resourceDigestMismatch(path)
      }
      sourceData[path] = data
    }
    try requirePath(source, matches: openedRoot, source: true)

    let treeDigest = try inventoryDigest(expectedDigests)
    let applicationSupport = try privateApplicationSupport(applicationSupportRoot)
    let snapshots = applicationSupport.appendingPathComponent("PiResources", isDirectory: true)
    let version = snapshots.appendingPathComponent(treeDigest, isDirectory: true)
    try ensurePrivateDirectory(snapshots, beneath: applicationSupport)
    try ensurePrivateDirectory(version, beneath: snapshots)

    let expectedDirectories = directoryPaths(for: Set(expectedDigests.keys))
    for relativePath in expectedDirectories.sorted(by: directoryPrecedes) {
      try ensurePrivateDirectory(
        version.appendingPathComponent(relativePath, isDirectory: true),
        beneath: version.appendingPathComponent(
          parentPath(relativePath),
          isDirectory: true
        )
      )
    }
    for relativePath in expectedDigests.keys.sorted() {
      guard let data = sourceData[relativePath] else {
        throw PackagedPiResourceSnapshotError.invalidManifest
      }
      try publish(
        data: data,
        expectedDigest: expectedDigests[relativePath]!,
        destination: version.appendingPathComponent(relativePath, isDirectory: false)
      )
    }
    try validateInventory(
      root: version,
      expectedFiles: Set(expectedDigests.keys),
      expectedDirectories: expectedDirectories
    )
    _ = try PiTUIResourceCatalog.inspect(resourceRoot: version)
    try requirePath(source, matches: openedRoot, source: true)
    return try PiTUIFileProtocol.canonicalExistingURL(version)
  }

  private static func canonicalSourceRoot(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    let canonical = url.resolvingSymlinksInPath()
    guard canonical.path == url.path else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    return canonical
  }

  private static func sourceDirectoryMetadata(descriptor: Int32) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == 0 || metadata.st_uid == geteuid(),
      metadata.st_mode & 0o022 == 0
    else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    return metadata
  }

  private static func readSourceFile(
    relativePath: String,
    rootDescriptor: Int32
  ) throws -> Data {
    guard validRelativePath(relativePath) else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    let components = relativePath.split(separator: "/").map(String.init)
    var directories: [Int32] = []
    var current = rootDescriptor
    defer {
      for descriptor in directories.reversed() { _ = Darwin.close(descriptor) }
    }
    for component in components.dropLast() {
      let descriptor = Darwin.openat(
        current,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else { throw PackagedPiResourceSnapshotError.unsafeSource }
      _ = try sourceDirectoryMetadata(descriptor: descriptor)
      directories.append(descriptor)
      current = descriptor
    }
    guard let leaf = components.last else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    let descriptor = Darwin.openat(current, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PackagedPiResourceSnapshotError.unsafeSource }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == 0 || opened.st_uid == geteuid(),
      opened.st_mode & 0o022 == 0,
      opened.st_nlink == 1,
      opened.st_size >= 1,
      opened.st_size <= maximumResourceBytes
    else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    let data = try read(descriptor: descriptor, metadata: opened)
    var after = stat()
    guard fstat(descriptor, &after) == 0, sameFile(opened, after) else {
      throw PackagedPiResourceSnapshotError.unsafeSource
    }
    return data
  }

  private static func decodeManifest(
    _ data: Data,
    expectedDigest: String,
    expectedPaths: Set<String>
  ) throws -> [String: String] {
    guard sha256(data) == expectedDigest,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["contractVersion", "resources", "schemaVersion"]),
      object["schemaVersion"] as? Int == 1,
      object["contractVersion"] as? String == PiWorkflowResourceCatalog.contractVersion,
      let resources = object["resources"] as? [String: String],
      Set(resources.keys) == expectedPaths,
      resources.allSatisfy({ validRelativePath($0.key) && validSHA256($0.value) })
    else {
      throw PackagedPiResourceSnapshotError.invalidManifest
    }
    return resources
  }

  private static func publish(
    data: Data,
    expectedDigest: String,
    destination: URL
  ) throws {
    guard sha256(data) == expectedDigest else {
      throw PackagedPiResourceSnapshotError.resourceDigestMismatch(destination.lastPathComponent)
    }
    try recoverPublicationArtifacts(data: data, destination: destination)
    do {
      try PiTUIFileProtocol.createPrivateFile(data: data, at: destination, idempotent: true)
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    let descriptor = Darwin.open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == geteuid(),
      opened.st_nlink == 1,
      opened.st_size == data.count,
      fchmod(descriptor, 0o400) == 0,
      fsync(descriptor) == 0
    else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    var sealed = stat()
    guard fstat(descriptor, &sealed) == 0,
      sameFile(opened, sealed),
      sealed.st_mode & 0o777 == 0o400
    else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    try requirePath(destination, matches: sealed, source: false)
    let persisted: Data
    do {
      persisted = try PiTUIFileProtocol.readPrivateFile(
        destination,
        maximumBytes: maximumResourceBytes
      )
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    guard persisted == data,
      sha256(persisted) == expectedDigest,
      try PiTUIFileProtocol.safePrivateFile(destination, maximumBytes: maximumResourceBytes)
    else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
  }

  private static func recoverPublicationArtifacts(
    data: Data,
    destination: URL
  ) throws {
    let parent = destination.deletingLastPathComponent()
    let finalName = destination.lastPathComponent
    guard try PiTUIFileProtocol.safePrivateDirectory(parent),
      !finalName.isEmpty,
      !finalName.contains("/")
    else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0,
      DarwinACLAuthority.hasNoAllowEntries(parentDescriptor)
    else {
      if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    defer { _ = Darwin.close(parentDescriptor) }

    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    let preparedName = ".\(finalName).prepared"
    let stagingPrefix = ".\(finalName)."
    let stagingSuffix = ".staging"
    for name in names.sorted() {
      let isPrepared = name == preparedName
      let isStaging: Bool
      if name.hasPrefix(stagingPrefix), name.hasSuffix(stagingSuffix) {
        let start = name.index(name.startIndex, offsetBy: stagingPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -stagingSuffix.count)
        let identifier = String(name[start..<end])
        isStaging = UUID(uuidString: identifier)?.uuidString.lowercased() == identifier
      } else {
        isStaging = false
      }
      guard isPrepared || isStaging else { continue }

      let descriptor = Darwin.openat(
        parentDescriptor,
        name,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      var metadata = stat()
      let validMetadata =
        fstat(descriptor, &metadata) == 0
        && DarwinACLAuthority.hasNoAllowEntries(descriptor)
        && metadata.st_mode & S_IFMT == S_IFREG
        && metadata.st_uid == geteuid()
        && metadata.st_mode & 0o777 == 0o600
        && metadata.st_nlink == 1
        && metadata.st_size >= 0
        && metadata.st_size <= data.count
      let artifactData: Data?
      if validMetadata, metadata.st_size == 0 {
        artifactData = Data()
      } else if validMetadata {
        artifactData = try? read(descriptor: descriptor, metadata: metadata)
      } else {
        artifactData = nil
      }
      var after = stat()
      let stable = fstat(descriptor, &after) == 0 && sameFile(metadata, after)
      _ = Darwin.close(descriptor)
      guard let artifactData, stable,
        isPrepared ? artifactData == data : data.starts(with: artifactData)
      else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      guard unlinkat(parentDescriptor, name, 0) == 0,
        fsync(parentDescriptor) == 0
      else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
    }
  }

  private static func validateInventory(
    root: URL,
    expectedFiles: Set<String>,
    expectedDirectories: Set<String>
  ) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false }
      )
    else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    var files = Set<String>()
    var directories = Set<String>()
    for case let url as URL in enumerator {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      if values.isDirectory == true {
        guard try PiTUIFileProtocol.safePrivateDirectory(url) else {
          throw PackagedPiResourceSnapshotError.unsafeDestination
        }
        directories.insert(relative)
      } else if values.isRegularFile == true {
        guard try PiTUIFileProtocol.safePrivateFile(url, maximumBytes: maximumResourceBytes)
        else {
          throw PackagedPiResourceSnapshotError.unsafeDestination
        }
        files.insert(relative)
      } else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
    }
    guard files == expectedFiles, directories == expectedDirectories else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
  }

  private static func inspectDestinationDirectory(
    relativePath: String,
    root: URL,
    rootDescriptor: Int32,
    expectedFiles: Set<String>,
    expectedDirectories: Set<String>,
    entryInspection: (String, URL) throws -> Void
  ) throws -> PackagedPiResourceEntryEvidence {
    let descriptor = try openDestinationDirectory(
      relativePath: relativePath,
      rootDescriptor: rootDescriptor
    )
    let stream = fdopendir(descriptor)
    guard let stream else {
      _ = Darwin.close(descriptor)
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    defer { closedir(stream) }
    let directoryDescriptor = dirfd(stream)
    let before = try destinationDirectoryMetadata(descriptor: directoryDescriptor)
    let url =
      relativePath.isEmpty
      ? root
      : root.appendingPathComponent(relativePath, isDirectory: true)
    try entryInspection(relativePath, url)
    var names = Set<String>()
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      guard !name.isEmpty, names.insert(name).inserted else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
    }
    let expectedNames = Set(
      expectedFiles.filter { parentPath($0) == relativePath }.map {
        URL(fileURLWithPath: $0).lastPathComponent
      }
        + expectedDirectories.filter { parentPath($0) == relativePath }.map {
          URL(fileURLWithPath: $0).lastPathComponent
        }
    )
    var after = stat()
    guard names == expectedNames,
      fstat(directoryDescriptor, &after) == 0,
      sameFile(before, after),
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    try requirePath(url, matches: after, source: false)
    return destinationEntry(relativePath: relativePath, kind: .directory, metadata: after)
  }

  private static func openDestinationDirectory(
    relativePath: String,
    rootDescriptor: Int32
  ) throws -> Int32 {
    var descriptor = Darwin.dup(rootDescriptor)
    guard descriptor >= 0 else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    if relativePath.isEmpty { return descriptor }
    for component in relativePath.split(separator: "/").map(String.init) {
      let next = Darwin.openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      _ = Darwin.close(descriptor)
      guard next >= 0 else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      descriptor = next
    }
    return descriptor
  }

  private static func destinationDirectoryMetadata(descriptor: Int32) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o700,
      metadata.st_nlink >= 2
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    return metadata
  }

  private static func readDestinationFile(
    relativePath: String,
    root: URL,
    rootDescriptor: Int32,
    entryInspection: (String, URL) throws -> Void
  ) throws -> (data: Data, entry: PackagedPiResourceEntryEvidence) {
    guard validRelativePath(relativePath) else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    let components = relativePath.split(separator: "/").map(String.init)
    guard let leaf = components.last else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    var directoryDescriptors: [Int32] = []
    var directoryMetadata: [stat] = []
    var currentDescriptor = rootDescriptor
    for component in components.dropLast() {
      let descriptor = Darwin.openat(
        currentDescriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      do {
        directoryMetadata.append(try destinationDirectoryMetadata(descriptor: descriptor))
      } catch {
        _ = Darwin.close(descriptor)
        throw error
      }
      directoryDescriptors.append(descriptor)
      currentDescriptor = descriptor
    }
    defer {
      for descriptor in directoryDescriptors.reversed() { _ = Darwin.close(descriptor) }
    }
    let descriptor = Darwin.openat(
      currentDescriptor,
      leaf,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(),
      before.st_mode & 0o777 == 0o400,
      before.st_nlink == 1,
      before.st_size >= 1,
      before.st_size <= maximumResourceBytes
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    let url = root.appendingPathComponent(relativePath, isDirectory: false)
    try entryInspection(relativePath, url)
    let data = try read(descriptor: descriptor, metadata: before)
    var after = stat()
    var current = stat()
    guard fstat(descriptor, &after) == 0,
      fstatat(currentDescriptor, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
      sameFile(before, after),
      sameFile(after, current),
      sameChangeTime(before, after),
      sameChangeTime(after, current)
    else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    for index in directoryDescriptors.indices {
      let parentDescriptor = index == 0 ? rootDescriptor : directoryDescriptors[index - 1]
      var opened = stat()
      var named = stat()
      guard fstat(directoryDescriptors[index], &opened) == 0,
        fstatat(parentDescriptor, components[index], &named, AT_SYMLINK_NOFOLLOW) == 0,
        sameFile(directoryMetadata[index], opened),
        sameFile(opened, named),
        sameChangeTime(directoryMetadata[index], opened),
        sameChangeTime(opened, named)
      else { throw PackagedPiResourceSnapshotError.unsafeDestination }
    }
    return (
      data,
      destinationEntry(
        relativePath: relativePath,
        kind: .file,
        metadata: after,
        contentSHA256: sha256(data)
      )
    )
  }

  private static func destinationEntry(
    relativePath: String,
    kind: PackagedPiResourceEntryEvidence.Kind,
    metadata: stat,
    contentSHA256: String? = nil
  ) -> PackagedPiResourceEntryEvidence {
    PackagedPiResourceEntryEvidence(
      path: relativePath,
      kind: kind,
      device: UInt64(metadata.st_dev),
      inode: metadata.st_ino,
      owner: metadata.st_uid,
      permissions: UInt16(metadata.st_mode & 0o777),
      linkCount: UInt64(metadata.st_nlink),
      size: Int64(metadata.st_size),
      modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
      contentSHA256: contentSHA256
    )
  }

  private static func privateApplicationSupport(_ url: URL) throws -> URL {
    do {
      let canonical = try PiTUIFileProtocol.canonicalExistingURL(url)
      guard try PiTUIFileProtocol.safePrivateDirectory(canonical) else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
      return canonical
    } catch let error as PackagedPiResourceSnapshotError {
      throw error
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
  }

  private static func ensurePrivateDirectory(_ url: URL, beneath parent: URL) throws {
    guard url.deletingLastPathComponent().path == parent.path else {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
    do {
      try PrivateDirectoryBoundary.ensure(url)
      guard try PiTUIFileProtocol.safePrivateDirectory(url) else {
        throw PackagedPiResourceSnapshotError.unsafeDestination
      }
    } catch let error as PackagedPiResourceSnapshotError {
      throw error
    } catch {
      throw PackagedPiResourceSnapshotError.unsafeDestination
    }
  }

  private static func requirePath(
    _ url: URL,
    matches opened: stat,
    source: Bool
  ) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0, sameFile(opened, current) else {
      throw source
        ? PackagedPiResourceSnapshotError.unsafeSource
        : PackagedPiResourceSnapshotError.unsafeDestination
    }
  }

  private static func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev
      && left.st_ino == right.st_ino
      && left.st_size == right.st_size
      && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
      && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
  }

  private static func sameChangeTime(_ left: stat, _ right: stat) -> Bool {
    left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
      && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
  }

  private static func read(descriptor: Int32, metadata: stat) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw PackagedPiResourceSnapshotError.readFailed
    }
    var data = Data(count: Int(metadata.st_size))
    try data.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw PackagedPiResourceSnapshotError.readFailed
      }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(
          descriptor,
          baseAddress.advanced(by: offset),
          buffer.count - offset
        )
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw PackagedPiResourceSnapshotError.readFailed
        }
      }
    }
    return data
  }

  private static func inventoryDigest(_ inventory: [String: String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
    return sha256(data)
  }

  private static func directoryPaths(for files: Set<String>) -> Set<String> {
    var result = Set<String>()
    for file in files {
      var components = file.split(separator: "/").map(String.init)
      _ = components.popLast()
      while !components.isEmpty {
        result.insert(components.joined(separator: "/"))
        _ = components.popLast()
      }
    }
    return result
  }

  private static func directoryPrecedes(_ left: String, _ right: String) -> Bool {
    let leftDepth = left.split(separator: "/").count
    let rightDepth = right.split(separator: "/").count
    return leftDepth == rightDepth ? left < right : leftDepth < rightDepth
  }

  private static func parentPath(_ path: String) -> String {
    guard let separator = path.lastIndex(of: "/") else { return "" }
    return String(path[..<separator])
  }

  private static func validRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
      !value.contains("\u{0}")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  private static func validSHA256(_ value: String) -> Bool {
    value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
