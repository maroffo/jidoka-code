import CryptoKit
import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Herdr Pi workflow runtime", .serialized)
struct HerdrPiWorkflowRuntimeTests {
  @Test("job kinds eagerly create exact one four and five role-host topologies")
  func eagerTopologyCardinality() async throws {
    let cases: [(JobKind, PiWorkflowKind, PiWorkflowRole, Int)] = [
      (.issueTriage, .issueTriage, .triage, 1),
      (.prReview, .pullRequestReview, .architecture, 4),
      (.issueImplementation, .planning, .writer, 5),
    ]
    for (kind, workflow, role, expectedCount) in cases {
      let fixture = try await HerdrPiRuntimeFixture.make(kind: kind)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      await fixture.runtime.setLaunchAllowed(true)
      async let failure: Void = fixture.emitRuntimeFailure()
      let executor = fixture.runtime.makeExecutor(
        preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
      )
      await #expect(throws: HerdrPiWorkflowError.runtimeFailure("FIXTURE_FAILURE")) {
        _ = try await executor.execute(
          PiWorkflowExecutionRequest(
            jobID: "job-\(fixture.jobID.uuidString.lowercased())",
            workflow: workflow,
            role: role,
            round: 1,
            artifactSHA256: fixture.artifactSHA256,
            sessionDirective: .fresh
          )
        )
      }
      try await failure
      let commands = await fixture.herdr.launchedCommands()
      #expect(commands.count == expectedCount)
      let hosts = try await fixture.runStore.roleHosts(jobID: fixture.jobID)
      #expect(hosts.count == expectedCount)
      #expect(hosts.allSatisfy { $0.state == .waiting && $0.processIdentity != nil })
      #expect(try await fixture.runStore.jobBinding(jobID: fixture.jobID)?.state == .active)
      #expect(commands.allSatisfy { $0.count == 3 && $0[0] == "/usr/bin/true" })
      #expect(!commands.flatMap { $0 }.contains("agent.start"))
      #expect(!commands.flatMap { $0 }.contains("pi"))
      if kind == .issueTriage {
        await fixture.herdr.failNextHandshake()
        let reconnectRequest = PiWorkflowExecutionRequest(
          jobID: "job-\(fixture.jobID.uuidString.lowercased())",
          workflow: workflow,
          role: role,
          round: 2,
          artifactSHA256: fixture.artifactSHA256,
          sessionDirective: .fresh
        )
        await #expect(throws: HerdrPiWorkflowError.topologyUnavailable) {
          _ = try await executor.execute(reconnectRequest)
        }
        await #expect(throws: HerdrPiWorkflowError.launchSuppressed) {
          _ = try await executor.execute(reconnectRequest)
        }
        #expect(await fixture.herdr.launchedCommands().count == expectedCount)
      }
    }
  }

  @Test("every production workflow fails closed when Herdr is unavailable")
  func herdrFailureHasNoFallback() async throws {
    let cases: [(JobKind, PiWorkflowKind, PiWorkflowRole)] = [
      (.issueTriage, .issueTriage, .triage),
      (.prReview, .pullRequestReview, .architecture),
      (.issueImplementation, .planning, .writer),
      (.issueImplementation, .orchestration, .writer),
    ]
    for (kind, workflow, role) in cases {
      let fixture = try await HerdrPiRuntimeFixture.make(kind: kind)
      await fixture.herdr.failNextHandshake()
      await fixture.runtime.setLaunchAllowed(true)
      let executor = fixture.runtime.makeExecutor(
        preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
      )
      await #expect(throws: HerdrPiWorkflowError.topologyUnavailable) {
        _ = try await executor.execute(
          PiWorkflowExecutionRequest(
            jobID: "job-\(fixture.jobID.uuidString.lowercased())",
            workflow: workflow,
            role: role,
            round: 1,
            artifactSHA256: fixture.artifactSHA256,
            sessionDirective: .fresh
          )
        )
      }
      #expect(await fixture.herdr.launchedCommands().isEmpty)
      #expect(try await fixture.runStore.runs().isEmpty)
      try? FileManager.default.removeItem(at: fixture.root)
    }
  }

  @Test("startup recovery rolls back every partial exact 1 4 and 5 role generation")
  func partialActivationStartupRecovery() async throws {
    let cases: [(JobKind, Int)] = [
      (.issueTriage, 1),
      (.prReview, 4),
      (.issueImplementation, 5),
    ]
    for (kind, roleCount) in cases {
      for startedCount in 0..<roleCount {
        let fixture = try await HerdrPiRuntimeFixture.make(kind: kind)
        try await fixture.preparePartialTopology(kind: kind, startedCount: startedCount)
        await fixture.herdr.renameJobTabAndAddDuplicateLabel()
        let recovered = try fixture.reopenedRuntime()
        try await recovered.recoverDurableState()
        let hosts = try await fixture.runStore.roleHosts(jobID: fixture.jobID)
        #expect(hosts.count == roleCount)
        #expect(hosts.allSatisfy { $0.state == .lost })
        #expect(try await fixture.runStore.jobBinding(jobID: fixture.jobID)?.state == .lost)
        #expect(await fixture.herdr.paneCount() == 1)
        try? FileManager.default.removeItem(at: fixture.root)
      }
    }
  }

  @Test("partial exact 1 4 and 5 role activation rolls every sibling back")
  func partialActivationRollback() async throws {
    let cases: [(JobKind, PiWorkflowKind, PiWorkflowRole, Int)] = [
      (.issueTriage, .issueTriage, .triage, 1),
      (.prReview, .pullRequestReview, .architecture, 4),
      (.issueImplementation, .planning, .writer, 5),
    ]
    for (kind, workflow, role, roleCount) in cases {
      for failedRoleIndex in 1...roleCount {
        let fixture = try await HerdrPiRuntimeFixture.make(kind: kind)
        await fixture.herdr.failRoleProcessInfo(index: failedRoleIndex)
        await fixture.runtime.setLaunchAllowed(true)
        let executor = fixture.runtime.makeExecutor(
          preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
        )
        await #expect(throws: HerdrPiWorkflowError.topologyUnavailable) {
          _ = try await executor.execute(
            PiWorkflowExecutionRequest(
              jobID: "job-\(fixture.jobID.uuidString.lowercased())",
              workflow: workflow,
              role: role,
              round: 1,
              artifactSHA256: fixture.artifactSHA256,
              sessionDirective: .fresh
            )
          )
        }
        let hosts = try await fixture.runStore.roleHosts(jobID: fixture.jobID)
        #expect(hosts.count == roleCount)
        #expect(hosts.allSatisfy { $0.state == .lost })
        #expect(try await fixture.runStore.jobBinding(jobID: fixture.jobID)?.state == .lost)
        #expect(await fixture.herdr.launchedCommands().count == roleCount)
        #expect(await fixture.herdr.paneCount() == 1)
        try? FileManager.default.removeItem(at: fixture.root)
      }
    }
  }

  @Test("quit timeout marks every sibling host lost instead of stranding stopping state")
  func quitTimeoutConvergesSiblingStates() async throws {
    let fixture = try await HerdrPiRuntimeFixture.make(kind: .prReview)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await fixture.runtime.setLaunchAllowed(true)
    async let failure: Void = fixture.emitRuntimeFailure()
    let executor = fixture.runtime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    await #expect(throws: HerdrPiWorkflowError.runtimeFailure("FIXTURE_FAILURE")) {
      _ = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: "job-\(fixture.jobID.uuidString.lowercased())",
          workflow: .pullRequestReview,
          role: .architecture,
          round: 1,
          artifactSHA256: fixture.artifactSHA256,
          sessionDirective: .fresh
        )
      )
    }
    try await failure
    let foreignPaneID = try await fixture.herdr.takeOverRolePane()
    await #expect(throws: HerdrPiWorkflowError.timedOut) {
      try await fixture.runtime.shutdownOwnedRoleHosts(timeoutSeconds: 0)
    }
    let hosts = try await fixture.runStore.roleHosts(jobID: fixture.jobID)
    #expect(hosts.count == 4)
    #expect(hosts.allSatisfy { $0.state == .lost })
    #expect(await fixture.herdr.containsPane(foreignPaneID))
    #expect(await fixture.herdr.paneCount() == 2)
  }

  @Test("pause admission closes before a live result settles and replays without relaunch")
  func livePauseSettlement() async throws {
    let fixture = try await HerdrPiRuntimeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await fixture.runtime.setLaunchAllowed(true)
    let request = PiWorkflowExecutionRequest(
      jobID: "job-\(fixture.jobID.uuidString.lowercased())",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: fixture.artifactSHA256,
      sessionDirective: .fresh
    )
    let executor = fixture.runtime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    let execution = Task { try await executor.execute(request) }
    try await fixture.waitForEnqueuedCommand()

    await fixture.runtime.closeLaunchAdmission()
    try await fixture.configuration.setPaused(
      true,
      now: Date(timeIntervalSince1970: 2)
    )
    await fixture.runtime.waitForLaunchAdmissionDrain()
    async let result: Void = fixture.emitTriageResult()
    _ = try await execution.value
    try await result

    let run = try #require(try await fixture.runStore.runs().first)
    #expect(run.outcome == .released)
    #expect(await fixture.herdr.launchedCommands().count == 1)
    await #expect(throws: HerdrPiWorkflowError.launchSuppressed) {
      _ = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: request.jobID,
          workflow: request.workflow,
          role: request.role,
          round: 2,
          artifactSHA256: request.artifactSHA256,
          sessionDirective: .fresh
        )
      )
    }
  }

  @Test("durable enqueued state republishes one missing command after a crash window")
  func enqueuedCommandRecovery() async throws {
    let fixture = try await HerdrPiRuntimeFixture.make(timeoutSeconds: 600)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await fixture.runtime.setLaunchAllowed(true)
    let executor = fixture.runtime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    let request = PiWorkflowExecutionRequest(
      jobID: "job-\(fixture.jobID.uuidString.lowercased())",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: fixture.artifactSHA256,
      sessionDirective: .fresh
    )
    let first = Task { try await executor.execute(request) }
    try await fixture.removeEnqueuedCommand()
    await fixture.runtime.setLaunchAllowed(false)
    await #expect(throws: HerdrPiWorkflowError.launchSuppressed) {
      _ = try await executor.execute(request)
    }
    #expect(!(try await fixture.enqueuedCommandExists()))
    let recoveredRuntime = try fixture.reopenedRuntime()
    try await recoveredRuntime.recoverDurableState()
    await recoveredRuntime.setLaunchAllowed(true)
    let recoveredExecutor = recoveredRuntime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    let second = Task { try await recoveredExecutor.execute(request) }
    try await fixture.waitForEnqueuedCommand()
    async let failure: Void = fixture.emitRuntimeFailure()
    await #expect(throws: HerdrPiWorkflowError.runtimeFailure("FIXTURE_FAILURE")) {
      _ = try await first.value
    }
    await #expect(throws: HerdrPiWorkflowError.runtimeFailure("FIXTURE_FAILURE")) {
      _ = try await second.value
    }
    try await failure
    let run = try #require(try await fixture.runStore.runs().first)
    #expect(try await fixture.runStore.launches(runID: run.id).count == 1)
    #expect(
      try await fixture.runStore.events(runID: run.id).filter { $0.kind == .enqueued }.count == 1)
  }

  @Test("a moved persistent role host executes its next round in the rebound pane")
  func movedHostExecutesNextRound() async throws {
    let fixture = try await HerdrPiRuntimeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await fixture.runtime.setLaunchAllowed(true)
    let firstExecutor = fixture.runtime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    async let firstResult: Void = fixture.emitTriageResult(round: 1)
    _ = try await firstExecutor.execute(
      PiWorkflowExecutionRequest(
        jobID: "job-\(fixture.jobID.uuidString.lowercased())",
        workflow: .issueTriage,
        role: .triage,
        round: 1,
        artifactSHA256: fixture.artifactSHA256,
        sessionDirective: .fresh
      )
    )
    try await firstResult

    let movedPaneID = try await fixture.herdr.moveRolePane()
    let recovered = try fixture.reopenedRuntime()
    try await recovered.recoverDurableState()
    await recovered.setLaunchAllowed(true)
    let secondExecutor = recovered.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    async let secondResult: Void = fixture.emitTriageResult(round: 2)
    _ = try await secondExecutor.execute(
      PiWorkflowExecutionRequest(
        jobID: "job-\(fixture.jobID.uuidString.lowercased())",
        workflow: .issueTriage,
        role: .triage,
        round: 2,
        artifactSHA256: fixture.artifactSHA256,
        sessionDirective: .fresh
      )
    )
    try await secondResult

    let runs = try await fixture.runStore.runs()
    let secondRun = try #require(runs.first { $0.round == 2 })
    let secondLaunch = try #require(
      try await fixture.runStore.launches(runID: secondRun.id).last
    )
    let command = try #require(
      try HerdrRoleHostDescriptorStore.command(
        roleHostID: secondLaunch.roleHostID,
        sequence: secondLaunch.queueSequence,
        root: fixture.applicationSupport
          .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
      )
    )
    #expect(command.expectedWorkspaceID == "workspace-user-moved")
    #expect(command.expectedTabID == "tab-user-moved")
    #expect(command.expectedPaneID == movedPaneID)
    #expect(command.expectedTerminalID == "terminal-role-1")
    #expect(await fixture.herdr.launchedCommands().count == 1)
  }

  @Test("settled evidence survives topology rebind job recovery and durable pause")
  func freshTriageSettlement() async throws {
    let fixture = try await HerdrPiRuntimeFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await fixture.runtime.setLaunchAllowed(true)
    async let sideChannel: Void = fixture.emitTriageResult()
    let executor = fixture.runtime.makeExecutor(
      preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
    )
    let output = try await PiIssueTriageRouter(executor: executor).run(
      PiIssueTriageInput(
        jobID: "job-\(fixture.jobID.uuidString.lowercased())",
        artifactSHA256: fixture.artifactSHA256
      )
    )
    try await sideChannel

    #expect(output.effectiveVerdict == "human")
    #expect(output.result.verdict == "human")
    let runs = try await fixture.runStore.runs()
    let run = try #require(runs.first)
    #expect(runs.count == 1)
    #expect(run.outcome == .released)
    #expect(run.sessionBoundarySHA256?.count == 64)
    #expect(try await fixture.runStore.result(runID: run.id) != nil)
    #expect(
      try await fixture.runStore.events(runID: run.id).map(\.kind)
        == [.prepared, .enqueued, .resultPrepared, .settled, .acknowledged, .released]
    )
    let commands = await fixture.herdr.launchedCommands()
    #expect(commands.count == 1)
    #expect(commands[0] == ["/usr/bin/true", "--role-host-id", commands[0][2]])
    #expect(!commands.flatMap { $0 }.contains("agent.start"))
    #expect(!commands.flatMap { $0 }.contains("pi"))

    await fixture.herdr.replaceDisplayMetadataWithChildRun()
    let movedPaneID = try await fixture.herdr.moveRolePane()
    try await fixture.configuration.setPaused(
      true,
      now: Date(timeIntervalSince1970: 2)
    )
    let recoveredRuntime = try fixture.reopenedRuntime()
    try await recoveredRuntime.recoverDurableState()
    _ = try await fixture.jobs.recoverAtStartup(now: Date(timeIntervalSince1970: 3))
    #expect(try await fixture.jobs.job(id: fixture.jobID)?.state == .reconciliationQueued)
    let replayed = try await PiIssueTriageRouter(
      executor: recoveredRuntime.makeExecutor(
        preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
      )
    ).run(
      PiIssueTriageInput(
        jobID: "job-\(fixture.jobID.uuidString.lowercased())",
        artifactSHA256: fixture.artifactSHA256
      )
    )
    #expect(replayed.result == output.result)
    #expect(await fixture.herdr.launchedCommands().count == 1)
    let reboundHost = try #require(
      try await fixture.runStore.roleHosts(jobID: fixture.jobID).first
    )
    #expect(reboundHost.paneID == movedPaneID)
    #expect(reboundHost.workspaceID == "workspace-user-moved")
    #expect(reboundHost.tabID == "tab-user-moved")

    try await fixture.runStore.markRoleHostLost(
      id: reboundHost.id,
      now: Date(timeIntervalSince1970: 4)
    )
    try await fixture.runStore.markJobBindingLost(
      jobID: fixture.jobID,
      generation: 1,
      now: Date(timeIntervalSince1970: 4)
    )
    let repositoryWorkspaceID = try #require(
      try await fixture.runStore.repositoryBinding(repositoryID: fixture.repositoryID)?.workspaceID
    )
    _ = try await fixture.runStore.prepareJobBinding(
      jobID: fixture.jobID,
      repositoryID: fixture.repositoryID,
      generation: 2,
      workspaceID: repositoryWorkspaceID,
      now: Date(timeIntervalSince1970: 5)
    )
    let generationReplay = try await PiIssueTriageRouter(
      executor: recoveredRuntime.makeExecutor(
        preparer: PiJobWorkflowPreparer(context: fixture.workflowContext)
      )
    ).run(
      PiIssueTriageInput(
        jobID: "job-\(fixture.jobID.uuidString.lowercased())",
        artifactSHA256: fixture.artifactSHA256
      )
    )
    #expect(generationReplay.result == output.result)
    #expect(await fixture.herdr.launchedCommands().count == 1)
  }
}

