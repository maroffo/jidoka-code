import Darwin
import Foundation

/// Immutable process authority. Dynamic process-group and session values are never part of
/// identity because a supervised process can change either without becoming a different process.
struct SupervisedProcessIdentity: Hashable, Sendable {
  let processID: pid_t
  let startSeconds: UInt64
  let startMicroseconds: UInt64
}

struct SupervisedProcessEvidence: Equatable, Sendable {
  let identity: SupervisedProcessIdentity
  let parentProcessID: pid_t
  let processGroupID: pid_t
  let sessionID: pid_t
}

struct SupervisedProcessSignalTargets: Equatable, Sendable {
  let processGroups: [pid_t]
  let identities: [SupervisedProcessIdentity]
}

/// Records every descendant identity observed while an owned leader or recorded descendant is
/// alive. Groups are refreshed only as signaling evidence; liveness is always PID + start time.
final class SupervisedProcessTracker: @unchecked Sendable {
  private static let maximumChildrenPerProcess = 4_096

  private let lock = NSLock()
  private let rootIdentity: SupervisedProcessIdentity
  private var evidenceByIdentity: [SupervisedProcessIdentity: SupervisedProcessEvidence]
  private var observationComplete = true

  init?(rootProcessID: pid_t) {
    guard let root = Self.currentEvidence(rootProcessID) else { return nil }
    rootIdentity = root.identity
    evidenceByIdentity = [root.identity: root]
  }

  var root: SupervisedProcessIdentity { rootIdentity }

  @discardableResult
  func observeDescendants() -> Bool {
    lock.lock()
    let known = Array(evidenceByIdentity.keys)
    lock.unlock()

    var refreshed: [SupervisedProcessIdentity: SupervisedProcessEvidence] = [:]
    var pending: [pid_t] = []
    var visited: Set<pid_t> = []
    var complete = true

    for identity in known {
      guard let current = Self.currentEvidence(identity.processID),
        current.identity == identity
      else { continue }
      refreshed[identity] = current
      pending.append(identity.processID)
    }

    while let parent = pending.popLast() {
      guard visited.insert(parent).inserted else { continue }
      var children = [pid_t](repeating: 0, count: Self.maximumChildrenPerProcess)
      let count = proc_listchildpids(
        parent,
        &children,
        Int32(children.count * MemoryLayout<pid_t>.size)
      )
      if count < 0 {
        if errno != ESRCH { complete = false }
        continue
      }
      if Int(count) >= children.count { complete = false }
      for child in children.prefix(min(max(Int(count), 0), children.count)) where child > 0 {
        guard let current = Self.currentEvidence(child) else { continue }
        refreshed[current.identity] = current
        pending.append(child)
      }
    }

    lock.lock()
    for (identity, evidence) in refreshed { evidenceByIdentity[identity] = evidence }
    observationComplete = observationComplete && complete
    lock.unlock()
    return complete
  }

  func matchingEvidence() -> [SupervisedProcessEvidence] {
    _ = observeDescendants()
    lock.lock()
    let identities = Array(evidenceByIdentity.keys)
    lock.unlock()
    return identities.compactMap { identity in
      guard let current = Self.currentEvidence(identity.processID),
        current.identity == identity
      else { return nil }
      lock.lock()
      evidenceByIdentity[identity] = current
      lock.unlock()
      return current
    }
  }

  func signalOwnedProcesses(_ signal: Int32, originalProcessGroup: pid_t) {
    _ = observeDescendants()
    lock.lock()
    let recorded = Array(evidenceByIdentity.keys)
    lock.unlock()
    let callerGroup = getpgrp()
    let targets = Self.signalTargets(
      recordedIdentities: recorded,
      originalProcessGroup: originalProcessGroup,
      callerProcessGroup: callerGroup,
      evidenceProvider: Self.currentEvidence
    )
    for group in targets.processGroups {
      guard group != callerGroup,
        targets.identities.contains(where: { identity in
          guard let current = Self.currentEvidence(identity.processID) else { return false }
          return current.identity == identity && current.processGroupID == group
        })
      else { continue }
      _ = Darwin.kill(-group, signal)
    }
    for identity in targets.identities {
      guard let refreshed = Self.currentEvidence(identity.processID),
        refreshed.identity == identity
      else { continue }
      _ = Darwin.kill(identity.processID, signal)
    }
  }

