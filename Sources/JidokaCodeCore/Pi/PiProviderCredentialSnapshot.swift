import Darwin
import Foundation

struct PiProviderCredentialEvidence: Codable, Equatable, Sendable {
  let provider: String
  let type: String
  let expiresAtMilliseconds: Int64
  let accountIdentity: String
  let projectedBytesSHA256: String
  let sourceDevice: UInt64
  let sourceInode: UInt64
  let sourceOwner: UInt32
  let sourcePermissions: UInt16
  let sourceSize: Int64
  let sourceModifiedSeconds: Int64
  let sourceModifiedNanoseconds: Int64

  init(
    provider: String,
    type: String,
    expiresAtMilliseconds: Int64,
    accountIdentity: String,
    projectedBytesSHA256: String,
    sourceDevice: UInt64,
    sourceInode: UInt64,
    sourceOwner: UInt32,
    sourcePermissions: UInt16,
    sourceSize: Int64,
    sourceModifiedSeconds: Int64,
    sourceModifiedNanoseconds: Int64
  ) {
    self.provider = provider
    self.type = type
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.accountIdentity = accountIdentity
    self.projectedBytesSHA256 = projectedBytesSHA256
    self.sourceDevice = sourceDevice
    self.sourceInode = sourceInode
    self.sourceOwner = sourceOwner
    self.sourcePermissions = sourcePermissions
    self.sourceSize = sourceSize
    self.sourceModifiedSeconds = sourceModifiedSeconds
    self.sourceModifiedNanoseconds = sourceModifiedNanoseconds
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case type
    case expiresAtMilliseconds
    case sourceDevice
    case sourceInode
    case sourceOwner
    case sourcePermissions
    case sourceSize
    case sourceModifiedSeconds
    case sourceModifiedNanoseconds
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try values.decode(String.self, forKey: .provider),
      type: try values.decode(String.self, forKey: .type),
      expiresAtMilliseconds: try values.decode(Int64.self, forKey: .expiresAtMilliseconds),
      accountIdentity: "",
      projectedBytesSHA256: "",
      sourceDevice: try values.decode(UInt64.self, forKey: .sourceDevice),
      sourceInode: try values.decode(UInt64.self, forKey: .sourceInode),
      sourceOwner: try values.decode(UInt32.self, forKey: .sourceOwner),
      sourcePermissions: try values.decode(UInt16.self, forKey: .sourcePermissions),
      sourceSize: try values.decode(Int64.self, forKey: .sourceSize),
      sourceModifiedSeconds: try values.decode(Int64.self, forKey: .sourceModifiedSeconds),
      sourceModifiedNanoseconds: try values.decode(
        Int64.self,
        forKey: .sourceModifiedNanoseconds
      )
    )
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(provider, forKey: .provider)
    try values.encode(type, forKey: .type)
    try values.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
    try values.encode(sourceDevice, forKey: .sourceDevice)
    try values.encode(sourceInode, forKey: .sourceInode)
    try values.encode(sourceOwner, forKey: .sourceOwner)
    try values.encode(sourcePermissions, forKey: .sourcePermissions)
    try values.encode(sourceSize, forKey: .sourceSize)
    try values.encode(sourceModifiedSeconds, forKey: .sourceModifiedSeconds)
    try values.encode(sourceModifiedNanoseconds, forKey: .sourceModifiedNanoseconds)
  }

  var replacementBindingSHA256: String {
    let object: [String: Any] = [
      "accountIdentity": accountIdentity,
      "expiresAtMilliseconds": expiresAtMilliseconds,
      "projectedBytesSHA256": projectedBytesSHA256,
      "provider": provider,
      "sourceDevice": sourceDevice,
      "sourceInode": sourceInode,
      "sourceModifiedNanoseconds": sourceModifiedNanoseconds,
      "sourceModifiedSeconds": sourceModifiedSeconds,
      "sourceOwner": sourceOwner,
      "sourcePermissions": sourcePermissions,
      "sourceSize": sourceSize,
      "type": type,
    ]
    return (try? PiTUIFileProtocol.canonicalJSONData(object))
      .map(PiTUIFileProtocol.sha256) ?? ""
  }

  func validate() throws {
    guard provider.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,63}$/) != nil,
      type == "oauth",
      expiresAtMilliseconds > 0,
      !accountIdentity.isEmpty,
      accountIdentity.utf8.count <= 1_024,
      !accountIdentity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      GitHubInputValidation.validSHA256(projectedBytesSHA256),
      sourceDevice > 0,
      sourceInode > 0,
      sourcePermissions & 0o077 == 0,
      sourceSize > 0
    else { throw PiTUIRuntimeError.invalidConfiguration }
  }
}

struct PiProviderCredentialSnapshotter: Sendable {
  private static let maximumSourceBytes = 1_048_576
  private static let maximumCredentialBytes = 65_536
  private static let credentialFileName = "auth.json"

  private let sourceURL: URL

