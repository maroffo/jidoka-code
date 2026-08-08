import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Bounded full-duplex Pi RPC process runner")
struct PiRPCProcessTests {
  @Test("correlated fake provider transcript settles and every descendant is removed")
  func successfulConversationAndCleanup() async throws {
    let fixture = try PiRPCProcessFixture(mode: "success")
    defer { fixture.remove() }

    let result = try await PiRPCProcessRunner().run(fixture.request(timeout: 3))

    #expect(result.sessionID == "fake-session-1")
    #expect(result.terminalResult.payload["verdict"]?.stringValue == "pass")
    #expect(
      result.stderrSHA256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(result.cleanupVerified)
    #expect(!result.abortAcknowledged)
    let descendant = try fixture.recordedDescendantPID()
    #expect(await processDisappeared(descendant))
  }

  @Test("a child forked after settlement cannot escape its dedicated process group")
  func lateProcessGroupChildCleanup() async throws {
    let fixture = try PiRPCProcessFixture(mode: "late-process-group-child")
    defer { fixture.remove() }

    let result = try await PiRPCProcessRunner().run(fixture.request(timeout: 3))

    #expect(result.cleanupVerified)
    let descendant = try fixture.recordedDescendantPID()
    #expect(await processDisappeared(descendant))
  }

  @Test("a child that never reads stdin cannot escape the monotonic timeout")
  func blockedInputCleanup() async throws {
    let fixture = try PiRPCProcessFixture(mode: "no-read-prompt")
    defer { fixture.remove() }

    await #expect(throws: PiRPCProcessError.self) {
      _ = try await PiRPCProcessRunner().run(
        fixture.request(
          timeout: 3,
          prompt: String(repeating: "x", count: 2 * 1_024 * 1_024)
        )
      )
    }
    let processID = try fixture.recordedDescendantPID()
    #expect(await processDisappeared(processID))
  }

  @Test("a child that closes stdin cannot terminate the engine with SIGPIPE")
  func closedInputDoesNotSignalParent() async throws {
    let fixture = try PiRPCProcessFixture(mode: "close-stdin")
    defer { fixture.remove() }

    do {
      _ = try await PiRPCProcessRunner().run(
        fixture.request(
          timeout: 3,
          prompt: String(repeating: "x", count: 2 * 1_024 * 1_024)
        )
      )
      Issue.record("closed stdin unexpectedly accepted a prompt")
    } catch let error as PiRPCProcessError {
      #expect(error == .writeFailed(EPIPE))
    }
    let processID = try fixture.recordedDescendantPID()
    #expect(await processDisappeared(processID))
  }

  @Test("a settled child must still exit successfully when it exits on its own")
  func settledNonzeroExitFails() async throws {
    for (mode, expected) in [
      ("settle-exit-7", PiRPCProcessError.unexpectedExit(7)),
      ("settle-abort", PiRPCProcessError.unexpectedExit(nil)),
      ("settle-term-exit-7", PiRPCProcessError.unexpectedExit(7)),
    ] {
      let fixture = try PiRPCProcessFixture(mode: mode)
      defer { fixture.remove() }
      do {
        _ = try await PiRPCProcessRunner().run(fixture.request(timeout: 2))
        Issue.record("\(mode) unexpectedly became successful evidence")
      } catch let error as PiRPCProcessError {
        #expect(error == expected)
      }
    }
  }

  @Test("timeout sends one abort, requires acknowledgement, and still cleans descendants")
  func timeoutAbortAndCleanup() async throws {
    let fixture = try PiRPCProcessFixture(mode: "timeout")
    defer { fixture.remove() }

    do {
      _ = try await PiRPCProcessRunner().run(fixture.request(timeout: 3))
      Issue.record("timeout fixture unexpectedly settled")
    } catch let error as PiRPCProcessError {
      #expect(error == .timeout(abortAcknowledged: true))
    }
    let descendant = try fixture.recordedDescendantPID()
    #expect(await processDisappeared(descendant))
  }

  @Test("stderr and non-JSONL output cannot become successful evidence")
  func malformedOutputAndStderr() async throws {
    for mode in ["stderr", "malformed", "late-event"] {
      let fixture = try PiRPCProcessFixture(mode: mode)
      defer { fixture.remove() }
      await #expect(throws: (any Error).self) {
        try await PiRPCProcessRunner().run(fixture.request(timeout: 2))
      }
    }
  }

  @Test("invocation builder excludes generic discovery and secret-shaped environment keys")
  func closedInvocationBuilder() throws {
    let fixture = try InvocationBuilderFixture()
    defer { fixture.remove() }
    let arguments = try PiRPCInvocationBuilder.arguments(
      runtime: fixture.runtime,
      model: "openai-codex/gpt-5.6-sol:max",
      sessionDirectory: fixture.sessionURL,
      sessionName: "jidoka-code-job-1-writer",
      blockerExtension: fixture.blockerURL,
      runtimeExtension: fixture.extensionURL,
      skill: fixture.skillURL
    )
    let environment = try PiRPCInvocationBuilder.environment(
      homeDirectory: fixture.homeURL,
      agentDirectory: fixture.agentURL,
      temporaryDirectory: fixture.temporaryURL,
      workflowConfiguration: fixture.configurationURL,
      offline: true
    )

    #expect(arguments.first == fixture.runtime.piCLIURL.path)
    #expect(arguments.contains("--no-extensions"))
    #expect(arguments.contains("--no-skills"))
    #expect(arguments.contains("--no-context-files"))
    #expect(arguments.contains("--tools"))
    #expect(arguments.contains(PiWorkflowResourceCatalog.readOnlyToolNames.joined(separator: ",")))
    #expect(!arguments.joined(separator: " ").contains("bash"))
    #expect(!arguments.contains("--approve"))
    #expect(environment["PI_OFFLINE"] == "1")
    #expect(environment["GIT_CONFIG_NOSYSTEM"] == "1")
    #expect(environment["GIT_ASKPASS"] == "/usr/bin/false")
    #expect(
      environment.keys.allSatisfy { key in
        !["GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "SSH_AUTH_SOCK"].contains(key)
      })

    let resumed = try PiRPCInvocationBuilder.arguments(
      runtime: fixture.runtime,
      model: "openai-codex/gpt-5.6-sol:max",
      sessionDirectory: fixture.sessionURL,
      sessionName: "jidoka-code-job-1-writer",
      blockerExtension: fixture.blockerURL,
      runtimeExtension: fixture.extensionURL,
      skill: fixture.skillURL,
      session: .resume("12345678-1234-1234-1234-123456789abc")
    )
    let sessionIndex = try #require(resumed.firstIndex(of: "--session"))
    #expect(
      resumed[resumed.index(after: sessionIndex)]
        == "12345678-1234-1234-1234-123456789abc"
    )
  }

  private func processDisappeared(_ pid: pid_t) async -> Bool {
    for _ in 0..<100 {
      if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return Darwin.kill(pid, 0) == -1 && errno == ESRCH
  }
}

