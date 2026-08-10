import CryptoKit
import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Herdr exact host and custom lifecycle relay", .serialized)
struct HerdrHostRuntimeTests {
  @Test("descriptor store is create-only private digest-bound and rejects mutation")
  func descriptorStoreBoundary() throws {
    let fixture = try HerdrHostFixture()
    let descriptor = try fixture.descriptor()
    let digest = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)

    #expect(digest.wholeMatch(of: /^[a-f0-9]{64}$/) != nil)
    #expect(
      try HerdrHostDescriptorStore.load(
        launchAttemptID: descriptor.launchAttemptID, from: fixture.runRoot)
        == descriptor)
    #expect(throws: HerdrHostError.descriptorAlreadyExists) {
      _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
    }

    let launch = fixture.runRoot
      .appendingPathComponent(descriptor.launchAttemptID, isDirectory: true)
      .appendingPathComponent("launch.json")
    let handle = try FileHandle(forWritingTo: launch)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(" ".utf8))
    try handle.close()
    #expect(throws: HerdrHostError.descriptorDigestMismatch) {
      _ = try HerdrHostDescriptorStore.load(
        launchAttemptID: descriptor.launchAttemptID, from: fixture.runRoot)
    }
  }

  @Test("descriptor load rejects Darwin allow ACL authority over the child")
  func descriptorACLBoundary() throws {
    let fixture = try HerdrHostFixture()
    let descriptor = try fixture.descriptor()
    _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
    try addHostEveryoneWriteACL(to: fixture.childExecutable)
    #expect(throws: HerdrHostError.invalidDescriptor) {
      _ = try HerdrHostDescriptorStore.load(
        launchAttemptID: descriptor.launchAttemptID,
        from: fixture.runRoot
      )
    }
  }

  @Test("descriptor preparation rolls back every incomplete durable phase")
  func descriptorPreparationRollback() throws {
    for point in HerdrHostDescriptorPreparationPoint.allCases {
      let fixture = try HerdrHostFixture()
      let descriptor = try fixture.descriptor()
      #expect(throws: HerdrHostError.unsafeDescriptorStore) {
        _ = try HerdrHostDescriptorStore.prepare(
          descriptor,
          in: fixture.runRoot,
          failingAt: point
        )
      }
      let runDirectory = fixture.runRoot.appendingPathComponent(
        descriptor.launchAttemptID,
        isDirectory: true
      )
      #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
      _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
      #expect(
        try HerdrHostDescriptorStore.load(
          launchAttemptID: descriptor.launchAttemptID, from: fixture.runRoot)
          == descriptor)
    }
  }

  @Test("secret-shaped and Herdr child environment capabilities fail closed")
  func childEnvironmentPolicy() throws {
    let fixture = try HerdrHostFixture()
    #expect(throws: HerdrHostError.invalidDescriptor) {
      _ = try fixture.descriptor(environment: ["HERDR_SOCKET_PATH": "/tmp/forbidden"])
    }
    #expect(throws: HerdrHostError.invalidDescriptor) {
      _ = try fixture.descriptor(environment: ["PROVIDER_TOKEN": "forbidden"])
    }
  }

  @Test("host reports only its pane launches exact child and strips every Herdr capability")
  func exactHostLifecycle() async throws {
    let fixture = try HerdrHostFixture()
    let descriptor = try fixture.descriptor()
    _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { responder.response(to: $0) })
      }
    )
    var environment = fixture.hostEnvironment(socketURL: server.socketURL)
    environment["JIDOKA_CODE_HERDR_SEQUENCE_BASE"] = "3"

    let status = try await HerdrHostRuntime.run(
      arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
      environment: environment
    )
    await server.finish()

    #expect(status == 0)
    let childEnvironment = try String(contentsOf: fixture.childEnvironmentLog, encoding: .utf8)
    #expect(childEnvironment.contains("SAFE_VALUE=fixture"))
    #expect(!childEnvironment.contains("HERDR_"))
    #expect(!childEnvironment.contains("must-not-reach-child"))

    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method) == [
        "ping", "session.snapshot", "pane.report_agent", "pane.report_metadata",
        "agent.rename", "ping", "session.snapshot", "pane.report_agent",
        "pane.report_metadata",
      ]
    )
    let objects = try requests.map(Self.object)
    let reports = objects.filter { $0["method"] as? String == "pane.report_agent" }
    #expect(reports.count == 2)
    #expect(
      reports.allSatisfy { ($0["params"] as? [String: Any])?["pane_id"] as? String == "w-repo:p2" })
    #expect(
      reports.allSatisfy {
        let parameters = $0["params"] as? [String: Any]
        return parameters?["agent_session_id"] == nil
          && parameters?["agent_session_path"] == nil
      }
    )
    #expect(
      reports.compactMap { ($0["params"] as? [String: Any])?["state"] as? String }
        == ["working", "idle"]
    )
    #expect(
      reports.compactMap {
        (($0["params"] as? [String: Any])?["seq"] as? NSNumber)?.intValue
      }
        == [3, 4]
    )
    let metadata = objects.filter { $0["method"] as? String == "pane.report_metadata" }
    #expect(metadata.count == 2)
    #expect(
      metadata.compactMap {
        (($0["params"] as? [String: Any])?["seq"] as? NSNumber)?.intValue
      }
        == [3, 4]
    )
    #expect(
      metadata.allSatisfy {
        let tokens = ($0["params"] as? [String: Any])?["tokens"] as? [String: String]
        return tokens?["managed_by"] == "jidoka" && tokens?["run_id"] == descriptor.runID
      }
    )
  }

  @Test("accepted Pi result retains through cancellation and reports idle only after release")
  func settlementRetention() async throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    let channel = try settlement.resultChannel()
    try fixture.writeSettlementResult(settlement)
    _ = try channel.acknowledgePreparedResult()
    let descriptor = try fixture.descriptor(settlement: settlement)
    _ = try fixture.prepare(descriptor)
    let responder = HerdrHostWireResponder(
      fixture: fixture,
      descriptor: descriptor,
      moveTerminalOnFinish: true
    )
    let working = HostLaunchSignal()
    let replies = (0..<12).map { _ in
      HerdrFakeReply(dynamicResponse: { request in
        if let object = try? Self.object(request),
          object["method"] as? String == "agent.rename"
        {
          working.markStarted()
        }
        return responder.response(to: request)
      })
    }
    let server = try HerdrFakeSocketServer(
      replies: replies,
      idleTimeoutSeconds: 60
    )
    let completion = HostCompletionFlag()
    let launches = HostInvocationCounter()
    let task = Task {
      let value = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL),
        responseTimeoutSeconds: 60,
        descriptorLoader: { _, _ in descriptor },
        launchOperation: { _ in
          await launches.record()
          return 23
        }
      )
      await completion.markFinished()
      return value
    }

    let completionObserver = Task {
      _ = try? await task.value
      working.markFinishedBeforeStart()
    }
    let started = await working.waitForOutcome()
    completionObserver.cancel()
    #expect(started)
    guard started else {
      try channel.releaseAcceptedResult()
      do {
        _ = try await task.value
      } catch {
        Issue.record("host ended before working: \(error)")
      }
      await server.cancel()
      return
    }
    #expect(try Self.reportedStates(await server.requests.snapshot()) == ["working"])
    #expect(await launches.count == 0)
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await completion.isFinished == false)
    try channel.releaseAcceptedResult()
    #expect(try await task.value == 0)
    await server.cancel()
    #expect(await completion.isFinished)
    let requests = await server.requests.snapshot()
    #expect(try Self.reportedStates(requests) == ["working", "idle"])
    let reportPaneIDs = try requests.compactMap { request -> String? in
      let value = try Self.object(request)
      guard value["method"] as? String == "pane.report_agent" else { return nil }
      return (value["params"] as? [String: Any])?["pane_id"] as? String
    }
    #expect(reportPaneIDs == ["w-repo:p2", "w-moved:p9"])
    #expect(descriptor.schemaVersion == 3)
  }

  @Test(
    "prepared, accepted, and released crash boundaries never launch a second Pi process",
    arguments: ["prepared", "accepted", "released"]
  )
  func settledRestartSkipsLaunch(boundary: String) async throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    let channel = try settlement.resultChannel()
    try fixture.writeSettlementResult(settlement)
    if boundary != "prepared" { _ = try channel.acknowledgePreparedResult() }
    if boundary == "released" { try channel.releaseAcceptedResult() }
    let descriptor = try fixture.descriptor(settlement: settlement)
    _ = try fixture.prepare(descriptor)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let working = HostLaunchSignal()
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { request in
          if let object = try? Self.object(request),
            object["method"] as? String == "pane.report_agent",
            let parameters = object["params"] as? [String: Any],
            parameters["state"] as? String == "working"
          {
            working.markStarted()
          }
          return responder.response(to: request)
        })
      }
    )
    let launches = HostInvocationCounter()
    let task = Task {
      try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL),
        descriptorLoader: { _, _ in descriptor },
        launchOperation: { _ in
          await launches.record()
          return 0
        }
      )
    }
    let completionObserver = Task {
      _ = try? await task.value
      working.markFinishedBeforeStart()
    }
    let started = await working.waitForOutcome()
    completionObserver.cancel()
    #expect(started)
    if boundary == "prepared" { _ = try channel.acknowledgePreparedResult() }
    if boundary != "released" { try channel.releaseAcceptedResult() }
    #expect(try await task.value == 0)
    await server.finish()
    #expect(await launches.count == 0)
    #expect(try Self.reportedStates(await server.requests.snapshot()) == ["working", "idle"])
  }

  @Test("child success without an accepted Pi result is blocked")
  func missingSettlement() async throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    let descriptor = try fixture.descriptor(settlement: settlement)
    _ = try fixture.prepare(descriptor)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { responder.response(to: $0) })
      }
    )
    await #expect(throws: HerdrHostError.settlementMissing) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL),
        descriptorLoader: { _, _ in descriptor },
        launchOperation: { _ in 0 }
      )
    }
    await server.finish()
    #expect(try Self.reportedStates(await server.requests.snapshot()) == ["working", "blocked"])
  }

  @Test("structured TUI runtime failure overrides an opaque child status")
  func structuredTUIRuntimeFailure() async throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    try fixture.writeRuntimeFailure(code: "COMMAND_PROVENANCE_MISMATCH", settlement: settlement)
    let descriptor = try fixture.descriptor(settlement: settlement)
    _ = try fixture.prepare(descriptor)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { responder.response(to: $0) })
      }
    )
    await #expect(
      throws: HerdrHostError.tuiRuntimeFailed("COMMAND_PROVENANCE_MISMATCH")
    ) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL),
        descriptorLoader: { _, _ in descriptor },
        launchOperation: { _ in 70 }
      )
    }
    await server.finish()
  }

  @Test("launch nonzero exit and finish-report failures remain explicit")
  func lifecycleFailurePaths() async throws {
    let launchFixture = try HerdrHostFixture()
    let launchDescriptor = try launchFixture.descriptor()
    _ = try HerdrHostDescriptorStore.prepare(launchDescriptor, in: launchFixture.runRoot)
    let launchResponder = HerdrHostWireResponder(
      fixture: launchFixture,
      descriptor: launchDescriptor
    )
    let launchServer = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { launchResponder.response(to: $0) })
      }
    )
    await #expect(throws: HerdrHostError.launchFailed) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", launchDescriptor.launchAttemptID],
        environment: launchFixture.hostEnvironment(socketURL: launchServer.socketURL),
        launchOperation: { _ in throw HerdrHostError.launchFailed }
      )
    }
    await launchServer.finish()
    #expect(
      try Self.reportedStates(await launchServer.requests.snapshot()) == ["working", "blocked"])

    let nonzeroFixture = try HerdrHostFixture()
    let nonzeroDescriptor = try nonzeroFixture.descriptor()
    _ = try HerdrHostDescriptorStore.prepare(nonzeroDescriptor, in: nonzeroFixture.runRoot)
    let nonzeroResponder = HerdrHostWireResponder(
      fixture: nonzeroFixture,
      descriptor: nonzeroDescriptor
    )
    let nonzeroServer = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { nonzeroResponder.response(to: $0) })
      }
    )
    await #expect(throws: HerdrHostError.childFailed(23)) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", nonzeroDescriptor.launchAttemptID],
        environment: nonzeroFixture.hostEnvironment(socketURL: nonzeroServer.socketURL),
        launchOperation: { _ in 23 }
      )
    }
    await nonzeroServer.finish()
    #expect(
      try Self.reportedStates(await nonzeroServer.requests.snapshot()) == ["working", "blocked"])

    let reportFixture = try HerdrHostFixture()
    let reportDescriptor = try reportFixture.descriptor()
    _ = try HerdrHostDescriptorStore.prepare(reportDescriptor, in: reportFixture.runRoot)
    let reportResponder = HerdrHostWireResponder(
      fixture: reportFixture,
      descriptor: reportDescriptor
    )
    var reportReplies = (0..<7).map { _ in
      HerdrFakeReply(dynamicResponse: { reportResponder.response(to: $0) })
    }
    reportReplies.append(HerdrFakeReply(dynamicResponse: { Self.errorResponse(to: $0) }))
    let reportServer = try HerdrFakeSocketServer(replies: reportReplies)
    await #expect(throws: HerdrHostError.herdrTransactionFailed) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", reportDescriptor.launchAttemptID],
        environment: reportFixture.hostEnvironment(socketURL: reportServer.socketURL),
        launchOperation: { _ in 0 }
      )
    }
    await reportServer.finish()
    #expect(await reportServer.requests.snapshot().count == 8)
  }

  @Test("schema 3 binds logical run, nonce, role, workflow, channel, and TUI configuration")
  func settlementIdentityBinding() throws {
    let fixture = try HerdrHostFixture()
    let mismatched = try HerdrHostSettlementDescriptor(
      channelDirectory: fixture.settlementDirectory.resolvingSymlinksInPath().path,
      runID: "run-0002",
      runNonce: String(repeating: "b", count: 64),
      workflow: "issue-triage",
      role: "triage",
      nonce: "workflow-nonce",
      artifactSHA256: String(repeating: "a", count: 64),
      allowedCommandIDs: []
    )
    #expect(throws: HerdrHostError.invalidDescriptor) {
      _ = try fixture.descriptor(settlement: mismatched)
    }

    let otherChannel = fixture.root.appendingPathComponent("other-channel", isDirectory: true)
    try FileManager.default.createDirectory(
      at: otherChannel,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let redirected = try fixture.settlement(channelDirectory: otherChannel)
    #expect(throws: HerdrHostError.invalidDescriptor) {
      _ = try fixture.descriptor(settlement: redirected)
    }
  }

  @Test("schema 3 rejects every derived launch-family mutation after decode")
  func schema3DerivedLaunchMutation() throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    let descriptor = try fixture.descriptor(settlement: settlement)
    let encoded = try JSONEncoder().encode(descriptor)
    let base = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let mutations: [(String, (inout [String: Any]) -> Void)] = [
      ("executable", { $0["childExecutable"] = "/tmp/drift-node" }),
      (
        "arguments",
        {
          var values = $0["childArguments"] as? [String] ?? []
          values.append("--drift")
          $0["childArguments"] = values
        }
      ),
      (
        "environment",
        {
          var values = $0["childEnvironment"] as? [String: String] ?? [:]
          values["DRIFT"] = "1"
          $0["childEnvironment"] = values
        }
      ),
      ("working-directory", { $0["childWorkingDirectory"] = "/tmp" }),
      ("execution-timeout", { $0["executionTimeoutMilliseconds"] = 59_999 }),
      ("abort-grace", { $0["abortGraceMilliseconds"] = 999 }),
      (
        "settlement",
        {
          var value = $0["settlement"] as? [String: Any] ?? [:]
          value["runNonce"] = String(repeating: "c", count: 64)
          $0["settlement"] = value
        }
      ),
      (
        "TUI-configuration-digest",
        {
          var value = $0["piTUIInvocation"] as? [String: Any] ?? [:]
          value["tuiConfigurationSHA256"] = String(repeating: "d", count: 64)
          $0["piTUIInvocation"] = value
        }
      ),
    ]
    for (index, mutation) in mutations.enumerated() {
      var object = base
      mutation.1(&object)
      var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      data.append(0x0A)
      let root = fixture.root.appendingPathComponent(
        "schema3-mutation-\(index)",
        isDirectory: true
      )
      let run = root.appendingPathComponent(descriptor.launchAttemptID, isDirectory: true)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.createDirectory(
        at: run,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try writeHostPrivate(data, to: run.appendingPathComponent("launch.json"))
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try writeHostPrivate(
        Data("\(digest)\n".utf8),
        to: run.appendingPathComponent("launch.sha256")
      )
      do {
        _ = try fixture.load(
          launchAttemptID: descriptor.launchAttemptID,
          from: root
        )
        Issue.record("schema-3 mutation passed: \(mutation.0)")
      } catch let error as HerdrHostError {
        #expect(error == .invalidDescriptor)
      }
    }
  }

  @Test("topology launch attempt resolves the schema 3 descriptor for one logical run")
  func topologyLaunchIdentity() throws {
    let fixture = try HerdrHostFixture()
    let settlement = try fixture.settlement()
    let descriptor = try fixture.descriptor(settlement: settlement)
    _ = try fixture.prepare(descriptor)
    let launch = try HerdrHostLaunchPlan(
      role: "triage",
      paneLabel: "triage",
      runID: descriptor.runID,
      launchAttemptID: descriptor.launchAttemptID,
      agentAlias: descriptor.agentAlias,
      hostExecutable: fixture.childExecutable,
      descriptorRoot: fixture.runRoot,
      workingDirectory: fixture.workingDirectory
    )

    #expect(launch.runID != launch.launchAttemptID)
    #expect(
      launch.command
        == [fixture.childExecutable.path, "--launch-attempt-id", descriptor.launchAttemptID]
    )
    #expect(
      try fixture.load(launchAttemptID: launch.command[2]).runID == launch.runID
    )
  }

  @Test("execution timeout kills the exact process group and records a typed failure")
  func executionTimeoutCleanup() async throws {
    let fixture = try HerdrHostFixture()
    let descriptor = try fixture.descriptor(
      longRunning: true,
      executionTimeoutMilliseconds: 10_000,
      abortGraceMilliseconds: 100
    )
    _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { responder.response(to: $0) })
      },
      idleTimeoutSeconds: 15
    )
    await #expect(throws: HerdrHostError.executionTimedOut) {
      _ = try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL)
      )
    }
    let requests = await server.requests.snapshot()
    await server.cancel()
    #expect(try Self.reportedStates(requests) == ["working", "blocked"])
    let loadedFailure = try HerdrHostDescriptorStore.loadFailure(
      launchAttemptID: descriptor.launchAttemptID,
      from: fixture.runRoot
    )
    let failure = try #require(loadedFailure)
    #expect(failure.code == "EXECUTION_TIMED_OUT")
    try Self.assertExactProcessGroupAndCleanup(fixture.processLog)
  }

  @Test("task cancellation aborts and verifies the exact process group")
  func cancellationCleanup() async throws {
    let fixture = try HerdrHostFixture()
    let descriptor = try fixture.descriptor(
      longRunning: true,
      executionTimeoutMilliseconds: 10_000,
      abortGraceMilliseconds: 100
    )
    _ = try HerdrHostDescriptorStore.prepare(descriptor, in: fixture.runRoot)
    let responder = HerdrHostWireResponder(fixture: fixture, descriptor: descriptor)
    let server = try HerdrFakeSocketServer(
      replies: (0..<9).map { _ in
        HerdrFakeReply(dynamicResponse: { responder.response(to: $0) })
      },
      idleTimeoutSeconds: 15
    )
    let task = Task {
      try await HerdrHostRuntime.run(
        arguments: ["--launch-attempt-id", descriptor.launchAttemptID],
        environment: fixture.hostEnvironment(socketURL: server.socketURL)
      )
    }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: fixture.processLog.path) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let processStarted = FileManager.default.fileExists(atPath: fixture.processLog.path)
    #expect(processStarted)
    guard processStarted else {
      task.cancel()
      _ = try? await task.value
      await server.cancel()
      return
    }
    task.cancel()
    await #expect(throws: HerdrHostError.cancelled) { _ = try await task.value }
    let requests = await server.requests.snapshot()
    await server.cancel()
    #expect(try Self.reportedStates(requests) == ["working", "blocked"])
    let loadedFailure = try HerdrHostDescriptorStore.loadFailure(
      launchAttemptID: descriptor.launchAttemptID,
      from: fixture.runRoot
    )
    let failure = try #require(loadedFailure)
    #expect(failure.code == "CANCELLED")
    try Self.assertExactProcessGroupAndCleanup(fixture.processLog)
  }

  private static func assertExactProcessGroupAndCleanup(_ log: URL) throws {
    let lines = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    let rootFields = try #require(lines.first?.split(separator: " ").map(String.init))
    #expect(rootFields.count == 2)
    #expect(rootFields[0] == rootFields[1])
    for value in [rootFields[0], lines.last].compactMap({ $0 }).compactMap(Int32.init) {
      #expect(Darwin.kill(value, 0) == -1)
      #expect(errno == ESRCH)
    }
  }

  private static func reportedStates(_ requests: [Data]) throws -> [String] {
    try requests.compactMap { request in
      let value = try object(request)
      guard value["method"] as? String == "pane.report_agent" else { return nil }
      return (value["params"] as? [String: Any])?["state"] as? String
    }
  }

  private static func errorResponse(to request: Data) -> Data {
    let value = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
    let id = value?["id"] as? String ?? "invalid"
    return Data(
      "{\"id\":\"\(id)\",\"error\":{\"code\":\"rejected\",\"message\":\"fixture\"}}\n"
        .utf8
    )
  }

  private static func method(_ data: Data) throws -> String {
    try object(data)["method"] as? String ?? ""
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HerdrHostError.invalidDescriptor
    }
    return value
  }
}

