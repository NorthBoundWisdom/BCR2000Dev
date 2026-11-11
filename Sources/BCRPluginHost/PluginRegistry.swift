import BCRFoundation
import Foundation
import SurfacePluginContracts

public enum PluginRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case unsupportedContract(String)
    case unknownPlugin(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(id): L10n.text("插件标识无效：\(id)")
        case let .duplicateIdentifier(id): L10n.text("插件标识重复：\(id)")
        case let .unsupportedContract(version): L10n.text("不支持的插件合同版本：\(version)")
        case let .unknownPlugin(id): L10n.text("未知插件：\(id)")
        }
    }
}

/// Value registry owned by a host actor. Validation and startup commit together.
/// The registry has no knowledge of individual plugin types or physical controls.
public struct PluginRegistry: Sendable {
    private var plugins: [PluginID: any ControlPlugin] = [:]
    public var pluginIDs: [PluginID] { plugins.keys.sorted { $0.rawValue < $1.rawValue } }

    public init() {}

    public mutating func register(_ additions: [any ControlPlugin], at time: PluginTime) throws {
        var candidate = plugins
        var names = Set(plugins.values.flatMap { plugin in
            plugin.surface.parameters.map(\.id.rawValue) + plugin.surface.actions.map(\.id.rawValue)
                + plugin.surface.indicators.map(\.id.rawValue)
        })
        for plugin in additions {
            let manifest = plugin.manifest
            guard manifest.contractVersion == "1.0" else {
                throw PluginRegistrationError.unsupportedContract(manifest.contractVersion)
            }
            try Self.validateName(manifest.id.rawValue)
            guard candidate[manifest.id] == nil else {
                throw PluginRegistrationError.duplicateIdentifier(manifest.id.rawValue)
            }
            let surface = plugin.surface
            let ids = surface.parameters.map(\.id.rawValue) + surface.actions.map(\.id.rawValue)
                + surface.indicators.map(\.id.rawValue)
            for id in ids {
                try Self.validateName(id)
                guard id.hasPrefix(manifest.id.rawValue + ".") else {
                    throw PluginRegistrationError.invalidIdentifier(id)
                }
                guard names.insert(id).inserted else { throw PluginRegistrationError.duplicateIdentifier(id) }
            }
            for action in surface.actions {
                if action.nameKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw PluginRegistrationError.invalidIdentifier(action.id.rawValue)
                }
                if let count = action.indexCount, count < 1 {
                    throw PluginRegistrationError.invalidIdentifier(action.id.rawValue)
                }
            }
            for indicator in surface.indicators where indicator.nameKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw PluginRegistrationError.invalidIdentifier(indicator.id.rawValue)
            }
            candidate[manifest.id] = plugin
        }
        // No plugin becomes callable if any declaration or any startup fails.
        for plugin in additions {
            var started = plugin
            _ = try started.handle(.start, at: time)
            candidate[plugin.manifest.id] = started
        }
        plugins = candidate
    }

    public func plugin<P: ControlPlugin>(_ id: PluginID, as type: P.Type) throws -> P {
        guard let value = plugins[id] as? P else { throw PluginRegistrationError.unknownPlugin(id.rawValue) }
        return value
    }

    public func snapshot(_ id: PluginID) throws -> PluginSnapshot {
        guard let plugin = plugins[id] else { throw PluginRegistrationError.unknownPlugin(id.rawValue) }
        return plugin.snapshot()
    }

    @discardableResult
    public mutating func handle(_ input: PluginInput, for id: PluginID, at time: PluginTime) throws -> PluginUpdate {
        guard var plugin = plugins[id] else { throw PluginRegistrationError.unknownPlugin(id.rawValue) }
        let update = try plugin.handle(input, at: time)
        plugins[id] = plugin
        return update
    }

    @discardableResult
    public mutating func update<P: ControlPlugin>(
        _ id: PluginID, as type: P.Type, _ operation: (inout P) throws -> PluginUpdate
    ) throws -> PluginUpdate {
        var plugin = try plugin(id, as: type)
        let update = try operation(&plugin)
        plugins[id] = plugin
        return update
    }

    private static func validateName(_ name: String) throws {
        guard name.range(of: "^[a-z][a-z0-9_-]*(\\.[a-z0-9_-]+)*$", options: .regularExpression) != nil else {
            throw PluginRegistrationError.invalidIdentifier(name)
        }
    }
}
