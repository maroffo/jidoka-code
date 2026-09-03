import Foundation
import JidokaCodeLocationProbeSupport
import Testing

@Suite("Location probe protocol")
struct LocationProbeProtocolTests {
  @Test("request and response bind one canonical nonce and exact installed paths")
  func canonicalRoundTrip() throws {
    let nonce = UUID().uuidString.lowercased()
    let request = LocationProbeRequest(operation: .roundTrip, nonce: nonce)
    try request.validate()
    let response = LocationProbeResponse(
      operation: .roundTrip,
      nonce: nonce,
      helperProcessID: 42,
      helperExecutablePath:
        "/Library/Application Support/JidokaCode-LocationProbe/Applications/Jidoka Code Location Probe.app/Contents/Helpers/JidokaCodeLocationProbeEngine",
      containingApplicationPath:
        "/Library/Application Support/JidokaCode-LocationProbe/Applications/Jidoka Code Location Probe.app"
    )
    try response.validate(
      for: request,
      expectedApplicationPath: response.containingApplicationPath,
      expectedHelperPath: response.helperExecutablePath,
      expectedHelperProcessID: 42
    )
  }

  @Test("request rejects malformed nonce")
  func malformedNonce() {
    let request = LocationProbeRequest(operation: .roundTrip, nonce: "not-a-uuid")
    #expect(throws: LocationProbeError.invalidRequest) {
      try request.validate()
    }
  }

  @Test("response rejects operation nonce peer process and path drift", arguments: 0..<6)
  func responseDrift(index: Int) throws {
    let nonce = UUID().uuidString.lowercased()
    let request = LocationProbeRequest(operation: .roundTrip, nonce: nonce)
    let application = "/Applications/Jidoka Code Location Probe.app"
    let helper = "\(application)/Contents/Helpers/JidokaCodeLocationProbeEngine"
    let response = LocationProbeResponse(
      operation: index == 0 ? .shutdown : .roundTrip,
      nonce: index == 1 ? UUID().uuidString.lowercased() : nonce,
      helperProcessID: index == 2 ? 0 : 42,
      helperExecutablePath: index == 4 ? "\(helper).drift" : helper,
      containingApplicationPath: index == 5 ? "\(application).drift" : application
    )
    #expect(throws: LocationProbeError.invalidResponse) {
      try response.validate(
        for: request,
        expectedApplicationPath: application,
        expectedHelperPath: helper,
        expectedHelperProcessID: index == 3 ? 43 : 42
      )
    }
  }

  @Test("UAT identifiers remain distinct from production authority")
  func identifiersAreIsolated() {
    #expect(LocationProbeConstants.applicationIdentifier != "com.maroffo.JidokaCode")
    #expect(LocationProbeConstants.helperIdentifier != "com.maroffo.JidokaCode.Engine")
    #expect(LocationProbeConstants.packageIdentifier != "com.maroffo.JidokaCode.pkg")
  }
}
