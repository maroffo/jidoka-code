// ABOUTME: Pins that a historical JobCanaryScope context can never obtain fresh effect authority.
// ABOUTME: Reserve, verify, mark-started and settle must all deny, leaving no durable trace.
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Historical canary effect denial")
struct HistoricalCanaryEffectDenialTests {
  @Test("a historical canary context cannot reserve any fresh effect", arguments: [false, true])
  func historicalCanaryCannotReserve(useDouble: Bool) async throws {
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let jobID = fixture.jobID
    let authority: any RolloutEffectAuthorizing =
      useDouble ? ExplicitTestRolloutEffectAuthority() : fixture.authority

    try await fixture.asHistoricalCanary {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "githubRead") {
        _ = try await authority.reserveGitHubRead(fixture.githubReadEffect(), now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "gitRemoteRead") {
        _ = try await authority.reserveGitRemoteRead(fixture.gitReadEffect(), now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "provider") {
        _ = try await authority.reserveProvider(fixture.providerEffect(), now: fixture.now)
      }
      // Command and Git-send reservation carry no historical-canary branch at all, so
      // the context simply fails to be a `.workflow` one: different error, same denial.
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch, "approvedCommand") {
        _ = try await authority.reserveApprovedCommand(fixture.commandEffect(), now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "markerBatch") {
        _ = try await authority.reserveMarkerBatch(
          fixture.markerEffect(intentID: fixture.intentID), now: fixture.now)
      }
    }

    #expect(try await fixture.reservationCount() == 0)
    #expect(try await fixture.rolloutGeneration() == 0)
    _ = jobID
    await fixture.database.close()
  }

  // The shared unit double must preserve production's historical-canary denial.
  @Test("the explicit test double denies a historical canary provider reservation like the store")
  func explicitDoubleMatchesStoreForCanaryProvider() async throws {
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let double = ExplicitTestRolloutEffectAuthority()

    try await fixture.asHistoricalCanary {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
        _ = try await double.reserveProvider(fixture.providerEffect(), now: fixture.now)
      }
    }
    await fixture.database.close()
  }

  @Test(
    "a historical canary send is denied and marks no intent as started", arguments: [false, true])
  func historicalCanarySendMarksNothing(useDouble: Bool) async throws {
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let authority: any RolloutEffectAuthorizing =
      useDouble
      ? ExplicitTestRolloutEffectAuthority(intents: MutationIntentStore(database: fixture.database))
      : fixture.authority
    #expect(try await fixture.intentState() == "prepared")

    try await fixture.asHistoricalCanary {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed) {
        _ = try await authority.reserveGitHubSendAndMarkStarted(
          fixture.githubSendEffect(), now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
        _ = try await authority.reserveGitSendAndMarkStarted(
          fixture.gitSendEffect(), now: fixture.now)
      }
    }

    // The whole point of the denial: no send-start was recorded, so no remote effect
    // can ever be attributed to historical canary authority.
    #expect(try await fixture.intentState() == "prepared")
    #expect(try await fixture.reservationCount() == 0)
    await fixture.database.close()
  }

  @Test("a historical canary permit cannot be verified or settled", arguments: [false, true])
  func historicalCanaryCannotVerifyOrSettle(useDouble: Bool) async throws {
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let authority: any RolloutEffectAuthorizing =
      useDouble ? ExplicitTestRolloutEffectAuthority() : fixture.authority
    let permit = RolloutEffectPermit.historicalCanary(jobID: fixture.jobID)

    try await fixture.asHistoricalCanary {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify githubRead") {
        try await authority.verifyGitHubReadPermit(permit, effect: fixture.githubReadEffect())
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify gitRead") {
        try await authority.verifyGitRemoteReadPermit(permit, effect: fixture.gitReadEffect())
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify provider") {
        try await authority.verifyProviderPermit(permit, effect: fixture.providerEffect())
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify command") {
        try await authority.verifyApprovedCommandPermit(permit, effect: fixture.commandEffect())
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify githubSend") {
        try await authority.verifyGitHubSendPermit(
          permit, operation: fixture.githubSendEffect().operation)
      }
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch, "verify gitSend") {
        try await authority.verifyGitSendPermit(permit, effect: fixture.gitSendEffect())
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "settle") {
        try await authority.settleEffect(
          permit,
          evidenceSHA256: String(repeating: "e", count: 64),
          now: fixture.now
        )
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "observe") {
        try await authority.recordMutationObservation(
          intentID: fixture.intentID,
          observation: .observationRequired,
          evidenceSHA256: String(repeating: "f", count: 64),
          now: fixture.now
        )
      }
    }

    #expect(try await fixture.reservationCount() == 0)
    #expect(try await fixture.intentState() == "prepared")
    await fixture.database.close()
  }

  @Test("the double keeps workflow-issued permits inert under a historical context")
  func doubleDeniesWorkflowPermitsUnderHistoricalContext() async throws {
    // Parity with the store for permits that were legitimately issued to a workflow:
    // verifying or binding them under a historical canary context is refused with the
    // store's error, and the same permits still serve the workflow that issued them.
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let double = ExplicitTestRolloutEffectAuthority(
      intents: MutationIntentStore(database: fixture.database))
    let provider = fixture.providerEffect()
    let command = fixture.commandEffect()
    let gitSend = fixture.gitSendEffect()
    let workflow = RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    let permits = try await RolloutEffectTaskContext.$current.withValue(workflow) {
      (
        provider: try await double.reserveProvider(provider, now: fixture.now),
        command: try await double.reserveApprovedCommand(command, now: fixture.now),
        gitSend: try await double.reserveGitSendAndMarkStarted(gitSend, now: fixture.now)
      )
    }

    try await fixture.asHistoricalCanary {
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "verify provider") {
        try await double.verifyProviderPermit(permits.provider, effect: provider)
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "bind provider") {
        try await double.bindProviderReservation(
          permits.provider, effect: provider, runID: "run", now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectAdmissionClosed, "bind command") {
        try await double.bindApprovedCommandReservation(
          permits.command, effect: command, runID: "run", now: fixture.now)
      }
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch, "verify gitSend") {
        try await double.verifyGitSendPermit(permits.gitSend, effect: gitSend)
      }
    }

    try await RolloutEffectTaskContext.$current.withValue(workflow) {
      try await double.verifyProviderPermit(permits.provider, effect: provider)
      try await double.bindProviderReservation(
        permits.provider, effect: provider, runID: "run", now: fixture.now)
      try await double.bindApprovedCommandReservation(
        permits.command, effect: command, runID: "run", now: fixture.now)
      try await double.verifyGitSendPermit(permits.gitSend, effect: gitSend)
    }
    await fixture.database.close()
  }

  // `RolloutEffectPermit.historicalCanary` is deliberately kept so historical rows and
  // permits keep decoding. The compiler enforces that: this file would not build
  // without the case. There is no test for it, because asserting that a value built one
  // line earlier equals itself would exercise synthesized Equatable and nothing else.
}

