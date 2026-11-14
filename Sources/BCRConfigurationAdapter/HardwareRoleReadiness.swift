import BCRFoundation
import BCRSurfaceDomain
import Foundation

/// Offline checks of explicitly requested consumer roles, never a hardware qualification.
/// Input support is evaluated with the same value engine used by the host, without dispatching effects.
public enum HardwareRoleReadiness {
    public struct Request: Codable, Sendable {
        public let schema_version: Int
        public let roles: [String: String]
        public let require_feedback: Bool
        public init(roles: [String: String], requireFeedback: Bool = true) {
            schema_version = 1; self.roles = roles; require_feedback = requireFeedback
        }
    }

    public struct ControlSupport: Codable, Sendable {
        public let control_id: String
        public let engine_accepts_input: Bool
        public let momentary: Bool
        public let feedback_kind: String?
        public let reasons: [String]
    }

    public struct RoleResult: Codable, Sendable {
        public let control_id: String?
        public let input_ready: Bool
        public let feedback_ready: Bool
        public let reasons: [String]
    }

    public struct Report: Encodable, Sendable {
        public let schema_version = 1
        public let scope = "offline-role-readiness; not hardware qualification"
        public let hardware_qualified = false
        public let ready: Bool
        public let hardware_output: String
        public let display_permission: Bool
        public let roles: [String: RoleResult]
        public let available_input_ids: [String]
        public let available_momentary_button_ids: [String]
        public let available_value_feedback_ids: [String]
        public let available_indicator_feedback_ids: [String]
        public let controls: [ControlSupport]
        public let missing: [String]
    }

