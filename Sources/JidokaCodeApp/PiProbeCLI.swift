import CryptoKit
import Darwin
import Foundation
import JidokaCodeCore

private enum PiProbeCLIConstants {
  static let nodeURL = URL(fileURLWithPath: "/opt/homebrew/Cellar/node/26.6.0/bin/node")
  static let runnerRelativePath = "runtime/pi-rpc-profile-probe.mjs"
  static let runnerSHA256 = "83d081f9337bc1531e8c516e4248c324de26e325a4f8ef3895eb3df3417d45e9"
  static let runtimeAttestationRelativePath = "runtime/pi-runtime-attestation.mjs"
  static let runtimeAttestationSHA256 =
    "a2187f46e1a5e97cf8f87be230382f4bbd235d7c47d31eb933c821d799bd5e9e"
  static let maximumOutputBytes = 1_048_576
}

enum PiProbeCLIError: Error, Equatable {
  case invalidPackagedRunner
  case invalidNodeRuntime
  case invalidOutput
  case runnerFailed(Int32)
  case timeout
  case unsafeConsentDirectory
}

enum PiProbeCLI {
  static func run(arguments: [String]) throws -> Data {
    let command = try PiProbeCommand.parse(arguments)
    let resourceRoot = try packagedResourceRoot()
    let runnerURL = try packagedRunner(in: resourceRoot)
    let workspaceURL = try createTemporaryWorkspace()
    let runnerArguments: [String]

    switch command {
    case .preflight:
      runnerArguments = ["preflight", resourceRoot.path]
    case .timeout:
      runnerArguments = ["timeout", resourceRoot.path]
    case .ledgerPreflight:
      runnerArguments = [
        "ledger-preflight",
        resourceRoot.path,
        workspaceURL.appendingPathComponent("provider-call-ledger.json").path,
      ]
    case .profile(let profile):
      let ledgerURL = try canonicalProviderLedgerURL()
      runnerArguments = ["profile", resourceRoot.path, profile.rawValue, ledgerURL.path]
    }

    defer {
      try? removeTemporaryWorkspace(workspaceURL)
    }
    return try executeRunner(
      runnerURL: runnerURL,
      workspaceURL: workspaceURL,
      arguments: runnerArguments,
      timeout: commandTimeout(command)
    )
  }

  static func write(_ data: Data) {
    FileHandle.standardOutput.write(data)
    if data.last != 0x0A {
      FileHandle.standardOutput.write(Data([0x0A]))
    }
  }

  private static func createTemporaryWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-pi-workspace-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return workspace
  }

  private static func removeTemporaryWorkspace(_ workspace: URL) throws {
    let values = try workspace.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard
      workspace.lastPathComponent.hasPrefix("jidoka-code-pi-workspace-"),
      values.isDirectory == true,
      values.isSymbolicLink == false
    else {
      throw PiProbeCLIError.invalidOutput
    }
    try FileManager.default.removeItem(at: workspace)
  }

  private static func packagedResourceRoot() throws -> URL {
    guard let resources = Bundle.main.resourceURL else {
      throw PiProbeCLIError.invalidPackagedRunner
    }
    let root = resources.appendingPathComponent("Pi", isDirectory: true).standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink == false else {
      throw PiProbeCLIError.invalidPackagedRunner
    }
    return root
  }

  private static func packagedRunner(in resourceRoot: URL) throws -> URL {
    _ = try packagedRuntimeFile(
      in: resourceRoot,
      relativePath: PiProbeCLIConstants.runtimeAttestationRelativePath,
      expectedSHA256: PiProbeCLIConstants.runtimeAttestationSHA256
    )
    return try packagedRuntimeFile(
      in: resourceRoot,
      relativePath: PiProbeCLIConstants.runnerRelativePath,
      expectedSHA256: PiProbeCLIConstants.runnerSHA256
    )
  }

  private static func packagedRuntimeFile(
    in resourceRoot: URL,
    relativePath: String,
    expectedSHA256: String
  ) throws -> URL {
    let file = resourceRoot.appendingPathComponent(
      relativePath,
      isDirectory: false
    ).standardizedFileURL
    let resolvedRoot = resourceRoot.resolvingSymlinksInPath().path
    let resolvedFile = file.resolvingSymlinksInPath().path
    let values = try file.resourceValues(forKeys: [
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard resolvedFile.hasPrefix(resolvedRoot + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink == false,
      let fileSize = values.fileSize,
      fileSize <= PiProbeCLIConstants.maximumOutputBytes
    else {
      throw PiProbeCLIError.invalidPackagedRunner
    }
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA256 else {
      throw PiProbeCLIError.invalidPackagedRunner
    }
    return file
  }

  private static func canonicalProviderLedgerURL() throws -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let components = ["Library", "Application Support", "JidokaCode", "Consent"]
    var current = home
    for (index, component) in components.enumerated() {
      current.appendPathComponent(component, isDirectory: true)
      if FileManager.default.fileExists(atPath: current.path) {
        let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
          throw PiProbeCLIError.unsafeConsentDirectory
        }
      } else {
        try FileManager.default.createDirectory(
          at: current,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      }
      if index >= 2 {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700],
          ofItemAtPath: current.path
        )
      }
    }
    return current.appendingPathComponent("provider-call-ledger.json", isDirectory: false)
  }

  private static func commandTimeout(_ command: PiProbeCommand) -> DispatchTimeInterval {
    switch command {
    case .profile:
      return .seconds(150)
    case .preflight, .timeout, .ledgerPreflight:
      return .seconds(30)
    }
  }

  private static func executeRunner(
    runnerURL: URL,
    workspaceURL: URL,
    arguments: [String],
    timeout: DispatchTimeInterval
  ) throws -> Data {
    let nodeValues = try PiProbeCLIConstants.nodeURL.resourceValues(forKeys: [
      .isExecutableKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard
      nodeValues.isExecutable == true,
      nodeValues.isRegularFile == true,
      nodeValues.isSymbolicLink == false
    else {
      throw PiProbeCLIError.invalidNodeRuntime
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let termination = DispatchSemaphore(value: 0)
    process.executableURL = PiProbeCLIConstants.nodeURL
    process.arguments = [runnerURL.path] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "JIDOKA_PI_WORKSPACE": workspaceURL.path,
      "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in termination.signal() }
    try process.run()

    guard termination.wait(timeout: .now() + timeout) == .success else {
      process.terminate()
      if termination.wait(timeout: .now() + .seconds(8)) != .success {
        kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + .seconds(2))
      }
      throw PiProbeCLIError.timeout
    }

    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw PiProbeCLIError.runnerFailed(process.terminationStatus)
    }
    guard
      errorOutput.isEmpty,
      !output.isEmpty,
      output.count <= PiProbeCLIConstants.maximumOutputBytes,
      output.filter({ $0 == 0x0A }).count == 1,
      (try? JSONSerialization.jsonObject(with: output)) is [String: Any]
    else {
      throw PiProbeCLIError.invalidOutput
    }
    return output
  }
}
