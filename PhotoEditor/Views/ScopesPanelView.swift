import SwiftUI

// MARK: - ScopesPanelView
struct ScopesPanelView: View {
    @ObservedObject var viewModel: PhotoEditorViewModel
    @State private var isExpanded: Bool = false
    @State private var selectedScope: ScopeType = .waveform

    enum ScopeType: String, CaseIterable {
        case waveform = "Waveform"
        case vectorscope = "Vectorscope"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerButton
            
            if isExpanded {
                scopePicker
                
                let scopeData = viewModel.scopeData
                
                Group {
                    switch selectedScope {
                    case .waveform:
                        WaveformView(data: scopeData.waveform)
                    case .vectorscope:
                        VectorscopeView(data: scopeData.vectorscope)
                    }
                }
                .transition(.opacity)

                metadataView(for: scopeData)
            }
        }
    }

    private var headerButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Label("Scopes", systemImage: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $selectedScope) {
            ForEach(ScopeType.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func metadataView(for scopeData: ProcessingEngine.ScopeData) -> some View {
        HStack(spacing: 12) {
            if selectedScope == .vectorscope {
                Label(scopeData.vectorscope.skewDescription, systemImage: "paintpalette")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Spread: \(String(format: "%.0f", scopeData.waveformSpread * 100))%",
                    systemImage: "chart.bar"
                )
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - WaveformView
struct WaveformView: View {
    let data: ProcessingEngine.WaveformData

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)

            referenceLines
            
            if !data.columns.isEmpty {
                waveformCanvas
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var referenceLines: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.15))
            Spacer()
            Divider().overlay(Color.white.opacity(0.15))
            Spacer()
            Divider().overlay(Color.white.opacity(0.15))
        }
        .padding(.horizontal, 2)
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            let colWidth = size.width / CGFloat(data.columns.count)
            for (colIdx, column) in data.columns.enumerated() {
                let x = CGFloat(colIdx) * colWidth
                for bin in 0..<256 {
                    let intensity = column[bin]
                    guard intensity > 0.01 else { continue }
                    let y = size.height - (CGFloat(bin) / 255.0) * size.height
                    context.fill(
                        Path(CGRect(x: x, y: y, width: colWidth, height: 1)),
                        with: .color(Color.green.opacity(Double(intensity) * 0.8))
                    )
                }
            }
        }
        .padding(2)
    }
}

// MARK: - VectorscopeView
struct VectorscopeView: View {
    let data: ProcessingEngine.VectorscopeData

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)

            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = size / 2 - 8

                graticuleLayer(center: center, radius: radius)
                skinToneLine(center: center, radius: radius)
                vectorscopeCanvas(center: center, radius: radius)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func graticuleLayer(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    .frame(width: radius * 2 * CGFloat(fraction), height: radius * 2 * CGFloat(fraction))
                    .position(center)
            }
            Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - radius))
                path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                path.move(to: CGPoint(x: center.x - radius, y: center.y))
                path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            }
            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func skinToneLine(center: CGPoint, radius: CGFloat) -> some View {
        let skinAngle: CGFloat = 123.0 * .pi / 180.0
        return ZStack {
            Path { path in
                path.move(to: center)
                path.addLine(to: CGPoint(
                    x: center.x + cos(skinAngle) * radius,
                    y: center.y - sin(skinAngle) * radius
                ))
            }
            .stroke(Color.yellow.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            Text("I")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.yellow.opacity(0.5))
                .position(
                    x: center.x + cos(skinAngle) * (radius + 8),
                    y: center.y - sin(skinAngle) * (radius + 8)
                )
        }
    }

    private func vectorscopeCanvas(center: CGPoint, radius: CGFloat) -> some View {
        Canvas { context, _ in
            for point in data.points {
                let px = center.x + point.u * radius * 2
                let py = center.y - point.v * radius * 2
                let dist = sqrt(point.u * point.u + point.v * point.v)
                let alpha = min(0.6, 0.15 + dist)
                context.fill(
                    Path(ellipseIn: CGRect(x: px - 1, y: py - 1, width: 2, height: 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
    }
}
