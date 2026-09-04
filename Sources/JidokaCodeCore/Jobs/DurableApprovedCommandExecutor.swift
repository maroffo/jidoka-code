import Foundation

actor DurableApprovedCommandExecutor: PiApprovedCommandExecuting {
  private let job: JobRecord
  private let store: ApprovedCommandRunStore
  private let gate: ApprovedCommandExecutionGate
  private let runner: VerificationCommandRunner
  private let authority: any RolloutEffectAuthorizing
  private let workspace: URL
  private let now: @Sendable () -> Date

  init(
    job: JobRecord,
    store: ApprovedCommandRunStore,
    gate: ApprovedCommandExecutionGate,
    runner: VerificationCommandRunner,
    authority: any RolloutEffectAuthorizing,
    workspace: URL,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.job = job
    self.store = store
    self.gate = gate
    self.runner = runner
    self.authority = authority
    self.workspace = workspace.standardizedFileURL
    self.now = now
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
    let workspaceHeadSHA = try await runner.repositoryHeadSHA(workspace: workspace)
    let effect = RolloutApprovedCommandEffect(
      jobID: job.id,
      commandID: command.id,
      definitionSHA256: command.definitionDigest,
      planSHA256: plan.digest,
      workspaceHeadSHA: workspaceHeadSHA,
      phase: phase,
      round: round,
      ordinal: commandOrdinal
    )
    var permit: RolloutEffectPermit? = try await authority.reserveApprovedCommand(
      effect,
      now: now()
    )
    var processBoundaryCrossed = false
    do {
      guard let activePermit = permit else {
        throw RolloutAuthorityError.effectAdmissionClosed
      }
      try await authority.bindApprovedCommandReservation(
        activePermit,
        effect: effect,
        runID: run.id,
        now: now()
      )
      run = try await store.start(runID: run.id)
      let evidence: VerificationCommandEvidence
      if run.state == .resultAccepted {
        evidence = try await replay(run: run, plan: plan)
      } else {
        guard run.state == .started else {
          throw ApprovedCommandRunStoreError.invalidTransition
        }
        do {
          guard try await runner.repositoryHeadSHA(workspace: workspace) == workspaceHeadSHA else {
            throw VerificationCommandError.repositoryStateUnavailable
          }
          guard let activePermit = permit else {
            throw RolloutAuthorityError.effectAdmissionClosed
          }
          try await authority.verifyApprovedCommandPermit(activePermit, effect: effect)
          processBoundaryCrossed = true
          evidence = try await runner.executePrepared(preparedExecution)
        } catch {
          let launchError = error
          if processBoundaryCrossed {
            _ = try? await store.markUnknown(runID: run.id)
            throw ApprovedCommandRunStoreError.outcomeUnknown(run.id)
          }
          do {
            run = try await store.recordLaunchDenied(runID: run.id)
          } catch {
            _ = try? await store.markUnknown(
              runID: run.id,
              detailCode: "LAUNCH_DENIAL_RECORD_UNKNOWN"
            )
            throw ApprovedCommandRunStoreError.outcomeUnknown(run.id)
          }
          throw launchError
        }
        do {
          _ = try await store.accept(runID: run.id, evidence: evidence)
        } catch {
          if let accepted = try? await store.acceptedEvidence(runID: run.id),
            accepted == evidence
          {
            // The durable result committed before the interrupted acknowledgement.
          } else {
            _ = try? await store.markUnknown(runID: run.id)
            throw error
          }
        }
      }
      if let activePermit = permit {
        try await authority.settleEffect(
          activePermit,
          evidenceSHA256: try Self.evidenceSHA256(evidence),
          now: now()
        )
        permit = nil
      }
      return evidence
    } catch {
      if let permit, !processBoundaryCrossed {
        try await authority.settleEffect(
          permit,
          evidenceSHA256: GitHubMarkerCodec.sha256(
            Data(String(reflecting: type(of: error)).utf8)
          ),
          now: now()
        )
      }
      throw error
    }
  }

  private static func evidenceSHA256(
    _ evidence: VerificationCommandEvidence
  ) throws -> String {
    RolloutCanonicalJSON.sha256(try RolloutCanonicalJSON.encode(evidence))
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
