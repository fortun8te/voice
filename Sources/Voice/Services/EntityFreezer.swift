// EntityFreezer.swift
//
// Protects fragile spans (emails, URLs, code, contractions, domains) from
// LLM polishing by replacing them with sentinel tokens BEFORE the model
// sees the text, then restoring them verbatim AFTER the model returns.
//
// Solves a class of bugs where the polisher:
//   - splits "michael@gmail.com" → "michael@gmail. Com" (sees `.com` as a
//     sentence boundary)
//   - mangles "let's say" → "let'say" (apostrophe handling drift)
//   - capitalizes "github.com" → "GitHub.com" mid-paragraph
//   - drops or rewrites already-correct identifiers
//
// Sentinel format: ⟦E0⟧, ⟦E1⟧, ⟦E2⟧… using mathematical white square
// brackets (U+27E6 / U+27E7). These survive Qwen3 tokenization as a
// single visible chunk and don't collide with any normal English text.
//
// Phase 1 of the multi-agent polish pipeline plan. Subsequent phases
// (ensemble drafts, critic) build on top of this — every draft polishes
// the SAME frozen text so unfreezing produces identical entity content
// across drafts.

import Foundation

public enum EntityFreezer {

    /// Result of freezing: the modified text plus the map needed to restore
    /// the original spans.
    public struct Frozen {
        public let text: String
        public let entities: [String: String]
        public var isEmpty: Bool { entities.isEmpty }
    }

    /// Pattern priority — longest / most specific first. An email must be
    /// frozen before its domain part would otherwise match the domain pass.
    private static let patterns: [(name: String, regex: String)] = [
        // Emails — full RFC-ish, but pragmatic.
        ("email", #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),

        // Full URLs with scheme.
        ("url", #"https?://[^\s)\]\}>,]+"#),

        // Bare domains with TLD — matches "github.com/user", "example.io",
        // "api.example.co.uk/v2". Requires at least one alphanumeric label
        // before the TLD to avoid matching ". com" or "the .net".
        ("domain", #"\b[A-Za-z0-9][A-Za-z0-9\-]*(?:\.[A-Za-z0-9\-]+)*\.(?:com|io|net|org|dev|app|ai|co|us|uk|gov|edu|me|tv|fm|so|sh|xyz|tech|cloud)(?:/[^\s)\]\}>,]*)?\b"#),

        // Backtick-protected spans (already explicitly user-marked).
        ("backtick", #"`[^`\n]+`"#),

        // File paths (POSIX-style absolute paths).
        ("path", #"(?:^|\s)(/(?:[A-Za-z0-9._\-]+/?)+)(?=\s|$|[,;.])"#),

        // Contractions and possessives — the "let's", "don't", "it's" class.
        // Word boundary on both sides keeps us out of code/identifier
        // spans (which are already frozen by backtick/path passes above).
        ("contraction", #"\b[A-Za-z]+'[A-Za-z]+\b"#),
    ]

    /// Freeze fragile spans. Returns the frozen text and a map for
    /// unfreezing. Iterates patterns in priority order; later patterns
    /// won't re-match content already replaced with a sentinel because
    /// sentinels contain `⟦` and `⟧`, which none of the patterns match.
    public static func freeze(_ input: String) -> Frozen {
        var working = input
        var entities: [String: String] = [:]
        var counter = 0

        for (_, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = working as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: working, range: range)

            // Reverse so earlier indices stay valid as we substitute.
            for match in matches.reversed() {
                // For patterns that use a capture group (path), prefer it.
                let captureRange: NSRange = {
                    if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                        return match.range(at: 1)
                    }
                    return match.range
                }()
                guard captureRange.location != NSNotFound else { continue }
                let original = ns.substring(with: captureRange)

                // Skip if already frozen (shouldn't happen but defensive).
                if original.contains("⟦") && original.contains("⟧") { continue }

                let sentinel = "⟦E\(counter)⟧"
                entities[sentinel] = original
                counter += 1
                working = (working as NSString).replacingCharacters(in: captureRange, with: sentinel)
            }
        }

        return Frozen(text: working, entities: entities)
    }

    /// Restore frozen spans. Iterates sentinels in reverse-numeric order
    /// so longer keys substitute before shorter ones (defensive — sentinels
    /// don't share prefixes in our format, but if the format ever changes,
    /// this ordering avoids a class of bugs).
    public static func unfreeze(_ text: String, entities: [String: String]) -> String {
        guard !entities.isEmpty else { return text }
        var output = text
        let sortedKeys = entities.keys.sorted { lhs, rhs in
            // Sort by length desc, then lexical desc.
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs > rhs
        }
        for key in sortedKeys {
            guard let original = entities[key] else { continue }
            output = output.replacingOccurrences(of: key, with: original)
        }
        return output
    }

    /// One-shot helper for the common case: freeze → transform → unfreeze.
    /// The transform closure receives the frozen text and returns the
    /// polished version (which should preserve sentinel tokens verbatim).
    public static func roundTrip(
        _ input: String,
        transform: (String) async -> String
    ) async -> String {
        let frozen = freeze(input)
        if frozen.isEmpty {
            return await transform(input)
        }
        let transformed = await transform(frozen.text)
        return unfreeze(transformed, entities: frozen.entities)
    }
}
