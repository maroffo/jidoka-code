import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Job-scoped approved command execution")
struct WorkspaceApprovedCommandExecutorTests {
  @Test("router command IDs execute only in the bound workspace")
  func executesBoundPlan() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-workspace-command-adapter")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    _ = try await fixture.commit(
      repository: repository,
      path: "tracked.txt",
      contents: "tracked\n",
      message: "test: seed"
    )
    let command = makeApprovedCommand(
      id: "status",
      kind: .gitRead,
      executable: "git",
      arguments: ["status", "--porcelain=v1"]
    )
    let plan = try makeFrozenPlan([command])
    let adapter = WorkspaceApprovedCommandExecutor(
      runner: VerificationCommandRunner(
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      ),
      workspace: repository
    )

    let evidence = try await adapter.execute(
      commandID: command.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      round: 1
    )

    #expect(evidence.succeeded)
    #expect(evidence.commandID == "status")
    #expect(evidence.definitionDigest == command.definitionDigest)
  }
}
