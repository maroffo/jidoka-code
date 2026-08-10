import CryptoKit
import Foundation

public enum PiWorkflowSessionDirective: Equatable, Sendable {
  case fresh
  case resume(String)
  case resumeBounded(sessionID: String, boundarySHA256: String)
}

public struct PiNormalizedRoleResult: Equatable, Sendable {
  public let role: PiWorkflowRole
  public let verdict: String
  public let severity: PiWorkflowReportSeverity
  public let summary: String
  public let findings: [PiWorkflowFinding]
  public let evidence: [String]
  public let proposedComplexity: WorkComplexity?
  public let classifierFacts: ComplexityFacts?
  public let approvedCommandDigests: [String]
  public let approvedPlanDigest: String?

  public init(
    role: PiWorkflowRole,
    verdict: String,
    severity: PiWorkflowReportSeverity,
    summary: String,
    findings: [PiWorkflowFinding],
    evidence: [String],
    proposedComplexity: WorkComplexity?,
    classifierFacts: ComplexityFacts?,
    approvedCommandDigests: [String],
    approvedPlanDigest: String?
  ) {
    self.role = role
    self.verdict = verdict
    self.severity = severity
    self.summary = summary
    self.findings = findings
    self.evidence = evidence
    self.proposedComplexity = proposedComplexity
    self.classifierFacts = classifierFacts
    self.approvedCommandDigests = approvedCommandDigests
    self.approvedPlanDigest = approvedPlanDigest
  }

  public static func make(from result: PiWorkflowRoleResult) -> Self {
    switch result.payload {
    case .pullRequestReview(let payload):
      return PiNormalizedRoleResult(
        role: result.role,
        verdict: payload.verdict,
        severity: payload.severity,
        summary: payload.summary,
        findings: payload.findings,
        evidence: payload.evidence,
        proposedComplexity: nil,
        classifierFacts: nil,
        approvedCommandDigests: [],
        approvedPlanDigest: nil
      )
    case .issueTriage(let payload):
      return PiNormalizedRoleResult(
        role: result.role,
        verdict: payload.verdict,
        severity: payload.severity,
        summary: payload.summary,
        findings: [],
        evidence: [payload.rationale],
        proposedComplexity: payload.complexityGuess,
        classifierFacts: nil,
        approvedCommandDigests: [],
        approvedPlanDigest: nil
      )
    case .planning(let payload):
      return PiNormalizedRoleResult(
        role: result.role,
        verdict: payload.verdict,
        severity: payload.severity,
        summary: payload.summary,
        findings: payload.findings,
        evidence: payload.evidence,
        proposedComplexity: payload.proposedComplexity,
        classifierFacts: payload.classifierFacts,
        approvedCommandDigests: payload.approvedCommandDigests,
        approvedPlanDigest: payload.approvedPlanDigest
      )
    case .orchestration(let payload):
      return PiNormalizedRoleResult(
        role: result.role,
        verdict: payload.verdict,
        severity: payload.severity,
        summary: payload.summary,
        findings: payload.findings,
        evidence: payload.evidence,
        proposedComplexity: nil,
        classifierFacts: nil,
        approvedCommandDigests: [],
        approvedPlanDigest: nil
      )
    }
  }
}

public struct PiWorkflowExecutionRequest: Equatable, Sendable {
  public let jobID: String
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let round: Int
  public let artifactSHA256: String
  public let sessionDirective: PiWorkflowSessionDirective
  public let normalizedRoleInputs: [PiNormalizedRoleResult]
  public let canonicalCommandDigests: [String]
  public let frozenPlan: FrozenCommandPlan?
  public let commandEvidence: [VerificationCommandEvidence]
  public let engineFailures: [String]

  public init(
    jobID: String,
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    round: Int,
    artifactSHA256: String,
    sessionDirective: PiWorkflowSessionDirective,
    normalizedRoleInputs: [PiNormalizedRoleResult] = [],
    canonicalCommandDigests: [String] = [],
    frozenPlan: FrozenCommandPlan? = nil,
    commandEvidence: [VerificationCommandEvidence] = [],
    engineFailures: [String] = []
  ) {
    self.jobID = jobID
    self.workflow = workflow
    self.role = role
    self.round = round
    self.artifactSHA256 = artifactSHA256
    self.sessionDirective = sessionDirective
    self.normalizedRoleInputs = normalizedRoleInputs
    self.canonicalCommandDigests = canonicalCommandDigests
    self.frozenPlan = frozenPlan
    self.commandEvidence = commandEvidence
    self.engineFailures = engineFailures
  }
}

public struct PiWorkflowExecution: Equatable, Sendable {
  public let sessionID: String
  public let sessionBoundarySHA256: String?
  public let result: PiWorkflowRoleResult
  public let agentSettledCount: Int
  public let extensionErrorCount: Int

