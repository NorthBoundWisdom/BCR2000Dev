import BCRFoundation
import BCRSurfaceDomain
import BCRExamples
import Foundation

/// The official profile decoder preserves legacy example protection before migration.
public enum SurfaceConfigurationCodec {
    /// Only historical profile objects receive the historical policy; v7 is entirely explicit.
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        func migrate(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(migrate) }
            guard var object = value as? [String: Any] else { return value }
            if let version = object["version"] as? Int, (1 ... 6).contains(version),
               let definitions = object["parameters"] as? [[String: Any]], object["assignments"] != nil
            {
                object["parameters"] = definitions.map { definition in
                    var result = definition
                    let legacyProtected = (definition["id"] as? String)
                        .map { LegacyExampleProtection.parameterIDs.contains(ParameterID($0)) } ?? false
                    result["externallyProtected"] = legacyProtected ||
                        (definition["externallyProtected"] as? Bool ?? false)
                    if result["agentWritable"] == nil { result["agentWritable"] = !legacyProtected }
                    return result
                }
            }
            return object.mapValues(migrate)
        }
        let normalized = try JSONSerialization.data(
            withJSONObject: migrate(object),
            options: [.fragmentsAllowed, .sortedKeys]
        )
        return try JSONDecoder().decode(type, from: normalized)
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[ParameterDecodingPolicy.legacyProtectedIDs] = LegacyExampleProtection.parameterIDs
        return decoder
    }

    public static func decode(_ data: Data) throws -> SurfaceConfiguration {
        try decode(SurfaceConfiguration.self, from: data)
    }
}
