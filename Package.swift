// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BCRAgentConsole",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BCRAgentCore",
            targets: ["BCRAgentCore"]
        ),
        .executable(
            name: "BCRAgentConsole",
            targets: ["BCRAgentConsole"]
        ),
    ],
    targets: [
        .target(
            name: "BCRAgentCore"
        ),
        .executableTarget(
            name: "BCRAgentConsole",
            dependencies: ["BCRAgentCore"],
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
            ]
        ),
        .testTarget(
            name: "BCRAgentCoreTests",
            dependencies: ["BCRAgentCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
