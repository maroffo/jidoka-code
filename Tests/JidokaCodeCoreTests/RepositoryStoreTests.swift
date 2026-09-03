import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("App-managed repository mirrors and workspaces")
struct RepositoryStoreTests {
  @Test("mirror, exact PR ref, local-origin workspace, and cleanup are durable")
  func lifecycle() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-repository-store")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let baseSHA = try await fixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "chore: add base"
    )
    let sourceStatus = try await fixture.output(["-C", source.path, "status", "--porcelain"])
    let remoteURL = try await fixture.bareRemote(from: source)
    let headSHA = try await fixture.commit(
      repository: source,
      path: "Sources/Feature.swift",
      contents: "let feature = true\n",
      message: "feat: add fixture"
    )
    try await fixture.run([
      "-C", source.path, "push", remoteURL.path,
      "\(headSHA):refs/pull/7/head",
    ])

    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repositoryID = UUID()
    let configuration = RepositoryConfiguration(
      id: repositoryID,
      nodeID: "R_fixture",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await ConfigurationStore(database: database).upsertRepository(
      configuration,
      now: Date(timeIntervalSince1970: 1_000)
    )
    let jobs = DurableJobStore(database: database)
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_fixture",
        revisionKey: "claim-1"
      ),
      objectNumber: 7,
      contractVersionUsed: "v1",
      priority: .issueImplementation,
      firstStep: .publish,
      now: Date(timeIntervalSince1970: 1_000)
    )
    let job: JobRecord
    guard case .created(let created) = creation else {
      Issue.record("fixture job was suppressed")
      return
    }
    job = created
    try await jobs.appendCompletedStep(
      jobID: job.id,
      ordinal: 0,
      kind: .publish,
      inputDigest: String(repeating: "a", count: 64),
      outputDigest: String(repeating: "b", count: 64),
      mutationID: "cleanup-fixture",
      acceptanceEvidence: "blocked-publication",
      now: Date(timeIntervalSince1970: 1_001)
    )

    let remote = try GitRemoteRepository(
      repositoryID: repositoryID,
      nodeID: configuration.nodeID,
      owner: configuration.owner,
      name: configuration.name,
      defaultBranch: configuration.defaultBranch,
      localFixtureURL: remoteURL
    )
    let appRoot = fixture.root.appendingPathComponent("ApplicationSupport", isDirectory: true)
    let store = try RepositoryStore(
      rootURL: appRoot,
      database: database,
      transport: fixture.git
    )
    let mirror = try await store.ensureMirror(remote: remote)
    #expect(
      mirror.path.hasSuffix("/Repositories/\(repositoryID.uuidString.lowercased())/mirror.git"))
    let fetched = try await store.fetchPullRequest(
      number: 7,
      expectedSHA: headSHA,
      jobID: job.id,
      remote: remote
    )
    #expect(fetched == headSHA)
    await #expect(throws: GitTransportError.exactSHAMismatch) {
      _ = try await store.fetchPullRequest(
        number: 7,
        expectedSHA: String(repeating: "a", count: 40),
        jobID: UUID(),
        remote: remote
      )
    }

    let materialized = try await store.materializeWorkspace(
      jobID: job.id,
      remote: remote,
      baseSHA: baseSHA,
      branch: "agent/issue-7-fixture",
      now: Date(timeIntervalSince1970: 1_001)
    )
    #expect(materialized.record.localHeadSHA == baseSHA)
    #expect(materialized.record.cleanupState == .retained)
    #expect(
      try await fixture.output([
        "-C", materialized.workspaceURL.path, "symbolic-ref", "--short", "HEAD",
      ]) == "agent/issue-7-fixture"
    )
    #expect(
      URL(
        fileURLWithPath: try await fixture.output([
          "-C", materialized.workspaceURL.path, "config", "--get", "remote.origin.url",
        ])
      ).standardizedFileURL == mirror.standardizedFileURL
    )
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: materialized.workspaceURL.path
      )[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
    #expect(try await fixture.output(["-C", source.path, "status", "--porcelain"]) == sourceStatus)

    let orphan = store.workspacesURL.appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(
      at: orphan,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(
      try await store.orphanedWorkspaceDirectories().map(\.standardizedFileURL.path)
        .contains(orphan.standardizedFileURL.path)
    )
    await #expect(throws: RepositoryStoreError.cleanupNotAuthorized) {
      try await store.cleanupWorkspace(jobID: job.id)
    }
    try await database.execute(
      "UPDATE jobs SET state = 'awaitingResolution' WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )
    await #expect(throws: RepositoryStoreError.cleanupNotAuthorized) {
      try await store.authorizeCleanup(jobID: job.id)
    }
    try await database.execute(
      "UPDATE jobs SET state = 'blocked' WHERE id = ?",
      bindings: [.text(job.id.uuidString.lowercased())]
    )
    try await store.authorizeCleanup(jobID: job.id, now: Date(timeIntervalSince1970: 1_002))
    try FileManager.default.removeItem(
      at: materialized.workspaceURL.deletingLastPathComponent()
    )
    try await store.cleanupWorkspace(jobID: job.id, now: Date(timeIntervalSince1970: 1_003))
    try await store.cleanupWorkspace(jobID: job.id, now: Date(timeIntervalSince1970: 1_004))
    #expect(try await store.workspaceRecord(jobID: job.id)?.cleanupState == .removed)
    let recreated = store.workspacesURL.appendingPathComponent(
      job.id.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: recreated,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    await #expect(throws: RepositoryStoreError.unsafePath) {
      try await store.cleanupWorkspace(jobID: job.id)
    }
    #expect(FileManager.default.fileExists(atPath: recreated.path))
    #expect(FileManager.default.fileExists(atPath: orphan.path))
  }

  @Test("operator retirement cleans only an exact clean evidence-bound workspace")
  func operatorRetirementCleanup() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-repository-retirement")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let baseSHA = try await fixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "R_retirement",
      owner: "owner",
      name: "repository",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await ConfigurationStore(database: database).upsertRepository(
      repository,
      now: Date(timeIntervalSince1970: 1)
    )
    let jobs = DurableJobStore(database: database)
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "PR_retirement",
        revisionKey: "head"
      ),
      contractVersionUsed: "v1",
      priority: .prReview,
      firstStep: .review,
      now: Date(
        timeIntervalSince1970: TimeInterval(
          JobMaintenanceScope.authorizedBoundaryEpochSeconds - 1
        )
      )
    )
    guard case .created(let job) = creation else {
      Issue.record("retirement fixture job was suppressed")
      return
    }
    let remote = try GitRemoteRepository(
      repositoryID: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      localFixtureURL: remoteURL
    )
    let store = try RepositoryStore(
      rootURL: fixture.root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database,
      transport: fixture.git
    )
    _ = try await store.ensureMirror(remote: remote)
    let materialized = try await store.materializeWorkspace(
      jobID: job.id,
      remote: remote,
      baseSHA: baseSHA,
      branch: "agent/issue-1-retirement",
      now: Date(timeIntervalSince1970: 2)
    )
    #expect(try await store.workspaceIsCleanAtRecordedHead(jobID: job.id))

    try await database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let stalePreview = try await jobs.previewMaintenance(scope: scope)
    let staleAuthorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: stalePreview.candidateCount,
      evidenceSHA256: stalePreview.evidenceSHA256
    )
    try await database.execute(
      "UPDATE workspaces SET updated_at = ? WHERE job_id = ?",
      bindings: [
        .real(2.5),
        .text(job.id.uuidString.lowercased()),
      ]
    )
    await #expect(throws: DurableJobStoreError.maintenanceEvidenceMismatch) {
      _ = try await jobs.applyMaintenance(
        staleAuthorization,
        now: Date(timeIntervalSince1970: 3)
      )
    }
    let preview = try await jobs.previewMaintenance(scope: scope)
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    _ = try await jobs.applyMaintenance(authorization, now: Date(timeIntervalSince1970: 3))
    await #expect(throws: RepositoryStoreError.cleanupNotAuthorized) {
      try await store.authorizeOperatorRetirementCleanup(
        jobID: job.id,
        evidenceSHA256: String(repeating: "b", count: 64)
      )
    }
    try await store.authorizeOperatorRetirementCleanup(
      jobID: job.id,
      evidenceSHA256: authorization.evidenceSHA256,
      now: Date(timeIntervalSince1970: 4)
    )
    try await store.cleanupWorkspace(jobID: job.id, now: Date(timeIntervalSince1970: 5))
    #expect(try await store.workspaceRecord(jobID: job.id)?.cleanupState == .removed)
    #expect(!FileManager.default.fileExists(atPath: materialized.workspaceURL.path))
  }

  @Test("unsafe roots, branches, collisions, and missing jobs fail closed")
  func invalidInputs() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-repository-invalid")
    defer { fixture.remove() }
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let realRoot = fixture.root.appendingPathComponent("real", isDirectory: true)
    let linkedRoot = fixture.root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
    #expect(throws: RepositoryStoreError.unsafeRoot) {
      _ = try RepositoryStore(rootURL: linkedRoot, database: database, transport: fixture.git)
    }
    for branch in [
      "main", "agent/issue-0-invalid", "agent/issue-1/extra", "agent/issue-1-.bad",
      "agent/issue-1-topic/../../escape", "agent/issue-1-title;touch-pwned",
    ] {
      #expect(!GitBranchPolicy.validImplementationBranch(branch))
    }
  }
}
