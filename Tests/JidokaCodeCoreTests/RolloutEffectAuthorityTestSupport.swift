import Foundation

@testable import JidokaCodeCore

/// An explicit, finite permit issuer for unit tests that do not construct a schema-10 rollout.
/// Production composition must always use `RolloutAuthorityStore`.
actor ExplicitTestRolloutEffectAuthority: RolloutEffectAuthorizing {
  private enum PermitKind: Equatable, Sendable {
    case githubRead
    case gitRead
    case provider
    case command
    case githubSend
    case gitSend
  }

  private let intents: MutationIntentStore?
  private let closeAfterGitReadReservation: Bool
  private let failGitReadSettlement: Bool
  private var admissionOpen = true
  private var permits: [String: PermitKind] = [:]
  private var verifiedReadPermits: Set<String> = []
  private var markerPermitIDs: [UUID: String] = [:]
  private var activeSendPermitIDs: [UUID: String] = [:]

  init(
    intents: MutationIntentStore? = nil,
    closeAfterGitReadReservation: Bool = false,
    failGitReadSettlement: Bool = false
  ) {
    self.intents = intents
    self.closeAfterGitReadReservation = closeAfterGitReadReservation
    self.failGitReadSettlement = failGitReadSettlement
  }

  func reserveGitHubRead(
    _ effect: RolloutGitHubReadEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    try denyHistoricalContext()
    guard admissionOpen, !effect.operation.kind.isWrite, effect.maximumResponseBytes > 0 else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    return issue(.githubRead)
  }

  func settleGitHubRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256 _: String,
    now _: Date
  ) throws {
    try settle(permit, expected: .githubRead)
  }

  func verifyGitHubReadPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutGitHubReadEffect
  ) throws {
    try denyHistoricalContext()
    guard admissionOpen || effect.context.isReadback else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try require(permit, expected: .githubRead)
    guard let id = permitID(permit), verifiedReadPermits.insert(id).inserted else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  func reserveGitRemoteRead(
    _ effect: RolloutGitRemoteReadEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    try denyHistoricalContext()
    guard admissionOpen, !effect.target.isEmpty else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    let permit = issue(.gitRead)
    if closeAfterGitReadReservation { admissionOpen = false }
    return permit
  }

  func verifyGitRemoteReadPermit(
    _ permit: RolloutEffectPermit,
    effect _: RolloutGitRemoteReadEffect
  ) throws {
    try denyHistoricalContext()
    guard admissionOpen || RolloutEffectTaskContext.current?.isReadback == true else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try require(permit, expected: .gitRead)
    guard let id = permitID(permit), verifiedReadPermits.insert(id).inserted else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  func settleGitRemoteRead(
    _ permit: RolloutEffectPermit,
    evidenceSHA256: String,
    now: Date
  ) async throws {
    // Opt-in failure for the transport's failure path: the permit stays outstanding,
    // as a store whose settlement transaction failed would leave it.
    if failGitReadSettlement { throw RolloutAuthorityError.effectIdentityMismatch }
    try await settleEffect(permit, evidenceSHA256: evidenceSHA256, now: now)
  }

  func reserveProvider(
    _ effect: RolloutProviderEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    try denyHistoricalContext()
    guard admissionOpen, !effect.runNonce.isEmpty else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    return issue(.provider)
  }

  func verifyProviderPermit(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect
  ) throws {
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID, jobID == effect.jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try denyHistoricalContext()
    try require(permit, expected: .provider)
  }

  func bindProviderReservation(
    _ permit: RolloutEffectPermit,
    effect: RolloutProviderEffect,
    runID: String,
    now _: Date
  ) throws {
    guard !runID.isEmpty else { throw RolloutAuthorityError.effectIdentityMismatch }
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID, jobID == effect.jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try denyHistoricalContext()
    try require(permit, expected: .provider)
  }

  func reserveApprovedCommand(
    _ effect: RolloutApprovedCommandEffect,
    now _: Date
  ) throws -> RolloutEffectPermit {
    guard RolloutPreviewBuilder.validIdentifier(effect.commandID, maximum: 128),
      GitHubInputValidation.validSHA256(effect.definitionSHA256),
      GitHubInputValidation.validSHA256(effect.planSHA256),
      GitHubInputValidation.validGitSHA(effect.workspaceHeadSHA),
      (1...3).contains(effect.round), effect.ordinal >= 0,
      case .workflow(let jobID) = RolloutEffectTaskContext.current?.mode,
      jobID == effect.jobID
    else { throw RolloutAuthorityError.effectIdentityMismatch }
    guard admissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    return issue(.command)
  }

  func verifyApprovedCommandPermit(
    _ permit: RolloutEffectPermit,
    effect _: RolloutApprovedCommandEffect
  ) throws {
    try denyHistoricalContext()
    guard admissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    try require(permit, expected: .command)
  }

  func bindApprovedCommandReservation(
    _ permit: RolloutEffectPermit,
    effect _: RolloutApprovedCommandEffect,
    runID: String,
    now _: Date
  ) throws {
    try denyHistoricalContext()
    guard admissionOpen, !runID.isEmpty else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    try require(permit, expected: .command)
  }

  func reconcileLocalEffectResults(now _: Date) -> Int {
    0
  }

  func reserveMarkerBatch(
    _ effect: RolloutMarkerBatchEffect,
    now _: Date
  ) throws -> [RolloutEffectPermit] {
    try denyHistoricalContext()
    guard admissionOpen,
      !effect.intentIDs.isEmpty,
      Set(effect.intentIDs).count == effect.intentIDs.count
    else {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    return effect.intentIDs.map { intentID in
      let permit = issue(.githubSend)
      if case .reservation(let id) = permit {
        markerPermitIDs[intentID] = id
      }
      return permit
    }
  }

  func reserveGitHubSendAndMarkStarted(
    _ effect: RolloutGitHubSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    try denyHistoricalContext()
    guard admissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    let permit: RolloutEffectPermit
    if let id = markerPermitIDs.removeValue(forKey: effect.intentID) {
      permit = .reservation(id: id)
    } else {
      permit = issue(.githubSend)
    }
    if let intents {
      do {
        _ = try await intents.markSendStarted(id: effect.intentID, now: now)
      } catch {
        remove(permit)
        throw error
      }
    }
    if case .reservation(let id) = permit {
      activeSendPermitIDs[effect.intentID] = id
    }
    return permit
  }

  func reserveGitSendAndMarkStarted(
    _ effect: RolloutGitSendEffect,
    now: Date
  ) async throws -> RolloutEffectPermit {
    if case .historicalCanary = RolloutEffectTaskContext.current?.mode {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    guard admissionOpen else { throw RolloutAuthorityError.effectAdmissionClosed }
    let permit = issue(.gitSend)
    if let intents {
      do {
        _ = try await intents.markSendStarted(id: effect.intentID, now: now)
      } catch {
        remove(permit)
        throw error
      }
    }
    if case .reservation(let id) = permit {
      activeSendPermitIDs[effect.intentID] = id
    }
    return permit
  }

  func verifyGitHubSendPermit(
    _ permit: RolloutEffectPermit,
    operation _: GitHubOperation
  ) throws {
    try denyHistoricalContext()
    try require(permit, expected: .githubSend)
  }

  func verifyGitSendPermit(
    _ permit: RolloutEffectPermit,
    effect _: RolloutGitSendEffect
  ) throws {
    if case .historicalCanary = RolloutEffectTaskContext.current?.mode {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    try require(permit, expected: .gitSend)
  }

  func recordMutationObservation(
    intentID: UUID,
    observation: RolloutMutationObservation,
    evidenceSHA256 _: String,
    now _: Date
  ) throws {
    try denyHistoricalContext()
    if case .settled = observation,
      let id = activeSendPermitIDs.removeValue(forKey: intentID)
    {
      permits.removeValue(forKey: id)
    }
  }

  func settleEffect(
    _ permit: RolloutEffectPermit,
    evidenceSHA256 _: String,
    now _: Date
  ) throws {
    if case .historicalCanary(let jobID) = permit {
      guard
        case .historicalCanary(let contextualJobID) =
          RolloutEffectTaskContext.current?.mode,
        contextualJobID == jobID
      else {
        throw RolloutAuthorityError.effectIdentityMismatch
      }
      throw RolloutAuthorityError.effectAdmissionClosed
    }
    guard let kind = kind(for: permit),
      kind == .gitRead || kind == .provider || kind == .command
    else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
    remove(permit)
  }

  func closeAdmission() {
    admissionOpen = false
  }

  func openAdmission() {
    admissionOpen = true
  }

  func waitForDrain(until _: Date) -> Bool {
    permits.isEmpty
  }

  private func issue(_ kind: PermitKind) -> RolloutEffectPermit {
    let id = UUID().uuidString.lowercased()
    permits[id] = kind
    return .reservation(id: id)
  }

  private func denyHistoricalContext() throws {
    if case .historicalCanary = RolloutEffectTaskContext.current?.mode {
      throw RolloutAuthorityError.effectAdmissionClosed
    }
  }

  private func settle(_ permit: RolloutEffectPermit, expected: PermitKind) throws {
    try require(permit, expected: expected)
    remove(permit)
  }

  private func require(_ permit: RolloutEffectPermit, expected: PermitKind) throws {
    guard let kind = kind(for: permit), kind == expected else {
      throw RolloutAuthorityError.effectIdentityMismatch
    }
  }

  private func kind(for permit: RolloutEffectPermit) -> PermitKind? {
    switch permit {
    case .reservation(let id), .scopeRead(let id), .readback(let id),
      .gitReadback(let id), .boundedRead(let id):
      permits[id]
    case .historicalCanary:
      nil
    }
  }

  private func remove(_ permit: RolloutEffectPermit) {
    if let id = permitID(permit) {
      permits.removeValue(forKey: id)
      verifiedReadPermits.remove(id)
    }
  }

  private func permitID(_ permit: RolloutEffectPermit) -> String? {
    switch permit {
    case .reservation(let id), .scopeRead(let id), .readback(let id),
      .gitReadback(let id), .boundedRead(let id):
      id
    case .historicalCanary:
      nil
    }
  }
}

actor ExplicitlyAuthorizedTestGitPublisher {
  private let publisher: GitPublisher
  private let authority: ExplicitTestRolloutEffectAuthority
  private let jobID = UUID()
  private let now = Date(timeIntervalSince1970: 1)

  init(
    transport: any GitPublicationTransporting,
    authority: ExplicitTestRolloutEffectAuthority = ExplicitTestRolloutEffectAuthority()
  ) {
    publisher = GitPublisher(transport: transport)
    self.authority = authority
  }

  func publishCreateOnly(
    branch: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)? = nil
  ) async throws -> GitPublicationResult {
    let reference = "refs/heads/\(branch)"
    let intentID = UUID()
    let effect = RolloutGitSendEffect(
      jobID: jobID,
      intentID: intentID,
      repositoryID: remote.repositoryID,
      repositoryNodeID: remote.nodeID,
      branch: branch,
      exactSHA: exactSHA,
      target: "repository:\(remote.nodeID):\(reference)",
      expectedStateSHA256: GitHubMarkerCodec.sha256(Data("test-before-state".utf8)),
      requestSHA256: GitHubMarkerCodec.sha256(
        Data("test-git-send:\(remote.nodeID):\(reference):\(exactSHA)".utf8)
      )
    )
    return try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
    ) {
      try await publisher.publishCreateOnly(
        branch: branch,
        exactSHA: exactSHA,
        remote: remote,
        repository: repository,
        credentials: credentials
      ) {
        let permit = try await self.authority.reserveGitSendAndMarkStarted(
          effect,
          now: self.now
        )
        return (permit, effect)
      }
    }
  }
}

enum TestRolloutFixtureError: Error {
  case invalidJob
}

func withTestRolloutWorkflow<Value: Sendable>(
  jobID: UUID,
  operation: () async throws -> Value
) async rethrows -> Value {
  try await RolloutEffectTaskContext.$current.withValue(
    RolloutEffectExecutionContext(mode: .workflow(jobID: jobID)),
    operation: operation
  )
}

func activateTestImplementationRollout(
  database: SQLiteStore,
  repository: RepositoryConfiguration,
  job: JobRecord,
  plan: FrozenCommandPlan,
  workspaceHeadSHA: String,
  now: Date,
  currentTime: @escaping @Sendable () -> Date = Date.init,
  includeGitPublicationBudget: Bool = false
) async throws -> RolloutAuthorityStore {
  guard let objectNumber = job.objectNumber,
    let currentStep = job.currentStepKind
  else {
    throw TestRolloutFixtureError.invalidJob
  }
  let configuration = ConfigurationStore(database: database)
  let tokenSHA256 = GitHubMarkerCodec.sha256(Data("test-rollout-token".utf8))
  _ = try await configuration.prepareCredentialReplacement(
    account: repository.owner,
    authorID: 7,
    tokenSHA256: tokenSHA256,
    now: now
  )
  try await configuration.commitCredentialReplacement(
    account: repository.owner,
    authorID: 7,
    tokenSHA256: tokenSHA256,
    now: now
  )
  try await configuration.setMaxConcurrency(1, now: now)

  let authority = RolloutAuthorityStore(database: database, now: currentTime)
  let baseLocal = try await authority.localEvidence(repositoryID: repository.id)
  let fixedDigest = GitHubMarkerCodec.sha256(Data("test-release-evidence".utf8))
  let object = RolloutObjectSelector(
    nodeID: job.identity.objectNodeID,
    number: objectNumber,
    revisionKey: job.identity.revisionKey,
    canonicalInputSHA256: GitHubMarkerCodec.sha256(
      Data("test-input:\(job.identity.objectNodeID):\(job.identity.revisionKey)".utf8)
    ),
    baseSHA: workspaceHeadSHA,
    planSHA256: plan.digest,
    labelStateSHA256: GitHubMarkerCodec.sha256(Data("test-label-state".utf8)),
    currentStep: currentStep.rawValue
  )
  let scope = RolloutScope(
    mode: .exactObject,
    stage: .implementationExecute,
    repository: RolloutRepositoryIdentity(
      id: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      enabled: repository.enabled,
      reviewEnabled: repository.reviewEnabled,
      triageEnabled: repository.triageEnabled,
      implementationEnabled: repository.implementationEnabled
    ),
    object: object,
    finiteWindow: nil
  )
  let commands = plan.commandOrder.enumerated().map { ordinal, commandID in
    RolloutCommandBinding(
      ordinal: ordinal,
      commandID: commandID,
      definitionSHA256: plan.commands[commandID]!.definitionDigest,
      frozenPlanSHA256: plan.digest,
      workspaceHeadSHA: workspaceHeadSHA
    )
  }
  let jobBinding = RolloutJobBinding(
    jobID: job.id,
    jobKind: job.identity.kind,
    objectNumber: objectNumber,
    contractVersion: job.contractVersionUsed,
    priority: job.priority,
    firstStep: .orchestrate,
    currentStep: currentStep.rawValue
  )
  let local = try await authority.localEvidence(scope: scope, jobBinding: jobBinding)
  let createdAtMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
  let input = RolloutPreviewInput(
    releaseIdentity: RolloutReleaseIdentity(
      sourceCommit: workspaceHeadSHA,
      sourceTree: workspaceHeadSHA,
      bundleVersion: "0.2.0",
      bundleBuild: 3,
      applicationSHA256: fixedDigest,
      helperSHA256: fixedDigest,
      askPassSHA256: fixedDigest,
      pushGuardSHA256: fixedDigest,
      herdrHostSHA256: fixedDigest,
      schemaVersion: 10,
      engineProtocolVersion: 12,
      runtimeManifestSHA256: fixedDigest,
      runtimeTreeSHA256: fixedDigest,
      modelProfilesSHA256: baseLocal.modelProfilesSHA256,
      workflowResourcesSHA256: fixedDigest,
      githubAccount: repository.owner,
      githubAuthorID: 7,
      repositoryConfigurationSHA256: baseLocal.repositoryConfigurationSHA256,
      maxConcurrency: 1
    ),
    scope: scope,
    budgets: RolloutBudgets(
      jobs: 1,
      githubReadRequests: 0,
      githubReadPages: 0,
      githubReadBytes: 0,
      gitRemoteReads: includeGitPublicationBudget ? 2 : 0,
      providerSessions: 0,
      approvedCommands: commands.count,
      markerParts: 0,
      labelWrites: 0,
      branchCreates: includeGitPublicationBudget ? 1 : 0,
      pullRequestCreates: 0,
      githubSends: 0,
      gitSends: includeGitPublicationBudget ? 1 : 0
    ),
    inventory: local.inventory,
    missingLabels: [],
    commands: commands,
    jobBinding: jobBinding,
    createdAtMilliseconds: createdAtMilliseconds,
    expiresAtMilliseconds: createdAtMilliseconds + 600_000
  )
  let preview = try await authority.preview(input: input)
  _ = try await authority.activate(
    approvedCanonicalJSON: preview.canonicalJSON,
    confirmedSHA256: preview.sha256,
    recomputedInput: input,
    now: now.addingTimeInterval(1)
  )
  return authority
}

func activateTestPullRequestRollout(
  database: SQLiteStore,
  repository: RepositoryConfiguration,
  job: JobRecord,
  baseSHA: String,
  headSHA: String,
  now: Date
) async throws -> RolloutAuthorityStore {
  guard let objectNumber = job.objectNumber,
    let currentStep = job.currentStepKind
  else {
    throw TestRolloutFixtureError.invalidJob
  }
  let configuration = ConfigurationStore(database: database)
  let tokenSHA256 = GitHubMarkerCodec.sha256(Data("test-rollout-token".utf8))
  _ = try await configuration.prepareCredentialReplacement(
    account: repository.owner,
    authorID: 7,
    tokenSHA256: tokenSHA256,
    now: now
  )
  try await configuration.commitCredentialReplacement(
    account: repository.owner,
    authorID: 7,
    tokenSHA256: tokenSHA256,
    now: now
  )
  try await configuration.setMaxConcurrency(1, now: now)

  let authority = RolloutAuthorityStore(database: database)
  let baseLocal = try await authority.localEvidence(repositoryID: repository.id)
  let fixedDigest = GitHubMarkerCodec.sha256(Data("test-release-evidence".utf8))
  let object = RolloutObjectSelector(
    nodeID: job.identity.objectNodeID,
    number: objectNumber,
    revisionKey: job.identity.revisionKey,
    canonicalInputSHA256: GitHubMarkerCodec.sha256(
      Data("test-input:\(job.identity.objectNodeID):\(job.identity.revisionKey)".utf8)
    ),
    headSHA: headSHA,
    baseSHA: baseSHA,
    narrativeSHA256: GitHubMarkerCodec.sha256(Data("test-review-narrative".utf8)),
    currentStep: currentStep.rawValue
  )
  let scope = RolloutScope(
    mode: .exactObject,
    stage: .prReview,
    repository: RolloutRepositoryIdentity(
      id: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      enabled: repository.enabled,
      reviewEnabled: repository.reviewEnabled,
      triageEnabled: repository.triageEnabled,
      implementationEnabled: repository.implementationEnabled
    ),
    object: object,
    finiteWindow: nil
  )
  let jobBinding = RolloutJobBinding(
    jobID: job.id,
    jobKind: job.identity.kind,
    objectNumber: objectNumber,
    contractVersion: job.contractVersionUsed,
    priority: job.priority,
    firstStep: .review,
    currentStep: currentStep.rawValue
  )
  let local = try await authority.localEvidence(scope: scope, jobBinding: jobBinding)
  let input = RolloutPreviewInput(
    releaseIdentity: RolloutReleaseIdentity(
      sourceCommit: headSHA,
      sourceTree: headSHA,
      bundleVersion: "0.2.0",
      bundleBuild: 3,
      applicationSHA256: fixedDigest,
      helperSHA256: fixedDigest,
      askPassSHA256: fixedDigest,
      pushGuardSHA256: fixedDigest,
      herdrHostSHA256: fixedDigest,
      schemaVersion: 10,
      engineProtocolVersion: 12,
      runtimeManifestSHA256: fixedDigest,
      runtimeTreeSHA256: fixedDigest,
      modelProfilesSHA256: baseLocal.modelProfilesSHA256,
      workflowResourcesSHA256: fixedDigest,
      githubAccount: repository.owner,
      githubAuthorID: 7,
      repositoryConfigurationSHA256: baseLocal.repositoryConfigurationSHA256,
      maxConcurrency: 1
    ),
    scope: scope,
    budgets: RolloutBudgets(
      jobs: 1,
      githubReadRequests: 64,
      githubReadPages: 64,
      githubReadBytes: 1_048_576,
      gitRemoteReads: 8,
      providerSessions: 4,
      approvedCommands: 0,
      markerParts: 8,
      labelWrites: 0,
      branchCreates: 0,
      pullRequestCreates: 0,
      githubSends: 8,
      gitSends: 0
    ),
    inventory: local.inventory,
    missingLabels: [],
    commands: [],
    jobBinding: jobBinding,
    createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
    expiresAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000) + 600_000
  )
  let preview = try await authority.preview(input: input)
  _ = try await authority.activate(
    approvedCanonicalJSON: preview.canonicalJSON,
    confirmedSHA256: preview.sha256,
    recomputedInput: input,
    now: now.addingTimeInterval(1)
  )
  return authority
}
