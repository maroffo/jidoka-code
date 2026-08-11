import CryptoKit
import Foundation

public enum PackagedPreflightError: Error, Equatable, Sendable {
  case unexpectedBundleIdentifier(String?)
  case manifestMissing
  case resourcePathInvalid
  case manifestNotRegularFile
  case manifestTooLarge(Int)
  case manifestInvalid
  case unsupportedSchema(Int)
  case unexpectedResourceName(String)
}

public struct PackagedPreflightReport: Codable, Equatable, Sendable {
  public let bundleIdentifier: String
  public let manifestSHA256: String
  public let resourceName: String
  public let schemaVersion: Int
  public let status: String
  public let workingDirectory: String
}

public enum PackagedPreflight {
  public static let expectedBundleIdentifier = "com.maroffo.JidokaCode"
  public static let expectedResourceName = "jidoka-code"
  public static let supportedSchemaVersion = 1

  public static func inspect(
    bundleURL: URL,
    bundleIdentifier: String?,
    workingDirectory: String
  ) throws -> PackagedPreflightReport {
    guard bundleIdentifier == expectedBundleIdentifier else {
      throw PackagedPreflightError.unexpectedBundleIdentifier(bundleIdentifier)
    }

    var currentURL = bundleURL
    for component in ["Contents", "Resources", "Pi"] {
      currentURL.appendPathComponent(component, isDirectory: true)
      let values = try currentURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw PackagedPreflightError.resourcePathInvalid
      }
    }

    let manifestURL = currentURL.appendingPathComponent("manifest.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw PackagedPreflightError.manifestMissing
    }

    let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw PackagedPreflightError.resourcePathInvalid
    }
    guard values.isRegularFile == true else {
      throw PackagedPreflightError.manifestNotRegularFile
    }

    let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedManifestURL = manifestURL.resolvingSymlinksInPath().standardizedFileURL
    let expectedPrefix =
      resolvedBundleURL.path.hasSuffix("/")
      ? resolvedBundleURL.path
      : resolvedBundleURL.path + "/"
    guard resolvedManifestURL.path.hasPrefix(expectedPrefix) else {
      throw PackagedPreflightError.resourcePathInvalid
    }

    let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
    guard data.count <= 65_536 else {
      throw PackagedPreflightError.manifestTooLarge(data.count)
    }

    guard let manifest = try? JSONDecoder().decode(ResourceManifest.self, from: data) else {
      throw PackagedPreflightError.manifestInvalid
    }
    guard manifest.schemaVersion == supportedSchemaVersion else {
      throw PackagedPreflightError.unsupportedSchema(manifest.schemaVersion)
    }
    guard manifest.name == expectedResourceName else {
      throw PackagedPreflightError.unexpectedResourceName(manifest.name)
    }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return PackagedPreflightReport(
      bundleIdentifier: expectedBundleIdentifier,
      manifestSHA256: digest,
      resourceName: manifest.name,
      schemaVersion: manifest.schemaVersion,
      status: "ok",
      workingDirectory: workingDirectory
    )
  }
}

private struct ResourceManifest: Decodable {
  let name: String
  let schemaVersion: Int
}
