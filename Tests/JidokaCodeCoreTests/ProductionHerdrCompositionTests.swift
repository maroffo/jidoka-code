import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Production Herdr composition contract")
struct ProductionHerdrCompositionTests {
  @Test("initial runtime reload emits only closed diagnostic phases")
  func initialRuntimeReloadPhases() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jidoka-production-reload-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(database: database)
    let intents = MutationIntentStore(database: database)
    let logger = ProductionRuntimeLogFake()
    let runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: try ProductionEngineRuntimeConfiguration(
        applicationSupportRoot: root,
        piResourceRoot: root.appendingPathComponent("Pi", isDirectory: true),
        askPassExecutable: root.appendingPathComponent("askpass"),
        pushGuardExecutable: root.appendingPathComponent("push-guard"),
        herdrHostExecutable: root.appendingPathComponent("herdr-host"),
        herdrSocketURL: root.appendingPathComponent("herdr.sock"),
        contractVersion: "test-v1"
      ),
      database: database,
      configuration: configuration,
      jobs: jobs,
      intents: intents,
      herdrReadiness: ProductionRuntimeReadinessFake(),
      logger: logger,
      now: { Date(timeIntervalSince1970: 700_000) }
    )

    try await runtime.reload(dispatchAllowed: false)
    try await runtime.reload(dispatchAllowed: false)

    let records = await logger.records
    #expect(records.map(\.phase) == [.runtimeQuiesce, .runtimeSnapshot, .runtimeOwnership])
    #expect(records.allSatisfy { $0.event == .startupPhase })
    #expect(records.allSatisfy { $0.command == nil && $0.error == nil })
    await database.close()
  }

  @Test("retirement cleanup remains provider-independent without runtime components")
  func providerIndependentRetirementCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-production-maintenance-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(database: database)
    let repository = RepositoryConfiguration(
      id: UUID(),
      nodeID: "R_maintenance",
      owner: "owner",
      name: "repository",
      defaultBranch: "main",
      reviewEnabled: true,
      triageEnabled: true,
      implementationEnabled: true,
      enabled: true
    )
    try await configuration.upsertRepository(repository, now: Date(timeIntervalSince1970: 1))
    let creation = try await jobs.createJob(
      identity: LogicalJobIdentity(
        repositoryID: repository.id,
        kind: .prReview,
        objectNodeID: "PR_maintenance",
        revisionKey: "head"
      ),
      contractVersionUsed: "test-v1",
      priority: .prReview,
      firstStep: .review,
      now: Date(
        timeIntervalSince1970: TimeInterval(
          JobMaintenanceScope.authorizedBoundaryEpochSeconds - 1
        )
      )
    )
    guard case .created(let job) = creation else {
      Issue.record("maintenance fixture was suppressed")
      return
    }
    try await database.execute("UPDATE app_settings SET paused = 1 WHERE singleton = 1")
    let scope = JobMaintenanceScope(
      operation: .retireBefore,
      boundaryEpochSeconds: JobMaintenanceScope.authorizedBoundaryEpochSeconds
    )
    let preview = try await jobs.previewMaintenance(scope: scope)
    let authorization = JobMaintenanceAuthorization(
      scope: scope,
      expectedCount: preview.candidateCount,
      evidenceSHA256: preview.evidenceSHA256
    )
    let application = try await jobs.applyMaintenance(authorization, now: Date())
    let runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: try ProductionEngineRuntimeConfiguration(
        applicationSupportRoot: root,
        piResourceRoot: root.appendingPathComponent("Pi", isDirectory: true),
        askPassExecutable: root.appendingPathComponent("askpass"),
        pushGuardExecutable: root.appendingPathComponent("push-guard"),
        herdrHostExecutable: root.appendingPathComponent("herdr-host"),
        herdrSocketURL: root.appendingPathComponent("herdr.sock"),
        contractVersion: "test-v1"
      ),
      database: database,
      configuration: configuration,
      jobs: jobs,
      intents: MutationIntentStore(database: database),
      herdrReadiness: ProductionRuntimeReadinessFake()
    )
    try await runtime.reload(dispatchAllowed: false)
    try await runtime.beginExclusiveOperation()
    try await runtime.cleanupRetiredJobs(
      jobIDs: application.jobIDs,
      evidenceSHA256: authorization.evidenceSHA256
    )
    await runtime.endExclusiveOperation()
    #expect(application.jobIDs == [job.id])
    #expect(try await jobs.disposition(for: job.identity)?.state == .superseded)
    await database.close()
  }

  @Test(
    "production replacement boundary returns every typed outcome and closes authority",
    arguments: ProductionReplacementBoundaryScenario.executionCases
  )
  func productionReplacementBoundary(
    scenario: ProductionReplacementBoundaryScenario
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-production-replacement-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let configuration = ConfigurationStore(database: database)
    let jobs = DurableJobStore(database: database)
    let authorization = productionReplacementAuthorization()
    let canary = productionReplacementCanaryReport(authorization: authorization)
    let terminal = try productionReplacementReport(
      authorization: authorization,
      outcome: scenario.outcome
    )
    let probe = ProductionReplacementBoundaryProbe(
      scenario: scenario,
      authorization: authorization,
      canary: canary,
      terminal: terminal
    )
    let runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: try ProductionEngineRuntimeConfiguration(
        applicationSupportRoot: root,
        piResourceRoot: root.appendingPathComponent("Pi", isDirectory: true),
        askPassExecutable: root.appendingPathComponent("askpass"),
        pushGuardExecutable: root.appendingPathComponent("push-guard"),
        herdrHostExecutable: root.appendingPathComponent("herdr-host"),
        herdrSocketURL: root.appendingPathComponent("herdr.sock"),
        contractVersion: "test-v1"
      ),
      database: database,
      configuration: configuration,
      jobs: jobs,
      intents: MutationIntentStore(database: database),
      herdrReadiness: ProductionRuntimeReadinessFake(),
      ownershipRuntime: nil,
      reloadComposition: ProductionEngineReloadComposition(
        setSchedulerPaused: { _ in },
        recoverCoordinatorAtStartup: {},
        runStartupPass: { _ in },
        requestStartup: {}
      ),
      roleHostReplacementBoundary: await probe.boundary()
    )
    await runtime.setPaused(true)
    try await runtime.beginExclusiveOperation()
    do {
      let execution = try await runtime.executeCanaryRoleHostReplacement(authorization)
      #expect(scenario != .thrownError)
      #expect(execution.replacement == terminal)
      #expect(execution.canary == canary)
    } catch {
      guard scenario == .thrownError else {
        await runtime.endExclusiveOperation()
        throw error
      }
      #expect(error as? ProductionReplacementBoundaryFailure == .injected)
    }
    await runtime.endExclusiveOperation()
    try await runtime.beginExclusiveOperation()
    await runtime.endExclusiveOperation()

    #expect(
      await probe.events
        == [
          "terminal:initial", "resource", "admit", "candidate", "marker:begin",
          "admission:begin", "activate", "coordinator", "admission:end", "marker:end",
          "terminal:final",
        ]
    )
    #expect(await probe.openMarkerCount == 0)
    #expect(await probe.openAdmissionCount == 0)
    await database.close()
  }

  @Test("terminal replacement replay is denied before marker or launch admission")
  func productionReplacementReplayDenied() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-production-replacement-replay-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
    let configuration = ConfigurationStore(database: database)
    let authorization = productionReplacementAuthorization()
    let terminal = try productionReplacementReport(
      authorization: authorization,
      outcome: .remoteEffectAmbiguous
    )
    let probe = ProductionReplacementBoundaryProbe(
      scenario: .terminalReplay,
      authorization: authorization,
      canary: productionReplacementCanaryReport(authorization: authorization),
      terminal: terminal
    )
    let runtime = ProductionEngineJobRuntime(
      runtimeConfiguration: try ProductionEngineRuntimeConfiguration(
        applicationSupportRoot: root,
        piResourceRoot: root.appendingPathComponent("Pi", isDirectory: true),
        askPassExecutable: root.appendingPathComponent("askpass"),
        pushGuardExecutable: root.appendingPathComponent("push-guard"),
        herdrHostExecutable: root.appendingPathComponent("herdr-host"),
        herdrSocketURL: root.appendingPathComponent("herdr.sock"),
        contractVersion: "test-v1"
      ),
      database: database,
      configuration: configuration,
      jobs: DurableJobStore(database: database),
      intents: MutationIntentStore(database: database),
      herdrReadiness: ProductionRuntimeReadinessFake(),
      ownershipRuntime: nil,
      reloadComposition: ProductionEngineReloadComposition(
        setSchedulerPaused: { _ in },
        recoverCoordinatorAtStartup: {},
        runStartupPass: { _ in },
        requestStartup: {}
      ),
      roleHostReplacementBoundary: await probe.boundary()
    )
    await runtime.setPaused(true)
    try await runtime.beginExclusiveOperation()
    await #expect(throws: EngineClientError(.staleEvidence)) {
      _ = try await runtime.executeCanaryRoleHostReplacement(authorization)
    }
    await runtime.endExclusiveOperation()
    #expect(await probe.events == ["terminal:initial"])
    #expect(await probe.openMarkerCount == 0)
    #expect(await probe.openAdmissionCount == 0)
    await database.close()
  }

  @Test("all production Pi workflows share Herdr and recovery precedes job recovery")
  func productionCutoverIsExclusive() throws {
    let source = try String(contentsOf: productionRuntimeSource(), encoding: .utf8)
    #expect(source.components(separatedBy: "executorFactory: herdrRuntime").count - 1 == 4)
    #expect(!source.contains("PiRPCWorkflowExecutorFactory("))
    #expect(!source.contains("PiRPCProcessRunner("))
    let herdrRecovery = try #require(source.range(of: "herdrRuntime.recoverDurableState()"))
    let commandRecovery = try #require(
      source.range(
        of: "commandRuns.recoverAtStartup()",
        range: herdrRecovery.upperBound..<source.endIndex
      )
    )
    let accountGate = try #require(source.range(of: "guard let account, let authorID"))
    let jobRecovery = try #require(
      source.range(
        of: "activeReloadComposition.recoverCoordinatorAtStartup()",
        range: accountGate.upperBound..<source.endIndex
      )
    )
    #expect(herdrRecovery.lowerBound < commandRecovery.lowerBound)
    #expect(commandRecovery.lowerBound < accountGate.lowerBound)
    #expect(commandRecovery.lowerBound < jobRecovery.lowerBound)
    #expect(source.contains("commandRuns: commandRuns"))
    #expect(source.contains("commandGate: commandGate"))
    #expect(source.contains("JobCanaryMarkerAuthorizationGate(authority: jobs)"))
    #expect(source.contains("canaryAuthorizer: canaryMarkerGate"))
    #expect(source.contains("canaryMarkerGate.begin(jobID:"))
    #expect(source.contains("canaryMarkerGate.end()"))
    #expect(source.contains("ownershipRuntime?.shutdownOwnedRoleHosts()"))
    for relativePath in [
      "Sources/JidokaCodeCore/Jobs/IssueTriageJobWorkflow.swift",
      "Sources/JidokaCodeCore/Jobs/PullRequestReviewJobWorkflow.swift",
      "Sources/JidokaCodeCore/Jobs/PiIssueImplementationExecutors.swift",
    ] {
      let workflowSource = try String(
        contentsOf: projectRoot().appendingPathComponent(relativePath),
        encoding: .utf8
      )
      #expect(!workflowSource.contains("PiRPCWorkflowExecutorFactory("))
      #expect(!workflowSource.contains("PiRPCProcessRunner("))
    }
  }

  @Test("external Pi closure drift cannot satisfy the release-owned production contract")
  func productionPiRuntimeIsReleaseOwned() throws {
    let probeSources = ["PiProbeCLI.swift", "WorkflowProbeCLI.swift", "LocalSpikeCLI.swift"]
      .map { projectRoot().appendingPathComponent("Sources/JidokaCodeApp/\($0)") }
    let sources = try
      ([productionRuntimeSource(), engineMainSource(), appClientSource()] + probeSources).map {
        try String(contentsOf: $0, encoding: .utf8)
      }
    let composition = sources.joined(separator: "\n")

    #expect(!composition.contains("configuration: .standard(resourceRoot:"))
    #expect(!composition.contains(".standard(resourceRoot:"))
    #expect(composition.contains("ReleaseOwnedPiRuntimeResolver("))
    #expect(!composition.contains("/opt/homebrew"))
    #expect(!composition.contains("/usr/local/bin/pi"))
    #expect(!composition.contains("DYLD_LIBRARY_PATH"))
  }

  @Test("ordinary release compilation excludes diagnostic and ad hoc runtime authority")
  func releaseCompilationExcludesDiagnosticRuntimeAuthority() throws {
    let resolverSource = try String(
      contentsOf: projectRoot().appendingPathComponent(
        "Sources/JidokaCodeCore/Pi/PiRuntimeResolver.swift"
      ),
      encoding: .utf8
    )
    let releaseRuntimeSource = try String(
      contentsOf: projectRoot().appendingPathComponent(
        "Sources/JidokaCodeCore/Pi/ReleaseOwnedPiRuntime.swift"
      ),
      encoding: .utf8
    )
    let appSource = try String(
      contentsOf: projectRoot().appendingPathComponent(
        "Sources/JidokaCodeApp/JidokaCodeApp.swift"
      ),
      encoding: .utf8
    )
    let probeSource = try ["PiProbeCLI.swift", "WorkflowProbeCLI.swift", "LocalSpikeCLI.swift"]
      .map {
        try String(
          contentsOf: projectRoot().appendingPathComponent("Sources/JidokaCodeApp/\($0)"),
          encoding: .utf8
        )
      }
      .joined(separator: "\n")
    let makefile = try String(
      contentsOf: projectRoot().appendingPathComponent("Makefile"),
      encoding: .utf8
    )
    let releaseResolver = unflaggedReleaseProjection(resolverSource)
    let releaseVerifier = unflaggedReleaseProjection(releaseRuntimeSource)
    let releaseApp = unflaggedReleaseProjection(appSource)
    let releaseProbes = unflaggedReleaseProjection(probeSource)

    for forbidden in [
      "/opt/homebrew", "/usr/local/bin/pi", "/usr/local/bin/node",
      "PiRuntimeResolverConfiguration", "diagnosticSystem(", "init(configuration:",
      "materializePrivateSnapshot", "resolvePi(", "resolveNode(", "validatePiCandidate(",
      "resolveMachODependency(",
    ] {
      #expect(!releaseResolver.contains(forbidden))
    }
    #expect(releaseResolver.contains("validateReleaseNodeMachO("))
    #expect(releaseResolver.contains("attestPackageTree("))
    #expect(releaseResolver.contains("actionableIssue("))
    for forbidden in [
      "verifyPackagedProbe", "verifyAdHocBundle", "verifyDeveloperIDBundle",
      "ReleaseOwnedPiRuntimeVerifier", "case stagedInput", "case adHocBundle",
      "case developerIDBundle", "allowAdHoc",
    ] {
      #expect(!releaseVerifier.contains(forbidden))
    }
    #expect(!releaseRuntimeSource.contains("verifyPackagedProbe"))
    #expect(!releaseApp.contains("--release-runtime-verify-adhoc"))
    #expect(!releaseApp.contains("--release-runtime-verify-developer-id"))
    #expect(releaseApp.contains("--release-runtime-verify-production"))
    #expect(releaseProbes.contains("ReleaseOwnedPiRuntimeResolver("))
    #expect(!releaseProbes.contains("ReleaseOwnedPiRuntimeVerifier"))
    #expect(!makefile.contains("NODE ?= node"))
    #expect(
      makefile.contains("override NODE := $(abspath $(JIDOKA_RELEASE_RUNTIME_ROOT))/node/bin/node"))
    #expect(makefile.contains("scripts/qualified-runtime-node.sh"))
  }

  @Test("all 13 actual production seams preserve one real release identity")
  func productionRuntimeBoundariesAreBehaviorDriven() throws {
    let fixture = try ReleaseOwnedRuntimeFixture()
    defer { fixture.remove() }
    let resolver = try CountingReleaseOwnedRuntimeResolver(resolver: fixture.resolver())
    let deniedLookup = FailingExternalRuntimeLookupSpy()
    var runtimes: [PiResolvedRuntime] = []

    try PiExternalRuntimeLookupTestSeam.$observer.withValue(deniedLookup) {
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.applicationStartupForTesting(
          using: resolver
        ))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.engineHelperStartupForTesting(
          using: resolver
        ))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.localEngineStartup(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.modelCatalogProcess(using: resolver))
      runtimes.append(try ReleaseOwnedPiRuntimeBoundaryAuthority.rpcProcess(using: resolver))
      runtimes.append(try ReleaseOwnedPiRuntimeBoundaryAuthority.tuiHost(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.initialHerdrPreparation(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.herdrRecoveryRetry(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.descriptorCreate(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.descriptorDecode(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.replacementCandidate(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.preCredentialExecution(using: resolver))
      runtimes.append(
        try ReleaseOwnedPiRuntimeBoundaryAuthority.finalPreSendProof(using: resolver))
    }

    let expectedCounts: [PiRuntimeResolutionBoundary: Int] = [
      .applicationStartup: 1,
      .engineHelperStartup: 1,
      .localEngineStartup: 1,
      .modelCatalogProcess: 1,
      .rpcProcess: 1,
      .tuiHost: 1,
      .initialHerdrPreparation: 1,
      .herdrRecoveryRetry: 1,
      .descriptorCreate: 1,
      .descriptorDecode: 1,
      .replacementCandidate: 1,
      .preCredentialExecution: 1,
      .finalPreSendProof: 1,
    ]
    let expectedIdentity = try #require(runtimes.first?.releaseIdentity)
    #expect(runtimes.count == 13)
    #expect(runtimes.allSatisfy { $0.releaseIdentity == expectedIdentity })
    #expect(resolver.boundaryAttemptCounts == expectedCounts)
    #expect(resolver.boundaryCounts == expectedCounts)
    #expect(resolver.unscopedResolutionCount == 0)
    #expect(deniedLookup.count == 0)
  }

  @Test("all 13 actual production seams deny release drift before effect")
  func productionRuntimeBoundariesDenyDriftBeforeEffect() throws {
    let fixture = try ReleaseOwnedRuntimeFixture()
    defer { fixture.remove() }
    let resolver = try CountingReleaseOwnedRuntimeResolver(resolver: fixture.resolver())
    let deniedLookup = FailingExternalRuntimeLookupSpy()
    try Data("boundary-drift\n".utf8).write(
      to: fixture.packageRoot.appendingPathComponent("dist/core/sdk.js")
    )
    var effectCount = 0

    func expectDriftDenied(_ operation: () throws -> PiResolvedRuntime) {
      do {
        _ = try operation()
        effectCount += 1
        Issue.record("release drift reached a production boundary effect")
      } catch let error as PiRuntimeResolutionError {
        #expect(error.code == .releaseRuntimeDrift)
      } catch {
        Issue.record("release drift failed opaquely: \(error)")
      }
    }

    PiExternalRuntimeLookupTestSeam.$observer.withValue(deniedLookup) {
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.applicationStartupForTesting(
          using: resolver
        )
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.engineHelperStartupForTesting(
          using: resolver
        )
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.localEngineStartup(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.modelCatalogProcess(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.rpcProcess(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.tuiHost(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.initialHerdrPreparation(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.herdrRecoveryRetry(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.descriptorCreate(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.descriptorDecode(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.replacementCandidate(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.preCredentialExecution(using: resolver)
      }
      expectDriftDenied {
        try ReleaseOwnedPiRuntimeBoundaryAuthority.finalPreSendProof(using: resolver)
      }
    }

    let expectedAttempts: [PiRuntimeResolutionBoundary: Int] = [
      .applicationStartup: 1,
      .engineHelperStartup: 1,
      .localEngineStartup: 1,
      .modelCatalogProcess: 1,
      .rpcProcess: 1,
      .tuiHost: 1,
      .initialHerdrPreparation: 1,
      .herdrRecoveryRetry: 1,
      .descriptorCreate: 1,
      .descriptorDecode: 1,
      .replacementCandidate: 1,
      .preCredentialExecution: 1,
      .finalPreSendProof: 1,
    ]
    #expect(effectCount == 0)
    #expect(resolver.boundaryAttemptCounts == expectedAttempts)
    #expect(resolver.boundaryCounts.isEmpty)
    #expect(resolver.unscopedResolutionCount == 0)
    #expect(deniedLookup.count == 0)
  }

  @Test("external lookup spy has a clean-machine throwing negative control")
  func externalRuntimeLookupSpyNegativeControl() throws {
    let spy = FailingExternalRuntimeLookupSpy()
    let resources = projectRoot().appendingPathComponent("Resources/Pi", isDirectory: true)
    let configuration = PiRuntimeResolverConfiguration(
      piCandidates: [URL(fileURLWithPath: "/clean-machine/absent/pi")],
      nodeCandidates: [URL(fileURLWithPath: "/clean-machine/absent/node")],
      piPolicyURL: resources.appendingPathComponent("runtime/pi-runtime-builds.json"),
      nodePolicyURL: resources.appendingPathComponent("runtime/node-runtime-builds.json")
    )
    do {
      try PiExternalRuntimeLookupTestSeam.$observer.withValue(spy) {
        _ = try PiRuntimeResolver(configuration: configuration).resolve()
      }
      Issue.record("external diagnostic resolver bypassed the fail-on-call spy")
    } catch let error as ExternalRuntimeLookupSpyError {
      #expect(error == .attempted)
    }
    #expect(spy.count == 1)
  }

  @Test("supplemental source routing names all finite production boundaries")
  func productionRuntimeBoundariesAreExplicit() throws {
    let expected: [String: String] = [
      "Sources/JidokaCodeApp/ApplicationEngineClient.swift": ".applicationStartup(",
      "Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift": ".engineHelperStartup(",
      "Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift":
        ".localEngineStartup(",
      "Sources/JidokaCodeCore/Pi/PiModelCatalog.swift": ".modelCatalogProcess(",
      "Sources/JidokaCodeCore/Pi/PiRPCWorkflowExecutor.swift": ".rpcProcess(",
      "Sources/JidokaCodeCore/Pi/PiTUIRuntime.swift": ".tuiHost(",
    ]
    for (path, boundary) in expected {
      let source = try String(
        contentsOf: projectRoot().appendingPathComponent(path),
        encoding: .utf8
      )
      #expect(source.contains(boundary))
    }
    let herdr = try String(
      contentsOf: projectRoot().appendingPathComponent(
        "Sources/JidokaCodeCore/Pi/HerdrPiWorkflowExecutor.swift"
      ),
      encoding: .utf8
    )
    for boundary in [
      ".initialHerdrPreparation(", ".herdrRecoveryRetry(", ".descriptorCreate(",
      ".descriptorDecode(", ".replacementCandidate(", ".preCredentialExecution(",
      ".finalPreSendProof(",
    ] {
      #expect(herdr.contains(boundary))
    }
  }

  @Test("packaged diagnostics stay inside one bounded process-group supervisor")
  func packagedDiagnosticsUseBoundedSupervisor() throws {
    for path in ["PiProbeCLI.swift", "WorkflowProbeCLI.swift", "LocalSpikeCLI.swift"] {
      let source = try String(
        contentsOf: projectRoot().appendingPathComponent("Sources/JidokaCodeApp/\(path)"),
        encoding: .utf8
      )
      #expect(source.contains("BoundedProcessRunner().runSynchronously("))
      #expect(!source.contains("let process = Process()"))
      #expect(source.contains("maximumOutputBytes:"))
    }
    for path in ["pi-rpc-profile-probe.mjs", "pi-rpc-workflow-probe.mjs"] {
      let source = try String(
        contentsOf: projectRoot().appendingPathComponent("scripts/spikes/\(path)"),
        encoding: .utf8
      )
      #expect(source.contains("detached: false"))
      #expect(!source.contains("detached: true"))
      #expect(!source.contains("process.kill(-"))
    }
  }

  @Test("packaging and source gates use the native microsecond-identity supervisor")
  func packageSupervisionIsNative() throws {
    for path in [
      "scripts/package-app.sh",
      "scripts/package-installer.sh",
      "scripts/qualified-runtime-node.sh",
      "scripts/spikes/test-s1-package.sh",
    ] {
      let source = try String(
        contentsOf: projectRoot().appendingPathComponent(path),
        encoding: .utf8
      )
      #expect(source.contains("JidokaCodeBoundedCommand"))
      #expect(!source.contains("run-bounded-command.pl"))
    }
    let compatibilityShim = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/run-bounded-command.pl"),
      encoding: .utf8
    )
    #expect(!compatibilityShim.contains("lstart"))
    #expect(!compatibilityShim.contains("/bin/ps"))
    #expect(!compatibilityShim.contains("process_snapshot"))
  }

  @Test("packaging verifies staged input before copy and creates inventory privately")
  func packageInputAndInventoryOrderIsClosed() throws {
    let source = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/package-app.sh"),
      encoding: .utf8
    )
    let verify = try #require(
      source.range(of: "verify_staged_runtime_performance \"$STAGED_RUNTIME_VERIFIER\"")
    )
    let copy = try #require(source.range(of: "\"$RELEASE_RUNTIME/pi\""))
    #expect(verify.lowerBound < copy.lowerBound)
    #expect(source.contains("/usr/bin/mktemp \"$BUILD_ROOT/.runtime-inventory.XXXXXX\""))
    #expect(source.contains("/bin/mv -f -- \"$RUNTIME_INVENTORY_TEMP\""))
    #expect(source.contains("generated release runtime inventory must not be a symbolic link"))
  }

  @Test("installer publishes only the validated copied and expanded payload")
  func installerPayloadSnapshotIsClosed() throws {
    let source = try String(
      contentsOf: projectRoot().appendingPathComponent("scripts/package-installer.sh"),
      encoding: .utf8
    )
    let snapshot = try #require(source.range(of: "/usr/bin/ditto \"$APP\" \"$COMPONENT_APP\""))
    let componentValidation = try #require(
      source.range(of: "--release-runtime-verify-developer-id \\\n    \"$COMPONENT_APP\"")
    )
    let package = try #require(source.range(of: "/usr/bin/pkgbuild"))
    let expansion = try #require(source.range(of: "--expand-full \"$PRODUCT_PACKAGE\""))
    let payloadValidation = try #require(
      source.range(of: "--release-runtime-verify-developer-id \\\n    \"$PAYLOAD_APP\"")
    )
    let byteComparison = try #require(
      source.range(
        of: "/usr/bin/cmp -s \"$COMPONENT_TREE_INVENTORY\" \"$PAYLOAD_TREE_INVENTORY\""
      )
    )
    #expect(
      source.contains("\"${verifier_build_arguments[@]}\" --product JidokaCodeApp")
    )
    #expect(
      source.contains("\"${verifier_build_arguments[@]}\" --product JidokaCodeBoundedCommand")
    )
    #expect(snapshot.lowerBound < componentValidation.lowerBound)
    #expect(componentValidation.lowerBound < package.lowerBound)
    #expect(package.lowerBound < expansion.lowerBound)
    #expect(expansion.lowerBound < payloadValidation.lowerBound)
    #expect(payloadValidation.lowerBound < byteComparison.lowerBound)
    #expect(source.contains("payloadTreeSHA256"))
    let postSnapshot = source[snapshot.upperBound...]
    #expect(!postSnapshot.contains("\"$APP\""))
    #expect(postSnapshot.contains("$PAYLOAD_APP"))
  }

  @Test("production endpoint and attestation resources cannot come from process input")
  func defaultSocketIsFixed() throws {
    let source = try String(contentsOf: engineMainSource(), encoding: .utf8)
    let appClient = try String(contentsOf: appClientSource(), encoding: .utf8)
    let protocolSource = try String(contentsOf: engineProtocolSource(), encoding: .utf8)
    #expect(source.contains(".appendingPathComponent(\".config/herdr/herdr.sock\""))
    #expect(appClient.contains(".appendingPathComponent(\".config/herdr/herdr.sock\""))
    #expect(!source.contains("ProcessInfo.processInfo.environment[\"HERDR_SOCKET_PATH\"]"))
    #expect(!appClient.contains("ProcessInfo.processInfo.environment[\"HERDR_SOCKET_PATH\"]"))
    #expect(!source.contains("sourceHerdrResources"))
    #expect(!appClient.contains("sourceHerdr"))
    #expect(protocolSource.contains(".runHerdrPreflight"))
    #expect(protocolSource.contains(".focusInHerdr"))
    #expect(source.contains("EngineCommandKind.productionHelperAllowedCommands"))
  }

  private func productionRuntimeSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeCore/Application/ProductionEngineJobRuntime.swift"
    )
  }

  private func engineMainSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeEngineProbe/JidokaCodeEngineMain.swift"
    )
  }

  private func appClientSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeApp/ApplicationEngineClient.swift"
    )
  }

  private func engineProtocolSource() -> URL {
    projectRoot().appendingPathComponent(
      "Sources/JidokaCodeCore/Application/EngineProtocol.swift"
    )
  }

  private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct ConditionalProjectionFrame {
  let parentIncluded: Bool
  let conditionMatched: Bool
}

