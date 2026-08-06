import Foundation

public struct IssueRevisionLabel: Equatable, Sendable {
  public let nodeID: String
  public let name: String

  public init(nodeID: String, name: String) {
    self.nodeID = nodeID
    self.name = name
  }
}

public struct IssueRevisionComment: Equatable, Sendable {
  public let id: Int64
  public let nodeID: String
  public let authorID: Int64
  public let authorLogin: String
  public let createdAt: String
  public let updatedAt: String
  public let body: String

  public init(
    id: Int64,
    nodeID: String,
    authorID: Int64,
    authorLogin: String,
    createdAt: String,
    updatedAt: String,
    body: String
  ) {
    self.id = id
    self.nodeID = nodeID
    self.authorID = authorID
    self.authorLogin = authorLogin
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.body = body
  }
}

public struct IssueRevisionLinkedInput: Equatable, Sendable {
  public let canonicalURL: String
  public let nodeID: String
  public let retrievalRevision: String
  public let contentDigest: String

  public init(
    canonicalURL: String,
    nodeID: String,
    retrievalRevision: String,
    contentDigest: String
  ) {
    self.canonicalURL = canonicalURL
    self.nodeID = nodeID
    self.retrievalRevision = retrievalRevision
    self.contentDigest = contentDigest
  }
}

public struct IssueRevisionInput: Equatable, Sendable {
  public let issueNodeID: String
  public let title: String
  public let body: String
  public let authorID: Int64
  public let createdAt: String
  public let labels: [IssueRevisionLabel]
  public let comments: [IssueRevisionComment]
  public let linkedInputs: [IssueRevisionLinkedInput]

  public init(
    issueNodeID: String,
    title: String,
    body: String,
    authorID: Int64,
    createdAt: String,
    labels: [IssueRevisionLabel],
    comments: [IssueRevisionComment],
    linkedInputs: [IssueRevisionLinkedInput]
  ) {
    self.issueNodeID = issueNodeID
    self.title = title
    self.body = body
    self.authorID = authorID
    self.createdAt = createdAt
    self.labels = labels
    self.comments = comments
    self.linkedInputs = linkedInputs
  }
}

public struct IssueRevision: Equatable, Sendable {
  public let sha256: String
  public let canonicalJSON: Data
  public let excludedCommentIDs: Set<Int64>
}

public struct BaseRevision: Equatable, Sendable {
  public let branch: String
  public let sha: String
  public let sha256: String

  public init(branch: String, sha: String) throws {
    guard GitHubInputValidation.validBranch(branch),
      GitHubInputValidation.validGitSHA(sha)
    else {
      throw IssueRevisionError.invalidBaseRevision
    }
    self.branch = branch
    self.sha = sha
    let encoded = JCS.encode(
      .object([
        ("branch", .string(branch)),
        ("sha", .string(sha)),
      ])
    )
    sha256 = GitHubMarkerCodec.sha256(encoded)
  }
}

public enum IssueRevisionError: Error, Equatable, Sendable {
  case invalidIdentity
  case invalidTimestamp
  case invalidLabel
  case invalidComment
  case invalidLinkedInput
  case invalidBaseRevision
  case invalidContent
}

