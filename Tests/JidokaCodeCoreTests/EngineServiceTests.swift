import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Application engine service")
struct EngineServiceTests {
  @Test("onboarding persists exact prerequisites and never persists token bytes")
  func onboardingAndSecretBoundary() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let initial = try await fixture.service.snapshot()
    #expect(initial.lifecycle == .onboarding)
    #expect(Set(initial.settings.profiles.map(\.role)) == Set(ModelProfileRole.allCases))
    #expect(initial.settings.maxConcurrency == 2)

    _ = try await fixture.service.send(.acknowledgeExternalAutomation(true))
    _ = try await fixture.service.send(.acknowledgeProviderDisclosure(true))
    let sentinel = "github_pat_" + String(repeating: "w7-secret", count: 5)
    _ = try await fixture.service.send(.replaceCredential(Data(sentinel.utf8)))
    _ = try await fixture.service.send(
      .addRepository(
        EngineRepositoryDraft(
          owner: "owner",
          name: "repo",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true
        )
      )
    )
    _ = try await fixture.service.send(
      .synchronizeLoginStatus(selected: true, status: .enabled)
    )
    let completed = try await fixture.service.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)
    #expect(completed.state.onboarding.complete)
    #expect(completed.state.onboarding.credential.account == "octocat")
    #expect(completed.state.settings.repositories.count == 1)
    #expect(await fixture.external.sawCredential)
    #expect(await fixture.runtime.dispatchValues.last == true)

    let persisted = try await fixture.configuration.appConfiguration()
    #expect(persisted.onboardingComplete)
    #expect(persisted.externalAutomationAcknowledged)
    #expect(persisted.providerDisclosureAcknowledged)
    #expect(persisted.loginItemSelected)
    #expect(persisted.loginItemStatus == .enabled)

    _ = try await fixture.database.checkpoint()
    let forbidden = Data(sentinel.utf8)
    for url in [
      fixture.database.databaseURL,
      URL(fileURLWithPath: fixture.database.databaseURL.path + "-wal"),
      URL(fileURLWithPath: fixture.database.databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      let bytes = try Data(contentsOf: url)
      #expect(!bytes.contains(forbidden))
    }
  }

  @Test("consent withdrawal and profile changes durably close dispatch")
  func consentAndProfileBinding() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    try await fixture.completeOnboarding()

    let withdrawn = try await fixture.service.send(
      .acknowledgeProviderDisclosure(false)
    )
    #expect(withdrawn.state.lifecycle == .onboarding)
    #expect(!withdrawn.state.onboarding.providerDisclosureAcknowledged)
    #expect(await fixture.runtime.dispatchValues.last == false)

    _ = try await fixture.service.send(.acknowledgeProviderDisclosure(true))
    _ = try await fixture.service.send(.completeOnboarding)
    let changed = try await fixture.service.send(
      .setProfile(
        ModelProfileConfiguration(
          role: .review,
          provider: "configured-provider",
          model: "configured/model",
          thinking: .high
        )
      )
    )
    #expect(changed.state.lifecycle == .onboarding)
    #expect(!changed.state.onboarding.providerDisclosureAcknowledged)
    #expect(await fixture.runtime.dispatchValues.last == false)
  }

  @Test("wake and network regain forward only lifecycle scheduler reasons")
  func lifecycleTriggers() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.service.notifyLifecycleEvent(.wake)
    await fixture.service.notifyLifecycleEvent(.networkRegained)
    await fixture.service.notifyLifecycleEvent(.manual)
    #expect(await fixture.runtime.lifecycleReasons == [.wake, .networkRegained])
  }

  @Test("pause persists first and leaves an in-flight pass running")
  func pauseDoesNotInterruptInFlightPass() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.runtime.setPassRunning(true)

    let response = try await fixture.service.send(.setPaused(true))
    #expect(response.state.paused)
    #expect(response.state.passRunning)
    #expect(try await fixture.configuration.appConfiguration().paused)
    #expect(await fixture.runtime.pauseValues.last == true)
    #expect(await fixture.runtime.pauseObservedPersistedValues.last == true)
    #expect(await fixture.runtime.prepareCount == 0)

    _ = try await fixture.service.send(.setPaused(false))
    #expect(!(try await fixture.configuration.appConfiguration().paused))
    #expect(await fixture.runtime.pollCount == 0)
  }

  @Test("quit waits for the runtime checkpoint and returns durable evidence")
  func durableQuit() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    await fixture.runtime.setPassRunning(true)

    let response = try await fixture.service.send(.prepareForQuit)
    #expect(response.state.lifecycle == .quitting)
    #expect(response.state.paused)
    #expect(response.checkpoint?.databaseCheckpointed == true)
    #expect(response.checkpoint?.nonterminalJobCount == 0)
    #expect(await fixture.runtime.prepareCount == 1)
    #expect(try await fixture.configuration.appConfiguration().paused)
    await #expect(throws: EngineClientError(.busy)) {
      _ = try await fixture.service.send(.pollNow)
    }
  }

  @Test("ambiguous retry requires byte-exact current evidence")
  func exactAmbiguousAuthorization() async throws {
    let fixture = try await EngineServiceFixture()
    defer { fixture.remove() }
    let repository = try await fixture.addRepository()
    let job = try await fixture.makeAmbiguousJob(repositoryID: repository.id)

    let state = try await fixture.service.snapshot()
    let mutation = try #require(state.ambiguousMutations.first)
    #expect(state.operationalStatus == .warning)
    #expect(mutation.jobID == job.id)
    #expect(mutation.evidenceDigest == String(repeating: "4", count: 64))
    #expect(mutation.revisionKey == String(repeating: "a", count: 40))

    let exact = EngineAmbiguousMutationEvidence(mutation)
    let stale = EngineAmbiguousMutation(
      jobID: mutation.jobID,
      repositoryID: mutation.repositoryID,
      repositoryOwner: mutation.repositoryOwner,
      repositoryName: mutation.repositoryName,
      kind: mutation.kind,
      objectNodeID: mutation.objectNodeID,
      objectNumber: mutation.objectNumber,
      revisionKey: mutation.revisionKey,
      evidenceDigest: String(repeating: "5", count: 64),
      mutationGeneration: mutation.mutationGeneration,
      mutationID: mutation.mutationID
    )
    await #expect(throws: EngineClientError(.staleEvidence)) {
      _ = try await fixture.service.send(
        .authorizeRetry(EngineAmbiguousMutationEvidence(stale))
      )
    }

    _ = try await fixture.service.send(.recheckAmbiguousMutation(exact))
    #expect(await fixture.runtime.recheckedJobs == [job.id])
    let authorized = try await fixture.service.send(.authorizeRetry(exact))
    #expect(authorized.state.ambiguousMutations.isEmpty)
    #expect(try await fixture.jobs.job(id: job.id)?.state == .queued)
    #expect(try await fixture.jobs.job(id: job.id)?.attempt == 2)
    #expect(await fixture.runtime.pollCount == 1)
    #expect(await fixture.runtime.exclusiveBeginCount == 3)
    #expect(await fixture.runtime.exclusiveEndCount == 3)
  }
}

