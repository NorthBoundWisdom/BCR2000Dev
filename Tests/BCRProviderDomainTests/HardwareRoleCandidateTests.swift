import BCRConfigurationAdapter
import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

final class HardwareRoleCandidateTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let map = HardwareMap(entries: [
            .init(
                control: .button(row: 1, 1),
                midi: .init(kind: .controlChange, channel: 0, number: 67),
                visualizationOnly: true,
                pressMode: .momentary
            ),
            .init(
                control: .button(row: 1, 2),
                midi: .init(kind: .controlChange, channel: 0, number: 68),
                visualizationOnly: true,
                pressMode: .momentary
            ),
            .init(control: .pushEncoder(group: 1, 1), midi: .init(kind: .controlChange, channel: 0, number: 8)),
            .init(control: .pushEncoder(group: 1, 2), midi: .init(kind: .controlChange, channel: 0, number: 9))
        ])
        let request = HardwareRoleReadiness.Request(roles: [
            "enable": "button.1.1",
            "stop": "button.1.2",
            "linear": "pushEncoder.1.1",
            "steer": "pushEncoder.1.2"
        ])
        let source = directory.appendingPathComponent("test-only-source-map.json")
        let roles = directory.appendingPathComponent("test-only-roles.json")
        try JSONEncoder().encode(map).write(to: source)
        try JSONEncoder().encode(request).write(to: roles)
        return (directory, source, roles, directory.appendingPathComponent("new-candidate"))
    }

    func testSeparateCandidatePreservesSourceIdentitiesAndNeverClaimsQualification() throws {
        let (directory, source, roles, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let report = try HardwareRoleCandidate.prepare(mapURL: source, requestURL: roles, destination: destination)
        XCTAssertEqual(report["ready"] as? Bool, false)
        XCTAssertEqual(report["software_ready"] as? Bool, true)
        XCTAssertEqual(report["hardware_qualified"] as? Bool, false)
        XCTAssertEqual(report["source_map_sha256"] as? String, HardwareRoleCandidate.sha256(original))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let candidate = try JSONDecoder().decode(
            HardwareMap.self,
            from: Data(contentsOf: destination.appendingPathComponent("candidate-hardware-map.json"))
        )
        let originalMap = try JSONDecoder().decode(HardwareMap.self, from: original)
        XCTAssertEqual(candidate.entries.map(\.midi), originalMap.entries.map(\.midi))
        XCTAssertEqual(candidate.entries.map(\.pressMode), originalMap.entries.map(\.pressMode))
        XCTAssertFalse(candidate.isVisualizationOnly(.button(row: 1, 1)))
        let verified = try HardwareRoleCandidate.verify(directory: destination)
        XCTAssertEqual(verified["integrity_valid"] as? Bool, true)
        XCTAssertEqual(verified["ready"] as? Bool, false)
        XCTAssertThrowsError(try HardwareRoleCandidate.prepare(
            mapURL: source,
            requestURL: roles,
            destination: destination
        ))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDuplicateKeysAndUnknownEncodingDoNotCreateCandidate() throws {
        let (directory, source, roles, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let text = String(decoding: original, as: UTF8.self)
        for broken in [text.replacingOccurrences(of: "\"version\":7", with: "\"version\":7,\"version\":7"),
                       text.replacingOccurrences(of: "controlChange", with: "unknownEncoding")]
        {
            try Data(broken.utf8).write(to: source)
            XCTAssertThrowsError(try HardwareRoleCandidate.prepare(
                mapURL: source,
                requestURL: roles,
                destination: destination
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testPulseAndRepeatedRoleAreRejectedWithoutChangingInput() throws {
        let (directory, source, roles, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let pulse = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "momentary", with: "pulse")
        try Data(pulse.utf8).write(to: source)
        XCTAssertThrowsError(try HardwareRoleCandidate.prepare(
            mapURL: source,
            requestURL: roles,
            destination: destination
        ))
        try original.write(to: source)
        let request = HardwareRoleReadiness.Request(roles: [
            "enable": "button.1.1",
            "stop": "button.1.1",
            "linear": "pushEncoder.1.1",
            "steer": "pushEncoder.1.2"
        ])
        try JSONEncoder().encode(request).write(to: roles)
        XCTAssertThrowsError(try HardwareRoleCandidate.prepare(
            mapURL: source,
            requestURL: roles,
            destination: destination
        ))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTamperingAndFalseQualificationFailClosed() throws {
        let (directory, source, roles, destination) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try HardwareRoleCandidate.prepare(mapURL: source, requestURL: roles, destination: destination)
        let manifestURL = destination.appendingPathComponent("candidate-manifest.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        var manifest = try JSONSerialization.jsonObject(with: originalManifest) as! [String: Any]
        manifest["hardware_qualified"] = true
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try HardwareRoleCandidate.verify(directory: destination))
        try originalManifest.write(to: manifestURL)
        try Data("{}".utf8).write(to: destination.appendingPathComponent("candidate-hardware-map.json"))
        XCTAssertThrowsError(try HardwareRoleCandidate.verify(directory: destination))
    }
}
