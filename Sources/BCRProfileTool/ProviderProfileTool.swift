import BCRConfigurationAdapter
import Foundation

@main
struct BCRProfileTool {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--help" {
            print(
                "BCRProfileTool <capture-directory> <profile-directory> | --buttons <capture> <profile> | --check-hardware-roles <learned-map.json> <role-request.json> [--configuration PATH] [--hardware-output observe|write] [--allow-surface-feedback]"
            )
            return
        }
        if args.count >= 2, args[1] == "--check-hardware-roles" {
            let result = HardwareRoleReadiness.command(arguments: Array(args.dropFirst(2)))
            print(result.output)
            exit(result.exitCode)
        }
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
