import BCRAgentCore
import Foundation

struct ConsoleStores: Sendable {
    let hardwareMap: JSONFileStore<HardwareMap>
    let configuration: JSONFileStore<SurfaceConfiguration>

    static let standard = ConsoleStores(
        hardwareMap: JSONFileStore(applicationSupportFile: "hardware-map.json"),
        configuration: JSONFileStore(applicationSupportFile: "surface-configuration.json")
    )

    static func temporary() -> ConsoleStores {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bcr-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ConsoleStores(
            hardwareMap: JSONFileStore(fileURL: directory.appending(path: "hardware-map.json")),
            configuration: JSONFileStore(fileURL: directory.appending(path: "surface-configuration.json"))
        )
    }
}
