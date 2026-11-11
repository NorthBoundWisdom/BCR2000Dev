import BCRFoundation
import Foundation

/// A value owned separately by each device. No global control, model or clock state.
public struct DeviceControl: Sendable {
    public private(set) var generation = UUID().uuidString
    public private(set) var revision: UInt64 = 0
    public private(set) var time: Double = 0
    public private(set) var initialized = false
    public private(set) var enabled = false
    public private(set) var fault: String?
    public private(set) var lastCommandSequence = 0
    public private(set) var owner: String?
    public private(set) var expires: Double?
    private var token: String?

    public init() {}
    public mutating func changed() { revision &+= 1 }

    public func checkGeneration(_ expected: String) throws {
        try ProviderValidation.require(expected == generation, "stale_generation", "The device generation changed")
    }

    public mutating func initialize(expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        try ProviderValidation.require(fault == nil, "faulted", "Clear the simulated fault before initialization")
        generation = UUID().uuidString; initialized = true; enabled = false
        owner = nil; expires = nil; token = nil; lastCommandSequence = 0; changed()
    }

    public mutating func acquire(expectedGeneration: String, owner: String, ttl: Double) throws -> DeviceControlGrant {
        try checkGeneration(expectedGeneration)
        try ProviderValidation.require(initialized, "not_initialized", "Initialize the device first")
        try ProviderValidation.require(fault == nil, "faulted", "The device has a fault")
        try ProviderValidation.require(
            !owner.isEmpty && owner.utf8.count <= 128 && !owner.unicodeScalars.contains(where: { $0.value < 32 }),
            "invalid_argument",
            "Invalid control owner"
        )
        try ProviderValidation.require(
            ttl.isFinite && ttl >= 0.1 && ttl <= 5,
            "invalid_argument",
            "Control TTL must be within 0.1...5 seconds"
        )
        try ProviderValidation.require(token == nil, "busy", "Control is already owned")
        let value = UUID().uuidString
        self.owner = owner; expires = time + ttl; token = value; lastCommandSequence = 0; changed()
        return DeviceControlGrant(generation: generation, token: value, expires: time + ttl)
    }

    public func validate(_ proof: DeviceCommandProof) throws {
        try checkGeneration(proof.generation)
        try ProviderValidation.require(initialized, "not_initialized", "Initialize the device first")
        try ProviderValidation.require(fault == nil, "faulted", "The device has a fault")
        try ProviderValidation.require(
            token != nil && expires.map { $0 > time } == true,
            "control_expired",
            "Control is absent or expired"
        )
        try ProviderValidation.require(
            proof.token == token,
            "invalid_control",
            "Control token does not own this device"
        )
        try ProviderValidation.require(
            proof.sequence > lastCommandSequence,
            "stale_sequence",
            "Command sequence must strictly increase"
        )
    }

    public mutating func accept(_ proof: DeviceCommandProof) throws {
        try validate(proof); lastCommandSequence = proof.sequence; changed()
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws { try accept(proof); enabled = true; changed() }
    public mutating func disable() { enabled = false; changed() }
    public mutating func revoke() {
        enabled = false; owner = nil; expires = nil; token = nil
        generation = UUID().uuidString; lastCommandSequence = 0; changed()
    }

    public mutating func release(_ proof: DeviceCommandProof) throws {
        try accept(proof); owner = nil; expires = nil; token = nil; enabled = false; changed()
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws {
        try ProviderValidation.require(
            ttl.isFinite && ttl >= 0.1 && ttl <= 5,
            "invalid_argument",
            "Invalid control TTL"
        )
        try accept(proof); expires = time + ttl; changed()
    }

    /// The caller splits integration at the expiry boundary before revoking control.
    @discardableResult public mutating func advance(_ dt: Double) throws -> Bool {
        try ProviderValidation.require(
            dt.isFinite && dt > 0 && dt <= 0.1,
            "invalid_argument",
            "Advance must be within (0, 0.1] seconds"
        )
        let next = time + dt
        try ProviderValidation.require(
            next.isFinite && next > time,
            "invalid_argument",
            "Time step is not representable at this simulation time"
        )
        time = next
        let expired = expireIfDue()
        changed(); return expired
    }

    @discardableResult public mutating func expireIfDue() -> Bool {
        guard let expires, time >= expires else { return false }
        owner = nil; self.expires = nil; token = nil; enabled = false; changed(); return true
    }

    public mutating func injectFault(_ code: String, expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        try ProviderValidation.require(
            !code.isEmpty && code.utf8.count <= 64 && code.unicodeScalars
                .allSatisfy {
                    $0.isASCII && ($0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) || $0 == "_")
                },
            "invalid_argument",
            "Invalid simulated fault code"
        )
        fault = code; enabled = false; owner = nil; expires = nil; token = nil
        generation = UUID().uuidString; lastCommandSequence = 0; changed()
    }

    public mutating func reset(expectedGeneration: String) throws {
        try checkGeneration(expectedGeneration)
        generation = UUID().uuidString; initialized = false; enabled = false; fault = nil
        owner = nil; expires = nil; token = nil; lastCommandSequence = 0; changed()
    }

    public func metadata(device: String, model: String, state: String, frame: String) -> DeviceMetadata {
        DeviceMetadata(device: device, model: model, generation: generation, sequence: revision, time: time,
                       state: state, initialized: initialized, enabled: enabled, fault: fault,
                       owner: owner, expires: expires, commandSequence: lastCommandSequence, frame: frame)
    }
}
