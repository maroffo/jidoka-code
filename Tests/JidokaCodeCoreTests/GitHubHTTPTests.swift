import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("GitHub HTTP classification and broker", .serialized)
struct GitHubHTTPTests {
  @Test("status and transport failures have operation-specific outcomes")
  func statusMatrix() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let read = GitHubOperation.issue(owner: "owner", repository: "repo", number: 1)
    let write = GitHubOperation.createComment(
      owner: "owner", repository: "repo", number: 1, body: "body")
    let repository = GitHubOperation.repository(owner: "owner", repository: "repo")
    let removeLabel = GitHubOperation.removeIssueLabel(
      owner: "owner", repository: "repo", number: 1, label: "agent:wip")
    let branch = GitHubOperation.branchReference(
      owner: "owner", repository: "repo", branch: "main")
    let listComments = GitHubOperation.listComments(
      owner: "owner", repository: "repo", number: 1, page: 1)
    let pullRead = GitHubOperation.pullRequest(
      owner: "owner", repository: "repo", number: 1)
    let listPulls = GitHubOperation.listPullRequests(
      owner: "owner", repository: "repo", page: 1, head: nil, base: nil)
    let listCommits = GitHubOperation.listPullRequestCommits(
      owner: "owner", repository: "repo", number: 1, page: 1)
    let cases: [(GitHubOperation, Int, [String: String], Data, GitHubResponseDisposition)] = [
      (read, 200, [:], Data(), .success),
      (read, 304, [:], Data(), .escalation),
      (
        repository, 301,
        ["Location": "https://api.github.com/repos/canonical/repo"],
        Data(),
        .repositoryRedirect(
          try #require(URL(string: "https://api.github.com/repos/canonical/repo"))
        )
      ),
      (write, 301, ["Location": "https://api.github.com/repos/owner/repo"], Data(), .escalation),
      (read, 400, [:], Data(), .authenticationOrConfigurationBlocked),
      (read, 401, [:], Data(), .authenticationOrConfigurationBlocked),
      (read, 403, [:], Data(), .permissionBlocked),
      (
        read, 403,
        ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1300"],
        Data(),
        .rateLimited(
          GitHubRetryDirective(
            kind: .primary,
            notBefore: Date(timeIntervalSince1970: 1_300)
          ))
      ),
      (read, 403, ["X-RateLimit-Remaining": "0"], Data(), .escalation),
      (read, 403, ["Retry-After": "malformed"], Data(), .escalation),
      (
        read, 403,
        ["Retry-After": "malformed", "X-RateLimit-Reset": "1300"],
        Data(),
        .rateLimited(
          GitHubRetryDirective(
            kind: .retryAfter,
            notBefore: Date(timeIntervalSince1970: 1_300)
          ))
      ),
      (
        read, 403, [:],
        try JSONSerialization.data(withJSONObject: ["message": "secondary rate limit"]),
        .rateLimited(
          GitHubRetryDirective(
            kind: .secondary,
            notBefore: Date(timeIntervalSince1970: 1_060)
          ))
      ),
      (read, 404, [:], Data(), .absent),
      (.authenticatedIdentity, 404, [:], Data(), .escalation),
      (branch, 404, [:], Data(), .absent),
      (removeLabel, 404, [:], Data(), .reconcileRequired),
      (listComments, 404, [:], Data(), .targetGone),
      (listCommits, 404, [:], Data(), .targetGone),
      (pullRead, 406, [:], Data(), .clientConfigurationBlocked),
      (read, 406, [:], Data(), .escalation),
      (branch, 409, [:], Data(), .reconcileRequired),
      (read, 409, [:], Data(), .escalation),
      (read, 410, [:], Data(), .targetGone),
      (.authenticatedIdentity, 410, [:], Data(), .escalation),
      (listCommits, 410, [:], Data(), .targetGone),
      (listPulls, 422, [:], Data(), .validationBlocked),
      (listCommits, 422, [:], Data(), .validationBlocked),
      (read, 422, [:], Data(), .escalation),
      (removeLabel, 422, [:], Data(), .escalation),
      (
        read, 429, ["Retry-After": "12"], Data(),
        .rateLimited(
          GitHubRetryDirective(
            kind: .retryAfter,
            notBefore: Date(timeIntervalSince1970: 1_012)
          ))
      ),
      (
        read, 429, ["Retry-After": "Thu, 01 Jan 1970 00:20:00 GMT"], Data(),
        .rateLimited(
          GitHubRetryDirective(
            kind: .retryAfter,
            notBefore: Date(timeIntervalSince1970: 1_200)
          ))
      ),
      (read, 429, [:], Data(), .escalation),
      (read, 429, ["Retry-After": "malformed"], Data(), .escalation),
      (
        read, 429,
        ["Retry-After": "malformed", "X-RateLimit-Reset": "1300"],
        Data(),
        .rateLimited(
          GitHubRetryDirective(
            kind: .retryAfter,
            notBefore: Date(timeIntervalSince1970: 1_300)
          ))
      ),
      (read, 429, ["X-RateLimit-Reset": "900"], Data(), .escalation),
      (read, 500, [:], Data(), .retryableRead),
      (read, 502, [:], Data(), .retryableRead),
      (read, 503, [:], Data(), .retryableRead),
      (read, 504, [:], Data(), .retryableRead),
      (write, 404, [:], Data(), .staleConflict),
      (write, 422, [:], Data(), .reconcileRequired),
      (write, 503, [:], Data(), .reconcileRequired),
      (read, 418, [:], Data(), .escalation),
    ]
    for (operation, status, headers, body, expected) in cases {
      let response = GitHubHTTPResponse(
        statusCode: status,
        url: try #require(URL(string: "https://api.github.com/repos/owner/repo/issues/1")),
        headers: headers,
        body: body
      )
      #expect(
        GitHubStatusClassifier.classify(
          operation: operation,
          response: response,
          now: now
        ) == expected
      )
    }
    let cached = GitHubHTTPResponse(
      statusCode: 304,
      url: try #require(URL(string: "https://api.github.com/repos/owner/repo/issues/1")),
      headers: [:],
      body: Data()
    )
    #expect(
      GitHubStatusClassifier.classify(
        operation: read,
        response: cached,
        now: now,
        validatedCache: true
      ) == .notModified
    )
    #expect(
      GitHubStatusClassifier.classify(
        operation: read,
        transportError: URLError(.timedOut)
      ) == .retryableRead
    )
    #expect(
      GitHubStatusClassifier.classify(
        operation: write,
        transportError: URLError(.networkConnectionLost)
      ) == .reconcileRequired
    )
  }

  @Test("redirect policy allows one canonical repository GET on the API host only")
  func redirectPolicy() throws {
    let operation = GitHubOperation.repository(owner: "old-owner", repository: "repo")
    let source = try #require(URL(string: "https://api.github.com/repos/old-owner/repo"))
    #expect(
      GitHubRedirectPolicy.repositoryRedirect(
        operation: operation,
        from: source,
        location: "https://api.github.com/repos/new-owner/repo"
      ) == URL(string: "https://api.github.com/repos/new-owner/repo")
    )
    for location in [
      "https://example.com/repos/new-owner/repo",
      "http://api.github.com/repos/new-owner/repo",
      "https://user@api.github.com/repos/new-owner/repo",
      "https://api.github.com/repos/new-owner/repo?token=value",
      "https://api.github.com/user",
    ] {
      #expect(
        GitHubRedirectPolicy.repositoryRedirect(
          operation: operation,
          from: source,
          location: location
        ) == nil
      )
    }
    #expect(
      GitHubRedirectPolicy.repositoryRedirect(
        operation: .createComment(
          owner: "owner", repository: "repo", number: 1, body: "body"),
        from: source,
        location: "https://api.github.com/repos/new-owner/repo"
      ) == nil
    )
  }

  @Test("production URLSession transport executes through an offline URLProtocol fixture")
  func urlSessionFixture() async throws {
    URLProtocolFixtureState.shared.reset(
      body: try JSONSerialization.data(
        withJSONObject: userJSON(id: 7, login: "fixture-user")
      )
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GitHubFixtureURLProtocol.self]
    let broker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: GitHubURLSessionTransport(configuration: configuration)
    )

    let identity = try await broker.authenticatedIdentity()
    #expect(identity.login == "fixture-user")
    let requests = URLProtocolFixtureState.shared.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://api.github.com/user")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(String(repeating: "t", count: 32))")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
  }

  @Test("broker paginates to exhaustion and attaches the token only to the fixed host")
  func paginationAndCredentialBoundary() async throws {
    let firstPage = try JSONSerialization.data(
      withJSONObject: (1...100).map(pullRequestJSON)
    )
    let secondPage = try JSONSerialization.data(
      withJSONObject: [pullRequestJSON(101)]
    )
    let transport = ScriptedGitHubTransport(stubs: [
      .response(status: 200, headers: [:], body: firstPage),
      .response(status: 200, headers: [:], body: secondPage),
    ])
    let token = Data(repeating: 0x74, count: 32)
    let broker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: token),
      transport: transport,
      now: { Date(timeIntervalSince1970: 1_000) }
    )

    let values = try await broker.listPullRequests(owner: "owner", repository: "repo")
    #expect(values.count == 101)
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url?.host == "api.github.com" })
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(String(repeating: "t", count: 32))"
      })
    #expect(
      requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false) }
        .compactMap { components in
          components.queryItems?.first(where: { $0.name == "page" })?.value
        } == ["1", "2"]
    )

    let oversizedPage = try JSONSerialization.data(
      withJSONObject: (1...101).map(pullRequestJSON)
    )
    let invalidTransport = ScriptedGitHubTransport(stubs: [
      .response(status: 200, headers: [:], body: oversizedPage)
    ])
    let invalidBroker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: token),
      transport: invalidTransport
    )
    await #expect(throws: GitHubBrokerError.decodingFailed(.listPullRequests)) {
      _ = try await invalidBroker.listPullRequests(owner: "owner", repository: "repo")
    }
  }

  @Test("pull request commits paginate in exact API order and reject duplicates")
  func pullRequestCommitPagination() async throws {
    let firstPage = try JSONSerialization.data(
      withJSONObject: (1...100).map(pullRequestCommitJSON)
    )
    let secondPage = try JSONSerialization.data(
      withJSONObject: [pullRequestCommitJSON(101)]
    )
    let token = Data(repeating: 0x74, count: 32)
    let transport = ScriptedGitHubTransport(stubs: [
      .response(status: 200, headers: [:], body: firstPage),
      .response(status: 200, headers: [:], body: secondPage),
    ])
    let broker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: token),
      transport: transport
    )

    let commits = try await broker.listPullRequestCommits(
      owner: "owner",
      repository: "repo",
      number: 7
    )
    #expect(commits.count == 101)
    #expect(commits.map(\.sha) == (1...101).map { pullRequestCommitSHA($0) })
    #expect(
      (await transport.requests()).map(\.url?.path) == [
        "/repos/owner/repo/pulls/7/commits",
        "/repos/owner/repo/pulls/7/commits",
      ]
    )

    let duplicate = try JSONSerialization.data(
      withJSONObject: [pullRequestCommitJSON(1), pullRequestCommitJSON(1)]
    )
    let duplicateBroker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: token),
      transport: ScriptedGitHubTransport(stubs: [
        .response(status: 200, headers: [:], body: duplicate)
      ])
    )
    await #expect(throws: GitHubBrokerError.decodingFailed(.listPullRequestCommits)) {
      _ = try await duplicateBroker.listPullRequestCommits(
        owner: "owner",
        repository: "repo",
        number: 7
      )
    }
  }

  @Test("repository redirect requires the expected node identity")
  func repositoryRedirectIdentity() async throws {
    let repository = try JSONSerialization.data(
      withJSONObject: repositoryJSON(nodeID: "R_expected"))
    let transport = ScriptedGitHubTransport(stubs: [
      .response(
        status: 301,
        headers: ["Location": "https://api.github.com/repos/new-owner/repo"],
        body: Data()
      ),
      .response(status: 200, headers: [:], body: repository),
    ])
    let broker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: transport
    )
    let value = try await broker.repository(
      owner: "old-owner",
      repository: "repo",
      expectedNodeID: "R_expected"
    )
    #expect(value.nodeID == "R_expected")
    #expect(
      (await transport.requests()).map(\.url?.path) == [
        "/repos/old-owner/repo", "/repos/new-owner/repo",
      ])
  }

  @Test("direct repository reads validate canonical identity and default branch")
  func directRepositoryIdentity() async throws {
    let data = try JSONSerialization.data(
      withJSONObject: repositoryJSON(nodeID: "R_expected")
    )
    let validTransport = ScriptedGitHubTransport(stubs: [
      .response(status: 200, headers: [:], body: data)
    ])
    let validBroker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: validTransport
    )
    #expect(
      try await validBroker.repository(
        owner: "new-owner",
        repository: "repo"
      ).nodeID == "R_expected"
    )

    let mismatchTransport = ScriptedGitHubTransport(stubs: [
      .response(status: 200, headers: [:], body: data)
    ])
    let mismatchBroker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: mismatchTransport
    )
    await #expect(throws: GitHubBrokerError.redirectedRepositoryIdentityMismatch) {
      _ = try await mismatchBroker.repository(
        owner: "new-owner",
        repository: "repo",
        expectedNodeID: "R_other"
      )
    }
  }

  @Test("oversized and cross-host responses fail closed")
  func unsafeResponses() async throws {
    let oversized = ScriptedGitHubTransport(stubs: [
      .response(
        status: 200,
        headers: [:],
        body: Data(repeating: 0, count: GitHubBroker.maximumResponseBytes + 1)
      )
    ])
    let broker = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: oversized
    )
    await #expect(throws: GitHubBrokerError.responseTooLarge) {
      _ = try await broker.perform(.authenticatedIdentity)
    }

    let crossHost = CrossHostGitHubTransport()
    let second = GitHubBroker(
      tokenProvider: StaticGitHubTokenProvider(value: Data(repeating: 0x74, count: 32)),
      transport: crossHost
    )
    await #expect(throws: GitHubBrokerError.unexpectedResponseURL) {
      _ = try await second.perform(.authenticatedIdentity)
    }
  }
}

