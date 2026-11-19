import BCRConfigurationAdapter
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@main
struct BCRProfileTool {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--describe-mock-map" {
            print(String(decoding: try ProfileConversion.mockMapDescription(), as: UTF8.self))
            return
        }
        if args.count == 2, args[1] == "--help" {
            print(
                "BCRProfileTool --describe-mock-map | --inspect-preset <file> | <capture-directory> <profile-directory> | --stage-hardware-candidate <map> <roles> <new-dir> [--configuration PATH] | --verify-hardware-candidate <dir> | --buttons <capture> <profile> | --check-hardware-roles <learned-map.json> <role-request.json> [--configuration PATH] [--hardware-output observe|write] [--allow-surface-feedback]"
            )
            return
        }
        if args.count >= 2, args[1] == "--inspect-preset" {
            guard args.count == 3 else {
                FileHandle.standardError.write(Data("Usage: BCRProfileTool --inspect-preset <file>\n".utf8))
                exit(2)
            }
            do {
                let report = try ProfileConversion.inspectPreset(file: URL(fileURLWithPath: args[2]))
                print(String(decoding: report, as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(2)
            }
            return
        }
        if args.count >= 2, ["--stage-hardware-candidate", "--verify-hardware-candidate"].contains(args[1]) {
            let result = HardwareRoleCandidate.command(
                arguments: Array(args.dropFirst(2)),
                verifyOnly: args[1] == "--verify-hardware-candidate"
            )
            print(result.output)
            exit(result.exitCode)
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
