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
  private let identity: any RolloutPreviewIdentityReading
  private let api: any RolloutPreviewRepositoryReading
  private let git: any RolloutPreviewGitInspecting

  init(
    identity: any RolloutPreviewIdentityReading,
    api: any RolloutPreviewRepositoryReading,
    git: any RolloutPreviewGitInspecting
  ) {
    self.identity = identity
    self.api = api
    self.git = git
  }

  func observePullRequest(
    repository: RolloutRepositoryIdentity,
    number: Int,
    resolveBinding: RolloutExactJobBindingResolving
  ) async throws -> RolloutExactObjectObservation {
    let account = try await identity.authenticatedIdentity()
    guard GitHubInputValidation.validOwner(account.login), account.id > 0 else {
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
    guard let jobID = UUID(uuidString: binding.jobID),
      jobID.uuidString.lowercased() == binding.jobID,
      binding.objectNumber == number
    else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    let restCommits = try await api.listPullRequestCommits(
      owner: repository.owner,
      repository: repository.name,
      number: number
    ).map(\.sha)
    let fetched = try await git.derivePullRequest(
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
