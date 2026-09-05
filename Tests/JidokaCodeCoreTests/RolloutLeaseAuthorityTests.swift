// ABOUTME: Pins the repository-lease rollout gate: which lanes arm it and which updates it admits.
// ABOUTME: Covers direct insert, cross-repository, post-close, reactivation, renewal, pause and drain.
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Repository lease rollout authority")
struct RolloutLeaseAuthorityTests {
  @Test("an empty authorization table leaves ordinary generation-0 leases admissible")
  func generationZeroLeaseWithoutAnyAuthorization() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let job = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")

    try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: job.id)
    #expect(try await fixture.activeLeaseCount() == 1)
    await fixture.database.close()
  }

  @Test("an open lane on one repository never gates another repository")
  func openLaneDoesNotGateAnotherRepository() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    let other = try await fixture.createJob(repositoryID: fixture.repositoryB, revision: "rev-b")

    try await fixture.insertLease(repositoryID: fixture.repositoryB, jobID: other.id)
    #expect(try await fixture.activeLeaseCount() == 1)
    await fixture.database.close()
  }

  @Test("an open lane rejects an unbound generation-0 lease on its own repository")
  func openLaneRejectsUnboundJobOnSameRepository() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    let unbound = try await fixture.createJob(
      repositoryID: fixture.repositoryA,
      revision: "rev-unbound"
    )
    #expect(try await fixture.rolloutGeneration(jobID: unbound.id) == 0)

    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: unbound.id)
    }
    #expect(try await fixture.activeLeaseCount() == 0)
    await fixture.database.close()
  }

  @Test("every closed authorization state releases the gate for ordinary jobs")
  func closedAuthorizationsDoNotGateFutureLeases() async throws {
    for (state, reason) in [
      ("settled", "completed"), ("revoked", "operator"), ("expired", "expiry"),
      ("failed", "fault"),
    ] {
      let fixture = try await RolloutLeaseFixture()
      let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
      _ = try await fixture.activateExactPullRequestRollout(
        repositoryID: fixture.repositoryA,
        job: bound
      )
      try await fixture.close(state: state, reason: reason)
      let ordinary = try await fixture.createJob(
        repositoryID: fixture.repositoryA,
        revision: "rev-after-\(state)"
      )

      try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: ordinary.id)
      #expect(try await fixture.activeLeaseCount() == 1, "\(state)")

      // The authorization row itself survives: the gate opened because the lane
      // closed, not because history was erased.
      #expect(try await fixture.authorizationCount() == 1, "\(state)")
      await fixture.database.close()
      fixture.remove()
    }
  }

  @Test("reactivating a released lease is admission and stays gated while a lane is open")
  func reactivationRemainsGated() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
    try await fixture.releaseLease(repositoryID: fixture.repositoryA)
    let unbound = try await fixture.createJob(
      repositoryID: fixture.repositoryA,
      revision: "rev-unbound"
    )

    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.reactivateLease(repositoryID: fixture.repositoryA, jobID: unbound.id)
    }
    // The bound job may retake it: admission is checked, not blocked outright.
    try await fixture.reactivateLease(repositoryID: fixture.repositoryA, jobID: bound.id)
    #expect(try await fixture.activeLeaseCount() == 1)
    await fixture.database.close()
  }

  @Test("pause and drain stop admission but never a held lease's heartbeat")
  func heartbeatSurvivesPauseAndDrain() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
    try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now.addingTimeInterval(30))

    // Pausing is the mandatory first step of closing a lane.
    try await fixture.setPaused(true)
    try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now.addingTimeInterval(60))
    #expect(try await fixture.leaseHeartbeat() == fixture.now.addingTimeInterval(60))

    try await fixture.setAuthorizationState("draining")
    try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now.addingTimeInterval(90))
    #expect(try await fixture.leaseHeartbeat() == fixture.now.addingTimeInterval(90))

    // A renewal past the authorization's own expiry still only continues the lease.
    try await fixture.jobs.heartbeat(
      jobID: bound.id,
      now: fixture.now.addingTimeInterval(30 * 24 * 3_600)
    )

    // Release must remain possible after the drain.
    try await fixture.releaseLease(repositoryID: fixture.repositoryA)
    #expect(try await fixture.activeLeaseCount() == 0)
    await fixture.database.close()
  }

  @Test("a paused or draining lane still refuses fresh admission")
  func admissionDeniedWhilePausedOrDraining() async throws {
    for state in ["active", "draining", "recoveryRequired"] {
      let fixture = try await RolloutLeaseFixture()
      let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
      _ = try await fixture.activateExactPullRequestRollout(
        repositoryID: fixture.repositoryA,
        job: bound
      )
      try await fixture.setPaused(true)
      try await fixture.setAuthorizationState(state)

      await #expect(throws: SQLiteStoreError.self, "\(state)") {
        try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
      }
      #expect(try await fixture.activeLeaseCount() == 0, "\(state)")
      await fixture.database.close()
      fixture.remove()
    }
  }

  @Test("a generation-1 job stays gated after its own lane has closed")
  func generationOneLeaseGatedAfterLaneClosed() async throws {
    for (state, reason) in [
      ("settled", "completed"), ("revoked", "operator"), ("expired", "expiry"),
      ("failed", "fault"),
    ] {
      let fixture = try await RolloutLeaseFixture()
      let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
      _ = try await fixture.activateExactPullRequestRollout(
        repositoryID: fixture.repositoryA,
        job: bound
      )
      #expect(try await fixture.rolloutGeneration(jobID: bound.id) == 1, "\(state)")
      try await fixture.close(state: state, reason: reason)

      // Arming on lane state alone would leave this job ungated for ever once its
      // lane closed. A job an authorization promoted always needs one.
      await #expect(throws: SQLiteStoreError.self, "\(state)") {
        try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
      }
      #expect(try await fixture.activeLeaseCount() == 0, "\(state)")
      await fixture.database.close()
      fixture.remove()
    }
  }

  @Test("a generation-1 job stays gated even where no lane was ever opened")
  func generationOneLeaseGatedWithoutAnyLane() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    try await fixture.close(state: "settled", reason: "completed")
    // Move the promoted job to a repository that never had an authorization at all.
    try await fixture.database.execute(
      "UPDATE jobs SET repository_id = ? WHERE id = ?",
      bindings: [
        .text(fixture.repositoryB.uuidString.lowercased()),
        .text(bound.id.uuidString.lowercased()),
      ]
    )

    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.insertLease(repositoryID: fixture.repositoryB, jobID: bound.id)
    }
    #expect(try await fixture.activeLeaseCount() == 0)
    await fixture.database.close()
  }

  @Test("a lease the open lane does not bind stops being a continuation")
  func unboundLeaseLosesContinuationWhenALaneOpens() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    // Ordinary generation-0 work, admitted before any lane exists and therefore
    // never seen by the gate.
    let ordinary = try await fixture.createJob(
      repositoryID: fixture.repositoryA, revision: "rev-ord")
    try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: ordinary.id)
    try await fixture.jobs.heartbeat(jobID: ordinary.id, now: fixture.now.addingTimeInterval(30))

    // Activation deliberately does not require a lease-free repository: a rollout
    // binds a job already in flight, which legitimately holds the lease. What must
    // not survive is a continuation for a lease the lane never bound.
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    await #expect(throws: (any Error).self) {
      try await fixture.jobs.heartbeat(
        jobID: ordinary.id,
        now: fixture.now.addingTimeInterval(60)
      )
    }
    #expect(try await fixture.leaseHeartbeat() == fixture.now.addingTimeInterval(30))

    // The lane's own bound job is the contrast: same open lane, and it continues.
    try await fixture.releaseLease(repositoryID: fixture.repositoryA)
    try await fixture.reactivateLease(repositoryID: fixture.repositoryA, jobID: bound.id)
    try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now.addingTimeInterval(90))
    #expect(try await fixture.leaseHeartbeat() == fixture.now.addingTimeInterval(90))
    await fixture.database.close()
  }

  @Test("a live lease cannot be handed to another job or repository")
  func continuationRequiresUnchangedIdentity() async throws {
    for drift in LeaseIdentityDrift.allCases {
      let fixture = try await RolloutLeaseFixture()
      let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
      _ = try await fixture.activateExactPullRequestRollout(
        repositoryID: fixture.repositoryA,
        job: bound
      )
      try await fixture.insertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
      let other = try await fixture.createJob(
        repositoryID: fixture.repositoryA, revision: "rev-other")

      // Each of these keeps OLD.active = 1, so only the exemption's identity
      // conjuncts separate them from an ordinary heartbeat. The generation case
      // pauses first: a fencing bump on the lane's own bound job is legitimate
      // while the lane is running, so what must be proved is that it is *gated*
      // rather than exempt — under pause it has to abort where a plain heartbeat,
      // which changes no identity, still succeeds.
      if drift == .generation {
        try await fixture.setPaused(true)
        try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now.addingTimeInterval(5))
      }
      await #expect(throws: SQLiteStoreError.self, "\(drift)") {
        switch drift {
        case .job:
          try await fixture.database.execute(
            "UPDATE repository_leases SET job_id = ? WHERE repository_id = ?",
            bindings: [
              .text(other.id.uuidString.lowercased()),
              .text(fixture.repositoryA.uuidString.lowercased()),
            ]
          )
        case .repository:
          try await fixture.database.execute(
            "UPDATE repository_leases SET repository_id = ? WHERE repository_id = ?",
            bindings: [
              .text(fixture.repositoryB.uuidString.lowercased()),
              .text(fixture.repositoryA.uuidString.lowercased()),
            ]
          )
        case .generation:
          try await fixture.database.execute(
            "UPDATE repository_leases SET generation = generation + 1 WHERE repository_id = ?",
            bindings: [.text(fixture.repositoryA.uuidString.lowercased())]
          )
        }
      }
      await fixture.database.close()
      fixture.remove()
    }
  }

  @Test("the upsert lease shape is gated exactly like the plain statements")
  func upsertShapeMatchesPlainStatements() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    let unbound = try await fixture.createJob(
      repositoryID: fixture.repositoryA, revision: "rev-unbound")

    // JobCanary acquires leases with INSERT ... ON CONFLICT DO UPDATE, so the gate has
    // to hold on both branches of that one statement. The insert branch first, with no
    // row to conflict with.
    await #expect(throws: SQLiteStoreError.self, "unbound upsert, insert branch") {
      try await fixture.upsertLease(repositoryID: fixture.repositoryA, jobID: unbound.id)
    }
    try await fixture.upsertLease(repositoryID: fixture.repositoryA, jobID: bound.id)
    #expect(try await fixture.activeLeaseCount() == 1)

    // And now the conflict branch, which is the one the INSERT trigger would miss if
    // SQLite only fired it when a row is actually inserted. It does not: BEFORE INSERT
    // runs before the conflict is resolved, so the same verdict applies.
    await #expect(throws: SQLiteStoreError.self, "unbound upsert, conflict branch") {
      try await fixture.upsertLease(repositoryID: fixture.repositoryA, jobID: unbound.id)
    }
    #expect(try await fixture.leaseJobID() == bound.id)
    #expect(try await fixture.activeLeaseCount() == 1)
    await fixture.database.close()
  }

  @Test("a missing lease still reports a typed error rather than a raw SQLite abort")
  func heartbeatWithoutLeaseIsTyped() async throws {
    let fixture = try await RolloutLeaseFixture()
    defer { fixture.remove() }
    let bound = try await fixture.createJob(repositoryID: fixture.repositoryA, revision: "rev-a")
    _ = try await fixture.activateExactPullRequestRollout(
      repositoryID: fixture.repositoryA,
      job: bound
    )
    try await fixture.setPaused(true)

    await #expect(throws: DurableJobStoreError.leaseMissing(bound.id)) {
      try await fixture.jobs.heartbeat(jobID: bound.id, now: fixture.now)
    }
    await fixture.database.close()
  }
}

