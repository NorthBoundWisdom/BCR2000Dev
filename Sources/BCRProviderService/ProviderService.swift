import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
import BCRPersistenceAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRProviderApplication
import BCRProviderMCPAdapter
import Darwin
import Foundation

private struct BootError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private struct Options {
    var port: UInt16 = 8787
    var source: DeviceSource = .mock
    /// nil until given; only meaningful with `--source hardware`, where it defaults to observe (D32).
    var hardwareOutputOption: HardwareOutputPolicy?
    var hardwareOutput: HardwareOutputPolicy { hardwareOutputOption ?? .observe }
    var console = true
    var robot = false
    var chassis = false
    var clock: ProviderClock = .realtime
    var dataDirectory: URL?
    var configuration: URL?
    var hardwareMap: URL?
    var exportContract: URL?
    var tokenStdin = false
    var simulationProfile = false
    var simulationConfiguration: URL?
    var usesSimulationConfiguration: Bool { simulationProfile || simulationConfiguration != nil }
    var describeSurface = false
    var surfaceInstanceID: String?
    var surfacePermissions = BCRSurfaceControlAdapter.Permissions()
    var permissions = MCPPermissions()
    var surfacePrincipalFile: URL?
    var surfaceWriteLimits: BCRSurfaceControlAdapter.WriteLimits?
    var aggregateWriteLimitSpecified = false
    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options(); var i = 0
        func value() throws -> String {
            guard i + 1 < arguments.count else { throw BootError(reason: "A command-line option value is missing") }
            i += 1; return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--port":
                guard let port = UInt16(try value()),
                      port == 0 || port >= 1024
                else { throw BootError(reason: "Invalid loopback port") }; result.port = port
            case "--source":
                guard let source = DeviceSource(rawValue: try value())
                else { throw BootError(reason: "Source must be mock or hardware") }; result.source = source
            case "--hardware-output":
                guard let policy = HardwareOutputPolicy(rawValue: try value())
                else { throw BootError(reason: "Hardware output must be observe or write") }
                result.hardwareOutputOption = policy
            case "--clock":
                guard let clock = ProviderClock(rawValue: try value())
                else { throw BootError(reason: "Clock must be realtime or manual") }; result.clock = clock
            case "--no-console": result.console = false
            case "--robot-sim": result.robot = true
            case "--chassis-sim": result.chassis = true
            case "--read-only": result.permissions.parameterWrite = false
            case "--allow-configuration": result.permissions.configurationWrite = true
            case "--allow-device-control": result.permissions.deviceControl = true
            case "--allow-robot-control": result.permissions.robotControl = true
            case "--allow-chassis-control": result.permissions.chassisControl = true
            case "--allow-simulation-control": result.permissions.simulationControl = true
            case "--token-stdin": result.tokenStdin = true
            case "--simulation-profile": result.simulationProfile = true
            case "--simulation-configuration": result.simulationConfiguration = URL(fileURLWithPath: try value())
                .standardizedFileURL
            case "--describe-surface": result.describeSurface = true
            case "--surface-instance-id":
                let id = try value()
                guard !id.isEmpty, id.utf8.count <= 128,
                      id.utf8.allSatisfy({ (33 ... 126).contains($0) })
                else { throw BootError(reason: "Invalid surface instance identity") }
                result.surfaceInstanceID = id
            case "--allow-surface-input": result.surfacePermissions.input = true
            case "--allow-surface-feedback": result.surfacePermissions.feedback = true
            case "--allow-surface-reset": result.surfacePermissions.reset = true
            case "--data-dir": result.dataDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
                .standardizedFileURL
            case "--configuration": result.configuration = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--hardware-map": result.hardwareMap = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--export-contract": result.exportContract = URL(fileURLWithPath: try value(), isDirectory: true)
                .standardizedFileURL
            case "--surface-principal-file":
                guard result.surfacePrincipalFile == nil
                else { throw BootError(reason: "Repeated principal file option") }
                result.surfacePrincipalFile = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--write-limits":
                guard result.surfaceWriteLimits == nil else { throw BootError(reason: "Repeated write limits option") }
                result.surfaceWriteLimits = try BCRSurfaceControlAdapter.parseWriteLimits(value())
            case "--write-limit":
                result.aggregateWriteLimitSpecified = true
                guard let limit = Int(try value()),
                      (1 ... 10000).contains(limit)
                else { throw BootError(reason: "Invalid write limit") }; result.permissions
                    .writesPerSecond = limit
            default: throw BootError(reason: "Unknown provider service option; use --help")
            }
            i += 1
        }
        guard !(result.aggregateWriteLimitSpecified && result.surfaceWriteLimits != nil) else {
            throw BootError(reason: "--write-limit and --write-limits are mutually exclusive")
        }
        guard (result.surfacePrincipalFile == nil && result.surfaceWriteLimits == nil) || result
            .usesSimulationConfiguration
        else {
            throw BootError(
                reason: "Surface principal and category limits require an explicit simulation profile/configuration"
            )
        }
        guard result.hardwareOutputOption == nil || (result.console && result.source == .hardware)
        else { throw BootError(reason: "--hardware-output requires --source hardware") }
        guard !result.permissions.configurationWrite || result.permissions.parameterWrite
        else { throw BootError(reason: "Read-only mode cannot grant configuration writes") }
        guard result.console || (result.source == .mock && result.configuration == nil && result.hardwareMap == nil)
        else { throw BootError(reason: "Console options require an enabled console") }
        guard !(result.simulationProfile && result.simulationConfiguration != nil) else {
            throw BootError(reason: "--simulation-profile and --simulation-configuration are mutually exclusive")
        }
        guard !result.usesSimulationConfiguration ||
            (result.console && result.source == .mock && result.configuration == nil && result
                .dataDirectory == nil && (result.simulationConfiguration == nil || result.hardwareMap == nil))
        else {
            throw BootError(
                reason: "Simulation profile/configuration requires a memory-only Mock console without configuration, hardware-map or data-dir"
            )
        }
        guard !(result.surfacePermissions.input || result.surfacePermissions.feedback || result.surfacePermissions
            .reset) ||
            (result.console && result.source == .mock)
        else { throw BootError(reason: "Surface simulation permissions require a Mock console") }
        return result
    }
}

