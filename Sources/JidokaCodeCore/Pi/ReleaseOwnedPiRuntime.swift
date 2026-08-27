import CryptoKit
import Darwin
import Foundation
import Security

public struct PiReleaseRuntimeIdentity: Codable, Equatable, Sendable {
  public let runtimeID: String
  public let manifestSHA256: String
  public let canonicalRoot: String
  public let rootDevice: UInt64
  public let rootInode: UInt64
  public let nodeCodeDirectorySHA256: String
  public let piPackageTreeSHA256: String

  public init(
    runtimeID: String,
    manifestSHA256: String,
    canonicalRoot: String,
    rootDevice: UInt64,
    rootInode: UInt64,
    nodeCodeDirectorySHA256: String,
    piPackageTreeSHA256: String
  ) throws {
    guard runtimeID.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{7,127}$/) != nil,
      GitHubInputValidation.validSHA256(manifestSHA256),
      canonicalRoot.hasPrefix("/"),
      rootDevice > 0,
      rootInode > 0,
      GitHubInputValidation.validSHA256(nodeCodeDirectorySHA256),
      GitHubInputValidation.validSHA256(piPackageTreeSHA256)
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime identity is invalid"
      )
    }
    self.runtimeID = runtimeID
    self.manifestSHA256 = manifestSHA256
    self.canonicalRoot = canonicalRoot
    self.rootDevice = rootDevice
    self.rootInode = rootInode
    self.nodeCodeDirectorySHA256 = nodeCodeDirectorySHA256
    self.piPackageTreeSHA256 = piPackageTreeSHA256
  }

  public var authoritySHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return Self.sha256(data)
  }

  public func containingApplicationURL() throws -> URL {
    let root = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
    guard root.lastPathComponent == "PiRuntime",
      root.deletingLastPathComponent().lastPathComponent == "Resources"
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime is outside the application bundle layout"
      )
    }
    let contents = root.deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents" else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime is outside the application bundle layout"
      )
    }
    let application = contents.deletingLastPathComponent()
    guard application.pathExtension == "app" else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime is outside the application bundle layout"
      )
    }
    return application
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

#if DEBUG
  enum ReleaseOwnedPiRuntimeSyntheticSignaturePolicy: Equatable, Sendable {
    case adHoc
    case production
  }

  struct ReleaseOwnedPiRuntimeSyntheticSignatureEvidence: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String?
    let codeDirectorySHA256: String
    let entitlementSHA256: String
    let hardenedRuntime: Bool
  }

  enum ReleaseOwnedPiRuntimeValidationCheckpoint: Equatable, Sendable {
    case packageDirectoryOpened(String)
    case packageRegularFileOpened(String)
    case packageLinkTargetOpened(link: String, target: String, isFinal: Bool)
    case packageTreeInspected
  }
#endif

public struct ReleaseOwnedPiRuntimeResolver: PiRuntimeResolving, Sendable {
  public static let expectedManifestSHA256 =
    "fe15573a58a4604a3695b092ba8b07ae2432da7b7f07743a8d54a4421ab3aa83"
  public static let runtimeDirectoryName = "PiRuntime"

  private let runtimeRoot: URL
  private let runtimeRootIsDirectDirectory: Bool
  private let expectedManifestSHA256: String
  private let validationMode: ValidationMode
  #if DEBUG
    private let testingValidationHook:
      (@Sendable (ReleaseOwnedPiRuntimeValidationCheckpoint) throws -> Void)?
  #endif

  public init(runtimeRoot: URL, containingApplicationURL: URL) {
    let root = Self.canonicalRuntimeRoot(runtimeRoot)
    self.runtimeRoot = root.url
    runtimeRootIsDirectDirectory = root.directDirectory
    expectedManifestSHA256 = Self.expectedManifestSHA256
    let applicationPath = Self.canonicalExistingPath(containingApplicationURL.path)
    var applicationMetadata = stat()
    let applicationIsDirectDirectory =
      lstat(containingApplicationURL.path, &applicationMetadata) == 0
      && applicationMetadata.st_mode & S_IFMT == S_IFDIR
      && applicationPath == containingApplicationURL.path
    validationMode = .production(
      ProductionContext(
        application: URL(
          fileURLWithPath: applicationPath ?? containingApplicationURL.path,
          isDirectory: true
        ),
        directDirectory: applicationIsDirectDirectory
      )
    )
    #if DEBUG
      testingValidationHook = nil
    #endif
  }

  #if DEBUG
    init(
      testingRuntimeRoot runtimeRoot: URL,
      expectedManifestSHA256: String,
      signatureEvidence: ReleaseOwnedPiRuntimeSyntheticSignatureEvidence,
      signaturePolicy: ReleaseOwnedPiRuntimeSyntheticSignaturePolicy = .adHoc,
      validationHook: (@Sendable (ReleaseOwnedPiRuntimeValidationCheckpoint) throws -> Void)? = nil
    ) {
      let root = Self.canonicalRuntimeRoot(runtimeRoot)
      self.runtimeRoot = root.url
      runtimeRootIsDirectDirectory = root.directDirectory
      self.expectedManifestSHA256 = expectedManifestSHA256
      validationMode = .synthetic(signatureEvidence, signaturePolicy)
      testingValidationHook = validationHook
    }

    static func observeProductionStrictSignatureValidationForTesting(
      preliminaryApplicationTeam: String?,
      preliminaryNodeTeam: String?,
      observer: () -> Void
    ) throws {
      try ReleaseOwnedCodeSignatureValidator
        .observeProductionStrictValidationForTesting(
          preliminaryApplicationTeam: preliminaryApplicationTeam,
          preliminaryNodeTeam: preliminaryNodeTeam,
          observer: observer
        )
    }

    static var productionSignatureRequirementsForTesting: (application: String, node: String) {
      ReleaseOwnedCodeSignatureValidator.productionRequirements
    }
  #endif

