import Darwin
import Foundation
import JidokaCodeCore

@main
struct JidokaCodePushGuard {
  static func main() {
    do {
      let input = try readInput()
      try GitPushGuard.validate(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment,
        input: input
      )
    } catch {
      fail()
    }
  }

  private static func readInput() throws -> Data {
    var input = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while input.count <= 2_048 {
      let maximumRead = min(buffer.count, 2_049 - input.count)
      let count = Darwin.read(STDIN_FILENO, &buffer, maximumRead)
      if count > 0 {
        input.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        return input
      } else if errno != EINTR {
        throw PushGuardReadError.failed
      }
    }
    return input
  }

  private static func fail() -> Never {
    FileHandle.standardError.write(Data("JIDOKA_PUSH_GUARD_FAILED\n".utf8))
    Darwin.exit(64)
  }
}

private enum PushGuardReadError: Error {
  case failed
}
