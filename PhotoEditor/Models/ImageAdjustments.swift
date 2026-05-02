import Foundation

// MARK: - ColorProfile
/// Per-channel HSL adjustment values.
/// All properties are optional to allow partial updates.

struct ColorProfile: Codable, Equatable {
    /// Hue rotation for this color channel (-1.0 ... 1.0).
    let hue: Double?

    /// Saturation boost/cut for this color channel (-1.0 ... 1.0).
    let saturation: Double?

    /// Luminance boost/cut for this color channel (-1.0 ... 1.0).
    let luminance: Double?

    /// No change baseline.
    static let identity = ColorProfile(hue: 0.0, saturation: 0.0, luminance: 0.0)

    /// Resolved values with nil → 0.0 defaults.
    var resolvedHue: Float { Float(hue ?? 0.0) }
    var resolvedSaturation: Float { Float(saturation ?? 0.0) }
    var resolvedLuminance: Float { Float(luminance ?? 0.0) }

    /// Returns true if this profile has no effect.
    var isIdentity: Bool {
        resolvedHue == 0.0 && resolvedSaturation == 0.0 && resolvedLuminance == 0.0
    }

    /// Clamps all values to the valid -1.0 ... 1.0 range.
    func clamped() -> ColorProfile {
        ColorProfile(
            hue: min(max(hue ?? 0.0, -1.0), 1.0),
            saturation: min(max(saturation ?? 0.0, -1.0), 1.0),
            luminance: min(max(luminance ?? 0.0, -1.0), 1.0)
        )
    }
}

// MARK: - Color Channel Definitions

enum ColorChannel: String, CaseIterable, Codable {
    case Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta

    static let allNames: [String] = allCases.map { $0.rawValue }
}

// MARK: - LayerAdjustments
/// A single editing layer's adjustments: 5 global sliders + per-channel HSL profiles.
/// Used for global, subject, and background layers independently.

struct LayerAdjustments: Codable, Equatable {
    let exposure: Double?
    let contrast: Double?
    let saturation: Double?
    let warmth: Double?
    let sharpness: Double?
    let shadows: Double?
    let highlights: Double?
    let blur: Double?
    let aiColorProfiles: [String: ColorProfile]?

    init(
        exposure: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        warmth: Double? = nil,
        sharpness: Double? = nil,
        shadows: Double? = nil,
        highlights: Double? = nil,
        blur: Double? = nil,
        aiColorProfiles: [String: ColorProfile]? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.sharpness = sharpness
        self.shadows = shadows
        self.highlights = highlights
        self.blur = blur
        self.aiColorProfiles = aiColorProfiles
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, warmth, sharpness
        case shadows, highlights, blur
        case aiColorProfiles
    }

    // MARK: - Resolved Values (nil → 0.0)

    var resolvedExposure: Float { Float(exposure ?? 0.0) }
    var resolvedContrast: Float { Float(contrast ?? 0.0) }
    var resolvedSaturation: Float { Float(saturation ?? 0.0) }
    var resolvedWarmth: Float { Float(warmth ?? 0.0) }
    var resolvedSharpness: Float { Float(sharpness ?? 0.0) }
    var resolvedShadows: Float { Float(shadows ?? 0.0) }
    var resolvedHighlights: Float { Float(highlights ?? 0.0) }
    var resolvedBlur: Float { Float(blur ?? 0.0) }

    // MARK: - Identity

    static let identity = LayerAdjustments(
        exposure: 0.0, contrast: 0.0, saturation: 0.0, warmth: 0.0, sharpness: 0.0,
        shadows: 0.0, highlights: 0.0, blur: 0.0,
        aiColorProfiles: nil
    )

    // MARK: - Clamping

    func clamped() -> LayerAdjustments {
        var clampedProfiles: [String: ColorProfile]? = nil
        if let profiles = aiColorProfiles {
            clampedProfiles = [:]
            for (key, profile) in profiles {
                clampedProfiles?[key] = profile.clamped()
            }
        }
        return LayerAdjustments(
            exposure: min(max(exposure ?? 0.0, -1.0), 1.0),
            contrast: min(max(contrast ?? 0.0, -1.0), 1.0),
            saturation: min(max(saturation ?? 0.0, -1.0), 1.0),
            warmth: min(max(warmth ?? 0.0, -1.0), 1.0),
            sharpness: min(max(sharpness ?? 0.0, -1.0), 1.0),
            shadows: min(max(shadows ?? 0.0, -1.0), 1.0),
            highlights: min(max(highlights ?? 0.0, -1.0), 1.0),
            blur: min(max(blur ?? 0.0, -1.0), 1.0),
            aiColorProfiles: clampedProfiles
        )
    }

    /// Whether all adjustments are at identity.
    var isIdentity: Bool {
        resolvedExposure == 0.0 && resolvedContrast == 0.0 &&
        resolvedSaturation == 0.0 && resolvedWarmth == 0.0 && resolvedSharpness == 0.0 &&
        resolvedShadows == 0.0 && resolvedHighlights == 0.0 && resolvedBlur == 0.0 &&
        (aiColorProfiles == nil || aiColorProfiles!.values.allSatisfy { $0.isIdentity })
    }
}

