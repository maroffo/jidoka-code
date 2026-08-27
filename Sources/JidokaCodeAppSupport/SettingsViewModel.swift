import Foundation
import JidokaCodeCore
import Observation

public enum ModelProfileSource: String, Equatable, Sendable {
  case catalog
  case custom
}

public struct ModelProfileDraft: Equatable, Sendable {
  public var source: ModelProfileSource
  public var provider: String
  public var model: String
  public var thinking: ModelThinkingLevel

  public var selectionID: String { "\(provider)/\(model)" }

  public init(
    source: ModelProfileSource,
    provider: String,
    model: String,
    thinking: ModelThinkingLevel
  ) {
    self.source = source
    self.provider = provider
    self.model = model
    self.thinking = thinking
  }
}

public struct RepositoryCoordinates: Equatable, Sendable {
  public let owner: String
  public let name: String

  public init(owner: String, name: String) {
    self.owner = owner
    self.name = name
  }
}

public enum RepositoryReferenceParser {
  public static func parse(_ input: String) -> RepositoryCoordinates? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("\u{0}") else { return nil }
    let path: String
    if value.contains("://") {
      guard let components = URLComponents(string: value),
        components.scheme?.lowercased() == "https",
        components.host?.lowercased() == "github.com",
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.query == nil,
        components.fragment == nil
      else {
        return nil
      }
      guard let decodedPath = components.percentEncodedPath.removingPercentEncoding else {
        return nil
      }
      path = decodedPath
    } else {
      guard !value.contains(":"), !value.contains("//"),
        !value.contains("?") && !value.contains("#")
      else {
        return nil
      }
      path = value
    }
    let pathWithoutTrailingSlash =
      path.count > 1 && path.hasSuffix("/")
      ? String(path.dropLast()) : path
    guard !pathWithoutTrailingSlash.contains("//") else { return nil }
    var parts = pathWithoutTrailingSlash.split(
      separator: "/",
      omittingEmptySubsequences: true
    ).map(String.init)
    guard parts.count == 2 else { return nil }
    if parts[1].lowercased().hasSuffix(".git") {
      parts[1].removeLast(4)
    }
    guard GitHubInputValidation.validOwner(parts[0]),
      GitHubInputValidation.validRepository(parts[1])
    else {
      return nil
    }
    return RepositoryCoordinates(owner: parts[0], name: parts[1])
  }
}

@MainActor
@Observable
public final class SettingsViewModel {
  public private(set) var state: EngineUIState?
  public private(set) var isWorking = false
  public var message: PresentationMessage?
  public var replacementToken = ""
  public var repositoryReference = ""
  public var newRepositoryReviewEnabled = true
  public var newRepositoryTriageEnabled = true
  public var newRepositoryImplementationEnabled = true
  public var maxConcurrency = 2
  public var profileDrafts: [ModelProfileRole: ModelProfileDraft] = [:]
  public private(set) var modelCatalogNotice: String?

  @ObservationIgnored private let client: any EngineClient
  @ObservationIgnored private var customProfileDrafts: [ModelProfileRole: ModelProfileDraft] = [:]
  @ObservationIgnored private var automaticModelCatalogRefreshAttempted = false
  @ObservationIgnored private let stateDidChange: @MainActor (EngineUIState) -> Void

  public init(
    client: any EngineClient,
    stateDidChange: @escaping @MainActor (EngineUIState) -> Void = { _ in }
  ) {
    self.client = client
    self.stateDidChange = stateDidChange
  }

  public var repositories: [RepositoryConfiguration] {
    state?.settings.repositories ?? []
  }

  public var profiles: [ModelProfileConfiguration] {
    state?.settings.profiles ?? []
  }

  public var modelCatalog: [PiModelCatalogEntry] {
    state?.settings.modelCatalog.models ?? []
  }

  public var loginItemSelected: Bool {
    state?.settings.loginItemSelected ?? false
  }

  public var credentialStatus: EngineCredentialStatus {
    state?.settings.credential ?? .missing
  }

  public var herdrStatus: EngineHerdrStatus {
    state?.settings.herdr ?? .unchecked
  }

  public var canAddRepository: Bool {
    credentialStatus.state == .valid && RepositoryReferenceParser.parse(repositoryReference) != nil
  }

  public var canSubmitCredential: Bool {
    (20...2_048).contains(replacementToken.utf8.count)
  }

  public var diagnostics: [String] {
    guard let diagnostics = state?.diagnostics else {
      return ["Engine diagnostics unavailable"]
    }
    var values = [
      "Schema version: \(diagnostics.schemaVersion)",
      "Nonterminal jobs: \(diagnostics.nonterminalJobCount)",
      "Ambiguous mutations: \(diagnostics.ambiguousMutationCount)",
    ]
    if let code = diagnostics.piIssueCode {
      values.append("Pi status code: \(code.rawValue)")
    }
    if let code = diagnostics.herdrIssueCode {
      values.append("Herdr status code: \(code.rawValue)")
    }
    values += diagnostics.coordinatorFailureCodes.map { "Engine code: \($0)" }
    return values
  }

