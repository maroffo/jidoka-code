import Foundation

public struct WorkspaceApprovedCommandExecutor: PiApprovedCommandExecuting, Sendable {
  private let runner: VerificationCommandRunner
  private let workspace: URL

  public init(
    runner: VerificationCommandRunner,
    workspace: URL
  ) {
    self.runner = runner
    self.workspace = workspace.standardizedFileURL
  }

  public func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    round: Int
  ) async throws -> VerificationCommandEvidence {
    guard (1...PiOrchestrationRouter.maximumRounds).contains(round) else {
      throw PiWorkflowRouterError.invalidInput
    }
    return try await runner.execute(
      commandID: commandID,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      workspace: workspace
    )
  }
}
