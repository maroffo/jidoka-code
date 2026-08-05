import Foundation

private struct EngineProbeReport: Codable {
  let identifier: String
  let status: String
  let workingDirectory: String
}

guard CommandLine.arguments.contains("--probe") else {
  FileHandle.standardError.write(Data("usage: JidokaCodeEngineProbe --probe\n".utf8))
  exit(EXIT_FAILURE)
}

private let report = EngineProbeReport(
  identifier: "com.maroffo.JidokaCode.EngineProbe",
  status: "ok",
  workingDirectory: FileManager.default.currentDirectoryPath
)
private let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
private let data = try encoder.encode(report)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
