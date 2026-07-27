import SwiftUI

@main
@MainActor
struct BCRAgentConsoleApp: App {
    @StateObject private var model = ConsoleViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1_020, minHeight: 720)
        }
        .defaultSize(width: 1_180, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}
