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
    model.repositoryOwner = "owner"
    model.repositoryName = "repo"
    await model.validateAndAddRepository()
    #expect(model.canComplete)
    #expect(await model.complete())
    #expect(model.state?.lifecycle == .ready)
    #expect(app.state?.lifecycle == .ready)
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
        .addRepository,
        .setLoginEnabled,
        .completeOnboarding,
      ]
    )
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
  }

  @Test("menu pause suppresses poll but durable quit still checkpoints")
  func menuPauseAndQuit() async {
    let fake = AppSupportEngineFake(onboardingComplete: true)
    let model = AppViewModel(client: fake)
    await model.refresh()
    #expect(model.canPoll)

    await model.togglePaused()
    #expect(model.state?.paused == true)
    #expect(!model.canPoll)
    await model.pollNow()
    #expect(await fake.pollCount == 0)

    await model.togglePaused()
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

  @Test("settings updates repositories, four profiles, concurrency, login, and credential")
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

    model.repositoryOwner = "second-owner"
    model.repositoryName = "second-repo"
    await model.addRepository()
    #expect(model.repositories.count == 2)
    #expect(model.repositoryOwner.isEmpty)
    #expect(model.repositoryName.isEmpty)
    let added = try #require(model.repositories.first(where: { $0.owner == "second-owner" }))
    await model.removeRepository(added)
    #expect(model.repositories.count == 1)

    for role in ModelProfileRole.allCases {
      model.setProfileProvider("configured-\(role.rawValue)", role: role)
      model.setProfileModel("configured/\(role.rawValue)", role: role)
      model.setProfileThinking(.high, role: role)
      await model.saveProfile(role: role)
      let profile = try #require(
        model.state?.settings.profiles.first(where: { $0.role == role })
      )
      #expect(profile.provider == "configured-\(role.rawValue)")
      #expect(profile.model == "configured/\(role.rawValue)")
      #expect(profile.thinking == .high)
    }
    model.maxConcurrency = 8
    await model.saveMaxConcurrency()
    await model.runHerdrPreflight()
    await model.focusInHerdr()
    #expect(await fake.focusCount == 1)
    #expect(model.state?.settings.maxConcurrency == 8)
    await model.setLoginItemEnabled(false)
    #expect(!model.loginItemSelected)

    let sentinel = "github_pat_" + String(repeating: "settings-secret", count: 3)
    model.replacementToken = sentinel
    await model.replaceCredential()
    #expect(model.replacementToken.isEmpty)
    #expect(model.credentialStatus.state == .valid)
    await model.deleteCredential()
    #expect(model.credentialStatus.state == .missing)
    #expect(!model.diagnostics.joined().contains(sentinel))
    #expect(Set(model.state?.settings.profiles.map(\.role) ?? []) == Set(ModelProfileRole.allCases))
    let commandKinds = await fake.commandKinds
    #expect(commandKinds.filter { $0 == .updateRepository }.count == 4)
    #expect(commandKinds.contains(.addRepository))
    #expect(commandKinds.contains(.removeRepository))
  }

  @Test("accessibility identifiers and user-facing errors are stable and secret-free")
  func accessibilityAndErrorCopy() {
    let identifiers = [
      JidokaAccessibilityID.menuStatus,
      JidokaAccessibilityID.pollNow,
      JidokaAccessibilityID.pauseResume,
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
      JidokaAccessibilityID.repositoryOwner,
      JidokaAccessibilityID.repositoryName,
      JidokaAccessibilityID.repositoryAdd,
      JidokaAccessibilityID.loginItem,
      JidokaAccessibilityID.onboardingComplete,
      JidokaAccessibilityID.settingsWindow,
      JidokaAccessibilityID.settingsHerdrPreflight,
      JidokaAccessibilityID.settingsFocusInHerdr,
      JidokaAccessibilityID.credentialReplacement,
      JidokaAccessibilityID.credentialDeletion,
      JidokaAccessibilityID.ambiguousRecheck,
      JidokaAccessibilityID.ambiguousAuthorize,
    ]
    #expect(Set(identifiers).count == identifiers.count)
    let sentinel = "github_pat_accessibility_secret"
    for code in EngineClientErrorCode.allCases {
      let message = PresentationCopy.message(for: EngineClientError(code))
      #expect(!message.title.isEmpty)
      #expect(!message.detail.isEmpty)
      #expect(!message.title.contains(sentinel))
      #expect(!message.detail.contains(sentinel))
    }
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
  private var maxConcurrency = 2
  private var loginSelected: Bool
  private var loginStatus: LifecycleServiceStatus
  private var externalAcknowledged: Bool
  private var providerAcknowledged: Bool
  private var ambiguousMutations: [EngineAmbiguousMutation]
  private var failures: [EngineCommandKind: EngineClientErrorCode] = [:]
  private var checkpointDatabaseSucceeded = true
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
    ambiguousMutations = ambiguous ? [Self.ambiguousMutation()] : []
  }

  func fail(_ command: EngineCommandKind, with code: EngineClientErrorCode) {
    failures[command] = code
  }

  func setCheckpointDatabaseSucceeded(_ value: Bool) {
    checkpointDatabaseSucceeded = value
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
          enabled: true
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
    case .recheckAmbiguousMutation:
      recheckCount += 1
    case .authorizeRetry(let evidence):
      authorizationEvidence = evidence
      ambiguousMutations.removeAll { $0.jobID == evidence.jobID }
    case .setLoginEnabled(let value):
      loginSelected = value
      loginStatus = value ? .enabled : .notRegistered
    case .synchronizeLoginStatus(let selected, let status):
      loginSelected = selected
      loginStatus = status
    case .completeOnboarding:
      guard externalAcknowledged, providerAcknowledged, pi.state == .ready,
        herdr.state == .ready, credential.state == .valid, !repositories.isEmpty, loginSelected,
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
        herdr: herdr
      ),
      diagnostics: EngineDiagnostics(
        schemaVersion: 2,
        nonterminalJobCount: ambiguousMutations.count,
        ambiguousMutationCount: ambiguousMutations.count,
        coordinatorFailureCodes: [],
        piIssueCode: pi.issueCode,
        herdrIssueCode: herdr.issueCode
      )
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
      version: "0.8.0",
      protocolVersion: 19,
      executableSHA256: String(repeating: "e", count: 64),
      schemaSHA256: String(repeating: "d", count: 64),
      policySHA256: String(repeating: "c", count: 64)
    )
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
