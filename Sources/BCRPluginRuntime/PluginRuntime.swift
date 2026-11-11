import Foundation
import RemoteToolContracts
import SurfacePluginContracts

public struct PluginRuntimeChange: Sendable {
    public let instanceID: String
    public let operation: String
    public let update: PluginUpdate?
    public let isRemote: Bool
}

/// One canonical value registry, event epoch and trusted clock per host. No domain switches.
@MainActor
public final class BCRPluginRuntime {
    private var registry: RemoteRegistry
    private let clock: @MainActor () -> PluginTime
    private var observers: [UUID: @MainActor (PluginRuntimeChange) -> Void] = [:]
    private var pluginIDs: [String: PluginID] = [:]
    private var toolOwners: [String: Set<PluginID>] = [:]
    private var lastTrustedTime: PluginTime?
    public var now: PluginTime { clock() }
    public var tools: [RemoteToolDescriptor] { registry.tools }
    public var epoch: String { registry.journal.epoch }
    /// Used only for trusted stop/disconnect/fault transitions, never ordinary writes.
    public var safetyTimestamp: PluginTime { safetyTime() }
    public func isTrustedTime(_ value: PluginTime) -> Bool {
        value.isFinite && (lastTrustedTime.map({ value >= $0 }) ?? true)
    }

    public init(clock: @escaping @MainActor () -> PluginTime = { ProcessInfo.processInfo.systemUptime },
                epoch: String = UUID().uuidString) throws
    {
        self.clock = clock
        registry = try RemoteRegistry(epoch: epoch)
    }

    public func install(_ bindings: [any RemoteBinding], start: Bool = true) throws {
        guard !bindings.isEmpty else { return }
        var candidate = registry
        try candidate.install(bindings)
        let time = try checkedTime()
        if start {
            for binding in bindings { _ = try candidate.handle(instanceID: binding.instanceID, input: .start, at: time)
            }
        }
        registry = candidate
        lastTrustedTime = time
        for binding in bindings {
            pluginIDs[binding.instanceID] = binding.manifest.id
            for tool in binding.tools { toolOwners[tool.name, default: []].insert(binding.manifest.id) }
        }
        for binding in bindings { notify(.init(
            instanceID: binding.instanceID,
            operation: "host.install",
            update: nil,
            isRemote: false
        )) }
    }

    public func binding<P: RemoteBinding>(_ id: String, as type: P.Type) throws -> P {
        guard let result = registry.binding(id, as: type) else { throw PluginError(code: .unsupported) }
        return result
    }

    public func optionalBinding<P: RemoteBinding>(_ id: String, as type: P.Type) -> P? {
        registry.binding(id, as: type)
    }

    public func snapshot(_ id: String) -> PluginSnapshot? { registry.snapshot(instanceID: id) }
    public func pluginID(for id: String) -> PluginID? { pluginIDs[id] }
    public func owners(of tool: String) -> Set<PluginID> { toolOwners[tool] ?? [] }

    public func replace(_ binding: any RemoteBinding, event: PluginEvent, update: PluginUpdate? = nil) throws {
        let time = try checkedTime()
        try registry.replace(binding, at: time, event: event)
        lastTrustedTime = time
        notify(.init(instanceID: binding.instanceID, operation: event.code, update: update, isRemote: false))
    }

    /// Emergency closing/fault transitions only. Ordinary writes never clamp a bad clock.
    public func replaceForSafety(_ binding: any RemoteBinding, event: PluginEvent) throws {
        let time = safetyTime()
        try registry.replace(binding, at: time, event: event)
        lastTrustedTime = time
        notify(.init(instanceID: binding.instanceID, operation: event.code, update: nil, isRemote: false))
    }

    @discardableResult
    public func handle(_ id: String, input: PluginInput) throws -> PluginUpdate {
        let time: PluginTime
        if input == .stop { time = safetyTime() } else { time = try checkedTime() }
        let update = try registry.handle(instanceID: id, input: input, at: time)
        lastTrustedTime = time
        notify(.init(instanceID: id, operation: "host.input", update: update, isRemote: false))
        return update
    }

    public func call(_ name: String, arguments: JSONValue, controlToken: String? = nil,
                     permitsOutputEnable: Bool = false) throws -> JSONValue
    {
        let mutation = tools.first { $0.name == name }?.isMutation == true
        let time = mutation ? try checkedTime() : (now.isFinite ? now : lastTrustedTime ?? 0)
        let result = try registry.call(name, arguments: arguments, context: .init(
            time: time, controlToken: controlToken, permitsOutputEnable: permitsOutputEnable
        ))
        if mutation { lastTrustedTime = time }
        if mutation, let id = arguments.objectValue?["instance_id"]?.stringValue {
            notify(.init(instanceID: id, operation: name, update: nil, isRemote: true))
        }
        return result
    }

    public func observe(_ callback: @escaping @MainActor (PluginRuntimeChange) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func checkedTime() throws -> PluginTime {
        let value = now
        guard isTrustedTime(value) else {
            throw PluginError(code: .invalidTime)
        }
        return value
    }

    private func safetyTime() -> PluginTime {
        let value = now
        if value.isFinite, lastTrustedTime.map({ value >= $0 }) ?? true { return value }
        return lastTrustedTime ?? 0
    }

    private func notify(_ change: PluginRuntimeChange) {
        for callback in Array(observers.values) { callback(change) }
    }
}
