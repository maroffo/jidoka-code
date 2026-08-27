import CryptoKit
import Darwin
import Foundation

public enum PiWorkflowKind: String, CaseIterable, Codable, Sendable {
  case pullRequestReview = "pr-review"
  case issueTriage = "issue-triage"
  case planning
  case orchestration
}

public enum PiWorkflowRole: String, CaseIterable, Codable, Sendable {
  case triage
  case writer
  case architecture
  case security
  case test
  case synthesis
}

public enum PiWorkflowToolPolicy: String, Codable, Sendable {
  case readOnly = "read-only"
  case writer
}

public enum PiWorkflowResourceError: Error, Equatable, Sendable {
  case unsafeResourceRoot
  case missingManifest
  case manifestDigestMismatch
  case malformedManifest
  case unexpectedResourceInventory
  case unsafeResource(String)
  case resourceDigestMismatch(String)
  case invalidWorkflowRole
  case invalidRuntimeConfiguration
  case unsafeConfigurationDestination
  case configurationAlreadyExists
  case configurationWriteFailed(Int32)
}

public struct PiWorkflowResourceCatalog: Equatable, Sendable {
  public static let contractVersion = "1"
  public static let workflowManifestSHA256 =
    "230c9a45b9dd53443837166c6e8b60adac67d3bfeb32249de8ca5228f1e1357d"
  public static let readOnlyToolNames = [
    "jidoka_code_preflight",
    "jidoka_code_read",
    "jidoka_code_result",
    "jidoka_code_workspace_query",
  ]
  public static let writerToolNames =
    (readOnlyToolNames + ["jidoka_code_edit", "jidoka_code_write"]).sorted()
  public static let expectedResourcePaths: Set<String> = [
    "extensions/jidoka-code.ts",
    "extensions/jidoka-deny-user-bash.js",
    "runtime/jidoka-extension-contract.mjs",
    "runtime/node-runtime-builds.json",
    "runtime/pi-runtime-builds.json",
    "skills/jidoka-code-issue-triage/SKILL.md",
    "skills/jidoka-code-orchestrate/SKILL.md",
    "skills/jidoka-code-plan/SKILL.md",
    "skills/jidoka-code-pr-review/SKILL.md",
    "skills/jidoka-code-review-architecture/SKILL.md",
    "skills/jidoka-code-review-security/SKILL.md",
    "skills/jidoka-code-review-test/SKILL.md",
    "skills/jidoka-code-synthesize/SKILL.md",
  ]

  public let resourceRoot: URL
  public let manifestURL: URL
  public let manifestSHA256: String
  public let resourceSHA256: [String: String]

  public init(
    resourceRoot: URL,
    manifestURL: URL,
    manifestSHA256: String,
    resourceSHA256: [String: String]
  ) {
    self.resourceRoot = resourceRoot
    self.manifestURL = manifestURL
    self.manifestSHA256 = manifestSHA256
    self.resourceSHA256 = resourceSHA256
  }

