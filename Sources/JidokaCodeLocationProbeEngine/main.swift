import Darwin
import Foundation
import JidokaCodeCore
import JidokaCodeLocationProbeSupport

private struct LocationProbePaths {
  let applicationURL: URL
  let executableURL: URL

  static func current() throws -> LocationProbePaths {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
    guard length > 0 else {
      throw LocationProbeError.invalidBundle
    }
    let end = buffer.firstIndex(of: 0) ?? Int(length)
    let executablePath = String(
      decoding: buffer[..<end].map(UInt8.init(bitPattern:)),
      as: UTF8.self
    )
    let executableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
      .resolvingSymlinksInPath().standardizedFileURL
    let helpers = executableURL.deletingLastPathComponent()
    guard helpers.lastPathComponent == "Helpers",
      executableURL.lastPathComponent == LocationProbeConstants.helperExecutableName
    else {
      throw LocationProbeError.invalidBundle
    }
    let contents = helpers.deletingLastPathComponent()
    let applicationURL = contents.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL
    guard applicationURL.pathExtension == "app",
      let bundle = Bundle(url: applicationURL),
      bundle.bundleIdentifier == LocationProbeConstants.applicationIdentifier
    else {
      throw LocationProbeError.invalidBundle
    }
    return LocationProbePaths(applicationURL: applicationURL, executableURL: executableURL)
  }
}

private final class LocationProbeService: NSObject, LocationProbeXPCProtocol,
  @unchecked Sendable
{
  private let paths: LocationProbePaths

  init(paths: LocationProbePaths) {
    self.paths = paths
  }

  func handle(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
    do {
      let request = try JSONDecoder().decode(LocationProbeRequest.self, from: requestData)
      try request.validate()
      let response = LocationProbeResponse(
        operation: request.operation,
        nonce: request.nonce,
        helperProcessID: ProcessInfo.processInfo.processIdentifier,
        helperExecutablePath: paths.executableURL.path,
        containingApplicationPath: paths.applicationURL.path
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      reply(try encoder.encode(response), nil)
      if request.operation == .shutdown {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
          exit(EXIT_SUCCESS)
        }
      }
    } catch {
      reply(nil, "LOCATION_PROBE_INVALID_REQUEST")
    }
  }
}

private final class LocationProbeListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  private let peerValidator: EngineXPCPeerValidator
  private let service: LocationProbeService

  init(paths: LocationProbePaths) {
    peerValidator = EngineXPCPeerValidator(helperExecutableURL: paths.executableURL)
    service = LocationProbeService(paths: paths)
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard
      peerValidator.accepts(
        processID: newConnection.processIdentifier,
        effectiveUserID: newConnection.effectiveUserIdentifier
      )
    else {
      newConnection.invalidate()
      return false
    }
    newConnection.exportedInterface = NSXPCInterface(with: LocationProbeXPCProtocol.self)
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

@main
private struct JidokaCodeLocationProbeEngine {
  static func main() {
    do {
      guard Array(CommandLine.arguments.dropFirst()) == ["--service"] else {
        throw LocationProbeError.invalidArguments
      }
      let paths = try LocationProbePaths.current()
      let delegate = LocationProbeListenerDelegate(paths: paths)
      let listener = NSXPCListener(
        machServiceName: LocationProbeConstants.helperIdentifier
      )
      listener.delegate = delegate
      listener.resume()
      withExtendedLifetime([delegate, listener]) {
        dispatchMain()
      }
    } catch {
      FileHandle.standardError.write(Data("location probe engine failed: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
