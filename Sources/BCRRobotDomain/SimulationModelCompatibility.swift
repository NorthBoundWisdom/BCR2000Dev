import Foundation
import BCRSimulationKernel
import struct RobotPlugin.RobotModel
import struct RobotPlugin.RobotActual
import struct RobotPlugin.RobotSnapshot
import struct RobotPlugin.RobotTraceSample

public typealias SharedRobotModel = RobotPlugin.RobotModel
public typealias RobotActual = RobotPlugin.RobotActual
public typealias RobotSnapshot = RobotPlugin.RobotSnapshot
public typealias RobotTraceSample = RobotPlugin.RobotTraceSample
public struct RobotModel: Codable, Sendable {
    public var id: String
    public var minimum: [Double]
    public var maximum: [Double]
    public var maximum_speed_rad_s: Double
    public var maximum_acceleration_rad_s2: Double
    public var dh_a_m: [Double]
    public var dh_d_m: [Double]
    public var dh_alpha_rad: [Double]
    public var shared: SharedRobotModel {
        SharedRobotModel(
            id: id,
            minimum: minimum,
            maximum: maximum,
            maximum_speed_rad_s: maximum_speed_rad_s,
            maximum_acceleration_rad_s2: maximum_acceleration_rad_s2,
            dh_a_m: dh_a_m,
            dh_d_m: dh_d_m,
            dh_alpha_rad: dh_alpha_rad
        )
    }

    public static var reference: RobotModel {
        let value = SharedRobotModel.reference
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

    public func validate() throws { try withLegacySimulationErrors { try shared.validate() } }
    public func validateJoints(_ values: [Double]) throws {
        try withLegacySimulationErrors { try shared.validateJoints(values) }
    }

    public func forward(_ joints: [Double]) -> [Double] { shared.forward(joints) }
}
