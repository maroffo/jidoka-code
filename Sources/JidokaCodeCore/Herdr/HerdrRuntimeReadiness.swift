import CryptoKit
import Darwin
import Foundation

public struct HerdrRuntimeAttestation: Equatable, Sendable {
  public let version: String
  public let protocolVersion: Int
  public let architecture: String
  public let executable: URL
  public let executableSHA256: String
  public let apiSchemaSHA256: String
  public let policySHA256: String

  public init(
    version: String,
    protocolVersion: Int,
    architecture: String,
    executable: URL,
    executableSHA256: String,
    apiSchemaSHA256: String,
    policySHA256: String
  ) {
    self.version = version
    self.protocolVersion = protocolVersion
    self.architecture = architecture
    self.executable = executable
    self.executableSHA256 = executableSHA256
    self.apiSchemaSHA256 = apiSchemaSHA256
    self.policySHA256 = policySHA256
  }
}

public enum HerdrRuntimeResolutionError: Error, Equatable, Sendable {
  case invalidConfiguration
  case policyMissing
  case policyInvalid
  case unsupportedPolicySchema
  case unsupportedBuild
  case schemaMissing
  case schemaInvalid
  case schemaDigestMismatch
  case executableUnavailable
  case executableUnsafe
  case executableDigestMismatch
  case versionOutputMismatch
  case schemaOutputMismatch
  case runtimeCommandFailed
}

public struct HerdrRuntimeResolverConfiguration: Equatable, Sendable {
  public let resourceRoot: URL
  public let executableLink: URL

  init(resourceRoot: URL, executableLink: URL) throws {
    guard resourceRoot.isFileURL, resourceRoot.path.hasPrefix("/"),
      executableLink.isFileURL, executableLink.path.hasPrefix("/"),
      resourceRoot.standardizedFileURL.path == resourceRoot.path,
      executableLink.standardizedFileURL.path == executableLink.path
    else {
      throw HerdrRuntimeResolutionError.invalidConfiguration
    }
    self.resourceRoot = resourceRoot
    self.executableLink = executableLink
  }

  public static func standard(resourceRoot: URL) throws -> Self {
    try Self(
      resourceRoot: resourceRoot.standardizedFileURL,
      executableLink: URL(fileURLWithPath: "/opt/homebrew/bin/herdr", isDirectory: false)
    )
  }
}

public protocol HerdrRuntimeResolving: Sendable {
  func resolve() async throws -> HerdrRuntimeAttestation
}

public struct HerdrRuntimeResolver: HerdrRuntimeResolving, Sendable {
  private static let policyName = "runtime-builds.json"
  private static let maximumPolicyBytes = 64 * 1_024
  private static let maximumSchemaBytes = 1 * 1_024 * 1_024
  private static let maximumExecutableBytes = 64 * 1_024 * 1_024

  private let configuration: HerdrRuntimeResolverConfiguration
  private let process: any GitProcessExecuting

  public init(configuration: HerdrRuntimeResolverConfiguration) {
    self.configuration = configuration
    process = BoundedProcessRunner()
  }

  init(
    configuration: HerdrRuntimeResolverConfiguration,
    process: any GitProcessExecuting
  ) {
    self.configuration = configuration
    self.process = process
  }

