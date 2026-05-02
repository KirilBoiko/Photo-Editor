import SwiftUI

// MARK: - ToolbarView
/// The main toolbar content for the photo editor window.
///
/// Provides buttons for: Import, Open, Auto-Enhance, Batch, Sync, Reset, and Export.
/// Integrated into the `ContentView` via `.toolbar { }`.

struct ToolbarView: View {
    @ObservedObject var viewModel: PhotoEditorViewModel

    var body: some View {
        // Import Folder
        Button {
            viewModel.importFolder()
        } label: {
            Label("Import Folder", systemImage: "folder.badge.plus")
                .frame(height: 44)
        }
        .transaction { $0.animation = nil }
        .fixedSize()
        .help("Import a folder of JPEG photos")

        // Open Photo
        Button {
            viewModel.importPhoto()
        } label: {
            Label("Open", systemImage: "photo.on.rectangle.angled")
                .frame(height: 44)
        }
        .transaction { $0.animation = nil }
        .fixedSize()
        .help("Open a JPEG photo (⌘O)")
        .keyboardShortcut("o", modifiers: .command)

        // Spacer with processing overlay — spinner never affects layout flow
        Spacer()
            .overlay {
                HStack(spacing: 8) {
                    if viewModel.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                    if viewModel.batchState == .processing {
                        Text(viewModel.batchProgress)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Button {
                            viewModel.cancelBatch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .transaction { $0.animation = nil }

        // Auto-Enhance
        Button {
            viewModel.autoEnhance()
        } label: {
            ZStack {
                Label("Auto-Enhance", systemImage: "wand.and.stars")
                    .opacity(viewModel.isAnalyzing ? 0 : 1)
                
                if viewModel.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 44)
            .transaction { $0.animation = nil }
        }
        .transaction { $0.animation = nil }
        .animation(nil, value: viewModel.isAnalyzing)
        .fixedSize()
        .disabled(viewModel.document == nil || viewModel.isAnalyzing || viewModel.batchState == .processing)
        .help("Analyze photo and apply recommended enhancements")

        if viewModel.photoQueue.count > 1 {
            // Batch Enhance
            Button {
                viewModel.batchEnhance()
            } label: {
                Label("Batch Enhance", systemImage: "sparkles.rectangle.stack")
                    .frame(height: 44)
            }
            .transaction { $0.animation = nil }
            .fixedSize()
            .disabled(viewModel.batchState == .processing || viewModel.isAnalyzing)
            .help("Analyze and enhance all photos in the batch")

            // Sync Settings
            Button {
                viewModel.syncSettings()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .frame(height: 44)
            }
            .transaction { $0.animation = nil }
            .fixedSize()
            .disabled(viewModel.batchState == .processing)
            .help("Sync current settings to all photos")
        }

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
