import CryptoKit
import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Herdr prepared topology and exact recovery", .serialized)
struct HerdrTopologyTests {
  @Test("pause gate waits for admitted mutations and rejects every later send")
  func pauseMutationBarrier() async throws {
    let gate = HerdrTopologyMutationGate(initiallyAllowed: true)
    let lease = try await gate.acquire(
      key: HerdrTopologyMutationKey(repositoryID: "repository-pause")
    )
    let closed = AsyncFlag()
    let closeTask = Task {
      await gate.closeAndWait()
      await closed.set()
    }
    await Task.yield()
    #expect(!(await closed.value()))
    await gate.release(lease)
    await closeTask.value
    #expect(await closed.value())
    await #expect(throws: HerdrTopologyMutationGateError.closed) {
      _ = try await gate.acquire(
        key: HerdrTopologyMutationKey(repositoryID: "repository-late")
      )
    }
    await gate.open()
    let resumed = try await gate.acquire(
      key: HerdrTopologyMutationKey(repositoryID: "repository-resumed")
    )
    await gate.release(resumed)
  }

  @Test("role-host publication leases serialize without bypassing pause closure")
  func serializedPublicationLease() async throws {
    let gate = HerdrTopologyMutationGate(initiallyAllowed: true)
    let key = HerdrTopologyMutationKey(repositoryID: "queue:rolehost-00000001")
    let first = try await gate.acquireSerially(key: key)
    let secondAcquired = AsyncFlag()
    let secondTask = Task {
      let second = try await gate.acquireSerially(key: key)
      await secondAcquired.set()
      return second
    }
    await Task.yield()
    #expect(!(await secondAcquired.value()))
    await gate.release(first)
    let second = try await secondTask.value
    #expect(await secondAcquired.value())
    await gate.release(second)
  }

  @Test("one repository topology mutation is active across jobs and generations")
  func repositoryMutationSerialization() async throws {
    let fixture = try HerdrTopologyFixture()
    let firstPlan = try fixture.plan(jobID: "job-0001", generation: 1)
    let secondPlan = try fixture.plan(jobID: "job-0002", generation: 2)
    let firstKey = HerdrTopologyCoordinator.mutationKey(for: firstPlan)
    let secondKey = HerdrTopologyCoordinator.mutationKey(for: secondPlan)
    #expect(firstKey == secondKey)

    let gate = HerdrTopologyMutationGate()
    let first = try await gate.acquire(key: firstKey)
    await #expect(throws: HerdrTopologyError.concurrentMutation) {
      _ = try await gate.acquire(key: secondKey)
    }
    await gate.release(first)
  }

  @Test("retry keeps logical run identity and changes only launch-attempt argv")
  func launchAttemptIdentity() throws {
    let fixture = try HerdrTopologyFixture()
    let first = try fixture.plan(launchAttempt: 1)
    let retry = try fixture.plan(launchAttempt: 2)

    #expect(first.launches.map(\.runID) == retry.launches.map(\.runID))
    #expect(first.launches.map(\.launchAttemptID) != retry.launches.map(\.launchAttemptID))
    #expect(
      first.launches[0].command
        == [fixture.hostExecutable.path, "--launch-attempt-id", "attempt-plan-0001"]
    )
    #expect(
      retry.launches[0].command
        == [fixture.hostExecutable.path, "--launch-attempt-id", "attempt-plan-0002"]
    )
  }

  @Test("an exact repository workspace is adopted and layout is prepared before send")
  func exactWorkspaceAdoption() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let initial = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let applied = fixture.appliedLayout()
    let post = fixture.handshake(snapshot: fixture.jobSnapshot(layout: applied))
    let recorder = HerdrTopologyOperationRecorder()
    let api = HerdrFakeTopologyAPI(
      handshakes: [initial, post],
      layoutResult: HerdrLayoutApplyResult(type: "layout_apply", layout: applied),
      recorder: recorder
    )
    let store = HerdrFakeTopologyIntentStore(recorder: recorder)
    let coordinator = HerdrTopologyCoordinator(
      api: api,
      intents: store,
      mutationID: { "mutation-layout" }
    )

    let binding = try await coordinator.ensureTopology(for: plan)

    #expect(binding.workspaceID == "w-repo")
    #expect(binding.tabID == "w-repo:t2")
    #expect(binding.roles.map { $0.paneID } == ["w-repo:p2", "w-repo:p3"])
    #expect(
      recorder.snapshot() == [
        "handshake", "prepare:applyLayout", "sendStarted:applyLayout", "applyLayout",
        "attributed:applyLayout", "handshake",
      ]
    )
  }

  @Test("a lost layout response is attributed by snapshot and exact layout export without resend")
  func lostLayoutResponse() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let initial = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let applied = fixture.appliedLayout()
    let post = fixture.handshake(snapshot: fixture.jobSnapshot(layout: applied))
    let recorder = HerdrTopologyOperationRecorder()
    let api = HerdrFakeTopologyAPI(
      handshakes: [initial, post],
      layoutError: HerdrSocketClientError.connectionClosed,
      exportedLayout: applied,
      recorder: recorder
    )
    let store = HerdrFakeTopologyIntentStore(recorder: recorder)
    let coordinator = HerdrTopologyCoordinator(
      api: api,
      intents: store,
      mutationID: { "mutation-layout" }
    )

    let binding = try await coordinator.ensureTopology(for: plan)

    #expect(binding.tabID == "w-repo:t2")
    #expect(await api.applyCount() == 1)
    #expect(
      recorder.snapshot() == [
        "handshake", "prepare:applyLayout", "sendStarted:applyLayout", "applyLayout",
        "handshake", "exportLayout", "attributed:applyLayout",
      ]
    )
  }

  @Test("a helper crash after layout send is attributed by a fresh coordinator without resend")
  func helperCrashAfterLayoutSend() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let initial = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let applied = fixture.appliedLayout()
    let post = fixture.handshake(snapshot: fixture.jobSnapshot(layout: applied))
    let store = HerdrFakeTopologyIntentStore(failMarkUnknown: true)
    let firstAPI = HerdrFakeTopologyAPI(
      handshakes: [initial],
      layoutError: HerdrSocketClientError.connectionClosed
    )
    let first = HerdrTopologyCoordinator(
      api: firstAPI,
      intents: store,
      mutationID: { "mutation-layout-crash" }
    )
    await #expect(throws: HerdrTopologyError.invalidResponse) {
      _ = try await first.ensureTopology(for: plan)
    }
    #expect(await firstAPI.applyCount() == 1)

    let secondAPI = HerdrFakeTopologyAPI(
      handshakes: [post],
      exportedLayout: applied
    )
    let second = HerdrTopologyCoordinator(
      api: secondAPI,
      intents: store,
      mutationID: { "must-not-create-another-intent" }
    )
    let recovered = try await second.ensureTopology(for: plan)
    #expect(recovered.tabID == applied.tabID)
    #expect(await secondAPI.applyCount() == 0)
  }

  @Test("an unprovable lost layout response becomes unknown and never retries")
  func unknownLayoutResponse() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let initial = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let recorder = HerdrTopologyOperationRecorder()
    let api = HerdrFakeTopologyAPI(
      handshakes: [initial, initial],
      layoutError: HerdrSocketClientError.connectionClosed,
      recorder: recorder
    )
    let store = HerdrFakeTopologyIntentStore(recorder: recorder)
    let coordinator = HerdrTopologyCoordinator(
      api: api,
      intents: store,
      mutationID: { "mutation-layout" }
    )

    await #expect(throws: HerdrTopologyError.mutationUnknown) {
      _ = try await coordinator.ensureTopology(for: plan)
    }
    #expect(await api.applyCount() == 1)
    #expect(recorder.snapshot().last == "unknown:applyLayout")
  }

  @Test("a lost workspace response is attributed before the one layout create")
  func lostWorkspaceResponse() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let empty = fixture.handshake(snapshot: fixture.emptySnapshot())
    let repository = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let applied = fixture.appliedLayout()
    let post = fixture.handshake(snapshot: fixture.jobSnapshot(layout: applied))
    let recorder = HerdrTopologyOperationRecorder()
    let api = HerdrFakeTopologyAPI(
      handshakes: [empty, repository, post],
      workspaceError: HerdrSocketClientError.connectionClosed,
      layoutResult: HerdrLayoutApplyResult(type: "layout_apply", layout: applied),
      recorder: recorder
    )
    let store = HerdrFakeTopologyIntentStore(recorder: recorder)
    let mutationIDs = HerdrLockedSequence(["mutation-workspace", "mutation-layout"])
    let coordinator = HerdrTopologyCoordinator(
      api: api,
      intents: store,
      mutationID: { mutationIDs() }
    )

    let binding = try await coordinator.ensureTopology(for: plan)

    #expect(binding.workspaceID == "w-repo")
    #expect(await api.workspaceCreateCount() == 1)
    #expect(await api.applyCount() == 1)
    #expect(
      recorder.snapshot().prefix(6) == [
        "handshake", "prepare:createWorkspace", "sendStarted:createWorkspace",
        "createWorkspace", "handshake", "attributed:createWorkspace",
      ]
    )
  }

  @Test("workspace ambiguity existing generation and wrong durable binding fail before mutation")
  func topologyCollisionsFailClosed() async throws {
    let fixture = try HerdrTopologyFixture()
    let duplicateSnapshot = fixture.repositorySnapshot(duplicateWorkspace: true)
    let duplicateAPI = HerdrFakeTopologyAPI(
      handshakes: [fixture.handshake(snapshot: duplicateSnapshot)]
    )
    let duplicateCoordinator = HerdrTopologyCoordinator(
      api: duplicateAPI,
      intents: HerdrFakeTopologyIntentStore(),
      mutationID: { "unused-0001" }
    )
    await #expect(throws: HerdrTopologyError.ambiguousWorkspace) {
      _ = try await duplicateCoordinator.ensureTopology(for: fixture.plan())
    }
    #expect(await duplicateAPI.mutationCount() == 0)

    let wrongBindingAPI = HerdrFakeTopologyAPI(
      handshakes: [fixture.handshake(snapshot: fixture.repositorySnapshot())]
    )
    let wrongBindingCoordinator = HerdrTopologyCoordinator(
      api: wrongBindingAPI,
      intents: HerdrFakeTopologyIntentStore(),
      mutationID: { "unused-0002" }
    )
    await #expect(throws: HerdrTopologyError.workspaceIdentityMismatch) {
      _ = try await wrongBindingCoordinator.ensureTopology(
        for: fixture.plan(boundWorkspaceID: "w-missing")
      )
    }
    #expect(await wrongBindingAPI.mutationCount() == 0)

    let existingTabAPI = HerdrFakeTopologyAPI(
      handshakes: [
        fixture.handshake(snapshot: fixture.jobSnapshot(layout: fixture.appliedLayout()))
      ]
    )
    let existingTabCoordinator = HerdrTopologyCoordinator(
      api: existingTabAPI,
      intents: HerdrFakeTopologyIntentStore(),
      mutationID: { "unused-0003" }
    )
    await #expect(throws: HerdrTopologyError.tabAlreadyExists) {
      _ = try await existingTabCoordinator.ensureTopology(for: fixture.plan())
    }
    #expect(await existingTabAPI.mutationCount() == 0)
  }

  @Test("focus drift cannot erase an already attributed mutation")
  func focusDriftAfterAttribution() async throws {
    let fixture = try HerdrTopologyFixture()
    let plan = try fixture.plan()
    let initial = fixture.handshake(snapshot: fixture.repositorySnapshot())
    let applied = fixture.appliedLayout()
    let changedFocus = fixture.jobSnapshot(layout: applied, focusedPaneID: "w-repo:p2")
    let recorder = HerdrTopologyOperationRecorder()
    let api = HerdrFakeTopologyAPI(
      handshakes: [initial, fixture.handshake(snapshot: changedFocus)],
      layoutResult: HerdrLayoutApplyResult(type: "layout_apply", layout: applied),
      recorder: recorder
    )
    let coordinator = HerdrTopologyCoordinator(
      api: api,
      intents: HerdrFakeTopologyIntentStore(recorder: recorder),
      mutationID: { "mutation-layout" }
    )

    await #expect(throws: HerdrTopologyError.focusChanged) {
      _ = try await coordinator.ensureTopology(for: plan)
    }
    #expect(recorder.snapshot().contains("attributed:applyLayout"))
    #expect(!recorder.snapshot().contains("unknown:applyLayout"))
  }

  @Test("terminal identity follows a moved or renamed pane and close is interruption unknown")
  func moveRenameAndCloseReconciliation() async throws {
    let fixture = try HerdrTopologyFixture()
    let layout = fixture.appliedLayout()
    let snapshot = fixture.jobSnapshot(layout: layout)
    let binding = HerdrTopologyBinding(
      repositoryID: "repo-0001",
      workspaceID: "w-repo",
      tabID: "w-repo:t2",
      generation: 1,
      roles: [
        HerdrRolePaneBinding(
          role: "plan",
          runID: "run-0001",
          launchAttemptID: "attempt-plan-0001",
          workspaceID: "w-repo",
          tabID: "w-repo:t2",
          paneID: "old-pane",
          terminalID: "term-plan"
        ),
        HerdrRolePaneBinding(
          role: "review",
          runID: "run-0002",
          launchAttemptID: "attempt-review-0001",
          workspaceID: "w-repo",
          tabID: "w-repo:t2",
          paneID: "w-repo:p3",
          terminalID: "term-review"
        ),
      ]
    )
    let coordinator = HerdrTopologyCoordinator(
      api: HerdrFakeTopologyAPI(handshakes: []),
      intents: HerdrFakeTopologyIntentStore()
    )
    let movedPlan = fixture.pane(
      id: "w-other:p9",
      terminalID: "term-plan",
      workspaceID: "w-other",
      tabID: "w-other:t4",
      label: "renamed-by-user",
      runID: "run-0001",
      launchAttemptID: "attempt-plan-0001"
    )
    let review = fixture.pane(
      id: "w-repo:p3",
      terminalID: "term-review",
      workspaceID: "w-repo",
      tabID: "w-repo:t2",
      label: "also-renamed",
      runID: "run-0002",
      launchAttemptID: "attempt-review-0001"
    )
    let movedSnapshot = fixture.snapshot(panes: [movedPlan, review])

    let rebound = try await coordinator.reconcile(binding: binding, in: movedSnapshot)
    #expect(rebound.roles[0].paneID == "w-other:p9")
    #expect(rebound.roles[0].workspaceID == "w-other")
    #expect(rebound.roles[0].tabID == "w-other:t4")

    await #expect(throws: HerdrTopologyError.bindingLost) {
      _ = try await coordinator.reconcile(
        binding: binding,
        in: fixture.snapshot(panes: [review])
      )
    }
    _ = snapshot
  }
}