private struct HerdrPiRuntimeFixture: Sendable {
  let root: URL
  let applicationSupport: URL
  let sessions: URL
  let workspace: URL
  let artifact: Data
  let artifactSHA256: String
  let repositoryID: UUID
  let jobID: UUID
  let runtime: HerdrPiWorkflowRuntime
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let resourceRoot: URL
  let runStore: PiRunStore
  let herdr: RuntimeFakeHerdrAPI
  let workflowContext: PiJobWorkflowContext

  static func make(
    kind: JobKind = .issueTriage,
    timeoutSeconds: TimeInterval = 30
  ) async throws -> Self {
    let root = try privateDirectory(name: "herdr-production-runtime")
    let applicationSupport = try childDirectory("app", in: root)
    let repositories = try childDirectory("Repositories", in: applicationSupport)
    let sessions = try childDirectory("Sessions", in: applicationSupport)
    let workspaces = try childDirectory("Workspaces", in: applicationSupport)
    let repositoryID = UUID(uuidString: "61000000-0000-0000-0000-000000000061")!
    let jobID = UUID(uuidString: "62000000-0000-0000-0000-000000000062")!
    _ = try childDirectory(repositoryID.uuidString.lowercased(), in: repositories)
    let workspace = try childDirectory(jobID.uuidString.lowercased(), in: workspaces)
    let database = try SQLiteStore(
      databaseURL: applicationSupport.appendingPathComponent("state.sqlite3")
    )
    try await insertRepositoryAndJob(
      database: database,
      repositoryID: repositoryID,
      jobID: jobID,
      kind: kind
    )
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(database: database)
    let runStore = PiRunStore(database: database)
    let herdr = try RuntimeFakeHerdrAPI(
      descriptorRoot:
        applicationSupport
        .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true),
      hostExecutable: URL(fileURLWithPath: "/usr/bin/true")
    )
    let mutationGate = HerdrTopologyMutationGate(initiallyAllowed: false)
    let topology = HerdrTopologyCoordinator(
      api: herdr,
      intents: SQLiteHerdrTopologyIntentStore(database: database),
      gate: mutationGate,
      mutationID: { "mutation-\(UUID().uuidString.lowercased())" }
    )
    let resourceRoot = sourceResourceRoot()
    let resolver = PiRuntimeResolver(configuration: .standard(resourceRoot: resourceRoot))
    let runtime = try HerdrPiWorkflowRuntime(
      applicationSupportRoot: applicationSupport,
      resourceRoot: resourceRoot,
      hostExecutable: URL(fileURLWithPath: "/usr/bin/true"),
      runtimeResolver: resolver,
      jobs: jobs,
      configuration: configuration,
      runs: runStore,
      api: herdr,
      topology: topology,
      mutationGate: mutationGate
    )
    let artifact = Data("Untrusted synthetic issue artifact.\n".utf8)
    let digest = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
    return Self(
      root: root,
      applicationSupport: applicationSupport,
      sessions: sessions,
      workspace: workspace,
      artifact: artifact,
      artifactSHA256: digest,
      repositoryID: repositoryID,
      jobID: jobID,
      runtime: runtime,
      database: database,
      configuration: configuration,
      jobs: jobs,
      resourceRoot: resourceRoot,
      runStore: runStore,
      herdr: herdr,
      workflowContext: PiJobWorkflowContext(
        artifact: artifact,
        workspaceRoot: workspace,
        sessionRoot: sessions,
        profiles: ModelProfileRole.allCases.map {
          ModelProfileConfiguration(
            role: $0,
            provider: "fixture",
            model: "fixture",
            thinking: .off
          )
        },
        allowedWritePaths: [],
        offline: true,
        timeoutSeconds: timeoutSeconds
      )
    )
  }

  func preparePartialTopology(kind: JobKind, startedCount: Int) async throws {
    let roles: [PiWorkflowRole]
    let workflows: Set<PiWorkflowKind>
    switch kind {
    case .issueTriage:
      roles = [.triage]
      workflows = [.issueTriage]
    case .prReview:
      roles = [.architecture, .security, .test, .synthesis]
      workflows = [.pullRequestReview]
    case .issueImplementation, .complexPlan:
      roles = [.writer, .architecture, .security, .test, .synthesis]
      workflows = [.planning, .orchestration]
    }
    guard (0..<roles.count).contains(startedCount) else {
      throw HerdrTopologyError.invalidPlan
    }
    let canonicalApplicationSupport = applicationSupport.standardizedFileURL
    let repositoryRoot =
      canonicalApplicationSupport
      .appendingPathComponent("Repositories", isDirectory: true)
      .appendingPathComponent(repositoryID.uuidString.lowercased(), isDirectory: true)
    let descriptorRoot =
      canonicalApplicationSupport
      .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
    let gate = HerdrTopologyMutationGate(initiallyAllowed: true)
    let topology = HerdrTopologyCoordinator(
      api: herdr,
      intents: SQLiteHerdrTopologyIntentStore(database: database),
      gate: gate,
      mutationID: { "partial-mutation-\(UUID().uuidString.lowercased())" }
    )
    let workspacePlan = try HerdrWorkspacePlan(
      repositoryID: repositoryID.uuidString.lowercased(),
      repositoryRoot: repositoryRoot,
      workspaceLabel: "Jidoka | owner/repository",
      boundWorkspaceID: nil
    )
    let workspaceBinding = try await topology.ensureWorkspace(
      for: workspacePlan,
      jobID: jobID.uuidString.lowercased(),
      generation: 1
    )
    _ = try await runStore.bindRepository(
      repositoryID: repositoryID,
      workspaceID: workspaceBinding.workspaceID,
      identityRoot: repositoryRoot,
      handshake: workspaceBinding.handshake,
      now: Date(timeIntervalSince1970: 2)
    )
    _ = try await runStore.prepareJobBinding(
      jobID: jobID,
      repositoryID: repositoryID,
      generation: 1,
      workspaceID: workspaceBinding.workspaceID,
      now: Date(timeIntervalSince1970: 2)
    )
    let executable = try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: "/usr/bin/true")
    )
    let executableDigest = SHA256.hash(
      data: try Data(contentsOf: executable, options: [.mappedIfSafe])
    ).map { String(format: "%02x", $0) }.joined()
    var plans: [HerdrHostLaunchPlan] = []
    var hostIDs: [String] = []
    for (index, role) in roles.enumerated() {
      let hostID = "rolehost-\(index)-\(UUID().uuidString.lowercased())"
      hostIDs.append(hostID)
      let alias = "jc-\(jobID.uuidString.lowercased().prefix(8))-\(role.rawValue)"
      let bootstrap = try HerdrRoleHostBootstrapDescriptor(
        roleHostID: hostID,
        repositoryID: repositoryID.uuidString.lowercased(),
        jobID: jobID.uuidString.lowercased(),
        generation: 1,
        role: role,
        allowedWorkflows: workflows,
        expectedWorkspaceID: workspaceBinding.workspaceID,
        workingDirectory: workspace.standardizedFileURL,
        agentAlias: alias,
        title: "Jidoka \(role.rawValue)",
        displayAgent: "Jidoka | \(role.rawValue)",
        hostExecutable: executable
      )
      let descriptorDigest = try HerdrRoleHostDescriptorStore.prepare(
        bootstrap,
        in: descriptorRoot
      )
      _ = try await runStore.prepareRoleHost(
        id: hostID,
        jobID: jobID,
        generation: 1,
        role: role,
        workspaceID: workspaceBinding.workspaceID,
        bootstrapDescriptorSHA256: descriptorDigest,
        hostExecutableSHA256: executableDigest,
        now: Date(timeIntervalSince1970: 2)
      )
      plans.append(
        try HerdrHostLaunchPlan(
          roleHostID: hostID,
          role: role,
          paneLabel: role.rawValue,
          agentAlias: alias,
          hostExecutable: executable,
          descriptorRoot: descriptorRoot,
          workingDirectory: workspace.standardizedFileURL
        )
      )
    }
    _ = try await topology.ensureJobTab(
      for: HerdrTopologyPlan(
        repositoryID: repositoryID.uuidString.lowercased(),
        repositoryRoot: repositoryRoot,
        workspaceLabel: "Jidoka | owner/repository",
        boundWorkspaceID: workspaceBinding.workspaceID,
        jobID: jobID.uuidString.lowercased(),
        generation: 1,
        tabLabel: "Job \(jobID.uuidString.lowercased().prefix(8))-g1",
        launches: plans
      ),
      workspace: workspaceBinding
    )
    for hostID in hostIDs.dropFirst(startedCount) {
      try FileManager.default.removeItem(
        at: descriptorRoot.appendingPathComponent(hostID, isDirectory: true)
          .appendingPathComponent("host-start.json")
      )
    }
  }

  func reopenedRuntime() throws -> HerdrPiWorkflowRuntime {
    let mutationGate = HerdrTopologyMutationGate(initiallyAllowed: false)
    let topology = HerdrTopologyCoordinator(
      api: herdr,
      intents: SQLiteHerdrTopologyIntentStore(database: database),
      gate: mutationGate,
      mutationID: { "recovery-mutation-\(UUID().uuidString.lowercased())" }
    )
    return try HerdrPiWorkflowRuntime(
      applicationSupportRoot: applicationSupport,
      resourceRoot: resourceRoot,
      hostExecutable: URL(fileURLWithPath: "/usr/bin/true"),
      runtimeResolver: PiRuntimeResolver(
        configuration: .standard(resourceRoot: resourceRoot)
      ),
      jobs: jobs,
      configuration: configuration,
      runs: runStore,
      api: herdr,
      topology: topology,
      mutationGate: mutationGate
    )
  }

  func removeEnqueuedCommand() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 660
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let run = try await runStore.runs().first,
        let launch = try await runStore.launches(runID: run.id).last,
        launch.state == .enqueued,
        let command = try HerdrRoleHostDescriptorStore.command(
          roleHostID: launch.roleHostID,
          sequence: launch.queueSequence,
          root:
            applicationSupport
            .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
        )
      {
        #expect(command.launchAttemptID == launch.launchAttemptID)
        let url =
          applicationSupport
          .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
          .appendingPathComponent(launch.roleHostID, isDirectory: true)
          .appendingPathComponent(String(format: "command-%08d.json", launch.queueSequence))
        try FileManager.default.removeItem(at: url)
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HerdrPiWorkflowError.timedOut
  }

  func enqueuedCommandExists() async throws -> Bool {
    guard let run = try await runStore.runs().first,
      let launch = try await runStore.launches(runID: run.id).last
    else { return false }
    return try HerdrRoleHostDescriptorStore.command(
      roleHostID: launch.roleHostID,
      sequence: launch.queueSequence,
      root:
        applicationSupport
        .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
    ) != nil
  }

  func waitForEnqueuedCommand() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 660
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let run = try await runStore.runs().first,
        let launch = try await runStore.launches(runID: run.id).last,
        try HerdrRoleHostDescriptorStore.command(
          roleHostID: launch.roleHostID,
          sequence: launch.queueSequence,
          root:
            applicationSupport
            .appendingPathComponent("HerdrRuntime/Descriptors", isDirectory: true)
        ) != nil
      {
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HerdrPiWorkflowError.timedOut
  }

  func emitRuntimeFailure() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 660
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let run = try await runStore.runs().first,
        let launch = try await runStore.launches(runID: run.id).last,
        launch.state == .enqueued
      {
        let object: [String: Any] = [
          "code": "FIXTURE_FAILURE",
          "runID": run.id,
          "runNonce": run.runNonce,
          "schemaVersion": 1,
          "status": "failed",
        ]
        try PiTUIFileProtocol.createPrivateFile(
          data: try PiTUIFileProtocol.canonicalJSONData(object),
          at: URL(fileURLWithPath: run.channelPath, isDirectory: true)
            .appendingPathComponent(PiTUIResultChannel.runtimeFailureFileName)
        )
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HerdrPiWorkflowError.timedOut
  }

  func emitTriageResult(round: Int = 1) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 660
    var run: PiRunRecord?
    var launch: PiRunLaunchRecord?
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let candidate = try await runStore.runs().first(where: { $0.round == round }) {
        let launches = try await runStore.launches(runID: candidate.id)
        if let candidateLaunch = launches.last, candidateLaunch.state == .enqueued {
          run = candidate
          launch = candidateLaunch
          break
        }
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let durableRun = try #require(run)
    let durableLaunch = try #require(launch)
    let channel = URL(fileURLWithPath: durableRun.channelPath, isDirectory: true)
    let workflow = try PiWorkflowRuntimeConfiguration.load(
      from: channel.appendingPathComponent("workflow.json")
    )
    let tui = try PiTUIRunConfiguration.load(
      from: channel.appendingPathComponent("tui-\(durableLaunch.launchAttemptID).json")
    )
    let sessionID = UUID().uuidString.lowercased()
    let sessionFile = tui.sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
    try PiTUIFileProtocol.createPrivateFile(
      data: Data("{\"type\":\"session\"}\n".utf8),
      at: sessionFile
    )
    try PiTUIFileProtocol.createPrivateFile(
      data: try PiTUIFileProtocol.canonicalJSONData([
        "originLaunchMode": "fresh",
        "originResumeBoundarySHA256": NSNull(),
        "runID": durableRun.id,
        "runNonce": durableRun.runNonce,
        "schemaVersion": 2,
        "sessionFile": sessionFile.path,
        "sessionID": sessionID,
      ]),
      at: channel.appendingPathComponent("session.json")
    )
    let payload: [String: Any] = [
      "complexityGuess": "humanOwned",
      "hardRiskFlags": ["security-or-secret-core"],
      "questions": [String](),
      "rationale": "Synthetic production-runtime result.",
      "rubric": [
        "bounded": "yes", "safe": "human", "specified": "yes", "testable": "yes",
      ],
      "severity": "major",
      "summary": "Synthetic visible Herdr triage result.",
      "verdict": "human",
    ]
    let boundaryObject: [String: Any] = [
      "approvedCommandIDs": [String](),
      "artifactSHA256": workflow.artifactSHA256,
      "nonce": workflow.nonce,
      "payload": payload,
      "resultSequence": 1,
      "role": workflow.role.rawValue,
      "schemaVersion": 1,
      "workflow": workflow.workflow.rawValue,
    ]
    let boundaryData = try PiTUIFileProtocol.canonicalJSONData(boundaryObject)
    var resultObject = boundaryObject
    resultObject.removeValue(forKey: "resultSequence")
    resultObject["runID"] = durableRun.id
    resultObject["runNonce"] = durableRun.runNonce
    resultObject["sessionBoundarySHA256"] = PiTUIFileProtocol.sha256(
      Data(boundaryData.dropLast())
    )
    try PiTUIFileProtocol.createPrivateFile(
      data: try PiTUIFileProtocol.canonicalJSONData(resultObject),
      at: channel.appendingPathComponent(PiTUIResultChannel.resultFileName)
    )
    while ProcessInfo.processInfo.systemUptime < deadline {
      if FileManager.default.fileExists(
        atPath: channel.appendingPathComponent(PiTUIResultChannel.releaseFileName).path
      ) {
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HerdrPiWorkflowError.timedOut
  }

  private static func privateDirectory(name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(name)-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return try PiTUIFileProtocol.canonicalExistingURL(root)
  }

  private static func childDirectory(_ name: String, in parent: URL) throws -> URL {
    let child = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: child,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return try PiTUIFileProtocol.canonicalExistingURL(child)
  }

  private static func sourceResourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
  }

  private static func insertRepositoryAndJob(
    database: SQLiteStore,
    repositoryID: UUID,
    jobID: UUID,
    kind: JobKind
  ) async throws {
    _ = try await database.execute(
      """
      INSERT INTO repositories(
        id, node_id, owner, name, default_branch,
        review_enabled, triage_enabled, implementation_enabled, enabled,
        created_at, updated_at
      ) VALUES (?, 'repository-node', 'owner', 'repository', 'main', 1, 1, 1, 1, 1, 1)
      """,
      bindings: [.text(repositoryID.uuidString.lowercased())]
    )
    _ = try await database.execute(
      """
      INSERT INTO jobs(
        id, repository_id, kind, object_node_id, object_number, revision_key,
        contract_version_used, priority, state, current_step, current_step_kind,
        attempt, created_at, updated_at
      ) VALUES (?, ?, ?, 'issue-node', 1, 'fixture-revision',
        'test', 4, 'runningPi', 0, ?, 1, 1, 1)
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .text(repositoryID.uuidString.lowercased()),
        .text(kind.rawValue),
        .text(kind == .issueTriage ? "triage" : (kind == .prReview ? "review" : "plan")),
      ]
    )
  }
}

private actor RuntimeFakeHerdrAPI: HerdrTopologyAPI, HerdrPiRuntimeAPI {
  private let descriptorRoot: URL
  private let hostExecutable: URL
  private let hostExecutableSHA256: String
  private let identity: HerdrHostProcessIdentity
  private let socketIdentity = HerdrSocketIdentity(
    device: 71,
    inode: 72,
    owner: UInt32(geteuid()),
    permissions: 0o600
  )
  private var workspace: HerdrWorkspaceSnapshot?
  private var tabs: [HerdrTabSnapshot] = []
  private var panes: [HerdrPaneSnapshot] = []
  private var layouts: [String: HerdrLayoutDescription] = [:]
  private var commands: [[String]] = []
  private var roleHostsByPane: [String: String] = [:]
  private var failHandshake = false
  private var failedProcessInfoPaneID: String?

  init(descriptorRoot: URL, hostExecutable: URL) throws {
    self.descriptorRoot = descriptorRoot
    self.hostExecutable = try PiTUIFileProtocol.canonicalExistingURL(hostExecutable)
    let data = try Data(contentsOf: hostExecutable, options: [.mappedIfSafe])
    hostExecutableSHA256 = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined()
    identity = try HerdrRoleHostRuntime.processIdentity(getpid())
  }

  func handshake() throws -> HerdrHandshake {
    if failHandshake {
      failHandshake = false
      throw HerdrSocketClientError.connectionClosed
    }
    return HerdrHandshake(
      pong: HerdrPong(
        version: "0.8.0",
        protocolVersion: 19,
        capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
      ),
      snapshot: snapshot(),
      socketIdentity: socketIdentity
    )
  }

  func createWorkspace(
    _ parameters: HerdrWorkspaceCreateParameters,
    attestedBy _: HerdrHandshake
  ) -> HerdrWorkspaceCreatedResult {
    let createdWorkspace = HerdrWorkspaceSnapshot(
      workspaceID: "workspace-runtime",
      activeTabID: "tab-root",
      label: parameters.label,
      number: 1,
      paneCount: 1,
      tabCount: 1,
      focused: false,
      agentStatus: .idle,
      tokens: nil,
      worktree: nil
    )
    let tab = HerdrTabSnapshot(
      tabID: "tab-root",
      workspaceID: createdWorkspace.workspaceID,
      label: "root",
      number: 1,
      paneCount: 1,
      focused: false,
      agentStatus: .idle
    )
    let pane = Self.pane(
      paneID: "pane-root",
      terminalID: "terminal-root",
      workspaceID: createdWorkspace.workspaceID,
      tabID: tab.tabID,
      cwd: parameters.cwd,
      label: "root",
      tokens: nil
    )
    workspace = createdWorkspace
    tabs = [tab]
    panes = [pane]
    return HerdrWorkspaceCreatedResult(
      type: "workspace_create",
      workspace: createdWorkspace,
      tab: tab,
      rootPane: pane
    )
  }

  func applyLayout(
    _ parameters: HerdrLayoutApplyParameters,
    attestedBy _: HerdrHandshake
  ) throws -> HerdrLayoutApplyResult {
    var nextPane = 1
    var createdPanes: [HerdrPaneSnapshot] = []
    func bind(_ node: HerdrLayoutNode) throws -> HerdrLayoutNode {
      switch node {
      case .pane(let source):
        let paneID = "pane-role-\(nextPane)"
        let terminalID = "terminal-role-\(nextPane)"
        nextPane += 1
        guard let command = source.command, command.count == 3,
          command[0] == hostExecutable.path,
          command[1] == "--role-host-id"
        else {
          throw HerdrTopologyError.invalidPlan
        }
        let roleHostID = command[2]
        commands.append(command)
        roleHostsByPane[paneID] = roleHostID
        try HerdrRoleHostDescriptorStore.recordStart(
          roleHostID: roleHostID,
          identity: HerdrRoleHostRuntimeIdentity(
            process: identity,
            executable: hostExecutable,
            executableSHA256: hostExecutableSHA256
          ),
          root: descriptorRoot
        )
        createdPanes.append(
          Self.pane(
            paneID: paneID,
            terminalID: terminalID,
            workspaceID: parameters.workspaceID,
            tabID: "tab-job",
            cwd: source.workingDirectory,
            label: source.label,
            tokens: [
              "launch_attempt_id": roleHostID,
              "managed_by": "jidoka",
              "run_id": roleHostID,
            ]
          )
        )
        return .pane(
          HerdrLayoutPane(
            paneID: paneID,
            label: source.label,
            workingDirectory: source.workingDirectory,
            command: command,
            environment: source.environment
          )
        )
      case .split(let split):
        return .split(
          HerdrLayoutSplit(
            direction: split.direction,
            ratio: split.ratio,
            first: try bind(split.first),
            second: try bind(split.second)
          )
        )
      }
    }
    let boundRoot = try bind(parameters.root)
    let tab = HerdrTabSnapshot(
      tabID: "tab-job",
      workspaceID: parameters.workspaceID,
      label: parameters.tabLabel,
      number: 2,
      paneCount: createdPanes.count,
      focused: false,
      agentStatus: .idle
    )
    tabs.append(tab)
    panes.append(contentsOf: createdPanes)
    workspace = workspace.map {
      HerdrWorkspaceSnapshot(
        workspaceID: $0.workspaceID,
        activeTabID: $0.activeTabID,
        label: $0.label,
        number: $0.number,
        paneCount: panes.count,
        tabCount: tabs.count,
        focused: false,
        agentStatus: .idle,
        tokens: $0.tokens,
        worktree: $0.worktree
      )
    }
    let layout = HerdrLayoutDescription(
      workspaceID: parameters.workspaceID,
      tabID: tab.tabID,
      zoomed: false,
      focusedPaneID: createdPanes[0].paneID,
      root: boundRoot
    )
    layouts[tab.tabID] = layout
    return HerdrLayoutApplyResult(type: "layout_apply", layout: layout)
  }

  func exportLayout(
    tabID: String,
    attestedBy _: HerdrHandshake
  ) throws -> HerdrLayoutDescription {
    guard let layout = layouts[tabID] else { throw HerdrTopologyError.invalidResponse }
    return layout
  }

  func processInfo(
    paneID: String,
    attestedBy _: HerdrHandshake
  ) throws -> HerdrPaneProcessInfo {
    if paneID == failedProcessInfoPaneID {
      throw HerdrTopologyError.bindingLost
    }
    guard panes.contains(where: { $0.paneID == paneID }),
      let roleHostID = roleHostsByPane[paneID]
    else {
      throw HerdrTopologyError.bindingLost
    }
    return HerdrPaneProcessInfo(
      paneID: paneID,
      shellProcessID: nil,
      foregroundProcessGroupID: UInt32(identity.processID),
      foregroundProcesses: [
        HerdrPaneProcessSnapshot(
          processID: UInt32(identity.processID),
          name: hostExecutable.lastPathComponent,
          arguments: [hostExecutable.path, "--role-host-id", roleHostID],
          argumentZero: hostExecutable.path,
          commandLine: nil,
          workingDirectory: panes.first(where: { $0.paneID == paneID })?.cwd
        )
      ],
      tty: nil
    )
  }

  func closePane(
    paneID: String,
    terminalID: String,
    attestedBy _: HerdrHandshake
  ) throws {
    guard panes.contains(where: { $0.paneID == paneID && $0.terminalID == terminalID }) else {
      throw HerdrTopologyError.bindingLost
    }
    panes.removeAll { $0.paneID == paneID }
  }

  func launchedCommands() -> [[String]] { commands }

  func failNextHandshake() { failHandshake = true }

  func failRoleProcessInfo(index: Int) {
    failedProcessInfoPaneID = "pane-role-\(index)"
  }

  func renameJobTabAndAddDuplicateLabel() {
    let originalLabel = "Job 62000000-g1"
    tabs = tabs.map { tab in
      guard tab.tabID == "tab-job" else { return tab }
      return HerdrTabSnapshot(
        tabID: tab.tabID,
        workspaceID: tab.workspaceID,
        label: "user-renamed-job-tab",
        number: tab.number,
        paneCount: tab.paneCount,
        focused: tab.focused,
        agentStatus: tab.agentStatus
      )
    }
    if !tabs.contains(where: { $0.tabID == "tab-foreign-duplicate" }) {
      tabs.append(
        HerdrTabSnapshot(
          tabID: "tab-foreign-duplicate",
          workspaceID: "workspace-runtime",
          label: originalLabel,
          number: 99,
          paneCount: 0,
          focused: false,
          agentStatus: .idle
        )
      )
    }
  }

  func takeOverRolePane() throws -> String {
    guard let pane = panes.first(where: { roleHostsByPane[$0.paneID] != nil }) else {
      throw HerdrTopologyError.bindingLost
    }
    roleHostsByPane.removeValue(forKey: pane.paneID)
    return pane.paneID
  }

  func containsPane(_ paneID: String) -> Bool {
    panes.contains { $0.paneID == paneID }
  }

  func paneCount() -> Int { panes.count }

  func moveRolePane() throws -> String {
    guard let index = panes.firstIndex(where: { roleHostsByPane[$0.paneID] != nil }),
      let roleHostID = roleHostsByPane[panes[index].paneID]
    else {
      throw HerdrTopologyError.bindingLost
    }
    let prior = panes[index]
    let movedPaneID = "\(prior.paneID)-moved"
    panes[index] = Self.pane(
      paneID: movedPaneID,
      terminalID: prior.terminalID,
      workspaceID: "workspace-user-moved",
      tabID: "tab-user-moved",
      cwd: prior.cwd,
      label: prior.label,
      tokens: prior.tokens
    )
    roleHostsByPane.removeValue(forKey: prior.paneID)
    roleHostsByPane[movedPaneID] = roleHostID
    return movedPaneID
  }

  func replaceDisplayMetadataWithChildRun() {
    panes = panes.map { pane in
      guard roleHostsByPane[pane.paneID] != nil else { return pane }
      return Self.pane(
        paneID: pane.paneID,
        terminalID: pane.terminalID,
        workspaceID: pane.workspaceID,
        tabID: pane.tabID,
        cwd: pane.cwd,
        label: pane.label,
        tokens: [
          "launch_attempt_id": "launch-child-display",
          "managed_by": "jidoka",
          "run_id": "run-child-display",
        ]
      )
    }
  }

  private func snapshot() -> HerdrSessionSnapshot {
    HerdrSessionSnapshot(
      version: "0.8.0",
      protocolVersion: 19,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: workspace.map { [$0] } ?? [],
      tabs: tabs,
      panes: panes,
      agents: []
    )
  }

  private static func pane(
    paneID: String,
    terminalID: String,
    workspaceID: String,
    tabID: String,
    cwd: String?,
    label: String?,
    tokens: [String: String]?
  ) -> HerdrPaneSnapshot {
    HerdrPaneSnapshot(
      paneID: paneID,
      terminalID: terminalID,
      workspaceID: workspaceID,
      tabID: tabID,
      revision: 1,
      focused: false,
      agentStatus: .idle,
      cwd: cwd,
      foregroundCWD: cwd,
      label: label,
      agent: nil,
      displayAgent: nil,
      title: nil,
      stateLabels: nil,
      tokens: tokens,
      agentSession: nil
    )
  }
}
