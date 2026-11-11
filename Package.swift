// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BCRAgentConsole",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BCRAgentCore",
            targets: ["BCRAgentCore"]
        ),
        .executable(
            name: "BCRAgentConsole",
            targets: ["BCRAgentConsole"]
        )
    ],
    targets: [
        .target(
            name: "BCRAgentCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BCRAgentConsole",
            dependencies: ["BCRAgentCore"],
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        ),
        .testTarget(
            name: "BCRAgentCoreTests",
            dependencies: ["BCRAgentCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "BCRAgentConsoleTests",
            dependencies: ["BCRAgentConsole"],
            exclude: ["Fixtures"]
        )
    ],
    swiftLanguageModes: [.v6]
)
