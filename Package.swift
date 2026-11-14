// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Acquisition is explicit and outside SwiftPM. Even direct Swift invocations validate
// the locked clean materialization; this read-only verification never contacts a remote.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dependencyCheck = Process()
dependencyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
dependencyCheck.arguments = [
    "python3",
    repositoryRoot.appendingPathComponent("configs/surface_plugins_dependency.py").path,
    "verify"
]
dependencyCheck.currentDirectoryURL = repositoryRoot
let dependencyOutput = Pipe()
dependencyCheck.standardOutput = dependencyOutput
dependencyCheck.standardError = dependencyOutput
do {
    try dependencyCheck.run()
    dependencyCheck.waitUntilExit()
    if dependencyCheck.terminationStatus != 0 {
        let message = String(decoding: dependencyOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        fatalError(message + "\nRun python3 configs/surface_plugins_dependency.py ensure first.")
    }
} catch { fatalError("Cannot verify locked SurfacePlugins dependency: \(error)") }
let surfacePlugins: Package.Dependency = .package(path: "build/seed/SurfacePlugins")

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
    dependencies: [surfacePlugins],
    targets: [
        .target(name: "BCRTestSupport", dependencies: ["BCRSurfaceDomain", "BCRCoreMIDIDriver"],
                path: "Tests/Support/BCRTestSupport"),
        .target(name: "BCRPluginRuntime", dependencies: [
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "RemoteToolContracts", package: "SurfacePlugins")
        ]),
        .target(name: "BCRFoundation", dependencies: [
            .product(name: "SimulationContracts", package: "SurfacePlugins"),
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
        ], resources: [.process("Resources")]),
        .target(name: "BCRAgentDomain", dependencies: [
            "BCRFoundation", .product(name: "AgentPlugin", package: "SurfacePlugins")
        ]),
        .target(name: "BCRPluginHost", dependencies: [
            "BCRFoundation", "BCRAgentDomain", "BCRSurfaceDomain", "BCRConfigurationAdapter", "BCRPluginRuntime",
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "AgentPlugin", package: "SurfacePlugins"),
            .product(name: "AgentRemoteBinding", package: "SurfacePlugins")
        ]),
        .target(name: "BCRSimulationKernel", dependencies: [
            "BCRFoundation", .product(name: "SimulationContracts", package: "SurfacePlugins")
        ]),
        .target(name: "BCRRobotDomain", dependencies: [
            "BCRFoundation", "BCRSimulationKernel", .product(name: "RobotPlugin", package: "SurfacePlugins")
        ]),
        .target(name: "BCRChassisDomain", dependencies: [
            "BCRFoundation", "BCRSimulationKernel", .product(name: "ChassisPlugin", package: "SurfacePlugins")
        ]),
        .target(
            name: "BCRProviderApplication",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRRobotDomain",
                "BCRChassisDomain",
                "BCRPluginRuntime",
                .product(name: "RobotRemoteBinding", package: "SurfacePlugins"),
                .product(name: "ChassisRemoteBinding", package: "SurfacePlugins")
            ]
                + [.product(name: "RemoteToolContracts", package: "SurfacePlugins"),
                   .product(name: "SurfacePluginContracts", package: "SurfacePlugins")]
        ),
        .target(
            name: "BCRProviderMCPAdapter",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRRobotDomain",
                "BCRChassisDomain",
                "BCRProviderApplication",
                "BCRMCPAdapter",
                .product(name: "SurfaceControlContracts", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
            ]
        ),
        .target(name: "BCRCodexAdapter", dependencies: ["BCRFoundation", "BCRAgentDomain"]),
        .target(name: "BCRSurfaceDomain", dependencies: [
            "BCRFoundation", .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
        ]),
        .target(name: "BCROutputDomain", dependencies: [
            "BCRFoundation", .product(name: "ParameterOutputPlugin", package: "SurfacePlugins")
        ]),
        .target(name: "BCRExamples", dependencies: [
            "BCRFoundation", "BCRSurfaceDomain", .product(name: "ExampleParameterSets", package: "SurfacePlugins")
        ]),
        .target(name: "BCRConfigurationAdapter", dependencies: [
            "BCRFoundation", "BCRSurfaceDomain", "BCRExamples", "BCRAgentDomain",
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
        ]),
        .target(
            name: "BCRPersistenceAdapter",
            dependencies: ["BCRFoundation", "BCRSurfaceDomain", "BCRConfigurationAdapter", "BCRExamples"]
        ),
        .target(name: "BCRMCPAdapter", dependencies: [
            "BCRFoundation", "BCRSurfaceDomain", "BCRPluginRuntime",
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "RemoteToolContracts", package: "SurfacePlugins")
        ]),
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
                "BCRPluginHost",
                "BCRPluginRuntime",
                .product(name: "OutputRemoteBinding", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                "BCRProviderApplication",
                "BCRProviderMCPAdapter"
            ],
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        ),
        .testTarget(
            name: "BCRPluginHostTests",
            dependencies: [
                "BCRPluginHost",
                "BCRPluginRuntime",
                .product(name: "AgentRemoteBinding", package: "SurfacePlugins"),
                .product(name: "RemoteToolContracts", package: "SurfacePlugins"),
                "BCRConfigurationAdapter",
                .product(name: "AgentPlugin", package: "SurfacePlugins")
            ]
        ),
        .testTarget(
            name: "BCRAgentCoreTests",
            dependencies: ["BCRAgentCore", "BCRTestSupport"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "BCRAgentConsoleTests",
            dependencies: ["BCRAgentConsole", "BCRTestSupport"],
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
                "BCRPluginRuntime",
                "BCRTestSupport",
                .product(name: "AgentPlugin", package: "SurfacePlugins"),
                .product(name: "AgentRemoteBinding", package: "SurfacePlugins"),
                .product(name: "RemoteToolContracts", package: "SurfacePlugins"),
                "BCRFoundation",
                .product(name: "OutputRemoteBinding", package: "SurfacePlugins"),
                .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"),
                "BCRSurfaceDomain",
                "BCRProviderApplication",
                "BCRMCPAdapter",
                .product(name: "SurfaceControlContracts", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                "BCRProviderMCPAdapter",
                "BCRHTTPTransport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
