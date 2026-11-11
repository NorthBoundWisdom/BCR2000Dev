import Foundation
import XCTest
@testable import BCRAgentCore

final class AgentCompatibilityTests: XCTestCase {
    func testEveryAgentStateWritesExactValueToAllBoundLEDsAndRings() throws {
        let slot = AgentSlotID(1)
        let controls: [BCRControlID] = [
            .button(row: 1, 1), .button(row: 1, 2),
            .pushEncoder(group: 1, 1), .encoder(row: 1, 1)
        ]
        let hardware = HardwareMap.mockPreset()
        // The engine supports feedback to rings; configuration validation separately prohibits
        // assigning trigger actions to continuous controls. Exercise that existing feedback path.
        var engine = SurfaceEngine(hardwareMap: hardware, configuration: SurfaceConfiguration(
            name: "Agent feedback compatibility",
            assignments: controls.map { .init(control: $0, target: .agentPrimaryAction(slot)) } + [
                .init(control: .button(row: 1, 3), target: .agentPrimaryAction(AgentSlotID(2)))
            ]
        ))
        let expected: [(AgentRunState, UInt8)] = [
            (.idle, 0), (.queued, 40), (.running, 127), (.waitingApproval, 96),
            (.completed, 72), (.interrupted, 20), (.error, 8)
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(AgentRunState.allCases))
        for (state, value) in expected {
            XCTAssertEqual(state.feedbackValue, value, state.rawValue)
            let effects = engine.setAgentFeedback(slot, value: state.feedbackValue,
                                                  at: Date(timeIntervalSinceReferenceDate: 1000))
            let messages = effects.compactMap { effect -> MIDIVoiceMessage? in
                if case let .send(message) = effect { return message }
                return nil
            }
            XCTAssertEqual(messages, try controls.sorted().map {
                MIDI1UMPCodec.feedback(control: try XCTUnwrap(hardware.midi(for: $0)), value: value)
            }, state.rawValue)
            for control in controls { XCTAssertEqual(engine.state(of: control).lastOutput, value) }
            XCTAssertNil(engine.state(of: .button(row: 1, 3)).lastOutput)
        }
    }

    func testLegacyAgentPrimaryActionJSONRoundTripsWithoutChangingContent() throws {
        // Frozen pre-plugin configuration wire representation, including the old enum payload.
        let data = Data("""
        {"version":7,"name":"Legacy Agent","parameters":[],"assignments":[{
          "control":{"section":"button","row":1,"index":1},
          "target":{"agentPrimaryAction":{"_0":{"rawValue":8}}},
          "buttonBehavior":"toggle","inverted":false,"encoderMode":"absolute","encoderStep":1
        }],"pages":[],"macros":[]}
        """.utf8)
        let configuration = try JSONDecoder().decode(SurfaceConfiguration.self, from: data)
        XCTAssertEqual(configuration.assignments.first?.target, .agentPrimaryAction(AgentSlotID(8)))
        let roundTrip = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: roundTrip),
                       try JSONDecoder().decode(JSONValue.self, from: data))
    }
}
