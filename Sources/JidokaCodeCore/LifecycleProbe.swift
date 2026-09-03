import Foundation

public enum LifecycleProbeConstants {
  public static let appBundleIdentifier = "com.maroffo.JidokaCode"
  public static let helperIdentifier = "com.maroffo.JidokaCode.Engine"
  public static let launchAgentPlistName = "com.maroffo.JidokaCode.Engine.plist"
  public static let maximumRoundTrips = 1_000
  public static let mainQuitNotification = "com.maroffo.JidokaCode.lifecycle.quit"
}

package final class EngineServiceLifetime: @unchecked Sendable {
  private let retainedObjects: [AnyObject]
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  package init(retaining retainedObjects: [AnyObject]) {
    let pair = AsyncStream<Void>.makeStream()
    self.retainedObjects = retainedObjects
    stream = pair.stream
    continuation = pair.continuation
  }

  package func wait() async {
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
    withExtendedLifetime(retainedObjects) {}
  }
}

public enum EngineTopology: String, Codable, Sendable {
  case direct
  case helper
}

public enum LifecycleTopologyGate {
  public static func eligibleTopologies(
    directPassed: Bool,
    helperPassed: Bool
  ) throws -> [EngineTopology] {
    let eligible = [
      directPassed ? EngineTopology.direct : nil,
      helperPassed ? EngineTopology.helper : nil,
    ].compactMap { $0 }
    guard !eligible.isEmpty else {
      throw LifecycleProbeError.noEligibleTopology
    }
    return eligible
  }
}

public struct EngineRoundTripRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let sequence: Int

  public init(requestID: String, sequence: Int) {
    self.requestID = requestID
    self.sequence = sequence
  }
}

public struct EngineSnapshot: Codable, Equatable, Sendable {
  public let generation: Int
  public let launchID: String
  public let pid: Int32
  public let reconciled: Bool
  public let topology: EngineTopology

  public init(
    generation: Int,
    launchID: String,
    pid: Int32,
    reconciled: Bool,
    topology: EngineTopology
  ) {
    self.generation = generation
    self.launchID = launchID
    self.pid = pid
    self.reconciled = reconciled
    self.topology = topology
  }
}

public struct EngineRoundTripResponse: Codable, Equatable, Sendable {
  public let requestID: String
  public let sequence: Int
  public let snapshot: EngineSnapshot

  public init(requestID: String, sequence: Int, snapshot: EngineSnapshot) {
    self.requestID = requestID
    self.sequence = sequence
    self.snapshot = snapshot
  }
}

public struct EngineRoundTripReport: Codable, Equatable, Sendable {
  public let count: Int
  public let duplicateCount: Int
  public let ordered: Bool
  public let snapshot: EngineSnapshot

  public init(count: Int, duplicateCount: Int, ordered: Bool, snapshot: EngineSnapshot) {
    self.count = count
    self.duplicateCount = duplicateCount
    self.ordered = ordered
    self.snapshot = snapshot
  }
}

public enum LifecycleProbeError: Error, Equatable, Sendable {
  case invalidArguments
  case invalidRoundTripCount(Int)
  case invalidRequest
  case invalidResponse
  case duplicateResponse(String)
  case unorderedResponse(expected: Int, actual: Int)
  case unsupportedOperation(String)
  case remoteFailure(String)
  case timeout
  case noEligibleTopology
}

public protocol LifecycleProbeClient: Sendable {
  func snapshot() throws -> EngineSnapshot
  func roundTrip(_ request: EngineRoundTripRequest) throws -> EngineRoundTripResponse
}

