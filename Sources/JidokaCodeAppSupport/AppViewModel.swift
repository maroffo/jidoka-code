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
  public private(set) var recoveryPreview: RolloutRecoveryPreview?

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
    guard let rollout = state.rollout,
      rollout.status.authorization.state == .active,
      rollout.status.scope.mode == .finiteWindow
    else {
      return "Poll Now requires an active finite rollout window."
    }
    if state.onboarding.credential.state != .valid {
      return "Connect GitHub in Settings to poll."
    }
    if state.onboarding.pi.state != .ready {
      return "Restore the attested Pi runtime, then restart Jidoka Code."
    }
    if state.settings.herdr.state != .ready {
      return "Restore Herdr readiness before polling."
    }
    if !state.settings.repositories.contains(where: {
      $0.id == rollout.status.authorization.repositoryID && $0.enabled
    }) {
      return "The rollout repository is not enabled."
    }
    if !state.settings.loginItemSelected || state.settings.loginItemStatus != .enabled {
      return "Enable the login item before polling."
    }
    if Set(state.settings.profiles.map(\.role)) != Set(ModelProfileRole.allCases) {
      return "Configure every model profile before polling."
    }
    return nil
  }

  public var canStopAndDrain: Bool {
    guard let rollout = state?.rollout else { return false }
    return !isWorking && rollout.status.authorization.state == .active
  }

  public var canPreviewRecovery: Bool {
    guard let rollout = state?.rollout else { return false }
    return !isWorking && rollout.status.authorization.state == .recoveryRequired
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

  public func pauseForContainment() async {
    guard !isWorking, state?.paused == false, state?.rollout == nil else { return }
    _ = await execute(.setPaused(true))
  }

  public func stopAndDrain() async {
    guard canStopAndDrain, let authorization = state?.rollout?.status.authorization else {
      return
    }
    _ = await execute(
      .stopAndDrainRollout(
        RolloutStopRequest(
          authorizationID: authorization.id,
          previewSHA256: authorization.previewSHA256,
          timeoutMilliseconds: 60_000
        )
      )
    )
  }

  public func previewRecovery() async {
    guard canPreviewRecovery, let authorization = state?.rollout?.status.authorization else {
      return
    }
    recoveryPreview = await execute(
      .previewRolloutRecovery(
        RolloutRecoveryRequest(
          authorizationID: authorization.id,
          previewSHA256: authorization.previewSHA256
        )
      )
    )?.rolloutRecoveryPreview
  }

  public func cancelRecovery() {
    recoveryPreview = nil
  }

  public func executeRecovery() async {
    guard let recoveryPreview else { return }
    self.recoveryPreview = nil
    _ = await execute(
      .executeRolloutRecovery(
        RolloutRecoveryAuthorization(
          approvedCanonicalJSON: recoveryPreview.canonicalJSON,
          confirmedSHA256: recoveryPreview.sha256
        )
      )
    )
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
