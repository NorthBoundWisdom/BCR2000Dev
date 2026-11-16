import AppKit
import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
import BCRPersistenceAdapter
import Combine
import Foundation

/// UI observations and presentation timers only. Never authorizes or sends a device effect.
@MainActor
final class ConsolePresentationState: ObservableObject {
    let timing: ConsoleTiming
    let workspacePanelStore: JSONFileStore<WorkspacePanelSettings>
    let displayMarquee = DisplayMarqueeState()
    var isStartingMIDI: () -> Bool = { false }
    var selectGroup: ((Int) -> Void)?
    @Published var slots: [AgentSlotPresentation] = []
    @Published var notice: ConsoleNotice? { didSet { scheduleNoticeDismissal() } }
    @Published var persistenceNotice: ConsoleNotice? = nil
    @Published var visibleGroup: Int = 1
    @Published var workspacePanels: WorkspacePanelSettings = .init()
    @Published var selectedControl: BCRControlID? = .pushEncoder(group: 1, 1)
    @Published var followsTouch: Bool = true
    @Published var hardwarePressedControls: Set<BCRControlID> = []
    var display: BCRDisplayModel = .init()
    var deviceActivity: Bool = false
    var pendingTouchedControl: BCRControlID? = nil
    var uiPublishTask: Task<Void, Never>? = nil
    var displayRevertTask: Task<Void, Never>? = nil
    var activityTask: Task<Void, Never>? = nil
    var noticeDismissTask: Task<Void, Never>? = nil
    var pressTasks: [BCRControlID: Task<Void, Never>] = [:]
    var pressStarted: [BCRControlID: Double] = [:]
    init(timing: ConsoleTiming, workspacePanelStore: JSONFileStore<WorkspacePanelSettings>) {
        self.timing = timing; self.workspacePanelStore = workspacePanelStore
    }

    func scheduleFrame() {
        guard uiPublishTask == nil else { return }
        uiPublishTask = Task { @MainActor [weak self, timing] in
            do { try await timing.work.sleep(ConsoleTiming.frame) } catch { return }
            guard let self else { return }
            if self.followsTouch, let control = self.pendingTouchedControl {
                if self.selectedControl != control { self.selectedControl = control }
                if (control.section == .pushEncoder || control.section == .pushEncoderButton),
                   self.visibleGroup != control.row
                {
                    self.selectGroup?(control.row)
                }
            }
            self.pendingTouchedControl = nil
            self.objectWillChange.send()
            self.uiPublishTask = nil
        }
    }

    func beginTransfer(_ operation: BCRDisplayModel.TransferOperation) -> UUID {
        let token = display.beginTransfer(operation); objectWillChange.send(); return token
    }

    func endTransfer(_ token: UUID) { display.endTransfer(token); objectWillChange.send() }

    func setWorkspacePanel(_ panel: WorkspaceTab, enabled: Bool) -> Bool {
        do {
            var updated = workspacePanels
            try updated.set(panel, enabled: enabled)
            try workspacePanelStore.save(updated)
            workspacePanels = updated
            return true
        } catch {
            notice = ConsoleNotice(level: .error, message: "面板设置保存失败：\(error: error)")
            return false
        }
    }

    func noteDeviceActivity() {
        activityTask?.cancel()
        deviceActivity = true
        activityTask = Task { @MainActor [weak self, timing] in
            do { try await timing.presentation.sleep(ConsoleTiming.activity) } catch { return }
            self?.objectWillChange.send()
            self?.deviceActivity = false
        }
    }

    func clearDisplayedValue() {
        displayRevertTask?.cancel(); displayRevertTask = nil
        if display.transient != nil { objectWillChange.send(); display.clearTransient() }
    }

    func setDisplayPreset(_ preset: Int?) {
        display.setPreset(preset)
        objectWillChange.send()
    }

    func clearHardwarePresses() {
        for task in pressTasks.values { task.cancel() }
        pressTasks.removeAll(); pressStarted.removeAll()
        if !hardwarePressedControls.isEmpty { hardwarePressedControls.removeAll() }
    }

    private func scheduleNoticeDismissal() {
        noticeDismissTask?.cancel(); noticeDismissTask = nil
        guard let current = notice, current.level == .info, current.action == nil else { return }
        if isStartingMIDI(), current == ConsoleNotice(level: .info,
                                                      message: "正在启动 MIDI 服务；界面可继续使用，请等待设备就绪。") { return }
        noticeDismissTask = Task { @MainActor [weak self, timing] in
            do { try await timing.presentation.sleep(ConsoleTiming.notice) } catch { return }
            guard let self, self.notice == current else { return }
            self.notice = nil
        }
    }

    func showDeviceInput(_ control: BCRControlID, rawValue: UInt16, pressed: Bool?, shows: Bool) {
        // The mock's preset shows every value; the device follows its own `.showvalue` settings.
        let now = timing.presentation.now()
        if control.isContinuous {
            display.encoderMoved(rawValue: Int(rawValue), showsValue: shows, at: now)
        } else {
            display.buttonChanged(pressed: pressed, rawValue: Int(rawValue), showsValue: shows, at: now)
        }
        guard shows else { return }
        displayRevertTask?.cancel()
        displayRevertTask = Task { @MainActor [weak self, timing] in
            // Values and button states are held for different times; wait for whichever is shown.
            let remaining = (self?.display.transient?.until ?? now) - now
            do { try await timing.presentation.sleep(.seconds(max(0, remaining))) } catch { return }
            self?.objectWillChange.send()
            self?.displayRevertTask = nil
        }
    }

    func noteButtonActivity(_ control: BCRControlID, pressed: Bool?) {
        pressTasks[control]?.cancel()
        pressTasks[control] = nil
        if pressed == false {
            guard hardwarePressedControls.contains(control) else { return }
            let remaining = max(
                0,
                ConsoleTiming.minimumPressSeconds - (timing.presentation.now() - (pressStarted[control] ?? 0))
            )
            pressStarted[control] = nil
            if remaining == 0 { hardwarePressedControls.remove(control); return }
            pressTasks[control] = Task { @MainActor [weak self, timing] in
                do { try await timing.presentation.sleep(.seconds(remaining)) } catch { return }
                self?.hardwarePressedControls.remove(control)
                self?.pressTasks[control] = nil
            }
            return
        }
        hardwarePressedControls.insert(control)
        if pressed == true {
            pressStarted[control] = timing.presentation.now()
            return
        }
        pressTasks[control] = Task { @MainActor [weak self, timing] in
            do { try await timing.presentation.sleep(ConsoleTiming.pulse) } catch { return }
            self?.hardwarePressedControls.remove(control)
            self?.pressTasks[control] = nil
        }
    }
}
