import Foundation

public enum SchedulerTriggerReason: String, CaseIterable, Codable, Sendable {
  case startup
  case periodic
  case wake
  case networkRegained
  case resume
  case manual
}

public struct SchedulerPass: Equatable, Sendable {
  public let reasons: [SchedulerTriggerReason]
  public let startedAt: Date
}

public struct SchedulerTimingSnapshot: Equatable, Sendable {
  public let paused: Bool
  public let passRunning: Bool
  public let pendingReasons: Set<SchedulerTriggerReason>
  public let dueAt: Date?
  public let nextPeriodicAt: Date
}

public struct SchedulerTimingState: Sendable {
  public static let periodicInterval: TimeInterval = 600
  public static let immediateDebounce: TimeInterval = 1
  public static let immediateUpperBound: TimeInterval = 30

  private(set) var paused = false
  private(set) var passRunning = false
  private(set) var pendingReasons: Set<SchedulerTriggerReason> = []
  private(set) var dueAt: Date?
  private(set) var nextPeriodicAt: Date

  public init(now: Date) {
    nextPeriodicAt = now.addingTimeInterval(Self.periodicInterval)
  }

  public var snapshot: SchedulerTimingSnapshot {
    SchedulerTimingSnapshot(
      paused: paused,
      passRunning: passRunning,
      pendingReasons: pendingReasons,
      dueAt: dueAt,
      nextPeriodicAt: nextPeriodicAt
    )
  }

  public mutating func request(
    _ reason: SchedulerTriggerReason,
    now: Date
  ) {
    guard !paused else { return }
    pendingReasons.insert(reason)
    guard !passRunning else { return }
    let candidate = now.addingTimeInterval(Self.immediateDebounce)
    dueAt = min(dueAt ?? candidate, candidate)
  }

  public mutating func setPaused(_ value: Bool, now: Date) {
    guard value != paused else { return }
    paused = value
    if value {
      pendingReasons.removeAll()
      dueAt = nil
    } else {
      request(.resume, now: now)
    }
  }

  public mutating func takeDuePass(now: Date) -> SchedulerPass? {
    guard !paused, !passRunning else { return nil }
    if now >= nextPeriodicAt {
      pendingReasons.insert(.periodic)
      dueAt = min(dueAt ?? now, now)
    }
    guard !pendingReasons.isEmpty, let dueAt, dueAt <= now else { return nil }

    let reasons = pendingReasons.sorted { $0.rawValue < $1.rawValue }
    pendingReasons.removeAll()
    self.dueAt = nil
    passRunning = true
    if reasons.contains(.periodic) {
      nextPeriodicAt = now.addingTimeInterval(Self.periodicInterval)
    }
    return SchedulerPass(reasons: reasons, startedAt: now)
  }

  public mutating func finishPass(now: Date) {
    guard passRunning else { return }
    passRunning = false
    guard !paused, !pendingReasons.isEmpty else { return }
    dueAt = now
  }

  public func nextWakeDate() -> Date? {
    guard !paused, !passRunning else { return nil }
    if let dueAt { return min(dueAt, nextPeriodicAt) }
    return nextPeriodicAt
  }
}

public struct QueuedJob: Equatable, Sendable {
  public let id: UUID
  public let repositoryID: UUID
  public let priority: JobPriority
  public let enqueuedAt: Date
  fileprivate let sequence: UInt64

  public init(
    id: UUID,
    repositoryID: UUID,
    priority: JobPriority,
    enqueuedAt: Date,
    sequence: UInt64 = 0
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.priority = priority
    self.enqueuedAt = enqueuedAt
    self.sequence = sequence
  }
}

public struct StarvationObservation: Equatable, Sendable {
  public let jobID: UUID
  public let priority: JobPriority
  public let waitedSeconds: TimeInterval
}

public struct SchedulerQueue: Sendable {
  private var jobs: [UUID: QueuedJob] = [:]
  private var nextSequence: UInt64 = 0

  public init() {}

  public var count: Int { jobs.count }

  @discardableResult
  public mutating func enqueue(
    id: UUID,
    repositoryID: UUID,
    priority: JobPriority,
    now: Date
  ) -> Bool {
    guard jobs[id] == nil else { return false }
    jobs[id] = QueuedJob(
      id: id,
      repositoryID: repositoryID,
      priority: priority,
      enqueuedAt: now,
      sequence: nextSequence
    )
    nextSequence &+= 1
    return true
  }

  public mutating func remove(id: UUID) -> QueuedJob? {
    jobs.removeValue(forKey: id)
  }

  public func ordered() -> [QueuedJob] {
    jobs.values.sorted(by: Self.precedes)
  }

