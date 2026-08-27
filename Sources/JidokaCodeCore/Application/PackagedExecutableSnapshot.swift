import CryptoKit
import Darwin
import Foundation
import Security

public enum PackagedExecutableSnapshotError: Error, Equatable, Sendable {
  case unsafeSource
  case invalidSignature
  case unsafeDestination
  case readFailed
}

public enum PackagedExecutableSnapshot {
  private static let maximumExecutableBytes = 64 * 1_048_576
  private static let herdrHostRequirement =
    "anchor apple generic and identifier \"com.maroffo.JidokaCode.HerdrHost\" "
    + "and certificate leaf[subject.OU] = \"X3Q42VNZDC\""

  public static func prepareHerdrHost(
    sourceURL: URL,
    applicationSupportRoot: URL
  ) throws -> URL {
    try prepareHerdrHost(
      sourceURL: sourceURL,
      applicationSupportRoot: applicationSupportRoot,
      signatureValidator: validHerdrHostSignature
    )
  }

  static func prepareHerdrHost(
    sourceURL: URL,
    applicationSupportRoot: URL,
    signatureValidator: (URL) -> Bool
  ) throws -> URL {
    let source = try canonicalSource(sourceURL)
    let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PackagedExecutableSnapshotError.unsafeSource }
    defer { _ = Darwin.close(descriptor) }

    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      opened.st_mode & S_IFMT == S_IFREG,
      opened.st_uid == 0 || opened.st_uid == geteuid(),
      opened.st_mode & 0o022 == 0,
      opened.st_mode & 0o111 != 0,
      opened.st_nlink == 1,
      opened.st_size >= 1,
      opened.st_size <= maximumExecutableBytes
    else {
      throw PackagedExecutableSnapshotError.unsafeSource
    }
    guard signatureValidator(source) else {
      throw PackagedExecutableSnapshotError.invalidSignature
    }
    try requirePath(source, matches: opened)
    let data = try read(descriptor: descriptor, metadata: opened)
    var afterRead = stat()
    guard fstat(descriptor, &afterRead) == 0, sameFile(opened, afterRead) else {
      throw PackagedExecutableSnapshotError.unsafeSource
    }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let applicationSupport = try PiTUIFileProtocol.canonicalExistingURL(applicationSupportRoot)
    guard try PiTUIFileProtocol.safePrivateDirectory(applicationSupport) else {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    let runtimeRoot = applicationSupport.appendingPathComponent("Runtime", isDirectory: true)
    let snapshotsRoot = runtimeRoot.appendingPathComponent(
      "HerdrHostSnapshots", isDirectory: true)
    let versionRoot = snapshotsRoot.appendingPathComponent(digest, isDirectory: true)
    try ensurePrivateDirectory(runtimeRoot, beneath: applicationSupport)
    try ensurePrivateDirectory(snapshotsRoot, beneath: runtimeRoot)
    try ensurePrivateDirectory(versionRoot, beneath: snapshotsRoot)

    let destination = versionRoot.appendingPathComponent(
      "JidokaCodeHerdrHost", isDirectory: false)
    do {
      try PiTUIFileProtocol.createPrivateFile(
        data: data,
        at: destination,
        idempotent: true
      )
    } catch {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    let destinationDescriptor = Darwin.open(
      destination.path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard destinationDescriptor >= 0 else {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    defer { _ = Darwin.close(destinationDescriptor) }
    var destinationMetadata = stat()
    guard fstat(destinationDescriptor, &destinationMetadata) == 0,
      DarwinACLAuthority.hasNoAllowEntries(destinationDescriptor),
      destinationMetadata.st_mode & S_IFMT == S_IFREG,
      destinationMetadata.st_uid == geteuid(),
      destinationMetadata.st_nlink == 1,
      destinationMetadata.st_size == data.count,
      fchmod(destinationDescriptor, 0o500) == 0,
      fsync(destinationDescriptor) == 0
    else {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    let persisted = try PiTUIFileProtocol.readPrivateFile(
      destination,
      maximumBytes: maximumExecutableBytes
    )
    guard persisted == data,
      try PiTUIFileProtocol.safeRegularFile(destination)
    else {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    guard signatureValidator(destination) else {
      var current = stat()
      if lstat(destination.path, &current) == 0,
        current.st_dev == destinationMetadata.st_dev,
        current.st_ino == destinationMetadata.st_ino
      {
        _ = unlink(destination.path)
      }
      throw PackagedExecutableSnapshotError.invalidSignature
    }
    return try PiTUIFileProtocol.canonicalExistingURL(destination)
  }

  private static func canonicalSource(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path else {
      throw PackagedExecutableSnapshotError.unsafeSource
    }
    let canonical = url.resolvingSymlinksInPath()
    guard canonical.path == url.path else {
      throw PackagedExecutableSnapshotError.unsafeSource
    }
    return canonical
  }

  private static func requirePath(_ url: URL, matches opened: stat) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0, sameFile(opened, current) else {
      throw PackagedExecutableSnapshotError.unsafeSource
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
      throw PackagedExecutableSnapshotError.readFailed
    }
    var data = Data(count: Int(metadata.st_size))
    try data.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw PackagedExecutableSnapshotError.readFailed
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
          throw PackagedExecutableSnapshotError.readFailed
        }
      }
    }
    return data
  }

  private static func ensurePrivateDirectory(_ url: URL, beneath parent: URL) throws {
    guard url.deletingLastPathComponent().path == parent.path else {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
    do {
      try PrivateDirectoryBoundary.ensure(url)
      guard try PiTUIFileProtocol.safePrivateDirectory(url) else {
        throw PackagedExecutableSnapshotError.unsafeDestination
      }
    } catch let error as PackagedExecutableSnapshotError {
      throw error
    } catch {
      throw PackagedExecutableSnapshotError.unsafeDestination
    }
  }

  private static func validHerdrHostSignature(_ url: URL) -> Bool {
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        herdrHostRequirement as CFString,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return false
    }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code
    else {
      return false
    }
    let flags = SecCSFlags(
      rawValue: UInt32(
        kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
          | kSecCSRestrictSymlinks
      )
    )
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }
}
