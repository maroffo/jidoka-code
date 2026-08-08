import Foundation

public struct PiWorkflowReplayKey: Hashable, Sendable {
  public let workflow: PiWorkflowKind
  public let role: PiWorkflowRole
  public let round: Int

  public init(workflow: PiWorkflowKind, role: PiWorkflowRole, round: Int) {
    self.workflow = workflow
    self.role = role
    self.round = round
  }
}

public struct PiWorkflowReplayFixture: Sendable {
  public let key: PiWorkflowReplayKey
  public let sessionID: String
  public let transcript: Data
  public let terminalIdentity: PiRPCTerminalResultIdentity
  public let sessionDirective: PiWorkflowSessionDirective
  public let promptRequestID: String

  public init(
    key: PiWorkflowReplayKey,
    sessionID: String,
    transcript: Data,
    terminalIdentity: PiRPCTerminalResultIdentity,
    sessionDirective: PiWorkflowSessionDirective = .fresh,
    promptRequestID: String = "prompt-1"
  ) {
    self.key = key
    self.sessionID = sessionID
    self.transcript = transcript
    self.terminalIdentity = terminalIdentity
    self.sessionDirective = sessionDirective
    self.promptRequestID = promptRequestID
  }
}

public enum PiWorkflowReplayError: Error, Equatable, Sendable {
  case duplicateFixture
  case missingFixture
  case artifactMismatch
  case sessionMismatch
  case unusedFixture
}

public actor PiWorkflowReplayExecutor: PiWorkflowExecuting {
  private var fixtures: [PiWorkflowReplayKey: PiWorkflowReplayFixture]

  public init(fixtures: [PiWorkflowReplayFixture]) throws {
    guard Set(fixtures.map(\.key)).count == fixtures.count else {
      throw PiWorkflowReplayError.duplicateFixture
    }
    self.fixtures = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.key, $0) })
  }

  public func execute(_ request: PiWorkflowExecutionRequest) async throws -> PiWorkflowExecution {
    let key = PiWorkflowReplayKey(
      workflow: request.workflow,
      role: request.role,
      round: request.round
    )
    guard let fixture = fixtures.removeValue(forKey: key) else {
      throw PiWorkflowReplayError.missingFixture
    }
    guard request.artifactSHA256 == fixture.terminalIdentity.artifactSHA256 else {
      throw PiWorkflowReplayError.artifactMismatch
    }
    guard request.sessionDirective == fixture.sessionDirective else {
      throw PiWorkflowReplayError.sessionMismatch
    }
    if case .resume(let expectedSessionID) = fixture.sessionDirective,
      expectedSessionID != fixture.sessionID
    {
      throw PiWorkflowReplayError.sessionMismatch
    }
    let result = try Self.replay(fixture)
    return PiWorkflowExecution(
      sessionID: fixture.sessionID,
      result: result,
      agentSettledCount: 1,
      extensionErrorCount: 0
    )
  }

  public func assertExhausted() throws {
    guard fixtures.isEmpty else { throw PiWorkflowReplayError.unusedFixture }
  }

  public static func replay(
    _ fixture: PiWorkflowReplayFixture,
    chunkPattern: [Int] = [1, 7, 31, 127]
  ) throws -> PiWorkflowRoleResult {
    guard !chunkPattern.isEmpty, chunkPattern.allSatisfy({ $0 > 0 }) else {
      throw PiRPCProtocolError.invalidLimits
    }
    var parser = try PiRPCJSONLParser()
    var conversation = PiRPCConversation(
      terminalIdentity: fixture.terminalIdentity,
      allowedToolNames: try PiWorkflowResourceCatalog.activeToolNames(
        workflow: fixture.key.workflow,
        role: fixture.key.role
      )
    )
    try conversation.registerRequest(id: fixture.promptRequestID, command: "prompt")
    var offset = 0
    var chunkIndex = 0
    while offset < fixture.transcript.count {
      let count = min(
        chunkPattern[chunkIndex % chunkPattern.count], fixture.transcript.count - offset)
      let chunk = fixture.transcript.subdata(in: offset..<(offset + count))
      for record in try parser.append(chunk) {
        try conversation.consume(record)
        if let response = conversation.takeResponse(id: fixture.promptRequestID) {
          try conversation.markPromptAccepted(response)
        }
      }
      offset += count
      chunkIndex += 1
    }
    try parser.finish()
    let terminal = try conversation.validatedTerminalResult()
    return try PiWorkflowResultDecoder.decode(terminal)
  }
}
