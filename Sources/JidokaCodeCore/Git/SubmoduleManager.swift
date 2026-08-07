import Darwin
import Foundation

public enum SubmoduleSource: Equatable, Sendable {
  case relative(String)
  case github(owner: String, repository: String, canonicalURL: String)
}

public struct SubmoduleEntry: Equatable, Sendable {
  public let name: String
  public let path: String
  public let source: SubmoduleSource
}

public struct SubmoduleMirror: Equatable, Sendable {
  public let sourceIdentity: String
  public let mirrorURL: URL

  public init(sourceIdentity: String, mirrorURL: URL) {
    self.sourceIdentity = sourceIdentity
    self.mirrorURL = mirrorURL
  }
}

public enum SubmoduleManagerError: Error, Equatable, Sendable {
  case unsafeGitmodules
  case malformedGitmodules
  case duplicateEntry
  case invalidName
  case invalidPath
  case unsupportedRemote(String)
  case mirrorUnavailable(String)
  case unsafeMirror
  case materializationFailed
  case nestedSubmoduleUnsupported(String)
  case duplicateMirror(String)
}

public enum SubmoduleInventory {
  public static func load(workspace: URL) throws -> [SubmoduleEntry] {
    let file = workspace.appendingPathComponent(".gitmodules")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let values = try file.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? 0) <= 1_048_576
    else {
      throw SubmoduleManagerError.unsafeGitmodules
    }
    let data = try Data(contentsOf: file)
    guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else {
      throw SubmoduleManagerError.malformedGitmodules
    }
    return try parse(text)
  }

  public static func parse(_ text: String) throws -> [SubmoduleEntry] {
    struct Pending {
      var name: String
      var path: String?
      var url: String?
    }
    var entries: [SubmoduleEntry] = []
    var pending: Pending?

    func finish(_ value: Pending?) throws -> SubmoduleEntry? {
      guard let value else { return nil }
      guard let path = value.path, let url = value.url else {
        throw SubmoduleManagerError.malformedGitmodules
      }
      return try SubmoduleEntry(
        name: value.name,
        path: validate(path: path),
        source: classify(url: url)
      )
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
      if line.hasPrefix("[") {
        if let completed = try finish(pending) { entries.append(completed) }
        guard line.hasPrefix("[submodule \""), line.hasSuffix("\"]") else {
          throw SubmoduleManagerError.malformedGitmodules
        }
        let name = String(line.dropFirst(12).dropLast(2))
        guard validName(name) else { throw SubmoduleManagerError.invalidName }
        pending = Pending(name: name, path: nil, url: nil)
        continue
      }
      guard var current = pending, let separator = line.firstIndex(of: "=") else {
        throw SubmoduleManagerError.malformedGitmodules
      }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { throw SubmoduleManagerError.malformedGitmodules }
      switch key {
      case "path":
        guard current.path == nil else { throw SubmoduleManagerError.duplicateEntry }
        current.path = value
      case "url":
        guard current.url == nil else { throw SubmoduleManagerError.duplicateEntry }
        current.url = value
      default:
        throw SubmoduleManagerError.malformedGitmodules
      }
      pending = current
    }
    if let completed = try finish(pending) { entries.append(completed) }
    guard entries.count <= 1_000,
      Set(entries.map(\.name)).count == entries.count,
      Set(entries.map(\.path)).count == entries.count
    else {
      throw SubmoduleManagerError.duplicateEntry
    }
    return entries.sorted { $0.path < $1.path }
  }

  public static func sourceIdentity(_ source: SubmoduleSource) -> String {
    switch source {
    case .relative(let value): "relative:\(value)"
    case .github(_, _, let canonicalURL): "github:\(canonicalURL)"
    }
  }

  private static func classify(url: String) throws -> SubmoduleSource {
    guard url.utf8.count <= 1_024, !url.contains("\u{0}") else {
      throw SubmoduleManagerError.unsupportedRemote("invalid")
    }
    if url.hasPrefix("../") || url.hasPrefix("./") {
      guard !url.hasPrefix("../../"), !url.contains("/../") else {
        throw SubmoduleManagerError.unsupportedRemote(url)
      }
      return .relative(url)
    }
    guard let parsed = URL(string: url), parsed.absoluteString == url,
      parsed.scheme == "https", parsed.host == "github.com",
      parsed.user == nil, parsed.password == nil,
      parsed.query == nil, parsed.fragment == nil
    else {
      throw SubmoduleManagerError.unsupportedRemote(url)
    }
    let components = parsed.path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 2,
      GitHubInputValidation.validOwner(String(components[0]))
    else {
      throw SubmoduleManagerError.unsupportedRemote(url)
    }
    let rawRepository = String(components[1])
    let repository =
      rawRepository.hasSuffix(".git")
      ? String(rawRepository.dropLast(4)) : rawRepository
    guard GitHubInputValidation.validRepository(repository) else {
      throw SubmoduleManagerError.unsupportedRemote(url)
    }
    let canonicalURL = "https://github.com/\(components[0])/\(repository).git"
    guard url == canonicalURL || url == String(canonicalURL.dropLast(4)) else {
      throw SubmoduleManagerError.unsupportedRemote(url)
    }
    return .github(
      owner: String(components[0]),
      repository: repository,
      canonicalURL: canonicalURL
    )
  }

  private static func validate(path: String) throws -> String {
    guard !path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= 1_024,
      !path.contains("\u{0}"), !path.contains("//")
    else {
      throw SubmoduleManagerError.invalidPath
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git"
      })
    else {
      throw SubmoduleManagerError.invalidPath
    }
    return path
  }

  private static func validName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 200 else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { component in
      !component.isEmpty && component != "." && component != ".." && component != ".git"
        && component.utf8.allSatisfy { byte in
          (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || [45, 46, 95].contains(byte)
        }
    }
  }
}