  public mutating func dequeue(
    now: Date,
    starvationThreshold: TimeInterval
  ) -> (job: QueuedJob?, observations: [StarvationObservation]) {
    let ordered = ordered()
    let observations = ordered.compactMap { job -> StarvationObservation? in
      let wait = max(0, now.timeIntervalSince(job.enqueuedAt))
      guard wait >= starvationThreshold else { return nil }
      return StarvationObservation(
        jobID: job.id,
        priority: job.priority,
        waitedSeconds: wait
      )
    }
    guard let first = ordered.first else { return (nil, observations) }
    return (jobs.removeValue(forKey: first.id), observations)
  }

  private static func precedes(_ lhs: QueuedJob, _ rhs: QueuedJob) -> Bool {
    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
    if lhs.enqueuedAt != rhs.enqueuedAt { return lhs.enqueuedAt < rhs.enqueuedAt }
    return lhs.sequence < rhs.sequence
  }
}

public struct RepositoryBackoffRecord: Equatable, Sendable {
  public let repositoryID: UUID
  public let failureCount: Int
  public let notBefore: Date
  public let reason: String
}

public enum RepositoryBackoffError: Error, Equatable, Sendable {
  case invalidJitter
  case invalidReason
  case decode
}

public enum RepositoryBackoffPolicy {
  public static let delays: [TimeInterval] = [60, 120, 240, 480, 960, 1_800]

  public static func delay(
    failureCount: Int,
    jitterFraction: Double
  ) throws -> TimeInterval {
    guard (-0.1...0.1).contains(jitterFraction) else {
      throw RepositoryBackoffError.invalidJitter
    }
    let index = min(max(1, failureCount), delays.count) - 1
    return min(1_800, delays[index] * (1 + jitterFraction))
  }
}

public actor SchedulerPersistence {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  public func recordFailure(
    repositoryID: UUID,
    reason: String,
    now: Date,
    jitterFraction: Double = 0,
    serverReset: Date? = nil
  ) async throws -> RepositoryBackoffRecord {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == reason else {
      throw RepositoryBackoffError.invalidReason
    }
    return try await database.transaction { database in
      let previous = Int(
        try database.scalarInt(
          "SELECT failure_count FROM repository_backoff WHERE repository_id = ?",
          bindings: [.text(repositoryID.uuidString.lowercased())]
        ) ?? 0
      )
      let failureCount = previous + 1
      let delay = try RepositoryBackoffPolicy.delay(
        failureCount: failureCount,
        jitterFraction: jitterFraction
      )
      var notBefore = now.addingTimeInterval(delay)
      if let serverReset, serverReset > notBefore { notBefore = serverReset }
      _ = try database.execute(
        """
        INSERT INTO repository_backoff(
          repository_id, failure_count, not_before, reason, updated_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(repository_id) DO UPDATE SET
          failure_count = excluded.failure_count,
          not_before = excluded.not_before,
          reason = excluded.reason,
          updated_at = excluded.updated_at
        """,
        bindings: [
          .text(repositoryID.uuidString.lowercased()),
          .integer(Int64(failureCount)),
          .real(notBefore.timeIntervalSince1970),
          .text(reason),
          .real(now.timeIntervalSince1970),
        ]
      )
      return RepositoryBackoffRecord(
        repositoryID: repositoryID,
        failureCount: failureCount,
        notBefore: notBefore,
        reason: reason
      )
    }
  }

  public func recordSuccess(repositoryID: UUID) async throws {
    try await database.execute(
      "DELETE FROM repository_backoff WHERE repository_id = ?",
      bindings: [.text(repositoryID.uuidString.lowercased())]
    )
  }

  public func backoff(repositoryID: UUID) async throws -> RepositoryBackoffRecord? {
    guard
      let row = try await database.query(
        "SELECT * FROM repository_backoff WHERE repository_id = ?",
        bindings: [.text(repositoryID.uuidString.lowercased())]
      ).first
    else { return nil }
    guard case .integer(let count)? = row["failure_count"],
      case .real(let seconds)? = row["not_before"],
      case .text(let reason)? = row["reason"]
    else { throw RepositoryBackoffError.decode }
    return RepositoryBackoffRecord(
      repositoryID: repositoryID,
      failureCount: Int(count),
      notBefore: Date(timeIntervalSince1970: seconds),
      reason: reason
    )
  }
}

public protocol SchedulerClock: Sendable {
  func now() async -> Date
  func sleep(until deadline: Date) async throws
}

public struct SystemSchedulerClock: SchedulerClock {
  private let clock: ContinuousClock
  private let monotonicOrigin: ContinuousClock.Instant
  private let wallOrigin: Date

  public init() {
    let clock = ContinuousClock()
    self.clock = clock
    monotonicOrigin = clock.now
    wallOrigin = Date()
  }

  public func now() -> Date {
    let elapsed = monotonicOrigin.duration(to: clock.now).components
    let seconds =
      TimeInterval(elapsed.seconds)
      + TimeInterval(elapsed.attoseconds) / 1_000_000_000_000_000_000
    return wallOrigin.addingTimeInterval(seconds)
  }

