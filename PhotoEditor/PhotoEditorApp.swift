import SwiftUI

// MARK: - PhotoEditorApp
/// Main entry point for the AI Photo Editor macOS application.

@main
struct PhotoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove the default "New Window" command since this is a single-window app
            CommandGroup(replacing: .newItem) {}
        }
    }
}
