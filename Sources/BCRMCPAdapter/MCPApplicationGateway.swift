import BCRSurfaceDomain
import BCRFoundation
import Foundation
import enum SurfacePluginContracts.JSONValue

/// Client-neutral tool execution. Transport credentials never enter this service or its log.
@MainActor
public final class MCPApplicationGateway {
    public let surfaceSession: SurfaceSession?
    /// Compatibility port; only console handlers registered with a surface may use it.
    public var session: SurfaceSession { surfaceSession! }
    public var permissions: MCPPermissions {
        didSet {
            guard permissions != oldValue else { return }
            for observer in Array(permissionObservers.values) { observer(oldValue, permissions) }
        }
    }

    private var permissionObservers: [UUID: @MainActor (MCPPermissions, MCPPermissions) -> Void] = [:]
    public func observePermissions(_ observer: @escaping @MainActor (MCPPermissions, MCPPermissions) -> Void) -> UUID {
        let id = UUID(); permissionObservers[id] = observer; return id
    }

    public func removePermissionObserver(_ id: UUID) { permissionObservers[id] = nil }
    public private(set) var audit: [MCPAuditEntry] = []
    public var onChange: (@MainActor () -> Void)?
    public var onReadAgents: (@MainActor () throws -> JSONValue)?
    public var onAgentAction: (@MainActor (String, AgentSlotID?) throws -> Void)?
    public var onSelectSource: (@MainActor (DeviceSource) throws -> Void)?
    public var onRestrictConfigurationWrite: (@MainActor () throws -> Void)?
    private let now: @MainActor () -> Date
    private var rateWindow: Date?
    private var usedWrites = 0
    private var definitions: [String: JSONValue] = [:]
    private var toolOrder: [String] = []
    private var moduleIDs: Set<String> = []
    private var handlers: [String: @MainActor ([String: JSONValue]) throws -> JSONValue] = [:]
    private var rawTools: Set<String> = []
    private var handlerValidation: Set<String> = []
    private var failureEncoders: [String: @MainActor (any Error) -> JSONValue] = [:]
    private var moduleCleanup: [@MainActor @Sendable () -> Void] = []
    func retainModuleCleanup(_ cleanup: @escaping @MainActor @Sendable () -> Void) { moduleCleanup.append(cleanup) }
    deinit {
        let cleanup = moduleCleanup
        Task { @MainActor in for action in cleanup { action() } }
    }

    public var toolDefinitions: [JSONValue] { toolOrder.compactMap { definitions[$0] } }

    public init(session: SurfaceSession? = nil, permissions: MCPPermissions = MCPPermissions(),
                now: @escaping @MainActor () -> Date = { .now }, includeAgent: Bool = true)
    {
        self.surfaceSession = session
        self.permissions = permissions
        self.now = now
        for definition in MCPToolCatalog.tools {
            guard let name = definition.objectValue?["name"]?.stringValue else { continue }
            if AgentMCPModule.names.contains(name) { if !includeAgent { continue } }
            else if session == nil { continue }
            definitions[name] = definition; toolOrder.append(name)
        }
    }

    /// Host-only registration: all definitions validate before any registry mutation.
    public func registerModule(
        id: String,
        tools: [JSONValue],
        rawResults: Bool = false,
        validatesInHandler: Bool = false,
        failureEncoder: (@MainActor (any Error) -> JSONValue)? = nil,
        handler: @escaping @MainActor (String, [String: JSONValue]) throws -> JSONValue
    ) throws {
        guard !moduleIDs.contains(id),
              !tools.isEmpty else { throw MCPToolFailure("Duplicate or empty provider module") }
        var names = Set<String>()
        for tool in tools {
            guard let object = tool.objectValue, let name = object["name"]?.stringValue,
                  object["inputSchema"]?.objectValue != nil, definitions[name] == nil, names.insert(name).inserted
            else { throw MCPToolFailure("Invalid or duplicate provider tool") }
        }
        moduleIDs.insert(id)
        for tool in tools {
            let name = tool.objectValue!["name"]!.stringValue!
            definitions[name] = tool; toolOrder.append(name)
            handlers[name] = { args in try handler(name, args) }
            if rawResults { rawTools.insert(name) }
            if validatesInHandler { handlerValidation.insert(name) }
            failureEncoders[name] = failureEncoder
        }
    }

    public func record(_ method: String, succeeded: Bool, detail: String) {
        audit.append(MCPAuditEntry(time: now(), method: method, succeeded: succeeded, detail: detail))
        if audit.count > 100 { audit.removeFirst(audit.count - 100) }
        onChange?()
    }

    public func call(_ name: String, arguments: JSONValue = .object([:])) -> MCPToolResult {
        do {
            guard let definition = definitions[name] else { throw ProviderDomainError(
                "unsupported",
                "The capability is not registered"
            ) }
            guard let args = arguments.objectValue else { throw MCPToolFailure(L10n.text("arguments 必须是对象")) }
            if name == "start_agent" || name == "interrupt_agent" { _ = try agentSlot(args) }
            if !handlerValidation.contains(name) {
                try MCPInputValidation.validate(.object(args), schema: definition.objectValue!["inputSchema"]!)
            }
            let result: JSONValue
            if let handler = handlers[name] {
                if !handlerValidation.contains(name), definition.objectValue?["annotations"]?
                    .objectValue?["readOnlyHint"] != .bool(true) { try consumeWrites(1) }
                result = try handler(args)
            } else if AgentMCPModule.names.contains(name) { result = try executeAgent(name, args) }
            else { result = try executeSurface(name, args) }
            record(name, succeeded: true, detail: L10n.text("完成"))
            return MCPToolResult(value: result, isError: false, rawObject: rawTools.contains(name))
        } catch {
            // Error messages only include domain validation details, never HTTP headers or tokens.
            record(name, succeeded: false, detail: error.localizedDescription)
            if let encode = failureEncoders[name] {
                return MCPToolResult(value: encode(error), isError: true, rawObject: rawTools.contains(name))
            }
            if let error = error as? ProviderDomainError {
                return MCPToolResult(
                    value: .object(["error": .object([
                        "code": .string(error.code),
                        "message": .string(error.message)
                    ])]),
                    isError: true
                )
            }
            if handlers[name] != nil {
                return MCPToolResult(
                    value: .object(["error": .object([
                        "code": .string("invalid_argument"),
                        "message": .string(error.localizedDescription)
                    ])]),
                    isError: true
                )
            }
            return MCPToolResult(value: .object(["error": .string(error.localizedDescription)]), isError: true)
        }
    }

    public func consumeWrites(_ count: Int) throws {
        let time = now()
        if rateWindow == nil || time < rateWindow! || time.timeIntervalSince(rateWindow!) >= 1 {
            rateWindow = time
            usedWrites = 0
        }
        guard permissions.writesPerSecond > 0,
              count <= permissions.writesPerSecond - usedWrites else { throw MCPToolFailure(L10n.text("写入超过每秒限额")) }
        usedWrites += count
    }

    func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue,
              value.utf8.count <= 1_024 else { throw MCPToolFailure(L10n.text("\(key) 必须是长度不超过 1024 的字符串")) }
        return value
    }

    func number(_ args: [String: JSONValue], _ key: String) throws -> Double {
        guard let value = args[key]?.finiteNumber else { throw MCPToolFailure(L10n.text("\(key) 必须是有限数值")) }
        return value
    }
}
