import Foundation

public protocol IssueImplementationPlanning: Sendable {
  func plan(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    artifactSHA256: String
  ) async throws -> PiPlanningOutput
}

public struct PiIssueImplementationPlanner: IssueImplementationPlanning, Sendable {
  private let executorFactory: any PiWorkflowExecutorBuilding
  private let sessionRoot: URL
  private let profiles: [ModelProfileConfiguration]
  private let offline: Bool
  private let timeoutSeconds: TimeInterval

  public init(
    executorFactory: any PiWorkflowExecutorBuilding,
    sessionRoot: URL,
    profiles: [ModelProfileConfiguration],
    offline: Bool = false,
    timeoutSeconds: TimeInterval = 600
  ) {
    self.executorFactory = executorFactory
    self.sessionRoot = sessionRoot
    self.profiles = profiles
    self.offline = offline
    self.timeoutSeconds = timeoutSeconds
  }

  public func plan(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    artifactSHA256: String
  ) async throws -> PiPlanningOutput {
    let executor = executorFactory.makeExecutor(
      preparer: PiJobWorkflowPreparer(
        context: PiJobWorkflowContext(
          artifact: prepared.artifact,
          workspaceRoot: workspaceURL,
          sessionRoot: sessionRoot,
          profiles: profiles,
          allowedWritePaths: [],
          offline: offline,
          timeoutSeconds: timeoutSeconds
        )
      )
    )
    return try await PiPlanningRouter(executor: executor).run(
      jobID: "job-\(job.id.uuidString.lowercased())",
      artifactSHA256: artifactSHA256
    )
  }
}

public struct IssueImplementationExecutionResult: Sendable {
  public let orchestration: PiOrchestrationOutput
  public let importEvidence: WorkspaceImportEvidence?
  public let headSHA: String?
  public let treeSHA: String?

  public init(
    orchestration: PiOrchestrationOutput,
    importEvidence: WorkspaceImportEvidence?,
    headSHA: String?,
    treeSHA: String?
  ) {
    self.orchestration = orchestration
    self.importEvidence = importEvidence
    self.headSHA = headSHA
    self.treeSHA = treeSHA
  }
}

public protocol IssueImplementationOrchestrating: Sendable {
  func orchestrate(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    envelope: IssueImplementationPlanEnvelope,
    artifactSHA256: String
  ) async throws -> IssueImplementationExecutionResult
}

public enum PiIssueImplementationExecutorError: Error, Equatable, Sendable {
  case invalidPlanLayout
  case unsafePlanPath
  case bootstrapCommandFailed(String)
  case planCommitViolation
  case implementationCommitViolation
  case changedPathViolation(String)
  case finalCommitEvidenceMissing
  case gitEvidenceUnavailable
}

public struct PiIssueImplementationOrchestrator: IssueImplementationOrchestrating, Sendable {
  private let executorFactory: any PiWorkflowExecutorBuilding
  private let sessionRoot: URL
  private let profiles: [ModelProfileConfiguration]
  private let verificationRunner: VerificationCommandRunner
  private let commandRuns: ApprovedCommandRunStore
  private let commandGate: ApprovedCommandExecutionGate
  private let rolloutAuthority: any RolloutEffectAuthorizing
  private let importer: WorkspaceImporter
  private let git: any GitLocalCommanding
  private let offline: Bool
  private let timeoutSeconds: TimeInterval
  private let now: @Sendable () -> Date

