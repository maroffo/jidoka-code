import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("App-versioned Pi workflow resources and runtime configuration")
struct PiWorkflowResourceTests {
  @Test("exact manifest attests every production extension, policy, and skill")
  func resourceCatalog() throws {
    let catalog = try PiWorkflowResourceCatalog.inspect(resourceRoot: sourceResourceRoot())

    #expect(catalog.manifestSHA256 == PiWorkflowResourceCatalog.workflowManifestSHA256)
    #expect(catalog.resourceSHA256.count == 13)
    #expect(Set(catalog.resourceSHA256.keys) == PiWorkflowResourceCatalog.expectedResourcePaths)
    #expect(catalog.runtimeExtensionURL.lastPathComponent == "jidoka-code.ts")
    #expect(catalog.blockerExtensionURL.lastPathComponent == "jidoka-deny-user-bash.js")
    #expect(
      PiWorkflowResourceCatalog.readOnlyToolNames == [
        "jidoka_code_preflight",
        "jidoka_code_read",
        "jidoka_code_result",
        "jidoka_code_workspace_query",
      ])
    #expect(
      PiWorkflowResourceCatalog.writerToolNames == [
        "jidoka_code_edit",
        "jidoka_code_preflight",
        "jidoka_code_read",
        "jidoka_code_result",
        "jidoka_code_workspace_query",
        "jidoka_code_write",
      ])
    #expect(
      PiWorkflowResourceCatalog.writerToolNames.allSatisfy {
        !["bash", "edit", "find", "grep", "ls", "read", "write"].contains($0)
      })
  }

  @Test("workflow and role select only the primary skill plus one fixed role skill")
  func skillRouting() throws {
    let catalog = try PiWorkflowResourceCatalog.inspect(resourceRoot: sourceResourceRoot())

    #expect(
      try catalog.skillURLs(workflow: .planning, role: .writer).map {
        $0.deletingLastPathComponent().lastPathComponent
      } == ["jidoka-code-plan"]
    )
    #expect(
      try catalog.skillURLs(workflow: .planning, role: .security).map {
        $0.deletingLastPathComponent().lastPathComponent
      } == ["jidoka-code-plan", "jidoka-code-review-security"]
    )
    #expect(
      try catalog.skillURLs(workflow: .pullRequestReview, role: .synthesis).map {
        $0.deletingLastPathComponent().lastPathComponent
      } == ["jidoka-code-pr-review", "jidoka-code-synthesize"]
    )
    #expect(throws: PiWorkflowResourceError.invalidWorkflowRole) {
      try catalog.skillURLs(workflow: .issueTriage, role: .writer)
    }
  }

  @Test("command provenance has no user or project resource")
  func exactCommandProvenance() throws {
    let catalog = try PiWorkflowResourceCatalog.inspect(resourceRoot: sourceResourceRoot())
    let commands = try catalog.expectedCommandProvenance(
      workflow: .orchestration,
      role: .architecture
    )

    #expect(
      commands.map(\.name).sorted() == [
        "jidoka-code-preflight",
        "llama",
        "skill:jidoka-code-orchestrate",
        "skill:jidoka-code-review-architecture",
      ])
    #expect(commands.allSatisfy { $0.scope == "temporary" && $0.origin == "top-level" })
    #expect(commands.allSatisfy { !$0.path.contains("/.pi/") && !$0.path.contains("/.agents/") })
  }

  @Test("mutated manifest, resource byte, and resource symlink fail closed")
  func resourceMutation() throws {
    let fixture = try WorkflowResourceFixture()
    defer { fixture.remove() }

    try Data("\n".utf8).append(to: fixture.root.appendingPathComponent("workflow-resources.json"))
    #expect(throws: PiWorkflowResourceError.manifestDigestMismatch) {
      try PiWorkflowResourceCatalog.inspect(resourceRoot: fixture.root)
    }

    try fixture.reset()
    try Data("mutated\n".utf8).write(
      to: fixture.root.appendingPathComponent("skills/jidoka-code-plan/SKILL.md")
    )
    #expect(
      throws: PiWorkflowResourceError.resourceDigestMismatch(
        "skills/jidoka-code-plan/SKILL.md"
      )
    ) {
      try PiWorkflowResourceCatalog.inspect(resourceRoot: fixture.root)
    }

    try fixture.reset()
    let skill = fixture.root.appendingPathComponent("skills/jidoka-code-plan/SKILL.md")
    let external = fixture.container.appendingPathComponent("external-skill.md")
    try FileManager.default.moveItem(at: skill, to: external)
    try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: external)
    #expect(
      throws: PiWorkflowResourceError.unsafeResource(
        "skills/jidoka-code-plan/SKILL.md"
      )
    ) {
      try PiWorkflowResourceCatalog.inspect(resourceRoot: fixture.root)
    }

    try fixture.reset()
    let skillDirectory = fixture.root.appendingPathComponent("skills/jidoka-code-plan")
    let externalDirectory = fixture.container.appendingPathComponent("external-plan-directory")
    try FileManager.default.moveItem(at: skillDirectory, to: externalDirectory)
    try FileManager.default.createSymbolicLink(
      at: skillDirectory,
      withDestinationURL: externalDirectory
    )
    #expect(
      throws: PiWorkflowResourceError.unsafeResource(
        "skills/jidoka-code-plan/SKILL.md"
      )
    ) {
      try PiWorkflowResourceCatalog.inspect(resourceRoot: fixture.root)
    }

    try fixture.reset()
    let linkedSkill = fixture.root.appendingPathComponent(
      "skills/jidoka-code-plan/SKILL.md"
    )
    let externalHardLink = fixture.container.appendingPathComponent("external-hardlink.md")
    try FileManager.default.copyItem(at: linkedSkill, to: externalHardLink)
    try FileManager.default.removeItem(at: linkedSkill)
    try FileManager.default.linkItem(at: externalHardLink, to: linkedSkill)
    #expect(
      throws: PiWorkflowResourceError.unsafeResource(
        "skills/jidoka-code-plan/SKILL.md"
      )
    ) {
      try PiWorkflowResourceCatalog.inspect(resourceRoot: fixture.root)
    }
  }

  @Test("runtime configuration derives tool policy and writes one private immutable file")
  func runtimeConfiguration() throws {
    let fixture = try RuntimeConfigurationFixture()
    defer { fixture.remove() }
    let configuration = try PiWorkflowRuntimeConfiguration(
      workflow: .orchestration,
      role: .writer,
      nonce: "nonce-12345678",
      artifactSHA256: String(repeating: "a", count: 64),
      allowedCommandIDs: ["test", "check"],
      allowedWritePaths: ["Tests", "Sources/Feature"],
      workspaceRoot: fixture.workspace,
      resources: fixture.catalog
    )
    let destination = fixture.privateDirectory.appendingPathComponent("workflow.json")

    try configuration.write(to: destination)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)

    #expect(configuration.toolPolicy == .writer)
    #expect(object["toolPolicy"] as? String == "writer")
    #expect(object["allowedCommandIDs"] as? [String] == ["check", "test"])
    #expect(
      Set(object.keys)
        == Set([
          "allowedCommandIDs",
          "allowedWritePaths",
          "artifactSHA256",
          "contractVersion",
          "nonce",
          "resourceManifestPath",
          "resourceManifestSHA256",
          "resourceRoot",
          "role",
          "schemaVersion",
          "toolPolicy",
          "workflow",
          "workspaceRoot",
        ]))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(!String(decoding: try configuration.encoded(), as: UTF8.self).contains("TOKEN"))
    #expect(throws: PiWorkflowResourceError.configurationAlreadyExists) {
      try configuration.write(to: destination)
    }
  }

  @Test("read-only roles and unsafe paths cannot gain a write surface")
  func invalidRuntimeConfiguration() throws {
    let fixture = try RuntimeConfigurationFixture()
    defer { fixture.remove() }

    #expect(throws: PiWorkflowResourceError.invalidRuntimeConfiguration) {
      try PiWorkflowRuntimeConfiguration(
        workflow: .pullRequestReview,
        role: .security,
        nonce: "nonce-12345678",
        artifactSHA256: String(repeating: "a", count: 64),
        allowedCommandIDs: [],
        allowedWritePaths: ["Sources"],
        workspaceRoot: fixture.workspace,
        resources: fixture.catalog
      )
    }
    for unsafePath in [
      "../outside", ".GIT/config", ".GiT/hooks", ".PI/settings.json", ".AGENTS/policy.md",
    ] {
      #expect(throws: PiWorkflowResourceError.invalidRuntimeConfiguration) {
        try PiWorkflowRuntimeConfiguration(
          workflow: .planning,
          role: .writer,
          nonce: "nonce-12345678",
          artifactSHA256: String(repeating: "a", count: 64),
          allowedCommandIDs: [],
          allowedWritePaths: [unsafePath],
          workspaceRoot: fixture.workspace,
          resources: fixture.catalog
        )
      }
    }
  }

  private func sourceResourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
  }
}

private final class WorkflowResourceFixture {
  let container: URL
  let root: URL
  private let source: URL

  init() throws {
    source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .resolvingSymlinksInPath()
    container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-workflow-resources-\(UUID().uuidString)",
      isDirectory: true
    ).resolvingSymlinksInPath()
    root = container.appendingPathComponent("Pi", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try reset()
  }

  func reset() throws {
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
    try FileManager.default.copyItem(at: source, to: root)
  }

  func remove() {
    try? FileManager.default.removeItem(at: container)
  }
}

private final class RuntimeConfigurationFixture {
  let container: URL
  let workspace: URL
  let privateDirectory: URL
  let catalog: PiWorkflowResourceCatalog

  init() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Pi", isDirectory: true)
      .resolvingSymlinksInPath()
    catalog = try PiWorkflowResourceCatalog.inspect(resourceRoot: source)
    container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jidoka-workflow-config-\(UUID().uuidString)",
      isDirectory: true
    ).resolvingSymlinksInPath()
    workspace = container.appendingPathComponent("workspace", isDirectory: true)
    privateDirectory = container.appendingPathComponent("private", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
    for directory in [workspace, privateDirectory] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: container)
  }
}

extension Data {
  fileprivate func append(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: self)
  }
}
