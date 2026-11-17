import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
import BCRCoreMIDIDriver
import BCRHTTPTransport
import ParameterOutputPlugin
import Foundation
import Darwin
import Security

@MainActor
enum ConsoleConstructionAudit {
    static private(set) var counts: [String: Int] = [:]
    static func note(_ key: String) { counts[key] = min(counts[key, default: 0], Int.max - 1) + 1 }
}

struct GUIVirtualOptions {
    let tokenFD: Int32
    let readyFD: Int32
    let port: UInt16
    let inputCapacity: Int?

    /// Pure argument parsing: no store, model, driver, credential object or system endpoint.
    static func parse(_ arguments: [String]) throws -> GUIVirtualOptions? {
        let enabled = arguments.contains("--gui-virtual-surface")
        let selected = arguments
            .contains { $0.hasPrefix("--gui-virtual-surface") || $0 == "--surface-input-event-capacity" }
        guard enabled else { if selected { throw GUIVirtualError.invalidLaunch }; return nil }
        let conflicts: Set<String> = [
            "--mcp-token-stdin",
            "--integration-test",
            "--connection-fixture",
            "--startup-smoke",
            "--startup-smoke=headless",
            "--robot-sim",
            "--chassis-sim",
            "--hardware-profile",
            "--owned-virtual-rehearsal",
            "--source"
        ]
        guard !arguments.contains(where: conflicts.contains) else { throw GUIVirtualError.invalidLaunch }
        var seen: Set<String> = [], token: Int32?, ready: Int32?, port: UInt16 = 0, capacity: Int?
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--gui-virtual-surface") || name == "--surface-input-event-capacity"
            else { throw GUIVirtualError.invalidLaunch }
            guard seen.insert(name).inserted else { throw GUIVirtualError.invalidLaunch }
            if name == "--gui-virtual-surface" { index += 1; continue }
            index += 1
            guard index < arguments.count else { throw GUIVirtualError.invalidLaunch }
            let value = arguments[index]
            switch name {
            case "--gui-virtual-surface-token-fd": token = Int32(value)
            case "--gui-virtual-surface-ready-fd": ready = Int32(value)
            case "--gui-virtual-surface-port":
                guard let parsed = UInt16(value),
                      parsed == 0 || parsed >= 1024 else { throw GUIVirtualError.invalidLaunch }
                port = parsed
            case "--surface-input-event-capacity":
                guard let parsed = Int(value),
                      (1 ... 65536).contains(parsed) else { throw GUIVirtualError.invalidLaunch }
                capacity = parsed
            default: throw GUIVirtualError.invalidLaunch
            }
            index += 1
        }
        guard let token, let ready, token > STDERR_FILENO, ready > STDERR_FILENO,
              token != ready else { throw GUIVirtualError.invalidLaunch }
        return .init(tokenFD: token, readyFD: ready, port: port, inputCapacity: capacity)
    }
}

enum GUIVirtualError: Error { case invalidLaunch, invalidPipe, credential, unavailable, ownership, evidence }

@MainActor
enum ConsoleRuntimeMode {
    case normal
    case guiVirtual(GUIVirtualContext)
    var isVirtual: Bool { if case .guiVirtual = self { true } else { false } }
    var context: GUIVirtualContext? { if case let .guiVirtual(value) = self { value } else { nil } }
}

@MainActor
final class GUIVirtualContext {
    let options: GUIVirtualOptions
    let readyWriter: GUIVirtualReadyWriter
    let directory: URL
    let stores: ConsoleStores
    let preferences: UserDefaults
    let preferenceSuite: String
    let credentials: SurfaceClientCredentials
    let midi = PermanentMockOnlyMIDIService()
    let output = DisabledGUIOutputTransport()
    let legacyCredential = DisabledMCPCredentialStore()
    let identity = UUID().uuidString
    var onDenied: (@MainActor (String) -> Void)?
    private let directoryDevice: dev_t, directoryInode: ino_t
    private var cleanupResult: [String]?
    var nativeFactoryCalls = 0

