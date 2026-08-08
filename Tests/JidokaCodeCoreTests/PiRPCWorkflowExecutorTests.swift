import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Pi RPC workflow adapter")
struct PiRPCWorkflowExecutorTests {
  private let artifact = String(repeating: "a", count: 64)

  @Test("validated canonical launch becomes one settled typed workflow execution")
  func typedExecution() async throws {
    let fixture = try RPCExecutorFixture(artifact: artifact)
    defer { fixture.remove() }
    let processRequest = try fixture.makeProcessRequest(
      workflow: .issueTriage,
      role: .triage
    )
    let runner = FixedRPCRunner(result: makeProcessResult())
    let executor = fixture.executor(request: processRequest, runner: runner)
    let request = PiWorkflowExecutionRequest(
      jobID: "rpc-adapter-1",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: artifact,
      sessionDirective: .fresh
    )

    let execution = try await executor.execute(request)

    #expect(execution.sessionID == "typed-session")
    #expect(execution.agentSettledCount == 1)
    #expect(execution.extensionErrorCount == 0)
    guard case .issueTriage(let payload) = execution.result.payload else {
      Issue.record("adapter decoded the wrong payload")
      return
    }
    #expect(payload.verdict == "human")
    #expect(await runner.callCount() == 1)
  }

  @Test("preparer cannot change workflow, role, or artifact identity")
  func preparationIdentityMismatch() async throws {
    let fixture = try RPCExecutorFixture(artifact: artifact)
    defer { fixture.remove() }
    let processRequest = try fixture.makeProcessRequest(workflow: .planning, role: .writer)
    let runner = FixedRPCRunner(result: makeProcessResult())
    let executor = fixture.executor(request: processRequest, runner: runner)

    await #expect(throws: PiRPCWorkflowExecutorError.preparationIdentityMismatch) {
      try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: "rpc-adapter-2",
          workflow: .issueTriage,
          role: .triage,
          round: 1,
          artifactSHA256: artifact,
          sessionDirective: .fresh
        )
      )
    }
    #expect(await runner.callCount() == 0)
  }

  @Test("preparer cannot replace session, environment, or role tool policy")
  func preparationSessionAndBoundaryMismatch() async throws {
    let fixture = try RPCExecutorFixture(artifact: artifact)
    defer { fixture.remove() }
    let runner = FixedRPCRunner(result: makeProcessResult())
    let workflowRequest = PiWorkflowExecutionRequest(
      jobID: "rpc-adapter-boundary",
      workflow: .issueTriage,
      role: .triage,
      round: 2,
      artifactSHA256: artifact,
      sessionDirective: .resume("12345678-1234-1234-1234-123456789abc")
    )

    let freshRequest = try fixture.makeProcessRequest(workflow: .issueTriage, role: .triage)
    await #expect(throws: PiRPCWorkflowExecutorError.preparationSessionMismatch) {
      try await fixture.executor(request: freshRequest, runner: runner).execute(workflowRequest)
    }

    let fixturePolicyRequest = try fixture.makeProcessRequest(
      workflow: .issueTriage,
      role: .triage,
      environmentPolicy: .deterministicFixture
    )
    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(request: fixturePolicyRequest, runner: runner).execute(
        PiWorkflowExecutionRequest(
          jobID: "rpc-adapter-fixture",
          workflow: .issueTriage,
          role: .triage,
          round: 1,
          artifactSHA256: artifact,
          sessionDirective: .fresh
        )
      )
    }

    let wrongToolsRequest = try fixture.makeProcessRequest(
      workflow: .issueTriage,
      role: .triage,
      allowedToolNames: ["jidoka_code_result"]
    )
    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(request: wrongToolsRequest, runner: runner).execute(
        PiWorkflowExecutionRequest(
          jobID: "rpc-adapter-tools",
          workflow: .issueTriage,
          role: .triage,
          round: 1,
          artifactSHA256: artifact,
          sessionDirective: .fresh
        )
      )
    }
    #expect(await runner.callCount() == 0)
  }

  @Test("arbitrary Node scripts and non-bundled provenance never reach the runner")
  func canonicalLaunchBoundary() async throws {
    let fixture = try RPCExecutorFixture(artifact: artifact)
    defer { fixture.remove() }
    let runner = FixedRPCRunner(result: makeProcessResult())
    let workflowRequest = PiWorkflowExecutionRequest(
      jobID: "rpc-adapter-launch",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: artifact,
      sessionDirective: .fresh
    )

    let arbitrary = try fixture.makeProcessRequest(
      workflow: .issueTriage,
      role: .triage,
      executable: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["/tmp/arbitrary.mjs", "--tools", "jidoka_code_result"]
    )
    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(request: arbitrary, runner: runner).execute(workflowRequest)
    }

    let foreignProvenance = PiRPCSessionExpectation(
      provider: "fixture",
      modelID: "fixture",
      thinkingLevel: "off",
      commands: [
        PiRPCCommandProvenance(
          name: "skill:foreign",
          source: "skill",
          path: "/not/a/bundled/skill",
          scope: "temporary",
          origin: "top-level"
        )
      ]
    )
    let foreign = try fixture.makeProcessRequest(
      workflow: .issueTriage,
      role: .triage,
      sessionExpectation: foreignProvenance
    )
    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(request: foreign, runner: runner).execute(workflowRequest)
    }
    #expect(await runner.callCount() == 0)
  }

  private func makeProcessResult() -> PiRPCExecutionResult {
    PiRPCExecutionResult(
      sessionID: "typed-session",
      terminalResult: PiRPCTerminalResult(
        workflow: "issue-triage",
        role: "triage",
        nonce: "nonce-adapter-1",
        artifactSHA256: artifact,
        approvedCommandIDs: [],
        payload: [
          "complexityGuess": .string("complex"),
          "hardRiskFlags": .array([.string("security-or-secret-core")]),
          "questions": .array([]),
          "rationale": .string("Credential work remains human-owned."),
          "rubric": .object([
            "bounded": .string("bounded"),
            "safe": .string("not safe for automation"),
            "specified": .string("specified"),
            "testable": .string("testable only under human ownership"),
          ]),
          "severity": .string("major"),
          "summary": .string("Escalate."),
          "verdict": .string("human"),
        ],
        recordSHA256: String(repeating: "b", count: 64)
      ),
      stdoutSHA256: String(repeating: "c", count: 64),
      stderrSHA256: String(repeating: "d", count: 64),
      durationSeconds: 0.1,
      abortAcknowledged: false,
      cleanupVerified: true
    )
  }
}