  public init(
    sessionID: String,
    sessionBoundarySHA256: String? = nil,
    result: PiWorkflowRoleResult,
    agentSettledCount: Int = 1,
    extensionErrorCount: Int = 0
  ) {
    self.sessionID = sessionID
    self.sessionBoundarySHA256 = sessionBoundarySHA256
    self.result = result
    self.agentSettledCount = agentSettledCount
    self.extensionErrorCount = extensionErrorCount
  }
}

public protocol PiWorkflowExecuting: Sendable {
  func execute(_ request: PiWorkflowExecutionRequest) async throws -> PiWorkflowExecution
}

public protocol PiApprovedCommandExecuting: Sendable {
  func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan,
    round: Int
  ) async throws -> VerificationCommandEvidence
}

public enum PiWorkflowRouterError: Error, Equatable, Sendable {
  case invalidInput
  case headMismatch
  case invalidCommitNarrative
  case invalidExecutionIdentity
  case missingSettledEvidence
  case extensionFailure
  case reusedFreshSession
  case wrongWriterSession
  case unexpectedPayload
  case narrativeDigestMismatch
  case commandDefinitionInvalid
  case commandEvidenceMismatch
  case executorFailure
}

public struct PiCommitNarrativeEntry: Equatable, Sendable {
  public let ordinal: Int
  public let sha: String
  public let parentSHAs: [String]
  public let subject: String
  public let patchSHA256: String

  public init(
    ordinal: Int,
    sha: String,
    parentSHAs: [String],
    subject: String,
    patchSHA256: String
  ) {
    self.ordinal = ordinal
    self.sha = sha
    self.parentSHAs = parentSHAs
    self.subject = subject
    self.patchSHA256 = patchSHA256
  }
}

public struct PiPullRequestReviewInput: Equatable, Sendable {
  public let jobID: String
  public let artifactSHA256: String
  public let baseSHA: String
  public let restHeadSHA: String
  public let fetchedHeadSHA: String
  public let restCommitSHAs: [String]
  public let fetchedCommitSHAs: [String]
  public let commits: [PiCommitNarrativeEntry]

  public init(
    jobID: String,
    artifactSHA256: String,
    baseSHA: String,
    restHeadSHA: String,
    fetchedHeadSHA: String,
    restCommitSHAs: [String],
    fetchedCommitSHAs: [String],
    commits: [PiCommitNarrativeEntry]
  ) {
    self.jobID = jobID
    self.artifactSHA256 = artifactSHA256
    self.baseSHA = baseSHA
    self.restHeadSHA = restHeadSHA
    self.fetchedHeadSHA = fetchedHeadSHA
    self.restCommitSHAs = restCommitSHAs
    self.fetchedCommitSHAs = fetchedCommitSHAs
    self.commits = commits
  }
}

public struct PiPullRequestReviewOutput: Equatable, Sendable {
  public let commitNarrativeSHA256: String
  public let roleResults: [PiWorkflowRoleResult]
  public let synthesis: PiPRReviewPayload
  public let effectiveVerdict: String
  public let effectiveSeverity: PiWorkflowReportSeverity

  public init(
    commitNarrativeSHA256: String,
    roleResults: [PiWorkflowRoleResult],
    synthesis: PiPRReviewPayload,
    effectiveVerdict: String,
    effectiveSeverity: PiWorkflowReportSeverity
  ) {
    self.commitNarrativeSHA256 = commitNarrativeSHA256
    self.roleResults = roleResults
    self.synthesis = synthesis
    self.effectiveVerdict = effectiveVerdict
    self.effectiveSeverity = effectiveSeverity
  }
}

public struct PiPullRequestReviewRouter: Sendable {
  private let executor: any PiWorkflowExecuting

  public init(executor: any PiWorkflowExecuting) {
    self.executor = executor
  }

