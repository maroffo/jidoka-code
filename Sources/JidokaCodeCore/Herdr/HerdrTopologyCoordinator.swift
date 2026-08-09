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

actor HerdrTopologyMutationGate {
  // The engine is single-instance, so a process-wide gate excludes competing coordinators.
  // The intent store remains the recovery authority across process restarts.
  static let shared = HerdrTopologyMutationGate()

  private var active: [HerdrTopologyMutationKey: UUID] = [:]

  func acquire(key: HerdrTopologyMutationKey) throws -> HerdrTopologyMutationLease {
    guard active[key] == nil else { throw HerdrTopologyError.concurrentMutation }
    let lease = HerdrTopologyMutationLease(key: key, token: UUID())
    active[key] = lease.token
    return lease
  }

  func release(_ lease: HerdrTopologyMutationLease) {
    guard active[lease.key] == lease.token else { return }
    active.removeValue(forKey: lease.key)
  }
}

actor HerdrTopologyCoordinator {
  private struct WorkspaceResolution: Sendable {
    let workspaceID: String
    let handshake: HerdrHandshake
  }

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
    let lease = try await gate.acquire(key: Self.mutationKey(for: plan))
    do {
      let result = try await ensureTopologyWhileHoldingLease(for: plan)
      await gate.release(lease)
      return result
    } catch {
      await gate.release(lease)
      throw error
    }
  }

  private func ensureTopologyWhileHoldingLease(
    for plan: HerdrTopologyPlan
  ) async throws -> HerdrTopologyBinding {
    let initial = try await api.handshake()
    let baselineFocus = HerdrTopologyFocus(snapshot: initial.snapshot)
    let workspace = try await resolveWorkspace(
      for: plan,
      handshake: initial,
      baselineFocus: baselineFocus
    )
    guard
      !workspace.handshake.snapshot.tabs.contains(where: {
        $0.workspaceID == workspace.workspaceID && $0.label == plan.tabLabel
      })
    else {
      throw HerdrTopologyError.tabAlreadyExists
    }
    return try await createJobTab(
      for: plan,
      workspace: workspace,
      baselineFocus: baselineFocus
    )
  }

  nonisolated static func mutationKey(
    for plan: HerdrTopologyPlan
  ) -> HerdrTopologyMutationKey {
    HerdrTopologyMutationKey(repositoryID: plan.repositoryID)
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
    for plan: HerdrTopologyPlan,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> WorkspaceResolution {
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
      return WorkspaceResolution(workspaceID: workspace.workspaceID, handshake: handshake)
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
      return WorkspaceResolution(workspaceID: workspace.workspaceID, handshake: handshake)
    }
    guard candidates.isEmpty else { throw HerdrTopologyError.ambiguousWorkspace }
    return try await createWorkspace(
      for: plan,
      handshake: handshake,
      baselineFocus: baselineFocus
    )
  }

  private func createWorkspace(
    for plan: HerdrTopologyPlan,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> WorkspaceResolution {
    let parameters = HerdrWorkspaceCreateParameters(
      label: plan.workspaceLabel,
      cwd: plan.repositoryRoot.path,
      env: [:],
      focus: false
    )
    let receipt = try await prepareIntent(
      kind: .createWorkspace,
      plan: plan,
      payload: parameters,
      handshake: handshake
    )
    let previousIDs = Set(handshake.snapshot.workspaces.map(\.workspaceID))
    try await intents.markSendStarted(receipt)

    let directResult: HerdrWorkspaceCreatedResult?
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
      return WorkspaceResolution(workspaceID: result.workspace.workspaceID, handshake: post)
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
    for plan: HerdrTopologyPlan,
    previousIDs: Set<String>,
    handshake: HerdrHandshake,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> WorkspaceResolution {
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
    return WorkspaceResolution(workspaceID: workspace.workspaceID, handshake: post)
  }

  private func createJobTab(
    for plan: HerdrTopologyPlan,
    workspace: WorkspaceResolution,
    baselineFocus: HerdrTopologyFocus
  ) async throws -> HerdrTopologyBinding {
    let expectedRoot = Self.layout(for: plan.launches)
    let parameters = HerdrLayoutApplyParameters(
      workspaceID: workspace.workspaceID,
      tabLabel: plan.tabLabel,
      focus: false,
      root: expectedRoot
    )
    let receipt = try await prepareIntent(
      kind: .applyLayout,
      plan: plan,
      payload: parameters,
      handshake: workspace.handshake
    )
    let previousTabIDs = Set(workspace.handshake.snapshot.tabs.map(\.tabID))
    try await intents.markSendStarted(receipt)

    let directLayout: HerdrLayoutDescription?
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
  ) async throws -> HerdrTopologyMutationReceipt {
    let id = mutationID()
    guard id.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil else {
      throw HerdrTopologyError.invalidPlan
    }
    let intent = HerdrTopologyMutationIntent(
      mutationID: id,
      kind: kind,
      repositoryID: plan.repositoryID,
      jobID: plan.jobID,
      generation: plan.generation,
      payloadSHA256: try Self.digest(payload),
      socketIdentity: HerdrSocketIdentityRecord(handshake.socketIdentity)
    )
    return try await intents.prepare(intent)
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

  private static func validateFilesystem(_ plan: HerdrTopologyPlan) throws {
    var repository = stat()
    guard lstat(plan.repositoryRoot.path, &repository) == 0,
      repository.st_mode & S_IFMT == S_IFDIR
    else {
      throw HerdrTopologyError.invalidPlan
    }
    for launch in plan.launches {
      var executable = stat()
      var descriptorRoot = stat()
      guard lstat(launch.hostExecutable.path, &executable) == 0,
        executable.st_mode & S_IFMT == S_IFREG,
        executable.st_mode & 0o111 != 0,
        lstat(launch.descriptorRoot.path, &descriptorRoot) == 0,
        descriptorRoot.st_mode & S_IFMT == S_IFDIR,
        descriptorRoot.st_uid == geteuid(),
        descriptorRoot.st_mode & 0o077 == 0
      else {
        throw HerdrTopologyError.invalidPlan
      }
    }
  }
}
