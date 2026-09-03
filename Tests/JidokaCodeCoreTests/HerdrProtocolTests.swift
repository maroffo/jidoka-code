import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Herdr protocol and explicit socket boundary", .serialized)
struct HerdrProtocolTests {
  @Test("NDJSON parser preserves fragmented and coalesced records")
  func parserBoundaries() throws {
    var parser = try HerdrNDJSONParser(maximumRecordBytes: 1_024)
    #expect(try parser.append(Data("{\"id\":\"a".utf8)).isEmpty)
    let records = try parser.append(Data("\"}\n{\"id\":\"b\"}\n".utf8))
    #expect(records == [Data("{\"id\":\"a\"}".utf8), Data("{\"id\":\"b\"}".utf8)])
    try parser.finish()

    var incomplete = try HerdrNDJSONParser(maximumRecordBytes: 1_024)
    _ = try incomplete.append(Data("{}".utf8))
    #expect(throws: HerdrSocketClientError.incompleteRecord) {
      try incomplete.finish()
    }

    var oversized = try HerdrNDJSONParser(maximumRecordBytes: 4)
    #expect(throws: HerdrSocketClientError.recordTooLarge) {
      _ = try oversized.append(Data("12345".utf8))
    }
  }

  @Test("exact handshake decodes snapshot without touching focus")
  func exactHandshake() async throws {
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "req-1"), splitAt: [1, 7, 19]),
        HerdrFakeReply(Self.snapshot(id: "req-2"), splitAt: [3, 31, 113]),
      ]
    )
    let client = try Self.client(server: server, ids: ["req-1", "req-2"])
    let handshake = try await client.handshake()
    #expect(handshake.pong.version == "0.8.2")
    #expect(handshake.pong.protocolVersion == 20)
    #expect(handshake.snapshot.focusedWorkspaceID == "w-user")
    #expect(handshake.snapshot.workspaces.map(\.workspaceID) == ["w-user", "w-jidoka"])
    #expect(handshake.snapshot.tabs.last?.label == "j/imp/i42/k7m2/g2")
    #expect(handshake.snapshot.panes.last?.terminalID == "term-jidoka")
    #expect(handshake.snapshot.agents.last?.tokens?["managed_by"] == "jidoka")
    let requests = await server.requests.snapshot()
    #expect(try requests.map(Self.method) == ["ping", "session.snapshot"])
    await server.finish()
  }

  @Test("version protocol and capability drift fail closed")
  func compatibilityDrift() async throws {
    for (reply, expected) in [
      (
        Self.pong(id: "req", version: "0.8.1"),
        HerdrCompatibilityError.versionMismatch
      ),
      (
        Self.pong(id: "req", protocolVersion: 19),
        HerdrCompatibilityError.protocolMismatch
      ),
      (
        Self.pong(id: "req", liveHandoff: false),
        HerdrCompatibilityError.missingLiveHandoff
      ),
      (
        Self.pong(id: "req", detachedServerDaemon: false),
        HerdrCompatibilityError.missingDetachedServerDaemon
      ),
    ] {
      let server = try HerdrFakeSocketServer(replies: [HerdrFakeReply(reply)])
      let client = try Self.client(server: server, ids: ["req"])
      await #expect(throws: expected) {
        _ = try await client.handshake()
      }
      await server.finish()
      #expect(await server.requests.snapshot().count == 1)
    }
  }

  @Test("snapshot must match the attested ping")
  func snapshotMismatch() async throws {
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "req-1")),
        HerdrFakeReply(Self.snapshot(id: "req-2", protocolVersion: 19)),
      ]
    )
    let client = try Self.client(server: server, ids: ["req-1", "req-2"])
    await #expect(throws: HerdrCompatibilityError.snapshotMismatch) {
      _ = try await client.handshake()
    }
    await server.finish()
  }

  @Test("response IDs are exact")
  func responseCorrelation() async throws {
    let wrongID = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "other"))]
    )
    let wrongIDClient = try Self.client(server: wrongID, ids: ["req"])
    await #expect(throws: HerdrSocketClientError.responseIDMismatch) {
      _ = try await wrongIDClient.ping()
    }
    await wrongID.finish()
  }

  @Test("remote errors expose only a validated code")
  func typedRemoteError() async throws {
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(
          "{\"id\":\"req\",\"error\":{\"code\":\"not_found\",\"message\":\"foreign detail\"}}\n"
        )
      ]
    )
    let client = try Self.client(server: server, ids: ["req"])
    await #expect(throws: HerdrSocketClientError.remote("not_found")) {
      _ = try await client.ping()
    }
    await server.finish()

    let invalid = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(
          "{\"id\":\"req\",\"error\":{\"code\":\"BAD CODE\",\"message\":\"x\"}}\n"
        )
      ]
    )
    let invalidClient = try Self.client(server: invalid, ids: ["req"])
    await #expect(throws: HerdrSocketClientError.invalidRemoteError) {
      _ = try await invalidClient.ping()
    }
    await invalid.finish()
  }

  @Test("malformed UTF-8 oversize and missing LF are rejected")
  func malformedRecords() async throws {
    var invalidUTF8 = Data(Self.pong(id: "req").utf8)
    let version = try #require(invalidUTF8.range(of: Data("0.8.2".utf8)))
    invalidUTF8[version.lowerBound] = 0xFF
    let malformed = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(chunks: [invalidUTF8])]
    )
    let malformedClient = try Self.client(server: malformed, ids: ["req"])
    await #expect(throws: HerdrSocketClientError.invalidRecord) {
      _ = try await malformedClient.ping()
    }
    await malformed.finish()

    let oversize = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(chunks: [Data(repeating: 0x61, count: 1_025)])]
    )
    let oversizeClient = try Self.client(
      server: oversize,
      ids: ["req"],
      maximumRecordBytes: 1_024
    )
    await #expect(throws: HerdrSocketClientError.recordTooLarge) {
      _ = try await oversizeClient.ping()
    }
    await oversize.finish()

    let incomplete = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req").trimmingCharacters(in: .newlines))]
    )
    let incompleteClient = try Self.client(server: incomplete, ids: ["req"])
    await #expect(throws: HerdrSocketClientError.incompleteRecord) {
      _ = try await incompleteClient.ping()
    }
    await incomplete.finish()
  }

  @Test("deadline bounds a server that accepts but does not answer")
  func timeout() async throws {
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(
          Self.pong(id: "req"),
          delayNanoseconds: 250_000_000
        )
      ]
    )
    let client = try Self.client(server: server, ids: ["req"], timeoutSeconds: 0.05)
    let startedAt = ProcessInfo.processInfo.systemUptime
    await #expect(throws: HerdrSocketClientError.timedOut) {
      _ = try await client.ping()
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    #expect(elapsed >= 0.04)
    // Scheduler contention and sanitizer instrumentation can delay the task's
    // post-timeout resumption while the typed timeout still wins. Keep a finite
    // hang detector; the client deadline itself remains 50 milliseconds.
    let processSymbols = UnsafeMutableRawPointer(bitPattern: -2)  // Darwin RTLD_DEFAULT.
    let sanitizerActive =
      dlsym(processSymbols, "__asan_init") != nil
      || dlsym(processSymbols, "__tsan_init") != nil
    #expect(elapsed < (sanitizerActive ? 30.0 : 15.0))
    await server.finish()
  }

  @Test("replacement launch exposes only exact split, escaped exec text, and enter")
  func typedReplacementLaunch() async throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(
        "replacement-launch-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let descriptorRoot = root.appendingPathComponent("descriptors", isDirectory: true)
    try FileManager.default.createDirectory(
      at: descriptorRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executable = root.appendingPathComponent("host'quoted")
    try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let canonicalRoot = try PiTUIFileProtocol.canonicalExistingURL(root)
    let canonicalExecutable = try PiTUIFileProtocol.canonicalExistingURL(executable)
    let hostExecutableSHA256 = GitHubMarkerCodec.sha256(
      try Data(contentsOf: canonicalExecutable, options: [.mappedIfSafe])
    )
    let canonicalDescriptorRoot = try PiTUIFileProtocol.canonicalExistingURL(descriptorRoot)
    let launch: HerdrReplacementRoleHostLaunch
    do {
      launch = try HerdrReplacementRoleHostLaunch(
        targetPaneID: "w-user:p1",
        workspaceID: "w-user",
        workingDirectory: canonicalRoot,
        hostExecutable: canonicalExecutable,
        hostExecutableSHA256: hostExecutableSHA256,
        descriptorRoot: canonicalDescriptorRoot,
        roleHostID: "replacement-role-host-0001"
      )
    } catch {
      Issue.record("typed replacement plan rejected: \(error)")
      throw error
    }
    #expect(throws: HerdrTopologyError.invalidPlan) {
      _ = try HerdrReplacementRoleHostLaunch(
        targetPaneID: "w-user:p1",
        workspaceID: "w-user",
        workingDirectory: root,
        hostExecutable: executable,
        hostExecutableSHA256: hostExecutableSHA256,
        descriptorRoot: descriptorRoot,
        roleHostID: "replacement;touch-pwned"
      )
    }

    func snapshot(id: String, includeReplacement: Bool = true) -> String {
      let replacementPane =
        includeReplacement
        ? ",{\"pane_id\":\"w-user:p2\",\"terminal_id\":\"term-replacement\",\"workspace_id\":\"w-user\",\"tab_id\":\"w-user:t1\",\"revision\":1,\"focused\":false,\"agent_status\":\"unknown\",\"cwd\":\"\(root.path)\",\"foreground_cwd\":\"\(root.path)\"}"
        : ""
      return """
        {"id":"\(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.2","protocol":20,"focused_workspace_id":"w-user","focused_tab_id":"w-user:t1","focused_pane_id":"w-user:p1","workspaces":[{"workspace_id":"w-user","active_tab_id":"w-user:t1","label":"personal","number":1,"pane_count":\(includeReplacement ? 2 : 1),"tab_count":1,"focused":true,"agent_status":"unknown"},{"workspace_id":"w-jidoka","active_tab_id":"w-jidoka:t1","label":"maroffo/jidoka-code","number":2,"pane_count":1,"tab_count":1,"focused":false,"agent_status":"working"}],"tabs":[{"tab_id":"w-user:t1","workspace_id":"w-user","label":"main","number":1,"pane_count":\(includeReplacement ? 2 : 1),"focused":true,"agent_status":"unknown"},{"tab_id":"w-jidoka:t1","workspace_id":"w-jidoka","label":"job","number":1,"pane_count":1,"focused":false,"agent_status":"working"}],"panes":[{"pane_id":"w-user:p1","terminal_id":"term-user","workspace_id":"w-user","tab_id":"w-user:t1","revision":1,"focused":true,"agent_status":"unknown","cwd":"/tmp/user","foreground_cwd":"/tmp/user"},{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","tokens":{"managed_by":"jidoka","run_id":"run-1"}}\(replacementPane)],"agents":[{"agent":"pi","name":"jc-job","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"state_change_seq":9,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","screen_detection_skipped":true,"tokens":{"managed_by":"jidoka","run_id":"run-1"}}]}}}
        """ + "\n"
    }
    let split = """
      {"id":"split","result":{"type":"pane_created","pane":{"pane_id":"w-user:p2","terminal_id":"term-replacement","workspace_id":"w-user","tab_id":"w-user:t1","revision":1,"focused":false,"agent_status":"unknown","cwd":"\(root.path)","foreground_cwd":"\(root.path)"}}}
      """ + "\n"
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping-0")),
        HerdrFakeReply(snapshot(id: "snapshot-0", includeReplacement: false)),
        HerdrFakeReply(split),
        HerdrFakeReply(Self.pong(id: "ping-1")), HerdrFakeReply(snapshot(id: "snapshot-1")),
        HerdrFakeReply("{\"id\":\"text\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply(Self.pong(id: "ping-2")), HerdrFakeReply(snapshot(id: "snapshot-2")),
        HerdrFakeReply("{\"id\":\"enter\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply(Self.pong(id: "ping-3")), HerdrFakeReply(snapshot(id: "snapshot-3")),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: [
        "ping-0", "snapshot-0", "split", "ping-1", "snapshot-1", "text",
        "ping-2", "snapshot-2", "enter", "ping-3", "snapshot-3",
      ]
    )
    let handshake = try await client.handshake()
    let pane: HerdrPaneSnapshot
    do {
      pane = try await client.launchReplacementRoleHost(launch, attestedBy: handshake)
    } catch {
      let methods = try await server.requests.snapshot().map(Self.method)
      Issue.record("replacement launch failed after methods \(methods): \(error)")
      throw error
    }
    #expect(pane.paneID == "w-user:p2")
    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method) == [
        "ping", "session.snapshot", "pane.split", "ping", "session.snapshot",
        "pane.send_text", "ping", "session.snapshot", "pane.send_keys", "ping",
        "session.snapshot",
      ]
    )
    let textRequest = try Self.object(requests[5])
    let textParameters = try #require(textRequest["params"] as? [String: Any])
    #expect(textParameters["pane_id"] as? String == "w-user:p2")
    let exactText = try launch.shellCommand(pane: pane, socketPath: server.socketURL.path)
    #expect(textParameters["text"] as? String == exactText)
    let expectedArguments = [
      "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "/bin/sh", "-c", "exec \"$@\"",
      "jidoka-role-host", "/usr/bin/env", "-i", "HOME=/var/empty", "PATH=/usr/bin:/bin",
      "TMPDIR=/tmp", "HERDR_PANE_ID=\(pane.paneID)",
      "HERDR_SOCKET_PATH=\(server.socketURL.path)", "HERDR_TAB_ID=\(pane.tabID)",
      "HERDR_WORKSPACE_ID=\(pane.workspaceID)",
      "JIDOKA_CODE_HERDR_RUN_ROOT=\(canonicalDescriptorRoot.path)",
      canonicalExecutable.path, "--role-host-id", "replacement-role-host-0001",
    ]
    #expect(exactText == expectedArguments.map(Self.quoteShellArgument).joined(separator: " "))
    #expect(exactText.hasPrefix("'/usr/bin/env' '-i' 'PATH=/usr/bin:/bin' '/bin/sh'"))
    #expect(exactText.contains("'exec \"$@\"'"))
    #expect(exactText.contains("'\(executable.path.replacingOccurrences(of: "'", with: "'\\''"))'"))
    #expect(!exactText.localizedCaseInsensitiveContains("token"))
    #expect(!exactText.localizedCaseInsensitiveContains("credential"))
    let fixtureSecrets = [String(repeating: "a", count: 32), String(repeating: "b", count: 32)]
    for secret in fixtureSecrets {
      #expect(!exactText.contains(secret))
      #expect(
        requests.allSatisfy {
          String(decoding: $0, as: UTF8.self).contains(secret) == false
        }
      )
    }
    let hostileShell = Process()
    hostileShell.executableURL = URL(fileURLWithPath: "/bin/sh")
    hostileShell.arguments = [
      "-c", "exec() { exit 97; }; alias exec='exit 98'; \(exactText)",
    ]
    try hostileShell.run()
    hostileShell.waitUntilExit()
    #expect(hostileShell.terminationStatus == 0)
    let keyRequest = try Self.object(requests[8])
    let keyParameters = try #require(keyRequest["params"] as? [String: Any])
    #expect(keyParameters["pane_id"] as? String == "w-user:p2")
    #expect(keyParameters["keys"] as? [String] == ["enter"])
    await server.finish()

    var changedExecutable = try Data(contentsOf: executable)
    changedExecutable.append(Data("changed-after-attestation".utf8))
    try changedExecutable.write(to: executable)
    #expect(throws: HerdrTopologyError.invalidPlan) {
      _ = try launch.shellCommand(pane: pane, socketPath: server.socketURL.path)
    }
  }

  @Test(
    "replacement launch fault cuts stop at the exact typed boundary",
    arguments: ReplacementLaunchFault.allCases
  )
  func typedReplacementLaunchFaults(fault: ReplacementLaunchFault) async throws {
    let fixture = try Self.makeReplacementLaunchFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let server = try HerdrFakeSocketServer(
      replies: try Self.replacementFaultReplies(
        fault: fault,
        workingDirectory: fixture.root.path
      ),
      idleTimeoutSeconds: 0.25
    )
    let client = try Self.client(
      server: server,
      ids: [
        "ping-0", "snapshot-0", "split", "ping-1", "snapshot-1", "text",
        "ping-2", "snapshot-2", "enter", "ping-3", "snapshot-3",
      ],
      timeoutSeconds: fault.isTimeout ? 0.05 : 0.5
    )
    let handshake = try await client.handshake()
    let startedAt = ProcessInfo.processInfo.systemUptime
    var observedError: (any Error)?
    do {
      _ = try await client.launchReplacementRoleHost(
        fixture.launch,
        attestedBy: handshake
      )
    } catch {
      observedError = error
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    let failure = try #require(observedError)
    #expect(fault.matches(failure))
    #expect(elapsed < 2)

    let requests = await server.requests.snapshot()
    #expect(try requests.map(Self.method) == fault.expectedMethods)
    let requestText = requests.map { String(decoding: $0, as: UTF8.self) }.joined()
    #expect(!requestText.contains(String(repeating: "a", count: 32)))
    #expect(!requestText.contains(String(repeating: "b", count: 32)))
    await server.cancel()
  }

  @Test("typed workspace and layout mutations encode only no-focus exact argv")
  func typedTopologyMutations() async throws {
    let workspaceResponse = """
      {"id":"create","result":{"type":"workspace_created","workspace":{"workspace_id":"w-new","active_tab_id":"w-new:t1","label":"owner/repo","number":2,"pane_count":1,"tab_count":1,"focused":false,"agent_status":"unknown"},"tab":{"tab_id":"w-new:t1","workspace_id":"w-new","label":"1","number":1,"pane_count":1,"focused":false,"agent_status":"unknown"},"root_pane":{"pane_id":"w-new:p1","terminal_id":"term-root","workspace_id":"w-new","tab_id":"w-new:t1","revision":1,"focused":false,"agent_status":"unknown","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo"}}}
      """ + "\n"
    let layoutResponse = """
      {"id":"layout","result":{"type":"layout_apply","layout":{"workspace_id":"w-new","tab_id":"w-new:t2","zoomed":false,"focused_pane_id":"w-new:p2","root":{"type":"pane","pane_id":"w-new:p2","label":"plan","cwd":"/tmp/repo","command":["/app/JidokaCodeHerdrHost","--launch-attempt-id","run-0001"],"env":{"JIDOKA_CODE_HERDR_RUN_ROOT":"/tmp/runs"}}}}}
      """ + "\n"
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
        HerdrFakeReply(workspaceResponse),
        HerdrFakeReply(layoutResponse),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: ["ping", "snapshot", "create", "layout"]
    )
    let handshake = try await client.handshake()
    let workspace = try await client.createWorkspace(
      HerdrWorkspaceCreateParameters(
        label: "owner/repo",
        cwd: "/tmp/repo",
        env: [:],
        focus: false
      ),
      attestedBy: handshake
    )
    #expect(workspace.workspace.workspaceID == "w-new")
    let root = HerdrLayoutNode.pane(
      HerdrLayoutPane(
        label: "plan",
        workingDirectory: "/tmp/repo",
        command: ["/app/JidokaCodeHerdrHost", "--launch-attempt-id", "run-0001"],
        environment: ["JIDOKA_CODE_HERDR_RUN_ROOT": "/tmp/runs"]
      )
    )
    let layout = try await client.applyLayout(
      HerdrLayoutApplyParameters(
        workspaceID: "w-new",
        tabLabel: "j/imp/i1/job1/g1",
        focus: false,
        root: root
      ),
      attestedBy: handshake
    )
    #expect(layout.layout.tabID == "w-new:t2")

    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method) == [
        "ping", "session.snapshot", "workspace.create", "layout.apply",
      ]
    )
    let create = try Self.object(requests[2])
    #expect(Set(create.keys) == ["id", "method", "params"])
    #expect(create["id"] as? String == "create")
    let createParameters = try #require(create["params"] as? [String: Any])
    #expect(Set(createParameters.keys) == ["label", "cwd", "env", "focus"])
    #expect(createParameters["label"] as? String == "owner/repo")
    #expect(createParameters["cwd"] as? String == "/tmp/repo")
    #expect((createParameters["env"] as? [String: Any])?.isEmpty == true)
    #expect(createParameters["focus"] as? Bool == false)

    let apply = try Self.object(requests[3])
    #expect(Set(apply.keys) == ["id", "method", "params"])
    #expect(apply["id"] as? String == "layout")
    let parameters = try #require(apply["params"] as? [String: Any])
    #expect(Set(parameters.keys) == ["workspace_id", "tab_label", "focus", "root"])
    #expect(parameters["workspace_id"] as? String == "w-new")
    #expect(parameters["tab_label"] as? String == "j/imp/i1/job1/g1")
    #expect(parameters["focus"] as? Bool == false)
    let encodedRoot = try #require(parameters["root"] as? [String: Any])
    #expect(Set(encodedRoot.keys) == ["type", "label", "cwd", "command", "env"])
    #expect(encodedRoot["type"] as? String == "pane")
    #expect(encodedRoot["label"] as? String == "plan")
    #expect(encodedRoot["cwd"] as? String == "/tmp/repo")
    #expect(
      encodedRoot["command"] as? [String]
        == ["/app/JidokaCodeHerdrHost", "--launch-attempt-id", "run-0001"]
    )
    #expect(
      encodedRoot["env"] as? [String: String]
        == ["JIDOKA_CODE_HERDR_RUN_ROOT": "/tmp/runs"]
    )
    #expect(!(String(data: requests[3], encoding: .utf8) ?? "").contains("sh -c"))
    await server.finish()
  }

  @Test("user focus encodes only exact workspace, tab, and pane targets")
  func explicitFocusRequests() async throws {
    let workspaceResponse = """
      {"id":"focus-workspace","result":{"type":"workspace_info","workspace":{"workspace_id":"w-jidoka","active_tab_id":"w-jidoka:t1","label":"maroffo/jidoka-code","number":2,"pane_count":1,"tab_count":1,"focused":true,"agent_status":"working"}}}
      """ + "\n"
    let tabResponse = """
      {"id":"focus-tab","result":{"type":"tab_info","tab":{"tab_id":"w-jidoka:t1","workspace_id":"w-jidoka","label":"j/imp/i42/k7m2/g2","number":1,"pane_count":1,"focused":true,"agent_status":"working"}}}
      """ + "\n"
    let paneResponse = """
      {"id":"focus-pane","result":{"type":"pane_info","pane":{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"focused":true,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo"}}}
      """ + "\n"
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
        HerdrFakeReply(workspaceResponse),
        HerdrFakeReply(tabResponse),
        HerdrFakeReply(paneResponse),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: ["ping", "snapshot", "focus-workspace", "focus-tab", "focus-pane"]
    )
    let handshake = try await client.handshake()
    try await client.focusWorkspace(workspaceID: "w-jidoka", attestedBy: handshake)
    try await client.focusTab(tabID: "w-jidoka:t1", attestedBy: handshake)
    try await client.focusPane(paneID: "w-jidoka:p1", attestedBy: handshake)

    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method)
        == ["ping", "session.snapshot", "workspace.focus", "tab.focus", "pane.focus"]
    )
    let workspace = try Self.object(requests[2])
    let workspaceParameters = try #require(workspace["params"] as? [String: Any])
    #expect(Set(workspaceParameters.keys) == ["workspace_id"])
    #expect(workspaceParameters["workspace_id"] as? String == "w-jidoka")
    let tab = try Self.object(requests[3])
    let tabParameters = try #require(tab["params"] as? [String: Any])
    #expect(Set(tabParameters.keys) == ["tab_id"])
    #expect(tabParameters["tab_id"] as? String == "w-jidoka:t1")
    let pane = try Self.object(requests[4])
    let paneParameters = try #require(pane["params"] as? [String: Any])
    #expect(Set(paneParameters.keys) == ["pane_id"])
    #expect(paneParameters["pane_id"] as? String == "w-jidoka:p1")
    await server.finish()
  }

  @Test("socket mode owner and symlink boundaries fail before connect")
  func socketFilesystemBoundary() async throws {
    let unsafeMode = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req"))],
      permissions: 0o660
    )
    let unsafeModeAttempts = HerdrConnectionAttemptRecorder()
    let unsafeModeClient = try Self.client(
      server: unsafeMode,
      ids: ["req"],
      exchanger: SystemHerdrSocketExchange { unsafeModeAttempts.record($0) }
    )
    await #expect(throws: HerdrSocketClientError.unsafeSocket) {
      _ = try await unsafeModeClient.ping()
    }
    #expect(unsafeModeAttempts.snapshot().isEmpty)
    await unsafeMode.cancel()

    let unsafeParent = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req"))]
    )
    #expect(Darwin.chmod(unsafeParent.rootURL.path, 0o770) == 0)
    let unsafeParentAttempts = HerdrConnectionAttemptRecorder()
    let unsafeParentClient = try Self.client(
      server: unsafeParent,
      ids: ["req"],
      exchanger: SystemHerdrSocketExchange { unsafeParentAttempts.record($0) }
    )
    await #expect(throws: HerdrSocketClientError.unsafeSocket) {
      _ = try await unsafeParentClient.ping()
    }
    #expect(unsafeParentAttempts.snapshot().isEmpty)
    await unsafeParent.cancel()

    let wrongOwner = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req"))]
    )
    let wrongOwnerConfiguration = try HerdrSocketClientConfiguration(
      endpoint: wrongOwner.socketURL,
      expectedOwner: geteuid() &+ 1
    )
    let wrongOwnerAttempts = HerdrConnectionAttemptRecorder()
    let wrongOwnerClient = HerdrSocketClient(
      configuration: wrongOwnerConfiguration,
      requestID: { "req" },
      exchanger: SystemHerdrSocketExchange { wrongOwnerAttempts.record($0) }
    )
    await #expect(throws: HerdrSocketClientError.unsafeSocket) {
      _ = try await wrongOwnerClient.ping()
    }
    #expect(wrongOwnerAttempts.snapshot().isEmpty)
    await wrongOwner.cancel()

    let symlinkTarget = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req"))]
    )
    let link = symlinkTarget.rootURL.appendingPathComponent("link.sock")
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: symlinkTarget.socketURL
    )
    let symlinkConfiguration = try HerdrSocketClientConfiguration(endpoint: link)
    let symlinkAttempts = HerdrConnectionAttemptRecorder()
    let symlinkClient = HerdrSocketClient(
      configuration: symlinkConfiguration,
      requestID: { "req" },
      exchanger: SystemHerdrSocketExchange { symlinkAttempts.record($0) }
    )
    await #expect(throws: HerdrSocketClientError.unsafeSocket) {
      _ = try await symlinkClient.ping()
    }
    #expect(symlinkAttempts.snapshot().isEmpty)
    await symlinkTarget.cancel()
  }

  @Test("an explicit missing endpoint never reaches connect or a fallback")
  func noDefaultFallback() async throws {
    let root = URL(
      fileURLWithPath: "/tmp/jh-\(UUID().uuidString.lowercased().prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = root.appendingPathComponent("missing.sock")
    let configuration = try HerdrSocketClientConfiguration(endpoint: endpoint)
    let attempts = HerdrConnectionAttemptRecorder()
    let client = HerdrSocketClient(
      configuration: configuration,
      requestID: { "req" },
      exchanger: SystemHerdrSocketExchange { attempts.record($0) }
    )
    await #expect(throws: HerdrSocketClientError.unsafeSocket) {
      _ = try await client.ping()
    }
    #expect(attempts.snapshot().isEmpty)
  }

  @Test("an attested sequence pins socket identity before its next request")
  func sequencePinsIdentityBeforeRequest() async throws {
    let exchanger = RotatingHerdrSocketExchange()
    let sequence = HerdrRequestIDSequence(["ping", "snapshot"])
    let client = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: URL(fileURLWithPath: "/unused/herdr.sock")
      ),
      requestID: { sequence.next() },
      exchanger: exchanger
    )
    await #expect(throws: HerdrSocketClientError.socketChanged) {
      _ = try await client.handshake()
    }
    #expect(await exchanger.sentRequestCount() == 1)
    #expect(await exchanger.expectedIdentityCheckCount() == 1)

    let hostExchanger = RotatingHerdrSocketExchange()
    let hostIDs = HerdrRequestIDSequence(["ping", "snapshot", "agent", "metadata", "rename"])
    let hostClient = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: URL(fileURLWithPath: "/unused/herdr.sock")
      ),
      requestID: { hostIDs.next() },
      exchanger: hostExchanger
    )
    await #expect(throws: HerdrSocketClientError.socketChanged) {
      _ = try await hostClient.startHostPane(
        paneID: "w1:p1",
        workspaceID: "w1",
        tabID: "w1:t1",
        expectedTerminalID: "term-1",
        agent: HerdrPaneReportAgentParameters(
          paneID: "w1:p1",
          source: "jidoka:run:run-0001",
          agent: "custom",
          state: .working,
          message: "running",
          sequence: 1
        ),
        metadata: HerdrPaneReportMetadataParameters(
          paneID: "w1:p1",
          source: "jidoka:run:run-0001",
          agent: "custom",
          appliesToSource: "jidoka:run:run-0001",
          title: "Plan",
          displayAgent: "Jidoka | plan",
          stateLabels: ["working": "planning"],
          tokens: ["managed_by": "jidoka", "run_id": "run-0001"],
          sequence: 1
        ),
        alias: "jc-plan"
      )
    }
    #expect(await hostExchanger.sentRequestCount() == 1)
    #expect(await hostExchanger.expectedIdentityCheckCount() == 1)
  }

  @Test(
    "every request and validated sequence reject one-field connected-peer drift",
    arguments: HerdrPeerEvidenceDrift.allCases
  )
  func connectedPeerEvidenceIsPinned(drift: HerdrPeerEvidenceDrift) async throws {
    let baseline = try currentPeerEvidence()
    let changed = try driftedPeerEvidence(baseline, drift: drift)
    let exchanger = DriftingHerdrPeerExchange(baseline: baseline, changed: changed)
    let sequence = HerdrRequestIDSequence(["ping", "snapshot"])
    let client = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: URL(fileURLWithPath: "/unused/herdr.sock")
      ),
      requestID: { sequence.next() },
      exchanger: exchanger
    )
    await #expect(throws: HerdrSocketClientError.socketChanged) {
      _ = try await client.handshake()
    }
    #expect(await exchanger.sentRequestCount() == 1)
    #expect(await exchanger.expectedAuthorityCheckCount() == 1)

    let sequenceExchanger = DriftingHerdrPeerExchange(
      baseline: baseline,
      changed: changed
    )
    let hostIDs = HerdrRequestIDSequence(["ping", "snapshot", "agent", "metadata"])
    let hostClient = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: URL(fileURLWithPath: "/unused/herdr.sock")
      ),
      requestID: { hostIDs.next() },
      exchanger: sequenceExchanger
    )
    await #expect(throws: HerdrSocketClientError.socketChanged) {
      _ = try await hostClient.startHostPane(
        paneID: "w1:p1",
        workspaceID: "w1",
        tabID: "w1:t1",
        expectedTerminalID: "term-1",
        agent: HerdrPaneReportAgentParameters(
          paneID: "w1:p1",
          source: "jidoka:run:run-0001",
          agent: "custom",
          state: .working,
          message: "running",
          sequence: 1
        ),
        metadata: HerdrPaneReportMetadataParameters(
          paneID: "w1:p1",
          source: "jidoka:run:run-0001",
          agent: "custom",
          appliesToSource: "jidoka:run:run-0001",
          title: "Plan",
          displayAgent: "Jidoka | plan",
          stateLabels: ["working": "planning"],
          tokens: ["managed_by": "jidoka", "run_id": "run-0001"],
          sequence: 1
        ),
        alias: nil
      )
    }
    #expect(await sequenceExchanger.sentRequestCount() == 1)
    #expect(await sequenceExchanger.expectedAuthorityCheckCount() == 1)
  }

  @Test("peer evidence unavailability fails before the request is written")
  func connectedPeerEvidenceUnavailable() async throws {
    let server = try HerdrFakeSocketServer(
      replies: [HerdrFakeReply(Self.pong(id: "req"))],
      idleTimeoutSeconds: 0.25
    )
    let client = try Self.client(
      server: server,
      ids: ["req"],
      exchanger: SystemHerdrSocketExchange(peerEvidence: { _, _ in
        throw HerdrSocketClientError.unsafePeer
      })
    )
    await #expect(throws: HerdrSocketClientError.unsafePeer) {
      _ = try await client.ping()
    }
    #expect(await server.requests.snapshot().isEmpty)
    await server.cancel()
  }

  @Test("process start, mapped executable, and code identity unavailability fail closed")
  func processAuthorityUnavailable() throws {
    #expect(throws: HerdrTopologyError.invalidPlan) {
      _ = try HerdrProcessAuthorityInspector.inspect(processID: Int32.max)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "unsigned-peer-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let unsigned = root.appendingPathComponent("unsigned")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unsigned)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: unsigned.path
    )
    #expect(throws: HerdrTopologyError.invalidPlan) {
      _ = try HerdrExecutableCodeIdentity.inspectStatic(at: unsigned)
    }
  }

  @Test("response payload cannot supply connected-peer evidence")
  func responsePayloadCannotForgePeerEvidence() async throws {
    let forgedPong = Self.pong(id: "ping").replacingOccurrences(
      of: "\"result\":{",
      with: "\"result\":{\"peer_pid\":1,\"peer_path\":\"/tmp/forged\","
    )
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(forgedPong),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
      ]
    )
    let client = try Self.client(server: server, ids: ["ping", "snapshot"])
    let handshake = try await client.handshake()
    #expect(handshake.socketIdentity.peerEvidence?.processID == getpid())
    #expect(handshake.socketIdentity.peerEvidence?.executable.path != "/tmp/forged")
    await server.finish()
  }

  @Test("legacy agent prime uses the production codec and exact readback")
  func legacyAgentPrimeCodec() async throws {
    let tokens = [
      "managed_by": "jidoka",
      "job_id": "job-0001",
      "run_id": "run-0001",
      "launch_attempt_id": "launch-0004",
    ]
    let pane = """
      {"id":"pane","result":{"type":"pane_info","pane":{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","display_agent":"Jidoka | architecture","title":"Review architecture","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001"}}}}
      """ + "\n"
    let agent = """
      {"id":"agent","result":{"type":"agent_info","agent":{"agent":"pi","name":"jc-job-architecture-q4","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"state_change_seq":1,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","screen_detection_skipped":false,"display_agent":"Jidoka | architecture","title":"Review architecture","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001"}}}}
      """ + "\n"
    let renamed = agent.replacingOccurrences(of: "\"id\":\"agent\"", with: "\"id\":\"rename\"")
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
        HerdrFakeReply(Self.snapshot(id: "prime-snapshot")),
        HerdrFakeReply("{\"id\":\"report\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply("{\"id\":\"metadata\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply(renamed),
        HerdrFakeReply(pane),
        HerdrFakeReply(agent),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: [
        "ping", "snapshot", "prime-snapshot", "report", "metadata", "rename", "pane",
        "agent",
      ]
    )
    let handshake = try await client.handshake()
    let prime = HerdrAgentAuthorityPrime(
      workspaceID: "w-jidoka",
      tabID: "w-jidoka:t1",
      paneID: "w-jidoka:p1",
      terminalID: "term-jidoka",
      agent: HerdrPaneReportAgentParameters(
        paneID: "w-jidoka:p1",
        source: "jidoka:canary-prime:launch-0003",
        agent: "pi",
        state: .working,
        message: "primed",
        sequence: 1
      ),
      metadata: HerdrPaneReportMetadataParameters(
        paneID: "w-jidoka:p1",
        source: "jidoka:canary-prime-metadata:launch-0003",
        agent: "pi",
        appliesToSource: "jidoka:canary-prime:launch-0003",
        title: "Review architecture",
        displayAgent: "Jidoka | architecture",
        stateLabels: ["working": "running"],
        tokens: tokens,
        sequence: 1
      ),
      alias: "jc-job-architecture-q4"
    )
    let evidence = try await client.primeAgentAuthority(prime, attestedBy: handshake)
    #expect(evidence.pane.tokens == tokens)
    #expect(evidence.agent.name == "jc-job-architecture-q4")

    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method) == [
        "ping", "session.snapshot", "session.snapshot", "pane.report_agent",
        "pane.report_metadata", "agent.rename", "pane.get", "agent.get",
      ]
    )
    let report = try #require(try Self.object(requests[3])["params"] as? [String: Any])
    #expect(report["source"] as? String == "jidoka:canary-prime:launch-0003")
    #expect(report["seq"] as? Int == 1)
    let metadata = try #require(try Self.object(requests[4])["params"] as? [String: Any])
    #expect(metadata["applies_to_source"] as? String == report["source"] as? String)
    #expect(metadata["tokens"] as? [String: String] == tokens)
    let rename = try #require(try Self.object(requests[5])["params"] as? [String: Any])
    #expect(Set(rename.keys) == ["target", "name"])
    #expect(rename["target"] as? String == "w-jidoka:p1")
    #expect(rename["name"] as? String == "jc-job-architecture-q4")
    let getAgent = try #require(try Self.object(requests[7])["params"] as? [String: Any])
    #expect(getAgent["target"] as? String == "jc-job-architecture-q4")
    await server.finish()
  }

  @Test("agent authority reset clears only the exact pane before q4 readback")
  func agentAuthorityResetCodec() async throws {
    let staleTokens = ["managed_by": "jidoka", "summary": "failed"]
    let q4Tokens = [
      "managed_by": "jidoka",
      "job_id": "job-0001",
      "run_id": "run-0001",
      "launch_attempt_id": "launch-0004",
      "summary": "running",
    ]
    let resetSnapshot = Self.snapshot(id: "reset-snapshot")
      .replacingOccurrences(
        of: "\"agent\":\"pi\",\"tokens\":{\"managed_by\":\"jidoka\",\"run_id\":\"run-1\"}",
        with: "\"tokens\":{\"managed_by\":\"jidoka\",\"summary\":\"failed\"}"
      )
    let pane = """
      {"id":"pane","result":{"type":"pane_info","pane":{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","display_agent":"Jidoka | architecture","title":"Review architecture","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001","summary":"running"}}}}
      """ + "\n"
    let agent = """
      {"id":"agent","result":{"type":"agent_info","agent":{"agent":"pi","name":"jc-job-architecture-q4","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"state_change_seq":7,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","screen_detection_skipped":false,"display_agent":"Jidoka | architecture","title":"Review architecture","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001","summary":"running"}}}}
      """ + "\n"
    let renamed = agent.replacingOccurrences(of: "\"id\":\"agent\"", with: "\"id\":\"rename\"")
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
        HerdrFakeReply(resetSnapshot),
        HerdrFakeReply("{\"id\":\"clear\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply("{\"id\":\"report\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply("{\"id\":\"metadata\",\"result\":{\"type\":\"ok\"}}\n"),
        HerdrFakeReply(renamed),
        HerdrFakeReply(pane),
        HerdrFakeReply(agent),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: [
        "ping", "snapshot", "reset-snapshot", "clear", "report", "metadata", "rename",
        "pane", "agent",
      ]
    )
    let handshake = try await client.handshake()
    let prime = HerdrAgentAuthorityPrime(
      workspaceID: "w-jidoka",
      tabID: "w-jidoka:t1",
      paneID: "w-jidoka:p1",
      terminalID: "term-jidoka",
      agent: HerdrPaneReportAgentParameters(
        paneID: "w-jidoka:p1",
        source: "jidoka:host",
        agent: "pi",
        state: .working,
        message: "running",
        sequence: 7
      ),
      metadata: HerdrPaneReportMetadataParameters(
        paneID: "w-jidoka:p1",
        source: "jidoka:coordination",
        agent: "pi",
        appliesToSource: "jidoka:host",
        title: "Review architecture",
        displayAgent: "Jidoka | architecture",
        stateLabels: ["working": "running"],
        tokens: q4Tokens,
        sequence: 7
      ),
      alias: "jc-job-architecture-q4"
    )
    let evidence = try await client.resetAgentAuthority(
      HerdrAgentAuthorityReset(
        prime: prime,
        expectedPaneRevision: 7,
        expectedTokens: staleTokens
      ),
      attestedBy: handshake
    )
    #expect(evidence.pane.tokens == q4Tokens)
    #expect(evidence.agent.stateChangeSequence == 7)

    let requests = await server.requests.snapshot()
    #expect(
      try requests.map(Self.method) == [
        "ping", "session.snapshot", "session.snapshot", "pane.clear_agent_authority",
        "pane.report_agent", "pane.report_metadata", "agent.rename", "pane.get", "agent.get",
      ]
    )
    let clear = try #require(try Self.object(requests[3])["params"] as? [String: Any])
    #expect(Set(clear.keys) == ["pane_id"])
    #expect(clear["pane_id"] as? String == "w-jidoka:p1")
    let report = try #require(try Self.object(requests[4])["params"] as? [String: Any])
    #expect(report["source"] as? String == "jidoka:host")
    #expect(report["seq"] as? Int == 7)
    let metadata = try #require(try Self.object(requests[5])["params"] as? [String: Any])
    #expect(metadata["source"] as? String == "jidoka:coordination")
    #expect(metadata["applies_to_source"] as? String == "jidoka:host")
    #expect(metadata["tokens"] as? [String: String] == q4Tokens)
    await server.finish()
  }

  @Test("clear succeeds, rename fails, and no readback or q4 authority follows")
  func clearThenRenameFailureRegression() async throws {
    try await agentAuthorityResetStopsAtWireFailure(failureIndex: 4)
  }

  @Test(
    "agent authority reset stops at every failed wire boundary",
    arguments: Array(0..<7)
  )
  func agentAuthorityResetStopsAtWireFailure(failureIndex: Int) async throws {
    let staleTokens = ["managed_by": "jidoka", "summary": "failed"]
    let q4Tokens = [
      "managed_by": "jidoka", "job_id": "job-0001", "run_id": "run-0001",
      "launch_attempt_id": "launch-0004", "summary": "running",
    ]
    let resetSnapshot = Self.snapshot(id: "reset-snapshot")
      .replacingOccurrences(
        of: "\"agent\":\"pi\",\"tokens\":{\"managed_by\":\"jidoka\",\"run_id\":\"run-1\"}",
        with: "\"tokens\":{\"managed_by\":\"jidoka\",\"summary\":\"failed\"}"
      )
    let pane = """
      {"id":"pane","result":{"type":"pane_info","pane":{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001","summary":"running"}}}}
      """ + "\n"
    let agent = """
      {"id":"agent","result":{"type":"agent_info","agent":{"agent":"pi","name":"jc-job-architecture-q4","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":8,"state_change_seq":7,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","tokens":{"job_id":"job-0001","launch_attempt_id":"launch-0004","managed_by":"jidoka","run_id":"run-0001","summary":"running"}}}}
      """ + "\n"
    let resetIDs = ["reset-snapshot", "clear", "report", "metadata", "rename", "pane", "agent"]
    var resetReplies = [
      resetSnapshot,
      "{\"id\":\"clear\",\"result\":{\"type\":\"ok\"}}\n",
      "{\"id\":\"report\",\"result\":{\"type\":\"ok\"}}\n",
      "{\"id\":\"metadata\",\"result\":{\"type\":\"ok\"}}\n",
      agent.replacingOccurrences(of: "\"id\":\"agent\"", with: "\"id\":\"rename\""),
      pane,
      agent,
    ]
    resetReplies[failureIndex] =
      "{\"id\":\"\(resetIDs[failureIndex])\",\"error\":{\"code\":\"fixture_failure\",\"message\":\"fixture\"}}\n"
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
      ] + resetReplies.prefix(failureIndex + 1).map { HerdrFakeReply($0) }
    )
    let client = try Self.client(
      server: server,
      ids: ["ping", "snapshot"] + resetIDs
    )
    let handshake = try await client.handshake()
    let prime = HerdrAgentAuthorityPrime(
      workspaceID: "w-jidoka",
      tabID: "w-jidoka:t1",
      paneID: "w-jidoka:p1",
      terminalID: "term-jidoka",
      agent: HerdrPaneReportAgentParameters(
        paneID: "w-jidoka:p1", source: "jidoka:host", agent: "pi",
        state: .working, message: "running", sequence: 7
      ),
      metadata: HerdrPaneReportMetadataParameters(
        paneID: "w-jidoka:p1", source: "jidoka:coordination", agent: "pi",
        appliesToSource: "jidoka:host", title: "Architecture", displayAgent: "Pi",
        stateLabels: ["working": "running"], tokens: q4Tokens, sequence: 7
      ),
      alias: "jc-job-architecture-q4"
    )
    await #expect(throws: HerdrSocketClientError.remote("fixture_failure")) {
      _ = try await client.resetAgentAuthority(
        HerdrAgentAuthorityReset(
          prime: prime,
          expectedPaneRevision: 7,
          expectedTokens: staleTokens
        ),
        attestedBy: handshake
      )
    }
    let requests = await server.requests.snapshot()
    #expect(requests.count == failureIndex + 3)
    #expect(
      try Self.method(requests.last!)
        == [
          "session.snapshot", "pane.clear_agent_authority", "pane.report_agent",
          "pane.report_metadata", "agent.rename", "pane.get", "agent.get",
        ][failureIndex])
    await server.finish()
  }

  @Test(
    "agent authority reset rejects baseline drift before clear",
    arguments: ["revision", "tokens", "agent"]
  )
  func agentAuthorityResetRejectsBaselineDrift(drift: String) async throws {
    var resetSnapshot = Self.snapshot(id: "reset-snapshot")
      .replacingOccurrences(
        of: "\"agent\":\"pi\",\"tokens\":{\"managed_by\":\"jidoka\",\"run_id\":\"run-1\"}",
        with: "\"tokens\":{\"managed_by\":\"jidoka\",\"summary\":\"failed\"}"
      )
    switch drift {
    case "revision":
      resetSnapshot = resetSnapshot.replacingOccurrences(
        of:
          "\"pane_id\":\"w-jidoka:p1\",\"terminal_id\":\"term-jidoka\",\"workspace_id\":\"w-jidoka\",\"tab_id\":\"w-jidoka:t1\",\"revision\":7",
        with:
          "\"pane_id\":\"w-jidoka:p1\",\"terminal_id\":\"term-jidoka\",\"workspace_id\":\"w-jidoka\",\"tab_id\":\"w-jidoka:t1\",\"revision\":8"
      )
    case "tokens":
      resetSnapshot = resetSnapshot.replacingOccurrences(
        of: "\"summary\":\"failed\"",
        with: "\"summary\":\"different\""
      )
    case "agent":
      resetSnapshot = resetSnapshot.replacingOccurrences(
        of: "\"tokens\":{\"managed_by\":\"jidoka\",\"summary\":\"failed\"}",
        with: "\"agent\":\"pi\",\"tokens\":{\"managed_by\":\"jidoka\",\"summary\":\"failed\"}"
      )
    default:
      Issue.record("unknown drift")
    }
    let server = try HerdrFakeSocketServer(
      replies: [
        HerdrFakeReply(Self.pong(id: "ping")),
        HerdrFakeReply(Self.snapshot(id: "snapshot")),
        HerdrFakeReply(resetSnapshot),
      ]
    )
    let client = try Self.client(
      server: server,
      ids: [
        "ping", "snapshot", "reset-snapshot", "clear", "report", "metadata", "rename", "pane",
        "agent",
      ]
    )
    let handshake = try await client.handshake()
    let prime = HerdrAgentAuthorityPrime(
      workspaceID: "w-jidoka", tabID: "w-jidoka:t1", paneID: "w-jidoka:p1",
      terminalID: "term-jidoka",
      agent: HerdrPaneReportAgentParameters(
        paneID: "w-jidoka:p1", source: "jidoka:host", agent: "pi",
        state: .working, message: "running", sequence: 7
      ),
      metadata: HerdrPaneReportMetadataParameters(
        paneID: "w-jidoka:p1", source: "jidoka:coordination", agent: "pi",
        appliesToSource: "jidoka:host", title: "Architecture", displayAgent: "Pi",
        stateLabels: ["working": "running"], tokens: ["summary": "running"], sequence: 7
      ),
      alias: "jc-job-architecture-q4"
    )
    await #expect(throws: HerdrHostError.incompatiblePane) {
      _ = try await client.resetAgentAuthority(
        HerdrAgentAuthorityReset(
          prime: prime,
          expectedPaneRevision: 7,
          expectedTokens: ["managed_by": "jidoka", "summary": "failed"]
        ),
        attestedBy: handshake
      )
    }
    let requests = await server.requests.snapshot()
    #expect(try requests.map(Self.method) == ["ping", "session.snapshot", "session.snapshot"])
    await server.finish()
  }

  @Test("invalid request IDs fail before socket exchange")
  func invalidRequestID() async throws {
    let endpoint = URL(fileURLWithPath: "/unused/herdr.sock")
    let exchanger = CapturingHerdrSocketExchange()
    let client = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(endpoint: endpoint),
      requestID: { "contains whitespace" },
      exchanger: exchanger
    )
    await #expect(throws: HerdrSocketClientError.invalidConfiguration) {
      _ = try await client.ping()
    }
    #expect(await exchanger.endpoints().isEmpty)
  }

  private static func client(
    server: HerdrFakeSocketServer,
    ids: [String],
    timeoutSeconds: TimeInterval = 2,
    maximumRecordBytes: Int = 1_048_576,
    exchanger: any HerdrSocketExchanging = SystemHerdrSocketExchange()
  ) throws -> HerdrSocketClient {
    let sequence = HerdrRequestIDSequence(ids)
    return HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(
        endpoint: server.socketURL,
        timeoutSeconds: timeoutSeconds,
        maximumRecordBytes: maximumRecordBytes
      ),
      requestID: { sequence.next() },
      exchanger: exchanger
    )
  }

  private static func quoteShellArgument(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func makeReplacementLaunchFixture() throws -> ReplacementLaunchFixture {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(
        "replacement-fault-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let descriptorRoot = root.appendingPathComponent("descriptors", isDirectory: true)
    try FileManager.default.createDirectory(
      at: descriptorRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executable = root.appendingPathComponent("host'quoted")
    try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let canonicalRoot = try PiTUIFileProtocol.canonicalExistingURL(root)
    let canonicalExecutable = try PiTUIFileProtocol.canonicalExistingURL(executable)
    let launch = try HerdrReplacementRoleHostLaunch(
      targetPaneID: "w-user:p1",
      workspaceID: "w-user",
      workingDirectory: canonicalRoot,
      hostExecutable: canonicalExecutable,
      hostExecutableSHA256: GitHubMarkerCodec.sha256(
        try Data(contentsOf: canonicalExecutable, options: [.mappedIfSafe])
      ),
      descriptorRoot: try PiTUIFileProtocol.canonicalExistingURL(descriptorRoot),
      roleHostID: "replacement-role-host-0001"
    )
    return ReplacementLaunchFixture(root: canonicalRoot, launch: launch)
  }

  private static func replacementFaultReplies(
    fault: ReplacementLaunchFault,
    workingDirectory: String
  ) throws -> [HerdrFakeReply] {
    let splitPaneID = fault == .splitExistingPane ? "w-user:p1" : "w-user:p2"
    let splitTerminalID =
      fault == .splitExistingTerminal ? "term-user" : "term-replacement"
    let split = try replacementSplitResponse(
      id: "split",
      workingDirectory: workingDirectory,
      paneID: splitPaneID,
      terminalID: splitTerminalID
    )
    let textReply: HerdrFakeReply
    switch fault {
    case .sendTextError:
      textReply = HerdrFakeReply(Self.remoteError(id: "text"))
    case .sendTextTimeout:
      textReply = HerdrFakeReply(
        "{\"id\":\"text\",\"result\":{\"type\":\"ok\"}}\n",
        delayNanoseconds: 250_000_000
      )
    default:
      textReply = HerdrFakeReply("{\"id\":\"text\",\"result\":{\"type\":\"ok\"}}\n")
    }
    let enterReply: HerdrFakeReply
    switch fault {
    case .sendKeysError:
      enterReply = HerdrFakeReply(Self.remoteError(id: "enter"))
    case .sendKeysTimeout:
      enterReply = HerdrFakeReply(
        "{\"id\":\"enter\",\"result\":{\"type\":\"ok\"}}\n",
        delayNanoseconds: 250_000_000
      )
    default:
      enterReply = HerdrFakeReply("{\"id\":\"enter\",\"result\":{\"type\":\"ok\"}}\n")
    }
    return [
      HerdrFakeReply(Self.pong(id: "ping-0")),
      HerdrFakeReply(
        try replacementSnapshot(
          id: "snapshot-0",
          workingDirectory: workingDirectory,
          includeReplacement: false,
          mutation: .none
        )
      ),
      HerdrFakeReply(split),
      HerdrFakeReply(Self.pong(id: "ping-1")),
      HerdrFakeReply(
        try replacementSnapshot(
          id: "snapshot-1",
          workingDirectory: workingDirectory,
          includeReplacement: true,
          mutation: fault.afterSplitMutation
        )
      ),
      textReply,
      HerdrFakeReply(Self.pong(id: "ping-2")),
      HerdrFakeReply(
        try replacementSnapshot(
          id: "snapshot-2",
          workingDirectory: workingDirectory,
          includeReplacement: true,
          mutation: fault.afterTextMutation
        )
      ),
      enterReply,
      HerdrFakeReply(Self.pong(id: "ping-3")),
      HerdrFakeReply(
        try replacementSnapshot(
          id: "snapshot-3",
          workingDirectory: workingDirectory,
          includeReplacement: true,
          mutation: fault.afterEnterMutation
        )
      ),
    ]
  }

  private static func replacementSplitResponse(
    id: String,
    workingDirectory: String,
    paneID: String,
    terminalID: String
  ) throws -> String {
    try encodedRecord([
      "id": id,
      "result": [
        "type": "pane_created",
        "pane": replacementPane(
          paneID: paneID,
          terminalID: terminalID,
          workingDirectory: workingDirectory
        ),
      ],
    ])
  }

  private static func replacementSnapshot(
    id: String,
    workingDirectory: String,
    includeReplacement: Bool,
    mutation: ReplacementPaneSetMutation
  ) throws -> String {
    var userPane: [String: Any] = [
      "pane_id": "w-user:p1", "terminal_id": "term-user", "workspace_id": "w-user",
      "tab_id": "w-user:t1", "revision": 1, "focused": true,
      "agent_status": "unknown", "cwd": "/tmp/user", "foreground_cwd": "/tmp/user",
    ]
    let jidokaPane: [String: Any] = [
      "pane_id": "w-jidoka:p1", "terminal_id": "term-jidoka",
      "workspace_id": "w-jidoka", "tab_id": "w-jidoka:t1", "revision": 7,
      "focused": false, "agent_status": "working", "cwd": "/tmp/repo",
      "foreground_cwd": "/tmp/repo", "agent": "pi",
      "tokens": ["managed_by": "jidoka", "run_id": "run-1"],
    ]
    if mutation == .driftPriorMapping {
      userPane["terminal_id"] = "term-user-drift"
    }
    var panes: [[String: Any]] = [userPane]
    if mutation != .removePriorPane {
      panes.append(jidokaPane)
    }
    if includeReplacement, mutation != .removeCreatedPane {
      var created = replacementPane(
        paneID: "w-user:p2",
        terminalID: "term-replacement",
        workingDirectory: workingDirectory
      )
      switch mutation {
      case .createdWrongCWD:
        created["cwd"] = "/tmp/wrong"
      case .createdAgent:
        created["agent"] = "pi"
      case .createdSession:
        created["agent_session"] = [
          "agent": "pi", "kind": "session", "source": "fixture", "value": "foreign",
        ]
      case .remapCreatedTerminal:
        created["terminal_id"] = "term-replacement-remapped"
      default:
        break
      }
      panes.append(created)
    }
    if mutation == .addPane {
      panes.append(
        replacementPane(
          paneID: "w-user:p3",
          terminalID: "term-extra",
          workingDirectory: workingDirectory
        )
      )
    }
    let userPaneCount = panes.filter { $0["workspace_id"] as? String == "w-user" }.count
    let jidokaPaneCount = panes.filter { $0["workspace_id"] as? String == "w-jidoka" }.count
    let agents: [[String: Any]] =
      mutation == .removePriorPane
      ? []
      : [
        [
          "agent": "pi", "name": "jc-job", "pane_id": "w-jidoka:p1",
          "terminal_id": "term-jidoka", "workspace_id": "w-jidoka",
          "tab_id": "w-jidoka:t1", "revision": 7, "state_change_seq": 9,
          "focused": false, "agent_status": "working", "cwd": "/tmp/repo",
          "foreground_cwd": "/tmp/repo", "screen_detection_skipped": true,
          "tokens": ["managed_by": "jidoka", "run_id": "run-1"],
        ]
      ]
    return try encodedRecord([
      "id": id,
      "result": [
        "type": "session_snapshot",
        "snapshot": [
          "version": "0.8.2", "protocol": 20,
          "focused_workspace_id": "w-user", "focused_tab_id": "w-user:t1",
          "focused_pane_id": "w-user:p1",
          "workspaces": [
            [
              "workspace_id": "w-user", "active_tab_id": "w-user:t1",
              "label": "personal", "number": 1, "pane_count": userPaneCount,
              "tab_count": 1, "focused": true, "agent_status": "unknown",
            ],
            [
              "workspace_id": "w-jidoka", "active_tab_id": "w-jidoka:t1",
              "label": "maroffo/jidoka-code", "number": 2,
              "pane_count": jidokaPaneCount, "tab_count": 1, "focused": false,
              "agent_status": "working",
            ],
          ],
          "tabs": [
            [
              "tab_id": "w-user:t1", "workspace_id": "w-user", "label": "main",
              "number": 1, "pane_count": userPaneCount, "focused": true,
              "agent_status": "unknown",
            ],
            [
              "tab_id": "w-jidoka:t1", "workspace_id": "w-jidoka", "label": "job",
              "number": 1, "pane_count": jidokaPaneCount, "focused": false,
              "agent_status": "working",
            ],
          ],
          "panes": panes,
          "agents": agents,
        ],
      ],
    ])
  }

  private static func replacementPane(
    paneID: String,
    terminalID: String,
    workingDirectory: String
  ) -> [String: Any] {
    [
      "pane_id": paneID, "terminal_id": terminalID, "workspace_id": "w-user",
      "tab_id": "w-user:t1", "revision": 1, "focused": false,
      "agent_status": "unknown", "cwd": workingDirectory,
      "foreground_cwd": workingDirectory,
    ]
  }

  private static func remoteError(id: String) -> String {
    "{\"id\":\"\(id)\",\"error\":{\"code\":\"injected\",\"message\":\"foreign\"}}\n"
  }

  private static func encodedRecord(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private static func method(_ data: Data) throws -> String {
    try object(data)["method"] as? String ?? ""
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HerdrSocketClientError.invalidRecord
    }
    return value
  }

  private static func pong(
    id: String,
    version: String = "0.8.2",
    protocolVersion: Int = 20,
    liveHandoff: Bool = true,
    detachedServerDaemon: Bool = true
  ) -> String {
    """
    {"id":"\(id)","result":{"type":"pong","version":"\(version)","protocol":\(protocolVersion),"capabilities":{"live_handoff":\(liveHandoff),"detached_server_daemon":\(detachedServerDaemon)}}}
    """ + "\n"
  }

  private static func snapshot(id: String, protocolVersion: Int = 20) -> String {
    """
    {"id":"\(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.2","protocol":\(protocolVersion),"focused_workspace_id":"w-user","focused_tab_id":"w-user:t1","focused_pane_id":"w-user:p1","workspaces":[{"workspace_id":"w-user","active_tab_id":"w-user:t1","label":"personal","number":1,"pane_count":1,"tab_count":1,"focused":true,"agent_status":"unknown"},{"workspace_id":"w-jidoka","active_tab_id":"w-jidoka:t1","label":"maroffo/jidoka-code","number":2,"pane_count":1,"tab_count":1,"focused":false,"agent_status":"working"}],"tabs":[{"tab_id":"w-user:t1","workspace_id":"w-user","label":"main","number":1,"pane_count":1,"focused":true,"agent_status":"unknown"},{"tab_id":"w-jidoka:t1","workspace_id":"w-jidoka","label":"j/imp/i42/k7m2/g2","number":1,"pane_count":1,"focused":false,"agent_status":"working"}],"panes":[{"pane_id":"w-user:p1","terminal_id":"term-user","workspace_id":"w-user","tab_id":"w-user:t1","revision":1,"focused":true,"agent_status":"unknown","cwd":"/tmp/user","foreground_cwd":"/tmp/user"},{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","tokens":{"managed_by":"jidoka","run_id":"run-1"}}],"agents":[{"agent":"pi","name":"jc-imp-i42-k7m2-g2-impl","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"state_change_seq":9,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","screen_detection_skipped":true,"display_agent":"Jidoka | implementation","title":"Issue 42 | implementation","tokens":{"managed_by":"jidoka","run_id":"run-1"}}]}}}
    """ + "\n"
  }
}

private struct ReplacementLaunchFixture {
  let root: URL
  let launch: HerdrReplacementRoleHostLaunch
}

enum ReplacementPaneSetMutation: Equatable, Sendable {
  case none
  case addPane
  case removePriorPane
  case driftPriorMapping
  case createdWrongCWD
  case createdAgent
  case createdSession
  case removeCreatedPane
  case remapCreatedTerminal
}

enum ReplacementLaunchFault: CaseIterable, Equatable, Sendable {
  case splitExistingPane
  case splitExistingTerminal
  case postSplitExtraPane
  case postSplitWrongMapping
  case postSplitWrongCWD
  case postSplitAgent
  case postSplitSession
  case postSplitCreatedPaneRemoved
  case postSplitCreatedTerminalRemapped
  case sendTextError
  case sendTextTimeout
  case postTextPriorDrift
  case postTextPaneAdded
  case postTextPaneRemoved
  case sendKeysError
  case sendKeysTimeout
  case postEnterPriorDrift
  case postEnterPaneAdded
  case postEnterPaneRemoved
  case postEnterCreatedPaneRemoved
  case postEnterCreatedTerminalRemapped

  var isTimeout: Bool {
    self == .sendTextTimeout || self == .sendKeysTimeout
  }

  var expectedMethods: [String] {
    let handshake = ["ping", "session.snapshot"]
    let split = handshake + ["pane.split"]
    let afterSplit = split + ["ping", "session.snapshot"]
    let text = afterSplit + ["pane.send_text"]
    let afterText = text + ["ping", "session.snapshot"]
    let enter = afterText + ["pane.send_keys"]
    let afterEnter = enter + ["ping", "session.snapshot"]
    switch self {
    case .splitExistingPane, .splitExistingTerminal:
      return split
    case .postSplitExtraPane, .postSplitWrongMapping, .postSplitWrongCWD,
      .postSplitAgent, .postSplitSession, .postSplitCreatedPaneRemoved,
      .postSplitCreatedTerminalRemapped:
      return afterSplit
    case .sendTextError, .sendTextTimeout:
      return text
    case .postTextPriorDrift, .postTextPaneAdded, .postTextPaneRemoved:
      return afterText
    case .sendKeysError, .sendKeysTimeout:
      return enter
    case .postEnterPriorDrift, .postEnterPaneAdded, .postEnterPaneRemoved,
      .postEnterCreatedPaneRemoved, .postEnterCreatedTerminalRemapped:
      return afterEnter
    }
  }

  var afterSplitMutation: ReplacementPaneSetMutation {
    switch self {
    case .postSplitExtraPane: .addPane
    case .postSplitWrongMapping: .driftPriorMapping
    case .postSplitWrongCWD: .createdWrongCWD
    case .postSplitAgent: .createdAgent
    case .postSplitSession: .createdSession
    case .postSplitCreatedPaneRemoved: .removeCreatedPane
    case .postSplitCreatedTerminalRemapped: .remapCreatedTerminal
    default: .none
    }
  }

  var afterTextMutation: ReplacementPaneSetMutation {
    switch self {
    case .postTextPriorDrift: .driftPriorMapping
    case .postTextPaneAdded: .addPane
    case .postTextPaneRemoved: .removePriorPane
    default: .none
    }
  }

  var afterEnterMutation: ReplacementPaneSetMutation {
    switch self {
    case .postEnterPriorDrift: .driftPriorMapping
    case .postEnterPaneAdded: .addPane
    case .postEnterPaneRemoved: .removePriorPane
    case .postEnterCreatedPaneRemoved: .removeCreatedPane
    case .postEnterCreatedTerminalRemapped: .remapCreatedTerminal
    default: .none
    }
  }

  func matches(_ error: any Error) -> Bool {
    switch self {
    case .sendTextError, .sendKeysError:
      return error as? HerdrSocketClientError == .remote("injected")
    case .sendTextTimeout, .sendKeysTimeout:
      return error as? HerdrSocketClientError == .timedOut
    default:
      return error as? HerdrTopologyError == .invalidResponse
    }
  }
}

enum HerdrPeerEvidenceDrift: CaseIterable, Sendable {
  case processID
  case startSeconds
  case startMicroseconds
  case effectiveUserID
  case executablePath
  case executableDevice
  case executableInode
  case executableContent
  case codeIdentity
}

private func driftedPeerEvidence(
  _ evidence: HerdrConnectedPeerEvidence,
  drift: HerdrPeerEvidenceDrift
) throws -> HerdrConnectedPeerEvidence {
  var processID = evidence.processID
  var startSeconds = evidence.startSeconds
  var startMicroseconds = evidence.startMicroseconds
  var effectiveUserID = evidence.effectiveUserID
  var path = evidence.executable.path
  var device = evidence.executable.device
  var inode = evidence.executable.inode
  var contentSHA256 = evidence.executable.contentSHA256
  var codeIdentity = evidence.executable.codeIdentity
  switch drift {
  case .processID: processID += 1
  case .startSeconds: startSeconds += 1
  case .startMicroseconds: startMicroseconds = (startMicroseconds + 1) % 1_000_000
  case .effectiveUserID: effectiveUserID += 1
  case .executablePath: path = "/usr/bin/false"
  case .executableDevice: device += 1
  case .executableInode: inode += 1
  case .executableContent: contentSHA256 = String(repeating: "e", count: 64)
  case .codeIdentity:
    codeIdentity = try HerdrExecutableCodeIdentity(
      identifier: codeIdentity.identifier + ".drift",
      teamIdentifier: codeIdentity.teamIdentifier,
      codeDirectoryHashSHA256: codeIdentity.codeDirectoryHashSHA256,
      designatedRequirement: codeIdentity.designatedRequirement
    )
  }
  let executable = try HerdrProcessExecutableIdentity(
    path: path,
    device: device,
    inode: inode,
    contentSHA256: contentSHA256,
    codeIdentity: codeIdentity
  )
  return try HerdrConnectedPeerEvidence(
    processID: processID,
    startSeconds: startSeconds,
    startMicroseconds: startMicroseconds,
    effectiveUserID: effectiveUserID,
    executable: executable
  )
}

private actor DriftingHerdrPeerExchange: HerdrSocketExchanging {
  private let baseline: HerdrConnectionAuthority
  private let changed: HerdrConnectionAuthority
  private var sent = 0
  private var expectedChecks = 0

  init(
    baseline: HerdrConnectedPeerEvidence,
    changed: HerdrConnectedPeerEvidence
  ) {
    let socket = HerdrSocketIdentity(
      device: 1,
      inode: 1,
      owner: geteuid(),
      permissions: 0o600
    )
    self.baseline = HerdrConnectionAuthority(socketIdentity: socket, peer: baseline)
    self.changed = HerdrConnectionAuthority(socketIdentity: socket, peer: changed)
  }

  func exchange(
    configuration _: HerdrSocketClientConfiguration,
    request _: Data
  ) async throws -> HerdrSocketExchange {
    sent += 1
    return HerdrSocketExchange(
      record: Data(
        """
        {"id":"ping","result":{"type":"pong","version":"0.8.2","protocol":20,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}
        """.utf8
      ),
      authority: baseline
    )
  }

  func exchange(
    configuration _: HerdrSocketClientConfiguration,
    request _: Data,
    expectedAuthority: HerdrConnectionAuthority
  ) async throws -> HerdrSocketExchange {
    expectedChecks += 1
    guard changed == expectedAuthority else {
      throw HerdrSocketClientError.socketChanged
    }
    sent += 1
    throw HerdrSocketClientError.invalidRecord
  }

  func sentRequestCount() -> Int { sent }
  func expectedAuthorityCheckCount() -> Int { expectedChecks }
}

private actor RotatingHerdrSocketExchange: HerdrSocketExchanging {
  private let original = HerdrSocketIdentity(
    device: 1,
    inode: 1,
    owner: geteuid(),
    permissions: 0o600
  )
  private let replacement = HerdrSocketIdentity(
    device: 1,
    inode: 2,
    owner: geteuid(),
    permissions: 0o600
  )
  private var sent = 0
  private var expectedChecks = 0

  func exchange(
    configuration _: HerdrSocketClientConfiguration,
    request _: Data
  ) async throws -> HerdrSocketExchange {
    sent += 1
    return HerdrSocketExchange(
      record: Data(
        """
        {"id":"ping","result":{"type":"pong","version":"0.8.2","protocol":20,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}
        """.utf8
      ),
      authority: try HerdrConnectionAuthority(
        socketIdentity: original,
        peer: currentPeerEvidence()
      )
    )
  }

  func exchange(
    configuration _: HerdrSocketClientConfiguration,
    request _: Data,
    expectedAuthority: HerdrConnectionAuthority
  ) async throws -> HerdrSocketExchange {
    expectedChecks += 1
    guard expectedAuthority.socketIdentity == replacement else {
      throw HerdrSocketClientError.socketChanged
    }
    sent += 1
    throw HerdrSocketClientError.invalidRecord
  }

  func sentRequestCount() -> Int {
    sent
  }

  func expectedIdentityCheckCount() -> Int {
    expectedChecks
  }
}

private func currentPeerEvidence() throws -> HerdrConnectedPeerEvidence {
  let authority = try HerdrProcessAuthorityInspector.inspect(processID: getpid())
  return try HerdrConnectedPeerEvidence(
    processID: authority.process.processID,
    startSeconds: authority.process.startSeconds,
    startMicroseconds: authority.process.startMicroseconds,
    effectiveUserID: geteuid(),
    executable: authority.executable
  )
}

private actor CapturingHerdrSocketExchange: HerdrSocketExchanging {
  private var observedEndpoints: [URL] = []

  func exchange(
    configuration: HerdrSocketClientConfiguration,
    request: Data
  ) async throws -> HerdrSocketExchange {
    observedEndpoints.append(configuration.endpoint)
    throw HerdrSocketClientError.unsafeSocket
  }

  func endpoints() -> [URL] {
    observedEndpoints
  }
}

private final class HerdrConnectionAttemptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var endpoints: [URL] = []

  func record(_ endpoint: URL) {
    lock.lock()
    defer { lock.unlock() }
    endpoints.append(endpoint)
  }

  func snapshot() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return endpoints
  }
}
