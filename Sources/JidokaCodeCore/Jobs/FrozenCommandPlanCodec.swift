import Foundation

public enum FrozenCommandPlanCodecError: Error, Equatable, Sendable {
  case incompletePlan
  case inconsistentComplexity
  case invalidSnapshot
}

public enum FrozenCommandPlanCodec {
  public static func encode(_ plan: FrozenCommandPlan) throws -> Data {
    guard let decision = plan.planningDecision else {
      throw FrozenCommandPlanCodecError.incompletePlan
    }
    let commands = try plan.commandOrder.map { id -> ApprovedCommand in
      guard let command = plan.commands[id] else {
        throw FrozenCommandPlanCodecError.invalidSnapshot
      }
      return command
    }
    let snapshot = Snapshot(
      schemaVersion: 1,
      artifactSHA256: plan.artifactSHA256,
      classifierVersion: plan.classifierVersion,
      planMarkdown: plan.planMarkdown,
      commands: commands,
      roleResults: decision.roleResults,
      complexity: decision.complexity,
      planningDecisionSHA256: decision.digest,
      digest: plan.digest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }

  public static func decode(_ data: Data) throws -> FrozenCommandPlan {
    let decoder = JSONDecoder()
    let snapshot: Snapshot
    do {
      snapshot = try decoder.decode(Snapshot.self, from: data)
    } catch {
      throw FrozenCommandPlanCodecError.invalidSnapshot
    }
    guard snapshot.schemaVersion == 1,
      snapshot.classifierVersion == ComplexityDecision.classifierVersion,
      GitHubInputValidation.validSHA256(snapshot.digest),
      GitHubInputValidation.validSHA256(snapshot.planningDecisionSHA256)
    else {
      throw FrozenCommandPlanCodecError.invalidSnapshot
    }
    let reports = try snapshot.roleResults.map { result -> ComplexityReport in
      guard case .planning(let payload) = result.payload else {
        throw FrozenCommandPlanCodecError.invalidSnapshot
      }
      return ComplexityReport(
        reporter: result.role,
        proposed: payload.proposedComplexity,
        facts: payload.classifierFacts,
        evidence: payload.evidence
      )
    }
    guard try ComplexityClassifier.classify(reports) == snapshot.complexity else {
      throw FrozenCommandPlanCodecError.inconsistentComplexity
    }
    let candidateDigest = FrozenCommandPlan.digest(
      artifactSHA256: snapshot.artifactSHA256,
      planMarkdown: snapshot.planMarkdown,
      commands: snapshot.commands,
      planningDecision: nil,
      classifierVersion: snapshot.classifierVersion
    )
    let candidate = try FrozenCommandPlan(
      artifactSHA256: snapshot.artifactSHA256,
      planMarkdown: snapshot.planMarkdown,
      commands: snapshot.commands,
      planningDecision: nil,
      expectedDigest: candidateDigest,
      classifierVersion: snapshot.classifierVersion
    )
    let decision = try FrozenPlanningDecision(
      candidatePlan: candidate,
      complexity: snapshot.complexity,
      roleResults: snapshot.roleResults
    )
    guard decision.digest == snapshot.planningDecisionSHA256 else {
      throw FrozenCommandPlanCodecError.invalidSnapshot
    }
    return try FrozenCommandPlan(
      artifactSHA256: snapshot.artifactSHA256,
      planMarkdown: snapshot.planMarkdown,
      commands: snapshot.commands,
      planningDecision: decision,
      expectedDigest: snapshot.digest,
      classifierVersion: snapshot.classifierVersion
    )
  }

  private struct Snapshot: Codable {
    let schemaVersion: Int
    let artifactSHA256: String
    let classifierVersion: String
    let planMarkdown: String
    let commands: [ApprovedCommand]
    let roleResults: [PiWorkflowRoleResult]
    let complexity: ComplexityDecision
    let planningDecisionSHA256: String
    let digest: String
  }
}
