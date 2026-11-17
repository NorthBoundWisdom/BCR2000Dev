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
final class ConsoleRecoveryWork: ObservableObject, ConsoleDeviceOwner, ConsoleConnectionRecoveryPort {
    let context: ConsoleDeviceContext
    private let preset: any ConsolePresetReadPort
    private let gate: ConsolePresetOperationGate
    private let store: ConsoleRecoveryStore
    var isConnecting: @MainActor () -> Bool = { false }
    private var connectingHardware: Bool { isConnecting() }
    private(set) var pendingPresetRestore: PendingPresetRestore?
    private(set) var restoreTask: Task<Void, Never>?
    private var restoreTaskID: UUID?
    private var restoreRoute: MIDIConnectionSnapshot?
    private var presetOperationID: UUID? { gate.id }
    private var presetAlignment: PresetAlignmentState? {
        get { preset.presetAlignment } set { preset.presetAlignment = newValue }
    }

    private var displayReadTask: Task<Void, Never>? { preset.displayReadTask }
    private var presetNumberEvidence: PresetNumberEvidence? {
        get { preset.presetNumberEvidence } set { preset.presetNumberEvidence = newValue }
    }

    private var verifiedDisplayNames: (route: MIDIConnectionSnapshot, names: BCRPresetNames)? {
        preset.verifiedDisplayNames
    }

    var presetRestorePoint: PresetRestorePoint? { store.presetRestorePoint }
    private var presetBackupDirectory: URL { store.presetBackupDirectory }
    init(context: ConsoleDeviceContext, preset: any ConsolePresetReadPort,
         gate: ConsolePresetOperationGate, store: ConsoleRecoveryStore)
    {
        self.context = context; self.preset = preset; self.gate = gate; self.store = store
    }

    func clearPendingContext() { pendingPresetRestore = nil }
    func validateConnectionWork() {
        if let route = restoreRoute, source != .hardware || !connection.hasSameRoute(as: route) || isLearning {
            restoreTask?.cancel()
        }
    }

    private func beginPresetWork(route: MIDIConnectionSnapshot) -> UUID {
        preset.cancelAlignment(); restoreTask?.cancel()
        let id = gate.begin(route: route)
        restoreTaskID = id; restoreRoute = route
        return id
    }

    private func finishPresetWork(_ id: UUID) {
        if restoreTaskID == id {
            gate.finish(id); restoreTask = nil; restoreTaskID = nil; restoreRoute = nil
        }
    }

    private func requirePresetRoute(_ route: MIDIConnectionSnapshot) throws { try preset.requirePresetRoute(route) }
    private func presetNames(on route: MIDIConnectionSnapshot) async throws -> BCRPresetNames {
        try await preset.presetNames(on: route)
    }

    private func invalidateDisplayNumber() { preset.invalidateDisplayNumber() }
    private func rememberPresetNumber(_ number: Int?, dump: Data, names: BCRPresetNames,
                                      route: MIDIConnectionSnapshot, originalDefinition: [String]? = nil,
                                      uniquenessProven: Bool = false) throws
    {
        try preset.rememberPresetNumber(number, dump: dump, names: names, route: route,
                                        originalDefinition: originalDefinition, uniquenessProven: uniquenessProven)
    }

    private func updateDisplayProfile(from dump: Data) { preset.updateDisplayProfile(from: dump) }
    private func installVerifiedMap(_ map: HardwareMap) throws { try preset.installVerifiedMap(map) }
    private func saveRestorePoint(_ point: PresetRestorePoint?) throws { try store.saveRestorePoint(point) }
    private func restoreDump(_ point: PresetRestorePoint) throws -> Data { try store.restoreDump(point) }
    private func matchesRestoreContext(_ current: Data, point: PresetRestorePoint, backup: Data) throws -> Bool {
        try store.matchesRestoreContext(current, point: point, backup: backup)
    }

    private var restoreUnavailableMessage: LocalizedMessage? {
        guard let point = presetRestorePoint else { return "没有可用的恢复点。" }
        guard canConfigureMIDI, midi.supportsStartupConfiguration else { return "当前设备不支持预设读写。" }
        guard source == .hardware, connection.isConnected else { return "请先在实体模式下连接原设备。" }
        guard !isLearning, !connectingHardware else { return "请先结束学习或连接操作。" }
        guard presetAlignment?.phase.isBusy != true,
              pendingPresetRestore == nil else { return "请先结束当前预设操作。" }
        guard let savedRoute = point.route, point.expectedPreset != nil, point.expectedHardwareMap != nil,
              point.backupDigest != nil,
              (point.acknowledgedLines ?? 0) > 0
        else {
            return "恢复点缺少已验证的设备上下文；备份保留，但不能自动写入。"
        }
        guard savedRoute.matches(connection) else { return "当前设备路由与恢复点不同，禁止恢复。" }
        return nil
    }

