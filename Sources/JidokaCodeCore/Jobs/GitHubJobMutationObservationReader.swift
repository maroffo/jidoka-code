import Foundation

public struct GitHubRepositoryCoordinates: Equatable, Sendable {
  public let owner: String
  public let repository: String

  public init(owner: String, repository: String) {
    self.owner = owner
    self.repository = repository
  }
}

public enum GitHubJobMutationExpectation: Equatable, Sendable {
  case bootstrapLabel(
    repository: GitHubRepositoryCoordinates,
    label: GitHubCreateLabel
  )
  case marker(
    repository: GitHubRepositoryCoordinates,
    number: Int,
    expectation: GitHubMarkerExpectation
  )
  case workflowLabels(
    repository: GitHubRepositoryCoordinates,
    number: Int,
    expectation: WorkflowLabelExpectation
  )
  case markerAndLabels(
    repository: GitHubRepositoryCoordinates,
    number: Int,
    marker: GitHubMarkerExpectation,
    labels: WorkflowLabelExpectation
  )
  case pullRequest(
    repository: GitHubRepositoryCoordinates,
    expectation: PullRequestMutationExpectation
  )
  case branch(
    repository: GitHubRepositoryCoordinates,
    branch: String,
    exactSHA: String
  )
}

public enum GitHubJobMutationObservationError: Error, Equatable, Sendable {
  case invalidExpectation
  case operationMismatch
}

public struct GitHubJobMutationObservationReader: MutationObservationReader, Sendable {
  private let api: any GitHubMutationReadAPI
  private let expectation: GitHubJobMutationExpectation

  public init(
    api: any GitHubMutationReadAPI,
    expectation: GitHubJobMutationExpectation
  ) {
    self.api = api
    self.expectation = expectation
  }

  public func observe(
    intent: MutationIntentRecord,
    attempt: Int
  ) async throws -> MutationObservation {
    guard (1...MutationReconciliationPolicy.delayedReadSeconds.count).contains(attempt) else {
      throw GitHubJobMutationObservationError.invalidExpectation
    }
    switch expectation {
    case .bootstrapLabel(let repository, let expected):
      guard intent.operation == .bootstrapLabel else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      return GitHubMutationObservations.bootstrapLabel(
        expected: expected,
        actual: try await api.repositoryLabel(
          owner: repository.owner,
          repository: repository.repository,
          label: expected.name
        )
      )
    case .marker(let repository, let number, let expected):
      guard Self.markerOperations.contains(intent.operation) else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      return GitHubMutationObservations.markerComment(
        comments: try await markerComments(repository: repository, number: number),
        expectation: expected
      )
    case .workflowLabels(let repository, let number, let expected):
      guard Self.labelOperations.contains(intent.operation) else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      return GitHubMutationObservations.workflowLabels(
        currentWorkflowLabels: try await workflowLabels(
          repository: repository,
          number: number
        ),
        expectation: expected
      )
    case .markerAndLabels(let repository, let number, let marker, let labels):
      guard [.claimIssue, .publishComplexPlan, .blockIssue].contains(intent.operation) else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      async let comments = markerComments(repository: repository, number: number)
      async let currentLabels = workflowLabels(repository: repository, number: number)
      let observedComments = try await comments
      let observedLabels = try await currentLabels
      return GitHubMutationObservations.composite(
        marker: GitHubMutationObservations.markerComment(
          comments: observedComments,
          expectation: marker
        ),
        labels: GitHubMutationObservations.workflowLabels(
          currentWorkflowLabels: observedLabels,
          expectation: labels
        )
      )
    case .pullRequest(let repository, let expected):
      guard intent.operation == .createPullRequest else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      let candidates = try await api.lookupPullRequests(
        owner: repository.owner,
        repository: repository.repository,
        head: expected.head,
        base: expected.base
      )
      let exact: GitHubPullRequest?
      if candidates.count == 1, let number = candidates.first?.number {
        exact = try await api.pullRequest(
          owner: repository.owner,
          repository: repository.repository,
          number: number
        )
      } else {
        exact = nil
      }
      return GitHubMutationObservations.pullRequest(
        candidates: candidates,
        exact: exact,
        expectation: expected
      )
    case .branch(let repository, let branch, let exactSHA):
      guard intent.operation == .publishBranch else {
        throw GitHubJobMutationObservationError.operationMismatch
      }
      return GitHubMutationObservations.branchReference(
        actual: try await api.branchReference(
          owner: repository.owner,
          repository: repository.repository,
          branch: branch
        ),
        branch: branch,
        exactSHA: exactSHA
      )
    }
  }

  private func markerComments(
    repository: GitHubRepositoryCoordinates,
    number: Int
  ) async throws -> [GitHubMarkerComment] {
    try await api.listComments(
      owner: repository.owner,
      repository: repository.repository,
      number: number
    ).map {
      GitHubMarkerComment(id: $0.id, authorID: $0.user.id, body: $0.body)
    }
  }

  private func workflowLabels(
    repository: GitHubRepositoryCoordinates,
    number: Int
  ) async throws -> Set<String> {
    Set(
      try await api.listIssueLabels(
        owner: repository.owner,
        repository: repository.repository,
        number: number
      ).map(\.name).filter(Self.isWorkflowLabel)
    )
  }

  private static let markerOperations: Set<MutationOperation> = [
    .createMarkerComment, .claimIssue, .linkPullRequest, .publishComplexPlan, .blockIssue,
  ]
  private static let labelOperations: Set<MutationOperation> = [
    .mutateWorkflowLabels, .pullRequestWorkflowLabel, .claimIssue, .publishComplexPlan,
    .blockIssue,
  ]

  private static func isWorkflowLabel(_ value: String) -> Bool {
    let lowered = value.lowercased()
    return lowered.hasPrefix("agent:") || lowered.hasPrefix("plan:")
  }
}
