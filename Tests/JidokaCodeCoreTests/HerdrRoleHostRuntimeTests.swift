import CryptoKit
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Persistent exact Herdr role host")
struct HerdrRoleHostRuntimeTests {
  @Test("one role host executes a contiguous create-only command queue")
  func sequentialQueue() async throws {
    let fixture = try RoleHostFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.enqueue(sequence: 1, launchAttemptID: "launch-00000001")
    try fixture.enqueue(
      sequence: 2,
      launchAttemptID: "launch-00000002",
      workspaceID: "workspace-moved",
      tabID: "tab-moved",
      paneID: "pane-moved",
      terminalID: "terminal-1"
    )
    let probe = RoleHostProbe()
    let status = try await HerdrRoleHostRuntime.run(
      arguments: ["--role-host-id", fixture.roleHostID],
      environment: fixture.environment,
      pollNanoseconds: 1_000_000,
      identity: fixture.identity,
      validateCommand: { _, _, _ in },
      execute: { command, root, environment in
        await probe.record(
          [
            command.launchAttemptID,
            environment["JIDOKA_CODE_HERDR_SEQUENCE_BASE"] ?? "missing",
            environment["HERDR_WORKSPACE_ID"] ?? "missing",
            environment["HERDR_TAB_ID"] ?? "missing",
            environment["HERDR_PANE_ID"] ?? "missing",
            environment["JIDOKA_CODE_HERDR_EXPECTED_TERMINAL_ID"] ?? "missing",
          ].joined(separator: "@")
        )
        if command.launchAttemptID == "launch-00000002" {
          try HerdrRoleHostDescriptorStore.requestShutdown(
            roleHostID: fixture.roleHostID,
            in: root
          )
        }
        return 0
      }
    )
    #expect(status == 0)
    #expect(
      await probe.values() == [
        "launch-00000001@1@workspace-1@tab-1@pane-1@terminal-1",
        "launch-00000002@3@workspace-moved@tab-moved@pane-moved@terminal-1",
      ]
    )
    #expect(
      try HerdrRoleHostDescriptorStore.completion(
        roleHostID: fixture.roleHostID,
        sequence: 1,
        from: fixture.root
      )?.status == "released"
    )
    #expect(
      try HerdrRoleHostDescriptorStore.completion(
        roleHostID: fixture.roleHostID,
        sequence: 2,
        from: fixture.root
      )?.status == "released"
    )
    let recordedStart = try HerdrRoleHostDescriptorStore.startRecord(
      roleHostID: fixture.roleHostID,
      from: fixture.root
    )
    let start = try #require(recordedStart)
    #expect(start.processID == fixture.identity.process.processID)
    #expect(start.executableSHA256 == fixture.identity.executableSHA256)
  }

  @Test("a queue gap fails before any child execution")
  func queueGap() async throws {
    let fixture = try RoleHostFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.enqueue(sequence: 2, launchAttemptID: "launch-00000002")
    let probe = RoleHostProbe()
    await #expect(throws: HerdrHostError.queueSequenceGap) {
      _ = try await HerdrRoleHostRuntime.run(
        arguments: ["--role-host-id", fixture.roleHostID],
        environment: fixture.environment,
        pollNanoseconds: 1_000_000,
        identity: fixture.identity,
        validateCommand: { _, _, _ in },
        execute: { command, _, _ in
          await probe.record(command.launchAttemptID)
          return 0
        }
      )
    }
    #expect(await probe.values().isEmpty)
  }

  @Test("a role host process restart cannot replay a started queue")
  func restartFailsClosed() async throws {
    let fixture = try RoleHostFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try HerdrRoleHostDescriptorStore.requestShutdown(
      roleHostID: fixture.roleHostID,
      in: fixture.root
    )
    #expect(
      try await HerdrRoleHostRuntime.run(
        arguments: ["--role-host-id", fixture.roleHostID],
        environment: fixture.environment,
        pollNanoseconds: 1_000_000,
        identity: fixture.identity,
        validateCommand: { _, _, _ in },
        execute: { _, _, _ in 0 }
      ) == 0
    )
    await #expect(throws: HerdrHostError.roleHostRestartNotAuthorized) {
      _ = try await HerdrRoleHostRuntime.run(
        arguments: ["--role-host-id", fixture.roleHostID],
        environment: fixture.environment,
        pollNanoseconds: 1_000_000,
        identity: fixture.identity,
        validateCommand: { _, _, _ in },
        execute: { _, _, _ in 0 }
      )
    }
  }

  @Test("a failed Pi command is immutable and a later authorized command can run")
  func failedCommandDoesNotKillRoleHost() async throws {
    let fixture = try RoleHostFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.enqueue(sequence: 1, launchAttemptID: "launch-00000001")
    try fixture.enqueue(sequence: 2, launchAttemptID: "launch-00000002")
    let status = try await HerdrRoleHostRuntime.run(
      arguments: ["--role-host-id", fixture.roleHostID],
      environment: fixture.environment,
      pollNanoseconds: 1_000_000,
      identity: fixture.identity,
      validateCommand: { _, _, _ in },
      execute: { command, root, _ in
        if command.launchAttemptID == "launch-00000001" {
          throw HerdrHostError.launchFailed
        }
        try HerdrRoleHostDescriptorStore.requestShutdown(
          roleHostID: fixture.roleHostID,
          in: root
        )
        return 0
      }
    )
    #expect(status == 0)
    let recordedFailure = try HerdrRoleHostDescriptorStore.completion(
      roleHostID: fixture.roleHostID,
      sequence: 1,
      from: fixture.root
    )
    let failed = try #require(recordedFailure)
    #expect(failed.status == "failed")
    #expect(failed.failureCode == HerdrHostError.launchFailed.code)
    #expect(
      try HerdrRoleHostDescriptorStore.completion(
        roleHostID: fixture.roleHostID,
        sequence: 2,
        from: fixture.root
      )?.status == "released"
    )
  }

  @Test("bootstrap and queue records reject mutation and wrong host identity")
  func recordsAreDigestBound() async throws {
    let fixture = try RoleHostFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let descriptor = try HerdrRoleHostDescriptorStore.load(
      roleHostID: fixture.roleHostID,
      from: fixture.root
    )
    #expect(descriptor.hostExecutableSHA256 == fixture.identity.executableSHA256)
    try fixture.enqueue(sequence: 1, launchAttemptID: "launch-00000001")
    let divergent = try HerdrRoleHostCommand(
      roleHostID: fixture.roleHostID,
      sequence: 1,
      launchAttemptID: "launch-00000009",
      descriptorSHA256: String(repeating: "9", count: 64),
      expectedWorkspaceID: "workspace-1",
      expectedTabID: "tab-1",
      expectedPaneID: "pane-1",
      expectedTerminalID: "terminal-1"
    )
    #expect(throws: PiTUIRuntimeError.divergentFile) {
      try HerdrRoleHostDescriptorStore.enqueue(divergent, in: fixture.root)
    }
    let wrongIdentity = HerdrRoleHostRuntimeIdentity(
      process: fixture.identity.process,
      executable: fixture.identity.executable,
      executableSHA256: String(repeating: "f", count: 64)
    )
    await #expect(throws: HerdrHostError.incompatiblePane) {
      _ = try await HerdrRoleHostRuntime.run(
        arguments: ["--role-host-id", fixture.roleHostID],
        environment: fixture.environment,
        pollNanoseconds: 1_000_000,
        identity: wrongIdentity,
        validateCommand: { _, _, _ in },
        execute: { _, _, _ in 0 }
      )
    }
  }
}

