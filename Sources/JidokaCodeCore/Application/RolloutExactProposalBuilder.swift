// ABOUTME: Produces the exact-object preview input the operator confirms, from one bounded GitHub read
// ABOUTME: Mirror of RolloutRemotePreviewRevalidator: it builds what that type later re-derives and compares

import Foundation

/// Resolves the durable job the proposal would bind, once the revision key is known. The revision
/// key is the pull request head, so the binding cannot be decided before the metadata fetch, and
/// the durable state it reads belongs to the engine rather than to the GitHub reader.
public typealias RolloutExactJobBindingResolving =
  @Sendable (
    _ objectNodeID: String,
    _ objectNumber: Int,
    _ revisionKey: String
  ) async throws -> RolloutJobBinding

struct RolloutExactProposalBuilder: Sendable {
  /// Builds the Git inspector once the job the reads will be attributed to is known. The remote
  /// read authority binds every fetch to an exact job id, and that id comes from durable state
  /// keyed by the pull request head, so it cannot exist before the metadata fetch.
  typealias GitInspecting = @Sendable (UUID) throws -> any RolloutPreviewGitInspecting

  private let identity: any RolloutPreviewIdentityReading
  private let api: any RolloutPreviewRepositoryReading
  private let makeGit: GitInspecting

  init(
    identity: any RolloutPreviewIdentityReading,
    api: any RolloutPreviewRepositoryReading,
    makeGit: @escaping GitInspecting
  ) {
    self.identity = identity
    self.api = api
    self.makeGit = makeGit
  }

  func observePullRequest(
    repository: RolloutRepositoryIdentity,
    number: Int,
    expectedAccount: String,
    expectedAuthorID: Int64,
    resolveBinding: RolloutExactJobBindingResolving
  ) async throws -> RolloutExactObjectObservation {
    // The token this fetch spends belongs to the configured account. An observation made under
    // any other identity is not this installation's proposal, whatever it contains, so the
    // comparison belongs here rather than in a caller that could forget to make it.
    let account = try await identity.authenticatedIdentity()
    guard GitHubInputValidation.validOwner(account.login), account.id > 0,
      account.login.caseInsensitiveCompare(expectedAccount) == .orderedSame,
      account.id == expectedAuthorID
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    let observed = try await api.repository(
      owner: repository.owner,
      repository: repository.name,
      expectedNodeID: repository.nodeID
    )
    guard observed.nodeID == repository.nodeID,
      observed.owner.login.caseInsensitiveCompare(repository.owner) == .orderedSame,
      observed.name.caseInsensitiveCompare(repository.name) == .orderedSame,
      observed.defaultBranch == repository.defaultBranch
    else {
      throw RolloutAuthorityError.invalidRepositoryIdentity
    }
    let pullRequest = try await api.pullRequest(
      owner: repository.owner,
      repository: repository.name,
      number: number
    )
    guard pullRequest.number == number,
      pullRequest.state == "open",
      !pullRequest.draft,
      pullRequest.base.ref == repository.defaultBranch,
      GitHubInputValidation.validGitSHA(pullRequest.base.sha),
      GitHubInputValidation.validGitSHA(pullRequest.head.sha),
      pullRequest.base.sha != pullRequest.head.sha
    else {
      throw RolloutAuthorityError.invalidObjectSelector
    }
    let binding = try await resolveBinding(
      pullRequest.nodeID,
      pullRequest.number,
      pullRequest.head.sha
    )
    // `RolloutJobBinding` normalises its own identifier, so only the object number can drift here.
    guard let jobID = UUID(uuidString: binding.jobID), binding.objectNumber == number else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    let restCommits = try await api.listPullRequestCommits(
      owner: repository.owner,
      repository: repository.name,
      number: number
    ).map(\.sha)
    let fetched = try await makeGit(jobID).derivePullRequest(
      repository: repository,
      number: number,
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
    return RolloutExactObjectObservation(
      object: RolloutObjectSelector(
        nodeID: pullRequest.nodeID,
        number: pullRequest.number,
        revisionKey: pullRequest.head.sha,
        canonicalInputSHA256: GitHubMarkerCodec.sha256(artifact),
        headSHA: pullRequest.head.sha,
        baseSHA: pullRequest.base.sha,
        narrativeSHA256: narrative,
        currentStep: binding.currentStep
      ),
      jobBinding: binding,
      githubAccount: account.login,
      githubAuthorID: account.id
    )
  }
}
