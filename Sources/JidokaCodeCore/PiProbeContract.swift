public enum PiProbeProfile: String, CaseIterable, Codable, Sendable {
  case review
  case triage
  case planning
  case orchestration
}

public enum PiProbeCommand: Equatable, Sendable {
  case preflight
  case timeout
  case ledgerPreflight
  case profile(PiProbeProfile)

  public static func parse(_ arguments: [String]) throws -> PiProbeCommand {
    if arguments == ["preflight"] {
      return .preflight
    }
    if arguments == ["timeout"] {
      return .timeout
    }
    if arguments == ["ledger-preflight"] {
      return .ledgerPreflight
    }
    if arguments.count == 2, arguments[0] == "profile",
      let profile = PiProbeProfile(rawValue: arguments[1])
    {
      return .profile(profile)
    }
    throw PiProbeContractError.invalidArguments
  }
}

public enum PiProbeContractError: Error, Equatable, Sendable {
  case invalidArguments
}
