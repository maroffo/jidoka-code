import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Progressive rollout authority")
struct RolloutAuthorityStoreTests {
  @Test("exact activation refuses another job's disposition without rewriting history")
  func existingDispositionRefusesAnotherExactJob() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let jobs = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let identity = LogicalJobIdentity(
      repositoryID: fixture.repositoryID, kind: .prReview,
      objectNodeID: "PR_fixture_rollout", revisionKey: String(repeating: "1", count: 40)
    )
    let creation = try await jobs.createJob(
      identity: identity, objectNumber: 17, contractVersionUsed: "pr-review-v1",
      priority: .prReview, firstStep: .review, now: fixture.now
    )
    guard case .created(let priorJob) = creation else {
      Issue.record("fixture must create the prior job")
      return
    }
    let disposition = try await jobs.disposition(for: identity)
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      _ = try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON, confirmedSHA256: preview.sha256,
        recomputedInput: input, authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(1)
      )
    }
    #expect(try await jobs.disposition(for: identity) == disposition)
    #expect(try await jobs.job(id: priorJob.id) == priorJob)
    #expect(try await jobs.job(id: fixture.jobID) == nil)
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("preview is read-only and exact activation is atomic")
  func previewAndActivation() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }

    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)
    #expect(preview.payload.effectEnvelope.currentStep == JobStepKind.review.rawValue)
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0
    )
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(try await fixture.database.scalarInt("SELECT COUNT(*) FROM jobs") == 0)

    let report = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    #expect(report.authorization.state == .active)
    #expect(report.authorization.previewSHA256 == preview.sha256)
    #expect(report.boundJobIDs == [fixture.jobID])
    #expect(report.remainingBudgets.jobs == 0)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
    #expect(
      try await fixture.database.scalarText(
        "SELECT active_rollout_authorization_id FROM app_settings"
      ) == fixture.authorizationID.uuidString.lowercased()
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT rollout_generation FROM jobs WHERE id = ?",
        bindings: [.text(fixture.jobID.uuidString.lowercased())]
      ) == 1
    )
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_job_bindings") == 1
    )
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorization_events")
        == 2
    )
    let replay = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(2)
    )
    #expect(replay.authorization.state == .active)
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 1)
    _ = try await fixture.authority.revoke(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "TEST_TERMINAL_REPLAY",
      now: fixture.now.addingTimeInterval(3)
    )
    await #expect(throws: RolloutAuthorityError.authorizationCollision) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: input,
        authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(4)
      )
    }
  }

  @Test("canonical preview rejects unknown fields and changed bytes")
  func canonicalPreviewIsStrict() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)

    var object = try #require(
      JSONSerialization.jsonObject(with: preview.canonicalJSON) as? [String: Any]
    )
    object["unknown"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(throws: RolloutAuthorityError.invalidCanonicalJSON) {
      try RolloutPreviewBuilder.parseCanonical(unknown)
    }

    let pretty = try JSONSerialization.data(
      withJSONObject: object.filter { $0.key != "unknown" },
      options: [.prettyPrinted, .sortedKeys]
    )
    #expect(throws: RolloutAuthorityError.invalidCanonicalJSON) {
      try RolloutPreviewBuilder.parseCanonical(pretty)
    }
  }

  @Test("activation rejects a confirmed digest that differs from canonical preview bytes")
  func activationRejectsPreviewDigestMismatch() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)

    await #expect(throws: RolloutAuthorityError.previewDigestMismatch) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: String(repeating: "f", count: 64),
        recomputedInput: input,
        authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(1)
      )
    }

    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("activation rejects a canonical preview at its exact expiry boundary")
  func activationRejectsExpiredPreview() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)
    let expiry = Date(
      timeIntervalSince1970: Double(input.expiresAtMilliseconds) / 1_000
    )

    await #expect(throws: RolloutAuthorityError.previewExpired) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: input,
        authorizationID: fixture.authorizationID,
        now: expiry
      )
    }

    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("preview rejects duplicate labels and lists larger than their budgets")
  func previewEffectListsFitBudgets() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.planningPreviewInput()
    let label = RolloutLabelDefinition(
      name: "agent:wip",
      color: "123abc",
      description: "Claimed by Jidoka Code"
    )
    let duplicateLabels = RolloutPreviewInput(
      policyVersion: input.policyVersion,
      releaseIdentity: input.releaseIdentity,
      scope: input.scope,
      budgets: input.budgets,
      inventory: input.inventory,
      missingLabels: [label, label],
      commands: input.commands,
      jobBinding: input.jobBinding,
      createdAtMilliseconds: input.createdAtMilliseconds,
      expiresAtMilliseconds: input.expiresAtMilliseconds
    )
    #expect(throws: RolloutAuthorityError.invalidLabelDefinition) {
      try RolloutPreviewBuilder.make(duplicateLabels)
    }
    #expect(throws: RolloutAuthorityError.invalidEffectEnvelope) {
      try RolloutPreviewBuilder.effectEnvelope(
        stage: input.scope.stage,
        currentStep: JobStepKind.claimReady.rawValue,
        budgets: input.budgets,
        missingLabelCount: input.budgets.labelWrites + 1,
        commandCount: 0
      )
    }
    #expect(throws: RolloutAuthorityError.invalidEffectEnvelope) {
      try RolloutPreviewBuilder.effectEnvelope(
        stage: input.scope.stage,
        currentStep: JobStepKind.claimReady.rawValue,
        budgets: input.budgets,
        missingLabelCount: 0,
        commandCount: input.budgets.approvedCommands + 1
      )
    }
  }

  @Test("generated review activation cannot invent an unlinked child job")
  func generatedReviewRequiresDurableChild() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput(stage: .generatedPRReview)
    let preview = try await fixture.authority.preview(input: input)

    await #expect(throws: RolloutAuthorityError.invalidJobBinding) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: input,
        authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(1)
      )
    }
    #expect(try await fixture.database.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
  }

  @Test("database lease triggers reject an unbound quarantined generated review")
  func repositoryLeaseRequiresRolloutBinding() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let seed = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let parentRevision = String(repeating: "9", count: 64)
    guard
      case .created = try await seed.createJob(
        id: fixture.jobID,
        identity: LogicalJobIdentity(
          repositoryID: fixture.repositoryID,
          kind: .issueImplementation,
          objectNodeID: "I_fixture_rollout",
          revisionKey: parentRevision
        ),
        objectNumber: 17,
        contractVersionUsed: "implementation-v1",
        priority: .issueImplementation,
        firstStep: .orchestrate,
        now: fixture.now
      )
    else {
      Issue.record("parent rollout job was unexpectedly suppressed")
      return
    }
    let input = try await fixture.missingExecutionPreviewInput()
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    try await fixture.database.execute(
      "UPDATE jobs SET state = 'reconciling', current_step = 4, current_step_kind = 'qa' WHERE id = ?",
      bindings: [.text(fixture.jobID.uuidString.lowercased())]
    )
    let childID = UUID()
    let childRevision = String(repeating: "8", count: 40)
    guard
      case .created = try await DurableJobStore(
        database: fixture.database,
        enforceRolloutAuthority: true
      ).createQuarantinedGeneratedReviewJob(
        id: childID,
        parentJobID: fixture.jobID,
        identity: LogicalJobIdentity(
          repositoryID: fixture.repositoryID,
          kind: .prReview,
          objectNodeID: "PR_generated_quarantine",
          revisionKey: childRevision
        ),
        objectNumber: 18,
        contractVersionUsed: "generated-review-v1",
        now: fixture.now.addingTimeInterval(2)
      )
    else {
      Issue.record("generated review was unexpectedly suppressed")
      return
    }

    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.database.execute(
        """
        INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
        VALUES (?, ?, 1, ?, 1)
        """,
        bindings: [
          .text(fixture.repositoryID.uuidString.lowercased()),
          .text(childID.uuidString.lowercased()),
          .real(fixture.now.addingTimeInterval(3).timeIntervalSince1970),
        ]
      )
    }
    #expect(
      try await fixture.database.execute(
        """
        INSERT INTO repository_leases(repository_id, job_id, generation, heartbeat, active)
        VALUES (?, ?, 1, ?, 1)
        """,
        bindings: [
          .text(fixture.repositoryID.uuidString.lowercased()),
          .text(fixture.jobID.uuidString.lowercased()),
          .real(fixture.now.addingTimeInterval(3).timeIntervalSince1970),
        ]
      ) == 1
    )
    try await fixture.database.execute(
      "UPDATE repository_leases SET active = 0 WHERE repository_id = ?",
      bindings: [.text(fixture.repositoryID.uuidString.lowercased())]
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.database.execute(
        """
        UPDATE repository_leases SET job_id = ?, generation = generation + 1,
          heartbeat = ?, active = 1 WHERE repository_id = ?
        """,
        bindings: [
          .text(childID.uuidString.lowercased()),
          .real(fixture.now.addingTimeInterval(4).timeIntervalSince1970),
          .text(fixture.repositoryID.uuidString.lowercased()),
        ]
      )
    }
  }

  @Test("execution activation cannot invent a job beyond the planning checkpoint")
  func executionRequiresDurablePlannedJob() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.missingExecutionPreviewInput()
    let preview = try await fixture.authority.preview(input: input)

    await #expect(throws: RolloutAuthorityError.invalidJobBinding) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: input,
        authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(1)
      )
    }
    #expect(try await fixture.database.scalarInt("SELECT COUNT(*) FROM jobs") == 0)
  }

  @Test("exact execution evaluates only its bound waiting-human job")
  func exactExecutionDispatchesWaitingApproval() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let jobs = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let created = try await jobs.createJob(
      id: fixture.jobID,
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_fixture_rollout",
        revisionKey: "claim-1"
      ),
      objectNumber: 17,
      contractVersionUsed: "implementation-v1",
      priority: .issueImplementation,
      firstStep: .claimReady,
      now: fixture.now
    )
    guard case .created = created else {
      Issue.record("waiting implementation job was unexpectedly suppressed")
      return
    }
    #expect(
      try await fixture.database.execute(
        "UPDATE jobs SET state = 'waitingHuman', current_step = 2, current_step_kind = 'publishPlan' WHERE id = ?",
        bindings: [.text(fixture.jobID.uuidString.lowercased())]
      ) == 1
    )
    let input = try await fixture.waitingExecutionPreviewInput()
    let coordinator = try await fixture.coordinator(workflowMode: .intentionalBlock)
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now.addingTimeInterval(2))
    )

    let finalJob = try #require(try await jobs.job(id: fixture.jobID))
    #expect(finalJob.state == .blocked)
    #expect(
      try await jobs.transitions(jobID: fixture.jobID).contains {
        $0.eventKey == "rollout-test:approval-fresh"
      }
    )
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).authorization.state == .settled
    )
  }

  @Test("stale approval checkpoints into a separately authorized planning step")
  func staleApprovalStopsAtPlanningBoundary() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let jobs = DurableJobStore(
      database: fixture.database,
      enforceApplicationDispatchGate: true,
      enforceRolloutAuthority: true
    )
    let seed = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let created = try await seed.createJob(
      id: fixture.jobID,
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_fixture_rollout",
        revisionKey: "claim-1"
      ),
      objectNumber: 17,
      contractVersionUsed: "implementation-v1",
      priority: .issueImplementation,
      firstStep: .claimReady,
      now: fixture.now
    )
    guard case .created = created else {
      Issue.record("waiting implementation job was unexpectedly suppressed")
      return
    }
    #expect(
      try await fixture.database.execute(
        "UPDATE jobs SET state = 'waitingHuman', current_step = 2, current_step_kind = 'publishPlan' WHERE id = ?",
        bindings: [.text(fixture.jobID.uuidString.lowercased())]
      ) == 1
    )
    let input = try await fixture.waitingExecutionPreviewInput()
    let coordinator = try await fixture.coordinator(workflowMode: .intentionalBlock)
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    let stale = try await jobs.transition(
      jobID: fixture.jobID,
      eventKey: "rollout-test:approval-stale",
      event: .approvalStale,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(2),
        reason: "approved input changed before execution"
      )
    )
    let queued: JobRecord =
      switch stale {
      case .applied(let job), .duplicate(let job): job
      }
    _ = try await jobs.transition(
      jobID: queued.id,
      eventKey: "rollout-test:stale-lease",
      event: .acquireLease,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(3), reason: "consume stale approval"
      )
    )
    _ = try await jobs.transition(
      jobID: queued.id,
      eventKey: "rollout-test:stale-inputs",
      event: .inputsValidated,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(3), reason: "validate stale approval input"
      )
    )
    _ = try await jobs.transition(
      jobID: queued.id,
      eventKey: "rollout-test:stale-select",
      event: .selectLocalStep,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(3), reason: "select approval removal"
      )
    )
    _ = try await jobs.transition(
      jobID: queued.id,
      eventKey: "rollout-test:stale-readback",
      event: .mutationNeedsAttribution,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(3), reason: "approval removal attributed"
      )
    )
    try await jobs.appendCompletedStep(
      jobID: queued.id,
      ordinal: 3,
      kind: .consumeStaleApproval,
      inputDigest: String(repeating: "c", count: 64),
      outputDigest: String(repeating: "e", count: 64),
      mutationID: "fixture-intent",
      acceptanceEvidence: "stale-approval-consumed",
      now: fixture.now.addingTimeInterval(3)
    )
    let checkpointed = try await jobs.transition(
      jobID: queued.id,
      eventKey: "rollout-test:stale-checkpoint",
      event: .phaseCheckpoint,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(4),
        reason: "stale approval consumed at planning boundary",
        nextStep: .replan
      )
    )
    let checkpointedJob: JobRecord =
      switch checkpointed {
      case .applied(let job), .duplicate(let job): job
      }
    #expect(checkpointedJob.state == .queued)
    #expect(checkpointedJob.currentStepKind == .replan)
    #expect(try await jobs.activeLeases().isEmpty)
    await #expect(throws: DurableJobStoreError.rolloutAuthorityRequired) {
      _ = try await jobs.transition(
        jobID: queued.id,
        eventKey: "rollout-test:replan-lease-denied",
        event: .acquireLease,
        context: JobTransitionContext(
          now: fixture.now.addingTimeInterval(5),
          reason: "execution authority cannot launch planning"
        )
      )
    }

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now.addingTimeInterval(6))
    )
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .settled)
    #expect(try await jobs.job(id: queued.id)?.state == .queued)
    #expect(try await jobs.job(id: queued.id)?.currentStepKind == .replan)
  }

  @Test("planning authority cannot cross the durable simple-plan boundary")
  func planningAuthorityStopsAtOrchestration() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.planningPreviewInput()
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    #expect(
      try await fixture.database.execute(
        """
        UPDATE jobs
        SET state = 'queued', current_step = current_step + 1,
            current_step_kind = 'orchestrate', updated_at = ?
        WHERE id = ?
        """,
        bindings: [
          .real(fixture.now.addingTimeInterval(2).timeIntervalSince1970),
          .text(fixture.jobID.uuidString.lowercased()),
        ]
      ) == 1
    )

    let jobs = DurableJobStore(
      database: fixture.database,
      enforceApplicationDispatchGate: true,
      enforceRolloutAuthority: true
    )
    await #expect(throws: DurableJobStoreError.rolloutAuthorityRequired) {
      try await jobs.transition(
        jobID: fixture.jobID,
        eventKey: "planning-boundary-lease-denied",
        event: .acquireLease,
        context: JobTransitionContext(
          now: fixture.now.addingTimeInterval(3),
          reason: "planning authority stops before orchestration"
        )
      )
    }

    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        _ = try await fixture.authority.reserveGitHubRead(
          RolloutGitHubReadEffect(
            operation: .issue(
              owner: "fixture-owner",
              repository: "fixture-repository",
              number: 17
            ),
            maximumResponseBytes: 4_096,
            context: context
          ),
          now: fixture.now.addingTimeInterval(3)
        )
      }
    }
    #expect(try await fixture.database.scalarInt("SELECT COUNT(*) FROM repository_leases") == 0)
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_effect_reservations")
        == 0
    )
  }

  @Test("execution start is not misreported as a completed stage")
  func executionStartIsNotCompletion() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    _ = try await fixture.missingExecutionPreviewInput()
    let jobs = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let created = try await jobs.createJob(
      id: fixture.jobID,
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .issueImplementation,
        objectNodeID: "I_fixture_rollout",
        revisionKey: String(repeating: "9", count: 64)
      ),
      objectNumber: 17,
      contractVersionUsed: "implementation-v1",
      priority: .issueImplementation,
      firstStep: .orchestrate,
      now: fixture.now
    )
    guard case .created = created else {
      Issue.record("planned execution job was unexpectedly suppressed")
      return
    }
    let coordinator = try await fixture.coordinator(
      workflowMode: .intentionalBlock,
      newDispatchAllowed: { false }
    )
    let input = try await fixture.missingExecutionPreviewInput()
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )

    await coordinator.run(
      pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now.addingTimeInterval(2))
    )

    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .active)
    #expect(try await jobs.job(id: fixture.jobID)?.state == .queued)
    #expect(status.events.allSatisfy { $0.kind != .settled })
  }

  @Test("activation rejects every stale preview digest")
  func activationRejectsDrift() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)
    let drifted = try await fixture.previewInput(githubReadRequests: 9)

    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: drifted,
        authorizationID: fixture.authorizationID,
        now: fixture.now.addingTimeInterval(1)
      )
    }
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0
    )
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("configuration drift fails and pauses the active lane before another effect")
  func activeConfigurationDriftFailsClosed() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    let configuration = ConfigurationStore(database: fixture.database)
    try await configuration.upsertRepository(
      RepositoryConfiguration(
        id: fixture.repositoryID,
        nodeID: "R_fixture_rollout",
        owner: "fixture-owner",
        name: "fixture-repository",
        defaultBranch: "main",
        reviewEnabled: false,
        triageEnabled: false,
        implementationEnabled: false,
        enabled: true
      ),
      now: fixture.now.addingTimeInterval(2)
    )

    await #expect(throws: RolloutAuthorityError.previewDrift) {
      _ = try await fixture.authority.schedulerAdmission(
        now: fixture.now.addingTimeInterval(3)
      )
    }
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .failed)
    #expect(status.authorization.terminalReason == "CONFIGURATION_DRIFT")
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(
      try await fixture.database.scalarText(
        "SELECT active_rollout_authorization_id FROM app_settings"
      ) == nil
    )
  }

  @Test("finite activation requires a same-stage exact receipt")
  func finitePromotionRequiresExactReceipt() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.finitePreviewInput()
    let preview = try await fixture.authority.preview(input: input)

    await #expect(throws: RolloutAuthorityError.finitePromotionRequired) {
      try await fixture.authority.activate(
        approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256,
        recomputedInput: input,
        now: fixture.now.addingTimeInterval(10)
      )
    }
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0
    )
  }

  @Test("first finite window admits only its closed future predicate and uses operational expiry")
  func finiteFuturePredicateIsBounded() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let coordinator = try await fixture.coordinator(workflowMode: .intentionalBlock)
    try await fixture.activate()
    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    let input = try await fixture.finitePreviewInput()
    let preview = try await fixture.authority.preview(input: input)
    let authorizationID = UUID()
    let report = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: authorizationID,
      now: fixture.now.addingTimeInterval(10)
    )
    let window = try #require(input.scope.finiteWindow)
    #expect(report.authorization.expiresAtMilliseconds == window.expiresAtMilliseconds)
    #expect(report.authorization.expiresAtMilliseconds > input.expiresAtMilliseconds)

    let futureNodeID = "PR_future_18"
    let futureRevision = String(repeating: "3", count: 40)
    let futureDigest = try RolloutPreviewBuilder.futureCandidateSHA256(
      scope: input.scope,
      nodeID: futureNodeID,
      number: 18,
      revisionKey: futureRevision
    )
    let jobs = DurableJobStore(database: fixture.database, enforceRolloutAuthority: true)
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .prReview,
        objectNodeID: futureNodeID,
        revisionKey: futureRevision
      ),
      objectNumber: 18,
      contractVersionUsed: "pr-review-v1",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now.addingTimeInterval(11),
      requiresDispatchEligibility: true,
      rolloutBinding: RolloutJobCreationBinding(
        authorizationID: authorizationID.uuidString.lowercased(),
        workflowStage: .prReview,
        canonicalInputSHA256: futureDigest
      )
    )
    guard case .created(let futureJob) = created else {
      Issue.record("future candidate was unexpectedly suppressed")
      return
    }
    try await fixture.setJob(
      id: futureJob.id,
      state: .runningPi,
      currentStep: 0,
      kind: .review
    )
    #expect(futureJob.identity.objectNodeID == futureNodeID)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM rollout_window_candidates WHERE authorization_id = ?",
        bindings: [.text(authorizationID.uuidString.lowercased())]
      ) == 1
    )

    let artifactSHA256 = String(repeating: "e", count: 64)
    let narrativeSHA256 = String(repeating: "f", count: 64)
    let provider = RolloutProviderEffect(
      jobID: futureJob.id,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      runNonce: GitHubMarkerCodec.sha256(Data("future-provider".utf8)),
      artifactSHA256: artifactSHA256,
      narrativeSHA256: narrativeSHA256,
      planSHA256: nil,
      resourceSHA256: RolloutCanonicalJSON.sha256(
        Data("\(String(repeating: "a", count: 64))|\(PiTUIResourceCatalog.manifestSHA256)".utf8)
      ),
      profileSHA256: RolloutCanonicalJSON.sha256(
        Data("openai-codex/gpt-5.6-sol:max".utf8)
      ),
      sessionDirectiveSHA256: String(repeating: "d", count: 64)
    )
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: futureJob.id))
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        _ = try await fixture.authority.reserveProvider(
          provider,
          now: fixture.now.addingTimeInterval(12)
        )
      }
    }
    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.freezeJobInputSnapshot(
        RolloutJobInputSnapshot(
          jobID: futureJob.id,
          canonicalInputSHA256: artifactSHA256,
          narrativeSHA256: narrativeSHA256,
          baseSHA: String(repeating: "2", count: 40)
        ),
        now: fixture.now.addingTimeInterval(13)
      )
      _ = try await fixture.authority.reserveProvider(
        provider,
        now: fixture.now.addingTimeInterval(14)
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM rollout_job_input_snapshots WHERE job_id = ?",
        bindings: [.text(futureJob.id.uuidString.lowercased())]
      ) == 1
    )

    let outsideRevision = String(repeating: "4", count: 40)
    await #expect(throws: DurableJobStoreError.rolloutAuthorityRequired) {
      _ = try await jobs.createJob(
        identity: LogicalJobIdentity(
          repositoryID: fixture.repositoryID,
          kind: .prReview,
          objectNodeID: "PR_outside_22",
          revisionKey: outsideRevision
        ),
        objectNumber: 22,
        contractVersionUsed: "pr-review-v1",
        priority: .prReview,
        firstStep: .review,
        now: fixture.now.addingTimeInterval(12),
        requiresDispatchEligibility: true,
        rolloutBinding: RolloutJobCreationBinding(
          authorizationID: authorizationID.uuidString.lowercased(),
          workflowStage: .prReview,
          canonicalInputSHA256: String(repeating: "f", count: 64)
        )
      )
    }
  }

  @Test("effect reservations consume a finite cap and remain immutable")
  func reservationsConsumeCap() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )

    for ordinal in 0..<4 {
      let request = fixture.providerRequest(ordinal: ordinal)
      let first = try await fixture.authority.reserveEffect(
        request,
        reservationID: fixture.reservationIDs[ordinal],
        now: fixture.now.addingTimeInterval(2)
      )
      let replay = try await fixture.authority.reserveEffect(
        request,
        reservationID: UUID(),
        now: fixture.now.addingTimeInterval(2)
      )
      #expect(replay.id == first.id)
      if ordinal == 0 {
        await #expect(throws: SQLiteStoreError.self) {
          try await fixture.database.execute(
            "UPDATE rollout_effect_reservations SET updated_at_ms = updated_at_ms + 1 WHERE id = ?",
            bindings: [.text(first.id)]
          )
        }
      }
      _ = try await fixture.authority.settleReservation(
        id: first.id,
        attributed: false,
        evidenceSHA256: String(repeating: "e", count: 64),
        now: fixture.now.addingTimeInterval(3)
      )
    }
    await #expect(throws: RolloutAuthorityError.budgetExceeded(.providerSession)) {
      try await fixture.authority.reserveEffect(
        fixture.providerRequest(ordinal: 4),
        now: fixture.now.addingTimeInterval(4)
      )
    }
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).remainingBudgets.providerSessions == 0
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM rollout_authorization_usage WHERE authorization_id = ?",
        bindings: [.text(fixture.authorizationID.uuidString.lowercased())]
      ) == 5
    )
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT provider_sessions FROM rollout_authorization_usage
        WHERE authorization_id = ? ORDER BY sequence DESC LIMIT 1
        """,
        bindings: [.text(fixture.authorizationID.uuidString.lowercased())]
      ) == 4
    )
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'trigger' AND name LIKE 'rollout_%reservations_%'
          AND upper(sql) LIKE '%SUM(%'
        """
      ) == 0
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.database.execute(
        "UPDATE rollout_authorization_budgets SET provider_sessions = 5"
      )
    }
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'trigger' AND name IN (
          'rollout_effect_reservations_updated_at_monotonic',
          'rollout_scope_read_reservations_updated_at_monotonic',
          'rollout_readback_reservations_updated_at_monotonic',
          'rollout_git_readback_reservations_updated_at_monotonic'
        )
        """
      ) == 4
    )
    await #expect(throws: SQLiteStoreError.self) {
      try await fixture.database.execute("DELETE FROM rollout_effect_reservations")
    }
  }

  @Test("usage INSERT cannot reset a consumed cap, skip sequence or invent a source")
  func usageInsertCannotForgeBudget() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    for ordinal in 0..<4 {
      _ = try await fixture.authority.reserveEffect(
        fixture.providerRequest(ordinal: ordinal),
        now: fixture.now.addingTimeInterval(2)
      )
    }
    // These are disposable fixture writes exercising the database's future-writer boundary.
    // All non-provider counters stay unchanged, isolating the reset of the consumed cap.
    for (sequence, source, consumed) in [
      (5, "forged-reset", 0), (6, "forged-gap", 4),
      (5, "forged-source", 4),
    ] {
      await #expect(throws: SQLiteStoreError.self) {
        try await fixture.database.execute(
          """
          INSERT INTO rollout_authorization_usage
          SELECT authorization_id, ?, 'effect', ?, github_read_requests,
            github_read_pages, github_read_bytes, git_remote_reads, ?, approved_commands,
            marker_parts, label_writes, branch_creates, pull_request_creates,
            github_sends, git_sends, created_at_ms
          FROM rollout_authorization_usage WHERE sequence = 4
          """,
          bindings: [.integer(Int64(sequence)), .text(source), .integer(Int64(consumed))]
        )
      }
    }
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorization_usage") == 5)
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).remainingBudgets.providerSessions == 0
    )
    await #expect(throws: RolloutAuthorityError.budgetExceeded(.providerSession)) {
      try await fixture.authority.reserveEffect(
        fixture.providerRequest(ordinal: 4), now: fixture.now.addingTimeInterval(3)
      )
    }
  }

  @Test("usage ledger refuses every single-fault forgery of a seed or append row")
  func usageLedgerRefusesSingleFaultForgeries() async throws {
    // `usageInsertCannotForgeBudget` proves the gate exists; this test proves each of
    // its conjuncts is load-bearing. A row that is wrong in several ways at once cannot
    // say which predicate refused it, so every forgery below is the exact honest row
    // with one field changed. Honest sources are consumed by their own AFTER INSERT
    // triggers in the same statement, so handing a single-fault row to the gate needs
    // those test-database triggers lifted first; they are restored before the end.
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let authorizationID = fixture.authorizationID.uuidString.lowercased()
    let counters = [
      "github_read_requests", "github_read_pages", "github_read_bytes", "git_remote_reads",
      "provider_sessions", "approved_commands", "marker_parts", "label_writes",
      "branch_creates", "pull_request_creates", "github_sends", "git_sends",
    ]
    func usageCount() async throws -> Int64? {
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM rollout_authorization_usage WHERE authorization_id = ?",
        bindings: [.text(authorizationID)]
      )
    }
    func insertUsage(
      sequence: Int64, kind: String, sourceID: String,
      totals: [String: Int64], createdAtMilliseconds: Int64
    ) async throws {
      let placeholders = counters.map { _ in "?" }.joined(separator: ", ")
      try await fixture.database.execute(
        """
        INSERT INTO rollout_authorization_usage(
          authorization_id, sequence, source_kind, source_id,
          \(counters.joined(separator: ", ")), created_at_ms
        ) VALUES (?, ?, ?, ?, \(placeholders), ?)
        """,
        bindings: [.text(authorizationID), .integer(sequence), .text(kind), .text(sourceID)]
          + counters.map { .integer(totals[$0] ?? 0) } + [.integer(createdAtMilliseconds)]
      )
    }
    func integers(_ sql: String, bindings: [SQLiteValue]) async throws -> [String: Int64] {
      let rows = try await fixture.database.query(sql, bindings: bindings)
      let row = try #require(rows.first)
      var values: [String: Int64] = [:]
      for column in row.columns {
        if case .integer(let integer)? = row[column] { values[column] = integer }
      }
      return values
    }
    typealias Forgery = (
      label: String, sequence: Int64, kind: String, sourceID: String,
      totals: [String: Int64], createdAtMilliseconds: Int64
    )
    func expectRefused(_ forgeries: [Forgery], leaving expectedCount: Int64) async throws {
      for forgery in forgeries {
        await #expect(throws: SQLiteStoreError.self, "\(forgery.label)") {
          try await insertUsage(
            sequence: forgery.sequence, kind: forgery.kind, sourceID: forgery.sourceID,
            totals: forgery.totals, createdAtMilliseconds: forgery.createdAtMilliseconds
          )
        }
        #expect(try await usageCount() == expectedCount, "\(forgery.label)")
      }
    }

    // Seed branch: the honest seed trigger is the only writer of sequence 0 and runs in
    // the same transaction as the authorization row, so a forged seed can only be tried
    // by replacing that trigger. Each replacement emits the honest seed with one field
    // changed; activation must then fail atomically and leave no authorization behind.
    typealias SeedFault = (
      label: String, sequence: String, kind: String, sourceID: String, counter: String?,
      createdAt: String
    )
    var seedFaults: [SeedFault] = [
      ("seed sequence", "1", "'activation'", "NEW.id", nil, "NEW.activated_at_ms"),
      ("seed source_kind", "0", "'effect'", "NEW.id", nil, "NEW.activated_at_ms"),
      ("seed source_id", "0", "'activation'", "'forged-seed'", nil, "NEW.activated_at_ms"),
      ("seed created_at_ms", "0", "'activation'", "NEW.id", nil, "NEW.activated_at_ms + 1"),
    ]
    for counter in counters {
      seedFaults.append(
        ("seed \(counter)", "0", "'activation'", "NEW.id", counter, "NEW.activated_at_ms"))
    }
    try await fixture.withTriggersLifted(["rollout_authorization_usage_seed"]) {
      for fault in seedFaults {
        let values = counters.map { $0 == fault.counter ? "1" : "0" }.joined(separator: ", ")
        try await fixture.database.execute(
          """
          CREATE TRIGGER test_forged_usage_seed
          AFTER INSERT ON rollout_authorizations
          BEGIN
            INSERT INTO rollout_authorization_usage(
              authorization_id, sequence, source_kind, source_id,
              \(counters.joined(separator: ", ")), created_at_ms
            ) VALUES (
              NEW.id, \(fault.sequence), \(fault.kind), \(fault.sourceID), \(values),
              \(fault.createdAt)
            );
          END
          """
        )
        await #expect(throws: SQLiteStoreError.self, "\(fault.label)") {
          try await fixture.activate()
        }
        #expect(
          try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations")
            == 0, "\(fault.label)")
        #expect(try await usageCount() == 0, "\(fault.label)")
        try await fixture.database.execute("DROP TRIGGER test_forged_usage_seed")
      }
    }
    // With the honest seed restored, activation writes the exact zero row.
    try await fixture.activate()
    #expect(try await usageCount() == 1)

    // Append branch: with the effect append lifted, reservations leave unconsumed sources.
    try await fixture.withTriggersLifted(["rollout_effect_reservations_usage_append"]) {
      let first = try await fixture.authority.reserveEffect(
        fixture.providerRequest(ordinal: 0),
        reservationID: fixture.reservationIDs[0],
        now: fixture.now.addingTimeInterval(2)
      )
      let second = try await fixture.authority.reserveEffect(
        fixture.providerRequest(ordinal: 1),
        reservationID: fixture.reservationIDs[1],
        now: fixture.now.addingTimeInterval(3)
      )
      #expect(try await usageCount() == 1)
      func exactAppend(
        of sourceID: String, after previous: [String: Int64]
      ) async throws -> (totals: [String: Int64], createdAtMilliseconds: Int64) {
        let source = try await integers(
          "SELECT * FROM rollout_effect_reservations WHERE id = ?", bindings: [.text(sourceID)]
        )
        var totals: [String: Int64] = [:]
        for counter in counters {
          totals[counter] = (previous[counter] ?? 0) + (source[counter] ?? 0)
        }
        return (totals, try #require(source["created_at_ms"]))
      }
      let seed = try await integers(
        "SELECT * FROM rollout_authorization_usage WHERE authorization_id = ? AND sequence = 0",
        bindings: [.text(authorizationID)]
      )
      let exact = try await exactAppend(of: first.id, after: seed)
      #expect(exact.totals["provider_sessions"] == 1)
      var appendForgeries: [Forgery] = [
        ("append sequence gap", 2, "effect", first.id, exact.totals, exact.createdAtMilliseconds),
        ("append source_kind", 1, "scopeRead", first.id, exact.totals, exact.createdAtMilliseconds),
        (
          "append source_id", 1, "effect", "forged-source", exact.totals,
          exact.createdAtMilliseconds
        ),
        (
          "append created_at_ms", 1, "effect", first.id, exact.totals,
          exact.createdAtMilliseconds + 1
        ),
      ]
      for counter in counters {
        var totals = exact.totals
        totals[counter, default: 0] += 1
        appendForgeries.append(
          ("append \(counter)", 1, "effect", first.id, totals, exact.createdAtMilliseconds))
      }
      try await expectRefused(appendForgeries, leaving: 1)
      try await insertUsage(
        sequence: 1, kind: "effect", sourceID: first.id,
        totals: exact.totals, createdAtMilliseconds: exact.createdAtMilliseconds
      )
      #expect(try await usageCount() == 2)
      // A source is consumed once for good: the ledger's UNIQUE key refuses a second
      // citation even when the arithmetic is exact.
      let twice = try await exactAppend(of: first.id, after: exact.totals)
      try await expectRefused(
        [
          (
            "append same source twice", 2, "effect", first.id, twice.totals,
            twice.createdAtMilliseconds
          )
        ],
        leaving: 2
      )
      let next = try await exactAppend(of: second.id, after: exact.totals)
      try await insertUsage(
        sequence: 2, kind: "effect", sourceID: second.id,
        totals: next.totals, createdAtMilliseconds: next.createdAtMilliseconds
      )
      #expect(try await usageCount() == 3)
    }

    // With the honest triggers restored, the store's own append continues the sequence.
    let third = try await fixture.authority.reserveEffect(
      fixture.providerRequest(ordinal: 2),
      reservationID: fixture.reservationIDs[2],
      now: fixture.now.addingTimeInterval(4)
    )
    #expect(try await usageCount() == 4)
    #expect(
      try await fixture.database.scalarText(
        """
        SELECT source_id FROM rollout_authorization_usage
        WHERE authorization_id = ? AND sequence = 3
        """,
        bindings: [.text(authorizationID)]
      ) == third.id
    )
    #expect(
      try await fixture.authority.status(authorizationID: authorizationID)
        .remainingBudgets.providerSessions == 1
    )
    #expect(
      try await fixture.database.scalarInt(
        """
        SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name IN (
          'rollout_authorization_usage_seed', 'rollout_effect_reservations_usage_append'
        )
        """
      ) == 2
    )
  }

  @Test("an unpaused open lane cannot change state even below the store")
  func openLaneCloseRequiresPauseAtTheSQLLevel() async throws {
    // `transitionLane` always pauses first, so the Swift path no longer reaches the
    // guard. This pins the guard itself: the same UPDATE is refused while resumed and
    // admitted once paused, so the pause conjunct is the deciding one.
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    let authorizationID = fixture.authorizationID.uuidString.lowercased()
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
    let transition = """
      UPDATE rollout_authorizations
      SET state = 'draining', updated_at_ms = updated_at_ms + 1
      WHERE id = ?
      """
    func laneState() async throws -> String? {
      try await fixture.database.scalarText(
        "SELECT state FROM rollout_authorizations WHERE id = ?",
        bindings: [.text(authorizationID)]
      )
    }
    do {
      try await fixture.database.execute(transition, bindings: [.text(authorizationID)])
      Issue.record("an unpaused active lane entered draining")
    } catch let error as SQLiteStoreError {
      #expect(
        error
          == .statementFailed(
            code: 19, message: "rollout lane must pause before terminal transition")
      )
    }
    #expect(try await laneState() == "active")
    try await fixture.database.execute(
      "UPDATE app_settings SET paused = 1, updated_at = ? WHERE singleton = 1",
      bindings: [.real(fixture.now.addingTimeInterval(5).timeIntervalSince1970)]
    )
    try await fixture.database.execute(transition, bindings: [.text(authorizationID)])
    #expect(try await laneState() == "draining")
  }

  @Test("the GitHub and Git readback gates share one lane-and-pause clause")
  func readbackTriggersShareTheLaneClause() throws {
    // The two readback triggers hand-duplicate the lane clause, as the lease pair does.
    // The lease pair's byte-equality test (`bothTriggersShareTheSameGate`) is the
    // accepted remedy for that drift risk; this is the same remedy for this pair.
    let migration = try #require(DatabaseSchema.migrations.first { $0.version == 10 })
    func laneClause(of triggerName: String) throws -> String {
      let statement = try #require(
        migration.statements.first { $0.contains("CREATE TRIGGER \(triggerName)") },
        "\(triggerName) statement"
      )
      let start = try #require(
        statement.range(of: "AND source.state IN ('sendStarted', 'observationRequired')"),
        "\(triggerName) source state"
      )
      let end = try #require(
        statement.range(of: "AND usage.", range: start.upperBound..<statement.endIndex),
        "\(triggerName) budget clause"
      )
      return String(statement[start.lowerBound..<end.lowerBound])
    }
    let github = try laneClause(of: "rollout_readback_reservations_exact_started_effect")
    let git = try laneClause(of: "rollout_git_readback_reservations_exact_started_effect")
    #expect(github == git)
    #expect(github.contains("authorization.state = 'active' AND settings.paused = 0"))
    #expect(github.contains("AND settings.paused = 1"))
    for state in [
      "'draining'", "'recoveryRequired'", "'settled'", "'revoked'", "'expired'",
      "'failed'",
    ] {
      #expect(github.contains(state), "\(state)")
    }
    #expect(github.count > 300)
  }

  @Test("a workflow-issued provider permit is inert under a historical canary context")
  func workflowProviderPermitIsInertUnderHistoricalContext() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    let effect = fixture.providerEffect(ordinal: 0)
    let runID = try await fixture.prepareProviderRun(effect)
    let permit = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.reserveProvider(effect, now: fixture.now.addingTimeInterval(2))
    }
    guard case .reservation(let reservationID) = permit else {
      Issue.record("provider reservation did not issue a durable permit: \(permit)")
      return
    }
    func reservationState() async throws -> String? {
      try await fixture.database.scalarText(
        "SELECT state FROM rollout_effect_reservations WHERE id = ?",
        bindings: [.text(reservationID)]
      )
    }
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .historicalCanary(jobID: fixture.jobID))
    ) {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "bind") {
        try await fixture.authority.bindProviderReservation(
          permit, effect: effect, runID: runID, now: fixture.now.addingTimeInterval(3)
        )
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify") {
        try await fixture.authority.verifyProviderPermit(permit, effect: effect)
      }
    }
    #expect(try await reservationState() == "reserved")
    // The same permit still serves the workflow that issued it.
    try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.bindProviderReservation(
        permit, effect: effect, runID: runID, now: fixture.now.addingTimeInterval(3)
      )
      try await fixture.authority.verifyProviderPermit(permit, effect: effect)
    }
    #expect(try await reservationState() == "sendStarted")
  }

  @Test("concurrent reservations cannot overrun the provider cap")
  func concurrentReservationsStayWithinCap() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()

    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for ordinal in 0..<16 {
        group.addTask {
          do {
            _ = try await fixture.authority.reserveEffect(
              fixture.providerRequest(ordinal: ordinal),
              now: fixture.now.addingTimeInterval(2)
            )
            return true
          } catch {
            return false
          }
        }
      }
      var count = 0
      for await succeeded in group where succeeded { count += 1 }
      return count
    }

    #expect(successes == 4)
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.count == 4)
    #expect(status.remainingBudgets.providerSessions == 0)
  }

  @Test("the same durable provider run reuses one permit without consuming another slot")
  func providerRunPermitIsReplaySafe() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    let effect = fixture.providerEffect(ordinal: 0)
    let runID = try await fixture.prepareProviderRun(effect)
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))

    let permits = try await RolloutEffectTaskContext.$current.withValue(context) {
      let first = try await fixture.authority.reserveProvider(
        effect,
        now: fixture.now.addingTimeInterval(2)
      )
      let replay = try await fixture.authority.reserveProvider(
        effect,
        now: fixture.now.addingTimeInterval(3)
      )
      try await fixture.authority.bindProviderReservation(
        first,
        effect: effect,
        runID: runID,
        now: fixture.now.addingTimeInterval(3)
      )
      try await fixture.authority.verifyProviderPermit(first, effect: effect)
      return (first, replay)
    }

    #expect(permits.0 == permits.1)
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.verifyProviderPermit(permits.1, effect: effect)
      }
    }
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.count == 1)
    #expect(status.reservations.first?.state == .sendStarted)
    #expect(status.remainingBudgets.providerSessions == 3)
    try await fixture.authority.settleEffect(
      permits.0,
      evidenceSHA256: String(repeating: "9", count: 64),
      now: fixture.now.addingTimeInterval(4)
    )
  }

  @Test("a settled local provider result reconciles only its bound reservation")
  func providerResultReconcilesAfterRestart() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    let effect = fixture.providerEffect(ordinal: 0)
    let runID = try await fixture.prepareProviderRun(effect)
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      let permit = try await fixture.authority.reserveProvider(
        effect,
        now: fixture.now.addingTimeInterval(2)
      )
      try await fixture.authority.bindProviderReservation(
        permit,
        effect: effect,
        runID: runID,
        now: fixture.now.addingTimeInterval(2)
      )
      try await fixture.authority.verifyProviderPermit(permit, effect: effect)
      return permit
    }
    guard case .reservation(let reservationID) = permit else {
      Issue.record("provider did not receive a durable reservation")
      return
    }
    let resultSHA256 = try await fixture.settleProviderRun(runID: runID, effect: effect)
    let interrupted = try await fixture.authority.markRecoveryRequired(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "PROVIDER_SETTLEMENT_ACK_INTERRUPTED",
      now: fixture.now.addingTimeInterval(3)
    )
    let recovery = try RolloutRecoveryPreviewBuilder.make(
      report: interrupted,
      createdAtMilliseconds: Int64(
        fixture.now.addingTimeInterval(3).timeIntervalSince1970 * 1_000
      )
    )
    #expect(recovery.payload.effects.first?.readbackOnly == true)
    #expect(recovery.payload.action == .readbackThenContinueExact)

    let reopened = RolloutAuthorityStore(
      database: fixture.database,
      now: { fixture.now.addingTimeInterval(4) }
    )
    #expect(
      try await reopened.reconcileLocalEffectResults(
        now: fixture.now.addingTimeInterval(4)
      ) == 1
    )
    #expect(
      try await reopened.reconcileLocalEffectResults(
        now: fixture.now.addingTimeInterval(5)
      ) == 0
    )
    let status = try await reopened.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.count == 1)
    #expect(status.reservations.first?.id == reservationID)
    #expect(status.reservations.first?.state == .settled)
    #expect(status.events.last?.checkpointSHA256 == resultSHA256)
    #expect(
      try await fixture.database.scalarText(
        "SELECT pi_run_id FROM rollout_local_effect_bindings WHERE reservation_id = ?",
        bindings: [.text(reservationID)]
      ) == runID
    )
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "UPDATE rollout_local_effect_bindings SET created_at_ms = created_at_ms + 1 WHERE reservation_id = ?",
        bindings: [.text(reservationID)]
      )
    }
    await #expect(throws: SQLiteStoreError.self) {
      _ = try await fixture.database.execute(
        "DELETE FROM rollout_local_effect_bindings WHERE reservation_id = ?",
        bindings: [.text(reservationID)]
      )
    }
  }

  @Test("provider admission binds artifact, narrative, resources, and model profile")
  func providerAdmissionRejectsIdentityDrift() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    let drifted = [
      fixture.providerEffect(ordinal: 0, artifactSHA256: String(repeating: "0", count: 64)),
      fixture.providerEffect(ordinal: 0, narrativeSHA256: String(repeating: "0", count: 64)),
      fixture.providerEffect(ordinal: 0, resourceSHA256: String(repeating: "0", count: 64)),
      fixture.providerEffect(ordinal: 0, profileSHA256: String(repeating: "0", count: 64)),
    ]

    for effect in drifted {
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
        try await RolloutEffectTaskContext.$current.withValue(context) {
          _ = try await fixture.authority.reserveProvider(
            effect,
            now: fixture.now.addingTimeInterval(2)
          )
        }
      }
    }
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.isEmpty)
    #expect(status.remainingBudgets.providerSessions == 4)
  }

  @Test("an exact intentional terminal result settles and pauses its stage")
  func coordinatorSettlesExactStage() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let coordinator = try await fixture.coordinator(workflowMode: .intentionalBlock)
    try await fixture.activate()

    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .settled)
    #expect(status.events.last?.kind == .settled)
    #expect(status.events.last?.checkpointSHA256 != nil)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("an exact transient failure closes the lane instead of retrying")
  func coordinatorFailsExactStageWithoutRetry() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let coordinator = try await fixture.coordinator(workflowMode: .transientFailure)
    try await fixture.activate()

    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .failed)
    #expect(status.authorization.terminalReason == "EXACT_STAGE_FAILED")
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("an exact interrupted provider boundary requires explicit recovery")
  func coordinatorSuspendsAmbiguousExactStage() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let coordinator = try await fixture.coordinator(workflowMode: .interruptedProvider)
    try await fixture.activate()

    await coordinator.run(pass: SchedulerPass(reasons: [.manual], startedAt: fixture.now))

    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .recoveryRequired)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
  }

  @Test("marker cap failure rolls back the complete reservation batch")
  func markerBatchIsAtomicAtCap() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .executing, currentStep: 1, kind: .publish)
    let intents = MutationIntentStore(database: fixture.database)
    let documentSHA256 = GitHubMarkerCodec.sha256(Data("review-document".utf8))
    var intentIDs: [UUID] = []
    for ordinal in 0..<3 {
      let operation = fixture.commentOperation(body: "review-part-\(ordinal)")
      let intent = try await intents.prepare(
        jobID: fixture.jobID,
        idempotencyKey: GitHubMarkerCodec.sha256(Data("marker-part-\(ordinal)".utf8)),
        operation: .createMarkerComment,
        target: fixture.markerTarget,
        expectedStateDigest: documentSHA256,
        requestDigest: try GitHubMutationExecutor.requestDigest(operation),
        now: fixture.now.addingTimeInterval(2)
      )
      intentIDs.append(intent.id)
    }

    await #expect(throws: RolloutAuthorityError.budgetExceeded(.markerBatch)) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        _ = try await fixture.authority.reserveMarkerBatch(
          fixture.markerBatch(intentIDs: intentIDs, documentSHA256: documentSHA256),
          now: fixture.now.addingTimeInterval(3)
        )
      }
    }
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.isEmpty)
    #expect(status.remainingBudgets.markerParts == 2)
    #expect(status.remainingBudgets.githubSends == 2)
  }

  @Test("issue marker revision and label sends are bound to the live planning step")
  func planningMutationStepIsExact() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.planningPreviewInput()
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    try await fixture.setJob(state: .executing, currentStep: 0, kind: .claimReady)
    let intents = MutationIntentStore(database: fixture.database)
    let documentSHA256 = GitHubMarkerCodec.sha256(Data("claim-document".utf8))
    let markerOperation = fixture.commentOperation(body: "claim-marker")
    let markerIntent = try await intents.prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("claim-marker-intent".utf8)),
      operation: .claimIssue,
      target: fixture.markerTarget,
      expectedStateDigest: documentSHA256,
      requestDigest: try GitHubMutationExecutor.requestDigest(markerOperation),
      now: fixture.now.addingTimeInterval(2)
    )
    let marker = RolloutMarkerBatchEffect(
      jobID: fixture.jobID,
      operation: .claimIssue,
      repositoryID: fixture.repositoryID,
      repository: GitHubRepositoryCoordinates(
        owner: "fixture-owner",
        repository: "fixture-repository"
      ),
      repositoryNodeID: "R_fixture_rollout",
      objectNodeID: "I_fixture_rollout",
      objectNumber: 17,
      revision: String(repeating: "e", count: 64),
      markerKind: .claim,
      authorID: 42,
      documentSHA256: documentSHA256,
      generation: 1,
      intentIDs: [markerIntent.id]
    )
    let markerPermits = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.reserveMarkerBatch(
        marker,
        now: fixture.now.addingTimeInterval(3)
      )
    }
    #expect(markerPermits.count == 1)

    let wrongLabelOperation = GitHubOperation.addIssueLabels(
      owner: "fixture-owner",
      repository: "fixture-repository",
      number: 17,
      labels: ["agent:qa"]
    )
    let wrongRequestSHA256 = try GitHubMutationExecutor.requestDigest(wrongLabelOperation)
    let wrongIntent = try await intents.prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("wrong-phase-label".utf8)),
      operation: .mutateWorkflowLabels,
      target: fixture.markerTarget,
      expectedStateDigest: String(repeating: "f", count: 64),
      requestDigest: wrongRequestSHA256,
      now: fixture.now.addingTimeInterval(4)
    )
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        _ = try await fixture.authority.reserveGitHubSendAndMarkStarted(
          RolloutGitHubSendEffect(
            jobID: fixture.jobID,
            intentID: wrongIntent.id,
            mutation: .mutateWorkflowLabels,
            target: fixture.markerTarget,
            expectedStateSHA256: String(repeating: "f", count: 64),
            requestSHA256: wrongRequestSHA256,
            operation: wrongLabelOperation
          ),
          now: fixture.now.addingTimeInterval(5)
        )
      }
    }
    #expect(try await intents.intent(id: wrongIntent.id)?.state == .prepared)

    let duplicateLabelOperation = GitHubOperation.addIssueLabels(
      owner: "fixture-owner",
      repository: "fixture-repository",
      number: 17,
      labels: ["agent:wip", "agent:wip"]
    )
    let duplicateRequestSHA256 = try GitHubMutationExecutor.requestDigest(
      duplicateLabelOperation
    )
    let duplicateIntent = try await intents.prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("duplicate-label".utf8)),
      operation: .mutateWorkflowLabels,
      target: fixture.markerTarget,
      expectedStateDigest: String(repeating: "1", count: 64),
      requestDigest: duplicateRequestSHA256,
      now: fixture.now.addingTimeInterval(6)
    )
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        _ = try await fixture.authority.reserveGitHubSendAndMarkStarted(
          RolloutGitHubSendEffect(
            jobID: fixture.jobID,
            intentID: duplicateIntent.id,
            mutation: .mutateWorkflowLabels,
            target: fixture.markerTarget,
            expectedStateSHA256: String(repeating: "1", count: 64),
            requestSHA256: duplicateRequestSHA256,
            operation: duplicateLabelOperation
          ),
          now: fixture.now.addingTimeInterval(7)
        )
      }
    }
    #expect(try await intents.intent(id: duplicateIntent.id)?.state == .prepared)
  }

  @Test("revocation denies fresh effects but preserves exact uncertain-effect readback")
  func revocationIsReadbackOnly() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .executing, currentStep: 1, kind: .publish)
    let intents = MutationIntentStore(database: fixture.database)
    let operation = fixture.commentOperation(body: "review-marker")
    let requestSHA256 = try GitHubMutationExecutor.requestDigest(operation)
    let documentSHA256 = GitHubMarkerCodec.sha256(Data("review-document".utf8))
    let intent = try await intents.prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("review-marker-intent".utf8)),
      operation: .createMarkerComment,
      target: fixture.markerTarget,
      expectedStateDigest: documentSHA256,
      requestDigest: requestSHA256,
      now: fixture.now.addingTimeInterval(2)
    )

    let sendPermit = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      _ = try await fixture.authority.reserveMarkerBatch(
        fixture.markerBatch(intentIDs: [intent.id], documentSHA256: documentSHA256),
        now: fixture.now.addingTimeInterval(3)
      )
      return try await fixture.authority.reserveGitHubSendAndMarkStarted(
        RolloutGitHubSendEffect(
          jobID: fixture.jobID,
          intentID: intent.id,
          mutation: .createMarkerComment,
          target: fixture.markerTarget,
          expectedStateSHA256: documentSHA256,
          requestSHA256: requestSHA256,
          operation: operation
        ),
        now: fixture.now.addingTimeInterval(4)
      )
    }
    guard case .reservation(let reservationID) = sendPermit else {
      Issue.record("schema-10 send did not return a durable reservation")
      return
    }
    #expect(try await intents.intent(id: intent.id)?.state == .sendStarted)
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).reservations.first?.state == .sendStarted
    )

    let revoked = try await fixture.authority.revoke(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_REVOKED",
      now: fixture.now.addingTimeInterval(5)
    )
    #expect(revoked.authorization.state == .revoked)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.verifyGitHubSendPermit(sendPermit, operation: operation)
      }
    }

    _ = try await intents.markReconcileRequired(
      id: intent.id,
      now: fixture.now.addingTimeInterval(6)
    )
    let readbackContext = RolloutEffectExecutionContext(
      mode: .readback(jobID: fixture.jobID, intentID: intent.id)
    )
    try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      try await fixture.authority.recordMutationObservation(
        intentID: intent.id,
        observation: .observationRequired,
        evidenceSHA256: GitHubMarkerCodec.sha256(Data("uncertain-send".utf8)),
        now: fixture.now.addingTimeInterval(6)
      )
    }

    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        _ = try await fixture.authority.reserveProvider(
          fixture.providerEffect(ordinal: 0),
          now: fixture.now.addingTimeInterval(7)
        )
      }
    }

    let unrelatedReadback = RolloutGitHubReadEffect(
      operation: .issue(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17
      ),
      maximumResponseBytes: 4_096,
      context: readbackContext
    )
    await #expect(throws: RolloutAuthorityError.readbackNotAllowed) {
      _ = try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
        try await fixture.authority.reserveGitHubRead(
          unrelatedReadback,
          now: fixture.now.addingTimeInterval(7)
        )
      }
    }

    let readbackEffect = RolloutGitHubReadEffect(
      operation: .listComments(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17,
        page: 1
      ),
      maximumResponseBytes: 4_096,
      context: readbackContext
    )
    let readback = try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      try await fixture.authority.reserveGitHubRead(
        readbackEffect,
        now: fixture.now.addingTimeInterval(7)
      )
    }
    let reopened = RolloutAuthorityStore(
      database: fixture.database,
      now: { fixture.now.addingTimeInterval(8) }
    )
    let reattachedReadback = try await RolloutEffectTaskContext.$current.withValue(
      readbackContext
    ) {
      try await reopened.reserveGitHubRead(
        readbackEffect,
        now: fixture.now.addingTimeInterval(8)
      )
    }
    #expect(reattachedReadback == readback)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM rollout_readback_reservations"
      ) == 1
    )
    try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      try await reopened.verifyGitHubReadPermit(
        reattachedReadback,
        effect: readbackEffect
      )
    }
    try await reopened.settleGitHubRead(
      reattachedReadback,
      evidenceSHA256: GitHubMarkerCodec.sha256(Data("exact-readback".utf8)),
      now: fixture.now.addingTimeInterval(9)
    )

    let attributed = try await intents.settle(
      id: intent.id,
      outcome: .attributableEffect,
      evidenceDigest: GitHubMarkerCodec.sha256(Data("exact-effect".utf8)),
      now: fixture.now.addingTimeInterval(10)
    )
    let observationEvidence = GitHubMarkerCodec.sha256(Data("attributed-effect".utf8))
    try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      for _ in 0..<2 {
        try await fixture.authority.recordMutationObservation(
          intentID: attributed.id,
          observation: .attributed,
          evidenceSHA256: observationEvidence,
          now: fixture.now.addingTimeInterval(10)
        )
      }
      for _ in 0..<2 {
        try await fixture.authority.recordMutationObservation(
          intentID: attributed.id,
          observation: .settled,
          evidenceSHA256: observationEvidence,
          now: fixture.now.addingTimeInterval(11)
        )
      }
    }
    let final = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(final.reservations.first(where: { $0.id == reservationID })?.state == .settled)
    #expect(final.reservations.count == 1)
    #expect(final.remainingBudgets.markerParts == 1)
    #expect(final.remainingBudgets.githubSends == 1)
  }

  @Test("send permits are task-bound, single-use transport capabilities")
  func sendPermitIsSingleUseAndTaskBound() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .executing, currentStep: 1, kind: .publish)
    let operation = fixture.commentOperation(body: "single-use-marker")
    let requestSHA256 = try GitHubMutationExecutor.requestDigest(operation)
    let documentSHA256 = GitHubMarkerCodec.sha256(Data("single-use-document".utf8))
    let intent = try await MutationIntentStore(database: fixture.database).prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("single-use-intent".utf8)),
      operation: .createMarkerComment,
      target: fixture.markerTarget,
      expectedStateDigest: documentSHA256,
      requestDigest: requestSHA256,
      now: fixture.now.addingTimeInterval(2)
    )
    let permit = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      _ = try await fixture.authority.reserveMarkerBatch(
        fixture.markerBatch(intentIDs: [intent.id], documentSHA256: documentSHA256),
        now: fixture.now.addingTimeInterval(3)
      )
      return try await fixture.authority.reserveGitHubSendAndMarkStarted(
        RolloutGitHubSendEffect(
          jobID: fixture.jobID,
          intentID: intent.id,
          mutation: .createMarkerComment,
          target: fixture.markerTarget,
          expectedStateSHA256: documentSHA256,
          requestSHA256: requestSHA256,
          operation: operation
        ),
        now: fixture.now.addingTimeInterval(4)
      )
    }

    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await fixture.authority.verifyGitHubSendPermit(permit, operation: operation)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: UUID()) {
        try await fixture.authority.verifyGitHubSendPermit(permit, operation: operation)
      }
    }
    try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.verifyGitHubSendPermit(permit, operation: operation)
    }
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).reservations.first?.state == .observationRequired
    )
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.verifyGitHubSendPermit(permit, operation: operation)
      }
    }

    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await fixture.authority.recordMutationObservation(
        intentID: intent.id,
        observation: .observationRequired,
        evidenceSHA256: String(repeating: "d", count: 64),
        now: fixture.now.addingTimeInterval(5)
      )
    }
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await withTestRolloutWorkflow(jobID: UUID()) {
        try await fixture.authority.recordMutationObservation(
          intentID: intent.id,
          observation: .observationRequired,
          evidenceSHA256: String(repeating: "d", count: 64),
          now: fixture.now.addingTimeInterval(5)
        )
      }
    }
    try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.recordMutationObservation(
        intentID: intent.id,
        observation: .observationRequired,
        evidenceSHA256: String(repeating: "d", count: 64),
        now: fixture.now.addingTimeInterval(5)
      )
    }
  }

  @Test("GitHub reads require the matching task-local scope and settle exactly once")
  func githubReadContextCannotBeForged() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .preparing, currentStep: 0, kind: .review)
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    let effect = RolloutGitHubReadEffect(
      operation: .pullRequest(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17
      ),
      maximumResponseBytes: 4_096,
      context: context
    )

    let wrongEffect = RolloutGitHubReadEffect(
      operation: .issue(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17
      ),
      maximumResponseBytes: 4_096,
      context: context
    )
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      _ = try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.reserveGitHubRead(
          wrongEffect,
          now: fixture.now.addingTimeInterval(2)
        )
      }
    }

    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      _ = try await fixture.authority.reserveGitHubRead(
        effect,
        now: fixture.now.addingTimeInterval(2)
      )
    }
    let permit = try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.reserveGitHubRead(
        effect,
        now: fixture.now.addingTimeInterval(2)
      )
    }
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await fixture.authority.verifyGitHubReadPermit(permit, effect: effect)
    }
    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.verifyGitHubReadPermit(permit, effect: effect)
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await RolloutEffectTaskContext.$current.withValue(context) {
        try await fixture.authority.verifyGitHubReadPermit(permit, effect: effect)
      }
    }
    try await fixture.authority.settleGitHubRead(
      permit,
      evidenceSHA256: GitHubMarkerCodec.sha256(Data("github-read".utf8)),
      now: fixture.now.addingTimeInterval(3)
    )
    try await fixture.authority.settleGitHubRead(
      permit,
      evidenceSHA256: GitHubMarkerCodec.sha256(Data("github-read".utf8)),
      now: fixture.now.addingTimeInterval(3)
    )
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.reservations.count == 1)
    #expect(status.remainingBudgets.githubReadRequests == 9)
  }

  @Test("expiry closes and terminalizes the lane before any fresh effect")
  func expiryIsFailClosed() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()

    let admission = try await fixture.authority.schedulerAdmission(
      now: fixture.now.addingTimeInterval(601)
    )
    #expect(admission == .denied)
    let status = try await fixture.authority.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(status.authorization.state == .expired)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(
      try await fixture.database.scalarText(
        "SELECT active_rollout_authorization_id FROM app_settings"
      ) == nil
    )
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        _ = try await fixture.authority.reserveProvider(
          fixture.providerEffect(ordinal: 0),
          now: fixture.now.addingTimeInterval(601)
        )
      }
    }
  }

  @Test("stop pauses durably with draining and terminalizes only after drain")
  func stopDrainOrderingIsDurable() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()

    let draining = try await fixture.authority.beginDrain(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_STOP_REQUESTED",
      now: fixture.now.addingTimeInterval(2)
    )
    #expect(draining.authorization.state == .draining)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(
      try await fixture.database.scalarText(
        "SELECT active_rollout_authorization_id FROM app_settings"
      ) == fixture.authorizationID.uuidString.lowercased()
    )
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      _ = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.reserveProvider(
          fixture.providerEffect(ordinal: 0),
          now: fixture.now.addingTimeInterval(3)
        )
      }
    }

    let stopped = try await fixture.authority.revoke(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_STOPPED",
      now: fixture.now.addingTimeInterval(4)
    )
    #expect(stopped.authorization.state == .revoked)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(
      try await fixture.database.scalarText(
        "SELECT active_rollout_authorization_id FROM app_settings"
      ) == nil
    )
  }

  @Test("terminal historical evidence does not block a later drain")
  func terminalEvidenceIsOutsideCurrentDrain() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    _ = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.reserveProvider(
        fixture.providerEffect(ordinal: 0),
        now: fixture.now.addingTimeInterval(2)
      )
    }
    let revoked = try await fixture.authority.revoke(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_STOPPED",
      now: fixture.now.addingTimeInterval(3)
    )
    #expect(revoked.authorization.state == .revoked)
    #expect(revoked.reservations.first?.state == .reserved)

    let reopened = RolloutAuthorityStore(
      database: fixture.database,
      now: { fixture.now.addingTimeInterval(4) }
    )
    #expect(await reopened.waitForDrain(until: fixture.now.addingTimeInterval(5)))
    let preserved = try await reopened.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(preserved.reservations.first?.state == .reserved)
  }

  @Test("confirmed recovery resumes only the same exact job after every effect settles")
  func exactRecoveryContinuationIsBound() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    let permit = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.reserveProvider(
        fixture.providerEffect(ordinal: 0),
        now: fixture.now.addingTimeInterval(2)
      )
    }
    _ = try await fixture.authority.markRecoveryRequired(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "STARTUP_INTERRUPTED",
      now: fixture.now.addingTimeInterval(3)
    )
    let checkpoint = String(repeating: "7", count: 64)
    await #expect(throws: RolloutAuthorityError.invalidStateTransition) {
      try await fixture.authority.resumeExactRecovery(
        authorizationID: fixture.authorizationID.uuidString.lowercased(),
        checkpointSHA256: checkpoint,
        now: fixture.now.addingTimeInterval(4)
      )
    }

    try await fixture.authority.settleEffect(
      permit,
      evidenceSHA256: String(repeating: "8", count: 64),
      now: fixture.now.addingTimeInterval(4)
    )
    let resumed = try await fixture.authority.resumeExactRecovery(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      checkpointSHA256: checkpoint,
      now: fixture.now.addingTimeInterval(5)
    )
    #expect(resumed.authorization.state == .active)
    #expect(resumed.boundJobIDs == [fixture.jobID])
    #expect(resumed.events.last?.kind == .recoveryActivated)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
  }

  @Test("startup recovery transforms only the bound rollout job before explicit continuation")
  func startupRecoveryIsBoundAndLive() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    let rolloutJobs = DurableJobStore(
      database: fixture.database,
      enforceRolloutAuthority: true
    )
    let queued = try #require(try await rolloutJobs.job(id: fixture.jobID))
    let leasedTransition = try await rolloutJobs.transition(
      jobID: queued.id,
      eventKey: "startup-rollout:lease",
      event: .acquireLease,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(2),
        reason: "prepare interrupted rollout fixture"
      )
    )
    let leased: JobRecord =
      switch leasedTransition {
      case .applied(let job), .duplicate(let job): job
      }
    let preparingTransition = try await rolloutJobs.transition(
      jobID: leased.id,
      eventKey: "startup-rollout:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(3),
        reason: "prepare interrupted rollout fixture"
      )
    )
    let preparing: JobRecord =
      switch preparingTransition {
      case .applied(let job), .duplicate(let job): job
      }
    _ = try await rolloutJobs.transition(
      jobID: preparing.id,
      eventKey: "startup-rollout:pi",
      event: .selectPiStep,
      context: JobTransitionContext(
        now: fixture.now.addingTimeInterval(4),
        reason: "simulate an interrupted provider phase"
      )
    )

    let historicalJobs = DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
    let historicalID = UUID()
    _ = try await historicalJobs.createJob(
      id: historicalID,
      identity: LogicalJobIdentity(
        repositoryID: fixture.repositoryID,
        kind: .prReview,
        objectNodeID: "PR_historical_inert",
        revisionKey: String(repeating: "5", count: 40)
      ),
      objectNumber: 99,
      contractVersionUsed: "historical-v1",
      priority: .prReview,
      firstStep: .review,
      now: fixture.now.addingTimeInterval(4)
    )
    let historicalTransitionCount = try await fixture.database.scalarInt(
      "SELECT COUNT(*) FROM job_transitions WHERE job_id = ?",
      bindings: [.text(historicalID.uuidString.lowercased())]
    )
    let historicalReconciliationCount = try await fixture.database.scalarInt(
      "SELECT COUNT(*) FROM reconciliation_events WHERE job_id = ?",
      bindings: [.text(historicalID.uuidString.lowercased())]
    )

    let coordinator = try await fixture.coordinator(workflowMode: .recoveryCompletes)
    #expect(try await rolloutJobs.job(id: fixture.jobID)?.state == .reconciliationQueued)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT active FROM repository_leases WHERE job_id = ?",
        bindings: [.text(fixture.jobID.uuidString.lowercased())]
      ) == 0
    )
    #expect(try await historicalJobs.job(id: historicalID)?.state == .queued)
    #expect(
      try await fixture.database.scalarInt(
        "SELECT rollout_generation FROM jobs WHERE id = ?",
        bindings: [.text(historicalID.uuidString.lowercased())]
      ) == 0
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM job_transitions WHERE job_id = ?",
        bindings: [.text(historicalID.uuidString.lowercased())]
      ) == historicalTransitionCount
    )
    #expect(
      try await fixture.database.scalarInt(
        "SELECT COUNT(*) FROM reconciliation_events WHERE job_id = ?",
        bindings: [.text(historicalID.uuidString.lowercased())]
      ) == historicalReconciliationCount
    )

    let checkpoint = String(repeating: "6", count: 64)
    _ = try await fixture.authority.resumeExactRecovery(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      checkpointSHA256: checkpoint,
      now: fixture.now.addingTimeInterval(5)
    )
    await coordinator.run(
      pass: SchedulerPass(reasons: [.resume], startedAt: fixture.now.addingTimeInterval(7))
    )

    let coordinatorSnapshot = await coordinator.snapshot()
    #expect(coordinatorSnapshot.failures == [])
    #expect(try await rolloutJobs.job(id: fixture.jobID)?.state == .blocked)
    #expect(try await historicalJobs.job(id: historicalID)?.state == .queued)
    #expect(
      try await fixture.authority.status(
        authorizationID: fixture.authorizationID.uuidString.lowercased()
      ).authorization.state == .settled
    )
  }

  @Test("restart reattaches only pre-boundary orphan reservations after exact recovery")
  func restartReattachesPreBoundaryReservations() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .runningPi, currentStep: 0, kind: .review)
    let context = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    let providerEffect = fixture.providerEffect(ordinal: 0)
    let providerRunID = try await fixture.prepareProviderRun(providerEffect)
    let githubReadEffect = RolloutGitHubReadEffect(
      operation: .pullRequest(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17
      ),
      maximumResponseBytes: 4_096,
      context: context
    )
    let providerPermit = try await RolloutEffectTaskContext.$current.withValue(context) {
      let permit = try await fixture.authority.reserveProvider(
        providerEffect,
        now: fixture.now.addingTimeInterval(2)
      )
      try await fixture.authority.bindProviderReservation(
        permit,
        effect: providerEffect,
        runID: providerRunID,
        now: fixture.now.addingTimeInterval(2)
      )
      return permit
    }
    let githubReadPermit = try await RolloutEffectTaskContext.$current.withValue(context) {
      try await fixture.authority.reserveGitHubRead(
        githubReadEffect,
        now: fixture.now.addingTimeInterval(2)
      )
    }

    let reopened = RolloutAuthorityStore(
      database: fixture.database,
      now: { fixture.now.addingTimeInterval(5) }
    )
    let recovery = try #require(
      try await reopened.markInterruptedLaneRecoveryRequired(
        now: fixture.now.addingTimeInterval(3)
      )
    )

    #expect(recovery.authorization.state == .recoveryRequired)
    #expect(recovery.reservations.count == 2)
    #expect(recovery.reservations.allSatisfy { $0.state == .reserved })
    let recoveryPreview = try RolloutRecoveryPreviewBuilder.make(
      report: recovery,
      createdAtMilliseconds: Int64(
        fixture.now.addingTimeInterval(3).timeIntervalSince1970 * 1_000
      )
    )
    #expect(recoveryPreview.payload.action == .readbackThenContinueExact)
    #expect(!(await reopened.waitForDrain(until: fixture.now.addingTimeInterval(4))))

    _ = try await reopened.resumeExactRecovery(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      checkpointSHA256: recoveryPreview.sha256,
      now: fixture.now.addingTimeInterval(4)
    )
    let reattached = try await RolloutEffectTaskContext.$current.withValue(context) {
      let provider = try await reopened.reserveProvider(
        providerEffect,
        now: fixture.now.addingTimeInterval(5)
      )
      let read = try await reopened.reserveGitHubRead(
        githubReadEffect,
        now: fixture.now.addingTimeInterval(5)
      )
      return (provider, read)
    }
    #expect(reattached.0 == providerPermit)
    #expect(reattached.1 == githubReadPermit)
    let reattachedStatus = try await reopened.status(
      authorizationID: fixture.authorizationID.uuidString.lowercased()
    )
    #expect(reattachedStatus.reservations.count == 2)
    #expect(reattachedStatus.remainingBudgets.providerSessions == 3)
    #expect(reattachedStatus.remainingBudgets.githubReadRequests == 9)

    try await RolloutEffectTaskContext.$current.withValue(context) {
      try await reopened.bindProviderReservation(
        reattached.0,
        effect: providerEffect,
        runID: providerRunID,
        now: fixture.now.addingTimeInterval(6)
      )
      try await reopened.verifyProviderPermit(reattached.0, effect: providerEffect)
      try await reopened.verifyGitHubReadPermit(reattached.1, effect: githubReadEffect)
      try await reopened.settleEffect(
        reattached.0,
        evidenceSHA256: String(repeating: "8", count: 64),
        now: fixture.now.addingTimeInterval(6)
      )
      try await reopened.settleGitHubRead(
        reattached.1,
        evidenceSHA256: String(repeating: "9", count: 64),
        now: fixture.now.addingTimeInterval(6)
      )
    }
    #expect(await reopened.waitForDrain(until: fixture.now.addingTimeInterval(7)))
  }

  @Test("a rollout job cannot settle an unreserved mutation effect")
  func mutationObservationRequiresReservation() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    let intent = try await MutationIntentStore(database: fixture.database).prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("unreserved-intent".utf8)),
      operation: .createMarkerComment,
      target: fixture.markerTarget,
      expectedStateDigest: String(repeating: "a", count: 64),
      requestDigest: String(repeating: "b", count: 64),
      now: fixture.now.addingTimeInterval(2)
    )

    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.recordMutationObservation(
          intentID: intent.id,
          observation: .settled,
          evidenceSHA256: String(repeating: "c", count: 64),
          now: fixture.now.addingTimeInterval(3)
        )
      }
    }
  }
}

private struct RolloutAuthorityFixture {
  let root: URL
  let database: SQLiteStore
  let authority: RolloutAuthorityStore
  let repositoryID = UUID(uuidString: "61000000-0000-4000-8000-000000000001")!
  let jobID = UUID(uuidString: "62000000-0000-4000-8000-000000000002")!
  let authorizationID = UUID(uuidString: "63000000-0000-4000-8000-000000000003")!
  let reservationIDs = (1...4).map {
    UUID(uuidString: "64000000-0000-4000-8000-\(String(format: "%012d", $0))")!
  }
  let now = Date(timeIntervalSince1970: 10_000)

  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-rollout-authority-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let fixture = Self(
      root: root,
      database: database,
      authority: RolloutAuthorityStore(
        database: database,
        now: { Date(timeIntervalSince1970: 10_005) }
      )
    )
    let configuration = ConfigurationStore(database: database)
    try await configuration.setExternalAutomationAcknowledged(true, now: fixture.now)
    try await configuration.setProviderDisclosureAcknowledged(true, now: fixture.now)
    try await configuration.setLoginItem(selected: true, status: .enabled, now: fixture.now)
    try await configuration.setOnboardingComplete(true, now: fixture.now)
    try await configuration.upsertRepository(
      RepositoryConfiguration(
        id: fixture.repositoryID,
        nodeID: "R_fixture_rollout",
        owner: "fixture-owner",
        name: "fixture-repository",
        defaultBranch: "main",
        reviewEnabled: true,
        triageEnabled: false,
        implementationEnabled: false,
        enabled: true
      ),
      now: fixture.now
    )
    try await database.execute(
      """
      UPDATE app_settings
      SET github_account = 'fixture-owner', github_author_id = 42,
          paused = 1, max_concurrency = 1, updated_at = ?
      WHERE singleton = 1
      """,
      bindings: [.real(fixture.now.timeIntervalSince1970)]
    )
    return fixture
  }

  func previewInput(
    githubReadRequests: Int = 10,
    stage: RolloutWorkflowStage = .prReview
  ) async throws -> RolloutPreviewInput {
    let baseEvidence = try await authority.localEvidence(repositoryID: repositoryID)
    let digest = String(repeating: "a", count: 64)
    let object = RolloutObjectSelector(
      nodeID: "PR_fixture_rollout",
      number: 17,
      revisionKey: String(repeating: "1", count: 40),
      canonicalInputSHA256: String(repeating: "b", count: 64),
      headSHA: String(repeating: "1", count: 40),
      baseSHA: String(repeating: "2", count: 40),
      narrativeSHA256: String(repeating: "c", count: 64),
      currentStep: JobStepKind.review.rawValue
    )
    let repository = RolloutRepositoryIdentity(
      id: repositoryID,
      nodeID: "R_fixture_rollout",
      owner: "fixture-owner",
      name: "fixture-repository",
      defaultBranch: "main",
      enabled: true,
      reviewEnabled: true,
      triageEnabled: false,
      implementationEnabled: false
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: stage,
      repository: repository,
      object: object,
      finiteWindow: nil
    )
    let jobBinding = RolloutJobBinding(
      jobID: jobID,
      jobKind: .prReview,
      objectNumber: 17,
      contractVersion: "pr-review-v1",
      priority: .prReview,
      firstStep: .review,
      currentStep: JobStepKind.review.rawValue
    )
    let evidence = try await authority.localEvidence(scope: scope, jobBinding: jobBinding)
    return RolloutPreviewInput(
      releaseIdentity: RolloutReleaseIdentity(
        sourceCommit: String(repeating: "1", count: 40),
        sourceTree: String(repeating: "2", count: 40),
        bundleVersion: "0.2.0",
        bundleBuild: 3,
        applicationSHA256: digest,
        helperSHA256: digest,
        askPassSHA256: digest,
        pushGuardSHA256: digest,
        herdrHostSHA256: digest,
        schemaVersion: 10,
        engineProtocolVersion: 12,
        runtimeManifestSHA256: digest,
        runtimeTreeSHA256: digest,
        modelProfilesSHA256: baseEvidence.modelProfilesSHA256,
        workflowResourcesSHA256: digest,
        githubAccount: "fixture-owner",
        githubAuthorID: 42,
        repositoryConfigurationSHA256: baseEvidence.repositoryConfigurationSHA256,
        maxConcurrency: 1
      ),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: 1,
        githubReadRequests: githubReadRequests,
        githubReadPages: 10,
        githubReadBytes: 1_000_000,
        gitRemoteReads: 1,
        providerSessions: 4,
        approvedCommands: 0,
        markerParts: 2,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: 2,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: jobBinding,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
    )
  }

  func missingExecutionPreviewInput() async throws -> RolloutPreviewInput {
    try await executionPreviewInput(
      revisionKey: String(repeating: "9", count: 64),
      currentStep: .orchestrate,
      firstStep: .orchestrate
    )
  }

  func waitingExecutionPreviewInput() async throws -> RolloutPreviewInput {
    try await executionPreviewInput(
      revisionKey: "claim-1",
      currentStep: .publishPlan,
      firstStep: .claimApprovedPlan
    )
  }

  private func executionPreviewInput(
    revisionKey: String,
    currentStep: JobStepKind,
    firstStep: JobStepKind
  ) async throws -> RolloutPreviewInput {
    let repository = RepositoryConfiguration(
      id: repositoryID,
      nodeID: "R_fixture_rollout",
      owner: "fixture-owner",
      name: "fixture-repository",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: false,
      implementationEnabled: true,
      enabled: true
    )
    try await ConfigurationStore(database: database).upsertRepository(repository, now: now)
    let digest = String(repeating: "a", count: 64)
    let object = RolloutObjectSelector(
      nodeID: "I_fixture_rollout",
      number: 17,
      revisionKey: revisionKey,
      canonicalInputSHA256: String(repeating: "b", count: 64),
      baseSHA: String(repeating: "2", count: 40),
      planSHA256: String(repeating: "c", count: 64),
      labelStateSHA256: String(repeating: "d", count: 64),
      currentStep: currentStep.rawValue
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: .implementationExecute,
      repository: RolloutRepositoryIdentity(
        id: repository.id,
        nodeID: repository.nodeID,
        owner: repository.owner,
        name: repository.name,
        defaultBranch: repository.defaultBranch,
        enabled: repository.enabled,
        reviewEnabled: repository.reviewEnabled,
        triageEnabled: repository.triageEnabled,
        implementationEnabled: repository.implementationEnabled
      ),
      object: object,
      finiteWindow: nil
    )
    let binding = RolloutJobBinding(
      jobID: jobID,
      jobKind: .issueImplementation,
      objectNumber: object.number,
      contractVersion: "implementation-v1",
      priority: .issueImplementation,
      firstStep: firstStep,
      currentStep: object.currentStep
    )
    let evidence = try await authority.localEvidence(scope: scope, jobBinding: binding)
    return RolloutPreviewInput(
      releaseIdentity: RolloutReleaseIdentity(
        sourceCommit: String(repeating: "1", count: 40),
        sourceTree: String(repeating: "2", count: 40),
        bundleVersion: "0.2.0",
        bundleBuild: 3,
        applicationSHA256: digest,
        helperSHA256: digest,
        askPassSHA256: digest,
        pushGuardSHA256: digest,
        herdrHostSHA256: digest,
        schemaVersion: 10,
        engineProtocolVersion: 12,
        runtimeManifestSHA256: digest,
        runtimeTreeSHA256: digest,
        modelProfilesSHA256: evidence.modelProfilesSHA256,
        workflowResourcesSHA256: digest,
        githubAccount: "fixture-owner",
        githubAuthorID: 42,
        repositoryConfigurationSHA256: evidence.repositoryConfigurationSHA256,
        maxConcurrency: 1
      ),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: 1,
        githubReadRequests: 0,
        githubReadPages: 0,
        githubReadBytes: 0,
        gitRemoteReads: 0,
        providerSessions: 0,
        approvedCommands: 0,
        markerParts: 0,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: 0,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: binding,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
    )
  }

  func planningPreviewInput() async throws -> RolloutPreviewInput {
    let seed = try await missingExecutionPreviewInput()
    let object = RolloutObjectSelector(
      nodeID: "I_fixture_rollout",
      number: 17,
      revisionKey: "claim-1",
      canonicalInputSHA256: String(repeating: "b", count: 64),
      baseSHA: String(repeating: "2", count: 40),
      labelStateSHA256: String(repeating: "d", count: 64),
      currentStep: JobStepKind.claimReady.rawValue
    )
    let scope = RolloutScope(
      mode: .exactObject,
      stage: .implementationPlan,
      repository: seed.scope.repository,
      object: object,
      finiteWindow: nil
    )
    let binding = RolloutJobBinding(
      jobID: jobID,
      jobKind: .issueImplementation,
      objectNumber: object.number,
      contractVersion: "implementation-v1",
      priority: .issueImplementation,
      firstStep: .claimReady,
      currentStep: object.currentStep
    )
    let evidence = try await authority.localEvidence(scope: scope, jobBinding: binding)
    return RolloutPreviewInput(
      releaseIdentity: seed.releaseIdentity,
      scope: scope,
      budgets: RolloutBudgets(
        jobs: 1,
        githubReadRequests: 10,
        githubReadPages: 10,
        githubReadBytes: 1_000_000,
        gitRemoteReads: 1,
        providerSessions: 15,
        approvedCommands: 0,
        markerParts: 2,
        labelWrites: 2,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: 4,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: binding,
      createdAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(now.addingTimeInterval(600).timeIntervalSince1970 * 1_000)
    )
  }

  func finitePreviewInput(
    maximumJobs: Int = 3,
    operationalLifetime: TimeInterval = 3 * 60 * 60
  ) async throws -> RolloutPreviewInput {
    let baseEvidence = try await authority.localEvidence(repositoryID: repositoryID)
    let digest = String(repeating: "a", count: 64)
    let repository = RolloutRepositoryIdentity(
      id: repositoryID,
      nodeID: "R_fixture_rollout",
      owner: "fixture-owner",
      name: "fixture-repository",
      defaultBranch: "main",
      enabled: true,
      reviewEnabled: true,
      triageEnabled: false,
      implementationEnabled: false
    )
    let createdAt = now.addingTimeInterval(8)
    let scope = RolloutScope(
      mode: .finiteWindow,
      stage: .prReview,
      repository: repository,
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: maximumJobs,
        expiresAtMilliseconds: Int64(
          createdAt.addingTimeInterval(operationalLifetime).timeIntervalSince1970 * 1_000
        ),
        allowsFutureObjects: true,
        observedObjectNumberUpperBound: 17,
        maximumFutureObjectNumber: 21,
        candidates: []
      )
    )
    let evidence = try await authority.localEvidence(scope: scope, jobBinding: nil)
    return RolloutPreviewInput(
      releaseIdentity: RolloutReleaseIdentity(
        sourceCommit: String(repeating: "1", count: 40),
        sourceTree: String(repeating: "2", count: 40),
        bundleVersion: "0.2.0",
        bundleBuild: 3,
        applicationSHA256: digest,
        helperSHA256: digest,
        askPassSHA256: digest,
        pushGuardSHA256: digest,
        herdrHostSHA256: digest,
        schemaVersion: 10,
        engineProtocolVersion: 12,
        runtimeManifestSHA256: digest,
        runtimeTreeSHA256: digest,
        modelProfilesSHA256: baseEvidence.modelProfilesSHA256,
        workflowResourcesSHA256: digest,
        githubAccount: "fixture-owner",
        githubAuthorID: 42,
        repositoryConfigurationSHA256: baseEvidence.repositoryConfigurationSHA256,
        maxConcurrency: 1
      ),
      scope: scope,
      budgets: RolloutBudgets(
        jobs: maximumJobs,
        githubReadRequests: 30,
        githubReadPages: 30,
        githubReadBytes: 3_000_000,
        gitRemoteReads: maximumJobs,
        providerSessions: maximumJobs * 4,
        approvedCommands: 0,
        markerParts: maximumJobs * 2,
        labelWrites: 0,
        branchCreates: 0,
        pullRequestCreates: 0,
        githubSends: maximumJobs * 2,
        gitSends: 0
      ),
      inventory: evidence.inventory,
      missingLabels: [],
      commands: [],
      jobBinding: nil,
      createdAtMilliseconds: Int64(createdAt.timeIntervalSince1970 * 1_000),
      expiresAtMilliseconds: Int64(
        createdAt.addingTimeInterval(600).timeIntervalSince1970 * 1_000
      )
    )
  }

  func activate() async throws {
    let input = try await previewInput()
    let preview = try await authority.preview(input: input)
    _ = try await authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256,
      recomputedInput: input,
      authorizationID: authorizationID,
      now: now.addingTimeInterval(1)
    )
  }

  /// Test-only seam: run `body` with the named test-database triggers dropped, then
  /// recreate each from its own recorded SQL. Restoration covers the throwing path so a
  /// failed body cannot leave later assertions in this fixture passing vacuously.
  func withTriggersLifted(_ names: [String], _ body: () async throws -> Void) async throws {
    var recorded: [String] = []
    for name in names {
      let rows = try await database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
        bindings: [.text(name)]
      )
      guard case .text(let sql)? = rows.first?["sql"] else {
        throw RolloutAuthorityError.decode("test trigger \(name)")
      }
      recorded.append(sql)
      try await database.execute("DROP TRIGGER \(name)")
    }
    do {
      try await body()
    } catch {
      for sql in recorded {
        do {
          try await database.execute(sql)
        } catch let restoreError {
          Issue.record("lifted trigger was not restored: \(restoreError)")
        }
      }
      throw error
    }
    for sql in recorded {
      try await database.execute(sql)
    }
  }

  func setJob(
    id: UUID? = nil,
    state: JobState,
    currentStep: Int,
    kind: JobStepKind
  ) async throws {
    guard
      try await database.execute(
        "UPDATE jobs SET state = ?, current_step = ?, current_step_kind = ?, updated_at = ? WHERE id = ?",
        bindings: [
          .text(state.rawValue),
          .integer(Int64(currentStep)),
          .text(kind.rawValue),
          .real(now.timeIntervalSince1970),
          .text((id ?? jobID).uuidString.lowercased()),
        ]
      ) == 1
    else {
      throw TestRolloutFixtureError.invalidJob
    }
  }

  func coordinator(
    workflowMode: RolloutCoordinatorWorkflow.Mode,
    newDispatchAllowed: @escaping @Sendable () async -> Bool = { true }
  ) async throws
    -> JobCoordinator
  {
    let jobs = DurableJobStore(database: database, enforceRolloutAuthority: true)
    let workflow = RolloutCoordinatorWorkflow(jobs: jobs, mode: workflowMode, now: now)
    let repositories = try RepositoryStore(
      rootURL: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      database: database,
      transport: SystemGitTransport()
    )
    let coordinator = JobCoordinator(
      configuration: ConfigurationStore(database: database),
      discovery: GitHubDiscovery(
        api: RolloutNoReadAPI(),
        jobs: jobs,
        reviewedRevisions: ReviewedRevisionStore(database: database)
      ),
      jobs: jobs,
      repositories: repositories,
      schedulerPersistence: SchedulerPersistence(database: database),
      workflows: JobWorkflowRegistry(
        pullRequestReview: workflow,
        issueTriage: workflow,
        issueImplementation: workflow,
        complexPlan: workflow
      ),
      contractVersion: "rollout-coordinator-v1",
      rolloutAuthority: authority,
      rolloutReadbacks: RolloutNoReadback(),
      newDispatchAllowed: newDispatchAllowed,
      now: { self.now.addingTimeInterval(5) }
    )
    try await coordinator.recoverAtStartup()
    return coordinator
  }

  func providerRequest(ordinal: Int) -> RolloutEffectReservationRequest {
    RolloutEffectReservationRequest(
      authorizationID: authorizationID.uuidString.lowercased(),
      jobID: jobID,
      kind: .providerSession,
      operationSHA256: GitHubMarkerCodec.sha256(Data("provider-\(ordinal)".utf8)),
      targetSHA256: String(repeating: "d", count: 64),
      ordinal: ordinal,
      attempt: 1,
      cost: RolloutEffectCost(providerSessions: 1)
    )
  }

  func providerEffect(
    ordinal: Int,
    artifactSHA256: String = String(repeating: "b", count: 64),
    narrativeSHA256: String = String(repeating: "c", count: 64),
    resourceSHA256: String? = nil,
    profileSHA256: String? = nil
  ) -> RolloutProviderEffect {
    let workflowManifest = String(repeating: "a", count: 64)
    let expectedResource = RolloutCanonicalJSON.sha256(
      Data("\(workflowManifest)|\(PiTUIResourceCatalog.manifestSHA256)".utf8)
    )
    let expectedProfile = RolloutCanonicalJSON.sha256(
      Data("openai-codex/gpt-5.6-sol:max".utf8)
    )
    return RolloutProviderEffect(
      jobID: jobID,
      workflow: .pullRequestReview,
      role: [.architecture, .security, .test, .synthesis][ordinal],
      round: 1,
      runNonce: GitHubMarkerCodec.sha256(Data("provider-nonce-\(ordinal)".utf8)),
      artifactSHA256: artifactSHA256,
      narrativeSHA256: narrativeSHA256,
      planSHA256: nil,
      resourceSHA256: resourceSHA256 ?? expectedResource,
      profileSHA256: profileSHA256 ?? expectedProfile,
      sessionDirectiveSHA256: String(repeating: "f", count: 64)
    )
  }

  func prepareProviderRun(_ effect: RolloutProviderEffect) async throws -> String {
    let runID = "run-\(UUID().uuidString.lowercased())"
    let changed = try await database.execute(
      """
      INSERT INTO pi_runs(
        id, job_id, runtime_kind, workflow, role, round, job_attempt,
        topology_generation, job_step, resumes_run_id, run_nonce, request_sha256,
        resource_version, resource_hash, model, session_path, session_id,
        session_boundary_sha256, channel_path, accepted, settled,
        structured_result_digest, outcome, created_at, updated_at
      )
      SELECT ?, job.id, 'herdr', ?, ?, ?, job.attempt, 1, job.current_step,
        NULL, ?, ?, 'fixture-v1', ?, 'fixture-model', ?, NULL, NULL, ?,
        0, 0, NULL, 'prepared', ?, ?
      FROM jobs AS job WHERE job.id = ?
      """,
      bindings: [
        .text(runID),
        .text(effect.workflow.rawValue),
        .text(effect.role.rawValue),
        .integer(Int64(effect.round)),
        .text(effect.runNonce),
        .text(effect.artifactSHA256),
        .text(effect.resourceSHA256),
        .text(root.appendingPathComponent(runID).path),
        .text(root.appendingPathComponent("\(runID)-channel").path),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
        .text(jobID.uuidString.lowercased()),
      ]
    )
    guard changed == 1 else { throw TestRolloutFixtureError.invalidJob }
    return runID
  }

  func settleProviderRun(
    runID: String,
    effect: RolloutProviderEffect
  ) async throws -> String {
    let workspaceID = "workspace-rollout-provider"
    let roleHostID = "rolehost-rollout-provider"
    let launchID = "launch-\(UUID().uuidString.lowercased())"
    let sessionID = UUID().uuidString.lowercased()
    let digest = String(repeating: "8", count: 64)
    _ = try await database.execute(
      """
      INSERT INTO herdr_repository_bindings(
        repository_id, workspace_id, identity_root, herdr_version, herdr_protocol,
        socket_device, socket_inode, socket_owner, socket_permissions,
        state, created_at, updated_at
      ) VALUES (?, ?, ?, 'fixture-herdr', 1, 1, 1, 1, 384, 'active', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .text(workspaceID),
        .text(root.path),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    _ = try await database.execute(
      """
      INSERT INTO herdr_job_bindings(
        job_id, repository_id, generation, workspace_id, tab_id,
        state, created_at, updated_at
      ) VALUES (?, ?, 1, ?, 'tab-rollout-provider', 'active', ?, ?)
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .text(repositoryID.uuidString.lowercased()),
        .text(workspaceID),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    _ = try await database.execute(
      """
      INSERT INTO herdr_role_hosts(
        id, job_id, generation, role, workspace_id, tab_id, pane_id, terminal_id,
        bootstrap_descriptor_sha256, host_executable_sha256,
        host_pid, host_start_seconds, host_start_microseconds,
        last_queue_sequence, lifecycle_sequence, state, created_at, updated_at
      ) VALUES (?, ?, 1, ?, ?, 'tab-rollout-provider', 'pane-rollout-provider',
        'terminal-rollout-provider', ?, ?, 1234, 100, 0, 0, 1, 'waiting', ?, ?)
      """,
      bindings: [
        .text(roleHostID),
        .text(jobID.uuidString.lowercased()),
        .text(effect.role.rawValue),
        .text(workspaceID),
        .text(digest),
        .text(digest),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    _ = try await database.execute(
      """
      INSERT INTO pi_run_launches(
        launch_attempt_id, run_id, role_host_id, queue_sequence, launch_mode,
        descriptor_sha256, expected_session_id, resume_boundary_sha256,
        state, failure_code, child_pid, child_process_group_id,
        child_start_seconds, child_start_microseconds, created_at, updated_at
      ) VALUES (?, ?, ?, 1, 'fresh', ?, NULL, NULL, 'enqueued', NULL,
        NULL, NULL, NULL, NULL, ?, ?)
      """,
      bindings: [
        .text(launchID),
        .text(runID),
        .text(roleHostID),
        .text(digest),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    let envelope = Data("accepted provider result".utf8)
    let resultSHA256 = GitHubMarkerCodec.sha256(envelope)
    _ = try await database.execute(
      """
      INSERT INTO pi_run_results(
        run_id, launch_attempt_id, envelope, result_sha256, session_id,
        session_boundary_sha256, settlement_sha256, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(runID),
        .text(launchID),
        .blob(envelope),
        .text(resultSHA256),
        .text(sessionID),
        .text(digest),
        .text(GitHubMarkerCodec.sha256(Data("settlement:\(runID)".utf8))),
        .real(now.addingTimeInterval(1).timeIntervalSince1970),
      ]
    )
    return resultSHA256
  }

  var markerTarget: String {
    "fixture-owner/fixture-repository/issues/17"
  }

  func commentOperation(body: String) -> GitHubOperation {
    .createComment(
      owner: "fixture-owner",
      repository: "fixture-repository",
      number: 17,
      body: body
    )
  }

  func markerBatch(intentIDs: [UUID], documentSHA256: String) -> RolloutMarkerBatchEffect {
    RolloutMarkerBatchEffect(
      jobID: jobID,
      operation: .createMarkerComment,
      repositoryID: repositoryID,
      repository: GitHubRepositoryCoordinates(
        owner: "fixture-owner",
        repository: "fixture-repository"
      ),
      repositoryNodeID: "R_fixture_rollout",
      objectNodeID: "PR_fixture_rollout",
      objectNumber: 17,
      revision: String(repeating: "1", count: 40),
      markerKind: .review,
      authorID: 42,
      documentSHA256: documentSHA256,
      generation: 0,
      intentIDs: intentIDs
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor RolloutCoordinatorWorkflow: JobWorkflowRunning,
  IssueImplementationApprovalEvaluating
{
  enum Mode {
    case intentionalBlock
    case transientFailure
    case interruptedProvider
    case recoveryCompletes
  }

  private let jobs: DurableJobStore
  private let mode: Mode
  private let now: Date

  init(jobs: DurableJobStore, mode: Mode, now: Date) {
    self.jobs = jobs
    self.mode = mode
    self.now = now
  }

  func run(jobID: UUID) async throws {
    guard let job = try await jobs.job(id: jobID) else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    if case .recoveryCompletes = mode {
      guard job.state == .reconciling else {
        throw RolloutAuthorityError.invalidJobBinding
      }
      _ = try await jobs.transition(
        jobID: jobID,
        eventKey: "rollout-test:recovery-block",
        event: .reconciliationPermanentFailure,
        context: JobTransitionContext(now: now, reason: "accepted recovered result")
      )
      return
    }
    guard job.state == .preparing else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    switch mode {
    case .intentionalBlock:
      let executing = try await jobs.transition(
        jobID: jobID,
        eventKey: "rollout-test:execute",
        event: .selectLocalStep,
        context: JobTransitionContext(now: now, reason: "test terminal result")
      )
      let current: JobRecord =
        switch executing {
        case .applied(let value), .duplicate(let value): value
        }
      _ = try await jobs.transition(
        jobID: current.id,
        eventKey: "rollout-test:block",
        event: .localPermanentFailure,
        context: JobTransitionContext(now: now, reason: "accepted blocked result")
      )
    case .transientFailure:
      throw URLError(.timedOut)
    case .interruptedProvider:
      _ = try await jobs.transition(
        jobID: jobID,
        eventKey: "rollout-test:provider",
        event: .selectPiStep,
        context: JobTransitionContext(now: now, reason: "test provider launch")
      )
      throw PiRPCProcessError.timeout(abortAcknowledged: false)
    case .recoveryCompletes:
      preconditionFailure("handled before preparing-state workflows")
    }
  }

  func evaluateWaitingApproval(jobID: UUID) async throws -> JobRecord {
    guard let job = try await jobs.job(id: jobID), job.state == .waitingHuman else {
      throw RolloutAuthorityError.invalidJobBinding
    }
    let transition = try await jobs.transition(
      jobID: jobID,
      eventKey: "rollout-test:approval-fresh",
      event: .approvalFresh,
      context: JobTransitionContext(now: now, reason: "fixture approval matches frozen plan")
    )
    switch transition {
    case .applied(let job), .duplicate(let job): return job
    }
  }
}

private struct RolloutNoReadAPI: GitHubReadAPI {
  func listPullRequests(owner _: String, repository _: String) async throws
    -> [GitHubPullRequest]
  {
    throw RolloutAuthorityError.effectAdmissionClosed
  }

  func listIssues(owner _: String, repository _: String) async throws -> [GitHubIssue] {
    throw RolloutAuthorityError.effectAdmissionClosed
  }
}

@Suite("Production rollout operator commands")
struct ProductionRolloutOperatorTests {
  @Test("preview and activation enforce paused, exclusive and checkpoint boundaries")
  func previewAndActivationBoundaries() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let harness = try RolloutOperatorHarness(
      fixture: fixture, expectedRelease: input.releaseIdentity)
    let runtime = harness.runtime
    await #expect(throws: EngineClientError(.busy)) { try await runtime.previewRollout(input) }
    await runtime.setPaused(true)
    let preview = try await runtime.previewRollout(input)
    #expect(
      try await fixture.database.scalarInt("SELECT COUNT(*) FROM rollout_authorizations") == 0)
    let request = RolloutActivationRequest(
      authorizationID: fixture.authorizationID, approvedCanonicalJSON: preview.canonicalJSON,
      confirmedSHA256: preview.sha256
    )
    try await runtime.beginExclusiveOperation()
    await #expect(throws: EngineClientError(.busy)) { try await runtime.previewRollout(input) }
    await #expect(throws: EngineClientError(.busy)) { try await runtime.activateRollout(request) }
    await runtime.endExclusiveOperation()
    let report = try await runtime.activateRollout(request)
    #expect(report.authorization.state == .active)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
    #expect(await runtime.timingSnapshot()?.paused == false)
    #expect(await harness.scheduler.pauses == [true, false])
    await #expect(throws: EngineClientError(.busy)) { try await runtime.activateRollout(request) }
    await runtime.setPaused(true)
    try await runtime.prepareForCheckpoint()
    await #expect(throws: EngineClientError(.busy)) { try await runtime.previewRollout(input) }
    await #expect(throws: EngineClientError(.busy)) { try await runtime.activateRollout(request) }
  }

  @Test("stop closes actual dispatch and command gates and pauses the scheduler")
  func stopClosesAdmission() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let harness = try RolloutOperatorHarness(
      fixture: fixture, expectedRelease: input.releaseIdentity)
    let report = try await harness.activate(input, authorizationID: fixture.authorizationID)
    #expect(await harness.dispatch.value())
    let lease = try await harness.commands.acquire()
    await harness.commands.release(lease)
    let stop = RolloutStopRequest(
      authorizationID: report.authorization.id, previewSHA256: report.authorization.previewSHA256,
      timeoutMilliseconds: 1_000
    )
    await #expect(throws: EngineClientError(.staleEvidence)) {
      try await harness.runtime.stopAndDrainRollout(
        RolloutStopRequest(
          authorizationID: stop.authorizationID, previewSHA256: String(repeating: "f", count: 64),
          timeoutMilliseconds: 1_000
        )
      )
    }
    #expect(await harness.dispatch.value())
    let stopped = try await harness.runtime.stopAndDrainRollout(stop)
    #expect(stopped.authorization.state == .revoked)
    #expect(stopped.authorization.terminalReason == "OPERATOR_STOPPED")
    #expect(await harness.runtime.timingSnapshot()?.paused == true)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(await harness.dispatch.value() == false)
    await #expect(throws: ApprovedCommandRunStoreError.launchSuppressed) {
      try await harness.commands.acquire()
    }
    await #expect(throws: EngineClientError(.staleEvidence)) {
      try await harness.runtime.stopAndDrainRollout(stop)
    }
  }

  @Test("a busy command times out into recovery without reopening admission")
  func drainTimeoutAndRecovery() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let harness = try RolloutOperatorHarness(
      fixture: fixture, expectedRelease: input.releaseIdentity)
    let active = try await harness.activate(input, authorizationID: fixture.authorizationID)
    let lease = try await harness.commands.acquire()
    let stopping = Task {
      try await harness.runtime.stopAndDrainRollout(
        RolloutStopRequest(
          authorizationID: active.authorization.id,
          previewSHA256: active.authorization.previewSHA256,
          timeoutMilliseconds: 1_000
        )
      )
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await harness.dispatch.value(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await harness.dispatch.value() == false)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(
      try await fixture.database.scalarText("SELECT state FROM rollout_authorizations")
        == "draining")
    await #expect(throws: ApprovedCommandRunStoreError.launchSuppressed) {
      try await harness.commands.acquire()
    }
    let report = try await stopping.value
    await harness.commands.release(lease)
    #expect(report.authorization.state == .recoveryRequired)
    #expect(report.events.last?.reasonCode == "DRAIN_TIMEOUT")
    #expect(await harness.runtime.timingSnapshot()?.paused == true)
    let request = RolloutRecoveryRequest(
      authorizationID: report.authorization.id, previewSHA256: report.authorization.previewSHA256
    )
    let before = try await harness.runtime.rolloutStatus()
    let preview = try await harness.runtime.previewRolloutRecovery(request)
    #expect(try await harness.runtime.rolloutStatus() == before)
    #expect(preview.payload.action == .readbackThenContinueExact)
    let authorization = RolloutRecoveryAuthorization(
      approvedCanonicalJSON: preview.canonicalJSON, confirmedSHA256: preview.sha256
    )
    // The service holds exclusivity and keeps dispatch shut through the checkpoint.
    try await harness.runtime.beginExclusiveOperation()
    let resumed = try await harness.runtime.executeRolloutRecovery(authorization)
    #expect(resumed.authorization.state == .active)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 0)
    #expect(await harness.dispatch.value() == false)
    #expect(await harness.runtime.timingSnapshot()?.paused == true)
    await harness.runtime.endExclusiveOperation()
    await harness.runtime.setPaused(false)
    await harness.runtime.setDispatchAllowed(true)
    #expect(await harness.dispatch.value())
    #expect(await harness.runtime.timingSnapshot()?.paused == false)
  }

  @Test("recovery rejects unpaused, expired and drifted evidence")
  func recoveryRejectsStaleEvidence() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let harness = try RolloutOperatorHarness(
      fixture: fixture, expectedRelease: input.releaseIdentity)
    let active = try await harness.activate(input, authorizationID: fixture.authorizationID)
    let reservation = try await fixture.authority.reserveEffect(
      fixture.providerRequest(ordinal: 0), now: fixture.now.addingTimeInterval(2)
    )
    _ = try await fixture.authority.markRecoveryRequired(
      authorizationID: active.authorization.id, reasonCode: "TEST_INTERRUPTION",
      now: fixture.now.addingTimeInterval(5)
    )
    let request = RolloutRecoveryRequest(
      authorizationID: active.authorization.id, previewSHA256: active.authorization.previewSHA256
    )
    await #expect(throws: EngineClientError(.staleEvidence)) {
      try await harness.runtime.previewRolloutRecovery(request)
    }
    await harness.runtime.setPaused(true)
    let preview = try await harness.runtime.previewRolloutRecovery(request)
    let authorization = RolloutRecoveryAuthorization(
      approvedCanonicalJSON: preview.canonicalJSON, confirmedSHA256: preview.sha256
    )
    let expired = try RolloutOperatorHarness(
      fixture: fixture, expectedRelease: input.releaseIdentity,
      now: fixture.now.addingTimeInterval(601)
    )
    await expired.runtime.setPaused(true)
    await #expect(throws: EngineClientError(.staleEvidence)) {
      try await expired.runtime.executeRolloutRecovery(authorization)
    }
    _ = try await fixture.authority.settleReservation(
      id: reservation.id, attributed: false, evidenceSHA256: String(repeating: "e", count: 64),
      now: fixture.now.addingTimeInterval(4)
    )
    await #expect(throws: EngineClientError(.staleEvidence)) {
      try await harness.runtime.executeRolloutRecovery(authorization)
    }
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(await harness.dispatch.value() == false)
  }

  @Test("release mismatch and local identity drift leave operator admission closed")
  func releaseAndStatusDrift() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let input = try await fixture.previewInput()
    let harness = try RolloutOperatorHarness(fixture: fixture, expectedRelease: nil)
    await harness.runtime.setPaused(true)
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await harness.runtime.previewRollout(input)
    }
    let good = try RolloutOperatorHarness(fixture: fixture, expectedRelease: input.releaseIdentity)
    _ = try await good.activate(input, authorizationID: fixture.authorizationID)
    let repository = input.scope.repository
    try await ConfigurationStore(database: fixture.database).upsertRepository(
      RepositoryConfiguration(
        id: fixture.repositoryID, nodeID: repository.nodeID, owner: repository.owner,
        name: repository.name, defaultBranch: repository.defaultBranch,
        reviewEnabled: repository.reviewEnabled, triageEnabled: repository.triageEnabled,
        implementationEnabled: repository.implementationEnabled, enabled: false
      ),
      now: fixture.now.addingTimeInterval(6)
    )
    let failed = try await good.runtime.rolloutStatus()
    #expect(failed?.authorization.state == .failed)
    #expect(failed?.authorization.terminalReason == "CONFIGURATION_DRIFT")
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    #expect(await good.runtime.timingSnapshot()?.paused == true)
    #expect(await good.dispatch.value() == false)
    await #expect(throws: ApprovedCommandRunStoreError.launchSuppressed) {
      try await good.commands.acquire()
    }
  }
}

