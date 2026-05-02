import SwiftUI

// MARK: - AdjustmentPanelView
/// A vertical panel containing:
/// 1. **Manual Sliders** — Exposure, Contrast, Saturation, Warmth, Sharpness
/// 2. **Color Mixer** — 8 toggleable color chips with HSL controls

struct AdjustmentPanelView: View {
    @ObservedObject var viewModel: PhotoEditorViewModel

    /// Color chip definitions: ordered from Red → Magenta around the hue wheel.
    private static let colorChips: [(name: String, color: Color)] = [
        ("Red",     .red),
        ("Orange",  .orange),
        ("Yellow",  .yellow),
        ("Green",   .green),
        ("Aqua",    Color(hue: 0.5, saturation: 0.8, brightness: 0.9)),
        ("Blue",    .blue),
        ("Purple",  .purple),
        ("Magenta", Color(hue: 0.83, saturation: 0.8, brightness: 0.9)),
    ]

    /// Grid layout: 4 columns for the color chips (2 rows × 4).
    private let chipColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Histogram
                HistogramView(data: viewModel.histogramData)
                    .padding(.bottom, 4)

                // MARK: - Scopes (Waveform + Vectorscope)
                ScopesPanelView(viewModel: viewModel)

                // MARK: - Highlight Warning
                if let stats = viewModel.lastImageStatistics,
                   stats.highlightClipping > 0.02 {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max.trianglefill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("Highlights Clipping (\(String(format: "%.1f", stats.highlightClipping * 100))%) — Recovery Mode")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // MARK: - Layer Picker
                VStack(spacing: 8) {
                    Picker("Layer", selection: $viewModel.selectedLayer) {
                        ForEach(PhotoEditorViewModel.LayerType.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if viewModel.isMaskAvailable {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Mask Active")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.bottom, 8)
                
                // MARK: - Adjustments Section Header
                HStack {
                    Label("Adjustments", systemImage: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.resetAdjustments()
                        }
                    } label: {
                        Text("Reset All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.hasChanges)
                    .opacity(viewModel.hasChanges ? 1.0 : 0.4)
                }

                Divider()

                // MARK: - Sliders (bound to selected layer)
                adjustmentSlider(
                    title: "Exposure",
                    systemImage: "sun.max.fill",
                    value: viewModel.binding(for: \.exposure),
                    color: .yellow
                )

                adjustmentSlider(
                    title: "Contrast",
                    systemImage: "circle.righthalf.filled",
                    value: viewModel.binding(for: \.contrast),
                    color: .gray
                )

                adjustmentSlider(
                    title: "Saturation",
                    systemImage: "drop.fill",
                    value: viewModel.binding(for: \.saturation),
                    color: .pink
                )

                adjustmentSlider(
                    title: "Warmth",
                    systemImage: "thermometer.sun.fill",
                    value: viewModel.binding(for: \.warmth),
                    color: .orange
                )

                adjustmentSlider(
                    title: "Sharpness",
                    systemImage: "triangle",
                    value: viewModel.binding(for: \.sharpness),
                    color: .blue
                )

                adjustmentSlider(
                    title: "Highlights",
                    systemImage: "sun.max",
                    value: viewModel.binding(for: \.highlights),
                    color: .orange
                )

                adjustmentSlider(
                    title: "Shadows",
                    systemImage: "moon.fill",
                    value: viewModel.binding(for: \.shadows),
                    color: .indigo
                )

                if viewModel.selectedLayer == .background {
                    adjustmentSlider(
                        title: "Bokeh",
                        systemImage: "camera.aperture",
                        value: viewModel.binding(for: \.blur),
                        color: .green
                    )
                }

                // MARK: - Color Mixer
                Divider()
                    .padding(.top, 4)

                HStack {
                    Label("Color Mixer", systemImage: "paintpalette.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Spacer()
                }
                
                Picker("Color Mixer Mode", selection: $viewModel.colorMixerMode) {
                    ForEach(PhotoEditorViewModel.ColorMixerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 4)

                if viewModel.colorMixerMode == .color {
                    // Chips grid
                    LazyVGrid(columns: chipColumns, spacing: 12) {
                        ForEach(Self.colorChips, id: \.name) { chip in
                            colorChipView(name: chip.name, color: chip.color)
                        }
                    }
                    .padding(.top, 4)

                    Divider().padding(.vertical, 8)

                    // 3 sliders for selected color
                    let selected = viewModel.selectedColorChannel
                    let colorObj = Self.colorChips.first(where: { $0.name == selected })?.color ?? .gray
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(selected) Adjustments")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        adjustmentSlider(
                            title: "Hue",
                            systemImage: "dial.min",
                            value: viewModel.profileBinding(for: selected, property: \.hue),
                            color: colorObj
                        )
                        adjustmentSlider(
                            title: "Saturation",
                            systemImage: "drop.fill",
                            value: viewModel.profileBinding(for: selected, property: \.saturation),
                            color: colorObj
                        )
                        adjustmentSlider(
                            title: "Luminance",
                            systemImage: "sun.max.fill",
                            value: viewModel.profileBinding(for: selected, property: \.luminance),
                            color: colorObj
                        )
                    }
                } else {
                    // Property sliders for all 8 colors
                    VStack(spacing: 12) {
                        ForEach(Self.colorChips, id: \.name) { chip in
                            let name = chip.name
                            let binding: Binding<Float> = Binding(
                                get: {
                                    let profile = viewModel.activeProfile(for: name)
                                    switch viewModel.colorMixerMode {
                                    case .hue: return profile.hue
                                    case .saturation: return profile.saturation
                                    case .luminance: return profile.luminance
                                    default: return 0.0
                                    }
                                },
                                set: { val in
                                    switch viewModel.colorMixerMode {
                                    case .hue: viewModel.profileBinding(for: name, property: \.hue).wrappedValue = val
                                    case .saturation: viewModel.profileBinding(for: name, property: \.saturation).wrappedValue = val
                                    case .luminance: viewModel.profileBinding(for: name, property: \.luminance).wrappedValue = val
                                    default: break
                                    }
                                }
                            )
                            
                            adjustmentSlider(
                                title: name,
                                systemImage: "circle.fill",
                                value: binding,
                                color: chip.color
                            )
                        }
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(16)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
    }

    // MARK: - Color Chip Component

    private func colorChipView(name: String, color: Color) -> some View {
        let isSelected = viewModel.selectedColorChannel == name

        return Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                viewModel.selectProfile(name)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .saturation(isSelected ? 1.0 : 0.4)
                    .brightness(isSelected ? 0.0 : -0.1)
                    .frame(width: 44, height: 44)
                    .shadow(
                        color: isSelected ? color.opacity(0.6) : .clear,
                        radius: isSelected ? 6 : 0,
                        x: 0, y: 2
                    )

                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white, lineWidth: 2)
                }
            }
            .scaleEffect(isSelected ? 1.0 : 0.92)
            .frame(width: 44, height: 44) // Lock layout footprint
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slider Component

    private func adjustmentSlider(
        title: String,
        systemImage: String,
        value: Binding<Float>,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundColor(color)
                        .font(.system(size: 11))
                        .frame(width: 16)
                }

                Spacer()

                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Button {
                    withAnimation(.spring(response: 0.2)) {
                        value.wrappedValue = 0.0
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(value.wrappedValue == 0.0 ? 0.3 : 1.0)
                .disabled(value.wrappedValue == 0.0)
            }

            Slider(value: value, in: -1.0...1.0, step: 0.01)
                .tint(color.opacity(0.7))
        }
    }
}

// MARK: - HistogramView

struct HistogramView: View {
    let data: ProcessingEngine.HistogramData
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            
            // Grid Lines
            VStack(spacing: 0) {
                Divider().opacity(0.3)
                Spacer()
                Divider().opacity(0.3)
                Spacer()
                Divider().opacity(0.3)
            }
            
            if data != .empty {
                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    
                    // Red
                    histogramPath(data.red, width: width, height: height)
                        .fill(LinearGradient(colors: [.red.opacity(0.6), .red.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        .blendMode(.screen)
                    
                    // Green
                    histogramPath(data.green, width: width, height: height)
                        .fill(LinearGradient(colors: [.green.opacity(0.6), .green.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        .blendMode(.screen)
                    
                    // Blue
                    histogramPath(data.blue, width: width, height: height)
                        .fill(LinearGradient(colors: [.blue.opacity(0.6), .blue.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        .blendMode(.screen)
                    
                    // Luminance
                    let lumPath = histogramPath(data.luminance, width: width, height: height)
                    lumPath
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    lumPath
                        .fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .blendMode(.plusLighter)
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func histogramPath(_ points: [CGFloat], width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard points.count == 256 else { return path }
        
        let step = width / 255.0
        
        path.move(to: CGPoint(x: 0, y: height))
        
        for i in 0..<256 {
            let x = CGFloat(i) * step
            // points[i] is normalized 0...1
            let y = height - (points[i] * height)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        
        return path
    }
}