  func waitForDisappearance(until deadline: TimeInterval) -> Bool {
    while Self.monotonicSeconds() < deadline {
      if matchingEvidence().isEmpty { return isObservationComplete }
      usleep(5_000)
    }
    return matchingEvidence().isEmpty && isObservationComplete
  }

  func waitForCleanup(
    originalProcessGroup: pid_t,
    until deadline: TimeInterval
  ) -> Bool {
    while Self.monotonicSeconds() < deadline {
      if cleanupVerified(originalProcessGroup: originalProcessGroup) { return true }
      usleep(5_000)
    }
    return cleanupVerified(originalProcessGroup: originalProcessGroup)
  }

  var cleanupVerified: Bool {
    matchingEvidence().isEmpty && isObservationComplete
  }

  func cleanupVerified(originalProcessGroup: pid_t) -> Bool {
    cleanupVerified && !Self.processGroupExists(originalProcessGroup)
  }

  var recordedIdentities: [SupervisedProcessIdentity] {
    lock.lock()
    defer { lock.unlock() }
    return evidenceByIdentity.keys.sorted {
      ($0.processID, $0.startSeconds, $0.startMicroseconds)
        < ($1.processID, $1.startSeconds, $1.startMicroseconds)
    }
  }

  private var isObservationComplete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return observationComplete
  }

  static func identity(_ processID: pid_t) -> SupervisedProcessIdentity? {
    currentEvidence(processID)?.identity
  }

  static func matches(_ identity: SupervisedProcessIdentity) -> Bool {
    currentEvidence(identity.processID)?.identity == identity
  }

  static func processGroupExists(_ processGroup: pid_t) -> Bool {
    guard processGroup > 0 else { return false }
    if Darwin.kill(-processGroup, 0) == 0 { return true }
    return errno == EPERM
  }

  #if DEBUG
    static func signalTargetsForTesting(
      recordedIdentities: [SupervisedProcessIdentity],
      currentEvidence: [pid_t: SupervisedProcessEvidence],
      originalProcessGroup: pid_t,
      callerProcessGroup: pid_t
    ) -> SupervisedProcessSignalTargets {
      signalTargets(
        recordedIdentities: recordedIdentities,
        originalProcessGroup: originalProcessGroup,
        callerProcessGroup: callerProcessGroup,
        evidenceProvider: { currentEvidence[$0] }
      )
    }
  #endif

  private static func signalTargets(
    recordedIdentities: [SupervisedProcessIdentity],
    originalProcessGroup: pid_t,
    callerProcessGroup: pid_t,
    evidenceProvider: (pid_t) -> SupervisedProcessEvidence?
  ) -> SupervisedProcessSignalTargets {
    let matching = recordedIdentities.compactMap { identity -> SupervisedProcessEvidence? in
      guard let current = evidenceProvider(identity.processID), current.identity == identity else {
        return nil
      }
      return current
    }
    var groups = Set(
      matching.map(\.processGroupID).filter { $0 > 0 && $0 != callerProcessGroup }
    )
    if !matching.contains(where: { $0.processGroupID == originalProcessGroup }) {
      groups.remove(originalProcessGroup)
    }
    return SupervisedProcessSignalTargets(
      processGroups: groups.sorted(),
      identities: matching.map(\.identity).sorted {
        ($0.processID, $0.startSeconds, $0.startMicroseconds)
          < ($1.processID, $1.startSeconds, $1.startMicroseconds)
      }
    )
  }

  private static func currentEvidence(_ processID: pid_t) -> SupervisedProcessEvidence? {
    var information = proc_bsdinfo()
    let size = proc_pidinfo(
      processID,
      PROC_PIDTBSDINFO,
      0,
      &information,
      Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard size == MemoryLayout<proc_bsdinfo>.size,
      information.pbi_pid == UInt32(processID),
      information.pbi_status != UInt32(SZOMB)
    else { return nil }
    let group = getpgid(processID)
    let session = getsid(processID)
    guard group > 0, session > 0 else { return nil }
    return SupervisedProcessEvidence(
      identity: SupervisedProcessIdentity(
        processID: processID,
        startSeconds: information.pbi_start_tvsec,
        startMicroseconds: information.pbi_start_tvusec
      ),
      parentProcessID: pid_t(information.pbi_ppid),
      processGroupID: group,
      sessionID: session
    )
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }
}
