import CryptoKit
import Darwin
import Foundation
import JidokaCodeCore

private enum LocalSpikeCLIConstants {
  static let nodeURL = URL(fileURLWithPath: "/opt/homebrew/Cellar/node/26.6.0/bin/node")
  static let runnerRelativePath = "Spikes/jidoka-local-spikes.mjs"
  static let runnerSHA256 = "59a4b657195d443c49f9211d25978dcdb29e64da0baea7e172c59ff5605b32e7"
  static let maximumOutputBytes = 1_048_576
}

enum LocalSpikeCLIError: Error, Equatable {
  case invalidNodeRuntime
  case invalidOutput
  case invalidPackagedRunner
  case runnerFailed(Int32)
  case timeout
  case unsafeWorkspace
}

enum LocalSpikeCLI {
  static func run(arguments: [String]) throws -> Data {
    let command = try LocalSpikeCommand.parse(arguments)
    let runnerURL = try packagedRunner()
    let workspaceURL = try createTemporaryWorkspace()
    defer {
      try? removeTemporaryWorkspace(workspaceURL)
    }
    return try executeRunner(
      runnerURL: runnerURL,
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

  private static func packagedRunner() throws -> URL {
    guard let resources = Bundle.main.resourceURL else {
      throw LocalSpikeCLIError.invalidPackagedRunner
    }
    let runner = resources.appendingPathComponent(
      LocalSpikeCLIConstants.runnerRelativePath,
      isDirectory: false
    ).standardizedFileURL
    let resolvedResources = resources.resolvingSymlinksInPath().path
    let resolvedRunner = runner.resolvingSymlinksInPath().path
    let values = try runner.resourceValues(forKeys: [
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard
      resolvedRunner.hasPrefix(resolvedResources + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink == false,
      let fileSize = values.fileSize,
      fileSize <= LocalSpikeCLIConstants.maximumOutputBytes
    else {
      throw LocalSpikeCLIError.invalidPackagedRunner
    }
    let data = try Data(contentsOf: runner, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == LocalSpikeCLIConstants.runnerSHA256 else {
      throw LocalSpikeCLIError.invalidPackagedRunner
    }
    return runner
  }

  private static func createTemporaryWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-code-local-workspace-\(UUID().uuidString.lowercased())",
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
      workspace.lastPathComponent.hasPrefix("jidoka-code-local-workspace-"),
      values.isDirectory == true,
      values.isSymbolicLink == false
    else {
      throw LocalSpikeCLIError.unsafeWorkspace
    }
    try FileManager.default.removeItem(at: workspace)
  }

  private static func executeRunner(
    runnerURL: URL,
    workspaceURL: URL,
    command: LocalSpikeCommand
  ) throws -> Data {
    let nodeValues = try LocalSpikeCLIConstants.nodeURL.resourceValues(forKeys: [
      .isExecutableKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard
      nodeValues.isExecutable == true,
      nodeValues.isRegularFile == true,
      nodeValues.isSymbolicLink == false
    else {
      throw LocalSpikeCLIError.invalidNodeRuntime
    }

    guard let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
      !developerDirectory.isEmpty
    else {
      throw LocalSpikeCLIError.invalidNodeRuntime
    }
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let termination = DispatchSemaphore(value: 0)
    process.executableURL = LocalSpikeCLIConstants.nodeURL
    process.arguments = [runnerURL.path, command.rawValue, workspaceURL.path]
    process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    process.environment = [
      "DEVELOPER_DIR": developerDirectory,
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "\(developerDirectory)/usr/bin:/usr/bin:/bin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in termination.signal() }
    try process.run()

    let timeout: DispatchTimeInterval = command == .gitTransport ? .seconds(240) : .seconds(60)
    guard termination.wait(timeout: .now() + timeout) == .success else {
      process.terminate()
      if termination.wait(timeout: .now() + .seconds(8)) != .success {
        kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + .seconds(2))
      }
      throw LocalSpikeCLIError.timeout
    }

    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw LocalSpikeCLIError.runnerFailed(process.terminationStatus)
    }
    guard
      errorOutput.isEmpty,
      !output.isEmpty,
      output.count <= LocalSpikeCLIConstants.maximumOutputBytes,
      output.filter({ $0 == 0x0A }).count == 1,
      (try? JSONSerialization.jsonObject(with: output)) is [String: Any]
    else {
      throw LocalSpikeCLIError.invalidOutput
    }
    return output
  }
}
