import Foundation

public enum EngineProtocolVersion {
  public static let current = 11
}

public enum LifecycleProbeProtocolVersion {
  public static let current = 2
}

public enum EngineLifecycleState: String, Codable, Sendable {
  case onboarding
  case ready
  case quitting
  case blocked
}

public enum EngineOperationalStatus: String, Codable, Sendable {
  case active
  case paused
  case running
  case warning
}

public enum EngineCredentialState: String, Codable, Sendable {
  case missing
  case valid
  case unavailable
}

public struct EngineCredentialStatus: Codable, Equatable, Sendable {
  public let state: EngineCredentialState
  public let account: String?

  public init(state: EngineCredentialState, account: String?) {
    self.state = state
    self.account = account
  }

  public static let missing = EngineCredentialStatus(state: .missing, account: nil)
}

public enum EnginePiState: String, Codable, Sendable {
  case unchecked
  case ready
  case blocked
}

public struct EnginePiStatus: Codable, Equatable, Sendable {
  public let state: EnginePiState
  public let executablePath: String?
  public let version: String?
  public let policySHA256: String?
  public let issueCode: PiRuntimeIssueCode?
  public let summary: String?
  public let recovery: String?

  public init(
    state: EnginePiState,
    executablePath: String? = nil,
    version: String? = nil,
    policySHA256: String? = nil,
    issueCode: PiRuntimeIssueCode? = nil,
    summary: String? = nil,
    recovery: String? = nil
  ) {
    self.state = state
    self.executablePath = executablePath
    self.version = version
    self.policySHA256 = policySHA256
    self.issueCode = issueCode
    self.summary = summary
    self.recovery = recovery
  }

  public static let unchecked = EnginePiStatus(state: .unchecked)
}

public enum EngineHerdrState: String, Codable, Sendable {
  case unchecked
  case ready
  case blocked
}

public enum EngineHerdrIssueCode: String, CaseIterable, Codable, Sendable {
  case executableUnavailable
  case executableMismatch
  case policyInvalid
  case schemaMismatch
  case socketUnavailable
  case unsafeSocket
  case versionMismatch
  case protocolMismatch
  case capabilityMismatch
  case runtimeUnavailable
}

public struct EngineHerdrStatus: Codable, Equatable, Sendable {
  public let state: EngineHerdrState
  public let version: String?
  public let protocolVersion: Int?
  public let executableSHA256: String?
  public let schemaSHA256: String?
  public let policySHA256: String?
  public let issueCode: EngineHerdrIssueCode?
  public let summary: String?
  public let recovery: String?

  public init(
    state: EngineHerdrState,
    version: String? = nil,
    protocolVersion: Int? = nil,
    executableSHA256: String? = nil,
    schemaSHA256: String? = nil,
    policySHA256: String? = nil,
    issueCode: EngineHerdrIssueCode? = nil,
    summary: String? = nil,
    recovery: String? = nil
  ) {
    self.state = state
    self.version = version
    self.protocolVersion = protocolVersion
    self.executableSHA256 = executableSHA256
    self.schemaSHA256 = schemaSHA256
    self.policySHA256 = policySHA256
    self.issueCode = issueCode
    self.summary = summary
    self.recovery = recovery
  }

  public static let unchecked = EngineHerdrStatus(state: .unchecked)
}

public struct EngineRepositoryDraft: Codable, Equatable, Sendable {
  public let owner: String
  public let name: String
  public let reviewEnabled: Bool
  public let triageEnabled: Bool
  public let implementationEnabled: Bool

  public init(
    owner: String,
    name: String,
    reviewEnabled: Bool,
    triageEnabled: Bool,
    implementationEnabled: Bool
  ) {
    self.owner = owner
    self.name = name
    self.reviewEnabled = reviewEnabled
    self.triageEnabled = triageEnabled
    self.implementationEnabled = implementationEnabled
  }
}

public struct EngineActivity: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let summary: String
  public let occurredAt: Date

  public init(id: String, summary: String, occurredAt: Date) {
    self.id = id
    self.summary = summary
    self.occurredAt = occurredAt
  }
}

public struct EngineAmbiguousMutation: Codable, Equatable, Identifiable, Sendable {
  public let jobID: UUID
  public let repositoryID: UUID
  public let repositoryOwner: String
  public let repositoryName: String
  public let kind: JobKind
  public let objectNodeID: String
  public let objectNumber: Int?
  public let revisionKey: String
  public let evidenceDigest: String
  public let mutationGeneration: Int
  public let mutationID: String?

  public var id: UUID { jobID }

  public init(
    jobID: UUID,
    repositoryID: UUID,
    repositoryOwner: String,
    repositoryName: String,
    kind: JobKind,
    objectNodeID: String,
    objectNumber: Int?,
    revisionKey: String,
    evidenceDigest: String,
    mutationGeneration: Int,
    mutationID: String?
  ) {
    self.jobID = jobID
    self.repositoryID = repositoryID
    self.repositoryOwner = repositoryOwner
    self.repositoryName = repositoryName
    self.kind = kind
    self.objectNodeID = objectNodeID
    self.objectNumber = objectNumber
    self.revisionKey = revisionKey
    self.evidenceDigest = evidenceDigest
    self.mutationGeneration = mutationGeneration
    self.mutationID = mutationID
  }
}

