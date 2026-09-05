import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Prepared-before-send GitHub mutation executor")
struct GitHubMutationExecutorTests {
  @Test("intent is sendStarted before transport and a repeated create never sends again")
  func preparedBeforeSend() async throws {
    let fixture = try await MutationExecutorFixture()
    defer { fixture.remove() }
    let key = GitHubMarkerCodec.sha256(Data("executor-key".utf8))
    let transport = InspectingMutationTransport(
      store: fixture.intents,
      idempotencyKey: key,
      stubs: [.response(status: 201, body: try commentResponseJSON())]
    )
    let authority = ExplicitTestRolloutEffectAuthority(intents: fixture.intents)
    let executor = GitHubMutationExecutor(
      intents: fixture.intents,
      broker: GitHubBroker(
        tokenProvider: ExecutorTokenProvider(),
        transport: transport,
        readAuthority: authority,
        effectAuthority: authority
      ),
      authority: authority
    )
    let operation = GitHubOperation.createComment(
      owner: "owner",
      repository: "repo",
      number: 1,
      body: "marker body"
    )

    let result = try await executor.prepareAndSend(
      jobID: fixture.jobID,
      idempotencyKey: key,
      mutation: .createMarkerComment,
      target: "issue:I_issue:comment",
      expectedStateDigest: String(repeating: "a", count: 64),
      operation: operation,
      now: fixture.now
    )
    #expect(result.intent.state == .reconcileRequired)
    #expect(result.intent.sendEpoch == 1)
    #expect(result.requiresReadBack)
    #expect(await transport.observedStates() == [.sendStarted])
    #expect(await transport.sendCount() == 1)

    await #expect(throws: MutationIntentStoreError.sendNotAllowed(.reconcileRequired)) {
      _ = try await executor.prepareAndSend(
        jobID: fixture.jobID,
        idempotencyKey: key,
        mutation: .createMarkerComment,
        target: "issue:I_issue:comment",
        expectedStateDigest: String(repeating: "a", count: 64),
        operation: operation,
        now: fixture.now
      )
    }
    #expect(await transport.sendCount() == 1)
  }

  @Test("request digest, operation mapping, and read/write separation fail closed")
  func closedDispatchSurface() async throws {
    let fixture = try await MutationExecutorFixture()
    defer { fixture.remove() }
    let transport = InspectingMutationTransport(
      store: fixture.intents,
      idempotencyKey: String(repeating: "f", count: 64),
      stubs: []
    )
    let authority = ExplicitTestRolloutEffectAuthority(intents: fixture.intents)
    let executor = GitHubMutationExecutor(
      intents: fixture.intents,
      broker: GitHubBroker(
        tokenProvider: ExecutorTokenProvider(),
        transport: transport,
        readAuthority: authority,
        effectAuthority: authority
      ),
      authority: authority
    )
    await #expect(throws: GitHubMutationExecutorError.readOperationForbidden) {
      _ = try await executor.prepareAndSend(
        jobID: fixture.jobID,
        idempotencyKey: String(repeating: "f", count: 64),
        mutation: .createMarkerComment,
        target: "target",
        expectedStateDigest: String(repeating: "a", count: 64),
        operation: .issue(owner: "owner", repository: "repo", number: 1),
        now: fixture.now
      )
    }
    await #expect(throws: GitHubMutationExecutorError.operationMismatch) {
      _ = try await executor.prepareAndSend(
        jobID: fixture.jobID,
        idempotencyKey: String(repeating: "f", count: 64),
        mutation: .createPullRequest,
        target: "target",
        expectedStateDigest: String(repeating: "a", count: 64),
        operation: .createComment(
          owner: "owner", repository: "repo", number: 1, body: "body"),
        now: fixture.now
      )
    }
    await #expect(throws: GitHubMutationExecutorError.gitTransportRequired) {
      _ = try await executor.prepareAndSend(
        jobID: fixture.jobID,
        idempotencyKey: String(repeating: "f", count: 64),
        mutation: .publishBranch,
        target: "target",
        expectedStateDigest: String(repeating: "a", count: 64),
        operation: .createComment(
          owner: "owner", repository: "repo", number: 1, body: "body"),
        now: fixture.now
      )
    }
    #expect(await transport.sendCount() == 0)
  }

  @Test("credential preflight failure leaves the durable intent provably unsent")
  func credentialPreflight() async throws {
    let fixture = try await MutationExecutorFixture()
    defer { fixture.remove() }
    let key = GitHubMarkerCodec.sha256(Data("credential-preflight".utf8))
    let transport = InspectingMutationTransport(
      store: fixture.intents,
      idempotencyKey: key,
      stubs: []
    )
    let authority = ExplicitTestRolloutEffectAuthority(intents: fixture.intents)
    let executor = GitHubMutationExecutor(
      intents: fixture.intents,
      broker: GitHubBroker(
        tokenProvider: InvalidExecutorTokenProvider(),
        transport: transport,
        readAuthority: authority,
        effectAuthority: authority
      ),
      authority: authority
    )
    await #expect(throws: GitHubBrokerError.invalidCredential) {
      _ = try await executor.prepareAndSend(
        jobID: fixture.jobID,
        idempotencyKey: key,
        mutation: .createMarkerComment,
        target: "credential-preflight",
        expectedStateDigest: String(repeating: "a", count: 64),
        operation: .createComment(
          owner: "owner", repository: "repo", number: 1, body: "body"),
        now: fixture.now
      )
    }
    let stored = try await fixture.intents.intent(idempotencyKey: key)
    let intent = try #require(stored)
    #expect(intent.state == .prepared)
    #expect(intent.sendEpoch == 0)
    #expect(await transport.sendCount() == 0)
  }

  @Test("definitive denial escalates while timeout remains read-back only")
  func responseClassification() async throws {
    let fixture = try await MutationExecutorFixture()
    defer { fixture.remove() }
    let deniedKey = GitHubMarkerCodec.sha256(Data("denied".utf8))
    let timeoutKey = GitHubMarkerCodec.sha256(Data("timeout".utf8))
    let transport = InspectingMutationTransport(
      store: fixture.intents,
      idempotencyKey: deniedKey,
      stubs: [
        .response(status: 401, body: Data()),
        .failure(.timedOut),
      ]
    )
    let authority = ExplicitTestRolloutEffectAuthority(intents: fixture.intents)
    let broker = GitHubBroker(
      tokenProvider: ExecutorTokenProvider(),
      transport: transport,
      readAuthority: authority,
      effectAuthority: authority
    )
    let executor = GitHubMutationExecutor(
      intents: fixture.intents,
      broker: broker,
      authority: authority
    )
    let denied = try await executor.prepareAndSend(
      jobID: fixture.jobID,
      idempotencyKey: deniedKey,
      mutation: .createMarkerComment,
      target: "denied",
      expectedStateDigest: String(repeating: "a", count: 64),
      operation: .createComment(owner: "owner", repository: "repo", number: 1, body: "body"),
      now: fixture.now
    )
    #expect(denied.intent.state == .escalated)
    #expect(!denied.requiresReadBack)

    await transport.expect(idempotencyKey: timeoutKey)
    let timeout = try await executor.prepareAndSend(
      jobID: fixture.jobID,
      idempotencyKey: timeoutKey,
      mutation: .createMarkerComment,
      target: "timeout",
      expectedStateDigest: String(repeating: "a", count: 64),
      operation: .createComment(owner: "owner", repository: "repo", number: 1, body: "body"),
      now: fixture.now
    )
    #expect(timeout.intent.state == .reconcileRequired)
    #expect(timeout.requiresReadBack)
  }
}

