import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Validated workspace import into app mirror")
struct WorkspaceImporterTests {
  @Test("branch, ancestry, tree, changed files, hooks, and exact SHA gate import")
  func validatedImport() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-import")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let base = try await fixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repositoryID = UUID()
    let configuration = RepositoryConfiguration(
      id: repositoryID,
      nodeID: "R_import",
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
      now: Date(timeIntervalSince1970: 2_000)
    )
    let jobs = DurableJobStore(database: database)
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_import",
        revisionKey: "claim-1"
      ),
      objectNumber: 8,
      contractVersionUsed: "v1",
      priority: .issueImplementation,
      firstStep: .implement,
      now: Date(timeIntervalSince1970: 2_000)
    )
    guard case .created(let job) = creation else {
      Issue.record("fixture job was suppressed")
      return
    }
    let remote = try GitRemoteRepository(
      repositoryID: repositoryID,
      nodeID: configuration.nodeID,
      owner: configuration.owner,
      name: configuration.name,
      defaultBranch: configuration.defaultBranch,
      localFixtureURL: remoteURL
    )
    let store = try RepositoryStore(
      rootURL: fixture.root.appendingPathComponent("ApplicationSupport"),
      database: database,
      transport: fixture.git
    )
    let materialized = try await withTestRolloutWorkflow(jobID: job.id) {
      try await store.materializeWorkspace(
        jobID: job.id,
        remote: remote,
        baseSHA: base,
        branch: "agent/issue-8-import"
      )
    }
    let changedPath = "Sources/Feature.swift"
    let changedURL = materialized.workspaceURL.appendingPathComponent(changedPath)
    try FileManager.default.createDirectory(
      at: changedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "let imported = true\n".write(
      to: changedURL,
      atomically: true,
      encoding: .utf8
    )

    let stage = makeApprovedCommand(
      id: "stage",
      kind: .gitStage,
      executable: "git",
      arguments: [changedPath]
    )
    let commit = makeApprovedCommand(
      id: "commit",
      kind: .gitCommit,
      executable: "git",
      arguments: ["feat(import): add validated fixture"]
    )
    let plan = try makeFrozenPlan([stage, commit])
    let commandRunner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let stageEvidence = try await commandRunner.execute(
      commandID: stage.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: materialized.workspaceURL
    )
    #expect(stageEvidence.succeeded)
    let commitEvidence = try await commandRunner.execute(
      commandID: commit.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: materialized.workspaceURL
    )
    #expect(commitEvidence.succeeded)
    let head = try await fixture.output([
      "-C", materialized.workspaceURL.path, "rev-parse", "HEAD",
    ])
    let tree = try await fixture.output([
      "-C", materialized.workspaceURL.path, "rev-parse", "HEAD^{tree}",
    ])
    _ = try await store.refreshWorkspaceHead(jobID: job.id)

    let importer = WorkspaceImporter(git: fixture.git)
    let request = WorkspaceImportRequest(
      jobID: job.id,
      branch: "agent/issue-8-import",
      baseSHA: base,
      exactHeadSHA: head,
      expectedTreeSHA: tree,
      allowedChangedFiles: [changedPath],
      commitEvidence: commitEvidence
    )
    let evidence = try await importer.importHead(
      request: request,
      workspace: materialized.workspaceURL,
      mirror: materialized.mirrorURL
    )
    #expect(evidence.exactHeadSHA == head)
    #expect(evidence.treeSHA == tree)
    #expect(evidence.changedFiles == [changedPath])
    #expect(
      try await fixture.output([
        "--git-dir", materialized.mirrorURL.path, "rev-parse", evidence.localReference,
      ]) == head
    )

    let disallowed = WorkspaceImportRequest(
      jobID: UUID(),
      branch: request.branch,
      baseSHA: base,
      exactHeadSHA: head,
      expectedTreeSHA: tree,
      allowedChangedFiles: ["README.md"],
      commitEvidence: commitEvidence
    )
    await #expect(throws: WorkspaceImporterError.changedFileViolation(changedPath)) {
      _ = try await importer.importHead(
        request: disallowed,
        workspace: materialized.workspaceURL,
        mirror: materialized.mirrorURL
      )
    }

    _ = try await fixture.run([
      "-C", materialized.workspaceURL.path, "config", "core.fsmonitor", "!untrusted",
    ])
    await #expect(throws: WorkspaceImporterError.hookEvidenceMissing) {
      _ = try await importer.importHead(
        request: request,
        workspace: materialized.workspaceURL,
        mirror: materialized.mirrorURL
      )
    }
    _ = try await fixture.run([
      "-C", materialized.workspaceURL.path, "config", "--unset", "core.fsmonitor",
    ])

    let untracked = materialized.workspaceURL.appendingPathComponent("untracked.txt")
    try "uncommitted\n".write(to: untracked, atomically: true, encoding: .utf8)
    await #expect(throws: WorkspaceImporterError.workspaceDirty) {
      _ = try await importer.importHead(
        request: request,
        workspace: materialized.workspaceURL,
        mirror: materialized.mirrorURL
      )
    }
    try FileManager.default.removeItem(at: untracked)

    let wrongHead = WorkspaceImportRequest(
      jobID: UUID(),
      branch: request.branch,
      baseSHA: base,
      exactHeadSHA: String(repeating: "a", count: 40),
      expectedTreeSHA: tree,
      allowedChangedFiles: [changedPath],
      commitEvidence: commitEvidence
    )
    await #expect(throws: WorkspaceImporterError.hookEvidenceMissing) {
      _ = try await importer.importHead(
        request: wrongHead,
        workspace: materialized.workspaceURL,
        mirror: materialized.mirrorURL
      )
    }
  }

  @Test("changed-file parser rejects malformed UTF-8")
  func malformedChangedPath() {
    #expect(throws: WorkspaceImporterError.invalidRequest) {
      _ = try WorkspaceImporter.parseChangedFiles(Data([0xFF, 0x00]))
    }
    #expect(throws: WorkspaceImporterError.invalidRequest) {
      _ = try WorkspaceImporter.parseChangedFiles(Data())
    }
    #expect(throws: WorkspaceImporterError.invalidRequest) {
      _ = try WorkspaceImporter.parseChangedFiles(Data("Sources/File.swift".utf8))
    }
    #expect(throws: WorkspaceImporterError.invalidRequest) {
      _ = try WorkspaceImporter.parseChangedFiles(
        Data("Sources/One.swift\u{0}\u{0}Sources/Two.swift\u{0}".utf8)
      )
    }
  }
}
