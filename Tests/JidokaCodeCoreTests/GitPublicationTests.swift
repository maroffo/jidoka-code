import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Atomic create-only Git publication")
struct GitPublicationTests {
  @Test("system Git publishes old-zero create, reads exact SHA, and never overwrites")
  func systemTransport() async throws {
    let fixture = try GitTestRoot(
      prefix: "jidoka-publication",
      installPushGuard: true
    )
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let base = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let exact = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "exact\n",
      message: "feat: add exact change"
    )
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_fixture",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      localFixtureURL: remoteURL
    )
    let publisher = ExplicitlyAuthorizedTestGitPublisher(
      transport: fixture.git,
      authority: fixture.authority
    )
    let created = try await publisher.publishCreateOnly(
      branch: "agent/issue-1-created",
      exactSHA: exact,
      remote: remote,
      repository: source
    )
    #expect(created.disposition == .attributableEffect)
    #expect(created.sendAttempted)
    #expect(created.sendSucceeded == true)
    #expect(created.observedSHA == exact)

    let same = try await publisher.publishCreateOnly(
      branch: "agent/issue-1-created",
      exactSHA: exact,
      remote: remote,
      repository: source
    )
    #expect(same.disposition == .attributableEffect)
    #expect(!same.sendAttempted)

    _ = try await fixture.run([
      "--git-dir", remoteURL.path, "update-ref",
      "refs/heads/agent/issue-2-divergent", base,
      String(repeating: "0", count: 40),
    ])
    let divergent = try await publisher.publishCreateOnly(
      branch: "agent/issue-2-divergent",
      exactSHA: exact,
      remote: remote,
      repository: source
    )
    #expect(divergent.disposition == .escalation)
    #expect(!divergent.sendAttempted)
    #expect(divergent.observedSHA == base)
    #expect(
      try await fixture.output([
        "--git-dir", remoteURL.path, "rev-parse", "refs/heads/agent/issue-2-divergent",
      ]) == base
    )
  }

  @Test("a ref created before advertisement cannot be fast-forwarded")
  func preAdvertisementRace() async throws {
    let fixture = try GitTestRoot(
      prefix: "jidoka-publication-pre-advertisement",
      installPushGuard: true
    )
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let base = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let exact = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "exact\n",
      message: "feat: add exact change"
    )
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_pre_advertisement",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      localFixtureURL: remoteURL
    )
    let transport = PreAdvertisementRacingTransport(
      delegate: fixture.git,
      remoteRepository: remoteURL,
      competingSHA: base
    )
    let result = try await ExplicitlyAuthorizedTestGitPublisher(
      transport: transport,
      authority: fixture.authority
    ).publishCreateOnly(
      branch: "agent/issue-3-pre-advertisement",
      exactSHA: exact,
      remote: remote,
      repository: source
    )
    #expect(result.disposition == .escalation)
    #expect(result.sendAttempted)
    #expect(result.sendSucceeded == nil)
    #expect(result.observedSHA == base)
    #expect(await transport.createCount() == 1)
    #expect(
      try await fixture.output([
        "--git-dir", remoteURL.path, "rev-parse",
        "refs/heads/agent/issue-3-pre-advertisement",
      ]) == base
    )
  }

  @Test("race injection preserves the competing ref and never retries automatically")
  func race() async throws {
    let base = String(repeating: "a", count: 40)
    let exact = String(repeating: "b", count: 40)
    let transport = RacingPublicationTransport(raceSHA: base)
    let publisher = ExplicitlyAuthorizedTestGitPublisher(transport: transport)
    let result = try await publisher.publishCreateOnly(
      branch: "agent/issue-3-race",
      exactSHA: exact,
      remote: try fixtureRemote(),
      repository: URL(fileURLWithPath: "/tmp")
    )
    #expect(result.disposition == .escalation)
    #expect(result.observedSHA == base)
    #expect(result.sendAttempted)
    #expect(await transport.createCount() == 1)
    #expect(await transport.currentSHA() == base)
  }

  @Test("concurrent publication for one repository ref is rejected before a second create")
  func concurrentPublish() async throws {
    let exact = String(repeating: "c", count: 40)
    let transport = RacingPublicationTransport(raceSHA: nil, suspendRead: true)
    let publisher = ExplicitlyAuthorizedTestGitPublisher(transport: transport)
    let remote = try fixtureRemote()
    async let first = publisher.publishCreateOnly(
      branch: "agent/issue-4-concurrent",
      exactSHA: exact,
      remote: remote,
      repository: URL(fileURLWithPath: "/tmp")
    )
    while !(await transport.isReadSuspended()) { await Task.yield() }
    await #expect(throws: GitPublicationError.concurrentPublication) {
      _ = try await publisher.publishCreateOnly(
        branch: "agent/issue-4-concurrent",
        exactSHA: exact,
        remote: remote,
        repository: URL(fileURLWithPath: "/tmp")
      )
    }
    await transport.releaseRead()
    #expect(try await first.disposition == .attributableEffect)
    #expect(await transport.createCount() == 1)
  }

  @Test("branch traversal, malformed SHA, and missing commit fail before a send")
  func invalidInputs() async throws {
    let transport = RacingPublicationTransport(raceSHA: nil)
    let publisher = ExplicitlyAuthorizedTestGitPublisher(transport: transport)
    await #expect(throws: GitPublicationError.invalidBranch) {
      _ = try await publisher.publishCreateOnly(
        branch: "agent/issue-1-topic/../../escape",
        exactSHA: String(repeating: "a", count: 40),
        remote: try fixtureRemote(),
        repository: URL(fileURLWithPath: "/tmp")
      )
    }
    await #expect(throws: GitPublicationError.invalidSHA) {
      _ = try await publisher.publishCreateOnly(
        branch: "agent/issue-1-topic",
        exactSHA: "bad",
        remote: try fixtureRemote(),
        repository: URL(fileURLWithPath: "/tmp")
      )
    }
    let missing = FaultPublicationTransport(
      localCommitExists: false,
      behavior: .failureAbsent
    )
    await #expect(throws: GitPublicationError.localObjectMissing) {
      _ = try await ExplicitlyAuthorizedTestGitPublisher(
        transport: missing
      ).publishCreateOnly(
        branch: "agent/issue-1-missing",
        exactSHA: String(repeating: "a", count: 40),
        remote: try fixtureRemote(),
        repository: URL(fileURLWithPath: "/tmp")
      )
    }
    #expect(await transport.createCount() == 0)
    #expect(await missing.createCount() == 0)
  }

  @Test("durable publisher records send epoch and recovers unknown sends read-only")
  func durableIntentLifecycle() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-publication-intent")
    defer { fixture.remove() }
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repositoryID = UUID()
    try await ConfigurationStore(database: database).upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "R_intent",
        owner: "owner",
        name: "repo",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: true,
        implementationEnabled: true,
        enabled: true
      ),
      now: Date(timeIntervalSince1970: 4_000)
    )
    let creation = try await DurableJobStore(database: database, enforceRolloutAuthority: false)
      .createJob(
        identity: LogicalJobIdentity(
          repositoryID: repositoryID,
          kind: .issueImplementation,
          objectNodeID: "I_intent",
          revisionKey: "claim-1"
        ),
        objectNumber: 6,
        contractVersionUsed: "v1",
        priority: .issueImplementation,
        firstStep: .publish,
        now: Date(timeIntervalSince1970: 4_000)
      )
    let job = try #require(createdPublicationJob(creation))
    let intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    let remote = try fixtureRemote(repositoryID: repositoryID)
    let exact = String(repeating: "f", count: 40)
    let expectedState = String(repeating: "1", count: 64)

    let freshTransport = FaultPublicationTransport(behavior: .successExact)
    let freshPublisher = DurableGitPublisher(
      intents: intents,
      transport: freshTransport,
      authority: authority
    )
    let freshRequest = GitBranchPublicationRequest(
      jobID: job.id,
      idempotencyKey: String(repeating: "2", count: 64),
      branch: "agent/issue-6-fresh",
      exactSHA: exact,
      expectedStateDigest: expectedState
    )
    let fresh = try await freshPublisher.publishCreateOnly(
      request: freshRequest,
      remote: remote,
      repository: fixture.root,
      now: Date(timeIntervalSince1970: 4_001)
    )
    #expect(fresh.intent.state == .attributed)
    #expect(fresh.intent.sendEpoch == 1)
    #expect(await freshTransport.createCount() == 1)
    let duplicate = try await freshPublisher.publishCreateOnly(
      request: freshRequest,
      remote: remote,
      repository: fixture.root,
      now: Date(timeIntervalSince1970: 4_002)
    )
    #expect(duplicate.intent.state == .attributed)
    #expect(duplicate.publication == nil)
    #expect(await freshTransport.createCount() == 1)

    let recoveryRequest = GitBranchPublicationRequest(
      jobID: job.id,
      idempotencyKey: String(repeating: "3", count: 64),
      branch: "agent/issue-6-recovery",
      exactSHA: exact,
      expectedStateDigest: expectedState
    )
    let prepared = try await intents.prepare(
      jobID: job.id,
      idempotencyKey: recoveryRequest.idempotencyKey,
      operation: .publishBranch,
      target: recoveryRequest.target(remote: remote),
      expectedStateDigest: recoveryRequest.expectedStateDigest,
      requestDigest: recoveryRequest.requestDigest(remote: remote),
      now: Date(timeIntervalSince1970: 4_003)
    )
    _ = try await intents.markSendStarted(
      id: prepared.id,
      now: Date(timeIntervalSince1970: 4_004)
    )
    let recoveryTransport = FaultPublicationTransport(
      behavior: .failureAbsent,
      initialSHA: exact
    )
    let recoveryPublisher = DurableGitPublisher(
      intents: intents,
      transport: recoveryTransport,
      authority: authority
    )
    let recovered = try await recoveryPublisher.publishCreateOnly(
      request: recoveryRequest,
      remote: remote,
      repository: fixture.root,
      now: Date(timeIntervalSince1970: 4_005)
    )
    #expect(recovered.intent.state == .attributed)
    #expect(recovered.intent.sendEpoch == 1)
    #expect(await recoveryTransport.createCount() == 0)

    let absentRequest = GitBranchPublicationRequest(
      jobID: job.id,
      idempotencyKey: String(repeating: "4", count: 64),
      branch: "agent/issue-6-absent",
      exactSHA: exact,
      expectedStateDigest: expectedState
    )
    let absentPrepared = try await intents.prepare(
      jobID: job.id,
      idempotencyKey: absentRequest.idempotencyKey,
      operation: .publishBranch,
      target: absentRequest.target(remote: remote),
      expectedStateDigest: absentRequest.expectedStateDigest,
      requestDigest: absentRequest.requestDigest(remote: remote),
      now: Date(timeIntervalSince1970: 4_006)
    )
    _ = try await intents.markSendStarted(
      id: absentPrepared.id,
      now: Date(timeIntervalSince1970: 4_007)
    )
    let absentTransport = FaultPublicationTransport(behavior: .failureAbsent)
    let absent = try await DurableGitPublisher(
      intents: intents,
      transport: absentTransport,
      authority: authority
    ).publishCreateOnly(
      request: absentRequest,
      remote: remote,
      repository: fixture.root,
      now: Date(timeIntervalSince1970: 4_008)
    )
    #expect(absent.intent.state == .retryAllowed)
    #expect(absent.intent.sendEpoch == 1)
    #expect(await absentTransport.createCount() == 0)

    let unreadableRequest = GitBranchPublicationRequest(
      jobID: job.id,
      idempotencyKey: String(repeating: "5", count: 64),
      branch: "agent/issue-6-unreadable",
      exactSHA: exact,
      expectedStateDigest: expectedState
    )
    let unreadableTransport = FaultPublicationTransport(
      behavior: .successExact,
      failPostSendRead: true
    )
    await #expect(throws: GitPublicationError.readBackUnavailable) {
      _ = try await DurableGitPublisher(
        intents: intents,
        transport: unreadableTransport,
        authority: authority
      ).publishCreateOnly(
        request: unreadableRequest,
        remote: remote,
        repository: fixture.root,
        now: Date(timeIntervalSince1970: 4_009)
      )
    }
    #expect(
      try await intents.intent(idempotencyKey: unreadableRequest.idempotencyKey)?.state
        == .reconcileRequired
    )
    #expect(await unreadableTransport.createCount() == 1)
  }

  @Test("durable publisher denial leaves a prepared intent and performs no Git send")
  func durablePublisherDenial() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-publication-denied")
    defer { fixture.remove() }
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repositoryID = UUID()
    try await ConfigurationStore(database: database).upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "R_denied",
        owner: "owner",
        name: "repo",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: true,
        implementationEnabled: true,
        enabled: true
      ),
      now: Date(timeIntervalSince1970: 4_100)
    )
    let creation = try await DurableJobStore(
      database: database,
      enforceRolloutAuthority: false
    ).createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_denied",
        revisionKey: "claim-denied"
      ),
      objectNumber: 7,
      contractVersionUsed: "v1",
      priority: .issueImplementation,
      firstStep: .publish,
      now: Date(timeIntervalSince1970: 4_100)
    )
    let job = try #require(createdPublicationJob(creation))
    let intents = MutationIntentStore(database: database)
    let authority = ExplicitTestRolloutEffectAuthority(intents: intents)
    await authority.closeAdmission()
    let transport = FaultPublicationTransport(behavior: .successExact)
    let request = GitBranchPublicationRequest(
      jobID: job.id,
      idempotencyKey: String(repeating: "6", count: 64),
      branch: "agent/issue-7-denied",
      exactSHA: String(repeating: "f", count: 40),
      expectedStateDigest: String(repeating: "7", count: 64)
    )

    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await DurableGitPublisher(
        intents: intents,
        transport: transport,
        authority: authority
      ).publishCreateOnly(
        request: request,
        remote: try fixtureRemote(repositoryID: repositoryID),
        repository: fixture.root,
        now: Date(timeIntervalSince1970: 4_101)
      )
    }

    #expect(await transport.createCount() == 0)
    #expect(try await intents.intent(idempotencyKey: request.idempotencyKey)?.state == .prepared)
    await database.close()
  }

  @Test("every post-send outcome reconciles without a blind second create")
  func faultClassifications() async throws {
    let exact = String(repeating: "d", count: 40)

    let failed = FaultPublicationTransport(behavior: .failureAbsent)
    let safe = try await ExplicitlyAuthorizedTestGitPublisher(
      transport: failed
    ).publishCreateOnly(
      branch: "agent/issue-5-safe",
      exactSHA: exact,
      remote: try fixtureRemote(),
      repository: URL(fileURLWithPath: "/tmp")
    )
    #expect(safe.disposition == .safeRetry)
    #expect(safe.sendSucceeded == false)
    #expect(safe.observationComplete)

    let thrownEffect = FaultPublicationTransport(behavior: .throwAfterExactEffect)
    let attributed = try await ExplicitlyAuthorizedTestGitPublisher(
      transport: thrownEffect
    ).publishCreateOnly(
      branch: "agent/issue-5-attributed",
      exactSHA: exact,
      remote: try fixtureRemote(),
      repository: URL(fileURLWithPath: "/tmp")
    )
    #expect(attributed.disposition == .attributableEffect)
    #expect(attributed.sendSucceeded == nil)
    #expect(attributed.observedSHA == exact)

    let divergent = FaultPublicationTransport(behavior: .successDivergent)
    let escalated = try await ExplicitlyAuthorizedTestGitPublisher(
      transport: divergent
    ).publishCreateOnly(
      branch: "agent/issue-5-divergent",
      exactSHA: exact,
      remote: try fixtureRemote(),
      repository: URL(fileURLWithPath: "/tmp")
    )
    #expect(escalated.disposition == .escalation)
    #expect(escalated.sendSucceeded == true)

    let unreadable = FaultPublicationTransport(
      behavior: .successExact,
      failPostSendRead: true
    )
    let unknown = try await ExplicitlyAuthorizedTestGitPublisher(
      transport: unreadable
    ).publishCreateOnly(
      branch: "agent/issue-5-unreadable",
      exactSHA: exact,
      remote: try fixtureRemote(),
      repository: URL(fileURLWithPath: "/tmp")
    )
    #expect(unknown.disposition == .escalation)
    #expect(!unknown.observationComplete)
    #expect(await unreadable.createCount() == 1)
    #expect(await failed.createCount() == 1)
    #expect(await thrownEffect.createCount() == 1)
    #expect(await divergent.createCount() == 1)
  }
}