private actor EngineServiceExternalFake: EngineExternalServicing {
  private(set) var sawCredential = false
  private var status = EngineCredentialStatus.missing

  func credentialStatus() -> EngineCredentialStatus {
    status
  }

  func replaceCredential(
    _ token: Data,
    allowAccountChange: Bool
  ) -> EngineCredentialStatus {
    sawCredential = token.count >= 20
    status = EngineCredentialStatus(state: .valid, account: "octocat")
    return status
  }

  func deleteCredential() {
    status = .missing
  }

  func validateRepository(
    _ draft: EngineRepositoryDraft,
    existingID: UUID?
  ) -> RepositoryConfiguration {
    RepositoryConfiguration(
      id: existingID ?? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      nodeID: "R_node",
      owner: draft.owner,
      name: draft.name,
      defaultBranch: "main",
      reviewEnabled: draft.reviewEnabled,
      triageEnabled: draft.triageEnabled,
      implementationEnabled: draft.implementationEnabled,
      enabled: true
    )
  }

  func preflightPi() -> EnginePiStatus {
    EnginePiStatus(
      state: .ready,
      executablePath: "/opt/homebrew/bin/pi",
      version: "0.84.1",
      policySHA256: String(repeating: "f", count: 64)
    )
  }
}

private actor EngineServiceRuntimeFake: EngineJobRuntime {
  private(set) var dispatchValues: [Bool] = []
  private(set) var pauseValues: [Bool] = []
  private(set) var pauseObservedPersistedValues: [Bool] = []
  private(set) var pollCount = 0
  private(set) var lifecycleReasons: [SchedulerTriggerReason] = []
  private(set) var recheckedJobs: [UUID] = []
  private(set) var exclusiveBeginCount = 0
  private(set) var exclusiveEndCount = 0
  private(set) var prepareCount = 0
  private var passRunning = false
  private var pauseObserver: ConfigurationStore?

  func reload(dispatchAllowed: Bool) {
    dispatchValues.append(dispatchAllowed)
  }

  func setDispatchAllowed(_ allowed: Bool) {
    dispatchValues.append(allowed)
  }

  func setPaused(_ paused: Bool) async {
    pauseValues.append(paused)
    if let pauseObserver,
      let persisted = try? await pauseObserver.appConfiguration().paused
    {
      pauseObservedPersistedValues.append(persisted)
    }
  }

  func pollNow() {
    pollCount += 1
  }

  func requestLifecyclePass(_ reason: SchedulerTriggerReason) {
    lifecycleReasons.append(reason)
  }

  func beginExclusiveOperation() {
    exclusiveBeginCount += 1
  }

  func endExclusiveOperation() {
    exclusiveEndCount += 1
  }

  func recheckAmbiguousMutation(jobID: UUID) {
    recheckedJobs.append(jobID)
  }

  func waitUntilIdle() {}

  func timingSnapshot() -> SchedulerTimingSnapshot? {
    SchedulerTimingSnapshot(
      paused: pauseValues.last ?? false,
      passRunning: passRunning,
      pendingReasons: [],
      dueAt: nil,
      nextPeriodicAt: Date(timeIntervalSince1970: 999_999)
    )
  }

  func coordinatorSnapshot() -> JobCoordinatorSnapshot? {
    JobCoordinatorSnapshot(lastPass: nil, failures: [])
  }

  func prepareForCheckpoint() {
    prepareCount += 1
    passRunning = false
  }

  func setPassRunning(_ value: Bool) {
    passRunning = value
  }

  func observePausePersistence(using configuration: ConfigurationStore) {
    pauseObserver = configuration
  }
}

