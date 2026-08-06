import CryptoKit
import Foundation

public enum GitHubMarkerKind: String, CaseIterable, Codable, Sendable {
  case review
  case triage
  case claim
  case resume
  case plan
  case link
  case blocked
}

public struct GitHubMarkerIdentity: Equatable, Sendable {
  public let kind: GitHubMarkerKind
  public let repositoryNodeID: String
  public let objectNodeID: String
  public let revision: String
  public let idempotencyKey: String

  public init(
    kind: GitHubMarkerKind,
    repositoryNodeID: String,
    objectNodeID: String,
    revision: String,
    idempotencyKey: String
  ) {
    self.kind = kind
    self.repositoryNodeID = repositoryNodeID
    self.objectNodeID = objectNodeID
    self.revision = revision
    self.idempotencyKey = idempotencyKey
  }
}

public struct GitHubMarkerPart: Equatable, Sendable {
  public let identity: GitHubMarkerIdentity
  public let payloadSHA256: String
  public let documentSHA256: String
  public let index: Int
  public let count: Int
  public let body: String
}

public struct ParsedGitHubMarker: Equatable, Sendable {
  public let identity: GitHubMarkerIdentity
  public let payloadSHA256: String
  public let documentSHA256: String
  public let index: Int
  public let count: Int
  public let payload: Data
}

public struct GitHubMarkerComment: Equatable, Sendable {
  public let id: Int64
  public let authorID: Int64
  public let body: String

  public init(id: Int64, authorID: Int64, body: String) {
    self.id = id
    self.authorID = authorID
    self.body = body
  }
}

public struct GitHubMarkerExpectation: Equatable, Sendable {
  public let identity: GitHubMarkerIdentity
  public let authorID: Int64
  public let documentSHA256: String

  public init(
    identity: GitHubMarkerIdentity,
    authorID: Int64,
    documentSHA256: String
  ) {
    self.identity = identity
    self.authorID = authorID
    self.documentSHA256 = documentSHA256
  }
}

public enum GitHubMarkerError: Error, Equatable, Sendable {
  case invalidIdentity
  case invalidDocument
  case documentTooLarge
  case tooManyParts
  case invalidUTF8Boundary
  case markerTooLarge
  case commentTooLarge
  case malformedMarker
  case payloadDigestMismatch
  case documentDigestMismatch
  case attributionMismatch
  case missingPart
  case duplicatePart
  case reorderedPart
}

public enum GitHubMarkerCodec {
  public static let sliceByteLimit = 55_000
  public static let markerByteLimit = 1_024
  public static let commentByteLimit = 56_025
  public static let maximumParts = 9_999
  public static let maximumDocumentBytes = 10 * 1_024 * 1_024

  public static func canonicalDocumentBytes(_ document: String) -> Data {
    let source = Array(document.utf8)
    var canonical: [UInt8] = []
    canonical.reserveCapacity(source.count + 1)
    var index = 0
    while index < source.count {
      if source[index] == 0x0D {
        canonical.append(0x0A)
        if index + 1 < source.count, source[index + 1] == 0x0A {
          index += 1
        }
      } else {
        canonical.append(source[index])
      }
      index += 1
    }
    while canonical.last == 0x0A {
      canonical.removeLast()
    }
    canonical.append(0x0A)
    return Data(canonical)
  }