private final class HerdrTopologyFixture: @unchecked Sendable {
  let root: URL
  let repository: URL
  let descriptorRoot: URL
  let hostExecutable: URL

  init() throws {
    root = URL(
      fileURLWithPath: "/tmp/jht-\(UUID().uuidString.lowercased().prefix(8))",
      isDirectory: true
    )
    repository = root.appendingPathComponent("repository", isDirectory: true)
    descriptorRoot = root.appendingPathComponent("runs", isDirectory: true)
    hostExecutable = root.appendingPathComponent("JidokaCodeHerdrHost")
    try FileManager.default.createDirectory(
      at: repository,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
      at: descriptorRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(
      FileManager.default.createFile(
        atPath: hostExecutable.path,
        contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o700]
      )
    )
    #expect(Darwin.chmod(hostExecutable.path, 0o700) == 0)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func plan(
    boundWorkspaceID: String? = nil,
    jobID: String = "job-0001",
    generation: Int = 1,
    launchAttempt: Int = 1
  ) throws -> HerdrTopologyPlan {
    let launches = try [
      HerdrHostLaunchPlan(
        role: "plan",
        paneLabel: "plan",
        runID: "run-0001",
        launchAttemptID: String(format: "attempt-plan-%04d", launchAttempt),
        agentAlias: "jc-h2-g1-plan",
        hostExecutable: hostExecutable,
        descriptorRoot: descriptorRoot,
        workingDirectory: repository
      ),
      HerdrHostLaunchPlan(
        role: "review",
        paneLabel: "review",
        runID: "run-0002",
        launchAttemptID: String(format: "attempt-review-%04d", launchAttempt),
        agentAlias: "jc-h2-g1-review",
        hostExecutable: hostExecutable,
        descriptorRoot: descriptorRoot,
        workingDirectory: repository
      ),
    ]
    return try HerdrTopologyPlan(
      repositoryID: "repo-0001",
      repositoryRoot: repository,
      workspaceLabel: "maroffo/jidoka-code",
      boundWorkspaceID: boundWorkspaceID,
      jobID: jobID,
      generation: generation,
      tabLabel: "j/imp/i42/k7m2/g\(generation)",
      launches: launches
    )
  }