private actor HostCompletionFlag {
  private(set) var isFinished = false

  func markFinished() { isFinished = true }
}

private func addHostEveryoneWriteACL(to url: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = ["+a", "everyone allow write", url.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw CocoaError(.fileWriteNoPermission)
  }
}

private actor HostInvocationCounter {
  private(set) var count = 0

  func record() { count += 1 }
}

private final class HostLaunchSignal: Sendable {
  private let continuation: AsyncStream<Bool>.Continuation
  private let stream: AsyncStream<Bool>

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func markStarted() {
    continuation.yield(true)
    continuation.finish()
  }

  func markFinishedBeforeStart() {
    continuation.yield(false)
    continuation.finish()
  }

  func waitForOutcome() async -> Bool {
    for await value in stream { return value }
    return false
  }
}

private final class HerdrHostFixture: @unchecked Sendable {
  private static let resolvedRuntime = Result {
    try PiRuntimeResolver(
      configuration: .standard(resourceRoot: sourceResourceRoot())
    ).resolve()
  }

  let root: URL
  let runRoot: URL
  let workingDirectory: URL
  let childExecutable: URL
  let childEnvironmentLog: URL
  let longRunningExecutable: URL
  let processLog: URL
  let settlementDirectory: URL
  let homeDirectory: URL
  let agentDirectory: URL
  let temporaryDirectory: URL
  let sessionDirectory: URL
  let promptURL: URL
  let workflowConfigurationURL: URL
  let tuiConfigurationURL: URL

