import SwiftUI
import CoreImage
import Combine

// MARK: - PhotoEditorViewModel
/// Central coordinator for the photo editor, managing state, user actions,
/// and the pipeline from image import → AI analysis → CIFilter rendering → export.
///
/// Marked `@MainActor` because all `@Published` properties drive SwiftUI views.
/// Heavy work (GPU rendering, network calls) is dispatched off the main thread
/// by `ProcessingEngine` and `NetworkManager` respectively.

@MainActor
final class PhotoEditorViewModel: ObservableObject {

    // MARK: - Published State

    /// The loaded photo document (nil until user imports a JPEG).
    @Published var document: PhotoDocument?

    /// The original image for display in the "Before" side.
    @Published var originalImage: NSImage?

    /// The processed image for display in the "After" side.
    @Published var processedImage: NSImage?

    enum LayerType: String, CaseIterable, Identifiable {
        case global = "Global"
        case subject = "Subject"
        case background = "Background"
        var id: String { self.rawValue }
    }

    struct LayerState: Equatable {
        var exposure: Float = 0.0
        var contrast: Float = 0.0
        var saturation: Float = 0.0
        var warmth: Float = 0.0
        var sharpness: Float = 0.0
        var colorProfiles: [String: UIProfile] = PhotoEditorViewModel.defaultColorProfiles

        var isIdentity: Bool {
            exposure == 0 && contrast == 0 && saturation == 0 &&
            warmth == 0 && sharpness == 0 && colorProfiles == PhotoEditorViewModel.defaultColorProfiles
        }

        func toLayerAdjustments() -> LayerAdjustments {
            let mappedProfiles = colorProfiles.mapValues { $0.toColorProfile }
            return LayerAdjustments(
                exposure: Double(exposure),
                contrast: Double(contrast),
                saturation: Double(saturation),
                warmth: Double(warmth),
                sharpness: Double(sharpness),
                aiColorProfiles: mappedProfiles
            )
        }

        mutating func update(from layerAdjustments: LayerAdjustments) {
            if let exp = layerAdjustments.exposure { self.exposure = Float(exp) }
            if let con = layerAdjustments.contrast { self.contrast = Float(con) }
            if let sat = layerAdjustments.saturation { self.saturation = Float(sat) }
            if let wrm = layerAdjustments.warmth { self.warmth = Float(wrm) }
            if let shp = layerAdjustments.sharpness { self.sharpness = Float(shp) }
            
            if let profiles = layerAdjustments.aiColorProfiles {
                for (channel, profile) in profiles {
                    self.colorProfiles[channel] = UIProfile(
                        hue: Float(profile.hue ?? 0.0),
                        saturation: Float(profile.saturation ?? 0.0),
                        luminance: Float(profile.luminance ?? 0.0)
                    )
                }
            }
        }
    }

    @Published var selectedLayer: LayerType = .global
    @Published var globalSliders = LayerState()
    @Published var subjectSliders = LayerState()
    @Published var backgroundSliders = LayerState()
    
    @Published var isMaskAvailable: Bool = false

    // MARK: - Color Mixer State
    
    enum ColorMixerMode: String, CaseIterable {
        case color = "Color"
        case hue = "Hue"
        case saturation = "Saturation"
        case luminance = "Luminance"
    }
    
    struct UIProfile: Equatable {
        var hue: Float = 0.0
        var saturation: Float = 0.0
        var luminance: Float = 0.0
        
        var toColorProfile: ColorProfile {
            ColorProfile(hue: Double(hue), saturation: Double(saturation), luminance: Double(luminance))
        }
    }
    
    @Published var colorMixerMode: ColorMixerMode = .color
    @Published var selectedColorChannel: String = "Red"

    /// True while the ProcessingEngine is rendering.
    @Published var isProcessing: Bool = false
    
    /// Real-time histogram data extracted from the rendering pipeline
    @Published var histogramData: ProcessingEngine.HistogramData = .empty

    /// True while the Gemini API call is in flight.
    @Published var isAnalyzing: Bool = false

    /// User-facing error message.
    @Published var errorMessage: String?

    /// Whether an error alert is presented.
    @Published var showErrorAlert: Bool = false

    // MARK: - Defaults

    static let defaultColorProfiles: [String: UIProfile] = {
        var profiles: [String: UIProfile] = [:]
        for channel in ColorChannel.allCases {
            profiles[channel.rawValue] = UIProfile()
        }
        return profiles
    }()

    // MARK: - Services

    private let processingEngine = ProcessingEngine()

    // MARK: - Debounce

    private var renderCancellable: AnyCancellable?
    private static let debounceInterval: TimeInterval = 0.05

    // MARK: - Computed

    /// Builds an ImageAdjustments from the current slider values for the processing engine.
    var currentAdjustments: ImageAdjustments {
        return ImageAdjustments(
            global: globalSliders.toLayerAdjustments(),
            subject: subjectSliders.isIdentity ? nil : subjectSliders.toLayerAdjustments(),
            background: backgroundSliders.isIdentity ? nil : backgroundSliders.toLayerAdjustments()
        )
    }

    /// Whether any adjustment is non-zero.
    var hasChanges: Bool {
        !globalSliders.isIdentity || !subjectSliders.isIdentity || !backgroundSliders.isIdentity
    }

    // MARK: - Initialization

