import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

final class GitTestRoot: @unchecked Sendable {
  let root: URL
  let git: SystemGitTransport

  init(prefix: String, installPushGuard: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let pushGuard: URL
    if installPushGuard {
      let hooks = root.appendingPathComponent("git-hooks", isDirectory: true)
      try FileManager.default.createDirectory(
        at: hooks,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      pushGuard = hooks.appendingPathComponent("pre-push")
      try FileManager.default.copyItem(
        at: builtProduct(named: "JidokaCodePushGuard"),
        to: pushGuard
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: pushGuard.path
      )
    } else {
      pushGuard = SystemGitTransport.packagedPushGuardExecutable
    }
    git = SystemGitTransport(
      homeDirectory: home.path,
      temporaryDirectory: root.path,
      pushGuardExecutable: pushGuard
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  func run(_ arguments: [String], cwd: URL? = nil) async throws -> GitProcessResult {
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: cwd ?? root,
      timeoutSeconds: 120,
      maximumOutputBytes: 8 * 1_024 * 1_024,
      environmentOverrides: [:]
    )
    guard result.succeeded else {
      Issue.record(
        "git command failed: \(arguments.joined(separator: " ")) stderr=\(String(decoding: result.stderr, as: UTF8.self))"
      )
      throw GitTransportError.commandFailed(
        exitCode: result.exitCode,
        stderrSHA256: result.stderrSHA256
      )
    }
    return result
  }

  func output(_ arguments: [String], cwd: URL? = nil) async throws -> String {
    let result = try await run(arguments, cwd: cwd)
    return String(decoding: result.stdout, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func initializeRepository(name: String = "source") async throws -> URL {
    let repository = root.appendingPathComponent(name, isDirectory: true)
    try await run(["init", repository.path])
    try await run(["-C", repository.path, "config", "user.name", "Jidoka Code"])
    try await run([
      "-C", repository.path, "config", "user.email", "jidoka-code@invalid.example",
    ])
    try await run(["-C", repository.path, "config", "commit.gpgsign", "false"])
    return repository
  }

  func commit(
    repository: URL,
    path: String,
    contents: String,
    message: String
  ) async throws -> String {
    let destination = repository.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: destination)
    try await run(["-C", repository.path, "add", "--", path])
    try await run(["-C", repository.path, "commit", "-m", message])
    return try await output(["-C", repository.path, "rev-parse", "HEAD"])
  }

  func bareRemote(from repository: URL, name: String = "remote.git") async throws -> URL {
    let remote = root.appendingPathComponent(name, isDirectory: true)
    try await run(["init", "--bare", remote.path])
    try await run([
      "-C", repository.path, "push", remote.path, "HEAD:refs/heads/main",
    ])
    try await run([
      "--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main",
    ])
    return remote
  }
}

func makeApprovedCommand(
  id: String,
  kind: ApprovedCommandRegistryKind,
  executable: String,
  arguments: [String],
  workingDirectory: String = ".",
  environment: [String: String] = [:],
  timeout: Int = 30,
  rationale: String = "fixture",
  sourceDigest: String? = nil,
  approvedHookPath: String? = nil,
  overrideDigest: String? = nil
) -> ApprovedCommand {
  let digest = ApprovedCommand.digest(
    id: id,
    registryKind: kind,
    executableOrRepositoryScript: executable,
    arguments: arguments,
    workingDirectory: workingDirectory,
    environmentOverrides: environment,
    timeoutSeconds: timeout,
    rationale: rationale,
    sourceDigest: sourceDigest,
    approvedHookPath: approvedHookPath
  )
  return ApprovedCommand(
    id: id,
    registryKind: kind,
    executableOrRepositoryScript: executable,
    arguments: arguments,
    workingDirectory: workingDirectory,
    environmentOverrides: environment,
    timeoutSeconds: timeout,
    rationale: rationale,
    sourceDigest: sourceDigest,
    approvedHookPath: approvedHookPath,
    definitionDigest: overrideDigest ?? digest
  )
}

func makeFrozenPlan(
  _ commands: [ApprovedCommand],
  decisionEvidenceSeed: String = "fixture",
  planningFacts: ComplexityFacts? = nil,
  proposedComplexity: WorkComplexity = .simple
) throws -> FrozenCommandPlan {
  let artifactSHA256 = String(repeating: "a", count: 64)
  let planMarkdown = "# Test plan\n"
  let candidate = try FrozenCommandPlan(
    artifactSHA256: artifactSHA256,
    planMarkdown: planMarkdown,
    commands: commands,
    planningDecision: nil,
    expectedDigest: FrozenCommandPlan.digest(
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: commands,
      planningDecision: nil
    )
  )
  let proposals = commands.map { command in
    ApprovedCommandProposal(
      id: command.id,
      registryKind: command.registryKind,
      executableOrRepositoryScript: command.executableOrRepositoryScript,
      arguments: command.arguments,
      workingDirectory: command.workingDirectory,
      environmentOverrides: command.environmentOverrides,
      timeoutSeconds: command.timeoutSeconds,
      rationale: command.rationale,
      sourceDigest: command.sourceDigest,
      approvedHookPath: command.approvedHookPath
    )
  }
  let facts =
    planningFacts
    ?? ComplexityFacts(
      workstreamCount: 1,
      publicAPI: false,
      nonDestructiveSchema: false,
      crossModuleConcurrency: false,
      operationalRollback: false,
      designAlternatives: false,
      humanDecisionGap: false,
      securityOrSecretCore: false,
      dataLossMigration: false,
      releaseOrTag: false,
      infrastructureBlastRadius: false,
      crossRepositoryCoordination: false,
      unresolvedDesignDebate: false,
      unverifiable: false
    )
  let roles: [PiWorkflowRole] = [.writer, .architecture, .security, .test, .synthesis]
  let commandDigests = commands.map(\.definitionDigest).sorted()
  let roleResults = roles.enumerated().map { index, role in
    let payload = PiPlanningPayload(
      verdict: "pass",
      severity: .none,
      summary: "validated test planning decision",
      proposedComplexity: proposedComplexity,
      classifierFacts: facts,
      evidence: ["\(decisionEvidenceSeed)-evidence-\(role.rawValue)"],
      findings: [],
      commandDefinitions: role == .writer ? proposals : [],
      approvedCommandDigests: role == .writer ? [] : commandDigests,
      approvedPlanDigest: role == .writer ? nil : candidate.digest,
      planMarkdown: role == .writer ? planMarkdown : ""
    )
    return PiWorkflowRoleResult(
      workflow: .planning,
      role: role,
      artifactSHA256: artifactSHA256,
      approvedCommandIDs: [],
      payload: .planning(payload),
      recordSHA256: sha256(
        Data("\(decisionEvidenceSeed)-planning-role-\(index)-\(role.rawValue)".utf8)
      )
    )
  }
  let reports = roleResults.map { result -> ComplexityReport in
    guard case .planning(let payload) = result.payload else { preconditionFailure() }
    return ComplexityReport(
      reporter: result.role,
      proposed: payload.proposedComplexity,
      facts: payload.classifierFacts,
      evidence: payload.evidence
    )
  }
  let planningDecision = try FrozenPlanningDecision(
    candidatePlan: candidate,
    complexity: ComplexityClassifier.classify(reports),
    roleResults: roleResults
  )
  return try FrozenCommandPlan(
    artifactSHA256: artifactSHA256,
    planMarkdown: planMarkdown,
    commands: commands,
    planningDecision: planningDecision,
    expectedDigest: FrozenCommandPlan.digest(
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: commands,
      planningDecision: planningDecision
    )
  )
}

func sha256(_ data: Data) -> String {
  GitHubMarkerCodec.sha256(data)
}

func writeExecutable(_ url: URL, _ contents: String) throws {
  try Data(contents.utf8).write(to: url, options: .atomic)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: url.path
  )
}

func builtProduct(named name: String) throws -> URL {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
  guard
    let enumerator = FileManager.default.enumerator(
      at: buildRoot,
      includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw GitTestSupportError.productNotFound
  }
  for case let candidate as URL in enumerator where candidate.lastPathComponent == name {
    let values = try candidate.resourceValues(forKeys: [
      .isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    if values.isExecutable == true, values.isRegularFile == true,
      values.isSymbolicLink != true, candidate.path.contains("/debug/")
    {
      return candidate
    }
  }
  throw GitTestSupportError.productNotFound
}

private enum GitTestSupportError: Error {
  case productNotFound
}
