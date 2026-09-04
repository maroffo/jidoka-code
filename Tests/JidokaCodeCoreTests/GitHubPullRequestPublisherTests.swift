import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable pull request create publication")
struct GitHubPullRequestPublisherTests {
  @Test("a crash after durable prepare but before send is sent exactly once on retry")
  func preparedIntentRetriesSend() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .throwBeforeSend)
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.publisher.publish(fixture.request)
    }
    await fixture.api.resumeWithCreate()
    let recovered = try await fixture.publisher.publish(fixture.request)

    #expect(recovered.disposition == .attributed)
    #expect(await fixture.api.sendCount == 1)
  }

  @Test("lost response after create attributes the exact PR and reentry never sends again")
  func lostResponseCreated() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .createThenThrow)
    defer { fixture.remove() }

    let first = try await fixture.publisher.publish(fixture.request)
    let second = try await fixture.publisher.publish(fixture.request)

    #expect(first.disposition == .attributed)
    #expect(first.pullRequest?.nodeID == "pr-node-44")
    #expect(second.disposition == .attributed)
    #expect(await fixture.api.sendCount == 1)
  }

  @Test("an exact PR that becomes visible after escalation is attributed by read-only late check")
  func lateVisibilityAttributes() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .throwAbsent)
    defer { fixture.remove() }

    let first = try await fixture.publisher.publish(fixture.request)
    await fixture.api.materializeLastRequest()
    let late = try await fixture.publisher.readBackLate(fixture.request)

    #expect(first.disposition == .escalated)
    #expect(late.disposition == .attributed)
    #expect(late.pullRequest?.nodeID == "pr-node-44")
    #expect(await fixture.api.sendCount == 1)
  }

  @Test("global retry generation does not require a nonexistent prior PR intent")
  func missingPriorGenerationDoesNotBlockFirstPR() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .createThenThrow)
    defer { fixture.remove() }

    let result = try await fixture.publisher.publishCheckingPriorGenerations(
      fixture.request.replacingGeneration(1),
      priorGenerations: [0]
    )

    #expect(result.disposition == .attributed)
    #expect(result.pullRequest?.nodeID == "pr-node-44")
    #expect(await fixture.api.sendCount == 1)
  }

  @Test("authorized retry reads the old generation before creating a new PR")
  func authorizedRetryChecksPriorGeneration() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .throwAbsent)
    defer { fixture.remove() }

    let first = try await fixture.publisher.publish(fixture.request)
    await fixture.api.materializeLastRequest()
    let recovered = try await fixture.publisher.publishCheckingPriorGenerations(
      fixture.request.replacingGeneration(1),
      priorGenerations: [0]
    )

    #expect(first.disposition == .escalated)
    #expect(recovered.disposition == .attributed)
    #expect(recovered.pullRequest?.nodeID == "pr-node-44")
    #expect(await fixture.api.sendCount == 1)
  }

  @Test("retry checks every older PR generation, not only the immediately preceding one")
  func multiplePriorGenerationsAreChecked() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .throwAbsent)
    defer { fixture.remove() }

    _ = try await fixture.publisher.publish(fixture.request)
    _ = try await fixture.publisher.publish(fixture.request.replacingGeneration(1))
    await fixture.api.materializeRequest(at: 0)
    let recovered = try await fixture.publisher.publishCheckingPriorGenerations(
      fixture.request.replacingGeneration(2),
      priorGenerations: [0, 1]
    )

    #expect(recovered.disposition == .attributed)
    #expect(recovered.pullRequest?.nodeID == "pr-node-44")
    #expect(await fixture.api.sendCount == 2)
  }

  @Test("lost response with no PR escalates and cannot recreate")
  func lostResponseAbsent() async throws {
    let fixture = try await PullRequestPublisherFixture(mode: .throwAbsent)
    defer { fixture.remove() }

    let first = try await fixture.publisher.publish(fixture.request)
    let second = try await fixture.publisher.publish(fixture.request)

    #expect(first.disposition == .escalated)
    #expect(first.pullRequest == nil)
    #expect(second.disposition == .escalated)
    #expect(await fixture.api.sendCount == 1)
  }
}

