import Foundation
import JidokaCodeCore
import Observation

@MainActor
@Observable
public final class OnboardingViewModel {
  public private(set) var state: EngineUIState?
  public private(set) var isWorking = false
  public var message: PresentationMessage?

  public var token = ""
  public var repositoryOwner = ""
  public var repositoryName = ""
  public var reviewEnabled = true
  public var triageEnabled = true
  public var implementationEnabled = true
  public var loginItemSelected = true

  @ObservationIgnored private let client: any EngineClient
  @ObservationIgnored private let stateDidChange: @MainActor (EngineUIState) -> Void

  public init(
    client: any EngineClient,
    stateDidChange: @escaping @MainActor (EngineUIState) -> Void = { _ in }
  ) {
    self.client = client
    self.stateDidChange = stateDidChange
  }

  public var canImportCredential: Bool {
    !isWorking && (20...2_048).contains(token.utf8.count)
  }

  public var canAddRepository: Bool {
    !isWorking && !repositoryOwner.isEmpty && !repositoryName.isEmpty
  }

  public var canComplete: Bool {
    guard let onboarding = state?.onboarding else { return false }
    return !isWorking
      && onboarding.duplicateInstanceCheckPassed
      && onboarding.externalAutomationAcknowledged
      && onboarding.providerDisclosureAcknowledged
      && onboarding.pi.state == .ready
      && onboarding.herdr.state == .ready
      && onboarding.credential.state == .valid
      && onboarding.repositoryCount > 0
      && Set(onboarding.configuredProfileRoles) == Set(ModelProfileRole.allCases)
      && loginItemSelected
  }

  public func apply(_ state: EngineUIState) {
    self.state = state
    loginItemSelected = state.onboarding.loginItemSelected || !state.onboarding.complete
  }

  public func refresh() async {
    _ = await execute(.snapshot)
  }

  public func acknowledgeExternalAutomation(_ acknowledged: Bool) async {
    _ = await execute(.acknowledgeExternalAutomation(acknowledged))
  }

  public func acknowledgeProviderDisclosure(_ acknowledged: Bool) async {
    _ = await execute(.acknowledgeProviderDisclosure(acknowledged))
  }

  public func runPiPreflight() async {
    _ = await execute(.runPiPreflight)
  }

  public func runHerdrPreflight() async {
    _ = await execute(.runHerdrPreflight)
  }

  public func validateAndImportCredential() async {
    guard canImportCredential else { return }
    var value = Data(token.utf8)
    token = ""
    let valueCount = value.count
    defer { value.resetBytes(in: 0..<valueCount) }
    _ = await execute(.replaceCredential(value))
  }

  public func validateAndAddRepository() async {
    guard canAddRepository else { return }
    let draft = EngineRepositoryDraft(
      owner: repositoryOwner.trimmingCharacters(in: .whitespacesAndNewlines),
      name: repositoryName.trimmingCharacters(in: .whitespacesAndNewlines),
      reviewEnabled: reviewEnabled,
      triageEnabled: triageEnabled,
      implementationEnabled: implementationEnabled
    )
    guard await execute(.addRepository(draft)) != nil else { return }
    repositoryOwner = ""
    repositoryName = ""
  }

  @discardableResult
  public func complete() async -> Bool {
    guard canComplete else { return false }
    guard await execute(.setLoginEnabled(loginItemSelected)) != nil else {
      return false
    }
    return await execute(.completeOnboarding) != nil
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
