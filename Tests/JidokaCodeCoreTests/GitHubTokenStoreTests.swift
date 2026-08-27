import Foundation
import Security
import Testing

@testable import JidokaCodeCore

@Suite("GitHub token Keychain boundary")
struct GitHubTokenStoreTests {
  @Test("stable service and account support atomic create then replace")
  func replaceRoundTrip() async throws {
    let backend = FakeGitHubTokenBackend()
    let store = try GitHubTokenStore(account: "maroffo", backend: backend)
    let first = Data(repeating: 0x61, count: 32)
    let second = Data(repeating: 0x62, count: 32)

    try await store.replace(with: first)
    #expect(try await store.token() == first)
    try await store.replace(with: second)
    #expect(try await store.token() == second)
    try await store.prepareForBackgroundAccess()

    let snapshot = backend.snapshot()
    #expect(snapshot.service == GitHubTokenConstants.service)
    #expect(snapshot.account == "maroffo")
    #expect(snapshot.label == GitHubTokenConstants.label)
    #expect(snapshot.addCount == 1)
    #expect(snapshot.updateCount == 2)
    #expect(snapshot.backgroundAccessCount == 1)
    #expect(snapshot.value == second)

    try await store.delete()
    await #expect(throws: GitHubTokenStoreError.missingToken) {
      _ = try await store.token()
    }
  }

  @Test("duplicate add race resolves through one atomic update")
  func duplicateRace() async throws {
    let backend = FakeGitHubTokenBackend(simulateDuplicateAdd: true)
    let store = try GitHubTokenStore(account: "automation-bot", backend: backend)
    let token = Data(repeating: 0x63, count: 32)

    try await store.replace(with: token)
    #expect(try await store.token() == token)
    let snapshot = backend.snapshot()
    #expect(snapshot.addCount == 1)
    #expect(snapshot.updateCount == 2)
  }

  @Test("packaged access policy trusts only the UI bundle and engine helper")
  func packagedAccessPolicy() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("jidoka-keychain-policy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Jidoka Code.app", isDirectory: true)
    let main = application.appendingPathComponent(
      "Contents/MacOS/Jidoka Code",
      isDirectory: false
    )
    let helper = application.appendingPathComponent(
      "Contents/Helpers/JidokaCodeEngineProbe",
      isDirectory: false
    )
    let unrelated = application.appendingPathComponent(
      "Contents/Helpers/Unrelated",
      isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: main.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: main.path, contents: Data()))
    #expect(FileManager.default.createFile(atPath: helper.path, contents: Data()))
    #expect(FileManager.default.createFile(atPath: unrelated.path, contents: Data()))

    let expected = [application.path, helper.path]
    let acceptPinnedCode: @Sendable (URL, String) -> Bool = { _, _ in true }
    #expect(
      try GitHubTokenKeychainAccessPolicy(
        executableURL: main,
        codeIsValid: acceptPinnedCode
      ).trustedApplicationPaths == expected
    )
    #expect(
      try GitHubTokenKeychainAccessPolicy(
        executableURL: helper,
        codeIsValid: acceptPinnedCode
      ).trustedApplicationPaths == expected
    )
    let policy = try GitHubTokenKeychainAccessPolicy(
      executableURL: main,
      codeIsValid: acceptPinnedCode
    )
    let access = try policy.makeAccess(descriptor: GitHubTokenConstants.label)
    #expect(
      policy.matchesExistingAccess(
        access,
        descriptor: GitHubTokenConstants.label
      )
    )
    #expect(!policy.matchesExistingAccess(access, descriptor: "wrong descriptor"))
    let extraAccess = try makeKeychainAccess(
      paths: expected + [unrelated.path],
      descriptor: GitHubTokenConstants.label
    )
    #expect(
      !policy.matchesExistingAccess(
        extraAccess,
        descriptor: GitHubTokenConstants.label
      )
    )
    let emptyAccess = try makeKeychainAccess(
      paths: [],
      descriptor: GitHubTokenConstants.label
    )
    #expect(
      !policy.matchesExistingAccess(
        emptyAccess,
        descriptor: GitHubTokenConstants.label
      )
    )
    let requiredApplications = [Data([0x01]), Data([0x02])]
    let required = GitHubTokenKeychainAccessPolicy.AccessACL(
      authorizations: [kSecACLAuthorizationDecrypt as String],
      applications: requiredApplications,
      descriptor: GitHubTokenConstants.label,
      prompt: 0
    )
    let extra = GitHubTokenKeychainAccessPolicy.AccessACL(
      authorizations: required.authorizations,
      applications: requiredApplications + [Data([0x03])],
      descriptor: required.descriptor,
      prompt: required.prompt
    )
    let any = GitHubTokenKeychainAccessPolicy.AccessACL(
      authorizations: [kSecACLAuthorizationAny as String],
      applications: requiredApplications,
      descriptor: required.descriptor,
      prompt: required.prompt
    )
    let integrity = GitHubTokenKeychainAccessPolicy.AccessACL(
      authorizations: [kSecACLAuthorizationIntegrity as String],
      applications: nil,
      descriptor: String(repeating: "a", count: 64),
      prompt: 0
    )
    let partition = GitHubTokenKeychainAccessPolicy.AccessACL(
      authorizations: [kSecACLAuthorizationPartitionID as String],
      applications: nil,
      descriptor: try partitionDescriptor(
        teamIdentifier: "X3Q42VNZDC",
        count: 2
      ),
      prompt: 0
    )
    #expect(
      GitHubTokenKeychainAccessPolicy.accessACLsAreExact(
        observed: [required, required, required, integrity, partition],
        expected: [required],
        expectedPartitionCount: 2
      )
    )
    #expect(
      !GitHubTokenKeychainAccessPolicy.accessACLsAreExact(
        observed: [],
        expected: [required],
        expectedPartitionCount: 2
      )
    )
    #expect(
      !GitHubTokenKeychainAccessPolicy.accessACLsAreExact(
        observed: [required, extra],
        expected: [required],
        expectedPartitionCount: 2
      )
    )
    #expect(
      !GitHubTokenKeychainAccessPolicy.accessACLsAreExact(
        observed: [required, any],
        expected: [required],
        expectedPartitionCount: 2
      )
    )
    #expect(
      !GitHubTokenKeychainAccessPolicy.accessACLsAreExact(
        observed: [required, integrity, partition],
        expected: [required],
        expectedPartitionCount: 1
      )
    )
    #expect(throws: GitHubTokenStoreError.invalidAccessPolicy) {
      _ = try GitHubTokenKeychainAccessPolicy(
        executableURL: unrelated,
        codeIsValid: acceptPinnedCode
      )
    }
    #expect(throws: GitHubTokenStoreError.invalidAccessPolicy) {
      _ = try GitHubTokenKeychainAccessPolicy(
        executableURL: main,
        codeIsValid: { _, identifier in
          identifier != LifecycleProbeConstants.helperIdentifier
        }
      )
    }
    try GitHubTokenKeychainAccessPolicy.validateMigratedAccountCount(3)
    #expect(throws: GitHubTokenStoreError.invalidAccessPolicy) {
      try GitHubTokenKeychainAccessPolicy.validateMigratedAccountCount(4)
    }
  }

  @Test("background ACL migration is idempotent and verifies persisted access")
  func backgroundAccessMigration() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("jidoka-keychain-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Jidoka Code.app", isDirectory: true)
    let main = application.appendingPathComponent("Contents/MacOS/Jidoka Code")
    let helper = application.appendingPathComponent(
      "Contents/Helpers/JidokaCodeEngineProbe"
    )
    try FileManager.default.createDirectory(
      at: main.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: main.path, contents: Data()))
    #expect(FileManager.default.createFile(atPath: helper.path, contents: Data()))
    let policy = try GitHubTokenKeychainAccessPolicy(
      executableURL: main,
      codeIsValid: { _, _ in true }
    )
    let backend = SystemGitHubTokenKeychainBackend(accessPolicy: policy)
    let exact = try policy.makeAccess(descriptor: GitHubTokenConstants.label)
    let mismatched = try policy.makeAccess(descriptor: "wrong descriptor")

    var exactReads = 0
    var exactUpdates = 0
    #expect(
      try backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: {
          exactReads += 1
          return exact
        },
        updateAccess: { _ in
          exactUpdates += 1
          return errSecSuccess
        }
      )
    )
    #expect(exactReads == 1)
    #expect(exactUpdates == 0)

    var migrationReads = [mismatched, exact]
    var migrationUpdates = 0
    #expect(
      try backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: { migrationReads.removeFirst() },
        updateAccess: { _ in
          migrationUpdates += 1
          return errSecSuccess
        }
      )
    )
    #expect(migrationReads.isEmpty)
    #expect(migrationUpdates == 1)

    #expect(throws: GitHubTokenStoreError.inconsistentMutation) {
      var reads = [mismatched, mismatched]
      _ = try backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: { reads.removeFirst() },
        updateAccess: { _ in errSecSuccess }
      )
    }
    #expect(
      try !backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: { nil },
        updateAccess: { _ in
          Issue.record("a missing item attempted an ACL update")
          return errSecSuccess
        }
      )
    )
    #expect(
      try !backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: { mismatched },
        updateAccess: { _ in errSecItemNotFound }
      )
    )
    #expect(throws: GitHubTokenStoreError.unexpectedStatus(errSecAuthFailed)) {
      _ = try backend.prepareBackgroundAccess(
        label: GitHubTokenConstants.label,
        currentAccess: { mismatched },
        updateAccess: { _ in errSecAuthFailed }
      )
    }
  }

  @Test("invalid account and payload fail before backend access")
  func invalidInputs() async throws {
    let backend = FakeGitHubTokenBackend()
    #expect(throws: GitHubTokenStoreError.invalidAccount) {
      _ = try GitHubTokenStore(account: "bad/account", backend: backend)
    }
    let store = try GitHubTokenStore(account: "maroffo", backend: backend)
    for token in [
      Data(),
      Data("short".utf8),
      Data("synthetic-token-with-newline\n".utf8),
      Data("synthetic token with spaces".utf8),
      Data([0xFF, 0xFE] + Array(repeating: 0x61, count: 30)),
    ] {
      await #expect(throws: GitHubTokenStoreError.invalidToken) {
        try await store.replace(with: token)
      }
    }
    #expect(backend.snapshot().updateCount == 0)
  }
}

