import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Exact Pi TUI invocation and structured settlement channel")
struct PiTUIRuntimeTests {
  @Test("configuration pins private prompt, model, session, and directories")
  func configurationContract() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }

    let destination = fixture.channel.appendingPathComponent("tui-configuration.json")
    try fixture.configuration.write(to: destination)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )

    #expect(
      Set(object.keys)
        == Set([
          "acknowledgementTimeoutMilliseconds", "channelDirectory", "expectedCommands",
          "expectedSessionID", "launchMode", "modelID", "modelProvider", "promptPath",
          "promptSHA256", "resumeBoundarySHA256", "role", "runID", "runNonce", "schemaVersion",
          "sessionDirectory",
          "sessionName", "thinkingLevel", "workflow", "workspaceRoot",
        ]))
    #expect(object["schemaVersion"] as? Int == 3)
    #expect(object["launchMode"] as? String == "fresh")
    #expect(object["expectedSessionID"] is NSNull)
    #expect(object["resumeBoundarySHA256"] is NSNull)
    #expect(object["modelProvider"] as? String == "jidoka-fixture")
    #expect(object["modelID"] as? String == "fixture")
    #expect(object["thinkingLevel"] as? String == "off")
    #expect(try permissions(destination) == 0o600)
    #expect(throws: PiTUIRuntimeError.self) { try fixture.configuration.write(to: destination) }
  }

  @Test("session identity origin and boundary match the exact launch configuration")
  func sessionIdentityMatchesLaunch() throws {
    let fresh = try PiTUIFixture()
    defer { fresh.remove() }
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let sessionFile = fresh.sessionDirectory.appendingPathComponent("session.jsonl")
    try PiTUIFileProtocol.createPrivateFile(data: Data("{}\n".utf8), at: sessionFile)
    let resumedOrigin: [String: Any] = [
      "originLaunchMode": "resume",
      "originResumeBoundarySHA256": String(repeating: "a", count: 64),
      "runID": fresh.configuration.runID,
      "runNonce": fresh.configuration.runNonce,
      "schemaVersion": 2,
      "sessionFile": sessionFile.path,
      "sessionID": sessionID,
    ]
    try PiTUIFileProtocol.createPrivateFile(
      data: try PiTUIFileProtocol.canonicalJSONData(resumedOrigin),
      at: fresh.channel.appendingPathComponent("session.json")
    )
    #expect(throws: PiTUIRuntimeError.identityMismatch) {
      _ = try PiTUISessionIdentity.load(
        from: fresh.channel,
        configuration: fresh.configuration
      )
    }

    let resumed = try PiTUIFixture()
    defer { resumed.remove() }
    let resumedSessionFile = resumed.sessionDirectory.appendingPathComponent("session.jsonl")
    try PiTUIFileProtocol.createPrivateFile(data: Data("{}\n".utf8), at: resumedSessionFile)
    let expectedBoundary = String(repeating: "b", count: 64)
    let resumeConfiguration = try PiTUIRunConfiguration(
      runID: resumed.configuration.runID,
      runNonce: resumed.configuration.runNonce,
      workflow: resumed.configuration.workflow,
      role: resumed.configuration.role,
      promptURL: resumed.prompt,
      promptSHA256: resumed.configuration.promptSHA256,
      channelDirectory: resumed.channel,
      workspaceRoot: resumed.workspace,
      sessionDirectory: resumed.sessionDirectory,
      sessionName: resumed.configuration.sessionName,
      launchMode: .resume,
      expectedSessionID: sessionID,
      resumeBoundarySHA256: expectedBoundary,
      model: resumed.configuration.model,
      expectedCommands: resumed.configuration.expectedCommands
    )
    let wrongBoundaryOrigin: [String: Any] = [
      "originLaunchMode": "resume",
      "originResumeBoundarySHA256": String(repeating: "c", count: 64),
      "runID": resumed.configuration.runID,
      "runNonce": resumed.configuration.runNonce,
      "schemaVersion": 2,
      "sessionFile": resumedSessionFile.path,
      "sessionID": sessionID,
    ]
    try PiTUIFileProtocol.createPrivateFile(
      data: try PiTUIFileProtocol.canonicalJSONData(wrongBoundaryOrigin),
      at: resumed.channel.appendingPathComponent("session.json")
    )
    #expect(throws: PiTUIRuntimeError.identityMismatch) {
      _ = try PiTUISessionIdentity.load(
        from: resumed.channel,
        configuration: resumeConfiguration
      )
    }
  }

  @Test("TUI argv omits RPC mode and prompt while preserving exact resource order")
  func tuiInvocation() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let resources = try fixture.invocationResources()

    let arguments = try PiTUIInvocationBuilder.arguments(
      runtime: resources.runtime,
      resources: resources.catalog,
      configuration: fixture.configuration
    )

    #expect(
      arguments == [
        resources.runtime.piCLIURL.path,
        "--no-approve",
        "--no-context-files",
        "--no-themes",
        "--no-prompt-templates",
        "--model",
        fixture.configuration.model.argument,
        "--session-dir",
        fixture.configuration.sessionDirectory.path,
        "--name",
        fixture.configuration.sessionName,
        "--no-extensions",
        "--extension",
        resources.catalog.workflowResources.blockerExtensionURL.path,
        "--extension",
        resources.catalog.workflowResources.runtimeExtensionURL.path,
        "--extension",
        resources.catalog.tuiRuntimeExtensionURL.path,
        "--no-skills",
        "--skill",
        resources.catalog.workflowResources.resourceRoot.appendingPathComponent(
          "skills/jidoka-code-issue-triage/SKILL.md"
        ).path,
        "--tools",
        PiWorkflowResourceCatalog.readOnlyToolNames.joined(separator: ","),
      ]
    )
    #expect(!arguments.contains("--mode"))
    #expect(!arguments.contains(fixture.prompt.path))
  }

  @Test(
    "every workflow role preserves the W5 model, resource, skill, tool, and command contract",
    arguments: h3WorkflowRoleCases
  )
  func workflowRoleParity(testCase: H3WorkflowRoleCase) throws {
    let fixture = try PiTUIFixture(workflow: testCase.workflow, role: testCase.role)
    defer { fixture.remove() }
    let resources = try fixture.invocationResources()
    let workflowResources = resources.catalog.workflowResources
    let skills = try workflowResources.skillURLs(
      workflow: testCase.workflow,
      role: testCase.role
    )
    let tools = try PiWorkflowResourceCatalog.activeToolNames(
      workflow: testCase.workflow,
      role: testCase.role
    )
    let tui = try PiTUIInvocationBuilder.arguments(
      runtime: resources.runtime,
      resources: resources.catalog,
      configuration: fixture.configuration
    )
    let rpc = try PiRPCInvocationBuilder.arguments(
      runtime: resources.runtime,
      model: fixture.configuration.model.argument,
      sessionDirectory: fixture.sessionDirectory,
      sessionName: fixture.configuration.sessionName,
      blockerExtension: workflowResources.blockerExtensionURL,
      runtimeExtension: workflowResources.runtimeExtensionURL,
      skills: skills,
      activeTools: tools,
      session: .fresh
    )

    #expect(tui.first == rpc.first)
    #expect(argumentValue("--model", in: tui) == argumentValue("--model", in: rpc))
    let tuiSession = try #require(argumentValue("--session-dir", in: tui))
    let rpcSession = try #require(argumentValue("--session-dir", in: rpc))
    #expect(
      URL(fileURLWithPath: tuiSession).resolvingSymlinksInPath().path
        == URL(fileURLWithPath: rpcSession).resolvingSymlinksInPath().path
    )
    #expect(argumentValue("--name", in: tui) == argumentValue("--name", in: rpc))
    #expect(argumentValue("--tools", in: tui) == argumentValue("--tools", in: rpc))
    #expect(skillValues(tui) == skillValues(rpc))
    #expect(
      extensionValues(tui) == extensionValues(rpc) + [resources.catalog.tuiRuntimeExtensionURL.path]
    )
    let expectedSkillNames = [testCase.primarySkill] + [testCase.roleSkill].compactMap { $0 }
    let frozenSkillPaths = expectedSkillNames.map {
      workflowResources.resourceRoot.appendingPathComponent("skills/\($0)/SKILL.md").path
    }
    let frozenTools =
      testCase.writer
      ? PiWorkflowResourceCatalog.writerToolNames
      : PiWorkflowResourceCatalog.readOnlyToolNames
    var frozenCommands = [
      PiRPCCommandProvenance(
        name: "jidoka-code-preflight",
        source: "extension",
        path: workflowResources.runtimeExtensionURL.path,
        scope: "temporary",
        origin: "top-level"
      )
    ]
    frozenCommands.append(
      contentsOf: zip(expectedSkillNames, frozenSkillPaths).map { name, path in
        PiRPCCommandProvenance(
          name: "skill:\(name)",
          source: "skill",
          path: path,
          scope: "temporary",
          origin: "top-level"
        )
      }
    )
    frozenCommands.append(
      PiRPCCommandProvenance(
        name: "llama",
        source: "extension",
        path: "<inline:llama.cpp>",
        scope: "temporary",
        origin: "top-level"
      )
    )
    #expect(
      fixture.configuration.promptSHA256
        == "d0f087c8eda2791f7aefc6d607fecefc38a1e428adf4f40d9bf605a0c918069e")
    #expect(fixture.configuration.model.argument == "jidoka-fixture/fixture:off")
    #expect(skillValues(tui) == frozenSkillPaths)
    #expect(argumentValue("--tools", in: tui) == frozenTools.joined(separator: ","))
    #expect(fixture.configuration.expectedCommands == frozenCommands)
    #expect(!tui.contains("--mode") && rpc.contains("--mode"))
    #expect(!tui.contains(fixture.prompt.path))
  }

  @Test("resume pins the exact existing session without another prompt argument")
  func resumeInvocation() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let resources = try fixture.invocationResources()
    let sessionID = "019fe66a-08e5-7566-be79-08c7cda1d7bf"
    let resume = try PiTUIRunConfiguration(
      runID: fixture.configuration.runID,
      runNonce: fixture.configuration.runNonce,
      workflow: .issueTriage,
      role: .triage,
      promptURL: fixture.prompt,
      promptSHA256: fixture.configuration.promptSHA256,
      channelDirectory: fixture.channel,
      workspaceRoot: fixture.workspace,
      sessionDirectory: fixture.sessionDirectory,
      sessionName: fixture.configuration.sessionName,
      launchMode: .resume,
      expectedSessionID: sessionID,
      model: fixture.configuration.model,
      expectedCommands: fixture.configuration.expectedCommands,
      acknowledgementTimeoutMilliseconds: 2_000
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: resume.encoded()) as? [String: Any]
    )
    let arguments = try PiTUIInvocationBuilder.arguments(
      runtime: resources.runtime,
      resources: resources.catalog,
      configuration: resume
    )

    #expect(object["launchMode"] as? String == "resume")
    #expect(object["expectedSessionID"] as? String == sessionID)
    #expect(
      arguments == [
        resources.runtime.piCLIURL.path,
        "--no-approve",
        "--no-context-files",
        "--no-themes",
        "--no-prompt-templates",
        "--model",
        fixture.configuration.model.argument,
        "--session-dir",
        fixture.configuration.sessionDirectory.path,
        "--name",
        fixture.configuration.sessionName,
        "--no-extensions",
        "--extension",
        resources.catalog.workflowResources.blockerExtensionURL.path,
        "--extension",
        resources.catalog.workflowResources.runtimeExtensionURL.path,
        "--extension",
        resources.catalog.tuiRuntimeExtensionURL.path,
        "--no-skills",
        "--session",
        sessionID,
        "--skill",
        resources.catalog.workflowResources.resourceRoot.appendingPathComponent(
          "skills/jidoka-code-issue-triage/SKILL.md"
        ).path,
        "--tools",
        PiWorkflowResourceCatalog.readOnlyToolNames.joined(separator: ","),
      ]
    )
    #expect(!arguments.contains(fixture.prompt.path))
  }

  @Test(
    "planning and orchestration resumes bind the prior settled session boundary",
    arguments: [PiWorkflowKind.planning, PiWorkflowKind.orchestration]
  )
  func crossRunResumeBoundary(workflow: PiWorkflowKind) throws {
    let fixture = try PiTUIFixture(workflow: workflow, role: .writer)
    defer { fixture.remove() }
    let boundary = String(repeating: "c", count: 64)
    let resume = try PiTUIRunConfiguration(
      runID: fixture.configuration.runID,
      runNonce: fixture.configuration.runNonce,
      workflow: workflow,
      role: .writer,
      promptURL: fixture.prompt,
      promptSHA256: fixture.configuration.promptSHA256,
      channelDirectory: fixture.channel,
      workspaceRoot: fixture.workspace,
      sessionDirectory: fixture.sessionDirectory,
      sessionName: fixture.configuration.sessionName,
      launchMode: .resume,
      expectedSessionID: "019fe66a-08e5-7566-be79-08c7cda1d7bf",
      resumeBoundarySHA256: boundary,
      model: fixture.configuration.model,
      expectedCommands: fixture.configuration.expectedCommands,
      acknowledgementTimeoutMilliseconds: 2_000
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: resume.encoded()) as? [String: Any]
    )
    #expect(object["resumeBoundarySHA256"] as? String == boundary)
    #expect(throws: PiTUIRuntimeError.invalidConfiguration) {
      _ = try PiTUIRunConfiguration(
        runID: fixture.configuration.runID,
        runNonce: fixture.configuration.runNonce,
        workflow: workflow,
        role: .writer,
        promptURL: fixture.prompt,
        promptSHA256: fixture.configuration.promptSHA256,
        channelDirectory: fixture.channel,
        workspaceRoot: fixture.workspace,
        sessionDirectory: fixture.sessionDirectory,
        sessionName: fixture.configuration.sessionName,
        launchMode: .fresh,
        expectedSessionID: nil,
        resumeBoundarySHA256: boundary,
        model: fixture.configuration.model,
        expectedCommands: fixture.configuration.expectedCommands
      )
    }
  }

  @Test("TUI environment adds only its private configuration capability")
  func tuiEnvironment() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let workflow = fixture.channel.appendingPathComponent("workflow.json")
    let tui = fixture.channel.appendingPathComponent("tui.json")
    try writePrivate(Data("{}\n".utf8), to: workflow)
    try fixture.configuration.write(to: tui)
    try PiTUIInvocationBuilder.writeLockedSettings(in: fixture.agent)

    let environment = try PiTUIInvocationBuilder.environment(
      homeDirectory: fixture.home,
      agentDirectory: fixture.agent,
      temporaryDirectory: fixture.temporary,
      workflowConfiguration: workflow,
      tuiConfiguration: tui,
      piVersion: try PiSemanticVersion("0.84.1"),
      offline: true
    )

    #expect(
      environment == [
        "GIT_ASKPASS": "/usr/bin/false",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_SSH_COMMAND": "/usr/bin/false",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": fixture.home.path,
        "JIDOKA_CODE_CONFIG": workflow.path,
        "JIDOKA_CODE_TUI_CONFIG": tui.path,
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "PATH": "/usr/bin:/bin",
        "PI_CODING_AGENT_DIR": fixture.agent.path,
        "PI_OFFLINE": "1",
        "PI_SKIP_VERSION_CHECK": "1",
        "TERM": "xterm-256color",
        "TMPDIR": fixture.temporary.path,
      ]
    )
  }

  @Test("locked settings bind the exact admitted Pi version")
  func lockedSettingsVersion() throws {
    for version in ["0.84.0", "0.84.1"] {
      let fixture = try PiTUIFixture()
      defer { fixture.remove() }
      let object: [String: Any] = [
        "compaction": ["enabled": false],
        "defaultProjectTrust": "never",
        "enableInstallTelemetry": false,
        "lastChangelogVersion": version,
        "retry": ["enabled": false, "provider": ["maxRetries": 0]],
        "transport": "sse",
      ]
      let data =
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        + Data([0x0A])
      try writePrivate(data, to: fixture.agent.appendingPathComponent("settings.json"))
      #expect(
        try PiTUIInvocationBuilder.validateLockedSettings(
          in: fixture.agent,
          piVersion: PiSemanticVersion(version)
        )
      )
      let other = version == "0.84.0" ? "0.84.1" : "0.84.0"
      #expect(
        try !PiTUIInvocationBuilder.validateLockedSettings(
          in: fixture.agent,
          piVersion: PiSemanticVersion(other)
        )
      )
    }
  }

  @Test("TUI capability roots reject allow ACLs and accept deny-only ACLs")
  func tuiEnvironmentACLs() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let workflow = fixture.channel.appendingPathComponent("workflow.json")
    let tui = fixture.channel.appendingPathComponent("tui.json")
    try writePrivate(Data("{}\n".utf8), to: workflow)
    try fixture.configuration.write(to: tui)
    try PiTUIInvocationBuilder.writeLockedSettings(in: fixture.agent)
    try runChmod(["+a", "everyone allow list,search", fixture.home.path])
    #expect(throws: PiRPCProcessError.self) {
      _ = try PiTUIInvocationBuilder.environment(
        homeDirectory: fixture.home,
        agentDirectory: fixture.agent,
        temporaryDirectory: fixture.temporary,
        workflowConfiguration: workflow,
        tuiConfiguration: tui,
        piVersion: PiSemanticVersion("0.84.1"),
        offline: true
      )
    }
    try runChmod(["-N", fixture.home.path])
    try runChmod(["+a", "everyone deny delete", fixture.home.path])
    #expect(
      try PiTUIInvocationBuilder.environment(
        homeDirectory: fixture.home,
        agentDirectory: fixture.agent,
        temporaryDirectory: fixture.temporary,
        workflowConfiguration: workflow,
        tuiConfiguration: tui,
        piVersion: PiSemanticVersion("0.84.1"),
        offline: true
      )["HOME"] == fixture.home.path
    )
  }

  @Test("result acknowledgement and release bind the exact digest and run identity")
  func settlementLifecycle() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let channel = try fixture.resultChannel()
    try fixture.writeResult()

    let preparedValue = try channel.preparedResult()
    let prepared = try #require(preparedValue)
    #expect(prepared.workflow == "issue-triage")
    #expect(prepared.role == "triage")
    #expect(prepared.payload["verdict"]?.stringValue == "human")
    #expect(prepared.sessionBoundarySHA256?.wholeMatch(of: /^[0-9a-f]{64}$/) != nil)
    #expect(try channel.acceptedResult() == nil)

    let acknowledged = try channel.acknowledgePreparedResult()
    #expect(acknowledged == prepared)
    #expect(try channel.acceptedResult() == prepared)
    try channel.acknowledgePreparedResult()
    #expect(
      try permissions(fixture.channel.appendingPathComponent("acknowledgement.json")) == 0o600)

    #expect(try !channel.isReleased())
    try writePrivate(
      Data("{".utf8),
      to: fixture.channel.appendingPathComponent(
        "..release.json.prepared.crash.staging"
      )
    )
    try channel.releaseAcceptedResult()
    #expect(try channel.isReleased())
    try channel.releaseAcceptedResult()
  }

  @Test("mismatched and divergent settlement files fail closed")
  func settlementMismatch() throws {
    let fixture = try PiTUIFixture()
    defer { fixture.remove() }
    let channel = try fixture.resultChannel()
    try fixture.writeResult(runNonce: String(repeating: "c", count: 64))
    #expect(throws: PiTUIRuntimeError.self) { try channel.preparedResult() }

    let second = try PiTUIFixture()
    defer { second.remove() }
    let secondChannel = try second.resultChannel()
    try second.writeResult()
    let wrongAcknowledgement: [String: Any] = [
      "resultSHA256": String(repeating: "d", count: 64),
      "runID": second.configuration.runID,
      "runNonce": second.configuration.runNonce,
      "schemaVersion": 1,
      "status": "accepted",
    ]
    let bytes =
      try JSONSerialization.data(withJSONObject: wrongAcknowledgement, options: [.sortedKeys])
      + Data([0x0A])
    try writePrivate(bytes, to: second.channel.appendingPathComponent("acknowledgement.json"))
    #expect(throws: PiTUIRuntimeError.self) { try secondChannel.acceptedResult() }

    let malformed = try PiTUIFixture()
    defer { malformed.remove() }
    let malformedChannel = try malformed.resultChannel()
    try malformed.writeResult(payload: ["verdict": "human"])
    #expect(throws: PiTUIRuntimeError.malformedFile) {
      _ = try malformedChannel.preparedResult()
    }

    let partial = try PiTUIFixture()
    defer { partial.remove() }
    let partialChannel = try partial.resultChannel()
    try partial.writeResult()
    try writePrivate(
      Data("{".utf8),
      to: partial.channel.appendingPathComponent(".acknowledgement.json.prepared")
    )
    #expect(throws: PiTUIRuntimeError.self) {
      _ = try partialChannel.acknowledgePreparedResult()
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: partial.channel.appendingPathComponent("acknowledgement.json").path
      ))
  }

}

