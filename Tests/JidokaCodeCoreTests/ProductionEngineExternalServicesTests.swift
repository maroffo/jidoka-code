import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production engine external services")
struct ProductionEngineExternalServicesTests {
  @Test("rollout preview budgets account for the identity request and page")
  func rolloutPreviewBudgetIncludesIdentityPage() throws {
    let responseBytes = Int64(GitHubBroker.maximumResponseBytes)
    let insufficient = rolloutBudgets(
      githubReadRequests: 2,
      githubReadPages: 1,
      githubReadBytes: responseBytes * 2
    )
    #expect(throws: RolloutAuthorityError.invalidBudget) {
      _ = try ProductionEngineExternalServices.rolloutGitHubBudget(insufficient)
    }

    let exact = rolloutBudgets(
      githubReadRequests: 2,
      githubReadPages: 2,
      githubReadBytes: responseBytes * 2
    )
    #expect(
      try ProductionEngineExternalServices.rolloutGitHubBudget(exact)
        == ProductionRolloutGitHubBudget(
          repositoryRequests: 1,
          repositoryBytes: responseBytes
        )
    )
  }

  @Test("the proposal path grants itself exactly the policy ceilings, at every authority")
  func exactProposalCeilings() throws {
    let responseBytes = Int64(GitHubBroker.maximumResponseBytes)
    let ceilings = try ProductionEngineExternalServices.exactProposalCeilings()
    #expect(
      ceilings
        == ProductionRolloutProposalCeilings(
          identityRequests: 1,
          identityBytes: responseBytes,
          // One request of the budget pays for the identity read, which is why the producer gets
          // 39 rather than the 40 the policy names: revalidation of the preview it writes is
          // mapped the same way and must not be poorer than the producer.
          repositoryRequests: 39,
          repositoryBytes: responseBytes * 39,
          gitCarrierRequests: 1,
          gitCarrierBytes: responseBytes,
          gitRemoteReads: 2
        )
    )
    let revalidation = try ProductionEngineExternalServices.rolloutGitHubBudget(
      RolloutExactProposalPolicy.pullRequestReviewBudgets
    )
    #expect(ceilings.repositoryRequests == revalidation.repositoryRequests)
    #expect(ceilings.repositoryBytes == revalidation.repositoryBytes)
  }

  @Test("the proposal's authorities and job binding are built where a test can see them")
  func exactProposalAuthorityWiring() async throws {
    let repositoryID = UUID()
    let repository = RolloutRepositoryIdentity(
      id: repositoryID,
      nodeID: "R_wiring",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      enabled: true,
      reviewEnabled: true,
      triageEnabled: false,
      implementationEnabled: false
    )
    let instant = Date(timeIntervalSince1970: 700_000)
    let ceilings = try ProductionEngineExternalServices.exactProposalCeilings()
    let authorities = try ProductionEngineExternalServices.exactProposalAuthorities(
      repository: repository)

    // The ceilings are exercised, not restated: each authority admits exactly its allowance and
    // then refuses, so widening a call site is visible here.
    func identityRead() -> RolloutGitHubReadEffect {
      RolloutGitHubReadEffect(
        operation: .authenticatedIdentity,
        maximumResponseBytes: Int64(GitHubBroker.maximumResponseBytes),
        context: RolloutEffectExecutionContext(mode: .discovery)
      )
    }
    for _ in 0..<ceilings.identityRequests {
      _ = try await authorities.identity.reserveGitHubRead(identityRead(), now: instant)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await authorities.identity.reserveGitHubRead(identityRead(), now: instant)
    }
    #expect(await authorities.identity.snapshot().reservedRequests == ceilings.identityRequests)

    func repositoryRead(_ number: Int) -> RolloutGitHubReadEffect {
      RolloutGitHubReadEffect(
        operation: .pullRequest(owner: "owner", repository: "repo", number: number),
        maximumResponseBytes: Int64(GitHubBroker.maximumResponseBytes),
        context: RolloutEffectExecutionContext(mode: .discovery)
      )
    }
    for number in 1...ceilings.repositoryRequests {
      _ = try await authorities.repository.reserveGitHubRead(repositoryRead(number), now: instant)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await authorities.repository.reserveGitHubRead(
        repositoryRead(ceilings.repositoryRequests + 1), now: instant)
    }
    // The identity authority admits only the identity read, and the repository authority only
    // coordinate-matching ones, so the two allowances cannot be spent as one.
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await authorities.identity.reserveGitHubRead(repositoryRead(1), now: instant)
    }

    // The job id the closure binds is recorded, which is the only way to observe from outside
    // that the resolved binding reached the authority rather than a fresh identifier.
    let box = ProposalGitInspectorBox()
    let makeGit = try ProductionEngineExternalServices.exactProposalGitInspecting(
      repository: repository,
      broker: GitHubBroker(
        tokenProvider: ProposalWiringTokenProvider(),
        transport: IdentityGitHubTransport(account: "owner", authorID: 42),
        readAuthority: authorities.repository,
        defaultReadContext: RolloutEffectExecutionContext(mode: .discovery),
        now: { instant }
      ),
      cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
        "unused-\(UUID().uuidString)", isDirectory: true),
      askPassExecutable: URL(fileURLWithPath: "/usr/bin/true"),
      now: { instant },
      box: box
    )
    let jobID = UUID()
    #expect(box.boundJobID == nil)
    let inspector = try makeGit(jobID)
    #expect(box.boundJobID == jobID)
    // A second request for the same proposal reuses the allowance already granted. The inspector
    // is a value type, so the authority it carries is where identity must be read: a fresh one
    // would silently renew the two remote reads.
    let firstAuthority = try #require(box.boundAuthority)
    _ = try makeGit(jobID)
    let secondAuthority = try #require(box.boundAuthority)
    #expect(secondAuthority === firstAuthority)
    _ = inspector
    // A request for another job is a programming error, not a second allowance.
    #expect(throws: RolloutAuthorityError.invalidJobBinding) { _ = try makeGit(UUID()) }

    let gitAuthority = try #require(box.boundAuthority)
    func remoteRead(_ target: String, jobID: UUID) -> RolloutGitRemoteReadEffect {
      RolloutGitRemoteReadEffect(
        jobID: jobID,
        repositoryID: repositoryID,
        repositoryNodeID: repository.nodeID,
        operation: .fetchPreviewBase,
        target: target
      )
    }
    for ordinal in 0..<ceilings.gitRemoteReads {
      _ = try await gitAuthority.reserveGitRemoteRead(
        remoteRead("refs/\(ordinal)", jobID: jobID), now: instant)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await gitAuthority.reserveGitRemoteRead(
        remoteRead("refs/overflow", jobID: jobID), now: instant)
    }
    let other = try ProductionEngineExternalServices.exactProposalGitInspecting(
      repository: repository,
      broker: GitHubBroker(
        tokenProvider: ProposalWiringTokenProvider(),
        transport: IdentityGitHubTransport(account: "owner", authorID: 42),
        readAuthority: authorities.repository,
        defaultReadContext: RolloutEffectExecutionContext(mode: .discovery),
        now: { instant }
      ),
      cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
        "unused-\(UUID().uuidString)", isDirectory: true),
      askPassExecutable: URL(fileURLWithPath: "/usr/bin/true"),
      now: { instant },
      box: ProposalGitInspectorBox()
    )
    let otherJob = UUID()
    _ = try other(otherJob)
    // An authority bound to one job admits nothing for another.
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await gitAuthority.reserveGitRemoteRead(
        remoteRead("refs/base", jobID: otherJob), now: instant)
    }
  }

  @Test("an exact proposal spends one identity read and three repository reads, in order")
  func exactProposalObservationSpendsBothAuthorities() async throws {
    let baseSHA = String(repeating: "a", count: 40)
    let headSHA = String(repeating: "b", count: 40)
    let recorder = ProposalTransportRecorder()
    let fixture = try ExternalServicesFixture(
      transport: ProposalRecordingTransport(
        recorder: recorder,
        account: "hubot",
        authorID: 8,
        owner: "octo-org",
        name: "repo",
        number: 7,
        repositoryNodeID: "R_proposal",
        pullRequestNodeID: "PR_proposal",
        baseSHA: baseSHA,
        headSHA: headSHA,
        commitSHAs: [headSHA]
      ),
      enableRolloutPreview: true
    )
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "hubot", authorID: 8)
    await fixture.vault.seed(account: "hubot", token: fixture.oldToken)

    let calls = ProposalBindingRecorder()
    // The ask-pass helper is a regular non-executable file, so the run is refused at the Git step
    // rather than reaching the network: everything the proposal owes GitHub has happened by then.
    await #expect(throws: GitAskPassError.credentialRejected) {
      _ = try await fixture.external.observeExactPullRequestReview(
        repository: proposalRepository(),
        number: 7,
        resolveBinding: { nodeID, objectNumber, revisionKey in
          await calls.record(
            ProposalBindingCall(
              nodeID: nodeID, number: objectNumber, revisionKey: revisionKey))
          return RolloutJobBinding(
            jobID: UUID(),
            jobKind: .prReview,
            objectNumber: objectNumber,
            contractVersion: "2026-05-01",
            priority: .prReview,
            firstStep: .review,
            currentStep: JobStepKind.review.rawValue
          )
        }
      )
    }

    // Two authorities, spent apart: one request on identity and three on the repository. Backing
    // both brokers with the same authority, or swapping them, stops this sequence short because
    // the identity allowance is one request and admits only the identity operation.
    #expect(
      await recorder.requests == [
        "https://api.github.com/user",
        "https://api.github.com/repos/octo-org/repo",
        "https://api.github.com/repos/octo-org/repo/pulls/7",
        "https://api.github.com/repos/octo-org/repo/pulls/7/commits?per_page=100&page=1",
      ])
    // The job is resolved from the head the metadata fetch returned, so a caller cannot choose the
    // revision the binding is keyed by.
    #expect(
      await calls.observed == [
        ProposalBindingCall(nodeID: "PR_proposal", number: 7, revisionKey: headSHA)
      ])
  }

  @Test("an exact proposal under an account other than the configured one is refused first")
  func exactProposalRefusesAnotherAccount() async throws {
    let recorder = ProposalTransportRecorder()
    let fixture = try ExternalServicesFixture(
      transport: ProposalRecordingTransport(
        recorder: recorder,
        account: "mallory",
        authorID: 9,
        owner: "octo-org",
        name: "repo",
        number: 7,
        repositoryNodeID: "R_proposal",
        pullRequestNodeID: "PR_proposal",
        baseSHA: String(repeating: "a", count: 40),
        headSHA: String(repeating: "b", count: 40),
        commitSHAs: [String(repeating: "b", count: 40)]
      ),
      enableRolloutPreview: true
    )
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "hubot", authorID: 8)
    await fixture.vault.seed(account: "hubot", token: fixture.oldToken)

    let calls = ProposalBindingRecorder()
    // The account the observation is compared against comes from durable configuration. Comparing
    // the fetched identity against itself would let this proposal through, which is why the check
    // cannot live in a caller that only has the observation.
    await #expect(throws: RolloutAuthorityError.invalidReleaseIdentity) {
      _ = try await fixture.external.observeExactPullRequestReview(
        repository: proposalRepository(),
        number: 7,
        resolveBinding: { nodeID, objectNumber, revisionKey in
          await calls.record(
            ProposalBindingCall(
              nodeID: nodeID, number: objectNumber, revisionKey: revisionKey))
          return RolloutJobBinding(
            jobID: UUID(),
            jobKind: .prReview,
            objectNumber: objectNumber,
            contractVersion: "2026-05-01",
            priority: .prReview,
            firstStep: .review,
            currentStep: JobStepKind.review.rawValue
          )
        }
      )
    }
    #expect(await recorder.requests == ["https://api.github.com/user"])
    #expect(await calls.observed.isEmpty)
  }

  @Test("a Keychain success followed by an error is completed from the durable journal")
  func replacementFailureAfterWriteRecoversForward() async throws {
    let fixture = try ExternalServicesFixture()
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await fixture.vault.setReplaceMode(.failAfterWrite)

    await #expect(throws: EngineClientError(.credentialRejected)) {
      _ = try await fixture.external.replaceCredential(
        fixture.newToken,
        allowAccountChange: true
      )
    }
    var app = try await fixture.configuration.appConfiguration()
    #expect(app.githubAccount == "octocat")
    #expect(app.pendingGitHubAccount == "hubot")
    #expect(app.previousGitHubAccount == "octocat")

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let reopenedConfiguration = ConfigurationStore(database: reopenedDatabase)
    let reopenedExternal = ProductionEngineExternalServices(
      configuration: reopenedConfiguration,
      transport: IdentityGitHubTransport(account: "hubot", authorID: 8),
      credentialVault: fixture.vault,
      runtimeResolver: UnusedPiRuntimeResolver(),
      herdrReadiness: ReadyHerdrReadiness(),
      now: { Date(timeIntervalSince1970: 700_001) }
    )
    let recovered = await reopenedExternal.credentialStatus()
    #expect(recovered == EngineCredentialStatus(state: .valid, account: "hubot"))
    app = try await reopenedConfiguration.appConfiguration()
    #expect(app.githubAccount == "hubot")
    #expect(app.githubAuthorID == 8)
    #expect(app.pendingGitHubAccount == nil)
    #expect(app.previousGitHubAccount == nil)
    #expect(await fixture.vault.contains(account: "hubot"))
    #expect(!(await fixture.vault.contains(account: "octocat")))
    await reopenedDatabase.close()
  }

  @Test("old-token cleanup converges before an immediate retry and after reopen")
  func cleanupFailureAfterDeleteConverges() async throws {
    let fixture = try ExternalServicesFixture()
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await fixture.vault.failNextDeleteAfterMutation()

    await #expect(throws: EngineClientError(.credentialRejected)) {
      _ = try await fixture.external.replaceCredential(
        fixture.newToken,
        allowAccountChange: true
      )
    }
    var app = try await fixture.configuration.appConfiguration()
    #expect(app.githubAccount == "hubot")
    #expect(app.previousGitHubAccount == "octocat")
    #expect(!(await fixture.vault.contains(account: "octocat")))
    #expect(
      try await fixture.external.replaceCredential(
        fixture.newToken,
        allowAccountChange: true
      ) == EngineCredentialStatus(state: .valid, account: "hubot")
    )
    app = try await fixture.configuration.appConfiguration()
    #expect(app.previousGitHubAccount == nil)
    await fixture.database.close()

    let reopenedDatabase = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let reopenedConfiguration = ConfigurationStore(database: reopenedDatabase)
    let reopenedExternal = ProductionEngineExternalServices(
      configuration: reopenedConfiguration,
      transport: IdentityGitHubTransport(account: "hubot", authorID: 8),
      credentialVault: fixture.vault,
      runtimeResolver: UnusedPiRuntimeResolver(),
      herdrReadiness: ReadyHerdrReadiness()
    )
    #expect(
      await reopenedExternal.credentialStatus()
        == EngineCredentialStatus(state: .valid, account: "hubot")
    )
    app = try await reopenedConfiguration.appConfiguration()
    #expect(app.previousGitHubAccount == nil)
    await reopenedDatabase.close()
  }

  @Test("credential deletion converges after Keychain mutation and process reopen")
  func credentialDeletionJournal() async throws {
    let fixture = try ExternalServicesFixture(identityAccount: "octocat", identityAuthorID: 7)
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await fixture.vault.failNextDeleteAfterMutation()

    await #expect(throws: EngineCredentialVaultFakeError.injected) {
      try await fixture.external.deleteCredential()
    }
    var app = try await fixture.configuration.appConfiguration()
    #expect(app.credentialDeletionPending)
    #expect(app.githubAccount == "octocat")
    #expect(!(await fixture.vault.contains(account: "octocat")))
    await fixture.database.close()

    let reopenedDatabase = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let reopenedConfiguration = ConfigurationStore(database: reopenedDatabase)
    let reopenedExternal = ProductionEngineExternalServices(
      configuration: reopenedConfiguration,
      transport: IdentityGitHubTransport(account: "octocat", authorID: 7),
      credentialVault: fixture.vault,
      runtimeResolver: UnusedPiRuntimeResolver(),
      herdrReadiness: ReadyHerdrReadiness()
    )
    #expect(await reopenedExternal.credentialStatus() == .missing)
    app = try await reopenedConfiguration.appConfiguration()
    #expect(!app.credentialDeletionPending)
    #expect(app.githubAccount == nil)
    await reopenedDatabase.close()
  }

  @Test("a failure before the Keychain write rolls the journal back to the old account")
  func replacementFailureBeforeWriteRollsBack() async throws {
    let fixture = try ExternalServicesFixture()
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await fixture.vault.setReplaceMode(.failBeforeWrite)

    await #expect(throws: EngineClientError(.credentialRejected)) {
      _ = try await fixture.external.replaceCredential(
        fixture.newToken,
        allowAccountChange: true
      )
    }
    let recovered = await fixture.external.credentialStatus()
    #expect(recovered == EngineCredentialStatus(state: .valid, account: "octocat"))
    let app = try await fixture.configuration.appConfiguration()
    #expect(app.githubAccount == "octocat")
    #expect(app.pendingGitHubAccount == nil)
    #expect(app.previousGitHubAccount == nil)
    #expect(!(await fixture.vault.contains(account: "hubot")))
    #expect(await fixture.vault.contains(account: "octocat"))
  }

  @Test("the durable schema rejects a partial credential replacement journal")
  func partialJournalFailsClosed() async throws {
    let fixture = try ExternalServicesFixture()
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.database.execute(
        """
        UPDATE app_settings
        SET pending_github_account = 'hubot', pending_github_author_id = NULL,
            previous_github_account = 'octocat'
        WHERE singleton = 1
        """
      )
    }

    #expect(
      await fixture.external.credentialStatus()
        == EngineCredentialStatus(state: .valid, account: "octocat")
    )
    #expect(await fixture.vault.contains(account: "octocat"))
    let app = try await fixture.configuration.appConfiguration()
    #expect(app.githubAccount == "octocat")
    #expect(app.pendingGitHubAccount == nil)
    #expect(app.previousGitHubAccount == nil)
  }

  @Test("same-account recovery does not mistake the old token for a completed rotation")
  func sameAccountRotationRequiresExactToken() async throws {
    let fixture = try ExternalServicesFixture(identityAccount: "octocat", identityAuthorID: 7)
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    await fixture.vault.setReplaceMode(.failBeforeWrite)

    await #expect(throws: EngineClientError(.credentialRejected)) {
      _ = try await fixture.external.replaceCredential(
        fixture.newToken,
        allowAccountChange: false
      )
    }
    #expect(
      await fixture.external.credentialStatus()
        == EngineCredentialStatus(state: .valid, account: "octocat")
    )
    #expect(await fixture.vault.storedToken(account: "octocat") == fixture.oldToken)
    let app = try await fixture.configuration.appConfiguration()
    #expect(app.pendingGitHubAccount == nil)
    #expect(app.pendingGitHubTokenSHA256 == nil)
  }

  @Test("startup completes old-account cleanup after the metadata commit boundary")
  func cleanupAfterMetadataCommit() async throws {
    let fixture = try ExternalServicesFixture()
    defer { fixture.remove() }
    try await fixture.configureIdentity(account: "octocat", authorID: 7)
    await fixture.vault.seed(account: "octocat", token: fixture.oldToken)
    _ = try await fixture.configuration.prepareCredentialReplacement(
      account: "hubot",
      authorID: 8,
      tokenSHA256: tokenDigest(fixture.newToken),
      now: fixture.now
    )
    await fixture.vault.seed(account: "hubot", token: fixture.newToken)
    try await fixture.configuration.commitCredentialReplacement(
      account: "hubot",
      authorID: 8,
      tokenSHA256: tokenDigest(fixture.newToken),
      now: fixture.now
    )

    let recovered = await fixture.external.credentialStatus()
    #expect(recovered == EngineCredentialStatus(state: .valid, account: "hubot"))
    let app = try await fixture.configuration.appConfiguration()
    #expect(app.previousGitHubAccount == nil)
    #expect(!(await fixture.vault.contains(account: "octocat")))
  }
}

