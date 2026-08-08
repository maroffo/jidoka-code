import CryptoKit
import Foundation

public struct PiJobWorkflowContext: Sendable {
  public let artifact: Data
  public let workspaceRoot: URL
  public let sessionRoot: URL
  public let profiles: [ModelProfileConfiguration]
  public let allowedWritePaths: [String]
  public let offline: Bool
  public let timeoutSeconds: TimeInterval

  public init(
    artifact: Data,
    workspaceRoot: URL,
    sessionRoot: URL,
    profiles: [ModelProfileConfiguration],
    allowedWritePaths: [String],
    offline: Bool,
    timeoutSeconds: TimeInterval = 600
  ) {
    self.artifact = artifact
    self.workspaceRoot = workspaceRoot
    self.sessionRoot = sessionRoot
    self.profiles = profiles
    self.allowedWritePaths = allowedWritePaths
    self.offline = offline
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum PiJobWorkflowPreparerError: Error, Equatable, Sendable {
  case invalidArtifact
  case artifactDigestMismatch
  case missingProfile(ModelProfileRole)
  case duplicateProfile(ModelProfileRole)
  case promptEncodingFailed
}

public struct PiJobWorkflowPreparer: PiRPCWorkflowPreparing, Sendable {
  private let context: PiJobWorkflowContext

  public init(context: PiJobWorkflowContext) {
    self.context = context
  }

  public func prepare(
    _ request: PiWorkflowExecutionRequest
  ) async throws -> PiRPCWorkflowPreparation {
    guard !context.artifact.isEmpty,
      context.artifact.count <= 2 * 1_024 * 1_024,
      let artifactText = String(data: context.artifact, encoding: .utf8),
      !artifactText.unicodeScalars.contains(where: { $0.value == 0 })
    else {
      throw PiJobWorkflowPreparerError.invalidArtifact
    }
    guard Self.sha256(context.artifact) == request.artifactSHA256 else {
      throw PiJobWorkflowPreparerError.artifactDigestMismatch
    }
    let role = Self.profileRole(for: request.workflow, role: request.role)
    let matchingProfiles = context.profiles.filter { $0.role == role }
    guard let profile = matchingProfiles.first else {
      throw PiJobWorkflowPreparerError.missingProfile(role)
    }
    guard matchingProfiles.count == 1 else {
      throw PiJobWorkflowPreparerError.duplicateProfile(role)
    }
    let prompt = try Self.prompt(
      request: request,
      artifactText: artifactText
    )
    let writer =
      request.role == .writer
      && (request.workflow == .planning || request.workflow == .orchestration)
    return PiRPCWorkflowPreparation(
      profile: profile,
      workspaceRoot: context.workspaceRoot,
      sessionRoot: context.sessionRoot,
      allowedWritePaths: writer ? context.allowedWritePaths : [],
      prompt: prompt,
      offline: context.offline,
      timeoutSeconds: context.timeoutSeconds
    )
  }

  private static func prompt(
    request: PiWorkflowExecutionRequest,
    artifactText: String
  ) throws -> String {
    let object: [String: Any] = [
      "applicationArtifactUTF8": artifactText,
      "artifactSHA256": request.artifactSHA256,
      "canonicalCommandDigests": request.canonicalCommandDigests,
      "commandEvidence": request.commandEvidence.map(commandEvidenceObject),
      "engineFailures": request.engineFailures,
      "frozenPlan": request.frozenPlan.map(planObject) ?? NSNull(),
      "jobID": request.jobID,
      "normalizedRoleInputs": request.normalizedRoleInputs.map(normalizedResultObject),
      "role": request.role.rawValue,
      "round": request.round,
      "schemaVersion": 1,
      "workflow": request.workflow.rawValue,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PiJobWorkflowPreparerError.promptEncodingFailed
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let value = String(data: data, encoding: .utf8) else {
      throw PiJobWorkflowPreparerError.promptEncodingFailed
    }
    return value
  }

  private static func normalizedResultObject(
    _ result: PiNormalizedRoleResult
  ) -> [String: Any] {
    [
      "approvedCommandDigests": result.approvedCommandDigests,
      "approvedPlanDigest": result.approvedPlanDigest ?? NSNull(),
      "evidence": result.evidence,
      "findings": result.findings.map(findingObject),
      "proposedComplexity": result.proposedComplexity?.rawValue ?? NSNull(),
      "role": result.role.rawValue,
      "severity": result.severity.rawValue,
      "summary": result.summary,
      "verdict": result.verdict,
    ]
  }

  private static func findingObject(_ finding: PiWorkflowFinding) -> [String: Any] {
    [
      "evidence": finding.evidence,
      "line": finding.line,
      "path": finding.path,
      "recommendation": finding.recommendation,
      "severity": finding.severity.rawValue,
    ]
  }

  private static func commandEvidenceObject(
    _ evidence: VerificationCommandEvidence
  ) -> [String: Any] {
    [
      "commandID": evidence.commandID,
      "definitionDigest": evidence.definitionDigest,
      "durationMilliseconds": evidence.durationMilliseconds,
      "exitCode": evidence.exitCode.map { Int($0) } ?? NSNull(),
      "outputLimitExceeded": evidence.outputLimitExceeded,
      "registryKind": evidence.registryKind.rawValue,
      "repositoryHeadSHA": evidence.repositoryHeadSHA ?? NSNull(),
      "stderrExcerpt": evidence.stderrExcerpt,
      "stderrSHA256": evidence.stderrSHA256,
      "stdoutExcerpt": evidence.stdoutExcerpt,
      "stdoutSHA256": evidence.stdoutSHA256,
      "succeeded": evidence.succeeded,
      "terminationSignal": evidence.terminationSignal.map { Int($0) } ?? NSNull(),
      "timedOut": evidence.timedOut,
    ]
  }

  private static func planObject(_ plan: FrozenCommandPlan) -> [String: Any] {
    [
      "artifactSHA256": plan.artifactSHA256,
      "classifierVersion": plan.classifierVersion,
      "commandOrder": plan.commandOrder,
      "commands": plan.commandOrder.compactMap { id in
        plan.commands[id].map(commandObject)
      },
      "digest": plan.digest,
      "planMarkdown": plan.planMarkdown,
      "planningDecisionSHA256": plan.planningDecisionSHA256 ?? NSNull(),
    ]
  }

  private static func commandObject(_ command: ApprovedCommand) -> [String: Any] {
    [
      "approvedHookPath": command.approvedHookPath ?? NSNull(),
      "arguments": command.arguments,
      "definitionDigest": command.definitionDigest,
      "environmentOverrides": command.environmentOverrides,
      "executableOrRepositoryScript": command.executableOrRepositoryScript,
      "id": command.id,
      "rationale": command.rationale,
      "registryKind": command.registryKind.rawValue,
      "sourceDigest": command.sourceDigest ?? NSNull(),
      "timeoutSeconds": command.timeoutSeconds,
      "workingDirectory": command.workingDirectory,
    ]
  }

  private static func profileRole(
    for workflow: PiWorkflowKind,
    role: PiWorkflowRole
  ) -> ModelProfileRole {
    if [.architecture, .security, .test].contains(role) { return .review }
    return switch workflow {
    case .pullRequestReview: .review
    case .issueTriage: .triage
    case .planning: .planning
    case .orchestration: .orchestration
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
