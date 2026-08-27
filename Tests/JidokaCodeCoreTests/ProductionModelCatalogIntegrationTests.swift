import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Pi model catalog integration")
struct ProductionModelCatalogIntegrationTests {
  @Test("production catalog construction is release-owned and has no private runtime fallback")
  func productionCatalogUsesOwnedRuntimeDirectly() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Sources/JidokaCodeCore/Pi/PiModelCatalog.swift"),
      encoding: .utf8
    )

    #expect(source.contains("runtimeResolver: ReleaseOwnedPiRuntimeResolver"))
    #expect(!source.contains("materializePrivateSnapshot"))
    #expect(!source.contains("DYLD_LIBRARY_PATH"))
    #expect(source.contains("\"PATH\": \"/usr/bin:/bin\""))
    #expect(
      source.contains("ReleaseOwnedPiRuntimeBoundaryAuthority.modelCatalogProcess(")
    )
  }
}
