import Foundation

public enum LocationProbeConstants {
  public static let applicationIdentifier = "com.maroffo.JidokaCode.LocationProbe"
  public static let helperIdentifier = "com.maroffo.JidokaCode.LocationProbe.Engine"
  public static let packageIdentifier = "com.maroffo.JidokaCode.LocationProbe.pkg"
  public static let launchAgentPlistName =
    "com.maroffo.JidokaCode.LocationProbe.Engine.plist"
  public static let mainExecutableName = "Jidoka Code"
  public static let helperExecutableName = "JidokaCodeLocationProbeEngine"
  public static let quitNotification = "com.maroffo.JidokaCode.LocationProbe.quit"
  public static let protocolVersion = 1
}

public enum LocationProbeOperation: String, Codable, Sendable {
  case roundTrip
  case shutdown
}

public struct LocationProbeRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let operation: LocationProbeOperation
  public let nonce: String

  public init(operation: LocationProbeOperation, nonce: String) {
    protocolVersion = LocationProbeConstants.protocolVersion
    self.operation = operation
    self.nonce = nonce
  }

  public func validate() throws {
    guard protocolVersion == LocationProbeConstants.protocolVersion,
      nonce.range(
        of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression
      ) != nil
    else {
      throw LocationProbeError.invalidRequest
    }
  }
}

public struct LocationProbeResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let operation: LocationProbeOperation
  public let nonce: String
  public let helperProcessID: Int32
  public let helperExecutablePath: String
  public let containingApplicationPath: String

  public init(
    operation: LocationProbeOperation,
    nonce: String,
    helperProcessID: Int32,
    helperExecutablePath: String,
    containingApplicationPath: String
  ) {
    protocolVersion = LocationProbeConstants.protocolVersion
    self.operation = operation
    self.nonce = nonce
    self.helperProcessID = helperProcessID
    self.helperExecutablePath = helperExecutablePath
    self.containingApplicationPath = containingApplicationPath
  }

  public func validate(
    for request: LocationProbeRequest,
    expectedApplicationPath: String,
    expectedHelperPath: String,
    expectedHelperProcessID: Int32
  ) throws {
    guard protocolVersion == request.protocolVersion,
      operation == request.operation,
      nonce == request.nonce,
      expectedHelperProcessID > 0,
      helperProcessID == expectedHelperProcessID,
      helperExecutablePath == expectedHelperPath,
      containingApplicationPath == expectedApplicationPath
    else {
      throw LocationProbeError.invalidResponse
    }
  }
}

public enum LocationProbeError: Error, Equatable, Sendable {
  case invalidArguments
  case invalidBundle
  case invalidRequest
  case invalidResponse
  case remoteFailure(String)
  case timeout
}

@objc public protocol LocationProbeXPCProtocol {
  func handle(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}
