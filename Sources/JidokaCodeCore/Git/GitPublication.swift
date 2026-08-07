import Foundation

public enum GitPublicationDisposition: String, Equatable, Sendable {
  case safeRetry
  case attributableEffect
  case escalation
}

public struct GitPublicationResult: Equatable, Sendable {
  public let disposition: GitPublicationDisposition
  public let reference: String
  public let expectedSHA: String
  public let observedSHA: String?
  public let sendAttempted: Bool
  public let sendSucceeded: Bool?
  public let observationComplete: Bool
  public let evidenceDigest: String
}

public enum GitPublicationError: Error, Equatable, Sendable {
  case invalidBranch
  case invalidSHA
  case localObjectMissing
  case concurrentPublication
  case readBackUnavailable
}

public struct GitBranchPublicationRequest: Sendable {
  public let jobID: UUID
  public let idempotencyKey: String
  public let branch: String
  public let exactSHA: String
  public let expectedStateDigest: String

  public init(
    jobID: UUID,
    idempotencyKey: String,
    branch: String,
    exactSHA: String,
    expectedStateDigest: String
  ) {
    self.jobID = jobID
    self.idempotencyKey = idempotencyKey
    self.branch = branch
    self.exactSHA = exactSHA
    self.expectedStateDigest = expectedStateDigest
  }

  func target(remote: GitRemoteRepository) -> String {
    "repository:\(remote.nodeID):refs/heads/\(branch)"
  }

  func requestDigest(remote: GitRemoteRepository) -> String {
    let fields = ["git-publish-v1", remote.nodeID, branch, exactSHA]
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }
}

public struct DurableGitPublicationDispatch: Sendable {
  public let intent: MutationIntentRecord
  public let publication: GitPublicationResult?
}

public actor DurableGitPublisher {
  private let intents: MutationIntentStore
  private let publisher: GitPublisher
  private var activeIdempotencyKeys: Set<String> = []

  public init(
    intents: MutationIntentStore,
    transport: any GitPublicationTransporting = SystemGitTransport()
  ) {
    self.intents = intents
    publisher = GitPublisher(transport: transport)
  }

  public func publishCreateOnly(
    request: GitBranchPublicationRequest,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)? = nil,
    now: Date = Date()
  ) async throws -> DurableGitPublicationDispatch {
    guard GitBranchPolicy.validImplementationBranch(request.branch) else {
      throw GitPublicationError.invalidBranch
    }
    guard GitHubInputValidation.validGitSHA(request.exactSHA) else {
      throw GitPublicationError.invalidSHA
    }
    guard activeIdempotencyKeys.insert(request.idempotencyKey).inserted else {
      throw GitPublicationError.concurrentPublication
    }
    defer { activeIdempotencyKeys.remove(request.idempotencyKey) }

    var intent = try await intents.prepare(
      jobID: request.jobID,
      idempotencyKey: request.idempotencyKey,
      operation: .publishBranch,
      target: request.target(remote: remote),
      expectedStateDigest: request.expectedStateDigest,
      requestDigest: request.requestDigest(remote: remote),
      now: now
    )
    switch intent.state {
    case .attributed, .escalated:
      return DurableGitPublicationDispatch(intent: intent, publication: nil)
    case .sendStarted:
      intent = try await intents.markReconcileRequired(id: intent.id, now: now)
      return try await reconcile(
        intent: intent,
        request: request,
        remote: remote,
        repository: repository,
        credentials: credentials,
        now: now
      )
    case .reconcileRequired:
      return try await reconcile(
        intent: intent,
        request: request,
        remote: remote,
        repository: repository,
        credentials: credentials,
        now: now
      )
    case .prepared, .retryAllowed:
      break
    }

    let intentID = intent.id
    let intentStore = intents
    let publication: GitPublicationResult
    do {
      publication = try await publisher.publishCreateOnly(
        branch: request.branch,
        exactSHA: request.exactSHA,
        remote: remote,
        repository: repository,
        credentials: credentials
      ) {
        _ = try await intentStore.markSendStarted(id: intentID, now: now)
      }
    } catch {
      try await markReconcileRequiredIfSendStarted(id: intentID, now: now)
      throw error
    }
    if !publication.observationComplete {
      try await markReconcileRequiredIfSendStarted(id: intentID, now: now)
      throw GitPublicationError.readBackUnavailable
    }
    let settled = try await intents.settle(
      id: intentID,
      outcome: Self.outcome(publication.disposition),
      evidenceDigest: publication.evidenceDigest,
      now: now
    )
    return DurableGitPublicationDispatch(intent: settled, publication: publication)
  }

  private func reconcile(
    intent: MutationIntentRecord,
    request: GitBranchPublicationRequest,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?,
    now: Date
  ) async throws -> DurableGitPublicationDispatch {
    let publication = try await publisher.reconcileCreateOnly(
      branch: request.branch,
      exactSHA: request.exactSHA,
      remote: remote,
      repository: repository,
      credentials: credentials
    )
    let settled = try await intents.settle(
      id: intent.id,
      outcome: Self.outcome(publication.disposition),
      evidenceDigest: publication.evidenceDigest,
      now: now
    )
    return DurableGitPublicationDispatch(intent: settled, publication: publication)
  }

  private func markReconcileRequiredIfSendStarted(id: UUID, now: Date) async throws {
    if try await intents.intent(id: id)?.state == .sendStarted {
      _ = try await intents.markReconcileRequired(id: id, now: now)
    }
  }

  private static func outcome(
    _ disposition: GitPublicationDisposition
  ) -> MutationReconciliationOutcome {
    switch disposition {
    case .safeRetry: .safeRetry
    case .attributableEffect: .attributableEffect
    case .escalation: .escalation
    }
  }
}

