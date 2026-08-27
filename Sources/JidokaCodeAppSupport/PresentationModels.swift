import Foundation
import JidokaCodeCore

public struct PresentationMessage: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let detail: String

  public init(id: UUID = UUID(), title: String, detail: String) {
    self.id = id
    self.title = title
    self.detail = detail
  }
}

public enum PresentationCopy {
  public static func modelCatalogUnavailable() -> PresentationMessage {
    PresentationMessage(
      title: "Pi model catalog unavailable",
      detail:
        "Jidoka Code could not load Pi's offline model catalog. Existing profiles remain "
        + "available as Custom. Verify the installed app and Pi runtime, then retry."
    )
  }

  public static func message(for error: Error) -> PresentationMessage {
    let code = (error as? EngineClientError)?.code ?? .internalFailure
    return switch code {
    case .invalidCommand, .invalidRequest, .invalidResponse, .unsupportedVersion:
      PresentationMessage(
        title: "Request rejected",
        detail: "The app and engine could not validate this request. Restart Jidoka Code."
      )
    case .unavailable:
      PresentationMessage(
        title: "Engine unavailable",
        detail: "Open Login Item settings or retry after the helper becomes available."
      )
    case .timedOut:
      PresentationMessage(
        title: "Engine still busy",
        detail: "The current durable operation did not reach a checkpoint in time."
      )
    case .busy:
      PresentationMessage(
        title: "Operation in progress",
        detail: "Wait for the current durable operation, then retry."
      )
    case .staleEvidence:
      PresentationMessage(
        title: "Evidence changed",
        detail: "Refresh status and review the current exact mutation evidence."
      )
    case .onboardingIncomplete:
      PresentationMessage(
        title: "Setup incomplete",
        detail: "Complete every required onboarding check before enabling automation."
      )
    case .credentialRejected:
      PresentationMessage(
        title: "Credential not accepted",
        detail: "Validate a GitHub token with the required repository permissions."
      )
    case .credentialInUse:
      PresentationMessage(
        title: "Credential is in use",
        detail: "Resolve all active and ambiguous jobs before changing GitHub accounts."
      )
    case .repositoryRejected:
      PresentationMessage(
        title: "Repository not accepted",
        detail: "Check owner, repository access, and the default branch, then retry."
      )
    case .piBlocked:
      PresentationMessage(
        title: "Pi preflight blocked",
        detail: "Install an attested Pi and Node build, then run preflight again."
      )
    case .herdrBlocked:
      PresentationMessage(
        title: "Herdr runtime blocked",
        detail: "Restore the approved global Herdr runtime, then run its preflight again."
      )
    case .loginItemFailed:
      PresentationMessage(
        title: "Login item needs attention",
        detail: "Review Login Items in System Settings, then refresh status."
      )
    case .checkpointFailed:
      PresentationMessage(
        title: "Checkpoint failed",
        detail: "Jidoka Code remains open so in-flight work is not abandoned."
      )
    case .internalFailure:
      PresentationMessage(
        title: "Jidoka Code needs attention",
        detail: "Open redacted diagnostics and retry the last action."
      )
    }
  }
}

public enum JidokaAccessibilityID {
  public static let menuStatus = "jidoka.menu.status"
  public static let pollNow = "jidoka.menu.poll-now"
  public static let pauseResume = "jidoka.menu.pause-resume"
  public static let focusInHerdr = "jidoka.menu.focus-in-herdr"
  public static let settings = "jidoka.menu.settings"
  public static let openLogs = "jidoka.menu.open-logs"
  public static let quit = "jidoka.menu.quit"
  public static let onboardingWindow = "jidoka.onboarding.window"
  public static let externalAutomationDisclosure =
    "jidoka.onboarding.external-automation-disclosure"
  public static let piPreflight = "jidoka.onboarding.pi-preflight"
  public static let herdrPreflight = "jidoka.onboarding.herdr-preflight"
  public static let tokenField = "jidoka.onboarding.token"
  public static let tokenImport = "jidoka.onboarding.token-import"
  public static let providerDisclosure = "jidoka.onboarding.provider-disclosure"
  public static let providerDisclosureProfile =
    "jidoka.onboarding.provider-disclosure-profile"
  public static let loginItem = "jidoka.onboarding.login-item"
  public static let onboardingComplete = "jidoka.onboarding.complete"
  public static let settingsWindow = "jidoka.settings.window"
  public static let settingsHerdrPreflight = "jidoka.settings.herdr-preflight"
  public static let settingsFocusInHerdr = "jidoka.settings.focus-in-herdr"
  public static let settingsRepositoryReference = "jidoka.settings.repository-reference"
  public static let settingsRepositoryAdd = "jidoka.settings.repository-add"
  public static let settingsModelCatalogRefresh = "jidoka.settings.model-catalog-refresh"
  public static let settingsModelCatalogNotice = "jidoka.settings.model-catalog-notice"
  public static let settingsModelSelector = "jidoka.settings.model-selector"
  public static let settingsCustomModel = "jidoka.settings.custom-model"
  public static let credentialConnect = "jidoka.settings.credential-connect"
  public static let credentialReplacement = "jidoka.settings.credential-replacement"
  public static let credentialDeletion = "jidoka.settings.credential-deletion"
  public static let ambiguousRecheck = "jidoka.ambiguous.recheck"
  public static let ambiguousAuthorize = "jidoka.ambiguous.authorize"
}

extension EngineOperationalStatus {
  public var displayName: String {
    switch self {
    case .active: "Active"
    case .paused: "Paused"
    case .running: "Running"
    case .warning: "Needs attention"
    }
  }

  public var systemImage: String {
    switch self {
    case .active: "checkmark.shield"
    case .paused: "pause.circle"
    case .running: "arrow.triangle.2.circlepath"
    case .warning: "exclamationmark.triangle"
    }
  }
}

extension JobKind {
  public var displayName: String {
    switch self {
    case .prReview: "Pull request review"
    case .issueTriage: "Issue triage"
    case .issueImplementation, .complexPlan: "Issue implementation"
    }
  }
}