  public func run(_ input: PiPullRequestReviewInput) async throws -> PiPullRequestReviewOutput {
    try validateCommon(jobID: input.jobID, artifactSHA256: input.artifactSHA256)
    guard GitHubInputValidation.validGitSHA(input.baseSHA),
      GitHubInputValidation.validGitSHA(input.restHeadSHA),
      input.baseSHA != input.restHeadSHA,
      input.restHeadSHA == input.fetchedHeadSHA
    else {
      throw PiWorkflowRouterError.headMismatch
    }
    let narrativeSHAs = input.commits.map(\.sha)
    let narrativeSet = Set(narrativeSHAs)
    guard input.commits.last?.sha == input.fetchedHeadSHA,
      !narrativeSet.contains(input.baseSHA),
      input.restCommitSHAs.count == input.commits.count,
      input.fetchedCommitSHAs.count == input.commits.count,
      Set(input.restCommitSHAs).count == input.restCommitSHAs.count,
      Set(input.fetchedCommitSHAs).count == input.fetchedCommitSHAs.count,
      input.restCommitSHAs.allSatisfy(GitHubInputValidation.validGitSHA),
      input.fetchedCommitSHAs.allSatisfy(GitHubInputValidation.validGitSHA),
      input.restCommitSHAs.last == input.restHeadSHA,
      input.fetchedCommitSHAs.last == input.fetchedHeadSHA,
      Set(input.restCommitSHAs) == narrativeSet,
      Set(input.fetchedCommitSHAs) == narrativeSet
    else {
      throw PiWorkflowRouterError.invalidCommitNarrative
    }
    let narrativeDigest = try Self.commitNarrativeDigest(
      input.commits,
      baseSHA: input.baseSHA
    )
    var sessions: Set<String> = []
    var results: [PiWorkflowRoleResult] = []
    for role in [PiWorkflowRole.architecture, .security, .test] {
      let execution = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: input.jobID,
          workflow: .pullRequestReview,
          role: role,
          round: 1,
          artifactSHA256: input.artifactSHA256,
          sessionDirective: .fresh
        )
      )
      let result = try validateExecution(
        execution,
        workflow: .pullRequestReview,
        role: role,
        artifactSHA256: input.artifactSHA256,
        directive: .fresh,
        sessions: &sessions
      )
      guard case .pullRequestReview(let payload) = result.payload,
        payload.commitNarrativeSHA256 == narrativeDigest
      else {
        throw PiWorkflowRouterError.narrativeDigestMismatch
      }
      results.append(result)
    }
    let synthesisExecution = try await executor.execute(
      PiWorkflowExecutionRequest(
        jobID: input.jobID,
        workflow: .pullRequestReview,
        role: .synthesis,
        round: 1,
        artifactSHA256: input.artifactSHA256,
        sessionDirective: .fresh,
        normalizedRoleInputs: results.map(PiNormalizedRoleResult.make)
      )
    )
    let synthesisResult = try validateExecution(
      synthesisExecution,
      workflow: .pullRequestReview,
      role: .synthesis,
      artifactSHA256: input.artifactSHA256,
      directive: .fresh,
      sessions: &sessions
    )
    guard case .pullRequestReview(let synthesis) = synthesisResult.payload,
      synthesis.commitNarrativeSHA256 == narrativeDigest
    else {
      throw PiWorkflowRouterError.narrativeDigestMismatch
    }
    let payloads =
      try results.map { result -> PiPRReviewPayload in
        guard case .pullRequestReview(let payload) = result.payload else {
          throw PiWorkflowRouterError.unexpectedPayload
        }
        return payload
      } + [synthesis]
    var mergedFindings: [PiWorkflowFinding] = []
    var mergedEvidence: [String] = []
    for payload in payloads {
      for finding in payload.findings where !mergedFindings.contains(finding) {
        mergedFindings.append(finding)
      }
      for item in payload.evidence where !mergedEvidence.contains(item) {
        mergedEvidence.append(item)
      }
    }
    let findingSeverities = mergedFindings.map { finding -> PiWorkflowReportSeverity in
      switch finding.severity {
      case .critical: .critical
      case .major: .major
      case .minor: .minor
      case .info: .info
      }
    }
    let effectiveSeverity =
      (payloads.map(\.severity) + findingSeverities)
      .max { $0.rank < $1.rank } ?? .critical
    let reviewBlocked = payloads.contains { payload in
      payload.verdict == "block"
        || payload.severity.rank >= PiWorkflowReportSeverity.major.rank
        || payload.findings.contains(where: {
          $0.severity == .critical || $0.severity == .major
        })
    }
    let effectiveVerdict = reviewBlocked ? "block" : "pass"
    let deterministicSynthesis = PiPRReviewPayload(
      verdict: effectiveVerdict,
      severity: effectiveSeverity,
      summary: reviewBlocked
        ? "Blocked by Jidoka Code's deterministic review gate; independent findings are preserved."
        : synthesis.summary,
      domain: .synthesis,
      commitNarrativeSHA256: narrativeDigest,
      evidence: mergedEvidence,
      findings: mergedFindings
    )
    return PiPullRequestReviewOutput(
      commitNarrativeSHA256: narrativeDigest,
      roleResults: results,
      synthesis: deterministicSynthesis,
      effectiveVerdict: effectiveVerdict,
      effectiveSeverity: effectiveSeverity
    )
  }

  public static func commitNarrativeDigest(
    _ commits: [PiCommitNarrativeEntry],
    baseSHA: String
  ) throws -> String {
    guard GitHubInputValidation.validGitSHA(baseSHA),
      !commits.isEmpty,
      commits.count <= 10_000,
      !commits.map(\.sha).contains(baseSHA),
      commits.map(\.ordinal) == Array(commits.indices),
      Set(commits.map(\.sha)).count == commits.count,
      commits.allSatisfy({ commit in
        GitHubInputValidation.validGitSHA(commit.sha)
          && commit.parentSHAs.allSatisfy(GitHubInputValidation.validGitSHA)
          && !commit.subject.isEmpty
          && commit.subject.utf8.count <= 1_024
          && GitHubInputValidation.validSHA256(commit.patchSHA256)
      })
    else {
      throw PiWorkflowRouterError.invalidCommitNarrative
    }
    let indexBySHA = Dictionary(
      uniqueKeysWithValues: commits.enumerated().map { ($0.element.sha, $0.offset) }
    )
    for (childIndex, commit) in commits.enumerated() {
      guard Set(commit.parentSHAs).count == commit.parentSHAs.count else {
        throw PiWorkflowRouterError.invalidCommitNarrative
      }
      for parent in commit.parentSHAs {
        if let parentIndex = indexBySHA[parent], parentIndex >= childIndex {
          throw PiWorkflowRouterError.invalidCommitNarrative
        }
      }
    }
    var reachableFromHead: Set<String> = []
    var reachedBase = false
    var pending = [commits[commits.count - 1].sha]
    while let sha = pending.popLast() {
      guard reachableFromHead.insert(sha).inserted,
        let index = indexBySHA[sha]
      else {
        continue
      }
      for parent in commits[index].parentSHAs {
        if parent == baseSHA {
          reachedBase = true
        } else if indexBySHA[parent] != nil {
          pending.append(parent)
        }
      }
    }
    guard reachedBase, reachableFromHead.count == commits.count else {
      throw PiWorkflowRouterError.invalidCommitNarrative
    }
    let fields =
      ["baseSHA", baseSHA]
      + commits.flatMap { commit in
        [
          String(commit.ordinal),
          commit.sha,
          commit.parentSHAs.joined(separator: ","),
          commit.subject,
          commit.patchSHA256,
        ]
      }
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(framed.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct PiIssueTriageInput: Equatable, Sendable {
  public let jobID: String
  public let artifactSHA256: String

  public init(jobID: String, artifactSHA256: String) {
    self.jobID = jobID
    self.artifactSHA256 = artifactSHA256
  }
}

public struct PiIssueTriageOutput: Equatable, Sendable {
  public let result: PiIssueTriagePayload
  public let effectiveVerdict: String

  public init(result: PiIssueTriagePayload, effectiveVerdict: String) {
    self.result = result
    self.effectiveVerdict = effectiveVerdict
  }
}

public struct PiIssueTriageRouter: Sendable {
  private let executor: any PiWorkflowExecuting

  public init(executor: any PiWorkflowExecuting) {
    self.executor = executor
  }

  public func run(_ input: PiIssueTriageInput) async throws -> PiIssueTriageOutput {
    try validateCommon(jobID: input.jobID, artifactSHA256: input.artifactSHA256)
    var sessions: Set<String> = []
    let execution = try await executor.execute(
      PiWorkflowExecutionRequest(
        jobID: input.jobID,
        workflow: .issueTriage,
        role: .triage,
        round: 1,
        artifactSHA256: input.artifactSHA256,
        sessionDirective: .fresh
      )
    )
    let result = try validateExecution(
      execution,
      workflow: .issueTriage,
      role: .triage,
      artifactSHA256: input.artifactSHA256,
      directive: .fresh,
      sessions: &sessions
    )
    guard case .issueTriage(let payload) = result.payload else {
      throw PiWorkflowRouterError.unexpectedPayload
    }
    let effectiveVerdict =
      payload.hardRiskFlags.isEmpty
        && payload.severity.rank < PiWorkflowReportSeverity.major.rank
      ? payload.verdict : "human"
    return PiIssueTriageOutput(result: payload, effectiveVerdict: effectiveVerdict)
  }
}

public enum PiPlanningDisposition: String, Codable, Sendable {
  case ready
  case requiresApproval
  case humanOwned
  case blocked
}

public struct PiPlanningOutput: Sendable {
  public let disposition: PiPlanningDisposition
  public let rounds: Int
  public let complexity: ComplexityDecision
  public let frozenPlan: FrozenCommandPlan?
  public let planMarkdown: String
  public let roleResults: [PiWorkflowRoleResult]
  public let engineFailures: [String]

  public init(
    disposition: PiPlanningDisposition,
    rounds: Int,
    complexity: ComplexityDecision,
    frozenPlan: FrozenCommandPlan?,
    planMarkdown: String,
    roleResults: [PiWorkflowRoleResult],
    engineFailures: [String]
  ) {
    self.disposition = disposition
    self.rounds = rounds
    self.complexity = complexity
    self.frozenPlan = frozenPlan
    self.planMarkdown = planMarkdown
    self.roleResults = roleResults
    self.engineFailures = engineFailures
  }
}

public struct PiPlanningRouter: Sendable {
  public static let maximumRounds = 3
  private let executor: any PiWorkflowExecuting

  public init(executor: any PiWorkflowExecuting) {
    self.executor = executor
  }

  public func run(jobID: String, artifactSHA256: String) async throws -> PiPlanningOutput {
    try validateCommon(jobID: jobID, artifactSHA256: artifactSHA256)
    var sessions: Set<String> = []
    var writerSession: String?
    var writerBoundarySHA256: String?
    var priorInputs: [PiNormalizedRoleResult] = []
    var engineFailures: [String] = []
    var lastResults: [PiWorkflowRoleResult] = []
    var lastDecision: ComplexityDecision?
    var lastPlanMarkdown = ""

    for round in 1...Self.maximumRounds {
      let directive: PiWorkflowSessionDirective =
        if let writerSession, let writerBoundarySHA256 {
          .resumeBounded(
            sessionID: writerSession,
            boundarySHA256: writerBoundarySHA256
          )
        } else if let writerSession {
          .resume(writerSession)
        } else {
          .fresh
        }
      let writerExecution = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: jobID,
          workflow: .planning,
          role: .writer,
          round: round,
          artifactSHA256: artifactSHA256,
          sessionDirective: directive,
          normalizedRoleInputs: priorInputs,
          engineFailures: engineFailures
        )
      )
      let writer = try validateExecution(
        writerExecution,
        workflow: .planning,
        role: .writer,
        artifactSHA256: artifactSHA256,
        directive: directive,
        sessions: &sessions
      )
      writerSession = writerExecution.sessionID
      writerBoundarySHA256 = writerExecution.sessionBoundarySHA256
      guard case .planning(let writerPayload) = writer.payload,
        writerPayload.approvedPlanDigest == nil,
        writerPayload.approvedCommandDigests.isEmpty
      else {
        throw PiWorkflowRouterError.unexpectedPayload
      }
      lastPlanMarkdown = writerPayload.planMarkdown
      let commands: [ApprovedCommand]
      if writerPayload.commandDefinitions.isEmpty {
        commands = []
      } else {
        do {
          commands = try ApprovedCommandCanonicalizer.canonicalize(
            writerPayload.commandDefinitions
          )
        } catch {
          engineFailures = ["command-definition-invalid"]
          lastResults = [writer]
          if round < Self.maximumRounds {
            priorInputs = [PiNormalizedRoleResult.make(from: writer)]
            continue
          }
          let decision = try ComplexityClassifier.classify([
            complexityReport(writerPayload, role: .writer)
          ])
          return PiPlanningOutput(
            disposition: .blocked,
            rounds: round,
            complexity: decision,
            frozenPlan: nil,
            planMarkdown: writerPayload.planMarkdown,
            roleResults: [writer],
            engineFailures: engineFailures
          )
        }
      }
      guard !commands.isEmpty, !writerPayload.planMarkdown.isEmpty else {
        engineFailures = []
        if commands.isEmpty { engineFailures.append("approved-command-plan-empty") }
        if writerPayload.planMarkdown.isEmpty { engineFailures.append("plan-markdown-empty") }
        lastResults = [writer]
        let decision = try ComplexityClassifier.classify([
          complexityReport(writerPayload, role: .writer)
        ])
        lastDecision = decision
        if round < Self.maximumRounds {
          priorInputs = [PiNormalizedRoleResult.make(from: writer)]
          continue
        }
        return PiPlanningOutput(
          disposition: decision.isHumanOwned ? .humanOwned : .blocked,
          rounds: round,
          complexity: decision,
          frozenPlan: nil,
          planMarkdown: writerPayload.planMarkdown,
          roleResults: [writer],
          engineFailures: engineFailures + ["planning-round-limit"]
        )
      }
      let commandDigests = commands.map(\.definitionDigest).sorted()
      let candidatePlan = try FrozenCommandPlan(
        artifactSHA256: artifactSHA256,
        planMarkdown: writerPayload.planMarkdown,
        commands: commands,
        planningDecision: nil,
        expectedDigest: FrozenCommandPlan.digest(
          artifactSHA256: artifactSHA256,
          planMarkdown: writerPayload.planMarkdown,
          commands: commands,
          planningDecision: nil
        )
      )
      var roundResults = [writer]
      for role in [PiWorkflowRole.architecture, .security, .test] {
        let execution = try await executor.execute(
          PiWorkflowExecutionRequest(
            jobID: jobID,
            workflow: .planning,
            role: role,
            round: round,
            artifactSHA256: artifactSHA256,
            sessionDirective: .fresh,
            normalizedRoleInputs: [PiNormalizedRoleResult.make(from: writer)],
            canonicalCommandDigests: commandDigests,
            frozenPlan: candidatePlan
          )
        )
        let result = try validateExecution(
          execution,
          workflow: .planning,
          role: role,
          artifactSHA256: artifactSHA256,
          directive: .fresh,
          sessions: &sessions
        )
        guard case .planning(let payload) = result.payload,
          payload.commandDefinitions.isEmpty
        else {
          throw PiWorkflowRouterError.unexpectedPayload
        }
        roundResults.append(result)
      }
      let synthesisExecution = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: jobID,
          workflow: .planning,
          role: .synthesis,
          round: round,
          artifactSHA256: artifactSHA256,
          sessionDirective: .fresh,
          normalizedRoleInputs: roundResults.map(PiNormalizedRoleResult.make),
          canonicalCommandDigests: commandDigests,
          frozenPlan: candidatePlan
        )
      )
      let synthesis = try validateExecution(
        synthesisExecution,
        workflow: .planning,
        role: .synthesis,
        artifactSHA256: artifactSHA256,
        directive: .fresh,
        sessions: &sessions
      )
      guard case .planning(let synthesisPayload) = synthesis.payload,
        synthesisPayload.commandDefinitions.isEmpty
      else {
        throw PiWorkflowRouterError.unexpectedPayload
      }
      roundResults.append(synthesis)
      let reports = try roundResults.map { result -> ComplexityReport in
        guard case .planning(let payload) = result.payload else {
          throw PiWorkflowRouterError.unexpectedPayload
        }
        return complexityReport(payload, role: result.role)
      }
      let decision = try ComplexityClassifier.classify(reports)
      lastDecision = decision
      lastResults = roundResults
      let approvalsExact = roundResults.dropFirst().allSatisfy { result in
        guard case .planning(let payload) = result.payload else { return false }
        return payload.approvedCommandDigests.sorted() == commandDigests
          && payload.approvedPlanDigest == candidatePlan.digest
      }
      let verdictsPass = roundResults.allSatisfy { result in
        guard case .planning(let payload) = result.payload else { return false }
        return payload.verdict == "pass"
      }
      let findingsClean = roundResults.allSatisfy { result in
        guard case .planning(let payload) = result.payload else { return false }
        return payload.severity.rank < PiWorkflowReportSeverity.major.rank
          && !payload.findings.contains(where: {
            $0.severity == .critical || $0.severity == .major
          })
      }
      let gatePassed = verdictsPass && approvalsExact && findingsClean
      if decision.isHumanOwned {
        return PiPlanningOutput(
          disposition: .humanOwned,
          rounds: round,
          complexity: decision,
          frozenPlan: nil,
          planMarkdown: writerPayload.planMarkdown,
          roleResults: roundResults,
          engineFailures: []
        )
      }
      if gatePassed {
        let planningDecision = try FrozenPlanningDecision(
          candidatePlan: candidatePlan,
          complexity: decision,
          roleResults: roundResults
        )
        let frozenPlan = try FrozenCommandPlan(
          artifactSHA256: artifactSHA256,
          planMarkdown: writerPayload.planMarkdown,
          commands: commands,
          planningDecision: planningDecision,
          expectedDigest: FrozenCommandPlan.digest(
            artifactSHA256: artifactSHA256,
            planMarkdown: writerPayload.planMarkdown,
            commands: commands,
            planningDecision: planningDecision
          )
        )
        return PiPlanningOutput(
          disposition: decision.requiresPlanApproval ? .requiresApproval : .ready,
          rounds: round,
          complexity: decision,
          frozenPlan: frozenPlan,
          planMarkdown: writerPayload.planMarkdown,
          roleResults: roundResults,
          engineFailures: []
        )
      }
      engineFailures = planningFailures(
        verdictsPass: verdictsPass,
        approvalsExact: approvalsExact,
        findingsClean: findingsClean
      )
      priorInputs = roundResults.map(PiNormalizedRoleResult.make)
    }

    guard let lastDecision else { throw PiWorkflowRouterError.executorFailure }
    return PiPlanningOutput(
      disposition: .blocked,
      rounds: Self.maximumRounds,
      complexity: lastDecision,
      frozenPlan: nil,
      planMarkdown: lastPlanMarkdown,
      roleResults: lastResults,
      engineFailures: engineFailures + ["planning-round-limit"]
    )
  }

  private func complexityReport(
    _ payload: PiPlanningPayload,
    role: PiWorkflowRole
  ) -> ComplexityReport {
    ComplexityReport(
      reporter: role,
      proposed: payload.proposedComplexity,
      facts: payload.classifierFacts,
      evidence: payload.evidence
    )
  }

  private func planningFailures(
    verdictsPass: Bool,
    approvalsExact: Bool,
    findingsClean: Bool
  ) -> [String] {
    var failures: [String] = []
    if !verdictsPass { failures.append("role-veto") }
    if !approvalsExact { failures.append("plan-or-command-digest-not-approved") }
    if !findingsClean { failures.append("critical-major-unresolved") }
    return failures
  }
}

