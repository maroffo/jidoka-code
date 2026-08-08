import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Strict Pi RPC JSONL and terminal result contract")
struct PiRPCProtocolTests {
  private let identity = PiRPCTerminalResultIdentity(
    workflow: "planning",
    role: "writer",
    nonce: "nonce-12345678",
    artifactSHA256: String(repeating: "a", count: 64),
    allowedCommandIDs: ["check", "test"]
  )

  @Test("LF framing preserves Unicode separators and accepts one trailing CR")
  func strictLFFraming() throws {
    var parser = try PiRPCJSONLParser(maximumRecordBytes: 1_024)
    let first = Data(#"{"type":"message_update","value":"left-right"}"#.utf8)
    let separator = String(UnicodeScalar(0x2028)!)
    let unicodeSeparator = Data(
      "{\"type\":\"message_update\",\"value\":\"left\(separator)right\"}\r\n".utf8
    )

    #expect(try parser.append(first).isEmpty)
    let records = try parser.append(Data("\n".utf8) + unicodeSeparator)
    try parser.finish()

    #expect(records.count == 2)
    #expect(records[1].object["value"]?.stringValue == "left\(separator)right")
  }

  @Test("empty, oversized, malformed, and unterminated records fail closed")
  func invalidFraming() throws {
    var empty = try PiRPCJSONLParser()
    #expect(throws: PiRPCProtocolError.emptyRecord) {
      try empty.append(Data("\n".utf8))
    }

    var oversized = try PiRPCJSONLParser(maximumRecordBytes: 64)
    #expect(throws: PiRPCProtocolError.recordTooLarge) {
      try oversized.append(Data(repeating: 0x61, count: 65))
    }

