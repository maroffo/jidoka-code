import Foundation
import JidokaCodeCore
import Observation

public struct ModelProfileDraft: Equatable, Sendable {
  public var provider: String
  public var model: String
  public var thinking: ModelThinkingLevel

  public init(provider: String, model: String, thinking: ModelThinkingLevel) {
    self.provider = provider
    self.model = model
    self.thinking = thinking
  }
}

@MainActor
@Observable
public final class SettingsViewModel {
  public private(set) var state: EngineUIState?
  public private(set) var isWorking = false
  public var message: PresentationMessage?
  public var replacementToken = ""
  public var repositoryOwner = ""
  public var repositoryName = ""
  public var newRepositoryReviewEnabled = true
  public var newRepositoryTriageEnabled = true
  public var newRepositoryImplementationEnabled = true
  public var maxConcurrency = 2
  public var profileDrafts: [ModelProfileRole: ModelProfileDraft] = [:]

  @ObservationIgnored private let client: any EngineClient
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

  public var loginItemSelected: Bool {
    state?.settings.loginItemSelected ?? false
  }

  public var credentialStatus: EngineCredentialStatus {
    state?.settings.credential ?? .missing
  }

  public var herdrStatus: EngineHerdrStatus {
    state?.settings.herdr ?? .unchecked
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
    profileDrafts = Dictionary(
      uniqueKeysWithValues: state.settings.profiles.map {
        (
          $0.role,
          ModelProfileDraft(
            provider: $0.provider,
            model: $0.model,
            thinking: $0.thinking
          )
        )
      }
    )
  }

  public func refresh() async {
    guard let response = await execute(.snapshot) else { return }
    apply(response.state)
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
    let owner = repositoryOwner.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !owner.isEmpty, !name.isEmpty else { return }
    let response = await execute(
      .addRepository(
        EngineRepositoryDraft(
          owner: owner,
          name: name,
          reviewEnabled: newRepositoryReviewEnabled,
          triageEnabled: newRepositoryTriageEnabled,
          implementationEnabled: newRepositoryImplementationEnabled
        )
      )
    )
    if response != nil {
      repositoryOwner = ""
      repositoryName = ""
    }
  }

  public func removeRepository(_ repository: RepositoryConfiguration) async {
    _ = await execute(.removeRepository(repository.id))
  }

  public func setProfileProvider(_ provider: String, role: ModelProfileRole) {
    guard var draft = profileDrafts[role] else { return }
    draft.provider = provider
    profileDrafts[role] = draft
  }

  public func setProfileModel(_ model: String, role: ModelProfileRole) {
    guard var draft = profileDrafts[role] else { return }
    draft.model = model
    profileDrafts[role] = draft
  }

  public func setProfileThinking(_ thinking: ModelThinkingLevel, role: ModelProfileRole) {
    guard var draft = profileDrafts[role] else { return }
    draft.thinking = thinking
    profileDrafts[role] = draft
  }

  public func saveProfile(role: ModelProfileRole) async {
    guard let draft = profileDrafts[role] else { return }
    _ = await execute(
      .setProfile(
        ModelProfileConfiguration(
          role: role,
          provider: draft.provider,
          model: draft.model,
          thinking: draft.thinking
        )
      )
    )
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
    guard (20...2_048).contains(replacementToken.utf8.count) else { return }
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
  private func execute(_ command: EngineCommand) async -> EngineCommandResponse? {
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
      message = PresentationCopy.message(for: error)
      return nil
    }
  }
}
