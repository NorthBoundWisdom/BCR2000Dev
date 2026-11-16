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

extension DeviceSource {
    var title: String {
        switch self {
        case .mock: L10n.text("Mock 设备")
        case .hardware: L10n.text("实体 BCR2000")
        }
    }
}

struct ConsoleNotice: Equatable {
    enum Level: Equatable {
        case info
        case warning
        case error
    }

    enum Action: Equatable {
        case switchToHardware
        case retryConfigurationSave
        /// Write migrated files back (the originals are backed up first) so the notice stops recurring.
        case saveMigration
    }

    private enum Content: Equatable {
        case verbatim(String)
        case localized(LocalizedMessage)
    }

    let level: Level
    private let content: Content
    var action: Action?
    var localizedMessage: LocalizedMessage {
        switch content {
        case let .verbatim(text): .verbatim(text)
        case let .localized(message): message
        }
    }

    var text: String {
        switch content {
        case let .verbatim(text): text
        case let .localized(message): L10n.text(message)
        }
    }

    init(level: Level, text: String, action: Action? = nil) {
        self.level = level; content = .verbatim(text); self.action = action
    }

    init(level: Level, message: LocalizedMessage, action: Action? = nil) {
        self.level = level; content = .localized(message); self.action = action
    }
}

/// Read → preview → confirm → write → verify of the device's temporary preset.
struct PresetAlignmentState {
    enum Phase: Equatable {
        case reading, preview, writing(done: Int, total: Int), verifying, finished, restoring, restoreConfirmation,
             failed(LocalizedMessage)
        var isBusy: Bool {
            switch self {
            case .reading, .writing, .verifying, .restoring: true
            case .preview, .finished, .restoreConfirmation, .failed: false
            }
        }
    }

    var phase: Phase
    var options = BCRPresetAlignment.Options()
    var plan: BCRPresetAlignment.Plan?
    var planError: LocalizedMessage?
    var backup: URL?
    var canRestore = false
    var restoreProgress: (done: Int, total: Int)?
}

struct HardwareConnectionPrompt: Identifiable {
    enum Mode: Equatable { case write, read }
    let id = UUID()
    let route: MIDIConnectionSnapshot
    let canRead: Bool
}
