// PolishPipeline.swift
//
// Multi-draft polish with a critic. Runs N polish variants in parallel
// against the SAME frozen text, then scores them to pick the best one.
//
// Why this exists: a single LLM polish pass is a coin flip on hard inputs.
// The 4B model loses proper nouns, hallucinates "?", fragments sentences,
// or merges thoughts. Each individual draft makes DIFFERENT mistakes —
// but if we run 3 variants with slightly different prompts and pick the
// one that preserved the most input content without hallucinating, we
// get most of the quality of a frontier model at the cost of 1-2s extra
// latency on Apple Silicon.
//
// Pipeline:
//   freeze entities → 3 parallel drafts → critic picks → unfreeze
//
// The drafts share the SAME frozen-input text so sentinel survival is
// directly comparable across drafts (deterministic scoring).
//
// Critic stack:
//   1. Hard rejection: any draft missing a sentinel from the input
//      (entity dropped) is immediately disqualified.
//   2. Deterministic scoring: word-count delta, hallucinated-token check,
//      structure markers (paragraphs, bullets).
//   3. LLM critic (optional, Phase 4b): a small 1.7B pass that picks the
//      "cleanest" of the survivors. Falls back to deterministic if the
//      LLM critic times out or returns garbage.
//
// Latency budget on M-series:
//   - 3 drafts parallel ≈ slowest single draft (~1.2s on 4B)
//   - Deterministic critic: <10ms
//   - LLM critic: ~400ms
//   - Total: ~1.5-2s for long dictation (was ~1.5s single-pass)

import Foundation

public enum DraftVariant: String, CaseIterable, Sendable {
    /// Conservative: minimal changes, preserve word choice, light filler strip.
    /// Used as the safety net — if structural/aggressive go wild, conservative
    /// usually stays sane.
    case conservative

    /// Structural: actively infer paragraph breaks, bullet lists, sentence
    /// boundaries. Best for long multi-topic dictations.
    case structural

    /// Aggressive: maximum filler strip, collapse all hedges, tight prose.
    /// Best for "make this readable" mode at HIGH cleanup level.
    case aggressive

    /// The cleanup-level override each variant applies on top of the user's
    /// chosen level. Conservative drops a notch, aggressive bumps a notch.
    public func adjustedCleanupLevel(_ user: String) -> String {
        switch (self, user) {
        case (.conservative, "high"):     return "medium"
        case (.conservative, "medium"):   return "light"
        case (.conservative, _):          return user
        case (.aggressive, "light"):      return "medium"
        case (.aggressive, "medium"):     return "high"
        case (.aggressive, _):            return user
        case (.structural, _):            return user
        }
    }
}

public struct PolishDraft: Sendable {
    public let variant: DraftVariant
    public let text: String
    public let latencyMs: Int

    /// Number of frozen entity sentinels (⟦E…⟧) preserved in this draft.
    /// Used by the critic to disqualify drafts that lost entities.
    public var sentinelCount: Int { Self.countSentinels(in: text) }

    static func countSentinels(in s: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"⟦E\d+⟧"#) else { return 0 }
        let ns = s as NSString
        return regex.numberOfMatches(in: s, range: NSRange(location: 0, length: ns.length))
    }
}

public enum PolishCritic {

