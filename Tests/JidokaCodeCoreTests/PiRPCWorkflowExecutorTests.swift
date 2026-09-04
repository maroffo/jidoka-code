import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Pi RPC workflow adapter")
struct PiRPCWorkflowExecutorTests {
  private let artifact = String(repeating: "a", count: 64)

  @Test("executor constructs the canonical launch from application-only preparation")
  func typedExecution() async throws {
    let fixture = try RPCExecutorFixture()
    defer { fixture.remove() }
    let runner = CapturingRPCRunner()
    let executor = fixture.executor(
      preparation: fixture.preparation(role: .triage),
      runner: runner
    )
    let request = workflowRequest()

    let execution = try await executor.execute(request)

    #expect(execution.sessionID == "typed-session")
    #expect(fixture.runtimeResolver.boundaryCounts == [.rpcProcess: 1])
    #expect(
      fixture.runtimeResolver.releaseIdentities[.rpcProcess]
        == [try #require(fixture.runtime.releaseIdentity)]
    )
    #expect(execution.agentSettledCount == 1)
    #expect(execution.extensionErrorCount == 0)
    guard case .issueTriage(let payload) = execution.result.payload else {
      Issue.record("adapter decoded the wrong payload")
      return
    }
    #expect(payload.verdict == "human")
    let launched = try #require(await runner.lastRequest())
    #expect(launched.executable == fixture.runtime.nodeURL)
    #expect(launched.environmentPolicy == .locked)
    #expect(launched.workingDirectory == fixture.workspace)
    #expect(
      launched.allowedToolNames
        == PiWorkflowResourceCatalog.readOnlyToolNames
    )
    #expect(launched.arguments.first == fixture.runtime.piCLIURL.path)
    #expect(!launched.arguments.contains("/tmp/arbitrary.mjs"))
    #expect(launched.environment["PI_OFFLINE"] == "1")
    #expect(launched.prompt.contains("Artifact SHA-256: \(artifact)."))
    #expect(launched.prompt.contains("untrusted data"))
    let configurationPath = try #require(launched.environment["JIDOKA_CODE_CONFIG"])
    let configuration = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
    let object = try #require(
      JSONSerialization.jsonObject(with: configuration) as? [String: Any]
    )
    #expect(object["workflow"] as? String == "issue-triage")
    #expect(object["role"] as? String == "triage")
    #expect(
      object["workspaceRoot"] as? String
        == (try PiTUIFileProtocol.canonicalExistingURL(fixture.workspace).path)
    )
    #expect(await runner.callCount() == 1)
  }

  @Test("application preparation cannot select the wrong model profile")
  func profileBoundary() async throws {
    let fixture = try RPCExecutorFixture()
    defer { fixture.remove() }
    let runner = CapturingRPCRunner()
    let executor = fixture.executor(
      preparation: fixture.preparation(role: .review),
      runner: runner
    )

    await #expect(throws: PiRPCWorkflowExecutorError.preparationProfileMismatch) {
      try await executor.execute(workflowRequest())
    }
    #expect(await runner.callCount() == 0)
  }

  @Test("read-only roles reject write paths and session directives stay canonical")
  func toolAndSessionBoundary() async throws {
    let fixture = try RPCExecutorFixture()
    defer { fixture.remove() }
    let rejectingRunner = CapturingRPCRunner()
    let writePreparation = fixture.preparation(
      role: .triage,
      allowedWritePaths: ["Sources/Allowed.swift"]
    )
    await #expect(throws: PiWorkflowResourceError.invalidRuntimeConfiguration) {
      try await fixture.executor(
        preparation: writePreparation,
        runner: rejectingRunner
      ).execute(workflowRequest())
    }
    #expect(await rejectingRunner.callCount() == 0)

    let resumedRunner = CapturingRPCRunner()
    let sessionID = "12345678-1234-1234-1234-123456789abc"
    let resumed = PiWorkflowExecutionRequest(
      jobID: "rpc-adapter-resume",
      workflow: .issueTriage,
      role: .triage,
      round: 2,
      artifactSHA256: artifact,
      sessionDirective: .resume(sessionID)
    )
    let execution = try await fixture.executor(
      preparation: fixture.preparation(role: .triage),
      runner: resumedRunner
    ).execute(resumed)
    #expect(execution.sessionID == sessionID)
    let launched = try #require(await resumedRunner.lastRequest())
    guard let sessionIndex = launched.arguments.firstIndex(of: "--session") else {
      Issue.record("canonical resume flag is absent")
      return
    }
    #expect(launched.arguments[sessionIndex + 1] == sessionID)
  }

  @Test("unsafe application directories fail before the process runner")
  func directoryBoundary() async throws {
    let fixture = try RPCExecutorFixture()
    defer { fixture.remove() }
    let runner = CapturingRPCRunner()
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    let linked = fixture.root.appendingPathComponent("linked-sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: outside.path
    )
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let preparation = PiRPCWorkflowPreparation(
      profile: fixture.profile(role: .triage),
      workspaceRoot: fixture.workspace,
      sessionRoot: linked,
      allowedWritePaths: [],
      prompt: "fixture",
      offline: true
    )

    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(preparation: preparation, runner: runner).execute(
        workflowRequest()
      )
    }
    #expect(await runner.callCount() == 0)

    let jobLink = fixture.sessionRoot.appendingPathComponent(
      "rpc-adapter-1",
      isDirectory: true
    )
    try FileManager.default.createSymbolicLink(at: jobLink, withDestinationURL: outside)
    await #expect(throws: PiRPCWorkflowExecutorError.preparationBoundaryMismatch) {
      try await fixture.executor(
        preparation: fixture.preparation(role: .triage),
        runner: runner
      ).execute(workflowRequest())
    }
    #expect(await runner.callCount() == 0)
  }

  private func workflowRequest() -> PiWorkflowExecutionRequest {
    PiWorkflowExecutionRequest(
      jobID: "rpc-adapter-1",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: artifact,
      sessionDirective: .fresh
    )
  }
}

