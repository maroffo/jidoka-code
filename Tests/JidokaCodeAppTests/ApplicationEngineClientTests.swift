import AppKit
import Foundation
import JidokaCodeCore
import Testing

@testable import JidokaCodeApp

@Suite("Application helper handoff")
struct ApplicationEngineClientTests {
  @Test("production activation notification identity is exact")
  func productionActivationNotification() {
    #expect(
      JidokaApplicationInstance.activationNotification == "com.maroffo.JidokaCode.ui.activate")
  }

  @Test("first onboarding checkpoints bootstrap before registration and helper handoff")
  func enableAndComplete() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    _ = try await client.send(.snapshot)
    let enabled = try await client.send(.setLoginEnabled(true))
    #expect(enabled.state.settings.loginItemStatus == .enabled)
    #expect(enabled.state.settings.loginItemSelected)
    let completed = try await client.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)

    let values = await events.values
    try expectOrder(
      values,
      [
        "bootstrap-1:prepareForHandoff",
        "bootstrap-1:close",
        "login:register",
        "helper:snapshot",
        "helper:synchronizeLoginStatus",
        "helper:completeOnboarding",
      ]
    )
    #expect(await factory.count == 1)
  }

  @Test("requires approval remains on the bootstrap control plane without starting jobs")
  func requiresApproval() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .requiresApproval,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    let enabled = try await client.send(.setLoginEnabled(true))
    #expect(enabled.state.settings.loginItemStatus == .requiresApproval)
    let completed = try await client.send(.completeOnboarding)
    #expect(completed.state.lifecycle == .ready)
    #expect(completed.state.operationalStatus == .warning)
    #expect(await factory.count == 2)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
  }

  @Test("disabling login checkpoints the helper before unregistering")
  func disableCheckpointsFirst() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      engineLockFactory: {
        await events.append("engine-lock:acquired")
        return TestEngineTopologyLock()
      },
      bootstrapFactory: { await factory.make() }
    )

    let response = try await client.send(.setLoginEnabled(false))
    #expect(!response.state.settings.loginItemSelected)
    #expect(response.state.settings.loginItemStatus == .notRegistered)
    try expectOrder(
      await events.values,
      [
        "helper:prepareForQuit",
        "engine-lock:acquired",
        "login:unregister",
        "bootstrap-1:created",
        "bootstrap-1:synchronizeLoginStatus",
      ]
    )
  }

  @Test("topology changes require an explicit durable checkpoint receipt")
  func checkpointReceiptRequired() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: true,
      loginStatus: .enabled,
      events: events,
      checkpointSucceeds: false
    )
    let factory = BootstrapFactory(
      events: events,
      onboardingReady: true,
      checkpointSucceeds: false
    )
    let enabling = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )
    await #expect(throws: EngineClientError(.checkpointFailed)) {
      _ = try await enabling.send(.setLoginEnabled(true))
    }
    #expect(!(await events.values).contains("login:register"))
    #expect(!(await events.values).contains("bootstrap-1:close"))

    let enabledLogin = LoginItemControllerFake(
      status: .enabled,
      registeredStatus: .enabled,
      events: events
    )
    let disabling = ProductionEngineClient(
      loginItems: enabledLogin,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )
    await #expect(throws: EngineClientError(.checkpointFailed)) {
      _ = try await disabling.send(.setLoginEnabled(false))
    }
    #expect(!(await events.values).contains("login:unregister"))
  }

  @Test("post-registration helper failure checkpoints, unregisters, and restores bootstrap")
  func postRegistrationFailureRollsBack() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events,
      failingKinds: [.snapshot]
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    try expectOrder(
      await events.values,
      [
        "login:register",
        "helper:snapshot",
        "helper:prepareForQuit",
        "login:unregister",
      ]
    )
    #expect(await factory.count == 2)
  }

  @Test("registration failure reopens bootstrap and returns a redacted code")
  func registrationFailure() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events,
      failRegistration: true
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: true)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.loginItemFailed)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    #expect(await factory.count == 2)
    #expect(!(await events.values).contains(where: { $0.hasPrefix("helper:") }))
  }

  @Test("every application termination path shares one durable checkpoint gate")
  @MainActor
  func durableTerminationGate() async throws {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var duplicateCompletions: [Bool] = []
    let first = gate.request(
      checkpoint: { await probe.checkpoint() },
      completion: { probe.complete($0) }
    )
    let duplicate = gate.request(
      checkpoint: {
        Issue.record("a duplicate termination request started another checkpoint")
        return false
      },
      completion: { duplicateCompletions.append($0) }
    )
    #expect(first == .terminateLater)
    #expect(duplicate == .terminateLater)
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    #expect(probe.callCount == 1)
    #expect(probe.continuation != nil)
    probe.resume(true)
    for _ in 0..<100 where duplicateCompletions.isEmpty { await Task.yield() }
    #expect(probe.completions == [true])
    #expect(duplicateCompletions == [true])
    #expect(
      gate.request(checkpoint: { false }, completion: { _ in }) == .terminateNow
    )
  }

  @Test("a notification checkpoint completes before synchronous termination")
  @MainActor
  func preparedTerminationGate() async {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var events: [String] = []
    gate.prepareAndRequestTermination(
      checkpoint: {
        events.append("checkpoint-start")
        let result = await probe.checkpoint()
        events.append("checkpoint-end")
        return result
      },
      requestTermination: { events.append("terminate") }
    )
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    #expect(events == ["checkpoint-start"])
    probe.resume(true)
    for _ in 0..<100 where events.count < 3 { await Task.yield() }
    #expect(events == ["checkpoint-start", "checkpoint-end", "terminate"])
    #expect(gate.request(checkpoint: { false }, completion: { _ in }) == .terminateNow)
  }

  @Test("a failed notification checkpoint resolves a concurrent AppKit quit")
  @MainActor
  func failedPreparedTerminationResolvesConcurrentRequest() async {
    let probe = TerminationCheckpointProbe()
    let gate = DurableTerminationGate()
    var requestCompletions: [Bool] = []
    var terminationRequests = 0
    gate.prepareAndRequestTermination(
      checkpoint: { await probe.checkpoint() },
      requestTermination: { terminationRequests += 1 }
    )
    let reply = gate.request(
      checkpoint: {
        Issue.record("a concurrent AppKit quit started another checkpoint")
        return true
      },
      completion: { requestCompletions.append($0) }
    )
    #expect(reply == .terminateLater)
    for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
    probe.resume(false)
    for _ in 0..<100 where requestCompletions.isEmpty { await Task.yield() }
    #expect(requestCompletions == [false])
    #expect(terminationRequests == 0)
  }

  @Test("incomplete bootstrap never attempts registration")
  func incompleteBootstrap() async throws {
    let events = TopologyEventLog()
    let login = LoginItemControllerFake(
      status: .notRegistered,
      registeredStatus: .enabled,
      events: events
    )
    let helper = TopologyEngineClientFake(
      name: "helper",
      onboardingReady: true,
      loginSelected: false,
      loginStatus: .notRegistered,
      events: events
    )
    let factory = BootstrapFactory(events: events, onboardingReady: false)
    let client = ProductionEngineClient(
      loginItems: login,
      helper: helper,
      bootstrapFactory: { await factory.make() }
    )

    await #expect(throws: EngineClientError(.onboardingIncomplete)) {
      _ = try await client.send(.setLoginEnabled(true))
    }
    #expect(!(await events.values).contains("login:register"))
  }

  private func expectOrder(_ values: [String], _ expected: [String]) throws {
    var position = values.startIndex
    for item in expected {
      let index = try #require(values[position...].firstIndex(of: item))
      position = values.index(after: index)
    }
  }
}

