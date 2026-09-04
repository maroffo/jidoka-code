import Foundation
import JidokaCodeCore
import Testing

@testable import JidokaCodeAppSupport

@Suite("Fake-first application flow")
@MainActor
struct ViewModelFlowTests {
  @Test("onboarding requires every gate and clears secret input")
  func onboarding() async throws {
    let fake = AppSupportEngineFake(onboardingComplete: false)
    let app = AppViewModel(client: fake)
    let model = OnboardingViewModel(client: fake) { state in app.apply(state) }
    await model.refresh()
    #expect(!model.canComplete)

    await model.acknowledgeExternalAutomation(true)
    await model.runPiPreflight()
    await model.runHerdrPreflight()
    let sentinel = "github_pat_" + String(repeating: "view-secret", count: 4)
    model.token = sentinel
    await model.validateAndImportCredential()
    #expect(model.token.isEmpty)
    await model.acknowledgeProviderDisclosure(true)
    #expect(model.state?.settings.repositories.isEmpty == true)
    #expect(model.canComplete)
    #expect(await model.complete())
    #expect(model.state?.lifecycle == .ready)
    #expect(app.state?.lifecycle == .ready)
    #expect(!app.canPoll)
    #expect(app.pollingUnavailableReason == "Poll Now requires an active finite rollout window.")
    #expect(await fake.tokenWasReceived)

    let encoded = try JSONEncoder().encode(try #require(model.state))
    #expect(!encoded.contains(Data(sentinel.utf8)))
    #expect(
      await fake.commandKinds == [
        .snapshot,
        .acknowledgeExternalAutomation,
        .runPiPreflight,
        .runHerdrPreflight,
        .replaceCredential,
        .acknowledgeProviderDisclosure,
        .setLoginEnabled,
        .completeOnboarding,
      ]
    )

    let settings = SettingsViewModel(client: fake) { state in app.apply(state) }
    await settings.refresh()
    settings.repositoryReference = "owner/repo"
    await settings.addRepository()
    #expect(!app.canPoll)
    #expect(app.pollingUnavailableReason == "Poll Now requires an active finite rollout window.")
  }

  @Test("invalid credential error is actionable and redacted")
  func redactedFailure() async {
    let fake = AppSupportEngineFake(onboardingComplete: false)
    await fake.fail(.replaceCredential, with: .credentialRejected)
    let model = OnboardingViewModel(client: fake)
    await model.refresh()
    let sentinel = "github_pat_" + String(repeating: "never-display", count: 3)
    model.token = sentinel
    await model.validateAndImportCredential()
    #expect(model.token.isEmpty)
    #expect(model.message?.title == "Credential not accepted")
    #expect(!(model.message?.detail.contains(sentinel) ?? true))

    let accessFailure = PresentationCopy.message(
      for: EngineClientError(.credentialAccessFailed)
    )
    #expect(accessFailure.title == "Keychain access needs attention")
    #expect(accessFailure.detail.contains("signed engine helper"))
  }

  @Test("menu stop and drain suppresses poll but durable quit still checkpoints")
  func menuStopAndQuit() async {
    let fake = AppSupportEngineFake(onboardingComplete: true)
    await fake.activateFiniteRollout()
    let model = AppViewModel(client: fake)
    await model.refresh()
    #expect(model.canPoll)

    await model.pollNow()
    #expect(await fake.pollCount == 1)
    await model.stopAndDrain()
    #expect(model.state?.paused == true)
    #expect(!model.canPoll)
    await model.pollNow()
    #expect(await fake.pollCount == 1)
    #expect(await model.prepareForQuit()?.databaseCheckpointed == true)
    #expect(model.state?.lifecycle == .quitting)

    let failedCheckpointEngine = AppSupportEngineFake(onboardingComplete: true)
    await failedCheckpointEngine.setCheckpointDatabaseSucceeded(false)
    let failedCheckpointModel = AppViewModel(client: failedCheckpointEngine)
    await failedCheckpointModel.refresh()
    #expect(await failedCheckpointModel.prepareForQuit() == nil)
    #expect(failedCheckpointModel.message?.title == "Checkpoint failed")
    await failedCheckpointEngine.setCheckpointDatabaseSucceeded(true)
    #expect(await failedCheckpointModel.prepareForQuit()?.databaseCheckpointed == true)
  }

