import Foundation

public struct GitHubWorkflowLabelMutationRequest: Sendable {
  public let jobID: UUID
  public let operation: MutationOperation
  public let repository: GitHubRepositoryCoordinates
  public let number: Int
  public let expected: Set<String>
  public let desired: Set<String>
  public let generation: Int
  public let now: Date

  public init(
    jobID: UUID,
    operation: MutationOperation,
    repository: GitHubRepositoryCoordinates,
    number: Int,
    expected: Set<String>,
    desired: Set<String>,
    generation: Int,
    now: Date
  ) {
    self.jobID = jobID
    self.operation = operation
    self.repository = repository
    self.number = number
    self.expected = expected
    self.desired = desired
    self.generation = generation
    self.now = now
  }
}

public enum GitHubWorkflowLabelMutationDisposition: String, Equatable, Sendable {
  case attributed
  case retryAllowed
  case escalated
}

public struct GitHubWorkflowLabelMutationResult: Equatable, Sendable {
  public let disposition: GitHubWorkflowLabelMutationDisposition
  public let intentIDs: [UUID]
  public let evidenceDigest: String
}

public enum GitHubWorkflowLabelMutatorError: Error, Equatable, Sendable {
  case invalidRequest
  case unsupportedOperation
  case noMutationRequired
  case preconditionMismatch
  case unexpectedIntentState(MutationIntentState)
}