@MainActor
private final class TerminationCheckpointProbe {
  var callCount = 0
  var completions: [Bool] = []
  var continuation: CheckedContinuation<Bool, Never>?

  func checkpoint() async -> Bool {
    callCount += 1
    return await withCheckedContinuation { continuation = $0 }
  }

  func resume(_ value: Bool) {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }

  func complete(_ value: Bool) {
    completions.append(value)
  }
}

private final class TestEngineTopologyLock: EngineTopologyLocking, @unchecked Sendable {
  func release() {}
}

private actor TopologyEventLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor LoginItemControllerFake: LoginItemControlling {
  private var current: LifecycleServiceStatus
  private let registeredStatus: LifecycleServiceStatus
  private let events: TopologyEventLog
  private let failRegistration: Bool

  init(
    status: LifecycleServiceStatus,
    registeredStatus: LifecycleServiceStatus,
    events: TopologyEventLog,
    failRegistration: Bool = false
  ) {
    current = status
    self.registeredStatus = registeredStatus
    self.events = events
    self.failRegistration = failRegistration
  }

  func status() -> LifecycleServiceStatus {
    current
  }

  func register() async throws {
    await events.append("login:register")
    if failRegistration { throw EngineClientError(.loginItemFailed) }
    current = registeredStatus
  }

  func unregister() async {
    await events.append("login:unregister")
    current = .notRegistered
  }
}