  public static func build(
    document: String,
    identity: GitHubMarkerIdentity
  ) throws -> [GitHubMarkerPart] {
    guard valid(identity: identity) else { throw GitHubMarkerError.invalidIdentity }
    guard document.utf8.count <= maximumDocumentBytes else {
      throw GitHubMarkerError.documentTooLarge
    }
    let canonical = canonicalDocumentBytes(document)
    guard canonical.count <= maximumDocumentBytes else {
      throw GitHubMarkerError.documentTooLarge
    }
    guard String(data: canonical, encoding: .utf8) != nil else {
      throw GitHubMarkerError.invalidDocument
    }
    let slices = try split(canonical)
    guard slices.count <= maximumParts else { throw GitHubMarkerError.tooManyParts }
    let documentDigest = sha256(canonical)

    return try slices.enumerated().map { offset, slice in
      let payloadDigest = sha256(slice)
      let marker = markerLine(
        identity: identity,
        payloadSHA256: payloadDigest,
        documentSHA256: documentDigest,
        index: offset + 1,
        count: slices.count
      )
      guard marker.utf8.count <= markerByteLimit else {
        throw GitHubMarkerError.markerTooLarge
      }
      guard let payload = String(data: slice, encoding: .utf8) else {
        throw GitHubMarkerError.invalidUTF8Boundary
      }
      let body = marker + "\n" + payload
      guard body.utf8.count <= commentByteLimit else {
        throw GitHubMarkerError.commentTooLarge
      }
      return GitHubMarkerPart(
        identity: identity,
        payloadSHA256: payloadDigest,
        documentSHA256: documentDigest,
        index: offset + 1,
        count: slices.count,
        body: body
      )
    }
  }

  public static func parse(_ body: String) throws -> ParsedGitHubMarker {
    let bytes = Data(body.utf8)
    guard let newline = bytes.firstIndex(of: 0x0A), newline > bytes.startIndex else {
      throw GitHubMarkerError.malformedMarker
    }
    let markerBytes = bytes[bytes.startIndex..<newline]
    guard markerBytes.count <= markerByteLimit,
      markerBytes.allSatisfy({ $0 < 0x80 }),
      let marker = String(data: markerBytes, encoding: .ascii)
    else {
      throw GitHubMarkerError.malformedMarker
    }
    let prefix = "<!-- jidoka-code:v1 "
    let suffix = " -->"
    guard marker.hasPrefix(prefix), marker.hasSuffix(suffix) else {
      throw GitHubMarkerError.malformedMarker
    }
    let content = marker.dropFirst(prefix.count).dropLast(suffix.count)
    let tokens = content.split(separator: " ", omittingEmptySubsequences: false)
    let names = ["kind", "repo", "object", "revision", "key", "payload", "document", "part"]
    guard tokens.count == names.count else { throw GitHubMarkerError.malformedMarker }
    var values: [String: String] = [:]
    for (expectedName, token) in zip(names, tokens) {
      guard let separator = token.firstIndex(of: "="),
        token[..<separator] == Substring(expectedName),
        separator < token.index(before: token.endIndex)
      else {
        throw GitHubMarkerError.malformedMarker
      }
      values[expectedName] = String(token[token.index(after: separator)...])
    }
    guard let kindValue = values["kind"],
      let kind = GitHubMarkerKind(rawValue: kindValue),
      let repositoryNodeID = values["repo"],
      let objectNodeID = values["object"],
      let revision = values["revision"],
      let key = values["key"],
      let payloadDigest = values["payload"],
      let documentDigest = values["document"],
      let partValue = values["part"]
    else {
      throw GitHubMarkerError.malformedMarker
    }
    let partComponents = partValue.split(separator: "/", omittingEmptySubsequences: false)
    guard partComponents.count == 2,
      let partIndex = Int(partComponents[0]),
      let partCount = Int(partComponents[1]),
      (1...partCount).contains(partIndex),
      (1...maximumParts).contains(partCount),
      GitHubInputValidation.validSHA256(payloadDigest),
      GitHubInputValidation.validSHA256(documentDigest)
    else {
      throw GitHubMarkerError.malformedMarker
    }
    let identity = GitHubMarkerIdentity(
      kind: kind,
      repositoryNodeID: repositoryNodeID,
      objectNodeID: objectNodeID,
      revision: revision,
      idempotencyKey: key
    )
    guard valid(identity: identity) else { throw GitHubMarkerError.invalidIdentity }
    let payloadStart = bytes.index(after: newline)
    let payload = Data(bytes[payloadStart..<bytes.endIndex])
    guard sha256(payload) == payloadDigest else {
      throw GitHubMarkerError.payloadDigestMismatch
    }
    return ParsedGitHubMarker(
      identity: identity,
      payloadSHA256: payloadDigest,
      documentSHA256: documentDigest,
      index: partIndex,
      count: partCount,
      payload: payload
    )
  }

