import CryptoKit
import Foundation

public struct JobCanaryScope: Codable, Equatable, Sendable {
  public static let authorizedBoundaryEpochSeconds: Int64 = 1_786_924_800
  public static let maximumCommentPartLimit = 64

  public let jobID: UUID
  public let boundaryEpochSeconds: Int64
  public let repairEvidenceSHA256: String
  public let maximumCommentParts: Int

  public init(
    jobID: UUID,
    boundaryEpochSeconds: Int64,
    repairEvidenceSHA256: String,
    maximumCommentParts: Int
  ) {
    self.jobID = jobID
    self.boundaryEpochSeconds = boundaryEpochSeconds
    self.repairEvidenceSHA256 = repairEvidenceSHA256
    self.maximumCommentParts = maximumCommentParts
  }

  public func validate() throws {
    guard boundaryEpochSeconds == Self.authorizedBoundaryEpochSeconds,
      GitHubInputValidation.validSHA256(repairEvidenceSHA256),
      (1...Self.maximumCommentPartLimit).contains(maximumCommentParts)
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryAuthorization: Codable, Equatable, Sendable {
  public let scope: JobCanaryScope
  public let previewEvidenceSHA256: String

  public init(scope: JobCanaryScope, previewEvidenceSHA256: String) {
    self.scope = scope
    self.previewEvidenceSHA256 = previewEvidenceSHA256
  }

  public func validate() throws {
    try scope.validate()
    guard GitHubInputValidation.validSHA256(previewEvidenceSHA256) else {
      throw EngineClientError(.invalidCommand)
    }
  }

  public var authorizationSHA256: String {
    let canonical = [
      "jidoka-job-canary-authorization-v1",
      scope.jobID.uuidString.lowercased(),
      String(scope.boundaryEpochSeconds),
      scope.repairEvidenceSHA256,
      String(scope.maximumCommentParts),
      previewEvidenceSHA256,
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public enum JobCanaryStatus: String, Codable, Equatable, Sendable {
  case preview
  case admitted
  case settled
  case recoveryRequired
}

public struct JobCanaryReport: Codable, Equatable, Sendable {
  public let scope: JobCanaryScope
  public let previewEvidenceSHA256: String
  public let authorizationSHA256: String?
  public let status: JobCanaryStatus
  public let repositoryOwner: String
  public let repositoryName: String
  public let objectNumber: Int
  public let revisionKey: String
  public let provider: String
  public let model: String
  public let thinking: String
  public let resourceTreeSHA256: String
  public let piRoles: [PiWorkflowRole]
  public let replayed: Bool

  public init(
    scope: JobCanaryScope,
    previewEvidenceSHA256: String,
    authorizationSHA256: String?,
    status: JobCanaryStatus,
    repositoryOwner: String,
    repositoryName: String,
    objectNumber: Int,
    revisionKey: String,
    provider: String,
    model: String,
    thinking: String,
    resourceTreeSHA256: String,
    piRoles: [PiWorkflowRole] = [.architecture, .security, .test, .synthesis],
    replayed: Bool
  ) {
    self.scope = scope
    self.previewEvidenceSHA256 = previewEvidenceSHA256
    self.authorizationSHA256 = authorizationSHA256
    self.status = status
    self.repositoryOwner = repositoryOwner
    self.repositoryName = repositoryName
    self.objectNumber = objectNumber
    self.revisionKey = revisionKey
    self.provider = provider
    self.model = model
    self.thinking = thinking
    self.resourceTreeSHA256 = resourceTreeSHA256
    self.piRoles = piRoles
    self.replayed = replayed
  }
}

public struct JobCanaryApplication: Sendable {
  public let report: JobCanaryReport
  public let shouldExecute: Bool
}

public enum JobCanaryRecoveryStatus: String, Codable, Equatable, Sendable {
  case preview
  case recovered
  case recoveryRequired
}

public struct JobCanaryRecoveryAuthorization: Codable, Equatable, Sendable {
  public let canary: JobCanaryAuthorization
  public let recoveryEvidenceSHA256: String

  public init(
    canary: JobCanaryAuthorization,
    recoveryEvidenceSHA256: String
  ) {
    self.canary = canary
    self.recoveryEvidenceSHA256 = recoveryEvidenceSHA256
  }

  public func validate() throws {
    try canary.validate()
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw EngineClientError(.invalidCommand)
    }
  }

  public var authorizationSHA256: String {
    let canonical = [
      "jidoka-job-canary-topology-recovery-authorization-v1",
      canary.authorizationSHA256,
      recoveryEvidenceSHA256,
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct JobCanaryRecoveryReport: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let canaryAuthorizationSHA256: String
  public let recoveryEvidenceSHA256: String
  public let recoveryAuthorizationSHA256: String?
  public let status: JobCanaryRecoveryStatus
  public let repositoryOwner: String
  public let repositoryName: String
  public let objectNumber: Int
  public let revisionKey: String
  public let provider: String
  public let model: String
  public let thinking: String
  public let resourceTreeSHA256: String
  public let unknownIntentID: String
  public let unknownIntentSHA256: String
  public let unknownPayloadSHA256: String
  public let layoutSHA256: String
  public let hostExecutableSHA256: String
  public let roles: [PiWorkflowRole]
  public let replayed: Bool

  public init(
    jobID: UUID,
    canaryAuthorizationSHA256: String,
    recoveryEvidenceSHA256: String,
    recoveryAuthorizationSHA256: String?,
    status: JobCanaryRecoveryStatus,
    repositoryOwner: String,
    repositoryName: String,
    objectNumber: Int,
    revisionKey: String,
    provider: String,
    model: String,
    thinking: String,
    resourceTreeSHA256: String,
    unknownIntentID: String,
    unknownIntentSHA256: String,
    unknownPayloadSHA256: String,
    layoutSHA256: String,
    hostExecutableSHA256: String,
    roles: [PiWorkflowRole],
    replayed: Bool
  ) {
    self.jobID = jobID
    self.canaryAuthorizationSHA256 = canaryAuthorizationSHA256
    self.recoveryEvidenceSHA256 = recoveryEvidenceSHA256
    self.recoveryAuthorizationSHA256 = recoveryAuthorizationSHA256
    self.status = status
    self.repositoryOwner = repositoryOwner
    self.repositoryName = repositoryName
    self.objectNumber = objectNumber
    self.revisionKey = revisionKey
    self.provider = provider
    self.model = model
    self.thinking = thinking
    self.resourceTreeSHA256 = resourceTreeSHA256
    self.unknownIntentID = unknownIntentID
    self.unknownIntentSHA256 = unknownIntentSHA256
    self.unknownPayloadSHA256 = unknownPayloadSHA256
    self.layoutSHA256 = layoutSHA256
    self.hostExecutableSHA256 = hostExecutableSHA256
    self.roles = roles
    self.replayed = replayed
  }
}

public struct JobCanaryRecoveryExecution: Sendable {
  public let recovery: JobCanaryRecoveryReport
  public let canary: JobCanaryReport
}

public enum JobCanaryPiRetryStatus: String, Codable, Equatable, Sendable {
  case preview
  case authorized
  case recoveryRequired
}

public struct JobCanaryPiRetryAuthorization: Codable, Equatable, Sendable {
  public let recovery: JobCanaryRecoveryAuthorization
  public let retryEvidenceSHA256: String

  public init(
    recovery: JobCanaryRecoveryAuthorization,
    retryEvidenceSHA256: String
  ) {
    self.recovery = recovery
    self.retryEvidenceSHA256 = retryEvidenceSHA256
  }

  public func validate() throws {
    try recovery.validate()
    guard GitHubInputValidation.validSHA256(retryEvidenceSHA256) else {
      throw EngineClientError(.invalidCommand)
    }
  }

  public var authorizationSHA256: String {
    let canonical = [
      "jidoka-job-canary-pi-fresh-retry-authorization-v1",
      recovery.authorizationSHA256,
      retryEvidenceSHA256,
    ].joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct JobCanaryPiRetryReport: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let canaryAuthorizationSHA256: String
  public let recoveryEvidenceSHA256: String
  public let retryEvidenceSHA256: String
  public let retryAuthorizationSHA256: String?
  public let agentAuthorityProtocol: String?
  public let failedPrimeIntentID: String?
  public let failedPrimeIntentSHA256: String?
  public let failedPrimePayloadSHA256: String?
  public let stalePaneRevision: UInt64?
  public let stalePaneHadTokens: Bool?
  public let stalePaneTokensSHA256: String?
  public let status: JobCanaryPiRetryStatus
  public let runID: String
  public let failedLaunchAttemptID: String
  public let provider: String
  public let model: String
  public let thinking: String
  public let credentialType: String
  public let credentialExpiresAtMilliseconds: Int64
  public let replayed: Bool
}

public struct JobCanaryPiRetryExecution: Sendable {
  public let retry: JobCanaryPiRetryReport
  public let canary: JobCanaryReport
}

public enum JobCanaryRoleHostReplacementEffectCertainty: String, Codable, Equatable,
  Sendable
{
  case knownNoRemoteEffect
  case possibleRemoteEffect
  case confirmedReplacementEffect
}

public enum JobCanaryRoleHostReplacementStatus: String, Codable, Equatable, Sendable {
  case preview
  case noRemoteEffectFailure
  case remoteEffectAmbiguous
  case q4Prepared
  case q4Enqueued
  case q4OutcomeAmbiguous
  case q4Failed
  case q4Settled
  case replacementHostLost
}

public enum JobCanaryRoleHostReplacementOutcome: Equatable, Sendable {
  case preview
  case noRemoteEffectFailure(failureCode: String)
  case remoteEffectAmbiguous
  case q4Prepared
  case q4Enqueued
  case q4OutcomeAmbiguous(failureCode: String?)
  case q4Failed(failureCode: String)
  case q4Settled
  case replacementHostLost

  public var status: JobCanaryRoleHostReplacementStatus {
    switch self {
    case .preview: .preview
    case .noRemoteEffectFailure: .noRemoteEffectFailure
    case .remoteEffectAmbiguous: .remoteEffectAmbiguous
    case .q4Prepared: .q4Prepared
    case .q4Enqueued: .q4Enqueued
    case .q4OutcomeAmbiguous: .q4OutcomeAmbiguous
    case .q4Failed: .q4Failed
    case .q4Settled: .q4Settled
    case .replacementHostLost: .replacementHostLost
    }
  }

  public var effectCertainty: JobCanaryRoleHostReplacementEffectCertainty {
    switch self {
    case .preview, .noRemoteEffectFailure:
      .knownNoRemoteEffect
    case .remoteEffectAmbiguous:
      .possibleRemoteEffect
    case .q4Prepared, .q4Enqueued, .q4OutcomeAmbiguous, .q4Failed, .q4Settled,
      .replacementHostLost:
      .confirmedReplacementEffect
    }
  }

  public var failureCode: String? {
    switch self {
    case .noRemoteEffectFailure(let code), .q4Failed(let code): code
    case .q4OutcomeAmbiguous(let code): code
    case .preview, .remoteEffectAmbiguous, .q4Prepared, .q4Enqueued, .q4Settled,
      .replacementHostLost:
      nil
    }
  }

  public var isTerminal: Bool { self != .preview }

  fileprivate init(
    status: JobCanaryRoleHostReplacementStatus,
    effectCertainty: JobCanaryRoleHostReplacementEffectCertainty,
    failureCode: String?
  ) throws {
    let outcome: Self
    switch status {
    case .preview:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .preview
    case .noRemoteEffectFailure:
      guard let failureCode, Self.validFailureCode(failureCode) else {
        throw EngineClientError(.invalidResponse)
      }
      outcome = .noRemoteEffectFailure(failureCode: failureCode)
    case .remoteEffectAmbiguous:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .remoteEffectAmbiguous
    case .q4Prepared:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .q4Prepared
    case .q4Enqueued:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .q4Enqueued
    case .q4OutcomeAmbiguous:
      guard failureCode.map(Self.validFailureCode) ?? true else {
        throw EngineClientError(.invalidResponse)
      }
      outcome = .q4OutcomeAmbiguous(failureCode: failureCode)
    case .q4Failed:
      guard let failureCode, Self.validFailureCode(failureCode) else {
        throw EngineClientError(.invalidResponse)
      }
      outcome = .q4Failed(failureCode: failureCode)
    case .q4Settled:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .q4Settled
    case .replacementHostLost:
      guard failureCode == nil else { throw EngineClientError(.invalidResponse) }
      outcome = .replacementHostLost
    }
    guard outcome.effectCertainty == effectCertainty else {
      throw EngineClientError(.invalidResponse)
    }
    self = outcome
  }

  static func validFailureCode(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
  }
}

public struct JobCanaryRoleHostReplacementQ4Binding: Codable, Equatable, Sendable {
  public let descriptorSHA256: String
  public let configurationSHA256: String
  public let promptSHA256: String
  public let workflowConfigurationSHA256: String
  public let priorLaunchDescriptorSHA256: String
  public let priorLaunchConfigurationSHA256: String
  public let resourceTreeSHA256: String

  public init(
    descriptorSHA256: String,
    configurationSHA256: String,
    promptSHA256: String,
    workflowConfigurationSHA256: String,
    priorLaunchDescriptorSHA256: String,
    priorLaunchConfigurationSHA256: String,
    resourceTreeSHA256: String
  ) {
    self.descriptorSHA256 = descriptorSHA256
    self.configurationSHA256 = configurationSHA256
    self.promptSHA256 = promptSHA256
    self.workflowConfigurationSHA256 = workflowConfigurationSHA256
    self.priorLaunchDescriptorSHA256 = priorLaunchDescriptorSHA256
    self.priorLaunchConfigurationSHA256 = priorLaunchConfigurationSHA256
    self.resourceTreeSHA256 = resourceTreeSHA256
  }

  public func validate() throws {
    guard
      [
        descriptorSHA256, configurationSHA256, promptSHA256,
        workflowConfigurationSHA256, priorLaunchDescriptorSHA256,
        priorLaunchConfigurationSHA256, resourceTreeSHA256,
      ].allSatisfy(GitHubInputValidation.validSHA256)
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryRoleHostReplacementRequest: Codable, Equatable, Sendable {
  public static let authorizedIncidentAuditSHA256 =
    "f855da9097441503472e85c912f881f157475381fdf6666057927f0651c5e1d7"
  public static let authorizedStalePaneRevision: UInt64 = 3
  public static let authorizedStalePaneHadTokens = true
  public static let authorizedStalePaneTokensSHA256 =
    "9a0952938abe3db94e9d949cb36c66a891ba7777a009edb1f443b3f465c6cc01"

  public let retry: JobCanaryPiRetryAuthorization
  public let incidentAuditSHA256: String
  public let plannedReplacementRoleHostID: String
  public let plannedLaunchAttemptID: String
  public let stalePaneRevision: UInt64
  public let stalePaneHadTokens: Bool
  public let stalePaneTokensSHA256: String

  public init(
    retry: JobCanaryPiRetryAuthorization,
    incidentAuditSHA256: String,
    plannedReplacementRoleHostID: String,
    plannedLaunchAttemptID: String,
    stalePaneRevision: UInt64 = Self.authorizedStalePaneRevision,
    stalePaneHadTokens: Bool = Self.authorizedStalePaneHadTokens,
    stalePaneTokensSHA256: String = Self.authorizedStalePaneTokensSHA256
  ) {
    self.retry = retry
    self.incidentAuditSHA256 = incidentAuditSHA256
    self.plannedReplacementRoleHostID = plannedReplacementRoleHostID
    self.plannedLaunchAttemptID = plannedLaunchAttemptID
    self.stalePaneRevision = stalePaneRevision
    self.stalePaneHadTokens = stalePaneHadTokens
    self.stalePaneTokensSHA256 = stalePaneTokensSHA256
  }

  public func validate() throws {
    try retry.validate()
    guard incidentAuditSHA256 == Self.authorizedIncidentAuditSHA256,
      stalePaneRevision == Self.authorizedStalePaneRevision,
      stalePaneHadTokens == Self.authorizedStalePaneHadTokens,
      stalePaneTokensSHA256 == Self.authorizedStalePaneTokensSHA256,
      plannedReplacementRoleHostID.wholeMatch(
        of: /^rolehost-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil,
      plannedLaunchAttemptID.wholeMatch(
        of: /^launch-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil
    else { throw EngineClientError(.invalidCommand) }
  }
}

public struct JobCanaryRoleHostReplacementAuthorization: Codable, Equatable, Sendable {
  public let request: JobCanaryRoleHostReplacementRequest
  public let replacementEvidenceSHA256: String
  public let q4Binding: JobCanaryRoleHostReplacementQ4Binding

  public init(
    request: JobCanaryRoleHostReplacementRequest,
    replacementEvidenceSHA256: String,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding
  ) {
    self.request = request
    self.replacementEvidenceSHA256 = replacementEvidenceSHA256
    self.q4Binding = q4Binding
  }

  public func validate() throws {
    try request.validate()
    try q4Binding.validate()
    guard GitHubInputValidation.validSHA256(replacementEvidenceSHA256) else {
      throw EngineClientError(.invalidCommand)
    }
  }

  public var authorizationSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? GitHubMarkerCodec.sha256(encoder.encode(self))) ?? ""
  }
}

public struct JobCanaryRoleHostReplacementReport: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let runID: String
  public let predecessorRoleHostID: String
  public let replacementRoleHostID: String
  public let plannedLaunchAttemptID: String
  public let incidentAuditSHA256: String
  public let replacementEvidenceSHA256: String
  public let replacementAuthorizationSHA256: String?
  public let q4Binding: JobCanaryRoleHostReplacementQ4Binding
  public let outcome: JobCanaryRoleHostReplacementOutcome
  public let replayed: Bool

  public var status: JobCanaryRoleHostReplacementStatus { outcome.status }
  public var effectCertainty: JobCanaryRoleHostReplacementEffectCertainty {
    outcome.effectCertainty
  }
  public var failureCode: String? { outcome.failureCode }

  public init(
    jobID: UUID,
    runID: String,
    predecessorRoleHostID: String,
    replacementRoleHostID: String,
    plannedLaunchAttemptID: String,
    incidentAuditSHA256: String,
    replacementEvidenceSHA256: String,
    replacementAuthorizationSHA256: String?,
    q4Binding: JobCanaryRoleHostReplacementQ4Binding,
    outcome: JobCanaryRoleHostReplacementOutcome,
    replayed: Bool
  ) throws {
    self.jobID = jobID
    self.runID = runID
    self.predecessorRoleHostID = predecessorRoleHostID
    self.replacementRoleHostID = replacementRoleHostID
    self.plannedLaunchAttemptID = plannedLaunchAttemptID
    self.incidentAuditSHA256 = incidentAuditSHA256
    self.replacementEvidenceSHA256 = replacementEvidenceSHA256
    self.replacementAuthorizationSHA256 = replacementAuthorizationSHA256
    self.q4Binding = q4Binding
    self.outcome = outcome
    self.replayed = replayed
    try validate()
  }

  public func validate() throws {
    try q4Binding.validate()
    let authorizationValid =
      replacementAuthorizationSHA256.map(GitHubInputValidation.validSHA256) ?? false
    guard runID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      predecessorRoleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      replacementRoleHostID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      predecessorRoleHostID != replacementRoleHostID,
      plannedLaunchAttemptID.wholeMatch(
        of: /^launch-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil,
      GitHubInputValidation.validSHA256(incidentAuditSHA256),
      GitHubInputValidation.validSHA256(replacementEvidenceSHA256),
      outcome == .preview
        ? replacementAuthorizationSHA256 == nil && !replayed
        : authorizationValid
    else { throw EngineClientError(.invalidResponse) }
  }

  private enum CodingKeys: String, CodingKey {
    case jobID
    case runID
    case predecessorRoleHostID
    case replacementRoleHostID
    case plannedLaunchAttemptID
    case incidentAuditSHA256
    case replacementEvidenceSHA256
    case replacementAuthorizationSHA256
    case q4Binding
    case status
    case effectCertainty
    case failureCode
    case replayed
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        jobID: values.decode(UUID.self, forKey: .jobID),
        runID: values.decode(String.self, forKey: .runID),
        predecessorRoleHostID: values.decode(String.self, forKey: .predecessorRoleHostID),
        replacementRoleHostID: values.decode(String.self, forKey: .replacementRoleHostID),
        plannedLaunchAttemptID: values.decode(String.self, forKey: .plannedLaunchAttemptID),
        incidentAuditSHA256: values.decode(String.self, forKey: .incidentAuditSHA256),
        replacementEvidenceSHA256: values.decode(
          String.self,
          forKey: .replacementEvidenceSHA256
        ),
        replacementAuthorizationSHA256: values.decodeIfPresent(
          String.self,
          forKey: .replacementAuthorizationSHA256
        ),
        q4Binding: values.decode(
          JobCanaryRoleHostReplacementQ4Binding.self,
          forKey: .q4Binding
        ),
        outcome: try JobCanaryRoleHostReplacementOutcome(
          status: values.decode(JobCanaryRoleHostReplacementStatus.self, forKey: .status),
          effectCertainty: values.decode(
            JobCanaryRoleHostReplacementEffectCertainty.self,
            forKey: .effectCertainty
          ),
          failureCode: values.decodeIfPresent(String.self, forKey: .failureCode)
        ),
        replayed: values.decode(Bool.self, forKey: .replayed)
      )
    } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid replacement report")
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    try validate()
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(jobID, forKey: .jobID)
    try values.encode(runID, forKey: .runID)
    try values.encode(predecessorRoleHostID, forKey: .predecessorRoleHostID)
    try values.encode(replacementRoleHostID, forKey: .replacementRoleHostID)
    try values.encode(plannedLaunchAttemptID, forKey: .plannedLaunchAttemptID)
    try values.encode(incidentAuditSHA256, forKey: .incidentAuditSHA256)
    try values.encode(replacementEvidenceSHA256, forKey: .replacementEvidenceSHA256)
    try values.encodeIfPresent(
      replacementAuthorizationSHA256,
      forKey: .replacementAuthorizationSHA256
    )
    try values.encode(q4Binding, forKey: .q4Binding)
    try values.encode(status, forKey: .status)
    try values.encode(effectCertainty, forKey: .effectCertainty)
    try values.encodeIfPresent(failureCode, forKey: .failureCode)
    try values.encode(replayed, forKey: .replayed)
  }
}

public struct JobCanaryRoleHostReplacementExecution: Sendable {
  public let replacement: JobCanaryRoleHostReplacementReport
  public let canary: JobCanaryReport
}

struct JobCanaryRoleHostReplacementLaunchEvidence: Codable, Equatable, Sendable {
  let launchAttemptID: String
  let queueSequence: Int
  let failureCode: String
  let childProcessID: Int32?
}

struct JobCanaryMappedRoleHostEvidence: Codable, Equatable, Sendable {
  let roleHostID: String
  let role: String
  let processID: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let executable: HerdrProcessExecutableIdentity
}

struct JobCanaryRoleHostReplacementEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let request: JobCanaryRoleHostReplacementRequest
  let canaryAuthorizationSHA256: String
  let recoveryEvidenceSHA256: String
  let retryEvidenceSHA256: String
  let jobID: String
  let runID: String
  let launches: [JobCanaryRoleHostReplacementLaunchEvidence]
  let failedPrimeIntentID: String
  let failedPrimeIntentSHA256: String
  let failedPrimePayloadSHA256: String
  let failedResetIntentID: String
  let failedResetIntentSHA256: String
  let failedResetPayloadSHA256: String
  let predecessor: JobCanaryRecoveryHostEvidence
  let preservedHosts: [JobCanaryRecoveryHostEvidence]
  let anchorRoleHostID: String
  let anchorPaneID: String
  let anchorTerminalID: String
  let socketDevice: UInt64
  let socketInode: UInt64
  let socketOwner: UInt32
  let socketPermissions: UInt16
  let socketPeer: HerdrConnectedPeerEvidence
  let resourceEvidence: PackagedPiResourceEvidence?
  let mappedHosts: [JobCanaryMappedRoleHostEvidence]
  let currentHostExecutableSHA256: String
  let currentHostExecutableDevice: UInt64
  let currentHostExecutableInode: UInt64
  let credential: PiProviderCredentialEvidence
  let credentialAccountIdentity: String
  let credentialProjectedBytesSHA256: String
  let q4Binding: JobCanaryRoleHostReplacementQ4Binding

  var evidenceSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? GitHubMarkerCodec.sha256(encoder.encode(self))) ?? ""
  }

  func report(
    authorization: JobCanaryRoleHostReplacementAuthorization?,
    outcome: JobCanaryRoleHostReplacementOutcome,
    replayed: Bool
  ) -> JobCanaryRoleHostReplacementReport? {
    guard let jobID = UUID(uuidString: jobID),
      GitHubInputValidation.validSHA256(evidenceSHA256),
      authorization?.q4Binding == nil || authorization?.q4Binding == q4Binding
    else { return nil }
    return try? JobCanaryRoleHostReplacementReport(
      jobID: jobID,
      runID: runID,
      predecessorRoleHostID: predecessor.roleHostID,
      replacementRoleHostID: request.plannedReplacementRoleHostID,
      plannedLaunchAttemptID: request.plannedLaunchAttemptID,
      incidentAuditSHA256: request.incidentAuditSHA256,
      replacementEvidenceSHA256: evidenceSHA256,
      replacementAuthorizationSHA256: authorization?.authorizationSHA256,
      q4Binding: q4Binding,
      outcome: outcome,
      replayed: replayed
    )
  }
}

struct JobCanaryPiRetryEvidence: Codable, Equatable, Sendable {
  static let legacyAgentPrimeProtocolV1 = "herdr-pane-agent-prime-v1"
  static let agentAuthorityResetProtocolV1 = "herdr-pane-agent-authority-reset-v1"

  let schemaVersion: Int
  let legacyAgentPrimeProtocol: String?
  let failedPrimeIntentID: String?
  let failedPrimeIntentSHA256: String?
  let failedPrimePayloadSHA256: String?
  let stalePaneRevision: UInt64?
  let stalePaneHadTokens: Bool?
  let stalePaneTokensSHA256: String?
  let canaryAuthorizationSHA256: String
  let recoveryEvidenceSHA256: String
  let jobID: String
  let jobAttempt: Int
  let jobStep: Int
  let jobStepKind: String
  let runID: String
  let runNonce: String
  let requestSHA256: String
  let role: String
  let round: Int
  let topologyGeneration: Int
  let runOutcome: String
  let provider: String
  let model: String
  let thinking: String
  let failedLaunchAttemptID: String
  let roleHostID: String
  let queueSequence: Int
  let launchMode: String
  let descriptorSHA256: String
  let failureCode: String
  let childProcessID: Int32
  let childStartSeconds: UInt64
  let childStartMicroseconds: UInt64
  let sessionRecordSHA256: String
  let resourceTreeSHA256: String
  let currentHostExecutableSHA256: String
  let piRunCount: Int
  let piLaunchCount: Int
  let piEventCount: Int
  let piResultCount: Int
  let piSessionOriginCount: Int
  let inputArtifactCount: Int
  let inputArtifactSHA256: String
  let reviewArtifactCount: Int
  let jobStepCount: Int
  let approvedCommandCount: Int
  let mutationIntentCount: Int
  let credentialBindingSHA256: String
  let credential: PiProviderCredentialEvidence

  var credentialBindingIsValid: Bool {
    GitHubInputValidation.validSHA256(credentialBindingSHA256)
      && credentialBindingSHA256 == credential.replacementBindingSHA256
  }

  var evidenceSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func report(
    authorization: JobCanaryPiRetryAuthorization?,
    status: JobCanaryPiRetryStatus,
    replayed: Bool
  ) -> JobCanaryPiRetryReport? {
    guard let jobID = UUID(uuidString: jobID),
      credentialBindingIsValid,
      GitHubInputValidation.validSHA256(evidenceSHA256)
    else { return nil }
    return JobCanaryPiRetryReport(
      jobID: jobID,
      canaryAuthorizationSHA256: canaryAuthorizationSHA256,
      recoveryEvidenceSHA256: recoveryEvidenceSHA256,
      retryEvidenceSHA256: evidenceSHA256,
      retryAuthorizationSHA256: authorization?.authorizationSHA256,
      agentAuthorityProtocol: legacyAgentPrimeProtocol,
      failedPrimeIntentID: failedPrimeIntentID,
      failedPrimeIntentSHA256: failedPrimeIntentSHA256,
      failedPrimePayloadSHA256: failedPrimePayloadSHA256,
      stalePaneRevision: stalePaneRevision,
      stalePaneHadTokens: stalePaneHadTokens,
      stalePaneTokensSHA256: stalePaneTokensSHA256,
      status: status,
      runID: runID,
      failedLaunchAttemptID: failedLaunchAttemptID,
      provider: provider,
      model: model,
      thinking: thinking,
      credentialType: credential.type,
      credentialExpiresAtMilliseconds: credential.expiresAtMilliseconds,
      replayed: replayed
    )
  }
}

struct JobCanaryFailedAgentPrimeIntent: Equatable, Sendable {
  let id: String
  let intentSHA256: String
  let payloadSHA256: String
}

struct JobCanaryPiRetryDurableState: Sendable {
  let job: JobRecord
  let run: PiRunRecord
  let launches: [PiRunLaunchRecord]
  let launch: PiRunLaunchRecord
  let inputArtifactCount: Int
  let inputArtifactSHA256: String
  let piEventCount: Int
  let failedPrimeIntent: JobCanaryFailedAgentPrimeIntent?
}

struct JobCanaryRoleHostReplacementDurableState: Sendable {
  let retry: JobCanaryPiRetryDurableState
  let failedResetIntent: JobCanaryFailedAgentPrimeIntent
  let replacementHost: HerdrReplacementRoleHostRecord?
  let replacementLaunch: PiRunLaunchRecord?
}

struct JobCanaryRecoveryHostEvidence: Codable, Equatable, Sendable {
  let roleHostID: String
  let role: String
  let bootstrapDescriptorSHA256: String
  let hostExecutableSHA256: String
  let hostExecutablePath: String
  let processID: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let workspaceID: String
  let tabID: String
  let paneID: String
  let terminalID: String
  let workingDirectory: String
  let arguments: [String]
}

struct JobCanaryRecoveryEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let canaryAuthorizationSHA256: String
  let jobID: String
  let jobState: String
  let attempt: Int
  let currentStep: Int
  let currentStepKind: String
  let objectNumber: Int
  let revisionKey: String
  let repositoryID: String
  let repositoryOwner: String
  let repositoryName: String
  let defaultBranch: String
  let provider: String
  let model: String
  let thinking: String
  let generation: Int
  let workspaceID: String
  let tabID: String
  let socketDevice: UInt64
  let socketInode: UInt64
  let socketOwner: UInt32
  let socketPermissions: UInt16
  let unknownIntentID: String
  let unknownIntentSHA256: String
  let unknownPayloadSHA256: String
  let layoutSHA256: String
  let exportedEnvironmentRedacted: Bool
  let resourceTreeSHA256: String
  let currentHostExecutableSHA256: String
  let compatibleLegacyHostSHA256: [String]
  let piRunCount: Int
  let piLaunchCount: Int
  let jobStepCount: Int
  let approvedCommandCount: Int
  let mutationIntentCount: Int
  let activeLeaseCount: Int
  let hosts: [JobCanaryRecoveryHostEvidence]

  var evidenceSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  var hostExecutableSHA256: String? {
    let values = Set(hosts.map(\.hostExecutableSHA256))
    guard values.count == 1 else { return nil }
    return values.first
  }

  func report(
    authorization: JobCanaryRecoveryAuthorization?,
    status: JobCanaryRecoveryStatus,
    replayed: Bool
  ) -> JobCanaryRecoveryReport? {
    guard let jobID = UUID(uuidString: jobID),
      let hostExecutableSHA256,
      GitHubInputValidation.validSHA256(evidenceSHA256)
    else { return nil }
    return JobCanaryRecoveryReport(
      jobID: jobID,
      canaryAuthorizationSHA256: canaryAuthorizationSHA256,
      recoveryEvidenceSHA256: evidenceSHA256,
      recoveryAuthorizationSHA256: authorization?.authorizationSHA256,
      status: status,
      repositoryOwner: repositoryOwner,
      repositoryName: repositoryName,
      objectNumber: objectNumber,
      revisionKey: revisionKey,
      provider: provider,
      model: model,
      thinking: thinking,
      resourceTreeSHA256: resourceTreeSHA256,
      unknownIntentID: unknownIntentID,
      unknownIntentSHA256: unknownIntentSHA256,
      unknownPayloadSHA256: unknownPayloadSHA256,
      layoutSHA256: layoutSHA256,
      hostExecutableSHA256: hostExecutableSHA256,
      roles: hosts.compactMap { PiWorkflowRole(rawValue: $0.role) },
      replayed: replayed
    )
  }
}

private struct JobCanaryEvidence: Codable {
  let scope: JobCanaryScope
  let repositoryID: String
  let repositoryNodeID: String
  let repositoryOwner: String
  let repositoryName: String
  let defaultBranch: String
  let reviewEnabled: Int64
  let triageEnabled: Int64
  let implementationEnabled: Int64
  let repositoryEnabled: Int64
  let repositoryUpdatedAtBits: String
  let jobKind: String
  let objectNodeID: String
  let objectNumber: Int
  let revisionKey: String
  let contractVersion: String
  let priority: Int64
  let jobState: String
  let attempt: Int64
  let currentStep: Int64
  let currentStepKind: String
  let notBeforeBits: String?
  let createdAtBits: String
  let updatedAtBits: String
  let terminalReason: String?
  let dispositionState: String
  let dispositionContractVersion: String
  let dispositionLastJobID: String?
  let dispositionLastMutationID: String?
  let dispositionEvidence: String?
  let dispositionGeneration: Int64
  let dispositionUpdatedAtBits: String
  let repairTransitionEvent: String
  let repairTransitionCreatedAtBits: String
  let provider: String
  let model: String
  let thinking: String
  let profileUpdatedAtBits: String
  let githubAccount: String
  let githubAuthorID: Int64
  let settingsUpdatedAtBits: String
  let resourceTreeSHA256: String
  let piRoles: [String]
  let allowedGitHubOperation: String
  let retryAuthority: JobCanaryRetryAuthority?
}

struct ActiveJobCanary {
  let jobID: UUID
  let authorizationSHA256: String
  let maximumCommentParts: Int
  let admitEventKey: String
}

private struct JobCanaryRetryAuthority: Codable {
  let admissionEventKey: String
  let piAuthorizationEventKey: String
  let failureEventKey: String
  let failureCreatedAtBits: String
  let closeEventKey: String
  let closeCreatedAtBits: String
}

extension DurableJobStore: JobCanaryMarkerAuthorizing {}

extension DurableJobStore {
  private static let canaryRoles: [PiWorkflowRole] = [
    .architecture, .security, .test, .synthesis,
  ]

  public func previewCanary(
    scope: JobCanaryScope,
    resourceTreeSHA256: String
  ) async throws -> JobCanaryReport {
    try scope.validate()
    guard GitHubInputValidation.validSHA256(resourceTreeSHA256) else {
      throw DurableJobStoreError.canaryEvidenceMismatch
    }
    return try await database.transaction { database in
      guard try Self.activeCanary(database: database) == nil else {
        throw DurableJobStoreError.canaryUnsafe(scope.jobID)
      }
      return try Self.canaryPreview(
        scope: scope,
        resourceTreeSHA256: resourceTreeSHA256,
        database: database
      )
    }
  }

  public func admitCanary(
    _ authorization: JobCanaryAuthorization,
    resourceTreeSHA256: String,
    now: Date
  ) async throws -> JobCanaryApplication {
    try authorization.validate()
    return try await database.transaction { database in
      let authorizationSHA = authorization.authorizationSHA256
      let admitKey = Self.canaryEventKey(
        authorizationSHA: authorizationSHA,
        maximumCommentParts: authorization.scope.maximumCommentParts,
        kind: "admit",
        suffix: authorization.scope.jobID.uuidString.lowercased()
      )
      let closeKey = Self.canaryEventKey(
        authorizationSHA: authorizationSHA,
        maximumCommentParts: authorization.scope.maximumCommentParts,
        kind: "close",
        suffix: authorization.scope.jobID.uuidString.lowercased()
      )
      if try Self.eventExists(
        admitKey,
        ownedBy: authorization.scope.jobID,
        database: database
      ) {
        let current = try Self.canaryPreview(
          scope: authorization.scope,
          resourceTreeSHA256: resourceTreeSHA256,
          database: database,
          allowSettledJob: true,
          allowExistingAuthorization: authorizationSHA
        )
        let closed = try Self.eventExists(
          closeKey,
          ownedBy: authorization.scope.jobID,
          database: database
        )
        return JobCanaryApplication(
          report: Self.report(
            current,
            previewEvidenceSHA: authorization.previewEvidenceSHA256,
            authorizationSHA: authorizationSHA,
            status: closed ? .settled : .recoveryRequired,
            replayed: true
          ),
          shouldExecute: false
        )
      }
      let preview = try Self.canaryPreview(
        scope: authorization.scope,
        resourceTreeSHA256: resourceTreeSHA256,
        database: database
      )
      guard preview.previewEvidenceSHA256 == authorization.previewEvidenceSHA256 else {
        throw DurableJobStoreError.canaryEvidenceMismatch
      }
      guard try Self.activeCanary(database: database) == nil else {
        throw DurableJobStoreError.canaryUnsafe(authorization.scope.jobID)
      }
      let jobID = authorization.scope.jobID.uuidString.lowercased()
      let admissionJob = try Self.canaryJob(authorization.scope.jobID, database: database)
      guard
        try Self.int(database, "SELECT paused FROM app_settings WHERE singleton = 1") == 1,
        try Self.int(database, "SELECT COUNT(*) FROM repository_leases WHERE active = 1") == 0,
        [.queued, .retryBackoff].contains(admissionJob.state)
      else { throw DurableJobStoreError.canaryUnsafe(authorization.scope.jobID) }
      let repositoryID = try Self.text(
        try Self.one(
          database, "SELECT repository_id AS value FROM jobs WHERE id = ?", [.text(jobID)]),
        "value"
      )
      let generation =
        (try Self.int(
          database,
          "SELECT generation FROM repository_leases WHERE repository_id = ?",
          [.text(repositoryID)]
        ) ?? 0) + 1
      _ = try database.execute(
        """
        INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
        VALUES (?, ?, ?, ?, 1)
        ON CONFLICT(repository_id) DO UPDATE SET
          job_id = excluded.job_id, generation = excluded.generation,
          heartbeat = excluded.heartbeat, active = 1
        """,
        bindings: [
          .text(repositoryID), .text(jobID), .integer(generation), .real(now.timeIntervalSince1970),
        ]
      )
      guard
        try database.execute(
          """
          UPDATE jobs SET state = 'leased', not_before = NULL, updated_at = ?
          WHERE id = ? AND state = ?
          """,
          bindings: [
            .real(now.timeIntervalSince1970), .text(jobID), .text(admissionJob.state.rawValue),
          ]
        ) == 1
      else { throw DurableJobStoreError.canaryUnsafe(authorization.scope.jobID) }
      try Self.insertCanaryEvent(
        jobID: authorization.scope.jobID,
        eventKey: admitKey,
        from: admissionJob.state,
        to: .leased,
        reason: admissionJob.state == .queued
          ? "operator admitted exact paused single-job canary"
          : "operator readmitted exact paused no-effect canary retry",
        now: now,
        database: database
      )
      return JobCanaryApplication(
        report: Self.report(
          preview, authorizationSHA: authorizationSHA, status: .admitted, replayed: false),
        shouldExecute: true
      )
    }
  }

  public func authorizeCanaryPiRole(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    now: Date
  ) async throws {
    try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database) else { return }
      guard active.jobID == jobID, workflow == .pullRequestReview, round == 1 else {
        throw DurableJobStoreError.canaryEffectDenied
      }
      let prefix = Self.canaryEventPrefix(active) + "pi:"
      let rows = try database.query(
        "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
        bindings: [.text(jobID.uuidString.lowercased()), .text(prefix + "*")]
      )
      let roleKey = prefix + role.rawValue + ":r\(round)"
      if rows.contains(where: { (try? Self.text($0, "event_key")) == roleKey }) { return }
      guard rows.count < Self.canaryRoles.count, Self.canaryRoles[rows.count] == role else {
        throw DurableJobStoreError.canaryEffectDenied
      }
      let job = try Self.canaryJob(jobID, database: database)
      try Self.insertCanaryEvent(
        jobID: jobID,
        eventKey: roleKey,
        from: job.state,
        to: job.state,
        reason: "exact canary Pi role authorized",
        now: now,
        database: database
      )
    }
  }

  public func authorizeCanaryMarkerBatch(
    jobID: UUID,
    operation: MutationOperation,
    documentSHA256: String,
    partCount: Int,
    now: Date
  ) async throws {
    try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database) else { return }
      guard active.jobID == jobID, operation == .createMarkerComment,
        GitHubInputValidation.validSHA256(documentSHA256),
        (1...active.maximumCommentParts).contains(partCount)
      else { throw DurableJobStoreError.canaryEffectDenied }
      let key = Self.canaryEventPrefix(active) + "marker:\(documentSHA256):\(partCount)"
      let existing = try database.query(
        "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .text(Self.canaryEventPrefix(active) + "marker:*"),
        ]
      )
      if existing.contains(where: { (try? Self.text($0, "event_key")) == key }) { return }
      guard existing.isEmpty else { throw DurableJobStoreError.canaryEffectDenied }
      let job = try Self.canaryJob(jobID, database: database)
      try Self.insertCanaryEvent(
        jobID: jobID,
        eventKey: key,
        from: job.state,
        to: job.state,
        reason: "exact canary marker batch authorized before first send",
        now: now,
        database: database
      )
    }
  }

  public func canaryRecoveryJob(
    authorization: JobCanaryAuthorization,
    resumedRecoveryEvidenceSHA256: String? = nil
  ) async throws -> JobRecord {
    try authorization.validate()
    return try await database.transaction { database in
      if let resumedRecoveryEvidenceSHA256 {
        guard GitHubInputValidation.validSHA256(resumedRecoveryEvidenceSHA256),
          let active = try Self.activeCanary(database: database),
          active.jobID == authorization.scope.jobID,
          active.authorizationSHA256 == authorization.authorizationSHA256
        else { throw DurableJobStoreError.canaryEffectDenied }
        let job = try Self.canaryJob(authorization.scope.jobID, database: database)
        if job.state == .preparing || job.state == .runningPi {
          try Self.requireResumedCanaryRecovery(
            active: active,
            job: job,
            recoveryEvidenceSHA256: resumedRecoveryEvidenceSHA256,
            database: database
          )
          return job
        }
      }
      return try Self.requireCanaryRecoveryBase(
        authorization: authorization,
        database: database
      ).job
    }
  }

  func resumedCanaryTopologyRecoveryJob(
    jobID: UUID,
    recoveryEvidenceSHA256: String
  ) async throws -> JobRecord {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == jobID
      else { throw DurableJobStoreError.canaryEffectDenied }
      let job = try Self.canaryJob(jobID, database: database)
      try Self.requireResumedCanaryRecovery(
        active: active,
        job: job,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        database: database
      )
      return job
    }
  }

  func selectCanaryReviewAfterTopologyRecovery(
    jobID: UUID,
    recoveryEvidenceSHA256: String,
    now: Date
  ) async throws -> JobRecord {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == jobID
      else { throw DurableJobStoreError.canaryEffectDenied }
      let job = try Self.canaryJob(jobID, database: database)
      try Self.requireResumedCanaryRecovery(
        active: active,
        job: job,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        database: database
      )
      if job.state == .runningPi { return job }
      let effect = try JobStateMachine.transition(
        from: job.state,
        event: .selectPiStep,
        context: JobTransitionContext(
          now: now,
          reason: "recovered canary selected the exact review Pi step"
        )
      )
      guard effect.to == .runningPi, effect.lease == .retain,
        effect.attemptDelta == 0, effect.stepDelta == 0
      else { throw DurableJobStoreError.canaryEffectDenied }
      guard
        try database.execute(
          "UPDATE jobs SET state = 'runningPi', updated_at = ? WHERE id = ? AND state = 'preparing' AND attempt = ? AND current_step = ?",
          bindings: [
            .real(now.timeIntervalSince1970),
            .text(job.id.uuidString.lowercased()),
            .integer(Int64(job.attempt)),
            .integer(Int64(job.currentStep)),
          ]
        ) == 1
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      try Self.insertCanaryEvent(
        jobID: job.id,
        eventKey: Self.canaryEventPrefix(active) + "topology-run-review:"
          + recoveryEvidenceSHA256,
        from: .preparing,
        to: .runningPi,
        reason: "exact topology recovery bypassed the stale review selection event",
        now: now,
        database: database
      )
      return try Self.canaryJob(job.id, database: database)
    }
  }

  @discardableResult
  func authorizeCanaryTopologyRecovery(
    _ authorization: JobCanaryRecoveryAuthorization,
    evidence: JobCanaryRecoveryEvidence,
    now: Date
  ) async throws -> Bool {
    try authorization.validate()
    guard evidence.canaryAuthorizationSHA256 == authorization.canary.authorizationSHA256,
      evidence.evidenceSHA256 == authorization.recoveryEvidenceSHA256,
      evidence.jobID == authorization.canary.scope.jobID.uuidString.lowercased(),
      evidence.schemaVersion == 1,
      evidence.jobState == JobState.reconciliationQueued.rawValue,
      evidence.currentStepKind == JobStepKind.review.rawValue,
      evidence.piRunCount == 0,
      evidence.piLaunchCount == 0,
      evidence.jobStepCount == 0,
      evidence.approvedCommandCount == 0,
      evidence.mutationIntentCount == 0,
      evidence.activeLeaseCount == 0,
      evidence.hosts.map(\.role)
        == [
          PiWorkflowRole.architecture.rawValue,
          PiWorkflowRole.security.rawValue,
          PiWorkflowRole.test.rawValue,
          PiWorkflowRole.synthesis.rawValue,
        ],
      evidence.hostExecutableSHA256 != nil
    else { throw DurableJobStoreError.canaryEvidenceMismatch }
    return try await database.transaction { database in
      let base = try Self.requireCanaryRecoveryBase(
        authorization: authorization.canary,
        database: database
      )
      guard base.job.attempt == evidence.attempt,
        base.job.currentStep == evidence.currentStep,
        base.job.objectNumber == evidence.objectNumber,
        base.job.identity.revisionKey == evidence.revisionKey,
        base.job.identity.repositoryID.uuidString.lowercased() == evidence.repositoryID
      else { throw DurableJobStoreError.canaryEvidenceMismatch }
      try Self.requireCanaryRecoveryConfiguration(evidence: evidence, database: database)
      let prefix = Self.canaryEventPrefix(base.active)
      let key = prefix + "topology-recovery:" + evidence.evidenceSHA256
      let rows = try database.query(
        "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
        bindings: [
          .text(evidence.jobID),
          .text(prefix + "topology-recovery:*"),
        ]
      )
      if !rows.isEmpty {
        guard rows.count == 1, try Self.text(rows[0], "event_key") == key else {
          throw DurableJobStoreError.canaryEffectDenied
        }
        let activated =
          try Self.int(
            database,
            "SELECT COUNT(*) FROM herdr_job_bindings WHERE job_id = ? AND state = 'active'",
            [.text(evidence.jobID)]
          ) == 1
        try Self.requireCanaryRecoveryTopology(
          evidence: evidence,
          activated: activated,
          database: database
        )
        return true
      }
      try Self.requireCanaryRecoveryTopology(
        evidence: evidence,
        activated: false,
        database: database
      )
      try Self.insertCanaryEvent(
        jobID: base.job.id,
        eventKey: key,
        from: base.job.state,
        to: base.job.state,
        reason: "operator authorized exact no-Pi canary topology recovery",
        now: now,
        database: database
      )
      return false
    }
  }

  func hasCanaryTopologyRecoveryAuthorization(
    _ authorization: JobCanaryRecoveryAuthorization
  ) async throws -> Bool {
    try authorization.validate()
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == authorization.canary.scope.jobID,
        active.authorizationSHA256 == authorization.canary.authorizationSHA256
      else { return false }
      let key =
        Self.canaryEventPrefix(active) + "topology-recovery:"
        + authorization.recoveryEvidenceSHA256
      return try Self.eventExists(key, ownedBy: active.jobID, database: database)
    }
  }

  func hasActiveCanaryTopologyRecovery(jobID: UUID) async throws -> Bool {
    try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == jobID
      else { return false }
      let rows = try database.query(
        "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .text(Self.canaryEventPrefix(active) + "topology-recovery:*"),
        ]
      )
      return rows.count == 1
    }
  }

  @discardableResult
  func resumeCanaryAfterTopologyRecovery(
    _ authorization: JobCanaryRecoveryAuthorization,
    evidence: JobCanaryRecoveryEvidence,
    now: Date
  ) async throws -> Bool {
    try authorization.validate()
    guard evidence.evidenceSHA256 == authorization.recoveryEvidenceSHA256 else {
      throw DurableJobStoreError.canaryEvidenceMismatch
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == authorization.canary.scope.jobID,
        active.authorizationSHA256 == authorization.canary.authorizationSHA256
      else { throw DurableJobStoreError.canaryEffectDenied }
      let prefix = Self.canaryEventPrefix(active)
      let authorizationKey =
        prefix + "topology-recovery:" + authorization.recoveryEvidenceSHA256
      guard
        try Self.eventExists(
          authorizationKey,
          ownedBy: authorization.canary.scope.jobID,
          database: database
        )
      else { throw DurableJobStoreError.canaryEffectDenied }
      let resumeKey = prefix + "topology-resume:" + authorization.recoveryEvidenceSHA256
      let current = try Self.canaryJob(authorization.canary.scope.jobID, database: database)
      if try Self.eventExists(resumeKey, ownedBy: current.id, database: database) {
        try Self.requireResumedCanaryRecovery(
          active: active,
          job: current,
          recoveryEvidenceSHA256: authorization.recoveryEvidenceSHA256,
          database: database
        )
        return true
      }
      let base = try Self.requireCanaryRecoveryBase(
        authorization: authorization.canary,
        database: database
      )
      guard base.job.attempt == evidence.attempt,
        base.job.currentStep == evidence.currentStep
      else { throw DurableJobStoreError.canaryEvidenceMismatch }
      try Self.requireCanaryRecoveryConfiguration(evidence: evidence, database: database)
      try Self.requireCanaryRecoveryTopology(
        evidence: evidence,
        activated: true,
        database: database
      )
      let effect = try JobStateMachine.transition(
        from: base.job.state,
        event: .canaryTopologyRecovered,
        context: JobTransitionContext(
          now: now,
          reason: "exact live topology recovered before any Pi launch"
        )
      )
      guard effect.to == .preparing, effect.lease == .acquireRecovery,
        effect.attemptDelta == 0, effect.stepDelta == 0
      else { throw DurableJobStoreError.canaryEffectDenied }
      let generation =
        (try Self.int(
          database,
          "SELECT generation FROM repository_leases WHERE repository_id = ?",
          [.text(evidence.repositoryID)]
        ) ?? 0) + 1
      _ = try database.execute(
        """
        INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
        VALUES (?, ?, ?, ?, 1)
        ON CONFLICT(repository_id) DO UPDATE SET
          job_id = excluded.job_id, generation = excluded.generation,
          heartbeat = excluded.heartbeat, active = 1
        """,
        bindings: [
          .text(evidence.repositoryID),
          .text(evidence.jobID),
          .integer(generation),
          .real(now.timeIntervalSince1970),
        ]
      )
      guard
        try database.execute(
          "UPDATE jobs SET state = 'preparing', updated_at = ? WHERE id = ? AND state = 'reconciliationQueued'",
          bindings: [.real(now.timeIntervalSince1970), .text(evidence.jobID)]
        ) == 1
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      try Self.insertCanaryEvent(
        jobID: base.job.id,
        eventKey: resumeKey,
        from: .reconciliationQueued,
        to: .preparing,
        reason: "exact no-Pi topology recovery resumed the same canary attempt",
        now: now,
        database: database
      )
      return false
    }
  }

  public func closeCanary(
    authorization: JobCanaryAuthorization,
    resourceTreeSHA256: String,
    now: Date
  ) async throws -> JobCanaryReport {
    try authorization.validate()
    return try await database.transaction { database in
      let jobID = authorization.scope.jobID
      let authorizationSHA = authorization.authorizationSHA256
      let admitKey = Self.canaryEventKey(
        authorizationSHA: authorizationSHA,
        maximumCommentParts: authorization.scope.maximumCommentParts,
        kind: "admit",
        suffix: jobID.uuidString.lowercased()
      )
      let closeKey = Self.canaryEventKey(
        authorizationSHA: authorizationSHA,
        maximumCommentParts: authorization.scope.maximumCommentParts,
        kind: "close",
        suffix: jobID.uuidString.lowercased()
      )
      guard try Self.eventExists(admitKey, ownedBy: jobID, database: database) else {
        throw DurableJobStoreError.canaryEffectDenied
      }
      let preview = try Self.canaryPreview(
        scope: authorization.scope,
        resourceTreeSHA256: resourceTreeSHA256,
        database: database,
        allowSettledJob: true,
        allowExistingAuthorization: authorizationSHA
      )
      if try Self.eventExists(closeKey, ownedBy: jobID, database: database) {
        return Self.report(
          preview,
          previewEvidenceSHA: authorization.previewEvidenceSHA256,
          authorizationSHA: authorizationSHA,
          status: .settled,
          replayed: true
        )
      }
      let active = try Self.activeCanary(database: database)
      guard active?.jobID == jobID,
        active?.authorizationSHA256 == authorizationSHA
      else { throw DurableJobStoreError.canaryEffectDenied }
      let job = try Self.canaryJob(jobID, database: database)
      guard
        [.succeeded, .blocked, .waitingHuman, .retryBackoff, .awaitingResolution].contains(
          job.state),
        try Self.int(
          database, "SELECT COUNT(*) FROM repository_leases WHERE job_id = ? AND active = 1",
          [.text(job.id.uuidString.lowercased())]) == 0
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      try Self.insertCanaryEvent(
        jobID: job.id,
        eventKey: closeKey,
        from: job.state,
        to: job.state,
        reason: "exact single-job canary settled without replacement",
        now: now,
        database: database
      )
      return Self.report(
        preview,
        previewEvidenceSHA: authorization.previewEvidenceSHA256,
        authorizationSHA: authorizationSHA,
        status: .settled,
        replayed: false
      )
    }
  }

  public func unresolvedCanaryJobID() async throws -> UUID? {
    try await database.transaction { database in
      try Self.activeCanary(database: database)?.jobID
    }
  }

  func terminalCanaryRoleHostReplacementPredecessor(
    jobID: UUID
  ) async throws -> String? {
    try await database.transaction { database in
      let id = jobID.uuidString.lowercased()
      let replacementAuthorityCount =
        try Self.int(
          database,
          "SELECT COUNT(*) FROM herdr_role_host_replacement_authorizations WHERE job_id = ?",
          [.text(id)]
        ) ?? 0
      let replacementIntentCount =
        try Self.int(
          database,
          "SELECT COUNT(*) FROM herdr_topology_intents WHERE job_id = ? AND kind = 'replaceRoleHost'",
          [.text(id)]
        ) ?? 0
      guard replacementAuthorityCount > 0 || replacementIntentCount > 0 else { return nil }
      guard let active = try Self.activeCanary(database: database),
        active.jobID == jobID
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      return try Self.terminalReplacementPreCutoverPredecessor(
        jobID: jobID,
        canaryAuthorizationSHA256: active.authorizationSHA256,
        database: database
      )
    }
  }

  private static func requireCanaryRecoveryBase(
    authorization: JobCanaryAuthorization,
    database: isolated SQLiteStore
  ) throws -> (active: ActiveJobCanary, job: JobRecord) {
    guard
      try int(database, "SELECT paused FROM app_settings WHERE singleton = 1") == 1,
      let active = try activeCanary(database: database),
      active.jobID == authorization.scope.jobID,
      active.authorizationSHA256 == authorization.authorizationSHA256
    else { throw DurableJobStoreError.canaryEffectDenied }
    let job = try canaryJob(authorization.scope.jobID, database: database)
    let id = job.id.uuidString.lowercased()
    let prefix = canaryEventPrefix(active)
    let roleRows = try database.query(
      "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "pi:*")]
    )
    let interruptionKey = "job:\(id):a\(job.attempt):s\(job.currentStep):pi-interrupted"
    guard job.identity.kind == .prReview,
      job.state == .reconciliationQueued,
      job.currentStep == 0,
      job.currentStepKind == .review,
      job.terminalReason == nil,
      roleRows.count == 1,
      try text(roleRows[0], "event_key") == prefix + "pi:architecture:r1",
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'runningPi' AND to_state = 'reconciliationQueued'",
        [.text(id), .text(interruptionKey)]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM repository_leases WHERE active = 1"
      ) == 0,
      try canaryRecoveryEffectCount(database: database, jobID: id) == 0
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    return (active, job)
  }

  static func resumedCanaryRecoveryJobIDForStartup(
    database: isolated SQLiteStore
  ) throws -> UUID? {
    guard let active = try activeCanary(database: database) else { return nil }
    let prefix = canaryEventPrefix(active)
    let recoveryPrefix = prefix + "topology-recovery:"
    let recoveryRows = try database.query(
      "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [
        .text(active.jobID.uuidString.lowercased()),
        .text(recoveryPrefix + "*"),
      ]
    )
    guard !recoveryRows.isEmpty else { return nil }
    guard recoveryRows.count == 1 else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let recoveryKey = try text(recoveryRows[0], "event_key")
    guard recoveryKey.hasPrefix(recoveryPrefix) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let recoveryEvidenceSHA256 = String(recoveryKey.dropFirst(recoveryPrefix.count))
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let resumeRows = try database.query(
      "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [
        .text(active.jobID.uuidString.lowercased()),
        .text(prefix + "topology-resume:*"),
      ]
    )
    guard !resumeRows.isEmpty else { return nil }
    guard resumeRows.count == 1 else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let job = try canaryJob(active.jobID, database: database)
    guard job.state == .preparing || job.state == .runningPi else { return nil }
    do {
      try requireResumedCanaryRecovery(
        active: active,
        job: job,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        allowUnrelatedActiveLeasesForStartup: true,
        database: database
      )
    } catch DurableJobStoreError.canaryRecoveryRequired {
      do {
        _ = try requireCanaryPiFreshRetry(
          active: active,
          recoveryEvidenceSHA256: recoveryEvidenceSHA256,
          authorizedRetryEvidenceSHA256: nil,
          allowUnrelatedActiveLeasesForStartup: true,
          database: database
        )
      } catch DurableJobStoreError.canaryRecoveryRequired {
        let retryRows = try database.query(
          "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id DESC LIMIT 1",
          bindings: [
            .text(active.jobID.uuidString.lowercased()),
            .text(prefix + "pi-fresh-retry:*"),
          ]
        )
        guard retryRows.count == 1 else {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
        let evidenceSHA256 = try text(retryRows[0], "event_key")
          .split(separator: ":").last.map(String.init)
        guard let evidenceSHA256, GitHubInputValidation.validSHA256(evidenceSHA256) else {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
        let replacementHostCount = try int(
          database,
          "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ?",
          [.text(active.jobID.uuidString.lowercased())]
        )
        let replacementAuthorizationCount = try int(
          database,
          "SELECT COUNT(*) FROM herdr_role_host_replacement_authorizations WHERE job_id = ?",
          [.text(active.jobID.uuidString.lowercased())]
        )
        guard let replacementHostCount, replacementHostCount <= 1,
          let replacementAuthorizationCount, replacementAuthorizationCount <= 1,
          replacementHostCount == 0 || replacementAuthorizationCount == 1
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        let hasReplacementHost = replacementHostCount == 1
        let hasInertReplacementAuthority: Bool
        let hasTerminalUnknownReplacementAuthority: Bool
        if replacementAuthorizationCount == 1, !hasReplacementHost {
          hasInertReplacementAuthority = try replacementPreCutoverStateIsInert(
            jobID: active.jobID,
            canaryAuthorizationSHA256: active.authorizationSHA256,
            database: database
          )
          hasTerminalUnknownReplacementAuthority =
            try terminalReplacementPreCutoverPredecessor(
              jobID: active.jobID,
              canaryAuthorizationSHA256: active.authorizationSHA256,
              database: database
            ) != nil
        } else {
          hasInertReplacementAuthority = false
          hasTerminalUnknownReplacementAuthority = false
        }
        _ = try requireCanaryPiFreshRetry(
          active: active,
          recoveryEvidenceSHA256: recoveryEvidenceSHA256,
          authorizedRetryEvidenceSHA256: evidenceSHA256,
          allowFailedResetIntent: hasReplacementHost || hasInertReplacementAuthority
            || hasTerminalUnknownReplacementAuthority,
          allowReplacementLaunch: hasReplacementHost,
          allowUnrelatedActiveLeasesForStartup: true,
          database: database
        )
      }
    }
    let id = job.id.uuidString.lowercased()
    let ordinaryTopology =
      try int(
        database,
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE job_id = ? AND state = 'waiting'
          AND role IN ('architecture', 'security', 'test', 'synthesis')
        """,
        [.text(id)]
      ) == 4
    let replacementTopology =
      try int(
        database,
        """
        SELECT COUNT(*) FROM herdr_role_hosts
        WHERE job_id = ? AND state = 'waiting' AND role IN ('security', 'test', 'synthesis')
        """,
        [.text(id)]
      ) == 3
      && int(
        database,
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ? AND role = 'architecture' AND state = 'stopped'",
        [.text(id)]
      ) == 1
      && int(
        database,
        "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ? AND state IN ('waiting', 'running')",
        [.text(id)]
      ) == 1
    guard
      try int(
        database,
        "SELECT COUNT(*) FROM herdr_job_bindings WHERE job_id = ? AND state = 'active'",
        [.text(id)]
      ) == 1,
      ordinaryTopology || replacementTopology,
      try int(
        database,
        "SELECT COUNT(DISTINCT role) FROM herdr_role_hosts WHERE job_id = ?",
        [.text(id)]
      ) == 4,
      try int(
        database,
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ?",
        [.text(id)]
      ) == 4
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    return job.id
  }

  func canaryPiFreshRetryState(
    jobID: UUID,
    recoveryEvidenceSHA256: String,
    authorizedRetryEvidenceSHA256: String? = nil,
    activeAgentAuthorityReceipt: HerdrTopologyMutationReceipt? = nil,
    activeAgentAuthorityKind: HerdrTopologyMutationIntent.Kind? = nil
  ) async throws -> JobCanaryPiRetryDurableState {
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256),
      authorizedRetryEvidenceSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      (activeAgentAuthorityReceipt == nil) == (activeAgentAuthorityKind == nil),
      activeAgentAuthorityKind.map({
        [.primeAgentAuthority, .resetAgentAuthority].contains($0)
      }) ?? true
    else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database), active.jobID == jobID else {
        throw DurableJobStoreError.canaryEffectDenied
      }
      return try Self.requireCanaryPiFreshRetry(
        active: active,
        recoveryEvidenceSHA256: recoveryEvidenceSHA256,
        authorizedRetryEvidenceSHA256: authorizedRetryEvidenceSHA256,
        activeAgentAuthorityReceipt: activeAgentAuthorityReceipt,
        activeAgentAuthorityKind: activeAgentAuthorityKind,
        database: database
      )
    }
  }

  func canaryRoleHostReplacementTerminalReport(
    request: JobCanaryRoleHostReplacementRequest,
    replayed: Bool = true
  ) async throws -> JobCanaryRoleHostReplacementReport? {
    try request.validate()
    return try await database.transaction { database in
      let jobID = request.retry.recovery.canary.scope.jobID
      let id = jobID.uuidString.lowercased()
      guard let active = try Self.activeCanary(database: database),
        active.jobID == jobID,
        active.authorizationSHA256 == request.retry.recovery.canary.authorizationSHA256
      else { throw DurableJobStoreError.canaryEffectDenied }
      let authorizationRows = try database.query(
        "SELECT * FROM herdr_role_host_replacement_authorizations WHERE job_id = ?",
        bindings: [.text(id)]
      )
      guard authorizationRows.count <= 1, let authorizationRow = authorizationRows.first else {
        if authorizationRows.isEmpty { return nil }
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let q4Binding = try Self.replacementQ4Binding(authorizationRow)
      let authorization = JobCanaryRoleHostReplacementAuthorization(
        request: request,
        replacementEvidenceSHA256: try Self.text(
          authorizationRow,
          "replacement_evidence_sha256"
        ),
        q4Binding: q4Binding
      )
      do {
        try authorization.validate()
      } catch {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let runID = try Self.text(authorizationRow, "run_id")
      let predecessorRoleHostID = try Self.text(
        authorizationRow,
        "predecessor_role_host_id"
      )
      let payloadSHA256 = try Self.text(authorizationRow, "payload_sha256")
      guard
        try Self.text(authorizationRow, "replacement_authorization_sha256")
          == authorization.authorizationSHA256,
        try Self.text(authorizationRow, "incident_audit_sha256")
          == request.incidentAuditSHA256,
        try Self.text(authorizationRow, "canary_authorization_sha256")
          == request.retry.recovery.canary.authorizationSHA256,
        try Self.text(authorizationRow, "recovery_evidence_sha256")
          == request.retry.recovery.recoveryEvidenceSHA256,
        try Self.text(authorizationRow, "retry_evidence_sha256")
          == request.retry.retryEvidenceSHA256,
        try Self.text(authorizationRow, "job_id") == id,
        try Self.text(authorizationRow, "planned_replacement_role_host_id")
          == request.plannedReplacementRoleHostID,
        try Self.text(authorizationRow, "planned_launch_attempt_id")
          == request.plannedLaunchAttemptID,
        try Self.integer(authorizationRow, "stale_pane_revision")
          == Int64(request.stalePaneRevision),
        try Self.integer(authorizationRow, "stale_pane_had_tokens")
          == (request.stalePaneHadTokens ? 1 : 0),
        try Self.text(authorizationRow, "stale_pane_tokens_sha256")
          == request.stalePaneTokensSHA256,
        GitHubInputValidation.validSHA256(payloadSHA256)
      else { throw DurableJobStoreError.canaryRecoveryRequired }

      let predecessorRows = try database.query(
        "SELECT * FROM herdr_role_hosts WHERE id = ?",
        bindings: [.text(predecessorRoleHostID)]
      )
      guard predecessorRows.count == 1 else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let predecessor = try PiRunStore.decodeRoleHost(predecessorRows[0])
      let authorizedGeneration = try Self.integer(authorizationRow, "generation")
      guard predecessor.jobID == jobID, predecessor.role == .architecture,
        Int64(predecessor.generation) == authorizedGeneration
      else { throw DurableJobStoreError.canaryRecoveryRequired }

      let intentRows = try database.query(
        "SELECT * FROM herdr_topology_intents WHERE job_id = ? AND kind = 'replaceRoleHost' ORDER BY created_at, id",
        bindings: [.text(id)]
      )
      guard intentRows.count <= 1, let intent = intentRows.first else {
        if intentRows.isEmpty { return nil }
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      guard try Self.text(intent, "job_id") == id,
        try Self.text(intent, "repository_id")
          == Self.text(authorizationRow, "repository_id"),
        try Self.integer(intent, "generation") == Self.integer(authorizationRow, "generation"),
        try Self.text(intent, "payload_sha256") == payloadSHA256
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      let mutationID = try Self.text(intent, "id")
      let generationValue = try Self.integer(intent, "generation")
      let socketDeviceValue = try Self.integer(intent, "socket_device")
      let socketInodeValue = try Self.integer(intent, "socket_inode")
      let socketOwnerValue = try Self.integer(intent, "socket_owner")
      let socketPermissionsValue = try Self.integer(intent, "socket_permissions")
      guard mutationID.wholeMatch(of: /^replace-[0-9a-f-]{36}$/) != nil,
        let generation = Int(exactly: generationValue), generation > 0,
        let socketDevice = UInt64(exactly: socketDeviceValue),
        let socketInode = UInt64(exactly: socketInodeValue),
        let socketOwner = UInt32(exactly: socketOwnerValue),
        let socketPermissions = UInt16(exactly: socketPermissionsValue)
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      let reconstructedIntent = HerdrTopologyMutationIntent(
        mutationID: mutationID,
        kind: .replaceRoleHost,
        repositoryID: try Self.text(intent, "repository_id"),
        jobID: id,
        generation: generation,
        payloadSHA256: payloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(
          HerdrSocketIdentity(
            device: socketDevice,
            inode: socketInode,
            owner: socketOwner,
            permissions: socketPermissions
          )
        )
      )
      let intentEncoder = JSONEncoder()
      intentEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard
        GitHubMarkerCodec.sha256(try intentEncoder.encode(reconstructedIntent))
          == (try Self.text(intent, "intent_sha256"))
      else { throw DurableJobStoreError.canaryRecoveryRequired }

      let replacementRows = try database.query(
        "SELECT * FROM herdr_replacement_role_hosts WHERE job_id = ? ORDER BY created_at, id",
        bindings: [.text(id)]
      )
      let launchRows = try database.query(
        "SELECT * FROM pi_run_launches WHERE run_id = ? AND queue_sequence >= 4 ORDER BY queue_sequence, launch_attempt_id",
        bindings: [.text(runID)]
      )
      guard replacementRows.count <= 1, launchRows.count <= 1 else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let resultRows = try database.query(
        "SELECT * FROM pi_run_results WHERE run_id = ?",
        bindings: [.text(runID)]
      )
      let q4EventRows = try database.query(
        "SELECT * FROM pi_run_events WHERE run_id = ? AND launch_attempt_id = ? ORDER BY sequence",
        bindings: [.text(runID), .text(request.plannedLaunchAttemptID)]
      )
      let failedLaunchAttemptID = try Self.text(
        authorizationRow,
        "failed_launch_attempt_id"
      )
      let replacementEventKey =
        "canary:\(request.retry.recovery.canary.authorizationSHA256):m8:"
        + "pi-role-host-replacement:\(runID):"
        + "\(failedLaunchAttemptID):"
        + "\(request.plannedLaunchAttemptID):\(predecessorRoleHostID):"
        + "\(request.plannedReplacementRoleHostID):\(payloadSHA256)"
      let replacementEventCount = try Self.int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'runningPi' AND to_state = 'runningPi'",
        [.text(id), .text(replacementEventKey)]
      )

      let intentState = try Self.text(intent, "state")
      let outcome: JobCanaryRoleHostReplacementOutcome
      switch intentState {
      case "failedNoRemoteEffect":
        guard predecessor.state == .waiting, replacementRows.isEmpty, launchRows.isEmpty,
          resultRows.isEmpty, q4EventRows.isEmpty, replacementEventCount == 0,
          try Self.optionalText(intent, "attribution_json") == nil,
          let failureCode = try Self.optionalText(intent, "failure_code"),
          JobCanaryRoleHostReplacementOutcome.validFailureCode(failureCode)
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        outcome = .noRemoteEffectFailure(failureCode: failureCode)
      case HerdrTopologyStoredIntentState.sendStarted.rawValue,
        HerdrTopologyStoredIntentState.unknown.rawValue:
        guard predecessor.state == .waiting, replacementRows.isEmpty, launchRows.isEmpty,
          resultRows.isEmpty, q4EventRows.isEmpty, replacementEventCount == 0,
          try Self.optionalText(intent, "attribution_json") == nil,
          try Self.optionalText(intent, "failure_code") == nil
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        outcome = .remoteEffectAmbiguous
      case HerdrTopologyStoredIntentState.prepared.rawValue:
        guard try Self.optionalText(intent, "attribution_json") == nil,
          try Self.optionalText(intent, "failure_code") == nil,
          predecessor.state == .waiting, replacementRows.isEmpty, launchRows.isEmpty,
          resultRows.isEmpty, q4EventRows.isEmpty, replacementEventCount == 0
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        return nil
      case HerdrTopologyStoredIntentState.attributed.rawValue:
        guard replacementRows.count == 1, launchRows.count == 1,
          replacementEventCount == 1,
          try Self.optionalText(intent, "failure_code") == nil,
          let attributionJSON = try Self.optionalText(intent, "attribution_json"),
          let attributionData = attributionJSON.data(using: .utf8),
          let attribution = try? JSONDecoder().decode(
            HerdrRoleHostReplacementAttribution.self,
            from: attributionData
          )
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        let replacement = try PiRunStore.decodeReplacementRoleHost(replacementRows[0])
        let launch = try PiRunStore.decodeLaunch(launchRows[0])
        let authorizedBootstrapSHA256 = try Self.text(
          authorizationRow,
          "replacement_bootstrap_descriptor_sha256"
        )
        let authorizedHostExecutableSHA256 = try Self.text(
          authorizationRow,
          "host_executable_sha256"
        )
        let authorizedCredentialEvidenceSHA256 = try Self.text(
          authorizationRow,
          "credential_evidence_sha256"
        )
        guard predecessor.state == .stopped,
          replacement.id == request.plannedReplacementRoleHostID,
          replacement.predecessorRoleHostID == predecessorRoleHostID,
          replacement.replacementIntentID == mutationID,
          replacement.jobID == jobID,
          Int64(replacement.generation) == authorizedGeneration,
          replacement.bootstrapDescriptorSHA256 == authorizedBootstrapSHA256,
          replacement.hostExecutableSHA256 == authorizedHostExecutableSHA256,
          replacement.q4Binding == q4Binding,
          attribution.predecessorRoleHostID == predecessorRoleHostID,
          attribution.replacementRoleHostID == replacement.id,
          attribution.replacementEvidenceSHA256 == authorization.replacementEvidenceSHA256,
          attribution.replacementAuthorizationSHA256 == authorization.authorizationSHA256,
          attribution.incidentAuditSHA256 == request.incidentAuditSHA256,
          attribution.credentialEvidenceSHA256 == authorizedCredentialEvidenceSHA256,
          attribution.hostExecutableSHA256 == replacement.hostExecutableSHA256,
          attribution.workspaceID == replacement.workspaceID,
          attribution.tabID == replacement.tabID,
          attribution.paneID == replacement.paneID,
          attribution.terminalID == replacement.terminalID,
          attribution.processID == replacement.processIdentity.processID,
          attribution.startSeconds == replacement.processIdentity.startSeconds,
          attribution.startMicroseconds == replacement.processIdentity.startMicroseconds,
          attribution.q4Binding == q4Binding,
          launch.launchAttemptID == request.plannedLaunchAttemptID,
          launch.runID == runID,
          launch.roleHostID == predecessorRoleHostID,
          launch.executionRoleHostID == replacement.id,
          launch.queueSequence == 4,
          launch.launchMode == .fresh,
          launch.descriptorSHA256 == q4Binding.descriptorSHA256,
          launch.expectedSessionID == nil,
          launch.resumeBoundarySHA256 == nil
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        if replacement.state == .lost {
          outcome = .replacementHostLost
        } else {
          switch launch.state {
          case .prepared:
            guard resultRows.isEmpty, q4EventRows.isEmpty else {
              throw DurableJobStoreError.canaryRecoveryRequired
            }
            outcome = .q4Prepared
          case .enqueued, .running, .resultPrepared:
            guard resultRows.isEmpty,
              !q4EventRows.contains(where: {
                guard case .text(let kind)? = $0["kind"] else { return true }
                return kind == PiRunEventKind.acknowledged.rawValue
                  || kind == PiRunEventKind.released.rawValue
              })
            else { throw DurableJobStoreError.canaryRecoveryRequired }
            outcome = .q4Enqueued
          case .interruptedUnknown:
            guard resultRows.isEmpty else {
              throw DurableJobStoreError.canaryRecoveryRequired
            }
            let failureCode = launch.failureCode
            guard failureCode.map(JobCanaryRoleHostReplacementOutcome.validFailureCode) ?? true
            else { throw DurableJobStoreError.canaryRecoveryRequired }
            outcome = .q4OutcomeAmbiguous(failureCode: failureCode)
          case .failed:
            guard resultRows.isEmpty, let failureCode = launch.failureCode,
              JobCanaryRoleHostReplacementOutcome.validFailureCode(failureCode),
              q4EventRows.contains(where: {
                $0["kind"] == .text(PiRunEventKind.failed.rawValue)
                  && $0["detail_code"] == .text(failureCode)
              })
            else { throw DurableJobStoreError.canaryRecoveryRequired }
            outcome = .q4Failed(failureCode: failureCode)
          case .settled, .released:
            guard resultRows.count == 1 else {
              throw DurableJobStoreError.canaryRecoveryRequired
            }
            let result = try PiRunStore.decodeResult(resultRows[0])
            let runRows = try database.query(
              "SELECT * FROM pi_runs WHERE id = ?",
              bindings: [.text(runID)]
            )
            guard runRows.count == 1 else {
              throw DurableJobStoreError.canaryRecoveryRequired
            }
            let run = try PiRunStore.decodeRun(runRows[0])
            let acknowledged = q4EventRows.contains(where: {
              $0["kind"] == .text(PiRunEventKind.acknowledged.rawValue)
                && $0["record_sha256"] == .text(result.resultSHA256)
            })
            let released = q4EventRows.contains(where: {
              $0["kind"] == .text(PiRunEventKind.released.rawValue)
                && $0["record_sha256"] == .text(result.resultSHA256)
            })
            let runOutcomeValid =
              launch.state == .released
              ? run.outcome == .released && acknowledged && released
              : run.outcome == .settled && !released
            guard result.launchAttemptID == launch.launchAttemptID,
              run.accepted, run.settled,
              run.structuredResultDigest == result.resultSHA256,
              runOutcomeValid
            else { throw DurableJobStoreError.canaryRecoveryRequired }
            outcome = .q4Settled
          }
        }
      default:
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      return try JobCanaryRoleHostReplacementReport(
        jobID: jobID,
        runID: runID,
        predecessorRoleHostID: predecessorRoleHostID,
        replacementRoleHostID: request.plannedReplacementRoleHostID,
        plannedLaunchAttemptID: request.plannedLaunchAttemptID,
        incidentAuditSHA256: request.incidentAuditSHA256,
        replacementEvidenceSHA256: authorization.replacementEvidenceSHA256,
        replacementAuthorizationSHA256: authorization.authorizationSHA256,
        q4Binding: q4Binding,
        outcome: outcome,
        replayed: replayed
      )
    }
  }

  func canaryRoleHostReplacementState(
    request: JobCanaryRoleHostReplacementRequest
  ) async throws -> JobCanaryRoleHostReplacementDurableState {
    try request.validate()
    guard try await canaryRoleHostReplacementTerminalReport(request: request) == nil else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == request.retry.recovery.canary.scope.jobID,
        active.authorizationSHA256 == request.retry.recovery.canary.authorizationSHA256
      else { throw DurableJobStoreError.canaryEffectDenied }
      let retry = try Self.requireCanaryPiFreshRetry(
        active: active,
        recoveryEvidenceSHA256: request.retry.recovery.recoveryEvidenceSHA256,
        authorizedRetryEvidenceSHA256: request.retry.retryEvidenceSHA256,
        allowFailedResetIntent: true,
        allowReplacementLaunch: true,
        database: database
      )
      let resetRows = try database.query(
        """
        SELECT id, intent_sha256, payload_sha256, state, attribution_json
        FROM herdr_topology_intents
        WHERE job_id = ? AND kind = 'resetAgentAuthority'
        ORDER BY created_at, id
        """,
        bindings: [.text(retry.job.id.uuidString.lowercased())]
      )
      guard resetRows.count == 1,
        try Self.text(resetRows[0], "state") == "unknown",
        try Self.optionalText(resetRows[0], "attribution_json") == nil
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      let failedReset = JobCanaryFailedAgentPrimeIntent(
        id: try Self.text(resetRows[0], "id"),
        intentSHA256: try Self.text(resetRows[0], "intent_sha256"),
        payloadSHA256: try Self.text(resetRows[0], "payload_sha256")
      )
      guard failedReset.id.wholeMatch(of: /^reset-[0-9a-f-]{36}$/) != nil,
        GitHubInputValidation.validSHA256(failedReset.intentSHA256),
        GitHubInputValidation.validSHA256(failedReset.payloadSHA256)
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      let replacementRows = try database.query(
        "SELECT * FROM herdr_replacement_role_hosts WHERE job_id = ? ORDER BY created_at, id",
        bindings: [.text(retry.job.id.uuidString.lowercased())]
      )
      guard replacementRows.count <= 1 else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let replacementAuthorizationRows = try database.query(
        """
        SELECT * FROM herdr_role_host_replacement_authorizations
        WHERE job_id = ? ORDER BY created_at, replacement_authorization_sha256
        """,
        bindings: [.text(retry.job.id.uuidString.lowercased())]
      )
      guard replacementAuthorizationRows.count <= 1 else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      if let row = replacementAuthorizationRows.first {
        let replacementEvidenceSHA256 = try Self.text(
          row,
          "replacement_evidence_sha256"
        )
        let durableAuthorization = JobCanaryRoleHostReplacementAuthorization(
          request: request,
          replacementEvidenceSHA256: replacementEvidenceSHA256,
          q4Binding: try Self.replacementQ4Binding(row)
        )
        do {
          try durableAuthorization.validate()
        } catch {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
        guard try Self.text(row, "incident_audit_sha256") == request.incidentAuditSHA256,
          try Self.text(row, "canary_authorization_sha256")
            == request.retry.recovery.canary.authorizationSHA256,
          try Self.text(row, "recovery_evidence_sha256")
            == request.retry.recovery.recoveryEvidenceSHA256,
          try Self.text(row, "retry_evidence_sha256") == request.retry.retryEvidenceSHA256,
          try Self.text(row, "job_id") == retry.job.id.uuidString.lowercased(),
          try Self.text(row, "run_id") == retry.run.id,
          try Self.text(row, "failed_launch_attempt_id")
            == retry.launch.launchAttemptID,
          try Self.text(row, "planned_replacement_role_host_id")
            == request.plannedReplacementRoleHostID,
          try Self.text(row, "planned_launch_attempt_id")
            == request.plannedLaunchAttemptID,
          try Self.integer(row, "stale_pane_revision") == Int64(request.stalePaneRevision),
          try Self.integer(row, "stale_pane_had_tokens")
            == (request.stalePaneHadTokens ? 1 : 0),
          try Self.text(row, "stale_pane_tokens_sha256")
            == request.stalePaneTokensSHA256,
          try Self.text(row, "replacement_authorization_sha256")
            == durableAuthorization.authorizationSHA256,
          GitHubInputValidation.validSHA256(try Self.text(row, "payload_sha256"))
        else { throw DurableJobStoreError.canaryRecoveryRequired }
      }
      let replacementHost = try replacementRows.first.map(
        PiRunStore.decodeReplacementRoleHost
      )
      let allLaunches = try database.query(
        "SELECT * FROM pi_run_launches WHERE run_id = ? ORDER BY queue_sequence, launch_attempt_id",
        bindings: [.text(retry.run.id)]
      ).map(PiRunStore.decodeLaunch)
      let replacementLaunch = allLaunches.count == 4 ? allLaunches.last : nil
      let replacementIntentRows = try database.query(
        "SELECT * FROM herdr_topology_intents WHERE job_id = ? AND kind = 'replaceRoleHost' ORDER BY created_at, id",
        bindings: [.text(retry.job.id.uuidString.lowercased())]
      )
      if let replacementHost, let replacementLaunch {
        guard replacementAuthorizationRows.count == 1 else {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
        let durableQ4Binding = try Self.replacementQ4Binding(
          replacementAuthorizationRows[0]
        )
        guard replacementIntentRows.count == 1,
          replacementHost.id == request.plannedReplacementRoleHostID,
          replacementLaunch.launchAttemptID == request.plannedLaunchAttemptID,
          replacementLaunch.executionRoleHostID == replacementHost.id,
          replacementLaunch.roleHostID == replacementHost.predecessorRoleHostID,
          replacementLaunch.descriptorSHA256 == replacementHost.q4Binding.descriptorSHA256,
          replacementHost.q4Binding == durableQ4Binding,
          try Self.int(
            database,
            "SELECT COUNT(*) FROM herdr_topology_intents WHERE id = ? AND kind = 'replaceRoleHost' AND state = 'attributed' AND attribution_json IS NOT NULL",
            [.text(replacementHost.replacementIntentID)]
          ) == 1
        else { throw DurableJobStoreError.canaryRecoveryRequired }
      } else {
        let inertReplacementStateValid: Bool
        if replacementAuthorizationRows.isEmpty {
          inertReplacementStateValid = replacementIntentRows.isEmpty
        } else {
          inertReplacementStateValid = try Self.replacementPreCutoverStateIsInert(
            jobID: retry.job.id,
            canaryAuthorizationSHA256: request.retry.recovery.canary.authorizationSHA256,
            database: database
          )
        }
        guard replacementHost == nil, replacementLaunch == nil,
          inertReplacementStateValid,
          allLaunches.count == 3
        else { throw DurableJobStoreError.canaryRecoveryRequired }
      }
      return JobCanaryRoleHostReplacementDurableState(
        retry: retry,
        failedResetIntent: failedReset,
        replacementHost: replacementHost,
        replacementLaunch: replacementLaunch
      )
    }
  }

  @discardableResult
  func authorizeCanaryPiFreshRetry(
    _ authorization: JobCanaryPiRetryAuthorization,
    evidence: JobCanaryPiRetryEvidence,
    now: Date
  ) async throws -> Bool {
    try authorization.validate()
    guard evidence.credentialBindingIsValid,
      evidence.evidenceSHA256 == authorization.retryEvidenceSHA256,
      evidence.canaryAuthorizationSHA256 == authorization.recovery.canary.authorizationSHA256,
      evidence.recoveryEvidenceSHA256 == authorization.recovery.recoveryEvidenceSHA256
    else {
      throw DurableJobStoreError.canaryEvidenceMismatch
    }
    return try await database.transaction { database in
      guard let active = try Self.activeCanary(database: database),
        active.jobID == authorization.recovery.canary.scope.jobID,
        active.authorizationSHA256 == authorization.recovery.canary.authorizationSHA256
      else { throw DurableJobStoreError.canaryEffectDenied }
      let key =
        Self.canaryEventPrefix(active) + "pi-fresh-retry:"
        + evidence.runID + ":" + evidence.failedLaunchAttemptID + ":"
        + authorization.retryEvidenceSHA256
      let rows = try database.query(
        "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
        bindings: [
          .text(active.jobID.uuidString.lowercased()),
          .text(Self.canaryEventPrefix(active) + "pi-fresh-retry:*"),
        ]
      )
      if try rows.contains(where: { try Self.text($0, "event_key") == key }) {
        _ = try Self.requireCanaryPiFreshRetry(
          active: active,
          recoveryEvidenceSHA256: authorization.recovery.recoveryEvidenceSHA256,
          authorizedRetryEvidenceSHA256: authorization.retryEvidenceSHA256,
          database: database
        )
        return true
      }
      let state = try Self.requireCanaryPiFreshRetry(
        active: active,
        recoveryEvidenceSHA256: authorization.recovery.recoveryEvidenceSHA256,
        authorizedRetryEvidenceSHA256: nil,
        database: database
      )
      let childEvidenceMatches: Bool
      if state.launches.count == 1, let child = state.launch.childProcess {
        childEvidenceMatches =
          evidence.childProcessID == child.processID
          && evidence.childStartSeconds == child.startSeconds
          && evidence.childStartMicroseconds == child.startMicroseconds
      } else {
        childEvidenceMatches =
          evidence.childProcessID == 0
          && evidence.childStartSeconds == 0
          && evidence.childStartMicroseconds == 0
      }
      guard evidence.jobID == state.job.id.uuidString.lowercased(),
        evidence.jobAttempt == state.job.attempt,
        evidence.jobStep == state.job.currentStep,
        evidence.jobStepKind == state.job.currentStepKind?.rawValue,
        evidence.runID == state.run.id,
        evidence.runNonce == state.run.runNonce,
        evidence.requestSHA256 == state.run.requestSHA256,
        evidence.role == state.run.role.rawValue,
        evidence.round == state.run.round,
        evidence.topologyGeneration == state.run.topologyGeneration,
        evidence.runOutcome == state.run.outcome.rawValue,
        evidence.failedLaunchAttemptID == state.launch.launchAttemptID,
        evidence.roleHostID == state.launch.roleHostID,
        evidence.queueSequence == state.launch.queueSequence,
        evidence.launchMode == state.launch.launchMode.rawValue,
        evidence.descriptorSHA256 == state.launch.descriptorSHA256,
        evidence.failureCode == state.launch.failureCode,
        evidence.schemaVersion
          == state.launches.count + (state.failedPrimeIntent == nil ? 0 : 1),
        state.failedPrimeIntent == nil
          ? (state.launches.count == 3
            ? evidence.legacyAgentPrimeProtocol
              == JobCanaryPiRetryEvidence.legacyAgentPrimeProtocolV1
            : evidence.legacyAgentPrimeProtocol == nil)
          : evidence.legacyAgentPrimeProtocol
            == JobCanaryPiRetryEvidence.agentAuthorityResetProtocolV1,
        evidence.failedPrimeIntentID == state.failedPrimeIntent?.id,
        evidence.failedPrimeIntentSHA256 == state.failedPrimeIntent?.intentSHA256,
        evidence.failedPrimePayloadSHA256 == state.failedPrimeIntent?.payloadSHA256,
        state.failedPrimeIntent == nil
          ? evidence.stalePaneRevision == nil
            && evidence.stalePaneHadTokens == nil
            && evidence.stalePaneTokensSHA256 == nil
          : evidence.stalePaneRevision.map({ $0 > 0 }) == true
            && evidence.stalePaneHadTokens != nil
            && evidence.stalePaneTokensSHA256.map(GitHubInputValidation.validSHA256) == true,
        evidence.piRunCount == 1,
        evidence.piLaunchCount == state.launches.count,
        evidence.piEventCount == state.piEventCount,
        evidence.piResultCount == 0,
        evidence.piSessionOriginCount == 0,
        evidence.inputArtifactCount == state.inputArtifactCount,
        evidence.inputArtifactSHA256 == state.inputArtifactSHA256,
        evidence.reviewArtifactCount == 0,
        evidence.jobStepCount == 0,
        evidence.approvedCommandCount == 0,
        evidence.mutationIntentCount == 0,
        childEvidenceMatches,
        GitHubInputValidation.validSHA256(evidence.sessionRecordSHA256),
        GitHubInputValidation.validSHA256(evidence.resourceTreeSHA256),
        GitHubInputValidation.validSHA256(evidence.currentHostExecutableSHA256),
        evidence.credential.provider == evidence.provider,
        evidence.credential.type == "oauth"
      else { throw DurableJobStoreError.canaryEvidenceMismatch }
      let job = state.job
      try Self.insertCanaryEvent(
        jobID: job.id,
        eventKey: key,
        from: job.state,
        to: job.state,
        reason: "operator authorized one exact pre-session Pi fresh retry launch",
        now: now,
        database: database
      )
      return false
    }
  }

  private static func requireCanaryPiFreshRetry(
    active: ActiveJobCanary,
    recoveryEvidenceSHA256: String,
    authorizedRetryEvidenceSHA256: String?,
    activeAgentAuthorityReceipt: HerdrTopologyMutationReceipt? = nil,
    activeAgentAuthorityKind: HerdrTopologyMutationIntent.Kind? = nil,
    allowFailedResetIntent: Bool = false,
    allowReplacementLaunch: Bool = false,
    allowUnrelatedActiveLeasesForStartup: Bool = false,
    database: isolated SQLiteStore
  ) throws -> JobCanaryPiRetryDurableState {
    let job = try canaryJob(active.jobID, database: database)
    let id = job.id.uuidString.lowercased()
    let prefix = canaryEventPrefix(active)
    let recoveryKey = prefix + "topology-recovery:" + recoveryEvidenceSHA256
    let resumeKey = prefix + "topology-resume:" + recoveryEvidenceSHA256
    let selectionKey = prefix + "topology-run-review:" + recoveryEvidenceSHA256
    let retryRows = try database.query(
      "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "pi-fresh-retry:*")]
    )
    let primeIntentRows = try database.query(
      """
      SELECT id, intent_sha256, payload_sha256, state, attribution_json
      FROM herdr_topology_intents
      WHERE job_id = ? AND kind = 'primeAgentAuthority'
      ORDER BY created_at, id
      """,
      bindings: [.text(id)]
    )
    let resetIntentRows = try database.query(
      """
      SELECT id, intent_sha256, payload_sha256, state, attribution_json
      FROM herdr_topology_intents
      WHERE job_id = ? AND kind = 'resetAgentAuthority'
      ORDER BY created_at, id
      """,
      bindings: [.text(id)]
    )
    func activeReceiptMatches(_ row: SQLiteRow) throws -> Bool {
      guard let activeAgentAuthorityReceipt else { return false }
      return try text(row, "id") == activeAgentAuthorityReceipt.mutationID
        && text(row, "intent_sha256") == activeAgentAuthorityReceipt.intentSHA256
    }
    let failedPrimeIntent: JobCanaryFailedAgentPrimeIntent?
    if primeIntentRows.isEmpty {
      guard activeAgentAuthorityKind != .primeAgentAuthority else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      failedPrimeIntent = nil
    } else {
      guard primeIntentRows.count == 1,
        try optionalText(primeIntentRows[0], "attribution_json") == nil
      else { throw DurableJobStoreError.canaryRecoveryRequired }
      let state = try text(primeIntentRows[0], "state")
      if state == "sendStarted",
        activeAgentAuthorityKind == .primeAgentAuthority,
        try activeReceiptMatches(primeIntentRows[0])
      {
        failedPrimeIntent = nil
      } else {
        guard state == "unknown", activeAgentAuthorityKind != .primeAgentAuthority else {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
        let intent = JobCanaryFailedAgentPrimeIntent(
          id: try text(primeIntentRows[0], "id"),
          intentSHA256: try text(primeIntentRows[0], "intent_sha256"),
          payloadSHA256: try text(primeIntentRows[0], "payload_sha256")
        )
        guard intent.id.wholeMatch(of: /^prime-[0-9a-f-]{36}$/) != nil,
          GitHubInputValidation.validSHA256(intent.intentSHA256),
          GitHubInputValidation.validSHA256(intent.payloadSHA256)
        else { throw DurableJobStoreError.canaryRecoveryRequired }
        failedPrimeIntent = intent
      }
    }
    if activeAgentAuthorityKind == .resetAgentAuthority {
      guard failedPrimeIntent != nil,
        resetIntentRows.count == 1,
        try text(resetIntentRows[0], "state") == "sendStarted",
        try optionalText(resetIntentRows[0], "attribution_json") == nil,
        try activeReceiptMatches(resetIntentRows[0])
      else { throw DurableJobStoreError.canaryRecoveryRequired }
    } else if allowFailedResetIntent {
      guard failedPrimeIntent != nil, resetIntentRows.count == 1,
        try text(resetIntentRows[0], "state") == "unknown",
        try optionalText(resetIntentRows[0], "attribution_json") == nil,
        try text(resetIntentRows[0], "id").wholeMatch(of: /^reset-[0-9a-f-]{36}$/) != nil,
        GitHubInputValidation.validSHA256(try text(resetIntentRows[0], "intent_sha256")),
        GitHubInputValidation.validSHA256(try text(resetIntentRows[0], "payload_sha256"))
      else { throw DurableJobStoreError.canaryRecoveryRequired }
    } else {
      guard resetIntentRows.isEmpty else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
    }
    let runs = try database.query(
      "SELECT * FROM pi_runs WHERE job_id = ? ORDER BY created_at, id",
      bindings: [.text(id)]
    )
    guard runs.count == 1 else { throw DurableJobStoreError.canaryRecoveryRequired }
    let run = try PiRunStore.decodeRun(runs[0])
    let launches = try database.query(
      "SELECT * FROM pi_run_launches WHERE run_id = ? ORDER BY queue_sequence, launch_attempt_id",
      bindings: [.text(run.id)]
    )
    guard (1...(allowReplacementLaunch ? 4 : 3)).contains(launches.count) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let allDecodedLaunches = try launches.map(PiRunStore.decodeLaunch)
    let replacementLaunch = allDecodedLaunches.count == 4 ? allDecodedLaunches.last : nil
    let decodedLaunches = Array(allDecodedLaunches.prefix(3))
    guard let launch = decodedLaunches.last,
      replacementLaunch == nil || allowReplacementLaunch
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    let expectedRetryRows: Int
    if failedPrimeIntent == nil {
      expectedRetryRows =
        decodedLaunches.count - (authorizedRetryEvidenceSHA256 == nil ? 1 : 0)
    } else {
      guard decodedLaunches.count == 3 else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      expectedRetryRows =
        decodedLaunches.count + (authorizedRetryEvidenceSHA256 == nil ? 0 : 1)
    }
    guard retryRows.count == expectedRetryRows else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    for (index, row) in retryRows.enumerated() {
      let eventKey = try text(row, "event_key")
      let launchIndex = min(index, decodedLaunches.count - 1)
      let eventPrefix =
        prefix + "pi-fresh-retry:" + run.id + ":"
        + decodedLaunches[launchIndex].launchAttemptID + ":"
      guard eventKey.hasPrefix(eventPrefix) else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      let evidenceSHA256 = String(eventKey.dropFirst(eventPrefix.count))
      guard GitHubInputValidation.validSHA256(evidenceSHA256) else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
      if index == retryRows.count - 1, let authorizedRetryEvidenceSHA256 {
        guard evidenceSHA256 == authorizedRetryEvidenceSHA256 else {
          throw DurableJobStoreError.canaryRecoveryRequired
        }
      }
    }
    let inputRows = try database.query(
      "SELECT sha256 FROM artifacts WHERE job_id = ? AND kind = 'input' ORDER BY created_at, rowid",
      bindings: [.text(id)]
    )
    let inputSHA256s = try inputRows.map { try text($0, "sha256") }
    let eventRows = try database.query(
      "SELECT sequence, launch_attempt_id, kind, detail_code FROM pi_run_events WHERE run_id = ? ORDER BY sequence",
      bindings: [.text(run.id)]
    )
    let initialLaunch = decodedLaunches[0]
    let initialEventKinds = [
      "prepared", "enqueued", "running", "childProcessRecorded", "failed",
    ]
    let initialEventsValid =
      try eventRows.count >= initialEventKinds.count
      && eventRows.prefix(initialEventKinds.count).enumerated().allSatisfy { index, row in
        try integer(row, "sequence") == Int64(index + 1)
          && text(row, "kind") == initialEventKinds[index]
          && (index == 0
            ? optionalText(row, "launch_attempt_id") == nil
            : optionalText(row, "launch_attempt_id") == initialLaunch.launchAttemptID)
      }
    let retryEventKinds = ["enqueued", "running", "failed"]
    let retryEventsValid = try decodedLaunches.dropFirst().enumerated().allSatisfy {
      launchIndex, retryLaunch in
      let eventOffset = initialEventKinds.count + launchIndex * retryEventKinds.count
      guard eventRows.count >= eventOffset + retryEventKinds.count else { return false }
      return try eventRows[eventOffset..<(eventOffset + retryEventKinds.count)]
        .enumerated().allSatisfy { eventIndex, row in
          try integer(row, "sequence") == Int64(eventOffset + eventIndex + 1)
            && text(row, "kind") == retryEventKinds[eventIndex]
            && optionalText(row, "launch_attempt_id") == retryLaunch.launchAttemptID
        }
    }
    let retryLaunchesValid = decodedLaunches.dropFirst().enumerated().allSatisfy {
      index, retryLaunch in
      retryLaunch.runID == run.id
        && retryLaunch.queueSequence == index + 2
        && retryLaunch.launchMode == .fresh
        && retryLaunch.state == .failed
        && retryLaunch.failureCode == "HERDR_TRANSACTION_FAILED"
        && retryLaunch.childProcess == nil
    }
    let baseEventCount =
      initialEventKinds.count
      + (decodedLaunches.count - 1) * retryEventKinds.count
    let expectedReplacementEventKinds: [String]?
    switch replacementLaunch?.state {
    case nil, .prepared?:
      expectedReplacementEventKinds = []
    case .enqueued?:
      expectedReplacementEventKinds = ["enqueued"]
    case .running?:
      expectedReplacementEventKinds = ["enqueued", "running"]
    case .resultPrepared?:
      expectedReplacementEventKinds = ["enqueued", "running", "resultPrepared"]
    case .settled?:
      expectedReplacementEventKinds = [
        "enqueued", "running", "childProcessRecorded", "resultPrepared", "settled",
      ]
    case .released?:
      expectedReplacementEventKinds = [
        "enqueued", "running", "childProcessRecorded", "resultPrepared", "settled",
        "acknowledged", "released",
      ]
    default:
      expectedReplacementEventKinds = nil
    }
    let replacementEventsValid =
      try expectedReplacementEventKinds.map { kinds in
        guard eventRows.count == baseEventCount + kinds.count else { return false }
        return try kinds.enumerated().allSatisfy { index, kind in
          let row = eventRows[baseEventCount + index]
          return try integer(row, "sequence") == Int64(baseEventCount + index + 1)
            && text(row, "kind") == kind
            && optionalText(row, "launch_attempt_id") == replacementLaunch?.launchAttemptID
        }
      } == true
    let replacementTopologyValid: Bool
    if let replacementLaunch {
      replacementTopologyValid =
        try allowReplacementLaunch
        && replacementLaunch.runID == run.id
        && replacementLaunch.queueSequence == 4
        && replacementLaunch.launchMode == .fresh
        && replacementLaunch.roleHostID == launch.roleHostID
        && replacementLaunch.executionRoleHostID != nil
        && replacementLaunch.expectedSessionID == nil
        && replacementLaunch.resumeBoundarySHA256 == nil
        && int(
          database,
          "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ? AND state = 'waiting' AND role IN ('security', 'test', 'synthesis')",
          [.text(id)]
        ) == 3
        && int(
          database,
          "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ? AND state = 'stopped' AND role = 'architecture' AND id = ?",
          [.text(id), .text(launch.roleHostID)]
        ) == 1
        && int(
          database,
          "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ? AND id = ? AND predecessor_role_host_id = ? AND state IN ('waiting', 'running')",
          [
            .text(id), .text(replacementLaunch.executionRoleHostID ?? ""),
            .text(launch.roleHostID),
          ]
        ) == 1
    } else {
      replacementTopologyValid =
        try int(
          database,
          "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ? AND state = 'waiting' AND role IN ('architecture', 'security', 'test', 'synthesis')",
          [.text(id)]
        ) == 4
        && int(
          database,
          "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ?",
          [.text(id)]
        ) == 0
    }
    let jobBindingGeneration = try int(
      database,
      "SELECT generation FROM herdr_job_bindings WHERE job_id = ? AND state = 'active'",
      [.text(id)]
    )
    let replacementSettled =
      replacementLaunch.map {
        [.settled, .released].contains($0.state)
      } ?? false
    let runStateValid =
      replacementSettled
      ? run.accepted && run.settled
        && [.settled, .released].contains(run.outcome)
      : !run.accepted && !run.settled && run.outcome == .running
    let resultCount = try int(
      database,
      "SELECT COUNT(*) FROM pi_run_results WHERE run_id = ?",
      [.text(run.id)]
    )
    guard try int(database, "SELECT paused FROM app_settings WHERE singleton = 1") == 1,
      job.identity.kind == .prReview,
      job.state == .runningPi,
      job.currentStep == 0,
      job.currentStepKind == .review,
      job.terminalReason == nil,
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'reconciliationQueued' AND to_state = 'reconciliationQueued'",
        [.text(id), .text(recoveryKey)]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'reconciliationQueued' AND to_state = 'preparing'",
        [.text(id), .text(resumeKey)]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'preparing' AND to_state = 'runningPi'",
        [.text(id), .text(selectionKey)]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
        [.text(id), .text(prefix + "pi:*")]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ?",
        [.text(id), .text(prefix + "pi:architecture:r1")]
      ) == 1,
      try
        (allowUnrelatedActiveLeasesForStartup
        || int(database, "SELECT COUNT(*) FROM repository_leases WHERE active = 1") == 1),
      try int(
        database,
        "SELECT COUNT(*) FROM repository_leases WHERE job_id = ? AND active = 1",
        [.text(id)]
      ) == 1,
      try int(
        database,
        "SELECT COUNT(*) FROM repository_leases l JOIN job_transitions t ON t.job_id = l.job_id AND t.event_key = ? WHERE l.job_id = ? AND l.active = 1 AND l.heartbeat = t.created_at",
        [.text(resumeKey), .text(id)]
      ) == 1,
      run.workflow == .pullRequestReview,
      run.role == .architecture,
      run.round == 1,
      run.jobAttempt == job.attempt,
      Int64(run.topologyGeneration) == jobBindingGeneration,
      run.jobStep == job.currentStep,
      run.resumesRunID == nil,
      runStateValid,
      initialLaunch.runID == run.id,
      initialLaunch.queueSequence == 1,
      initialLaunch.launchMode == .fresh,
      initialLaunch.state == .failed,
      initialLaunch.failureCode == "RUNTIME_TIMEOUT",
      initialLaunch.childProcess != nil,
      launch.runID == run.id,
      launch.queueSequence == decodedLaunches.count,
      launch.launchMode == .fresh,
      launch.state == .failed,
      decodedLaunches.count == 1
        || (launch.failureCode == "HERDR_TRANSACTION_FAILED"
          && launch.childProcess == nil),
      retryLaunchesValid,
      replacementEventsValid,
      initialEventsValid,
      retryEventsValid,
      try optionalText(eventRows[4], "detail_code") == "RUNTIME_TIMEOUT",
      try decodedLaunches.dropFirst().enumerated().allSatisfy({ index, _ in
        let detailIndex = initialEventKinds.count + (index + 1) * retryEventKinds.count - 1
        return try optionalText(eventRows[detailIndex], "detail_code")
          == "HERDR_TRANSACTION_FAILED"
      }),
      resultCount == (replacementSettled ? 1 : 0),
      try int(
        database,
        "SELECT COUNT(*) FROM pi_run_session_origins WHERE run_id = ?",
        [.text(run.id)]
      ) == 0,
      !inputSHA256s.isEmpty,
      inputSHA256s.count <= 16,
      Set(inputSHA256s).count == 1,
      inputSHA256s.first.map(GitHubInputValidation.validSHA256) == true,
      try int(
        database,
        "SELECT COUNT(*) FROM artifacts WHERE job_id = ? AND kind = 'review'",
        [.text(id)]
      ) == 0,
      try int(database, "SELECT COUNT(*) FROM job_steps WHERE job_id = ?", [.text(id)]) == 0,
      try int(
        database,
        "SELECT COUNT(*) FROM approved_command_runs WHERE job_id = ?",
        [.text(id)]
      ) == 0,
      try int(
        database,
        "SELECT COUNT(*) FROM mutation_intents WHERE job_id = ?",
        [.text(id)]
      ) == 0,
      replacementTopologyValid,
      try int(
        database,
        "SELECT COUNT(*) FROM herdr_role_hosts WHERE job_id = ?",
        [.text(id)]
      ) == 4
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    return JobCanaryPiRetryDurableState(
      job: job,
      run: run,
      launches: decodedLaunches,
      launch: launch,
      inputArtifactCount: inputSHA256s.count,
      inputArtifactSHA256: inputSHA256s[0],
      piEventCount: eventRows.count,
      failedPrimeIntent: failedPrimeIntent
    )
  }

  private static func requireResumedCanaryRecovery(
    active: ActiveJobCanary,
    job: JobRecord,
    recoveryEvidenceSHA256: String,
    allowUnrelatedActiveLeasesForStartup: Bool = false,
    database: isolated SQLiteStore
  ) throws {
    let id = job.id.uuidString.lowercased()
    let prefix = canaryEventPrefix(active)
    let recoveryKey = prefix + "topology-recovery:" + recoveryEvidenceSHA256
    let resumeKey = prefix + "topology-resume:" + recoveryEvidenceSHA256
    let selectionKey = prefix + "topology-run-review:" + recoveryEvidenceSHA256
    let recoveryRows = try database.query(
      "SELECT event_key, from_state, to_state FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "topology-recovery:*")]
    )
    let resumeRows = try database.query(
      "SELECT event_key, from_state, to_state FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "topology-resume:*")]
    )
    let selectionRows = try database.query(
      "SELECT event_key, from_state, to_state FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "topology-run-review:*")]
    )
    let roleRows = try database.query(
      "SELECT event_key FROM job_transitions WHERE job_id = ? AND event_key GLOB ? ORDER BY id",
      bindings: [.text(id), .text(prefix + "pi:*")]
    )
    let interruptionKey = "job:\(id):a\(job.attempt):s\(job.currentStep):pi-interrupted"
    guard GitHubInputValidation.validSHA256(recoveryEvidenceSHA256),
      try int(database, "SELECT paused FROM app_settings WHERE singleton = 1") == 1,
      job.identity.kind == .prReview,
      job.currentStep == 0,
      job.currentStepKind == .review,
      job.terminalReason == nil,
      recoveryRows.count == 1,
      try text(recoveryRows[0], "event_key") == recoveryKey,
      try text(recoveryRows[0], "from_state") == JobState.reconciliationQueued.rawValue,
      try text(recoveryRows[0], "to_state") == JobState.reconciliationQueued.rawValue,
      resumeRows.count == 1,
      try text(resumeRows[0], "event_key") == resumeKey,
      try text(resumeRows[0], "from_state") == JobState.reconciliationQueued.rawValue,
      try text(resumeRows[0], "to_state") == JobState.preparing.rawValue,
      roleRows.count == 1,
      try text(roleRows[0], "event_key") == prefix + "pi:architecture:r1",
      try int(
        database,
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key = ? AND from_state = 'runningPi' AND to_state = 'reconciliationQueued'",
        [.text(id), .text(interruptionKey)]
      ) == 1,
      try
        (allowUnrelatedActiveLeasesForStartup
        || int(database, "SELECT COUNT(*) FROM repository_leases WHERE active = 1") == 1),
      try int(
        database,
        "SELECT COUNT(*) FROM repository_leases WHERE job_id = ? AND active = 1",
        [.text(id)]
      ) == 1,
      try int(
        database,
        """
        SELECT COUNT(*)
        FROM repository_leases l
        JOIN jobs j ON j.id = l.job_id AND j.repository_id = l.repository_id
        JOIN job_transitions t ON t.job_id = j.id AND t.event_key = ?
        WHERE j.id = ? AND l.active = 1 AND l.heartbeat = t.created_at
        """,
        [.text(resumeKey), .text(id)]
      ) == 1,
      try canaryRecoveryEffectCount(database: database, jobID: id) == 0
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    switch job.state {
    case .preparing:
      guard selectionRows.isEmpty else {
        throw DurableJobStoreError.canaryRecoveryRequired
      }
    case .runningPi:
      guard selectionRows.count == 1,
        try text(selectionRows[0], "event_key") == selectionKey,
        try text(selectionRows[0], "from_state") == JobState.preparing.rawValue,
        try text(selectionRows[0], "to_state") == JobState.runningPi.rawValue
      else { throw DurableJobStoreError.canaryRecoveryRequired }
    default:
      throw DurableJobStoreError.canaryRecoveryRequired
    }
  }

  private static func canaryRecoveryEffectCount(
    database: isolated SQLiteStore,
    jobID: String
  ) throws -> Int64 {
    let runs =
      try int(
        database,
        "SELECT COUNT(*) FROM pi_runs WHERE job_id = ?",
        [.text(jobID)]
      ) ?? -1
    let launches =
      try int(
        database,
        "SELECT COUNT(*) FROM pi_run_launches l JOIN pi_runs r ON r.id = l.run_id WHERE r.job_id = ?",
        [.text(jobID)]
      ) ?? -1
    let steps =
      try int(
        database,
        "SELECT COUNT(*) FROM job_steps WHERE job_id = ?",
        [.text(jobID)]
      ) ?? -1
    let commands =
      try int(
        database,
        "SELECT COUNT(*) FROM approved_command_runs WHERE job_id = ?",
        [.text(jobID)]
      ) ?? -1
    let mutations =
      try int(
        database,
        "SELECT COUNT(*) FROM mutation_intents WHERE job_id = ?",
        [.text(jobID)]
      ) ?? -1
    guard [runs, launches, steps, commands, mutations].allSatisfy({ $0 >= 0 }) else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return runs + launches + steps + commands + mutations
  }

  private static func requireCanaryRecoveryConfiguration(
    evidence: JobCanaryRecoveryEvidence,
    database: isolated SQLiteStore
  ) throws {
    let row = try one(
      database,
      """
      SELECT r.owner AS owner, r.name AS name, r.default_branch AS default_branch,
        r.enabled AS enabled, r.review_enabled AS review_enabled,
        p.provider AS provider, p.model AS model, p.thinking AS thinking
      FROM jobs j
      JOIN repositories r ON r.id = j.repository_id
      JOIN model_profiles p ON p.role = 'review'
      WHERE j.id = ?
      """,
      [.text(evidence.jobID)]
    )
    guard try text(row, "owner") == evidence.repositoryOwner,
      try text(row, "name") == evidence.repositoryName,
      try text(row, "default_branch") == evidence.defaultBranch,
      try integer(row, "enabled") == 1,
      try integer(row, "review_enabled") == 1,
      try text(row, "provider") == evidence.provider,
      try text(row, "model") == evidence.model,
      try text(row, "thinking") == evidence.thinking
    else { throw DurableJobStoreError.canaryEvidenceMismatch }
  }

  private static func requireCanaryRecoveryTopology(
    evidence: JobCanaryRecoveryEvidence,
    activated: Bool,
    database: isolated SQLiteStore
  ) throws {
    let intentRows = try database.query(
      "SELECT * FROM herdr_topology_intents WHERE job_id = ? ORDER BY kind, id",
      bindings: [.text(evidence.jobID)]
    )
    guard intentRows.count == 2,
      let unknown = intentRows.first(where: {
        (try? text($0, "kind")) == HerdrTopologyMutationIntent.Kind.applyLayout.rawValue
      }),
      let workspace = intentRows.first(where: {
        (try? text($0, "kind")) == HerdrTopologyMutationIntent.Kind.createWorkspace.rawValue
      }),
      try text(unknown, "id") == evidence.unknownIntentID,
      try text(unknown, "intent_sha256") == evidence.unknownIntentSHA256,
      try text(unknown, "payload_sha256") == evidence.unknownPayloadSHA256,
      try text(unknown, "repository_id") == evidence.repositoryID,
      try integer(unknown, "generation") == Int64(evidence.generation),
      try text(unknown, "state") == HerdrTopologyStoredIntentState.unknown.rawValue,
      try integer(unknown, "socket_device") == Int64(bitPattern: evidence.socketDevice),
      try integer(unknown, "socket_inode") == Int64(bitPattern: evidence.socketInode),
      try integer(unknown, "socket_owner") == Int64(evidence.socketOwner),
      try integer(unknown, "socket_permissions") == Int64(evidence.socketPermissions),
      try text(workspace, "repository_id") == evidence.repositoryID,
      try integer(workspace, "generation") == Int64(evidence.generation),
      try text(workspace, "state") == HerdrTopologyStoredIntentState.attributed.rawValue,
      let workspaceAttributionValue = try optionalText(workspace, "attribution_json"),
      let workspaceAttributionData = workspaceAttributionValue.data(using: .utf8),
      let workspaceAttribution = try? JSONDecoder().decode(
        HerdrTopologyMutationAttribution.self,
        from: workspaceAttributionData
      ),
      workspaceAttribution.workspaceID == evidence.workspaceID
    else { throw DurableJobStoreError.canaryEvidenceMismatch }
    let bindingState =
      activated ? HerdrBindingState.active.rawValue : HerdrBindingState.prepared.rawValue
    guard
      try int(
        database,
        """
        SELECT COUNT(*) FROM herdr_job_bindings
        WHERE job_id = ? AND repository_id = ? AND generation = ? AND workspace_id = ?
          AND state = ? AND ((? = 1 AND tab_id = ?) OR (? = 0 AND tab_id IS NULL))
        """,
        [
          .text(evidence.jobID), .text(evidence.repositoryID),
          .integer(Int64(evidence.generation)), .text(evidence.workspaceID),
          .text(bindingState), .integer(activated ? 1 : 0), .text(evidence.tabID),
          .integer(activated ? 1 : 0),
        ]
      ) == 1
    else { throw DurableJobStoreError.canaryEvidenceMismatch }
    let hosts = try database.query(
      "SELECT * FROM herdr_role_hosts WHERE job_id = ? AND generation = ? ORDER BY role",
      bindings: [.text(evidence.jobID), .integer(Int64(evidence.generation))]
    )
    guard hosts.count == evidence.hosts.count else {
      throw DurableJobStoreError.canaryEvidenceMismatch
    }
    for expected in evidence.hosts {
      guard let row = hosts.first(where: { (try? text($0, "id")) == expected.roleHostID }),
        try text(row, "role") == expected.role,
        try text(row, "workspace_id") == expected.workspaceID,
        try text(row, "bootstrap_descriptor_sha256") == expected.bootstrapDescriptorSHA256,
        try text(row, "host_executable_sha256") == expected.hostExecutableSHA256,
        try text(row, "state")
          == (activated
            ? HerdrRoleHostState.waiting.rawValue : HerdrRoleHostState.prepared.rawValue),
        try integer(row, "last_queue_sequence") == 0,
        try integer(row, "lifecycle_sequence") == (activated ? 1 : 0)
      else { throw DurableJobStoreError.canaryEvidenceMismatch }
      if activated {
        guard try optionalText(row, "tab_id") == expected.tabID,
          try optionalText(row, "pane_id") == expected.paneID,
          try optionalText(row, "terminal_id") == expected.terminalID,
          try optionalInteger(row, "host_pid") == Int64(expected.processID),
          try optionalInteger(row, "host_start_seconds")
            == Int64(bitPattern: expected.startSeconds),
          try optionalInteger(row, "host_start_microseconds")
            == Int64(bitPattern: expected.startMicroseconds)
        else { throw DurableJobStoreError.canaryEvidenceMismatch }
      } else {
        guard try optionalText(row, "tab_id") == nil,
          try optionalText(row, "pane_id") == nil,
          try optionalText(row, "terminal_id") == nil,
          try optionalInteger(row, "host_pid") == nil
        else { throw DurableJobStoreError.canaryEvidenceMismatch }
      }
    }
  }

  private static func canaryPreview(
    scope: JobCanaryScope,
    resourceTreeSHA256: String,
    database: isolated SQLiteStore,
    allowSettledJob: Bool = false,
    allowExistingAuthorization: String? = nil
  ) throws -> JobCanaryReport {
    let jobID = scope.jobID.uuidString.lowercased()
    let row = try one(
      database,
      """
      SELECT j.repository_id AS repository_id, j.kind AS job_kind,
        j.object_node_id AS object_node_id, j.object_number AS object_number,
        j.revision_key AS revision_key, j.contract_version_used AS contract_version,
        j.priority AS priority, j.state AS job_state, j.attempt AS attempt,
        j.current_step AS current_step, j.current_step_kind AS current_step_kind,
        j.not_before AS not_before, j.created_at AS created_at,
        j.updated_at AS job_updated_at, j.terminal_reason AS terminal_reason,
        r.node_id AS repository_node_id, r.owner AS repository_owner,
        r.name AS repository_name, r.default_branch AS default_branch,
        r.review_enabled AS review_enabled, r.triage_enabled AS triage_enabled,
        r.implementation_enabled AS implementation_enabled,
        r.enabled AS repository_enabled, r.updated_at AS repository_updated_at,
        d.state AS disposition_state,
        d.contract_version_used AS disposition_contract_version,
        d.last_job_id AS disposition_last_job_id,
        d.last_mutation_id AS disposition_last_mutation_id,
        d.evidence_digest AS disposition_evidence,
        d.mutation_generation AS disposition_generation, d.updated_at AS disposition_updated_at,
        p.provider AS provider, p.model AS model, p.thinking AS thinking,
        p.updated_at AS profile_updated_at,
        a.github_account AS github_account, a.github_author_id AS github_author_id,
        a.updated_at AS settings_updated_at
      FROM jobs j
      JOIN repositories r ON r.id = j.repository_id
      JOIN object_dispositions d ON d.repository_id = j.repository_id
        AND d.kind = j.kind AND d.object_node_id = j.object_node_id
        AND d.revision_key = j.revision_key
      JOIN model_profiles p ON p.role = 'review'
      JOIN app_settings a ON a.singleton = 1
      WHERE j.id = ?
      """,
      [.text(jobID)]
    )
    let state = try text(row, "job_state")
    let contractVersion = try text(row, "contract_version")
    let dispositionContractVersion = try text(row, "disposition_contract_version")
    guard try text(row, "job_kind") == JobKind.prReview.rawValue,
      try real(row, "created_at") >= Double(scope.boundaryEpochSeconds),
      try integer(row, "review_enabled") == 1,
      try integer(row, "repository_enabled") == 1,
      let objectNumber = try optionalInteger(row, "object_number"), objectNumber > 0,
      try int(
        database,
        """
        SELECT COUNT(*) FROM app_settings
        WHERE singleton = 1 AND paused = 1 AND onboarding_complete = 1
          AND external_automation_acknowledged = 1
          AND provider_disclosure_acknowledged = 1
          AND login_item_selected = 1 AND login_item_status = 'enabled'
          AND github_account IS NOT NULL AND github_author_id IS NOT NULL
        """
      ) == 1
    else { throw DurableJobStoreError.canaryUnsafe(scope.jobID) }
    var retryAuthority: JobCanaryRetryAuthority?
    if !allowSettledJob {
      guard try integer(row, "priority") == Int64(JobPriority.prReview.rawValue),
        try integer(row, "current_step") == 0,
        try text(row, "current_step_kind") == JobStepKind.review.rawValue,
        try optionalText(row, "terminal_reason") == nil,
        try text(row, "disposition_state") == ObjectDispositionState.humanRetryAuthorized.rawValue,
        dispositionContractVersion == contractVersion,
        try optionalText(row, "disposition_last_job_id") == jobID,
        try text(row, "disposition_evidence") == scope.repairEvidenceSHA256
      else { throw DurableJobStoreError.canaryUnsafe(scope.jobID) }
      switch JobState(rawValue: state) {
      case .queued:
        guard try optionalReal(row, "not_before") == nil else {
          throw DurableJobStoreError.canaryUnsafe(scope.jobID)
        }
      case .retryBackoff:
        guard try optionalReal(row, "not_before") != nil,
          let authority = try closedNoEffectRetryAuthority(
            jobID: scope.jobID,
            database: database
          )
        else { throw DurableJobStoreError.canaryUnsafe(scope.jobID) }
        retryAuthority = authority
      default:
        throw DurableJobStoreError.canaryUnsafe(scope.jobID)
      }
      for table in [
        "job_steps", "pi_runs", "approved_command_runs", "mutation_intents",
        "herdr_topology_intents", "herdr_job_bindings", "herdr_role_hosts",
      ] {
        guard
          try int(database, "SELECT COUNT(*) FROM \(table) WHERE job_id = ?", [.text(jobID)]) == 0
        else {
          throw DurableJobStoreError.canaryUnsafe(scope.jobID)
        }
      }
      guard
        try int(
          database,
          "SELECT COUNT(*) FROM pi_run_launches l JOIN pi_runs r ON r.id = l.run_id WHERE r.job_id = ?",
          [.text(jobID)]) == 0,
        try int(
          database, "SELECT COUNT(*) FROM repository_leases WHERE job_id = ? AND active = 1",
          [.text(jobID)]) == 0
      else { throw DurableJobStoreError.canaryUnsafe(scope.jobID) }
    }
    let repairEvent =
      "maintenance:retryResourceFailuresAfter:\(scope.boundaryEpochSeconds):\(scope.repairEvidenceSHA256):\(jobID)"
    let repairRow = try one(
      database,
      "SELECT event_key, created_at FROM job_transitions WHERE job_id = ? AND event_key = ?",
      [.text(jobID), .text(repairEvent)]
    )
    if let active = try activeCanary(database: database),
      active.authorizationSHA256 != allowExistingAuthorization
    {
      throw DurableJobStoreError.canaryUnsafe(scope.jobID)
    }
    let evidence = JobCanaryEvidence(
      scope: scope,
      repositoryID: try text(row, "repository_id"),
      repositoryNodeID: try text(row, "repository_node_id"),
      repositoryOwner: try text(row, "repository_owner"),
      repositoryName: try text(row, "repository_name"),
      defaultBranch: try text(row, "default_branch"),
      reviewEnabled: try integer(row, "review_enabled"),
      triageEnabled: try integer(row, "triage_enabled"),
      implementationEnabled: try integer(row, "implementation_enabled"),
      repositoryEnabled: try integer(row, "repository_enabled"),
      repositoryUpdatedAtBits: bits(try real(row, "repository_updated_at")),
      jobKind: try text(row, "job_kind"),
      objectNodeID: try text(row, "object_node_id"),
      objectNumber: Int(objectNumber),
      revisionKey: try text(row, "revision_key"),
      contractVersion: contractVersion,
      priority: try integer(row, "priority"),
      jobState: state,
      attempt: try integer(row, "attempt"),
      currentStep: try integer(row, "current_step"),
      currentStepKind: try text(row, "current_step_kind"),
      notBeforeBits: try optionalReal(row, "not_before").map(bits),
      createdAtBits: bits(try real(row, "created_at")),
      updatedAtBits: bits(try real(row, "job_updated_at")),
      terminalReason: try optionalText(row, "terminal_reason"),
      dispositionState: try text(row, "disposition_state"),
      dispositionContractVersion: dispositionContractVersion,
      dispositionLastJobID: try optionalText(row, "disposition_last_job_id"),
      dispositionLastMutationID: try optionalText(row, "disposition_last_mutation_id"),
      dispositionEvidence: try optionalText(row, "disposition_evidence"),
      dispositionGeneration: try integer(row, "disposition_generation"),
      dispositionUpdatedAtBits: bits(try real(row, "disposition_updated_at")),
      repairTransitionEvent: try text(repairRow, "event_key"),
      repairTransitionCreatedAtBits: bits(try real(repairRow, "created_at")),
      provider: try text(row, "provider"),
      model: try text(row, "model"),
      thinking: try text(row, "thinking"),
      profileUpdatedAtBits: bits(try real(row, "profile_updated_at")),
      githubAccount: try text(row, "github_account"),
      githubAuthorID: try integer(row, "github_author_id"),
      settingsUpdatedAtBits: bits(try real(row, "settings_updated_at")),
      resourceTreeSHA256: resourceTreeSHA256,
      piRoles: canaryRoles.map(\.rawValue),
      allowedGitHubOperation: MutationOperation.createMarkerComment.rawValue,
      retryAuthority: retryAuthority
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let digest = SHA256.hash(data: try encoder.encode(evidence)).map { String(format: "%02x", $0) }
      .joined()
    return JobCanaryReport(
      scope: scope,
      previewEvidenceSHA256: digest,
      authorizationSHA256: nil,
      status: .preview,
      repositoryOwner: evidence.repositoryOwner,
      repositoryName: evidence.repositoryName,
      objectNumber: Int(objectNumber),
      revisionKey: evidence.revisionKey,
      provider: evidence.provider,
      model: evidence.model,
      thinking: evidence.thinking,
      resourceTreeSHA256: resourceTreeSHA256,
      replayed: false
    )
  }

  private static func report(
    _ preview: JobCanaryReport,
    previewEvidenceSHA: String? = nil,
    authorizationSHA: String,
    status: JobCanaryStatus,
    replayed: Bool
  ) -> JobCanaryReport {
    JobCanaryReport(
      scope: preview.scope,
      previewEvidenceSHA256: previewEvidenceSHA ?? preview.previewEvidenceSHA256,
      authorizationSHA256: authorizationSHA,
      status: status,
      repositoryOwner: preview.repositoryOwner,
      repositoryName: preview.repositoryName,
      objectNumber: preview.objectNumber,
      revisionKey: preview.revisionKey,
      provider: preview.provider,
      model: preview.model,
      thinking: preview.thinking,
      resourceTreeSHA256: preview.resourceTreeSHA256,
      replayed: replayed
    )
  }

  private static func closedNoEffectRetryAuthority(
    jobID: UUID,
    database: isolated SQLiteStore
  ) throws -> JobCanaryRetryAuthority? {
    let id = jobID.uuidString.lowercased()
    guard
      let admission = try database.query(
        """
        SELECT id, event_key FROM job_transitions
        WHERE job_id = ? AND event_key GLOB 'canary:*:m*:admit:*'
        ORDER BY id DESC LIMIT 1
        """,
        bindings: [.text(id)]
      ).first
    else { return nil }
    let admissionID = try integer(admission, "id")
    let admissionEvent = try text(admission, "event_key")
    let parts = admissionEvent.split(separator: ":", omittingEmptySubsequences: false).map(
      String.init
    )
    guard parts.count == 5, parts[0] == "canary",
      GitHubInputValidation.validSHA256(parts[1]), parts[2].first == "m",
      let maximum = Int(parts[2].dropFirst()),
      (1...JobCanaryScope.maximumCommentPartLimit).contains(maximum),
      parts[3] == "admit", parts[4] == id
    else { return nil }
    let prefix = "canary:\(parts[1]):m\(maximum):"
    let closeEvent = prefix + "close:" + id
    let closeRows = try database.query(
      """
      SELECT id, created_at FROM job_transitions
      WHERE job_id = ? AND event_key = ? AND id > ?
      """,
      bindings: [.text(id), .text(closeEvent), .integer(admissionID)]
    )
    guard closeRows.count == 1, let close = closeRows.first else { return nil }
    let closeID = try integer(close, "id")
    let canaryEffects = try database.query(
      """
      SELECT id, event_key FROM job_transitions
      WHERE job_id = ? AND id > ? AND id < ? AND event_key GLOB ?
      ORDER BY id
      """,
      bindings: [
        .text(id), .integer(admissionID), .integer(closeID), .text(prefix + "*"),
      ]
    )
    let piEvent = prefix + "pi:architecture:r1"
    guard canaryEffects.count == 1, let pi = canaryEffects.first,
      try text(pi, "event_key") == piEvent
    else { return nil }
    let piID = try integer(pi, "id")
    let failures = try database.query(
      """
      SELECT id, event_key, reason, created_at FROM job_transitions
      WHERE job_id = ? AND id > ? AND id < ?
        AND from_state = 'runningPi' AND to_state = 'retryBackoff'
      ORDER BY id
      """,
      bindings: [.text(id), .integer(piID), .integer(closeID)]
    )
    guard failures.count == 1, let failure = failures.first else { return nil }
    let failureEvent = try text(failure, "event_key")
    guard failureEvent.hasPrefix("job:\(id):a"), failureEvent.hasSuffix(":s0:retry"),
      try text(failure, "reason")
        == "job coordinator scheduled retry after JidokaCodeCore.HerdrPiWorkflowError"
    else { return nil }
    return JobCanaryRetryAuthority(
      admissionEventKey: admissionEvent,
      piAuthorizationEventKey: piEvent,
      failureEventKey: failureEvent,
      failureCreatedAtBits: bits(try real(failure, "created_at")),
      closeEventKey: closeEvent,
      closeCreatedAtBits: bits(try real(close, "created_at"))
    )
  }

  static func activeCanary(database: isolated SQLiteStore) throws -> ActiveJobCanary? {
    // Admissions and closes are serialized by one SQLite writer. Therefore the latest
    // admission is the only admission that can be open in a history produced by this API.
    guard
      let row = try database.query(
        """
        SELECT job_id, event_key FROM job_transitions
        WHERE event_key GLOB 'canary:*:m*:admit:*'
        ORDER BY id DESC LIMIT 1
        """
      ).first
    else { return nil }
    let event = try text(row, "event_key")
    let parts = event.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 5, parts[0] == "canary", GitHubInputValidation.validSHA256(parts[1]),
      parts[2].first == "m", let maximum = Int(parts[2].dropFirst()),
      (1...JobCanaryScope.maximumCommentPartLimit).contains(maximum), parts[3] == "admit",
      let id = UUID(uuidString: parts[4]), id.uuidString.lowercased() == parts[4],
      try text(row, "job_id") == parts[4]
    else { throw DurableJobStoreError.canaryEffectDenied }
    let close = canaryEventKey(
      authorizationSHA: parts[1], maximumCommentParts: maximum,
      kind: "close", suffix: id.uuidString.lowercased()
    )
    guard !(try eventExists(close, ownedBy: id, database: database)) else { return nil }
    return ActiveJobCanary(
      jobID: id, authorizationSHA256: parts[1], maximumCommentParts: maximum,
      admitEventKey: event
    )
  }

  private static func canaryEventKey(
    authorizationSHA: String,
    maximumCommentParts: Int,
    kind: String,
    suffix: String
  ) -> String {
    "canary:\(authorizationSHA):m\(maximumCommentParts):\(kind):\(suffix)"
  }

  private static func canaryEventPrefix(_ active: ActiveJobCanary) -> String {
    "canary:\(active.authorizationSHA256):m\(active.maximumCommentParts):"
  }

  private static func insertCanaryEvent(
    jobID: UUID,
    eventKey: String,
    from: JobState,
    to: JobState,
    reason: String,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    guard eventKey.utf8.count <= 512 else { throw DurableJobStoreError.invalidEventKey }
    let job = try canaryJob(jobID, database: database)
    _ = try database.execute(
      """
      INSERT INTO job_transitions(
        job_id, event_key, from_state, to_state, reason,
        attempt_before, attempt_after, step_before, step_after, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()), .text(eventKey),
        .text(from.rawValue), .text(to.rawValue), .text(reason),
        .integer(Int64(job.attempt)), .integer(Int64(job.attempt)),
        .integer(Int64(job.currentStep)), .integer(Int64(job.currentStep)),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  private static func canaryJob(_ id: UUID, database: isolated SQLiteStore) throws -> JobRecord {
    guard
      let row = try database.query(
        "SELECT * FROM jobs WHERE id = ?", bindings: [.text(id.uuidString.lowercased())]
      ).first
    else {
      throw DurableJobStoreError.jobNotFound(id)
    }
    func t(_ name: String) throws -> String { try text(row, name) }
    guard let repositoryID = UUID(uuidString: try t("repository_id")),
      let kind = JobKind(rawValue: try t("kind")),
      let priority = JobPriority(rawValue: Int(try integer(row, "priority"))),
      let state = JobState(rawValue: try t("state"))
    else { throw DurableJobStoreError.decode("canary job") }
    return JobRecord(
      id: id,
      identity: LogicalJobIdentity(
        repositoryID: repositoryID, kind: kind, objectNodeID: try t("object_node_id"),
        revisionKey: try t("revision_key")),
      objectNumber: try optionalInteger(row, "object_number").map(Int.init),
      contractVersionUsed: try t("contract_version_used"), priority: priority, state: state,
      currentStep: Int(try integer(row, "current_step")),
      currentStepKind: try optionalText(row, "current_step_kind").flatMap(
        JobStepKind.init(rawValue:)),
      attempt: Int(try integer(row, "attempt")),
      notBefore: try optionalReal(row, "not_before").map(Date.init(timeIntervalSince1970:)),
      createdAt: Date(timeIntervalSince1970: try real(row, "created_at")),
      updatedAt: Date(timeIntervalSince1970: try real(row, "updated_at")),
      terminalReason: try optionalText(row, "terminal_reason")
    )
  }

  private static func eventExists(
    _ key: String,
    ownedBy jobID: UUID,
    database: isolated SQLiteStore
  ) throws -> Bool {
    let rows = try database.query(
      "SELECT job_id FROM job_transitions WHERE event_key = ?",
      bindings: [.text(key)]
    )
    guard let row = rows.first else { return false }
    guard rows.count == 1, try text(row, "job_id") == jobID.uuidString.lowercased() else {
      throw DurableJobStoreError.eventKeyOwnedByAnotherJob
    }
    return true
  }

  private static func terminalReplacementPreCutoverPredecessor(
    jobID: UUID,
    canaryAuthorizationSHA256: String,
    database: isolated SQLiteStore
  ) throws -> String? {
    let id = jobID.uuidString.lowercased()
    let authorizationRows = try database.query(
      "SELECT * FROM herdr_role_host_replacement_authorizations WHERE job_id = ?",
      bindings: [.text(id)]
    )
    let intentRows = try database.query(
      "SELECT * FROM herdr_topology_intents WHERE job_id = ? AND kind = 'replaceRoleHost' ORDER BY created_at, id",
      bindings: [.text(id)]
    )
    if authorizationRows.isEmpty,
      intentRows.isEmpty
    {
      return nil
    }
    if authorizationRows.count == 1,
      intentRows.isEmpty
    {
      return nil
    }
    if authorizationRows.count == 1, intentRows.count == 1 {
      let state = try text(intentRows[0], "state")
      if state == HerdrTopologyStoredIntentState.prepared.rawValue
        || state == HerdrTopologyStoredIntentState.attributed.rawValue
      {
        return nil
      }
    }
    guard authorizationRows.count == 1, intentRows.count == 1 else {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    let authorization = authorizationRows[0]
    let intent = intentRows[0]
    let predecessorRoleHostID = try text(authorization, "predecessor_role_host_id")
    let runID = try text(authorization, "run_id")
    let mutationID = try text(intent, "id")
    let intentState = try text(intent, "state")
    let intentFailureCode = try optionalText(intent, "failure_code")
    let intentFailureValid =
      intentState == "failedNoRemoteEffect"
      ? intentFailureCode.map(JobCanaryRoleHostReplacementOutcome.validFailureCode) == true
      : intentFailureCode == nil
    guard
      try text(authorization, "canary_authorization_sha256")
        == canaryAuthorizationSHA256,
      GitHubInputValidation.validSHA256(
        try text(authorization, "replacement_authorization_sha256")
      ),
      GitHubInputValidation.validSHA256(try text(authorization, "payload_sha256")),
      GitHubInputValidation.validSHA256(
        try text(authorization, "replacement_evidence_sha256")
      ),
      mutationID.wholeMatch(of: /^replace-[0-9a-f-]{36}$/) != nil,
      [
        HerdrTopologyStoredIntentState.unknown.rawValue,
        "failedNoRemoteEffect",
      ].contains(intentState),
      try optionalText(intent, "attribution_json") == nil,
      intentFailureValid,
      try int(
        database,
        "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ?",
        [.text(id)]
      ) == 0,
      try int(
        database,
        "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ? AND queue_sequence >= 4",
        [.text(runID)]
      ) == 0,
      try int(
        database,
        """
        SELECT COUNT(*)
        FROM herdr_topology_intents AS exact_intent
        JOIN herdr_role_host_replacement_authorizations AS exact_authorization
          ON exact_authorization.repository_id = exact_intent.repository_id
          AND exact_authorization.job_id = exact_intent.job_id
          AND exact_authorization.generation = exact_intent.generation
          AND exact_authorization.payload_sha256 = exact_intent.payload_sha256
        JOIN herdr_role_hosts AS predecessor
          ON predecessor.id = exact_authorization.predecessor_role_host_id
          AND predecessor.job_id = exact_authorization.job_id
          AND predecessor.generation = exact_authorization.generation
          AND predecessor.role = 'architecture'
          AND predecessor.state = 'waiting'
        JOIN herdr_job_bindings AS binding
          ON binding.job_id = exact_authorization.job_id
          AND binding.repository_id = exact_authorization.repository_id
          AND binding.generation = exact_authorization.generation
          AND binding.state = 'active'
        JOIN herdr_repository_bindings AS repository_binding
          ON repository_binding.repository_id = exact_authorization.repository_id
          AND repository_binding.workspace_id = binding.workspace_id
          AND repository_binding.socket_device = exact_intent.socket_device
          AND repository_binding.socket_inode = exact_intent.socket_inode
          AND repository_binding.socket_owner = exact_intent.socket_owner
          AND repository_binding.socket_permissions = exact_intent.socket_permissions
          AND repository_binding.state = 'active'
        JOIN pi_runs AS exact_run
          ON exact_run.id = exact_authorization.run_id
          AND exact_run.job_id = exact_authorization.job_id
          AND exact_run.topology_generation = exact_authorization.generation
        JOIN pi_run_launches AS failed_launch
          ON failed_launch.launch_attempt_id
            = exact_authorization.failed_launch_attempt_id
          AND failed_launch.run_id = exact_run.id
          AND failed_launch.role_host_id = predecessor.id
          AND failed_launch.queue_sequence = 3
          AND failed_launch.state = 'failed'
          AND failed_launch.failure_code = 'HERDR_TRANSACTION_FAILED'
          AND failed_launch.child_pid IS NULL
        WHERE exact_authorization.job_id = ?
          AND exact_authorization.predecessor_role_host_id = ?
          AND predecessor.workspace_id = binding.workspace_id
          AND predecessor.tab_id = binding.tab_id
          AND exact_intent.id = ?
          AND exact_intent.kind = 'replaceRoleHost'
          AND exact_intent.state IN ('unknown', 'failedNoRemoteEffect')
          AND exact_intent.attribution_json IS NULL
          AND (
            (exact_intent.state = 'unknown' AND exact_intent.failure_code IS NULL)
            OR (
              exact_intent.state = 'failedNoRemoteEffect'
              AND exact_intent.failure_code IS NOT NULL
            )
          )
        """,
        [.text(id), .text(predecessorRoleHostID), .text(mutationID)]
      ) == 1
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    let generationValue = try integer(intent, "generation")
    let deviceValue = try integer(intent, "socket_device")
    let inodeValue = try integer(intent, "socket_inode")
    let ownerValue = try integer(intent, "socket_owner")
    let permissionsValue = try integer(intent, "socket_permissions")
    guard let generation = Int(exactly: generationValue), generation > 0,
      let device = UInt64(exactly: deviceValue),
      let inode = UInt64(exactly: inodeValue),
      let owner = UInt32(exactly: ownerValue),
      let permissions = UInt16(exactly: permissionsValue)
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    let reconstructed = HerdrTopologyMutationIntent(
      mutationID: mutationID,
      kind: .replaceRoleHost,
      repositoryID: try text(intent, "repository_id"),
      jobID: try text(intent, "job_id"),
      generation: generation,
      payloadSHA256: try text(intent, "payload_sha256"),
      socketIdentity: HerdrSocketIdentityRecord(
        HerdrSocketIdentity(
          device: device,
          inode: inode,
          owner: owner,
          permissions: permissions
        )
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard
      GitHubMarkerCodec.sha256(try encoder.encode(reconstructed))
        == (try text(intent, "intent_sha256"))
    else { throw DurableJobStoreError.canaryRecoveryRequired }
    return predecessorRoleHostID
  }

  private static func replacementPreCutoverStateIsInert(
    jobID: UUID,
    canaryAuthorizationSHA256: String,
    database: isolated SQLiteStore
  ) throws -> Bool {
    let id = jobID.uuidString.lowercased()
    let authorizationRows = try database.query(
      "SELECT * FROM herdr_role_host_replacement_authorizations WHERE job_id = ?",
      bindings: [.text(id)]
    )
    guard authorizationRows.count == 1,
      try text(authorizationRows[0], "canary_authorization_sha256")
        == canaryAuthorizationSHA256,
      try int(
        database,
        "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ?",
        [.text(id)]
      ) == 0,
      try int(
        database,
        "SELECT COUNT(*) FROM pi_run_launches AS launch JOIN herdr_role_host_replacement_authorizations AS authorization ON authorization.run_id = launch.run_id WHERE authorization.job_id = ? AND launch.queue_sequence >= 4",
        [.text(id)]
      ) == 0,
      try int(
        database,
        """
        SELECT COUNT(*)
        FROM herdr_role_host_replacement_authorizations AS authorization
        JOIN herdr_role_host_replacement_candidates AS candidate
          ON candidate.repository_id = authorization.repository_id
          AND candidate.job_id = authorization.job_id
          AND candidate.generation = authorization.generation
          AND candidate.run_id = authorization.run_id
          AND candidate.failed_launch_attempt_id = authorization.failed_launch_attempt_id
          AND candidate.predecessor_role_host_id = authorization.predecessor_role_host_id
        WHERE authorization.job_id = ?
        """,
        [.text(id)]
      ) == 1
    else { return false }
    let intentRows = try database.query(
      "SELECT * FROM herdr_topology_intents WHERE job_id = ? AND kind = 'replaceRoleHost' ORDER BY created_at, id",
      bindings: [.text(id)]
    )
    guard intentRows.count <= 1, let intent = intentRows.first else {
      return intentRows.isEmpty
    }
    let mutationID = try text(intent, "id")
    let generationValue = try integer(intent, "generation")
    let deviceValue = try integer(intent, "socket_device")
    let inodeValue = try integer(intent, "socket_inode")
    let ownerValue = try integer(intent, "socket_owner")
    let permissionsValue = try integer(intent, "socket_permissions")
    guard mutationID.wholeMatch(of: /^replace-[0-9a-f-]{36}$/) != nil,
      let generation = Int(exactly: generationValue), generation > 0,
      let device = UInt64(exactly: deviceValue),
      let inode = UInt64(exactly: inodeValue),
      let owner = UInt32(exactly: ownerValue),
      let permissions = UInt16(exactly: permissionsValue),
      try text(intent, "state") == HerdrTopologyStoredIntentState.prepared.rawValue,
      try optionalText(intent, "attribution_json") == nil,
      try int(
        database,
        """
        SELECT COUNT(*)
        FROM herdr_topology_intents AS intent
        JOIN herdr_role_host_replacement_authorizations AS authorization
          ON authorization.repository_id = intent.repository_id
          AND authorization.job_id = intent.job_id
          AND authorization.generation = intent.generation
          AND authorization.payload_sha256 = intent.payload_sha256
        JOIN herdr_role_host_replacement_candidates AS candidate
          ON candidate.repository_id = authorization.repository_id
          AND candidate.job_id = authorization.job_id
          AND candidate.generation = authorization.generation
          AND candidate.run_id = authorization.run_id
          AND candidate.failed_launch_attempt_id = authorization.failed_launch_attempt_id
          AND candidate.predecessor_role_host_id = authorization.predecessor_role_host_id
          AND candidate.socket_device = intent.socket_device
          AND candidate.socket_inode = intent.socket_inode
          AND candidate.socket_owner = intent.socket_owner
          AND candidate.socket_permissions = intent.socket_permissions
        WHERE authorization.job_id = ? AND intent.id = ?
          AND intent.kind = 'replaceRoleHost' AND intent.state = 'prepared'
          AND intent.attribution_json IS NULL
        """,
        [.text(id), .text(mutationID)]
      ) == 1
    else { return false }
    let reconstructed = HerdrTopologyMutationIntent(
      mutationID: mutationID,
      kind: .replaceRoleHost,
      repositoryID: try text(intent, "repository_id"),
      jobID: try text(intent, "job_id"),
      generation: generation,
      payloadSHA256: try text(intent, "payload_sha256"),
      socketIdentity: HerdrSocketIdentityRecord(
        HerdrSocketIdentity(
          device: device,
          inode: inode,
          owner: owner,
          permissions: permissions
        )
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return GitHubMarkerCodec.sha256(try encoder.encode(reconstructed))
      == (try text(intent, "intent_sha256"))
  }

  private static func one(
    _ database: isolated SQLiteStore, _ sql: String, _ bindings: [SQLiteValue] = []
  ) throws -> SQLiteRow {
    guard let row = try database.query(sql, bindings: bindings).first else {
      throw DurableJobStoreError.canaryEvidenceMismatch
    }
    return row
  }

  private static func int(
    _ database: isolated SQLiteStore, _ sql: String, _ bindings: [SQLiteValue] = []
  ) throws -> Int64? {
    try database.scalarInt(sql, bindings: bindings)
  }

  private static func replacementQ4Binding(
    _ row: SQLiteRow
  ) throws -> JobCanaryRoleHostReplacementQ4Binding {
    let binding = JobCanaryRoleHostReplacementQ4Binding(
      descriptorSHA256: try text(row, "q4_descriptor_sha256"),
      configurationSHA256: try text(row, "q4_configuration_sha256"),
      promptSHA256: try text(row, "q4_prompt_sha256"),
      workflowConfigurationSHA256: try text(
        row,
        "q4_workflow_configuration_sha256"
      ),
      priorLaunchDescriptorSHA256: try text(
        row,
        "q4_prior_launch_descriptor_sha256"
      ),
      priorLaunchConfigurationSHA256: try text(
        row,
        "q4_prior_launch_configuration_sha256"
      ),
      resourceTreeSHA256: try text(row, "q4_resource_tree_sha256")
    )
    do {
      try binding.validate()
    } catch {
      throw DurableJobStoreError.canaryRecoveryRequired
    }
    return binding
  }

  private static func text(_ row: SQLiteRow, _ name: String) throws -> String {
    guard case .text(let value)? = row[name] else { throw DurableJobStoreError.decode(name) }
    return value
  }

  private static func integer(_ row: SQLiteRow, _ name: String) throws -> Int64 {
    guard case .integer(let value)? = row[name] else { throw DurableJobStoreError.decode(name) }
    return value
  }

  private static func real(_ row: SQLiteRow, _ name: String) throws -> Double {
    switch row[name] {
    case .real(let value)?: return value
    case .integer(let value)?: return Double(value)
    default: throw DurableJobStoreError.decode(name)
    }
  }

  private static func optionalText(_ row: SQLiteRow, _ name: String) throws -> String? {
    switch row[name] {
    case .text(let value)?: return value
    case .null?: return nil
    default: throw DurableJobStoreError.decode(name)
    }
  }

  private static func optionalInteger(_ row: SQLiteRow, _ name: String) throws -> Int64? {
    switch row[name] {
    case .integer(let value)?: return value
    case .null?: return nil
    default: throw DurableJobStoreError.decode(name)
    }
  }

  private static func optionalReal(_ row: SQLiteRow, _ name: String) throws -> Double? {
    switch row[name] {
    case .real(let value)?: return value
    case .integer(let value)?: return Double(value)
    case .null?: return nil
    default: throw DurableJobStoreError.decode(name)
    }
  }

  private static func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
}
