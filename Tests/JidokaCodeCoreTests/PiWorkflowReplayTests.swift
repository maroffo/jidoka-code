import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Deterministic fake-provider replay for all Pi workflows")
struct PiWorkflowReplayTests {
  private let artifact = String(repeating: "a", count: 64)

  @Test("golden delta-only transcripts decode all four strict result schemas")
  func goldenReplay() throws {
    let review = try PiWorkflowReplayExecutor.replay(
      fixture(
        name: "pr-review",
        workflow: .pullRequestReview,
        role: .architecture,
        nonce: "nonce-pr-review",
        allowedCommandIDs: []
      )
    )
    guard case .pullRequestReview(let reviewPayload) = review.payload else {
      Issue.record("PR replay decoded the wrong payload")
      return
    }
    #expect(reviewPayload.commitNarrativeSHA256 == String(repeating: "c", count: 64))
    #expect(reviewPayload.domain == .architecture)

    let triage = try PiWorkflowReplayExecutor.replay(
      fixture(
        name: "issue-triage",
        workflow: .issueTriage,
        role: .triage,
        nonce: "nonce-triage-1",
        allowedCommandIDs: []
      )
    )
    guard case .issueTriage(let triagePayload) = triage.payload else {
      Issue.record("triage replay decoded the wrong payload")
      return
    }
    #expect(triagePayload.verdict == "human")
    #expect(triagePayload.hardRiskFlags == [.securityOrSecretCore])

    let planning = try PiWorkflowReplayExecutor.replay(
      fixture(
        name: "planning",
        workflow: .planning,
        role: .writer,
        nonce: "nonce-planning",
        allowedCommandIDs: []
      )
    )
    guard case .planning(let planningPayload) = planning.payload else {
      Issue.record("planning replay decoded the wrong payload")
      return
    }
    #expect(planningPayload.commandDefinitions.map(\.id) == ["check"])
    #expect(
      try ApprovedCommandCanonicalizer.canonicalize(
        planningPayload.commandDefinitions
      ).map(\.id) == ["check"])

