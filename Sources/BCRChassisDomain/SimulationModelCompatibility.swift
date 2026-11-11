import Foundation
import BCRSimulationKernel
import struct ChassisPlugin.AckermannModel
import struct ChassisPlugin.ChassisActual
import struct ChassisPlugin.ChassisSnapshot
import struct ChassisPlugin.ChassisTraceSample

public typealias SharedAckermannModel = ChassisPlugin.AckermannModel
public typealias ChassisActual = ChassisPlugin.ChassisActual
public typealias ChassisSnapshot = ChassisPlugin.ChassisSnapshot
public typealias ChassisTraceSample = ChassisPlugin.ChassisTraceSample
public struct AckermannModel: Codable, Sendable {
    public let id: String
    public let wheelbase_m: Double
    public let track_m: Double
    public let wheel_radius_m: Double
    public let maximum_speed_m_s: Double
    public let maximum_acceleration_m_s2: Double
    public let maximum_steering_rad: Double
    public let maximum_steering_rate_rad_s: Double
    public var shared: SharedAckermannModel {
        SharedAckermannModel(
            id: id,
            wheelbase_m: wheelbase_m,
            track_m: track_m,
            wheel_radius_m: wheel_radius_m,
            maximum_speed_m_s: maximum_speed_m_s,
            maximum_acceleration_m_s2: maximum_acceleration_m_s2,
            maximum_steering_rad: maximum_steering_rad,
            maximum_steering_rate_rad_s: maximum_steering_rate_rad_s
        )
    }

    public static var reference: AckermannModel {
        let value = SharedAckermannModel.reference
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

    public func validate() throws { try withLegacySimulationErrors { try shared.validate() } }
}
