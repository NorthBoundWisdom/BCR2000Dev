import BCRAgentCore
import BCRPluginRuntime
import BCRProviderApplication
import BCRPluginHost
import OutputRemoteBinding
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

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
private final class PrecisionOutputTransport: OutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var frames: [ParameterOutputFrame] = []
    func select(_ kind: OutputTransportKind) throws {}
    func start(host: String, port: UInt16) throws { isConnected = true; onConnection?(true, nil) }
    func ping(at now: Date) throws {}
    func send(_ frame: ParameterOutputFrame) throws { frames.append(frame) }
    func stop() { isConnected = false }
}

@MainActor
private final class OutputTestClock {
    var monotonic = 10.0
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
}

@MainActor
final class OutputControllerTests: XCTestCase {
    func testTransportFailureAlwaysStopsOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SurfaceSession(
            hardwareDevice: OutputFakeDevice(),
            configuration: .robotArmDemo(), saveHardwareMap: { _ in },
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
            configuration: .robotArmDemo(), saveHardwareMap: { _ in },
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
            configuration: .robotArmDemo(), now: { clock.now },
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
            configuration: .robotArmDemo(), now: { clock.now },
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
            hardwareDevice: OutputFakeDevice(), configuration: .robotArmDemo(), now: { clock.now },
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

    func testSharedRuntimeDisableUsesOneMonotonicDomainAndRequiresRealEnableOffOn() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wall = OutputTestClock()
        let owner = try BCRPluginRuntime(clock: { wall.monotonic }, epoch: "fixture")
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: .robotArmDemo(),
                                     now: { wall.now }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let adapter = OutputFakeTransport()
        let controller = OutputController(session: session,
                                          store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                          adapter: adapter,
                                          automaticallyTicks: false, now: { wall.now }, runtime: owner)
        controller.start()
        adapter.onHeartbeat?(wall.now)
        adapter.onSamples?(controller.settings.limits.map { .init(id: $0.id, value: 0, receivedAt: wall.now) })
        controller.tick() // real host enable parameter is off
        session.setParameter("arm.enabled", to: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .ready)
        wall.monotonic += 0.05; wall.now.addTimeInterval(0.05)
        _ = try owner.call(
            "surface_output_disable",
            arguments: .object(["instance_id": .string(OutputController.instanceID)])
        )
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertNotEqual(controller.status, .clockError)
        XCTAssertEqual(adapter.frames.last?.enabled, false)
        XCTAssertEqual(
            try owner.binding(OutputController.instanceID, as: OutputRemoteBinding.self).plugin.gate.status.rawValue,
            "disabled"
        )
        controller.tick()
        XCTAssertEqual(controller.status, .disabled, "Polling an unchanged enable parameter cannot undo remote disable")
        session.setParameter("arm.enabled", to: 0); controller.tick()
        session.setParameter("arm.enabled", to: 1); controller.tick()
        XCTAssertEqual(controller.status, .ready)
        controller.stop()
    }

