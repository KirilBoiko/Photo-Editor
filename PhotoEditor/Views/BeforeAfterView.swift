import SwiftUI

// MARK: - BeforeAfterView
/// An interactive split-screen comparison view with a draggable vertical divider.
///
/// The left side shows the "Before" (original) image and the right side shows
/// the "After" (processed) image. The user can drag the divider to reveal
/// more of either side.

struct BeforeAfterView: View {
    let originalImage: NSImage
    let processedImage: NSImage

    /// The current divider position as a fraction of the view width (0.0–1.0).
    @State private var dividerPosition: CGFloat = 0.5

    /// Whether the user is currently dragging the divider.
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let dividerX = width * dividerPosition

            ZStack {
                // Background — processed (After) image fills the entire frame
                Image(nsImage: processedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)

                // Foreground — original (Before) image, clipped to left of divider
                Image(nsImage: originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .clipShape(
                        HorizontalClipShape(clipWidth: dividerX)
                    )

                // Divider line
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .position(x: dividerX, y: height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 0)

                // Divider handle (draggable circle)
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 2)
                    )
                    .overlay(
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
                    .position(x: dividerX, y: height / 2)
                    .scaleEffect(isDragging ? 1.15 : 1.0)
                    .animation(.spring(response: 0.3), value: isDragging)

                // Labels
                HStack {
                    // "Before" label on the left
                    if dividerPosition > 0.15 {
                        labelPill("Before")
                            .padding(.leading, 16)
                            .transition(.opacity)
                    }

                    Spacer()

                    // "After" label on the right
                    if dividerPosition < 0.85 {
                        labelPill("After")
                            .padding(.trailing, 16)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.2), value: dividerPosition)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let newPosition = value.location.x / width
                        dividerPosition = min(max(newPosition, 0.02), 0.98)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Label Pill

    /// Glassmorphism-style label pill for "Before" / "After" indicators.
    private func labelPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Clip Shape

/// A shape that clips to the left portion of the view up to `clipWidth`.
struct HorizontalClipShape: Shape {
    var clipWidth: CGFloat

    var animatableData: CGFloat {
        get { clipWidth }
        set { clipWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: 0, y: 0, width: clipWidth, height: rect.height))
    }
}
