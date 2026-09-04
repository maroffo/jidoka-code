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

private struct ProductionRolloutPreviewDependencies: Sendable {
  let database: SQLiteStore
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let applicationSupportRoot: URL
  let askPassExecutable: URL
}

struct ProductionRolloutGitHubBudget: Equatable, Sendable {
  let repositoryRequests: Int
  let repositoryBytes: Int64
}

public actor ProductionEngineExternalServices: EngineExternalServicing {
  private let configuration: ConfigurationStore
  private let transport: any GitHubHTTPTransport
  private let credentialVault: any EngineCredentialVaulting
  private let runtimeResolver: any PiRuntimeResolving
  private let modelCatalogDiscovery: (any PiModelCatalogDiscovering)?
  private let herdrReadiness: any HerdrRuntimeReadinessChecking
  private let rolloutPreviewDependencies: ProductionRolloutPreviewDependencies?
  private let now: @Sendable () -> Date

  public init(
    configuration: ConfigurationStore,
    transport: any GitHubHTTPTransport = GitHubURLSessionTransport(),
    credentialVault: any EngineCredentialVaulting = SystemEngineCredentialVault(),
    runtimeResolver: ReleaseOwnedPiRuntimeResolver,
    modelCatalogDiscovery: (any PiModelCatalogDiscovering)? = nil,
    herdrReadiness: any HerdrRuntimeReadinessChecking,
    rolloutDatabase: SQLiteStore? = nil,
    rolloutJobs: DurableJobStore? = nil,
    rolloutIntents: MutationIntentStore? = nil,
    rolloutApplicationSupportRoot: URL? = nil,
    rolloutAskPassExecutable: URL? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.transport = transport
    self.credentialVault = credentialVault
    self.runtimeResolver = runtimeResolver
    self.modelCatalogDiscovery = modelCatalogDiscovery
    self.herdrReadiness = herdrReadiness
    rolloutPreviewDependencies = Self.rolloutPreviewDependencies(
      database: rolloutDatabase,
      jobs: rolloutJobs,
      intents: rolloutIntents,
      applicationSupportRoot: rolloutApplicationSupportRoot,
      askPassExecutable: rolloutAskPassExecutable
    )
    self.now = now
  }

  #if DEBUG
    init(
      configuration: ConfigurationStore,
      transport: any GitHubHTTPTransport = GitHubURLSessionTransport(),
      credentialVault: any EngineCredentialVaulting = SystemEngineCredentialVault(),
      runtimeResolver: any PiRuntimeResolving,
      modelCatalogDiscovery: (any PiModelCatalogDiscovering)? = nil,
      herdrReadiness: any HerdrRuntimeReadinessChecking,
      rolloutDatabase: SQLiteStore? = nil,
      rolloutJobs: DurableJobStore? = nil,
      rolloutIntents: MutationIntentStore? = nil,
      rolloutApplicationSupportRoot: URL? = nil,
      rolloutAskPassExecutable: URL? = nil,
      now: @escaping @Sendable () -> Date = Date.init
    ) {
      self.configuration = configuration
      self.transport = transport
      self.credentialVault = credentialVault
      self.runtimeResolver = runtimeResolver
      self.modelCatalogDiscovery = modelCatalogDiscovery
      self.herdrReadiness = herdrReadiness
      rolloutPreviewDependencies = Self.rolloutPreviewDependencies(
        database: rolloutDatabase,
        jobs: rolloutJobs,
        intents: rolloutIntents,
        applicationSupportRoot: rolloutApplicationSupportRoot,
        askPassExecutable: rolloutAskPassExecutable
      )
      self.now = now
    }
  #endif

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
    let readAuthority = try BoundedRolloutPreviewReadAuthority(
      repository: nil,
      maximumRequests: 1,
      maximumBytes: Int64(GitHubBroker.maximumResponseBytes)
    )
    let broker = GitHubBroker(
      tokenProvider: provider,
      transport: transport,
      readAuthority: readAuthority,
      defaultReadContext: RolloutEffectExecutionContext(mode: .discovery)
    )
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
    let coordinates = GitHubRepositoryCoordinates(owner: draft.owner, repository: draft.name)
    let readAuthority = try BoundedRolloutPreviewReadAuthority(
      repository: coordinates,
      maximumRequests: 2,
      maximumBytes: Int64(GitHubBroker.maximumResponseBytes * 2)
    )
    let broker = GitHubBroker(
      tokenProvider: provider,
      transport: transport,
      readAuthority: readAuthority,
      defaultReadContext: RolloutEffectExecutionContext(mode: .discovery)
    )
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
      enabled: draft.enabled
    )
  }

  public func preflightHerdr() async -> EngineHerdrStatus {
    await herdrReadiness.preflight()
  }

  public func discoverModelCatalog() async throws -> PiModelCatalog {
    guard let modelCatalogDiscovery else {
      throw EngineClientError(.piBlocked)
    }
    do {
      return try await modelCatalogDiscovery.discover()
    } catch {
      throw EngineClientError(.piBlocked)
    }
  }

  public func preflightPi() async -> EnginePiStatus {
    do {
      let resolved = try await Task.detached { [runtimeResolver] in
        try ReleaseOwnedPiRuntimeBoundaryAuthority.applicationStartup(
          using: runtimeResolver
        )
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

  public func revalidateRollout(_ preview: RolloutPreview) async throws {
    guard let dependencies = rolloutPreviewDependencies else {
      throw RolloutAuthorityError.previewDrift
    }
    let app = try await configuration.appConfiguration()
    guard let account = app.githubAccount,
      account.caseInsensitiveCompare(preview.payload.releaseIdentity.githubAccount)
        == .orderedSame,
      app.githubAuthorID == preview.payload.releaseIdentity.githubAuthorID
    else {
      throw RolloutAuthorityError.previewDrift
    }
    var token = try await credentialVault.token(account: account)
    defer { token.resetBytes(in: 0..<token.count) }
    let provider = EphemeralGitHubTokenProvider(value: token)
    do {
      let responseBytes = Int64(GitHubBroker.maximumResponseBytes)
      let budget = preview.payload.budgets
      let repositoryBudget = try Self.rolloutGitHubBudget(budget)
      let identityAuthority = try BoundedRolloutPreviewReadAuthority(
        repository: nil,
        maximumRequests: 1,
        maximumBytes: responseBytes
      )
      let identityBroker = GitHubBroker(
        tokenProvider: provider,
        transport: transport,
        readAuthority: identityAuthority,
        defaultReadContext: RolloutEffectExecutionContext(mode: .discovery),
        now: now
      )
      let scope = preview.payload.scope
      let repositoryCoordinates = GitHubRepositoryCoordinates(
        owner: scope.repository.owner,
        repository: scope.repository.name
      )
      let jobID = preview.payload.jobBinding.flatMap { UUID(uuidString: $0.jobID) }
      let previewGitReads: Int
      if scope.mode == .exactObject,
        [.prReview, .generatedPRReview].contains(scope.stage)
      {
        previewGitReads = budget.gitRemoteReads
      } else {
        previewGitReads = 0
      }
      let repositoryAuthority = try BoundedRolloutPreviewReadAuthority(
        repository: repositoryCoordinates,
        maximumRequests: repositoryBudget.repositoryRequests,
        maximumBytes: repositoryBudget.repositoryBytes,
        repositoryID: UUID(uuidString: scope.repository.id),
        repositoryNodeID: scope.repository.nodeID,
        jobID: jobID,
        maximumGitRemoteReads: previewGitReads
      )
      let repositoryBroker = GitHubBroker(
        tokenProvider: provider,
        transport: transport,
        readAuthority: repositoryAuthority,
        defaultReadContext: RolloutEffectExecutionContext(mode: .discovery),
        now: now
      )
      let git = ProductionRolloutPreviewGitInspector(
        cacheRoot: dependencies.applicationSupportRoot.appendingPathComponent(
          "RolloutPreviewCache",
          isDirectory: true
        ),
        askPassExecutable: dependencies.askPassExecutable,
        broker: repositoryBroker,
        readAuthority: repositoryAuthority,
        now: now
      )
      try await RolloutRemotePreviewRevalidator(
        identity: identityBroker,
        api: repositoryBroker,
        git: git,
        jobs: dependencies.jobs,
        intents: dependencies.intents,
        reviewedRevisions: ReviewedRevisionStore(database: dependencies.database)
      ).revalidate(preview)
      await provider.clear()
    } catch {
      await provider.clear()
      throw error
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

  static func rolloutGitHubBudget(_ budget: RolloutBudgets) throws
    -> ProductionRolloutGitHubBudget
  {
    let responseBytes = Int64(GitHubBroker.maximumResponseBytes)
    guard budget.githubReadRequests >= 2,
      budget.githubReadPages >= 2,
      budget.githubReadBytes >= responseBytes * 2
    else {
      throw RolloutAuthorityError.invalidBudget
    }
    return ProductionRolloutGitHubBudget(
      repositoryRequests: min(
        budget.githubReadRequests - 1,
        budget.githubReadPages - 1
      ),
      repositoryBytes: budget.githubReadBytes - responseBytes
    )
  }

  private static func rolloutPreviewDependencies(
    database: SQLiteStore?,
    jobs: DurableJobStore?,
    intents: MutationIntentStore?,
    applicationSupportRoot: URL?,
    askPassExecutable: URL?
  ) -> ProductionRolloutPreviewDependencies? {
    guard let database, let jobs, let intents,
      let applicationSupportRoot, applicationSupportRoot.isFileURL,
      applicationSupportRoot.path.hasPrefix("/"),
      let askPassExecutable, askPassExecutable.isFileURL,
      askPassExecutable.path.hasPrefix("/")
    else {
      return nil
    }
    return ProductionRolloutPreviewDependencies(
      database: database,
      jobs: jobs,
      intents: intents,
      applicationSupportRoot: applicationSupportRoot.standardizedFileURL,
      askPassExecutable: askPassExecutable.standardizedFileURL
    )
  }
}
