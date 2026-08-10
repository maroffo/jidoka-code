import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production implementation orchestration rails")
struct PiIssueImplementationOrchestratorTests {
  @Test(
    "plan commits first, hooks stay active, frozen checks pass, code commits second, and exact head imports"
  )
  func planThenImplementation() async throws {
    let fixture = try await ProductionOrchestratorFixture()
    defer { fixture.remove() }

    let result = try await fixture.orchestrator.orchestrate(
      job: fixture.job,
      prepared: fixture.prepared,
      workspaceURL: fixture.workspaceURL,
      envelope: fixture.envelope,
      artifactSHA256: fixture.artifactSHA256
    )

    #expect(result.orchestration.disposition == .succeeded)
    #expect(
      result.importEvidence?.changedFiles == [
        "Feature.txt", fixture.prepared.planPath,
      ])
    #expect(result.orchestration.commandEvidence.count == fixture.envelope.plan.commandOrder.count)
    let commits = result.orchestration.commandEvidence.filter {
      $0.registryKind == .gitCommit
    }
    #expect(commits.count == 2)
    #expect(commits.allSatisfy { $0.succeeded && $0.approvedHookPath == ".githooks" })
    #expect(await fixture.runner.callCount == 5)
    #expect(try await fixture.commitCount() == 2)
    let commandRuns = try await fixture.commandRuns.runs(jobID: fixture.job.id)
    #expect(commandRuns.count == fixture.envelope.plan.commandOrder.count)
    #expect(commandRuns.allSatisfy { $0.state == .resultAccepted })
    #expect(
      commandRuns.filter { $0.phase == .bootstrap }.map(\.commandID) == [
        "stage-plan", "setup-hooks-plan", "commit-plan",
      ])
    #expect(commandRuns.filter { $0.phase == .orchestration }.allSatisfy { $0.round == 1 })
    #expect(try await fixture.planCommitPaths() == [fixture.prepared.planPath])
    #expect(try await fixture.implementationCommitPaths() == ["Feature.txt"])
  }
}

private final class ProductionOrchestratorFixture: @unchecked Sendable {
  let gitFixture: GitTestRoot
  let database: SQLiteStore
  let jobs: DurableJobStore
  let commandRuns: ApprovedCommandRunStore
  let commandGate: ApprovedCommandExecutionGate
  let repositories: RepositoryStore
  let job: JobRecord
  let workspaceURL: URL
  let prepared: PreparedIssueImplementationJob
  let envelope: IssueImplementationPlanEnvelope
  let artifactSHA256: String
  let runner: OrchestrationRPCRunner
  let orchestrator: PiIssueImplementationOrchestrator
  let baseSHA: String

