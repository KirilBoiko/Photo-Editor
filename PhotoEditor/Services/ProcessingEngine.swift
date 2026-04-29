import AppKit
import CoreImage
import Metal
import Vision

// MARK: - ProcessingEngine
/// GPU-accelerated image processing pipeline using Core Image and Metal.
///
/// Architecture:
/// - Creates a single `CIContext` backed by the default `MTLDevice`
///   (the M3 GPU), ensuring all rendering uses hardware acceleration.
/// - **Stage 1**: Global CIFilter chain (exposure, contrast, saturation, warmth, sharpness)
/// - **Stage 2**: Per-channel CIColorCube LUTs for AI Color Tones
/// - Core Image's lazy evaluation fuses ALL stages into a single GPU pass.
/// - All rendering happens on a dedicated background queue to keep the UI responsive.

final class ProcessingEngine: @unchecked Sendable {

    // MARK: - Properties

    /// Metal-backed Core Image context. Created once, reused for all renders.
    private let ciContext: CIContext

    /// Background queue for rendering. Serial to avoid race conditions.
    private let renderQueue = DispatchQueue(
        label: "com.photoeditor.renderqueue",
        qos: .userInitiated
    )

    /// LUT cache: avoids recomputing CIColorCube data when toggling chips on/off.
    /// Key: "ChannelName_hue_sat_lum" → Value: precomputed LUT Data.
    private var lutCache: [String: Data] = [:]

    /// LUT cube dimension. 64³ = 262,144 entries — good balance of precision vs speed.
    /// Computation takes ~1ms on CPU; the GPU applies it in microseconds.
    private static let lutDimension: Int = 64

    /// Cached subject mask from Vision
    private var cachedSubjectMask: CIImage? = nil

    // MARK: - Hue Ranges

    /// Hue ranges for each color channel (in 0.0–1.0 scale, where 1.0 = 360°).
    /// Each range defines the center and width of the hue band that channel targets.
    private static let hueRanges: [String: (center: Float, width: Float)] = [
        "Red":     (center: 0.0,    width: 30.0 / 360.0),  // 345°–15°  (wraps around 0°)
        "Orange":  (center: 30.0  / 360.0, width: 30.0 / 360.0),  // 15°–45°
        "Yellow":  (center: 60.0  / 360.0, width: 30.0 / 360.0),  // 45°–75°
        "Green":   (center: 120.0 / 360.0, width: 90.0 / 360.0),  // 75°–165°
        "Aqua":    (center: 180.0 / 360.0, width: 30.0 / 360.0),  // 165°–195°
        "Blue":    (center: 240.0 / 360.0, width: 90.0 / 360.0),  // 195°–285°
        "Purple":  (center: 285.0 / 360.0, width: 30.0 / 360.0),  // 270°–300°
        "Magenta": (center: 330.0 / 360.0, width: 30.0 / 360.0),  // 315°–345°
    ]

    // MARK: - Histogram
    
    struct HistogramData: Equatable {
        var red: [CGFloat] = []
        var green: [CGFloat] = []
        var blue: [CGFloat] = []
        var luminance: [CGFloat] = []
        
        static let empty = HistogramData(
            red: Array(repeating: 0, count: 256),
            green: Array(repeating: 0, count: 256),
            blue: Array(repeating: 0, count: 256),
            luminance: Array(repeating: 0, count: 256)
        )
    }

    // MARK: - Initialization

