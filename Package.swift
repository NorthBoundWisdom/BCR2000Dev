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
        .library(name: "BCRSurfaceDomain", targets: ["BCRSurfaceDomain"]),
        .library(name: "BCRAgentDomain", targets: ["BCRAgentDomain"]),
        .library(name: "BCRRobotDomain", targets: ["BCRRobotDomain"]),
        .library(name: "BCRChassisDomain", targets: ["BCRChassisDomain"]),
        .executable(
            name: "BCRAgentConsole",
            targets: ["BCRAgentConsole"]
        ),
        .executable(name: "BCRProviderService", targets: ["BCRProviderService"]),
        .executable(name: "BCRProfileTool", targets: ["BCRProfileTool"])
    ],
    targets: [
        .target(name: "BCRFoundation", resources: [.process("Resources")]),
        .target(name: "BCRAgentDomain", dependencies: ["BCRFoundation"]),
        .target(name: "BCRSimulationKernel", dependencies: ["BCRFoundation"]),
        .target(name: "BCRRobotDomain", dependencies: ["BCRFoundation", "BCRSimulationKernel"]),
        .target(name: "BCRChassisDomain", dependencies: ["BCRFoundation", "BCRSimulationKernel"]),
        .target(
            name: "BCRProviderApplication",
            dependencies: ["BCRFoundation", "BCRSurfaceDomain", "BCRRobotDomain", "BCRChassisDomain"]
        ),
        .target(
            name: "BCRProviderMCPAdapter",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRRobotDomain",
                "BCRChassisDomain",
                "BCRProviderApplication",
                "BCRMCPAdapter"
            ]
        ),
        .target(name: "BCRCodexAdapter", dependencies: ["BCRFoundation", "BCRAgentDomain"]),
        .target(name: "BCRSurfaceDomain", dependencies: ["BCRFoundation"]),
        .target(name: "BCROutputDomain", dependencies: ["BCRFoundation"]),
        .target(name: "BCRExamples", dependencies: ["BCRFoundation", "BCRSurfaceDomain"]),
        .target(name: "BCRConfigurationAdapter", dependencies: ["BCRFoundation", "BCRSurfaceDomain", "BCRExamples"]),
        .target(
            name: "BCRPersistenceAdapter",
            dependencies: ["BCRFoundation", "BCRSurfaceDomain", "BCRConfigurationAdapter", "BCRExamples"]
        ),
        .target(name: "BCRMCPAdapter", dependencies: ["BCRFoundation", "BCRSurfaceDomain"]),
        .target(name: "BCRHTTPTransport", dependencies: ["BCRFoundation", "BCRSurfaceDomain", "BCRMCPAdapter"]),
        .target(
            name: "BCRCoreMIDIDriver",
            dependencies: ["BCRFoundation", "BCRSurfaceDomain"],
            linkerSettings: [.linkedFramework("CoreMIDI")]
        ),
        .target(
            name: "BCRAgentCore",
            dependencies: [
                "BCRFoundation",
                "BCRAgentDomain",
                "BCRCodexAdapter",
                "BCRSurfaceDomain",
                "BCROutputDomain",
                "BCRExamples",
                "BCRConfigurationAdapter",
                "BCRMCPAdapter",
                "BCRHTTPTransport",
                "BCRCoreMIDIDriver",
                "BCRPersistenceAdapter"
            ]
        ),
        .executableTarget(
            name: "BCRProviderService",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRConfigurationAdapter",
                "BCRMCPAdapter",
                "BCRHTTPTransport",
                "BCRCoreMIDIDriver",
                "BCRProviderApplication",
                "BCRProviderMCPAdapter",
                "BCRPersistenceAdapter"
            ]
        ),
        .executableTarget(name: "BCRProfileTool", dependencies: ["BCRConfigurationAdapter"]),
        .executableTarget(
            name: "BCRAgentConsole",
            dependencies: [
                "BCRAgentCore",
                "BCRFoundation",
                "BCRAgentDomain",
                "BCRCodexAdapter",
                "BCRProviderApplication",
                "BCRProviderMCPAdapter"
            ],
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
        ),
        .testTarget(
            name: "BCRProviderDomainTests",
            dependencies: [
                "BCRFoundation",
                "BCRSimulationKernel",
                "BCRRobotDomain",
                "BCRChassisDomain",
                "BCRSurfaceDomain",
                "BCRConfigurationAdapter"
            ]
        ),
        .testTarget(
            name: "BCRProviderAdapterTests",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRProviderApplication",
                "BCRMCPAdapter",
                "BCRProviderMCPAdapter",
                "BCRHTTPTransport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