struct H3WorkflowRoleCase: CustomTestStringConvertible, Sendable {
  let workflow: PiWorkflowKind
  let role: PiWorkflowRole
  let primarySkill: String
  let roleSkill: String?
  let writer: Bool

  var testDescription: String { "\(workflow.rawValue)-\(role.rawValue)" }
}

private let h3WorkflowRoleCases: [H3WorkflowRoleCase] = [
  H3WorkflowRoleCase(
    workflow: .issueTriage, role: .triage,
    primarySkill: "jidoka-code-issue-triage", roleSkill: nil, writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .pullRequestReview, role: .architecture,
    primarySkill: "jidoka-code-pr-review", roleSkill: "jidoka-code-review-architecture",
    writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .pullRequestReview, role: .security,
    primarySkill: "jidoka-code-pr-review", roleSkill: "jidoka-code-review-security", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .pullRequestReview, role: .test,
    primarySkill: "jidoka-code-pr-review", roleSkill: "jidoka-code-review-test", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .pullRequestReview, role: .synthesis,
    primarySkill: "jidoka-code-pr-review", roleSkill: "jidoka-code-synthesize", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .planning, role: .writer,
    primarySkill: "jidoka-code-plan", roleSkill: nil, writer: true
  ),
  H3WorkflowRoleCase(
    workflow: .planning, role: .architecture,
    primarySkill: "jidoka-code-plan", roleSkill: "jidoka-code-review-architecture", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .planning, role: .security,
    primarySkill: "jidoka-code-plan", roleSkill: "jidoka-code-review-security", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .planning, role: .test,
    primarySkill: "jidoka-code-plan", roleSkill: "jidoka-code-review-test", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .planning, role: .synthesis,
    primarySkill: "jidoka-code-plan", roleSkill: "jidoka-code-synthesize", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .orchestration, role: .writer,
    primarySkill: "jidoka-code-orchestrate", roleSkill: nil, writer: true
  ),
  H3WorkflowRoleCase(
    workflow: .orchestration, role: .architecture,
    primarySkill: "jidoka-code-orchestrate", roleSkill: "jidoka-code-review-architecture",
    writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .orchestration, role: .security,
    primarySkill: "jidoka-code-orchestrate", roleSkill: "jidoka-code-review-security", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .orchestration, role: .test,
    primarySkill: "jidoka-code-orchestrate", roleSkill: "jidoka-code-review-test", writer: false
  ),
  H3WorkflowRoleCase(
    workflow: .orchestration, role: .synthesis,
    primarySkill: "jidoka-code-orchestrate", roleSkill: "jidoka-code-synthesize", writer: false
  ),
]

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

