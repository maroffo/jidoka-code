import CryptoKit
import Foundation

public enum PiJSONValue: Equatable, Sendable {
  case object([String: PiJSONValue])
  case array([PiJSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  public var objectValue: [String: PiJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [PiJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var integerValue: Int64? {
    guard case .integer(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> PiJSONValue? {
    objectValue?[key]
  }
}

extension PiJSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([PiJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: PiJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct PiRPCRecord: Equatable, Sendable {
  public let object: [String: PiJSONValue]
  public let rawSHA256: String

  public var type: String? { object["type"]?.stringValue }
  public var id: String? { object["id"]?.stringValue }

  public init(object: [String: PiJSONValue], rawSHA256: String) {
    self.object = object
    self.rawSHA256 = rawSHA256
  }
}

public enum PiRPCProtocolError: Error, Equatable, Sendable {
  case invalidLimits
  case emptyRecord
  case recordTooLarge
  case invalidUTF8
  case malformedJSON
  case topLevelNotObject
  case unterminatedRecord
  case duplicateRequestID
  case unknownResponseID
  case duplicateResponseID
  case responseCommandMismatch
  case responseFailed(String)
  case invalidEvent
  case eventAfterSettled
  case extensionError
  case automaticContinuation
  case multipleTerminalResults
  case invalidTerminalResult
  case missingPromptAcceptance
  case missingAgentEnd
  case missingAgentSettled
  case missingTerminalResult
}

public struct PiRPCJSONLParser: Sendable {
  private var buffer = Data()
  private let maximumRecordBytes: Int

  public init(maximumRecordBytes: Int = 1_048_576) throws {
    guard (64...16 * 1_024 * 1_024).contains(maximumRecordBytes) else {
      throw PiRPCProtocolError.invalidLimits
    }
    self.maximumRecordBytes = maximumRecordBytes
  }

  public mutating func append(_ chunk: Data) throws -> [PiRPCRecord] {
    guard !chunk.isEmpty else { return [] }
    buffer.append(chunk)
    var records: [PiRPCRecord] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if line.last == 0x0D { line.removeLast() }
      guard !line.isEmpty else { throw PiRPCProtocolError.emptyRecord }
      guard line.count <= maximumRecordBytes else { throw PiRPCProtocolError.recordTooLarge }
      guard String(data: line, encoding: .utf8) != nil else {
        throw PiRPCProtocolError.invalidUTF8
      }
      let value: PiJSONValue
      do {
        value = try JSONDecoder().decode(PiJSONValue.self, from: line)
      } catch {
        throw PiRPCProtocolError.malformedJSON
      }
      guard case .object(let object) = value else {
        throw PiRPCProtocolError.topLevelNotObject
      }
      records.append(
        PiRPCRecord(
          object: object,
          rawSHA256: SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
        )
      )
    }
    guard buffer.count <= maximumRecordBytes else { throw PiRPCProtocolError.recordTooLarge }
    return records
  }

  public mutating func finish() throws {
    guard buffer.isEmpty else { throw PiRPCProtocolError.unterminatedRecord }
  }
}

public struct PiRPCCommandProvenance: Equatable, Sendable {
  public let name: String
  public let source: String
  public let path: String
  public let scope: String
  public let origin: String

  public init(name: String, source: String, path: String, scope: String, origin: String) {
    self.name = name
    self.source = source
    self.path = path
    self.scope = scope
    self.origin = origin
  }
}

public struct PiRPCSessionExpectation: Equatable, Sendable {
  public let provider: String
  public let modelID: String
  public let thinkingLevel: String
  public let commands: [PiRPCCommandProvenance]

  public init(
    provider: String,
    modelID: String,
    thinkingLevel: String,
    commands: [PiRPCCommandProvenance]
  ) {
    self.provider = provider
    self.modelID = modelID
    self.thinkingLevel = thinkingLevel
    self.commands = commands
  }
}

public struct PiRPCTerminalResultIdentity: Equatable, Sendable {
  public let workflow: String
  public let role: String
  public let nonce: String
  public let artifactSHA256: String
  public let allowedCommandIDs: Set<String>

  public init(
    workflow: String,
    role: String,
    nonce: String,
    artifactSHA256: String,
    allowedCommandIDs: Set<String>
  ) {
    self.workflow = workflow
    self.role = role
    self.nonce = nonce
    self.artifactSHA256 = artifactSHA256
    self.allowedCommandIDs = allowedCommandIDs
  }
}

public struct PiRPCTerminalResult: Equatable, Sendable {
  public let workflow: String
  public let role: String
  public let nonce: String
  public let artifactSHA256: String
  public let approvedCommandIDs: [String]
  public let payload: [String: PiJSONValue]
  public let recordSHA256: String
  public let sessionBoundarySHA256: String?

  public init(
    workflow: String,
    role: String,
    nonce: String,
    artifactSHA256: String,
    approvedCommandIDs: [String],
    payload: [String: PiJSONValue],
    recordSHA256: String,
    sessionBoundarySHA256: String? = nil
  ) {
    self.workflow = workflow
    self.role = role
    self.nonce = nonce
    self.artifactSHA256 = artifactSHA256
    self.approvedCommandIDs = approvedCommandIDs
    self.payload = payload
    self.recordSHA256 = recordSHA256
    self.sessionBoundarySHA256 = sessionBoundarySHA256
  }
}

public struct PiRPCResponse: Equatable, Sendable {
  public let id: String
  public let command: String
  public let success: Bool
  public let data: [String: PiJSONValue]?

  public init(id: String, command: String, success: Bool, data: [String: PiJSONValue]?) {
    self.id = id
    self.command = command
    self.success = success
    self.data = data
  }
}

private enum AgentLifecyclePhase: Equatable, Sendable {
  case awaitingAgentStart
  case awaitingInitialTurnStart
  case awaitingInitialUserMessageStart
  case awaitingInitialUserMessageEnd
  case awaitingAssistantMessageStart
  case assistantMessage
  case afterAssistantMessage
  case toolExecution
  case awaitingNextTurnStart
}

private enum TerminalSuffixPhase: Sendable {
  case none
  case toolResultMessageStart
  case toolResultMessageEnd
  case turnEnd
  case agentEnd
  case agentSettled
  case complete
}

public struct PiRPCConversation: Sendable {
  private let terminalIdentity: PiRPCTerminalResultIdentity
  private let allowedToolNames: Set<String>
  private var pendingRequests: [String: String] = [:]
  private var responses: [String: PiRPCResponse] = [:]
  private var completedRequestIDs: Set<String> = []
  private var promptAccepted = false
  private var lifecyclePhase: AgentLifecyclePhase = .awaitingAgentStart
  private var activeToolCalls: [String: String] = [:]
  private var turnToolCalls: [String: String] = [:]
  private var pendingToolResultMessages: [String: String] = [:]
  private var openToolResultMessageID: String?
  private var turnToolCallCount = 0
  private var terminalSuffixPhase: TerminalSuffixPhase = .none
  private var terminalToolCallID: String?
  private var agentEndCount = 0
  private var agentSettledCount = 0
  private var terminalResult: PiRPCTerminalResult?

  public init(
    terminalIdentity: PiRPCTerminalResultIdentity,
    allowedToolNames: [String] = ["jidoka_code_result"]
  ) {
    self.terminalIdentity = terminalIdentity
    self.allowedToolNames = Set(allowedToolNames)
  }

  public mutating func registerRequest(id: String, command: String) throws {
    guard !id.isEmpty, !command.isEmpty,
      pendingRequests[id] == nil,
      !completedRequestIDs.contains(id)
    else {
      throw PiRPCProtocolError.duplicateRequestID
    }
    pendingRequests[id] = command
  }

  public mutating func consume(_ record: PiRPCRecord) throws {
    guard let type = record.type else { throw PiRPCProtocolError.invalidEvent }
    if type == "response" {
      try consumeResponse(record)
      return
    }
    guard agentSettledCount == 0 else { throw PiRPCProtocolError.eventAfterSettled }
    guard promptAccepted else { throw PiRPCProtocolError.missingPromptAcceptance }
    if terminalResult != nil,
      type == "tool_execution_end",
      record.object["toolName"]?.stringValue == "jidoka_code_result"
    {
      throw PiRPCProtocolError.multipleTerminalResults
    }
    if terminalResult != nil {
      try consumeTerminalSuffix(record, type: type)
      return
    }
    if agentEndCount > 0, type != "agent_settled" {
      throw PiRPCProtocolError.invalidEvent
    }
    switch type {
    case "agent_start":
      guard lifecyclePhase == .awaitingAgentStart else {
        throw PiRPCProtocolError.invalidEvent
      }
      lifecyclePhase = .awaitingInitialTurnStart
    case "turn_start":
      try consumeTurnStart()
    case "message_start":
      try consumeMessageStart(record)
    case "message_end":
      try consumeMessageEnd(record)
    case "turn_end":
      try consumeTurnEnd(record)
    case "message_update":
      guard lifecyclePhase == .assistantMessage else {
        throw PiRPCProtocolError.invalidEvent
      }
      try validateMessageUpdate(record.object)
    case "tool_execution_start":
      guard
        lifecyclePhase == .afterAssistantMessage
          || lifecyclePhase == .toolExecution,
        openToolResultMessageID == nil
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      lifecyclePhase = .toolExecution
      try consumeToolStart(record)
    case "tool_execution_update":
      guard lifecyclePhase == .toolExecution,
        openToolResultMessageID == nil
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      try consumeToolUpdate(record)
    case "tool_execution_end":
      guard lifecyclePhase == .toolExecution,
        openToolResultMessageID == nil
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      try consumeToolEnd(record)
    case "agent_end":
      throw PiRPCProtocolError.automaticContinuation
    case "agent_settled", "queue_update", "extension_ui_request":
      throw PiRPCProtocolError.invalidEvent
    case "extension_error":
      throw PiRPCProtocolError.extensionError
    case "auto_retry_start", "auto_retry_end", "compaction_start", "compaction_end",
      "summarization_retry_scheduled", "summarization_retry_attempt_start",
      "summarization_retry_finished":
      throw PiRPCProtocolError.automaticContinuation
    default:
      throw PiRPCProtocolError.invalidEvent
    }
  }

  public mutating func takeResponse(id: String) -> PiRPCResponse? {
    responses.removeValue(forKey: id)
  }

  public mutating func markPromptAccepted(_ response: PiRPCResponse) throws {
    guard response.command == "prompt", response.success, promptAccepted else {
      throw PiRPCProtocolError.responseFailed(response.command)
    }
  }

  public func validatedTerminalResult() throws -> PiRPCTerminalResult {
    guard promptAccepted else { throw PiRPCProtocolError.missingPromptAcceptance }
    guard agentEndCount > 0 else { throw PiRPCProtocolError.missingAgentEnd }
    guard agentSettledCount == 1 else { throw PiRPCProtocolError.missingAgentSettled }
    guard let terminalResult else { throw PiRPCProtocolError.missingTerminalResult }
    return terminalResult
  }

  public var isSettled: Bool { agentSettledCount == 1 }

  private mutating func consumeResponse(_ record: PiRPCRecord) throws {
    guard agentSettledCount == 0 else { throw PiRPCProtocolError.eventAfterSettled }
    guard let id = record.id,
      let expectedCommand = pendingRequests.removeValue(forKey: id)
    else {
      if let id = record.id, completedRequestIDs.contains(id) {
        throw PiRPCProtocolError.duplicateResponseID
      }
      throw PiRPCProtocolError.unknownResponseID
    }
    guard let command = record.object["command"]?.stringValue,
      command == expectedCommand,
      let success = record.object["success"]?.boolValue
    else {
      throw PiRPCProtocolError.responseCommandMismatch
    }
    guard success else { throw PiRPCProtocolError.responseFailed(command) }
    let data = record.object["data"]?.objectValue
    if command == "prompt" {
      guard !promptAccepted, agentEndCount == 0, agentSettledCount == 0 else {
        throw PiRPCProtocolError.invalidEvent
      }
      promptAccepted = true
    }
    completedRequestIDs.insert(id)
    responses[id] = PiRPCResponse(id: id, command: command, success: success, data: data)
  }

  private mutating func consumeTurnStart() throws {
    guard activeToolCalls.isEmpty,
      pendingToolResultMessages.isEmpty,
      openToolResultMessageID == nil
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    switch lifecyclePhase {
    case .awaitingInitialTurnStart:
      lifecyclePhase = .awaitingInitialUserMessageStart
    case .awaitingNextTurnStart:
      lifecyclePhase = .awaitingAssistantMessageStart
    default:
      throw PiRPCProtocolError.invalidEvent
    }
    turnToolCalls.removeAll(keepingCapacity: true)
    turnToolCallCount = 0
  }

  private mutating func consumeMessageStart(_ record: PiRPCRecord) throws {
    guard let message = record.object["message"]?.objectValue,
      let role = message["role"]?.stringValue
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    switch lifecyclePhase {
    case .awaitingInitialUserMessageStart:
      guard role == "user" else { throw PiRPCProtocolError.invalidEvent }
      lifecyclePhase = .awaitingInitialUserMessageEnd
    case .awaitingAssistantMessageStart:
      guard role == "assistant" else { throw PiRPCProtocolError.invalidEvent }
      lifecyclePhase = .assistantMessage
    case .toolExecution:
      guard openToolResultMessageID == nil,
        role == "toolResult",
        let toolCallID = message["toolCallId"]?.stringValue,
        let toolName = pendingToolResultMessages[toolCallID],
        validToolMessage(record.object["message"], toolCallID: toolCallID, toolName: toolName)
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      openToolResultMessageID = toolCallID
    default:
      throw PiRPCProtocolError.invalidEvent
    }
  }

  private mutating func consumeMessageEnd(_ record: PiRPCRecord) throws {
    guard let message = record.object["message"]?.objectValue,
      let role = message["role"]?.stringValue
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    switch lifecyclePhase {
    case .awaitingInitialUserMessageEnd:
      guard role == "user" else { throw PiRPCProtocolError.invalidEvent }
      lifecyclePhase = .awaitingAssistantMessageStart
    case .assistantMessage:
      guard role == "assistant" else { throw PiRPCProtocolError.invalidEvent }
      lifecyclePhase = .afterAssistantMessage
    case .toolExecution:
      guard let toolCallID = openToolResultMessageID,
        let toolName = pendingToolResultMessages[toolCallID],
        validToolMessage(record.object["message"], toolCallID: toolCallID, toolName: toolName)
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      pendingToolResultMessages.removeValue(forKey: toolCallID)
      openToolResultMessageID = nil
    default:
      throw PiRPCProtocolError.invalidEvent
    }
  }

  private mutating func consumeTurnEnd(_ record: PiRPCRecord) throws {
    guard lifecyclePhase == .afterAssistantMessage || lifecyclePhase == .toolExecution,
      activeToolCalls.isEmpty,
      pendingToolResultMessages.isEmpty,
      openToolResultMessageID == nil,
      let toolResults = record.object["toolResults"]?.arrayValue,
      toolResults.count == turnToolCalls.count
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    var observedIDs: Set<String> = []
    for result in toolResults {
      guard let message = result.objectValue,
        let toolCallID = message["toolCallId"]?.stringValue,
        let toolName = turnToolCalls[toolCallID],
        validToolMessage(result, toolCallID: toolCallID, toolName: toolName),
        observedIDs.insert(toolCallID).inserted
      else {
        throw PiRPCProtocolError.invalidEvent
      }
    }
    lifecyclePhase = .awaitingNextTurnStart
    turnToolCalls.removeAll(keepingCapacity: true)
    turnToolCallCount = 0
  }

  private func validToolMessage(
    _ value: PiJSONValue?,
    toolCallID: String,
    toolName: String
  ) -> Bool {
    guard let message = value?.objectValue else { return false }
    return message["role"]?.stringValue == "toolResult"
      && message["toolCallId"]?.stringValue == toolCallID
      && message["toolName"]?.stringValue == toolName
      && message["isError"]?.boolValue == false
  }

  private func validateMessageUpdate(_ object: [String: PiJSONValue]) throws {
    guard let event = object["assistantMessageEvent"]?.objectValue,
      let type = event["type"]?.stringValue,
      [
        "text_start", "text_delta", "text_end", "thinking_start", "thinking_delta",
        "thinking_end", "toolcall_start", "toolcall_delta", "toolcall_end",
      ].contains(type),
      event["partial"] == nil,
      object["message"] == nil
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    if type.hasSuffix("_delta") {
      guard event["contentIndex"]?.integerValue != nil,
        event["delta"]?.stringValue != nil
      else {
        throw PiRPCProtocolError.invalidEvent
      }
    }
  }

  private mutating func consumeTerminalSuffix(
    _ record: PiRPCRecord,
    type: String
  ) throws {
    guard let toolCallID = terminalToolCallID else {
      throw PiRPCProtocolError.invalidEvent
    }
    switch terminalSuffixPhase {
    case .none, .complete:
      throw PiRPCProtocolError.invalidEvent
    case .toolResultMessageStart:
      guard type == "message_start",
        validTerminalToolMessage(record.object["message"], toolCallID: toolCallID)
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      terminalSuffixPhase = .toolResultMessageEnd
    case .toolResultMessageEnd:
      guard type == "message_end",
        validTerminalToolMessage(record.object["message"], toolCallID: toolCallID)
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      terminalSuffixPhase = .turnEnd
    case .turnEnd:
      guard type == "turn_end",
        let toolResults = record.object["toolResults"]?.arrayValue,
        toolResults.count == 1,
        validTerminalToolMessage(toolResults[0], toolCallID: toolCallID)
      else {
        throw PiRPCProtocolError.invalidEvent
      }
      terminalSuffixPhase = .agentEnd
    case .agentEnd:
      guard type == "agent_end",
        record.object["willRetry"]?.boolValue == false,
        activeToolCalls.isEmpty,
        agentEndCount == 0
      else {
        throw PiRPCProtocolError.automaticContinuation
      }
      agentEndCount = 1
      terminalSuffixPhase = .agentSettled
    case .agentSettled:
      guard type == "agent_settled", agentSettledCount == 0 else {
        throw PiRPCProtocolError.invalidEvent
      }
      agentSettledCount = 1
      terminalSuffixPhase = .complete
    }
  }

  private func validTerminalToolMessage(
    _ value: PiJSONValue?,
    toolCallID: String
  ) -> Bool {
    guard let message = value?.objectValue else { return false }
    return message["role"]?.stringValue == "toolResult"
      && message["toolCallId"]?.stringValue == toolCallID
      && message["toolName"]?.stringValue == "jidoka_code_result"
      && message["isError"]?.boolValue == false
  }

  private mutating func consumeToolStart(_ record: PiRPCRecord) throws {
    guard let toolName = record.object["toolName"]?.stringValue,
      allowedToolNames.contains(toolName),
      let toolCallID = record.object["toolCallId"]?.stringValue,
      !toolCallID.isEmpty,
      activeToolCalls[toolCallID] == nil,
      turnToolCalls[toolCallID] == nil
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    activeToolCalls[toolCallID] = toolName
    turnToolCalls[toolCallID] = toolName
    turnToolCallCount += 1
  }

  private func consumeToolUpdate(_ record: PiRPCRecord) throws {
    guard let toolName = record.object["toolName"]?.stringValue,
      allowedToolNames.contains(toolName),
      let toolCallID = record.object["toolCallId"]?.stringValue,
      activeToolCalls[toolCallID] == toolName
    else {
      throw PiRPCProtocolError.invalidEvent
    }
  }

  private mutating func consumeToolEnd(_ record: PiRPCRecord) throws {
    guard let toolName = record.object["toolName"]?.stringValue,
      allowedToolNames.contains(toolName),
      let toolCallID = record.object["toolCallId"]?.stringValue,
      activeToolCalls.removeValue(forKey: toolCallID) == toolName,
      record.object["isError"]?.boolValue == false
    else {
      throw PiRPCProtocolError.invalidEvent
    }
    guard toolName == "jidoka_code_result" else {
      pendingToolResultMessages[toolCallID] = toolName
      return
    }
    guard terminalResult == nil else { throw PiRPCProtocolError.multipleTerminalResults }
    guard turnToolCallCount == 1, activeToolCalls.isEmpty else {
      throw PiRPCProtocolError.invalidTerminalResult
    }
    guard record.object["isError"]?.boolValue == false,
      let result = record.object["result"]?.objectValue,
      let details = result["details"]?.objectValue
    else {
      throw PiRPCProtocolError.invalidTerminalResult
    }
    let expectedKeys: Set<String> = [
      "approvedCommandIDs",
      "artifactSHA256",
      "nonce",
      "payload",
      "resultSequence",
      "role",
      "schemaVersion",
      "workflow",
    ]
    guard Set(details.keys) == expectedKeys,
      details["schemaVersion"]?.integerValue == 1,
      details["resultSequence"]?.integerValue == 1,
      details["workflow"]?.stringValue == terminalIdentity.workflow,
      details["role"]?.stringValue == terminalIdentity.role,
      details["nonce"]?.stringValue == terminalIdentity.nonce,
      details["artifactSHA256"]?.stringValue == terminalIdentity.artifactSHA256,
      let commandValues = details["approvedCommandIDs"]?.arrayValue,
      let payload = details["payload"]?.objectValue
    else {
      throw PiRPCProtocolError.invalidTerminalResult
    }
    let commandIDs = commandValues.compactMap(\.stringValue)
    guard commandIDs.count == commandValues.count,
      Set(commandIDs).count == commandIDs.count,
      Set(commandIDs).isSubset(of: terminalIdentity.allowedCommandIDs)
    else {
      throw PiRPCProtocolError.invalidTerminalResult
    }
    terminalToolCallID = toolCallID
    terminalSuffixPhase = .toolResultMessageStart
    terminalResult = PiRPCTerminalResult(
      workflow: terminalIdentity.workflow,
      role: terminalIdentity.role,
      nonce: terminalIdentity.nonce,
      artifactSHA256: terminalIdentity.artifactSHA256,
      approvedCommandIDs: commandIDs,
      payload: payload,
      recordSHA256: record.rawSHA256
    )
  }
}

public enum PiRPCSessionValidation {
  public static func validateState(
    _ response: PiRPCResponse,
    expected: PiRPCSessionExpectation
  ) throws -> String {
    guard response.command == "get_state", response.success,
      let data = response.data,
      let model = data["model"]?.objectValue,
      model["provider"]?.stringValue == expected.provider,
      model["id"]?.stringValue == expected.modelID,
      data["thinkingLevel"]?.stringValue == expected.thinkingLevel,
      data["isStreaming"]?.boolValue == false,
      data["autoCompactionEnabled"]?.boolValue == false,
      let sessionID = data["sessionId"]?.stringValue,
      !sessionID.isEmpty,
      sessionID.utf8.count <= 128
    else {
      throw PiRPCProtocolError.responseFailed("get_state")
    }
    return sessionID
  }

  public static func validateCommands(
    _ response: PiRPCResponse,
    expected: PiRPCSessionExpectation
  ) throws {
    guard response.command == "get_commands", response.success,
      let commands = response.data?["commands"]?.arrayValue
    else {
      throw PiRPCProtocolError.responseFailed("get_commands")
    }
    let observed: [PiRPCCommandProvenance] = try commands.map { value in
      guard let command = value.objectValue,
        let name = command["name"]?.stringValue,
        let source = command["source"]?.stringValue,
        let sourceInfo = command["sourceInfo"]?.objectValue,
        let path = sourceInfo["path"]?.stringValue,
        let scope = sourceInfo["scope"]?.stringValue,
        let origin = sourceInfo["origin"]?.stringValue
      else {
        throw PiRPCProtocolError.responseFailed("get_commands")
      }
      return PiRPCCommandProvenance(
        name: name,
        source: source,
        path: path,
        scope: scope,
        origin: origin
      )
    }
    guard observed.sorted(by: order) == expected.commands.sorted(by: order) else {
      throw PiRPCProtocolError.responseFailed("get_commands")
    }
  }

  private static func order(
    _ lhs: PiRPCCommandProvenance,
    _ rhs: PiRPCCommandProvenance
  ) -> Bool {
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    return lhs.path < rhs.path
  }
}
