import Darwin
import Foundation

public enum WorkspaceCleanupState: String, Codable, Sendable {
  case retained
  case eligible
  case removed
}

public struct WorkspaceRecord: Equatable, Sendable {
  public let jobID: UUID
  public let relativePath: String
  public let baseBranch: String
  public let baseSHA: String
  public let localHeadSHA: String
  public let cleanupState: WorkspaceCleanupState
  public let updatedAt: Date
}

public struct RepositoryMaterialization: Equatable, Sendable {
  public let mirrorURL: URL
  public let workspaceURL: URL
  public let record: WorkspaceRecord
}

public struct PullRequestFetch: Equatable, Sendable {
  public let mirrorURL: URL
  public let headSHA: String
}

public enum RepositoryStoreError: Error, Equatable, Sendable {
  case unsafeRoot
  case invalidRepository
  case invalidJob
  case invalidBranch
  case invalidSHA
  case mirrorCollision
  case mirrorInvalid
  case workspaceCollision
  case workspaceInvalid
  case workspaceNotFound
  case cleanupNotAuthorized
  case unsafePath
  case gitFailure
  case decode(String)
}

public actor WorkspaceStateStore {
  private let database: SQLiteStore

  public init(database: SQLiteStore) {
    self.database = database
  }

  public func recordMaterialized(
    jobID: UUID,
    relativePath: String,
    baseBranch: String,
    baseSHA: String,
    localHeadSHA: String,
    now: Date
  ) async throws -> WorkspaceRecord {
    try Self.validate(
      jobID: jobID,
      relativePath: relativePath,
      baseBranch: baseBranch,
      baseSHA: baseSHA,
      localHeadSHA: localHeadSHA
    )
    return try await database.transaction { database in
      guard
        try database.scalarInt(
          "SELECT COUNT(*) FROM jobs WHERE id = ?",
          bindings: [.text(jobID.uuidString.lowercased())]
        ) == 1
      else {
        throw RepositoryStoreError.invalidJob
      }
      if let existing = try Self.load(jobID: jobID, database: database) {
        if existing.cleanupState == .removed {
          _ = try database.execute(
            """
            UPDATE workspaces
            SET relative_path = ?, base_branch = ?, base_sha = ?, local_head_sha = ?,
                cleanup_state = 'retained', updated_at = ?
            WHERE job_id = ? AND cleanup_state = 'removed'
            """,
            bindings: [
              .text(relativePath),
              .text(baseBranch),
              .text(baseSHA),
              .text(localHeadSHA),
              .real(now.timeIntervalSince1970),
              .text(jobID.uuidString.lowercased()),
            ]
          )
          return try Self.require(jobID: jobID, database: database)
        }
        guard existing.relativePath == relativePath,
          existing.baseBranch == baseBranch,
          existing.baseSHA == baseSHA,
          existing.localHeadSHA == localHeadSHA,
          existing.cleanupState == .retained
        else {
          throw RepositoryStoreError.workspaceCollision
        }
        return existing
      }
      _ = try database.execute(
        """
        INSERT INTO workspaces(
          job_id, relative_path, base_branch, base_sha,
          local_head_sha, cleanup_state, updated_at
        ) VALUES (?, ?, ?, ?, ?, 'retained', ?)
        """,
        bindings: [
          .text(jobID.uuidString.lowercased()),
          .text(relativePath),
          .text(baseBranch),
          .text(baseSHA),
          .text(localHeadSHA),
          .real(now.timeIntervalSince1970),
        ]
      )
      return try Self.require(jobID: jobID, database: database)
    }
  }

  public func updateHead(
    jobID: UUID,
    exactSHA: String,
    now: Date
  ) async throws -> WorkspaceRecord {
    guard GitHubInputValidation.validGitSHA(exactSHA) else {
      throw RepositoryStoreError.invalidSHA
    }
    return try await database.transaction { database in
      let current = try Self.require(jobID: jobID, database: database)
      guard current.cleanupState == .retained else {
        throw RepositoryStoreError.cleanupNotAuthorized
      }
      _ = try database.execute(
        "UPDATE workspaces SET local_head_sha = ?, updated_at = ? WHERE job_id = ?",
        bindings: [
          .text(exactSHA),
          .real(now.timeIntervalSince1970),
          .text(jobID.uuidString.lowercased()),
        ]
      )
      return try Self.require(jobID: jobID, database: database)
    }
  }

  public func authorizeCleanup(jobID: UUID, now: Date) async throws -> WorkspaceRecord {
    try await database.transaction { database in
      let current = try Self.require(jobID: jobID, database: database)
      if current.cleanupState == .eligible || current.cleanupState == .removed {
        return current
      }
      guard
        try database.scalarInt(
          """
          SELECT COUNT(*) FROM jobs
          WHERE id = ?
            AND state IN ('reconciling', 'succeeded', 'blocked', 'waitingHuman')
            AND EXISTS (
              SELECT 1 FROM job_steps
              WHERE job_steps.job_id = jobs.id
                AND job_steps.ordinal = jobs.current_step
                AND (
                  (jobs.kind = 'prReview' AND job_steps.kind = 'publish')
                  OR (jobs.kind = 'issueTriage' AND job_steps.kind = 'reconcile')
                  OR (
                    jobs.kind IN ('issueImplementation', 'complexPlan')
                    AND job_steps.kind IN ('publish', 'publishPlan', 'qa')
                  )
                )
            )
          """,
          bindings: [.text(jobID.uuidString.lowercased())]
        ) == 1
      else {
        throw RepositoryStoreError.cleanupNotAuthorized
      }
      _ = try database.execute(
        "UPDATE workspaces SET cleanup_state = 'eligible', updated_at = ? WHERE job_id = ?",
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(jobID.uuidString.lowercased()),
        ]
      )
      return try Self.require(jobID: jobID, database: database)
    }
  }

  public func markRemoved(jobID: UUID, now: Date) async throws -> WorkspaceRecord {
    try await database.transaction { database in
      let current = try Self.require(jobID: jobID, database: database)
      if current.cleanupState == .removed { return current }
      guard current.cleanupState == .eligible else {
        throw RepositoryStoreError.cleanupNotAuthorized
      }
      _ = try database.execute(
        "UPDATE workspaces SET cleanup_state = 'removed', updated_at = ? WHERE job_id = ?",
        bindings: [
          .real(now.timeIntervalSince1970),
          .text(jobID.uuidString.lowercased()),
        ]
      )
      return try Self.require(jobID: jobID, database: database)
    }
  }

  public func record(jobID: UUID) async throws -> WorkspaceRecord? {
    try await database.query(
      "SELECT * FROM workspaces WHERE job_id = ?",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).first.map(Self.decode)
  }

  public func records() async throws -> [WorkspaceRecord] {
    try await database.query(
      "SELECT * FROM workspaces ORDER BY job_id"
    ).map(Self.decode)
  }

  private static func validate(
    jobID: UUID,
    relativePath: String,
    baseBranch: String,
    baseSHA: String,
    localHeadSHA: String
  ) throws {
    guard relativePath == "\(jobID.uuidString.lowercased())/repo",
      GitHubInputValidation.validBranch(baseBranch),
      GitHubInputValidation.validGitSHA(baseSHA),
      GitHubInputValidation.validGitSHA(localHeadSHA)
    else {
      throw RepositoryStoreError.workspaceInvalid
    }
  }

  private static func require(
    jobID: UUID,
    database: isolated SQLiteStore
  ) throws -> WorkspaceRecord {
    guard let value = try load(jobID: jobID, database: database) else {
      throw RepositoryStoreError.workspaceNotFound
    }
    return value
  }

  private static func load(
    jobID: UUID,
    database: isolated SQLiteStore
  ) throws -> WorkspaceRecord? {
    try database.query(
      "SELECT * FROM workspaces WHERE job_id = ?",
      bindings: [.text(jobID.uuidString.lowercased())]
    ).first.map(decode)
  }

  private static func decode(_ row: SQLiteRow) throws -> WorkspaceRecord {
    guard case .text(let jobValue)? = row["job_id"],
      let jobID = UUID(uuidString: jobValue),
      case .text(let relativePath)? = row["relative_path"],
      case .text(let baseBranch)? = row["base_branch"],
      case .text(let baseSHA)? = row["base_sha"],
      case .text(let localHeadSHA)? = row["local_head_sha"],
      case .text(let cleanupValue)? = row["cleanup_state"],
      let cleanupState = WorkspaceCleanupState(rawValue: cleanupValue)
    else {
      throw RepositoryStoreError.decode("invalid workspace row")
    }
    let updatedAt: Double
    switch row["updated_at"] {
    case .real(let value): updatedAt = value
    case .integer(let value): updatedAt = Double(value)
    default: throw RepositoryStoreError.decode("invalid workspace timestamp")
    }
    return WorkspaceRecord(
      jobID: jobID,
      relativePath: relativePath,
      baseBranch: baseBranch,
      baseSHA: baseSHA,
      localHeadSHA: localHeadSHA,
      cleanupState: cleanupState,
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }
}

