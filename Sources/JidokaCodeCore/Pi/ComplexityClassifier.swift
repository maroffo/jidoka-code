import CryptoKit
import Foundation

public struct ComplexityReport: Equatable, Sendable {
  public let reporter: PiWorkflowRole
  public let proposed: WorkComplexity
  public let facts: ComplexityFacts
  public let evidence: [String]

  public init(
    reporter: PiWorkflowRole,
    proposed: WorkComplexity,
    facts: ComplexityFacts,
    evidence: [String]
  ) {
    self.reporter = reporter
    self.proposed = proposed
    self.facts = facts
    self.evidence = evidence
  }
}

public enum ComplexityReason: String, CaseIterable, Codable, Sendable {
  case multipleWorkstreams = "multiple-workstreams"
  case tooManyWorkstreams = "too-many-workstreams"
  case publicAPI = "public-api"
  case nonDestructiveSchema = "non-destructive-schema"
  case crossModuleConcurrency = "cross-module-concurrency"
  case operationalRollback = "operational-rollback"
  case designAlternatives = "design-alternatives"
  case humanDecisionGap = "human-decision-gap"
  case securityOrSecretCore = "security-or-secret-core"
  case dataLossMigration = "data-loss-migration"
  case releaseOrTag = "release-or-tag"
  case infrastructureBlastRadius = "infrastructure-blast-radius"
  case crossRepositoryCoordination = "cross-repository-coordination"
  case unresolvedDesignDebate = "unresolved-design-debate"
  case unverifiable
  case unknownClassification = "unknown-classification"
  case missingEvidence = "missing-evidence"
  case reporterDisagreement = "reporter-disagreement"
  case downgradeRejected = "downgrade-rejected"
}

public struct ComplexityDecision: Equatable, Sendable {
  public static let classifierVersion = "1"

  public let classification: WorkComplexity
  public let reasons: [ComplexityReason]
  public let reports: [ComplexityReport]
  public let downgradeRejectedReporters: [PiWorkflowRole]
  public let disagreement: Bool
  public let version: String

  public init(
    classification: WorkComplexity,
    reasons: [ComplexityReason],
    reports: [ComplexityReport],
    downgradeRejectedReporters: [PiWorkflowRole],
    disagreement: Bool,
    version: String = classifierVersion
  ) {
    self.classification = classification
    self.reasons = reasons
    self.reports = reports
    self.downgradeRejectedReporters = downgradeRejectedReporters
    self.disagreement = disagreement
    self.version = version
  }

  public var requiresPlanApproval: Bool { classification == .complex }
  public var permitsAutomatedImplementation: Bool {
    classification == .simple || classification == .moderate
  }
  public var isHumanOwned: Bool { classification == .humanOwned }

