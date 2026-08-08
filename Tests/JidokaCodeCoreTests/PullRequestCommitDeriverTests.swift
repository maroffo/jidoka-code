import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Independent fetched pull request commit derivation")
struct PullRequestCommitDeriverTests {
  @Test("local Git produces a complete topological narrative from base to exact head")
  func derivesNarrative() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-pr-commit-deriver")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let base = try await fixture.commit(
      repository: repository,
      path: "base.txt",
      contents: "base\n",
      message: "test: add base"
    )
    try await fixture.run(["-C", repository.path, "checkout", "-b", "feature"])
    let first = try await fixture.commit(
      repository: repository,
      path: "first.txt",
      contents: "first\n",
      message: "feat: add first change"
    )
    try await fixture.run(["-C", repository.path, "checkout", "-b", "side", base])
    let side = try await fixture.commit(
      repository: repository,
      path: "side.txt",
      contents: "side\n",
      message: "feat: add side change"
    )
    try await fixture.run(["-C", repository.path, "checkout", "feature"])
    try await fixture.run([
      "-C", repository.path, "merge", "--no-ff", "-m", "merge: join side", side,
    ])
    let head = try await fixture.output(["-C", repository.path, "rev-parse", "HEAD"])
    let deriver = GitPullRequestCommitDeriver(git: fixture.git)

    let result = try await deriver.derive(
      baseSHA: base,
      headSHA: head,
      mirror: repository.appendingPathComponent(".git", isDirectory: true)
    )

    #expect(result.baseSHA == base)
    #expect(result.headSHA == head)
    #expect(Set(result.commitSHAs) == Set([first, side, head]))
    #expect(result.commitSHAs.last == head)
    #expect(result.narrative.map(\.ordinal) == Array(result.narrative.indices))
    #expect(result.narrative.map(\.sha) == result.commitSHAs)
    #expect(result.narrative.last?.parentSHAs == [first, side])
    #expect(result.narrative.allSatisfy { GitHubInputValidation.validSHA256($0.patchSHA256) })
    #expect(
      GitHubInputValidation.validSHA256(
        try PiPullRequestReviewRouter.commitNarrativeDigest(
          result.narrative,
          baseSHA: base
        )
      )
    )
  }

  @Test("commit-count and aggregate wall-clock budgets stop before narrative expansion")
  func boundedWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-pr-budget-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let base = String(repeating: "a", count: 40)
    let head = String(repeating: "f", count: 40)
    let commits =
      (1...GitPullRequestCommitDeriver.maximumCommits).map {
        String(format: "%040llx", Int64($0))
      } + [head]
    let oversized = GitPullRequestBudgetGit(revisionList: commits)

    await #expect(throws: PullRequestCommitDeriverError.commitLimitExceeded) {
      try await GitPullRequestCommitDeriver(git: oversized).derive(
        baseSHA: base,
        headSHA: head,
        mirror: root
      )
    }
    #expect(await oversized.callCount == 3)

    let aggregateCommits =
      (1...8).map {
        String(format: "%040llx", Int64($0))
      } + [head]
    await #expect(throws: PullRequestCommitDeriverError.workBudgetExceeded) {
      try await GitPullRequestCommitDeriver(
        git: GitPullRequestAggregateBudgetGit(
          base: base,
          commits: aggregateCommits
        )
      ).derive(baseSHA: base, headSHA: head, mirror: root)
    }

    let clock = PullRequestBudgetClock()
    await #expect(throws: PullRequestCommitDeriverError.workBudgetExceeded) {
      try await GitPullRequestCommitDeriver(
        git: GitPullRequestBudgetGit(revisionList: [head]),
        monotonicNow: { clock.read() }
      ).derive(baseSHA: base, headSHA: head, mirror: root)
    }

    let nearDeadlineGit = GitPullRequestBudgetGit(revisionList: [head])
    let nearDeadlineClock = PullRequestBudgetClock(values: [0, 299, 301])
    await #expect(throws: PullRequestCommitDeriverError.workBudgetExceeded) {
      try await GitPullRequestCommitDeriver(
        git: nearDeadlineGit,
        monotonicNow: { nearDeadlineClock.read() }
      ).derive(baseSHA: base, headSHA: head, mirror: root)
    }
    #expect(await nearDeadlineGit.timeouts.first == 1)
  }

  @Test("unreachable, equal, and missing revisions fail closed")
  func rejectsInvalidRevisions() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-pr-commit-rejection")
    defer { fixture.remove() }
    let repository = try await fixture.initializeRepository()
    let base = try await fixture.commit(
      repository: repository,
      path: "base.txt",
      contents: "base\n",
      message: "test: base"
    )
    let deriver = GitPullRequestCommitDeriver(git: fixture.git)
    let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)

    await #expect(throws: PullRequestCommitDeriverError.invalidRevision) {
      try await deriver.derive(baseSHA: base, headSHA: base, mirror: gitDirectory)
    }
    await #expect(throws: PullRequestCommitDeriverError.self) {
      try await deriver.derive(
        baseSHA: base,
        headSHA: String(repeating: "f", count: 40),
        mirror: gitDirectory
      )
    }

    let orphan = try await fixture.output([
      "-C", repository.path, "commit-tree", "-m", "orphan", "HEAD^{tree}",
    ])
    await #expect(throws: PullRequestCommitDeriverError.narrativeMismatch) {
      try await deriver.derive(baseSHA: base, headSHA: orphan, mirror: gitDirectory)
    }
  }
}

private actor GitPullRequestBudgetGit: GitLocalCommanding {
  let revisionList: [String]
  private(set) var callCount = 0
  private(set) var timeouts: [TimeInterval] = []

  init(revisionList: [String]) {
    self.revisionList = revisionList
  }

  func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String]
  ) async throws -> GitProcessResult {
    callCount += 1
    timeouts.append(timeoutSeconds)
    let stdout: Data
    if arguments.contains("rev-list") {
      stdout = Data((revisionList.joined(separator: "\n") + "\n").utf8)
    } else {
      stdout = Data()
    }
    return GitProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      stdout: stdout,
      stderr: Data(),
      durationSeconds: 0
    )
  }
}

private actor GitPullRequestAggregateBudgetGit: GitLocalCommanding {
  let base: String
  let commits: [String]

  init(base: String, commits: [String]) {
    self.base = base
    self.commits = commits
  }

  func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String]
  ) async throws -> GitProcessResult {
    let stdout: Data
    if arguments.contains("rev-list") {
      stdout = Data((commits.joined(separator: "\n") + "\n").utf8)
    } else if arguments.contains("--format=%H%x00%P%x00%s%x00"),
      let sha = arguments.last,
      let index = commits.firstIndex(of: sha)
    {
      let parent = index == 0 ? base : commits[index - 1]
      stdout = Data("\(sha)\0\(parent)\0subject\0\n".utf8)
    } else if arguments.contains("diff-tree") {
      stdout = Data(repeating: 0x61, count: 8 * 1_024 * 1_024)
    } else {
      stdout = Data()
    }
    return GitProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      stdout: stdout,
      stderr: Data(),
      durationSeconds: 0
    )
  }
}

private final class PullRequestBudgetClock: @unchecked Sendable {
  private let lock = NSLock()
  private let values: [TimeInterval]
  private var reads = 0

  init(values: [TimeInterval] = [0, 301]) {
    self.values = values
  }

  func read() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    let index = min(reads, values.count - 1)
    reads += 1
    return values[index]
  }
}
