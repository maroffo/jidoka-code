// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JidokaCode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "JidokaCodeCore", targets: ["JidokaCodeCore"]),
        .executable(name: "JidokaCodeApp", targets: ["JidokaCodeApp"]),
        .executable(name: "JidokaCodeEngineProbe", targets: ["JidokaCodeEngineProbe"]),
        .executable(name: "JidokaCodeAskPass", targets: ["JidokaCodeAskPass"]),
        .executable(name: "JidokaCodePushGuard", targets: ["JidokaCodePushGuard"]),
    ],
    targets: [
        .target(
            name: "JidokaCodeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "JidokaCodeApp",
            dependencies: ["JidokaCodeCore"]
        ),
        .executableTarget(
            name: "JidokaCodeEngineProbe",
            dependencies: ["JidokaCodeCore"]
        ),
        .executableTarget(
            name: "JidokaCodeAskPass",
            dependencies: ["JidokaCodeCore"]
        ),
        .executableTarget(
            name: "JidokaCodePushGuard",
            dependencies: ["JidokaCodeCore"]
        ),
        .testTarget(
            name: "JidokaCodeCoreTests",
            dependencies: ["JidokaCodeCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
