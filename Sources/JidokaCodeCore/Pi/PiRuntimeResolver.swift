import CryptoKit
import Darwin
import Foundation

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
  public let piCLIURL: URL
  public let piPackageRootURL: URL
  public let piVersion: PiSemanticVersion
  public let piRuntimeSHA256: [String: String]
  public let compatibility: PiRuntimeCompatibility

  public init(
    nodeURL: URL,
    nodeVersion: PiSemanticVersion,
    nodeSHA256: String,
    nodeDynamicLibrarySHA256: [String: String] = [:],
    piCLIURL: URL,
    piPackageRootURL: URL,
    piVersion: PiSemanticVersion,
    piRuntimeSHA256: [String: String],
    compatibility: PiRuntimeCompatibility
  ) {
    self.nodeURL = nodeURL
    self.nodeVersion = nodeVersion
    self.nodeSHA256 = nodeSHA256
    self.nodeDynamicLibrarySHA256 = nodeDynamicLibrarySHA256
    self.piCLIURL = piCLIURL
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
          dynamicLibraryDigests: dynamicLibraryDigests
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
    maximumBytes: Int
  ) throws -> Data {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
    let sourceValues = try url.standardizedFileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard sourceValues.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let values = try resolved.resourceValues(forKeys: [
      .fileSizeKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      (0...maximumBytes).contains(size)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return try Data(contentsOf: resolved, options: [.mappedIfSafe])
  }

  public static func attestPackageTree(
    _ packageRoot: URL,
    maximumFileBytes: Int = 16 * 1_048_576
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
    let rootValues = try standardizedRoot.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard rootValues.isDirectory == true,
      rootValues.isSymbolicLink != true,
      canonicalExistingPath(standardizedRoot.path) == standardizedRoot.path
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let entries = try collectPackageEntries(standardizedRoot)
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
        let data = try readRegularFile(url, maximumBytes: maximumFileBytes)
        update([
          "regularFile", entry.relativePath,
          "permissions", String(entry.permissions),
          "size", String(data.count),
          "sha256", sha256(data),
        ])
      }
    }
    guard try collectPackageEntries(standardizedRoot) == entries else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return PiRuntimeTreeAttestation(entryCount: entries.count, sha256: digest)
  }

  private static func collectPackageEntries(_ root: URL) throws -> [PackageTreeEntry] {
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
      guard entries.count < 100_000,
        url.path.hasPrefix(prefix)
      else {
        throw CocoaError(.fileReadTooLarge)
      }
      let relativePath = String(url.path.dropFirst(prefix.count))
      guard !relativePath.isEmpty,
        !relativePath.contains("\u{0}"),
        !relativePath.split(separator: "/", omittingEmptySubsequences: false)
          .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
      if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let targetURL =
          target.hasPrefix("/")
          ? URL(fileURLWithPath: target)
          : url.deletingLastPathComponent().appendingPathComponent(target)
        let canonicalTarget = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalTarget == root.path || canonicalTarget.hasPrefix(prefix),
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
      } else if values.isDirectory == true {
        entries.append(
          PackageTreeEntry(
            relativePath: relativePath,
            kind: .directory,
            permissions: permissions,
            symbolicLinkTarget: nil
          ))
      } else if values.isRegularFile == true {
        entries.append(
          PackageTreeEntry(
            relativePath: relativePath,
            kind: .regularFile,
            permissions: permissions,
            symbolicLinkTarget: nil
          ))
      } else {
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
