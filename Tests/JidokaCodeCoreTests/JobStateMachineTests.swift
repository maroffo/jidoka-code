import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Job runtime and recovery state machines")
struct JobStateMachineTests {
  @Test("every normative runtime transition has the exact effect")
  func normativeTransitions() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    for transition in allowedTransitions {
      let effect = try JobStateMachine.transition(
        from: transition.from,
        event: transition.event,
        context: transitionContext(now: now)
      )
      #expect(effect.to == transition.to)
      #expect(effect.lease == transition.lease)
      #expect(effect.attemptDelta == transition.attemptDelta)
      #expect(effect.stepDelta == transition.stepDelta)
      #expect(effect.nextStep == transition.nextStep)
      #expect(effect.disposition == transition.disposition)
      #expect(effect.mutationGenerationDelta == transition.mutationGenerationDelta)
      if transition.to == .blocked {
        #expect(effect.terminalReason == "fixture")
      }
    }
  }

  @Test("all unlisted state and event pairs fail closed")
  func illegalTransitions() throws {
    let allowed = Set(allowedTransitions.map { Pair(state: $0.from, event: $0.event) })
    let now = Date(timeIntervalSince1970: 1_000)
    for state in JobState.allCases {
      for event in JobEvent.allCases where !allowed.contains(Pair(state: state, event: event)) {
        #expect(throws: JobStateMachineError.self) {
          _ = try JobStateMachine.transition(
            from: state,
            event: event,
            context: transitionContext(now: now)
          )
        }
      }
    }
  }

  @Test("retry requires a future persisted deadline")
  func retryDeadlineValidation() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    for event in [
      JobEvent.transientSetupFailure, .transientPiFailure, .transientLocalFailure, .safeRetry,
    ] {
      let state: JobState =
        switch event {
        case .transientSetupFailure: .preparing
        case .transientPiFailure: .runningPi
        case .transientLocalFailure: .executing
        default: .reconciling
        }
      #expect(throws: JobStateMachineError.missingFutureDeadline) {
        _ = try JobStateMachine.transition(
          from: state,
          event: event,
          context: JobTransitionContext(
            now: now,
            reason: "fixture",
            notBefore: now
          )
        )
      }
    }
  }

  @Test("success requires exact SHA-256 acceptance evidence")
  func successEvidenceValidation() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    for digest in [nil, "", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
      #expect(throws: JobStateMachineError.missingAcceptanceEvidence) {
        _ = try JobStateMachine.transition(
          from: .reconciling,
          event: .acceptanceComplete,
          context: JobTransitionContext(
            now: now,
            reason: "fixture",
            acceptanceEvidenceDigest: digest
          )
        )
      }
    }
  }

  @Test("recovery is total and preserves attempts, steps, and deadlines")
  func recoveryMatrix() {
    let now = Date(timeIntervalSince1970: 1_000)
    let future = now.addingTimeInterval(60)
    let activeStates: Set<JobState> = [
      .leased, .preparing, .runningPi, .executing, .reconciling,
    ]

    for state in JobState.allCases {
      let snapshot = JobRuntimeSnapshot(
        state: state,
        attempt: state == .discovered ? 0 : 3,
        currentStep: 7,
        notBefore: state == .retryBackoff ? future : nil
      )
      let recovered = JobRecovery.recover(snapshot, now: now)
      #expect(recovered.currentStep == 7)
      if state == .discovered {
        #expect(recovered.state == .queued)
        #expect(recovered.attempt == 1)
      } else {
        #expect(recovered.attempt == 3)
      }
      if activeStates.contains(state) {
        #expect(recovered.state == .reconciliationQueued)
        #expect(recovered.clearStaleLease)
        #expect(recovered.transitionRequired)
      }
      if state == .awaitingResolution {
        #expect(recovered.scheduleLateChecks)
        #expect(!recovered.transitionRequired)
      }
      if state == .retryBackoff {
        #expect(recovered.state == .retryBackoff)
        #expect(recovered.notBefore == future)
      }
      if state.isTerminal {
        #expect(recovered.state == state)
        #expect(!recovered.transitionRequired)
      }
    }

    let elapsed = JobRecovery.recover(
      JobRuntimeSnapshot(
        state: .retryBackoff,
        attempt: 4,
        currentStep: 2,
        notBefore: now.addingTimeInterval(-1)
      ),
      now: now
    )
    #expect(elapsed.state == .queued)
    #expect(elapsed.attempt == 4)
    #expect(elapsed.currentStep == 2)
    #expect(elapsed.notBefore == nil)
  }

  @Test("claim generations preserve distinct ready, approved, and stale paths")
  func claimGenerations() throws {
    let ready = try ClaimStateMachine.next(
      kind: .ready,
      generation: 1,
      priorGeneration: nil
    )
    #expect(ready.expectedLabels == ["agent:ready"])
    #expect(ready.desiredLabels == ["agent:wip"])
    #expect(ready.firstStep == .claimReady)

    let approved = try ClaimStateMachine.next(
      kind: .approvedComplex,
      generation: 3,
      priorGeneration: 2
    )
    #expect(approved.expectedLabels == ["agent:plan-review", "plan:approved"])
    #expect(approved.desiredLabels == ["agent:wip"])
    #expect(approved.firstStep == .claimApprovedPlan)
    #expect(
      ClaimStateMachine.staleApprovalSequence == [
        .consumeStaleApproval, .replan, .publishPlan,
      ])

    #expect(throws: ClaimStateMachineError.invalidGeneration) {
      _ = try ClaimStateMachine.next(
        kind: .approvedComplex,
        generation: 2,
        priorGeneration: 2
      )
    }
  }

  @Test("multi-step transitions advance exactly once and feedback does not advance")
  func multiStepContinuation() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    for (state, event) in [
      (JobState.runningPi, JobEvent.piCompleted),
      (.executing, .localStepCompletedMore),
      (.reconciling, .effectAttributedMore),
    ] {
      let effect = try JobStateMachine.transition(
        from: state,
        event: event,
        context: transitionContext(now: now)
      )
      #expect(effect.stepDelta == 1)
      #expect(!effect.to.isTerminal)
    }
    let routed = try JobStateMachine.transition(
      from: .reconciling,
      event: .effectAttributedMore,
      context: JobTransitionContext(
        now: now,
        reason: "continue workflow",
        nextStep: .publish
      )
    )
    #expect(routed.nextStep == .publish)

    let feedback = try JobStateMachine.transition(
      from: .executing,
      event: .localFailureWithinBudget,
      context: transitionContext(now: now)
    )
    #expect(feedback.stepDelta == 0)
    #expect(feedback.nextStep == .writerFeedback)
  }
}

