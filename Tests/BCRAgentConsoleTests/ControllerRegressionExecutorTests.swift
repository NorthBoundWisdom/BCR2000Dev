import BCRConfigurationAdapter
import BCRCoreMIDIDriver
import BCRFoundation
import BCRHTTPTransport
import BCRMCPAdapter
import BCRPersistenceAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import BCRTestSupport
import CryptoKit
import Foundation
import XCTest
@testable import BCRAgentConsole

private let regressionFeatures: Set<String> = [
    "absolute_input",
    "relative_input",
    "hardware_context",
    "display_style",
    "preset_transaction",
    "hardware_restore"
]
private let regressionFixtureSHA = "546fbc2a6f1d20f9e116a91558f4dd67891bfaba797b9778e85d975fe4cd3384"
private let regressionNull = NSNull()
private enum RegressionError: Error { case shape(String), operation(String) }
private func regressionObject(_ value: Any?) throws -> [String: Any] {
    guard let result = value as? [String: Any] else { throw RegressionError.shape("object") }
    return result
}

private func regressionRows(_ value: Any?) throws -> [[String: Any]] {
    guard let result = value as? [[String: Any]] else { throw RegressionError.shape("rows") }
    return result
}

private func regressionString(_ value: [String: Any], _ key: String) throws -> String {
    guard let result = value[key] as? String else { throw RegressionError.shape(key) }
    return result
}

private func regressionNumber(_ value: [String: Any], _ key: String) throws -> Double {
    guard let result = value[key] as? NSNumber,
          CFGetTypeID(result) != CFBooleanGetTypeID() else { throw RegressionError.shape(key) }
    return result.doubleValue
}

private func regressionValue<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? regressionNull }
private func regressionEqual(_ a: Any, _ b: Any) -> Bool {
    if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
    if let a = a as? NSNumber, let b = b as? NSNumber {
        return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) && a
            .doubleValue == b.doubleValue
    }
    return (a as? String) != nil && (a as? String) == (b as? String)
}

private func regressionExpect(_ row: [String: Any], instance: String,
                              before: [String: [String: Any]], after: [String: [String: Any]]) -> Bool
{
    let id = row["instance_id"] as? String ?? instance
    guard let metric = row["metric"] as? String, let a = after[id]?[metric],
          let relation = row["relation"] as? String else { return false }
    let b = before[id]?[metric]
    switch relation {
    case "equals": return row["value"].map { regressionEqual(a, $0) } ?? false
    case "not_equals": return row["value"].map { !regressionEqual(a, $0) } ?? false
    case "unchanged": return b.map { regressionEqual(a, $0) } ?? false
    case "increased": return (a as? NSNumber)
        .flatMap { aa in (b as? NSNumber).map { aa.doubleValue > $0.doubleValue } } ?? false
    case "at_least": return (a as? NSNumber)
        .flatMap { aa in (row["value"] as? NSNumber).map { aa.doubleValue >= $0.doubleValue } } ?? false
    case "increased_by":
        guard let a = a as? NSNumber, let b = b as? NSNumber,
              let increment = row["value"] as? NSNumber else { return false }
        return a.doubleValue - b.doubleValue == increment.doubleValue
    default: return false
    }
}

private func regressionProcess(_ arguments: [String], input: Data = Data()) async throws -> (Int32, Data, Data) {
    try await Task.detached {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, errors)
    }.value
}

@MainActor
private final class RegressionClock { var monotonic = 10.0; var wall = 1000.0 }

@MainActor
private final class RegressionMIDI: MIDIService {
    var connection: MIDIConnectionSnapshot = {
        var value = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
        value.connectedSourceID = 1; value.connectedDestinationID = 1
        return value
    }()

    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsStartupConfiguration: Bool { true }
    var supportsSnapshotReadback: Bool { true }
    var starts = 0
    var reject = false
    var physical = MockBCR2000()
    var records: [(MIDIVoiceMessage, Bool)] = []
    var preset: Data
    var batches: [[[UInt8]]] = []
    var holdsDump = false
    var dumps: [CheckedContinuation<Data, any Error>] = []
    init() { preset = try! BCLFixtures.encoderPreset(name: "Regression").dump }
    func start() throws { starts += 1 }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {
        records.append((message, !reject))
        guard !reject else { throw MIDIStartupError.noReply }
        _ = physical.receive(message)
    }

    func readPresetNames() async throws -> BCRPresetNames {
        .init(temporary: "Regression", memory: (1 ... 32).map { $0 == 8 ? "Regression" : "P\($0)" })
    }

    func readCurrentPreset() async throws -> Data {
        if holdsDump { return try await withCheckedThrowingContinuation { dumps.append($0) } }
        return preset
    }

    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        batches.append(frames)
        for index in frames.indices { try Task.checkCancellation(); progress(index + 1) }
        preset = Data(frames.joined())
    }

    func connection(_ id: Int32?) {
        if let id {
            connection = .init(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
            connection.connectedSourceID = id; connection.connectedDestinationID = id
        } else { connection = .init() }
        onConnection?(connection)
    }
}

@MainActor
private final class RegressionCredential: MCPCredentialStore {
    func loadOrCreate() async throws -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
    }
}

/// An adapter/observer of existing host APIs, not a second controller state machine.
@MainActor
private final class RegressionInstance {
    let id: String
    let source: String
    let scenario: String
    let setup: [String: Any]
    let directory: URL
    let clock = RegressionClock()
    let device = RegressionMIDI()
    var session: SurfaceSession
    var gateway: MCPApplicationGateway
    var context: ConsoleDeviceContext
    let gate = ConsolePresetOperationGate()
    var store: ConsoleRecoveryStore
    var preset: ConsolePresetWork
    var recovery: ConsoleRecoveryWork
    var intents: ConsoleSurfaceIntents
    var effects: [[String: Any]] = []
    var raw: [[String: Any]] = []
    var actions: [Int] = []
    var releases = 0
    var relativeSum = 0.0
    var observedGroup: Int?
    var routeGeneration = 1
    var oldExpected: JSONValue?
    var oldGeneration: String?
    var oldAuthorization: Bool?
    var hardwareContract: BCRHardwareSurfaceControlAdapter?
    var gap: Bool?
    var authorityMissing = false
    var endpointRows: [[String: Any]] = []
    var originalMap: HardwareMap
    var guiPermissionResult: Bool?
    var remotePermissionResult: Bool?
    var manualAuthority: Bool?
    var resultCertain: Bool?
    var proxyRequests: Int?
    var transactionHandles: [String: Task<Void, Never>] = [:]
    var originalRestore: PresetRestorePoint?
    var monotonicResults: [Bool] = []
    var pageProjectionValid: Bool?

