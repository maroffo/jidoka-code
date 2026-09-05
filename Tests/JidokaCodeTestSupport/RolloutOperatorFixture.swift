import Foundation
import JidokaCodeCore

public struct RolloutOperatorFixture: Sendable {
  public let exactInput: RolloutPreviewInput
  public let exactActivation: RolloutActivationRequest
  public let finiteInput: RolloutPreviewInput
  public let finiteActivation: RolloutActivationRequest
  public let stop: RolloutStopRequest
  public let recoveryRequest: RolloutRecoveryRequest
  public let recoveryAuthorization: RolloutRecoveryAuthorization
}

public func rolloutOperatorFixture() throws -> RolloutOperatorFixture {
  let digest = String(repeating: "a", count: 64)
  let repositoryID = UUID(uuidString: "81000000-0000-4000-8000-000000000081")!
  let authorizationID = UUID(uuidString: "82000000-0000-4000-8000-000000000082")!
  let jobID = UUID(uuidString: "83000000-0000-4000-8000-000000000083")!
  let repository = RolloutRepositoryIdentity(
    id: repositoryID,
    nodeID: "R_protocol",
    owner: "owner",
    name: "repo",
    defaultBranch: "main",
    enabled: true,
    reviewEnabled: true,
    triageEnabled: false,
    implementationEnabled: false
  )
  let release = RolloutReleaseIdentity(
    sourceCommit: String(repeating: "1", count: 40),
    sourceTree: String(repeating: "2", count: 40),
    bundleVersion: "0.2.0",
    bundleBuild: 3,
    applicationSHA256: digest,
    helperSHA256: digest,
    askPassSHA256: digest,
    pushGuardSHA256: digest,
    herdrHostSHA256: digest,
    schemaVersion: 10,
    engineProtocolVersion: 12,
    runtimeManifestSHA256: digest,
    runtimeTreeSHA256: digest,
    modelProfilesSHA256: digest,
    workflowResourcesSHA256: digest,
    githubAccount: "owner",
    githubAuthorID: 1,
    repositoryConfigurationSHA256: digest,
    maxConcurrency: 1
  )
  let inventory = RolloutInventory(
    queueSHA256: digest,
    recoverySHA256: digest,
    mutationIntentSHA256: digest,
    queueItemCount: 0,
    recoveryItemCount: 0,
    mutationItemCount: 0,
    outsideScopeQueueSHA256: digest,
    outsideScopeRecoverySHA256: digest,
    outsideScopeMutationIntentSHA256: digest,
    outsideScopeQueueItemCount: 0,
    outsideScopeRecoveryItemCount: 0,
    outsideScopeMutationItemCount: 0
  )
  let budgets = RolloutBudgets(
    jobs: 1,
    githubReadRequests: 10,
    githubReadPages: 10,
    githubReadBytes: 1_000_000,
    gitRemoteReads: 1,
    providerSessions: 4,
    approvedCommands: 0,
    markerParts: 2,
    labelWrites: 0,
    branchCreates: 0,
    pullRequestCreates: 0,
    githubSends: 2,
    gitSends: 0
  )
  let exactInput = RolloutPreviewInput(
    releaseIdentity: release,
    scope: RolloutScope(
      mode: .exactObject,
      stage: .prReview,
      repository: repository,
      object: RolloutObjectSelector(
        nodeID: "PR_protocol",
        number: 7,
        revisionKey: String(repeating: "3", count: 40),
        canonicalInputSHA256: String(repeating: "b", count: 64),
        headSHA: String(repeating: "3", count: 40),
        baseSHA: String(repeating: "4", count: 40),
        narrativeSHA256: String(repeating: "c", count: 64),
        currentStep: JobStepKind.review.rawValue
      ),
      finiteWindow: nil
    ),
    budgets: budgets,
    inventory: inventory,
    missingLabels: [],
    commands: [],
    jobBinding: RolloutJobBinding(
      jobID: jobID,
      jobKind: .prReview,
      objectNumber: 7,
      contractVersion: "pr-review-v1",
      priority: .prReview,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    ),
    createdAtMilliseconds: 1_000,
    expiresAtMilliseconds: 601_000
  )
  let exactPreview = try RolloutPreviewBuilder.make(exactInput)
  let exactActivation = RolloutActivationRequest(
    authorizationID: authorizationID,
    approvedCanonicalJSON: exactPreview.canonicalJSON,
    confirmedSHA256: exactPreview.sha256
  )
  let finiteInput = RolloutPreviewInput(
    releaseIdentity: release,
    scope: RolloutScope(
      mode: .finiteWindow,
      stage: .prReview,
      repository: repository,
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: 1,
        expiresAtMilliseconds: 3_601_000,
        allowsFutureObjects: true,
        observedObjectNumberUpperBound: 7,
        maximumFutureObjectNumber: 12,
        candidates: []
      )
    ),
    budgets: budgets,
    inventory: inventory,
    missingLabels: [],
    commands: [],
    jobBinding: nil,
    createdAtMilliseconds: 1_000,
    expiresAtMilliseconds: 601_000
  )
  let finitePreview = try RolloutPreviewBuilder.make(finiteInput)
  let finiteActivation = RolloutActivationRequest(
    authorizationID: UUID(uuidString: "84000000-0000-4000-8000-000000000084")!,
    approvedCanonicalJSON: finitePreview.canonicalJSON,
    confirmedSHA256: finitePreview.sha256
  )
  let recoveryReport = RolloutStatusReport(
    authorization: RolloutAuthorization(
      id: authorizationID.uuidString.lowercased(),
      previewSHA256: exactPreview.sha256,
      state: .recoveryRequired,
      scopeMode: .exactObject,
      workflowStage: .prReview,
      repositoryID: repositoryID,
      activatedAtMilliseconds: 1_500,
      expiresAtMilliseconds: 601_000,
      updatedAtMilliseconds: 2_000,
      terminalReason: nil
    ),
    releaseIdentity: release,
    scope: exactInput.scope,
    effectEnvelope: exactPreview.payload.effectEnvelope,
    missingLabels: [],
    commands: [],
    initialBudgets: budgets,
    remainingBudgets: budgets,
    boundJobIDs: [jobID],
    reservations: [],
    events: []
  )
  let recoveryPreview = try RolloutRecoveryPreviewBuilder.make(
    report: recoveryReport,
    createdAtMilliseconds: 2_000
  )
  return RolloutOperatorFixture(
    exactInput: exactInput,
    exactActivation: exactActivation,
    finiteInput: finiteInput,
    finiteActivation: finiteActivation,
    stop: RolloutStopRequest(
      authorizationID: authorizationID.uuidString.lowercased(),
      previewSHA256: exactPreview.sha256,
      timeoutMilliseconds: 10_000
    ),
    recoveryRequest: RolloutRecoveryRequest(
      authorizationID: authorizationID.uuidString.lowercased(),
      previewSHA256: exactPreview.sha256
    ),
    recoveryAuthorization: RolloutRecoveryAuthorization(
      approvedCanonicalJSON: recoveryPreview.canonicalJSON,
      confirmedSHA256: recoveryPreview.sha256
    )
  )
}
