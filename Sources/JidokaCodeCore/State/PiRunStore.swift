import CryptoKit
import Foundation

public enum HerdrBindingState: String, Codable, Sendable {
  case prepared
  case active
  case closed
  case lost
}

public enum HerdrRoleHostState: String, Codable, Sendable {
  case prepared
  case waiting
  case running
  case stopping
  case stopped
  case lost
}

public enum PiRunOutcome: String, Codable, Sendable {
  case prepared
  case running
  case settled
  case released
  case interruptedUnknown
  case failed
}

public enum PiRunLaunchMode: String, Codable, Sendable {
  case fresh
  case sameRunResume
  case crossRunResume
}

public enum PiRunLaunchState: String, Codable, Sendable {
  case prepared
  case enqueued
  case running
  case resultPrepared
  case settled
  case released
  case interruptedUnknown
  case failed
}

public enum PiRunEventKind: String, Codable, Sendable {
  case prepared
  case enqueued
  case running
  case childProcessRecorded
  case rebound
  case resultPrepared
  case settled
  case acknowledged
  case released
  case interruptedUnknown
  case failed
}

public struct HerdrRepositoryBindingRecord: Equatable, Sendable {
  public let repositoryID: UUID
  public let workspaceID: String
  public let identityRoot: String
  public let herdrVersion: String
  public let herdrProtocol: Int
  public let socketIdentity: HerdrSocketIdentity
  public let state: HerdrBindingState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct HerdrJobBindingRecord: Equatable, Sendable {
  public let jobID: UUID
  public let repositoryID: UUID
  public let generation: Int
  public let workspaceID: String
  public let tabID: String?
  public let state: HerdrBindingState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct HerdrHostProcessIdentity: Codable, Equatable, Sendable {
  public let processID: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64

  public init(processID: Int32, startSeconds: UInt64, startMicroseconds: UInt64) throws {
    guard processID > 0, startMicroseconds < 1_000_000 else {
      throw PiRunStoreError.invalidRecord
    }
    self.processID = processID
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
  }
}

public struct HerdrRoleHostRecord: Equatable, Sendable {
  public let id: String
  public let jobID: UUID
  public let generation: Int
  public let role: PiWorkflowRole
  public let workspaceID: String
  public let tabID: String?
  public let paneID: String?
  public let terminalID: String?
  public let bootstrapDescriptorSHA256: String
  public let hostExecutableSHA256: String
  public let processIdentity: HerdrHostProcessIdentity?
  public let lastQueueSequence: Int
  public let lifecycleSequence: Int
  public let state: HerdrRoleHostState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct HerdrReplacementRoleHostRecord: Equatable, Sendable {
  public let id: String
  public let predecessorRoleHostID: String
  public let replacementIntentID: String
  public let jobID: UUID
  public let generation: Int
  public let role: PiWorkflowRole
  public let workspaceID: String
  public let tabID: String
  public let paneID: String
  public let terminalID: String
  public let bootstrapDescriptorSHA256: String
  public let hostExecutableSHA256: String
  public let q4Binding: JobCanaryRoleHostReplacementQ4Binding
  public let processIdentity: HerdrHostProcessIdentity
  public let lastQueueSequence: Int
  public let lifecycleSequence: Int
  public let state: HerdrRoleHostState
  public let createdAt: Date
  public let updatedAt: Date
}

public struct HerdrRoleHostActivation: Equatable, Sendable {
  public let roleHostID: String
  public let workspaceID: String
  public let tabID: String
  public let paneID: String
  public let terminalID: String
  public let processIdentity: HerdrHostProcessIdentity

  public init(
    roleHostID: String,
    workspaceID: String,
    tabID: String,
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity
  ) {
    self.roleHostID = roleHostID
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.paneID = paneID
    self.terminalID = terminalID
    self.processIdentity = processIdentity
  }
}

public struct PiRunRecord: Equatable, Sendable {
  public let id: String
  public let jobID: UUID
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let round: Int
  public let jobAttempt: Int
  public let topologyGeneration: Int
  public let jobStep: Int
  public let resumesRunID: String?
  public let runNonce: String
  public let requestSHA256: String
  public let resourceVersion: String
  public let resourceHash: String
  public let model: String
  public let sessionPath: String
  public let sessionID: String?
  public let sessionBoundarySHA256: String?
  public let channelPath: String
  public let accepted: Bool
  public let settled: Bool
  public let structuredResultDigest: String?
  public let outcome: PiRunOutcome
  public let createdAt: Date
  public let updatedAt: Date
}

public struct PiRunLaunchRecord: Equatable, Sendable {
  public let launchAttemptID: String
  public let runID: String
  public let roleHostID: String
  public let executionRoleHostID: String?
  public let queueSequence: Int
  public let launchMode: PiRunLaunchMode
  public let descriptorSHA256: String
  public let expectedSessionID: String?
  public let resumeBoundarySHA256: String?
  public let state: PiRunLaunchState
  public let failureCode: String?
  public let childProcess: HerdrChildProcessRecord?
  public let createdAt: Date
  public let updatedAt: Date
}

public struct PiRunSessionOriginRecord: Equatable, Sendable {
  public let runID: String
  public let launchAttemptID: String
  public let sessionID: String
  public let originResumeBoundarySHA256: String?
  public let createdAt: Date
}

public struct PiRunResultRecord: Equatable, Sendable {
  public let runID: String
  public let launchAttemptID: String
  public let envelope: Data
  public let resultSHA256: String
  public let sessionID: String
  public let sessionBoundarySHA256: String
  public let settlementSHA256: String
  public let createdAt: Date
}

struct HerdrPrimedLaunchAuthority: Sendable {
  let receipt: HerdrTopologyMutationReceipt
  let payload: HerdrAgentAuthorityPrimePayload
  let attribution: HerdrAgentAuthorityPrimeAttribution
}

struct HerdrStoredReplacementAttribution: Sendable {
  let receipt: HerdrTopologyMutationReceipt
  let payloadSHA256: String
  let attribution: HerdrRoleHostReplacementAttribution
}

struct HerdrReplacementLaunchAuthority: Sendable {
  let receipt: HerdrTopologyMutationReceipt
  let payload: HerdrRoleHostReplacementPayload
  let attribution: HerdrRoleHostReplacementAttribution
}

public struct PiRunEventRecord: Equatable, Sendable {
  public let runID: String
  public let launchAttemptID: String?
  public let sequence: Int
  public let kind: PiRunEventKind
  public let recordSHA256: String?
  public let detailCode: String?
  public let createdAt: Date
}

public enum PiRunStoreError: Error, Equatable, Sendable {
  case invalidRecord
  case bindingCollision
  case roleHostNotFound(String)
  case runNotFound(String)
  case launchNotFound(String)
  case invalidTransition
  case launchSuppressed
  case divergentResult
  case decode(String)
}

public actor PiRunStore {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  @discardableResult
  public func bindRepository(
    repositoryID: UUID,
    workspaceID: String,
    identityRoot: URL,
    handshake: HerdrHandshake,
    now: Date
  ) async throws -> HerdrRepositoryBindingRecord {
    guard Self.validID(workspaceID), Self.validAbsolutePath(identityRoot),
      !handshake.pong.version.isEmpty, handshake.pong.protocolVersion > 0,
      handshake.socketIdentity.device <= UInt64(Int64.max),
      handshake.socketIdentity.inode <= UInt64(Int64.max)
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      if let existing = try Self.loadRepositoryBinding(repositoryID, database: database) {
        if existing.state == .active {
          guard existing.workspaceID == workspaceID,
            existing.identityRoot == identityRoot.path,
            existing.herdrVersion == handshake.pong.version,
            existing.herdrProtocol == handshake.pong.protocolVersion,
            existing.socketIdentity == handshake.socketIdentity
          else {
            throw PiRunStoreError.bindingCollision
          }
          return existing
        }
        guard existing.state == .lost else { throw PiRunStoreError.invalidTransition }
        _ = try database.execute(
          """
          UPDATE herdr_repository_bindings
          SET workspace_id = ?, identity_root = ?, herdr_version = ?, herdr_protocol = ?,
            socket_device = ?, socket_inode = ?, socket_owner = ?, socket_permissions = ?,
            state = 'active', updated_at = ?
          WHERE repository_id = ? AND state = 'lost'
          """,
          bindings: [
            .text(workspaceID),
            .text(identityRoot.path),
            .text(handshake.pong.version),
            .integer(Int64(handshake.pong.protocolVersion)),
            .integer(Int64(handshake.socketIdentity.device)),
            .integer(Int64(handshake.socketIdentity.inode)),
            .integer(Int64(handshake.socketIdentity.owner)),
            .integer(Int64(handshake.socketIdentity.permissions)),
            .real(now.timeIntervalSince1970),
            .text(Self.uuid(repositoryID)),
          ]
        )
        return try Self.requireRepositoryBinding(repositoryID, database: database)
      }
      _ = try database.execute(
        """
        INSERT INTO herdr_repository_bindings(
          repository_id, workspace_id, identity_root, herdr_version, herdr_protocol,
          socket_device, socket_inode, socket_owner, socket_permissions,
          state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
        """,
        bindings: [
          .text(Self.uuid(repositoryID)),
          .text(workspaceID),
          .text(identityRoot.path),
          .text(handshake.pong.version),
          .integer(Int64(handshake.pong.protocolVersion)),
          .integer(Int64(handshake.socketIdentity.device)),
          .integer(Int64(handshake.socketIdentity.inode)),
          .integer(Int64(handshake.socketIdentity.owner)),
          .integer(Int64(handshake.socketIdentity.permissions)),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireRepositoryBinding(repositoryID, database: database)
    }
  }

  public func repositoryBindings() async throws -> [HerdrRepositoryBindingRecord] {
    try await database.query(
      "SELECT * FROM herdr_repository_bindings ORDER BY repository_id"
    ).map(Self.decodeRepositoryBinding)
  }

  public func repositoryBinding(
    repositoryID: UUID
  ) async throws -> HerdrRepositoryBindingRecord? {
    try await database.query(
      "SELECT * FROM herdr_repository_bindings WHERE repository_id = ?",
      bindings: [.text(Self.uuid(repositoryID))]
    ).first.map(Self.decodeRepositoryBinding)
  }

  public func invalidateRepositoryBinding(
    repositoryID: UUID,
    observedHandshake: HerdrHandshake,
    now: Date
  ) async throws {
    try await database.transaction { database in
      let current = try Self.requireRepositoryBinding(repositoryID, database: database)
      if current.state == .lost { return }
      guard current.state == .active,
        current.socketIdentity != observedHandshake.socketIdentity,
        observedHandshake.pong.version == "0.8.0",
        observedHandshake.pong.protocolVersion == 19
      else {
        throw PiRunStoreError.bindingCollision
      }
      _ = try database.execute(
        """
        INSERT INTO herdr_repository_binding_history(
          repository_id, workspace_id, identity_root, herdr_version, herdr_protocol,
          socket_device, socket_inode, socket_owner, socket_permissions,
          reason, invalidated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'SOCKET_CHANGED', ?)
        """,
        bindings: [
          .text(Self.uuid(repositoryID)),
          .text(current.workspaceID),
          .text(current.identityRoot),
          .text(current.herdrVersion),
          .integer(Int64(current.herdrProtocol)),
          .integer(try Self.int64(current.socketIdentity.device)),
          .integer(try Self.int64(current.socketIdentity.inode)),
          .integer(Int64(current.socketIdentity.owner)),
          .integer(Int64(current.socketIdentity.permissions)),
          .real(now.timeIntervalSince1970),
        ]
      )
      let hosts = try database.query(
        """
        SELECT h.* FROM herdr_role_hosts h
        JOIN herdr_job_bindings j ON j.job_id = h.job_id
        WHERE j.repository_id = ? AND h.state NOT IN ('lost', 'stopped')
        ORDER BY h.id
        """,
        bindings: [.text(Self.uuid(repositoryID))]
      ).map(Self.decodeRoleHost)
      for host in hosts {
        _ = try database.execute(
          """
          UPDATE herdr_role_hosts
          SET state = 'lost', lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
          WHERE id = ?
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(host.id)]
        )
        let launches = try database.query(
          """
          SELECT * FROM pi_run_launches
          WHERE role_host_id = ?
            AND state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
          ORDER BY queue_sequence, launch_attempt_id
          """,
          bindings: [.text(host.id)]
        ).map(Self.decodeLaunch)
        for launch in launches {
          _ = try database.execute(
            """
            UPDATE pi_run_launches
            SET state = 'interruptedUnknown', failure_code = 'HERDR_SOCKET_CHANGED',
              updated_at = ?
            WHERE launch_attempt_id = ?
            """,
            bindings: [
              .real(now.timeIntervalSince1970),
              .text(launch.launchAttemptID),
            ]
          )
          _ = try database.execute(
            """
            UPDATE pi_runs SET outcome = 'interruptedUnknown', updated_at = ?
            WHERE id = ? AND settled = 0
            """,
            bindings: [.real(now.timeIntervalSince1970), .text(launch.runID)]
          )
          try Self.appendEvent(
            runID: launch.runID,
            launchAttemptID: launch.launchAttemptID,
            kind: .interruptedUnknown,
            recordSHA256: nil,
            detailCode: "HERDR_SOCKET_CHANGED",
            now: now,
            database: database
          )
        }
      }
      let replacementHosts = try database.query(
        """
        SELECT replacement.*
        FROM herdr_replacement_role_hosts AS replacement
        JOIN herdr_job_bindings AS job ON job.job_id = replacement.job_id
        WHERE job.repository_id = ? AND replacement.state NOT IN ('lost', 'stopped')
        ORDER BY replacement.id
        """,
        bindings: [.text(Self.uuid(repositoryID))]
      ).map(Self.decodeReplacementRoleHost)
      for host in replacementHosts {
        _ = try database.execute(
          """
          UPDATE herdr_replacement_role_hosts
          SET state = 'lost', lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
          WHERE id = ?
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(host.id)]
        )
        let launches = try database.query(
          """
          SELECT * FROM pi_run_launches
          WHERE execution_role_host_id = ?
            AND state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
          ORDER BY queue_sequence, launch_attempt_id
          """,
          bindings: [.text(host.id)]
        ).map(Self.decodeLaunch)
        for launch in launches {
          _ = try database.execute(
            """
            UPDATE pi_run_launches
            SET state = 'interruptedUnknown', failure_code = 'HERDR_SOCKET_CHANGED',
              updated_at = ?
            WHERE launch_attempt_id = ?
            """,
            bindings: [.real(now.timeIntervalSince1970), .text(launch.launchAttemptID)]
          )
          _ = try database.execute(
            "UPDATE pi_runs SET outcome = 'interruptedUnknown', updated_at = ? WHERE id = ? AND settled = 0",
            bindings: [.real(now.timeIntervalSince1970), .text(launch.runID)]
          )
          try Self.appendEvent(
            runID: launch.runID,
            launchAttemptID: launch.launchAttemptID,
            kind: .interruptedUnknown,
            recordSHA256: nil,
            detailCode: "HERDR_SOCKET_CHANGED",
            now: now,
            database: database
          )
        }
      }
      _ = try database.execute(
        """
        UPDATE herdr_job_bindings SET state = 'lost', updated_at = ?
        WHERE repository_id = ? AND state IN ('prepared', 'active')
        """,
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(repositoryID)),
        ]
      )
      _ = try database.execute(
        """
        UPDATE herdr_repository_bindings SET state = 'lost', updated_at = ?
        WHERE repository_id = ? AND state = 'active'
        """,
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(repositoryID)),
        ]
      )
    }
  }

  @discardableResult
  public func prepareJobBinding(
    jobID: UUID,
    repositoryID: UUID,
    generation: Int,
    workspaceID: String,
    now: Date
  ) async throws -> HerdrJobBindingRecord {
    guard generation > 0, Self.validID(workspaceID) else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let repository = try Self.requireRepositoryBinding(repositoryID, database: database)
      guard repository.state == .active,
        repository.workspaceID == workspaceID
      else { throw PiRunStoreError.invalidTransition }
      if let existing = try Self.loadJobBinding(jobID, database: database) {
        if existing.repositoryID == repositoryID,
          existing.generation == generation,
          existing.workspaceID == workspaceID
        {
          return existing
        }
        guard existing.repositoryID == repositoryID,
          [.lost, .closed].contains(existing.state),
          generation == existing.generation + 1,
          try database.scalarInt(
            """
            SELECT COUNT(*) FROM herdr_role_hosts
            WHERE job_id = ? AND generation = ? AND state NOT IN ('lost', 'stopped')
            """,
            bindings: [
              .text(Self.uuid(jobID)),
              .integer(Int64(existing.generation)),
            ]
          ) == 0
        else {
          throw PiRunStoreError.bindingCollision
        }
        _ = try database.execute(
          """
          UPDATE herdr_job_bindings
          SET generation = ?, workspace_id = ?, tab_id = NULL, state = 'prepared', updated_at = ?
          WHERE job_id = ? AND generation = ? AND state IN ('lost', 'closed')
          """,
          bindings: [
            .integer(Int64(generation)),
            .text(workspaceID),
            .real(now.timeIntervalSince1970),
            .text(Self.uuid(jobID)),
            .integer(Int64(existing.generation)),
          ]
        )
        return try Self.requireJobBinding(jobID, database: database)
      }
      _ = try database.execute(
        """
        INSERT INTO herdr_job_bindings(
          job_id, repository_id, generation, workspace_id, tab_id, state,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, NULL, 'prepared', ?, ?)
        """,
        bindings: [
          .text(Self.uuid(jobID)),
          .text(Self.uuid(repositoryID)),
          .integer(Int64(generation)),
          .text(workspaceID),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireJobBinding(jobID, database: database)
    }
  }

  @discardableResult
  private func activateJobBinding(
    jobID: UUID,
    tabID: String,
    now: Date
  ) async throws -> HerdrJobBindingRecord {
    guard Self.validID(tabID) else { throw PiRunStoreError.invalidRecord }
    return try await database.transaction { database in
      let current = try Self.requireJobBinding(jobID, database: database)
      if current.state == .active {
        guard current.tabID == tabID else { throw PiRunStoreError.bindingCollision }
        return current
      }
      guard current.state == .prepared, current.tabID == nil else {
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        UPDATE herdr_job_bindings
        SET tab_id = ?, state = 'active', updated_at = ?
        WHERE job_id = ? AND state = 'prepared' AND tab_id IS NULL
        """,
        bindings: [
          .text(tabID),
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(jobID)),
        ]
      )
      return try Self.requireJobBinding(jobID, database: database)
    }
  }

  public func jobBindings() async throws -> [HerdrJobBindingRecord] {
    try await database.query(
      "SELECT * FROM herdr_job_bindings ORDER BY job_id"
    ).map(Self.decodeJobBinding)
  }

  public func closeJobBinding(jobID: UUID, now: Date) async throws {
    try await database.transaction { database in
      let current = try Self.requireJobBinding(jobID, database: database)
      if current.state == .closed || current.state == .lost { return }
      guard [.prepared, .active].contains(current.state) else {
        throw PiRunStoreError.invalidTransition
      }
      let openHosts = try database.query(
        """
        SELECT COUNT(*) AS count FROM herdr_role_hosts
        WHERE job_id = ? AND state NOT IN ('stopped', 'lost')
        """,
        bindings: [.text(Self.uuid(jobID))]
      )
      let openReplacementHosts = try database.scalarInt(
        "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE job_id = ? AND state NOT IN ('stopped', 'lost')",
        bindings: [.text(Self.uuid(jobID))]
      )
      guard try Self.integer(openHosts[0], "count") == 0,
        openReplacementHosts == 0
      else {
        throw PiRunStoreError.invalidTransition
      }
      let targetState = current.state == .active ? "closed" : "lost"
      _ = try database.execute(
        "UPDATE herdr_job_bindings SET state = ?, updated_at = ? WHERE job_id = ?",
        bindings: [
          .text(targetState),
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(jobID)),
        ]
      )
    }
  }

  public func markJobBindingLost(
    jobID: UUID,
    generation: Int,
    now: Date
  ) async throws {
    try await database.transaction { database in
      let current = try Self.requireJobBinding(jobID, database: database)
      if current.state == .lost { return }
      guard current.generation == generation,
        [.prepared, .active].contains(current.state),
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM herdr_role_hosts
          WHERE job_id = ? AND generation = ? AND state NOT IN ('lost', 'stopped')
          """,
          bindings: [
            .text(Self.uuid(jobID)),
            .integer(Int64(generation)),
          ]
        ) == 0,
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM herdr_replacement_role_hosts
          WHERE job_id = ? AND generation = ? AND state NOT IN ('lost', 'stopped')
          """,
          bindings: [
            .text(Self.uuid(jobID)),
            .integer(Int64(generation)),
          ]
        ) == 0
      else {
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        UPDATE herdr_job_bindings SET state = 'lost', updated_at = ?
        WHERE job_id = ? AND generation = ?
        """,
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(jobID)),
          .integer(Int64(generation)),
        ]
      )
    }
  }

  public func jobBinding(jobID: UUID) async throws -> HerdrJobBindingRecord? {
    try await database.query(
      "SELECT * FROM herdr_job_bindings WHERE job_id = ?",
      bindings: [.text(Self.uuid(jobID))]
    ).first.map(Self.decodeJobBinding)
  }

  @discardableResult
  public func prepareRoleHost(
    id: String,
    jobID: UUID,
    generation: Int,
    role: PiWorkflowRole,
    workspaceID: String,
    bootstrapDescriptorSHA256: String,
    hostExecutableSHA256: String,
    now: Date
  ) async throws -> HerdrRoleHostRecord {
    guard Self.validRuntimeID(id), generation > 0, Self.validID(workspaceID),
      Self.isSHA256(bootstrapDescriptorSHA256), Self.isSHA256(hostExecutableSHA256)
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let job = try Self.requireJobBinding(jobID, database: database)
      guard job.generation == generation, job.workspaceID == workspaceID else {
        throw PiRunStoreError.bindingCollision
      }
      guard try !Self.replacementRoleHostIDCollision(id: id, database: database) else {
        throw PiRunStoreError.bindingCollision
      }
      if let existing = try Self.loadRoleHost(id, database: database) {
        guard existing.jobID == jobID, existing.generation == generation,
          existing.role == role, existing.workspaceID == workspaceID,
          existing.bootstrapDescriptorSHA256 == bootstrapDescriptorSHA256,
          existing.hostExecutableSHA256 == hostExecutableSHA256
        else {
          throw PiRunStoreError.bindingCollision
        }
        return existing
      }
      _ = try database.execute(
        """
        INSERT INTO herdr_role_hosts(
          id, job_id, generation, role, workspace_id, tab_id, pane_id, terminal_id,
          bootstrap_descriptor_sha256, host_executable_sha256,
          host_pid, host_start_seconds, host_start_microseconds,
          last_queue_sequence, lifecycle_sequence, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, NULL, NULL, NULL, 0, 0,
          'prepared', ?, ?)
        """,
        bindings: [
          .text(id),
          .text(Self.uuid(jobID)),
          .integer(Int64(generation)),
          .text(role.rawValue),
          .text(workspaceID),
          .text(bootstrapDescriptorSHA256),
          .text(hostExecutableSHA256),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireRoleHost(id, database: database)
    }
  }

  public func activateTopology(
    jobID: UUID,
    tabID: String,
    hosts activations: [HerdrRoleHostActivation],
    now: Date
  ) async throws {
    guard Self.validID(tabID), !activations.isEmpty,
      Set(activations.map(\.roleHostID)).count == activations.count,
      Set(activations.map(\.paneID)).count == activations.count,
      Set(activations.map(\.terminalID)).count == activations.count,
      activations.allSatisfy({
        Self.validID($0.workspaceID) && Self.validID($0.tabID) && Self.validID($0.paneID)
          && Self.validID($0.terminalID) && $0.tabID == tabID
      })
    else {
      throw PiRunStoreError.invalidRecord
    }
    try await database.transaction { database in
      let job = try Self.requireJobBinding(jobID, database: database)
      guard [.prepared, .active].contains(job.state) else {
        throw PiRunStoreError.invalidTransition
      }
      let currentHosts = try database.query(
        "SELECT * FROM herdr_role_hosts WHERE job_id = ? AND generation = ?",
        bindings: [
          .text(Self.uuid(jobID)),
          .integer(Int64(job.generation)),
        ]
      ).map(Self.decodeRoleHost)
      guard Set(currentHosts.map(\.id)) == Set(activations.map(\.roleHostID)) else {
        throw PiRunStoreError.bindingCollision
      }
      if job.state == .active {
        guard job.tabID == tabID,
          currentHosts.allSatisfy({ host in
            guard let activation = activations.first(where: { $0.roleHostID == host.id }) else {
              return false
            }
            return host.workspaceID == activation.workspaceID
              && host.tabID == activation.tabID
              && host.paneID == activation.paneID
              && host.terminalID == activation.terminalID
              && host.processIdentity == activation.processIdentity
              && [.waiting, .running].contains(host.state)
          })
        else {
          throw PiRunStoreError.bindingCollision
        }
        return
      }
      guard currentHosts.allSatisfy({ $0.state == .prepared }),
        activations.allSatisfy({ $0.workspaceID == job.workspaceID })
      else {
        throw PiRunStoreError.bindingCollision
      }
      for activation in activations {
        guard
          try !Self.replacementRoleHostPhysicalCollision(
            paneID: activation.paneID,
            terminalID: activation.terminalID,
            processIdentity: activation.processIdentity,
            database: database
          )
        else { throw PiRunStoreError.bindingCollision }
      }
      _ = try database.execute(
        "UPDATE herdr_job_bindings SET tab_id = ?, state = 'active', updated_at = ? WHERE job_id = ? AND state = 'prepared'",
        bindings: [
          .text(tabID),
          .real(now.timeIntervalSince1970),
          .text(Self.uuid(jobID)),
        ]
      )
      for activation in activations {
        _ = try database.execute(
          """
          UPDATE herdr_role_hosts
          SET workspace_id = ?, tab_id = ?, pane_id = ?, terminal_id = ?, host_pid = ?,
            host_start_seconds = ?, host_start_microseconds = ?, state = 'waiting',
            lifecycle_sequence = 1, updated_at = ?
          WHERE id = ? AND state = 'prepared'
          """,
          bindings: [
            .text(activation.workspaceID),
            .text(activation.tabID),
            .text(activation.paneID),
            .text(activation.terminalID),
            .integer(Int64(activation.processIdentity.processID)),
            .integer(try Self.int64(activation.processIdentity.startSeconds)),
            .integer(try Self.int64(activation.processIdentity.startMicroseconds)),
            .real(now.timeIntervalSince1970),
            .text(activation.roleHostID),
          ]
        )
      }
    }
  }

  @discardableResult
  func activateRoleHost(
    id: String,
    tabID: String,
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity,
    now: Date
  ) async throws -> HerdrRoleHostRecord {
    guard Self.validID(tabID), Self.validID(paneID), Self.validID(terminalID) else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let current = try Self.requireRoleHost(id, database: database)
      let job = try Self.requireJobBinding(current.jobID, database: database)
      guard job.state == .active, job.tabID == tabID,
        job.generation == current.generation
      else {
        throw PiRunStoreError.bindingCollision
      }
      if current.state != .prepared {
        guard current.tabID == tabID, current.paneID == paneID,
          current.terminalID == terminalID,
          current.processIdentity == processIdentity,
          [.waiting, .running].contains(current.state)
        else {
          throw PiRunStoreError.bindingCollision
        }
        return current
      }
      guard
        try !Self.replacementRoleHostPhysicalCollision(
          paneID: paneID,
          terminalID: terminalID,
          processIdentity: processIdentity,
          database: database
        )
      else { throw PiRunStoreError.bindingCollision }
      _ = try database.execute(
        """
        UPDATE herdr_role_hosts
        SET tab_id = ?, pane_id = ?, terminal_id = ?, host_pid = ?,
          host_start_seconds = ?, host_start_microseconds = ?, state = 'waiting',
          lifecycle_sequence = 1, updated_at = ?
        WHERE id = ? AND state = 'prepared'
        """,
        bindings: [
          .text(tabID),
          .text(paneID),
          .text(terminalID),
          .integer(Int64(processIdentity.processID)),
          .integer(try Self.int64(processIdentity.startSeconds)),
          .integer(try Self.int64(processIdentity.startMicroseconds)),
          .real(now.timeIntervalSince1970),
          .text(id),
        ]
      )
      return try Self.requireRoleHost(id, database: database)
    }
  }

  public func roleHosts() async throws -> [HerdrRoleHostRecord] {
    try await database.query(
      "SELECT * FROM herdr_role_hosts ORDER BY job_id, role, id"
    ).map(Self.decodeRoleHost)
  }

  public func roleHosts(jobID: UUID) async throws -> [HerdrRoleHostRecord] {
    try await database.query(
      "SELECT * FROM herdr_role_hosts WHERE job_id = ? ORDER BY role, id",
      bindings: [.text(Self.uuid(jobID))]
    ).map(Self.decodeRoleHost)
  }

  public func replacementRoleHosts() async throws -> [HerdrReplacementRoleHostRecord] {
    try await database.query(
      "SELECT * FROM herdr_replacement_role_hosts ORDER BY job_id, role, id"
    ).map(Self.decodeReplacementRoleHost)
  }

  public func replacementRoleHosts(
    jobID: UUID
  ) async throws -> [HerdrReplacementRoleHostRecord] {
    try await database.query(
      "SELECT * FROM herdr_replacement_role_hosts WHERE job_id = ? ORDER BY role, id",
      bindings: [.text(Self.uuid(jobID))]
    ).map(Self.decodeReplacementRoleHost)
  }

  public func replacementRoleHost(
    id: String
  ) async throws -> HerdrReplacementRoleHostRecord? {
    guard Self.validRuntimeID(id) else { throw PiRunStoreError.invalidRecord }
    return try await database.query(
      "SELECT * FROM herdr_replacement_role_hosts WHERE id = ?",
      bindings: [.text(id)]
    ).first.map(Self.decodeReplacementRoleHost)
  }

  func replacementAttribution(
    replacementRoleHostID: String
  ) async throws -> HerdrStoredReplacementAttribution? {
    guard Self.validRuntimeID(replacementRoleHostID) else {
      throw PiRunStoreError.invalidRecord
    }
    let rows = try await database.query(
      """
      SELECT intent.id, intent.intent_sha256, intent.payload_sha256,
        intent.state, intent.attribution_json
      FROM herdr_replacement_role_hosts AS host
      JOIN herdr_topology_intents AS intent ON intent.id = host.replacement_intent_id
      WHERE host.id = ? AND intent.kind = 'replaceRoleHost'
      """,
      bindings: [.text(replacementRoleHostID)]
    )
    guard rows.count <= 1, let row = rows.first else {
      if rows.isEmpty { return nil }
      throw PiRunStoreError.bindingCollision
    }
    guard try Self.text(row, "state") == "attributed",
      let json = try Self.optionalText(row, "attribution_json"),
      let data = json.data(using: .utf8),
      let attribution = try? JSONDecoder().decode(
        HerdrRoleHostReplacementAttribution.self,
        from: data
      )
    else { throw PiRunStoreError.decode("replacement attribution") }
    return HerdrStoredReplacementAttribution(
      receipt: HerdrTopologyMutationReceipt(
        mutationID: try Self.text(row, "id"),
        intentSHA256: try Self.text(row, "intent_sha256")
      ),
      payloadSHA256: try Self.text(row, "payload_sha256"),
      attribution: attribution
    )
  }

  @discardableResult
  public func transitionReplacementRoleHost(
    id: String,
    to state: HerdrRoleHostState,
    now: Date
  ) async throws -> HerdrReplacementRoleHostRecord {
    try await database.transaction { database in
      let current = try Self.requireReplacementRoleHost(id, database: database)
      if current.state == state { return current }
      let valid =
        current.state == .waiting && [.running, .stopping, .lost].contains(state)
        || current.state == .running && [.waiting, .stopping, .lost].contains(state)
        || current.state == .stopping && [.stopped, .lost].contains(state)
      guard valid, now >= current.updatedAt else { throw PiRunStoreError.invalidTransition }
      _ = try database.execute(
        """
        UPDATE herdr_replacement_role_hosts
        SET state = ?, lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
        WHERE id = ?
        """,
        bindings: [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(id)]
      )
      return try Self.requireReplacementRoleHost(id, database: database)
    }
  }

  @discardableResult
  public func rebindRoleHost(
    id: String,
    workspaceID: String,
    tabID: String,
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity,
    now: Date
  ) async throws -> HerdrRoleHostRecord {
    guard Self.validID(workspaceID), Self.validID(tabID), Self.validID(paneID),
      Self.validID(terminalID)
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let current = try Self.requireRoleHost(id, database: database)
      guard [.waiting, .running].contains(current.state),
        current.terminalID == terminalID,
        current.processIdentity == processIdentity,
        try !Self.replacementRoleHostPhysicalCollision(
          paneID: paneID,
          terminalID: terminalID,
          processIdentity: processIdentity,
          database: database
        )
      else {
        throw PiRunStoreError.bindingCollision
      }
      if current.workspaceID == workspaceID, current.tabID == tabID,
        current.paneID == paneID
      {
        return current
      }
      _ = try database.execute(
        """
        UPDATE herdr_role_hosts
        SET workspace_id = ?, tab_id = ?, pane_id = ?,
          lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
        WHERE id = ? AND terminal_id = ?
        """,
        bindings: [
          .text(workspaceID),
          .text(tabID),
          .text(paneID),
          .real(now.timeIntervalSince1970),
          .text(id),
          .text(terminalID),
        ]
      )
      let launches = try database.query(
        """
        SELECT l.* FROM pi_run_launches l
        WHERE l.role_host_id = ? AND l.state IN ('enqueued', 'running', 'resultPrepared')
        ORDER BY l.queue_sequence, l.launch_attempt_id
        """,
        bindings: [.text(id)]
      ).map(Self.decodeLaunch)
      for launch in launches {
        try Self.appendEvent(
          runID: launch.runID,
          launchAttemptID: launch.launchAttemptID,
          kind: .rebound,
          recordSHA256: nil,
          detailCode: nil,
          now: now,
          database: database
        )
      }
      return try Self.requireRoleHost(id, database: database)
    }
  }

  @discardableResult
  public func transitionRoleHost(
    id: String,
    to state: HerdrRoleHostState,
    now: Date
  ) async throws -> HerdrRoleHostRecord {
    try await database.transaction { database in
      let current = try Self.requireRoleHost(id, database: database)
      if current.state == state { return current }
      let valid =
        (current.state == .waiting && state == .stopping)
        || (current.state == .stopping && state == .stopped)
      guard valid else { throw PiRunStoreError.invalidTransition }
      _ = try database.execute(
        """
        UPDATE herdr_role_hosts
        SET state = ?, lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
        WHERE id = ?
        """,
        bindings: [
          .text(state.rawValue),
          .real(now.timeIntervalSince1970),
          .text(id),
        ]
      )
      return try Self.requireRoleHost(id, database: database)
    }
  }

  public func markRoleHostLost(id: String, now: Date) async throws {
    try await database.transaction { database in
      let current = try Self.requireRoleHost(id, database: database)
      if current.state == .lost || current.state == .stopped { return }
      guard [.prepared, .waiting, .running, .stopping].contains(current.state) else {
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        UPDATE herdr_role_hosts
        SET state = 'lost', lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
        WHERE id = ?
        """,
        bindings: [.real(now.timeIntervalSince1970), .text(id)]
      )
      let launches = try database.query(
        """
        SELECT * FROM pi_run_launches
        WHERE role_host_id = ?
          AND state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
        ORDER BY queue_sequence, launch_attempt_id
        """,
        bindings: [.text(id)]
      ).map(Self.decodeLaunch)
      for launch in launches {
        _ = try database.execute(
          """
          UPDATE pi_run_launches
          SET state = 'interruptedUnknown', failure_code = 'ROLE_HOST_LOST', updated_at = ?
          WHERE launch_attempt_id = ?
          """,
          bindings: [
            .real(now.timeIntervalSince1970),
            .text(launch.launchAttemptID),
          ]
        )
        _ = try database.execute(
          """
          UPDATE pi_runs SET outcome = 'interruptedUnknown', updated_at = ?
          WHERE id = ? AND settled = 0
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(launch.runID)]
        )
        try Self.appendEvent(
          runID: launch.runID,
          launchAttemptID: launch.launchAttemptID,
          kind: .interruptedUnknown,
          recordSHA256: nil,
          detailCode: "ROLE_HOST_LOST",
          now: now,
          database: database
        )
      }
    }
  }

  public func markReplacementRoleHostLost(id: String, now: Date) async throws {
    try await database.transaction { database in
      guard let current = try Self.loadReplacementRoleHost(id, database: database) else {
        throw PiRunStoreError.roleHostNotFound(id)
      }
      if current.state == .lost || current.state == .stopped { return }
      guard [.waiting, .running, .stopping].contains(current.state), now >= current.updatedAt else {
        throw PiRunStoreError.invalidTransition
      }
      guard
        try database.execute(
          """
          UPDATE herdr_replacement_role_hosts
          SET state = 'lost', lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
          WHERE id = ? AND state IN ('waiting', 'running', 'stopping')
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(id)]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }
      let launches = try database.query(
        """
        SELECT * FROM pi_run_launches
        WHERE execution_role_host_id = ?
          AND state IN ('prepared', 'enqueued', 'running', 'resultPrepared')
        ORDER BY queue_sequence, launch_attempt_id
        """,
        bindings: [.text(id)]
      ).map(Self.decodeLaunch)
      guard launches.count <= 1 else { throw PiRunStoreError.bindingCollision }
      for launch in launches {
        _ = try database.execute(
          """
          UPDATE pi_run_launches
          SET state = 'interruptedUnknown', failure_code = 'REPLACEMENT_ROLE_HOST_LOST',
            updated_at = ?
          WHERE launch_attempt_id = ?
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(launch.launchAttemptID)]
        )
        _ = try database.execute(
          """
          UPDATE pi_runs SET outcome = 'interruptedUnknown', updated_at = ?
          WHERE id = ? AND settled = 0
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(launch.runID)]
        )
        try Self.appendEvent(
          runID: launch.runID,
          launchAttemptID: launch.launchAttemptID,
          kind: .interruptedUnknown,
          recordSHA256: nil,
          detailCode: "REPLACEMENT_ROLE_HOST_LOST",
          now: now,
          database: database
        )
      }
    }
  }

  public func activeLaunch(roleHostID: String) async throws -> PiRunLaunchRecord? {
    let rows = try await database.query(
      """
      SELECT * FROM pi_run_launches
      WHERE COALESCE(execution_role_host_id, role_host_id) = ?
        AND state IN ('enqueued', 'running', 'resultPrepared')
      ORDER BY queue_sequence
      """,
      bindings: [.text(roleHostID)]
    )
    guard rows.count <= 1 else { throw PiRunStoreError.bindingCollision }
    return try rows.first.map(Self.decodeLaunch)
  }

  public func runs() async throws -> [PiRunRecord] {
    try await database.query(
      "SELECT * FROM pi_runs WHERE runtime_kind = 'herdr' ORDER BY created_at, id"
    ).map(Self.decodeRun)
  }

  @discardableResult
  public func prepareRun(
    id: String,
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    jobAttempt: Int,
    topologyGeneration: Int,
    jobStep: Int,
    resumesRunID: String? = nil,
    runNonce: String,
    requestSHA256: String,
    resourceVersion: String,
    resourceHash: String,
    model: String,
    sessionPath: URL,
    channelPath: URL,
    now: Date
  ) async throws -> PiRunRecord {
    guard Self.validRuntimeID(id), (1...3).contains(round), jobAttempt >= 0,
      topologyGeneration > 0, jobStep >= 0,
      PiWorkflowResourceCatalog.valid(role: role, for: workflow),
      resumesRunID.map(Self.validRuntimeID) ?? true,
      Self.isSHA256(runNonce), Self.isSHA256(requestSHA256),
      Self.isSHA256(resourceHash), !resourceVersion.isEmpty,
      !model.isEmpty, model.utf8.count <= 512,
      Self.validAbsolutePath(sessionPath), Self.validAbsolutePath(channelPath)
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      try Self.requireLaunchEligibility(database: database, jobID: jobID)
      let binding = try Self.requireJobBinding(jobID, database: database)
      guard binding.state == .active, binding.generation == topologyGeneration,
        let job = try database.query(
          "SELECT state, attempt, current_step FROM jobs WHERE id = ?",
          bindings: [.text(Self.uuid(jobID))]
        ).first,
        try Self.text(job, "state") == JobState.runningPi.rawValue,
        try Self.integer(job, "attempt") == Int64(jobAttempt),
        try Self.integer(job, "current_step") == Int64(jobStep)
      else {
        throw PiRunStoreError.bindingCollision
      }
      if let resumesRunID {
        let prior = try Self.requireRun(resumesRunID, database: database)
        guard role == .writer, round > 1,
          prior.jobID == jobID, prior.workflow == workflow, prior.role == role,
          prior.jobStep == jobStep, prior.round == round - 1,
          prior.accepted, prior.settled,
          prior.sessionID != nil, prior.sessionBoundarySHA256 != nil
        else {
          throw PiRunStoreError.bindingCollision
        }
      }
      if let existing = try Self.loadRun(id, database: database) {
        guard existing.jobID == jobID, existing.workflow == workflow,
          existing.role == role, existing.round == round,
          existing.jobAttempt == jobAttempt,
          existing.topologyGeneration == topologyGeneration,
          existing.jobStep == jobStep, existing.resumesRunID == resumesRunID,
          existing.runNonce == runNonce,
          existing.requestSHA256 == requestSHA256,
          existing.resourceVersion == resourceVersion,
          existing.resourceHash == resourceHash, existing.model == model,
          existing.sessionPath == sessionPath.path,
          existing.channelPath == channelPath.path
        else {
          throw PiRunStoreError.bindingCollision
        }
        return existing
      }
      let occupiedSlot = try database.query(
        """
        SELECT id FROM pi_runs
        WHERE runtime_kind = 'herdr' AND job_id = ? AND topology_generation = ?
          AND job_step = ? AND workflow = ? AND role = ? AND round = ?
        """,
        bindings: [
          .text(Self.uuid(jobID)),
          .integer(Int64(topologyGeneration)),
          .integer(Int64(jobStep)),
          .text(workflow.rawValue),
          .text(role.rawValue),
          .integer(Int64(round)),
        ]
      )
      guard occupiedSlot.isEmpty else { throw PiRunStoreError.bindingCollision }
      _ = try database.execute(
        """
        INSERT INTO pi_runs(
          id, job_id, runtime_kind, workflow, role, round, job_attempt,
          topology_generation, job_step, resumes_run_id,
          run_nonce, request_sha256, resource_version, resource_hash, model,
          session_path, session_id, session_boundary_sha256, channel_path,
          accepted, settled, structured_result_digest, outcome, created_at, updated_at
        ) VALUES (?, ?, 'herdr', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?,
          0, 0, NULL, 'prepared', ?, ?)
        """,
        bindings: [
          .text(id),
          .text(Self.uuid(jobID)),
          .text(workflow.rawValue),
          .text(role.rawValue),
          .integer(Int64(round)),
          .integer(Int64(jobAttempt)),
          .integer(Int64(topologyGeneration)),
          .integer(Int64(jobStep)),
          resumesRunID.map(SQLiteValue.text) ?? .null,
          .text(runNonce),
          .text(requestSHA256),
          .text(resourceVersion),
          .text(resourceHash),
          .text(model),
          .text(sessionPath.path),
          .text(channelPath.path),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      try Self.appendEvent(
        runID: id,
        launchAttemptID: nil,
        kind: .prepared,
        recordSHA256: requestSHA256,
        detailCode: nil,
        now: now,
        database: database
      )
      return try Self.requireRun(id, database: database)
    }
  }

  public func matchingRuns(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    topologyGeneration: Int,
    jobStep: Int,
    requestSHA256: String
  ) async throws -> [PiRunRecord] {
    guard (1...3).contains(round), topologyGeneration > 0, jobStep >= 0,
      Self.isSHA256(requestSHA256)
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.query(
      """
      SELECT * FROM pi_runs
      WHERE runtime_kind = 'herdr' AND job_id = ? AND workflow = ? AND role = ?
        AND round = ? AND topology_generation = ? AND job_step = ?
        AND request_sha256 = ?
      ORDER BY created_at, id
      """,
      bindings: [
        .text(Self.uuid(jobID)),
        .text(workflow.rawValue),
        .text(role.rawValue),
        .integer(Int64(round)),
        .integer(Int64(topologyGeneration)),
        .integer(Int64(jobStep)),
        .text(requestSHA256),
      ]
    ).map(Self.decodeRun)
  }

  public func settledRunForReplay(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    jobStep: Int,
    requestSHA256: String
  ) async throws -> PiRunRecord? {
    guard (1...3).contains(round), jobStep >= 0, Self.isSHA256(requestSHA256) else {
      throw PiRunStoreError.invalidRecord
    }
    let rows = try await database.query(
      """
      SELECT * FROM pi_runs
      WHERE runtime_kind = 'herdr' AND job_id = ? AND workflow = ? AND role = ?
        AND round = ? AND job_step = ? AND request_sha256 = ? AND settled = 1
      ORDER BY topology_generation DESC, created_at DESC, id DESC
      """,
      bindings: [
        .text(Self.uuid(jobID)),
        .text(workflow.rawValue),
        .text(role.rawValue),
        .integer(Int64(round)),
        .integer(Int64(jobStep)),
        .text(requestSHA256),
      ]
    ).map(Self.decodeRun)
    guard rows.count <= 1 else { throw PiRunStoreError.bindingCollision }
    return rows.first
  }

  public func runForSlot(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    topologyGeneration: Int,
    jobStep: Int
  ) async throws -> PiRunRecord? {
    guard (1...3).contains(round), topologyGeneration > 0, jobStep >= 0 else {
      throw PiRunStoreError.invalidRecord
    }
    let rows = try await database.query(
      """
      SELECT * FROM pi_runs
      WHERE runtime_kind = 'herdr' AND job_id = ? AND workflow = ? AND role = ?
        AND round = ? AND topology_generation = ? AND job_step = ?
      ORDER BY created_at, id
      """,
      bindings: [
        .text(Self.uuid(jobID)),
        .text(workflow.rawValue),
        .text(role.rawValue),
        .integer(Int64(round)),
        .integer(Int64(topologyGeneration)),
        .integer(Int64(jobStep)),
      ]
    ).map(Self.decodeRun)
    guard rows.count <= 1 else { throw PiRunStoreError.bindingCollision }
    return rows.first
  }

  public func settledRunForResume(
    jobID: UUID,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    priorRound: Int,
    jobStep: Int,
    sessionID: String,
    sessionBoundarySHA256: String
  ) async throws -> PiRunRecord? {
    guard role == .writer, (1..<3).contains(priorRound), jobStep >= 0,
      Self.validSessionID(sessionID), Self.isSHA256(sessionBoundarySHA256)
    else {
      throw PiRunStoreError.invalidRecord
    }
    let rows = try await database.query(
      """
      SELECT * FROM pi_runs
      WHERE runtime_kind = 'herdr' AND job_id = ? AND workflow = ? AND role = ?
        AND round = ? AND job_step = ? AND accepted = 1 AND settled = 1
        AND session_id = ? AND session_boundary_sha256 = ?
      ORDER BY created_at, id
      """,
      bindings: [
        .text(Self.uuid(jobID)),
        .text(workflow.rawValue),
        .text(role.rawValue),
        .integer(Int64(priorRound)),
        .integer(Int64(jobStep)),
        .text(sessionID),
        .text(sessionBoundarySHA256),
      ]
    ).map(Self.decodeRun)
    guard rows.count <= 1 else { throw PiRunStoreError.bindingCollision }
    return rows.first
  }

  public func run(id: String) async throws -> PiRunRecord? {
    try await database.query(
      "SELECT * FROM pi_runs WHERE id = ? AND runtime_kind = 'herdr'",
      bindings: [.text(id)]
    ).first.map(Self.decodeRun)
  }

  @discardableResult
  public func prepareLaunch(
    launchAttemptID: String,
    runID: String,
    roleHostID: String,
    launchMode: PiRunLaunchMode,
    descriptorSHA256: String,
    expectedSessionID: String?,
    resumeBoundarySHA256: String?,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    try await prepareLaunch(
      launchAttemptID: launchAttemptID,
      runID: runID,
      roleHostID: roleHostID,
      launchMode: launchMode,
      descriptorSHA256: descriptorSHA256,
      expectedSessionID: expectedSessionID,
      resumeBoundarySHA256: resumeBoundarySHA256,
      primedAuthority: nil,
      now: now
    )
  }

  @discardableResult
  func persistRoleHostReplacementAuthorization(
    _ authorization: JobCanaryRoleHostReplacementAuthorization,
    payload: HerdrRoleHostReplacementPayload,
    now: Date
  ) async throws -> Bool {
    try authorization.validate()
    try payload.validate()
    let request = authorization.request
    let canary = request.retry.recovery.canary
    let payloadSHA256 = try payload.payloadSHA256
    let replacementAuthorizationSHA256 = authorization.authorizationSHA256
    guard GitHubInputValidation.validSHA256(replacementAuthorizationSHA256),
      canary.scope.maximumCommentParts == 8,
      payload.replacementAuthorizationSHA256 == replacementAuthorizationSHA256,
      payload.replacementEvidenceSHA256 == authorization.replacementEvidenceSHA256,
      payload.q4Binding == authorization.q4Binding,
      payload.incidentAuditSHA256 == request.incidentAuditSHA256,
      payload.canaryAuthorizationSHA256 == canary.authorizationSHA256,
      payload.recoveryEvidenceSHA256 == request.retry.recovery.recoveryEvidenceSHA256,
      payload.retryEvidenceSHA256 == request.retry.retryEvidenceSHA256,
      payload.jobID == canary.scope.jobID.uuidString.lowercased(),
      payload.replacementRoleHostID == request.plannedReplacementRoleHostID,
      payload.plannedLaunchAttemptID == request.plannedLaunchAttemptID,
      request.stalePaneRevision <= UInt64(Int64.max)
    else { throw PiRunStoreError.invalidRecord }

    return try await database.transaction { database in
      let candidateCount = try database.scalarInt(
        """
        SELECT COUNT(*)
        FROM herdr_role_host_replacement_candidates AS candidate
        WHERE candidate.repository_id = ?
          AND candidate.job_id = ?
          AND candidate.generation = ?
          AND candidate.run_id = ?
          AND candidate.failed_launch_attempt_id = ?
          AND candidate.predecessor_role_host_id = ?
          AND candidate.anchor_role_host_id = ?
          AND candidate.anchor_pane_id = ?
          AND candidate.anchor_terminal_id = ?
          AND (
            SELECT COUNT(*) FROM job_transitions AS admit
            WHERE admit.job_id = candidate.job_id
              AND admit.event_key = ?
              AND admit.id = (
                SELECT MAX(latest.id) FROM job_transitions AS latest
                WHERE latest.event_key GLOB 'canary:*:m*:admit:*'
              )
          ) = 1
          AND NOT EXISTS (
            SELECT 1 FROM job_transitions AS close
            WHERE close.job_id = candidate.job_id AND close.event_key = ?
          )
          AND (
            SELECT COUNT(*) FROM job_transitions AS recovery
            WHERE recovery.job_id = candidate.job_id AND recovery.event_key = ?
          ) = 1
          AND (
            SELECT COUNT(*) FROM job_transitions AS retry
            WHERE retry.job_id = candidate.job_id
              AND retry.from_state = 'runningPi' AND retry.to_state = 'runningPi'
              AND retry.event_key = ?
          ) = 1
        """,
        bindings: [
          .text(payload.repositoryID),
          .text(payload.jobID),
          .integer(Int64(payload.generation)),
          .text(payload.runID),
          .text(payload.failedLaunchAttemptID),
          .text(payload.predecessorRoleHostID),
          .text(payload.anchorRoleHostID),
          .text(payload.anchorPaneID),
          .text(payload.anchorTerminalID),
          .text(
            "canary:\(payload.canaryAuthorizationSHA256):m8:admit:\(payload.jobID)"
          ),
          .text(
            "canary:\(payload.canaryAuthorizationSHA256):m8:close:\(payload.jobID)"
          ),
          .text(
            "canary:\(payload.canaryAuthorizationSHA256):m8:topology-recovery:"
              + payload.recoveryEvidenceSHA256
          ),
          .text(
            "canary:\(payload.canaryAuthorizationSHA256):m8:pi-fresh-retry:"
              + "\(payload.runID):\(payload.failedLaunchAttemptID):"
              + payload.retryEvidenceSHA256
          ),
        ]
      )
      guard candidateCount == 1,
        try database.scalarInt(
          "SELECT COUNT(*) FROM herdr_role_hosts WHERE id = ?",
          bindings: [.text(payload.replacementRoleHostID)]
        ) == 0,
        try database.scalarInt(
          "SELECT COUNT(*) FROM pi_run_launches WHERE launch_attempt_id = ?",
          bindings: [.text(payload.plannedLaunchAttemptID)]
        ) == 0
      else { throw PiRunStoreError.invalidTransition }

      let existing = try database.query(
        """
        SELECT * FROM herdr_role_host_replacement_authorizations
        WHERE job_id = ? OR replacement_authorization_sha256 = ? OR payload_sha256 = ?
          OR planned_replacement_role_host_id = ? OR planned_launch_attempt_id = ?
        """,
        bindings: [
          .text(payload.jobID),
          .text(replacementAuthorizationSHA256),
          .text(payloadSHA256),
          .text(payload.replacementRoleHostID),
          .text(payload.plannedLaunchAttemptID),
        ]
      )
      if let row = existing.first {
        guard existing.count == 1,
          try Self.text(row, "replacement_authorization_sha256")
            == replacementAuthorizationSHA256,
          try Self.text(row, "payload_sha256") == payloadSHA256,
          try Self.text(row, "replacement_evidence_sha256")
            == payload.replacementEvidenceSHA256,
          try Self.text(row, "incident_audit_sha256") == payload.incidentAuditSHA256,
          try Self.text(row, "canary_authorization_sha256")
            == payload.canaryAuthorizationSHA256,
          try Self.text(row, "recovery_evidence_sha256")
            == payload.recoveryEvidenceSHA256,
          try Self.text(row, "retry_evidence_sha256") == payload.retryEvidenceSHA256,
          try Self.text(row, "repository_id") == payload.repositoryID,
          try Self.text(row, "job_id") == payload.jobID,
          try Self.integer(row, "generation") == Int64(payload.generation),
          try Self.text(row, "run_id") == payload.runID,
          try Self.text(row, "failed_launch_attempt_id")
            == payload.failedLaunchAttemptID,
          try Self.text(row, "predecessor_role_host_id")
            == payload.predecessorRoleHostID,
          try Self.text(row, "planned_replacement_role_host_id")
            == payload.replacementRoleHostID,
          try Self.text(row, "planned_launch_attempt_id")
            == payload.plannedLaunchAttemptID,
          try Self.integer(row, "stale_pane_revision")
            == Int64(request.stalePaneRevision),
          try Self.integer(row, "stale_pane_had_tokens")
            == (request.stalePaneHadTokens ? 1 : 0),
          try Self.text(row, "stale_pane_tokens_sha256")
            == request.stalePaneTokensSHA256,
          try Self.text(row, "q4_descriptor_sha256")
            == payload.q4Binding.descriptorSHA256,
          try Self.text(row, "q4_configuration_sha256")
            == payload.q4Binding.configurationSHA256,
          try Self.text(row, "q4_prompt_sha256") == payload.q4Binding.promptSHA256,
          try Self.text(row, "q4_workflow_configuration_sha256")
            == payload.q4Binding.workflowConfigurationSHA256,
          try Self.text(row, "q4_prior_launch_descriptor_sha256")
            == payload.q4Binding.priorLaunchDescriptorSHA256,
          try Self.text(row, "q4_prior_launch_configuration_sha256")
            == payload.q4Binding.priorLaunchConfigurationSHA256,
          try Self.text(row, "q4_resource_tree_sha256")
            == payload.q4Binding.resourceTreeSHA256,
          try Self.text(row, "replacement_bootstrap_descriptor_sha256")
            == payload.replacementBootstrapDescriptorSHA256,
          try Self.text(row, "host_executable_sha256") == payload.hostExecutableSHA256,
          try Self.text(row, "credential_evidence_sha256")
            == payload.credentialEvidenceSHA256
        else { throw PiRunStoreError.bindingCollision }
        return true
      }

      _ = try database.execute(
        """
        INSERT INTO herdr_role_host_replacement_authorizations(
          replacement_authorization_sha256, payload_sha256,
          replacement_evidence_sha256, incident_audit_sha256,
          canary_authorization_sha256, recovery_evidence_sha256,
          retry_evidence_sha256, repository_id, job_id, generation, run_id,
          failed_launch_attempt_id, predecessor_role_host_id,
          planned_replacement_role_host_id, planned_launch_attempt_id,
          stale_pane_revision, stale_pane_had_tokens, stale_pane_tokens_sha256,
          q4_descriptor_sha256, q4_configuration_sha256, q4_prompt_sha256,
          q4_workflow_configuration_sha256, q4_prior_launch_descriptor_sha256,
          q4_prior_launch_configuration_sha256, q4_resource_tree_sha256,
          replacement_bootstrap_descriptor_sha256, host_executable_sha256,
          credential_evidence_sha256, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(replacementAuthorizationSHA256),
          .text(payloadSHA256),
          .text(payload.replacementEvidenceSHA256),
          .text(payload.incidentAuditSHA256),
          .text(payload.canaryAuthorizationSHA256),
          .text(payload.recoveryEvidenceSHA256),
          .text(payload.retryEvidenceSHA256),
          .text(payload.repositoryID),
          .text(payload.jobID),
          .integer(Int64(payload.generation)),
          .text(payload.runID),
          .text(payload.failedLaunchAttemptID),
          .text(payload.predecessorRoleHostID),
          .text(payload.replacementRoleHostID),
          .text(payload.plannedLaunchAttemptID),
          .integer(Int64(request.stalePaneRevision)),
          .integer(request.stalePaneHadTokens ? 1 : 0),
          .text(request.stalePaneTokensSHA256),
          .text(payload.q4Binding.descriptorSHA256),
          .text(payload.q4Binding.configurationSHA256),
          .text(payload.q4Binding.promptSHA256),
          .text(payload.q4Binding.workflowConfigurationSHA256),
          .text(payload.q4Binding.priorLaunchDescriptorSHA256),
          .text(payload.q4Binding.priorLaunchConfigurationSHA256),
          .text(payload.q4Binding.resourceTreeSHA256),
          .text(payload.replacementBootstrapDescriptorSHA256),
          .text(payload.hostExecutableSHA256),
          .text(payload.credentialEvidenceSHA256),
          .real(now.timeIntervalSince1970),
        ]
      )
      return false
    }
  }

  @discardableResult
  func prepareReplacementFreshLaunch(
    launchAttemptID: String,
    runID: String,
    predecessorRoleHostID: String,
    replacementRoleHostID: String,
    descriptorSHA256: String,
    bootstrapDescriptorSHA256: String,
    authority: HerdrReplacementLaunchAuthority,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    try authority.payload.validate()
    guard Self.validRuntimeID(launchAttemptID), Self.validRuntimeID(runID),
      Self.validRuntimeID(predecessorRoleHostID), Self.validRuntimeID(replacementRoleHostID),
      predecessorRoleHostID != replacementRoleHostID,
      Self.isSHA256(descriptorSHA256), Self.isSHA256(bootstrapDescriptorSHA256),
      descriptorSHA256 == authority.payload.q4Binding.descriptorSHA256,
      Self.isSHA256(try authority.payload.payloadSHA256)
    else { throw PiRunStoreError.invalidRecord }
    return try await database.transaction { database in
      try Self.requireLaunchEligibility(
        database: database,
        jobID: try Self.requireRun(runID, database: database).jobID
      )
      let run = try Self.requireRun(runID, database: database)
      let predecessor = try Self.requireRoleHost(predecessorRoleHostID, database: database)
      let payload = authority.payload
      let payloadSHA256 = try payload.payloadSHA256
      let attribution = authority.attribution
      let replacementProcessIdentity = try HerdrHostProcessIdentity(
        processID: attribution.processID,
        startSeconds: attribution.startSeconds,
        startMicroseconds: attribution.startMicroseconds
      )
      let ordinaryHosts = try database.query(
        "SELECT * FROM herdr_role_hosts WHERE job_id = ? AND generation = ?",
        bindings: [
          .text(Self.uuid(run.jobID)),
          .integer(Int64(run.topologyGeneration)),
        ]
      ).map(Self.decodeRoleHost)
      guard let anchor = ordinaryHosts.first(where: { $0.id == payload.anchorRoleHostID }),
        let anchorProcessIdentity = anchor.processIdentity
      else { throw PiRunStoreError.invalidTransition }
      guard !run.settled, run.outcome == .running, run.role == .architecture,
        predecessor.jobID == run.jobID,
        predecessor.generation == run.topologyGeneration,
        predecessor.role == .architecture,
        predecessor.state == .waiting,
        predecessor.lastQueueSequence == 3,
        now >= predecessor.updatedAt,
        anchor.jobID == run.jobID,
        anchor.generation == run.topologyGeneration,
        anchor.role == .security,
        anchor.state == .waiting,
        anchor.workspaceID == predecessor.workspaceID,
        anchor.tabID == predecessor.tabID,
        anchor.paneID == payload.anchorPaneID,
        anchor.terminalID == payload.anchorTerminalID,
        payload.anchorRoleHostID != predecessor.id,
        payload.repositoryID
          == (try Self.jobRepositoryID(run.jobID, database: database)),
        payload.jobID == Self.uuid(run.jobID),
        payload.generation == run.topologyGeneration,
        payload.runID == run.id,
        payload.failedLaunchAttemptID
          == (try Self.launchAttemptID(runID: run.id, sequence: 3, database: database)),
        payload.plannedLaunchAttemptID == launchAttemptID,
        payload.predecessorRoleHostID == predecessor.id,
        payload.replacementRoleHostID == replacementRoleHostID,
        payload.replacementBootstrapDescriptorSHA256 == bootstrapDescriptorSHA256,
        payload.queueSequence == 4,
        payload.workspaceID == predecessor.workspaceID,
        payload.tabID == predecessor.tabID,
        payload.predecessorPaneID == predecessor.paneID,
        payload.predecessorTerminalID == predecessor.terminalID,
        payload.predecessorBootstrapDescriptorSHA256
          == predecessor.bootstrapDescriptorSHA256,
        payload.hostExecutableSHA256 == predecessor.hostExecutableSHA256,
        payload.predecessorProcessID == predecessor.processIdentity?.processID,
        payload.predecessorStartSeconds == predecessor.processIdentity?.startSeconds,
        payload.predecessorStartMicroseconds == predecessor.processIdentity?.startMicroseconds,
        attribution.predecessorRoleHostID == predecessor.id,
        attribution.replacementRoleHostID == replacementRoleHostID,
        attribution.workspaceID == predecessor.workspaceID,
        attribution.tabID == predecessor.tabID,
        attribution.hostExecutableSHA256 == predecessor.hostExecutableSHA256,
        attribution.hostExecutableDevice == payload.hostExecutableDevice,
        attribution.hostExecutableInode == payload.hostExecutableInode,
        attribution.incidentAuditSHA256 == payload.incidentAuditSHA256,
        attribution.replacementEvidenceSHA256 == payload.replacementEvidenceSHA256,
        attribution.replacementAuthorizationSHA256
          == payload.replacementAuthorizationSHA256,
        attribution.credentialEvidenceSHA256 == payload.credentialEvidenceSHA256,
        attribution.q4Binding == payload.q4Binding,
        attribution.agent == "pi", attribution.agentSessionAbsent,
        attribution.alias == payload.alias,
        attribution.agentStateChangeSequence == payload.reportSequence,
        attribution.paneID != payload.predecessorPaneID,
        attribution.paneID != payload.anchorPaneID,
        attribution.terminalID != payload.predecessorTerminalID,
        attribution.terminalID != payload.anchorTerminalID,
        replacementProcessIdentity != predecessor.processIdentity,
        replacementProcessIdentity != anchorProcessIdentity,
        ordinaryHosts.allSatisfy({ host in
          host.id != replacementRoleHostID
            && host.paneID != attribution.paneID
            && host.terminalID != attribution.terminalID
            && host.processIdentity != replacementProcessIdentity
        }),
        Self.isSHA256(attribution.tokensSHA256),
        try !Self.ordinaryRoleHostCollision(
          id: replacementRoleHostID,
          paneID: attribution.paneID,
          terminalID: attribution.terminalID,
          processIdentity: replacementProcessIdentity,
          database: database
        ),
        try Self.loadLaunch(launchAttemptID, database: database) == nil,
        try Self.loadReplacementRoleHost(replacementRoleHostID, database: database) == nil,
        try database.scalarInt(
          "SELECT COUNT(*) FROM pi_run_launches WHERE run_id = ?",
          bindings: [.text(run.id)]
        ) == 3,
        try database.scalarInt(
          """
          SELECT COUNT(*)
          FROM herdr_role_host_replacement_candidates AS candidate
          JOIN herdr_topology_intents AS intent
            ON intent.id = ? AND intent.kind = 'replaceRoleHost'
            AND intent.repository_id = candidate.repository_id
            AND intent.job_id = candidate.job_id
            AND intent.generation = candidate.generation
            AND intent.socket_device = candidate.socket_device
            AND intent.socket_inode = candidate.socket_inode
            AND intent.socket_owner = candidate.socket_owner
            AND intent.socket_permissions = candidate.socket_permissions
            AND intent.state = 'sendStarted' AND intent.attribution_json IS NULL
          JOIN herdr_role_host_replacement_authorizations AS authorization
            ON authorization.payload_sha256 = intent.payload_sha256
            AND authorization.replacement_authorization_sha256 = ?
            AND authorization.replacement_evidence_sha256 = ?
            AND authorization.incident_audit_sha256 = ?
            AND authorization.repository_id = candidate.repository_id
            AND authorization.job_id = candidate.job_id
            AND authorization.generation = candidate.generation
            AND authorization.run_id = candidate.run_id
            AND authorization.failed_launch_attempt_id = candidate.failed_launch_attempt_id
            AND authorization.predecessor_role_host_id
              = candidate.predecessor_role_host_id
            AND authorization.planned_replacement_role_host_id = ?
            AND authorization.planned_launch_attempt_id = ?
            AND authorization.replacement_bootstrap_descriptor_sha256 = ?
            AND authorization.host_executable_sha256 = ?
            AND authorization.credential_evidence_sha256 = ?
            AND authorization.q4_descriptor_sha256 = ?
            AND authorization.q4_configuration_sha256 = ?
            AND authorization.q4_prompt_sha256 = ?
            AND authorization.q4_workflow_configuration_sha256 = ?
            AND authorization.q4_prior_launch_descriptor_sha256 = ?
            AND authorization.q4_prior_launch_configuration_sha256 = ?
            AND authorization.q4_resource_tree_sha256 = ?
          WHERE candidate.run_id = ?
            AND candidate.predecessor_role_host_id = ?
            AND candidate.failed_launch_attempt_id = ?
            AND candidate.anchor_role_host_id = ?
            AND candidate.anchor_pane_id = ?
            AND candidate.anchor_terminal_id = ?
            AND intent.intent_sha256 = ? AND intent.payload_sha256 = ?
          """,
          bindings: [
            .text(authority.receipt.mutationID),
            .text(payload.replacementAuthorizationSHA256),
            .text(payload.replacementEvidenceSHA256),
            .text(payload.incidentAuditSHA256),
            .text(replacementRoleHostID),
            .text(launchAttemptID),
            .text(bootstrapDescriptorSHA256),
            .text(payload.hostExecutableSHA256),
            .text(payload.credentialEvidenceSHA256),
            .text(payload.q4Binding.descriptorSHA256),
            .text(payload.q4Binding.configurationSHA256),
            .text(payload.q4Binding.promptSHA256),
            .text(payload.q4Binding.workflowConfigurationSHA256),
            .text(payload.q4Binding.priorLaunchDescriptorSHA256),
            .text(payload.q4Binding.priorLaunchConfigurationSHA256),
            .text(payload.q4Binding.resourceTreeSHA256),
            .text(run.id),
            .text(predecessor.id),
            .text(payload.failedLaunchAttemptID),
            .text(payload.anchorRoleHostID),
            .text(payload.anchorPaneID),
            .text(payload.anchorTerminalID),
            .text(authority.receipt.intentSHA256),
            .text(payloadSHA256),
          ]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let attributionData = try encoder.encode(attribution)
      let tokenData = try encoder.encode(payload.tokens)
      guard let attributionJSON = String(data: attributionData, encoding: .utf8),
        GitHubMarkerCodec.sha256(tokenData) == attribution.tokensSHA256
      else { throw PiRunStoreError.invalidRecord }

      _ = try database.execute(
        """
        INSERT INTO herdr_replacement_role_hosts(
          id, predecessor_role_host_id, replacement_intent_id, job_id, generation, role,
          workspace_id, tab_id, pane_id, terminal_id, bootstrap_descriptor_sha256,
          host_executable_sha256, q4_descriptor_sha256, q4_configuration_sha256,
          q4_prompt_sha256, q4_workflow_configuration_sha256,
          q4_prior_launch_descriptor_sha256, q4_prior_launch_configuration_sha256,
          q4_resource_tree_sha256, host_pid, host_start_seconds, host_start_microseconds,
          last_queue_sequence, lifecycle_sequence, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 'architecture', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 4,
          1, 'waiting', ?, ?)
        """,
        bindings: [
          .text(replacementRoleHostID),
          .text(predecessor.id),
          .text(authority.receipt.mutationID),
          .text(Self.uuid(run.jobID)),
          .integer(Int64(run.topologyGeneration)),
          .text(attribution.workspaceID),
          .text(attribution.tabID),
          .text(attribution.paneID),
          .text(attribution.terminalID),
          .text(bootstrapDescriptorSHA256),
          .text(attribution.hostExecutableSHA256),
          .text(payload.q4Binding.descriptorSHA256),
          .text(payload.q4Binding.configurationSHA256),
          .text(payload.q4Binding.promptSHA256),
          .text(payload.q4Binding.workflowConfigurationSHA256),
          .text(payload.q4Binding.priorLaunchDescriptorSHA256),
          .text(payload.q4Binding.priorLaunchConfigurationSHA256),
          .text(payload.q4Binding.resourceTreeSHA256),
          .integer(Int64(attribution.processID)),
          .integer(try Self.int64(attribution.startSeconds)),
          .integer(try Self.int64(attribution.startMicroseconds)),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      guard
        try database.execute(
          """
          UPDATE herdr_role_hosts
          SET state = 'stopped', lifecycle_sequence = lifecycle_sequence + 1, updated_at = ?
          WHERE id = ? AND state = 'waiting' AND last_queue_sequence = 3
          """,
          bindings: [.real(now.timeIntervalSince1970), .text(predecessor.id)]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }
      guard
        try database.execute(
          """
          UPDATE herdr_topology_intents
          SET state = 'attributed', attribution_json = ?, updated_at = ?
          WHERE id = ? AND kind = 'replaceRoleHost' AND state = 'sendStarted'
            AND intent_sha256 = ? AND payload_sha256 = ? AND attribution_json IS NULL
          """,
          bindings: [
            .text(attributionJSON),
            .real(now.timeIntervalSince1970),
            .text(authority.receipt.mutationID),
            .text(authority.receipt.intentSHA256),
            .text(payloadSHA256),
          ]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }
      let eventKey =
        "canary:\(payload.canaryAuthorizationSHA256):m\(payload.maximumCommentParts):"
        + "pi-role-host-replacement:\(run.id):\(payload.failedLaunchAttemptID):"
        + "\(launchAttemptID):\(predecessor.id):\(replacementRoleHostID):"
        + payloadSHA256
      guard
        try database.execute(
          """
          INSERT INTO job_transitions(
            job_id, event_key, from_state, to_state, reason, artifact_id,
            attempt_before, attempt_after, step_before, step_after, created_at
          )
          SELECT id, ?, state, state, ?, NULL, attempt, attempt,
            current_step, current_step, ?
          FROM jobs WHERE id = ? AND state = 'runningPi'
          """,
          bindings: [
            .text(eventKey),
            .text("exact architecture role host replaced for one q4 launch"),
            .real(now.timeIntervalSince1970),
            .text(Self.uuid(run.jobID)),
          ]
        ) == 1
      else { throw PiRunStoreError.invalidTransition }
      _ = try database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, execution_role_host_id,
          queue_sequence, launch_mode, descriptor_sha256, expected_session_id,
          resume_boundary_sha256, state, failure_code, created_at, updated_at
        ) VALUES (?, ?, ?, ?, 4, 'fresh', ?, NULL, NULL, 'prepared', NULL, ?, ?)
        """,
        bindings: [
          .text(launchAttemptID),
          .text(run.id),
          .text(predecessor.id),
          .text(replacementRoleHostID),
          .text(descriptorSHA256),
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireLaunch(launchAttemptID, database: database)
    }
  }

  @discardableResult
  func preparePrimedFreshLaunch(
    launchAttemptID: String,
    runID: String,
    roleHostID: String,
    descriptorSHA256: String,
    authority: HerdrPrimedLaunchAuthority,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    try authority.payload.validate()
    return try await prepareLaunch(
      launchAttemptID: launchAttemptID,
      runID: runID,
      roleHostID: roleHostID,
      launchMode: .fresh,
      descriptorSHA256: descriptorSHA256,
      expectedSessionID: nil,
      resumeBoundarySHA256: nil,
      primedAuthority: authority,
      now: now
    )
  }

  private func prepareLaunch(
    launchAttemptID: String,
    runID: String,
    roleHostID: String,
    launchMode: PiRunLaunchMode,
    descriptorSHA256: String,
    expectedSessionID: String?,
    resumeBoundarySHA256: String?,
    primedAuthority: HerdrPrimedLaunchAuthority?,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    guard Self.validRuntimeID(launchAttemptID), Self.validRuntimeID(runID),
      Self.validRuntimeID(roleHostID), Self.isSHA256(descriptorSHA256),
      Self.validLaunchMode(
        launchMode,
        expectedSessionID: expectedSessionID,
        resumeBoundarySHA256: resumeBoundarySHA256
      )
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      try Self.requireLaunchEligibility(database: database, jobID: run.jobID)
      let host = try Self.requireRoleHost(roleHostID, database: database)
      guard run.jobID == host.jobID,
        run.topologyGeneration == host.generation,
        run.role == host.role,
        [.waiting, .running].contains(host.state)
      else {
        throw PiRunStoreError.invalidTransition
      }
      if let authority = primedAuthority {
        guard launchMode == .fresh,
          expectedSessionID == nil,
          resumeBoundarySHA256 == nil,
          authority.payload.jobID == run.jobID.uuidString.lowercased(),
          authority.payload.runID == run.id,
          authority.payload.plannedLaunchAttemptID == launchAttemptID,
          authority.payload.roleHostID == host.id,
          authority.payload.generation == run.topologyGeneration,
          authority.payload.queueSequence == host.lastQueueSequence + 1,
          authority.payload.workspaceID == host.workspaceID,
          authority.payload.tabID == host.tabID,
          authority.payload.paneID == host.paneID,
          authority.payload.terminalID == host.terminalID,
          let identity = host.processIdentity,
          authority.payload.hostProcessID == identity.processID,
          authority.payload.hostStartSeconds == identity.startSeconds,
          authority.payload.hostStartMicroseconds == identity.startMicroseconds,
          authority.payload.hostExecutableSHA256 == host.hostExecutableSHA256,
          authority.payload.intentKind
            == (authority.payload.schemaVersion == 2
              ? .resetAgentAuthority : .primeAgentAuthority),
          authority.attribution.workspaceID == authority.payload.workspaceID,
          authority.attribution.tabID == authority.payload.tabID,
          authority.attribution.paneIDs == [authority.payload.paneID],
          authority.attribution.terminalID == authority.payload.terminalID,
          authority.attribution.alias == authority.payload.alias,
          authority.attribution.agent == "pi",
          authority.attribution.agentSessionAbsent,
          Self.isSHA256(authority.attribution.tokensSHA256)
        else { throw PiRunStoreError.invalidTransition }
      }
      if let existing = try Self.loadLaunch(launchAttemptID, database: database) {
        if primedAuthority != nil { throw PiRunStoreError.invalidTransition }
        guard existing.runID == runID, existing.roleHostID == roleHostID,
          existing.launchMode == launchMode,
          existing.descriptorSHA256 == descriptorSHA256,
          existing.expectedSessionID == expectedSessionID,
          existing.resumeBoundarySHA256 == resumeBoundarySHA256
        else {
          throw PiRunStoreError.bindingCollision
        }
        return existing
      }
      guard !run.settled else { throw PiRunStoreError.invalidTransition }
      let prior = try database.query(
        """
        SELECT * FROM pi_run_launches WHERE run_id = ?
        ORDER BY queue_sequence, launch_attempt_id
        """,
        bindings: [.text(runID)]
      ).map(Self.decodeLaunch)
      if prior.isEmpty {
        if let resumesRunID = run.resumesRunID {
          let origin = try Self.requireRun(resumesRunID, database: database)
          guard launchMode == .crossRunResume,
            run.role == .writer, run.round > 1,
            origin.accepted, origin.settled,
            origin.jobID == run.jobID,
            origin.workflow == run.workflow,
            origin.role == run.role,
            origin.jobStep == run.jobStep,
            origin.round == run.round - 1,
            origin.sessionID == expectedSessionID,
            origin.sessionBoundarySHA256 == resumeBoundarySHA256
          else {
            throw PiRunStoreError.invalidTransition
          }
        } else {
          guard launchMode == .fresh else {
            throw PiRunStoreError.invalidTransition
          }
        }
      } else {
        let sessionOrigin = try Self.loadSessionOrigin(runID, database: database)
        let last = prior.last
        let hasNoResult = try Self.loadResult(runID, database: database) == nil
        let freshRetryAuthorizationPattern =
          last.map {
            "canary:*:pi-fresh-retry:\(run.id):\($0.launchAttemptID):*"
          } ?? ""
        let freshRetryAuthorizationCount = try database.scalarInt(
          "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND from_state = 'runningPi' AND to_state = 'runningPi' AND event_key GLOB ?",
          bindings: [
            .text(run.jobID.uuidString.lowercased()),
            .text(freshRetryAuthorizationPattern),
          ]
        )
        let initialFreshRetryAuthorizationPattern =
          prior.first.map {
            "canary:*:pi-fresh-retry:\(run.id):\($0.launchAttemptID):*"
          } ?? ""
        let initialFreshRetryAuthorizationCount = try database.scalarInt(
          "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND from_state = 'runningPi' AND to_state = 'runningPi' AND event_key GLOB ?",
          bindings: [
            .text(run.jobID.uuidString.lowercased()),
            .text(initialFreshRetryAuthorizationPattern),
          ]
        )
        let sameRunResume =
          launchMode == .sameRunResume
          && last.map({ [.failed, .interruptedUnknown].contains($0.state) }) == true
          && sessionOrigin?.sessionID == expectedSessionID
          && sessionOrigin?.originResumeBoundarySHA256 == resumeBoundarySHA256
        let originalFreshRetry =
          prior.count == 1
          && last?.launchMode == .fresh
          && last?.state == .failed
          && last?.failureCode == "RUNTIME_TIMEOUT"
          && last?.childProcess != nil
        let hostTransactionRetry =
          prior.count == 2
          && prior.first?.launchMode == .fresh
          && prior.first?.state == .failed
          && prior.first?.failureCode == "RUNTIME_TIMEOUT"
          && prior.first?.childProcess != nil
          && last?.launchMode == .fresh
          && last?.state == .failed
          && last?.failureCode == "HERDR_TRANSACTION_FAILED"
          && last?.childProcess == nil
          && initialFreshRetryAuthorizationCount == 1
        let retryAuthorizationCounts = try prior.map { launch in
          try database.scalarInt(
            "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND from_state = 'runningPi' AND to_state = 'runningPi' AND event_key GLOB ?",
            bindings: [
              .text(run.jobID.uuidString.lowercased()),
              .text("canary:*:pi-fresh-retry:\(run.id):\(launch.launchAttemptID):*"),
            ]
          )
        }
        let totalRetryAuthorizationCount = try database.scalarInt(
          "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND from_state = 'runningPi' AND to_state = 'runningPi' AND event_key GLOB ?",
          bindings: [
            .text(run.jobID.uuidString.lowercased()),
            .text("canary:*:pi-fresh-retry:\(run.id):*"),
          ]
        )
        let noPrimeEffects =
          try database.scalarInt(
            "SELECT (SELECT COUNT(*) FROM pi_run_session_origins WHERE run_id = ?) + (SELECT COUNT(*) FROM artifacts WHERE job_id = ? AND kind = 'review') + (SELECT COUNT(*) FROM job_steps WHERE job_id = ?) + (SELECT COUNT(*) FROM approved_command_runs WHERE job_id = ?) + (SELECT COUNT(*) FROM mutation_intents WHERE job_id = ?)",
            bindings: [
              .text(run.id),
              .text(run.jobID.uuidString.lowercased()),
              .text(run.jobID.uuidString.lowercased()),
              .text(run.jobID.uuidString.lowercased()),
              .text(run.jobID.uuidString.lowercased()),
            ]
          ) == 0
        let legacyHostAuthorityRetry =
          prior.count == 3
          && prior[0].queueSequence == 1
          && prior[0].launchMode == .fresh
          && prior[0].state == .failed
          && prior[0].failureCode == "RUNTIME_TIMEOUT"
          && prior[0].childProcess != nil
          && prior[1].queueSequence == 2
          && prior[1].launchMode == .fresh
          && prior[1].state == .failed
          && prior[1].failureCode == "HERDR_TRANSACTION_FAILED"
          && prior[1].childProcess == nil
          && prior[2].queueSequence == 3
          && prior[2].launchMode == .fresh
          && prior[2].state == .failed
          && prior[2].failureCode == "HERDR_TRANSACTION_FAILED"
          && prior[2].childProcess == nil
          && (primedAuthority?.payload.intentKind == .primeAgentAuthority
            && retryAuthorizationCounts == [1, 1, 1]
            && totalRetryAuthorizationCount == 3
            || primedAuthority?.payload.intentKind == .resetAgentAuthority
              && retryAuthorizationCounts == [1, 1, 2]
              && totalRetryAuthorizationCount == 4)
          && noPrimeEffects
        let expectedFreshRetryAuthorizationCount: Int64 =
          primedAuthority?.payload.intentKind == .resetAgentAuthority ? 2 : 1
        let authorizedFreshRetry =
          launchMode == .fresh
          && (originalFreshRetry || hostTransactionRetry || legacyHostAuthorityRetry)
          && sessionOrigin == nil
          && expectedSessionID == nil
          && resumeBoundarySHA256 == nil
          && hasNoResult
          && (freshRetryAuthorizationCount ?? -1) == expectedFreshRetryAuthorizationCount
        guard sameRunResume || authorizedFreshRetry else {
          throw PiRunStoreError.invalidTransition
        }
        if let authority = primedAuthority {
          let candidateView: String
          let resetPredicate: String
          var bindings: [SQLiteValue] = [
            .text(authority.receipt.mutationID),
            .text(authority.receipt.intentSHA256),
            .text(authority.payload.payloadSHA256),
            .text(authority.payload.intentKind.rawValue),
            .text(run.id),
            .text(authority.payload.failedLaunchAttemptID),
            .text(host.id),
            .text(authority.payload.paneID),
            .text(authority.payload.terminalID),
          ]
          switch authority.payload.intentKind {
          case .primeAgentAuthority:
            candidateView = "herdr_prime_retry_candidates"
            resetPredicate = ""
          case .resetAgentAuthority:
            guard let failedPrimeIntentID = authority.payload.failedPrimeIntentID,
              let failedPrimeIntentSHA256 = authority.payload.failedPrimeIntentSHA256,
              let failedPrimePayloadSHA256 = authority.payload.failedPrimePayloadSHA256
            else { throw PiRunStoreError.invalidTransition }
            candidateView = "herdr_agent_reset_candidates"
            resetPredicate =
              " AND candidate.failed_prime_intent_id = ? AND candidate.failed_prime_intent_sha256 = ? AND candidate.failed_prime_payload_sha256 = ?"
            bindings.append(contentsOf: [
              .text(failedPrimeIntentID),
              .text(failedPrimeIntentSHA256),
              .text(failedPrimePayloadSHA256),
            ])
          default:
            throw PiRunStoreError.invalidTransition
          }
          let eligibleIntentCount = try database.scalarInt(
            """
            SELECT COUNT(*)
            FROM herdr_topology_intents AS intent
            JOIN \(candidateView) AS candidate
              ON candidate.job_id = intent.job_id
              AND candidate.repository_id = intent.repository_id
              AND candidate.generation = intent.generation
              AND candidate.socket_device = intent.socket_device
              AND candidate.socket_inode = intent.socket_inode
              AND candidate.socket_owner = intent.socket_owner
              AND candidate.socket_permissions = intent.socket_permissions
            WHERE intent.id = ? AND intent.intent_sha256 = ?
              AND intent.payload_sha256 = ? AND intent.kind = ?
              AND intent.state = 'sendStarted' AND intent.attribution_json IS NULL
              AND candidate.run_id = ? AND candidate.failed_launch_attempt_id = ?
              AND candidate.role_host_id = ? AND candidate.pane_id = ?
              AND candidate.terminal_id = ?\(resetPredicate)
            """,
            bindings: bindings
          )
          guard eligibleIntentCount == 1 else { throw PiRunStoreError.invalidTransition }
        }
      }
      let sequence = host.lastQueueSequence + 1
      if let authority = primedAuthority {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let attributionData = try encoder.encode(authority.attribution)
        let tokenData = try encoder.encode(authority.payload.tokens)
        guard let attributionJSON = String(data: attributionData, encoding: .utf8),
          GitHubMarkerCodec.sha256(tokenData) == authority.attribution.tokensSHA256,
          GitHubInputValidation.validSHA256(authority.payload.payloadSHA256)
        else { throw PiRunStoreError.invalidRecord }
        guard
          try database.execute(
            """
            UPDATE herdr_topology_intents
            SET state = 'attributed', attribution_json = ?, updated_at = ?
            WHERE id = ? AND kind = ? AND state = 'sendStarted'
              AND intent_sha256 = ? AND payload_sha256 = ? AND attribution_json IS NULL
            """,
            bindings: [
              .text(attributionJSON),
              .real(now.timeIntervalSince1970),
              .text(authority.receipt.mutationID),
              .text(authority.payload.intentKind.rawValue),
              .text(authority.receipt.intentSHA256),
              .text(authority.payload.payloadSHA256),
            ]
          ) == 1
        else { throw PiRunStoreError.invalidTransition }
        let authorityEvent =
          authority.payload.intentKind == .resetAgentAuthority
          ? "pi-agent-authority-reset" : "pi-agent-prime"
        let eventKey =
          "canary:\(authority.payload.canaryAuthorizationSHA256):m\(authority.payload.maximumCommentParts):\(authorityEvent):"
          + "\(run.id):\(authority.payload.failedLaunchAttemptID):\(launchAttemptID):"
          + "\(host.id):\(authority.payload.payloadSHA256)"
        guard
          try database.execute(
            """
            INSERT INTO job_transitions(
              job_id, event_key, from_state, to_state, reason, artifact_id,
              attempt_before, attempt_after, step_before, step_after, created_at
            )
            SELECT id, ?, state, state, ?, NULL, attempt, attempt,
              current_step, current_step, ?
            FROM jobs
            WHERE id = ? AND state = 'runningPi'
            """,
            bindings: [
              .text(eventKey),
              .text(
                authority.payload.intentKind == .resetAgentAuthority
                  ? "exact legacy role-host agent authority reset and primed for one launch"
                  : "exact legacy role-host agent authority primed for one launch"
              ),
              .real(now.timeIntervalSince1970),
              .text(run.jobID.uuidString.lowercased()),
            ]
          ) == 1
        else { throw PiRunStoreError.invalidTransition }
      }
      _ = try database.execute(
        "UPDATE herdr_role_hosts SET last_queue_sequence = ?, updated_at = ? WHERE id = ?",
        bindings: [
          .integer(Int64(sequence)),
          .real(now.timeIntervalSince1970),
          .text(roleHostID),
        ]
      )
      _ = try database.execute(
        """
        INSERT INTO pi_run_launches(
          launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
          descriptor_sha256, expected_session_id, resume_boundary_sha256,
          state, failure_code, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'prepared', NULL, ?, ?)
        """,
        bindings: [
          .text(launchAttemptID),
          .text(runID),
          .text(roleHostID),
          .integer(Int64(sequence)),
          .text(launchMode.rawValue),
          .text(descriptorSHA256),
          expectedSessionID.map(SQLiteValue.text) ?? .null,
          resumeBoundarySHA256.map(SQLiteValue.text) ?? .null,
          .real(now.timeIntervalSince1970),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireLaunch(launchAttemptID, database: database)
    }
  }

  @discardableResult
  public func transitionLaunch(
    launchAttemptID: String,
    to state: PiRunLaunchState,
    event: PiRunEventKind,
    recordSHA256: String? = nil,
    detailCode: String? = nil,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    if let recordSHA256, !Self.isSHA256(recordSHA256) {
      throw PiRunStoreError.invalidRecord
    }
    guard detailCode.map(Self.validDetailCode) ?? true else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let current = try Self.requireLaunch(launchAttemptID, database: database)
      guard Self.mayTransition(from: current.state, to: state, event: event) else {
        if current.state == state { return current }
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        UPDATE pi_run_launches
        SET state = ?, failure_code = ?, updated_at = ?
        WHERE launch_attempt_id = ?
        """,
        bindings: [
          .text(state.rawValue),
          detailCode.map(SQLiteValue.text) ?? .null,
          .real(now.timeIntervalSince1970),
          .text(launchAttemptID),
        ]
      )
      if state == .running {
        _ = try database.execute(
          "UPDATE pi_runs SET outcome = 'running', updated_at = ? WHERE id = ?",
          bindings: [.real(now.timeIntervalSince1970), .text(current.runID)]
        )
      }
      try Self.appendEvent(
        runID: current.runID,
        launchAttemptID: launchAttemptID,
        kind: event,
        recordSHA256: recordSHA256,
        detailCode: detailCode,
        now: now,
        database: database
      )
      return try Self.requireLaunch(launchAttemptID, database: database)
    }
  }

  @discardableResult
  public func recordChildProcess(
    launchAttemptID: String,
    record: HerdrChildProcessRecord,
    now: Date
  ) async throws -> PiRunLaunchRecord {
    guard record.launchAttemptID == launchAttemptID,
      record.processID > 0,
      record.processGroupID == record.processID,
      record.startMicroseconds < 1_000_000
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let current = try Self.requireLaunch(launchAttemptID, database: database)
      guard
        [.enqueued, .running, .resultPrepared, .failed, .interruptedUnknown].contains(
          current.state
        )
      else {
        throw PiRunStoreError.invalidTransition
      }
      if let existing = current.childProcess {
        guard existing == record else { throw PiRunStoreError.bindingCollision }
        return current
      }
      _ = try database.execute(
        """
        UPDATE pi_run_launches
        SET child_pid = ?, child_process_group_id = ?, child_start_seconds = ?,
          child_start_microseconds = ?, updated_at = ?
        WHERE launch_attempt_id = ? AND child_pid IS NULL
        """,
        bindings: [
          .integer(Int64(record.processID)),
          .integer(Int64(record.processGroupID)),
          .integer(try Self.int64(record.startSeconds)),
          .integer(try Self.int64(record.startMicroseconds)),
          .real(now.timeIntervalSince1970),
          .text(launchAttemptID),
        ]
      )
      try Self.appendEvent(
        runID: current.runID,
        launchAttemptID: launchAttemptID,
        kind: .childProcessRecorded,
        recordSHA256: nil,
        detailCode: nil,
        now: now,
        database: database
      )
      return try Self.requireLaunch(launchAttemptID, database: database)
    }
  }

  @discardableResult
  public func recordSessionOrigin(
    runID: String,
    launchAttemptID: String,
    sessionID: String,
    originResumeBoundarySHA256: String?,
    now: Date
  ) async throws -> PiRunSessionOriginRecord {
    guard Self.validRuntimeID(runID), Self.validRuntimeID(launchAttemptID),
      Self.validSessionID(sessionID),
      originResumeBoundarySHA256.map(Self.isSHA256) ?? true
    else {
      throw PiRunStoreError.invalidRecord
    }
    return try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      let launch = try Self.requireLaunch(launchAttemptID, database: database)
      if let existing = try Self.loadSessionOrigin(runID, database: database) {
        guard existing.launchAttemptID == launchAttemptID,
          existing.sessionID == sessionID,
          existing.originResumeBoundarySHA256 == originResumeBoundarySHA256
        else {
          throw PiRunStoreError.bindingCollision
        }
        return existing
      }
      let launches = try database.query(
        """
        SELECT * FROM pi_run_launches WHERE run_id = ?
        ORDER BY queue_sequence, launch_attempt_id
        """,
        bindings: [.text(runID)]
      ).map(Self.decodeLaunch)
      guard !run.settled, launch.runID == runID,
        launches.first?.launchAttemptID == launchAttemptID,
        [.failed, .interruptedUnknown].contains(launch.state),
        launch.expectedSessionID == nil || launch.expectedSessionID == sessionID,
        launch.resumeBoundarySHA256 == originResumeBoundarySHA256
      else {
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        INSERT INTO pi_run_session_origins(
          run_id, launch_attempt_id, session_id, origin_resume_boundary_sha256, created_at
        ) VALUES (?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(runID),
          .text(launchAttemptID),
          .text(sessionID),
          originResumeBoundarySHA256.map(SQLiteValue.text) ?? .null,
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.requireSessionOrigin(runID, database: database)
    }
  }

  public func sessionOrigin(runID: String) async throws -> PiRunSessionOriginRecord? {
    guard Self.validRuntimeID(runID) else { throw PiRunStoreError.invalidRecord }
    return try await database.query(
      "SELECT * FROM pi_run_session_origins WHERE run_id = ?",
      bindings: [.text(runID)]
    ).first.map(Self.decodeSessionOrigin)
  }

  @discardableResult
  public func settle(
    runID: String,
    launchAttemptID: String,
    resultEnvelope: Data,
    resultSHA256: String,
    sessionID: String,
    sessionBoundarySHA256: String,
    now: Date
  ) async throws -> PiRunRecord {
    guard !resultEnvelope.isEmpty, resultEnvelope.count <= 4 * 1_024 * 1_024,
      Self.sha256(resultEnvelope) == resultSHA256,
      Self.isSHA256(sessionBoundarySHA256), Self.validSessionID(sessionID)
    else {
      throw PiRunStoreError.invalidRecord
    }
    let settlementSHA256 = try Self.settlementSHA256(
      runID: runID,
      launchAttemptID: launchAttemptID,
      resultSHA256: resultSHA256,
      sessionID: sessionID,
      sessionBoundarySHA256: sessionBoundarySHA256
    )
    return try await database.transaction { database in
      let current = try Self.requireRun(runID, database: database)
      let launch = try Self.requireLaunch(launchAttemptID, database: database)
      guard launch.runID == runID else { throw PiRunStoreError.bindingCollision }
      if current.settled {
        guard current.accepted,
          current.structuredResultDigest == resultSHA256,
          current.sessionID == sessionID,
          current.sessionBoundarySHA256 == sessionBoundarySHA256,
          let stored = try Self.loadResult(runID, database: database),
          stored.launchAttemptID == launchAttemptID,
          stored.envelope == resultEnvelope,
          stored.resultSHA256 == resultSHA256,
          stored.sessionID == sessionID,
          stored.sessionBoundarySHA256 == sessionBoundarySHA256,
          stored.settlementSHA256 == settlementSHA256
        else {
          throw PiRunStoreError.divergentResult
        }
        return current
      }
      guard
        [.enqueued, .running, .resultPrepared, .failed, .interruptedUnknown].contains(
          launch.state
        ),
        try Self.loadResult(runID, database: database) == nil
      else {
        throw PiRunStoreError.invalidTransition
      }
      _ = try database.execute(
        """
        INSERT INTO pi_run_results(
          run_id, launch_attempt_id, envelope, result_sha256,
          session_id, session_boundary_sha256, settlement_sha256, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text(runID),
          .text(launchAttemptID),
          .blob(resultEnvelope),
          .text(resultSHA256),
          .text(sessionID),
          .text(sessionBoundarySHA256),
          .text(settlementSHA256),
          .real(now.timeIntervalSince1970),
        ]
      )
      try Self.appendEvent(
        runID: runID,
        launchAttemptID: launchAttemptID,
        kind: .resultPrepared,
        recordSHA256: resultSHA256,
        detailCode: nil,
        now: now,
        database: database
      )
      try Self.appendEvent(
        runID: runID,
        launchAttemptID: launchAttemptID,
        kind: .settled,
        recordSHA256: settlementSHA256,
        detailCode: nil,
        now: now,
        database: database
      )
      return try Self.requireRun(runID, database: database)
    }
  }

  public func result(runID: String) async throws -> PiRunResultRecord? {
    try await database.query(
      "SELECT * FROM pi_run_results WHERE run_id = ?",
      bindings: [.text(runID)]
    ).first.map(Self.decodeResult)
  }

  public func recordAcknowledgement(
    runID: String,
    launchAttemptID: String,
    resultSHA256: String,
    now: Date
  ) async throws {
    try await appendExternalSignal(
      runID: runID,
      launchAttemptID: launchAttemptID,
      resultSHA256: resultSHA256,
      event: .acknowledged,
      released: false,
      now: now
    )
  }

  public func recordRelease(
    runID: String,
    launchAttemptID: String,
    resultSHA256: String,
    now: Date
  ) async throws {
    try await appendExternalSignal(
      runID: runID,
      launchAttemptID: launchAttemptID,
      resultSHA256: resultSHA256,
      event: .released,
      released: true,
      now: now
    )
  }

  public func launches(runID: String) async throws -> [PiRunLaunchRecord] {
    try await database.query(
      "SELECT * FROM pi_run_launches WHERE run_id = ? ORDER BY queue_sequence, launch_attempt_id",
      bindings: [.text(runID)]
    ).map(Self.decodeLaunch)
  }

  public func events(runID: String) async throws -> [PiRunEventRecord] {
    try await database.query(
      "SELECT * FROM pi_run_events WHERE run_id = ? ORDER BY sequence",
      bindings: [.text(runID)]
    ).map(Self.decodeEvent)
  }

  public func activeRuns() async throws -> [PiRunRecord] {
    try await database.query(
      """
      SELECT * FROM pi_runs
      WHERE runtime_kind = 'herdr' AND outcome IN ('prepared', 'running', 'settled')
      ORDER BY created_at, id
      """
    ).map(Self.decodeRun)
  }

  private func appendExternalSignal(
    runID: String,
    launchAttemptID: String,
    resultSHA256: String,
    event: PiRunEventKind,
    released: Bool,
    now: Date
  ) async throws {
    guard Self.isSHA256(resultSHA256), event == .acknowledged || event == .released,
      released == (event == .released)
    else {
      throw PiRunStoreError.invalidRecord
    }
    try await database.transaction { database in
      let run = try Self.requireRun(runID, database: database)
      let launch = try Self.requireLaunch(launchAttemptID, database: database)
      guard run.settled, run.structuredResultDigest == resultSHA256,
        launch.runID == runID, [.settled, .released].contains(launch.state)
      else {
        throw PiRunStoreError.invalidTransition
      }
      let acknowledged = try Self.hasEvent(
        runID: runID,
        launchAttemptID: launchAttemptID,
        kind: .acknowledged,
        recordSHA256: resultSHA256,
        database: database
      )
      if released {
        guard acknowledged else { throw PiRunStoreError.invalidTransition }
      }
      if try Self.hasEvent(
        runID: runID,
        launchAttemptID: launchAttemptID,
        kind: event,
        recordSHA256: resultSHA256,
        database: database
      ) {
        if released {
          guard launch.state == .released, run.outcome == .released else {
            throw PiRunStoreError.invalidTransition
          }
        }
        return
      }
      try Self.appendEvent(
        runID: runID,
        launchAttemptID: launchAttemptID,
        kind: event,
        recordSHA256: resultSHA256,
        detailCode: nil,
        now: now,
        database: database
      )
      if released {
        let releasedRun = try Self.requireRun(runID, database: database)
        let releasedLaunch = try Self.requireLaunch(launchAttemptID, database: database)
        guard releasedRun.outcome == .released, releasedLaunch.state == .released else {
          throw PiRunStoreError.invalidTransition
        }
      }
    }
  }

  private static func appendEvent(
    runID: String,
    launchAttemptID: String?,
    kind: PiRunEventKind,
    recordSHA256: String?,
    detailCode: String?,
    now: Date,
    database: isolated SQLiteStore
  ) throws {
    let sequence = Int(
      try database.scalarInt(
        "SELECT COALESCE(MAX(sequence), 0) + 1 FROM pi_run_events WHERE run_id = ?",
        bindings: [.text(runID)]
      ) ?? 1
    )
    _ = try database.execute(
      """
      INSERT INTO pi_run_events(
        run_id, launch_attempt_id, sequence, kind, record_sha256, detail_code, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(runID),
        launchAttemptID.map(SQLiteValue.text) ?? .null,
        .integer(Int64(sequence)),
        .text(kind.rawValue),
        recordSHA256.map(SQLiteValue.text) ?? .null,
        detailCode.map(SQLiteValue.text) ?? .null,
        .real(now.timeIntervalSince1970),
      ]
    )
  }

  private static func hasEvent(
    runID: String,
    launchAttemptID: String,
    kind: PiRunEventKind,
    recordSHA256: String,
    database: isolated SQLiteStore
  ) throws -> Bool {
    try database.scalarInt(
      """
      SELECT COUNT(*) FROM pi_run_events
      WHERE run_id = ? AND launch_attempt_id = ? AND kind = ? AND record_sha256 = ?
      """,
      bindings: [
        .text(runID), .text(launchAttemptID), .text(kind.rawValue), .text(recordSHA256),
      ]
    ) == 1
  }

  private static func mayTransition(
    from: PiRunLaunchState,
    to: PiRunLaunchState,
    event: PiRunEventKind
  ) -> Bool {
    switch (from, to, event) {
    case (.prepared, .enqueued, .enqueued),
      (.enqueued, .running, .running),
      (.running, .running, .rebound),
      (.enqueued, .running, .rebound),
      (.running, .resultPrepared, .resultPrepared),
      (.enqueued, .resultPrepared, .resultPrepared),
      (.prepared, .interruptedUnknown, .interruptedUnknown),
      (.enqueued, .interruptedUnknown, .interruptedUnknown),
      (.running, .interruptedUnknown, .interruptedUnknown),
      (.prepared, .failed, .failed),
      (.enqueued, .failed, .failed),
      (.running, .failed, .failed):
      true
    default:
      false
    }
  }

  private static func validLaunchMode(
    _ mode: PiRunLaunchMode,
    expectedSessionID: String?,
    resumeBoundarySHA256: String?
  ) -> Bool {
    switch mode {
    case .fresh:
      expectedSessionID == nil && resumeBoundarySHA256 == nil
    case .sameRunResume:
      expectedSessionID.map(validSessionID) == true
        && (resumeBoundarySHA256 == nil || resumeBoundarySHA256.map(isSHA256) == true)
    case .crossRunResume:
      expectedSessionID.map(validSessionID) == true
        && resumeBoundarySHA256.map(isSHA256) == true
    }
  }

  private static func requireLaunchEligibility(
    database: isolated SQLiteStore,
    jobID: UUID
  ) throws {
    guard
      let row = try database.query(
        "SELECT repository_id FROM jobs WHERE id = ?",
        bindings: [.text(uuid(jobID))]
      ).first,
      case .text(let repositoryID)? = row["repository_id"],
      try pausedCanaryLaunchAuthorized(
        database: database,
        jobID: uuid(jobID),
        repositoryID: repositoryID
      )
    else {
      throw PiRunStoreError.launchSuppressed
    }
  }

  private static func loadRepositoryBinding(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> HerdrRepositoryBindingRecord? {
    try database.query(
      "SELECT * FROM herdr_repository_bindings WHERE repository_id = ?",
      bindings: [.text(uuid(id))]
    ).first.map(decodeRepositoryBinding)
  }

  private static func requireRepositoryBinding(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> HerdrRepositoryBindingRecord {
    guard let value = try loadRepositoryBinding(id, database: database) else {
      throw PiRunStoreError.bindingCollision
    }
    return value
  }

  private static func loadJobBinding(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> HerdrJobBindingRecord? {
    try database.query(
      "SELECT * FROM herdr_job_bindings WHERE job_id = ?",
      bindings: [.text(uuid(id))]
    ).first.map(decodeJobBinding)
  }

  private static func requireJobBinding(
    _ id: UUID,
    database: isolated SQLiteStore
  ) throws -> HerdrJobBindingRecord {
    guard let value = try loadJobBinding(id, database: database) else {
      throw PiRunStoreError.bindingCollision
    }
    return value
  }

  private static func loadRoleHost(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> HerdrRoleHostRecord? {
    try database.query(
      "SELECT * FROM herdr_role_hosts WHERE id = ?",
      bindings: [.text(id)]
    ).first.map(decodeRoleHost)
  }

  private static func requireRoleHost(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> HerdrRoleHostRecord {
    guard let value = try loadRoleHost(id, database: database) else {
      throw PiRunStoreError.roleHostNotFound(id)
    }
    return value
  }

  private static func loadReplacementRoleHost(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> HerdrReplacementRoleHostRecord? {
    try database.query(
      "SELECT * FROM herdr_replacement_role_hosts WHERE id = ?",
      bindings: [.text(id)]
    ).first.map(decodeReplacementRoleHost)
  }

  private static func replacementRoleHostIDCollision(
    id: String,
    database: isolated SQLiteStore
  ) throws -> Bool {
    guard try replacementRoleHostTableExists(database: database) else { return false }
    return try database.scalarInt(
      "SELECT COUNT(*) FROM herdr_replacement_role_hosts WHERE id = ?",
      bindings: [.text(id)]
    ) != 0
  }

  private static func replacementRoleHostPhysicalCollision(
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity,
    database: isolated SQLiteStore
  ) throws -> Bool {
    guard try replacementRoleHostTableExists(database: database) else { return false }
    return try database.scalarInt(
      """
      SELECT COUNT(*) FROM herdr_replacement_role_hosts
      WHERE pane_id = ? OR terminal_id = ?
        OR (host_pid = ? AND host_start_seconds = ? AND host_start_microseconds = ?)
      """,
      bindings: [
        .text(paneID),
        .text(terminalID),
        .integer(Int64(processIdentity.processID)),
        .integer(try int64(processIdentity.startSeconds)),
        .integer(try int64(processIdentity.startMicroseconds)),
      ]
    ) != 0
  }

  private static func replacementRoleHostTableExists(
    database: isolated SQLiteStore
  ) throws -> Bool {
    try database.scalarInt(
      """
      SELECT COUNT(*) FROM sqlite_master
      WHERE type = 'table' AND name = 'herdr_replacement_role_hosts'
      """
    ) == 1
  }

  private static func ordinaryRoleHostCollision(
    id: String,
    paneID: String,
    terminalID: String,
    processIdentity: HerdrHostProcessIdentity,
    database: isolated SQLiteStore
  ) throws -> Bool {
    try database.scalarInt(
      """
      SELECT COUNT(*) FROM herdr_role_hosts
      WHERE id = ? OR pane_id = ? OR terminal_id = ?
        OR (host_pid = ? AND host_start_seconds = ? AND host_start_microseconds = ?)
      """,
      bindings: [
        .text(id),
        .text(paneID),
        .text(terminalID),
        .integer(Int64(processIdentity.processID)),
        .integer(try int64(processIdentity.startSeconds)),
        .integer(try int64(processIdentity.startMicroseconds)),
      ]
    ) != 0
  }

  private static func requireReplacementRoleHost(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> HerdrReplacementRoleHostRecord {
    guard let value = try loadReplacementRoleHost(id, database: database) else {
      throw PiRunStoreError.roleHostNotFound(id)
    }
    return value
  }

  private static func jobRepositoryID(
    _ jobID: UUID,
    database: isolated SQLiteStore
  ) throws -> String {
    guard
      let value = try database.scalarText(
        "SELECT repository_id FROM jobs WHERE id = ?",
        bindings: [.text(uuid(jobID))]
      )
    else { throw PiRunStoreError.invalidTransition }
    return value
  }

  private static func launchAttemptID(
    runID: String,
    sequence: Int,
    database: isolated SQLiteStore
  ) throws -> String {
    guard
      let value = try database.scalarText(
        "SELECT launch_attempt_id FROM pi_run_launches WHERE run_id = ? AND queue_sequence = ?",
        bindings: [.text(runID), .integer(Int64(sequence))]
      )
    else { throw PiRunStoreError.invalidTransition }
    return value
  }

  private static func loadRun(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> PiRunRecord? {
    try database.query(
      "SELECT * FROM pi_runs WHERE id = ? AND runtime_kind = 'herdr'",
      bindings: [.text(id)]
    ).first.map(decodeRun)
  }

  private static func requireRun(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> PiRunRecord {
    guard let value = try loadRun(id, database: database) else {
      throw PiRunStoreError.runNotFound(id)
    }
    return value
  }

  private static func loadSessionOrigin(
    _ runID: String,
    database: isolated SQLiteStore
  ) throws -> PiRunSessionOriginRecord? {
    try database.query(
      "SELECT * FROM pi_run_session_origins WHERE run_id = ?",
      bindings: [.text(runID)]
    ).first.map(decodeSessionOrigin)
  }

  private static func requireSessionOrigin(
    _ runID: String,
    database: isolated SQLiteStore
  ) throws -> PiRunSessionOriginRecord {
    guard let value = try loadSessionOrigin(runID, database: database) else {
      throw PiRunStoreError.invalidTransition
    }
    return value
  }

  private static func loadResult(
    _ runID: String,
    database: isolated SQLiteStore
  ) throws -> PiRunResultRecord? {
    try database.query(
      "SELECT * FROM pi_run_results WHERE run_id = ?",
      bindings: [.text(runID)]
    ).first.map(decodeResult)
  }

  private static func loadLaunch(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> PiRunLaunchRecord? {
    try database.query(
      "SELECT * FROM pi_run_launches WHERE launch_attempt_id = ?",
      bindings: [.text(id)]
    ).first.map(decodeLaunch)
  }

  private static func requireLaunch(
    _ id: String,
    database: isolated SQLiteStore
  ) throws -> PiRunLaunchRecord {
    guard let value = try loadLaunch(id, database: database) else {
      throw PiRunStoreError.launchNotFound(id)
    }
    return value
  }

  private static func decodeRepositoryBinding(
    _ row: SQLiteRow
  ) throws -> HerdrRepositoryBindingRecord {
    guard let repositoryID = UUID(uuidString: try text(row, "repository_id")),
      let state = HerdrBindingState(rawValue: try text(row, "state")),
      [.active, .lost].contains(state)
    else {
      throw PiRunStoreError.decode("repository_id")
    }
    return HerdrRepositoryBindingRecord(
      repositoryID: repositoryID,
      workspaceID: try text(row, "workspace_id"),
      identityRoot: try text(row, "identity_root"),
      herdrVersion: try text(row, "herdr_version"),
      herdrProtocol: Int(try integer(row, "herdr_protocol")),
      socketIdentity: HerdrSocketIdentity(
        device: try uint64(row, "socket_device"),
        inode: try uint64(row, "socket_inode"),
        owner: UInt32(try integer(row, "socket_owner")),
        permissions: UInt16(try integer(row, "socket_permissions"))
      ),
      state: state,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  private static func decodeJobBinding(_ row: SQLiteRow) throws -> HerdrJobBindingRecord {
    guard let jobID = UUID(uuidString: try text(row, "job_id")),
      let repositoryID = UUID(uuidString: try text(row, "repository_id")),
      let state = HerdrBindingState(rawValue: try text(row, "state"))
    else {
      throw PiRunStoreError.decode("job binding")
    }
    return HerdrJobBindingRecord(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: Int(try integer(row, "generation")),
      workspaceID: try text(row, "workspace_id"),
      tabID: try optionalText(row, "tab_id"),
      state: state,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  static func decodeRoleHost(_ row: SQLiteRow) throws -> HerdrRoleHostRecord {
    guard let jobID = UUID(uuidString: try text(row, "job_id")),
      let role = PiWorkflowRole(rawValue: try text(row, "role")),
      let state = HerdrRoleHostState(rawValue: try text(row, "state"))
    else {
      throw PiRunStoreError.decode("role host")
    }
    let processID = try optionalInteger(row, "host_pid")
    let startSeconds = try optionalInteger(row, "host_start_seconds")
    let startMicroseconds = try optionalInteger(row, "host_start_microseconds")
    let identity: HerdrHostProcessIdentity?
    if let processID, let startSeconds, let startMicroseconds {
      identity = try HerdrHostProcessIdentity(
        processID: Int32(processID),
        startSeconds: UInt64(startSeconds),
        startMicroseconds: UInt64(startMicroseconds)
      )
    } else if processID == nil, startSeconds == nil, startMicroseconds == nil {
      identity = nil
    } else {
      throw PiRunStoreError.decode("partial process identity")
    }
    return HerdrRoleHostRecord(
      id: try text(row, "id"),
      jobID: jobID,
      generation: Int(try integer(row, "generation")),
      role: role,
      workspaceID: try text(row, "workspace_id"),
      tabID: try optionalText(row, "tab_id"),
      paneID: try optionalText(row, "pane_id"),
      terminalID: try optionalText(row, "terminal_id"),
      bootstrapDescriptorSHA256: try text(row, "bootstrap_descriptor_sha256"),
      hostExecutableSHA256: try text(row, "host_executable_sha256"),
      processIdentity: identity,
      lastQueueSequence: Int(try integer(row, "last_queue_sequence")),
      lifecycleSequence: Int(try integer(row, "lifecycle_sequence")),
      state: state,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  static func decodeReplacementRoleHost(
    _ row: SQLiteRow
  ) throws -> HerdrReplacementRoleHostRecord {
    guard let jobID = UUID(uuidString: try text(row, "job_id")),
      let role = PiWorkflowRole(rawValue: try text(row, "role")),
      role == .architecture,
      let state = HerdrRoleHostState(rawValue: try text(row, "state")),
      state != .prepared,
      let processID = Int32(exactly: try integer(row, "host_pid")),
      let startSeconds = UInt64(exactly: try integer(row, "host_start_seconds")),
      let startMicroseconds = UInt64(exactly: try integer(row, "host_start_microseconds"))
    else { throw PiRunStoreError.decode("replacement role host") }
    return HerdrReplacementRoleHostRecord(
      id: try text(row, "id"),
      predecessorRoleHostID: try text(row, "predecessor_role_host_id"),
      replacementIntentID: try text(row, "replacement_intent_id"),
      jobID: jobID,
      generation: Int(try integer(row, "generation")),
      role: role,
      workspaceID: try text(row, "workspace_id"),
      tabID: try text(row, "tab_id"),
      paneID: try text(row, "pane_id"),
      terminalID: try text(row, "terminal_id"),
      bootstrapDescriptorSHA256: try text(row, "bootstrap_descriptor_sha256"),
      hostExecutableSHA256: try text(row, "host_executable_sha256"),
      q4Binding: JobCanaryRoleHostReplacementQ4Binding(
        descriptorSHA256: try text(row, "q4_descriptor_sha256"),
        configurationSHA256: try text(row, "q4_configuration_sha256"),
        promptSHA256: try text(row, "q4_prompt_sha256"),
        workflowConfigurationSHA256: try text(
          row,
          "q4_workflow_configuration_sha256"
        ),
        priorLaunchDescriptorSHA256: try text(
          row,
          "q4_prior_launch_descriptor_sha256"
        ),
        priorLaunchConfigurationSHA256: try text(
          row,
          "q4_prior_launch_configuration_sha256"
        ),
        resourceTreeSHA256: try text(row, "q4_resource_tree_sha256")
      ),
      processIdentity: try HerdrHostProcessIdentity(
        processID: processID,
        startSeconds: startSeconds,
        startMicroseconds: startMicroseconds
      ),
      lastQueueSequence: Int(try integer(row, "last_queue_sequence")),
      lifecycleSequence: Int(try integer(row, "lifecycle_sequence")),
      state: state,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  static func decodeRun(_ row: SQLiteRow) throws -> PiRunRecord {
    guard try text(row, "runtime_kind") == "herdr",
      let jobID = UUID(uuidString: try text(row, "job_id")),
      let workflow = PiWorkflowKind(rawValue: try text(row, "workflow")),
      let role = PiWorkflowRole(rawValue: try text(row, "role")),
      let outcome = PiRunOutcome(rawValue: try text(row, "outcome"))
    else {
      throw PiRunStoreError.decode("pi run")
    }
    return PiRunRecord(
      id: try text(row, "id"),
      jobID: jobID,
      workflow: workflow,
      role: role,
      round: Int(try integer(row, "round")),
      jobAttempt: Int(try integer(row, "job_attempt")),
      topologyGeneration: Int(try integer(row, "topology_generation")),
      jobStep: Int(try integer(row, "job_step")),
      resumesRunID: try optionalText(row, "resumes_run_id"),
      runNonce: try text(row, "run_nonce"),
      requestSHA256: try text(row, "request_sha256"),
      resourceVersion: try text(row, "resource_version"),
      resourceHash: try text(row, "resource_hash"),
      model: try text(row, "model"),
      sessionPath: try text(row, "session_path"),
      sessionID: try optionalText(row, "session_id"),
      sessionBoundarySHA256: try optionalText(row, "session_boundary_sha256"),
      channelPath: try text(row, "channel_path"),
      accepted: try bool(row, "accepted"),
      settled: try bool(row, "settled"),
      structuredResultDigest: try optionalText(row, "structured_result_digest"),
      outcome: outcome,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  static func decodeLaunch(_ row: SQLiteRow) throws -> PiRunLaunchRecord {
    guard let mode = PiRunLaunchMode(rawValue: try text(row, "launch_mode")),
      let state = PiRunLaunchState(rawValue: try text(row, "state"))
    else {
      throw PiRunStoreError.decode("launch")
    }
    let childPID = try optionalInteger(row, "child_pid")
    let childGroup = try optionalInteger(row, "child_process_group_id")
    let childSeconds = try optionalInteger(row, "child_start_seconds")
    let childMicroseconds = try optionalInteger(row, "child_start_microseconds")
    let childProcess: HerdrChildProcessRecord?
    if let childPID, let childGroup, let childSeconds, let childMicroseconds,
      let processID = Int32(exactly: childPID),
      let processGroupID = Int32(exactly: childGroup),
      let startSeconds = UInt64(exactly: childSeconds),
      let startMicroseconds = UInt64(exactly: childMicroseconds)
    {
      childProcess = HerdrChildProcessRecord(
        launchAttemptID: try text(row, "launch_attempt_id"),
        processID: processID,
        processGroupID: processGroupID,
        startSeconds: startSeconds,
        startMicroseconds: startMicroseconds
      )
    } else if childPID == nil, childGroup == nil, childSeconds == nil,
      childMicroseconds == nil
    {
      childProcess = nil
    } else {
      throw PiRunStoreError.decode("launch child process")
    }
    return PiRunLaunchRecord(
      launchAttemptID: try text(row, "launch_attempt_id"),
      runID: try text(row, "run_id"),
      roleHostID: try text(row, "role_host_id"),
      executionRoleHostID: try optionalText(row, "execution_role_host_id"),
      queueSequence: Int(try integer(row, "queue_sequence")),
      launchMode: mode,
      descriptorSHA256: try text(row, "descriptor_sha256"),
      expectedSessionID: try optionalText(row, "expected_session_id"),
      resumeBoundarySHA256: try optionalText(row, "resume_boundary_sha256"),
      state: state,
      failureCode: try optionalText(row, "failure_code"),
      childProcess: childProcess,
      createdAt: try date(row, "created_at"),
      updatedAt: try date(row, "updated_at")
    )
  }

  private static func decodeSessionOrigin(
    _ row: SQLiteRow
  ) throws -> PiRunSessionOriginRecord {
    let sessionID = try text(row, "session_id")
    let boundary = try optionalText(row, "origin_resume_boundary_sha256")
    guard validSessionID(sessionID), boundary.map(isSHA256) ?? true else {
      throw PiRunStoreError.decode("session origin")
    }
    return PiRunSessionOriginRecord(
      runID: try text(row, "run_id"),
      launchAttemptID: try text(row, "launch_attempt_id"),
      sessionID: sessionID,
      originResumeBoundarySHA256: boundary,
      createdAt: try date(row, "created_at")
    )
  }

  static func decodeResult(_ row: SQLiteRow) throws -> PiRunResultRecord {
    guard case .blob(let envelope)? = row["envelope"] else {
      throw PiRunStoreError.decode("result envelope")
    }
    let resultSHA256 = try text(row, "result_sha256")
    guard sha256(envelope) == resultSHA256 else {
      throw PiRunStoreError.divergentResult
    }
    return PiRunResultRecord(
      runID: try text(row, "run_id"),
      launchAttemptID: try text(row, "launch_attempt_id"),
      envelope: envelope,
      resultSHA256: resultSHA256,
      sessionID: try text(row, "session_id"),
      sessionBoundarySHA256: try text(row, "session_boundary_sha256"),
      settlementSHA256: try text(row, "settlement_sha256"),
      createdAt: try date(row, "created_at")
    )
  }

  private static func decodeEvent(_ row: SQLiteRow) throws -> PiRunEventRecord {
    guard let kind = PiRunEventKind(rawValue: try text(row, "kind")) else {
      throw PiRunStoreError.decode("event")
    }
    return PiRunEventRecord(
      runID: try text(row, "run_id"),
      launchAttemptID: try optionalText(row, "launch_attempt_id"),
      sequence: Int(try integer(row, "sequence")),
      kind: kind,
      recordSHA256: try optionalText(row, "record_sha256"),
      detailCode: try optionalText(row, "detail_code"),
      createdAt: try date(row, "created_at")
    )
  }

  private static func text(_ row: SQLiteRow, _ column: String) throws -> String {
    guard case .text(let value)? = row[column] else {
      throw PiRunStoreError.decode(column)
    }
    return value
  }

  private static func optionalText(_ row: SQLiteRow, _ column: String) throws -> String? {
    switch row[column] {
    case .text(let value): value
    case .null: nil
    default: throw PiRunStoreError.decode(column)
    }
  }

  private static func integer(_ row: SQLiteRow, _ column: String) throws -> Int64 {
    guard case .integer(let value)? = row[column] else {
      throw PiRunStoreError.decode(column)
    }
    return value
  }

  private static func optionalInteger(_ row: SQLiteRow, _ column: String) throws -> Int64? {
    switch row[column] {
    case .integer(let value): value
    case .null: nil
    default: throw PiRunStoreError.decode(column)
    }
  }

  private static func bool(_ row: SQLiteRow, _ column: String) throws -> Bool {
    let value = try integer(row, column)
    guard value == 0 || value == 1 else { throw PiRunStoreError.decode(column) }
    return value == 1
  }

  private static func date(_ row: SQLiteRow, _ column: String) throws -> Date {
    guard case .real(let value)? = row[column] else {
      throw PiRunStoreError.decode(column)
    }
    return Date(timeIntervalSince1970: value)
  }

  private static func uint64(_ row: SQLiteRow, _ column: String) throws -> UInt64 {
    let value = try integer(row, column)
    guard value >= 0 else { throw PiRunStoreError.decode(column) }
    return UInt64(value)
  }

  private static func int64(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw PiRunStoreError.invalidRecord }
    return Int64(value)
  }

  private static func uuid(_ value: UUID) -> String {
    value.uuidString.lowercased()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func settlementSHA256(
    runID: String,
    launchAttemptID: String,
    resultSHA256: String,
    sessionID: String,
    sessionBoundarySHA256: String
  ) throws -> String {
    let object: [String: Any] = [
      "launchAttemptID": launchAttemptID,
      "resultSHA256": resultSHA256,
      "runID": runID,
      "schemaVersion": 1,
      "sessionBoundarySHA256": sessionBoundarySHA256,
      "sessionID": sessionID,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PiRunStoreError.invalidRecord
    }
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return sha256(data)
  }

  private static func validRuntimeID(_ value: String) -> Bool {
    value.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil
  }

  private static func validSessionID(_ value: String) -> Bool {
    value.wholeMatch(
      of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    ) != nil
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validAbsolutePath(_ value: URL) -> Bool {
    value.isFileURL && value.path.hasPrefix("/")
      && value.standardizedFileURL.path == value.path
  }

  private static func validDetailCode(_ value: String) -> Bool {
    value.wholeMatch(of: /^[A-Z][A-Z0-9_]{2,63}$/) != nil
  }
}

actor SQLiteHerdrTopologyIntentStore: HerdrTopologyIntentStoring {
  private let database: SQLiteStore
  private let now: @Sendable () -> Date

  init(
    database: SQLiteStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.now = now
  }

  func prepare(
    _ intent: HerdrTopologyMutationIntent
  ) async throws -> HerdrTopologyMutationReceipt {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let digest = GitHubMarkerCodec.sha256(try encoder.encode(intent))
    let instant = now()
    try await database.transaction { database in
      guard
        try pausedCanaryLaunchAuthorized(
          database: database,
          jobID: intent.jobID,
          repositoryID: intent.repositoryID
        )
      else {
        throw PiRunStoreError.launchSuppressed
      }
      if let row = try database.query(
        "SELECT * FROM herdr_topology_intents WHERE id = ?",
        bindings: [.text(intent.mutationID)]
      ).first {
        guard case .text(digest)? = row["intent_sha256"],
          case .text(intent.payloadSHA256)? = row["payload_sha256"]
        else {
          throw PiRunStoreError.bindingCollision
        }
        return
      }
      _ = try database.execute(
        """
        INSERT INTO herdr_topology_intents(
          id, kind, repository_id, job_id, generation, intent_sha256, payload_sha256,
          socket_device, socket_inode, socket_owner, socket_permissions,
          state, attribution_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', NULL, ?, ?)
        """,
        bindings: [
          .text(intent.mutationID),
          .text(intent.kind.rawValue),
          .text(intent.repositoryID),
          .text(intent.jobID),
          .integer(Int64(intent.generation)),
          .text(digest),
          .text(intent.payloadSHA256),
          .integer(try Self.int64(intent.socketIdentity.device)),
          .integer(try Self.int64(intent.socketIdentity.inode)),
          .integer(Int64(intent.socketIdentity.owner)),
          .integer(Int64(intent.socketIdentity.permissions)),
          .real(instant.timeIntervalSince1970),
          .real(instant.timeIntervalSince1970),
        ]
      )
    }
    return HerdrTopologyMutationReceipt(
      mutationID: intent.mutationID,
      intentSHA256: digest
    )
  }

  func markSendStarted(_ receipt: HerdrTopologyMutationReceipt) async throws {
    try await transition(
      receipt,
      from: "prepared",
      to: "sendStarted",
      attribution: nil,
      failureCode: nil
    )
  }

  func attribute(
    _ receipt: HerdrTopologyMutationReceipt,
    as attribution: HerdrTopologyMutationAttribution
  ) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(attribution)
    guard let value = String(data: data, encoding: .utf8) else {
      throw PiRunStoreError.invalidRecord
    }
    try await transition(
      receipt,
      from: "sendStarted",
      to: "attributed",
      attribution: value,
      failureCode: nil
    )
  }

  func markUnknown(_ receipt: HerdrTopologyMutationReceipt) async throws {
    try await transition(
      receipt,
      from: "sendStarted",
      to: "unknown",
      attribution: nil,
      failureCode: nil
    )
  }

  func markFailedNoRemoteEffect(
    _ receipt: HerdrTopologyMutationReceipt,
    failureCode: String
  ) async throws {
    guard JobCanaryRoleHostReplacementOutcome.validFailureCode(failureCode) else {
      throw PiRunStoreError.invalidRecord
    }
    try await transition(
      receipt,
      from: "prepared",
      to: "failedNoRemoteEffect",
      attribution: nil,
      failureCode: failureCode
    )
  }

  func markSentAgentPrimesUnknown() async throws {
    let instant = now().timeIntervalSince1970
    guard instant.isFinite else { throw PiRunStoreError.invalidTransition }
    _ = try await database.execute(
      """
      UPDATE herdr_topology_intents
      SET state = 'unknown', attribution_json = NULL, updated_at = ?
      WHERE kind IN ('primeAgentAuthority', 'resetAgentAuthority', 'replaceRoleHost')
        AND state = 'sendStarted' AND attribution_json IS NULL
      """,
      bindings: [.real(instant)]
    )
  }

  func storedIntent(
    kind: HerdrTopologyMutationIntent.Kind,
    repositoryID: String,
    jobID: String,
    generation: Int,
    payloadSHA256: String,
    socketIdentity: HerdrSocketIdentityRecord
  ) async throws -> HerdrTopologyStoredIntent? {
    guard generation > 0,
      payloadSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    else {
      throw PiRunStoreError.invalidRecord
    }
    let rows = try await database.query(
      """
      SELECT *
      FROM herdr_topology_intents
      WHERE kind = ? AND repository_id = ? AND job_id = ? AND generation = ?
        AND payload_sha256 = ? AND socket_device = ? AND socket_inode = ?
        AND socket_owner = ? AND socket_permissions = ?
      ORDER BY created_at, id
      """,
      bindings: [
        .text(kind.rawValue),
        .text(repositoryID),
        .text(jobID),
        .integer(Int64(generation)),
        .text(payloadSHA256),
        .integer(try Self.int64(socketIdentity.device)),
        .integer(try Self.int64(socketIdentity.inode)),
        .integer(Int64(socketIdentity.owner)),
        .integer(Int64(socketIdentity.permissions)),
      ]
    )
    guard rows.count <= 1, let row = rows.first else {
      if rows.isEmpty { return nil }
      throw PiRunStoreError.bindingCollision
    }
    guard case .text(let id)? = row["id"],
      case .text(let digest)? = row["intent_sha256"],
      case .text(let stateValue)? = row["state"],
      let state = HerdrTopologyStoredIntentState(rawValue: stateValue)
    else {
      throw PiRunStoreError.invalidRecord
    }
    let attribution: HerdrTopologyMutationAttribution?
    switch row["attribution_json"] {
    case .null:
      attribution = nil
    case .text(let value):
      guard let data = value.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(
          HerdrTopologyMutationAttribution.self,
          from: data
        )
      else {
        throw PiRunStoreError.invalidRecord
      }
      attribution = decoded
    default:
      throw PiRunStoreError.invalidRecord
    }
    let failureCode: String?
    switch row["failure_code"] {
    case .null?, nil:
      failureCode = nil
    case .text(let value) where JobCanaryRoleHostReplacementOutcome.validFailureCode(value):
      failureCode = value
    default:
      throw PiRunStoreError.invalidRecord
    }
    guard (state == .attributed) == (attribution != nil), failureCode == nil else {
      throw PiRunStoreError.invalidRecord
    }
    return HerdrTopologyStoredIntent(
      receipt: HerdrTopologyMutationReceipt(mutationID: id, intentSHA256: digest),
      state: state,
      attribution: attribution,
      failureCode: failureCode
    )
  }

  private func transition(
    _ receipt: HerdrTopologyMutationReceipt,
    from: String,
    to: String,
    attribution: String?,
    failureCode: String?
  ) async throws {
    let instant = now().timeIntervalSince1970
    guard instant.isFinite else { throw PiRunStoreError.invalidTransition }
    try await database.transaction { database in
      guard
        let row = try database.query(
          """
          SELECT * FROM herdr_topology_intents WHERE id = ?
          """,
          bindings: [.text(receipt.mutationID)]
        ).first,
        case .text(let state)? = row["state"],
        case .text(receipt.intentSHA256)? = row["intent_sha256"],
        case .text(let jobID)? = row["job_id"],
        case .text(let repositoryID)? = row["repository_id"],
        case .real(let priorInstant)? = row["updated_at"],
        priorInstant.isFinite
      else {
        throw PiRunStoreError.bindingCollision
      }
      if state == to {
        let existing: String? =
          switch row["attribution_json"] {
          case .text(let value): value
          case .null: nil
          default: throw PiRunStoreError.invalidRecord
          }
        let existingFailureCode: String? =
          switch row["failure_code"] {
          case .text(let value)?: value
          case .null?, nil: nil
          default: throw PiRunStoreError.invalidRecord
          }
        guard existing == attribution, existingFailureCode == failureCode else {
          throw PiRunStoreError.bindingCollision
        }
        return
      }
      guard instant >= priorInstant else { throw PiRunStoreError.invalidTransition }
      if from == "prepared", to == "sendStarted",
        !(try pausedCanaryLaunchAuthorized(
          database: database,
          jobID: jobID,
          repositoryID: repositoryID
        ))
      {
        throw PiRunStoreError.launchSuppressed
      }
      guard state == from else { throw PiRunStoreError.invalidTransition }
      let updatedRows: Int
      if failureCode != nil {
        updatedRows = try database.execute(
          """
          UPDATE herdr_topology_intents
          SET state = ?, attribution_json = ?, failure_code = ?, updated_at = ?
          WHERE id = ? AND state = ? AND updated_at = ?
          """,
          bindings: [
            .text(to),
            attribution.map(SQLiteValue.text) ?? .null,
            failureCode.map(SQLiteValue.text) ?? .null,
            .real(instant),
            .text(receipt.mutationID),
            .text(from),
            .real(priorInstant),
          ]
        )
      } else {
        updatedRows = try database.execute(
          """
          UPDATE herdr_topology_intents
          SET state = ?, attribution_json = ?, updated_at = ?
          WHERE id = ? AND state = ? AND updated_at = ?
          """,
          bindings: [
            .text(to),
            attribution.map(SQLiteValue.text) ?? .null,
            .real(instant),
            .text(receipt.mutationID),
            .text(from),
            .real(priorInstant),
          ]
        )
      }
      guard updatedRows == 1 else { throw PiRunStoreError.invalidTransition }
    }
  }

  private static func int64(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw PiRunStoreError.invalidRecord }
    return Int64(value)
  }
}

private func pausedCanaryLaunchAuthorized(
  database: isolated SQLiteStore,
  jobID: String,
  repositoryID: String
) throws -> Bool {
  let paused = try database.scalarInt(
    "SELECT paused FROM app_settings WHERE singleton = 1"
  )
  if paused == 0 { return true }
  guard paused == 1, let id = UUID(uuidString: jobID), id.uuidString.lowercased() == jobID,
    let repository = UUID(uuidString: repositoryID),
    repository.uuidString.lowercased() == repositoryID
  else { return false }
  let active: ActiveJobCanary
  do {
    guard let value = try DurableJobStore.activeCanary(database: database) else { return false }
    active = value
  } catch {
    return false
  }
  guard active.jobID == id else { return false }
  let prefix = "canary:\(active.authorizationSHA256):m\(active.maximumCommentParts):pi:"
  return try database.scalarInt(
    """
    SELECT COUNT(*) FROM jobs
    WHERE id = ? AND repository_id = ? AND kind = 'prReview' AND state = 'runningPi'
    """,
    bindings: [.text(jobID), .text(repositoryID)]
  ) == 1
    && database.scalarInt(
      """
      SELECT COUNT(*) FROM repository_leases
      WHERE repository_id = ? AND job_id = ? AND active = 1
      """,
      bindings: [.text(repositoryID), .text(jobID)]
    ) == 1
    && database.scalarInt(
      "SELECT COUNT(*) FROM job_transitions WHERE job_id = ? AND event_key GLOB ?",
      bindings: [.text(jobID), .text(prefix + "*:r1")]
    ).map { (1...4).contains($0) } == true
}
