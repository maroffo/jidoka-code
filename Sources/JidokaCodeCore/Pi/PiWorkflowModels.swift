import Foundation

public enum PiWorkflowFindingSeverity: String, CaseIterable, Codable, Sendable {
  case critical
  case major
  case minor
  case info
}

public enum PiWorkflowReportSeverity: String, CaseIterable, Codable, Sendable {
  case none
  case info
  case minor
  case major
  case critical

  public var rank: Int {
    switch self {
    case .none: 0
    case .info: 1
    case .minor: 2
    case .major: 3
    case .critical: 4
    }
  }
}

public struct PiWorkflowFinding: Codable, Equatable, Sendable {
  public let severity: PiWorkflowFindingSeverity
  public let path: String
  public let line: Int
  public let evidence: String
  public let recommendation: String

  public init(
    severity: PiWorkflowFindingSeverity,
    path: String,
    line: Int,
    evidence: String,
    recommendation: String
  ) {
    self.severity = severity
    self.path = path
    self.line = line
    self.evidence = evidence
    self.recommendation = recommendation
  }
}

public enum WorkComplexity: String, CaseIterable, Codable, Comparable, Sendable {
  case simple
  case moderate
  case complex
  case humanOwned
  case unknown

  public var rank: Int {
    switch self {
    case .simple: 0
    case .moderate: 1
    case .complex, .unknown: 2
    case .humanOwned: 3
    }
  }

  public static func < (lhs: WorkComplexity, rhs: WorkComplexity) -> Bool {
    lhs.rank < rhs.rank
  }
}

public struct ComplexityFacts: Codable, Equatable, Sendable {
  public let workstreamCount: Int
  public let publicAPI: Bool
  public let nonDestructiveSchema: Bool
  public let crossModuleConcurrency: Bool
  public let operationalRollback: Bool
  public let designAlternatives: Bool
  public let humanDecisionGap: Bool
  public let securityOrSecretCore: Bool
  public let dataLossMigration: Bool
  public let releaseOrTag: Bool
  public let infrastructureBlastRadius: Bool
  public let crossRepositoryCoordination: Bool
  public let unresolvedDesignDebate: Bool
  public let unverifiable: Bool

  public init(
    workstreamCount: Int,
    publicAPI: Bool,
    nonDestructiveSchema: Bool,
    crossModuleConcurrency: Bool,
    operationalRollback: Bool,
    designAlternatives: Bool,
    humanDecisionGap: Bool,
    securityOrSecretCore: Bool,
    dataLossMigration: Bool,
    releaseOrTag: Bool,
    infrastructureBlastRadius: Bool,
    crossRepositoryCoordination: Bool,
    unresolvedDesignDebate: Bool,
    unverifiable: Bool
  ) {
    self.workstreamCount = workstreamCount
    self.publicAPI = publicAPI
    self.nonDestructiveSchema = nonDestructiveSchema
    self.crossModuleConcurrency = crossModuleConcurrency
    self.operationalRollback = operationalRollback
    self.designAlternatives = designAlternatives
    self.humanDecisionGap = humanDecisionGap
    self.securityOrSecretCore = securityOrSecretCore
    self.dataLossMigration = dataLossMigration
    self.releaseOrTag = releaseOrTag
    self.infrastructureBlastRadius = infrastructureBlastRadius
    self.crossRepositoryCoordination = crossRepositoryCoordination
    self.unresolvedDesignDebate = unresolvedDesignDebate
    self.unverifiable = unverifiable
  }
}

public enum TriageHardRiskFlag: String, CaseIterable, Codable, Sendable {
  case securityOrSecretCore = "security-or-secret-core"
  case dataLossMigration = "data-loss-migration"
  case releaseOrTag = "release-or-tag"
  case infrastructureBlastRadius = "infrastructure-blast-radius"
  case crossRepositoryCoordination = "cross-repository-coordination"
  case unresolvedDesignDebate = "unresolved-design-debate"
  case unverifiable
}