private final class RPCExecutorFixture {
  let root: URL
  let resourceRoot: URL
  let runtime: PiResolvedRuntime
  private let sessionDirectory: URL
  private let homeDirectory: URL
  private let agentDirectory: URL
  private let temporaryDirectory: URL
  private let workspace: URL
  private let artifact: String
  private let resources: PiWorkflowResourceCatalog

  init(artifact: String) throws {
    self.artifact = artifact
    resourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .resolvingSymlinksInPath()
    resources = try PiWorkflowResourceCatalog.inspect(resourceRoot: resourceRoot)
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-rpc-executor-\(UUID().uuidString)",
      isDirectory: true
    ).resolvingSymlinksInPath()
    sessionDirectory = root.appendingPathComponent("session", isDirectory: true)
    homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)
    workspace = root.appendingPathComponent("workspace", isDirectory: true)
    for directory in [
      root, sessionDirectory, homeDirectory, agentDirectory, temporaryDirectory, workspace,
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
    runtime = PiResolvedRuntime(
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

  func makeProcessRequest(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    environmentPolicy: PiRPCEnvironmentPolicy = .locked,
    allowedToolNames: [String]? = nil,
    executable: URL? = nil,
    arguments: [String]? = nil,
    sessionExpectation: PiRPCSessionExpectation? = nil
  ) throws -> PiRPCProcessRequest {
    let tools = try PiWorkflowResourceCatalog.activeToolNames(workflow: workflow, role: role)
    let configuration = try PiWorkflowRuntimeConfiguration(
      workflow: workflow,
      role: role,
      nonce: "nonce-adapter-1",
      artifactSHA256: artifact,
      allowedCommandIDs: [],
      allowedWritePaths: [],
      workspaceRoot: workspace,
      resources: resources
    )
    let configurationURL = temporaryDirectory.appendingPathComponent(
      "configuration-\(UUID().uuidString).json"
    )
    try configuration.write(to: configurationURL)
    let model = "fixture/fixture:off"
    let canonicalArguments = try PiRPCInvocationBuilder.arguments(
      runtime: runtime,
      model: model,
      sessionDirectory: sessionDirectory,
      sessionName: "jidoka-code-rpc-adapter",
      blockerExtension: resources.blockerExtensionURL,
      runtimeExtension: resources.runtimeExtensionURL,
      skills: resources.skillURLs(workflow: workflow, role: role),
      activeTools: tools,
      session: .fresh
    )
    let environment = try PiRPCInvocationBuilder.environment(
      homeDirectory: homeDirectory,
      agentDirectory: agentDirectory,
      temporaryDirectory: temporaryDirectory,
      workflowConfiguration: configurationURL,
      offline: true
    )
    let canonicalSessionExpectation = PiRPCSessionExpectation(
      provider: "fixture",
      modelID: "fixture",
      thinkingLevel: "off",
      commands: try resources.expectedCommandProvenance(workflow: workflow, role: role)
    )
    return PiRPCProcessRequest(
      executable: executable ?? runtime.nodeURL,
      arguments: arguments ?? canonicalArguments,
      workingDirectory: workspace,
      environment: environment,
      prompt: "fixture",
      sessionExpectation: sessionExpectation ?? canonicalSessionExpectation,
      terminalIdentity: PiRPCTerminalResultIdentity(
        workflow: workflow.rawValue,
        role: role.rawValue,
        nonce: "nonce-adapter-1",
        artifactSHA256: artifact,
        allowedCommandIDs: []
      ),
      allowedToolNames: allowedToolNames ?? tools,
      timeoutSeconds: 1,
      environmentPolicy: environmentPolicy
    )
  }

  func executor(
    request: PiRPCProcessRequest,
    runner: FixedRPCRunner
  ) -> PiRPCWorkflowExecutor {
    PiRPCWorkflowExecutor(
      preparer: FixedRPCPreparer(request: request),
      runtimeResolver: FixedRuntimeResolver(runtime: runtime),
      resourceRoot: resourceRoot,
      runner: runner
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct FixedRuntimeResolver: PiRuntimeResolving {
  let runtime: PiResolvedRuntime

  func resolve() throws -> PiResolvedRuntime { runtime }
}

private struct FixedRPCPreparer: PiRPCWorkflowPreparing {
  let request: PiRPCProcessRequest

  func prepare(_ request: PiWorkflowExecutionRequest) async throws -> PiRPCProcessRequest {
    self.request
  }
}

private actor FixedRPCRunner: PiRPCProcessRunning {
  private let result: PiRPCExecutionResult
  private var calls = 0

  init(result: PiRPCExecutionResult) {
    self.result = result
  }

  func run(_ request: PiRPCProcessRequest) async throws -> PiRPCExecutionResult {
    calls += 1
    return result
  }

  func callCount() -> Int { calls }
}
