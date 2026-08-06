import Foundation

public struct WorkflowLabelExpectation: Equatable, Sendable {
  public let expected: Set<String>
  public let desired: Set<String>

  public init(expected: Set<String>, desired: Set<String>) {
    self.expected = expected
    self.desired = desired
  }
}

public struct PullRequestMutationExpectation: Equatable, Sendable {
  public let head: String
  public let base: String
  public let exactHeadSHA: String
  public let bodySHA256: String

  public init(
    head: String,
    base: String,
    exactHeadSHA: String,
    bodySHA256: String
  ) {
    self.head = head
    self.base = base
    self.exactHeadSHA = exactHeadSHA
    self.bodySHA256 = bodySHA256
  }
}

public enum GitHubMutationObservations {
  public static func bootstrapLabel(
    expected: GitHubCreateLabel,
    actual: GitHubLabel?
  ) -> MutationObservation {
    guard let actual else {
      return .effectAbsent(evidenceDigest: evidence(["label-absent", expected.name]))
    }
    let exact =
      actual.name.caseInsensitiveCompare(expected.name) == .orderedSame
      && actual.color.lowercased() == expected.color.lowercased()
      && (actual.description ?? "") == expected.description
    return exact
      ? .effectExact(evidenceDigest: evidence([actual.nodeID, actual.name, actual.color]))
      : .conflict(
        evidenceDigest: evidence([
          actual.nodeID, actual.name, actual.color, actual.description ?? "",
        ]))
  }

  public static func markerComment(
    comments: [GitHubMarkerComment],
    expectation: GitHubMarkerExpectation
  ) -> MutationObservation {
    let relevant = comments.filter { comment in
      guard let parsed = try? GitHubMarkerCodec.parse(comment.body) else {
        return false
      }
      return parsed.identity.idempotencyKey == expectation.identity.idempotencyKey
        || (parsed.identity.kind == expectation.identity.kind
          && parsed.identity.repositoryNodeID == expectation.identity.repositoryNodeID
          && parsed.identity.objectNodeID == expectation.identity.objectNodeID
          && parsed.identity.revision == expectation.identity.revision)
    }
    guard !relevant.isEmpty else {
      return .effectAbsent(
        evidenceDigest: evidence(["marker-absent", expectation.identity.idempotencyKey])
      )
    }
    do {
      let document = try GitHubMarkerCodec.reconstruct(
        comments: relevant,
        expectation: expectation
      )
      return .effectExact(evidenceDigest: GitHubMarkerCodec.sha256(document))
    } catch GitHubMarkerError.duplicatePart {
      return .duplicate(evidenceDigest: commentEvidence(relevant))
    } catch GitHubMarkerError.payloadDigestMismatch {
      return .digestMismatch(evidenceDigest: commentEvidence(relevant))
    } catch GitHubMarkerError.documentDigestMismatch {
      return .digestMismatch(evidenceDigest: commentEvidence(relevant))
    } catch GitHubMarkerError.missingPart {
      return .incomplete(evidenceDigest: commentEvidence(relevant))
    } catch GitHubMarkerError.reorderedPart {
      return .incomplete(evidenceDigest: commentEvidence(relevant))
    } catch {
      return .conflict(evidenceDigest: commentEvidence(relevant))
    }
  }

  public static func workflowLabels(
    currentWorkflowLabels: Set<String>,
    expectation: WorkflowLabelExpectation
  ) -> MutationObservation {
    let canonicalCurrent = canonicalLabelSet(currentWorkflowLabels)
    let desired = canonicalLabelSet(expectation.desired)
    let expected = canonicalLabelSet(expectation.expected)
    let digest = evidence(canonicalCurrent.sorted())
    if canonicalCurrent == desired {
      return .desiredStateExact(evidenceDigest: digest)
    }
    if canonicalCurrent == expected {
      return .expectedStateExact(evidenceDigest: digest)
    }
    return .conflict(evidenceDigest: digest)
  }