public struct PiPRReviewPayload: Codable, Equatable, Sendable {
  public let verdict: String
  public let severity: PiWorkflowReportSeverity
  public let summary: String
  public let domain: PiWorkflowRole
  public let commitNarrativeSHA256: String
  public let evidence: [String]
  public let findings: [PiWorkflowFinding]
}

public struct PiTriageRubric: Codable, Equatable, Sendable {
  public let specified: String
  public let testable: String
  public let bounded: String
  public let safe: String
}

public struct PiIssueTriagePayload: Codable, Equatable, Sendable {
  public let verdict: String
  public let severity: PiWorkflowReportSeverity
  public let summary: String
  public let rubric: PiTriageRubric
  public let hardRiskFlags: [TriageHardRiskFlag]
  public let rationale: String
  public let questions: [String]
  public let complexityGuess: WorkComplexity
}

public struct ApprovedCommandProposal: Codable, Equatable, Sendable {
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
    approvedHookPath: String?
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
  }
}

public struct PiPlanningPayload: Codable, Equatable, Sendable {
  public let verdict: String
  public let severity: PiWorkflowReportSeverity
  public let summary: String
  public let proposedComplexity: WorkComplexity
  public let classifierFacts: ComplexityFacts
  public let evidence: [String]
  public let findings: [PiWorkflowFinding]
  public let commandDefinitions: [ApprovedCommandProposal]
  public let approvedCommandDigests: [String]
  public let approvedPlanDigest: String?
  public let planMarkdown: String
}

public struct PiOrchestrationPayload: Codable, Equatable, Sendable {
  public let verdict: String
  public let severity: PiWorkflowReportSeverity
  public let summary: String
  public let evidence: [String]
  public let findings: [PiWorkflowFinding]
  public let changedPaths: [String]
  public let requestedCommandIDs: [String]
}

public enum PiWorkflowPayload: Codable, Equatable, Sendable {
  case pullRequestReview(PiPRReviewPayload)
  case issueTriage(PiIssueTriagePayload)
  case planning(PiPlanningPayload)
  case orchestration(PiOrchestrationPayload)
}

public struct PiWorkflowRoleResult: Codable, Equatable, Sendable {
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let artifactSHA256: String
  public let approvedCommandIDs: [String]
  public let payload: PiWorkflowPayload
  public let recordSHA256: String

  public init(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    artifactSHA256: String,
    approvedCommandIDs: [String],
    payload: PiWorkflowPayload,
    recordSHA256: String
  ) {
    self.workflow = workflow
    self.role = role
    self.artifactSHA256 = artifactSHA256
    self.approvedCommandIDs = approvedCommandIDs
    self.payload = payload
    self.recordSHA256 = recordSHA256
  }
}

public enum PiWorkflowResultError: Error, Equatable, Sendable {
  case invalidIdentity
  case invalidPayload
  case invalidFinding
  case invalidClassifier
  case invalidCommandDefinition
  case invalidHardRisk
}

public enum PiWorkflowResultDecoder {
  public static func decode(_ result: PiRPCTerminalResult) throws -> PiWorkflowRoleResult {
    guard let workflow = PiWorkflowKind(rawValue: result.workflow),
      let role = PiWorkflowRole(rawValue: result.role),
      PiWorkflowResourceCatalog.valid(role: role, for: workflow),
      GitHubInputValidation.validSHA256(result.artifactSHA256)
    else {
      throw PiWorkflowResultError.invalidIdentity
    }
    let payload: PiWorkflowPayload
    switch workflow {
    case .pullRequestReview:
      payload = .pullRequestReview(try decodePR(result.payload, role: role))
    case .issueTriage:
      payload = .issueTriage(try decodeTriage(result.payload))
    case .planning:
      payload = .planning(try decodePlanning(result.payload))
    case .orchestration:
      let orchestration = try decodeOrchestration(result.payload)
      guard orchestration.requestedCommandIDs == result.approvedCommandIDs else {
        throw PiWorkflowResultError.invalidPayload
      }
      payload = .orchestration(orchestration)
    }
    return PiWorkflowRoleResult(
      workflow: workflow,
      role: role,
      artifactSHA256: result.artifactSHA256,
      approvedCommandIDs: result.approvedCommandIDs,
      payload: payload,
      recordSHA256: result.recordSHA256
    )
  }

