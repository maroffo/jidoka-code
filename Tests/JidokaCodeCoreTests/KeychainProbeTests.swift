import Foundation
import Security
import Testing

@testable import JidokaCodeCore

@Suite("Keychain isolation contract")
struct KeychainProbeTests {
  @Test("probe identifiers are fixed")
  func fixedIdentifiers() {
    #expect(KeychainProbeConstants.service == "com.maroffo.JidokaCode.test.github")
    #expect(KeychainProbeConstants.account == "eabf21b6-02df-4854-b9a8-c8a21eafdbca")
    #expect(KeychainProbeConstants.sentinelByteCount == 32)
  }

  @Test("closed commands parse", arguments: KeychainProbeCommand.allCases)
  func commandsParse(command: KeychainProbeCommand) throws {
    #expect(try KeychainProbeCommand.parse([command.rawValue]) == command)
  }

  @Test(
    "arbitrary Keychain commands fail closed",
    arguments: [
      [String](),
      ["status", "extra"],
      ["create", "caller-value"],
      ["read", "other-service"],
      ["export"],
    ])
  func invalidCommands(arguments: [String]) {
    #expect(throws: KeychainProbeError.invalidArguments) {
      try KeychainProbeCommand.parse(arguments)
    }
  }

  @Test("digest is lowercase SHA-256")
  func digestShape() throws {
    let digest = KeychainProbeDigest.hex(of: Data("synthetic".utf8))
    #expect(digest == "b3cc0475bb78a5026098858e9889acf666d31062d513d303314eca31d36e72f2")
    #expect(KeychainProbeDigest.isValidSHA256(digest))
    #expect(!KeychainProbeDigest.isValidSHA256(digest.uppercased()))
    #expect(!KeychainProbeDigest.isValidSHA256(String(repeating: "a", count: 63)))
    #expect(
      try KeychainProbeResult(exists: true, sentinelSHA256: digest).sentinelSHA256 == digest)
    #expect(throws: KeychainProbeError.invalidResult) {
      try KeychainProbeResult(exists: false, sentinelSHA256: digest)
    }
  }

  @Test("Security status classification is total for known boundaries")
  func statusClassification() {
    #expect(KeychainProbeOSStatus.classify(errSecSuccess) == .success)
    #expect(KeychainProbeOSStatus.classify(errSecItemNotFound) == .itemNotFound)
    #expect(KeychainProbeOSStatus.classify(errSecDuplicateItem) == .duplicateItem)
    #expect(KeychainProbeOSStatus.classify(-999) == .unexpected(-999))
  }
}
