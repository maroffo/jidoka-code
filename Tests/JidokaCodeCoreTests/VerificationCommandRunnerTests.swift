import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Frozen argv-only verification command runner")
struct VerificationCommandRunnerTests {
  @Test("repository script keeps metacharacters as data and locks source digest")
  func repositoryScript() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-script")
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("verify.sh")
    try writeExecutable(
      script,
      "#!/bin/sh\nprintf '<%s>\\n' \"$1\" \"$2\"\n"
    )
    let marker = fixture.root.appendingPathComponent("must-not-exist")
    let arguments = ["; touch \(marker.path)", "$(uname)"]
    let command = makeApprovedCommand(
      id: "verify-script",
      kind: .repositoryScript,
      executable: "verify.sh",
      arguments: arguments,
      sourceDigest: sha256(try Data(contentsOf: script))
    )
    let plan = try makeFrozenPlan([command])
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let evidence = try await runner.execute(
      commandID: command.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: fixture.root
    )
    #expect(evidence.succeeded)
    #expect(
      evidence.stdoutExcerpt
        == "<\(arguments[0])>\n<\(arguments[1])>\n"
    )
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    try writeExecutable(script, "#!/bin/sh\nprintf 'changed\\n'\n")
    await #expect(throws: VerificationCommandError.sourceDigestMismatch) {
      _ = try await runner.execute(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: fixture.root
      )
    }
  }

  @Test("unknown ids, changed definitions, forbidden shapes, and cwd escape fail closed")
  func closedRegistry() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-closed")
    defer { fixture.remove() }
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let valid = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let plan = try makeFrozenPlan([valid])
    await #expect(throws: VerificationCommandError.commandNotFound) {
      _ = try await runner.execute(
        commandID: "arbitrary",
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: fixture.root
      )
    }
    await #expect(throws: VerificationCommandError.planDigestMismatch) {
      _ = try await runner.execute(
        commandID: valid.id,
        expectedPlanDigest: String(repeating: "a", count: 64),
        plan: plan,
        workspace: fixture.root
      )
    }

    let badDigest = makeApprovedCommand(
      id: "bad-digest",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"],
      overrideDigest: String(repeating: "b", count: 64)
    )
    let badPlan = try makeFrozenPlan([badDigest])
    await #expect(throws: VerificationCommandError.definitionDigestMismatch) {
      _ = try await runner.execute(
        commandID: badDigest.id,
        expectedPlanDigest: badPlan.digest,
        plan: badPlan,
        workspace: fixture.root
      )
    }

    for command in [
      makeApprovedCommand(
        id: "make-escape",
        kind: .makeTargets,
        executable: "make",
        arguments: ["-f", "evil.mk"]
      ),
      makeApprovedCommand(
        id: "git-push",
        kind: .gitRead,
        executable: "git",
        arguments: ["push"]
      ),
      makeApprovedCommand(
        id: "git-long-option",
        kind: .gitRead,
        executable: "git",
        arguments: ["diff", "--output=/tmp/escaped"]
      ),
      makeApprovedCommand(
        id: "git-config-env",
        kind: .gitRead,
        executable: "git",
        arguments: ["status", "--config-env=credential.helper=HELPER"]
      ),
      makeApprovedCommand(
        id: "xcode-path-escape",
        kind: .xcodebuildBuildTest,
        executable: "xcodebuild",
        arguments: ["build", "-derivedDataPath", "/tmp/out"]
      ),
      makeApprovedCommand(
        id: "shell",
        kind: .repositoryScript,
        executable: "/bin/sh",
        arguments: ["-c", "command"],
        sourceDigest: String(repeating: "c", count: 64)
      ),
    ] {
      let invalidPlan = try makeFrozenPlan([command])
      await #expect(throws: VerificationCommandError.self) {
        _ = try await runner.execute(
          commandID: command.id,
          expectedPlanDigest: invalidPlan.digest,
          plan: invalidPlan,
          workspace: fixture.root
        )
      }
    }

    let outside = fixture.root.deletingLastPathComponent()
    let link = fixture.root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let cwd = makeApprovedCommand(
      id: "cwd",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"],
      workingDirectory: "linked"
    )
    let cwdPlan = try makeFrozenPlan([cwd])
    await #expect(throws: VerificationCommandError.invalidWorkingDirectory) {
      _ = try await runner.execute(
        commandID: cwd.id,
        expectedPlanDigest: cwdPlan.digest,
        plan: cwdPlan,
        workspace: fixture.root
      )
    }
  }

  @Test("Git reads accept only exact operation-specific options")
  func gitReadOptions() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-git-read")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let command = makeApprovedCommand(
      id: "status",
      kind: .gitRead,
      executable: "git",
      arguments: ["status", "--porcelain=v1"]
    )
    let plan = try makeFrozenPlan([command])
    let evidence = try await VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    ).execute(
      commandID: command.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: repository
    )
    #expect(evidence.succeeded)
  }

  @Test("normal Git commit runs approved hooks and unsafe local config blocks execution")
  func hooksAndGitConfiguration() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-git")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let tracked = repository.appendingPathComponent("file.txt")
    try "content\n".write(to: tracked, atomically: true, encoding: .utf8)
    try await fixture.run(["-C", repository.path, "add", "--", "file.txt"])
    let hooks = repository.appendingPathComponent(".githooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
    let marker = fixture.root.appendingPathComponent("hook-invoked")
    let hook = hooks.appendingPathComponent("pre-commit")
    try writeExecutable(
      hook,
      "#!/bin/sh\nprintf invoked >>'\(marker.path)'\nexit 42\n"
    )
    try await fixture.run([
      "-C", repository.path, "config", "core.hooksPath", ".githooks",
    ])

    let command = makeApprovedCommand(
      id: "commit",
      kind: .gitCommit,
      executable: "git",
      arguments: ["feat(test): exercise hooks"],
      approvedHookPath: ".githooks"
    )
    let plan = try makeFrozenPlan([command])
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let blocked = try await runner.execute(
      commandID: command.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: repository
    )
    #expect(!blocked.succeeded)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let missingHead = try await fixture.git.runLocalGit(
      arguments: ["-C", repository.path, "rev-parse", "--verify", "HEAD"],
      workingDirectory: repository,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    #expect(missingHead.exitCode != 0)

    try writeExecutable(
      hook,
      "#!/bin/sh\nprintf invoked >>'\(marker.path)'\nexit 0\n"
    )
    let committed = try await runner.execute(
      commandID: command.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: repository
    )
    #expect(committed.succeeded)
    #expect(
      committed.repositoryHeadSHA
        == (try await fixture.output(["-C", repository.path, "rev-parse", "HEAD"]))
    )
    #expect(committed.approvedHookPath == ".githooks")
    #expect(committed.gitConfigurationDigest?.count == 64)
    #expect(try String(contentsOf: marker, encoding: .utf8) == "invokedinvoked")

    try "next\n".write(to: tracked, atomically: true, encoding: .utf8)
    try await fixture.run(["-C", repository.path, "add", "--", "file.txt"])
    try await fixture.run([
      "-C", repository.path, "config", "credential.helper", "!malicious-helper",
    ])
    await #expect(throws: VerificationCommandError.unsafeGitConfiguration) {
      _ = try await runner.execute(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: repository
      )
    }
  }

  @Test("runner reports timeout and bounded output as failed evidence")
  func resourceBounds() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-bounds")
    defer { fixture.remove() }
    let timeoutScript = fixture.root.appendingPathComponent("timeout.sh")
    try writeExecutable(timeoutScript, "#!/bin/sh\nexec /bin/sleep 30\n")
    let timeout = makeApprovedCommand(
      id: "timeout",
      kind: .repositoryScript,
      executable: "timeout.sh",
      arguments: [],
      timeout: 1,
      sourceDigest: sha256(try Data(contentsOf: timeoutScript))
    )
    let plan = try makeFrozenPlan([timeout])
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let evidence = try await runner.execute(
      commandID: timeout.id,
      expectedPlanDigest: plan.digest,
      plan: plan,
      workspace: fixture.root
    )
    #expect(evidence.timedOut)
    #expect(!evidence.succeeded)
  }
}
