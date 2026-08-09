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
    guard let state else { return false }
    return !isWorking && !state.paused && state.lifecycle == .ready
  }

  public var canPauseOrResume: Bool {
    guard let state else { return false }
    return !isWorking && state.lifecycle == .ready
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
    guard let checkpoint = await execute(.prepareForQuit)?.checkpoint,
      checkpoint.databaseCheckpointed
    else {
      message = PresentationCopy.message(for: EngineClientError(.checkpointFailed))
      return nil
    }
    return checkpoint
  }

  @discardableResult
  private func execute(_ command: EngineCommand) async -> EngineCommandResponse? {
    guard !isWorking else { return nil }
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