extension LifecycleProbeClient {
  public func run(roundTrips count: Int) throws -> EngineRoundTripReport {
    guard (1...LifecycleProbeConstants.maximumRoundTrips).contains(count) else {
      throw LifecycleProbeError.invalidRoundTripCount(count)
    }

    var responseIDs = Set<String>()
    var lastSnapshot: EngineSnapshot?
    for sequence in 0..<count {
      let request = EngineRoundTripRequest(
        requestID: "jidoka-lifecycle-\(sequence)", sequence: sequence)
      let response = try roundTrip(request)
      guard response.requestID == request.requestID else {
        throw LifecycleProbeError.invalidResponse
      }
      guard response.sequence == sequence else {
        throw LifecycleProbeError.unorderedResponse(
          expected: sequence, actual: response.sequence)
      }
      guard response.snapshot.reconciled else {
        throw LifecycleProbeError.invalidResponse
      }
      guard responseIDs.insert(response.requestID).inserted else {
        throw LifecycleProbeError.duplicateResponse(response.requestID)
      }
      lastSnapshot = response.snapshot
    }

    guard let lastSnapshot else {
      throw LifecycleProbeError.invalidRoundTripCount(count)
    }
    return EngineRoundTripReport(
      count: count,
      duplicateCount: count - responseIDs.count,
      ordered: true,
      snapshot: lastSnapshot
    )
  }
}

public struct DirectEngineClient: LifecycleProbeClient {
  private let currentSnapshot: EngineSnapshot

  public init(
    launchID: String = UUID().uuidString.lowercased(),
    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
    generation: Int = 1
  ) {
    currentSnapshot = EngineSnapshot(
      generation: generation,
      launchID: launchID,
      pid: pid,
      reconciled: true,
      topology: .direct
    )
  }

  public func snapshot() -> EngineSnapshot {
    currentSnapshot
  }

  public func roundTrip(_ request: EngineRoundTripRequest) throws -> EngineRoundTripResponse {
    guard request.sequence >= 0, request.requestID == "jidoka-lifecycle-\(request.sequence)" else {
      throw LifecycleProbeError.invalidRequest
    }
    return EngineRoundTripResponse(
      requestID: request.requestID,
      sequence: request.sequence,
      snapshot: currentSnapshot
    )
  }
}

public enum LifecycleServiceStatus: String, Codable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound

  public init(rawServiceManagementValue: Int) throws {
    switch rawServiceManagementValue {
    case 0: self = .notRegistered
    case 1: self = .enabled
    case 2: self = .requiresApproval
    case 3: self = .notFound
    default: throw LifecycleProbeError.invalidResponse
    }
  }
}

public enum LifecycleCommand: Equatable, Sendable {
  case mainStatus
  case mainRegister
  case mainUnregister
  case mainGracefulQuit
  case agentStatus
  case agentRegister
  case agentUnregister
  case directRoundTrips(Int)
  case helperSnapshot
  case helperRoundTrips(Int)
  case helperCrash
  case helperGracefulQuit
  case helperKeychainDigest

  public static func parse(_ arguments: [String]) throws -> LifecycleCommand {
    switch arguments {
    case ["main", "status"]: return .mainStatus
    case ["main", "register"]: return .mainRegister
    case ["main", "unregister"]: return .mainUnregister
    case ["main", "graceful-quit"]: return .mainGracefulQuit
    case ["agent", "status"]: return .agentStatus
    case ["agent", "register"]: return .agentRegister
    case ["agent", "unregister"]: return .agentUnregister
    case ["helper", "snapshot"]: return .helperSnapshot
    case ["helper", "crash"]: return .helperCrash
    case ["helper", "graceful-quit"]: return .helperGracefulQuit
    case ["helper", "keychain-digest"]: return .helperKeychainDigest
    default:
      guard arguments.count == 3, arguments[1] == "round-trips" else {
        throw LifecycleProbeError.invalidArguments
      }
      switch arguments[0] {
      case "direct": return .directRoundTrips(try parseCount(arguments[2]))
      case "helper": return .helperRoundTrips(try parseCount(arguments[2]))
      default: throw LifecycleProbeError.invalidArguments
      }
    }
  }

  private static func parseCount(_ value: String) throws -> Int {
    guard let count = Int(value), (1...LifecycleProbeConstants.maximumRoundTrips).contains(count)
    else {
      throw LifecycleProbeError.invalidArguments
    }
    return count
  }
}

public struct EngineServiceArguments: Equatable, Sendable {
  public let generation: Int

  public static func parse(_ arguments: [String]) throws -> EngineServiceArguments {
    guard arguments.count == 3,
      arguments[0] == "--service",
      arguments[1] == "--generation",
      let generation = Int(arguments[2]),
      generation > 0
    else {
      throw LifecycleProbeError.invalidArguments
    }
    return EngineServiceArguments(generation: generation)
  }
}

