import CryptoKit
import Foundation

public enum ApprovedCommandRegistryKind: String, CaseIterable, Codable, Sendable {
  case makeTargets
  case swiftBuildTest
  case xcodebuildBuildTest
  case repositoryScript
  case gitRead
  case gitStage
  case gitCommit
}

public struct ApprovedCommand: Codable, Equatable, Sendable {
  public let id: String
  public let registryKind: ApprovedCommandRegistryKind
  public let executableOrRepositoryScript: String
  public let arguments: [String]
  public let workingDirectory: String
  public let environmentOverrides: [String: String]
  public let timeoutSeconds: Int
  public let rationale: String
  public let sourceDigest: String?
  public let approvedHookPath: String?
  public let definitionDigest: String

  public init(
    id: String,
    registryKind: ApprovedCommandRegistryKind,
    executableOrRepositoryScript: String,
    arguments: [String],
    workingDirectory: String,
    environmentOverrides: [String: String],
    timeoutSeconds: Int,
    rationale: String,
    sourceDigest: String?,
    approvedHookPath: String?,
    definitionDigest: String
  ) {
    self.id = id
    self.registryKind = registryKind
    self.executableOrRepositoryScript = executableOrRepositoryScript
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environmentOverrides = environmentOverrides
    self.timeoutSeconds = timeoutSeconds
    self.rationale = rationale
    self.sourceDigest = sourceDigest
    self.approvedHookPath = approvedHookPath
    self.definitionDigest = definitionDigest
  }

