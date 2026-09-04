import CryptoKit
import Foundation

public enum RolloutPolicyVersion: Int, Codable, CaseIterable, Sendable {
  case v1 = 1
}

public enum RolloutScopeMode: String, Codable, CaseIterable, Sendable {
  case exactObject
  case finiteWindow
}

public enum RolloutWorkflowStage: String, Codable, CaseIterable, Sendable {
  case prReview
  case issueTriage
  case implementationPlan
  case implementationExecute
  case generatedPRReview

  public var providerSessionLimit: Int {
    switch self {
    case .prReview, .generatedPRReview: 4
    case .issueTriage: 1
    case .implementationPlan, .implementationExecute: 15
    }
  }

  public func accepts(jobKind: JobKind) -> Bool {
    switch self {
    case .prReview, .generatedPRReview:
      jobKind == .prReview
    case .issueTriage:
      jobKind == .issueTriage
    case .implementationPlan, .implementationExecute:
      jobKind == .issueImplementation || jobKind == .complexPlan
    }
  }
}

public enum RolloutAuthorizationState: String, Codable, CaseIterable, Sendable {
  case active
  case draining
  case recoveryRequired
  case settled
  case revoked
  case expired
  case failed

  public var isOpenLane: Bool {
    self == .active || self == .draining || self == .recoveryRequired
  }
}

public enum RolloutSchedulerAdmission: Equatable, Sendable {
  case active(RolloutScopeMode)
  case readbackOnly
  case denied
}

public enum RolloutAuthorizationEventKind: String, Codable, CaseIterable, Sendable {
  case activated
  case recoveryActivated
  case jobBound
  case effectReserved
  case sendStarted
  case effectObserved
  case drainStarted
  case recoveryRequired
  case settled
  case revoked
  case expired
  case failed
}

public enum RolloutEffectKind: String, Codable, CaseIterable, Hashable, Sendable {
  case githubRead
  case gitRemoteRead
  case providerSession
  case approvedCommand
  case markerBatch
  case labelWrite
  case branchCreate
  case pullRequestCreate
  case githubMutation
}

public enum RolloutEffectReservationState: String, Codable, CaseIterable, Sendable {
  case reserved
  case sendStarted
  case observationRequired
  case attributed
  case settled
}

public enum RolloutAuthorityError: Error, Equatable, Sendable {
  case invalidIdentifier(String)
  case invalidDigest(String)
  case invalidReleaseIdentity
  case invalidRepositoryIdentity
  case invalidObjectSelector
  case invalidFiniteWindow
  case invalidBudget
  case invalidLabelDefinition
  case invalidCommandBinding
  case invalidJobBinding
  case invalidEffectEnvelope
  case invalidEffectCost
  case invalidCanonicalJSON
  case previewExpired
  case previewDigestMismatch
  case previewDrift
  case finitePromotionRequired
  case authorizationNotFound(String)
  case authorizationNotActive(String)
  case authorizationCollision
  case jobNotFound(String)
  case jobBindingMismatch
  case budgetExceeded(RolloutEffectKind)
  case effectAdmissionClosed
  case effectIdentityMismatch
  case readbackNotAllowed
  case inventoryLimitExceeded(String)
  case invalidStateTransition
  case decode(String)
}

public struct RolloutReleaseIdentity: Codable, Equatable, Sendable {
  public let sourceCommit: String
  public let sourceTree: String
  public let bundleVersion: String
  public let bundleBuild: Int
  public let applicationSHA256: String
  public let helperSHA256: String
  public let herdrHostSHA256: String
  public let schemaVersion: Int
  public let engineProtocolVersion: Int
  public let runtimeManifestSHA256: String
  public let runtimeTreeSHA256: String
  public let modelProfilesSHA256: String
  public let workflowResourcesSHA256: String
  public let githubAccount: String
  public let githubAuthorID: Int64
  public let repositoryConfigurationSHA256: String
  public let maxConcurrency: Int

  public init(
    sourceCommit: String,
    sourceTree: String,
    bundleVersion: String,
    bundleBuild: Int,
    applicationSHA256: String,
    helperSHA256: String,
    herdrHostSHA256: String,
    schemaVersion: Int,
    engineProtocolVersion: Int,
    runtimeManifestSHA256: String,
    runtimeTreeSHA256: String,
    modelProfilesSHA256: String,
    workflowResourcesSHA256: String,
    githubAccount: String,
    githubAuthorID: Int64,
    repositoryConfigurationSHA256: String,
    maxConcurrency: Int
  ) {
    self.sourceCommit = sourceCommit
    self.sourceTree = sourceTree
    self.bundleVersion = bundleVersion
    self.bundleBuild = bundleBuild
    self.applicationSHA256 = applicationSHA256
    self.helperSHA256 = helperSHA256
    self.herdrHostSHA256 = herdrHostSHA256
    self.schemaVersion = schemaVersion
    self.engineProtocolVersion = engineProtocolVersion
    self.runtimeManifestSHA256 = runtimeManifestSHA256
    self.runtimeTreeSHA256 = runtimeTreeSHA256
    self.modelProfilesSHA256 = modelProfilesSHA256
    self.workflowResourcesSHA256 = workflowResourcesSHA256
    self.githubAccount = githubAccount
    self.githubAuthorID = githubAuthorID
    self.repositoryConfigurationSHA256 = repositoryConfigurationSHA256
    self.maxConcurrency = maxConcurrency
  }
}

public struct RolloutRepositoryIdentity: Codable, Equatable, Sendable {
  public let id: String
  public let nodeID: String
  public let owner: String
  public let name: String
  public let defaultBranch: String
  public let enabled: Bool
  public let reviewEnabled: Bool
  public let triageEnabled: Bool
  public let implementationEnabled: Bool

  public init(
    id: UUID,
    nodeID: String,
    owner: String,
    name: String,
    defaultBranch: String,
    enabled: Bool,
    reviewEnabled: Bool,
    triageEnabled: Bool,
    implementationEnabled: Bool
  ) {
    self.id = id.uuidString.lowercased()
    self.nodeID = nodeID
    self.owner = owner
    self.name = name
    self.defaultBranch = defaultBranch
    self.enabled = enabled
    self.reviewEnabled = reviewEnabled
    self.triageEnabled = triageEnabled
    self.implementationEnabled = implementationEnabled
  }
}

public struct RolloutObjectSelector: Codable, Equatable, Sendable {
  public let nodeID: String
  public let number: Int
  public let revisionKey: String
  public let canonicalInputSHA256: String
  public let headSHA: String?
  public let baseSHA: String?
  public let planSHA256: String?
  public let narrativeSHA256: String?
  public let labelStateSHA256: String?
  public let currentStep: String

  public init(
    nodeID: String,
    number: Int,
    revisionKey: String,
    canonicalInputSHA256: String,
    headSHA: String? = nil,
    baseSHA: String? = nil,
    planSHA256: String? = nil,
    narrativeSHA256: String? = nil,
    labelStateSHA256: String? = nil,
    currentStep: String
  ) {
    self.nodeID = nodeID
    self.number = number
    self.revisionKey = revisionKey
    self.canonicalInputSHA256 = canonicalInputSHA256
    self.headSHA = headSHA
    self.baseSHA = baseSHA
    self.planSHA256 = planSHA256
    self.narrativeSHA256 = narrativeSHA256
    self.labelStateSHA256 = labelStateSHA256
    self.currentStep = currentStep
  }
}

public struct RolloutWindowCandidate: Codable, Equatable, Sendable {
  public let ordinal: Int
  public let nodeID: String
  public let number: Int
  public let revisionKey: String
  public let canonicalInputSHA256: String

