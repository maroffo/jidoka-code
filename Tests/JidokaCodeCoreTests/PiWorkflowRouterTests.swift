import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Pi workflow routers preserve role, session, command, and safety boundaries")
struct PiWorkflowRouterTests {
  private let artifact = String(repeating: "a", count: 64)
  private let base = String(repeating: "0", count: 40)
  private let record = String(repeating: "b", count: 64)

  @Test("PR review keeps oldest-first narrative and sends synthesis only normalized role results")
  func pullRequestReview() async throws {
    let commits = commitNarrative()
    let digest = try PiPullRequestReviewRouter.commitNarrativeDigest(
      commits,
      baseSHA: base
    )
    let executor = ScriptedWorkflowExecutor { request in
      if request.role == .synthesis {
        #expect(request.normalizedRoleInputs.map(\.role) == [.architecture, .security, .test])
      } else {
        #expect(request.normalizedRoleInputs.isEmpty)
      }
      return PiWorkflowExecution(
        sessionID: "session-\(request.role.rawValue)",
        result: self.prResult(role: request.role, narrativeDigest: digest)
      )
    }
    let output = try await PiPullRequestReviewRouter(executor: executor).run(
      PiPullRequestReviewInput(
        jobID: "pr-review-1",
        artifactSHA256: artifact,
        baseSHA: base,
        restHeadSHA: commits.last!.sha,
        fetchedHeadSHA: commits.last!.sha,
        restCommitSHAs: commits.map(\.sha),
        fetchedCommitSHAs: commits.map(\.sha),
        commits: commits
      )
    )

    #expect(output.commitNarrativeSHA256 == digest)
    #expect(output.roleResults.map(\.role) == [.architecture, .security, .test])
    #expect(output.synthesis.domain == .synthesis)
    #expect(output.effectiveVerdict == "pass")
    #expect(output.effectiveSeverity == .none)
    #expect(
      await executor.recordedRequests().allSatisfy {
        $0.sessionDirective == .fresh
      })
  }

  @Test("PR narrative accepts a connected oldest-first fork and merge topology")
  func pullRequestMergeNarrative() async throws {
    let base = String(repeating: "1", count: 40)
    let left = String(repeating: "4", count: 40)
    let right = String(repeating: "5", count: 40)
    let merge = String(repeating: "6", count: 40)
    let commits = [
      PiCommitNarrativeEntry(
        ordinal: 0,
        sha: left,
        parentSHAs: [base],
        subject: "Left branch",
        patchSHA256: String(repeating: "4", count: 64)
      ),
      PiCommitNarrativeEntry(
        ordinal: 1,
        sha: right,
        parentSHAs: [base],
        subject: "Right branch",
        patchSHA256: String(repeating: "5", count: 64)
      ),
      PiCommitNarrativeEntry(
        ordinal: 2,
        sha: merge,
        parentSHAs: [left, right],
        subject: "Merge branches",
        patchSHA256: String(repeating: "6", count: 64)
      ),
    ]
    let digest = try PiPullRequestReviewRouter.commitNarrativeDigest(
      commits,
      baseSHA: base
    )
    let executor = ScriptedWorkflowExecutor { request in
      PiWorkflowExecution(
        sessionID: "merge-session-\(request.role.rawValue)",
        result: self.prResult(role: request.role, narrativeDigest: digest)
      )
    }
    let output = try await PiPullRequestReviewRouter(executor: executor).run(
      PiPullRequestReviewInput(
        jobID: "pr-review-merge",
        artifactSHA256: artifact,
        baseSHA: base,
        restHeadSHA: merge,
        fetchedHeadSHA: merge,
        restCommitSHAs: commits.map(\.sha),
        fetchedCommitSHAs: commits.map(\.sha),
        commits: commits
      )
    )
    #expect(output.commitNarrativeSHA256 == digest)

    let disconnected = PiCommitNarrativeEntry(
      ordinal: 2,
      sha: String(repeating: "7", count: 40),
      parentSHAs: [String(repeating: "8", count: 40)],
      subject: "Disconnected commit",
      patchSHA256: String(repeating: "7", count: 64)
    )
    #expect(throws: PiWorkflowRouterError.invalidCommitNarrative) {
      try PiPullRequestReviewRouter.commitNarrativeDigest(
        [commits[0], commits[1], disconnected],
        baseSHA: base
      )
    }
  }

  @Test("PR synthesis cannot downgrade an independent major finding")
  func pullRequestDowngrade() async throws {
    let commits = commitNarrative()
    let digest = try PiPullRequestReviewRouter.commitNarrativeDigest(
      commits,
      baseSHA: base
    )
    let executor = ScriptedWorkflowExecutor { request in
      let blocks = request.role == .security
      return PiWorkflowExecution(
        sessionID: "session-\(request.role.rawValue)",
        result: self.prResult(
          role: request.role,
          narrativeDigest: digest,
          verdict: blocks ? "block" : "pass",
          severity: blocks ? .major : .none
        )
      )
    }
    let output = try await PiPullRequestReviewRouter(executor: executor).run(
      PiPullRequestReviewInput(
        jobID: "pr-review-downgrade",
        artifactSHA256: artifact,
        baseSHA: base,
        restHeadSHA: commits[1].sha,
        fetchedHeadSHA: commits[1].sha,
        restCommitSHAs: commits.map(\.sha),
        fetchedCommitSHAs: commits.map(\.sha),
        commits: commits
      )
    )

    #expect(output.synthesis.verdict == "block")
    #expect(output.effectiveVerdict == "block")
    #expect(output.effectiveSeverity == .major)
  }

  @Test("head mismatch and reordered narrative stop before any model execution")
  func pullRequestPreconditions() async throws {
    let executor = ScriptedWorkflowExecutor { _ in
      throw PiWorkflowRouterError.executorFailure
    }
    let commits = commitNarrative()
    await #expect(throws: PiWorkflowRouterError.headMismatch) {
      try await PiPullRequestReviewRouter(executor: executor).run(
        PiPullRequestReviewInput(
          jobID: "pr-review-2",
          artifactSHA256: artifact,
          baseSHA: base,
          restHeadSHA: commits.last!.sha,
          fetchedHeadSHA: String(repeating: "f", count: 40),
          restCommitSHAs: commits.map(\.sha),
          fetchedCommitSHAs: commits.map(\.sha),
          commits: commits
        )
      )
    }
    #expect(await executor.recordedRequests().isEmpty)

    #expect(throws: PiWorkflowRouterError.invalidCommitNarrative) {
      try PiPullRequestReviewRouter.commitNarrativeDigest(
        commits.reversed(),
        baseSHA: base
      )
    }

    await #expect(throws: PiWorkflowRouterError.invalidCommitNarrative) {
      try await PiPullRequestReviewRouter(executor: executor).run(
        PiPullRequestReviewInput(
          jobID: "pr-review-stale-narrative",
          artifactSHA256: artifact,
          baseSHA: base,
          restHeadSHA: String(repeating: "3", count: 40),
          fetchedHeadSHA: String(repeating: "3", count: 40),
          restCommitSHAs: commits.map(\.sha),
          fetchedCommitSHAs: commits.map(\.sha),
          commits: commits
        )
      )
    }

    let head = commits[commits.count - 1]
    let truncated = PiCommitNarrativeEntry(
      ordinal: 0,
      sha: head.sha,
      parentSHAs: head.parentSHAs,
      subject: head.subject,
      patchSHA256: head.patchSHA256
    )
    await #expect(throws: PiWorkflowRouterError.invalidCommitNarrative) {
      try await PiPullRequestReviewRouter(executor: executor).run(
        PiPullRequestReviewInput(
          jobID: "pr-review-truncated-narrative",
          artifactSHA256: artifact,
          baseSHA: base,
          restHeadSHA: head.sha,
          fetchedHeadSHA: head.sha,
          restCommitSHAs: commits.map(\.sha),
          fetchedCommitSHAs: commits.map(\.sha),
          commits: [truncated]
        )
      )
    }

    let unrelated = [
      PiCommitNarrativeEntry(
        ordinal: 0,
        sha: commits[0].sha,
        parentSHAs: [String(repeating: "9", count: 40)],
        subject: commits[0].subject,
        patchSHA256: commits[0].patchSHA256
      ),
      commits[1],
    ]
    await #expect(throws: PiWorkflowRouterError.invalidCommitNarrative) {
      try await PiPullRequestReviewRouter(executor: executor).run(
        PiPullRequestReviewInput(
          jobID: "pr-review-unrelated-base",
          artifactSHA256: artifact,
          baseSHA: base,
          restHeadSHA: head.sha,
          fetchedHeadSHA: head.sha,
          restCommitSHAs: unrelated.map(\.sha),
          fetchedCommitSHAs: unrelated.map(\.sha),
          commits: unrelated
        )
      )
    }
    #expect(await executor.recordedRequests().isEmpty)
  }

  @Test("triage hard-risk flags override a model ready guess")
  func triageHardRail() async throws {
    let executor = ScriptedWorkflowExecutor { request in
      PiWorkflowExecution(
        sessionID: "triage-session",
        result: self.triageResult(
          verdict: "ready",
          hardRisks: [.securityOrSecretCore]
        )
      )
    }
    let output = try await PiIssueTriageRouter(executor: executor).run(
      PiIssueTriageInput(jobID: "triage-1", artifactSHA256: artifact)
    )

    #expect(output.result.verdict == "ready")
    #expect(output.effectiveVerdict == "human")
  }

  @Test("clean planning freezes canonical commands after exact fresh reviewer approval")
  func planningReady() async throws {
    let proposal = validCommandProposal()
    let executor = planningExecutor(
      writerProposal: { _ in proposal },
      roleComplexity: { _ in .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-1",
      artifactSHA256: artifact
    )

    #expect(output.disposition == .ready)
    #expect(output.rounds == 1)
    #expect(output.complexity.classification == .simple)
    #expect(output.frozenPlan?.commands.keys.sorted() == ["check"])
    let requests = await executor.recordedRequests()
    #expect(requests.count == 5)
    #expect(requests[0].role == .writer)
    #expect(requests[0].sessionDirective == .fresh)
    #expect(requests.dropFirst().allSatisfy { $0.sessionDirective == .fresh })
    #expect(requests[1].canonicalCommandDigests.count == 1)
    let candidateDigest = try #require(requests[1].frozenPlan?.digest)
    #expect(requests.dropFirst().allSatisfy { $0.frozenPlan?.digest == candidateDigest })
    #expect(requests[1].frozenPlan?.planningDecisionSHA256 == nil)
    #expect(output.frozenPlan?.planningDecisionSHA256 != nil)
    #expect(output.frozenPlan?.digest != candidateDigest)
    #expect(requests[1].frozenPlan?.planMarkdown == "# Plan\n")
    #expect(requests[1].frozenPlan?.commandOrder == ["check"])
    #expect(
      requests[4].normalizedRoleInputs.map(\.role) == [
        .writer, .architecture, .security, .test,
      ])
  }

  @Test("final plan identity binds exact role records and approval digests")
  func planningDecisionRecordBinding() async throws {
    func run(record: String) async throws -> PiPlanningOutput {
      let executor = planningExecutor(
        writerProposal: { _ in self.validCommandProposal() },
        roleComplexity: { _ in .simple },
        facts: { _ in self.facts() },
        synthesisVerdict: { _ in "pass" },
        findingSeverity: { _ in .none },
        recordDigest: { role in
          switch role {
          case .security: record
          case .writer: String(repeating: "1", count: 64)
          case .architecture: String(repeating: "2", count: 64)
          case .test: String(repeating: "3", count: 64)
          case .synthesis: String(repeating: "4", count: 64)
          case .triage: String(repeating: "5", count: 64)
          }
        }
      )
      return try await PiPlanningRouter(executor: executor).run(
        jobID: "planning-record-\(record.prefix(4))",
        artifactSHA256: artifact
      )
    }

    let first = try await run(record: String(repeating: "c", count: 64))
    let second = try await run(record: String(repeating: "d", count: 64))
    #expect(first.complexity.digest == second.complexity.digest)
    #expect(first.frozenPlan?.digest != second.frozenPlan?.digest)
    #expect(first.frozenPlan?.planningDecisionSHA256 != second.frozenPlan?.planningDecisionSHA256)

    let rejectedApproval = planningExecutor(
      writerProposal: { _ in self.validCommandProposal() },
      roleComplexity: { _ in .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none },
      approvedPlanDigest: { role, digest in
        role == .security ? String(repeating: "e", count: 64) : digest
      }
    )
    let rejected = try await PiPlanningRouter(executor: rejectedApproval).run(
      jobID: "planning-approval-mismatch",
      artifactSHA256: artifact
    )
    #expect(rejected.disposition == .blocked)
    #expect(rejected.engineFailures.contains("plan-or-command-digest-not-approved"))
  }

  @Test("reviewer disagreement is complex and waits for plan approval")
  func planningDisagreement() async throws {
    let executor = planningExecutor(
      writerProposal: { _ in self.validCommandProposal() },
      roleComplexity: { role in role == .security ? .complex : .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-2",
      artifactSHA256: artifact
    )

    #expect(output.disposition == .requiresApproval)
    #expect(output.complexity.classification == .complex)
    #expect(output.complexity.disagreement)
  }

  @Test("security facts stay human-owned even when writer and synthesis say simple")
  func planningHumanOwned() async throws {
    let executor = planningExecutor(
      writerProposal: { _ in self.validCommandProposal() },
      roleComplexity: { role in role == .security ? .humanOwned : .simple },
      facts: { role in
        self.facts(securityOrSecretCore: role == .security)
      },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-3",
      artifactSHA256: artifact
    )

    #expect(output.disposition == .humanOwned)
    #expect(output.complexity.classification == .humanOwned)
    #expect(output.frozenPlan == nil)
  }

  @Test("invalid command definitions return only to the same writer before review")
  func planningInvalidCommandRevision() async throws {
    let executor = planningExecutor(
      writerProposal: { round in
        if round < 3 {
          return ApprovedCommandProposal(
            id: "check",
            registryKind: .makeTargets,
            executableOrRepositoryScript: "bash",
            arguments: ["-c", "git push"],
            workingDirectory: ".",
            environmentOverrides: [:],
            timeoutSeconds: 30,
            rationale: "invalid fixture",
            sourceDigest: nil,
            approvedHookPath: nil
          )
        }
        return self.validCommandProposal()
      },
      roleComplexity: { _ in .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-4",
      artifactSHA256: artifact
    )
    let requests = await executor.recordedRequests()

    #expect(output.disposition == .ready)
    #expect(output.rounds == 3)
    #expect(requests.count == 7)
    #expect(requests[0].role == .writer)
    #expect(requests[1].role == .writer)
    #expect(requests[2].role == .writer)
    #expect(requests[1].sessionDirective == .resume("writer-session"))
    #expect(requests[2].engineFailures == ["command-definition-invalid"])
    #expect(requests.dropFirst(3).map(\.role) == [.architecture, .security, .test, .synthesis])
  }

  @Test("planning stops after exactly three unresolved review rounds")
  func planningRoundCeiling() async throws {
    let executor = planningExecutor(
      writerProposal: { _ in self.validCommandProposal() },
      roleComplexity: { _ in .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "revise" },
      findingSeverity: { role in role == .security ? .major : .none }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-5",
      artifactSHA256: artifact
    )
    let requests = await executor.recordedRequests()

    #expect(output.disposition == .blocked)
    #expect(output.rounds == 3)
    #expect(output.engineFailures.contains("planning-round-limit"))
    #expect(requests.count == 15)
    #expect(
      requests.filter { $0.role == .writer }.map(\.sessionDirective) == [
        .fresh, .resume("writer-session"), .resume("writer-session"),
      ])
    let reviewerSessions = await executor.sessionIDs(for: [.architecture, .security, .test])
    #expect(Set(reviewerSessions).count == 9)
  }

  @Test("an independent planning veto cannot be downgraded by synthesis")
  func planningReviewerVeto() async throws {
    let executor = planningExecutor(
      writerProposal: { _ in self.validCommandProposal() },
      roleComplexity: { _ in .simple },
      facts: { _ in self.facts() },
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none },
      reviewerVerdict: { $0 == .security ? "escalate" : "pass" }
    )
    let output = try await PiPlanningRouter(executor: executor).run(
      jobID: "planning-veto",
      artifactSHA256: artifact
    )

    #expect(output.disposition == .blocked)
    #expect(output.engineFailures.contains("role-veto"))
    #expect(output.rounds == 3)
  }

  @Test("orchestration executes only frozen IDs and reviews evidence after the writer")
  func orchestrationSuccess() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([validCommandProposal()])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let commandExecutor = ScriptedCommandExecutor { commandID, _, commandPlan in
      self.commandEvidence(
        commandID: commandID,
        digest: commandPlan.commands[commandID]!.definitionDigest,
        succeeded: true
      )
    }
    let output = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commandExecutor
    ).run(jobID: "orchestration-1", artifactSHA256: artifact, plan: plan)

    #expect(output.disposition == .succeeded)
    #expect(output.rounds == 1)
    #expect(output.commandEvidence.map(\.commandID) == ["check"])
    #expect(await commandExecutor.recordedCommandIDs() == ["check"])
    let requests = await executor.recordedRequests()
    #expect(requests.allSatisfy { $0.frozenPlan == plan })
    #expect(requests[1].commandEvidence.first?.commandID == "check")
    #expect(
      requests.last?.normalizedRoleInputs.map(\.role) == [
        .writer, .architecture, .security, .test,
      ])
  }

  @Test("an independent orchestration veto cannot be downgraded by synthesis")
  func orchestrationReviewerVeto() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([validCommandProposal()])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none },
      reviewerVerdict: { $0 == .security ? "block" : "pass" }
    )
    let commandExecutor = ScriptedCommandExecutor { commandID, _, commandPlan in
      self.commandEvidence(
        commandID: commandID,
        digest: commandPlan.commands[commandID]!.definitionDigest,
        succeeded: true
      )
    }
    let output = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commandExecutor
    ).run(jobID: "orchestration-veto", artifactSHA256: artifact, plan: plan)

    #expect(output.disposition == .blocked)
    #expect(output.engineFailures.contains("role-veto"))
  }

  @Test("a writer veto prevents every frozen command from executing")
  func orchestrationWriterVeto() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([validCommandProposal()])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none },
      writerVerdict: "block"
    )
    let commandExecutor = ScriptedCommandExecutor { _, _, _ in
      throw PiWorkflowRouterError.executorFailure
    }

    let output = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commandExecutor
    ).run(jobID: "orchestration-writer-veto", artifactSHA256: artifact, plan: plan)

    #expect(output.disposition == .blocked)
    #expect(output.engineFailures.contains("role-veto"))
    #expect(await commandExecutor.recordedCommandIDs().isEmpty)
  }

  @Test("orchestration rejects a candidate plan without complete planning approvals")
  func orchestrationRejectsCandidatePlan() async throws {
    let candidate = try ApprovedCommandCanonicalizer.candidate(
      [validCommandProposal()],
      artifactSHA256: artifact,
      planMarkdown: "# Plan\n"
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none }
    )
    let commandExecutor = ScriptedCommandExecutor { _, _, _ in
      throw PiWorkflowRouterError.executorFailure
    }

    await #expect(throws: PiWorkflowRouterError.invalidInput) {
      try await PiOrchestrationRouter(
        executor: executor,
        commandExecutor: commandExecutor
      ).run(jobID: "orchestration-candidate", artifactSHA256: artifact, plan: candidate)
    }
    #expect(await executor.recordedRequests().isEmpty)
    #expect(await commandExecutor.recordedCommandIDs().isEmpty)
  }

  @Test("the writer cannot select a subset of the frozen command plan")
  func orchestrationRejectsCommandSubset() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([
        validCommandProposal(), validCommandProposal(id: "test", target: "test"),
      ])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "pass" },
      findingSeverity: { _ in .none },
      writerCommandIDs: { Array($0.prefix(1)) }
    )
    let commandExecutor = ScriptedCommandExecutor { _, _, _ in
      throw PiWorkflowRouterError.executorFailure
    }

    await #expect(throws: PiWorkflowRouterError.unexpectedPayload) {
      try await PiOrchestrationRouter(
        executor: executor,
        commandExecutor: commandExecutor
      ).run(jobID: "orchestration-subset", artifactSHA256: artifact, plan: plan)
    }
    #expect(await commandExecutor.recordedCommandIDs().isEmpty)
  }

  @Test("a failed command prevents every later command in the frozen plan")
  func orchestrationStopsAfterFailure() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([
        validCommandProposal(), validCommandProposal(id: "test", target: "test"),
      ])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "block" },
      findingSeverity: { _ in .none }
    )
    let commandExecutor = ScriptedCommandExecutor { commandID, _, commandPlan in
      self.commandEvidence(
        commandID: commandID,
        digest: commandPlan.commands[commandID]!.definitionDigest,
        succeeded: false
      )
    }
    let output = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commandExecutor
    ).run(jobID: "orchestration-stop", artifactSHA256: artifact, plan: plan)

    #expect(output.disposition == .blocked)
    #expect(await commandExecutor.recordedCommandIDs() == ["check", "check", "check"])
  }

  @Test("failed verification remains blocked after three fix rounds")
  func orchestrationRoundCeiling() async throws {
    let plan = try makeFrozenPlan(
      ApprovedCommandCanonicalizer.canonicalize([validCommandProposal()])
    )
    let executor = orchestrationExecutor(
      synthesisVerdict: { _ in "block" },
      findingSeverity: { role in role == .security ? .major : .none }
    )
    let commandExecutor = ScriptedCommandExecutor { commandID, _, commandPlan in
      self.commandEvidence(
        commandID: commandID,
        digest: commandPlan.commands[commandID]!.definitionDigest,
        succeeded: false
      )
    }
    let output = try await PiOrchestrationRouter(
      executor: executor,
      commandExecutor: commandExecutor
    ).run(jobID: "orchestration-2", artifactSHA256: artifact, plan: plan)

    #expect(output.disposition == .blocked)
    #expect(output.rounds == 3)
    #expect(output.engineFailures.contains("orchestration-round-limit"))
    #expect(await commandExecutor.recordedCommandIDs() == ["check", "check", "check"])
    let requests = await executor.recordedRequests()
    #expect(
      requests.filter { $0.role == .writer }.map(\.sessionDirective) == [
        .fresh, .resume("orchestration-writer"), .resume("orchestration-writer"),
      ])
  }

  private func planningRecordDigest(_ role: PiWorkflowRole) -> String {
    switch role {
    case .writer: String(repeating: "b", count: 64)
    case .architecture: String(repeating: "c", count: 64)
    case .security: String(repeating: "d", count: 64)
    case .test: String(repeating: "e", count: 64)
    case .synthesis: String(repeating: "f", count: 64)
    case .triage: String(repeating: "a", count: 64)
    }
  }

  private func planningExecutor(
    writerProposal: @escaping @Sendable (Int) -> ApprovedCommandProposal,
    roleComplexity: @escaping @Sendable (PiWorkflowRole) -> WorkComplexity,
    facts: @escaping @Sendable (PiWorkflowRole) -> ComplexityFacts,
    synthesisVerdict: @escaping @Sendable (Int) -> String,
    findingSeverity: @escaping @Sendable (PiWorkflowRole) -> PiWorkflowReportSeverity,
    reviewerVerdict: @escaping @Sendable (PiWorkflowRole) -> String = { _ in "pass" },
    emptyWriterCommands: Bool = false,
    recordDigest: @escaping @Sendable (PiWorkflowRole) -> String = { role in
      switch role {
      case .writer: String(repeating: "b", count: 64)
      case .architecture: String(repeating: "c", count: 64)
      case .security: String(repeating: "d", count: 64)
      case .test: String(repeating: "e", count: 64)
      case .synthesis: String(repeating: "f", count: 64)
      case .triage: String(repeating: "a", count: 64)
      }
    },
    approvedPlanDigest: @escaping @Sendable (PiWorkflowRole, String?) -> String? = {
      role, digest in role == .writer ? nil : digest
    }
  ) -> ScriptedWorkflowExecutor {
    ScriptedWorkflowExecutor { request in
      let sessionID =
        request.role == .writer
        ? "writer-session"
        : "\(request.role.rawValue)-\(request.round)-\(UUID().uuidString)"
      let proposal =
        request.role == .writer && !emptyWriterCommands
        ? [writerProposal(request.round)] : []
      let approved = request.role == .writer ? [] : request.canonicalCommandDigests
      let severity = findingSeverity(request.role)
      let payload = PiPlanningPayload(
        verdict: request.role == .synthesis
          ? synthesisVerdict(request.round)
          : request.role == .writer ? "pass" : reviewerVerdict(request.role),
        severity: severity,
        summary: "\(request.role.rawValue) planning fixture",
        proposedComplexity: roleComplexity(request.role),
        classifierFacts: facts(request.role),
        evidence: ["evidence-\(request.role.rawValue)-\(request.round)"],
        findings: severity.rank >= PiWorkflowReportSeverity.major.rank
          ? [self.finding(.major)] : [],
        commandDefinitions: proposal,
        approvedCommandDigests: approved,
        approvedPlanDigest: approvedPlanDigest(request.role, request.frozenPlan?.digest),
        planMarkdown: request.role == .writer ? "# Plan\n" : ""
      )
      return PiWorkflowExecution(
        sessionID: sessionID,
        result: PiWorkflowRoleResult(
          workflow: .planning,
          role: request.role,
          artifactSHA256: self.artifact,
          approvedCommandIDs: [],
          payload: .planning(payload),
          recordSHA256: recordDigest(request.role)
        )
      )
    }
  }

  private func orchestrationExecutor(
    synthesisVerdict: @escaping @Sendable (Int) -> String,
    findingSeverity: @escaping @Sendable (PiWorkflowRole) -> PiWorkflowReportSeverity,
    reviewerVerdict: @escaping @Sendable (PiWorkflowRole) -> String = { _ in "pass" },
    writerVerdict: String = "pass",
    writerCommandIDs: @escaping @Sendable ([String]) -> [String] = { $0 }
  ) -> ScriptedWorkflowExecutor {
    ScriptedWorkflowExecutor { request in
      let sessionID =
        request.role == .writer
        ? "orchestration-writer"
        : "orchestration-\(request.role.rawValue)-\(request.round)-\(UUID().uuidString)"
      let severity = findingSeverity(request.role)
      let requested =
        request.role == .writer
        ? writerCommandIDs(request.frozenPlan?.commandOrder ?? []) : []
      return PiWorkflowExecution(
        sessionID: sessionID,
        result: PiWorkflowRoleResult(
          workflow: .orchestration,
          role: request.role,
          artifactSHA256: self.artifact,
          approvedCommandIDs: requested,
          payload: .orchestration(
            PiOrchestrationPayload(
              verdict: request.role == .synthesis
                ? synthesisVerdict(request.round)
                : request.role == .writer ? writerVerdict : reviewerVerdict(request.role),
              severity: severity,
              summary: "orchestration fixture",
              evidence: ["round-\(request.round)-evidence"],
              findings: severity.rank >= PiWorkflowReportSeverity.major.rank
                ? [self.finding(.major)] : [],
              changedPaths: request.role == .writer ? ["Sources/Feature.swift"] : [],
              requestedCommandIDs: requested
            )
          ),
          recordSHA256: self.record
        )
      )
    }
  }

  private func prResult(
    role: PiWorkflowRole,
    narrativeDigest: String,
    verdict: String = "pass",
    severity: PiWorkflowReportSeverity = .none
  ) -> PiWorkflowRoleResult {
    PiWorkflowRoleResult(
      workflow: .pullRequestReview,
      role: role,
      artifactSHA256: artifact,
      approvedCommandIDs: [],
      payload: .pullRequestReview(
        PiPRReviewPayload(
          verdict: verdict,
          severity: severity,
          summary: "review fixture",
          domain: role,
          commitNarrativeSHA256: narrativeDigest,
          evidence: ["exact commit narrative"],
          findings: []
        )
      ),
      recordSHA256: record
    )
  }

  private func triageResult(
    verdict: String,
    hardRisks: [TriageHardRiskFlag]
  ) -> PiWorkflowRoleResult {
    PiWorkflowRoleResult(
      workflow: .issueTriage,
      role: .triage,
      artifactSHA256: artifact,
      approvedCommandIDs: [],
      payload: .issueTriage(
        PiIssueTriagePayload(
          verdict: verdict,
          severity: hardRisks.isEmpty ? .none : .major,
          summary: "triage fixture",
          rubric: PiTriageRubric(
            specified: "specified",
            testable: "testable",
            bounded: "bounded",
            safe: "hard risk remains"
          ),
          hardRiskFlags: hardRisks,
          rationale: "deterministic hard-risk fixture",
          questions: [],
          complexityGuess: .simple
        )
      ),
      recordSHA256: record
    )
  }

  private func commitNarrative() -> [PiCommitNarrativeEntry] {
    let first = String(repeating: "1", count: 40)
    let second = String(repeating: "2", count: 40)
    return [
      PiCommitNarrativeEntry(
        ordinal: 0,
        sha: first,
        parentSHAs: [String(repeating: "0", count: 40)],
        subject: "plan first",
        patchSHA256: String(repeating: "c", count: 64)
      ),
      PiCommitNarrativeEntry(
        ordinal: 1,
        sha: second,
        parentSHAs: [first],
        subject: "implementation second",
        patchSHA256: String(repeating: "d", count: 64)
      ),
    ]
  }

  private func validCommandProposal(
    id: String = "check",
    target: String = "check"
  ) -> ApprovedCommandProposal {
    ApprovedCommandProposal(
      id: id,
      registryKind: .makeTargets,
      executableOrRepositoryScript: "make",
      arguments: [target],
      workingDirectory: ".",
      environmentOverrides: [:],
      timeoutSeconds: 120,
      rationale: "run the frozen repository check",
      sourceDigest: nil,
      approvedHookPath: nil
    )
  }

  private func facts(securityOrSecretCore: Bool = false) -> ComplexityFacts {
    ComplexityFacts(
      workstreamCount: 1,
      publicAPI: false,
      nonDestructiveSchema: false,
      crossModuleConcurrency: false,
      operationalRollback: false,
      designAlternatives: false,
      humanDecisionGap: false,
      securityOrSecretCore: securityOrSecretCore,
      dataLossMigration: false,
      releaseOrTag: false,
      infrastructureBlastRadius: false,
      crossRepositoryCoordination: false,
      unresolvedDesignDebate: false,
      unverifiable: false
    )
  }

  private func finding(_ severity: PiWorkflowFindingSeverity) -> PiWorkflowFinding {
    PiWorkflowFinding(
      severity: severity,
      path: "Sources/Feature.swift",
      line: 1,
      evidence: "fixture evidence",
      recommendation: "fix fixture"
    )
  }

  private func commandEvidence(
    commandID: String,
    digest: String,
    succeeded: Bool
  ) -> VerificationCommandEvidence {
    VerificationCommandEvidence(
      commandID: commandID,
      registryKind: .makeTargets,
      definitionDigest: digest,
      exitCode: succeeded ? 0 : 1,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      durationMilliseconds: 1,
      stdoutSHA256: String(repeating: "e", count: 64),
      stderrSHA256: String(repeating: "f", count: 64),
      stdoutExcerpt: succeeded ? "pass" : "failed",
      stderrExcerpt: "",
      repositoryHeadSHA: nil,
      approvedHookPath: nil,
      gitConfigurationDigest: nil
    )
  }
}