private struct Pair: Hashable {
  let state: JobState
  let event: JobEvent
}

private struct ExpectedTransition {
  let from: JobState
  let event: JobEvent
  let to: JobState
  let lease: JobLeaseEffect
  let attemptDelta: Int
  let stepDelta: Int
  let nextStep: JobStepKind?
  let disposition: ObjectDispositionState?
  let mutationGenerationDelta: Int

  init(
    _ from: JobState,
    _ event: JobEvent,
    _ to: JobState,
    lease: JobLeaseEffect = .none,
    attemptDelta: Int = 0,
    stepDelta: Int = 0,
    nextStep: JobStepKind? = nil,
    disposition: ObjectDispositionState? = nil,
    mutationGenerationDelta: Int = 0
  ) {
    self.from = from
    self.event = event
    self.to = to
    self.lease = lease
    self.attemptDelta = attemptDelta
    self.stepDelta = stepDelta
    self.nextStep = nextStep
    self.disposition = disposition
    self.mutationGenerationDelta = mutationGenerationDelta
  }
}

private let allowedTransitions: [ExpectedTransition] = [
  .init(.discovered, .enqueue, .queued, attemptDelta: 1),
  .init(.queued, .acquireLease, .leased, lease: .acquire),
  .init(.leased, .inputsValidated, .preparing, lease: .retain),
  .init(.preparing, .selectPiStep, .runningPi, lease: .retain),
  .init(.preparing, .selectLocalStep, .executing, lease: .retain),
  .init(.preparing, .transientSetupFailure, .retryBackoff, lease: .release, attemptDelta: 1),
  .init(.preparing, .permanentSetupFailure, .blocked, lease: .release),
  .init(.runningPi, .piCompleted, .executing, lease: .retain, stepDelta: 1),
  .init(.runningPi, .transientPiFailure, .retryBackoff, lease: .release, attemptDelta: 1),
  .init(.runningPi, .piInterruptedUnknown, .reconciliationQueued, lease: .clearStale),
  .init(.runningPi, .piPermanentFailure, .blocked, lease: .release),
  .init(.executing, .localStepCompletedMore, .preparing, lease: .retain, stepDelta: 1),
  .init(.executing, .inputsInvalidated, .preparing, lease: .retain, nextStep: .triage),
  .init(.executing, .mutationNeedsAttribution, .reconciling, lease: .retain),
  .init(.executing, .transientLocalFailure, .retryBackoff, lease: .release, attemptDelta: 1),
  .init(
    .executing, .localFailureWithinBudget, .preparing, lease: .retain, nextStep: .writerFeedback),
  .init(.executing, .localPermanentFailure, .blocked, lease: .release),
  .init(.reconciling, .inputsInvalidated, .preparing, lease: .retain, nextStep: .triage),
  .init(.reconciling, .effectAttributedMore, .preparing, lease: .retain, stepDelta: 1),
  .init(.reconciling, .acceptanceComplete, .succeeded, lease: .release, disposition: .attributed),
  .init(.reconciling, .humanGatePublished, .waitingHuman, lease: .release, disposition: .inFlight),
  .init(.reconciling, .safeRetry, .retryBackoff, lease: .release, attemptDelta: 1),
  .init(
    .reconciling, .ambiguousCreate, .awaitingResolution, lease: .release, disposition: .ambiguous),
  .init(.reconciling, .reconciliationPermanentFailure, .blocked, lease: .release),
  .init(.retryBackoff, .retryDeadlineReached, .queued),
  .init(
    .waitingHuman, .approvalFresh, .queued, attemptDelta: 1, stepDelta: 1,
    nextStep: .claimApprovedPlan, disposition: .inFlight),
  .init(
    .waitingHuman, .approvalStale, .queued, attemptDelta: 1, stepDelta: 1,
    nextStep: .consumeStaleApproval, disposition: .inFlight),
  .init(.awaitingResolution, .lateEffectAttributed, .reconciliationQueued, disposition: .inFlight),
  .init(
    .awaitingResolution, .humanRetryAuthorized, .queued, attemptDelta: 1,
    disposition: .humanRetryAuthorized, mutationGenerationDelta: 1),
  .init(.awaitingResolution, .humanAbort, .blocked, disposition: .ambiguous),
  .init(.reconciliationQueued, .acquireRecoveryLease, .reconciling, lease: .acquireRecovery),
]

private func transitionContext(now: Date) -> JobTransitionContext {
  JobTransitionContext(
    now: now,
    reason: "fixture",
    notBefore: now.addingTimeInterval(60),
    acceptanceEvidenceDigest: String(repeating: "a", count: 64),
    artifactID: "artifact"
  )
}