public actor GitHubWorkflowLabelMutator {
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

  public func mutate(
    _ request: GitHubWorkflowLabelMutationRequest
  ) async throws -> GitHubWorkflowLabelMutationResult {
    guard request.number > 0,
      request.generation >= 0,
      GitHubInputValidation.validOwner(request.repository.owner),
      GitHubInputValidation.validRepository(request.repository.repository),
      request.expected != request.desired,
      request.expected.union(request.desired).allSatisfy(GitHubInputValidation.validLabel)
    else {
      throw GitHubWorkflowLabelMutatorError.invalidRequest
    }
    guard Self.supportedOperations.contains(request.operation) else {
      throw GitHubWorkflowLabelMutatorError.unsupportedOperation
    }
    let expectedDigest = Self.digest(request.expected.sorted())
    let target =
      "\(request.repository.owner)/\(request.repository.repository)/issues/\(request.number)"
    var mutations: [(String, GitHubOperation)] = []
    let additions = request.desired.subtracting(request.expected).sorted()
    if !additions.isEmpty {
      mutations.append(
        (
          "add:\(additions.joined(separator: ","))",
          .addIssueLabels(
            owner: request.repository.owner,
            repository: request.repository.repository,
            number: request.number,
            labels: additions
          )
        ))
    }
    for removal in request.expected.subtracting(request.desired).sorted() {
      mutations.append(
        (
          "remove:\(removal)",
          .removeIssueLabel(
            owner: request.repository.owner,
            repository: request.repository.repository,
            number: request.number,
            label: removal
          )
        ))
    }
    guard !mutations.isEmpty else {
      throw GitHubWorkflowLabelMutatorError.noMutationRequired
    }
    let normalizedExpected = Self.normalized(request.expected)
    let normalizedDesired = Self.normalized(request.desired)
    let desiredDigest = Self.digest(request.desired.sorted())
    var states = [normalizedExpected]
    for mutation in mutations {
      states.append(try Self.applying(mutation.1, to: states[states.count - 1]))
    }
    guard states.last == normalizedDesired else {
      throw GitHubWorkflowLabelMutatorError.invalidRequest
    }
    let keys = mutations.enumerated().map { index, mutation in
      Self.digest([
        request.jobID.uuidString.lowercased(),
        request.operation.rawValue,
        "generation:\(request.generation)",
        "ordinal:\(index)",
        mutation.0,
        expectedDigest,
        desiredDigest,
      ])
    }
    var existing: [MutationIntentRecord?] = []
    for key in keys {
      existing.append(try await intents.intent(idempotencyKey: key))
    }
    var attributedPrefix = 0
    while attributedPrefix < existing.count,
      existing[attributedPrefix]?.state == .attributed
    {
      attributedPrefix += 1
    }
    guard existing.dropFirst(attributedPrefix + 1).allSatisfy({ $0 == nil }) else {
      throw GitHubWorkflowLabelMutatorError.preconditionMismatch
    }
    let initialLabels = try await workflowLabels(request.repository, number: request.number)
    if attributedPrefix == mutations.count {
      guard initialLabels == normalizedDesired else {
        throw GitHubWorkflowLabelMutatorError.preconditionMismatch
      }
      let records = existing.compactMap { $0 }
      return result(
        disposition: .attributed,
        intents: records,
        evidence: Self.digest(initialLabels.sorted())
      )
    }
    let nextExisting = existing[attributedPrefix]
    let allowedInitial: Set<Set<String>>
    if let nextExisting,
      [.sendStarted, .reconcileRequired, .escalated].contains(nextExisting.state)
    {
      allowedInitial = [states[attributedPrefix], states[attributedPrefix + 1]]
    } else {
      allowedInitial = [states[attributedPrefix]]
    }
    guard allowedInitial.contains(initialLabels) else {
      throw GitHubWorkflowLabelMutatorError.preconditionMismatch
    }

    var dispatched = Array(existing.prefix(attributedPrefix).compactMap { $0 })
    var current = initialLabels
    for index in attributedPrefix..<mutations.count {
      let before = states[index]
      let after = states[index + 1]
      let key = keys[index]
      if let known = existing[index] {
        if dispatched.last?.id != known.id { dispatched.append(known) }
        switch known.state {
        case .attributed:
          guard current == after else {
            throw GitHubWorkflowLabelMutatorError.preconditionMismatch
          }
          continue
        case .escalated:
          return result(
            disposition: .escalated,
            intents: dispatched,
            evidence: known.readBackEvidence
          )
        case .sendStarted, .reconcileRequired:
          let settled = try await reconcile(
            intentID: known.id,
            request: request,
            expected: before,
            desired: after
          )
          dispatched[dispatched.count - 1] = settled
          switch settled.state {
          case .attributed:
            current = try await workflowLabels(request.repository, number: request.number)
            guard current == after else {
              throw GitHubWorkflowLabelMutatorError.preconditionMismatch
            }
            continue
          case .retryAllowed:
            guard current == before else {
              throw GitHubWorkflowLabelMutatorError.preconditionMismatch
            }
          case .escalated:
            return result(
              disposition: .escalated,
              intents: dispatched,
              evidence: settled.readBackEvidence
            )
          default:
            throw GitHubWorkflowLabelMutatorError.unexpectedIntentState(settled.state)
          }
        case .prepared, .retryAllowed:
          guard current == before else {
            throw GitHubWorkflowLabelMutatorError.preconditionMismatch
          }
        }
      } else {
        guard current == before else {
          throw GitHubWorkflowLabelMutatorError.preconditionMismatch
        }
      }

      let dispatch: GitHubMutationDispatch
      do {
        dispatch = try await executor.prepareAndSend(
          jobID: request.jobID,
          idempotencyKey: key,
          mutation: .mutateWorkflowLabels,
          target: target,
          expectedStateDigest: expectedDigest,
          operation: mutations[index].1,
          now: request.now
        )
      } catch {
        guard let uncertain = try await intents.intent(idempotencyKey: key),
          uncertain.state == .sendStarted || uncertain.state == .reconcileRequired
        else {
          throw error
        }
        if dispatched.last?.id == uncertain.id {
          dispatched[dispatched.count - 1] = uncertain
        } else {
          dispatched.append(uncertain)
        }
        let settled = try await reconcile(
          intentID: uncertain.id,
          request: request,
          expected: before,
          desired: after
        )
        dispatched[dispatched.count - 1] = settled
        switch settled.state {
        case .attributed:
          current = after
          continue
        case .retryAllowed:
          return result(
            disposition: .retryAllowed,
            intents: dispatched,
            evidence: settled.readBackEvidence
          )
        case .escalated:
          return result(
            disposition: .escalated,
            intents: dispatched,
            evidence: settled.readBackEvidence
          )
        default:
          throw GitHubWorkflowLabelMutatorError.unexpectedIntentState(settled.state)
        }
      }
      if dispatched.last?.id == dispatch.intent.id {
        dispatched[dispatched.count - 1] = dispatch.intent
      } else {
        dispatched.append(dispatch.intent)
      }
      guard dispatch.response.disposition == .success else {
        let settled = try await reconcile(
          intentID: dispatch.intent.id,
          request: request,
          expected: before,
          desired: after
        )
        dispatched[dispatched.count - 1] = settled
        switch settled.state {
        case .attributed:
          current = after
          continue
        case .retryAllowed:
          return result(
            disposition: .retryAllowed,
            intents: dispatched,
            evidence: settled.readBackEvidence
          )
        case .escalated:
          return result(
            disposition: .escalated,
            intents: dispatched,
            evidence: settled.readBackEvidence
          )
        default:
          throw GitHubWorkflowLabelMutatorError.unexpectedIntentState(settled.state)
        }
      }
      let observed = try await workflowLabels(request.repository, number: request.number)
      guard observed == after else {
        let evidence = Self.digest(observed.sorted())
        let escalated = try await intents.settle(
          id: dispatch.intent.id,
          outcome: .escalation,
          evidenceDigest: evidence,
          now: now()
        )
        try await recordSettlement(escalated, evidenceSHA256: evidence)
        dispatched[dispatched.count - 1] = escalated
        return result(disposition: .escalated, intents: dispatched, evidence: evidence)
      }
      let evidence = Self.digest(observed.sorted())
      let attributed = try await intents.settle(
        id: dispatch.intent.id,
        outcome: .attributableEffect,
        evidenceDigest: evidence,
        now: now()
      )
      try await recordSettlement(attributed, evidenceSHA256: evidence)
      dispatched[dispatched.count - 1] = attributed
      current = after
    }
    guard current == normalizedDesired else {
      throw GitHubWorkflowLabelMutatorError.preconditionMismatch
    }
    return result(
      disposition: .attributed,
      intents: dispatched,
      evidence: Self.digest(current.sorted())
    )
  }

  private func reconcile(
    intentID: UUID,
    request: GitHubWorkflowLabelMutationRequest,
    expected: Set<String>,
    desired: Set<String>
  ) async throws -> MutationIntentRecord {
    let reader = GitHubJobMutationObservationReader(
      api: reads,
      expectation: .workflowLabels(
        repository: request.repository,
        number: request.number,
        expectation: WorkflowLabelExpectation(expected: expected, desired: desired)
      )
    )
    return try await MutationReconciliationRunner(
      store: intents,
      reader: reader,
      authority: authority,
      sleeper: sleeper,
      now: now
    ).reconcile(intentID: intentID)
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

  private func workflowLabels(
    _ repository: GitHubRepositoryCoordinates,
    number: Int
  ) async throws -> Set<String> {
    Self.normalized(
      Set(
        try await reads.listIssueLabels(
          owner: repository.owner,
          repository: repository.repository,
          number: number
        ).map(\.name).filter {
          let lowered = $0.lowercased()
          return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
        }
      )
    )
  }

  private func result(
    disposition: GitHubWorkflowLabelMutationDisposition,
    intents: [MutationIntentRecord],
    evidence: String?
  ) -> GitHubWorkflowLabelMutationResult {
    GitHubWorkflowLabelMutationResult(
      disposition: disposition,
      intentIDs: intents.map(\.id),
      evidenceDigest: evidence ?? Self.digest(["label-mutation", disposition.rawValue])
    )
  }

  private static let supportedOperations: Set<MutationOperation> = [
    .mutateWorkflowLabels, .pullRequestWorkflowLabel, .claimIssue, .publishComplexPlan,
    .blockIssue,
  ]

  private static func applying(
    _ mutation: GitHubOperation,
    to labels: Set<String>
  ) throws -> Set<String> {
    var result = labels
    switch mutation {
    case .addIssueLabels(_, _, _, let additions):
      result.formUnion(additions.map { $0.lowercased() })
    case .removeIssueLabel(_, _, _, let removal):
      result.remove(removal.lowercased())
    default:
      throw GitHubWorkflowLabelMutatorError.unsupportedOperation
    }
    return result
  }

  private static func normalized(_ labels: Set<String>) -> Set<String> {
    Set(labels.map { $0.lowercased() })
  }

  private static func digest(_ fields: [String]) -> String {
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }
}
