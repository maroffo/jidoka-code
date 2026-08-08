import CryptoKit
import Foundation

public struct PullRequestCommitDerivation: Equatable, Sendable {
  public let baseSHA: String
  public let headSHA: String
  public let commitSHAs: [String]
  public let narrative: [PiCommitNarrativeEntry]

  public init(
    baseSHA: String,
    headSHA: String,
    commitSHAs: [String],
    narrative: [PiCommitNarrativeEntry]
  ) {
    self.baseSHA = baseSHA
    self.headSHA = headSHA
    self.commitSHAs = commitSHAs
    self.narrative = narrative
  }
}

public enum PullRequestCommitDeriverError: Error, Equatable, Sendable {
  case invalidRevision
  case unsafeRepository
  case gitFailure(exitCode: Int32?, stderrSHA256: String)
  case malformedOutput
  case commitLimitExceeded
  case workBudgetExceeded
  case narrativeMismatch
}

public protocol PullRequestCommitDeriving: Sendable {
  func derive(
    baseSHA: String,
    headSHA: String,
    mirror: URL
  ) async throws -> PullRequestCommitDerivation
}

public actor GitPullRequestCommitDeriver: PullRequestCommitDeriving {
  public static let maximumCommits = 256
  public static let maximumAggregateNarrativeBytes = 64 * 1_024 * 1_024
  public static let maximumDerivationSeconds: TimeInterval = 300
  private static let maximumMetadataBytes = 64 * 1_024
  private static let maximumPatchBytes = 8 * 1_024 * 1_024

  private let git: any GitLocalCommanding
  private let monotonicNow: @Sendable () -> TimeInterval

  public init(
    git: any GitLocalCommanding,
    monotonicNow: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.git = git
    self.monotonicNow = monotonicNow
  }

  public func derive(
    baseSHA: String,
    headSHA: String,
    mirror: URL
  ) async throws -> PullRequestCommitDerivation {
    guard GitHubInputValidation.validGitSHA(baseSHA),
      GitHubInputValidation.validGitSHA(headSHA),
      baseSHA != headSHA
    else {
      throw PullRequestCommitDeriverError.invalidRevision
    }
    let deadline = monotonicNow() + Self.maximumDerivationSeconds
    let repository = mirror.standardizedFileURL
    guard try safeRepository(repository) else {
      throw PullRequestCommitDeriverError.unsafeRepository
    }
    let prefix = gitPrefix(repository)
    try await requireCommit(
      baseSHA, prefix: prefix, repository: repository, deadline: deadline
    )
    try await requireCommit(
      headSHA, prefix: prefix, repository: repository, deadline: deadline
    )
    let revisionList = try await run(
      prefix + ["rev-list", "--reverse", "--topo-order", "\(baseSHA)..\(headSHA)"],
      repository: repository,
      maximumOutputBytes: 1_048_576,
      deadline: deadline
    )
    guard let revisionText = String(data: revisionList.stdout, encoding: .utf8) else {
      throw PullRequestCommitDeriverError.malformedOutput
    }
    let commits = revisionText.split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    guard !commits.isEmpty,
      commits.count <= Self.maximumCommits,
      Set(commits).count == commits.count,
      commits.last == headSHA,
      !commits.contains(baseSHA),
      commits.allSatisfy(GitHubInputValidation.validGitSHA)
    else {
      if commits.count > Self.maximumCommits {
        throw PullRequestCommitDeriverError.commitLimitExceeded
      }
      throw PullRequestCommitDeriverError.narrativeMismatch
    }

    var narrative: [PiCommitNarrativeEntry] = []
    narrative.reserveCapacity(commits.count)
    var aggregateBytes = 0
    for (ordinal, sha) in commits.enumerated() {
      let metadata = try await run(
        prefix + [
          "show", "-s", "--no-show-signature", "--format=%H%x00%P%x00%s%x00", sha,
        ],
        repository: repository,
        maximumOutputBytes: Self.maximumMetadataBytes,
        deadline: deadline
      )
      aggregateBytes = try Self.addToBudget(
        aggregateBytes,
        bytes: metadata.stdout.count + metadata.stderr.count
      )
      let fields = metadata.stdout.split(separator: 0, omittingEmptySubsequences: false)
      guard fields.count >= 4,
        String(decoding: fields[0], as: UTF8.self) == sha,
        fields.dropFirst(3).allSatisfy({ field in
          field.isEmpty || field.allSatisfy({ $0 == 0x0A })
        })
      else {
        throw PullRequestCommitDeriverError.malformedOutput
      }
      let parentsText = String(decoding: fields[1], as: UTF8.self)
      let parents = parentsText.split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
      let subject = String(decoding: fields[2], as: UTF8.self)
      guard !subject.isEmpty,
        subject.utf8.count <= 1_024,
        !subject.unicodeScalars.contains(where: { $0.value == 0 }),
        Set(parents).count == parents.count,
        parents.allSatisfy(GitHubInputValidation.validGitSHA)
      else {
        throw PullRequestCommitDeriverError.malformedOutput
      }
      let patch = try await run(
        prefix + [
          "diff-tree", "--root", "-m", "--no-commit-id", "--binary", "--full-index",
          "--no-ext-diff", "--no-textconv", "-p", sha,
        ],
        repository: repository,
        maximumOutputBytes: Self.maximumPatchBytes,
        deadline: deadline
      )
      aggregateBytes = try Self.addToBudget(
        aggregateBytes,
        bytes: patch.stdout.count + patch.stderr.count
      )
      narrative.append(
        PiCommitNarrativeEntry(
          ordinal: ordinal,
          sha: sha,
          parentSHAs: parents,
          subject: subject,
          patchSHA256: Self.sha256(patch.stdout)
        )
      )
    }
    do {
      _ = try PiPullRequestReviewRouter.commitNarrativeDigest(
        narrative,
        baseSHA: baseSHA
      )
    } catch {
      throw PullRequestCommitDeriverError.narrativeMismatch
    }
    return PullRequestCommitDerivation(
      baseSHA: baseSHA,
      headSHA: headSHA,
      commitSHAs: commits,
      narrative: narrative
    )
  }

  private func requireCommit(
    _ sha: String,
    prefix: [String],
    repository: URL,
    deadline: TimeInterval
  ) async throws {
    _ = try await run(
      prefix + ["cat-file", "-e", "\(sha)^{commit}"],
      repository: repository,
      maximumOutputBytes: Self.maximumMetadataBytes,
      deadline: deadline
    )
  }

  private func run(
    _ arguments: [String],
    repository: URL,
    maximumOutputBytes: Int,
    deadline: TimeInterval
  ) async throws -> GitProcessResult {
    let remaining = deadline - monotonicNow()
    guard remaining > 0 else {
      throw PullRequestCommitDeriverError.workBudgetExceeded
    }
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: repository.deletingLastPathComponent(),
      timeoutSeconds: min(120, remaining),
      maximumOutputBytes: maximumOutputBytes,
      environmentOverrides: [:]
    )
    guard result.succeeded else {
      throw PullRequestCommitDeriverError.gitFailure(
        exitCode: result.exitCode,
        stderrSHA256: result.stderrSHA256
      )
    }
    return result
  }

  private func gitPrefix(_ repository: URL) -> [String] {
    [
      "--no-pager", "--no-optional-locks", "--no-replace-objects",
      "--git-dir", repository.path,
      "-c", "core.hooksPath=/dev/null",
      "-c", "core.fsmonitor=false",
    ]
  }

  private func safeRepository(_ repository: URL) throws -> Bool {
    guard repository.isFileURL, repository.path.hasPrefix("/") else { return false }
    let values = try repository.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    return values.isDirectory == true && values.isSymbolicLink != true
      && repository.resolvingSymlinksInPath().path == repository.path
  }

  private static func addToBudget(_ current: Int, bytes: Int) throws -> Int {
    let (updated, overflow) = current.addingReportingOverflow(bytes)
    guard !overflow, updated <= maximumAggregateNarrativeBytes else {
      throw PullRequestCommitDeriverError.workBudgetExceeded
    }
    return updated
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
