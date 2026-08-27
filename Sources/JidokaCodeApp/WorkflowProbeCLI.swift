import CryptoKit
import Foundation
import JidokaCodeCore

private enum WorkflowProbeCLIConstants {
  static let runnerRelativePath = "runtime/pi-rpc-workflow-probe.mjs"
  static let runnerSHA256 = "1c04d87ddb1f235c144001cd1d59fb3d80a9ad788ac1a8a33a79d12e1ce8f80b"
  static let runtimeAttestationRelativePath = "runtime/pi-runtime-attestation.mjs"
  static let runtimeAttestationSHA256 =
    "d062dad354b15d8bc0dc377e8aa6835d0eaf884cf68925dad4b8aace5d0cd413"
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
    let runtime = try releaseRuntime()
    let ledgerURL = try canonicalProviderLedgerURL()
    let workspaceURL = try createTemporaryWorkspace()
    defer {
      try? removeTemporaryWorkspace(workspaceURL)
    }
    let finalRuntime = try releaseRuntime()
    guard finalRuntime.releaseIdentity == runtime.releaseIdentity else {
      throw WorkflowProbeCLIError.invalidNodeRuntime
    }
    return try executeRunner(
      runnerURL: runnerURL,
      runtime: finalRuntime,
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

  private static func releaseRuntime() throws -> PiResolvedRuntime {
    guard let resources = Bundle.main.resourceURL else {
      throw WorkflowProbeCLIError.invalidNodeRuntime
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
    _ = try packagedRuntimeFile(
      in: resourceRoot,
      relativePath: WorkflowProbeCLIConstants.runtimeAttestationRelativePath,
      expectedSHA256: WorkflowProbeCLIConstants.runtimeAttestationSHA256
    )
    return try packagedRuntimeFile(
      in: resourceRoot,
      relativePath: WorkflowProbeCLIConstants.runnerRelativePath,
      expectedSHA256: WorkflowProbeCLIConstants.runnerSHA256
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
      fileSize <= WorkflowProbeCLIConstants.maximumOutputBytes
    else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
    }
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA256 else {
      throw WorkflowProbeCLIError.invalidPackagedRunner
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
    runtime: PiResolvedRuntime,
    resourceRoot: URL,
    ledgerURL: URL,
    workspaceURL: URL,
    command: WorkflowProbeCommand
  ) throws -> Data {
    let nodeURL = runtime.nodeURL
    guard let releaseIdentity = runtime.releaseIdentity else {
      throw WorkflowProbeCLIError.invalidNodeRuntime
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
      throw WorkflowProbeCLIError.invalidNodeRuntime
    }

    let result = try BoundedProcessRunner().runSynchronously(
      GitProcessRequest(
        executable: nodeURL,
        arguments: [
          runnerURL.path, command.rawValue, resourceRoot.path, ledgerURL.path,
        ],
        workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
        environment: [
          "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
          "JIDOKA_RELEASE_MANIFEST_SHA256": releaseIdentity.manifestSHA256,
          "JIDOKA_RELEASE_RUNTIME_ROOT": releaseIdentity.canonicalRoot,
          "JIDOKA_WORKFLOW_WORKSPACE": workspaceURL.path,
          "PATH": "/usr/bin:/bin",
          "TMPDIR": FileManager.default.temporaryDirectory.path,
        ],
        timeoutSeconds: command == .live ? 2_100 : 180,
        maximumOutputBytes: WorkflowProbeCLIConstants.maximumOutputBytes
      )
    )
    guard !result.timedOut else { throw WorkflowProbeCLIError.timeout }
    guard !result.outputLimitExceeded else { throw WorkflowProbeCLIError.invalidOutput }
    guard result.exitCode == 0, result.terminationSignal == nil else {
      throw WorkflowProbeCLIError.runnerFailed(
        result.exitCode ?? 128 + (result.terminationSignal ?? 0)
      )
    }
    let output = result.stdout
    let errorOutput = result.stderr
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
