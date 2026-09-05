import Foundation

public struct GitHubBrokerResponse: Sendable {
  public let operation: GitHubOperation
  public let disposition: GitHubResponseDisposition
  public let statusCode: Int?
  public let headers: [String: String]
  public let body: Data
}

public enum GitHubBrokerError: Error, Equatable, Sendable {
  case invalidCredential
  case unexpectedDisposition(GitHubOperationKind, GitHubResponseDisposition)
  case decodingFailed(GitHubOperationKind)
  case redirectedRepositoryIdentityMismatch
  case paginationLimitReached(GitHubOperationKind)
  case responseTooLarge
  case unexpectedResponseURL
  case writeOperationRequired
  case rolloutAuthorityRequired
}

public protocol GitHubReadAPI: Sendable {
  func listPullRequests(owner: String, repository: String) async throws
    -> [GitHubPullRequest]
  func listIssues(owner: String, repository: String) async throws -> [GitHubIssue]
}

public protocol GitHubPullRequestCommitAPI: Sendable {
  func listPullRequestCommits(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> [GitHubPullRequestCommit]
}

public protocol GitHubMutationReadAPI: Sendable {
  func pullRequest(owner: String, repository: String, number: Int) async throws
    -> GitHubPullRequest
  func issue(owner: String, repository: String, number: Int) async throws -> GitHubIssue
  func listComments(owner: String, repository: String, number: Int) async throws
    -> [GitHubComment]
  func listIssueLabels(owner: String, repository: String, number: Int) async throws
    -> [GitHubLabel]
  func lookupPullRequests(
    owner: String,
    repository: String,
    head: String,
    base: String
  ) async throws -> [GitHubPullRequest]
  func repositoryLabel(owner: String, repository: String, label: String) async throws
    -> GitHubLabel?
  func branchReference(owner: String, repository: String, branch: String) async throws
    -> GitHubReference?
}

public protocol GitHubMutationSending: Sendable {
  func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse
}

public actor GitHubBroker: GitHubReadAPI, GitHubPullRequestCommitAPI,
  GitHubMutationReadAPI, GitHubMutationSending
{
  public static let maximumResponseBytes = 10 * 1_024 * 1_024
  public static let maximumPaginatedBytes = 32 * 1_024 * 1_024
  public static let maximumPages = 1_000
  public static let maximumItems = 100_000

  private let tokenProvider: any GitHubTokenProviding
  private let transport: any GitHubHTTPTransport
  private let readAuthority: any RolloutGitHubReadAuthorizing
  private let effectAuthority: (any RolloutEffectAuthorizing)?
  private let defaultReadContext: RolloutEffectExecutionContext?
  private let now: @Sendable () -> Date
  private let decoder: JSONDecoder

  public init(
    tokenStore: GitHubTokenStore,
    authority: any RolloutEffectAuthorizing
  ) {
    tokenProvider = tokenStore
    transport = GitHubURLSessionTransport()
    readAuthority = authority
    effectAuthority = authority
    defaultReadContext = nil
    now = Date.init
    decoder = JSONDecoder()
  }

  public init(
    tokenProvider: any GitHubTokenProviding,
    transport: any GitHubHTTPTransport,
    readAuthority: any RolloutGitHubReadAuthorizing,
    effectAuthority: (any RolloutEffectAuthorizing)? = nil,
    defaultReadContext: RolloutEffectExecutionContext? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.tokenProvider = tokenProvider
    self.transport = transport
    self.readAuthority = readAuthority
    self.effectAuthority = effectAuthority
    self.defaultReadContext = defaultReadContext
    self.now = now
    decoder = JSONDecoder()
  }

  func makeGitCredentialSession(
    remoteURL: URL,
    socketDirectory: URL,
    timeoutSeconds: TimeInterval = 30
  ) async throws -> OneShotGitCredentialSession {
    guard RolloutGitCredentialTaskContext.remoteURL == remoteURL.absoluteString else {
      throw GitHubBrokerError.rolloutAuthorityRequired
    }
    var token = try await tokenProvider.token()
    let tokenCount = token.count
    defer { token.resetBytes(in: 0..<tokenCount) }
    guard (20...2_048).contains(token.count),
      token.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw GitHubBrokerError.invalidCredential
    }
    return try OneShotGitCredentialServer.start(
      token: token,
      remoteURL: remoteURL,
      socketDirectory: socketDirectory,
      timeoutSeconds: timeoutSeconds,
      now: now()
    )
  }

