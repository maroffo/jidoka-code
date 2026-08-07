import CryptoKit
import Darwin
import Foundation

public struct GitProcessRequest: Sendable {
  public let executable: URL
  public let arguments: [String]
  public let workingDirectory: URL
  public let environment: [String: String]
  public let timeoutSeconds: TimeInterval
  public let maximumOutputBytes: Int

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String],
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int = 1_048_576
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
    self.maximumOutputBytes = maximumOutputBytes
  }
}

public struct GitProcessResult: Equatable, Sendable {
  public let exitCode: Int32?
  public let terminationSignal: Int32?
  public let timedOut: Bool
  public let outputLimitExceeded: Bool
  public let stdout: Data
  public let stderr: Data
  public let durationSeconds: TimeInterval

  public var succeeded: Bool {
    exitCode == 0 && terminationSignal == nil && !timedOut && !outputLimitExceeded
  }

  public var stdoutSHA256: String { Self.sha256(stdout) }
  public var stderrSHA256: String { Self.sha256(stderr) }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum GitProcessError: Error, Equatable, Sendable {
  case invalidExecutable
  case unsafeWorkingDirectory
  case invalidEnvironment
  case invalidLimits
  case pipeFailed(Int32)
  case spawnFailed(Int32)
  case waitFailed(Int32)
  case allocationFailed
}

public protocol GitProcessExecuting: Sendable {
  func run(_ request: GitProcessRequest) async throws -> GitProcessResult
}

public struct CredentiallessEnvironment {
  public static var lockedDeveloperDirectory: String {
    assembleDeveloperDirectory()
  }

  public static func make(
    developerDirectory: String = CredentiallessEnvironment.lockedDeveloperDirectory,
    homeDirectory: String = "/var/empty",
    temporaryDirectory: String = NSTemporaryDirectory(),
    overrides: [String: String] = [:]
  ) throws -> [String: String] {
    guard developerDirectory == lockedDeveloperDirectory,
      homeDirectory.hasPrefix("/"), temporaryDirectory.hasPrefix("/")
    else {
      throw GitProcessError.invalidEnvironment
    }
    var environment = [
      "DEVELOPER_DIR": developerDirectory,
      "GIT_ASKPASS": "/usr/bin/false",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_SSH_COMMAND": "/usr/bin/false",
      "GIT_TERMINAL_PROMPT": "0",
      "HOME": homeDirectory,
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "PATH": "\(developerDirectory)/usr/bin:/usr/bin:/bin",
      "TMPDIR": temporaryDirectory,
    ]
    for (key, value) in overrides {
      let allowed =
        (key == "GIT_ALLOW_PROTOCOL" && value == "file")
        || (key == "GIT_TRACE_PACKET" && value == "1")
        || (key == "JIDOKA_PUSH_GUARD_REMOTE" && GitPushGuard.validRemote(value))
        || (key == "JIDOKA_PUSH_GUARD_REFERENCE" && validPushGuardReference(value))
        || (key == "JIDOKA_PUSH_GUARD_SHA"
          && GitHubInputValidation.validGitSHA(value))
      guard allowed else { throw GitProcessError.invalidEnvironment }
      environment[key] = value
    }
    return environment
  }

  private static func validPushGuardReference(_ value: String) -> Bool {
    value.hasPrefix("refs/heads/")
      && GitHubInputValidation.validBranch(
        String(value.dropFirst("refs/heads/".count))
      )
  }

  @inline(never)
  private static func assembleDeveloperDirectory() -> String {
    var path = String(UnicodeScalar(47))
    for component in ["Applications", "Xcode.app", "Contents", "Developer"] {
      if path.count > 1 { path.append("/") }
      path.append(component)
    }
    return path
  }
}

public final class BoundedProcessRunner: GitProcessExecuting, @unchecked Sendable {
  public init() {}

