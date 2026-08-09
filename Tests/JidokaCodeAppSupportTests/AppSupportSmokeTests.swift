import Testing

@testable import JidokaCodeAppSupport

@Test("app support target loads")
func appSupportTargetLoads() {
  #expect(JidokaAccessibilityID.pollNow == "jidoka.menu.poll-now")
}
