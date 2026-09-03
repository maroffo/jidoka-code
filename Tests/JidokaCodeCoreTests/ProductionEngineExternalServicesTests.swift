import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production engine external services")
struct ProductionEngineExternalServicesTests {
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
  let now = Date(timeIntervalSince1970: 700_000)
  let oldToken = Data(repeating: 0x6F, count: 32)
  let newToken = Data(repeating: 0x6E, count: 32)

  init(identityAccount: String = "hubot", identityAuthorID: Int64 = 8) throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-external-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try SQLiteStore(
      databaseURL: root.appendingPathComponent("state.sqlite3")
    )
    configuration = ConfigurationStore(database: database)
    vault = EngineCredentialVaultFake()
    external = ProductionEngineExternalServices(
      configuration: configuration,
      transport: IdentityGitHubTransport(
        account: identityAccount,
        authorID: identityAuthorID
      ),
      credentialVault: vault,
      runtimeResolver: UnusedPiRuntimeResolver(),
      herdrReadiness: ReadyHerdrReadiness(),
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