private struct RolloutOperatorHarness {
  let runtime: ProductionEngineJobRuntime
  let dispatch = EngineDispatchGate()
  let commands = ApprovedCommandExecutionGate()
  let scheduler = RolloutOperatorSchedulerProbe()

  init(fixture: RolloutAuthorityFixture, expectedRelease: RolloutReleaseIdentity?, now: Date? = nil)
    throws
  {
    let scheduler = self.scheduler
    let date = now ?? fixture.now.addingTimeInterval(5)
    runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: try ProductionEngineRuntimeConfiguration(
        applicationSupportRoot: fixture.root, piResourceRoot: fixture.root,
        askPassExecutable: URL(fileURLWithPath: "/usr/bin/true"),
        pushGuardExecutable: URL(fileURLWithPath: "/usr/bin/true"),
        herdrHostExecutable: URL(fileURLWithPath: "/usr/bin/true"),
        herdrSocketURL: fixture.root.appendingPathComponent("unused.sock"),
        contractVersion: "fixture-v1"
      ),
      database: fixture.database, configuration: ConfigurationStore(database: fixture.database),
      jobs: DurableJobStore(database: fixture.database, enforceRolloutAuthority: true),
      intents: MutationIntentStore(database: fixture.database),
      herdrReadiness: RolloutOperatorReadyHerdr(), ownershipRuntime: nil,
      reloadComposition: ProductionEngineReloadComposition(
        setSchedulerPaused: { await scheduler.setPaused($0) },
        recoverCoordinatorAtStartup: {}, runStartupPass: { _ in }, requestStartup: {},
        schedulerSnapshot: { await scheduler.snapshot() }
      ),
      rolloutReleaseIdentity: RolloutOperatorReleaseIdentity(expected: expectedRelease),
      dispatchGate: dispatch, commandGate: commands, now: { date }
    )
  }

  func activate(_ input: RolloutPreviewInput, authorizationID: UUID) async throws
    -> RolloutStatusReport
  {
    await runtime.setPaused(true)
    let preview = try await runtime.previewRollout(input)
    let report = try await runtime.activateRollout(
      RolloutActivationRequest(
        authorizationID: authorizationID, approvedCanonicalJSON: preview.canonicalJSON,
        confirmedSHA256: preview.sha256
      )
    )
    await runtime.setPaused(false)
    await runtime.setDispatchAllowed(true)
    return report
  }
}

