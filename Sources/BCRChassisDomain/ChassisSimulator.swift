import BCRFoundation
import BCRSimulationKernel
import Foundation
import struct ChassisPlugin.ChassisPlugin

/// Legacy API over one shared plugin value; no local integration or control algorithm.
public struct ChassisSimulator: Sendable {
    public var plugin: ChassisPlugin
    public var deviceID: String { plugin.simulator.deviceID }
    public var model: AckermannModel {
        // DTO compatibility retains mutable/immutable fields without a second model algorithm.
        let value = plugin.simulator.model
        return AckermannModel(
            id: value.id,
            wheelbase_m: value.wheelbase_m,
            track_m: value.track_m,
            wheel_radius_m: value.wheel_radius_m,
            maximum_speed_m_s: value.maximum_speed_m_s,
            maximum_acceleration_m_s2: value.maximum_acceleration_m_s2,
            maximum_steering_rad: value.maximum_steering_rad,
            maximum_steering_rate_rad_s: value.maximum_steering_rate_rad_s
        )
    }

    public var control: DeviceControl { .init(shared: plugin.simulator.control) }
    public var trace: [ChassisTraceSample] { plugin.simulator.trace }
    public init(deviceID: String = "chassis.reference", model: AckermannModel = .reference) throws {
        plugin = try withLegacySimulationErrors {
            try ChassisPlugin(deviceID: deviceID, model: model.shared, instanceID: UUID().uuidString)
        }
        _ = try plugin.handle(.start, at: 0)
    }

    public init(plugin: ChassisPlugin) { self.plugin = plugin }
    public mutating func initialize(_ pose: [Double], generation: String) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.initialize(
            pose,
            generation: generation
        ) }
    }

    public mutating func acquire(generation: String, owner: String, ttl: Double) throws -> DeviceControlGrant {
        try requireWrites()
        return try withLegacySimulationErrors {
            try plugin.simulator.acquire(generation: generation, owner: owner, ttl: ttl,
                                         controlToken: UUID().uuidString)
        }
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.enable(proof) }
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.renew(
            proof,
            ttl: ttl
        ) }
    }

    public mutating func release(_ proof: DeviceCommandProof) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.release(proof) }
    }

    public mutating func stop(_ proof: DeviceCommandProof, disable: Bool = false) throws {
        try withLegacySimulationErrors { try plugin.simulator.stop(
            proof,
            disable: disable
        ) }
    }

    public mutating func advance(_ dt: Double) throws {
        try withLegacySimulationErrors { try plugin.advanceSimulation(dt) }
    }

    public mutating func fault(_ code: String, generation: String) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.fault(
            code,
            generation: generation
        ) }
    }

    public mutating func reset(generation: String) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.reset(generation: generation) }
    }

    public mutating func drive(_ proof: DeviceCommandProof, speed: Double, steering: Double, validFor: Double) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.drive(
            proof,
            speed: speed,
            steering: steering,
            validFor: validFor
        ) }
    }

    public mutating func revokeControl() { plugin.simulator.revokeControl() }
    public func snapshot() -> ChassisSnapshot { plugin.simulator.snapshot() }
    private func requireWrites() throws {
        guard plugin.acceptsWrites else { throw ProviderDomainError("stopped", "The plugin is stopped") }
    }
}
