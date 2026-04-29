import Foundation

// MARK: - ColorProfile
/// Per-channel HSL adjustment values returned by the Gemini AI.
/// All properties are optional to handle cases where the AI omits a value.

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
    let aiColorProfiles: [String: ColorProfile]?

    init(
        exposure: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        warmth: Double? = nil,
        sharpness: Double? = nil,
        aiColorProfiles: [String: ColorProfile]? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.sharpness = sharpness
        self.aiColorProfiles = aiColorProfiles
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, warmth, sharpness
        case aiColorProfiles
    }

    // MARK: - Resolved Values (nil → 0.0)

    var resolvedExposure: Float { Float(exposure ?? 0.0) }
    var resolvedContrast: Float { Float(contrast ?? 0.0) }
    var resolvedSaturation: Float { Float(saturation ?? 0.0) }
    var resolvedWarmth: Float { Float(warmth ?? 0.0) }
    var resolvedSharpness: Float { Float(sharpness ?? 0.0) }

    // MARK: - Identity

    static let identity = LayerAdjustments(
        exposure: 0.0, contrast: 0.0, saturation: 0.0, warmth: 0.0, sharpness: 0.0,
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
            aiColorProfiles: clampedProfiles
        )
    }

    /// Whether all adjustments are at identity.
    var isIdentity: Bool {
        resolvedExposure == 0.0 && resolvedContrast == 0.0 &&
        resolvedSaturation == 0.0 && resolvedWarmth == 0.0 && resolvedSharpness == 0.0 &&
        (aiColorProfiles == nil || aiColorProfiles!.values.allSatisfy { $0.isIdentity })
    }
}

// MARK: - ImageAdjustments
/// Top-level model containing up to three independent editing layers.
/// The AI can populate all three; the user can edit them via the layer picker.

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
