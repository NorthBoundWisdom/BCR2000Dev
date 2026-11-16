import BCRFoundation
@testable import BCRSurfaceDomain
import Foundation
import SurfaceDeviceContracts
import XCTest

@MainActor
final class NeutralSurfaceProjectionTests: XCTestCase {
    private final class Sequence {
        var value = 0; func next() -> String { value += 1; return "fixture-generation.\(value)" }
    }

    private final class Device: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        func send(_ message: MIDIVoiceMessage) throws {}
    }

    func testInjectedJournalGenerationChangesOnResetAndRejectsOldGeneration() async throws {
        let sequence = Sequence()
        let journal = ProviderEventJournal(source: .mock, generationFactory: { sequence.next() })
        XCTAssertEqual(journal.generation, "fixture-generation.1")
        let old = journal.generation
        journal.reset(source: .hardware)
        XCTAssertEqual(journal.generation, "fixture-generation.2")
        XCTAssertThrowsError(try journal.read(generation: old))
        XCTAssertEqual(sequence.value, 2)
    }

    func testSessionRouteUsesInjectedFreshGenerationsAndNeutralPortOnlyObservesAcceptedInput() async throws {
        let sequence = Sequence(), device = Device()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                     configuration: .init(name: "fixture", parameters: [.init(id: "x", name: "x")],
                                                          assignments: [.init(control: .pushEncoder(group: 1, 1),
                                                                              target: .parameter("x"))]),
                                     hardwareLifecycleFeedback: false, generationFactory: { sequence.next() },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        let before = session.inputEvents.generation
        session.selectGroup(4)
        var input: [DeviceInputEvent] = []
        _ = session.observeNeutralInputs(instanceID: "fixture") { input.append($0) }
        let message = try XCTUnwrap(session.engine.hardwareMap.midi(for: .pushEncoder(group: 1, 1)))
        device.onMessages?([MIDI1UMPCodec.feedback(control: message, value: 12)])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?.source, .hardware)
        XCTAssertEqual(input.first?.value, .number(12))
        XCTAssertNil(input.first?.context.mappingRevision)
        XCTAssertTrue(input.first?.context.id.hasSuffix("|device-context=unknown") == true)
        XCTAssertFalse(input.first?.context.id.contains("simulation.encoder-group.4") == true)
        device.connection.connectedSourceID = 4
        device.onConnection?(device.connection)
        XCTAssertNotEqual(session.inputEvents.generation, before)
        XCTAssertThrowsError(try session.inputEvents.read(generation: before))
        XCTAssertEqual(sequence.value, 3)
    }

    func testRelativeWireKnowledgeStaysAdapterAndUnknownIdentityIsNotInvented() async throws {
        let endpoint = try BCRNeutralSurfaceProjection.endpoint(.init(endpointID: "unknown", connectionGeneration: 7,
                                                                      provenance: .localVirtual))
        XCTAssertNil(endpoint.endpointID)
        XCTAssertNil(endpoint.deviceID)
        XCTAssertEqual(endpoint.transportOrigin, .localVirtual)
        let context = try BCRNeutralSurfaceProjection.context(instanceID: "fixture", generation: "generation.1",
                                                              mappingGeneration: 2)
        let input = try BCRNeutralSurfaceProjection.input(control: .pushEncoder(group: 1, 1),
                                                          message: .controlChange(channel: 0, number: 1, value: 127),
                                                          mode: .relative1,
                                                          context: context, endpoint: endpoint, source: .hardware,
                                                          at: 10)
        XCTAssertEqual(input.kind, .relative)
        XCTAssertEqual(input.value, .number(-1))
        let reported = try BCRNeutralSurfaceProjection.observation(input)
        XCTAssertEqual(reported.value, .number(-1))
        XCTAssertEqual(reported.targetID, input.elementID + ".input.relative-delta")
        XCTAssertNotEqual(reported.targetID, input.elementID + ".input.position")
        XCTAssertFalse([reported]
            .contains { $0.targetID == input.elementID + ".input.position" && $0.state == .observed })
        XCTAssertThrowsError(try BCRNeutralSurfaceProjection.input(control: .pushEncoder(group: 1, 1),
                                                                   message: .controlChange(
                                                                       channel: 0,
                                                                       number: 1,
                                                                       value: 127
                                                                   ), mode: .relative1,
                                                                   context: context, endpoint: endpoint,
                                                                   source: .hardware, at: .nan))
    }

    func testCapabilityContentIdentityIncludesInputInterpretationButNotBusinessValues() async throws {
        let map = HardwareMap.mockPreset()
        func configuration(mode: EncoderMode, initial: Double = 0) -> SurfaceConfiguration {
            .init(name: "fixture", parameters: [.init(id: "x", name: "x", defaultValue: initial)],
                  assignments: [.init(control: .pushEncoder(group: 1, 1), target: .parameter("x"), encoderMode: mode)])
        }
        let absolute = try BCRNeutralSurfaceProjection.capabilities(
            map: map,
            configuration: configuration(mode: .absolute)
        )
        let relative = try BCRNeutralSurfaceProjection.capabilities(
            map: map,
            configuration: configuration(mode: .relative1)
        )
        let otherValue = try BCRNeutralSurfaceProjection.capabilities(
            map: map,
            configuration: configuration(mode: .absolute, initial: 99)
        )
        XCTAssertNotEqual(absolute.profileID, relative.profileID)
        XCTAssertEqual(absolute.profileID, otherValue.profileID)
        let element = BCRNeutralSurfaceProjection.elementID(.pushEncoder(group: 1, 1))
        XCTAssertEqual(
            absolute.modes.first?.elements.first(where: { $0.elementID == element })?.inputs.first?.kind,
            .absolute
        )
        let kinds = relative.modes.first?.elements.first(where: { $0.elementID == element })?.inputs
            .map { $0.kind.rawValue }.sorted()
        XCTAssertEqual(kinds, ["absolute", "relative"])
        XCTAssertEqual(relative.modes.count, 1)
        XCTAssertEqual(relative.modes.first?.id, "midi-1")
    }

    func testPhysicalRolesStayStableAcrossGroupsWhileFacetsAndDisplayTargetsRemainDistinct() async throws {
        let base = try BCRNeutralSurfaceProjection.context(
            instanceID: "fixture",
            generation: "g.1",
            mappingGeneration: 1
        )
        let endpoint = try BCRNeutralSurfaceProjection.endpoint(nil)
        let a = try BCRNeutralSurfaceProjection.input(control: .pushEncoder(group: 1, 1),
                                                      message: .controlChange(channel: 0, number: 1, value: 40),
                                                      mode: .absolute,
                                                      context: base, endpoint: endpoint, source: .hardware, at: 1)
        let b = try BCRNeutralSurfaceProjection.input(control: .pushEncoder(group: 2, 1),
                                                      message: .controlChange(channel: 0, number: 9, value: 50),
                                                      mode: .absolute,
                                                      context: base, endpoint: endpoint, source: .hardware, at: 1)
        XCTAssertEqual(a.elementID, b.elementID)
        XCTAssertNotEqual(a.context.id, b.context.id)
        XCTAssertTrue(a.context.id.hasSuffix("|device-context=unknown"))
        XCTAssertTrue(b.context.id.hasSuffix("|device-context=unknown"))
        XCTAssertNotEqual(a.elementID, BCRNeutralSurfaceProjection.elementID(.pushEncoderButton(group: 1, 1)))
        func event(_ group: Int) -> MonitorEvent {
            .init(id: group, time: Date(timeIntervalSinceReferenceDate: 1), monotonicTime: 1,
                  direction: .output, source: .hardware, message: .controlChange(
                      channel: 0,
                      number: UInt8(group),
                      value: 40
                  ),
                  control: .pushEncoder(group: group, 1), ignored: false, origin: .software, delivery: .sent)
        }
        let first = try XCTUnwrap(BCRNeutralSurfaceProjection.feedback(event(1), context: base))
        let second = try XCTUnwrap(BCRNeutralSurfaceProjection.feedback(event(2), context: base))
        XCTAssertEqual(first.targetID, "pushEncoder.1.1")
        XCTAssertEqual(second.targetID, "pushEncoder.2.1")
        XCTAssertEqual(first.affectedElements, second.affectedElements)
        XCTAssertEqual(first.affectedElements, Set([a.elementID]))
    }

    func testOnlyDeclaredMomentaryButtonsProducePhysicalPressAndReleaseEdges() async throws {
        let control = BCRControlID.button(row: 1, 1)
        let midi = MIDIControlID(kind: .controlChange, channel: 0, number: 11)
        let base = try BCRNeutralSurfaceProjection.context(
            instanceID: "fixture",
            generation: "g.1",
            mappingGeneration: 1
        )
        let endpoint = try BCRNeutralSurfaceProjection.endpoint(nil)
        for mode: HardwarePressMode? in [nil, .pulse, .momentary] {
            let map = HardwareMap(entries: [.init(control: control, midi: midi, pressMode: mode)])
            let capabilities = try BCRNeutralSurfaceProjection.capabilities(map: map, configuration: .neutral())
            let kinds = try XCTUnwrap(capabilities.modes.first?.elements.first).inputs.map { $0.kind.rawValue }.sorted()
            XCTAssertEqual(kinds, mode == .momentary ? ["press", "release"] : ["absolute"])
            for value: UInt8 in [0, 127] {
                let input = try BCRNeutralSurfaceProjection.input(control: control,
                                                                  message: MIDI1UMPCodec.feedback(
                                                                      control: midi,
                                                                      value: value
                                                                  ), mode: .absolute,
                                                                  context: base, endpoint: endpoint, source: .hardware,
                                                                  at: 1, pressMode: mode)
                XCTAssertEqual(input.value, .flag(value > 0))
                let observed = try BCRNeutralSurfaceProjection.observation(input)
                if mode == .momentary {
                    XCTAssertEqual(input.kind, value > 0 ? .press : .release)
                    XCTAssertTrue(observed.targetID.hasSuffix(".input.pressed"))
                } else {
                    XCTAssertEqual(input.kind, .absolute)
                    XCTAssertTrue(observed.targetID.hasSuffix(".input.signal-state"))
                    XCTAssertFalse(observed.targetID.hasSuffix(".input.position"))
                }
            }
        }
    }

    func testSuppressionHasNoTransmissionEvidenceAndOutputCanNeverBecomeObservation() async throws {
        let context = try BCRNeutralSurfaceProjection.context(
            instanceID: "fixture",
            generation: "g.1",
            mappingGeneration: 1
        )
        let event = MonitorEvent(id: 1, time: Date(timeIntervalSinceReferenceDate: 1), monotonicTime: 1,
                                 direction: .output, source: .hardware, message: .controlChange(
                                     channel: 0,
                                     number: 1,
                                     value: 64
                                 ),
                                 control: .pushEncoder(group: 1, 1), ignored: true, origin: .software,
                                 delivery: .suppressed)
        let effect = try XCTUnwrap(BCRNeutralSurfaceProjection.feedback(event, context: context))
        XCTAssertEqual(effect.requiredDirections, Set([EffectDirection.display]))
        XCTAssertNil(try BCRNeutralSurfaceProjection.transmission(event, effect: effect))
    }
}
