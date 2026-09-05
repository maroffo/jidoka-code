import Foundation

public enum JobState: String, CaseIterable, Codable, Sendable {
  case discovered
  case queued
  case leased
  case preparing
  case runningPi
  case executing
  case reconciling
  case retryBackoff
  case waitingHuman
  case awaitingResolution
  case reconciliationQueued
  case succeeded
  case blocked

  public var isTerminal: Bool {
    self == .succeeded || self == .blocked
  }
}

public enum JobPriority: Int, CaseIterable, Codable, Comparable, Sendable {
  case recovery = 0
  case approvedComplex = 1
  case prReview = 2
  case issueImplementation = 3
  case triage = 4

  public static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum JobStepKind: String, CaseIterable, Codable, Sendable {
  case review
  case triage
  case plan
  case claimReady
  case claimApprovedPlan
  case consumeStaleApproval
  case replan
  case publishPlan
  case writePlan
  case writerFeedback
  case implement
  case orchestrate
  case verify
  case push
  case openPullRequest
  case linkPullRequest
  case qa
  case enqueueReview
  case publish
  case reconcile
}

public enum JobEvent: String, CaseIterable, Codable, Sendable {
  case enqueue
  case acquireLease
  case inputsValidated
  case selectPiStep
  case selectLocalStep
  case transientSetupFailure
  case permanentSetupFailure
  case piCompleted
  case transientPiFailure
  case piInterruptedUnknown
  case piPermanentFailure
  case localStepCompletedMore
  case phaseCheckpoint
  case inputsInvalidated
  case mutationNeedsAttribution
  case transientLocalFailure
  case localFailureWithinBudget
  case localPermanentFailure
  case effectAttributedMore
  case acceptanceComplete
  case humanGatePublished
  case safeRetry
  case ambiguousCreate
  case reconciliationPermanentFailure
  case retryDeadlineReached
  case approvalFresh
  case approvalStale
  case lateEffectAttributed
  case humanRetryAuthorized
  case humanAbort
  case operatorRetire
  case operatorRetryConfigurationRepair
  case acquireRecoveryLease
  case canaryTopologyRecovered
}

public enum JobLeaseEffect: String, Codable, Sendable {
  case none
  case acquire
  case retain
  case release
  case clearStale
  case acquireRecovery
}

public enum JobDeadlineEffect: Equatable, Sendable {
  case retain
  case clear
  case set(Date)
}

public enum ObjectDispositionState: String, CaseIterable, Codable, Sendable {
  case inFlight
  case attributed
  case ambiguous
  case humanRetryAuthorized
  case superseded

  public var suppressesDiscovery: Bool { true }
}

public struct JobTransitionContext: Equatable, Sendable {
  public let now: Date
  public let reason: String
  public let notBefore: Date?
  public let acceptanceEvidenceDigest: String?
  public let artifactID: String?
  public let nextStep: JobStepKind?

  public init(
    now: Date,
    reason: String,
    notBefore: Date? = nil,
    acceptanceEvidenceDigest: String? = nil,
    artifactID: String? = nil,
    nextStep: JobStepKind? = nil
  ) {
    self.now = now
    self.reason = reason
    self.notBefore = notBefore
    self.acceptanceEvidenceDigest = acceptanceEvidenceDigest
    self.artifactID = artifactID
    self.nextStep = nextStep
  }
}

public struct JobTransitionEffect: Equatable, Sendable {
  public let from: JobState
  public let to: JobState
  public let lease: JobLeaseEffect
  public let attemptDelta: Int
  public let stepDelta: Int
  public let deadline: JobDeadlineEffect
  public let nextStep: JobStepKind?
  public let disposition: ObjectDispositionState?
  public let mutationGenerationDelta: Int
  public let terminalReason: String?
  public let clearsTerminalReason: Bool

