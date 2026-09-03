import Foundation
import JidokaCodeCore
import Observation

@MainActor
@Observable
public final class AppViewModel {
  public private(set) var state: EngineUIState?
  public private(set) var isWorking = false
  public var message: PresentationMessage?
  public var pendingRetryAuthorization: EngineAmbiguousMutation?

  @ObservationIgnored private let client: any EngineClient
  @ObservationIgnored private var terminationRequested = false

  public init(client: any EngineClient) {
    self.client = client
  }

  public var statusTitle: String {
    state?.operationalStatus.displayName ?? "Connecting"
  }

  public var statusSystemImage: String {
    state?.operationalStatus.systemImage ?? "ellipsis.circle"
  }

  public var canPoll: Bool {
    !isWorking && pollingUnavailableReason == nil
  }

  public var pollingUnavailableReason: String? {
    guard let state else { return "Connecting to the engine." }
    switch state.lifecycle {
    case .onboarding:
      return "Finish setup to enable polling."
    case .quitting:
      return "Jidoka Code is preparing to quit."
    case .blocked:
      return "Resolve the engine warning before polling."
    case .ready:
      break
    }
    if state.paused { return "Resume automation to poll." }
    if state.onboarding.credential.state != .valid {
      return "Connect GitHub in Settings to poll."
    }
    if state.onboarding.pi.state != .ready {
      return "Restore the attested Pi runtime, then restart Jidoka Code."
    }
    if state.settings.herdr.state != .ready {
      return "Restore Herdr readiness before polling."
    }
    if !state.settings.repositories.contains(where: { $0.enabled }) {
      return "Add and enable a repository in Settings to poll."
    }
    if !state.settings.loginItemSelected || state.settings.loginItemStatus != .enabled {
      return "Enable the login item before polling."
    }
    if Set(state.settings.profiles.map(\.role)) != Set(ModelProfileRole.allCases) {
      return "Configure every model profile before polling."
    }
    return nil
  }

  public var canPauseOrResume: Bool {
    guard let state else { return false }
    return !isWorking && state.lifecycle == .ready
  }

  public var canFocusInHerdr: Bool {
    guard let state else { return false }
    return !isWorking && state.lifecycle == .ready && state.settings.herdr.state == .ready
  }

  public func apply(_ state: EngineUIState) {
    self.state = state
  }

  public func refresh() async {
    _ = await execute(.snapshot)
  }

  public func pollNow() async {
    guard canPoll else { return }
    _ = await execute(.pollNow)
  }

  public func togglePaused() async {
    guard let state, canPauseOrResume else { return }
    _ = await execute(.setPaused(!state.paused))
  }

  public func focusInHerdr() async {
    guard canFocusInHerdr else { return }
    _ = await execute(.focusInHerdr)
  }

  public func recheck(_ mutation: EngineAmbiguousMutation) async {
    _ = await execute(
      .recheckAmbiguousMutation(EngineAmbiguousMutationEvidence(mutation))
    )
  }

  public func requestRetryAuthorization(_ mutation: EngineAmbiguousMutation) {
    pendingRetryAuthorization = mutation
  }

  public func cancelRetryAuthorization() {
    pendingRetryAuthorization = nil
  }

  public func authorizePendingRetry() async {
    guard let pendingRetryAuthorization else { return }
    self.pendingRetryAuthorization = nil
    _ = await execute(
      .authorizeRetry(EngineAmbiguousMutationEvidence(pendingRetryAuthorization))
    )
  }

  @discardableResult
  public func prepareForQuit() async -> EngineCheckpointReceipt? {
    terminationRequested = true
    while isWorking {
      if Task.isCancelled {
        terminationRequested = false
        return nil
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard let checkpoint = await execute(.prepareForQuit)?.checkpoint,
      checkpoint.databaseCheckpointed
    else {
      terminationRequested = false
      message = PresentationCopy.message(for: EngineClientError(.checkpointFailed))
      return nil
    }
    return checkpoint
  }

  @discardableResult
  private func execute(_ command: EngineCommand) async -> EngineCommandResponse? {
    guard !isWorking,
      !terminationRequested || command.kind == .prepareForQuit
    else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      let response = try await client.send(command)
      state = response.state
      message = nil
      return response
    } catch {
      message = PresentationCopy.message(for: error)
      return nil
    }
  }
}