private enum LeaseIdentityDrift: CaseIterable {
  case job
  case repository
  case generation
}

private final class RolloutLeaseFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let jobs: DurableJobStore
  let now = Date(timeIntervalSince1970: 10_000)
  let repositoryA = UUID()
  let repositoryB = UUID()

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-rollout-lease-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("jidoka-code.sqlite3"))
    jobs = DurableJobStore(database: database, enforceRolloutAuthority: false)
    try await insertRepository(repositoryA, suffix: "a")
    try await insertRepository(repositoryB, suffix: "b")
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private func insertRepository(_ id: UUID, suffix: String) async throws {
    try await database.execute(
      """
      INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at)
      VALUES (?, ?, ?, ?, 'main', ?, ?)
      """,
      bindings: [
        .text(id.uuidString.lowercased()),
        .text("node-\(id.uuidString.lowercased())"),
        .text("owner-\(suffix)"),
        .text("repo-\(suffix)"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  func configuration(for id: UUID) -> RepositoryConfiguration {
    RepositoryConfiguration(
      id: id,
      nodeID: "node-\(id.uuidString.lowercased())",
      owner: id == repositoryA ? "owner-a" : "owner-b",
      name: id == repositoryA ? "repo-a" : "repo-b",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
  }

  func createJob(repositoryID: UUID, revision: String) async throws -> JobRecord {
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .prReview,
        objectNodeID: "object-\(revision)",
        revisionKey: revision
      ),
      objectNumber: abs(revision.hashValue % 900) + 1,
      contractVersionUsed: "contract-v1",
      priority: .prReview,
      firstStep: .review,
      now: now
    )
    guard case .created(let job) = created else {
      throw TestRolloutFixtureError.invalidJob
    }
    return job
  }

  func activateExactPullRequestRollout(
    repositoryID: UUID,
    job: JobRecord
  ) async throws -> RolloutAuthorityStore {
    try await activateTestPullRequestRollout(
      database: database,
      repository: configuration(for: repositoryID),
      job: job,
      baseSHA: String(repeating: "a", count: 40),
      headSHA: String(repeating: "b", count: 40),
      now: now
    )
  }

  func insertLease(repositoryID: UUID, jobID: UUID) async throws {
    try await database.execute(
      """
      INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
      VALUES (?, ?, 1, ?, 1)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text(jobID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  /// The shape `JobCanary` uses: SQLite fires BEFORE INSERT here even on conflict.
  func upsertLease(repositoryID: UUID, jobID: UUID) async throws {
    try await database.execute(
      """
      INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
      VALUES (?, ?, 1, ?, 1)
      ON CONFLICT(repository_id) DO UPDATE SET
        job_id = excluded.job_id, generation = excluded.generation,
        heartbeat = excluded.heartbeat, active = 1
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text(jobID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  func reactivateLease(repositoryID: UUID, jobID: UUID) async throws {
    try await database.execute(
      """
      UPDATE repository_leases
      SET job_id = ?, generation = generation + 1, heartbeat = ?, active = 1
      WHERE repository_id = ?
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
        .text(repositoryID.uuidString.lowercased()),
      ]
    )
  }

  func releaseLease(repositoryID: UUID) async throws {
    try await database.execute(
      "UPDATE repository_leases SET active = 0, heartbeat = ? WHERE repository_id = ?",
      bindings: [
        .real(now.timeIntervalSince1970),
        .text(repositoryID.uuidString.lowercased()),
      ]
    )
  }

  func setPaused(_ paused: Bool) async throws {
    try await database.execute(
      "UPDATE app_settings SET paused = ? WHERE singleton = 1",
      bindings: [.integer(paused ? 1 : 0)]
    )
  }

  func setAuthorizationState(_ state: String) async throws {
    // The schema allows metadata to move only alongside a real state change.
    try await database.execute(
      """
      UPDATE rollout_authorizations
      SET state = ?, updated_at_ms = updated_at_ms + 1
      WHERE state <> ?
      """,
      bindings: [.text(state), .text(state)]
    )
  }

  func close(state: String, reason: String) async throws {
    try await setPaused(true)
    try await database.execute(
      """
      UPDATE rollout_authorizations
      SET state = ?, terminal_reason = ?, updated_at_ms = updated_at_ms + 1
      """,
      bindings: [.text(state), .text(reason)]
    )
  }

  func activeLeaseCount() async throws -> Int {
    Int(
      try await database.scalarInt("SELECT COUNT(*) FROM repository_leases WHERE active = 1")
        ?? -1
    )
  }

  func authorizationCount() async throws -> Int {
    Int(try await database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") ?? -1)
  }

  func rolloutGeneration(jobID: UUID) async throws -> Int {
    Int(
      try await database.scalarInt(
        "SELECT rollout_generation FROM jobs WHERE id = ?",
        bindings: [.text(jobID.uuidString.lowercased())]
      ) ?? -1
    )
  }

  func leaseJobID() async throws -> UUID? {
    let rows = try await database.query("SELECT job_id FROM repository_leases")
    guard case .text(let value)? = rows.first?["job_id"] else { return nil }
    return UUID(uuidString: value)
  }

  func leaseHeartbeat() async throws -> Date? {
    let rows = try await database.query("SELECT heartbeat FROM repository_leases")
    guard case .real(let value)? = rows.first?["heartbeat"] else { return nil }
    return Date(timeIntervalSince1970: value)
  }
}