  init(
    from: JobState,
    to: JobState,
    lease: JobLeaseEffect = .none,
    attemptDelta: Int = 0,
    stepDelta: Int = 0,
    deadline: JobDeadlineEffect = .retain,
    nextStep: JobStepKind? = nil,
    disposition: ObjectDispositionState? = nil,
    mutationGenerationDelta: Int = 0,
    terminalReason: String? = nil,
    clearsTerminalReason: Bool = false
  ) {
    self.from = from
    self.to = to
    self.lease = lease
    self.attemptDelta = attemptDelta
    self.stepDelta = stepDelta
    self.deadline = deadline
    self.nextStep = nextStep
    self.disposition = disposition
    self.mutationGenerationDelta = mutationGenerationDelta
    self.terminalReason = terminalReason
    self.clearsTerminalReason = clearsTerminalReason
  }
}

public enum JobStateMachineError: Error, Equatable, Sendable {
  case invalidTransition(from: JobState, event: JobEvent)
  case missingFutureDeadline
  case missingAcceptanceEvidence
  case invalidReason
}

public enum JobStateMachine {
  public static func transition(
    from state: JobState,
    event: JobEvent,
    context: JobTransitionContext
  ) throws -> JobTransitionEffect {
    guard !context.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw JobStateMachineError.invalidReason
    }

    switch (state, event) {
    case (.discovered, .enqueue):
      return effect(state, .queued, attemptDelta: 1)
    case (.queued, .acquireLease):
      return effect(state, .leased, lease: .acquire)
    case (.leased, .inputsValidated):
      return effect(state, .preparing, lease: .retain)
    case (.preparing, .selectPiStep):
      return effect(state, .runningPi, lease: .retain)
    case (.preparing, .selectLocalStep):
      return effect(state, .executing, lease: .retain)
    case (.preparing, .transientSetupFailure):
      return try retryEffect(from: state, context: context)
    case (.preparing, .permanentSetupFailure):
      return blockedEffect(from: state, context: context)
    case (.runningPi, .piCompleted):
      return effect(
        state,
        .executing,
        lease: .retain,
        stepDelta: 1,
        nextStep: context.nextStep
      )
    case (.runningPi, .transientPiFailure):
      return try retryEffect(from: state, context: context)
    case (.runningPi, .piInterruptedUnknown):
      return effect(state, .reconciliationQueued, lease: .clearStale)
    case (.runningPi, .piPermanentFailure):
      return blockedEffect(from: state, context: context)
    case (.executing, .localStepCompletedMore):
      return effect(
        state,
        .preparing,
        lease: .retain,
        stepDelta: 1,
        nextStep: context.nextStep
      )
    case (.executing, .phaseCheckpoint):
      return effect(
        state,
        .queued,
        lease: .release,
        stepDelta: 1,
        nextStep: context.nextStep
      )
    case (.preparing, .phaseCheckpoint):
      return effect(
        state,
        .queued,
        lease: .release,
        nextStep: context.nextStep
      )
    case (.reconciling, .phaseCheckpoint):
      return effect(
        state,
        .queued,
        lease: .release,
        stepDelta: 1,
        nextStep: context.nextStep
      )
    case (.executing, .inputsInvalidated):
      return effect(state, .preparing, lease: .retain, nextStep: .triage)
    case (.executing, .mutationNeedsAttribution):
      return effect(state, .reconciling, lease: .retain)
    case (.executing, .transientLocalFailure):
      return try retryEffect(from: state, context: context)
    case (.executing, .localFailureWithinBudget):
      return effect(
        state,
        .preparing,
        lease: .retain,
        nextStep: .writerFeedback
      )
    case (.executing, .localPermanentFailure):
      return blockedEffect(from: state, context: context)
    case (.reconciling, .inputsInvalidated):
      return effect(state, .preparing, lease: .retain, nextStep: .triage)
    case (.reconciling, .effectAttributedMore):
      return effect(
        state,
        .preparing,
        lease: .retain,
        stepDelta: 1,
        nextStep: context.nextStep
      )
    case (.reconciling, .acceptanceComplete):
      guard isSHA256(context.acceptanceEvidenceDigest) else {
        throw JobStateMachineError.missingAcceptanceEvidence
      }
      return effect(
        state,
        .succeeded,
        lease: .release,
        disposition: .attributed
      )
    case (.reconciling, .humanGatePublished):
      return effect(
        state,
        .waitingHuman,
        lease: .release,
        disposition: .inFlight
      )
    case (.reconciling, .safeRetry):
      return try retryEffect(from: state, context: context)
    case (.reconciling, .ambiguousCreate):
      return effect(
        state,
        .awaitingResolution,
        lease: .release,
        disposition: .ambiguous
      )
    case (.reconciling, .reconciliationPermanentFailure):
      return blockedEffect(from: state, context: context)
    case (.retryBackoff, .retryDeadlineReached):
      return effect(state, .queued, deadline: .clear)
    case (.waitingHuman, .approvalFresh):
      return effect(
        state,
        .queued,
        attemptDelta: 1,
        stepDelta: 1,
        deadline: .clear,
        nextStep: .claimApprovedPlan,
        disposition: .inFlight
      )
    case (.waitingHuman, .approvalStale):
      return effect(
        state,
        .queued,
        attemptDelta: 1,
        stepDelta: 1,
        deadline: .clear,
        nextStep: .consumeStaleApproval,
        disposition: .inFlight
      )
    case (.awaitingResolution, .lateEffectAttributed):
      return effect(
        state,
        .reconciliationQueued,
        disposition: .inFlight
      )
    case (.awaitingResolution, .humanRetryAuthorized):
      return effect(
        state,
        .queued,
        attemptDelta: 1,
        deadline: .clear,
        disposition: .humanRetryAuthorized,
        mutationGenerationDelta: 1
      )
    case (.awaitingResolution, .humanAbort):
      return effect(
        state,
        .blocked,
        disposition: .ambiguous,
        terminalReason: context.reason
      )
    case (.queued, .operatorRetire), (.blocked, .operatorRetire):
      return effect(
        state,
        .blocked,
        deadline: .clear,
        disposition: .superseded,
        terminalReason: context.reason
      )
    case (.blocked, .operatorRetryConfigurationRepair):
      return effect(
        state,
        .queued,
        attemptDelta: 1,
        deadline: .clear,
        disposition: .humanRetryAuthorized,
        clearsTerminalReason: true
      )
    case (.reconciliationQueued, .acquireRecoveryLease):
      return effect(state, .reconciling, lease: .acquireRecovery)
    case (.reconciliationQueued, .canaryTopologyRecovered):
      return effect(state, .preparing, lease: .acquireRecovery)
    default:
      throw JobStateMachineError.invalidTransition(from: state, event: event)
    }
  }

