import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable multipart GitHub marker publication")
struct GitHubMarkerPublisherTests {
  @Test("all parts are prepared, sent once, reconstructed, and attributed")
  func multipartAttribution() async throws {
    let fixture = try await MarkerPublisherFixture()
    defer { fixture.remove() }
    let document = String(repeating: "a", count: GitHubMarkerCodec.sliceByteLimit + 500)

    let first = try await fixture.publisher.publish(
      fixture.request(document: document)
    )
    let second = try await fixture.publisher.publish(
      fixture.request(document: document)
    )

    #expect(first.disposition == .attributed)
    #expect(first.comments.count == 2)
    #expect(first.intentIDs.count == 2)
    #expect(first.documentSHA256 == second.documentSHA256)
    #expect(second.disposition == .attributed)
    #expect(await fixture.api.sendCount == 2)
    #expect(
      (try await fixture.intents.intents(jobID: fixture.job.id)).map(\.state) == [
        .attributed, .attributed,
      ])
  }

  @Test("authorized retry reads the old marker generation before resend")
  func priorGenerationReadBack() async throws {
    let fixture = try await MarkerPublisherFixture(dropFirstCreate: true)
    defer { fixture.remove() }
    let document = "single-part delayed marker\n"
    let request = fixture.request(document: document)

    let first = try await fixture.publisher.publish(request)
    await fixture.api.materializeDroppedComment()
    let recovered = try await fixture.publisher.publishCheckingPriorGenerations(
      request.replacingGeneration(1),
      priorGenerations: [0]
    )

    #expect(first.disposition == .escalated)
    #expect(recovered.disposition == .attributed)
    #expect(await fixture.api.sendCount == 1)
    #expect(
      try await fixture.intents.intents(jobID: fixture.job.id).map(\.state) == [
        .attributed
      ])
  }

  @Test("reopen collects and settles every uncertain multipart intent")
  func multipartReopenSettlesAllParts() async throws {
    let fixture = try await MarkerPublisherFixture()
    defer { fixture.remove() }
    let document = String(repeating: "r", count: GitHubMarkerCodec.sliceByteLimit + 500)
    let request = fixture.request(document: document)
    let documentDigest = GitHubMarkerCodec.sha256(
      GitHubMarkerCodec.canonicalDocumentBytes(document)
    )
    let identity = GitHubMarkerIdentity(
      kind: request.kind,
      repositoryNodeID: request.repositoryNodeID,
      objectNodeID: request.objectNodeID,
      revision: request.revision,
      idempotencyKey: markerTestDigest([
        request.jobID.uuidString.lowercased(),
        request.operation.rawValue,
        "generation:\(request.generation)",
        request.repositoryNodeID,
        request.objectNodeID,
        request.revision,
        documentDigest,
      ])
    )
    let parts = try GitHubMarkerCodec.build(document: document, identity: identity)
    let executor = GitHubMutationExecutor(intents: fixture.intents, broker: fixture.api)
    for part in parts {
      _ = try await executor.prepareAndSend(
        jobID: request.jobID,
        idempotencyKey: GitHubMarkerPublisher.partIdempotencyKey(
          identity: identity,
          index: part.index,
          payloadSHA256: part.payloadSHA256
        ),
        mutation: request.operation,
        target: "owner/repo/issues/1",
        expectedStateDigest: documentDigest,
        operation: .createComment(
          owner: "owner",
          repository: "repo",
          number: 1,
          body: part.body
        ),
        now: request.now
      )
    }
    #expect(
      try await fixture.intents.intents(jobID: request.jobID).allSatisfy {
        $0.state == .reconcileRequired
      })
    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let reopenedIntents = MutationIntentStore(database: reopenedDatabase)
    let reopenedPublisher = GitHubMarkerPublisher(
      executor: GitHubMutationExecutor(intents: reopenedIntents, broker: fixture.api),
      intents: reopenedIntents,
      reads: fixture.api,
      sleeper: ImmediateMutationSleeper(),
      now: { Date(timeIntervalSince1970: 80_002) }
    )

    let result = try await reopenedPublisher.publish(request)

    #expect(result.disposition == .attributed)
    #expect(result.intentIDs.count == parts.count)
    #expect(await fixture.api.sendCount == parts.count)
    #expect(
      try await reopenedIntents.intents(jobID: request.jobID).allSatisfy {
        $0.state == .attributed
      })
    await reopenedDatabase.close()
  }

  @Test("a response-lost partial multipart create reconciles and escalates without another send")
  func partialUnknownEscalates() async throws {
    let fixture = try await MarkerPublisherFixture(failAfterFirstCreate: true)
    defer { fixture.remove() }
    let document = String(repeating: "b", count: GitHubMarkerCodec.sliceByteLimit + 500)

    let first = try await fixture.publisher.publish(fixture.request(document: document))
    await fixture.api.stopFailing()
    let recovered = try await fixture.publisher.publish(
      fixture.request(document: document)
    )

    #expect(first.disposition == .escalated)
    #expect(recovered.disposition == .escalated)
    #expect(recovered.comments.isEmpty)
    #expect(await fixture.api.sendCount == 1)
    #expect(
      (try await fixture.intents.intents(jobID: fixture.job.id)).map(\.state) == [
        .escalated
      ])
  }
}