  @Test("durable quit waits for an in-flight refresh")
  func quitWaitsForRefresh() async {
    let client = DelayedSnapshotEngineClient()
    let model = AppViewModel(client: client)
    let refresh = Task { @MainActor in await model.refresh() }
    for _ in 0..<100 {
      if model.isWorking { break }
      await Task.yield()
    }
    #expect(model.isWorking)

    let checkpoint = await model.prepareForQuit()
    await refresh.value

    #expect(checkpoint?.databaseCheckpointed == true)
    #expect(model.state?.lifecycle == .quitting)
    #expect(await client.observedCommandKinds() == [.snapshot, .prepareForQuit])
  }

  @Test("polling reports one deterministic blocker for every dispatch gate")
  func pollingBlockers() async throws {
    let fake = AppSupportEngineFake(onboardingComplete: true)
    await fake.activateFiniteRollout()
    let model = AppViewModel(client: fake)
    await model.refresh()
    let ready = try #require(model.state)
    #expect(model.canPoll)

    let cases: [(EngineUIState, String)] = [
      (
        pollingState(ready, lifecycle: .onboarding),
        "Finish setup to enable polling."
      ),
      (
        pollingState(ready, includeRollout: false),
        "Poll Now requires an active finite rollout window."
      ),
      (
        pollingState(ready, credential: .missing),
        "Connect GitHub in Settings to poll."
      ),
      (
        pollingState(ready, pi: .unchecked),
        "Restore the attested Pi runtime, then restart Jidoka Code."
      ),
      (
        pollingState(ready, herdr: .unchecked),
        "Restore Herdr readiness before polling."
      ),
      (
        pollingState(ready, repositories: []),
        "The rollout repository is not enabled."
      ),
      (
        pollingState(ready, loginSelected: false, loginStatus: .notRegistered),
        "Enable the login item before polling."
      ),
      (
        pollingState(ready, profiles: Array(ready.settings.profiles.dropLast())),
        "Configure every model profile before polling."
      ),
    ]

    for (state, reason) in cases {
      model.apply(state)
      #expect(!model.canPoll)
      #expect(model.pollingUnavailableReason == reason)
      await model.pollNow()
    }
    #expect(await fake.pollCount == 0)

    model.apply(ready)
    await model.pollNow()
    #expect(await fake.pollCount == 1)
  }

  @Test("ambiguous UI emits only late recheck or exact authorization")
  func ambiguousControls() async throws {
    let fake = AppSupportEngineFake(onboardingComplete: true, ambiguous: true)
    let model = AppViewModel(client: fake)
    await model.refresh()
    let mutation = try #require(model.state?.ambiguousMutations.first)

    await model.recheck(mutation)
    #expect(await fake.recheckCount == 1)
    #expect(model.state?.ambiguousMutations.count == 1)
    model.requestRetryAuthorization(mutation)
    await model.authorizePendingRetry()
    #expect(model.state?.ambiguousMutations.isEmpty == true)
    #expect(await fake.authorizationEvidence == EngineAmbiguousMutationEvidence(mutation))
    let commandKinds = await fake.commandKinds
    #expect(!commandKinds.contains(where: { $0.rawValue.lowercased().contains("abort") }))
  }

