import BCRAgentCore
import Combine
import SwiftUI

@MainActor
final class FeedbackSettingsController: ObservableObject {
    @Published private(set) var policy = FeedbackPolicy()
    @Published private(set) var error: String?
    private let session: SurfaceSession
    private let store: JSONFileStore<FeedbackPolicy>
    private var task: Task<Void, Never>?
    private var observer: UUID?
    private var pollGeneration = UUID()
    var isPolling: Bool { task != nil }
    init(session: SurfaceSession, url: URL) {
        self.session = session
        store = JSONFileStore(fileURL: url)
        do {
            if let saved = try store.load() { try saved.validate(); policy = saved }
            try session.configureFeedback(policy)
        } catch { self.error = error.localizedDescription }
        observer = session.observeFeedbackQueue { [weak self] _ in self?.updatePolling() }
        updatePolling()
    }

    deinit {
        task?.cancel()
        if let observer { Task { @MainActor [session] in session.removeFeedbackObserver(observer) } }
    }

    private func updatePolling() {
        guard policy.enabled, session.pendingFeedbackCount > 0 else {
            pollGeneration = UUID()
            task?.cancel(); task = nil
            return
        }
        guard task == nil else { return }
        let revision = UUID()
        pollGeneration = revision
        task = Task { @MainActor [weak self] in
            defer { if let self, self.pollGeneration == revision { self.task = nil } }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, self.pollGeneration == revision else { return }
                self.session.flushFeedback()
                guard self.policy.enabled, self.session.pendingFeedbackCount > 0 else { return }
            }
        }
    }

    func apply(_ candidate: FeedbackPolicy) {
        do {
            try candidate.validate()
            try store.save(candidate)
            try session.configureFeedback(candidate)
            policy = candidate
            updatePolling()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct FeedbackSettingsView: View {
    @ObservedObject var controller: FeedbackSettingsController
    @State private var draft: FeedbackPolicy
    init(controller: FeedbackSettingsController) {
        self.controller = controller
        _draft = State(initialValue: controller.policy)
    }

    var body: some View {
        Form {
            Toggle(L10n.text("合并并限速实体反馈"), isOn: $draft.enabled)
            TextField(L10n.text("每秒消息上限"), value: $draft.messagesPerSecond, format: .number)
            TextField(L10n.text("突发消息上限"), value: $draft.burst, format: .number)
            TextField(L10n.text("错误重试间隔（秒）"), value: $draft.errorCooldown, format: .number)
            Text(L10n.text("同一控件只发送最新值；切换端口、设备或配置时清除待发送反馈。默认关闭，真机速率需实测校准。"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            Button(L10n.text("应用设置")) { controller.apply(draft) }
        }
        .formStyle(.grouped).padding(12).frame(width: 560, height: 350)
        .preferredColorScheme(.dark)
    }
}
