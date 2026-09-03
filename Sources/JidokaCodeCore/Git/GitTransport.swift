import Darwin
import Foundation

public struct GitRemoteRepository: Equatable, Sendable {
  public let repositoryID: UUID
  public let nodeID: String
  public let owner: String
  public let name: String
  public let defaultBranch: String
  public let url: URL
  public let requiresCredential: Bool

  public init(repository: RepositoryConfiguration) throws {
    guard GitHubInputValidation.validOwner(repository.owner),
      GitHubInputValidation.validRepository(repository.name),
      GitHubInputValidation.validBranch(repository.defaultBranch),
      !repository.nodeID.isEmpty,
      let url = URL(
        string: "https://x-access-token@github.com/\(repository.owner)/\(repository.name).git"
      )
    else {
      throw GitTransportError.invalidRemote
    }
    repositoryID = repository.id
    nodeID = repository.nodeID
    owner = repository.owner
    name = repository.name
    defaultBranch = repository.defaultBranch
    self.url = url
    requiresCredential = true
  }

  init(
    repositoryID: UUID,
    nodeID: String,
    owner: String,
    name: String,
    defaultBranch: String,
    localFixtureURL: URL
  ) throws {
    guard localFixtureURL.isFileURL, localFixtureURL.path.hasPrefix("/"),
      GitHubInputValidation.validOwner(owner),
      GitHubInputValidation.validRepository(name),
      GitHubInputValidation.validBranch(defaultBranch),
      !nodeID.isEmpty
    else {
      throw GitTransportError.invalidRemote
    }
    self.repositoryID = repositoryID
    self.nodeID = nodeID
    self.owner = owner
    self.name = name
    self.defaultBranch = defaultBranch
    url = localFixtureURL.standardizedFileURL
    requiresCredential = false
  }
}

public enum GitTransportError: Error, Equatable, Sendable {
  case invalidRemote
  case credentialRequired
  case commandFailed(exitCode: Int32?, stderrSHA256: String)
  case malformedOutput
  case exactSHAMismatch
  case unsafeReference
  case unsafePushGuard
  case forceClassArgument
  case createOnlyPacketMissing
}

public protocol GitCredentialSessionProviding: Sendable {
  func makeSession(remoteURL: URL) async throws -> OneShotGitCredentialSession
  var askPassExecutable: URL { get }
}