    init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(
                mtlDevice: metalDevice,
                options: [
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                    .cacheIntermediates: true
                ]
            )
        } else {
            self.ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
            ])
        }
    }

    // MARK: - Public API

    /// Applies global adjustments and enabled color profiles to a source image.
    ///
    /// - Parameters:
    ///   - adjustments: The `ImageAdjustments` containing global + per-channel values.
    ///   - source: The input `CIImage` (EXIF orientation pre-applied).
    ///   - enabledProfiles: Dictionary of channel name → enabled state. Only enabled
    ///     channels have their CIColorCube applied.
    /// - Returns: A tuple containing the rendered `NSImage` and its `HistogramData`.
    func apply(
        adjustments: ImageAdjustments,
        to source: CIImage
    ) async throws -> (NSImage, HistogramData) {
        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                // Stage 1: Global filters + Stage 2: Color profiles
                let output = self.buildFullPipeline(
                    source: source,
                    adjustments: adjustments
                )

                guard let cgImage = self.ciContext.createCGImage(output, from: output.extent) else {
                    continuation.resume(throwing: ProcessingError.renderFailed)
                    return
                }

                let nsImage = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                
                // Stage 3: Generate Histogram
                let histogram = self.generateHistogram(from: output)

                continuation.resume(returning: (nsImage, histogram))
            }
        }
    }

    /// Exports the processed image as full-resolution JPEG data.
    func exportJPEG(
        source: CIImage,
        adjustments: ImageAdjustments,
        quality: CGFloat = 0.95
    ) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                let output = self.buildFullPipeline(
                    source: source,
                    adjustments: adjustments
                )

                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                    continuation.resume(throwing: ProcessingError.renderFailed)
                    return
                }

                guard let jpegData = self.ciContext.jpegRepresentation(
                    of: output,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                ) else {
                    continuation.resume(throwing: ProcessingError.renderFailed)
                    return
                }

                continuation.resume(returning: jpegData)
            }
        }
    }
    
    // MARK: - Histogram Generation
    
    /// Generates a normalized RGB and Luminance histogram using Core Image's hardware-accelerated filters.
    private func generateHistogram(from ciImage: CIImage) -> HistogramData {
        guard let histogramFilter = CIFilter(name: "CIAreaHistogram") else { return .empty }
        
        // Use a scaled-down version of the image to make histogram generation faster
        // A 500px width is plenty for a representative 256-bin histogram
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        let scale = min(1.0, 500.0 / ciImage.extent.width)
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        
        guard let scaledImage = scaleFilter.outputImage else { return .empty }
        
        histogramFilter.setValue(scaledImage, forKey: kCIInputImageKey)
        histogramFilter.setValue(CIVector(cgRect: scaledImage.extent), forKey: kCIInputExtentKey)
        histogramFilter.setValue(256, forKey: "inputCount")
        histogramFilter.setValue(1.0, forKey: "inputScale")
        
        guard let outputImage = histogramFilter.outputImage else { return .empty }
        
        // Render the 256x1 output into a float4 array
        var bitmap = [SIMD4<Float>](repeating: .zero, count: 256)
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 1)
        
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 256 * MemoryLayout<SIMD4<Float>>.stride,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: nil
        )
        
        // Find max value to normalize (excluding the 0 and 255 bins which can spike due to clipping)
        var maxVal: Float = 0.001 // prevent division by zero
        for i in 1..<255 {
            let pixel = bitmap[i]
            let m = max(pixel.x, max(pixel.y, pixel.z))
            if m > maxVal { maxVal = m }
        }
        
        var data = HistogramData.empty
        for i in 0..<256 {
            let pixel = bitmap[i]
            // Scale and clamp so the curve fits in the UI
            data.red[i] = CGFloat(min(1.0, pixel.x / maxVal))
            data.green[i] = CGFloat(min(1.0, pixel.y / maxVal))
            data.blue[i] = CGFloat(min(1.0, pixel.z / maxVal))
            // Approximate luminance from RGB bin counts (this isn't perfect since it's the frequency of R/G/B at that intensity, but good enough for visual "pop" representation)
            // A true luminance histogram would require a grayscale conversion pass first.
            data.luminance[i] = CGFloat(min(1.0, (pixel.x * 0.2126 + pixel.y * 0.7152 + pixel.z * 0.0722) / maxVal))
        }
        
        return data
    }

    func clearMaskCache() {
        renderQueue.sync {
            cachedSubjectMask = nil
        }
    }

    /// Asynchronously generates a foreground instance mask using Vision.
    func generateSubjectMask(from ciImage: CIImage) async throws -> CIImage? {
        if let cached = cachedSubjectMask { return cached }

        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async {
                if #available(macOS 14.0, *) {
                    let request = VNGenerateForegroundInstanceMaskRequest()
                    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                    do {
                        try handler.perform([request])
                        if let result = request.results?.first {
                            let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                            var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

                            // Ensure mask is sized to exactly the source image extent
                            let scaleX = ciImage.extent.width / maskImage.extent.width
                            let scaleY = ciImage.extent.height / maskImage.extent.height
                            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                            
                            self.cachedSubjectMask = maskImage
                            continuation.resume(returning: maskImage)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Full Pipeline

    /// Builds the complete multi-stage filter pipeline.
    private func buildFullPipeline(
        source: CIImage,
        adjustments: ImageAdjustments
    ) -> CIImage {
        
        let globalLayer = buildLayer(source: source, adjustments: adjustments.global)

        guard adjustments.hasLayerAdjustments, let mask = cachedSubjectMask else {
            return globalLayer
        }

        var subjectResult = source
        var backgroundResult = source

        if let subjectAdjustments = adjustments.subject, !subjectAdjustments.isIdentity {
            subjectResult = buildLayer(source: source, adjustments: subjectAdjustments)
        } else {
            subjectResult = globalLayer
        }

        if let backgroundAdjustments = adjustments.background, !backgroundAdjustments.isIdentity {
            backgroundResult = buildLayer(source: source, adjustments: backgroundAdjustments)
        } else {
            backgroundResult = globalLayer
        }

        // Blend subject and background
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return globalLayer }
        blendFilter.setValue(subjectResult, forKey: kCIInputImageKey)
        blendFilter.setValue(backgroundResult, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)

        if let blended = blendFilter.outputImage {
            // Apply global adjustments to the final composite
            return buildLayer(source: blended, adjustments: adjustments.global)
        }

        return globalLayer
    }

    // MARK: - Layer Filter Chain

    private func buildLayer(
        source: CIImage,
        adjustments: LayerAdjustments
    ) -> CIImage {
        var image = Self.buildGlobalFilterChain(source: source, adjustments: adjustments)

        if let profiles = adjustments.aiColorProfiles {
            image = applyColorProfiles(
                to: image,
                profiles: profiles
            )
        }

        return image
    }

    /// Applies the 5 global adjustment filters.
    private static func buildGlobalFilterChain(
        source: CIImage,
        adjustments: LayerAdjustments
    ) -> CIImage {
        var image = source

        // Use resolved* properties which default nil → 0.0
        let exp = adjustments.resolvedExposure
        let con = adjustments.resolvedContrast
        let sat = adjustments.resolvedSaturation
        let wrm = adjustments.resolvedWarmth
        let shp = adjustments.resolvedSharpness

        // 1. Exposure — CIExposureAdjust
        if exp != 0.0 {
            let exposureFilter = CIFilter(name: "CIExposureAdjust")!
            exposureFilter.setValue(image, forKey: kCIInputImageKey)
            exposureFilter.setValue(exp * 3.0, forKey: kCIInputEVKey)
            if let output = exposureFilter.outputImage {
                image = output
            }
        }

        // 2. Contrast + Saturation — CIColorControls
        if con != 0.0 || sat != 0.0 {
            let colorFilter = CIFilter(name: "CIColorControls")!
            colorFilter.setValue(image, forKey: kCIInputImageKey)
            colorFilter.setValue(1.0 + con * 0.5, forKey: kCIInputContrastKey)
            colorFilter.setValue(1.0 + sat, forKey: kCIInputSaturationKey)
            colorFilter.setValue(Float(0.0), forKey: kCIInputBrightnessKey)
            if let output = colorFilter.outputImage {
                image = output
            }
        }

        // 3. Warmth — CITemperatureAndTint
        if wrm != 0.0 {
            let tempFilter = CIFilter(name: "CITemperatureAndTint")!
            tempFilter.setValue(image, forKey: kCIInputImageKey)
            let neutralTemp: Float = 6500.0
            let tempShift = wrm * 1500.0
            tempFilter.setValue(
                CIVector(x: CGFloat(neutralTemp + tempShift), y: 0),
                forKey: "inputNeutral"
            )
            tempFilter.setValue(
                CIVector(x: CGFloat(neutralTemp), y: 0),
                forKey: "inputTargetNeutral"
            )
            if let output = tempFilter.outputImage {
                image = output
            }
        }

        // 4. Sharpness — CISharpenLuminance
        if shp > 0.0 {
            let sharpenFilter = CIFilter(name: "CISharpenLuminance")!
            sharpenFilter.setValue(image, forKey: kCIInputImageKey)
            sharpenFilter.setValue(shp * 2.0, forKey: kCIInputSharpnessKey)
            sharpenFilter.setValue(Float(1.69), forKey: kCIInputRadiusKey)
            if let output = sharpenFilter.outputImage {
                image = output
            }
        }

        return image
    }

    // MARK: - Stage 2: Per-Channel Color Profiles

    /// Applies CIColorCube filters for each enabled color channel.
    ///
    /// Each channel gets its own 64³ LUT that:
    /// 1. Identifies pixels whose hue falls within the channel's range
    /// 2. Applies the HSL shift to those pixels
    /// 3. Passes all other pixels through unchanged
    ///
    /// Core Image fuses all these into a single GPU pass via lazy evaluation.
    private func applyColorProfiles(
        to image: CIImage,
        profiles: [String: ColorProfile]
    ) -> CIImage {
        var result = image
        
        // Debug print to verify which channels are actively being processed by the M3 GPU
        let enabledChannels = ColorChannel.allCases
            .filter { profiles[$0.rawValue]?.isIdentity == false }
            .map { $0.rawValue }
        print("Processing Engine: Applying HSL for \(enabledChannels.count) colors")

        for channel in ColorChannel.allCases {
            let name = channel.rawValue

            // Skip identity/missing channels
            guard let profile = profiles[name],
                  !profile.isIdentity else {
                continue
            }

            // Get or compute the LUT for this channel+profile combination
            let lutData = colorCubeLUT(for: name, profile: profile)

            // Apply CIColorCube
            let cubeFilter = CIFilter(name: "CIColorCube")!
            cubeFilter.setValue(result, forKey: kCIInputImageKey)
            cubeFilter.setValue(Self.lutDimension, forKey: "inputCubeDimension")
            cubeFilter.setValue(lutData, forKey: "inputCubeData")

            if let output = cubeFilter.outputImage {
                result = output
            }
        }

        return result
    }

    // MARK: - CIColorCube LUT Generation

    /// Returns a cached or freshly computed 64³ color cube LUT for the given channel.
    private func colorCubeLUT(for channelName: String, profile: ColorProfile) -> Data {
        // Cache key encodes the channel + resolved profile values
        let cacheKey = "\(channelName)_\(profile.resolvedHue)_\(profile.resolvedSaturation)_\(profile.resolvedLuminance)"

        if let cached = lutCache[cacheKey] {
            return cached
        }

        let data = Self.generateColorCubeLUT(for: channelName, profile: profile)
        lutCache[cacheKey] = data
        return data
    }

    /// Generates a 64³ RGBA float color cube LUT that applies HSL shifts
    /// only to pixels within the specified channel's hue range.
    private static func generateColorCubeLUT(
        for channelName: String,
        profile: ColorProfile
    ) -> Data {
        let dim = lutDimension
        let totalEntries = dim * dim * dim
        var lutFloats = [Float](repeating: 0, count: totalEntries * 4) // RGBA

        guard let range = hueRanges[channelName] else {
            return generateIdentityLUT()
        }

        let hueCenter = range.center
        let hueHalfWidth = range.width

        // Resolve optional values to Float once
        let profileHue = profile.resolvedHue
        let profileSat = profile.resolvedSaturation
        let profileLum = profile.resolvedLuminance

        for b in 0..<dim {
            for g in 0..<dim {
                for r in 0..<dim {
                    let index = (b * dim * dim + g * dim + r) * 4

                    let rf = Float(r) / Float(dim - 1)
                    let gf = Float(g) / Float(dim - 1)
                    let bf = Float(b) / Float(dim - 1)

                    var (h, s, l) = rgbToHSL(r: rf, g: gf, b: bf)

                    let influence = hueInfluence(pixelHue: h, center: hueCenter, halfWidth: hueHalfWidth)

                    if influence > 0.001 {
                        h = fmodf(h + profileHue * 0.083 * influence + 1.0, 1.0) // ±30° max
                        s = max(0, min(1, s + profileSat * 0.5 * influence))
                        l = max(0, min(1, l + profileLum * 0.3 * influence))
                    }

                    // Convert back to RGB
                    let (rOut, gOut, bOut) = hslToRGB(h: h, s: s, l: l)

                    lutFloats[index + 0] = rOut
                    lutFloats[index + 1] = gOut
                    lutFloats[index + 2] = bOut
                    lutFloats[index + 3] = 1.0 // Alpha
                }
            }
        }

        return Data(bytes: lutFloats, count: lutFloats.count * MemoryLayout<Float>.size)
    }

    /// Generates an identity (passthrough) LUT.
    private static func generateIdentityLUT() -> Data {
        let dim = lutDimension
        var lutFloats = [Float](repeating: 0, count: dim * dim * dim * 4)

        for b in 0..<dim {
            for g in 0..<dim {
                for r in 0..<dim {
                    let index = (b * dim * dim + g * dim + r) * 4
                    lutFloats[index + 0] = Float(r) / Float(dim - 1)
                    lutFloats[index + 1] = Float(g) / Float(dim - 1)
                    lutFloats[index + 2] = Float(b) / Float(dim - 1)
                    lutFloats[index + 3] = 1.0
                }
            }
        }

        return Data(bytes: lutFloats, count: lutFloats.count * MemoryLayout<Float>.size)
    }

    // MARK: - Hue Influence

    /// Calculates how much a pixel's hue is influenced by a given channel.
    /// Returns 0.0 (outside range) to 1.0 (at center), with smooth cosine falloff.
    private static func hueInfluence(pixelHue: Float, center: Float, halfWidth: Float) -> Float {
        // Calculate shortest angular distance on the hue circle
        var delta = abs(pixelHue - center)
        if delta > 0.5 {
            delta = 1.0 - delta  // Wrap around (e.g., Red spans 345°–15°)
        }

        if delta > halfWidth {
            return 0.0  // Outside the channel's range
        }

        // Smooth cosine falloff: 1.0 at center, 0.0 at edge
        let t = delta / halfWidth
        return (cosf(t * .pi) + 1.0) * 0.5
    }

    // MARK: - Color Space Conversion

    /// Converts RGB (0–1) to HSL (0–1).
    private static func rgbToHSL(r: Float, g: Float, b: Float) -> (h: Float, s: Float, l: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        // Luminance
        let l = (maxC + minC) * 0.5

        // Achromatic
        if delta < 0.00001 {
            return (0.0, 0.0, l)
        }

        // Saturation
        let s = l > 0.5 ? delta / (2.0 - maxC - minC) : delta / (maxC + minC)

        // Hue
        var h: Float
        if maxC == r {
            h = (g - b) / delta + (g < b ? 6.0 : 0.0)
        } else if maxC == g {
            h = (b - r) / delta + 2.0
        } else {
            h = (r - g) / delta + 4.0
        }
        h /= 6.0

        return (h, s, l)
    }

    /// Converts HSL (0–1) to RGB (0–1).
    private static func hslToRGB(h: Float, s: Float, l: Float) -> (r: Float, g: Float, b: Float) {
        if s < 0.00001 {
            return (l, l, l)  // Achromatic
        }

        let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        let p = 2.0 * l - q

        let r = hueToRGB(p: p, q: q, t: h + 1.0 / 3.0)
        let g = hueToRGB(p: p, q: q, t: h)
        let b = hueToRGB(p: p, q: q, t: h - 1.0 / 3.0)

        return (r, g, b)
    }

    /// Helper for HSL→RGB conversion.
    private static func hueToRGB(p: Float, q: Float, t: Float) -> Float {
        var t = t
        if t < 0 { t += 1.0 }
        if t > 1 { t -= 1.0 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
        return p
    }

    /// Clears the LUT cache (call when adjustments change from the API).
    func clearLUTCache() {
        lutCache.removeAll()
    }
}

// MARK: - Errors

enum ProcessingError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "GPU rendering failed. The image may be too large or the system is out of memory."
        }
    }
}
