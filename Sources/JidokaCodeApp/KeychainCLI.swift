import Foundation
import JidokaCodeCore

struct KeychainCLIReport: Codable, Sendable {
  let action: String
  let exists: Bool
  let sentinelSHA256: String?
}

enum KeychainCLI {
  static func run(arguments: [String]) throws -> KeychainCLIReport {
    let command = try KeychainProbeCommand.parse(arguments)
    let store = KeychainProbeStore()
    let result: KeychainProbeResult
    switch command {
    case .status:
      result = try store.status()
    case .create:
      result = try store.create()
    case .read:
      result = try store.readDigest()
    case .replace:
      result = try store.replace()
    case .delete:
      result = try store.delete()
    }
    return KeychainCLIReport(
      action: "keychain.\(command.rawValue)",
      exists: result.exists,
      sentinelSHA256: result.sentinelSHA256
    )
  }

  static func write(_ report: KeychainCLIReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}
