import BCRFoundation
import BCRRobotDomain
import BCRChassisDomain
import BCRSurfaceDomain
import Foundation
import BCRPluginRuntime
import RobotRemoteBinding
import ChassisRemoteBinding
import RemoteToolContracts

public enum ProviderClock: String, Codable, Sendable { case realtime, manual }
public struct ProviderConfiguration: Codable, Sendable {
    public var robot: Bool
    public var chassis: Bool
    public var clock: ProviderClock
    public init(robot: Bool = false, chassis: Bool = false, clock: ProviderClock = .realtime) {
        self.robot = robot; self.chassis = chassis; self.clock = clock
    }
}

public struct ProviderAccess: Sendable {
    public let write: Bool
    public let robot: Bool
    public let chassis: Bool
    public let simulation: Bool
    public init(write: Bool, robot: Bool, chassis: Bool, simulation: Bool) {
        self.write = write; self.robot = robot; self.chassis = chassis; self.simulation = simulation
    }
}

public enum RobotOperation: Sendable {
    case initialize(String, [Double]), acquire(String, String, Double)
    case enable(DeviceCommandProof), stop(DeviceCommandProof), disable(DeviceCommandProof), release(DeviceCommandProof)
    case renew(DeviceCommandProof, Double), move(DeviceCommandProof, [Double], Double, Double)
    case reset(String), fault(String, String), clearFault(String)
}

public enum ChassisOperation: Sendable {
    case initialize(String, [Double]), acquire(String, String, Double)
    case enable(DeviceCommandProof), stop(DeviceCommandProof), disable(DeviceCommandProof), release(DeviceCommandProof)
    case renew(DeviceCommandProof, Double), drive(DeviceCommandProof, Double, Double, Double)
    case reset(String), fault(String, String), clearFault(String)
}

public struct RobotCommandReply: Codable, Sendable {
    public let accepted: Bool
    public let control: DeviceControlGrant?
    public let state: RobotSnapshot
}

public struct ChassisCommandReply: Codable, Sendable {
    public let accepted: Bool
    public let control: DeviceControlGrant?
    public let state: ChassisSnapshot
}

/// Composition/application boundary shared by GUI and headless hosts. No transport or UI dependency.
@MainActor
public final class ProviderApplication {
    /// Identity of this application instance, not configurable and not a device generation.
    public let providerID = UUID().uuidString
    public let configuration: ProviderConfiguration
    public let events = ProviderEventJournal(source: .simulation)
    public let runtime: BCRPluginRuntime
    public static let robotInstanceID = "robot.reference"
    public static let chassisInstanceID = "chassis.reference"
    private var robot: RobotSimulator? { configuration.robot ? runtime.optionalBinding(
        Self.robotInstanceID,
        as: RobotRemoteBinding.self
    ).map { .init(plugin: $0.plugin) } : nil }
    private var chassis: ChassisSimulator? { configuration.chassis ? runtime.optionalBinding(
        Self.chassisInstanceID,
        as: ChassisRemoteBinding.self
    ).map { .init(plugin: $0.plugin) } : nil }
    private struct SimulationRoute {
        let enabled: Bool
        let advance: @MainActor (Double) throws -> Void
        let revoke: @MainActor () throws -> Void
        let fault: @MainActor (String) throws -> Void
    }

    private var routes: [String: SimulationRoute] = [:]
    private let routeOrder: [String] = ["robot", "chassis"]
    private var observer: UUID?
    public private(set) var lastSafetyFailure: String?
    private var clockDiagnostic = "gap"

    private var timer: Task<Void, Never>?
    private let monotonic: @MainActor () -> Double
    private var lastMonotonic: Double

