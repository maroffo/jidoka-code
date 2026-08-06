import CryptoKit
import Darwin
import Foundation
import JidokaCodeCore

private enum WorkflowProbeCLIConstants {
  static let nodeURL = URL(fileURLWithPath: "/opt/homebrew/Cellar/node/26.6.0/bin/node")
  static let runnerRelativePath = "runtime/pi-rpc-workflow-probe.mjs"
  static let runnerSHA256 = "37ebfc816041f9242b5da4298e064dbb9bcde794ab192926fca6f73ca156c1dd"
  static let maximumOutputBytes = 1_048_576
}

enum WorkflowProbeCLIError: Error, Equatable {
  case invalidNodeRuntime
  case invalidOutput
  case invalidPackagedRunner
  case runnerFailed(Int32)
  case timeout
  case unsafeConsentDirectory
  case unsafeWorkspace
}

enum WorkflowProbeCLI {
  static func run(arguments: [String]) throws -> Data {
    let command = try WorkflowProbeCommand.parse(arguments)
    let resourceRoot = try packagedResourceRoot()
    let runnerURL = try packagedRunner(in: resourceRoot)
    let ledgerURL = try canonicalProviderLedgerURL()
    let workspaceURL = try createTemporaryWorkspace()
    defer {
      try? removeTemporaryWorkspace(workspaceURL)
    }
    return try executeRunner(
      runnerURL: runnerURL,
      resourceRoot: resourceRoot,
      ledgerURL: ledgerURL,
      workspaceURL: workspaceURL,
      command: command
    )
  }

  static func write(_ data: Data) {
    FileHandle.standardOutput.write(data)
    if data.last != 0x0A {
      FileHandle.standardOutput.write(Data([0x0A]))
    }
  }

  private static func packagedResourceRoot() throws -> URL {
    guard let resources = Bundle.main.resourceURL else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
    }
    let root = resources.appendingPathComponent("Pi", isDirectory: true).standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink == false else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
    }
    return root
  }

  private static func packagedRunner(in resourceRoot: URL) throws -> URL {
    let runner = resourceRoot.appendingPathComponent(
      WorkflowProbeCLIConstants.runnerRelativePath,
      isDirectory: false
    ).standardizedFileURL
    let resolvedRoot = resourceRoot.resolvingSymlinksInPath().path
    let resolvedRunner = runner.resolvingSymlinksInPath().path
    let values = try runner.resourceValues(forKeys: [
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard
      resolvedRunner.hasPrefix(resolvedRoot + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink == false,
      let fileSize = values.fileSize,
      fileSize <= WorkflowProbeCLIConstants.maximumOutputBytes
    else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
    }
    let data = try Data(contentsOf: runner, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == WorkflowProbeCLIConstants.runnerSHA256 else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
    }
    return runner
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
          throw WorkflowProbeCLIError.unsafeConsentDirectory
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

  private static func createTemporaryWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-workflow-workspace-\(UUID().uuidString.lowercased())",
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
      workspace.lastPathComponent.hasPrefix("jidoka-code-workflow-workspace-"),
      values.isDirectory == true,
      values.isSymbolicLink == false
    else {
      throw WorkflowProbeCLIError.unsafeWorkspace
    }
    try FileManager.default.removeItem(at: workspace)
  }

  private static func executeRunner(
    runnerURL: URL,
    resourceRoot: URL,
    ledgerURL: URL,
    workspaceURL: URL,
    command: WorkflowProbeCommand
  ) throws -> Data {
    let nodeValues = try WorkflowProbeCLIConstants.nodeURL.resourceValues(forKeys: [
      .isExecutableKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard
      nodeValues.isExecutable == true,
      nodeValues.isRegularFile == true,
      nodeValues.isSymbolicLink == false
    else {
      throw WorkflowProbeCLIError.invalidNodeRuntime
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let termination = DispatchSemaphore(value: 0)
    process.executableURL = WorkflowProbeCLIConstants.nodeURL
    process.arguments = [runnerURL.path, command.rawValue, resourceRoot.path, ledgerURL.path]
    process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "JIDOKA_WORKFLOW_WORKSPACE": workspaceURL.path,
      "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in termination.signal() }
    try process.run()

    let timeout: DispatchTimeInterval = command == .live ? .seconds(2_100) : .seconds(180)
    guard termination.wait(timeout: .now() + timeout) == .success else {
      process.terminate()
      if termination.wait(timeout: .now() + .seconds(8)) != .success {
        kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + .seconds(2))
      }
      throw WorkflowProbeCLIError.timeout
    }

    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw WorkflowProbeCLIError.runnerFailed(process.terminationStatus)
    }
    guard
      errorOutput.isEmpty,
      !output.isEmpty,
      output.count <= WorkflowProbeCLIConstants.maximumOutputBytes,
      output.filter({ $0 == 0x0A }).count == 1,
      (try? JSONSerialization.jsonObject(with: output)) is [String: Any]
    else {
      throw WorkflowProbeCLIError.invalidOutput
    }
    return output
  }
}
