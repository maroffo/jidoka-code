import CryptoKit
import Foundation
import JidokaCodeCore

private enum PiProbeCLIConstants {
  static let runnerRelativePath = "runtime/pi-rpc-profile-probe.mjs"
  static let runnerSHA256 = "085fc4f44e77e051c05e2e68c4f755748ebfca227eb3b6782c1e0e3cce727b9d"
  static let runtimeAttestationRelativePath = "runtime/pi-runtime-attestation.mjs"
  static let runtimeAttestationSHA256 =
    "d062dad354b15d8bc0dc377e8aa6835d0eaf884cf68925dad4b8aace5d0cd413"
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

enum ReleaseRuntimeProbeCLI {
  #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
    static func verifyStaged(arguments: [String]) throws -> Data {
      guard arguments.count == 1 else { throw PiProbeCLIError.invalidNodeRuntime }
      let root = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
      let runtime = try ReleaseOwnedPiRuntimeVerifier.verifyStagedInput(runtimeRoot: root)
      return try report(runtime)
    }

    static func verifyAdHocBundle() throws -> Data {
      guard let resources = Bundle.main.resourceURL else {
        throw PiProbeCLIError.invalidNodeRuntime
      }
      let runtime = try ReleaseOwnedPiRuntimeVerifier.verifyAdHocBundle(
        runtimeRoot: resources.appendingPathComponent(
          ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
          isDirectory: true
        ),
        containingApplicationURL: Bundle.main.bundleURL
      )
      return try report(runtime)
    }

    static func verifyDeveloperIDBundle(arguments: [String]) throws -> Data {
      guard arguments.count == 1 else { throw PiProbeCLIError.invalidNodeRuntime }
      let application = URL(
        fileURLWithPath: arguments[0],
        isDirectory: true
      ).standardizedFileURL
      let runtime = try ReleaseOwnedPiRuntimeVerifier.verifyDeveloperIDBundle(
        runtimeRoot:
          application
          .appendingPathComponent("Contents", isDirectory: true)
          .appendingPathComponent("Resources", isDirectory: true)
          .appendingPathComponent(
            ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
            isDirectory: true
          ),
        containingApplicationURL: application
      )
      return try report(runtime)
    }
  #endif

  static func verifyProductionBundle() throws -> Data {
    guard let resources = Bundle.main.resourceURL else {
      throw PiProbeCLIError.invalidNodeRuntime
    }
    let resolver = ReleaseOwnedPiRuntimeResolver(
      runtimeRoot: resources.appendingPathComponent(
        ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
        isDirectory: true
      ),
      containingApplicationURL: Bundle.main.bundleURL
    )
    let runtime = try ReleaseOwnedPiRuntimeBoundaryAuthority.applicationStartup(using: resolver)
    return try report(runtime)
  }

  private static func report(_ runtime: PiResolvedRuntime) throws -> Data {
    guard let identity = runtime.releaseIdentity else {
      throw PiProbeCLIError.invalidNodeRuntime
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "manifestSHA256": identity.manifestSHA256,
        "runtimeID": identity.runtimeID,
        "runtimeIdentitySHA256": identity.authoritySHA256,
        "runtimeTreeSHA256": identity.releaseContentSHA256,
        "schemaVersion": 2,
      ],
      options: [.sortedKeys, .withoutEscapingSlashes]
    ) + Data([0x0A])
  }
}

enum PiProbeCLI {
  static func run(arguments: [String]) throws -> Data {
    let command = try PiProbeCommand.parse(arguments)
    let resourceRoot = try packagedResourceRoot()
    let runnerURL = try packagedRunner(in: resourceRoot)
    let runtime = try releaseRuntime()
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
    let finalRuntime = try releaseRuntime()
    guard finalRuntime.releaseIdentity == runtime.releaseIdentity else {
      throw PiProbeCLIError.invalidNodeRuntime
    }
    return try executeRunner(
      runnerURL: runnerURL,
      runtime: finalRuntime,
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

  private static func releaseRuntime() throws -> PiResolvedRuntime {
    guard let resources = Bundle.main.resourceURL else {
      throw PiProbeCLIError.invalidNodeRuntime
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

  private static func commandTimeout(_ command: PiProbeCommand) -> TimeInterval {
    switch command {
    case .profile:
      return 150
    case .preflight, .timeout, .ledgerPreflight:
      return 30
    }
  }

  private static func executeRunner(
    runnerURL: URL,
    runtime: PiResolvedRuntime,
    workspaceURL: URL,
    arguments: [String],
    timeout: TimeInterval
  ) throws -> Data {
    let nodeURL = runtime.nodeURL
    guard let releaseIdentity = runtime.releaseIdentity else {
      throw PiProbeCLIError.invalidNodeRuntime
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
      throw PiProbeCLIError.invalidNodeRuntime
    }

    let result = try BoundedProcessRunner().runSynchronously(
      GitProcessRequest(
        executable: nodeURL,
        arguments: [runnerURL.path] + arguments,
        workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
        environment: [
          "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
          "JIDOKA_PI_WORKSPACE": workspaceURL.path,
          "JIDOKA_RELEASE_MANIFEST_SHA256": releaseIdentity.manifestSHA256,
          "JIDOKA_RELEASE_RUNTIME_ROOT": releaseIdentity.canonicalRoot,
          "PATH": "/usr/bin:/bin",
          "TMPDIR": FileManager.default.temporaryDirectory.path,
        ],
        timeoutSeconds: timeout,
        maximumOutputBytes: PiProbeCLIConstants.maximumOutputBytes
      )
    )
    guard !result.timedOut else { throw PiProbeCLIError.timeout }
    guard !result.outputLimitExceeded else { throw PiProbeCLIError.invalidOutput }
    guard result.exitCode == 0, result.terminationSignal == nil else {
      throw PiProbeCLIError.runnerFailed(
        result.exitCode ?? 128 + (result.terminationSignal ?? 0)
      )
    }
    let output = result.stdout
    let errorOutput = result.stderr
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
