import BCRAgentCore
import Combine
import Foundation

enum AgentBackend: String, CaseIterable { case mock, codex }

/// Main-actor bridge between value snapshots from Core and the console's existing LED pipeline.
@MainActor
final class CodexAgentController: ObservableObject {
    @Published private(set) var backend: AgentBackend = .mock
    @Published private(set) var phase: CodexConnectionPhase = .stopped
    @Published private(set) var models: [CodexModelCapability] = []
    @Published private(set) var approvals: [CodexPendingApproval] = []
    @Published private(set) var reviewingApproval: CodexPendingApproval?
    @Published private(set) var respondingApprovals: Set<CodexRequestID> = []
    private var presentedApprovalID: UUID?
    private var approvalTasks: [CodexRequestID: Task<Void, Never>] = [:]
    @Published private(set) var error: String?
    @Published private(set) var slots = AgentSlot.mockSlots()
    @Published var executable = "codex"
    @Published var workspace = ""
    @Published var prompt = ""
    @Published var modelID = ""
    @Published var effort = ""
    @Published var allowWorkspaceWrites = false
    var onSlots: (([AgentSlot]) -> Void)?
    var onStopMock: (() -> Void)?
    private let directory: URL
    private let factory: (@MainActor () async throws -> CodexSessionCoordinator)?
    private var snapshotTask: Task<Void, Never>?
    private var snapshots: AsyncStream<CodexSessionSnapshot>.Continuation?
    private var coordinator: CodexSessionCoordinator?
    private var generation = 0
    private var tasks: [AgentSlotID: Task<Void, Never>] = [:]

    init(directory: URL, factory: (@MainActor () async throws -> CodexSessionCoordinator)? = nil) {
        self.directory = directory
        self.factory = factory
    }

    func selectBackend(_ value: AgentBackend) async {
        guard value != backend else { return }
        await stopAll()
        backend = value
        onStopMock?()
    }

    func connect() async {
        guard backend == .codex, phase == .stopped || phase == .failed else { return }
        await stopAll()
        generation += 1
        let revision = generation
        phase = .launching
        error = nil
        do {
            _ = try WorkspacePolicy.canonicalWorkspaceRoot(workspace)
            let session: CodexSessionCoordinator
            if let factory { session = try await factory() }
            else {
                let supervisor = CodexProcessSupervisor()
                try await supervisor.start(executablePath: executable,
                                           arguments: ["app-server", "--listen", "stdio://"])
                session = CodexSessionCoordinator(transport: supervisor,
                                                  modelCatalogStore: CodexModelCatalogStore(fileURL: directory
                                                      .appending(path: "codex-models.json")))
            }
            guard revision == generation else { await session.stop(); return }
            coordinator = session
            let stream = AsyncStream<CodexSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
            snapshots = stream.continuation
            snapshotTask = Task { @MainActor [weak self] in
                for await snapshot in stream.stream {
                    guard let self, self.generation == revision else { return }
                    self.apply(snapshot)
                }
            }
            await session.setSnapshotHandler { snapshot in stream.continuation.yield(snapshot) }
            try await session.start()
            guard revision == generation else { return }
            apply(await session.snapshot())
        } catch {
            guard revision == generation else { return }
            phase = .failed
            self.error = error.localizedDescription
        }
    }

    func stopAll() async {
        if backend == .mock { onStopMock?() }
        generation += 1
        snapshots?.finish(); snapshots = nil
        snapshotTask?.cancel(); snapshotTask = nil
        approvalTasks.values.forEach { $0.cancel() }
        approvalTasks.removeAll()
        respondingApprovals.removeAll()
        dismissApprovalReview()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        let session = coordinator
        coordinator = nil
        phase = .stopped
        approvals = []
        models = []
        for index in slots.indices where slots[index].state.isActive {
            slots[index].state = .interrupted
            slots[index].statusText = L10n.text("已由控制台中断")
        }
        if backend == .codex { onSlots?(slots) }
        await session?.stop()
    }

    func perform(_ id: AgentSlotID) {
        guard backend == .codex, let slot = slots.first(where: { $0.id == id }) else { return }
        if slot.state == .waitingApproval { requestApprovalReview(for: id) }
        else if slot.state.isActive { interrupt(id) }
        else { start(id) }
    }

