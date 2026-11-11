import BCRFoundation
import BCRSimulationKernel
import Foundation

public struct RobotModel: Codable, Sendable {
    public var id: String
    public var minimum: [Double]
    public var maximum: [Double]
    public var maximum_speed_rad_s: Double
    public var maximum_acceleration_rad_s2: Double
    public var dh_a_m: [Double]
    public var dh_d_m: [Double]
    public var dh_alpha_rad: [Double]
    public static var reference: RobotModel {
        RobotModel(id: "reference-six-joint-v1", minimum: Array(repeating: -.pi, count: 6),
                   maximum: Array(repeating: .pi, count: 6), maximum_speed_rad_s: 2,
                   maximum_acceleration_rad_s2: 4, dh_a_m: [0, 0.3, 0.25, 0, 0, 0],
                   dh_d_m: [0.32, 0, 0, 0.32, 0, 0.1], dh_alpha_rad: [.pi / 2, 0, 0, .pi / 2, -.pi / 2, 0])
    }

    public func validate() throws {
        let n = minimum.count
        try ProviderValidation.require(
            (1 ... 12).contains(n) && [maximum, dh_a_m, dh_d_m, dh_alpha_rad].allSatisfy { $0.count == n },
            "invalid_argument",
            "Invalid joint chain dimensions"
        )
        try ProviderValidation.require(
            ProviderValidation.finite(minimum + maximum + dh_a_m + dh_d_m + dh_alpha_rad) && zip(minimum, maximum)
                .allSatisfy { $0 < $1 },
            "invalid_argument",
            "Invalid joint chain limits"
        )
        try ProviderValidation.require(
            maximum_speed_rad_s.isFinite && maximum_speed_rad_s > 0 && maximum_acceleration_rad_s2
                .isFinite && maximum_acceleration_rad_s2 > 0,
            "invalid_argument",
            "Invalid joint dynamics"
        )
    }

    public func validateJoints(_ values: [Double]) throws {
        try ProviderValidation.require(
            values.count == minimum.count && ProviderValidation.finite(values),
            "invalid_argument",
            "Finite joint vector with the model dimension is required"
        )
        try ProviderValidation.require(
            values.indices.allSatisfy { minimum[$0] <= values[$0] && values[$0] <= maximum[$0] },
            "invalid_argument",
            "Joint target exceeds model limits"
        )
    }

    public func forward(_ joints: [Double]) -> [Double] {
        var matrix = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        for i in joints.indices {
            let c = cos(joints[i]), s = sin(joints[i]), ca = cos(dh_alpha_rad[i]), sa = sin(dh_alpha_rad[i])
            let next = [c, -s * ca, s * sa, dh_a_m[i] * c, s, c * ca, -c * sa, dh_a_m[i] * s,
                        0, sa, ca, dh_d_m[i], 0, 0, 0, 1]
            var result = Array(repeating: 0.0, count: 16)
            for row in 0 ..<
                4
            {
                for col in 0 ..<
                    4 { for k in 0 ..< 4 { result[row * 4 + col] += matrix[row * 4 + k] * next[k * 4 + col] } }
            }
            matrix = result
        }
        return matrix
    }
}

public struct RobotActual: Codable, Sendable {
    public let joints_rad: [Double]
    public let joint_velocity_rad_s: [Double]
    public let base_from_tool_row_major_m: [Double]
}

public struct RobotSnapshot: Codable, Sendable {
    public let metadata: DeviceMetadata
    public let actual: RobotActual?
    public let target_joints_rad: [Double]?
    public let motion_active: Bool
    public let stopped: Bool
    public let trace_dropped: UInt64
    private enum CodingKeys: String,
        CodingKey { case metadata, actual, target_joints_rad, motion_active, stopped, trace_dropped }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metadata, forKey: .metadata); try c.encode(actual, forKey: .actual)
        try c.encode(target_joints_rad, forKey: .target_joints_rad); try c.encode(motion_active, forKey: .motion_active)
        try c.encode(stopped, forKey: .stopped); try c.encode(trace_dropped, forKey: .trace_dropped)
    }
}