  public static func reconstruct(
    comments: [GitHubMarkerComment],
    expectation: GitHubMarkerExpectation
  ) throws -> Data {
    guard !comments.isEmpty,
      GitHubInputValidation.validSHA256(expectation.documentSHA256)
    else {
      throw GitHubMarkerError.missingPart
    }
    var document = Data()
    var expectedCount: Int?
    var seen: Set<Int> = []

    for (offset, comment) in comments.enumerated() {
      guard comment.authorID == expectation.authorID else {
        throw GitHubMarkerError.attributionMismatch
      }
      let parsed = try parse(comment.body)
      guard parsed.identity == expectation.identity,
        parsed.documentSHA256 == expectation.documentSHA256
      else {
        throw GitHubMarkerError.attributionMismatch
      }
      if let expectedCount, expectedCount != parsed.count {
        throw GitHubMarkerError.attributionMismatch
      }
      expectedCount = parsed.count
      guard seen.insert(parsed.index).inserted else {
        throw GitHubMarkerError.duplicatePart
      }
      guard parsed.index == offset + 1 else {
        throw GitHubMarkerError.reorderedPart
      }
      document.append(parsed.payload)
    }

    guard expectedCount == comments.count else { throw GitHubMarkerError.missingPart }
    guard sha256(document) == expectation.documentSHA256 else {
      throw GitHubMarkerError.documentDigestMismatch
    }
    return document
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func split(_ document: Data) throws -> [Data] {
    let bytes = Array(document)
    var slices: [Data] = []
    var start = 0
    while start < bytes.count {
      let limit = min(start + sliceByteLimit, bytes.count)
      let end: Int
      if limit == bytes.count {
        end = bytes.count
      } else if let newlineEnd = stride(from: limit, through: start + 1, by: -1)
        .first(where: { bytes[$0 - 1] == 0x0A })
      {
        end = newlineEnd
      } else {
        var boundary = limit
        while boundary > start, bytes[boundary] & 0xC0 == 0x80 {
          boundary -= 1
        }
        guard boundary > start else { throw GitHubMarkerError.invalidUTF8Boundary }
        end = boundary
      }
      slices.append(Data(bytes[start..<end]))
      guard slices.count <= maximumParts else { throw GitHubMarkerError.tooManyParts }
      start = end
    }
    return slices
  }

  private static func markerLine(
    identity: GitHubMarkerIdentity,
    payloadSHA256: String,
    documentSHA256: String,
    index: Int,
    count: Int
  ) -> String {
    "<!-- jidoka-code:v1 kind=\(identity.kind.rawValue) repo=\(identity.repositoryNodeID) object=\(identity.objectNodeID) revision=\(identity.revision) key=\(identity.idempotencyKey) payload=\(payloadSHA256) document=\(documentSHA256) part=\(index)/\(count) -->"
  }

  private static func valid(identity: GitHubMarkerIdentity) -> Bool {
    validToken(identity.repositoryNodeID, maximum: 256)
      && validToken(identity.objectNodeID, maximum: 256)
      && validToken(identity.revision, maximum: 256)
      && GitHubInputValidation.validSHA256(identity.idempotencyKey)
  }

  private static func validToken(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || [43, 45, 46, 47, 58, 61, 95].contains(byte)
      }
  }
}

public enum GitHubMarkerAttributor {
  public static func attributedCommentIDs(
    comments: [GitHubMarkerComment],
    expectations: [GitHubMarkerExpectation]
  ) -> Set<Int64> {
    var attributed: Set<Int64> = []
    for expectation in expectations {
      let candidates = comments.filter { comment in
        guard comment.authorID == expectation.authorID,
          let parsed = try? GitHubMarkerCodec.parse(comment.body)
        else {
          return false
        }
        return parsed.identity == expectation.identity
          && parsed.documentSHA256 == expectation.documentSHA256
      }
      guard
        (try? GitHubMarkerCodec.reconstruct(
          comments: candidates,
          expectation: expectation
        )) != nil
      else {
        continue
      }
      attributed.formUnion(candidates.map(\.id))
    }
    return attributed
  }
}
