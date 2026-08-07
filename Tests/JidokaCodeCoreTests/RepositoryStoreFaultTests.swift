import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Repository store interruption recovery")
struct RepositoryStoreFaultTests {
  @Test("workspace failures remove only owned pending or moved directories")
  func workspaceFailureMatrix() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-repository-faults")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    let baseSHA = try await fixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let repositoryID = UUID()
    try await ConfigurationStore(database: database).upsertRepository(
      RepositoryConfiguration(
        id: repositoryID,
        nodeID: "R_fault",
        owner: "owner",
        name: "repo",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: true,
        implementationEnabled: true,
        enabled: true
      ),
      now: Date(timeIntervalSince1970: 3_000)
    )
    let remote = try GitRemoteRepository(
      repositoryID: repositoryID,
      nodeID: "R_fault",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      localFixtureURL: remoteURL
    )
    let transport = FaultInjectingRepositoryTransport(base: fixture.git)
    let store = try RepositoryStore(
      rootURL: fixture.root.appendingPathComponent("ApplicationSupport"),
      database: database,
      transport: transport
    )
    _ = try await store.ensureMirror(remote: remote)
    let jobs = DurableJobStore(database: database)

    for (index, failureCall) in [7, 8, 12, 15].enumerated() {
      let creation = try await jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: repositoryID,
          kind: .issueImplementation,
          objectNodeID: "I_fault_\(index)",
          revisionKey: "claim-\(index)"
        ),
        objectNumber: 100 + index,
        contractVersionUsed: "v1",
        priority: .issueImplementation,
        firstStep: .implement,
        now: Date(timeIntervalSince1970: 3_001 + Double(index))
      )
      let job = try #require(createdJob(creation))
      await transport.failLocalCall(failureCall)
      await #expect(throws: RepositoryStoreError.gitFailure) {
        _ = try await store.materializeWorkspace(
          jobID: job.id,
          remote: remote,
          baseSHA: baseSHA,
          branch: "agent/issue-\(100 + index)-fault"
        )
      }
      #expect(try await store.workspaceRecord(jobID: job.id) == nil)
      let exactDirectory = store.workspacesURL.appendingPathComponent(
        job.id.uuidString.lowercased()
      )
      #expect(!FileManager.default.fileExists(atPath: exactDirectory.path))
      let pending = try FileManager.default.contentsOfDirectory(atPath: store.workspacesURL.path)
        .filter { $0.hasPrefix("\(job.id.uuidString.lowercased()).pending-") }
      #expect(pending.isEmpty)
    }

    await transport.failLocalCall(nil)
    let missingJobID = UUID()
    await #expect(throws: RepositoryStoreError.invalidJob) {
      _ = try await store.materializeWorkspace(
        jobID: missingJobID,
        remote: remote,
        baseSHA: baseSHA,
        branch: "agent/issue-999-db-failure"
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: store.workspacesURL.appendingPathComponent(
          missingJobID.uuidString.lowercased()
        ).path
      )
    )
  }

  @Test("a mirror replaced by a symlink is rejected before Git follows it")
  func mirrorSymlink() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-repository-symlink")
    defer { fixture.remove() }
    let source = try await fixture.initializeRepository()
    _ = try await fixture.commit(
      repository: source,
      path: "README.md",
      contents: "base\n",
      message: "chore: add base"
    )
    let remoteURL = try await fixture.bareRemote(from: source)
    let database = try SQLiteStore(
      databaseURL: fixture.root.appendingPathComponent("state.sqlite3")
    )
    let remote = try GitRemoteRepository(
      repositoryID: UUID(),
      nodeID: "R_symlink",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      localFixtureURL: remoteURL
    )
    let store = try RepositoryStore(
      rootURL: fixture.root.appendingPathComponent("ApplicationSupport"),
      database: database,
      transport: fixture.git
    )
    let mirror = try await store.ensureMirror(remote: remote)
    let moved = mirror.deletingLastPathComponent().appendingPathComponent("moved.git")
    try FileManager.default.moveItem(at: mirror, to: moved)
    try FileManager.default.createSymbolicLink(at: mirror, withDestinationURL: moved)
    await #expect(throws: RepositoryStoreError.unsafePath) {
      _ = try await store.ensureMirror(remote: remote)
    }
  }
}

private func createdJob(_ result: JobCreationResult) -> JobRecord? {
  guard case .created(let job) = result else { return nil }
  return job
}

private actor FaultInjectingRepositoryTransport: GitRepositoryTransporting,
  GitLocalCommanding
{
  private let base: SystemGitTransport
  private var localCall = 0
  private var failingCall: Int?

  init(base: SystemGitTransport) {
    self.base = base
  }

  func failLocalCall(_ call: Int?) {
    localCall = 0
    failingCall = call
  }

  func cloneMirror(
    remote: GitRemoteRepository,
    destination: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws {
    try await base.cloneMirror(
      remote: remote,
      destination: destination,
      credentials: credentials
    )
  }

  func fetchMirror(
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws {
    try await base.fetchMirror(remote: remote, mirror: mirror, credentials: credentials)
  }

  func fetchPullRequest(
    number: Int,
    expectedSHA: String,
    jobID: UUID,
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String {
    try await base.fetchPullRequest(
      number: number,
      expectedSHA: expectedSHA,
      jobID: jobID,
      remote: remote,
      mirror: mirror,
      credentials: credentials
    )
  }

  func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String]
  ) async throws -> GitProcessResult {
    localCall += 1
    if localCall == failingCall {
      return GitProcessResult(
        exitCode: 70,
        terminationSignal: nil,
        timedOut: false,
        outputLimitExceeded: false,
        stdout: Data(),
        stderr: Data("fault".utf8),
        durationSeconds: 0
      )
    }
    return try await base.runLocalGit(
      arguments: arguments,
      workingDirectory: workingDirectory,
      timeoutSeconds: timeoutSeconds,
      maximumOutputBytes: maximumOutputBytes,
      environmentOverrides: environmentOverrides
    )
  }
}
