import CryptoKit
import Foundation

public protocol EngineCredentialVaulting: Sendable {
  func token(account: String) async throws -> Data
  func contains(account: String) async throws -> Bool
  func replace(account: String, with token: Data) async throws
  func delete(account: String) async throws
}

public actor SystemEngineCredentialVault: EngineCredentialVaulting {
  public init() {}

  public func token(account: String) async throws -> Data {
    try await GitHubTokenStore(account: account).token()
  }

  public func contains(account: String) async throws -> Bool {
    try await GitHubTokenStore(account: account).containsCredential()
  }

  public func replace(account: String, with token: Data) async throws {
    try await GitHubTokenStore(account: account).replace(with: token)
  }

  public func delete(account: String) async throws {
    try await GitHubTokenStore(account: account).delete()
  }
}

private actor EphemeralGitHubTokenProvider: GitHubTokenProviding {
  private var value: Data?

  init(value: Data) {
    self.value = value
  }

  func token() throws -> Data {
    guard let value else {
      throw GitHubTokenStoreError.missingToken
    }
    return value
  }

  func clear() {
    let count = value?.count ?? 0
    value?.resetBytes(in: 0..<count)
    value = nil
  }
}

public actor ProductionEngineExternalServices: EngineExternalServicing {
  private let configuration: ConfigurationStore
  private let transport: any GitHubHTTPTransport
  private let credentialVault: any EngineCredentialVaulting
  private let runtimeResolver: any PiRuntimeResolving
  private let herdrReadiness: any HerdrRuntimeReadinessChecking
  private let now: @Sendable () -> Date

  public init(
    configuration: ConfigurationStore,
    transport: any GitHubHTTPTransport = GitHubURLSessionTransport(),
    credentialVault: any EngineCredentialVaulting = SystemEngineCredentialVault(),
    runtimeResolver: any PiRuntimeResolving,
    herdrReadiness: any HerdrRuntimeReadinessChecking,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.transport = transport
    self.credentialVault = credentialVault
    self.runtimeResolver = runtimeResolver
    self.herdrReadiness = herdrReadiness
    self.now = now
  }

  public func credentialStatus() async -> EngineCredentialStatus {
    do {
      try await recoverCredentialDeletion()
      try await recoverCredentialReplacement()
      let app = try await configuration.appConfiguration()
      guard let account = app.githubAccount else {
        return .missing
      }
      return try await credentialVault.contains(account: account)
        ? EngineCredentialStatus(state: .valid, account: account)
        : .missing
    } catch GitHubTokenStoreError.missingToken {
      return .missing
    } catch {
      return EngineCredentialStatus(state: .unavailable, account: nil)
    }
  }

  public func replaceCredential(
    _ suppliedToken: Data,
    allowAccountChange: Bool
  ) async throws -> EngineCredentialStatus {
    try await recoverCredentialDeletion()
    try await recoverCredentialReplacement()
    var token = suppliedToken
    defer {
      let count = token.count
      token.resetBytes(in: 0..<count)
    }
    let provider = EphemeralGitHubTokenProvider(value: token)
    let broker = GitHubBroker(tokenProvider: provider, transport: transport)
    let identity: GitHubUser
    do {
      identity = try await broker.authenticatedIdentity()
    } catch {
      await provider.clear()
      throw EngineClientError(.credentialRejected)
    }
    await provider.clear()
    guard GitHubInputValidation.validOwner(identity.login), identity.id > 0 else {
      throw EngineClientError(.credentialRejected)
    }

    let current = try await configuration.appConfiguration()
    if let existing = current.githubAccount,
      existing.caseInsensitiveCompare(identity.login) != .orderedSame,
      !allowAccountChange
    {
      throw EngineClientError(.credentialInUse)
    }

    let instant = now()
    let tokenSHA256 = Self.sha256(token)
    let previous = try await configuration.prepareCredentialReplacement(
      account: identity.login,
      authorID: identity.id,
      tokenSHA256: tokenSHA256,
      now: instant
    )
    do {
      try await credentialVault.replace(account: identity.login, with: token)
      try await configuration.commitCredentialReplacement(
        account: identity.login,
        authorID: identity.id,
        tokenSHA256: tokenSHA256,
        now: instant
      )
      if let previous {
        try await credentialVault.delete(account: previous)
        try await configuration.completeCredentialCleanup(account: previous, now: now())
      }
      return EngineCredentialStatus(state: .valid, account: identity.login)
    } catch {
      // Preserve the journal. The next credential status read reconciles whether the
      // Keychain replacement committed before this failure and finishes or rolls back.
      throw EngineClientError(.credentialRejected)
    }
  }

  public func deleteCredential() async throws {
    guard let account = try await configuration.prepareCredentialDeletion(now: now()) else {
      return
    }
    try await credentialVault.delete(account: account)
    try await configuration.completeCredentialDeletion(account: account, now: now())
  }

  public func validateRepository(
    _ draft: EngineRepositoryDraft,
    existingID: UUID?
  ) async throws -> RepositoryConfiguration {
    let app = try await configuration.appConfiguration()
    guard let account = app.githubAccount else {
      throw EngineClientError(.credentialRejected)
    }
    var token = try await credentialVault.token(account: account)
    defer {
      let count = token.count
      token.resetBytes(in: 0..<count)
    }
    let provider = EphemeralGitHubTokenProvider(value: token)
    let broker = GitHubBroker(tokenProvider: provider, transport: transport)
    let repository: GitHubRepository
    do {
      repository = try await broker.repository(owner: draft.owner, repository: draft.name)
    } catch {
      await provider.clear()
      throw EngineClientError(.repositoryRejected)
    }
    await provider.clear()
    return RepositoryConfiguration(
      id: existingID ?? UUID(),
      nodeID: repository.nodeID,
      owner: repository.owner.login,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      reviewEnabled: draft.reviewEnabled,
      triageEnabled: draft.triageEnabled,
      implementationEnabled: draft.implementationEnabled,
      enabled: true
    )
  }

  public func preflightHerdr() async -> EngineHerdrStatus {
    await herdrReadiness.preflight()
  }

  public func preflightPi() async -> EnginePiStatus {
    do {
      let resolved = try await Task.detached { [runtimeResolver] in
        try runtimeResolver.resolve()
      }.value
      return EnginePiStatus(
        state: .ready,
        version: resolved.piVersion.description,
        policySHA256: resolved.compatibility.policySHA256
      )
    } catch let error as PiRuntimeResolutionError {
      let issue = PiRuntimeResolver.actionableIssue(for: error)
      return EnginePiStatus(
        state: .blocked,
        issueCode: issue.code,
        summary: issue.summary,
        recovery: issue.recovery
      )
    } catch {
      return EnginePiStatus(
        state: .blocked,
        issueCode: .invalidPiPackage,
        summary: "Pi runtime validation failed.",
        recovery: "Reinstall an attested Pi and Node build, then run preflight again."
      )
    }
  }

  private func recoverCredentialDeletion() async throws {
    let app = try await configuration.appConfiguration()
    guard app.credentialDeletionPending else { return }
    guard let account = app.githubAccount else {
      throw EngineClientError(.credentialRejected)
    }
    try await credentialVault.delete(account: account)
    try await configuration.completeCredentialDeletion(account: account, now: now())
  }

  private func recoverCredentialReplacement() async throws {
    var app = try await configuration.appConfiguration()
    if app.pendingGitHubAccount != nil || app.pendingGitHubAuthorID != nil
      || app.pendingGitHubTokenSHA256 != nil
    {
      guard let pendingAccount = app.pendingGitHubAccount,
        let pendingAuthorID = app.pendingGitHubAuthorID,
        let pendingTokenSHA256 = app.pendingGitHubTokenSHA256
      else {
        throw EngineClientError(.credentialRejected)
      }
      var exactReplacementExists = false
      if try await credentialVault.contains(account: pendingAccount) {
        var storedToken = try await credentialVault.token(account: pendingAccount)
        exactReplacementExists = Self.sha256(storedToken) == pendingTokenSHA256
        let count = storedToken.count
        storedToken.resetBytes(in: 0..<count)
      }
      if exactReplacementExists {
        try await configuration.commitCredentialReplacement(
          account: pendingAccount,
          authorID: pendingAuthorID,
          tokenSHA256: pendingTokenSHA256,
          now: now()
        )
      } else {
        try await configuration.cancelCredentialReplacement(now: now())
      }
      app = try await configuration.appConfiguration()
    }
    if let previous = app.previousGitHubAccount {
      try await credentialVault.delete(account: previous)
      try await configuration.completeCredentialCleanup(account: previous, now: now())
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
