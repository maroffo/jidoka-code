import Foundation

public enum JobMaintenanceOperation: String, CaseIterable, Codable, Sendable {
  case retireBefore
  case retryResourceFailuresAfter
}

public struct JobMaintenanceScope: Codable, Equatable, Sendable {
  public static let authorizedBoundaryEpochSeconds: Int64 = 1_786_924_800

  public let operation: JobMaintenanceOperation
  public let boundaryEpochSeconds: Int64

  public init(operation: JobMaintenanceOperation, boundaryEpochSeconds: Int64) {
    self.operation = operation
    self.boundaryEpochSeconds = boundaryEpochSeconds
  }

  public func validate() throws {
    guard boundaryEpochSeconds == Self.authorizedBoundaryEpochSeconds else {
      throw EngineClientError(.invalidCommand)
    }
  }
}

public struct JobMaintenanceAuthorization: Codable, Equatable, Sendable {
  public let scope: JobMaintenanceScope
  public let expectedCount: Int
  public let evidenceSHA256: String

  public init(scope: JobMaintenanceScope, expectedCount: Int, evidenceSHA256: String) {
    self.scope = scope
    self.expectedCount = expectedCount
    self.evidenceSHA256 = evidenceSHA256
  }

  public func validate() throws {
    try scope.validate()
    guard (1...1_024).contains(expectedCount),
      GitHubInputValidation.validSHA256(evidenceSHA256)
    else {
      throw EngineClientError(.invalidCommand)
    }
  }
}

public struct JobMaintenanceReport: Codable, Equatable, Sendable {
  public let scope: JobMaintenanceScope
  public let candidateCount: Int
  public let evidenceSHA256: String
  public let appliedCount: Int
  public let replayed: Bool

  public init(
    scope: JobMaintenanceScope,
    candidateCount: Int,
    evidenceSHA256: String,
    appliedCount: Int,
    replayed: Bool
  ) {
    self.scope = scope
    self.candidateCount = candidateCount
    self.evidenceSHA256 = evidenceSHA256
    self.appliedCount = appliedCount
    self.replayed = replayed
  }
}

public struct JobMaintenanceApplication: Sendable {
  public let report: JobMaintenanceReport
  public let jobIDs: [UUID]

  public init(report: JobMaintenanceReport, jobIDs: [UUID]) {
    self.report = report
    self.jobIDs = jobIDs
  }
}
