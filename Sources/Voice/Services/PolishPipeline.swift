// PolishPipeline.swift
//
// Relaxed-cloud sanitizer for polish validation.
//
// The single sanitize() in Qwen3Polisher.swift was originally written for
// the LOCAL 1.7B model — small, error-prone, needed tight word/length
// budgets and a long list of injection guards. The CLOUD path
// (Cerebras gpt-oss-120b / Groq llama3.1-8b) is far stronger and
// legitimately produces:
//   - long restructuring rewrites that drop filler words wholesale
//     (fails strict word-preservation)
//   - email/letter reformatting that adds "\n\nBest,\nName"
//     (fails strict word-count budget)
//   - bullet expansion with colons added ("groceries: a, b, c, d")
//     (fails strict sentence-count budget)
//   - number normalization ("twenty three percent" → "23%")
//     (fails strict char-length budget)
// Run through the legacy strict sanitizer, every one of those polishes
// was being SILENTLY rejected and the raw transcript shipped instead —
// the "Voice quality is bad" experience.
//
// The Sanitizer here exposes a public API the polisher can call on the
// cloud path. Two modes:
//   .strict  — legacy behavior (kept verbatim for the local 1.7B path)
//   .relaxed — trust the cloud model, only block absolute-rule
//              violations: em-dashes, emojis, vulgarity injection,
//              proper-noun/number/email/URL preservation, semantic flips,
//              prompt echo / preamble residue.
//
// Visible logging:
//   Every rejection prints `[VOICE-SANITIZE] rejected: rule=<name> ...`
//   so reviewers can grep the dev console for false-positives.
//
// Emergency override:
//   UserDefaults bool `voice.disableSanitizer` (read here, can be set by
//   a SwiftUI `@AppStorage("voice.disableSanitizer")` toggle in Settings).
//   When true, Sanitizer.run() ALWAYS accepts the model output. Lets the
//   user A/B test "is the sanitizer the problem?" with one toggle.

import Foundation

// MARK: - Sanitizer (the relaxed-cloud validator)

/// Public validator that decides whether to accept a polish or fall back
/// to the raw input. Two modes — STRICT for the local 1.7B (legacy
/// behavior) and RELAXED for the cloud (Cerebras / Groq).
///
/// Usage from the polisher (cloud branch):
/// ```
/// let accepted = Sanitizer.run(
///     polish: cloudOut,
///     original: frozenInput,
///     mode: .relaxed,
///     cleanupLevel: cleanupLevel,
///     userVocabulary: userVocabulary
/// )
/// if accepted == nil {
///     // Sanitizer rejected — fall back to raw input.
///     polishedFrozen = frozenInput
/// } else {
///     polishedFrozen = accepted!
/// }
/// ```
///
/// `run` ALWAYS returns the polish unchanged when the user has toggled
/// `voice.disableSanitizer` on, so the user can A/B test whether the
/// sanitizer is the source of bad output.
public enum Sanitizer {

    /// How strictly the sanitizer should validate the model output.
    public enum Mode: Sendable {
        /// Legacy strict mode: tight word/length budgets, contraction +
        /// filler caps, every input word must roughly appear in output.
        /// Use for the local 1.7B polish path — that model is too small
        /// to trust with aggressive restructuring.
        case strict

        /// Relaxed cloud mode: trust the model. Only block ABSOLUTE-RULE
        /// violations:
        ///   - em-dashes / en-dashes (Voice never ships them)
        ///   - emojis (banned by spec)
        ///   - vulgarity injection (introduced words not in original)
        ///   - proper-noun loss (>2 names dropped)
        ///   - number/email/URL loss (substring preservation)
        ///   - semantic flips (don't think → think, etc.)
        ///   - prompt echo / preamble residue ("Here's the polish: …")
        ///   - prompt-injection markers (<|, [INST], As an AI, </think>)
        /// Sentence count, word count, contraction count, filler count
        /// are NOT checked — the cloud is allowed to restructure freely.
        case relaxed
    }

    /// UserDefaults key for the emergency override. When true (matching
    /// `@AppStorage("voice.disableSanitizer")` in a SwiftUI toggle), the
    /// sanitizer always accepts the model output untouched.
    public static let disableKey = "voice.disableSanitizer"