  public init(
    ordinal: Int,
    nodeID: String,
    number: Int,
    revisionKey: String,
    canonicalInputSHA256: String
  ) {
    self.ordinal = ordinal
    self.nodeID = nodeID
    self.number = number
    self.revisionKey = revisionKey
    self.canonicalInputSHA256 = canonicalInputSHA256
  }
}

public struct RolloutFiniteWindowSelector: Codable, Equatable, Sendable {
  public let predicateVersion: Int
  public let maximumJobs: Int
  public let expiresAtMilliseconds: Int64
  public let allowsFutureObjects: Bool
  public let observedObjectNumberUpperBound: Int
  public let maximumFutureObjectNumber: Int
  public let candidates: [RolloutWindowCandidate]

  public init(
    predicateVersion: Int = 1,
    maximumJobs: Int,
    expiresAtMilliseconds: Int64,
    allowsFutureObjects: Bool = false,
    observedObjectNumberUpperBound: Int = 0,
    maximumFutureObjectNumber: Int = 0,
    candidates: [RolloutWindowCandidate]
  ) {
    self.predicateVersion = predicateVersion
    self.maximumJobs = maximumJobs
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.allowsFutureObjects = allowsFutureObjects
    self.observedObjectNumberUpperBound = observedObjectNumberUpperBound
    self.maximumFutureObjectNumber = maximumFutureObjectNumber
    self.candidates = candidates
  }
}

public struct RolloutScope: Codable, Equatable, Sendable {
  public let mode: RolloutScopeMode
  public let stage: RolloutWorkflowStage
  public let repository: RolloutRepositoryIdentity
  public let object: RolloutObjectSelector?
  public let finiteWindow: RolloutFiniteWindowSelector?

  public init(
    mode: RolloutScopeMode,
    stage: RolloutWorkflowStage,
    repository: RolloutRepositoryIdentity,
    object: RolloutObjectSelector?,
    finiteWindow: RolloutFiniteWindowSelector?
  ) {
    self.mode = mode
    self.stage = stage
    self.repository = repository
    self.object = object
    self.finiteWindow = finiteWindow
  }
}

public struct RolloutInventory: Codable, Equatable, Sendable {
  public let queueSHA256: String
  public let recoverySHA256: String
  public let mutationIntentSHA256: String
  public let queueItemCount: Int
  public let recoveryItemCount: Int
  public let mutationItemCount: Int
  public let outsideScopeQueueSHA256: String
  public let outsideScopeRecoverySHA256: String
  public let outsideScopeMutationIntentSHA256: String
  public let outsideScopeQueueItemCount: Int
  public let outsideScopeRecoveryItemCount: Int
  public let outsideScopeMutationItemCount: Int

  public init(
    queueSHA256: String,
    recoverySHA256: String,
    mutationIntentSHA256: String,
    queueItemCount: Int,
    recoveryItemCount: Int,
    mutationItemCount: Int,
    outsideScopeQueueSHA256: String,
    outsideScopeRecoverySHA256: String,
    outsideScopeMutationIntentSHA256: String,
    outsideScopeQueueItemCount: Int,
    outsideScopeRecoveryItemCount: Int,
    outsideScopeMutationItemCount: Int
  ) {
    self.queueSHA256 = queueSHA256
    self.recoverySHA256 = recoverySHA256
    self.mutationIntentSHA256 = mutationIntentSHA256
    self.queueItemCount = queueItemCount
    self.recoveryItemCount = recoveryItemCount
    self.mutationItemCount = mutationItemCount
    self.outsideScopeQueueSHA256 = outsideScopeQueueSHA256
    self.outsideScopeRecoverySHA256 = outsideScopeRecoverySHA256
    self.outsideScopeMutationIntentSHA256 = outsideScopeMutationIntentSHA256
    self.outsideScopeQueueItemCount = outsideScopeQueueItemCount
    self.outsideScopeRecoveryItemCount = outsideScopeRecoveryItemCount
    self.outsideScopeMutationItemCount = outsideScopeMutationItemCount
  }

  func hasMatchingOutsideScope(_ other: RolloutInventory) -> Bool {
    outsideScopeQueueSHA256 == other.outsideScopeQueueSHA256
      && outsideScopeRecoverySHA256 == other.outsideScopeRecoverySHA256
      && outsideScopeMutationIntentSHA256 == other.outsideScopeMutationIntentSHA256
      && outsideScopeQueueItemCount == other.outsideScopeQueueItemCount
      && outsideScopeRecoveryItemCount == other.outsideScopeRecoveryItemCount
      && outsideScopeMutationItemCount == other.outsideScopeMutationItemCount
  }
}

public struct RolloutLabelDefinition: Codable, Equatable, Sendable {
  public let name: String
  public let color: String
  public let description: String

  public init(name: String, color: String, description: String) {
    self.name = name
    self.color = color
    self.description = description
  }
}

public struct RolloutCommandBinding: Codable, Equatable, Sendable {
  public let ordinal: Int
  public let commandID: String
  public let definitionSHA256: String
  public let frozenPlanSHA256: String
  public let workspaceHeadSHA: String

  public init(
    ordinal: Int,
    commandID: String,
    definitionSHA256: String,
    frozenPlanSHA256: String,
    workspaceHeadSHA: String
  ) {
    self.ordinal = ordinal
    self.commandID = commandID
    self.definitionSHA256 = definitionSHA256
    self.frozenPlanSHA256 = frozenPlanSHA256
    self.workspaceHeadSHA = workspaceHeadSHA
  }
}

public struct RolloutBudgets: Codable, Equatable, Sendable {
  public let jobs: Int
  public let githubReadRequests: Int
  public let githubReadPages: Int
  public let githubReadBytes: Int64
  public let gitRemoteReads: Int
  public let providerSessions: Int
  public let approvedCommands: Int
  public let markerParts: Int
  public let labelWrites: Int
  public let branchCreates: Int
  public let pullRequestCreates: Int
  public let githubSends: Int
  public let gitSends: Int

  public init(
    jobs: Int,
    githubReadRequests: Int,
    githubReadPages: Int,
    githubReadBytes: Int64,
    gitRemoteReads: Int,
    providerSessions: Int,
    approvedCommands: Int,
    markerParts: Int,
    labelWrites: Int,
    branchCreates: Int,
    pullRequestCreates: Int,
    githubSends: Int,
    gitSends: Int
  ) {
    self.jobs = jobs
    self.githubReadRequests = githubReadRequests
    self.githubReadPages = githubReadPages
    self.githubReadBytes = githubReadBytes
    self.gitRemoteReads = gitRemoteReads
    self.providerSessions = providerSessions
    self.approvedCommands = approvedCommands
    self.markerParts = markerParts
    self.labelWrites = labelWrites
    self.branchCreates = branchCreates
    self.pullRequestCreates = pullRequestCreates
    self.githubSends = githubSends
    self.gitSends = gitSends
  }

  public static let zero = RolloutBudgets(
    jobs: 0,
    githubReadRequests: 0,
    githubReadPages: 0,
    githubReadBytes: 0,
    gitRemoteReads: 0,
    providerSessions: 0,
    approvedCommands: 0,
    markerParts: 0,
    labelWrites: 0,
    branchCreates: 0,
    pullRequestCreates: 0,
    githubSends: 0,
    gitSends: 0
  )

