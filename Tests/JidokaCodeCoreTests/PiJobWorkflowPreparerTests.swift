import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Application-only Pi job workflow preparation")
struct PiJobWorkflowPreparerTests {
  @Test("artifact, model profile, prior results, and write scope become bounded prompt data")
  func preparesApplicationData() async throws {
    let fixture = try PiJobPreparerFixture()
    defer { fixture.remove() }
    let artifact = Data("{\"issue\":\"untrusted\"}\n".utf8)
    let digest = sha256(artifact)
    let result = PiNormalizedRoleResult(
      role: .architecture,
      verdict: "pass",
      severity: .minor,
      summary: "Bounded finding.",
      findings: [
        PiWorkflowFinding(
          severity: .minor,
          path: "Sources/File.swift",
          line: 7,
          evidence: "fixture",
          recommendation: "keep the boundary"
        )
      ],
      evidence: ["reviewed"],
      proposedComplexity: .moderate,
      classifierFacts: nil,
      approvedCommandDigests: [],
      approvedPlanDigest: nil
    )
    let context = fixture.context(artifact: artifact)
    let preparer = PiJobWorkflowPreparer(context: context)
    let request = PiWorkflowExecutionRequest(
      jobID: "job-preparer-1",
      workflow: .orchestration,
      role: .writer,
      round: 2,
      artifactSHA256: digest,
      sessionDirective: .fresh,
      normalizedRoleInputs: [result],
      engineFailures: ["verification-failed"]
    )

    let preparation = try await preparer.prepare(request)

    #expect(preparation.profile.role == .orchestration)
    #expect(preparation.allowedWritePaths == ["Sources/Allowed.swift"])
    #expect(preparation.workspaceRoot == fixture.workspace)
    #expect(preparation.sessionRoot == fixture.sessions)
    let promptData = try #require(preparation.prompt.data(using: .utf8))
    let object = try #require(
      JSONSerialization.jsonObject(with: promptData) as? [String: Any]
    )
    #expect(object["artifactSHA256"] as? String == digest)
    #expect(
      object["applicationArtifactUTF8"] as? String == String(decoding: artifact, as: UTF8.self))
    #expect(object["engineFailures"] as? [String] == ["verification-failed"])
    let inputs = try #require(object["normalizedRoleInputs"] as? [[String: Any]])
    #expect(inputs.first?["role"] as? String == "architecture")
    #expect(inputs.first?["verdict"] as? String == "pass")
  }

  @Test("review roles get no write paths and use the review profile")
  func readOnlyProfile() async throws {
    let fixture = try PiJobPreparerFixture()
    defer { fixture.remove() }
    let artifact = Data("review\n".utf8)
    let preparation = try await PiJobWorkflowPreparer(
      context: fixture.context(artifact: artifact)
    ).prepare(
      PiWorkflowExecutionRequest(
        jobID: "job-preparer-review",
        workflow: .pullRequestReview,
        role: .security,
        round: 1,
        artifactSHA256: sha256(artifact),
        sessionDirective: .fresh
      )
    )
    #expect(preparation.profile.role == .review)
    #expect(preparation.allowedWritePaths.isEmpty)

    for workflow in [PiWorkflowKind.planning, .orchestration] {
      let independent = try await PiJobWorkflowPreparer(
        context: fixture.context(artifact: artifact)
      ).prepare(
        PiWorkflowExecutionRequest(
          jobID: "job-preparer-\(workflow.rawValue)-security",
          workflow: workflow,
          role: .security,
          round: 1,
          artifactSHA256: sha256(artifact),
          sessionDirective: .fresh
        )
      )
      #expect(independent.profile.role == .review)
      #expect(independent.allowedWritePaths.isEmpty)
    }
  }

  @Test("artifact mismatch and ambiguous profiles fail before launch preparation")
  func failsClosed() async throws {
    let fixture = try PiJobPreparerFixture()
    defer { fixture.remove() }
    let artifact = Data("artifact\n".utf8)
    let request = PiWorkflowExecutionRequest(
      jobID: "job-preparer-fail",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: String(repeating: "f", count: 64),
      sessionDirective: .fresh
    )
    await #expect(throws: PiJobWorkflowPreparerError.artifactDigestMismatch) {
      try await PiJobWorkflowPreparer(
        context: fixture.context(artifact: artifact)
      ).prepare(request)
    }

    let duplicate = PiJobWorkflowContext(
      artifact: artifact,
      workspaceRoot: fixture.workspace,
      sessionRoot: fixture.sessions,
      profiles: [fixture.profile(.triage), fixture.profile(.triage)],
      allowedWritePaths: [],
      offline: true
    )
    let validRequest = PiWorkflowExecutionRequest(
      jobID: "job-preparer-duplicate",
      workflow: .issueTriage,
      role: .triage,
      round: 1,
      artifactSHA256: sha256(artifact),
      sessionDirective: .fresh
    )
    await #expect(throws: PiJobWorkflowPreparerError.duplicateProfile(.triage)) {
      try await PiJobWorkflowPreparer(context: duplicate).prepare(validRequest)
    }
  }
}

private final class PiJobPreparerFixture {
  let root: URL
  let workspace: URL
  let sessions: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-pi-job-preparer-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    workspace = root.appendingPathComponent("workspace", isDirectory: true)
    sessions = root.appendingPathComponent("sessions", isDirectory: true)
    for directory in [root, workspace, sessions] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  func profile(_ role: ModelProfileRole) -> ModelProfileConfiguration {
    ModelProfileConfiguration(
      role: role,
      provider: "fixture",
      model: "fixture",
      thinking: .off
    )
  }

  func context(artifact: Data) -> PiJobWorkflowContext {
    PiJobWorkflowContext(
      artifact: artifact,
      workspaceRoot: workspace,
      sessionRoot: sessions,
      profiles: ModelProfileRole.allCases.map(profile),
      allowedWritePaths: ["Sources/Allowed.swift"],
      offline: true,
      timeoutSeconds: 30
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
