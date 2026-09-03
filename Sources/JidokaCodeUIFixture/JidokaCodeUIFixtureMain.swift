import AppKit
import CryptoKit
import Foundation
import JidokaCodeAppSupport
import JidokaCodeCore
import SwiftUI

private struct UIFixtureScreenshot: Codable {
  let filename: String
  let sha256: String
  let width: Int
  let height: Int
  let declaredAccessibilityIdentifiers: [String]
  let declaredAccessibilityLabels: [String]
  let observedAccessibilityIdentifiers: [String]
  let observedAccessibilityLabels: [String]
}

private struct UIFixtureAccessibilityContract {
  let identifiers: [String]
  let labels: [String]

  static func value(for filename: String) -> UIFixtureAccessibilityContract {
    switch filename {
    case "onboarding-first-run.png":
      UIFixtureAccessibilityContract(
        identifiers: [
          JidokaAccessibilityID.onboardingWindow,
          JidokaAccessibilityID.externalAutomationDisclosure,
          JidokaAccessibilityID.piPreflight,
          JidokaAccessibilityID.tokenField,
          JidokaAccessibilityID.tokenImport,
          JidokaAccessibilityID.providerDisclosure,
          "\(JidokaAccessibilityID.providerDisclosureProfile).orchestration",
          "\(JidokaAccessibilityID.providerDisclosureProfile).planning",
          "\(JidokaAccessibilityID.providerDisclosureProfile).review",
          "\(JidokaAccessibilityID.providerDisclosureProfile).triage",
          JidokaAccessibilityID.loginItem,
          JidokaAccessibilityID.onboardingComplete,
        ],
        labels: [
          "Automation coexistence",
          "Run Pi Preflight",
          "GitHub token",
          "Validate and Import",
          "Provider and source disclosure",
          "Orchestration: openai-codex/gpt-5.6-sol, thinking max",
          "Planning: openai-codex/gpt-5.6-sol, thinking max",
          "Review: openai-codex/gpt-5.6-sol, thinking max",
          "Triage: openai-codex/gpt-5.6-sol, thinking max",
          "Start Jidoka Code at login",
          "Finish Setup",
        ]
      )
    case "settings-accessibility-type.png":
      UIFixtureAccessibilityContract(
        identifiers: [
          JidokaAccessibilityID.settingsWindow,
          JidokaAccessibilityID.settingsRepositoryReference,
          JidokaAccessibilityID.settingsRepositoryAdd,
          JidokaAccessibilityID.settingsModelCatalogRefresh,
          "\(JidokaAccessibilityID.settingsModelSelector).review",
          "\(JidokaAccessibilityID.settingsCustomModel).review",
          JidokaAccessibilityID.credentialConnect,
          JidokaAccessibilityID.credentialReplacement,
          JidokaAccessibilityID.credentialDeletion,
        ],
        labels: [
          "Repositories",
          "GitHub repository URL or owner and repository",
          "Validate and Add",
          "Model Profiles",
          "Refresh Pi Models",
          "Maximum concurrent jobs",
          "Start Jidoka Code at login",
          "Validate and Replace",
          "Delete Credential",
          "Redacted diagnostics",
        ]
      )
    case "settings-catalog-unavailable.png":
      UIFixtureAccessibilityContract(
        identifiers: [
          JidokaAccessibilityID.settingsWindow,
          JidokaAccessibilityID.settingsModelCatalogRefresh,
          JidokaAccessibilityID.settingsModelCatalogNotice,
          "\(JidokaAccessibilityID.settingsCustomModel).review",
        ],
        labels: [
          "Model Profiles",
          "Refresh Pi Models",
          "Pi's offline model catalog",
        ]
      )
    case "menu-warning.png":
      UIFixtureAccessibilityContract(
        identifiers: [
          JidokaAccessibilityID.menuStatus,
          JidokaAccessibilityID.ambiguousRecheck,
          JidokaAccessibilityID.ambiguousAuthorize,
          JidokaAccessibilityID.pollNow,
          JidokaAccessibilityID.pauseResume,
          JidokaAccessibilityID.settings,
          JidokaAccessibilityID.openLogs,
          JidokaAccessibilityID.quit,
        ],
        labels: [
          "Jidoka Code status: Needs attention",
          "Recheck Visibility",
          "Authorize Retry",
          "Poll Now",
          "Pause",
          "Settings",
          "Open Logs",
          "Quit Jidoka Code",
        ]
      )
    default:
      UIFixtureAccessibilityContract(identifiers: [], labels: [])
    }
  }
}