  public func subtracting(_ usage: RolloutBudgets) -> RolloutBudgets {
    RolloutBudgets(
      jobs: max(0, jobs - usage.jobs),
      githubReadRequests: max(0, githubReadRequests - usage.githubReadRequests),
      githubReadPages: max(0, githubReadPages - usage.githubReadPages),
      githubReadBytes: max(0, githubReadBytes - usage.githubReadBytes),
      gitRemoteReads: max(0, gitRemoteReads - usage.gitRemoteReads),
      providerSessions: max(0, providerSessions - usage.providerSessions),
      approvedCommands: max(0, approvedCommands - usage.approvedCommands),
      markerParts: max(0, markerParts - usage.markerParts),
      labelWrites: max(0, labelWrites - usage.labelWrites),
      branchCreates: max(0, branchCreates - usage.branchCreates),
      pullRequestCreates: max(0, pullRequestCreates - usage.pullRequestCreates),
      githubSends: max(0, githubSends - usage.githubSends),
      gitSends: max(0, gitSends - usage.gitSends)
    )
  }
}

public struct RolloutJobBinding: Codable, Equatable, Sendable {
  public let jobID: String
  public let jobKind: JobKind
  public let objectNumber: Int
  public let contractVersion: String
  public let priority: JobPriority
  public let firstStep: JobStepKind
  public let currentStep: String

  public init(
    jobID: UUID,
    jobKind: JobKind,
    objectNumber: Int,
    contractVersion: String,
    priority: JobPriority,
    firstStep: JobStepKind,
    currentStep: String
  ) {
    self.jobID = jobID.uuidString.lowercased()
    self.jobKind = jobKind
    self.objectNumber = objectNumber
    self.contractVersion = contractVersion
    self.priority = priority
    self.firstStep = firstStep
    self.currentStep = currentStep
  }
}

public struct RolloutEffectAllowance: Codable, Equatable, Sendable {
  public let kind: RolloutEffectKind
  public let maximumCount: Int64

  public init(kind: RolloutEffectKind, maximumCount: Int64) {
    self.kind = kind
    self.maximumCount = maximumCount
  }
}

public struct RolloutEffectEnvelope: Codable, Equatable, Sendable {
  public let stage: RolloutWorkflowStage
  public let currentStep: String
  public let allowances: [RolloutEffectAllowance]

  public init(
    stage: RolloutWorkflowStage,
    currentStep: String,
    allowances: [RolloutEffectAllowance]
  ) {
    self.stage = stage
    self.currentStep = currentStep
    self.allowances = allowances
  }
}

public struct RolloutPreviewInput: Codable, Equatable, Sendable {
  public let policyVersion: RolloutPolicyVersion
  public let releaseIdentity: RolloutReleaseIdentity
  public let scope: RolloutScope
  public let budgets: RolloutBudgets
  public let inventory: RolloutInventory
  public let missingLabels: [RolloutLabelDefinition]
  public let commands: [RolloutCommandBinding]
  public let jobBinding: RolloutJobBinding?
  public let createdAtMilliseconds: Int64
  public let expiresAtMilliseconds: Int64

  public init(
    policyVersion: RolloutPolicyVersion = .v1,
    releaseIdentity: RolloutReleaseIdentity,
    scope: RolloutScope,
    budgets: RolloutBudgets,
    inventory: RolloutInventory,
    missingLabels: [RolloutLabelDefinition],
    commands: [RolloutCommandBinding],
    jobBinding: RolloutJobBinding?,
    createdAtMilliseconds: Int64,
    expiresAtMilliseconds: Int64
  ) {
    self.policyVersion = policyVersion
    self.releaseIdentity = releaseIdentity
    self.scope = scope
    self.budgets = budgets
    self.inventory = inventory
    self.missingLabels = missingLabels
    self.commands = commands
    self.jobBinding = jobBinding
    self.createdAtMilliseconds = createdAtMilliseconds
    self.expiresAtMilliseconds = expiresAtMilliseconds
  }
}

public struct RolloutPreviewPayload: Codable, Equatable, Sendable {
  public let policyVersion: RolloutPolicyVersion
  public let releaseIdentity: RolloutReleaseIdentity
  public let scope: RolloutScope
  public let budgets: RolloutBudgets
  public let inventory: RolloutInventory
  public let missingLabels: [RolloutLabelDefinition]
  public let commands: [RolloutCommandBinding]
  public let jobBinding: RolloutJobBinding?
  public let effectEnvelope: RolloutEffectEnvelope
  public let createdAtMilliseconds: Int64
  public let expiresAtMilliseconds: Int64
}

public struct RolloutPreview: Codable, Equatable, Sendable {
  public let payload: RolloutPreviewPayload
  public let canonicalJSON: Data
  public let sha256: String

  public init(payload: RolloutPreviewPayload, canonicalJSON: Data, sha256: String) {
    self.payload = payload
    self.canonicalJSON = canonicalJSON
    self.sha256 = sha256
  }
}

