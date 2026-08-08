import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Workflow label bootstrap")
struct GitHubWorkflowLabelBootstrapperTests {
  @Test("creates only missing labels and preserves existing metadata on every rerun")
  func bootstrapMissingOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-label-bootstrap-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let repositoryID = UUID()
    try await ConfigurationStore(database: database).upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "repository-node",
        owner: "owner",
        name: "repo",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: true,
        implementationEnabled: true,
        enabled: true
      ),
      now: Date(timeIntervalSince1970: 150_000)
    )
    let creation = try await DurableJobStore(database: database).createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueTriage,
        objectNodeID: "issue-node",
        revisionKey: "initial-triage"
      ),
      objectNumber: 1,
      contractVersionUsed: "w6-test",
      priority: .triage,
      firstStep: .triage,
      now: Date(timeIntervalSince1970: 150_000)
    )
    guard case .created(let job) = creation else { return }
    let api = WorkflowLabelBootstrapAPI()
    let intents = MutationIntentStore(database: database)
    let bootstrapper = GitHubWorkflowLabelBootstrapper(
      executor: GitHubMutationExecutor(intents: intents, broker: api),
      intents: intents,
      reads: api,
      sleeper: WorkflowLabelBootstrapImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 150_001) }
    )

    let first = try await bootstrapper.bootstrap(
      jobID: job.id,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
      at: Date(timeIntervalSince1970: 150_000)
    )
    let second = try await bootstrapper.bootstrap(
      jobID: job.id,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
      at: Date(timeIntervalSince1970: 150_000)
    )

    #expect(first.disposition == .ready)
    #expect(first.preservedNames == ["agent:ready"])
    #expect(first.createdNames.count == 7)
    #expect(second.preservedNames.count == 8)
    #expect(second.createdNames.isEmpty)
    #expect(await api.sendCount == 7)
    #expect(await api.label(named: "agent:ready")?.color == "123456")
  }
}

private actor WorkflowLabelBootstrapAPI: GitHubMutationReadAPI, GitHubMutationSending {
  private var labels: [String: GitHubLabel] = [
    "agent:ready": GitHubLabel(
      id: 1,
      nodeID: "existing-ready",
      name: "agent:ready",
      color: "123456",
      description: "owner metadata"
    )
  ]
  private(set) var sendCount = 0

  func label(named name: String) -> GitHubLabel? { labels[name] }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> Void
  ) async throws -> GitHubBrokerResponse {
    try await beforeSend()
    guard case .createRepositoryLabel(_, _, let request) = operation else {
      throw WorkflowLabelBootstrapError.unexpectedOperation
    }
    sendCount += 1
    labels[request.name] = GitHubLabel(
      id: Int64(sendCount + 1),
      nodeID: "created-\(request.name)",
      name: request.name,
      color: request.color,
      description: request.description
    )
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: 201,
      headers: [:],
      body: Data()
    )
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    throw WorkflowLabelBootstrapError.unexpectedOperation
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw WorkflowLabelBootstrapError.unexpectedOperation
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    []
  }

  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  {
    []
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
    labels[label]
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }
}

private struct WorkflowLabelBootstrapImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum WorkflowLabelBootstrapError: Error {
  case unexpectedOperation
}