private struct UIFixtureReport: Codable {
  let schemaVersion: Int
  let commandKinds: [String]
  let screenshots: [UIFixtureScreenshot]
  let invalidCredentialRejected: Bool
  let invalidRepositoryRejected: Bool
  let tokenFieldCleared: Bool
  let catalogFailureInline: Bool
  let catalogFailureModalSuppressed: Bool
  let catalogFailureRefreshCount: Int
  let pausePreservedInFlight: Bool
  let ambiguousLateRecheckCount: Int
  let ambiguousAuthorizationCount: Int
  let quitCheckpointed: Bool
  let keychainCalls: Int
  let networkCalls: Int
  let piProviderCalls: Int
  let serviceManagementCalls: Int
}

private actor UIFixtureEngine: EngineClient {
  private var lifecycle = EngineLifecycleState.onboarding
  private var paused = false
  private var passRunning = false
  private var externalAcknowledged = false
  private var providerAcknowledged = false
  private var pi = EnginePiStatus(
    state: .blocked,
    issueCode: .piRuntimeNotFound,
    summary: "Pi runtime was not found.",
    recovery: "Install an attested Pi and run preflight again."
  )
  private var credential = EngineCredentialStatus.missing
  private var herdr = EngineHerdrStatus.unchecked
  private var repositories: [RepositoryConfiguration] = []
  private var profiles = ModelProfileRole.allCases.map {
    ModelProfileConfiguration(
      role: $0,
      provider: "openai-codex",
      model: "gpt-5.6-sol",
      thinking: .max
    )
  }
  private var modelCatalog = PiModelCatalog.unavailable
  private let availableModelCatalog = PiModelCatalog(
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
  private var loginSelected = false
  private var loginStatus = LifecycleServiceStatus.notRegistered
  private var maxConcurrency = 2
  private var ambiguous: [EngineAmbiguousMutation] = []
  private var revision = 0
  private var rejectCredentialOnce = true
  private var rejectRepositoryOnce = true
  private var rejectModelCatalog = false

  private(set) var commandKinds: [EngineCommandKind] = []
  private(set) var lateRecheckCount = 0
  private(set) var authorizationCount = 0

  func send(_ command: EngineCommand) throws -> EngineCommandResponse {
    commandKinds.append(command.kind)
    var checkpoint: EngineCheckpointReceipt?
    switch command {
    case .snapshot:
      break
    case .refreshModelCatalog:
      guard !rejectModelCatalog else { throw EngineClientError(.piBlocked) }
      modelCatalog = availableModelCatalog
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
      herdr = EngineHerdrStatus(
        state: .ready,
        version: "0.8.2",
        protocolVersion: 20,
        executableSHA256: String(repeating: "e", count: 64),
        schemaSHA256: String(repeating: "d", count: 64),
        policySHA256: String(repeating: "c", count: 64)
      )
    case .focusInHerdr:
      guard herdr.state == .ready else { throw EngineClientError(.herdrBlocked) }
    case .replaceCredential(let token):
      guard !rejectCredentialOnce else {
        rejectCredentialOnce = false
        throw EngineClientError(.credentialRejected)
      }
      guard token.count >= 20 else { throw EngineClientError(.credentialRejected) }
      credential = EngineCredentialStatus(state: .valid, account: "fixture-user")
    case .deleteCredential:
      credential = .missing
    case .addRepository(let draft):
      guard !rejectRepositoryOnce else {
        rejectRepositoryOnce = false
        throw EngineClientError(.repositoryRejected)
      }
      repositories = [
        RepositoryConfiguration(
          id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          nodeID: "R_fixture",
          owner: draft.owner,
          name: draft.name,
          defaultBranch: "main",
          reviewEnabled: draft.reviewEnabled,
          triageEnabled: draft.triageEnabled,
          implementationEnabled: draft.implementationEnabled,
          enabled: true
        )
      ]
    case .updateRepository(let repository):
      repositories = repositories.map { $0.id == repository.id ? repository : $0 }
    case .removeRepository(let id):
      repositories.removeAll { $0.id == id }
    case .setProfile(let profile):
      profiles.removeAll { $0.role == profile.role }
      profiles.append(profile)
    case .setMaxConcurrency(let value):
      maxConcurrency = value
    case .setPaused(let value):
      paused = value
    case .pollNow:
      break
    case .recheckAmbiguousMutation:
      lateRecheckCount += 1
    case .authorizeRetry(let evidence):
      guard
        ambiguous.contains(where: {
          EngineAmbiguousMutationEvidence($0) == evidence
        })
      else {
        throw EngineClientError(.staleEvidence)
      }
      ambiguous.removeAll { $0.jobID == evidence.jobID }
      authorizationCount += 1
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
      checkpoint = checkpointReceipt()
    case .prepareForQuit:
      paused = true
      passRunning = false
      lifecycle = .quitting
      checkpoint = checkpointReceipt()
    }
    revision += 1
    return EngineCommandResponse(
      command: command.kind,
      state: state(),
      checkpoint: checkpoint
    )
  }

  func setPassRunning(_ value: Bool) {
    passRunning = value
  }

  func setModelCatalogUnavailable(_ value: Bool) {
    rejectModelCatalog = value
    if value { modelCatalog = .unavailable }
  }

  func injectAmbiguousMutation() {
    ambiguous = [
      EngineAmbiguousMutation(
        jobID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        repositoryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        repositoryOwner: "owner",
        repositoryName: "repo",
        kind: .prReview,
        objectNodeID: "PR_fixture",
        objectNumber: 42,
        revisionKey: String(repeating: "a", count: 40),
        evidenceDigest: String(repeating: "b", count: 64),
        mutationGeneration: 1,
        mutationID: "33333333-3333-3333-3333-333333333333"
      )
    ]
  }

  private func state() -> EngineUIState {
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
      complete: lifecycle != .onboarding
    )
    return EngineUIState(
      revision: revision,
      lifecycle: lifecycle,
      operationalStatus: !ambiguous.isEmpty
        ? .warning : passRunning ? .running : paused ? .paused : .active,
      paused: paused,
      passRunning: passRunning,
      activities: repositories.isEmpty
        ? []
        : [
          EngineActivity(
            id: "fixture-activity",
            summary: "owner/repo: pull request review #42, running.",
            occurredAt: Date(timeIntervalSince1970: 400_000)
          )
        ],
      ambiguousMutations: ambiguous,
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
        nonterminalJobCount: ambiguous.count,
        ambiguousMutationCount: ambiguous.count,
        coordinatorFailureCodes: [],
        piIssueCode: pi.issueCode,
        herdrIssueCode: herdr.issueCode
      )
    )
  }

  private func checkpointReceipt() -> EngineCheckpointReceipt {
    EngineCheckpointReceipt(
      checkpointID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
      completedAt: Date(timeIntervalSince1970: 400_001),
      nonterminalJobCount: ambiguous.count,
      ambiguousMutationCount: ambiguous.count,
      databaseCheckpointed: true
    )
  }
}

