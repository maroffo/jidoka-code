import Foundation

public struct GitHubHTTPResponse: Sendable {
  public let statusCode: Int
  public let url: URL
  public let headers: [String: String]
  public let body: Data

  public init(
    statusCode: Int,
    url: URL,
    headers: [String: String],
    body: Data
  ) {
    self.statusCode = statusCode
    self.url = url
    var normalizedHeaders: [String: String] = [:]
    for (name, value) in headers {
      normalizedHeaders[name.lowercased()] = value
    }
    self.headers = normalizedHeaders
    self.body = body
  }

  public subscript(header name: String) -> String? {
    headers[name.lowercased()]
  }
}

public protocol GitHubHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse
}

public final class GitHubURLSessionTransport: GitHubHTTPTransport, @unchecked Sendable {
  private let delegate: GitHubRedirectBlockingDelegate
  private let session: URLSession

  public init(configuration: URLSessionConfiguration = .ephemeral) {
    let delegate = GitHubRedirectBlockingDelegate()
    self.delegate = delegate
    session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
  }

  public func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse,
      let url = response.url
    else {
      throw GitHubHTTPError.invalidResponse
    }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      guard let key = key as? String else { continue }
      headers[key] = String(describing: value)
    }
    return GitHubHTTPResponse(
      statusCode: response.statusCode,
      url: url,
      headers: headers,
      body: data
    )
  }
}

final class GitHubRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public enum GitHubHTTPError: Error, Equatable, Sendable {
  case invalidResponse
  case responseTooLarge
  case unexpectedResponseURL
}

public enum GitHubRateLimitKind: String, Equatable, Sendable {
  case primary
  case secondary
  case retryAfter
}

public struct GitHubRetryDirective: Equatable, Sendable {
  public let kind: GitHubRateLimitKind
  public let notBefore: Date
}

public enum GitHubResponseDisposition: Equatable, Sendable {
  case success
  case notModified
  case repositoryRedirect(URL)
  case authenticationOrConfigurationBlocked
  case permissionBlocked
  case rateLimited(GitHubRetryDirective)
  case absent
  case staleConflict
  case clientConfigurationBlocked
  case reconcileRequired
  case validationBlocked
  case targetGone
  case retryableRead
  case escalation
}

public enum GitHubRedirectPolicy {
  public static func repositoryRedirect(
    operation: GitHubOperation,
    from source: URL,
    location: String
  ) -> URL? {
    guard operation.kind == .repository,
      let destination = URL(string: location, relativeTo: source)?.absoluteURL,
      source.scheme == "https", source.host == GitHubRequestFactory.host,
      destination.scheme == "https", destination.host == GitHubRequestFactory.host,
      destination.user == nil, destination.password == nil,
      destination.fragment == nil, destination.query == nil
    else {
      return nil
    }
    let components = destination.path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 3, components[0] == "repos",
      GitHubInputValidation.validOwner(String(components[1])),
      GitHubInputValidation.validRepository(String(components[2]))
    else {
      return nil
    }
    return destination
  }
}

