import Darwin
import Foundation

@testable import JidokaCodeCore

enum ProcessIdentityFixtureRecordError: Error {
  case malformedRecord
  case recordingTimedOut
}

struct ProcessIdentityFixtureRecord {
  static let sessionEscapeScript: URL = {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "scripts/tests/fixtures/process-identity-session-escape.py",
        isDirectory: false
      )
  }()

  static func load(from recordFile: URL) async throws -> SupervisedProcessIdentity {
    for _ in 0..<4_000 {
      if FileManager.default.fileExists(atPath: recordFile.path) {
        return try decode(Data(contentsOf: recordFile))
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw ProcessIdentityFixtureRecordError.recordingTimedOut
  }

  private static func decode(_ data: Data) throws -> SupervisedProcessIdentity {
    guard data.count <= 128, let value = String(data: data, encoding: .utf8) else {
      throw ProcessIdentityFixtureRecordError.malformedRecord
    }
    let fields = value.split(whereSeparator: \Character.isWhitespace)
    guard fields.count == 3,
      let processID = pid_t(fields[0]), processID > 0,
      let startSeconds = UInt64(fields[1]),
      let startMicroseconds = UInt64(fields[2]), startMicroseconds < 1_000_000
    else {
      throw ProcessIdentityFixtureRecordError.malformedRecord
    }
    return SupervisedProcessIdentity(
      processID: processID,
      startSeconds: startSeconds,
      startMicroseconds: startMicroseconds
    )
  }
}
