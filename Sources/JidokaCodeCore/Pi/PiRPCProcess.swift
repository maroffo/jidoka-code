import CryptoKit
import Darwin
import Foundation

public enum PiRPCEnvironmentPolicy: Equatable, Sendable {
  case locked
  case deterministicFixture
}

public struct PiRPCProcessRequest: Sendable {
  public let executable: URL
  public let arguments: [String]
  public let workingDirectory: URL
  public let environment: [String: String]
  public let prompt: String
  public let sessionExpectation: PiRPCSessionExpectation
  public let terminalIdentity: PiRPCTerminalResultIdentity
  public let allowedToolNames: [String]
  public let timeoutSeconds: TimeInterval
  public let abortGraceSeconds: TimeInterval
  public let maximumRecordBytes: Int
  public let maximumOutputBytes: Int
  public let maximumErrorBytes: Int
  public let requireEmptyStderr: Bool
  public let environmentPolicy: PiRPCEnvironmentPolicy

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String],
    prompt: String,
    sessionExpectation: PiRPCSessionExpectation,
    terminalIdentity: PiRPCTerminalResultIdentity,
    allowedToolNames: [String],
    timeoutSeconds: TimeInterval,
    abortGraceSeconds: TimeInterval = 2,
    maximumRecordBytes: Int = 1_048_576,
    maximumOutputBytes: Int = 8 * 1_024 * 1_024,
    maximumErrorBytes: Int = 1_048_576,
    requireEmptyStderr: Bool = true,
    environmentPolicy: PiRPCEnvironmentPolicy = .locked
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.prompt = prompt
    self.sessionExpectation = sessionExpectation
    self.terminalIdentity = terminalIdentity
    self.allowedToolNames = allowedToolNames
    self.timeoutSeconds = timeoutSeconds
    self.abortGraceSeconds = abortGraceSeconds
    self.maximumRecordBytes = maximumRecordBytes
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumErrorBytes = maximumErrorBytes
    self.requireEmptyStderr = requireEmptyStderr
    self.environmentPolicy = environmentPolicy
  }
}

public struct PiRPCExecutionResult: Equatable, Sendable {
  public let sessionID: String
  public let terminalResult: PiRPCTerminalResult
  public let stdoutSHA256: String
  public let stderrSHA256: String
  public let durationSeconds: TimeInterval
  public let abortAcknowledged: Bool
  public let cleanupVerified: Bool

  public init(
    sessionID: String,
    terminalResult: PiRPCTerminalResult,
    stdoutSHA256: String,
    stderrSHA256: String,
    durationSeconds: TimeInterval,
    abortAcknowledged: Bool,
    cleanupVerified: Bool
  ) {
    self.sessionID = sessionID
    self.terminalResult = terminalResult
    self.stdoutSHA256 = stdoutSHA256
    self.stderrSHA256 = stderrSHA256
    self.durationSeconds = durationSeconds
    self.abortAcknowledged = abortAcknowledged
    self.cleanupVerified = cleanupVerified
  }
}

public enum PiRPCProcessError: Error, Equatable, Sendable {
  case invalidRequest
  case invalidExecutable
  case unsafeWorkingDirectory
  case pipeFailed(Int32)
  case spawnFailed(Int32)
  case descriptorConfigurationFailed(Int32)
  case writeFailed(Int32)
  case readFailed(Int32)
  case waitFailed(Int32)
  case allocationFailed
  case outputLimitExceeded
  case stderrNotEmpty
  case unexpectedExit(Int32?)
  case timeout(abortAcknowledged: Bool)
  case cleanupFailed
}

public protocol PiRPCProcessRunning: Sendable {
  func run(_ request: PiRPCProcessRequest) async throws -> PiRPCExecutionResult
}

public final class PiRPCProcessRunner: PiRPCProcessRunning, @unchecked Sendable {
  public init() {}