public actor RepositoryStore {
  public nonisolated let rootURL: URL
  public nonisolated let repositoriesURL: URL
  public nonisolated let workspacesURL: URL

  private let transport: any GitRepositoryTransporting & GitLocalCommanding
  private let workspaceStates: WorkspaceStateStore

  public init(
    rootURL: URL,
    database: SQLiteStore,
    transport: any GitRepositoryTransporting & GitLocalCommanding = SystemGitTransport()
  ) throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw RepositoryStoreError.unsafeRoot
    }
    try Self.ensurePrivateDirectory(rootURL)
    let repositoriesURL = rootURL.appendingPathComponent("Repositories", isDirectory: true)
    let workspacesURL = rootURL.appendingPathComponent("Workspaces", isDirectory: true)
    try Self.ensurePrivateDirectory(repositoriesURL)
    try Self.ensurePrivateDirectory(workspacesURL)
    self.rootURL = rootURL
    self.repositoriesURL = repositoriesURL
    self.workspacesURL = workspacesURL
    self.transport = transport
    workspaceStates = WorkspaceStateStore(database: database)
  }

  public func ensureMirror(
    remote: GitRemoteRepository,
    credentials: (any GitCredentialSessionProviding)? = nil
  ) async throws -> URL {
    try Self.validate(remote)
    let container = repositoriesURL.appendingPathComponent(
      remote.repositoryID.uuidString.lowercased(),
      isDirectory: true
    )
    try Self.ensurePrivateDirectory(container)
    let mirror = container.appendingPathComponent("mirror.git", isDirectory: true)
    try Self.validateContained(mirror, root: repositoriesURL)
    if FileManager.default.fileExists(atPath: mirror.path) {
      try await validateMirror(mirror, remote: remote)
      try await transport.fetchMirror(
        remote: remote,
        mirror: mirror,
        credentials: credentials
      )
      try await validateMirror(mirror, remote: remote)
      return mirror
    }

    let temporary = container.appendingPathComponent(
      "mirror.pending-\(UUID().uuidString.lowercased()).git",
      isDirectory: true
    )
    do {
      try await transport.cloneMirror(
        remote: remote,
        destination: temporary,
        credentials: credentials
      )
      try Self.ensurePrivateDirectory(temporary)
      try await validateMirror(temporary, remote: remote)
      try FileManager.default.moveItem(at: temporary, to: mirror)
      try Self.ensurePrivateDirectory(mirror)
      return mirror
    } catch {
      try? Self.removeExactTemporary(temporary, parent: container)
      throw error
    }
  }

  public func fetchPullRequest(
    number: Int,
    expectedSHA: String,
    jobID: UUID,
    remote: GitRemoteRepository,
    credentials: (any GitCredentialSessionProviding)? = nil
  ) async throws -> String {
    try await fetchPullRequestMaterialization(
      number: number,
      expectedSHA: expectedSHA,
      jobID: jobID,
      remote: remote,
      credentials: credentials
    ).headSHA
  }

  public func fetchPullRequestMaterialization(
    number: Int,
    expectedSHA: String,
    jobID: UUID,
    remote: GitRemoteRepository,
    credentials: (any GitCredentialSessionProviding)? = nil
  ) async throws -> PullRequestFetch {
    let mirror = try await ensureMirror(remote: remote, credentials: credentials)
    let head = try await transport.fetchPullRequest(
      number: number,
      expectedSHA: expectedSHA,
      jobID: jobID,
      remote: remote,
      mirror: mirror,
      credentials: credentials
    )
    return PullRequestFetch(mirrorURL: mirror, headSHA: head)
  }

  public func materializeReviewWorkspace(
    jobID: UUID,
    remote: GitRemoteRepository,
    baseSHA: String,
    headSHA: String,
    mirrorURL: URL? = nil,
    credentials: (any GitCredentialSessionProviding)? = nil,
    now: Date = Date()
  ) async throws -> RepositoryMaterialization {
    guard GitHubInputValidation.validGitSHA(baseSHA),
      GitHubInputValidation.validGitSHA(headSHA)
    else {
      throw RepositoryStoreError.invalidSHA
    }
    let mirror: URL
    if let supplied = mirrorURL?.standardizedFileURL {
      try Self.validateContained(supplied, root: repositoriesURL)
      try await validateMirror(supplied, remote: remote)
      mirror = supplied
    } else {
      mirror = try await ensureMirror(remote: remote, credentials: credentials)
    }
    let existing = try await workspaceStates.record(jobID: jobID)
    let relativePath = "\(jobID.uuidString.lowercased())/repo"
    let jobDirectory = workspacesURL.appendingPathComponent(
      jobID.uuidString.lowercased(),
      isDirectory: true
    )
    let workspace = jobDirectory.appendingPathComponent("repo", isDirectory: true)
    if let existing {
      guard existing.relativePath == relativePath,
        existing.baseBranch == remote.defaultBranch,
        existing.baseSHA == baseSHA,
        existing.localHeadSHA == headSHA,
        existing.cleanupState == .retained
      else {
        throw RepositoryStoreError.workspaceCollision
      }
      try await validateDetachedWorkspace(
        workspace,
        mirror: mirror,
        headSHA: headSHA
      )
      return RepositoryMaterialization(
        mirrorURL: mirror,
        workspaceURL: workspace,
        record: existing
      )
    }
    guard !FileManager.default.fileExists(atPath: jobDirectory.path) else {
      throw RepositoryStoreError.workspaceCollision
    }

    let temporaryJob = workspacesURL.appendingPathComponent(
      "\(jobID.uuidString.lowercased()).pending-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let temporaryWorkspace = temporaryJob.appendingPathComponent("repo", isDirectory: true)
    try Self.ensurePrivateDirectory(temporaryJob)
    var movedIntoPlace = false
    do {
      try await requireSuccess(
        transport.runLocalGit(
          arguments: [
            "clone", "--no-hardlinks", "--no-checkout", "--", mirror.path,
            temporaryWorkspace.path,
          ],
          workingDirectory: temporaryJob,
          timeoutSeconds: 300,
          maximumOutputBytes: 8 * 1_024 * 1_024,
          environmentOverrides: [:]
        ))
      try await requireSuccess(
        transport.runLocalGit(
          arguments: ["-C", temporaryWorkspace.path, "checkout", "--detach", headSHA],
          workingDirectory: temporaryWorkspace,
          timeoutSeconds: 120,
          maximumOutputBytes: 1_048_576,
          environmentOverrides: [:]
        ))
      try Self.ensurePrivateDirectory(temporaryWorkspace)
      try await validateDetachedWorkspace(
        temporaryWorkspace,
        mirror: mirror,
        headSHA: headSHA
      )
      try FileManager.default.moveItem(at: temporaryJob, to: jobDirectory)
      movedIntoPlace = true
      let record = try await workspaceStates.recordMaterialized(
        jobID: jobID,
        relativePath: relativePath,
        baseBranch: remote.defaultBranch,
        baseSHA: baseSHA,
        localHeadSHA: headSHA,
        now: now
      )
      return RepositoryMaterialization(
        mirrorURL: mirror,
        workspaceURL: workspace,
        record: record
      )
    } catch {
      if movedIntoPlace {
        try? Self.removeExactWorkspace(jobDirectory, jobID: jobID, parent: workspacesURL)
      } else {
        try? Self.removeExactTemporary(temporaryJob, parent: workspacesURL)
      }
      throw error
    }
  }

  public func materializeSnapshotWorkspace(
    jobID: UUID,
    remote: GitRemoteRepository,
    exactSHA: String,
    mirrorURL: URL? = nil,
    credentials: (any GitCredentialSessionProviding)? = nil,
    now: Date = Date()
  ) async throws -> RepositoryMaterialization {
    try await materializeReviewWorkspace(
      jobID: jobID,
      remote: remote,
      baseSHA: exactSHA,
      headSHA: exactSHA,
      mirrorURL: mirrorURL,
      credentials: credentials,
      now: now
    )
  }

  public func materializeWorkspace(
    jobID: UUID,
    remote: GitRemoteRepository,
    baseSHA: String,
    branch: String,
    credentials: (any GitCredentialSessionProviding)? = nil,
    now: Date = Date()
  ) async throws -> RepositoryMaterialization {
    guard GitHubInputValidation.validGitSHA(baseSHA) else {
      throw RepositoryStoreError.invalidSHA
    }
    guard GitBranchPolicy.validImplementationBranch(branch) else {
      throw RepositoryStoreError.invalidBranch
    }
    let mirror = try await ensureMirror(remote: remote, credentials: credentials)
    let existing = try await workspaceStates.record(jobID: jobID)
    let relativePath = "\(jobID.uuidString.lowercased())/repo"
    let jobDirectory = workspacesURL.appendingPathComponent(
      jobID.uuidString.lowercased(),
      isDirectory: true
    )
    let workspace = jobDirectory.appendingPathComponent("repo", isDirectory: true)
    if let existing, existing.cleanupState == .retained {
      guard existing.relativePath == relativePath,
        existing.baseBranch == remote.defaultBranch,
        existing.baseSHA == baseSHA
      else {
        throw RepositoryStoreError.workspaceCollision
      }
      try await validateWorkspace(
        workspace,
        mirror: mirror,
        branch: branch,
        headSHA: existing.localHeadSHA
      )
      return RepositoryMaterialization(
        mirrorURL: mirror,
        workspaceURL: workspace,
        record: existing
      )
    }
    if let existing, existing.cleanupState != .removed {
      throw RepositoryStoreError.workspaceCollision
    }
    guard !FileManager.default.fileExists(atPath: jobDirectory.path) else {
      throw RepositoryStoreError.workspaceCollision
    }

    let temporaryJob = workspacesURL.appendingPathComponent(
      "\(jobID.uuidString.lowercased()).pending-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let temporaryWorkspace = temporaryJob.appendingPathComponent("repo", isDirectory: true)
    try Self.ensurePrivateDirectory(temporaryJob)
    var movedIntoPlace = false
    do {
      try await requireSuccess(
        transport.runLocalGit(
          arguments: [
            "clone", "--no-hardlinks", "--no-checkout", "--", mirror.path, temporaryWorkspace.path,
          ],
          workingDirectory: temporaryJob,
          timeoutSeconds: 300,
          maximumOutputBytes: 8 * 1_024 * 1_024,
          environmentOverrides: [:]
        ))
      try await requireSuccess(
        transport.runLocalGit(
          arguments: ["-C", temporaryWorkspace.path, "checkout", "--detach", baseSHA],
          workingDirectory: temporaryWorkspace,
          timeoutSeconds: 120,
          maximumOutputBytes: 1_048_576,
          environmentOverrides: [:]
        ))
      try await requireSuccess(
        transport.runLocalGit(
          arguments: ["-C", temporaryWorkspace.path, "switch", "-c", branch],
          workingDirectory: temporaryWorkspace,
          timeoutSeconds: 120,
          maximumOutputBytes: 1_048_576,
          environmentOverrides: [:]
        ))
      for (key, value) in [
        ("user.name", "Jidoka Code"),
        ("user.email", "jidoka-code@invalid.example"),
        ("commit.gpgsign", "false"),
      ] {
        try await requireSuccess(
          transport.runLocalGit(
            arguments: ["-C", temporaryWorkspace.path, "config", "--local", key, value],
            workingDirectory: temporaryWorkspace,
            timeoutSeconds: 30,
            maximumOutputBytes: 1_048_576,
            environmentOverrides: [:]
          ))
      }
      try Self.ensurePrivateDirectory(temporaryWorkspace)
      try await validateWorkspace(
        temporaryWorkspace,
        mirror: mirror,
        branch: branch,
        headSHA: baseSHA
      )
      try FileManager.default.moveItem(at: temporaryJob, to: jobDirectory)
      movedIntoPlace = true
      let record = try await workspaceStates.recordMaterialized(
        jobID: jobID,
        relativePath: relativePath,
        baseBranch: remote.defaultBranch,
        baseSHA: baseSHA,
        localHeadSHA: baseSHA,
        now: now
      )
      return RepositoryMaterialization(
        mirrorURL: mirror,
        workspaceURL: workspace,
        record: record
      )
    } catch {
      if movedIntoPlace {
        try? Self.removeExactWorkspace(jobDirectory, jobID: jobID, parent: workspacesURL)
      } else {
        try? Self.removeExactTemporary(temporaryJob, parent: workspacesURL)
      }
      throw error
    }
  }

  public func refreshWorkspaceHead(jobID: UUID, now: Date = Date()) async throws
    -> WorkspaceRecord
  {
    guard let current = try await workspaceStates.record(jobID: jobID) else {
      throw RepositoryStoreError.workspaceNotFound
    }
    let workspace = try workspaceURL(record: current)
    let head = try await output(
      arguments: ["-C", workspace.path, "rev-parse", "--verify", "HEAD"],
      workingDirectory: workspace
    )
    guard GitHubInputValidation.validGitSHA(head) else {
      throw RepositoryStoreError.workspaceInvalid
    }
    return try await workspaceStates.updateHead(jobID: jobID, exactSHA: head, now: now)
  }

  public func authorizeCleanup(jobID: UUID, now: Date = Date()) async throws {
    _ = try await workspaceStates.authorizeCleanup(jobID: jobID, now: now)
  }

  public func cleanupWorkspace(jobID: UUID, now: Date = Date()) async throws {
    guard let record = try await workspaceStates.record(jobID: jobID) else {
      throw RepositoryStoreError.workspaceNotFound
    }
    guard record.cleanupState == .eligible || record.cleanupState == .removed else {
      throw RepositoryStoreError.cleanupNotAuthorized
    }
    let jobDirectory = workspacesURL.appendingPathComponent(
      jobID.uuidString.lowercased(),
      isDirectory: true
    )
    try Self.validateContained(jobDirectory, root: workspacesURL)
    if record.cleanupState == .removed {
      guard !FileManager.default.fileExists(atPath: jobDirectory.path) else {
        throw RepositoryStoreError.unsafePath
      }
      return
    }
    if FileManager.default.fileExists(atPath: jobDirectory.path) {
      let values = try jobDirectory.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RepositoryStoreError.unsafePath
      }
      try FileManager.default.removeItem(at: jobDirectory)
    }
    _ = try await workspaceStates.markRemoved(jobID: jobID, now: now)
  }

  public func orphanedWorkspaceDirectories() async throws -> [URL] {
    let recorded = Set(
      try await workspaceStates.records().map {
        $0.jobID.uuidString.lowercased()
      })
    return try FileManager.default.contentsOfDirectory(
      at: workspacesURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { candidate in
      let values = try candidate.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      return values.isDirectory == true && values.isSymbolicLink != true
        && !recorded.contains(candidate.lastPathComponent)
    }.sorted { $0.path < $1.path }
  }

  public func workspaceRecord(jobID: UUID) async throws -> WorkspaceRecord? {
    try await workspaceStates.record(jobID: jobID)
  }

  public func workspaceIsCleanAtRecordedHead(jobID: UUID) async throws -> Bool {
    guard let record = try await workspaceStates.record(jobID: jobID),
      record.cleanupState == .retained
    else { return false }
    let workspace = try workspaceURL(record: record)
    let head = try await output(
      arguments: [
        "--no-pager", "--no-optional-locks", "--no-replace-objects",
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-C", workspace.path, "rev-parse", "--verify", "HEAD",
      ],
      workingDirectory: workspace
    )
    guard head == record.localHeadSHA else { return false }
    let status = try await transport.runLocalGit(
      arguments: [
        "--no-pager", "--no-optional-locks", "--no-replace-objects",
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-C", workspace.path, "status", "--porcelain=v1", "-z",
        "--untracked-files=all",
      ],
      workingDirectory: workspace,
      timeoutSeconds: 60,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    try await requireSuccess(status)
    return status.stdout.isEmpty
  }

  public func retainedWorkspaceURL(jobID: UUID) async throws -> URL {
    guard let record = try await workspaceStates.record(jobID: jobID),
      record.cleanupState == .retained
    else {
      throw RepositoryStoreError.workspaceNotFound
    }
    return try workspaceURL(record: record)
  }

  private func validateMirror(
    _ mirror: URL,
    remote: GitRemoteRepository
  ) async throws {
    try Self.validateManagedDirectory(mirror)
    let bare = try await output(
      arguments: ["--git-dir", mirror.path, "rev-parse", "--is-bare-repository"],
      workingDirectory: mirror.deletingLastPathComponent()
    )
    let origin = try await output(
      arguments: ["--git-dir", mirror.path, "config", "--get", "remote.origin.url"],
      workingDirectory: mirror.deletingLastPathComponent()
    )
    let defaultSHA = try await revision(
      "refs/heads/\(remote.defaultBranch)",
      repository: mirror
    )
    guard bare == "true", origin == remote.url.absoluteString,
      GitHubInputValidation.validGitSHA(defaultSHA)
    else {
      throw RepositoryStoreError.mirrorInvalid
    }
  }

  private func validateDetachedWorkspace(
    _ workspace: URL,
    mirror: URL,
    headSHA: String
  ) async throws {
    try Self.validateManagedDirectory(workspace)
    let origin = try await output(
      arguments: ["-C", workspace.path, "config", "--get", "remote.origin.url"],
      workingDirectory: workspace
    )
    let observedHead = try await output(
      arguments: ["-C", workspace.path, "rev-parse", "--verify", "HEAD"],
      workingDirectory: workspace
    )
    let symbolic = try await transport.runLocalGit(
      arguments: ["-C", workspace.path, "symbolic-ref", "-q", "HEAD"],
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard URL(fileURLWithPath: origin).standardizedFileURL == mirror.standardizedFileURL,
      observedHead == headSHA,
      symbolic.exitCode == 1,
      symbolic.terminationSignal == nil,
      !symbolic.timedOut,
      !symbolic.outputLimitExceeded
    else {
      throw RepositoryStoreError.workspaceInvalid
    }
  }

  private func validateWorkspace(
    _ workspace: URL,
    mirror: URL,
    branch: String,
    headSHA: String
  ) async throws {
    try Self.validateManagedDirectory(workspace)
    let origin = try await output(
      arguments: ["-C", workspace.path, "config", "--get", "remote.origin.url"],
      workingDirectory: workspace
    )
    let observedBranch = try await output(
      arguments: ["-C", workspace.path, "symbolic-ref", "--short", "HEAD"],
      workingDirectory: workspace
    )
    let observedHead = try await output(
      arguments: ["-C", workspace.path, "rev-parse", "--verify", "HEAD"],
      workingDirectory: workspace
    )
    guard URL(fileURLWithPath: origin).standardizedFileURL == mirror.standardizedFileURL,
      observedBranch == branch, observedHead == headSHA
    else {
      throw RepositoryStoreError.workspaceInvalid
    }
  }

  private func revision(_ reference: String, repository: URL) async throws -> String {
    let value = try await output(
      arguments: ["--git-dir", repository.path, "rev-parse", "--verify", reference],
      workingDirectory: repository.deletingLastPathComponent()
    )
    guard GitHubInputValidation.validGitSHA(value) else {
      throw RepositoryStoreError.mirrorInvalid
    }
    return value
  }

  private func output(arguments: [String], workingDirectory: URL) async throws -> String {
    let result = try await transport.runLocalGit(
      arguments: arguments,
      workingDirectory: workingDirectory,
      timeoutSeconds: 60,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    try await requireSuccess(result)
    guard let value = String(data: result.stdout, encoding: .utf8) else {
      throw RepositoryStoreError.gitFailure
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func requireSuccess(_ result: GitProcessResult) async throws {
    guard result.succeeded else { throw RepositoryStoreError.gitFailure }
  }

  private func workspaceURL(record: WorkspaceRecord) throws -> URL {
    let expected = "\(record.jobID.uuidString.lowercased())/repo"
    guard record.relativePath == expected else { throw RepositoryStoreError.unsafePath }
    let value = workspacesURL.appendingPathComponent(record.relativePath, isDirectory: true)
    try Self.validateContained(value, root: workspacesURL)
    return value
  }

  private static func validate(_ remote: GitRemoteRepository) throws {
    guard GitHubInputValidation.validOwner(remote.owner),
      GitHubInputValidation.validRepository(remote.name),
      GitHubInputValidation.validBranch(remote.defaultBranch),
      !remote.nodeID.isEmpty
    else {
      throw RepositoryStoreError.invalidRepository
    }
  }

  private static func ensurePrivateDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw RepositoryStoreError.unsafeRoot }
      var existing = stat()
      guard lstat(url.path, &existing) == 0,
        (existing.st_mode & S_IFMT) == S_IFDIR,
        existing.st_uid == geteuid()
      else {
        throw RepositoryStoreError.unsafeRoot
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
    var value = stat()
    guard lstat(url.path, &value) == 0,
      (value.st_mode & S_IFMT) == S_IFDIR,
      (value.st_mode & 0o077) == 0,
      value.st_uid == geteuid()
    else {
      throw RepositoryStoreError.unsafeRoot
    }
  }

  private static func validateManagedDirectory(_ value: URL) throws {
    var attributes = stat()
    guard lstat(value.path, &attributes) == 0,
      (attributes.st_mode & S_IFMT) == S_IFDIR,
      (attributes.st_mode & 0o077) == 0,
      attributes.st_uid == geteuid()
    else {
      throw RepositoryStoreError.unsafePath
    }
  }

  private static func validateContained(_ value: URL, root: URL) throws {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let parentPath = value.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL.path
    guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else {
      throw RepositoryStoreError.unsafePath
    }
  }

  private static func removeExactWorkspace(
    _ value: URL,
    jobID: UUID,
    parent: URL
  ) throws {
    try validateContained(value, root: parent)
    guard value.lastPathComponent == jobID.uuidString.lowercased() else {
      throw RepositoryStoreError.unsafePath
    }
    if FileManager.default.fileExists(atPath: value.path) {
      let values = try value.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RepositoryStoreError.unsafePath
      }
      try FileManager.default.removeItem(at: value)
    }
  }

  private static func removeExactTemporary(_ value: URL, parent: URL) throws {
    try validateContained(value, root: parent)
    guard value.lastPathComponent.contains(".pending-") else {
      throw RepositoryStoreError.unsafePath
    }
    if FileManager.default.fileExists(atPath: value.path) {
      let values = try value.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RepositoryStoreError.unsafePath
      }
      try FileManager.default.removeItem(at: value)
    }
  }
}

public enum GitBranchPolicy {
  public static func validImplementationBranch(_ value: String) -> Bool {
    guard GitHubInputValidation.validBranch(value), value.utf8.count <= 200 else {
      return false
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "agent", parts[1].hasPrefix("issue-") else {
      return false
    }
    let suffix = parts[1].dropFirst("issue-".count)
    let issueAndSlug = suffix.split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard issueAndSlug.count == 2,
      let issueNumber = Int(issueAndSlug[0]), issueNumber > 0,
      String(issueNumber) == issueAndSlug[0],
      !issueAndSlug[1].isEmpty,
      issueAndSlug[1].first != "-", issueAndSlug[1].last != "-"
    else {
      return false
    }
    return issueAndSlug[1].utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
    }
  }
}
