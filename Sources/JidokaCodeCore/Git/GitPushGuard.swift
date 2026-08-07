import Foundation

public enum GitPushGuardError: Error, Equatable, Sendable {
  case invalidArguments
  case invalidEnvironment
  case invalidInput
  case remoteReferenceExists
}

public enum GitPushGuard {
  public static func validate(
    arguments: [String],
    environment: [String: String],
    input: Data
  ) throws {
    guard arguments.count == 2 else { throw GitPushGuardError.invalidArguments }
    guard let expectedRemote = environment["JIDOKA_PUSH_GUARD_REMOTE"],
      let expectedReference = environment["JIDOKA_PUSH_GUARD_REFERENCE"],
      let expectedSHA = environment["JIDOKA_PUSH_GUARD_SHA"],
      validRemote(expectedRemote),
      expectedReference.hasPrefix("refs/heads/"),
      GitHubInputValidation.validBranch(
        String(expectedReference.dropFirst("refs/heads/".count))
      ),
      GitHubInputValidation.validGitSHA(expectedSHA)
    else {
      throw GitPushGuardError.invalidEnvironment
    }
    guard arguments == [expectedRemote, expectedRemote] else {
      throw GitPushGuardError.invalidArguments
    }
    guard !input.isEmpty, input.count <= 2_048, input.last == 0x0A,
      !input.dropLast().contains(0x0A), !input.contains(0x0D), !input.contains(0x00),
      let line = String(data: input.dropLast(), encoding: .utf8)
    else {
      throw GitPushGuardError.invalidInput
    }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 4,
      fields[0] == Substring(expectedSHA),
      fields[1] == Substring(expectedSHA),
      fields[2] == Substring(expectedReference)
    else {
      throw GitPushGuardError.invalidInput
    }
    guard fields[3] == Substring(String(repeating: "0", count: 40)) else {
      throw GitPushGuardError.remoteReferenceExists
    }
  }

  static func validRemote(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 2_048, !value.contains("\u{0}"),
      !value.unicodeScalars.contains(where: CharacterSet.newlines.contains),
      let url = URL(string: value), url.absoluteString == value,
      url.query == nil, url.fragment == nil
    else {
      return false
    }
    if url.isFileURL {
      return url.path.hasPrefix("/") && url.user == nil && url.password == nil
    }
    guard url.scheme == "https", url.host == "github.com", url.port == nil,
      url.user == "x-access-token", url.password == nil
    else {
      return false
    }
    let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 2,
      GitHubInputValidation.validOwner(String(components[0]))
    else {
      return false
    }
    let owner = String(components[0])
    let rawRepository = String(components[1])
    guard rawRepository.hasSuffix(".git") else { return false }
    let repository = String(rawRepository.dropLast(4))
    return GitHubInputValidation.validRepository(repository)
      && value == "https://x-access-token@github.com/\(owner)/\(repository).git"
  }
}
