import AppKit
import Darwin
import Foundation
import JidokaCodeAppSupport
import JidokaCodeCore
import SwiftUI

@main
@MainActor
struct JidokaCodeApp: App {
  @NSApplicationDelegateAdaptor(JidokaApplicationDelegate.self)
  private var applicationDelegate

  private let composition: ApplicationComposition

  init() {
    Self.dispatchCLIIfRequested(arguments: Array(CommandLine.arguments.dropFirst()))
    do {
      let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JidokaCode", isDirectory: true)
      try PrivateDirectoryBoundary.ensure(applicationSupport)
      let instanceLock = try SingleInstanceLock(
        directoryURL: applicationSupport.appendingPathComponent("IPC", isDirectory: true)
      )
      guard instanceLock.ownsLock else {
        JidokaApplicationInstance.activateExisting()
        exit(EXIT_SUCCESS)
      }
      let composition = ApplicationComposition(instanceLock: instanceLock)
      self.composition = composition
      applicationDelegate.composition = composition
    } catch {
      FileHandle.standardError.write(
        Data("Jidoka Code startup failed: INSTANCE_GATE_FAILED\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(
        model: composition.appViewModel,
        openOnboarding: { composition.windows.showOnboarding() },
        openSettings: { composition.windows.showSettings() },
        openLogs: { composition.openLogs() },
        quit: { composition.quitDurably() }
      )
    } label: {
      Label(
        "Jidoka Code, \(composition.appViewModel.statusTitle)",
        systemImage: composition.appViewModel.statusSystemImage
      )
      .accessibilityLabel("Jidoka Code status: \(composition.appViewModel.statusTitle)")
    }
    .menuBarExtraStyle(.menu)
  }

  private static func dispatchCLIIfRequested(arguments: [String]) {
    if arguments.first == "--pi-probe" {
      do {
        PiProbeCLI.write(try PiProbeCLI.run(arguments: Array(arguments.dropFirst())))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("Pi probe failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    if arguments.first == "--local-spike" {
      do {
        LocalSpikeCLI.write(try LocalSpikeCLI.run(arguments: Array(arguments.dropFirst())))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("local spike failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    if arguments.first == "--workflow-probe" {
      do {
        WorkflowProbeCLI.write(try WorkflowProbeCLI.run(arguments: Array(arguments.dropFirst())))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("workflow probe failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    if arguments.first == "--keychain" {
      do {
        try KeychainCLI.write(KeychainCLI.run(arguments: Array(arguments.dropFirst())))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("keychain probe failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    if arguments.first == "--lifecycle" {
      do {
        try LifecycleCLI.write(LifecycleCLI.run(arguments: Array(arguments.dropFirst())))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("lifecycle probe failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    if arguments == ["--preflight"] {
      do {
        let report = try PackagedPreflight.inspect(
          bundleURL: Bundle.main.bundleURL,
          bundleIdentifier: Bundle.main.bundleIdentifier,
          workingDirectory: FileManager.default.currentDirectoryPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(EXIT_SUCCESS)
      } catch {
        FileHandle.standardError.write(Data("packaged preflight failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }
  }
}
