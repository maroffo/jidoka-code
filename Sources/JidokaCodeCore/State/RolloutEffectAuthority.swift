import Foundation

public enum RolloutEffectExecutionMode: Equatable, Sendable {
  case discovery
  case workflow(jobID: UUID)
  case readback(jobID: UUID, intentID: UUID)
  case historicalCanary(jobID: UUID)
}

public struct RolloutEffectExecutionContext: Equatable, Sendable {
  public let mode: RolloutEffectExecutionMode

  public init(mode: RolloutEffectExecutionMode) {
    self.mode = mode
  }

  public var jobID: UUID? {
    switch mode {
    case .discovery: nil
    case .workflow(let jobID), .readback(let jobID, _), .historicalCanary(let jobID): jobID
    }
  }

  public var isReadback: Bool {
    if case .readback = mode { return true }
    return false
  }
}

public enum RolloutEffectTaskContext {
  @TaskLocal public static var current: RolloutEffectExecutionContext?
}

public enum RolloutEffectPermit: Equatable, Sendable {
  case reservation(id: String)
  case scopeRead(id: String)
  case readback(id: String)
  case gitReadback(id: String)
  case boundedRead(id: String)
  case historicalCanary(jobID: UUID)
}

public struct RolloutGitHubReadEffect: Sendable {
  public let operation: GitHubOperation
  public let maximumResponseBytes: Int64
  public let context: RolloutEffectExecutionContext

  public init(
    operation: GitHubOperation,
    maximumResponseBytes: Int64,
    context: RolloutEffectExecutionContext
  ) {
    self.operation = operation
    self.maximumResponseBytes = maximumResponseBytes
    self.context = context
  }
}

public protocol RolloutGitHubReadAuthorizing: Sendable {
  func reserveGitHubRead(
    _ effect: RolloutGitHubReadEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func verifyGitHubReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitHubReadEffect
  ) async throws
  func settleGitHubRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws
}

public protocol RolloutGitRemoteReadAuthorizing: Sendable {
  func reserveGitRemoteRead(
    _ effect: RolloutGitRemoteReadEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func verifyGitRemoteReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitRemoteReadEffect
  ) async throws
  func settleGitRemoteRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws
}

