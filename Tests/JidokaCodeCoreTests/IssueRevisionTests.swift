import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Issue and base revision")
struct IssueRevisionTests {
  @Test("JCS golden vector excludes only a fully attributed app marker")
  func goldenVector() throws {
    let fixture = try issueRevisionFixture()
    let revision = try IssueRevisionBuilder.make(
      input: fixture.input,
      markerExpectations: [fixture.expectation]
    )
    let expected = """
      {"author_id":1,"body":"Body\\n","comments":[{"author_id":2,"author_login":"human","body":"Human comment\\n","created_at":"2026-08-06T00:01:00Z","id":2,"node_id":"C_human","updated_at":"2026-08-06T00:01:00Z"}],"created_at":"2026-08-06T00:00:00Z","domain_labels":[{"name":"bug","node_id":"L_bug"}],"issue_node_id":"I_issue","linked_inputs":[{"canonical_url":"https://example.com/spec","content_digest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","node_id":"LI_spec","retrieval_revision":"r1"}],"title":"Title\\n"}
      """
    #expect(revision.canonicalJSON == Data(expected.utf8))
    #expect(
      revision.sha256
        == "cbf4e4271616a27cceb97bee2cd13da1382b5a9f91e97672143d859a0021f21f"
    )
    #expect(revision.excludedCommentIDs == Set([1]))
  }

  @Test("workflow labels and attributed markers are revision-stable")
  func appEffectsAreStable() throws {
    let fixture = try issueRevisionFixture()
    let baseline = try IssueRevisionBuilder.make(
      input: fixture.input,
      markerExpectations: [fixture.expectation]
    )
    var labels = fixture.input.labels
    labels.append(IssueRevisionLabel(nodeID: "L_agent_ready", name: "agent:ready"))
    labels.append(IssueRevisionLabel(nodeID: "L_approved", name: "plan:approved"))
    let withWorkflowLabels = replacing(fixture.input, labels: labels)
    let stable = try IssueRevisionBuilder.make(
      input: withWorkflowLabels,
      markerExpectations: [fixture.expectation]
    )
    #expect(stable.sha256 == baseline.sha256)

    let withoutIntent = try IssueRevisionBuilder.make(
      input: fixture.input,
      markerExpectations: []
    )
    #expect(withoutIntent.sha256 != baseline.sha256)
    #expect(withoutIntent.excludedCommentIDs.isEmpty)
  }

  @Test("human edits, comments, domain labels, and linked digests make plans stale")
  func humanAndSourceChangesAreStale() throws {
    let fixture = try issueRevisionFixture()
    let baseline = try revision(fixture.input, fixture: fixture)

    let editedBody = replacing(fixture.input, body: "Body changed")
    #expect(try revision(editedBody, fixture: fixture) != baseline)

    var comments = fixture.input.comments
    comments.append(
      IssueRevisionComment(
        id: 3,
        nodeID: "C_new",
        authorID: 3,
        authorLogin: "reviewer",
        createdAt: "2026-08-06T00:02:00Z",
        updatedAt: "2026-08-06T00:02:00Z",
        body: "New input"
      ))
    #expect(
      try revision(replacing(fixture.input, comments: comments), fixture: fixture) != baseline)

    var labels = fixture.input.labels
    labels.append(IssueRevisionLabel(nodeID: "L_security", name: "security"))
    #expect(try revision(replacing(fixture.input, labels: labels), fixture: fixture) != baseline)

    var links = fixture.input.linkedInputs
    links[0] = IssueRevisionLinkedInput(
      canonicalURL: links[0].canonicalURL,
      nodeID: links[0].nodeID,
      retrievalRevision: links[0].retrievalRevision,
      contentDigest: String(repeating: "e", count: 64)
    )
    #expect(
      try revision(replacing(fixture.input, linkedInputs: links), fixture: fixture) != baseline)
  }

  @Test("Unicode is not normalized and numeric comment order is deterministic")
  func unicodeAndOrdering() throws {
    let fixture = try issueRevisionFixture()
    let composed = replacing(fixture.input, title: "é")
    let decomposed = replacing(fixture.input, title: "e\u{301}")
    #expect(try revision(composed, fixture: fixture) != revision(decomposed, fixture: fixture))

    let reversed = replacing(fixture.input, comments: Array(fixture.input.comments.reversed()))
    #expect(try revision(reversed, fixture: fixture) == revision(fixture.input, fixture: fixture))
  }

  @Test("duplicate immutable IDs and malformed timestamps fail closed")
  func malformedRemoteSnapshot() throws {
    let fixture = try issueRevisionFixture()
    let duplicate = replacing(
      fixture.input,
      comments: fixture.input.comments + [fixture.input.comments[0]]
    )
    #expect(throws: IssueRevisionError.invalidComment) {
      _ = try IssueRevisionBuilder.make(
        input: duplicate,
        markerExpectations: [fixture.expectation]
      )
    }
    let malformedTimestamp = IssueRevisionInput(
      issueNodeID: fixture.input.issueNodeID,
      title: fixture.input.title,
      body: fixture.input.body,
      authorID: fixture.input.authorID,
      createdAt: "2026-99-99T99:99:99Z",
      labels: fixture.input.labels,
      comments: fixture.input.comments,
      linkedInputs: fixture.input.linkedInputs
    )
    #expect(throws: IssueRevisionError.invalidTimestamp) {
      _ = try IssueRevisionBuilder.make(input: malformedTimestamp)
    }
    let oversized = replacing(
      fixture.input,
      body: String(repeating: "x", count: 100_001)
    )
    #expect(throws: IssueRevisionError.invalidContent) {
      _ = try IssueRevisionBuilder.make(input: oversized)
    }
    let oversizedLabel = replacing(
      fixture.input,
      labels: fixture.input.labels + [
        IssueRevisionLabel(
          nodeID: "L_oversized",
          name: "a" + String(repeating: "\u{301}", count: 1_000)
        )
      ]
    )
    #expect(throws: IssueRevisionError.invalidLabel) {
      _ = try IssueRevisionBuilder.make(input: oversizedLabel)
    }
  }

  @Test("base revision binds validated branch and exact SHA")
  func baseRevision() throws {
    let first = try BaseRevision(branch: "main", sha: String(repeating: "a", count: 40))
    let same = try BaseRevision(branch: "main", sha: String(repeating: "a", count: 40))
    let moved = try BaseRevision(branch: "main", sha: String(repeating: "b", count: 40))
    #expect(first == same)
    #expect(first.sha256 != moved.sha256)
    #expect(throws: IssueRevisionError.invalidBaseRevision) {
      _ = try BaseRevision(branch: "feature/.hidden", sha: String(repeating: "a", count: 40))
    }
    #expect(throws: IssueRevisionError.invalidBaseRevision) {
      _ = try BaseRevision(branch: "main", sha: "not-a-sha")
    }
  }
}

