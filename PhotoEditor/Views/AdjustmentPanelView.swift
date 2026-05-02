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
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                // MARK: - Analysis Section
                Section {
                    VStack(spacing: 16) {
                        HistogramView(data: viewModel.histogramData)
                        
                        ScopesPanelView(viewModel: viewModel)
                        
                        highlightWarning
                    }
                }
                
                // MARK: - Context Section
                Section {
                    VStack(spacing: 12) {
                        layerPicker
                        
                        if viewModel.isMaskAvailable {
                            maskStatus
                        }
                    }
                }
                
                // MARK: - Global Adjustments
                Section(header: sectionHeader("Adjustments", systemImage: "slider.horizontal.3")) {
                    VStack(spacing: 16) {
                        adjustmentSliders
                    }
                    .padding(.top, 8)
                }
                
                // MARK: - Color Mixer
                Section(header: sectionHeader("Color Mixer", systemImage: "paintpalette")) {
                    VStack(spacing: 16) {
                        colorMixerContent
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
    }

    // MARK: - Subviews

    private var highlightWarning: some View {
        Group {
            if let stats = viewModel.lastImageStatistics,
               stats.highlightClipping > 0.02 {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.trianglefill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text("Highlights Clipping (\(String(format: "%.1f", stats.highlightClipping * 100))%)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var layerPicker: some View {
        Picker("Layer", selection: $viewModel.selectedLayer) {
            ForEach(PhotoEditorViewModel.LayerType.allCases) { layer in
                Text(layer.rawValue).tag(layer)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var maskStatus: some View {
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

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                
                if title == "Adjustments" {
                    resetButton
                }
            }
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            Divider()
        }
    }

    private var resetButton: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                viewModel.resetAdjustments()
            }
        } label: {
            Text("Reset")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.hasChanges)
        .opacity(viewModel.hasChanges ? 1.0 : 0.4)
    }

    private var adjustmentSliders: some View {
        VStack(spacing: 12) {
            AdjustmentSlider(label: "Exposure", value: viewModel.binding(for: \.exposure), range: -2...2, icon: "sun.max.fill")
                .tint(.orange)
            AdjustmentSlider(label: "Contrast", value: viewModel.binding(for: \.contrast), range: -1...1, icon: "circle.lefthalf.filled")
            AdjustmentSlider(label: "Shadows", value: viewModel.binding(for: \.shadows), range: -1...1, icon: "shadow")
            AdjustmentSlider(label: "Highlights", value: viewModel.binding(for: \.highlights), range: -1...1, icon: "circle.dotted")
            AdjustmentSlider(label: "Saturation", value: viewModel.binding(for: \.saturation), range: -1...1, icon: "drop.fill")
                .tint(.pink)
            AdjustmentSlider(label: "Warmth", value: viewModel.binding(for: \.warmth), range: -1...1, icon: "thermometer.medium")
                .tint(.orange)
            AdjustmentSlider(label: "Sharpness", value: viewModel.binding(for: \.sharpness), range: 0...1, icon: "triangle.fill")
            
            if viewModel.selectedLayer == .background {
                AdjustmentSlider(label: "Background Blur", value: viewModel.binding(for: \.blur), range: 0...1, icon: "sparkles")
                    .tint(.purple)
            }
        }
    }

    private var colorMixerContent: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: chipColumns, spacing: 12) {
                ForEach(Self.colorChips, id: \.name) { chip in
                    colorChipView(name: chip.name, color: chip.color)
                }
            }
            
            VStack(spacing: 12) {
                Picker("Mode", selection: $viewModel.colorMixerMode) {
                    ForEach(PhotoEditorViewModel.ColorMixerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                let selectedChannel = viewModel.selectedColorChannel
                
                if viewModel.colorMixerMode == .color {
                    VStack(spacing: 8) {
                        AdjustmentSlider(
                            label: "Hue",
                            value: viewModel.profileBinding(for: selectedChannel, property: \.hue),
                            range: -1...1,
                            icon: "dial.min"
                        )
                        AdjustmentSlider(
                            label: "Saturation",
                            value: viewModel.profileBinding(for: selectedChannel, property: \.saturation),
                            range: -1...1,
                            icon: "drop.fill"
                        )
                        AdjustmentSlider(
                            label: "Luminance",
                            value: viewModel.profileBinding(for: selectedChannel, property: \.luminance),
                            range: -1...1,
                            icon: "sun.max.fill"
                        )
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                } else {
                    // Logic for property sliders is simplified for the sidebar view
                    VStack(spacing: 8) {
                        ForEach(Self.colorChips.prefix(4), id: \.name) { chip in
                            let name = chip.name
                            AdjustmentSlider(
                                label: name,
                                value: colorPropertyBinding(for: name),
                                range: -1...1,
                                icon: "circle.fill"
                            )
                            .tint(chip.color)
                        }
                    }
                }
            }
        }
    }

    private func colorPropertyBinding(for name: String) -> Binding<Float> {
        Binding(
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
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                    .shadow(color: color.opacity(isSelected ? 0.5 : 0.2), radius: isSelected ? 4 : 2)
                
                if isSelected {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 36, height: 36)
                }
            }
            .scaleEffect(isSelected ? 1.0 : 0.9)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slider Component

struct AdjustmentSlider: View {
    let label: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

