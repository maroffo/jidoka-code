import AppKit
import Darwin
import Foundation
import JidokaCodeCore
import SwiftUI

@main
struct JidokaCodeApp: App {
  init() {
    guard CommandLine.arguments.contains("--preflight") else {
      return
    }

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

  var body: some Scene {
    MenuBarExtra("Jidoka Code", systemImage: "checkmark.shield") {
      Text("S1 packaging probe")
      Divider()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
    }
    .menuBarExtraStyle(.menu)
  }
}
