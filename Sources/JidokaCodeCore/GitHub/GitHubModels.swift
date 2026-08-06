import Foundation

public struct GitHubUser: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let login: String

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case login
  }
}

public struct GitHubRepository: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let name: String
  public let fullName: String
  public let defaultBranch: String
  public let owner: GitHubUser

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case name
    case fullName = "full_name"
    case defaultBranch = "default_branch"
    case owner
  }
}

public struct GitHubPullRepository: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let fullName: String

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case fullName = "full_name"
  }
}

public struct GitHubPullReference: Decodable, Equatable, Sendable {
  public let ref: String
  public let sha: String
  public let repository: GitHubPullRepository?

  enum CodingKeys: String, CodingKey {
    case ref
    case sha
    case repository = "repo"
  }
}

public struct GitHubPullRequest: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let number: Int
  public let state: String
  public let draft: Bool
  public let title: String
  public let body: String?
  public let htmlURL: String
  public let user: GitHubUser
  public let head: GitHubPullReference
  public let base: GitHubPullReference

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case number
    case state
    case draft
    case title
    case body
    case htmlURL = "html_url"
    case user
    case head
    case base
  }
}

public struct GitHubLabel: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let name: String
  public let color: String
  public let description: String?

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case name
    case color
    case description
  }
}

public struct GitHubIssuePullMarker: Decodable, Equatable, Sendable {
  public let url: String
}

public struct GitHubIssue: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let number: Int
  public let state: String
  public let title: String
  public let body: String?
  public let user: GitHubUser
  public let labels: [GitHubLabel]
  public let createdAt: String
  public let pullRequest: GitHubIssuePullMarker?

  public var isPullRequest: Bool { pullRequest != nil }

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case number
    case state
    case title
    case body
    case user
    case labels
    case createdAt = "created_at"
    case pullRequest = "pull_request"
  }
}

public struct GitHubComment: Decodable, Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let body: String
  public let user: GitHubUser
  public let createdAt: String
  public let updatedAt: String
  public let htmlURL: String

  enum CodingKeys: String, CodingKey {
    case id
    case nodeID = "node_id"
    case body
    case user
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case htmlURL = "html_url"
  }
}

public struct GitHubGitObject: Decodable, Equatable, Sendable {
  public let sha: String
  public let type: String
  public let url: String
}

public struct GitHubReference: Decodable, Equatable, Sendable {
  public let ref: String
  public let nodeID: String
  public let object: GitHubGitObject

  enum CodingKeys: String, CodingKey {
    case ref
    case nodeID = "node_id"
    case object
  }
}

struct GitHubErrorEnvelope: Decodable, Sendable {
  let message: String?
}