  private static func decodePR(
    _ object: [String: PiJSONValue],
    role: PiWorkflowRole
  ) throws -> PiPRReviewPayload {
    try requireKeys(
      object,
      [
        "commitNarrativeSHA256", "domain", "evidence", "findings", "severity", "summary",
        "verdict",
      ]
    )
    guard let verdict = string(object, "verdict"), ["pass", "block"].contains(verdict),
      let severity = severity(object),
      let summary = boundedString(object, "summary", maximum: 2_000),
      let domainValue = string(object, "domain"),
      let domain = PiWorkflowRole(rawValue: domainValue),
      domain == role,
      [.architecture, .security, .test, .synthesis].contains(domain),
      let narrativeDigest = string(object, "commitNarrativeSHA256"),
      GitHubInputValidation.validSHA256(narrativeDigest)
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    return PiPRReviewPayload(
      verdict: verdict,
      severity: severity,
      summary: summary,
      domain: domain,
      commitNarrativeSHA256: narrativeDigest,
      evidence: try stringArray(object, "evidence", maximumItems: 128),
      findings: try findings(object)
    )
  }

  private static func decodeTriage(
    _ object: [String: PiJSONValue]
  ) throws -> PiIssueTriagePayload {
    try requireKeys(
      object,
      [
        "complexityGuess", "hardRiskFlags", "questions", "rationale", "rubric", "severity",
        "summary", "verdict",
      ]
    )
    guard let verdict = string(object, "verdict"),
      ["ready", "needs-spec", "human"].contains(verdict),
      let severity = severity(object),
      let summary = boundedString(object, "summary", maximum: 2_000),
      let rationale = boundedString(object, "rationale", maximum: 8_000),
      let complexityValue = string(object, "complexityGuess"),
      let complexity = WorkComplexity(rawValue: complexityValue),
      let rubricObject = object["rubric"]?.objectValue
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    try requireKeys(rubricObject, ["bounded", "safe", "specified", "testable"])
    guard let specified = boundedString(rubricObject, "specified", maximum: 2_000),
      let testable = boundedString(rubricObject, "testable", maximum: 2_000),
      let bounded = boundedString(rubricObject, "bounded", maximum: 2_000),
      let safe = boundedString(rubricObject, "safe", maximum: 2_000)
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    let rawFlags = try stringArray(object, "hardRiskFlags", maximumItems: 32)
    let flags = try rawFlags.map { value in
      guard let flag = TriageHardRiskFlag(rawValue: value) else {
        throw PiWorkflowResultError.invalidHardRisk
      }
      return flag
    }
    return PiIssueTriagePayload(
      verdict: verdict,
      severity: severity,
      summary: summary,
      rubric: PiTriageRubric(
        specified: specified,
        testable: testable,
        bounded: bounded,
        safe: safe
      ),
      hardRiskFlags: flags,
      rationale: rationale,
      questions: try stringArray(object, "questions", maximumItems: 20),
      complexityGuess: complexity
    )
  }

