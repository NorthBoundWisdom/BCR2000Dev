// Development compatibility source; prefer the published BCRProfileTool executable.
import BCRConfigurationAdapter
import Foundation

@main
struct BCRProfileTool {
    static func main() throws {
        let args = CommandLine.arguments
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
