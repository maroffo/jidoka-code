import Foundation

public struct GitHubMarkerPublicationRequest: Sendable {
  public let jobID: UUID
  public let operation: MutationOperation
  public let repositoryID: UUID
  public let repository: GitHubRepositoryCoordinates
  public let repositoryNodeID: String
  public let objectNodeID: String
  public let number: Int
  public let revision: String
  public let kind: GitHubMarkerKind
  public let authorID: Int64
  public let document: String
  public let now: Date
  public let generation: Int

  public init(
    jobID: UUID,
    operation: MutationOperation,
    repositoryID: UUID,
    repository: GitHubRepositoryCoordinates,
    repositoryNodeID: String,
    objectNodeID: String,
    number: Int,
    revision: String,
    kind: GitHubMarkerKind,
    authorID: Int64,
    document: String,
    now: Date,
    generation: Int = 0
  ) {
    self.jobID = jobID
    self.operation = operation
    self.repositoryID = repositoryID
    self.repository = repository
    self.repositoryNodeID = repositoryNodeID
    self.objectNodeID = objectNodeID
    self.number = number
    self.revision = revision
    self.kind = kind
    self.authorID = authorID
    self.document = document
    self.now = now
    self.generation = generation
  }

  public func replacingGeneration(_ generation: Int) -> GitHubMarkerPublicationRequest {
    GitHubMarkerPublicationRequest(
      jobID: jobID,
      operation: operation,
      repositoryID: repositoryID,
      repository: repository,
      repositoryNodeID: repositoryNodeID,
      objectNodeID: objectNodeID,
      number: number,
      revision: revision,
      kind: kind,
      authorID: authorID,
      document: document,
      now: now,
      generation: generation
    )
  }
}

public enum GitHubMarkerPublicationDisposition: String, Equatable, Sendable {
  case attributed
  case escalated
}

public struct GitHubMarkerPublicationResult: Equatable, Sendable {
  public let disposition: GitHubMarkerPublicationDisposition
  public let identity: GitHubMarkerIdentity
  public let documentSHA256: String
  public let comments: [GitHubComment]
  public let intentIDs: [UUID]
  public let evidenceDigest: String
}

public enum GitHubMarkerPublisherError: Error, Equatable, Sendable {
  case invalidRequest
  case unsupportedOperation
  case unexpectedIntentState(MutationIntentState)
  case attributionMismatch
  case canarySuppressed
}

public protocol JobCanaryMarkerAuthorizing: Sendable {
  func authorizeCanaryMarkerBatch(
    jobID: UUID,
    operation: MutationOperation,
    documentSHA256: String,
    partCount: Int,
    now: Date
  ) async throws
}

public actor JobCanaryMarkerAuthorizationGate: JobCanaryMarkerAuthorizing {
  private let authority: any JobCanaryMarkerAuthorizing
  private var jobID: UUID?

  public init(authority: any JobCanaryMarkerAuthorizing) {
    self.authority = authority
  }

  public func begin(jobID: UUID) throws {
    guard self.jobID == nil else { throw GitHubMarkerPublisherError.canarySuppressed }
    self.jobID = jobID
  }

  public func end() {
    jobID = nil
  }

  public func authorizeCanaryMarkerBatch(
    jobID: UUID,
    operation: MutationOperation,
    documentSHA256: String,
    partCount: Int,
    now: Date
  ) async throws {
    guard let authorizedJobID = self.jobID else { return }
    guard authorizedJobID == jobID else {
      throw GitHubMarkerPublisherError.canarySuppressed
    }
    try await authority.authorizeCanaryMarkerBatch(
      jobID: jobID,
      operation: operation,
      documentSHA256: documentSHA256,
      partCount: partCount,
      now: now
    )
  }
}