public struct EngineDiagnostics: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let nonterminalJobCount: Int
  public let ambiguousMutationCount: Int
  public let coordinatorFailureCodes: [String]
  public let piIssueCode: PiRuntimeIssueCode?
  public let herdrIssueCode: EngineHerdrIssueCode?

  public init(
    schemaVersion: Int,
    nonterminalJobCount: Int,
    ambiguousMutationCount: Int,
    coordinatorFailureCodes: [String],
    piIssueCode: PiRuntimeIssueCode?,
    herdrIssueCode: EngineHerdrIssueCode?
  ) {
    self.schemaVersion = schemaVersion
    self.nonterminalJobCount = nonterminalJobCount
    self.ambiguousMutationCount = ambiguousMutationCount
    self.coordinatorFailureCodes = coordinatorFailureCodes
    self.piIssueCode = piIssueCode
    self.herdrIssueCode = herdrIssueCode
  }
}

public struct EngineOnboardingSnapshot: Codable, Equatable, Sendable {
  public let duplicateInstanceCheckPassed: Bool
  public let externalAutomationAcknowledged: Bool
  public let providerDisclosureAcknowledged: Bool
  public let pi: EnginePiStatus
  public let herdr: EngineHerdrStatus
  public let credential: EngineCredentialStatus
  public let repositoryCount: Int
  public let configuredProfileRoles: [ModelProfileRole]
  public let loginItemSelected: Bool
  public let loginItemStatus: LifecycleServiceStatus
  public let complete: Bool

  public init(
    duplicateInstanceCheckPassed: Bool,
    externalAutomationAcknowledged: Bool,
    providerDisclosureAcknowledged: Bool,
    pi: EnginePiStatus,
    herdr: EngineHerdrStatus,
    credential: EngineCredentialStatus,
    repositoryCount: Int,
    configuredProfileRoles: [ModelProfileRole],
    loginItemSelected: Bool,
    loginItemStatus: LifecycleServiceStatus,
    complete: Bool
  ) {
    self.duplicateInstanceCheckPassed = duplicateInstanceCheckPassed
    self.externalAutomationAcknowledged = externalAutomationAcknowledged
    self.providerDisclosureAcknowledged = providerDisclosureAcknowledged
    self.pi = pi
    self.herdr = herdr
    self.credential = credential
    self.repositoryCount = repositoryCount
    self.configuredProfileRoles = configuredProfileRoles
    self.loginItemSelected = loginItemSelected
    self.loginItemStatus = loginItemStatus
    self.complete = complete
  }
}

public struct EngineSettingsSnapshot: Codable, Equatable, Sendable {
  public let repositories: [RepositoryConfiguration]
  public let profiles: [ModelProfileConfiguration]
  public let maxConcurrency: Int
  public let loginItemSelected: Bool
  public let loginItemStatus: LifecycleServiceStatus
  public let credential: EngineCredentialStatus
  public let herdr: EngineHerdrStatus
  public let modelCatalog: PiModelCatalog

  public init(
    repositories: [RepositoryConfiguration],
    profiles: [ModelProfileConfiguration],
    maxConcurrency: Int,
    loginItemSelected: Bool,
    loginItemStatus: LifecycleServiceStatus,
    credential: EngineCredentialStatus,
    herdr: EngineHerdrStatus,
    modelCatalog: PiModelCatalog = .unavailable
  ) {
    self.repositories = repositories
    self.profiles = profiles
    self.maxConcurrency = maxConcurrency
    self.loginItemSelected = loginItemSelected
    self.loginItemStatus = loginItemStatus
    self.credential = credential
    self.herdr = herdr
    self.modelCatalog = modelCatalog
  }
}

public struct EngineUIState: Codable, Equatable, Sendable {
  public let revision: Int
  public let lifecycle: EngineLifecycleState
  public let operationalStatus: EngineOperationalStatus
  public let paused: Bool
  public let passRunning: Bool
  public let activities: [EngineActivity]
  public let ambiguousMutations: [EngineAmbiguousMutation]
  public let onboarding: EngineOnboardingSnapshot
  public let settings: EngineSettingsSnapshot
  public let diagnostics: EngineDiagnostics

  public init(
    revision: Int,
    lifecycle: EngineLifecycleState,
    operationalStatus: EngineOperationalStatus,
    paused: Bool,
    passRunning: Bool,
    activities: [EngineActivity],
    ambiguousMutations: [EngineAmbiguousMutation],
    onboarding: EngineOnboardingSnapshot,
    settings: EngineSettingsSnapshot,
    diagnostics: EngineDiagnostics
  ) {
    self.revision = revision
    self.lifecycle = lifecycle
    self.operationalStatus = operationalStatus
    self.paused = paused
    self.passRunning = passRunning
    self.activities = activities
    self.ambiguousMutations = ambiguousMutations
    self.onboarding = onboarding
    self.settings = settings
    self.diagnostics = diagnostics
  }
}

public struct EngineAmbiguousMutationEvidence: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let repositoryID: UUID
  public let kind: JobKind
  public let objectNodeID: String
  public let objectNumber: Int?
  public let revisionKey: String
  public let evidenceDigest: String
  public let mutationGeneration: Int
  public let mutationID: String?

  public init(_ mutation: EngineAmbiguousMutation) {
    jobID = mutation.jobID
    repositoryID = mutation.repositoryID
    kind = mutation.kind
    objectNodeID = mutation.objectNodeID
    objectNumber = mutation.objectNumber
    revisionKey = mutation.revisionKey
    evidenceDigest = mutation.evidenceDigest
    mutationGeneration = mutation.mutationGeneration
    mutationID = mutation.mutationID
  }
}

