import Darwin
import Foundation
import Security

public struct EngineXPCPeerValidator: Sendable {
  private let expectedClientURL: URL
  private let pathForProcess: @Sendable (pid_t) -> URL?
  private let codeIsValid: @Sendable (pid_t) -> Bool

  public init(helperExecutableURL: URL) {
    let expectedClientURL = Self.expectedClientURL(for: helperExecutableURL)
    self.init(
      helperExecutableURL: helperExecutableURL,
      pathForProcess: Self.systemPath(for:),
      codeIsValid: { processID in
        Self.systemCodeIsValid(
          processID: processID,
          expectedClientURL: expectedClientURL
        )
      }
    )
  }

  init(
    helperExecutableURL: URL,
    pathForProcess: @escaping @Sendable (pid_t) -> URL?,
    codeIsValid: @escaping @Sendable (pid_t) -> Bool = { _ in true }
  ) {
    expectedClientURL =
      Self.expectedClientURL(for: helperExecutableURL)
      .resolvingSymlinksInPath().standardizedFileURL
    self.pathForProcess = pathForProcess
    self.codeIsValid = codeIsValid
  }

  public func accepts(processID: pid_t, effectiveUserID: uid_t) -> Bool {
    guard processID > 0, effectiveUserID == geteuid(), codeIsValid(processID),
      let observed = pathForProcess(processID)?.resolvingSymlinksInPath().standardizedFileURL
    else {
      return false
    }
    return observed == expectedClientURL
  }

  public static func expectedClientURL(for helperExecutableURL: URL) -> URL {
    let helper = helperExecutableURL.standardizedFileURL
    let directory = helper.deletingLastPathComponent()
    if directory.lastPathComponent == "Helpers" {
      return directory.deletingLastPathComponent()
        .appendingPathComponent("MacOS/JidokaCodeApp", isDirectory: false)
    }
    return directory.appendingPathComponent("JidokaCodeApp", isDirectory: false)
  }

  private static func systemCodeIsValid(
    processID: pid_t,
    expectedClientURL: URL
  ) -> Bool {
    var expectedCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        expectedClientURL as CFURL,
        SecCSFlags(),
        &expectedCode
      ) == errSecSuccess,
      let expectedCode,
      SecStaticCodeCheckValidity(expectedCode, SecCSFlags(), nil) == errSecSuccess
    else {
      return false
    }
    var requirement: SecRequirement?
    guard
      SecCodeCopyDesignatedRequirement(
        expectedCode,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return false
    }
    var runningCode: SecCode?
    let attributes =
      [
        kSecGuestAttributePid as String: NSNumber(value: processID)
      ] as CFDictionary
    guard
      SecCodeCopyGuestWithAttributes(
        nil,
        attributes,
        SecCSFlags(),
        &runningCode
      ) == errSecSuccess,
      let runningCode
    else {
      return false
    }
    return SecCodeCheckValidity(runningCode, SecCSFlags(), requirement) == errSecSuccess
  }

  private static func systemPath(for processID: pid_t) -> URL? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? Int(length)
    let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    return URL(fileURLWithPath: path, isDirectory: false)
  }
}
