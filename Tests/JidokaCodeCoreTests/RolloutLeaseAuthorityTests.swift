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

  func leaseHeartbeat() async throws -> Date? {
    let rows = try await database.query("SELECT heartbeat FROM repository_leases")
    guard case .real(let value)? = rows.first?["heartbeat"] else { return nil }
    return Date(timeIntervalSince1970: value)
  }
}
