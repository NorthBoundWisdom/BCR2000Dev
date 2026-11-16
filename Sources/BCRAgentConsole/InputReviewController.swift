import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class InputReviewController: ObservableObject {
    @Published var source: DeviceSource = .hardware
    @Published private(set) var error: String?
    @Published private(set) var receipt: InputReviewExportReceipt?
    @Published private(set) var isExporting = false
    private var hardware = InputCoverage(), mock = InputCoverage()
    private var hardwareStarted: Date
    private let mockStarted: Date
    private var hardwareRoute: MIDIConnectionSnapshot
    private let session: SurfaceSession
    private let now: @MainActor () -> Date
    private var observer: UUID?
    var map: HardwareMap { source == .hardware ? session.learnedHardwareMap : session.mock.preset }
    var review: InputCoverage {
        source == .mock ? mock : (hardwareRoute.hasSameRoute(as: session.connection) ? hardware : .init())
    }

    init(session: SurfaceSession, now: @escaping @MainActor () -> Date) {
        self.session = session; self.now = now
        hardwareStarted = now(); mockStarted = now(); hardwareRoute = session.connection
        observer = session.observeMonitor { [weak self] event, echo in self?.observe(event, echo: echo) }
    }

    private func observe(_ event: MonitorEvent, echo: Bool) {
        guard event.direction == .input else { return }
        if event.source == .hardware {
            if !hardwareRoute.hasSameRoute(as: session.connection) {
                hardware = .init(); hardwareStarted = now(); hardwareRoute = session.connection
            }
            hardware.observe(event, feedbackEcho: echo, map: session.learnedHardwareMap)
        } else { mock.observe(event, feedbackEcho: echo, map: session.mock.preset) }
        objectWillChange.send()
    }

    func chooseExport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "bcr-input-review.json"
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }

    func export(to url: URL) {
        guard !isExporting else { return }
        isExporting = true; error = nil
        let coverage = review, map = map, source = source, connection = session.connection, generated = now()
        let started = source == .mock ? mockStarted :
            (hardwareRoute.hasSameRoute(as: connection) ? hardwareStarted : generated)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try InputReviewExporter.export(to: url, coverage: coverage, map: map,
                                               applicationVersion: AppBuildVersion.current, source: source,
                                               connection: connection, observationStarted: started,
                                               generatedAt: generated,
                                               contextID: UUID().uuidString)
            }.result
            guard let self else { return }
            isExporting = false
            switch result {
            case let .success(receipt): self.receipt = receipt
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }
}