  public init(
    executorFactory: any PiWorkflowExecutorBuilding,
    sessionRoot: URL,
    profiles: [ModelProfileConfiguration],
    verificationRunner: VerificationCommandRunner,
    commandRuns: ApprovedCommandRunStore,
    commandGate: ApprovedCommandExecutionGate,
    rolloutAuthority: any RolloutEffectAuthorizing,
    importer: WorkspaceImporter,
    git: any GitLocalCommanding,
    offline: Bool = false,
    timeoutSeconds: TimeInterval = 600,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.executorFactory = executorFactory
    self.sessionRoot = sessionRoot
    self.profiles = profiles
    self.verificationRunner = verificationRunner
    self.commandRuns = commandRuns
    self.commandGate = commandGate
    self.rolloutAuthority = rolloutAuthority
    self.importer = importer
    self.git = git
    self.offline = offline
    self.timeoutSeconds = timeoutSeconds
    self.now = now
  }

  public func orchestrate(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    envelope: IssueImplementationPlanEnvelope,
    artifactSHA256: String
  ) async throws -> IssueImplementationExecutionResult {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: job.id))
    ) {
      try await self.orchestrateAuthorized(
        job: job,
        prepared: prepared,
        workspaceURL: workspaceURL,
        envelope: envelope,
        artifactSHA256: artifactSHA256
      )
    }
  }

  private func orchestrateAuthorized(
    job: JobRecord,
    prepared: PreparedIssueImplementationJob,
    workspaceURL: URL,
    envelope: IssueImplementationPlanEnvelope,
    artifactSHA256: String
  ) async throws -> IssueImplementationExecutionResult {
    guard envelope.issueRevisionSHA256 == prepared.issueRevision.sha256,
      envelope.baseRevision == prepared.baseRevision,
      envelope.branch == prepared.branch,
      envelope.planPath == prepared.planPath,
      envelope.plan.artifactSHA256 == artifactSHA256
    else {
      throw PiIssueImplementationExecutorError.invalidPlanLayout
    }
    let layout = try CommandLayout(plan: envelope.plan, planPath: envelope.planPath)
    try Self.writePlan(
      envelope.plan.planMarkdown,
      relativePath: envelope.planPath,
      workspace: workspaceURL
    )
    let durableCommands = DurableApprovedCommandExecutor(
      job: job,
      store: commandRuns,
      gate: commandGate,
      runner: verificationRunner,
      authority: rolloutAuthority,
      workspace: workspaceURL,
      now: now
    )
    var bootstrapEvidence: [String: VerificationCommandEvidence] = [:]
    for commandID in layout.bootstrapCommandIDs {
      let evidence = try await durableCommands.executeBootstrap(
        commandID: commandID,
        expectedPlanDigest: envelope.plan.digest,
        plan: envelope.plan
      )
      guard evidence.succeeded else {
        throw PiIssueImplementationExecutorError.bootstrapCommandFailed(commandID)
      }
      bootstrapEvidence[commandID] = evidence
    }
    guard let planCommit = bootstrapEvidence[layout.firstCommitCommandID],
      let planHead = planCommit.repositoryHeadSHA,
      try await output(
        ["-C", workspaceURL.path, "rev-parse", "\(planHead)^"],
        workspace: workspaceURL
      ) == envelope.baseRevision.sha,
      try await changedFiles(commit: planHead, workspace: workspaceURL) == [envelope.planPath],
      try await output(
        ["-C", workspaceURL.path, "rev-parse", "HEAD"],
        workspace: workspaceURL
      ) == planHead
    else {
      throw PiIssueImplementationExecutorError.planCommitViolation
    }
    let commands = BootstrapCachingApprovedCommandExecutor(
      executor: durableCommands,
      cached: bootstrapEvidence
    )
    let executor = executorFactory.makeExecutor(
      preparer: PiJobWorkflowPreparer(
        context: PiJobWorkflowContext(
          artifact: prepared.artifact,
          workspaceRoot: workspaceURL,
          sessionRoot: sessionRoot,
          profiles: profiles,
          allowedWritePaths: layout.implementationPaths,
          offline: offline,
          timeoutSeconds: timeoutSeconds
        )
      )
    )
    let orchestration = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commands
    ).run(
      jobID: "job-\(job.id.uuidString.lowercased())",
      artifactSHA256: artifactSHA256,
      plan: envelope.plan
    )
    guard orchestration.disposition == .succeeded else {
      return IssueImplementationExecutionResult(
        orchestration: orchestration,
        importEvidence: nil,
        headSHA: nil,
        treeSHA: nil
      )
    }
    guard let writer = orchestration.roleResults.first,
      case .orchestration(let writerPayload) = writer.payload
    else {
      throw PiIssueImplementationExecutorError.changedPathViolation("missing-writer")
    }
    let approvedPaths = Set(layout.implementationPaths)
    for path in writerPayload.changedPaths where !approvedPaths.contains(path) {
      throw PiIssueImplementationExecutorError.changedPathViolation(path)
    }
    guard
      let commitEvidence = orchestration.commandEvidence.last(where: {
        $0.commandID == layout.finalCommitCommandID
      }),
      let headSHA = commitEvidence.repositoryHeadSHA
    else {
      throw PiIssueImplementationExecutorError.finalCommitEvidenceMissing
    }
    let treeSHA = try await output(
      ["-C", workspaceURL.path, "rev-parse", "\(headSHA)^{tree}"],
      workspace: workspaceURL
    )
    let finalCommitFiles = try await changedFiles(commit: headSHA, workspace: workspaceURL)
    let commitCount = Int(
      try await textOutput(
        [
          "-C", workspaceURL.path, "rev-list", "--count",
          "\(envelope.baseRevision.sha)..\(headSHA)",
        ],
        workspace: workspaceURL
      )
    )
    guard !finalCommitFiles.isEmpty,
      Set(finalCommitFiles).isSubset(of: approvedPaths),
      !finalCommitFiles.contains(envelope.planPath),
      let commitCount,
      (2...(PiOrchestrationRouter.maximumRounds + 1)).contains(commitCount)
    else {
      throw PiIssueImplementationExecutorError.implementationCommitViolation
    }
    let allowedFiles = approvedPaths.union([envelope.planPath])
    let imported = try await importer.importHead(
      request: WorkspaceImportRequest(
        jobID: job.id,
        branch: envelope.branch,
        baseSHA: envelope.baseRevision.sha,
        exactHeadSHA: headSHA,
        expectedTreeSHA: treeSHA,
        allowedChangedFiles: allowedFiles,
        commitEvidence: commitEvidence
      ),
      workspace: workspaceURL,
      mirror: prepared.mirrorURL
    )
    return IssueImplementationExecutionResult(
      orchestration: orchestration,
      importEvidence: imported,
      headSHA: headSHA,
      treeSHA: treeSHA
    )
  }

  private func changedFiles(commit: String, workspace: URL) async throws -> [String] {
    try await textOutput(
      ["-C", workspace.path, "diff-tree", "--no-commit-id", "--name-only", "-r", commit],
      workspace: workspace
    ).split(separator: "\n").map(String.init).sorted()
  }

  private func output(_ arguments: [String], workspace: URL) async throws -> String {
    let value = try await textOutput(arguments, workspace: workspace)
    guard GitHubInputValidation.validGitSHA(value) else {
      throw PiIssueImplementationExecutorError.gitEvidenceUnavailable
    }
    return value
  }

  private func textOutput(_ arguments: [String], workspace: URL) async throws -> String {
    let result = try await git.runLocalGit(
      arguments: arguments,
      workingDirectory: workspace,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_024,
      environmentOverrides: [:]
    )
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      throw PiIssueImplementationExecutorError.gitEvidenceUnavailable
    }
    return value
  }

  private static func writePlan(
    _ markdown: String,
    relativePath: String,
    workspace: URL
  ) throws {
    guard !relativePath.hasPrefix("/"),
      relativePath.split(separator: "/").allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git"
      })
    else {
      throw PiIssueImplementationExecutorError.unsafePlanPath
    }
    let standardizedRoot = workspace.standardizedFileURL
    let root = workspace.resolvingSymlinksInPath().standardizedFileURL
    guard standardizedRoot.path == root.path else {
      throw PiIssueImplementationExecutorError.unsafePlanPath
    }
    let components = relativePath.split(separator: "/").map(String.init)
    var parent = root
    for component in components.dropLast() {
      parent.appendPathComponent(component, isDirectory: true)
      if FileManager.default.fileExists(atPath: parent.path) {
        let values = try parent.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true,
          parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path
        else {
          throw PiIssueImplementationExecutorError.unsafePlanPath
        }
      } else {
        try FileManager.default.createDirectory(
          at: parent,
          withIntermediateDirectories: false
        )
      }
    }
    let destination = parent.appendingPathComponent(components.last!)
    if FileManager.default.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        (attributes[.referenceCount] as? NSNumber)?.intValue == 1
      else {
        throw PiIssueImplementationExecutorError.unsafePlanPath
      }
    }
    try Data(markdown.utf8).write(to: destination, options: [.atomic])
  }

  private struct CommandLayout {
    let bootstrapCommandIDs: [String]
    let implementationPaths: [String]
    let firstCommitCommandID: String
    let finalCommitCommandID: String

    init(plan: FrozenCommandPlan, planPath: String) throws {
      let commands = try plan.commandOrder.map { id -> ApprovedCommand in
        guard let value = plan.commands[id] else {
          throw PiIssueImplementationExecutorError.invalidPlanLayout
        }
        return value
      }
      let stageIndices = commands.indices.filter { commands[$0].registryKind == .gitStage }
      let commitIndices = commands.indices.filter { commands[$0].registryKind == .gitCommit }
      guard stageIndices.count == 2,
        commitIndices.count == 2,
        stageIndices[0] + 1 < commitIndices[0],
        commitIndices[0] < stageIndices[1],
        stageIndices[1] + 1 < commitIndices[1],
        commitIndices[1] == commands.count - 1,
        commands[stageIndices[0]].arguments == [planPath],
        !commands[stageIndices[1]].arguments.isEmpty,
        !commands[stageIndices[1]].arguments.contains(planPath),
        commands[(stageIndices[0] + 1)..<commitIndices[0]].allSatisfy({
          $0.registryKind == .repositoryScript
        }),
        commands[(stageIndices[1] + 1)..<commitIndices[1]].allSatisfy({
          $0.registryKind == .repositoryScript
        }),
        commitIndices[0] + 1 < stageIndices[1],
        commands[(commitIndices[0] + 1)..<stageIndices[1]].contains(where: {
          ![.gitRead, .gitStage, .gitCommit].contains($0.registryKind)
        }),
        let hookPath = commands[commitIndices[0]].approvedHookPath,
        !hookPath.isEmpty,
        commands[commitIndices[1]].approvedHookPath == hookPath
      else {
        throw PiIssueImplementationExecutorError.invalidPlanLayout
      }
      bootstrapCommandIDs = Array(plan.commandOrder[...commitIndices[0]])
      implementationPaths = commands[stageIndices[1]].arguments
      firstCommitCommandID = commands[commitIndices[0]].id
      finalCommitCommandID = commands[commitIndices[1]].id
    }
  }
}

private actor BootstrapCachingApprovedCommandExecutor: PiApprovedCommandExecuting {
  private let executor: DurableApprovedCommandExecutor
  private let cached: [String: VerificationCommandEvidence]

  init(
    executor: DurableApprovedCommandExecutor,
    cached: [String: VerificationCommandEvidence]
  ) {
    self.executor = executor
    self.cached = cached
  }

  func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    round: Int
  ) async throws -> VerificationCommandEvidence {
    if let evidence = cached[commandID] { return evidence }
    return try await executor.execute(
      commandID: commandID,
      expectedPlanDigest: expectedPlanDigest,
      plan: plan,
      round: round
    )
  }
}
