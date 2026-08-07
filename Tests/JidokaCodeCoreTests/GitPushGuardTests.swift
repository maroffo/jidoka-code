import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Atomic Git push old-zero guard")
struct GitPushGuardTests {
  @Test("an exact absent remote ref is accepted before transfer")
  func acceptsAbsentReference() throws {
    let fixture = guardFixture()
    try GitPushGuard.validate(
      arguments: [fixture.remote, fixture.remote],
      environment: fixture.environment,
      input: fixture.input(oldSHA: String(repeating: "0", count: 40))
    )
  }

  @Test("a remote ref observed before advertisement is rejected")
  func rejectsExistingReference() throws {
    let fixture = guardFixture()
    #expect(throws: GitPushGuardError.remoteReferenceExists) {
      try GitPushGuard.validate(
        arguments: [fixture.remote, fixture.remote],
        environment: fixture.environment,
        input: fixture.input(oldSHA: String(repeating: "b", count: 40))
      )
    }
  }

  @Test("changed argv, refspec, and extra input fail closed")
  func rejectsChangedInputs() throws {
    let fixture = guardFixture()
    #expect(throws: GitPushGuardError.invalidArguments) {
      try GitPushGuard.validate(
        arguments: ["origin", fixture.remote],
        environment: fixture.environment,
        input: fixture.input(oldSHA: String(repeating: "0", count: 40))
      )
    }
    #expect(throws: GitPushGuardError.invalidInput) {
      try GitPushGuard.validate(
        arguments: [fixture.remote, fixture.remote],
        environment: fixture.environment,
        input: Data(
          "\(fixture.sha) \(fixture.sha) refs/heads/agent/issue-8-other \(String(repeating: "0", count: 40))\n"
            .utf8
        )
      )
    }
    #expect(throws: GitPushGuardError.invalidInput) {
      try GitPushGuard.validate(
        arguments: [fixture.remote, fixture.remote],
        environment: fixture.environment,
        input: fixture.input(oldSHA: String(repeating: "0", count: 40)) + Data("extra\n".utf8)
      )
    }
  }

  @Test("missing and symbolic guard executables fail before Git")
  func rejectsUnsafeExecutable() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-push-guard-unsafe")
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("guard")
    let symbolic = fixture.root.appendingPathComponent("pre-push")
    try writeExecutable(target, "#!/bin/sh\nexit 0\n")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
    let transport = SystemGitTransport(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path,
      pushGuardExecutable: symbolic
    )
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_unsafe_guard",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      localFixtureURL: fixture.root.appendingPathComponent("remote.git")
    )
    await #expect(throws: GitTransportError.unsafePushGuard) {
      _ = try await transport.createRemoteRef(
        "refs/heads/agent/issue-8-unsafe",
        exactSHA: String(repeating: "a", count: 40),
        remote: remote,
        repository: fixture.root,
        credentials: nil
      )
    }
  }
}

private struct PushGuardFixture {
  let remote = "https://x-access-token@github.com/owner/repo.git"
  let reference = "refs/heads/agent/issue-8-guard"
  let sha = String(repeating: "a", count: 40)

  var environment: [String: String] {
    [
      "JIDOKA_PUSH_GUARD_REFERENCE": reference,
      "JIDOKA_PUSH_GUARD_REMOTE": remote,
      "JIDOKA_PUSH_GUARD_SHA": sha,
    ]
  }

  func input(oldSHA: String) -> Data {
    Data("\(sha) \(sha) \(reference) \(oldSHA)\n".utf8)
  }
}

private func guardFixture() -> PushGuardFixture {
  PushGuardFixture()
}