private final class MarkerPublisherFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let intents: MutationIntentStore
  let api: MarkerGitHubAPI
  let publisher: GitHubMarkerPublisher
  let job: JobRecord
  let now = Date(timeIntervalSince1970: 80_000)

  init(
    failAfterFirstCreate: Bool = false,
    dropFirstCreate: Bool = false
  ) async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-marker-publisher-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
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
        kind: .prReview,
        objectNodeID: "pr-node",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 1,
      contractVersionUsed: "w6-test",
      priority: .prReview,
      firstStep: .review,
      now: now
    )
    guard case .created(let job) = created else {
      throw MarkerPublisherFixtureError.suppressed
    }
    self.job = job
    intents = MutationIntentStore(database: database)
    api = MarkerGitHubAPI(
      failAfterFirstCreate: failAfterFirstCreate,
      dropFirstCreate: dropFirstCreate
    )
    let executor = GitHubMutationExecutor(intents: intents, broker: api)
    publisher = GitHubMarkerPublisher(
      executor: executor,
      intents: intents,
      reads: api,
      sleeper: ImmediateMutationSleeper(),
      now: { Date(timeIntervalSince1970: 80_001) }
    )
  }

  func request(document: String) -> GitHubMarkerPublicationRequest {
    GitHubMarkerPublicationRequest(
      jobID: job.id,
      operation: .createMarkerComment,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repo"),
      repositoryNodeID: "repository-node",
      objectNodeID: "pr-node",
      number: 1,
      revision: String(repeating: "a", count: 40),
      kind: .review,
      authorID: 7,
      document: document,
      now: now
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor MarkerGitHubAPI: GitHubMutationSending, GitHubMutationReadAPI {
  private var comments: [GitHubComment] = []
  private var failAfterFirstCreate: Bool
  private var dropFirstCreate: Bool
  private var droppedBody: String?
  private(set) var sendCount = 0

  init(failAfterFirstCreate: Bool, dropFirstCreate: Bool) {
    self.failAfterFirstCreate = failAfterFirstCreate
    self.dropFirstCreate = dropFirstCreate
  }

  func stopFailing() {
    failAfterFirstCreate = false
  }

  func materializeDroppedComment() {
    guard let body = droppedBody else { return }
    droppedBody = nil
    appendComment(body)
  }

  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> Void
  ) async throws -> GitHubBrokerResponse {
    try await beforeSend()
    guard case .createComment(_, _, _, let body) = operation else {
      throw MarkerPublisherFixtureError.unexpectedOperation
    }
    sendCount += 1
    if dropFirstCreate {
      dropFirstCreate = false
      droppedBody = body
      throw URLError(.networkConnectionLost)
    }
    appendComment(body)
    if failAfterFirstCreate, sendCount == 1 {
      throw URLError(.networkConnectionLost)
    }
    return GitHubBrokerResponse(
      operation: operation,
      disposition: .success,
      statusCode: 201,
      headers: [:],
      body: Data()
    )
  }

  private func appendComment(_ body: String) {
    comments.append(
      GitHubComment(
        id: Int64(comments.count + 1),
        nodeID: "comment-\(comments.count + 1)",
        body: body,
        user: GitHubUser(id: 7, nodeID: "jidoka-user", login: "jidoka-code"),
        createdAt: "2026-08-08T00:00:00Z",
        updatedAt: "2026-08-08T00:00:00Z",
        htmlURL: "https://github.com/owner/repo/issues/1#issuecomment-\(comments.count + 1)"
      )
    )
  }

  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  {
    throw MarkerPublisherFixtureError.unexpectedOperation
  }

  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue {
    throw MarkerPublisherFixtureError.unexpectedOperation
  }

  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  {
    comments
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
    nil
  }

  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
  {
    nil
  }
}

private struct ImmediateMutationSleeper: MutationReconciliationSleeper {
  func sleep(seconds: TimeInterval) async throws {}
}

private func markerTestDigest(_ fields: [String]) -> String {
  let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  return GitHubMarkerCodec.sha256(Data(framed.utf8))
}

private enum MarkerPublisherFixtureError: Error {
  case suppressed
  case unexpectedOperation
}
