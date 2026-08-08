import Foundation

public protocol IssueLinkedInputResolving: Sendable {
  func linkedInputs(
    issue: GitHubIssue,
    comments: [GitHubComment]
  ) async throws -> [IssueRevisionLinkedInput]
}

public struct NoIssueLinkedInputResolver: IssueLinkedInputResolving, Sendable {
  public init() {}

  public func linkedInputs(
    issue: GitHubIssue,
    comments: [GitHubComment]
  ) async throws -> [IssueRevisionLinkedInput] {
    []
  }
}

public struct DurableIssueRevisionDeriver: Sendable {
  private let intents: MutationIntentStore
  private let linkedInputs: any IssueLinkedInputResolving
  private let appAuthorID: Int64

  public init(
    intents: MutationIntentStore,
    appAuthorID: Int64,
    linkedInputs: any IssueLinkedInputResolving = NoIssueLinkedInputResolver()
  ) {
    self.intents = intents
    self.appAuthorID = appAuthorID
    self.linkedInputs = linkedInputs
  }

  public func derive(
    repositoryNodeID: String,
    issue: GitHubIssue,
    comments: [GitHubComment],
    labels: [GitHubLabel]
  ) async throws -> IssueRevision {
    var expectations: [GitHubMarkerExpectation] = []
    for comment in comments where comment.user.id == appAuthorID {
      guard let parsed = try? GitHubMarkerCodec.parse(comment.body),
        parsed.identity.repositoryNodeID == repositoryNodeID,
        parsed.identity.objectNodeID == issue.nodeID
      else { continue }
      let key = GitHubMarkerPublisher.partIdempotencyKey(
        identity: parsed.identity,
        index: parsed.index,
        payloadSHA256: parsed.payloadSHA256
      )
      guard let intent = try await intents.intent(idempotencyKey: key),
        intent.state == .attributed,
        intent.expectedStateDigest == parsed.documentSHA256,
        Self.markerOperations.contains(intent.operation)
      else { continue }
      expectations.append(
        GitHubMarkerExpectation(
          identity: parsed.identity,
          authorID: appAuthorID,
          documentSHA256: parsed.documentSHA256
        )
      )
    }
    return try IssueRevisionBuilder.make(
      input: IssueRevisionInput(
        issueNodeID: issue.nodeID,
        title: issue.title,
        body: issue.body ?? "",
        authorID: issue.user.id,
        createdAt: issue.createdAt,
        labels: labels.map { IssueRevisionLabel(nodeID: $0.nodeID, name: $0.name) },
        comments: comments.map {
          IssueRevisionComment(
            id: $0.id,
            nodeID: $0.nodeID,
            authorID: $0.user.id,
            authorLogin: $0.user.login,
            createdAt: $0.createdAt,
            updatedAt: $0.updatedAt,
            body: $0.body
          )
        },
        linkedInputs: try await linkedInputs.linkedInputs(issue: issue, comments: comments)
      ),
      markerExpectations: expectations
    )
  }

  private static let markerOperations: Set<MutationOperation> = [
    .createMarkerComment, .claimIssue, .linkPullRequest, .publishComplexPlan, .blockIssue,
  ]
}