public enum RolloutCanonicalJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: encoded)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  public static func decodeCanonical<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    let decoded: T
    do {
      decoded = try JSONDecoder().decode(type, from: data)
    } catch {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    guard try encode(decoded) == data else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    return decoded
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum RolloutPreviewBuilder {
  public static let exactPreviewLifetimeMilliseconds: Int64 = 15 * 60 * 1_000
  public static let finitePreviewLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
  public static let firstFiniteWindowLifetimeMilliseconds: Int64 = 4 * 60 * 60 * 1_000
  public static let laterFiniteWindowLifetimeMilliseconds: Int64 = 24 * 60 * 60 * 1_000

  public static func make(_ input: RolloutPreviewInput) throws -> RolloutPreview {
    try validate(input)
    let labels = input.missingLabels.sorted { lhs, rhs in
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      if lhs.color != rhs.color { return lhs.color < rhs.color }
      return lhs.description < rhs.description
    }
    let commands = input.commands.sorted { $0.ordinal < $1.ordinal }
    let envelope = try effectEnvelope(
      stage: input.scope.stage,
      currentStep: input.scope.object?.currentStep ?? "discovery",
      budgets: input.budgets,
      missingLabelCount: labels.count,
      commandCount: commands.count
    )
    let payload = RolloutPreviewPayload(
      policyVersion: input.policyVersion,
      releaseIdentity: input.releaseIdentity,
      scope: input.scope,
      budgets: input.budgets,
      inventory: input.inventory,
      missingLabels: labels,
      commands: commands,
      jobBinding: input.jobBinding,
      effectEnvelope: envelope,
      createdAtMilliseconds: input.createdAtMilliseconds,
      expiresAtMilliseconds: input.expiresAtMilliseconds
    )
    let data = try RolloutCanonicalJSON.encode(payload)
    return RolloutPreview(
      payload: payload,
      canonicalJSON: data,
      sha256: RolloutCanonicalJSON.sha256(data)
    )
  }

  public static func parseCanonical(_ data: Data) throws -> RolloutPreview {
    let payload = try RolloutCanonicalJSON.decodeCanonical(
      RolloutPreviewPayload.self,
      from: data
    )
    let input = input(from: payload)
    let rebuilt = try make(input)
    guard rebuilt.payload.effectEnvelope == payload.effectEnvelope,
      rebuilt.canonicalJSON == data
    else {
      throw RolloutAuthorityError.invalidEffectEnvelope
    }
    return rebuilt
  }

  public static func input(from payload: RolloutPreviewPayload) -> RolloutPreviewInput {
    RolloutPreviewInput(
      policyVersion: payload.policyVersion,
      releaseIdentity: payload.releaseIdentity,
      scope: payload.scope,
      budgets: payload.budgets,
      inventory: payload.inventory,
      missingLabels: payload.missingLabels,
      commands: payload.commands,
      jobBinding: payload.jobBinding,
      createdAtMilliseconds: payload.createdAtMilliseconds,
      expiresAtMilliseconds: payload.expiresAtMilliseconds
    )
  }

  public static func effectEnvelope(
    stage: RolloutWorkflowStage,
    currentStep: String,
    budgets: RolloutBudgets,
    missingLabelCount: Int,
    commandCount: Int
  ) throws -> RolloutEffectEnvelope {
    guard missingLabelCount >= 0, commandCount >= 0,
      missingLabelCount <= budgets.labelWrites,
      commandCount <= budgets.approvedCommands
    else {
      throw RolloutAuthorityError.invalidEffectEnvelope
    }
    var kinds: [RolloutEffectKind] = [.githubRead, .providerSession]
    if budgets.gitRemoteReads > 0 { kinds.append(.gitRemoteRead) }
    if budgets.markerParts > 0 { kinds.append(.markerBatch) }
    if missingLabelCount > 0 || budgets.labelWrites > 0 { kinds.append(.labelWrite) }
    if commandCount > 0 || budgets.approvedCommands > 0 { kinds.append(.approvedCommand) }
    if budgets.branchCreates > 0 { kinds.append(.branchCreate) }
    if budgets.pullRequestCreates > 0 { kinds.append(.pullRequestCreate) }
    if budgets.githubSends > budgets.markerParts + budgets.labelWrites + budgets.pullRequestCreates
    {
      kinds.append(.githubMutation)
    }
    let allowed: Set<RolloutEffectKind>
    switch stage {
    case .prReview, .generatedPRReview:
      allowed = [.githubRead, .gitRemoteRead, .providerSession, .markerBatch]
    case .issueTriage:
      allowed = [.githubRead, .providerSession, .markerBatch, .labelWrite]
    case .implementationPlan:
      allowed = [.githubRead, .gitRemoteRead, .providerSession, .markerBatch, .labelWrite]
    case .implementationExecute:
      allowed = Set(RolloutEffectKind.allCases)
    }
    guard Set(kinds).isSubset(of: allowed) else {
      throw RolloutAuthorityError.invalidEffectEnvelope
    }
    let values = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }.map { kind in
      RolloutEffectAllowance(kind: kind, maximumCount: maximum(for: kind, budgets: budgets))
    }
    return RolloutEffectEnvelope(
      stage: stage,
      currentStep: currentStep,
      allowances: values
    )
  }

  private static func validate(_ input: RolloutPreviewInput) throws {
    try validate(release: input.releaseIdentity)
    try validate(scope: input.scope)
    try validate(budgets: input.budgets, scope: input.scope)
    try validate(inventory: input.inventory)
    for label in input.missingLabels {
      try validate(label: label)
    }
    guard
      Set(input.missingLabels.map { $0.name.lowercased() }).count
        == input.missingLabels.count
    else {
      throw RolloutAuthorityError.invalidLabelDefinition
    }
    try validate(commands: input.commands, scope: input.scope)
    if let binding = input.jobBinding {
      try validate(binding: binding, scope: input.scope)
    } else if input.scope.mode == .exactObject {
      throw RolloutAuthorityError.invalidJobBinding
    }
    guard input.createdAtMilliseconds >= 0,
      input.expiresAtMilliseconds > input.createdAtMilliseconds
    else {
      throw RolloutAuthorityError.invalidFiniteWindow
    }
    let maximumLifetime =
      input.scope.mode == .exactObject
      ? exactPreviewLifetimeMilliseconds : finitePreviewLifetimeMilliseconds
    guard input.expiresAtMilliseconds - input.createdAtMilliseconds <= maximumLifetime else {
      throw RolloutAuthorityError.invalidFiniteWindow
    }
    if let finite = input.scope.finiteWindow {
      guard finite.expiresAtMilliseconds > input.expiresAtMilliseconds,
        finite.expiresAtMilliseconds - input.createdAtMilliseconds
          <= laterFiniteWindowLifetimeMilliseconds
      else {
        throw RolloutAuthorityError.invalidFiniteWindow
      }
    }
  }

  private static func validate(release: RolloutReleaseIdentity) throws {
    let digests = [
      release.applicationSHA256,
      release.helperSHA256,
      release.herdrHostSHA256,
      release.runtimeManifestSHA256,
      release.runtimeTreeSHA256,
      release.modelProfilesSHA256,
      release.workflowResourcesSHA256,
      release.repositoryConfigurationSHA256,
    ]
    guard GitHubInputValidation.validGitSHA(release.sourceCommit),
      GitHubInputValidation.validGitSHA(release.sourceTree),
      digests.allSatisfy(GitHubInputValidation.validSHA256),
      validText(release.bundleVersion, maximum: 32),
      release.bundleBuild > 0,
      release.schemaVersion == 10,
      release.engineProtocolVersion == 12,
      GitHubInputValidation.validOwner(release.githubAccount),
      release.githubAuthorID > 0,
      release.maxConcurrency == 1
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
  }

  private static func validate(scope: RolloutScope) throws {
    let repository = scope.repository
    guard validLowercaseUUID(repository.id),
      validIdentity(repository.nodeID),
      GitHubInputValidation.validOwner(repository.owner),
      GitHubInputValidation.validRepository(repository.name),
      GitHubInputValidation.validBranch(repository.defaultBranch),
      repository.enabled,
      workflowEnabled(scope.stage, repository: repository)
    else {
      throw RolloutAuthorityError.invalidRepositoryIdentity
    }
    switch (scope.mode, scope.object, scope.finiteWindow) {
    case (.exactObject, .some(let object), .none):
      try validate(object: object, stage: scope.stage)
    case (.finiteWindow, .none, .some(let window)):
      guard window.predicateVersion == 1,
        (1...10).contains(window.maximumJobs),
        [.prReview, .issueTriage, .implementationPlan].contains(scope.stage),
        window.candidates.count <= 10_000,
        window.candidates.map(\.ordinal) == Array(window.candidates.indices),
        window.candidates == window.candidates.sorted(by: candidatePrecedes),
        window.observedObjectNumberUpperBound >= 0,
        window.maximumFutureObjectNumber >= window.observedObjectNumberUpperBound,
        window.candidates.allSatisfy({
          $0.number <= window.observedObjectNumberUpperBound
        }),
        window.allowsFutureObjects
          ? window.maximumFutureObjectNumber > window.observedObjectNumberUpperBound
          : window.maximumFutureObjectNumber == window.observedObjectNumberUpperBound,
        Set(window.candidates.map { "\($0.nodeID)\u{0}\($0.revisionKey)" }).count
          == window.candidates.count
      else {
        throw RolloutAuthorityError.invalidFiniteWindow
      }
      for candidate in window.candidates {
        guard validIdentity(candidate.nodeID), candidate.number > 0,
          validText(candidate.revisionKey, maximum: 256),
          GitHubInputValidation.validSHA256(candidate.canonicalInputSHA256)
        else {
          throw RolloutAuthorityError.invalidFiniteWindow
        }
      }
    default:
      throw RolloutAuthorityError.invalidFiniteWindow
    }
  }

  public static func futureCandidateSHA256(
    scope: RolloutScope,
    nodeID: String,
    number: Int,
    revisionKey: String
  ) throws -> String {
    guard scope.mode == .finiteWindow,
      scope.finiteWindow?.predicateVersion == 1,
      validIdentity(nodeID), number > 0,
      validText(revisionKey, maximum: 256)
    else {
      throw RolloutAuthorityError.invalidFiniteWindow
    }
    struct Snapshot: Codable {
      let policy: String
      let repositoryID: String
      let stage: RolloutWorkflowStage
      let nodeID: String
      let number: Int
      let revisionKey: String
    }
    return RolloutCanonicalJSON.sha256(
      try RolloutCanonicalJSON.encode(
        Snapshot(
          policy: "finite-future-object-v1",
          repositoryID: scope.repository.id,
          stage: scope.stage,
          nodeID: nodeID,
          number: number,
          revisionKey: revisionKey
        )
      )
    )
  }

  public static func labelStateSHA256(_ labels: [GitHubLabel]) throws -> String {
    struct Snapshot: Codable {
      let nodeID: String
      let name: String
      let color: String
      let description: String
    }
    guard labels.count <= 1_000,
      Set(labels.map(\.nodeID)).count == labels.count,
      Set(labels.map { $0.name.lowercased() }).count == labels.count
    else {
      throw RolloutAuthorityError.invalidObjectSelector
    }
    let snapshots = try labels.map { label -> Snapshot in
      let color = label.color.lowercased()
      let description = label.description ?? ""
      guard validIdentity(label.nodeID), GitHubInputValidation.validLabel(label.name),
        color.utf8.count == 6,
        color.utf8.allSatisfy(GitHubInputValidation.isLowercaseHex),
        description.utf8.count <= 256,
        !description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        throw RolloutAuthorityError.invalidObjectSelector
      }
      return Snapshot(
        nodeID: label.nodeID,
        name: label.name,
        color: color,
        description: description
      )
    }.sorted { lhs, rhs in
      if lhs.name.lowercased() != rhs.name.lowercased() {
        return lhs.name.lowercased() < rhs.name.lowercased()
      }
      return lhs.nodeID < rhs.nodeID
    }
    return RolloutCanonicalJSON.sha256(try RolloutCanonicalJSON.encode(snapshots))
  }

  private static func candidatePrecedes(
    _ lhs: RolloutWindowCandidate,
    _ rhs: RolloutWindowCandidate
  ) -> Bool {
    if lhs.number != rhs.number { return lhs.number < rhs.number }
    if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
    return lhs.revisionKey < rhs.revisionKey
  }

  private static func validate(
    object: RolloutObjectSelector,
    stage: RolloutWorkflowStage
  ) throws {
    guard validIdentity(object.nodeID), object.number > 0,
      validText(object.revisionKey, maximum: 256),
      GitHubInputValidation.validSHA256(object.canonicalInputSHA256),
      validIdentifier(object.currentStep, maximum: 64),
      validCurrentStep(object.currentStep, stage: stage),
      object.headSHA.map(GitHubInputValidation.validGitSHA) ?? true,
      object.baseSHA.map(GitHubInputValidation.validGitSHA) ?? true,
      object.planSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      object.narrativeSHA256.map(GitHubInputValidation.validSHA256) ?? true,
      object.labelStateSHA256.map(GitHubInputValidation.validSHA256) ?? true
    else {
      throw RolloutAuthorityError.invalidObjectSelector
    }
    switch stage {
    case .prReview, .generatedPRReview:
      guard object.headSHA != nil, object.baseSHA != nil, object.narrativeSHA256 != nil else {
        throw RolloutAuthorityError.invalidObjectSelector
      }
    case .issueTriage, .implementationPlan:
      guard object.baseSHA != nil, object.labelStateSHA256 != nil else {
        throw RolloutAuthorityError.invalidObjectSelector
      }
    case .implementationExecute:
      guard object.baseSHA != nil, object.planSHA256 != nil, object.labelStateSHA256 != nil else {
        throw RolloutAuthorityError.invalidObjectSelector
      }
    }
  }

  private static func validCurrentStep(
    _ currentStep: String,
    stage: RolloutWorkflowStage
  ) -> Bool {
    switch stage {
    case .prReview, .generatedPRReview:
      currentStep == JobStepKind.review.rawValue
    case .issueTriage:
      currentStep == JobStepKind.triage.rawValue
    case .implementationPlan:
      [JobStepKind.claimReady, .replan].map(\.rawValue).contains(currentStep)
    case .implementationExecute:
      [JobStepKind.publishPlan, .claimApprovedPlan, .orchestrate]
        .map(\.rawValue).contains(currentStep)
    }
  }

  private static func validate(budgets: RolloutBudgets, scope: RolloutScope) throws {
    let integers = [
      budgets.jobs,
      budgets.githubReadRequests,
      budgets.githubReadPages,
      budgets.gitRemoteReads,
      budgets.providerSessions,
      budgets.approvedCommands,
      budgets.markerParts,
      budgets.labelWrites,
      budgets.branchCreates,
      budgets.pullRequestCreates,
      budgets.githubSends,
      budgets.gitSends,
    ]
    guard integers.allSatisfy({ $0 >= 0 }), budgets.githubReadBytes >= 0,
      (1...10).contains(budgets.jobs),
      budgets.githubReadRequests <= 10_000,
      budgets.githubReadPages <= 1_000,
      budgets.githubReadBytes <= 1_073_741_824,
      budgets.gitRemoteReads <= 1_000,
      budgets.providerSessions <= scope.stage.providerSessionLimit * budgets.jobs,
      budgets.approvedCommands <= 128,
      budgets.markerParts <= 64,
      budgets.labelWrites <= 64,
      budgets.branchCreates <= 10,
      budgets.pullRequestCreates <= 10,
      budgets.githubSends <= 256,
      budgets.gitSends <= 32
    else {
      throw RolloutAuthorityError.invalidBudget
    }
    if scope.mode == .exactObject {
      guard budgets.jobs == 1 else { throw RolloutAuthorityError.invalidBudget }
    } else {
      guard budgets.jobs == scope.finiteWindow?.maximumJobs else {
        throw RolloutAuthorityError.invalidBudget
      }
    }
  }

  private static func validate(inventory: RolloutInventory) throws {
    guard
      [
        inventory.queueSHA256,
        inventory.recoverySHA256,
        inventory.mutationIntentSHA256,
        inventory.outsideScopeQueueSHA256,
        inventory.outsideScopeRecoverySHA256,
        inventory.outsideScopeMutationIntentSHA256,
      ]
      .allSatisfy(GitHubInputValidation.validSHA256),
      inventory.queueItemCount >= 0,
      inventory.recoveryItemCount >= 0,
      inventory.mutationItemCount >= 0,
      inventory.outsideScopeQueueItemCount >= 0,
      inventory.outsideScopeRecoveryItemCount >= 0,
      inventory.outsideScopeMutationItemCount >= 0,
      inventory.outsideScopeQueueItemCount <= inventory.queueItemCount,
      inventory.outsideScopeRecoveryItemCount <= inventory.recoveryItemCount,
      inventory.outsideScopeMutationItemCount <= inventory.mutationItemCount
    else {
      throw RolloutAuthorityError.invalidDigest("inventory")
    }
  }

  private static func validate(label: RolloutLabelDefinition) throws {
    guard GitHubInputValidation.validLabel(label.name), label.color.utf8.count == 6,
      label.color.utf8.allSatisfy(GitHubInputValidation.isLowercaseHex),
      validText(label.description, maximum: 256)
    else {
      throw RolloutAuthorityError.invalidLabelDefinition
    }
  }

  private static func validate(commands: [RolloutCommandBinding], scope: RolloutScope) throws {
    guard commands.map(\.ordinal) == Array(commands.indices),
      Set(commands.map(\.commandID)).count == commands.count,
      Set(commands.map(\.workspaceHeadSHA)).count <= 1,
      commands.count <= 128,
      commands.isEmpty || scope.stage == .implementationExecute
    else {
      throw RolloutAuthorityError.invalidCommandBinding
    }
    for command in commands {
      guard validIdentifier(command.commandID, maximum: 128),
        GitHubInputValidation.validSHA256(command.definitionSHA256),
        GitHubInputValidation.validSHA256(command.frozenPlanSHA256),
        GitHubInputValidation.validGitSHA(command.workspaceHeadSHA),
        command.frozenPlanSHA256 == scope.object?.planSHA256
      else {
        throw RolloutAuthorityError.invalidCommandBinding
      }
    }
  }

  private static func validate(binding: RolloutJobBinding, scope: RolloutScope) throws {
    guard validLowercaseUUID(binding.jobID), scope.stage.accepts(jobKind: binding.jobKind),
      binding.objectNumber > 0,
      validIdentifier(binding.contractVersion, maximum: 128),
      validIdentifier(binding.currentStep, maximum: 64),
      binding.currentStep == scope.object?.currentStep
    else {
      throw RolloutAuthorityError.invalidJobBinding
    }
  }

  private static func workflowEnabled(
    _ stage: RolloutWorkflowStage,
    repository: RolloutRepositoryIdentity
  ) -> Bool {
    switch stage {
    case .prReview, .generatedPRReview: repository.reviewEnabled
    case .issueTriage: repository.triageEnabled
    case .implementationPlan, .implementationExecute: repository.implementationEnabled
    }
  }

  private static func maximum(for kind: RolloutEffectKind, budgets: RolloutBudgets) -> Int64 {
    switch kind {
    case .githubRead: Int64(budgets.githubReadRequests)
    case .gitRemoteRead: Int64(budgets.gitRemoteReads)
    case .providerSession: Int64(budgets.providerSessions)
    case .approvedCommand: Int64(budgets.approvedCommands)
    case .markerBatch: Int64(budgets.markerParts)
    case .labelWrite: Int64(budgets.labelWrites)
    case .branchCreate: Int64(budgets.branchCreates)
    case .pullRequestCreate: Int64(budgets.pullRequestCreates)
    case .githubMutation: Int64(budgets.githubSends)
    }
  }

  private static func validIdentity(_ value: String) -> Bool {
    validText(value, maximum: 256)
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || [43, 45, 46, 47, 61, 95].contains(byte)
      }
  }

  static func validIdentifier(_ value: String, maximum: Int) -> Bool {
    validText(value, maximum: maximum)
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || [45, 46, 58, 95].contains(byte)
      }
  }

  static func validLowercaseUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }

  private static func validText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum && value.utf8.count <= maximum * 4
      && value == value.precomposedStringWithCanonicalMapping
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

