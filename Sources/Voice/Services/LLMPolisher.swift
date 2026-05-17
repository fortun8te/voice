// VOICE — LLM Polisher
// ============================================================
// Optional last-pass cleanup using Apple's on-device Foundation Models.
// Runs AFTER rule-based formatting. Fails open: returns original text on
// timeout, error, or unavailable.
//
// Prompt is deliberately restrictive: fix typos, casing, obvious disfluencies,
// but NEVER rephrase or add words. The rule-based formatter has already done
// the heavy lifting — this is surface polish only.
//
// Latency budget: 400ms hard timeout. We'd rather paste raw than make the
// user wait.
//
// User toggle: UserDefaults key `llmPolishEnabled` (Bool).
// Defaults to ON when Foundation Models is available (macOS 26+), OFF otherwise.
// Surface in Settings UI.
// ============================================================

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class LLMPolisher {
    static let shared = LLMPolisher()

    // Session is cached as a Task so concurrent callers (prewarm + first
    // polish) all await the same in-flight construction instead of racing
    // to each build their own session. The `Any?` storage lets us keep a
    // single property across availability gates.
    private var sessionTask: Any?  // Task<LanguageModelSession, Never> on macOS 26+

    // Latency tracking — exposed to UI for the FM status card.
    // Updated on every call that reaches the model (skips don't count).
    private(set) var lastLatencyMs: Int = 0
    private(set) var avgLatencyMs: Double = 0
    private(set) var sampleCount: Int = 0

    private func recordLatency(_ ms: Int) {
        lastLatencyMs = ms
        // Running average — keeps memory flat regardless of session length.
        sampleCount += 1
        avgLatencyMs = avgLatencyMs + (Double(ms) - avgLatencyMs) / Double(sampleCount)
    }

    /// Insertion context hint — lets the model bias its cleanup for the
    /// destination surface (casual chat vs. code vs. email).
    enum PolishContext: String {
        case `default` = "general prose"
        case messaging = "casual chat message"
        case code = "code comment or shell command"
        case email = "email or formal writing"
    }

    static var isEnabled: Bool {
        // Default to ON when Foundation Models is available — but only if the user
        // hasn't explicitly set a preference. Once they touch the toggle, respect it.
        if UserDefaults.standard.object(forKey: "llmPolishEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "llmPolishEnabled")
        }
        return isAvailable
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Human-readable status for UI surfacing in the dock menu / BigMenu.
    /// Distinguishes the common states the user actually cares about.
    enum AvailabilityStatus {
        case available
        case downloading      // model assets still being fetched
        case appleIntelligenceOff
        case deviceNotEligible
        case unsupportedOS
        case unknown(String)

        var displayLabel: String {
            switch self {
            case .available:               return "Ready"
            case .downloading:             return "Downloading model…"
            case .appleIntelligenceOff:    return "Turn on Apple Intelligence in Settings"
            case .deviceNotEligible:       return "Not supported on this Mac"
            case .unsupportedOS:           return "Requires macOS 26+"
            case .unknown(let reason):     return reason
            }
        }

        var isReady: Bool { if case .available = self { return true } else { return false } }
    }

    static var availabilityStatus: AvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                let str = String(describing: reason).lowercased()
                if str.contains("modelnotready") || str.contains("notready") || str.contains("downloading") {
                    return .downloading
                }
                if str.contains("appleintelligencenotenabled") || str.contains("notenabled") {
                    return .appleIntelligenceOff
                }
                if str.contains("deviceneligible") || str.contains("noteligible") {
                    return .deviceNotEligible
                }
                return .unknown(String(describing: reason))
            @unknown default:
                return .unknown("unknown")
            }
        }
        #endif
        return .unsupportedOS
    }

    /// Force the model to page in. Eats the cold-start cost BEFORE the user's
    /// first dictation so the first real polish doesn't pay it.
    /// Uses a realistic polish-shaped prompt — sending just "ok" doesn't
    /// warm the same inference path we use in production.
    func prewarm() {
        guard Self.isAvailable else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = await self.ensureSession()
                let warmupPrompt = "Context: general prose\nInput: hello world\nOutput:"
                let start = Date()
                _ = try? await session.respond(to: warmupPrompt)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("[VOICE] LLM polisher pre-warmed in \(ms)ms")
            }
            #endif
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func ensureSession() async -> LanguageModelSession {
        if let task = self.sessionTask as? Task<LanguageModelSession, Never> {
            return await task.value
        }
        let task = Task<LanguageModelSession, Never> { @MainActor in
            Self.makeSession()
        }
        self.sessionTask = task
        return await task.value
    }
    #endif

    /// Polish formatted text with a strict timeout. Returns the original
    /// string on any failure path (timeout, model unavailable, error).
    ///
    /// Pipeline:
    ///   1. Rule-based filler removal (~1ms, always runs)
    ///   2. Skip-if-clean detector (~1ms — skip model entirely if text passes checks)
    ///   3. Foundation Model polish (only if needed)
    ///
    /// Default timeout 2500ms matches observed Apple Foundation Model latency on
    /// current hardware. 400ms (original) was aspirational — every call timed out
    /// and polish was effectively a no-op. The skip-if-clean detector eliminates
    /// ~40% of calls entirely, so the average user-perceived latency is still low.
    func polish(_ text: String, context: PolishContext = .default, timeoutMs: Int = 2500) async -> String {
        guard Self.isEnabled, Self.isAvailable else { return text }
        guard text.count >= 4 else { return text }
        // Code: skip polish entirely — model rewrites break syntax/identifiers
        if context == .code { return text }

        // Step 1: Strip fillers (rule-based, ~1ms) — runs ALWAYS, even if we skip model
        let stripped = Self.stripFillers(text)

        // Step 2: Skip model if text looks clean enough (rule-based, ~1ms)
        if Self.isCleanEnough(stripped) {
            print("[VOICE] LLM polish skipped — text looks clean")
            return stripped
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await polishWithFoundationModels(stripped, context: context, timeoutMs: timeoutMs)
        }
        #endif
        return stripped
    }

    /// Rule-based filler removal. Runs before the model to shorten input
    /// (cheaper LLM call) and to handle filler stripping even when we skip the model.
    nonisolated static func stripFillers(_ text: String) -> String {
        var result = text

        // 1. Repeated word stutters: "I I want" → "I want", "the the cat" → "the cat"
        result = result.replacingOccurrences(
            of: #"\b(\w+)\s+\1\b"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )

        // 2. Standalone fillers anywhere: um, uh, uhm, er, ah, hmm, mhm
        let standaloneFillers = #"\b(um+|uh+|uhm+|er+|ah+|hmm+|mhm+)\b[,.\s]*"#
        result = result.replacingOccurrences(
            of: standaloneFillers,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 3. Sentence-boundary fillers: "you know", "i mean", "sort of", "kind of"
        //    Only strip when at start of sentence or after comma — preserves "I mean it"
        let boundaryFillers = #"(^|[.!?,]\s*)(you know|i mean|sort of|kind of)[,]?\s*"#
        result = result.replacingOccurrences(
            of: boundaryFillers,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )

        // 4. Collapse runs of 2+ horizontal spaces (NOT newlines) from removals.
        //    Preserving \n and \n\n is critical — TextFormatter inserts them for
        //    voice commands ("new paragraph") and segment-gap paragraph breaks.
        result = result.replacingOccurrences(of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression)
        // 5. Strip leading/trailing whitespace + dangling punctuation.
        //    Use .whitespaces (not .whitespacesAndNewlines) to preserve paragraph breaks.
        result = result.trimmingCharacters(in: .whitespaces)
        result = result.replacingOccurrences(of: #"^[,;:]+\s*"#, with: "", options: .regularExpression)

        return result
    }

    /// Heuristic check: does text look "clean enough" to skip the model?
    /// Conservative — only skip if we're confident. False positives are MUCH worse
    /// than false negatives here (false positive = bad text shipped without polish).
    nonisolated static func isCleanEnough(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Check 1: First letter must be capitalized
        guard let first = trimmed.first, first.isUppercase || !first.isLetter else { return false }

        // Check 2: Must end with sentence-terminal punctuation
        guard let last = trimmed.last, ".!?".contains(last) else { return false }

        // Check 3: No obvious lowercase "i" pronoun (Whisper signature error)
        if trimmed.range(of: #"\bi\b"#, options: .regularExpression) != nil { return false }

        // Check 4: No common homophone slip-ups
        let homophoneErrors = [
            #"\byour\s+(welcome|right|wrong|here|there)\b"#,  // "your welcome" → "you're welcome"
            #"\bits\s+(a|an|the|been|going|working)\b"#,      // "its working" → "it's working"
            #"\btheir\s+(is|are|was|were)\b"#,                // "their are" → "there are"
            #"\bthey're\s+(car|house|dog|book|stuff)\b"#,    // possessive should be "their"
            #"\btoo\s+\d"#,                                    // "too 3" → "to 3" (or "two")
            #"\bwould\s+of\b"#, #"\bcould\s+of\b"#, #"\bshould\s+of\b"#, // "would of" → "would have"
        ]
        for pattern in homophoneErrors {
            if trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
        }

        // Check 5: No obvious repeated-letter typos (dictatoin, propsal, etc.)
        // Words longer than 5 chars without a common pattern are suspicious
        // (skip — too noisy a heuristic, let the model handle it)

        // Check 6: Reasonable length (single word might be a name or odd input)
        let wordCount = trimmed.split(separator: " ").count
        guard wordCount >= 3 else { return false }

        return true
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func polishWithFoundationModels(_ text: String, context: PolishContext, timeoutMs: Int) async -> String {
        // Reuse session if already created — saves cold-start cost on each call
        let session = await ensureSession()

        let prompt = Self.buildPrompt(for: text, context: context)
        let start = Date()

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    await MainActor.run { LLMPolisher.shared.recordLatency(ms) }
                    return Self.sanitize(response.content, original: text)
                } catch {
                    print("[VOICE] LLM polish error: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return nil
            }
            // Take whichever finishes first; cancel the rest
            for await result in group {
                group.cancelAll()
                return result ?? text
            }
            return text
        }
    }

    @available(macOS 26.0, *)
    private static func makeSession() -> LanguageModelSession {
        // System prompt: tight, example-driven, explicit anti-style rules.
        // Few-shot examples teach more reliably than rule lists on small models.
        let instructions = """
        Fix typos and homophones in dictated text. Preserve word order, line breaks, and style EXACTLY.

        DO fix:
        - Typos by choosing the closest correct word (dictatoin → dictation, NOT dictionary)
        - Homophones (their/there/they're, your/you're, its/it's, to/too/two)
        - Capitalization of "I", proper nouns, and sentence starts
        - Missing apostrophes in contractions (your → you're, dont → don't)

        DO NOT:
        - Rephrase, rewrite, or change meaning
        - Add or remove words (word count must match)
        - Expand contractions (you're stays you're, NEVER becomes "you are")
        - Change number/time formats (3pm stays 3pm, NOT 3 p.m.)
        - Add line breaks, paragraph breaks, semicolons, or em dashes
        - Replace one word with a different word (only fix spelling)

        If text is already clean: output it UNCHANGED.

        Examples:
        Input: i went their yesturday and saw they're car
        Output: I went there yesterday and saw their car.

        Input: your right about that
        Output: You're right about that.

        Input: meeting at 3pm tomorrow
        Output: Meeting at 3pm tomorrow.

        Input: lets ask sarah about the new york trip
        Output: Let's ask Sarah about the New York trip.

        Input: i want too make a dictatoin app
        Output: I want to make a dictation app.

        Input: Dear John, i hope your doing well.
        Output: Dear John, I hope you're doing well.

        Output the corrected text only on a single line if input is single-line. No commentary.
        """
        return LanguageModelSession(instructions: instructions)
    }

    @available(macOS 26.0, *)
    nonisolated private static func buildPrompt(for text: String, context: PolishContext) -> String {
        // Per-call prompt: minimal — system prompt has all the rules and examples.
        // Format mimics the few-shot examples to leverage in-context pattern matching.
        return """
        Context: \(context.rawValue)
        Input: \(text)
        Output:
        """
    }

    /// Defensive sanitization: strip preamble/postamble, collapse inserted newlines,
    /// reject if the output drifted too far from a polish (length, word count, content).
    nonisolated private static func sanitize(_ output: String, original: String) -> String {
        var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip delimiters if model echoed them
        if cleaned.hasPrefix("<<<") { cleaned = String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if cleaned.hasSuffix(">>>") { cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }

        // If input was a single line, collapse any inserted line breaks (model
        // sometimes adds paragraph breaks in email contexts — this strips them).
        let originalLineCount = original.components(separatedBy: .newlines).count
        if originalLineCount == 1 {
            cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
            cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Reject if word count drifted by more than 1 — model added/removed words
        let originalWords = original.split { $0.isWhitespace }.count
        let cleanedWords = cleaned.split { $0.isWhitespace }.count
        let wordDelta = abs(originalWords - cleanedWords)
        guard wordDelta <= 1 else {
            print("[VOICE] LLM polish rejected: word count drift \(originalWords)→\(cleanedWords)")
            return original
        }

        // Reject if length differs by more than 25% — model went off the rails
        let lenDelta = abs(cleaned.count - original.count)
        let threshold = max(original.count / 4, 8)
        guard lenDelta <= threshold else {
            print("[VOICE] LLM polish rejected: length drift \(original.count)→\(cleaned.count)")
            return original
        }
        // Reject if the model included an explanation marker
        let lower = cleaned.lowercased()
        for forbidden in ["here is", "here's", "i fixed", "corrected", "cleaned:"] {
            if lower.hasPrefix(forbidden) {
                print("[VOICE] LLM polish rejected: preamble detected")
                return original
            }
        }
        return cleaned
    }
    #endif
}