    /// Score a single draft against the raw frozen input. Higher is better.
    /// Returns nil for disqualified drafts (entities lost or hallucinated).
    public static func score(
        draft: PolishDraft,
        rawFrozen: String,
        expectedSentinels: Int
    ) -> Double? {
        let draftSentinels = draft.sentinelCount

        // Disqualify: any sentinel from the input is missing.
        if draftSentinels < expectedSentinels {
            print("[VOICE-CRITIC] reject \(draft.variant.rawValue): lost \(expectedSentinels - draftSentinels) entities")
            return nil
        }

        // Disqualify: hallucinated sentinels (more sentinels than input had).
        // The LLM should never invent ⟦E…⟧ tokens.
        if draftSentinels > expectedSentinels {
            print("[VOICE-CRITIC] reject \(draft.variant.rawValue): hallucinated \(draftSentinels - expectedSentinels) entities")
            return nil
        }

        var score: Double = 0

        // Reward structure markers — bullets, paragraph breaks — when the
        // input clearly suggested them. Modest reward so style differences
        // don't dominate content correctness.
        let inputLower = rawFrozen.lowercased()
        let hasListCue = inputLower.contains("i need ") || inputLower.contains("i have to get")
            || inputLower.contains("first") || inputLower.contains("the list")
        if hasListCue && draft.text.contains("\n- ") {
            score += 1.0
        }

        // Reward paragraph breaks on long inputs.
        let inputWords = rawFrozen.split(separator: " ").count
        if inputWords > 80 && draft.text.contains("\n\n") {
            score += 0.5
        }

        // Penalize huge word-count divergence (model dropped or invented
        // content). Tolerance: ±40% for cleanup, but >60% suggests problem.
        let draftWords = draft.text.split(separator: " ").count
        let ratio = Double(draftWords) / Double(max(inputWords, 1))
        if ratio < 0.4 || ratio > 1.6 {
            score -= 1.5
        }

        // Penalize obvious hallucination markers.
        if draft.text.contains("As an AI") || draft.text.contains("[INST]")
            || draft.text.contains("<|") || draft.text.contains("</think>") {
            score -= 5.0
        }

        // Penalize trailing "Output:" or "Polished:" residue.
        if draft.text.lowercased().contains("output:")
            || draft.text.lowercased().hasPrefix("polished:")
            || draft.text.lowercased().hasPrefix("here is the polished") {
            score -= 3.0
        }

        // Light reward for absence of em-dashes (rule says no em-dashes).
        if !draft.text.contains("\u{2014}") && !draft.text.contains("\u{2013}") {
            score += 0.2
        }

        // Per-variant baseline preference: structural slightly preferred for
        // long inputs (paragraphs matter); conservative slightly preferred
        // for short inputs (less risk of restructuring); aggressive boosted
        // when user explicitly asked for HIGH cleanup elsewhere.
        switch draft.variant {
        case .structural:
            if inputWords > 80 { score += 0.3 }
        case .conservative:
            if inputWords < 30 { score += 0.3 }
        case .aggressive:
            // Aggressive doesn't get a baseline — it has to earn it on cleanup quality.
            break
        }

        return score
    }

    /// Pick the best draft from a list. Returns nil if all drafts are disqualified.
    public static func pick(
        drafts: [PolishDraft],
        rawFrozen: String,
        expectedSentinels: Int
    ) -> PolishDraft? {
        let scored = drafts.compactMap { draft -> (PolishDraft, Double)? in
            guard let s = score(draft: draft, rawFrozen: rawFrozen, expectedSentinels: expectedSentinels) else {
                return nil
            }
            return (draft, s)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let scoreLog = scored.map { "\($0.0.variant.rawValue)=\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
        print("[VOICE-CRITIC] picked \(best.0.variant.rawValue) | scores: \(scoreLog)")
        return best.0
    }
}

public enum PolishPipeline {

    /// Run all three drafts in parallel and pick the best.
    /// Falls back to the input itself if every draft is disqualified
    /// (extremely defensive — preserves user content over breaking it).
    public static func run(
        frozenInput: String,
        expectedSentinels: Int,
        runDraft: @Sendable @escaping (DraftVariant) async -> String
    ) async -> String {
        let started = CFAbsoluteTimeGetCurrent()

        let drafts = await withTaskGroup(of: PolishDraft.self) { group -> [PolishDraft] in
            for variant in DraftVariant.allCases {
                group.addTask {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let text = await runDraft(variant)
                    let dt = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    return PolishDraft(variant: variant, text: text, latencyMs: dt)
                }
            }
            var out: [PolishDraft] = []
            for await draft in group { out.append(draft) }
            return out
        }

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        print("[VOICE-PIPELINE] 3 drafts complete in \(totalMs)ms: " +
              drafts.map { "\($0.variant.rawValue)=\($0.latencyMs)ms" }.joined(separator: " "))

        if let winner = PolishCritic.pick(
            drafts: drafts,
            rawFrozen: frozenInput,
            expectedSentinels: expectedSentinels
        ) {
            return winner.text
        }

        // All drafts disqualified — fall back to conservative (most likely
        // to be intact even if it lost entities, because its prompt is the
        // least invasive). If conservative isn't in the list either, return
        // the raw frozen input — postprocessor will still unfreeze + finish.
        print("[VOICE-PIPELINE] WARN: all drafts disqualified, falling back")
        if let conservative = drafts.first(where: { $0.variant == .conservative }) {
            return conservative.text
        }
        return frozenInput
    }
}
