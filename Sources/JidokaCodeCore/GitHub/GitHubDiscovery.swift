import Foundation

public struct ReviewedRevisionRecord: Equatable, Sendable {
  public let repositoryNodeID: String
  public let pullRequestNodeID: String
  public let headSHA: String
  public let reviewContractVersionUsed: String
  public let commentID: String
  public let commentURL: String
  public let commentDigest: String
  public let createdAt: Date
}

public enum ReviewedRevisionStoreError: Error, Equatable, Sendable {
  case invalidRecord
  case collision
  case decode
}

public actor ReviewedRevisionStore {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  public func record(_ value: ReviewedRevisionRecord) async throws {
    guard Self.valid(value) else { throw ReviewedRevisionStoreError.invalidRecord }
    try await database.transaction { database in
      let existing = try database.query(
        """
        SELECT * FROM reviewed_revisions
        WHERE repository_node_id = ? AND pr_node_id = ? AND head_sha = ?
        """,
        bindings: [
          .text(value.repositoryNodeID),
          .text(value.pullRequestNodeID),
          .text(value.headSHA),
        ]
      ).first
      if let existing {
        guard try Self.decode(existing) == value else {
          throw ReviewedRevisionStoreError.collision
        }
        return
      }
      _ = try database.execute(
        """
        INSERT INTO reviewed_revisions(
          repository_node_id, pr_node_id, head_sha,
          review_contract_version_used, comment_id, comment_url,
          comment_digest, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(value.repositoryNodeID),
          .text(value.pullRequestNodeID),
          .text(value.headSHA),
          .text(value.reviewContractVersionUsed),
          .text(value.commentID),
          .text(value.commentURL),
          .text(value.commentDigest),
          .real(value.createdAt.timeIntervalSince1970),
        ]
      )
    }
  }

  public func contains(
    repositoryNodeID: String,
    pullRequestNodeID: String,
    headSHA: String
  ) async throws -> Bool {
    try await database.scalarInt(
      """
      SELECT COUNT(*) FROM reviewed_revisions
      WHERE repository_node_id = ? AND pr_node_id = ? AND head_sha = ?
      """,
      bindings: [
        .text(repositoryNodeID),
        .text(pullRequestNodeID),
        .text(headSHA),
      ]
    ) == 1
  }

  private static func valid(_ value: ReviewedRevisionRecord) -> Bool {
    guard validText(value.repositoryNodeID, maximum: 256),
      validText(value.pullRequestNodeID, maximum: 256),
      GitHubInputValidation.validGitSHA(value.headSHA),
      validText(value.reviewContractVersionUsed, maximum: 256),
      !value.commentID.isEmpty,
      value.commentID.utf8.allSatisfy({ (48...57).contains($0) }),
      let commentURL = URL(string: value.commentURL),
      commentURL.scheme == "https", commentURL.host != nil,
      commentURL.user == nil, commentURL.password == nil,
      GitHubInputValidation.validSHA256(value.commentDigest)
    else {
      return false
    }
    return true
  }

  private static func validText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func decode(_ row: SQLiteRow) throws -> ReviewedRevisionRecord {
    guard case .text(let repositoryNodeID)? = row["repository_node_id"],
      case .text(let pullRequestNodeID)? = row["pr_node_id"],
      case .text(let headSHA)? = row["head_sha"],
      case .text(let contract)? = row["review_contract_version_used"],
      case .text(let commentID)? = row["comment_id"],
      case .text(let commentURL)? = row["comment_url"],
      case .text(let commentDigest)? = row["comment_digest"]
    else {
      throw ReviewedRevisionStoreError.decode
    }
    let createdAt: Double
    switch row["created_at"] {
    case .real(let value): createdAt = value
    case .integer(let value): createdAt = Double(value)
    default: throw ReviewedRevisionStoreError.decode
    }
    return ReviewedRevisionRecord(
      repositoryNodeID: repositoryNodeID,
      pullRequestNodeID: pullRequestNodeID,
      headSHA: headSHA,
      reviewContractVersionUsed: contract,
      commentID: commentID,
      commentURL: commentURL,
      commentDigest: commentDigest,
      createdAt: Date(timeIntervalSince1970: createdAt)
    )
  }
}

public enum GitHubDiscoveryDisposition: Equatable, Sendable {
  case candidate
  case closed
  case draft
  case pullRequestEntry
  case workflowLabel(String)
  case reviewed
  case durableDisposition(ObjectDispositionState)
  case invalidRemoteIdentity
}

public struct PullRequestDiscoveryObservation: Equatable, Sendable {
  public let pullRequest: GitHubPullRequest
  public let disposition: GitHubDiscoveryDisposition
}

public struct IssueDiscoveryObservation: Equatable, Sendable {
  public let issue: GitHubIssue
  public let disposition: GitHubDiscoveryDisposition
}

public actor GitHubDiscovery {
  private let api: any GitHubReadAPI
  private let jobs: DurableJobStore
  private let reviewedRevisions: ReviewedRevisionStore

  public init(
    api: any GitHubReadAPI,
    jobs: DurableJobStore,
    reviewedRevisions: ReviewedRevisionStore
  ) {
    self.api = api
    self.jobs = jobs
    self.reviewedRevisions = reviewedRevisions
  }

  public func pullRequests(
    owner: String,
    repository: String,
    repositoryID: UUID,
    repositoryNodeID: String
  ) async throws -> [PullRequestDiscoveryObservation] {
    let pullRequests = try await api.listPullRequests(owner: owner, repository: repository)
    var observations: [PullRequestDiscoveryObservation] = []
    observations.reserveCapacity(pullRequests.count)
    for pullRequest in pullRequests {
      let disposition: GitHubDiscoveryDisposition
      if pullRequest.state != "open" {
        disposition = .closed
      } else if pullRequest.draft {
        disposition = .draft
      } else if !GitHubInputValidation.validGitSHA(pullRequest.head.sha)
        || pullRequest.nodeID.isEmpty
      {
        disposition = .invalidRemoteIdentity
      } else if try await reviewedRevisions.contains(
        repositoryNodeID: repositoryNodeID,
        pullRequestNodeID: pullRequest.nodeID,
        headSHA: pullRequest.head.sha
      ) {
        disposition = .reviewed
      } else {
        let identity = LogicalJobIdentity(
          repositoryID: repositoryID,
          kind: .prReview,
          objectNodeID: pullRequest.nodeID,
          revisionKey: pullRequest.head.sha
        )
        if let durable = try await jobs.disposition(for: identity) {
          disposition = .durableDisposition(durable.state)
        } else {
          disposition = .candidate
        }
      }
      observations.append(
        PullRequestDiscoveryObservation(
          pullRequest: pullRequest,
          disposition: disposition
        )
      )
    }
    return observations
  }

  public func issues(
    owner: String,
    repository: String,
    repositoryID: UUID
  ) async throws -> [IssueDiscoveryObservation] {
    let issues = try await api.listIssues(owner: owner, repository: repository)
    var observations: [IssueDiscoveryObservation] = []
    observations.reserveCapacity(issues.count)
    for issue in issues {
      let disposition: GitHubDiscoveryDisposition
      if issue.state != "open" {
        disposition = .closed
      } else if issue.isPullRequest {
        disposition = .pullRequestEntry
      } else if let workflow = issue.labels.map(\.name).first(where: Self.isWorkflowLabel) {
        disposition = .workflowLabel(workflow)
      } else if issue.nodeID.isEmpty {
        disposition = .invalidRemoteIdentity
      } else {
        let identity = LogicalJobIdentity(
          repositoryID: repositoryID,
          kind: .issueTriage,
          objectNodeID: issue.nodeID,
          revisionKey: "initial-triage"
        )
        if let durable = try await jobs.disposition(for: identity) {
          disposition = .durableDisposition(durable.state)
        } else {
          disposition = .candidate
        }
      }
      observations.append(
        IssueDiscoveryObservation(issue: issue, disposition: disposition)
      )
    }
    return observations
  }

  private static func isWorkflowLabel(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
  }
}