  init(sourceURL: URL) throws {
    guard sourceURL.isFileURL, sourceURL.path.hasPrefix("/"),
      sourceURL.lastPathComponent == Self.credentialFileName
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    self.sourceURL = sourceURL.standardizedFileURL
  }

  func inspect(
    provider: String,
    validUntil: Date
  ) throws -> PiProviderCredentialEvidence {
    var projected = try projection(provider: provider, validUntil: validUntil)
    defer { projected.encoded.resetBytes(in: 0..<projected.encoded.count) }
    try projected.evidence.validate()
    return projected.evidence
  }

  @discardableResult
  func install(
    provider: String,
    validUntil: Date,
    agentDirectory: URL
  ) throws -> PiProviderCredentialEvidence {
    guard try PiTUIFileProtocol.safePrivateDirectory(agentDirectory) else {
      throw PiTUIRuntimeError.unsafePath
    }
    var projected = try projection(provider: provider, validUntil: validUntil)
    defer { projected.encoded.resetBytes(in: 0..<projected.encoded.count) }
    try PiTUIFileProtocol.createPrivateFile(
      data: projected.encoded,
      at: agentDirectory.appendingPathComponent(Self.credentialFileName),
      idempotent: true
    )
    return try inspectInstalled(
      in: agentDirectory,
      expected: projected.evidence
    )
  }

  func inspectInstalled(
    in agentDirectory: URL,
    expected: PiProviderCredentialEvidence
  ) throws -> PiProviderCredentialEvidence {
    guard try PiTUIFileProtocol.safePrivateDirectory(agentDirectory) else {
      throw PiTUIRuntimeError.unsafePath
    }
    var data = try PiTUIFileProtocol.readPrivateFile(
      agentDirectory.appendingPathComponent(Self.credentialFileName),
      maximumBytes: Self.maximumCredentialBytes
    )
    defer { data.resetBytes(in: 0..<data.count) }
    try expected.validate()
    guard PiTUIFileProtocol.sha256(data) == expected.projectedBytesSHA256 else {
      throw PiTUIRuntimeError.identityMismatch
    }
    return expected
  }