private actor RolloutOperatorSchedulerProbe {
  private(set) var pauses: [Bool] = []
  func setPaused(_ value: Bool) { pauses.append(value) }
  func snapshot() -> SchedulerTimingSnapshot {
    SchedulerTimingSnapshot(
      paused: pauses.last ?? false, passRunning: false, pendingReasons: [],
      dueAt: nil, nextPeriodicAt: Date(timeIntervalSince1970: 20_000)
    )
  }
}

private struct RolloutOperatorReadyHerdr: HerdrRuntimeReadinessChecking {
  func preflight() async -> EngineHerdrStatus { EngineHerdrStatus(state: .ready) }
}

private struct RolloutOperatorReleaseIdentity: RolloutReleaseIdentityRevalidating {
  let expected: RolloutReleaseIdentity?
  func requireCurrent(_ actual: RolloutReleaseIdentity) async throws {
    guard actual == expected else { throw RolloutAuthorityError.previewDrift }
  }
}

private struct RolloutNoReadback: RolloutStartedEffectReconciling {
  func reconcileStartedEffects(now _: Date) async throws {}
}

// Drain closes fresh admission durably while preserving exact started-effect readback.
extension RolloutAuthorityStoreTests {
  @Test("a started branch publication can read back during drain without fresh send authority")
  func gitReadbackDuringDrain() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    let seed = try await fixture.missingExecutionPreviewInput()
    _ = try await DurableJobStore(database: fixture.database, enforceRolloutAuthority: false)
      .createJob(
        id: fixture.jobID,
        identity: LogicalJobIdentity(
          repositoryID: fixture.repositoryID, kind: .issueImplementation,
          objectNodeID: "I_fixture_rollout", revisionKey: String(repeating: "9", count: 64)
        ),
        objectNumber: 17, contractVersionUsed: "implementation-v1",
        priority: .issueImplementation, firstStep: .orchestrate, now: fixture.now
      )
    // Refresh local evidence after creating the existing implementation job.
    let current = try await fixture.missingExecutionPreviewInput()
    let input = RolloutPreviewInput(
      releaseIdentity: current.releaseIdentity, scope: current.scope,
      budgets: RolloutBudgets(
        jobs: 1, githubReadRequests: 0, githubReadPages: 0, githubReadBytes: 0,
        gitRemoteReads: 1, providerSessions: 0, approvedCommands: 0,
        markerParts: 0, labelWrites: 0, branchCreates: 1, pullRequestCreates: 0,
        githubSends: 0, gitSends: 1
      ),
      inventory: current.inventory, missingLabels: [], commands: [],
      jobBinding: current.jobBinding, createdAtMilliseconds: seed.createdAtMilliseconds,
      expiresAtMilliseconds: seed.expiresAtMilliseconds
    )
    let preview = try await fixture.authority.preview(input: input)
    _ = try await fixture.authority.activate(
      approvedCanonicalJSON: preview.canonicalJSON, confirmedSHA256: preview.sha256,
      recomputedInput: input, authorizationID: fixture.authorizationID,
      now: fixture.now.addingTimeInterval(1)
    )
    try await fixture.setJob(state: .executing, currentStep: 2, kind: .push)
    let digest = String(repeating: "a", count: 64)
    let target = "R_fixture_rollout:refs/heads/agent/issue-17-fixture"
    let intents = MutationIntentStore(database: fixture.database)
    let intent = try await intents.prepare(
      jobID: fixture.jobID, idempotencyKey: digest, operation: .publishBranch,
      target: target, expectedStateDigest: digest, requestDigest: digest,
      now: fixture.now.addingTimeInterval(2)
    )
    let send = RolloutGitSendEffect(
      jobID: fixture.jobID, intentID: intent.id, repositoryID: fixture.repositoryID,
      repositoryNodeID: "R_fixture_rollout", branch: "agent/issue-17-fixture",
      exactSHA: String(repeating: "1", count: 40), target: target,
      expectedStateSHA256: digest, requestSHA256: digest
    )
    _ = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      try await fixture.authority.reserveGitSendAndMarkStarted(
        send, now: fixture.now.addingTimeInterval(3)
      )
    }
    #expect(try await intents.intent(id: intent.id)?.state == .sendStarted)
    _ = try await fixture.authority.beginDrain(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_STOP_REQUESTED", now: fixture.now.addingTimeInterval(4)
    )
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)
    let read = RolloutGitRemoteReadEffect(
      jobID: fixture.jobID, repositoryID: fixture.repositoryID,
      repositoryNodeID: "R_fixture_rollout", operation: .readReference, target: target
    )
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .readback(jobID: fixture.jobID, intentID: intent.id))
    ) {
      let permit = try await fixture.authority.reserveGitRemoteRead(
        read, now: fixture.now.addingTimeInterval(5)
      )
      guard case .gitReadback = permit else {
        Issue.record("expected exact Git readback permit")
        return
      }
      try await fixture.authority.verifyGitRemoteReadPermit(permit, effect: read)
      try await fixture.authority.settleEffect(
        permit, evidenceSHA256: digest, now: fixture.now.addingTimeInterval(6)
      )
    }
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.reserveGitSendAndMarkStarted(
          send, now: fixture.now.addingTimeInterval(7)
        )
      }
    }
  }

  @Test("a send-started mutation's readback is reservable while the lane is draining")
  func readbackDuringDrain() async throws {
    let fixture = try await RolloutAuthorityFixture.make()
    defer { fixture.remove() }
    try await fixture.activate()
    try await fixture.setJob(state: .executing, currentStep: 1, kind: .publish)
    let intents = MutationIntentStore(database: fixture.database)
    let operation = fixture.commentOperation(body: "review-marker")
    let requestSHA256 = try GitHubMutationExecutor.requestDigest(operation)
    let documentSHA256 = GitHubMarkerCodec.sha256(Data("review-document".utf8))
    let intent = try await intents.prepare(
      jobID: fixture.jobID,
      idempotencyKey: GitHubMarkerCodec.sha256(Data("review-marker-intent".utf8)),
      operation: .createMarkerComment,
      target: fixture.markerTarget,
      expectedStateDigest: documentSHA256,
      requestDigest: requestSHA256,
      now: fixture.now.addingTimeInterval(2)
    )
    let sendPermit = try await withTestRolloutWorkflow(jobID: fixture.jobID) {
      _ = try await fixture.authority.reserveMarkerBatch(
        fixture.markerBatch(intentIDs: [intent.id], documentSHA256: documentSHA256),
        now: fixture.now.addingTimeInterval(3)
      )
      return try await fixture.authority.reserveGitHubSendAndMarkStarted(
        RolloutGitHubSendEffect(
          jobID: fixture.jobID,
          intentID: intent.id,
          mutation: .createMarkerComment,
          target: fixture.markerTarget,
          expectedStateSHA256: documentSHA256,
          requestSHA256: requestSHA256,
          operation: operation
        ),
        now: fixture.now.addingTimeInterval(4)
      )
    }
    guard case .reservation = sendPermit else {
      Issue.record("send did not return a durable reservation")
      return
    }
    #expect(try await intents.intent(id: intent.id)?.state == .sendStarted)

    let draining = try await fixture.authority.beginDrain(
      authorizationID: fixture.authorizationID.uuidString.lowercased(),
      reasonCode: "OPERATOR_STOP_REQUESTED",
      now: fixture.now.addingTimeInterval(5)
    )
    #expect(draining.authorization.state == .draining)
    #expect(try await fixture.database.scalarInt("SELECT paused FROM app_settings") == 1)

    let readbackContext = RolloutEffectExecutionContext(
      mode: .readback(jobID: fixture.jobID, intentID: intent.id)
    )
    let readbackEffect = RolloutGitHubReadEffect(
      operation: .listComments(
        owner: "fixture-owner",
        repository: "fixture-repository",
        number: 17,
        page: 1
      ),
      maximumResponseBytes: 4_096,
      context: readbackContext
    )
    let permit = try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      try await fixture.authority.reserveGitHubRead(
        readbackEffect,
        now: fixture.now.addingTimeInterval(6)
      )
    }
    guard case .readback = permit else {
      Issue.record("unexpected permit kind during drain: \(permit)")
      return
    }
    try await RolloutEffectTaskContext.$current.withValue(readbackContext) {
      try await fixture.authority.verifyGitHubReadPermit(permit, effect: readbackEffect)
    }
    try await fixture.authority.settleGitHubRead(
      permit, evidenceSHA256: String(repeating: "e", count: 64),
      now: fixture.now.addingTimeInterval(7)
    )
    await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
      try await withTestRolloutWorkflow(jobID: fixture.jobID) {
        try await fixture.authority.reserveProvider(
          fixture.providerEffect(ordinal: 0), now: fixture.now.addingTimeInterval(8)
        )
      }
    }
  }
}
