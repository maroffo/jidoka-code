import Foundation
import Testing

@testable import JidokaCodeCore

@Suite("Broker-localized Git submodules")
struct SubmoduleManagerTests {
  @Test("inventory is strict and rejects network shapes outside canonical GitHub HTTPS")
  func inventory() throws {
    let entries = try SubmoduleInventory.parse(
      """
      [submodule "local"]
        path = Dependencies/local
        url = ../local.git
      [submodule "public"]
        path = Dependencies/public
        url = https://github.com/owner/public.git
      """
    )
    #expect(entries.count == 2)
    #expect(entries[0].source == .relative("../local.git"))
    #expect(
      entries[1].source
        == .github(
          owner: "owner",
          repository: "public",
          canonicalURL: "https://github.com/owner/public.git"
        )
    )
    for value in [
      """
      [submodule "private"]
        path = Dependencies/private
        url = git@github.com:owner/private.git
      """,
      """
      [submodule "escape"]
        path = ../escape
        url = ../local.git
      """,
      """
      [submodule "unknown"]
        path = Dependencies/value
        url = ../local.git
        update = !command
      """,
    ] {
      #expect(throws: SubmoduleManagerError.self) {
        _ = try SubmoduleInventory.parse(value)
      }
    }
  }

  @Test("local mirror override materializes without contacting the declared URL")
  func materialization() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-submodule")
    defer { fixture.remove() }
    let submodule = try await fixture.initializeRepository(name: "submodule-source")
    _ = try await fixture.commit(
      repository: submodule,
      path: "VALUE.txt",
      contents: "localized\n",
      message: "chore: add submodule fixture"
    )
    let submoduleRemote = try await fixture.bareRemote(
      from: submodule,
      name: "submodule.git"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: submoduleRemote.path
    )

    let superproject = try await fixture.initializeRepository(name: "superproject")
    try await fixture.run([
      "-C", superproject.path,
      "-c", "protocol.file.allow=always",
      "submodule", "add", submoduleRemote.path, "Dependencies/local",
    ])
    let modules = superproject.appendingPathComponent(".gitmodules")
    var text = try String(contentsOf: modules, encoding: .utf8)
    text = text.replacingOccurrences(of: submoduleRemote.path, with: "../submodule.git")
    try text.write(to: modules, atomically: true, encoding: .utf8)
    try await fixture.run([
      "-C", superproject.path, "add", ".gitmodules", "Dependencies/local",
    ])
    try await fixture.run([
      "-C", superproject.path, "commit", "-m", "chore: add localized submodule",
    ])

    let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    try await fixture.run(["clone", "--no-hardlinks", superproject.path, workspace.path])
    let entries = try SubmoduleInventory.load(workspace: workspace)
    let entry = try #require(entries.count == 1 ? entries.first : nil)
    let manager = SubmoduleManager(git: fixture.git)
    try await manager.materialize(
      workspace: workspace,
      entries: entries,
      mirrors: [
        SubmoduleMirror(
          sourceIdentity: "relative:../submodule.git",
          mirrorURL: submoduleRemote
        )
      ]
    )
    #expect(
      try String(
        contentsOf: workspace.appendingPathComponent("Dependencies/local/VALUE.txt"),
        encoding: .utf8
      ) == "localized\n"
    )
    #expect(
      try await fixture.output([
        "-C", workspace.path, "config", "--local", "--get",
        "submodule.\(entry.name).url",
      ]) == submoduleRemote.path
    )
  }

  @Test("nested inventories stop before any recursive network invocation")
  func nestedInventory() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-submodule-nested")
    defer { fixture.remove() }
    let nested = fixture.root.appendingPathComponent("Dependencies/local", isDirectory: true)
    let mirror = fixture.root.appendingPathComponent("nested.git", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: mirror,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try """
    [submodule "child"]
      path = Child
      url = ../child.git
    """.write(
      to: nested.appendingPathComponent(".gitmodules"),
      atomically: true,
      encoding: .utf8
    )
    let git = CountingLocalGit()
    let manager = SubmoduleManager(git: git)
    await #expect(
      throws: SubmoduleManagerError.nestedSubmoduleUnsupported("Dependencies/local")
    ) {
      try await manager.materialize(
        workspace: fixture.root,
        entries: [
          SubmoduleEntry(
            name: "local",
            path: "Dependencies/local",
            source: .relative("../local.git")
          )
        ],
        mirrors: [
          SubmoduleMirror(
            sourceIdentity: "relative:../local.git",
            mirrorURL: mirror
          )
        ]
      )
    }
    let invocations = await git.invocations()
    #expect(invocations.count == 2)
    #expect(!invocations.flatMap { $0 }.contains("--recursive"))
  }

  @Test("a symbolic ancestor cannot redirect submodule materialization")
  func symbolicAncestor() async throws {
    let fixture = try GitTestRoot(prefix: "jidoka-submodule-symlink")
    defer { fixture.remove() }
    let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    let mirror = fixture.root.appendingPathComponent("mirror.git", isDirectory: true)
    for directory in [workspace, outside, mirror] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try FileManager.default.createSymbolicLink(
      at: workspace.appendingPathComponent("Dependencies"),
      withDestinationURL: outside
    )
    let git = CountingLocalGit()
    await #expect(throws: SubmoduleManagerError.invalidPath) {
      try await SubmoduleManager(git: git).materialize(
        workspace: workspace,
        entries: [
          SubmoduleEntry(
            name: "escape",
            path: "Dependencies/escape",
            source: .relative("../escape.git")
          )
        ],
        mirrors: [
          SubmoduleMirror(
            sourceIdentity: "relative:../escape.git",
            mirrorURL: mirror
          )
        ]
      )
    }
    #expect(await git.calls() == 0)
  }

  @Test("missing mirror escalates before any Git subprocess")
  func missingMirror() async {
    let git = CountingLocalGit()
    let manager = SubmoduleManager(git: git)
    let workspace = FileManager.default.temporaryDirectory
    await #expect(throws: SubmoduleManagerError.mirrorUnavailable("relative:../missing.git")) {
      try await manager.materialize(
        workspace: workspace,
        entries: [
          SubmoduleEntry(
            name: "missing",
            path: "Dependencies/missing",
            source: .relative("../missing.git")
          )
        ],
        mirrors: []
      )
    }
    #expect(await git.calls() == 0)
  }
}

private actor CountingLocalGit: GitLocalCommanding {
  private var argumentsByCall: [[String]] = []

  func runLocalGit(
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String]
  ) async throws -> GitProcessResult {
    argumentsByCall.append(arguments)
    return GitProcessResult(
      exitCode: 0,
      terminationSignal: nil,
      timedOut: false,
      outputLimitExceeded: false,
      stdout: Data(),
      stderr: Data(),
      durationSeconds: 0
    )
  }

  func calls() -> Int { argumentsByCall.count }
  func invocations() -> [[String]] { argumentsByCall }
}
