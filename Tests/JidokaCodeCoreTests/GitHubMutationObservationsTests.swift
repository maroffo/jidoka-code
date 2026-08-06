import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Operation-specific GitHub read-back observations")
struct GitHubMutationObservationsTests {
  @Test("label bootstrap distinguishes absent, exact, and semantic conflict")
  func bootstrapLabel() {
    let expected = GitHubCreateLabel(
      name: "agent:ready",
      color: "abcdef",
      description: "Ready"
    )
    #expect(
      isAbsent(GitHubMutationObservations.bootstrapLabel(expected: expected, actual: nil))
    )
    let exact = GitHubLabel(
      id: 1,
      nodeID: "L_exact",
      name: "Agent:Ready",
      color: "ABCDEF",
      description: "Ready"
    )
    #expect(
      isExact(GitHubMutationObservations.bootstrapLabel(expected: expected, actual: exact))
    )
    let conflict = GitHubLabel(
      id: 1,
      nodeID: "L_conflict",
      name: "agent:ready",
      color: "000000",
      description: "Different"
    )
    #expect(
      isConflict(
        GitHubMutationObservations.bootstrapLabel(expected: expected, actual: conflict)
      )
    )
  }

  @Test("comment read-back requires all exact marker parts and author identity")
  func markerComment() throws {
    let identity = GitHubMarkerIdentity(
      kind: .plan,
      repositoryNodeID: "R_repo",
      objectNodeID: "I_issue",
      revision: "revision",
      idempotencyKey: GitHubMarkerCodec.sha256(Data("observation".utf8))
    )
    let parts = try GitHubMarkerCodec.build(
      document: String(repeating: "plan\n", count: 20_000),
      identity: identity
    )
    let comments = parts.enumerated().map { index, part in
      GitHubMarkerComment(id: Int64(index + 1), authorID: 42, body: part.body)
    }
    let expectation = GitHubMarkerExpectation(
      identity: identity,
      authorID: 42,
      documentSHA256: parts[0].documentSHA256
    )
    #expect(
      isAbsent(
        GitHubMutationObservations.markerComment(
          comments: [],
          expectation: expectation
        ))
    )
    #expect(
      isExact(
        GitHubMutationObservations.markerComment(
          comments: comments,
          expectation: expectation
        ))
    )
    #expect(
      isDuplicate(
        GitHubMutationObservations.markerComment(
          comments: [comments[0], comments[0]],
          expectation: expectation
        ))
    )
    var wrongAuthor = comments
    wrongAuthor[0] = GitHubMarkerComment(
      id: comments[0].id,
      authorID: 99,
      body: comments[0].body
    )
    #expect(
      isConflict(
        GitHubMutationObservations.markerComment(
          comments: wrongAuthor,
          expectation: expectation
        ))
    )
  }

  @Test("workflow labels compare the full workflow subset")
  func workflowLabels() {
    let expectation = WorkflowLabelExpectation(
      expected: ["agent:ready"],
      desired: ["agent:wip"]
    )
    #expect(
      isExpected(
        GitHubMutationObservations.workflowLabels(
          currentWorkflowLabels: ["Agent:Ready"],
          expectation: expectation
        ))
    )
    #expect(
      isDesired(
        GitHubMutationObservations.workflowLabels(
          currentWorkflowLabels: ["AGENT:WIP"],
          expectation: expectation
        ))
    )
    #expect(
      isConflict(
        GitHubMutationObservations.workflowLabels(
          currentWorkflowLabels: ["agent:ready", "agent:wip"],
          expectation: expectation
        ))
    )
    let marker = MutationObservation.effectExact(
      evidenceDigest: String(repeating: "a", count: 64)
    )
    let desired = MutationObservation.desiredStateExact(
      evidenceDigest: String(repeating: "b", count: 64)
    )
    #expect(isExact(GitHubMutationObservations.composite(marker: marker, labels: desired)))
    let expected = MutationObservation.expectedStateExact(
      evidenceDigest: String(repeating: "c", count: 64)
    )
    #expect(isExpected(GitHubMutationObservations.composite(marker: marker, labels: expected)))
  }

  @Test("PR and branch read-back reject duplicate or divergent remote state")
  func pullRequestAndBranch() {
    let pull = observedPullRequest(
      number: 1,
      head: "agent/issue-1-work",
      headSHA: String(repeating: "a", count: 40),
      base: "main",
      body: "marker body"
    )
    let expectation = PullRequestMutationExpectation(
      head: "agent/issue-1-work",
      base: "main",
      exactHeadSHA: String(repeating: "a", count: 40),
      bodySHA256: GitHubMarkerCodec.sha256(Data("marker body".utf8))
    )
    #expect(
      isAbsent(
        GitHubMutationObservations.pullRequest(
          candidates: [],
          exact: nil,
          expectation: expectation
        )
      )
    )
    #expect(
      isExact(
        GitHubMutationObservations.pullRequest(
          candidates: [pull],
          exact: pull,
          expectation: expectation
        ))
    )
    #expect(
      isIncomplete(
        GitHubMutationObservations.pullRequest(
          candidates: [pull],
          exact: nil,
          expectation: expectation
        ))
    )
    let ownerQualified = PullRequestMutationExpectation(
      head: "owner:agent/issue-1-work",
      base: expectation.base,
      exactHeadSHA: expectation.exactHeadSHA,
      bodySHA256: expectation.bodySHA256
    )
    #expect(
      isExact(
        GitHubMutationObservations.pullRequest(
          candidates: [pull],
          exact: pull,
          expectation: ownerQualified
        ))
    )
    #expect(
      isDuplicate(
        GitHubMutationObservations.pullRequest(
          candidates: [pull, pull],
          exact: pull,
          expectation: expectation
        ))
    )
    let divergent = observedPullRequest(
      number: 1,
      head: "agent/issue-1-work",
      headSHA: String(repeating: "b", count: 40),
      base: "main",
      body: "marker body"
    )
    #expect(
      isConflict(
        GitHubMutationObservations.pullRequest(
          candidates: [divergent],
          exact: divergent,
          expectation: expectation
        ))
    )

    let reference = GitHubReference(
      ref: "refs/heads/agent/issue-1-work",
      nodeID: "REF_1",
      object: GitHubGitObject(
        sha: String(repeating: "a", count: 40),
        type: "commit",
        url: "https://api.github.com/repos/owner/repo/git/commits/a"
      )
    )
    #expect(
      isExact(
        GitHubMutationObservations.branchReference(
          actual: reference,
          branch: "agent/issue-1-work",
          exactSHA: String(repeating: "a", count: 40)
        ))
    )
    #expect(
      isConflict(
        GitHubMutationObservations.branchReference(
          actual: reference,
          branch: "agent/issue-1-work",
          exactSHA: String(repeating: "b", count: 40)
        ))
    )
  }
}

