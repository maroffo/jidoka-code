import Darwin
import Foundation
import JidokaCodeCore

private struct EngineProbeReport: Codable {
  let identifier: String
  let status: String
  let workingDirectory: String
}

private final class LifecycleEventRecorder: @unchecked Sendable {
  private let fileURL: URL
  private let lock = NSLock()
  private var nextSequence = 0

  init() throws {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/JidokaCode/Spike/S2", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    fileURL = directoryURL.appendingPathComponent("helper-events.jsonl", isDirectory: false)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      guard
        FileManager.default.createFile(
          atPath: fileURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw LifecycleProbeError.remoteFailure("cannot create lifecycle event log")
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func record(_ kind: LifecycleEventKind, snapshot: EngineSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    let event = LifecycleEvent(
      event: kind,
      generation: snapshot.generation,
      launchID: snapshot.launchID,
      pid: snapshot.pid,
      sequence: nextSequence
    )
    nextSequence += 1
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(event)
    data.append(0x0A)
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }
}

private final class EngineProbeService: NSObject, EngineProbeXPCProtocol, @unchecked Sendable {
  private let recorder: LifecycleEventRecorder
  private let snapshotValue: EngineSnapshot

  init(generation: Int, recorder: LifecycleEventRecorder) {
    snapshotValue = EngineSnapshot(
      generation: generation,
      launchID: UUID().uuidString.lowercased(),
      pid: ProcessInfo.processInfo.processIdentifier,
      reconciled: true,
      topology: .helper
    )
    self.recorder = recorder
  }

  func reconcileBeforeListening() throws {
    try recorder.record(.reconciliation, snapshot: snapshotValue)
  }

  func handle(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
    do {
      let request = try JSONDecoder().decode(EngineProbeXPCRequest.self, from: requestData)
      try request.validate()
      try recorder.record(.dispatch, snapshot: snapshotValue)

      let roundTrip: EngineRoundTripResponse?
      if let requestRoundTrip = request.roundTrip {
        roundTrip = EngineRoundTripResponse(
          requestID: requestRoundTrip.requestID,
          sequence: requestRoundTrip.sequence,
          snapshot: snapshotValue
        )
      } else {
        roundTrip = nil
      }
      let keychainSHA256: String?
      if request.operation == .keychainDigest {
        keychainSHA256 = try KeychainProbeStore().readDigest().sentinelSHA256
      } else {
        keychainSHA256 = nil
      }
      let response = EngineProbeXPCResponse(
        operation: request.operation,
        keychainSHA256: keychainSHA256,
        roundTrip: roundTrip,
        snapshot: snapshotValue
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      reply(try encoder.encode(response), nil)

      switch request.operation {
      case .crash:
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
          exit(EXIT_FAILURE)
        }
      case .gracefulQuit:
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
          exit(EXIT_SUCCESS)
        }
      case .snapshot, .roundTrip, .keychainDigest:
        break
      }
    } catch {
      reply(nil, String(describing: error))
    }
  }
}

private final class EngineProbeListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  private let service: EngineProbeService

  init(service: EngineProbeService) {
    self.service = service
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: EngineProbeXPCProtocol.self)
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

private func runOneShotProbe() throws -> Never {
  let report = EngineProbeReport(
    identifier: LifecycleProbeConstants.helperIdentifier,
    status: "ok",
    workingDirectory: FileManager.default.currentDirectoryPath
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
  exit(EXIT_SUCCESS)
}

private func runService(arguments: [String]) throws -> Never {
  let configuration = try EngineServiceArguments.parse(arguments)
  let recorder = try LifecycleEventRecorder()
  let service = EngineProbeService(generation: configuration.generation, recorder: recorder)
  try service.reconcileBeforeListening()
  let delegate = EngineProbeListenerDelegate(service: service)
  let listener = NSXPCListener(machServiceName: LifecycleProbeConstants.helperIdentifier)
  listener.delegate = delegate
  listener.resume()
  RunLoop.current.run()
  exit(EXIT_FAILURE)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--probe"] {
    try runOneShotProbe()
  }
  if arguments.first == "--service" {
    try runService(arguments: arguments)
  }
  throw LifecycleProbeError.invalidArguments
} catch {
  FileHandle.standardError.write(Data("engine probe failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