public enum EngineCommandKind: String, CaseIterable, Codable, Hashable, Sendable {
  case snapshot
  case refreshModelCatalog
  case acknowledgeExternalAutomation
  case acknowledgeProviderDisclosure
  case runPiPreflight
  case runHerdrPreflight
  case focusInHerdr
  case replaceCredential
  case deleteCredential
  case addRepository
  case updateRepository
  case removeRepository
  case setProfile
  case setMaxConcurrency
  case setPaused
  case pollNow
  case recheckAmbiguousMutation
  case authorizeRetry
  case previewJobMaintenance
  case applyJobMaintenance
  case previewJobCanary
  case executeJobCanary
  case previewJobCanaryRecovery
  case executeJobCanaryRecovery
  case previewJobCanaryPiRetry
  case executeJobCanaryPiRetry
  case previewJobCanaryRoleHostReplacement
  case executeJobCanaryRoleHostReplacement
  case previewJobCanaryGenerationRollover
  case executeJobCanaryGenerationRollover
  case previewJobCanaryGenerationRolloverQ4
  case executeJobCanaryGenerationRolloverQ4
  case setLoginEnabled
  case synchronizeLoginStatus
  case completeOnboarding
  case rollbackOnboarding
  case prepareForHandoff
  case prepareForQuit
}

extension EngineCommandKind {
  public static let productionHelperAllowedCommands: Set<Self> = [
    .snapshot,
    .refreshModelCatalog,
    .acknowledgeExternalAutomation,
    .acknowledgeProviderDisclosure,
    .runPiPreflight,
    .runHerdrPreflight,
    .focusInHerdr,
    .replaceCredential,
    .deleteCredential,
    .addRepository,
    .updateRepository,
    .removeRepository,
    .setProfile,
    .setMaxConcurrency,
    .setPaused,
    .pollNow,
    .recheckAmbiguousMutation,
    .authorizeRetry,
    .previewJobMaintenance,
    .applyJobMaintenance,
    .previewJobCanary,
    .executeJobCanary,
    .previewJobCanaryRecovery,
    .executeJobCanaryRecovery,
    .previewJobCanaryPiRetry,
    .executeJobCanaryPiRetry,
    .previewJobCanaryRoleHostReplacement,
    .executeJobCanaryRoleHostReplacement,
    .previewJobCanaryGenerationRollover,
    .executeJobCanaryGenerationRollover,
    .previewJobCanaryGenerationRolloverQ4,
    .executeJobCanaryGenerationRolloverQ4,
    .synchronizeLoginStatus,
    .completeOnboarding,
    .rollbackOnboarding,
    .prepareForQuit,
  ]
}

public enum EngineCommand: Codable, Equatable, Sendable {
  case snapshot
  case refreshModelCatalog
  case acknowledgeExternalAutomation(Bool)
  case acknowledgeProviderDisclosure(Bool)
  case runPiPreflight
  case runHerdrPreflight
  case focusInHerdr
  case replaceCredential(Data)
  case deleteCredential
  case addRepository(EngineRepositoryDraft)
  case updateRepository(RepositoryConfiguration)
  case removeRepository(UUID)
  case setProfile(ModelProfileConfiguration)
  case setMaxConcurrency(Int)
  case setPaused(Bool)
  case pollNow
  case recheckAmbiguousMutation(EngineAmbiguousMutationEvidence)
  case authorizeRetry(EngineAmbiguousMutationEvidence)
  case previewJobMaintenance(JobMaintenanceScope)
  case applyJobMaintenance(JobMaintenanceAuthorization)
  case previewJobCanary(JobCanaryScope)
  case executeJobCanary(JobCanaryAuthorization)
  case previewJobCanaryRecovery(JobCanaryAuthorization)
  case executeJobCanaryRecovery(JobCanaryRecoveryAuthorization)
  case previewJobCanaryPiRetry(JobCanaryRecoveryAuthorization)
  case executeJobCanaryPiRetry(JobCanaryPiRetryAuthorization)
  case previewJobCanaryRoleHostReplacement(JobCanaryRoleHostReplacementRequest)
  case executeJobCanaryRoleHostReplacement(JobCanaryRoleHostReplacementAuthorization)
  case previewJobCanaryGenerationRollover(JobCanaryGenerationRolloverRequest)
  case executeJobCanaryGenerationRollover(JobCanaryGenerationRolloverAuthorization)
  case previewJobCanaryGenerationRolloverQ4(JobCanaryGenerationRolloverQ4Request)
  case executeJobCanaryGenerationRolloverQ4(
    JobCanaryGenerationRolloverQ4ExecutionAuthorization
  )
  case setLoginEnabled(Bool)
  case synchronizeLoginStatus(selected: Bool, status: LifecycleServiceStatus)
  case completeOnboarding
  case rollbackOnboarding
  case prepareForHandoff
  case prepareForQuit

