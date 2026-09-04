import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable exact workflow-label mutations")
struct GitHubWorkflowLabelMutatorTests {
  @Test("a changed expected workflow-label subset blocks before every send")
  func stalePreconditionStopsSend() async throws {
    let fixture = try await WorkflowLabelFixture()
    defer { fixture.remove() }
    await fixture.api.setWorkflowLabels(["agent:human"])

    await #expect(throws: GitHubWorkflowLabelMutatorError.preconditionMismatch) {
      try await fixture.mutator.mutate(fixture.request())
    }

    #expect(await fixture.api.sendCount == 0)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:human"])
  }

  @Test("historical attributed intents cannot authorize a changed current label set")
  func attributedHistoryDoesNotBypassPrecondition() async throws {
    let fixture = try await WorkflowLabelFixture()
    defer { fixture.remove() }
    _ = try await fixture.mutator.mutate(fixture.request())
    await fixture.api.setWorkflowLabels(["agent:human"])

    await #expect(throws: GitHubWorkflowLabelMutatorError.preconditionMismatch) {
      try await fixture.mutator.mutate(fixture.request())
    }

    #expect(await fixture.api.sendCount == 2)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:human"])
  }

  @Test("reopen resumes an attributed prefix and a prepared unsent suffix")
  func reopenResumesAttributedPrefix() async throws {
    let fixture = try await WorkflowLabelFixture(failBeforeSecondMutation: true)
    defer { fixture.remove() }

    await #expect(throws: URLError.self) {
      try await fixture.mutator.mutate(fixture.request())
    }
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:ready", "agent:wip"])
    let interruptedStates = try await fixture.intents.intents(jobID: fixture.job.id)
      .map(\.state)
    #expect(interruptedStates.count == 2)
    #expect(interruptedStates.contains(.attributed))
    #expect(interruptedStates.contains(.prepared))
    await fixture.database.close()
    let reopened = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopenedIntents = MutationIntentStore(database: reopened)
    let authority = ExplicitTestRolloutEffectAuthority(intents: reopenedIntents)
    await fixture.api.resumeNormally()
    let mutator = GitHubWorkflowLabelMutator(
      executor: GitHubMutationExecutor(
        intents: reopenedIntents,
        broker: fixture.api,
        authority: authority
      ),
      intents: reopenedIntents,
      reads: fixture.api,
      authority: authority,
      sleeper: WorkflowLabelImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 110_002) }
    )

    let result = try await mutator.mutate(fixture.request())

    #expect(result.disposition == .attributed)
    #expect(await fixture.api.sendCount == 2)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:wip"])
    #expect(
      try await reopenedIntents.intents(jobID: fixture.job.id).map(\.state) == [
        .attributed, .attributed,
      ])
    await reopened.close()
  }

  @Test("claim transition sends each operation once and reentry only reads")
  func exactClaimTransition() async throws {
    let fixture = try await WorkflowLabelFixture()
    defer { fixture.remove() }

    let first = try await fixture.mutator.mutate(fixture.request())
    let second = try await fixture.mutator.mutate(fixture.request())

    #expect(first.disposition == .attributed)
    #expect(second.disposition == .attributed)
    #expect(first.intentIDs.count == 2)
    #expect(await fixture.api.sendCount == 2)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:wip"])
    #expect(
      try await fixture.intents.intents(jobID: fixture.job.id).allSatisfy {
        $0.state == .attributed
      })
  }

  @Test("unknown composite label send with no effect remains safely retryable")
  func compositeUnknownNoEffectRetries() async throws {
    let fixture = try await WorkflowLabelFixture(failBeforeFirstEffect: true)
    defer { fixture.remove() }

    let result = try await fixture.mutator.mutate(fixture.request())

    #expect(result.disposition == .retryAllowed)
    #expect(await fixture.api.sendCount == 1)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:ready"])
    #expect(
      try await fixture.intents.intents(jobID: fixture.job.id).map(\.state) == [
        .retryAllowed
      ])
  }

  @Test("lost response after a verified first operation resumes the attributed prefix")
  func partialLostResponse() async throws {
    let fixture = try await WorkflowLabelFixture(failAfterFirstMutation: true)
    defer { fixture.remove() }

    let result = try await fixture.mutator.mutate(fixture.request())

    #expect(result.disposition == .attributed)
    #expect(await fixture.api.sendCount == 2)
    #expect(await fixture.api.currentWorkflowLabels() == ["agent:wip"])
    #expect(
      try await fixture.intents.intents(jobID: fixture.job.id).map(\.state) == [
        .attributed, .attributed,
      ])
  }
}

