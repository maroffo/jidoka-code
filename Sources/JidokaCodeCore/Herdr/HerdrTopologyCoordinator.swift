import CryptoKit
import Darwin
import Foundation

protocol HerdrTopologyAPI: Sendable {
  func handshake() async throws -> HerdrHandshake
  func createWorkspace(
    _ parameters: HerdrWorkspaceCreateParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrWorkspaceCreatedResult
  func applyLayout(
    _ parameters: HerdrLayoutApplyParameters,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrLayoutApplyResult
  func exportLayout(
    tabID: String,
    attestedBy handshake: HerdrHandshake
  ) async throws -> HerdrLayoutDescription
}

extension HerdrSocketClient: HerdrTopologyAPI {}

struct HerdrTopologyMutationKey: Hashable, Sendable {
  let repositoryID: String
}

struct HerdrTopologyMutationLease: Equatable, Sendable {
  let key: HerdrTopologyMutationKey
  let token: UUID
}

enum HerdrTopologyMutationGateError: Error, Equatable, Sendable {
  case closed
}

actor HerdrTopologyMutationGate {
  // The engine is single-instance, so a process-wide gate excludes competing coordinators.
  // The intent store remains the recovery authority across process restarts.
  static let shared = HerdrTopologyMutationGate()

  private var allowed: Bool
  private struct SerialWaiter {
    let token: UUID
    let continuation: CheckedContinuation<HerdrTopologyMutationLease, Error>
  }

  private var active: [HerdrTopologyMutationKey: UUID] = [:]
  private var serialWaiters: [HerdrTopologyMutationKey: [SerialWaiter]] = [:]
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  init(initiallyAllowed: Bool = true) {
    allowed = initiallyAllowed
  }

  func acquire(key: HerdrTopologyMutationKey) throws -> HerdrTopologyMutationLease {
    guard allowed else { throw HerdrTopologyMutationGateError.closed }
    guard active[key] == nil else { throw HerdrTopologyError.concurrentMutation }
    let lease = HerdrTopologyMutationLease(key: key, token: UUID())
    active[key] = lease.token
    return lease
  }

  func acquireSerially(
    key: HerdrTopologyMutationKey
  ) async throws -> HerdrTopologyMutationLease {
    guard allowed else { throw HerdrTopologyMutationGateError.closed }
    if active[key] == nil {
      let lease = HerdrTopologyMutationLease(key: key, token: UUID())
      active[key] = lease.token
      return lease
    }
    let token = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      serialWaiters[key, default: []].append(
        SerialWaiter(token: token, continuation: continuation)
      )
    }
  }

  func release(_ lease: HerdrTopologyMutationLease) {
    guard active[lease.key] == lease.token else { return }
    if allowed, var waiters = serialWaiters[lease.key], !waiters.isEmpty {
      let next = waiters.removeFirst()
      if waiters.isEmpty {
        serialWaiters.removeValue(forKey: lease.key)
      } else {
        serialWaiters[lease.key] = waiters
      }
      active[lease.key] = next.token
      next.continuation.resume(
        returning: HerdrTopologyMutationLease(key: lease.key, token: next.token)
      )
      return
    }
    active.removeValue(forKey: lease.key)
    resumeCloseWaitersIfIdle()
  }

  func close() {
    allowed = false
    let queued = serialWaiters.values.flatMap { $0 }
    serialWaiters.removeAll()
    for waiter in queued {
      waiter.continuation.resume(throwing: HerdrTopologyMutationGateError.closed)
    }
  }

  func waitUntilIdle() async {
    guard !active.isEmpty else { return }
    await withCheckedContinuation { continuation in
      closeWaiters.append(continuation)
    }
  }

  func closeAndWait() async {
    close()
    await waitUntilIdle()
  }

  func open() {
    allowed = true
  }

  private func resumeCloseWaitersIfIdle() {
    guard active.isEmpty else { return }
    let waiters = closeWaiters
    closeWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

actor HerdrTopologyCoordinator {
  private let api: any HerdrTopologyAPI
  private let intents: any HerdrTopologyIntentStoring
  private let gate: HerdrTopologyMutationGate
  private let mutationID: @Sendable () -> String

  init(
    api: any HerdrTopologyAPI,
    intents: any HerdrTopologyIntentStoring,
    gate: HerdrTopologyMutationGate = .shared,
    mutationID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.api = api
    self.intents = intents
    self.gate = gate
    self.mutationID = mutationID
  }

  func ensureTopology(for plan: HerdrTopologyPlan) async throws -> HerdrTopologyBinding {
    try Self.validateFilesystem(plan)
    let lease = try await gate.acquire(key: Self.mutationKey(repositoryID: plan.repositoryID))
    do {
      let initial = try await api.handshake()
      let baselineFocus = HerdrTopologyFocus(snapshot: initial.snapshot)
      let workspace = try await resolveWorkspace(
        for: try Self.workspacePlan(plan),
        jobID: plan.jobID,
        generation: plan.generation,
        handshake: initial,
        baselineFocus: baselineFocus
      )
      let result = try await createJobTabIfAbsent(
        for: plan,
        workspace: workspace,
        baselineFocus: baselineFocus
      )
      await gate.release(lease)
      return result
    } catch {
      await gate.release(lease)
      throw error
    }
  }

  func ensureWorkspace(
    for plan: HerdrWorkspacePlan,
    jobID: String,
    generation: Int
  ) async throws -> HerdrWorkspaceBinding {
    try Self.validateFilesystem(plan)
    guard jobID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      (1...1_000_000).contains(generation)
    else {
      throw HerdrTopologyError.invalidPlan
    }
    let lease = try await gate.acquire(key: Self.mutationKey(repositoryID: plan.repositoryID))
    do {
      let initial = try await api.handshake()
      let result = try await resolveWorkspace(
        for: plan,
        jobID: jobID,
        generation: generation,
        handshake: initial,
        baselineFocus: HerdrTopologyFocus(snapshot: initial.snapshot)
      )
      await gate.release(lease)
      return result
    } catch {
      await gate.release(lease)
      throw error
    }
  }

  func ensureJobTab(
    for plan: HerdrTopologyPlan,
    workspace priorWorkspace: HerdrWorkspaceBinding
  ) async throws -> HerdrTopologyBinding {
    try Self.validateFilesystem(plan)
    guard priorWorkspace.workspaceID == plan.boundWorkspaceID else {
      throw HerdrTopologyError.workspaceIdentityMismatch
    }
    let lease = try await gate.acquire(key: Self.mutationKey(repositoryID: plan.repositoryID))
    do {
      let current = try await compatibleHandshake(after: priorWorkspace.handshake)
      let baselineFocus = HerdrTopologyFocus(snapshot: current.snapshot)
      guard
        current.snapshot.workspaces.contains(where: {
          $0.workspaceID == priorWorkspace.workspaceID
            && Self.matchesRepository(
              workspace: $0,
              snapshot: current.snapshot,
              repositoryRoot: plan.repositoryRoot
            )
        })
      else {
        throw HerdrTopologyError.workspaceIdentityMismatch
      }
      let result = try await createJobTabIfAbsent(
        for: plan,
        workspace: HerdrWorkspaceBinding(
          workspaceID: priorWorkspace.workspaceID,
          handshake: current
        ),
        baselineFocus: baselineFocus
      )
      await gate.release(lease)
      return result
    } catch {
      await gate.release(lease)
      throw error
    }
  }

  func recoverJobTab(
    for plan: HerdrTopologyPlan,
    workspace: HerdrWorkspaceBinding
  ) async throws -> HerdrTopologyBinding {
    try Self.validateFilesystem(plan)
    guard workspace.workspaceID == plan.boundWorkspaceID else {
      throw HerdrTopologyError.bindingLost
    }
    let expectedRoot = Self.layout(for: plan.launches)
    let parameters = HerdrLayoutApplyParameters(
      workspaceID: workspace.workspaceID,
      tabLabel: plan.tabLabel,
      focus: false,
      root: expectedRoot
    )
    guard
      let stored = try await intents.storedIntent(
        kind: .applyLayout,
        repositoryID: plan.repositoryID,
        jobID: plan.jobID,
        generation: plan.generation,
        payloadSHA256: try Self.digest(parameters),
        socketIdentity: HerdrSocketIdentityRecord(workspace.handshake.socketIdentity)
      )
    else {
      throw HerdrTopologyError.bindingLost
    }
    let layout: HerdrLayoutDescription
    let attribution: HerdrTopologyMutationAttribution
    switch stored.state {
    case .attributed:
      guard let storedAttribution = stored.attribution,
        storedAttribution.workspaceID == workspace.workspaceID,
        let tabID = storedAttribution.tabID
      else {
        throw HerdrTopologyError.mutationUnknown
      }
      layout = try await api.exportLayout(
        tabID: tabID,
        attestedBy: workspace.handshake
      )
      attribution = storedAttribution
    case .sendStarted:
      var candidates: [HerdrLayoutDescription] = []
      for tab in workspace.handshake.snapshot.tabs {
        guard
          let candidate = try? await api.exportLayout(
            tabID: tab.tabID,
            attestedBy: workspace.handshake
          ),
          Self.matchesRecovered(actual: candidate.root, expected: expectedRoot)
        else { continue }
        candidates.append(candidate)
      }
      guard candidates.count == 1, let candidate = candidates.first else {
        throw HerdrTopologyError.mutationUnknown
      }
      layout = candidate
      attribution = HerdrTopologyMutationAttribution(
        workspaceID: workspace.workspaceID,
        tabID: candidate.tabID,
        paneIDs: try Self.paneIDs(from: candidate.root)
      )
      try await intents.attribute(stored.receipt, as: attribution)
    case .prepared:
      throw HerdrTopologyError.bindingLost
    case .unknown:
      throw HerdrTopologyError.mutationUnknown
    }
    guard Self.matchesRecovered(actual: layout.root, expected: expectedRoot),
      attribution.tabID == layout.tabID,
      attribution.paneIDs == (try Self.paneIDs(from: layout.root)),
      workspace.handshake.snapshot.tabs.contains(where: {
        $0.tabID == layout.tabID && $0.workspaceID == layout.workspaceID
      })
    else {
      throw HerdrTopologyError.mutationUnknown
    }
    return try Self.binding(
      plan: plan,
      workspaceID: layout.workspaceID,
      layout: layout,
      snapshot: workspace.handshake.snapshot
    )
  }

  nonisolated static func mutationKey(
    for plan: HerdrTopologyPlan
  ) -> HerdrTopologyMutationKey {
    mutationKey(repositoryID: plan.repositoryID)
  }

  nonisolated static func mutationKey(
    repositoryID: String
  ) -> HerdrTopologyMutationKey {
    HerdrTopologyMutationKey(repositoryID: repositoryID)
  }

  func reconcile(
    binding: HerdrTopologyBinding,
    in snapshot: HerdrSessionSnapshot
  ) throws -> HerdrTopologyBinding {
    let rebound = try binding.roles.map { role -> HerdrRolePaneBinding in
      let candidates = snapshot.panes.filter {
        $0.terminalID == role.terminalID
          && $0.tokens?["managed_by"] == "jidoka"
          && $0.tokens?["run_id"] == role.runID
          && $0.tokens?["launch_attempt_id"] == role.launchAttemptID
      }
      guard candidates.count == 1, let pane = candidates.first else {
        throw HerdrTopologyError.bindingLost
      }
      return HerdrRolePaneBinding(
        role: role.role,
        runID: role.runID,
        launchAttemptID: role.launchAttemptID,
        workspaceID: pane.workspaceID,
        tabID: pane.tabID,
        paneID: pane.paneID,
        terminalID: pane.terminalID
      )
    }
    return HerdrTopologyBinding(
      repositoryID: binding.repositoryID,
      workspaceID: binding.workspaceID,
      tabID: binding.tabID,
      generation: binding.generation,
      roles: rebound
    )
  }

  private func resolveWorkspace(
    for plan: HerdrWorkspacePlan,
    jobID: String,
    generation: Int,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrWorkspaceBinding {
    if let boundWorkspaceID = plan.boundWorkspaceID {
      guard
        let workspace = handshake.snapshot.workspaces.first(where: {
          $0.workspaceID == boundWorkspaceID
        }),
        Self.matchesRepository(
          workspace: workspace,
          snapshot: handshake.snapshot,
          repositoryRoot: plan.repositoryRoot
        )
      else {
        throw HerdrTopologyError.workspaceIdentityMismatch
      }
      return HerdrWorkspaceBinding(workspaceID: workspace.workspaceID, handshake: handshake)
    }

    let candidates = handshake.snapshot.workspaces.filter {
      $0.label == plan.workspaceLabel
        && Self.matchesRepository(
          workspace: $0,
          snapshot: handshake.snapshot,
          repositoryRoot: plan.repositoryRoot
        )
    }
    if candidates.count == 1, let workspace = candidates.first {
      let parameters = HerdrWorkspaceCreateParameters(
        label: plan.workspaceLabel,
        cwd: plan.repositoryRoot.path,
        env: [:],
        focus: false
      )
      if let stored = try await intents.storedIntent(
        kind: .createWorkspace,
        repositoryID: plan.repositoryID,
        jobID: jobID,
        generation: generation,
        payloadSHA256: try Self.digest(parameters),
        socketIdentity: HerdrSocketIdentityRecord(handshake.socketIdentity)
      ) {
        let attribution = HerdrTopologyMutationAttribution(
          workspaceID: workspace.workspaceID,
          tabID: nil,
          paneIDs: []
        )
        switch stored.state {
        case .sendStarted:
          try await intents.attribute(stored.receipt, as: attribution)
        case .attributed:
          guard stored.attribution?.workspaceID == workspace.workspaceID else {
            throw HerdrTopologyError.mutationUnknown
          }
        case .prepared, .unknown:
          throw HerdrTopologyError.mutationUnknown
        }
      }
      return HerdrWorkspaceBinding(workspaceID: workspace.workspaceID, handshake: handshake)
    }
    guard candidates.isEmpty else { throw HerdrTopologyError.ambiguousWorkspace }
    return try await createWorkspace(
      for: plan,
      jobID: jobID,
      generation: generation,
      handshake: handshake,
      baselineFocus: baselineFocus
    )
  }

  private func createWorkspace(
    for plan: HerdrWorkspacePlan,
    jobID: String,
    generation: Int,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrWorkspaceBinding {
    let parameters = HerdrWorkspaceCreateParameters(
      label: plan.workspaceLabel,
      cwd: plan.repositoryRoot.path,
      env: [:],
      focus: false
    )
    let stored = try await prepareIntent(
      kind: .createWorkspace,
      plan: plan,
      jobID: jobID,
      generation: generation,
      payload: parameters,
      handshake: handshake
    )
    let receipt = stored.receipt
    let previousIDs = Set(handshake.snapshot.workspaces.map(\.workspaceID))
    let maySend: Bool
    switch stored.state {
    case .prepared:
      try await intents.markSendStarted(receipt)
      maySend = true
    case .sendStarted:
      maySend = false
    case .attributed, .unknown:
      throw HerdrTopologyError.mutationUnknown
    }

    let directResult: HerdrWorkspaceCreatedResult?
    if maySend {
      do {
        let result = try await api.createWorkspace(parameters, attestedBy: handshake)
        guard result.workspace.label == plan.workspaceLabel,
          result.tab.workspaceID == result.workspace.workspaceID,
          result.rootPane.workspaceID == result.workspace.workspaceID,
          result.rootPane.tabID == result.tab.tabID,
          result.rootPane.cwd == plan.repositoryRoot.path
        else {
          throw HerdrTopologyError.invalidResponse
        }
        directResult = result
      } catch {
        directResult = nil
      }
    } else {
      directResult = nil
    }

    if let result = directResult {
      try await intents.attribute(
        receipt,
        as: HerdrTopologyMutationAttribution(
          workspaceID: result.workspace.workspaceID,
          tabID: result.tab.tabID,
          paneIDs: [result.rootPane.paneID]
        )
      )
      let post = try await compatibleHandshake(after: handshake)
      guard HerdrTopologyFocus(snapshot: post.snapshot) == baselineFocus,
        post.snapshot.workspaces.contains(where: {
          $0.workspaceID == result.workspace.workspaceID
            && Self.matchesRepository(
              workspace: $0,
              snapshot: post.snapshot,
              repositoryRoot: plan.repositoryRoot
            )
        })
      else {
        throw HerdrTopologyError.focusChanged
      }
      return HerdrWorkspaceBinding(workspaceID: result.workspace.workspaceID, handshake: post)
    }

    if let recovered = try? await recoverWorkspace(
      for: plan,
      previousIDs: previousIDs,
      handshake: handshake,
      baselineFocus: baselineFocus
    ) {
      try await intents.attribute(
        receipt,
        as: HerdrTopologyMutationAttribution(
          workspaceID: recovered.workspaceID,
          tabID: nil,
          paneIDs: []
        )
      )
      return recovered
    }
    try await intents.markUnknown(receipt)
    throw HerdrTopologyError.mutationUnknown
  }

  private func recoverWorkspace(
    for plan: HerdrWorkspacePlan,
    previousIDs: Set<String>,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrWorkspaceBinding {
    let post = try await compatibleHandshake(after: handshake)
    guard HerdrTopologyFocus(snapshot: post.snapshot) == baselineFocus else {
      throw HerdrTopologyError.focusChanged
    }
    let candidates = post.snapshot.workspaces.filter {
      !previousIDs.contains($0.workspaceID)
        && $0.label == plan.workspaceLabel
        && Self.matchesRepository(
          workspace: $0,
          snapshot: post.snapshot,
          repositoryRoot: plan.repositoryRoot
        )
    }
    guard candidates.count == 1, let workspace = candidates.first else {
      throw HerdrTopologyError.mutationUnknown
    }
    return HerdrWorkspaceBinding(workspaceID: workspace.workspaceID, handshake: post)
  }

  private func createJobTabIfAbsent(
    for plan: HerdrTopologyPlan,
    workspace: HerdrWorkspaceBinding,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrTopologyBinding {
    let candidates = workspace.handshake.snapshot.tabs.filter {
      $0.workspaceID == workspace.workspaceID && $0.label == plan.tabLabel
    }
    guard candidates.count <= 1 else { throw HerdrTopologyError.tabAlreadyExists }
    guard let tab = candidates.first else {
      return try await createJobTab(
        for: plan,
        workspace: workspace,
        baselineFocus: baselineFocus
      )
    }
    let expectedRoot = Self.layout(for: plan.launches)
    let parameters = HerdrLayoutApplyParameters(
      workspaceID: workspace.workspaceID,
      tabLabel: plan.tabLabel,
      focus: false,
      root: expectedRoot
    )
    let payloadSHA256 = try Self.digest(parameters)
    guard
      let stored = try await intents.storedIntent(
        kind: .applyLayout,
        repositoryID: plan.repositoryID,
        jobID: plan.jobID,
        generation: plan.generation,
        payloadSHA256: payloadSHA256,
        socketIdentity: HerdrSocketIdentityRecord(workspace.handshake.socketIdentity)
      )
    else {
      throw HerdrTopologyError.tabAlreadyExists
    }
    let layout = try await api.exportLayout(
      tabID: tab.tabID,
      attestedBy: workspace.handshake
    )
    guard layout.workspaceID == workspace.workspaceID,
      Self.matches(actual: layout.root, expected: expectedRoot),
      HerdrTopologyFocus(snapshot: workspace.handshake.snapshot) == baselineFocus
    else {
      throw HerdrTopologyError.mutationUnknown
    }
    let attribution = HerdrTopologyMutationAttribution(
      workspaceID: workspace.workspaceID,
      tabID: tab.tabID,
      paneIDs: try Self.paneIDs(from: layout.root)
    )
    switch stored.state {
    case .sendStarted:
      try await intents.attribute(stored.receipt, as: attribution)
    case .attributed:
      guard stored.attribution == attribution else {
        throw HerdrTopologyError.mutationUnknown
      }
    case .prepared, .unknown:
      throw HerdrTopologyError.mutationUnknown
    }
    return try Self.binding(
      plan: plan,
      workspaceID: workspace.workspaceID,
      layout: layout,
      snapshot: workspace.handshake.snapshot
    )
  }

  private func createJobTab(
    for plan: HerdrTopologyPlan,
    workspace: HerdrWorkspaceBinding,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrTopologyBinding {
    let expectedRoot = Self.layout(for: plan.launches)
    let parameters = HerdrLayoutApplyParameters(
      workspaceID: workspace.workspaceID,
      tabLabel: plan.tabLabel,
      focus: false,
      root: expectedRoot
    )
    let stored = try await prepareIntent(
      kind: .applyLayout,
      plan: plan,
      payload: parameters,
      handshake: workspace.handshake
    )
    let receipt = stored.receipt
    let previousTabIDs = Set(workspace.handshake.snapshot.tabs.map(\.tabID))
    let maySend: Bool
    switch stored.state {
    case .prepared:
      try await intents.markSendStarted(receipt)
      maySend = true
    case .sendStarted:
      maySend = false
    case .attributed, .unknown:
      throw HerdrTopologyError.mutationUnknown
    }

    let directLayout: HerdrLayoutDescription?
    if maySend {
      do {
        let result = try await api.applyLayout(parameters, attestedBy: workspace.handshake)
        guard result.layout.workspaceID == workspace.workspaceID,
          Self.matches(actual: result.layout.root, expected: expectedRoot)
        else {
          throw HerdrTopologyError.invalidResponse
        }
        directLayout = result.layout
      } catch {
        directLayout = nil
      }
    } else {
      directLayout = nil
    }

    let layout: HerdrLayoutDescription
    let post: HerdrHandshake
    if let directLayout {
      try await intents.attribute(
        receipt,
        as: HerdrTopologyMutationAttribution(
          workspaceID: workspace.workspaceID,
          tabID: directLayout.tabID,
          paneIDs: try Self.paneIDs(from: directLayout.root)
        )
      )
      layout = directLayout
      post = try await compatibleHandshake(after: workspace.handshake)
    } else {
      let recovered: (layout: HerdrLayoutDescription, handshake: HerdrHandshake)
      do {
        recovered = try await recoverLayout(
          for: plan,
          workspaceID: workspace.workspaceID,
          previousTabIDs: previousTabIDs,
          expectedRoot: expectedRoot,
          handshake: workspace.handshake,
          baselineFocus: baselineFocus
        )
      } catch {
        try await intents.markUnknown(receipt)
        throw HerdrTopologyError.mutationUnknown
      }
      layout = recovered.layout
      post = recovered.handshake
      try await intents.attribute(
        receipt,
        as: HerdrTopologyMutationAttribution(
          workspaceID: workspace.workspaceID,
          tabID: layout.tabID,
          paneIDs: try Self.paneIDs(from: layout.root)
        )
      )
    }

    guard HerdrTopologyFocus(snapshot: post.snapshot) == baselineFocus,
      post.snapshot.tabs.contains(where: {
        $0.tabID == layout.tabID
          && $0.workspaceID == workspace.workspaceID
          && $0.label == plan.tabLabel
      })
    else {
      throw HerdrTopologyError.focusChanged
    }
    return try Self.binding(
      plan: plan,
      workspaceID: workspace.workspaceID,
      layout: layout,
      snapshot: post.snapshot
    )
  }

  private func recoverLayout(
    for plan: HerdrTopologyPlan,
    workspaceID: String,
    previousTabIDs: Set<String>,
    expectedRoot: HerdrLayoutNode,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> (layout: HerdrLayoutDescription, handshake: HerdrHandshake) {
    let post = try await compatibleHandshake(after: handshake)
    guard HerdrTopologyFocus(snapshot: post.snapshot) == baselineFocus else {
      throw HerdrTopologyError.focusChanged
    }
    let candidates = post.snapshot.tabs.filter {
      $0.workspaceID == workspaceID
        && $0.label == plan.tabLabel
        && !previousTabIDs.contains($0.tabID)
    }
    guard candidates.count == 1, let tab = candidates.first else {
      throw HerdrTopologyError.mutationUnknown
    }
    let layout = try await api.exportLayout(tabID: tab.tabID, attestedBy: post)
    guard layout.workspaceID == workspaceID,
      Self.matches(actual: layout.root, expected: expectedRoot)
    else {
      throw HerdrTopologyError.mutationUnknown
    }
    return (layout, post)
  }

  private func compatibleHandshake(after previous: HerdrHandshake) async throws
    -> HerdrHandshake
  {
    let current = try await api.handshake()
    guard current.socketIdentity == previous.socketIdentity else {
      throw HerdrTopologyError.incompatibleSocket
    }
    return current
  }

  private func prepareIntent<Payload: Encodable & Sendable>(
    kind: HerdrTopologyMutationIntent.Kind,
    plan: HerdrTopologyPlan,
    payload: Payload,
    handshake: HerdrHandshake
  ) async throws -> HerdrTopologyStoredIntent {
    try await prepareIntent(
      kind: kind,
      repositoryID: plan.repositoryID,
      jobID: plan.jobID,
      generation: plan.generation,
      payload: payload,
      handshake: handshake
    )
  }

  private func prepareIntent<Payload: Encodable & Sendable>(
    kind: HerdrTopologyMutationIntent.Kind,
    plan: HerdrWorkspacePlan,
    jobID: String,
    generation: Int,
    payload: Payload,
    handshake: HerdrHandshake
  ) async throws -> HerdrTopologyStoredIntent {
    try await prepareIntent(
      kind: kind,
      repositoryID: plan.repositoryID,
      jobID: jobID,
      generation: generation,
      payload: payload,
      handshake: handshake
    )
  }

  private func prepareIntent<Payload: Encodable & Sendable>(
    kind: HerdrTopologyMutationIntent.Kind,
    repositoryID: String,
    jobID: String,
    generation: Int,
    payload: Payload,
    handshake: HerdrHandshake
  ) async throws -> HerdrTopologyStoredIntent {
    let payloadSHA256 = try Self.digest(payload)
    if let existing = try await intents.storedIntent(
      kind: kind,
      repositoryID: repositoryID,
      jobID: jobID,
      generation: generation,
      payloadSHA256: payloadSHA256,
      socketIdentity: HerdrSocketIdentityRecord(handshake.socketIdentity)
    ) {
      return existing
    }
    let id = mutationID()
    guard id.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil else {
      throw HerdrTopologyError.invalidPlan
    }
    let intent = HerdrTopologyMutationIntent(
      mutationID: id,
      kind: kind,
      repositoryID: repositoryID,
      jobID: jobID,
      generation: generation,
      payloadSHA256: payloadSHA256,
      socketIdentity: HerdrSocketIdentityRecord(handshake.socketIdentity)
    )
    return HerdrTopologyStoredIntent(
      receipt: try await intents.prepare(intent),
      state: .prepared,
      attribution: nil
    )
  }

  private static func digest<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(value))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func matchesRepository(
    workspace: HerdrWorkspaceSnapshot,
    snapshot: HerdrSessionSnapshot,
    repositoryRoot: URL
  ) -> Bool {
    if workspace.worktree?.checkoutPath == repositoryRoot.path
      || workspace.worktree?.repositoryRoot == repositoryRoot.path
    {
      return true
    }
    return snapshot.panes.contains {
      $0.workspaceID == workspace.workspaceID && $0.cwd == repositoryRoot.path
    }
  }

  private static func layout(for launches: [HerdrHostLaunchPlan]) -> HerdrLayoutNode {
    func build(_ slice: ArraySlice<HerdrHostLaunchPlan>, depth: Int) -> HerdrLayoutNode {
      if let launch = slice.first, slice.count == 1 {
        return .pane(
          HerdrLayoutPane(
            label: launch.paneLabel,
            workingDirectory: launch.workingDirectory.path,
            command: launch.command,
            environment: launch.environment
          )
        )
      }
      let middle = slice.index(slice.startIndex, offsetBy: slice.count / 2)
      let first = slice[..<middle]
      let second = slice[middle...]
      return .split(
        HerdrLayoutSplit(
          direction: depth.isMultiple(of: 2) ? .right : .down,
          ratio: Double(first.count) / Double(slice.count),
          first: build(first, depth: depth + 1),
          second: build(second, depth: depth + 1)
        )
      )
    }
    return build(launches[...], depth: 0)
  }

  private static func matches(actual: HerdrLayoutNode, expected: HerdrLayoutNode) -> Bool {
    switch (actual, expected) {
    case (.pane(let actualPane), .pane(let expectedPane)):
      return actualPane.paneID != nil
        && actualPane.label == expectedPane.label
        && actualPane.workingDirectory == expectedPane.workingDirectory
        && actualPane.command == expectedPane.command
        && actualPane.environment == expectedPane.environment
    case (.split(let actualSplit), .split(let expectedSplit)):
      return actualSplit.direction == expectedSplit.direction
        && abs(actualSplit.ratio - expectedSplit.ratio) < 0.000_001
        && matches(actual: actualSplit.first, expected: expectedSplit.first)
        && matches(actual: actualSplit.second, expected: expectedSplit.second)
    default:
      return false
    }
  }

  private static func matchesRecovered(
    actual: HerdrLayoutNode,
    expected: HerdrLayoutNode
  ) -> Bool {
    switch (actual, expected) {
    case (.pane(let actualPane), .pane(let expectedPane)):
      return actualPane.paneID != nil
        && actualPane.workingDirectory == expectedPane.workingDirectory
        && actualPane.command == expectedPane.command
        && actualPane.environment == expectedPane.environment
    case (.split(let actualSplit), .split(let expectedSplit)):
      return actualSplit.direction == expectedSplit.direction
        && abs(actualSplit.ratio - expectedSplit.ratio) < 0.000_001
        && matchesRecovered(actual: actualSplit.first, expected: expectedSplit.first)
        && matchesRecovered(actual: actualSplit.second, expected: expectedSplit.second)
    default:
      return false
    }
  }

  private static func paneIDs(from root: HerdrLayoutNode) throws -> [String] {
    switch root {
    case .pane(let pane):
      guard let paneID = pane.paneID else { throw HerdrTopologyError.invalidResponse }
      return [paneID]
    case .split(let split):
      let values = try paneIDs(from: split.first) + paneIDs(from: split.second)
      guard Set(values).count == values.count else {
        throw HerdrTopologyError.invalidResponse
      }
      return values
    }
  }

  private static func binding(
    plan: HerdrTopologyPlan,
    workspaceID: String,
    layout: HerdrLayoutDescription,
    snapshot: HerdrSessionSnapshot
  ) throws -> HerdrTopologyBinding {
    let paneIDs = try paneIDs(from: layout.root)
    guard paneIDs.count == plan.launches.count else {
      throw HerdrTopologyError.invalidResponse
    }
    let roles = try zip(plan.launches, paneIDs).map { launch, paneID in
      let candidates = snapshot.panes.filter {
        $0.paneID == paneID
          && $0.workspaceID == workspaceID
          && $0.tabID == layout.tabID
      }
      guard candidates.count == 1, let pane = candidates.first else {
        throw HerdrTopologyError.invalidResponse
      }
      return HerdrRolePaneBinding(
        role: launch.role,
        runID: launch.runID,
        launchAttemptID: launch.launchAttemptID,
        workspaceID: pane.workspaceID,
        tabID: pane.tabID,
        paneID: pane.paneID,
        terminalID: pane.terminalID
      )
    }
    return HerdrTopologyBinding(
      repositoryID: plan.repositoryID,
      workspaceID: workspaceID,
      tabID: layout.tabID,
      generation: plan.generation,
      roles: roles
    )
  }

  private static func workspacePlan(
    _ plan: HerdrTopologyPlan
  ) throws -> HerdrWorkspacePlan {
    try HerdrWorkspacePlan(
      repositoryID: plan.repositoryID,
      repositoryRoot: plan.repositoryRoot,
      workspaceLabel: plan.workspaceLabel,
      boundWorkspaceID: plan.boundWorkspaceID
    )
  }

  private static func validateFilesystem(_ plan: HerdrWorkspacePlan) throws {
    var repository = stat()
    guard lstat(plan.repositoryRoot.path, &repository) == 0,
      repository.st_mode & S_IFMT == S_IFDIR
    else {
      throw HerdrTopologyError.invalidPlan
    }
  }

  private static func validateFilesystem(_ plan: HerdrTopologyPlan) throws {
    try validateFilesystem(workspacePlan(plan))
    for launch in plan.launches {
      var executable = stat()
      var descriptorRoot = stat()
      var workingDirectory = stat()
      guard lstat(launch.hostExecutable.path, &executable) == 0,
        executable.st_mode & S_IFMT == S_IFREG,
        executable.st_mode & 0o111 != 0,
        lstat(launch.descriptorRoot.path, &descriptorRoot) == 0,
        descriptorRoot.st_mode & S_IFMT == S_IFDIR,
        descriptorRoot.st_uid == geteuid(),
        descriptorRoot.st_mode & 0o077 == 0,
        lstat(launch.workingDirectory.path, &workingDirectory) == 0,
        workingDirectory.st_mode & S_IFMT == S_IFDIR,
        workingDirectory.st_uid == geteuid()
      else {
        throw HerdrTopologyError.invalidPlan
      }
    }
  }
}
