import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Rollout release identity attestor")
struct RolloutReleaseIdentityAttestorTests {
  @Test("packaged release identity must match every executable and resource binding")
  func exactPackagedIdentity() async throws {
    let expected = releaseIdentity()
    let exact = ProductionRolloutReleaseIdentityRevalidator {
      packagedIdentity()
    }
    try await exact.requireCurrent(expected)

    for drift in PackagedIdentityDrift.allCases {
      let drifted = ProductionRolloutReleaseIdentityRevalidator {
        packagedIdentity(drift: drift)
      }
      await #expect(throws: RolloutAuthorityError.previewDrift, "\(drift)") {
        try await drifted.requireCurrent(expected)
      }
    }
  }

  @Test("inspection failures are normalized to fail-closed rollout drift")
  func inspectionFailure() async {
    let verifier = ProductionRolloutReleaseIdentityRevalidator {
      throw CocoaError(.fileReadNoSuchFile)
    }
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await verifier.requireCurrent(releaseIdentity())
    }
  }
}

private func releaseIdentity() -> RolloutReleaseIdentity {
  RolloutReleaseIdentity(
    sourceCommit: String(repeating: "1", count: 40),
    sourceTree: String(repeating: "2", count: 40),
    bundleVersion: "0.2.0",
    bundleBuild: 3,
    applicationSHA256: String(repeating: "a", count: 64),
    helperSHA256: String(repeating: "b", count: 64),
    askPassSHA256: String(repeating: "c", count: 64),
    pushGuardSHA256: String(repeating: "d", count: 64),
    herdrHostSHA256: String(repeating: "e", count: 64),
    schemaVersion: 10,
    engineProtocolVersion: 12,
    runtimeManifestSHA256: String(repeating: "f", count: 64),
    runtimeTreeSHA256: String(repeating: "6", count: 64),
    modelProfilesSHA256: String(repeating: "8", count: 64),
    workflowResourcesSHA256: String(repeating: "7", count: 64),
    githubAccount: "owner",
    githubAuthorID: 42,
    repositoryConfigurationSHA256: String(repeating: "9", count: 64),
    maxConcurrency: 1
  )
}

private enum PackagedIdentityDrift: CaseIterable {
  case manifestSchema
  case sourceCommit
  case sourceTree
  case bundleVersion
  case bundleBuild
  case application
  case helper
  case askPass
  case pushGuard
  case herdrHost
  case databaseSchema
  case engineProtocol
  case runtimeManifest
  case runtimeTree
  case workflowResources
}

private func packagedIdentity(
  drift: PackagedIdentityDrift? = nil
) -> RolloutObservedReleaseIdentity {
  let alternateDigest = String(repeating: "0", count: 64)
  return RolloutObservedReleaseIdentity(
    packaged: RolloutPackagedReleaseIdentity(
      manifestSchemaVersion: drift == .manifestSchema ? 1 : 2,
      sourceCommit: String(repeating: drift == .sourceCommit ? "0" : "1", count: 40),
      sourceTree: String(repeating: drift == .sourceTree ? "0" : "2", count: 40),
      bundleVersion: drift == .bundleVersion ? "0.2.1" : "0.2.0",
      bundleBuild: drift == .bundleBuild ? 4 : 3,
      helperSHA256: drift == .helper ? alternateDigest : String(repeating: "b", count: 64),
      askPassSHA256: drift == .askPass ? alternateDigest : String(repeating: "c", count: 64),
      pushGuardSHA256: drift == .pushGuard ? alternateDigest : String(repeating: "d", count: 64),
      herdrHostSHA256: drift == .herdrHost ? alternateDigest : String(repeating: "e", count: 64),
      databaseSchemaVersion: drift == .databaseSchema ? 9 : 10,
      engineProtocolVersion: drift == .engineProtocol ? 11 : 12,
      runtimeManifestSHA256: drift == .runtimeManifest
        ? alternateDigest : String(repeating: "f", count: 64),
      runtimeTreeSHA256: drift == .runtimeTree
        ? alternateDigest : String(repeating: "6", count: 64),
      workflowResourcesSHA256: drift == .workflowResources
        ? alternateDigest : String(repeating: "7", count: 64)
    ),
    applicationSHA256: drift == .application
      ? alternateDigest : String(repeating: "a", count: 64)
  )
}
