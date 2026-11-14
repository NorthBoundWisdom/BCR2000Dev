import BCRFoundation
import BCRSurfaceDomain
import enum SurfacePluginContracts.JSONValue
import CryptoKit
import Foundation

/// Stages separate, explicitly unverified files; never installs a map or dispatches effects.
public enum HardwareRoleCandidate {
    public enum Failure: Error { case invalid, destinationExists, changedSource }
    private static let roles = ["enable", "linear", "steer", "stop"]
    private static let parameters = ["enable": "candidate.button_a", "linear": "candidate.axis_a",
                                     "steer": "candidate.axis_b", "stop": "candidate.button_b"]
    private static let files = ["source-map.json", "source-configuration.json", "role-readiness-request.json",
                                "candidate-hardware-map.json", "candidate-configuration.json",
                                "software-readiness.json"]
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }
        .joined()
    }

    private static func id(_ control: BCRControlID)
        -> String { "\(control.section.rawValue).\(control.row).\(control.index)" }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// Foundation's decoder accepts duplicate object keys; candidate inputs reject them first.
    private static func strict(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        _ = try JSONSerialization.jsonObject(with: data)
        let regex = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|[{}\[\]:,]"#)
        let tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
        var scopes: [Set<String>?] = []
        for (index, token) in tokens.enumerated() {
            switch token {
            case "{": scopes.append([])
            case "[": scopes.append(nil)
            case "}", "]": guard !scopes.isEmpty else { throw Failure.invalid }; scopes.removeLast()
            default:
                if token.first == "\"", index + 1 < tokens.count, tokens[index + 1] == ":" {
                    guard !scopes.isEmpty, var keys = scopes.removeLast() else { throw Failure.invalid }
                    let key = try JSONDecoder().decode(String.self, from: Data(token.utf8))
                    guard keys.insert(key).inserted else { throw Failure.invalid }
                    scopes.append(keys)
                }
            }
        }
        guard scopes.isEmpty else { throw Failure.invalid }
    }

    private static func build(map: HardwareMap, sourceConfiguration: SurfaceConfiguration,
                              request: HardwareRoleReadiness.Request) throws -> (HardwareMap, SurfaceConfiguration)
    {
        try map.validate()
        _ = try sourceConfiguration.migrated()
        guard request.schema_version == 1, request.require_feedback,
              Set(request.roles.keys) == Set(roles), Set(request.roles.values).count == 4 else { throw Failure.invalid }
        var candidate = map
        var definitions: [ParameterDefinition] = []
        var assignments: [ControlAssignment] = []
        for name in roles {
            guard let selected = request.roles[name],
                  let entry = map.entries.first(where: { id($0.control) == selected }),
                  entry.midi.kind == .controlChange else { throw Failure.invalid }
            let button = name == "enable" || name == "stop"
            guard button ? (!entry.control.isContinuous && entry.pressMode == .momentary) : entry.control.isContinuous
            else { throw Failure.invalid }
            if !button, let mode = sourceConfiguration.assignment(for: entry.control)?.encoderMode,
               mode != .absolute { throw Failure.invalid }
            // Keep the exact learned MIDI identity and press mode. Only the two candidate buttons
            // change the host's visualization policy; nothing changes on the physical device.
            if button {
                try candidate.bind(entry.control, to: entry.midi, visualizationOnly: false, pressMode: entry.pressMode)
            }
            let parameter = ParameterID(parameters[name]!)
            definitions.append(.init(id: parameter, name: parameters[name]!, minimum: 0, maximum: button ? 1 : 127,
                                     kind: button ? .toggle : .continuous, step: 1))
            assignments.append(.init(control: entry.control, target: .parameter(parameter), buttonBehavior: .momentary))
        }
        return (
            candidate,
            try SurfaceConfiguration(name: "Unverified independent role candidate", parameters: definitions,
                                     assignments: assignments).migrated()
        )
    }

    public static func prepare(mapURL: URL, requestURL: URL, destination: URL,
                               configurationURL: URL? = nil) throws -> [String: Any]
    {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: destination.path)) == nil else { throw Failure.destinationExists }
        let sourceMap = try Data(contentsOf: mapURL), sourceRequest = try Data(contentsOf: requestURL)
        let sourceConfiguration = try configurationURL
            .map { try Data(contentsOf: $0) } ?? encode(SurfaceConfiguration.neutral())
        for data in [sourceMap, sourceRequest, sourceConfiguration] { try strict(data) }
        let decoder = JSONDecoder()
        let map = try decoder.decode(HardwareMap.self, from: sourceMap)
        let configuration = try decoder.decode(SurfaceConfiguration.self, from: sourceConfiguration)
        let request = try decoder.decode(HardwareRoleReadiness.Request.self, from: sourceRequest)
        let (candidate, candidateConfiguration) = try build(
            map: map,
            sourceConfiguration: configuration,
            request: request
        )
        let software = try HardwareRoleReadiness.check(
            map: candidate,
            configuration: candidateConfiguration,
            request: request,
            hardwareOutput: .write,
            displayPermission: true
        )
        guard software.ready else { throw Failure.invalid }
        let payload: [String: Data] = ["source-map.json": sourceMap, "source-configuration.json": sourceConfiguration,
                                       "role-readiness-request.json": sourceRequest,
                                       "candidate-hardware-map.json": try encode(candidate),
                                       "candidate-configuration.json": try encode(candidateConfiguration),
                                       "software-readiness.json": try encode(software)]
        let changes = try roles.map { name -> [String: Any] in
            let control = map.entries.first { id($0.control) == request.roles[name]! }!
            return [
                "role": name,
                "control_id": id(control.control),
                "midi": try JSONSerialization.jsonObject(with: encode(control.midi)),
                "midi_identity_changed": false,
                "press_mode_changed": false,
                "visualization_only_before": control.visualizationOnly == true,
                "visualization_only_after": (name == "enable" || name == "stop") ? false : control
                    .visualizationOnly == true,
                "new_parameter": parameters[name]!
            ]
        }
        let manifest: [String: Any] = [
            "schema_version": 1, "artifact": "unverified-hardware-role-candidate", "candidate": true,
            "test_only": true, "ready": false, "software_ready": true, "hardware_qualified": false,
            "qualification": "unverified; no device I/O or automatic application",
            "source_map_sha256": sha256(sourceMap), "source_configuration_sha256": sha256(sourceConfiguration),
            "source_configuration_basis": configurationURL == nil ? "neutral default encoded value" :
                "explicit read-only source",
            "source_request_sha256": sha256(sourceRequest), "files_sha256": payload.mapValues(sha256),
            "changes": changes, "missing_evidence": [
                "fresh current-preset identity matching the learned addresses",
                "per selected button observed press=127 and release=0 on that identity",
                "per selected button physical LED output address/encoding and observed on/off result",
                "attended end-to-end qualification of this exact candidate and endpoint"
            ],
            "historical_context": "visualizationOnly is the host's imported-button safety policy; inherited momentary declarations are not fresh observations"
        ]
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".candidate-stage-" + UUID().uuidString)
        try manager.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: stage) }
        for (name, data) in payload {
            try data.write(to: stage.appendingPathComponent(name), options: .withoutOverwriting)
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(
            to: stage.appendingPathComponent("candidate-manifest.json"),
            options: .withoutOverwriting
        )
        guard try Data(contentsOf: mapURL) == sourceMap, try Data(contentsOf: requestURL) == sourceRequest,
              try configurationURL.map({ try Data(contentsOf: $0) == sourceConfiguration }) ?? true
        else { throw Failure.changedSource }
        try manager.moveItem(at: stage, to: destination)
        return manifest
    }

    public static func verify(directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("candidate-manifest.json"))
        try strict(data)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["artifact"] as? String == "unverified-hardware-role-candidate",
              manifest["ready"] as? Bool == false, manifest["hardware_qualified"] as? Bool == false,
              let hashes = manifest["files_sha256"] as? [String: String],
              Set(hashes.keys) == Set(files) else { throw Failure.invalid }
        var payload: [String: Data] = [:]
        for name in files {
            let value = try Data(contentsOf: directory.appendingPathComponent(name)); try strict(value)
            guard sha256(value) == hashes[name] else { throw Failure.invalid }; payload[name] = value
        }
        guard sha256(payload["source-map.json"]!) == manifest["source_map_sha256"] as? String,
              sha256(payload["source-configuration.json"]!) == manifest["source_configuration_sha256"] as? String,
              sha256(payload["role-readiness-request.json"]!) == manifest["source_request_sha256"] as? String
        else { throw Failure.invalid }
        let decoder = JSONDecoder()
        let sourceMap = try decoder.decode(HardwareMap.self, from: payload["source-map.json"]!)
        let sourceConfiguration = try decoder.decode(
            SurfaceConfiguration.self,
            from: payload["source-configuration.json"]!
        )
        let request = try decoder.decode(
            HardwareRoleReadiness.Request.self,
            from: payload["role-readiness-request.json"]!
        )
        let expected = try build(map: sourceMap, sourceConfiguration: sourceConfiguration, request: request)
        guard try decoder.decode(HardwareMap.self, from: payload["candidate-hardware-map.json"]!) == expected.0,
              try decoder.decode(SurfaceConfiguration.self, from: payload["candidate-configuration.json"]!) == expected
                  .1 else { throw Failure.invalid }
        let software = try HardwareRoleReadiness.check(map: expected.0, configuration: expected.1, request: request,
                                                       hardwareOutput: .write, displayPermission: true)
        guard software.ready,
              try decoder.decode(JSONValue.self, from: payload["software-readiness.json"]!) == decoder.decode(
                  JSONValue.self,
                  from: encode(software)
              ),
              manifest["candidate"] as? Bool == true, manifest["test_only"] as? Bool == true,
              let evidence = manifest["missing_evidence"] as? [String],
              evidence.count == 4 else { throw Failure.invalid }
        return ["artifact": "unverified-hardware-role-candidate", "integrity_valid": true,
                "ready": false, "software_ready": true, "hardware_qualified": false,
                "missing_evidence": manifest["missing_evidence"] ?? [],
                "source_map_sha256": sha256(payload["source-map.json"]!)]
    }

    public static func command(arguments: [String], verifyOnly: Bool = false) -> (output: String, exitCode: Int32) {
        do {
            let result: [String: Any]
            if verifyOnly {
                guard arguments.count == 1 else { throw Failure.invalid }
                result = try verify(directory: URL(fileURLWithPath: arguments[0], isDirectory: true))
            } else {
                guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--configuration")
                else { throw Failure.invalid }
                result = try prepare(
                    mapURL: URL(fileURLWithPath: arguments[0]),
                    requestURL: URL(fileURLWithPath: arguments[1]),
                    destination: URL(fileURLWithPath: arguments[2], isDirectory: true),
                    configurationURL: arguments.count == 5 ? URL(fileURLWithPath: arguments[4]) : nil
                )
            }
            return (
                String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                       as: UTF8.self),
                0
            )
        } catch {
            return (
                "{\"ready\":false,\"hardware_qualified\":false,\"code\":\"invalid_or_conflicting_candidate_input\"}",
                2
            )
        }
    }
}