    /// Validate `polish` against `original`. Returns the polish on accept,
    /// nil on reject. Every rejection logs `[VOICE-SANITIZE] rejected:
    /// rule=<name> input="..." polish="..."` so the dev console makes it
    /// obvious which rule fired.
    public static func run(
        polish: String,
        original: String,
        mode: Mode,
        cleanupLevel: String? = "medium",
        userVocabulary: [String]? = nil
    ) -> String? {
        // Emergency override — user-toggleable. Pass through unconditionally.
        if UserDefaults.standard.bool(forKey: disableKey) {
            print("[VOICE-SANITIZE] DISABLED via \(disableKey) — accepting polish unconditionally")
            return polish
        }

        var cleaned = polish.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            logReject(rule: "empty-polish", input: original, polish: polish)
            return nil
        }

        // --- ABSOLUTE RULES — apply to every mode ---

        // 1. Em-dash / en-dash / horizontal-bar. The user HATES these.
        //    These chars are absolute-banned per the app spec. We reject
        //    rather than strip so a polish that LEANS on dashes for
        //    structure (a common Claude/GPT habit) loses its winning
        //    bid and a better candidate (next draft / raw input) takes
        //    over. The downstream `stripDashes` pass is the secondary
        //    safety net for any dashes that slip through.
        if cleaned.contains("\u{2014}") || cleaned.contains("\u{2013}") || cleaned.contains("\u{2015}") {
            logReject(rule: "em-dash", input: original, polish: polish)
            return nil
        }

        // 2. Emojis. Also banned by spec. Reject if any extended-pictographic
        //    char appears that was NOT in the original (so a user dictating
        //    "tell me about 🚀 launches" still works).
        if containsEmojiNotInOriginal(polish: cleaned, original: original) {
            logReject(rule: "emoji", input: original, polish: polish)
            return nil
        }

        // 3. Prompt-injection / chat-template residue. The model leaked
        //    its system frame — always wrong.
        let residueMarkers = ["<|im_start|>", "<|im_end|>", "<|", "|>",
                              "[INST]", "[/INST]", "</think>", "<think>",
                              "As an AI", "As a language model"]
        for marker in residueMarkers {
            if cleaned.contains(marker) {
                logReject(rule: "prompt-residue:\(marker)", input: original, polish: polish)
                return nil
            }
        }

        // 4. Preamble residue. "Here's the polish:", "Output:", "Polished:"…
        let lowerHead = cleaned.lowercased()
        let preambles = ["here is the polish", "here's the polish",
                         "here is the polished", "here's the polished",
                         "here is the cleaned", "here's the cleaned",
                         "polished:", "output:", "cleaned:",
                         "i fixed", "corrected:"]
        for pre in preambles {
            if lowerHead.hasPrefix(pre) {
                logReject(rule: "preamble:\(pre)", input: original, polish: polish)
                return nil
            }
        }

        // 5. Trailing "Output:" / "Input:" continuation residue.
        if cleaned.range(of: #"\n\s*(Input|Output):"#, options: .regularExpression) != nil {
            logReject(rule: "trailing-turn-marker", input: original, polish: polish)
            return nil
        }

        // 6. Vulgarity injection. Word-boundary match: any word in the
        //    blocklist that's in the polish but NOT the original is a
        //    polish-induced corruption.
        if let bad = injectedVulgarity(polish: cleaned, original: original) {
            logReject(rule: "vulgarity:\(bad)", input: original, polish: polish)
            return nil
        }

        // 7. Semantic flip detection — negation lost. Catastrophic, all modes.
        if hasSemanticFlip(polish: cleaned, original: original) {
            logReject(rule: "semantic-flip", input: original, polish: polish)
            return nil
        }

        // --- PROPER NOUN / NUMBER / EMAIL / URL preservation ---
        // Required in both modes; relaxed mode is identical here — these
        // are anchors the cloud model still must preserve even when it
        // restructures everything around them.

        if let missing = missingProperNouns(polish: cleaned, original: original) {
            logReject(rule: "lost-proper-noun:\(missing)", input: original, polish: polish)
            return nil
        }

        if let lostNum = missingSignificantNumber(polish: cleaned, original: original) {
            logReject(rule: "lost-number:\(lostNum)", input: original, polish: polish)
            return nil
        }

        if let lostEmail = missingEmail(polish: cleaned, original: original) {
            logReject(rule: "lost-email:\(lostEmail)", input: original, polish: polish)
            return nil
        }