private func unflaggedReleaseProjection(_ source: String) -> String {
  var included = true
  var frames: [ConditionalProjectionFrame] = []
  var projected: [Substring] = []
  for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let directive = line.trimmingCharacters(in: .whitespaces)
    if directive.hasPrefix("#if ") {
      let condition = String(directive.dropFirst("#if ".count))
      let matched =
        !condition.contains("DEBUG") && !condition.contains("JIDOKA_ADHOC_RUNTIME_TESTING")
      frames.append(
        ConditionalProjectionFrame(parentIncluded: included, conditionMatched: matched)
      )
      included = included && matched
    } else if directive == "#else", let frame = frames.last {
      included = frame.parentIncluded && !frame.conditionMatched
    } else if directive == "#endif", let frame = frames.popLast() {
      included = frame.parentIncluded
    } else if included {
      projected.append(line)
    }
  }
  return projected.joined(separator: "\n")
}

private enum ProductionReplacementBoundaryFailure: Error {
  case injected
}

enum ProductionReplacementBoundaryScenario: CaseIterable, Sendable {
  case noRemoteEffectFailure
  case remoteEffectAmbiguous
  case q4Prepared
  case q4Enqueued
  case q4OutcomeAmbiguous
  case q4Failed
  case q4Settled
  case replacementHostLost
  case thrownError
  case terminalReplay