private actor PreAdvertisementRacingTransport: GitPublicationTransporting {
  private let delegate: SystemGitTransport
  private let remoteRepository: URL
  private let competingSHA: String
  private var creates = 0

  init(
    delegate: SystemGitTransport,
    remoteRepository: URL,
    competingSHA: String
  ) {
    self.delegate = delegate
    self.remoteRepository = remoteRepository
    self.competingSHA = competingSHA
  }

  func containsLocalCommit(_ exactSHA: String, repository: URL) async throws -> Bool {
    try await delegate.containsLocalCommit(exactSHA, repository: repository)
  }

  func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String? {
    try await delegate.readRemoteRef(
      reference,
      remote: remote,
      repository: repository,
      credentials: credentials
    )
  }

  func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?,
    permit: RolloutEffectPermit,
    effect: RolloutGitSendEffect
  ) async throws -> GitProcessResult {
    creates += 1
    let injected = try await delegate.runLocalGit(
      arguments: [
        "--git-dir", remoteRepository.path, "update-ref", reference,
        competingSHA, String(repeating: "0", count: 40),
      ],
      workingDirectory: remoteRepository.deletingLastPathComponent(),
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard injected.succeeded else {
      throw GitTransportError.commandFailed(
        exitCode: injected.exitCode,
        stderrSHA256: injected.stderrSHA256
      )
    }
    return try await delegate.createRemoteRef(
      reference,
      exactSHA: exactSHA,
      remote: remote,
      repository: repository,
      credentials: credentials,
      permit: permit,
      effect: effect
    )
  }

  func createCount() -> Int { creates }
}

