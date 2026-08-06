import Testing

@testable import JidokaCodeCore

@Suite("Local spike closed command contract")
struct LocalSpikeContractTests {
  @Test("closed local spike commands parse")
  func closedCommandsParse() throws {
    for command in LocalSpikeCommand.allCases {
      #expect(try LocalSpikeCommand.parse([command.rawValue]) == command)
    }
  }

  @Test(
    "arbitrary local spike commands fail closed",
    arguments: [
      [String](),
      ["security", "extra"],
      ["git"],
      ["shell", "echo"],
      ["mutation-recovery", "/tmp/arbitrary"],
    ])
  func arbitraryCommandsFail(arguments: [String]) {
    #expect(throws: LocalSpikeContractError.invalidArguments) {
      try LocalSpikeCommand.parse(arguments)
    }
  }
}
