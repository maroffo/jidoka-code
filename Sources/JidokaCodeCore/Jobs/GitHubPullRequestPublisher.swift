import Foundation

public struct GitHubPullRequestPublicationRequest: Sendable {
  public let jobID: UUID
  public let repository: GitHubRepositoryCoordinates
  public let title: String
  public let head: String
  public let base: String
  public let body: String
  public let expectedHeadSHA: String
  public let generation: Int
  public let now: Date

  public init(
    jobID: UUID,
    repository: GitHubRepositoryCoordinates,
    title: String,
    head: String,
    base: String,
    body: String,
    expectedHeadSHA: String,
    generation: Int,
    now: Date
  ) {
    self.jobID = jobID
    self.repository = repository
    self.title = title
    self.head = head
    self.base = base
    self.body = body
    self.expectedHeadSHA = expectedHeadSHA
    self.generation = generation
    self.now = now
  }

  public func replacingGeneration(_ generation: Int) -> GitHubPullRequestPublicationRequest {
    GitHubPullRequestPublicationRequest(
      jobID: jobID,
      repository: repository,
      title: title,
      head: head,
      base: base,
      body: body,
      expectedHeadSHA: expectedHeadSHA,
      generation: generation,
      now: now
    )
  }
}

public enum GitHubPullRequestPublicationDisposition: String, Equatable, Sendable {
  case attributed
  case retryAllowed
  case escalated
}

public struct GitHubPullRequestPublicationResult: Sendable {
  public let disposition: GitHubPullRequestPublicationDisposition
  public let intentID: UUID
  public let pullRequest: GitHubPullRequest?
  public let evidenceDigest: String
}

public enum GitHubPullRequestPublisherError: Error, Equatable, Sendable {
  case invalidRequest
  case unexpectedIntentState(MutationIntentState)
  case attributedPullRequestMissing
}