private func partitionDescriptor(
  teamIdentifier: String,
  count: Int
) throws -> String {
  let data = try PropertyListSerialization.data(
    fromPropertyList: [
      "Partitions": Array(
        repeating: "teamid:\(teamIdentifier)",
        count: count
      )
    ],
    format: .xml,
    options: 0
  )
  return data.map { String(format: "%02x", $0) }.joined()
}

private func makeKeychainAccess(
  paths: [String],
  descriptor: String
) throws -> SecAccess {
  var trustedApplications: [SecTrustedApplication] = []
  for path in paths {
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

private struct FakeTokenSnapshot: Sendable {
  let service: String?
  let account: String?
  let label: String?
  let value: Data?
  let addCount: Int
  let updateCount: Int
  let backgroundAccessCount: Int
}

private final class FakeGitHubTokenBackend: GitHubTokenKeychainBackend,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var service: String?
  private var account: String?
  private var label: String?
  private var value: Data?
  private var addCount = 0
  private var updateCount = 0
  private var backgroundAccessCount = 0
  private var simulateDuplicateAdd: Bool

  init(simulateDuplicateAdd: Bool = false) {
    self.simulateDuplicateAdd = simulateDuplicateAdd
  }

  func read(service: String, account: String) throws -> Data? {
    lock.withLock {
      guard self.service == service, self.account == account else { return nil }
      return value
    }
  }

  func add(
    service: String,
    account: String,
    value: Data,
    label: String
  ) throws -> GitHubKeychainAddResult {
    lock.withLock {
      addCount += 1
      self.service = service
      self.account = account
      self.label = label
      if simulateDuplicateAdd {
        simulateDuplicateAdd = false
        self.value = value
        return .duplicate
      }
      guard self.value == nil else { return .duplicate }
      self.value = value
      return .added
    }
  }

  func update(
    service: String,
    account: String,
    value: Data,
    label: String
  ) throws -> GitHubKeychainUpdateResult {
    lock.withLock {
      updateCount += 1
      guard self.value != nil else { return .missing }
      self.service = service
      self.account = account
      self.label = label
      self.value = value
      return .updated
    }
  }

  func prepareBackgroundAccess(service: String, account: String, label: String) throws -> Bool {
    lock.withLock {
      guard self.service == service, self.account == account, value != nil else {
        return false
      }
      self.label = label
      backgroundAccessCount += 1
      return true
    }
  }

  func delete(service: String, account: String) throws -> Bool {
    lock.withLock {
      guard self.service == service, self.account == account, value != nil else {
        return false
      }
      value = nil
      return true
    }
  }

  func snapshot() -> FakeTokenSnapshot {
    lock.withLock {
      FakeTokenSnapshot(
        service: service,
        account: account,
        label: label,
        value: value,
        addCount: addCount,
        updateCount: updateCount,
        backgroundAccessCount: backgroundAccessCount
      )
    }
  }
}