  static let executionCases = allCases.filter { $0 != .terminalReplay }

  var outcome: JobCanaryRoleHostReplacementOutcome {
    switch self {
    case .noRemoteEffectFailure:
      .noRemoteEffectFailure(failureCode: "INVALID_PREPARATION")
    case .remoteEffectAmbiguous, .terminalReplay:
      .remoteEffectAmbiguous
    case .q4Prepared: .q4Prepared
    case .q4Enqueued: .q4Enqueued
    case .q4OutcomeAmbiguous:
      .q4OutcomeAmbiguous(failureCode: "RUNTIME_INTERRUPTED")
    case .q4Failed: .q4Failed(failureCode: "CHILD_FAILED")
    case .q4Settled, .thrownError: .q4Settled
    case .replacementHostLost: .replacementHostLost
    }
  }
}

private actor ProductionReplacementBoundaryProbe {
  private let scenario: ProductionReplacementBoundaryScenario
  private let authorization: JobCanaryRoleHostReplacementAuthorization
  private let canary: JobCanaryReport
  private let terminal: JobCanaryRoleHostReplacementReport
  private var terminalCallCount = 0
  private(set) var events: [String] = []
  private(set) var openMarkerCount = 0
  private(set) var openAdmissionCount = 0

  init(
    scenario: ProductionReplacementBoundaryScenario,
    authorization: JobCanaryRoleHostReplacementAuthorization,
    canary: JobCanaryReport,
    terminal: JobCanaryRoleHostReplacementReport
  ) {
    self.scenario = scenario
    self.authorization = authorization
    self.canary = canary
    self.terminal = terminal
  }

  func boundary() -> ProductionRoleHostReplacementBoundary {
    ProductionRoleHostReplacementBoundary(
      terminalReport: { request, _ in
        try await self.terminalReport(request: request)
      },
      resourceTreeSHA256: { await self.resourceTreeSHA256() },
      admitCanary: { canary, resource in
        try await self.admitCanary(canary, resource: resource)
      },
      candidate: { authorization, resource in
        try await self.candidate(authorization, resource: resource)
      },
      beginMarker: { jobID in try await self.beginMarker(jobID: jobID) },
      endMarker: { await self.endMarker() },
      beginLaunchAdmission: { jobID in await self.beginAdmission(jobID: jobID) },
      endLaunchAdmission: { await self.endAdmission() },
      runCoordinator: { request in try await self.runCoordinator(request: request) }
    )
  }

  private func terminalReport(
    request: JobCanaryRoleHostReplacementRequest
  ) throws -> JobCanaryRoleHostReplacementReport? {
    guard request == authorization.request else { throw EngineClientError(.staleEvidence) }
    terminalCallCount += 1
    events.append(terminalCallCount == 1 ? "terminal:initial" : "terminal:final")
    if scenario == .terminalReplay { return terminal }
    return terminalCallCount == 1 ? nil : (scenario == .thrownError ? nil : terminal)
  }

  private func resourceTreeSHA256() -> String {
    events.append("resource")
    return String(repeating: "7", count: 64)
  }

  private func admitCanary(
    _ candidate: JobCanaryAuthorization,
    resource: String
  ) throws -> JobCanaryApplication {
    guard candidate == authorization.request.retry.recovery.canary,
      resource == String(repeating: "7", count: 64)
    else { throw EngineClientError(.staleEvidence) }
    events.append("admit")
    return JobCanaryApplication(report: canary, shouldExecute: false)
  }

  private func candidate(
    _ candidate: JobCanaryRoleHostReplacementAuthorization,
    resource: String
  ) throws -> ProductionRoleHostReplacementCandidate {
    guard candidate == authorization, resource == String(repeating: "7", count: 64) else {
      throw EngineClientError(.staleEvidence)
    }
    events.append("candidate")
    return ProductionRoleHostReplacementCandidate(
      report: try productionReplacementReport(authorization: authorization, outcome: .preview),
      activate: { try await self.activate() }
    )
  }

  private func beginMarker(jobID: UUID) throws {
    guard jobID == authorization.request.retry.recovery.canary.scope.jobID else {
      throw EngineClientError(.staleEvidence)
    }
    events.append("marker:begin")
    openMarkerCount += 1
  }

  private func endMarker() {
    events.append("marker:end")
    openMarkerCount -= 1
  }

  private func beginAdmission(jobID: UUID) {
    guard jobID == authorization.request.retry.recovery.canary.scope.jobID else { return }
    events.append("admission:begin")
    openAdmissionCount += 1
  }

  private func endAdmission() {
    events.append("admission:end")
    openAdmissionCount -= 1
  }

  private func activate() throws {
    events.append("activate")
  }

  private func runCoordinator(request: JobCanaryRoleHostReplacementRequest) throws {
    guard request == authorization.request else { throw EngineClientError(.staleEvidence) }
    events.append("coordinator")
    if scenario != .q4Settled { throw ProductionReplacementBoundaryFailure.injected }
  }
}