  func handshake(snapshot: HerdrSessionSnapshot) -> HerdrHandshake {
    HerdrHandshake(
      pong: HerdrPong(
        version: "0.8.2",
        protocolVersion: 20,
        capabilities: HerdrCapabilities(liveHandoff: true, detachedServerDaemon: true)
      ),
      snapshot: snapshot,
      socketIdentity: HerdrSocketIdentity(
        device: 1,
        inode: 2,
        owner: geteuid(),
        permissions: 0o600
      )
    )
  }

  func emptySnapshot() -> HerdrSessionSnapshot {
    snapshot(panes: [])
  }

  func repositorySnapshot(duplicateWorkspace: Bool = false) -> HerdrSessionSnapshot {
    var workspaces = [workspace(id: "w-repo")]
    var tabs = [tab(id: "w-repo:t1", workspaceID: "w-repo", label: "shell", paneCount: 1)]
    var panes = [
      pane(
        id: "w-repo:p1",
        terminalID: "term-root",
        workspaceID: "w-repo",
        tabID: "w-repo:t1",
        label: "shell"
      )
    ]
    if duplicateWorkspace {
      workspaces.append(workspace(id: "w-duplicate"))
      tabs.append(
        tab(id: "w-duplicate:t1", workspaceID: "w-duplicate", label: "shell", paneCount: 1)
      )
      panes.append(
        pane(
          id: "w-duplicate:p1",
          terminalID: "term-duplicate",
          workspaceID: "w-duplicate",
          tabID: "w-duplicate:t1",
          label: "shell"
        )
      )
    }
    return HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: workspaces,
      tabs: tabs,
      panes: panes,
      agents: []
    )
  }

  func jobSnapshot(
    layout: HerdrLayoutDescription,
    focusedPaneID: String? = nil
  ) -> HerdrSessionSnapshot {
    let root = pane(
      id: "w-repo:p1",
      terminalID: "term-root",
      workspaceID: "w-repo",
      tabID: "w-repo:t1",
      label: "shell"
    )
    let planPane = pane(
      id: "w-repo:p2",
      terminalID: "term-plan",
      workspaceID: "w-repo",
      tabID: layout.tabID,
      label: "plan",
      runID: "run-0001",
      launchAttemptID: "attempt-plan-0001"
    )
    let reviewPane = pane(
      id: "w-repo:p3",
      terminalID: "term-review",
      workspaceID: "w-repo",
      tabID: layout.tabID,
      label: "review",
      runID: "run-0002",
      launchAttemptID: "attempt-review-0001"
    )
    return HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: focusedPaneID == nil ? nil : "w-repo",
      focusedTabID: focusedPaneID == nil ? nil : layout.tabID,
      focusedPaneID: focusedPaneID,
      workspaces: [workspace(id: "w-repo", tabCount: 2, paneCount: 3)],
      tabs: [
        tab(id: "w-repo:t1", workspaceID: "w-repo", label: "shell", paneCount: 1),
        tab(
          id: layout.tabID,
          workspaceID: "w-repo",
          label: "j/imp/i42/k7m2/g1",
          paneCount: 2
        ),
      ],
      panes: [root, planPane, reviewPane],
      agents: []
    )
  }

  func appliedLayout() -> HerdrLayoutDescription {
    HerdrLayoutDescription(
      workspaceID: "w-repo",
      tabID: "w-repo:t2",
      zoomed: false,
      focusedPaneID: "w-repo:p2",
      root: .split(
        HerdrLayoutSplit(
          direction: .right,
          ratio: 0.5,
          first: .pane(
            HerdrLayoutPane(
              paneID: "w-repo:p2",
              label: "plan",
              workingDirectory: repository.path,
              command: [hostExecutable.path, "--launch-attempt-id", "attempt-plan-0001"],
              environment: ["JIDOKA_CODE_HERDR_RUN_ROOT": descriptorRoot.path]
            )
          ),
          second: .pane(
            HerdrLayoutPane(
              paneID: "w-repo:p3",
              label: "review",
              workingDirectory: repository.path,
              command: [hostExecutable.path, "--launch-attempt-id", "attempt-review-0001"],
              environment: ["JIDOKA_CODE_HERDR_RUN_ROOT": descriptorRoot.path]
            )
          )
        )
      )
    )
  }

  func snapshot(panes: [HerdrPaneSnapshot]) -> HerdrSessionSnapshot {
    HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: nil,
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: [],
      tabs: [],
      panes: panes,
      agents: []
    )
  }

  func workspace(
    id: String,
    tabCount: Int = 1,
    paneCount: Int = 1
  ) -> HerdrWorkspaceSnapshot {
    HerdrWorkspaceSnapshot(
      workspaceID: id,
      activeTabID: "\(id):t1",
      label: "maroffo/jidoka-code",
      number: 1,
      paneCount: paneCount,
      tabCount: tabCount,
      focused: false,
      agentStatus: .unknown,
      tokens: nil,
      worktree: nil
    )
  }

  func tab(
    id: String,
    workspaceID: String,
    label: String,
    paneCount: Int
  ) -> HerdrTabSnapshot {
    HerdrTabSnapshot(
      tabID: id,
      workspaceID: workspaceID,
      label: label,
      number: 1,
      paneCount: paneCount,
      focused: false,
      agentStatus: .unknown
    )
  }

  func pane(
    id: String,
    terminalID: String,
    workspaceID: String,
    tabID: String,
    label: String,
    runID: String? = nil,
    launchAttemptID: String? = nil
  ) -> HerdrPaneSnapshot {
    HerdrPaneSnapshot(
      paneID: id,
      terminalID: terminalID,
      workspaceID: workspaceID,
      tabID: tabID,
      revision: 1,
      focused: false,
      agentStatus: runID == nil ? .unknown : .working,
      cwd: repository.path,
      foregroundCWD: repository.path,
      label: label,
      agent: runID == nil ? nil : "pi",
      displayAgent: nil,
      title: nil,
      stateLabels: nil,
      tokens: runID.flatMap { runID in
        launchAttemptID.map {
          ["launch_attempt_id": $0, "managed_by": "jidoka", "run_id": runID]
        }
      },
      agentSession: nil
    )
  }
}