public enum PiOrchestrationDisposition: String, Codable, Sendable {
  case succeeded
  case blocked
}

public struct PiOrchestrationOutput: Sendable {
  public let disposition: PiOrchestrationDisposition
  public let rounds: Int
  public let roleResults: [PiWorkflowRoleResult]
  public let commandEvidence: [VerificationCommandEvidence]
  public let engineFailures: [String]

  public init(
    disposition: PiOrchestrationDisposition,
    rounds: Int,
    roleResults: [PiWorkflowRoleResult],
    commandEvidence: [VerificationCommandEvidence],
    engineFailures: [String]
  ) {
    self.disposition = disposition
    self.rounds = rounds
    self.roleResults = roleResults
    self.commandEvidence = commandEvidence
    self.engineFailures = engineFailures
  }
}

public struct PiOrchestrationRouter: Sendable {
  public static let maximumRounds = 3
  private let executor: any PiWorkflowExecuting
  private let commandExecutor: any PiApprovedCommandExecuting

  public init(
    executor: any PiWorkflowExecuting,
    commandExecutor: any PiApprovedCommandExecuting
  ) {
    self.executor = executor
    self.commandExecutor = commandExecutor
  }

  public func run(
    jobID: String,
    artifactSHA256: String,
    plan: FrozenCommandPlan
  ) async throws -> PiOrchestrationOutput {
    try validateCommon(jobID: jobID, artifactSHA256: artifactSHA256)
    guard plan.artifactSHA256 == artifactSHA256 else {
      throw PiWorkflowRouterError.invalidInput
    }
    do {
      try plan.validateFinalPlanningDecision()
    } catch {
      throw PiWorkflowRouterError.invalidInput
    }
    var sessions: Set<String> = []
    var writerSession: String?
    var writerBoundarySHA256: String?
    var priorInputs: [PiNormalizedRoleResult] = []
    var engineFailures: [String] = []
    var lastResults: [PiWorkflowRoleResult] = []
    var lastEvidence: [VerificationCommandEvidence] = []

    for round in 1...Self.maximumRounds {
      let directive: PiWorkflowSessionDirective =
        if let writerSession, let writerBoundarySHA256 {
          .resumeBounded(
            sessionID: writerSession,
            boundarySHA256: writerBoundarySHA256
          )
        } else if let writerSession {
          .resume(writerSession)
        } else {
          .fresh
        }
      let writerExecution = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: jobID,
          workflow: .orchestration,
          role: .writer,
          round: round,
          artifactSHA256: artifactSHA256,
          sessionDirective: directive,
          normalizedRoleInputs: priorInputs,
          canonicalCommandDigests: plan.commands.values.map(\.definitionDigest).sorted(),
          frozenPlan: plan,
          commandEvidence: lastEvidence,
          engineFailures: engineFailures
        )
      )
      let writer = try validateExecution(
        writerExecution,
        workflow: .orchestration,
        role: .writer,
        artifactSHA256: artifactSHA256,
        directive: directive,
        sessions: &sessions
      )
      writerSession = writerExecution.sessionID
      writerBoundarySHA256 = writerExecution.sessionBoundarySHA256
      guard case .orchestration(let writerPayload) = writer.payload,
        writerPayload.requestedCommandIDs == plan.commandOrder,
        writer.approvedCommandIDs == plan.commandOrder
      else {
        throw PiWorkflowRouterError.unexpectedPayload
      }

