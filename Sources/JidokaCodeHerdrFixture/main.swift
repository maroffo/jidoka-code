import CryptoKit
import Darwin
import Foundation
import JidokaCodeCore

@main
enum JidokaCodeHerdrFixtureMain {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2, arguments[0] == "--prepare-h3" {
      try prepareH3(specificationURL: URL(fileURLWithPath: arguments[1]))
      return
    }
    if arguments.count == 3,
      ["--acknowledge-h3", "--release-h3"].contains(arguments[0])
    {
      try settleH3(
        action: arguments[0],
        tuiConfigurationURL: URL(fileURLWithPath: arguments[1]),
        workflowConfigurationURL: URL(fileURLWithPath: arguments[2])
      )
      return
    }
    guard arguments.count == 2 || arguments.count == 4,
      arguments[0] == "--run-id",
      arguments[1].wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil
    else {
      exit(EX_USAGE)
    }
    let holdMilliseconds: UInt32
    if arguments.count == 4 {
      guard arguments[2] == "--hold-ms",
        let value = UInt32(arguments[3]),
        (100...5_000).contains(value)
      else {
        exit(EX_USAGE)
      }
      holdMilliseconds = value
    } else {
      holdMilliseconds = 100
    }
    let environment = ProcessInfo.processInfo.environment
    let herdrKeys = environment.keys
      .filter { $0.hasPrefix("HERDR_") }
      .sorted()
    let report: [String: Any] = [
      "herdr_keys": herdrKeys,
      "fixture_sentinel": environment["JIDOKA_FIXTURE_SENTINEL"] ?? "missing",
      "pid": ProcessInfo.processInfo.processIdentifier,
      "run_id": arguments[1],
      "status": herdrKeys.isEmpty ? "ok" : "contaminated",
      "working_directory": FileManager.default.currentDirectoryPath,
    ]
    var data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
    usleep(holdMilliseconds * 1_000)
    guard herdrKeys.isEmpty else { exit(EX_NOPERM) }
  }

  private static func settleH3(
    action: String,
    tuiConfigurationURL: URL,
    workflowConfigurationURL: URL
  ) throws {
    let tui = try PiTUIRunConfiguration.load(from: tuiConfigurationURL)
    let workflow = try PiWorkflowRuntimeConfiguration.load(from: workflowConfigurationURL)
    guard tui.workflow == workflow.workflow,
      tui.role == workflow.role,
      tui.workspaceRoot.resolvingSymlinksInPath().path
        == workflow.workspaceRoot.resolvingSymlinksInPath().path
    else {
      throw HerdrHostError.invalidDescriptor
    }
    let channel = try PiTUIResultChannel(
      directory: tui.channelDirectory,
      expectation: PiTUIResultExpectation(
        runID: tui.runID,
        runNonce: tui.runNonce,
        terminalIdentity: PiRPCTerminalResultIdentity(
          workflow: workflow.workflow.rawValue,
          role: workflow.role.rawValue,
          nonce: workflow.nonce,
          artifactSHA256: workflow.artifactSHA256,
          allowedCommandIDs: Set(workflow.allowedCommandIDs)
        )
      )
    )
    let result: PiRPCTerminalResult
    if action == "--acknowledge-h3" {
      result = try channel.acknowledgePreparedResult()
    } else {
      try channel.releaseAcceptedResult()
      guard let accepted = try channel.acceptedResult() else {
        throw HerdrHostError.settlementMissing
      }
      result = accepted
    }
    let evidence = H3SettlementEvidence(
      resultSHA256: result.recordSHA256,
      runID: tui.runID,
      status: action == "--acknowledge-h3" ? "accepted" : "release"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(evidence)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }

  private static func prepareH3(specificationURL: URL) throws {
    #if DEBUG
      let specification = try JSONDecoder().decode(
        H3PreparationSpecification.self,
        from: Data(contentsOf: specificationURL)
      )
      guard
        let runtimeRoot = ProcessInfo.processInfo.environment[
          "JIDOKA_RELEASE_RUNTIME_ROOT"
        ]
      else {
        throw HerdrHostError.invalidDescriptor
      }
      let resolvedRuntime = try ReleaseOwnedPiRuntimeDebugFixture.resolveExactStagedRuntime(
        at: URL(fileURLWithPath: runtimeRoot, isDirectory: true)
      )
      let resourceRoot = URL(fileURLWithPath: specification.resourceRoot, isDirectory: true)
      let resources = try PiTUIResourceCatalog.inspect(resourceRoot: resourceRoot)
      let workspace = URL(fileURLWithPath: specification.workspaceRoot, isDirectory: true)
      let workflowURL = URL(fileURLWithPath: specification.workflowConfiguration)
      let workflow: PiWorkflowRuntimeConfiguration
      if FileManager.default.fileExists(atPath: workflowURL.path) {
        workflow = try PiWorkflowRuntimeConfiguration.load(from: workflowURL)
      } else {
        workflow = try PiWorkflowRuntimeConfiguration(
          workflow: .issueTriage,
          role: .triage,
          nonce: specification.workflowNonce,
          artifactSHA256: specification.artifactSHA256,
          allowedCommandIDs: [],
          allowedWritePaths: [],
          workspaceRoot: workspace,
          resources: resources.workflowResources
        )
        try workflow.write(to: workflowURL)
      }
      guard workflow.workflow == .issueTriage,
        workflow.role == .triage,
        workflow.nonce == specification.workflowNonce,
        workflow.artifactSHA256 == specification.artifactSHA256,
        workflow.workspaceRoot.resolvingSymlinksInPath().path
          == workspace.resolvingSymlinksInPath().path,
        workflow.resources == resources.workflowResources
      else {
        throw HerdrHostError.invalidDescriptor
      }

      let agentDirectory = URL(fileURLWithPath: specification.agentDirectory, isDirectory: true)
      let settings = agentDirectory.appendingPathComponent("settings.json")
      if FileManager.default.fileExists(atPath: settings.path) {
        guard
          try PiTUIInvocationBuilder.validateLockedSettings(
            in: agentDirectory,
            piVersion: PiSemanticVersion("0.84.2")
          )
        else {
          throw HerdrHostError.invalidDescriptor
        }
      } else {
        try PiTUIInvocationBuilder.writeLockedSettings(in: agentDirectory)
      }

      let promptURL = URL(fileURLWithPath: specification.promptPath)
      let promptData = try Data(contentsOf: promptURL)
      let promptSHA256 = SHA256.hash(data: promptData)
        .map { String(format: "%02x", $0) }.joined()
      let model = try PiTUIModelIdentity(
        provider: "jidoka-fixture",
        modelID: "fixture",
        thinkingLevel: "off"
      )
      let launchMode: PiTUILaunchMode = specification.expectedSessionID == nil ? .fresh : .resume
      let tui = try PiTUIRunConfiguration(
        runID: specification.runID,
        runNonce: specification.runNonce,
        workflow: .issueTriage,
        role: .triage,
        promptURL: promptURL,
        promptSHA256: promptSHA256,
        channelDirectory: URL(
          fileURLWithPath: specification.channelDirectory,
          isDirectory: true
        ),
        workspaceRoot: workspace,
        sessionDirectory: URL(
          fileURLWithPath: specification.sessionDirectory,
          isDirectory: true
        ),
        sessionName: specification.sessionName,
        launchMode: launchMode,
        expectedSessionID: specification.expectedSessionID,
        resumeBoundarySHA256: specification.resumeBoundarySHA256,
        model: model,
        expectedCommands: try resources.workflowResources.expectedCommandProvenance(
          workflow: .issueTriage,
          role: .triage
        ),
        acknowledgementTimeoutMilliseconds: 60_000
      )
      let tuiURL = URL(fileURLWithPath: specification.tuiConfiguration)
      try tui.write(to: tuiURL)
      let invocation = try PiTUIHostInvocationDescriptor(
        resourceRoot: resourceRoot,
        runtime: resolvedRuntime,
        homeDirectory: URL(fileURLWithPath: specification.homeDirectory, isDirectory: true),
        agentDirectory: agentDirectory,
        temporaryDirectory: URL(
          fileURLWithPath: specification.temporaryDirectory,
          isDirectory: true
        ),
        workflowConfiguration: workflowURL,
        tuiConfiguration: tuiURL,
        offline: true,
        executionTimeoutMilliseconds: 60_000,
        abortGraceMilliseconds: 1_000,
        fixtureProviderExtension: URL(fileURLWithPath: specification.fixtureProviderExtension),
        fixtureProviderCall: URL(fileURLWithPath: specification.fixtureProviderCall)
      )
      let settlement = try HerdrHostSettlementDescriptor(
        channelDirectory: specification.channelDirectory,
        runID: specification.runID,
        runNonce: specification.runNonce,
        workflow: PiWorkflowKind.issueTriage.rawValue,
        role: PiWorkflowRole.triage.rawValue,
        nonce: specification.workflowNonce,
        artifactSHA256: specification.artifactSHA256,
        allowedCommandIDs: []
      )
      let descriptor = try HerdrHostDescriptor.debugFixture(
        launchAttemptID: specification.launchAttemptID,
        runID: specification.runID,
        runNonce: specification.runNonce,
        repositoryID: "repo-s12-0001",
        jobID: "job-s12-0001",
        generation: 1,
        role: PiWorkflowRole.triage.rawValue,
        agentAlias: specification.agentAlias,
        title: specification.title,
        displayAgent: "Jidoka | issue triage",
        expectedWorkspaceID: specification.workspaceID,
        piTUIInvocation: invocation,
        settlement: settlement,
        resolvedRuntime: resolvedRuntime
      )
      let descriptorRoot = URL(
        fileURLWithPath: specification.runRoot,
        isDirectory: true
      ).standardizedFileURL
      let digest = try HerdrHostDescriptorStore.prepareDebugFixture(
        descriptor,
        in: descriptorRoot,
        resolvedRuntime: resolvedRuntime
      )
      let evidence = H3PreparationEvidence(
        argumentValues: descriptor.childArguments,
        childEnvironmentKeys: descriptor.childEnvironment.keys.sorted(),
        descriptorSHA256: digest,
        launchAttemptID: descriptor.launchAttemptID,
        runID: descriptor.runID,
        schemaVersion: descriptor.schemaVersion
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(evidence)
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    #else
      _ = specificationURL
      throw HerdrHostError.invalidDescriptor
    #endif
  }
}

private struct H3SettlementEvidence: Codable {
  let resultSHA256: String
  let runID: String
  let status: String
}

private struct H3PreparationSpecification: Codable {
  let launchAttemptID: String
  let runID: String
  let runNonce: String
  let workflowNonce: String
  let artifactSHA256: String
  let runRoot: String
  let resourceRoot: String
  let workspaceRoot: String
  let homeDirectory: String
  let agentDirectory: String
  let temporaryDirectory: String
  let sessionDirectory: String
  let channelDirectory: String
  let workflowConfiguration: String
  let tuiConfiguration: String
  let promptPath: String
  let sessionName: String
  let expectedSessionID: String?
  let resumeBoundarySHA256: String?
  let fixtureProviderExtension: String
  let fixtureProviderCall: String
  let workspaceID: String
  let agentAlias: String
  let title: String
}

private struct H3PreparationEvidence: Codable {
  let argumentValues: [String]
  let childEnvironmentKeys: [String]
  let descriptorSHA256: String
  let launchAttemptID: String
  let runID: String
  let schemaVersion: Int
}