private func productionReplacementAuthorization()
  -> JobCanaryRoleHostReplacementAuthorization
{
  let scope = JobCanaryScope(
    jobID: UUID(uuidString: "aaaaaaaa-1111-4111-8111-111111111111")!,
    boundaryEpochSeconds: JobCanaryScope.authorizedBoundaryEpochSeconds,
    repairEvidenceSHA256: String(repeating: "a", count: 64),
    maximumCommentParts: 8
  )
  let canary = JobCanaryAuthorization(
    scope: scope,
    previewEvidenceSHA256: String(repeating: "b", count: 64)
  )
  let recovery = JobCanaryRecoveryAuthorization(
    canary: canary,
    recoveryEvidenceSHA256: String(repeating: "c", count: 64)
  )
  let retry = JobCanaryPiRetryAuthorization(
    recovery: recovery,
    retryEvidenceSHA256: String(repeating: "d", count: 64)
  )
  let request = JobCanaryRoleHostReplacementRequest(
    retry: retry,
    incidentAuditSHA256: JobCanaryRoleHostReplacementRequest.authorizedIncidentAuditSHA256,
    plannedReplacementRoleHostID: "rolehost-11111111-1111-4111-8111-111111111111",
    plannedLaunchAttemptID: "launch-22222222-2222-4222-8222-222222222222"
  )
  return JobCanaryRoleHostReplacementAuthorization(
    request: request,
    replacementEvidenceSHA256: String(repeating: "e", count: 64),
    q4Binding: JobCanaryRoleHostReplacementQ4Binding(
      descriptorSHA256: String(repeating: "1", count: 64),
      configurationSHA256: String(repeating: "2", count: 64),
      promptSHA256: String(repeating: "3", count: 64),
      workflowConfigurationSHA256: String(repeating: "4", count: 64),
      priorLaunchDescriptorSHA256: String(repeating: "5", count: 64),
      priorLaunchConfigurationSHA256: String(repeating: "6", count: 64),
      resourceTreeSHA256: String(repeating: "7", count: 64)
    )
  )
}