private final class PullRequestPublisherFixture: @unchecked Sendable {
  let root: URL
  let api: PullRequestPublisherAPI
  let publisher: GitHubPullRequestPublisher
  let request: GitHubPullRequestPublicationRequest

  init(mode: PullRequestPublisherAPI.Mode) async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-pr-publisher-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
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
      now: Date(timeIntervalSince1970: 140_000)
    )
    let creation = try await DurableJobStore(database: database).createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "issue-node",
        revisionKey: String(repeating: "a", count: 64)
      ),
      objectNumber: 1,
      contractVersionUsed: "w6-test",
      priority: .issueImplementation,
      firstStep: .openPullRequest,
      now: Date(timeIntervalSince1970: 140_000)
    )
    guard case .created(let job) = creation else {
      throw PullRequestPublisherFixtureError.suppressed
    }
    let headSHA = String(repeating: "b", count: 40)
    api = PullRequestPublisherAPI(mode: mode, headSHA: headSHA)
    let intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    publisher = GitHubPullRequestPublisher(
      executor: GitHubMutationExecutor(
        intents: intents,
        broker: api,
        authority: authority
      ),
      intents: intents,
      reads: api,
      authority: authority,
      sleeper: PullRequestPublisherImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 140_001) }
    )
    request = GitHubPullRequestPublicationRequest(
      jobID: job.id,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
      title: "Agent implementation",
      head: "agent/issue-1-fixture",
      base: "main",
      body: "Closes #1\n",
      expectedHeadSHA: headSHA,
      generation: 0,
      now: Date(timeIntervalSince1970: 140_000)
    )
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor PullRequestPublisherAPI: GitHubMutationReadAPI, GitHubMutationSending {
  enum Mode: Equatable { case createThenThrow, throwAbsent, throwBeforeSend, createSuccess }

  private var mode: Mode
  let headSHA: String
  private var value: GitHubPullRequest?
  private var requests: [GitHubCreatePullRequest] = []
  private(set) var sendCount = 0

  init(mode: Mode, headSHA: String) {
    self.mode = mode
    self.headSHA = headSHA
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse {
    if mode == .throwBeforeSend {
      throw URLError(.networkConnectionLost)
    }
    _ = try await beforeSend()
    sendCount += 1
    guard case .createPullRequest(_, _, let request) = operation else {
      throw PullRequestPublisherFixtureError.unexpectedOperation
    }
    requests.append(request)
    if mode == .createThenThrow || mode == .createSuccess {
      materialize(request)
    }
    if mode == .createSuccess {
      return GitHubBrokerResponse(
        operation: operation,
        disposition: .success,
        statusCode: 201,
        headers: [:],
        body: Data()
      )
    }
    throw URLError(.networkConnectionLost)
  }

  func resumeWithCreate() {
    mode = .createSuccess
  }

  func materializeLastRequest() {
    if let request = requests.last { materialize(request) }
  }

  func materializeRequest(at index: Int) {
    guard requests.indices.contains(index) else { return }
    materialize(requests[index])
  }

  private func materialize(_ request: GitHubCreatePullRequest) {
    let repository = GitHubPullRepository(
      id: 1,
      nodeID: "repository-node",
      fullName: "owner/repo"
    )
    value = GitHubPullRequest(
      id: 44,
      nodeID: "pr-node-44",
      number: 44,
      state: "open",
      draft: false,
      title: request.title,
      body: request.body,
      htmlURL: "https://github.com/owner/repo/pull/44",
      user: GitHubUser(id: 7, nodeID: "jidoka-user", login: "jidoka-code"),
      head: GitHubPullReference(ref: request.head, sha: headSHA, repository: repository),
      base: GitHubPullReference(
        ref: request.base,
        sha: String(repeating: "c", count: 40),
        repository: repository
      )
    )
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    guard let value, value.number == number else {
      throw PullRequestPublisherFixtureError.unexpectedOperation
    }
    return value
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw PullRequestPublisherFixtureError.unexpectedOperation
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
    guard let value, value.head.ref == head, value.base.ref == base else { return [] }
    return [value]
  }

  func repositoryLabel(owner: String, repository: String, label: String) async throws
    -> GitHubLabel?
  {
    nil
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }
}

private struct PullRequestPublisherImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum PullRequestPublisherFixtureError: Error {
  case suppressed
  case unexpectedOperation
}
