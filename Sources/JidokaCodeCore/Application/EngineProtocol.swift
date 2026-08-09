import Foundation

public enum EngineProtocolVersion {
  public static let current = 1
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

  public init(
    schemaVersion: Int,
    nonterminalJobCount: Int,
    ambiguousMutationCount: Int,
    coordinatorFailureCodes: [String],
    piIssueCode: PiRuntimeIssueCode?
  ) {
    self.schemaVersion = schemaVersion
    self.nonterminalJobCount = nonterminalJobCount
    self.ambiguousMutationCount = ambiguousMutationCount
    self.coordinatorFailureCodes = coordinatorFailureCodes
    self.piIssueCode = piIssueCode
  }
}

public struct EngineOnboardingSnapshot: Codable, Equatable, Sendable {
  public let duplicateInstanceCheckPassed: Bool
  public let externalAutomationAcknowledged: Bool
  public let providerDisclosureAcknowledged: Bool
  public let pi: EnginePiStatus
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

  public init(
    repositories: [RepositoryConfiguration],
    profiles: [ModelProfileConfiguration],
    maxConcurrency: Int,
    loginItemSelected: Bool,
    loginItemStatus: LifecycleServiceStatus,
    credential: EngineCredentialStatus
  ) {
    self.repositories = repositories
    self.profiles = profiles
    self.maxConcurrency = maxConcurrency
    self.loginItemSelected = loginItemSelected
    self.loginItemStatus = loginItemStatus
    self.credential = credential
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
  case acknowledgeExternalAutomation
  case acknowledgeProviderDisclosure
  case runPiPreflight
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
  case setLoginEnabled
  case synchronizeLoginStatus
  case completeOnboarding
  case rollbackOnboarding
  case prepareForHandoff
  case prepareForQuit
}

public enum EngineCommand: Codable, Equatable, Sendable {
  case snapshot
  case acknowledgeExternalAutomation(Bool)
  case acknowledgeProviderDisclosure(Bool)
  case runPiPreflight
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
  case setLoginEnabled(Bool)
  case synchronizeLoginStatus(selected: Bool, status: LifecycleServiceStatus)
  case completeOnboarding
  case rollbackOnboarding
  case prepareForHandoff
  case prepareForQuit

  public var kind: EngineCommandKind {
    switch self {
    case .snapshot: .snapshot
    case .acknowledgeExternalAutomation: .acknowledgeExternalAutomation
    case .acknowledgeProviderDisclosure: .acknowledgeProviderDisclosure
    case .runPiPreflight: .runPiPreflight
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
    case .snapshot, .acknowledgeExternalAutomation, .acknowledgeProviderDisclosure,
      .runPiPreflight, .deleteCredential, .removeRepository, .setPaused, .pollNow,
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

  public init(
    command: EngineCommandKind,
    state: EngineUIState,
    checkpoint: EngineCheckpointReceipt? = nil
  ) {
    self.command = command
    self.state = state
    self.checkpoint = checkpoint
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
  case credentialInUse
  case repositoryRejected
  case piBlocked
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
      result.command == request.command.kind
    else {
      throw EngineClientError(.invalidResponse)
    }
    return result
  }
}
