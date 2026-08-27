import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Engine XPC peer validation")
struct EngineXPCPeerValidatorTests {
  @Test("packaged and development helpers derive only the exact sibling app executable")
  func expectedPaths() {
    #expect(
      EngineXPCPeerValidator.expectedClientURL(
        for: URL(
          fileURLWithPath: "/Applications/Jidoka Code.app/Contents/Helpers/JidokaCodeEngineProbe")
      ).path == "/Applications/Jidoka Code.app/Contents/MacOS/Jidoka Code"
    )
    #expect(
      EngineXPCPeerValidator.expectedClientURL(
        for: URL(fileURLWithPath: "/tmp/build/JidokaCodeEngineProbe")
      ).path == "/tmp/build/JidokaCodeApp"
    )
  }

  @Test("UID, PID, and exact executable path all fail closed")
  func exactPeerIdentity() {
    let helper = URL(fileURLWithPath: "/tmp/build/JidokaCodeEngineProbe")
    let accepted = EngineXPCPeerValidator(helperExecutableURL: helper) { processID in
      processID == 42 ? URL(fileURLWithPath: "/tmp/build/JidokaCodeApp") : nil
    }
    #expect(accepted.accepts(processID: 42, effectiveUserID: geteuid()))
    #expect(!accepted.accepts(processID: 0, effectiveUserID: geteuid()))
    #expect(!accepted.accepts(processID: 43, effectiveUserID: geteuid()))
    #expect(!accepted.accepts(processID: 42, effectiveUserID: geteuid() &+ 1))

    let wrongPath = EngineXPCPeerValidator(helperExecutableURL: helper) { _ in
      URL(fileURLWithPath: "/tmp/attacker/JidokaCodeApp")
    }
    #expect(!wrongPath.accepts(processID: 42, effectiveUserID: geteuid()))
    let invalidSignature = EngineXPCPeerValidator(
      helperExecutableURL: helper,
      pathForProcess: { _ in URL(fileURLWithPath: "/tmp/build/JidokaCodeApp") },
      codeIsValid: { _ in false }
    )
    #expect(!invalidSignature.accepts(processID: 42, effectiveUserID: geteuid()))
  }
}
