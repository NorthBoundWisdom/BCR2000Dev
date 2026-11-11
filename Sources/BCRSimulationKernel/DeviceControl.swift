import BCRFoundation
import Foundation
import SimulationContracts

/// Source-compatible host facade; shared DeviceControl is the sole control state.
public struct DeviceControl: Sendable {
    public var shared: SimulationContracts.DeviceControl
    public init() { shared = .init(namespace: UUID().uuidString) }
    public init(shared: SimulationContracts.DeviceControl) { self.shared = shared }
    public var generation: String { shared.generation }
    public var revision: UInt64 { shared.revision }
    public var time: Double { shared.time }
    public var initialized: Bool { shared.initialized }
    public var enabled: Bool { shared.enabled }
    public var fault: String? { shared.fault }
    public var lastCommandSequence: Int { shared.lastCommandSequence }
    public var owner: String? { shared.owner }
    public var expires: Double? { shared.expires }
    public mutating func changed() { shared.changed() }
    public func checkGeneration(_ expected: String) throws {
        try withLegacySimulationErrors { try shared.checkGeneration(expected) }
    }

    public mutating func initialize(expectedGeneration: String) throws {
        try withLegacySimulationErrors { try shared.initialize(expectedGeneration: expectedGeneration) }
    }

    public mutating func acquire(expectedGeneration: String, owner: String,
                                 ttl: Double) throws -> DeviceControlGrant
    { try withLegacySimulationErrors { try shared.acquire(
        expectedGeneration: expectedGeneration,
        owner: owner,
        ttl: ttl,
        controlToken: UUID().uuidString
    ) } }
    public func validate(_ proof: DeviceCommandProof) throws {
        try withLegacySimulationErrors { try shared.validate(proof) }
    }

    public mutating func accept(_ proof: DeviceCommandProof) throws {
        try withLegacySimulationErrors { try shared.accept(proof) }
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws {
        try withLegacySimulationErrors { try shared.enable(proof) }
    }

    public mutating func disable() { shared.disable() }
    public mutating func revoke() { shared.revoke() }
    public mutating func release(_ proof: DeviceCommandProof) throws {
        try withLegacySimulationErrors { try shared.release(proof) }
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws {
        try withLegacySimulationErrors { try shared.renew(
            proof,
            ttl: ttl
        ) }
    }

    @discardableResult public mutating func advance(_ dt: Double) throws
        -> Bool { try withLegacySimulationErrors { try shared.advance(dt) } }
    @discardableResult public mutating func expireIfDue() -> Bool { shared.expireIfDue() }
    public mutating func injectFault(_ code: String, expectedGeneration: String) throws {
        try withLegacySimulationErrors { try shared.injectFault(
            code,
            expectedGeneration: expectedGeneration
        ) }
    }

    public mutating func reset(expectedGeneration: String) throws {
        try withLegacySimulationErrors { try shared.reset(expectedGeneration: expectedGeneration) }
    }

    public func metadata(device: String, model: String, state: String,
                         frame: String) -> DeviceMetadata
    { shared.metadata(
        device: device,
        model: model,
        state: state,
        frame: frame
    ) }
}
