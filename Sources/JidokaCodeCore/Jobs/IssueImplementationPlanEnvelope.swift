import Foundation

public struct IssueImplementationPlanEnvelope: Sendable {
  public let issueRevisionSHA256: String
  public let baseRevision: BaseRevision
  public let branch: String
  public let planPath: String
  public let plan: FrozenCommandPlan

  public init(
    issueRevisionSHA256: String,
    baseRevision: BaseRevision,
    branch: String,
    planPath: String,
    plan: FrozenCommandPlan
  ) throws {
    guard GitHubInputValidation.validSHA256(issueRevisionSHA256),
      GitBranchPolicy.validImplementationBranch(branch),
      !planPath.isEmpty,
      !planPath.hasPrefix("/"),
      planPath.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
    else {
      throw IssueImplementationPlanEnvelopeError.invalidEnvelope
    }
    try plan.validateFinalPlanningDecision()
    self.issueRevisionSHA256 = issueRevisionSHA256
    self.baseRevision = baseRevision
    self.branch = branch
    self.planPath = planPath
    self.plan = plan
  }
}

public enum IssueImplementationPlanEnvelopeError: Error, Equatable, Sendable {
  case invalidEnvelope
}

public enum IssueImplementationPlanEnvelopeCodec {
  public static func encode(_ envelope: IssueImplementationPlanEnvelope) throws -> Data {
    let planData = try FrozenCommandPlanCodec.encode(envelope.plan)
    let object: [String: Any] = [
      "baseBranch": envelope.baseRevision.branch,
      "baseDigest": envelope.baseRevision.sha256,
      "baseSHA": envelope.baseRevision.sha,
      "branch": envelope.branch,
      "issueRevisionSHA256": envelope.issueRevisionSHA256,
      "plan": planData.base64EncodedString(),
      "planPath": envelope.planPath,
      "schemaVersion": 1,
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw IssueImplementationPlanEnvelopeError.invalidEnvelope
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  public static func decode(_ data: Data) throws -> IssueImplementationPlanEnvelope {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object.count == 8,
      object["schemaVersion"] as? Int == 1,
      let issueRevision = object["issueRevisionSHA256"] as? String,
      let baseBranch = object["baseBranch"] as? String,
      let baseSHA = object["baseSHA"] as? String,
      let baseDigest = object["baseDigest"] as? String,
      let branch = object["branch"] as? String,
      let planPath = object["planPath"] as? String,
      let planBase64 = object["plan"] as? String,
      let planData = Data(base64Encoded: planBase64)
    else {
      throw IssueImplementationPlanEnvelopeError.invalidEnvelope
    }
    let base = try BaseRevision(branch: baseBranch, sha: baseSHA)
    guard base.sha256 == baseDigest else {
      throw IssueImplementationPlanEnvelopeError.invalidEnvelope
    }
    return try IssueImplementationPlanEnvelope(
      issueRevisionSHA256: issueRevision,
      baseRevision: base,
      branch: branch,
      planPath: planPath,
      plan: FrozenCommandPlanCodec.decode(planData)
    )
  }
}
