import AgentPlugin
import AgentRemoteBinding
import BCRPluginRuntime
import BCRAgentDomain
import BCRConfigurationAdapter
import BCRFoundation
import BCRSurfaceDomain
import Foundation
import SurfacePluginContracts

/// Explicit composition of the Mock plugin. Codex processes and approvals remain in the App.
@MainActor
public final class BCRMockAgentHost {
    public let runtime: BCRPluginRuntime
    public static let instanceID = "agent.mock"
    private var observer: UUID?
    private let epoch: TimeInterval
    private var driver: Task<Void, Never>?
    private var lastPublished: [BCRAgentDomain.AgentSlot]?
    public var onUpdate: (@MainActor ([BCRAgentDomain.AgentSlot], [AgentSlotID: UInt8]) -> Void)?
    public var onError: (@MainActor (any Error) -> Void)?

    public init(clock: @escaping @MainActor () -> PluginTime = { ProcessInfo.processInfo.systemUptime },
                epoch: Date = .now, runtime: BCRPluginRuntime? = nil, started: Bool = true) throws
    {
        let owner = try runtime ?? BCRPluginRuntime(clock: clock)
        self.runtime = owner
        let now = owner.now
        self.epoch = epoch.timeIntervalSince1970 - now
        try owner.install([AgentRemoteBinding(
            instanceID: Self.instanceID,
            plugin: AgentPlugin(slotCount: 8, approvalPolicy: .localOrigins, at: now)
        )], start: started)
        lastPublished = try slots
        observer = owner.observe { [weak self] change in
            guard let self, change.instanceID == Self.instanceID else { return }
            do { self.publish(try change.update ?? .init(indicators: self.snapshot().indicators)) }
            catch { self.onError?(error) }
        }
    }

    deinit {
        driver?.cancel()
        let owner = runtime, token = observer
        Task { @MainActor in if let token { owner.removeObserver(token) } }
    }

    public var slots: [BCRAgentDomain.AgentSlot] {
        get throws {
            try plugin().slots.map { slot in
                BCRAgentDomain.AgentSlot(
                    id: AgentSlotID(slot.id), name: "Agent \(slot.id)",
                    state: slot.state,
                    progress: slot.progress, statusText: Self.statusText(slot.statusKey),
                    lastUpdated: Date(timeIntervalSince1970: epoch + slot.lastUpdated)
                )
            }
        }
    }

    public func plugin() throws -> AgentPlugin {
        try runtime.binding(Self.instanceID, as: AgentRemoteBinding.self).plugin
    }

    public func snapshot() throws -> PluginSnapshot { try plugin().snapshot() }

    public func invoke(_ slot: AgentSlotID, origin: InputOrigin) throws {
        _ = try runtime.handle(
            Self.instanceID,
            input: .invoke(AgentBindingTranslation.action(for: slot), origin: origin)
        )
    }

    public func interrupt(_ slot: AgentSlotID) throws {
        var binding = try runtime.binding(Self.instanceID, as: AgentRemoteBinding.self)
        let update = try binding.plugin.interrupt(slot.rawValue, at: runtime.now)
        try runtime.replace(binding, event: .init(code: "host.agent.interrupt"), update: update)
    }

    public func advance() throws { _ = try runtime.handle(Self.instanceID, input: .advance) }

    public func reset(started: Bool = true) throws {
        var binding = try runtime.binding(Self.instanceID, as: AgentRemoteBinding.self)
        binding.plugin = try AgentPlugin(slotCount: 8, approvalPolicy: .localOrigins, at: runtime.now)
        if started { _ = try binding.plugin.handle(.start, at: runtime.now) }
        lastPublished = nil
        try runtime.replace(binding, event: .init(code: "host.agent.reset"))
    }

    /// The MainActor host drives time even when no window is being redrawn.
    public func startDriving() {
        guard driver == nil else { return }
        driver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard let self else { return }
                do { try self.advance() } catch {
                    self.onError?(error)
                    self.stopDriving()
                    return
                }
            }
        }
    }

    public func stopDriving() { driver?.cancel(); driver = nil }

    private func publish(_ update: PluginUpdate) {
        do {
            // Replay every injected-time stage, including multiple updates at the same instant.
            // A delayed host tick must preserve the original observable state/LED order.
            if var projection = lastPublished {
                for event in update.events where event.code == "agent.updated" {
                    guard let id = event.fields["slot"]?.intValue,
                          let index = projection.firstIndex(where: { $0.id.rawValue == id }),
                          let rawState = event.fields["state"]?.stringValue,
                          let state = BCRAgentDomain.AgentRunState(rawValue: rawState),
                          let progress = event.fields["progress"]?.finiteNumber,
                          let key = event.fields["statusKey"]?.stringValue,
                          let time = event.fields["time"]?.finiteNumber
                    else { throw PluginError(code: .invalidParameter) }
                    projection[index].state = state
                    projection[index].progress = progress
                    projection[index].statusText = Self.statusText(key)
                    projection[index].lastUpdated = Date(timeIntervalSince1970: epoch + time)
                    lastPublished = projection
                    onUpdate?(
                        projection,
                        [projection[index].id: BCRIndicatorPresentation.value(for: state.indicatorSemantic)]
                    )
                }
            }
            let slots = try slots
            guard slots != lastPublished else { return }
            let feedback = Dictionary(uniqueKeysWithValues: slots.compactMap { slot -> (AgentSlotID, UInt8)? in
                guard let state = update.indicators[AgentPlugin.indicatorID(for: slot.id.rawValue)] else { return nil }
                return (slot.id, BCRIndicatorPresentation.value(for: state.semantic))
            })
            lastPublished = slots
            onUpdate?(slots, feedback)
        } catch { onError?(error) }
    }

    private static func statusText(_ key: String) -> String {
        let source: LocalizedMessage = switch key {
        case "agent.awaitingTask": "等待任务"
        case "agent.mock.queued": "Mock 任务已进入队列"
        case "agent.mock.analyze": "分析工作区"
        case "agent.mock.context": "读取项目上下文"
        case "agent.mock.plan": "规划变更"
        case "agent.mock.patch": "生成补丁"
        case "agent.mock.prepare": "准备执行受控操作"
        case "agent.mock.awaitingApproval": "等待批准：运行 Mock 验证"
        case "agent.mock.approved": "批准通过，继续验证"
        case "agent.mock.test": "运行单元测试"
        case "agent.mock.build": "检查构建结果"
        case "agent.mock.summarize": "整理变更摘要"
        case "agent.mock.completed": "Mock 任务已完成"
        case "agent.interrupted", "agent.stopped": "已由控制台中断"
        default: .init(stringLiteral: key)
        }
        return L10n.text(source)
    }
}
