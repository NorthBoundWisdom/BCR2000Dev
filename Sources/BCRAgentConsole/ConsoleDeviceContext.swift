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
struct ConsoleDeviceContext {
    let session: SurfaceSession
    let midi: any MIDIService
    let presentation: ConsolePresentationState
    let timing: ConsoleTiming
    let canConfigureMIDI: Bool
    let hardwareFile: ProtectedJSONFile<HardwareMap>
}

/// Immutable references only; canonical values and effects remain in SurfaceSession.
@MainActor
protocol ConsoleDeviceOwner: AnyObject { var context: ConsoleDeviceContext { get } }

extension ConsoleDeviceOwner {
    var session: SurfaceSession { context.session }
    var midi: any MIDIService { context.midi }
    var presentation: ConsolePresentationState { context.presentation }
    var timing: ConsoleTiming { context.timing }
    var canConfigureMIDI: Bool { context.canConfigureMIDI }
    var hardwareFile: ProtectedJSONFile<HardwareMap> { context.hardwareFile }
    var source: DeviceSource { session.source }
    var connection: MIDIConnectionSnapshot { session.connection }
    var engine: SurfaceEngine { session.engine }
    var configuration: SurfaceConfiguration { engine.configuration }
    var isLearning: Bool { engine.learnTarget != nil }
    var notice: ConsoleNotice? {
        get { presentation.notice } set { presentation.notice = newValue }
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, message: "\(error: error)")
    }

    func withDisplayTransfer<T>(_ operation: BCRDisplayModel.TransferOperation = .read,
                                _ body: @MainActor () async throws -> T) async rethrows -> T
    {
        let transfer = presentation.beginTransfer(operation)
        defer { presentation.endTransfer(transfer) }
        return try await body()
    }
}

/// Only the existing BCL exclusivity nonce and route; no task, business state or scheduler.
@MainActor
final class ConsolePresetOperationGate {
    private(set) var id: UUID?
    private(set) var route: MIDIConnectionSnapshot?
    func begin(route: MIDIConnectionSnapshot) -> UUID {
        let id = UUID()
        self.id = id; self.route = route
        return id
    }

    func finish(_ id: UUID) {
        if self.id == id { clear() }
    }

    func clear() { id = nil; route = nil }
}
