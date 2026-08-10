import Foundation

public protocol PiWorkflowExecutorBuilding: Sendable {
  func makeExecutor(
    preparer: any PiRPCWorkflowPreparing
  ) -> any PiWorkflowExecuting
}

struct PiRPCWorkflowExecutorFactory: PiWorkflowExecutorBuilding, Sendable {
  private let runtimeResolver: any PiRuntimeResolving
  private let resourceRoot: URL
  private let runner: any PiRPCProcessRunning

  init(
    runtimeResolver: any PiRuntimeResolving,
    resourceRoot: URL,
    runner: any PiRPCProcessRunning = PiRPCProcessRunner()
  ) {
    self.runtimeResolver = runtimeResolver
    self.resourceRoot = resourceRoot
    self.runner = runner
  }

  func makeExecutor(
    preparer: any PiRPCWorkflowPreparing
  ) -> any PiWorkflowExecuting {
    PiRPCWorkflowExecutor(
      preparer: preparer,
      runtimeResolver: runtimeResolver,
      resourceRoot: resourceRoot,
      runner: runner
    )
  }
}
