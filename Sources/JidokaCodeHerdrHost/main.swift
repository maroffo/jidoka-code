import Darwin
import Foundation
import JidokaCodeCore

@main
enum JidokaCodeHerdrHostMain {
  static func main() async {
    _ = Darwin.umask(0o077)
    let task = Task {
      try await HerdrHostRuntime.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: ProcessInfo.processInfo.environment
      )
    }
    let sources = [SIGINT, SIGTERM].map { signalNumber in
      Darwin.signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: DispatchQueue.global()
      )
      source.setEventHandler { task.cancel() }
      source.resume()
      return source
    }
    defer {
      for source in sources { source.cancel() }
    }
    do {
      exit(try await task.value)
    } catch let error as HerdrHostError {
      FileHandle.standardError.write(Data("JIDOKA_HERDR_HOST_\(error.code)\n".utf8))
      exit(EX_SOFTWARE)
    } catch {
      FileHandle.standardError.write(Data("JIDOKA_HERDR_HOST_FAILED\n".utf8))
      exit(EX_SOFTWARE)
    }
  }
}
