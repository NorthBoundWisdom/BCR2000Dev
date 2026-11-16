import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Only owns offline presentation and run scheduling. It has no reference to the live console.
@MainActor
final class OfflineCaptureController: ObservableObject {
    @Published private(set) var loaded: RecordedCapture?
    @Published private(set) var name: String?
    @Published private(set) var replay: RecordedCaptureReplay?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    private var loadingTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var generation = UUID()

    func chooseFile() {
        pause()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .data, .json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        pause(); loadingTask?.cancel()
        let generation = UUID(); self.generation = generation
        isLoading = true; error = nil
        loadingTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { try OfflineCaptureFile.load(url) }.result
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            isLoading = false
            switch result {
            case let .success(capture): install(capture, name: url.lastPathComponent)
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }

    func importData(_ data: Data, name: String) {
        pause(); loadingTask?.cancel(); generation = UUID(); isLoading = false
        do { install(try RecordedCapture(data: data), name: name) }
        catch { self.error = error.localizedDescription }
    }

    private func install(_ capture: RecordedCapture, name: String) {
        loaded = capture; self.name = name; error = nil
        do { replay = try RecordedCaptureReplay(capture: capture) }
        catch { replay = nil; self.error = error.localizedDescription }
    }

    func clear() {
        pause(); loadingTask?.cancel(); generation = UUID()
        loaded = nil; replay = nil; name = nil; error = nil; isLoading = false
    }

    func step() {
        guard !isPlaying, !isLoading else { return }
        advance(steps: 1)
    }

    func run() {
        guard !isLoading, replay?.isAtEnd == false else { return }
        pause(); isPlaying = true
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                advance(steps: 128)
                guard isPlaying, replay?.isAtEnd == false else { isPlaying = false; return }
                await Task.yield()
            }
        }
    }

    func pause() { replayTask?.cancel(); replayTask = nil; isPlaying = false }
    func reset() {
        pause()
        do { try replay?.reset(); objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }

    private func advance(steps: Int) {
        do {
            for _ in 0 ..< steps { if try replay?.step() != true { break } }
            objectWillChange.send()
        } catch { self.error = error.localizedDescription; pause() }
    }
}
