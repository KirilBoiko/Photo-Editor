import Foundation

// MARK: - NetworkManager
/// Handles communication with the image analysis API.
///
/// Architecture:
/// - Uses the REST API directly via `URLSession`.
/// - Sends a base64-encoded low-res JPEG thumbnail for analysis.
/// - Uses structured output (JSON Mode) with a strict `responseSchema`
///   to guarantee a valid `ImageAdjustments` response.
/// - API key is loaded from `APIKeys.plist` in the app bundle.

final class NetworkManager: Sendable {

    // MARK: - Types

    /// Errors that can occur during the API interaction.
    enum NetworkError: LocalizedError {
        case missingAPIKey
        case invalidThumbnailData
        case invalidURL
        case httpError(statusCode: Int, message: String)
        case emptyResponse
        case decodingError(String)
        case unexpectedResponseStructure(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API key not found. Please add your key to APIKeys.plist."
            case .invalidThumbnailData:
                return "Failed to generate JPEG thumbnail data for the image."
            case .invalidURL:
                return "Internal error: could not construct the API URL."
            case .httpError(let code, let message):
                return "API request failed (HTTP \(code)): \(message)"
            case .emptyResponse:
                return "The API returned an empty response."
            case .decodingError(let detail):
                return "Failed to decode the API response: \(detail)"
            case .unexpectedResponseStructure(let detail):
                return "Unexpected API response structure: \(detail)"
            }
        }
    }

    // MARK: - Constants

    /// API endpoint.
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Model to use for photo analysis.
    private static let modelName = "gemini-3.1-pro-preview"

    /// Maximum dimension (width or height) for the thumbnail sent to the API.
    /// 768px provides enough detail for color grading while keeping payload small.
    private static let thumbnailMaxDimension: CGFloat = 768

    /// Maximum retry attempts for timeout errors.
    private static let maxRetries = 1

    /// Dedicated URLSession with extended timeouts for complex analysis.
    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // MARK: - API Key Loading

    /// Loads the API key from `APIKeys.plist` in the app bundle.
    ///
    /// The plist should contain a top-level dictionary with a `GEMINI_API_KEY` string entry.
    /// This file should be listed in `.gitignore` to avoid committing secrets.
    private static func loadAPIKey() throws -> String {
        // First check environment variable (useful for CI/testing)
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }

        // Fall back to APIKeys.plist in the app bundle
        guard let plistURL = Bundle.module.url(forResource: "APIKeys", withExtension: "plist"),
              let plistData = try? Data(contentsOf: plistURL),
              let plistDict = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil
              ) as? [String: Any],
              let apiKey = plistDict["GEMINI_API_KEY"] as? String,
              apiKey != "YOUR_API_KEY_HERE",
              !apiKey.isEmpty else {
            throw NetworkError.missingAPIKey
        }

        return apiKey
    }

    // MARK: - Structured Output Schema

    /// Builds the JSON Schema for the structured output.
    ///
    /// The schema defines two sections:
    /// 1. Five global adjustment floats (exposure, contrast, saturation, warmth, sharpness)
    /// 2. An `ai_color_profiles` object with HSL shifts for 8 color channels
    private static func adjustmentsResponseSchema() -> [String: Any] {
        func colorProfileSchema() -> [String: Any] {
            return [
                "type": "OBJECT",
                "properties": [
                    "hue": [
                        "type": "NUMBER",
                        "description": "Hue rotation for this color channel as a number between -1.0 and 1.0. Use 0 for no change."
                    ],
                    "saturation": [
                        "type": "NUMBER",
                        "description": "Saturation adjustment for this color channel as a number between -1.0 and 1.0. Use 0 for no change."
                    ],
                    "luminance": [
                        "type": "NUMBER",
                        "description": "Luminance adjustment for this color channel as a number between -1.0 and 1.0. Use 0 for no change."
                    ]
                ],
                "required": ["hue", "saturation", "luminance"]
            ]
        }

        var colorProfileProperties: [String: Any] = [:]
        for name in ColorChannel.allNames {
            colorProfileProperties[name] = colorProfileSchema()
        }

        let layerSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "exposure": [
                    "type": "NUMBER",
                    "description": "Exposure adjustment as a number between -1.0 and 1.0."
                ],
                "contrast": [
                    "type": "NUMBER",
                    "description": "Contrast adjustment as a number between -1.0 and 1.0."
                ],
                "saturation": [
                    "type": "NUMBER",
                    "description": "Saturation adjustment as a number between -1.0 and 1.0."
                ],
                "warmth": [
                    "type": "NUMBER",
                    "description": "Color temperature adjustment as a number between -1.0 and 1.0."
                ],
                "sharpness": [
                    "type": "NUMBER",
                    "description": "Sharpness adjustment as a number between 0.0 and 1.0."
                ],
                "shadows": [
                    "type": "NUMBER",
                    "description": "Shadows adjustment as a number between -1.0 and 1.0."
                ],
                "highlights": [
                    "type": "NUMBER",
                    "description": "Highlights adjustment as a number between -1.0 and 1.0."
                ],
                "blur": [
                    "type": "NUMBER",
                    "description": "Gaussian blur adjustment as a number between 0.0 and 1.0."
                ],
                "aiColorProfiles": [
                    "type": "OBJECT",
                    "description": "Per-channel HSL adjustments for 8 color channels.",
                    "properties": colorProfileProperties,
                    "required": ColorChannel.allNames
                ]
            ],
            "required": ["exposure", "contrast", "saturation", "warmth", "sharpness", "shadows", "highlights", "blur", "aiColorProfiles"]
        ]

        return [
            "type": "OBJECT",
            "properties": [
                "global": layerSchema,
                "subject": layerSchema,
                "background": layerSchema
            ],
            "required": ["global"]
        ]
    }

    private static let systemInstruction: String = """
    You are a Technical Master Colorist with zero-tolerance for highlight destruction.

    ⛔ THE HIGHLIGHT RED LINE (HIGHEST PRIORITY):
    • If highlightClipping > 1% OR any top-row zone in the Light Map > 0.85:
      - FORBIDDEN: Do NOT increase background.exposure or global.exposure
      - MANDATORY: Drop background.highlights (-0.15 to -0.40)
      - Consider dropping background.exposure (-0.05 to -0.15)
    • Recovery over brightness: a slightly dark subject is better than a destroyed background
    • Near-white zones (0.9+) contain precious recoverable data — pull back, never push

    DYNAMIC RANGE STRESS (brightest zone − darkest zone > 0.6):
    • Lift subject with subject.shadows (+0.2), keep background exposure neutral or negative
    • Protect fog/sky/mist detail — if near white, treat as irreplaceable

    COLOR SCIENCE:
    • Overcast/foggy: use background.warmth (-0.05) to lean into natural cool tones
    • Do not let mist/fog go pure white — preserve atmospheric depth

    SPATIAL DIAGNOSIS (3x3 Light Map):
    • BACKLIT: top row >0.8 & center <0.3 → subject.shadows +0.2, background.highlights -0.15
    • FLAT: Dynamic Range <0.15 → global.contrast +0.02, HSL Luminance for pop
    • UNBALANCED: L/R differ >0.2 → split-the-difference with global.exposure
    • Subject Area <0.35 → lift subject.exposure; >0.65 → protect highlights

    HISTOGRAM RULES:
    • Shadow Clipping >5% → recover with subject/global shadows
    • Highlight Clipping >5% → pull back with background/global highlights
    • Mean Brightness <0.3 → lift Exposure; >0.7 → reduce it
    • R/G/B deviation >10% from 0.33 → Warmth correction
    • Contrast Score <0.01 → minimal values (low dynamic range)

    SUBJECT: subject.shadows (+0.05 to +0.15), subject.exposure for focal emphasis.
    Skin: Orange/Red Saturation ±0.03. Orange Luminance for glow.

    BACKGROUND: background.highlights (-0.1) for sky recovery.
    Subject brightened → darken/cool background (warmth -0.05). Busy → blur (0.0–0.5).

    GLOBAL: White balance and tiny contrast tweaks only.

    HARD CAPS: Contrast ±0.03 | Exposure ±0.12 | Sharpness 0.05

    JSON: Return valid {global, subject?, background?}. Omit unused layers. Never truncate.
    """

    // MARK: - Public API

    /// Analyzes a photo thumbnail and returns AI-recommended adjustments.
    ///
    /// This method:
    /// 1. Loads the API key from `APIKeys.plist` or environment
    /// 2. Encodes the thumbnail JPEG as base64
    /// 3. Sends it to the API with a structured output schema
    /// 4. Parses and returns the `ImageAdjustments`
    ///
    /// - Parameters:
    ///   - thumbnailData: JPEG data of a low-resolution thumbnail (≤512px).
    ///     Generate this from `PhotoDocument.thumbnailJPEGData()`.
    ///   - statistics: Optional histogram-derived technical data. When provided,
    ///     injected into the user prompt as a "Technical Truth" block.
    /// - Returns: An `ImageAdjustments` with all values clamped to -1.0...1.0.
    /// - Throws: `NetworkError` if the API call fails at any stage.
    static func analyzePhoto(thumbnailData: Data, statistics: ImageStatistics? = nil) async throws -> ImageAdjustments {
        // 1. Load the API key
        let apiKey = try loadAPIKey()

        // 2. Encode the thumbnail as base64
        let base64Image = thumbnailData.base64EncodedString()
        guard !base64Image.isEmpty else {
            throw NetworkError.invalidThumbnailData
        }

        // 3. Build the request URL
        guard let url = URL(
            string: "\(baseURL)/\(modelName):generateContent?key=\(apiKey)"
        ) else {
            throw NetworkError.invalidURL
        }

        // 4. Build the request body with structured output schema
        let requestBody = buildRequestBody(
            base64Image: base64Image,
            systemPrompt: systemInstruction,
            statistics: statistics
        )

        // 5. Serialize to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

        // 6. Create the HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        // 7. Execute with retry on timeout
        return try await executeWithRetry(request: request)
    }

    static func analyzeBatch(activeData: Data, contextThumbnails: [String]) async throws -> [ImageAdjustments] {
        let apiKey = try loadAPIKey()
        let base64Image = activeData.base64EncodedString()
        guard !base64Image.isEmpty else { throw NetworkError.invalidThumbnailData }
        
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent?key=\(apiKey)") else {
            throw NetworkError.invalidURL
        }

        var parts: [[String: Any]] = []
        parts.append(["text": "Analyze the active image and the context of the session (thumbnails). Provide a consistent professional grade for the entire batch. Return a JSON array of ImageAdjustments. Active Image:"])
        parts.append(["inline_data": ["mime_type": "image/jpeg", "data": base64Image]])
        
        for (i, thumb) in contextThumbnails.enumerated() {
            parts.append(["text": "Context Image \(i+1):"])
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": thumb]])
        }

        let requestBody: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [["parts": parts]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": [
                    "type": "ARRAY",
                    "items": adjustmentsResponseSchema()
                ],
                "temperature": 0.2,
                "max_output_tokens": 8192
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let (data, response) = try await apiSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.decodingError("Invalid HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8)
            if let text = errorText {
                print("API ERROR: \(text)")
            }
            throw NetworkError.httpError(statusCode: httpResponse.statusCode, message: errorText ?? "Unknown API Error")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw NetworkError.decodingError("No text in response.")
        }
        
        var sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("```json") { sanitized = String(sanitized.dropFirst(7)) }
        else if sanitized.hasPrefix("```") { sanitized = String(sanitized.dropFirst(3)) }
        if sanitized.hasSuffix("```") { sanitized = String(sanitized.dropLast(3)) }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "\\.(?=[,\\s}\\]]|$)", with: ".0", options: .regularExpression)

        guard let adjustmentsData = sanitized.data(using: .utf8) else {
            throw NetworkError.decodingError("Response text is not valid UTF-8.")
        }

        guard let jsonObj = try JSONSerialization.jsonObject(with: adjustmentsData) as? [[String: Any]] else {
            throw NetworkError.decodingError("Root JSON is not an array.")
        }

        var results: [ImageAdjustments] = []
        let decoder = JSONDecoder()
        for dict in jsonObj {
            let dictData = try JSONSerialization.data(withJSONObject: dict)
            results.append(try decoder.decode(ImageAdjustments.self, from: dictData).clamped())
        }
        return results
    }

    // MARK: - Retry Logic

    /// Executes a request with automatic retry on timeout.
    /// Uses the dedicated `apiSession` with extended timeouts.
    private static func executeWithRetry(request: URLRequest, attempt: Int = 0) async throws -> ImageAdjustments {
        do {
            let (data, _) = try await apiSession.data(for: request)
            return try parseGeminiResponse(data: data)
        } catch let error as URLError where error.code == .timedOut && attempt < maxRetries {
            print("⏱ Request timed out (attempt \(attempt + 1)/\(maxRetries + 1)). Retrying...")
            return try await executeWithRetry(request: request, attempt: attempt + 1)
        }
    }

    // MARK: - Request Building

    /// Constructs the full JSON request body for the generateContent API.
    ///
    /// The structure follows the REST API specification:
    /// - `system_instruction`: System-level prompt for consistent behavior
    /// - `contents`: User message with text prompt + inline image data
    /// - `generationConfig`: Enforces JSON output with our schema
    private static func buildRequestBody(
        base64Image: String,
        systemPrompt: String,
        statistics: ImageStatistics? = nil
    ) -> [String: Any] {
        // Build the user prompt text, optionally enriched with histogram data
        var userPrompt = "Analyze this photograph and provide the optimal adjustment values to enhance it."
        if let stats = statistics {
            userPrompt += "\n\n" + stats.aiPromptBlock
        }

        return [
            // System instruction — sets the model's persona
            "system_instruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],

            // User content — the image to analyze + technical data + a brief user prompt
            "contents": [
                [
                    "parts": [
                        [
                            "text": userPrompt
                        ],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],

            // Generation config — enforces structured JSON output
            // NOTE: The REST API uses snake_case keys, NOT camelCase.
            // Using camelCase (e.g. "responseMimeType") is silently ignored,
            // causing the API to return markdown-wrapped JSON instead of raw JSON.
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": adjustmentsResponseSchema(),
                "temperature": 0.2,  // Low temperature for consistent, predictable results
                "max_output_tokens": 8192  // Larger response for layered output
            ]
        ]
    }

    // MARK: - Response Parsing

    /// Parses the API response and extracts `ImageAdjustments`.
    ///
    /// The response structure:
    /// ```json
    /// {
    ///   "candidates": [{
    ///     "content": {
    ///       "parts": [{
    ///         "text": "{\"exposure\": 0.2, \"contrast\": 0.1, ...}"
    ///       }]
    ///     }
    ///   }]
    /// }
    /// ```
    ///
    /// The `text` field contains the JSON string matching our schema, which
    /// we decode into `ImageAdjustments`.
    private static func parseGeminiResponse(data: Data) throws -> ImageAdjustments {
        // Parse the top-level response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.unexpectedResponseStructure("Response is not a JSON object.")
        }

        // Navigate: candidates[0].content.parts[0].text
        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            // Check if there's a prompt feedback / block reason
            if let promptFeedback = json["promptFeedback"] as? [String: Any],
               let blockReason = promptFeedback["blockReason"] as? String {
                throw NetworkError.httpError(
                    statusCode: 400,
                    message: "Request blocked by safety filters: \(blockReason)"
                )
            }
            throw NetworkError.unexpectedResponseStructure(
                "Could not extract text from candidates[0].content.parts[0].text"
            )
        }

        // Sanitize the response text:
        // Even with response_mime_type set, some models occasionally wrap JSON in
        // markdown code fences (```json ... ```). Strip them to be safe.
        var sanitized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove leading ```json or ``` fence
        if sanitized.hasPrefix("```json") {
            sanitized = String(sanitized.dropFirst(7))
        } else if sanitized.hasPrefix("```") {
            sanitized = String(sanitized.dropFirst(3))
        }
        
        // Remove trailing ``` fence
        if sanitized.hasSuffix("```") {
            sanitized = String(sanitized.dropLast(3))
        }
        
        // Final trim after stripping fences
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fix invalid decimals (e.g. "exposure": 0. instead of 0.0)
        // Replaces any dot that is followed by a comma, space, closing brace, bracket, or string end with ".0"
        sanitized = sanitized.replacingOccurrences(
            of: "\\.(?=[,\\s}\\]]|$)",
            with: ".0",
            options: .regularExpression
        )

        // Robust JSON Repair removed as requested

        // Debug logging
        print("RAW JSON: \(text)")
        print("SANITIZED JSON: \(sanitized)")

        guard let adjustmentsData = sanitized.data(using: .utf8) else {
            throw NetworkError.decodingError("Response text is not valid UTF-8.")
        }

        let parsed: [String: Any]
        do {
            guard let jsonObj = try JSONSerialization.jsonObject(with: adjustmentsData) as? [String: Any] else {
                throw NetworkError.decodingError("Root JSON is not a dictionary.")
            }
            parsed = jsonObj
        } catch {
            print("JSON SERIALIZATION ERROR: \(error.localizedDescription)")
            throw NetworkError.decodingError("Response text is not a valid JSON object: \(sanitized) | Error: \(error.localizedDescription)")
        }

        print("PARSED KEYS: \(parsed.keys.sorted())")

        // Helper: coerce any JSON number (Int, Double, NSNumber) to Double
        func toDouble(_ value: Any?) -> Double? {
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }

        func parseLayer(from layerDict: [String: Any]?) -> LayerAdjustments? {
            guard let layerDict = layerDict else { return nil }

            let exposure = toDouble(layerDict["exposure"])
            let contrast = toDouble(layerDict["contrast"])
            let saturation = toDouble(layerDict["saturation"])
            let warmth = toDouble(layerDict["warmth"])
            let sharpness = toDouble(layerDict["sharpness"])

            var colorProfiles: [String: ColorProfile]? = nil

            let profilesDict = (layerDict["aiColorProfiles"] as? [String: Any])
                ?? (layerDict["ai_color_profiles"] as? [String: Any])

            if let profilesDict = profilesDict {
                colorProfiles = [:]
                for channelName in ColorChannel.allNames {
                    let matchedKey = profilesDict.keys.first { $0.caseInsensitiveCompare(channelName) == .orderedSame }
                    if let key = matchedKey, let channelDict = profilesDict[key] as? [String: Any] {
                        colorProfiles?[channelName] = ColorProfile(
                            hue: toDouble(channelDict["hue"]),
                            saturation: toDouble(channelDict["saturation"]),
                            luminance: toDouble(channelDict["luminance"])
                        )
                    } else {
                        colorProfiles?[channelName] = .identity
                    }
                }
            }

            return LayerAdjustments(
                exposure: exposure,
                contrast: contrast,
                saturation: saturation,
                warmth: warmth,
                sharpness: sharpness,
                aiColorProfiles: colorProfiles
            )
        }

        guard let globalLayerDict = parsed["global"] as? [String: Any],
              let global = parseLayer(from: globalLayerDict) else {
            throw NetworkError.decodingError("Missing or invalid 'global' layer in response.")
        }

        let subject = parseLayer(from: parsed["subject"] as? [String: Any])
        let background = parseLayer(from: parsed["background"] as? [String: Any])

        let adjustments = ImageAdjustments(
            global: global,
            subject: subject,
            background: background
        )

        print("DECODED OK: Layers -> global: YES, subject: \(subject != nil), background: \(background != nil)")

        return adjustments
    }
}