    /// CLI parsing stays with the existing configuration tool adapter; no runtime or device is opened.
    public static func command(arguments: [String]) -> (output: String, exitCode: Int32) {
        do {
            guard arguments.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
            let map = try JSONDecoder().decode(
                HardwareMap.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            )
            let request = try JSONDecoder().decode(
                Request.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            )
            var configuration = SurfaceConfiguration.neutral()
            var policy = HardwareOutputPolicy.observe
            var permission = false
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--configuration":
                    index += 1; guard index < arguments.count else { throw CocoaError(.fileReadCorruptFile) }
                    configuration = try JSONDecoder().decode(
                        SurfaceConfiguration.self,
                        from: Data(contentsOf: URL(fileURLWithPath: arguments[index]))
                    )
                case "--hardware-output":
                    index += 1; guard index < arguments.count,
                                      let value = HardwareOutputPolicy(rawValue: arguments[index])
                    else { throw CocoaError(.fileReadCorruptFile) }
                    policy = value
                case "--allow-surface-feedback": permission = true
                default: throw CocoaError(.fileReadCorruptFile)
                }
                index += 1
            }
            let report = try check(
                map: map,
                configuration: configuration,
                request: request,
                hardwareOutput: policy,
                displayPermission: permission
            )
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (String(decoding: try encoder.encode(report), as: UTF8.self), report.ready ? 0 : 3)
        } catch {
            return ("{\"ready\":false,\"code\":\"invalid_readiness_input\",\"hardware_qualified\":false}", 2)
        }
    }

    private static let names = ["enable", "linear", "steer", "stop"]
    private static func id(_ control: BCRControlID) -> String {
        "\(control.section.rawValue).\(control.row).\(control.index)"
    }

    public static func check(map: HardwareMap, configuration: SurfaceConfiguration, request: Request,
                             hardwareOutput: HardwareOutputPolicy = .observe,
                             displayPermission: Bool = false) throws -> Report
    {
        try map.validate()
        let configuration = try configuration.migrated()
        var supports: [String: ControlSupport] = [:]
        let engine = SurfaceEngine(hardwareMap: map, configuration: configuration)
        for entry in map.entries {
            let control = entry.control
            var reasons: [String] = []
            let mode = configuration.assignment(for: control)?.encoderMode ?? .absolute
            if entry.visualizationOnly == true { reasons.append("visualization_only_input_is_ignored") }
            if entry.midi.kind == .nrpn { reasons.append("nrpn_not_qualified") }
            if control.isContinuous && mode != .absolute { reasons.append("relative_not_qualified") }
            let supportedEncoding = entry.midi.kind != .nrpn && (!control.isContinuous || mode == .absolute)
            var candidate = engine
            let before = candidate.state(of: control).eventCount
            if supportedEncoding {
                // No SurfaceDevice is constructed and no returned effect is dispatched.
                _ = candidate.handleInput(MIDI1UMPCodec.feedback(control: entry.midi, value: 127),
                                          at: Date(timeIntervalSinceReferenceDate: 1))
            }
            let accepted = supportedEncoding && candidate.state(of: control).eventCount > before
            let afterPress = candidate.state(of: control).eventCount
            if supportedEncoding, !control.isContinuous {
                _ = candidate.handleInput(MIDI1UMPCodec.feedback(control: entry.midi, value: 0),
                                          at: Date(timeIntervalSinceReferenceDate: 2))
            }
            let releaseAccepted = !control.isContinuous && candidate.state(of: control).eventCount > afterPress
            if !accepted && !reasons
                .contains("visualization_only_input_is_ignored") { reasons.append("engine_does_not_accept_input") }
            let momentary = accepted && releaseAccepted && entry.pressMode == .momentary &&
                (configuration.assignment(for: control).map { $0.buttonBehavior == .momentary } ?? true)
            if !control.isContinuous && !momentary { reasons.append("momentary_press_release_not_declared") }
            let feedback: String? = supportedEncoding && entry.visualizationOnly != true ?
                (control.isContinuous ? "value" : "indicator") : nil
            supports[id(control)] = ControlSupport(control_id: id(control), engine_accepts_input: accepted,
                                                   momentary: momentary, feedback_kind: feedback, reasons: reasons)
        }
        var roles: [String: RoleResult] = [:]
        var missing: [String] = []
        if request.schema_version != 1 { missing.append("invalid_request_version") }
        if !Set(request.roles.keys).isSubset(of: Set(names)) { missing.append("unknown_role") }
        let duplicates = Set(request.roles.values.filter { value in
            request.roles.values.filter { $0 == value }.count > 1
        })
        for name in names {
            let requested = request.roles[name]
            let support = requested.flatMap { supports[$0] }
            var reasons: [String] = []
            if requested == nil { reasons.append("missing_role") }
            else if support == nil { reasons.append("unknown_control") }
            let needsButton = name == "enable" || name == "stop"
            if let support {
                reasons += support.reasons
                if !support.engine_accepts_input { reasons.append("accepted_input_required") }
                if needsButton && !support.momentary { reasons.append("momentary_button_required") }
                if !needsButton && !map.entries
                    .contains(where: { id($0.control) == requested && $0.control.isContinuous })
                {
                    reasons.append("absolute_axis_required")
                }
                if let requested, duplicates.contains(requested) { reasons.append("role_controls_must_be_distinct") }
            }
            let inputReady = support?.engine_accepts_input == true && reasons.isEmpty
            let kind = needsButton ? "indicator" : "value"
            let feedbackReady = support?.feedback_kind == kind && hardwareOutput == .write && displayPermission
            if request.require_feedback && !feedbackReady {
                if support?.feedback_kind != kind { reasons.append("required_display_feedback_not_declared") }
                if hardwareOutput != .write { reasons.append("hardware_write_policy_required") }
                if !displayPermission { reasons.append("display_permission_required") }
            }
            reasons = Array(Set(reasons)).sorted()
            roles[name] = RoleResult(control_id: requested, input_ready: inputReady,
                                     feedback_ready: feedbackReady, reasons: reasons)
            missing += reasons.map { name + ":" + $0 }
        }
        let rows = supports.values.sorted { $0.control_id < $1.control_id }
        return Report(ready: missing.isEmpty, hardware_output: hardwareOutput.rawValue,
                      display_permission: displayPermission, roles: roles,
                      available_input_ids: rows.filter(\.engine_accepts_input).map(\.control_id),
                      available_momentary_button_ids: rows.filter { $0.engine_accepts_input && $0.momentary }
                          .map(\.control_id),
                      available_value_feedback_ids: rows.filter { $0.feedback_kind == "value" }.map(\.control_id),
                      available_indicator_feedback_ids: rows.filter { $0.feedback_kind == "indicator" }
                          .map(\.control_id),
                      controls: rows, missing: Array(Set(missing)).sorted())
    }
}
