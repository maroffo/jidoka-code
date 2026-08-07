import Foundation

public struct WorkspaceImportRequest: Sendable {
  public let jobID: UUID
  public let branch: String
  public let baseSHA: String
  public let exactHeadSHA: String
  public let expectedTreeSHA: String
  public let allowedChangedFiles: Set<String>
  public let commitEvidence: VerificationCommandEvidence

  public init(
    jobID: UUID,
    branch: String,
    baseSHA: String,
    exactHeadSHA: String,
    expectedTreeSHA: String,
    allowedChangedFiles: Set<String>,
    commitEvidence: VerificationCommandEvidence
  ) {
    self.jobID = jobID
    self.branch = branch
    self.baseSHA = baseSHA
    self.exactHeadSHA = exactHeadSHA
    self.expectedTreeSHA = expectedTreeSHA
    self.allowedChangedFiles = allowedChangedFiles
    self.commitEvidence = commitEvidence
  }
}

public struct WorkspaceImportEvidence: Equatable, Sendable {
  public let localReference: String
  public let exactHeadSHA: String
  public let treeSHA: String
  public let changedFiles: [String]
  public let evidenceDigest: String
}

public enum WorkspaceImporterError: Error, Equatable, Sendable {
  case invalidRequest
  case branchMismatch
  case headMismatch
  case baseNotAncestor
  case treeMismatch
  case changedFileViolation(String)
  case hookEvidenceMissing
  case importedReferenceCollision
  case workspaceDirty
  case gitFailure
}