  public func apply(_ state: EngineUIState) {
    self.state = state
    maxConcurrency = state.settings.maxConcurrency
    let catalogIDs = Set(state.settings.modelCatalog.models.map(\.selectionID))
    for profile in state.settings.profiles {
      let selectionID = "\(profile.provider)/\(profile.model)"
      let source: ModelProfileSource = catalogIDs.contains(selectionID) ? .catalog : .custom
      let saved = ModelProfileDraft(
        source: source,
        provider: profile.provider,
        model: profile.model,
        thinking: profile.thinking
      )
      guard let current = profileDrafts[profile.role], profileIsDirty(profile.role) else {
        profileDrafts[profile.role] = saved
        if source == .custom { customProfileDrafts[profile.role] = saved }
        continue
      }
      if current.source == .custom { customProfileDrafts[profile.role] = current }
      if current.source == .catalog, !catalogIDs.contains(current.selectionID) {
        profileDrafts[profile.role] = customProfileDrafts[profile.role] ?? saved
      }
    }
  }

  public func refresh() async {
    guard let response = await execute(.snapshot) else { return }
    apply(response.state)
    if !response.state.settings.modelCatalog.models.isEmpty {
      modelCatalogNotice = nil
    } else if !automaticModelCatalogRefreshAttempted {
      automaticModelCatalogRefreshAttempted = true
      await refreshModelCatalog(showFailure: false)
    }
  }

  public func refreshModelCatalog() async {
    await refreshModelCatalog(showFailure: true)
  }

  private func refreshModelCatalog(showFailure: Bool) async {
    guard let response = await execute(.refreshModelCatalog, reportFailure: false) else {
      if let snapshot = try? await client.send(.snapshot) {
        apply(snapshot.state)
        stateDidChange(snapshot.state)
      }
      let failure = PresentationCopy.modelCatalogUnavailable()
      modelCatalogNotice = failure.detail
      message = showFailure ? failure : nil
      return
    }
    apply(response.state)
    modelCatalogNotice = nil
  }

  public func setRepositoryEnabled(_ repository: RepositoryConfiguration, value: Bool) async {
    await update(repository) { current in
      RepositoryConfiguration(
        id: current.id,
        nodeID: current.nodeID,
        owner: current.owner,
        name: current.name,
        defaultBranch: current.defaultBranch,
        reviewEnabled: current.reviewEnabled,
        triageEnabled: current.triageEnabled,
        implementationEnabled: current.implementationEnabled,
        enabled: value
      )
    }
  }

  public func setReviewEnabled(_ repository: RepositoryConfiguration, value: Bool) async {
    await update(repository) { current in
      RepositoryConfiguration(
        id: current.id,
        nodeID: current.nodeID,
        owner: current.owner,
        name: current.name,
        defaultBranch: current.defaultBranch,
        reviewEnabled: value,
        triageEnabled: current.triageEnabled,
        implementationEnabled: current.implementationEnabled,
        enabled: current.enabled
      )
    }
  }

  public func setTriageEnabled(_ repository: RepositoryConfiguration, value: Bool) async {
    await update(repository) { current in
      RepositoryConfiguration(
        id: current.id,
        nodeID: current.nodeID,
        owner: current.owner,
        name: current.name,
        defaultBranch: current.defaultBranch,
        reviewEnabled: current.reviewEnabled,
        triageEnabled: value,
        implementationEnabled: current.implementationEnabled,
        enabled: current.enabled
      )
    }
  }

  public func setImplementationEnabled(
    _ repository: RepositoryConfiguration,
    value: Bool
  ) async {
    await update(repository) { current in
      RepositoryConfiguration(
        id: current.id,
        nodeID: current.nodeID,
        owner: current.owner,
        name: current.name,
        defaultBranch: current.defaultBranch,
        reviewEnabled: current.reviewEnabled,
        triageEnabled: current.triageEnabled,
        implementationEnabled: value,
        enabled: current.enabled
      )
    }
  }

  public func addRepository() async {
    guard let repository = RepositoryReferenceParser.parse(repositoryReference) else { return }
    let response = await execute(
      .addRepository(
        EngineRepositoryDraft(
          owner: repository.owner,
          name: repository.name,
          reviewEnabled: newRepositoryReviewEnabled,
          triageEnabled: newRepositoryTriageEnabled,
          implementationEnabled: newRepositoryImplementationEnabled
        )
      )
    )
    if response != nil {
      repositoryReference = ""
    }
  }

  public func removeRepository(_ repository: RepositoryConfiguration) async {
    _ = await execute(.removeRepository(repository.id))
  }

  public func setProfileSource(_ source: ModelProfileSource, role: ModelProfileRole) {
    guard var draft = profileDrafts[role] else { return }
    if source == .custom {
      if draft.source == .catalog, let custom = customProfileDrafts[role] {
        profileDrafts[role] = custom
      } else {
        draft.source = .custom
        profileDrafts[role] = draft
        customProfileDrafts[role] = draft
      }
    } else {
      draft.source = .catalog
      profileDrafts[role] = draft
    }
  }