  public var kind: EngineCommandKind {
    switch self {
    case .snapshot: .snapshot
    case .refreshModelCatalog: .refreshModelCatalog
    case .acknowledgeExternalAutomation: .acknowledgeExternalAutomation
    case .acknowledgeProviderDisclosure: .acknowledgeProviderDisclosure
    case .runPiPreflight: .runPiPreflight
    case .runHerdrPreflight: .runHerdrPreflight
    case .focusInHerdr: .focusInHerdr
    case .replaceCredential: .replaceCredential
    case .deleteCredential: .deleteCredential
    case .addRepository: .addRepository
    case .updateRepository: .updateRepository
    case .removeRepository: .removeRepository
    case .setProfile: .setProfile
    case .setMaxConcurrency: .setMaxConcurrency
    case .setPaused: .setPaused
    case .pollNow: .pollNow
    case .recheckAmbiguousMutation: .recheckAmbiguousMutation
    case .authorizeRetry: .authorizeRetry
    case .previewJobMaintenance: .previewJobMaintenance
    case .applyJobMaintenance: .applyJobMaintenance
    case .previewJobCanary: .previewJobCanary
    case .executeJobCanary: .executeJobCanary
    case .previewJobCanaryRecovery: .previewJobCanaryRecovery
    case .executeJobCanaryRecovery: .executeJobCanaryRecovery
    case .previewJobCanaryPiRetry: .previewJobCanaryPiRetry
    case .executeJobCanaryPiRetry: .executeJobCanaryPiRetry
    case .previewJobCanaryRoleHostReplacement: .previewJobCanaryRoleHostReplacement
    case .executeJobCanaryRoleHostReplacement: .executeJobCanaryRoleHostReplacement
    case .previewJobCanaryGenerationRollover: .previewJobCanaryGenerationRollover
    case .executeJobCanaryGenerationRollover: .executeJobCanaryGenerationRollover
    case .previewJobCanaryGenerationRolloverQ4: .previewJobCanaryGenerationRolloverQ4
    case .executeJobCanaryGenerationRolloverQ4: .executeJobCanaryGenerationRolloverQ4
    case .setLoginEnabled: .setLoginEnabled
    case .synchronizeLoginStatus: .synchronizeLoginStatus
    case .completeOnboarding: .completeOnboarding
    case .rollbackOnboarding: .rollbackOnboarding
    case .prepareForHandoff: .prepareForHandoff
    case .prepareForQuit: .prepareForQuit
    }
  }

  public func validate() throws {
    switch self {
    case .replaceCredential(let token):
      guard (20...2_048).contains(token.count),
        token.allSatisfy({ (0x21...0x7E).contains($0) })
      else {
        throw EngineClientError(.invalidCommand)
      }
    case .addRepository(let draft):
      guard GitHubInputValidation.validOwner(draft.owner),
        GitHubInputValidation.validRepository(draft.name)
      else {
        throw EngineClientError(.invalidCommand)
      }
    case .updateRepository(let repository):
      guard GitHubInputValidation.validOwner(repository.owner),
        GitHubInputValidation.validRepository(repository.name),
        GitHubInputValidation.validBranch(repository.defaultBranch),
        !repository.nodeID.isEmpty
      else {
        throw EngineClientError(.invalidCommand)
      }
    case .setProfile(let profile):
      guard !profile.provider.isEmpty, !profile.model.isEmpty else {
        throw EngineClientError(.invalidCommand)
      }
    case .setMaxConcurrency(let value):
      guard (1...8).contains(value) else {
        throw EngineClientError(.invalidCommand)
      }
    case .recheckAmbiguousMutation(let evidence), .authorizeRetry(let evidence):
      guard evidence.mutationGeneration >= 0,
        !evidence.objectNodeID.isEmpty,
        !evidence.revisionKey.isEmpty,
        GitHubInputValidation.validSHA256(evidence.evidenceDigest)
      else {
        throw EngineClientError(.invalidCommand)
      }
    case .previewJobMaintenance(let scope):
      try scope.validate()
    case .applyJobMaintenance(let authorization):
      try authorization.validate()
    case .previewJobCanary(let scope):
      try scope.validate()
    case .executeJobCanary(let authorization),
      .previewJobCanaryRecovery(let authorization):
      try authorization.validate()
    case .executeJobCanaryRecovery(let authorization),
      .previewJobCanaryPiRetry(let authorization):
      try authorization.validate()
    case .executeJobCanaryPiRetry(let authorization):
      try authorization.validate()
    case .previewJobCanaryRoleHostReplacement(let request):
      try request.validate()
    case .executeJobCanaryRoleHostReplacement(let authorization):
      try authorization.validate()
    case .previewJobCanaryGenerationRollover(let request):
      try request.validate()
    case .executeJobCanaryGenerationRollover(let authorization):
      try authorization.validate()
    case .previewJobCanaryGenerationRolloverQ4(let request):
      try request.validate()
    case .executeJobCanaryGenerationRolloverQ4(let authorization):
      try authorization.validate()
    case .snapshot, .refreshModelCatalog, .acknowledgeExternalAutomation,
      .acknowledgeProviderDisclosure,
      .runPiPreflight, .runHerdrPreflight, .focusInHerdr, .deleteCredential,
      .removeRepository, .setPaused, .pollNow,
      .setLoginEnabled, .synchronizeLoginStatus, .completeOnboarding, .rollbackOnboarding,
      .prepareForHandoff, .prepareForQuit:
      break
    }
  }
}

public struct EngineCheckpointReceipt: Codable, Equatable, Sendable {
  public let checkpointID: UUID
  public let completedAt: Date
  public let nonterminalJobCount: Int
  public let ambiguousMutationCount: Int
  public let databaseCheckpointed: Bool