private actor HerdrFakeTopologyAPI: HerdrTopologyAPI {
  private var handshakes: [HerdrHandshake]
  private let workspaceResult: HerdrWorkspaceCreatedResult?
  private let workspaceError: (any Error & Sendable)?
  private let layoutResult: HerdrLayoutApplyResult?
  private let layoutError: (any Error & Sendable)?
  private let exportedLayout: HerdrLayoutDescription?
  private let recorder: HerdrTopologyOperationRecorder?
  private var workspaceCreates = 0
  private var layoutApplies = 0

  init(
    handshakes: [HerdrHandshake],
    workspaceResult: HerdrWorkspaceCreatedResult? = nil,
    workspaceError: (any Error & Sendable)? = nil,
    layoutResult: HerdrLayoutApplyResult? = nil,
    layoutError: (any Error & Sendable)? = nil,
    exportedLayout: HerdrLayoutDescription? = nil,
    recorder: HerdrTopologyOperationRecorder? = nil
  ) {
    self.handshakes = handshakes
    self.workspaceResult = workspaceResult
    self.workspaceError = workspaceError
    self.layoutResult = layoutResult
    self.layoutError = layoutError
    self.exportedLayout = exportedLayout
    self.recorder = recorder
  }

  func handshake() throws -> HerdrHandshake {
    recorder?.append("handshake")
    guard !handshakes.isEmpty else { throw HerdrTopologyError.invalidResponse }
    return handshakes.removeFirst()
  }

  func createWorkspace(
    _ parameters: HerdrWorkspaceCreateParameters,
    attestedBy handshake: HerdrHandshake
  ) throws -> HerdrWorkspaceCreatedResult {
    workspaceCreates += 1
    recorder?.append("createWorkspace")
    if let workspaceError { throw workspaceError }
    guard let workspaceResult else { throw HerdrTopologyError.invalidResponse }
    return workspaceResult
  }

  func applyLayout(
    _ parameters: HerdrLayoutApplyParameters,
    attestedBy handshake: HerdrHandshake
  ) throws -> HerdrLayoutApplyResult {
    layoutApplies += 1
    recorder?.append("applyLayout")
    if let layoutError { throw layoutError }
    guard let layoutResult else { throw HerdrTopologyError.invalidResponse }
    return layoutResult
  }

  func exportLayout(
    tabID: String,
    attestedBy handshake: HerdrHandshake
  ) throws -> HerdrLayoutDescription {
    recorder?.append("exportLayout")
    guard let exportedLayout, exportedLayout.tabID == tabID else {
      throw HerdrTopologyError.invalidResponse
    }
    return exportedLayout
  }

  func workspaceCreateCount() -> Int { workspaceCreates }
  func applyCount() -> Int { layoutApplies }
  func mutationCount() -> Int { workspaceCreates + layoutApplies }
}