    public init(
        configuration: ProviderConfiguration = .init(),
        monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        runtime: BCRPluginRuntime? = nil
    ) {
        self.configuration = configuration
        do { self.runtime = try runtime ?? BCRPluginRuntime(clock: monotonic) }
        catch { preconditionFailure("Invalid built-in plugin runtime: \(error)") }
        let owner = self.runtime
        self.monotonic = { owner.now }; lastMonotonic = owner.now
        do {
            var bindings: [any RemoteBinding] = []
            if configuration.robot { bindings.append(RobotRemoteBinding(
                instanceID: Self.robotInstanceID,
                plugin: try RobotSimulator().plugin
            )) }
            if configuration.chassis { bindings.append(ChassisRemoteBinding(
                instanceID: Self.chassisInstanceID,
                plugin: try ChassisSimulator().plugin
            )) }
            try self.runtime.install(bindings)
        } catch { preconditionFailure("Invalid built-in simulation composition: \(error)") }
        routes["robot"] = .init(enabled: configuration.robot, advance: { [unowned self] dt in
            guard var value = self.robot else { throw ProviderDomainError(
                "unsupported",
                "The robot module is not enabled"
            ) }
            try value.advance(dt); try self.storeRobot(value, operation: "advance")
        }, revoke: { [unowned self] in
            guard var value = self.robot else { return }
            value.revokeControl(); try self.storeRobot(value, operation: "revoke", safety: true)
        }, fault: { [unowned self] code in
            guard var value = self.robot else { return }
            try value.plugin.simulator.fault(code, generation: value.control.generation)
            try self.storeRobot(value, operation: "fault", safety: true)
        })
        routes["chassis"] = .init(enabled: configuration.chassis, advance: { [unowned self] dt in
            guard var value = self.chassis else { throw ProviderDomainError(
                "unsupported",
                "The chassis module is not enabled"
            ) }
            try value.advance(dt); try self.storeChassis(value, operation: "advance")
        }, revoke: { [unowned self] in
            guard var value = self.chassis else { return }
            value.revokeControl(); try self.storeChassis(value, operation: "revoke", safety: true)
        }, fault: { [unowned self] code in
            guard var value = self.chassis else { return }
            try value.plugin.simulator.fault(code, generation: value.control.generation)
            try self.storeChassis(value, operation: "fault", safety: true)
        })
        observer = self.runtime.observe { [weak self] change in
            guard let self, change.isRemote,
                  change.instanceID == Self.robotInstanceID || change.instanceID == Self.chassisInstanceID
            else { return }
            self.publish()
        }
    }

    deinit {
        timer?.cancel()
        let owner = runtime, token = observer
        Task { @MainActor in if let token { owner.removeObserver(token) } }
    }

