import BCRFoundation
import BCRPluginRuntime
import Foundation
import RemoteToolContracts
import SurfacePluginContracts

/// Transport glue only: shared schemas/parsing/results remain owned by each binding.
@MainActor
public enum SharedPluginMCPModule {
    public typealias WritePolicy = @MainActor (MCPPermissions, String) -> Bool
    public static func install(on service: MCPApplicationGateway, runtime: BCRPluginRuntime,
                               policies: [PluginID: WritePolicy]) throws
    {
        var registered: Set<String> = []
        var generation = 0
        try synchronize(service: service, runtime: runtime, policies: policies,
                        registered: &registered, generation: &generation)
        let subscription = runtime.observe { [weak service, weak runtime] change in
            guard change.operation == "host.install", let service, let runtime else { return }
            do { try synchronize(service: service, runtime: runtime, policies: policies,
                                 registered: &registered, generation: &generation) } catch
            { service.record(
                "surface.registration",
                succeeded: false,
                detail: error.localizedDescription
            ) }
        }
        service.retainModuleCleanup { [weak runtime] in runtime?.removeObserver(subscription) }
    }

    private static func synchronize(service: MCPApplicationGateway, runtime: BCRPluginRuntime,
                                    policies: [PluginID: WritePolicy], registered: inout Set<String>,
                                    generation: inout Int) throws
    {
        let tools = runtime.tools.filter { !registered.contains($0.name) }
        guard !tools.isEmpty else { return }
        let definitions = tools.map { tool in JSONValue.object([
            "name": .string(tool.name), "description": .string("Shared surface plugin: " + tool.name),
            "inputSchema": tool.inputSchema, "outputSchema": tool.outputSchema,
            "annotations": .object(["readOnlyHint": .bool(!tool.isMutation), "openWorldHint": .bool(false)])
        ]) }
        let descriptors = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        try service.registerModule(id: "surface.plugins.\(generation)", tools: definitions,
                                   rawResults: true, validatesInHandler: true, failureEncoder: { error in
                                       let failure = error is MCPToolFailure ? RemoteFailure(code: "invalidParameter") :
                                           RemoteFailure.from(error)
                                       // RemoteFailure contains only stable codes/fields, never transport credentials.
                                       return .object([
                                           "code": .string(failure.code),
                                           "fields": .object(failure.fields)
                                       ])
                                   }) { [weak service, weak runtime] name, args in
            guard let service, let runtime else { throw RemoteFailure(code: "notInitialized") }
            if descriptors[name]?.isMutation == true {
                let owners = runtime.owners(of: name)
                guard let instance = args["instance_id"]?.stringValue,
                      let plugin = runtime.pluginID(for: instance), owners.contains(plugin)
                else {
                    throw RemoteFailure(code: "unsupported")
                }
                guard policies[plugin]?(service.permissions, name) == true else {
                    throw RemoteFailure(code: "permissionDenied")
                }
                do { try service.consumeWrites(1) }
                catch { throw RemoteFailure(code: "permissionDenied", fields: ["reason": .string("writeRate")]) }
            }
            return try runtime.call(name, arguments: .object(args), controlToken: UUID().uuidString,
                                    permitsOutputEnable: false)
        }
        registered.formUnion(tools.map(\.name)); generation += 1
    }
}