  public static func inspect(resourceRoot requestedRoot: URL) throws -> Self {
    guard requestedRoot.isFileURL, requestedRoot.path.hasPrefix("/") else {
      throw PiWorkflowResourceError.unsafeResourceRoot
    }
    let root = requestedRoot.standardizedFileURL
    let rootValues = try root.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard rootValues.isDirectory == true,
      rootValues.isSymbolicLink != true,
      root.resolvingSymlinksInPath().path == root.path
    else {
      throw PiWorkflowResourceError.unsafeResourceRoot
    }
    let manifestURL = root.appendingPathComponent("workflow-resources.json")
    let manifestData: Data
    do {
      manifestData = try readBoundedRegularFile(
        relativePath: "workflow-resources.json",
        in: root
      )
    } catch {
      throw PiWorkflowResourceError.missingManifest
    }
    let manifestDigest = sha256(manifestData)
    guard manifestDigest == workflowManifestSHA256 else {
      throw PiWorkflowResourceError.manifestDigestMismatch
    }
    guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      Set(manifest.keys) == Set(["contractVersion", "resources", "schemaVersion"]),
      manifest["schemaVersion"] as? Int == 1,
      manifest["contractVersion"] as? String == contractVersion,
      let resources = manifest["resources"] as? [String: String],
      Set(resources.keys) == expectedResourcePaths,
      resources.values.allSatisfy(GitHubInputValidation.validSHA256)
    else {
      throw PiWorkflowResourceError.malformedManifest
    }
    for relativePath in expectedResourcePaths.sorted() {
      guard validRelativeResourcePath(relativePath) else {
        throw PiWorkflowResourceError.unexpectedResourceInventory
      }
      let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
      guard fileURL.path.hasPrefix(root.path + "/") else {
        throw PiWorkflowResourceError.unsafeResource(relativePath)
      }
      let data: Data
      do {
        data = try readBoundedRegularFile(relativePath: relativePath, in: root)
      } catch {
        throw PiWorkflowResourceError.unsafeResource(relativePath)
      }
      guard sha256(data) == resources[relativePath] else {
        throw PiWorkflowResourceError.resourceDigestMismatch(relativePath)
      }
    }
    return PiWorkflowResourceCatalog(
      resourceRoot: root,
      manifestURL: manifestURL,
      manifestSHA256: manifestDigest,
      resourceSHA256: resources
    )
  }

  public var blockerExtensionURL: URL {
    resourceRoot.appendingPathComponent("extensions/jidoka-deny-user-bash.js")
  }

  public var runtimeExtensionURL: URL {
    resourceRoot.appendingPathComponent("extensions/jidoka-code.ts")
  }

  public func skillURLs(workflow: PiWorkflowKind, role: PiWorkflowRole) throws -> [URL] {
    guard Self.valid(role: role, for: workflow) else {
      throw PiWorkflowResourceError.invalidWorkflowRole
    }
    let primary: String
    switch workflow {
    case .pullRequestReview: primary = "jidoka-code-pr-review"
    case .issueTriage: primary = "jidoka-code-issue-triage"
    case .planning: primary = "jidoka-code-plan"
    case .orchestration: primary = "jidoka-code-orchestrate"
    }
    var names = [primary]
    switch role {
    case .architecture: names.append("jidoka-code-review-architecture")
    case .security: names.append("jidoka-code-review-security")
    case .test: names.append("jidoka-code-review-test")
    case .synthesis: names.append("jidoka-code-synthesize")
    case .triage, .writer: break
    }
    return names.map {
      resourceRoot.appendingPathComponent("skills/\($0)/SKILL.md", isDirectory: false)
    }
  }

  public func expectedCommandProvenance(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole
  ) throws -> [PiRPCCommandProvenance] {
    var commands = [
      PiRPCCommandProvenance(
        name: "jidoka-code-preflight",
        source: "extension",
        path: runtimeExtensionURL.path,
        scope: "temporary",
        origin: "top-level"
      )
    ]
    for skillURL in try skillURLs(workflow: workflow, role: role) {
      commands.append(
        PiRPCCommandProvenance(
          name: "skill:\(skillURL.deletingLastPathComponent().lastPathComponent)",
          source: "skill",
          path: skillURL.path,
          scope: "temporary",
          origin: "top-level"
        )
      )
    }
    commands.append(
      PiRPCCommandProvenance(
        name: "llama",
        source: "extension",
        path: "<inline:llama.cpp>",
        scope: "temporary",
        origin: "top-level"
      )
    )
    return commands
  }

  public static func valid(role: PiWorkflowRole, for workflow: PiWorkflowKind) -> Bool {
    switch workflow {
    case .pullRequestReview:
      return [.architecture, .security, .test, .synthesis].contains(role)
    case .issueTriage:
      return role == .triage
    case .planning, .orchestration:
      return [.writer, .architecture, .security, .test, .synthesis].contains(role)
    }
  }

