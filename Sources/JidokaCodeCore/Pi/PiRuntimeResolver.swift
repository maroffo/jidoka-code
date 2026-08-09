import CryptoKit
import Darwin
import Foundation

enum DarwinACLAuthority {
  // Deny-only ACLs are harmless; any extended allow ACE expands the POSIX mode boundary.
  static func hasNoAllowEntries(_ descriptor: Int32) -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    var selector = ACL_FIRST_ENTRY
    while acl_get_entry(acl, Int32(selector.rawValue), &entry) == 0 {
      var tag = acl_tag_t(0)
      guard acl_get_tag_type(entry, &tag) == 0,
        tag == ACL_EXTENDED_ALLOW || tag == ACL_EXTENDED_DENY
      else {
        return false
      }
      if tag == ACL_EXTENDED_ALLOW { return false }
      selector = ACL_NEXT_ENTRY
    }
    return true
  }
}

public struct PiSemanticVersion: Comparable, Codable, CustomStringConvertible, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public var description: String { "\(major).\(minor).\(patch)" }

  public init(_ value: String) throws {
    let pattern = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/
    guard let match = value.wholeMatch(of: pattern),
      let major = Int(match.1),
      let minor = Int(match.2),
      let patch = Int(match.3)
    else {
      throw PiRuntimeResolutionError(
        code: .malformedCompatibilityPolicy,
        detail: "invalid semantic version"
      )
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public static func < (lhs: PiSemanticVersion, rhs: PiSemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public struct PiRuntimeCompatibility: Equatable, Sendable {
  public let minimumVersion: PiSemanticVersion
  public let maximumVersionExclusive: PiSemanticVersion
  public let policySHA256: String

  public init(
    minimumVersion: PiSemanticVersion,
    maximumVersionExclusive: PiSemanticVersion,
    policySHA256: String
  ) {
    self.minimumVersion = minimumVersion
    self.maximumVersionExclusive = maximumVersionExclusive
    self.policySHA256 = policySHA256
  }
}

public struct PiRuntimeTreeAttestation: Equatable, Sendable {
  public let entryCount: Int
  public let sha256: String

  public init(entryCount: Int, sha256: String) {
    self.entryCount = entryCount
    self.sha256 = sha256
  }
}

public struct PiResolvedRuntime: Equatable, Sendable {
  public let nodeURL: URL
  public let nodeVersion: PiSemanticVersion
  public let nodeSHA256: String
  public let nodeDynamicLibrarySHA256: [String: String]
  public let nodeDynamicLibraryLoadPaths: [String: String]
  public let nodeDynamicLibraryDirectoryURL: URL?
  public let piCLIURL: URL
  public let piCLIRelativePath: String
  public let piPackageRootURL: URL
  public let piVersion: PiSemanticVersion
  public let piRuntimeSHA256: [String: String]
  public let compatibility: PiRuntimeCompatibility

  public init(
    nodeURL: URL,
    nodeVersion: PiSemanticVersion,
    nodeSHA256: String,
    nodeDynamicLibrarySHA256: [String: String] = [:],
    nodeDynamicLibraryLoadPaths: [String: String] = [:],
    nodeDynamicLibraryDirectoryURL: URL? = nil,
    piCLIURL: URL,
    piCLIRelativePath: String = "dist/cli.js",
    piPackageRootURL: URL,
    piVersion: PiSemanticVersion,
    piRuntimeSHA256: [String: String],
    compatibility: PiRuntimeCompatibility
  ) {
    self.nodeURL = nodeURL
    self.nodeVersion = nodeVersion
    self.nodeSHA256 = nodeSHA256
    self.nodeDynamicLibrarySHA256 = nodeDynamicLibrarySHA256
    self.nodeDynamicLibraryLoadPaths = nodeDynamicLibraryLoadPaths
    self.nodeDynamicLibraryDirectoryURL = nodeDynamicLibraryDirectoryURL
    self.piCLIURL = piCLIURL
    self.piCLIRelativePath = piCLIRelativePath
    self.piPackageRootURL = piPackageRootURL
    self.piVersion = piVersion
    self.piRuntimeSHA256 = piRuntimeSHA256
    self.compatibility = compatibility
  }
}

public enum PiRuntimeIssueCode: String, Codable, Sendable {
  case malformedCompatibilityPolicy
  case unsafeCompatibilityPolicy
  case piRuntimeNotFound
  case invalidPiPackage
  case unsupportedPiVersion
  case unattestedPiBuild
  case invalidPiShebang
  case nodeRuntimeNotFound
  case unattestedNodeBuild
}

public struct PiRuntimeResolutionError: Error, Equatable, Sendable {
  public let code: PiRuntimeIssueCode
  public let detail: String

  public init(code: PiRuntimeIssueCode, detail: String) {
    self.code = code
    self.detail = detail
  }
}

public struct PiRuntimePreflightIssue: Equatable, Sendable {
  public let code: PiRuntimeIssueCode
  public let summary: String
  public let recovery: String

  public init(code: PiRuntimeIssueCode, summary: String, recovery: String) {
    self.code = code
    self.summary = summary
    self.recovery = recovery
  }
}

public enum PiRuntimePreflightResult: Equatable, Sendable {
  case ready(PiResolvedRuntime)
  case blocked(PiRuntimePreflightIssue)
}

public struct PiRuntimeResolverConfiguration: Sendable {
  public let piCandidates: [URL]
  public let nodeCandidates: [URL]
  public let piPolicyURL: URL
  public let nodePolicyURL: URL
  public let maximumRuntimeFileBytes: Int
  public let maximumNodeLibraryBytes: Int

  public init(
    piCandidates: [URL],
    nodeCandidates: [URL],
    piPolicyURL: URL,
    nodePolicyURL: URL,
    maximumRuntimeFileBytes: Int = 16 * 1_048_576,
    maximumNodeLibraryBytes: Int = 128 * 1_048_576
  ) {
    self.piCandidates = piCandidates
    self.nodeCandidates = nodeCandidates
    self.piPolicyURL = piPolicyURL
    self.nodePolicyURL = nodePolicyURL
    self.maximumRuntimeFileBytes = maximumRuntimeFileBytes
    self.maximumNodeLibraryBytes = maximumNodeLibraryBytes
  }

  public static func standard(resourceRoot: URL) -> PiRuntimeResolverConfiguration {
    PiRuntimeResolverConfiguration(
      piCandidates: [
        URL(fileURLWithPath: "/opt/homebrew/bin/pi"),
        URL(
          fileURLWithPath:
            "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
        ),
        URL(fileURLWithPath: "/usr/local/bin/pi"),
      ],
      nodeCandidates: [
        URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        URL(fileURLWithPath: "/opt/homebrew/Cellar/node/26.6.0/bin/node"),
        URL(fileURLWithPath: "/usr/local/bin/node"),
        URL(fileURLWithPath: "/usr/bin/node"),
      ],
      piPolicyURL: resourceRoot.appendingPathComponent(
        "runtime/pi-runtime-builds.json",
        isDirectory: false
      ),
      nodePolicyURL: resourceRoot.appendingPathComponent(
        "runtime/node-runtime-builds.json",
        isDirectory: false
      )
    )
  }
}

public protocol PiRuntimeResolving: Sendable {
  func resolve() throws -> PiResolvedRuntime
}

public struct PiRuntimeResolver: PiRuntimeResolving, Sendable {
  private static let expectedPackageName = "@earendil-works/pi-coding-agent"
  private static let expectedPiRuntimePaths: Set<String> = [
    "dist/cli.js",
    "dist/core/sdk.js",
    "node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js",
    "package.json",
  ]

  private let configuration: PiRuntimeResolverConfiguration

  public init(configuration: PiRuntimeResolverConfiguration) {
    self.configuration = configuration
  }

  public func preflight() -> PiRuntimePreflightResult {
    do {
      return .ready(try resolve())
    } catch let error as PiRuntimeResolutionError {
      return .blocked(Self.actionableIssue(for: error))
    } catch {
      return .blocked(
        PiRuntimePreflightIssue(
          code: .invalidPiPackage,
          summary: "Pi runtime validation failed.",
          recovery: "Reinstall an attested Pi and Node build, then run preflight again."
        )
      )
    }
  }

  public func resolve() throws -> PiResolvedRuntime {
    guard (1...64 * 1_024 * 1_024).contains(configuration.maximumRuntimeFileBytes),
      (1...512 * 1_024 * 1_024).contains(configuration.maximumNodeLibraryBytes)
    else {
      throw PiRuntimeResolutionError(
        code: .malformedCompatibilityPolicy,
        detail: "invalid runtime file bound"
      )
    }
    let piPolicyData = try readPolicy(configuration.piPolicyURL)
    let nodePolicyData = try readPolicy(configuration.nodePolicyURL)
    let piPolicy = try Self.parsePiPolicy(piPolicyData)
    let nodePolicy = try Self.parseNodePolicy(nodePolicyData)
    let piResolution = try resolvePi(policy: piPolicy)
    let nodeResolution = try resolveNode(
      policy: nodePolicy,
      shebang: piResolution.shebang
    )
    return PiResolvedRuntime(
      nodeURL: nodeResolution.url,
      nodeVersion: nodeResolution.version,
      nodeSHA256: nodeResolution.digest,
      nodeDynamicLibrarySHA256: nodeResolution.dynamicLibraryDigests,
      nodeDynamicLibraryLoadPaths: nodeResolution.dynamicLibraryLoadPaths,
      piCLIURL: piResolution.cliURL,
      piPackageRootURL: piResolution.packageRoot,
      piVersion: piResolution.version,
      piRuntimeSHA256: piResolution.digests,
      compatibility: PiRuntimeCompatibility(
        minimumVersion: piPolicy.minimum,
        maximumVersionExclusive: piPolicy.maximum,
        policySHA256: Self.sha256(piPolicyData)
      )
    )
  }

  private func resolvePi(policy: PiPolicy) throws -> PiResolution {
    var failures: [PiRuntimeResolutionError] = []
    for candidate in uniqueCanonicalCandidates(configuration.piCandidates) {
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      do {
        return try validatePiCandidate(candidate, policy: policy)
      } catch let error as PiRuntimeResolutionError {
        failures.append(error)
      }
    }
    if let failure = Self.preferredFailure(failures) { throw failure }
    throw PiRuntimeResolutionError(
      code: .piRuntimeNotFound,
      detail: "no Pi candidate exists"
    )
  }

  private func validatePiCandidate(_ candidate: URL, policy: PiPolicy) throws -> PiResolution {
    let cliURL = candidate.resolvingSymlinksInPath().standardizedFileURL
    let suffix = "/dist/cli.js"
    guard cliURL.path.hasSuffix(suffix) else {
      throw PiRuntimeResolutionError(
        code: .invalidPiPackage,
        detail: "Pi candidate is not the package CLI"
      )
    }
    let packageRoot = URL(
      fileURLWithPath: String(cliURL.path.dropLast(suffix.count)),
      isDirectory: true
    )
    let packageURL = packageRoot.appendingPathComponent("package.json", isDirectory: false)
    let packageData = try readRuntimeFile(packageURL, failureCode: .invalidPiPackage)
    guard let metadata = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
      metadata["name"] as? String == Self.expectedPackageName,
      let versionString = metadata["version"] as? String
    else {
      throw PiRuntimeResolutionError(
        code: .invalidPiPackage,
        detail: "Pi package identity is invalid"
      )
    }
    let version: PiSemanticVersion
    do {
      version = try PiSemanticVersion(versionString)
    } catch {
      throw PiRuntimeResolutionError(
        code: .invalidPiPackage,
        detail: "Pi package version is malformed"
      )
    }
    guard version >= policy.minimum, version < policy.maximum else {
      throw PiRuntimeResolutionError(
        code: .unsupportedPiVersion,
        detail: "Pi \(version) is outside the supported range"
      )
    }
    guard let build = policy.builds[versionString] else {
      throw PiRuntimeResolutionError(
        code: .unattestedPiBuild,
        detail: "Pi \(version) has no attested build"
      )
    }
    var digests: [String: String] = [:]
    for relativePath in Self.expectedPiRuntimePaths.sorted() {
      let fileURL = packageRoot.appendingPathComponent(relativePath, isDirectory: false)
      let data =
        relativePath == "package.json"
        ? packageData
        : try readRuntimeFile(fileURL, failureCode: .unattestedPiBuild)
      let digest = Self.sha256(data)
      guard digest == build.criticalFiles[relativePath] else {
        throw PiRuntimeResolutionError(
          code: .unattestedPiBuild,
          detail: "Pi runtime digest mismatch for \(relativePath)"
        )
      }
      digests[relativePath] = digest
    }
    let tree: PiRuntimeTreeAttestation
    do {
      tree = try Self.attestPackageTree(
        packageRoot,
        maximumFileBytes: configuration.maximumRuntimeFileBytes
      )
    } catch {
      throw PiRuntimeResolutionError(
        code: .unattestedPiBuild,
        detail: "Pi package tree is missing, redirected, or unsafe"
      )
    }
    guard tree == build.packageTree else {
      throw PiRuntimeResolutionError(
        code: .unattestedPiBuild,
        detail: "Pi package tree digest or inventory mismatch"
      )
    }
    digests["package-tree-v1"] = tree.sha256
    let cliData = try readRuntimeFile(cliURL, failureCode: .invalidPiPackage)
    let shebang = try Self.parseShebang(cliData)
    return PiResolution(
      cliURL: cliURL,
      packageRoot: packageRoot,
      version: version,
      digests: digests,
      shebang: shebang
    )
  }

  private func resolveNode(policy: NodePolicy, shebang: PiShebang) throws -> NodeResolution {
    var candidates = configuration.nodeCandidates
    if case .absolute(let path) = shebang {
      candidates.insert(URL(fileURLWithPath: path), at: 0)
    }
    var observedCandidate = false
    for candidate in uniqueCanonicalCandidates(candidates) {
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      observedCandidate = true
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      if case .absolute(let expectedPath) = shebang,
        resolved.path != URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath().path
      {
        continue
      }
      guard FileManager.default.isExecutableFile(atPath: resolved.path),
        let data = try? readRuntimeFile(resolved, failureCode: .unattestedNodeBuild)
      else {
        continue
      }
      let digest = Self.sha256(data)
      guard
        let match = policy.builds.first(where: { _, build in
          build.executable.canonicalPath == resolved.path
            && build.executable.sha256 == digest
        }),
        let version = try? PiSemanticVersion(match.key)
      else {
        continue
      }
      do {
        let dynamicLibraryDigests = try validateNodeLibraries(
          match.value.dynamicLibraries,
          executableURL: resolved,
          executableData: data
        )
        return NodeResolution(
          url: resolved,
          version: version,
          digest: digest,
          dynamicLibraryDigests: dynamicLibraryDigests,
          dynamicLibraryLoadPaths: Dictionary(
            uniqueKeysWithValues: match.value.dynamicLibraries.map {
              ($0.loadPath, $0.canonicalPath)
            }
          )
        )
      } catch {
        continue
      }
    }
    throw PiRuntimeResolutionError(
      code: observedCandidate ? .unattestedNodeBuild : .nodeRuntimeNotFound,
      detail: observedCandidate
        ? "no Node candidate and dynamic-library closure match the packaged digest policy"
        : "no Node candidate exists"
    )
  }

  private func validateNodeLibraries(
    _ libraries: [NodeDynamicLibrary],
    executableURL: URL,
    executableData: Data
  ) throws -> [String: String] {
    var observed: [String: String] = [:]
    var libraryData: [String: Data] = [:]
    for library in libraries {
      let loadURL: URL
      if library.loadPath.hasPrefix("@") {
        loadURL = URL(fileURLWithPath: library.canonicalPath, isDirectory: false)
      } else {
        loadURL = URL(fileURLWithPath: library.loadPath, isDirectory: false)
      }
      let canonical = loadURL.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.path == library.canonicalPath else {
        throw PiRuntimeResolutionError(
          code: .unattestedNodeBuild,
          detail: "Node dynamic-library target mismatch for \(library.loadPath)"
        )
      }
      let data = try Self.readRegularFile(
        canonical,
        maximumBytes: configuration.maximumNodeLibraryBytes
      )
      let digest = Self.sha256(data)
      guard digest == library.sha256 else {
        throw PiRuntimeResolutionError(
          code: .unattestedNodeBuild,
          detail: "Node dynamic-library digest mismatch for \(library.loadPath)"
        )
      }
      observed[library.canonicalPath] = digest
      libraryData[library.canonicalPath] = data
    }
    try Self.validateMachODependencyClosure(
      executableURL: executableURL,
      executableData: executableData,
      libraries: libraries,
      libraryData: libraryData
    )
    return observed
  }

  private static func validateMachODependencyClosure(
    executableURL: URL,
    executableData: Data,
    libraries: [NodeDynamicLibrary],
    libraryData: [String: Data]
  ) throws {
    let expectedPaths = Set(libraries.map(\.canonicalPath))
    var images = libraryData
    images[executableURL.path] = executableData
    let executableMetadata = try parseMachO(executableData)
    var reachable: Set<String> = []
    var pending = [executableURL.path]
    while let imagePath = pending.popLast() {
      guard let data = images[imagePath] else {
        throw unattestedNodeClosureError()
      }
      let metadata = try parseMachO(data)
      for dependency in metadata.dependencies where !systemMachODependency(dependency) {
        let canonicalPath = try resolveMachODependency(
          dependency,
          imagePath: imagePath,
          imageRPaths: metadata.rpaths,
          executableURL: executableURL,
          executableRPaths: executableMetadata.rpaths,
          expectedPaths: expectedPaths
        )
        guard expectedPaths.contains(canonicalPath) else {
          throw unattestedNodeClosureError()
        }
        if reachable.insert(canonicalPath).inserted {
          pending.append(canonicalPath)
        }
      }
    }
    guard reachable == expectedPaths else {
      throw unattestedNodeClosureError()
    }
  }

  private static func parseMachO(_ data: Data) throws -> MachOMetadata {
    let headerSize = 32
    guard data.count >= headerSize,
      try readUInt32(data, at: 0) == 0xFEED_FACF
    else {
      throw unattestedNodeClosureError()
    }
    let commandCount = Int(try readUInt32(data, at: 16))
    let commandBytes = Int(try readUInt32(data, at: 20))
    guard commandCount <= 4_096,
      commandBytes <= data.count - headerSize
    else {
      throw unattestedNodeClosureError()
    }
    let dependencyCommands: Set<UInt32> = [
      0x0000_000C,
      0x0000_0020,
      0x8000_0018,
      0x8000_001F,
      0x8000_0023,
    ]
    var dependencies: [String] = []
    var rpaths: [String] = []
    var cursor = headerSize
    for _ in 0..<commandCount {
      guard cursor <= headerSize + commandBytes - 8 else {
        throw unattestedNodeClosureError()
      }
      let command = try readUInt32(data, at: cursor)
      let commandSize = Int(try readUInt32(data, at: cursor + 4))
      guard commandSize >= 8,
        cursor + commandSize <= headerSize + commandBytes
      else {
        throw unattestedNodeClosureError()
      }
      if dependencyCommands.contains(command) {
        guard commandSize >= 24 else { throw unattestedNodeClosureError() }
        let offset = Int(try readUInt32(data, at: cursor + 8))
        dependencies.append(
          try readMachOString(data, start: cursor + offset, end: cursor + commandSize)
        )
      } else if command == 0x8000_001C {
        guard commandSize >= 12 else { throw unattestedNodeClosureError() }
        let offset = Int(try readUInt32(data, at: cursor + 8))
        rpaths.append(
          try readMachOString(data, start: cursor + offset, end: cursor + commandSize)
        )
      }
      cursor += commandSize
    }
    guard cursor == headerSize + commandBytes else {
      throw unattestedNodeClosureError()
    }
    return MachOMetadata(dependencies: dependencies, rpaths: rpaths)
  }

  private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
      throw unattestedNodeClosureError()
    }
    return data.withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  private static func readMachOString(
    _ data: Data,
    start: Int,
    end: Int
  ) throws -> String {
    guard start >= 0, start < end, end <= data.count,
      let terminator = data[start..<end].firstIndex(of: 0),
      terminator > start,
      let value = String(data: data[start..<terminator], encoding: .utf8),
      !value.contains("\u{0}")
    else {
      throw unattestedNodeClosureError()
    }
    return value
  }

  private static func systemMachODependency(_ path: String) -> Bool {
    path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/")
  }

  private static func resolveMachODependency(
    _ dependency: String,
    imagePath: String,
    imageRPaths: [String],
    executableURL: URL,
    executableRPaths: [String],
    expectedPaths: Set<String>
  ) throws -> String {
    if dependency.hasPrefix("/") {
      let canonical = URL(fileURLWithPath: dependency).resolvingSymlinksInPath()
        .standardizedFileURL.path
      guard expectedPaths.contains(canonical) else { throw unattestedNodeClosureError() }
      return canonical
    }
    if dependency.hasPrefix("@loader_path/") {
      return try canonicalExpectedPath(
        replacing: "@loader_path",
        in: dependency,
        with: URL(fileURLWithPath: imagePath).deletingLastPathComponent().path,
        expectedPaths: expectedPaths
      )
    }
    if dependency.hasPrefix("@executable_path/") {
      return try canonicalExpectedPath(
        replacing: "@executable_path",
        in: dependency,
        with: executableURL.deletingLastPathComponent().path,
        expectedPaths: expectedPaths
      )
    }
    guard dependency.hasPrefix("@rpath/") else {
      throw unattestedNodeClosureError()
    }
    let suffix = String(dependency.dropFirst("@rpath/".count))
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains("\u{0}") else {
      throw unattestedNodeClosureError()
    }
    for rpath in imageRPaths + executableRPaths {
      guard
        let expanded = expandMachORPath(
          rpath,
          imagePath: imagePath,
          executableURL: executableURL
        )
      else { continue }
      let candidate = URL(fileURLWithPath: expanded, isDirectory: true)
        .appendingPathComponent(suffix, isDirectory: false)
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path
      guard expectedPaths.contains(canonical) else {
        throw unattestedNodeClosureError()
      }
      return canonical
    }
    throw unattestedNodeClosureError()
  }

  private static func canonicalExpectedPath(
    replacing token: String,
    in dependency: String,
    with directory: String,
    expectedPaths: Set<String>
  ) throws -> String {
    let suffix = dependency.dropFirst(token.count)
    let candidate = URL(fileURLWithPath: directory, isDirectory: true)
      .appendingPathComponent(String(suffix.dropFirst()), isDirectory: false)
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      throw unattestedNodeClosureError()
    }
    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    guard expectedPaths.contains(canonical) else { throw unattestedNodeClosureError() }
    return canonical
  }

  private static func expandMachORPath(
    _ rpath: String,
    imagePath: String,
    executableURL: URL
  ) -> String? {
    let imageDirectory = URL(fileURLWithPath: imagePath).deletingLastPathComponent().path
    let executableDirectory = executableURL.deletingLastPathComponent().path
    let expanded: String
    if rpath == "@loader_path" {
      expanded = imageDirectory
    } else if rpath.hasPrefix("@loader_path/") {
      expanded = imageDirectory + String(rpath.dropFirst("@loader_path".count))
    } else if rpath == "@executable_path" {
      expanded = executableDirectory
    } else if rpath.hasPrefix("@executable_path/") {
      expanded = executableDirectory + String(rpath.dropFirst("@executable_path".count))
    } else if rpath.hasPrefix("/") {
      expanded = rpath
    } else {
      return nil
    }
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
  }

  private static func unattestedNodeClosureError() -> PiRuntimeResolutionError {
    PiRuntimeResolutionError(
      code: .unattestedNodeBuild,
      detail: "Node Mach-O dependency closure does not match the packaged inventory"
    )
  }

  private func readPolicy(_ url: URL) throws -> Data {
    do {
      return try Self.readRegularFile(
        url,
        maximumBytes: configuration.maximumRuntimeFileBytes
      )
    } catch {
      throw PiRuntimeResolutionError(
        code: .unsafeCompatibilityPolicy,
        detail: "compatibility policy is missing or unsafe"
      )
    }
  }

  private func readRuntimeFile(_ url: URL, failureCode: PiRuntimeIssueCode) throws -> Data {
    do {
      return try Self.readRegularFile(
        url,
        maximumBytes: configuration.maximumRuntimeFileBytes
      )
    } catch {
      throw PiRuntimeResolutionError(
        code: failureCode,
        detail: "runtime file is missing, redirected, or oversized"
      )
    }
  }

  private func uniqueCanonicalCandidates(_ candidates: [URL]) -> [URL] {
    var seen: Set<String> = []
    return candidates.filter { candidate in
      guard candidate.isFileURL, candidate.path.hasPrefix("/") else { return false }
      let key = candidate.standardizedFileURL.path
      return seen.insert(key).inserted
    }
  }

  private static func readRegularFile(
    _ url: URL,
    maximumBytes: Int,
    requireSafeAncestors: Bool = false
  ) throws -> Data {
    guard url.isFileURL, url.path.hasPrefix("/"), maximumBytes >= 0,
      let canonicalPath = canonicalExistingPath(url.path),
      !requireSafeAncestors
        || safeRuntimeAncestorChain(
          URL(fileURLWithPath: canonicalPath).deletingLastPathComponent().path
        )
    else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == 0 || before.st_uid == geteuid(),
      before.st_mode & 0o022 == 0,
      before.st_nlink == 1,
      before.st_size >= 0,
      before.st_size <= maximumBytes
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
    var offset = 0
    try bytes.withUnsafeMutableBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.read(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw CocoaError(.fileReadUnknown)
        }
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_mode == after.st_mode,
      before.st_uid == after.st_uid,
      before.st_nlink == after.st_nlink,
      before.st_size == after.st_size
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return Data(bytes)
  }

  private static func safeRuntimeNode(
    _ path: String,
    requireSafeAncestors: Bool = false
  ) -> Bool {
    guard let canonical = canonicalExistingPath(path), canonical == path,
      !requireSafeAncestors
        || safeRuntimeAncestorChain(
          URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    else {
      return false
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_uid == 0 || value.st_uid == geteuid()
    else {
      return false
    }
    switch value.st_mode & S_IFMT {
    case S_IFDIR:
      return value.st_mode & 0o022 == 0
    case S_IFREG:
      return value.st_mode & 0o022 == 0 && value.st_nlink == 1
    default:
      return false
    }
  }

  private static func safeRuntimeDirectory(
    _ path: String,
    requireSafeAncestors: Bool = false
  ) -> Bool {
    guard let canonical = canonicalExistingPath(path), canonical == path,
      !requireSafeAncestors
        || safeRuntimeAncestorChain(
          URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    else {
      return false
    }
    return safeRuntimeDirectoryDescriptor(path, allowStickyWrite: false)
  }

  private static func safeRuntimeAncestorChain(_ path: String) -> Bool {
    var current = path
    while true {
      guard safeRuntimeDirectoryDescriptor(current, allowStickyWrite: true) else {
        return false
      }
      if current == "/" { return true }
      let parent = (current as NSString).deletingLastPathComponent
      guard !parent.isEmpty, parent != current else { return false }
      current = parent
    }
  }

  private static func safeRuntimeDirectoryDescriptor(
    _ path: String,
    allowStickyWrite: Bool
  ) -> Bool {
    let descriptor = Darwin.open(
      path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      value.st_mode & S_IFMT == S_IFDIR,
      value.st_uid == 0 || value.st_uid == geteuid()
    else {
      return false
    }
    let writable = value.st_mode & 0o022 != 0
    return !writable || (allowStickyWrite && value.st_mode & S_ISVTX != 0)
  }

  static func materializePrivateSnapshot(
    of runtime: PiResolvedRuntime,
    in parentDirectory: URL
  ) throws -> PiResolvedRuntime {
    do {
      return try materializePrivateSnapshotUnchecked(
        of: runtime,
        in: parentDirectory
      )
    } catch let error as PiRuntimeResolutionError {
      throw error
    } catch {
      throw PiRuntimeResolutionError(
        code: .unattestedPiBuild,
        detail: "private runtime snapshot could not be materialized"
      )
    }
  }

  private static func materializePrivateSnapshotUnchecked(
    of runtime: PiResolvedRuntime,
    in parentDirectory: URL
  ) throws -> PiResolvedRuntime {
    guard parentDirectory.isFileURL,
      let canonicalParentPath = canonicalExistingPath(parentDirectory.path),
      safeRuntimeDirectory(canonicalParentPath, requireSafeAncestors: true),
      let packageTreeSHA256 = runtime.piRuntimeSHA256["package-tree-v1"]
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let parent = URL(fileURLWithPath: canonicalParentPath, isDirectory: true)
    let snapshotIdentity = sha256(
      Data(
        ([runtime.nodeSHA256, packageTreeSHA256, runtime.piCLIRelativePath]
          + runtime.nodeDynamicLibrarySHA256.values.sorted()
          + runtime.nodeDynamicLibraryLoadPaths.map { "\($0.key)=\($0.value)" }.sorted())
          .joined(separator: "\u{0}").utf8
      )
    )
    let destination = parent.appendingPathComponent(
      "runtime-snapshot-\(snapshotIdentity.prefix(24))",
      isDirectory: true
    )
    let expectedMarker = try privateSnapshotMarker(
      runtime: runtime,
      packageTreeSHA256: packageTreeSHA256
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      do {
        return try verifyPrivateSnapshot(
          at: destination,
          source: runtime,
          expectedMarker: expectedMarker,
          packageTreeSHA256: packageTreeSHA256
        )
      } catch {
        try FileManager.default.removeItem(at: destination)
      }
    }

    let staging = parent.appendingPathComponent(
      ".runtime-snapshot-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    var keepStaging = true
    defer {
      if keepStaging {
        try? FileManager.default.removeItem(at: staging)
      }
    }

    let nodeDestination = staging.appendingPathComponent("node")
    try copyRuntimeFile(
      from: runtime.nodeURL,
      to: nodeDestination,
      maximumBytes: 512 * 1_048_576
    )
    let libraryDirectory = staging.appendingPathComponent("lib", isDirectory: true)
    try FileManager.default.createDirectory(
      at: libraryDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    var libraryNames = Set<String>()
    for sourcePath in runtime.nodeDynamicLibrarySHA256.keys.sorted() {
      let name = URL(fileURLWithPath: sourcePath).lastPathComponent
      guard !name.isEmpty, libraryNames.insert(name).inserted else {
        throw CocoaError(.fileReadCorruptFile)
      }
      try copyRuntimeFile(
        from: URL(fileURLWithPath: sourcePath),
        to: libraryDirectory.appendingPathComponent(name),
        maximumBytes: 512 * 1_048_576
      )
    }
    for (alias, target) in try privateSnapshotLibraryAliases(runtime: runtime) {
      guard !libraryNames.contains(alias) else { throw CocoaError(.fileReadCorruptFile) }
      try FileManager.default.createSymbolicLink(
        atPath: libraryDirectory.appendingPathComponent(alias).path,
        withDestinationPath: target
      )
    }
    let packageDestination = staging.appendingPathComponent("pi", isDirectory: true)
    try copyRuntimePackage(
      from: runtime.piPackageRootURL,
      to: packageDestination
    )
    try writePrivateSnapshotFile(
      expectedMarker,
      to: staging.appendingPathComponent("snapshot.json"),
      permissions: 0o400
    )
    guard rename(staging.path, destination.path) == 0 else {
      throw CocoaError(.fileWriteFileExists)
    }
    keepStaging = false
    return try verifyPrivateSnapshot(
      at: destination,
      source: runtime,
      expectedMarker: expectedMarker,
      packageTreeSHA256: packageTreeSHA256
    )
  }

  private static func privateSnapshotMarker(
    runtime: PiResolvedRuntime,
    packageTreeSHA256: String
  ) throws -> Data {
    var libraries: [String: String] = [:]
    for (path, digest) in runtime.nodeDynamicLibrarySHA256 {
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard !name.isEmpty, libraries[name] == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      libraries[name] = digest
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1,
        "nodeVersion": runtime.nodeVersion.description,
        "nodeSHA256": runtime.nodeSHA256,
        "piVersion": runtime.piVersion.description,
        "piCLIRelativePath": runtime.piCLIRelativePath,
        "piPackageTreeSHA256": packageTreeSHA256,
        "dynamicLibraries": libraries,
        "dynamicLibraryAliases": try privateSnapshotLibraryAliases(runtime: runtime),
      ],
      options: [.sortedKeys]
    )
  }

  private static func privateSnapshotLibraryAliases(
    runtime: PiResolvedRuntime
  ) throws -> [String: String] {
    let canonicalNames = Set(
      runtime.nodeDynamicLibrarySHA256.keys.map {
        URL(fileURLWithPath: $0).lastPathComponent
      }
    )
    var aliases: [String: String] = [:]
    for (loadPath, canonicalPath) in runtime.nodeDynamicLibraryLoadPaths {
      guard runtime.nodeDynamicLibrarySHA256[canonicalPath] != nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let alias = (loadPath as NSString).lastPathComponent
      let target = URL(fileURLWithPath: canonicalPath).lastPathComponent
      guard !alias.isEmpty, !target.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
      if alias == target { continue }
      guard !canonicalNames.contains(alias), aliases[alias] == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      aliases[alias] = target
    }
    return aliases
  }

  private static func copyRuntimePackage(
    from source: URL,
    to destination: URL
  ) throws {
    guard let canonicalSourcePath = canonicalExistingPath(source.path) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let canonicalSource = URL(fileURLWithPath: canonicalSourcePath, isDirectory: true)
    let entries = try collectPackageEntries(canonicalSource)
    try FileManager.default.createDirectory(
      at: destination,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    for entry in entries where entry.kind == .directory {
      let target = destination.appendingPathComponent(entry.relativePath, isDirectory: true)
      try FileManager.default.createDirectory(
        at: target,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: entry.permissions)]
      )
      guard chmod(target.path, mode_t(entry.permissions)) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    for entry in entries where entry.kind != .directory {
      let sourceURL = canonicalSource.appendingPathComponent(entry.relativePath)
      let target = destination.appendingPathComponent(entry.relativePath)
      switch entry.kind {
      case .regularFile:
        try copyRuntimeFile(
          from: sourceURL,
          to: target,
          maximumBytes: 64 * 1_048_576
        )
      case .symbolicLink:
        guard let linkTarget = entry.symbolicLinkTarget,
          !linkTarget.hasPrefix("/")
        else {
          throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createSymbolicLink(
          atPath: target.path,
          withDestinationPath: linkTarget
        )
      case .directory:
        preconditionFailure("directories are copied first")
      }
    }
  }

  private static func copyRuntimeFile(
    from source: URL,
    to destination: URL,
    maximumBytes: Int
  ) throws {
    var value = stat()
    guard let canonicalSource = canonicalExistingPath(source.path),
      lstat(canonicalSource, &value) == 0,
      value.st_mode & S_IFMT == S_IFREG
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let data = try readRegularFile(source, maximumBytes: maximumBytes)
    try writePrivateSnapshotFile(
      data,
      to: destination,
      permissions: Int(value.st_mode & 0o7777)
    )
  }

  private static func writePrivateSnapshotFile(
    _ data: Data,
    to destination: URL,
    permissions: Int
  ) throws {
    let descriptor = Darwin.open(
      destination.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(permissions)
    )
    guard descriptor >= 0, DarwinACLAuthority.hasNoAllowEntries(descriptor) else {
      if descriptor >= 0 { _ = Darwin.close(descriptor) }
      throw CocoaError(.fileWriteNoPermission)
    }
    var succeeded = false
    defer {
      _ = Darwin.close(descriptor)
      if !succeeded {
        _ = unlink(destination.path)
      }
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
    }
    guard fchmod(descriptor, mode_t(permissions)) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    succeeded = true
  }

  private static func verifyPrivateSnapshot(
    at root: URL,
    source: PiResolvedRuntime,
    expectedMarker: Data,
    packageTreeSHA256: String
  ) throws -> PiResolvedRuntime {
    guard safeRuntimeDirectory(root.path, requireSafeAncestors: true),
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        == ["lib", "node", "pi", "snapshot.json"]
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let marker = try readRegularFile(
      root.appendingPathComponent("snapshot.json"),
      maximumBytes: 64 * 1_024,
      requireSafeAncestors: true
    )
    guard marker == expectedMarker else { throw CocoaError(.fileReadCorruptFile) }
    let node = root.appendingPathComponent("node")
    guard
      sha256(
        try readRegularFile(
          node,
          maximumBytes: 512 * 1_048_576,
          requireSafeAncestors: true
        )
      ) == source.nodeSHA256
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let packageRoot = root.appendingPathComponent("pi", isDirectory: true)
    let packageTree = try attestPackageTree(
      packageRoot,
      maximumFileBytes: 64 * 1_048_576,
      requireSafeAncestors: true
    )
    guard packageTree.sha256 == packageTreeSHA256 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let libraryDirectory = root.appendingPathComponent("lib", isDirectory: true)
    guard safeRuntimeDirectory(libraryDirectory.path, requireSafeAncestors: true) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var expectedLibraries: [String: String] = [:]
    for (path, digest) in source.nodeDynamicLibrarySHA256 {
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard !name.isEmpty, expectedLibraries[name] == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      expectedLibraries[name] = digest
    }
    let aliases = try privateSnapshotLibraryAliases(runtime: source)
    guard
      try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path).sorted()
        == (Array(expectedLibraries.keys) + Array(aliases.keys)).sorted()
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    for (alias, target) in aliases {
      let aliasURL = libraryDirectory.appendingPathComponent(alias)
      var status = stat()
      guard lstat(aliasURL.path, &status) == 0,
        status.st_mode & S_IFMT == S_IFLNK,
        status.st_uid == 0 || status.st_uid == geteuid(),
        status.st_nlink == 1,
        try FileManager.default.destinationOfSymbolicLink(atPath: aliasURL.path) == target,
        let resolvedTarget = canonicalExistingPath(aliasURL.path),
        safeRuntimeNode(resolvedTarget, requireSafeAncestors: true)
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
    var snapshotLibraries: [String: String] = [:]
    for (name, digest) in expectedLibraries {
      let library = libraryDirectory.appendingPathComponent(name)
      guard
        sha256(
          try readRegularFile(
            library,
            maximumBytes: 512 * 1_048_576,
            requireSafeAncestors: true
          )
        ) == digest
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      snapshotLibraries[library.path] = digest
    }
    guard source.piCLIRelativePath == "dist/cli.js",
      let cliSHA256 = source.piRuntimeSHA256[source.piCLIRelativePath]
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let cli = packageRoot.appendingPathComponent(source.piCLIRelativePath)
    guard
      sha256(
        try readRegularFile(
          cli,
          maximumBytes: 64 * 1_048_576,
          requireSafeAncestors: true
        )
      ) == cliSHA256
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var snapshotLoadPaths: [String: String] = [:]
    for (loadPath, sourcePath) in source.nodeDynamicLibraryLoadPaths {
      let library = libraryDirectory.appendingPathComponent(
        URL(fileURLWithPath: sourcePath).lastPathComponent
      )
      guard snapshotLibraries[library.path] != nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      snapshotLoadPaths[loadPath] = library.path
    }
    return PiResolvedRuntime(
      nodeURL: node,
      nodeVersion: source.nodeVersion,
      nodeSHA256: source.nodeSHA256,
      nodeDynamicLibrarySHA256: snapshotLibraries,
      nodeDynamicLibraryLoadPaths: snapshotLoadPaths,
      nodeDynamicLibraryDirectoryURL: libraryDirectory,
      piCLIURL: cli,
      piCLIRelativePath: source.piCLIRelativePath,
      piPackageRootURL: packageRoot,
      piVersion: source.piVersion,
      piRuntimeSHA256: source.piRuntimeSHA256,
      compatibility: source.compatibility
    )
  }

  public static func attestPackageTree(
    _ packageRoot: URL,
    maximumFileBytes: Int = 16 * 1_048_576,
    requireSafeAncestors: Bool = false
  ) throws -> PiRuntimeTreeAttestation {
    guard (1...64 * 1_048_576).contains(maximumFileBytes),
      packageRoot.isFileURL,
      packageRoot.path.hasPrefix("/")
    else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    guard let canonicalRootPath = canonicalExistingPath(packageRoot.path) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let standardizedRoot = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
    guard
      safeRuntimeDirectory(
        standardizedRoot.path,
        requireSafeAncestors: requireSafeAncestors
      )
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let entries = try collectPackageEntries(
      standardizedRoot,
      requireSafeAncestors: requireSafeAncestors
    )
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
          throw CocoaError(.fileReadCorruptFile)
        }
        update([
          "symbolicLink", entry.relativePath,
          "target", target,
        ])
      case .regularFile:
        let url = standardizedRoot.appendingPathComponent(entry.relativePath, isDirectory: false)
        let data = try readRegularFile(
          url,
          maximumBytes: maximumFileBytes,
          requireSafeAncestors: requireSafeAncestors
        )
        update([
          "regularFile", entry.relativePath,
          "permissions", String(entry.permissions),
          "size", String(data.count),
          "sha256", sha256(data),
        ])
      }
    }
    guard
      try collectPackageEntries(
        standardizedRoot,
        requireSafeAncestors: requireSafeAncestors
      ) == entries
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return PiRuntimeTreeAttestation(entryCount: entries.count, sha256: digest)
  }

  private static func collectPackageEntries(
    _ root: URL,
    requireSafeAncestors: Bool = false
  ) throws -> [PackageTreeEntry] {
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ],
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw CocoaError(.fileReadUnknown)
    }
    let prefix = root.path + "/"
    var entries: [PackageTreeEntry] = []
    while let url = enumerator.nextObject() as? URL {
      guard entries.count < 100_000 else { throw CocoaError(.fileReadTooLarge) }
      guard url.path.hasPrefix(prefix) else { throw CocoaError(.fileReadCorruptFile) }
      let relativePath = String(url.path.dropFirst(prefix.count))
      guard !relativePath.isEmpty,
        !relativePath.contains("\u{0}"),
        !relativePath.split(separator: "/", omittingEmptySubsequences: false)
          .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      var status = stat()
      guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadCorruptFile) }
      let permissions = Int(status.st_mode & 0o7777)
      switch status.st_mode & S_IFMT {
      case S_IFLNK:
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let targetURL =
          target.hasPrefix("/")
          ? URL(fileURLWithPath: target)
          : url.deletingLastPathComponent().appendingPathComponent(target)
        guard let canonicalTarget = canonicalExistingPath(targetURL.path),
          canonicalTarget == root.path || canonicalTarget.hasPrefix(prefix),
          status.st_uid == 0 || status.st_uid == geteuid(),
          status.st_nlink == 1,
          safeRuntimeDirectory(
            url.deletingLastPathComponent().path,
            requireSafeAncestors: requireSafeAncestors
          ),
          safeRuntimeNode(
            canonicalTarget,
            requireSafeAncestors: requireSafeAncestors
          ),
          try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target
        else {
          throw CocoaError(.fileReadCorruptFile)
        }
        entries.append(
          PackageTreeEntry(
            relativePath: relativePath,
            kind: .symbolicLink,
            permissions: 0,
            symbolicLinkTarget: target
          ))
      case S_IFDIR:
        guard
          safeRuntimeDirectory(
            url.path,
            requireSafeAncestors: requireSafeAncestors
          )
        else { throw CocoaError(.fileReadCorruptFile) }
        entries.append(
          PackageTreeEntry(
            relativePath: relativePath,
            kind: .directory,
            permissions: permissions,
            symbolicLinkTarget: nil
          ))
      case S_IFREG:
        guard
          safeRuntimeNode(
            url.path,
            requireSafeAncestors: requireSafeAncestors
          )
        else { throw CocoaError(.fileReadCorruptFile) }
        entries.append(
          PackageTreeEntry(
            relativePath: relativePath,
            kind: .regularFile,
            permissions: permissions,
            symbolicLinkTarget: nil
          ))
      default:
        throw CocoaError(.fileReadCorruptFile)
      }
    }
    if let enumerationError { throw enumerationError }
    return entries.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
  }

  private static func canonicalExistingPath(_ path: String) -> String? {
    guard let pointer = Darwin.realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  private static func parsePiPolicy(_ data: Data) throws -> PiPolicy {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys)
        == Set(["builds", "maximumVersionExclusive", "minimumVersion", "package", "schemaVersion"]),
      object["schemaVersion"] as? Int == 2,
      object["package"] as? String == expectedPackageName,
      let minimumString = object["minimumVersion"] as? String,
      let maximumString = object["maximumVersionExclusive"] as? String,
      let rawBuilds = object["builds"] as? [String: Any],
      !rawBuilds.isEmpty
    else {
      throw PiRuntimeResolutionError(
        code: .malformedCompatibilityPolicy,
        detail: "Pi compatibility policy shape is invalid"
      )
    }
    let minimum = try PiSemanticVersion(minimumString)
    let maximum = try PiSemanticVersion(maximumString)
    guard minimum < maximum else {
      throw PiRuntimeResolutionError(
        code: .malformedCompatibilityPolicy,
        detail: "Pi compatibility range is empty"
      )
    }
    var builds: [String: PiBuild] = [:]
    for (versionString, rawBuild) in rawBuilds {
      let version = try PiSemanticVersion(versionString)
      guard version >= minimum, version < maximum,
        let buildObject = rawBuild as? [String: Any],
        Set(buildObject.keys) == Set(["criticalFiles", "packageTree"]),
        let criticalFiles = buildObject["criticalFiles"] as? [String: String],
        Set(criticalFiles.keys) == expectedPiRuntimePaths,
        criticalFiles.values.allSatisfy(GitHubInputValidation.validSHA256),
        let treeObject = buildObject["packageTree"] as? [String: Any],
        Set(treeObject.keys) == Set(["entryCount", "sha256"]),
        let entryCount = treeObject["entryCount"] as? Int,
        (1...100_000).contains(entryCount),
        let treeDigest = treeObject["sha256"] as? String,
        GitHubInputValidation.validSHA256(treeDigest)
      else {
        throw PiRuntimeResolutionError(
          code: .malformedCompatibilityPolicy,
          detail: "Pi build policy is invalid"
        )
      }
      builds[versionString] = PiBuild(
        criticalFiles: criticalFiles,
        packageTree: PiRuntimeTreeAttestation(entryCount: entryCount, sha256: treeDigest)
      )
    }
    return PiPolicy(minimum: minimum, maximum: maximum, builds: builds)
  }

  private static func parseNodePolicy(_ data: Data) throws -> NodePolicy {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["builds", "runtime", "schemaVersion"]),
      object["schemaVersion"] as? Int == 2,
      object["runtime"] as? String == "node",
      let rawBuilds = object["builds"] as? [String: Any],
      !rawBuilds.isEmpty
    else {
      throw PiRuntimeResolutionError(
        code: .malformedCompatibilityPolicy,
        detail: "Node compatibility policy shape is invalid"
      )
    }
    var builds: [String: NodeBuild] = [:]
    var executableDigests: Set<String> = []
    for (versionString, rawBuild) in rawBuilds {
      guard (try? PiSemanticVersion(versionString)) != nil,
        let buildObject = rawBuild as? [String: Any],
        Set(buildObject.keys) == Set(["dynamicLibraries", "executable"]),
        let executableObject = buildObject["executable"] as? [String: Any],
        Set(executableObject.keys) == Set(["canonicalPath", "sha256"]),
        let executablePath = executableObject["canonicalPath"] as? String,
        validAbsolutePolicyPath(executablePath),
        let executableDigest = executableObject["sha256"] as? String,
        GitHubInputValidation.validSHA256(executableDigest),
        executableDigests.insert(executableDigest).inserted,
        let rawLibraries = buildObject["dynamicLibraries"] as? [[String: Any]],
        rawLibraries.count <= 128
      else {
        throw PiRuntimeResolutionError(
          code: .malformedCompatibilityPolicy,
          detail: "Node build policy is invalid"
        )
      }
      var libraries: [NodeDynamicLibrary] = []
      for rawLibrary in rawLibraries {
        guard Set(rawLibrary.keys) == Set(["canonicalPath", "loadPath", "sha256"]),
          let loadPath = rawLibrary["loadPath"] as? String,
          validNodeLoadPath(loadPath),
          let canonicalPath = rawLibrary["canonicalPath"] as? String,
          validAbsolutePolicyPath(canonicalPath),
          let digest = rawLibrary["sha256"] as? String,
          GitHubInputValidation.validSHA256(digest)
        else {
          throw PiRuntimeResolutionError(
            code: .malformedCompatibilityPolicy,
            detail: "Node dynamic-library policy is invalid"
          )
        }
        libraries.append(
          NodeDynamicLibrary(
            loadPath: loadPath,
            canonicalPath: canonicalPath,
            sha256: digest
          ))
      }
      guard libraries.map(\.loadPath) == libraries.map(\.loadPath).sorted(),
        Set(libraries.map(\.loadPath)).count == libraries.count,
        Set(libraries.map(\.canonicalPath)).count == libraries.count
      else {
        throw PiRuntimeResolutionError(
          code: .malformedCompatibilityPolicy,
          detail: "Node dynamic-library inventory is ambiguous"
        )
      }
      builds[versionString] = NodeBuild(
        executable: NodeExecutable(canonicalPath: executablePath, sha256: executableDigest),
        dynamicLibraries: libraries
      )
    }
    return NodePolicy(builds: builds)
  }

  private static func validAbsolutePolicyPath(_ value: String) -> Bool {
    guard value.hasPrefix("/"), !value.contains("\u{0}") else { return false }
    return URL(fileURLWithPath: value).standardizedFileURL.path == value
  }

  private static func validNodeLoadPath(_ value: String) -> Bool {
    for prefix in ["@rpath/", "@loader_path/"] where value.hasPrefix(prefix) {
      let name = value.dropFirst(prefix.count)
      return !name.isEmpty && !name.contains("/") && !name.contains("\u{0}")
    }
    return validAbsolutePolicyPath(value)
  }

  private static func parseShebang(_ data: Data) throws -> PiShebang {
    guard let newline = data.firstIndex(of: 0x0A), newline <= 255,
      let firstLine = String(data: data[..<newline], encoding: .utf8)
    else {
      throw PiRuntimeResolutionError(
        code: .invalidPiShebang,
        detail: "Pi CLI shebang is absent"
      )
    }
    if firstLine == "#!/usr/bin/env node" { return .environmentNode }
    if firstLine.hasPrefix("#!/"), !firstLine.contains(" "), !firstLine.contains("\t") {
      return .absolute(String(firstLine.dropFirst(2)))
    }
    throw PiRuntimeResolutionError(
      code: .invalidPiShebang,
      detail: "Pi CLI shebang is unsupported"
    )
  }

  private static func preferredFailure(
    _ failures: [PiRuntimeResolutionError]
  ) -> PiRuntimeResolutionError? {
    let priority: [PiRuntimeIssueCode] = [
      .unattestedPiBuild,
      .unsupportedPiVersion,
      .invalidPiShebang,
      .invalidPiPackage,
    ]
    for code in priority {
      if let failure = failures.first(where: { $0.code == code }) { return failure }
    }
    return failures.first
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func actionableIssue(
    for error: PiRuntimeResolutionError
  ) -> PiRuntimePreflightIssue {
    switch error.code {
    case .piRuntimeNotFound:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "Pi was not found in a supported system location.",
        recovery: "Install the supported Pi package system-wide, then run preflight again."
      )
    case .unsupportedPiVersion:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "The installed Pi version is outside Jidoka Code's compatibility range.",
        recovery: "Install a Pi version in the packaged range with an attested build digest."
      )
    case .unattestedPiBuild:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "The installed Pi build is not attested by this Jidoka Code release.",
        recovery: "Install the exact supported Pi build or update Jidoka Code."
      )
    case .nodeRuntimeNotFound:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "Node was not found in a supported system location.",
        recovery: "Install the Node build required by this Jidoka Code release."
      )
    case .unattestedNodeBuild:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "The installed Node build does not match the packaged digest policy.",
        recovery: "Install the exact supported Node build, then run preflight again."
      )
    case .invalidPiShebang, .invalidPiPackage:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "The installed Pi package layout is invalid or unsupported.",
        recovery: "Reinstall the supported Pi package without modifying its runtime files."
      )
    case .malformedCompatibilityPolicy, .unsafeCompatibilityPolicy:
      return PiRuntimePreflightIssue(
        code: error.code,
        summary: "Jidoka Code's packaged runtime policy is invalid.",
        recovery: "Reinstall or update Jidoka Code before enabling Pi jobs."
      )
    }
  }

  private struct PiPolicy {
    let minimum: PiSemanticVersion
    let maximum: PiSemanticVersion
    let builds: [String: PiBuild]
  }

  private struct PiBuild {
    let criticalFiles: [String: String]
    let packageTree: PiRuntimeTreeAttestation
  }

  private struct NodePolicy {
    let builds: [String: NodeBuild]
  }

  private struct NodeBuild {
    let executable: NodeExecutable
    let dynamicLibraries: [NodeDynamicLibrary]
  }

  private struct NodeExecutable {
    let canonicalPath: String
    let sha256: String
  }

  private struct NodeDynamicLibrary {
    let loadPath: String
    let canonicalPath: String
    let sha256: String
  }

  private struct MachOMetadata {
    let dependencies: [String]
    let rpaths: [String]
  }

  private struct PiResolution {
    let cliURL: URL
    let packageRoot: URL
    let version: PiSemanticVersion
    let digests: [String: String]
    let shebang: PiShebang
  }

  private struct NodeResolution {
    let url: URL
    let version: PiSemanticVersion
    let digest: String
    let dynamicLibraryDigests: [String: String]
    let dynamicLibraryLoadPaths: [String: String]
  }

  private enum PackageTreeEntryKind: Equatable {
    case directory
    case regularFile
    case symbolicLink
  }

  private struct PackageTreeEntry: Equatable {
    let relativePath: String
    let kind: PackageTreeEntryKind
    let permissions: Int
    let symbolicLinkTarget: String?
  }

  private enum PiShebang {
    case environmentNode
    case absolute(String)
  }
}