  public func selectCatalogModel(_ selectionID: String, role: ModelProfileRole) {
    guard let entry = modelCatalog.first(where: { $0.selectionID == selectionID }),
      var draft = profileDrafts[role]
    else {
      return
    }
    if draft.source == .custom { customProfileDrafts[role] = draft }
    draft.source = .catalog
    draft.provider = entry.provider
    draft.model = entry.id
    if !entry.thinkingLevels.contains(draft.thinking) {
      draft.thinking =
        entry.thinkingLevels.contains(.medium)
        ? .medium : entry.thinkingLevels.last ?? .off
    }
    profileDrafts[role] = draft
  }

  public func setProfileProvider(_ provider: String, role: ModelProfileRole) {
    guard var draft = profileDrafts[role], draft.source == .custom else { return }
    draft.provider = provider
    profileDrafts[role] = draft
    customProfileDrafts[role] = draft
  }

  public func setProfileModel(_ model: String, role: ModelProfileRole) {
    guard var draft = profileDrafts[role], draft.source == .custom else { return }
    draft.model = model
    profileDrafts[role] = draft
    customProfileDrafts[role] = draft
  }

  public func setProfileThinking(_ thinking: ModelThinkingLevel, role: ModelProfileRole) {
    guard var draft = profileDrafts[role], availableThinkingLevels(role: role).contains(thinking)
    else {
      return
    }
    draft.thinking = thinking
    profileDrafts[role] = draft
    if draft.source == .custom { customProfileDrafts[role] = draft }
  }

  public func availableThinkingLevels(role: ModelProfileRole) -> [ModelThinkingLevel] {
    guard let draft = profileDrafts[role], draft.source == .catalog,
      let entry = modelCatalog.first(where: { $0.selectionID == draft.selectionID })
    else {
      return ModelThinkingLevel.allCases
    }
    return entry.thinkingLevels
  }

  public func catalogEntry(role: ModelProfileRole) -> PiModelCatalogEntry? {
    guard let draft = profileDrafts[role], draft.source == .catalog else { return nil }
    return modelCatalog.first { $0.selectionID == draft.selectionID }
  }

  public func profileIsDirty(_ role: ModelProfileRole) -> Bool {
    guard let draft = profileDrafts[role],
      let saved = profiles.first(where: { $0.role == role })
    else {
      return false
    }
    return draft.provider != saved.provider || draft.model != saved.model
      || draft.thinking != saved.thinking
  }

  public func saveProfile(role: ModelProfileRole) async {
    guard let draft = profileDrafts[role] else { return }
    let source = draft.source
    let response = await execute(
      .setProfile(
        ModelProfileConfiguration(
          role: role,
          provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
          model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
          thinking: draft.thinking
        )
      )
    )
    guard let response,
      let profile = response.state.settings.profiles.first(where: { $0.role == role })
    else {
      return
    }
    apply(response.state)
    let accepted = ModelProfileDraft(
      source: source,
      provider: profile.provider,
      model: profile.model,
      thinking: profile.thinking
    )
    profileDrafts[role] = accepted
    if source == .custom { customProfileDrafts[role] = accepted }
  }

  public func saveMaxConcurrency() async {
    _ = await execute(.setMaxConcurrency(maxConcurrency))
  }

  public func runHerdrPreflight() async {
    _ = await execute(.runHerdrPreflight)
  }

  public func focusInHerdr() async {
    guard herdrStatus.state == .ready else { return }
    _ = await execute(.focusInHerdr)
  }

  public func setLoginItemEnabled(_ enabled: Bool) async {
    _ = await execute(.setLoginEnabled(enabled))
  }

  public func replaceCredential() async {
    guard canSubmitCredential else { return }
    var data = Data(replacementToken.utf8)
    replacementToken = ""
    let dataCount = data.count
    defer { data.resetBytes(in: 0..<dataCount) }
    _ = await execute(.replaceCredential(data))
  }

  public func deleteCredential() async {
    replacementToken = ""
    _ = await execute(.deleteCredential)
  }

  private func update(
    _ repository: RepositoryConfiguration,
    transform: (RepositoryConfiguration) -> RepositoryConfiguration
  ) async {
    guard let current = state?.settings.repositories.first(where: { $0.id == repository.id }) else {
      return
    }
    _ = await execute(.updateRepository(transform(current)))
  }

  @discardableResult
  private func execute(
    _ command: EngineCommand,
    reportFailure: Bool = true
  ) async -> EngineCommandResponse? {
    guard !isWorking else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      let response = try await client.send(command)
      state = response.state
      stateDidChange(response.state)
      message = nil
      return response
    } catch {
      message = reportFailure ? PresentationCopy.message(for: error) : nil
      return nil
    }
  }
}