public actor SubmoduleManager {
  private let git: any GitLocalCommanding

  public init(git: any GitLocalCommanding) {
    self.git = git
  }

  public func materialize(
    workspace: URL,
    entries: [SubmoduleEntry],
    mirrors: [SubmoduleMirror]
  ) async throws {
    var mirrorsByIdentity: [String: URL] = [:]
    for mirror in mirrors {
      if let existing = mirrorsByIdentity[mirror.sourceIdentity] {
        guard existing.standardizedFileURL == mirror.mirrorURL.standardizedFileURL else {
          throw SubmoduleManagerError.duplicateMirror(mirror.sourceIdentity)
        }
      } else {
        mirrorsByIdentity[mirror.sourceIdentity] = mirror.mirrorURL
      }
    }
    var workspaceAttributes = stat()
    guard workspace.isFileURL, workspace.path.hasPrefix("/"),
      lstat(workspace.path, &workspaceAttributes) == 0,
      (workspaceAttributes.st_mode & S_IFMT) == S_IFDIR
    else {
      throw SubmoduleManagerError.invalidPath
    }
    let workspaceRoot = workspace.resolvingSymlinksInPath().standardizedFileURL.path
    var resolved: [(SubmoduleEntry, URL)] = []
    for entry in entries {
      let identity = SubmoduleInventory.sourceIdentity(entry.source)
      guard let mirror = mirrorsByIdentity[identity] else {
        throw SubmoduleManagerError.mirrorUnavailable(identity)
      }
      var mirrorAttributes = stat()
      guard mirror.isFileURL, mirror.path.hasPrefix("/"),
        lstat(mirror.path, &mirrorAttributes) == 0,
        (mirrorAttributes.st_mode & S_IFMT) == S_IFDIR,
        (mirrorAttributes.st_mode & 0o077) == 0,
        mirrorAttributes.st_uid == geteuid()
      else {
        throw SubmoduleManagerError.unsafeMirror
      }
      let destination = workspace.appendingPathComponent(entry.path)
      let parent = destination.deletingLastPathComponent()
        .resolvingSymlinksInPath().standardizedFileURL.path
      guard parent == workspaceRoot || parent.hasPrefix(workspaceRoot + "/") else {
        throw SubmoduleManagerError.invalidPath
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        let destinationValues = try destination.resourceValues(forKeys: [
          .isSymbolicLinkKey
        ])
        guard destinationValues.isSymbolicLink != true else {
          throw SubmoduleManagerError.invalidPath
        }
      }
      resolved.append((entry, mirror))
    }

    for (entry, mirror) in resolved {
      let key = "submodule.\(entry.name).url"
      try await requireSuccess(
        git.runLocalGit(
          arguments: ["-C", workspace.path, "config", "--local", key, mirror.path],
          workingDirectory: workspace,
          timeoutSeconds: 30,
          maximumOutputBytes: 1_048_576,
          environmentOverrides: [:]
        ))
    }
    if !entries.isEmpty {
      let paths = entries.map(\.path)
      try await requireSuccess(
        git.runLocalGit(
          arguments: [
            "-C", workspace.path, "submodule", "update", "--init", "--",
          ] + paths,
          workingDirectory: workspace,
          timeoutSeconds: 300,
          maximumOutputBytes: 8 * 1_024 * 1_024,
          environmentOverrides: ["GIT_ALLOW_PROTOCOL": "file"]
        ))
      for entry in entries {
        let nestedWorkspace = workspace.appendingPathComponent(entry.path, isDirectory: true)
        let nestedEntries = try SubmoduleInventory.load(workspace: nestedWorkspace)
        if !nestedEntries.isEmpty {
          throw SubmoduleManagerError.nestedSubmoduleUnsupported(entry.path)
        }
      }
    }
  }

  private func requireSuccess(_ result: GitProcessResult) throws {
    guard result.succeeded else { throw SubmoduleManagerError.materializationFailed }
  }
}