      let writerBlocked =
        writerPayload.verdict != "pass"
        || writerPayload.severity.rank >= PiWorkflowReportSeverity.major.rank
        || writerPayload.findings.contains(where: {
          $0.severity == .critical || $0.severity == .major
        })
      var evidence: [VerificationCommandEvidence] = []
      var commandFailure = writerBlocked
      engineFailures = writerBlocked ? ["writer-veto"] : []
      if !writerBlocked {
        for commandID in plan.commandOrder {
          let item = try await commandExecutor.execute(
            commandID: commandID,
            expectedPlanDigest: plan.digest,
            plan: plan,
            round: round
          )
          guard item.commandID == commandID,
            item.definitionDigest == plan.commands[commandID]?.definitionDigest
          else {
            throw PiWorkflowRouterError.commandEvidenceMismatch
          }
          evidence.append(item)
          if !item.succeeded {
            commandFailure = true
            break
          }
        }
      }
      var roundResults = [writer]
      for role in [PiWorkflowRole.architecture, .security, .test] {
        let execution = try await executor.execute(
          PiWorkflowExecutionRequest(
            jobID: jobID,
            workflow: .orchestration,
            role: role,
            round: round,
            artifactSHA256: artifactSHA256,
            sessionDirective: .fresh,
            normalizedRoleInputs: [PiNormalizedRoleResult.make(from: writer)],
            canonicalCommandDigests: plan.commands.values.map(\.definitionDigest).sorted(),
            frozenPlan: plan,
            commandEvidence: evidence,
            engineFailures: commandFailure
              ? engineFailures + ["verification-failed"] : []
          )
        )
        roundResults.append(
          try validateExecution(
            execution,
            workflow: .orchestration,
            role: role,
            artifactSHA256: artifactSHA256,
            directive: .fresh,
            sessions: &sessions
          )
        )
      }
      let synthesisExecution = try await executor.execute(
        PiWorkflowExecutionRequest(
          jobID: jobID,
          workflow: .orchestration,
          role: .synthesis,
          round: round,
          artifactSHA256: artifactSHA256,
          sessionDirective: .fresh,
          normalizedRoleInputs: roundResults.map(PiNormalizedRoleResult.make),
          canonicalCommandDigests: plan.commands.values.map(\.definitionDigest).sorted(),
          frozenPlan: plan,
          commandEvidence: evidence,
          engineFailures: commandFailure
            ? engineFailures + ["verification-failed"] : []
        )
      )
      let synthesis = try validateExecution(
        synthesisExecution,
        workflow: .orchestration,
        role: .synthesis,
        artifactSHA256: artifactSHA256,
        directive: .fresh,
        sessions: &sessions
      )
      roundResults.append(synthesis)
      guard case .orchestration = synthesis.payload else {
        throw PiWorkflowRouterError.unexpectedPayload
      }
      let verdictsPass = roundResults.allSatisfy { result in
        guard case .orchestration(let payload) = result.payload else { return false }
        return payload.verdict == "pass"
      }
      let findingsClean = roundResults.allSatisfy { result in
        guard case .orchestration(let payload) = result.payload else { return false }
        return payload.severity.rank < PiWorkflowReportSeverity.major.rank
          && !payload.findings.contains(where: {
            $0.severity == .critical || $0.severity == .major
          })
      }
      let allEvidencePassed =
        evidence.count == plan.commandOrder.count
        && evidence.allSatisfy(\.succeeded)
      if verdictsPass, findingsClean, allEvidencePassed, !commandFailure {
        return PiOrchestrationOutput(
          disposition: .succeeded,
          rounds: round,
          roleResults: roundResults,
          commandEvidence: evidence,
          engineFailures: []
        )
      }
      engineFailures = []
      if commandFailure || !allEvidencePassed { engineFailures.append("verification-failed") }
      if !findingsClean { engineFailures.append("critical-major-unresolved") }
      if !verdictsPass { engineFailures.append("role-veto") }
      priorInputs = roundResults.map(PiNormalizedRoleResult.make)
      lastResults = roundResults
      lastEvidence = evidence
    }

    return PiOrchestrationOutput(
      disposition: .blocked,
      rounds: Self.maximumRounds,
      roleResults: lastResults,
      commandEvidence: lastEvidence,
      engineFailures: engineFailures + ["orchestration-round-limit"]
    )
  }
}