private func extensionValues(_ arguments: [String]) -> [String] {
  arguments.indices.compactMap { index in
    arguments[index] == "--extension" && index + 1 < arguments.count
      ? arguments[index + 1]
      : nil
  }
}

private func skillValues(_ arguments: [String]) -> [String] {
  arguments.indices.compactMap { index in
    arguments[index] == "--skill" && index + 1 < arguments.count
      ? arguments[index + 1]
      : nil
  }
}

private struct PiTUIFixture {
  let root: URL
  let channel: URL
  let workspace: URL
  let sessionDirectory: URL
  let home: URL
  let agent: URL
  let temporary: URL
  let prompt: URL
  let configuration: PiTUIRunConfiguration

  init(
    workflow: PiWorkflowKind = .issueTriage,
    role: PiWorkflowRole = .triage
  ) throws {
    let requested = FileManager.default.temporaryDirectory
      .appendingPathComponent("jidoka-pi-tui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false)
    root = requested.resolvingSymlinksInPath()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    channel = try Self.directory("channel", in: root)
    workspace = try Self.directory("workspace", in: root)
    sessionDirectory = try Self.directory("sessions", in: root)
    home = try Self.directory("home", in: root)
    agent = try Self.directory("agent", in: root)
    temporary = try Self.directory("temporary", in: root)
    prompt = channel.appendingPathComponent("prompt.txt")
    let promptData = Data("Pinned H3 prompt.\n".utf8)
    let promptSHA256 = try PiTUIRunConfiguration.writePrompt(promptData, to: prompt)
    let model = try PiTUIModelIdentity(
      provider: "jidoka-fixture",
      modelID: "fixture",
      thinkingLevel: "off"
    )
    let resources = try PiTUIResourceCatalog.inspect(resourceRoot: sourceResourceRoot())
    configuration = try PiTUIRunConfiguration(
      runID: "run-h3-fixture",
      runNonce: String(repeating: "b", count: 64),
      workflow: workflow,
      role: role,
      promptURL: prompt,
      promptSHA256: promptSHA256,
      channelDirectory: channel,
      workspaceRoot: workspace,
      sessionDirectory: sessionDirectory,
      sessionName: "jidoka-code-h3-fixture",
      launchMode: .fresh,
      expectedSessionID: nil,
      model: model,
      expectedCommands: try resources.workflowResources.expectedCommandProvenance(
        workflow: workflow,
        role: role
      ),
      acknowledgementTimeoutMilliseconds: 2_000
    )
  }

  func resultChannel() throws -> PiTUIResultChannel {
    try PiTUIResultChannel(
      directory: channel,
      expectation: PiTUIResultExpectation(
        runID: configuration.runID,
        runNonce: configuration.runNonce,
        terminalIdentity: PiRPCTerminalResultIdentity(
          workflow: "issue-triage",
          role: "triage",
          nonce: "workflow-nonce",
          artifactSHA256: String(repeating: "a", count: 64),
          allowedCommandIDs: []
        )
      )
    )
  }

  func writeResult(
    runNonce: String? = nil,
    payload: [String: Any]? = nil
  ) throws {
    let validPayload: [String: Any] = [
      "complexityGuess": "humanOwned",
      "hardRiskFlags": ["security-or-secret-core"],
      "questions": [String](),
      "rationale": "Synthetic schema-valid triage payload.",
      "rubric": [
        "bounded": "yes", "safe": "human", "specified": "yes", "testable": "yes",
      ],
      "severity": "major",
      "summary": "Synthetic H3 TUI settlement result.",
      "verdict": "human",
    ]
    let details: [String: Any] = [
      "approvedCommandIDs": [String](),
      "artifactSHA256": String(repeating: "a", count: 64),
      "nonce": "workflow-nonce",
      "payload": payload ?? validPayload,
      "resultSequence": 1,
      "role": "triage",
      "schemaVersion": 1,
      "workflow": "issue-triage",
    ]
    let boundaryData = try PiTUIFileProtocol.canonicalJSONData(details)
    var object = details
    object.removeValue(forKey: "resultSequence")
    object["runID"] = configuration.runID
    object["runNonce"] = runNonce ?? configuration.runNonce
    object["sessionBoundarySHA256"] = PiTUIFileProtocol.sha256(Data(boundaryData.dropLast()))
    let data =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data([0x0A])
    try writePrivate(data, to: channel.appendingPathComponent("result.json"))
  }

  func invocationResources() throws -> (
    runtime: PiResolvedRuntime,
    catalog: PiTUIResourceCatalog
  ) {
    let node = root.appendingPathComponent("node")
    let cli = root.appendingPathComponent("cli.js")
    for url in [node, cli] {
      try writePrivate(Data("fixture\n".utf8), to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    let runtime = PiResolvedRuntime(
      nodeURL: node,
      nodeVersion: try PiSemanticVersion("26.6.0"),
      nodeSHA256: String(repeating: "a", count: 64),
      piCLIURL: cli,
      piPackageRootURL: root,
      piVersion: try PiSemanticVersion("0.84.1"),
      piRuntimeSHA256: [:],
      compatibility: PiRuntimeCompatibility(
        minimumVersion: try PiSemanticVersion("0.84.0"),
        maximumVersionExclusive: try PiSemanticVersion("0.90.0"),
        policySHA256: String(repeating: "b", count: 64)
      )
    )
    return (runtime, try PiTUIResourceCatalog.inspect(resourceRoot: sourceResourceRoot()))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static func directory(_ name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

private func writePrivate(_ data: Data, to url: URL) throws {
  try data.write(to: url, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func runChmod(_ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw CocoaError(.fileWriteNoPermission)
  }
}

private func sourceResourceRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Pi", isDirectory: true)
    .standardizedFileURL
}
