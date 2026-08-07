import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Bounded credentialless process execution")
struct GitProcessTests {
  @Test("credentialless environment has exact locked boundaries")
  func credentiallessEnvironment() throws {
    let environment = try CredentiallessEnvironment.make(
      homeDirectory: "/tmp/jidoka-home",
      temporaryDirectory: "/tmp"
    )
    #expect(environment["GIT_CONFIG_NOSYSTEM"] == "1")
    #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["GIT_ASKPASS"] == "/usr/bin/false")
    #expect(environment["GIT_SSH_COMMAND"] == "/usr/bin/false")
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "SSH_AUTH_SOCK"] {
      #expect(environment[key] == nil)
    }
    #expect(throws: GitProcessError.invalidEnvironment) {
      _ = try CredentiallessEnvironment.make(developerDirectory: "/tmp/Xcode")
    }
    for override in [
      ["GIT_ASKPASS": "/tmp/bypass"],
      ["HTTPS_PROXY": "http://127.0.0.1:8080"],
      ["GIT_ALLOW_PROTOCOL": "https:file"],
      ["GIT_TRACE_PACKET": "2"],
    ] {
      #expect(throws: GitProcessError.invalidEnvironment) {
        _ = try CredentiallessEnvironment.make(overrides: override)
      }
    }
    #expect(
      try CredentiallessEnvironment.make(overrides: ["GIT_ALLOW_PROTOCOL": "file"])[
        "GIT_ALLOW_PROTOCOL"
      ] == "file"
    )
    let guarded = try CredentiallessEnvironment.make(overrides: [
      "JIDOKA_PUSH_GUARD_REFERENCE": "refs/heads/agent/issue-1-guard",
      "JIDOKA_PUSH_GUARD_REMOTE": "https://x-access-token@github.com/owner/repo.git",
      "JIDOKA_PUSH_GUARD_SHA": String(repeating: "a", count: 40),
    ])
    #expect(guarded["JIDOKA_PUSH_GUARD_SHA"] == String(repeating: "a", count: 40))
    for override in [
      ["JIDOKA_PUSH_GUARD_REFERENCE": "refs/heads/../main"],
      ["JIDOKA_PUSH_GUARD_REMOTE": "https://evil.example/owner/repo.git"],
      ["JIDOKA_PUSH_GUARD_REMOTE": "https://github.com/owner/repo.git"],
      ["JIDOKA_PUSH_GUARD_SHA": "not-a-sha"],
    ] {
      #expect(throws: GitProcessError.invalidEnvironment) {
        _ = try CredentiallessEnvironment.make(overrides: override)
      }
    }
  }

  @Test("argv stays discrete and output is captured without a shell")
  func discreteArguments() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-process")
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("arguments.sh")
    try writeExecutable(
      script,
      "#!/bin/sh\nprintf '<%s>\\n' \"$1\" \"$2\"\n"
    )
    let marker = fixture.root.appendingPathComponent("must-not-exist")
    let metacharacter = "; touch \(marker.path)"
    let result = try await BoundedProcessRunner().run(
      GitProcessRequest(
        executable: script,
        arguments: [metacharacter, "$(uname)"],
        workingDirectory: fixture.root,
        environment: try CredentiallessEnvironment.make(
          homeDirectory: fixture.root.path,
          temporaryDirectory: fixture.root.path
        ),
        timeoutSeconds: 5
      ))
    #expect(result.succeeded)
    #expect(
      String(decoding: result.stdout, as: UTF8.self)
        == "<\(metacharacter)>\n<$(uname)>\n"
    )
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("timeout and output bounds terminate the whole process group")
  func processTreeBounds() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-process-tree")
    defer { fixture.remove() }
    let pidFile = fixture.root.appendingPathComponent("child.pid")
    let timeoutScript = fixture.root.appendingPathComponent("timeout.sh")
    try writeExecutable(
      timeoutScript,
      """
      #!/bin/sh
      /bin/sleep 30 &
      printf '%s\n' "$!" >'\(pidFile.path)'
      wait
      """
    )
    let timeout = try await BoundedProcessRunner().run(
      GitProcessRequest(
        executable: timeoutScript,
        arguments: [],
        workingDirectory: fixture.root,
        environment: try CredentiallessEnvironment.make(
          homeDirectory: fixture.root.path,
          temporaryDirectory: fixture.root.path
        ),
        timeoutSeconds: 1
      ))
    #expect(timeout.timedOut)
    #expect(!timeout.succeeded)
    let childPID = try Int32(
      String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    #expect(childPID != nil)
    if let childPID {
      let deadline = Date().addingTimeInterval(1)
      while Darwin.kill(childPID, 0) == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(Darwin.kill(childPID, 0) == -1)
      #expect(errno == ESRCH)
    }

    let escapedPIDFile = fixture.root.appendingPathComponent("escaped.pid")
    let escapedScript = fixture.root.appendingPathComponent("escaped.sh")
    try writeExecutable(
      escapedScript,
      """
      #!/bin/sh
      /usr/bin/python3 -c 'import os,time; os.setsid(); open("\(escapedPIDFile.path)", "w").write(str(os.getpid())); time.sleep(30)' &
      attempt=0
      while [ ! -f '\(escapedPIDFile.path)' ] && [ "$attempt" -lt 50 ]
      do
        /bin/sleep 0.02
        attempt=$((attempt + 1))
      done
      test -f '\(escapedPIDFile.path)'
      /bin/sleep 0.1
      exit 0
      """
    )
    let escaped = try await BoundedProcessRunner().run(
      GitProcessRequest(
        executable: escapedScript,
        arguments: [],
        workingDirectory: fixture.root,
        environment: try CredentiallessEnvironment.make(
          homeDirectory: fixture.root.path,
          temporaryDirectory: fixture.root.path
        ),
        timeoutSeconds: 3
      ))
    #expect(escaped.timedOut)
    let escapedPID = try #require(
      Int32(
        String(contentsOf: escapedPIDFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    let escapedDeadline = Date().addingTimeInterval(1)
    while Darwin.kill(escapedPID, 0) == 0, Date() < escapedDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(Darwin.kill(escapedPID, 0) == -1)
    #expect(errno == ESRCH)

    let outputScript = fixture.root.appendingPathComponent("output.sh")
    try writeExecutable(outputScript, "#!/bin/sh\nexec /usr/bin/yes bounded\n")
    let bounded = try await BoundedProcessRunner().run(
      GitProcessRequest(
        executable: outputScript,
        arguments: [],
        workingDirectory: fixture.root,
        environment: try CredentiallessEnvironment.make(
          homeDirectory: fixture.root.path,
          temporaryDirectory: fixture.root.path
        ),
        timeoutSeconds: 5,
        maximumOutputBytes: 1_024
      ))
    #expect(bounded.outputLimitExceeded)
    #expect(bounded.stdout.count == 1_024)
    #expect(!bounded.succeeded)
  }

  @Test("symlink executables and working directories fail closed")
  func symlinks() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-process-symlink")
    defer { fixture.remove() }
    let executable = fixture.root.appendingPathComponent("real.sh")
    let executableLink = fixture.root.appendingPathComponent("link.sh")
    try writeExecutable(executable, "#!/bin/sh\nexit 0\n")
    try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: executable)
    await #expect(throws: GitProcessError.invalidExecutable) {
      _ = try await BoundedProcessRunner().run(
        GitProcessRequest(
          executable: executableLink,
          arguments: [],
          workingDirectory: fixture.root,
          environment: try CredentiallessEnvironment.make(),
          timeoutSeconds: 5
        ))
    }
  }
}