  @Test("repository parser accepts GitHub URL and owner/repository only")
  func repositoryParser() {
    #expect(
      RepositoryReferenceParser.parse("https://github.com/second-owner/second-repo.git")
        == RepositoryCoordinates(owner: "second-owner", name: "second-repo")
    )
    #expect(
      RepositoryReferenceParser.parse(" second-owner/second-repo ")
        == RepositoryCoordinates(owner: "second-owner", name: "second-repo")
    )
    #expect(
      RepositoryReferenceParser.parse("https://github.com/second-owner/second-repo/")
        == RepositoryCoordinates(owner: "second-owner", name: "second-repo")
    )
    for invalid in [
      "http://github.com/owner/repo",
      "https://github.example/owner/repo",
      "https://user@github.com/owner/repo",
      "https://github.com/owner/repo/issues",
      "git@github.com:owner/repo.git",
      "owner",
      "owner//repo",
      "owner/repo/extra",
      "-owner/repo",
    ] {
      #expect(RepositoryReferenceParser.parse(invalid) == nil)
    }
  }

  @Test("settings lazily refreshes once and preserves Custom drafts across catalog changes")
  func modelCatalogDrafts() async throws {
    let fake = AppSupportEngineFake(onboardingComplete: true)
    let model = SettingsViewModel(client: fake)

    await model.refresh()
    #expect(await fake.commandKinds == [.snapshot, .refreshModelCatalog])
    await model.refresh()
    #expect(await fake.commandKinds == [.snapshot, .refreshModelCatalog, .snapshot])

    model.setProfileSource(.custom, role: .review)
    model.setProfileProvider(" unsaved-provider ", role: .review)
    model.setProfileModel(" unsaved/model ", role: .review)
    model.setProfileThinking(.xhigh, role: .review)
    model.selectCatalogModel("anthropic/claude-sonnet-4-6", role: .review)
    #expect(model.profileDrafts[.review]?.thinking == .medium)
    model.setProfileSource(.custom, role: .review)
    #expect(model.profileDrafts[.review]?.provider == " unsaved-provider ")
    #expect(model.profileDrafts[.review]?.model == " unsaved/model ")
    #expect(model.profileDrafts[.review]?.thinking == .xhigh)

    await model.refreshModelCatalog()
    #expect(model.profileDrafts[.review]?.provider == " unsaved-provider ")
    #expect(model.profileDrafts[.review]?.model == " unsaved/model ")
    await model.saveProfile(role: .review)
    #expect(model.profileDrafts[.review]?.provider == "unsaved-provider")
    #expect(model.profileDrafts[.review]?.model == "unsaved/model")
    #expect(!model.profileIsDirty(.review))

    let reopened = SettingsViewModel(client: fake)
    await reopened.refresh()
    #expect(reopened.profileDrafts[.review]?.source == .custom)
    #expect(reopened.profileDrafts[.review]?.provider == "unsaved-provider")
    #expect(reopened.profileDrafts[.review]?.model == "unsaved/model")

    await fake.fail(.refreshModelCatalog, with: .internalFailure)
    await reopened.refreshModelCatalog()
    #expect(reopened.modelCatalog.isEmpty)
    #expect(reopened.message?.title == "Pi model catalog unavailable")
    #expect(reopened.modelCatalogNotice == reopened.message?.detail)

    let automaticFailure = AppSupportEngineFake(onboardingComplete: true)
    await automaticFailure.fail(.refreshModelCatalog, with: .piBlocked)
    let automatic = SettingsViewModel(client: automaticFailure)
    await automatic.refresh()
    #expect(automatic.modelCatalog.isEmpty)
    #expect(automatic.message == nil)
    #expect(automatic.modelCatalogNotice?.contains("offline model catalog") == true)
    #expect(
      await automaticFailure.commandKinds == [
        .snapshot, .refreshModelCatalog, .snapshot,
      ])
    await automatic.refresh()
    #expect(
      await automaticFailure.commandKinds == [
        .snapshot, .refreshModelCatalog, .snapshot, .snapshot,
      ])
    await automatic.refreshModelCatalog()
    #expect(automatic.message?.title == "Pi model catalog unavailable")
    #expect(automatic.modelCatalogNotice == automatic.message?.detail)
    #expect(
      await automaticFailure.commandKinds == [
        .snapshot, .refreshModelCatalog, .snapshot, .snapshot,
        .refreshModelCatalog, .snapshot,
      ])
  }

  @Test("settings updates repositories, Pi catalog profiles, concurrency, login, and credential")
  func settings() async throws {
    let fake = AppSupportEngineFake(onboardingComplete: true)
    let model = SettingsViewModel(client: fake)
    await model.refresh()
    let repository = try #require(model.repositories.first)

    await model.setRepositoryEnabled(repository, value: false)
    await model.setReviewEnabled(repository, value: false)
    await model.setTriageEnabled(repository, value: false)
    await model.setImplementationEnabled(repository, value: false)
    let toggled = try #require(model.repositories.first)
    #expect(!toggled.enabled)
    #expect(!toggled.reviewEnabled)
    #expect(!toggled.triageEnabled)
    #expect(!toggled.implementationEnabled)

    model.repositoryReference = "https://github.com/second-owner/second-repo.git"
    #expect(model.canAddRepository)
    await model.addRepository()
    #expect(model.repositories.count == 2)
    #expect(model.repositoryReference.isEmpty)
    let added = try #require(model.repositories.first(where: { $0.owner == "second-owner" }))
    await model.removeRepository(added)
    #expect(model.repositories.count == 1)

    for role in ModelProfileRole.allCases {
      #expect(model.profileDrafts[role]?.source == .catalog)
      model.selectCatalogModel("anthropic/claude-sonnet-4-6", role: role)
      #expect(model.availableThinkingLevels(role: role) == [.off, .low, .medium, .high])
      model.setProfileThinking(.high, role: role)
      await model.saveProfile(role: role)
      let profile = try #require(
        model.state?.settings.profiles.first(where: { $0.role == role })
      )
      #expect(profile.provider == "anthropic")
      #expect(profile.model == "claude-sonnet-4-6")
      #expect(profile.thinking == .high)
    }
    model.setProfileSource(.custom, role: .review)
    #expect(model.profileDrafts[.review]?.provider == "openai-codex")
    #expect(model.profileDrafts[.review]?.model == "gpt-5.6-sol")
    model.setProfileProvider("configured-review", role: .review)
    model.setProfileModel("configured/review", role: .review)
    model.setProfileThinking(.xhigh, role: .review)
    await model.saveProfile(role: .review)
    #expect(model.profileDrafts[.review]?.source == .custom)
    model.maxConcurrency = 1
    await model.saveMaxConcurrency()
    await model.runHerdrPreflight()
    await model.focusInHerdr()
    #expect(await fake.focusCount == 1)
    #expect(model.state?.settings.maxConcurrency == 1)
    await model.setLoginItemEnabled(false)
    #expect(!model.loginItemSelected)

    let sentinel = "github_pat_" + String(repeating: "settings-secret", count: 3)
    model.replacementToken = sentinel
    await model.replaceCredential()
    #expect(model.replacementToken.isEmpty)
    #expect(model.credentialStatus.state == .valid)
    await model.deleteCredential()
    #expect(model.credentialStatus.state == .missing)
    #expect(model.replacementToken.isEmpty)
    #expect(!model.diagnostics.joined().contains(sentinel))
    #expect(Set(model.state?.settings.profiles.map(\.role) ?? []) == Set(ModelProfileRole.allCases))
    let commandKinds = await fake.commandKinds
    #expect(commandKinds.filter { $0 == .updateRepository }.count == 4)
    #expect(commandKinds.contains(.addRepository))
    #expect(commandKinds.contains(.removeRepository))
  }

  private func pollingState(
    _ base: EngineUIState,
    lifecycle: EngineLifecycleState? = nil,
    paused: Bool? = nil,
    credential: EngineCredentialStatus? = nil,
    pi: EnginePiStatus? = nil,
    herdr: EngineHerdrStatus? = nil,
    repositories: [RepositoryConfiguration]? = nil,
    loginSelected: Bool? = nil,
    loginStatus: LifecycleServiceStatus? = nil,
    profiles: [ModelProfileConfiguration]? = nil,
    includeRollout: Bool = true
  ) -> EngineUIState {
    let lifecycle = lifecycle ?? base.lifecycle
    let credential = credential ?? base.settings.credential
    let pi = pi ?? base.onboarding.pi
    let herdr = herdr ?? base.settings.herdr
    let repositories = repositories ?? base.settings.repositories
    let loginSelected = loginSelected ?? base.settings.loginItemSelected
    let loginStatus = loginStatus ?? base.settings.loginItemStatus
    let profiles = profiles ?? base.settings.profiles
    return EngineUIState(
      revision: base.revision,
      lifecycle: lifecycle,
      operationalStatus: base.operationalStatus,
      paused: paused ?? base.paused,
      passRunning: base.passRunning,
      activities: base.activities,
      ambiguousMutations: base.ambiguousMutations,
      onboarding: EngineOnboardingSnapshot(
        duplicateInstanceCheckPassed: base.onboarding.duplicateInstanceCheckPassed,
        externalAutomationAcknowledged: base.onboarding.externalAutomationAcknowledged,
        providerDisclosureAcknowledged: base.onboarding.providerDisclosureAcknowledged,
        pi: pi,
        herdr: herdr,
        credential: credential,
        repositoryCount: repositories.count,
        configuredProfileRoles: profiles.map(\.role),
        loginItemSelected: loginSelected,
        loginItemStatus: loginStatus,
        complete: lifecycle == .ready
      ),
      settings: EngineSettingsSnapshot(
        repositories: repositories,
        profiles: profiles,
        maxConcurrency: base.settings.maxConcurrency,
        loginItemSelected: loginSelected,
        loginItemStatus: loginStatus,
        credential: credential,
        herdr: herdr,
        modelCatalog: base.settings.modelCatalog
      ),
      diagnostics: base.diagnostics,
      rollout: includeRollout ? base.rollout : nil
    )
  }

  @Test("accessibility identifiers and user-facing errors are stable and secret-free")
  func accessibilityAndErrorCopy() {
    let identifiers = [
      JidokaAccessibilityID.menuStatus,
      JidokaAccessibilityID.pollNow,
      JidokaAccessibilityID.rolloutStop,
      JidokaAccessibilityID.rolloutRecovery,
      JidokaAccessibilityID.focusInHerdr,
      JidokaAccessibilityID.settings,
      JidokaAccessibilityID.openLogs,
      JidokaAccessibilityID.quit,
      JidokaAccessibilityID.onboardingWindow,
      JidokaAccessibilityID.externalAutomationDisclosure,
      JidokaAccessibilityID.piPreflight,
      JidokaAccessibilityID.herdrPreflight,
      JidokaAccessibilityID.tokenField,
      JidokaAccessibilityID.tokenImport,
      JidokaAccessibilityID.providerDisclosure,
      "\(JidokaAccessibilityID.providerDisclosureProfile).orchestration",
      "\(JidokaAccessibilityID.providerDisclosureProfile).planning",
      "\(JidokaAccessibilityID.providerDisclosureProfile).review",
      "\(JidokaAccessibilityID.providerDisclosureProfile).triage",
      JidokaAccessibilityID.loginItem,
      JidokaAccessibilityID.onboardingComplete,
      JidokaAccessibilityID.settingsWindow,
      JidokaAccessibilityID.settingsHerdrPreflight,
      JidokaAccessibilityID.settingsFocusInHerdr,
      JidokaAccessibilityID.settingsRepositoryReference,
      JidokaAccessibilityID.settingsRepositoryAdd,
      JidokaAccessibilityID.rolloutInput,
      JidokaAccessibilityID.rolloutPreview,
      JidokaAccessibilityID.rolloutCanonical,
      JidokaAccessibilityID.rolloutConfirmation,
      JidokaAccessibilityID.rolloutActivate,
      JidokaAccessibilityID.settingsModelCatalogRefresh,
      JidokaAccessibilityID.settingsModelCatalogNotice,
      JidokaAccessibilityID.settingsModelSelector,
      JidokaAccessibilityID.settingsCustomModel,
      JidokaAccessibilityID.credentialConnect,
      JidokaAccessibilityID.credentialReplacement,
      JidokaAccessibilityID.credentialDeletion,
      JidokaAccessibilityID.ambiguousRecheck,
      JidokaAccessibilityID.ambiguousAuthorize,
    ]
    #expect(Set(identifiers).count == identifiers.count)
    let sentinel = "github_pat_accessibility_secret"
    let catalogMessage = PresentationCopy.modelCatalogUnavailable()
    #expect(!catalogMessage.title.contains(sentinel))
    #expect(!catalogMessage.detail.contains(sentinel))
    #expect(catalogMessage.title != "Pi preflight blocked")
    for code in EngineClientErrorCode.allCases {
      let message = PresentationCopy.message(for: EngineClientError(code))
      #expect(!message.title.isEmpty)
      #expect(!message.detail.isEmpty)
      #expect(!message.title.contains(sentinel))
      #expect(!message.detail.contains(sentinel))
    }
  }
}

