import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("GitHub discovery with durable terminal evidence")
struct GitHubDiscoveryTests {
  @Test("PR discovery rejects drafts and terminal evidence but accepts a new head SHA")
  func pullRequestDiscovery() async throws {
    let fixture = try await DiscoveryFixture()
    defer { fixture.remove() }
    let reviewedSHA = String(repeating: "a", count: 40)
    let durableSHA = String(repeating: "b", count: 40)
    let newSHA = String(repeating: "c", count: 40)
    let reviewed = pullRequest(number: 1, nodeID: "PR_reviewed", sha: reviewedSHA)
    let durable = pullRequest(number: 2, nodeID: "PR_durable", sha: durableSHA)
    let fresh = pullRequest(number: 3, nodeID: "PR_reviewed", sha: newSHA)
    let draft = pullRequest(number: 4, nodeID: "PR_draft", sha: newSHA, draft: true)
    let closed = pullRequest(number: 5, nodeID: "PR_closed", sha: newSHA, state: "closed")

    try await fixture.reviewed.record(
      ReviewedRevisionRecord(
        repositoryNodeID: fixture.repositoryNodeID,
        pullRequestNodeID: reviewed.nodeID,
        headSHA: reviewedSHA,
        reviewContractVersionUsed: "v1",
        commentID: "1",
        commentURL: "https://github.com/owner/repo/pull/1#issuecomment-1",
        commentDigest: String(repeating: "d", count: 64),
        createdAt: fixture.now
      ))
    _ = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .prReview,
        objectNodeID: durable.nodeID,
        revisionKey: durableSHA
      ),
      contractVersionUsed: "v1",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )

    let api = StaticGitHubReadAPI(
      pullRequests: [reviewed, durable, fresh, draft, closed],
      issues: []
    )
    let discovery = GitHubDiscovery(
      api: api,
      jobs: fixture.jobs,
      reviewedRevisions: fixture.reviewed
    )
    let observations = try await discovery.pullRequests(
      owner: "owner",
      repository: "repo",
      repositoryID: fixture.repositoryID,
      repositoryNodeID: fixture.repositoryNodeID
    )
    #expect(
      observations.map(\.disposition) == [
        .reviewed,
        .durableDisposition(.inFlight),
        .candidate,
        .draft,
        .closed,
      ])
  }

  @Test("issue discovery excludes PR entries and every workflow label")
  func issueDiscovery() async throws {
    let fixture = try await DiscoveryFixture()
    defer { fixture.remove() }
    let candidate = issue(number: 1, nodeID: "I_candidate")
    let pull = issue(number: 2, nodeID: "I_pull", isPullRequest: true)
    let workflow = issue(number: 3, nodeID: "I_workflow", labels: ["Agent:Ready"])
    let domain = issue(number: 4, nodeID: "I_domain", labels: ["bug", "security"])
    let closed = issue(number: 5, nodeID: "I_closed", state: "closed")
    let durable = issue(number: 6, nodeID: "I_durable")
    _ = try await fixture.jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .issueTriage,
        objectNodeID: durable.nodeID,
        revisionKey: "initial-triage"
      ),
      contractVersionUsed: "v1",
      priority: .triage,
      firstStep: .triage,
      now: fixture.now
    )

    let api = StaticGitHubReadAPI(
      pullRequests: [],
      issues: [candidate, pull, workflow, domain, closed, durable]
    )
    let discovery = GitHubDiscovery(
      api: api,
      jobs: fixture.jobs,
      reviewedRevisions: fixture.reviewed
    )
    let observations = try await discovery.issues(
      owner: "owner",
      repository: "repo",
      repositoryID: fixture.repositoryID
    )
    #expect(
      observations.map(\.disposition) == [
        .candidate,
        .pullRequestEntry,
        .workflowLabel("Agent:Ready"),
        .candidate,
        .closed,
        .durableDisposition(.inFlight),
      ])
  }
}

private struct StaticGitHubReadAPI: GitHubReadAPI {
  let pullRequests: [GitHubPullRequest]
  let issues: [GitHubIssue]

  func listPullRequests(owner: String, repository: String) async throws
    -> [GitHubPullRequest]
  {
    pullRequests
  }

  func listIssues(owner: String, repository: String) async throws -> [GitHubIssue] {
    issues
  }
}

private final class DiscoveryFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let jobs: DurableJobStore
  let reviewed: ReviewedRevisionStore
  let repositoryID = UUID()
  let repositoryNodeID = "R_repo"
  let now = Date(timeIntervalSince1970: 20_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-discovery-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', 'repo', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text(repositoryNodeID),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    jobs = DurableJobStore(database: database)
    reviewed = ReviewedRevisionStore(database: database)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func pullRequest(
  number: Int,
  nodeID: String,
  sha: String,
  draft: Bool = false,
  state: String = "open"
) -> GitHubPullRequest {
  let user = GitHubUser(id: 1, nodeID: "U_user", login: "user")
  let repository = GitHubPullRepository(id: 1, nodeID: "R_repo", fullName: "owner/repo")
  return GitHubPullRequest(
    id: Int64(number),
    nodeID: nodeID,
    number: number,
    state: state,
    draft: draft,
    title: "PR \(number)",
    body: "body",
    htmlURL: "https://github.com/owner/repo/pull/\(number)",
    user: user,
    head: GitHubPullReference(ref: "feature", sha: sha, repository: repository),
    base: GitHubPullReference(
      ref: "main",
      sha: String(repeating: "f", count: 40),
      repository: repository
    )
  )
}

private func issue(
  number: Int,
  nodeID: String,
  labels: [String] = [],
  isPullRequest: Bool = false,
  state: String = "open"
) -> GitHubIssue {
  GitHubIssue(
    id: Int64(number),
    nodeID: nodeID,
    number: number,
    state: state,
    title: "Issue \(number)",
    body: "body",
    user: GitHubUser(id: 1, nodeID: "U_user", login: "user"),
    labels: labels.enumerated().map { index, name in
      GitHubLabel(
        id: Int64(index + 1),
        nodeID: "L_\(number)_\(index)",
        name: name,
        color: "abcdef",
        description: nil
      )
    },
    createdAt: "2026-08-06T00:00:00Z",
    pullRequest: isPullRequest
      ? GitHubIssuePullMarker(url: "https://api.github.com/repos/owner/repo/pulls/\(number)")
      : nil
  )
}