    func start(_ id: AgentSlotID) {
        guard backend == .codex, phase == .ready, let coordinator,
              let index = slots.firstIndex(where: { $0.id == id }), !slots[index].state.isActive
        else {
            error = L10n.text("Codex 连接未建立"); return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = L10n.text("任务内容不能为空"); return
        }
        let revision = generation
        let text = prompt, model = modelID, root = workspace, selectedEffort = effort
        let policy = CodexPermissionPolicy(type: allowWorkspaceWrites ? .workspaceWrite : .safeRead,
                                           networkAccess: false, writableRoots: allowWorkspaceWrites ? [root] : nil)
        slots[index].state = .queued
        slots[index].statusText = L10n.text("排队中")
        onSlots?(slots)
        tasks[id] = Task { [weak self] in
            do {
                try await coordinator.startTurn(slotID: id, userPrompt: text, modelID: model,
                                                effortID: selectedEffort.isEmpty ? nil : selectedEffort,
                                                permission: policy, cwd: root)
            } catch {
                guard let self, self.generation == revision else { return }
                self.error = error.localizedDescription
                if let index = self.slots.firstIndex(where: { $0.id == id }) {
                    self.slots[index].state = .error
                    self.slots[index].statusText = error.localizedDescription
                    self.onSlots?(self.slots)
                }
            }
            if let self, self.generation == revision { self.tasks[id] = nil }
        }
    }

    func interrupt(_ id: AgentSlotID) {
        guard let coordinator else { return }
        // A queued thread may not yet have a turn ID; stopping the connection cancels it safely.
        if slots.first(where: { $0.id == id })?.state == .queued {
            Task { await stopAll() }; return
        }
        let revision = generation
        tasks[id] = Task { [weak self] in
            do { try await coordinator.interruptTurn(slotID: id) }
            catch { if let self, self.generation == revision { self.error = error.localizedDescription } }
        }
    }

    /// Slot/physical intents never grant approval. Only the presented per-request review can grant it.
    func decide(_ id: AgentSlotID, approve: Bool) {
        if approve { requestApprovalReview(for: id) }
        else if let request = approvals.first(where: { $0.slotID == id }) { rejectApproval(request.id) }
    }

    func requestApprovalReview(for slot: AgentSlotID) {
        guard let request = approvals.first(where: { $0.slotID == slot }) else { return }
        reviewApproval(request.id)
    }

    func reviewApproval(_ id: CodexRequestID) {
        guard let request = approvals.first(where: { $0.id == id }) else { return }
        // Repeated physical presses cannot acknowledge the presentation or approve it.
        guard reviewingApproval?.id != id else { return }
        presentedApprovalID = nil
        reviewingApproval = request
    }

    func markApprovalPresented(_ request: CodexPendingApproval) {
        guard reviewingApproval == request, approvals.contains(request) else { return }
        presentedApprovalID = request.reviewToken
    }

    func dismissApprovalReview() {
        presentedApprovalID = nil
        reviewingApproval = nil
    }

    func approveReviewedRequest(_ request: CodexPendingApproval) {
        guard reviewingApproval == request, presentedApprovalID == request.reviewToken,
              approvals.contains(request)
        else {
            error = L10n.text("请先在审批详情页查看该请求"); return
        }
        sendDecision(request.id, decision: .approve)
    }

    func rejectApproval(_ id: CodexRequestID) { sendDecision(id, decision: .decline) }
    private func sendDecision(_ id: CodexRequestID, decision: CodexApprovalDecision) {
        guard let coordinator, let request = approvals.first(where: { $0.id == id }),
              !respondingApprovals.contains(id) else { return }
        let revision = generation
        error = nil
        respondingApprovals.insert(id)
        approvalTasks[id] = Task { [weak self] in
            defer {
                if let self, self.generation == revision {
                    self.respondingApprovals.remove(id)
                    self.approvalTasks[id] = nil
                }
            }
            do {
                try await coordinator.sendApproval(id: id, slotID: request.slotID,
                                                   visibleSlotID: request.slotID, decision: decision)
            } catch { if let self, self.generation == revision { self.error = error.localizedDescription } }
        }
    }

    private func apply(_ snapshot: CodexSessionSnapshot) {
        phase = snapshot.phase
        models = snapshot.models
        approvals = snapshot.approvals
        if let review = reviewingApproval,
           !approvals.contains(where: { $0.id == review.id }) { dismissApprovalReview() }
        if !models
            .contains(where: { $0.id == modelID })
        {
            modelID = models.first(where: \.isDefault)?.id ?? models.first?.id ?? ""
        }
        if let error = snapshot.error { self.error = error }
        for index in slots.indices {
            guard let state = snapshot.states[slots[index].id] else { continue }
            // Idle snapshots from another slot must not clear a start request still in flight.
            if snapshot.phase == .failed, slots[index].state.isActive {
                slots[index].state = .error
                slots[index].statusText = snapshot.error ?? L10n.text("Codex 连接未建立")
                continue
            }
            if slots[index].state == .queued, state.phase == .idle { continue }
            switch state.phase {
            case .idle: slots[index].state = .idle
            case .threadStarting, .activeThread, .turnStarting: slots[index].state = .queued
            case .running: slots[index].state = .running
            case .awaitingApproval: slots[index].state = .waitingApproval
            case .completed: slots[index].state = .completed
            case .interrupted: slots[index].state = .interrupted
            case .failed: slots[index].state = .error
            }
            slots[index].progress = state.phase == .completed ? 1 : 0
            slots[index].statusText = state.lastError ?? slots[index].state.displayName
        }
        onSlots?(slots)
    }
}
