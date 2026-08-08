import Foundation

public enum GitHubHTTPMethod: String, Equatable, Sendable {
  case get = "GET"
  case post = "POST"
  case delete = "DELETE"
}

public enum GitHubOperationKind: String, CaseIterable, Codable, Sendable {
  case authenticatedIdentity
  case repository
  case listPullRequests
  case pullRequest
  case listPullRequestCommits
  case createPullRequest
  case listIssues
  case issue
  case listComments
  case createComment
  case listIssueLabels
  case addIssueLabels
  case removeIssueLabel
  case listRepositoryLabels
  case repositoryLabel
  case createRepositoryLabel
  case branchReference

  public var isWrite: Bool {
    switch self {
    case .createPullRequest, .createComment, .addIssueLabels,
      .removeIssueLabel, .createRepositoryLabel:
      true
    default:
      false
    }
  }

  public var isCreate: Bool {
    switch self {
    case .createPullRequest, .createComment, .createRepositoryLabel:
      true
    default:
      false
    }
  }
}

public struct GitHubCreatePullRequest: Equatable, Sendable {
  public let title: String
  public let head: String
  public let base: String
  public let body: String

  public init(title: String, head: String, base: String, body: String) {
    self.title = title
    self.head = head
    self.base = base
    self.body = body
  }
}

public struct GitHubCreateLabel: Equatable, Sendable {
  public let name: String
  public let color: String
  public let description: String

  public init(name: String, color: String, description: String) {
    self.name = name
    self.color = color
    self.description = description
  }
}

public enum GitHubOperation: Equatable, Sendable {
  case authenticatedIdentity
  case repository(owner: String, repository: String)
  case listPullRequests(
    owner: String,
    repository: String,
    page: Int,
    head: String?,
    base: String?
  )
  case pullRequest(owner: String, repository: String, number: Int)
  case listPullRequestCommits(
    owner: String,
    repository: String,
    number: Int,
    page: Int
  )
  case createPullRequest(
    owner: String,
    repository: String,
    request: GitHubCreatePullRequest
  )
  case listIssues(owner: String, repository: String, page: Int)
  case issue(owner: String, repository: String, number: Int)
  case listComments(owner: String, repository: String, number: Int, page: Int)
  case createComment(owner: String, repository: String, number: Int, body: String)
  case listIssueLabels(owner: String, repository: String, number: Int, page: Int)
  case addIssueLabels(owner: String, repository: String, number: Int, labels: [String])
  case removeIssueLabel(owner: String, repository: String, number: Int, label: String)
  case listRepositoryLabels(owner: String, repository: String, page: Int)
  case repositoryLabel(owner: String, repository: String, label: String)
  case createRepositoryLabel(
    owner: String,
    repository: String,
    request: GitHubCreateLabel
  )
  case branchReference(owner: String, repository: String, branch: String)

  public var kind: GitHubOperationKind {
    switch self {
    case .authenticatedIdentity: .authenticatedIdentity
    case .repository: .repository
    case .listPullRequests: .listPullRequests
    case .pullRequest: .pullRequest
    case .listPullRequestCommits: .listPullRequestCommits
    case .createPullRequest: .createPullRequest
    case .listIssues: .listIssues
    case .issue: .issue
    case .listComments: .listComments
    case .createComment: .createComment
    case .listIssueLabels: .listIssueLabels
    case .addIssueLabels: .addIssueLabels
    case .removeIssueLabel: .removeIssueLabel
    case .listRepositoryLabels: .listRepositoryLabels
    case .repositoryLabel: .repositoryLabel
    case .createRepositoryLabel: .createRepositoryLabel
    case .branchReference: .branchReference
    }
  }

