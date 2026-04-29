import SwiftUI

// MARK: - ToolbarView
/// The main toolbar content for the photo editor window.
///
/// Provides buttons for: Open Photo, Auto-Enhance via AI, Reset, and Export.
/// Integrated into the `ContentView` via `.toolbar { }`.

struct ToolbarView: View {
    @ObservedObject var viewModel: PhotoEditorViewModel

    var body: some View {
        // Open Photo
        Button {
            viewModel.importPhoto()
        } label: {
            Label("Open", systemImage: "photo.on.rectangle.angled")
                .frame(width: 44, height: 44)
        }
        .transaction { $0.animation = nil }
        .fixedSize()
        .help("Open a JPEG photo (⌘O)")
        .keyboardShortcut("o", modifiers: .command)

        // Spacer with processing overlay — spinner never affects layout flow
        Spacer()
            .overlay {
                if viewModel.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .transaction { $0.animation = nil }

        // Auto-Enhance via AI
        Button {
            viewModel.autoEnhance()
        } label: {
            ZStack {
                // Hidden label dictates the layout footprint so the button never resizes
                Label("Auto-Enhance", systemImage: "wand.and.stars")
                    .opacity(viewModel.isAnalyzing ? 0 : 1)
                
                if viewModel.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 44, height: 44)
            .transaction { $0.animation = nil }
        }
        .transaction { $0.animation = nil }
        .animation(nil, value: viewModel.isAnalyzing)
        .fixedSize()
        .disabled(viewModel.document == nil || viewModel.isAnalyzing)
        .help("Analyze photo with AI and apply recommended enhancements")

        // Reset
        Button {
            withAnimation(.spring(response: 0.3)) {
                viewModel.resetAdjustments()
            }
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .frame(width: 44, height: 44)
        }
        .transaction { $0.animation = nil }
        .fixedSize()
        .disabled(!viewModel.hasChanges)
        .help("Reset all adjustments to default")

        // Export
        Button {
            viewModel.exportPhoto()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .frame(width: 44, height: 44)
        }
        .transaction { $0.animation = nil }
        .fixedSize()
        .disabled(viewModel.document == nil)
        .help("Export the enhanced photo as JPEG (⌘E)")
        .keyboardShortcut("e", modifiers: .command)
    }
}
