import Testing

@testable import JidokaCodeCore

@Suite("Workflow probe closed command contract")
struct WorkflowProbeContractTests {
  @Test("closed workflow commands parse")
  func closedCommandsParse() throws {
    for command in WorkflowProbeCommand.allCases {
      #expect(try WorkflowProbeCommand.parse([command.rawValue]) == command)
    }
  }

  @Test(
    "arbitrary workflow commands fail closed",
    arguments: [
      [String](),
      ["live", "review"],
      ["profile", "review"],
      ["shell", "echo"],
      ["preflight", "/tmp/arbitrary"],
    ])
  func arbitraryCommandsFail(arguments: [String]) {
    #expect(throws: WorkflowProbeContractError.invalidArguments) {
      try WorkflowProbeCommand.parse(arguments)
    }
  }
}