private final class WorkflowLabelFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let databaseURL: URL
  let intents: MutationIntentStore
  let api: WorkflowLabelAPI
  let mutator: GitHubWorkflowLabelMutator
  let job: JobRecord
  let now = Date(timeIntervalSince1970: 110_000)

  init(
    failAfterFirstMutation: Bool = false,
    failBeforeSecondMutation: Bool = false,
    failBeforeFirstEffect: Bool = false
  ) async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-workflow-labels-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("state.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
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
      now: now
    )
    let created = try await DurableJobStore(database: database).createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "issue-node",
        revisionKey: String(repeating: "a", count: 64)
      ),
      objectNumber: 1,
      contractVersionUsed: "w6-test",
      priority: .issueImplementation,
      firstStep: .claimReady,
      now: now
    )
    guard case .created(let value) = created else {
      throw WorkflowLabelFixtureError.suppressed
    }
    job = value
    intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    api = WorkflowLabelAPI(
      failAfterFirstMutation: failAfterFirstMutation,
      failBeforeSecondMutation: failBeforeSecondMutation,
      failBeforeFirstEffect: failBeforeFirstEffect
    )
    mutator = GitHubWorkflowLabelMutator(
      executor: GitHubMutationExecutor(
        intents: intents,
        broker: api,
        authority: authority
      ),
      intents: intents,
      reads: api,
      authority: authority,
      sleeper: WorkflowLabelImmediateSleeper(),
      now: { Date(timeIntervalSince1970: 110_001) }
    )
  }

  func request() -> GitHubWorkflowLabelMutationRequest {
    GitHubWorkflowLabelMutationRequest(
      jobID: job.id,
      operation: .claimIssue,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
      number: 1,
      expected: ["agent:ready"],
      desired: ["agent:wip"],
      generation: 1,
      now: now
    )
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor WorkflowLabelAPI: GitHubMutationReadAPI, GitHubMutationSending {
  private var labels: Set<String> = ["agent:ready"]
  private let failAfterFirstMutation: Bool
  private var failBeforeSecondMutation: Bool
  private let failBeforeFirstEffect: Bool
  private(set) var sendCount = 0

  init(
    failAfterFirstMutation: Bool,
    failBeforeSecondMutation: Bool,
    failBeforeFirstEffect: Bool
  ) {
    self.failAfterFirstMutation = failAfterFirstMutation
    self.failBeforeSecondMutation = failBeforeSecondMutation
    self.failBeforeFirstEffect = failBeforeFirstEffect
  }

  func currentWorkflowLabels() -> Set<String> { labels }

  func setWorkflowLabels(_ values: Set<String>) {
    labels = values
  }

  func resumeNormally() {
    failBeforeSecondMutation = false
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse {
    if failBeforeSecondMutation, sendCount == 1 {
      throw URLError(.networkConnectionLost)
    }
    _ = try await beforeSend()
    sendCount += 1
    if failBeforeFirstEffect, sendCount == 1 {
      throw URLError(.networkConnectionLost)
    }
    switch operation {
    case .addIssueLabels(_, _, _, let values):
      labels.formUnion(values)
    case .removeIssueLabel(_, _, _, let value):
      labels.remove(value)
    default:
      throw WorkflowLabelFixtureError.unexpectedOperation
    }
    if failAfterFirstMutation, sendCount == 1 {
      throw URLError(.networkConnectionLost)
    }
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: 200,
      headers: [:],
      body: Data()
    )
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    throw WorkflowLabelFixtureError.unexpectedOperation
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw WorkflowLabelFixtureError.unexpectedOperation
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    []
  }

  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  {
    labels.map {
      GitHubLabel(
        id: Int64($0.utf8.count),
        nodeID: "label-\($0)",
        name: $0,
        color: "abcdef",
        description: nil
      )
    }
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
    nil
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }
}

private struct WorkflowLabelImmediateSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private enum WorkflowLabelFixtureError: Error {
  case suppressed
  case unexpectedOperation
}