private actor ScriptedWorkflowExecutor: PiWorkflowExecuting {
  typealias Handler = @Sendable (PiWorkflowExecutionRequest) throws -> PiWorkflowExecution

  private let handler: Handler
  private var requests: [PiWorkflowExecutionRequest] = []
  private var sessions: [(PiWorkflowRole, String)] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func execute(_ request: PiWorkflowExecutionRequest) async throws -> PiWorkflowExecution {
    requests.append(request)
    let execution = try handler(request)
    sessions.append((request.role, execution.sessionID))
    return execution
  }

  func recordedRequests() -> [PiWorkflowExecutionRequest] {
    requests
  }

  func sessionIDs(for roles: Set<PiWorkflowRole>) -> [String] {
    sessions.filter { roles.contains($0.0) }.map(\.1)
  }
}

private actor ScriptedCommandExecutor: PiApprovedCommandExecuting {
  typealias Handler =
    @Sendable (String, String, FrozenCommandPlan) throws ->
    VerificationCommandEvidence

  private let handler: Handler
  private var commandIDs: [String] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func execute(
    commandID: String,
    expectedPlanDigest: String,
    plan: FrozenCommandPlan
  ) async throws -> VerificationCommandEvidence {
    commandIDs.append(commandID)
    return try handler(commandID, expectedPlanDigest, plan)
  }

  func recordedCommandIDs() -> [String] {
    commandIDs
  }
}