  public func resolve() async throws -> HerdrRuntimeAttestation {
    let root = try Self.canonicalResourceRoot(configuration.resourceRoot)
    let policyURL = root.appendingPathComponent(Self.policyName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: policyURL.path) else {
      throw HerdrRuntimeResolutionError.policyMissing
    }
    let policyData = try Self.readRegularFile(
      policyURL,
      maximumBytes: Self.maximumPolicyBytes,
      missing: .policyMissing,
      unsafe: .policyInvalid
    )
    let policy = try Self.decodePolicy(policyData)
    guard policy.architecture == Self.currentArchitecture else {
      throw HerdrRuntimeResolutionError.unsupportedBuild
    }

    let schemaURL = root.appendingPathComponent(policy.apiSchemaResource, isDirectory: false)
    guard schemaURL.deletingLastPathComponent().standardizedFileURL == root else {
      throw HerdrRuntimeResolutionError.policyInvalid
    }
    let schemaData = try Self.readRegularFile(
      schemaURL,
      maximumBytes: Self.maximumSchemaBytes,
      missing: .schemaMissing,
      unsafe: .schemaInvalid
    )
    try Self.validateSchema(schemaData, policy: policy)

    let executable = try Self.resolveExecutable(configuration.executableLink)
    let executableData = try Self.readRegularFile(
      executable,
      maximumBytes: Self.maximumExecutableBytes,
      missing: .executableUnavailable,
      unsafe: .executableUnsafe,
      requireExecutable: true
    )
    guard Self.sha256(executableData) == policy.executableSHA256 else {
      throw HerdrRuntimeResolutionError.executableDigestMismatch
    }

    let environment = try CredentiallessEnvironment.make(
      homeDirectory: "/var/empty",
      temporaryDirectory: "/tmp"
    )
    let version = try await process.run(
      GitProcessRequest(
        executable: executable,
        arguments: ["--version"],
        workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
        environment: environment,
        timeoutSeconds: 5,
        maximumOutputBytes: 4_096
      )
    )
    guard version.succeeded, version.stderr.isEmpty,
      version.stdout == Data("herdr \(policy.version)\n".utf8)
    else {
      throw HerdrRuntimeResolutionError.versionOutputMismatch
    }

    let generatedSchema = try await process.run(
      GitProcessRequest(
        executable: executable,
        arguments: ["api", "schema", "--json"],
        workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
        environment: environment,
        timeoutSeconds: 5,
        maximumOutputBytes: Self.maximumSchemaBytes
      )
    )
    guard generatedSchema.succeeded, generatedSchema.stderr.isEmpty,
      generatedSchema.stdout == schemaData,
      Self.sha256(generatedSchema.stdout) == policy.apiSchemaSHA256
    else {
      throw HerdrRuntimeResolutionError.schemaOutputMismatch
    }

    let finalExecutableData = try Self.readRegularFile(
      executable,
      maximumBytes: Self.maximumExecutableBytes,
      missing: .executableUnavailable,
      unsafe: .executableUnsafe,
      requireExecutable: true
    )
    guard Self.sha256(finalExecutableData) == policy.executableSHA256 else {
      throw HerdrRuntimeResolutionError.executableDigestMismatch
    }

    return HerdrRuntimeAttestation(
      version: policy.version,
      protocolVersion: policy.protocolVersion,
      architecture: policy.architecture,
      executable: executable,
      executableSHA256: policy.executableSHA256,
      apiSchemaSHA256: policy.apiSchemaSHA256,
      policySHA256: Self.sha256(policyData)
    )
  }

  private static func canonicalResourceRoot(_ root: URL) throws -> URL {
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL
    else {
      throw HerdrRuntimeResolutionError.invalidConfiguration
    }
    return root.standardizedFileURL
  }

  private static func resolveExecutable(_ link: URL) throws -> URL {
    var linkMetadata = stat()
    guard lstat(link.path, &linkMetadata) == 0,
      linkMetadata.st_uid == 0 || linkMetadata.st_uid == geteuid(),
      linkMetadata.st_mode & S_IFMT == S_IFLNK || linkMetadata.st_mode & S_IFMT == S_IFREG
    else {
      throw HerdrRuntimeResolutionError.executableUnavailable
    }
    let executable = link.resolvingSymlinksInPath().standardizedFileURL
    guard executable.path.hasPrefix("/"),
      executable.path != link.path || linkMetadata.st_mode & S_IFMT == S_IFREG
    else {
      throw HerdrRuntimeResolutionError.executableUnsafe
    }
    return executable
  }

