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
    plan: FrozenCommandPlan
  ) async throws -> VerificationCommandEvidence {
    try await runner.execute(
      commandID: commandID,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      workspace: workspace
    )
  }
}
