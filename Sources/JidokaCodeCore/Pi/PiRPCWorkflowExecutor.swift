import Foundation

public protocol PiRPCWorkflowPreparing: Sendable {
  func prepare(_ request: PiWorkflowExecutionRequest) async throws -> PiRPCProcessRequest
}

public enum PiRPCWorkflowExecutorError: Error, Equatable, Sendable {
  case preparationIdentityMismatch
  case preparationSessionMismatch
  case preparationBoundaryMismatch
  case resultIdentityMismatch
}

public struct PiRPCWorkflowExecutor: PiWorkflowExecuting, Sendable {
  private let preparer: any PiRPCWorkflowPreparing
  private let runtimeResolver: any PiRuntimeResolving
  private let resourceRoot: URL
  private let runner: any PiRPCProcessRunning

  public init(
    preparer: any PiRPCWorkflowPreparing,
    runtimeResolver: any PiRuntimeResolving,
    resourceRoot: URL,
    runner: any PiRPCProcessRunning = PiRPCProcessRunner()
  ) {
    self.preparer = preparer
    self.runtimeResolver = runtimeResolver
    self.resourceRoot = resourceRoot
    self.runner = runner
  }

  public func execute(_ request: PiWorkflowExecutionRequest) async throws -> PiWorkflowExecution {
    let processRequest = try await preparer.prepare(request)
    guard processRequest.terminalIdentity.workflow == request.workflow.rawValue,
      processRequest.terminalIdentity.role == request.role.rawValue,
      processRequest.terminalIdentity.artifactSHA256 == request.artifactSHA256
    else {
      throw PiRPCWorkflowExecutorError.preparationIdentityMismatch
    }
    let runtime = try runtimeResolver.resolve()
    let resources = try PiWorkflowResourceCatalog.inspect(resourceRoot: resourceRoot)
    try validateLaunch(
      processRequest,
      for: request,
      runtime: runtime,
      resources: resources
    )
    let execution = try await runner.run(processRequest)
    let result = try PiWorkflowResultDecoder.decode(execution.terminalResult)
    guard result.workflow == request.workflow,
      result.role == request.role,
      result.artifactSHA256 == request.artifactSHA256
    else {
      throw PiRPCWorkflowExecutorError.resultIdentityMismatch
    }
    return PiWorkflowExecution(
      sessionID: execution.sessionID,
      result: result,
      agentSettledCount: 1,
      extensionErrorCount: 0
    )
  }

  private func validateLaunch(
    _ processRequest: PiRPCProcessRequest,
    for request: PiWorkflowExecutionRequest,
    runtime: PiResolvedRuntime,
    resources: PiWorkflowResourceCatalog
  ) throws {
    let expectedToolNames = try PiWorkflowResourceCatalog.activeToolNames(
      workflow: request.workflow,
      role: request.role
    )
    let expectedCommandIDs = request.frozenPlan?.commandOrder ?? []
    guard processRequest.environmentPolicy == .locked,
      processRequest.executable.resolvingSymlinksInPath().standardizedFileURL
        == runtime.nodeURL.resolvingSymlinksInPath().standardizedFileURL,
      processRequest.allowedToolNames == expectedToolNames,
      processRequest.terminalIdentity.allowedCommandIDs == Set(expectedCommandIDs),
      let model = uniqueArgumentValue("--model", in: processRequest.arguments),
      let sessionDirectory = uniqueArgumentValue("--session-dir", in: processRequest.arguments),
      let sessionName = uniqueArgumentValue("--name", in: processRequest.arguments)
    else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    let sessionFlagIndices = processRequest.arguments.indices.filter {
      processRequest.arguments[$0] == "--session"
    }
    let sessionValues = sessionFlagIndices.compactMap { index in
      index + 1 < processRequest.arguments.count ? processRequest.arguments[index + 1] : nil
    }
    let launch: PiRPCSessionLaunch
    switch request.sessionDirective {
    case .fresh:
      guard sessionFlagIndices.isEmpty else {
        throw PiRPCWorkflowExecutorError.preparationSessionMismatch
      }
      launch = .fresh
    case .resume(let sessionID):
      guard sessionFlagIndices.count == 1, sessionValues == [sessionID] else {
        throw PiRPCWorkflowExecutorError.preparationSessionMismatch
      }
      launch = .resume(sessionID)
    }
    let expectedArguments = try PiRPCInvocationBuilder.arguments(
      runtime: runtime,
      model: model,
      sessionDirectory: URL(fileURLWithPath: sessionDirectory, isDirectory: true),
      sessionName: sessionName,
      blockerExtension: resources.blockerExtensionURL,
      runtimeExtension: resources.runtimeExtensionURL,
      skills: resources.skillURLs(workflow: request.workflow, role: request.role),
      activeTools: expectedToolNames,
      session: launch
    )
    guard processRequest.arguments == expectedArguments else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }

    let modelIdentity = try parseModel(model)
    let expectedSession = PiRPCSessionExpectation(
      provider: modelIdentity.provider,
      modelID: modelIdentity.modelID,
      thinkingLevel: modelIdentity.thinkingLevel,
      commands: try resources.expectedCommandProvenance(
        workflow: request.workflow,
        role: request.role
      )
    )
    guard processRequest.sessionExpectation == expectedSession,
      let home = processRequest.environment["HOME"],
      let agent = processRequest.environment["PI_CODING_AGENT_DIR"],
      let temporary = processRequest.environment["TMPDIR"],
      let configurationPath = processRequest.environment["JIDOKA_CODE_CONFIG"]
    else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    let offline: Bool
    switch processRequest.environment["PI_OFFLINE"] {
    case nil: offline = false
    case "1": offline = true
    default: throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    let configurationURL = URL(fileURLWithPath: configurationPath, isDirectory: false)
    let expectedEnvironment = try PiRPCInvocationBuilder.environment(
      homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
      agentDirectory: URL(fileURLWithPath: agent, isDirectory: true),
      temporaryDirectory: URL(fileURLWithPath: temporary, isDirectory: true),
      workflowConfiguration: configurationURL,
      offline: offline
    )
    guard processRequest.environment == expectedEnvironment else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    try validateRuntimeConfiguration(
      configurationURL,
      processRequest: processRequest,
      request: request,
      resources: resources,
      expectedCommandIDs: expectedCommandIDs
    )
  }

  private func validateRuntimeConfiguration(
    _ configurationURL: URL,
    processRequest: PiRPCProcessRequest,
    request: PiWorkflowExecutionRequest,
    resources: PiWorkflowResourceCatalog,
    expectedCommandIDs: [String]
  ) throws {
    let data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
    guard data.count <= 65_536,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let allowedWritePaths = object["allowedWritePaths"] as? [String]
    else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    let expected = try PiWorkflowRuntimeConfiguration(
      workflow: request.workflow,
      role: request.role,
      nonce: processRequest.terminalIdentity.nonce,
      artifactSHA256: request.artifactSHA256,
      allowedCommandIDs: expectedCommandIDs,
      allowedWritePaths: allowedWritePaths,
      workspaceRoot: processRequest.workingDirectory,
      resources: resources
    )
    guard try expected.encoded() == data else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
  }

  private func uniqueArgumentValue(_ flag: String, in arguments: [String]) -> String? {
    let indices = arguments.indices.filter { arguments[$0] == flag }
    guard indices.count == 1,
      let index = indices.first,
      index + 1 < arguments.count
    else {
      return nil
    }
    return arguments[index + 1]
  }

  private func parseModel(
    _ model: String
  ) throws -> (provider: String, modelID: String, thinkingLevel: String) {
    let providerAndModel = model.split(separator: "/", omittingEmptySubsequences: false)
    guard providerAndModel.count == 2 else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    let modelAndThinking = providerAndModel[1].split(
      separator: ":",
      omittingEmptySubsequences: false
    )
    guard modelAndThinking.count == 2 else {
      throw PiRPCWorkflowExecutorError.preparationBoundaryMismatch
    }
    return (
      provider: String(providerAndModel[0]),
      modelID: String(modelAndThinking[0]),
      thinkingLevel: String(modelAndThinking[1])
    )
  }
}