  init() throws {
    root = URL(
      fileURLWithPath: "/tmp/jhh-\(UUID().uuidString.lowercased().prefix(8))",
      isDirectory: true
    )
    runRoot = root.appendingPathComponent("runs", isDirectory: true)
    workingDirectory = root.appendingPathComponent("work", isDirectory: true)
    childExecutable = root.appendingPathComponent("fixture-child")
    childEnvironmentLog = root.appendingPathComponent("child-environment.txt")
    longRunningExecutable = root.appendingPathComponent("long-running-child")
    processLog = root.appendingPathComponent("processes.txt")
    settlementDirectory = root.appendingPathComponent("settlement", isDirectory: true)
    homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    temporaryDirectory = root.appendingPathComponent("temporary", isDirectory: true)
    sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    promptURL = settlementDirectory.appendingPathComponent("prompt.txt")
    workflowConfigurationURL = settlementDirectory.appendingPathComponent("workflow.json")
    tuiConfigurationURL = settlementDirectory.appendingPathComponent("tui.json")
    try FileManager.default.createDirectory(
      at: runRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: workingDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    for directory in [
      settlementDirectory, homeDirectory, agentDirectory, temporaryDirectory, sessionDirectory,
    ] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    }
    let script = """
      #!/bin/sh
      /usr/bin/env > "$1"
      printf '{"fixture":"visible"}\\n'
      exit 0
      """
    let longRunningScript = """
      #!/bin/sh
      root_pid="$$"
      root_pgid="$(/bin/ps -o pgid= -p "$$" | /usr/bin/tr -d ' ')"
      printf '%s %s\n' "$root_pid" "$root_pgid" > "$1"
      /bin/sleep 30 &
      printf '%s\n' "$!" >> "$1"
      wait
      """
    guard
      FileManager.default.createFile(
        atPath: childExecutable.path,
        contents: Data(script.utf8),
        attributes: [.posixPermissions: 0o700]
      ),
      FileManager.default.createFile(
        atPath: longRunningExecutable.path,
        contents: Data(longRunningScript.utf8),
        attributes: [.posixPermissions: 0o700]
      ),
      Darwin.chmod(childExecutable.path, 0o700) == 0,
      Darwin.chmod(longRunningExecutable.path, 0o700) == 0
    else {
      throw HerdrHostError.invalidDescriptor
    }
    try writeHostPrivate(Data("Pinned host settlement prompt.\n".utf8), to: promptURL)
    try PiTUIInvocationBuilder.writeLockedSettings(in: agentDirectory)
    let resources = try PiWorkflowResourceCatalog.inspect(resourceRoot: sourceResourceRoot())
    let workflow = try PiWorkflowRuntimeConfiguration(
      workflow: .issueTriage,
      role: .triage,
      nonce: "workflow-nonce",
      artifactSHA256: String(repeating: "a", count: 64),
      allowedCommandIDs: [],
      allowedWritePaths: [],
      workspaceRoot: workingDirectory,
      resources: resources
    )
    try workflow.write(to: workflowConfigurationURL)
    let promptSHA256 = SHA256.hash(data: try Data(contentsOf: promptURL))
      .map { String(format: "%02x", $0) }.joined()
    let tui = try PiTUIRunConfiguration(
      runID: "run-0001",
      runNonce: String(repeating: "b", count: 64),
      workflow: .issueTriage,
      role: .triage,
      promptURL: promptURL,
      promptSHA256: promptSHA256,
      channelDirectory: settlementDirectory,
      workspaceRoot: workingDirectory,
      sessionDirectory: sessionDirectory,
      sessionName: "jidoka-host-fixture",
      launchMode: .fresh,
      expectedSessionID: nil,
      model: PiTUIModelIdentity(
        provider: "openai-codex",
        modelID: "gpt-5.6-sol",
        thinkingLevel: "max"
      ),
      expectedCommands: try resources.expectedCommandProvenance(
        workflow: .issueTriage,
        role: .triage
      ),
      acknowledgementTimeoutMilliseconds: 2_000
    )
    try tui.write(to: tuiConfigurationURL)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func prepare(_ descriptor: HerdrHostDescriptor) throws -> String {
    try HerdrHostDescriptorStore.prepare(
      descriptor,
      in: runRoot,
      resolvedRuntime: Self.resolvedRuntime.get()
    )
  }

  func load(
    launchAttemptID: String,
    from root: URL? = nil
  ) throws -> HerdrHostDescriptor {
    try HerdrHostDescriptorStore.load(
      launchAttemptID: launchAttemptID,
      from: root ?? runRoot,
      resolvedRuntime: Self.resolvedRuntime.get()
    )
  }

  func hostEnvironment(socketURL: URL) -> [String: String] {
    [
      "HERDR_SOCKET_PATH": socketURL.path,
      "HERDR_ENV": "1",
      "HERDR_WORKSPACE_ID": "w-repo",
      "HERDR_TAB_ID": "w-repo:t2",
      "HERDR_PANE_ID": "w-repo:p2",
      "HERDR_BIN_PATH": "/usr/local/bin/herdr",
      "JIDOKA_CODE_HERDR_RUN_ROOT": runRoot.path,
      "SECRET_SENTINEL": "must-not-reach-child",
    ]
  }

  func descriptor(
    environment: [String: String] = ["SAFE_VALUE": "fixture"],
    settlement: HerdrHostSettlementDescriptor? = nil,
    longRunning: Bool = false,
    executionTimeoutMilliseconds: Int = 3_600_000,
    abortGraceMilliseconds: Int = 5_000
  ) throws -> HerdrHostDescriptor {
    if let settlement {
      let invocation = try PiTUIHostInvocationDescriptor(
        resourceRoot: sourceResourceRoot(),
        homeDirectory: homeDirectory,
        agentDirectory: agentDirectory,
        temporaryDirectory: temporaryDirectory,
        workflowConfiguration: workflowConfigurationURL,
        tuiConfiguration: tuiConfigurationURL,
        offline: true,
        executionTimeoutMilliseconds: executionTimeoutMilliseconds,
        abortGraceMilliseconds: abortGraceMilliseconds
      )
      return try HerdrHostDescriptor(
        launchAttemptID: "attempt-0001",
        runID: settlement.runID,
        runNonce: settlement.runNonce,
        repositoryID: "repo-0001",
        jobID: "job-0001",
        generation: 1,
        role: settlement.role,
        agentAlias: "jc-h3-g1-triage",
        title: "Synthetic triage role",
        displayAgent: "Jidoka | triage",
        expectedWorkspaceID: "w-repo",
        piTUIInvocation: invocation,
        settlement: settlement,
        resolvedRuntime: try Self.resolvedRuntime.get()
      )
    }
    return try HerdrHostDescriptor(
      runID: "run-0001",
      runNonce: "nonce-00000000001",
      repositoryID: "repo-0001",
      jobID: "job-0001",
      generation: 1,
      role: "plan",
      agentAlias: "jc-h2-g1-plan",
      title: "Synthetic plan role",
      displayAgent: "Jidoka | plan",
      expectedWorkspaceID: "w-repo",
      childExecutable: longRunning ? longRunningExecutable.path : childExecutable.path,
      childArguments: [longRunning ? processLog.path : childEnvironmentLog.path],
      childWorkingDirectory: workingDirectory.path,
      childEnvironment: environment,
      executionTimeoutMilliseconds: executionTimeoutMilliseconds,
      abortGraceMilliseconds: abortGraceMilliseconds
    )
  }

  func settlement(channelDirectory: URL? = nil) throws -> HerdrHostSettlementDescriptor {
    try HerdrHostSettlementDescriptor(
      channelDirectory: (channelDirectory ?? settlementDirectory).resolvingSymlinksInPath().path,
      runID: "run-0001",
      runNonce: String(repeating: "b", count: 64),
      workflow: "issue-triage",
      role: "triage",
      nonce: "workflow-nonce",
      artifactSHA256: String(repeating: "a", count: 64),
      allowedCommandIDs: []
    )
  }

  func writeRuntimeFailure(
    code: String,
    settlement: HerdrHostSettlementDescriptor
  ) throws {
    let object: [String: Any] = [
      "code": code,
      "runID": settlement.runID,
      "runNonce": settlement.runNonce,
      "schemaVersion": 1,
      "status": "failed",
    ]
    let data =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data([0x0A])
    try writeHostPrivate(
      data,
      to: settlementDirectory.appendingPathComponent("runtime-failure.json")
    )
  }

  func writeSettlementResult(_ settlement: HerdrHostSettlementDescriptor) throws {
    let details: [String: Any] = [
      "approvedCommandIDs": [String](),
      "artifactSHA256": settlement.artifactSHA256,
      "nonce": settlement.nonce,
      "payload": [
        "complexityGuess": "humanOwned",
        "hardRiskFlags": ["security-or-secret-core"],
        "questions": [String](),
        "rationale": "Synthetic schema-valid triage payload.",
        "rubric": [
          "bounded": "yes", "safe": "human", "specified": "yes", "testable": "yes",
        ],
        "severity": "major",
        "summary": "Synthetic H3 host settlement result.",
        "verdict": "human",
      ],
      "resultSequence": 1,
      "role": settlement.role,
      "schemaVersion": 1,
      "workflow": settlement.workflow,
    ]
    let boundaryData = try PiTUIFileProtocol.canonicalJSONData(details)
    var object = details
    object.removeValue(forKey: "resultSequence")
    object["runID"] = settlement.runID
    object["runNonce"] = settlement.runNonce
    object["sessionBoundarySHA256"] = PiTUIFileProtocol.sha256(Data(boundaryData.dropLast()))
    let data =
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      + Data([0x0A])
    let destination = settlementDirectory.appendingPathComponent("result.json")
    try data.write(to: destination, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
  }
}

private func writeHostPrivate(_ data: Data, to url: URL) throws {
  try data.write(to: url, options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func sourceResourceRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Pi", isDirectory: true)
    .standardizedFileURL
}

private final class HerdrHostWireResponder: @unchecked Sendable {
  private let fixture: HerdrHostFixture
  private let descriptor: HerdrHostDescriptor
  private let moveTerminalOnFinish: Bool
  private let lock = NSLock()
  private var snapshotCount = 0

  init(
    fixture: HerdrHostFixture,
    descriptor: HerdrHostDescriptor,
    moveTerminalOnFinish: Bool = false
  ) {
    self.fixture = fixture
    self.descriptor = descriptor
    self.moveTerminalOnFinish = moveTerminalOnFinish
  }

  func response(to request: Data) -> Data {
    guard
      let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
      let id = object["id"] as? String,
      let method = object["method"] as? String
    else {
      return Data(
        "{\"id\":\"invalid\",\"error\":{\"code\":\"invalid_request\",\"message\":\"invalid\"}}\n"
          .utf8)
    }
    let result: String
    switch method {
    case "ping":
      result = """
        {"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}
        """
    case "session.snapshot":
      let moved = nextSnapshotIsMoved()
      let paneID = moved ? "w-moved:p9" : "w-repo:p2"
      let workspaceID = moved ? "w-moved" : "w-repo"
      let tabID = moved ? "w-moved:t9" : "w-repo:t2"
      result = """
        {"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null,"workspaces":[{"workspace_id":"\(workspaceID)","active_tab_id":"\(tabID)","label":"maroffo/jidoka-code","number":1,"pane_count":1,"tab_count":1,"focused":false,"agent_status":"working"}],"tabs":[{"tab_id":"\(tabID)","workspace_id":"\(workspaceID)","label":"j/h2/g1","number":1,"pane_count":1,"focused":false,"agent_status":"working"}],"panes":[{"pane_id":"\(paneID)","terminal_id":"term-host","workspace_id":"\(workspaceID)","tab_id":"\(tabID)","revision":1,"focused":false,"agent_status":"working","cwd":"\(escaped(fixture.workingDirectory.path))","foreground_cwd":"\(escaped(fixture.workingDirectory.path))"}],"agents":[]}}
        """
    case "agent.rename":
      result = """
        {"type":"agent_info","agent":{"agent":"pi","name":"\(descriptor.agentAlias)","pane_id":"w-repo:p2","terminal_id":"term-host","workspace_id":"w-repo","tab_id":"w-repo:t2","revision":2,"state_change_seq":2,"focused":false,"agent_status":"working","cwd":"\(escaped(fixture.workingDirectory.path))","foreground_cwd":"\(escaped(fixture.workingDirectory.path))"}}
        """
    case "pane.report_agent", "pane.report_metadata":
      result = "{\"type\":\"ok\"}"
    default:
      return Data(
        "{\"id\":\"\(id)\",\"error\":{\"code\":\"method_not_allowed\",\"message\":\"closed\"}}\n"
          .utf8)
    }
    return Data("{\"id\":\"\(id)\",\"result\":\(result)}\n".utf8)
  }

  private func nextSnapshotIsMoved() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    snapshotCount += 1
    return moveTerminalOnFinish && snapshotCount > 1
  }

  private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