  private static func decodePlanning(
    _ object: [String: PiJSONValue]
  ) throws -> PiPlanningPayload {
    try requireKeys(
      object,
      [
        "approvedCommandDigests", "approvedPlanDigest", "classifierFacts", "commandDefinitions",
        "evidence", "findings", "planMarkdown", "proposedComplexity", "severity", "summary",
        "verdict",
      ]
    )
    guard let verdict = string(object, "verdict"),
      ["pass", "revise", "escalate"].contains(verdict),
      let severity = severity(object),
      let summary = boundedString(object, "summary", maximum: 2_000),
      let complexityValue = string(object, "proposedComplexity"),
      let complexity = WorkComplexity(rawValue: complexityValue),
      let factsObject = object["classifierFacts"]?.objectValue,
      let planMarkdown = string(object, "planMarkdown"),
      planMarkdown.utf8.count <= 262_144
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    let commandValues = try array(object, "commandDefinitions", maximumItems: 64)
    let commands = try commandValues.map { value in
      guard let definition = value.objectValue else {
        throw PiWorkflowResultError.invalidCommandDefinition
      }
      return try decodeCommand(definition)
    }
    let approvedDigests = try stringArray(
      object,
      "approvedCommandDigests",
      maximumItems: 64
    )
    let approvedPlanDigest = try optionalString(object, "approvedPlanDigest")
    guard approvedDigests.allSatisfy(GitHubInputValidation.validSHA256),
      approvedPlanDigest.map(GitHubInputValidation.validSHA256) ?? true
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    return PiPlanningPayload(
      verdict: verdict,
      severity: severity,
      summary: summary,
      proposedComplexity: complexity,
      classifierFacts: try decodeFacts(factsObject),
      evidence: try stringArray(object, "evidence", maximumItems: 128),
      findings: try findings(object),
      commandDefinitions: commands,
      approvedCommandDigests: approvedDigests,
      approvedPlanDigest: approvedPlanDigest,
      planMarkdown: planMarkdown
    )
  }

  private static func decodeOrchestration(
    _ object: [String: PiJSONValue]
  ) throws -> PiOrchestrationPayload {
    try requireKeys(
      object,
      [
        "changedPaths", "evidence", "findings", "requestedCommandIDs", "severity", "summary",
        "verdict",
      ]
    )
    guard let verdict = string(object, "verdict"),
      ["pass", "revise", "block"].contains(verdict),
      let severity = severity(object),
      let summary = boundedString(object, "summary", maximum: 2_000)
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    let changedPaths = try stringArray(object, "changedPaths", maximumItems: 256)
    guard changedPaths.allSatisfy(validRelativePath) else {
      throw PiWorkflowResultError.invalidPayload
    }
    let commandIDs = try stringArray(object, "requestedCommandIDs", maximumItems: 64)
    guard commandIDs.allSatisfy(validIdentifier) else {
      throw PiWorkflowResultError.invalidPayload
    }
    return PiOrchestrationPayload(
      verdict: verdict,
      severity: severity,
      summary: summary,
      evidence: try stringArray(object, "evidence", maximumItems: 128),
      findings: try findings(object),
      changedPaths: changedPaths,
      requestedCommandIDs: commandIDs
    )
  }

  private static func decodeFacts(_ object: [String: PiJSONValue]) throws -> ComplexityFacts {
    let keys: Set<String> = [
      "crossModuleConcurrency", "crossRepositoryCoordination", "dataLossMigration",
      "designAlternatives", "humanDecisionGap", "infrastructureBlastRadius",
      "nonDestructiveSchema", "operationalRollback", "publicAPI", "releaseOrTag",
      "securityOrSecretCore", "unresolvedDesignDebate", "unverifiable", "workstreamCount",
    ]
    try requireKeys(object, keys)
    guard let countValue = object["workstreamCount"]?.integerValue,
      (1...100).contains(countValue),
      let count = Int(exactly: countValue)
    else {
      throw PiWorkflowResultError.invalidClassifier
    }
    func flag(_ key: String) throws -> Bool {
      guard let value = object[key]?.boolValue else {
        throw PiWorkflowResultError.invalidClassifier
      }
      return value
    }
    return try ComplexityFacts(
      workstreamCount: count,
      publicAPI: flag("publicAPI"),
      nonDestructiveSchema: flag("nonDestructiveSchema"),
      crossModuleConcurrency: flag("crossModuleConcurrency"),
      operationalRollback: flag("operationalRollback"),
      designAlternatives: flag("designAlternatives"),
      humanDecisionGap: flag("humanDecisionGap"),
      securityOrSecretCore: flag("securityOrSecretCore"),
      dataLossMigration: flag("dataLossMigration"),
      releaseOrTag: flag("releaseOrTag"),
      infrastructureBlastRadius: flag("infrastructureBlastRadius"),
      crossRepositoryCoordination: flag("crossRepositoryCoordination"),
      unresolvedDesignDebate: flag("unresolvedDesignDebate"),
      unverifiable: flag("unverifiable")
    )
  }

