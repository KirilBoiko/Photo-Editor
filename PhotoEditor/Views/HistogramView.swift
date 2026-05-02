import SwiftUI

// MARK: - HistogramView
/// A high-performance histogram visualization using SwiftUI Canvas.
/// Uses immediate-mode drawing to avoid Path/Shape overhead for 256-bin data.
struct HistogramView: View {
    let data: ProcessingEngine.HistogramData
    
    var body: some View {
        ZStack {
            backgroundLayer
            
            if data != .empty {
                Canvas { context, size in
                    drawHistogram(in: context, size: size)
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
        // Flattens the view into a single GPU layer for smooth scrolling
        .drawingGroup()
    }
    
    private var backgroundLayer: some View {
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
        }
    }
    
    private func drawHistogram(in context: GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        
        // Render RGB channels with Screen blend mode
        var rgbLayer = context
        rgbLayer.blendMode = .screen
        
        // Red
        drawPath(data.red, in: rgbLayer, color: .red, width: width, height: height)
        // Green
        drawPath(data.green, in: rgbLayer, color: .green, width: width, height: height)
        // Blue
        drawPath(data.blue, in: rgbLayer, color: .blue, width: width, height: height)
        
        // Render Luminance on top
        drawLuminance(data.luminance, in: context, width: width, height: height)
    }
    
    private func drawPath(_ points: [CGFloat], in context: GraphicsContext, color: Color, width: CGFloat, height: CGFloat) {
        guard points.count == 256 else { return }
        
        let step = width / 255.0
        var path = Path()
        path.move(to: CGPoint(x: 0, y: height))
        
        for i in 0..<256 {
            let x = CGFloat(i) * step
            let y = height - (points[i] * height)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        
        let gradient = Gradient(colors: [color.opacity(0.6), color.opacity(0.1)])
        context.fill(path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
    }
    
    private func drawLuminance(_ points: [CGFloat], in context: GraphicsContext, width: CGFloat, height: CGFloat) {
        guard points.count == 256 else { return }
        
        let step = width / 255.0
        var path = Path()
        
        for i in 0..<256 {
            let x = CGFloat(i) * step
            let y = height - (points[i] * height)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        
        // Stroke
        context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        
        // Fill
        var fillPath = path
        fillPath.addLine(to: CGPoint(x: width, y: height))
        fillPath.addLine(to: CGPoint(x: 0, y: height))
        fillPath.closeSubpath()
        
        let gradient = Gradient(colors: [.white.opacity(0.3), .clear])
        var lumLayer = context
        lumLayer.blendMode = .plusLighter
        lumLayer.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
    }
}
