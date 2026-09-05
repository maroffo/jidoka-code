import CryptoKit
import Darwin
import Foundation

protocol RolloutReleaseIdentityRevalidating: Sendable {
  func requireCurrent(_ expected: RolloutReleaseIdentity) async throws
}

struct RolloutPackagedReleaseIdentity: Codable, Equatable, Sendable {
  let manifestSchemaVersion: Int
  let sourceCommit: String
  let sourceTree: String
  let bundleVersion: String
  let bundleBuild: Int
  let helperSHA256: String
  let askPassSHA256: String
  let pushGuardSHA256: String
  let herdrHostSHA256: String
  let databaseSchemaVersion: Int
  let engineProtocolVersion: Int
  let runtimeManifestSHA256: String
  let runtimeTreeSHA256: String
  let workflowResourcesSHA256: String

  func matches(
    _ expected: RolloutReleaseIdentity,
    applicationSHA256: String
  ) -> Bool {
    manifestSchemaVersion == 2
      && sourceCommit == expected.sourceCommit
      && sourceTree == expected.sourceTree
      && bundleVersion == expected.bundleVersion
      && bundleBuild == expected.bundleBuild
      && applicationSHA256 == expected.applicationSHA256
      && helperSHA256 == expected.helperSHA256
      && askPassSHA256 == expected.askPassSHA256
      && pushGuardSHA256 == expected.pushGuardSHA256
      && herdrHostSHA256 == expected.herdrHostSHA256
      && databaseSchemaVersion == expected.schemaVersion
      && engineProtocolVersion == expected.engineProtocolVersion
      && runtimeManifestSHA256 == expected.runtimeManifestSHA256
      && runtimeTreeSHA256 == expected.runtimeTreeSHA256
      && workflowResourcesSHA256 == expected.workflowResourcesSHA256
  }
}

struct RolloutObservedReleaseIdentity: Equatable, Sendable {
  let packaged: RolloutPackagedReleaseIdentity
  let applicationSHA256: String

  func matches(_ expected: RolloutReleaseIdentity) -> Bool {
    packaged.matches(expected, applicationSHA256: applicationSHA256)
  }
}

struct ProductionRolloutReleaseIdentityRevalidator: RolloutReleaseIdentityRevalidating {
  static let relativeManifestPath = "Contents/Resources/progressive-production-release.json"

  private let inspect: @Sendable () throws -> RolloutObservedReleaseIdentity

  init(runtimeConfiguration: ProductionEngineRuntimeConfiguration) {
    inspect = {
      try Self.inspect(runtimeConfiguration: runtimeConfiguration)
    }
  }

  #if DEBUG
    init(inspect: @escaping @Sendable () throws -> RolloutObservedReleaseIdentity) {
      self.inspect = inspect
    }
  #endif

  func requireCurrent(_ expected: RolloutReleaseIdentity) async throws {
    do {
      let observed = try inspect()
      guard observed.matches(expected) else {
        throw RolloutAuthorityError.previewDrift
      }
    } catch let error as RolloutAuthorityError {
      throw error
    } catch {
      throw RolloutAuthorityError.previewDrift
    }
  }

  private static func inspect(
    runtimeConfiguration: ProductionEngineRuntimeConfiguration
  ) throws -> RolloutObservedReleaseIdentity {
    let application = runtimeConfiguration.containingApplicationURL.standardizedFileURL
    let manifestURL = application.appendingPathComponent(relativeManifestPath)
    let manifestData = try readRegularFile(
      manifestURL,
      containedIn: application,
      maximumBytes: 64 * 1_024
    )
    let declared = try RolloutCanonicalJSON.decodeCanonical(
      RolloutPackagedReleaseIdentity.self,
      from: manifestData
    )
    let declaredDigests = [
      declared.helperSHA256,
      declared.askPassSHA256,
      declared.pushGuardSHA256,
      declared.herdrHostSHA256,
      declared.runtimeManifestSHA256,
      declared.runtimeTreeSHA256,
      declared.workflowResourcesSHA256,
    ]
    guard declared.manifestSchemaVersion == 2,
      GitHubInputValidation.validGitSHA(declared.sourceCommit),
      GitHubInputValidation.validGitSHA(declared.sourceTree),
      declared.bundleVersion == "0.2.0",
      declared.bundleBuild == 3,
      declared.databaseSchemaVersion == 10,
      declared.engineProtocolVersion == EngineProtocolVersion.current,
      declaredDigests.allSatisfy(GitHubInputValidation.validSHA256)
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }

