import BCRAgentCore
import XCTest

@MainActor
final class HardwareConfirmationGatewayTests: XCTestCase {
    func testHeadlessDefaultAndInjectedHostConfirmation() {
        let service = MCPApplicationGateway(session: SurfaceSession(
            hardwareDevice: MockSurfaceDevice(), configuration: .starter(),
            saveHardwareMap: { _ in }, saveConfiguration: { _ in }
        ))
        func confirmation() -> JSONValue? {
            let result = service.call("get_status")
            XCTAssertFalse(result.isError)
            return result.value.objectValue?["hardwareConnection"]?.objectValue?["confirmation"]
        }
        XCTAssertEqual(confirmation(), .string("none"))
        for state in [HardwareConnectionConfirmation.pending, .declined, .none] {
            service.onReadHardwareConnectionConfirmation = { state }
            XCTAssertEqual(confirmation(), .string(state.rawValue))
        }
        service.onReadHardwareConnectionConfirmation = nil
        XCTAssertEqual(confirmation(), .string("none"))
    }
}
