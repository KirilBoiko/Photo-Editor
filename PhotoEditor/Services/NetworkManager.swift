import Foundation

// MARK: - NetworkManager
/// Handles communication with the Google Gemini API for AI-powered photo analysis.
///
/// Architecture:
/// - Uses the Gemini REST API directly via `URLSession` (no Firebase/SDK dependency).
/// - Sends a base64-encoded low-res JPEG thumbnail for analysis.
/// - Uses Gemini's Structured Output (JSON Mode) with a strict `responseSchema`
///   to guarantee a valid `ImageAdjustments` response.
/// - API key is loaded from `APIKeys.plist` in the app bundle.

final class NetworkManager: Sendable {

    // MARK: - Types

    /// Errors that can occur during the Gemini API interaction.
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
                return "Gemini API key not found. Please add your key to APIKeys.plist."
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

    /// Gemini API endpoint (v1beta required for structured output / responseSchema).
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Model to use. Gemini 3.1 Pro for high-quality photo analysis.
    private static let modelName = "gemini-3.1-pro-preview"

    /// Maximum dimension (width or height) for the thumbnail sent to the API.
    /// 512px keeps the request small while providing enough detail for analysis.
    private static let thumbnailMaxDimension: CGFloat = 512

    // MARK: - API Key Loading

    /// Loads the Gemini API key from `APIKeys.plist` in the app bundle.
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

    /// Builds the JSON Schema for Gemini's structured output.
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
                "aiColorProfiles": [
                    "type": "OBJECT",
                    "description": "Per-channel HSL adjustments for 8 color channels.",
                    "properties": colorProfileProperties,
                    "required": ColorChannel.allNames
                ]
            ],
            "required": ["exposure", "contrast", "saturation", "warmth", "sharpness", "aiColorProfiles"]
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
    You are a Professional Layered Colorist.
    MANDATORY WORKFLOW:

    Analyze the Subject vs the Background.

    If there is a lighting difference (e.g., subject is darker than sky), you MUST use the 'subject' and 'background' blocks independently.

    Do not rely solely on 'global'. Use 'global' only for basic white balance.

    For the Golden Gate photo (or similar): Boost 'subject.exposure' (+0.2) and drop 'background.exposure' (-0.1) to create depth.

    If a subject is detected, provide distinct values for its HSL profile (e.g., warmer skin for subject, cooler blues for background).

    STRICT SCHEMA: { "global": {...}, "subject": {...}, "background": {...} }
    """

    // MARK: - Public API

    /// Analyzes a photo thumbnail and returns AI-recommended adjustments.
    ///
    /// This method:
    /// 1. Loads the API key from `APIKeys.plist` or environment
    /// 2. Encodes the thumbnail JPEG as base64
    /// 3. Sends it to Gemini with a structured output schema
    /// 4. Parses and returns the `ImageAdjustments`
    ///
    /// - Parameter thumbnailData: JPEG data of a low-resolution thumbnail (≤512px).
    ///   Generate this from `PhotoDocument.thumbnailJPEGData()`.
    /// - Returns: An `ImageAdjustments` with all values clamped to -1.0...1.0.
    /// - Throws: `NetworkError` if the API call fails at any stage.
    static func analyzePhoto(thumbnailData: Data) async throws -> ImageAdjustments {
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
            systemPrompt: systemInstruction
        )

        // 5. Serialize to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

        // 6. Create the HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        // 7. Execute the request
        let (data, response) = try await URLSession.shared.data(for: request)

        // 8. Validate the HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unexpectedResponseStructure("Response is not HTTP.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            throw NetworkError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorBody
            )
        }

        // 9. Parse the Gemini response structure
        let adjustments = try parseGeminiResponse(data: data)

        // 10. Clamp values to valid range and return
        return adjustments.clamped()
    }

    // MARK: - Request Building

    /// Constructs the full JSON request body for the Gemini generateContent API.
    ///
    /// The structure follows the Gemini REST API specification:
    /// - `system_instruction`: System-level prompt for consistent behavior
    /// - `contents`: User message with text prompt + inline image data
    /// - `generationConfig`: Enforces JSON output with our schema
    private static func buildRequestBody(
        base64Image: String,
        systemPrompt: String
    ) -> [String: Any] {
        return [
            // System instruction — sets the model's persona
            "system_instruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],

            // User content — the image to analyze + a brief user prompt
            "contents": [
                [
                    "parts": [
                        [
                            "text": "Analyze this photograph and provide the optimal adjustment values to enhance it."
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
            // causing Gemini to return markdown-wrapped JSON instead of raw JSON.
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": adjustmentsResponseSchema(),
                "temperature": 0.2,  // Low temperature for consistent, predictable results
                "max_output_tokens": 2048  // Larger response for layered output
            ]
        ]
    }

    // MARK: - Response Parsing

    /// Parses the Gemini API response and extracts `ImageAdjustments`.
    ///
    /// Gemini's response structure:
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
        // Parse the top-level Gemini response
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

        // Fix invalid decimals from AI (e.g. "exposure": 0. instead of 0.0)
        // Replaces any dot that is followed by a comma, space, closing brace, bracket, or string end with ".0"
        sanitized = sanitized.replacingOccurrences(
            of: "\\.(?=[,\\s}\\]]|$)",
            with: ".0",
            options: .regularExpression
        )

        // Robust JSON Repair step: if the model hit the token limit and cut off
        var openBraces = sanitized.filter { $0 == "{" }.count
        var closeBraces = sanitized.filter { $0 == "}" }.count
        
        if openBraces > closeBraces {
            print("WARNING: Gemini response appears truncated. Applying robust JSON repair...")
            
            // Clean up any trailing comma, incomplete key/value pairs before closing
            // Remove trailing commas
            while sanitized.hasSuffix(",") || sanitized.hasSuffix(" ") || sanitized.hasSuffix("\n") {
                sanitized.removeLast()
            }
            
            // If we cut off mid-key or mid-value (e.g. ending in a quote or colon), 
            // the safest bet is to strip back to the last valid separator
            if sanitized.hasSuffix("\"") || sanitized.hasSuffix(":") {
                if let lastComma = sanitized.lastIndex(of: ",") {
                    sanitized = String(sanitized[..<lastComma])
                }
            }
            
            // Append missing closing braces
            while openBraces > closeBraces {
                sanitized += "}"
                closeBraces += 1
            }
        }

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