private struct ExternalServicesFixture {
  let root: URL
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let vault: EngineCredentialVaultFake
  let external: ProductionEngineExternalServices
  let askPassExecutable: URL
  let now = Date(timeIntervalSince1970: 700_000)
  let oldToken = Data(repeating: 0x6F, count: 32)
  let newToken = Data(repeating: 0x6E, count: 32)

  init(
    identityAccount: String = "hubot",
    identityAuthorID: Int64 = 8,
    transport: (any GitHubHTTPTransport)? = nil,
    enableRolloutPreview: Bool = false
  ) throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-external-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try SQLiteStore(
      databaseURL: root.appendingPathComponent("state.sqlite3")
    )
    configuration = ConfigurationStore(database: database)
    vault = EngineCredentialVaultFake()
    askPassExecutable = root.appendingPathComponent("askpass", isDirectory: false)
    if enableRolloutPreview {
      // Present and owned by this process, so the credential provider gets past its path checks
      // and refuses on the executable bit alone. That refusal is the boundary the proposal tests
      // stop at, and it costs no network.
      try Data().write(to: askPassExecutable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: askPassExecutable.path
      )
    }
    external = ProductionEngineExternalServices(
      configuration: configuration,
      transport: transport
        ?? IdentityGitHubTransport(
          account: identityAccount,
          authorID: identityAuthorID
        ),
      credentialVault: vault,
      runtimeResolver: UnusedPiRuntimeResolver(),
      herdrReadiness: ReadyHerdrReadiness(),
      rolloutDatabase: enableRolloutPreview ? database : nil,
      rolloutJobs: enableRolloutPreview
        ? DurableJobStore(database: database, enforceRolloutAuthority: false) : nil,
      rolloutIntents: enableRolloutPreview ? MutationIntentStore(database: database) : nil,
      rolloutApplicationSupportRoot: enableRolloutPreview ? root : nil,
      rolloutAskPassExecutable: enableRolloutPreview ? askPassExecutable : nil,
      now: { Date(timeIntervalSince1970: 700_000) }
    )
  }

  func configureIdentity(account: String, authorID: Int64) async throws {
    _ = try await configuration.prepareCredentialReplacement(
      account: account,
      authorID: authorID,
      tokenSHA256: tokenDigest(oldToken),
      now: now
    )
    try await configuration.commitCredentialReplacement(
      account: account,
      authorID: authorID,
      tokenSHA256: tokenDigest(oldToken),
      now: now
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum EngineCredentialVaultFakeError: Error, Equatable {
  case injected
  case missing
}

private actor EngineCredentialVaultFake: EngineCredentialVaulting {
  enum ReplaceMode {
    case normal
    case failBeforeWrite
    case failAfterWrite
  }

  private var tokens: [String: Data] = [:]
  private var replaceMode = ReplaceMode.normal
  private var deleteFailureAfterMutation = false

  func seed(account: String, token: Data) {
    tokens[account] = token
  }

  func setReplaceMode(_ mode: ReplaceMode) {
    replaceMode = mode
  }

  func failNextDeleteAfterMutation() {
    deleteFailureAfterMutation = true
  }

  func token(account: String) throws -> Data {
    guard let token = tokens[account] else { throw EngineCredentialVaultFakeError.missing }
    return token
  }

  func storedToken(account: String) -> Data? {
    tokens[account]
  }

  func contains(account: String) -> Bool {
    tokens[account] != nil
  }

  func replace(account: String, with token: Data) throws {
    if replaceMode == .failBeforeWrite {
      throw EngineCredentialVaultFakeError.injected
    }
    tokens[account] = token
    if replaceMode == .failAfterWrite {
      throw EngineCredentialVaultFakeError.injected
    }
  }

  func delete(account: String) throws {
    tokens.removeValue(forKey: account)
    if deleteFailureAfterMutation {
      deleteFailureAfterMutation = false
      throw EngineCredentialVaultFakeError.injected
    }
  }
}

private struct IdentityGitHubTransport: GitHubHTTPTransport {
  let account: String
  let authorID: Int64

  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    let url = try #require(request.url)
    #expect(url.absoluteString == "https://api.github.com/user")
    let body = try JSONSerialization.data(
      withJSONObject: [
        "id": authorID,
        "node_id": "U_\(authorID)",
        "login": account,
      ]
    )
    return GitHubHTTPResponse(statusCode: 200, url: url, headers: [:], body: body)
  }
}

private struct ReadyHerdrReadiness: HerdrRuntimeReadinessChecking {
  func preflight() -> EngineHerdrStatus {
    EngineHerdrStatus(
      state: .ready,
      version: "0.8.2",
      protocolVersion: 20,
      executableSHA256: String(repeating: "e", count: 64),
      schemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
  }
}

private struct UnusedPiRuntimeResolver: PiRuntimeResolving {
  func resolve() throws -> PiResolvedRuntime {
    throw EngineClientError(.piBlocked)
  }
}

private func tokenDigest(_ token: Data) -> String {
  SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
}

private func rolloutBudgets(
  githubReadRequests: Int,
  githubReadPages: Int,
  githubReadBytes: Int64
) -> RolloutBudgets {
  RolloutBudgets(
    jobs: 1,
    githubReadRequests: githubReadRequests,
    githubReadPages: githubReadPages,
    githubReadBytes: githubReadBytes,
    gitRemoteReads: 0,
    providerSessions: 0,
    approvedCommands: 0,
    markerParts: 0,
    labelWrites: 0,
    branchCreates: 0,
    pullRequestCreates: 0,
    githubSends: 0,
    gitSends: 0
  )
}

private struct ProposalWiringTokenProvider: GitHubTokenProviding {
  func token() async throws -> Data { Data(repeating: 0x74, count: 40) }
}

private func proposalRepository() -> RolloutRepositoryIdentity {
  RolloutRepositoryIdentity(
    id: UUID(),
    nodeID: "R_proposal",
    owner: "octo-org",
    name: "repo",
    defaultBranch: "main",
    enabled: true,
    reviewEnabled: true,
    triageEnabled: false,
    implementationEnabled: false
  )
}

private struct ProposalBindingCall: Equatable, Sendable {
  let nodeID: String
  let number: Int
  let revisionKey: String
}

private actor ProposalBindingRecorder {
  private(set) var observed: [ProposalBindingCall] = []

  func record(_ call: ProposalBindingCall) {
    observed.append(call)
  }
}

private actor ProposalTransportRecorder {
  private(set) var requests: [String] = []

  func record(_ request: String) {
    requests.append(request)
  }
}

/// Serves the four reads a proposal is allowed and records the order they arrive in. Anything else
/// answers 404, so a fifth read shows up as a failure rather than as a silent success.
private struct ProposalRecordingTransport: GitHubHTTPTransport {
  let recorder: ProposalTransportRecorder
  let account: String
  let authorID: Int64
  let owner: String
  let name: String
  let number: Int
  let repositoryNodeID: String
  let pullRequestNodeID: String
  let baseSHA: String
  let headSHA: String
  let commitSHAs: [String]

  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    let url = try #require(request.url)
    await recorder.record(url.absoluteString)
    let body: Data?
    switch url.path {
    case "/user":
      body = try JSONSerialization.data(withJSONObject: user(login: account, id: authorID))
    case "/repos/\(owner)/\(name)":
      body = try JSONSerialization.data(
        withJSONObject: [
          "id": 4_242,
          "node_id": repositoryNodeID,
          "name": name,
          "full_name": "\(owner)/\(name)",
          "default_branch": "main",
          "owner": user(login: owner, id: 4_243),
        ] as [String: Any]
      )
    case "/repos/\(owner)/\(name)/pulls/\(number)":
      body = try JSONSerialization.data(
        withJSONObject: [
          "id": 5_151,
          "node_id": pullRequestNodeID,
          "number": number,
          "state": "open",
          "draft": false,
          "title": "Proposal",
          "body": "Proposal body",
          "html_url": "https://github.com/\(owner)/\(name)/pull/\(number)",
          "user": user(login: account, id: authorID),
          "head": ["ref": "feature", "sha": headSHA],
          "base": ["ref": "main", "sha": baseSHA],
        ] as [String: Any]
      )
    case "/repos/\(owner)/\(name)/pulls/\(number)/commits":
      body = try JSONSerialization.data(
        withJSONObject: commitSHAs.map { ["sha": $0] }
      )
    default:
      body = nil
    }
    guard let body else {
      return GitHubHTTPResponse(statusCode: 404, url: url, headers: [:], body: Data())
    }
    return GitHubHTTPResponse(statusCode: 200, url: url, headers: [:], body: body)
  }

  private func user(login: String, id: Int64) -> [String: Any] {
    ["id": id, "node_id": "U_\(id)", "login": login]
  }
}
