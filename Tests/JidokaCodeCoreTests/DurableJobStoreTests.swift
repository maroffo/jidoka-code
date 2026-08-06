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
    await #expect(throws: SQLiteStoreError.self) {
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
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM job_steps WHERE job_id = ?",
        bindings: [.text(job.id.uuidString.lowercased())]
      ) == 1
    )
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
    #expect(try await fixture.jobs.activeLeases().count == 2)

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
      jobID: a2.id,
      eventKey: "a2-lease",
      event: .acquireLease,
      context: fixture.context("lease")
    )
    let leases = try await fixture.jobs.activeLeases()
    let a2Lease = try #require(leases.first { $0.jobID == a2.id })
    #expect(a2Lease.generation == 2)
    #expect(Set(leases.map(\.repositoryID)).count == leases.count)
    #expect(leases.count == 2)
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
      } else if active.count < 2,
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
      #expect(leases.count <= 2)
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
    let attributed = try await fixture.jobs.transition(
      jobID: job.id,
      eventKey: "stale-attributed",
      event: .effectAttributedMore,
      context: fixture.context("approval removal attributed")
    )
    #expect(try appliedJob(attributed).state == .preparing)
    #expect(try appliedJob(attributed).currentStep == 1)
    #expect(try appliedJob(attributed).currentStepKind == .replan)
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
