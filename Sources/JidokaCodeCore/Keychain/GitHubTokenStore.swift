import Foundation
import Security

public enum GitHubTokenConstants {
  public static let service = "com.maroffo.JidokaCode.github"
  public static let label = "Jidoka Code GitHub credential"
}

public enum GitHubTokenStoreError: Error, Equatable, Sendable {
  case invalidAccount
  case invalidToken
  case missingToken
  case unexpectedStatus(OSStatus)
  case inconsistentMutation
}

enum GitHubKeychainAddResult: Equatable, Sendable {
  case added
  case duplicate
}

enum GitHubKeychainUpdateResult: Equatable, Sendable {
  case updated
  case missing
}

protocol GitHubTokenKeychainBackend: Sendable {
  func read(service: String, account: String) throws -> Data?
  func add(service: String, account: String, value: Data, label: String) throws
    -> GitHubKeychainAddResult
  func update(service: String, account: String, value: Data) throws
    -> GitHubKeychainUpdateResult
  func delete(service: String, account: String) throws -> Bool
}

public protocol GitHubTokenProviding: Sendable {
  func token() async throws -> Data
}

public actor GitHubTokenStore: GitHubTokenProviding {
  public nonisolated let account: String
  private let backend: any GitHubTokenKeychainBackend

  public init(account: String) throws {
    guard GitHubInputValidation.validOwner(account) else {
      throw GitHubTokenStoreError.invalidAccount
    }
    self.account = account
    backend = SystemGitHubTokenKeychainBackend()
  }

  init(
    account: String,
    backend: any GitHubTokenKeychainBackend
  ) throws {
    guard GitHubInputValidation.validOwner(account) else {
      throw GitHubTokenStoreError.invalidAccount
    }
    self.account = account
    self.backend = backend
  }

  public func token() async throws -> Data {
    guard
      let value = try backend.read(
        service: GitHubTokenConstants.service,
        account: account
      )
    else {
      throw GitHubTokenStoreError.missingToken
    }
    try Self.validate(token: value)
    return value
  }

  public func containsCredential() throws -> Bool {
    guard
      var value = try backend.read(
        service: GitHubTokenConstants.service,
        account: account
      )
    else {
      return false
    }
    let count = value.count
    defer { value.resetBytes(in: 0..<count) }
    try Self.validate(token: value)
    return true
  }

  public func replace(with value: Data) throws {
    try Self.validate(token: value)
    switch try backend.update(
      service: GitHubTokenConstants.service,
      account: account,
      value: value
    ) {
    case .updated:
      return
    case .missing:
      switch try backend.add(
        service: GitHubTokenConstants.service,
        account: account,
        value: value,
        label: GitHubTokenConstants.label
      ) {
      case .added:
        return
      case .duplicate:
        guard
          try backend.update(
            service: GitHubTokenConstants.service,
            account: account,
            value: value
          ) == .updated
        else {
          throw GitHubTokenStoreError.inconsistentMutation
        }
      }
    }
  }

  public func delete() throws {
    _ = try backend.delete(
      service: GitHubTokenConstants.service,
      account: account
    )
  }

  private static func validate(token: Data) throws {
    guard (20...2_048).contains(token.count),
      let string = String(data: token, encoding: .utf8),
      string.utf8.count == token.count,
      string.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw GitHubTokenStoreError.invalidToken
    }
  }
}

struct SystemGitHubTokenKeychainBackend: GitHubTokenKeychainBackend {
  func read(service: String, account: String) throws -> Data? {
    var result: CFTypeRef?
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else {
        throw GitHubTokenStoreError.inconsistentMutation
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  func add(
    service: String,
    account: String,
    value: Data,
    label: String
  ) throws -> GitHubKeychainAddResult {
    var query = baseQuery(service: service, account: account)
    query[kSecValueData as String] = value
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    query[kSecAttrLabel as String] = label
    let status = SecItemAdd(query as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return .added
    case errSecDuplicateItem:
      return .duplicate
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  func update(
    service: String,
    account: String,
    value: Data
  ) throws -> GitHubKeychainUpdateResult {
    let attributes: [String: Any] = [
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrLabel as String: GitHubTokenConstants.label,
    ]
    let status = SecItemUpdate(
      baseQuery(service: service, account: account) as CFDictionary,
      attributes as CFDictionary
    )
    switch status {
    case errSecSuccess:
      return .updated
    case errSecItemNotFound:
      return .missing
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  func delete(service: String, account: String) throws -> Bool {
    let status = SecItemDelete(
      baseQuery(service: service, account: account) as CFDictionary
    )
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}