@Suite("Explicit command authority double")
struct ExplicitCommandAuthorityDoubleTests {
  @Test("command reservation requires the workflow identity and every effect field")
  func commandReservationParity() async throws {
    let fixture = try await HistoricalCanaryFixture()
    defer { fixture.remove() }
    let double = ExplicitTestRolloutEffectAuthority()
    let valid = fixture.commandEffect()
    await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
      _ = try await double.reserveApprovedCommand(valid, now: fixture.now)
    }
    await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: UUID()))
    ) {
      await #expect(throws: RolloutAuthorityError.effectIdentityMismatch) {
        _ = try await double.reserveApprovedCommand(valid, now: fixture.now)
      }
    }
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .workflow(jobID: fixture.jobID))
    ) {
      for field in ["command", "definition", "plan", "head", "round", "ordinal"] {
        let invalid = RolloutApprovedCommandEffect(
          jobID: valid.jobID,
          commandID: field == "command" ? "" : valid.commandID,
          definitionSHA256: field == "definition" ? "invalid" : valid.definitionSHA256,
          planSHA256: field == "plan" ? "invalid" : valid.planSHA256,
          workspaceHeadSHA: field == "head" ? "invalid" : valid.workspaceHeadSHA,
          phase: valid.phase, round: field == "round" ? 4 : valid.round,
          ordinal: field == "ordinal" ? -1 : valid.ordinal
        )
        let authorities: [any RolloutEffectAuthorizing] = [double, fixture.authority]
        for authority in authorities {
          await #expect(throws: RolloutAuthorityError.effectIdentityMismatch, "\(field)") {
            _ = try await authority.reserveApprovedCommand(invalid, now: fixture.now)
          }
        }
      }
      let permit = try await double.reserveApprovedCommand(valid, now: fixture.now)
      try await double.verifyApprovedCommandPermit(permit, effect: valid)
      try await double.settleEffect(
        permit, evidenceSHA256: String(repeating: "e", count: 64), now: fixture.now
      )
      #expect(await double.waitForDrain(until: fixture.now))
    }
    await fixture.database.close()
  }
}