    init(_ options: GUIVirtualOptions) throws {
        self.options = options
        try Self.validatePipe(options.tokenFD, writable: false)
        try Self.validatePipe(options.readyFD, writable: true)
        let writer = GUIVirtualReadyWriter(fd: options.readyFD)
        readyWriter = writer
        var completed = false
        var created: (URL, dev_t, ino_t)?
        var ownedPreferences: (UserDefaults, String)?
        defer {
            if !completed {
                writer.close()
                if let (preferences, suite) = ownedPreferences { preferences.removePersistentDomain(forName: suite) }
                if let (url, device, inode) = created {
                    var info = stat()
                    if lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode,
                       info.st_mode & S_IFMT == S_IFDIR { try? FileManager.default.removeItem(at: url) }
                }
            }
        }
        let token = try Self.readToken(options.tokenFD)
        let roles: JSONValue = .object([
            "owner": .string(try Self.secret()),
            "operator": .string(try Self.secret()),
            "display": .string(token)
        ])
        credentials = try SurfaceClientCredentials(data: Data((try roles.jsonText).utf8))
        directory = FileManager.default.temporaryDirectory.appending(
            path: "bcr-gui-virtual-" + UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw GUIVirtualError.ownership }
        directoryDevice = info.st_dev; directoryInode = info.st_ino
        created = (directory, info.st_dev, info.st_ino)
        stores = ConsoleStores(hardwareMap: .init(fileURL: directory.appending(path: "hardware-map.json")),
                               configuration: .init(fileURL: directory.appending(path: "configuration.json")))
        preferenceSuite = "dev.bcr.gui.virtual." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: preferenceSuite) else { throw GUIVirtualError.unavailable }
        self.preferences = preferences
        ownedPreferences = (preferences, preferenceSuite)
        midi.onDenied = { [weak self] in self?.deny($0) }
        output.onDenied = { [weak self] in self?.deny($0) }
        completed = true
    }

    func deny(_ operation: String) { onDenied?(operation) }
    static func validatePipe(_ fd: Int32, writable: Bool) throws {
        var info = stat()
        let flags = fcntl(fd, F_GETFL)
        guard fd > STDERR_FILENO, flags >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              writable ? flags & O_ACCMODE == O_WRONLY : flags & O_ACCMODE == O_RDONLY
        else { throw GUIVirtualError.invalidPipe }
    }

    private static func readToken(_ fd: Int32) throws -> String {
        defer { close(fd) }
        let limit = ProcessInfo.processInfo.systemUptime + 2
        var data = Data()
        while true {
            let remaining = limit - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw GUIVirtualError.credential }
            var entry = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard poll(&entry, 1, Int32(remaining * 1000)) > 0 else { throw GUIVirtualError.credential }
            var bytes = [UInt8](repeating: 0, count: 65 - data.count)
            let amount = read(fd, &bytes, bytes.count)
            guard amount >= 0 else { throw GUIVirtualError.credential }
            if amount == 0 { break }
            data.append(contentsOf: bytes.prefix(amount))
            guard data.count <= 64 else { throw GUIVirtualError.credential }
        }
        guard data.count == 64, data.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              let token = String(data: data, encoding: .utf8) else { throw GUIVirtualError.credential }
        return token
    }

    private static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard bytes
            .withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) ==
            errSecSuccess else { throw GUIVirtualError.credential }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func writeEvidence(_ data: Data, name: String) throws {
        var info = stat()
        guard !name.contains("/"), !name.contains(".."),
              lstat(directory.path, &info) == 0, info.st_dev == directoryDevice,
              info.st_ino == directoryInode, info.st_mode & S_IFMT == S_IFDIR
        else {
            throw GUIVirtualError.ownership
        }
        try data.write(to: directory.appending(path: name), options: .atomic)
    }

    var hasCleanedUp: Bool { cleanupResult != nil }

    func finishWithoutController() async -> [String] {
        var failures = cleanup()
        do {
            try await readyWriter.write(.object([
                "event": .string("gui_virtual.stopped"), "source": .string("simulation"),
                "physical_evidence": .bool(false), "endpoint_started": .bool(false),
                "cleanup_failed": .array(failures.map(JSONValue.string)),
                "owned_cleanup": .array(failures.map(JSONValue.string))
            ]))
        } catch { failures.append("ready_pipe_write_failed") }
        readyWriter.close()
        return failures
    }

    func cleanup() -> [String] {
        if let cleanupResult { return cleanupResult }
        cleanupResult = ["cleanup_in_progress"]
        preferences.removePersistentDomain(forName: preferenceSuite)
        let preferenceErrors = preferences
            .persistentDomain(forName: preferenceSuite) == nil ? [] : ["owned_preferences_cleanup_failed"]
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_dev == directoryDevice, info.st_ino == directoryInode,
              info.st_mode & S_IFMT == S_IFDIR
        else { cleanupResult = ["owned_directory_unconfirmed"]; return cleanupResult! }
        do { try FileManager.default.removeItem(at: directory); cleanupResult = preferenceErrors }
        catch { cleanupResult = ["owned_directory_cleanup_failed"] }
        return cleanupResult!
    }
}

@MainActor
final class DisabledMCPCredentialStore: MCPCredentialStore {
    private(set) var attempts = 0
    func loadOrCreate() async throws -> String { attempts += 1; throw GUIVirtualError.unavailable }
}

@MainActor
final class PermanentMockOnlyMIDIService: MIDIService {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var onDenied: (@MainActor (String) -> Void)?
    private(set) var attempts: [String: Int] = [:]
    private func reject(_ name: String) {
        attempts[name] = min(attempts[name, default: 0], Int.max - 1) + 1; onDenied?(name)
    }

    func start() throws { reject("midi_start"); throw GUIVirtualError.unavailable }
    func startWhenReady() async throws { try start() }
    func beginStartup() { reject("midi_begin_startup") }
    func selectEndpoints(_ selection: MIDIEndpointSelection) { reject("midi_select_endpoints") }
    func send(_ message: MIDIVoiceMessage) throws { reject("midi_send"); throw GUIVirtualError.unavailable }
    func readSnapshot(expected: Set<MIDIControlID>) async throws
        -> [MIDIVoiceMessage] { reject("midi_read_snapshot"); throw GUIVirtualError.unavailable }
    func readCurrentPreset() async throws -> Data { reject("midi_read_preset"); throw GUIVirtualError.unavailable }
    func readPresetNames() async throws -> BCRPresetNames { reject("midi_read_names"); throw GUIVirtualError
        .unavailable
    }

    func readMemoryPreset(_ number: Int) async throws -> Data { reject("midi_read_memory"); throw GUIVirtualError
        .unavailable
    }

    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        reject("midi_write_preset"); throw GUIVirtualError.unavailable
    }
}

@MainActor
final class DisabledGUIOutputTransport: OutputTransport {
    let isConnected = false
    var onSamples: (@MainActor ([ParameterObservation]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var onDenied: (@MainActor (String) -> Void)?
    func select(_ kind: OutputTransportKind) throws { onDenied?("output_select"); throw GUIVirtualError.unavailable }
    func start(host: String, port: UInt16) throws { onDenied?("output_start"); throw GUIVirtualError.unavailable }
    func ping(at now: Date) throws { onDenied?("output_ping"); throw GUIVirtualError.unavailable }
    func send(_ frame: ParameterOutputFrame) throws { onDenied?("output_send"); throw GUIVirtualError.unavailable }
    func stop() {}
}
