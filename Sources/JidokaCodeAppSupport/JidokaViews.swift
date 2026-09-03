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

      if let reason = model.pollingUnavailableReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Polling unavailable: \(reason)")
      }

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
          "When a workflow is enabled, Jidoka Code may send repository content, issues, "
            + "pull requests, diffs, plans, and verification evidence to its configured model."
        )
        .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 12) {
          ForEach(disclosureProfiles, id: \.role) { profile in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
              Text(onboardingRoleName(profile.role))
                .font(.subheadline.weight(.semibold))
                .frame(width: 110, alignment: .leading)
              Text("\(profile.provider)/\(profile.model)")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 8)
              Text("Thinking: \(profile.thinking.rawValue.capitalized)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
              "\(onboardingRoleName(profile.role)): \(profile.provider)/\(profile.model), "
                + "thinking \(profile.thinking.rawValue)"
            )
            .accessibilityIdentifier(
              "\(JidokaAccessibilityID.providerDisclosureProfile).\(profile.role.rawValue)"
            )
          }
        }
        .padding(12)
        .background(
          Color.secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
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
    .frame(minWidth: 620, minHeight: 680)
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

  private var disclosureProfiles: [ModelProfileConfiguration] {
    (model.state?.settings.profiles ?? []).sorted { $0.role.rawValue < $1.role.rawValue }
  }

  private func onboardingRoleName(_ role: ModelProfileRole) -> String {
    switch role {
    case .review: "Review"
    case .triage: "Triage"
    case .planning: "Planning"
    case .orchestration: "Orchestration"
    }
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
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        settingsHeader
        repositoriesSection
        modelsSection
        credentialSection
        automationSection
        runtimeSection
        diagnosticsSection
      }
      .padding(28)
      .frame(maxWidth: 860, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 760, minHeight: 720)
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
    } message: { _ in
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

  private var settingsHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Settings")
        .font(.largeTitle.bold())
      Text("Connect GitHub, choose Pi models, and control Jidoka Code automation.")
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }

  private var repositoriesSection: some View {
    settingsCard(title: "Repositories", systemImage: "shippingbox") {
      VStack(alignment: .leading, spacing: 14) {
        Text("Paste a GitHub URL or enter owner/repository.")
          .foregroundStyle(.secondary)

        HStack(alignment: .firstTextBaseline, spacing: 10) {
          TextField(
            "https://github.com/owner/repository or owner/repository",
            text: $model.repositoryReference
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("GitHub repository URL or owner and repository")
          .accessibilityIdentifier(JidokaAccessibilityID.settingsRepositoryReference)

          Button("Validate and Add", systemImage: "plus") {
            Task { await model.addRepository() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canAddRepository || model.isWorking)
          .accessibilityIdentifier(JidokaAccessibilityID.settingsRepositoryAdd)
        }

        if model.credentialStatus.state != .valid {
          Label(
            "Connect GitHub before adding a repository.",
            systemImage: "info.circle"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }

        HStack(spacing: 18) {
          Toggle("Pull request reviews", isOn: $model.newRepositoryReviewEnabled)
          Toggle("Issue triage", isOn: $model.newRepositoryTriageEnabled)
          Toggle("Issue implementation", isOn: $model.newRepositoryImplementationEnabled)
        }
        .toggleStyle(.checkbox)

        Divider()

        if model.repositories.isEmpty {
          ContentUnavailableView(
            "No Repositories",
            systemImage: "shippingbox",
            description: Text("Add a repository to enable workflow automation.")
          )
          .frame(maxWidth: .infinity, minHeight: 100)
        } else {
          ForEach(model.repositories) { repository in
            repositoryRow(repository)
            if repository.id != model.repositories.last?.id { Divider() }
          }
        }
      }
    }
  }

  private func repositoryRow(_ repository: RepositoryConfiguration) -> some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("\(repository.owner)/\(repository.name)")
          .font(.headline)
        Text("Default branch: \(repository.defaultBranch)")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 14) {
          Toggle("Reviews", isOn: repositoryBinding(repository, keyPath: \.reviewEnabled))
          Toggle("Triage", isOn: repositoryBinding(repository, keyPath: \.triageEnabled))
          Toggle(
            "Implementation",
            isOn: repositoryBinding(repository, keyPath: \.implementationEnabled)
          )
        }
        .toggleStyle(.checkbox)
      }
      Spacer(minLength: 20)
      Toggle(
        "Enabled",
        isOn: repositoryBinding(repository, keyPath: \.enabled)
      )
      .labelsHidden()
      Button(role: .destructive) {
        repositoryPendingRemoval = repository
      } label: {
        Label("Remove repository", systemImage: "trash")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }

  private var modelsSection: some View {
    settingsCard(title: "Model Profiles", systemImage: "brain.head.profile") {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center) {
          if let notice = model.modelCatalogNotice {
            Text(notice)
              .foregroundStyle(Color.orange)
              .accessibilityIdentifier(JidokaAccessibilityID.settingsModelCatalogNotice)
          } else {
            Text(
              model.modelCatalog.isEmpty
                ? "No authenticated Pi models are available. Existing profiles remain editable as Custom."
                : "Choose among the models currently available to Pi, or use Custom for an advanced identifier."
            )
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Button("Refresh Pi Models", systemImage: "arrow.clockwise") {
            Task { await model.refreshModelCatalog() }
          }
          .disabled(model.isWorking)
          .accessibilityIdentifier(JidokaAccessibilityID.settingsModelCatalogRefresh)
        }

        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
          GridRow {
            Text("Workflow").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Model").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Thinking").font(.caption.bold()).foregroundStyle(.secondary)
            Text("")
          }
          Divider().gridCellColumns(4)
          ForEach(ModelProfileRole.allCases, id: \.self) { role in
            profileRow(role)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func profileRow(_ role: ModelProfileRole) -> some View {
    let source = model.profileDrafts[role]?.source ?? .custom
    GridRow(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(roleDisplayName(role)).fontWeight(.medium)
        Text(roleHelp(role)).font(.caption).foregroundStyle(.secondary)
      }
      .frame(minWidth: 140, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        Picker("Model for \(roleDisplayName(role))", selection: profileSelectionBinding(role)) {
          if !model.modelCatalog.isEmpty {
            ForEach(groupedProviders, id: \.provider) { group in
              Section(group.provider) {
                ForEach(group.models) { entry in
                  Text("\(entry.name) · \(entry.id)")
                    .tag(entry.selectionID)
                }
              }
            }
          }
          Divider()
          Text("Custom…").tag(customSelectionID)
        }
        .labelsHidden()
        .frame(minWidth: 300)
        .accessibilityIdentifier("\(JidokaAccessibilityID.settingsModelSelector).\(role.rawValue)")

        if source == .custom {
          HStack(spacing: 8) {
            TextField("Provider", text: providerBinding(role))
              .textFieldStyle(.roundedBorder)
            TextField("Model ID", text: modelBinding(role))
              .textFieldStyle(.roundedBorder)
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Custom provider and model for \(roleDisplayName(role))")
          .accessibilityIdentifier("\(JidokaAccessibilityID.settingsCustomModel).\(role.rawValue)")
        } else if let entry = model.catalogEntry(role: role) {
          Text(modelMetadata(entry))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Picker("Thinking for \(roleDisplayName(role))", selection: thinkingBinding(role)) {
        ForEach(model.availableThinkingLevels(role: role), id: \.self) { level in
          Text(level.rawValue.capitalized).tag(level)
        }
      }
      .labelsHidden()
      .frame(minWidth: 110)

      Button("Save") {
        Task { await model.saveProfile(role: role) }
      }
      .disabled(!model.profileIsDirty(role) || model.isWorking)
    }
  }

  private var credentialSection: some View {
    settingsCard(title: "GitHub Connection", systemImage: "key") {
      VStack(alignment: .leading, spacing: 14) {
        credentialStatus
        Text(
          "Jidoka Code validates the token against GitHub, stores it only in Keychain, "
            + "and never sends it to Pi. Use a fine-grained personal access token with "
            + "access to the repositories you automate."
        )
        .foregroundStyle(.secondary)

        Link(
          "Create a fine-grained token on GitHub",
          destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!
        )

        Text("Required repository permissions")
          .font(.subheadline.bold())
        Text(
          "Metadata: read; Issues: read and write; Pull requests: read and write; Contents: read and write."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        SecureField(
          model.credentialStatus.state == .valid ? "New token" : "GitHub token",
          text: $model.replacementToken
        )
        .textFieldStyle(.roundedBorder)
        .textContentType(.password)
        .accessibilityIdentifier(JidokaAccessibilityID.credentialReplacement)

        HStack {
          Button(
            model.credentialStatus.state == .valid
              ? "Validate and Replace" : "Connect GitHub",
            systemImage: "checkmark.shield"
          ) {
            Task { await model.replaceCredential() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSubmitCredential || model.isWorking)
          .accessibilityIdentifier(JidokaAccessibilityID.credentialConnect)

          if model.credentialStatus.state == .valid {
            Button("Delete Credential…", role: .destructive) {
              confirmCredentialDeletion = true
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier(JidokaAccessibilityID.credentialDeletion)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var credentialStatus: some View {
    switch model.credentialStatus.state {
    case .missing:
      Label("GitHub is not connected.", systemImage: "key.slash")
    case .valid:
      Label(
        "Connected as \(model.credentialStatus.account ?? "GitHub account").",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .unavailable:
      Label("Keychain status is unavailable.", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var automationSection: some View {
    settingsCard(title: "Automation", systemImage: "gearshape.2") {
      VStack(alignment: .leading, spacing: 14) {
        Stepper(value: $model.maxConcurrency, in: 1...8) {
          Text("Maximum concurrent jobs: \(model.maxConcurrency)")
        }
        Button("Save Concurrency") {
          Task { await model.saveMaxConcurrency() }
        }
        .disabled(model.isWorking)

        Divider()

        Toggle(
          "Start Jidoka Code at login",
          isOn: Binding(
            get: { model.loginItemSelected },
            set: { value in Task { await model.setLoginItemEnabled(value) } }
          )
        )
        Text("Login item status: \(model.state?.settings.loginItemStatus.rawValue ?? "unknown")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var runtimeSection: some View {
    settingsCard(title: "Herdr Runtime", systemImage: "rectangle.connected.to.line.below") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "Herdr is an external shared-session prerequisite. Visible panes may include "
            + "Jidoka Code transcripts and user-owned terminals."
        )
        .foregroundStyle(.secondary)
        settingsHerdrStatus
        HStack {
          Button("Run Herdr Preflight") {
            Task { await model.runHerdrPreflight() }
          }
          .disabled(model.isWorking)
          .accessibilityIdentifier(JidokaAccessibilityID.settingsHerdrPreflight)
          Button("Open Most Recent Jidoka Pane") {
            Task { await model.focusInHerdr() }
          }
          .disabled(model.isWorking || model.herdrStatus.state != .ready)
          .accessibilityIdentifier(JidokaAccessibilityID.settingsFocusInHerdr)
        }
      }
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

  @ViewBuilder
  private var diagnosticsSection: some View {
    if let mutations = model.state?.ambiguousMutations, !mutations.isEmpty {
      settingsCard(title: "Ambiguous Mutations", systemImage: "exclamationmark.triangle") {
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

    DisclosureGroup("Redacted diagnostics") {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(model.diagnostics, id: \.self) { diagnostic in
          Text(diagnostic)
            .textSelection(.enabled)
        }
      }
      .padding(.top, 8)
    }
    .foregroundStyle(.secondary)
  }

  private func settingsCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GroupBox {
      content()
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label(title, systemImage: systemImage)
        .font(.title3.bold())
    }
  }

  private var groupedProviders: [(provider: String, models: [PiModelCatalogEntry])] {
    Dictionary(grouping: model.modelCatalog, by: \.provider).keys.sorted().map { provider in
      (provider, model.modelCatalog.filter { $0.provider == provider })
    }
  }

  private var customSelectionID: String { "__jidoka_custom__" }

  private func profileSelectionBinding(_ role: ModelProfileRole) -> Binding<String> {
    Binding(
      get: {
        guard let draft = model.profileDrafts[role] else { return customSelectionID }
        return draft.source == .catalog ? draft.selectionID : customSelectionID
      },
      set: { value in
        if value == customSelectionID {
          model.setProfileSource(.custom, role: role)
        } else {
          model.selectCatalogModel(value, role: role)
        }
      }
    )
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
      get: { model.profileDrafts[role]?.thinking ?? .off },
      set: { model.setProfileThinking($0, role: role) }
    )
  }

  private func roleDisplayName(_ role: ModelProfileRole) -> String {
    switch role {
    case .review: "Review"
    case .triage: "Triage"
    case .planning: "Planning"
    case .orchestration: "Orchestration"
    }
  }

  private func roleHelp(_ role: ModelProfileRole) -> String {
    switch role {
    case .review: "Pull request analysis"
    case .triage: "Issue classification"
    case .planning: "Implementation plans"
    case .orchestration: "Code changes"
    }
  }

  private func modelMetadata(_ entry: PiModelCatalogEntry) -> String {
    let context = entry.contextWindow.formatted(.number.notation(.compactName))
    let modalities = entry.input.map(\.rawValue).joined(separator: ", ")
    return "\(entry.provider) · \(context) context · \(modalities)"
  }
}