@MainActor
private final class ShutdownSignal {
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for code in [SIGINT, SIGTERM] {
                signal(code, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
                source.setEventHandler { [weak self] in Task { @MainActor in self?.finish() } }
                sources.append(source); source.resume()
            }
        }
    }

    private func finish() {
        continuation?.resume(); continuation = nil
        for source in sources { source.cancel() }; sources.removeAll()
    }
}

@main
private struct BCRProviderService {
    static let help = """
    BCRProviderService — macOS loopback MCP/HTTP/SSE provider, contract 1.0
    --port PORT                    Default 8787; zero selects an isolated ephemeral port
    --source mock|hardware        Default mock; hardware requires an actual bidirectional MIDI route
    --hardware-output observe|write
                                  With --source hardware only. Default observe: inputs update parameters,
                                  nothing is sent to the device (no resync on connect or reconnect).
                                  write sends feedback and resyncs as before and must be given explicitly
    --no-console                  Run device simulator modules without a console
    --robot-sim --chassis-sim      Explicitly enable independent reference modules
    --clock realtime|manual       Default realtime; manual advancement is separately authorized
    --configuration PATH          Public configuration seed (legacy formats safely migrated)
    --hardware-map PATH           Explicit learned map; no guessed device preset
    --data-dir PATH               Optional owned profile persistence; default is memory only
    --allow-configuration --allow-device-control
    --allow-robot-control --allow-chassis-control --allow-simulation-control
    --read-only --write-limit N    Default write limit 60/s; control grants default OFF
    --export-contract DIR         Export Schema and tool definitions, then exit (no devices opened)
    --token-stdin                 Read a 64-byte lowercase hex token from an anonymous pipe
    --simulation-profile          Explicit ordinary-input simulation fixture; memory-only Mock
    --simulation-configuration PATH Strict simulation-only SurfaceConfiguration v7; implies memory-only Mock
    --describe-surface            Print the simulation profile's published control contract (JSON), then exit
    --surface-instance-id ID      Stable consumer-pinned simulation instance identity
    --surface-principal-file PATH Explicit private host-issued principal record; default memory only
    --write-limits input=N,feedback=N,renew=N,admin=N
                                  Surface-only independent budgets, mutually exclusive with --write-limit
    --allow-surface-input --allow-surface-feedback --allow-surface-reset
                                  Separate simulation permissions; default OFF, never hardware
    Credentials: BCR_PROVIDER_TOKEN environment, or --token-stdin. Never pass tokens in argv.
    No GUI, actual robot/chassis driver, vendor program or LAN listener is started.
    """