  public var operationID: String {
    switch kind {
    case .authenticatedIdentity: "users/get-authenticated"
    case .repository: "repos/get"
    case .listPullRequests: "pulls/list"
    case .pullRequest: "pulls/get"
    case .listPullRequestCommits: "pulls/list-commits"
    case .createPullRequest: "pulls/create"
    case .listIssues: "issues/list-for-repo"
    case .issue: "issues/get"
    case .listComments: "issues/list-comments"
    case .createComment: "issues/create-comment"
    case .listIssueLabels: "issues/list-labels-on-issue"
    case .addIssueLabels: "issues/add-labels"
    case .removeIssueLabel: "issues/remove-label"
    case .listRepositoryLabels: "issues/list-labels-for-repo"
    case .repositoryLabel: "issues/get-label"
    case .createRepositoryLabel: "issues/create-label"
    case .branchReference: "git/get-ref"
    }
  }
}

public struct GitHubRequestDescriptor: Sendable {
  public let operation: GitHubOperation
  public let request: URLRequest
  public let expectedSuccessStatuses: Set<Int>

  public var operationID: String { operation.operationID }
}

public enum GitHubRequestFactoryError: Error, Equatable, Sendable {
  case invalidOwner
  case invalidRepository
  case invalidNumber
  case invalidPage
  case invalidBranch
  case invalidHead
  case invalidLabel
  case invalidTitle
  case invalidBody
  case invalidColor
  case invalidDescription
  case invalidURL
  case encodingFailed
}

public enum GitHubRequestFactory {
  public static let host = "api.github.com"
  public static let apiVersion = "2022-11-28"
  public static let accept = "application/vnd.github+json"
  public static let timeout: TimeInterval = 30

