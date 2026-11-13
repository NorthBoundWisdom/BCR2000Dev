import BCRAgentCore
import enum SurfacePluginContracts.JSONValue
import Foundation

/// MCP access to the same alignment flow as the window. Commands start the flow and return at once;
/// callers poll `get_preset_alignment` until `busy` is false. The window shows the same state.
extension ConsoleViewModel {
    func handlePresetAlignment(_ command: PresetAlignmentCommand) throws -> JSONValue {
        switch command {
        case .status:
            break
        case let .preview(options):
            guard canAlignPreset else {
                throw MCPToolFailure(L10n.text("请先在实体模式下连接 BCR2000，并停止学习。"))
            }
            beginPresetAlignment(options: options)
        case .apply:
            guard let state = presetAlignment, state.phase == .preview else {
                throw MCPToolFailure(L10n.text("没有待确认的预设对齐预览，请先读取预览。"))
            }
            guard let plan = state.plan, !plan.isEmpty else {
                throw MCPToolFailure(L10n.text("预览没有需要写入的变更。"))
            }
            applyPresetAlignment()
            // Every precondition failure leaves the preview in place and only posts a notice.
            guard presetAlignment?.phase != .preview else {
                throw MCPToolFailure(L10n.text("请重新读取并确认设备预设预览。"))
            }
        case .restore:
            if let reason = restoreUnavailableReason { throw MCPToolFailure(reason) }
            restorePresetBeforeAlignment()
        case .dismiss:
            guard presetAlignment?.phase.isBusy != true else {
                throw MCPToolFailure(L10n.text("预设操作进行中，完成后才能关闭。"))
            }
            dismissPresetAlignment()
        }
        return try presetAlignmentStatus()
    }

    private func presetAlignmentStatus() throws -> JSONValue {
        let state = presetAlignment
        var progress: JSONValue = .null
        var failure: JSONValue = .null
        let phase: String
        switch state?.phase {
        case nil: phase = "none"
        case .reading: phase = "reading"
        case .preview: phase = "preview"
        case let .writing(done, total):
            phase = "writing"; progress = .object(["done": .number(done), "total": .number(total)])
        case .verifying: phase = "verifying"
        case .finished: phase = "finished"
        case .restoring:
            phase = "restoring"
            if let restore = state?.restoreProgress {
                progress = .object(["done": .number(restore.done), "total": .number(restore.total)])
            }
        case .restoreConfirmation: phase = "restoreConfirmation"
        case let .failed(message): phase = "failed"; failure = .string(L10n.text(message))
        }
        var plan: JSONValue = .null
        if let value = state?.plan {
            plan = .object([
                "changeCount": .number(value.changes.count),
                "lineCount": .number(value.lines.count),
                "changes": .array(try value.changes.map { change in
                    .object([
                        "kind": .string(change.kind.rawValue),
                        "control": try change.control.map {
                            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
                        } ?? .null,
                        "detail": .string(change.detail)
                    ])
                })
            ])
        }
        let options = state?.options ?? BCRPresetAlignment.Options()
        return .object([
            "phase": .string(phase),
            "busy": .bool(state?.phase.isBusy == true),
            "progress": progress,
            "error": failure,
            "planError": state?.planError.map { .string(L10n.text($0)) } ?? .null,
            "options": .object([
                "completeButtons": .bool(options.completeButtons), "ringModes": .bool(options.ringModes),
                "buttonBehavior": .bool(options.buttonBehavior), "lockPreset": .bool(options.lockPreset),
                "enableButtonFunctions": .bool(options.enableButtonFunctions)
            ]),
            "plan": plan,
            "backupFile": state?.backup.map { .string($0.lastPathComponent) } ?? .null,
            "canPreview": .bool(canAlignPreset),
            "hasRestorePoint": .bool(presetRestorePoint != nil),
            "canRestore": .bool(canRestorePreset),
            "restoreUnavailableReason": restoreUnavailableReason.map(JSONValue.string) ?? .null
        ])
    }
}
