import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Herdr protocol and explicit socket boundary")
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
    #expect(handshake.pong.version == "0.8.0")
    #expect(handshake.pong.protocolVersion == 19)
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
        Self.pong(id: "req", protocolVersion: 20),
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
        HerdrFakeReply(Self.snapshot(id: "req-2", protocolVersion: 20)),
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
    let version = try #require(invalidUTF8.range(of: Data("0.8.0".utf8)))
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
    // Sanitizer instrumentation can delay the task's post-timeout resumption while
    // the typed timeout still wins. Keep a finite hang detector without applying
    // the instrumentation allowance to the normal production-shaped test.
    let processSymbols = UnsafeMutableRawPointer(bitPattern: -2)  // Darwin RTLD_DEFAULT.
    let sanitizerActive =
      dlsym(processSymbols, "__asan_init") != nil
      || dlsym(processSymbols, "__tsan_init") != nil
    #expect(elapsed < (sanitizerActive ? 15.0 : 5.0))
    await server.finish()
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
    version: String = "0.8.0",
    protocolVersion: Int = 19,
    liveHandoff: Bool = true,
    detachedServerDaemon: Bool = true
  ) -> String {
    """
    {"id":"\(id)","result":{"type":"pong","version":"\(version)","protocol":\(protocolVersion),"capabilities":{"live_handoff":\(liveHandoff),"detached_server_daemon":\(detachedServerDaemon)}}}
    """ + "\n"
  }

  private static func snapshot(id: String, protocolVersion: Int = 19) -> String {
    """
    {"id":"\(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":\(protocolVersion),"focused_workspace_id":"w-user","focused_tab_id":"w-user:t1","focused_pane_id":"w-user:p1","workspaces":[{"workspace_id":"w-user","active_tab_id":"w-user:t1","label":"personal","number":1,"pane_count":1,"tab_count":1,"focused":true,"agent_status":"unknown"},{"workspace_id":"w-jidoka","active_tab_id":"w-jidoka:t1","label":"maroffo/jidoka-code","number":2,"pane_count":1,"tab_count":1,"focused":false,"agent_status":"working"}],"tabs":[{"tab_id":"w-user:t1","workspace_id":"w-user","label":"main","number":1,"pane_count":1,"focused":true,"agent_status":"unknown"},{"tab_id":"w-jidoka:t1","workspace_id":"w-jidoka","label":"j/imp/i42/k7m2/g2","number":1,"pane_count":1,"focused":false,"agent_status":"working"}],"panes":[{"pane_id":"w-user:p1","terminal_id":"term-user","workspace_id":"w-user","tab_id":"w-user:t1","revision":1,"focused":true,"agent_status":"unknown","cwd":"/tmp/user","foreground_cwd":"/tmp/user"},{"pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","agent":"pi","tokens":{"managed_by":"jidoka","run_id":"run-1"}}],"agents":[{"agent":"pi","name":"jc-imp-i42-k7m2-g2-impl","pane_id":"w-jidoka:p1","terminal_id":"term-jidoka","workspace_id":"w-jidoka","tab_id":"w-jidoka:t1","revision":7,"state_change_seq":9,"focused":false,"agent_status":"working","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","screen_detection_skipped":true,"display_agent":"Jidoka | implementation","title":"Issue 42 | implementation","tokens":{"managed_by":"jidoka","run_id":"run-1"}}]}}}
    """ + "\n"
  }
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
        {"id":"ping","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}
        """.utf8
      ),
      socketIdentity: original
    )
  }

  func exchange(
    configuration _: HerdrSocketClientConfiguration,
    request _: Data,
    expectedSocketIdentity: HerdrSocketIdentity
  ) async throws -> HerdrSocketExchange {
    expectedChecks += 1
    guard expectedSocketIdentity == replacement else {
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
