import Darwin
import Foundation
import JidokaCodeCore

@main
struct JidokaCodeAskPass {
  static func main() {
    guard CommandLine.arguments.count == 2 else {
      fail()
    }
    do {
      var credential = try GitAskPassClient.credential(
        prompt: CommandLine.arguments[1],
        environment: ProcessInfo.processInfo.environment
      )
      let credentialCount = credential.count
      defer { credential.resetBytes(in: 0..<credentialCount) }
      FileHandle.standardOutput.write(credential)
      FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
      fail()
    }
  }

  private static func fail() -> Never {
    FileHandle.standardError.write(Data("JIDOKA_ASKPASS_FAILED\n".utf8))
    Darwin.exit(64)
  }
}