public struct RolloutAuthorization: Codable, Equatable, Sendable {
  public let id: String
  public let previewSHA256: String
  public let state: RolloutAuthorizationState
  public let scopeMode: RolloutScopeMode
  public let workflowStage: RolloutWorkflowStage
  public let repositoryID: UUID
  public let activatedAtMilliseconds: Int64
  public let expiresAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public let terminalReason: String?

  public init(
    id: String,
    previewSHA256: String,
    state: RolloutAuthorizationState,
    scopeMode: RolloutScopeMode,
    workflowStage: RolloutWorkflowStage,
    repositoryID: UUID,
    activatedAtMilliseconds: Int64,
    expiresAtMilliseconds: Int64,
    updatedAtMilliseconds: Int64,
    terminalReason: String?
  ) {
    self.id = id
    self.previewSHA256 = previewSHA256
    self.state = state
    self.scopeMode = scopeMode
    self.workflowStage = workflowStage
    self.repositoryID = repositoryID
    self.activatedAtMilliseconds = activatedAtMilliseconds
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.updatedAtMilliseconds = updatedAtMilliseconds
    self.terminalReason = terminalReason
  }
}

public struct RolloutAuthorizationEvent: Codable, Equatable, Sendable {
  public let id: Int64
  public let authorizationID: String
  public let eventKey: String
  public let kind: RolloutAuthorizationEventKind
  public let fromState: RolloutAuthorizationState?
  public let toState: RolloutAuthorizationState
  public let reasonCode: String
  public let checkpointSHA256: String?
  public let createdAtMilliseconds: Int64
}