public enum IssueRevisionBuilder {
  public static func make(
    input: IssueRevisionInput,
    markerExpectations: [GitHubMarkerExpectation] = []
  ) throws -> IssueRevision {
    guard validIdentity(input.issueNodeID), input.authorID > 0 else {
      throw IssueRevisionError.invalidIdentity
    }
    guard input.title.utf8.count <= 1_024,
      input.body.utf8.count <= 100_000,
      input.labels.count <= 1_000,
      input.comments.count <= 100_000,
      input.linkedInputs.count <= 1_000,
      input.comments.allSatisfy({ $0.body.utf8.count <= 100_000 })
    else {
      throw IssueRevisionError.invalidContent
    }
    guard validTimestamp(input.createdAt) else {
      throw IssueRevisionError.invalidTimestamp
    }
    guard Set(input.comments.map(\.id)).count == input.comments.count else {
      throw IssueRevisionError.invalidComment
    }
    guard Set(input.labels.map(\.nodeID)).count == input.labels.count else {
      throw IssueRevisionError.invalidLabel
    }
    let linkedKeys = input.linkedInputs.map { "\($0.canonicalURL)\u{0}\($0.nodeID)" }
    guard Set(linkedKeys).count == linkedKeys.count else {
      throw IssueRevisionError.invalidLinkedInput
    }

    let markerComments = input.comments.map {
      GitHubMarkerComment(id: $0.id, authorID: $0.authorID, body: $0.body)
    }
    let excluded = GitHubMarkerAttributor.attributedCommentIDs(
      comments: markerComments,
      expectations: markerExpectations
    )
    let labels = try input.labels
      .filter { !isWorkflowLabel($0.name) }
      .map { label -> JCSValue in
        guard validIdentity(label.nodeID), validText(label.name, maximum: 50) else {
          throw IssueRevisionError.invalidLabel
        }
        return .object([
          ("name", .string(label.name)),
          ("node_id", .string(label.nodeID)),
        ])
      }
    let sortedLabels = zip(input.labels.filter { !isWorkflowLabel($0.name) }, labels)
      .sorted { lhs, rhs in
        if lhs.0.nodeID != rhs.0.nodeID {
          return unicodeScalarLess(lhs.0.nodeID, rhs.0.nodeID)
        }
        return unicodeScalarLess(lhs.0.name, rhs.0.name)
      }
      .map(\.1)

    let comments = try input.comments
      .filter { !excluded.contains($0.id) }
      .sorted { $0.id < $1.id }
      .map { comment -> JCSValue in
        guard comment.id > 0, comment.authorID > 0,
          validIdentity(comment.nodeID),
          validText(comment.authorLogin, maximum: 100),
          validTimestamp(comment.createdAt), validTimestamp(comment.updatedAt)
        else {
          throw IssueRevisionError.invalidComment
        }
        return .object([
          ("author_id", .integer(comment.authorID)),
          ("author_login", .string(comment.authorLogin)),
          ("body", .string(canonicalString(comment.body))),
          ("created_at", .string(comment.createdAt)),
          ("id", .integer(comment.id)),
          ("node_id", .string(comment.nodeID)),
          ("updated_at", .string(comment.updatedAt)),
        ])
      }

    let linked = try input.linkedInputs
      .sorted { lhs, rhs in
        if lhs.canonicalURL != rhs.canonicalURL {
          return unicodeScalarLess(lhs.canonicalURL, rhs.canonicalURL)
        }
        return unicodeScalarLess(lhs.nodeID, rhs.nodeID)
      }
      .map { linked -> JCSValue in
        guard validCanonicalURL(linked.canonicalURL),
          validIdentity(linked.nodeID),
          validText(linked.retrievalRevision, maximum: 256),
          GitHubInputValidation.validSHA256(linked.contentDigest)
        else {
          throw IssueRevisionError.invalidLinkedInput
        }
        return .object([
          ("canonical_url", .string(linked.canonicalURL)),
          ("content_digest", .string(linked.contentDigest)),
          ("node_id", .string(linked.nodeID)),
          ("retrieval_revision", .string(linked.retrievalRevision)),
        ])
      }

    let value = JCSValue.object([
      ("author_id", .integer(input.authorID)),
      ("body", .string(canonicalString(input.body))),
      ("comments", .array(comments)),
      ("created_at", .string(input.createdAt)),
      ("domain_labels", .array(sortedLabels)),
      ("issue_node_id", .string(input.issueNodeID)),
      ("linked_inputs", .array(linked)),
      ("title", .string(canonicalString(input.title))),
    ])
    let canonicalJSON = JCS.encode(value)
    return IssueRevision(
      sha256: GitHubMarkerCodec.sha256(canonicalJSON),
      canonicalJSON: canonicalJSON,
      excludedCommentIDs: excluded
    )
  }

  private static func canonicalString(_ value: String) -> String {
    String(data: GitHubMarkerCodec.canonicalDocumentBytes(value), encoding: .utf8)!
  }

  private static func isWorkflowLabel(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
  }

  private static func validIdentity(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || [43, 45, 46, 47, 61, 95].contains(byte)
      }
  }

  private static func validTimestamp(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 20 else { return false }
    let separators: [Int: UInt8] = [
      4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 90,
    ]
    for (index, byte) in bytes.enumerated() {
      if let separator = separators[index] {
        guard byte == separator else { return false }
      } else if !(48...57).contains(byte) {
        return false
      }
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }

  private static func validText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.count <= maximum
      && value.utf8.count <= maximum * 4
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validCanonicalURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
      url.absoluteString == value,
      url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.fragment == nil
    else {
      return false
    }
    return true
  }

  private static func unicodeScalarLess(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.unicodeScalars.map(\.value)
    let right = rhs.unicodeScalars.map(\.value)
    for (a, b) in zip(left, right) where a != b { return a < b }
    return left.count < right.count
  }
}

private indirect enum JCSValue {
  case string(String)
  case integer(Int64)
  case array([JCSValue])
  case object([(String, JCSValue)])
}

private enum JCS {
  static func encode(_ value: JCSValue) -> Data {
    Data(render(value).utf8)
  }

  private static func render(_ value: JCSValue) -> String {
    switch value {
    case .string(let string):
      return quote(string)
    case .integer(let integer):
      return String(integer)
    case .array(let values):
      return "[" + values.map(render).joined(separator: ",") + "]"
    case .object(let entries):
      let sorted = entries.sorted { unicodeScalarLess($0.0, $1.0) }
      return "{"
        + sorted.map { quote($0.0) + ":" + render($0.1) }
        .joined(separator: ",") + "}"
    }
  }

  private static func quote(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0A: result += "\\n"
      case 0x0C: result += "\\f"
      case 0x0D: result += "\\r"
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x00...0x1F:
        result += String(format: "\\u%04x", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    result += "\""
    return result
  }

  private static func unicodeScalarLess(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.unicodeScalars.map(\.value)
    let right = rhs.unicodeScalars.map(\.value)
    for (a, b) in zip(left, right) where a != b { return a < b }
    return left.count < right.count
  }
}