private func validateCommon(jobID: String, artifactSHA256: String) throws {
  guard jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil,
    GitHubInputValidation.validSHA256(artifactSHA256)
  else {
    throw PiWorkflowRouterError.invalidInput
  }
}

private func validateExecution(
  _ execution: PiWorkflowExecution,
  workflow: PiWorkflowKind,
  role: PiWorkflowRole,
  artifactSHA256: String,
  directive: PiWorkflowSessionDirective,
  sessions: inout Set<String>
) throws -> PiWorkflowRoleResult {
  guard !execution.sessionID.isEmpty,
    execution.sessionID.utf8.count <= 128,
    execution.result.workflow == workflow,
    execution.result.role == role,
    execution.result.artifactSHA256 == artifactSHA256,
    GitHubInputValidation.validSHA256(execution.result.recordSHA256),
    Set(execution.result.approvedCommandIDs).count
      == execution.result.approvedCommandIDs.count,
    execution.result.approvedCommandIDs.allSatisfy({
      $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil
    })
  else {
    throw PiWorkflowRouterError.invalidExecutionIdentity
  }
  guard execution.agentSettledCount == 1 else {
    throw PiWorkflowRouterError.missingSettledEvidence
  }
  guard execution.extensionErrorCount == 0 else {
    throw PiWorkflowRouterError.extensionFailure
  }
  switch directive {
  case .fresh:
    guard sessions.insert(execution.sessionID).inserted else {
      throw PiWorkflowRouterError.reusedFreshSession
    }
  case .resume(let expected):
    guard execution.sessionID == expected, sessions.contains(expected) else {
      throw PiWorkflowRouterError.wrongWriterSession
    }
  case .resumeBounded(let expected, let priorBoundary):
    guard execution.sessionID == expected, sessions.contains(expected),
      GitHubInputValidation.validSHA256(priorBoundary),
      execution.sessionBoundarySHA256.map(GitHubInputValidation.validSHA256) == true
    else {
      throw PiWorkflowRouterError.wrongWriterSession
    }
  }
  return execution.result
}