private final class URLProtocolFixtureState: @unchecked Sendable {
  static let shared = URLProtocolFixtureState()

  private let lock = NSLock()
  private var requests: [URLRequest] = []
  private var body = Data()

  func reset(body: Data) {
    lock.withLock {
      requests = []
      self.body = body
    }
  }

  func response(for request: URLRequest) -> (URLRequest, Data) {
    lock.withLock {
      requests.append(request)
      return (request, body)
    }
  }

  func recordedRequests() -> [URLRequest] {
    lock.withLock { requests }
  }
}

private final class GitHubFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let (request, body) = URLProtocolFixtureState.shared.response(for: request)
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private struct StaticGitHubTokenProvider: GitHubTokenProviding {
  let value: Data

  func token() async throws -> Data { value }
}

private enum ScriptedGitHubStub: Sendable {
  case response(status: Int, headers: [String: String], body: Data)
  case failure(URLError.Code)
}

private actor ScriptedGitHubTransport: GitHubHTTPTransport {
  private var stubs: [ScriptedGitHubStub]
  private var recorded: [URLRequest] = []

  init(stubs: [ScriptedGitHubStub]) {
    self.stubs = stubs
  }

  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    recorded.append(request)
    guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
    let stub = stubs.removeFirst()
    switch stub {
    case .response(let status, let headers, let body):
      return GitHubHTTPResponse(
        statusCode: status,
        url: try #require(request.url),
        headers: headers,
        body: body
      )
    case .failure(let code):
      throw URLError(code)
    }
  }

  func requests() -> [URLRequest] { recorded }
}

