import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

@MainActor
public enum SurfaceControlMCPModule {
    @discardableResult
    public static func install(on gateway: MCPApplicationGateway, instanceID: String,
                               permissions: BCRSurfaceControlAdapter.Permissions = .init(), eventCapacity: Int = 1024,
                               inputEventCapacity: Int? = nil,
                               principals: SurfaceControlPrincipals = .init(),
                               writeLimits: BCRSurfaceControlAdapter.WriteLimits? = nil,
                               monotonic: @escaping @MainActor ()
                                   -> Double = { ProcessInfo.processInfo.systemUptime },
                               holdScheduler: @escaping BCRSurfaceControlAdapter.HoldScheduler =
                                   BCRSurfaceControlAdapter.defaultHoldScheduler,
                               epochFactory: @escaping @MainActor () -> String = { UUID().uuidString }) throws
        -> BCRSurfaceControlAdapter?
    {
        guard let surface = gateway.surfaceSession else { return nil }
        let adapter = try BCRSurfaceControlAdapter(
            surface: surface, instanceID: instanceID, permissions: permissions,
            eventCapacity: eventCapacity, inputEventCapacity: inputEventCapacity, monotonic: monotonic,
            diagnostic: { [weak gateway] value in
                // Existing audit trail; the context itself is revoked by the adapter (fail closed).
                gateway?.record("surface_control.context", succeeded: false, detail: value.reason + ": " + value.code)
            },
            holdScheduler: holdScheduler, principals: principals, writeLimits: writeLimits, epochFactory: epochFactory
        )
        // Any request, including legacy and unrelated tools, first releases due leases: a flood of
        // queued requests then delays an expiry by at most one request, not by the whole queue.
        gateway.addCallPreflight { [weak adapter] in adapter?.processDueHoldsBeforeRequest() }
        let tools = SurfaceControlTools.descriptors.map { descriptor in JSONValue.object([
            "name": .string(descriptor.name),
            "description": .string("Optional simulation surface control " + ControlDiscovery.contractVersion),
            "inputSchema": descriptor.inputSchema, "outputSchema": descriptor.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(!descriptor.isMutation), "openWorldHint": .bool(false)])
        ]) } + retainedInputTools(source: .simulation, enabled: inputEventCapacity != nil)
        try gateway.registerModule(id: "surface.controls.1", tools: tools, rawResults: true, validatesInHandler: true,
                                   failureEncoder: { error in
                                       .object(["code": .string(BCRSurfaceControlAdapter.failureCode(error))])
                                   }) { [weak gateway] name, arguments in
            guard let gateway else { throw ControlContractError("not_initialized") }
            if name == SurfaceControlInputEventsTools.name {
                return try adapter.execute(
                    SurfaceControlInputEventsTools.parse(name, arguments: .object(arguments)),
                    gateway: gateway
                )
            }
            return try adapter.execute(SurfaceControlTools.parse(name, arguments: .object(arguments)), gateway: gateway)
        }
        return adapter
    }

    public static func installHardware(on gateway: MCPApplicationGateway, instanceID: String,
                                       permissions: BCRSurfaceControlAdapter.Permissions = .init(),
                                       inputEventCapacity: Int? = nil,
                                       principals: SurfaceControlPrincipals = .init(),
                                       monotonic: @escaping @MainActor ()
                                           -> Double = { ProcessInfo.processInfo.systemUptime },
                                       epochFactory: @escaping @MainActor () -> String = { UUID().uuidString }) throws
    {
        guard let surface = gateway.surfaceSession else { throw ControlContractError("unsupported_source") }
        let adapter = try BCRHardwareSurfaceControlAdapter(surface: surface, instanceID: instanceID,
                                                           permissions: permissions, principals: principals,
                                                           inputEventCapacity: inputEventCapacity, monotonic: monotonic,
                                                           epochFactory: epochFactory)
        let tools = SurfaceControlTools.descriptors(source: .hardware).map { descriptor in JSONValue.object([
            "name": .string(descriptor.name), "description": .string("Hardware surface control 1.4"),
            "inputSchema": descriptor.inputSchema, "outputSchema": descriptor.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(!descriptor.isMutation), "openWorldHint": .bool(false)])
        ]) } + retainedInputTools(source: .hardware, enabled: inputEventCapacity != nil)
        try gateway.registerModule(id: "surface.controls.1", tools: tools, rawResults: true, validatesInHandler: true,
                                   failureEncoder: {
                                       .object(["code": .string(BCRSurfaceControlAdapter.failureCode($0))])
                                   }) { [weak gateway] name, arguments in
            guard let gateway else { throw ControlContractError("not_initialized") }
            if name == SurfaceControlInputEventsTools.name {
                return try adapter.execute(
                    SurfaceControlInputEventsTools.parse(name, arguments: .object(arguments)),
                    gateway: gateway
                )
            }
            return try adapter.execute(SurfaceControlTools.parse(name, arguments: .object(arguments)), gateway: gateway)
        }
    }

    private static func retainedInputTools(source: PluginSource, enabled: Bool) -> [JSONValue] {
        guard enabled else { return [] }
        return SurfaceControlInputEventsTools.descriptors(source: source).map { descriptor in .object([
            "name": .string(descriptor.name), "description": .string("Independent retained surface input events 1.5"),
            "inputSchema": descriptor.inputSchema, "outputSchema": descriptor.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)])
        ]) }
    }

    /// An explicitly selected, ordinary-input fixture. No business operation is implemented here.
    public static func simulationConfiguration() -> SurfaceConfiguration {
        let commands = ["arm", "start", "pause", "cancel", "progress"]
        // Momentary: on only while pressed, so an expired 1.1 lease (release) returns it to 0.
        let parameters = commands.map { name in ParameterDefinition(id: ParameterID("simulation." + name),
                                                                    name: name, minimum: 0, maximum: 127, step: 1) } + [
            ParameterDefinition(
                id: "simulation.state",
                name: "State",
                minimum: 0,
                maximum: 1,
                kind: .toggle
            ),
            ParameterDefinition(
                id: "simulation.link",
                name: "Link",
                minimum: 0,
                maximum: 1,
                kind: .toggle
            ),
            ParameterDefinition(
                id: "simulation.hold",
                name: "Hold",
                minimum: 0,
                maximum: 1,
                kind: .toggle
            )
        ]
        let assignments = commands.enumerated().map { index, name in
            ControlAssignment(
                control: .pushEncoder(group: 1, index + 1),
                target: .parameter(ParameterID("simulation." + name))
            )
        } + [ControlAssignment(control: .button(row: 1, 1), target: .parameter("simulation.state")),
             ControlAssignment(control: .button(row: 1, 2), target: .parameter("simulation.link")),
             ControlAssignment(control: .button(row: 1, 3), target: .parameter("simulation.hold"),
                               buttonBehavior: .momentary)]
        return SurfaceConfiguration(
            name: "Simulation control trial 1.1",
            parameters: parameters,
            assignments: assignments
        )
    }
}
