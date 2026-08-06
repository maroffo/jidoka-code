public enum WorkflowProbeCommand: String, CaseIterable, Codable, Sendable {
  case preflight
  case live

  public static func parse(_ arguments: [String]) throws -> WorkflowProbeCommand {
    guard arguments.count == 1, let command = WorkflowProbeCommand(rawValue: arguments[0]) else {
      throw WorkflowProbeContractError.invalidArguments
    }
    return command
  }
}

public enum WorkflowProbeContractError: Error, Equatable, Sendable {
  case invalidArguments
}
