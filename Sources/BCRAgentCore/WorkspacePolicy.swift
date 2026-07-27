import Foundation

public enum WorkspacePolicyError: Error, LocalizedError, Sendable {
    case pathMissing(String)
    case pathNotAbsolute(String)
    case pathNotDirectory(String)
    case writableRootEmpty
    case writableRootMismatch
    case pathTraversalDetected

    public var errorDescription: String? {
        switch self {
        case let .pathMissing(path):
            "路径不存在：\(path)"
        case let .pathNotAbsolute(path):
            "必须使用绝对路径：\(path)"
        case let .pathNotDirectory(path):
            "必须是目录：\(path)"
        case .writableRootEmpty:
            "workspaceWrite 需要可解析且存在的 writableRoot"
        case .writableRootMismatch:
            "writableRoots 必须严格等于当前工作目录，禁止放宽为父目录"
        case .pathTraversalDetected:
            "路径包含不可追踪的符号链接或越界风险"
        }
    }
}

public enum WorkspacePolicy {
    public static func canonicalWorkspaceRoot(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL else {
            throw WorkspacePolicyError.pathNotAbsolute(path)
        }
        guard url.path.starts(with: "/") else {
            throw WorkspacePolicyError.pathNotAbsolute(path)
        }
        let resolved = url.resolvingSymlinksInPath()

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw WorkspacePolicyError.pathMissing(resolved.path)
        }
        guard isDirectory.boolValue else {
            throw WorkspacePolicyError.pathNotDirectory(resolved.path)
        }

        return resolved.standardizedFileURL
    }

    public static func validateWorkspaceWrite(
        cwdPath: String?,
        writableRoots: [String]?
    ) throws {
        guard let cwdPath else {
            throw WorkspacePolicyError.pathMissing("")
        }
        let normalizedCWD = try canonicalWorkspaceRoot(cwdPath).path

        guard let roots = writableRoots, !roots.isEmpty else {
            throw WorkspacePolicyError.writableRootEmpty
        }
        guard roots.count == 1 else {
            throw WorkspacePolicyError.writableRootMismatch
        }
        let normalizedRoot = try canonicalWorkspaceRoot(roots[0]).path
        guard normalizedRoot == normalizedCWD else {
            throw WorkspacePolicyError.writableRootMismatch
        }
    }

    public static func isSubpath(_ child: URL, within parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return childPath == parent.standardizedFileURL.path
            || childPath.hasPrefix(parentPath)
    }
}