private struct CrossHostGitHubTransport: GitHubHTTPTransport {
  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    GitHubHTTPResponse(
      statusCode: 200,
      url: URL(string: "https://example.com/redirected")!,
      headers: [:],
      body: Data("{}".utf8)
    )
  }
}

private func pullRequestCommitSHA(_ number: Int) -> String {
  String(format: "%040llx", Int64(number))
}

private func pullRequestCommitJSON(_ number: Int) -> [String: Any] {
  ["sha": pullRequestCommitSHA(number)]
}

private func pullRequestJSON(_ number: Int) -> [String: Any] {
  [
    "id": number,
    "node_id": "PR_\(number)",
    "number": number,
    "state": "open",
    "draft": false,
    "title": "PR \(number)",
    "body": "body",
    "html_url": "https://github.com/owner/repo/pull/\(number)",
    "user": userJSON(id: number, login: "user"),
    "head": [
      "ref": "feature-\(number)",
      "sha": String(repeating: "a", count: 40),
      "repo": repositorySummaryJSON(),
    ],
    "base": [
      "ref": "main",
      "sha": String(repeating: "b", count: 40),
      "repo": repositorySummaryJSON(),
    ],
  ]
}

private func repositoryJSON(nodeID: String) -> [String: Any] {
  [
    "id": 1,
    "node_id": nodeID,
    "name": "repo",
    "full_name": "new-owner/repo",
    "default_branch": "main",
    "owner": userJSON(id: 1, login: "new-owner"),
  ]
}

private func repositorySummaryJSON() -> [String: Any] {
  [
    "id": 1,
    "node_id": "R_repo",
    "full_name": "owner/repo",
  ]
}

private func userJSON(id: Int, login: String) -> [String: Any] {
  [
    "id": id,
    "node_id": "U_\(id)",
    "login": login,
  ]
}
