import Foundation

public actor EngineXPCMessageHandler {
  private let client: any EngineClient
  private let allowedCommands: Set<EngineCommandKind>

  public init(
    client: any EngineClient,
    allowedCommands: Set<EngineCommandKind> = Set(EngineCommandKind.allCases)
  ) {
    self.client = client
    self.allowedCommands = allowedCommands
  }

  public func handle(_ requestData: Data) async -> Data {
    let request: EngineXPCRequest
    do {
      request = try JSONDecoder().decode(EngineXPCRequest.self, from: requestData)
    } catch {
      return encode(
        EngineXPCResponse(
          requestID: "invalid",
          error: EngineClientError(.invalidRequest)
        )
      )
    }
    do {
      try request.validate()
      guard allowedCommands.contains(request.command.kind) else {
        throw EngineClientError(.invalidCommand)
      }
      let result = try await client.send(request.command)
      return encode(EngineXPCResponse(requestID: request.requestID, result: result))
    } catch let error as EngineClientError {
      return encode(EngineXPCResponse(requestID: request.requestID, error: error))
    } catch {
      return encode(
        EngineXPCResponse(
          requestID: request.requestID,
          error: EngineClientError(.internalFailure)
        )
      )
    }
  }

  private func encode(_ response: EngineXPCResponse) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(response)) ?? Data()
  }
}
