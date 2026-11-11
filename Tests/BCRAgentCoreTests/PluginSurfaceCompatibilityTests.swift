import Foundation
import XCTest
@testable import BCRAgentCore

final class PluginSurfaceCompatibilityTests: XCTestCase {
    private let slot = AgentSlotID(1)
    private let button = BCRControlID.button(row: 1, 1)
    private let time = Date(timeIntervalSinceReferenceDate: 1000)

    func testInjectedProductionBindingsOnlyEmitGenericActionAndPreserveFeedbackOrder() throws {
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: .starter(),
                                   pluginBindings: AgentBindingTranslation.bindings)
        let action = try AgentBindingTranslation.action(for: slot)
        let indicator = AgentBindingTranslation.indicator(for: slot)
        let midi = try XCTUnwrap(engine.hardwareMap.midi(for: button))
        _ = engine.setIndicatorFeedback(indicator, value: 96, at: time)
        let effects = engine.press(button, isDown: true, at: time.addingTimeInterval(1))
        XCTAssertEqual(effects, [.send(MIDI1UMPCodec.feedback(control: midi, value: 96)), .triggerAction(action)])
        XCTAssertFalse(effects.contains(.triggerAgent(slot)))
        XCTAssertEqual(engine.indicatorFeedback[indicator], 96)
        XCTAssertEqual(engine.agentFeedback[slot], 96) // Legacy facade reads neutral storage.
        _ = engine.replaceConfiguration(engine.configuration)
        XCTAssertEqual(engine.pluginBindings, AgentBindingTranslation.bindings)
        XCTAssertEqual(engine.indicatorFeedback[indicator], 96)
    }

    func testLegacyEnumPatternsStillMatchWithoutInjectedBindings() {
        let target = ControlTarget.agentPrimaryAction(slot)
        if case let .agentPrimaryAction(received) = target { XCTAssertEqual(received, slot) }
        else { XCTFail("Legacy target enum pattern must remain source compatible") }
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: .starter())
        let effects = engine.press(button, isDown: true, at: time)
        let triggered = effects.compactMap { effect -> AgentSlotID? in
            if case let .triggerAgent(received) = effect { return received }
            return nil
        }
        XCTAssertEqual(triggered, [slot])
    }

    func testInvalidLegacySlotsFailAtCheckedAndPluginBindingBoundariesWithoutTrapping() throws {
        for index in [Int.min, -1, 0, 9, Int.max] {
            let legacy = AgentSlotID(index)
            XCTAssertEqual(legacy.rawValue, index)
            XCTAssertThrowsError(try AgentSlotID(validating: index)) { error in
                XCTAssertEqual(error as? AgentSlotIDError, .outOfRange(index))
            }
            XCTAssertThrowsError(try AgentBindingTranslation.action(for: legacy))
        }
        XCTAssertEqual(try AgentBindingTranslation.slot(for: AgentBindingTranslation.action(for: slot)), slot)
    }

    @MainActor
    func testGenericSessionActionCallbackPreservesSynchronousLEDUpdateOnHeldPress() throws {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: .starter(),
                                     pluginBindings: AgentBindingTranslation.bindings,
                                     now: { self.time }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        var actions = 0
        session.onTriggerAgent = { _ in XCTFail("Production bindings must bypass legacy callback") }
        session.onTriggerAction = { [weak session] action in
            actions += 1
            XCTAssertEqual(try? AgentBindingTranslation.slot(for: action), self.slot)
            session?.setIndicatorFeedback(AgentBindingTranslation.indicator(for: self.slot), value: 40)
        }
        session.press(button)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(session.mock.value(of: button), 40)
        session.release(button)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(session.mock.value(of: button), 40)
    }
}
