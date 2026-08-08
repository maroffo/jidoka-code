import Foundation

public struct PreparedIssueImplementationJob: Sendable {
  public let repository: RepositoryConfiguration
  public let issue: GitHubIssue
  public let comments: [GitHubComment]
  public let workflowLabels: Set<String>
  public let issueRevision: IssueRevision
  public let baseRevision: BaseRevision
  public let remote: GitRemoteRepository
  public let mirrorURL: URL
  public let branch: String
  public let planPath: String
  public let artifact: Data

  public init(
    repository: RepositoryConfiguration,
    issue: GitHubIssue,
    comments: [GitHubComment],
    workflowLabels: Set<String>,
    issueRevision: IssueRevision,
    baseRevision: BaseRevision,
    remote: GitRemoteRepository,
    mirrorURL: URL,
    branch: String,
    planPath: String,
    artifact: Data
  ) {
    self.repository = repository
    self.issue = issue
    self.comments = comments
    self.workflowLabels = workflowLabels
    self.issueRevision = issueRevision
    self.baseRevision = baseRevision
    self.remote = remote
    self.mirrorURL = mirrorURL
    self.branch = branch
    self.planPath = planPath
    self.artifact = artifact
  }
}

public enum IssueImplementationInputError: Error, Equatable, Sendable {
  case invalidJob
  case repositoryDisabled
  case remoteIdentityMismatch
  case invalidIssueRevision
  case invalidArtifact
}

public protocol IssueImplementationJobPreparing: Sendable {
  func prepare(job: JobRecord) async throws -> PreparedIssueImplementationJob
}

public struct SystemIssueImplementationJobPreparer: IssueImplementationJobPreparing, Sendable {
  private let configuration: ConfigurationStore
  private let api: any GitHubMutationReadAPI
  private let repositories: RepositoryStore
  private let remoteResolver: any GitRemoteRepositoryResolving
  private let revisionDeriver: DurableIssueRevisionDeriver
  private let credentials: (any GitCredentialSessionProviding)?

  public init(
    configuration: ConfigurationStore,
    api: any GitHubMutationReadAPI,
    repositories: RepositoryStore,
    intents: MutationIntentStore,
    appAuthorID: Int64,
    linkedInputs: any IssueLinkedInputResolving = NoIssueLinkedInputResolver(),
    remoteResolver: any GitRemoteRepositoryResolving = GitHubRemoteRepositoryResolver(),
    credentials: (any GitCredentialSessionProviding)? = nil
  ) {
    self.configuration = configuration
    self.api = api
    self.repositories = repositories
    self.remoteResolver = remoteResolver
    revisionDeriver = DurableIssueRevisionDeriver(
      intents: intents,
      appAuthorID: appAuthorID,
      linkedInputs: linkedInputs
    )
    self.credentials = credentials
  }

  public func prepare(job: JobRecord) async throws -> PreparedIssueImplementationJob {
    guard job.identity.kind == .issueImplementation,
      let number = job.objectNumber,
      number > 0
    else {
      throw IssueImplementationInputError.invalidJob
    }
    guard let repository = try await configuration.repository(id: job.identity.repositoryID),
      repository.enabled,
      repository.implementationEnabled
    else {
      throw IssueImplementationInputError.repositoryDisabled
    }
    async let issueRead = api.issue(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let commentsRead = api.listComments(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let labelsRead = api.listIssueLabels(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    async let referenceRead = api.branchReference(
      owner: repository.owner,
      repository: repository.name,
      branch: repository.defaultBranch
    )
    let issue = try await issueRead
    let comments = try await commentsRead
    let labels = try await labelsRead
    guard let reference = try await referenceRead else {
      throw IssueImplementationInputError.remoteIdentityMismatch
    }
    guard issue.nodeID == job.identity.objectNodeID,
      issue.number == number,
      issue.state == "open",
      !issue.isPullRequest,
      reference.ref == "refs/heads/\(repository.defaultBranch)",
      GitHubInputValidation.validGitSHA(reference.object.sha)
    else {
      throw IssueImplementationInputError.remoteIdentityMismatch
    }
    let revision = try await revisionDeriver.derive(
      repositoryNodeID: repository.nodeID,
      issue: issue,
      comments: comments,
      labels: labels
    )
    let base = try BaseRevision(branch: repository.defaultBranch, sha: reference.object.sha)
    let remote = try remoteResolver.remote(for: repository)
    let mirror = try await repositories.ensureMirror(
      remote: remote,
      credentials: credentials
    )
    let branch = try Self.branch(number: number, title: issue.title)
    let planPath = "docs/plans/jidoka-code-issue-\(number).md"
    let artifact = try Self.artifact(
      repository: repository,
      issue: issue,
      comments: comments,
      labels: labels,
      revision: revision,
      base: base,
      branch: branch,
      planPath: planPath
    )
    return PreparedIssueImplementationJob(
      repository: repository,
      issue: issue,
      comments: comments,
      workflowLabels: Set(
        labels.map(\.name).filter(Self.isWorkflowLabel).map { $0.lowercased() }
      ),
      issueRevision: revision,
      baseRevision: base,
      remote: remote,
      mirrorURL: mirror,
      branch: branch,
      planPath: planPath,
      artifact: artifact
    )
  }

  private static func branch(number: Int, title: String) throws -> String {
    let lowered = title.lowercased()
    var slug = ""
    var pendingSeparator = false
    for scalar in lowered.unicodeScalars {
      let value = scalar.value
      let allowed = (48...57).contains(value) || (97...122).contains(value)
      if allowed {
        if pendingSeparator, !slug.isEmpty { slug.append("-") }
        slug.unicodeScalars.append(scalar)
        pendingSeparator = false
      } else if !slug.isEmpty {
        pendingSeparator = true
      }
      if slug.utf8.count >= 80 { break }
    }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if slug.isEmpty { slug = "implementation" }
    let value = "agent/issue-\(number)-\(slug)"
    guard GitBranchPolicy.validImplementationBranch(value) else {
      throw IssueImplementationInputError.invalidJob
    }
    return value
  }

  private static func artifact(
    repository: RepositoryConfiguration,
    issue: GitHubIssue,
    comments: [GitHubComment],
    labels: [GitHubLabel],
    revision: IssueRevision,
    base: BaseRevision,
    branch: String,
    planPath: String
  ) throws -> Data {
    let object: [String: Any] = [
      "baseRevision": [
        "branch": base.branch,
        "digest": base.sha256,
        "sha": base.sha,
      ],
      "branch": branch,
      "comments": comments.filter { !revision.excludedCommentIDs.contains($0.id) }.map {
        [
          "authorID": $0.user.nodeID,
          "body": $0.body,
          "createdAt": $0.createdAt,
          "id": $0.id,
          "updatedAt": $0.updatedAt,
        ] as [String: Any]
      },
      "issue": [
        "authorID": issue.user.nodeID,
        "body": issue.body ?? "",
        "domainLabels": labels.map(\.name).filter { !isWorkflowLabel($0) }.sorted(),
        "nodeID": issue.nodeID,
        "number": issue.number,
        "title": issue.title,
      ],
      "issueRevisionSHA256": revision.sha256,
      "planPath": planPath,
      "repository": [
        "name": repository.name,
        "nodeID": repository.nodeID,
        "owner": repository.owner,
      ],
      "schemaVersion": 1,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw IssueImplementationInputError.invalidArtifact
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func isWorkflowLabel(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
  }
}