  public init(
    checkpointID: UUID,
    completedAt: Date,
    nonterminalJobCount: Int,
    ambiguousMutationCount: Int,
    databaseCheckpointed: Bool
  ) {
    self.checkpointID = checkpointID
    self.completedAt = completedAt
    self.nonterminalJobCount = nonterminalJobCount
    self.ambiguousMutationCount = ambiguousMutationCount
    self.databaseCheckpointed = databaseCheckpointed
  }
}

public struct EngineCommandResponse: Codable, Equatable, Sendable {
  public let command: EngineCommandKind
  public let state: EngineUIState
  public let checkpoint: EngineCheckpointReceipt?
  public let jobMaintenance: JobMaintenanceReport?
  public let jobCanary: JobCanaryReport?
  public let jobCanaryRecovery: JobCanaryRecoveryReport?
  public let jobCanaryPiRetry: JobCanaryPiRetryReport?
  public let jobCanaryRoleHostReplacement: JobCanaryRoleHostReplacementReport?
  public let jobCanaryGenerationRollover: JobCanaryGenerationRolloverReport?
  public let jobCanaryGenerationRolloverQ4: JobCanaryGenerationRolloverQ4Report?

  public init(
    command: EngineCommandKind,
    state: EngineUIState,
    checkpoint: EngineCheckpointReceipt? = nil,
    jobMaintenance: JobMaintenanceReport? = nil,
    jobCanary: JobCanaryReport? = nil,
    jobCanaryRecovery: JobCanaryRecoveryReport? = nil,
    jobCanaryPiRetry: JobCanaryPiRetryReport? = nil,
    jobCanaryRoleHostReplacement: JobCanaryRoleHostReplacementReport? = nil,
    jobCanaryGenerationRollover: JobCanaryGenerationRolloverReport? = nil,
    jobCanaryGenerationRolloverQ4: JobCanaryGenerationRolloverQ4Report? = nil
  ) {
    self.command = command
    self.state = state
    self.checkpoint = checkpoint
    self.jobMaintenance = jobMaintenance
    self.jobCanary = jobCanary
    self.jobCanaryRecovery = jobCanaryRecovery
    self.jobCanaryPiRetry = jobCanaryPiRetry
    self.jobCanaryRoleHostReplacement = jobCanaryRoleHostReplacement
    self.jobCanaryGenerationRollover = jobCanaryGenerationRollover
    self.jobCanaryGenerationRolloverQ4 = jobCanaryGenerationRolloverQ4
  }
}

public enum EngineClientErrorCode: String, CaseIterable, Codable, Sendable {
  case invalidCommand
  case invalidRequest
  case invalidResponse
  case unsupportedVersion
  case unavailable
  case timedOut
  case busy
  case staleEvidence
  case onboardingIncomplete
  case credentialRejected
  case credentialAccessFailed
  case credentialInUse
  case repositoryRejected
  case piBlocked
  case herdrBlocked
  case loginItemFailed
  case checkpointFailed
  case internalFailure
}

public struct EngineClientError: Error, Codable, Equatable, Sendable {
  public let code: EngineClientErrorCode

  public init(_ code: EngineClientErrorCode) {
    self.code = code
  }
}

public protocol EngineClient: Sendable {
  func send(_ command: EngineCommand) async throws -> EngineCommandResponse
}

extension EngineClient {
  public func snapshot() async throws -> EngineUIState {
    try await send(.snapshot).state
  }
}

public struct EngineXPCRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let requestID: String
  public let command: EngineCommand

  public init(
    protocolVersion: Int = EngineProtocolVersion.current,
    requestID: String = UUID().uuidString.lowercased(),
    command: EngineCommand
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.command = command
  }

  public func validate() throws {
    guard protocolVersion == EngineProtocolVersion.current else {
      throw EngineClientError(.unsupportedVersion)
    }
    guard let id = UUID(uuidString: requestID), id.uuidString.lowercased() == requestID else {
      throw EngineClientError(.invalidRequest)
    }
    try command.validate()
  }
}