private final class EngineServiceFixture: @unchecked Sendable {
  let root: URL
  let database: SQLiteStore
  let configuration: ConfigurationStore
  let jobs: DurableJobStore
  let intents: MutationIntentStore
  let external: EngineServiceExternalFake
  let runtime: EngineServiceRuntimeFake
  let service: EngineService
  let now = Date(timeIntervalSince1970: 200_000)

  init() async throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-engine-\(UUID().uuidString)", isDirectory: true)
    database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    configuration = ConfigurationStore(database: database)
    jobs = DurableJobStore(database: database)
    intents = MutationIntentStore(database: database)
    external = EngineServiceExternalFake()
    runtime = EngineServiceRuntimeFake()
    await runtime.observePausePersistence(using: configuration)
    service = EngineService(
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      database: database,
      external: external,
      runtime: runtime,
      duplicateInstanceCheckPassed: true,
      now: { Date(timeIntervalSince1970: 200_000) }
    )
    try await service.initialize()
  }

  func completeOnboarding() async throws {
    _ = try await service.send(.acknowledgeExternalAutomation(true))
    _ = try await service.send(.acknowledgeProviderDisclosure(true))
    _ = try await service.send(
      .replaceCredential(Data(String(repeating: "t", count: 32).utf8))
    )
    _ = try await addRepository()
    _ = try await service.send(
      .synchronizeLoginStatus(selected: true, status: .enabled)
    )
    _ = try await service.send(.completeOnboarding)
  }

  func addRepository() async throws -> RepositoryConfiguration {
    let repository = RepositoryConfiguration(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      nodeID: "R_node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(repository, now: now)
    return repository
  }

  func makeAmbiguousJob(repositoryID: UUID) async throws -> JobRecord {
    let created = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repositoryID,
        kind: .prReview,
        objectNodeID: "PR_node",
        revisionKey: String(repeating: "a", count: 40)
      ),
      objectNumber: 7,
      contractVersionUsed: "w7-test",
      priority: .prReview,
      firstStep: .publish,
      now: now
    )
    guard case .created(let job) = created else {
      throw EngineClientError(.internalFailure)
    }
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:lease",
      event: .acquireLease,
      context: JobTransitionContext(now: now, reason: "fixture lease")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:inputs",
      event: .inputsValidated,
      context: JobTransitionContext(now: now, reason: "fixture inputs")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:execute",
      event: .selectLocalStep,
      context: JobTransitionContext(now: now, reason: "fixture mutation")
    )
    let intent = try await intents.prepare(
      jobID: job.id,
      idempotencyKey: String(repeating: "1", count: 64),
      operation: .createMarkerComment,
      target: "owner/repo/issues/7",
      expectedStateDigest: String(repeating: "2", count: 64),
      requestDigest: String(repeating: "3", count: 64),
      now: now
    )
    _ = try await intents.markSendStarted(id: intent.id, now: now)
    _ = try await intents.markReconcileRequired(id: intent.id, now: now)
    _ = try await intents.settle(
      id: intent.id,
      outcome: .escalation,
      evidenceDigest: String(repeating: "4", count: 64),
      now: now
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:reconcile",
      event: .mutationNeedsAttribution,
      context: JobTransitionContext(now: now, reason: "fixture read-back")
    )
    _ = try await jobs.transition(
      jobID: job.id,
      eventKey: "fixture:ambiguous",
      event: .ambiguousCreate,
      context: JobTransitionContext(now: now, reason: "fixture ambiguous")
    )
    return try #require(await jobs.job(id: job.id))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