  init() async throws {
    gitFixture = try GitTestRoot(prefix: "jidoka-production-orchestrator")
    let source = try await gitFixture.initializeRepository()
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent(".githooks", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("base\n".utf8).write(to: source.appendingPathComponent("README.md"))
    try Data("check:\n\t@/bin/test -f Feature.txt\n".utf8).write(
      to: source.appendingPathComponent("Makefile")
    )
    let setup = source.appendingPathComponent("scripts/setup-hooks")
    try writeExecutable(
      setup,
      "#!/bin/sh\nset -eu\n/usr/bin/git config --local core.hooksPath .githooks\n"
    )
    let clearHooks = source.appendingPathComponent("scripts/clear-hooks")
    try writeExecutable(
      clearHooks,
      "#!/bin/sh\nset -eu\n/usr/bin/git config --local --unset core.hooksPath\n"
    )
    try writeExecutable(
      source.appendingPathComponent(".githooks/pre-commit"),
      "#!/bin/sh\nset -eu\nexit 0\n"
    )
    try await gitFixture.run([
      "-C", source.path, "add", "--", ".githooks", "Makefile", "README.md", "scripts",
    ])
    try await gitFixture.run(["-C", source.path, "commit", "-m", "test: base fixture"])
    baseSHA = try await gitFixture.output(["-C", source.path, "rev-parse", "HEAD"])
    let remoteURL = try await gitFixture.bareRemote(from: source)

    database = try SQLiteStore(
      databaseURL: gitFixture.root.appendingPathComponent("state.sqlite3")
    )
    let configuration = ConfigurationStore(database: database)
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "repository-node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(
      repository,
      now: Date(timeIntervalSince1970: 130_000)
    )
    jobs = DurableJobStore(database: database)
    commandRuns = ApprovedCommandRunStore(database: database)
    commandGate = ApprovedCommandExecutionGate()
    await commandGate.open()
    let issueRevision = try IssueRevisionBuilder.make(
      input: IssueRevisionInput(
        issueNodeID: "issue-node-21",
        title: "Implement production rails",
        body: "Create Feature.txt.",
        authorID: 2,
        createdAt: "2026-08-08T00:00:00Z",
        labels: [IssueRevisionLabel(nodeID: "label-ready", name: "agent:wip")],
        comments: [],
        linkedInputs: []
      )
    )
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .issueImplementation,
        objectNodeID: "issue-node-21",
        revisionKey: issueRevision.sha256
      ),
      objectNumber: 21,
      contractVersionUsed: "w6-test",
      priority: .issueImplementation,
      firstStep: .orchestrate,
      now: Date(timeIntervalSince1970: 130_000)
    )
    guard case .created(let value) = creation else {
      throw ProductionOrchestratorFixtureError.suppressed
    }
    let leased = productionOrchestratorJob(
      try await jobs.transition(
        jobID: value.id,
        eventKey: "production-orchestrator:lease",
        event: .acquireLease,
        context: JobTransitionContext(now: value.createdAt, reason: "fixture lease")
      )
    )
    let preparing = productionOrchestratorJob(
      try await jobs.transition(
        jobID: leased.id,
        eventKey: "production-orchestrator:inputs",
        event: .inputsValidated,
        context: JobTransitionContext(now: value.createdAt, reason: "fixture inputs")
      )
    )
    job = productionOrchestratorJob(
      try await jobs.transition(
        jobID: preparing.id,
        eventKey: "production-orchestrator:pi",
        event: .selectPiStep,
        context: JobTransitionContext(now: value.createdAt, reason: "fixture Pi step")
      )
    )
    repositories = try RepositoryStore(
      rootURL: gitFixture.root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database,
      transport: gitFixture.git
    )
    let remote = try GitRemoteRepository(
      repositoryID: repository.id,
      nodeID: repository.nodeID,
      owner: repository.owner,
      name: repository.name,
      defaultBranch: repository.defaultBranch,
      localFixtureURL: remoteURL
    )
    let materialization = try await repositories.materializeWorkspace(
      jobID: job.id,
      remote: remote,
      baseSHA: baseSHA,
      branch: "agent/issue-21-production-rails",
      now: Date(timeIntervalSince1970: 130_000)
    )
    workspaceURL = materialization.workspaceURL
    let artifact = Data("{\"fixture\":\"bounded\"}".utf8)
    artifactSHA256 = GitHubMarkerCodec.sha256(artifact)
    let baseRevision = try BaseRevision(branch: "main", sha: baseSHA)
    let issue = GitHubIssue(
      id: 21,
      nodeID: "issue-node-21",
      number: 21,
      state: "open",
      title: "Implement production rails",
      body: "Create Feature.txt.",
      user: GitHubUser(id: 2, nodeID: "author-node", login: "author"),
      labels: [],
      createdAt: "2026-08-08T00:00:00Z",
      pullRequest: nil
    )
    prepared = PreparedIssueImplementationJob(
      repository: repository,
      issue: issue,
      comments: [],
      workflowLabels: ["agent:wip"],
      issueRevision: issueRevision,
      baseRevision: baseRevision,
      remote: remote,
      mirrorURL: materialization.mirrorURL,
      branch: "agent/issue-21-production-rails",
      planPath: "docs/plans/jidoka-code-issue-21.md",
      artifact: artifact
    )
    let setupDigest = GitHubMarkerCodec.sha256(try Data(contentsOf: setup))
    let clearHooksDigest = GitHubMarkerCodec.sha256(try Data(contentsOf: clearHooks))
    let commands = [
      makeApprovedCommand(
        id: "stage-plan",
        kind: .gitStage,
        executable: "git",
        arguments: [prepared.planPath],
        rationale: "Stage only the frozen plan."
      ),
      makeApprovedCommand(
        id: "setup-hooks-plan",
        kind: .repositoryScript,
        executable: "scripts/setup-hooks",
        arguments: [],
        rationale: "Configure the digest-approved hooks for the plan commit.",
        sourceDigest: setupDigest
      ),
      makeApprovedCommand(
        id: "commit-plan",
        kind: .gitCommit,
        executable: "git",
        arguments: ["docs: record issue implementation plan"],
        rationale: "Commit the frozen plan before source edits.",
        approvedHookPath: ".githooks"
      ),
      makeApprovedCommand(
        id: "clear-hooks-after-plan",
        kind: .repositoryScript,
        executable: "scripts/clear-hooks",
        arguments: [],
        rationale: "Remove the hook config before non-commit Git commands.",
        sourceDigest: clearHooksDigest
      ),
      makeApprovedCommand(
        id: "check",
        kind: .makeTargets,
        executable: "make",
        arguments: ["check"],
        rationale: "Run the exact frozen repository check."
      ),
      makeApprovedCommand(
        id: "stage-implementation",
        kind: .gitStage,
        executable: "git",
        arguments: ["Feature.txt"],
        rationale: "Stage only the reviewed implementation file."
      ),
      makeApprovedCommand(
        id: "setup-hooks-implementation",
        kind: .repositoryScript,
        executable: "scripts/setup-hooks",
        arguments: [],
        rationale: "Configure the digest-approved hooks for the implementation commit.",
        sourceDigest: setupDigest
      ),
      makeApprovedCommand(
        id: "commit-implementation",
        kind: .gitCommit,
        executable: "git",
        arguments: ["feat: add production rail fixture"],
        rationale: "Commit the checked implementation with hooks active.",
        approvedHookPath: ".githooks"
      ),
    ]
    let plan = try makeFrozenPlan(
      commands,
      decisionEvidenceSeed: "production-orchestrator",
      artifactSHA256: artifactSHA256,
      planMarkdown:
        "# Production rail plan\n\nCreate `Feature.txt`, run `make check`, and commit it.\n"
    )
    envelope = try IssueImplementationPlanEnvelope(
      issueRevisionSHA256: issueRevision.sha256,
      baseRevision: baseRevision,
      branch: prepared.branch,
      planPath: prepared.planPath,
      plan: plan
    )
    let sessionRoot = gitFixture.root.appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sessionRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: sessionRoot.path
    )
    runner = OrchestrationRPCRunner(
      workspace: workspaceURL,
      commandOrder: plan.commandOrder
    )
    orchestrator = PiIssueImplementationOrchestrator(
      executorFactory: PiRPCWorkflowExecutorFactory(
        runtimeResolver: ProductionFixtureRuntimeResolver(),
        resourceRoot: Self.resourceRoot,
        runner: runner
      ),
      sessionRoot: sessionRoot,
      profiles: [
        Self.profile(.review), Self.profile(.planning), Self.profile(.orchestration),
      ],
      verificationRunner: VerificationCommandRunner(),
      commandRuns: commandRuns,
      commandGate: commandGate,
      importer: WorkspaceImporter(git: gitFixture.git),
      git: gitFixture.git,
      offline: true,
      timeoutSeconds: 30
    )
  }

  func commitCount() async throws -> Int {
    Int(try await output(["rev-list", "--count", "\(baseSHA)..HEAD"])) ?? -1
  }

  func planCommitPaths() async throws -> [String] {
    try await lines(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD~1"])
  }

  func implementationCommitPaths() async throws -> [String] {
    try await lines(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
  }

  private func lines(_ arguments: [String]) async throws -> [String] {
    try await output(arguments).split(separator: "\n").map(String.init).sorted()
  }

  private func output(_ arguments: [String]) async throws -> String {
    let result = try await gitFixture.git.runLocalGit(
      arguments: ["-C", workspaceURL.path] + arguments,
      workingDirectory: workspaceURL,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)
    else {
      throw ProductionOrchestratorFixtureError.gitFailure
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func remove() { gitFixture.remove() }

  private static let resourceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Pi", isDirectory: true)

  private static func profile(_ role: ModelProfileRole) -> ModelProfileConfiguration {
    ModelProfileConfiguration(role: role, provider: "fixture", model: "fixture", thinking: .off)
  }
}

private struct ProductionFixtureRuntimeResolver: PiRuntimeResolving {
  func resolve() throws -> PiResolvedRuntime {
    PiResolvedRuntime(
      nodeURL: URL(fileURLWithPath: "/usr/bin/false"),
      nodeVersion: try PiSemanticVersion("26.6.0"),
      nodeSHA256: String(repeating: "a", count: 64),
      piCLIURL: URL(fileURLWithPath: "/attested/pi-cli.js"),
      piPackageRootURL: URL(fileURLWithPath: "/attested/pi-package", isDirectory: true),
      piVersion: try PiSemanticVersion("0.84.0"),
      piRuntimeSHA256: [:],
      compatibility: PiRuntimeCompatibility(
        minimumVersion: try PiSemanticVersion("0.84.0"),
        maximumVersionExclusive: try PiSemanticVersion("0.90.0"),
        policySHA256: String(repeating: "b", count: 64)
      )
    )
  }
}

private actor OrchestrationRPCRunner: PiRPCProcessRunning {
  let workspace: URL
  let commandOrder: [String]
  private(set) var callCount = 0

  init(workspace: URL, commandOrder: [String]) {
    self.workspace = workspace
    self.commandOrder = commandOrder
  }

  func run(_ request: PiRPCProcessRequest) async throws -> PiRPCExecutionResult {
    callCount += 1
    let role = try #require(PiWorkflowRole(rawValue: request.terminalIdentity.role))
    if role == .writer {
      try Data("production rails\n".utf8).write(
        to: workspace.appendingPathComponent("Feature.txt"),
        options: [.atomic]
      )
    }
    let approved =
      role == .writer
      ? commandOrder : request.terminalIdentity.allowedCommandIDs.sorted()
    let resumedSession = request.arguments.firstIndex(of: "--session").flatMap { index in
      index + 1 < request.arguments.count ? request.arguments[index + 1] : nil
    }
    let freshSession = String(format: "00000000-0000-0000-0000-%012d", callCount)
    return PiRPCExecutionResult(
      sessionID: resumedSession ?? freshSession,
      terminalResult: PiRPCTerminalResult(
        workflow: request.terminalIdentity.workflow,
        role: request.terminalIdentity.role,
        nonce: request.terminalIdentity.nonce,
        artifactSHA256: request.terminalIdentity.artifactSHA256,
        approvedCommandIDs: approved,
        payload: [
          "changedPaths": .array(
            role == .writer ? [.string("Feature.txt")] : []
          ),
          "evidence": .array([.string("Exact command evidence passed.")]),
          "findings": .array([]),
          "requestedCommandIDs": .array(approved.map { .string($0) }),
          "severity": .string("none"),
          "summary": .string("Bounded implementation passed."),
          "verdict": .string("pass"),
        ],
        recordSHA256: GitHubMarkerCodec.sha256(
          Data("orchestration-record-\(callCount)".utf8)
        )
      ),
      stdoutSHA256: String(repeating: "c", count: 64),
      stderrSHA256: String(repeating: "d", count: 64),
      durationSeconds: 0.1,
      abortAcknowledged: false,
      cleanupVerified: true
    )
  }
}

private func productionOrchestratorJob(_ result: JobTransitionResult) -> JobRecord {
  switch result {
  case .applied(let job), .duplicate(let job): job
  }
}

private enum ProductionOrchestratorFixtureError: Error {
  case suppressed
  case gitFailure
}