  func perform(_ operation: GitHubOperation) async throws -> GitHubBrokerResponse {
    guard !operation.kind.isWrite else {
      throw GitHubBrokerError.writeOperationRequired
    }
    return try await send(operation: operation, overrideURL: nil, beforeSend: nil)
  }

  public func performMutation(
    _ operation: GitHubOperation,
    beforeSend: @escaping @Sendable () async throws -> RolloutEffectPermit
  ) async throws -> GitHubBrokerResponse {
    guard operation.kind.isWrite else {
      throw GitHubBrokerError.writeOperationRequired
    }
    return try await send(
      operation: operation,
      overrideURL: nil,
      beforeSend: beforeSend
    )
  }

  public func authenticatedIdentity() async throws -> GitHubUser {
    try await decoded(.authenticatedIdentity, as: GitHubUser.self)
  }

  public func repository(
    owner: String,
    repository: String,
    expectedNodeID: String? = nil
  ) async throws -> GitHubRepository {
    let operation = GitHubOperation.repository(owner: owner, repository: repository)
    let first = try await perform(operation)
    switch first.disposition {
    case .success:
      let value = try decode(first, as: GitHubRepository.self)
      guard
        Self.validRepository(
          value,
          owner: owner,
          repository: repository,
          expectedNodeID: expectedNodeID
        )
      else {
        throw GitHubBrokerError.redirectedRepositoryIdentityMismatch
      }
      return value
    case .repositoryRedirect(let destination):
      guard let expectedNodeID, !expectedNodeID.isEmpty else {
        throw GitHubBrokerError.redirectedRepositoryIdentityMismatch
      }
      let redirected = try await send(
        operation: operation,
        overrideURL: destination,
        beforeSend: nil
      )
      guard redirected.disposition == .success else {
        throw GitHubBrokerError.unexpectedDisposition(
          operation.kind,
          redirected.disposition
        )
      }
      let value = try decode(redirected, as: GitHubRepository.self)
      let path = destination.path.split(separator: "/")
      guard path.count == 3,
        Self.validRepository(
          value,
          owner: String(path[1]),
          repository: String(path[2]),
          expectedNodeID: expectedNodeID
        ),
        redirected.statusCode == 200
      else {
        throw GitHubBrokerError.redirectedRepositoryIdentityMismatch
      }
      return value
    default:
      throw GitHubBrokerError.unexpectedDisposition(operation.kind, first.disposition)
    }
  }

  public func listPullRequests(
    owner: String,
    repository: String
  ) async throws -> [GitHubPullRequest] {
    try await allPages(kind: .listPullRequests) { page in
      .listPullRequests(
        owner: owner,
        repository: repository,
        page: page,
        head: nil,
        base: nil
      )
    }
  }

  public func lookupPullRequests(
    owner: String,
    repository: String,
    head: String,
    base: String
  ) async throws -> [GitHubPullRequest] {
    try await allPages(kind: .listPullRequests) { page in
      .listPullRequests(
        owner: owner,
        repository: repository,
        page: page,
        head: head,
        base: base
      )
    }
  }