        if let lostURL = missingURL(polish: cleaned, original: original) {
            logReject(rule: "lost-url:\(lostURL)", input: original, polish: polish)
            return nil
        }

        // --- STRICT-MODE-ONLY BUDGETS ---
        // Tight word/length/contraction/filler caps that legitimately
        // catch the local 1.7B but starve cloud restructuring. Skipped
        // entirely in .relaxed.
        if mode == .strict {
            if let reason = strictBudgetCheck(
                polish: cleaned,
                original: original,
                cleanupLevel: cleanupLevel,
                userVocabulary: userVocabulary
            ) {
                logReject(rule: "strict:\(reason)", input: original, polish: polish)
                return nil
            }
        } else {
            // Relaxed: only block COMPLETELY-DEGENERATE drift —
            // empty output or output that's <10% of input length on
            // a non-trivial input. Anything in between is the cloud
            // legitimately rewriting.
            let origCount = original.count
            if origCount > 40, cleaned.count < max(8, origCount / 10) {
                logReject(rule: "relaxed:catastrophic-shrink", input: original, polish: polish)
                return nil
            }
            // Symmetric guard for runaway expansion (model in a loop).
            // Cap at 4x the input — generous, covers email/letter
            // reformatting + signature + 4 bullets without false-positive.
            if origCount > 0, cleaned.count > max(80, origCount * 4) {
                logReject(rule: "relaxed:runaway-expansion", input: original, polish: polish)
                return nil
            }
        }

