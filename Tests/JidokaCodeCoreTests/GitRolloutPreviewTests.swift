import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Rollout Git preview reads")
struct GitRolloutPreviewTests {
  @Test("preview fetches only the exact base and pull-request head under a finite permit")
  func exactBoundedFetch() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-rollout-preview-fetch")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let baseSHA = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let headSHA = try await fixture.commit(
      repository: source,
      path: "file.txt",
      contents: "head\n",
      message: "feat: add preview head"
    )
    try await fixture.run([
      "-C", source.path, "push", remoteURL.path,
      "HEAD:refs/pull/17/head",
    ])

    let repositoryID = UUID()
    let jobID = UUID()
    let remote = try GitRemoteRepository(
      repositoryID: repositoryID,
      nodeID: "R_rollout_preview",
      owner: "owner",
      name: "repository",
      defaultBranch: "main",
      localFixtureURL: remoteURL
    )
    let authority = try BoundedRolloutPreviewReadAuthority(
      repository: nil,
      maximumRequests: 1,
      maximumBytes: 1,
      repositoryID: repositoryID,
      repositoryNodeID: remote.nodeID,
      jobID: jobID,
      maximumGitRemoteReads: 2
    )
    let transport = SystemGitTransport(
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path,
      rolloutReadAuthority: authority,
      now: { Date(timeIntervalSince1970: 1) }
    )
    let destination = fixture.root.appendingPathComponent(
      "preview.git",
      isDirectory: true
    )
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
    ) {
      try await transport.preparePullRequestPreviewRepository(
        number: 17,
        baseBranch: "main",
        expectedBaseSHA: baseSHA,
        expectedHeadSHA: headSHA,
        jobID: jobID,
        remote: remote,
        destination: destination,
        credentials: nil
      )
    }

    #expect(
      try await transport.localRevision(
        reference: "refs/jidoka/preview/base",
        repository: destination
      ) == baseSHA
    )
    #expect(
      try await transport.localRevision(
        reference: "refs/jidoka/preview/head",
        repository: destination
      ) == headSHA
    )
    let snapshot = await authority.snapshot()
    #expect(snapshot.reservedGitRemoteReads == 2)
    #expect(snapshot.outstandingGitRemoteReads == 0)
  }

  @Test("closing read admission after reservation prevents Git transport")
  func readAdmissionClosesBeforeTransport() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-rollout-preview-closed-read")
    defer { fixture.remove() }
    let jobID = UUID()
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_rollout_closed_read",
      owner: "owner",
      name: "repository",
      defaultBranch: "main",
      localFixtureURL: fixture.root.appendingPathComponent("remote.git")
    )
    let authority = ExplicitTestRolloutEffectAuthority(
      closeAfterGitReadReservation: true
    )
    let runner = NeverGitProcessRunner()
    let transport = SystemGitTransport(
      runner: runner,
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path,
      rolloutReadAuthority: authority
    )

    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
      ) {
        try await transport.cloneMirror(
          remote: remote,
          destination: fixture.root.appendingPathComponent("mirror.git"),
          credentials: nil
        )
      }
    }
    #expect(await runner.executions() == 0)
    #expect(await authority.waitForDrain(until: Date(timeIntervalSince1970: 1)))
  }

  @Test("a failed Git read keeps the transport error primary when settlement also fails")
  func failedReadSettlementKeepsTransportErrorPrimary() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-rollout-preview-settle-failure")
    defer { fixture.remove() }
    let jobID = UUID()
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_rollout_settle_failure",
      owner: "owner",
      name: "repository",
      defaultBranch: "main",
      localFixtureURL: fixture.root.appendingPathComponent("remote.git")
    )
    let authority = ExplicitTestRolloutEffectAuthority(failGitReadSettlement: true)
    let runner = NeverGitProcessRunner()
    let transport = SystemGitTransport(
      runner: runner,
      homeDirectory: fixture.root.path,
      temporaryDirectory: fixture.root.path,
      rolloutReadAuthority: authority
    )

    await #expect(throws: GitProcessError.invalidLimits) {
      try await RolloutEffectTaskContext.$current.withValue(
        RolloutEffectExecutionContext(mode: .workflow(jobID: jobID))
      ) {
        try await transport.cloneMirror(
          remote: remote,
          destination: fixture.root.appendingPathComponent("mirror.git"),
          credentials: nil
        )
      }
    }
    #expect(await runner.executions() == 1)
    // The reservation stays consumed and unsettled: a failed settlement never
    // replenishes read authority, and it never masks the transport error.
    #expect(await authority.waitForDrain(until: Date(timeIntervalSince1970: 1)) == false)
  }
}

private actor NeverGitProcessRunner: GitProcessExecuting {
  private var count = 0

  func run(_: GitProcessRequest) async throws -> GitProcessResult {
    count += 1
    throw GitProcessError.invalidLimits
  }

  func executions() -> Int { count }
}