public enum GitHubStatusClassifier {
  public static func classify(
    operation: GitHubOperation,
    response: GitHubHTTPResponse,
    now: Date,
    validatedCache: Bool = false
  ) -> GitHubResponseDisposition {
    let status = response.statusCode
    let kind = operation.kind
    if expectedSuccessStatuses(for: kind).contains(status) {
      return .success
    }
    if status == 304 {
      return !kind.isWrite && validatedCache ? .notModified : .escalation
    }
    if status == 301 {
      guard let location = response[header: "location"],
        let redirect = GitHubRedirectPolicy.repositoryRedirect(
          operation: operation,
          from: response.url,
          location: location
        )
      else {
        return .escalation
      }
      return .repositoryRedirect(redirect)
    }
    if status == 400 || status == 401 {
      return .authenticationOrConfigurationBlocked
    }
    if status == 403 {
      if response[header: "x-ratelimit-remaining"] == "0" {
        guard
          let directive = retryDirective(
            response: response,
            now: now,
            kind: .primary
          )
        else { return .escalation }
        return .rateLimited(directive)
      }
      if response[header: "retry-after"] != nil {
        guard
          let directive = retryDirective(
            response: response,
            now: now,
            kind: .retryAfter
          )
        else { return .escalation }
        return .rateLimited(directive)
      }
      if secondaryRateLimit(body: response.body) {
        guard
          let directive = retryDirective(
            response: response,
            now: now,
            fallback: 60,
            kind: .secondary
          )
        else { return .escalation }
        return .rateLimited(directive)
      }
      return .permissionBlocked
    }
    if status == 404 {
      switch kind {
      case .repositoryLabel, .branchReference, .pullRequest, .issue:
        return .absent
      case .removeIssueLabel:
        return .reconcileRequired
      case .createPullRequest, .createComment, .addIssueLabels,
        .createRepositoryLabel:
        return .staleConflict
      case .repository, .listPullRequestCommits, .listIssues, .listComments,
        .listIssueLabels, .listRepositoryLabels:
        return .targetGone
      case .authenticatedIdentity, .listPullRequests:
        return .escalation
      }
    }
    if status == 406 {
      return kind == .pullRequest ? .clientConfigurationBlocked : .escalation
    }
    if status == 409 {
      return kind == .branchReference ? .reconcileRequired : .escalation
    }
    if status == 410 {
      switch kind {
      case .pullRequest, .listPullRequestCommits, .issue, .listComments,
        .createComment, .listIssueLabels, .addIssueLabels, .removeIssueLabel:
        return .targetGone
      default:
        return .escalation
      }
    }
    if status == 422 {
      switch kind {
      case .listPullRequests, .listPullRequestCommits, .listIssues:
        return .validationBlocked
      case .createPullRequest, .createComment, .addIssueLabels,
        .createRepositoryLabel:
        return .reconcileRequired
      default:
        return .escalation
      }
    }
    if status == 429 {
      guard
        let directive = retryDirective(
          response: response,
          now: now,
          kind: .retryAfter
        )
      else { return .escalation }
      return .rateLimited(directive)
    }
    if [500, 502, 503, 504].contains(status) {
      return kind.isWrite ? .reconcileRequired : .retryableRead
    }
    return .escalation
  }

  public static func classify(
    operation: GitHubOperation,
    transportError: Error
  ) -> GitHubResponseDisposition {
    if let error = transportError as? URLError {
      switch error.code {
      case .timedOut, .cannotFindHost, .cannotConnectToHost,
        .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
        return operation.kind.isWrite ? .reconcileRequired : .retryableRead
      default:
        return .escalation
      }
    }
    return .escalation
  }

  private static func expectedSuccessStatuses(for kind: GitHubOperationKind) -> Set<Int> {
    switch kind {
    case .createPullRequest, .createComment, .createRepositoryLabel:
      [201]
    default:
      [200]
    }
  }

  private static func retryDirective(
    response: GitHubHTTPResponse,
    now: Date,
    fallback: TimeInterval? = nil,
    kind: GitHubRateLimitKind
  ) -> GitHubRetryDirective? {
    let latestAllowed = now.addingTimeInterval(86_400)
    let reset = response[header: "x-ratelimit-reset"]
      .flatMap(TimeInterval.init)
      .map(Date.init(timeIntervalSince1970:))
      .flatMap { ($0 >= now && $0 <= latestAllowed) ? $0 : nil }
    let retryAfter = response[header: "retry-after"]
      .flatMap { retryAfterDate($0, now: now) }
      .flatMap { ($0 >= now && $0 <= latestAllowed) ? $0 : nil }
    let fallbackDate = fallback.map { now.addingTimeInterval($0) }
    guard let notBefore = [reset, retryAfter, fallbackDate].compactMap({ $0 }).max()
    else {
      return nil
    }
    return GitHubRetryDirective(kind: kind, notBefore: notBefore)
  }

  private static func retryAfterDate(_ value: String, now: Date) -> Date? {
    if let seconds = TimeInterval(value), seconds >= 0, seconds <= 86_400 {
      return now.addingTimeInterval(seconds)
    }
    for format in [
      "EEE',' dd MMM yyyy HH':'mm':'ss z",
      "EEEE',' dd-MMM-yy HH':'mm':'ss z",
      "EEE MMM d HH':'mm':'ss yyyy",
    ] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }

  private static func secondaryRateLimit(body: Data) -> Bool {
    guard body.count <= 64 * 1_024,
      let envelope = try? JSONDecoder().decode(GitHubErrorEnvelope.self, from: body),
      let message = envelope.message?.lowercased()
    else {
      return false
    }
    return message.contains("secondary rate limit")
      || message.contains("abuse detection")
  }
}
