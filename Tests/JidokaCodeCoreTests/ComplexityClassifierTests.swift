import Testing

@testable import JidokaCodeCore

@Suite("Deterministic authoritative complexity classifier")
struct ComplexityClassifierTests {
  @Test("one fully evidenced localized workstream is simple")
  func simple() throws {
    let decision = try ComplexityClassifier.classify([
      report(.writer, .simple, facts())
    ])

    #expect(decision.classification == .simple)
    #expect(decision.permitsAutomatedImplementation)
    #expect(!decision.requiresPlanApproval)
    #expect(decision.version == "1")
  }

  @Test("two through four bounded workstreams are moderate", arguments: [2, 3, 4])
  func moderateBoundaries(count: Int) throws {
    let decision = try ComplexityClassifier.classify([
      report(.writer, .moderate, facts(workstreamCount: count))
    ])

    #expect(decision.classification == .moderate)
    #expect(decision.reasons.contains(.multipleWorkstreams))
    #expect(decision.permitsAutomatedImplementation)
  }

  @Test("five workstreams and every design trigger are complex")
  func complexTriggers() throws {
    let fixtures: [(ComplexityFacts, ComplexityReason)] = [
      (facts(workstreamCount: 5), .tooManyWorkstreams),
      (facts(publicAPI: true), .publicAPI),
      (facts(nonDestructiveSchema: true), .nonDestructiveSchema),
      (facts(crossModuleConcurrency: true), .crossModuleConcurrency),
      (facts(operationalRollback: true), .operationalRollback),
      (facts(designAlternatives: true), .designAlternatives),
      (facts(humanDecisionGap: true), .humanDecisionGap),
    ]
    for (fixture, reason) in fixtures {
      let decision = try ComplexityClassifier.classify([
        report(.writer, .complex, fixture)
      ])
      #expect(decision.classification == .complex)
      #expect(decision.reasons.contains(reason))
      #expect(decision.requiresPlanApproval)
      #expect(!decision.permitsAutomatedImplementation)
    }
  }

  @Test("every hard risk is human-owned and approval cannot bypass it")
  func humanOwnedTriggers() throws {
    let fixtures: [(ComplexityFacts, ComplexityReason)] = [
      (facts(securityOrSecretCore: true), .securityOrSecretCore),
      (facts(dataLossMigration: true), .dataLossMigration),
      (facts(releaseOrTag: true), .releaseOrTag),
      (facts(infrastructureBlastRadius: true), .infrastructureBlastRadius),
      (facts(crossRepositoryCoordination: true), .crossRepositoryCoordination),
      (facts(unresolvedDesignDebate: true), .unresolvedDesignDebate),
      (facts(unverifiable: true), .unverifiable),
    ]
    for (fixture, reason) in fixtures {
      let decision = try ComplexityClassifier.classify([
        report(.writer, .simple, fixture)
      ])
      #expect(decision.classification == .humanOwned)
      #expect(decision.reasons.contains(reason))
      #expect(decision.reasons.contains(.downgradeRejected))
      #expect(decision.isHumanOwned)
      #expect(!decision.requiresPlanApproval)
    }
  }

  @Test("unknown, missing evidence, or reporter disagreement is at least complex")
  func uncertaintyAndDisagreement() throws {
    let unknown = try ComplexityClassifier.classify([
      report(.writer, .unknown, facts())
    ])
    #expect(unknown.classification == .complex)
    #expect(unknown.reasons.contains(.unknownClassification))

    let missing = try ComplexityClassifier.classify([
      ComplexityReport(
        reporter: .writer,
        proposed: .simple,
        facts: facts(),
        evidence: []
      )
    ])
    #expect(missing.classification == .complex)
    #expect(missing.reasons.contains(.missingEvidence))

    let disagreement = try ComplexityClassifier.classify([
      report(.writer, .simple, facts()),
      report(.security, .complex, facts()),
    ])
    #expect(disagreement.classification == .complex)
    #expect(disagreement.disagreement)
    #expect(disagreement.reasons.contains(.reporterDisagreement))
  }