private func observedPullRequest(
  number: Int,
  head: String,
  headSHA: String,
  base: String,
  body: String
) -> GitHubPullRequest {
  let repository = GitHubPullRepository(
    id: 1,
    nodeID: "R_repo",
    fullName: "owner/repo"
  )
  return GitHubPullRequest(
    id: Int64(number),
    nodeID: "PR_\(number)",
    number: number,
    state: "open",
    draft: false,
    title: "Title",
    body: body,
    htmlURL: "https://github.com/owner/repo/pull/\(number)",
    user: GitHubUser(id: 1, nodeID: "U_1", login: "owner"),
    head: GitHubPullReference(ref: head, sha: headSHA, repository: repository),
    base: GitHubPullReference(
      ref: base,
      sha: String(repeating: "f", count: 40),
      repository: repository
    )
  )
}

private func isExact(_ value: MutationObservation) -> Bool {
  if case .effectExact = value { return true }
  return false
}

private func isAbsent(_ value: MutationObservation) -> Bool {
  if case .effectAbsent = value { return true }
  return false
}

private func isConflict(_ value: MutationObservation) -> Bool {
  if case .conflict = value { return true }
  return false
}

private func isDuplicate(_ value: MutationObservation) -> Bool {
  if case .duplicate = value { return true }
  return false
}

private func isExpected(_ value: MutationObservation) -> Bool {
  if case .expectedStateExact = value { return true }
  return false
}

private func isDesired(_ value: MutationObservation) -> Bool {
  if case .desiredStateExact = value { return true }
  return false
}

private func isIncomplete(_ value: MutationObservation) -> Bool {
  if case .incomplete = value { return true }
  return false
}
