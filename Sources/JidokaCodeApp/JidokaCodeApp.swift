import AppKit
import Darwin
import Foundation
import JidokaCodeCore
import SwiftUI

@main
struct JidokaCodeApp: App {
  init() {
    let arguments = Array(CommandLine.arguments.dropFirst())
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
        let message = "lifecycle probe failed: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
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
        let message = "packaged preflight failed: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
      }
    }

    startMainQuitObserver()
  }

  var body: some Scene {
    MenuBarExtra("Jidoka Code", systemImage: "checkmark.shield") {
      Text("W1 lifecycle probe")
      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .menuBarExtraStyle(.menu)
  }
}
