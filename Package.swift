// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "JidokaCode",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "JidokaCodeCore", targets: ["JidokaCodeCore"]),
    .library(name: "JidokaCodeAppSupport", targets: ["JidokaCodeAppSupport"]),
    .executable(name: "JidokaCodeApp", targets: ["JidokaCodeApp"]),
    .executable(name: "JidokaCodeEngineProbe", targets: ["JidokaCodeEngineProbe"]),
    .executable(name: "JidokaCodeUIFixture", targets: ["JidokaCodeUIFixture"]),
    .executable(name: "JidokaCodeAskPass", targets: ["JidokaCodeAskPass"]),
    .executable(name: "JidokaCodePushGuard", targets: ["JidokaCodePushGuard"]),
    .executable(name: "JidokaCodeHerdrHost", targets: ["JidokaCodeHerdrHost"]),
    .executable(name: "JidokaCodeHerdrFixture", targets: ["JidokaCodeHerdrFixture"]),
    .executable(name: "JidokaCodeBoundedCommand", targets: ["JidokaCodeBoundedCommand"]),
    .executable(name: "JidokaCodeLocationProbeApp", targets: ["JidokaCodeLocationProbeApp"]),
    .executable(
      name: "JidokaCodeLocationProbeEngine", targets: ["JidokaCodeLocationProbeEngine"]),
  ],
  targets: [
    .target(
      name: "JidokaCodeCore",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "JidokaCodeAppSupport",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodeApp",
      dependencies: ["JidokaCodeCore", "JidokaCodeAppSupport"]
    ),
    .executableTarget(
      name: "JidokaCodeEngineProbe",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodeUIFixture",
      dependencies: ["JidokaCodeCore", "JidokaCodeAppSupport"]
    ),
    .executableTarget(
      name: "JidokaCodeAskPass",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodePushGuard",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodeHerdrHost",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodeHerdrFixture",
      dependencies: ["JidokaCodeCore"]
    ),
    .executableTarget(
      name: "JidokaCodeBoundedCommand",
      dependencies: ["JidokaCodeCore"]
    ),
    .target(name: "JidokaCodeLocationProbeSupport"),
    .executableTarget(
      name: "JidokaCodeLocationProbeApp",
      dependencies: ["JidokaCodeCore", "JidokaCodeLocationProbeSupport"]
    ),
    .executableTarget(
      name: "JidokaCodeLocationProbeEngine",
      dependencies: ["JidokaCodeCore", "JidokaCodeLocationProbeSupport"]
    ),
    .testTarget(
      name: "JidokaCodeCoreTests",
      dependencies: ["JidokaCodeCore", "JidokaCodeLocationProbeSupport"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "JidokaCodeAppSupportTests",
      dependencies: ["JidokaCodeAppSupport", "JidokaCodeCore"]
    ),
    .testTarget(
      name: "JidokaCodeAppTests",
      dependencies: ["JidokaCodeApp", "JidokaCodeCore"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
