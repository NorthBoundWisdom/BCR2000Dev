import BCRSurfaceDomain
import Foundation
import CoreFoundation

/// A strict simulation-only subset of the existing SurfaceConfiguration format, never a user profile migration.
public enum SimulationSurfaceConfiguration {
    public struct ValidationError: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    // Shared with drift tests so the strict decoder and its assertions inspect the same policy.
    static let configurationFields: Set<String> = ["version", "name", "parameters", "assignments", "pages", "macros"]
    static let parameterFields: Set<String> = ["id", "name", "group", "unit", "minimum", "maximum", "defaultValue",
                                               "kind", "agentWritable", "externallyProtected", "step"]
    static let assignmentFields: Set<String> = [
        "control",
        "target",
        "buttonBehavior",
        "inverted",
        "encoderMode",
        "encoderStep"
    ]
    static let controlFields: Set<String> = ["section", "row", "index"]
    static let targetFields: Set<String> = ["parameter"]
    static let parameterTargetFields: Set<String> = ["_0"]

    public static func decode(_ data: Data) throws -> SurfaceConfiguration {
        func object(_ value: Any, keys: Set<String>, path: String) throws -> [String: Any] {
            guard let value = value as? [String: Any] else {
                throw ValidationError(reason: "\(path): expected an object")
            }
            let unknown = Set(value.keys).subtracting(keys).sorted()
            guard unknown.isEmpty else {
                throw ValidationError(reason: "\(path): unknown fields: \(unknown.joined(separator: ", "))")
            }
            return value
        }
        let root = try object(JSONSerialization.jsonObject(with: data),
                              keys: configurationFields,
                              path: "configuration")
        guard let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == SurfaceConfiguration.currentVersion,
              version.doubleValue == Double(SurfaceConfiguration.currentVersion)
        else {
            throw ValidationError(reason: "configuration.version: simulation requires SurfaceConfiguration version 7")
        }
        for key in ["pages", "macros"] {
            guard let rows = root[key] as? [Any], rows.isEmpty else {
                throw ValidationError(reason: "configuration.\(key): must be an empty array in simulation")
            }
        }
        guard let parameters = root["parameters"] as? [Any], let assignments = root["assignments"] as? [Any] else {
            throw ValidationError(reason: "configuration: parameters and assignments arrays are required")
        }
        for (index, parameter) in parameters.enumerated() {
            _ = try object(parameter, keys: parameterFields,
                           path: "parameters[\(index)]")
        }
        for (index, assignment) in assignments.enumerated() {
            let path = "assignments[\(index)]"
            let row = try object(
                assignment,
                keys: assignmentFields,
                path: path
            )
            _ = try object(row["control"] as Any, keys: controlFields, path: path + ".control")
            let target = try object(row["target"] as Any, keys: targetFields, path: path + ".target")
            _ = try object(target["parameter"] as Any, keys: parameterTargetFields, path: path + ".target.parameter")
        }
        let configuration: SurfaceConfiguration
        do { configuration = try JSONDecoder().decode(SurfaceConfiguration.self, from: data) }
        catch {
            throw ValidationError(reason: "Invalid simulation configuration: \(error.localizedDescription) (\(error))")
        }
        for parameter in configuration.parameters where !parameter.agentWritable || parameter.externallyProtected {
            throw ValidationError(
                reason: "Parameter \(parameter.id.rawValue): simulation parameters must be writable and unprotected"
            )
        }
        return configuration
    }
}