public actor WorkspaceImporter {
  private let git: any GitLocalCommanding

  public init(git: any GitLocalCommanding) {
    self.git = git
  }

  public func importHead(
    request: WorkspaceImportRequest,
    workspace: URL,
    mirror: URL
  ) async throws -> WorkspaceImportEvidence {
    try Self.validate(request)
    guard request.commitEvidence.succeeded,
      request.commitEvidence.registryKind == .gitCommit,
      request.commitEvidence.repositoryHeadSHA == request.exactHeadSHA,
      let expectedConfigurationDigest = request.commitEvidence.gitConfigurationDigest,
      GitHubInputValidation.validSHA256(expectedConfigurationDigest),
      GitHubInputValidation.validSHA256(request.commitEvidence.definitionDigest)
    else {
      throw WorkspaceImporterError.hookEvidenceMissing
    }
    let configuration = try await git.runLocalGit(
      arguments: [
        "-C", workspace.path, "config", "--local", "--null", "--list",
      ],
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard configuration.succeeded else { throw WorkspaceImporterError.hookEvidenceMissing }
    let observedConfigurationDigest: String
    do {
      observedConfigurationDigest =
        try VerificationCommandRunner
        .validateGitConfigurationData(
          configuration.stdout,
          repository: workspace,
          approvedHookPath: request.commitEvidence.approvedHookPath
        )
    } catch {
      throw WorkspaceImporterError.hookEvidenceMissing
    }
    guard observedConfigurationDigest == expectedConfigurationDigest else {
      throw WorkspaceImporterError.hookEvidenceMissing
    }
    let status = try await git.runLocalGit(
      arguments: [
        "-C", workspace.path, "status", "--porcelain=v1", "-z", "--untracked-files=all",
      ],
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 4 * 1_024 * 1_024,
      environmentOverrides: [:]
    )
    guard status.succeeded else { throw WorkspaceImporterError.gitFailure }
    guard status.stdout.isEmpty else { throw WorkspaceImporterError.workspaceDirty }
    let branch = try await output(
      ["-C", workspace.path, "symbolic-ref", "--short", "HEAD"],
      workingDirectory: workspace
    )
    guard branch == request.branch else { throw WorkspaceImporterError.branchMismatch }
    let head = try await output(
      ["-C", workspace.path, "rev-parse", "--verify", "HEAD"],
      workingDirectory: workspace
    )
    guard head == request.exactHeadSHA else { throw WorkspaceImporterError.headMismatch }
    let ancestry = try await git.runLocalGit(
      arguments: [
        "-C", workspace.path, "merge-base", "--is-ancestor",
        request.baseSHA, request.exactHeadSHA,
      ],
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard ancestry.exitCode == 0, ancestry.terminationSignal == nil else {
      throw WorkspaceImporterError.baseNotAncestor
    }
    let tree = try await output(
      ["-C", workspace.path, "rev-parse", "\(request.exactHeadSHA)^{tree}"],
      workingDirectory: workspace
    )
    guard tree == request.expectedTreeSHA else { throw WorkspaceImporterError.treeMismatch }

    let changedResult = try await git.runLocalGit(
      arguments: [
        "-C", workspace.path, "diff", "--name-only", "-z",
        "\(request.baseSHA)...\(request.exactHeadSHA)",
      ],
      workingDirectory: workspace,
      timeoutSeconds: 60,
      maximumOutputBytes: 4 * 1_024 * 1_024,
      environmentOverrides: [:]
    )
    guard changedResult.succeeded else { throw WorkspaceImporterError.gitFailure }
    let changed = try Self.parseChangedFiles(changedResult.stdout)
    for path in changed where !request.allowedChangedFiles.contains(path) {
      throw WorkspaceImporterError.changedFileViolation(path)
    }

    let reference = "refs/jidoka/jobs/\(request.jobID.uuidString.lowercased())/head"
    let existing = try await optionalRevision(reference, mirror: mirror)
    if let existing, existing != request.exactHeadSHA {
      throw WorkspaceImporterError.importedReferenceCollision
    }
    if existing == nil {
      let result = try await git.runLocalGit(
        arguments: [
          "--git-dir", mirror.path, "fetch", "--no-tags", "--",
          workspace.path, "\(request.exactHeadSHA):\(reference)",
        ],
        workingDirectory: mirror.deletingLastPathComponent(),
        timeoutSeconds: 120,
        maximumOutputBytes: 8 * 1_024 * 1_024,
        environmentOverrides: [:]
      )
      guard result.succeeded else { throw WorkspaceImporterError.gitFailure }
    }
    let imported = try await optionalRevision(reference, mirror: mirror)
    guard imported == request.exactHeadSHA else {
      throw WorkspaceImporterError.headMismatch
    }
    let sortedFiles = changed.sorted()
    let fields = [reference, request.exactHeadSHA, tree] + sortedFiles
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return WorkspaceImportEvidence(
      localReference: reference,
      exactHeadSHA: request.exactHeadSHA,
      treeSHA: tree,
      changedFiles: sortedFiles,
      evidenceDigest: GitHubMarkerCodec.sha256(Data(framed.utf8))
    )
  }

  private func optionalRevision(_ reference: String, mirror: URL) async throws -> String? {
    let result = try await git.runLocalGit(
      arguments: ["--git-dir", mirror.path, "rev-parse", "--verify", "--quiet", reference],
      workingDirectory: mirror.deletingLastPathComponent(),
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    if result.exitCode == 1, result.terminationSignal == nil { return nil }
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      GitHubInputValidation.validGitSHA(value)
    else {
      throw WorkspaceImporterError.gitFailure
    }
    return value
  }

  private func output(_ arguments: [String], workingDirectory: URL) async throws -> String {
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: workingDirectory,
      timeoutSeconds: 60,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)
    else {
      throw WorkspaceImporterError.gitFailure
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func validate(_ request: WorkspaceImportRequest) throws {
    guard GitBranchPolicy.validImplementationBranch(request.branch),
      GitHubInputValidation.validGitSHA(request.baseSHA),
      GitHubInputValidation.validGitSHA(request.exactHeadSHA),
      GitHubInputValidation.validGitSHA(request.expectedTreeSHA),
      !request.allowedChangedFiles.isEmpty,
      request.allowedChangedFiles.count <= 10_000,
      request.allowedChangedFiles.allSatisfy(validPath)
    else {
      throw WorkspaceImporterError.invalidRequest
    }
  }

  static func parseChangedFiles(_ data: Data) throws -> [String] {
    guard data.count <= 4 * 1_024 * 1_024 else {
      throw WorkspaceImporterError.invalidRequest
    }
    guard data.last == 0, data.count > 1 else {
      throw WorkspaceImporterError.invalidRequest
    }
    let payload = data.dropLast()
    let encodedFields = payload.split(separator: 0, omittingEmptySubsequences: false)
    guard !encodedFields.isEmpty, encodedFields.count <= 10_000,
      encodedFields.allSatisfy({ !$0.isEmpty })
    else {
      throw WorkspaceImporterError.invalidRequest
    }
    var fields: [String] = []
    fields.reserveCapacity(encodedFields.count)
    for encoded in encodedFields {
      guard let field = String(data: Data(encoded), encoding: .utf8) else {
        throw WorkspaceImporterError.invalidRequest
      }
      fields.append(field)
    }
    guard fields.allSatisfy(validPath), Set(fields).count == fields.count else {
      throw WorkspaceImporterError.invalidRequest
    }
    fields.sort()
    return fields
  }

  private static func validPath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/"),
      value.utf8.count <= 4_096, !value.contains("\u{0}"), !value.contains("//")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git"
    }
  }
}
