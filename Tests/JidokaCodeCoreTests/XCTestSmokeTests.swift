import XCTest

@testable import JidokaCodeCore

final class XCTestSmokeTests: XCTestCase {
  func testExpectedIdentityIsStable() {
    XCTAssertEqual(
      PackagedPreflight.expectedBundleIdentifier,
      "com.maroffo.JidokaCode.Probe"
    )
  }
}