public struct RobotTraceSample: Codable, Sendable {
    public let source: ProviderSource
    public let generation: String
    public let sequence: UInt64
    public let simulated_time_s: Double
    public let actual: RobotActual
}

public struct RobotSimulator: Sendable {
    public let deviceID: String
    public let model: RobotModel
    public private(set) var control = DeviceControl()
    public private(set) var trace: [RobotTraceSample] = []
    private var dropped: UInt64 = 0
    private var joints: [Double]?
    private var velocity: [Double] = []
    private var target: [Double]?
    private var plan: Plan?
    private var phase = "uninitialized"
    private struct Plan: Sendable {
        let start: Double
        let duration: Double
        let initial: [Double]
        let initialVelocity: [Double]
        let target: [Double]
        let stopping: Bool
    }

    public init(deviceID: String = "robot.reference", model: RobotModel = .reference) throws {
        try model.validate(); self.deviceID = deviceID; self.model = model
    }

    public mutating func initialize(_ values: [Double], generation: String) throws {
        try ProviderValidation.require(plan == nil, "busy", "Stop the robot before initializing")
        try model.validateJoints(values); try control.initialize(expectedGeneration: generation)
        joints = values; velocity = Array(repeating: 0, count: values.count); target = nil; phase = "disabled"
        trace.removeAll(); dropped = 0; record()
    }

    public mutating func acquire(generation: String, owner: String, ttl: Double) throws -> DeviceControlGrant {
        try control.acquire(expectedGeneration: generation, owner: owner, ttl: ttl)
    }

    public mutating func enable(_ proof: DeviceCommandProof) throws {
        try ProviderValidation.require(plan == nil, "busy", "The robot is still stopping")
        try control.enable(proof); phase = "idle"
    }

    public mutating func renew(_ proof: DeviceCommandProof, ttl: Double) throws { try control.renew(proof, ttl: ttl) }
    public mutating func release(_ proof: DeviceCommandProof) throws {
        try ProviderValidation.require(plan == nil, "busy", "Stop before releasing control")
        try control.release(proof); phase = "disabled"
    }

    public mutating func move(_ proof: DeviceCommandProof, target: [Double], duration: Double,
                              validFor: Double) throws
    {
        try control.validate(proof)
        try ProviderValidation.require(control.enabled, "disabled", "Enable the robot before motion")
        try ProviderValidation.require(plan == nil, "busy", "Stop or finish the current motion first")
        try model.validateJoints(target)
        try ProviderValidation.require(
            duration.isFinite && validFor
                .isFinite && duration > 0 && validFor >= duration && validFor <= 5 && (control.expires ?? 0) - control
                .time >= duration,
            "command_expired",
            "The complete move must fit its validity and control window"
        )
        guard let joints else { throw ProviderDomainError("not_initialized", "Actual joints are unknown") }
        let distance = zip(joints, target).map { abs($0 - $1) }.max() ?? 0
        let minimumDuration = max(1.875 * distance / model.maximum_speed_rad_s,
                                  sqrt(5.773502692 * distance / model.maximum_acceleration_rad_s2))
        try ProviderValidation.require(
            duration >= minimumDuration,
            "invalid_argument",
            "Requested duration exceeds model velocity or acceleration limits"
        )
        try control.accept(proof)
        self.target = target
        if distance == 0 { phase = "stopped"; record(); return }
        plan = Plan(start: control.time, duration: duration, initial: joints,
                    initialVelocity: Array(repeating: 0, count: joints.count), target: target, stopping: false)
        phase = "running"; record()
    }

    public mutating func stop(_ proof: DeviceCommandProof, disable: Bool = false) throws {
        try control.accept(proof)
        if disable { control.disable() }
        beginStop()
    }

    public mutating func revokeControl() { control.revoke(); beginStop() }

