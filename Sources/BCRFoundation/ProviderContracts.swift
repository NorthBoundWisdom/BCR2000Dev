import Foundation
import SimulationContracts
@_exported import enum SurfacePluginContracts.PluginSource

public typealias ProviderSource = SimulationContracts.ProviderSource

public struct ProviderDomainError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

// The shared simulation contracts preserve the published Provider 1.0 wire fields.
public typealias DeviceCommandProof = SimulationContracts.DeviceCommandProof
public typealias DeviceControlGrant = SimulationContracts.DeviceControlGrant
public typealias DeviceMetadata = SimulationContracts.DeviceMetadata

public enum ProviderValidation {
    public static func require(_ condition: Bool, _ code: String = "invalid_argument", _ message: String) throws {
        if !condition { throw ProviderDomainError(code, message) }
    }

    public static func finite(_ values: [Double]) -> Bool { values.allSatisfy(\.isFinite) }
}