private final class HistoricalCanaryFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let authority: RolloutAuthorityStore
  let now = Date(timeIntervalSince1970: 210_000)
  let repositoryID = UUID()
  let jobID = UUID()
  let intentID = UUID()

  init() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-historical-canary-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("jidoka-code.sqlite3"))
    authority = RolloutAuthorityStore(
      database: database,
      now: { Date(timeIntervalSince1970: 210_000) }
    )
    try await database.execute(
      """
      INSERT INTO repositories(id, node_id, owner, name, default_branch, created_at, updated_at)
      VALUES (?, 'repository-node', 'owner', 'repository', 'main', ?, ?)
      """,
      bindings: [
        .text(repositoryID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    // A historical canary job is generation 0: nothing ever bound it to schema-10 authority.
    try await database.execute(
      """
      INSERT INTO jobs(
        id, repository_id, kind, object_node_id, object_number, revision_key,
        contract_version_used, priority, state, current_step, current_step_kind,
        attempt, created_at, updated_at, rollout_generation
      ) VALUES (?, ?, 'prReview', 'pull-node', 1, 'head-revision', 'contract-v1', 1,
        'runningPi', 0, 'review', 1, ?, ?, 0)
      """,
      bindings: [
        .text(jobID.uuidString.lowercased()),
        .text(repositoryID.uuidString.lowercased()),
        .real(now.timeIntervalSince1970),
        .real(now.timeIntervalSince1970),
      ]
    )
    _ = try await MutationIntentStore(database: database).prepare(
      id: intentID,
      jobID: jobID,
      idempotencyKey: String(repeating: "d", count: 64),
      operation: .createMarkerComment,
      target: "pull-node",
      expectedStateDigest: String(repeating: "1", count: 64),
      requestDigest: String(repeating: "2", count: 64),
      now: now
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func asHistoricalCanary(_ body: () async throws -> Void) async throws {
    try await RolloutEffectTaskContext.$current.withValue(
      RolloutEffectExecutionContext(mode: .historicalCanary(jobID: jobID)),
      operation: body
    )
  }

  var context: RolloutEffectExecutionContext {
    RolloutEffectExecutionContext(mode: .historicalCanary(jobID: jobID))
  }

  func githubReadEffect() -> RolloutGitHubReadEffect {
    RolloutGitHubReadEffect(
      operation: .pullRequest(owner: "owner", repository: "repository", number: 1),
      maximumResponseBytes: 4_096,
      context: context
    )
  }

  func gitReadEffect() -> RolloutGitRemoteReadEffect {
    RolloutGitRemoteReadEffect(
      jobID: jobID,
      repositoryID: repositoryID,
      repositoryNodeID: "repository-node",
      operation: .fetchPullRequest,
      target: "refs/pull/1/head"
    )
  }

  func providerEffect() -> RolloutProviderEffect {
    RolloutProviderEffect(
      jobID: jobID,
      workflow: .pullRequestReview,
      role: .architecture,
      round: 1,
      runNonce: String(repeating: "3", count: 64),
      artifactSHA256: String(repeating: "4", count: 64),
      narrativeSHA256: String(repeating: "5", count: 64),
      planSHA256: nil,
      resourceSHA256: String(repeating: "6", count: 64),
      profileSHA256: String(repeating: "7", count: 64),
      sessionDirectiveSHA256: String(repeating: "8", count: 64)
    )
  }

  func commandEffect() -> RolloutApprovedCommandEffect {
    RolloutApprovedCommandEffect(
      jobID: jobID,
      commandID: "check",
      definitionSHA256: String(repeating: "9", count: 64),
      planSHA256: String(repeating: "a", count: 64),
      workspaceHeadSHA: String(repeating: "b", count: 40),
      phase: .bootstrap,
      round: 1,
      ordinal: 0
    )
  }

  func markerEffect(intentID: UUID) -> RolloutMarkerBatchEffect {
    RolloutMarkerBatchEffect(
      jobID: jobID,
      operation: .createMarkerComment,
      repositoryID: repositoryID,
      repository: GitHubRepositoryCoordinates(owner: "owner", repository: "repository"),
      repositoryNodeID: "repository-node",
      objectNodeID: "pull-node",
      objectNumber: 1,
      revision: "head-revision",
      markerKind: .review,
      authorID: 7,
      documentSHA256: String(repeating: "c", count: 64),
      generation: 0,
      intentIDs: [intentID]
    )
  }

  func githubSendEffect() -> RolloutGitHubSendEffect {
    RolloutGitHubSendEffect(
      jobID: jobID,
      intentID: intentID,
      mutation: .createMarkerComment,
      target: "pull-node",
      expectedStateSHA256: String(repeating: "1", count: 64),
      requestSHA256: String(repeating: "2", count: 64),
      operation: .createComment(
        owner: "owner",
        repository: "repository",
        number: 1,
        body: "historical"
      )
    )
  }

  func gitSendEffect() -> RolloutGitSendEffect {
    RolloutGitSendEffect(
      jobID: jobID,
      intentID: intentID,
      repositoryID: repositoryID,
      repositoryNodeID: "repository-node",
      branch: "jidoka/historical",
      exactSHA: String(repeating: "b", count: 40),
      target: "pull-node",
      expectedStateSHA256: String(repeating: "1", count: 64),
      requestSHA256: String(repeating: "2", count: 64)
    )
  }

  func reservationCount() async throws -> Int {
    var total = 0
    for table in [
      "rollout_effect_reservations", "rollout_scope_read_reservations",
      "rollout_readback_reservations", "rollout_git_readback_reservations",
    ] {
      total += Int(try await database.scalarInt("SELECT COUNT(*) FROM \(table)") ?? 0)
    }
    return total
  }

  func intentState() async throws -> String {
    let rows = try await database.query(
      "SELECT state FROM mutation_intents WHERE id = ?",
      bindings: [.text(intentID.uuidString.lowercased())]
    )
    guard case .text(let value)? = rows.first?["state"] else { return "missing" }
    return value
  }

  func rolloutGeneration() async throws -> Int {
    Int(try await database.scalarInt("SELECT rollout_generation FROM jobs") ?? -1)
  }
}
