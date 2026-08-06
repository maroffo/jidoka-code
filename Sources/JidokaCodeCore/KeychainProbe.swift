import CryptoKit
import Foundation
import Security

public enum KeychainProbeConstants {
  public static let service = "com.maroffo.JidokaCode.test.github"
  public static let account = "eabf21b6-02df-4854-b9a8-c8a21eafdbca"
  public static let sentinelByteCount = 32
}

public enum KeychainProbeCommand: String, CaseIterable, Sendable {
  case status
  case create
  case read
  case replace
  case delete

  public static func parse(_ arguments: [String]) throws -> KeychainProbeCommand {
    guard arguments.count == 1, let command = KeychainProbeCommand(rawValue: arguments[0]) else {
      throw KeychainProbeError.invalidArguments
    }
    return command
  }
}

public enum KeychainProbeOSStatus: Equatable, Sendable {
  case success
  case itemNotFound
  case duplicateItem
  case unexpected(OSStatus)

  public static func classify(_ status: OSStatus) -> KeychainProbeOSStatus {
    switch status {
    case errSecSuccess: .success
    case errSecItemNotFound: .itemNotFound
    case errSecDuplicateItem: .duplicateItem
    default: .unexpected(status)
    }
  }
}

public enum KeychainProbeError: Error, Equatable, Sendable {
  case invalidArguments
  case duplicateItem
  case missingItem
  case randomGenerationFailed(OSStatus)
  case unexpectedStatus(OSStatus)
  case invalidResult
}

public struct KeychainProbeResult: Codable, Equatable, Sendable {
  public let exists: Bool
  public let sentinelSHA256: String?

  public init(exists: Bool, sentinelSHA256: String?) throws {
    if let sentinelSHA256 {
      guard exists, KeychainProbeDigest.isValidSHA256(sentinelSHA256) else {
        throw KeychainProbeError.invalidResult
      }
    }
    guard exists || sentinelSHA256 == nil else {
      throw KeychainProbeError.invalidResult
    }
    self.exists = exists
    self.sentinelSHA256 = sentinelSHA256
  }
}

public enum KeychainProbeDigest {
  public static func hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}

public struct KeychainProbeStore: Sendable {
  public init() {}

  public func status() throws -> KeychainProbeResult {
    var result: CFTypeRef?
    var query = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch KeychainProbeOSStatus.classify(status) {
    case .success:
      guard result != nil else { throw KeychainProbeError.invalidResult }
      return try KeychainProbeResult(exists: true, sentinelSHA256: nil)
    case .itemNotFound:
      return try KeychainProbeResult(exists: false, sentinelSHA256: nil)
    case .duplicateItem:
      throw KeychainProbeError.unexpectedStatus(status)
    case .unexpected(let value):
      throw KeychainProbeError.unexpectedStatus(value)
    }
  }

  public func create() throws -> KeychainProbeResult {
    guard try !status().exists else { throw KeychainProbeError.duplicateItem }
    let sentinel = try makeSentinel()
    var query = baseQuery
    query[kSecValueData as String] = sentinel
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    query[kSecAttrLabel as String] = "Jidoka Code synthetic S3 sentinel"
    let status = SecItemAdd(query as CFDictionary, nil)
    switch KeychainProbeOSStatus.classify(status) {
    case .success:
      return try KeychainProbeResult(
        exists: true,
        sentinelSHA256: KeychainProbeDigest.hex(of: sentinel)
      )
    case .duplicateItem:
      throw KeychainProbeError.duplicateItem
    case .itemNotFound:
      throw KeychainProbeError.unexpectedStatus(status)
    case .unexpected(let value):
      throw KeychainProbeError.unexpectedStatus(value)
    }
  }

  public func readDigest() throws -> KeychainProbeResult {
    var result: CFTypeRef?
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch KeychainProbeOSStatus.classify(status) {
    case .success:
      guard let data = result as? Data, data.count == KeychainProbeConstants.sentinelByteCount
      else {
        throw KeychainProbeError.invalidResult
      }
      return try KeychainProbeResult(
        exists: true,
        sentinelSHA256: KeychainProbeDigest.hex(of: data)
      )
    case .itemNotFound:
      throw KeychainProbeError.missingItem
    case .duplicateItem:
      throw KeychainProbeError.unexpectedStatus(status)
    case .unexpected(let value):
      throw KeychainProbeError.unexpectedStatus(value)
    }
  }

  public func replace() throws -> KeychainProbeResult {
    guard try status().exists else { throw KeychainProbeError.missingItem }
    let sentinel = try makeSentinel()
    let attributes = [kSecValueData as String: sentinel]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    switch KeychainProbeOSStatus.classify(status) {
    case .success:
      return try KeychainProbeResult(
        exists: true,
        sentinelSHA256: KeychainProbeDigest.hex(of: sentinel)
      )
    case .itemNotFound:
      throw KeychainProbeError.missingItem
    case .duplicateItem:
      throw KeychainProbeError.unexpectedStatus(status)
    case .unexpected(let value):
      throw KeychainProbeError.unexpectedStatus(value)
    }
  }

  public func delete() throws -> KeychainProbeResult {
    let status = SecItemDelete(baseQuery as CFDictionary)
    switch KeychainProbeOSStatus.classify(status) {
    case .success:
      return try KeychainProbeResult(exists: false, sentinelSHA256: nil)
    case .itemNotFound:
      throw KeychainProbeError.missingItem
    case .duplicateItem:
      throw KeychainProbeError.unexpectedStatus(status)
    case .unexpected(let value):
      throw KeychainProbeError.unexpectedStatus(value)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: KeychainProbeConstants.service,
      kSecAttrAccount as String: KeychainProbeConstants.account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func makeSentinel() throws -> Data {
    var data = Data(count: KeychainProbeConstants.sentinelByteCount)
    let status = data.withUnsafeMutableBytes { bytes in
      guard let address = bytes.baseAddress else { return errSecAllocate }
      return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
    }
    guard status == errSecSuccess else {
      throw KeychainProbeError.randomGenerationFailed(status)
    }
    return data
  }
}