    var restoreUnavailableReason: String? { restoreUnavailableMessage.map { L10n.text($0) } }

    var canRestorePreset: Bool { restoreUnavailableReason == nil }

    var canDiscardPresetRestore: Bool {
        presetRestorePoint != nil && presetAlignment?.phase.isBusy != true && pendingPresetRestore == nil
    }

    var canRevealPresetBackups: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: presetBackupDirectory.path, isDirectory: &directory)
            && directory.boolValue
    }

    func restorePresetBeforeAlignment() {
        do { try session.requireHardwareAccess("gui_restore") } catch { report(error); return }
        guard canRestorePreset, let point = presetRestorePoint else {
            notice = ConsoleNotice(level: .warning, message: restoreUnavailableMessage ?? "没有可用的恢复点。")
            return
        }
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        let route = connection, id = beginPresetWork(route: connection)
        presetAlignment = PresetAlignmentState(phase: .reading)
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            do {
                let dump = try self.restoreDump(point)
                let names = try await self.presetNames(on: route)
                let backupName = try BCRDisplayProfile.read(fromPresetDump: dump).name
                guard names.temporaryName == backupName else {
                    throw PresetOperationError("当前预设名称与恢复备份不同，禁止恢复。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try self.matchesRestoreContext(current, point: point, backup: dump) else {
                    throw PresetOperationError("当前预设已改变，不能自动恢复旧备份。")
                }
                let context = PendingPresetRestore(point: point, dump: dump, route: route,
                                                   currentMap: self.session.learnedHardwareMap)
                if context.currentMap != point.expectedHardwareMap {
                    self.pendingPresetRestore = context
                    self.presetAlignment?.phase = .restoreConfirmation
                    return
                }
                try await self.performPresetRestore(context)
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("恢复失败：\(error: error)")
            }
        }
    }

    func confirmPresetRestoreReplacingLearning() {
        do { try session.requireHardwareAccess("gui_restore") } catch { report(error); return }
        guard let context = pendingPresetRestore else { return }
        pendingPresetRestore = nil
        let id = beginPresetWork(route: context.route)
        presetAlignment?.phase = .reading
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            do {
                try self.requirePresetRoute(context.route)
                guard self.session.learnedHardwareMap == context.currentMap else {
                    throw PresetOperationError("确认期间映射再次改变，请重新检查恢复操作。")
                }
                let names = try await self.presetNames(on: context.route)
                guard names.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: context.dump).name) else {
                    throw PresetOperationError("当前预设名称与恢复备份不同，禁止恢复。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(context.route)
                guard try self.matchesRestoreContext(current, point: context.point, backup: context.dump) else {
                    throw PresetOperationError("当前预设已改变，不能自动恢复旧备份。")
                }
                let archive = try PresetMapArchiveStore(directory: self.presetBackupDirectory).save(context.currentMap)
                self.notice = ConsoleNotice(level: .info, message: "替换前的映射备份：\(archive.path)")
                try await self.performPresetRestore(context, mapArchive: archive)
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("恢复失败：\(error: error)")
            }
        }
    }

    func cancelPresetRestore() {
        guard pendingPresetRestore != nil else { return }
        pendingPresetRestore = nil
        presetAlignment = nil
        notice = ConsoleNotice(level: .info, message: "已取消恢复，设备与映射未改动。")
    }

    private func performPresetRestore(_ context: PendingPresetRestore, mapArchive: URL? = nil) async throws {
        try requirePresetRoute(context.route)
        guard session.learnedHardwareMap == context.currentMap, presetRestorePoint == context.point else {
            throw PresetOperationError("恢复上下文已改变，请重新确认。")
        }
        let carriedEvidence = try presetNumberEvidence.flatMap { evidence -> PresetNumberEvidence? in
            guard evidence.locked, let expected = context.point.expectedPreset,
                  let names = verifiedDisplayNames?.names,
                  try evidence.matches(expected, names: names, on: context.route) else { return nil }
            return evidence
        }
        presetNumberEvidence = nil
        invalidateDisplayNumber()
        var writingPoint = context.point
        writingPoint.restoreAttempted = true
        try saveRestorePoint(writingPoint)
        let frames = Array(context.dump).split(separator: 0xF7, omittingEmptySubsequences: true)
            .map { Array($0) + [0xF7] }
        presetAlignment?.phase = .restoring
        presetAlignment?.restoreProgress = (0, frames.count)
        try await withDisplayTransfer(.write) {
            try await self.midi.sendPresetFrames(frames) { [weak self] done in
                guard let self else { return }
                self.presetAlignment?.restoreProgress = (done, frames.count)
                if self.source != .hardware || !self.connection.hasSameRoute(as: context.route) || self.isLearning {
                    self.restoreTask?.cancel()
                }
            }
        }
        try requirePresetRoute(context.route)
        presetAlignment?.phase = .verifying
        let readback = try await withDisplayTransfer { try await self.midi.readCurrentPreset() }
        try requirePresetRoute(context.route)
        guard try BCRPresetAlignment.canonicalLines(of: readback) == BCRPresetAlignment
            .canonicalLines(of: context.dump)
        else {
            throw PresetOperationError("恢复回读与备份内容不一致；恢复点已保留。")
        }
        guard session.learnedHardwareMap == context.currentMap else {
            throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
        }
        let finalNames = try await presetNames(on: context.route)
        guard finalNames.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: readback).name),
              session.learnedHardwareMap == context.currentMap
        else {
            throw PresetOperationError("写入期间预设或映射已改变，未覆盖当前映射。")
        }
        let restoredLocked = try BCRDisplayProfile.read(fromPresetDump: readback).locked == true
        let restoredDefinition = try BCRPresetAlignment.identityLines(of: readback)
        if let evidence = carriedEvidence, evidence.matches(finalNames, on: context.route),
           restoredLocked || restoredDefinition == evidence.originalDefinition
        {
            try rememberPresetNumber(evidence.number, dump: readback, names: finalNames, route: context.route,
                                     originalDefinition: evidence.originalDefinition,
                                     uniquenessProven: evidence.uniquenessProven)
        } else if let proven = try preset.rememberedPresetNumber(
            for: readback,
            names: finalNames,
            route: context.route
        ) {
            // Evidence rebuilt after a restart lacks the original definition, but the restored document
            // itself may have a content-uniqueness proof on this route (from the preview before the
            // alignment). Only such proofs qualify; manual session confirmations never do.
            try rememberPresetNumber(proven, dump: readback, names: finalNames, route: context.route,
                                     uniquenessProven: true)
        }
        updateDisplayProfile(from: readback)
        try installVerifiedMap(context.point.hardwareMap)
        try saveRestorePoint(context.point.previous)
        session.synchronize()
        presetAlignment?.canRestore = canRestorePreset
        presetAlignment?.phase = .finished
        notice = ConsoleNotice(level: .info, message: mapArchive.map { archive -> LocalizedMessage in
            "已恢复预设；替换前的映射备份：\(archive.path)"
        } ?? "已回读确认并恢复设备临时预设和本机映射。")
    }

    func discardPresetRestore(_ confirmed: PresetRestorePoint) {
        guard canDiscardPresetRestore, presetRestorePoint == confirmed else { return }
        do {
            try saveRestorePoint(confirmed.previous)
            presetAlignment?.canRestore = canRestorePreset
            notice = ConsoleNotice(level: .info, message: "已丢弃当前恢复层；设备、映射和预设备份未改动。")
        } catch { report(error) }
    }

    func revealPresetBackups(file: URL? = nil) {
        if let file {
            guard FileManager.default.fileExists(atPath: file.path) else {
                notice = ConsoleNotice(level: .warning, message: "备份文件已不存在。")
                return
            }
            guard !skipsFinderWhenOffscreen() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            guard canRevealPresetBackups else {
                notice = ConsoleNotice(level: .info, message: "尚无预设备份。")
                return
            }
            guard !skipsFinderWhenOffscreen() else { return }
            if !NSWorkspace.shared.open(presetBackupDirectory) {
                notice = ConsoleNotice(level: .error, message: "无法打开备份文件夹。")
            }
        }
    }

    private func skipsFinderWhenOffscreen() -> Bool {
        guard OffscreenPresentation.isEnabled else { return false }
        notice = ConsoleNotice(level: .info, message: "离屏测试模式不打开访达。")
        return true
    }
}