public actor GitHubGitCredentialProvider: GitCredentialSessionProviding {
  public nonisolated let askPassExecutable: URL
  private let broker: GitHubBroker
  private let socketDirectory: URL

  public init(
    broker: GitHubBroker,
    socketDirectory: URL,
    askPassExecutable: URL
  ) throws {
    guard socketDirectory.isFileURL, socketDirectory.path.hasPrefix("/"),
      askPassExecutable.isFileURL, askPassExecutable.path.hasPrefix("/")
    else {
      throw GitAskPassError.unsafeDirectory
    }
    let executableValues = try askPassExecutable.resourceValues(forKeys: [
      .isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard executableValues.isExecutable == true,
      executableValues.isRegularFile == true,
      executableValues.isSymbolicLink != true
    else {
      throw GitAskPassError.credentialRejected
    }
    if FileManager.default.fileExists(atPath: socketDirectory.path) {
      var existing = stat()
      guard lstat(socketDirectory.path, &existing) == 0,
        (existing.st_mode & S_IFMT) == S_IFDIR,
        existing.st_uid == geteuid()
      else {
        throw GitAskPassError.unsafeDirectory
      }
    } else {
      try FileManager.default.createDirectory(
        at: socketDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: socketDirectory.path
    )
    var directory = stat()
    let address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let socketNameBytes = "/a-".utf8.count + 32 + ".s".utf8.count
    guard lstat(socketDirectory.path, &directory) == 0,
      (directory.st_mode & S_IFMT) == S_IFDIR,
      (directory.st_mode & 0o077) == 0,
      directory.st_uid == geteuid(),
      socketDirectory.path.utf8.count + socketNameBytes + 1 <= pathCapacity
    else {
      throw GitAskPassError.unsafeDirectory
    }
    self.broker = broker
    self.socketDirectory = socketDirectory
    self.askPassExecutable = askPassExecutable
  }

  public func makeSession(remoteURL: URL) async throws -> OneShotGitCredentialSession {
    try await broker.makeGitCredentialSession(
      remoteURL: remoteURL,
      socketDirectory: socketDirectory
    )
  }
}

public protocol GitRepositoryTransporting: Sendable {
  func cloneMirror(
    remote: GitRemoteRepository,
    destination: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws
  func fetchMirror(
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws
  func fetchPullRequest(
    number: Int,
    expectedSHA: String,
    jobID: UUID,
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String
}

public protocol GitLocalCommanding: Sendable {
  func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String]
  ) async throws -> GitProcessResult
}

public protocol GitPublicationTransporting: Sendable {
  func containsLocalCommit(_ exactSHA: String, repository: URL) async throws -> Bool
  func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String?
  func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> GitProcessResult
}

public actor SystemGitTransport: GitRepositoryTransporting, GitLocalCommanding,
  GitPublicationTransporting
{
  public static let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")

  public static var packagedPushGuardExecutable: URL {
    Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/GitHooks/pre-push",
      isDirectory: false
    )
  }

  private let runner: any GitProcessExecuting
  private let developerDirectory: String
  private let homeDirectory: String
  private let temporaryDirectory: String
  private let pushGuardExecutable: URL

  public init(
    runner: any GitProcessExecuting = BoundedProcessRunner(),
    developerDirectory: String = CredentiallessEnvironment.lockedDeveloperDirectory,
    homeDirectory: String = "/var/empty",
    temporaryDirectory: String = NSTemporaryDirectory(),
    pushGuardExecutable: URL = SystemGitTransport.packagedPushGuardExecutable
  ) {
    self.runner = runner
    self.developerDirectory = developerDirectory
    self.homeDirectory = homeDirectory
    self.temporaryDirectory = temporaryDirectory
    self.pushGuardExecutable = pushGuardExecutable
  }

  public func cloneMirror(
    remote: GitRemoteRepository,
    destination: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws {
    let result = try await runGit(
      arguments: ["clone", "--mirror", "--", remote.url.absoluteString, destination.path],
      workingDirectory: destination.deletingLastPathComponent(),
      remote: remote,
      credentials: credentials,
      timeoutSeconds: 300
    )
    try requireSuccess(result)
  }

  public func fetchMirror(
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws {
    let result = try await runGit(
      arguments: [
        "--git-dir", mirror.path,
        "fetch", "--prune", "--no-tags", "origin",
        "+refs/heads/*:refs/heads/*",
      ],
      workingDirectory: mirror.deletingLastPathComponent(),
      remote: remote,
      credentials: credentials,
      timeoutSeconds: 300
    )
    try requireSuccess(result)
  }

  public func fetchPullRequest(
    number: Int,
    expectedSHA: String,
    jobID: UUID,
    remote: GitRemoteRepository,
    mirror: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String {
    guard number > 0, GitHubInputValidation.validGitSHA(expectedSHA) else {
      throw GitTransportError.unsafeReference
    }
    let localReference = "refs/jidoka/reviews/\(jobID.uuidString.lowercased())"
    let result = try await runGit(
      arguments: [
        "--git-dir", mirror.path,
        "fetch", "--no-tags", "origin",
        "refs/pull/\(number)/head:\(localReference)",
      ],
      workingDirectory: mirror.deletingLastPathComponent(),
      remote: remote,
      credentials: credentials,
      timeoutSeconds: 300
    )
    try requireSuccess(result)
    let observed = try await localRevision(reference: localReference, repository: mirror)
    guard observed == expectedSHA else { throw GitTransportError.exactSHAMismatch }
    return observed
  }

  public func containsLocalCommit(
    _ exactSHA: String,
    repository: URL
  ) async throws -> Bool {
    guard GitHubInputValidation.validGitSHA(exactSHA) else {
      throw GitTransportError.unsafeReference
    }
    let result = try await runLocalGit(
      arguments: ["-C", repository.path, "cat-file", "-e", "\(exactSHA)^{commit}"],
      workingDirectory: repository,
      timeoutSeconds: 30,
      maximumOutputBytes: 1_048_576,
      environmentOverrides: [:]
    )
    if result.succeeded { return true }
    if result.exitCode != nil, result.terminationSignal == nil,
      !result.timedOut, !result.outputLimitExceeded
    {
      return false
    }
    throw GitTransportError.commandFailed(
      exitCode: result.exitCode,
      stderrSHA256: result.stderrSHA256
    )
  }

  public func readRemoteRef(
    _ reference: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> String? {
    guard Self.validRemoteReference(reference) else {
      throw GitTransportError.unsafeReference
    }
    let result = try await runGit(
      arguments: [
        "-C", repository.path, "ls-remote", "--refs", remote.url.absoluteString, reference,
      ],
      workingDirectory: repository,
      remote: remote,
      credentials: credentials,
      timeoutSeconds: 120
    )
    try requireSuccess(result)
    guard let output = String(data: result.stdout, encoding: .utf8) else {
      throw GitTransportError.malformedOutput
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    if lines.isEmpty { return nil }
    guard lines.count == 1 else { throw GitTransportError.malformedOutput }
    let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 2, fields[1] == Substring(reference) else {
      throw GitTransportError.malformedOutput
    }
    let sha = String(fields[0])
    guard GitHubInputValidation.validGitSHA(sha) else {
      throw GitTransportError.malformedOutput
    }
    return sha
  }

  public func createRemoteRef(
    _ reference: String,
    exactSHA: String,
    remote: GitRemoteRepository,
    repository: URL,
    credentials: (any GitCredentialSessionProviding)?
  ) async throws -> GitProcessResult {
    guard Self.validRemoteReference(reference),
      GitHubInputValidation.validGitSHA(exactSHA)
    else {
      throw GitTransportError.unsafeReference
    }
    let hooksDirectory = try validatedPushGuardDirectory()
    let arguments = [
      "-C", repository.path,
      "-c", "credential.helper=",
      "-c", "core.hooksPath=\(hooksDirectory.path)",
      "push", "--porcelain", "--", remote.url.absoluteString,
      "\(exactSHA):\(reference)",
    ]
    guard !Self.containsForceClassArgument(arguments) else {
      throw GitTransportError.forceClassArgument
    }
    let result = try await runGit(
      arguments: arguments,
      workingDirectory: repository,
      remote: remote,
      credentials: credentials,
      timeoutSeconds: 300,
      environmentOverrides: [
        "GIT_TRACE_PACKET": "1",
        "JIDOKA_PUSH_GUARD_REFERENCE": reference,
        "JIDOKA_PUSH_GUARD_REMOTE": remote.url.absoluteString,
        "JIDOKA_PUSH_GUARD_SHA": exactSHA,
      ]
    )
    let zero = String(repeating: "0", count: exactSHA.count)
    let trace = String(data: result.stderr, encoding: .utf8) ?? ""
    guard trace.contains("\(zero) \(exactSHA) \(reference)") else {
      throw GitTransportError.createOnlyPacketMissing
    }
    return result
  }

  public func localRevision(reference: String, repository: URL) async throws -> String {
    guard Self.validLocalReference(reference) else {
      throw GitTransportError.unsafeReference
    }
    let result = try await runLocalGit(
      arguments: ["--git-dir", repository.path, "rev-parse", "--verify", reference],
      workingDirectory: repository.deletingLastPathComponent(),
      timeoutSeconds: 30
    )
    try requireSuccess(result)
    guard
      let value = String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      GitHubInputValidation.validGitSHA(value)
    else {
      throw GitTransportError.malformedOutput
    }
    return value
  }

  public func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval = 120,
    maximumOutputBytes: Int = 1_048_576,
    environmentOverrides: [String: String] = [:]
  ) async throws -> GitProcessResult {
    guard !arguments.contains(where: { $0.lowercased().contains("force") }) else {
      throw GitTransportError.forceClassArgument
    }
    let environment = try CredentiallessEnvironment.make(
      developerDirectory: developerDirectory,
      homeDirectory: homeDirectory,
      temporaryDirectory: temporaryDirectory,
      overrides: environmentOverrides
    )
    return try await runner.run(
      GitProcessRequest(
        executable: Self.gitExecutable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutSeconds: timeoutSeconds,
        maximumOutputBytes: maximumOutputBytes
      ))
  }

  private func runGit(
    arguments: [String],
    workingDirectory: URL,
    remote: GitRemoteRepository,
    credentials: (any GitCredentialSessionProviding)?,
    timeoutSeconds: TimeInterval,
    environmentOverrides: [String: String] = [:]
  ) async throws -> GitProcessResult {
    var environment = try CredentiallessEnvironment.make(
      developerDirectory: developerDirectory,
      homeDirectory: homeDirectory,
      temporaryDirectory: temporaryDirectory,
      overrides: environmentOverrides
    )
    var session: OneShotGitCredentialSession?
    if remote.requiresCredential {
      guard let credentials else { throw GitTransportError.credentialRequired }
      let created = try await credentials.makeSession(remoteURL: remote.url)
      environment = try created.environment(
        askPassExecutable: credentials.askPassExecutable,
        base: environment
      )
      session = created
    }
    do {
      let result = try await runner.run(
        GitProcessRequest(
          executable: Self.gitExecutable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          timeoutSeconds: timeoutSeconds,
          maximumOutputBytes: 8 * 1_024 * 1_024
        ))
      if let session { await session.invalidate() }
      return result
    } catch {
      if let session { await session.invalidate() }
      throw error
    }
  }

  private func requireSuccess(_ result: GitProcessResult) throws {
    guard result.succeeded else {
      throw GitTransportError.commandFailed(
        exitCode: result.exitCode,
        stderrSHA256: result.stderrSHA256
      )
    }
  }

  private func validatedPushGuardDirectory() throws -> URL {
    guard pushGuardExecutable.isFileURL,
      pushGuardExecutable.lastPathComponent == "pre-push"
    else {
      throw GitTransportError.unsafePushGuard
    }
    let executableValues = try pushGuardExecutable.resourceValues(forKeys: [
      .isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    let directory = pushGuardExecutable.deletingLastPathComponent()
    let directoryValues = try directory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    var executableStatus = stat()
    var directoryStatus = stat()
    guard executableValues.isExecutable == true,
      executableValues.isRegularFile == true,
      executableValues.isSymbolicLink != true,
      directoryValues.isDirectory == true,
      directoryValues.isSymbolicLink != true,
      lstat(pushGuardExecutable.path, &executableStatus) == 0,
      lstat(directory.path, &directoryStatus) == 0,
      (executableStatus.st_mode & S_IFMT) == S_IFREG,
      (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
      (executableStatus.st_mode & 0o022) == 0,
      (directoryStatus.st_mode & 0o022) == 0,
      [uid_t(0), geteuid()].contains(executableStatus.st_uid),
      [uid_t(0), geteuid()].contains(directoryStatus.st_uid)
    else {
      throw GitTransportError.unsafePushGuard
    }
    return directory
  }

  private static func containsForceClassArgument(_ arguments: [String]) -> Bool {
    arguments.contains { value in
      let lowered = value.lowercased()
      return lowered == "-f" || lowered == "--force"
        || lowered.hasPrefix("--force-with-lease")
        || lowered.hasPrefix("--force-if-includes")
        || value.hasPrefix("+")
    }
  }

  private static func validRemoteReference(_ value: String) -> Bool {
    guard value.hasPrefix("refs/heads/") else { return false }
    return GitHubInputValidation.validBranch(String(value.dropFirst("refs/heads/".count)))
  }

  private static func validLocalReference(_ value: String) -> Bool {
    guard value.utf8.count <= 512, !value.contains(".."), !value.contains("@{") else {
      return false
    }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._")
    return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
  }
}