  static func remove(from agentDirectory: URL) throws {
    guard try PiTUIFileProtocol.safePrivateDirectory(agentDirectory) else {
      throw PiTUIRuntimeError.unsafePath
    }
    let parent = try PiTUIFileProtocol.canonicalExistingURL(agentDirectory)
    let parentDescriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0, DarwinACLAuthority.hasNoAllowEntries(parentDescriptor) else {
      if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
      throw PiTUIRuntimeError.fileUnavailable
    }
    defer { _ = Darwin.close(parentDescriptor) }
    let listingDescriptor = Darwin.dup(parentDescriptor)
    guard listingDescriptor >= 0, let stream = fdopendir(listingDescriptor) else {
      if listingDescriptor >= 0 { _ = Darwin.close(listingDescriptor) }
      throw PiTUIRuntimeError.fileUnavailable
    }
    var names: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      if name == credentialFileName || name.hasPrefix(".\(credentialFileName)") {
        names.append(name)
      }
    }
    closedir(stream)
    for name in names.sorted() {
      guard validCredentialArtifactName(name) else {
        throw PiTUIRuntimeError.unsafePath
      }
      try scrub(name: name, parentDescriptor: parentDescriptor)
    }
  }

  private static func validCredentialArtifactName(_ name: String) -> Bool {
    if name == credentialFileName || name == ".\(credentialFileName).prepared" {
      return true
    }
    let prefix = ".\(credentialFileName)."
    let suffix = ".staging"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    let identifier = String(name[start..<end])
    return UUID(uuidString: identifier)?.uuidString.lowercased() == identifier
  }

  private static func scrub(name: String, parentDescriptor: Int32) throws {
    let descriptor = Darwin.openat(
      parentDescriptor,
      name,
      O_RDWR | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw PiTUIRuntimeError.fileUnavailable }
    defer { _ = Darwin.close(descriptor) }
    var metadata = stat()
    var current = stat()
    guard fstat(descriptor, &metadata) == 0,
      fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      metadata.st_dev == current.st_dev,
      metadata.st_ino == current.st_ino,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o600,
      metadata.st_nlink == 1,
      metadata.st_size >= 0,
      metadata.st_size <= maximumCredentialBytes
    else { throw PiTUIRuntimeError.unsafePath }
    var zeros = [UInt8](repeating: 0, count: min(max(Int(metadata.st_size), 1), 4_096))
    defer { zeros.resetBytes(in: 0..<zeros.count) }
    var offset: off_t = 0
    while offset < metadata.st_size {
      let count = min(zeros.count, Int(metadata.st_size - offset))
      let written = zeros.withUnsafeBytes { bytes in
        pwrite(descriptor, bytes.baseAddress, count, offset)
      }
      if written > 0 {
        offset += off_t(written)
      } else if written == -1, errno == EINTR {
        continue
      } else {
        throw PiTUIRuntimeError.writeFailed(errno)
      }
    }
    var after = stat()
    guard fsync(descriptor) == 0,
      fstat(descriptor, &after) == 0,
      after.st_dev == metadata.st_dev,
      after.st_ino == metadata.st_ino,
      after.st_mode == metadata.st_mode,
      after.st_uid == metadata.st_uid,
      after.st_nlink == metadata.st_nlink,
      after.st_size == metadata.st_size,
      unlinkat(parentDescriptor, name, 0) == 0,
      fsync(parentDescriptor) == 0
    else { throw PiTUIRuntimeError.writeFailed(errno) }
  }

  private struct Projection {
    var encoded: Data
    let evidence: PiProviderCredentialEvidence
  }

  private func projection(
    provider: String,
    validUntil: Date
  ) throws -> Projection {
    guard provider.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,63}$/) != nil,
      validUntil.timeIntervalSince1970.isFinite
    else {
      throw PiTUIRuntimeError.invalidConfiguration
    }
    var snapshot = try readSource()
    defer { snapshot.data.resetBytes(in: 0..<snapshot.data.count) }
    return try autoreleasepool {
      guard
        let root = try JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any],
        (1...32).contains(root.count),
        let credential = root[provider] as? [String: Any],
        credential["type"] as? String == "oauth",
        Set(credential.keys).isSubset(of: ["type", "access", "refresh", "expires", "accountId"]),
        Set(["type", "access", "refresh", "expires"]).isSubset(of: Set(credential.keys)),
        let access = credential["access"] as? String,
        let refresh = credential["refresh"] as? String,
        (16...32_768).contains(access.utf8.count),
        (16...32_768).contains(refresh.utf8.count),
        let expiresNumber = credential["expires"] as? NSNumber,
        CFGetTypeID(expiresNumber) != CFBooleanGetTypeID(),
        expiresNumber.doubleValue.isFinite,
        expiresNumber.doubleValue.rounded(.towardZero) == expiresNumber.doubleValue,
        expiresNumber.doubleValue <= Double(Int64.max),
        expiresNumber.doubleValue >= Double(Int64.min),
        expiresNumber.int64Value >= Int64(validUntil.timeIntervalSince1970 * 1_000),
        let account = credential["accountId"] as? String,
        let accountIdentity = normalizedAccountIdentity(account)
      else {
        throw PiTUIRuntimeError.invalidConfiguration
      }
      // JSONSerialization necessarily materializes immutable Foundation strings here;
      // the uniquely owned source and encoded byte buffers are zeroed around that boundary.
      var encoded = try JSONSerialization.data(
        withJSONObject: [provider: credential],
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      encoded.append(0x0A)
      guard encoded.count <= Self.maximumCredentialBytes else {
        encoded.resetBytes(in: 0..<encoded.count)
        throw PiTUIRuntimeError.fileTooLarge
      }
      let projectedBytesSHA256 = PiTUIFileProtocol.sha256(encoded)
      return Projection(
        encoded: encoded,
        evidence: PiProviderCredentialEvidence(
          provider: provider,
          type: "oauth",
          expiresAtMilliseconds: expiresNumber.int64Value,
          accountIdentity: accountIdentity,
          projectedBytesSHA256: projectedBytesSHA256,
          sourceDevice: UInt64(snapshot.metadata.st_dev),
          sourceInode: UInt64(snapshot.metadata.st_ino),
          sourceOwner: snapshot.metadata.st_uid,
          sourcePermissions: UInt16(snapshot.metadata.st_mode & 0o777),
          sourceSize: Int64(snapshot.metadata.st_size),
          sourceModifiedSeconds: Int64(snapshot.metadata.st_mtimespec.tv_sec),
          sourceModifiedNanoseconds: Int64(snapshot.metadata.st_mtimespec.tv_nsec)
        )
      )
    }
  }

  private func normalizedAccountIdentity(_ value: String) -> String? {
    let normalized = value.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 1_024,
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return normalized
  }

  private func readSource() throws -> (data: Data, metadata: stat) {
    let descriptor = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PiTUIRuntimeError.fileUnavailable }
    defer { _ = Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(),
      before.st_mode & 0o077 == 0,
      before.st_nlink == 1,
      before.st_size >= 1,
      before.st_size <= Self.maximumSourceBytes
    else {
      throw PiTUIRuntimeError.unsafePath
    }
    var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    var offset = 0
    try bytes.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      while offset < buffer.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
        if count > 0 {
          offset += count
        } else if count == -1, errno == EINTR {
          continue
        } else {
          throw PiTUIRuntimeError.fileUnavailable
        }
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      DarwinACLAuthority.hasNoAllowEntries(descriptor),
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_uid == after.st_uid,
      before.st_mode == after.st_mode,
      before.st_nlink == after.st_nlink,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else {
      throw PiTUIRuntimeError.identityMismatch
    }
    return (Data(bytes), before)
  }
}
