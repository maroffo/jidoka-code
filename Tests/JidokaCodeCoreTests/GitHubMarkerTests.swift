import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Byte-exact GitHub markers")
struct GitHubMarkerTests {
  @Test("canonical bytes lock line endings, final LF, and digest")
  func canonicalization() {
    let canonical = GitHubMarkerCodec.canonicalDocumentBytes("alpha\r\nbeta\r\n\n")
    #expect(String(data: canonical, encoding: .utf8) == "alpha\nbeta\n")
    #expect(
      GitHubMarkerCodec.sha256(canonical)
        == "e49c81e2d2f84e259d40e2fb8192f3bcd198b355184845d76d8f58807d0d78ee"
    )
    #expect(
      GitHubMarkerCodec.canonicalDocumentBytes("").map { $0 } == [0x0A]
    )

    let composed = GitHubMarkerCodec.canonicalDocumentBytes("é")
    let decomposed = GitHubMarkerCodec.canonicalDocumentBytes("e\u{301}")
    #expect(composed != decomposed)
    #expect(GitHubMarkerCodec.sha256(composed) != GitHubMarkerCodec.sha256(decomposed))
    #expect(
      GitHubMarkerCodec.canonicalDocumentBytes("value  \n")
        == Data("value  \n".utf8)
    )
  }

  @Test("55000 and 55001 byte boundaries follow the locked split algorithm")
  func sizeBoundaries() throws {
    let onePartDocument = String(repeating: "a", count: 54_999)
    let onePart = try GitHubMarkerCodec.build(
      document: onePartDocument,
      identity: markerIdentity()
    )
    #expect(onePart.count == 1)
    #expect(try GitHubMarkerCodec.parse(onePart[0].body).payload.count == 55_000)

    let twoPartDocument = String(repeating: "a", count: 55_000)
    let twoParts = try GitHubMarkerCodec.build(
      document: twoPartDocument,
      identity: markerIdentity()
    )
    #expect(twoParts.count == 2)
    #expect(try GitHubMarkerCodec.parse(twoParts[0].body).payload.count == 55_000)
    #expect(try GitHubMarkerCodec.parse(twoParts[1].body).payload == Data([0x0A]))
    #expect(twoParts.allSatisfy { $0.body.utf8.count <= 56_025 })
  }

  @Test("oversized logical documents fail before multipart allocation")
  func oversizedDocument() {
    let oversized = String(
      repeating: "a",
      count: GitHubMarkerCodec.maximumDocumentBytes + 1
    )
    #expect(throws: GitHubMarkerError.documentTooLarge) {
      _ = try GitHubMarkerCodec.build(
        document: oversized,
        identity: markerIdentity()
      )
    }
  }

  @Test("multipart preserves UTF-8 boundaries, hostile HTML, and marker-like payload")
  func multipartRoundTrip() throws {
    let document =
      String(repeating: "é", count: 40_000)
      + "\n<!-- jidoka-code:v1 kind=spoof -->\n--> trailing"
    let parts = try GitHubMarkerCodec.build(document: document, identity: markerIdentity())
    #expect(parts.count > 1)
    let comments = parts.enumerated().map { index, part in
      GitHubMarkerComment(id: Int64(index + 1), authorID: 42, body: part.body)
    }
    let rebuilt = try GitHubMarkerCodec.reconstruct(
      comments: comments,
      expectation: markerExpectation(parts: parts)
    )
    #expect(rebuilt == GitHubMarkerCodec.canonicalDocumentBytes(document))
  }

  @Test("missing, duplicate, reordered, mutated, and wrong-author parts fail")
  func invalidMultipart() throws {
    let parts = try GitHubMarkerCodec.build(
      document: String(repeating: "x", count: 60_000),
      identity: markerIdentity()
    )
    let comments = parts.enumerated().map { index, part in
      GitHubMarkerComment(id: Int64(index + 1), authorID: 42, body: part.body)
    }
    let expectation = markerExpectation(parts: parts)

    #expect(throws: GitHubMarkerError.missingPart) {
      _ = try GitHubMarkerCodec.reconstruct(
        comments: Array(comments.dropLast()),
        expectation: expectation
      )
    }
    #expect(throws: GitHubMarkerError.duplicatePart) {
      _ = try GitHubMarkerCodec.reconstruct(
        comments: [comments[0], comments[0]],
        expectation: expectation
      )
    }
    #expect(throws: GitHubMarkerError.reorderedPart) {
      _ = try GitHubMarkerCodec.reconstruct(
        comments: comments.reversed(),
        expectation: expectation
      )
    }
    var mutated = comments
    mutated[0] = GitHubMarkerComment(
      id: mutated[0].id,
      authorID: mutated[0].authorID,
      body: mutated[0].body + "mutation"
    )
    #expect(throws: GitHubMarkerError.payloadDigestMismatch) {
      _ = try GitHubMarkerCodec.reconstruct(
        comments: mutated,
        expectation: expectation
      )
    }
    var wrongAuthor = comments
    wrongAuthor[0] = GitHubMarkerComment(
      id: wrongAuthor[0].id,
      authorID: 99,
      body: wrongAuthor[0].body
    )
    #expect(throws: GitHubMarkerError.attributionMismatch) {
      _ = try GitHubMarkerCodec.reconstruct(
        comments: wrongAuthor,
        expectation: expectation
      )
    }
  }

  @Test("only a full persisted expectation attributes marker comments")
  func attributionRequiresIntent() throws {
    let parts = try GitHubMarkerCodec.build(
      document: String(repeating: "plan\n", count: 20_000),
      identity: markerIdentity()
    )
    let comments = parts.enumerated().map { index, part in
      GitHubMarkerComment(id: Int64(index + 10), authorID: 42, body: part.body)
    }
    #expect(
      GitHubMarkerAttributor.attributedCommentIDs(
        comments: comments,
        expectations: []
      ).isEmpty
    )
    let wrong = GitHubMarkerExpectation(
      identity: GitHubMarkerIdentity(
        kind: .plan,
        repositoryNodeID: "R_repo",
        objectNodeID: "I_issue",
        revision: "revision",
        idempotencyKey: String(repeating: "b", count: 64)
      ),
      authorID: 42,
      documentSHA256: try #require(parts.first).documentSHA256
    )
    #expect(
      GitHubMarkerAttributor.attributedCommentIDs(
        comments: comments,
        expectations: [wrong]
      ).isEmpty
    )
    #expect(
      GitHubMarkerAttributor.attributedCommentIDs(
        comments: comments,
        expectations: [markerExpectation(parts: parts)]
      ) == Set(comments.map(\.id))
    )
  }

  @Test("deterministic fuzz preserves every canonical payload byte")
  func deterministicFuzz() throws {
    var random = MarkerRandom(seed: 0x1234_5678)
    let fragments = ["a", "é", "e\u{301}", "\r", "\n", "\r\n", "  ", "<!--x-->"]
    for iteration in 0..<200 {
      var document = ""
      for _ in 0..<(1 + random.next(upperBound: 400)) {
        document += fragments[random.next(upperBound: fragments.count)]
      }
      let parts = try GitHubMarkerCodec.build(
        document: document,
        identity: markerIdentity(keySeed: iteration)
      )
      let comments = parts.enumerated().map { index, part in
        GitHubMarkerComment(id: Int64(index + 1), authorID: 42, body: part.body)
      }
      let rebuilt = try GitHubMarkerCodec.reconstruct(
        comments: comments,
        expectation: markerExpectation(parts: parts)
      )
      #expect(rebuilt == GitHubMarkerCodec.canonicalDocumentBytes(document))
    }
  }
}

private func markerIdentity(keySeed: Int = 0) -> GitHubMarkerIdentity {
  let key = GitHubMarkerCodec.sha256(Data("key-\(keySeed)".utf8))
  return GitHubMarkerIdentity(
    kind: .plan,
    repositoryNodeID: "R_repo",
    objectNodeID: "I_issue",
    revision: "revision",
    idempotencyKey: key
  )
}

private func markerExpectation(parts: [GitHubMarkerPart]) -> GitHubMarkerExpectation {
  GitHubMarkerExpectation(
    identity: parts[0].identity,
    authorID: 42,
    documentSHA256: parts[0].documentSHA256
  )
}

private struct MarkerRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next(upperBound: Int) -> Int {
    state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    return Int(state % UInt64(upperBound))
  }
}
