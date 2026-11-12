import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import Foundation
import XCTest

@MainActor
final class SimulationConfigurationTests: XCTestCase {
    var example: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "examples/simulation/chassis-controls.json")
    }

    func testExampleProducesUsableInputsAndOnlyMomentaryHold() throws {
        let configuration = try SimulationSurfaceConfiguration.decode(Data(contentsOf: example))
        let surface = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: configuration,
                                     saveHardwareMap: { _ in XCTFail("must not save hardware map") },
                                     saveConfiguration: { _ in XCTFail("must not persist simulation configuration") })
        let gateway = MCPApplicationGateway(
            session: surface,
            permissions: .init(deviceControl: true),
            includeAgent: false
        )
        let adapter = try XCTUnwrap(SurfaceControlMCPModule.install(on: gateway, instanceID: "configuration-test",
                                                                    permissions: .init(input: true),
                                                                    momentaryHoldsOnly: true))
        _ = adapter
        let discovery = gateway.call("surface_control_discover").value.objectValue!
        let controls = discovery["profile"]!.objectValue!["controls"]!.arrayValue!
        let enable = try XCTUnwrap(controls.first { $0.objectValue?["id"] == .string("button.1.1") }?.objectValue)
        let stop = try XCTUnwrap(controls.first { $0.objectValue?["id"] == .string("button.1.2") }?.objectValue)
        XCTAssertNotNil(enable["hold"])
        XCTAssertNil(stop["hold"])
        for (id, encoding, value, parameter) in [
            ("button.1.1", "boolean", JSONValue.bool(true), "simulation.enable"),
            ("pushEncoder.1.1", "scalar", .number(90), "simulation.speed"),
            ("pushEncoder.1.2", "scalar", .number(80), "simulation.steer"),
            ("button.1.2", "boolean", .bool(true), "simulation.stop")
        ] {
            let current = gateway.call("surface_control_discover").value.objectValue!
            let result = gateway.call("surface_control_input", arguments: .object([
                "expected": current["expected"]!, "expected_sequence": current["latest_sequence"]!,
                "control_id": .string(id), "encoding": .string(encoding), "value": value
            ]))
            XCTAssertFalse(result.isError, "\(result.value)")
            XCTAssertGreaterThan(surface.engine.value(of: ParameterID(parameter)) ?? 0, 0)
        }
    }

    func testStrictConfigurationRejectsUnknownFieldsInvalidBindingsAndProtectedParameters() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: example)) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unexpected"] = true },
            { $0["version"] = 6 },
            { $0["version"] = true },
            { $0["pages"] = [["id": "page"]] },
            { row in var p = row["parameters"] as! [[String: Any]]; p[0]["unknown"] = 1; row["parameters"] = p },
            { row in
                var p = row["parameters"] as! [[String: Any]]; p[0]["agentWritable"] = false; row["parameters"] = p },
            { row in
                var p = row["parameters"] as! [[String: Any]]; p[0]["externallyProtected"] = true; row["parameters"] =
                    p },
            { row in var a = row["assignments"] as! [[String: Any]]; a.append(a[0]); row["assignments"] = a },
            { row in var a = row["assignments"] as! [[String: Any]]; a[0]["unknown"] = true; row["assignments"] = a },
            { row in var a = row["assignments"] as! [[String: Any]]; a[0]["control"] = [
                "section": "button",
                "row": 9,
                "index": 1
            ]; row["assignments"] = a },
            { row in var a = row["assignments"] as! [[String: Any]]; a[0]["control"] = [
                "section": "button",
                "row": 1,
                "index": 1,
                "unknown": 1
            ]; row["assignments"] = a },
            { row in
                var a = row["assignments"] as! [[String: Any]]; a[0]["target"] =
                    ["parameter": ["_0": "missing"]]; row["assignments"] = a },
            { row in
                var a = row["assignments"] as! [[String: Any]]; a[0]["target"] =
                    ["runMacro": ["_0": "macro"]]; row["assignments"] = a }
        ]
        for (index, mutation) in mutations.enumerated() {
            var candidate = base; mutation(&candidate)
            XCTAssertThrowsError(
                try SimulationSurfaceConfiguration.decode(JSONSerialization.data(withJSONObject: candidate)),
                "mutation \(index)"
            )
        }
    }

    func testLegacySimulationMappingRemainsPinned() throws {
        let surface = SurfaceSession(
            hardwareDevice: MockSurfaceDevice(),
            configuration: SurfaceControlMCPModule.simulationConfiguration(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let contract = try BCRSurfaceControlAdapter.publishedContract(surface: surface)
        XCTAssertEqual(contract.objectValue?["discovery"]?.objectValue?["expected"]?.objectValue?["mapping_revision"],
                       .string("2813b4891860c6da"))
    }
}