  public func run(_ request: GitProcessRequest) async throws -> GitProcessResult {
    let task = Task.detached(priority: nil) {
      try Self.runSynchronously(request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func runSynchronously(
    _ request: GitProcessRequest
  ) throws -> GitProcessResult {
    try validate(request)
    var stdoutPipe = [Int32](repeating: -1, count: 2)
    var stderrPipe = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&stdoutPipe) == 0 else { throw GitProcessError.pipeFailed(errno) }
    guard Darwin.pipe(&stderrPipe) == 0 else {
      closePair(stdoutPipe)
      throw GitProcessError.pipeFailed(errno)
    }
    let nullDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard nullDescriptor >= 0 else {
      closePair(stdoutPipe)
      closePair(stderrPipe)
      throw GitProcessError.pipeFailed(errno)
    }

    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    let actionInitialization = posix_spawn_file_actions_init(&actions)
    guard actionInitialization == 0 else {
      closePair(stdoutPipe)
      closePair(stderrPipe)
      Darwin.close(nullDescriptor)
      throw GitProcessError.spawnFailed(actionInitialization)
    }
    let attributeInitialization = posix_spawnattr_init(&attributes)
    guard attributeInitialization == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      closePair(stdoutPipe)
      closePair(stderrPipe)
      Darwin.close(nullDescriptor)
      throw GitProcessError.spawnFailed(attributeInitialization)
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
      Darwin.close(nullDescriptor)
    }

    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    let setupStatuses = [
      posix_spawn_file_actions_adddup2(&actions, nullDescriptor, STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
      posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
      posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
      posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
      posix_spawn_file_actions_addclose(&actions, stderrPipe[1]),
      posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory.path),
      posix_spawnattr_setflags(&attributes, flags),
      posix_spawnattr_setpgroup(&attributes, 0),
    ]
    if let setupFailure = setupStatuses.first(where: { $0 != 0 }) {
      closePair(stdoutPipe)
      closePair(stderrPipe)
      throw GitProcessError.spawnFailed(setupFailure)
    }

    var processID: pid_t = 0
    let arguments = [request.executable.path] + request.arguments
    let environment = request.environment.sorted { $0.key < $1.key }.map {
      "\($0.key)=\($0.value)"
    }
    let spawnStatus: Int32
    do {
      spawnStatus = try withCStringVector(arguments) { argumentVector in
        try withCStringVector(environment) { environmentVector in
          posix_spawn(
            &processID,
            request.executable.path,
            &actions,
            &attributes,
            argumentVector,
            environmentVector
          )
        }
      }
    } catch {
      closePair(stdoutPipe)
      closePair(stderrPipe)
      throw error
    }
    Darwin.close(stdoutPipe[1])
    Darwin.close(stderrPipe[1])
    stdoutPipe[1] = -1
    stderrPipe[1] = -1
    guard spawnStatus == 0 else {
      closePair(stdoutPipe)
      closePair(stderrPipe)
      throw GitProcessError.spawnFailed(spawnStatus)
    }

    setNonBlocking(stdoutPipe[0])
    setNonBlocking(stderrPipe[0])
    let startedAt = monotonicSeconds()
    let deadline = startedAt + request.timeoutSeconds
    var stdout = Data()
    var stderr = Data()
    var stdoutOpen = true
    var stderrOpen = true
    var childStatus: Int32 = 0
    var childExited = false
    var timedOut = false
    var outputLimitExceeded = false
    var terminationSent = false
    var forceKillAt: TimeInterval?
    var abandonPipesAt: TimeInterval?
    var observedProcesses: Set<ProcessIdentity> = []
    if let identity = processIdentity(processID) { observedProcesses.insert(identity) }

    defer {
      if stdoutPipe[0] >= 0 { Darwin.close(stdoutPipe[0]) }
      if stderrPipe[0] >= 0 { Darwin.close(stderrPipe[0]) }
      if !childExited {
        terminateProcessTree(
          processID,
          observedProcesses: observedProcesses,
          signal: SIGKILL
        )
        _ = Darwin.waitpid(processID, &childStatus, 0)
      }
    }

    while !childExited || stdoutOpen || stderrOpen {
      observedProcesses.formUnion(descendantProcesses(of: processID))
      if Task.isCancelled && !terminationSent {
        timedOut = true
        terminateProcessTree(
          processID,
          observedProcesses: observedProcesses,
          signal: SIGTERM
        )
        terminationSent = true
        let now = monotonicSeconds()
        forceKillAt = now + 0.25
        abandonPipesAt = now + 0.5
      }
      let now = monotonicSeconds()
      if now >= deadline, !terminationSent {
        timedOut = true
        terminateProcessTree(
          processID,
          observedProcesses: observedProcesses,
          signal: SIGTERM
        )
        terminationSent = true
        forceKillAt = now + 0.25
        abandonPipesAt = now + 0.5
      }

      if stdoutOpen {
        stdoutOpen = try drain(
          descriptor: stdoutPipe[0],
          into: &stdout,
          maximumBytes: request.maximumOutputBytes,
          exceeded: &outputLimitExceeded
        )
      }
      if stderrOpen {
        stderrOpen = try drain(
          descriptor: stderrPipe[0],
          into: &stderr,
          maximumBytes: request.maximumOutputBytes,
          exceeded: &outputLimitExceeded
        )
      }
      if outputLimitExceeded, !terminationSent {
        terminateProcessTree(
          processID,
          observedProcesses: observedProcesses,
          signal: SIGTERM
        )
        terminationSent = true
        let now = monotonicSeconds()
        forceKillAt = now + 0.25
        abandonPipesAt = now + 0.5
      }
      if let forceKillAt, monotonicSeconds() >= forceKillAt {
        terminateProcessTree(
          processID,
          observedProcesses: observedProcesses,
          signal: SIGKILL
        )
      }
      if let abandonPipesAt, monotonicSeconds() >= abandonPipesAt {
        if stdoutOpen {
          Darwin.close(stdoutPipe[0])
          stdoutPipe[0] = -1
          stdoutOpen = false
        }
        if stderrOpen {
          Darwin.close(stderrPipe[0])
          stderrPipe[0] = -1
          stderrOpen = false
        }
      }

      if !childExited {
        let waited = Darwin.waitpid(processID, &childStatus, WNOHANG)
        if waited == processID {
          childExited = true
        } else if waited == -1, errno != EINTR {
          throw GitProcessError.waitFailed(errno)
        }
      }
      if !childExited || stdoutOpen || stderrOpen {
        var descriptors: [pollfd] = []
        if stdoutOpen {
          descriptors.append(pollfd(fd: stdoutPipe[0], events: Int16(POLLIN), revents: 0))
        }
        if stderrOpen {
          descriptors.append(pollfd(fd: stderrPipe[0], events: Int16(POLLIN), revents: 0))
        }
        if descriptors.isEmpty {
          usleep(10_000)
        } else {
          _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20)
        }
      }
    }

    let descendantExitDeadline = monotonicSeconds() + 0.25
    var survivingProcesses = observedProcesses.filter { processIdentity($0.pid) == $0 }
    while survivingProcesses.contains(where: { $0.pid != processID }),
      monotonicSeconds() < descendantExitDeadline
    {
      usleep(10_000)
      survivingProcesses = observedProcesses.filter { processIdentity($0.pid) == $0 }
    }
    if survivingProcesses.contains(where: { $0.pid != processID }) {
      timedOut = true
      let survivors = Set(survivingProcesses)
      terminateProcessTree(
        processID,
        observedProcesses: survivors,
        signal: SIGTERM
      )
      usleep(100_000)
      terminateProcessTree(
        processID,
        observedProcesses: survivors,
        signal: SIGKILL
      )
    }
    let duration = max(0, monotonicSeconds() - startedAt)
    let status = decodedStatus(childStatus)
    return GitProcessResult(
      exitCode: status.exitCode,
      terminationSignal: status.signal,
      timedOut: timedOut,
      outputLimitExceeded: outputLimitExceeded,
      stdout: stdout,
      stderr: stderr,
      durationSeconds: duration
    )
  }

