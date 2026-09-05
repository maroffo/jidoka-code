import Darwin
import Foundation

protocol RolloutPreviewIdentityReading: Sendable {
  func authenticatedIdentity() async throws -> GitHubUser
}

protocol RolloutPreviewRepositoryReading: GitHubReadAPI, GitHubMutationReadAPI,
  GitHubPullRequestCommitAPI
{
  func repository(
    owner: String,
    repository: String,
    expectedNodeID: String?
  ) async throws -> GitHubRepository
  func listRepositoryLabels(owner: String, repository: String) async throws -> [GitHubLabel]
}

extension GitHubBroker: RolloutPreviewIdentityReading, RolloutPreviewRepositoryReading {}

protocol RolloutPreviewGitInspecting: Sendable {
  func derivePullRequest(
    repository: RolloutRepositoryIdentity,
    number: Int,
    baseSHA: String,
    headSHA: String,
    jobID: UUID
  ) async throws -> PullRequestCommitDerivation
}

enum RolloutRemotePreviewError: Error, Equatable, Sendable {
  case unavailable
  case unsafeCache
  case cacheLimitExceeded
  case cacheCleanupFailed
}

struct ProductionRolloutPreviewGitInspector: RolloutPreviewGitInspecting, Sendable {
  static let maximumCacheEntries = 100_000
  static let maximumAllocatedCacheBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

  private let cacheRoot: URL
  private let askPassExecutable: URL
  private let broker: GitHubBroker
  private let readAuthority: any RolloutGitRemoteReadAuthorizing
  private let now: @Sendable () -> Date

  init(
    cacheRoot: URL,
    askPassExecutable: URL,
    broker: GitHubBroker,
    readAuthority: any RolloutGitRemoteReadAuthorizing,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.cacheRoot = cacheRoot.standardizedFileURL
    self.askPassExecutable = askPassExecutable.standardizedFileURL
    self.broker = broker
    self.readAuthority = readAuthority
    self.now = now
  }

  func derivePullRequest(
    repository: RolloutRepositoryIdentity,
    number: Int,
    baseSHA: String,
    headSHA: String,
    jobID: UUID
  ) async throws -> PullRequestCommitDerivation {
    try Self.ensurePrivateDirectory(cacheRoot)
    let operationRoot = cacheRoot.appendingPathComponent(
      "preview-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: operationRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    var originalRoot = stat()
    guard lstat(operationRoot.path, &originalRoot) == 0,
      originalRoot.st_mode & S_IFMT == S_IFDIR,
      originalRoot.st_uid == geteuid(),
      originalRoot.st_mode & 0o077 == 0
    else {
      throw RolloutRemotePreviewError.unsafeCache
    }

    var result: PullRequestCommitDerivation?
    var operationError: (any Error)?
    do {
      guard let repositoryID = UUID(uuidString: repository.id),
        repositoryID.uuidString.lowercased() == repository.id
      else {
        throw RolloutAuthorityError.invalidRepositoryIdentity
      }
      let configuration = RepositoryConfiguration(
        id: repositoryID,
        nodeID: repository.nodeID,
        owner: repository.owner,
        name: repository.name,
        defaultBranch: repository.defaultBranch,
        reviewEnabled: repository.reviewEnabled,
        triageEnabled: repository.triageEnabled,
        implementationEnabled: repository.implementationEnabled,
        enabled: repository.enabled
      )
      let remote = try GitRemoteRepository(repository: configuration)
      let ipc = operationRoot.appendingPathComponent("IPC", isDirectory: true)
      let mirror = operationRoot.appendingPathComponent("pull-request.git", isDirectory: true)
      let git = SystemGitTransport(
        temporaryDirectory: operationRoot.path,
        rolloutReadAuthority: readAuthority,
        now: now
      )
      let credentials = try GitHubGitCredentialProvider(
        broker: broker,
        socketDirectory: ipc,
        askPassExecutable: askPassExecutable
      )
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
      ) {
        try await git.preparePullRequestPreviewRepository(
          number: number,
          baseBranch: repository.defaultBranch,
          expectedBaseSHA: baseSHA,
          expectedHeadSHA: headSHA,
          jobID: jobID,
          remote: remote,
          destination: mirror,
          credentials: credentials
        )
      }
      try Self.requireBoundedCache(operationRoot)
      result = try await GitPullRequestCommitDeriver(git: git).derive(
        baseSHA: baseSHA,
        headSHA: headSHA,
        mirror: mirror
      )
      try Self.requireBoundedCache(operationRoot)
    } catch {
      operationError = error
    }

    do {
      try Self.removeExactDirectory(operationRoot, original: originalRoot)
    } catch {
      throw RolloutRemotePreviewError.cacheCleanupFailed
    }
    if let operationError { throw operationError }
    guard let result else { throw RolloutRemotePreviewError.unavailable }
    return result
  }

