import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import AppKit
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
import enum SurfacePluginContracts.IndicatorSemantic
import UniformTypeIdentifiers
import Combine
import Foundation

@MainActor
final class ConsoleSurfaceIntents: ConsoleDeviceOwner {
    let context: ConsoleDeviceContext
    private let configurationFile: ProtectedJSONFile<SurfaceConfiguration>
    private var migratedHardwareMap: HardwareMap?
    private var migratedConfiguration: Bool
    var requestSource: @MainActor (DeviceSource) -> Void = { _ in }
    var canChangeButtonFunctions: @MainActor () -> Bool = { false }
    private var canChangeHardwareButtonFunctions: Bool { canChangeButtonFunctions() }
    private var selectedControl: BCRControlID? {
        get { presentation.selectedControl } set { presentation.selectedControl = newValue }
    }

    private var visibleGroup: Int {
        get { presentation.visibleGroup } set { presentation.visibleGroup = newValue }
    }

    private var workspacePanels: WorkspacePanelSettings { presentation.workspacePanels }
    private var learnedCount: Int { engine.hardwareMap.boundCount }
    private var persistenceNotice: ConsoleNotice? {
        get { presentation.persistenceNotice } set { presentation.persistenceNotice = newValue }
    }

    init(context: ConsoleDeviceContext, configurationFile: ProtectedJSONFile<SurfaceConfiguration>,
         migratedHardwareMap: HardwareMap?, migratedConfiguration: Bool)
    {
        self.context = context; self.configurationFile = configurationFile
        self.migratedHardwareMap = migratedHardwareMap; self.migratedConfiguration = migratedConfiguration
    }

    func selectGroup(_ group: Int) {
        visibleGroup = min(max(group, 1), 4)
        session.selectGroup(visibleGroup)
    }

    func turn(_ control: BCRControlID, by delta: Int) {
        touch(control)
        session.turn(control, by: delta)
    }

    func press(_ control: BCRControlID) {
        touch(control)
        session.press(control)
    }

    func release(_ control: BCRControlID) {
        session.release(control)
    }

    func touch(_ control: BCRControlID) {
        guard !isLearning else { return }
        selectedControl = control
    }

    func setParameter(_ id: ParameterID, to value: Double) {
        session.setParameter(id, to: value)
    }

    func resetGroup(_ group: String) {
        session.resetGroup(group)
    }

    @discardableResult
    func createParameter(assigningTo control: BCRControlID? = nil) -> ParameterID? {
        do {
            return try session.createParameter(assigningTo: control)
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func updateParameter(_ definition: ParameterDefinition) -> ParameterDefinition? {
        do {
            notice = ConsoleNotice(
                level: .info,
                message: "参数“\(BuiltInNamePresentation.displayName(definition.name))”已更新。"
            )
            try session.updateParameter(definition)
            return configuration.parameter(definition.id)
        } catch {
            report(error)
            return nil
        }
    }

    func removeParameter(_ id: ParameterID) {
        session.removeParameter(id)
    }

    func loadPreset(_ preset: ConfigurationPreset) {
        let hint: LocalizedMessage = preset == .robotArm && !workspacePanels.isEnabled(.arm)
            ? "可从工作区“面板”菜单启用机械臂预览。" : ""
        let loaded: LocalizedMessage = "已载入“\(preset.title)”。"
        notice = ConsoleNotice(level: .info, message: "\(loaded)\(hint)")
        do { try session.replaceConfiguration(preset.makeConfiguration()) }
        catch { report(error) }
    }

    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) {
        do { try session.setAssignment(assignment, for: control) }
        catch { report(error) }
    }

    func setCycleValues(_ text: String, parameter: ParameterID, for control: BCRControlID) {
        let fields = text.replacingOccurrences(of: "，", with: ",").split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        let values = fields.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == fields.count
        else { report(ConfigurationFileError(reason: L10n.text("循环值必须是逗号分隔的数值"))); return }
        setAssignment(
            ControlAssignment(control: control, target: .cycleParameter(id: parameter, values: values)),
            for: control
        )
    }

    func bulkAssignmentPlan(section: BCRSection, row: Int, group: String) -> BulkAssignmentPlan? {
        do { return try BulkAssignmentPlan(configuration: configuration, section: section, row: row, group: group) }
        catch { report(error); return nil }
    }

    @discardableResult
    func applyBulkAssignment(_ plan: BulkAssignmentPlan) -> Bool {
        do {
            notice = ConsoleNotice(level: .info, message: "已批量分配 \(plan.changes.count) 个控件。")
            try session.applyBulkAssignment(plan)
            return session.lastConfigurationPersistenceError == nil
        } catch { report(error); return false }
    }

    func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) {
        guard session.beginLearning(at: control, format: format) else {
            notice = ConsoleNotice(level: .warning, message: "Mock 设备的预设已知，学习只用于实体 BCR2000。")
            return
        }
        selectedControl = control
        notice = ConsoleNotice(
            level: .info,
            message: "学习中：请操作实体 \(control.shortName)。完成后会自动跳到本区下一个未学习控件，可连续扫过整排。"
        )
    }

