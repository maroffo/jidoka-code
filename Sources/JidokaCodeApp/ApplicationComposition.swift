import AppKit
import Foundation
import JidokaCodeAppSupport
import JidokaCodeCore
import SwiftUI

@MainActor
final class ApplicationComposition {
  let appViewModel: AppViewModel
  let onboardingViewModel: OnboardingViewModel
  let settingsViewModel: SettingsViewModel
  let instanceLock: SingleInstanceLock
  let windows: ApplicationWindowController

  private var refreshTask: Task<Void, Never>?

  init(instanceLock: SingleInstanceLock) {
    self.instanceLock = instanceLock
    let client = ProductionEngineClient(
      duplicateInstanceCheckPassed: instanceLock.ownsLock
    )
    let appViewModel = AppViewModel(client: client)
    self.appViewModel = appViewModel
    onboardingViewModel = OnboardingViewModel(client: client) { [weak appViewModel] state in
      appViewModel?.apply(state)
    }
    settingsViewModel = SettingsViewModel(client: client) { [weak appViewModel] state in
      appViewModel?.apply(state)
    }
    windows = ApplicationWindowController()
    windows.configure(
      onboarding: onboardingViewModel,
      settings: settingsViewModel,
      app: appViewModel
    )
  }

  func start() async {
    await appViewModel.refresh()
    if let state = appViewModel.state {
      onboardingViewModel.apply(state)
      settingsViewModel.apply(state)
      if state.lifecycle == .onboarding {
        windows.showOnboarding()
      }
    }
    guard refreshTask == nil else { return }
    refreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled, let self else { return }
        await appViewModel.refresh()
      }
    }
  }

  func stop() {
    refreshTask?.cancel()
    refreshTask = nil
  }

  func showRelevantWindow() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await appViewModel.refresh()
      guard let lifecycle = appViewModel.state?.lifecycle else { return }
      if lifecycle == .onboarding {
        windows.showOnboarding()
      } else {
        windows.showSettings()
      }
    }
  }

  func openLogs() {
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/JidokaCode/Logs", isDirectory: true)
    do {
      try PrivateDirectoryBoundary.ensure(logs)
      NSWorkspace.shared.open(logs)
    } catch {
      appViewModel.message = PresentationMessage(
        title: "Logs unavailable",
        detail: "Jidoka Code could not open its private redacted log directory."
      )
    }
  }

  func quitDurably() {
    NSApplication.shared.terminate(nil)
  }
}

@MainActor
final class ApplicationWindowController {
  private weak var appViewModel: AppViewModel?
  private weak var onboardingViewModel: OnboardingViewModel?
  private weak var settingsViewModel: SettingsViewModel?
  private var onboardingWindow: NSWindowController?
  private var settingsWindow: NSWindowController?

  func configure(
    onboarding: OnboardingViewModel,
    settings: SettingsViewModel,
    app: AppViewModel
  ) {
    onboardingViewModel = onboarding
    settingsViewModel = settings
    appViewModel = app
  }

  func showOnboarding() {
    guard let onboardingViewModel else { return }
    if let state = appViewModel?.state {
      onboardingViewModel.apply(state)
    }
    if onboardingWindow == nil {
      let view = OnboardingView(model: onboardingViewModel) { [weak self] in
        self?.onboardingWindow?.close()
        self?.onboardingWindow = nil
      }
      onboardingWindow = makeWindow(
        title: "Welcome to Jidoka Code",
        rootView: AnyView(view)
      )
    }
    onboardingWindow?.showWindow(nil)
    onboardingWindow?.window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func showSettings() {
    guard let settingsViewModel else { return }
    if let state = appViewModel?.state {
      settingsViewModel.apply(state)
    }
    if settingsWindow == nil {
      settingsWindow = makeWindow(
        title: "Jidoka Code Settings",
        rootView: AnyView(SettingsView(model: settingsViewModel))
      )
    }
    settingsWindow?.showWindow(nil)
    settingsWindow?.window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func makeWindow(title: String, rootView: AnyView) -> NSWindowController {
    let controller = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: controller)
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.center()
    return NSWindowController(window: window)
  }
}

@MainActor
final class DurableTerminationGate {
  private var inProgress = false
  private var approved = false

  func request(
    checkpoint: @escaping @MainActor () async -> Bool,
    completion: @escaping @MainActor (Bool) -> Void
  ) -> NSApplication.TerminateReply {
    if approved { return .terminateNow }
    if inProgress { return .terminateLater }
    inProgress = true
    Task { @MainActor [weak self] in
      guard let self else {
        completion(false)
        return
      }
      let checkpointed = await checkpoint()
      inProgress = false
      approved = checkpointed
      completion(checkpointed)
    }
    return .terminateLater
  }
}

@MainActor
final class JidokaApplicationDelegate: NSObject, NSApplicationDelegate {
  var composition: ApplicationComposition?
  private var activationObserver: NSObjectProtocol?
  private let terminationGate = DurableTerminationGate()

  func applicationDidFinishLaunching(_ notification: Notification) {
    startMainQuitObserver()
    activationObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(JidokaApplicationInstance.activationNotification),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.composition?.showRelevantWindow() }
    }
    Task { @MainActor [weak self] in
      await self?.composition?.start()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let composition else { return .terminateCancel }
    return terminationGate.request(
      checkpoint: { await composition.appViewModel.prepareForQuit() != nil },
      completion: { [weak sender] checkpointed in
        sender?.reply(toApplicationShouldTerminate: checkpointed)
      }
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    composition?.stop()
    if let activationObserver {
      DistributedNotificationCenter.default().removeObserver(activationObserver)
    }
  }
}

enum JidokaApplicationInstance {
  static let activationNotification = "com.maroffo.JidokaCode.Probe.ui.activate"

  @MainActor
  static func activateExisting() {
    let identifier = Bundle.main.bundleIdentifier ?? LifecycleProbeConstants.appBundleIdentifier
    let currentPID = ProcessInfo.processInfo.processIdentifier
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
      .first(where: { $0.processIdentifier != currentPID })
    {
      running.activate(options: [.activateAllWindows])
    }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(activationNotification),
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
  }
}
