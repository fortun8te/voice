// CorrectionLearner.swift
//
// Wispr-Flow-style "learn from correction" dictionary.
//
// When VOICE auto-pastes a transcript and the user immediately fixes a
// misheard word right there in the text field (e.g. ASR wrote "Diatype" as
// "diatribe", and they retype it), we want to LEARN the corrected word so
// next time both the ASR vocabulary booster AND the LLM polisher recognize
// it — without the user ever opening a settings pane.
//
// HOW IT WORKS
//   1. After a successful auto-paste, VoiceApp hands us (pastedText, snapshot)
//      where `snapshot` captures the focused AX element at paste time.
//   2. We schedule a one-shot check ~5s later (cancellable). Any new paste
//      cancels the prior pending check, so rapid-fire dictation doesn't pile
//      up overlapping diffs.
//   3. On the check we re-read the element's current text via AX. We locate
//      the region where our pasted text landed and diff it token-by-token
//      against what's there now. Single-word SUBSTITUTIONS are the signal:
//      a token VOICE wrote was replaced by a different, plausible new term.
//   4. Plausible new terms get added to the boosted vocabulary (persisted,
//      feeds ASR boosting via UserDictionary → CombinedDictionary, and the
//      polish vocab via ProperNounVocabulary) and surfaced via a toast.
//
// GUARDRAILS (see `isPlausibleNewTerm` + the diff): never crash on denied /
// stale AX, never learn when the field was cleared, skip common English
// words, punctuation, numbers, deletions, and already-known terms. At most a
// couple of words learned per correction.

import Foundation
import AppKit          // AXIsProcessTrusted, AX* accessibility APIs