public actor BoundedRolloutPreviewReadAuthority: RolloutGitHubReadAuthorizing,
  RolloutGitRemoteReadAuthorizing
{
  public struct Snapshot: Equatable, Sendable {
    public let reservedRequests: Int
    public let reservedBytes: Int64
    public let outstandingRequests: Int
    public let reservedGitRemoteReads: Int
    public let outstandingGitRemoteReads: Int
  }

  private let repository: GitHubRepositoryCoordinates?
  private let repositoryID: UUID?
  private let repositoryNodeID: String?
  private let jobID: UUID?
  private let maximumRequests: Int
  private let maximumBytes: Int64
  private let maximumGitRemoteReads: Int
  private var reservedRequests = 0
  private var reservedBytes: Int64 = 0
  private var outstanding: [String: String] = [:]
  private var verified: Set<String> = []
  private var reservedGitRemoteReads = 0
  private var outstandingGitRemoteReads: [String: String] = [:]
  private var verifiedGitRemoteReads: Set<String> = []

  public init(
    repository: GitHubRepositoryCoordinates?,
    maximumRequests: Int,
    maximumBytes: Int64,
    repositoryID: UUID? = nil,
    repositoryNodeID: String? = nil,
    jobID: UUID? = nil,
    maximumGitRemoteReads: Int = 0
  ) throws {
    guard (1...1_000).contains(maximumRequests), maximumBytes > 0,
      (0...1_000).contains(maximumGitRemoteReads),
      maximumGitRemoteReads == 0
        || (repositoryID != nil && repositoryNodeID?.isEmpty == false && jobID != nil)
    else {
      throw RolloutAuthorityError.invalidBudget
    }
    self.repository = repository
    self.repositoryID = repositoryID
    self.repositoryNodeID = repositoryNodeID
    self.jobID = jobID
    self.maximumRequests = maximumRequests
    self.maximumBytes = maximumBytes
    self.maximumGitRemoteReads = maximumGitRemoteReads
  }

  public func reserveGitHubRead(
    _ effect: RolloutGitHubReadEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    guard !effect.operation.kind.isWrite,
      effect.maximumResponseBytes > 0,
      reservedRequests < maximumRequests,
      reservedBytes <= maximumBytes - effect.maximumResponseBytes,
      Self.matches(effect.operation, repository: repository)
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    let id = UUID().uuidString.lowercased()
    reservedRequests += 1
    reservedBytes += effect.maximumResponseBytes
    outstanding[id] = try Self.githubReadIdentity(effect)
    return .boundedRead(id: id)
  }

  public func verifyGitHubReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitHubReadEffect
  ) throws {
    guard case .boundedRead(let id) = permit,
      let identity = outstanding.removeValue(forKey: id),
      identity == (try Self.githubReadIdentity(effect)),
      verified.insert(id).inserted
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func settleGitHubRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now _: Date
  ) throws {
    guard case .boundedRead(let id) = permit,
      GitHubInputValidation.validSHA256(evidenceSHA256),
      outstanding.removeValue(forKey: id) != nil || verified.remove(id) != nil
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func snapshot() -> Snapshot {
    Snapshot(
      reservedRequests: reservedRequests,
      reservedBytes: reservedBytes,
      outstandingRequests: outstanding.count + verified.count,
      reservedGitRemoteReads: reservedGitRemoteReads,
      outstandingGitRemoteReads: outstandingGitRemoteReads.count
        + verifiedGitRemoteReads.count
    )
  }

  public func reserveGitRemoteRead(
    _ effect: RolloutGitRemoteReadEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    guard maximumGitRemoteReads > 0,
      reservedGitRemoteReads < maximumGitRemoteReads,
      effect.jobID == jobID,
      effect.repositoryID == repositoryID,
      effect.repositoryNodeID == repositoryNodeID,
      !effect.target.isEmpty,
      effect.target.utf8.count <= 2_048
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    let id = UUID().uuidString.lowercased()
    reservedGitRemoteReads += 1
    outstandingGitRemoteReads[id] = Self.gitRemoteReadIdentity(effect)
    return .boundedRead(id: id)
  }

  public func verifyGitRemoteReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitRemoteReadEffect
  ) throws {
    guard case .boundedRead(let id) = permit,
      let identity = outstandingGitRemoteReads.removeValue(forKey: id),
      identity == Self.gitRemoteReadIdentity(effect),
      verifiedGitRemoteReads.insert(id).inserted
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  public func settleGitRemoteRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now _: Date
  ) throws {
    guard case .boundedRead(let id) = permit,
      GitHubInputValidation.validSHA256(evidenceSHA256),
      outstandingGitRemoteReads.removeValue(forKey: id) != nil
        || verifiedGitRemoteReads.remove(id) != nil
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  private static func matches(
    _ operation: GitHubOperation,
    repository: GitHubRepositoryCoordinates?
  ) -> Bool {
    guard let repository else { return operation == .authenticatedIdentity }
    guard let observed = operation.repositoryCoordinates else { return false }
    return observed.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
      && observed.repository.caseInsensitiveCompare(repository.repository) == .orderedSame
  }

  private static func githubReadIdentity(_ effect: RolloutGitHubReadEffect) throws -> String {
    let descriptor = try GitHubRequestFactory.make(effect.operation)
    let value = [
      "github-preview-read-v1", descriptor.request.httpMethod ?? "",
      descriptor.request.url?.absoluteString ?? "",
      GitHubMarkerCodec.sha256(descriptor.request.httpBody ?? Data()),
      String(effect.maximumResponseBytes), String(reflecting: effect.context.mode),
    ].joined(separator: "\n")
    return GitHubMarkerCodec.sha256(Data(value.utf8))
  }

  private static func gitRemoteReadIdentity(_ effect: RolloutGitRemoteReadEffect) -> String {
    let value = [
      "git-preview-read-v1", effect.jobID.uuidString.lowercased(),
      effect.repositoryID.uuidString.lowercased(), effect.repositoryNodeID,
      effect.operation.rawValue, effect.target,
    ].joined(separator: "\n")
    return GitHubMarkerCodec.sha256(Data(value.utf8))
  }
}

public enum RolloutGitRemoteOperation: String, Codable, CaseIterable, Sendable {
  case cloneMirror
  case fetchMirror
  case fetchPreviewBase
  case fetchPullRequest
  case readReference
}

public struct RolloutGitRemoteReadEffect: Sendable {
  public let jobID: UUID
  public let repositoryID: UUID
  public let repositoryNodeID: String
  public let operation: RolloutGitRemoteOperation
  public let target: String

