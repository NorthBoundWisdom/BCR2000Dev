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
                               monotonic: @escaping @MainActor ()
                                   -> Double = { ProcessInfo.processInfo.systemUptime },
                               holdScheduler: @escaping BCRSurfaceControlAdapter.HoldScheduler =
                                   BCRSurfaceControlAdapter.defaultHoldScheduler) throws
        -> BCRSurfaceControlAdapter?
    {
        guard let surface = gateway.surfaceSession else { return nil }
        let adapter = try BCRSurfaceControlAdapter(
            surface: surface, instanceID: instanceID, permissions: permissions,
            eventCapacity: eventCapacity, monotonic: monotonic,
            diagnostic: { [weak gateway] value in
                // Existing audit trail; the context itself is revoked by the adapter (fail closed).
                gateway?.record("surface_control.context", succeeded: false, detail: value.reason + ": " + value.code)
            },
            holdScheduler: holdScheduler
        )
        let tools = SurfaceControlTools.descriptors.map { descriptor in JSONValue.object([
            "name": .string(descriptor.name),
            "description": .string("Optional simulation surface control " + ControlDiscovery.contractVersion),
            "inputSchema": descriptor.inputSchema, "outputSchema": descriptor.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(!descriptor.isMutation), "openWorldHint": .bool(false)])
        ]) }
        try gateway.registerModule(id: "surface.controls.1", tools: tools, rawResults: true, validatesInHandler: true,
                                   failureEncoder: { error in
                                       .object(["code": .string(BCRSurfaceControlAdapter.failureCode(error))])
                                   }) { [weak gateway] name, arguments in
            guard let gateway else { throw ControlContractError("not_initialized") }
            return try adapter.execute(SurfaceControlTools.parse(name, arguments: .object(arguments)), gateway: gateway)
        }
        return adapter
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