  public static func toolPolicy(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole
  ) throws -> PiWorkflowToolPolicy {
    guard valid(role: role, for: workflow) else {
      throw PiWorkflowResourceError.invalidWorkflowRole
    }
    if role == .writer, workflow == .planning || workflow == .orchestration {
      return .writer
    }
    return .readOnly
  }

  public static func activeToolNames(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole
  ) throws -> [String] {
    try toolPolicy(workflow: workflow, role: role) == .writer
      ? writerToolNames
      : readOnlyToolNames
  }

  private static func validRelativeResourcePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
      !value.contains("\u{0}")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  fileprivate static func readBoundedRegularFile(
    relativePath: String,
    in root: URL
  ) throws -> Data {
    guard validRelativeResourcePath(relativePath),
      (try? PiTUIFileProtocol.safeRegularFile(
        root.appendingPathComponent(relativePath, isDirectory: false)
      )) == true
    else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    let components = relativePath.split(separator: "/").map(String.init)
    let rootDescriptor = open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    var directoryDescriptors = [rootDescriptor]
    defer {
      for descriptor in directoryDescriptors.reversed() {
        _ = close(descriptor)
      }
    }
    for component in components.dropLast() {
      let descriptor = openat(
        directoryDescriptors[directoryDescriptors.count - 1],
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        throw PiWorkflowResourceError.unsafeResource(relativePath)
      }
      directoryDescriptors.append(descriptor)
    }
    guard let finalComponent = components.last else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    let descriptor = openat(
      directoryDescriptors[directoryDescriptors.count - 1],
      finalComponent,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    defer { _ = close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_nlink == 1,
      before.st_size >= 0,
      before.st_size <= 1_048_576
    else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
    var offset = 0
    while offset < bytes.count {
      let remaining = bytes.count - offset
      let count = bytes.withUnsafeMutableBytes { buffer in
        read(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          remaining
        )
      }
      guard count > 0 else {
        throw PiWorkflowResourceError.unsafeResource(relativePath)
      }
      offset += count
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mode == after.st_mode,
      before.st_nlink == after.st_nlink
    else {
      throw PiWorkflowResourceError.unsafeResource(relativePath)
    }
    return Data(bytes)
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct PiTUIResourceCatalog: Equatable, Sendable {
  public static let manifestSHA256 =
    "5392fec5eb544dbe0c721692440e8445604d3c05509a39b450f2bb964245f07f"
  public static let expectedResourcePaths: Set<String> = [
    "extensions/jidoka-tui-runtime.ts",
    "runtime/jidoka-tui-contract.mjs",
  ]

  public let workflowResources: PiWorkflowResourceCatalog
  public let manifestURL: URL
  public let manifestSHA256: String
  public let resourceSHA256: [String: String]

  public static func inspect(resourceRoot: URL) throws -> Self {
    let workflowResources = try PiWorkflowResourceCatalog.inspect(resourceRoot: resourceRoot)
    let manifestURL = workflowResources.resourceRoot.appendingPathComponent("tui-resources.json")
    let manifestData: Data
    do {
      manifestData = try PiWorkflowResourceCatalog.readBoundedRegularFile(
        relativePath: "tui-resources.json",
        in: workflowResources.resourceRoot
      )
    } catch {
      throw PiWorkflowResourceError.missingManifest
    }
    let observedDigest = PiWorkflowResourceCatalog.sha256(manifestData)
    guard observedDigest == manifestSHA256,
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      Set(manifest.keys) == Set(["contractVersion", "resources", "schemaVersion"]),
      manifest["schemaVersion"] as? Int == 1,
      manifest["contractVersion"] as? String == PiWorkflowResourceCatalog.contractVersion,
      let resources = manifest["resources"] as? [String: String],
      Set(resources.keys) == expectedResourcePaths,
      resources.values.allSatisfy(GitHubInputValidation.validSHA256)
    else {
      throw PiWorkflowResourceError.manifestDigestMismatch
    }
    for relativePath in expectedResourcePaths.sorted() {
      let data = try PiWorkflowResourceCatalog.readBoundedRegularFile(
        relativePath: relativePath,
        in: workflowResources.resourceRoot
      )
      guard PiWorkflowResourceCatalog.sha256(data) == resources[relativePath] else {
        throw PiWorkflowResourceError.resourceDigestMismatch(relativePath)
      }
    }
    return Self(
      workflowResources: workflowResources,
      manifestURL: manifestURL,
      manifestSHA256: observedDigest,
      resourceSHA256: resources
    )
  }

  public var tuiRuntimeExtensionURL: URL {
    workflowResources.resourceRoot.appendingPathComponent("extensions/jidoka-tui-runtime.ts")
  }

  public var tuiContractURL: URL {
    workflowResources.resourceRoot.appendingPathComponent("runtime/jidoka-tui-contract.mjs")
  }
}

public struct PiWorkflowRuntimeConfiguration: Equatable, Sendable {
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let nonce: String
  public let artifactSHA256: String
  public let allowedCommandIDs: [String]
  public let allowedWritePaths: [String]
  public let workspaceRoot: URL
  public let resources: PiWorkflowResourceCatalog
  public let toolPolicy: PiWorkflowToolPolicy

  public init(
    workflow: PiWorkflowKind,
    role: PiWorkflowRole,
    nonce: String,
    artifactSHA256: String,
    allowedCommandIDs: [String],
    allowedWritePaths: [String],
    workspaceRoot: URL,
    resources: PiWorkflowResourceCatalog
  ) throws {
    let toolPolicy = try PiWorkflowResourceCatalog.toolPolicy(workflow: workflow, role: role)
    guard nonce.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil,
      GitHubInputValidation.validSHA256(artifactSHA256),
      allowedCommandIDs.count <= 64,
      Set(allowedCommandIDs).count == allowedCommandIDs.count,
      allowedCommandIDs.allSatisfy(Self.validIdentifier),
      allowedWritePaths.count <= 256,
      Set(allowedWritePaths).count == allowedWritePaths.count,
      allowedWritePaths.allSatisfy(Self.validRelativeWorkspacePath),
      toolPolicy == .writer || allowedWritePaths.isEmpty,
      workspaceRoot.isFileURL,
      workspaceRoot.path.hasPrefix("/")
    else {
      throw PiWorkflowResourceError.invalidRuntimeConfiguration
    }
    let workspaceValues = try workspaceRoot.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let workspaceAttributes = try FileManager.default.attributesOfItem(
      atPath: workspaceRoot.path
    )
    let workspacePermissions =
      (workspaceAttributes[.posixPermissions] as? NSNumber)?.intValue
    let workspaceOwner =
      (workspaceAttributes[.ownerAccountID] as? NSNumber)?.uint32Value
    guard workspaceValues.isDirectory == true,
      workspaceValues.isSymbolicLink != true,
      workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
        == workspaceRoot.standardizedFileURL.path,
      workspacePermissions.map({ $0 & 0o077 == 0 }) == true,
      workspaceOwner == getuid()
    else {
      throw PiWorkflowResourceError.invalidRuntimeConfiguration
    }
    self.workflow = workflow
    self.role = role
    self.nonce = nonce
    self.artifactSHA256 = artifactSHA256
    self.allowedCommandIDs = allowedCommandIDs.sorted()
    self.allowedWritePaths = allowedWritePaths.sorted()
    self.workspaceRoot = workspaceRoot.standardizedFileURL
    self.resources = resources
    self.toolPolicy = toolPolicy
  }

  public func encoded() throws -> Data {
    let object: [String: Any] = [
      "allowedCommandIDs": allowedCommandIDs,
      "allowedWritePaths": allowedWritePaths,
      "artifactSHA256": artifactSHA256,
      "contractVersion": PiWorkflowResourceCatalog.contractVersion,
      "nonce": nonce,
      "resourceManifestPath": resources.manifestURL.path,
      "resourceManifestSHA256": resources.manifestSHA256,
      "resourceRoot": resources.resourceRoot.path,
      "role": role.rawValue,
      "schemaVersion": 1,
      "toolPolicy": toolPolicy.rawValue,
      "workflow": workflow.rawValue,
      "workspaceRoot": workspaceRoot.path,
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
  }

  public static func load(from source: URL) throws -> Self {
    let data: Data
    do {
      data = try PiTUIFileProtocol.readPrivateFile(source, maximumBytes: 1_048_576)
    } catch {
      throw PiWorkflowResourceError.invalidRuntimeConfiguration
    }
    guard data.last == 0x0A,
      let object = try? JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys)
        == Set([
          "allowedCommandIDs", "allowedWritePaths", "artifactSHA256", "contractVersion",
          "nonce", "resourceManifestPath", "resourceManifestSHA256", "resourceRoot", "role",
          "schemaVersion", "toolPolicy", "workflow", "workspaceRoot",
        ]),
      object["schemaVersion"] as? Int == 1,
      object["contractVersion"] as? String == PiWorkflowResourceCatalog.contractVersion,
      let workflowValue = object["workflow"] as? String,
      let workflow = PiWorkflowKind(rawValue: workflowValue),
      let roleValue = object["role"] as? String,
      let role = PiWorkflowRole(rawValue: roleValue),
      let nonce = object["nonce"] as? String,
      let artifactSHA256 = object["artifactSHA256"] as? String,
      let allowedCommandIDs = object["allowedCommandIDs"] as? [String],
      let allowedWritePaths = object["allowedWritePaths"] as? [String],
      let workspacePath = object["workspaceRoot"] as? String,
      let resourceRootPath = object["resourceRoot"] as? String,
      let manifestPath = object["resourceManifestPath"] as? String,
      let manifestSHA256 = object["resourceManifestSHA256"] as? String,
      let toolPolicyValue = object["toolPolicy"] as? String
    else {
      throw PiWorkflowResourceError.invalidRuntimeConfiguration
    }
    let resources = try PiWorkflowResourceCatalog.inspect(
      resourceRoot: URL(fileURLWithPath: resourceRootPath, isDirectory: true)
    )
    let configuration = try Self(
      workflow: workflow,
      role: role,
      nonce: nonce,
      artifactSHA256: artifactSHA256,
      allowedCommandIDs: allowedCommandIDs,
      allowedWritePaths: allowedWritePaths,
      workspaceRoot: URL(fileURLWithPath: workspacePath, isDirectory: true),
      resources: resources
    )
    guard manifestPath == resources.manifestURL.path,
      manifestSHA256 == resources.manifestSHA256,
      toolPolicyValue == configuration.toolPolicy.rawValue,
      try configuration.encoded() == data
    else {
      throw PiWorkflowResourceError.invalidRuntimeConfiguration
    }
    return configuration
  }

  public func write(to destination: URL) throws {
    do {
      try PiTUIFileProtocol.createPrivateFile(data: encoded(), at: destination)
    } catch PiTUIRuntimeError.fileAlreadyExists {
      throw PiWorkflowResourceError.configurationAlreadyExists
    } catch let error as PiTUIRuntimeError {
      switch error {
      case .unsafePath:
        throw PiWorkflowResourceError.unsafeConfigurationDestination
      case .writeFailed(let code):
        throw PiWorkflowResourceError.configurationWriteFailed(code)
      default:
        throw PiWorkflowResourceError.invalidRuntimeConfiguration
      }
    }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    value.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil
  }

  private static func validRelativeWorkspacePath(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 1_024, !value.hasPrefix("/"),
      !value.contains("\\"), !value.contains("\u{0}")
    else {
      return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      let lowered = $0.lowercased()
      return !$0.isEmpty && $0 != "." && $0 != ".."
        && lowered != ".git" && lowered != ".pi" && lowered != ".agents"
    }
  }
}
