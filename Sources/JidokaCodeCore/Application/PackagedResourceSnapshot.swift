import CryptoKit
import Darwin
import Foundation

public enum PackagedResourceSnapshotError: Error, Equatable, Sendable {
  case unsafeSource
  case digestMismatch
  case unsafeDestination
  case readFailed
}

public enum PackagedResourceSnapshot {
  private static let maximumModelCatalogScriptBytes = 1_048_576

  public static func prepareModelCatalogScript(
    sourceURL: URL,
    expectedSHA256: String,
    applicationSupportRoot: URL
  ) throws -> URL {
    try prepareModelCatalogScript(
      sourceURL: sourceURL,
      expectedSHA256: expectedSHA256,
      applicationSupportRoot: applicationSupportRoot,
      sourceInspection: { _ in }
    )
  }

  static func prepareModelCatalogScript(
    sourceURL: URL,
    expectedSHA256: String,
    applicationSupportRoot: URL,
    sourceInspection: (URL) throws -> Void
  ) throws -> URL {
    guard expectedSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil else {
      throw PackagedResourceSnapshotError.digestMismatch
    }
    let source = try canonicalSource(sourceURL)
    let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PackagedResourceSnapshotError.unsafeSource }
    defer { _ = Darwin.close(descriptor) }

    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == 0 || opened.st_uid == geteuid(),
      opened.st_mode & 0o022 == 0,
      opened.st_nlink == 1,
      opened.st_size >= 1,
      opened.st_size <= maximumModelCatalogScriptBytes
    else {
      throw PackagedResourceSnapshotError.unsafeSource
    }
    try sourceInspection(source)
    try requirePath(source, matches: opened, source: true)
    let data = try read(descriptor: descriptor, metadata: opened)
    var afterRead = stat()
    guard fstat(descriptor, &afterRead) == 0, sameFile(opened, afterRead) else {
      throw PackagedResourceSnapshotError.unsafeSource
    }
    try requirePath(source, matches: afterRead, source: true)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA256 else {
      throw PackagedResourceSnapshotError.digestMismatch
    }

    let applicationSupport = try privateApplicationSupport(applicationSupportRoot)
    let modelCatalogRoot = applicationSupport.appendingPathComponent(
      "ModelCatalog", isDirectory: true)
    let scriptsRoot = modelCatalogRoot.appendingPathComponent("Scripts", isDirectory: true)
    let versionRoot = scriptsRoot.appendingPathComponent(expectedSHA256, isDirectory: true)
    try ensurePrivateDirectory(modelCatalogRoot, beneath: applicationSupport)
    try ensurePrivateDirectory(scriptsRoot, beneath: modelCatalogRoot)
    try ensurePrivateDirectory(versionRoot, beneath: scriptsRoot)

    let destination = versionRoot.appendingPathComponent(
      "jidoka-model-catalog.mjs", isDirectory: false)
    do {
      try PiTUIFileProtocol.createPrivateFile(
        data: data,
        at: destination,
        idempotent: true
      )
    } catch {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    let destinationDescriptor = Darwin.open(
      destination.path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard destinationDescriptor >= 0 else {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    defer { _ = Darwin.close(destinationDescriptor) }
    var destinationMetadata = stat()
    guard fstat(destinationDescriptor, &destinationMetadata) == 0,
      DarwinACLAuthority.hasNoAllowEntries(destinationDescriptor),
      destinationMetadata.st_mode & S_IFMT == S_IFREG,
      destinationMetadata.st_uid == geteuid(),
      destinationMetadata.st_nlink == 1,
      destinationMetadata.st_size == data.count,
      fchmod(destinationDescriptor, 0o400) == 0,
      fsync(destinationDescriptor) == 0
    else {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    var sealedMetadata = stat()
    guard fstat(destinationDescriptor, &sealedMetadata) == 0,
      sameFile(destinationMetadata, sealedMetadata),
      sealedMetadata.st_mode & 0o777 == 0o400
    else {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    try requirePath(destination, matches: sealedMetadata, source: false)
    let persisted: Data
    do {
      persisted = try PiTUIFileProtocol.readPrivateFile(
        destination,
        maximumBytes: maximumModelCatalogScriptBytes
      )
    } catch {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    guard persisted == data,
      try PiTUIFileProtocol.safePrivateFile(
        destination,
        maximumBytes: maximumModelCatalogScriptBytes
      )
    else {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    try requirePath(destination, matches: sealedMetadata, source: false)
    return try PiTUIFileProtocol.canonicalExistingURL(destination)
  }

  private static func canonicalSource(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"),
      url.standardizedFileURL.path == url.path,
      url.lastPathComponent == "jidoka-model-catalog.mjs"
    else {
      throw PackagedResourceSnapshotError.unsafeSource
    }
    let canonical = url.resolvingSymlinksInPath()
    guard canonical.path == url.path else {
      throw PackagedResourceSnapshotError.unsafeSource
    }
    return canonical
  }

  private static func privateApplicationSupport(_ url: URL) throws -> URL {
    do {
      let canonical = try PiTUIFileProtocol.canonicalExistingURL(url)
      guard try PiTUIFileProtocol.safePrivateDirectory(canonical) else {
        throw PackagedResourceSnapshotError.unsafeDestination
      }
      return canonical
    } catch let error as PackagedResourceSnapshotError {
      throw error
    } catch {
      throw PackagedResourceSnapshotError.unsafeDestination
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
        ? PackagedResourceSnapshotError.unsafeSource
        : PackagedResourceSnapshotError.unsafeDestination
    }
  }

  private static func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev
      && left.st_ino == right.st_ino
      && left.st_size == right.st_size
      && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
      && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
  }

  private static func read(descriptor: Int32, metadata: stat) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw PackagedResourceSnapshotError.readFailed
    }
    var data = Data(count: Int(metadata.st_size))
    try data.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw PackagedResourceSnapshotError.readFailed
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
          throw PackagedResourceSnapshotError.readFailed
        }
      }
    }
    return data
  }

  private static func ensurePrivateDirectory(_ url: URL, beneath parent: URL) throws {
    guard url.deletingLastPathComponent().path == parent.path else {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
    do {
      try PrivateDirectoryBoundary.ensure(url)
      guard try PiTUIFileProtocol.safePrivateDirectory(url) else {
        throw PackagedResourceSnapshotError.unsafeDestination
      }
    } catch let error as PackagedResourceSnapshotError {
      throw error
    } catch {
      throw PackagedResourceSnapshotError.unsafeDestination
    }
  }
}
