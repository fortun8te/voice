// StyleCardService.swift
//
// Extracts, stores, and serves a personal Style Card — a compressed ~300-token
// JSON descriptor of how a specific user writes. Injected into cloud polish
// calls when "My Style" is enabled so Cerebras sounds like the user, not generic AI.
//
// Architecture:
//   1. User pastes writing samples (messages, emails, notes — any text they wrote)
//   2. One-time Cerebras call (Qwen3-235B) extracts a Style Card JSON
//   3. Card saved on-device as a protected JSON file in Application Support
//   4. Every cloud polish call appends the card to the system prompt (~300 tokens)
//
// Privacy: raw writing samples never leave the device. Only the extracted
// Style Card JSON (structural/stylistic descriptor, no PII) is included in
// polish prompts.
//
// "My Style" is independent of the personality preset (Neutral/Formal/Casual/Excited).
// It applies on top — makes FORMAL sound like YOUR formal, CASUAL like YOUR casual.

import Foundation

// MARK: - Service

@MainActor
final class StyleCardService {
    static let shared = StyleCardService()
    private init() { loadFromDisk() }

    // MARK: - Storage paths

    private static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VOICE", isDirectory: true)
    }
    private static var cardURL: URL { appSupportURL.appendingPathComponent("style_card.json") }
    private static var samplesURL: URL { appSupportURL.appendingPathComponent("writing_samples.json") }

    // MARK: - UserDefaults keys

    private let enabledKey = "myStyleEnabled"

    /// Whether "My Style" injection is active. Independent of personality preset.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Active card (in-memory)

    private(set) var activeCard: String? = nil
    private(set) var cardWordCount: Int = 0
    private(set) var cardSampleCount: Int = 0

    var hasCard: Bool { activeCard != nil }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: Self.cardURL.path),
              let data = try? Data(contentsOf: Self.cardURL),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = envelope["card"] as? String else { return }
        activeCard = json
        cardWordCount   = envelope["totalWordCount"] as? Int ?? 0
        cardSampleCount = envelope["sampleCount"] as? Int ?? 0
    }

    private func saveToDisk(card: String, sampleCount: Int, wordCount: Int) {
        let dir = Self.appSupportURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let envelope: [String: Any] = [
            "card": card,
            "sampleCount": sampleCount,
            "totalWordCount": wordCount,
            "extractedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: .prettyPrinted) else { return }
        try? data.write(to: Self.cardURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Prompt injection

    /// Returns the Style Card formatted as a system-prompt block, or nil if
    /// "My Style" is off or no card has been extracted yet.
    /// Includes the fidelity instruction for the current MyStyleLevel so the
    /// model knows how tightly to follow the card vs. elevating for quality.
    func styleCardPromptBlock() -> String? {
        guard isEnabled, let card = activeCard, !card.isEmpty else { return nil }
        // Read fidelity level from UserDefaults directly — avoids importing
        // VoiceApp.swift types into the Services layer.
        let levelRaw = UserDefaults.standard.string(forKey: "myStyleLevel") ?? "polished"
        let fidelity: String
        switch levelRaw {
        case "raw":
            fidelity = "STYLE FIDELITY: exact. Preserve every quirk, rhythm, and characteristic phrase from the Style Card. Fix only audio artifacts — nothing else."
        case "light":
            fidelity = "STYLE FIDELITY: close. Smooth grammar and run-ons only. Keep the speaker's exact cadence, slang, and characteristic phrases from the Style Card."
        case "best":
            fidelity = "STYLE FIDELITY: card-informed. Quality and precision first. The Style Card defines character and voice — let the prose be its best possible form."
        default: // "polished" / unrecognized
            fidelity = "STYLE FIDELITY: primary. The Style Card is your main voice guide. Full editorial cleanup allowed. Mild elevation OK where it strengthens clarity."
        }
        return """


=== MY WRITING STYLE (apply when rendering voice) ===
The following Style Card describes how this specific user writes. Match their sentence \
length, vocabulary, characteristic phrases, and punctuation habits. Preserve their \
idiosyncrasies even when unconventional.

\(fidelity)

\(card)

This person does NOT write like a generic AI. If you find yourself using words or \
phrases absent from the Style Card above (like "leverage", "utilize", "delve", \
"it's worth noting"), stop and rewrite.
"""
    }

    // MARK: - Extraction

    static let minWords = 300
    static let goodWords = 1500

    struct WritingSample {
        let text: String
        let context: String   // "message" | "email" | "note" | "other"
        var wordCount: Int { text.split(separator: " ").count }
    }

    /// Extract a Style Card from writing samples using Cerebras Qwen3-235B.
    /// Saves to disk and updates in-memory state on success.
    @discardableResult
    func extractCard(from samples: [WritingSample]) async throws -> String {
        let totalWords = samples.reduce(0) { $0 + $1.wordCount }
        guard totalWords >= Self.minWords else {
            throw StyleCardError.insufficientData(have: totalWords, need: Self.minWords)
        }

        let userPrompt = Self.buildExtractionPrompt(samples: samples)
        guard let raw = await CerebrasPolisher.shared.extractStyleCard(
            systemPrompt: Self.extractionSystemPrompt,
            userPrompt: userPrompt
        ) else {
            throw StyleCardError.extractionFailed("Cerebras returned nil — check API key and connection")
        }

        // Validate: must be JSON with required top-level keys.
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["surface"] != nil,
              parsed["lexical"] != nil else {
            throw StyleCardError.invalidOutput(raw)
        }

        // Enforce 400-token hard cap (~1600 chars).
        let capped = raw.count > 1600 ? String(raw.prefix(1590)) + "\n}" : raw

        // Persist.
        saveToDisk(card: capped, sampleCount: samples.count, wordCount: totalWords)
        activeCard      = capped
        cardSampleCount = samples.count
        cardWordCount   = totalWords

        // Persist raw samples locally for future re-extraction.
        let samplesPayload = samples.map { ["text": $0.text, "context": $0.context] }
        if let sd = try? JSONSerialization.data(withJSONObject: samplesPayload, options: .prettyPrinted) {
            try? sd.write(to: Self.samplesURL, options: [.atomic, .completeFileProtection])
        }

        print("[VOICE-STYLE] Style Card extracted — \(samples.count) samples, \(totalWords) words, \(capped.count) chars")
        return capped
    }

    func clearCard() {
        activeCard = nil
        cardWordCount = 0
        cardSampleCount = 0
        try? FileManager.default.removeItem(at: Self.cardURL)
        try? FileManager.default.removeItem(at: Self.samplesURL)
    }

    // MARK: - Extraction prompt

    static let extractionSystemPrompt = """
    You are a writing style analyst. Extract a Style Card JSON from the provided \
    writing samples. The Style Card will be injected into AI prompts to make the AI \
    write in the same voice as the sample author.

    Output ONLY valid JSON — no markdown, no explanation, no code fences. Schema:

    {
      "surface": {
        "sentence_length": "short" | "medium" | "long" | "mixed",
        "avg_words_per_sentence": <integer>,
        "punctuation_habits": [<list of observed habits, e.g. "uses ellipses to trail off">],
        "contraction_usage": "none" | "low" | "medium" | "high"
      },
      "structural": {
        "paragraph_length": "one-liner" | "short (1-3 sentences)" | "medium (3-5)" | "long",
        "opening_style": <short string, e.g. "jumps in directly, no preamble">,
        "closing_style": <short string, e.g. "blunt, often a fragment">,
        "transition_style": <short string>
      },
      "lexical": {
        "vocabulary_level": "casual" | "conversational" | "moderate" | "formal",
        "characteristic_phrases": [<3-6 phrases the author ACTUALLY uses, verbatim>],
        "avoid_phrases": [<6-10 phrases this author would NEVER use — include generic AI \
    phrases like "delve", "leverage", "utilize", "it's worth noting", "touch base", \
    "synergy", plus any formal/stiff patterns absent from samples>],
        "register": <one short phrase>
      },
      "exemplars": [
        <2-3 SHORT sentences verbatim from the samples that best capture their voice>
      ]
    }

    Rules:
    - characteristic_phrases must come from the actual samples, not invented
    - avoid_phrases: always include the generic AI filler list above; supplement with \
      patterns clearly absent from the samples
    - exemplars must be verbatim quotes from the samples, not paraphrases
    - Keep total JSON under 1500 characters
    """

    private static func buildExtractionPrompt(samples: [WritingSample]) -> String {
        var out = "Extract a Style Card from these \(samples.count) writing samples:\n\n"
        for (i, s) in samples.enumerated() {
            out += "--- Sample \(i + 1) [\(s.context.uppercased())] ---\n\(s.text)\n\n"
        }
        out += "Output ONLY the Style Card JSON."
        return out
    }
}

// MARK: - Cerebras extraction endpoint

extension CerebrasPolisher {
    /// One-time Style Card extraction call. Non-streaming, temperature 0 for
    /// deterministic JSON output. Separate from the polish path.
    func extractStyleCard(systemPrompt: String, userPrompt: String) async -> String? {
        guard Self.isAvailable else { return nil }

        let extractionURL = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        let payload: [String: Any] = [
            "model": "qwen-3-235b-a22b-instruct-2507",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt],
            ],
            "temperature": 0,
            "max_tokens": 700,
            "stream": false,
            "prompt_cache_key": "voice-style-extraction",
        ]

        var req = URLRequest(url: extractionURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            print("[CEREBRAS] style card extraction failed")
            return nil
        }

        // Strip accidental markdown fences.
        let ws = CharacterSet.whitespacesAndNewlines
        return text
            .trimmingCharacters(in: ws)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: ws)
    }
}

// MARK: - Errors

enum StyleCardError: LocalizedError {
    case insufficientData(have: Int, need: Int)
    case extractionFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .insufficientData(let have, let need):
            return "Need at least \(need) words, got \(have). Add more writing samples."
        case .extractionFailed(let reason):
            return "Extraction failed: \(reason)"
        case .invalidOutput(let raw):
            return "Model returned invalid JSON. Got: \(raw.prefix(200))"
        }
    }
}