public actor GitHubMarkerPublisher {
  private let executor: GitHubMutationExecutor
  private let intents: MutationIntentStore
  private let reads: any GitHubMutationReadAPI
  private let authority: any RolloutEffectAuthorizing
  private let canaryAuthorizer: (any JobCanaryMarkerAuthorizing)?
  private let sleeper: any MutationReconciliationSleeper
  private let now: @Sendable () -> Date

  public init(
    executor: GitHubMutationExecutor,
    intents: MutationIntentStore,
    reads: any GitHubMutationReadAPI,
    authority: any RolloutEffectAuthorizing,
    canaryAuthorizer: (any JobCanaryMarkerAuthorizing)? = nil,
    sleeper: any MutationReconciliationSleeper = SystemMutationReconciliationSleeper(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.executor = executor
    self.intents = intents
    self.reads = reads
    self.authority = authority
    self.canaryAuthorizer = canaryAuthorizer
    self.sleeper = sleeper
    self.now = now
  }

  public func publish(
    _ request: GitHubMarkerPublicationRequest
  ) async throws -> GitHubMarkerPublicationResult {
    guard request.number > 0,
      request.authorID > 0,
      request.generation >= 0,
      GitHubInputValidation.validOwner(request.repository.owner),
      GitHubInputValidation.validRepository(request.repository.repository),
      !request.document.isEmpty
    else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    guard Self.markerOperations.contains(request.operation) else {
      throw GitHubMarkerPublisherError.unsupportedOperation
    }
    let identity = GitHubMarkerIdentity(
      kind: request.kind,
      repositoryNodeID: request.repositoryNodeID,
      objectNodeID: request.objectNodeID,
      revision: request.revision,
      idempotencyKey: Self.digest([
        request.jobID.uuidString.lowercased(),
        request.operation.rawValue,
        "generation:\(request.generation)",
        request.repositoryNodeID,
        request.objectNodeID,
        request.revision,
        GitHubMarkerCodec.sha256(GitHubMarkerCodec.canonicalDocumentBytes(request.document)),
      ])
    )
    let parts = try GitHubMarkerCodec.build(
      document: request.document,
      identity: identity
    )
    guard let documentSHA256 = parts.first?.documentSHA256 else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    try await canaryAuthorizer?.authorizeCanaryMarkerBatch(
      jobID: request.jobID,
      operation: request.operation,
      documentSHA256: documentSHA256,
      partCount: parts.count,
      now: request.now
    )
    let target =
      "\(request.repository.owner)/\(request.repository.repository)/issues/\(request.number)"
    var entries: [(part: GitHubMarkerPart, key: String, intent: MutationIntentRecord)] = []
    entries.reserveCapacity(parts.count)
    for part in parts {
      let key = Self.partIdempotencyKey(
        identity: identity,
        index: part.index,
        payloadSHA256: part.payloadSHA256
      )
      let operation = GitHubOperation.createComment(
        owner: request.repository.owner,
        repository: request.repository.repository,
        number: request.number,
        body: part.body
      )
      let prepared = try await intents.prepare(
        jobID: request.jobID,
        idempotencyKey: key,
        operation: request.operation,
        target: target,
        expectedStateDigest: documentSHA256,
        requestDigest: try GitHubMutationExecutor.requestDigest(operation),
        now: request.now
      )
      entries.append((part, key, prepared))
    }
    let freshIntents = entries.compactMap { entry -> UUID? in
      entry.intent.state == .prepared || entry.intent.state == .retryAllowed
        ? entry.intent.id : nil
    }
    if !freshIntents.isEmpty {
      _ = try await authority.reserveMarkerBatch(
        RolloutMarkerBatchEffect(
          jobID: request.jobID,
          operation: request.operation,
          repositoryID: request.repositoryID,
          repository: request.repository,
          repositoryNodeID: request.repositoryNodeID,
          objectNodeID: request.objectNodeID,
          objectNumber: request.number,
          revision: request.revision,
          markerKind: request.kind,
          authorID: request.authorID,
          documentSHA256: documentSHA256,
          generation: request.generation,
          intentIDs: freshIntents
        ),
        now: request.now
      )
    }
    var dispatched = entries.map(\.intent)
    var stopSending = false
    for entry in entries {
      if stopSending { continue }
      let existing = entry.intent
      switch existing.state {
      case .prepared, .retryAllowed:
        break
      case .sendStarted, .reconcileRequired:
        stopSending = true
        continue
      case .attributed:
        continue
      case .escalated:
        return try await escalatedResult(
          identity: identity,
          documentSHA256: documentSHA256,
          intents: dispatched,
          evidence: existing.readBackEvidence
        )
      }
      do {
        let dispatch = try await executor.prepareAndSend(
          jobID: request.jobID,
          idempotencyKey: entry.key,
          mutation: request.operation,
          target: target,
          expectedStateDigest: documentSHA256,
          operation: .createComment(
            owner: request.repository.owner,
            repository: request.repository.repository,
            number: request.number,
            body: entry.part.body
          ),
          now: request.now
        )
        if let index = dispatched.firstIndex(where: { $0.id == dispatch.intent.id }) {
          dispatched[index] = dispatch.intent
        } else {
          dispatched.append(dispatch.intent)
        }
        guard dispatch.intent.state != .escalated else {
          return try await escalatedResult(
            identity: identity,
            documentSHA256: documentSHA256,
            intents: dispatched,
            evidence: dispatch.intent.readBackEvidence
          )
        }
        if dispatch.response.disposition != .success { stopSending = true }
      } catch {
        guard let uncertain = try await intents.intent(idempotencyKey: entry.key),
          uncertain.state == .sendStarted || uncertain.state == .reconcileRequired
        else {
          throw error
        }
        if let index = dispatched.firstIndex(where: { $0.id == uncertain.id }) {
          dispatched[index] = uncertain
        } else {
          dispatched.append(uncertain)
        }
        stopSending = true
      }
    }

    guard
      let representative = dispatched.first(where: {
        $0.state == .sendStarted || $0.state == .reconcileRequired
      }) ?? dispatched.first
    else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    let expectation = GitHubMarkerExpectation(
      identity: identity,
      authorID: request.authorID,
      documentSHA256: documentSHA256
    )
    let reader = GitHubJobMutationObservationReader(
      api: reads,
      expectation: .marker(
        repository: request.repository,
        number: request.number,
        expectation: expectation
      )
    )
    let reconciler = MutationReconciliationRunner(
      store: intents,
      reader: reader,
      authority: authority,
      sleeper: sleeper,
      now: now
    )
    let settled = try await reconciler.reconcile(intentID: representative.id)
    guard let evidence = settled.readBackEvidence else {
      throw GitHubMarkerPublisherError.unexpectedIntentState(settled.state)
    }
    switch settled.state {
    case .attributed:
      for intent in dispatched where intent.id != settled.id {
        let attributed = try await intents.settle(
          id: intent.id,
          outcome: .attributableEffect,
          evidenceDigest: evidence,
          now: now()
        )
        try await recordSettlement(attributed, evidenceSHA256: evidence)
      }
      let comments = try await reads.listComments(
        owner: request.repository.owner,
        repository: request.repository.repository,
        number: request.number
      )
      let markerComments = comments.map {
        GitHubMarkerComment(id: $0.id, authorID: $0.user.id, body: $0.body)
      }
      let attributed = GitHubMarkerAttributor.attributedCommentIDs(
        comments: markerComments,
        expectations: [expectation]
      )
      let exact = comments.filter { attributed.contains($0.id) }.sorted { $0.id < $1.id }
      guard exact.count == parts.count else {
        throw GitHubMarkerPublisherError.attributionMismatch
      }
      return GitHubMarkerPublicationResult(
        disposition: .attributed,
        identity: identity,
        documentSHA256: documentSHA256,
        comments: exact,
        intentIDs: dispatched.map(\.id),
        evidenceDigest: evidence
      )
    case .escalated:
      return try await escalatedResult(
        identity: identity,
        documentSHA256: documentSHA256,
        intents: dispatched,
        evidence: evidence
      )
    default:
      throw GitHubMarkerPublisherError.unexpectedIntentState(settled.state)
    }
  }

  private func escalatedResult(
    identity: GitHubMarkerIdentity,
    documentSHA256: String,
    intents values: [MutationIntentRecord],
    evidence: String?
  ) async throws -> GitHubMarkerPublicationResult {
    let digest = evidence ?? Self.digest([identity.idempotencyKey, "escalated"])
    for intent in values where !intent.state.isTerminal {
      let escalated = try await intents.settle(
        id: intent.id,
        outcome: .escalation,
        evidenceDigest: digest,
        now: now()
      )
      try await recordSettlement(escalated, evidenceSHA256: digest)
    }
    return GitHubMarkerPublicationResult(
      disposition: .escalated,
      identity: identity,
      documentSHA256: documentSHA256,
      comments: [],
      intentIDs: values.map(\.id),
      evidenceDigest: digest
    )
  }

  private func recordSettlement(
    _ intent: MutationIntentRecord,
    evidenceSHA256: String
  ) async throws {
    if intent.state == .attributed {
      try await authority.recordMutationObservation(
        intentID: intent.id,
        observation: .attributed,
        evidenceSHA256: evidenceSHA256,
        now: now()
      )
    }
    try await authority.recordMutationObservation(
      intentID: intent.id,
      observation: .settled,
      evidenceSHA256: evidenceSHA256,
      now: now()
    )
  }

  public func publishCheckingPriorGenerations(
    _ request: GitHubMarkerPublicationRequest,
    priorGenerations: [Int]
  ) async throws -> GitHubMarkerPublicationResult {
    if let prior = try await readBackFirstAttributed(
      request,
      priorGenerations: priorGenerations
    ) {
      return prior
    }
    return try await publish(request)
  }

  public func readBackFirstAttributed(
    _ request: GitHubMarkerPublicationRequest,
    priorGenerations: [Int]
  ) async throws -> GitHubMarkerPublicationResult? {
    guard priorGenerations.count <= 1_024,
      Set(priorGenerations).count == priorGenerations.count,
      priorGenerations.allSatisfy({ $0 >= 0 && $0 < request.generation })
    else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    for generation in priorGenerations.reversed() {
      let candidate = request.replacingGeneration(generation)
      guard try await hasDurableIntent(candidate) else { continue }
      let prior = try await readBackLate(candidate)
      if prior.disposition == .attributed { return prior }
    }
    return nil
  }

  private func hasDurableIntent(_ request: GitHubMarkerPublicationRequest) async throws -> Bool {
    let identity = GitHubMarkerIdentity(
      kind: request.kind,
      repositoryNodeID: request.repositoryNodeID,
      objectNodeID: request.objectNodeID,
      revision: request.revision,
      idempotencyKey: Self.digest([
        request.jobID.uuidString.lowercased(),
        request.operation.rawValue,
        "generation:\(request.generation)",
        request.repositoryNodeID,
        request.objectNodeID,
        request.revision,
        GitHubMarkerCodec.sha256(
          GitHubMarkerCodec.canonicalDocumentBytes(request.document)
        ),
      ])
    )
    guard
      let first = try GitHubMarkerCodec.build(
        document: request.document,
        identity: identity
      ).first
    else { return false }
    let key = Self.partIdempotencyKey(
      identity: identity,
      index: first.index,
      payloadSHA256: first.payloadSHA256
    )
    return try await intents.intent(idempotencyKey: key) != nil
  }

  public func readBackLate(
    _ request: GitHubMarkerPublicationRequest
  ) async throws -> GitHubMarkerPublicationResult {
    guard request.number > 0, request.authorID > 0, request.generation >= 0,
      Self.markerOperations.contains(request.operation)
    else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    let identity = GitHubMarkerIdentity(
      kind: request.kind,
      repositoryNodeID: request.repositoryNodeID,
      objectNodeID: request.objectNodeID,
      revision: request.revision,
      idempotencyKey: Self.digest([
        request.jobID.uuidString.lowercased(),
        request.operation.rawValue,
        "generation:\(request.generation)",
        request.repositoryNodeID,
        request.objectNodeID,
        request.revision,
        GitHubMarkerCodec.sha256(
          GitHubMarkerCodec.canonicalDocumentBytes(request.document)
        ),
      ])
    )
    let parts = try GitHubMarkerCodec.build(document: request.document, identity: identity)
    guard let documentSHA256 = parts.first?.documentSHA256 else {
      throw GitHubMarkerPublisherError.invalidRequest
    }
    let comments = try await reads.listComments(
      owner: request.repository.owner,
      repository: request.repository.repository,
      number: request.number
    )
    let markerComments = comments.map {
      GitHubMarkerComment(id: $0.id, authorID: $0.user.id, body: $0.body)
    }
    let expectation = GitHubMarkerExpectation(
      identity: identity,
      authorID: request.authorID,
      documentSHA256: documentSHA256
    )
    let observation = GitHubMutationObservations.markerComment(
      comments: markerComments,
      expectation: expectation
    )
    guard case .effectExact(let evidenceDigest) = observation else {
      return GitHubMarkerPublicationResult(
        disposition: .escalated,
        identity: identity,
        documentSHA256: documentSHA256,
        comments: [],
        intentIDs: [],
        evidenceDigest: observation.evidenceDigest
          ?? Self.digest(["late-marker-not-visible", identity.idempotencyKey])
      )
    }
    var intentIDs: [UUID] = []
    for part in parts {
      let key = Self.partIdempotencyKey(
        identity: identity,
        index: part.index,
        payloadSHA256: part.payloadSHA256
      )
      guard let intent = try await intents.intent(idempotencyKey: key),
        intent.state == .escalated || intent.state == .attributed
      else {
        throw GitHubMarkerPublisherError.attributionMismatch
      }
      _ = try await intents.attributeLateVisibleEffect(
        id: intent.id,
        evidenceDigest: evidenceDigest,
        now: now()
      )
      intentIDs.append(intent.id)
    }
    let attributedIDs = GitHubMarkerAttributor.attributedCommentIDs(
      comments: markerComments,
      expectations: [expectation]
    )
    let attributed = comments.filter { attributedIDs.contains($0.id) }
      .sorted { $0.id < $1.id }
    guard attributed.count == parts.count else {
      throw GitHubMarkerPublisherError.attributionMismatch
    }
    return GitHubMarkerPublicationResult(
      disposition: .attributed,
      identity: identity,
      documentSHA256: documentSHA256,
      comments: attributed,
      intentIDs: intentIDs,
      evidenceDigest: evidenceDigest
    )
  }

  public static func partIdempotencyKey(
    identity: GitHubMarkerIdentity,
    index: Int,
    payloadSHA256: String
  ) -> String {
    digest([
      identity.idempotencyKey,
      "part",
      String(index),
      payloadSHA256,
    ])
  }

  private static let markerOperations: Set<MutationOperation> = [
    .createMarkerComment, .claimIssue, .linkPullRequest, .publishComplexPlan, .blockIssue,
  ]

  private static func digest(_ fields: [String]) -> String {
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }
}
