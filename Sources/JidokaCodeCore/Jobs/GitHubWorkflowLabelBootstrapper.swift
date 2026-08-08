import Foundation

public struct GitHubWorkflowLabelDefinition: Equatable, Sendable {
  public let name: String
  public let color: String
  public let description: String

  public init(name: String, color: String, description: String) {
    self.name = name
    self.color = color
    self.description = description
  }

  var createRequest: GitHubCreateLabel {
    GitHubCreateLabel(name: name, color: color, description: description)
  }
}

public enum GitHubWorkflowLabelBootstrapDisposition: String, Equatable, Sendable {
  case ready
  case escalated
}

public struct GitHubWorkflowLabelBootstrapResult: Sendable {
  public let disposition: GitHubWorkflowLabelBootstrapDisposition
  public let preservedNames: [String]
  public let createdNames: [String]
  public let intentIDs: [UUID]
}

public enum GitHubWorkflowLabelBootstrapperError: Error, Equatable, Sendable {
  case invalidRequest
  case unexpectedIntentState(MutationIntentState)
}

public actor GitHubWorkflowLabelBootstrapper {
  public static let definitions: [GitHubWorkflowLabelDefinition] = [
    GitHubWorkflowLabelDefinition(
      name: "agent:ready",
      color: "1f883d",
      description: "Ready for an automated implementation claim"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:needs-spec",
      color: "bf8700",
      description: "Needs material specification before implementation"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:human",
      color: "8250df",
      description: "Requires human ownership"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:wip",
      color: "0969da",
      description: "Claimed by Jidoka Code"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:plan-review",
      color: "fbca04",
      description: "Complex plan awaits exact human approval"
    ),
    GitHubWorkflowLabelDefinition(
      name: "plan:approved",
      color: "0e8a16",
      description: "Exact complex plan approved by a human"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:blocked",
      color: "b60205",
      description: "Implementation stopped by a safety or verification gate"
    ),
    GitHubWorkflowLabelDefinition(
      name: "agent:qa",
      color: "5319e7",
      description: "Implementation pull request is ready for independent review"
    ),
  ]

  private let executor: GitHubMutationExecutor
  private let intents: MutationIntentStore
  private let reads: any GitHubMutationReadAPI
  private let sleeper: any MutationReconciliationSleeper
  private let now: @Sendable () -> Date

  public init(
    executor: GitHubMutationExecutor,
    intents: MutationIntentStore,
    reads: any GitHubMutationReadAPI,
    sleeper: any MutationReconciliationSleeper = SystemMutationReconciliationSleeper(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.executor = executor
    self.intents = intents
    self.reads = reads
    self.sleeper = sleeper
    self.now = now
  }

  public func bootstrap(
    jobID: UUID,
    repository: GitHubRepositoryCoordinates,
    at requestedAt: Date
  ) async throws -> GitHubWorkflowLabelBootstrapResult {
    guard GitHubInputValidation.validOwner(repository.owner),
      GitHubInputValidation.validRepository(repository.repository)
    else {
      throw GitHubWorkflowLabelBootstrapperError.invalidRequest
    }
    var preserved: [String] = []
    var created: [String] = []
    var intentIDs: [UUID] = []
    for definition in Self.definitions {
      if try await reads.repositoryLabel(
        owner: repository.owner,
        repository: repository.repository,
        label: definition.name
      ) != nil {
        preserved.append(definition.name)
        continue
      }
      let expectedDigest = Self.digest([
        definition.name, definition.color, definition.description,
      ])
      let key = Self.digest([
        jobID.uuidString.lowercased(),
        MutationOperation.bootstrapLabel.rawValue,
        repository.owner,
        repository.repository,
        definition.name,
      ])
      let existing = try await intents.intent(idempotencyKey: key)
      if let existing, existing.state == .attributed || existing.state == .escalated {
        return GitHubWorkflowLabelBootstrapResult(
          disposition: .escalated,
          preservedNames: preserved.sorted(),
          createdNames: created.sorted(),
          intentIDs: intentIDs + [existing.id]
        )
      }
      let shouldSend =
        existing == nil
        || existing?.state == .prepared
        || existing?.state == .retryAllowed
      let intent: MutationIntentRecord
      if shouldSend {
        do {
          intent = try await executor.prepareAndSend(
            jobID: jobID,
            idempotencyKey: key,
            mutation: .bootstrapLabel,
            target: "\(repository.owner)/\(repository.repository)/labels/\(definition.name)",
            expectedStateDigest: expectedDigest,
            operation: .createRepositoryLabel(
              owner: repository.owner,
              repository: repository.repository,
              request: definition.createRequest
            ),
            now: requestedAt
          ).intent
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
        throw GitHubWorkflowLabelBootstrapperError.invalidRequest
      }
      intentIDs.append(intent.id)
      if intent.state == .escalated {
        return GitHubWorkflowLabelBootstrapResult(
          disposition: .escalated,
          preservedNames: preserved.sorted(),
          createdNames: created.sorted(),
          intentIDs: intentIDs
        )
      }
      let reader = GitHubJobMutationObservationReader(
        api: reads,
        expectation: .bootstrapLabel(
          repository: repository,
          label: definition.createRequest
        )
      )
      let settled = try await MutationReconciliationRunner(
        store: intents,
        reader: reader,
        sleeper: sleeper,
        now: now
      ).reconcile(intentID: intent.id)
      switch settled.state {
      case .attributed:
        created.append(definition.name)
      case .escalated:
        return GitHubWorkflowLabelBootstrapResult(
          disposition: .escalated,
          preservedNames: preserved.sorted(),
          createdNames: created.sorted(),
          intentIDs: intentIDs
        )
      default:
        throw GitHubWorkflowLabelBootstrapperError.unexpectedIntentState(settled.state)
      }
    }
    return GitHubWorkflowLabelBootstrapResult(
      disposition: .ready,
      preservedNames: preserved.sorted(),
      createdNames: created.sorted(),
      intentIDs: intentIDs
    )
  }

  private static func digest(_ fields: [String]) -> String {
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return GitHubMarkerCodec.sha256(Data(framed.utf8))
  }
}