public struct RolloutEffectCost: Codable, Equatable, Sendable {
  public let githubReadRequests: Int
  public let githubReadPages: Int
  public let githubReadBytes: Int64
  public let gitRemoteReads: Int
  public let providerSessions: Int
  public let approvedCommands: Int
  public let markerParts: Int
  public let labelWrites: Int
  public let branchCreates: Int
  public let pullRequestCreates: Int
  public let githubSends: Int
  public let gitSends: Int

  public init(
    githubReadRequests: Int = 0,
    githubReadPages: Int = 0,
    githubReadBytes: Int64 = 0,
    gitRemoteReads: Int = 0,
    providerSessions: Int = 0,
    approvedCommands: Int = 0,
    markerParts: Int = 0,
    labelWrites: Int = 0,
    branchCreates: Int = 0,
    pullRequestCreates: Int = 0,
    githubSends: Int = 0,
    gitSends: Int = 0
  ) {
    self.githubReadRequests = githubReadRequests
    self.githubReadPages = githubReadPages
    self.githubReadBytes = githubReadBytes
    self.gitRemoteReads = gitRemoteReads
    self.providerSessions = providerSessions
    self.approvedCommands = approvedCommands
    self.markerParts = markerParts
    self.labelWrites = labelWrites
    self.branchCreates = branchCreates
    self.pullRequestCreates = pullRequestCreates
    self.githubSends = githubSends
    self.gitSends = gitSends
  }

  public var asBudgets: RolloutBudgets {
    RolloutBudgets(
      jobs: 0,
      githubReadRequests: githubReadRequests,
      githubReadPages: githubReadPages,
      githubReadBytes: githubReadBytes,
      gitRemoteReads: gitRemoteReads,
      providerSessions: providerSessions,
      approvedCommands: approvedCommands,
      markerParts: markerParts,
      labelWrites: labelWrites,
      branchCreates: branchCreates,
      pullRequestCreates: pullRequestCreates,
      githubSends: githubSends,
      gitSends: gitSends
    )
  }

  public func validate(for kind: RolloutEffectKind) throws {
    let values = [
      githubReadRequests,
      githubReadPages,
      gitRemoteReads,
      providerSessions,
      approvedCommands,
      markerParts,
      labelWrites,
      branchCreates,
      pullRequestCreates,
      githubSends,
      gitSends,
    ]
    guard values.allSatisfy({ $0 >= 0 }), githubReadBytes >= 0 else {
      throw RolloutAuthorityError.invalidEffectCost
    }
    let valid: Bool
    switch kind {
    case .githubRead:
      valid =
        githubReadRequests == 1 && githubReadPages == 1 && githubReadBytes > 0
        && nonReadTotal == 0
    case .gitRemoteRead:
      valid = githubReadTotal == 0 && gitRemoteReads == 1 && nonReadTotal == 1
    case .providerSession:
      valid = githubReadTotal == 0 && providerSessions == 1 && nonReadTotal == 1
    case .approvedCommand:
      valid = githubReadTotal == 0 && approvedCommands == 1 && nonReadTotal == 1
    case .markerBatch:
      valid =
        markerParts == 1 && githubSends == 1
        && githubReadTotal == 0 && nonReadTotal == 2
    case .labelWrite:
      valid =
        labelWrites == 1 && githubSends == 1
        && githubReadTotal == 0 && nonReadTotal == 2
    case .branchCreate:
      valid =
        branchCreates == 1 && gitSends == 1
        && githubReadTotal == 0 && nonReadTotal == 2
    case .pullRequestCreate:
      valid =
        pullRequestCreates == 1 && githubSends == 1
        && githubReadTotal == 0 && nonReadTotal == 2
    case .githubMutation:
      valid = githubReadTotal == 0 && githubSends == 1 && nonReadTotal == 1
    }
    guard valid else { throw RolloutAuthorityError.invalidEffectCost }
  }

