import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Job-scoped GitHub mutation read-back")
struct GitHubJobMutationObservationReaderTests {
  @Test("claim marker and exact workflow labels reconcile as one attributable effect")
  func compositeClaim() async throws {
    let key = String(repeating: "a", count: 64)
    let identity = GitHubMarkerIdentity(
      kind: .claim,
      repositoryNodeID: "repository-node",
      objectNodeID: "issue-node",
      revision: "claim-1",
      idempotencyKey: key
    )
    let document = "Claim issue for bounded implementation.\n"
    let parts = try GitHubMarkerCodec.build(document: document, identity: identity)
    let author = GitHubUser(id: 7, nodeID: "user-node", login: "jidoka-code")
    let comments = parts.enumerated().map { index, part in
      GitHubComment(
        id: Int64(index + 1),
        nodeID: "comment-\(index + 1)",
        body: part.body,
        user: author,
        createdAt: "2026-08-08T00:00:00Z",
        updatedAt: "2026-08-08T00:00:00Z",
        htmlURL: "https://github.com/owner/repo/issues/1#issuecomment-\(index + 1)"
      )
    }
    let labels = [label("agent:wip"), label("domain:swift")]
    let api = MutationReadFixture(comments: comments, labels: labels)
    let reader = GitHubJobMutationObservationReader(
      api: api,
      expectation: .markerAndLabels(
        repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
        number: 1,
        marker: GitHubMarkerExpectation(
          identity: identity,
          authorID: author.id,
          documentSHA256: try #require(parts.first?.documentSHA256)
        ),
        labels: WorkflowLabelExpectation(
          expected: ["agent:ready"],
          desired: ["agent:wip"]
        )
      )
    )

    let observation = try await reader.observe(
      intent: intent(operation: .claimIssue, key: key),
      attempt: 1
    )

    guard case .effectExact(let digest) = observation else {
      Issue.record("claim was not attributed: \(observation)")
      return
    }
    #expect(GitHubInputValidation.validSHA256(digest))
    #expect(await api.commentReads == 1)
    #expect(await api.labelReads == 1)
  }

  @Test("operation mismatches and invalid attempts fail before remote reads")
  func rejectsMismatches() async throws {
    let api = MutationReadFixture(comments: [], labels: [])
    let reader = GitHubJobMutationObservationReader(
      api: api,
      expectation: .workflowLabels(
        repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
        number: 1,
        expectation: WorkflowLabelExpectation(
          expected: ["agent:ready"],
          desired: ["agent:wip"]
        )
      )
    )
    await #expect(throws: GitHubJobMutationObservationError.operationMismatch) {
      try await reader.observe(
        intent: intent(operation: .createMarkerComment, key: String(repeating: "b", count: 64)),
        attempt: 1
      )
    }
    await #expect(throws: GitHubJobMutationObservationError.invalidExpectation) {
      try await reader.observe(
        intent: intent(
          operation: .mutateWorkflowLabels,
          key: String(repeating: "c", count: 64)
        ),
        attempt: 0
      )
    }
    #expect(await api.commentReads == 0)
    #expect(await api.labelReads == 0)
  }

  private func intent(operation: MutationOperation, key: String) -> MutationIntentRecord {
    MutationIntentRecord(
      id: UUID(),
      jobID: UUID(),
      idempotencyKey: key,
      operation: operation,
      target: "owner/repo/issues/1",
      expectedStateDigest: String(repeating: "d", count: 64),
      requestDigest: String(repeating: "e", count: 64),
      state: .reconcileRequired,
      sendEpoch: 1,
      readBackEvidence: nil,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func label(_ name: String) -> GitHubLabel {
    GitHubLabel(
      id: Int64(abs(name.hashValue)),
      nodeID: "label-\(name)",
      name: name,
      color: "abcdef",
      description: nil
    )
  }
}

private actor MutationReadFixture: GitHubMutationReadAPI {
  let comments: [GitHubComment]
  let labels: [GitHubLabel]
  private(set) var commentReads = 0
  private(set) var labelReads = 0

  init(comments: [GitHubComment], labels: [GitHubLabel]) {
    self.comments = comments
    self.labels = labels
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    throw MutationReadFixtureError.unconfigured
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw MutationReadFixtureError.unconfigured
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    commentReads += 1
    return comments
  }

  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  {
    labelReads += 1
    return labels
  }

  func lookupPullRequests(
    owner: String,
    repository: String,
    head: String,
    base: String
  ) async throws -> [GitHubPullRequest] {
    []
  }

  func repositoryLabel(owner: String, repository: String, label: String) async throws
    -> GitHubLabel?
  {
    labels.first { $0.name.caseInsensitiveCompare(label) == .orderedSame }
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }
}

private enum MutationReadFixtureError: Error {
  case unconfigured
}