  private static func retryEffect(
    from state: JobState,
    context: JobTransitionContext
  ) throws -> JobTransitionEffect {
    guard let notBefore = context.notBefore, notBefore > context.now else {
      throw JobStateMachineError.missingFutureDeadline
    }
    return effect(
      state,
      .retryBackoff,
      lease: .release,
      attemptDelta: 1,
      deadline: .set(notBefore)
    )
  }

  private static func blockedEffect(
    from state: JobState,
    context: JobTransitionContext
  ) -> JobTransitionEffect {
    effect(
      state,
      .blocked,
      lease: .release,
      terminalReason: context.reason
    )
  }

  private static func effect(
    _ from: JobState,
    _ to: JobState,
    lease: JobLeaseEffect = .none,
    attemptDelta: Int = 0,
    stepDelta: Int = 0,
    deadline: JobDeadlineEffect = .retain,
    nextStep: JobStepKind? = nil,
    disposition: ObjectDispositionState? = nil,
    mutationGenerationDelta: Int = 0,
    terminalReason: String? = nil,
    clearsTerminalReason: Bool = false
  ) -> JobTransitionEffect {
    JobTransitionEffect(
      from: from,
      to: to,
      lease: lease,
      attemptDelta: attemptDelta,
      stepDelta: stepDelta,
      deadline: deadline,
      nextStep: nextStep,
      disposition: disposition,
      mutationGenerationDelta: mutationGenerationDelta,
      terminalReason: terminalReason,
      clearsTerminalReason: clearsTerminalReason
    )
  }