  private static func decodeCommand(
    _ object: [String: PiJSONValue]
  ) throws -> ApprovedCommandProposal {
    try requireKeys(
      object,
      [
        "approvedHookPath", "arguments", "environmentOverrides", "executableOrRepositoryScript",
        "id", "rationale", "registryKind", "sourceDigest", "timeoutSeconds",
        "workingDirectory",
      ]
    )
    guard let id = string(object, "id"), validIdentifier(id),
      let registryValue = string(object, "registryKind"),
      let registry = ApprovedCommandRegistryKind(rawValue: registryValue),
      let executable = boundedString(object, "executableOrRepositoryScript", maximum: 1_024),
      let workingDirectory = boundedString(object, "workingDirectory", maximum: 1_024),
      let timeoutValue = object["timeoutSeconds"]?.integerValue,
      (1...3_600).contains(timeoutValue),
      let timeout = Int(exactly: timeoutValue),
      let rationale = boundedString(object, "rationale", maximum: 2_000),
      let environmentObject = object["environmentOverrides"]?.objectValue
    else {
      throw PiWorkflowResultError.invalidCommandDefinition
    }
    var environment: [String: String] = [:]
    for (key, value) in environmentObject {
      guard key.wholeMatch(of: /^[A-Z][A-Z0-9_]{0,63}$/) != nil,
        let item = value.stringValue,
        item.utf8.count <= 4_096
      else {
        throw PiWorkflowResultError.invalidCommandDefinition
      }
      environment[key] = item
    }
    let sourceDigest = try optionalString(object, "sourceDigest")
    let hookPath = try optionalString(object, "approvedHookPath")
    if let sourceDigest, !GitHubInputValidation.validSHA256(sourceDigest) {
      throw PiWorkflowResultError.invalidCommandDefinition
    }
    if let hookPath, !validRelativePath(hookPath) {
      throw PiWorkflowResultError.invalidCommandDefinition
    }
    guard workingDirectory == "." || validRelativePath(workingDirectory) else {
      throw PiWorkflowResultError.invalidCommandDefinition
    }
    return ApprovedCommandProposal(
      id: id,
      registryKind: registry,
      executableOrRepositoryScript: executable,
      arguments: try stringArray(object, "arguments", maximumItems: 256, allowEmpty: true),
      workingDirectory: workingDirectory,
      environmentOverrides: environment,
      timeoutSeconds: timeout,
      rationale: rationale,
      sourceDigest: sourceDigest,
      approvedHookPath: hookPath
    )
  }

  private static func findings(
    _ object: [String: PiJSONValue]
  ) throws -> [PiWorkflowFinding] {
    let values = try array(object, "findings", maximumItems: 100)
    return try values.map { value in
      guard let finding = value.objectValue else { throw PiWorkflowResultError.invalidFinding }
      try requireKeys(finding, ["evidence", "line", "path", "recommendation", "severity"])
      guard let severityValue = string(finding, "severity"),
        let severity = PiWorkflowFindingSeverity(rawValue: severityValue),
        let path = string(finding, "path"),
        path.utf8.count <= 1_024,
        let lineValue = finding["line"]?.integerValue,
        lineValue >= 0,
        let line = Int(exactly: lineValue),
        let evidence = boundedString(finding, "evidence", maximum: 4_096),
        let recommendation = boundedString(finding, "recommendation", maximum: 4_096)
      else {
        throw PiWorkflowResultError.invalidFinding
      }
      return PiWorkflowFinding(
        severity: severity,
        path: path,
        line: line,
        evidence: evidence,
        recommendation: recommendation
      )
    }
  }

  private static func severity(
    _ object: [String: PiJSONValue]
  ) -> PiWorkflowReportSeverity? {
    string(object, "severity").flatMap(PiWorkflowReportSeverity.init(rawValue:))
  }