public actor GitHubPullRequestPublisher {
  private let executor: GitHubMutationExecutor
  private let intents: MutationIntentStore
  private let reads: any GitHubMutationReadAPI
  private let authority: any RolloutEffectAuthorizing
  private let sleeper: any MutationReconciliationSleeper
  private let now: @Sendable () -> Date

  public init(
    executor: GitHubMutationExecutor,
    intents: MutationIntentStore,
    reads: any GitHubMutationReadAPI,
    authority: any RolloutEffectAuthorizing,
    sleeper: any MutationReconciliationSleeper = SystemMutationReconciliationSleeper(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.executor = executor
    self.intents = intents
    self.reads = reads
    self.authority = authority
    self.sleeper = sleeper
    self.now = now
  }

  public func publish(
    _ request: GitHubPullRequestPublicationRequest
  ) async throws -> GitHubPullRequestPublicationResult {
    guard request.generation >= 0,
      GitHubInputValidation.validOwner(request.repository.owner),
      GitHubInputValidation.validRepository(request.repository.repository),
      GitHubInputValidation.validBranch(request.head),
      GitHubInputValidation.validBranch(request.base),
      request.head != request.base,
      GitHubInputValidation.validGitSHA(request.expectedHeadSHA),
      !request.title.isEmpty,
      request.title.utf8.count <= 256,
      request.body.utf8.count <= 65_536
    else {
      throw GitHubPullRequestPublisherError.invalidRequest
    }
    let digest = Self.digest([
      request.repository.owner,
      request.repository.repository,
      request.head,
      request.base,
      request.expectedHeadSHA,
      request.title,
      request.body,
    ])
    let key = Self.digest([
      request.jobID.uuidString.lowercased(),
      MutationOperation.createPullRequest.rawValue,
      "generation:\(request.generation)",
      digest,
    ])
    let existing = try await intents.intent(idempotencyKey: key)
    if let existing, existing.state == .escalated {
      return GitHubPullRequestPublicationResult(
        disposition: .escalated,
        intentID: existing.id,
        pullRequest: nil,
        evidenceDigest: existing.readBackEvidence ?? digest
      )
    }
    let shouldSend =
      existing == nil
      || existing?.state == .prepared
      || existing?.state == .retryAllowed
    let intent: MutationIntentRecord
    if shouldSend {
      do {
        let dispatch = try await executor.prepareAndSend(
          jobID: request.jobID,
          idempotencyKey: key,
          mutation: .createPullRequest,
          target:
            "\(request.repository.owner)/\(request.repository.repository)/pulls/\(request.head)-to-\(request.base)",
          expectedStateDigest: digest,
          operation: .createPullRequest(
            owner: request.repository.owner,
            repository: request.repository.repository,
            request: GitHubCreatePullRequest(
              title: request.title,
              head: request.head,
              base: request.base,
              body: request.body
            )
          ),
          now: request.now
        )
        intent = dispatch.intent
        if dispatch.intent.state == .escalated {
          return GitHubPullRequestPublicationResult(
            disposition: .escalated,
            intentID: dispatch.intent.id,
            pullRequest: nil,
            evidenceDigest: dispatch.intent.readBackEvidence ?? digest
          )
        }
      } catch {
        guard let uncertain = try await intents.intent(idempotencyKey: key),
          uncertain.state == .sendStarted || uncertain.state == .reconcileRequired
        else {
          throw error
        }
        intent = uncertain
      }
    } else if let existing {
      intent = existing
    } else {
      throw GitHubPullRequestPublisherError.invalidRequest
    }
    let reader = GitHubJobMutationObservationReader(
      api: reads,
      expectation: .pullRequest(
        repository: request.repository,
        expectation: PullRequestMutationExpectation(
          head: request.head,
          base: request.base,
          exactHeadSHA: request.expectedHeadSHA,
          bodySHA256: GitHubMarkerCodec.sha256(Data(request.body.utf8))
        )
      )
    )
    let reconciler = MutationReconciliationRunner(
      store: intents,
      reader: reader,
      authority: authority,
      sleeper: sleeper,
      now: now
    )
    let settled = try await reconciler.reconcile(intentID: intent.id)
    guard let evidence = settled.readBackEvidence else {
      throw GitHubPullRequestPublisherError.unexpectedIntentState(settled.state)
    }
    switch settled.state {
    case .attributed:
      let matches = try await reads.lookupPullRequests(
        owner: request.repository.owner,
        repository: request.repository.repository,
        head: request.head,
        base: request.base
      ).filter { $0.head.sha == request.expectedHeadSHA }
      guard matches.count == 1, let pullRequest = matches.first else {
        throw GitHubPullRequestPublisherError.attributedPullRequestMissing
      }
      return GitHubPullRequestPublicationResult(
        disposition: .attributed,
        intentID: settled.id,
        pullRequest: pullRequest,
        evidenceDigest: evidence
      )
    case .retryAllowed:
      return GitHubPullRequestPublicationResult(
        disposition: .retryAllowed,
        intentID: settled.id,
        pullRequest: nil,
        evidenceDigest: evidence
      )
    case .escalated:
      return GitHubPullRequestPublicationResult(
        disposition: .escalated,
        intentID: settled.id,
        pullRequest: nil,
        evidenceDigest: evidence
      )
    default:
      throw GitHubPullRequestPublisherError.unexpectedIntentState(settled.state)
    }
  }

  public func publishCheckingPriorGenerations(
    _ request: GitHubPullRequestPublicationRequest,
    priorGenerations: [Int]
  ) async throws -> GitHubPullRequestPublicationResult {
    guard priorGenerations.count <= 1_024,
      Set(priorGenerations).count == priorGenerations.count,
      priorGenerations.allSatisfy({ $0 >= 0 && $0 < request.generation })
    else {
      throw GitHubPullRequestPublisherError.invalidRequest
    }
    for generation in priorGenerations.reversed() {
      do {
        let prior = try await readBackLate(request.replacingGeneration(generation))
        if prior.disposition == .attributed { return prior }
      } catch GitHubPullRequestPublisherError.invalidRequest {
        continue
      }
    }
    return try await publish(request)
  }

  public func readBackLate(
    _ request: GitHubPullRequestPublicationRequest
  ) async throws -> GitHubPullRequestPublicationResult {
    let digest = Self.digest([
      request.repository.owner,
      request.repository.repository,
      request.head,
      request.base,
      request.expectedHeadSHA,
      request.title,
      request.body,
    ])
    let key = Self.digest([
      request.jobID.uuidString.lowercased(),
      MutationOperation.createPullRequest.rawValue,
      "generation:\(request.generation)",
      digest,
    ])
    guard let intent = try await intents.intent(idempotencyKey: key),
      intent.state == .escalated || intent.state == .attributed
    else {
      throw GitHubPullRequestPublisherError.invalidRequest
    }
    let candidates = try await reads.lookupPullRequests(
      owner: request.repository.owner,
      repository: request.repository.repository,
      head: request.head,
      base: request.base
    )
    let exact: GitHubPullRequest?
    if candidates.count == 1 {
      exact = try await reads.pullRequest(
        owner: request.repository.owner,
        repository: request.repository.repository,
        number: candidates[0].number
      )
    } else {
      exact = nil
    }
    let observation = GitHubMutationObservations.pullRequest(
      candidates: candidates,
      exact: exact,
      expectation: PullRequestMutationExpectation(
        head: request.head,
        base: request.base,
        exactHeadSHA: request.expectedHeadSHA,
        bodySHA256: GitHubMarkerCodec.sha256(Data(request.body.utf8))
      )
    )
    guard case .effectExact(let evidenceDigest) = observation,
      let pullRequest = exact
    else {
      return GitHubPullRequestPublicationResult(
        disposition: .escalated,
        intentID: intent.id,
        pullRequest: nil,
        evidenceDigest: observation.evidenceDigest ?? digest
      )
    }
    _ = try await intents.attributeLateVisibleEffect(
      id: intent.id,
      evidenceDigest: evidenceDigest,
      now: now()
    )
    return GitHubPullRequestPublicationResult(
      disposition: .attributed,
      intentID: intent.id,
      pullRequest: pullRequest,
      evidenceDigest: evidenceDigest
    )
  }

  private static func digest(_ fields: [String]) -> String {
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }
}