  private var nonReadTotal: Int64 {
    Int64(
      gitRemoteReads + providerSessions + approvedCommands + markerParts + labelWrites
        + branchCreates + pullRequestCreates + githubSends + gitSends)
  }

  private var githubReadTotal: Int64 {
    Int64(githubReadRequests + githubReadPages) + githubReadBytes
  }
}

public struct RolloutEffectReservationRequest: Codable, Equatable, Sendable {
  public let authorizationID: String
  public let jobID: UUID
  public let kind: RolloutEffectKind
  public let operationSHA256: String
  public let targetSHA256: String
  public let ordinal: Int
  public let attempt: Int
  public let cost: RolloutEffectCost
  public let mutationIntentID: String?

  public init(
    authorizationID: String,
    jobID: UUID,
    kind: RolloutEffectKind,
    operationSHA256: String,
    targetSHA256: String,
    ordinal: Int,
    attempt: Int,
    cost: RolloutEffectCost,
    mutationIntentID: String? = nil
  ) {
    self.authorizationID = authorizationID
    self.jobID = jobID
    self.kind = kind
    self.operationSHA256 = operationSHA256
    self.targetSHA256 = targetSHA256
    self.ordinal = ordinal
    self.attempt = attempt
    self.cost = cost
    self.mutationIntentID = mutationIntentID
  }
}

public struct RolloutEffectReservation: Codable, Equatable, Sendable {
  public let id: String
  public let request: RolloutEffectReservationRequest
  public let state: RolloutEffectReservationState
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
}

public struct RolloutStatusReport: Codable, Equatable, Sendable {
  public let authorization: RolloutAuthorization
  public let releaseIdentity: RolloutReleaseIdentity
  public let scope: RolloutScope
  public let effectEnvelope: RolloutEffectEnvelope
  public let missingLabels: [RolloutLabelDefinition]
  public let commands: [RolloutCommandBinding]
  public let initialBudgets: RolloutBudgets
  public let remainingBudgets: RolloutBudgets
  public let boundJobIDs: [UUID]
  public let reservations: [RolloutEffectReservation]
  public let events: [RolloutAuthorizationEvent]

  public init(
    authorization: RolloutAuthorization,
    releaseIdentity: RolloutReleaseIdentity,
    scope: RolloutScope,
    effectEnvelope: RolloutEffectEnvelope,
    missingLabels: [RolloutLabelDefinition],
    commands: [RolloutCommandBinding],
    initialBudgets: RolloutBudgets,
    remainingBudgets: RolloutBudgets,
    boundJobIDs: [UUID],
    reservations: [RolloutEffectReservation],
    events: [RolloutAuthorizationEvent]
  ) {
    self.authorization = authorization
    self.releaseIdentity = releaseIdentity
    self.scope = scope
    self.effectEnvelope = effectEnvelope
    self.missingLabels = missingLabels
    self.commands = commands
    self.initialBudgets = initialBudgets
    self.remainingBudgets = remainingBudgets
    self.boundJobIDs = boundJobIDs
    self.reservations = reservations
    self.events = events
  }
}

public struct RolloutJobCreationBinding: Equatable, Sendable {
  public let authorizationID: String
  public let workflowStage: RolloutWorkflowStage
  public let canonicalInputSHA256: String

  public init(
    authorizationID: String,
    workflowStage: RolloutWorkflowStage,
    canonicalInputSHA256: String
  ) {
    self.authorizationID = authorizationID
    self.workflowStage = workflowStage
    self.canonicalInputSHA256 = canonicalInputSHA256
  }
}

public struct RolloutJobInputSnapshot: Equatable, Sendable {
  public let jobID: UUID
  public let canonicalInputSHA256: String
  public let narrativeSHA256: String?
  public let baseSHA: String
  public let labelStateSHA256: String?
  public let planSHA256: String?

  public init(
    jobID: UUID,
    canonicalInputSHA256: String,
    narrativeSHA256: String? = nil,
    baseSHA: String,
    labelStateSHA256: String? = nil,
    planSHA256: String? = nil
  ) {
    self.jobID = jobID
    self.canonicalInputSHA256 = canonicalInputSHA256
    self.narrativeSHA256 = narrativeSHA256
    self.baseSHA = baseSHA
    self.labelStateSHA256 = labelStateSHA256
    self.planSHA256 = planSHA256
  }
}

public protocol RolloutJobInputSnapshotRecording: Sendable {
  func freezeJobInputSnapshot(
    _ snapshot: RolloutJobInputSnapshot,
    now: Date
  ) async throws
}

public struct RolloutLocalStateEvidence: Codable, Equatable, Sendable {
  public let inventory: RolloutInventory
  public let repositoryConfigurationSHA256: String
  public let modelProfilesSHA256: String

  public init(
    inventory: RolloutInventory,
    repositoryConfigurationSHA256: String,
    modelProfilesSHA256: String
  ) {
    self.inventory = inventory
    self.repositoryConfigurationSHA256 = repositoryConfigurationSHA256
    self.modelProfilesSHA256 = modelProfilesSHA256
  }
}

public struct RolloutActivationRequest: Codable, Equatable, Sendable {
  public let authorizationID: UUID
  public let approvedCanonicalJSON: Data
  public let confirmedSHA256: String

  public init(
    authorizationID: UUID,
    approvedCanonicalJSON: Data,
    confirmedSHA256: String
  ) {
    self.authorizationID = authorizationID
    self.approvedCanonicalJSON = approvedCanonicalJSON
    self.confirmedSHA256 = confirmedSHA256
  }

  public func validate(mode: RolloutScopeMode) throws {
    guard approvedCanonicalJSON.count <= 1_048_576,
      GitHubInputValidation.validSHA256(confirmedSHA256)
    else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    let approved = try RolloutPreviewBuilder.parseCanonical(approvedCanonicalJSON)
    guard approved.payload.scope.mode == mode,
      approved.sha256 == confirmedSHA256
    else {
      throw RolloutAuthorityError.previewDigestMismatch
    }
  }
}

public struct RolloutStopRequest: Codable, Equatable, Sendable {
  public let authorizationID: String
  public let previewSHA256: String
  public let timeoutMilliseconds: Int

  public init(
    authorizationID: String,
    previewSHA256: String,
    timeoutMilliseconds: Int
  ) {
    self.authorizationID = authorizationID
    self.previewSHA256 = previewSHA256
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  public func validate() throws {
    guard RolloutPreviewBuilder.validLowercaseUUID(authorizationID),
      GitHubInputValidation.validSHA256(previewSHA256),
      (1_000...660_000).contains(timeoutMilliseconds)
    else {
      throw RolloutAuthorityError.invalidIdentifier("stop request")
    }
  }
}

public struct RolloutRecoveryRequest: Codable, Equatable, Sendable {
  public let authorizationID: String
  public let previewSHA256: String

  public init(authorizationID: String, previewSHA256: String) {
    self.authorizationID = authorizationID
    self.previewSHA256 = previewSHA256
  }

