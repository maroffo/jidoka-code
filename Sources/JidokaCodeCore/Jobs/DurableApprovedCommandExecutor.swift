import Foundation

actor DurableApprovedCommandExecutor: PiApprovedCommandExecuting {
  private let job: JobRecord
  private let store: ApprovedCommandRunStore
  private let gate: ApprovedCommandExecutionGate
  private let runner: VerificationCommandRunner
  private let workspace: URL

  init(
    job: JobRecord,
    store: ApprovedCommandRunStore,
    gate: ApprovedCommandExecutionGate,
    runner: VerificationCommandRunner,
    workspace: URL
  ) {
    self.job = job
    self.store = store
    self.gate = gate
    self.runner = runner
    self.workspace = workspace.standardizedFileURL
  }

  func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    round: Int
  ) async throws -> VerificationCommandEvidence {
    try await execute(
      commandID: commandID,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      phase: .orchestration,
      round: round
    )
  }

  func executeBootstrap(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan
  ) async throws -> VerificationCommandEvidence {
    try await execute(
      commandID: commandID,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      phase: .bootstrap,
      round: 1
    )
  }

  private func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    phase: ApprovedCommandRunPhase,
    round: Int
  ) async throws -> VerificationCommandEvidence {
    guard expectedPlanDigest == plan.digest,
      let commandOrdinal = plan.commandOrder.firstIndex(of: commandID),
      let command = plan.commands[commandID],
      (1...PiOrchestrationRouter.maximumRounds).contains(round)
    else {
      throw VerificationCommandError.invalidPlan
    }
    let lease = try await gate.acquire()
    do {
      let result = try await executeWithLease(
        command: command,
        commandOrdinal: commandOrdinal,
        expectedPlanDigest: expectedPlanDigest,
        plan: plan,
        phase: phase,
        round: round
      )
      await gate.release(lease)
      return result
    } catch {
      await gate.release(lease)
      throw error
    }
  }

  private func executeWithLease(
    command: ApprovedCommand,
    commandOrdinal: Int,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    phase: ApprovedCommandRunPhase,
    round: Int
  ) async throws -> VerificationCommandEvidence {
    let preparedExecution = try await runner.prepare(
      commandID: command.id,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      workspace: workspace
    )
    let workspaceIdentity = try ApprovedCommandWorkspaceIdentity(url: workspace)
    var run = try await store.prepare(
      job: job,
      phase: phase,
      round: round,
      commandOrdinal: commandOrdinal,
      command: command,
      planSHA256: plan.digest,
      workspace: workspaceIdentity
    )
    switch run.state {
    case .resultAccepted:
      return try await replay(run: run, plan: plan)
    case .started, .unknown:
      throw ApprovedCommandRunStoreError.outcomeUnknown(run.id)
    case .superseded:
      throw ApprovedCommandRunStoreError.invalidTransition
    case .prepared:
      break
    }
    run = try await store.start(runID: run.id)
    if run.state == .resultAccepted {
      return try await replay(run: run, plan: plan)
    }
    guard run.state == .started else {
      throw ApprovedCommandRunStoreError.invalidTransition
    }
    let evidence: VerificationCommandEvidence
    do {
      evidence = try await runner.executePrepared(preparedExecution)
    } catch {
      _ = try? await store.markUnknown(runID: run.id)
      throw ApprovedCommandRunStoreError.outcomeUnknown(run.id)
    }
    do {
      _ = try await store.accept(runID: run.id, evidence: evidence)
      return evidence
    } catch {
      if let accepted = try? await store.acceptedEvidence(runID: run.id),
        accepted == evidence
      {
        return evidence
      }
      _ = try? await store.markUnknown(runID: run.id)
      throw error
    }
  }

  private func replay(
    run: ApprovedCommandRunRecord,
    plan: FrozenCommandPlan
  ) async throws -> VerificationCommandEvidence {
    guard let accepted = try await store.acceptedEvidence(runID: run.id),
      let expectedState = accepted.repositoryStateSHA256
    else {
      throw ApprovedCommandRunStoreError.divergentResult
    }
    if try await store.requiresRepositoryStateValidation(runID: run.id) {
      let observedState = try await runner.repositoryStateSHA256(
        workspace: workspace,
        plan: plan
      )
      guard observedState == expectedState else {
        throw ApprovedCommandRunStoreError.workspaceDiverged
      }
    }
    return accepted
  }
}
