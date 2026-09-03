import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Lifecycle probe contract")
struct LifecycleProbeTests {
  @Test("direct client completes 100 unique ordered round trips")
  func directRoundTrips() throws {
    let client = DirectEngineClient(launchID: "direct-launch", pid: 42, generation: 1)

    let report = try client.run(roundTrips: 100)

    #expect(report.count == 100)
    #expect(report.duplicateCount == 0)
    #expect(report.ordered)
    #expect(report.snapshot.launchID == "direct-launch")
    #expect(report.snapshot.topology == .direct)
  }

  @Test("round-trip bounds fail closed", arguments: [0, -1, 1_001, Int.max])
  func invalidRoundTripCount(count: Int) {
    let client = DirectEngineClient()

    #expect(throws: LifecycleProbeError.invalidRoundTripCount(count)) {
      try client.run(roundTrips: count)
    }
  }

  @Test("direct request identity is validated")
  func invalidDirectRequest() {
    let client = DirectEngineClient()

    #expect(throws: LifecycleProbeError.invalidRequest) {
      try client.roundTrip(EngineRoundTripRequest(requestID: "wrong", sequence: 1))
    }
  }

  @Test("wrong-identity and unordered responses are rejected")
  func responseValidation() {
    #expect(throws: LifecycleProbeError.invalidResponse) {
      try WrongIdentityClient().run(roundTrips: 1)
    }
    #expect(throws: LifecycleProbeError.unorderedResponse(expected: 0, actual: 1)) {
      try UnorderedClient().run(roundTrips: 1)
    }
  }

  @Test("XPC request and response validate exact identity")
  func xpcValidation() throws {
    let snapshot = helperSnapshot
    let roundTrip = EngineRoundTripRequest(requestID: "jidoka-lifecycle-7", sequence: 7)
    let request = EngineProbeXPCRequest(operation: .roundTrip, roundTrip: roundTrip)
    let responseRoundTrip = EngineRoundTripResponse(
      requestID: roundTrip.requestID,
      sequence: roundTrip.sequence,
      snapshot: snapshot
    )
    let response = EngineProbeXPCResponse(
      operation: .roundTrip,
      roundTrip: responseRoundTrip,
      snapshot: snapshot
    )

    try request.validate()
    try response.validate(for: request)

    let malformed = EngineProbeXPCRequest(operation: .snapshot, roundTrip: roundTrip)
    #expect(throws: LifecycleProbeError.invalidRequest) {
      try malformed.validate()
    }
    let wrongResponse = EngineProbeXPCResponse(
      operation: .snapshot,
      snapshot: snapshot
    )
    #expect(throws: LifecycleProbeError.invalidResponse) {
      try wrongResponse.validate(for: request)
    }

    let digest = String(repeating: "a", count: 64)
    let keychainRequest = EngineProbeXPCRequest(operation: .keychainDigest)
    let keychainResponse = EngineProbeXPCResponse(
      operation: .keychainDigest,
      keychainSHA256: digest,
      snapshot: snapshot
    )
    try keychainRequest.validate()
    try keychainResponse.validate(for: keychainRequest)
    #expect(throws: LifecycleProbeError.invalidResponse) {
      try EngineProbeXPCResponse(
        operation: .keychainDigest,
        keychainSHA256: "invalid",
        snapshot: snapshot
      ).validate(for: keychainRequest)
    }
    #expect(throws: LifecycleProbeError.invalidResponse) {
      try EngineProbeXPCResponse(
        operation: .snapshot,
        keychainSHA256: digest,
        snapshot: snapshot
      ).validate(for: EngineProbeXPCRequest(operation: .snapshot))
    }
  }

  @Test(
    "service status values are stable",
    arguments: [
      (0, LifecycleServiceStatus.notRegistered),
      (1, LifecycleServiceStatus.enabled),
      (2, LifecycleServiceStatus.requiresApproval),
      (3, LifecycleServiceStatus.notFound),
    ])
  func serviceStatus(rawValue: Int, expected: LifecycleServiceStatus) throws {
    #expect(try LifecycleServiceStatus(rawServiceManagementValue: rawValue) == expected)
  }

  @Test("unknown service status fails closed")
  func unknownServiceStatus() {
    #expect(throws: LifecycleProbeError.invalidResponse) {
      try LifecycleServiceStatus(rawServiceManagementValue: 4)
    }
  }

  @Test("reconciliation is the first launch event")
  func reconciliationFirst() {
    let events = LifecycleEvent.launchSequence(snapshot: helperSnapshot)

    #expect(events.count == 1)
    #expect(events.first?.event == .reconciliation)
    #expect(events.first?.sequence == 0)
    #expect(events.first?.launchID == helperSnapshot.launchID)
  }

  @Test("closed lifecycle arguments parse")
  func lifecycleArguments() throws {
    #expect(try LifecycleCommand.parse(["main", "status"]) == .mainStatus)
    #expect(try LifecycleCommand.parse(["agent", "register"]) == .agentRegister)
    #expect(try LifecycleCommand.parse(["direct", "round-trips", "100"]) == .directRoundTrips(100))
    #expect(try LifecycleCommand.parse(["helper", "snapshot"]) == .helperSnapshot)
    #expect(try LifecycleCommand.parse(["helper", "crash"]) == .helperCrash)
    #expect(try LifecycleCommand.parse(["helper", "graceful-quit"]) == .helperGracefulQuit)
    #expect(try LifecycleCommand.parse(["helper", "keychain-digest"]) == .helperKeychainDigest)
  }

  @Test(
    "arbitrary lifecycle arguments are rejected",
    arguments: [
      [String](),
      ["main"],
      ["main", "status", "extra"],
      ["direct", "round-trips", "0"],
      ["helper", "round-trips", "1001"],
      ["helper", "run", "/tmp/arbitrary"],
    ])
  func invalidLifecycleArguments(arguments: [String]) {
    #expect(throws: LifecycleProbeError.invalidArguments) {
      try LifecycleCommand.parse(arguments)
    }
  }

  @Test("service lifetime suspends without blocking the main executor")
  @MainActor
  func asynchronousServiceLifetime() async throws {
    var retained: LifecycleLifetimeSentinel? = LifecycleLifetimeSentinel()
    weak let weakRetained = retained
    var lifetime: EngineServiceLifetime? = EngineServiceLifetime(
      retaining: [try #require(retained)]
    )
    let completion = LifecycleLifetimeCompletion()
    let task = Task { [weak lifetime] in
      guard let lifetime else { return }
      await completion.start()
      await lifetime.wait()
      await completion.finish()
    }
    for _ in 0..<100 {
      if await completion.startedValue() { break }
      await Task.yield()
    }
    retained = nil
    lifetime = nil

    try await Task.sleep(for: .milliseconds(50))
    #expect(weakRetained != nil)
    #expect(!(await completion.finishedValue()))

    task.cancel()
    await task.value
    #expect(await completion.finishedValue())
    #expect(weakRetained == nil)
  }

  @Test("service lifetime handles cancellation before entering its wait")
  func precancelledServiceLifetime() async {
    let gate = LifecycleLifetimeEntryGate()
    let completion = LifecycleLifetimeCompletion()
    let lifetime = EngineServiceLifetime(retaining: [])
    let task = Task {
      await gate.wait()
      await lifetime.wait()
      await completion.finish()
    }
    for _ in 0..<100 {
      if await gate.isWaiting() { break }
      await Task.yield()
    }
    #expect(await gate.isWaiting())

    task.cancel()
    await gate.open()
    await task.value
    #expect(await completion.finishedValue())
  }

  @Test("packaged probe resolves resources when launchd supplies a basename argv zero")
  func launchdBasenameExecutablePath() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-launchd-argv-zero-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Jidoka Code.app/Contents", isDirectory: true)
    let helperDirectory = contents.appendingPathComponent("Helpers", isDirectory: true)
    let resources = contents.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: helperDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: resources.appendingPathComponent("Pi", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: resources.appendingPathComponent("Herdr", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: resources.appendingPathComponent("PiRuntime", isDirectory: true),
      withIntermediateDirectories: true
    )
    let helper = helperDirectory.appendingPathComponent("JidokaCodeEngineProbe")
    try FileManager.default.copyItem(
      at: builtProduct(named: "JidokaCodeEngineProbe"),
      to: helper
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      "-c",
      "exec -a JidokaCodeEngineProbe \"$1\" --path-probe",
      "jidoka-launchd-test",
      helper.path,
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()

    #expect(process.terminationStatus == 0)
    #expect(error.isEmpty)
    let report = try #require(
      JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect(report["identifier"] as? String == LifecycleProbeConstants.helperIdentifier)
    #expect(report["status"] as? String == "ok")
  }

  @Test("service generation arguments are exact")
  func serviceArguments() throws {
    #expect(
      try EngineServiceArguments.parse(["--service", "--generation", "2"])
        == EngineServiceArguments(generation: 2))
    #expect(throws: LifecycleProbeError.invalidArguments) {
      try EngineServiceArguments.parse(["--service", "--generation", "0"])
    }
    #expect(throws: LifecycleProbeError.invalidArguments) {
      try EngineServiceArguments.parse(["--service", "--generation", "1", "extra"])
    }
  }

  @Test("topology gate keeps each passing candidate")
  func topologyGateCandidates() throws {
    #expect(
      try LifecycleTopologyGate.eligibleTopologies(
        directPassed: true, helperPassed: false) == [.direct])
    #expect(
      try LifecycleTopologyGate.eligibleTopologies(
        directPassed: false, helperPassed: true) == [.helper])
    #expect(
      try LifecycleTopologyGate.eligibleTopologies(
        directPassed: true, helperPassed: true) == [.direct, .helper])
  }

  @Test("topology gate blocks when every candidate fails")
  func topologyGateBlocks() {
    #expect(throws: LifecycleProbeError.noEligibleTopology) {
      try LifecycleTopologyGate.eligibleTopologies(
        directPassed: false, helperPassed: false)
    }
  }

  private var helperSnapshot: EngineSnapshot {
    EngineSnapshot(
      generation: 1,
      launchID: "helper-launch",
      pid: 43,
      reconciled: true,
      topology: .helper
    )
  }
}