    public func start() {
        guard configuration.clock == .realtime, robot != nil || chassis != nil, timer == nil else { return }
        lastMonotonic = monotonic()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                self?.tick()
            }
        }
    }

    public func stopClock() { timer?.cancel(); timer = nil }
    public func revokeControl(domain: String) {
        guard let route = routes[domain] else { return }
        do { try route.revoke() } catch { lastSafetyFailure = error.localizedDescription }
        publish()
    }

    public func tick() {
        guard configuration.clock == .realtime else { return }
        let now = monotonic(), elapsed = now - lastMonotonic
        guard elapsed >= 0 && elapsed <= 2 && runtime.isTrustedTime(now) else {
            clockDiagnostic = !now
                .isFinite ? "nonfinite" : (elapsed < 0 || !runtime.isTrustedTime(now) ? "regressed" : "gap")
            // Keep the previous trusted anchor through regressions/NaN. A valid forward
            // gap faults motion but establishes a new clock anchor for later ticks.
            if now.isFinite && runtime.isTrustedTime(now) && elapsed > 2 { lastMonotonic = now }
            for name in routeOrder {
                do { try routes[name]?.fault("host_clock_gap") }
                catch { lastSafetyFailure = error.localizedDescription }
            }
            publish(); return
        }
        lastMonotonic = now
        var remaining = elapsed
        while remaining > 1e-9 {
            let step = min(0.02, remaining)
            do { for name in routeOrder { if let route = routes[name], route.enabled { try route.advance(step) } } }
            catch { assertionFailure("Invalid internal simulation step: \(error)") }
            remaining -= step
        }
        if elapsed > 0 { publish() }
    }

    private func storeRobot(_ value: RobotSimulator, operation: String, safety: Bool = false) throws {
        var binding = try runtime.binding(Self.robotInstanceID, as: RobotRemoteBinding.self)
        binding.plugin = value.plugin
        if safety {
            try runtime.replaceForSafety(binding, event: .init(code: "host.safety.robot." + operation,
                                                               fields: ["clock": .string(operation == "fault" ?
                                                                       clockDiagnostic : "authorityRevoked")]))
        } else { try runtime.replace(binding, event: .init(code: "host.robot." + operation)) }
    }

    private func storeChassis(_ value: ChassisSimulator, operation: String, safety: Bool = false) throws {
        var binding = try runtime.binding(Self.chassisInstanceID, as: ChassisRemoteBinding.self)
        binding.plugin = value.plugin
        if safety {
            try runtime.replaceForSafety(binding, event: .init(code: "host.safety.chassis." + operation,
                                                               fields: ["clock": .string(operation == "fault" ?
                                                                       clockDiagnostic : "authorityRevoked")]))
        } else { try runtime.replace(binding, event: .init(code: "host.chassis." + operation)) }
    }

    public func robotState() throws -> RobotSnapshot {
        guard let robot else { throw ProviderDomainError("unsupported", "The robot module is not enabled") }
        return robot.snapshot()
    }

    public func chassisState() throws -> ChassisSnapshot {
        guard let chassis else { throw ProviderDomainError("unsupported", "The chassis module is not enabled") }
        return chassis.snapshot()
    }

    public func robotTrace() throws -> [RobotTraceSample] {
        guard let robot
        else { throw ProviderDomainError("unsupported", "The robot module is not enabled") }; return robot.trace
    }

    public func chassisTrace() throws -> [ChassisTraceSample] {
        guard let chassis
        else { throw ProviderDomainError("unsupported", "The chassis module is not enabled") }; return chassis.trace
    }

    public func executeRobot(_ operation: RobotOperation, access: ProviderAccess) throws -> RobotCommandReply {
        guard var robot else { throw ProviderDomainError("unsupported", "The robot module is not enabled") }
        try ProviderValidation.require(
            access.write && access.robot,
            "permission_denied",
            "Robot control permission is required"
        )
        var grant: DeviceControlGrant?
        switch operation {
        case let .initialize(generation, joints): try robot.initialize(joints, generation: generation)
        case let .acquire(generation, owner, ttl): grant = try robot.acquire(
                generation: generation,
                owner: owner,
                ttl: ttl
            )
        case let .enable(proof): try robot.enable(proof)
        case let .stop(proof): try robot.stop(proof)
        case let .disable(proof): try robot.stop(proof, disable: true)
        case let .release(proof): try robot.release(proof)
        case let .renew(proof, ttl): try robot.renew(proof, ttl: ttl)
        case let .move(proof, joints, duration, validity): try robot.move(
                proof,
                target: joints,
                duration: duration,
                validFor: validity
            )
        case let .reset(generation), let .clearFault(generation):
            try ProviderValidation.require(
                access.simulation,
                "permission_denied",
                "Simulation administration permission is required"
            )
            try robot.reset(generation: generation)
        case let .fault(generation, code):
            try ProviderValidation.require(
                access.simulation,
                "permission_denied",
                "Simulation fault permission is required"
            )
            try robot.fault(code, generation: generation)
        }
        try storeRobot(robot, operation: "command"); publish()
        return RobotCommandReply(accepted: true, control: grant, state: robot.snapshot())
    }

    public func executeChassis(_ operation: ChassisOperation, access: ProviderAccess) throws -> ChassisCommandReply {
        guard var chassis else { throw ProviderDomainError("unsupported", "The chassis module is not enabled") }
        try ProviderValidation.require(
            access.write && access.chassis,
            "permission_denied",
            "Chassis control permission is required"
        )
        var grant: DeviceControlGrant?
        switch operation {
        case let .initialize(generation, pose): try chassis.initialize(pose, generation: generation)
        case let .acquire(generation, owner, ttl): grant = try chassis.acquire(
                generation: generation,
                owner: owner,
                ttl: ttl
            )
        case let .enable(proof): try chassis.enable(proof)
        case let .stop(proof): try chassis.stop(proof)
        case let .disable(proof): try chassis.stop(proof, disable: true)
        case let .release(proof): try chassis.release(proof)
        case let .renew(proof, ttl): try chassis.renew(proof, ttl: ttl)
        case let .drive(proof, speed, steering, validity): try chassis.drive(
                proof,
                speed: speed,
                steering: steering,
                validFor: validity
            )
        case let .reset(generation), let .clearFault(generation):
            try ProviderValidation.require(
                access.simulation,
                "permission_denied",
                "Simulation administration permission is required"
            )
            try chassis.reset(generation: generation)
        case let .fault(generation, code):
            try ProviderValidation.require(
                access.simulation,
                "permission_denied",
                "Simulation fault permission is required"
            )
            try chassis.fault(code, generation: generation)
        }
        try storeChassis(chassis, operation: "command"); publish()
        return ChassisCommandReply(accepted: true, control: grant, state: chassis.snapshot())
    }

    public func advance(domain: String, dt: Double, access: ProviderAccess) throws {
        try ProviderValidation.require(
            configuration.clock == .manual,
            "unsupported",
            "Manual advance requires manual-clock mode"
        )
        try ProviderValidation.require(
            access.write && access.simulation,
            "permission_denied",
            "Simulation clock permission is required"
        )
        guard let route = routes[domain] else { throw ProviderDomainError("unsupported", "Unknown simulation domain") }
        try route.advance(dt)
        publish()
    }

    public func state() -> JSONValue {
        .object([
            "schema_version": .number(1),
            "provider_id": .string(providerID),
            "source": .string("simulation"),
            "clock": .string(configuration.clock.rawValue),
            "robot": robot.map { try! JSONValue.encoded($0.snapshot()) } ?? .null,
            "chassis": chassis.map { try! JSONValue.encoded($0.snapshot()) } ?? .null
        ])
    }

    private func publish() { events.append(kind: "devices.changed", payload: state()) }
}