  public func sleep(until deadline: Date) async throws {
    let interval = deadline.timeIntervalSince(now())
    guard interval > 0 else { return }
    try await Task.sleep(
      nanoseconds: UInt64(min(interval, 3_600) * 1_000_000_000)
    )
  }
}

public protocol SchedulerPassRunner: Sendable {
  func run(pass: SchedulerPass) async
  func runReadbackOnly(pass: SchedulerPass) async
}

extension SchedulerPassRunner {
  public func runReadbackOnly(pass _: SchedulerPass) async {}
}

public actor DurableScheduler {
  private let clock: any SchedulerClock
  private let runner: any SchedulerPassRunner
  private let rolloutAuthority: RolloutAuthorityStore?
  private var timing: SchedulerTimingState
  private var runGeneration: UInt64 = 0
  private var sleepGeneration: UInt64 = 0
  private var sleepTask: Task<Void, Never>?

  public init(
    clock: any SchedulerClock,
    runner: any SchedulerPassRunner,
    initialNow: Date,
    rolloutAuthority: RolloutAuthorityStore? = nil
  ) {
    self.clock = clock
    self.runner = runner
    self.rolloutAuthority = rolloutAuthority
    timing = SchedulerTimingState(now: initialNow)
  }

  public func request(_ reason: SchedulerTriggerReason) async {
    let instant = await clock.now()
    if let rolloutAuthority {
      let admission = (try? await rolloutAuthority.schedulerAdmission(now: instant)) ?? .denied
      switch admission {
      case .active(let mode):
        if reason == .manual, mode != .finiteWindow { return }
      case .readbackOnly:
        guard reason != .manual && reason != .resume else { return }
        await runner.runReadbackOnly(
          pass: SchedulerPass(reasons: [reason], startedAt: instant)
        )
        timing.setPaused(true, now: await clock.now())
        interruptSleep()
        return
      case .denied:
        timing.setPaused(true, now: instant)
        interruptSleep()
        return
      }
    }
    timing.request(reason, now: instant)
    interruptSleep()
  }

  public func setPaused(_ paused: Bool) async {
    let instant = await clock.now()
    if !paused, let rolloutAuthority,
      (try? await rolloutAuthority.activeStatus(now: instant)) == nil
    {
      return
    }
    timing.setPaused(paused, now: instant)
    interruptSleep()
  }

  @discardableResult
  public func runDuePass() async -> Bool {
    let now = await clock.now()
    let admission: RolloutSchedulerAdmission
    if let rolloutAuthority {
      admission = (try? await rolloutAuthority.schedulerAdmission(now: now)) ?? .denied
    } else {
      admission = .active(.finiteWindow)
    }
    if admission == .denied {
      timing.setPaused(true, now: now)
      interruptSleep()
      return false
    }
    guard let pass = timing.takeDuePass(now: now) else { return false }
    switch admission {
    case .active:
      await runner.run(pass: pass)
    case .readbackOnly:
      await runner.runReadbackOnly(pass: pass)
    case .denied:
      return false
    }
    let finishedAt = await clock.now()
    timing.finishPass(now: finishedAt)
    if admission == .readbackOnly {
      timing.setPaused(true, now: finishedAt)
    }
    return true
  }

  public func snapshot() -> SchedulerTimingSnapshot {
    timing.snapshot
  }

  public func run() async {
    runGeneration &+= 1
    interruptSleep()
    let generation = runGeneration
    while generation == runGeneration {
      if await runDuePass() { continue }
      let now = await clock.now()
      let deadline =
        timing.nextWakeDate()
        ?? now.addingTimeInterval(SchedulerTimingState.periodicInterval)
      let sleeping = Task<Void, Never> { [clock] in
        do {
          try await clock.sleep(until: deadline)
        } catch {
          // Cancellation is the wake-up signal; the loop recalculates its deadline.
        }
      }
      let sleepGeneration = self.sleepGeneration
      sleepTask = sleeping
      await withTaskCancellationHandler {
        await sleeping.value
      } onCancel: {
        sleeping.cancel()
      }
      if sleepGeneration == self.sleepGeneration {
        sleepTask = nil
      }
      if Task.isCancelled { return }
    }
  }

  public func stop() {
    runGeneration &+= 1
    interruptSleep()
  }

  private func interruptSleep() {
    sleepGeneration &+= 1
    sleepTask?.cancel()
    sleepTask = nil
  }
}

public actor StartupCoordinator {
  private let jobs: DurableJobStore
  private let scheduler: DurableScheduler

  public init(jobs: DurableJobStore, scheduler: DurableScheduler) {
    self.jobs = jobs
    self.scheduler = scheduler
  }

  @discardableResult
  public func start(now: Date) async throws -> [StartupRecoveryRecord] {
    let recovered = try await jobs.recoverAtStartup(now: now)
    await scheduler.request(.startup)
    return recovered
  }
}