// MARK: - ImageStatistics
/// Precise histogram-derived technical data computed from the source image.
/// Used to anchor enhancement decisions in measurable data.

struct ImageStatistics: Codable, Equatable {
    /// Average luminance of the image (0.0 = black, 1.0 = white). Target: ~0.5.
    let meanBrightness: Double

    /// Luminance variance — a measure of tonal range / contrast.
    let contrastScore: Double

    /// Percentage of pixels in the 0.0–0.05 luminance range (blocked blacks).
    let shadowClipping: Double

    /// Percentage of pixels in the 0.95–1.0 luminance range (blown highlights).
    let highlightClipping: Double

    /// Average R, G, B channel ratios (each 0.0–1.0). Used to detect color casts.
    let colorBalance: [String: Double]

    /// 3x3 grid of local brightness values (left-to-right, top-to-bottom).
    /// Each value is the average luminance of that zone (0.0–1.0).
    let zonalBrightness: [Double]

    /// Max zone brightness minus min zone brightness. Measures spatial contrast.
    let dynamicRangeDepth: Double

    /// Average brightness of the center-weighted zones (indices 1, 3, 4, 5, 7).
    let subjectZoneBrightness: Double

    /// Human-readable summary for console debugging.
    var debugDescription: String {
        let zonal = zonalBrightness.map { String(format: "%.2f", $0) }
        return """
        📊 Analysis: Brightness \(String(format: "%.3f", meanBrightness)), \
        Contrast \(String(format: "%.4f", contrastScore)), \
        Clipping S:\(String(format: "%.1f", shadowClipping * 100))% H:\(String(format: "%.1f", highlightClipping * 100))%
        📐 Zonal Map:
          [ \(zonal[0]),  \(zonal[1]),  \(zonal[2]) ]
          [ \(zonal[3]),  \(zonal[4]),  \(zonal[5]) ]
          [ \(zonal[6]),  \(zonal[7]),  \(zonal[8]) ]
        🎯 Subject Zone: \(String(format: "%.3f", subjectZoneBrightness)), Dynamic Range: \(String(format: "%.3f", dynamicRangeDepth))
        """
    }

    /// Formats the stats into a structured block for the enhancement prompt.
    var aiPromptBlock: String {
        let z = zonalBrightness.map { String(format: "%.3f", $0) }
        return """
        HISTOGRAM DATA FOR CURRENT FRAME:
        - Mean Brightness: \(String(format: "%.3f", meanBrightness)) (Target: 0.5)
        - Contrast Score: \(String(format: "%.4f", contrastScore))
        - Shadow Clipping: \(String(format: "%.1f", shadowClipping * 100))% (High values indicate blocked blacks)
        - Highlight Clipping: \(String(format: "%.1f", highlightClipping * 100))% (High values indicate blown skies)
        - Color Balance: R=\(String(format: "%.3f", colorBalance["red"] ?? 0)) G=\(String(format: "%.3f", colorBalance["green"] ?? 0)) B=\(String(format: "%.3f", colorBalance["blue"] ?? 0))

        SPATIAL LIGHT MAP (3x3 Grid, 0.0=black 1.0=white):
        [ \(z[0]),  \(z[1]),  \(z[2]) ]
        [ \(z[3]),  \(z[4]),  \(z[5]) ]
        [ \(z[6]),  \(z[7]),  \(z[8]) ]

        Dynamic Range Depth: \(String(format: "%.3f", dynamicRangeDepth))
        Subject Area Brightness: \(String(format: "%.3f", subjectZoneBrightness))
        """
    }
}

// MARK: - ImageAdjustments
/// Top-level model containing up to three independent editing layers.
/// All three can be populated programmatically; the user edits them via the layer picker.

struct ImageAdjustments: Codable, Equatable {
    /// Always-present base layer.
    let global: LayerAdjustments

    /// Optional foreground subject layer (requires Vision mask).
    let subject: LayerAdjustments?

    /// Optional background layer (requires Vision mask).
    let background: LayerAdjustments?

    init(
        global: LayerAdjustments,
        subject: LayerAdjustments? = nil,
        background: LayerAdjustments? = nil
    ) {
        self.global = global
        self.subject = subject
        self.background = background
    }

    enum CodingKeys: String, CodingKey {
        case global, subject, background
    }

    // MARK: - Identity

    static let identity = ImageAdjustments(
        global: .identity, subject: nil, background: nil
    )

    // MARK: - Clamping

    func clamped() -> ImageAdjustments {
        ImageAdjustments(
            global: global.clamped(),
            subject: subject?.clamped(),
            background: background?.clamped()
        )
    }

    /// Whether all layers are at identity.
    var isAllIdentity: Bool {
        global.isIdentity &&
        (subject == nil || subject!.isIdentity) &&
        (background == nil || background!.isIdentity)
    }

    /// Convenience: does this have any layer-specific adjustments?
    var hasLayerAdjustments: Bool {
        subject != nil || background != nil
    }
}