    @MainActor
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--help") { print(help); return }
        do {
            if ProcessInfo.processInfo.environment["BCR_PROVIDER_PACKAGED"] == "1",
               !ProviderResources.hasAdjacentBundle
            {
                throw BootError(reason: "The published provider resource bundle is missing")
            }
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let configuration = ProviderConfiguration(
                robot: options.robot,
                chassis: options.chassis,
                clock: options.clock
            )
            let simulationConfiguration: SurfaceConfiguration?
            if let path = options.simulationConfiguration {
                do { simulationConfiguration = try SimulationSurfaceConfiguration.decode(Data(contentsOf: path)) }
                catch { throw BootError(reason: "Simulation configuration: \(error.localizedDescription)") }
            } else { simulationConfiguration = nil }
            if options.describeSurface {
                // Static description of the --simulation-profile configuration; no device, port or token.
                let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                             configuration: simulationConfiguration ?? SurfaceControlMCPModule
                                                 .simulationConfiguration(),
                                             saveHardwareMap: { _ in }, saveConfiguration: { _ in })
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try FileHandle.standardOutput.write(
                    encoder.encode(BCRSurfaceControlAdapter.publishedContract(
                        surface: session, writeLimits: options.surfaceWriteLimits
                    )) + Data("\n".utf8)
                )
                return
            }
            if let directory = options.exportContract {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try ProviderContractSchema.data.write(
                    to: directory.appending(path: "provider.schema.json"),
                    options: .atomic
                )
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(ProviderMCPModule.tools(configuration: configuration)).write(
                    to: directory.appending(path: "tools.json"),
                    options: .atomic
                )
                print("Provider contract 1.0 exported; no device was opened")
                return
            }
            let token: String
            if options.tokenStdin {
                var info = stat()
                guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
                      let data = try FileHandle.standardInput.read(upToCount: 65), let value = String(
                          data: data,
                          encoding: .utf8
                      )
                else { throw BootError(reason: "Token stdin requires a dedicated pipe") }
                token = value
            } else { token = ProcessInfo.processInfo.environment["BCR_PROVIDER_TOKEN"] ?? "" }
            guard token.utf8.count == 64,
                  token.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else {
                throw BootError(reason: "Set a valid BCR_PROVIDER_TOKEN or use the dedicated stdin pipe")
            }
            // The sole bearer is valid before it is bound to a host-issued remote principal.
            // Static describe/export return earlier and never read or create the private record.
            let principals = try options.surfacePrincipalFile
                .map { try SurfaceControlPrincipals.loadOrCreate(at: $0) } ??
                SurfaceControlPrincipals()
            if let directory = options.dataDirectory {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let profileURL = options.dataDirectory?.appending(path: "surface-configuration.json")
            let mapURL = options.dataDirectory?.appending(path: "hardware-map.json")
            if let profileURL, FileManager.default.fileExists(atPath: profileURL.path), options.configuration != nil {
                throw BootError(reason: "Existing profile state cannot be replaced by a seed option")
            }
            if let mapURL, FileManager.default.fileExists(atPath: mapURL.path), options.hardwareMap != nil {
                throw BootError(reason: "Existing learned map cannot be replaced by a seed option")
            }
            func profileStore(_ url: URL) -> ProtectedJSONFile<SurfaceConfiguration> {
                ProtectedJSONFile(
                    store: JSONFileStore(fileURL: url),
                    title: "Configuration",
                    normalize: { try $0.migrated() },
                    version: { $0.version },
                    fallback: { .neutral() }
                )
            }
            var profile = SurfaceConfiguration.neutral()
            if options.simulationProfile { profile = SurfaceControlMCPModule.simulationConfiguration() }
            if let simulationConfiguration { profile = simulationConfiguration }
            if let path = options.configuration ?? profileURL {
                let read = profileStore(path).load()
                guard !read.failed
                else { throw BootError(reason: "Configuration validation failed; original file was preserved")
                }; profile = read.value
            }
            var map = HardwareMap()
            if let path = options.hardwareMap ?? mapURL {
                let read = ProtectedJSONFile.hardware(JSONFileStore(fileURL: path)).load()
                guard !read.failed
                else { throw BootError(reason: "Learned map validation failed; original file was preserved")
                }; map = read.value
            }
            var native: CoreMIDIService?
            let hardware: any SurfaceDevice
            if options.console && options.source == .hardware {
                let driver = CoreMIDIService(); try driver.start(); native = driver; hardware = driver
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while !driver.connection.isConnected && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard driver.connection.isConnected,
                      driver.connection.lastError == nil
                else { throw BootError(reason: "Hardware MIDI route is unavailable; no Mock fallback was used") }
            } else { hardware = MockSurfaceDevice() }
            let session: SurfaceSession? = options.console ? SurfaceSession(
                hardwareDevice: hardware, hardwareMap: map, configuration: profile,
                pluginBindings: AgentBindingTranslation.bindings,
                hardwareOutput: options.hardwareOutput,
                saveHardwareMap: { value in
                    if let mapURL { try ProtectedJSONFile.hardware(JSONFileStore(fileURL: mapURL)).save(value) }
                },
                saveConfiguration: { value in if let profileURL { try profileStore(profileURL).save(value) } }
            ) : nil
            session?.selectSource(options.source)
            let gateway = MCPApplicationGateway(session: session, permissions: options.permissions, includeAgent: false)
            gateway.onSelectSource = { source in
                guard let session else { throw ProviderDomainError("unsupported", "The console is disabled") }
                if source == .hardware && native == nil { throw ProviderDomainError(
                    "unsupported",
                    "Restart with --source hardware to open the native driver"
                ) }
                session.selectSource(source)
            }
            // Headless policy is explicit process configuration; closing it never grants another scope.
            gateway.onRestrictConfigurationWrite = {}
            let application = ProviderApplication(configuration: configuration)
            try ProviderMCPModule.install(on: gateway, application: application,
                                          enableSurfaceControl: options.usesSimulationConfiguration || options
                                              .surfaceInstanceID != nil ||
                                              options.surfacePermissions.input || options.surfacePermissions
                                              .feedback || options.surfacePermissions.reset,
                                          surfaceInstanceID: options.surfaceInstanceID,
                                          surfacePermissions: options.surfacePermissions, surfacePrincipals: principals,
                                          surfaceWriteLimits: options.surfaceWriteLimits)
            try ProviderMCPModule.installShared(on: gateway, application: application)
            let server = MCPHTTPServer(
                router: MCPRouter(service: gateway),
                providerID: application.providerID,
                eventSources: [
                    "devices": MCPStreamSource(
                        notification: "notifications/bcr/devicesChanged",
                        journal: application.events
                    )
                ]
            )
            let port = try await server.start(port: options.port, token: token)
            application.start()
            let ready: JSONValue = .object([
                "event": .string("provider.ready"), "contract_version": .string("1.0"),
                "provider_id": .string(application.providerID),
                "url": .string("http://127.0.0.1:\(port)/mcp"), "pid": .number(Int(getpid())),
                "console": .bool(options.console), "source": .string(options.source.rawValue),
                "hardware_output": options.source == .hardware ? .string(options.hardwareOutput.rawValue) : .null,
                "robot": .bool(options.robot), "chassis": .bool(options.chassis),
                "clock": .string(options.clock.rawValue),
                "persistence": .string(options.dataDirectory == nil ? "memory" : "owned_profile_directory")
            ])
            print(try ready.jsonText)
            fflush(stdout)
            let shutdown = ShutdownSignal(); await shutdown.wait()
            server.stop(); application.stopClock()
            print("{\"event\":\"provider.stopped\"}")
        } catch {
            let message = (error as? ProviderDomainError)?.message ?? (error as? BootError)?
                .reason ?? (error as? SurfaceControlPrincipals.RecordError)?.reason ?? "Provider startup failed; check local configuration and port ownership"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
    }
}