  public static func digest(
    id: String,
    registryKind: ApprovedCommandRegistryKind,
    executableOrRepositoryScript: String,
    arguments: [String],
    workingDirectory: String,
    environmentOverrides: [String: String],
    timeoutSeconds: Int,
    rationale: String,
    sourceDigest: String?,
    approvedHookPath: String?
  ) -> String {
    var fields = [
      "id", id,
      "registryKind", registryKind.rawValue,
      "executableOrRepositoryScript", executableOrRepositoryScript,
      "workingDirectory", workingDirectory,
      "timeoutSeconds", String(timeoutSeconds),
      "rationale", rationale,
      "sourceDigest", sourceDigest ?? "",
      "approvedHookPath", approvedHookPath ?? "",
      "argumentCount", String(arguments.count),
    ]
    for (index, argument) in arguments.enumerated() {
      fields.append("argument[\(index)]")
      fields.append(argument)
    }
    let environment = environmentOverrides.sorted(by: { $0.key < $1.key })
    fields.append("environmentCount")
    fields.append(String(environment.count))
    for (key, value) in environment {
      fields.append("environmentKey")
      fields.append(key)
      fields.append("environmentValue")
      fields.append(value)
    }
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(framed.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct FrozenPlanningDecision: Equatable, Sendable {
  public let candidatePlanDigest: String
  public let complexity: ComplexityDecision
  public let roleResults: [PiWorkflowRoleResult]
  public let digest: String

  public init(
    candidatePlan: FrozenCommandPlan,
    complexity: ComplexityDecision,
    roleResults: [PiWorkflowRoleResult]
  ) throws {
    guard candidatePlan.planningDecision == nil else {
      throw VerificationCommandError.invalidPlan
    }
    try Self.validate(
      candidatePlanDigest: candidatePlan.digest,
      artifactSHA256: candidatePlan.artifactSHA256,
      planMarkdown: candidatePlan.planMarkdown,
      commands: candidatePlan.commandOrder.compactMap { candidatePlan.commands[$0] },
      complexity: complexity,
      roleResults: roleResults
    )
    self.candidatePlanDigest = candidatePlan.digest
    self.complexity = complexity
    self.roleResults = roleResults
    digest = Self.digest(
      candidatePlanDigest: candidatePlan.digest,
      complexity: complexity,
      roleResults: roleResults
    )
  }

  fileprivate func validate(
    artifactSHA256: String,
    planMarkdown: String,
    commands: [ApprovedCommand]
  ) throws {
    try Self.validate(
      candidatePlanDigest: candidatePlanDigest,
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: commands,
      complexity: complexity,
      roleResults: roleResults
    )
    guard
      digest
        == Self.digest(
          candidatePlanDigest: candidatePlanDigest,
          complexity: complexity,
          roleResults: roleResults
        )
    else {
      throw VerificationCommandError.invalidPlan
    }
  }

  private static func validate(
    candidatePlanDigest: String,
    artifactSHA256: String,
    planMarkdown: String,
    commands: [ApprovedCommand],
    complexity: ComplexityDecision,
    roleResults: [PiWorkflowRoleResult]
  ) throws {
    let expectedRoles: [PiWorkflowRole] = [
      .writer, .architecture, .security, .test, .synthesis,
    ]
    let commandDigests = commands.map(\.definitionDigest).sorted()
    guard !complexity.isHumanOwned,
      GitHubInputValidation.validSHA256(candidatePlanDigest),
      roleResults.map(\.role) == expectedRoles,
      Set(roleResults.map(\.recordSHA256)).count == roleResults.count,
      roleResults.allSatisfy({ result in
        result.workflow == .planning
          && result.artifactSHA256 == artifactSHA256
          && result.approvedCommandIDs.isEmpty
          && GitHubInputValidation.validSHA256(result.recordSHA256)
      })
    else {
      throw VerificationCommandError.invalidPlan
    }
    var reports: [ComplexityReport] = []
    for result in roleResults {
      guard case .planning(let payload) = result.payload,
        payload.verdict == "pass",
        payload.severity.rank < PiWorkflowReportSeverity.major.rank,
        !payload.findings.contains(where: {
          $0.severity == .critical || $0.severity == .major
        })
      else {
        throw VerificationCommandError.invalidPlan
      }
      if result.role == .writer {
        let proposed = try ApprovedCommandCanonicalizer.canonicalize(
          payload.commandDefinitions
        )
        guard payload.approvedPlanDigest == nil,
          payload.approvedCommandDigests.isEmpty,
          payload.planMarkdown == planMarkdown,
          proposed == commands
        else {
          throw VerificationCommandError.invalidPlan
        }
      } else {
        guard payload.commandDefinitions.isEmpty,
          payload.approvedPlanDigest == candidatePlanDigest,
          payload.approvedCommandDigests.sorted() == commandDigests
        else {
          throw VerificationCommandError.invalidPlan
        }
      }
      reports.append(
        ComplexityReport(
          reporter: result.role,
          proposed: payload.proposedComplexity,
          facts: payload.classifierFacts,
          evidence: payload.evidence
        )
      )
    }
    guard try ComplexityClassifier.classify(reports) == complexity else {
      throw VerificationCommandError.invalidPlan
    }
  }

  private static func digest(
    candidatePlanDigest: String,
    complexity: ComplexityDecision,
    roleResults: [PiWorkflowRoleResult]
  ) -> String {
    var fields = [
      "schemaVersion", "1",
      "candidatePlanDigest", candidatePlanDigest,
      "complexityDecisionDigest", complexity.digest,
      "roleResultCount", String(roleResults.count),
    ]
    for (index, result) in roleResults.enumerated() {
      fields += [
        "roleResultIndex", String(index),
        "workflow", result.workflow.rawValue,
        "role", result.role.rawValue,
        "artifactSHA256", result.artifactSHA256,
        "recordSHA256", result.recordSHA256,
      ]
    }
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(framed.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct FrozenCommandPlan: Equatable, Sendable {
  public let digest: String
  public let artifactSHA256: String
  public let classifierVersion: String
  public let planningDecision: FrozenPlanningDecision?
  public let planMarkdown: String
  public let commandOrder: [String]
  public let commands: [String: ApprovedCommand]

  public var planningDecisionSHA256: String? { planningDecision?.digest }

  public init(
    artifactSHA256: String,
    planMarkdown: String,
    commands: [ApprovedCommand],
    planningDecision: FrozenPlanningDecision?,
    expectedDigest: String,
    classifierVersion: String = ComplexityDecision.classifierVersion
  ) throws {
    guard GitHubInputValidation.validSHA256(artifactSHA256),
      classifierVersion == ComplexityDecision.classifierVersion,
      !planMarkdown.isEmpty,
      planMarkdown.utf8.count <= 262_144,
      !commands.isEmpty,
      Set(commands.map(\.id)).count == commands.count,
      GitHubInputValidation.validSHA256(expectedDigest)
    else {
      throw VerificationCommandError.invalidPlan
    }
    for command in commands {
      try VerificationCommandRunner.validateDefinition(command)
      let observedDefinition = ApprovedCommand.digest(
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
      guard observedDefinition == command.definitionDigest else {
        throw VerificationCommandError.definitionDigestMismatch
      }
    }
    let observed = Self.digest(
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: commands,
      planningDecision: planningDecision,
      classifierVersion: classifierVersion
    )
    guard observed == expectedDigest else {
      throw VerificationCommandError.planDigestMismatch
    }
    digest = expectedDigest
    self.artifactSHA256 = artifactSHA256
    if let planningDecision {
      try planningDecision.validate(
        artifactSHA256: artifactSHA256,
        planMarkdown: planMarkdown,
        commands: commands
      )
      let candidateDigest = Self.digest(
        artifactSHA256: artifactSHA256,
        planMarkdown: planMarkdown,
        commands: commands,
        planningDecision: nil,
        classifierVersion: classifierVersion
      )
      guard planningDecision.candidatePlanDigest == candidateDigest else {
        throw VerificationCommandError.invalidPlan
      }
    }
    self.classifierVersion = classifierVersion
    self.planningDecision = planningDecision
    self.planMarkdown = planMarkdown
    commandOrder = commands.map(\.id)
    self.commands = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
  }

  public func validateFinalPlanningDecision() throws {
    guard let planningDecision else { throw VerificationCommandError.invalidPlan }
    let orderedCommands = commandOrder.compactMap { commands[$0] }
    guard orderedCommands.count == commandOrder.count else {
      throw VerificationCommandError.invalidPlan
    }
    try planningDecision.validate(
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: orderedCommands
    )
    let candidateDigest = Self.digest(
      artifactSHA256: artifactSHA256,
      planMarkdown: planMarkdown,
      commands: orderedCommands,
      planningDecision: nil,
      classifierVersion: classifierVersion
    )
    guard planningDecision.candidatePlanDigest == candidateDigest,
      digest
        == Self.digest(
          artifactSHA256: artifactSHA256,
          planMarkdown: planMarkdown,
          commands: orderedCommands,
          planningDecision: planningDecision,
          classifierVersion: classifierVersion
        )
    else {
      throw VerificationCommandError.invalidPlan
    }
  }

  public static func digest(
    artifactSHA256: String,
    planMarkdown: String,
    commands: [ApprovedCommand],
    planningDecision: FrozenPlanningDecision?,
    classifierVersion: String = ComplexityDecision.classifierVersion
  ) -> String {
    var fields = [
      "schemaVersion", "2",
      "artifactSHA256", artifactSHA256,
      "classifierVersion", classifierVersion,
      "planningDecisionSHA256", planningDecision?.digest ?? "pending",
      "planMarkdown", planMarkdown,
      "commandCount", String(commands.count),
    ]
    for (index, command) in commands.enumerated() {
      fields.append("commandIndex")
      fields.append(String(index))
      fields.append("commandID")
      fields.append(command.id)
      fields.append("commandDefinitionDigest")
      fields.append(command.definitionDigest)
    }
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(framed.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct VerificationCommandEvidence: Equatable, Sendable {
  public let commandID: String
  public let registryKind: ApprovedCommandRegistryKind
  public let definitionDigest: String
  public let exitCode: Int32?
  public let terminationSignal: Int32?
  public let timedOut: Bool
  public let outputLimitExceeded: Bool
  public let durationMilliseconds: Int64
  public let stdoutSHA256: String
  public let stderrSHA256: String
  public let stdoutExcerpt: String
  public let stderrExcerpt: String
  public let repositoryHeadSHA: String?
  public let approvedHookPath: String?
  public let gitConfigurationDigest: String?

  public var succeeded: Bool {
    exitCode == 0 && terminationSignal == nil && !timedOut && !outputLimitExceeded
  }
}

public enum VerificationCommandError: Error, Equatable, Sendable {
  case invalidPlan
  case planDigestMismatch
  case commandNotFound
  case definitionDigestMismatch
  case invalidIdentifier
  case invalidWorkingDirectory
  case invalidEnvironment
  case invalidTimeout
  case invalidCommandShape
  case forbiddenArgument
  case unsafeRepositoryScript
  case sourceDigestMismatch
  case unsafeGitConfiguration
  case unsafeGitRepository
  case commitHeadUnavailable
}

public actor VerificationCommandRunner {
  private let process: any GitProcessExecuting
  private let developerDirectory: String
  private let homeDirectory: String
  private let temporaryDirectory: String

  public init(
    process: any GitProcessExecuting = BoundedProcessRunner(),
    developerDirectory: String = CredentiallessEnvironment.lockedDeveloperDirectory,
    homeDirectory: String = "/var/empty",
    temporaryDirectory: String = NSTemporaryDirectory()
  ) {
    self.process = process
    self.developerDirectory = developerDirectory
    self.homeDirectory = homeDirectory
    self.temporaryDirectory = temporaryDirectory
  }

  public func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    workspace: URL
  ) async throws -> VerificationCommandEvidence {
    try plan.validateFinalPlanningDecision()
    guard expectedPlanDigest == plan.digest else {
      throw VerificationCommandError.planDigestMismatch
    }
    guard let command = plan.commands[commandID] else {
      throw VerificationCommandError.commandNotFound
    }
    try Self.validateDefinition(command)
    let observedDigest = ApprovedCommand.digest(
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
    guard observedDigest == command.definitionDigest else {
      throw VerificationCommandError.definitionDigestMismatch
    }
    let workingDirectory = try Self.resolveDirectory(
      command.workingDirectory,
      workspace: workspace
    )
    let invocation = try await resolve(
      command,
      workspace: workspace,
      workingDirectory: workingDirectory
    )
    var environment = try CredentiallessEnvironment.make(
      developerDirectory: developerDirectory,
      homeDirectory: homeDirectory,
      temporaryDirectory: temporaryDirectory
    )
    for (key, value) in command.environmentOverrides {
      guard Self.allowedEnvironmentKeys.contains(key), !value.contains("\u{0}") else {
        throw VerificationCommandError.invalidEnvironment
      }
      environment[key] = value
    }
    let result = try await process.run(
      GitProcessRequest(
        executable: invocation.executable,
        arguments: invocation.arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutSeconds: TimeInterval(command.timeoutSeconds),
        maximumOutputBytes: 4 * 1_024 * 1_024
      ))
    let repositoryHeadSHA: String?
    let gitConfigurationDigest: String?
    if command.registryKind == .gitCommit, result.succeeded {
      repositoryHeadSHA = try await committedHead(
        repository: workingDirectory,
        environment: environment
      )
      gitConfigurationDigest = try await validateGitConfiguration(
        repository: workingDirectory,
        approvedHookPath: command.approvedHookPath
      )
    } else {
      repositoryHeadSHA = nil
      gitConfigurationDigest = nil
    }
    return VerificationCommandEvidence(
      commandID: command.id,
      registryKind: command.registryKind,
      definitionDigest: command.definitionDigest,
      exitCode: result.exitCode,
      terminationSignal: result.terminationSignal,
      timedOut: result.timedOut,
      outputLimitExceeded: result.outputLimitExceeded,
      durationMilliseconds: Int64((result.durationSeconds * 1_000).rounded()),
      stdoutSHA256: result.stdoutSHA256,
      stderrSHA256: result.stderrSHA256,
      stdoutExcerpt: Self.redactedExcerpt(result.stdout),
      stderrExcerpt: Self.redactedExcerpt(result.stderr),
      repositoryHeadSHA: repositoryHeadSHA,
      approvedHookPath: command.approvedHookPath,
      gitConfigurationDigest: gitConfigurationDigest
    )
  }

  private func committedHead(
    repository: URL,
    environment: [String: String]
  ) async throws -> String {
    let result = try await process.run(
      GitProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: try Self.gitInvocationPrefix(repository: repository)
          + ["rev-parse", "--verify", "HEAD"],
        workingDirectory: repository,
        environment: environment,
        timeoutSeconds: 30,
        maximumOutputBytes: 1_024
      ))
    guard result.succeeded,
      let value = String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      GitHubInputValidation.validGitSHA(value)
    else {
      throw VerificationCommandError.commitHeadUnavailable
    }
    return value
  }

  private func resolve(
    _ command: ApprovedCommand,
    workspace: URL,
    workingDirectory: URL
  ) async throws -> (executable: URL, arguments: [String]) {
    switch command.registryKind {
    case .makeTargets:
      guard command.executableOrRepositoryScript == "make", !command.arguments.isEmpty,
        command.arguments.allSatisfy(Self.validMakeTarget)
      else {
        throw VerificationCommandError.invalidCommandShape
      }
      return (URL(fileURLWithPath: "/usr/bin/make"), command.arguments)

    case .swiftBuildTest:
      guard command.executableOrRepositoryScript == "swift" else {
        throw VerificationCommandError.invalidCommandShape
      }
      try Self.validateSwiftArguments(command.arguments)
      return (URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift"] + command.arguments)

    case .xcodebuildBuildTest:
      guard command.executableOrRepositoryScript == "xcodebuild" else {
        throw VerificationCommandError.invalidCommandShape
      }
      try Self.validateXcodebuildArguments(command.arguments)
      return (URL(fileURLWithPath: "/usr/bin/xcrun"), ["xcodebuild"] + command.arguments)

    case .repositoryScript:
      guard let sourceDigest = command.sourceDigest,
        GitHubInputValidation.validSHA256(sourceDigest),
        Self.validRelativePath(command.executableOrRepositoryScript)
      else {
        throw VerificationCommandError.unsafeRepositoryScript
      }
      let script = workspace.appendingPathComponent(command.executableOrRepositoryScript)
      try Self.validateContained(script, root: workspace)
      let values = try script.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.isExecutable == true
      else {
        throw VerificationCommandError.unsafeRepositoryScript
      }
      let data = try Data(contentsOf: script, options: [.mappedIfSafe])
      guard Self.sha256(data) == sourceDigest else {
        throw VerificationCommandError.sourceDigestMismatch
      }
      try Self.validateOpaqueArguments(command.arguments)
      return (script, command.arguments)

    case .gitRead:
      guard command.executableOrRepositoryScript == "git" else {
        throw VerificationCommandError.invalidCommandShape
      }
      try Self.validateGitRead(command.arguments)
      _ = try await validateGitConfiguration(
        repository: workspace,
        approvedHookPath: nil
      )
      return (
        URL(fileURLWithPath: "/usr/bin/git"),
        try Self.gitInvocationPrefix(repository: workspace)
          + ["--no-optional-locks"] + command.arguments
      )

    case .gitStage:
      guard command.executableOrRepositoryScript == "git", !command.arguments.isEmpty else {
        throw VerificationCommandError.invalidCommandShape
      }
      _ = try await validateGitConfiguration(
        repository: workspace,
        approvedHookPath: nil
      )
      for path in command.arguments {
        guard Self.validRelativePath(path) else {
          throw VerificationCommandError.forbiddenArgument
        }
        let candidate = workingDirectory.appendingPathComponent(path)
        try Self.validateContained(candidate, root: workingDirectory)
      }
      return (
        URL(fileURLWithPath: "/usr/bin/git"),
        try Self.gitInvocationPrefix(repository: workspace) + ["add", "--"]
          + command.arguments
      )

    case .gitCommit:
      guard command.executableOrRepositoryScript == "git", command.arguments.count == 1,
        Self.validCommitMessage(command.arguments[0])
      else {
        throw VerificationCommandError.invalidCommandShape
      }
      _ = try await validateGitConfiguration(
        repository: workspace,
        approvedHookPath: command.approvedHookPath
      )
      return (
        URL(fileURLWithPath: "/usr/bin/git"),
        try Self.gitInvocationPrefix(
          repository: workspace,
          allowHooks: command.approvedHookPath != nil
        ) + ["commit", "-m", command.arguments[0]]
      )
    }
  }

  private static func gitInvocationPrefix(
    repository: URL,
    allowHooks: Bool = false
  ) throws -> [String] {
    let gitDirectory = try validateGitRepositoryMetadata(repository: repository)
    var arguments = [
      "--git-dir=\(gitDirectory.path)",
      "--work-tree=\(repository.path)",
      "-c", "core.worktree=\(repository.path)",
      "-c", "core.bare=false",
      "-c", "core.attributesFile=/dev/null",
      "-c", "core.excludesFile=/dev/null",
    ]
    if !allowHooks {
      arguments += ["-c", "core.hooksPath=/dev/null"]
    }
    return arguments
  }

  private static func validateGitRepositoryMetadata(repository: URL) throws -> URL {
    let root = repository.standardizedFileURL
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
    let rootValues = try gitDirectory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let canonicalGitDirectory = gitDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard rootValues.isDirectory == true,
      rootValues.isSymbolicLink != true,
      canonicalGitDirectory.path == canonicalRoot.appendingPathComponent(".git").path
    else {
      throw VerificationCommandError.unsafeGitRepository
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: gitDirectory,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ],
        options: []
      )
    else {
      throw VerificationCommandError.unsafeGitRepository
    }
    var entryCount = 0
    for case let entry as URL in enumerator {
      entryCount += 1
      let canonicalEntry = entry.resolvingSymlinksInPath().standardizedFileURL
      guard entryCount <= 1_000_000,
        canonicalEntry.path.hasPrefix(canonicalGitDirectory.path + "/")
      else {
        throw VerificationCommandError.unsafeGitRepository
      }
      let values = try entry.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isSymbolicLink != true else {
        throw VerificationCommandError.unsafeGitRepository
      }
      if values.isRegularFile == true {
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
        guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
          throw VerificationCommandError.unsafeGitRepository
        }
      } else if values.isDirectory != true {
        throw VerificationCommandError.unsafeGitRepository
      }
    }
    for relativePath in [
      "commondir", "objects/info/alternates", "objects/info/http-alternates",
    ] {
      var metadata = stat()
      let status = lstat(gitDirectory.appendingPathComponent(relativePath).path, &metadata)
      if status == 0 || errno != ENOENT {
        throw VerificationCommandError.unsafeGitRepository
      }
    }
    return gitDirectory
  }

  private func validateGitConfiguration(
    repository: URL,
    approvedHookPath: String?
  ) async throws -> String {
    let gitDirectory = try Self.validateGitRepositoryMetadata(repository: repository)
    let environment = try CredentiallessEnvironment.make(
      developerDirectory: developerDirectory,
      homeDirectory: homeDirectory,
      temporaryDirectory: temporaryDirectory
    )
    let result = try await process.run(
      GitProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: [
          "config", "--file", gitDirectory.appendingPathComponent("config").path,
          "--no-includes", "--null", "--list",
        ],
        workingDirectory: repository,
        environment: environment,
        timeoutSeconds: 30,
        maximumOutputBytes: 1_048_576
      ))
    guard result.succeeded else {
      throw VerificationCommandError.unsafeGitConfiguration
    }
    return try Self.validateGitConfigurationData(
      result.stdout,
      repository: repository,
      approvedHookPath: approvedHookPath
    )
  }

  static func validateGitConfigurationData(
    _ data: Data,
    repository: URL,
    approvedHookPath: String?
  ) throws -> String {
    guard let output = String(data: data, encoding: .utf8) else {
      throw VerificationCommandError.unsafeGitConfiguration
    }
    let records = output.split(separator: "\u{0}", omittingEmptySubsequences: true)
    var observedHookPath: String?
    for record in records {
      let value = String(record)
      guard let separator = value.firstIndex(of: "\n") else {
        throw VerificationCommandError.unsafeGitConfiguration
      }
      let key = String(value[..<separator]).lowercased()
      let setting = String(value[value.index(after: separator)...])
      if key == "core.hookspath" {
        guard let approvedHookPath, setting == approvedHookPath,
          Self.validRelativePath(setting)
        else {
          throw VerificationCommandError.unsafeGitConfiguration
        }
        let hookDirectory = repository.appendingPathComponent(setting, isDirectory: true)
        try Self.validateContained(hookDirectory, root: repository)
        let values = try hookDirectory.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw VerificationCommandError.unsafeGitConfiguration
        }
        observedHookPath = setting
        continue
      }
      guard Self.safeGitSetting(key: key, value: setting, repository: repository) else {
        throw VerificationCommandError.unsafeGitConfiguration
      }
    }
    guard observedHookPath == approvedHookPath else {
      throw VerificationCommandError.unsafeGitConfiguration
    }
    return Self.sha256(data)
  }

  private static func safeGitSetting(
    key: String,
    value: String,
    repository: URL
  ) -> Bool {
    switch key {
    case "core.repositoryformatversion": return value == "0"
    case "core.filemode", "core.ignorecase", "core.precomposeunicode":
      return value == "true" || value == "false"
    case "core.bare": return value == "false"
    case "core.logallrefupdates": return value == "true"
    case "user.name": return value == "Jidoka Code"
    case "user.email": return value == "jidoka-code@invalid.example"
    case "commit.gpgsign": return value == "false"
    case "remote.origin.url":
      guard value.hasPrefix("/") else { return false }
      let url = URL(fileURLWithPath: value).standardizedFileURL
      return url.path != repository.path
    case "remote.origin.fetch":
      return value == "+refs/heads/*:refs/remotes/origin/*"
    default:
      if key.hasPrefix("branch.") {
        return (key.hasSuffix(".remote") && value == "origin")
          || (key.hasSuffix(".merge") && value.hasPrefix("refs/heads/"))
      }
      if key.hasPrefix("submodule."), key.hasSuffix(".url") {
        return value.hasPrefix("/")
      }
      return false
    }
  }

  static func validateDefinition(_ command: ApprovedCommand) throws {
    if let hookPath = command.approvedHookPath, !validRelativePath(hookPath) {
      throw VerificationCommandError.invalidPlan
    }
    guard validIdentifier(command.id), GitHubInputValidation.validSHA256(command.definitionDigest),
      (1...3_600).contains(command.timeoutSeconds),
      !command.rationale.isEmpty, command.rationale.utf8.count <= 2_000,
      validRelativeDirectory(command.workingDirectory),
      command.arguments.count <= 256,
      command.environmentOverrides.allSatisfy({ key, value in
        allowedEnvironmentKeys.contains(key) && !value.contains("\u{0}")
          && value.utf8.count <= 4_096
      })
    else {
      throw VerificationCommandError.invalidPlan
    }
    switch command.registryKind {
    case .makeTargets:
      guard command.executableOrRepositoryScript == "make",
        !command.arguments.isEmpty,
        command.arguments.allSatisfy(validMakeTarget),
        command.sourceDigest == nil,
        command.approvedHookPath == nil
      else {
        throw VerificationCommandError.invalidCommandShape
      }
    case .swiftBuildTest:
      guard command.executableOrRepositoryScript == "swift",
        command.sourceDigest == nil,
        command.approvedHookPath == nil
      else {
        throw VerificationCommandError.invalidCommandShape
      }
      try validateSwiftArguments(command.arguments)
    case .xcodebuildBuildTest:
      guard command.executableOrRepositoryScript == "xcodebuild",
        command.sourceDigest == nil,
        command.approvedHookPath == nil
      else {
        throw VerificationCommandError.invalidCommandShape
      }
      try validateXcodebuildArguments(command.arguments)
    case .repositoryScript:
      guard validRelativePath(command.executableOrRepositoryScript),
        let sourceDigest = command.sourceDigest,
        GitHubInputValidation.validSHA256(sourceDigest),
        command.approvedHookPath == nil
      else {
        throw VerificationCommandError.unsafeRepositoryScript
      }
      try validateOpaqueArguments(command.arguments)
    case .gitRead:
      guard command.executableOrRepositoryScript == "git",
        command.workingDirectory == ".",
        command.sourceDigest == nil,
        command.approvedHookPath == nil
      else {
        throw VerificationCommandError.invalidCommandShape
      }
      try validateGitRead(command.arguments)
    case .gitStage:
      guard command.executableOrRepositoryScript == "git",
        command.workingDirectory == ".",
        command.sourceDigest == nil,
        command.approvedHookPath == nil,
        !command.arguments.isEmpty,
        command.arguments.allSatisfy(validRelativePath)
      else {
        throw VerificationCommandError.invalidCommandShape
      }
    case .gitCommit:
      guard command.executableOrRepositoryScript == "git",
        command.workingDirectory == ".",
        command.sourceDigest == nil,
        command.arguments.count == 1,
        validCommitMessage(command.arguments[0])
      else {
        throw VerificationCommandError.invalidCommandShape
      }
    }
  }

  private static func validateSwiftArguments(_ arguments: [String]) throws {
    guard let verb = arguments.first, ["build", "test"].contains(verb) else {
      throw VerificationCommandError.invalidCommandShape
    }
    let optionsWithValue = Set(["--configuration", "--product", "--target", "--filter"])
    let flags = Set(["--enable-code-coverage", "--parallel"])
    var index = 1
    while index < arguments.count {
      let value = arguments[index]
      if flags.contains(value) {
        index += 1
      } else if optionsWithValue.contains(value), index + 1 < arguments.count,
        validOptionValue(arguments[index + 1])
      {
        index += 2
      } else {
        throw VerificationCommandError.forbiddenArgument
      }
    }
  }

  private static func validateXcodebuildArguments(_ arguments: [String]) throws {
    guard arguments.contains(where: { $0 == "build" || $0 == "test" }),
      !arguments.contains(where: forbiddenSystemArgument)
    else {
      throw VerificationCommandError.invalidCommandShape
    }
    let valueOptions = Set([
      "-scheme", "-destination", "-configuration", "-project", "-workspace",
      "-derivedDataPath",
    ])
    let pathOptions = Set(["-project", "-workspace", "-derivedDataPath"])
    var index = 0
    var actionCount = 0
    while index < arguments.count {
      let value = arguments[index]
      if value == "build" || value == "test" {
        actionCount += 1
        index += 1
      } else if valueOptions.contains(value), index + 1 < arguments.count,
        validOptionValue(arguments[index + 1]),
        !pathOptions.contains(value) || validRelativePath(arguments[index + 1])
      {
        index += 2
      } else {
        throw VerificationCommandError.forbiddenArgument
      }
    }
    guard actionCount == 1 else { throw VerificationCommandError.invalidCommandShape }
  }

  private static func validateGitRead(_ arguments: [String]) throws {
    guard let verb = arguments.first,
      ["status", "diff", "log", "show", "rev-parse", "merge-base"].contains(verb),
      !arguments.contains(where: forbiddenSystemArgument)
    else {
      throw VerificationCommandError.forbiddenArgument
    }
    let exactOptions: Set<String>
    switch verb {
    case "status":
      exactOptions = ["--short", "--porcelain", "--porcelain=v1", "--porcelain=v2"]
    case "diff":
      exactOptions = [
        "--stat", "--name-only", "--name-status", "--no-ext-diff", "--no-textconv",
      ]
    case "log", "show":
      exactOptions = [
        "--stat", "--name-only", "--name-status", "--oneline", "--no-patch",
        "--no-ext-diff", "--no-textconv",
      ]
    case "rev-parse":
      exactOptions = ["--verify", "--short"]
    case "merge-base":
      exactOptions = ["--is-ancestor"]
    default:
      throw VerificationCommandError.forbiddenArgument
    }
    var afterSeparator = false
    for value in arguments.dropFirst() {
      if afterSeparator { continue }
      if value == "--" {
        afterSeparator = true
      } else if value.hasPrefix("-") {
        let validShortValue: Bool
        if verb == "rev-parse", value.hasPrefix("--short="),
          let length = Int(value.dropFirst("--short=".count))
        {
          validShortValue = (1...40).contains(length)
        } else {
          validShortValue = false
        }
        guard exactOptions.contains(value) || validShortValue else {
          throw VerificationCommandError.forbiddenArgument
        }
      }
    }
    try validateOpaqueArguments(Array(arguments.dropFirst()))
  }

  private static func validateOpaqueArguments(_ arguments: [String]) throws {
    guard arguments.count <= 256,
      arguments.allSatisfy({ !$0.contains("\u{0}") && $0.utf8.count <= 4_096 }),
      !arguments.contains(where: forbiddenSystemArgument)
    else {
      throw VerificationCommandError.forbiddenArgument
    }
  }

  private static func forbiddenSystemArgument(_ value: String) -> Bool {
    let lowered = value.lowercased()
    let exact = Set([
      "-c", "--config", "--config-env", "--no-verify", "remote", "fetch", "push",
      "merge", "tag", "worktree", "config", "sh", "bash", "zsh", "env", "xargs",
      "osascript", "open", "curl", "ssh", "gh",
    ])
    return exact.contains(lowered)
  }

  private static func validMakeTarget(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 100 && !value.hasPrefix("-")
      && !value.contains("=")
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || [45, 46, 58, 95].contains(byte)
      }
  }

  private static func validCommitMessage(_ value: String) -> Bool {
    guard value.utf8.count <= 200, !value.contains("\n"), !value.contains("\r"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let separator = value.firstIndex(of: ":")
    else {
      return false
    }
    let prefix = value[..<separator]
    if let opening = prefix.firstIndex(of: "(") {
      let scopeStart = prefix.index(after: opening)
      let scopeEnd = prefix.index(before: prefix.endIndex)
      guard prefix.last == ")", opening != prefix.startIndex,
        scopeStart < scopeEnd,
        prefix[scopeStart..<scopeEnd]
          .allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
      else {
        return false
      }
    } else if prefix.contains(")") {
      return false
    }
    let subject = value[value.index(after: separator)...]
      .trimmingCharacters(in: .whitespaces)
    let allowedTypes = [
      "feat", "fix", "docs", "refactor", "perf", "test", "build", "ci", "chore", "revert",
    ]
    let type = prefix.split(separator: "(", maxSplits: 1).first.map(String.init) ?? ""
    return allowedTypes.contains(type) && !subject.isEmpty && !subject.hasSuffix(".")
  }

  private static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 100
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || [45, 46, 95].contains(byte)
      }
  }

  private static func validOptionValue(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("-") && !value.contains("\u{0}")
      && value.utf8.count <= 1_024
  }

  private static func validRelativeDirectory(_ value: String) -> Bool {
    value == "." || validRelativePath(value)
  }

  private static func validRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/"),
      value.utf8.count <= 1_024, !value.contains("\u{0}"), !value.contains("//")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      let lowered = $0.lowercased()
      return !$0.isEmpty && $0 != "." && $0 != ".."
        && lowered != ".git" && lowered != ".pi" && lowered != ".agents"
    }
  }

  private static func resolveDirectory(
    _ relativePath: String,
    workspace: URL
  ) throws -> URL {
    let values = try workspace.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard workspace.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else {
      throw VerificationCommandError.invalidWorkingDirectory
    }
    let candidate =
      relativePath == "."
      ? workspace : workspace.appendingPathComponent(relativePath, isDirectory: true)
    try validateContained(candidate, root: workspace)
    let candidateValues = try candidate.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard candidateValues.isDirectory == true, candidateValues.isSymbolicLink != true,
      candidate.resolvingSymlinksInPath().standardizedFileURL.path
        == candidate.standardizedFileURL.path
    else {
      throw VerificationCommandError.invalidWorkingDirectory
    }
    return candidate
  }

  private static func validateContained(_ value: URL, root: URL) throws {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalValue = value.resolvingSymlinksInPath().standardizedFileURL.path
    guard canonicalValue == canonicalRoot || canonicalValue.hasPrefix(canonicalRoot + "/") else {
      throw VerificationCommandError.invalidWorkingDirectory
    }
  }

  private static func redactedExcerpt(_ data: Data) -> String {
    let prefix = data.prefix(4_096)
    var value = String(decoding: prefix, as: UTF8.self)
    let patterns = ["ghp_", "github_pat_", "Bearer ", "sk-"]
    for pattern in patterns {
      while let range = value.range(of: pattern, options: [.caseInsensitive]) {
        let tail = value[range.lowerBound...]
        let end = tail.firstIndex(where: { $0.isWhitespace }) ?? value.endIndex
        value.replaceSubrange(range.lowerBound..<end, with: "[REDACTED]")
      }
    }
    return value
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static let allowedEnvironmentKeys = Set([
    "CI", "LANG", "LC_ALL", "SWIFT_DETERMINISTIC_HASHING",
  ])
}