private func productionReplacementCanaryReport(
  authorization: JobCanaryRoleHostReplacementAuthorization
) -> JobCanaryReport {
  JobCanaryReport(
    scope: authorization.request.retry.recovery.canary.scope,
    previewEvidenceSHA256:
      authorization.request.retry.recovery.canary.previewEvidenceSHA256,
    authorizationSHA256:
      authorization.request.retry.recovery.canary.authorizationSHA256,
    status: .recoveryRequired,
    repositoryOwner: "fixture",
    repositoryName: "replacement",
    objectNumber: 42,
    revisionKey: String(repeating: "f", count: 40),
    provider: "fixture",
    model: "fixture",
    thinking: "off",
    resourceTreeSHA256: authorization.q4Binding.resourceTreeSHA256,
    replayed: false
  )
}

private func productionReplacementReport(
  authorization: JobCanaryRoleHostReplacementAuthorization,
  outcome: JobCanaryRoleHostReplacementOutcome
) throws -> JobCanaryRoleHostReplacementReport {
  try JobCanaryRoleHostReplacementReport(
    jobID: authorization.request.retry.recovery.canary.scope.jobID,
    runID: "run-33333333-3333-4333-8333-333333333333",
    predecessorRoleHostID: "rolehost-44444444-4444-4444-8444-444444444444",
    replacementRoleHostID: authorization.request.plannedReplacementRoleHostID,
    plannedLaunchAttemptID: authorization.request.plannedLaunchAttemptID,
    incidentAuditSHA256: authorization.request.incidentAuditSHA256,
    replacementEvidenceSHA256: authorization.replacementEvidenceSHA256,
    replacementAuthorizationSHA256: outcome == .preview
      ? nil : authorization.authorizationSHA256,
    q4Binding: authorization.q4Binding,
    outcome: outcome,
    replayed: false
  )
}

private actor ProductionRuntimeLogFake: EngineEventLogging {
  private(set) var records: [EngineLogRecord] = []

  func record(_ record: EngineLogRecord) {
    records.append(record)
  }
}

private struct ProductionRuntimeReadinessFake: HerdrRuntimeReadinessChecking {
  func preflight() -> EngineHerdrStatus {
    EngineHerdrStatus(state: .blocked)
  }
}

private enum ExternalRuntimeLookupSpyError: Error, Equatable {
  case attempted
}

private final class FailingExternalRuntimeLookupSpy:
  PiExternalRuntimeLookupObserving, @unchecked Sendable
{
  private let lock = NSLock()
  private var attempts = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts
  }

  func externalRuntimeLookupAttempted() throws {
    lock.lock()
    attempts += 1
    lock.unlock()
    throw ExternalRuntimeLookupSpyError.attempted
  }
}