private struct ExecutorTokenProvider: GitHubTokenProviding {
  func token() async throws -> Data { Data(repeating: 0x74, count: 32) }
}

private struct InvalidExecutorTokenProvider: GitHubTokenProviding {
  func token() async throws -> Data { Data("invalid".utf8) }
}

private enum ExecutorTransportStub: Sendable {
  case response(status: Int, body: Data)
  case failure(URLError.Code)
}

private actor InspectingMutationTransport: GitHubHTTPTransport {
  private let store: MutationIntentStore
  private var idempotencyKey: String
  private var stubs: [ExecutorTransportStub]
  private var states: [MutationIntentState] = []
  private var count = 0

  init(
    store: MutationIntentStore,
    idempotencyKey: String,
    stubs: [ExecutorTransportStub]
  ) {
    self.store = store
    self.idempotencyKey = idempotencyKey
    self.stubs = stubs
  }

  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    count += 1
    if let intent = try await store.intent(idempotencyKey: idempotencyKey) {
      states.append(intent.state)
    }
    guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
    switch stubs.removeFirst() {
    case .response(let status, let body):
      guard let url = request.url else { throw URLError(.badURL) }
      return GitHubHTTPResponse(
        statusCode: status,
        url: url,
        headers: [:],
        body: body
      )
    case .failure(let code):
      throw URLError(code)
    }
  }

  func expect(idempotencyKey: String) {
    self.idempotencyKey = idempotencyKey
  }

  func observedStates() -> [MutationIntentState] { states }
  func sendCount() -> Int { count }
}

private final class MutationExecutorFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let intents: MutationIntentStore
  let jobID: UUID
  let now = Date(timeIntervalSince1970: 30_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-mutation-executor-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
    let repositoryID = UUID()
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', 'repo', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text("R_\(repositoryID.uuidString.lowercased())"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    let jobs = DurableJobStore(database: database, enforceRolloutAuthority: false)
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueTriage,
        objectNodeID: "I_issue",
        revisionKey: "initial-triage"
      ),
      contractVersionUsed: "v1",
      priority: .triage,
      firstStep: .triage,
      now: now
    )
    guard case .created(let job) = created else {
      throw MutationIntentStoreError.decode("job suppressed")
    }
    jobID = job.id
    intents = MutationIntentStore(database: database)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func commentResponseJSON() throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "id": 1,
    "node_id": "C_1",
    "body": "marker body",
    "user": ["id": 1, "node_id": "U_1", "login": "bot"],
    "created_at": "2026-08-06T00:00:00Z",
    "updated_at": "2026-08-06T00:00:00Z",
    "html_url": "https://github.com/owner/repo/issues/1#issuecomment-1",
  ])
}
