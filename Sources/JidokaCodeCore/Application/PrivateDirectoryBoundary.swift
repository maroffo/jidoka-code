import Darwin
import Foundation

public enum PrivateDirectoryBoundaryError: Error, Equatable, Sendable {
  case unsafePath
}

public enum PrivateDirectoryBoundary {
  public static func ensure(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw PrivateDirectoryBoundaryError.unsafePath
    }
    var metadata = stat()
    if FileManager.default.fileExists(atPath: url.path) {
      guard lstat(url.path, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0
      else {
        throw PrivateDirectoryBoundaryError.unsafePath
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard lstat(url.path, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid()
      else {
        throw PrivateDirectoryBoundaryError.unsafePath
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }
}