    func parameterFractionDigits(_ id: ParameterID) -> Int {
        configuration.controls(targetingParameter: id).contains {
            configuration.assignment(for: $0)?.encoderMode != .absolute || engine.hardwareMap.midi(for: $0)?
                .kind == .nrpn
        } ? 3 : 0
    }

    func setMockNRPN(_ enabled: Bool, for control: BCRControlID) {
        do { try session.setMockNRPN(enabled, for: control) }
        catch { report(error) }
    }

    func stopLearning() {
        session.stopLearning()
        notice = ConsoleNotice(
            level: .info,
            message: "学习已停止，已学习 \(learnedCount) / \(BCRLayout.allControls.count) 个控件。"
        )
    }

    func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        session.unbind(control)
    }

    func setHardwareButtonFunctions(_ entry: HardwareMapEntry, enabled: Bool) {
        guard canChangeHardwareButtonFunctions, !entry.control.isContinuous else {
            notice = ConsoleNotice(level: .warning, message: "当前无法更改按键功能，请结束学习或设备操作后重试。")
            return
        }
        var map = session.learnedHardwareMap
        guard map.entries.first(where: { $0.control == entry.control }) == entry else {
            notice = ConsoleNotice(level: .warning, message: "按键绑定已改变，请重新确认。")
            return
        }
        do {
            try map.bind(entry.control, to: entry.midi, ringMode: entry.ringMode,
                         visualizationOnly: !enabled, pressMode: entry.pressMode)
            try session.installHardwareMap(map)
            // installHardwareMap reports persistence errors through the existing session event path.
        } catch { report(error) }
    }

    func resetHardwareMap() {
        guard source == .hardware else { return }
        notice = ConsoleNotice(level: .info, message: "实体映射已清空，请重新学习。")
        session.resetHardwareMap()
    }

    func clearMonitor() {
        session.clearMonitor()
    }

    func clearNotice() {
        notice = nil
    }

    private func saveMigration() {
        do {
            if let map = migratedHardwareMap { try hardwareFile.save(map) }
            if migratedConfiguration { try configurationFile.save(configuration) }
            migratedHardwareMap = nil; migratedConfiguration = false
            persistenceNotice = nil
            notice = ConsoleNotice(level: .info, message: "已保存升级后的文件，原文件已备份在同一目录。")
        } catch {
            persistenceNotice = ConsoleNotice(level: .error,
                                              message: "保存升级失败：\(error: error)",
                                              action: .saveMigration)
        }
    }

    func clearPersistenceNotice() {
        persistenceNotice = nil
    }

    func performNoticeAction(_ action: ConsoleNotice.Action) {
        switch action {
        case .switchToHardware:
            requestSource(.hardware)
        case .saveMigration:
            saveMigration()
        case .retryConfigurationSave:
            session.retryConfigurationPersistence()
            if session.lastConfigurationPersistenceError == nil {
                notice = ConsoleNotice(level: .info, message: "配置已保存。")
            }
        }
    }

    func selectPage(_ id: String) throws { try session.selectPage(id) }

    func updatePrograms(_ candidate: SurfaceConfiguration) throws { try session.updatePrograms(candidate) }

    func readConfiguration(from url: URL) throws -> SurfaceConfiguration {
        try ConfigurationTransfer.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    @discardableResult
    func installConfiguration(_ candidate: SurfaceConfiguration) -> Bool {
        do {
            let candidate = try candidate.migrated()
            // Commit the durable configuration before changing the live engine.
            try configurationFile.save(candidate)
            notice = ConsoleNotice(
                level: .info,
                message: "已导入“\(BuiltInNamePresentation.displayName(candidate.name))”；实体映射保留。"
            )
            try session.replaceConfiguration(candidate, persist: false)
            return true
        } catch { report(error); return false }
    }

    private func presentConfigurationPanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse? {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil
        }) else {
            notice = ConsoleNotice(level: .error, message: "无法打开配置面板：请先关闭其他对话框。")
            return nil
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    func chooseConfigurationImport() async -> SurfaceConfiguration? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入参数与功能分配")
        panel.prompt = L10n.text("导入")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response = await presentConfigurationPanel(panel)
        guard response == .OK, let url = panel.url else { return nil }
        do { return try readConfiguration(from: url) }
        catch {
            notice = ConsoleNotice(level: .error, message: "配置导入失败：\(error: error)")
            return nil
        }
    }

    func exportConfiguration(to url: URL) throws {
        let data = try ConfigurationTransfer.encode(configuration)
        if url.standardizedFileURL == configurationFile.store.fileURL.standardizedFileURL {
            try configurationFile.save(configuration)
        } else {
            try JSONFileStore<SurfaceConfiguration>(fileURL: url).writeEncoded(data)
        }
    }

    func chooseConfigurationExport() async {
        let panel = NSSavePanel()
        panel.title = L10n.text("导出参数与功能分配")
        panel.prompt = L10n.text("导出")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "surface-configuration.json"
        panel.canCreateDirectories = true
        let response = await presentConfigurationPanel(panel)
        guard response == .OK, let url = panel.url else { return }
        do {
            try exportConfiguration(to: url)
            notice = ConsoleNotice(level: .info, message: "配置已导出，不含实体映射。")
        } catch {
            notice = ConsoleNotice(level: .error, message: "配置导出失败：\(error: error)")
        }
    }
}