public enum EngineProbeXPCOperation: String, Codable, Sendable {
  case snapshot
  case roundTrip
  case crash
  case gracefulQuit
  case keychainDigest
}

public struct EngineProbeXPCRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let operation: EngineProbeXPCOperation
  public let roundTrip: EngineRoundTripRequest?

  public init(
    protocolVersion: Int = LifecycleProbeProtocolVersion.current,
    operation: EngineProbeXPCOperation,
    roundTrip: EngineRoundTripRequest? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.operation = operation
    self.roundTrip = roundTrip
  }

  public func validate() throws {
    guard protocolVersion == LifecycleProbeProtocolVersion.current else {
      throw LifecycleProbeError.invalidRequest
    }
    switch operation {
    case .roundTrip:
      guard let roundTrip,
        roundTrip.sequence >= 0,
        roundTrip.requestID == "jidoka-lifecycle-\(roundTrip.sequence)"
      else {
        throw LifecycleProbeError.invalidRequest
      }
    case .snapshot, .crash, .gracefulQuit, .keychainDigest:
      guard roundTrip == nil else {
        throw LifecycleProbeError.invalidRequest
      }
    }
  }
}

public struct EngineProbeXPCResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let keychainSHA256: String?
  public let operation: EngineProbeXPCOperation
  public let roundTrip: EngineRoundTripResponse?
  public let snapshot: EngineSnapshot

  public init(
    protocolVersion: Int = LifecycleProbeProtocolVersion.current,
    operation: EngineProbeXPCOperation,
    keychainSHA256: String? = nil,
    roundTrip: EngineRoundTripResponse? = nil,
    snapshot: EngineSnapshot
  ) {
    self.protocolVersion = protocolVersion
    self.keychainSHA256 = keychainSHA256
    self.operation = operation
    self.roundTrip = roundTrip
    self.snapshot = snapshot
  }

  public func validate(for request: EngineProbeXPCRequest) throws {
    guard protocolVersion == request.protocolVersion,
      protocolVersion == LifecycleProbeProtocolVersion.current,
      operation == request.operation,
      snapshot.reconciled,
      snapshot.topology == .helper
    else {
      throw LifecycleProbeError.invalidResponse
    }
    switch request.operation {
    case .roundTrip:
      guard keychainSHA256 == nil,
        let requestRoundTrip = request.roundTrip,
        let responseRoundTrip = roundTrip,
        responseRoundTrip.requestID == requestRoundTrip.requestID,
        responseRoundTrip.sequence == requestRoundTrip.sequence,
        responseRoundTrip.snapshot == snapshot
      else {
        throw LifecycleProbeError.invalidResponse
      }
    case .snapshot, .crash, .gracefulQuit:
      guard keychainSHA256 == nil, roundTrip == nil else {
        throw LifecycleProbeError.invalidResponse
      }
    case .keychainDigest:
      guard roundTrip == nil,
        let keychainSHA256,
        KeychainProbeDigest.isValidSHA256(keychainSHA256)
      else {
        throw LifecycleProbeError.invalidResponse
      }
    }
  }
}

@objc public protocol EngineProbeXPCProtocol {
  func handle(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public enum LifecycleEventKind: String, Codable, Sendable {
  case reconciliation
  case dispatch
}

public struct LifecycleEvent: Codable, Equatable, Sendable {
  public let event: LifecycleEventKind
  public let generation: Int
  public let launchID: String
  public let pid: Int32
  public let sequence: Int

  public init(
    event: LifecycleEventKind,
    generation: Int,
    launchID: String,
    pid: Int32,
    sequence: Int
  ) {
    self.event = event
    self.generation = generation
    self.launchID = launchID
    self.pid = pid
    self.sequence = sequence
  }

  public static func launchSequence(snapshot: EngineSnapshot) -> [LifecycleEvent] {
    [
      LifecycleEvent(
        event: .reconciliation,
        generation: snapshot.generation,
        launchID: snapshot.launchID,
        pid: snapshot.pid,
        sequence: 0
      )
    ]
  }
}