public struct EngineXPCResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let requestID: String
  public let result: EngineCommandResponse?
  public let error: EngineClientError?

  public init(
    protocolVersion: Int = EngineProtocolVersion.current,
    requestID: String,
    result: EngineCommandResponse? = nil,
    error: EngineClientError? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.result = result
    self.error = error
  }

  public func validate(for request: EngineXPCRequest) throws -> EngineCommandResponse {
    guard requestID == request.requestID,
      (result == nil) != (error == nil)
    else {
      throw EngineClientError(.invalidResponse)
    }
    if let error {
      guard protocolVersion == request.protocolVersion || error.code == .unsupportedVersion else {
        throw EngineClientError(.invalidResponse)
      }
      throw error
    }
    guard protocolVersion == request.protocolVersion,
      let result,
      result.command == request.command.kind,
      result.state.onboarding.herdr == result.state.settings.herdr,
      result.state.diagnostics.herdrIssueCode == result.state.settings.herdr.issueCode
    else {
      throw EngineClientError(.invalidResponse)
    }
    try Self.validate(result.state.settings.herdr)
    try Self.validate(result.state.settings.modelCatalog)
    try Self.validateMaintenance(result, for: request.command)
    try Self.validateCanary(result, for: request.command)
    try Self.validateCanaryRecovery(result, for: request.command)
    try Self.validateCanaryPiRetry(result, for: request.command)
    try Self.validateCanaryRoleHostReplacement(result, for: request.command)
    try Self.validateCanaryGenerationRollover(result, for: request.command)
    return result
  }

  private static func validateMaintenance(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobMaintenance(let scope):
      guard result.state.paused,
        let report = result.jobMaintenance,
        report.scope == scope,
        report.candidateCount >= 0,
        report.appliedCount == 0,
        !report.replayed,
        GitHubInputValidation.validSHA256(report.evidenceSHA256),
        result.checkpoint == nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .applyJobMaintenance(let authorization):
      guard result.state.paused,
        let report = result.jobMaintenance,
        report.scope == authorization.scope,
        report.candidateCount == authorization.expectedCount,
        report.evidenceSHA256 == authorization.evidenceSHA256,
        report.appliedCount == authorization.expectedCount,
        result.checkpoint?.databaseCheckpointed == true
      else {
        throw EngineClientError(.invalidResponse)
      }
    default:
      guard result.jobMaintenance == nil else {
        throw EngineClientError(.invalidResponse)
      }
    }
  }

  private static func validateCanary(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobCanary(let scope):
      guard result.state.paused,
        let report = result.jobCanary,
        report.scope == scope,
        report.status == .preview,
        report.authorizationSHA256 == nil,
        !report.replayed,
        Self.validCanaryReport(report),
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanary(let authorization):
      guard result.state.paused,
        let report = result.jobCanary,
        report.scope == authorization.scope,
        report.previewEvidenceSHA256 == authorization.previewEvidenceSHA256,
        report.authorizationSHA256 == authorization.authorizationSHA256,
        report.status == .settled || report.status == .recoveryRequired,
        Self.validCanaryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryRecovery(let authorization):
      guard result.state.paused,
        let report = result.jobCanary,
        report.scope == authorization.canary.scope,
        report.previewEvidenceSHA256 == authorization.canary.previewEvidenceSHA256,
        report.authorizationSHA256 == authorization.canary.authorizationSHA256,
        report.status == .settled || report.status == .recoveryRequired,
        Self.validCanaryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryPiRetry(let authorization):
      guard result.state.paused,
        let report = result.jobCanary,
        report.scope == authorization.recovery.canary.scope,
        report.previewEvidenceSHA256 == authorization.recovery.canary.previewEvidenceSHA256,
        report.authorizationSHA256 == authorization.recovery.canary.authorizationSHA256,
        report.status == .settled || report.status == .recoveryRequired,
        Self.validCanaryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryRoleHostReplacement(let authorization):
      guard result.state.paused,
        let report = result.jobCanary,
        report.scope == authorization.request.retry.recovery.canary.scope,
        report.previewEvidenceSHA256
          == authorization.request.retry.recovery.canary.previewEvidenceSHA256,
        report.authorizationSHA256
          == authorization.request.retry.recovery.canary.authorizationSHA256,
        report.status == .settled || report.status == .recoveryRequired,
        Self.validCanaryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    default:
      guard result.jobCanary == nil else { throw EngineClientError(.invalidResponse) }
    }
  }

  private static func validateCanaryRecovery(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobCanaryRecovery(let canary):
      guard result.state.paused,
        let report = result.jobCanaryRecovery,
        report.jobID == canary.scope.jobID,
        report.canaryAuthorizationSHA256 == canary.authorizationSHA256,
        report.recoveryAuthorizationSHA256 == nil,
        report.status == .preview,
        !report.replayed,
        validCanaryRecoveryReport(report),
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryRecovery(let authorization):
      guard result.state.paused,
        let report = result.jobCanaryRecovery,
        report.jobID == authorization.canary.scope.jobID,
        report.canaryAuthorizationSHA256 == authorization.canary.authorizationSHA256,
        report.recoveryEvidenceSHA256 == authorization.recoveryEvidenceSHA256,
        report.recoveryAuthorizationSHA256 == authorization.authorizationSHA256,
        report.status == .recovered || report.status == .recoveryRequired,
        validCanaryRecoveryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    default:
      guard result.jobCanaryRecovery == nil else {
        throw EngineClientError(.invalidResponse)
      }
    }
  }

  private static func validateCanaryPiRetry(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobCanaryPiRetry(let recovery):
      guard result.state.paused,
        let report = result.jobCanaryPiRetry,
        report.jobID == recovery.canary.scope.jobID,
        report.canaryAuthorizationSHA256 == recovery.canary.authorizationSHA256,
        report.recoveryEvidenceSHA256 == recovery.recoveryEvidenceSHA256,
        report.retryAuthorizationSHA256 == nil,
        report.status == .preview,
        !report.replayed,
        validCanaryPiRetryReport(report),
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryPiRetry(let authorization):
      guard result.state.paused,
        let report = result.jobCanaryPiRetry,
        report.jobID == authorization.recovery.canary.scope.jobID,
        report.canaryAuthorizationSHA256 == authorization.recovery.canary.authorizationSHA256,
        report.recoveryEvidenceSHA256 == authorization.recovery.recoveryEvidenceSHA256,
        report.retryEvidenceSHA256 == authorization.retryEvidenceSHA256,
        report.retryAuthorizationSHA256 == authorization.authorizationSHA256,
        report.status == .authorized || report.status == .recoveryRequired,
        validCanaryPiRetryReport(report),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    default:
      guard result.jobCanaryPiRetry == nil else {
        throw EngineClientError(.invalidResponse)
      }
    }
  }

  private static func validateCanaryRoleHostReplacement(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobCanaryRoleHostReplacement(let request):
      guard result.state.paused,
        let report = result.jobCanaryRoleHostReplacement,
        report.jobID == request.retry.recovery.canary.scope.jobID,
        report.replacementRoleHostID == request.plannedReplacementRoleHostID,
        report.plannedLaunchAttemptID == request.plannedLaunchAttemptID,
        report.incidentAuditSHA256 == request.incidentAuditSHA256,
        GitHubInputValidation.validSHA256(report.replacementEvidenceSHA256),
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
      do {
        try report.validate()
      } catch {
        throw EngineClientError(.invalidResponse)
      }
      switch report.outcome {
      case .preview:
        guard report.replacementAuthorizationSHA256 == nil, !report.replayed else {
          throw EngineClientError(.invalidResponse)
        }
      default:
        let durableAuthorization = JobCanaryRoleHostReplacementAuthorization(
          request: request,
          replacementEvidenceSHA256: report.replacementEvidenceSHA256,
          q4Binding: report.q4Binding
        )
        guard report.outcome.isTerminal, report.replayed,
          report.replacementAuthorizationSHA256
            == durableAuthorization.authorizationSHA256
        else { throw EngineClientError(.invalidResponse) }
      }
    case .executeJobCanaryRoleHostReplacement(let authorization):
      guard result.state.paused,
        let report = result.jobCanaryRoleHostReplacement,
        report.jobID == authorization.request.retry.recovery.canary.scope.jobID,
        report.replacementRoleHostID
          == authorization.request.plannedReplacementRoleHostID,
        report.plannedLaunchAttemptID == authorization.request.plannedLaunchAttemptID,
        report.incidentAuditSHA256 == authorization.request.incidentAuditSHA256,
        report.replacementEvidenceSHA256 == authorization.replacementEvidenceSHA256,
        report.replacementAuthorizationSHA256 == authorization.authorizationSHA256,
        report.q4Binding == authorization.q4Binding,
        report.outcome.isTerminal,
        !report.replayed,
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
      do {
        try report.validate()
      } catch {
        throw EngineClientError(.invalidResponse)
      }
    default:
      guard result.jobCanaryRoleHostReplacement == nil else {
        throw EngineClientError(.invalidResponse)
      }
    }
  }

  private static func validateCanaryGenerationRollover(
    _ result: EngineCommandResponse,
    for command: EngineCommand
  ) throws {
    switch command {
    case .previewJobCanaryGenerationRollover(let request):
      guard result.state.paused,
        let report = result.jobCanaryGenerationRollover,
        report.authorization.request == request,
        report.status == .preview, !report.replayed,
        result.jobCanaryGenerationRolloverQ4 == nil,
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryGenerationRollover(let authorization):
      guard result.state.paused,
        let report = result.jobCanaryGenerationRollover,
        report.authorization == authorization,
        report.status == .topologyActivated,
        result.jobCanaryGenerationRolloverQ4 == nil,
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    case .previewJobCanaryGenerationRolloverQ4(let request):
      guard result.state.paused,
        result.jobCanaryGenerationRollover == nil,
        let report = result.jobCanaryGenerationRolloverQ4,
        report.authorization.rolloverAuthorizationSHA256
          == request.rolloverAuthorization.authorizationSHA256,
        report.authorization.plannedLaunchAttemptID == request.plannedLaunchAttemptID,
        report.status == .preview, !report.replayed,
        result.checkpoint == nil
      else { throw EngineClientError(.invalidResponse) }
    case .executeJobCanaryGenerationRolloverQ4(let authorization):
      guard result.state.paused,
        result.jobCanaryGenerationRollover == nil,
        let report = result.jobCanaryGenerationRolloverQ4,
        report.authorization == authorization.q4,
        [.settled, .failed, .outcomeAmbiguous].contains(report.status),
        result.checkpoint?.databaseCheckpointed == true
      else { throw EngineClientError(.invalidResponse) }
    default:
      guard result.jobCanaryGenerationRollover == nil,
        result.jobCanaryGenerationRolloverQ4 == nil
      else { throw EngineClientError(.invalidResponse) }
    }
  }

  private static func validCanaryPiRetryReport(_ report: JobCanaryPiRetryReport) -> Bool {
    let authorityEvidenceValid: Bool
    switch report.agentAuthorityProtocol {
    case nil:
      authorityEvidenceValid =
        report.failedPrimeIntentID == nil
        && report.failedPrimeIntentSHA256 == nil
        && report.failedPrimePayloadSHA256 == nil
        && report.stalePaneRevision == nil
        && report.stalePaneHadTokens == nil
        && report.stalePaneTokensSHA256 == nil
    case JobCanaryPiRetryEvidence.legacyAgentPrimeProtocolV1:
      authorityEvidenceValid =
        report.failedPrimeIntentID == nil
        && report.failedPrimeIntentSHA256 == nil
        && report.failedPrimePayloadSHA256 == nil
        && report.stalePaneRevision == nil
        && report.stalePaneHadTokens == nil
        && report.stalePaneTokensSHA256 == nil
    case JobCanaryPiRetryEvidence.agentAuthorityResetProtocolV1:
      authorityEvidenceValid =
        report.failedPrimeIntentID?.wholeMatch(of: /^prime-[0-9a-f-]{36}$/) != nil
        && report.failedPrimeIntentSHA256.map(GitHubInputValidation.validSHA256) == true
        && report.failedPrimePayloadSHA256.map(GitHubInputValidation.validSHA256) == true
        && report.stalePaneRevision.map({ $0 > 0 }) == true
        && report.stalePaneHadTokens != nil
        && report.stalePaneTokensSHA256.map(GitHubInputValidation.validSHA256) == true
    default:
      authorityEvidenceValid = false
    }
    return authorityEvidenceValid
      && GitHubInputValidation.validSHA256(report.canaryAuthorizationSHA256)
      && GitHubInputValidation.validSHA256(report.recoveryEvidenceSHA256)
      && GitHubInputValidation.validSHA256(report.retryEvidenceSHA256)
      && (report.retryAuthorizationSHA256.map(GitHubInputValidation.validSHA256) ?? true)
      && report.runID.wholeMatch(of: /^run-[0-9a-f-]{36}$/) != nil
      && report.failedLaunchAttemptID.wholeMatch(of: /^launch-[0-9a-f-]{36}$/) != nil
      && report.provider.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,63}$/) != nil
      && !report.model.isEmpty && report.model.utf8.count <= 256
      && ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        .contains(report.thinking)
      && report.credentialType == "oauth"
      && report.credentialExpiresAtMilliseconds > 0
  }

  private static func validCanaryRecoveryReport(_ report: JobCanaryRecoveryReport) -> Bool {
    report.roles == [.architecture, .security, .test, .synthesis]
      && GitHubInputValidation.validOwner(report.repositoryOwner)
      && GitHubInputValidation.validRepository(report.repositoryName)
      && report.objectNumber > 0
      && !report.revisionKey.isEmpty && report.revisionKey.utf8.count <= 1_024
      && !report.provider.isEmpty && report.provider.utf8.count <= 128
      && !report.model.isEmpty && report.model.utf8.count <= 256
      && !report.thinking.isEmpty && report.thinking.utf8.count <= 64
      && GitHubInputValidation.validSHA256(report.resourceTreeSHA256)
      && GitHubInputValidation.validSHA256(report.canaryAuthorizationSHA256)
      && GitHubInputValidation.validSHA256(report.recoveryEvidenceSHA256)
      && (report.recoveryAuthorizationSHA256.map(GitHubInputValidation.validSHA256) ?? true)
      && GitHubInputValidation.validSHA256(report.unknownIntentSHA256)
      && GitHubInputValidation.validSHA256(report.unknownPayloadSHA256)
      && GitHubInputValidation.validSHA256(report.layoutSHA256)
      && GitHubInputValidation.validSHA256(report.hostExecutableSHA256)
      && report.unknownIntentID.wholeMatch(of: /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$/) != nil
  }

  private static func validCanaryReport(_ report: JobCanaryReport) -> Bool {
    report.piRoles == [.architecture, .security, .test, .synthesis]
      && GitHubInputValidation.validSHA256(report.previewEvidenceSHA256)
      && GitHubInputValidation.validSHA256(report.resourceTreeSHA256)
      && (report.authorizationSHA256.map(GitHubInputValidation.validSHA256) ?? true)
      && GitHubInputValidation.validOwner(report.repositoryOwner)
      && GitHubInputValidation.validRepository(report.repositoryName)
      && report.objectNumber > 0
      && !report.revisionKey.isEmpty && report.revisionKey.utf8.count <= 1_024
      && !report.provider.isEmpty && report.provider.utf8.count <= 128
      && !report.model.isEmpty && report.model.utf8.count <= 256
      && !report.thinking.isEmpty && report.thinking.utf8.count <= 64
  }

  private static func validate(_ status: EngineHerdrStatus) throws {
    let validSHA256: (String?) -> Bool = { value in
      guard let value else { return false }
      return value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    }
    switch status.state {
    case .unchecked:
      guard status.version == nil, status.protocolVersion == nil,
        status.executableSHA256 == nil, status.schemaSHA256 == nil,
        status.policySHA256 == nil, status.issueCode == nil,
        status.summary == nil, status.recovery == nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .ready:
      guard status.version == HerdrCompatibilityManifest.approved.version,
        status.protocolVersion == HerdrCompatibilityManifest.approved.protocolVersion,
        validSHA256(status.executableSHA256), validSHA256(status.schemaSHA256),
        validSHA256(status.policySHA256), status.issueCode == nil,
        status.summary == nil, status.recovery == nil
      else {
        throw EngineClientError(.invalidResponse)
      }
    case .blocked:
      guard status.version == nil, status.protocolVersion == nil,
        status.executableSHA256 == nil, status.schemaSHA256 == nil,
        status.policySHA256 == nil, status.issueCode != nil,
        validDiagnostic(status.summary), validDiagnostic(status.recovery)
      else {
        throw EngineClientError(.invalidResponse)
      }
    }
  }

  private static func validate(_ catalog: PiModelCatalog) throws {
    do {
      let data = try JSONEncoder().encode(catalog)
      guard try PiModelCatalogDecoder.decode(data) == catalog else {
        throw EngineClientError(.invalidResponse)
      }
    } catch let error as EngineClientError {
      throw error
    } catch {
      throw EngineClientError(.invalidResponse)
    }
  }

  private static func validDiagnostic(_ value: String?) -> Bool {
    guard let value, (1...1_024).contains(value.utf8.count) else { return false }
    return !value.unicodeScalars.contains { $0.value == 0 }
  }
}
