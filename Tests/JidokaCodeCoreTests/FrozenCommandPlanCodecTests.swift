import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Durable frozen command plan snapshots")
struct FrozenCommandPlanCodecTests {
  @Test("round trip reconstructs every digest-bound invariant")
  func roundTrip() throws {
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"],
      rationale: "Run the exact repository check."
    )
    let plan = try makeFrozenPlan([command])

    let encoded = try FrozenCommandPlanCodec.encode(plan)
    let decoded = try FrozenCommandPlanCodec.decode(encoded)

    #expect(decoded == plan)
    #expect(decoded.planningDecisionSHA256 == plan.planningDecisionSHA256)
  }

  @Test("changed snapshot digest fails closed")
  func tamper() throws {
    let command = makeApprovedCommand(
      id: "check",
      kind: .makeTargets,
      executable: "make",
      arguments: ["check"],
      rationale: "Run the exact repository check."
    )
    let plan = try makeFrozenPlan([command])
    let encoded = try FrozenCommandPlanCodec.encode(plan)
    let changed = Data(
      String(decoding: encoded, as: UTF8.self)
        .replacingOccurrences(of: "# Test plan", with: "# Changed plan").utf8
    )

    #expect(throws: (any Error).self) {
      try FrozenCommandPlanCodec.decode(changed)
    }
  }
}