  public func resolve() throws -> PiResolvedRuntime {
    do {
      return try resolveUnchecked()
    } catch let error as PiRuntimeResolutionError {
      throw error
    } catch {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime validation failed"
      )
    }
  }

  private func resolveUnchecked() throws -> PiResolvedRuntime {
    guard GitHubInputValidation.validSHA256(expectedManifestSHA256) else {
      throw PiRuntimeResolutionError(
        code: .malformedReleaseManifest,
        detail: "compiled release manifest digest is invalid"
      )
    }
    guard runtimeRootIsDirectDirectory,
      runtimeRoot.isFileURL,
      runtimeRoot.path.hasPrefix("/")
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeMissing,
        detail: "release runtime root path is invalid"
      )
    }
    guard let canonicalPath = Self.canonicalExistingPath(runtimeRoot.path) else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeMissing,
        detail: "release runtime root is missing"
      )
    }
    guard canonicalPath == runtimeRoot.path else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeMissing,
        detail: "release runtime root is redirected"
      )
    }
    try validateContainingApplicationBinding(canonicalRuntimePath: canonicalPath)
    guard Self.safeAncestorChain(runtimeRoot.deletingLastPathComponent().path) else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime ancestor is unsafe"
      )
    }

    let rootDescriptor = Darwin.open(
      canonicalPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeMissing,
        detail: "release runtime root cannot be opened"
      )
    }
    defer { _ = Darwin.close(rootDescriptor) }
    let openedRoot = try Self.directoryMetadata(rootDescriptor, exactMode: 0o755)
    if case .production = validationMode {
      try Self.requireRootOwnedInstalledChain(runtimeRoot, matches: openedRoot)
      try Self.requireRootOwnedTree(rootDescriptor)
    }
    try Self.requirePath(runtimeRoot, matches: openedRoot)
    guard
      try Self.directoryNames(rootDescriptor)
        == ["licenses", "node", "pi", "runtime-manifest.json"]
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime root inventory differs"
      )
    }

    let manifestFile = try Self.readFile(
      "runtime-manifest.json",
      beneath: rootDescriptor,
      maximumBytes: 64 * 1_024,
      exactMode: 0o444
    )
    let manifestDigest = Self.sha256(manifestFile.data)
    guard manifestDigest == expectedManifestSHA256 else {
      throw PiRuntimeResolutionError(
        code: .releaseManifestDrift,
        detail: "release runtime manifest digest differs"
      )
    }
    let manifest = try ReleaseOwnedPiRuntimeManifest.parseCanonical(manifestFile.data)
    try manifest.validateLockedPolicy()
    let selectedNodeCodeDirectorySHA256 = selectedNodeCodeDirectorySHA256(manifest)

    try Self.validateFixedDirectoryInventory(rootDescriptor)
    let initialSignature = try validateSignatures(manifest: manifest, nodeData: nil)

    let license = try Self.readFile(
      manifest.license.relativePath,
      beneath: rootDescriptor,
      maximumBytes: 2 * 1_048_576,
      exactMode: mode_t(manifest.license.mode)
    )
    guard license.data.count == manifest.license.size,
      Self.sha256(license.data) == manifest.license.sha256
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime license differs"
      )
    }

    let node = try Self.readFile(
      manifest.node.relativePath,
      beneath: rootDescriptor,
      maximumBytes: 512 * 1_048_576,
      exactMode: mode_t(manifest.node.mode)
    )
    guard node.data.count >= manifest.node.sizeAtAdHocQualification - 1_048_576,
      node.data.count <= manifest.node.sizeAtAdHocQualification + 8 * 1_048_576
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release Node size is outside the signed release bound"
      )
    }
    try PiRuntimeResolver.validateReleaseNodeMachO(
      node.data,
      architecture: manifest.node.architecture,
      dependencies: manifest.node.machoDependencies
    )
    guard let nodeSignature = try validateSignatures(manifest: manifest, nodeData: node.data),
      signatureTeamIsValid(nodeSignature.teamIdentifier),
      nodeSignature.identifier == manifest.node.identifier,
      nodeSignature.codeDirectorySHA256 == selectedNodeCodeDirectorySHA256,
      nodeSignature.entitlementSHA256 == manifest.node.entitlementSHA256,
      nodeSignature.hardenedRuntime
    else {
      throw PiRuntimeResolutionError(
        code: .releaseSignatureInvalid,
        detail: "release Node signature identity differs"
      )
    }
    if let initialSignature {
      guard initialSignature == nodeSignature else {
        throw PiRuntimeResolutionError(
          code: .releaseSignatureInvalid,
          detail: "release signature evidence changed during validation"
        )
      }
    }

    let packageRoot = runtimeRoot.appendingPathComponent(
      manifest.pi.relativeRoot, isDirectory: true)
    var piDigests: [String: String] = [:]
    for relativePath in manifest.pi.criticalFiles.keys.sorted() {
      let file = try Self.readFile(
        "\(manifest.pi.relativeRoot)/\(relativePath)",
        beneath: rootDescriptor,
        maximumBytes: 64 * 1_048_576,
        exactMode: nil
      )
      let digest = Self.sha256(file.data)
      guard digest == manifest.pi.criticalFiles[relativePath] else {
        throw PiRuntimeResolutionError(
          code: .releaseRuntimeDrift,
          detail: "release Pi critical file differs"
        )
      }
      piDigests[relativePath] = digest
    }
    let packageMetadata = try Self.readFile(
      "\(manifest.pi.relativeRoot)/package.json",
      beneath: rootDescriptor,
      maximumBytes: 1_048_576,
      exactMode: nil
    ).data
    guard let package = try? JSONSerialization.jsonObject(with: packageMetadata) as? [String: Any],
      package["name"] as? String == manifest.pi.package,
      package["version"] as? String == manifest.pi.version
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release Pi package identity differs"
      )
    }
    let cli = try Self.readFile(
      "\(manifest.pi.relativeRoot)/\(manifest.pi.cliRelativePath)",
      beneath: rootDescriptor,
      maximumBytes: 64 * 1_048_576,
      exactMode: nil
    ).data
    guard cli.starts(with: Data("#!/usr/bin/env node\n".utf8)) else {
      throw PiRuntimeResolutionError(
        code: .invalidPiShebang,
        detail: "release Pi CLI shebang differs"
      )
    }
    let tree = try attestPackageTree(
      manifest.pi.relativeRoot,
      beneath: rootDescriptor,
      maximumFileBytes: 64 * 1_048_576
    )
    guard tree == manifest.pi.packageTree else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release Pi package tree differs"
      )
    }
    piDigests["package-tree-v1"] = tree.sha256

    var finalRoot = stat()
    guard fstat(rootDescriptor, &finalRoot) == 0,
      Self.sameEvidence(openedRoot, finalRoot),
      try Self.directoryNames(rootDescriptor)
        == ["licenses", "node", "pi", "runtime-manifest.json"]
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime root changed during validation"
      )
    }
    try Self.requirePath(runtimeRoot, matches: finalRoot)
    try Self.requireRelativeFile(
      manifest.node.relativePath,
      beneath: rootDescriptor,
      matches: node.metadata
    )
    try Self.requireRelativeFile(
      "runtime-manifest.json",
      beneath: rootDescriptor,
      matches: manifestFile.metadata
    )
    guard let finalSignature = try validateSignatures(manifest: manifest, nodeData: node.data),
      finalSignature == nodeSignature
    else {
      throw PiRuntimeResolutionError(
        code: .releaseSignatureInvalid,
        detail: "release signature evidence changed during final validation"
      )
    }
    if case .production = validationMode {
      try Self.requireRootOwnedInstalledChain(runtimeRoot, matches: finalRoot)
    }

    let identity = try PiReleaseRuntimeIdentity(
      runtimeID: manifest.runtimeID,
      manifestSHA256: manifestDigest,
      canonicalRoot: canonicalPath,
      rootDevice: UInt64(finalRoot.st_dev),
      rootInode: finalRoot.st_ino,
      nodeCodeDirectorySHA256: selectedNodeCodeDirectorySHA256,
      piPackageTreeSHA256: tree.sha256
    )
    guard GitHubInputValidation.validSHA256(identity.authoritySHA256) else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime authority digest is invalid"
      )
    }
    let nodeVersion = try PiSemanticVersion(manifest.node.version)
    let piVersion = try PiSemanticVersion(manifest.pi.version)
    let maximumPiVersion = try PiSemanticVersion(
      "\(piVersion.major).\(piVersion.minor).\(piVersion.patch + 1)"
    )
    return PiResolvedRuntime(
      nodeURL: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
      nodeVersion: nodeVersion,
      nodeSHA256: selectedNodeCodeDirectorySHA256,
      piCLIURL: packageRoot.appendingPathComponent(manifest.pi.cliRelativePath),
      piCLIRelativePath: manifest.pi.cliRelativePath,
      piPackageRootURL: packageRoot,
      piVersion: piVersion,
      piRuntimeSHA256: piDigests,
      compatibility: PiRuntimeCompatibility(
        minimumVersion: piVersion,
        maximumVersionExclusive: maximumPiVersion,
        policySHA256: manifestDigest
      ),
      provenance: .releaseOwned(identity)
    )
  }

  private func signatureTeamIsValid(_ team: String?) -> Bool {
    switch validationMode {
    case .production:
      return team == "X3Q42VNZDC"
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .developerIDBundle:
        return team == "X3Q42VNZDC"
      case .stagedInput, .adHocBundle:
        return team == nil
    #endif
    #if DEBUG
      case .synthetic(_, let policy):
        switch policy {
        case .adHoc:
          return team == nil
        case .production:
          return team == "X3Q42VNZDC"
        }
    #endif
    }
  }

  private func selectedNodeCodeDirectorySHA256(
    _ manifest: ReleaseOwnedPiRuntimeManifest
  ) -> String {
    switch validationMode {
    case .production:
      return manifest.node.productionCodeDirectorySHA256
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .developerIDBundle:
        return manifest.node.productionCodeDirectorySHA256
      case .stagedInput, .adHocBundle:
        return manifest.node.adHocCodeDirectorySHA256
    #endif
    #if DEBUG
      case .synthetic(_, let policy):
        switch policy {
        case .adHoc:
          return manifest.node.adHocCodeDirectorySHA256
        case .production:
          return manifest.node.productionCodeDirectorySHA256
        }
    #endif
    }
  }

  private func validateContainingApplicationBinding(canonicalRuntimePath: String) throws {
    let application: URL
    let requireDirectApplication: Bool
    switch validationMode {
    case .production(let context):
      application = context.application
      requireDirectApplication = context.directDirectory
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .adHocBundle(let value), .developerIDBundle(let value):
        application = value
        requireDirectApplication = true
      case .stagedInput:
        return
    #endif
    #if DEBUG
      case .synthetic:
        return
    #endif
    }
    guard requireDirectApplication,
      application.pathExtension == "app",
      let canonicalApplication = Self.canonicalExistingPath(application.path),
      canonicalApplication == application.path
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "containing application path is unsafe"
      )
    }
    let expectedRuntime =
      application
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent(Self.runtimeDirectoryName, isDirectory: true)
    guard Self.canonicalExistingPath(expectedRuntime.path) == canonicalRuntimePath,
      expectedRuntime.path == canonicalRuntimePath
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime is detached from its containing application"
      )
    }
  }

  private static func requireRootOwnedInstalledChain(
    _ installedRuntime: URL,
    matches expectedRuntime: stat
  ) throws {
    guard installedRuntime.path.hasPrefix("/"),
      installedRuntime.lastPathComponent == runtimeDirectoryName
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "installed application path is invalid"
      )
    }
    let components = installedRuntime.path.split(separator: "/").map(String.init)
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "installed application root cannot be opened"
      )
    }
    do {
      try requireRootOwnedDirectory(current)
      for component in components {
        let child = Darwin.openat(
          current,
          component,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed application ancestor is redirected"
          )
        }
        _ = Darwin.close(current)
        current = child
        try requireRootOwnedDirectory(current)
      }
      let finalRuntime = try rootOwnedDirectoryMetadata(current)
      guard sameEvidence(finalRuntime, expectedRuntime) else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "installed release runtime path identity differs"
        )
      }
      _ = Darwin.close(current)
    } catch {
      _ = Darwin.close(current)
      throw error
    }
  }

  private static func requireRootOwnedTree(_ root: Int32) throws {
    var entryCount = 0
    try requireRootOwnedDirectoryTree(root, depth: 0, entryCount: &entryCount)
  }

  private static func requireRootOwnedDirectoryTree(
    _ descriptor: Int32,
    depth: Int,
    entryCount: inout Int
  ) throws {
    guard depth <= 256 else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "installed release runtime depth is excessive"
      )
    }
    let before = try rootOwnedDirectoryMetadata(descriptor)
    let names = try directoryNames(descriptor)
    for name in names {
      entryCount += 1
      guard entryCount <= 100_000 else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "installed release runtime inventory is excessive"
        )
      }
      var pathMetadata = stat()
      guard fstatat(descriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
        pathMetadata.st_uid == 0,
        pathMetadata.st_nlink >= 1
      else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "installed release runtime ownership is unsafe"
        )
      }
      switch pathMetadata.st_mode & S_IFMT {
      case S_IFDIR:
        guard pathMetadata.st_mode & 0o022 == 0 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime directory is writable"
          )
        }
        let child = Darwin.openat(
          descriptor,
          name,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime directory is redirected"
          )
        }
        do {
          let opened = try rootOwnedDirectoryMetadata(child)
          guard sameEvidence(pathMetadata, opened) else {
            throw PiRuntimeResolutionError(
              code: .unsafeReleaseRuntime,
              detail: "installed release runtime directory changed while opened"
            )
          }
          try requireRootOwnedDirectoryTree(
            child,
            depth: depth + 1,
            entryCount: &entryCount
          )
          _ = Darwin.close(child)
        } catch {
          _ = Darwin.close(child)
          throw error
        }
      case S_IFREG:
        guard pathMetadata.st_mode & 0o022 == 0, pathMetadata.st_nlink == 1 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime file is unsafe"
          )
        }
        let child = Darwin.openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime file is redirected"
          )
        }
        var opened = stat()
        let safe =
          fstat(child, &opened) == 0
          && DarwinACLAuthority.hasNoAllowEntries(child)
          && sameEvidence(pathMetadata, opened)
        _ = Darwin.close(child)
        guard safe else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime file metadata is unsafe"
          )
        }
      case S_IFLNK:
        guard pathMetadata.st_nlink == 1 else {
          throw PiRuntimeResolutionError(
            code: .unsafeReleaseRuntime,
            detail: "installed release runtime symbolic link is unsafe"
          )
        }
      default:
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "installed release runtime entry kind is unsafe"
        )
      }
    }
    let after = try rootOwnedDirectoryMetadata(descriptor)
    guard before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      try directoryNames(descriptor) == names
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "installed release runtime directory changed"
      )
    }
  }

  private static func requireRootOwnedDirectory(_ descriptor: Int32) throws {
    _ = try rootOwnedDirectoryMetadata(descriptor)
  }

  private static func rootOwnedDirectoryMetadata(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == 0,
      value.st_mode & 0o022 == 0
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "installed application ownership chain is unsafe"
      )
    }
    return value
  }

  private func validateSignatures(
    manifest: ReleaseOwnedPiRuntimeManifest,
    nodeData: Data?
  ) throws -> ReleaseOwnedCodeSignatureEvidence? {
    switch validationMode {
    case .production(let context):
      guard let nodeData else {
        try ReleaseOwnedCodeSignatureValidator.validateProductionContainingApplication(
          context.application,
          node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
          nodeIdentifier: manifest.node.identifier
        )
        return nil
      }
      return try ReleaseOwnedCodeSignatureValidator.validateProduction(
        application: context.application,
        node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
        nodeData: nodeData,
        manifest: manifest
      )
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .developerIDBundle(let application):
        guard let nodeData else {
          try ReleaseOwnedCodeSignatureValidator.validateProductionContainingApplication(
            application,
            node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
            nodeIdentifier: manifest.node.identifier
          )
          return nil
        }
        return try ReleaseOwnedCodeSignatureValidator.validateProduction(
          application: application,
          node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
          nodeData: nodeData,
          manifest: manifest
        )
      case .stagedInput:
        guard let nodeData else { return nil }
        return try ReleaseOwnedCodeSignatureValidator.validateAdHoc(
          application: nil,
          node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
          nodeData: nodeData,
          manifest: manifest
        )
      case .adHocBundle(let application):
        guard let nodeData else {
          try ReleaseOwnedCodeSignatureValidator.validateAdHocContainingApplication(
            application,
            node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
            nodeIdentifier: manifest.node.identifier
          )
          return nil
        }
        return try ReleaseOwnedCodeSignatureValidator.validateAdHoc(
          application: application,
          node: runtimeRoot.appendingPathComponent(manifest.node.relativePath),
          nodeData: nodeData,
          manifest: manifest
        )
    #endif
    #if DEBUG
      case .synthetic(let evidence, _):
        guard nodeData != nil else { return nil }
        return ReleaseOwnedCodeSignatureEvidence(
          identifier: evidence.identifier,
          teamIdentifier: evidence.teamIdentifier,
          codeDirectorySHA256: evidence.codeDirectorySHA256,
          entitlementSHA256: evidence.entitlementSHA256,
          hardenedRuntime: evidence.hardenedRuntime
        )
    #endif
    }
  }

  #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
    fileprivate init(
      runtimeRoot: URL,
      expectedManifestSHA256: String,
      validationMode: ValidationMode
    ) {
      let root = Self.canonicalRuntimeRoot(runtimeRoot)
      self.runtimeRoot = root.url
      runtimeRootIsDirectDirectory = root.directDirectory
      self.expectedManifestSHA256 = expectedManifestSHA256
      self.validationMode = validationMode
      #if DEBUG
        testingValidationHook = nil
      #endif
    }
  #endif

  fileprivate struct ProductionContext: Sendable {
    let application: URL
    let directDirectory: Bool
  }

  fileprivate enum ValidationMode: Sendable {
    case production(ProductionContext)
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case stagedInput
      case adHocBundle(URL)
      case developerIDBundle(URL)
    #endif
    #if DEBUG
      case synthetic(
        ReleaseOwnedPiRuntimeSyntheticSignatureEvidence,
        ReleaseOwnedPiRuntimeSyntheticSignaturePolicy
      )
    #endif
  }

  private struct FileEvidence {
    let data: Data
    let metadata: stat
  }

  private enum ReleasePackageTreeEntryKind: Equatable {
    case directory
    case regularFile
    case symbolicLink
  }

  private struct ReleasePackageTreeEntry: Equatable {
    let relativePath: String
    let kind: ReleasePackageTreeEntryKind
    let permissions: Int
    let symbolicLinkTarget: String?
    let size: Int
    let sha256: String?
  }

  private func attestPackageTree(
    _ relativeRoot: String,
    beneath runtimeRoot: Int32,
    maximumFileBytes: Int
  ) throws -> PiRuntimeTreeAttestation {
    guard (1...64 * 1_048_576).contains(maximumFileBytes) else {
      throw Self.packageTreeError("release Pi package file-size bound is invalid")
    }
    let components = try Self.relativeComponents(relativeRoot)
    guard let name = components.last else {
      throw Self.packageTreeError("release Pi package root is invalid")
    }
    let parent = try Self.openDirectory(
      components.dropLast().joined(separator: "/"),
      beneath: runtimeRoot,
      exactMode: nil
    )
    defer { _ = Darwin.close(parent) }

    var pathBefore = stat()
    guard fstatat(parent, name, &pathBefore, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw Self.packageTreeError("release Pi package root is missing")
    }
    let packageRoot = Darwin.openat(
      parent,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard packageRoot >= 0 else {
      throw Self.packageTreeError("release Pi package root is redirected")
    }
    defer { _ = Darwin.close(packageRoot) }
    let packageBefore = try Self.directoryMetadata(packageRoot, exactMode: 0o755)
    guard Self.sameEvidence(pathBefore, packageBefore) else {
      throw Self.packageTreeError("release Pi package root changed while opened")
    }

    let inspected = try inspectPackageTree(
      packageRoot,
      maximumFileBytes: maximumFileBytes
    )
    #if DEBUG
      try testingValidationHook?(.packageTreeInspected)
    #endif
    let finalInspection = try inspectPackageTree(
      packageRoot,
      maximumFileBytes: maximumFileBytes
    )
    guard finalInspection == inspected else {
      throw Self.packageTreeError("release Pi package tree changed during validation")
    }

    let packageAfter = try Self.directoryMetadata(packageRoot, exactMode: 0o755)
    var pathAfter = stat()
    guard Self.sameEvidence(packageBefore, packageAfter),
      fstatat(parent, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameEvidence(packageAfter, pathAfter)
    else {
      throw Self.packageTreeError("release Pi package root changed before authority")
    }
    return try Self.packageTreeAttestation(inspected)
  }

  private func inspectPackageTree(
    _ packageRoot: Int32,
    maximumFileBytes: Int
  ) throws -> [ReleasePackageTreeEntry] {
    var entries: [ReleasePackageTreeEntry] = []
    try inspectPackageDirectory(
      packageRoot,
      packageRoot: packageRoot,
      components: [],
      maximumFileBytes: maximumFileBytes,
      depth: 0,
      entries: &entries
    )
    return entries.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
  }

  private func inspectPackageDirectory(
    _ descriptor: Int32,
    packageRoot: Int32,
    components: [String],
    maximumFileBytes: Int,
    depth: Int,
    entries: inout [ReleasePackageTreeEntry]
  ) throws {
    guard depth <= 256 else {
      throw Self.packageTreeError("release Pi package directory depth is excessive")
    }
    let before = try Self.directoryMetadata(descriptor, exactMode: nil)
    let names = try Self.directoryNames(descriptor)
    for name in names {
      guard entries.count < 100_000 else {
        throw Self.packageTreeError("release Pi package inventory is excessive")
      }
      let childComponents = components + [name]
      let relativePath = childComponents.joined(separator: "/")
      guard relativePath.utf8.count <= 4_096 else {
        throw Self.packageTreeError("release Pi package path is excessive")
      }
      var pathMetadata = stat()
      guard fstatat(descriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Self.packageTreeError("release Pi package entry disappeared")
      }
      let permissions = Int(pathMetadata.st_mode & 0o7777)
      switch pathMetadata.st_mode & S_IFMT {
      case S_IFDIR:
        let child = Darwin.openat(
          descriptor,
          name,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
          throw Self.packageTreeError("release Pi package directory is redirected")
        }
        do {
          let opened = try Self.directoryMetadata(child, exactMode: nil)
          guard Self.sameEvidence(pathMetadata, opened) else {
            throw Self.packageTreeError("release Pi package directory changed while opened")
          }
          #if DEBUG
            try testingValidationHook?(.packageDirectoryOpened(relativePath))
          #endif
          entries.append(
            ReleasePackageTreeEntry(
              relativePath: relativePath,
              kind: .directory,
              permissions: permissions,
              symbolicLinkTarget: nil,
              size: 0,
              sha256: nil
            )
          )
          try inspectPackageDirectory(
            child,
            packageRoot: packageRoot,
            components: childComponents,
            maximumFileBytes: maximumFileBytes,
            depth: depth + 1,
            entries: &entries
          )
          let after = try Self.directoryMetadata(child, exactMode: nil)
          var finalPathMetadata = stat()
          guard Self.sameEvidence(opened, after),
            fstatat(descriptor, name, &finalPathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
            Self.sameEvidence(after, finalPathMetadata)
          else {
            throw Self.packageTreeError("release Pi package directory changed while inspected")
          }
          _ = Darwin.close(child)
        } catch {
          _ = Darwin.close(child)
          throw error
        }
      case S_IFREG:
        entries.append(
          try inspectPackageRegularFile(
            parent: descriptor,
            name: name,
            relativePath: relativePath,
            pathMetadata: pathMetadata,
            permissions: permissions,
            maximumFileBytes: maximumFileBytes
          )
        )
      case S_IFLNK:
        entries.append(
          try inspectPackageSymbolicLink(
            parent: descriptor,
            name: name,
            parentComponents: components,
            relativePath: relativePath,
            pathMetadata: pathMetadata,
            packageRoot: packageRoot
          )
        )
      default:
        throw Self.packageTreeError("release Pi package entry kind is unsafe")
      }
    }
    let after = try Self.directoryMetadata(descriptor, exactMode: nil)
    guard try Self.directoryNames(descriptor) == names,
      Self.sameEvidence(before, after)
    else {
      throw Self.packageTreeError("release Pi package directory inventory changed")
    }
  }

  private func inspectPackageRegularFile(
    parent: Int32,
    name: String,
    relativePath: String,
    pathMetadata: stat,
    permissions: Int,
    maximumFileBytes: Int
  ) throws -> ReleasePackageTreeEntry {
    let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw Self.packageTreeError("release Pi package file is redirected")
    }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      Self.sameEvidence(pathMetadata, before),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == 0 || before.st_uid == geteuid(),
      before.st_mode & 0o022 == 0,
      before.st_nlink == 1,
      before.st_size >= 0,
      before.st_size <= off_t(maximumFileBytes)
    else {
      throw Self.packageTreeError("release Pi package file metadata is unsafe")
    }
    #if DEBUG
      try testingValidationHook?(.packageRegularFileOpened(relativePath))
    #endif
    var data = Data(count: Int(before.st_size))
    if !data.isEmpty {
      try data.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else {
          throw Self.packageTreeError("release Pi package file buffer is unavailable")
        }
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
          if count > 0 {
            offset += count
          } else if count == -1, errno == EINTR {
            continue
          } else {
            throw Self.packageTreeError("release Pi package file could not be read")
          }
        }
      }
    }
    var after = stat()
    var finalPathMetadata = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      Self.sameEvidence(before, after),
      fstatat(parent, name, &finalPathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameEvidence(after, finalPathMetadata)
    else {
      throw Self.packageTreeError("release Pi package file changed while inspected")
    }
    return ReleasePackageTreeEntry(
      relativePath: relativePath,
      kind: .regularFile,
      permissions: permissions,
      symbolicLinkTarget: nil,
      size: data.count,
      sha256: Self.sha256(data)
    )
  }

  private func inspectPackageSymbolicLink(
    parent: Int32,
    name: String,
    parentComponents: [String],
    relativePath: String,
    pathMetadata: stat,
    packageRoot: Int32
  ) throws -> ReleasePackageTreeEntry {
    guard pathMetadata.st_uid == 0 || pathMetadata.st_uid == geteuid(),
      pathMetadata.st_nlink == 1
    else {
      throw Self.packageTreeError("release Pi package symbolic-link metadata is unsafe")
    }
    let target = try Self.readPackageSymbolicLink(parent: parent, name: name)
    let targetComponents = try Self.normalizedPackageLinkTarget(
      target,
      parentComponents: parentComponents
    )
    try validatePackageLinkTarget(
      targetComponents,
      linkRelativePath: relativePath,
      beneath: packageRoot
    )
    var finalPathMetadata = stat()
    guard fstatat(parent, name, &finalPathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      Self.sameEvidence(pathMetadata, finalPathMetadata),
      try Self.readPackageSymbolicLink(parent: parent, name: name) == target
    else {
      throw Self.packageTreeError("release Pi package symbolic link changed while inspected")
    }
    return ReleasePackageTreeEntry(
      relativePath: relativePath,
      kind: .symbolicLink,
      permissions: 0,
      symbolicLinkTarget: target,
      size: 0,
      sha256: nil
    )
  }

  private static func readPackageSymbolicLink(parent: Int32, name: String) throws -> String {
    let capacity = Int(PATH_MAX) + 1
    var bytes = [UInt8](repeating: 0, count: capacity)
    let count = bytes.withUnsafeMutableBytes { buffer in
      Darwin.readlinkat(
        parent,
        name,
        buffer.bindMemory(to: CChar.self).baseAddress,
        capacity - 1
      )
    }
    guard count > 0,
      count < capacity,
      let target = String(data: Data(bytes.prefix(count)), encoding: .utf8),
      !target.contains("\u{0}")
    else {
      throw packageTreeError("release Pi package symbolic-link target is invalid")
    }
    return target
  }

  private static func normalizedPackageLinkTarget(
    _ target: String,
    parentComponents: [String]
  ) throws -> [String] {
    guard !target.hasPrefix("/"),
      target.utf8.count <= 4_096
    else {
      throw packageTreeError("release Pi package symbolic link escapes its root")
    }
    var result = parentComponents
    for rawComponent in target.split(separator: "/", omittingEmptySubsequences: false) {
      let component = String(rawComponent)
      if component == "." { continue }
      if component == ".." {
        guard !result.isEmpty else {
          throw packageTreeError("release Pi package symbolic link escapes its root")
        }
        result.removeLast()
        continue
      }
      guard !component.isEmpty,
        component.utf8.count <= Int(MAXNAMLEN),
        !component.contains("\u{0}")
      else {
        throw packageTreeError("release Pi package symbolic-link target is invalid")
      }
      result.append(component)
    }
    return result
  }

  private func validatePackageLinkTarget(
    _ components: [String],
    linkRelativePath: String,
    beneath packageRoot: Int32
  ) throws {
    struct OpenedTarget {
      let parent: Int32
      let name: String
      let child: Int32
      let evidence: stat
    }

    let root = Darwin.dup(packageRoot)
    guard root >= 0 else {
      throw Self.packageTreeError("release Pi package descriptor could not be duplicated")
    }
    var descriptors = [root]
    var openedTargets: [OpenedTarget] = []
    defer {
      for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }
    }
    _ = try Self.directoryMetadata(root, exactMode: nil)

    for (index, component) in components.enumerated() {
      let parent = descriptors.last!
      var pathMetadata = stat()
      guard fstatat(parent, component, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Self.packageTreeError("release Pi package symbolic-link target is missing")
      }
      let final = index == components.count - 1
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (final ? 0 : O_DIRECTORY)
      let child = Darwin.openat(parent, component, flags)
      guard child >= 0 else {
        throw Self.packageTreeError("release Pi package symbolic-link target is redirected")
      }
      descriptors.append(child)
      var opened = stat()
      guard fstat(child, &opened) == 0,
        DarwinACLAuthority.hasNoAllowEntries(child),
        Self.sameEvidence(pathMetadata, opened),
        opened.st_uid == 0 || opened.st_uid == geteuid()
      else {
        throw Self.packageTreeError("release Pi package symbolic-link target is unsafe")
      }
      if final {
        switch opened.st_mode & S_IFMT {
        case S_IFDIR:
          guard opened.st_mode & 0o022 == 0 else {
            throw Self.packageTreeError("release Pi package symbolic-link target is writable")
          }
        case S_IFREG:
          guard opened.st_mode & 0o022 == 0, opened.st_nlink == 1 else {
            throw Self.packageTreeError("release Pi package symbolic-link target is unsafe")
          }
        default:
          throw Self.packageTreeError("release Pi package symbolic-link target kind is unsafe")
        }
      } else {
        guard opened.st_mode & S_IFMT == S_IFDIR,
          opened.st_mode & 0o022 == 0
        else {
          throw Self.packageTreeError("release Pi package symbolic-link ancestor is unsafe")
        }
      }
      openedTargets.append(
        OpenedTarget(parent: parent, name: component, child: child, evidence: opened)
      )
      #if DEBUG
        try testingValidationHook?(
          .packageLinkTargetOpened(
            link: linkRelativePath,
            target: components.prefix(index + 1).joined(separator: "/"),
            isFinal: final
          )
        )
      #endif
    }

    for target in openedTargets {
      var descriptorEvidence = stat()
      var pathEvidence = stat()
      guard fstat(target.child, &descriptorEvidence) == 0,
        DarwinACLAuthority.hasNoAllowEntries(target.child),
        Self.sameEvidence(target.evidence, descriptorEvidence),
        fstatat(target.parent, target.name, &pathEvidence, AT_SYMLINK_NOFOLLOW) == 0,
        Self.sameEvidence(descriptorEvidence, pathEvidence)
      else {
        throw Self.packageTreeError(
          "release Pi package symbolic-link target changed while inspected"
        )
      }
    }
  }

  private static func packageTreeAttestation(
    _ entries: [ReleasePackageTreeEntry]
  ) throws -> PiRuntimeTreeAttestation {
    var hasher = SHA256()
    func update(_ fields: [String]) {
      let framed = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|") + "\n"
      hasher.update(data: Data(framed.utf8))
    }
    update(["jidoka-pi-package-tree", "1", "entryCount", String(entries.count)])
    for entry in entries {
      switch entry.kind {
      case .directory:
        update([
          "directory", entry.relativePath,
          "permissions", String(entry.permissions),
        ])
      case .symbolicLink:
        guard let target = entry.symbolicLinkTarget else {
          throw packageTreeError("release Pi package symbolic-link evidence is missing")
        }
        update([
          "symbolicLink", entry.relativePath,
          "target", target,
        ])
      case .regularFile:
        guard let digest = entry.sha256 else {
          throw packageTreeError("release Pi package file evidence is missing")
        }
        update([
          "regularFile", entry.relativePath,
          "permissions", String(entry.permissions),
          "size", String(entry.size),
          "sha256", digest,
        ])
      }
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return PiRuntimeTreeAttestation(entryCount: entries.count, sha256: digest)
  }

  private static func packageTreeError(_ detail: String) -> PiRuntimeResolutionError {
    PiRuntimeResolutionError(code: .releaseRuntimeDrift, detail: detail)
  }

  private static func validateFixedDirectoryInventory(_ root: Int32) throws {
    let licenses = try openDirectory("licenses", beneath: root, exactMode: 0o755)
    defer { _ = Darwin.close(licenses) }
    guard try directoryNames(licenses) == ["node-LICENSE"] else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release license inventory differs"
      )
    }
    let node = try openDirectory("node", beneath: root, exactMode: 0o755)
    defer { _ = Darwin.close(node) }
    guard try directoryNames(node) == ["bin"] else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release Node inventory differs"
      )
    }
    let bin = try openDirectory("node/bin", beneath: root, exactMode: 0o755)
    defer { _ = Darwin.close(bin) }
    guard try directoryNames(bin) == ["node"] else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release Node binary inventory differs"
      )
    }
    let pi = try openDirectory("pi", beneath: root, exactMode: 0o755)
    _ = Darwin.close(pi)
  }

  private static func readFile(
    _ relativePath: String,
    beneath root: Int32,
    maximumBytes: Int,
    exactMode: mode_t?
  ) throws -> FileEvidence {
    let components = try relativeComponents(relativePath)
    let parentPath = components.dropLast().joined(separator: "/")
    let parent = try openDirectory(parentPath, beneath: root, exactMode: nil)
    defer { _ = Darwin.close(parent) }
    guard let name = components.last else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime path is invalid"
      )
    }
    let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime file is missing or redirected"
      )
    }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == 0 || before.st_uid == geteuid(),
      before.st_mode & 0o022 == 0,
      exactMode.map({ before.st_mode & 0o777 == $0 }) ?? true,
      before.st_nlink == 1,
      before.st_size >= 1,
      before.st_size <= maximumBytes
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime file metadata is unsafe"
      )
    }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw PiRuntimeResolutionError(
            code: .releaseRuntimeDrift,
            detail: "release runtime file could not be read"
          )
        }
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      sameEvidence(before, after)
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime file changed while read"
      )
    }
    return FileEvidence(data: data, metadata: after)
  }

  private static func requireRelativeFile(
    _ relativePath: String,
    beneath root: Int32,
    matches expected: stat
  ) throws {
    let components = try relativeComponents(relativePath)
    let parent = try openDirectory(
      components.dropLast().joined(separator: "/"),
      beneath: root,
      exactMode: nil
    )
    defer { _ = Darwin.close(parent) }
    guard let name = components.last else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime final path is invalid"
      )
    }
    var current = stat()
    guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      sameEvidence(expected, current)
    else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime file changed before authority"
      )
    }
  }

  private static func openDirectory(
    _ relativePath: String,
    beneath root: Int32,
    exactMode: mode_t?
  ) throws -> Int32 {
    var current = Darwin.dup(root)
    guard current >= 0 else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime descriptor could not be duplicated"
      )
    }
    do {
      let components = relativePath.isEmpty ? [] : try relativeComponents(relativePath)
      for component in components {
        let child = Darwin.openat(
          current,
          component,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
          throw PiRuntimeResolutionError(
            code: .releaseRuntimeDrift,
            detail: "release runtime directory is missing or redirected"
          )
        }
        _ = Darwin.close(current)
        current = child
        _ = try directoryMetadata(current, exactMode: nil)
      }
      _ = try directoryMetadata(current, exactMode: exactMode)
      return current
    } catch {
      _ = Darwin.close(current)
      throw error
    }
  }

  private static func directoryMetadata(_ descriptor: Int32, exactMode: mode_t?) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == 0 || value.st_uid == geteuid(),
      value.st_mode & 0o022 == 0,
      exactMode.map({ value.st_mode & 0o777 == $0 }) ?? true
    else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime directory metadata is unsafe"
      )
    }
    return value
  }

  private static func directoryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0,
      lseek(duplicate, 0, SEEK_SET) >= 0,
      let directory = fdopendir(duplicate)
    else {
      if duplicate >= 0 { _ = Darwin.close(duplicate) }
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime directory inventory is unavailable"
      )
    }
    defer { _ = closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      guard !name.isEmpty,
        name.utf8.count <= Int(MAXNAMLEN),
        !name.contains("/"),
        !name.contains("\u{0}"),
        names.count < 100_000
      else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "release runtime directory entry is invalid"
        )
      }
      names.append(name)
    }
    guard errno == 0 else {
      throw PiRuntimeResolutionError(
        code: .unsafeReleaseRuntime,
        detail: "release runtime directory enumeration failed"
      )
    }
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  private static func relativeComponents(_ path: String) throws -> [String] {
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !path.isEmpty,
      path.utf8.count <= 4_096,
      !path.hasPrefix("/"),
      !path.hasSuffix("/"),
      components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(MAXNAMLEN)
          && !$0.contains("\u{0}")
      }),
      URL(fileURLWithPath: "/\(path)").standardizedFileURL.path == "/\(path)"
    else {
      throw PiRuntimeResolutionError(
        code: .malformedReleaseManifest,
        detail: "release runtime manifest path is invalid"
      )
    }
    return components
  }

  private static func requirePath(_ url: URL, matches expected: stat) throws {
    var current = stat()
    guard lstat(url.path, &current) == 0, sameEvidence(expected, current) else {
      throw PiRuntimeResolutionError(
        code: .releaseRuntimeDrift,
        detail: "release runtime root path changed"
      )
    }
  }

  private static func sameEvidence(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev
      && left.st_ino == right.st_ino
      && left.st_mode == right.st_mode
      && left.st_uid == right.st_uid
      && left.st_gid == right.st_gid
      && left.st_nlink == right.st_nlink
      && left.st_size == right.st_size
      && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
      && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
      && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
      && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
  }

  private static func safeAncestorChain(_ path: String) -> Bool {
    var current = path
    while true {
      let descriptor = Darwin.open(
        current,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else { return false }
      var value = stat()
      let safe =
        fstat(descriptor, &value) == 0
        && DarwinACLAuthority.hasNoAllowEntries(descriptor)
        && value.st_mode & S_IFMT == S_IFDIR
        && (value.st_uid == 0 || value.st_uid == geteuid())
        && (value.st_mode & 0o022 == 0 || value.st_mode & S_ISVTX != 0)
      _ = Darwin.close(descriptor)
      guard safe else { return false }
      if current == "/" { return true }
      let parent = (current as NSString).deletingLastPathComponent
      guard !parent.isEmpty, parent != current else { return false }
      current = parent
    }
  }

  private static func canonicalRuntimeRoot(_ requested: URL) -> (
    url: URL, directDirectory: Bool
  ) {
    var metadata = stat()
    let directDirectory =
      lstat(requested.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFDIR
    let path = canonicalExistingPath(requested.path) ?? requested.path
    return (URL(fileURLWithPath: path, isDirectory: true), directDirectory)
  }

  fileprivate static func canonicalExistingPath(_ path: String) -> String? {
    guard let pointer = Darwin.realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

#if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
  public enum ReleaseOwnedPiRuntimeVerifier {
    @discardableResult
    public static func verifyStagedInput(runtimeRoot: URL) throws -> PiResolvedRuntime {
      try ReleaseOwnedPiRuntimeResolver(
        runtimeRoot: runtimeRoot,
        expectedManifestSHA256: ReleaseOwnedPiRuntimeResolver.expectedManifestSHA256,
        validationMode: .stagedInput
      ).resolve()
    }

    @discardableResult
    public static func verifyAdHocBundle(
      runtimeRoot: URL,
      containingApplicationURL: URL
    ) throws -> PiResolvedRuntime {
      try verifyBundle(
        runtimeRoot: runtimeRoot,
        containingApplicationURL: containingApplicationURL,
        validationMode: { .adHocBundle($0) }
      )
    }

    @discardableResult
    public static func verifyDeveloperIDBundle(
      runtimeRoot: URL,
      containingApplicationURL: URL
    ) throws -> PiResolvedRuntime {
      try verifyBundle(
        runtimeRoot: runtimeRoot,
        containingApplicationURL: containingApplicationURL,
        validationMode: { .developerIDBundle($0) }
      )
    }

    private static func verifyBundle(
      runtimeRoot: URL,
      containingApplicationURL: URL,
      validationMode: (URL) -> ReleaseOwnedPiRuntimeResolver.ValidationMode
    ) throws -> PiResolvedRuntime {
      var metadata = stat()
      guard lstat(containingApplicationURL.path, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR
      else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "containing application path is unsafe"
        )
      }
      guard
        let canonicalApplication = ReleaseOwnedPiRuntimeResolver.canonicalExistingPath(
          containingApplicationURL.path
        )
      else {
        throw PiRuntimeResolutionError(
          code: .unsafeReleaseRuntime,
          detail: "containing application path is unavailable"
        )
      }
      return try ReleaseOwnedPiRuntimeResolver(
        runtimeRoot: runtimeRoot,
        expectedManifestSHA256: ReleaseOwnedPiRuntimeResolver.expectedManifestSHA256,
        validationMode: validationMode(
          URL(fileURLWithPath: canonicalApplication, isDirectory: true)
        )
      ).resolve()
    }
  }
#endif

private struct ReleaseOwnedCodeSignatureEvidence: Equatable {
  let identifier: String
  let teamIdentifier: String?
  let codeDirectorySHA256: String
  let entitlementSHA256: String
  let hardenedRuntime: Bool
}

private enum ReleaseOwnedCodeSignatureValidator {
  private static let expectedProductionTeamIdentifier = "X3Q42VNZDC"
  private static let expectedApplicationIdentifier = "com.maroffo.JidokaCode"
  private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000
  static let productionRequirements = (
    application: "anchor apple generic and identifier \"com.maroffo.JidokaCode\" "
      + "and certificate leaf[subject.OU] = \"X3Q42VNZDC\"",
    node: "anchor apple generic and identifier \"works.earendil.jidoka.runtime.node\" "
      + "and certificate leaf[subject.OU] = \"X3Q42VNZDC\""
  )

  static func validateProductionContainingApplication(
    _ application: URL,
    node: URL,
    nodeIdentifier: String
  ) throws {
    try validateContainingApplication(
      application,
      node: node,
      nodeIdentifier: nodeIdentifier,
      policy: .production
    )
  }

  static func validateProduction(
    application: URL,
    node: URL,
    nodeData: Data,
    manifest: ReleaseOwnedPiRuntimeManifest
  ) throws -> ReleaseOwnedCodeSignatureEvidence {
    try validate(
      application: application,
      node: node,
      nodeData: nodeData,
      manifest: manifest,
      policy: .production
    )
  }

  #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
    static func validateAdHocContainingApplication(
      _ application: URL,
      node: URL,
      nodeIdentifier: String
    ) throws {
      try validateContainingApplication(
        application,
        node: node,
        nodeIdentifier: nodeIdentifier,
        policy: .adHoc
      )
    }

    static func validateAdHoc(
      application: URL?,
      node: URL,
      nodeData: Data,
      manifest: ReleaseOwnedPiRuntimeManifest
    ) throws -> ReleaseOwnedCodeSignatureEvidence {
      try validate(
        application: application,
        node: node,
        nodeData: nodeData,
        manifest: manifest,
        policy: .adHoc
      )
    }
  #endif

  private static func validateContainingApplication(
    _ application: URL,
    node: URL,
    nodeIdentifier: String,
    policy: SignaturePolicy
  ) throws {
    let requirements = signatureRequirements(
      nodeIdentifier: nodeIdentifier,
      policy: policy
    )
    let applicationTarget = try signingTarget(
      application,
      requirement: requirements.application
    )
    let preliminaryApplicationTeam = teamIdentifier(
      applicationTarget.preliminaryInformation
    )
    let nodeTarget = try signingTarget(
      node,
      requirement: requirements.node
    )
    let preliminaryNodeTeam = teamIdentifier(nodeTarget.preliminaryInformation)
    try validatePreliminaryTeams(
      applicationTeam: preliminaryApplicationTeam,
      nodeTeam: preliminaryNodeTeam,
      hasApplication: true,
      policy: policy
    )

    let trustedApplicationInformation = try strictSigningInformation(
      applicationTarget,
      checkNestedCode: true
    )
    let trustedApplicationTeam = teamIdentifier(trustedApplicationInformation)
    guard trustedApplicationTeam == preliminaryApplicationTeam,
      trustedApplicationInformation[kSecCodeInfoIdentifier as String] as? String
        == expectedApplicationIdentifier
    else {
      throw signatureError("release application signing evidence changed after strict validation")
    }
    try validateTeam(trustedApplicationTeam, applicationTeam: nil, policy: policy)

    let trustedNodeInformation = try strictSigningInformation(
      nodeTarget,
      checkNestedCode: false
    )
    let trustedNodeTeam = teamIdentifier(trustedNodeInformation)
    guard trustedNodeTeam == preliminaryNodeTeam,
      trustedNodeInformation[kSecCodeInfoIdentifier as String] as? String == nodeIdentifier
    else {
      throw signatureError("release Node signing evidence changed after strict validation")
    }
    try validateTeam(
      trustedNodeTeam,
      applicationTeam: trustedApplicationTeam,
      policy: policy
    )
  }

  private static func validate(
    application: URL?,
    node: URL,
    nodeData: Data,
    manifest: ReleaseOwnedPiRuntimeManifest,
    policy: SignaturePolicy
  ) throws -> ReleaseOwnedCodeSignatureEvidence {
    let requirements = signatureRequirements(
      nodeIdentifier: manifest.node.identifier,
      policy: policy
    )
    let applicationTarget = try application.map {
      try signingTarget($0, requirement: requirements.application)
    }
    let preliminaryApplicationTeam =
      applicationTarget.map {
        teamIdentifier($0.preliminaryInformation)
      } ?? nil
    let nodeTarget = try signingTarget(node, requirement: requirements.node)
    let preliminaryNodeTeam = teamIdentifier(nodeTarget.preliminaryInformation)

    try validatePreliminaryTeams(
      applicationTeam: preliminaryApplicationTeam,
      nodeTeam: preliminaryNodeTeam,
      hasApplication: applicationTarget != nil,
      policy: policy
    )

    var trustedApplicationTeam: String?
    if let applicationTarget {
      let trustedApplicationInformation = try strictSigningInformation(
        applicationTarget,
        checkNestedCode: true
      )
      trustedApplicationTeam = teamIdentifier(trustedApplicationInformation)
      guard trustedApplicationTeam == preliminaryApplicationTeam,
        trustedApplicationInformation[kSecCodeInfoIdentifier as String] as? String
          == expectedApplicationIdentifier
      else {
        throw signatureError("release application signing evidence changed after strict validation")
      }
      try validateTeam(trustedApplicationTeam, applicationTeam: nil, policy: policy)
    }

    let nodeInfo = try strictSigningInformation(nodeTarget, checkNestedCode: false)
    let nodeTeam = teamIdentifier(nodeInfo)
    guard nodeTeam == preliminaryNodeTeam else {
      throw signatureError("release Node team evidence changed after strict validation")
    }
    try validateTeam(nodeTeam, applicationTeam: trustedApplicationTeam, policy: policy)
    guard nodeInfo[kSecCodeInfoIdentifier as String] as? String == manifest.node.identifier,
      let flags = nodeInfo[kSecCodeInfoFlags as String] as? NSNumber,
      flags.uint32Value & hardenedRuntimeFlag == hardenedRuntimeFlag,
      let entitlements = nodeInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      Set(entitlements.keys) == Set(manifest.node.entitlementKeys),
      entitlements.allSatisfy({ ($0.value as? Bool) == true })
    else {
      throw signatureError("release Node signing metadata or entitlements differ")
    }
    let entitlementData = try JSONSerialization.data(
      withJSONObject: entitlements,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let entitlementSHA256 = sha256(entitlementData)
    guard entitlementSHA256 == manifest.node.entitlementSHA256 else {
      throw signatureError("release Node entitlement digest differs")
    }
    let expectedCodeDirectorySHA256: String
    switch policy {
    case .production:
      expectedCodeDirectorySHA256 = manifest.node.productionCodeDirectorySHA256
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .adHoc:
        expectedCodeDirectorySHA256 = manifest.node.adHocCodeDirectorySHA256
    #endif
    }
    let codeDirectorySHA256: String
    do {
      codeDirectorySHA256 = try fullCodeDirectorySHA256(
        nodeData,
        identifier: manifest.node.identifier,
        expectedSHA256: expectedCodeDirectorySHA256
      )
    } catch {
      throw signatureError("release Node full CodeDirectory evidence differs")
    }
    let expectedCDHash = Data(hexadecimal: String(codeDirectorySHA256.prefix(40)))
    let observedCDHashes = nodeInfo[kSecCodeInfoCdHashes as String] as? [Data]
    guard let expectedCDHash,
      observedCDHashes?.contains(expectedCDHash) == true
    else {
      throw signatureError("release Node CDHash evidence differs")
    }
    return ReleaseOwnedCodeSignatureEvidence(
      identifier: manifest.node.identifier,
      teamIdentifier: nodeTeam,
      codeDirectorySHA256: codeDirectorySHA256,
      entitlementSHA256: entitlementSHA256,
      hardenedRuntime: true
    )
  }

  private static func validatePreliminaryTeams(
    applicationTeam: String?,
    nodeTeam: String?,
    hasApplication: Bool,
    policy: SignaturePolicy
  ) throws {
    if hasApplication {
      try validateTeam(applicationTeam, applicationTeam: nil, policy: policy)
    }
    try validateTeam(
      nodeTeam,
      applicationTeam: hasApplication ? applicationTeam : nil,
      policy: policy
    )
  }

  #if DEBUG
    static func observeProductionStrictValidationForTesting(
      preliminaryApplicationTeam: String?,
      preliminaryNodeTeam: String?,
      observer: () -> Void
    ) throws {
      // This rejection-only seam returns no signing evidence and cannot authorize a runtime.
      try validatePreliminaryTeams(
        applicationTeam: preliminaryApplicationTeam,
        nodeTeam: preliminaryNodeTeam,
        hasApplication: true,
        policy: .production
      )
      observer()
    }
  #endif

  private static func validateTeam(
    _ team: String?,
    applicationTeam: String?,
    policy: SignaturePolicy
  ) throws {
    switch policy {
    case .production:
      guard team == expectedProductionTeamIdentifier,
        applicationTeam.map({ $0 == team }) ?? true
      else {
        throw signatureError("release Node and application teams differ")
      }
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .adHoc:
        guard team == nil, applicationTeam == nil else {
          throw signatureError("release ad hoc team evidence differs")
        }
    #endif
    }
  }

  private enum SignaturePolicy {
    case production
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case adHoc
    #endif
  }

  private static func signatureRequirements(
    nodeIdentifier: String,
    policy: SignaturePolicy
  ) -> (application: String?, node: String) {
    switch policy {
    case .production:
      return productionRequirements
    #if DEBUG || JIDOKA_ADHOC_RUNTIME_TESTING
      case .adHoc:
        return (nil, "identifier \"\(nodeIdentifier)\"")
    #endif
    }
  }

  private struct SigningTarget {
    let code: SecStaticCode
    let requirement: SecRequirement?
    let preliminaryInformation: [String: Any]
  }

  private static func signingTarget(
    _ url: URL,
    requirement requirementText: String?
  ) throws -> SigningTarget {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code
    else { throw signatureError() }
    var requirement: SecRequirement?
    if let requirementText {
      guard
        SecRequirementCreateWithString(
          requirementText as CFString,
          SecCSFlags(),
          &requirement
        ) == errSecSuccess
      else { throw signatureError() }
    }
    return try SigningTarget(
      code: code,
      requirement: requirement,
      preliminaryInformation: copySigningInformation(code)
    )
  }

  private static func strictSigningInformation(
    _ target: SigningTarget,
    checkNestedCode: Bool
  ) throws -> [String: Any] {
    var rawFlags = UInt32(
      kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSRestrictSymlinks)
    if checkNestedCode { rawFlags |= UInt32(kSecCSCheckNestedCode) }
    guard
      SecStaticCodeCheckValidity(
        target.code,
        SecCSFlags(rawValue: rawFlags),
        target.requirement
      ) == errSecSuccess
    else { throw signatureError() }
    return try copySigningInformation(target.code)
  }

  private static func copySigningInformation(_ code: SecStaticCode) throws -> [String: Any] {
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let values = information as? [String: Any]
    else { throw signatureError() }
    return values
  }

  private static func teamIdentifier(_ information: [String: Any]) -> String? {
    information[kSecCodeInfoTeamIdentifier as String] as? String
  }

  private static func fullCodeDirectorySHA256(
    _ data: Data,
    identifier: String,
    expectedSHA256: String
  ) throws -> String {
    guard data.count >= 32,
      readLittleUInt32(data, 0) == 0xFEED_FACF,
      let commandCount = readLittleUInt32(data, 16),
      let commandBytes = readLittleUInt32(data, 20),
      commandCount <= 4_096,
      Int(commandBytes) <= data.count - 32
    else { throw signatureError() }
    var cursor = 32
    var signatureRange: Range<Int>?
    for _ in 0..<commandCount {
      guard let command = readLittleUInt32(data, cursor),
        let size = readLittleUInt32(data, cursor + 4),
        size >= 8,
        cursor + Int(size) <= 32 + Int(commandBytes)
      else { throw signatureError() }
      if command == 0x0000_001D {
        guard signatureRange == nil,
          size >= 16,
          let offset = readLittleUInt32(data, cursor + 8),
          let length = readLittleUInt32(data, cursor + 12),
          Int(offset) <= data.count,
          Int(length) <= data.count - Int(offset)
        else { throw signatureError() }
        signatureRange = Int(offset)..<(Int(offset) + Int(length))
      }
      cursor += Int(size)
    }
    guard cursor == 32 + Int(commandBytes), let signatureRange else {
      throw signatureError()
    }
    let rawSignature = Data(data[signatureRange])
    guard readBigUInt32(rawSignature, 0) == 0xFADE_0CC0,
      let length = readBigUInt32(rawSignature, 4),
      Int(length) <= rawSignature.count,
      rawSignature.dropFirst(Int(length)).allSatisfy({ $0 == 0 })
    else { throw signatureError() }
    let signature = Data(rawSignature.prefix(Int(length)))
    guard let count = readBigUInt32(signature, 8),
      count <= 64,
      12 + Int(count) * 8 <= signature.count
    else { throw signatureError() }
    var matches = 0
    for index in 0..<Int(count) {
      guard let offset = readBigUInt32(signature, 12 + index * 8 + 4),
        Int(offset) <= signature.count - 8,
        readBigUInt32(signature, Int(offset)) == 0xFADE_0C02,
        let blobLength = readBigUInt32(signature, Int(offset) + 4),
        blobLength >= 40,
        Int(blobLength) <= signature.count - Int(offset)
      else { continue }
      let blob = Data(signature[Int(offset)..<(Int(offset) + Int(blobLength))])
      guard blob.count > 40,
        blob[36] == 32,
        blob[37] == 2,
        let identifierOffset = readBigUInt32(blob, 20),
        Int(identifierOffset) < blob.count,
        let end = blob[Int(identifierOffset)...].firstIndex(of: 0),
        let observedIdentifier = String(
          data: blob[Int(identifierOffset)..<end],
          encoding: .utf8
        ),
        observedIdentifier == identifier
      else { continue }
      let digest = sha256(blob)
      if digest == expectedSHA256 { matches += 1 }
    }
    guard matches == 1 else { throw signatureError() }
    return expectedSHA256
  }

  private static func readLittleUInt32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return data.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  private static func readBigUInt32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return data.withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  private static func signatureError(
    _ detail: String = "release application or Node signature differs"
  ) -> PiRuntimeResolutionError {
    PiRuntimeResolutionError(
      code: .releaseSignatureInvalid,
      detail: detail
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct ReleaseOwnedPiRuntimeManifest: Equatable {
  let runtimeID: String
  let rootEntries: [String]
  let node: Node
  let pi: Pi
  let license: License

  struct Node: Equatable {
    let adHocCodeDirectorySHA256: String
    let architecture: String
    let entitlementSHA256: String
    let entitlementKeys: [String]
    let identifier: String
    let machoDependencies: [String]
    let mode: Int
    let productionCodeDirectorySHA256: String
    let relativePath: String
    let signatureTeam: String
    let sizeAtAdHocQualification: Int
    let upstreamArchiveSHA256: String
    let upstreamNodeSHA256: String
    let upstreamSignerFingerprint: String
    let version: String
  }

  struct Pi: Equatable {
    let cliRelativePath: String
    let criticalFiles: [String: String]
    let package: String
    let packageTree: PiRuntimeTreeAttestation
    let relativeRoot: String
    let version: String
  }

  struct License: Equatable {
    let mode: Int
    let relativePath: String
    let sha256: String
    let size: Int
  }

  static func parseCanonical(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 64 * 1_024, data.last == 0x0A,
      let object = try? JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any],
      Set(object.keys)
        == Set(["licenses", "node", "pi", "rootEntries", "runtimeID", "schemaVersion"]),
      object["schemaVersion"] as? Int == 2,
      let runtimeID = object["runtimeID"] as? String,
      let rootEntries = object["rootEntries"] as? [String],
      let licenses = object["licenses"] as? [String: Any],
      Set(licenses.keys) == Set(["node"]),
      let licenseObject = licenses["node"] as? [String: Any],
      Set(licenseObject.keys) == Set(["mode", "relativePath", "sha256", "size"]),
      let licenseMode = licenseObject["mode"] as? Int,
      let licensePath = licenseObject["relativePath"] as? String,
      let licenseSHA256 = licenseObject["sha256"] as? String,
      let licenseSize = licenseObject["size"] as? Int,
      let nodeObject = object["node"] as? [String: Any],
      Set(nodeObject.keys)
        == Set([
          "adHocCodeDirectorySHA256", "architecture", "entitlementPolicy", "identifier",
          "machoDependencies", "mode", "productionCodeDirectorySHA256", "relativePath",
          "signatureTeam", "sizeAtAdHocQualification", "upstream", "version",
        ]),
      let adHocCodeDirectorySHA256 = nodeObject["adHocCodeDirectorySHA256"] as? String,
      let architecture = nodeObject["architecture"] as? String,
      let entitlementObject = nodeObject["entitlementPolicy"] as? [String: Any],
      Set(entitlementObject.keys) == Set(["canonicalSHA256", "keys"]),
      let entitlementSHA256 = entitlementObject["canonicalSHA256"] as? String,
      let entitlementKeys = entitlementObject["keys"] as? [String],
      let identifier = nodeObject["identifier"] as? String,
      let machoDependencies = nodeObject["machoDependencies"] as? [String],
      let nodeMode = nodeObject["mode"] as? Int,
      let productionCodeDirectorySHA256 =
        nodeObject["productionCodeDirectorySHA256"] as? String,
      let nodePath = nodeObject["relativePath"] as? String,
      let signatureTeam = nodeObject["signatureTeam"] as? String,
      let nodeSize = nodeObject["sizeAtAdHocQualification"] as? Int,
      let upstream = nodeObject["upstream"] as? [String: Any],
      Set(upstream.keys) == Set(["archiveSHA256", "nodeSHA256", "signerFingerprint"]),
      let archiveSHA256 = upstream["archiveSHA256"] as? String,
      let upstreamNodeSHA256 = upstream["nodeSHA256"] as? String,
      let signerFingerprint = upstream["signerFingerprint"] as? String,
      let nodeVersion = nodeObject["version"] as? String,
      let piObject = object["pi"] as? [String: Any],
      Set(piObject.keys)
        == Set([
          "cliRelativePath", "criticalFiles", "package", "packageTree", "relativeRoot", "version",
        ]),
      let cliRelativePath = piObject["cliRelativePath"] as? String,
      let criticalFiles = piObject["criticalFiles"] as? [String: String],
      let package = piObject["package"] as? String,
      let packageTreeObject = piObject["packageTree"] as? [String: Any],
      Set(packageTreeObject.keys) == Set(["entryCount", "sha256"]),
      let entryCount = packageTreeObject["entryCount"] as? Int,
      let packageTreeSHA256 = packageTreeObject["sha256"] as? String,
      let piRoot = piObject["relativeRoot"] as? String,
      let piVersion = piObject["version"] as? String
    else { throw malformed() }
    let canonical =
      try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ) + Data([0x0A])
    guard canonical == data else { throw malformed() }
    return Self(
      runtimeID: runtimeID,
      rootEntries: rootEntries,
      node: Node(
        adHocCodeDirectorySHA256: adHocCodeDirectorySHA256,
        architecture: architecture,
        entitlementSHA256: entitlementSHA256,
        entitlementKeys: entitlementKeys,
        identifier: identifier,
        machoDependencies: machoDependencies,
        mode: nodeMode,
        productionCodeDirectorySHA256: productionCodeDirectorySHA256,
        relativePath: nodePath,
        signatureTeam: signatureTeam,
        sizeAtAdHocQualification: nodeSize,
        upstreamArchiveSHA256: archiveSHA256,
        upstreamNodeSHA256: upstreamNodeSHA256,
        upstreamSignerFingerprint: signerFingerprint,
        version: nodeVersion
      ),
      pi: Pi(
        cliRelativePath: cliRelativePath,
        criticalFiles: criticalFiles,
        package: package,
        packageTree: PiRuntimeTreeAttestation(
          entryCount: entryCount,
          sha256: packageTreeSHA256
        ),
        relativeRoot: piRoot,
        version: piVersion
      ),
      license: License(
        mode: licenseMode,
        relativePath: licensePath,
        sha256: licenseSHA256,
        size: licenseSize
      )
    )
  }

  func validateLockedPolicy() throws {
    let entitlementKeys = [
      "com.apple.security.cs.allow-jit",
      "com.apple.security.cs.allow-unsigned-executable-memory",
    ]
    let criticalPaths = Set([
      "dist/cli.js",
      "dist/core/sdk.js",
      "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js",
      "package.json",
    ])
    guard runtimeID.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{7,127}$/) != nil,
      rootEntries == ["licenses", "node", "pi", "runtime-manifest.json"],
      GitHubInputValidation.validSHA256(node.adHocCodeDirectorySHA256),
      node.architecture == "arm64",
      GitHubInputValidation.validSHA256(node.entitlementSHA256),
      node.entitlementKeys == entitlementKeys,
      node.identifier == "works.earendil.jidoka.runtime.node",
      Set(node.machoDependencies).count == node.machoDependencies.count,
      node.machoDependencies.allSatisfy({
        $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/")
      }),
      node.mode == 0o555,
      GitHubInputValidation.validSHA256(node.productionCodeDirectorySHA256),
      node.productionCodeDirectorySHA256 != node.adHocCodeDirectorySHA256,
      node.relativePath == "node/bin/node",
      node.signatureTeam == "same-as-containing-application",
      (1...512 * 1_048_576).contains(node.sizeAtAdHocQualification),
      GitHubInputValidation.validSHA256(node.upstreamArchiveSHA256),
      GitHubInputValidation.validSHA256(node.upstreamNodeSHA256),
      node.upstreamSignerFingerprint.wholeMatch(of: /^[0-9A-F]{40}$/) != nil,
      (try? PiSemanticVersion(node.version)) != nil,
      pi.cliRelativePath == "dist/cli.js",
      Set(pi.criticalFiles.keys) == criticalPaths,
      pi.criticalFiles.values.allSatisfy(GitHubInputValidation.validSHA256),
      pi.package == "@earendil-works/pi-coding-agent",
      (1...100_000).contains(pi.packageTree.entryCount),
      GitHubInputValidation.validSHA256(pi.packageTree.sha256),
      pi.relativeRoot == "pi",
      (try? PiSemanticVersion(pi.version)) != nil,
      license.mode == 0o444,
      license.relativePath == "licenses/node-LICENSE",
      GitHubInputValidation.validSHA256(license.sha256),
      (1...2 * 1_048_576).contains(license.size)
    else { throw Self.malformed() }
  }

  private static func malformed() -> PiRuntimeResolutionError {
    PiRuntimeResolutionError(
      code: .malformedReleaseManifest,
      detail: "release runtime manifest is non-canonical or invalid"
    )
  }
}

extension Data {
  fileprivate init?(hexadecimal: String) {
    guard hexadecimal.count.isMultiple(of: 2),
      hexadecimal.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      })
    else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hexadecimal.count / 2)
    var index = hexadecimal.startIndex
    while index < hexadecimal.endIndex {
      let end = hexadecimal.index(index, offsetBy: 2)
      guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
      bytes.append(byte)
      index = end
    }
    self = Data(bytes)
  }
}