  private static func validate(_ request: GitProcessRequest) throws {
    guard request.executable.isFileURL, request.executable.path.hasPrefix("/"),
      request.arguments.allSatisfy({ !$0.contains("\u{0}") }),
      request.environment.allSatisfy({
        !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\u{0}")
          && !$0.value.contains("\u{0}")
      })
    else {
      throw GitProcessError.invalidEnvironment
    }
    let executableValues = try request.executable.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard executableValues.isRegularFile == true,
      executableValues.isSymbolicLink != true
    else {
      throw GitProcessError.invalidExecutable
    }
    let workingValues = try request.workingDirectory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard workingValues.isDirectory == true, workingValues.isSymbolicLink != true else {
      throw GitProcessError.unsafeWorkingDirectory
    }
    guard request.timeoutSeconds.isFinite, (0.05...3_600).contains(request.timeoutSeconds),
      (1...16 * 1_024 * 1_024).contains(request.maximumOutputBytes)
    else {
      throw GitProcessError.invalidLimits
    }
  }

  private static func withCStringVector<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
  ) throws -> T {
    var pointers: [UnsafeMutablePointer<CChar>] = []
    do {
      for string in strings {
        guard let pointer = strdup(string) else { throw GitProcessError.allocationFailed }
        pointers.append(pointer)
      }
    } catch {
      for pointer in pointers { free(pointer) }
      throw error
    }
    defer {
      for pointer in pointers { free(pointer) }
    }
    var terminated = pointers.map(Optional.some) + [nil]
    return try terminated.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw GitProcessError.allocationFailed
      }
      return try body(baseAddress)
    }
  }

  private static func drain(
    descriptor: Int32,
    into output: inout Data,
    maximumBytes: Int,
    exceeded: inout Bool
  ) throws -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        let remaining = max(0, maximumBytes - output.count)
        if remaining > 0 {
          output.append(contentsOf: buffer.prefix(min(remaining, count)))
        }
        if count > remaining { exceeded = true }
        continue
      }
      if count == 0 { return false }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return true }
      throw GitProcessError.pipeFailed(errno)
    }
  }

  private static func setNonBlocking(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
  }

  private struct ProcessIdentity: Hashable {
    let pid: pid_t
    let processGroup: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func == (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
      lhs.pid == rhs.pid
        && lhs.startSeconds == rhs.startSeconds
        && lhs.startMicroseconds == rhs.startMicroseconds
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(pid)
      hasher.combine(startSeconds)
      hasher.combine(startMicroseconds)
    }
  }

  private static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
    var information = proc_bsdinfo()
    let size = proc_pidinfo(
      pid,
      PROC_PIDTBSDINFO,
      0,
      &information,
      Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard size == MemoryLayout<proc_bsdinfo>.size,
      information.pbi_pid == UInt32(pid),
      information.pbi_status != UInt32(SZOMB)
    else {
      return nil
    }
    return ProcessIdentity(
      pid: pid,
      processGroup: pid_t(information.pbi_pgid),
      startSeconds: information.pbi_start_tvsec,
      startMicroseconds: information.pbi_start_tvusec
    )
  }

  private static func descendantProcesses(of root: pid_t) -> Set<ProcessIdentity> {
    var discovered: Set<ProcessIdentity> = []
    var pending = [root]
    while let parent = pending.popLast() {
      var children = [pid_t](repeating: 0, count: 1_024)
      let count = proc_listchildpids(
        parent,
        &children,
        Int32(children.count * MemoryLayout<pid_t>.size)
      )
      guard count > 0 else { continue }
      for child in children.prefix(min(Int(count), children.count)) where child > 0 {
        guard let identity = processIdentity(child) else { continue }
        if discovered.insert(identity).inserted { pending.append(child) }
      }
    }
    return discovered
  }

  private static func terminateProcessTree(
    _ processID: pid_t,
    observedProcesses: Set<ProcessIdentity>,
    signal: Int32
  ) {
    let current = observedProcesses.filter { processIdentity($0.pid) == $0 }
    if current.contains(where: { $0.processGroup == processID }) {
      _ = Darwin.kill(-processID, signal)
    }
    for process in current {
      _ = Darwin.kill(process.pid, signal)
    }
  }

  private static func decodedStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
    let signal = status & 0x7F
    if signal == 0 { return ((status >> 8) & 0xFF, nil) }
    return (nil, signal)
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }

  private static func closePair(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
  }
}