  public func run(_ request: PiRPCProcessRequest) async throws -> PiRPCExecutionResult {
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
    _ request: PiRPCProcessRequest
  ) throws -> PiRPCExecutionResult {
    let executable = request.executable.resolvingSymlinksInPath().standardizedFileURL
    let workingDirectory = request.workingDirectory.resolvingSymlinksInPath().standardizedFileURL
    try validate(request, executable: executable, workingDirectory: workingDirectory)
    var inputPipe = [Int32](repeating: -1, count: 2)
    var outputPipe = [Int32](repeating: -1, count: 2)
    var errorPipe = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&inputPipe) == 0 else { throw PiRPCProcessError.pipeFailed(errno) }
    guard Darwin.pipe(&outputPipe) == 0 else {
      closePair(inputPipe)
      throw PiRPCProcessError.pipeFailed(errno)
    }
    guard Darwin.pipe(&errorPipe) == 0 else {
      closePair(inputPipe)
      closePair(outputPipe)
      throw PiRPCProcessError.pipeFailed(errno)
    }

    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    let actionStatus = posix_spawn_file_actions_init(&actions)
    guard actionStatus == 0 else {
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(actionStatus)
    }
    let attributeStatus = posix_spawnattr_init(&attributes)
    guard attributeStatus == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(attributeStatus)
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }

    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED
    )
    let setupStatuses = [
      posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO),
      posix_spawn_file_actions_addclose(&actions, inputPipe[0]),
      posix_spawn_file_actions_addclose(&actions, inputPipe[1]),
      posix_spawn_file_actions_addclose(&actions, outputPipe[0]),
      posix_spawn_file_actions_addclose(&actions, outputPipe[1]),
      posix_spawn_file_actions_addclose(&actions, errorPipe[0]),
      posix_spawn_file_actions_addclose(&actions, errorPipe[1]),
      posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path),
      posix_spawnattr_setflags(&attributes, flags),
      posix_spawnattr_setpgroup(&attributes, 0),
    ]
    if let setupFailure = setupStatuses.first(where: { $0 != 0 }) {
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(setupFailure)
    }

    var processID: pid_t = 0
    let arguments = [executable.path] + request.arguments
    let environment = request.environment.sorted { $0.key < $1.key }.map {
      "\($0.key)=\($0.value)"
    }
    let spawnStatus: Int32
    do {
      spawnStatus = try withCStringVector(arguments) { argumentVector in
        try withCStringVector(environment) { environmentVector in
          posix_spawn(
            &processID,
            executable.path,
            &actions,
            &attributes,
            argumentVector,
            environmentVector
          )
        }
      }
    } catch {
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw error
    }
    Darwin.close(inputPipe[0])
    Darwin.close(outputPipe[1])
    Darwin.close(errorPipe[1])
    inputPipe[0] = -1
    outputPipe[1] = -1
    errorPipe[1] = -1
    guard spawnStatus == 0 else {
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(spawnStatus)
    }

    let descriptorStatuses = [
      setNoSigPipe(inputPipe[1]),
      setNonBlocking(inputPipe[1]),
      setNonBlocking(outputPipe[0]),
      setNonBlocking(errorPipe[0]),
    ]
    if let descriptorFailure = descriptorStatuses.first(where: { $0 != 0 }) {
      _ = Darwin.kill(-processID, SIGKILL)
      _ = Darwin.kill(processID, SIGKILL)
      _ = Darwin.waitpid(processID, nil, 0)
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.descriptorConfigurationFailed(descriptorFailure)
    }
    guard let processTracker = SupervisedProcessTracker(rootProcessID: processID) else {
      _ = Darwin.kill(processID, SIGKILL)
      _ = Darwin.waitpid(processID, nil, 0)
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(ESRCH)
    }
    guard Darwin.kill(-processID, SIGCONT) == 0 else {
      let signalError = errno
      processTracker.signalOwnedProcesses(SIGKILL, originalProcessGroup: processID)
      _ = Darwin.waitpid(processID, nil, 0)
      closePair(inputPipe)
      closePair(outputPipe)
      closePair(errorPipe)
      throw PiRPCProcessError.spawnFailed(signalError)
    }
    let startedAt = monotonicSeconds()
    let deadline = startedAt + request.timeoutSeconds
    var parser = try PiRPCJSONLParser(maximumRecordBytes: request.maximumRecordBytes)
    var conversation = PiRPCConversation(
      terminalIdentity: request.terminalIdentity,
      allowedToolNames: request.allowedToolNames
    )
    var standardOutput = Data()
    var standardError = Data()
    var outputOpen = true
    var errorOpen = true
    var inputOpen = true
    var childStatus: Int32 = 0
    var childExited = false
    var cleanupSignal: Int32?
    var cleanupComplete = false

    defer {
      if inputOpen { Darwin.close(inputPipe[1]) }
      if outputPipe[0] >= 0 { Darwin.close(outputPipe[0]) }
      if errorPipe[0] >= 0 { Darwin.close(errorPipe[0]) }
      if !cleanupComplete {
        processTracker.signalOwnedProcesses(SIGKILL, originalProcessGroup: processID)
        if !childExited { _ = Darwin.waitpid(processID, &childStatus, 0) }
      }
    }

    func checkChild() throws {
      _ = processTracker.observeDescendants()
      guard !childExited else { return }
      let waited = Darwin.waitpid(processID, &childStatus, WNOHANG)
      if waited == processID {
        childExited = true
        _ = processTracker.observeDescendants()
      } else if waited == -1, errno != EINTR {
        throw PiRPCProcessError.waitFailed(errno)
      }
    }

    func drainOutput() throws {
      guard outputOpen else { return }
      var chunks: [Data] = []
      outputOpen = try drain(
        descriptor: outputPipe[0],
        maximumBytes: request.maximumOutputBytes,
        output: &standardOutput,
        chunks: &chunks
      )
      for chunk in chunks {
        for record in try parser.append(chunk) {
          try conversation.consume(record)
        }
      }
      if !outputOpen { try parser.finish() }
    }

    func drainError() throws {
      guard errorOpen else { return }
      var ignored: [Data] = []
      errorOpen = try drain(
        descriptor: errorPipe[0],
        maximumBytes: request.maximumErrorBytes,
        output: &standardError,
        chunks: &ignored
      )
    }

    func pump(until waitDeadline: TimeInterval) throws {
      if Task.isCancelled || monotonicSeconds() >= waitDeadline {
        throw PiRPCProcessError.timeout(abortAcknowledged: false)
      }
      try drainOutput()
      try drainError()
      try checkChild()
      if childExited {
        // A child may exit after the first nonblocking drain but before waitpid.
        // Drain once more so bytes written immediately before exit are validated.
        try drainOutput()
        try drainError()
        if !conversation.isSettled {
          throw PiRPCProcessError.unexpectedExit(decodedExitCode(childStatus))
        }
      }
      var descriptors: [pollfd] = []
      if outputOpen {
        descriptors.append(pollfd(fd: outputPipe[0], events: Int16(POLLIN), revents: 0))
      }
      if errorOpen {
        descriptors.append(pollfd(fd: errorPipe[0], events: Int16(POLLIN), revents: 0))
      }
      if descriptors.isEmpty {
        usleep(10_000)
      } else {
        _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), 20)
      }
    }

    func writePayload(_ data: Data, writeDeadline: TimeInterval) throws {
      try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
          guard inputOpen, !childExited else {
            throw PiRPCProcessError.unexpectedExit(decodedExitCode(childStatus))
          }
          let count = Darwin.write(
            inputPipe[1],
            base.advanced(by: offset),
            rawBuffer.count - offset
          )
          if count > 0 {
            offset += count
          } else if count == -1, errno == EINTR {
            continue
          } else if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
            try pump(until: writeDeadline)
          } else {
            throw PiRPCProcessError.writeFailed(errno)
          }
        }
      }
    }

    var nextRequestID = 1
    func send(
      _ object: [String: Any],
      command: String,
      writeDeadline: TimeInterval
    ) throws -> String {
      guard inputOpen, !childExited else {
        throw PiRPCProcessError.unexpectedExit(decodedExitCode(childStatus))
      }
      let id = "jidoka-\(nextRequestID)"
      nextRequestID += 1
      var payload = object
      payload["id"] = id
      var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      data.append(0x0A)
      try conversation.registerRequest(id: id, command: command)
      try writePayload(data, writeDeadline: writeDeadline)
      return id
    }

    func waitForResponse(
      id: String,
      command: String,
      commandDeadline: TimeInterval
    ) throws -> PiRPCResponse {
      while true {
        if let response = conversation.takeResponse(id: id) {
          guard response.command == command else {
            throw PiRPCProtocolError.responseCommandMismatch
          }
          return response
        }
        try pump(until: commandDeadline)
      }
    }

    func issue(_ object: [String: Any], command: String) throws -> PiRPCResponse {
      let commandDeadline = min(deadline, monotonicSeconds() + 10)
      let id = try send(object, command: command, writeDeadline: commandDeadline)
      return try waitForResponse(
        id: id,
        command: command,
        commandDeadline: commandDeadline
      )
    }

    var operationError: (any Error)?
    var terminalResult: PiRPCTerminalResult?
    var sessionID: String?
    var abortAcknowledged = false
    do {
      _ = try issue(
        ["type": "set_auto_retry", "enabled": false],
        command: "set_auto_retry"
      )
      _ = try issue(
        ["type": "set_auto_compaction", "enabled": false],
        command: "set_auto_compaction"
      )
      let state = try issue(["type": "get_state"], command: "get_state")
      sessionID = try PiRPCSessionValidation.validateState(
        state,
        expected: request.sessionExpectation
      )
      let commands = try issue(["type": "get_commands"], command: "get_commands")
      try PiRPCSessionValidation.validateCommands(commands, expected: request.sessionExpectation)
      let prompt = try issue(
        ["type": "prompt", "message": request.prompt],
        command: "prompt"
      )
      try conversation.markPromptAccepted(prompt)
      while !conversation.isSettled { try pump(until: deadline) }
      terminalResult = try conversation.validatedTerminalResult()
    } catch {
      operationError = error
      if case PiRPCProcessError.timeout = error, inputOpen, !childExited {
        do {
          let abortDeadline = monotonicSeconds() + request.abortGraceSeconds
          let abortID = try send(
            ["type": "abort"],
            command: "abort",
            writeDeadline: abortDeadline
          )
          while monotonicSeconds() < abortDeadline {
            if let response = conversation.takeResponse(id: abortID) {
              abortAcknowledged = response.command == "abort" && response.success
              break
            }
            try pump(until: abortDeadline)
          }
        } catch {
          abortAcknowledged = false
        }
      }
    }

    func recordCleanupError(_ operation: () throws -> Void) {
      do {
        try operation()
      } catch {
        if operationError == nil { operationError = error }
      }
    }

    if operationError != nil, !childExited {
      cleanupSignal = SIGTERM
      processTracker.signalOwnedProcesses(SIGTERM, originalProcessGroup: processID)
    }
    if inputOpen {
      Darwin.close(inputPipe[1])
      inputPipe[1] = -1
      inputOpen = false
    }
    var gracefulDeadline = monotonicSeconds() + 0.5
    while !childExited, monotonicSeconds() < gracefulDeadline {
      recordCleanupError { try drainOutput() }
      recordCleanupError { try drainError() }
      recordCleanupError { try checkChild() }
      if !childExited { usleep(10_000) }
    }
    if childExited, operationError == nil, !didExitSuccessfully(childStatus) {
      operationError = PiRPCProcessError.unexpectedExit(decodedExitCode(childStatus))
    }
    if !childExited {
      recordCleanupError { try checkChild() }
    }
    if !childExited {
      cleanupSignal = SIGTERM
      processTracker.signalOwnedProcesses(SIGTERM, originalProcessGroup: processID)
      gracefulDeadline = monotonicSeconds() + 0.5
      while !childExited, monotonicSeconds() < gracefulDeadline {
        recordCleanupError { try drainOutput() }
        recordCleanupError { try drainError() }
        recordCleanupError { try checkChild() }
        if !childExited { usleep(10_000) }
      }
    }
    if !childExited {
      recordCleanupError { try checkChild() }
    }
    if !childExited {
      cleanupSignal = SIGKILL
      processTracker.signalOwnedProcesses(SIGKILL, originalProcessGroup: processID)
      var waited: pid_t
      repeat {
        waited = Darwin.waitpid(processID, &childStatus, 0)
      } while waited == -1 && errno == EINTR
      if waited == processID {
        childExited = true
      } else if operationError == nil {
        operationError = PiRPCProcessError.waitFailed(errno)
      }
    }
    if childExited, operationError == nil,
      !didExitAcceptably(childStatus, cleanupSignal: cleanupSignal)
    {
      operationError = PiRPCProcessError.unexpectedExit(decodedExitCode(childStatus))
    }
    if !processTracker.cleanupVerified(originalProcessGroup: processID) {
      processTracker.signalOwnedProcesses(SIGTERM, originalProcessGroup: processID)
      if !processTracker.waitForCleanup(
        originalProcessGroup: processID,
        until: monotonicSeconds() + 0.25
      ) {
        processTracker.signalOwnedProcesses(SIGKILL, originalProcessGroup: processID)
        guard
          processTracker.waitForCleanup(
            originalProcessGroup: processID,
            until: monotonicSeconds() + 2
          )
        else {
          throw PiRPCProcessError.cleanupFailed
        }
      }
    }
    let pipeDeadline = monotonicSeconds() + 0.5
    while outputOpen || errorOpen, monotonicSeconds() < pipeDeadline {
      recordCleanupError { try drainOutput() }
      recordCleanupError { try drainError() }
      if outputOpen || errorOpen { usleep(10_000) }
    }
    if outputOpen {
      Darwin.close(outputPipe[0])
      outputPipe[0] = -1
      outputOpen = false
      if operationError == nil { operationError = PiRPCProcessError.cleanupFailed }
    }
    if errorOpen {
      Darwin.close(errorPipe[0])
      errorPipe[0] = -1
      errorOpen = false
      if operationError == nil { operationError = PiRPCProcessError.cleanupFailed }
    }
    recordCleanupError { try parser.finish() }
    let cleanupVerified = processTracker.cleanupVerified(originalProcessGroup: processID)
    cleanupComplete = cleanupVerified
    guard cleanupVerified else { throw PiRPCProcessError.cleanupFailed }

    if let operationError {
      if case PiRPCProcessError.timeout = operationError {
        throw PiRPCProcessError.timeout(abortAcknowledged: abortAcknowledged)
      }
      throw operationError
    }
    guard let terminalResult else { throw PiRPCProtocolError.missingTerminalResult }
    guard let sessionID else { throw PiRPCProtocolError.responseFailed("get_state") }
    guard !request.requireEmptyStderr || standardError.isEmpty else {
      throw PiRPCProcessError.stderrNotEmpty
    }
    return PiRPCExecutionResult(
      sessionID: sessionID,
      terminalResult: terminalResult,
      stdoutSHA256: sha256(standardOutput),
      stderrSHA256: sha256(standardError),
      durationSeconds: max(0, monotonicSeconds() - startedAt),
      abortAcknowledged: abortAcknowledged,
      cleanupVerified: cleanupVerified
    )
  }

  private static func validate(
    _ request: PiRPCProcessRequest,
    executable: URL,
    workingDirectory: URL
  ) throws {
    guard request.executable.isFileURL,
      request.executable.path.hasPrefix("/"),
      request.workingDirectory.isFileURL,
      request.workingDirectory.path.hasPrefix("/"),
      !request.prompt.isEmpty,
      request.prompt.utf8.count <= 8 * 1_024 * 1_024,
      request.arguments.count <= 64,
      request.arguments.allSatisfy({
        !$0.contains("\u{0}") && $0.utf8.count <= 8_192
      }),
      request.environment.count <= 32,
      request.environment.allSatisfy({ key, value in
        !key.isEmpty && key.utf8.count <= 128 && !key.contains("=")
          && !key.contains("\u{0}") && !value.contains("\u{0}")
          && value.utf8.count <= 8_192
      }),
      request.environment.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count })
        <= 128 * 1_024,
      validSessionExpectation(request.sessionExpectation),
      validTerminalIdentity(request.terminalIdentity),
      !request.allowedToolNames.isEmpty,
      request.allowedToolNames.count <= 16,
      Set(request.allowedToolNames).count == request.allowedToolNames.count,
      request.allowedToolNames.allSatisfy({
        $0.wholeMatch(of: /^[a-z][a-z0-9_]{0,63}$/) != nil
      }),
      request.timeoutSeconds.isFinite,
      (0.05...3_600).contains(request.timeoutSeconds),
      request.abortGraceSeconds.isFinite,
      (0.05...30).contains(request.abortGraceSeconds),
      (64...16 * 1_024 * 1_024).contains(request.maximumRecordBytes),
      (1...64 * 1_024 * 1_024).contains(request.maximumOutputBytes),
      (1...16 * 1_024 * 1_024).contains(request.maximumErrorBytes)
    else {
      throw PiRPCProcessError.invalidRequest
    }
    try validateEnvironment(request.environment, policy: request.environmentPolicy)
    let executableValues = try executable.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard executableValues.isRegularFile == true,
      executableValues.isSymbolicLink != true,
      FileManager.default.isExecutableFile(atPath: executable.path)
    else {
      throw PiRPCProcessError.invalidExecutable
    }
    guard try safeDirectoryPath(workingDirectory.path) else {
      throw PiRPCProcessError.unsafeWorkingDirectory
    }
  }

  private static func validSessionExpectation(_ value: PiRPCSessionExpectation) -> Bool {
    guard !value.provider.isEmpty, value.provider.utf8.count <= 128,
      !value.modelID.isEmpty, value.modelID.utf8.count <= 256,
      ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        .contains(value.thinkingLevel),
      !value.commands.isEmpty, value.commands.count <= 8
    else {
      return false
    }
    let identities = value.commands.map { "\($0.name)\u{0}\($0.path)" }
    return Set(identities).count == identities.count
      && value.commands.allSatisfy { command in
        !command.name.isEmpty && command.name.utf8.count <= 256
          && !command.source.isEmpty && command.source.utf8.count <= 64
          && !command.path.isEmpty && command.path.utf8.count <= 4_096
          && !command.scope.isEmpty && command.scope.utf8.count <= 64
          && !command.origin.isEmpty && command.origin.utf8.count <= 64
          && !command.name.contains("\u{0}") && !command.path.contains("\u{0}")
      }
  }

  private static func validTerminalIdentity(_ value: PiRPCTerminalResultIdentity) -> Bool {
    let workflows = Set(["pr-review", "issue-triage", "planning", "orchestration"])
    let roles = Set(["architecture", "security", "test", "synthesis", "triage", "writer"])
    return workflows.contains(value.workflow)
      && roles.contains(value.role)
      && value.nonce.wholeMatch(of: /^[a-z0-9][a-z0-9-]{7,63}$/) != nil
      && value.artifactSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
      && value.allowedCommandIDs.count <= 256
      && value.allowedCommandIDs.allSatisfy {
        $0.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil
      }
  }

  private static func validateEnvironment(
    _ environment: [String: String],
    policy: PiRPCEnvironmentPolicy
  ) throws {
    let forbiddenKeys = Set([
      "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "SSH_AUTH_SOCK",
    ])
    guard forbiddenKeys.isDisjoint(with: environment.keys) else {
      throw PiRPCProcessError.invalidRequest
    }
    guard policy == .locked else { return }
    let requiredKeys: Set<String> = [
      "GIT_ASKPASS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_SSH_COMMAND",
      "GIT_TERMINAL_PROMPT", "HOME", "JIDOKA_CODE_CONFIG", "LANG", "LC_ALL", "PATH",
      "PI_CODING_AGENT_DIR", "PI_SKIP_VERSION_CHECK", "TMPDIR",
    ]
    let observedKeys = Set(environment.keys)
    guard observedKeys == requiredKeys || observedKeys == requiredKeys.union(["PI_OFFLINE"]),
      environment["GIT_ASKPASS"] == "/usr/bin/false",
      environment["GIT_CONFIG_GLOBAL"] == "/dev/null",
      environment["GIT_CONFIG_NOSYSTEM"] == "1",
      environment["GIT_SSH_COMMAND"] == "/usr/bin/false",
      environment["GIT_TERMINAL_PROMPT"] == "0",
      environment["LANG"] == "en_US.UTF-8",
      environment["LC_ALL"] == "en_US.UTF-8",
      environment["PATH"] == "/usr/bin:/bin",
      environment["PI_SKIP_VERSION_CHECK"] == "1",
      environment["PI_OFFLINE"] == nil || environment["PI_OFFLINE"] == "1",
      let home = environment["HOME"],
      let agent = environment["PI_CODING_AGENT_DIR"],
      let temporary = environment["TMPDIR"],
      let configuration = environment["JIDOKA_CODE_CONFIG"],
      try safeDirectoryPath(home),
      try safeDirectoryPath(agent),
      try safeDirectoryPath(temporary),
      try safePrivateFilePath(configuration)
    else {
      throw PiRPCProcessError.invalidRequest
    }
  }

  private static func safeDirectoryPath(_ path: String) throws -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard path.hasPrefix("/"), url.path == path,
      url.resolvingSymlinksInPath().path == path
    else {
      return false
    }
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    return values.isDirectory == true && values.isSymbolicLink != true
      && permissions.map { $0 & 0o077 == 0 } == true
      && owner == getuid()
  }

  private static func safePrivateFilePath(_ path: String) throws -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard path.hasPrefix("/"), url.path == path,
      url.resolvingSymlinksInPath().path == path
    else {
      return false
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    let size = (attributes[.size] as? NSNumber)?.intValue
    return values.isRegularFile == true && values.isSymbolicLink != true
      && permissions.map { $0 & 0o077 == 0 } == true
      && owner == getuid()
      && size.map { $0 <= 1_048_576 } == true
  }

  private static func drain(
    descriptor: Int32,
    maximumBytes: Int,
    output: inout Data,
    chunks: inout [Data]
  ) throws -> Bool {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        guard output.count + count <= maximumBytes else {
          throw PiRPCProcessError.outputLimitExceeded
        }
        let chunk = Data(buffer.prefix(count))
        output.append(chunk)
        chunks.append(chunk)
        continue
      }
      if count == 0 { return false }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return true }
      throw PiRPCProcessError.readFailed(errno)
    }
  }

  private static func withCStringVector<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
  ) throws -> T {
    var pointers: [UnsafeMutablePointer<CChar>] = []
    do {
      for string in strings {
        guard let pointer = strdup(string) else { throw PiRPCProcessError.allocationFailed }
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
        throw PiRPCProcessError.allocationFailed
      }
      return try body(baseAddress)
    }
  }

  private static func decodedExitCode(_ status: Int32) -> Int32? {
    let signal = status & 0x7F
    return signal == 0 ? (status >> 8) & 0xFF : nil
  }

  private static func didExitSuccessfully(_ status: Int32) -> Bool {
    decodedExitCode(status) == 0
  }

  private static func didExitAcceptably(
    _ status: Int32,
    cleanupSignal: Int32?
  ) -> Bool {
    if didExitSuccessfully(status) { return true }
    guard let cleanupSignal else { return false }
    let signal = status & 0x7F
    return signal != 0 && signal != 0x7F && signal == cleanupSignal
  }

  private static func monotonicSeconds() -> TimeInterval {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
  }

  private static func setNoSigPipe(_ descriptor: Int32) -> Int32 {
    guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { return errno }
    return 0
  }

  private static func setNonBlocking(_ descriptor: Int32) -> Int32 {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0 else { return errno }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return errno }
    return 0
  }

  private static func closePair(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum PiRPCSessionLaunch: Equatable, Sendable {
  case fresh
  case resume(String)
}

public enum PiRPCInvocationBuilder {
  public static func arguments(
    runtime: PiResolvedRuntime,
    model: String,
    sessionDirectory: URL,
    sessionName: String,
    blockerExtension: URL,
    runtimeExtension: URL,
    skill: URL,
    activeTools: [String] = PiWorkflowResourceCatalog.readOnlyToolNames,
    session: PiRPCSessionLaunch = .fresh
  ) throws -> [String] {
    try arguments(
      runtime: runtime,
      model: model,
      sessionDirectory: sessionDirectory,
      sessionName: sessionName,
      blockerExtension: blockerExtension,
      runtimeExtension: runtimeExtension,
      skills: [skill],
      activeTools: activeTools,
      session: session
    )
  }

  public static func arguments(
    runtime: PiResolvedRuntime,
    model: String,
    sessionDirectory: URL,
    sessionName: String,
    blockerExtension: URL,
    runtimeExtension: URL,
    skills: [URL],
    activeTools: [String],
    session: PiRPCSessionLaunch
  ) throws -> [String] {
    guard validModel(model),
      validSessionName(sessionName),
      try safeDirectory(sessionDirectory),
      try safeRegularFile(blockerExtension),
      try safeRegularFile(runtimeExtension),
      !skills.isEmpty,
      skills.count <= 3,
      try skills.allSatisfy(safeRegularFile),
      validActiveTools(activeTools),
      validSessionLaunch(session)
    else {
      throw PiRPCProcessError.invalidRequest
    }
    var values = [
      runtime.piCLIURL.path,
      "--mode",
      "rpc",
      "--no-approve",
      "--no-context-files",
      "--no-themes",
      "--no-prompt-templates",
      "--model",
      model,
      "--session-dir",
      sessionDirectory.path,
      "--name",
      sessionName,
      "--no-extensions",
      "--extension",
      blockerExtension.path,
      "--extension",
      runtimeExtension.path,
      "--no-skills",
    ]
    if case .resume(let sessionID) = session {
      values.append(contentsOf: ["--session", sessionID])
    }
    for skill in skills {
      values.append(contentsOf: ["--skill", skill.path])
    }
    values.append(contentsOf: ["--tools", activeTools.joined(separator: ",")])
    return values
  }

  public static func environment(
    homeDirectory: URL,
    agentDirectory: URL,
    temporaryDirectory: URL,
    workflowConfiguration: URL,
    offline: Bool
  ) throws -> [String: String] {
    guard try safeDirectory(homeDirectory),
      try safeDirectory(agentDirectory),
      try safeDirectory(temporaryDirectory),
      try safePrivateRegularFile(workflowConfiguration)
    else {
      throw PiRPCProcessError.invalidRequest
    }
    var environment = [
      "GIT_ASKPASS": "/usr/bin/false",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_SSH_COMMAND": "/usr/bin/false",
      "GIT_TERMINAL_PROMPT": "0",
      "HOME": homeDirectory.path,
      "JIDOKA_CODE_CONFIG": workflowConfiguration.path,
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "PATH": "/usr/bin:/bin",
      "PI_CODING_AGENT_DIR": agentDirectory.path,
      "PI_SKIP_VERSION_CHECK": "1",
      "TMPDIR": temporaryDirectory.path,
    ]
    if offline { environment["PI_OFFLINE"] = "1" }
    return environment
  }

  private static func validSessionLaunch(_ value: PiRPCSessionLaunch) -> Bool {
    switch value {
    case .fresh:
      return true
    case .resume(let sessionID):
      return sessionID.wholeMatch(
        of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      ) != nil
    }
  }

  private static func validActiveTools(_ values: [String]) -> Bool {
    values == PiWorkflowResourceCatalog.readOnlyToolNames
      || values == PiWorkflowResourceCatalog.writerToolNames
  }

  private static func validModel(_ value: String) -> Bool {
    value.wholeMatch(
      of:
        /^[a-z0-9][a-z0-9._-]{0,63}\/[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}:(off|minimal|low|medium|high|xhigh|max)$/
    ) != nil
  }

  private static func validSessionName(_ value: String) -> Bool {
    value.wholeMatch(of: /^jidoka-code-[a-z0-9][a-z0-9-]{0,95}$/) != nil
  }

  private static func safeDirectory(_ url: URL) throws -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/") else { return false }
    let standardized = url.standardizedFileURL
    guard standardized.resolvingSymlinksInPath().path == standardized.path else { return false }
    let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: standardized.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    return values.isDirectory == true && values.isSymbolicLink != true
      && permissions.map { $0 & 0o077 == 0 } == true
      && owner == getuid()
  }

  private static func safePrivateRegularFile(_ url: URL) throws -> Bool {
    guard try safeRegularFile(url) else { return false }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    let size = (attributes[.size] as? NSNumber)?.intValue
    return permissions.map { $0 & 0o077 == 0 } == true
      && owner == getuid()
      && size.map { $0 <= 1_048_576 } == true
  }

  private static func safeRegularFile(_ url: URL) throws -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/") else { return false }
    let standardized = url.standardizedFileURL
    guard standardized.resolvingSymlinksInPath().path == standardized.path else { return false }
    let values = try standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
