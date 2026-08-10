import JidokaCodeCore
import SwiftUI

public struct MenuBarContentView: View {
  @Bindable private var model: AppViewModel
  private let openOnboarding: @MainActor () -> Void
  private let openSettings: @MainActor () -> Void
  private let openLogs: @MainActor () -> Void
  private let quit: @MainActor () -> Void

  public init(
    model: AppViewModel,
    openOnboarding: @escaping @MainActor () -> Void,
    openSettings: @escaping @MainActor () -> Void,
    openLogs: @escaping @MainActor () -> Void,
    quit: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.openOnboarding = openOnboarding
    self.openSettings = openSettings
    self.openLogs = openLogs
    self.quit = quit
  }

  public var body: some View {
    Group {
      Label(model.statusTitle, systemImage: model.statusSystemImage)
        .accessibilityIdentifier(JidokaAccessibilityID.menuStatus)
        .accessibilityLabel("Jidoka Code status: \(model.statusTitle)")

      if model.state?.lifecycle == .onboarding {
        Button("Complete Setup", systemImage: "checklist", action: openOnboarding)
      }

      if let activities = model.state?.activities, !activities.isEmpty {
        Divider()
        Text("Recent activity")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(activities) { activity in
          Text(activity.summary)
            .lineLimit(2)
            .accessibilityLabel(activity.summary)
        }
      }

      if let mutations = model.state?.ambiguousMutations, !mutations.isEmpty {
        Divider()
        Text("Mutation needs exact resolution")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(mutations) { mutation in
          Text(ambiguousSummary(mutation))
            .lineLimit(2)
          Button("Recheck Visibility") {
            Task { await model.recheck(mutation) }
          }
          .accessibilityIdentifier(
            "\(JidokaAccessibilityID.ambiguousRecheck).\(mutation.jobID.uuidString.lowercased())"
          )
          Button("Authorize Retry…") {
            model.requestRetryAuthorization(mutation)
          }
          .accessibilityIdentifier(
            "\(JidokaAccessibilityID.ambiguousAuthorize).\(mutation.jobID.uuidString.lowercased())"
          )
        }
      }

      Divider()
      Button("Poll Now", systemImage: "arrow.clockwise") {
        Task { await model.pollNow() }
      }
      .disabled(!model.canPoll)
      .keyboardShortcut("p", modifiers: [.command])
      .accessibilityIdentifier(JidokaAccessibilityID.pollNow)

      Button(
        model.state?.paused == true ? "Resume" : "Pause",
        systemImage: model.state?.paused == true ? "play.fill" : "pause.fill"
      ) {
        Task { await model.togglePaused() }
      }
      .disabled(!model.canPauseOrResume)
      .accessibilityIdentifier(JidokaAccessibilityID.pauseResume)

      Button("Open in Herdr", systemImage: "rectangle.inset.focused") {
        Task { await model.focusInHerdr() }
      }
      .disabled(!model.canFocusInHerdr)
      .accessibilityIdentifier(JidokaAccessibilityID.focusInHerdr)

      Divider()
      Button("Settings…", systemImage: "gearshape", action: openSettings)
        .keyboardShortcut(",", modifiers: [.command])
        .accessibilityIdentifier(JidokaAccessibilityID.settings)
      Button("Open Logs", systemImage: "doc.text.magnifyingglass", action: openLogs)
        .accessibilityIdentifier(JidokaAccessibilityID.openLogs)
      Button("Quit Jidoka Code", systemImage: "power", action: quit)
        .keyboardShortcut("q", modifiers: [.command])
        .accessibilityIdentifier(JidokaAccessibilityID.quit)
    }
    .task {
      if model.state == nil {
        await model.refresh()
      }
    }
    .alert(item: $model.message) { message in
      Alert(
        title: Text(message.title),
        message: Text(message.detail),
        dismissButton: .default(Text("OK"))
      )
    }
    .confirmationDialog(
      "Authorize one exact retry?",
      isPresented: Binding(
        get: { model.pendingRetryAuthorization != nil },
        set: { if !$0 { model.cancelRetryAuthorization() } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingRetryAuthorization
    ) { _ in
      Button("Authorize Retry", role: .destructive) {
        Task { await model.authorizePendingRetry() }
      }
      Button("Cancel", role: .cancel) {
        model.cancelRetryAuthorization()
      }
    } message: { mutation in
      Text(
        "Repository: \(mutation.repositoryOwner)/\(mutation.repositoryName)\n"
          + "Object: \(mutation.kind.displayName) \(objectLabel(mutation))\n"
          + "Revision: \(mutation.revisionKey)\n"
          + "Evidence: \(mutation.evidenceDigest)\n"
          + "Generation: \(mutation.mutationGeneration)"
      )
    }
  }

  private func ambiguousSummary(_ mutation: EngineAmbiguousMutation) -> String {
    "\(mutation.repositoryOwner)/\(mutation.repositoryName): "
      + "\(mutation.kind.displayName) \(objectLabel(mutation))"
  }

  private func objectLabel(_ mutation: EngineAmbiguousMutation) -> String {
    mutation.objectNumber.map { "#\($0)" } ?? mutation.objectNodeID
  }
}

public struct OnboardingView: View {
  @Bindable private var model: OnboardingViewModel
  private let completed: @MainActor () -> Void

  public init(
    model: OnboardingViewModel,
    completed: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.completed = completed
  }

  public var body: some View {
    Form {
      Section("Automation coexistence") {
        Label(
          model.state?.onboarding.duplicateInstanceCheckPassed == true
            ? "This is the only Jidoka Code UI instance."
            : "Another Jidoka Code instance is active.",
          systemImage: model.state?.onboarding.duplicateInstanceCheckPassed == true
            ? "checkmark.circle" : "xmark.octagon"
        )
        Toggle(
          "I understand that external GitHub automations may conflict with Jidoka Code.",
          isOn: Binding(
            get: { model.state?.onboarding.externalAutomationAcknowledged ?? false },
            set: { value in
              Task { await model.acknowledgeExternalAutomation(value) }
            }
          )
        )
        .accessibilityIdentifier(JidokaAccessibilityID.externalAutomationDisclosure)
      }

      Section("Pi runtime") {
        piStatus
        Button("Run Pi Preflight", systemImage: "checkmark.shield") {
          Task { await model.runPiPreflight() }
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier(JidokaAccessibilityID.piPreflight)
      }

      Section("Herdr runtime") {
        Text(
          "Jidoka Code uses your existing global Herdr session. Agent terminals and "
            + "transcripts are observable there. Jidoka Code never installs, updates, "
            + "reconfigures, or stops Herdr."
        )
        .foregroundStyle(.secondary)
        herdrStatus
        Button("Run Herdr Preflight", systemImage: "rectangle.connected.to.line.below") {
          Task { await model.runHerdrPreflight() }
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier(JidokaAccessibilityID.herdrPreflight)
      }

      Section("GitHub credential") {
        Text("The token is validated, then stored only in Keychain. It is never sent to Pi.")
          .foregroundStyle(.secondary)
        SecureField("GitHub token", text: $model.token)
          .textContentType(.password)
          .accessibilityIdentifier(JidokaAccessibilityID.tokenField)
        Button("Validate and Import", systemImage: "key.fill") {
          Task { await model.validateAndImportCredential() }
        }
        .disabled(!model.canImportCredential)
        .accessibilityIdentifier(JidokaAccessibilityID.tokenImport)
        credentialStatus
      }

      Section("Provider and source disclosure") {
        Text(
          "Configured workflow profiles: \(profileDisclosure). "
            + "Repository content, issues, pull requests, diffs, plans, and verification evidence "
            + "may be sent only when a workflow is enabled."
        )
        Toggle(
          "I understand the provider, model, and source categories.",
          isOn: Binding(
            get: { model.state?.onboarding.providerDisclosureAcknowledged ?? false },
            set: { value in
              Task { await model.acknowledgeProviderDisclosure(value) }
            }
          )
        )
        .accessibilityIdentifier(JidokaAccessibilityID.providerDisclosure)
      }

      Section("Repository") {
        TextField("Owner", text: $model.repositoryOwner)
          .accessibilityIdentifier(JidokaAccessibilityID.repositoryOwner)
        TextField("Repository", text: $model.repositoryName)
          .accessibilityIdentifier(JidokaAccessibilityID.repositoryName)
        Toggle("Pull request reviews", isOn: $model.reviewEnabled)
        Toggle("Issue triage", isOn: $model.triageEnabled)
        Toggle("Issue implementation", isOn: $model.implementationEnabled)
        Button("Validate and Add Repository", systemImage: "plus") {
          Task { await model.validateAndAddRepository() }
        }
        .disabled(!model.canAddRepository)
        .accessibilityIdentifier(JidokaAccessibilityID.repositoryAdd)
        Text("Configured repositories: \(model.state?.onboarding.repositoryCount ?? 0)")
          .foregroundStyle(.secondary)
      }

      Section("Login item") {
        Toggle("Start Jidoka Code at login", isOn: $model.loginItemSelected)
          .accessibilityIdentifier(JidokaAccessibilityID.loginItem)
        Text("Enabled by default. macOS may require approval in Login Items.")
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Finish Setup") {
          Task {
            if await model.complete() {
              completed()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canComplete)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(JidokaAccessibilityID.onboardingComplete)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 620, minHeight: 760)
    .accessibilityIdentifier(JidokaAccessibilityID.onboardingWindow)
    .task {
      if model.state == nil {
        await model.refresh()
      }
    }
    .alert(item: $model.message) { message in
      Alert(
        title: Text(message.title),
        message: Text(message.detail),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  private var profileDisclosure: String {
    let profiles = model.state?.settings.profiles ?? []
    return profiles.sorted { $0.role.rawValue < $1.role.rawValue }.map {
      "\($0.role.rawValue)=\($0.provider)/\($0.model):\($0.thinking.rawValue)"
    }.joined(separator: ", ")
  }

  @ViewBuilder
  private var piStatus: some View {
    switch model.state?.onboarding.pi.state ?? .unchecked {
    case .unchecked:
      Label("Preflight has not run.", systemImage: "questionmark.circle")
    case .ready:
      Label(
        "Pi \(model.state?.onboarding.pi.version ?? "validated") passed attestation.",
        systemImage: "checkmark.circle"
      )
    case .blocked:
      Label(
        model.state?.onboarding.pi.summary ?? "Pi preflight is blocked.",
        systemImage: "xmark.octagon"
      )
      Text(model.state?.onboarding.pi.recovery ?? "Run preflight again after recovery.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var herdrStatus: some View {
    switch model.state?.onboarding.herdr.state ?? .unchecked {
    case .unchecked:
      Label("Herdr preflight has not run.", systemImage: "questionmark.circle")
    case .ready:
      Label(
        "Herdr \(model.state?.onboarding.herdr.version ?? "validated") protocol "
          + "\(model.state?.onboarding.herdr.protocolVersion ?? 0) passed attestation.",
        systemImage: "checkmark.circle"
      )
    case .blocked:
      Label(
        model.state?.onboarding.herdr.summary ?? "Herdr readiness is blocked.",
        systemImage: "xmark.octagon"
      )
      Text(model.state?.onboarding.herdr.recovery ?? "Run preflight again after recovery.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var credentialStatus: some View {
    switch model.state?.onboarding.credential.state ?? .missing {
    case .missing:
      Label("No validated GitHub credential.", systemImage: "key.slash")
    case .valid:
      Label(
        "Validated for \(model.state?.onboarding.credential.account ?? "GitHub account").",
        systemImage: "checkmark.circle"
      )
    case .unavailable:
      Label("Keychain status is unavailable.", systemImage: "exclamationmark.triangle")
    }
  }
}

public struct SettingsView: View {
  @Bindable private var model: SettingsViewModel
  @State private var repositoryPendingRemoval: RepositoryConfiguration?
  @State private var confirmCredentialDeletion = false

  public init(model: SettingsViewModel) {
    self.model = model
  }

  public var body: some View {
    Form {
      Section("Repositories") {
        GroupBox("Add repository") {
          TextField("Owner", text: $model.repositoryOwner)
          TextField("Repository", text: $model.repositoryName)
          Toggle("Pull request reviews", isOn: $model.newRepositoryReviewEnabled)
          Toggle("Issue triage", isOn: $model.newRepositoryTriageEnabled)
          Toggle("Issue implementation", isOn: $model.newRepositoryImplementationEnabled)
          Button("Validate and Add Repository", systemImage: "plus") {
            Task { await model.addRepository() }
          }
          .disabled(model.repositoryOwner.isEmpty || model.repositoryName.isEmpty)
        }
        if model.repositories.isEmpty {
          Text("No repositories configured.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.repositories) { repository in
          GroupBox("\(repository.owner)/\(repository.name)") {
            Toggle(
              "Repository enabled",
              isOn: repositoryBinding(repository, keyPath: \.enabled)
            )
            Toggle(
              "Pull request reviews",
              isOn: repositoryBinding(repository, keyPath: \.reviewEnabled)
            )
            Toggle(
              "Issue triage",
              isOn: repositoryBinding(repository, keyPath: \.triageEnabled)
            )
            Toggle(
              "Issue implementation",
              isOn: repositoryBinding(repository, keyPath: \.implementationEnabled)
            )
            Button("Remove Repository", role: .destructive) {
              repositoryPendingRemoval = repository
            }
          }
        }
      }

      Section("Model profiles") {
        ForEach(ModelProfileRole.allCases, id: \.self) { role in
          GroupBox(role.rawValue.capitalized) {
            TextField("Provider", text: providerBinding(role))
            TextField("Model", text: modelBinding(role))
            Picker("Thinking", selection: thinkingBinding(role)) {
              ForEach(ModelThinkingLevel.allCases, id: \.self) { level in
                Text(level.rawValue).tag(level)
              }
            }
            Button("Save \(role.rawValue.capitalized) Profile") {
              Task { await model.saveProfile(role: role) }
            }
          }
        }
      }

      Section("Concurrency") {
        Stepper(value: $model.maxConcurrency, in: 1...8) {
          Text("Maximum concurrent jobs: \(model.maxConcurrency)")
        }
        Button("Save Concurrency") {
          Task { await model.saveMaxConcurrency() }
        }
      }

      Section("Login item") {
        Toggle(
          "Start at login",
          isOn: Binding(
            get: { model.loginItemSelected },
            set: { value in Task { await model.setLoginItemEnabled(value) } }
          )
        )
        Text("Status: \(model.state?.settings.loginItemStatus.rawValue ?? "unknown")")
          .foregroundStyle(.secondary)
      }

      Section("Herdr runtime") {
        Text(
          "Herdr is an external shared-session prerequisite. Its visible panes may include "
            + "Jidoka Code transcripts and user-owned terminals."
        )
        .foregroundStyle(.secondary)
        settingsHerdrStatus
        Button("Run Herdr Preflight") {
          Task { await model.runHerdrPreflight() }
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier(JidokaAccessibilityID.settingsHerdrPreflight)
        Button("Open Most Recent Jidoka Pane in Herdr") {
          Task { await model.focusInHerdr() }
        }
        .disabled(model.isWorking || model.herdrStatus.state != .ready)
        .accessibilityIdentifier(JidokaAccessibilityID.settingsFocusInHerdr)
      }

      Section("GitHub credential") {
        Text("Status: \(model.credentialStatus.state.rawValue)")
        SecureField("Replacement token", text: $model.replacementToken)
          .textContentType(.password)
          .accessibilityIdentifier(JidokaAccessibilityID.credentialReplacement)
        Button("Validate and Replace") {
          Task { await model.replaceCredential() }
        }
        .disabled(!(20...2_048).contains(model.replacementToken.utf8.count))
        Button("Delete Credential…", role: .destructive) {
          confirmCredentialDeletion = true
        }
        .accessibilityIdentifier(JidokaAccessibilityID.credentialDeletion)
      }

      if let mutations = model.state?.ambiguousMutations, !mutations.isEmpty {
        Section("Ambiguous mutations") {
          ForEach(mutations) { mutation in
            Text(
              "\(mutation.repositoryOwner)/\(mutation.repositoryName), "
                + "\(mutation.kind.displayName), revision \(mutation.revisionKey), "
                + "evidence \(mutation.evidenceDigest)"
            )
            .textSelection(.enabled)
          }
        }
      }

      Section("Redacted diagnostics") {
        ForEach(model.diagnostics, id: \.self) { diagnostic in
          Text(diagnostic)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 680, minHeight: 820)
    .accessibilityIdentifier(JidokaAccessibilityID.settingsWindow)
    .task { await model.refresh() }
    .alert(item: $model.message) { message in
      Alert(
        title: Text(message.title),
        message: Text(message.detail),
        dismissButton: .default(Text("OK"))
      )
    }
    .confirmationDialog(
      "Remove this repository?",
      isPresented: Binding(
        get: { repositoryPendingRemoval != nil },
        set: { if !$0 { repositoryPendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: repositoryPendingRemoval
    ) { repository in
      Button("Remove \(repository.owner)/\(repository.name)", role: .destructive) {
        repositoryPendingRemoval = nil
        Task { await model.removeRepository(repository) }
      }
      Button("Cancel", role: .cancel) { repositoryPendingRemoval = nil }
    } message: { repository in
      Text("Active or ambiguous jobs prevent removal. No local mirror is deleted here.")
    }
    .confirmationDialog(
      "Delete the GitHub credential?",
      isPresented: $confirmCredentialDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete Credential", role: .destructive) {
        Task { await model.deleteCredential() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Deletion is blocked while active or ambiguous jobs still require reconciliation.")
    }
  }

  @ViewBuilder
  private var settingsHerdrStatus: some View {
    switch model.herdrStatus.state {
    case .unchecked:
      Label("Preflight has not run.", systemImage: "questionmark.circle")
    case .ready:
      Label(
        "Herdr \(model.herdrStatus.version ?? "validated") protocol "
          + "\(model.herdrStatus.protocolVersion ?? 0) is ready.",
        systemImage: "checkmark.circle"
      )
    case .blocked:
      Label(
        model.herdrStatus.summary ?? "Herdr readiness is blocked.",
        systemImage: "xmark.octagon"
      )
      Text(model.herdrStatus.recovery ?? "Run preflight again after recovery.")
        .foregroundStyle(.secondary)
    }
  }

  private func repositoryBinding(
    _ repository: RepositoryConfiguration,
    keyPath: KeyPath<RepositoryConfiguration, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: {
        model.repositories.first(where: { $0.id == repository.id })?[keyPath: keyPath]
          ?? repository[keyPath: keyPath]
      },
      set: { value in
        Task {
          switch keyPath {
          case \.enabled:
            await model.setRepositoryEnabled(repository, value: value)
          case \.reviewEnabled:
            await model.setReviewEnabled(repository, value: value)
          case \.triageEnabled:
            await model.setTriageEnabled(repository, value: value)
          case \.implementationEnabled:
            await model.setImplementationEnabled(repository, value: value)
          default:
            break
          }
        }
      }
    )
  }

  private func providerBinding(_ role: ModelProfileRole) -> Binding<String> {
    Binding(
      get: { model.profileDrafts[role]?.provider ?? "" },
      set: { model.setProfileProvider($0, role: role) }
    )
  }

  private func modelBinding(_ role: ModelProfileRole) -> Binding<String> {
    Binding(
      get: { model.profileDrafts[role]?.model ?? "" },
      set: { model.setProfileModel($0, role: role) }
    )
  }

  private func thinkingBinding(_ role: ModelProfileRole) -> Binding<ModelThinkingLevel> {
    Binding(
      get: { model.profileDrafts[role]?.thinking ?? .max },
      set: { model.setProfileThinking($0, role: role) }
    )
  }
}
