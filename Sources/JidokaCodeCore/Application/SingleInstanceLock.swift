import Darwin
import Foundation

public enum SingleInstanceLockError: Error, Equatable, Sendable {
  case unsafeDirectory
  case unsafeLockFile
  case lockFailed(Int32)
}

public final class SingleInstanceLock: @unchecked Sendable {
  public let ownsLock: Bool
  public let lockFileURL: URL

  private let releaseLock = NSLock()
  private var descriptor: Int32 = -1

  public init(directoryURL: URL, filename: String = "ui-instance.lock") throws {
    guard directoryURL.isFileURL,
      directoryURL.path.hasPrefix("/"),
      ["ui-instance.lock", "engine-instance.lock"].contains(filename)
    else {
      throw SingleInstanceLockError.unsafeDirectory
    }
    try Self.ensurePrivateDirectory(directoryURL)
    lockFileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
    let descriptor = open(
      lockFileURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw SingleInstanceLockError.lockFailed(errno)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o077) == 0
    else {
      close(descriptor)
      throw SingleInstanceLockError.unsafeLockFile
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      self.descriptor = descriptor
      ownsLock = true
      do {
        try Self.recordOwner(descriptor)
      } catch {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = -1
        throw error
      }
    } else if errno == EWOULDBLOCK {
      close(descriptor)
      ownsLock = false
    } else {
      let code = errno
      close(descriptor)
      throw SingleInstanceLockError.lockFailed(code)
    }
  }

  public func release() {
    releaseLock.lock()
    defer { releaseLock.unlock() }
    guard descriptor >= 0 else { return }
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }

  deinit {
    release()
  }

  private static func ensurePrivateDirectory(_ url: URL) throws {
    var metadata = stat()
    if FileManager.default.fileExists(atPath: url.path) {
      guard lstat(url.path, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0
      else {
        throw SingleInstanceLockError.unsafeDirectory
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func recordOwner(_ descriptor: Int32) throws {
    let data = Data("pid=\(getpid())\n".utf8)
    guard ftruncate(descriptor, 0) == 0,
      lseek(descriptor, 0, SEEK_SET) == 0
    else {
      throw SingleInstanceLockError.lockFailed(errno)
    }
    let written = data.withUnsafeBytes { bytes in
      Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }
    guard written == data.count, fsync(descriptor) == 0 else {
      throw SingleInstanceLockError.lockFailed(errno)
    }
  }
}
