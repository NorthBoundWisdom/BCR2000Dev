import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import AppKit
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
import enum SurfacePluginContracts.IndicatorSemantic
import UniformTypeIdentifiers
import Combine
import Foundation

@MainActor
final class ConsoleButtonFeedbackWork: ObservableObject, ConsoleDeviceOwner {
    let context: ConsoleDeviceContext
    let codex: CodexAgentController
    private(set) var mockAgents: BCRMockAgentHost?
    @Published private(set) var blinksAgentLEDs: Bool
    private var agentSemantics: [AgentSlotID: IndicatorSemantic] = [:]
    private(set) var blinkTask: Task<Void, Never>?
    private var blinkLevels: [AgentSlotID: UInt8] = [:]
    private let blinkPreference: JSONFileStore<Bool>
    var slots: [AgentSlotPresentation] {
        get { presentation.slots } set { presentation.slots = newValue }
    }

    init(context: ConsoleDeviceContext, codex: CodexAgentController, directory: URL) {
        self.context = context; self.codex = codex
        blinkPreference = JSONFileStore(fileURL: directory.appending(path: "agent-led-blink.json"))
        blinksAgentLEDs = (try? blinkPreference.load()) ?? true
    }

    func installMockHost(_ host: BCRMockAgentHost) { mockAgents = host }
    func slot(_ id: AgentSlotID) -> AgentSlotPresentation? { slots.first { $0.id == id } }
    func applyAgentSlots(_ newSlots: [AgentSlotPresentation], changed slotID: AgentSlotID) {
        let previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.state) })
        slots = newSlots
        for slot in newSlots where previous[slot.id] != slot.state {
            showAgentState(slot, level: slot.state.feedbackValue)
        }
    }

    func setBlinksAgentLEDs(_ enabled: Bool) {
        guard enabled != blinksAgentLEDs else { return }
        blinksAgentLEDs = enabled
        do { try blinkPreference.save(enabled) } catch { report(error) }
        for slot in slots { showAgentState(slot, level: slot.state.feedbackValue) }
    }

    func showAgentState(_ slot: AgentSlotPresentation, level: UInt8) {
        agentSemantics[slot.id] = slot.state.indicatorSemantic
        guard blinksAgentLEDs else {
            blinkLevels[slot.id] = nil
            session.setIndicatorFeedback(AgentBindingTranslation.indicator(for: slot.id), value: level)
            updateBlinkTimer()
            return
        }
        refreshBlink(slot.id, at: timing.presentation.now())
        updateBlinkTimer()
    }

    private func refreshBlink(_ id: AgentSlotID, at time: Double) {
        guard let semantic = agentSemantics[id] else { return }
        let level: UInt8 = BCRIndicatorBlink.pattern(for: semantic).isOn(at: time) ? 127 : 0
        guard blinkLevels[id] != level else { return }
        blinkLevels[id] = level
        session.setIndicatorFeedback(AgentBindingTranslation.indicator(for: id), value: level)
    }

    private func updateBlinkTimer() {
        let blinking = blinksAgentLEDs && agentSemantics.values.contains { semantic in
            if case .blink = BCRIndicatorBlink.pattern(for: semantic) { return true }
            return false
        }
        guard blinking else { blinkTask?.cancel(); blinkTask = nil; return }
        guard blinkTask == nil else { return }
        blinkTask = Task { @MainActor [weak self, timing] in
            while !Task.isCancelled {
                do { try await timing.presentation.sleep(ConsoleTiming.blink) } catch { return }
                guard let self else { return }
                let now = timing.presentation.now()
                for id in self.agentSemantics.keys { self.refreshBlink(id, at: now) }
            }
        }
    }

    func showSurfaceApprovalNotice() {
        notice = ConsoleNotice(level: .info, message: "请在 Agent 页查看详情后批准或拒绝")
    }
}
