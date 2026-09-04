import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable jobs, dispositions, leases, and recovery")
struct DurableJobStoreTests {
  @Test("logical identity suppresses rediscovery across restart and contract bump")
  func contractIndependentIdentity() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let identity = fixture.identity(repositoryID: repositoryID, revision: "head-a")
    let jobID = UUID()

    let first = try await fixture.jobs.createJob(
      id: jobID,
      identity: identity,
      contractVersionUsed: "contract-v1",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    let created = try createdJob(first)
    #expect(created.state == .queued)
    #expect(created.attempt == 1)

    let bumped = try await fixture.jobs.createJob(
      identity: identity,
      contractVersionUsed: "contract-v2",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    let disposition = try suppressedDisposition(bumped)
    #expect(disposition.state == .inFlight)
    #expect(disposition.contractVersionUsed == "contract-v1")
    #expect(disposition.lastJobID == jobID)

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = DurableJobStore(database: reopenedDatabase)
    let afterRestart = try await reopened.createJob(
      identity: identity,
      contractVersionUsed: "app-and-skill-v99",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    #expect(try suppressedDisposition(afterRestart).lastJobID == jobID)
    try await reopened.supersedeDisposition(
      identity,
      evidenceDigest: String(repeating: "d", count: 64),
      now: fixture.now
    )
    let superseded = try await reopened.createJob(
      identity: identity,
      contractVersionUsed: "explicit-campaign-without-new-revision",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    #expect(try suppressedDisposition(superseded).state == .superseded)

    let newRevision = try await reopened.createJob(
      identity: fixture.identity(repositoryID: repositoryID, revision: "head-b"),
      contractVersionUsed: "contract-v2",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now
    )
    #expect(try createdJob(newRevision).id != jobID)
    await reopenedDatabase.close()
  }

  @Test("transition event keys make attempt and step changes exactly once")
  func transitionIdempotency() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let job = try await fixture.createJob(repositoryID: repositoryID)

    let leased = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "lease-1",
      event: .acquireLease,
      context: fixture.context("lease")
    )
    #expect(try appliedJob(leased).state == .leased)
    let duplicate = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "lease-1",
      event: .acquireLease,
      context: fixture.context("duplicate")
    )
    #expect(try duplicateJob(duplicate).state == .leased)

    let secondRepositoryID = try await fixture.addRepository()
    let secondJob = try await fixture.createJob(repositoryID: secondRepositoryID)
    await #expect(throws: DurableJobStoreError.eventKeyOwnedByAnotherJob) {
      _ = try await fixture.jobs.transition(
        jobID: secondJob.id,
        eventKey: "lease-1",
        event: .acquireLease,
        context: fixture.context("must not alias another job")
      )
    }
    #expect(try await fixture.jobs.job(id: secondJob.id)?.state == .queued)

    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "inputs-1",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    let deadline = fixture.now.addingTimeInterval(60)
    let backoff = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "backoff-1",
      event: .transientSetupFailure,
      context: fixture.context("retry", notBefore: deadline)
    )
    #expect(try appliedJob(backoff).attempt == 2)
    #expect(try appliedJob(backoff).notBefore == deadline)

    let duplicateBackoff = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "backoff-1",
      event: .transientSetupFailure,
      context: fixture.context("duplicate", notBefore: deadline)
    )
    #expect(try duplicateJob(duplicateBackoff).attempt == 2)

    await #expect(throws: DurableJobStoreError.retryDeadlineNotReached) {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: "deadline-early",
        event: .retryDeadlineReached,
        context: fixture.context("early")
      )
    }
    let queued = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "deadline-due",
      event: .retryDeadlineReached,
      context: JobTransitionContext(
        now: deadline,
        reason: "deadline reached"
      )
    )
    #expect(try appliedJob(queued).attempt == 2)
    #expect(try appliedJob(queued).notBefore == nil)
    #expect(try await fixture.jobs.transitions(jobID: job.id).count == 5)
  }

  @Test("completed steps are append-only, ordinal-bound, and digest-validated")
  func completedSteps() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let job = try await fixture.createJob(repositoryID: repositoryID)
    let digest = String(repeating: "c", count: 64)
    await #expect(
      throws: DurableJobStoreError.stepKindMismatch(expected: .review, actual: .triage)
    ) {
      try await fixture.jobs.appendCompletedStep(
        jobID: job.id,
        ordinal: 0,
        kind: .triage,
        inputDigest: digest,
        outputDigest: digest,
        mutationID: nil,
        acceptanceEvidence: nil,
        now: fixture.now
      )
    }
    try await fixture.jobs.appendCompletedStep(
      jobID: job.id,
      ordinal: 0,
      kind: .review,
      inputDigest: digest,
      outputDigest: digest,
      mutationID: nil,
      acceptanceEvidence: "schema-valid",
      now: fixture.now
    )
    await #expect(throws: DurableJobStoreError.stepOrdinalMismatch(expected: 0, actual: 1)) {
      try await fixture.jobs.appendCompletedStep(
        jobID: job.id,
        ordinal: 1,
        kind: .review,
        inputDigest: digest,
        outputDigest: digest,
        mutationID: nil,
        acceptanceEvidence: nil,
        now: fixture.now
      )
    }
    try await fixture.jobs.appendCompletedStep(
      jobID: job.id,
      ordinal: 0,
      kind: .review,
      inputDigest: digest,
      outputDigest: digest,
      mutationID: nil,
      acceptanceEvidence: "schema-valid",
      now: fixture.now
    )
    await #expect(
      throws: DurableJobStoreError.completedStepCollision(jobID: job.id, ordinal: 0)
    ) {
      try await fixture.jobs.appendCompletedStep(
        jobID: job.id,
        ordinal: 0,
        kind: .review,
        inputDigest: digest,
        outputDigest: digest,
        mutationID: nil,
        acceptanceEvidence: nil,
        now: fixture.now
      )
    }
    let steps = try await fixture.jobs.steps(jobID: job.id)
    let completed = try #require(steps.first)
    #expect(steps.count == 1)
    #expect(completed.jobID == job.id)
    #expect(completed.ordinal == 0)
    #expect(completed.kind == .review)
    #expect(completed.inputDigest == digest)
    #expect(completed.outputDigest == digest)
    #expect(completed.acceptanceEvidence == "schema-valid")
    #expect(try await fixture.jobs.completedStep(jobID: job.id, ordinal: 0) == completed)
    #expect(try await fixture.jobs.completedStep(jobID: job.id, ordinal: 1) == nil)
  }

  @Test("attributed and ambiguous dispositions control rediscovery and retry")
  func dispositionTransitions() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()

    let successful = try await fixture.createJob(
      repositoryID: repositoryID,
      revision: "success"
    )
    try await driveToReconciling(fixture, job: successful, prefix: "success")
    let digest = String(repeating: "a", count: 64)
    let completed = try await fixture.jobs.transition(
      jobID: successful.id,
      eventKey: "success-complete",
      event: .acceptanceComplete,
      context: fixture.context("accepted", evidenceDigest: digest)
    )
    #expect(try appliedJob(completed).state == .succeeded)
    let attributed = try #require(
      try await fixture.jobs.disposition(for: successful.identity)
    )
    #expect(attributed.state == .attributed)
    #expect(attributed.evidenceDigest == digest)
    #expect(
      try suppressedDisposition(
        try await fixture.jobs.createJob(
          identity: successful.identity,
          contractVersionUsed: "contract-v2",
          priority: .prReview,
          firstStep: .review,
          now: fixture.now
        )
      ).state == .attributed
    )

    let late = try await fixture.createJob(
      repositoryID: repositoryID,
      revision: "late"
    )
    try await driveToReconciling(fixture, job: late, prefix: "late")
    let ambiguous = try await fixture.jobs.transition(
      jobID: late.id,
      eventKey: "late-ambiguous",
      event: .ambiguousCreate,
      context: fixture.context("response lost")
    )
    #expect(try appliedJob(ambiguous).state == .awaitingResolution)
    #expect(try await fixture.jobs.disposition(for: late.identity)?.state == .ambiguous)
    #expect(
      try suppressedDisposition(
        try await fixture.jobs.createJob(
          identity: late.identity,
          contractVersionUsed: "contract-v99",
          priority: .prReview,
          firstStep: .review,
          now: fixture.now
        )
      ).state == .ambiguous
    )
    let lateAttribution = try await fixture.jobs.transition(
      jobID: late.id,
      eventKey: "late-attributed",
      event: .lateEffectAttributed,
      context: fixture.context("read-only attribution")
    )
    #expect(try appliedJob(lateAttribution).state == .reconciliationQueued)
    #expect(try appliedJob(lateAttribution).attempt == 1)
    #expect(try await fixture.jobs.disposition(for: late.identity)?.state == .inFlight)

    let retry = try await fixture.createJob(
      repositoryID: repositoryID,
      revision: "human-retry"
    )
    try await driveToReconciling(fixture, job: retry, prefix: "retry")
    _ = try await fixture.jobs.transition(
      jobID: retry.id,
      eventKey: "retry-ambiguous",
      event: .ambiguousCreate,
      context: fixture.context("response lost")
    )
    let authorized = try await fixture.jobs.transition(
      jobID: retry.id,
      eventKey: "retry-authorized",
      event: .humanRetryAuthorized,
      context: fixture.context("exact human authorization")
    )
    #expect(try appliedJob(authorized).state == .queued)
    #expect(try appliedJob(authorized).attempt == 2)
    let authorizedDisposition = try #require(
      try await fixture.jobs.disposition(for: retry.identity)
    )
    #expect(authorizedDisposition.state == .humanRetryAuthorized)
    #expect(authorizedDisposition.mutationGeneration == 1)
  }

  @Test("repository lease and global semaphore enforce both bounds")
  func leaseBounds() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repoA = try await fixture.addRepository()
    let repoB = try await fixture.addRepository()
    let repoC = try await fixture.addRepository()
    let a1 = try await fixture.createJob(repositoryID: repoA, revision: "a1")
    let a2 = try await fixture.createJob(repositoryID: repoA, revision: "a2")
    let b1 = try await fixture.createJob(repositoryID: repoB, revision: "b1")
    let c1 = try await fixture.createJob(repositoryID: repoC, revision: "c1")

    _ = try await fixture.jobs.transition(
      jobID: a1.id,
      eventKey: "a1-lease",
      event: .acquireLease,
      context: fixture.context("lease")
    )
    await #expect(throws: DurableJobStoreError.repositoryAlreadyLeased(repoA)) {
      _ = try await fixture.jobs.transition(
        jobID: a2.id,
        eventKey: "a2-collision",
        event: .acquireLease,
        context: fixture.context("collision")
      )
    }
    await #expect(throws: DurableJobStoreError.globalConcurrencyReached) {
      _ = try await fixture.jobs.transition(
        jobID: b1.id,
        eventKey: "b1-cap",
        event: .acquireLease,
        context: fixture.context("cap")
      )
    }
    #expect(try await fixture.jobs.activeLeases().count == 1)

    _ = try await fixture.jobs.transition(
      jobID: a1.id,
      eventKey: "a1-inputs",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: a1.id,
      eventKey: "a1-block",
      event: .permanentSetupFailure,
      context: fixture.context("blocked")
    )
    _ = try await fixture.jobs.transition(
      jobID: b1.id,
      eventKey: "b1-lease",
      event: .acquireLease,
      context: fixture.context("lease")
    )
    await #expect(throws: DurableJobStoreError.globalConcurrencyReached) {
      _ = try await fixture.jobs.transition(
        jobID: c1.id,
        eventKey: "c1-cap",
        event: .acquireLease,
        context: fixture.context("cap")
      )
    }
    _ = try await fixture.jobs.transition(
      jobID: b1.id,
      eventKey: "b1-inputs",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: b1.id,
      eventKey: "b1-block",
      event: .permanentSetupFailure,
      context: fixture.context("blocked")
    )
    _ = try await fixture.jobs.transition(
      jobID: a2.id,
      eventKey: "a2-lease",
      event: .acquireLease,
      context: fixture.context("lease")
    )
    let leases = try await fixture.jobs.activeLeases()
    let a2Lease = try #require(leases.first { $0.jobID == a2.id })
    #expect(a2Lease.generation == 2)
    #expect(Set(leases.map(\.repositoryID)).count == leases.count)
    #expect(leases.count == 1)
  }

  @Test("deterministic operation property preserves repository and global lease bounds")
  func leaseProperty() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    var jobsByRepository: [UUID: [JobRecord]] = [:]
    for _ in 0..<6 {
      let repositoryID = try await fixture.addRepository()
      var jobs: [JobRecord] = []
      for index in 0..<8 {
        jobs.append(
          try await fixture.createJob(
            repositoryID: repositoryID,
            revision: "property-\(index)"
          )
        )
      }
      jobsByRepository[repositoryID] = jobs
    }

    var active: [UUID: JobRecord] = [:]
    var nextIndex = Dictionary(uniqueKeysWithValues: jobsByRepository.keys.map { ($0, 0) })
    var random = DeterministicRandom(seed: 0x5eed)
    for operation in 0..<200 {
      let repositories = jobsByRepository.keys.sorted {
        $0.uuidString < $1.uuidString
      }
      let repositoryID = repositories[random.nextInt(upperBound: repositories.count)]
      if let current = active[repositoryID] {
        _ = try await fixture.jobs.transition(
          jobID: current.id,
          eventKey: "property-\(operation)-inputs",
          event: .inputsValidated,
          context: fixture.context("inputs")
        )
        _ = try await fixture.jobs.transition(
          jobID: current.id,
          eventKey: "property-\(operation)-release",
          event: .permanentSetupFailure,
          context: fixture.context("release")
        )
        active.removeValue(forKey: repositoryID)
      } else if active.isEmpty,
        let index = nextIndex[repositoryID],
        let available = jobsByRepository[repositoryID],
        index < available.count
      {
        let job = available[index]
        _ = try await fixture.jobs.transition(
          jobID: job.id,
          eventKey: "property-\(operation)-lease",
          event: .acquireLease,
          context: fixture.context("lease")
        )
        active[repositoryID] = job
        nextIndex[repositoryID] = index + 1
      }

      let leases = try await fixture.jobs.activeLeases()
      #expect(leases.count <= 1)
      #expect(Set(leases.map(\.repositoryID)).count == leases.count)
      #expect(Set(leases.map(\.repositoryID)) == Set(active.keys))
    }
  }

  @Test("startup recovery persists the total matrix before dispatch")
  func startupRecovery() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let now = fixture.now
    var jobByState: [JobState: JobRecord] = [:]

    for state in JobState.allCases {
      let repositoryID = try await fixture.addRepository()
      let job = try await fixture.createJob(
        repositoryID: repositoryID,
        revision: "state-\(state.rawValue)"
      )
      let deadline: SQLiteValue =
        state == .retryBackoff
        ? .real(now.addingTimeInterval(-1).timeIntervalSince1970)
        : .null
      try await fixture.database.execute(
        "UPDATE jobs SET state = ?, attempt = 3, current_step = 7, not_before = ? WHERE id = ?",
        bindings: [
          .text(state.rawValue), deadline, .text(job.id.uuidString.lowercased()),
        ]
      )
      if [.leased, .preparing, .runningPi, .executing, .reconciling].contains(state) {
        try await fixture.database.execute(
          "INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active) VALUES (?, ?, 1, ?, 1)",
          bindings: [
            .text(repositoryID.uuidString.lowercased()),
            .text(job.id.uuidString.lowercased()),
            .real(now.timeIntervalSince1970),
          ]
        )
      }
      jobByState[state] = job
    }

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = DurableJobStore(database: reopenedDatabase)
    let recoveryRecords = try await reopened.recoverAtStartup(now: now)
    #expect(try await reopened.activeLeases().isEmpty)
    let awaitingRecord = try #require(
      recoveryRecords.first { $0.persistedState == .awaitingResolution }
    )
    #expect(awaitingRecord.scheduleLateChecks)
    #expect(
      recoveryRecords
        .filter { $0.persistedState != .awaitingResolution }
        .allSatisfy { !$0.scheduleLateChecks }
    )

    for state in JobState.allCases {
      let original = try #require(jobByState[state])
      let recovered = try #require(try await reopened.job(id: original.id))
      switch state {
      case .discovered:
        #expect(recovered.state == .queued)
        #expect(recovered.attempt == 3)
      case .retryBackoff:
        #expect(recovered.state == .queued)
        #expect(recovered.attempt == 3)
        #expect(recovered.notBefore == nil)
      case .leased, .preparing, .runningPi, .executing, .reconciling:
        #expect(recovered.state == .reconciliationQueued)
        #expect(recovered.attempt == 3)
        #expect(recovered.currentStep == 7)
        let transitions = try await reopened.transitions(jobID: original.id)
        let startup = try #require(transitions.last)
        #expect(startup.from == state)
        #expect(startup.to == .reconciliationQueued)
        #expect(startup.reason == "startup recovery")
      default:
        #expect(recovered.state == state)
        #expect(recovered.attempt == 3)
      }
    }
    await reopenedDatabase.close()
  }

  @Test("stale approval cannot replan before consume attribution")
  func staleApprovalOrdering() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let job = try await fixture.createJob(repositoryID: repositoryID)
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'waitingHuman', current_step_kind = 'plan' WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )
    let stale = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "stale-approval",
      event: .approvalStale,
      context: fixture.context("base changed")
    )
    #expect(try appliedJob(stale).currentStepKind == .consumeStaleApproval)
    for (key, event) in [
      ("stale-lease", JobEvent.acquireLease),
      ("stale-inputs", .inputsValidated),
      ("stale-execute", .selectLocalStep),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: key,
        event: event,
        context: fixture.context(key)
      )
    }
    await #expect(throws: DurableJobStoreError.staleApprovalRequiresAttribution) {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: "stale-bypass",
        event: .localStepCompletedMore,
        context: fixture.context("must not replan")
      )
    }
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "stale-send",
      event: .mutationNeedsAttribution,
      context: fixture.context("approval removal sent")
    )
    await #expect(throws: DurableJobStoreError.staleApprovalRequiresCheckpoint) {
      _ = try await fixture.jobs.transition(
        jobID: job.id,
        eventKey: "stale-attribution-bypass",
        event: .effectAttributedMore,
        context: fixture.context("must cross the planning checkpoint")
      )
    }
    let checkpointed = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "stale-attributed-checkpoint",
      event: .phaseCheckpoint,
      context: JobTransitionContext(
        now: fixture.now,
        reason: "approval removal attributed at the planning boundary",
        nextStep: .replan
      )
    )
    #expect(try appliedJob(checkpointed).state == .queued)
    #expect(try appliedJob(checkpointed).currentStep == 2)
    #expect(try appliedJob(checkpointed).currentStepKind == .replan)
    #expect(try await fixture.jobs.activeLeases().isEmpty)
  }

  @Test("claim generations persist ready, stale, and approved sequences")
  func claimPersistence() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let job = try await fixture.createJob(repositoryID: repositoryID)

    let ready = try await fixture.jobs.beginClaim(
      issueNodeID: "issue-node",
      jobID: job.id,
      kind: .ready,
      marker: "ready-marker",
      planDigest: nil,
      now: fixture.now
    )
    #expect(ready.generation == 1)
    #expect(ready.priorGeneration == nil)
    #expect(ready.expectedLabels == ["agent:ready"])
    #expect(ready.desiredLabels == ["agent:wip"])

    await #expect(throws: DurableJobStoreError.activeClaimExists("issue-node")) {
      _ = try await fixture.jobs.beginClaim(
        issueNodeID: "issue-node",
        jobID: job.id,
        kind: .ready,
        marker: "collision",
        planDigest: nil,
        now: fixture.now
      )
    }
    try await fixture.jobs.finishClaim(
      issueNodeID: "issue-node",
      generation: 1,
      state: .stale,
      now: fixture.now
    )
    let approved = try await fixture.jobs.beginClaim(
      issueNodeID: "issue-node",
      jobID: job.id,
      kind: .approvedComplex,
      marker: "resume-marker",
      planDigest: String(repeating: "b", count: 64),
      now: fixture.now
    )
    #expect(approved.generation == 2)
    #expect(approved.priorGeneration == 1)
    #expect(approved.expectedLabels == ["agent:plan-review", "plan:approved"])
    #expect(
      try await fixture.jobs.claims(issueNodeID: "issue-node").map(\.state) == [
        .stale, .active,
      ])
  }

  @Test("exact pre-boundary retirement is atomic suppresses rediscovery and replays")
  func exactRetirementBatch() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let boundary = JobMaintenanceScope.authorizedBoundaryEpochSeconds
    let first = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "old-blocked"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary - 1_000))
      )
    )
    for (key, event) in [
      ("retire-lease", JobEvent.acquireLease),
      ("retire-inputs", .inputsValidated),
      ("retire-block", .permanentSetupFailure),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: first.id,
        eventKey: key,
        event: event,
        context: JobTransitionContext(
          now: Date(timeIntervalSince1970: TimeInterval(boundary - 900)),
          reason: "fixture failure"
        )
      )
    }
    let second = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "old-queued"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary - 800))
      )
    )
    let newer = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "new-queued"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary))
      )
    )
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: boundary
    )
    let preview = try await fixture.jobs.previewMaintenance(scope: scope)
    #expect(preview.candidateCount == 2)
    #expect(GitHubInputValidation.validSHA256(preview.evidenceSHA256))
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    let applied = try await fixture.jobs.applyMaintenance(
      authorization,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 1_000))
    )
    #expect(applied.report.appliedCount == 2)
    #expect(!applied.report.replayed)
    #expect(Set(applied.jobIDs) == Set([first.id, second.id]))
    for job in [first, second] {
      #expect(try await fixture.jobs.job(id: job.id)?.state == .blocked)
      #expect(try await fixture.jobs.disposition(for: job.identity)?.state == .superseded)
    }
    #expect(try await fixture.jobs.job(id: newer.id)?.state == .queued)
    #expect(try await fixture.jobs.disposition(for: newer.identity)?.state == .inFlight)
    #expect(try await fixture.jobs.jobs().count == 3)

    let replay = try await fixture.jobs.applyMaintenance(
      authorization,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 2_000))
    )
    #expect(replay.report.replayed)
    #expect(replay.report.appliedCount == 2)
    #expect(try await fixture.jobs.transitions(jobID: second.id).last?.from == .queued)
    #expect(try await fixture.jobs.previewMaintenance(scope: scope).candidateCount == 0)

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = try await DurableJobStore(database: reopenedDatabase).applyMaintenance(
      authorization,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 3_000))
    )
    #expect(reopened.report.replayed)
    #expect(Set(reopened.jobIDs) == Set([first.id, second.id]))
    await reopenedDatabase.close()
  }

  @Test("only exact resource failures after the boundary are safely requeued")
  func exactResourceRepairBatch() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let boundary = JobMaintenanceScope.authorizedBoundaryEpochSeconds
    let repairable = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "resource-failure"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary))
      )
    )
    for (key, event, reason) in [
      ("repair-lease", JobEvent.acquireLease, "lease"),
      ("repair-inputs", .inputsValidated, "inputs"),
      ("repair-pi", .selectPiStep, "pi"),
      (
        "repair-block", .piPermanentFailure,
        "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError"
      ),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: repairable.id,
        eventKey: key,
        event: event,
        context: JobTransitionContext(
          now: Date(timeIntervalSince1970: TimeInterval(boundary + 100)),
          reason: reason
        )
      )
    }
    let legacy = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "legacy-resource"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary - 1))
      )
    )
    for (key, event, reason) in [
      ("legacy-lease", JobEvent.acquireLease, "lease"),
      ("legacy-inputs", .inputsValidated, "inputs"),
      ("legacy-pi", .selectPiStep, "pi"),
      (
        "legacy-block", .piPermanentFailure,
        "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError"
      ),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: legacy.id,
        eventKey: key,
        event: event,
        context: JobTransitionContext(
          now: Date(timeIntervalSince1970: TimeInterval(boundary + 100)),
          reason: reason
        )
      )
    }
    let unrelated = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "other-failure"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary + 200))
      )
    )
    for (key, event) in [
      ("other-lease", JobEvent.acquireLease),
      ("other-inputs", .inputsValidated),
      ("other-block", .permanentSetupFailure),
    ] {
      _ = try await fixture.jobs.transition(
        jobID: unrelated.id,
        eventKey: key,
        event: event,
        context: JobTransitionContext(
          now: Date(timeIntervalSince1970: TimeInterval(boundary + 300)),
          reason:
            "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError.suffix"
        )
      )
    }
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    let scope = JobMaintenanceScope(
      operation: .retryResourceFailuresAfter,
      boundaryEpochSeconds: boundary
    )
    let preview = try await fixture.jobs.previewMaintenance(scope: scope)
    #expect(preview.candidateCount == 1)
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: 1,
      evidenceSHA256: preview.evidenceSHA256
    )
    let applied = try await fixture.jobs.applyMaintenance(
      authorization,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 400))
    )
    #expect(applied.jobIDs == [repairable.id])
    let repaired = try #require(try await fixture.jobs.job(id: repairable.id))
    #expect(repaired.state == .queued)
    #expect(repaired.attempt == 2)
    #expect(repaired.terminalReason == nil)
    #expect(
      try await fixture.jobs.disposition(for: repairable.identity)?.state
        == .humanRetryAuthorized
    )
    #expect(try await fixture.jobs.job(id: unrelated.id)?.state == .blocked)
    #expect(try await fixture.jobs.job(id: legacy.id)?.state == .blocked)
    #expect(
      try await fixture.jobs.applyMaintenance(
        authorization,
        now: Date(timeIntervalSince1970: TimeInterval(boundary + 500))
      ).report.replayed
    )
  }

  @Test("exact paused canary admits one repaired PR and bounds every effect")
  func exactPausedCanary() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let boundary = JobCanaryScope.authorizedBoundaryEpochSeconds
    let candidate = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "canary-repair"),
        objectNumber: 42,
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary))
      )
    )
    try await blockForResourceFailure(
      fixture: fixture,
      job: candidate,
      eventPrefix: "canary-repair",
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 1))
    )
    try await fixture.database.execute(
      """
      UPDATE app_settings
      SET paused = 1, onboarding_complete = 1,
          external_automation_acknowledged = 1,
          provider_disclosure_acknowledged = 1,
          github_account = 'fixture', github_author_id = 1,
          login_item_selected = 1, login_item_status = 'enabled'
      WHERE singleton = 1
      """
    )
    let repairScope = JobMaintenanceScope(
      operation: .retryResourceFailuresAfter,
      boundaryEpochSeconds: boundary
    )
    let repairPreview = try await fixture.jobs.previewMaintenance(scope: repairScope)
    _ = try await fixture.jobs.applyMaintenance(
      JobMaintenanceAuthorization(
        scope: repairScope,
        expectedCount: 1,
        evidenceSHA256: repairPreview.evidenceSHA256
      ),
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 2))
    )
    let repaired = try #require(try await fixture.jobs.job(id: candidate.id))
    let repairedDisposition = try #require(
      try await fixture.jobs.disposition(for: candidate.identity)
    )
    #expect(repaired.state == .queued)
    #expect(repaired.priority == .prReview)
    #expect(repaired.currentStep == 0)
    #expect(repaired.currentStepKind == .review)
    #expect(repaired.notBefore == nil)
    #expect(repaired.terminalReason == nil)
    #expect(repairedDisposition.contractVersionUsed == repaired.contractVersionUsed)
    #expect(repairedDisposition.lastJobID == candidate.id)
    #expect(repairedDisposition.mutationGeneration == 0)
    let untouched = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "untouched"),
        objectNumber: 43,
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary + 3))
      )
    )
    let scope = JobCanaryScope(
      jobID: candidate.id,
      boundaryEpochSeconds: boundary,
      repairEvidenceSHA256: repairPreview.evidenceSHA256,
      maximumCommentParts: 2
    )
    let resource = String(repeating: "a", count: 64)
    try await fixture.database.execute(
      "UPDATE jobs SET terminal_reason = 'stale' WHERE id = ?",
      bindings: [.text(candidate.id.uuidString.lowercased())]
    )
    await #expect(throws: DurableJobStoreError.canaryUnsafe(candidate.id)) {
      _ = try await fixture.jobs.previewCanary(scope: scope, resourceTreeSHA256: resource)
    }
    try await fixture.database.execute(
      "UPDATE jobs SET terminal_reason = NULL, not_before = ? WHERE id = ?",
      bindings: [
        .real(TimeInterval(boundary + 100)), .text(candidate.id.uuidString.lowercased()),
      ]
    )
    await #expect(throws: DurableJobStoreError.canaryUnsafe(candidate.id)) {
      _ = try await fixture.jobs.previewCanary(scope: scope, resourceTreeSHA256: resource)
    }
    try await fixture.database.execute(
      "UPDATE jobs SET not_before = NULL WHERE id = ?",
      bindings: [.text(candidate.id.uuidString.lowercased())]
    )
    let transitionsBefore = try await fixture.jobs.transitions(jobID: candidate.id).count
    let preview = try await fixture.jobs.previewCanary(
      scope: scope,
      resourceTreeSHA256: resource
    )
    #expect(preview.status == .preview)
    #expect(preview.piRoles == [.architecture, .security, .test, .synthesis])
    #expect(try await fixture.jobs.transitions(jobID: candidate.id).count == transitionsBefore)

    let authorization = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: preview.previewEvidenceSHA256
    )
    await #expect(throws: DurableJobStoreError.canaryEvidenceMismatch) {
      _ = try await fixture.jobs.admitCanary(
        authorization,
        resourceTreeSHA256: String(repeating: "f", count: 64),
        now: fixture.now
      )
    }
    try await fixture.database.execute(
      "UPDATE repositories SET default_branch = 'changed' WHERE id = ?",
      bindings: [.text(repositoryID.uuidString.lowercased())]
    )
    await #expect(throws: DurableJobStoreError.canaryEvidenceMismatch) {
      _ = try await fixture.jobs.admitCanary(
        authorization,
        resourceTreeSHA256: resource,
        now: fixture.now
      )
    }
    try await fixture.database.execute(
      "UPDATE repositories SET default_branch = 'main' WHERE id = ?",
      bindings: [.text(repositoryID.uuidString.lowercased())]
    )
    try await fixture.database.execute(
      """
      CREATE TRIGGER fail_canary_admission
      BEFORE UPDATE OF state ON jobs
      WHEN OLD.id = '\(candidate.id.uuidString.lowercased())' AND NEW.state = 'leased'
      BEGIN SELECT RAISE(ABORT, 'injected canary admission failure'); END
      """
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.jobs.admitCanary(
        authorization,
        resourceTreeSHA256: resource,
        now: Date(timeIntervalSince1970: TimeInterval(boundary + 4))
      )
    }
    try await fixture.database.execute("DROP TRIGGER fail_canary_admission")
    #expect(try await fixture.jobs.job(id: candidate.id)?.state == .queued)
    #expect(try await fixture.jobs.activeLeases().isEmpty)
    #expect(try await fixture.jobs.unresolvedCanaryJobID() == nil)
    let admitted = try await fixture.jobs.admitCanary(
      authorization,
      resourceTreeSHA256: resource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 4))
    )
    #expect(admitted.shouldExecute)
    #expect(admitted.report.status == .admitted)
    let unresolvedReplay = try await fixture.jobs.admitCanary(
      authorization,
      resourceTreeSHA256: resource,
      now: fixture.now
    )
    #expect(!unresolvedReplay.shouldExecute)
    #expect(unresolvedReplay.report.status == .recoveryRequired)
    #expect(unresolvedReplay.report.replayed)
    #expect(try await fixture.jobs.job(id: candidate.id)?.state == .leased)
    #expect(try await fixture.jobs.job(id: untouched.id)?.state == .queued)
    #expect(try await fixture.jobs.activeLeases().map(\.jobID) == [candidate.id])
    await #expect(throws: DurableJobStoreError.canaryUnsafe(candidate.id)) {
      _ = try await fixture.jobs.previewCanary(
        scope: scope,
        resourceTreeSHA256: resource
      )
    }

    await #expect(throws: DurableJobStoreError.canaryEffectDenied) {
      try await fixture.jobs.authorizeCanaryPiRole(
        jobID: candidate.id,
        workflow: .pullRequestReview,
        role: .security,
        round: 1,
        now: fixture.now
      )
    }
    for role in [PiWorkflowRole.architecture, .security, .test, .synthesis] {
      try await fixture.jobs.authorizeCanaryPiRole(
        jobID: candidate.id,
        workflow: .pullRequestReview,
        role: role,
        round: 1,
        now: fixture.now
      )
    }
    try await fixture.jobs.authorizeCanaryPiRole(
      jobID: candidate.id,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      now: fixture.now
    )
    await #expect(throws: DurableJobStoreError.canaryEffectDenied) {
      try await fixture.jobs.authorizeCanaryPiRole(
        jobID: candidate.id,
        workflow: .pullRequestReview,
        role: .architecture,
        round: 2,
        now: fixture.now
      )
    }
    await #expect(throws: DurableJobStoreError.canaryEffectDenied) {
      try await fixture.jobs.authorizeCanaryPiRole(
        jobID: untouched.id,
        workflow: .pullRequestReview,
        role: .architecture,
        round: 1,
        now: fixture.now
      )
    }
    await #expect(throws: DurableJobStoreError.canaryEffectDenied) {
      try await fixture.jobs.authorizeCanaryMarkerBatch(
        jobID: candidate.id,
        operation: .createMarkerComment,
        documentSHA256: String(repeating: "b", count: 64),
        partCount: 3,
        now: fixture.now
      )
    }
    try await fixture.jobs.authorizeCanaryMarkerBatch(
      jobID: candidate.id,
      operation: .createMarkerComment,
      documentSHA256: String(repeating: "b", count: 64),
      partCount: 2,
      now: fixture.now
    )
    await #expect(throws: DurableJobStoreError.canaryEffectDenied) {
      try await fixture.jobs.authorizeCanaryMarkerBatch(
        jobID: candidate.id,
        operation: .createMarkerComment,
        documentSHA256: String(repeating: "c", count: 64),
        partCount: 1,
        now: fixture.now
      )
    }

    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-test-inputs",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-test-block",
      event: .permanentSetupFailure,
      context: fixture.context("fixture terminal canary")
    )
    let closed = try await fixture.jobs.closeCanary(
      authorization: authorization,
      resourceTreeSHA256: resource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 5))
    )
    #expect(closed.status == .settled)
    #expect(closed.previewEvidenceSHA256 == preview.previewEvidenceSHA256)
    #expect(try await fixture.jobs.unresolvedCanaryJobID() == nil)
    let closeReplay = try await fixture.jobs.closeCanary(
      authorization: authorization,
      resourceTreeSHA256: resource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 6))
    )
    #expect(closeReplay.status == .settled)
    #expect(closeReplay.replayed)
    let replay = try await fixture.jobs.admitCanary(
      authorization,
      resourceTreeSHA256: resource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 6))
    )
    #expect(!replay.shouldExecute)
    #expect(replay.report.status == .settled)
    #expect(replay.report.replayed)
    #expect(try await fixture.jobs.job(id: untouched.id)?.state == .queued)
    #expect(DatabaseSchema.migrations.count == 10)
  }

  @Test("a closed no-effect canary retry requires a new preview and admission")
  func closedNoEffectCanaryRetry() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let boundary = JobCanaryScope.authorizedBoundaryEpochSeconds
    let candidate = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "canary-retry"),
        objectNumber: 42,
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary))
      )
    )
    try await blockForResourceFailure(
      fixture: fixture,
      job: candidate,
      eventPrefix: "canary-retry",
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 1))
    )
    try await fixture.database.execute(
      """
      UPDATE app_settings
      SET paused = 1, onboarding_complete = 1,
          external_automation_acknowledged = 1,
          provider_disclosure_acknowledged = 1,
          github_account = 'fixture', github_author_id = 1,
          login_item_selected = 1, login_item_status = 'enabled'
      WHERE singleton = 1
      """
    )
    let repairScope = JobMaintenanceScope(
      operation: .retryResourceFailuresAfter,
      boundaryEpochSeconds: boundary
    )
    let repairPreview = try await fixture.jobs.previewMaintenance(scope: repairScope)
    _ = try await fixture.jobs.applyMaintenance(
      JobMaintenanceAuthorization(
        scope: repairScope,
        expectedCount: 1,
        evidenceSHA256: repairPreview.evidenceSHA256
      ),
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 2))
    )
    let scope = JobCanaryScope(
      jobID: candidate.id,
      boundaryEpochSeconds: boundary,
      repairEvidenceSHA256: repairPreview.evidenceSHA256,
      maximumCommentParts: 2
    )
    let firstResource = String(repeating: "a", count: 64)
    let firstPreview = try await fixture.jobs.previewCanary(
      scope: scope,
      resourceTreeSHA256: firstResource
    )
    let firstAuthorization = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: firstPreview.previewEvidenceSHA256
    )
    #expect(
      try await fixture.jobs.admitCanary(
        firstAuthorization,
        resourceTreeSHA256: firstResource,
        now: Date(timeIntervalSince1970: TimeInterval(boundary + 3))
      ).shouldExecute
    )
    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-retry-first-inputs",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-retry-first-pi",
      event: .selectPiStep,
      context: fixture.context("Pi")
    )
    try await fixture.jobs.authorizeCanaryPiRole(
      jobID: candidate.id,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 4))
    )
    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "job:\(candidate.id.uuidString.lowercased()):a2:s0:retry",
      event: .transientPiFailure,
      context: fixture.context(
        "job coordinator scheduled retry after JidokaCodeCore.HerdrPiWorkflowError",
        notBefore: Date(timeIntervalSince1970: TimeInterval(boundary + 100))
      )
    )
    let firstClosed = try await fixture.jobs.closeCanary(
      authorization: firstAuthorization,
      resourceTreeSHA256: firstResource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 5))
    )
    #expect(firstClosed.status == .settled)
    #expect(try await fixture.jobs.job(id: candidate.id)?.state == .retryBackoff)
    #expect(try await fixture.jobs.job(id: candidate.id)?.attempt == 3)

    let secondResource = String(repeating: "b", count: 64)
    _ = try await fixture.database.execute(
      """
      INSERT INTO herdr_topology_intents(
        id, kind, repository_id, job_id, generation, intent_sha256, payload_sha256,
        socket_device, socket_inode, socket_owner, socket_permissions,
        state, created_at, updated_at
      ) VALUES (
        'effectful-canary', 'createWorkspace', ?, ?, 1, ?, ?,
        1, 2, 501, 384, 'prepared', 1, 1
      )
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text(candidate.id.uuidString.lowercased()),
        .text(String(repeating: "c", count: 64)),
        .text(String(repeating: "d", count: 64)),
      ]
    )
    await #expect(throws: DurableJobStoreError.canaryUnsafe(candidate.id)) {
      _ = try await fixture.jobs.previewCanary(
        scope: scope,
        resourceTreeSHA256: secondResource
      )
    }
    _ = try await fixture.database.execute(
      "DELETE FROM herdr_topology_intents WHERE id = 'effectful-canary'"
    )
    let secondPreview = try await fixture.jobs.previewCanary(
      scope: scope,
      resourceTreeSHA256: secondResource
    )
    #expect(secondPreview.status == .preview)
    #expect(secondPreview.previewEvidenceSHA256 != firstPreview.previewEvidenceSHA256)
    let secondAuthorization = JobCanaryAuthorization(
      scope: scope,
      previewEvidenceSHA256: secondPreview.previewEvidenceSHA256
    )
    let secondAdmission = try await fixture.jobs.admitCanary(
      secondAuthorization,
      resourceTreeSHA256: secondResource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 6))
    )
    #expect(secondAdmission.shouldExecute)
    #expect(secondAdmission.report.authorizationSHA256 != firstClosed.authorizationSHA256)
    let readmitted = try #require(try await fixture.jobs.job(id: candidate.id))
    #expect(readmitted.state == .leased)
    #expect(readmitted.attempt == 3)
    #expect(readmitted.notBefore == nil)
    let admission = try #require(
      try await fixture.jobs.transitions(jobID: candidate.id).last(where: {
        $0.eventKey.contains(":admit:")
      })
    )
    #expect(admission.from == .retryBackoff)
    #expect(admission.to == .leased)

    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-retry-second-inputs",
      event: .inputsValidated,
      context: fixture.context("inputs")
    )
    _ = try await fixture.jobs.transition(
      jobID: candidate.id,
      eventKey: "canary-retry-second-block",
      event: .permanentSetupFailure,
      context: fixture.context("stop fixture")
    )
    _ = try await fixture.jobs.closeCanary(
      authorization: secondAuthorization,
      resourceTreeSHA256: secondResource,
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 7))
    )
    #expect(try await fixture.jobs.unresolvedCanaryJobID() == nil)
  }

  @Test("maintenance apply requires pause and byte-exact current evidence")
  func maintenanceGuards() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    _ = try await fixture.createJob(repositoryID: repositoryID, revision: "first")
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let preview = try await fixture.jobs.previewMaintenance(scope: scope)
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    let wrongCount = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount + 1,
      evidenceSHA256: preview.evidenceSHA256
    )
    await #expect(throws: DurableJobStoreError.maintenanceEvidenceMismatch) {
      _ = try await fixture.jobs.applyMaintenance(wrongCount, now: fixture.now)
    }
    let wrongEvidence = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: String(repeating: "b", count: 64)
    )
    await #expect(throws: DurableJobStoreError.maintenanceEvidenceMismatch) {
      _ = try await fixture.jobs.applyMaintenance(wrongEvidence, now: fixture.now)
    }
    _ = try await fixture.createJob(repositoryID: repositoryID, revision: "second")
    await #expect(throws: DurableJobStoreError.maintenanceEvidenceMismatch) {
      _ = try await fixture.jobs.applyMaintenance(authorization, now: fixture.now)
    }
    let unauthorizedScope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds - 1
    )
    await #expect(throws: EngineClientError(.invalidCommand)) {
      _ = try await fixture.jobs.previewMaintenance(scope: unauthorizedScope)
    }
  }

  @Test("resource retry rejects a candidate with durable job-step evidence")
  func retryRejectsJobStepEvidence() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let boundary = JobMaintenanceScope.authorizedBoundaryEpochSeconds
    let job = try createdJob(
      try await fixture.jobs.createJob(
        identity: fixture.identity(repositoryID: repositoryID, revision: "resource-step"),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: Date(timeIntervalSince1970: TimeInterval(boundary))
      )
    )
    try await blockForResourceFailure(
      fixture: fixture,
      job: job,
      eventPrefix: "resource-step",
      now: Date(timeIntervalSince1970: TimeInterval(boundary + 1))
    )
    try await fixture.database.execute(
      """
      INSERT INTO job_steps(
        job_id, ordinal, kind, state, input_digest, output_digest,
        mutation_id, acceptance_evidence, completed_at
      ) VALUES (?, 0, 'review', 'completed', NULL, NULL, NULL, NULL, ?)
      """,
      bindings: [
        .text(job.id.uuidString.lowercased()),
        .real(TimeInterval(boundary + 2)),
      ]
    )
    let scope = JobMaintenanceScope(
      operation: .retryResourceFailuresAfter,
      boundaryEpochSeconds: boundary
    )
    await #expect(throws: DurableJobStoreError.maintenanceCandidateUnsafe(job.id)) {
      _ = try await fixture.jobs.previewMaintenance(scope: scope)
    }
  }

  @Test("maintenance rejects every active durable authority")
  func maintenanceActiveAuthorityGuards() async throws {
    try await expectUnsafeMaintenance(revision: "active-lease") { fixture, job in
      try await fixture.database.execute(
        """
        INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
        VALUES (?, ?, 1, ?, 1)
        """,
        bindings: [
          .text(job.identity.repositoryID.uuidString.lowercased()),
          .text(job.id.uuidString.lowercased()),
          .real(fixture.now.timeIntervalSince1970),
        ]
      )
    }
    try await expectUnsafeMaintenance(revision: "pi-run") { fixture, job in
      try await fixture.database.execute(
        """
        INSERT INTO pi_runs(
          id, job_id, runtime_kind, role, resource_version, resource_hash, model, session_path,
          accepted, settled, structured_result_digest, outcome, created_at, updated_at
        ) VALUES (?, ?, 'rpcLegacy', 'triage', 'v1', ?, 'model', '/private/tmp/session',
                  0, 0, NULL, 'pending', ?, ?)
        """,
        bindings: [
          .text(UUID().uuidString.lowercased()),
          .text(job.id.uuidString.lowercased()),
          .text(String(repeating: "a", count: 64)),
          .real(fixture.now.timeIntervalSince1970),
          .real(fixture.now.timeIntervalSince1970),
        ]
      )
    }
    try await expectUnsafeMaintenance(revision: "approved-command") { fixture, job in
      try await fixture.database.execute(
        """
        INSERT INTO approved_command_runs(
          id, job_id, job_attempt, job_step, phase, round, command_ordinal,
          command_id, plan_sha256, definition_sha256, registry_kind, workspace_path,
          workspace_device, workspace_inode, state, created_at, updated_at
        ) VALUES (?, ?, 0, 0, 'bootstrap', 1, 0, 'check', ?, ?, 'makeTargets',
                  '/private/tmp/workspace', 1, 1, 'prepared', ?, ?)
        """,
        bindings: [
          .text(UUID().uuidString.lowercased()),
          .text(job.id.uuidString.lowercased()),
          .text(String(repeating: "a", count: 64)),
          .text(String(repeating: "b", count: 64)),
          .real(fixture.now.timeIntervalSince1970),
          .real(fixture.now.timeIntervalSince1970),
        ]
      )
    }
    try await expectUnsafeMaintenance(revision: "mutation-intent") { fixture, job in
      _ = try await MutationIntentStore(database: fixture.database).prepare(
        jobID: job.id,
        idempotencyKey: String(repeating: "c", count: 64),
        operation: .bootstrapLabel,
        target: "repository-label",
        expectedStateDigest: String(repeating: "d", count: 64),
        requestDigest: String(repeating: "e", count: 64),
        now: fixture.now
      )
    }
  }

  @Test("maintenance batch rollback is all-or-nothing")
  func maintenanceBatchRollback() async throws {
    let fixture = try await JobStoreFixture()
    defer { fixture.remove() }
    let repositoryID = try await fixture.addRepository()
    let first = try await fixture.createJob(repositoryID: repositoryID, revision: "rollback-a")
    let second = try await fixture.createJob(repositoryID: repositoryID, revision: "rollback-b")
    let ordered = [first, second].sorted {
      $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
    }
    let failureTarget = try #require(ordered.last)
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1 WHERE singleton = 1"
    )
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let preview = try await fixture.jobs.previewMaintenance(scope: scope)
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    try await fixture.database.execute(
      """
      CREATE TRIGGER fail_maintenance_second_update
      BEFORE UPDATE ON jobs
      WHEN OLD.id = '\(failureTarget.id.uuidString.lowercased())'
      BEGIN SELECT RAISE(ABORT, 'injected maintenance failure'); END
      """
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.jobs.applyMaintenance(authorization, now: fixture.now)
    }
    #expect(try await fixture.jobs.job(id: first.id)?.state == .queued)
    #expect(try await fixture.jobs.job(id: second.id)?.state == .queued)
    #expect(try await fixture.jobs.disposition(for: first.identity)?.state == .inFlight)
    #expect(try await fixture.jobs.disposition(for: second.identity)?.state == .inFlight)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM job_transitions WHERE event_key GLOB 'maintenance:*'"
      ) == 0
    )
  }
}

private func blockForResourceFailure(
  fixture: JobStoreFixture,
  job: JobRecord,
  eventPrefix: String,
  now: Date
) async throws {
  for (suffix, event, reason) in [
    ("lease", JobEvent.acquireLease, "lease"),
    ("inputs", .inputsValidated, "inputs"),
    ("pi", .selectPiStep, "pi"),
    (
      "block", .piPermanentFailure,
      "job coordinator blocked after JidokaCodeCore.PiWorkflowResourceError"
    ),
  ] {
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "\(eventPrefix)-\(suffix)",
      event: event,
      context: JobTransitionContext(now: now, reason: reason)
    )
  }
}

private func expectUnsafeMaintenance(
  revision: String,
  prepare: (JobStoreFixture, JobRecord) async throws -> Void
) async throws {
  let fixture = try await JobStoreFixture()
  defer { fixture.remove() }
  let repositoryID = try await fixture.addRepository()
  let job = try await fixture.createJob(repositoryID: repositoryID, revision: revision)
  try await prepare(fixture, job)
  let scope = JobMaintenanceScope(
    operation: .retireBefore,
    boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
  )
  await #expect(throws: DurableJobStoreError.maintenanceCandidateUnsafe(job.id)) {
    _ = try await fixture.jobs.previewMaintenance(scope: scope)
  }
}

private struct DeterministicRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextInt(upperBound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return Int(state % UInt64(upperBound))
  }
}

private final class JobStoreFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let jobs: DurableJobStore
  let now = Date(timeIntervalSince1970: 10_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-job-store-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
    jobs = DurableJobStore(database: database)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func addRepository() async throws -> UUID {
    let id = UUID()
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', ?, 'main', ?, ?)
      """,
      bindings: [
        .text(id.uuidString.lowercased()),
        .text("node-\(id.uuidString.lowercased())"),
        .text("repo-\(id.uuidString.lowercased())"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    return id
  }

  func identity(
    repositoryID: UUID,
    revision: String = "revision"
  ) -> LogicalJobIdentity {
    LogicalJobIdentity(
      repositoryID: repositoryID,
      kind: .prReview,
      objectNodeID: "object-\(revision)",
      revisionKey: revision
    )
  }

  func createJob(
    repositoryID: UUID,
    revision: String = "revision"
  ) async throws -> JobRecord {
    try createdJob(
      try await jobs.createJob(
        identity: identity(repositoryID: repositoryID, revision: revision),
        contractVersionUsed: "contract-v1",
        priority: .prReview,
        firstStep: .review,
        now: now
      )
    )
  }

  func context(
    _ reason: String,
    notBefore: Date? = nil,
    evidenceDigest: String? = nil
  ) -> JobTransitionContext {
    JobTransitionContext(
      now: now,
      reason: reason,
      notBefore: notBefore,
      acceptanceEvidenceDigest: evidenceDigest
    )
  }
}

private func driveToReconciling(
  _ fixture: JobStoreFixture,
  job: JobRecord,
  prefix: String
) async throws {
  for (suffix, event) in [
    ("lease", JobEvent.acquireLease),
    ("inputs", .inputsValidated),
    ("execute", .selectLocalStep),
    ("reconcile", .mutationNeedsAttribution),
  ] {
    _ = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "\(prefix)-\(suffix)",
      event: event,
      context: fixture.context(suffix)
    )
  }
}

private func createdJob(_ result: JobCreationResult) throws -> JobRecord {
  guard case .created(let job) = result else {
    throw DurableJobStoreError.decode("expected created job")
  }
  return job
}

private func suppressedDisposition(
  _ result: JobCreationResult
) throws -> ObjectDispositionRecord {
  guard case .suppressed(let disposition) = result else {
    throw DurableJobStoreError.decode("expected suppressed disposition")
  }
  return disposition
}

private func appliedJob(_ result: JobTransitionResult) throws -> JobRecord {
  guard case .applied(let job) = result else {
    throw DurableJobStoreError.decode("expected applied transition")
  }
  return job
}

private func duplicateJob(_ result: JobTransitionResult) throws -> JobRecord {
  guard case .duplicate(let job) = result else {
    throw DurableJobStoreError.decode("expected duplicate transition")
  }
  return job
}
