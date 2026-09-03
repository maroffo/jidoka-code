import Darwin
import Foundation
import JidokaCodeCore

@main
enum JidokaCodeBoundedCommandMain {
  private static let defaultStandardOutputLimit = 8 * 1_024 * 1_024
  private static let defaultStandardErrorLimit = 1_024 * 1_024

  static func main() async {
    if CommandLine.arguments.count == 3,
      CommandLine.arguments[1] == "--process-identity"
    {
      exit(writeProcessIdentity(CommandLine.arguments[2]))
    }

    do {
      let invocation = try invocation()
      let forwardedSignal = ForwardedSignalState()
      for signalNumber in [SIGHUP, SIGINT, SIGTERM] {
        Darwin.signal(signalNumber, SIG_IGN)
      }
      let task = Task {
        try await BoundedProcessRunner().run(invocation.request)
      }
      let signalSources = [SIGHUP, SIGINT, SIGTERM].map { signalNumber in
        let source = DispatchSource.makeSignalSource(
          signal: signalNumber,
          queue: DispatchQueue.global()
        )
        source.setEventHandler(handler: { @Sendable [forwardedSignal, task] in
          forwardedSignal.record(signalNumber)
          task.cancel()
        })
        source.resume()
        return source
      }
      defer {
        for source in signalSources { source.cancel() }
      }

      let result = try await task.value
      FileHandle.standardOutput.write(result.stdout)
      FileHandle.standardError.write(result.stderr)
      if result.outputLimitExceeded {
        let stream = result.stdoutLimitExceeded ? "stdout" : "stderr"
        let limit =
          result.stdoutLimitExceeded
          ? invocation.standardOutputLimit : invocation.standardErrorLimit
        writeError("bounded command \(stream) exceeded \(limit) bytes\n")
        exit(126)
      }
      if let signalNumber = forwardedSignal.value {
        exit(128 + signalNumber)
      }
      if result.timedOut {
        writeError("bounded command timed out after \(invocation.timeoutSeconds)s\n")
        exit(124)
      }
      if let exitCode = result.exitCode { exit(exitCode) }
      if let signalNumber = result.terminationSignal { exit(128 + signalNumber) }
      writeError("bounded command identity cleanup failed\n")
      exit(125)
    } catch let error as GitProcessError {
      if error == .cleanupFailed {
        writeError("bounded command identity cleanup failed\n")
        exit(125)
      }
      writeError("bounded command execution failed\n")
      exit(125)
    } catch {
      writeError("invalid bounded-command invocation\n")
      exit(64)
    }
  }

  private struct Invocation {
    let request: GitProcessRequest
    let timeoutSeconds: Int
    let standardOutputLimit: Int
    let standardErrorLimit: Int
  }

  private static func invocation() throws -> Invocation {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2,
      let timeout = Int(arguments[0]),
      (1...3_600).contains(timeout)
    else {
      throw BoundedCommandError.invalidInvocation
    }
    let executable = arguments[1]
    guard executable.hasPrefix("/") else { throw BoundedCommandError.invalidInvocation }
    let standardOutputLimit = try outputLimit(
      name: "JIDOKA_BOUNDED_STDOUT_LIMIT_BYTES",
      defaultValue: defaultStandardOutputLimit
    )
    let standardErrorLimit = try outputLimit(
      name: "JIDOKA_BOUNDED_STDERR_LIMIT_BYTES",
      defaultValue: defaultStandardErrorLimit
    )
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "JIDOKA_BOUNDED_STDOUT_LIMIT_BYTES")
    environment.removeValue(forKey: "JIDOKA_BOUNDED_STDERR_LIMIT_BYTES")
    let workingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).resolvingSymlinksInPath()
    return Invocation(
      request: GitProcessRequest(
        executable: URL(fileURLWithPath: executable),
        arguments: Array(arguments.dropFirst(2)),
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutSeconds: TimeInterval(timeout),
        maximumOutputBytes: standardOutputLimit,
        maximumStandardErrorBytes: standardErrorLimit
      ),
      timeoutSeconds: timeout,
      standardOutputLimit: standardOutputLimit,
      standardErrorLimit: standardErrorLimit
    )
  }

  private static func outputLimit(name: String, defaultValue: Int) throws -> Int {
    guard let value = ProcessInfo.processInfo.environment[name] else { return defaultValue }
    guard value.wholeMatch(of: /^[1-9][0-9]*$/) != nil,
      let parsed = Int(value),
      (1...64 * 1_024 * 1_024).contains(parsed)
    else {
      throw BoundedCommandError.invalidInvocation
    }
    return parsed
  }

  private static func writeProcessIdentity(_ value: String) -> Int32 {
    guard let processID = pid_t(value), processID > 0 else { return 64 }
    var information = proc_bsdinfo()
    let size = proc_pidinfo(
      processID,
      PROC_PIDTBSDINFO,
      0,
      &information,
      Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    guard size == MemoryLayout<proc_bsdinfo>.size,
      information.pbi_pid == UInt32(processID),
      information.pbi_status != UInt32(SZOMB)
    else { return 1 }
    FileHandle.standardOutput.write(
      Data(
        "\(processID)|\(information.pbi_start_tvsec)|\(information.pbi_start_tvusec)\n".utf8
      )
    )
    return 0
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}

private enum BoundedCommandError: Error {
  case invalidInvocation
}

private final class ForwardedSignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var signalNumber: Int32?

  var value: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return signalNumber
  }

  func record(_ value: Int32) {
    lock.lock()
    if signalNumber == nil { signalNumber = value }
    lock.unlock()
  }
}