  private static func ensurePrivateDirectory(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw RolloutRemotePreviewError.unsafeCache
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw RolloutRemotePreviewError.unsafeCache
    }
  }

  private static func requireBoundedCache(_ root: URL) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      )
    else {
      throw RolloutRemotePreviewError.unsafeCache
    }
    var entries = 0
    var allocatedBytes: Int64 = 0
    for case let candidate as URL in enumerator {
      entries += 1
      guard entries <= maximumCacheEntries else {
        throw RolloutRemotePreviewError.cacheLimitExceeded
      }
      var metadata = stat()
      guard lstat(candidate.path, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR || metadata.st_mode & S_IFMT == S_IFREG
      else {
        throw RolloutRemotePreviewError.unsafeCache
      }
      if metadata.st_mode & S_IFMT == S_IFREG {
        let blocks = Int64(metadata.st_blocks)
        guard blocks >= 0, blocks <= (maximumAllocatedCacheBytes - allocatedBytes) / 512 else {
          throw RolloutRemotePreviewError.cacheLimitExceeded
        }
        allocatedBytes += blocks * 512
      }
    }
  }

  private static func removeExactDirectory(_ url: URL, original: stat) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0,
      current.st_mode & S_IFMT == S_IFDIR,
      current.st_dev == original.st_dev,
      current.st_ino == original.st_ino
    else {
      throw RolloutRemotePreviewError.unsafeCache
    }
    try FileManager.default.removeItem(at: url)
    guard lstat(url.path, &current) != 0, errno == ENOENT else {
      throw RolloutRemotePreviewError.cacheCleanupFailed
    }
  }
}

struct RolloutRemotePreviewRevalidator: Sendable {
  private let identity: any RolloutPreviewIdentityReading
  private let api: any RolloutPreviewRepositoryReading
  private let git: any RolloutPreviewGitInspecting
  private let jobs: DurableJobStore
  private let intents: MutationIntentStore
  private let reviewedRevisions: ReviewedRevisionStore

  init(
    identity: any RolloutPreviewIdentityReading,
    api: any RolloutPreviewRepositoryReading,
    git: any RolloutPreviewGitInspecting,
    jobs: DurableJobStore,
    intents: MutationIntentStore,
    reviewedRevisions: ReviewedRevisionStore
  ) {
    self.identity = identity
    self.api = api
    self.git = git
    self.jobs = jobs
    self.intents = intents
    self.reviewedRevisions = reviewedRevisions
  }