private final class LifecycleLifetimeSentinel {}

private actor LifecycleLifetimeCompletion {
  private var started = false
  private var finished = false

  func start() {
    started = true
  }

  func finish() {
    finished = true
  }

  func startedValue() -> Bool {
    started
  }

  func finishedValue() -> Bool {
    finished
  }
}

private actor LifecycleLifetimeEntryGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiting = false

  func wait() async {
    waiting = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func isWaiting() -> Bool {
    waiting
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

private struct WrongIdentityClient: LifecycleProbeClient {
  private let snapshotValue = EngineSnapshot(
    generation: 1,
    launchID: "wrong-identity",
    pid: 1,
    reconciled: true,
    topology: .direct
  )

  func snapshot() -> EngineSnapshot { snapshotValue }

  func roundTrip(_ request: EngineRoundTripRequest) -> EngineRoundTripResponse {
    EngineRoundTripResponse(requestID: "wrong", sequence: request.sequence, snapshot: snapshotValue)
  }
}

private struct UnorderedClient: LifecycleProbeClient {
  private let snapshotValue = EngineSnapshot(
    generation: 1,
    launchID: "unordered",
    pid: 1,
    reconciled: true,
    topology: .direct
  )

  func snapshot() -> EngineSnapshot { snapshotValue }

  func roundTrip(_ request: EngineRoundTripRequest) -> EngineRoundTripResponse {
    EngineRoundTripResponse(
      requestID: request.requestID,
      sequence: request.sequence + 1,
      snapshot: snapshotValue
    )
  }
}
