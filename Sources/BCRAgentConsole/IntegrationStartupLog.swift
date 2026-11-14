import Foundation

/// Direct stderr writes survive early termination; never include credentials or environment values.
enum IntegrationStartupLog {
    static func write(_ stage: String) {
        #if DEBUG
            guard CommandLine.arguments.contains("--integration-test") else { return }
            let event: [String: Any] = [
                "type": "bcr.integration_startup", "stage": stage,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "time": Date().timeIntervalSince1970
            ]
            do {
                var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                data.append(0x0A)
                try FileHandle.standardError.write(contentsOf: data)
            } catch {
                FileHandle.standardError.write(Data("Could not write integration startup marker.\n".utf8))
            }
        #endif
    }
}
