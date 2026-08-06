public enum LocalSpikeCommand: String, CaseIterable, Codable, Sendable {
  case security
  case gitTransport = "git-transport"
  case mutationRecovery = "mutation-recovery"

  public static func parse(_ arguments: [String]) throws -> LocalSpikeCommand {
    guard arguments.count == 1, let command = LocalSpikeCommand(rawValue: arguments[0]) else {
      throw LocalSpikeContractError.invalidArguments
    }
    return command
  }
}

public enum LocalSpikeContractError: Error, Equatable, Sendable {
  case invalidArguments
}
