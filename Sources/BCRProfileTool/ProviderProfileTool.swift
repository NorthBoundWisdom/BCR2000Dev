import BCRConfigurationAdapter
import Foundation

@main
struct BCRProfileTool {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--buttons" {
            let result = try ProfileConversion.prepareButtons(
                capture: URL(fileURLWithPath: args[2]),
                profile: URL(fileURLWithPath: args[3])
            )
            print(
                "Staged \(result.mappings) mappings; \(result.missing) unconfigured and \(result.unsupported) unsupported buttons; original profile unchanged"
            )
            return
        }
        guard args.count == 3 else { throw NSError(
            domain: "BCRProfileTool",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Usage: BCRProfileTool <capture-directory> <profile-directory>"]
        ) }
        let result = try ProfileConversion.prepare(
            capture: URL(fileURLWithPath: args[1], isDirectory: true),
            profile: URL(fileURLWithPath: args[2], isDirectory: true)
        )
        print("Staged \(result.mappings) mappings and \(result.parameters) parameters; original profile unchanged")
    }
}
