import Testing

@testable import JidokaCodeCore

@Suite("Pi probe closed command contract")
struct PiProbeContractTests {
  @Test("closed commands parse")
  func closedCommandsParse() throws {
    #expect(try PiProbeCommand.parse(["preflight"]) == .preflight)
    #expect(try PiProbeCommand.parse(["timeout"]) == .timeout)
    #expect(try PiProbeCommand.parse(["ledger-preflight"]) == .ledgerPreflight)
    for profile in PiProbeProfile.allCases {
      #expect(try PiProbeCommand.parse(["profile", profile.rawValue]) == .profile(profile))
    }
  }

  @Test(
    "arbitrary Pi commands fail closed",
    arguments: [
      [String](),
      ["profile"],
      ["profile", "review", "extra"],
      ["profile", "unknown"],
      ["preflight", "/tmp/arbitrary"],
      ["shell", "echo"],
    ])
  func arbitraryCommandsFail(arguments: [String]) {
    #expect(throws: PiProbeContractError.invalidArguments) {
      try PiProbeCommand.parse(arguments)
    }
  }
}