    func testDelayedTrustedObservationKeepsItsOriginalAgeAcrossTheTimeBridge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wall = OutputTestClock()
        let owner = try BCRPluginRuntime(clock: { wall.monotonic })
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: .robotArmDemo(),
                                     now: { wall.now }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let adapter = OutputFakeTransport()
        let controller = OutputController(session: session,
                                          store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                          adapter: adapter,
                                          automaticallyTicks: false, now: { wall.now }, runtime: owner)
        controller.start()
        let captured = wall.now
        wall.monotonic += 1; wall.now.addTimeInterval(1)
        adapter.onHeartbeat?(captured)
        controller.tick()
        XCTAssertEqual(controller.status, .heartbeatExpired)
        XCTAssertNotEqual(controller.status, .ready)
        controller.stop()
    }

    func testGUICompositionInjectsTheSameOwnerIntoAgentSimulatorsAndOutput() throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false,
                                     providerConfiguration: .init(robot: true, chassis: true, clock: .manual),
                                     mockClock: { 0 }, automaticallyAdvancesMock: false)
        XCTAssertTrue(try XCTUnwrap(model.mockAgents).runtime === model.provider.runtime)
        XCTAssertTrue(model.output.runtime === model.provider.runtime)
        let data = try model.provider.runtime.call("surface_capabilities", arguments: .object([:]))
        let instances = try XCTUnwrap(data.objectValue?["instances"]?.arrayValue)
        XCTAssertEqual(instances.compactMap { $0.objectValue?["instance_id"]?.stringValue },
                       ["agent.mock", "chassis.reference", "output.parameters", "robot.reference"])
        model.mcp.service.permissions.agentControl = true
        let result = model.mcp.service.call(
            "surface_agent_primary",
            arguments: .object(["instance_id": .string("agent.mock"), "slot": .number(1)])
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(model.slots[0].state, .queued)
        XCTAssertEqual(model.mock.value(of: .button(row: 1, 1)), 40)
        model.performPrimaryAction(AgentSlotID(1))
        let state = try model.provider.runtime.call(
            "surface_agent_snapshot",
            arguments: .object(["instance_id": .string("agent.mock")])
        )
        XCTAssertEqual(state.objectValue?["slots"]?.arrayValue?[0].objectValue?["state"], .string("interrupted"))
        XCTAssertEqual(model.slots[0].state, .interrupted)
    }

    private func precisionController(_ transport: OutputTransportKind,
                                     actual: Double) throws -> (
        OutputController,
        PrecisionOutputTransport,
        OutputTestClock
    ) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = OutputTestClock(), adapter = PrecisionOutputTransport()
        let configuration = SurfaceConfiguration(name: "precision", parameters: [
            .init(id: "axis", name: "Axis", minimum: 0, maximum: 0.1, defaultValue: 0.1),
            .init(id: "enable", name: "Enable", minimum: 0, maximum: 1, kind: .toggle)
        ])
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: configuration,
                                     now: { clock.now }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let controller = OutputController(session: session,
                                          store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                          adapter: adapter,
                                          automaticallyTicks: false, now: { clock.now })
        var settings = controller.settings; settings.transport = transport; controller.apply(settings)
        controller.start()
        adapter.onHeartbeat?(clock.now)
        adapter.onSamples?([.init(id: "axis", value: actual, receivedAt: clock.now)])
        controller.tick()
        session.setParameter("enable", to: 1); controller.tick()
        return (controller, adapter, clock)
    }

    func testOSCRejectsUnrepresentableInitialActualWithoutChangingTheObservation() throws {
        let (controller, adapter, _) = try precisionController(.osc, actual: 0.1)
        defer { controller.stop() }
        XCTAssertEqual(controller.status, .invalidActual)
        XCTAssertTrue(controller.reason.contains("Float32"))
        XCTAssertTrue(controller.reason.contains("axis"))
        XCTAssertEqual(controller.actual["axis"], 0.1)
        XCTAssertFalse(adapter.frames.contains { $0.enabled })
    }

    func testJSONTransportKeepsDoublePointOneAndProducesSafeJSONWireValue() throws {
        let (controller, adapter, clock) = try precisionController(.webSocket, actual: 0.1)
        defer { controller.stop() }
        XCTAssertEqual(controller.status, .ready)
        let frame = try XCTUnwrap(adapter.frames.last { $0.enabled })
        XCTAssertEqual(frame.values["axis"], 0.1)
        var link = JSONParameterLink(session: "fixture")
        let ping = link.ping(at: clock.now)
        _ = try link.receive(.object([
            "type": .string("pong"),
            "session": .string("fixture"),
            "epoch": .string("peer"),
            "sequence": try XCTUnwrap(ping.objectValue?["sequence"])
        ]), at: clock.now)
        let wire = try link.command(frame)
        let encoded = try wire.jsonText
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
        let value = try XCTUnwrap(decoded.objectValue?["values"]?.objectValue?["axis"]?.finiteNumber)
        XCTAssertEqual(value, 0.1)
        XCTAssertLessThanOrEqual(value, 0.1)
    }

    func testRealFloat32ActualStillProducesAnOSCValueWithinTheSoftLimit() throws {
        let (controller, adapter, _) = try precisionController(.osc, actual: Double(Float(0.05)))
        defer { controller.stop() }
        XCTAssertEqual(controller.status, .ready)
        let frame = try XCTUnwrap(adapter.frames.last { $0.enabled })
        let value = try XCTUnwrap(frame.values["axis"])
        let bytes = try OSCCodec.encode(.message(.init("/bcr/param/axis", [.float(Float(value))])))
        guard case let .message(message) = try OSCCodec.decode(bytes),
              case let .float(wire) = message.arguments[0] else { return XCTFail("Expected OSC float") }
        XCTAssertLessThanOrEqual(Double(wire), 0.1)
        XCTAssertGreaterThanOrEqual(Double(wire), 0)
        XCTAssertEqual(Double(wire), value)
    }

    func testDisabledOutputWithNoContinuousParametersStartsWithoutAnOutputError() throws {
        for configuration in [SurfaceConfiguration(name: "empty"),
                              SurfaceConfiguration(name: "only-toggle", parameters: [
                                  .init(id: "enable", name: "Enable", minimum: 0, maximum: 1, kind: .toggle)
                              ])]
        {
            try configuration.validate()
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: configuration,
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            let adapter = OutputFakeTransport()
            let controller = OutputController(session: session,
                                              store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                              adapter: adapter,
                                              automaticallyTicks: false)
            XCTAssertFalse(controller.settings.enabled)
            XCTAssertFalse(adapter.isConnected)
            XCTAssertEqual(controller.status, .disconnected)
            XCTAssertNil(controller.error, configuration.name)
            controller.start()
            XCTAssertFalse(controller.settings.enabled)
            XCTAssertNotNil(controller.error, "Explicit start must report the invalid output configuration")
            XCTAssertFalse(adapter.isConnected)
        }
    }

    func testDisabledSavedInvalidLimitsArePreservedWithoutANewStartupError() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SurfaceConfiguration.robotArmDemo()
        let store = JSONFileStore<OutputSettings>(fileURL: directory.appending(path: "settings.json"))
        var invalid = OutputSettings.defaults(for: configuration)
        invalid.limits[0].maximum = invalid.limits[0].minimum
        try store.save(invalid)
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: configuration,
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let controller = OutputController(
            session: session,
            store: store,
            adapter: OutputFakeTransport(),
            automaticallyTicks: false
        )
        XCTAssertEqual(controller.settings, invalid)
        XCTAssertNil(controller.error)
        controller.start()
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.settings.enabled)
    }

    func testOutputSettingsDecodeFailureRemainsVisibleEvenWithNoContinuousParameters() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "settings.json")
        try Data("not-json".utf8).write(to: file)
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: .init(name: "empty"),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let controller = OutputController(session: session, store: JSONFileStore(fileURL: file),
                                          adapter: OutputFakeTransport(), automaticallyTicks: false)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.settings.enabled)
    }

    func testTenThousandReadyTelemetryTicksKeepEarlyAgentAndFaultEventsWhileNumericOutputsUpdate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wall = OutputTestClock()
        let owner = try BCRPluginRuntime(clock: { wall.monotonic }, epoch: "output-retention")
        let application = ProviderApplication(configuration: .init(robot: true), runtime: owner)
        wall.monotonic += 3; application.tick()
        let agent = try BCRMockAgentHost(clock: { wall.monotonic }, runtime: owner)
        _ = try owner.call(
            "surface_agent_primary",
            arguments: .object(["instance_id": .string(BCRMockAgentHost.instanceID), "slot": .number(1)])
        )
        let configuration = SurfaceConfiguration(name: "steady", parameters: [
            .init(id: "axis", name: "Axis", minimum: 0, maximum: 10, defaultValue: 0),
            .init(id: "enable", name: "Enable", minimum: 0, maximum: 1, kind: .toggle)
        ])
        let session = SurfaceSession(hardwareDevice: OutputFakeDevice(), configuration: configuration,
                                     now: { wall.now }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let adapter = OutputFakeTransport()
        let controller = OutputController(session: session,
                                          store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                          adapter: adapter,
                                          automaticallyTicks: false, now: { wall.now }, runtime: owner)
        defer { controller.stop(); agent.stopDriving() }
        controller.start()
        adapter.onHeartbeat?(wall.now)
        adapter.onSamples?([.init(id: "axis", value: 0, receivedAt: wall.now)])
        controller.tick(); session.setParameter("enable", to: 1); controller.tick()
        XCTAssertEqual(controller.status, .ready)
        func events() throws -> JSONValue { try owner.call("surface_events", arguments: .object([
            "epoch": .string(owner.epoch), "after": .string("0"), "limit": .number(1024)
        ])) }
        let before = try events()
        let wallStart = wall.now, policyStart = wall.monotonic
        for index in 1 ... 10_000 {
            // Date-only fixture uses exactly the facade's epoch conversion. Production
            // receipt clocks are tested separately; independent floating clocks can drift.
            wall.now = wallStart.addingTimeInterval(Double(index) * 0.02)
            wall.monotonic = policyStart + wall.now.timeIntervalSince(wallStart)
            let value = Double(index) / 1024
            session.setParameter("axis", to: value)
            adapter.onHeartbeat?(wall.now)
            adapter.onSamples?([.init(id: "axis", value: value, receivedAt: wall.now)])
            controller.tick()
            XCTAssertEqual(controller.status, .ready)
            XCTAssertFalse(controller.limited)
        }
        XCTAssertEqual(try events(), before)
        XCTAssertEqual(controller.outputs["axis"], Double(10_000) / 1024)
        XCTAssertEqual(controller.actual["axis"], Double(10_000) / 1024)
        XCTAssertEqual(adapter.frames.last?.values["axis"], Double(10_000) / 1024)
        let records = try XCTUnwrap(before.objectValue?["events"]?.arrayValue)
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["code"] == .string("surface_agent_primary") })
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["code"] == .string("host.safety.robot.fault") })
    }
}
