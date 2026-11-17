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
protocol ConsolePresetReadPort: AnyObject {
    var displayReadTask: Task<Void, Never>? { get }
    var presetAlignment: PresetAlignmentState? { get set }
    var presetNumberEvidence: PresetNumberEvidence? { get set }
    var verifiedDisplayNames: (route: MIDIConnectionSnapshot, names: BCRPresetNames)? { get }
    func rememberedPresetNumber(for dump: Data, names: BCRPresetNames, route: MIDIConnectionSnapshot) throws -> Int?
    func cancelAlignment()
    func requirePresetRoute(_ route: MIDIConnectionSnapshot) throws
    func presetNames(on route: MIDIConnectionSnapshot) async throws -> BCRPresetNames
    func invalidateDisplayNumber()
    func rememberPresetNumber(_ number: Int?, dump: Data, names: BCRPresetNames,
                              route: MIDIConnectionSnapshot, originalDefinition: [String]?,
                              uniquenessProven: Bool) throws
    func updateDisplayProfile(from dump: Data)
    func installVerifiedMap(_ map: HardwareMap) throws
}

@MainActor
final class ConsolePresetWork: ObservableObject, ConsoleDeviceOwner, ConsolePresetReadPort,
    ConsoleConnectionPresetPort
{
    let context: ConsoleDeviceContext
    let gate: ConsolePresetOperationGate
    let recoveryStore: ConsoleRecoveryStore
    weak var recovery: ConsoleRecoveryWork?
    var isConnecting: @MainActor () -> Bool = { false }
    var isStarting: @MainActor () -> Bool = { false }
    var connectingHardware: Bool { isConnecting() }
    var startingMIDI: Bool { isStarting() }
    @Published private(set) var displayProfile: BCRDisplayProfile?
    private let displayProfileStore: JSONFileStore<BCRDisplayProfile>
    private let presetNumberMemory: PresetNumberMemory
    @Published var presetAlignment: PresetAlignmentState?
    private var presetDump: Data?
    private var presetPreviewRoute: MIDIConnectionSnapshot?
    private var presetPreviewMap: HardwareMap?
    private var presetPreviewConfiguration: SurfaceConfiguration?
    private(set) var alignmentTask: Task<Void, Never>?
    private var alignmentTaskID: UUID?
    private var alignmentRoute: MIDIConnectionSnapshot?
    private(set) var displayReadTask: Task<Void, Never>?
    private var displayReadID: UUID?
    var presetNumberEvidence: PresetNumberEvidence?
    private var latestDisplayDump: (route: PresetRestoreRoute, dump: Data)?
    @Published private(set) var pendingPresetNumberConfirmation: PresetNumberConfirmation?
    @Published private(set) var selectedPresetNumber: Int?
    private(set) var verifiedDisplayNames: (route: MIDIConnectionSnapshot, names: BCRPresetNames)?
    private var pendingPresetRestore: PendingPresetRestore? { recovery?.pendingPresetRestore }
    private var presetOperationID: UUID? { gate.id }
    private var presetRestorePoint: PresetRestorePoint? { recoveryStore.presetRestorePoint }
    private var canRestorePreset: Bool { recovery?.canRestorePreset ?? false }
    var display: BCRDisplayModel { presentation.display }
    var backgroundTasks: [Task<Void, Never>] { [displayReadTask, alignmentTask].compactMap { $0 } }
    var presetSourceSwitchBlocked: Bool {
        presetAlignment?.phase.isBusy == true || pendingPresetRestore != nil || gate.id != nil
    }

    init(context: ConsoleDeviceContext, gate: ConsolePresetOperationGate,
         recoveryStore: ConsoleRecoveryStore, directory: URL)
    {
        self.context = context; self.gate = gate; self.recoveryStore = recoveryStore
        displayProfileStore = JSONFileStore(fileURL: directory.appending(path: "display-profile.json"))
        displayProfile = try? displayProfileStore.load()
        presetNumberMemory = PresetNumberMemory(store: JSONFileStore(fileURL:
            directory.appending(path: "preset-number-evidence.json")))
    }

    func clearNumberContext() {
        presetNumberEvidence = nil
        latestDisplayDump = nil; pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
    }

    func cancelDisplayReadAndClearNumberContext() {
        displayReadTask?.cancel(); clearNumberContext()
    }

    func rememberedPresetNumber(for dump: Data, names: BCRPresetNames, route: MIDIConnectionSnapshot) throws -> Int? {
        try presetNumberMemory.number(for: dump, names: names, route: route)
    }

    func cancelAlignment() { alignmentTask?.cancel() }
    func validateConnectionWork() {
        if source != .hardware || !connection.isConnected || isLearning { displayReadTask?.cancel() }
        if let route = alignmentRoute, source != .hardware || !connection.hasSameRoute(as: route) || isLearning {
            alignmentTask?.cancel()
        }
    }

    func saveRestorePoint(_ point: PresetRestorePoint?) throws { try recoveryStore.saveRestorePoint(point) }
    func saveBackup(_ dump: Data) throws -> URL { try recoveryStore.saveBackup(dump) }
    var deviceKeysLocked: Bool? { source == .hardware ? displayProfile?.locked : nil }

    var displayPresetName: String? { source == .hardware ? displayProfile?.name : nil }

    var canCheckDisplayPresetNumber: Bool {
        canConfigureMIDI && midi.supportsStartupConfiguration && source == .hardware && connection.isConnected
            && !presetSourceSwitchBlocked && !isLearning && !startingMIDI
    }

    var canAlignPreset: Bool {
        canConfigureMIDI && midi.supportsStartupConfiguration && source == .hardware && connection.isConnected
            && !isLearning && !connectingHardware && presetAlignment?.phase.isBusy != true
            && pendingPresetRestore == nil
    }

    private func acceptDisplayNames(_ names: BCRPresetNames, route: MIDIConnectionSnapshot) {
        verifiedDisplayNames = (route, names)
        let candidates = names.candidates
        if let evidence = presetNumberEvidence, !evidence.matches(names, on: route) { presetNumberEvidence = nil }
        let carried = presetNumberEvidence.flatMap { $0.locked ? $0.number : nil }
        let number = carried ?? names.presetNumber
        setDisplayPreset(number)
        if displayProfile?.name == names.temporaryName {
            displayProfile?.resolvedPreset = number
            displayProfile?.resolvedCandidates = candidates
            if let profile = displayProfile {
                do { try displayProfileStore.save(profile) } catch { report(error) }
            }
        } else {
            displayProfile?.resolvedPreset = nil
            displayProfile?.resolvedCandidates = nil
        }
    }

    func invalidateDisplayNumber() {
        verifiedDisplayNames = nil
        setDisplayPreset(nil)
    }

    func refreshDisplayFromDevice() {
        do { try session.requireHardwareAccess("gui_preset") } catch { report(error); return }
        guard canConfigureMIDI, midi.supportsStartupConfiguration, source == .hardware, connection.isConnected,
              presetAlignment?.phase.isBusy != true, pendingPresetRestore == nil else { return }
        let previous = displayReadTask
        previous?.cancel()
        let route = connection, id = UUID()
        displayReadID = id
        displayReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.displayReadID == id { self.displayReadTask = nil; self.displayReadID = nil } }
            await previous?.value
            var freshNames: BCRPresetNames?
            do {
                let names = try await self.presetNames(on: route)
                freshNames = names
                let needsNumber = self.display.preset == nil && names.candidates.count > 1
                let temporary = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                self.updateDisplayProfile(from: temporary)
                self.syncRingModes(from: temporary, route: route)
                if needsNumber {
                    try await self.resolveDisplayNumber(temporary: temporary, names: names, route: route)
                }
            } catch {
                guard self.displayReadID == id, !Task.isCancelled,
                      self.source == .hardware, self.connection.hasSameRoute(as: route), !self.isLearning
                else { return }
                if let number = freshNames?.presetNumber {
                    self.setDisplayPreset(number)
                    self.notice = ConsoleNotice(level: .warning,
                                                message: "未能读取设备显示设置或同步灯环：\(error: error)")
                } else {
                    self.invalidateDisplayNumber()
                    if !(error is CancellationError) {
                        self.notice = ConsoleNotice(level: .warning,
                                                    message: "未能核对预设编号，显示未知：\(error: error)")
                    }
                }
            }
        }
    }

    func rememberPresetNumber(_ number: Int?, dump: Data, names: BCRPresetNames,
                              route: MIDIConnectionSnapshot, originalDefinition: [String]? = nil,
                              uniquenessProven: Bool = false) throws
    {
        let evidence = try PresetNumberEvidence(number: number, dump: dump, names: names, route: route,
                                                originalDefinition: originalDefinition,
                                                uniquenessProven: uniquenessProven)
        guard number == nil || evidence != nil else {
            throw PresetOperationError("编号证据与当前预设不一致，请重新核对。")
        }
        presetNumberEvidence = evidence
        // Persist the provenance too: session-only confirmations must not become restart proofs.
        if let evidence {
            do { try presetNumberMemory.remember(evidence) } catch { report(error) }
        }
        setDisplayPreset(number)
        displayProfile?.resolvedPreset = number
        displayProfile?.resolvedCandidates = names.candidates
        if let profile = displayProfile { try displayProfileStore.save(profile) }
    }

    private func resolveDisplayNumber(temporary: Data, names: BCRPresetNames,
                                      route: MIDIConnectionSnapshot) async throws
    {
        try requirePresetRoute(route)
        if let evidence = presetNumberEvidence, try evidence.matches(temporary, names: names, on: route) {
            try rememberPresetNumber(evidence.number, dump: temporary, names: names, route: route,
                                     originalDefinition: evidence.originalDefinition,
                                     uniquenessProven: evidence.uniquenessProven)
            return
        }
        let profile = try BCRDisplayProfile.read(fromPresetDump: temporary)
        // A number proven earlier (also before a restart) for exactly this definition on this route.
        let remembered = try presetNumberMemory.number(for: temporary, names: names, route: route)
        if let number = names.presetNumber ?? remembered {
            try rememberPresetNumber(number, dump: temporary, names: names, route: route,
                                     uniquenessProven: remembered == number)
            return
        }
        presetNumberEvidence = nil
        let candidates = names.candidates
        // A locked copy without proof is usually an aligned (edited) copy that can never match a
        // stored slot; two more full dumps (~24 s of device busy time) on every connection would be
        // futile. Such copies use the recorded proof above or the explicit screen confirmation.
        guard profile.locked != true, candidates.count > 1, candidates.count <= 4 else { return }
        var dumps: [Int: Data] = [:]
        for number in candidates {
            try requirePresetRoute(route)
            dumps[number] = try await withDisplayTransfer { try await self.midi.readMemoryPreset(number) }
        }
        let latest = try await presetNames(on: route)
        guard latest.temporaryName == names.temporaryName, latest.candidates == candidates else { return }
        let number = try BCRPresetNames.resolve(temporary: temporary, candidates: dumps)
        try rememberPresetNumber(number, dump: temporary, names: latest, route: route,
                                 uniquenessProven: number != nil)
    }

    private func tryResolveDisplayNumber(temporary: Data, names: BCRPresetNames,
                                         route: MIDIConnectionSnapshot) async throws
    {
        do { try await resolveDisplayNumber(temporary: temporary, names: names, route: route) }
        catch {
            try requirePresetRoute(route)
            presetNumberEvidence = nil
            invalidateDisplayNumber()
            notice = ConsoleNotice(level: .warning,
                                   message: "未能核对预设编号，显示未知：\(error: error)")
        }
    }

    func updateDisplayProfile(from dump: Data) {
        do {
            var profile = try BCRDisplayProfile.read(fromPresetDump: dump)
            latestDisplayDump = (PresetRestoreRoute(connection), dump)
            if let context = verifiedDisplayNames, connection.hasSameRoute(as: context.route),
               context.names.temporaryName == profile.name
            {
                let evidence = presetNumberEvidence
                if let evidence, try !evidence.matches(dump, names: context.names, on: context.route) {
                    presetNumberEvidence = nil
                }
                profile.resolvedPreset = presetNumberEvidence?.number ?? context.names.presetNumber
                profile.resolvedCandidates = context.names.candidates
            } else { presetNumberEvidence = nil }
            displayProfile = profile
            setDisplayPreset(profile.resolvedPreset)
            // The profile is a disposable settings cache, never a source of number evidence.
            // Fresh device data must repair malformed JSON instead of reloading it here.
            try displayProfileStore.save(profile)
        } catch { report(error) }
    }

    private func syncRingModes(from dump: Data, route: MIDIConnectionSnapshot) {
        guard source == .hardware, connection.hasSameRoute(as: route), !isLearning else { return }
        do {
            let (map, changed) = try BCRPresetAlignment.syncingRingModes(session.learnedHardwareMap, with: dump)
            guard !changed.isEmpty else { return }
            try installVerifiedMap(map)
            notice = ConsoleNotice(level: .info,
                                   message: "已按设备当前预设更新 \(changed.count) 个旋钮的灯环显示模式；未写入设备。")
        } catch { report(error) }
    }

    func requestPresetNumberConfirmation() {
        do { try session.requireHardwareAccess("gui_preset") } catch { report(error); return }
        guard canCheckDisplayPresetNumber else { return }
        pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
        let previous = displayReadTask
        previous?.cancel()
        let route = connection, id = UUID()
        displayReadID = id
        displayReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.displayReadID == id { self.displayReadID = nil; self.displayReadTask = nil } }
            await previous?.value
            do {
                let names = try await self.presetNames(on: route)
                let dump: Data
                if let recent = self.latestDisplayDump, recent.route.matches(route),
                   self.displayProfile?.locked == true,
                   (try BCRDisplayProfile.read(fromPresetDump: recent.dump).name) == names.temporaryName
                {
                    dump = recent.dump
                } else { dump = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() } }
                try self.requirePresetRoute(route)
                self.updateDisplayProfile(from: dump)
                guard !names.candidates.isEmpty else {
                    throw PresetOperationError("当前名称没有对应的存储预设，无法确认编号。")
                }
                self.pendingPresetNumberConfirmation = PresetNumberConfirmation(route: PresetRestoreRoute(route),
                                                                                dump: dump, names: names)
            } catch {
                guard self.displayReadID == id, !Task.isCancelled else { return }
                self.report(error)
            }
        }
    }

    func selectDisplayPresetNumber(_ id: UUID, number: Int) {
        guard let context = pendingPresetNumberConfirmation, context.id == id,
              context.route.matches(connection), context.names.candidates.contains(number) else { return }
        selectedPresetNumber = number
    }

    func confirmDisplayPresetNumber(_ id: UUID, number: Int) {
        guard let context = pendingPresetNumberConfirmation, context.id == id,
              canCheckDisplayPresetNumber, context.route.matches(connection), context.names.candidates.contains(number),
              latestDisplayDump?.dump == context.dump,
              verifiedDisplayNames?.names == context.names else { return }
        do {
            let matchingEvidence = try presetNumberEvidence.flatMap { evidence -> PresetNumberEvidence? in
                guard evidence.number == number,
                      try evidence.matches(context.dump, names: context.names, on: connection) else { return nil }
                return evidence
            }
            let inSessionProof = matchingEvidence?.uniquenessProven ?? false
            let recordedProof = try presetNumberMemory.number(for: context.dump, names: context.names,
                                                              route: connection) == number
            let uniquenessProven = inSessionProof || recordedProof
            try rememberPresetNumber(number, dump: context.dump, names: context.names, route: connection,
                                     originalDefinition: matchingEvidence?.originalDefinition,
                                     uniquenessProven: uniquenessProven)
            pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
            notice = ConsoleNotice(level: .info, message: uniquenessProven
                ? "已确认预设编号 \(number)；已有内容唯一性证明，定义一致时可跨连接恢复，不写入设备。"
                : "已按实机屏幕确认预设编号 \(number)；未证明内容唯一性，仅本次连接有效，不写入设备。")
        } catch { report(error) }
    }

    func cancelPresetNumberConfirmation() { pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil }

    func requirePresetRoute(_ route: MIDIConnectionSnapshot) throws {
        try Task.checkCancellation()
        guard canConfigureMIDI, midi.supportsStartupConfiguration, source == .hardware,
              connection.isConnected, connection.hasSameRoute(as: route), !isLearning
        else {
            throw PresetOperationError("设备连接或操作状态已改变，已停止预设操作。")
        }
    }

    func presetNames(on route: MIDIConnectionSnapshot) async throws -> BCRPresetNames {
        try requirePresetRoute(route)
        invalidateDisplayNumber()
        let names = try await withDisplayTransfer { try await self.midi.readPresetNames() }
        try requirePresetRoute(route)
        acceptDisplayNames(names, route: route)
        return names
    }

    func beginPresetAlignment(options: BCRPresetAlignment.Options = .init()) {
        do { try session.requireHardwareAccess("gui_preset") } catch { report(error); return }
        guard canAlignPreset else {
            notice = ConsoleNotice(level: .warning, message: "请先在实体模式下连接 BCR2000，并停止学习。")
            return
        }
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        presetAlignment = PresetAlignmentState(phase: .reading, options: options)
        presetDump = nil; presetPreviewRoute = nil
        let route = connection, id = beginPresetWork(route: connection)
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            do {
                do { _ = try await self.presetNames(on: route) }
                catch {
                    try self.requirePresetRoute(route)
                    self.notice = ConsoleNotice(level: .warning,
                                                message: "未能核对预设编号，显示未知：\(error: error)")
                }
                let dump = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                self.presetDump = dump; self.presetPreviewRoute = route
                self.updateDisplayProfile(from: dump)
                self.syncRingModes(from: dump, route: route)
                if let context = self.verifiedDisplayNames {
                    try await self.tryResolveDisplayNumber(temporary: dump, names: context.names, route: route)
                }
                self.presetAlignment?.backup = try self.saveBackup(dump)
                self.presetAlignment?.phase = .preview
                self.recomputeAlignment()
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("读取设备预设失败：\(error: error)")
            }
        }
    }

    func setAlignmentOptions(_ options: BCRPresetAlignment.Options) {
        guard presetAlignment?.phase == .preview else { return }
        presetAlignment?.options = options
        recomputeAlignment()
    }

    private func recomputeAlignment() {
        guard let dump = presetDump, var state = presetAlignment else { return }
        do {
            state.plan = try BCRPresetAlignment.prepare(dump: dump, hardwareMap: session.learnedHardwareMap,
                                                        configuration: configuration, options: state.options)
            presetPreviewMap = session.learnedHardwareMap
            presetPreviewConfiguration = configuration
            state.planError = nil
        } catch {
            state.plan = nil
            state.planError = "\(error: error)"
        }
        presetAlignment = state
    }

    func installVerifiedMap(_ map: HardwareMap) throws {
        try session.installHardwareMap(map)
        guard try hardwareFile.store.load() == map else {
            throw PresetOperationError("硬件映射未能保存，恢复点已保留。")
        }
    }

    func applyPresetAlignment() {
        do { try session.requireHardwareAccess("gui_preset") } catch { report(error); return }
        guard var state = presetAlignment, state.phase == .preview, let plan = state.plan, !plan.isEmpty,
              canAlignPreset, let route = presetPreviewRoute, let before = presetDump, let backup = state.backup,
              presetPreviewMap == session.learnedHardwareMap, presetPreviewConfiguration == configuration
        else {
            notice = ConsoleNotice(level: .warning, message: "请重新读取并确认设备预设预览。")
            return
        }
        do { try requirePresetRoute(route) } catch { report(error); return }
        let device = before[before.startIndex + 4]
        let frames = plan.frames(device: device)
        let previousMap = session.learnedHardwareMap, previousPoint = presetRestorePoint
        var point = PresetRestorePoint(backupFile: backup.lastPathComponent, hardwareMap: previousMap,
                                       createdAt: .now, route: PresetRestoreRoute(route),
                                       expectedPreset: Data(frames.joined()),
                                       expectedHardwareMap: previousMap, acknowledgedLines: 0,
                                       history: PresetRestorePoint.history(retaining: previousPoint),
                                       backupDigest: PresetBackupStore.digest(before))
        do { try saveRestorePoint(point) } catch { report(error); return }
        state.phase = .reading
        presetAlignment = state
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        let id = beginPresetWork(route: route)
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            var acknowledged = 0
            do {
                try self.requirePresetRoute(route)
                let names = try await self.presetNames(on: route)
                guard names.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: before).name) else {
                    throw PresetOperationError("预览后设备预设已改变，请重新读取。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try BCRPresetAlignment.deviceIdentifier(of: current) == device,
                      try BCRPresetAlignment.identityLines(of: current) == BCRPresetAlignment.identityLines(of: before)
                else {
                    throw PresetOperationError("预览后设备预设已改变，请重新读取。")
                }
                guard self.session.learnedHardwareMap == previousMap else {
                    throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
                }
                let carriedEvidence = try self.presetNumberEvidence.flatMap {
                    try $0.matches(current, names: names, on: route) ? $0 : nil
                }
                // A partial write may change the lock. Only verified completion can
                // install the carried proof for the new working copy.
                self.presetNumberEvidence = nil
                self.invalidateDisplayNumber()
                self.presetAlignment?.phase = .writing(done: 0, total: frames.count)
                try await self.withDisplayTransfer(.write) {
                    try await self.midi.sendPresetFrames(frames) { [weak self] done in
                        acknowledged = done
                        guard let self, self.presetOperationID == id else { return }
                        // Only positive acknowledgement is needed for crash recovery. Keep
                        // exact progress in memory and save the final count on completion/failure.
                        if (point.acknowledgedLines ?? 0) == 0 {
                            point.acknowledgedLines = done
                            do { try self.saveRestorePoint(point) }
                            catch { self.report(error); self.alignmentTask?.cancel() }
                        }
                        self.presetAlignment?.phase = .writing(done: done, total: frames.count)
                        if self.source != .hardware || !self.connection.hasSameRoute(as: route) || self.isLearning {
                            self.alignmentTask?.cancel()
                        }
                    }
                }
                try self.requirePresetRoute(route)
                self.presetAlignment?.phase = .verifying
                let readback = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try BCRPresetAlignment.readbackMatches(readback, expected: plan.lines) else {
                    throw PresetOperationError("回读与写入内容不一致")
                }
                guard self.session.learnedHardwareMap == previousMap else {
                    throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
                }
                let finalNames = try await self.presetNames(on: route)
                guard finalNames.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: readback).name),
                      self.session.learnedHardwareMap == previousMap
                else {
                    throw PresetOperationError("写入期间预设或映射已改变，未覆盖当前映射。")
                }
                if (try BCRDisplayProfile.read(fromPresetDump: readback).locked) == true,
                   finalNames.candidates == names.candidates
                {
                    try self.rememberPresetNumber(
                        carriedEvidence?.number,
                        dump: readback,
                        names: finalNames,
                        route: route,
                        originalDefinition: carriedEvidence?.originalDefinition,
                        uniquenessProven: carriedEvidence?.uniquenessProven ?? false
                    )
                } else { self.presetNumberEvidence = nil }
                self.updateDisplayProfile(from: readback)
                try self.installVerifiedMap(plan.hardwareMap)
                point.expectedPreset = readback; point.expectedHardwareMap = plan.hardwareMap
                point.acknowledgedLines = acknowledged
                try self.saveRestorePoint(point)
                self.session.synchronize()
                self.presetAlignment?.canRestore = true
                self.presetAlignment?.phase = .finished
                self.notice = ConsoleNotice(level: .info,
                                            message: "设备临时预设已对齐（\(plan.changes.count) 项）；未写入永久存储。")
            } catch {
                guard self.presetOperationID == id else { return }
                // With no acknowledgement there is no confirmed edit to undo. Keep the old level.
                if acknowledged == 0 {
                    do { try self.saveRestorePoint(previousPoint) } catch { self.report(error) }
                } else {
                    point.acknowledgedLines = acknowledged
                    // Never adopt an arbitrary unexpected readback as a trusted recovery context.
                    // Only the original or complete confirmed target document is trusted.
                    if self.source == .hardware, self.connection.hasSameRoute(as: route), !self.isLearning,
                       !Task.isCancelled,
                       let partial = try? await self.withDisplayTransfer(
                           .read,
                           { try await self.midi.readCurrentPreset() }
                       ),
                       (try? BCRPresetAlignment.deviceIdentifier(of: partial)) == device,
                       (try? BCRPresetAlignment.identityLines(of: partial)) ==
                       (try? BCRPresetAlignment.identityLines(of: before))
                    {
                        point.expectedPreset = before
                    }
                    do { try self.saveRestorePoint(point) } catch { self.report(error) }
                }
                let failure: LocalizedMessage = "写入设备预设失败：\(error: error)"
                let recovery: LocalizedMessage = " 永久存储未改动；备份已保留，部分写入可能无法自动恢复，可丢弃此恢复层。"
                self.presetAlignment?.phase = .failed("\(failure)\(recovery)")
                self.presetAlignment?.canRestore = self.canRestorePreset
            }
        }
    }

    private func beginPresetWork(route: MIDIConnectionSnapshot) -> UUID {
        alignmentTask?.cancel()
        let id = gate.begin(route: route)
        alignmentTaskID = id; alignmentRoute = route
        return id
    }

    private func finishPresetWork(_ id: UUID) {
        if alignmentTaskID == id {
            gate.finish(id); alignmentTask = nil; alignmentTaskID = nil; alignmentRoute = nil
        }
    }

    func dismissPresetAlignment() {
        guard presetAlignment?.phase.isBusy != true else { return }
        alignmentTask?.cancel(); alignmentTask = nil; alignmentTaskID = nil; alignmentRoute = nil
        gate.clear(); recovery?.clearPendingContext()
        presetAlignment = nil
    }

    private func setDisplayPreset(_ number: Int?) { presentation.setDisplayPreset(number) }
}