  public func pullRequest(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> GitHubPullRequest {
    try await decoded(
      .pullRequest(owner: owner, repository: repository, number: number),
      as: GitHubPullRequest.self
    )
  }

  public func listPullRequestCommits(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> [GitHubPullRequestCommit] {
    let commits: [GitHubPullRequestCommit] = try await allPages(
      kind: .listPullRequestCommits
    ) { page in
      .listPullRequestCommits(
        owner: owner,
        repository: repository,
        number: number,
        page: page
      )
    }
    guard !commits.isEmpty,
      commits.count <= 10_000,
      Set(commits.map(\.sha)).count == commits.count,
      commits.allSatisfy({ GitHubInputValidation.validGitSHA($0.sha) })
    else {
      throw GitHubBrokerError.decodingFailed(.listPullRequestCommits)
    }
    return commits
  }

  public func listIssues(
    owner: String,
    repository: String
  ) async throws -> [GitHubIssue] {
    try await allPages(kind: .listIssues) { page in
      .listIssues(owner: owner, repository: repository, page: page)
    }
  }

  public func issue(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> GitHubIssue {
    try await decoded(
      .issue(owner: owner, repository: repository, number: number),
      as: GitHubIssue.self
    )
  }

  public func listComments(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> [GitHubComment] {
    try await allPages(kind: .listComments) { page in
      .listComments(owner: owner, repository: repository, number: number, page: page)
    }
  }

  public func listIssueLabels(
    owner: String,
    repository: String,
    number: Int
  ) async throws -> [GitHubLabel] {
    try await allPages(kind: .listIssueLabels) { page in
      .listIssueLabels(owner: owner, repository: repository, number: number, page: page)
    }
  }

  public func listRepositoryLabels(
    owner: String,
    repository: String
  ) async throws -> [GitHubLabel] {
    try await allPages(kind: .listRepositoryLabels) { page in
      .listRepositoryLabels(owner: owner, repository: repository, page: page)
    }
  }

  public func repositoryLabel(
    owner: String,
    repository: String,
    label: String
  ) async throws -> GitHubLabel? {
    let operation = GitHubOperation.repositoryLabel(
      owner: owner,
      repository: repository,
      label: label
    )
    let response = try await perform(operation)
    switch response.disposition {
    case .success:
      return try decode(response, as: GitHubLabel.self)
    case .absent:
      return nil
    default:
      throw GitHubBrokerError.unexpectedDisposition(operation.kind, response.disposition)
    }
  }

  public func branchReference(
    owner: String,
    repository: String,
    branch: String
  ) async throws -> GitHubReference? {
    let operation = GitHubOperation.branchReference(
      owner: owner,
      repository: repository,
      branch: branch
    )
    let response = try await perform(operation)
    switch response.disposition {
    case .success:
      let value = try decode(response, as: GitHubReference.self)
      guard value.ref == "refs/heads/\(branch)",
        GitHubInputValidation.validGitSHA(value.object.sha)
      else {
        throw GitHubBrokerError.decodingFailed(operation.kind)
      }
      return value
    case .absent:
      return nil
    default:
      throw GitHubBrokerError.unexpectedDisposition(operation.kind, response.disposition)
    }
  }

  private func send(
    operation: GitHubOperation,
    overrideURL: URL?,
    beforeSend: (@Sendable () async throws -> RolloutEffectPermit)?
  ) async throws -> GitHubBrokerResponse {
    guard operation.kind.isWrite == (beforeSend != nil) else {
      throw GitHubBrokerError.writeOperationRequired
    }
    let descriptor = try GitHubRequestFactory.make(operation)
    var request = descriptor.request
    if let overrideURL {
      guard let sourceURL = request.url,
        GitHubRedirectPolicy.repositoryRedirect(
          operation: operation,
          from: sourceURL,
          location: overrideURL.absoluteString
        ) == overrideURL
      else {
        throw GitHubBrokerError.unexpectedResponseURL
      }
      request.url = overrideURL
    }

    let readEffect: RolloutGitHubReadEffect?
    let readPermit: RolloutEffectPermit?
    if operation.kind.isWrite {
      readEffect = nil
      readPermit = nil
    } else {
      guard let context = RolloutEffectTaskContext.current ?? defaultReadContext else {
        throw GitHubBrokerError.rolloutAuthorityRequired
      }
      let effect = RolloutGitHubReadEffect(
        operation: operation,
        maximumResponseBytes: Int64(Self.maximumResponseBytes),
        context: context
      )
      readEffect = effect
      readPermit = try await readAuthority.reserveGitHubRead(
        effect,
        now: now()
      )
    }

    let tokenData: Data
    do {
      tokenData = try await tokenProvider.token()
    } catch {
      if let readPermit {
        try? await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(operation: operation, error: error)
        )
      }
      throw error
    }
    guard (20...2_048).contains(tokenData.count),
      let token = String(data: tokenData, encoding: .utf8),
      token.utf8.count == tokenData.count,
      token.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      if let readPermit {
        try await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(
            operation: operation,
            error: GitHubBrokerError.invalidCredential
          )
        )
      }
      throw GitHubBrokerError.invalidCredential
    }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let readPermit, let readEffect {
      do {
        try await readAuthority.verifyGitHubReadPermit(readPermit, effect: readEffect)
      } catch {
        try? await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(operation: operation, error: error)
        )
        throw error
      }
    }
    let sendPermit: RolloutEffectPermit?
    if let beforeSend {
      guard let effectAuthority else {
        throw GitHubBrokerError.rolloutAuthorityRequired
      }
      let permit = try await beforeSend()
      try await effectAuthority.verifyGitHubSendPermit(permit, operation: operation)
      sendPermit = permit
    } else {
      sendPermit = nil
    }

    let brokerResponse: GitHubBrokerResponse
    do {
      let response = try await transport.send(request)
      guard response.body.count <= Self.maximumResponseBytes else {
        throw GitHubBrokerError.responseTooLarge
      }
      guard response.url.scheme == "https",
        response.url.host == GitHubRequestFactory.host,
        response.url.user == nil,
        response.url.password == nil
      else {
        throw GitHubBrokerError.unexpectedResponseURL
      }
      brokerResponse = GitHubBrokerResponse(
        operation: operation,
        disposition: GitHubStatusClassifier.classify(
          operation: operation,
          response: response,
          now: now()
        ),
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body
      )
    } catch let error as GitHubBrokerError {
      if let readPermit {
        try? await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(operation: operation, error: error)
        )
      }
      throw error
    } catch is CancellationError {
      if let readPermit {
        try? await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(operation: operation, error: CancellationError())
        )
      }
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      if let readPermit {
        try? await settleRead(
          readPermit,
          operation: operation,
          evidence: Self.failureEvidence(operation: operation, error: error)
        )
      }
      throw CancellationError()
    } catch {
      brokerResponse = GitHubBrokerResponse(
        operation: operation,
        disposition: GitHubStatusClassifier.classify(
          operation: operation,
          transportError: error
        ),
        statusCode: nil,
        headers: [:],
        body: Data()
      )
    }
    if let readPermit {
      try await settleRead(
        readPermit,
        operation: operation,
        evidence: Self.responseEvidence(brokerResponse)
      )
    }
    _ = sendPermit
    return brokerResponse
  }

  private func settleRead(
    _ permit: RolloutEffectPermit,
    operation: GitHubOperation,
    evidence: String
  ) async throws {
    try await readAuthority.settleGitHubRead(permit, evidenceSHA256: evidence, now: now())
  }

  private static func responseEvidence(_ response: GitHubBrokerResponse) -> String {
    var bytes = Data(response.operation.operationID.utf8)
    bytes.append(0x0A)
    bytes.append(Data(String(response.statusCode ?? 0).utf8))
    bytes.append(0x0A)
    bytes.append(Data(GitHubMarkerCodec.sha256(response.body).utf8))
    return GitHubMarkerCodec.sha256(bytes)
  }

  private static func failureEvidence(
    operation: GitHubOperation,
    error: any Error
  ) -> String {
    let value = "\(operation.operationID)\n\(String(reflecting: type(of: error)))"
    return GitHubMarkerCodec.sha256(Data(value.utf8))
  }

  private func decoded<T: Decodable & Sendable>(
    _ operation: GitHubOperation,
    as type: T.Type
  ) async throws -> T {
    let response = try await perform(operation)
    guard response.disposition == .success else {
      throw GitHubBrokerError.unexpectedDisposition(operation.kind, response.disposition)
    }
    return try decode(response, as: type)
  }

  private func decode<T: Decodable & Sendable>(
    _ response: GitHubBrokerResponse,
    as type: T.Type
  ) throws -> T {
    do {
      return try decoder.decode(type, from: response.body)
    } catch {
      throw GitHubBrokerError.decodingFailed(response.operation.kind)
    }
  }

  private static func validRepository(
    _ value: GitHubRepository,
    owner: String,
    repository: String,
    expectedNodeID: String?
  ) -> Bool {
    value.fullName.caseInsensitiveCompare("\(owner)/\(repository)") == .orderedSame
      && value.owner.login.caseInsensitiveCompare(owner) == .orderedSame
      && value.name.caseInsensitiveCompare(repository) == .orderedSame
      && !value.nodeID.isEmpty
      && GitHubInputValidation.validBranch(value.defaultBranch)
      && (expectedNodeID.map { value.nodeID == $0 } ?? true)
  }

  private func allPages<T: Decodable & Sendable>(
    kind: GitHubOperationKind,
    operation: (Int) -> GitHubOperation
  ) async throws -> [T] {
    var all: [T] = []
    var encodedBytes = 0
    for page in 1...Self.maximumPages {
      let current = operation(page)
      let response = try await perform(current)
      guard response.disposition == .success else {
        throw GitHubBrokerError.unexpectedDisposition(kind, response.disposition)
      }
      guard encodedBytes <= Self.maximumPaginatedBytes - response.body.count else {
        throw GitHubBrokerError.responseTooLarge
      }
      encodedBytes += response.body.count
      let values: [T] = try decode(response, as: [T].self)
      guard values.count <= 100 else {
        throw GitHubBrokerError.decodingFailed(kind)
      }
      guard all.count <= Self.maximumItems - values.count else {
        throw GitHubBrokerError.paginationLimitReached(kind)
      }
      all.append(contentsOf: values)
      if values.count < 100 { return all }
    }
    throw GitHubBrokerError.paginationLimitReached(kind)
  }
}