  public static func pullRequest(
    candidates: [GitHubPullRequest],
    exact: GitHubPullRequest?,
    expectation: PullRequestMutationExpectation
  ) -> MutationObservation {
    guard GitHubInputValidation.validHead(expectation.head),
      GitHubInputValidation.validBranch(expectation.base),
      GitHubInputValidation.validGitSHA(expectation.exactHeadSHA),
      GitHubInputValidation.validSHA256(expectation.bodySHA256)
    else {
      return .conflict(evidenceDigest: evidence(["invalid-pr-expectation"]))
    }
    guard !candidates.isEmpty else {
      return .effectAbsent(evidenceDigest: evidence(["pr-absent", expectation.head]))
    }
    guard candidates.count == 1, let listed = candidates.first else {
      return .duplicate(
        evidenceDigest: evidence(candidates.map { String($0.number) }.sorted())
      )
    }
    guard let candidate = exact else {
      return .incomplete(evidenceDigest: evidence([listed.nodeID, "exact-pr-missing"]))
    }
    guard listed.id == candidate.id,
      listed.nodeID == candidate.nodeID,
      listed.number == candidate.number
    else {
      return .conflict(
        evidenceDigest: evidence([
          listed.nodeID, candidate.nodeID,
          String(listed.number), String(candidate.number),
        ]))
    }
    let headComponents = expectation.head.split(
      separator: ":",
      omittingEmptySubsequences: false
    )
    let expectedHeadReference = headComponents.last.map(String.init) ?? ""
    let expectedHeadOwner = headComponents.count == 2 ? String(headComponents[0]) : nil
    let actualHeadOwner = candidate.head.repository?.fullName.split(
      separator: "/",
      maxSplits: 1
    ).first.map(String.init)
    let ownerMatches =
      expectedHeadOwner.map { expected in
        actualHeadOwner?.caseInsensitiveCompare(expected) == .orderedSame
      } ?? true
    let bodyDigest = GitHubMarkerCodec.sha256(Data((candidate.body ?? "").utf8))
    guard candidate.state == "open", !candidate.draft,
      candidate.head.ref == expectedHeadReference,
      ownerMatches,
      candidate.base.ref == expectation.base,
      candidate.head.sha == expectation.exactHeadSHA,
      bodyDigest == expectation.bodySHA256
    else {
      return .conflict(
        evidenceDigest: evidence([
          String(candidate.number), candidate.state, String(candidate.draft),
          candidate.head.ref, candidate.base.ref, candidate.head.sha, bodyDigest,
        ]))
    }
    return .effectExact(
      evidenceDigest: evidence([
        candidate.nodeID, String(candidate.number), candidate.head.sha, bodyDigest,
      ])
    )
  }

  public static func branchReference(
    actual: GitHubReference?,
    branch: String,
    exactSHA: String
  ) -> MutationObservation {
    guard GitHubInputValidation.validBranch(branch),
      GitHubInputValidation.validGitSHA(exactSHA)
    else {
      return .conflict(evidenceDigest: evidence(["invalid-ref-expectation"]))
    }
    guard let actual else {
      return .effectAbsent(evidenceDigest: evidence(["ref-absent", branch]))
    }
    guard actual.ref == "refs/heads/\(branch)", actual.object.sha == exactSHA else {
      return .conflict(evidenceDigest: evidence([actual.ref, actual.object.sha]))
    }
    return .effectExact(evidenceDigest: evidence([actual.ref, actual.object.sha]))
  }

  public static func composite(
    marker: MutationObservation,
    labels: MutationObservation
  ) -> MutationObservation {
    let markerEvidence: String
    switch marker {
    case .effectExact(let digest): markerEvidence = digest
    case .effectAbsent(let digest): return .effectAbsent(evidenceDigest: digest)
    case .duplicate(let digest): return .duplicate(evidenceDigest: digest)
    case .digestMismatch(let digest): return .digestMismatch(evidenceDigest: digest)
    case .incomplete(let digest): return .incomplete(evidenceDigest: digest)
    case .conflict(let digest): return .conflict(evidenceDigest: digest)
    case .notVisibleYet: return .notVisibleYet
    case .expectedStateExact(let digest): return .incomplete(evidenceDigest: digest)
    case .desiredStateExact(let digest): return .incomplete(evidenceDigest: digest)
    }

    let labelEvidence: String
    switch labels {
    case .desiredStateExact(let digest): labelEvidence = digest
    case .expectedStateExact(let digest): return .expectedStateExact(evidenceDigest: digest)
    case .effectAbsent(let digest): return .incomplete(evidenceDigest: digest)
    case .duplicate(let digest): return .duplicate(evidenceDigest: digest)
    case .digestMismatch(let digest): return .digestMismatch(evidenceDigest: digest)
    case .incomplete(let digest): return .incomplete(evidenceDigest: digest)
    case .conflict(let digest): return .conflict(evidenceDigest: digest)
    case .notVisibleYet: return .notVisibleYet
    case .effectExact(let digest): return .incomplete(evidenceDigest: digest)
    }
    return .effectExact(evidenceDigest: evidence([markerEvidence, labelEvidence]))
  }

  private static func canonicalLabelSet(_ labels: Set<String>) -> Set<String> {
    Set(labels.map { $0.lowercased() })
  }

  private static func commentEvidence(_ comments: [GitHubMarkerComment]) -> String {
    evidence(
      comments.map { comment in
        "\(comment.id):\(comment.authorID):\(GitHubMarkerCodec.sha256(Data(comment.body.utf8)))"
      })
  }

  private static func evidence(_ fields: [String]) -> String {
    let encoded = fields.map { field in
      "\(field.utf8.count):\(field)"
    }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(encoded.utf8))
  }
}