  public init(
    jobID: UUID,
    repositoryID: UUID,
    repositoryNodeID: String,
    operation: RolloutGitRemoteOperation,
    target: String
  ) {
    self.jobID = jobID
    self.repositoryID = repositoryID
    self.repositoryNodeID = repositoryNodeID
    self.operation = operation
    self.target = target
  }
}

public struct RolloutProviderEffect: Sendable {
  public let jobID: UUID
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let round: Int
  public let runNonce: String
  public let artifactSHA256: String
  public let narrativeSHA256: String?
  public let planSHA256: String?
  public let resourceSHA256: String
  public let profileSHA256: String
  public let sessionDirectiveSHA256: String

  public init(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    runNonce: String,
    artifactSHA256: String,
    narrativeSHA256: String?,
    planSHA256: String?,
    resourceSHA256: String,
    profileSHA256: String,
    sessionDirectiveSHA256: String
  ) {
    self.jobID = jobID
    self.workflow = workflow
    self.role = role
    self.round = round
    self.runNonce = runNonce
    self.artifactSHA256 = artifactSHA256
    self.narrativeSHA256 = narrativeSHA256
    self.planSHA256 = planSHA256
    self.resourceSHA256 = resourceSHA256
    self.profileSHA256 = profileSHA256
    self.sessionDirectiveSHA256 = sessionDirectiveSHA256
  }
}

public struct RolloutApprovedCommandEffect: Sendable {
  public let jobID: UUID
  public let commandID: String
  public let definitionSHA256: String
  public let planSHA256: String
  public let workspaceHeadSHA: String
  public let phase: ApprovedCommandRunPhase
  public let round: Int
  public let ordinal: Int

  public init(
    jobID: UUID,
    commandID: String,
    definitionSHA256: String,
    planSHA256: String,
    workspaceHeadSHA: String,
    phase: ApprovedCommandRunPhase,
    round: Int,
    ordinal: Int
  ) {
    self.jobID = jobID
    self.commandID = commandID
    self.definitionSHA256 = definitionSHA256
    self.planSHA256 = planSHA256
    self.workspaceHeadSHA = workspaceHeadSHA
    self.phase = phase
    self.round = round
    self.ordinal = ordinal
  }
}

public struct RolloutMarkerBatchEffect: Sendable {
  public let jobID: UUID
  public let operation: MutationOperation
  public let repositoryID: UUID
  public let repository: GitHubRepositoryCoordinates
  public let repositoryNodeID: String
  public let objectNodeID: String
  public let objectNumber: Int
  public let revision: String
  public let markerKind: GitHubMarkerKind
  public let authorID: Int64
  public let documentSHA256: String
  public let generation: Int
  public let intentIDs: [UUID]

  public init(
    jobID: UUID,
    operation: MutationOperation,
    repositoryID: UUID,
    repository: GitHubRepositoryCoordinates,
    repositoryNodeID: String,
    objectNodeID: String,
    objectNumber: Int,
    revision: String,
    markerKind: GitHubMarkerKind,
    authorID: Int64,
    documentSHA256: String,
    generation: Int,
    intentIDs: [UUID]
  ) {
    self.jobID = jobID
    self.operation = operation
    self.repositoryID = repositoryID
    self.repository = repository
    self.repositoryNodeID = repositoryNodeID
    self.objectNodeID = objectNodeID
    self.objectNumber = objectNumber
    self.revision = revision
    self.markerKind = markerKind
    self.authorID = authorID
    self.documentSHA256 = documentSHA256
    self.generation = generation
    self.intentIDs = intentIDs
  }
}

public struct RolloutGitHubSendEffect: Sendable {
  public let jobID: UUID
  public let intentID: UUID
  public let mutation: MutationOperation
  public let target: String
  public let expectedStateSHA256: String
  public let requestSHA256: String
  public let operation: GitHubOperation

  public init(
    jobID: UUID,
    intentID: UUID,
    mutation: MutationOperation,
    target: String,
    expectedStateSHA256: String,
    requestSHA256: String,
    operation: GitHubOperation
  ) {
    self.jobID = jobID
    self.intentID = intentID
    self.mutation = mutation
    self.target = target
    self.expectedStateSHA256 = expectedStateSHA256
    self.requestSHA256 = requestSHA256
    self.operation = operation
  }
}