@MainActor
private enum UIFixtureRunner {
  static func run(outputDirectory: URL) async throws -> UIFixtureReport {
    try prepareOutputDirectory(outputDirectory)
    let engine = UIFixtureEngine()
    let app = AppViewModel(client: engine)
    let settings = SettingsViewModel(client: engine) { state in app.apply(state) }
    let onboardingSnapshot = OnboardingViewModel(client: engine) { state in app.apply(state) }
    await onboardingSnapshot.refresh()

    var screenshots: [UIFixtureScreenshot] = []
    screenshots.append(
      try render(
        AnyView(OnboardingView(model: onboardingSnapshot, completed: {})),
        size: NSSize(width: 720, height: 1_300),
        filename: "onboarding-first-run.png",
        outputDirectory: outputDirectory
      )
    )

    // Keep screenshot-hosted models immutable after their windows are hidden. A live
    // alert transition on a hidden NSHostingView can race AppKit sheet teardown.
    let onboarding = OnboardingViewModel(client: engine) { state in app.apply(state) }
    await onboarding.refresh()
    await onboarding.acknowledgeExternalAutomation(true)
    await onboarding.runPiPreflight()
    await onboarding.runHerdrPreflight()
    let sentinel = ["github", "pat", "ui", "fixture", "secret", UUID().uuidString]
      .joined(separator: "_")
    onboarding.token = sentinel
    await onboarding.validateAndImportCredential()
    let invalidCredentialRejected = onboarding.message?.title == "Credential not accepted"
    onboarding.token = sentinel
    await onboarding.validateAndImportCredential()
    await onboarding.acknowledgeProviderDisclosure(true)
    guard await onboarding.complete() else {
      throw EngineClientError(.onboardingIncomplete)
    }
    let tokenFieldCleared = onboarding.token.isEmpty

    await settings.refresh()
    settings.repositoryReference = "owner/repo"
    await settings.addRepository()
    let invalidRepositoryRejected = settings.message?.title == "Repository not accepted"
    settings.repositoryReference = "owner/repo"
    await settings.addRepository()
    settings.setProfileSource(.custom, role: .review)
    screenshots.append(
      try render(
        AnyView(
          SettingsView(model: settings)
            .environment(\.dynamicTypeSize, .accessibility2)
        ),
        size: NSSize(width: 900, height: 1_800),
        filename: "settings-accessibility-type.png",
        outputDirectory: outputDirectory
      )
    )

    let unavailableEngine = UIFixtureEngine()
    await unavailableEngine.setModelCatalogUnavailable(true)
    let unavailableSettings = SettingsViewModel(client: unavailableEngine)
    await unavailableSettings.refresh()
    let catalogFailureInline =
      unavailableSettings.modelCatalogNotice?.contains("offline model catalog") == true
    let catalogFailureModalSuppressed = unavailableSettings.message == nil
    let catalogFailureRefreshCount = await unavailableEngine.commandKinds.filter {
      $0 == .refreshModelCatalog
    }.count
    screenshots.append(
      try render(
        AnyView(SettingsView(model: unavailableSettings)),
        size: NSSize(width: 900, height: 1_800),
        filename: "settings-catalog-unavailable.png",
        outputDirectory: outputDirectory
      )
    )

    await app.refresh()
    await engine.setPassRunning(true)
    await app.refresh()
    await app.togglePaused()
    let pausePreservedInFlight = app.state?.paused == true && app.state?.passRunning == true
    await engine.setPassRunning(false)
    await app.togglePaused()
    await engine.injectAmbiguousMutation()
    await app.refresh()
    let menuSnapshot = AppViewModel(client: engine)
    await menuSnapshot.refresh()
    screenshots.append(
      try render(
        AnyView(
          ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 8) {
              MenuBarContentView(
                model: menuSnapshot,
                openOnboarding: {},
                openSettings: {},
                openLogs: {},
                quit: {}
              )
            }
            .padding(16)
            .buttonStyle(.borderless)
          }
          .environment(\.colorScheme, .light)
        ),
        size: NSSize(width: 520, height: 620),
        filename: "menu-warning.png",
        outputDirectory: outputDirectory
      )
    )
    guard let mutation = app.state?.ambiguousMutations.first else {
      throw EngineClientError(.internalFailure)
    }
    await app.recheck(mutation)
    app.requestRetryAuthorization(mutation)
    await app.authorizePendingRetry()
    let quitCheckpointed = await app.prepareForQuit()?.databaseCheckpointed == true

    let report = UIFixtureReport(
      schemaVersion: 1,
      commandKinds: await engine.commandKinds.map(\.rawValue),
      screenshots: screenshots,
      invalidCredentialRejected: invalidCredentialRejected,
      invalidRepositoryRejected: invalidRepositoryRejected,
      tokenFieldCleared: tokenFieldCleared,
      catalogFailureInline: catalogFailureInline,
      catalogFailureModalSuppressed: catalogFailureModalSuppressed,
      catalogFailureRefreshCount: catalogFailureRefreshCount,
      pausePreservedInFlight: pausePreservedInFlight,
      ambiguousLateRecheckCount: await engine.lateRecheckCount,
      ambiguousAuthorizationCount: await engine.authorizationCount,
      quitCheckpointed: quitCheckpointed,
      keychainCalls: 0,
      networkCalls: 0,
      piProviderCalls: 0,
      serviceManagementCalls: 0
    )
    let encodedState = try JSONEncoder().encode(app.state)
    guard !encodedState.contains(Data(sentinel.utf8)) else {
      throw EngineClientError(.internalFailure)
    }
    return report
  }

  private static func render(
    _ rootView: AnyView,
    size: NSSize,
    filename: String,
    outputDirectory: URL
  ) throws -> UIFixtureScreenshot {
    let hosting = NSHostingView(rootView: rootView)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Jidoka Code UI Fixture"
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    NSAccessibility.post(element: hosting, notification: .layoutChanged)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      throw EngineClientError(.internalFailure)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw EngineClientError(.internalFailure)
    }
    let destination = outputDirectory.appendingPathComponent(filename, isDirectory: false)
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    let accessibility = UIFixtureAccessibilityContract.value(for: filename)
    let observedAccessibility = accessibilitySnapshot(root: window)
    window.orderOut(nil)
    return UIFixtureScreenshot(
      filename: filename,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      width: representation.pixelsWide,
      height: representation.pixelsHigh,
      declaredAccessibilityIdentifiers: accessibility.identifiers,
      declaredAccessibilityLabels: accessibility.labels,
      observedAccessibilityIdentifiers: observedAccessibility.identifiers,
      observedAccessibilityLabels: observedAccessibility.labels
    )
  }

  private static func accessibilitySnapshot(
    root: AnyObject
  ) -> (identifiers: [String], labels: [String]) {
    var pending: [AnyObject] = [root]
    var visited: Set<ObjectIdentifier> = []
    var identifiers: Set<String> = []
    var labels: Set<String> = []
    while let object = pending.popLast(), visited.count < 2_000 {
      let identity = ObjectIdentifier(object)
      guard visited.insert(identity).inserted else { continue }
      let identifier: String?
      let label: String?
      let children: [Any]
      if let window = object as? NSWindow {
        identifier = window.accessibilityIdentifier()
        label = window.accessibilityLabel()
        children = window.accessibilityChildren() ?? []
      } else if let view = object as? NSView {
        identifier = view.accessibilityIdentifier()
        label = view.accessibilityLabel()
        children = view.accessibilityChildren() ?? []
      } else if let element = object as? NSAccessibilityElement {
        identifier = element.accessibilityIdentifier()
        label = element.accessibilityLabel()
        children = element.accessibilityChildren() ?? []
      } else {
        continue
      }
      if let identifier, !identifier.isEmpty { identifiers.insert(identifier) }
      if let label, !label.isEmpty { labels.insert(label) }
      pending.append(contentsOf: children.compactMap { $0 as AnyObject })
    }
    return (identifiers.sorted(), labels.sorted())
  }

  private static func prepareOutputDirectory(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw EngineClientError(.invalidCommand)
    }
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true,
        try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
      else {
        throw EngineClientError(.invalidCommand)
      }
    } else {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
}