@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// Fired (on the main actor) for each newly-learned word so the UI can
    /// show an "Added 'X'" pill. Set by VoiceApp.
    var onWordLearned: ((String) -> Void)?

    /// How long to wait after a paste before checking for a correction.
    /// Long enough for the user to notice + fix a misheard word, short enough
    /// that the element snapshot is still valid and the field hasn't moved on.
    private let checkDelay: TimeInterval = 5.0

    /// Max words to learn from a single correction — keeps a big rewrite from
    /// flooding the dictionary with one-off edits.
    private let maxWordsPerCorrection = 3

    private let paster = CursorPaster()

    private var pendingText: String?
    private var pendingSnapshot: CursorPaster.PasteTargetSnapshot?
    private var checkTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public entry point

    /// Record a freshly-pasted transcript + its target element, and schedule a
    /// delayed correction check. Cancels any prior pending check.
    func track(pastedText: String, snapshot: CursorPaster.PasteTargetSnapshot) {
        // Only meaningful when we can actually re-read the field later.
        guard AXIsProcessTrusted(), snapshot.focusedElement != nil else { return }
        let trimmed = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        pendingText = pastedText
        pendingSnapshot = snapshot

        checkTask?.cancel()
        let delay = checkDelay
        checkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runCheck()
        }
    }

    // MARK: - The delayed check

    private func runCheck() {
        guard let pasted = pendingText, let snapshot = pendingSnapshot else { return }
        pendingText = nil
        pendingSnapshot = nil

        // Re-read the element. nil → AX denied / element stale → no-op.
        guard let current = paster.currentText(of: snapshot) else { return }
        // Field cleared (or emptied) → never learn.
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Unchanged → nothing to learn.
        guard current != pasted else { return }

        let substitutions = detectSubstitutions(pasted: pasted, current: current)
        guard !substitutions.isEmpty else { return }

        // Build the known-vocab set once (case-insensitive) for dedup.
        let known = Set(
            (ProperNounVocabulary.current() + CombinedDictionary.terms())
                .map { $0.lowercased() }
        )

        var learnedThisRound = Set<String>()
        for (old, new) in substitutions {
            guard learnedThisRound.count < maxWordsPerCorrection else { break }
            guard isPlausibleNewTerm(new, replacing: old, known: known) else { continue }
            guard !learnedThisRound.contains(new.lowercased()) else { continue }

            learn(new)
            learnedThisRound.insert(new.lowercased())
        }
    }

    // MARK: - Learning

    private func learn(_ word: String) {
        // Single source of truth: ProperNounVocabulary. It now feeds BOTH paths
        // — ASR boosting (CombinedDictionary.vocabularyContext includes
        // ProperNounVocabulary.customTerms() at the highest weight) AND the
        // polish prompt vocab / EntityFreezer. Writing only here means the
        // Settings Dictionary "remove" fully clears a word from both ASR and
        // polish (no stale UserDictionary copy left boosting it).
        ProperNounVocabulary.add(word)

        Telemetry.log("vocab.learned", properties: ["word": word])
        print("[VOICE-CORRECTION] learned '\(word)' from in-field fix")
        onWordLearned?(word)
    }

    // MARK: - Diffing

    /// Locate the pasted region inside the current field value and return the
    /// list of (old → new) single-token substitutions. The pasted text was
    /// inserted at the cursor, so we search for the most informative anchor we
    /// can: the longest shared prefix/suffix around the pasted region. To keep
    /// it cheap and robust we tokenize both the pasted text and the current
    /// value, then run a token-level LCS alignment and read substitutions off
    /// the alignment.
    ///
    /// We don't need to pinpoint the exact insertion offset: aligning the
    /// pasted tokens against the (usually larger) current tokens via LCS lets
    /// surrounding unchanged text match up, and the only divergences inside the
    /// aligned span are the user's edits.
    private func detectSubstitutions(pasted: String, current: String) -> [(String, String)] {
        let pastedTokens = tokenize(pasted)
        let currentTokens = tokenize(current)
        guard !pastedTokens.isEmpty, !currentTokens.isEmpty else { return [] }

        // Window the current tokens to the region that overlaps the paste,
        // anchored by the first/last pasted token if we can find them. This
        // avoids aligning against the user's entire pre-existing document.
        let window = alignmentWindow(pasted: pastedTokens, current: currentTokens)
        let curWindow = Array(currentTokens[window])

        return lcsSubstitutions(old: pastedTokens, new: curWindow)
    }

    /// Find the slice of `current` that most likely corresponds to the pasted
    /// region by anchoring on the first and last pasted tokens. Falls back to
    /// the whole array when anchors can't be found.
    private func alignmentWindow(pasted: [String], current: [String]) -> Range<Int> {
        let lowerCurrent = current.map { $0.lowercased() }
        let firstTok = pasted.first!.lowercased()
        let lastTok = pasted.last!.lowercased()

        let start = lowerCurrent.firstIndex(of: firstTok) ?? 0
        // Search for the last token at or after `start`.
        var end = current.count
        if let rel = lowerCurrent[start...].lastIndex(of: lastTok) {
            end = rel + 1
        }
        guard start < end else { return 0..<current.count }
        // Guard against pathological windows (anchors matched far apart):
        // cap the window to a reasonable multiple of the pasted length.
        let maxLen = max(pasted.count * 3, pasted.count + 8)
        if end - start > maxLen { return start..<min(start + maxLen, current.count) }
        return start..<end
    }

    /// Token-level LCS alignment → emit (old, new) pairs where a single old
    /// token was replaced by a single new token at the aligned position.
    /// Pure deletions and insertions are ignored (we only learn replacements).
    private func lcsSubstitutions(old: [String], new: [String]) -> [(String, String)] {
        let m = old.count, n = new.count
        guard m > 0, n > 0 else { return [] }
        // Cap to keep the DP cheap; corrections are tiny in practice.
        guard m <= 400, n <= 400 else { return [] }

        let oldLower = old.map { $0.lowercased() }
        let newLower = new.map { $0.lowercased() }

        // LCS DP table.
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if oldLower[i] == newLower[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        // Backtrack to recover the edit script.
        var subs: [(String, String)] = []
        var i = 0, j = 0
        while i < m && j < n {
            if oldLower[i] == newLower[j] {
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                // Token `old[i]` is dropped. If the next new token is also a
                // divergence (not part of the LCS), treat it as a substitution
                // old[i] → new[j]; otherwise it's a pure deletion (skip).
                if dp[i + 1][j] == dp[i][j + 1] && j < n {
                    subs.append((old[i], new[j]))
                    i += 1; j += 1
                } else {
                    i += 1 // deletion
                }
            } else {
                j += 1 // insertion
            }
        }
        return subs
    }

    /// Split text into word-ish tokens. Keeps letters/digits and internal
    /// apostrophes/hyphens; drops surrounding punctuation and whitespace.
    private func tokenize(_ text: String) -> [String] {
        let pattern = #"[A-Za-z0-9][A-Za-z0-9'\-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Plausibility guardrails

    /// A correction is worth learning only when `new` looks like a real,
    /// not-yet-known term the user deliberately typed in place of `old`.
    private func isPlausibleNewTerm(_ new: String, replacing old: String, known: Set<String>) -> Bool {
        let word = new.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
        // Length floor — skip "a", "of", short filler.
        guard word.count >= 3 else { return false }
        // Must be a real substitution, not just casing.
        guard word.lowercased() != old.lowercased() else { return false }
        // Must contain letters; allow internal digits/capitals ("Diatype",
        // "veCRV", "GPT4"), but reject pure numbers / number-only edits.
        guard word.contains(where: { $0.isLetter }) else { return false }
        guard !word.allSatisfy({ $0.isNumber }) else { return false }
        // Reject anything with characters outside our allowed alphabet
        // (the tokenizer already constrains this, but be defensive).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
        guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Skip common English words (sentence-start caps, filler, etc.).
        guard !Self.commonEnglish.contains(word.lowercased()) else { return false }
        // Already known to ASR boost / polish vocab → nothing to learn.
        guard !known.contains(word.lowercased()) else { return false }
        return true
    }

    /// Conservative stoplist of frequent English words. A misheard→fix where
    /// the fix is an everyday word is almost never a vocabulary term worth
    /// boosting (and boosting common words hurts ASR). Kept small and cheap;
    /// proper-noun-ish corrections sail through.
    private static let commonEnglish: Set<String> = [
        "the", "and", "but", "for", "are", "was", "were", "you", "your",
        "they", "them", "this", "that", "these", "those", "with", "from",
        "have", "has", "had", "not", "what", "when", "where", "who", "why",
        "how", "all", "any", "can", "could", "would", "should", "will",
        "just", "like", "about", "into", "than", "then", "there", "their",
        "here", "some", "more", "most", "much", "many", "want", "need",
        "make", "made", "take", "took", "come", "came", "going", "gone",
        "yes", "yeah", "okay", "well", "actually", "maybe", "really",
        "today", "tomorrow", "yesterday", "now", "thing", "things", "stuff",
        "good", "great", "nice", "bad", "sure", "right", "left", "very",
        "also", "even", "still", "back", "over", "under", "again", "kind",
        "sort", "look", "looks", "looking", "said", "says", "tell", "told",
        "think", "thought", "know", "knew", "feel", "felt", "work", "works",
    ]
}
