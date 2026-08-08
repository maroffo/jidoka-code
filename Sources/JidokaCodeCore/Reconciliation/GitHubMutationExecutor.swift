import Foundation

public struct GitHubMutationDispatch: Sendable {
  public let intent: MutationIntentRecord
  public let response: GitHubBrokerResponse
  public let requiresReadBack: Bool
}

public enum GitHubMutationExecutorError: Error, Equatable, Sendable {
  case readOperationForbidden
  case operationMismatch
  case gitTransportRequired
}

public actor GitHubMutationExecutor {
  private let intents: MutationIntentStore
  private let broker: any GitHubMutationSending

  public init(
    intents: MutationIntentStore,
    broker: any GitHubMutationSending
  ) {
    self.intents = intents
    self.broker = broker
  }

  public func prepareAndSend(
    jobID: UUID,
    idempotencyKey: String,
    mutation: MutationOperation,
    target: String,
    expectedStateDigest: String,
    operation: GitHubOperation,
    now: Date
  ) async throws -> GitHubMutationDispatch {
    guard operation.kind.isWrite else {
      throw GitHubMutationExecutorError.readOperationForbidden
    }
    guard mutation != .publishBranch else {
      throw GitHubMutationExecutorError.gitTransportRequired
    }
    guard Self.allows(mutation: mutation, operation: operation.kind) else {
      throw GitHubMutationExecutorError.operationMismatch
    }
    let requestDigest = try Self.requestDigest(operation)
    let prepared = try await intents.prepare(
      jobID: jobID,
      idempotencyKey: idempotencyKey,
      operation: mutation,
      target: target,
      expectedStateDigest: expectedStateDigest,
      requestDigest: requestDigest,
      now: now
    )

    let response: GitHubBrokerResponse
    do {
      let intentStore = intents
      response = try await broker.performMutation(operation) {
        _ = try await intentStore.markSendStarted(id: prepared.id, now: now)
      }
    } catch {
      if try await intents.intent(id: prepared.id)?.state == .sendStarted {
        _ = try? await intents.markReconcileRequired(id: prepared.id, now: now)
      }
      throw error
    }
    guard let started = try await intents.intent(id: prepared.id),
      started.state == .sendStarted
    else {
      throw MutationIntentStoreError.concurrentTransition
    }

    let evidence = Self.responseEvidence(response)
    switch response.disposition {
    case .authenticationOrConfigurationBlocked, .permissionBlocked,
      .staleConflict, .clientConfigurationBlocked, .validationBlocked,
      .targetGone, .absent:
      let terminal = try await intents.settle(
        id: started.id,
        outcome: .escalation,
        evidenceDigest: evidence,
        now: now
      )
      return GitHubMutationDispatch(
        intent: terminal,
        response: response,
        requiresReadBack: false
      )
    case .success, .notModified, .repositoryRedirect, .rateLimited,
      .reconcileRequired, .retryableRead, .escalation:
      let reconciling = try await intents.markReconcileRequired(
        id: started.id,
        now: now
      )
      return GitHubMutationDispatch(
        intent: reconciling,
        response: response,
        requiresReadBack: true
      )
    }
  }

  private static func allows(
    mutation: MutationOperation,
    operation: GitHubOperationKind
  ) -> Bool {
    switch mutation {
    case .bootstrapLabel:
      operation == .createRepositoryLabel
    case .createMarkerComment, .linkPullRequest:
      operation == .createComment
    case .mutateWorkflowLabels, .pullRequestWorkflowLabel:
      operation == .addIssueLabels || operation == .removeIssueLabel
    case .claimIssue, .publishComplexPlan, .blockIssue:
      operation == .createComment
        || operation == .addIssueLabels
        || operation == .removeIssueLabel
    case .createPullRequest:
      operation == .createPullRequest
    case .publishBranch:
      false
    }
  }

  private static func requestDigest(_ operation: GitHubOperation) throws -> String {
    let request = try GitHubRequestFactory.make(operation).request
    var bytes = Data()
    bytes.append(Data((request.httpMethod ?? "").utf8))
    bytes.append(0x0A)
    bytes.append(Data((request.url?.absoluteString ?? "").utf8))
    bytes.append(0x0A)
    if let body = request.httpBody { bytes.append(body) }
    return GitHubMarkerCodec.sha256(bytes)
  }

  private static func responseEvidence(_ response: GitHubBrokerResponse) -> String {
    var bytes = Data()
    bytes.append(Data(String(response.statusCode ?? 0).utf8))
    bytes.append(0x0A)
    bytes.append(Data(dispositionCode(response.disposition).utf8))
    bytes.append(0x0A)
    bytes.append(Data(GitHubMarkerCodec.sha256(response.body).utf8))
    return GitHubMarkerCodec.sha256(bytes)
  }

  private static func dispositionCode(_ disposition: GitHubResponseDisposition) -> String {
    switch disposition {
    case .success: "success"
    case .notModified: "not-modified"
    case .repositoryRedirect: "repository-redirect"
    case .authenticationOrConfigurationBlocked: "authentication-or-configuration-blocked"
    case .permissionBlocked: "permission-blocked"
    case .rateLimited(let directive):
      "rate-limited:\(directive.kind.rawValue):\(directive.notBefore.timeIntervalSince1970)"
    case .absent: "absent"
    case .staleConflict: "stale-conflict"
    case .clientConfigurationBlocked: "client-configuration-blocked"
    case .reconcileRequired: "reconcile-required"
    case .validationBlocked: "validation-blocked"
    case .targetGone: "target-gone"
    case .retryableRead: "retryable-read"
    case .escalation: "escalation"
    }
  }
}