  public func validate() throws {
    guard RolloutPreviewBuilder.validLowercaseUUID(authorizationID),
      GitHubInputValidation.validSHA256(previewSHA256)
    else {
      throw RolloutAuthorityError.invalidIdentifier("recovery request")
    }
  }
}

public struct RolloutRecoveryEffect: Codable, Equatable, Sendable {
  public let reservationID: String
  public let jobID: UUID
  public let kind: RolloutEffectKind
  public let operationSHA256: String
  public let targetSHA256: String
  public let state: RolloutEffectReservationState
  public let mutationIntentID: String?
  public let readbackOnly: Bool
}

public struct RolloutRecoveryPayload: Codable, Equatable, Sendable {
  public let policyVersion: RolloutPolicyVersion
  public let authorizationID: String
  public let previewSHA256: String
  public let state: RolloutAuthorizationState
  public let scopeMode: RolloutScopeMode
  public let authorizationExpiresAtMilliseconds: Int64
  public let action: RolloutRecoveryAction
  public let effects: [RolloutRecoveryEffect]
  public let remainingBudgets: RolloutBudgets
  public let createdAtMilliseconds: Int64
  public let expiresAtMilliseconds: Int64
}

public enum RolloutRecoveryAction: String, Codable, CaseIterable, Sendable {
  case readbackOnly
  case readbackThenContinueExact
}

public struct RolloutRecoveryPreview: Codable, Equatable, Sendable {
  public let payload: RolloutRecoveryPayload
  public let canonicalJSON: Data
  public let sha256: String

  public init(payload: RolloutRecoveryPayload, canonicalJSON: Data, sha256: String) {
    self.payload = payload
    self.canonicalJSON = canonicalJSON
    self.sha256 = sha256
  }
}

public enum RolloutRecoveryPreviewBuilder {
  public static let lifetimeMilliseconds: Int64 = 10 * 60 * 1_000

  public static func make(
    report: RolloutStatusReport,
    createdAtMilliseconds: Int64
  ) throws -> RolloutRecoveryPreview {
    guard
      report.authorization.state == .recoveryRequired
        || report.authorization.state == .draining
    else {
      throw RolloutAuthorityError.authorizationNotActive(report.authorization.id)
    }
    let effects = report.reservations.filter { $0.state != .settled }.map { reservation in
      RolloutRecoveryEffect(
        reservationID: reservation.id,
        jobID: reservation.request.jobID,
        kind: reservation.request.kind,
        operationSHA256: reservation.request.operationSHA256,
        targetSHA256: reservation.request.targetSHA256,
        state: reservation.state,
        mutationIntentID: reservation.request.mutationIntentID,
        readbackOnly: Self.isReadbackOnly(
          kind: reservation.request.kind,
          state: reservation.state,
          mutationIntentID: reservation.request.mutationIntentID
        )
      )
    }.sorted { $0.reservationID < $1.reservationID }
    let payload = RolloutRecoveryPayload(
      policyVersion: .v1,
      authorizationID: report.authorization.id,
      previewSHA256: report.authorization.previewSHA256,
      state: report.authorization.state,
      scopeMode: report.scope.mode,
      authorizationExpiresAtMilliseconds: report.authorization.expiresAtMilliseconds,
      action: report.scope.mode == .exactObject
        && report.authorization.expiresAtMilliseconds > createdAtMilliseconds
        && effects.allSatisfy(Self.continuable)
        ? .readbackThenContinueExact : .readbackOnly,
      effects: effects,
      remainingBudgets: report.remainingBudgets,
      createdAtMilliseconds: createdAtMilliseconds,
      expiresAtMilliseconds: createdAtMilliseconds + lifetimeMilliseconds
    )
    let canonicalJSON = try RolloutCanonicalJSON.encode(payload)
    return RolloutRecoveryPreview(
      payload: payload,
      canonicalJSON: canonicalJSON,
      sha256: RolloutCanonicalJSON.sha256(canonicalJSON)
    )
  }

  public static func parseCanonical(_ data: Data) throws -> RolloutRecoveryPreview {
    let payload = try RolloutCanonicalJSON.decodeCanonical(
      RolloutRecoveryPayload.self,
      from: data
    )
    guard payload.policyVersion == .v1,
      RolloutPreviewBuilder.validLowercaseUUID(payload.authorizationID),
      GitHubInputValidation.validSHA256(payload.previewSHA256),
      payload.state == .recoveryRequired || payload.state == .draining,
      payload.authorizationExpiresAtMilliseconds > 0,
      payload.createdAtMilliseconds >= 0,
      payload.expiresAtMilliseconds - payload.createdAtMilliseconds == lifetimeMilliseconds,
      payload.effects.map(\.reservationID) == payload.effects.map(\.reservationID).sorted(),
      Set(payload.effects.map(\.reservationID)).count == payload.effects.count,
      payload.effects.allSatisfy({ effect in
        RolloutPreviewBuilder.validLowercaseUUID(effect.reservationID)
          && GitHubInputValidation.validSHA256(effect.operationSHA256)
          && GitHubInputValidation.validSHA256(effect.targetSHA256)
          && effect.readbackOnly
            == Self.isReadbackOnly(
              kind: effect.kind,
              state: effect.state,
              mutationIntentID: effect.mutationIntentID
            )
      }),
      payload.action
        == (payload.scopeMode == .exactObject
          && payload.authorizationExpiresAtMilliseconds > payload.createdAtMilliseconds
          && payload.effects.allSatisfy(Self.continuable)
          ? .readbackThenContinueExact : .readbackOnly)
    else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    let canonicalJSON = try RolloutCanonicalJSON.encode(payload)
    guard canonicalJSON == data else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    return RolloutRecoveryPreview(
      payload: payload,
      canonicalJSON: canonicalJSON,
      sha256: RolloutCanonicalJSON.sha256(canonicalJSON)
    )
  }

  private static func continuable(_ effect: RolloutRecoveryEffect) -> Bool {
    effect.state == .reserved || effect.readbackOnly
  }

  private static func isReadbackOnly(
    kind: RolloutEffectKind,
    state: RolloutEffectReservationState,
    mutationIntentID: String?
  ) -> Bool {
    if mutationIntentID != nil,
      [.sendStarted, .observationRequired, .attributed].contains(state)
    {
      return true
    }
    return [.providerSession, .approvedCommand].contains(kind) && state == .sendStarted
  }
}

public struct RolloutRecoveryAuthorization: Codable, Equatable, Sendable {
  public let approvedCanonicalJSON: Data
  public let confirmedSHA256: String

  public init(approvedCanonicalJSON: Data, confirmedSHA256: String) {
    self.approvedCanonicalJSON = approvedCanonicalJSON
    self.confirmedSHA256 = confirmedSHA256
  }

  public func validate() throws {
    guard approvedCanonicalJSON.count <= 1_048_576,
      GitHubInputValidation.validSHA256(confirmedSHA256)
    else {
      throw RolloutAuthorityError.invalidCanonicalJSON
    }
    let preview = try RolloutRecoveryPreviewBuilder.parseCanonical(approvedCanonicalJSON)
    guard preview.sha256 == confirmedSHA256 else {
      throw RolloutAuthorityError.previewDigestMismatch
    }
  }
}

public struct RolloutOperatorJob: Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: JobKind
  public let objectNumber: Int?
  public let revisionKey: String
  public let state: JobState
  public let attempt: Int
  public let currentStep: Int
  public let currentStepKind: JobStepKind?
  public let terminalReason: String?
}

public struct RolloutOperatorReport: Codable, Equatable, Sendable {
  public let status: RolloutStatusReport
  public let jobs: [RolloutOperatorJob]
  public let checkpointSHA256: String?

  public init(
    status: RolloutStatusReport,
    jobs: [RolloutOperatorJob],
    checkpointSHA256: String?
  ) {
    self.status = status
    self.jobs = jobs
    self.checkpointSHA256 = checkpointSHA256
  }
}
