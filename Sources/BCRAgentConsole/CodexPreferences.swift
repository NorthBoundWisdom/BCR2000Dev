import BCRAgentCore
import Foundation

struct CodexPreferences: Codable, Sendable, Equatable {
    var version = 1
    var backend: AgentBackend = .mock
    var executable = ""
    var workspace = ""
    var modelID = ""
    var effort = ""
    var allowWorkspaceWrites = false
    init() {}
    private enum CodingKeys: String,
        CodingKey { case version, backend, executable, workspace, modelID, effort, allowWorkspaceWrites }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        backend = try c.decode(AgentBackend.self, forKey: .backend)
        executable = try c.decode(String.self, forKey: .executable)
        workspace = try c.decode(String.self, forKey: .workspace)
        modelID = try c.decode(String.self, forKey: .modelID)
        effort = try c.decode(String.self, forKey: .effort)
        allowWorkspaceWrites = try c.decode(Bool.self, forKey: .allowWorkspaceWrites)
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw ConfigurationFileError(reason: L10n.text("Codex 设置版本不受支持")) }
        for path in [executable, workspace] {
            guard path.isEmpty || (path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 4096) else {
                throw ConfigurationFileError(reason: L10n.text("Codex 设置中的路径必须是绝对路径"))
            }
        }
        guard modelID.utf8.count <= 1024, effort.utf8.count <= 1024 else {
            throw ConfigurationFileError(reason: L10n.text("Codex 设置无效"))
        }
    }
}
