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
                                   -> Double = { ProcessInfo.processInfo.systemUptime }) throws
        -> BCRSurfaceControlAdapter?
    {
        guard let surface = gateway.surfaceSession else { return nil }
        let adapter = try BCRSurfaceControlAdapter(surface: surface, instanceID: instanceID, permissions: permissions,
                                                   eventCapacity: eventCapacity, monotonic: monotonic)
        let tools = SurfaceControlTools.descriptors.map { descriptor in JSONValue.object([
            "name": .string(descriptor.name), "description": .string("Optional simulation surface control 1.0"),
            "inputSchema": descriptor.inputSchema, "outputSchema": descriptor.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(!descriptor.isMutation), "openWorldHint": .bool(false)])
        ]) }
        try gateway.registerModule(id: "surface.controls.1", tools: tools, rawResults: true, validatesInHandler: true,
                                   failureEncoder: { error in
                                       .object(["code": .string((error as? ControlContractError)?
                                               .code ?? "invalid_argument")])
                                   }) { [weak gateway] name, arguments in
            guard let gateway else { throw ControlContractError("not_initialized") }
            return try adapter.execute(SurfaceControlTools.parse(name, arguments: .object(arguments)), gateway: gateway)
        }
        return adapter
    }

    /// An explicitly selected, ordinary-input fixture. No business operation is implemented here.
    public static func simulationConfiguration() -> SurfaceConfiguration {
        let commands = ["arm", "start", "pause", "cancel", "progress"]
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
            )
        ]
        let assignments = commands.enumerated().map { index, name in
            ControlAssignment(
                control: .pushEncoder(group: 1, index + 1),
                target: .parameter(ParameterID("simulation." + name))
            )
        } + [ControlAssignment(control: .button(row: 1, 1), target: .parameter("simulation.state")),
             ControlAssignment(control: .button(row: 1, 2), target: .parameter("simulation.link"))]
        return SurfaceConfiguration(
            name: "Simulation control trial 1.0",
            parameters: parameters,
            assignments: assignments
        )
    }
}
