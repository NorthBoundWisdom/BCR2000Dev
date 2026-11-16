// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Acquisition is explicit and outside SwiftPM. Even direct Swift invocations validate
// the locked clean materialization; this read-only verification never contacts a remote.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
for dependency in ["surface_plugins", "control_surface_kit"] {
    let dependencyCheck = Process()
    dependencyCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    dependencyCheck.arguments = [
        "python3",
        repositoryRoot.appendingPathComponent("configs/\(dependency)_dependency.py").path,
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
            fatalError(message + "\nRun python3 configs/\(dependency)_dependency.py ensure first.")
        }
    } catch { fatalError("Cannot verify locked \(dependency) dependency: \(error)") }
}

let surfacePlugins: Package.Dependency = .package(path: "build/seed/SurfacePlugins")
let controlSurfaceKit: Package.Dependency = .package(path: "build/seed/ControlSurfaceKit")

let package = Package(
    name: "BCRAgentConsole",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BCRSurfaceDomain", targets: ["BCRSurfaceDomain"]),

        .executable(
            name: "BCRAgentConsole",
            targets: ["BCRAgentConsole"]
        ),
        .executable(name: "BCRProviderService", targets: ["BCRProviderService"]),
        .executable(name: "BCRProfileTool", targets: ["BCRProfileTool"])
    ],
    dependencies: [surfacePlugins, controlSurfaceKit],
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

        .target(name: "BCRPluginHost", dependencies: [
            "BCRFoundation",
            "BCRSurfaceDomain",
            "BCRConfigurationAdapter",
            "BCRPluginRuntime",
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "AgentPlugin", package: "SurfacePlugins"),
            .product(name: "AgentRemoteBinding", package: "SurfacePlugins")
        ]),

        .target(
            name: "BCRProviderApplication",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRPluginRuntime",
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins"),
                .product(name: "RobotRemoteBinding", package: "SurfacePlugins"),
                .product(name: "ChassisRemoteBinding", package: "SurfacePlugins"),
                .product(name: "RemoteToolContracts", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins")
            ]
        ),
        .target(
            name: "BCRProviderMCPAdapter",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRProviderApplication",
                "BCRMCPAdapter",
                .product(name: "SurfaceControlContracts", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins")
            ]
        ),
        .target(name: "BCRCodexAdapter", dependencies: [
            "BCRFoundation"
        ]),
        .target(name: "BCRSurfaceDomain", dependencies: [
            "BCRFoundation", .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"),
            .product(name: "SurfaceBindingContext", package: "ControlSurfaceKit"),
            .product(name: "SurfaceConnectionState", package: "ControlSurfaceKit")
        ]),

        .target(name: "BCRExamples", dependencies: [
            "BCRFoundation", "BCRSurfaceDomain", .product(name: "ExampleParameterSets", package: "SurfacePlugins")
        ]),
        .target(name: "BCRConfigurationAdapter", dependencies: [
            "BCRFoundation",
            "BCRSurfaceDomain",
            "BCRExamples",
            .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
            .product(name: "AgentPlugin", package: "SurfacePlugins"),
            .product(name: "ParameterOutputPlugin", package: "SurfacePlugins")
        ]),
        .target(
            name: "BCRPersistenceAdapter",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRConfigurationAdapter",
                "BCRExamples",
                .product(name: "AgentPlugin", package: "SurfacePlugins")
            ]
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
                "BCRFoundation",
                "BCRCodexAdapter",
                "BCRSurfaceDomain",
                "BCRExamples",
                "BCRConfigurationAdapter",
                "BCRMCPAdapter",
                "BCRHTTPTransport",
                "BCRCoreMIDIDriver",
                "BCRPersistenceAdapter",
                "BCRPluginHost",
                "BCRPluginRuntime",
                "BCRProviderApplication",
                "BCRProviderMCPAdapter",
                .product(name: "OutputRemoteBinding", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"),
                .product(name: "AgentPlugin", package: "SurfacePlugins"),
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins")
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
            dependencies: [
                "BCRProviderMCPAdapter",
                .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"),
                .product(name: "SurfaceDeviceConformance", package: "ControlSurfaceKit"),
                "BCRFoundation",
                "BCRCodexAdapter",
                "BCRSurfaceDomain",
                "BCRExamples",
                "BCRConfigurationAdapter",
                "BCRMCPAdapter",
                "BCRHTTPTransport",
                "BCRCoreMIDIDriver",
                "BCRPersistenceAdapter",
                "BCRTestSupport",
                .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"),
                .product(name: "AgentPlugin", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                .product(name: "SimulationContracts", package: "SurfacePlugins"),
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins")
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "BCRAgentConsoleTests",
            dependencies: [
                .product(name: "SurfaceDeviceContracts", package: "ControlSurfaceKit"),
                .product(name: "SurfaceDeviceConformance", package: "ControlSurfaceKit"),
                "BCRAgentConsole",
                "BCRTestSupport",
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRConfigurationAdapter",
                "BCRPersistenceAdapter",
                "BCRCodexAdapter",
                "BCRMCPAdapter",
                "BCRProviderMCPAdapter",
                "BCRHTTPTransport",
                "BCRCoreMIDIDriver",
                "BCRExamples",
                .product(name: "ParameterOutputPlugin", package: "SurfacePlugins"),
                .product(name: "AgentPlugin", package: "SurfacePlugins"),
                .product(name: "SurfacePluginContracts", package: "SurfacePlugins"),
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins")
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "BCRProviderDomainTests",
            dependencies: [
                "BCRFoundation",
                "BCRSurfaceDomain",
                "BCRConfigurationAdapter",
                "BCRProviderApplication",
                .product(name: "RobotPlugin", package: "SurfacePlugins"),
                .product(name: "ChassisPlugin", package: "SurfacePlugins"),
                .product(name: "SimulationContracts", package: "SurfacePlugins"),
                .product(name: "RobotRemoteBinding", package: "SurfacePlugins"),
                .product(name: "ChassisRemoteBinding", package: "SurfacePlugins")
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

// Native hosts remain native. The same portable slice can be checked on a Mac without
// claiming Linux validation: BCR_PORTABLE_BUILD=1 swift test --build-path build/swiftpm-portable.
#if os(macOS)
    let portableBuild = ProcessInfo.processInfo.environment["BCR_PORTABLE_BUILD"] == "1"
#else
    let portableBuild = true
#endif
if portableBuild {
    let nativeTargets: Set<String> = ["BCRAgentConsole", "BCRProviderService", "BCRCoreMIDIDriver",
                                      "BCRHTTPTransport", "BCRAgentConsoleTests"]
    package.products.removeAll { nativeTargets.contains($0.name) }
    package.targets.removeAll { nativeTargets.contains($0.name) }
    for target in package.targets {
        target.dependencies.removeAll { dependency in
            switch dependency {
            case let .targetItem(name, _), let .byNameItem(name, _): nativeTargets.contains(name)
            default: false
            }
        }
        target.swiftSettings = (target.swiftSettings ?? []) + [.define("BCR_PORTABLE_BUILD")]
        if target.name == "BCRTestSupport" { target.exclude.append("RecordingMIDIService.swift") }
    }
}