  @Test("a writer cannot downgrade reviewer facts or synthesis severity")
  func downgradeRejected() throws {
    let decision = try ComplexityClassifier.classify([
      report(.writer, .simple, facts()),
      report(.security, .simple, facts(securityOrSecretCore: true)),
      report(.synthesis, .moderate, facts(workstreamCount: 3)),
    ])

    #expect(decision.classification == .humanOwned)
    #expect(decision.downgradeRejectedReporters == [.security])
    #expect(decision.reports.map(\.reporter) == [.writer, .security, .synthesis])
  }

  @Test("decision digest binds classification, facts, reporters, reasons, and evidence")
  func decisionDigest() throws {
    let baseline = try ComplexityClassifier.classify([
      report(.writer, .simple, facts())
    ])
    let changedFacts = try ComplexityClassifier.classify([
      report(.writer, .complex, facts(publicAPI: true))
    ])
    let changedEvidence = try ComplexityClassifier.classify([
      ComplexityReport(
        reporter: .writer,
        proposed: .simple,
        facts: facts(),
        evidence: ["different evidence"]
      )
    ])
    let changedReporter = try ComplexityClassifier.classify([
      report(.security, .simple, facts())
    ])

    #expect(baseline.digest.wholeMatch(of: /^[0-9a-f]{64}$/) != nil)
    #expect(baseline.digest != changedFacts.digest)
    #expect(baseline.digest != changedEvidence.digest)
    #expect(baseline.digest != changedReporter.digest)
    #expect(
      baseline.digest
        == (try ComplexityClassifier.classify([
          report(.writer, .simple, facts())
        ])).digest
    )
  }

  @Test("missing, duplicate, and invalid reporter inputs fail closed")
  func invalidInputs() {
    #expect(throws: ComplexityClassifierError.missingReports) {
      try ComplexityClassifier.classify([])
    }
    #expect(throws: ComplexityClassifierError.duplicateReporter) {
      try ComplexityClassifier.classify([
        report(.writer, .simple, facts()),
        report(.writer, .simple, facts()),
      ])
    }
    #expect(throws: ComplexityClassifierError.invalidWorkstreamCount) {
      try ComplexityClassifier.classify([
        report(.writer, .simple, facts(workstreamCount: 0))
      ])
    }
  }

  private func report(
    _ reporter: PiWorkflowRole,
    _ proposed: WorkComplexity,
    _ facts: ComplexityFacts
  ) -> ComplexityReport {
    ComplexityReport(
      reporter: reporter,
      proposed: proposed,
      facts: facts,
      evidence: ["fixture evidence for \(reporter.rawValue)"]
    )
  }

  private func facts(
    workstreamCount: Int = 1,
    publicAPI: Bool = false,
    nonDestructiveSchema: Bool = false,
    crossModuleConcurrency: Bool = false,
    operationalRollback: Bool = false,
    designAlternatives: Bool = false,
    humanDecisionGap: Bool = false,
    securityOrSecretCore: Bool = false,
    dataLossMigration: Bool = false,
    releaseOrTag: Bool = false,
    infrastructureBlastRadius: Bool = false,
    crossRepositoryCoordination: Bool = false,
    unresolvedDesignDebate: Bool = false,
    unverifiable: Bool = false
  ) -> ComplexityFacts {
    ComplexityFacts(
      workstreamCount: workstreamCount,
      publicAPI: publicAPI,
      nonDestructiveSchema: nonDestructiveSchema,
      crossModuleConcurrency: crossModuleConcurrency,
      operationalRollback: operationalRollback,
      designAlternatives: designAlternatives,
      humanDecisionGap: humanDecisionGap,
      securityOrSecretCore: securityOrSecretCore,
      dataLossMigration: dataLossMigration,
      releaseOrTag: releaseOrTag,
      infrastructureBlastRadius: infrastructureBlastRadius,
      crossRepositoryCoordination: crossRepositoryCoordination,
      unresolvedDesignDebate: unresolvedDesignDebate,
      unverifiable: unverifiable
    )
  }
}
