import XCTest

@testable import JidokaCodeCore

final class XCTestSmokeTests: XCTestCase {
  func testExpectedProductionIdentitiesAreStable() {
    XCTAssertEqual(PackagedPreflight.expectedBundleIdentifier, "com.maroffo.JidokaCode")
    XCTAssertEqual(LifecycleProbeConstants.appBundleIdentifier, "com.maroffo.JidokaCode")
    XCTAssertEqual(LifecycleProbeConstants.helperIdentifier, "com.maroffo.JidokaCode.Engine")
    XCTAssertEqual(
      LifecycleProbeConstants.launchAgentPlistName,
      "com.maroffo.JidokaCode.Engine.plist"
    )
    XCTAssertEqual(
      LifecycleProbeConstants.mainQuitNotification,
      "com.maroffo.JidokaCode.lifecycle.quit"
    )
  }
}