    var malformed = try PiRPCJSONLParser()
    #expect(throws: PiRPCProtocolError.malformedJSON) {
      try malformed.append(Data("{not-json}\n".utf8))
    }

    var unterminated = try PiRPCJSONLParser()
    _ = try unterminated.append(Data("{}".utf8))
    #expect(throws: PiRPCProtocolError.unterminatedRecord) {
      try unterminated.finish()
    }
  }

  @Test("correlated accepted prompt plus one settled result is the only success")
  func settledResult() throws {
    var conversation = PiRPCConversation(terminalIdentity: identity)
    try conversation.registerRequest(id: "1", command: "prompt")
    try conversation.consume(
      try record(#"{"command":"prompt","id":"1","success":true,"type":"response"}"#)
    )
    let optionalResponse = conversation.takeResponse(id: "1")
    let response = try #require(optionalResponse)
    try conversation.markPromptAccepted(response)
    try consumeInitialLifecycle(&conversation, closeAssistantMessage: false)
    try conversation.consume(
      try record(
        #"{"assistantMessageEvent":{"contentIndex":0,"delta":"ok-still-json","type":"text_delta"},"type":"message_update"}"#
      )
    )
    try conversation.consume(
      try record(#"{"message":{"role":"assistant"},"type":"message_end"}"#)
    )
    try conversation.consume(try terminalStartRecord())
    try conversation.consume(try terminalRecord())
    try consumeTerminalSuffix(&conversation)

    let result = try conversation.validatedTerminalResult()
    #expect(result.workflow == "planning")
    #expect(result.approvedCommandIDs == ["check"])
    #expect(result.payload["verdict"]?.stringValue == "pass")
    #expect(conversation.isSettled)
  }

  @Test("unknown responses, extension errors, retry, and events after settled are fatal")
  func fatalEvents() throws {
    var unknown = PiRPCConversation(terminalIdentity: identity)
    #expect(throws: PiRPCProtocolError.unknownResponseID) {
      try unknown.consume(
        try record(#"{"command":"prompt","id":"other","success":true,"type":"response"}"#)
      )
    }

    var extensionFailure = try acceptedConversation()
    #expect(throws: PiRPCProtocolError.extensionError) {
      try extensionFailure.consume(try record(#"{"error":"boom","type":"extension_error"}"#))
    }

    var retry = try acceptedConversation()
    #expect(throws: PiRPCProtocolError.automaticContinuation) {
      try retry.consume(try record(#"{"type":"auto_retry_start"}"#))
    }

    var failedTool = try acceptedConversation()
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try failedTool.consume(
        try record(
          #"{"isError":true,"toolCallId":"read-1","toolName":"read","type":"tool_execution_end"}"#
        )
      )
    }

    var duplicateEnd = try acceptedConversation()
    try duplicateEnd.consume(try terminalRecord())
    try consumeTerminalToolResult(&duplicateEnd)
    let agentEnd = try record(#"{"messages":[],"type":"agent_end","willRetry":false}"#)
    try duplicateEnd.consume(agentEnd)
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try duplicateEnd.consume(agentEnd)
    }

    var settled = try acceptedConversation()
    try settled.consume(try terminalRecord())
    try consumeTerminalSuffix(&settled)
    #expect(throws: PiRPCProtocolError.eventAfterSettled) {
      try settled.consume(try record(#"{"type":"agent_start"}"#))
    }
    try settled.registerRequest(id: "late", command: "get_state")
    #expect(throws: PiRPCProtocolError.eventAfterSettled) {
      try settled.consume(
        try record(#"{"command":"get_state","id":"late","success":true,"type":"response"}"#)
      )
    }
  }

  @Test("tool lifecycle rejects unauthorized, orphaned, and mismatched calls")
  func toolLifecycle() throws {
    var unauthorized = try acceptedConversation(startTerminalTool: false)
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try unauthorized.consume(
        try record(
          #"{"args":{},"toolCallId":"bash-1","toolName":"bash","type":"tool_execution_start"}"#
        )
      )
    }

    var orphaned = try acceptedConversation(startTerminalTool: false)
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try orphaned.consume(try terminalRecord())
    }

    var mismatched = try acceptedConversation(startTerminalTool: false)
    try mismatched.consume(
      try record(
        #"{"args":{},"toolCallId":"result-1","toolName":"jidoka_code_result","type":"tool_execution_start"}"#
      )
    )
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try mismatched.consume(
        try record(
          #"{"args":{},"partialResult":{},"toolCallId":"result-1","toolName":"jidoka_code_read","type":"tool_execution_update"}"#
        )
      )
    }
  }

  @Test("terminal evidence is causally ordered after prompt acceptance")
  func terminalOrdering() throws {
    var beforePrompt = PiRPCConversation(terminalIdentity: identity)
    try beforePrompt.registerRequest(id: "1", command: "prompt")
    #expect(throws: PiRPCProtocolError.missingPromptAcceptance) {
      try beforePrompt.consume(try terminalRecord())
    }

    var missingRetryFlag = try acceptedConversation()
    try missingRetryFlag.consume(try terminalRecord())
    try consumeTerminalToolResult(&missingRetryFlag)
    #expect(throws: PiRPCProtocolError.automaticContinuation) {
      try missingRetryFlag.consume(try record(#"{"messages":[],"type":"agent_end"}"#))
    }

    var missingToolResultMessage = try acceptedConversation()
    try missingToolResultMessage.consume(try terminalRecord())
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try missingToolResultMessage.consume(
        try record(#"{"messages":[],"type":"agent_end","willRetry":false}"#)
      )
    }

    var settledBeforeEnd = try acceptedConversation()
    try settledBeforeEnd.consume(try terminalRecord())
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try settledBeforeEnd.consume(try record(#"{"type":"agent_settled"}"#))
    }

    var multipleTools = try acceptedConversation(startTerminalTool: false)
    try multipleTools.consume(
      try record(
        #"{"args":{},"toolCallId":"read-1","toolName":"jidoka_code_read","type":"tool_execution_start"}"#
      )
    )
    try multipleTools.consume(
      try record(
        #"{"isError":false,"result":{},"toolCallId":"read-1","toolName":"jidoka_code_read","type":"tool_execution_end"}"#
      )
    )
    let readResult =
      #"{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"read-1","toolName":"jidoka_code_read"}"#
    try multipleTools.consume(
      try record("{\"message\":\(readResult),\"type\":\"message_start\"}")
    )
    try multipleTools.consume(
      try record("{\"message\":\(readResult),\"type\":\"message_end\"}")
    )
    try multipleTools.consume(try terminalStartRecord())
    #expect(throws: PiRPCProtocolError.invalidTerminalResult) {
      try multipleTools.consume(try terminalRecord())
    }
  }

  @Test("a nonterminal tool result closes its turn before the next assistant message")
  func nonterminalToolTurn() throws {
    var conversation = try acceptedConversation(startTerminalTool: false)
    try conversation.consume(
      try record(
        #"{"args":{},"toolCallId":"read-1","toolName":"jidoka_code_read","type":"tool_execution_start"}"#
      )
    )
    try conversation.consume(
      try record(
        #"{"isError":false,"result":{},"toolCallId":"read-1","toolName":"jidoka_code_read","type":"tool_execution_end"}"#
      )
    )
    let readResult =
      #"{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"read-1","toolName":"jidoka_code_read"}"#
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try conversation.consume(try record(#"{"type":"turn_start"}"#))
    }
    try conversation.consume(
      try record("{\"message\":\(readResult),\"type\":\"message_start\"}")
    )
    try conversation.consume(
      try record("{\"message\":\(readResult),\"type\":\"message_end\"}")
    )
    try conversation.consume(
      try record("{\"message\":{},\"toolResults\":[\(readResult)],\"type\":\"turn_end\"}")
    )
    try conversation.consume(try record(#"{"type":"turn_start"}"#))
    try conversation.consume(
      try record(#"{"message":{"role":"assistant"},"type":"message_start"}"#)
    )
    try conversation.consume(
      try record(#"{"message":{"role":"assistant"},"type":"message_end"}"#)
    )
    try conversation.consume(try terminalStartRecord())
    try conversation.consume(try terminalRecord())
    try consumeTerminalSuffix(&conversation)
    #expect(conversation.isSettled)
  }

  @Test("mandatory agent, turn, user, and assistant lifecycle cannot be omitted or reordered")
  func mandatoryLifecycle() throws {
    var missingAgent = try promptAcceptedConversation()
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try missingAgent.consume(try terminalStartRecord())
    }

    var missingTurn = try promptAcceptedConversation()
    try missingTurn.consume(try record(#"{"type":"agent_start"}"#))
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try missingTurn.consume(
        try record(#"{"message":{"role":"user"},"type":"message_start"}"#)
      )
    }

    var reordered = try promptAcceptedConversation()
    try reordered.consume(try record(#"{"type":"agent_start"}"#))
    try reordered.consume(try record(#"{"type":"turn_start"}"#))
    #expect(throws: PiRPCProtocolError.invalidEvent) {
      try reordered.consume(
        try record(#"{"message":{"role":"assistant"},"type":"message_start"}"#)
      )
    }
  }

  @Test("multiple or out-of-plan terminal command results fail closed")
  func invalidTerminalResults() throws {
    var duplicate = try acceptedConversation()
    try duplicate.consume(try terminalRecord())
    #expect(throws: PiRPCProtocolError.multipleTerminalResults) {
      try duplicate.consume(try terminalRecord())
    }

    var outOfPlan = try acceptedConversation()
    #expect(throws: PiRPCProtocolError.invalidTerminalResult) {
      try outOfPlan.consume(try terminalRecord(commandIDs: ["arbitrary"]))
    }
  }

  @Test("state and command inventory require exact model and provenance")
  func exactStateAndCommands() throws {
    let expected = PiRPCSessionExpectation(
      provider: "openai-codex",
      modelID: "gpt-5.6-sol",
      thinkingLevel: "max",
      commands: [
        PiRPCCommandProvenance(
          name: "skill:jidoka-code-plan",
          source: "skill",
          path: "/bundle/skills/plan/SKILL.md",
          scope: "temporary",
          origin: "top-level"
        )
      ]
    )
    let sessionID = try PiRPCSessionValidation.validateState(
      PiRPCResponse(
        id: "1",
        command: "get_state",
        success: true,
        data: [
          "autoCompactionEnabled": .bool(false),
          "isStreaming": .bool(false),
          "model": .object([
            "id": .string("gpt-5.6-sol"),
            "provider": .string("openai-codex"),
          ]),
          "sessionId": .string("session-1"),
          "thinkingLevel": .string("max"),
        ]
      ),
      expected: expected
    )
    #expect(sessionID == "session-1")
    try PiRPCSessionValidation.validateCommands(
      PiRPCResponse(
        id: "2",
        command: "get_commands",
        success: true,
        data: [
          "commands": .array([
            .object([
              "name": .string("skill:jidoka-code-plan"),
              "source": .string("skill"),
              "sourceInfo": .object([
                "origin": .string("top-level"),
                "path": .string("/bundle/skills/plan/SKILL.md"),
                "scope": .string("temporary"),
              ]),
            ])
          ])
        ]
      ),
      expected: expected
    )
  }

  private func consumeTerminalToolResult(
    _ conversation: inout PiRPCConversation
  ) throws {
    let message =
      #"{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"result-1","toolName":"jidoka_code_result"}"#
    try conversation.consume(try record("{\"message\":\(message),\"type\":\"message_start\"}"))
    try conversation.consume(try record("{\"message\":\(message),\"type\":\"message_end\"}"))
    try conversation.consume(
      try record("{\"message\":{},\"toolResults\":[\(message)],\"type\":\"turn_end\"}")
    )
  }

  private func consumeTerminalSuffix(
    _ conversation: inout PiRPCConversation
  ) throws {
    try consumeTerminalToolResult(&conversation)
    try conversation.consume(
      try record(#"{"messages":[],"type":"agent_end","willRetry":false}"#)
    )
    try conversation.consume(try record(#"{"type":"agent_settled"}"#))
  }

  private func terminalStartRecord() throws -> PiRPCRecord {
    try record(
      #"{"args":{},"toolCallId":"result-1","toolName":"jidoka_code_result","type":"tool_execution_start"}"#
    )
  }

  private func terminalRecord(commandIDs: [String] = ["check"]) throws -> PiRPCRecord {
    let commands = commandIDs.map { "\"\($0)\"" }.joined(separator: ",")
    return try record(
      """
      {"isError":false,"result":{"details":{"approvedCommandIDs":[\(commands)],"artifactSHA256":"\(String(repeating: "a", count: 64))","nonce":"nonce-12345678","payload":{"verdict":"pass"},"resultSequence":1,"role":"writer","schemaVersion":1,"workflow":"planning"}},"toolCallId":"result-1","toolName":"jidoka_code_result","type":"tool_execution_end"}
      """
    )
  }

  private func acceptedConversation(
    startTerminalTool: Bool = true
  ) throws -> PiRPCConversation {
    var conversation = try promptAcceptedConversation()
    try consumeInitialLifecycle(&conversation)
    if startTerminalTool {
      try conversation.consume(try terminalStartRecord())
    }
    return conversation
  }

  private func promptAcceptedConversation() throws -> PiRPCConversation {
    var conversation = PiRPCConversation(
      terminalIdentity: identity,
      allowedToolNames: ["jidoka_code_read", "jidoka_code_result"]
    )
    try conversation.registerRequest(id: "prompt", command: "prompt")
    try conversation.consume(
      try record(#"{"command":"prompt","id":"prompt","success":true,"type":"response"}"#)
    )
    let optionalResponse = conversation.takeResponse(id: "prompt")
    let response = try #require(optionalResponse)
    try conversation.markPromptAccepted(response)
    return conversation
  }

  private func consumeInitialLifecycle(
    _ conversation: inout PiRPCConversation,
    closeAssistantMessage: Bool = true
  ) throws {
    try conversation.consume(try record(#"{"type":"agent_start"}"#))
    try conversation.consume(try record(#"{"type":"turn_start"}"#))
    try conversation.consume(
      try record(#"{"message":{"role":"user"},"type":"message_start"}"#)
    )
    try conversation.consume(
      try record(#"{"message":{"role":"user"},"type":"message_end"}"#)
    )
    try conversation.consume(
      try record(#"{"message":{"role":"assistant"},"type":"message_start"}"#)
    )
    if closeAssistantMessage {
      try conversation.consume(
        try record(#"{"message":{"role":"assistant"},"type":"message_end"}"#)
      )
    }
  }

  private func record(_ json: String) throws -> PiRPCRecord {
    var parser = try PiRPCJSONLParser()
    let records = try parser.append(Data("\(json)\n".utf8))
    try parser.finish()
    return try #require(records.first)
  }
}