private actor TopologyEngineClientFake: EngineClient {
  private let name: String
  private let onboardingReady: Bool
  private let events: TopologyEventLog
  private let checkpointSucceeds: Bool
  private let failingKinds: Set<EngineCommandKind>
  private var lifecycle = EngineLifecycleState.onboarding
  private var loginSelected: Bool
  private var loginStatus: LifecycleServiceStatus

  init(
    name: String,
    onboardingReady: Bool,
    loginSelected: Bool,
    loginStatus: LifecycleServiceStatus,
    events: TopologyEventLog,
    checkpointSucceeds: Bool = true,
    failingKinds: Set<EngineCommandKind> = []
  ) {
    self.name = name
    self.onboardingReady = onboardingReady
    self.loginSelected = loginSelected
    self.loginStatus = loginStatus
    self.events = events
    self.checkpointSucceeds = checkpointSucceeds
    self.failingKinds = failingKinds
  }

  func send(_ command: EngineCommand) async throws -> EngineCommandResponse {
    await events.append("\(name):\(command.kind.rawValue)")
    if failingKinds.contains(command.kind) {
      throw EngineClientError(.unavailable)
    }
    var checkpoint: EngineCheckpointReceipt?
    switch command {
    case .synchronizeLoginStatus(let selected, let status):
      loginSelected = selected
      loginStatus = status
    case .completeOnboarding:
      lifecycle = .ready
    case .prepareForHandoff, .prepareForQuit:
      if checkpointSucceeds {
        checkpoint = EngineCheckpointReceipt(
          checkpointID: UUID(),
          completedAt: Date(timeIntervalSince1970: 600_000),
          nonterminalJobCount: 0,
          ambiguousMutationCount: 0,
          databaseCheckpointed: true
        )
      }
    default:
      break
    }
    return EngineCommandResponse(
      command: command.kind,
      state: state(),
      checkpoint: checkpoint
    )
  }

  private func state() -> EngineUIState {
    let credential =
      onboardingReady
      ? EngineCredentialStatus(state: .valid, account: "octocat") : .missing
    let pi =
      onboardingReady
      ? EnginePiStatus(
        state: .ready,
        executablePath: "/opt/homebrew/bin/pi",
        version: "0.84.1",
        policySHA256: String(repeating: "f", count: 64)
      ) : .unchecked
    let herdr =
      onboardingReady
      ? EngineHerdrStatus(
        state: .ready,
        version: "0.8.0",
        protocolVersion: 19,
        executableSHA256: String(repeating: "e", count: 64),
        schemaSHA256: String(repeating: "d", count: 64),
        policySHA256: String(repeating: "c", count: 64)
      ) : .unchecked
    let profiles = ModelProfileRole.allCases.map {
      ModelProfileConfiguration(
        role: $0,
        provider: "openai-codex",
        model: "gpt-5.6-sol",
        thinking: .max
      )
    }
    let repository = RepositoryConfiguration(
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
    let repositories = onboardingReady ? [repository] : []
    let onboarding = EngineOnboardingSnapshot(
      duplicateInstanceCheckPassed: true,
      externalAutomationAcknowledged: onboardingReady,
      providerDisclosureAcknowledged: onboardingReady,
      pi: pi,
      herdr: herdr,
      credential: credential,
      repositoryCount: repositories.count,
      configuredProfileRoles: profiles.map(\.role),
      loginItemSelected: loginSelected,
      loginItemStatus: loginStatus,
      complete: lifecycle == .ready
    )
    return EngineUIState(
      revision: 1,
      lifecycle: lifecycle,
      operationalStatus: lifecycle == .ready && loginStatus != .enabled ? .warning : .active,
      paused: false,
      passRunning: false,
      activities: [],
      ambiguousMutations: [],
      onboarding: onboarding,
      settings: EngineSettingsSnapshot(
        repositories: repositories,
        profiles: profiles,
        maxConcurrency: 2,
        loginItemSelected: loginSelected,
        loginItemStatus: loginStatus,
        credential: credential,
        herdr: herdr
      ),
      diagnostics: EngineDiagnostics(
        schemaVersion: 2,
        nonterminalJobCount: 0,
        ambiguousMutationCount: 0,
        coordinatorFailureCodes: [],
        piIssueCode: nil,
        herdrIssueCode: nil
      )
    )
  }
}

private final class TopologyBootstrapContainer: BootstrapEngineContaining, @unchecked Sendable {
  let client: any EngineClient
  private let name: String
  private let events: TopologyEventLog

  init(client: any EngineClient, name: String, events: TopologyEventLog) {
    self.client = client
    self.name = name
    self.events = events
  }

  func close() async {
    await events.append("\(name):close")
  }
}

private actor BootstrapFactory {
  private let events: TopologyEventLog
  private let onboardingReady: Bool
  private let checkpointSucceeds: Bool
  private(set) var count = 0

  init(
    events: TopologyEventLog,
    onboardingReady: Bool,
    checkpointSucceeds: Bool = true
  ) {
    self.events = events
    self.onboardingReady = onboardingReady
    self.checkpointSucceeds = checkpointSucceeds
  }

  func make() async -> any BootstrapEngineContaining {
    count += 1
    let name = "bootstrap-\(count)"
    await events.append("\(name):created")
    return TopologyBootstrapContainer(
      client: TopologyEngineClientFake(
        name: name,
        onboardingReady: onboardingReady,
        loginSelected: false,
        loginStatus: .notRegistered,
        events: events,
        checkpointSucceeds: checkpointSucceeds
      ),
      name: name,
      events: events
    )
  }
}
