import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Closed GitHub REST request inventory")
struct GitHubRequestTests {
  @Test("every allowed operation has an exact method, host, and operation id")
  func inventorySnapshot() throws {
    let operations = fixtureOperations()
    #expect(Set(operations.map(\.kind)) == Set(GitHubOperationKind.allCases))
    let expectedIDs: [GitHubOperationKind: String] = [
      .authenticatedIdentity: "users/get-authenticated",
      .repository: "repos/get",
      .listPullRequests: "pulls/list",
      .pullRequest: "pulls/get",
      .createPullRequest: "pulls/create",
      .listIssues: "issues/list-for-repo",
      .issue: "issues/get",
      .listComments: "issues/list-comments",
      .createComment: "issues/create-comment",
      .listIssueLabels: "issues/list-labels-on-issue",
      .addIssueLabels: "issues/add-labels",
      .removeIssueLabel: "issues/remove-label",
      .listRepositoryLabels: "issues/list-labels-for-repo",
      .repositoryLabel: "issues/get-label",
      .createRepositoryLabel: "issues/create-label",
      .branchReference: "git/get-ref",
    ]

    for operation in operations {
      let descriptor = try GitHubRequestFactory.make(operation)
      let request = descriptor.request
      #expect(request.url?.scheme == "https")
      #expect(request.url?.host == "api.github.com")
      #expect(request.url?.user == nil)
      #expect(request.url?.password == nil)
      #expect(descriptor.operationID == expectedIDs[operation.kind])
      #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
      #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.timeoutInterval == 30)
      let expectedMethod: String =
        switch operation.kind {
        case .createPullRequest, .createComment, .addIssueLabels, .createRepositoryLabel:
          "POST"
        case .removeIssueLabel:
          "DELETE"
        default:
          "GET"
        }
      #expect(request.httpMethod == expectedMethod)
      let queryNames = Set(
        URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
          .queryItems?.map(\.name) ?? []
      )
      #expect(queryNames.isSubset(of: ["state", "per_page", "page", "head", "base"]))
      let path = request.url?.path.lowercased() ?? ""
      for forbiddenPath in ["/merge", "/releases", "/tags"] {
        #expect(!path.contains(forbiddenPath))
      }
    }

    let forbidden = ["merge", "auto", "close", "release", "tag", "delete"]
    for name in GitHubOperationKind.allCases.map(\.rawValue) {
      #expect(!forbidden.contains(where: name.lowercased().contains))
    }
  }

  @Test("query and body allowlists are exact")
  func exactShapes() throws {
    let pulls = try GitHubRequestFactory.make(
      .listPullRequests(
        owner: "owner",
        repository: "repo",
        page: 7,
        head: "owner:agent/topic",
        base: "main"
      )
    ).request
    #expect(pulls.httpMethod == "GET")
    #expect(pulls.url?.path == "/repos/owner/repo/pulls")
    #expect(
      URLComponents(url: try #require(pulls.url), resolvingAgainstBaseURL: false)?.queryItems
        == [
          URLQueryItem(name: "state", value: "open"),
          URLQueryItem(name: "per_page", value: "100"),
          URLQueryItem(name: "page", value: "7"),
          URLQueryItem(name: "head", value: "owner:agent/topic"),
          URLQueryItem(name: "base", value: "main"),
        ])

    let create = try GitHubRequestFactory.make(
      .createPullRequest(
        owner: "owner",
        repository: "repo",
        request: GitHubCreatePullRequest(
          title: "Implement bounded work",
          head: "agent/issue-1-work",
          base: "main",
          body: "evidence\n"
        )
      )
    ).request
    #expect(create.httpMethod == "POST")
    #expect(create.url?.path == "/repos/owner/repo/pulls")
    #expect(create.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let httpBody = try #require(create.httpBody)
    let object = try JSONSerialization.jsonObject(with: httpBody)
    let body = try #require(object as? [String: Any])
    #expect(body["draft"] as? Bool == false)
    #expect(Set(body.keys) == Set(["base", "body", "draft", "head", "title"]))

    let remove = try GitHubRequestFactory.make(
      .removeIssueLabel(
        owner: "owner",
        repository: "repo",
        number: 3,
        label: "agent:plan/review"
      )
    ).request
    #expect(remove.httpMethod == "DELETE")
    let removeURL = try #require(remove.url)
    let removeComponents = try #require(
      URLComponents(url: removeURL, resolvingAgainstBaseURL: false)
    )
    #expect(removeComponents.percentEncodedPath.hasSuffix("agent%3Aplan%2Freview"))