    private mutating func beginStop() {
        guard let joints else { plan = nil; return }
        let duration = (velocity.map { abs($0) }.max() ?? 0) / model.maximum_acceleration_rad_s2
        if duration <= 1e-12 {
            velocity = Array(repeating: 0, count: joints.count); plan = nil; target = nil
            phase = control.enabled ? "stopped" : "disabled"; record(); return
        }
        let end = zip(joints, velocity).map { $0 + $1 * duration / 2 }
        plan = Plan(
            start: control.time,
            duration: duration,
            initial: joints,
            initialVelocity: velocity,
            target: end,
            stopping: true
        )
        target = nil; phase = "stopping"; record()
    }

    public mutating func advance(_ dt: Double) throws {
        try ProviderValidation.require(
            dt.isFinite && dt > 0 && dt <= 0.1,
            "invalid_argument",
            "Invalid robot time step"
        )
        try ProviderValidation.require(
            (control.time + dt).isFinite && control.time + dt > control.time,
            "invalid_argument",
            "Time step is not representable"
        )
        var remaining = dt
        if let expiry = control.expires, expiry > control.time, expiry < control.time + dt {
            let first = expiry - control.time
            integrate(to: control.time + first); let expired = try control.advance(first)
            if expired { beginStop() }; remaining -= first
        }
        if remaining > 0, control.time + remaining > control.time {
            integrate(to: control.time + remaining); let expired = try control.advance(remaining)
            if expired { beginStop() }
        }
        record()
    }

    private mutating func integrate(to time: Double) {
        guard let plan else { return }
        let t = min(max((time - plan.start) / plan.duration, 0), 1)
        if plan.stopping {
            let elapsed = t * plan.duration
            joints = zip(plan.initial, plan.initialVelocity)
                .map { $0 + $1 * (elapsed - elapsed * elapsed / (2 * plan.duration)) }
            velocity = plan.initialVelocity.map { $0 * (1 - t) }
        } else {
            func polynomial(_ u: Double) -> Double { u * u * u * (10 + u * (-15 + 6 * u)) }
            let blend = t < 0.5 ? polynomial(t) : 1 - polynomial(1 - t)
            joints = zip(plan.initial, plan.target).map { $0 + ($1 - $0) * blend }
            velocity = zip(plan.initial, plan.target).map { ($1 - $0) * 30 * t * t * (1 - t) * (1 - t) / plan.duration }
        }
        if t >= 1 {
            joints = plan.target; velocity = Array(repeating: 0, count: plan.target.count); self.plan = nil
            phase = control.enabled ? "stopped" : "disabled"
        }
    }

    public mutating func fault(_ code: String, generation: String) throws {
        try control.injectFault(code, expectedGeneration: generation)
        plan = nil; velocity = velocity.map { _ in 0 }; target = nil; phase = "fault"; record()
    }

    public mutating func reset(generation: String) throws {
        try ProviderValidation.require(plan == nil, "busy", "Stop before resetting")
        try control.reset(expectedGeneration: generation)
        joints = nil; velocity = []; target = nil; phase = "uninitialized"; trace.removeAll(); dropped = 0
    }

    private func actual() -> RobotActual? {
        guard let joints, control.fault != "telemetry_unavailable" else { return nil }
        return RobotActual(
            joints_rad: joints,
            joint_velocity_rad_s: velocity,
            base_from_tool_row_major_m: model.forward(joints)
        )
    }

    private mutating func record() {
        guard let actual = actual() else { return }
        trace.append(RobotTraceSample(
            source: .simulation,
            generation: control.generation,
            sequence: control.revision,
            simulated_time_s: control.time,
            actual: actual
        ))
        if trace.count > 512 { trace.removeFirst(trace.count - 512); dropped &+= 1 }
    }

    public func snapshot() -> RobotSnapshot {
        RobotSnapshot(
            metadata: control
                .metadata(device: deviceID, model: model.id, state: phase, frame: "reference_robot_base_v1"),
            actual: actual(),
            target_joints_rad: target,
            motion_active: plan != nil,
            stopped: actual() != nil && plan == nil && velocity.allSatisfy { abs($0) <= 1e-12 },
            trace_dropped: dropped
        )
    }
}
