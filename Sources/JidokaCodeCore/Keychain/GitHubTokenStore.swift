import Darwin
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
  case invalidAccessPolicy
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
  func update(service: String, account: String, value: Data, label: String) throws
    -> GitHubKeychainUpdateResult
  func prepareBackgroundAccess(service: String, account: String, label: String) throws -> Bool
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
    backend = try SystemGitHubTokenKeychainBackend()
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

  public func prepareForBackgroundAccess() throws {
    guard
      try backend.prepareBackgroundAccess(
        service: GitHubTokenConstants.service,
        account: account,
        label: GitHubTokenConstants.label
      )
    else {
      throw GitHubTokenStoreError.missingToken
    }
  }

  public func replace(with value: Data) throws {
    try Self.validate(token: value)
    switch try backend.update(
      service: GitHubTokenConstants.service,
      account: account,
      value: value,
      label: GitHubTokenConstants.label
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
            value: value,
            label: GitHubTokenConstants.label
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
  private let accessPolicy: GitHubTokenKeychainAccessPolicy

  init() throws {
    accessPolicy = try GitHubTokenKeychainAccessPolicy()
  }

  init(accessPolicy: GitHubTokenKeychainAccessPolicy) {
    self.accessPolicy = accessPolicy
  }

  func read(service: String, account: String) throws -> Data? {
    try recoverPendingReplacement(
      service: service,
      account: account,
      label: GitHubTokenConstants.label
    )
    return try itemData(service: service, account: account)
  }

  func add(
    service: String,
    account: String,
    value: Data,
    label: String
  ) throws -> GitHubKeychainAddResult {
    try recoverPendingReplacement(service: service, account: account, label: label)
    let desiredAccess = try accessPolicy.makeAccess(descriptor: label)
    let status = addItem(
      service: service,
      account: account,
      value: value,
      label: label,
      access: desiredAccess
    )
    switch status {
    case errSecSuccess:
      try verifyAccess(service: service, account: account, label: label)
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
    value: Data,
    label: String
  ) throws -> GitHubKeychainUpdateResult {
    try recoverPendingReplacement(service: service, account: account, label: label)
    guard try currentItem(service: service, account: account) != nil else {
      return .missing
    }
    let desiredAccess = try accessPolicy.makeAccess(descriptor: label)
    try replaceItem(
      service: service,
      account: account,
      value: value,
      label: label,
      desiredAccess: desiredAccess
    )
    return .updated
  }

  func prepareBackgroundAccess(service: String, account: String, label: String) throws -> Bool {
    try recoverPendingReplacement(service: service, account: account, label: label)
    return try prepareBackgroundAccess(
      label: label,
      currentAccess: {
        guard let item = try currentItem(service: service, account: account) else {
          return nil
        }
        return try access(for: item)
      },
      updateAccess: { desiredAccess in
        guard var value = try itemData(service: service, account: account) else {
          return errSecItemNotFound
        }
        defer { value.resetBytes(in: 0..<value.count) }
        try replaceItem(
          service: service,
          account: account,
          value: value,
          label: label,
          desiredAccess: desiredAccess
        )
        return errSecSuccess
      }
    )
  }

  func prepareBackgroundAccess(
    label: String,
    currentAccess: () throws -> SecAccess?,
    updateAccess: (SecAccess) throws -> OSStatus
  ) throws -> Bool {
    guard let existingAccess = try currentAccess() else { return false }
    if accessPolicy.matchesExistingAccess(existingAccess, descriptor: label) {
      return true
    }
    let desiredAccess = try accessPolicy.makeAccess(descriptor: label)
    let status = try updateAccess(desiredAccess)
    switch status {
    case errSecSuccess:
      guard
        let updatedAccess = try currentAccess(),
        accessPolicy.matchesExistingAccess(updatedAccess, descriptor: label)
      else {
        throw GitHubTokenStoreError.inconsistentMutation
      }
      return true
    case errSecItemNotFound:
      return false
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  func prepareAllForBackgroundAccess(service: String, label: String) throws {
    try recoverAllPendingReplacements(service: service, label: label)
    var result: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
    try GitHubTokenKeychainAccessPolicy.validateMigratedAccountCount(rows.count)
    let accounts = try Set(
      rows.map { row in
        guard let account = row[kSecAttrAccount as String] as? String,
          GitHubInputValidation.validOwner(account)
        else {
          throw GitHubTokenStoreError.invalidAccessPolicy
        }
        return account
      })
    for account in accounts.sorted() {
      guard try prepareBackgroundAccess(service: service, account: account, label: label) else {
        throw GitHubTokenStoreError.inconsistentMutation
      }
    }
  }

  private func currentItem(service: String, account: String) throws -> SecKeychainItem? {
    var result: CFTypeRef?
    var query = baseQuery(service: service, account: account)
    query[kSecReturnRef as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let result,
        CFGetTypeID(result) == SecKeychainItemGetTypeID()
      else {
        throw GitHubTokenStoreError.inconsistentMutation
      }
      return unsafeDowncast(result, to: SecKeychainItem.self)
    case errSecItemNotFound:
      return nil
    default:
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
  }

  private func access(for item: SecKeychainItem) throws -> SecAccess {
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess,
      let access
    else {
      throw GitHubTokenStoreError.inconsistentMutation
    }
    return access
  }

  private func itemData(service: String, account: String) throws -> Data? {
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

  private func addItem(
    service: String,
    account: String,
    value: Data,
    label: String,
    access: SecAccess
  ) -> OSStatus {
    var query = baseQuery(service: service, account: account)
    query[kSecValueData as String] = value
    query[kSecAttrLabel as String] = label
    query[kSecAttrAccess as String] = access
    return SecItemAdd(query as CFDictionary, nil)
  }

  private func deleteItem(service: String, account: String) -> OSStatus {
    SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
  }

  private func verifyAccess(service: String, account: String, label: String) throws {
    guard let item = try currentItem(service: service, account: account),
      accessPolicy.matchesExistingAccess(try access(for: item), descriptor: label)
    else {
      throw GitHubTokenStoreError.inconsistentMutation
    }
  }

  private func replacementService(for service: String) -> String {
    "\(service).replacement"
  }

  private func recoverAllPendingReplacements(service: String, label: String) throws {
    var result: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: replacementService(for: service),
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
    try GitHubTokenKeychainAccessPolicy.validateMigratedAccountCount(rows.count)
    let accounts = try Set(
      rows.map { row in
        guard let account = row[kSecAttrAccount as String] as? String,
          GitHubInputValidation.validOwner(account)
        else {
          throw GitHubTokenStoreError.invalidAccessPolicy
        }
        return account
      })
    for account in accounts.sorted() {
      try recoverPendingReplacement(service: service, account: account, label: label)
    }
  }

  private func recoverPendingReplacement(
    service: String,
    account: String,
    label: String
  ) throws {
    let shadowService = replacementService(for: service)
    guard let shadowItem = try currentItem(service: shadowService, account: account) else {
      return
    }
    guard accessPolicy.matchesExistingAccess(try access(for: shadowItem), descriptor: label) else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    if try currentItem(service: service, account: account) != nil {
      let status = deleteItem(service: shadowService, account: account)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw GitHubTokenStoreError.unexpectedStatus(status)
      }
      return
    }
    guard var value = try itemData(service: shadowService, account: account) else {
      throw GitHubTokenStoreError.inconsistentMutation
    }
    defer { value.resetBytes(in: 0..<value.count) }
    let desiredAccess = try accessPolicy.makeAccess(descriptor: label)
    let addStatus = addItem(
      service: service,
      account: account,
      value: value,
      label: label,
      access: desiredAccess
    )
    guard addStatus == errSecSuccess else {
      throw GitHubTokenStoreError.unexpectedStatus(addStatus)
    }
    do {
      try verifyAccess(service: service, account: account, label: label)
    } catch {
      _ = deleteItem(service: service, account: account)
      throw error
    }
    let cleanupStatus = deleteItem(service: shadowService, account: account)
    guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
      throw GitHubTokenStoreError.unexpectedStatus(cleanupStatus)
    }
  }

  private func replaceItem(
    service: String,
    account: String,
    value: Data,
    label: String,
    desiredAccess: SecAccess
  ) throws {
    try recoverPendingReplacement(service: service, account: account, label: label)
    guard try currentItem(service: service, account: account) != nil else {
      throw GitHubTokenStoreError.inconsistentMutation
    }
    let shadowService = replacementService(for: service)
    let shadowStatus = addItem(
      service: shadowService,
      account: account,
      value: value,
      label: label,
      access: desiredAccess
    )
    guard shadowStatus == errSecSuccess else {
      throw GitHubTokenStoreError.unexpectedStatus(shadowStatus)
    }
    do {
      try verifyAccess(service: shadowService, account: account, label: label)
    } catch {
      _ = deleteItem(service: shadowService, account: account)
      throw error
    }
    let deleteStatus = deleteItem(service: service, account: account)
    guard deleteStatus == errSecSuccess else {
      _ = deleteItem(service: shadowService, account: account)
      if deleteStatus == errSecItemNotFound {
        throw GitHubTokenStoreError.inconsistentMutation
      }
      throw GitHubTokenStoreError.unexpectedStatus(deleteStatus)
    }
    let primaryAccess = try accessPolicy.makeAccess(descriptor: label)
    let addStatus = addItem(
      service: service,
      account: account,
      value: value,
      label: label,
      access: primaryAccess
    )
    guard addStatus == errSecSuccess else {
      throw GitHubTokenStoreError.unexpectedStatus(addStatus)
    }
    do {
      try verifyAccess(service: service, account: account, label: label)
    } catch {
      _ = deleteItem(service: service, account: account)
      throw error
    }
    let cleanupStatus = deleteItem(service: shadowService, account: account)
    guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
      throw GitHubTokenStoreError.unexpectedStatus(cleanupStatus)
    }
  }

  func delete(service: String, account: String) throws -> Bool {
    try recoverPendingReplacement(
      service: service,
      account: account,
      label: GitHubTokenConstants.label
    )
    let status = deleteItem(service: service, account: account)
    let shadowStatus = deleteItem(service: replacementService(for: service), account: account)
    guard shadowStatus == errSecSuccess || shadowStatus == errSecItemNotFound else {
      throw GitHubTokenStoreError.unexpectedStatus(shadowStatus)
    }
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
    ]
  }
}

public struct GitHubTokenBackgroundAccess: Sendable {
  public init() {}

  public func prepare() throws {
    try SystemGitHubTokenKeychainBackend().prepareAllForBackgroundAccess(
      service: GitHubTokenConstants.service,
      label: GitHubTokenConstants.label
    )
  }
}

struct GitHubTokenKeychainAccessPolicy: Sendable {
  private static let maximumMigratedAccounts = 3
  private static let teamIdentifier = "X3Q42VNZDC"

  let trustedApplicationPaths: [String]

  init(
    executableURL: URL? = nil,
    codeIsValid: @escaping @Sendable (URL, String) -> Bool = systemCodeIsValid
  ) throws {
    let executable = try Self.requireRegularFile(
      executableURL ?? Self.currentExecutableURL()
    )
    var application = executable.deletingLastPathComponent()
    while application.path != "/", application.pathExtension != "app" {
      application.deleteLastPathComponent()
    }
    guard application.pathExtension == "app" else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    application = try Self.requireDirectory(application)
    let mainExecutable = try Self.requireRegularFile(
      application.appendingPathComponent("Contents/MacOS/Jidoka Code", isDirectory: false)
    )
    let helperExecutable = try Self.requireRegularFile(
      application.appendingPathComponent(
        "Contents/Helpers/JidokaCodeEngineProbe",
        isDirectory: false
      )
    )
    guard executable == mainExecutable || executable == helperExecutable,
      codeIsValid(application, LifecycleProbeConstants.appBundleIdentifier),
      codeIsValid(helperExecutable, LifecycleProbeConstants.helperIdentifier)
    else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    trustedApplicationPaths = [application.path, helperExecutable.path]
  }

  func matchesExistingAccess(_ access: SecAccess, descriptor: String) -> Bool {
    guard let expectedAccess = try? makeAccess(descriptor: descriptor),
      let expected = Self.accessFingerprint(expectedAccess),
      let observed = Self.accessFingerprint(access),
      observed.userID == expected.userID,
      observed.groupID == expected.groupID,
      observed.ownerType == expected.ownerType
    else {
      return false
    }
    return Self.accessACLsAreExact(
      observed: observed.acls,
      expected: expected.acls,
      expectedPartitionCount: trustedApplicationPaths.count
    )
  }

  func makeAccess(descriptor: String) throws -> SecAccess {
    var trustedApplications: [SecTrustedApplication] = []
    for path in trustedApplicationPaths {
      var application: SecTrustedApplication?
      let status = path.withCString {
        SecTrustedApplicationCreateFromPath($0, &application)
      }
      guard status == errSecSuccess, let application else {
        throw GitHubTokenStoreError.unexpectedStatus(status)
      }
      trustedApplications.append(application)
    }
    var access: SecAccess?
    let status = SecAccessCreate(
      descriptor as CFString,
      trustedApplications as CFArray,
      &access
    )
    guard status == errSecSuccess, let access else {
      throw GitHubTokenStoreError.unexpectedStatus(status)
    }
    return access
  }

  static func validateMigratedAccountCount(_ count: Int) throws {
    guard (0...maximumMigratedAccounts).contains(count) else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
  }

  struct AccessACL: Hashable {
    let authorizations: [String]
    let applications: [Data]?
    let descriptor: String
    let prompt: UInt16
  }

  struct AccessFingerprint: Equatable {
    let userID: uid_t
    let groupID: gid_t
    let ownerType: SecAccessOwnerType
    let acls: [AccessACL]
  }

  static func accessACLsAreExact(
    observed: [AccessACL],
    expected: [AccessACL],
    expectedPartitionCount: Int
  ) -> Bool {
    guard !observed.isEmpty, !expected.isEmpty,
      expectedPartitionCount > 0
    else {
      return false
    }
    let required = Set(
      expected.filter { acl in
        !isIntegrityACL(acl) && !isPartitionACL(acl)
      })
    let observedSet = Set(observed)
    guard !required.isEmpty, required.isSubset(of: observedSet) else {
      return false
    }
    if expected.contains(where: isIntegrityACL),
      !observed.contains(where: validIntegrityACL)
    {
      return false
    }
    if expected.contains(where: isPartitionACL),
      !observed.contains(where: {
        validPartitionACL($0, expectedCount: expectedPartitionCount)
      })
    {
      return false
    }
    return observedSet.allSatisfy { acl in
      required.contains(acl)
        || validIntegrityACL(acl)
        || validPartitionACL(acl, expectedCount: expectedPartitionCount)
    }
  }

  private static func accessFingerprint(_ access: SecAccess) -> AccessFingerprint? {
    var userID = uid_t()
    var groupID = gid_t()
    var ownerType = SecAccessOwnerType()
    guard
      SecAccessCopyOwnerAndACL(
        access,
        &userID,
        &groupID,
        &ownerType,
        nil
      ) == errSecSuccess
    else {
      return nil
    }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess,
      let entries = list as? [SecACL],
      (1...32).contains(entries.count)
    else {
      return nil
    }
    var result: [AccessACL] = []
    result.reserveCapacity(entries.count)
    for entry in entries {
      guard
        let authorizations = SecACLCopyAuthorizations(entry) as? [String],
        (1...32).contains(authorizations.count)
      else {
        return nil
      }
      var applicationList: CFArray?
      var descriptor: CFString?
      var prompt = SecKeychainPromptSelector()
      guard
        SecACLCopyContents(
          entry,
          &applicationList,
          &descriptor,
          &prompt
        ) == errSecSuccess,
        let descriptor,
        (descriptor as String).utf8.count <= 16_384
      else {
        return nil
      }
      let applicationData: [Data]?
      if let applications = applicationList as? [SecTrustedApplication] {
        guard applications.count <= 8 else { return nil }
        var data: [Data] = []
        data.reserveCapacity(applications.count)
        for application in applications {
          var value: CFData?
          guard SecTrustedApplicationCopyData(application, &value) == errSecSuccess,
            let value,
            (value as Data).count <= 16_384
          else {
            return nil
          }
          data.append(value as Data)
        }
        applicationData = data.sorted { $0.lexicographicallyPrecedes($1) }
      } else if applicationList == nil {
        applicationData = nil
      } else {
        return nil
      }
      result.append(
        AccessACL(
          authorizations: authorizations.sorted(),
          applications: applicationData,
          descriptor: descriptor as String,
          prompt: prompt.rawValue
        )
      )
    }
    return AccessFingerprint(
      userID: userID,
      groupID: groupID,
      ownerType: ownerType,
      acls: result
    )
  }

  private static func isIntegrityACL(_ acl: AccessACL) -> Bool {
    acl.authorizations == [kSecACLAuthorizationIntegrity as String]
      && acl.applications == nil
  }

  private static func isPartitionACL(_ acl: AccessACL) -> Bool {
    acl.authorizations == [kSecACLAuthorizationPartitionID as String]
      && acl.applications == nil
  }

  private static func validIntegrityACL(_ acl: AccessACL) -> Bool {
    isIntegrityACL(acl)
      && acl.prompt == 0
      && acl.descriptor.utf8.count == 64
      && acl.descriptor.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
      }
  }

  private static func validPartitionACL(_ acl: AccessACL, expectedCount: Int) -> Bool {
    guard isPartitionACL(acl),
      acl.applications == nil,
      acl.prompt == 0,
      let data = lowercaseHexData(acl.descriptor),
      data.count <= 8_192,
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ),
      let dictionary = propertyList as? [String: Any],
      Set(dictionary.keys) == Set(["Partitions"]),
      let partitions = dictionary["Partitions"] as? [String],
      (1...expectedCount).contains(partitions.count)
    else {
      return false
    }
    return partitions.allSatisfy { $0 == "teamid:\(teamIdentifier)" }
  }

  private static func lowercaseHexData(_ value: String) -> Data? {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.count <= 16_384,
      bytes.allSatisfy({
        (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
      })
    else {
      return nil
    }
    var result = Data()
    result.reserveCapacity(bytes.count / 2)
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = hexNibble(bytes[index]),
        let low = hexNibble(bytes[index + 1])
      else {
        return nil
      }
      result.append((high << 4) | low)
    }
    return result
  }

  private static func hexNibble(_ value: UInt8) -> UInt8? {
    switch value {
    case 0x30...0x39: value - 0x30
    case 0x61...0x66: value - 0x61 + 10
    default: nil
    }
  }

  private static func systemCodeIsValid(at url: URL, identifier: String) -> Bool {
    guard
      [
        LifecycleProbeConstants.appBundleIdentifier,
        LifecycleProbeConstants.helperIdentifier,
      ].contains(identifier)
    else {
      return false
    }
    let requirementText =
      "identifier \"\(identifier)\" and anchor apple generic "
      + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
      + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
      + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        requirementText as CFString,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return false
    }
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code
    else {
      return false
    }
    let flags = SecCSFlags(
      rawValue: UInt32(
        kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
          | kSecCSRestrictSymlinks
      )
    )
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }

  private static func currentExecutableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 1 else { throw GitHubTokenStoreError.invalidAccessPolicy }
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    return URL(
      fileURLWithFileSystemRepresentation: buffer,
      isDirectory: false,
      relativeTo: nil
    )
  }

  private static func requireRegularFile(_ url: URL) throws -> URL {
    try require(url, type: S_IFREG)
  }

  private static func requireDirectory(_ url: URL) throws -> URL {
    try require(url, type: S_IFDIR)
  }

  private static func require(_ url: URL, type: mode_t) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    let standardized = url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath()
    guard standardized.path == canonical.path else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    var metadata = stat()
    guard lstat(canonical.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == type
    else {
      throw GitHubTokenStoreError.invalidAccessPolicy
    }
    return canonical
  }
}