private final class RPCExecutorFixture {
  let root: URL
  let resourceRoot: URL
  let runtime: PiResolvedRuntime
  let runtimeResolver: CountingReleaseOwnedRuntimeResolver
  let sessionRoot: URL
  private let releaseRuntimeFixture: ReleaseOwnedRuntimeFixture
  let workspace: URL

  init() throws {
    releaseRuntimeFixture = try ReleaseOwnedRuntimeFixture()
    runtimeResolver = try CountingReleaseOwnedRuntimeResolver(
      resolver: releaseRuntimeFixture.resolver()
    )
    runtime = try releaseRuntimeFixture.resolver().resolve()
    resourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .resolvingSymlinksInPath()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-rpc-executor-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    workspace = root.appendingPathComponent("workspace", isDirectory: true)
    for directory in [root, sessionRoot, workspace] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  func profile(role: ModelProfileRole) -> ModelProfileConfiguration {
    ModelProfileConfiguration(
      role: role,
      provider: "fixture",
      model: "fixture",
      thinking: .off
    )
  }

  func preparation(
    role: ModelProfileRole,
    allowedWritePaths: [String] = []
  ) -> PiRPCWorkflowPreparation {
    PiRPCWorkflowPreparation(
      profile: profile(role: role),
      workspaceRoot: workspace,
      sessionRoot: sessionRoot,
      allowedWritePaths: allowedWritePaths,
      prompt: "Synthetic application artifact and normalized prior role evidence.",
      offline: true,
      timeoutSeconds: 30
    )
  }

  func executor(
    preparation: PiRPCWorkflowPreparation,
    runner: CapturingRPCRunner
  ) -> PiRPCWorkflowExecutor {
    PiRPCWorkflowExecutor(
      preparer: FixedRPCPreparer(preparation: preparation),
      runtimeResolver: runtimeResolver,
      resourceRoot: resourceRoot,
      runner: runner,
      nonce: { "nonce-adapter-1" }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
    releaseRuntimeFixture.remove()
  }
}

private struct FixedRPCPreparer: PiRPCWorkflowPreparing {
  let preparation: PiRPCWorkflowPreparation

  func prepare(_ request: PiWorkflowExecutionRequest) async throws -> PiRPCWorkflowPreparation {
    preparation
  }
}

private actor CapturingRPCRunner: PiRPCProcessRunning {
  private var requests: [PiRPCProcessRequest] = []

  func run(_ request: PiRPCProcessRequest) async throws -> PiRPCExecutionResult {
    requests.append(request)
    let resumedSession: String? = request.arguments.firstIndex(of: "--session").flatMap { index in
      index + 1 < request.arguments.count ? request.arguments[index + 1] : nil
    }
    return PiRPCExecutionResult(
      sessionID: resumedSession ?? "typed-session",
      terminalResult: PiRPCTerminalResult(
        workflow: request.terminalIdentity.workflow,
        role: request.terminalIdentity.role,
        nonce: request.terminalIdentity.nonce,
        artifactSHA256: request.terminalIdentity.artifactSHA256,
        approvedCommandIDs: request.terminalIdentity.allowedCommandIDs.sorted(),
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

  func callCount() -> Int { requests.count }
  func lastRequest() -> PiRPCProcessRequest? { requests.last }
}