private enum UIFixtureDemoScreen: String, CaseIterable, Identifiable {
  case onboarding = "Onboarding"
  case settings = "Settings"
  case menu = "Menu"

  var id: Self { self }
}

@MainActor
private struct UIFixtureInteractiveView: View {
  @State private var screen = UIFixtureDemoScreen.onboarding

  private let app: AppViewModel
  private let onboarding: OnboardingViewModel
  private let settings: SettingsViewModel

  init() {
    let engine = UIFixtureEngine()
    let app = AppViewModel(client: engine)
    self.app = app
    onboarding = OnboardingViewModel(client: engine) { state in app.apply(state) }
    settings = SettingsViewModel(client: engine) { state in app.apply(state) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Jidoka Code")
            .font(.headline)
          Text("Interactive UI fixture")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Picker("Screen", selection: $screen) {
          ForEach(UIFixtureDemoScreen.allCases) { screen in
            Text(screen.rawValue).tag(screen)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 360)

        Spacer()

        Label("Isolated demo", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)

      Divider()

      Group {
        switch screen {
        case .onboarding:
          OnboardingView(model: onboarding) { screen = .settings }
        case .settings:
          SettingsView(model: settings)
        case .menu:
          ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 8) {
              MenuBarContentView(
                model: app,
                openOnboarding: { screen = .onboarding },
                openSettings: { screen = .settings },
                openLogs: {},
                quit: { NSApplication.shared.terminate(nil) }
              )
            }
            .padding(24)
            .frame(width: 520, alignment: .leading)
          }
        }
      }
    }
    .frame(minWidth: 900, minHeight: 780)
    .task {
      NSApplication.shared.activate(ignoringOtherApps: true)
      await app.refresh()
    }
  }
}

@main
@MainActor
private struct JidokaCodeUIFixtureApp: App {
  private let arguments: [String]

  init() {
    arguments = Array(CommandLine.arguments.dropFirst())
  }

  var body: some Scene {
    Window("Jidoka Code UI Fixture", id: "fixture-runner") {
      if arguments == ["--interactive"] {
        UIFixtureInteractiveView()
      } else {
        Color.clear
          .frame(width: 1, height: 1)
          .task { await runFixture() }
      }
    }
    .windowResizability(.contentSize)
  }

  private func runFixture() async {
    do {
      guard arguments.count == 2, arguments[0] == "--output" else {
        throw EngineClientError(.invalidCommand)
      }
      let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
      let report = try await UIFixtureRunner.run(outputDirectory: output)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let destination = output.appendingPathComponent("ui-flow-report.json", isDirectory: false)
      try encoder.encode(report).write(to: destination, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
      exit(EXIT_SUCCESS)
    } catch {
      FileHandle.standardError.write(Data("UI fixture failed: FIXTURE_ERROR\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
