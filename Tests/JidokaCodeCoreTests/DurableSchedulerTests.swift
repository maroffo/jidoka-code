import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable scheduler")
struct DurableSchedulerTests {
  @Test("immediate triggers are bounded and overlapping passes coalesce once")
  func timingAndOverlap() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var timing = SchedulerTimingState(now: now)
    timing.request(.startup, now: now)
    let due = try #require(timing.snapshot.dueAt)
    #expect(due.timeIntervalSince(now) <= SchedulerTimingState.immediateUpperBound)
    let tooEarly = timing.takeDuePass(now: now)
    #expect(tooEarly == nil)

    let firstValue = timing.takeDuePass(
      now: now.addingTimeInterval(SchedulerTimingState.immediateDebounce)
    )
    let first = try #require(firstValue)
    #expect(first.reasons == [.startup])
    timing.request(.wake, now: now.addingTimeInterval(2))
    timing.request(.networkRegained, now: now.addingTimeInterval(2))
    timing.request(.wake, now: now.addingTimeInterval(2))
    let overlapping = timing.takeDuePass(now: now.addingTimeInterval(2))
    #expect(overlapping == nil)

    timing.finishPass(now: now.addingTimeInterval(3))
    let coalescedValue = timing.takeDuePass(now: now.addingTimeInterval(3))
    let coalesced = try #require(coalescedValue)
    #expect(Set(coalesced.reasons) == [.wake, .networkRegained])
    timing.finishPass(now: now.addingTimeInterval(4))
    let noThirdPass = timing.takeDuePass(now: now.addingTimeInterval(4))
    #expect(noThirdPass == nil)
  }

  @Test("pause drops pending triggers and resume schedules one immediate pass")
  func pauseResume() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var timing = SchedulerTimingState(now: now)
    timing.request(.manual, now: now)
    timing.setPaused(true, now: now)
    #expect(timing.snapshot.paused)
    #expect(timing.snapshot.pendingReasons.isEmpty)
    #expect(timing.snapshot.dueAt == nil)
    timing.request(.wake, now: now)
    #expect(timing.snapshot.pendingReasons.isEmpty)

    timing.setPaused(false, now: now.addingTimeInterval(10))
    #expect(!timing.snapshot.paused)
    let passValue = timing.takeDuePass(now: now.addingTimeInterval(11))
    let pass = try #require(passValue)
    #expect(pass.reasons == [.resume])
  }

  @Test("periodic tick is exactly 600 seconds")
  func periodicTick() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var timing = SchedulerTimingState(now: now)
    let beforeTick = timing.takeDuePass(now: now.addingTimeInterval(599))
    #expect(beforeTick == nil)
    let passValue = timing.takeDuePass(now: now.addingTimeInterval(600))
    let pass = try #require(passValue)
    #expect(pass.reasons == [.periodic])
    timing.finishPass(now: now.addingTimeInterval(601))
    #expect(
      timing.snapshot.nextPeriodicAt
        == now.addingTimeInterval(1_200)
    )
  }

  @Test("priority order is locked while starvation is observation-only")
  func priorityAndStarvation() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    var queue = SchedulerQueue()
    let triage = UUID()
    let review = UUID()
    let recovery = UUID()
    let implementation = UUID()
    let approved = UUID()
    let repositoryID = UUID()

    let insertedTriage = queue.enqueue(
      id: triage,
      repositoryID: repositoryID,
      priority: .triage,
      now: now.addingTimeInterval(-10_000)
    )
    let insertedReview = queue.enqueue(
      id: review, repositoryID: repositoryID, priority: .prReview, now: now)
    let insertedRecovery = queue.enqueue(
      id: recovery, repositoryID: repositoryID, priority: .recovery, now: now)
    let insertedImplementation = queue.enqueue(
      id: implementation,
      repositoryID: repositoryID,
      priority: .issueImplementation,
      now: now
    )
    let insertedApproved = queue.enqueue(
      id: approved,
      repositoryID: repositoryID,
      priority: .approvedComplex,
      now: now
    )
    let insertedDuplicate = queue.enqueue(
      id: triage, repositoryID: repositoryID, priority: .recovery, now: now)
    #expect(insertedTriage)
    #expect(insertedReview)
    #expect(insertedRecovery)
    #expect(insertedImplementation)
    #expect(insertedApproved)
    #expect(!insertedDuplicate)
    #expect(
      queue.ordered().map(\.id) == [
        recovery, approved, review, implementation, triage,
      ])

    let first = queue.dequeue(now: now, starvationThreshold: 3_600)
    #expect(first.job?.id == recovery)
    let observation = try #require(first.observations.first { $0.jobID == triage })
    #expect(observation.waitedSeconds == 10_000)
    #expect(queue.ordered().last?.id == triage)
  }

  @Test("repository backoff persists 60 through 1800 seconds and resets")
  func persistedBackoff() async throws {
    let fixture = try await SchedulerDatabaseFixture()
    defer { fixture.remove() }
    let persistence = SchedulerPersistence(database: fixture.database)
    let expected: [TimeInterval] = [60, 120, 240, 480, 960, 1_800, 1_800]
    for (index, delay) in expected.enumerated() {
      let record = try await persistence.recordFailure(
        repositoryID: fixture.repositoryID,
        reason: "read failure",
        now: fixture.now,
        jitterFraction: 0
      )
      #expect(record.failureCount == index + 1)
      #expect(record.notBefore == fixture.now.addingTimeInterval(delay))
    }

    await fixture.database.close()
    let reopenedDatabase = try SQLiteStore(databaseURL: fixture.databaseURL)
    let reopened = SchedulerPersistence(database: reopenedDatabase)
    #expect(try await reopened.backoff(repositoryID: fixture.repositoryID)?.failureCount == 7)
    try await reopened.recordSuccess(repositoryID: fixture.repositoryID)
    #expect(try await reopened.backoff(repositoryID: fixture.repositoryID) == nil)

    let serverReset = fixture.now.addingTimeInterval(900)
    let rateLimited = try await reopened.recordFailure(
      repositoryID: fixture.repositoryID,
      reason: "rate reset",
      now: fixture.now,
      jitterFraction: 0.1,
      serverReset: serverReset
    )
    #expect(rateLimited.notBefore == serverReset)
    await #expect(throws: RepositoryBackoffError.invalidJitter) {
      _ = try await reopened.recordFailure(
        repositoryID: fixture.repositoryID,
        reason: "invalid",
        now: fixture.now,
        jitterFraction: 0.2
      )
    }
    await reopenedDatabase.close()
  }

  @Test("injected virtual clock drives startup, periodic, wake, and network triggers")
  func virtualClockMatrix() async throws {
    let initial = Date(timeIntervalSince1970: 5_000)
    let clock = VirtualSchedulerClock(now: initial)
    let runner = RecordingSchedulerRunner()
    let scheduler = DurableScheduler(
      clock: clock,
      runner: runner,
      initialNow: initial
    )

    await scheduler.request(.startup)
    #expect(!(await scheduler.runDuePass()))
    await clock.advance(to: initial.addingTimeInterval(1))
    #expect(await scheduler.runDuePass())
    #expect(await runner.passes().map(\.reasons) == [[.startup]])

    await clock.advance(to: initial.addingTimeInterval(600))
    #expect(await scheduler.runDuePass())
    #expect(await runner.passes().last?.reasons == [.periodic])

    await scheduler.request(.wake)
    await scheduler.request(.networkRegained)
    await clock.advance(to: initial.addingTimeInterval(601))
    #expect(await scheduler.runDuePass())
    #expect(Set(try #require(await runner.passes().last).reasons) == [.wake, .networkRegained])
  }

  @Test("a sleeping run loop wakes for an immediate trigger")
  func sleepingLoopWakes() async throws {
    let initial = Date(timeIntervalSince1970: 6_000)
    let clock = VirtualSchedulerClock(now: initial)
    let runner = RecordingSchedulerRunner()
    let scheduler = DurableScheduler(
      clock: clock,
      runner: runner,
      initialNow: initial
    )
    let loop = Task { await scheduler.run() }
    defer { loop.cancel() }

    try await waitUntil {
      await clock.recordedDeadlines().count >= 1
    }
    #expect(await clock.recordedDeadlines().first == initial.addingTimeInterval(600))

    await scheduler.request(.wake)
    try await waitUntil {
      await clock.recordedDeadlines().count >= 2
    }
    #expect(await clock.recordedDeadlines()[1] == initial.addingTimeInterval(1))

    await clock.advance(to: initial.addingTimeInterval(1))
    try await waitUntil {
      await runner.passes().count == 1
    }
    #expect(await runner.passes().first?.reasons == [.wake])

    await scheduler.stop()
    await loop.value
  }

  @Test("startup coordinator persists recovery before scheduling discovery")
  func startupOrdersRecoveryFirst() async throws {
    let fixture = try await SchedulerDatabaseFixture()
    defer { fixture.remove() }
    let jobs = DurableJobStore(database: fixture.database)
    let identity = LogicalJobIdentity(
      repositoryID: fixture.repositoryID,
      kind: .issueTriage,
      objectNodeID: "issue",
      revisionKey: "initial-triage"
    )
    let created = try await jobs.createJob(
      identity: identity,
      contractVersionUsed: "v1",
      priority: .triage,
      firstStep: .triage,
      now: fixture.now
    )
    guard case .created(let job) = created else {
      Issue.record("job creation was suppressed")
      return
    }
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'runningPi' WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )

    let clock = VirtualSchedulerClock(now: fixture.now)
    let runner = RecordingSchedulerRunner()
    let scheduler = DurableScheduler(
      clock: clock,
      runner: runner,
      initialNow: fixture.now
    )
    let startup = StartupCoordinator(jobs: jobs, scheduler: scheduler)
    _ = try await startup.start(now: fixture.now)

    let recovered = try #require(try await jobs.job(id: job.id))
    #expect(recovered.state == .reconciliationQueued)
    #expect(await runner.passes().isEmpty)
    #expect((await scheduler.snapshot()).pendingReasons == [.startup])
  }
}

