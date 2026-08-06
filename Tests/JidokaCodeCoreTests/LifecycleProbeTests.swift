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

private struct WrongIdentityClient: EngineClient {
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

private struct UnorderedClient: EngineClient {
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