private actor RacingPublicationTransport: GitPublicationTransporting {
  private var sha: String?
  private var creates = 0
  private let raceSHA: String?
  private let suspendRead: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private var didSuspend = false

  init(raceSHA: String?, suspendRead: Bool = false) {
    self.raceSHA = raceSHA
    self.suspendRead = suspendRead
  }

  func containsLocalCommit(_ exactSHA: String, repository: URL) async throws -> Bool {
    true
  }

  func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String? {
    if suspendRead, !didSuspend {
      didSuspend = true
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }
    return sha
  }

  func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?,
    permit _: RolloutEffectPermit,
    effect _: RolloutGitSendEffect
  ) async throws -> GitProcessResult {
    creates += 1
    if let raceSHA {
      sha = raceSHA
      return failedProcessResult()
    }
    guard sha == nil else { return failedProcessResult() }
    sha = exactSHA
    return successfulProcessResult()
  }

  func releaseRead() {
    continuation?.resume()
    continuation = nil
  }

  func createCount() -> Int { creates }
  func currentSHA() -> String? { sha }
  func isReadSuspended() -> Bool { continuation != nil }
}

private actor FaultPublicationTransport: GitPublicationTransporting {
  enum Behavior: Sendable {
    case failureAbsent
    case throwAfterExactEffect
    case successDivergent
    case successExact
  }

  private let localCommitExists: Bool
  private let behavior: Behavior
  private let failPostSendRead: Bool
  private var sha: String?
  private var reads = 0
  private var creates = 0

  init(
    localCommitExists: Bool = true,
    behavior: Behavior,
    failPostSendRead: Bool = false,
    initialSHA: String? = nil
  ) {
    self.localCommitExists = localCommitExists
    self.behavior = behavior
    self.failPostSendRead = failPostSendRead
    sha = initialSHA
  }

  func containsLocalCommit(_ exactSHA: String, repository: URL) async throws -> Bool {
    localCommitExists
  }

  func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String? {
    reads += 1
    if failPostSendRead, reads == 2 { throw FaultPublicationError.readFailed }
    return sha
  }

  func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?,
    permit _: RolloutEffectPermit,
    effect _: RolloutGitSendEffect
  ) async throws -> GitProcessResult {
    creates += 1
    switch behavior {
    case .failureAbsent:
      return failedProcessResult()
    case .throwAfterExactEffect:
      sha = exactSHA
      throw FaultPublicationError.sendFailed
    case .successDivergent:
      sha = String(repeating: "e", count: 40)
      return successfulProcessResult()
    case .successExact:
      sha = exactSHA
      return successfulProcessResult()
    }
  }

  func createCount() -> Int { creates }
}

private enum FaultPublicationError: Error {
  case sendFailed
  case readFailed
}

private func createdPublicationJob(_ result: JobCreationResult) -> JobRecord? {
  guard case .created(let job) = result else { return nil }
  return job
}

private func fixtureRemote(repositoryID: UUID = UUID()) throws -> GitRemoteRepository {
  try GitRemoteRepository(
    repositoryID: repositoryID,
    nodeID: "R_fixture",
    owner: "owner",
    name: "repo",
    defaultBranch: "main",
    localFixtureURL: URL(fileURLWithPath: "/tmp/fixture.git")
  )
}

private func successfulProcessResult() -> GitProcessResult {
  GitProcessResult(
    exitCode: 0,
    terminationSignal: nil,
    timedOut: false,
    outputLimitExceeded: false,
    stdout: Data(),
    stderr: Data(),
    durationSeconds: 0
  )
}

private func failedProcessResult() -> GitProcessResult {
  GitProcessResult(
    exitCode: 1,
    terminationSignal: nil,
    timedOut: false,
    outputLimitExceeded: false,
    stdout: Data(),
    stderr: Data(),
    durationSeconds: 0
  )
}