  public static func make(_ operation: GitHubOperation) throws -> GitHubRequestDescriptor {
    let components = try requestComponents(operation)
    guard let url = components.url, url.scheme == "https", url.host == host,
      url.user == nil, url.password == nil, url.fragment == nil
    else {
      throw GitHubRequestFactoryError.invalidURL
    }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method(for: operation).rawValue
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("JidokaCode/1", forHTTPHeaderField: "User-Agent")
    if let body = try body(for: operation) {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    return GitHubRequestDescriptor(
      operation: operation,
      request: request,
      expectedSuccessStatuses: successStatuses(for: operation.kind)
    )
  }

  private static func requestComponents(
    _ operation: GitHubOperation
  ) throws -> URLComponents {
    var path: [String]
    var query: [URLQueryItem] = []

    switch operation {
    case .authenticatedIdentity:
      path = ["user"]
    case .repository(let owner, let repository):
      try validate(owner: owner, repository: repository)
      path = ["repos", owner, repository]
    case .listPullRequests(let owner, let repository, let page, let head, let base):
      try validate(owner: owner, repository: repository)
      try validate(page: page)
      path = ["repos", owner, repository, "pulls"]
      query = [URLQueryItem(name: "state", value: "open")] + pagination(page: page)
      if let head {
        guard GitHubInputValidation.validHead(head) else {
          throw GitHubRequestFactoryError.invalidHead
        }
        query.append(URLQueryItem(name: "head", value: head))
      }
      if let base {
        guard GitHubInputValidation.validBranch(base) else {
          throw GitHubRequestFactoryError.invalidBranch
        }
        query.append(URLQueryItem(name: "base", value: base))
      }
    case .pullRequest(let owner, let repository, let number):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      path = ["repos", owner, repository, "pulls", String(number)]
    case .listPullRequestCommits(let owner, let repository, let number, let page):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      try validate(page: page)
      path = ["repos", owner, repository, "pulls", String(number), "commits"]
      query = pagination(page: page)
    case .createPullRequest(let owner, let repository, let payload):
      try validate(owner: owner, repository: repository)
      try validate(pullRequest: payload)
      path = ["repos", owner, repository, "pulls"]
    case .listIssues(let owner, let repository, let page):
      try validate(owner: owner, repository: repository)
      try validate(page: page)
      path = ["repos", owner, repository, "issues"]
      query = [
        URLQueryItem(name: "state", value: "open"),
        URLQueryItem(name: "per_page", value: "100"),
        URLQueryItem(name: "page", value: String(page)),
      ]
    case .issue(let owner, let repository, let number):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      path = ["repos", owner, repository, "issues", String(number)]
    case .listComments(let owner, let repository, let number, let page):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      try validate(page: page)
      path = ["repos", owner, repository, "issues", String(number), "comments"]
      query = pagination(page: page)
    case .createComment(let owner, let repository, let number, let commentBody):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      try validate(body: commentBody)
      path = ["repos", owner, repository, "issues", String(number), "comments"]
    case .listIssueLabels(let owner, let repository, let number, let page):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      try validate(page: page)
      path = ["repos", owner, repository, "issues", String(number), "labels"]
      query = pagination(page: page)
    case .addIssueLabels(let owner, let repository, let number, let labels):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      guard !labels.isEmpty, labels.count <= 20,
        labels.allSatisfy(GitHubInputValidation.validLabel)
      else {
        throw GitHubRequestFactoryError.invalidLabel
      }
      path = ["repos", owner, repository, "issues", String(number), "labels"]
    case .removeIssueLabel(let owner, let repository, let number, let label):
      try validate(owner: owner, repository: repository)
      try validate(number: number)
      guard GitHubInputValidation.validLabel(label) else {
        throw GitHubRequestFactoryError.invalidLabel
      }
      path = ["repos", owner, repository, "issues", String(number), "labels", label]
    case .listRepositoryLabels(let owner, let repository, let page):
      try validate(owner: owner, repository: repository)
      try validate(page: page)
      path = ["repos", owner, repository, "labels"]
      query = pagination(page: page)
    case .repositoryLabel(let owner, let repository, let label):
      try validate(owner: owner, repository: repository)
      guard GitHubInputValidation.validLabel(label) else {
        throw GitHubRequestFactoryError.invalidLabel
      }
      path = ["repos", owner, repository, "labels", label]
    case .createRepositoryLabel(let owner, let repository, let payload):
      try validate(owner: owner, repository: repository)
      try validate(label: payload)
      path = ["repos", owner, repository, "labels"]
    case .branchReference(let owner, let repository, let branch):
      try validate(owner: owner, repository: repository)
      guard GitHubInputValidation.validBranch(branch) else {
        throw GitHubRequestFactoryError.invalidBranch
      }
      path =
        ["repos", owner, repository, "git", "ref", "heads"]
        + branch.split(separator: "/").map(String.init)
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.percentEncodedPath = "/" + path.map(percentEncodedPathSegment).joined(separator: "/")
    components.queryItems = query.isEmpty ? nil : query
    return components
  }

  private static func method(for operation: GitHubOperation) -> GitHubHTTPMethod {
    switch operation.kind {
    case .createPullRequest, .createComment, .addIssueLabels, .createRepositoryLabel:
      .post
    case .removeIssueLabel:
      .delete
    default:
      .get
    }
  }

  private static func successStatuses(for kind: GitHubOperationKind) -> Set<Int> {
    switch kind {
    case .createPullRequest, .createComment, .createRepositoryLabel:
      [201]
    case .removeIssueLabel:
      [200]
    default:
      [200]
    }
  }

  private static func body(for operation: GitHubOperation) throws -> Data? {
    let value: [String: Any]
    switch operation {
    case .createPullRequest(_, _, let request):
      value = [
        "base": request.base,
        "body": request.body,
        "draft": false,
        "head": request.head,
        "title": request.title,
      ]
    case .createComment(_, _, _, let body):
      value = ["body": body]
    case .addIssueLabels(_, _, _, let labels):
      value = ["labels": labels]
    case .createRepositoryLabel(_, _, let request):
      value = [
        "color": request.color,
        "description": request.description,
        "name": request.name,
      ]
    default:
      return nil
    }
    guard JSONSerialization.isValidJSONObject(value) else {
      throw GitHubRequestFactoryError.encodingFailed
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private static func validate(owner: String, repository: String) throws {
    guard GitHubInputValidation.validOwner(owner) else {
      throw GitHubRequestFactoryError.invalidOwner
    }
    guard GitHubInputValidation.validRepository(repository) else {
      throw GitHubRequestFactoryError.invalidRepository
    }
  }

  private static func validate(number: Int) throws {
    guard number > 0 else { throw GitHubRequestFactoryError.invalidNumber }
  }

  private static func validate(page: Int) throws {
    guard (1...1_000).contains(page) else {
      throw GitHubRequestFactoryError.invalidPage
    }
  }

  private static func validate(body: String) throws {
    guard !body.isEmpty, body.utf8.count <= 60_000,
      !body.unicodeScalars.contains(where: { $0.value == 0 })
    else {
      throw GitHubRequestFactoryError.invalidBody
    }
  }

  private static func validate(pullRequest: GitHubCreatePullRequest) throws {
    guard !pullRequest.title.isEmpty, pullRequest.title.count <= 256,
      pullRequest.title.utf8.count <= 1_024,
      pullRequest.title == pullRequest.title.trimmingCharacters(in: .whitespacesAndNewlines),
      !pullRequest.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw GitHubRequestFactoryError.invalidTitle
    }
    guard GitHubInputValidation.validHead(pullRequest.head) else {
      throw GitHubRequestFactoryError.invalidHead
    }
    guard GitHubInputValidation.validBranch(pullRequest.base) else {
      throw GitHubRequestFactoryError.invalidBranch
    }
    try validate(body: pullRequest.body)
  }

  private static func validate(label: GitHubCreateLabel) throws {
    guard GitHubInputValidation.validLabel(label.name) else {
      throw GitHubRequestFactoryError.invalidLabel
    }
    guard label.color.utf8.count == 6,
      label.color.utf8.allSatisfy(GitHubInputValidation.isLowercaseHex)
    else {
      throw GitHubRequestFactoryError.invalidColor
    }
    guard label.description.count <= 100,
      label.description.utf8.count <= 400,
      !label.description.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw GitHubRequestFactoryError.invalidDescription
    }
  }

  private static func pagination(page: Int) -> [URLQueryItem] {
    [
      URLQueryItem(name: "per_page", value: "100"),
      URLQueryItem(name: "page", value: String(page)),
    ]
  }

  private static func percentEncodedPathSegment(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }
}

public enum GitHubInputValidation {
  public static func validOwner(_ value: String) -> Bool {
    guard validComponent(value, maximum: 39),
      value.first != "-", value.last != "-"
    else { return false }
    return value.utf8.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 }
  }

  public static func validRepository(_ value: String) -> Bool {
    guard validComponent(value, maximum: 100), value != ".", value != ".." else {
      return false
    }
    return value.utf8.allSatisfy {
      isASCIIAlphaNumeric($0) || [45, 46, 95].contains($0)
    }
  }

  public static func validBranch(_ value: String) -> Bool {
    guard validComponent(value, maximum: 255), value != "@",
      !value.hasPrefix("/"), !value.hasSuffix("/"),
      !value.hasSuffix("."), !value.contains(".."),
      !value.contains("//"), !value.contains("@{")
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.allSatisfy({
        !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
      })
    else { return false }
    let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
    return !value.unicodeScalars.contains(where: forbidden.contains)
  }

  public static func validHead(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 1 { return validBranch(value) }
    guard parts.count == 2 else { return false }
    return validOwner(String(parts[0])) && validBranch(String(parts[1]))
  }

  public static func validLabel(_ value: String) -> Bool {
    validComponent(value, maximum: 50)
  }

  public static func validSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy(isLowercaseHex)
  }

  public static func validGitSHA(_ value: String) -> Bool {
    [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy(isLowercaseHex)
  }

  static func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }

  private static func validComponent(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty
      && value.count <= maximum
      && value.utf8.count <= maximum * 4
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...90).contains(byte)
      || (97...122).contains(byte)
  }
}