  private static func string(
    _ object: [String: PiJSONValue],
    _ key: String
  ) -> String? {
    object[key]?.stringValue
  }

  private static func boundedString(
    _ object: [String: PiJSONValue],
    _ key: String,
    maximum: Int
  ) -> String? {
    guard let value = string(object, key), !value.isEmpty, value.utf8.count <= maximum else {
      return nil
    }
    return value
  }

  private static func optionalString(
    _ object: [String: PiJSONValue],
    _ key: String
  ) throws -> String? {
    guard let value = object[key] else { throw PiWorkflowResultError.invalidPayload }
    if case .null = value { return nil }
    guard let string = value.stringValue else { throw PiWorkflowResultError.invalidPayload }
    return string
  }

  private static func array(
    _ object: [String: PiJSONValue],
    _ key: String,
    maximumItems: Int
  ) throws -> [PiJSONValue] {
    guard let values = object[key]?.arrayValue, values.count <= maximumItems else {
      throw PiWorkflowResultError.invalidPayload
    }
    return values
  }

  private static func stringArray(
    _ object: [String: PiJSONValue],
    _ key: String,
    maximumItems: Int,
    allowEmpty: Bool = false
  ) throws -> [String] {
    let values = try array(object, key, maximumItems: maximumItems)
    let strings = values.compactMap(\.stringValue)
    guard strings.count == values.count,
      Set(strings).count == strings.count,
      strings.allSatisfy({ value in
        (allowEmpty || !value.isEmpty) && value.utf8.count <= 4_096
      })
    else {
      throw PiWorkflowResultError.invalidPayload
    }
    return strings
  }

  private static func requireKeys(
    _ object: [String: PiJSONValue],
    _ expected: Set<String>
  ) throws {
    guard Set(object.keys) == expected else { throw PiWorkflowResultError.invalidPayload }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    value.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil
  }

  private static func validRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\u{0}")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      let lowered = $0.lowercased()
      return !$0.isEmpty && $0 != "." && $0 != ".."
        && lowered != ".git" && lowered != ".pi" && lowered != ".agents"
    }
  }
}

public enum ApprovedCommandCanonicalizer {
  public static func canonicalize(
    _ proposals: [ApprovedCommandProposal]
  ) throws -> [ApprovedCommand] {
    guard !proposals.isEmpty,
      Set(proposals.map(\.id)).count == proposals.count
    else {
      throw VerificationCommandError.invalidPlan
    }
    return try proposals.map { proposal in
      let digest = ApprovedCommand.digest(
        id: proposal.id,
        registryKind: proposal.registryKind,
        executableOrRepositoryScript: proposal.executableOrRepositoryScript,
        arguments: proposal.arguments,
        workingDirectory: proposal.workingDirectory,
        environmentOverrides: proposal.environmentOverrides,
        timeoutSeconds: proposal.timeoutSeconds,
        rationale: proposal.rationale,
        sourceDigest: proposal.sourceDigest,
        approvedHookPath: proposal.approvedHookPath
      )
      let command = ApprovedCommand(
        id: proposal.id,
        registryKind: proposal.registryKind,
        executableOrRepositoryScript: proposal.executableOrRepositoryScript,
        arguments: proposal.arguments,
        workingDirectory: proposal.workingDirectory,
        environmentOverrides: proposal.environmentOverrides,
        timeoutSeconds: proposal.timeoutSeconds,
        rationale: proposal.rationale,
        sourceDigest: proposal.sourceDigest,
        approvedHookPath: proposal.approvedHookPath,
        definitionDigest: digest
      )
      try VerificationCommandRunner.validateDefinition(command)
      return command
    }
  }

  public static func candidate(
    _ proposals: [ApprovedCommandProposal],
    artifactSHA256: String,
    planMarkdown: String
  ) throws -> FrozenCommandPlan {
    let commands = try canonicalize(proposals)
    return try FrozenCommandPlan(
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
  }
}
