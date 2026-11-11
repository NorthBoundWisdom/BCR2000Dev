import BCRAgentCore
import BCRPluginHost
import Foundation
import enum SurfacePluginContracts.InputOrigin

/// The host drives the shared Mock plugin independently of window redraws.
/// Codex process management and the device-origin approval boundary stay here.
extension ConsoleViewModel {
    func performPrimaryAction(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.perform(slotID); return }
        do { try requireMockHost().invoke(slotID, origin: .interface) } catch { report(error) }
    }

    /// Device-origin intents cannot grant a real Codex approval or dismiss its pending request.
    func performSurfaceAgentAction(_ slotID: AgentSlotID) {
        if codex.backend == .codex {
            if codex.slots.first(where: { $0.id == slotID })?.state == .waitingApproval {
                showSurfaceApprovalNotice()
                return
            }
            codex.perform(slotID)
        } else {
            do { try requireMockHost().invoke(slotID, origin: .hardware) } catch { report(error) }
        }
    }

    func start(_ slotID: AgentSlotID, origin: InputOrigin = .interface) {
        if codex.backend == .codex { codex.start(slotID); return }
        guard let slot = slot(slotID), !slot.state.isActive else { return }
        do { try requireMockHost().invoke(slotID, origin: origin) } catch { report(error) }
    }

    func interrupt(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.interrupt(slotID); return }
        guard let slot = slot(slotID), slot.state.isActive else { return }
        do { try requireMockHost().interrupt(slotID) } catch { report(error) }
    }

    func approve(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.decide(slotID, approve: true); return }
        guard slot(slotID)?.state == .waitingApproval else { return }
        do { try requireMockHost().invoke(slotID, origin: .interface) } catch { report(error) }
    }

    func decline(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.decide(slotID, approve: false); return }
        guard slot(slotID)?.state == .waitingApproval else { return }
        interrupt(slotID)
    }

    func requireMockHost() throws -> BCRMockAgentHost {
        guard let mockAgents else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
        return mockAgents
    }
}
