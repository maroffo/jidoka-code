import Darwin
import Foundation

public enum GitAskPassError: Error, Equatable, Sendable {
  case unsafeDirectory
  case invalidRemote
  case invalidNonce
  case invalidTimeout
  case socketPathTooLong
  case socketFailure(Int32)
  case timedOut
  case invalidRequest
  case credentialRejected
  case responseTooLarge
  case incompleteWrite
  case unsafeEnvironment
}

public final class OneShotGitCredentialSession: @unchecked Sendable {
  public let socketURL: URL
  public let nonce: String
  public let remoteURL: URL
  public let expiresAt: Date

  private let task: Task<Void, Error>

  fileprivate init(
    socketURL: URL,
    nonce: String,
    remoteURL: URL,
    expiresAt: Date,
    task: Task<Void, Error>
  ) {
    self.socketURL = socketURL
    self.nonce = nonce
    self.remoteURL = remoteURL
    self.expiresAt = expiresAt
    self.task = task
  }

  deinit {
    task.cancel()
  }

  public func environment(
    askPassExecutable: URL,
    base: [String: String]
  ) throws -> [String: String] {
    let values = try askPassExecutable.resourceValues(forKeys: [
      .isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard askPassExecutable.isFileURL, askPassExecutable.path.hasPrefix("/"),
      values.isExecutable == true, values.isRegularFile == true,
      values.isSymbolicLink != true,
      base["GH_TOKEN"] == nil, base["GITHUB_TOKEN"] == nil,
      base["SSH_AUTH_SOCK"] == nil, base["GIT_TERMINAL_PROMPT"] == "0"
    else {
      throw GitAskPassError.unsafeEnvironment
    }
    var environment = base
    environment["GIT_ASKPASS"] = askPassExecutable.path
    environment["GIT_ASKPASS_REQUIRE"] = "force"
    environment["JIDOKA_ASKPASS_NONCE"] = nonce
    environment["JIDOKA_ASKPASS_REMOTE"] = remoteURL.absoluteString
    environment["JIDOKA_ASKPASS_SOCKET"] = socketURL.path
    return environment
  }

  public func wait() async throws {
    try await task.value
  }

  public func invalidate() async {
    task.cancel()
    _ = try? await task.value
  }
}

private final class MutableCredential: @unchecked Sendable {
  var bytes: Data

  init(_ bytes: Data) {
    self.bytes = bytes.withUnsafeBytes { Data($0) }
  }

  func zero() {
    let byteCount = bytes.count
    bytes.resetBytes(in: 0..<byteCount)
  }
}

enum OneShotGitCredentialServer {
  static func start(
    token: Data,
    remoteURL: URL,
    socketDirectory: URL,
    timeoutSeconds: TimeInterval,
    now: Date
  ) throws -> OneShotGitCredentialSession {
    guard validRemote(remoteURL) else { throw GitAskPassError.invalidRemote }
    guard timeoutSeconds.isFinite, (1...60).contains(timeoutSeconds) else {
      throw GitAskPassError.invalidTimeout
    }
    try validateDirectory(socketDirectory)
    let nonce = UUID().uuidString.lowercased()
    let socketURL = socketDirectory.appendingPathComponent(
      "askpass-\(UUID().uuidString.lowercased()).sock"
    )
    let listener = try makeListener(at: socketURL)
    let expiresAt = now.addingTimeInterval(timeoutSeconds)
    let credential = MutableCredential(token)
    let task = Task.detached(priority: .userInitiated) {
      defer {
        credential.zero()
        Darwin.close(listener)
        _ = Darwin.unlink(socketURL.path)
      }
      try serveOnce(
        listener: listener,
        socketURL: socketURL,
        nonce: nonce,
        remoteURL: remoteURL,
        token: credential.bytes,
        timeoutSeconds: timeoutSeconds
      )
    }
    return OneShotGitCredentialSession(
      socketURL: socketURL,
      nonce: nonce,
      remoteURL: remoteURL,
      expiresAt: expiresAt,
      task: task
    )
  }

  private static func serveOnce(
    listener: Int32,
    socketURL: URL,
    nonce: String,
    remoteURL: URL,
    token: Data,
    timeoutSeconds: TimeInterval
  ) throws {
    let deadline = monotonicSeconds() + timeoutSeconds
    while true {
      if Task.isCancelled { throw CancellationError() }
      let remaining = deadline - monotonicSeconds()
      guard remaining > 0 else { throw GitAskPassError.timedOut }
      var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000, 100)))
      if status == -1 {
        if errno == EINTR { continue }
        throw GitAskPassError.socketFailure(errno)
      }
      if status == 0 { continue }
      let connection = Darwin.accept(listener, nil, nil)
      guard connection >= 0 else {
        if errno == EINTR { continue }
        throw GitAskPassError.socketFailure(errno)
      }
      defer { Darwin.close(connection) }
      let requestData = try readLine(
        connection,
        maximumBytes: 4_096,
        deadline: deadline
      )
      let request: AskPassRequest
      do {
        request = try JSONDecoder().decode(AskPassRequest.self, from: requestData)
      } catch {
        throw GitAskPassError.invalidRequest
      }
      guard request.nonce == nonce,
        request.remote == remoteURL.absoluteString,
        validPrompt(request.prompt, remoteURL: remoteURL),
        socketURL.path.hasSuffix(".sock")
      else {
        throw GitAskPassError.credentialRejected
      }
      var response = token
      response.append(0x0A)
      let responseCount = response.count
      defer { response.resetBytes(in: 0..<responseCount) }
      try writeAll(connection, data: response)
      return
    }
  }

  private static func validPrompt(_ prompt: String, remoteURL: URL) -> Bool {
    guard prompt.utf8.count <= 2_048, !prompt.contains("\u{0}"),
      let host = remoteURL.host
    else {
      return false
    }
    let lowered = prompt.lowercased()
    return lowered.contains("password") && lowered.contains(host.lowercased())
  }

  private static func validRemote(_ url: URL) -> Bool {
    guard url.scheme == "https", url.host == "github.com",
      url.user == "x-access-token", url.password == nil,
      url.query == nil, url.fragment == nil, url.port == nil
    else {
      return false
    }
    let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 2,
      GitHubInputValidation.validOwner(String(components[0]))
    else {
      return false
    }
    let repository = String(components[1]).replacingOccurrences(of: ".git", with: "")
    return GitHubInputValidation.validRepository(repository)
      && components[1] == Substring("\(repository).git")
  }

  private static func validateDirectory(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw GitAskPassError.unsafeDirectory
    }
    var value = stat()
    guard lstat(url.path, &value) == 0,
      (value.st_mode & S_IFMT) == S_IFDIR,
      (value.st_mode & 0o077) == 0,
      value.st_uid == geteuid()
    else {
      throw GitAskPassError.unsafeDirectory
    }
  }

  private static func makeListener(at socketURL: URL) throws -> Int32 {
    let pathBytes = Array(socketURL.path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !pathBytes.isEmpty, pathBytes.count + 1 <= capacity else {
      throw GitAskPassError.socketPathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
    }
    _ = Darwin.unlink(socketURL.path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw GitAskPassError.socketFailure(errno) }
    var ownsDescriptor = true
    defer {
      if ownsDescriptor { Darwin.close(descriptor) }
    }
    let bindStatus = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindStatus == 0 else { throw GitAskPassError.socketFailure(errno) }
    guard Darwin.chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
      throw GitAskPassError.socketFailure(errno)
    }
    guard Darwin.listen(descriptor, 1) == 0 else {
      throw GitAskPassError.socketFailure(errno)
    }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    ownsDescriptor = false
    return descriptor
  }

  private static func readLine(
    _ descriptor: Int32,
    maximumBytes: Int,
    deadline: TimeInterval
  ) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count <= maximumBytes {
      if Task.isCancelled { throw CancellationError() }
      let remaining = deadline - monotonicSeconds()
      guard remaining > 0 else { throw GitAskPassError.timedOut }
      var polled = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let status = Darwin.poll(&polled, 1, Int32(min(remaining * 1_000, 100)))
      if status == -1 {
        if errno == EINTR { continue }
        throw GitAskPassError.socketFailure(errno)
      }
      if status == 0 { continue }
      let count = Darwin.read(descriptor, &byte, 1)
      if count == 1 {
        if byte == 0x0A { return data }
        data.append(byte)
        continue
      }
      if count == 0 { throw GitAskPassError.invalidRequest }
      if errno == EINTR { continue }
      throw GitAskPassError.socketFailure(errno)
    }
    throw GitAskPassError.responseTooLarge
  }

  fileprivate static func writeAll(_ descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count == -1 {
          if errno == EINTR { continue }
          throw GitAskPassError.socketFailure(errno)
        }
        guard count > 0 else { throw GitAskPassError.incompleteWrite }
        offset += count
      }
    }
  }

  static func connect(to socketPath: String) throws -> Int32 {
    let pathBytes = Array(socketPath.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !pathBytes.isEmpty, pathBytes.count + 1 <= capacity else {
      throw GitAskPassError.socketPathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw GitAskPassError.socketFailure(errno) }
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard status == 0 else {
      let error = errno
      Darwin.close(descriptor)
      throw GitAskPassError.socketFailure(error)
    }
    return descriptor
  }

  fileprivate static func readResponse(
    _ descriptor: Int32,
    maximumBytes: Int
  ) throws -> Data {
    try readLine(
      descriptor,
      maximumBytes: maximumBytes,
      deadline: monotonicSeconds() + 5
    )
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }
}