  public var digest: String {
    var fields = [
      "schemaVersion", "1",
      "classifierVersion", version,
      "classification", classification.rawValue,
      "disagreement", String(disagreement),
      "reasonCount", String(reasons.count),
    ]
    for (index, reason) in reasons.enumerated() {
      fields += ["reasonIndex", String(index), "reason", reason.rawValue]
    }
    fields += ["downgradeReporterCount", String(downgradeRejectedReporters.count)]
    for (index, reporter) in downgradeRejectedReporters.enumerated() {
      fields += [
        "downgradeReporterIndex", String(index),
        "downgradeReporter", reporter.rawValue,
      ]
    }
    fields += ["reportCount", String(reports.count)]
    for (index, report) in reports.enumerated() {
      fields += [
        "reportIndex", String(index),
        "reporter", report.reporter.rawValue,
        "proposed", report.proposed.rawValue,
      ]
      fields += Self.framedFacts(report.facts)
      fields += ["evidenceCount", String(report.evidence.count)]
      for (evidenceIndex, evidence) in report.evidence.enumerated() {
        fields += [
          "evidenceIndex", String(evidenceIndex),
          "evidence", evidence,
        ]
      }
    }
    let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(framed.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func framedFacts(_ facts: ComplexityFacts) -> [String] {
    [
      "workstreamCount", String(facts.workstreamCount),
      "publicAPI", String(facts.publicAPI),
      "nonDestructiveSchema", String(facts.nonDestructiveSchema),
      "crossModuleConcurrency", String(facts.crossModuleConcurrency),
      "operationalRollback", String(facts.operationalRollback),
      "designAlternatives", String(facts.designAlternatives),
      "humanDecisionGap", String(facts.humanDecisionGap),
      "securityOrSecretCore", String(facts.securityOrSecretCore),
      "dataLossMigration", String(facts.dataLossMigration),
      "releaseOrTag", String(facts.releaseOrTag),
      "infrastructureBlastRadius", String(facts.infrastructureBlastRadius),
      "crossRepositoryCoordination", String(facts.crossRepositoryCoordination),
      "unresolvedDesignDebate", String(facts.unresolvedDesignDebate),
      "unverifiable", String(facts.unverifiable),
    ]
  }
}

public enum ComplexityClassifierError: Error, Equatable, Sendable {
  case missingReports
  case invalidWorkstreamCount
  case duplicateReporter
}

public enum ComplexityClassifier {
  public static func classify(_ reports: [ComplexityReport]) throws -> ComplexityDecision {
    guard !reports.isEmpty else { throw ComplexityClassifierError.missingReports }
    guard Set(reports.map(\.reporter)).count == reports.count else {
      throw ComplexityClassifierError.duplicateReporter
    }
    guard reports.allSatisfy({ (1...100).contains($0.facts.workstreamCount) }) else {
      throw ComplexityClassifierError.invalidWorkstreamCount
    }

    var classification = WorkComplexity.simple
    var reasons: Set<ComplexityReason> = []
    var downgradeReporters: [PiWorkflowRole] = []
    var normalizedProposals: [WorkComplexity] = []

    for report in reports {
      let required = requiredComplexity(for: report.facts, reasons: &reasons)
      let proposed = report.proposed == .unknown ? WorkComplexity.complex : report.proposed
      normalizedProposals.append(proposed)
      if report.proposed == .unknown {
        reasons.insert(.unknownClassification)
      }
      if report.evidence.isEmpty {
        reasons.insert(.missingEvidence)
        classification = max(classification, .complex)
      }
      if proposed < required {
        reasons.insert(.downgradeRejected)
        downgradeReporters.append(report.reporter)
      }
      classification = max(classification, required, proposed)
    }

    let disagreement = Set(normalizedProposals).count > 1
    if disagreement {
      reasons.insert(.reporterDisagreement)
      classification = max(classification, .complex)
    }
    if reasons.contains(.securityOrSecretCore)
      || reasons.contains(.dataLossMigration)
      || reasons.contains(.releaseOrTag)
      || reasons.contains(.infrastructureBlastRadius)
      || reasons.contains(.crossRepositoryCoordination)
      || reasons.contains(.unresolvedDesignDebate)
      || reasons.contains(.unverifiable)
    {
      classification = .humanOwned
    }

    return ComplexityDecision(
      classification: classification,
      reasons: reasons.sorted { $0.rawValue < $1.rawValue },
      reports: reports,
      downgradeRejectedReporters: downgradeReporters.sorted { $0.rawValue < $1.rawValue },
      disagreement: disagreement
    )
  }

  private static func requiredComplexity(
    for facts: ComplexityFacts,
    reasons: inout Set<ComplexityReason>
  ) -> WorkComplexity {
    var required = WorkComplexity.simple
    if facts.workstreamCount >= 2 {
      reasons.insert(.multipleWorkstreams)
      required = .moderate
    }
    if facts.workstreamCount > 4 {
      reasons.insert(.tooManyWorkstreams)
      required = .complex
    }
    for (triggered, reason) in [
      (facts.publicAPI, ComplexityReason.publicAPI),
      (facts.nonDestructiveSchema, .nonDestructiveSchema),
      (facts.crossModuleConcurrency, .crossModuleConcurrency),
      (facts.operationalRollback, .operationalRollback),
      (facts.designAlternatives, .designAlternatives),
      (facts.humanDecisionGap, .humanDecisionGap),
    ] where triggered {
      reasons.insert(reason)
      required = max(required, .complex)
    }
    for (triggered, reason) in [
      (facts.securityOrSecretCore, ComplexityReason.securityOrSecretCore),
      (facts.dataLossMigration, .dataLossMigration),
      (facts.releaseOrTag, .releaseOrTag),
      (facts.infrastructureBlastRadius, .infrastructureBlastRadius),
      (facts.crossRepositoryCoordination, .crossRepositoryCoordination),
      (facts.unresolvedDesignDebate, .unresolvedDesignDebate),
      (facts.unverifiable, .unverifiable),
    ] where triggered {
      reasons.insert(reason)
      required = .humanOwned
    }
    return required
  }

  private static func max(_ values: WorkComplexity...) -> WorkComplexity {
    values.max() ?? .simple
  }
}