  private static func readRegularFile(
    _ url: URL,
    maximumBytes: Int,
    missing: HerdrRuntimeResolutionError,
    unsafe: HerdrRuntimeResolutionError,
    requireExecutable: Bool = false
  ) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw missing }
      throw unsafe
    }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == 0 || before.st_uid == geteuid(),
      before.st_mode & 0o022 == 0,
      !requireExecutable || before.st_mode & 0o111 != 0,
      before.st_nlink == 1,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw unsafe
    }
    let expectedCount = Int(before.st_size)
    var data = Data(count: expectedCount)
    var offset = 0
    while offset < expectedCount {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress?.advanced(by: offset), expectedCount - offset)
      }
      if count > 0 {
        offset += count
      } else if count == -1, errno == EINTR {
        continue
      } else {
        throw unsafe
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_mode == after.st_mode,
      before.st_uid == after.st_uid,
      before.st_size == after.st_size,
      before.st_nlink == after.st_nlink
    else {
      throw unsafe
    }
    return data
  }

  private static func decodePolicy(_ data: Data) throws -> RuntimeBuildPolicy {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["builds", "schemaVersion"]),
      object["schemaVersion"] as? Int == 1,
      let builds = object["builds"] as? [[String: Any]],
      builds.count == 1,
      let build = builds.first,
      Set(build.keys)
        == Set([
          "apiSchemaResource", "apiSchemaSHA256", "architecture", "executableSHA256",
          "protocolVersion", "version",
        ]),
      let apiSchemaResource = build["apiSchemaResource"] as? String,
      apiSchemaResource.wholeMatch(of: /^api-schema-[0-9]+\.[0-9]+\.[0-9]+\.json$/) != nil,
      let apiSchemaSHA256 = build["apiSchemaSHA256"] as? String,
      apiSchemaSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      let architecture = build["architecture"] as? String,
      ["arm64", "x86_64"].contains(architecture),
      let executableSHA256 = build["executableSHA256"] as? String,
      executableSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
      let protocolVersion = build["protocolVersion"] as? Int,
      protocolVersion == HerdrCompatibilityManifest.herdr080.protocolVersion,
      let version = build["version"] as? String,
      version == HerdrCompatibilityManifest.herdr080.version
    else {
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let schema = object["schemaVersion"] as? Int,
        schema != 1
      {
        throw HerdrRuntimeResolutionError.unsupportedPolicySchema
      }
      throw HerdrRuntimeResolutionError.policyInvalid
    }
    return RuntimeBuildPolicy(
      apiSchemaResource: apiSchemaResource,
      apiSchemaSHA256: apiSchemaSHA256,
      architecture: architecture,
      executableSHA256: executableSHA256,
      protocolVersion: protocolVersion,
      version: version
    )
  }

  private static func validateSchema(
    _ data: Data,
    policy: RuntimeBuildPolicy
  ) throws {
    guard sha256(data) == policy.apiSchemaSHA256 else {
      throw HerdrRuntimeResolutionError.schemaDigestMismatch
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["$schema", "protocol", "schema_version", "schemas", "title"]),
      object["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema",
      object["title"] as? String == "Herdr API",
      object["protocol"] as? Int == policy.protocolVersion,
      object["schema_version"] as? Int == 1,
      let schemas = object["schemas"] as? [String: Any],
      Set(schemas.keys)
        == Set(["error_response", "event", "request", "subscription_event", "success_response"])
    else {
      throw HerdrRuntimeResolutionError.schemaInvalid
    }
  }

  private static var currentArchitecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unsupported"
    #endif
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct RuntimeBuildPolicy: Sendable {
  let apiSchemaResource: String
  let apiSchemaSHA256: String
  let architecture: String
  let executableSHA256: String
  let protocolVersion: Int
  let version: String
}

public protocol HerdrRuntimeHandshaking: Sendable {
  func handshake() async throws -> HerdrHandshake
}

extension HerdrSocketClient: HerdrRuntimeHandshaking {}

public protocol HerdrRuntimeReadinessChecking: Sendable {
  func preflight() async -> EngineHerdrStatus
}

public actor HerdrRuntimeReadinessChecker: HerdrRuntimeReadinessChecking {
  private let resolver: any HerdrRuntimeResolving
  private let handshaker: any HerdrRuntimeHandshaking

  public init(resourceRoot: URL, socketURL: URL) throws {
    resolver = HerdrRuntimeResolver(
      configuration: try .standard(resourceRoot: resourceRoot)
    )
    handshaker = HerdrSocketClient(
      configuration: try HerdrSocketClientConfiguration(endpoint: socketURL)
    )
  }

  init(
    resolver: any HerdrRuntimeResolving,
    handshaker: any HerdrRuntimeHandshaking
  ) {
    self.resolver = resolver
    self.handshaker = handshaker
  }

  public func preflight() async -> EngineHerdrStatus {
    let attestation: HerdrRuntimeAttestation
    do {
      attestation = try await resolver.resolve()
    } catch {
      return Self.blocked(for: error)
    }

    do {
      let handshake = try await handshaker.handshake()
      guard let peerExecutable = handshake.socketIdentity.peerEvidence?.executable,
        peerExecutable.path == attestation.executable.path,
        peerExecutable.contentSHA256 == attestation.executableSHA256
      else {
        throw HerdrSocketClientError.unsafePeer
      }
      guard handshake.pong.version == attestation.version else {
        return Self.blocked(for: HerdrCompatibilityError.versionMismatch)
      }
      guard handshake.pong.protocolVersion == attestation.protocolVersion else {
        return Self.blocked(for: HerdrCompatibilityError.protocolMismatch)
      }
      return EngineHerdrStatus(
        state: .ready,
        version: attestation.version,
        protocolVersion: attestation.protocolVersion,
        executableSHA256: attestation.executableSHA256,
        schemaSHA256: attestation.apiSchemaSHA256,
        policySHA256: attestation.policySHA256
      )
    } catch {
      return Self.blocked(for: error)
    }
  }

  private static func blocked(for error: Error) -> EngineHerdrStatus {
    let issue: EngineHerdrIssueCode
    let summary: String
    let recovery: String
    switch error {
    case HerdrRuntimeResolutionError.executableUnavailable:
      issue = .executableUnavailable
      summary = "The required Herdr executable is unavailable."
      recovery = "Install Herdr 0.8.0 with Homebrew, then run the Herdr preflight again."
    case HerdrRuntimeResolutionError.executableUnsafe,
      HerdrRuntimeResolutionError.executableDigestMismatch,
      HerdrRuntimeResolutionError.versionOutputMismatch:
      issue = .executableMismatch
      summary = "The installed Herdr executable is not an attested build."
      recovery = "Restore the approved Herdr 0.8.0 build, then run the Herdr preflight again."
    case HerdrRuntimeResolutionError.policyMissing,
      HerdrRuntimeResolutionError.policyInvalid,
      HerdrRuntimeResolutionError.unsupportedPolicySchema,
      HerdrRuntimeResolutionError.unsupportedBuild,
      HerdrRuntimeResolutionError.invalidConfiguration:
      issue = .policyInvalid
      summary = "The packaged Herdr compatibility policy is invalid."
      recovery = "Reinstall this Jidoka Code build before enabling automation."
    case HerdrRuntimeResolutionError.schemaMissing,
      HerdrRuntimeResolutionError.schemaInvalid,
      HerdrRuntimeResolutionError.schemaDigestMismatch,
      HerdrRuntimeResolutionError.schemaOutputMismatch:
      issue = .schemaMismatch
      summary = "The Herdr API schema does not match the approved protocol."
      recovery = "Restore Herdr 0.8.0 and reinstall Jidoka Code, then rerun preflight."
    case HerdrCompatibilityError.versionMismatch:
      issue = .versionMismatch
      summary = "The running Herdr version is incompatible."
      recovery = "Run the approved Herdr 0.8.0 server, then rerun preflight."
    case HerdrCompatibilityError.protocolMismatch, HerdrCompatibilityError.snapshotMismatch,
      HerdrCompatibilityError.invalidPong:
      issue = .protocolMismatch
      summary = "The running Herdr protocol is incompatible."
      recovery = "Run Herdr protocol 19, then rerun preflight."
    case HerdrCompatibilityError.missingLiveHandoff,
      HerdrCompatibilityError.missingDetachedServerDaemon:
      issue = .capabilityMismatch
      summary = "The running Herdr server lacks a required capability."
      recovery = "Start the approved persistent Herdr server, then rerun preflight."
    case HerdrSocketClientError.unsafeSocket, HerdrSocketClientError.unsafePeer:
      issue = .unsafeSocket
      summary = "The Herdr socket ownership boundary is unsafe."
      recovery = "Restore the current-user Herdr socket with mode 0600, then rerun preflight."
    case HerdrSocketClientError.socketFailure, HerdrSocketClientError.timedOut,
      HerdrSocketClientError.connectionClosed:
      issue = .socketUnavailable
      summary = "The global Herdr session is unavailable."
      recovery = "Start Herdr normally, then rerun preflight. Jidoka Code will not start it."
    default:
      issue = .runtimeUnavailable
      summary = "Herdr readiness could not be established."
      recovery = "Review redacted diagnostics and rerun the Herdr preflight."
    }
    return EngineHerdrStatus(
      state: .blocked,
      issueCode: issue,
      summary: summary,
      recovery: recovery
    )
  }
}
