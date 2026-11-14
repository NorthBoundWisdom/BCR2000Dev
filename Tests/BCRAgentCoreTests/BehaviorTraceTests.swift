import BCRAgentCore
import Foundation
import XCTest

@MainActor
private final class BehaviorTraceRecorder {
    final class Clock { var time: Double = 1000 }
    let clock = Clock()
    let device = OutputRecordingDevice()
    let session: SurfaceSession
    var steps: [JSONValue] = []
    var actions = 0
    var acceptedInputs = 0
    var connectionGeneration = 0

    init(configuration: SurfaceConfiguration = HardwareOutputPolicyTests.configuration(),
         policy: HardwareOutputPolicy = .write)
    {
        let clock = clock
        session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                 configuration: configuration, hardwareOutput: policy,
                                 now: { Date(timeIntervalSinceReferenceDate: clock.time) },
                                 saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.onTriggerAgent = { [weak self] _ in self?.actions += 1 }
        _ = session.observeAcceptedInput { [weak self] _, _, _, _ in self?.acceptedInputs += 1 }
    }

    func step(_ operation: String, payload: JSONValue = .object([:]), inputExpected: Bool = false,
              rejection: String? = nil, _ run: () throws -> Void) rethrows
    {
        clock.time += 1
        session.clearMonitor()
        let previous = session.engine.parameterValues
        let oldActions = actions, oldInputs = acceptedInputs
        try run()
        let events = session.events
        let inputs = events.filter { $0.direction == .input }
        let outputs = events.filter { $0.direction == .output }
        let accepted = rejection == nil && (!inputExpected || acceptedInputs > oldInputs)
        let values = session.engine.parameterValues
        let changes = Dictionary(uniqueKeysWithValues: values.filter { previous[$0.key] != $0.value }.map {
            ($0.key.rawValue, JSONValue.double($0.value))
        })
        let controls = Array(Set(session.engine.configuration.assignments.map(\.control))).sorted()
        let observations: [JSONValue] = controls.map { control in
            let state = session.engine.state(of: control)
            return .object([
                "control": try! .encoded(control),
                "last_input": state.lastInput.map { .number(Int($0)) } ?? .null,
                // lastOutput is generated feedback, not successful transport or device arrival.
                "last_generated_feedback": state.lastOutput.map { .number(Int($0)) } ?? .null
            ])
        }
        func bytes(_ message: MIDIVoiceMessage) -> JSONValue { .array(message.midi1Bytes.map { .number(Int($0)) }) }
        // Test-only declarations use this host's learned/Mock map, never a cross-device MIDI table.
        func element(_ control: BCRControlID) -> String {
            switch control.section {
            case .pushEncoder, .pushEncoderButton: "encoder.top.\(control.index)"
            case .encoder: "encoder.row\(control.row).\(control.index)"
            case .button: "button.row\(control.row).\(control.index)"
            case .userButton: "button.user.\(control.index)"
            }
        }
        let inputControl = inputs.first.flatMap { session.engine.hardwareMap.control(for: $0.message.controlID) }
        let role: JSONValue
        if let inputControl {
            let mode = session.engine.configuration.assignment(for: inputControl)?.encoderMode ?? .absolute
            role = .string(inputControl.isContinuous ? (mode == .absolute ? "position" : "rotation") : "press")
        } else { role = .null }
        let group: JSONValue
        if let inputControl, inputControl.section == .pushEncoder || inputControl.section == .pushEncoderButton {
            group = .number(inputControl.row)
        } else if session.source == .mock { group = .number(session.mock.activeGroup) }
        else { group = .null } // Hardware group buttons do not report their current group.
        let outputGroups = [
            ("sent", outputs.filter { $0.delivery == .sent }),
            ("suppressed", outputs.filter(\.ignored)),
            ("rejected", outputs.filter { $0.delivery == .disconnected || $0.delivery == .failed })
        ]
        let outputDeclarations: [JSONValue] = outputGroups.flatMap { name, events -> [JSONValue] in
            events.enumerated().map { index, event -> JSONValue in
                let control = session.engine.hardwareMap.control(for: event.message.controlID)
                return .object([
                    "source_field": .string("/output/\(name)/\(index)"),
                    "category": control == nil ? .null : .string("display"),
                    "target": control.map { .string(element($0) + ($0.isContinuous ? ".ring" : ".light")) } ?? .null,
                    "affected": control.map { .array([.string(element($0))]) } ?? .null
                ])
            }
        }
        var observationDeclarations: [JSONValue] = controls.enumerated().flatMap { index, control -> [JSONValue] in
            let state = session.engine.state(of: control)
            return [
                .object(["source_field": .string("/observation/controls/\(index)/last_input"),
                         "element": .string(element(control)),
                         "state": .string(state.lastInput == nil ? "unknown" : "observed")]),
                .object(["source_field": .string("/observation/controls/\(index)/last_generated_feedback"),
                         "element": .string(element(control)),
                         "state": state.lastOutput == nil ? .string("unknown") : .null])
            ]
        }
        observationDeclarations.append(.object([
            "source_field": .string("/observation/confirmed_device_display"), "element": .null,
            "state": .string("unknown")
        ]))
        steps.append(.object([
            "input": .object([
                "operation": .string(operation), "payload": payload,
                "element": inputControl.map { .string(element($0)) } ?? .null,
                "role": role, "context": .object(["kind": .string("group"), "value": group]),
                "messages": .array(inputs.map { bytes($0.message) }),
                "hardware_context": .object(["group": .number(session.mock.activeGroup)]),
                "time": .double(clock.time), "source": .string(session.source.rawValue)
            ]),
            "result": .object([
                "accepted": .bool(accepted),
                "reason": rejection.map(JSONValue.string) ?? (accepted ? .null : .string("unmapped_input")),
                "parameter_changes": .object(changes), "action_count": .number(actions - oldActions)
            ]),
            "output": .object([
                "declarations": .array(outputDeclarations),
                "sent": .array(outputs.filter { $0.delivery == .sent }.map { bytes($0.message) }),
                "suppressed": .array(outputs.filter(\.ignored).map {
                    .object(["message": bytes($0.message), "reason": .string("hardware_output_observe")])
                }),
                "rejected": .array(outputs.filter { $0.delivery == .disconnected || $0.delivery == .failed }.map {
                    .object(["message": bytes($0.message), "reason": .string($0.delivery!.rawValue)])
                }),
                "deferred": .array([])
            ]),
            "observation": .object([
                "declarations": .array(observationDeclarations),
                "controls": .array(observations),
                "confirmed_device_display": .null,
                "connection_generation": .number(connectionGeneration),
                "binding_revision": .string(String(session.mappingContextRevision)),
                "connected": .bool(session.source == .mock || session.connection.isConnected)
            ])
        ]))
    }
}