public struct RolloutGitSendEffect: Sendable {
  public let jobID: UUID
  public let intentID: UUID
  public let repositoryID: UUID
  public let repositoryNodeID: String
  public let branch: String
  public let exactSHA: String
  public let target: String
  public let expectedStateSHA256: String
  public let requestSHA256: String

  public init(
    jobID: UUID,
    intentID: UUID,
    repositoryID: UUID,
    repositoryNodeID: String,
    branch: String,
    exactSHA: String,
    target: String,
    expectedStateSHA256: String,
    requestSHA256: String
  ) {
    self.jobID = jobID
    self.intentID = intentID
    self.repositoryID = repositoryID
    self.repositoryNodeID = repositoryNodeID
    self.branch = branch
    self.exactSHA = exactSHA
    self.target = target
    self.expectedStateSHA256 = expectedStateSHA256
    self.requestSHA256 = requestSHA256
  }
}

public enum RolloutMutationObservation: Sendable {
  case observationRequired
  case attributed
  case settled
}

public protocol RolloutEffectAuthorizing: RolloutGitHubReadAuthorizing,
  RolloutGitRemoteReadAuthorizing, Sendable
{
  func reserveProvider(
    _ effect: RolloutProviderEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func verifyProviderPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect
  ) async throws
  func bindProviderReservation(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect,
    runID: String,
    now: Date
  ) async throws
  func reserveApprovedCommand(
    _ effect: RolloutApprovedCommandEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func verifyApprovedCommandPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutApprovedCommandEffect
  ) async throws
  func bindApprovedCommandReservation(
    _ permit: RolloutEffectPermit,
    effect: RolloutApprovedCommandEffect,
    runID: String,
    now: Date
  ) async throws
  @discardableResult
  func reconcileLocalEffectResults(now: Date) async throws -> Int
  func reserveMarkerBatch(
    _ effect: RolloutMarkerBatchEffect,
    now: Date
  ) async throws -> [RolloutEffectPermit]
  func reserveGitHubSendAndMarkStarted(
    _ effect: RolloutGitHubSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func reserveGitSendAndMarkStarted(
    _ effect: RolloutGitSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit
  func verifyGitHubSendPermit(
    _ permit: RolloutEffectPermit,
    operation: GitHubOperation
  ) async throws
  func verifyGitSendPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitSendEffect
  ) async throws
  func recordMutationObservation(
    intentID: UUID,
    observation: RolloutMutationObservation,
    evidenceSHA256: String,
    now: Date
  ) async throws
  func settleEffect(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws
  func closeAdmission() async
  func openAdmission() async throws
  func waitForDrain(until deadline: Date) async -> Bool
}

extension RolloutEffectAuthorizing {
  public func settleGitRemoteRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    try await settleEffect(permit, evidenceSHA256: evidenceSHA256, now: now)
  }
}

extension GitHubOperation {
  var repositoryCoordinates: GitHubRepositoryCoordinates? {
    switch self {
    case .authenticatedIdentity:
      nil
    case .repository(let owner, let repository),
      .listPullRequests(let owner, let repository, _, _, _),
      .pullRequest(let owner, let repository, _),
      .listPullRequestCommits(let owner, let repository, _, _),
      .createPullRequest(let owner, let repository, _),
      .listIssues(let owner, let repository, _),
      .issue(let owner, let repository, _),
      .listComments(let owner, let repository, _, _),
      .createComment(let owner, let repository, _, _),
      .listIssueLabels(let owner, let repository, _, _),
      .addIssueLabels(let owner, let repository, _, _),
      .removeIssueLabel(let owner, let repository, _, _),
      .listRepositoryLabels(let owner, let repository, _),
      .repositoryLabel(let owner, let repository, _),
      .createRepositoryLabel(let owner, let repository, _),
      .branchReference(let owner, let repository, _):
      GitHubRepositoryCoordinates(owner: owner, repository: repository)
    }
  }

  var objectNumber: Int? {
    switch self {
    case .pullRequest(_, _, let number),
      .listPullRequestCommits(_, _, let number, _),
      .issue(_, _, let number),
      .listComments(_, _, let number, _),
      .createComment(_, _, let number, _),
      .listIssueLabels(_, _, let number, _),
      .addIssueLabels(_, _, let number, _),
      .removeIssueLabel(_, _, let number, _):
      number
    default:
      nil
    }
  }
}