actor GitPublisher {
  private let transport: any GitPublicationTransporting
  private var activeReferences: Set<String> = []

  init(transport: any GitPublicationTransporting) {
    self.transport = transport
  }

  func publishCreateOnly(
    branch: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)? = nil,
    beforeSend: (@Sendable () async throws -> Void)? = nil
  ) async throws -> GitPublicationResult {
    try await validateLocalInputs(
      branch: branch,
      exactSHA: exactSHA,
      repository: repository
    )
    let reference = "refs/heads/\(branch)"
    let publicationKey = "\(remote.repositoryID.uuidString.lowercased()):\(reference)"
    guard activeReferences.insert(publicationKey).inserted else {
      throw GitPublicationError.concurrentPublication
    }
    defer { activeReferences.remove(publicationKey) }
    let before = try await transport.readRemoteRef(
      reference,
      remote: remote,
      repository: repository,
      credentials: credentials
    )
    if let before {
      return result(
        disposition: before == exactSHA ? .attributableEffect : .escalation,
        reference: reference,
        expectedSHA: exactSHA,
        observedSHA: before,
        sendAttempted: false,
        sendSucceeded: nil,
        observationComplete: true
      )
    }

    try await beforeSend?()
    let send: GitProcessResult?
    do {
      send = try await transport.createRemoteRef(
        reference,
        exactSHA: exactSHA,
        remote: remote,
        repository: repository,
        credentials: credentials
      )
    } catch {
      send = nil
    }
    let after: String?
    do {
      after = try await transport.readRemoteRef(
        reference,
        remote: remote,
        repository: repository,
        credentials: credentials
      )
    } catch {
      return result(
        disposition: .escalation,
        reference: reference,
        expectedSHA: exactSHA,
        observedSHA: nil,
        sendAttempted: true,
        sendSucceeded: send?.succeeded,
        observationComplete: false
      )
    }
    let disposition: GitPublicationDisposition
    if after == exactSHA {
      disposition = .attributableEffect
    } else if after == nil, send?.succeeded != true {
      disposition = .safeRetry
    } else {
      disposition = .escalation
    }
    return result(
      disposition: disposition,
      reference: reference,
      expectedSHA: exactSHA,
      observedSHA: after,
      sendAttempted: true,
      sendSucceeded: send?.succeeded,
      observationComplete: true
    )
  }

  func reconcileCreateOnly(
    branch: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)? = nil
  ) async throws -> GitPublicationResult {
    try await validateLocalInputs(
      branch: branch,
      exactSHA: exactSHA,
      repository: repository
    )
    let reference = "refs/heads/\(branch)"
    let observed = try await transport.readRemoteRef(
      reference,
      remote: remote,
      repository: repository,
      credentials: credentials
    )
    let disposition: GitPublicationDisposition
    if observed == exactSHA {
      disposition = .attributableEffect
    } else if observed == nil {
      disposition = .safeRetry
    } else {
      disposition = .escalation
    }
    return result(
      disposition: disposition,
      reference: reference,
      expectedSHA: exactSHA,
      observedSHA: observed,
      sendAttempted: true,
      sendSucceeded: nil,
      observationComplete: true
    )
  }

  private func validateLocalInputs(
    branch: String,
    exactSHA: String,
    repository: URL
  ) async throws {
    guard GitBranchPolicy.validImplementationBranch(branch) else {
      throw GitPublicationError.invalidBranch
    }
    guard GitHubInputValidation.validGitSHA(exactSHA) else {
      throw GitPublicationError.invalidSHA
    }
    guard try await transport.containsLocalCommit(exactSHA, repository: repository) else {
      throw GitPublicationError.localObjectMissing
    }
  }

  private func result(
    disposition: GitPublicationDisposition,
    reference: String,
    expectedSHA: String,
    observedSHA: String?,
    sendAttempted: Bool,
    sendSucceeded: Bool?,
    observationComplete: Bool
  ) -> GitPublicationResult {
    let fields = [
      disposition.rawValue,
      reference,
      expectedSHA,
      observedSHA ?? (observationComplete ? "absent" : "unavailable"),
      sendAttempted ? "sent" : "not-sent",
      sendSucceeded.map { $0 ? "send-succeeded" : "send-failed" } ?? "send-unknown",
      observationComplete ? "observed" : "observation-failed",
    ]
    let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitPublicationResult(
      disposition: disposition,
      reference: reference,
      expectedSHA: expectedSHA,
      observedSHA: observedSHA,
      sendAttempted: sendAttempted,
      sendSucceeded: sendSucceeded,
      observationComplete: observationComplete,
      evidenceDigest: GitHubMarkerCodec.sha256(Data(encoded.utf8))
    )
  }
}