  private static func isSHA256(_ value: String?) -> Bool {
    guard let bytes = value?.utf8, bytes.count == 64 else { return false }
    return bytes.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }
}

public struct JobRuntimeSnapshot: Equatable, Sendable {
  public let state: JobState
  public let attempt: Int
  public let currentStep: Int
  public let notBefore: Date?

  public init(
    state: JobState,
    attempt: Int,
    currentStep: Int,
    notBefore: Date?
  ) {
    self.state = state
    self.attempt = attempt
    self.currentStep = currentStep
    self.notBefore = notBefore
  }
}

public struct JobRecoveryEffect: Equatable, Sendable {
  public let state: JobState
  public let attempt: Int
  public let currentStep: Int
  public let notBefore: Date?
  public let clearStaleLease: Bool
  public let scheduleLateChecks: Bool
  public let transitionRequired: Bool
}

public enum JobRecovery {
  public static func recover(
    _ snapshot: JobRuntimeSnapshot,
    now: Date
  ) -> JobRecoveryEffect {
    switch snapshot.state {
    case .discovered:
      return result(
        snapshot,
        state: .queued,
        attempt: max(1, snapshot.attempt),
        transitionRequired: true
      )
    case .queued:
      return result(snapshot)
    case .retryBackoff:
      if let notBefore = snapshot.notBefore, notBefore <= now {
        return result(
          snapshot,
          state: .queued,
          clearNotBefore: true,
          transitionRequired: true
        )
      }
      return result(snapshot)
    case .waitingHuman:
      return result(snapshot)
    case .awaitingResolution:
      return result(snapshot, scheduleLateChecks: true)
    case .leased, .preparing, .runningPi, .executing, .reconciling:
      return result(
        snapshot,
        state: .reconciliationQueued,
        clearStaleLease: true,
        transitionRequired: true
      )
    case .reconciliationQueued, .succeeded, .blocked:
      return result(snapshot)
    }
  }

  private static func result(
    _ snapshot: JobRuntimeSnapshot,
    state: JobState? = nil,
    attempt: Int? = nil,
    clearNotBefore: Bool = false,
    clearStaleLease: Bool = false,
    scheduleLateChecks: Bool = false,
    transitionRequired: Bool = false
  ) -> JobRecoveryEffect {
    JobRecoveryEffect(
      state: state ?? snapshot.state,
      attempt: attempt ?? snapshot.attempt,
      currentStep: snapshot.currentStep,
      notBefore: clearNotBefore ? nil : snapshot.notBefore,
      clearStaleLease: clearStaleLease,
      scheduleLateChecks: scheduleLateChecks,
      transitionRequired: transitionRequired
    )
  }
}

public enum ClaimKind: String, Codable, Sendable {
  case ready
  case approvedComplex
}

public struct ClaimGeneration: Equatable, Sendable {
  public let generation: Int
  public let priorGeneration: Int?
  public let expectedLabels: [String]
  public let desiredLabels: [String]
  public let firstStep: JobStepKind
}

public enum ClaimStateMachineError: Error, Equatable, Sendable {
  case invalidGeneration
}

public enum ClaimStateMachine {
  public static func next(
    kind: ClaimKind,
    generation: Int,
    priorGeneration: Int?
  ) throws -> ClaimGeneration {
    guard generation > 0, priorGeneration.map({ $0 < generation }) ?? true else {
      throw ClaimStateMachineError.invalidGeneration
    }
    switch kind {
    case .ready:
      return ClaimGeneration(
        generation: generation,
        priorGeneration: priorGeneration,
        expectedLabels: ["agent:ready"],
        desiredLabels: ["agent:wip"],
        firstStep: .claimReady
      )
    case .approvedComplex:
      return ClaimGeneration(
        generation: generation,
        priorGeneration: priorGeneration,
        expectedLabels: ["agent:plan-review", "plan:approved"],
        desiredLabels: ["agent:wip"],
        firstStep: .claimApprovedPlan
      )
    }
  }

  public static let staleApprovalSequence: [JobStepKind] = [
    .consumeStaleApproval,
    .replan,
    .publishPlan,
  ]
}