private actor HerdrFakeTopologyIntentStore: HerdrTopologyIntentStoring {
  private enum Phase {
    case prepared
    case sendStarted
    case attributed
    case unknown
  }

  private var intents: [String: (HerdrTopologyMutationIntent, Phase)] = [:]
  private var attributions: [String: HerdrTopologyMutationAttribution] = [:]
  private let recorder: HerdrTopologyOperationRecorder?
  private let failMarkUnknown: Bool

  init(
    recorder: HerdrTopologyOperationRecorder? = nil,
    failMarkUnknown: Bool = false
  ) {
    self.recorder = recorder
    self.failMarkUnknown = failMarkUnknown
  }

  func prepare(_ intent: HerdrTopologyMutationIntent) throws -> HerdrTopologyMutationReceipt {
    guard intents[intent.mutationID] == nil else { throw HerdrTopologyError.invalidResponse }
    intents[intent.mutationID] = (intent, .prepared)
    recorder?.append("prepare:\(intent.kind.rawValue)")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(intent))
      .map { String(format: "%02x", $0) }
      .joined()
    return HerdrTopologyMutationReceipt(
      mutationID: intent.mutationID,
      intentSHA256: digest
    )
  }

  func markSendStarted(_ receipt: HerdrTopologyMutationReceipt) throws {
    let intent = try transition(receipt, from: .prepared, to: .sendStarted)
    recorder?.append("sendStarted:\(intent.kind.rawValue)")
  }

  func attribute(
    _ receipt: HerdrTopologyMutationReceipt,
    as attribution: HerdrTopologyMutationAttribution
  ) throws {
    let intent = try transition(receipt, from: .sendStarted, to: .attributed)
    attributions[receipt.mutationID] = attribution
    recorder?.append("attributed:\(intent.kind.rawValue)")
  }

  func markUnknown(_ receipt: HerdrTopologyMutationReceipt) throws {
    if failMarkUnknown { throw HerdrTopologyError.invalidResponse }
    let intent = try transition(receipt, from: .sendStarted, to: .unknown)
    recorder?.append("unknown:\(intent.kind.rawValue)")
  }

  func storedIntent(
    kind: HerdrTopologyMutationIntent.Kind,
    repositoryID: String,
    jobID: String,
    generation: Int,
    payloadSHA256: String,
    socketIdentity: HerdrSocketIdentityRecord
  ) throws -> HerdrTopologyStoredIntent? {
    let matches = intents.filter { _, value in
      let intent = value.0
      return intent.kind == kind && intent.repositoryID == repositoryID
        && intent.jobID == jobID && intent.generation == generation
        && intent.payloadSHA256 == payloadSHA256
        && intent.socketIdentity == socketIdentity
    }
    guard matches.count <= 1, let (id, value) = matches.first else {
      if matches.isEmpty { return nil }
      throw HerdrTopologyError.invalidResponse
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(value.0))
      .map { String(format: "%02x", $0) }
      .joined()
    let state: HerdrTopologyStoredIntentState =
      switch value.1 {
      case .prepared: .prepared
      case .sendStarted: .sendStarted
      case .attributed: .attributed
      case .unknown: .unknown
      }
    return HerdrTopologyStoredIntent(
      receipt: HerdrTopologyMutationReceipt(mutationID: id, intentSHA256: digest),
      state: state,
      attribution: attributions[id]
    )
  }

  private func transition(
    _ receipt: HerdrTopologyMutationReceipt,
    from expected: Phase,
    to next: Phase
  ) throws -> HerdrTopologyMutationIntent {
    guard let current = intents[receipt.mutationID], current.1 == expected else {
      throw HerdrTopologyError.invalidResponse
    }
    intents[receipt.mutationID] = (current.0, next)
    return current.0
  }
}

private final class HerdrTopologyOperationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private actor AsyncFlag {
  private var flag = false

  func set() { flag = true }
  func value() -> Bool { flag }
}

private final class HerdrLockedSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  func callAsFunction() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? "exhausted" : values.removeFirst()
  }
}
