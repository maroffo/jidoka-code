import CryptoKit
import Foundation
import JidokaCodeCore

private enum LocalSpikeCLIConstants {
  static let runnerRelativePath = "Spikes/jidoka-local-spikes.mjs"
  static let runnerSHA256 = "c16e11605ecb8b818bd51abbdbe824414d9c2d19a1d010d3265c48c99cf05ecf"
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
    let runtime = try packagedRuntime()
    let workspaceURL = try createTemporaryWorkspace()
    defer {
      try? removeTemporaryWorkspace(workspaceURL)
    }
    let finalRuntime = try packagedRuntime()
    guard finalRuntime.releaseIdentity == runtime.releaseIdentity else {
      throw LocalSpikeCLIError.invalidNodeRuntime
    }
    return try executeRunner(
      runnerURL: runnerURL,
      runtime: finalRuntime,
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

  private static func packagedRuntime() throws -> PiResolvedRuntime {
    guard let resources = Bundle.main.resourceURL else {
      throw LocalSpikeCLIError.invalidPackagedRunner
    }
    let runtimeRoot = resources.appendingPathComponent(
      ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
      isDirectory: true
    )
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      return try ReleaseOwnedPiRuntimeVerifier.verifyAdHocBundle(
        runtimeRoot: runtimeRoot,
        containingApplicationURL: Bundle.main.bundleURL
      )
    #else
      return try ReleaseOwnedPiRuntimeBoundaryAuthority.rpcProcess(
        using: ReleaseOwnedPiRuntimeResolver(
          runtimeRoot: runtimeRoot,
          containingApplicationURL: Bundle.main.bundleURL
        )
      )
    #endif
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
    runtime: PiResolvedRuntime,
    workspaceURL: URL,
    command: LocalSpikeCommand
  ) throws -> Data {
    let nodeURL = runtime.nodeURL
    guard let releaseIdentity = runtime.releaseIdentity else {
      throw LocalSpikeCLIError.invalidNodeRuntime
    }
    let nodeValues = try nodeURL.resourceValues(forKeys: [
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
    let result = try BoundedProcessRunner().runSynchronously(
      GitProcessRequest(
        executable: nodeURL,
        arguments: [runnerURL.path, command.rawValue, workspaceURL.path],
        workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
        environment: [
          "DEVELOPER_DIR": developerDirectory,
          "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
          "JIDOKA_RELEASE_MANIFEST_SHA256": releaseIdentity.manifestSHA256,
          "JIDOKA_RELEASE_RUNTIME_ROOT": releaseIdentity.canonicalRoot,
          "PATH": "\(developerDirectory)/usr/bin:/usr/bin:/bin",
          "TMPDIR": FileManager.default.temporaryDirectory.path,
        ],
        timeoutSeconds: command == .gitTransport ? 240 : 60,
        maximumOutputBytes: LocalSpikeCLIConstants.maximumOutputBytes
      )
    )
    guard !result.timedOut else { throw LocalSpikeCLIError.timeout }
    guard !result.outputLimitExceeded else { throw LocalSpikeCLIError.invalidOutput }
    guard result.exitCode == 0, result.terminationSignal == nil else {
      throw LocalSpikeCLIError.runnerFailed(
        result.exitCode ?? 128 + (result.terminationSignal ?? 0)
      )
    }
    let output = result.stdout
    let errorOutput = result.stderr
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