        return cleaned
    }

    // MARK: - Internals

    private static func logReject(rule: String, input: String, polish: String) {
        let inSnip = input.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
        let outSnip = polish.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
        print("[VOICE-SANITIZE] rejected: rule=\(rule) input=\"\(inSnip)\" polish=\"\(outSnip)\"")
    }

    /// Extended-pictographic chars in `polish` that aren't in `original`.
    private static func containsEmojiNotInOriginal(polish: String, original: String) -> Bool {
        var origEmojis = Set<UnicodeScalar>()
        for s in original.unicodeScalars where s.properties.isEmojiPresentation || s.properties.isEmoji {
            origEmojis.insert(s)
        }
        for s in polish.unicodeScalars {
            // Properties.isEmoji matches digit/asterisk/# too (keycap chars).
            // Require Extended_Pictographic for true emoji-only test.
            guard s.properties.isEmojiPresentation || isExtendedPictographic(s) else { continue }
            if !origEmojis.contains(s) { return true }
        }
        return false
    }

    /// True for Unicode "Extended_Pictographic" — covers all emoji ranges
    /// without false-positives on digits / # / *. Approximated by the
    /// dominant emoji blocks; conservative on the side of allowing.
    private static func isExtendedPictographic(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (0x1F300...0x1FAFF).contains(v)   // misc symbols & pictographs, extended ranges
            || (0x2600...0x27BF).contains(v)     // misc symbols, dingbats
            || (0x1F1E6...0x1F1FF).contains(v)   // regional indicator (flags)
    }

    /// Returns the first vulgar word introduced by polish, or nil.
    private static let vulgarWords: Set<String> = [
        "cuck", "fuck", "fucking", "fucked", "fucker",
        "shit", "shitty", "shitting",
        "cunt", "bitch", "bastard",
        "nigger", "nigga", "faggot", "fag", "retard", "retarded",
        "asshole", "dick", "cock", "pussy", "twat", "whore", "slut"
    ]

    private static func injectedVulgarity(polish: String, original: String) -> String? {
        let origSet = wordSet(original)
        let polSet = wordSet(polish)
        for v in vulgarWords {
            if polSet.contains(v) && !origSet.contains(v) { return v }
        }
        return nil
    }

    private static func wordSet(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// Detect catastrophic semantic flip: original had a negation
    /// ("don't think") that's flipped to its positive ("think") in polish.
    private static let criticalFlips: [(neg: String, pos: String)] = [
        ("don't think", "think"),
        ("do not think", "think"),
        ("shouldn't", "should"),
        ("should not", "should"),
        ("won't", "will"),
        ("will not", "will"),
        ("can't", "can"),
        ("cannot", "can"),
    ]

    private static func hasSemanticFlip(polish: String, original: String) -> Bool {
        let o = original.lowercased()
        let p = polish.lowercased()
        for flip in criticalFlips {
            let origHasNeg = containsWord(flip.neg, in: o)
            let polLostNeg = !containsWord(flip.neg, in: p) && containsWord(flip.pos, in: p)
            if origHasNeg && polLostNeg { return true }
        }
        return false
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Returns the first proper noun (≥4 chars, capitalized) present in
    /// original but not in polish. Allows up to 2 losses (typo collapse,
    /// pronoun replacement) — only fires when ≥3 names disappear.
    private static func missingProperNouns(polish: String, original: String) -> String? {
        let origWords = original.components(separatedBy: .whitespacesAndNewlines)
        let nouns = origWords.compactMap { w -> String? in
            let stripped = w.trimmingCharacters(in: .punctuationCharacters)
            guard stripped.count >= 4,
                  stripped.first?.isUppercase == true,
                  stripped.dropFirst().contains(where: { $0.isLowercase })
            else { return nil }
            return stripped
        }
        guard nouns.count >= 2 else { return nil }
        let polLower = polish.lowercased()
        let lost = nouns.filter { !polLower.contains($0.lowercased()) }
        if lost.count > 2 { return lost.first }
        return nil
    }

    /// Extract all multi-digit numbers (≥2 digits) from original. If more
    /// than 1 is missing from polish AND wasn't replaced by a normalized
    /// form ("twenty three" → "23", "$4.7M"), reject. Single-digit drops
    /// are tolerated (filler counts).
    private static func missingSignificantNumber(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"\b\d{2,}\b"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let nums = matches.map { ns.substring(with: $0.range) }
        guard !nums.isEmpty else { return nil }
        let polDigits = polish.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            .map { Character($0) }
            .reduce("") { $0 + String($1) }
        let lost = nums.filter { !polDigits.contains($0) && !polish.contains($0) }
        // Allow up to 1 loss (e.g. "year 2025" → "this year" is fine if
        // it was the ONLY number). 2+ lost numbers = the model deleted
        // material content.
        if lost.count > 1 { return lost.first }
        return nil
    }

    private static func missingEmail(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let polLower = polish.lowercased()
        for m in matches {
            let email = ns.substring(with: m.range)
            if !polLower.contains(email.lowercased()) { return email }
        }
        return nil
    }

    private static func missingURL(polish: String, original: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"https?://[^\s)\]\}>,]+"#) else { return nil }
        let ns = original as NSString
        let matches = rx.matches(in: original, range: NSRange(location: 0, length: ns.length))
        let polLower = polish.lowercased()
        for m in matches {
            let url = ns.substring(with: m.range)
            if !polLower.contains(url.lowercased()) { return url }
        }
        return nil
    }

    // MARK: - Strict-mode budget check (legacy)
    //
    // This intentionally does NOT duplicate every detail of the Qwen3Polisher
    // sanitize() — that function is the legacy, comprehensive strict path
    // and stays where it is for the local 1.7B caller. The strict branch
    // here is a SECONDARY guard suitable for any new strict caller (e.g.
    // when the local path is updated to use Sanitizer.run uniformly).
    // It enforces: word-count drift, length drift, and absence of preamble
    // residue — the same three guards that caught >90% of local-1.7B
    // failures in production.

    private static func strictBudgetCheck(
        polish: String,
        original: String,
        cleanupLevel: String?,
        userVocabulary: [String]?
    ) -> String? {
        let originalWords = original.split { $0.isWhitespace }.count
        let polishWords = polish.split { $0.isWhitespace }.count
        let wordDelta = abs(originalWords - polishWords)
        let basePct: Int
        switch cleanupLevel?.lowercased() {
        case "none":   basePct = 5
        case "light":  basePct = 15
        case "high":   basePct = 60
        default:       basePct = 30
        }
        let wordBudget = max(3, originalWords * basePct / 100)
        if wordDelta > wordBudget {
            return "word-drift(\(originalWords)→\(polishWords),budget=\(wordBudget))"
        }
        let lenDelta = abs(original.count - polish.count)
        let lenBudget = max(20, original.count * max(35, basePct) / 100)
        if lenDelta > lenBudget {
            return "length-drift(\(original.count)→\(polish.count),budget=\(lenBudget))"
        }
        _ = userVocabulary // reserved for future vocab-aware relaxation
        return nil
    }
}
