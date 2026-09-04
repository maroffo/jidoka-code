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

    let drifted = ProductionRolloutReleaseIdentityRevalidator {
      packagedIdentity(helperSHA256: String(repeating: "f", count: 64))
    }
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await drifted.requireCurrent(expected)
    }

    let applicationDrifted = ProductionRolloutReleaseIdentityRevalidator {
      packagedIdentity(applicationSHA256: String(repeating: "f", count: 64))
    }
    await #expect(throws: RolloutAuthorityError.previewDrift) {
      try await applicationDrifted.requireCurrent(expected)
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
    herdrHostSHA256: String(repeating: "c", count: 64),
    schemaVersion: 10,
    engineProtocolVersion: 12,
    runtimeManifestSHA256: String(repeating: "d", count: 64),
    runtimeTreeSHA256: String(repeating: "e", count: 64),
    modelProfilesSHA256: String(repeating: "6", count: 64),
    workflowResourcesSHA256: String(repeating: "7", count: 64),
    githubAccount: "owner",
    githubAuthorID: 42,
    repositoryConfigurationSHA256: String(repeating: "8", count: 64),
    maxConcurrency: 1
  )
}

private func packagedIdentity(
  applicationSHA256: String = String(repeating: "a", count: 64),
  helperSHA256: String = String(repeating: "b", count: 64)
) -> RolloutObservedReleaseIdentity {
  RolloutObservedReleaseIdentity(
    packaged: RolloutPackagedReleaseIdentity(
      manifestSchemaVersion: 1,
      sourceCommit: String(repeating: "1", count: 40),
      sourceTree: String(repeating: "2", count: 40),
      bundleVersion: "0.2.0",
      bundleBuild: 3,
      helperSHA256: helperSHA256,
      herdrHostSHA256: String(repeating: "c", count: 64),
      databaseSchemaVersion: 10,
      engineProtocolVersion: 12,
      runtimeManifestSHA256: String(repeating: "d", count: 64),
      runtimeTreeSHA256: String(repeating: "e", count: 64),
      workflowResourcesSHA256: String(repeating: "7", count: 64)
    ),
    applicationSHA256: applicationSHA256
  )
}