    let reference = try GitHubRequestFactory.make(
      .branchReference(owner: "owner", repository: "repo", branch: "agent/topic")
    ).request
    #expect(reference.url?.path == "/repos/owner/repo/git/ref/heads/agent/topic")
  }

  @Test("untrusted path, query, and payload values fail closed")
  func invalidInputs() {
    let invalid: [GitHubOperation] = [
      .repository(owner: "bad/owner", repository: "repo"),
      .repository(owner: "owner", repository: ".."),
      .listIssues(owner: "owner", repository: "repo", page: 0),
      .listIssues(owner: "owner", repository: "repo", page: 1_001),
      .issue(owner: "owner", repository: "repo", number: 0),
      .branchReference(owner: "owner", repository: "repo", branch: "feature/.hidden"),
      .listPullRequests(
        owner: "owner", repository: "repo", page: 1,
        head: "other:bad..branch", base: "main"),
      .createComment(owner: "owner", repository: "repo", number: 1, body: ""),
      .addIssueLabels(owner: "owner", repository: "repo", number: 1, labels: []),
      .addIssueLabels(
        owner: "owner",
        repository: "repo",
        number: 1,
        labels: ["a" + String(repeating: "\u{301}", count: 1_000)]
      ),
      .createRepositoryLabel(
        owner: "owner",
        repository: "repo",
        request: GitHubCreateLabel(name: "agent:ready", color: "ZZZZZZ", description: "")
      ),
    ]
    for operation in invalid {
      #expect(throws: GitHubRequestFactoryError.self) {
        _ = try GitHubRequestFactory.make(operation)
      }
    }
  }
}

private func fixtureOperations() -> [GitHubOperation] {
  [
    .authenticatedIdentity,
    .repository(owner: "owner", repository: "repo"),
    .listPullRequests(
      owner: "owner", repository: "repo", page: 1, head: nil, base: nil),
    .pullRequest(owner: "owner", repository: "repo", number: 1),
    .createPullRequest(
      owner: "owner",
      repository: "repo",
      request: GitHubCreatePullRequest(
        title: "Title", head: "agent/issue-1-work", base: "main", body: "Body")),
    .listIssues(owner: "owner", repository: "repo", page: 1),
    .issue(owner: "owner", repository: "repo", number: 1),
    .listComments(owner: "owner", repository: "repo", number: 1, page: 1),
    .createComment(owner: "owner", repository: "repo", number: 1, body: "Body"),
    .listIssueLabels(owner: "owner", repository: "repo", number: 1, page: 1),
    .addIssueLabels(owner: "owner", repository: "repo", number: 1, labels: ["agent:ready"]),
    .removeIssueLabel(owner: "owner", repository: "repo", number: 1, label: "agent:wip"),
    .listRepositoryLabels(owner: "owner", repository: "repo", page: 1),
    .repositoryLabel(owner: "owner", repository: "repo", label: "agent:ready"),
    .createRepositoryLabel(
      owner: "owner",
      repository: "repo",
      request: GitHubCreateLabel(
        name: "agent:ready", color: "abcdef", description: "Ready")),
    .branchReference(owner: "owner", repository: "repo", branch: "main"),
  ]
}
