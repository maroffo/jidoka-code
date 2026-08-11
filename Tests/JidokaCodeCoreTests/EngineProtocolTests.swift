import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Versioned application engine protocol")
struct EngineProtocolTests {
  @Test("request and response bind version, identity, and operation")
  func exactEnvelope() throws {
    let request = EngineXPCRequest(
      requestID: "11111111-1111-1111-1111-111111111111",
      command: .setPaused(true)
    )
    try request.validate()
    let state = engineProtocolState()
    let result = EngineCommandResponse(command: .setPaused, state: state)
    let response = EngineXPCResponse(requestID: request.requestID, result: result)
    #expect(try response.validate(for: request) == result)

    let wrongID = EngineXPCResponse(
      requestID: "22222222-2222-2222-2222-222222222222",
      result: result
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try wrongID.validate(for: request)
    }
    let wrongCommand = EngineXPCResponse(
      requestID: request.requestID,
      result: EngineCommandResponse(command: .pollNow, state: state)
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try wrongCommand.validate(for: request)
    }
    let incompleteReadiness = EngineXPCResponse(
      requestID: request.requestID,
      result: EngineCommandResponse(
        command: .setPaused,
        state: engineProtocolState(herdr: EngineHerdrStatus(state: .ready))
      )
    )
    #expect(throws: EngineClientError(.invalidResponse)) {
      try incompleteReadiness.validate(for: request)
    }
  }

  @Test("unsupported versions and malformed request IDs fail closed")
  func versionBoundary() {
    #expect(throws: EngineClientError(.unsupportedVersion)) {
      try EngineXPCRequest(
        protocolVersion: EngineProtocolVersion.current + 1,
        command: .snapshot
      ).validate()
    }
    #expect(throws: EngineClientError(.invalidRequest)) {
      try EngineXPCRequest(requestID: "not-a-uuid", command: .snapshot).validate()
    }
    #expect(throws: EngineClientError(.invalidCommand)) {
      try EngineXPCRequest(command: .replaceCredential(Data("short".utf8))).validate()
    }
  }

  @Test("production XPC handler returns exact envelopes without reflecting credential bytes")
  func messageHandler() async throws {
    let client = EngineXPCClientFake()
    let handler = EngineXPCMessageHandler(client: client)
    let token = Data("github_pat_xpc_secret_1234567890".utf8)
    let request = EngineXPCRequest(
      requestID: "11111111-1111-1111-1111-111111111111",
      command: .replaceCredential(token)
    )
    let encoder = JSONEncoder()
    let payload = await handler.handle(try encoder.encode(request))
    #expect(!payload.contains(token))
    let response = try JSONDecoder().decode(EngineXPCResponse.self, from: payload)
    #expect(try response.validate(for: request).command == .replaceCredential)

    let unsupported = EngineXPCRequest(
      protocolVersion: EngineProtocolVersion.current + 1,
      requestID: "22222222-2222-2222-2222-222222222222",
      command: .snapshot
    )
    let unsupportedResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(try encoder.encode(unsupported))
    )
    #expect(unsupportedResponse.requestID == unsupported.requestID)
    #expect(unsupportedResponse.error == EngineClientError(.unsupportedVersion))
    #expect(throws: EngineClientError(.unsupportedVersion)) {
      try unsupportedResponse.validate(for: unsupported)
    }

    let malformedResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(Data("not-json".utf8))
    )
    #expect(malformedResponse.requestID == "invalid")
    #expect(malformedResponse.error == EngineClientError(.invalidRequest))

    let restricted = EngineXPCMessageHandler(
      client: client,
      allowedCommands: [.snapshot]
    )
    let topologyRequest = EngineXPCRequest(command: .setLoginEnabled(true))
    let topologyResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await restricted.handle(try encoder.encode(topologyRequest))
    )
    #expect(topologyResponse.error == EngineClientError(.invalidCommand))

    await client.fail(with: .busy)
    let busyRequest = EngineXPCRequest(command: .pollNow)
    let busyResponse = try JSONDecoder().decode(
      EngineXPCResponse.self,
      from: await handler.handle(try encoder.encode(busyRequest))
    )
    #expect(busyResponse.error == EngineClientError(.busy))
  }

  @Test("all commands survive a Codable round trip without changing kind")
  func codableCommands() throws {
    let mutation = EngineAmbiguousMutation(
      jobID: UUID(),
      repositoryID: UUID(),
      repositoryOwner: "owner",
      repositoryName: "repo",
      kind: .prReview,
      objectNodeID: "PR_node",
      objectNumber: 7,
      revisionKey: String(repeating: "a", count: 40),
      evidenceDigest: String(repeating: "b", count: 64),
      mutationGeneration: 2,
      mutationID: UUID().uuidString.lowercased()
    )
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "R_node",
      owner: "owner",
      name: "repo",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    let commands: [EngineCommand] = [
      .snapshot,
      .acknowledgeExternalAutomation(true),
      .acknowledgeProviderDisclosure(true),
      .runPiPreflight,
      .runHerdrPreflight,
      .focusInHerdr,
      .replaceCredential(Data(String(repeating: "x", count: 20).utf8)),
      .deleteCredential,
      .addRepository(
        EngineRepositoryDraft(
          owner: "owner",
          name: "repo",
          reviewEnabled: true,
          triageEnabled: true,
          implementationEnabled: true
        )
      ),
      .updateRepository(repository),
      .removeRepository(repository.id),
      .setProfile(
        ModelProfileConfiguration(
          role: .review,
          provider: "openai-codex",
          model: "gpt-5.6-sol",
          thinking: .max
        )
      ),
      .setMaxConcurrency(4),
      .setPaused(true),
      .pollNow,
      .recheckAmbiguousMutation(EngineAmbiguousMutationEvidence(mutation)),
      .authorizeRetry(EngineAmbiguousMutationEvidence(mutation)),
      .setLoginEnabled(true),
      .synchronizeLoginStatus(selected: true, status: .enabled),
      .completeOnboarding,
      .rollbackOnboarding,
      .prepareForHandoff,
      .prepareForQuit,
    ]
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for command in commands {
      let decoded = try decoder.decode(EngineCommand.self, from: encoder.encode(command))
      #expect(decoded == command)
      #expect(decoded.kind == command.kind)
    }
  }
}