private actor VirtualSchedulerClock: SchedulerClock {
  private typealias PendingSleep = (
    deadline: Date,
    continuation: CheckedContinuation<Void, Error>
  )

  private var current: Date
  private var pending: [UUID: PendingSleep] = [:]
  private var deadlines: [Date] = []

  init(now: Date) {
    current = now
  }

  func now() -> Date { current }

  func sleep(until deadline: Date) async throws {
    guard deadline > current else { return }
    let id = UUID()
    deadlines.append(deadline)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[id] = (deadline, continuation)
        }
      }
    } onCancel: {
      Task { await self.cancelSleep(id: id) }
    }
  }

  func advance(to date: Date) {
    precondition(date >= current)
    current = date
    let ready = pending.compactMap { id, sleep in
      sleep.deadline <= date ? id : nil
    }
    for id in ready {
      pending.removeValue(forKey: id)?.continuation.resume()
    }
  }

  func recordedDeadlines() -> [Date] { deadlines }

  private func cancelSleep(id: UUID) {
    pending.removeValue(forKey: id)?.continuation.resume(
      throwing: CancellationError()
    )
  }
}

private enum VirtualClockError: Error {
  case timeout
}

private func waitUntil(
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<1_000 {
    if await condition() { return }
    try await Task.sleep(nanoseconds: 1_000_000)
  }
  throw VirtualClockError.timeout
}

private actor RecordingSchedulerRunner: SchedulerPassRunner {
  private var recorded: [SchedulerPass] = []

  func run(pass: SchedulerPass) async {
    recorded.append(pass)
  }

  func passes() -> [SchedulerPass] { recorded }
}

private final class SchedulerDatabaseFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let database: SQLiteStore
  let repositoryID = UUID()
  let now = Date(timeIntervalSince1970: 20_000)

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-scheduler-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    databaseURL = root.appendingPathComponent("jidoka-code.sqlite3")
    database = try SQLiteStore(databaseURL: databaseURL)
    try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch, created_at, updated_at
      ) VALUES (?, ?, 'owner', 'repo', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text("node-\(repositoryID.uuidString.lowercased())"),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
