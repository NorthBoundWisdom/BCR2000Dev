import BCRFoundation
import BCRProviderApplication
import Foundation
import XCTest

@MainActor
final class HostSimulationBoundaryTests: XCTestCase {
    private let all = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
    private func fixture() -> ProviderApplication {
        .init(configuration: .init(robot: true, clock: .manual), monotonic: { 0 })
    }

    func testHostUUIDTokensRemainOpaqueAndGenerationFailurePrecedesTokenFailure() throws {
        let app = fixture()
        let initialGeneration = try app.robotState().metadata.generation
        let initialized = try app.executeRobot(
            .initialize(initialGeneration, Array(repeating: 0, count: 6)),
            access: all
        )
        let generation = initialized.state.metadata.generation
        XCTAssertNotEqual(generation, initialGeneration)
        let grant = try XCTUnwrap(app.executeRobot(.acquire(generation, "fixture", 5), access: all).control)
        XCTAssertTrue(UUID(uuidString: grant.control_token)?.uuidString == grant.control_token)
        XCTAssertThrowsError(try app.executeRobot(
            .enable(.init(generation: "wrong", token: "wrong", sequence: 1)),
            access: all
        )) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stale_generation", "The device generation changed"))
        }
        if grant.control_token.lowercased() != grant.control_token {
            XCTAssertThrowsError(try app.executeRobot(
                .enable(.init(generation: generation, token: grant.control_token.lowercased(), sequence: 1)),
                access: all
            )) {
                XCTAssertEqual(
                    $0 as? ProviderDomainError,
                    .init("invalid_control", "Control token does not own this device")
                )
            }
        }
        _ = try app.executeRobot(
            .enable(.init(generation: generation, token: grant.control_token, sequence: 1)),
            access: all
        )
        XCTAssertTrue(try app.robotState().metadata.enabled)
    }

    func testPermissionAndStoppedChecksKeepOriginalOrderBeforeGenerationAndValueErrors() throws {
        let app = fixture()
        _ = try app.runtime.handle(ProviderApplication.robotInstanceID, input: .stop)
        let noWrite = ProviderAccess(write: false, robot: true, chassis: true, simulation: true)
        XCTAssertThrowsError(try app.executeRobot(.initialize("wrong", []), access: noWrite)) {
            XCTAssertEqual(
                $0 as? ProviderDomainError,
                .init("permission_denied", "Robot control permission is required")
            )
        }
        XCTAssertThrowsError(try app.executeRobot(.initialize("wrong", []), access: all)) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stopped", "The plugin is stopped"))
        }
        let noAdmin = ProviderAccess(write: true, robot: true, chassis: true, simulation: false)
        XCTAssertThrowsError(try app.executeRobot(.reset("wrong"), access: noAdmin)) {
            XCTAssertEqual(
                $0 as? ProviderDomainError,
                .init("permission_denied", "Simulation administration permission is required")
            )
        }
    }
}
