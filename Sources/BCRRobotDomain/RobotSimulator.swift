import BCRFoundation
import BCRSimulationKernel
import Foundation
import struct RobotPlugin.RobotPlugin

/// Legacy API over one shared plugin value; no local integration or control algorithm.
public struct RobotSimulator: Sendable {
    public var plugin: RobotPlugin
    public var deviceID: String { plugin.simulator.deviceID }
    public var model: RobotModel {
        // DTO compatibility retains mutable/immutable fields without a second model algorithm.
        let value = plugin.simulator.model
        return RobotModel(
            id: value.id,
            minimum: value.minimum,
            maximum: value.maximum,
            maximum_speed_rad_s: value.maximum_speed_rad_s,
            maximum_acceleration_rad_s2: value.maximum_acceleration_rad_s2,
            dh_a_m: value.dh_a_m,
            dh_d_m: value.dh_d_m,
            dh_alpha_rad: value.dh_alpha_rad
        )
    }

    public var control: DeviceControl { .init(shared: plugin.simulator.control) }
    public var trace: [RobotTraceSample] { plugin.simulator.trace }
    public init(deviceID: String = "robot.reference", model: RobotModel = .reference) throws {
        plugin = try withLegacySimulationErrors {
            try RobotPlugin(deviceID: deviceID, model: model.shared, instanceID: UUID().uuidString)
        }
        _ = try plugin.handle(.start, at: 0)
    }

    public init(plugin: RobotPlugin) { self.plugin = plugin }
    public mutating func initialize(_ values: [Double], generation: String) throws {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.initialize(
            values,
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

    public mutating func move(_ proof: DeviceCommandProof, target: [Double], duration: Double,
                              validFor: Double) throws
    {
        try requireWrites()
        try withLegacySimulationErrors { try plugin.simulator.move(
            proof,
            target: target,
            duration: duration,
            validFor: validFor
        ) }
    }

    public mutating func revokeControl() { plugin.simulator.revokeControl() }
    public func snapshot() -> RobotSnapshot { plugin.simulator.snapshot() }
    private func requireWrites() throws {
        guard plugin.acceptsWrites else { throw ProviderDomainError("stopped", "The plugin is stopped") }
    }
}