private actor DelayedSnapshotEngineClient: EngineClient {
  private let base = AppSupportEngineFake(onboardingComplete: true)

  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    if command.kind == .snapshot {
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    return try await base.send(command)
  }

  func observedCommandKinds() async -> [EngineCommandKind] {
    await base.commandKinds
  }
}

private actor AppSupportEngineFake: EngineClient {
  private var lifecycle: EngineLifecycleState
  private var paused = false
  private var pi = EnginePiStatus.unchecked
  private var herdr = EngineHerdrStatus.unchecked
  private var credential = EngineCredentialStatus.missing
  private var repositories: [RepositoryConfiguration]
  private var profiles: [ModelProfileConfiguration]
  private var modelCatalog: PiModelCatalog
  private var maxConcurrency = 1
  private var loginSelected: Bool
  private var loginStatus: LifecycleServiceStatus
  private var externalAcknowledged: Bool
  private var providerAcknowledged: Bool
  private var ambiguousMutations: [EngineAmbiguousMutation]
  private var failures: [EngineCommandKind: EngineClientErrorCode] = [:]
  private var checkpointDatabaseSucceeded = true
  private var rolloutState: RolloutAuthorizationState?
  private var revision = 0

  private(set) var commandKinds: [EngineCommandKind] = []
  private(set) var tokenWasReceived = false
  private(set) var pollCount = 0
  private(set) var focusCount = 0
  private(set) var recheckCount = 0
  private(set) var authorizationEvidence: EngineAmbiguousMutationEvidence?

  init(onboardingComplete: Bool, ambiguous: Bool = false) {
    lifecycle = onboardingComplete ? .ready : .onboarding
    externalAcknowledged = onboardingComplete
    providerAcknowledged = onboardingComplete
    loginSelected = onboardingComplete
    loginStatus = onboardingComplete ? .enabled : .notRegistered
    pi =
      onboardingComplete
      ? EnginePiStatus(
        state: .ready,
        executablePath: "/opt/homebrew/bin/pi",
        version: "0.84.1",
        policySHA256: String(repeating: "f", count: 64)
      ) : .unchecked
    herdr = onboardingComplete ? Self.readyHerdr() : .unchecked
    credential =
      onboardingComplete
      ? EngineCredentialStatus(state: .valid, account: "octocat") : .missing
    repositories = onboardingComplete ? [Self.repository()] : []
    profiles = ModelProfileRole.allCases.map {
      ModelProfileConfiguration(
        role: $0,
        provider: "openai-codex",
        model: "gpt-5.6-sol",
        thinking: .max
      )
    }
    modelCatalog = .unavailable
    ambiguousMutations = ambiguous ? [Self.ambiguousMutation()] : []
  }

  func fail(_ command: EngineCommandKind, with code: EngineClientErrorCode) {
    failures[command] = code
    if command == .refreshModelCatalog { modelCatalog = .unavailable }
  }

  func setCheckpointDatabaseSucceeded(_ value: Bool) {
    checkpointDatabaseSucceeded = value
  }

  func activateFiniteRollout() {
    rolloutState = .active
    paused = false
  }

  func send(_ command: EngineCommand) throws -> EngineCommandResponse {
    commandKinds.append(command.kind)
    if let failure = failures[command.kind] {
      throw EngineClientError(failure)
    }
    var checkpoint: EngineCheckpointReceipt?
    switch command {
    case .snapshot:
      break
    case .refreshModelCatalog:
      modelCatalog = Self.catalog()
    case .acknowledgeExternalAutomation(let value):
      externalAcknowledged = value
    case .acknowledgeProviderDisclosure(let value):
      providerAcknowledged = value
    case .runPiPreflight:
      pi = EnginePiStatus(
        state: .ready,
        executablePath: "/opt/homebrew/bin/pi",
        version: "0.84.1",
        policySHA256: String(repeating: "f", count: 64)
      )
    case .runHerdrPreflight:
      herdr = Self.readyHerdr()
    case .focusInHerdr:
      guard herdr.state == .ready else { throw EngineClientError(.herdrBlocked) }
      focusCount += 1
    case .replaceCredential(let token):
      tokenWasReceived = token.count >= 20
      credential = EngineCredentialStatus(state: .valid, account: "octocat")
    case .deleteCredential:
      credential = .missing
    case .addRepository(let draft):
      let existingID = repositories.first(where: {
        $0.owner == draft.owner && $0.name == draft.name
      })?.id
      repositories.removeAll { $0.owner == draft.owner && $0.name == draft.name }
      repositories.append(
        RepositoryConfiguration(
          id: existingID ?? UUID(),
          nodeID: "R_\(draft.owner)_\(draft.name)",
          owner: draft.owner,
          name: draft.name,
          defaultBranch: "main",
          reviewEnabled: draft.reviewEnabled,
          triageEnabled: draft.triageEnabled,
          implementationEnabled: draft.implementationEnabled,
          enabled: draft.enabled
        )
      )
    case .updateRepository(let repository):
      repositories = repositories.map { $0.id == repository.id ? repository : $0 }
    case .removeRepository(let id):
      repositories.removeAll { $0.id == id }
    case .setProfile(let profile):
      profiles.removeAll { $0.role == profile.role }
      profiles.append(profile)
      profiles.sort { $0.role.rawValue < $1.role.rawValue }
    case .setMaxConcurrency(let value):
      maxConcurrency = value
    case .setPaused(let value):
      paused = value
    case .pollNow:
      pollCount += 1
    case .rolloutStatus:
      break
    case .stopAndDrainRollout(let request):
      guard let rollout = makeRolloutReport(),
        rollout.status.authorization.id == request.authorizationID,
        rollout.status.authorization.previewSHA256 == request.previewSHA256
      else { throw EngineClientError(.invalidCommand) }
      rolloutState = .revoked
      paused = true
    case .previewRollout, .activateRollout,
      .previewRolloutRecovery, .executeRolloutRecovery,
      .previewFiniteWindow, .activateFiniteWindow:
      throw EngineClientError(.invalidCommand)
    case .recheckAmbiguousMutation:
      recheckCount += 1
    case .authorizeRetry(let evidence):
      authorizationEvidence = evidence
      ambiguousMutations.removeAll { $0.jobID == evidence.jobID }
    case .previewJobMaintenance, .applyJobMaintenance,
      .previewJobCanary, .executeJobCanary,
      .previewJobCanaryRecovery, .executeJobCanaryRecovery,
      .previewJobCanaryPiRetry, .executeJobCanaryPiRetry,
      .previewJobCanaryRoleHostReplacement, .executeJobCanaryRoleHostReplacement,
      .previewJobCanaryGenerationRollover, .executeJobCanaryGenerationRollover,
      .previewJobCanaryGenerationRolloverQ4, .executeJobCanaryGenerationRolloverQ4:
      throw EngineClientError(.invalidCommand)
    case .setLoginEnabled(let value):
      loginSelected = value
      loginStatus = value ? .enabled : .notRegistered
    case .synchronizeLoginStatus(let selected, let status):
      loginSelected = selected
      loginStatus = status
    case .completeOnboarding:
      guard externalAcknowledged, providerAcknowledged, pi.state == .ready,
        herdr.state == .ready, credential.state == .valid, loginSelected,
        loginStatus == .enabled
      else {
        throw EngineClientError(.onboardingIncomplete)
      }
      lifecycle = .ready
    case .rollbackOnboarding:
      lifecycle = .onboarding
    case .prepareForHandoff:
      checkpoint = makeCheckpoint()
    case .prepareForQuit:
      paused = true
      lifecycle = .quitting
      checkpoint = makeCheckpoint()
    }
    revision += 1
    return EngineCommandResponse(
      command: command.kind,
      state: makeState(),
      checkpoint: checkpoint
    )
  }

  private func makeState() -> EngineUIState {
    let complete = lifecycle != .onboarding
    let onboarding = EngineOnboardingSnapshot(
      duplicateInstanceCheckPassed: true,
      externalAutomationAcknowledged: externalAcknowledged,
      providerDisclosureAcknowledged: providerAcknowledged,
      pi: pi,
      herdr: herdr,
      credential: credential,
      repositoryCount: repositories.count,
      configuredProfileRoles: profiles.map(\.role),
      loginItemSelected: loginSelected,
      loginItemStatus: loginStatus,
      complete: complete
    )
    return EngineUIState(
      revision: revision,
      lifecycle: lifecycle,
      operationalStatus: !ambiguousMutations.isEmpty ? .warning : paused ? .paused : .active,
      paused: paused,
      passRunning: false,
      activities: [],
      ambiguousMutations: ambiguousMutations,
      onboarding: onboarding,
      settings: EngineSettingsSnapshot(
        repositories: repositories,
        profiles: profiles,
        maxConcurrency: maxConcurrency,
        loginItemSelected: loginSelected,
        loginItemStatus: loginStatus,
        credential: credential,
        herdr: herdr,
        modelCatalog: modelCatalog
      ),
      diagnostics: EngineDiagnostics(
        schemaVersion: 2,
        nonterminalJobCount: ambiguousMutations.count,
        ambiguousMutationCount: ambiguousMutations.count,
        coordinatorFailureCodes: [],
        piIssueCode: pi.issueCode,
        herdrIssueCode: herdr.issueCode
      ),
      rollout: makeRolloutReport()
    )
  }

  private func makeRolloutReport() -> RolloutOperatorReport? {
    guard let rolloutState else { return nil }
    let repository = Self.repository()
    let digest = String(repeating: "a", count: 64)
    let authorization = RolloutAuthorization(
      id: "44444444-4444-4444-4444-444444444444",
      previewSHA256: digest,
      state: rolloutState,
      scopeMode: .finiteWindow,
      workflowStage: .prReview,
      repositoryID: repository.id,
      activatedAtMilliseconds: 300_000,
      expiresAtMilliseconds: 600_000,
      updatedAtMilliseconds: 300_000,
      terminalReason: rolloutState == .revoked ? "OPERATOR_STOPPED" : nil
    )
    let release = RolloutReleaseIdentity(
      sourceCommit: String(repeating: "1", count: 40),
      sourceTree: String(repeating: "2", count: 40),
      bundleVersion: "1.0.0",
      bundleBuild: 1,
      applicationSHA256: digest,
      helperSHA256: String(repeating: "b", count: 64),
      askPassSHA256: String(repeating: "b", count: 64),
      pushGuardSHA256: String(repeating: "b", count: 64),
      herdrHostSHA256: String(repeating: "c", count: 64),
      schemaVersion: 10,
      engineProtocolVersion: 12,
      runtimeManifestSHA256: String(repeating: "d", count: 64),
      runtimeTreeSHA256: String(repeating: "e", count: 64),
      modelProfilesSHA256: String(repeating: "f", count: 64),
      workflowResourcesSHA256: String(repeating: "0", count: 64),
      githubAccount: "octocat",
      githubAuthorID: 1,
      repositoryConfigurationSHA256: String(repeating: "3", count: 64),
      maxConcurrency: 1
    )
    let scope = RolloutScope(
      mode: .finiteWindow,
      stage: .prReview,
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
      object: nil,
      finiteWindow: RolloutFiniteWindowSelector(
        maximumJobs: 1,
        expiresAtMilliseconds: 600_000,
        candidates: []
      )
    )
    return RolloutOperatorReport(
      status: RolloutStatusReport(
        authorization: authorization,
        releaseIdentity: release,
        scope: scope,
        effectEnvelope: RolloutEffectEnvelope(
          stage: .prReview,
          currentStep: JobStepKind.review.rawValue,
          allowances: []
        ),
        missingLabels: [],
        commands: [],
        initialBudgets: .zero,
        remainingBudgets: .zero,
        boundJobIDs: [],
        reservations: [],
        events: []
      ),
      jobs: [],
      checkpointSHA256: nil
    )
  }

  private func makeCheckpoint() -> EngineCheckpointReceipt {
    EngineCheckpointReceipt(
      checkpointID: UUID(),
      completedAt: Date(timeIntervalSince1970: 300_000),
      nonterminalJobCount: ambiguousMutations.count,
      ambiguousMutationCount: ambiguousMutations.count,
      databaseCheckpointed: checkpointDatabaseSucceeded
    )
  }

  private static func readyHerdr() -> EngineHerdrStatus {
    EngineHerdrStatus(
      state: .ready,
      version: "0.8.2",
      protocolVersion: 20,
      executableSHA256: String(repeating: "e", count: 64),
      schemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
  }

  private static func catalog() -> PiModelCatalog {
    PiModelCatalog(
      models: [
        PiModelCatalogEntry(
          provider: "openai-codex",
          id: "gpt-5.6-sol",
          name: "GPT-5.6 Sol",
          reasoning: true,
          input: [.text, .image],
          contextWindow: 200_000,
          maxTokens: 64_000,
          thinkingLevels: ModelThinkingLevel.allCases
        ),
        PiModelCatalogEntry(
          provider: "anthropic",
          id: "claude-sonnet-4-6",
          name: "Claude Sonnet 4.6",
          reasoning: true,
          input: [.text, .image],
          contextWindow: 200_000,
          maxTokens: 64_000,
          thinkingLevels: [.off, .low, .medium, .high]
        ),
      ])
  }

  private static func repository() -> RepositoryConfiguration {
    RepositoryConfiguration(
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
  }

  private static func ambiguousMutation() -> EngineAmbiguousMutation {
    EngineAmbiguousMutation(
      jobID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      repositoryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      repositoryOwner: "owner",
      repositoryName: "repo",
      kind: .prReview,
      objectNodeID: "PR_node",
      objectNumber: 7,
      revisionKey: String(repeating: "a", count: 40),
      evidenceDigest: String(repeating: "b", count: 64),
      mutationGeneration: 1,
      mutationID: "33333333-3333-3333-3333-333333333333"
    )
  }
}
