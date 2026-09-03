import Foundation

public struct JobCanaryGenerationRolloverPlannedHost: Codable, Equatable, Sendable {
  public let role: PiWorkflowRole
  public let roleHostID: String

  public init(role: PiWorkflowRole, roleHostID: String) {
    self.role = role
    self.roleHostID = roleHostID
  }

  public func validate() throws {
    guard
      roleHostID.wholeMatch(
        of: /^rolehost-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryGenerationRolloverRequest: Codable, Equatable, Sendable {
  public let retry: JobCanaryPiRetryAuthorization
  public let successorRunID: String
  public let plannedHosts: [JobCanaryGenerationRolloverPlannedHost]

  public init(
    retry: JobCanaryPiRetryAuthorization,
    successorRunID: String,
    plannedHosts: [JobCanaryGenerationRolloverPlannedHost]
  ) {
    self.retry = retry
    self.successorRunID = successorRunID
    self.plannedHosts = plannedHosts
  }

  public func validate() throws {
    try retry.validate()
    for host in plannedHosts { try host.validate() }
    let sorted = plannedHosts.sorted { $0.role.rawValue < $1.role.rawValue }
    guard successorRunID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      plannedHosts == sorted,
      Set(plannedHosts.map(\.role))
        == Set<PiWorkflowRole>([
          .architecture, .security, .test, .synthesis,
        ]),
      Set(plannedHosts.map(\.roleHostID)).count == 4
    else { throw EngineClientError(.invalidCommand) }
  }
}

public enum JobCanaryGenerationRolloverStatus: String, Codable, Equatable, Sendable {
  case preview
  case topologyActivated
}

public struct JobCanaryGenerationRolloverReport: Codable, Equatable, Sendable {
  public let authorization: JobCanaryGenerationRolloverAuthorization
  public let status: JobCanaryGenerationRolloverStatus
  public let replayed: Bool

  public init(
    authorization: JobCanaryGenerationRolloverAuthorization,
    status: JobCanaryGenerationRolloverStatus,
    replayed: Bool
  ) throws {
    try authorization.validate()
    guard (status == .preview && !replayed) || status == .topologyActivated else {
      throw EngineClientError(.invalidResponse)
    }
    self.authorization = authorization
    self.status = status
    self.replayed = replayed
  }
}

public struct JobCanaryGenerationRolloverQ4Request: Codable, Equatable, Sendable {
  public let rolloverAuthorization: JobCanaryGenerationRolloverAuthorization
  public let plannedLaunchAttemptID: String

  public init(
    rolloverAuthorization: JobCanaryGenerationRolloverAuthorization,
    plannedLaunchAttemptID: String
  ) {
    self.rolloverAuthorization = rolloverAuthorization
    self.plannedLaunchAttemptID = plannedLaunchAttemptID
  }

  public func validate() throws {
    try rolloverAuthorization.validate()
    guard
      plannedLaunchAttemptID.wholeMatch(
        of: /^launch-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryGenerationRolloverQ4ExecutionAuthorization: Codable, Equatable,
  Sendable
{
  public let rollover: JobCanaryGenerationRolloverAuthorization
  public let q4: JobCanaryGenerationRolloverQ4Authorization

  public init(
    rollover: JobCanaryGenerationRolloverAuthorization,
    q4: JobCanaryGenerationRolloverQ4Authorization
  ) {
    self.rollover = rollover
    self.q4 = q4
  }

  public func validate() throws {
    try rollover.validate()
    try q4.validate()
    guard q4.rolloverAuthorizationSHA256 == rollover.authorizationSHA256,
      q4.successorRunID == rollover.successorRunID
    else { throw EngineClientError(.invalidCommand) }
  }
}

public enum JobCanaryGenerationRolloverQ4Status: String, Codable, Equatable, Sendable {
  case preview
  case prepared
  case enqueued
  case outcomeAmbiguous
  case failed
  case settled
}

public struct JobCanaryGenerationRolloverQ4Report: Codable, Equatable, Sendable {
  public let authorization: JobCanaryGenerationRolloverQ4Authorization
  public let status: JobCanaryGenerationRolloverQ4Status
  public let failureCode: String?
  public let replayed: Bool

  public init(
    authorization: JobCanaryGenerationRolloverQ4Authorization,
    status: JobCanaryGenerationRolloverQ4Status,
    failureCode: String? = nil,
    replayed: Bool
  ) throws {
    try authorization.validate()
    guard failureCode.map(JobCanaryRoleHostReplacementOutcome.validFailureCode) ?? true,
      (status == .failed || status == .outcomeAmbiguous) == (failureCode != nil),
      status != .preview || !replayed
    else { throw EngineClientError(.invalidResponse) }
    self.authorization = authorization
    self.status = status
    self.failureCode = failureCode
    self.replayed = replayed
  }
}
