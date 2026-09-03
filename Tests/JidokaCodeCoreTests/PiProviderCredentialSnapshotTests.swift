import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Scoped Pi provider credential snapshots", .serialized)
struct PiProviderCredentialSnapshotTests {
  @Test("one unexpired OAuth provider is projected and securely removed")
  func scopedProjection() throws {
    let root = try privateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    let agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    try makePrivateDirectory(sourceDirectory)
    try makePrivateDirectory(agentDirectory)
    let source = sourceDirectory.appendingPathComponent("auth.json")
    let expires = Int64(Date().addingTimeInterval(7_200).timeIntervalSince1970 * 1_000)
    let sourceObject: [String: Any] = [
      "anthropic": [
        "type": "oauth", "access": String(repeating: "a", count: 32),
        "refresh": String(repeating: "b", count: 32), "expires": expires,
      ],
      "openai-codex": [
        "type": "oauth", "access": String(repeating: "c", count: 32),
        "refresh": String(repeating: "d", count: 32), "expires": expires,
        "accountId": "account-1",
      ],
    ]
    var sourceData = try JSONSerialization.data(
      withJSONObject: sourceObject,
      options: [.sortedKeys]
    )
    sourceData.append(0x0A)
    try PiTUIFileProtocol.createPrivateFile(data: sourceData, at: source)

    let snapshotter = try PiProviderCredentialSnapshotter(sourceURL: source)
    let evidence = try snapshotter.install(
      provider: "openai-codex",
      validUntil: Date().addingTimeInterval(600),
      agentDirectory: agentDirectory
    )
    #expect(evidence.provider == "openai-codex")
    #expect(evidence.type == "oauth")
    #expect(evidence.expiresAtMilliseconds == expires)
    #expect(evidence.accountIdentity == "account-1")
    #expect(GitHubInputValidation.validSHA256(evidence.projectedBytesSHA256))
    #expect(GitHubInputValidation.validSHA256(evidence.replacementBindingSHA256))
    let encodedEvidence = try JSONEncoder().encode(evidence)
    let legacyObject = try #require(
      JSONSerialization.jsonObject(with: encodedEvidence) as? [String: Any]
    )
    #expect(
      !String(decoding: encodedEvidence, as: UTF8.self)
        .contains(String(repeating: "c", count: 32))
    )
    #expect(
      !String(decoding: encodedEvidence, as: UTF8.self)
        .contains(String(repeating: "d", count: 32))
    )
    #expect(legacyObject["accountIdentity"] == nil)
    #expect(legacyObject["projectedBytesSHA256"] == nil)
    let destination = agentDirectory.appendingPathComponent("auth.json")
    let projected = try PiTUIFileProtocol.readPrivateFile(destination, maximumBytes: 65_536)
    let object = try #require(
      JSONSerialization.jsonObject(with: projected) as? [String: Any]
    )
    #expect(Set(object.keys) == ["openai-codex"])
    #expect(object["anthropic"] == nil)
    #expect(PiTUIFileProtocol.sha256(projected) == evidence.projectedBytesSHA256)
    #expect(try PiTUIFileProtocol.safePrivateFile(destination, maximumBytes: 65_536))
    #expect(
      try snapshotter.install(
        provider: "openai-codex",
        validUntil: Date().addingTimeInterval(600),
        agentDirectory: agentDirectory
      ) == evidence
    )

    try PiProviderCredentialSnapshotter.remove(from: agentDirectory)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("canonical credential bytes and account identity reject metadata-preserving drift")
  func canonicalContentAndAccountDrift() throws {
    let root = try privateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    let agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    try makePrivateDirectory(sourceDirectory)
    try makePrivateDirectory(agentDirectory)
    let source = sourceDirectory.appendingPathComponent("auth.json")
    let expires = Int64(Date().addingTimeInterval(7_200).timeIntervalSince1970 * 1_000)
    func encoded(access: String, account: String) throws -> Data {
      var data = try JSONSerialization.data(
        withJSONObject: [
          "openai-codex": [
            "type": "oauth", "access": access,
            "refresh": String(repeating: "r", count: 32),
            "expires": expires, "accountId": account,
          ]
        ],
        options: [.sortedKeys]
      )
      data.append(0x0A)
      return data
    }
    let original = try encoded(access: String(repeating: "a", count: 32), account: "account-1")
    try PiTUIFileProtocol.createPrivateFile(data: original, at: source)
    let snapshotter = try PiProviderCredentialSnapshotter(sourceURL: source)
    let before = try snapshotter.inspect(
      provider: "openai-codex",
      validUntil: Date().addingTimeInterval(600)
    )
    let metadata = try FileManager.default.attributesOfItem(atPath: source.path)
    let inode = try #require((metadata[.systemFileNumber] as? NSNumber)?.uint64Value)
    let modified = try #require(metadata[.modificationDate] as? Date)
    let contentDrift = try encoded(
      access: String(repeating: "b", count: 32),
      account: "account-1"
    )
    #expect(contentDrift.count == original.count)
    let handle = try FileHandle(forWritingTo: source)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: contentDrift)
    try handle.synchronize()
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
    let afterContent = try snapshotter.inspect(
      provider: "openai-codex",
      validUntil: Date().addingTimeInterval(600)
    )
    let contentMetadata = try FileManager.default.attributesOfItem(atPath: source.path)
    #expect((contentMetadata[.systemFileNumber] as? NSNumber)?.uint64Value == inode)
    #expect((contentMetadata[.size] as? NSNumber)?.intValue == original.count)
    #expect(afterContent.projectedBytesSHA256 != before.projectedBytesSHA256)
    #expect(afterContent.accountIdentity == before.accountIdentity)

    let accountDrift = try encoded(
      access: String(repeating: "b", count: 32),
      account: "account-2"
    )
    let accountHandle = try FileHandle(forWritingTo: source)
    try accountHandle.seek(toOffset: 0)
    try accountHandle.write(contentsOf: accountDrift)
    try accountHandle.synchronize()
    try accountHandle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
    let afterAccount = try snapshotter.inspect(
      provider: "openai-codex",
      validUntil: Date().addingTimeInterval(600)
    )
    #expect(afterAccount.accountIdentity == "account-2")
    #expect(afterAccount.accountIdentity != before.accountIdentity)
    #expect(afterAccount.projectedBytesSHA256 != before.projectedBytesSHA256)

    _ = try snapshotter.install(
      provider: "openai-codex",
      validUntil: Date().addingTimeInterval(600),
      agentDirectory: agentDirectory
    )
    let finalDrift = try encoded(
      access: String(repeating: "c", count: 32),
      account: "account-2"
    )
    let finalHandle = try FileHandle(forWritingTo: source)
    try finalHandle.seek(toOffset: 0)
    try finalHandle.write(contentsOf: finalDrift)
    try finalHandle.synchronize()
    try finalHandle.close()
    #expect(throws: PiTUIRuntimeError.divergentFile) {
      _ = try snapshotter.install(
        provider: "openai-codex",
        validUntil: Date().addingTimeInterval(600),
        agentDirectory: agentDirectory
      )
    }
  }

  @Test("final, prepared, and staging projections are scrubbed exactly")
  func crashArtifactScrub() throws {
    let root = try privateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    try makePrivateDirectory(agentDirectory)
    let names = [
      "auth.json",
      ".auth.json.prepared",
      ".auth.json.11111111-1111-1111-1111-111111111111.staging",
    ]
    for name in names {
      let url = agentDirectory.appendingPathComponent(name)
      try Data("secret-projection\n".utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
      )
    }
    try PiProviderCredentialSnapshotter.remove(from: agentDirectory)
    for name in names {
      #expect(
        !FileManager.default.fileExists(atPath: agentDirectory.appendingPathComponent(name).path))
    }
  }

  @Test("malformed or aliased credential artifacts fail closed and remain")
  func unsafeCrashArtifact() throws {
    let root = try privateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let malformedDirectory = root.appendingPathComponent("malformed", isDirectory: true)
    try makePrivateDirectory(malformedDirectory)
    let malformed = malformedDirectory.appendingPathComponent(
      ".auth.json.not-a-uuid.staging"
    )
    try Data("secret\n".utf8).write(to: malformed)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: malformed.path
    )
    #expect(throws: PiTUIRuntimeError.unsafePath) {
      try PiProviderCredentialSnapshotter.remove(from: malformedDirectory)
    }
    #expect(FileManager.default.fileExists(atPath: malformed.path))

    let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
    try makePrivateDirectory(linkedDirectory)
    let prepared = linkedDirectory.appendingPathComponent(".auth.json.prepared")
    let alias = root.appendingPathComponent("credential-alias")
    try Data("secret\n".utf8).write(to: prepared)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: prepared.path
    )
    try FileManager.default.linkItem(at: prepared, to: alias)
    #expect(throws: PiTUIRuntimeError.unsafePath) {
      try PiProviderCredentialSnapshotter.remove(from: linkedDirectory)
    }
    #expect(FileManager.default.fileExists(atPath: prepared.path))
    #expect(FileManager.default.fileExists(atPath: alias.path))
  }

  @Test("missing, expired, and redirected credentials fail closed")
  func denial() throws {
    let root = try privateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    let agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    try makePrivateDirectory(sourceDirectory)
    try makePrivateDirectory(agentDirectory)
    let source = sourceDirectory.appendingPathComponent("auth.json")
    let expired: [String: Any] = [
      "openai-codex": [
        "type": "oauth", "access": String(repeating: "a", count: 32),
        "refresh": String(repeating: "b", count: 32),
        "expires": Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000),
      ]
    ]
    var data = try JSONSerialization.data(withJSONObject: expired, options: [.sortedKeys])
    data.append(0x0A)
    try PiTUIFileProtocol.createPrivateFile(data: data, at: source)
    let snapshotter = try PiProviderCredentialSnapshotter(sourceURL: source)
    #expect(throws: PiTUIRuntimeError.invalidConfiguration) {
      _ = try snapshotter.install(
        provider: "openai-codex",
        validUntil: Date().addingTimeInterval(600),
        agentDirectory: agentDirectory
      )
    }
    #expect(throws: PiTUIRuntimeError.invalidConfiguration) {
      _ = try snapshotter.inspect(
        provider: "anthropic",
        validUntil: Date().addingTimeInterval(600)
      )
    }

    let redirectedDirectory = root.appendingPathComponent("redirected", isDirectory: true)
    try makePrivateDirectory(redirectedDirectory)
    let redirected = redirectedDirectory.appendingPathComponent("auth.json")
    try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: source)
    let redirectedSnapshotter = try PiProviderCredentialSnapshotter(sourceURL: redirected)
    #expect(throws: PiTUIRuntimeError.fileUnavailable) {
      _ = try redirectedSnapshotter.inspect(
        provider: "openai-codex",
        validUntil: Date().addingTimeInterval(600)
      )
    }
  }

  private func privateTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-provider-credential-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try makePrivateDirectory(root)
    return root
  }

  private func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }
}
