import Darwin
import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("One-shot Git askpass capability", .serialized)
struct GitAskPassTests {
  @Test("brokered credential is host-bound, one-shot, and absent from disk and environment")
  func oneShotRoundTrip() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap")
    defer { fixture.remove() }
    let socketDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let token = Data(String(repeating: "t", count: 32).utf8)
    let broker = GitHubBroker(
      tokenProvider: AskPassTokenProvider(token: token),
      transport: UnusedAskPassHTTPTransport(),
      readAuthority: ExplicitTestRolloutEffectAuthority(),
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git")
    )
    let session = try await withGitCredentialCarrier(remoteURL: remote) {
      try await broker.makeGitCredentialSession(
        remoteURL: remote,
        socketDirectory: socketDirectory,
        timeoutSeconds: 5
      )
    }
    let executable = fixture.root.appendingPathComponent("askpass")
    try writeExecutable(executable, "#!/bin/sh\nexit 0\n")
    let environment = try session.environment(
      askPassExecutable: executable,
      base: try CredentiallessEnvironment.make(
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      )
    )
    #expect(!environment.values.contains(String(decoding: token, as: UTF8.self)))
    var unsafeBase = environment
    unsafeBase["GITHUB_TOKEN"] = "forbidden"
    #expect(throws: GitAskPassError.unsafeEnvironment) {
      _ = try session.environment(askPassExecutable: executable, base: unsafeBase)
    }
    let observed = try GitAskPassClient.credential(
      prompt: "Password for 'https://x-access-token@github.com':",
      environment: environment
    )
    #expect(observed == token)
    try await session.wait()
    #expect(!FileManager.default.fileExists(atPath: session.socketURL.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: socketDirectory.path).isEmpty
    )
    #expect(throws: GitAskPassError.self) {
      _ = try GitAskPassClient.credential(
        prompt: "Password for 'https://x-access-token@github.com':",
        environment: environment
      )
    }
  }

  @Test("built askpass executable consumes the capability without token argv or env")
  func executableRoundTrip() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap-executable")
    defer { fixture.remove() }
    let socketDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let token = Data(repeating: 0x75, count: 32)
    let broker = GitHubBroker(
      tokenProvider: AskPassTokenProvider(token: token),
      transport: UnusedAskPassHTTPTransport(),
      readAuthority: ExplicitTestRolloutEffectAuthority()
    )
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git")
    )
    let session = try await withGitCredentialCarrier(remoteURL: remote) {
      try await broker.makeGitCredentialSession(
        remoteURL: remote,
        socketDirectory: socketDirectory,
        timeoutSeconds: 30
      )
    }
    let executable = try builtProduct(named: "JidokaCodeAskPass")
    let environment = try session.environment(
      askPassExecutable: executable,
      base: try CredentiallessEnvironment.make(
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      )
    )
    let result = try await BoundedProcessRunner().run(
      GitProcessRequest(
        executable: executable,
        arguments: ["Password for 'https://x-access-token@github.com':"],
        workingDirectory: fixture.root,
        environment: environment,
        timeoutSeconds: 30
      ))
    #expect(result.succeeded)
    #expect(result.stdout == token + Data([0x0A]))
    #expect(result.stderr.isEmpty)
    try await session.wait()
  }

  @Test("partial clients cannot hold the one-shot server past its deadline")
  func partialClientTimeout() async throws {
    let socketDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let broker = GitHubBroker(
      tokenProvider: AskPassTokenProvider(token: Data(repeating: 0x74, count: 32)),
      transport: UnusedAskPassHTTPTransport(),
      readAuthority: ExplicitTestRolloutEffectAuthority()
    )
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git")
    )
    let session = try await withGitCredentialCarrier(remoteURL: remote) {
      try await broker.makeGitCredentialSession(
        remoteURL: remote,
        socketDirectory: socketDirectory,
        timeoutSeconds: 1
      )
    }
    let descriptor = try OneShotGitCredentialServer.connect(to: session.socketURL.path)
    defer { Darwin.close(descriptor) }
    await #expect(throws: GitAskPassError.timedOut) {
      try await session.wait()
    }
    #expect(!FileManager.default.fileExists(atPath: session.socketURL.path))
  }

  @Test("wrong nonce or remote consumes the capability without releasing a token")
  func bindingFailure() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap-binding")
    defer { fixture.remove() }
    let socketDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let broker = GitHubBroker(
      tokenProvider: AskPassTokenProvider(token: Data(repeating: 0x74, count: 32)),
      transport: UnusedAskPassHTTPTransport(),
      readAuthority: ExplicitTestRolloutEffectAuthority()
    )
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git")
    )
    let session = try await withGitCredentialCarrier(remoteURL: remote) {
      try await broker.makeGitCredentialSession(
        remoteURL: remote,
        socketDirectory: socketDirectory,
        timeoutSeconds: 5
      )
    }
    var environment = [
      "JIDOKA_ASKPASS_NONCE": UUID().uuidString.lowercased(),
      "JIDOKA_ASKPASS_REMOTE": remote.absoluteString,
      "JIDOKA_ASKPASS_SOCKET": session.socketURL.path,
    ]
    #expect(throws: GitAskPassError.self) {
      _ = try GitAskPassClient.credential(
        prompt: "Password for 'https://x-access-token@github.com':",
        environment: environment
      )
    }
    await #expect(throws: GitAskPassError.credentialRejected) {
      try await session.wait()
    }

    environment["JIDOKA_ASKPASS_NONCE"] = session.nonce
    #expect(throws: GitAskPassError.self) {
      _ = try GitAskPassClient.credential(
        prompt: "Password for 'https://evil.example':",
        environment: environment
      )
    }
  }

  @Test("production-length Application Support paths fit one-shot askpass sockets")
  func productionLengthSocketPath() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap-production-path")
    defer { fixture.remove() }
    let parent = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: parent) }
    let targetDirectoryByteCount = 57
    let paddingCount = targetDirectoryByteCount - parent.path.utf8.count - 1
    guard paddingCount > 0 else {
      Issue.record("temporary socket path cannot reproduce the production boundary")
      return
    }
    let socketDirectory = parent.appendingPathComponent(
      String(repeating: "p", count: paddingCount), isDirectory: true)
    try FileManager.default.createDirectory(
      at: socketDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executable = fixture.root.appendingPathComponent("askpass")
    try writeExecutable(executable, "#!/bin/sh\nexit 0\n")
    let token = Data(repeating: 0x75, count: 32)
    let provider = try GitHubGitCredentialProvider(
      broker: GitHubBroker(
        tokenProvider: AskPassTokenProvider(token: token),
        transport: UnusedAskPassHTTPTransport(),
        readAuthority: ExplicitTestRolloutEffectAuthority()
      ),
      socketDirectory: socketDirectory,
      askPassExecutable: executable
    )
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git"))
    await #expect(throws: GitTransportError.rolloutAuthorityRequired) {
      _ = try await provider.makeSession(remoteURL: remote)
    }
    let session = try await withGitCredentialCarrier(remoteURL: remote) {
      try await provider.makeSession(remoteURL: remote)
    }
    #expect(
      session.socketURL.path.utf8.count + 1
        <= MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    )
    let environment = try session.environment(
      askPassExecutable: executable,
      base: try CredentiallessEnvironment.make(
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      )
    )
    #expect(
      try GitAskPassClient.credential(
        prompt: "Password for 'https://x-access-token@github.com':",
        environment: environment
      ) == token
    )
    try await session.wait()
  }

  @Test("occupied socket names are preserved while a fresh name is bound")
  func occupiedSocketNameRetriesWithoutUnlink() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap-collision")
    defer { fixture.remove() }
    let socketDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let occupiedID = String(repeating: "a", count: 32)
    let availableID = String(repeating: "b", count: 32)
    let occupiedURL = socketDirectory.appendingPathComponent("a-\(occupiedID).s")
    let occupiedContents = Data("occupied".utf8)
    try occupiedContents.write(to: occupiedURL, options: .withoutOverwriting)
    let executable = fixture.root.appendingPathComponent("askpass")
    try writeExecutable(executable, "#!/bin/sh\nexit 0\n")
    let token = Data(repeating: 0x75, count: 32)
    let remote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git"))
    let socketIDs = SocketIDSequence([occupiedID, availableID])
    let session = try OneShotGitCredentialServer.start(
      token: token,
      remoteURL: remote,
      socketDirectory: socketDirectory,
      timeoutSeconds: 5,
      now: Date(),
      socketIDGenerator: { socketIDs.next() }
    )
    #expect(session.socketURL.lastPathComponent == "a-\(availableID).s")
    #expect(try Data(contentsOf: occupiedURL) == occupiedContents)
    let environment = try session.environment(
      askPassExecutable: executable,
      base: try CredentiallessEnvironment.make(
        homeDirectory: fixture.root.path,
        temporaryDirectory: fixture.root.path
      )
    )
    #expect(
      try GitAskPassClient.credential(
        prompt: "Password for 'https://x-access-token@github.com':",
        environment: environment
      ) == token
    )
    try await session.wait()
    #expect(try Data(contentsOf: occupiedURL) == occupiedContents)
    #expect(!FileManager.default.fileExists(atPath: session.socketURL.path))
  }

  @Test("unsafe socket directories and remote identities fail before token release")
  func unsafeInputs() async throws {
    let fixture = try GitTestRoot(prefix: "jc-ap-unsafe")
    defer { fixture.remove() }
    let unsafeDirectory = try makeShortSocketDirectory(mode: 0o755)
    defer { try? FileManager.default.removeItem(at: unsafeDirectory) }
    let broker = GitHubBroker(
      tokenProvider: AskPassTokenProvider(token: Data(repeating: 0x74, count: 32)),
      transport: UnusedAskPassHTTPTransport(),
      readAuthority: ExplicitTestRolloutEffectAuthority()
    )
    let validRemote = try #require(
      URL(string: "https://x-access-token@github.com/owner/repo.git")
    )
    await #expect(throws: GitAskPassError.unsafeDirectory) {
      _ = try await withGitCredentialCarrier(remoteURL: validRemote) {
        try await broker.makeGitCredentialSession(
          remoteURL: validRemote,
          socketDirectory: unsafeDirectory
        )
      }
    }
    let safeDirectory = try makeShortSocketDirectory(mode: 0o700)
    defer { try? FileManager.default.removeItem(at: safeDirectory) }
    let invalidRemote = try #require(
      URL(string: "https://x-access-token@example.com/owner/repo.git")
    )
    await #expect(throws: GitAskPassError.invalidRemote) {
      _ = try await withGitCredentialCarrier(remoteURL: invalidRemote) {
        try await broker.makeGitCredentialSession(
          remoteURL: invalidRemote,
          socketDirectory: safeDirectory
        )
      }
    }
  }
}

private func withGitCredentialCarrier<Value: Sendable>(
  remoteURL: URL,
  operation: () async throws -> Value
) async rethrows -> Value {
  try await RolloutGitCredentialTaskContext.$remoteURL.withValue(
    remoteURL.absoluteString,
    operation: operation
  )
}

private final class SocketIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.removeFirst()
  }
}

private func makeShortSocketDirectory(mode: Int) throws -> URL {
  let suffix = UUID().uuidString.prefix(8).lowercased()
  let directory = URL(fileURLWithPath: "/tmp/jc-ap-\(suffix)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: mode]
  )
  return directory
}

private struct AskPassTokenProvider: GitHubTokenProviding {
  let token: Data

  func token() async throws -> Data { token }
}

private struct UnusedAskPassHTTPTransport: GitHubHTTPTransport {
  func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
    throw URLError(.unsupportedURL)
  }
}