@MainActor
final class BehaviorTraceTests: XCTestCase {
    private func compare(_ name: String, _ recorder: BehaviorTraceRecorder) throws {
        let value: JSONValue = .object([
            "format_version": .number(1), "scenario": .string(name), "device_instance": .string("mock-fixture"),
            "steps": .array(recorder.steps)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data("\n".utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/BehaviorTraces", directoryHint: .isDirectory)
        let file = root.appending(path: name + ".json")
        if ProcessInfo.processInfo.environment["BCR_RECORD_BEHAVIOR_TRACES"] == "1" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: file)
        }
        XCTAssertEqual(try Data(contentsOf: file), data, name)
    }

    func testRelativeTwentyIncrements() throws {
        var configuration = HardwareOutputPolicyTests.configuration()
        try configuration.assign(.init(control: .encoder(row: 1, 1), target: .parameter("p1"),
                                       encoderMode: .relative1, encoderStep: 1))
        let r = BehaviorTraceRecorder(configuration: configuration)
        for _ in 0 ..< 20 {
            r.step("relative_increment", payload: .number(1), inputExpected: true) {
                r.session.turn(.encoder(row: 1, 1), by: 1)
            }
        }
        XCTAssertEqual(r.session.engine.value(of: "p1"), 30)
        XCTAssertEqual(r.acceptedInputs, 20)
        try compare("relative-twenty-increments", r)
    }

    func testTopGroupSwitchSamePhysicalEncoder() throws {
        var configuration = HardwareOutputPolicyTests.configuration()
        try configuration.assign(.init(control: .pushEncoder(group: 1, 1), target: .parameter("p1")))
        try configuration.assign(.init(control: .pushEncoder(group: 2, 1), target: .parameter("p2")))
        let r = BehaviorTraceRecorder(configuration: configuration)
        r.step("rotate_top_encoder", payload: .number(1), inputExpected: true) {
            r.session.turn(.pushEncoder(group: 1, 1), by: 1)
        }
        r.step("select_group", payload: .number(2)) { r.session.selectGroup(2) }
        r.step("rotate_top_encoder", payload: .number(1), inputExpected: true) {
            r.session.turn(.pushEncoder(group: 2, 1), by: 1)
        }
        XCTAssertEqual(r.acceptedInputs, 2)
        XCTAssertEqual(r.session.engine.value(of: "p1"), 1)
        XCTAssertEqual(r.session.engine.value(of: "p2"), 1)
        try compare("top-group-switch", r)
    }

    func testPressSwitchPageRelease() throws {
        var configuration = HardwareOutputPolicyTests.configuration()
        let button = BCRControlID.button(row: 1, 1)
        try configuration.assign(.init(control: button, target: .agentPrimaryAction(AgentSlotID(1))))
        try configuration.addPage(.init(id: "second", name: "Second", assignments: [
            .init(control: button, target: .agentPrimaryAction(AgentSlotID(2)))
        ]))
        let r = BehaviorTraceRecorder(configuration: configuration)
        r.step("press", inputExpected: true) { r.session.press(button) }
        try r.step("select_page", payload: .string("second")) { try r.session.selectPage("second") }
        r.step("release", inputExpected: true) { r.session.release(button) }
        XCTAssertEqual(r.actions, 1)
        XCTAssertEqual(r.session.engine.state(of: button).lastInput, 0)
        try compare("press-page-release", r)
    }

    func testObserveParameterChange() throws {
        let r = BehaviorTraceRecorder(policy: .observe)
        r.step("connect") { r.connectionGeneration += 1; r.device.connect(1); r.session.selectSource(.hardware) }
        r.step("software_parameter", payload: .object(["p1": .number(80)])) { r.session.setParameter("p1", to: 80) }
        r.step("hardware_position", payload: .number(80), inputExpected: true) {
            r.device.onMessages?([.controlChange(channel: 0, number: 81, value: 80)])
        }
        XCTAssertTrue(r.device.sent.isEmpty)
        try compare("observe-parameter-change", r)
    }

    func testWriteReconnect() throws {
        let r = BehaviorTraceRecorder()
        r.step("connect") { r.connectionGeneration += 1; r.device.connect(1); r.session.selectSource(.hardware) }
        r.step("disconnect") { r.device.connect(nil) }
        r.step("software_parameter", payload: .object(["p1": .number(90)])) { r.session.setParameter("p1", to: 90) }
        r.step("reconnect") { r.connectionGeneration += 1; r.device.connect(2) }
        XCTAssertEqual(r.device.sent.count, 6)
        XCTAssertEqual(r.device.sent.last?.dataValue, 30)
        try compare("write-reconnect", r)
    }

    func testUnmappedInput() throws {
        let r = BehaviorTraceRecorder()
        r.device.connect(1)
        r.connectionGeneration = 1
        r.session.selectSource(.hardware)
        r.device.sent.removeAll()
        r.step("unmapped_hardware_input", inputExpected: true, rejection: "unmapped_input") {
            r.device.onMessages?([.controlChange(channel: 15, number: 127, value: 91)])
        }
        XCTAssertEqual(r.acceptedInputs, 0)
        XCTAssertTrue(r.device.sent.isEmpty)
        try compare("unmapped-input", r)
    }
}