    init(id: String, source: String, scenario: String, setup: [String: Any], directory: URL) throws {
        self.id = id; self.source = source; self.scenario = scenario; self.setup = setup; self.directory = directory
        let clock = clock
        let configuration = try Self.configuration(setup)
        let map = HardwareMap.mockPreset()
        originalMap = map
        let mapStore = JSONFileStore<HardwareMap>(fileURL: directory.appending(path: "map.json"))
        try mapStore.save(map)
        let hardwareFile = ProtectedJSONFile.hardware(mapStore)
        let configStore = JSONFileStore<SurfaceConfiguration>(fileURL: directory.appending(path: "config.json"))
        try configStore.save(configuration)
        let configurationFile = ProtectedJSONFile.configuration(configStore, preset: .starter)
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: configuration,
                                     pluginBindings: AgentBindingTranslation.bindings,
                                     requiresHardwareConfirmation: true, hardwareLifecycleFeedback: false,
                                     now: { Date(timeIntervalSinceReferenceDate: clock.wall) },
                                     saveHardwareMap: { try hardwareFile.save($0) },
                                     saveConfiguration: { try configurationFile.save($0) })
        self.session = session
        gateway = MCPApplicationGateway(session: session, permissions: .init(agentControl: true),
                                        now: { Date(timeIntervalSinceReferenceDate: clock.wall) },
                                        displayMonotonic: { clock.monotonic })
        let ui = ConsolePresentationState(timing: .immediate,
                                          workspacePanelStore: JSONFileStore(fileURL: directory
                                              .appending(path: "ui.json")))
        context = ConsoleDeviceContext(session: session, midi: device, presentation: ui,
                                       timing: .immediate, canConfigureMIDI: true, hardwareFile: hardwareFile)
        store = ConsoleRecoveryStore(directory: directory)
        preset = ConsolePresetWork(context: context, gate: gate, recoveryStore: store, directory: directory)
        recovery = ConsoleRecoveryWork(context: context, preset: preset, gate: gate, store: store)
        preset.recovery = recovery
        intents = ConsoleSurfaceIntents(context: context, configurationFile: configurationFile,
                                        migratedHardwareMap: nil, migratedConfiguration: false)
        if source == "hardware" { session.selectSource(.hardware) }
        if ["T12", "T23"].contains(scenario) { try SurfaceControlMCPModule.installHardware(
            on: gateway,
            instanceID: id,
            permissions: .init(input: true, feedback: true)
        ) }
        if scenario == "T25" {
            hardwareContract = try BCRHardwareSurfaceControlAdapter(
                surface: session,
                instanceID: id,
                permissions: .init(),
                eventCapacity: setup["journal_capacity"] as? Int ?? 16,
                monotonic: { clock.monotonic }
            )
        }
        session.onTriggerAction = { [weak self] action in
            if let index = action.index { self?.actions.append(index) }
        }
        _ = session.observeAcceptedInput { [weak self] control, message, _, _ in
            guard let self else { return }
            if control.section == .pushEncoder { self.observedGroup = control.row }
            if !control.isContinuous, !message.isPositiveActivation { self.releases += 1 }
        }
        session.onChange = { [weak preset, weak recovery] in
            preset?.validateConnectionWork(); recovery?.validateConnectionWork()
        }
        session.clearMonitor()
        device.records.removeAll()
        if scenario == "T26" { monotonicResults.append(consumeDisplayBudget()) }
    }

    static func configuration(_ setup: [String: Any]) throws -> SurfaceConfiguration {
        let definitions = try regressionRows(setup["parameters"]).map {
            try ParameterDefinition(id: ParameterID(regressionString($0, "id")), name: regressionString($0, "id"),
                                    minimum: regressionNumber($0, "minimum"), maximum: regressionNumber($0, "maximum"),
                                    defaultValue: regressionNumber($0, "initial"))
        }
        let relative = try regressionRows(setup["controls"])
            .first { $0["id"] as? String == "axis" }?["kind"] as? String == "relative"
        func assignments(_ page: [String: Any]) throws -> [ControlAssignment] {
            var rows: [ControlAssignment] = []
            for binding in try regressionRows(page["bindings"]) {
                let element = try regressionString(binding, "element_id"), targetID = try regressionString(
                    binding,
                    "target_id"
                )
                let controls: [BCRControlID]
                switch element { case "axis": controls = [
                        .pushEncoder(group: 1, 1),
                        .pushEncoder(group: 2, 1)
                    ]; case "button": controls = [.button(row: 1, 1)]; default: continue }
                let target: ControlTarget = binding["kind"] as? String == "parameter" ?
                    .parameter(ParameterID(targetID)) : .agentPrimaryAction(AgentSlotID(targetID == "fire2" ? 2 : 1))
                rows += controls.map { .init(
                    control: $0,
                    target: target,
                    encoderMode: relative && element == "axis" ? .relative1 : .absolute,
                    encoderStep: 1
                ) }
            }
            return rows
        }
        let pages = try regressionRows(setup["pages"])
        return try SurfaceConfiguration(
            name: "Controller regression",
            parameters: definitions,
            assignments: assignments(pages[0]),
            pages: pages.map { try .init(
                id: regressionString($0, "id"),
                name: regressionString($0, "id"),
                assignments: assignments($0)
            ) },
            activePageID: regressionString(pages[0], "id")
        )
    }

    func control(_ element: String, context: String = "context1") -> BCRControlID {
        switch element { case "axis": .pushEncoder(
                group: context == "context2" ? 2 : 1,
                1
            ); case "button": .button(row: 1, 1); case "meter": .encoder(row: 1, 8); default: .userButton(4) }
    }

    func endpoint(_ control: BCRControlID?) -> String {
        guard let control else { return "unmapped.output" }
        if control.section == .pushEncoder { return "axis.display" }
        if control == .button(row: 1, 1) { return "button.display" }
        return "meter.display"
    }

    func receive(_ element: String, value: Any, context name: String = "context1") throws {
        let control = control(element, context: name)
        if control.section == .pushEncoder { device.physical.activeGroup = control.row }
        guard let midi = session.engine.hardwareMap.midi(for: control)
        else { throw RegressionError.shape("input address") }
        let raw: UInt8 = (value as? NSNumber)
            .map { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0.boolValue ? 127 : 0) : UInt8($0.intValue) } ?? 0
        let message: MIDIVoiceMessage
        if control.isContinuous, session.engine.configuration.assignment(for: control)?.encoderMode != .relative1 {
            message = try XCTUnwrap(device.physical.move(control, to: UInt16(raw)))
        } else if !control.isContinuous {
            message = try XCTUnwrap(raw > 0 ? device.physical.press(control) : device.physical.release(control))
        } else { message = .controlChange(channel: midi.channel, number: UInt8(midi.number), value: raw) }
        let before = session.engine.value(of: "p1") ?? 0
        if source == "hardware" { device.onMessages?([message]) }
        else { session.simulateAbsoluteInput(control, rawValue: UInt16(raw)) }
        let after = session.engine.value(of: "p1") ?? 0
        if session.engine.configuration.assignment(for: control)?
            .encoderMode == .relative1 { relativeSum += after - before }
        rawAppend("input", ["message": message.midi1Bytes, "control": BCRSurfaceControlAdapter.controlID(control)])
    }

    func collectOutputs() {
        for event in session.events
            where event.direction == .output && (event.delivery == .sent || event.delivery == .failed)
        {
            // A physical instance's automatic switch to its internal Mock is not physical transport.
            guard (event.source == .hardware) == (source == "hardware") else {
                rawAppend("other-source-output", ["source": event.source.rawValue, "bytes": event.message.midi1Bytes])
                continue
            }
            effects.append([
                "instance_id": id,
                "kinds": ["display", "value_projection"],
                "endpoint": endpoint(event.control),
                "value": Int(event.message.dataValue),
                "accepted": event.delivery == .sent
            ])
            rawAppend("native-output", ["bytes": event.message.midi1Bytes, "delivery": event.delivery!.rawValue,
                                        "origin": event.origin.rawValue])
        }
        session.clearMonitor()
    }

    func rawAppend(_ kind: String, _ value: [String: Any]) { raw.append(value.merging(["kind": kind]) { _, b in b }) }
    func consumeDisplayBudget() -> Bool {
        do {
            try gateway
                .withAuthenticatedSurfaceWriterID("h10.display", displayWriteLimit: 1) { try gateway.consumeWrites(1) }
            return true
        } catch { return false }
    }

    func observations() -> [String: Any] {
        let accepted = effects.filter { $0["accepted"] as? Bool == true }
        let state = session.engine.state(of: .pushEncoder(group: 1, 1))
        let page = session.engine.configuration.activePageID ?? "page1"
        let sent = accepted.last { $0["endpoint"] as? String == "axis.display" }?["value"]
        var plannedEngine = session.engine
        let displayPlan = plannedEngine.fullFeedback(at: Date(timeIntervalSinceReferenceDate: clock.wall))
        let planMessages = displayPlan.compactMap { effect -> MIDIVoiceMessage? in
            if case let .send(message) = effect { return message }; return nil
        }
        let planValid = !planMessages.isEmpty && planMessages
            .allSatisfy { session.engine.hardwareMap.control(for: $0.controlID) != nil }
        let eligibility = Set(session.learnedHardwareMap.entries.filter { $0.visualizationOnly != true }.map(\.control))
        let initialEligibility = Set(originalMap.entries.filter { $0.visualizationOnly != true }.map(\.control))
        let provenanceAvailable = endpointRows.count == 2 && endpointRows
            .allSatisfy { $0["native_provenance"] as? String != nil }
        let nativeState: [String: Any] = [
            "parameter_p1": regressionValue(session.engine.value(of: "p1")),
            "observed_value": regressionValue(state.lastInput),
            "sent_value": sent ?? regressionNull,
            "display_output_count": effects.count, "value_projection_output_count": accepted.count,
            "device_output_count": effects.count, "accepted_transport_count": accepted.count,
            "layer_select_output_count": effects.filter { ($0["kinds"] as? [String])?.contains("context") == true }
                .count,
            "motor_output_count": effects.filter { ($0["kinds"] as? [String])?.contains("motor") == true }.count,
            "action_fire1_count": actions.filter { $0 == 1 }.count,
            "action_fire2_count": actions.filter { $0 == 2 }.count,
            "release_count": releases, "relative_delta_sum": relativeSum,
            "hardware_context": "context\(observedGroup ?? device.physical.activeGroup)", "software_page": page,
            "feedback_endpoint": effects.last?["endpoint"] ?? regressionNull,

            "route_generation": routeGeneration, "old_authorization_valid": regressionValue(oldAuthorization),
            "authorization_rules_equal": regressionValue(guiPermissionResult.flatMap { a in
                remotePermissionResult.map { a == $0 }
            }),
            "manual_authority_granted": regressionValue(manualAuthority),
            "result_certain": regressionValue(resultCertain), "automatic_action_replay_count": proxyRequests.map { max(
                0,
                $0 - 1
            ) } ?? 0,
            "journal_gap": regressionValue(gap),
            "monotonic_policy_preserved": !monotonicResults.isEmpty && monotonicResults
                .first == true && monotonicResults.dropFirst().allSatisfy { !$0 },
            "authority_error_visible": context.presentation.notice?.level == .error,
            "rendered_value": regressionValue(session.engine.value(of: "p1")),
            "transaction_progress": preset.displayReadTask != nil ? 0 : (preset.displayProfile == nil ? -1 : 1),
            "restore_identity_valid": recovery.canRestorePreset,
            "enable_binding_count": session.outputEnableParameter == nil ? 0 : 1,
            "display_plan_valid": pageProjectionValid ?? planValid,
            "provenance_preserved": provenanceAvailable,
            "qualification_upgraded": !eligibility.isSubset(of: initialEligibility)
        ]
        return nativeState
    }

    func execute(_ row: [String: Any], repo: URL) async throws -> String? {
        let operation = try regressionString(row, "operation"), arguments = try regressionObject(row["arguments"])
        if operation != "advance_time" { clock.wall += 0.3; clock.monotonic += 0.3 }
        defer { collectOutputs() }
        switch operation {
        case "receive_input":
            try receive(
                regressionString(arguments, "element_id"),
                value: arguments["value"]!,
                context: regressionString(arguments, "context")
            )
        case "receive_repeated":
            for _ in 0 ..< Int(try regressionNumber(arguments, "count")) {
                try receive(
                    regressionString(arguments, "element_id"),
                    value: arguments["value"]!,
                    context: regressionString(arguments, "context")
                )
                clock.wall += 0.3; clock.monotonic += 0.3
            }
        case "turn_absolute":
            let message = try device.physical.turn(
                control(regressionString(arguments, "element_id")),
                by: Int(regressionNumber(arguments, "delta"))
            )
            if let message { device.onMessages?([message]) }
            rawAppend("fake-physical-absolute-turn", ["message": message.map { $0.midi1Bytes as Any } ?? regressionNull,
                                                      "native_fake_value": device.physical.value(of: control("axis"))])
        case "select_software_page":
            let page = try regressionString(arguments, "page")
            let mark = device.records.count
            try intents.selectPage(page)
            let pageData = try XCTUnwrap(regressionRows(setup["pages"]).first { $0["id"] as? String == page })
            let binding = try XCTUnwrap(regressionRows(pageData["bindings"])
                .first { $0["element_id"] as? String == "axis" })
            let target = try regressionString(binding, "target_id"), axis = control("axis")
            let definition = try XCTUnwrap(session.engine.configuration.parameter(ParameterID(target)))
            let value = try XCTUnwrap(session.engine.value(of: ParameterID(target)))
            let parameterData = try XCTUnwrap(regressionRows(setup["parameters"])
                .first { $0["id"] as? String == target })
            let expectedInitial = try regressionNumber(parameterData, "initial")
            let midi = try XCTUnwrap(session.engine.hardwareMap.midi(for: axis))
            let expected = MIDI1UMPCodec.feedback(control: midi, value: definition.midiValue(for: value))
            var copy = session.engine
            let plan = copy.fullFeedback(at: Date(timeIntervalSinceReferenceDate: clock.wall))
                .compactMap { effect -> MIDIVoiceMessage? in
                    if case let .send(message) = effect { return message }; return nil
                }
            let bound = session.engine.configuration.assignment(for: axis)?.target.parameterID?.rawValue
            let sends = Array(device.records.dropFirst(mark))
            pageProjectionValid = session.engine.configuration
                .activePageID == page && bound == target && value == expectedInitial &&
                plan.contains(expected) && sends.contains { $0.0 == expected && $0.1 }
            rawAppend(
                "real-page-bound-projection",
                ["page": page, "actual_target": regressionValue(bound), "expected_target": target,
                 "parameter_value": value, "expected_data_initial": expectedInitial,
                 "expected_codec_bytes": expected.midi1Bytes,
                 "native_plan": plan.map(\.midi1Bytes),
                 "actual_transport": sends.map { [
                     "bytes": $0.0.midi1Bytes as Any,
                     "accepted": $0.1
                 ] },
                 "projection_valid": pageProjectionValid!]
            )
        case "publish_display":
            let element = try regressionString(arguments, "element_id"), value = UInt16(try regressionNumber(
                arguments,
                "value"
            ))
            if let style = arguments["style"] as? String, style != "unchanged" {
                let control = control(element),
                    entry = try XCTUnwrap(session.learnedHardwareMap.entries.first { $0.control == control })
                var map = session.learnedHardwareMap
                try map.bind(control, to: entry.midi, ringMode: style == "alternate" ? .bar : .oneDot,
                             visualizationOnly: entry.visualizationOnly == true, pressMode: entry.pressMode)
                try session.installHardwareMap(map)
                rawAppend("native-ring-style", ["ring_mode": map.ringMode(for: control)!.rawValue])
            }
            if source == "hardware" { try session.setHardwareDisplayFeedback(control(element), rawValue: value) }
            else { try session.setSimulationDisplayFeedback(control(element), rawValue: value) }
        case "prepare_display":
            // Retain the real session scheduler's plan, never a fixture-owned output queue.
            try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
            oldGeneration = session.inputEvents.generation
            if scenario ==
                "T12" { oldExpected = gateway.call("surface_control_discover").value.objectValue?["expected"] }
            try intents.setParameter("p1", to: regressionNumber(arguments, "value"))
            rawAppend(
                "native-queued-feedback",
                ["pending": session.pendingFeedbackCount, "generation": session.inputEvents.generation]
            )
        case "flush":
            device.reject = arguments["transport_result"] as? String == "rejected"
            let transportMark = device.records.count
            session.flushFeedback()
            if let oldExpected {
                let result = gateway.call("surface_control_feedback", arguments: .object([
                    "expected": oldExpected, "control_id": .string(BCRSurfaceControlAdapter.controlID(control("axis"))),
                    "kind": .string("value"), "value": .number(100)
                ]))
                oldAuthorization = !result.isError
                rawAppend(
                    "native-old-expected-feedback",
                    ["is_error": result.isError, "result": try json(result.value)]
                )
            }
            let rejected = device.records.dropFirst(transportMark).filter { !$0.1 }.map { $0.0 }
            if device.reject,
               rejected.isEmpty { return "Rejected flush must attempt at least one actual transport message" }
            let evidence = rejected.map { session.engine.isFeedbackEcho(
                $0,
                at: Date(timeIntervalSinceReferenceDate: clock.wall)
            ) }
            rawAppend("native-flush", ["pending": session.pendingFeedbackCount, "reject": device.reject,
                                       "rejected_messages": rejected.map(\.midi1Bytes),
                                       "actual_engine_echo_evidence": evidence])
            if device.reject,
               evidence
                   .contains(true) { return "Rejected native transport populated actual engine feedback echo evidence" }
        case "replace_route":
            let previous = session.inputEvents.generation
            device.connection(nil); device.connection(1)
            if previous != session.inputEvents.generation { routeGeneration += 1 }
            rawAppend("native-route-epoch", ["before": previous, "after": session.inputEvents.generation,
                                             "source": session.source.rawValue,
                                             "source_id": regressionValue(session.connection.connectedSourceID)])
        case "configure_permissions":
            gateway.permissions.parameterWrite = arguments["display"] as? Bool ?? false
            session.configureParameterWrites(allowsWrite: arguments["display"] as? Bool ?? false,
                                             allowsDisplay: arguments["display"] as? Bool ?? false)
            rawAppend("native-permissions", ["remote_parameter_write": gateway.permissions.parameterWrite,
                                             "immutable_gui_hardware_policy": session.hardwareOutput.rawValue])
        case "write_parameter":
            let value = try regressionNumber(arguments, "value"), parameter = try regressionString(
                arguments,
                "parameter_id"
            )
            if arguments["origin"] as? String == "remote" {
                let result = gateway.call(
                    "set_parameter",
                    arguments: .object(["id": .string(parameter), "value": .double(value)])
                )
                remotePermissionResult = !result.isError
                rawAppend("real-provider-write-result", ["is_error": result.isError, "value": try json(result.value)])
            } else {
                let before = session.events.filter { $0.direction == .output && $0.delivery == .sent }.count
                intents.setParameter(ParameterID(parameter), to: value)
                let after = session.events.filter { $0.direction == .output && $0.delivery == .sent }.count
                guiPermissionResult = after > before
                rawAppend(
                    "real-gui-intent",
                    ["value": value, "native_value": regressionValue(session.engine.value(of: ParameterID(parameter))),
                     "accepted_output_delta": after - before]
                )
            }
        case "preset_transaction":
            let transaction = try regressionString(arguments, "transaction_id"), verb = try regressionString(
                arguments,
                "verb"
            )
            switch verb {
            case "begin":
                session.selectSource(.hardware); device.holdsDump = true
                preset.refreshDisplayFromDevice()
                transactionHandles[transaction] = preset.displayReadTask
                if transaction == "old" { try await waitUntil { !self.device.dumps.isEmpty } }
                rawAppend(
                    "real-bcl-read-begin",
                    ["transaction": transaction, "pending_reply_count": device.dumps.count]
                )
            case "cancel":
                session.selectSource(.mock); preset.validateConnectionWork()
                rawAppend(
                    "real-bcl-read-cancel",
                    ["transaction": transaction, "task_cancelled": transactionHandles[transaction]?.isCancelled == true]
                )
            case "reply":
                guard !device.dumps.isEmpty else { throw RegressionError.shape("held old reply") }
                let previous = preset.displayReadTask
                let profile = preset.displayProfile
                let evidence = try numberEvidence()
                device.dumps.removeFirst().resume(returning: device.preset)
                await transactionHandles[transaction]?.value
                try await waitUntil { !self.device.dumps.isEmpty }
                let newEvidence = try numberEvidence()
                let sameHandle = previous != nil && preset.displayReadTask == previous
                let sameProfile = preset.displayProfile == profile
                let sameEvidence = evidence == newEvidence
                rawAppend("real-old-bcl-reply", ["transaction": transaction, "new_handle_preserved": sameHandle,
                                                 "old_task_cancelled": transactionHandles[transaction]?
                                                     .isCancelled == true,
                                                 "display_profile_before": try encoded(profile),
                                                 "display_profile_after": try encoded(preset.displayProfile),
                                                 "number_evidence_before": try json(evidence),
                                                 "number_evidence_after": try json(newEvidence),
                                                 "profile_unchanged": sameProfile, "evidence_unchanged": sameEvidence])
                if !sameHandle || !sameProfile ||
                    !sameEvidence
                { return "Old BCL reply changed replacement task, display profile or number evidence"
                }
            default: throw RegressionError.operation(verb)
            }
        case "save_restore":
            switch try regressionString(arguments, "verb") {
            case "save":
                let backup = try store.saveBackup(device.preset)
                let point = PresetRestorePoint(
                    backupFile: backup.lastPathComponent,
                    hardwareMap: session.learnedHardwareMap,
                    createdAt: .now,
                    route: PresetRestoreRoute(session.connection),
                    expectedPreset: device.preset,
                    expectedHardwareMap: session.learnedHardwareMap,
                    acknowledgedLines: 1,
                    backupDigest: PresetBackupStore.digest(device.preset)
                )
                try store.saveRestorePoint(point); originalRestore = point
                rawAppend(
                    "real-persistent-restore-save",
                    ["backup_digest": point.backupDigest!, "route": try encoded(point.route)]
                )
            case "restart":
                // New native owners reload the same durable file. The fake other device has a different endpoint ID.
                device.onMessages = nil; device.onConnection = nil
                device.connection(2)
                let hardwareFile = ProtectedJSONFile
                    .hardware(JSONFileStore<HardwareMap>(fileURL: directory.appending(path: "map.json")))
                let configurationFile = ProtectedJSONFile.configuration(
                    JSONFileStore(fileURL: directory.appending(path: "config.json")),
                    preset: .starter
                )
                let clock = clock
                session = SurfaceSession(hardwareDevice: device, hardwareMap: hardwareFile.load().value,
                                         configuration: configurationFile.load().value,
                                         pluginBindings: AgentBindingTranslation.bindings,
                                         requiresHardwareConfirmation: true, hardwareLifecycleFeedback: false,
                                         now: { Date(timeIntervalSinceReferenceDate: clock.wall) },
                                         saveHardwareMap: { try hardwareFile.save($0) },
                                         saveConfiguration: { try configurationFile.save($0) })
                session.selectSource(.hardware)
                let ui = ConsolePresentationState(
                    timing: .immediate,
                    workspacePanelStore: JSONFileStore(fileURL: directory.appending(path: "ui.json"))
                )
                context = ConsoleDeviceContext(session: session, midi: device, presentation: ui, timing: .immediate,
                                               canConfigureMIDI: true, hardwareFile: hardwareFile)
                gateway = MCPApplicationGateway(session: session)
                intents = ConsoleSurfaceIntents(
                    context: context,
                    configurationFile: configurationFile,
                    migratedHardwareMap: nil,
                    migratedConfiguration: false
                )
                store = ConsoleRecoveryStore(directory: directory)
                preset = ConsolePresetWork(context: context, gate: gate, recoveryStore: store, directory: directory)
                recovery = ConsoleRecoveryWork(context: context, preset: preset, gate: gate, store: store)
                preset.recovery = recovery
                rawAppend("real-owner-restart", ["point_reloaded": store.presetRestorePoint == originalRestore,
                                                 "other_device_source_id": regressionValue(device.connection
                                                     .connectedSourceID)])
            case "restore":
                recovery.restorePresetBeforeAlignment()
                await recovery.restoreTask?.value
                rawAppend(
                    "native-restore-preflight",
                    [
                        "can_restore": recovery.canRestorePreset,
                        "reason": regressionValue(recovery.restoreUnavailableReason),
                        "write_batches": device.batches.count
                    ]
                )
            case "undo":
                // Motor scenarios are physically NA for BCR, so no synthetic undo model is supplied.
                throw RegressionError.operation("BCR has no motor endpoint")
            default: throw RegressionError.shape("restore verb")
            }
        case "simulation_feedback":
            try session.setSimulationDisplayFeedback(
                control(regressionString(arguments, "element_id")),
                rawValue: UInt16(regressionNumber(arguments, "value"))
            )
        case "simulation_reset":
            try session.resetSimulationContext()
        case "remote_input":
            if arguments["drop_response"] as? Bool == true {
                try await responseLoss(repo: repo)
            } else {
                let discover = gateway.call("surface_control_discover")
                let expected = try XCTUnwrap(discover.value.objectValue?["expected"])
                let inputSequence = try XCTUnwrap(discover.value.objectValue?["latest_input_sequence"])
                let before = gateway.call("surface_control_snapshot", arguments: .object(["instance_id": .string(id)]))
                let originalActions = actions
                let valid: [String: JSONValue] = ["expected": expected, "expected_input_sequence": inputSequence,
                                                  "control_id": .string("button.1.1"), "encoding": .string("boolean"),
                                                  "value": .bool(true)]
                let normal = gateway.call("surface_control_input", arguments: .object(valid))
                var forged = valid
                forged["origin"] = .string("hardware")
                let result = gateway.call("surface_control_input", arguments: .object(forged))
                let after = gateway.call("surface_control_snapshot", arguments: .object(["instance_id": .string(id)]))
                let inputUnchanged = before.value.objectValue?["inputs"] == after.value.objectValue?["inputs"] &&
                    before.value.objectValue?["latest_input_sequence"] == after.value
                    .objectValue?["latest_input_sequence"]
                let normalCode = normal.value.objectValue?["code"]?.stringValue
                let forgedCode = result.value.objectValue?["code"]?.stringValue
                manualAuthority = !normal.isError || !result.isError || actions != originalActions
                rawAppend(
                    "real-forged-origin-refusal",
                    ["otherwise_valid_input": try json(.object(valid)), "forged_input": try json(.object(forged)),
                     "normal_result": try json(normal.value),
                     "forged_result": try json(result.value),
                     "input_sequence_before": try json(inputSequence),
                     "snapshot_before": try json(before.value),
                     "snapshot_after": try json(after.value),
                     "inputs_unchanged": inputUnchanged,
                     "actions_before": originalActions, "actions_after": actions]
                )
                if normalCode != "permission_denied" || forgedCode != "invalid_argument" || !inputUnchanged ||
                    actions !=
                    originalActions
                {
                    return "Otherwise-valid hardware input or origin-only strict rejection did not preserve native input/action state"
                }
            }
        case "overflow_journal":
            let adapter = try XCTUnwrap(hardwareContract)
            let discovery = try adapter.execute(.discover, gateway: gateway)
            let epoch = try XCTUnwrap(discovery.objectValue?["expected"]?.objectValue?["epoch"]?.stringValue)
            for index in 0 ..< Int(try regressionNumber(arguments, "count")) {
                try receive("axis", value: (index % 100) + 1)
            }
            do {
                _ = try adapter.execute(
                    .events(instanceID: id, epoch: epoch, afterSequence: "0", limit: 1024),
                    gateway: gateway
                )
                gap = false
            } catch {
                gap = BCRSurfaceControlAdapter.failureCode(error) == "event_gap"
                rawAppend("native-bounded-journal-gap", ["code": BCRSurfaceControlAdapter.failureCode(error)])
            }
            let snapshot = try adapter.execute(.snapshot(instanceID: id), gateway: gateway)
            let retained = try adapter.execute(
                .events(instanceID: id, epoch: epoch, afterSequence: "1", limit: 1024),
                gateway: gateway
            )
            rawAppend(
                "native-live-hardware-journal",
                ["snapshot": try json(snapshot), "retained_events": try json(retained),
                 "capacity": setup["journal_capacity"]!]
            )
        case "advance_time":
            // The display credential uses the actual monotonic budget; wall-clock changes cannot refill it.
            clock.monotonic += try regressionNumber(arguments, "monotonic_delta_s")
            clock.wall += try regressionNumber(arguments, "wall_delta_s")
            let accepted = consumeDisplayBudget(); monotonicResults.append(accepted)
            rawAppend("native-budget-result", ["monotonic": clock.monotonic, "wall": clock.wall, "accepted": accepted])
        case "authority_reply":
            let parameter = ParameterID(try regressionString(arguments, "parameter_id"))
            let actual = try regressionNumber(arguments, "actual_value")
            let accepted = arguments["accepted"] as? Bool ?? false
            let reason = try regressionString(arguments, "reason")
            session.parameterAuthority = { request in
                guard request.parameter == parameter else { return .accept }
                return accepted ? .accept : .reject(actual: actual, reason: reason)
            }
            rawAppend("native-authority-installed", ["parameter": parameter.rawValue, "accepted": accepted])
        case "receive_unconfigured":
            let element = try regressionString(arguments, "element_id")
            let message = element == "meter" ? MIDIVoiceMessage
                .controlChange(channel: 15, number: 126, value: 127) : .controlChange(
                    channel: 15,
                    number: 127,
                    value: 127
                )
            device.onMessages?([message]); rawAppend("unconfigured-input", ["bytes": message.midi1Bytes])
        case "attach_endpoint":
            let name = try regressionString(arguments, "name")
            let provenance: MIDIEndpointProvenance = try regressionString(arguments, "provenance") == "remote_virtual" ?
                .remoteVirtual : .physicalUSB
            let native = MIDIEndpointDescriptor(id: Int32(endpointRows.count + 10), name: name, provenance: provenance)
            device.connection = MIDIConnectionSnapshot(connectedSource: native.name, connectedDestination: native.name)
            device.connection.connectedSourceID = native.id; device.connection.connectedDestinationID = native.id
            device.connection.sourceEndpoints = [native]; device.connection.destinationEndpoints = [native]
            device.onConnection?(device.connection)
            endpointRows.append([
                "neutral_endpoint": arguments["endpoint_id"]!,
                "requested_provenance": arguments["provenance"]!,
                "native_id": native.id,
                "native_name": native.name,
                "native_provenance": device.connection.sourceEndpoints.first?.provenance.rawValue ?? "unknown",
                "connection_generation": session.connectionGeneration
            ])
            rawAppend("native-endpoint-provenance", endpointRows.last!)
        case "inspect": break
        default: throw RegressionError.operation(operation)
        }
        if operation == "authority_reply" && authorityMissing {
            return "No product external-authority rejection-to-UI path; only existing actual-feedback API is available"
        }
        return nil
    }

    private func numberEvidence() throws -> JSONValue {
        guard let evidence = preset.presetNumberEvidence else { return .null }
        let value: [String: Any] = [
            "number": evidence.number,
            "route": try encoded(evidence.route),
            "name": evidence.name,
            "candidates": evidence.candidates,
            "device": evidence.device,
            "definition": evidence.definition,
            "locked": evidence.locked,
            "original_definition": evidence.originalDefinition,
            "uniqueness_proven": evidence.uniquenessProven
        ]
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func json(_ value: JSONValue) throws -> Any { try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    ) }
    private func encoded(_ value: some Encodable) throws -> Any { try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    ) }
    func drainHeldReplies() async {
        device.holdsDump = false
        for continuation in device.dumps { continuation.resume(throwing: CancellationError()) }
        device.dumps.removeAll()
        await preset.displayReadTask?.value
    }

    func responseLoss(repo: URL) async throws {
        guard source == "simulation" else { throw RegressionError.shape("loss action must be isolated simulation") }
        let stores = ConsoleStores(
            hardwareMap: JSONFileStore(fileURL: directory.appending(path: "mock-action-map.json")),
            configuration: JSONFileStore(fileURL: directory.appending(path: "mock-action-config.json"))
        )
        let work = ConsoleDeviceWork(stores: stores, startsMIDI: false, mcpCredentials: RegressionCredential(),
                                     integrationTest: true, midiService: device, automaticallyAdvancesMock: false,
                                     timing: .immediate)
        work.mcp.service.permissions.agentControl = true
        let original = work.mcp.service.onAgentAction
        var dispatches = 0
        work.mcp.service.onAgentAction = { action, slot in
            let before = work.slots.first?.state
            try original?(action, slot)
            if work.slots.first?.state != before { dispatches += 1 }
        }
        defer { work.mcp.service.onAgentAction = original }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
        let server = MCPHTTPServer(router: MCPRouter(service: work.mcp.service))
        let port = try await server.start(port: 0, token: token)
        defer { server.stop() }
        let payload = try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:\(port)/mcp", "token": token,
                                                                  "sdk": repo
                                                                      .appending(
                                                                          path: "build/seed/SurfacePlugins/clients/python"
                                                                      )
                                                                      .path])
        let before = work.slots[0].state.rawValue
        let (status, output, errors) = try await regressionProcess(
            ["python3", "-B", repo.appending(path: "Tests/H10Support/response_drop.py").path],
            input: payload
        )
        guard !String(decoding: output + errors, as: UTF8.self).contains(token)
        else { throw RegressionError.shape("credential leak") }
        guard status == 0 else { throw RegressionError.operation("drop proxy: " + String(
            decoding: errors,
            as: UTF8.self
        )) }
        let report = try regressionObject(JSONSerialization.jsonObject(with: output))
        guard report["upstream_successes"] as? Int == 1, dispatches == 1,
              work.slots[0].state.rawValue != before
        else { throw RegressionError.operation("action did not execute before loss") }
        resultCertain = report["client_code"] as? String != "transport_unknown"
        proxyRequests = report["proxy_requests"] as? Int
        actions += Array(repeating: 1, count: dispatches)
        rawAppend(
            "real-sdk-action-response-loss",
            ["tool": "start_agent", "before": before, "after": work.slots[0].state.rawValue,
             "dispatches": dispatches, "transport": report]
        )
    }
}

