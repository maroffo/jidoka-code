import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Herdr composition contract")
struct ProductionHerdrCompositionTests {
  @Test("all production Pi workflows share Herdr and recovery precedes job recovery")
  func productionCutoverIsExclusive() throws {
    let source = try String(contentsOf: productionRuntimeSource(), encoding: .utf8)
    #expect(source.components(separatedBy: "executorFactory: herdrRuntime").count - 1 == 4)
    #expect(!source.contains("PiRPCWorkflowExecutorFactory("))
    #expect(!source.contains("PiRPCProcessRunner("))
    let herdrRecovery = try #require(source.range(of: "herdrRuntime.recoverDurableState()"))
    let commandRecovery = try #require(
      source.range(
        of: "commandRuns.recoverAtStartup()",
        range: herdrRecovery.upperBound..<source.endIndex
      )
    )
    let accountGate = try #require(source.range(of: "guard let account, let authorID"))
    let jobRecovery = try #require(source.range(of: "coordinator.recoverAtStartup()"))
    #expect(herdrRecovery.lowerBound < commandRecovery.lowerBound)
    #expect(commandRecovery.lowerBound < accountGate.lowerBound)
    #expect(commandRecovery.lowerBound < jobRecovery.lowerBound)
    #expect(source.contains("commandRuns: commandRuns"))
    #expect(source.contains("commandGate: commandGate"))
    #expect(source.contains("ownershipRuntime?.shutdownOwnedRoleHosts()"))
    for relativePath in [
      "Sources/JidokaCodeCore/Jobs/IssueTriageJobWorkflow.swift",
      "Sources/JidokaCodeCore/Jobs/PullRequestReviewJobWorkflow.swift",
      "Sources/JidokaCodeCore/Jobs/PiIssueImplementationExecutors.swift",
    ] {
      let workflowSource = try String(
        contentsOf: projectRoot().appendingPathComponent(relativePath),
        encoding: .utf8
      )
      #expect(!workflowSource.contains("PiRPCWorkflowExecutorFactory("))
      #expect(!workflowSource.contains("PiRPCProcessRunner("))
    }
  }

  @Test("production endpoint and attestation resources cannot come from process input")
  func defaultSocketIsFixed() throws {
    let source = try String(contentsOf: engineMainSource(), encoding: .utf8)
    let appClient = try String(contentsOf: appClientSource(), encoding: .utf8)
    #expect(source.contains(".appendingPathComponent(\".config/herdr/herdr.sock\""))
    #expect(appClient.contains(".appendingPathComponent(\".config/herdr/herdr.sock\""))
    #expect(!source.contains("ProcessInfo.processInfo.environment[\"HERDR_SOCKET_PATH\"]"))
    #expect(!appClient.contains("ProcessInfo.processInfo.environment[\"HERDR_SOCKET_PATH\"]"))
    #expect(!source.contains("sourceHerdrResources"))
    #expect(!appClient.contains("sourceHerdr"))
    #expect(source.contains(".runHerdrPreflight"))
    #expect(source.contains(".focusInHerdr"))
  }

  private func productionRuntimeSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift"
    )
  }

  private func engineMainSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift"
    )
  }

  private func appClientSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeApp/ApplicationEngineClient.swift"
    )
  }

  private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