private struct AskPassRequest: Codable, Sendable {
  let nonce: String
  let remote: String
  let prompt: String
}

public enum GitAskPassClient {
  public static func credential(
    prompt: String,
    environment: [String: String]
  ) throws -> Data {
    guard let nonce = environment["JIDOKA_ASKPASS_NONCE"],
      let remote = environment["JIDOKA_ASKPASS_REMOTE"],
      let socketPath = environment["JIDOKA_ASKPASS_SOCKET"],
      UUID(uuidString: nonce) != nil,
      let remoteURL = URL(string: remote),
      remoteURL.absoluteString == remote,
      socketPath.hasPrefix("/"), !socketPath.contains("\u{0}")
    else {
      throw GitAskPassError.invalidRequest
    }
    let request = AskPassRequest(nonce: nonce, remote: remote, prompt: prompt)
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    let descriptor = try OneShotGitCredentialServer.connect(to: socketPath)
    defer { Darwin.close(descriptor) }
    try OneShotGitCredentialServer.writeAll(descriptor, data: data)
    let credential = try OneShotGitCredentialServer.readResponse(
      descriptor,
      maximumBytes: 2_048
    )
    guard (20...2_048).contains(credential.count),
      credential.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw GitAskPassError.credentialRejected
    }
    return credential
  }
}
