import Foundation
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

    let snapshot = backend.snapshot()
    #expect(snapshot.service == GitHubTokenConstants.service)
    #expect(snapshot.account == "maroffo")
    #expect(snapshot.label == GitHubTokenConstants.label)
    #expect(snapshot.addCount == 1)
    #expect(snapshot.updateCount == 2)
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

private struct FakeTokenSnapshot: Sendable {
  let service: String?
  let account: String?
  let label: String?
  let value: Data?
  let addCount: Int
  let updateCount: Int
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
    value: Data
  ) throws -> GitHubKeychainUpdateResult {
    lock.withLock {
      updateCount += 1
      guard self.value != nil else { return .missing }
      self.service = service
      self.account = account
      self.value = value
      return .updated
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
        updateCount: updateCount
      )
    }
  }
}