    let infoURL = application.appendingPathComponent("Contents/Info.plist")
    let infoData = try readRegularFile(
      infoURL,
      containedIn: application,
      maximumBytes: 1_048_576
    )
    guard
      let info = try PropertyListSerialization.propertyList(
        from: infoData,
        options: [],
        format: nil
      ) as? [String: Any],
      let executableName = info["CFBundleExecutable"] as? String,
      executableName == "Jidoka Code",
      let bundleVersion = info["CFBundleShortVersionString"] as? String,
      let buildText = info["CFBundleVersion"] as? String,
      let bundleBuild = Int(buildText),
      bundleVersion == declared.bundleVersion,
      bundleBuild == declared.bundleBuild
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }

    let applicationExecutable = application.appendingPathComponent(
      "Contents/MacOS/\(executableName)"
    )
    let helperExecutable = application.appendingPathComponent(
      "Contents/Helpers/JidokaCodeEngineProbe"
    )
    let applicationSHA256 = sha256(
      try readRegularFile(
        applicationExecutable,
        containedIn: application,
        maximumBytes: 128 * 1_048_576
      )
    )
    let helperSHA256 = sha256(
      try readRegularFile(
        helperExecutable,
        containedIn: application,
        maximumBytes: 128 * 1_048_576
      )
    )
    let askPassSHA256 = sha256(
      try readRegularFile(
        runtimeConfiguration.askPassExecutable,
        containedIn: application,
        maximumBytes: 128 * 1_048_576
      )
    )
    let pushGuardSHA256 = sha256(
      try readRegularFile(
        runtimeConfiguration.pushGuardExecutable,
        containedIn: application,
        maximumBytes: 128 * 1_048_576
      )
    )
    let herdrHostSHA256 = sha256(
      try readRegularFile(
        runtimeConfiguration.herdrHostExecutable,
        containedIn: runtimeConfiguration.herdrHostExecutable.deletingLastPathComponent(),
        maximumBytes: 128 * 1_048_576
      )
    )
    let resolver = ReleaseOwnedPiRuntimeResolver(
      runtimeRoot: runtimeConfiguration.releaseRuntimeRoot,
      containingApplicationURL: application
    )
    let runtime = try ReleaseOwnedPiRuntimeBoundaryAuthority.engineHelperStartup(using: resolver)
    guard let runtimeIdentity = runtime.releaseIdentity else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    let workflowResources = try PiWorkflowResourceCatalog.inspect(
      resourceRoot: runtimeConfiguration.piResourceRoot
    )
    guard helperSHA256 == declared.helperSHA256,
      askPassSHA256 == declared.askPassSHA256,
      pushGuardSHA256 == declared.pushGuardSHA256,
      herdrHostSHA256 == declared.herdrHostSHA256,
      runtimeIdentity.manifestSHA256 == declared.runtimeManifestSHA256,
      runtimeIdentity.authoritySHA256 == declared.runtimeTreeSHA256,
      workflowResources.manifestSHA256 == declared.workflowResourcesSHA256
    else {
      throw RolloutAuthorityError.previewDrift
    }
    return RolloutObservedReleaseIdentity(
      packaged: declared,
      applicationSHA256: applicationSHA256
    )
  }

  private static func readRegularFile(
    _ url: URL,
    containedIn root: URL,
    maximumBytes: Int
  ) throws -> Data {
    let target = url.standardizedFileURL
    let lexicalRoot = root.standardizedFileURL
    let rootPrefix = lexicalRoot.path + "/"
    guard target.isFileURL, target.path.hasPrefix(rootPrefix),
      lexicalRoot.isFileURL, lexicalRoot.path.hasPrefix("/"), maximumBytes > 0
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    let relativePath = String(target.path.dropFirst(rootPrefix.count))
    let canonicalRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
    let expectedCanonicalTarget = canonicalRoot.appendingPathComponent(relativePath)
      .standardizedFileURL
    guard target.resolvingSymlinksInPath().standardizedFileURL == expectedCanonicalTarget else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    var pathMetadata = stat()
    guard lstat(target.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      pathMetadata.st_mode & 0o022 == 0,
      pathMetadata.st_uid == 0 || pathMetadata.st_uid == geteuid(),
      pathMetadata.st_nlink == 1,
      pathMetadata.st_size > 0,
      pathMetadata.st_size <= maximumBytes
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    let descriptor = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RolloutAuthorityError.invalidReleaseIdentity }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_dev == pathMetadata.st_dev,
      opened.st_ino == pathMetadata.st_ino,
      opened.st_size == pathMetadata.st_size
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    var data = Data(count: Int(opened.st_size))
    let count = data.withUnsafeMutableBytes { buffer -> Int in
      guard let base = buffer.baseAddress else { return -1 }
      var offset = 0
      while offset < buffer.count {
        let result = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { return -1 }
        offset += result
      }
      return offset
    }
    var afterRead = stat()
    guard count == data.count,
      fstat(descriptor, &afterRead) == 0,
      afterRead.st_dev == opened.st_dev,
      afterRead.st_ino == opened.st_ino,
      afterRead.st_size == opened.st_size,
      afterRead.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
      afterRead.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
      afterRead.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
      afterRead.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec
    else {
      throw RolloutAuthorityError.invalidReleaseIdentity
    }
    return data
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
