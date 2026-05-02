import SwiftUI
import UniformTypeIdentifiers

// MARK: - ContentView
/// The main editor layout combining the image canvas and adjustment panel.
///
/// Layout:
/// - **Left**: Image canvas showing either a placeholder or the BeforeAfterView
/// - **Right**: AdjustmentPanelView with sliders
/// - **Top**: macOS toolbar with actions
///
/// Supports drag-and-drop of JPEG files onto the canvas.

struct ContentView: View {
    @StateObject private var viewModel = PhotoEditorViewModel()

    /// Whether the user is currently dragging a file over the canvas.
    @State private var isDragTargeted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left: Image Canvas
                imageCanvas
                    .frame(minWidth: 500)
                    .layoutPriority(1)

                // Right: Adjustment Panel
                AdjustmentPanelView(viewModel: viewModel)
            }
            
            if !viewModel.photoQueue.isEmpty {
                Divider()
                FilmstripView(viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarView(viewModel: viewModel)
        }
        .alert(
            "Error",
            isPresented: $viewModel.showErrorAlert,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Image Canvas

    @ViewBuilder
    private var imageCanvas: some View {
        if let original = viewModel.originalImage,
           let processed = viewModel.processedImage {
            // Photo loaded — show Before/After comparison
            BeforeAfterView(
                originalImage: original,
                processedImage: processed
            )
            .padding(16)
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers)
            }
            .overlay(dragOverlay)
        } else {
            // No photo — show placeholder with drag-and-drop prompt
            emptyStatePlaceholder
                .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                    handleDrop(providers)
                }
                .overlay(dragOverlay)
        }
    }

    // MARK: - Empty State

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Open a JPEG Photo")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)

            Text("Drag and drop a file here, or click Open in the toolbar")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.importPhoto()
            } label: {
                Label("Open Photo", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drag & Drop

    /// Visual overlay shown when a file is being dragged over the canvas.
    @ViewBuilder
    private var dragOverlay: some View {
        if isDragTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 3, dash: [8, 4])
                )
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(8)
                .transition(.opacity)
        }
    }

    /// Handles a file drop event. Loads the first valid JPEG from the dropped items.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else {
                return
            }

            DispatchQueue.main.async {
                viewModel.loadPhoto(from: url)
            }
        }

        return true
    }
}