    init() {
        // Debounced render: any @Published change triggers re-render after 50ms
        // We use a single timer that fires on any objectWillChange
        renderCancellable = objectWillChange
            .debounce(for: .seconds(Self.debounceInterval), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.renderProcessedImage()
                }
            }
    }

    // MARK: - User Actions

    /// Opens an `NSOpenPanel` for the user to select a JPEG file.
    func importPhoto() {
        let panel = NSOpenPanel()
        panel.title = "Select a JPEG Photo"
        panel.allowedContentTypes = [.jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadPhoto(from: url)
    }

    /// Loads a photo from a file URL.
    func loadPhoto(from url: URL) {
        do {
            let doc = try PhotoDocument(url: url)
            self.document = doc
            self.originalImage = doc.originalImage
            self.processedImage = doc.originalImage
            resetAdjustments()
            isMaskAvailable = false
            processingEngine.clearMaskCache()
            
            // Asynchronously generate subject mask using Vision
            Task {
                let mask = try? await processingEngine.generateSubjectMask(from: doc.ciImage)
                await MainActor.run {
                    self.isMaskAvailable = (mask != nil)
                }
            }

        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Applies AI-recommended adjustments from Gemini across all layers.
    func applyAIAdjustments(_ adjustments: ImageAdjustments) {
        globalSliders.update(from: adjustments.global)
        
        if let subject = adjustments.subject {
            subjectSliders.update(from: subject)
        }
        
        if let background = adjustments.background {
            backgroundSliders.update(from: background)
        }
        
        // Explicitly printing the mapping as requested
        print("AI returned subject exposure: \(adjustments.subject?.exposure ?? 0.0)")
        print("AI returned background exposure: \(adjustments.background?.exposure ?? 0.0)")
        
        print("Applying AI Layered Adjustments")
        processingEngine.clearLUTCache()
    }

    /// Sends the photo thumbnail to the Gemini API for AI analysis.
    func autoEnhance() {
        guard let document = document else {
            showError("Please open a photo first.")
            return
        }

        guard !isAnalyzing else { return }

        isAnalyzing = true
        errorMessage = nil

        Task {
            defer { isAnalyzing = false }

            do {
                let thumbnailData = try document.thumbnailJPEGData()

                let aiAdjustments = try await NetworkManager.analyzePhoto(
                    thumbnailData: thumbnailData
                )

                // Apply with nil-safety and smooth transition
                await MainActor.run {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        self.applyAIAdjustments(aiAdjustments)
                    }
                }

            } catch {
                await MainActor.run {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    /// Selects a specific color channel for editing.
    func selectProfile(_ channelName: String) {
        selectedColorChannel = channelName
    }

    /// Resets all adjustments to zero and clears color profiles.
    func resetAdjustments() {
        globalSliders = LayerState()
        subjectSliders = LayerState()
        backgroundSliders = LayerState()
        selectedLayer = .global
        processingEngine.clearLUTCache()
    }

    // MARK: - Dynamic Bindings for UI

    func binding(for keyPath: WritableKeyPath<LayerState, Float>) -> Binding<Float> {
        Binding(
            get: {
                switch self.selectedLayer {
                case .global: return self.globalSliders[keyPath: keyPath]
                case .subject: return self.subjectSliders[keyPath: keyPath]
                case .background: return self.backgroundSliders[keyPath: keyPath]
                }
            },
            set: { newValue in
                self.objectWillChange.send() // Ensure UI updates
                switch self.selectedLayer {
                case .global: self.globalSliders[keyPath: keyPath] = newValue
                case .subject: self.subjectSliders[keyPath: keyPath] = newValue
                case .background: self.backgroundSliders[keyPath: keyPath] = newValue
                }
            }
        )
    }

    func profileBinding(for channel: String, property: WritableKeyPath<UIProfile, Float>) -> Binding<Float> {
        Binding(
            get: {
                let profile = self.activeProfile(for: channel)
                return profile[keyPath: property]
            },
            set: { newValue in
                self.objectWillChange.send()
                switch self.selectedLayer {
                case .global: self.globalSliders.colorProfiles[channel]?[keyPath: property] = newValue
                case .subject: self.subjectSliders.colorProfiles[channel]?[keyPath: property] = newValue
                case .background: self.backgroundSliders.colorProfiles[channel]?[keyPath: property] = newValue
                }
            }
        )
    }

    func activeProfile(for channel: String) -> UIProfile {
        switch selectedLayer {
        case .global: return globalSliders.colorProfiles[channel] ?? UIProfile()
        case .subject: return subjectSliders.colorProfiles[channel] ?? UIProfile()
        case .background: return backgroundSliders.colorProfiles[channel] ?? UIProfile()
        }
    }

    /// Opens an `NSSavePanel` and exports the processed image as a JPEG.
    func exportPhoto() {
        guard let document = document else {
            showError("No photo to export.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Enhanced JPEG"
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "\(document.displayName)_enhanced.jpg"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessing = true

        Task {
            defer { isProcessing = false }

            do {
                let jpegData = try await processingEngine.exportJPEG(
                    source: document.ciImage,
                    adjustments: currentAdjustments,
                    quality: 0.95
                )
                try jpegData.write(to: url, options: .atomic)

            } catch {
                showError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Rendering

    private func renderProcessedImage() async {
        guard let document = document else { return }

        if !hasChanges {
            processedImage = document.originalImage
            
            // Generate base histogram if no changes
            if let (_, histogram) = try? await processingEngine.apply(
                adjustments: currentAdjustments,
                to: document.ciImage
            ) {
                self.histogramData = histogram
            } else {
                self.histogramData = .empty
            }
            return
        }

        isProcessing = true

        do {
            let (rendered, histogram) = try await processingEngine.apply(
                adjustments: currentAdjustments,
                to: document.ciImage
            )
            self.processedImage = rendered
            self.histogramData = histogram
        } catch {
            showError("Rendering failed: \(error.localizedDescription)")
        }

        isProcessing = false
    }

    // MARK: - Error Handling

    private func showError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }
}
