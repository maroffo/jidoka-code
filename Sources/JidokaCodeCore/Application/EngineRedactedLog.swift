import Darwin
import Foundation

public enum EngineLogEventCode: String, Codable, Sendable {
  case startupPhase
  case startupFailed
  case initialized
  case commandSucceeded
  case commandRejected
}

public enum EngineStartupPhase: String, Codable, Sendable {
  case privateDirectory
  case instanceLock
  case lifecycleRecorder
  case paths
  case resourceSnapshot
  case database
  case herdrReadiness
  case hostSnapshot
  case runtimeConfiguration
  case serviceConstruction
  case credentialStatus
  case piPreflight
  case herdrPreflight
  case dispatchGate
  case runtimeReload
  case runtimeQuiesce
  case runtimeSnapshot
  case runtimeOwnership
  case runtimeRecovery
  case runtimeComponents
  case runtimeCoordinatorRecovery
  case runtimeStartupPass
  case pausedState
  case reconciliation
  case listener
}

public struct EngineLogRecord: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let event: EngineLogEventCode
  public let phase: EngineStartupPhase?
  public let command: EngineCommandKind?
  public let error: EngineClientErrorCode?

  public init(
    timestamp: Date,
    event: EngineLogEventCode,
    phase: EngineStartupPhase? = nil,
    command: EngineCommandKind?,
    error: EngineClientErrorCode?
  ) {
    self.timestamp = timestamp
    self.event = event
    self.phase = phase
    self.command = command
    self.error = error
  }
}

public protocol EngineEventLogging: Sendable {
  func record(_ record: EngineLogRecord) async
}

public actor NullEngineEventLogger: EngineEventLogging {
  public init() {}
  public func record(_ record: EngineLogRecord) {}
}

public enum EngineRedactedLogError: Error, Equatable, Sendable {
  case unsafeDirectory
  case unsafeFile
  case writeFailed
}

public actor EngineRedactedLogger: EngineEventLogging {
  public static let maximumBytes = 1_048_576

  public nonisolated let fileURL: URL
  public nonisolated let archiveURL: URL

  private let rootURL: URL

  public init(rootURL: URL, filename: String) throws {
    guard rootURL.isFileURL,
      rootURL.path.hasPrefix("/"),
      ["engine.jsonl", "bootstrap.jsonl"].contains(filename)
    else {
      throw EngineRedactedLogError.unsafeDirectory
    }
    try Self.ensurePrivateDirectory(rootURL)
    self.rootURL = rootURL
    fileURL = rootURL.appendingPathComponent(filename, isDirectory: false)
    archiveURL = rootURL.appendingPathComponent("\(filename).1", isDirectory: false)
    try Self.ensureLogFile(fileURL)
  }

  public func record(_ record: EngineLogRecord) {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(record)
      data.append(0x0A)
      try rotateIfNeeded(incomingBytes: data.count)
      let descriptor = open(
        fileURL.path,
        O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else { throw EngineRedactedLogError.unsafeFile }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFREG,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0,
        metadata.st_nlink == 1
      else {
        close(descriptor)
        throw EngineRedactedLogError.unsafeFile
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      // Logging must never change engine state or expand an error payload.
    }
  }

  private func rotateIfNeeded(incomingBytes: Int) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let current = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard current + incomingBytes > Self.maximumBytes else { return }
    if FileManager.default.fileExists(atPath: archiveURL.path) {
      try Self.requirePrivateRegularFile(archiveURL)
      try FileManager.default.removeItem(at: archiveURL)
    }
    try Self.requirePrivateRegularFile(fileURL)
    try FileManager.default.moveItem(at: fileURL, to: archiveURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
    try Self.ensureLogFile(fileURL)
  }

  private static func ensurePrivateDirectory(_ url: URL) throws {
    var metadata = stat()
    if FileManager.default.fileExists(atPath: url.path) {
      guard lstat(url.path, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0
      else {
        throw EngineRedactedLogError.unsafeDirectory
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

  private static func ensureLogFile(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try requirePrivateRegularFile(url)
      return
    }
    guard
      FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw EngineRedactedLogError.writeFailed
    }
    try requirePrivateRegularFile(url)
  }

  private static func requirePrivateRegularFile(_ url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o077) == 0
    else {
      throw EngineRedactedLogError.unsafeFile
    }
  }
}