private struct RoleHostFixture {
  let root: URL
  let roleHostID: String
  let environment: [String: String]
  let identity: HerdrRoleHostRuntimeIdentity

  static func make() throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "role-host-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executable = try PiTUIFileProtocol.canonicalExistingURL(
      URL(fileURLWithPath: "/usr/bin/true")
    )
    let executableData = try Data(contentsOf: executable, options: [.mappedIfSafe])
    let executableSHA256 = SHA256.hash(data: executableData)
      .map { String(format: "%02x", $0) }.joined()
    let identity = HerdrRoleHostRuntimeIdentity(
      process: try HerdrHostProcessIdentity(
        processID: 42,
        startSeconds: 100,
        startMicroseconds: 200
      ),
      executable: executable,
      executableSHA256: executableSHA256
    )
    let roleHostID = "role-host-00000001"
    let descriptor = try HerdrRoleHostBootstrapDescriptor(
      roleHostID: roleHostID,
      repositoryID: "repository-00000001",
      jobID: "job-00000001",
      generation: 1,
      role: .writer,
      allowedWorkflows: [.planning, .orchestration],
      expectedWorkspaceID: "workspace-1",
      workingDirectory: root.standardizedFileURL,
      agentAlias: "jidoka_writer",
      title: "Jidoka planning writer",
      displayAgent: "Jidoka | writer",
      hostExecutable: executable
    )
    _ = try HerdrRoleHostDescriptorStore.prepare(descriptor, in: root)
    return Self(
      root: root,
      roleHostID: roleHostID,
      environment: [
        "HERDR_PANE_ID": "pane-1",
        "HERDR_SOCKET_PATH": "/private/fake-herdr.sock",
        "HERDR_TAB_ID": "tab-1",
        "HERDR_WORKSPACE_ID": "workspace-1",
        "JIDOKA_CODE_HERDR_RUN_ROOT": root.path,
      ],
      identity: identity
    )
  }

  func enqueue(
    sequence: Int,
    launchAttemptID: String,
    workspaceID: String = "workspace-1",
    tabID: String = "tab-1",
    paneID: String = "pane-1",
    terminalID: String = "terminal-1"
  ) throws {
    try HerdrRoleHostDescriptorStore.enqueue(
      HerdrRoleHostCommand(
        roleHostID: roleHostID,
        sequence: sequence,
        launchAttemptID: launchAttemptID,
        descriptorSHA256: String(repeating: Character(String(sequence % 10)), count: 64),
        expectedWorkspaceID: workspaceID,
        expectedTabID: tabID,
        expectedPaneID: paneID,
        expectedTerminalID: terminalID
      ),
      in: root
    )
  }
}

private actor RoleHostProbe {
  private var observed: [String] = []

  func record(_ value: String) {
    observed.append(value)
  }

  func values() -> [String] {
    observed
  }
}
