import Foundation
import JidokaCodeCore
import JidokaCodeTestSupport
import Testing

@testable import JidokaCodeApp

@Suite("Rollout operator CLI")
struct RolloutCLITests {
  @Test("each operator action parses its exact payload and rejects extra or missing arguments")
  func commandTable() throws {
    let fixture = try rolloutOperatorFixture()
    let exact = fixture.exactActivation
    let finite = fixture.finiteActivation
    let recovery = fixture.recoveryAuthorization
    let cases: [([String], EngineCommand)] = [
      (
        [
          "preview-exact",
          try RolloutCanonicalJSON.encode(fixture.exactInput).base64EncodedString(),
        ],
        .previewRollout(fixture.exactInput)
      ),
      (
        [
          "preview-finite",
          try RolloutCanonicalJSON.encode(fixture.finiteInput).base64EncodedString(),
        ],
        .previewFiniteWindow(fixture.finiteInput)
      ),
      (
        [
          "activate-exact", exact.authorizationID.uuidString.lowercased(),
          exact.approvedCanonicalJSON.base64EncodedString(), exact.confirmedSHA256,
        ], .activateRollout(exact)
      ),
      (
        [
          "activate-finite", finite.authorizationID.uuidString.lowercased(),
          finite.approvedCanonicalJSON.base64EncodedString(), finite.confirmedSHA256,
        ], .activateFiniteWindow(finite)
      ),
      (["status"], .rolloutStatus),
      (
        [
          "stop", fixture.stop.authorizationID, fixture.stop.previewSHA256,
          String(fixture.stop.timeoutMilliseconds),
        ], .stopAndDrainRollout(fixture.stop)
      ),
      (
        [
          "preview-recovery", fixture.recoveryRequest.authorizationID,
          fixture.recoveryRequest.previewSHA256,
        ],
        .previewRolloutRecovery(fixture.recoveryRequest)
      ),
      (
        [
          "execute-recovery", recovery.approvedCanonicalJSON.base64EncodedString(),
          recovery.confirmedSHA256,
        ],
        .executeRolloutRecovery(recovery)
      ),
      (["poll-finite"], .pollNow),
    ]
    for (arguments, command) in cases {
      #expect(try RolloutCLI.parse(arguments) == command)
      #expect(throws: EngineClientError(.invalidCommand)) {
        try RolloutCLI.parse(arguments + ["extra"])
      }
      #expect(throws: EngineClientError(.invalidCommand)) {
        try RolloutCLI.parse(Array(arguments.dropLast()))
      }
    }
  }

  @Test("mode, UUID, digest, JSON and timeout mismatches are refused")
  func invalidArguments() throws {
    let fixture = try rolloutOperatorFixture()
    let activation = fixture.exactActivation
    let id = activation.authorizationID.uuidString.lowercased()
    let json = activation.approvedCanonicalJSON.base64EncodedString()
    let digest = activation.confirmedSHA256
    let invalid = [
      ["unknown"], ["STATUS"],
      [
        "preview-exact", try RolloutCanonicalJSON.encode(fixture.finiteInput).base64EncodedString(),
      ],
      [
        "preview-finite", try RolloutCanonicalJSON.encode(fixture.exactInput).base64EncodedString(),
      ],
      ["activate-exact", "AAAAAAAA-0000-4000-8000-000000000001", json, digest],
      ["activate-exact", "not-a-uuid", json, digest],
      ["preview-exact", Data("{}".utf8).base64EncodedString()],
      [
        "preview-exact",
        (try RolloutCanonicalJSON.encode(fixture.exactInput) + Data([0x20])).base64EncodedString(),
      ],
      ["stop", id, digest, "NaN"],
    ]
    for arguments in invalid {
      #expect(throws: EngineClientError(.invalidCommand), "\(arguments[0])") {
        try RolloutCLI.parse(arguments)
      }
    }
    for timeout in [1_000, 660_000] {
      #expect(
        try RolloutCLI.parse(["stop", id, digest, String(timeout)]).kind == .stopAndDrainRollout)
    }
    let invalidRequests: [([String], RolloutAuthorityError)] = [
      (["activate-exact", id, json, String(repeating: "f", count: 64)], .previewDigestMismatch),
      (["activate-finite", id, json, digest], .previewDigestMismatch),
      (["stop", id, digest, "999"], .invalidIdentifier("stop request")),
      (["stop", id, digest, "660001"], .invalidIdentifier("stop request")),
      (["stop", id, "short", "1000"], .invalidIdentifier("stop request")),
      (["preview-recovery", id, "short"], .invalidIdentifier("recovery request")),
      (
        [
          "execute-recovery",
          fixture.recoveryAuthorization.approvedCanonicalJSON.base64EncodedString(),
          String(repeating: "f", count: 64),
        ], .previewDigestMismatch
      ),
    ]
    for (arguments, error) in invalidRequests {
      #expect(throws: error) { try RolloutCLI.parse(arguments) }
    }
  }

  @Test("base64 decoding is canonical, nonempty and bounded before JSON parsing")
  func boundedCanonicalBytes() throws {
    let maximum = Data(repeating: 0x61, count: 1_048_576)
    #expect(try RolloutCLI.canonicalData(maximum.base64EncodedString()) == maximum)
    for invalid in [
      "", "_", "AR==", "AQ==\n",
      Data(repeating: 0x61, count: 1_048_577).base64EncodedString(),
      String(repeating: "A", count: 1_398_108),
    ] {
      #expect(throws: EngineClientError(.invalidCommand)) {
        try RolloutCLI.canonicalData(invalid)
      }
    }
  }

  @Test("stop and recovery allow the bounded engine drain budget")
  func responseBudgets() {
    for kind in EngineCommandKind.allCases {
      let expected = kind == .stopAndDrainRollout || kind == .executeRolloutRecovery ? 700 : 30
      #expect(RolloutCLI.responseTimeoutSeconds(for: kind) == expected)
    }
  }
}