private struct IssueRevisionFixture {
  let input: IssueRevisionInput
  let expectation: GitHubMarkerExpectation
}

private func issueRevisionFixture() throws -> IssueRevisionFixture {
  let identity = GitHubMarkerIdentity(
    kind: .plan,
    repositoryNodeID: "R_repo",
    objectNodeID: "I_issue",
    revision: "revision",
    idempotencyKey: GitHubMarkerCodec.sha256(Data("intent".utf8))
  )
  let part = try #require(
    GitHubMarkerCodec.build(document: "App transition", identity: identity).first
  )
  let input = IssueRevisionInput(
    issueNodeID: "I_issue",
    title: "Title",
    body: "Body\r\n",
    authorID: 1,
    createdAt: "2026-08-06T00:00:00Z",
    labels: [
      IssueRevisionLabel(nodeID: "L_ready", name: "agent:wip"),
      IssueRevisionLabel(nodeID: "L_bug", name: "bug"),
    ],
    comments: [
      IssueRevisionComment(
        id: 1,
        nodeID: "C_app",
        authorID: 42,
        authorLogin: "jidoka-code",
        createdAt: "2026-08-06T00:00:30Z",
        updatedAt: "2026-08-06T00:00:30Z",
        body: part.body
      ),
      IssueRevisionComment(
        id: 2,
        nodeID: "C_human",
        authorID: 2,
        authorLogin: "human",
        createdAt: "2026-08-06T00:01:00Z",
        updatedAt: "2026-08-06T00:01:00Z",
        body: "Human comment"
      ),
    ],
    linkedInputs: [
      IssueRevisionLinkedInput(
        canonicalURL: "https://example.com/spec",
        nodeID: "LI_spec",
        retrievalRevision: "r1",
        contentDigest: String(repeating: "d", count: 64)
      )
    ]
  )
  return IssueRevisionFixture(
    input: input,
    expectation: GitHubMarkerExpectation(
      identity: identity,
      authorID: 42,
      documentSHA256: part.documentSHA256
    )
  )
}

private func revision(
  _ input: IssueRevisionInput,
  fixture: IssueRevisionFixture
) throws -> String {
  try IssueRevisionBuilder.make(
    input: input,
    markerExpectations: [fixture.expectation]
  ).sha256
}

private func replacing(
  _ input: IssueRevisionInput,
  title: String? = nil,
  body: String? = nil,
  labels: [IssueRevisionLabel]? = nil,
  comments: [IssueRevisionComment]? = nil,
  linkedInputs: [IssueRevisionLinkedInput]? = nil
) -> IssueRevisionInput {
  IssueRevisionInput(
    issueNodeID: input.issueNodeID,
    title: title ?? input.title,
    body: body ?? input.body,
    authorID: input.authorID,
    createdAt: input.createdAt,
    labels: labels ?? input.labels,
    comments: comments ?? input.comments,
    linkedInputs: linkedInputs ?? input.linkedInputs
  )
}
