import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class OutputFakeDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class OutputFakeTransport: OutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var frames: [ParameterOutputFrame] = []
    func start(host: String, port: UInt16) throws { isConnected = true; onConnection?(true, nil) }
    func ping(at now: Date) throws {}
    func send(_ frame: ParameterOutputFrame) throws { frames.append(frame) }
    func stop() { isConnected = false; frames.append(.init(enabled: false, values: [:])) }
}

@MainActor
private final class OutputTestClock {
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
}

@MainActor
final class OutputControllerTests: XCTestCase {
    func testTransportFailureAlwaysStopsOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let adapter = OutputFakeTransport()
        let controller = OutputController(
            session: session,
            store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
            adapter: adapter,
            automaticallyTicks: false
        )
        controller.start()
        XCTAssertTrue(controller.settings.enabled)
        adapter.onFailure?("injected failure")
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertFalse(adapter.isConnected)
        XCTAssertEqual(controller.status, .disconnected)
        XCTAssertEqual(controller.error, "injected failure")
        XCTAssertEqual(adapter.frames.last, .init(enabled: false, values: [:]))
    }

    func testInjectedAdapterCannotSilentlyIgnoreSelectedTransport() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let transport = OutputFakeTransport()
        let controller = OutputController(
            session: session,
            store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
            adapter: transport,
            automaticallyTicks: false
        )
        var settings = controller.settings
        settings.transport = .webSocket
        controller.apply(settings)
        controller.start()
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(transport.isConnected)
    }

    func testHardwareMockSoftwareAndMCPUseTheSameGateAndDisableStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = OutputTestClock(), transport = OutputFakeTransport()
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            now: { clock.now },
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let controller = OutputController(
            session: session,
            store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
            adapter: transport,
            automaticallyTicks: false,
            now: { clock.now }
        )
        controller.start()
        defer { controller.stop() }
        func fresh() {
            transport.onHeartbeat?(clock.now)
            transport.onSamples?(SurfaceConfiguration.robotArmDemo().parameters.filter { $0.kind == .continuous }.map {
                ParameterSample(id: $0.id, value: $0.defaultValue, receivedAt: clock.now)
            })
        }
        fresh()
        session.setParameter("arm.j1", to: 90)
        controller.tick()
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(transport.frames.contains { $0.enabled && !$0.values.isEmpty })
        session.press(.button(row: 2, 1)); session.release(.button(row: 2, 1))
        controller.tick()
        XCTAssertEqual(controller.status, .ready)
        clock.now.addTimeInterval(0.1); fresh(); controller.tick()
        XCTAssertLessThanOrEqual(controller.outputs["arm.j1"]!, 1)
        let service = AgentControlService(session: session, now: { clock.now })
        XCTAssertFalse(service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.j1"), "value": .number(180)])
        ).isError)
        clock.now.addTimeInterval(0.1); fresh(); controller.tick()
        XCTAssertLessThanOrEqual(controller.outputs["arm.j1"]!, 2)
        session.turn(.pushEncoder(group: 1, 1), by: -10)
        clock.now.addTimeInterval(0.1); fresh(); controller.tick()
        XCTAssertLessThanOrEqual(controller.outputs["arm.j1"]!, 3)
        session.press(.button(row: 2, 1)); session.release(.button(row: 2, 1))
        controller.tick()
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertEqual(transport.frames.last, .init(enabled: false, values: [:]))
        XCTAssertEqual(session.motionSafety?.status, .disabled)
    }

    func testTimeoutConfigurationChangeAndActualProjectionAreVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = OutputTestClock(), transport = OutputFakeTransport()
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            now: { clock.now },
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let controller = OutputController(
            session: session,
            store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
            adapter: transport,
            automaticallyTicks: false,
            now: { clock.now }
        )
        controller.start()
        defer { controller.stop() }
        transport.onHeartbeat?(clock.now)
        transport.onSamples?(SurfaceConfiguration.robotArmDemo().parameters.filter { $0.kind == .continuous }.map {
            .init(id: $0.id, value: $0.defaultValue, receivedAt: clock.now)
        })
        controller.tick()
        session.setParameter("arm.j1", to: 90)
        controller.setLEDSource(.actual)
        XCTAssertEqual(session.engine.value(of: "arm.j1"), 90)
        XCTAssertEqual(session.mock.value(of: .pushEncoder(group: 1, 1)), 64)
        clock.now.addTimeInterval(0.31)
        controller.tick()
        XCTAssertEqual(controller.status, .heartbeatExpired)
        controller.setLEDSource(.actual)
        XCTAssertNotNil(controller.error)
        var definition = session.engine.configuration.parameter("arm.j1")!
        definition.name = "Changed"
        try session.updateParameter(definition)
        controller.tick()
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertTrue(controller.error?.contains(L10n.language == .chinese ? "配置" : "Configuration") == true)
        XCTAssertEqual(session.engine.ledFeedbackSource, .target)
    }

    func testOutputSettingsRejectUnknownEnableAndUnsafeLimits() throws {
        let config = SurfaceConfiguration.robotArmDemo()
        var settings = OutputSettings.defaults(for: config)
        try settings.validate(configuration: config)
        settings.enableParameter = "arm.j1"
        XCTAssertThrowsError(try settings.validate(configuration: config))
        settings = .defaults(for: config)
        settings.limits[0].minimum = -999
        XCTAssertThrowsError(try settings.validate(configuration: config))
        settings = .defaults(for: config)
        settings.limits.append(settings.limits[0])
        XCTAssertThrowsError(try settings.validate(configuration: config))
    }

    func testReloadingIdenticalConfigurationStopsOutputBeforeAnotherMotionFrame() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = OutputTestClock(), transport = OutputFakeTransport()
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(), now: { clock.now },
            saveHardwareMap: { _ in }, saveConfiguration: { _ in }
        )
        let controller = OutputController(
            session: session, store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
            adapter: transport, automaticallyTicks: false, now: { clock.now }
        )
        controller.start()
        defer { controller.stop() }
        transport.onHeartbeat?(clock.now)
        transport.onSamples?(session.engine.configuration.parameters.filter { $0.kind == .continuous }.map {
            .init(id: $0.id, value: $0.defaultValue, receivedAt: clock.now)
        })
        controller.tick()
        session.setParameter("arm.enabled", to: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .ready)

        try session.replaceConfiguration(session.engine.configuration)
        // A new enable input can arrive before the next 20 ms output tick.
        session.setParameter("arm.enabled", to: 1)
        let sentBeforeTick = transport.frames.count
        controller.tick()

        XCTAssertFalse(controller.settings.enabled)
        XCTAssertTrue(controller.error?.contains(L10n.language == .chinese ? "配置" : "Configuration") == true)
        XCTAssertFalse(transport.frames.dropFirst(sentBeforeTick).contains { $0.enabled })
    }

    func testSavedEnabledOutputDoesNotAutoRestoreAndStartupHighRequiresNewEdge() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = OutputTestClock(), transport = OutputFakeTransport()
        var configuration = SurfaceConfiguration.robotArmDemo()
        var enable = configuration.parameter("arm.enabled")!
        enable.defaultValue = 1
        try configuration.updateParameter(enable)
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            configuration: configuration,
            now: { clock.now },
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        XCTAssertEqual(session.engine.value(of: "arm.enabled"), 1)
        let store = JSONFileStore<OutputSettings>(fileURL: directory.appending(path: "output.json"))
        var saved = OutputSettings.defaults(for: session.engine.configuration)
        saved.enabled = true
        try store.save(saved)
        let controller = OutputController(
            session: session,
            store: store,
            adapter: transport,
            automaticallyTicks: false,
            now: { clock.now }
        )
        controller.restore()
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertFalse(transport.isConnected)
        XCTAssertTrue(transport.frames.isEmpty)
        XCTAssertEqual(try store.load()?.enabled, false)
        controller.start()
        defer { controller.stop() }
        transport.onHeartbeat?(clock.now)
        transport.onSamples?(session.engine.configuration.parameters.filter { $0.kind == .continuous }.map {
            .init(id: $0.id, value: $0.defaultValue, receivedAt: clock.now)
        })
        for _ in 0 ..< 3 { controller.tick() }
        XCTAssertEqual(controller.status, .waitingRearm)
        XCTAssertFalse(transport.frames.contains { $0.enabled })
        session.setParameter("arm.enabled", to: 0); controller.tick()
        session.setParameter("arm.enabled", to: 1); controller.tick()
        XCTAssertEqual(controller.status, .ready)
        XCTAssertEqual(transport.frames.last?.values.count, saved.limits.count)
    }
}