@MainActor
final class ControllerRegressionExecutorTests: XCTestCase {
    func testExecutesThirtySharedScenariosAndValidatesReportSeparatelyFromConformance() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let shared = URL(fileURLWithPath: environment["BCR_H10_SCHEMA_ROOT"] ?? repo
            .appending(path: "build/seed/SurfacePlugins").path)
        let fixture = URL(fileURLWithPath: environment["BCR_H10_FIXTURE_PATH"] ?? shared
            .appending(path: "fixtures/controller-regression-v1.json").path)
        let destination = URL(fileURLWithPath: environment["BCR_H10_REPORT_ROOT"] ?? repo
            .appending(path: "build/h/h10/final").path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: fixture)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, regressionFixtureSHA)
        guard digest == regressionFixtureSHA else { throw RegressionError.shape("coordinate fixture SHA change") }
        let document = try regressionObject(JSONSerialization.jsonObject(with: bytes))
        let scenes = try regressionRows(document["scenarios"])
        XCTAssertEqual(scenes.count, 30)
        var results: [[String: Any]] = [], traces: [[String: Any]] = []
        for scene in scenes {
            let scenarioID = try regressionString(scene, "id")
            let missing = Set(scene["requires_features"] as? [String] ?? []).subtracting(regressionFeatures)
            if !missing.isEmpty {
                results.append([
                    "id": scenarioID,
                    "status": "not_applicable",
                    "reason": "BCR2000 has no physical/protocol feature: " + missing.sorted().joined(separator: ","),
                    "steps": []
                ])
                continue
            }
            let setup = try regressionObject(scene["setup"])
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var instances: [String: RegressionInstance] = [:]
            for instance in try regressionRows(setup["instances"]) {
                let id = try regressionString(instance, "id")
                instances[id] = try RegressionInstance(
                    id: id,
                    source: regressionString(instance, "source"),
                    scenario: scenarioID,
                    setup: setup,
                    directory: temporary.appending(path: id)
                )
            }
            var records: [[String: Any]] = [], stepTraces: [[String: Any]] = []
            for (index, action) in try regressionRows(scene["steps"]).enumerated() {
                let operation = try regressionString(action, "operation"), instanceID = try regressionString(
                    action,
                    "instance_id"
                )
                let missing = Set(action["requires_features"] as? [String] ?? []).subtracting(regressionFeatures)
                if !missing.isEmpty {
                    records.append([
                        "index": index,
                        "operation": operation,
                        "status": "not_applicable",
                        "reason": "BCR2000 lacks " + missing.sorted().joined(separator: ","),
                        "before": [:],
                        "after": [:],
                        "effects": []
                    ])
                    continue
                }
                let before = instances.mapValues { $0.observations() }
                let offsets = instances.mapValues { ($0.effects.count, $0.raw.count) }
                var failure: String?
                guard let instance = instances[instanceID] else { throw RegressionError.shape("instance") }
                do { failure = try await instance.execute(action, repo: repo) }
                catch { failure = "Actual API error: " + String(describing: error) }
                let after = instances.mapValues { $0.observations() }
                let effects = instances.flatMap { id, value in Array(value.effects.dropFirst(offsets[id]!.0)) }
                let unmet = try regressionRows(action["expect"]).filter { !regressionExpect(
                    $0,
                    instance: instanceID,
                    before: before,
                    after: after
                ) }
                if !unmet
                    .isEmpty
                {
                    failure = (failure.map { $0 + "; " } ?? "") + "Real observations differ: " + unmet
                        .compactMap { $0["metric"] as? String }.joined(separator: ",")
                }
                let reason: Any = failure.map { String($0.prefix(512)) } ?? regressionNull
                records.append([
                    "index": index,
                    "operation": operation,
                    "status": failure == nil ? "pass" : "fail",
                    "reason": reason,
                    "before": before,
                    "after": after,
                    "effects": effects
                ])
                stepTraces.append(["index": index, "operation": operation, "instance_id": instanceID,
                                   "arguments": action["arguments"]!,
                                   "native": instances
                                       .mapValues { value in Array(value.raw.dropFirst(offsets[value.id]!.1)) }])
            }
            results.append([
                "id": scenarioID,
                "status": records.contains { $0["status"] as? String == "fail" } ? "fail" : "pass",
                "reason": records
                    .contains { $0["status"] as? String == "fail" } ?
                    String(records.compactMap { $0["status"] as? String == "fail" ? $0["reason"] as? String : nil }
                        .joined(separator: "; ").prefix(512)) as Any : regressionNull,
                "steps": records
            ])
            traces.append([
                "id": scenarioID,
                "steps": stepTraces,
                "native_endpoints": instances.mapValues { $0.endpointRows },
                "fake_transport": instances.mapValues { $0.device.records.map { [
                    "bytes": $0.0.midi1Bytes as Any,
                    "accepted": $0.1
                ] } },
                "preset_batches": instances.mapValues { $0.device.batches }
            ])
            for instance in instances.values { await instance.drainHeldReplies(); XCTAssertEqual(
                instance.device.starts,
                0
            ) }
        }
        let (gitStatus, gitOutput, _) = try await regressionProcess(["git", "-C", repo.path, "rev-parse", "HEAD"])
        XCTAssertEqual(gitStatus, 0)
        let report: [String: Any] = [
            "schema_version": 1,
            "artifact": "neutral-controller-regression-results",
            "fixture_sha256": digest,
            "host_revision": String(decoding: gitOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            "host_id": "bcr2000",
            "qualification": "test-only-fake-device",
            "features": regressionFeatures.sorted(),
            "results": results
        ]
        let reportPath = destination.appending(path: "controller-regression-results.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportPath)
        try JSONSerialization.data(
            withJSONObject: ["fixture_sha256": digest, "hardware_accessed": false, "traces": traces],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: destination.appending(path: "controller-regression-raw.json"))
        let (status, output, errors) = try await regressionProcess([
            "python3",
            "-B",
            shared.appending(path: "scripts/validate_controller_regression.py").path,
            "--fixture",
            fixture.path,
            "--report",
            reportPath.path
        ])
        print("H10_REPORT_VALIDATION " + String(decoding: output, as: UTF8.self))
        XCTAssertEqual(
            status,
            0,
            "Report validity is separate from conformance: \(String(decoding: errors, as: UTF8.self))"
        )
    }
}