  func revalidate(_ preview: RolloutPreview) async throws {
    do {
      let rebuilt = try RolloutPreviewBuilder.parseCanonical(preview.canonicalJSON)
      guard rebuilt == preview else { throw RolloutAuthorityError.previewDrift }
      let account = try await identity.authenticatedIdentity()
      guard account.id == preview.payload.releaseIdentity.githubAuthorID,
        account.login.caseInsensitiveCompare(
          preview.payload.releaseIdentity.githubAccount
        ) == .orderedSame
      else {
        throw RolloutAuthorityError.previewDrift
      }
      let scope = preview.payload.scope
      let repository = try await api.repository(
        owner: scope.repository.owner,
        repository: scope.repository.name,
        expectedNodeID: scope.repository.nodeID
      )
      guard repository.nodeID == scope.repository.nodeID,
        repository.owner.login.caseInsensitiveCompare(scope.repository.owner) == .orderedSame,
        repository.name.caseInsensitiveCompare(scope.repository.name) == .orderedSame,
        repository.defaultBranch == scope.repository.defaultBranch
      else {
        throw RolloutAuthorityError.previewDrift
      }
      try await validateMissingLabels(preview)
      switch scope.mode {
      case .exactObject:
        try await validateExact(preview)
      case .finiteWindow:
        try await validateFinite(preview)
      }
    } catch let error as RolloutAuthorityError {
      throw error
    } catch {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private func validateMissingLabels(_ preview: RolloutPreview) async throws {
    switch preview.payload.scope.stage {
    case .prReview, .generatedPRReview:
      guard preview.payload.missingLabels.isEmpty else {
        throw RolloutAuthorityError.previewDrift
      }
      return
    case .issueTriage, .implementationPlan, .implementationExecute:
      break
    }
    let repository = preview.payload.scope.repository
    let observed = try await api.listRepositoryLabels(
      owner: repository.owner,
      repository: repository.name
    )
    guard observed.count <= GitHubBroker.maximumItems,
      Set(observed.map(\.nodeID)).count == observed.count
    else {
      throw RolloutAuthorityError.previewDrift
    }
    var missing: [RolloutLabelDefinition] = []
    for definition in GitHubWorkflowLabelBootstrapper.definitions {
      let matches = observed.filter {
        $0.name.caseInsensitiveCompare(definition.name) == .orderedSame
      }
      guard matches.count <= 1 else { throw RolloutAuthorityError.previewDrift }
      if let existing = matches.first {
        guard existing.name.caseInsensitiveCompare(definition.name) == .orderedSame,
          existing.color.lowercased() == definition.color,
          (existing.description ?? "") == definition.description
        else {
          throw RolloutAuthorityError.previewDrift
        }
      } else {
        missing.append(
          RolloutLabelDefinition(
            name: definition.name,
            color: definition.color,
            description: definition.description
          )
        )
      }
    }
    let expected = missing.sorted { lhs, rhs in
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      if lhs.color != rhs.color { return lhs.color < rhs.color }
      return lhs.description < rhs.description
    }
    guard expected == preview.payload.missingLabels else {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private func validateExact(_ preview: RolloutPreview) async throws {
    guard let object = preview.payload.scope.object,
      let binding = preview.payload.jobBinding,
      let jobID = UUID(uuidString: binding.jobID),
      jobID.uuidString.lowercased() == binding.jobID
    else {
      throw RolloutAuthorityError.previewDrift
    }
    if let job = try await jobs.job(id: jobID) {
      guard
        job.identity.repositoryID.uuidString.lowercased()
          == preview.payload.scope.repository.id,
        job.identity.kind == binding.jobKind,
        job.identity.objectNodeID == object.nodeID,
        job.identity.revisionKey == object.revisionKey,
        job.objectNumber == binding.objectNumber,
        job.contractVersionUsed == binding.contractVersion,
        job.priority == binding.priority,
        job.currentStepKind?.rawValue == binding.currentStep,
        Self.validExistingJobState(
          job,
          stage: preview.payload.scope.stage,
          currentStep: binding.currentStep
        ),
        !job.state.isTerminal
      else {
        throw RolloutAuthorityError.previewDrift
      }
    } else {
      guard binding.currentStep == binding.firstStep.rawValue,
        validNewExactJob(binding, stage: preview.payload.scope.stage)
      else {
        throw RolloutAuthorityError.previewDrift
      }
    }
    switch preview.payload.scope.stage {
    case .prReview, .generatedPRReview:
      try await validatePullRequest(preview, object: object, jobID: jobID)
    case .issueTriage, .implementationPlan, .implementationExecute:
      try await validateIssue(preview, object: object)
    }
  }

  private static func validExistingJobState(
    _ job: JobRecord,
    stage: RolloutWorkflowStage,
    currentStep: String
  ) -> Bool {
    if stage == .implementationExecute,
      currentStep == JobStepKind.publishPlan.rawValue
    {
      return job.state == .waitingHuman
    }
    return true
  }

  private func validNewExactJob(
    _ binding: RolloutJobBinding,
    stage: RolloutWorkflowStage
  ) -> Bool {
    switch stage {
    case .prReview:
      binding.jobKind == .prReview
        && binding.priority == .prReview
        && binding.firstStep == .review
    case .issueTriage:
      binding.jobKind == .issueTriage
        && binding.priority == .triage
        && binding.firstStep == .triage
    case .implementationPlan:
      binding.jobKind == .issueImplementation
        && binding.priority == .issueImplementation
        && binding.firstStep == .claimReady
    case .implementationExecute, .generatedPRReview:
      false
    }
  }

  private func validatePullRequest(
    _ preview: RolloutPreview,
    object: RolloutObjectSelector,
    jobID: UUID
  ) async throws {
    let repository = preview.payload.scope.repository
    let pullRequest = try await api.pullRequest(
      owner: repository.owner,
      repository: repository.name,
      number: object.number
    )
    guard pullRequest.nodeID == object.nodeID,
      pullRequest.number == object.number,
      pullRequest.state == "open",
      !pullRequest.draft,
      pullRequest.head.sha == object.revisionKey,
      pullRequest.base.ref == repository.defaultBranch,
      GitHubInputValidation.validGitSHA(pullRequest.base.sha),
      GitHubInputValidation.validGitSHA(pullRequest.head.sha),
      pullRequest.base.sha != pullRequest.head.sha
    else {
      throw RolloutAuthorityError.previewDrift
    }
    let restCommits = try await api.listPullRequestCommits(
      owner: repository.owner,
      repository: repository.name,
      number: object.number
    ).map(\.sha)
    let fetched = try await git.derivePullRequest(
      repository: repository,
      number: object.number,
      baseSHA: pullRequest.base.sha,
      headSHA: pullRequest.head.sha,
      jobID: jobID
    )
    guard restCommits == fetched.commitSHAs,
      fetched.baseSHA == pullRequest.base.sha,
      fetched.headSHA == pullRequest.head.sha
    else {
      throw RolloutAuthorityError.previewDrift
    }
    let artifact = try SystemPullRequestReviewJobPreparer.artifact(
      repository: repository.configuration,
      pullRequest: pullRequest,
      restCommitSHAs: restCommits,
      fetched: fetched
    )
    let narrative = try PiPullRequestReviewRouter.commitNarrativeDigest(
      fetched.narrative,
      baseSHA: pullRequest.base.sha
    )
    guard object.headSHA == pullRequest.head.sha,
      object.baseSHA == pullRequest.base.sha,
      object.narrativeSHA256 == narrative,
      object.canonicalInputSHA256 == GitHubMarkerCodec.sha256(artifact),
      object.labelStateSHA256 == nil,
      object.planSHA256 == nil
    else {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private func validateIssue(
    _ preview: RolloutPreview,
    object: RolloutObjectSelector
  ) async throws {
    let repository = preview.payload.scope.repository
    async let issueRead = api.issue(
      owner: repository.owner,
      repository: repository.name,
      number: object.number
    )
    async let commentsRead = api.listComments(
      owner: repository.owner,
      repository: repository.name,
      number: object.number
    )
    async let labelsRead = api.listIssueLabels(
      owner: repository.owner,
      repository: repository.name,
      number: object.number
    )
    async let referenceRead = api.branchReference(
      owner: repository.owner,
      repository: repository.name,
      branch: repository.defaultBranch
    )
    let issue = try await issueRead
    let comments = try await commentsRead
    let labels = try await labelsRead
    guard let reference = try await referenceRead,
      issue.nodeID == object.nodeID,
      issue.number == object.number,
      issue.state == "open",
      !issue.isPullRequest,
      reference.ref == "refs/heads/\(repository.defaultBranch)",
      GitHubInputValidation.validGitSHA(reference.object.sha)
    else {
      throw RolloutAuthorityError.previewDrift
    }
    try validateWorkflowLabels(
      labels,
      stage: preview.payload.scope.stage,
      currentStep: object.currentStep
    )
    let revision = try await DurableIssueRevisionDeriver(
      intents: intents,
      appAuthorID: preview.payload.releaseIdentity.githubAuthorID
    ).derive(
      repositoryNodeID: repository.nodeID,
      issue: issue,
      comments: comments,
      labels: labels
    )
    let base = try BaseRevision(branch: repository.defaultBranch, sha: reference.object.sha)
    let artifact: Data
    switch preview.payload.scope.stage {
    case .issueTriage:
      artifact = try SystemIssueTriageJobPreparer.artifact(
        repository: repository.configuration,
        issue: issue,
        comments: comments,
        labels: labels,
        issueRevision: revision,
        baseRevision: base
      )
    case .implementationPlan, .implementationExecute:
      let branch = try SystemIssueImplementationJobPreparer.branch(
        number: issue.number,
        title: issue.title
      )
      artifact = try SystemIssueImplementationJobPreparer.artifact(
        repository: repository.configuration,
        issue: issue,
        comments: comments,
        labels: labels,
        revision: revision,
        base: base,
        branch: branch,
        planPath: "docs/plans/jidoka-code-issue-\(issue.number).md"
      )
    case .prReview, .generatedPRReview:
      throw RolloutAuthorityError.previewDrift
    }
    let labelStateSHA256 = try RolloutPreviewBuilder.labelStateSHA256(labels)
    guard object.baseSHA == base.sha,
      object.labelStateSHA256 == labelStateSHA256,
      object.canonicalInputSHA256 == GitHubMarkerCodec.sha256(artifact),
      object.headSHA == nil,
      object.narrativeSHA256 == nil
    else {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private func validateWorkflowLabels(
    _ labels: [GitHubLabel],
    stage: RolloutWorkflowStage,
    currentStep: String
  ) throws {
    let workflow = Set(
      labels.map(\.name).filter(SystemIssueImplementationJobPreparer.isWorkflowLabel)
        .map { $0.lowercased() }
    )
    let expected: Set<String>
    switch (stage, currentStep) {
    case (.issueTriage, _):
      expected = []
    case (.implementationPlan, JobStepKind.claimReady.rawValue):
      expected = ["agent:ready"]
    case (.implementationPlan, JobStepKind.replan.rawValue):
      expected = ["agent:plan-review"]
    case (.implementationExecute, JobStepKind.publishPlan.rawValue):
      expected = ["agent:plan-review", "plan:approved"]
    case (.implementationExecute, JobStepKind.claimApprovedPlan.rawValue):
      expected = ["agent:plan-review", "plan:approved"]
    case (.implementationExecute, JobStepKind.orchestrate.rawValue):
      expected = ["agent:wip"]
    default:
      throw RolloutAuthorityError.previewDrift
    }
    guard workflow == expected else { throw RolloutAuthorityError.previewDrift }
  }

  private func validateFinite(_ preview: RolloutPreview) async throws {
    guard let window = preview.payload.scope.finiteWindow,
      let repositoryID = UUID(uuidString: preview.payload.scope.repository.id),
      repositoryID.uuidString.lowercased() == preview.payload.scope.repository.id
    else {
      throw RolloutAuthorityError.previewDrift
    }
    let repository = preview.payload.scope.repository
    let discovery = GitHubDiscovery(
      api: api,
      jobs: jobs,
      reviewedRevisions: reviewedRevisions
    )
    let identities: [(nodeID: String, number: Int, revisionKey: String)]
    let observedUpperBound: Int
    switch preview.payload.scope.stage {
    case .prReview:
      let observations = try await discovery.pullRequests(
        owner: repository.owner,
        repository: repository.name,
        repositoryID: repositoryID,
        repositoryNodeID: repository.nodeID
      )
      guard observations.allSatisfy({ $0.pullRequest.number > 0 }) else {
        throw RolloutAuthorityError.previewDrift
      }
      observedUpperBound = observations.map(\.pullRequest.number).max() ?? 0
      identities = observations.compactMap {
        guard $0.disposition == .candidate else { return nil }
        return ($0.pullRequest.nodeID, $0.pullRequest.number, $0.pullRequest.head.sha)
      }
    case .issueTriage:
      let observations = try await discovery.issues(
        owner: repository.owner,
        repository: repository.name,
        repositoryID: repositoryID
      )
      guard observations.allSatisfy({ $0.issue.number > 0 }) else {
        throw RolloutAuthorityError.previewDrift
      }
      observedUpperBound = observations.map(\.issue.number).max() ?? 0
      identities = observations.compactMap {
        guard $0.disposition == .candidate else { return nil }
        return ($0.issue.nodeID, $0.issue.number, "initial-triage")
      }
    case .implementationPlan:
      let observations = try await discovery.implementationIssues(
        owner: repository.owner,
        repository: repository.name,
        repositoryID: repositoryID
      )
      guard observations.allSatisfy({ $0.issue.number > 0 }) else {
        throw RolloutAuthorityError.previewDrift
      }
      observedUpperBound = observations.map(\.issue.number).max() ?? 0
      identities = try await implementationCandidateIdentities(observations)
    case .implementationExecute, .generatedPRReview:
      throw RolloutAuthorityError.previewDrift
    }
    let sorted = identities.sorted { lhs, rhs in
      if lhs.number != rhs.number { return lhs.number < rhs.number }
      if lhs.nodeID != rhs.nodeID { return lhs.nodeID < rhs.nodeID }
      return lhs.revisionKey < rhs.revisionKey
    }
    guard Set(sorted.map { "\($0.nodeID)\u{0}\($0.revisionKey)" }).count == sorted.count else {
      throw RolloutAuthorityError.previewDrift
    }
    let candidates = try sorted.enumerated().map { ordinal, candidate in
      RolloutWindowCandidate(
        ordinal: ordinal,
        nodeID: candidate.nodeID,
        number: candidate.number,
        revisionKey: candidate.revisionKey,
        canonicalInputSHA256: try RolloutPreviewBuilder.futureCandidateSHA256(
          scope: preview.payload.scope,
          nodeID: candidate.nodeID,
          number: candidate.number,
          revisionKey: candidate.revisionKey
        )
      )
    }
    guard candidates == window.candidates,
      observedUpperBound == window.observedObjectNumberUpperBound
    else {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private func implementationCandidateIdentities(
    _ observations: [ImplementationIssueDiscoveryObservation]
  ) async throws -> [(nodeID: String, number: Int, revisionKey: String)] {
    var values: [(nodeID: String, number: Int, revisionKey: String)] = []
    for observation in observations {
      guard observation.disposition == .candidate(.ready) else { continue }
      let generation = try await jobs.nextClaimGeneration(
        issueNodeID: observation.issue.nodeID
      )
      values.append((observation.issue.nodeID, observation.issue.number, "claim-\(generation)"))
    }
    return values
  }
}

extension RolloutRepositoryIdentity {
  fileprivate var configuration: RepositoryConfiguration {
    get throws {
      guard let id = UUID(uuidString: id), id.uuidString.lowercased() == self.id else {
        throw RolloutAuthorityError.invalidRepositoryIdentity
      }
      return RepositoryConfiguration(
        id: id,
        nodeID: nodeID,
        owner: owner,
        name: name,
        defaultBranch: defaultBranch,
        reviewEnabled: reviewEnabled,
        triageEnabled: triageEnabled,
        implementationEnabled: implementationEnabled,
        enabled: enabled
      )
    }
  }
}
