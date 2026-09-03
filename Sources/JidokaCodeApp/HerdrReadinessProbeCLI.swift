import Foundation
import JidokaCodeCore

private enum HerdrReadinessProbeCLIError: Error, CustomStringConvertible {
  case invalidBundle
  case probeFailed(String)
  case timedOut

  var description: String {
    switch self {
    case .invalidBundle: return "INVALID_BUNDLE"
    case .probeFailed(let detail): return "PROBE_FAILED: \(detail)"
    case .timedOut: return "TIMED_OUT"
    }
  }
}

enum HerdrReadinessProbeCLI {
  static func run() throws -> HerdrRuntimeReadinessProbeReport {
    guard let resources = Bundle.main.resourceURL else {
      throw HerdrReadinessProbeCLIError.invalidBundle
    }
    let releaseRuntime = resources.appendingPathComponent(
      ReleaseOwnedPiRuntimeResolver.runtimeDirectoryName,
      isDirectory: true
    )
    let herdrResources = resources.appendingPathComponent("Herdr", isDirectory: true)
    guard FileManager.default.fileExists(atPath: releaseRuntime.path),
      FileManager.default.fileExists(atPath: herdrResources.path)
    else {
      throw HerdrReadinessProbeCLIError.invalidBundle
    }
    let socket = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
    let probe = try HerdrRuntimeReadinessProbe(
      releaseRuntimeRoot: releaseRuntime,
      containingApplicationURL: Bundle.main.bundleURL,
      herdrResourceRoot: herdrResources,
      socketURL: socket
    )
    return try inspect(probe)
  }

  static func write(_ report: HerdrRuntimeReadinessProbeReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  private static func inspect(
    _ probe: HerdrRuntimeReadinessProbe
  ) throws -> HerdrRuntimeReadinessProbeReport {
    let result = HerdrReadinessProbeResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task.detached {
      do {
        result.store(.success(try await probe.inspect()))
      } catch {
        result.store(.failure(.probeFailed(String(describing: error))))
      }
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .seconds(30)) == .success else {
      task.cancel()
      throw HerdrReadinessProbeCLIError.timedOut
    }
    guard let value = result.load() else {
      throw HerdrReadinessProbeCLIError.probeFailed("probe returned no result")
    }
    return try value.get()
  }
}

private final class HerdrReadinessProbeResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<HerdrRuntimeReadinessProbeReport, HerdrReadinessProbeCLIError>?

  func store(
    _ value: Result<HerdrRuntimeReadinessProbeReport, HerdrReadinessProbeCLIError>
  ) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func load() -> Result<HerdrRuntimeReadinessProbeReport, HerdrReadinessProbeCLIError>? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