private actor EngineXPCClientFake: EngineClient {
  private var error: EngineClientErrorCode?

  func fail(with error: EngineClientErrorCode) {
    self.error = error
  }

  func send(_ command: EngineCommand) throws -> EngineCommandResponse {
    if let error { throw EngineClientError(error) }
    return EngineCommandResponse(command: command.kind, state: engineProtocolState())
  }
}

private func engineProtocolState(
  herdr: EngineHerdrStatus = .unchecked
) -> EngineUIState {
  let credential = EngineCredentialStatus.missing
  let pi = EnginePiStatus.unchecked
  let onboarding = EngineOnboardingSnapshot(
    duplicateInstanceCheckPassed: true,
    externalAutomationAcknowledged: false,
    providerDisclosureAcknowledged: false,
    pi: pi,
    herdr: herdr,
    credential: credential,
    repositoryCount: 0,
    configuredProfileRoles: [],
    loginItemSelected: false,
    loginItemStatus: .notRegistered,
    complete: false
  )
  return EngineUIState(
    revision: 0,
    lifecycle: .onboarding,
    operationalStatus: .active,
    paused: false,
    passRunning: false,
    activities: [],
    ambiguousMutations: [],
    onboarding: onboarding,
    settings: EngineSettingsSnapshot(
      repositories: [],
      profiles: [],
      maxConcurrency: 2,
      loginItemSelected: false,
      loginItemStatus: .notRegistered,
      credential: credential,
      herdr: herdr
    ),
    diagnostics: EngineDiagnostics(
      schemaVersion: 2,
      nonterminalJobCount: 0,
      ambiguousMutationCount: 0,
      coordinatorFailureCodes: [],
      piIssueCode: nil,
      herdrIssueCode: nil
    )
  )
}
