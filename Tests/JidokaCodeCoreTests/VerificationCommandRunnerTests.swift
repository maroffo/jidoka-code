import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Frozen argv-only verification command runner")
struct VerificationCommandRunnerTests {
  @Test("definition digest frames argument and environment domains independently")
  func definitionDigestDomainSeparation() {
    let common:
      (
        [String], [String: String]
      ) -> String = { arguments, environment in
        ApprovedCommand.digest(
          id: "verify",
          registryKind: .repositoryScript,
          executableOrRepositoryScript: "verify.sh",
          arguments: arguments,
          workingDirectory: ".",
          environmentOverrides: environment,
          timeoutSeconds: 30,
          rationale: "Verify one bounded condition.",
          sourceDigest: String(repeating: "a", count: 64),
          approvedHookPath: nil
        )
      }

    #expect(common(["CI", "1"], [:]) != common([], ["CI": "1"]))
  }

  @Test("frozen plan digest binds artifact, plan bytes, classifier, and command order")
  func frozenPlanDomainSeparation() {
    let check = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let test = makeApprovedCommand(
      id: "test",
      kind: .makeTargets,
      executable: "make",
      arguments: ["test"]
    )
    let artifact = String(repeating: "a", count: 64)
    let plan = try? makeFrozenPlan([check, test])
    let baseline = plan?.digest
    let planningDecision = plan?.planningDecision

    #expect(
      baseline
        != FrozenCommandPlan.digest(
          artifactSHA256: String(repeating: "b", count: 64),
          planMarkdown: "# Test plan\n",
          commands: [check, test],
          planningDecision: planningDecision
        ))
    #expect(
      baseline
        != FrozenCommandPlan.digest(
          artifactSHA256: artifact,
          planMarkdown: "# Plan changed\n",
          commands: [check, test],
          planningDecision: planningDecision
        ))
    #expect(
      baseline
        != FrozenCommandPlan.digest(
          artifactSHA256: artifact,
          planMarkdown: "# Test plan\n",
          commands: [test, check],
          planningDecision: planningDecision
        ))
    #expect(
      baseline
        != (try? makeFrozenPlan(
          [check, test],
          decisionEvidenceSeed: "changed"
        ).digest)
    )
    #expect(
      baseline
        != FrozenCommandPlan.digest(
          artifactSHA256: artifact,
          planMarkdown: "# Test plan\n",
          commands: [check, test],
          planningDecision: planningDecision,
          classifierVersion: "2"
        ))
  }

  @Test("human-owned planning decisions can never become executable plans")
  func humanOwnedPlanRejected() {
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"]
    )
    let hardRisk = ComplexityFacts(
      workstreamCount: 1,
      publicAPI: false,
      nonDestructiveSchema: false,
      crossModuleConcurrency: false,
      operationalRollback: false,
      designAlternatives: false,
      humanDecisionGap: false,
      securityOrSecretCore: true,
      dataLossMigration: false,
      releaseOrTag: false,
      infrastructureBlastRadius: false,
      crossRepositoryCoordination: false,
      unresolvedDesignDebate: false,
      unverifiable: false
    )

    #expect(throws: VerificationCommandError.invalidPlan) {
      try makeFrozenPlan(
        [command],
        decisionEvidenceSeed: "human-owned",
        planningFacts: hardRisk,
        proposedComplexity: .humanOwned
      )
    }
  }

  @Test("repository script keeps metacharacters as data and locks source digest")
  func repositoryScript() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-script")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let script = repository.appendingPathComponent("verify.sh")
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
      workspace: repository
    )
    #expect(evidence.succeeded)
    #expect(evidence.repositoryStateSHA256?.count == 64)
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
        workspace: repository
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
    #expect(throws: VerificationCommandError.definitionDigestMismatch) {
      _ = try makeFrozenPlan([badDigest])
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
        id: "git-read-hook",
        kind: .gitRead,
        executable: "git",
        arguments: ["status", "--porcelain=v1"],
        approvedHookPath: ".githooks"
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
        id: "git-stage-hook",
        kind: .gitStage,
        executable: "git",
        arguments: ["file.txt"],
        approvedHookPath: ".githooks"
      ),
      makeApprovedCommand(
        id: "metadata-stage",
        kind: .gitStage,
        executable: "git",
        arguments: [".GIT/config"]
      ),
      makeApprovedCommand(
        id: "metadata-cwd",
        kind: .makeTargets,
        executable: "make",
        arguments: ["check"],
        workingDirectory: ".PI"
      ),
      makeApprovedCommand(
        id: "shell",
        kind: .repositoryScript,
        executable: "/bin/sh",
        arguments: ["-c", "command"],
        sourceDigest: String(repeating: "c", count: 64)
      ),
    ] {
      #expect(throws: VerificationCommandError.self) {
        _ = try makeFrozenPlan([command])
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

  @Test("Git commands reject gitdir indirection, core worktree overrides, and alternates")
  func gitRepositoryIdentity() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-git-identity")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let command = makeApprovedCommand(
      id: "status",
      kind: .gitRead,
      executable: "git",
      arguments: ["status", "--porcelain=v1"]
    )
    let plan = try makeFrozenPlan([command])
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )

    let redirected = fixture.root.appendingPathComponent("redirected", isDirectory: true)
    try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)
    try "gitdir: \(repository.appendingPathComponent(".git").path)\n".write(
      to: redirected.appendingPathComponent(".git"),
      atomically: true,
      encoding: .utf8
    )
    await #expect(throws: VerificationCommandError.unsafeGitRepository) {
      _ = try await runner.execute(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: redirected
      )
    }

    try await fixture.run([
      "-C", repository.path, "config", "--local", "core.worktree", redirected.path,
    ])
    await #expect(throws: VerificationCommandError.unsafeGitConfiguration) {
      _ = try await runner.execute(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: repository
      )
    }
    try await fixture.run([
      "-C", repository.path, "config", "--local", "--unset", "core.worktree",
    ])

    let alternates = repository.appendingPathComponent(".git/objects/info/alternates")
    try "\(redirected.path)\n".write(
      to: alternates,
      atomically: true,
      encoding: .utf8
    )
    await #expect(throws: VerificationCommandError.unsafeGitRepository) {
      _ = try await runner.execute(
        commandID: command.id,
        expectedPlanDigest: plan.digest,
        plan: plan,
        workspace: repository
      )
    }
  }

  @Test("Git read and stage disable repository hooks and optional read locks")
  func nonCommitGitCommandsDisableHooks() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-command-no-read-hooks")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    _ = try await fixture.commit(
      repository: repository,
      path: "tracked.txt",
      contents: "tracked\n",
      message: "test: seed repository"
    )
    let marker = fixture.root.appendingPathComponent("post-index-change-invoked")
    let hook = repository.appendingPathComponent(".git/hooks/post-index-change")
    try writeExecutable(
      hook,
      "#!/bin/sh\nprintf invoked >>'\(marker.path)'\n"
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: repository.appendingPathComponent("tracked.txt").path
    )
    let runner = VerificationCommandRunner(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path
    )
    let read = makeApprovedCommand(
      id: "status",
      kind: .gitRead,
      executable: "git",
      arguments: ["status", "--porcelain=v1"]
    )
    let readPlan = try makeFrozenPlan([read])
    let readEvidence = try await runner.execute(
      commandID: read.id,
      expectedPlanDigest: readPlan.digest,
      plan: readPlan,
      workspace: repository
    )
    #expect(readEvidence.succeeded)
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    try "new\n".write(
      to: repository.appendingPathComponent("new.txt"),
      atomically: true,
      encoding: .utf8
    )
    let stage = makeApprovedCommand(
      id: "stage",
      kind: .gitStage,
      executable: "git",
      arguments: ["new.txt"]
    )
    let stagePlan = try makeFrozenPlan([stage])
    let stageEvidence = try await runner.execute(
      commandID: stage.id,
      expectedPlanDigest: stagePlan.digest,
      plan: stagePlan,
      workspace: repository
    )
    #expect(stageEvidence.succeeded)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
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
    let repository = try await fixture.initializeRepository()
    let timeoutScript = repository.appendingPathComponent("timeout.sh")
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
      workspace: repository
    )
    #expect(evidence.timedOut)
    #expect(!evidence.succeeded)
    #expect(evidence.repositoryStateSHA256?.count == 64)
  }
}