private final class PiRPCProcessFixture {
  let rootURL: URL
  private let scriptURL: URL
  private let childPIDURL: URL
  private let mode: String

  init(mode: String) throws {
    self.mode = mode
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-rpc-process-\(UUID().uuidString)",
      isDirectory: true
    )
    scriptURL = rootURL.appendingPathComponent("fake-pi.mjs")
    childPIDURL = rootURL.appendingPathComponent("child.pid")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootURL.path
    )
    try Data(Self.script.utf8).write(to: scriptURL)
  }

  func request(
    timeout: TimeInterval,
    prompt: String = "deterministic fake-provider prompt"
  ) -> PiRPCProcessRequest {
    let command = PiRPCCommandProvenance(
      name: "skill:jidoka-code-plan",
      source: "skill",
      path: "/bundle/skills/jidoka-code-plan/SKILL.md",
      scope: "temporary",
      origin: "top-level"
    )
    return PiRPCProcessRequest(
      executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/node/26.6.0/bin/node"),
      arguments: [scriptURL.path],
      workingDirectory: rootURL,
      environment: [
        "FAKE_CHILD_PID_FILE": childPIDURL.path,
        "FAKE_MODE": mode,
        "PATH": "/usr/bin:/bin",
      ],
      prompt: prompt,
      sessionExpectation: PiRPCSessionExpectation(
        provider: "fake-provider",
        modelID: "fake-model",
        thinkingLevel: "off",
        commands: [command]
      ),
      terminalIdentity: PiRPCTerminalResultIdentity(
        workflow: "planning",
        role: "writer",
        nonce: "nonce-12345678",
        artifactSHA256: String(repeating: "a", count: 64),
        allowedCommandIDs: ["check"]
      ),
      allowedToolNames: PiWorkflowResourceCatalog.writerToolNames,
      timeoutSeconds: timeout,
      abortGraceSeconds: 1,
      environmentPolicy: .deterministicFixture
    )
  }

  func recordedDescendantPID() throws -> pid_t {
    let value = try String(contentsOf: childPIDURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(pid_t(value))
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private static let script = #"""
    import { spawn } from "node:child_process";
    import { closeSync, writeFileSync, writeSync } from "node:fs";

    let input = Buffer.alloc(0);
    let child;
    if (process.env.FAKE_MODE === "settle-term-exit-7") {
      process.on("SIGTERM", () => process.exit(7));
    }
    function emit(value) {
      writeSync(1, `${JSON.stringify(value)}\n`);
    }
    function response(message, data = undefined) {
      const value = {
        command: message.type,
        id: message.id,
        success: true,
        type: "response",
      };
      if (data !== undefined) value.data = data;
      emit(value);
    }
    function spawnChild() {
      if (child !== undefined) return;
      child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
        stdio: "ignore",
      });
      writeFileSync(process.env.FAKE_CHILD_PID_FILE, `${child.pid}\n`, { mode: 0o600 });
    }
    if (["no-read-prompt", "close-stdin"].includes(process.env.FAKE_MODE)) {
      writeFileSync(process.env.FAKE_CHILD_PID_FILE, `${process.pid}\n`, { mode: 0o600 });
    }
    if (process.env.FAKE_MODE === "timeout") spawnChild();
    function handle(message) {
      if (message.type === "set_auto_retry" || message.type === "set_auto_compaction") {
        response(message);
        return;
      }
      if (message.type === "get_state") {
        response(message, {
          autoCompactionEnabled: false,
          isStreaming: false,
          model: { id: "fake-model", provider: "fake-provider" },
          sessionId: "fake-session-1",
          thinkingLevel: "off",
        });
        return;
      }
      if (message.type === "get_commands") {
        response(message, {
          commands: [{
            name: "skill:jidoka-code-plan",
            source: "skill",
            sourceInfo: {
              origin: "top-level",
              path: "/bundle/skills/jidoka-code-plan/SKILL.md",
              scope: "temporary",
            },
          }],
        });
        if (process.env.FAKE_MODE === "no-read-prompt") process.stdin.pause();
        if (process.env.FAKE_MODE === "close-stdin") closeSync(0);
        return;
      }
      if (message.type === "prompt") {
        response(message);
        if (process.env.FAKE_MODE !== "late-process-group-child") spawnChild();
        if (process.env.FAKE_MODE === "timeout") return;
        if (process.env.FAKE_MODE === "stderr") {
          process.stderr.write("unexpected diagnostic\n");
        }
        if (process.env.FAKE_MODE === "malformed") {
          process.stdout.write("not-json\n");
          return;
        }
        emit({ type: "agent_start" });
        emit({ type: "turn_start" });
        emit({ message: { role: "user" }, type: "message_start" });
        emit({ message: { role: "user" }, type: "message_end" });
        emit({ message: { role: "assistant" }, type: "message_start" });
        emit({
          assistantMessageEvent: { contentIndex: 0, delta: "done", type: "text_delta" },
          type: "message_update",
        });
        emit({ message: { role: "assistant" }, type: "message_end" });
        emit({
          args: {},
          toolCallId: "result-1",
          toolName: "jidoka_code_result",
          type: "tool_execution_start",
        });
        emit({
          isError: false,
          result: {
            details: {
              approvedCommandIDs: ["check"],
              artifactSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              nonce: "nonce-12345678",
              payload: { verdict: "pass" },
              resultSequence: 1,
              role: "writer",
              schemaVersion: 1,
              workflow: "planning",
            },
          },
          toolCallId: "result-1",
          toolName: "jidoka_code_result",
          type: "tool_execution_end",
        });
        const toolResult = {
          content: [],
          details: {},
          isError: false,
          role: "toolResult",
          timestamp: 1,
          toolCallId: "result-1",
          toolName: "jidoka_code_result",
        };
        emit({ message: toolResult, type: "message_start" });
        emit({ message: toolResult, type: "message_end" });
        emit({ message: {}, toolResults: [toolResult], type: "turn_end" });
        emit({ messages: [], type: "agent_end", willRetry: false });
        emit({ type: "agent_settled" });
        if (process.env.FAKE_MODE === "late-process-group-child") {
          spawnChild();
          process.exit(0);
        }
        if (process.env.FAKE_MODE === "late-event") {
          setTimeout(() => emit({ type: "agent_start" }), 50);
        }
        if (process.env.FAKE_MODE === "settle-exit-7") {
          setTimeout(() => process.exit(7), 10);
        }
        if (process.env.FAKE_MODE === "settle-abort") {
          setTimeout(() => process.kill(process.pid, "SIGABRT"), 10);
        }
        return;
      }
      if (message.type === "abort") {
        response(message);
      }
    }
    process.stdin.on("data", (chunk) => {
      input = Buffer.concat([input, chunk]);
      while (true) {
        const newline = input.indexOf(0x0a);
        if (newline < 0) break;
        const line = input.subarray(0, newline);
        input = input.subarray(newline + 1);
        handle(JSON.parse(line.toString("utf8")));
      }
    });
    setInterval(() => {}, 1000);
    """#
}

private final class InvocationBuilderFixture {
  let rootURL: URL
  let sessionURL: URL
  let homeURL: URL
  let agentURL: URL
  let temporaryURL: URL
  let blockerURL: URL
  let extensionURL: URL
  let skillURL: URL
  let configurationURL: URL
  let runtime: PiResolvedRuntime

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-rpc-builder-\(UUID().uuidString)",
      isDirectory: true
    )
    sessionURL = rootURL.appendingPathComponent("session", isDirectory: true)
    homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
    agentURL = rootURL.appendingPathComponent("agent", isDirectory: true)
    temporaryURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
    blockerURL = rootURL.appendingPathComponent("blocker.js")
    extensionURL = rootURL.appendingPathComponent("runtime.ts")
    skillURL = rootURL.appendingPathComponent("SKILL.md")
    configurationURL = rootURL.appendingPathComponent("config.json")
    for directory in [rootURL, sessionURL, homeURL, agentURL, temporaryURL] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
    for file in [blockerURL, extensionURL, skillURL, configurationURL] {
      try Data("fixture".utf8).write(to: file)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: configurationURL.path
    )
    runtime = PiResolvedRuntime(
      nodeURL: URL(fileURLWithPath: "/node"),
      nodeVersion: try PiSemanticVersion("26.6.0"),
      nodeSHA256: String(repeating: "a", count: 64),
      piCLIURL: blockerURL,
      piPackageRootURL: rootURL,
      piVersion: try PiSemanticVersion("0.84.0"),
      piRuntimeSHA256: [:],
      compatibility: PiRuntimeCompatibility(
        minimumVersion: try PiSemanticVersion("0.84.0"),
        maximumVersionExclusive: try PiSemanticVersion("0.90.0"),
        policySHA256: String(repeating: "b", count: 64)
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