    let orchestration = try PiWorkflowReplayExecutor.replay(
      fixture(
        name: "orchestration",
        workflow: .orchestration,
        role: .writer,
        nonce: "nonce-orchestrate",
        allowedCommandIDs: ["check"]
      )
    )
    guard case .orchestration(let orchestrationPayload) = orchestration.payload else {
      Issue.record("orchestration replay decoded the wrong payload")
      return
    }
    #expect(orchestrationPayload.requestedCommandIDs == ["check"])
    #expect(orchestration.approvedCommandIDs == ["check"])
  }

  @Test("replay executor consumes each exact workflow-role-round fixture once")
  func replayExecutorCardinality() async throws {
    let replayFixture = fixture(
      name: "issue-triage",
      workflow: .issueTriage,
      role: .triage,
      nonce: "nonce-triage-1",
      allowedCommandIDs: []
    )
    let executor = try PiWorkflowReplayExecutor(fixtures: [replayFixture])
    let execution = try await executor.execute(
      PiWorkflowExecutionRequest(
        jobID: "triage-replay",
        workflow: .issueTriage,
        role: .triage,
        round: 1,
        artifactSHA256: artifact,
        sessionDirective: .fresh
      )
    )

    #expect(execution.agentSettledCount == 1)
    #expect(execution.extensionErrorCount == 0)
    try await executor.assertExhausted()

    let mismatchedDirective = try PiWorkflowReplayExecutor(fixtures: [replayFixture])
    await #expect(throws: PiWorkflowReplayError.sessionMismatch) {
      try await mismatchedDirective.execute(
        PiWorkflowExecutionRequest(
          jobID: "triage-replay",
          workflow: .issueTriage,
          role: .triage,
          round: 1,
          artifactSHA256: artifact,
          sessionDirective: .resume("replay-issue-triage")
        )
      )
    }

    let resumeSessionID = "replay-issue-triage"
    let resumeFixture = PiWorkflowReplayFixture(
      key: PiWorkflowReplayKey(workflow: .issueTriage, role: .triage, round: 2),
      sessionID: resumeSessionID,
      transcript: replayFixture.transcript,
      terminalIdentity: replayFixture.terminalIdentity,
      sessionDirective: .resume(resumeSessionID)
    )
    let resumeExecutor = try PiWorkflowReplayExecutor(fixtures: [resumeFixture])
    let resumed = try await resumeExecutor.execute(
      PiWorkflowExecutionRequest(
        jobID: "triage-replay",
        workflow: .issueTriage,
        role: .triage,
        round: 2,
        artifactSHA256: artifact,
        sessionDirective: .resume(resumeSessionID)
      )
    )
    #expect(resumed.sessionID == resumeSessionID)
    try await resumeExecutor.assertExhausted()

    let wrongResumeFixture = PiWorkflowReplayFixture(
      key: PiWorkflowReplayKey(workflow: .issueTriage, role: .triage, round: 2),
      sessionID: resumeSessionID,
      transcript: replayFixture.transcript,
      terminalIdentity: replayFixture.terminalIdentity,
      sessionDirective: .resume("different-session")
    )
    let wrongResumeExecutor = try PiWorkflowReplayExecutor(fixtures: [wrongResumeFixture])
    await #expect(throws: PiWorkflowReplayError.sessionMismatch) {
      try await wrongResumeExecutor.execute(
        PiWorkflowExecutionRequest(
          jobID: "triage-replay",
          workflow: .issueTriage,
          role: .triage,
          round: 2,
          artifactSHA256: artifact,
          sessionDirective: .resume("different-session")
        )
      )
    }

    await #expect(throws: PiWorkflowReplayError.missingFixture) {
      try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: "triage-replay",
          workflow: .issueTriage,
          role: .triage,
          round: 1,
          artifactSHA256: artifact,
          sessionDirective: .fresh
        )
      )
    }
  }

  @Test("unstructured output, extension error, missing settled, and multiple result fail")
  func replayFalsifiers() throws {
    let valid = fixture(
      name: "pr-review",
      workflow: .pullRequestReview,
      role: .architecture,
      nonce: "nonce-pr-review",
      allowedCommandIDs: []
    )
    let unstructured = PiWorkflowReplayFixture(
      key: valid.key,
      sessionID: "bad-unstructured",
      transcript: Data("not-json\n".utf8),
      terminalIdentity: valid.terminalIdentity
    )
    #expect(throws: PiRPCProtocolError.malformedJSON) {
      try PiWorkflowReplayExecutor.replay(unstructured)
    }

    let response = #"{"command":"prompt","id":"prompt-1","success":true,"type":"response"}"#
    let extensionFailure = PiWorkflowReplayFixture(
      key: valid.key,
      sessionID: "bad-extension",
      transcript: Data("\(response)\n{\"error\":\"boom\",\"type\":\"extension_error\"}\n".utf8),
      terminalIdentity: valid.terminalIdentity
    )
    #expect(throws: PiRPCProtocolError.extensionError) {
      try PiWorkflowReplayExecutor.replay(extensionFailure)
    }

    let lines = String(decoding: valid.transcript, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    let missingSettled = PiWorkflowReplayFixture(
      key: valid.key,
      sessionID: "bad-unsettled",
      transcript: Data((lines.dropLast().joined(separator: "\n") + "\n").utf8),
      terminalIdentity: valid.terminalIdentity
    )
    #expect(throws: PiRPCProtocolError.missingAgentSettled) {
      try PiWorkflowReplayExecutor.replay(missingSettled)
    }

    let resultLine = try #require(lines.first(where: { $0.contains("tool_execution_end") }))
    let settledLine = try #require(lines.last)
    let duplicateLines = Array(lines.dropLast()) + [resultLine, settledLine]
    let duplicateResult = PiWorkflowReplayFixture(
      key: valid.key,
      sessionID: "bad-duplicate",
      transcript: Data((duplicateLines.joined(separator: "\n") + "\n").utf8),
      terminalIdentity: valid.terminalIdentity
    )
    #expect(throws: PiRPCProtocolError.multipleTerminalResults) {
      try PiWorkflowReplayExecutor.replay(duplicateResult)
    }
  }

  @Test("unknown schema fields and hard-risk flags cannot pass decoder strictness")
  func strictDecoder() throws {
    let result = PiRPCTerminalResult(
      workflow: "issue-triage",
      role: "triage",
      nonce: "nonce-triage-1",
      artifactSHA256: artifact,
      approvedCommandIDs: [],
      payload: [
        "complexityGuess": .string("simple"),
        "hardRiskFlags": .array([.string("invented-risk")]),
        "questions": .array([]),
        "rationale": .string("rationale"),
        "rubric": .object([
          "bounded": .string("bounded"),
          "safe": .string("safe"),
          "specified": .string("specified"),
          "testable": .string("testable"),
        ]),
        "severity": .string("none"),
        "summary": .string("summary"),
        "verdict": .string("ready"),
      ],
      recordSHA256: String(repeating: "b", count: 64)
    )
    #expect(throws: PiWorkflowResultError.invalidHardRisk) {
      try PiWorkflowResultDecoder.decode(result)
    }

    var extra = result.payload
    extra["unexpected"] = .bool(true)
    let extraResult = PiRPCTerminalResult(
      workflow: result.workflow,
      role: result.role,
      nonce: result.nonce,
      artifactSHA256: result.artifactSHA256,
      approvedCommandIDs: result.approvedCommandIDs,
      payload: extra,
      recordSHA256: result.recordSHA256
    )
    #expect(throws: PiWorkflowResultError.invalidPayload) {
      try PiWorkflowResultDecoder.decode(extraResult)
    }

    let metadataWrite = PiRPCTerminalResult(
      workflow: "orchestration",
      role: "writer",
      nonce: "nonce-orchestrate",
      artifactSHA256: artifact,
      approvedCommandIDs: ["check"],
      payload: [
        "changedPaths": .array([.string(".GIT/config")]),
        "evidence": .array([.string("evidence")]),
        "findings": .array([]),
        "requestedCommandIDs": .array([.string("check")]),
        "severity": .string("none"),
        "summary": .string("summary"),
        "verdict": .string("pass"),
      ],
      recordSHA256: String(repeating: "c", count: 64)
    )
    #expect(throws: PiWorkflowResultError.invalidPayload) {
      try PiWorkflowResultDecoder.decode(metadataWrite)
    }
  }

  private func fixture(
    name: String,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    nonce: String,
    allowedCommandIDs: Set<String>
  ) -> PiWorkflowReplayFixture {
    let url = Bundle.module.url(
      forResource: name,
      withExtension: "jsonl",
      subdirectory: "Fixtures/Pi"
    )!
    return PiWorkflowReplayFixture(
      key: PiWorkflowReplayKey(workflow: workflow, role: role, round: 1),
      sessionID: "replay-\(name)",
      transcript: try! Data(contentsOf: url),
      terminalIdentity: PiRPCTerminalResultIdentity(
        workflow: workflow.rawValue,
        role: role.rawValue,
        nonce: nonce,
        artifactSHA256: artifact,
        allowedCommandIDs: allowedCommandIDs
      )
    )
  }
}
