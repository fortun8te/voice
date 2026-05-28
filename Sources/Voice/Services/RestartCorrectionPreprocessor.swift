// RestartCorrectionPreprocessor.swift
// ============================================================
// Deterministic pre-processor that resolves speaker self-corrections
// in ASR output BEFORE the LLM polish stage.
//
// Background:
//   The LLM is told via system prompt to drop abandoned restart attempts
//   ("two cardons. No wait, one cardon" -> "one cardon"), but on a 4B
//   parameter model the rule does not fire reliably — the abandoned
//   version often survives the polish call. We move this responsibility
//   into deterministic Swift code so the LLM never sees the abandoned
//   text, which both improves output quality AND frees the LLM to focus
//   on rules it actually executes well (paragraph structure, technical
//   strings, message body quoting).
//
// Conservative principle:
//   When in doubt, KEEP the speaker's words. False negatives (failing
//   to drop a real restart) are vastly preferable to false positives
//   (deleting content the speaker actually meant). Every pass requires
//   evidence of correction; ambiguous text is passed through unchanged.
//
// Four passes (each independent, each can be disabled):
//   1. Stutter removal      — "the the the cat" -> "the cat"
//                            — "ke keep" -> "keep"
//   2. Explicit correction  — "X. No wait Y" -> "Y" (only when X≈Y similar)
//   3. Near-duplicate clause— "X. Or X..." -> latest version
//   4. Punctuation cleanup  — collapse the gaps left by passes 1-3
//
// Confidence-aware mode:
//   If per-token confidence scores are supplied, a low-confidence span
//   adjacent to a near-duplicate biases the algorithm toward dropping
//   the low-confidence side. Without scores, all decisions are made
//   from text alone (conservative defaults).
// ============================================================

import Foundation

public enum RestartCorrectionPreprocessor {

    // MARK: - Public API

    public struct Options: Sendable {
        public var stutterRemoval: Bool
        public var phraseRepetition: Bool
        public var explicitCorrections: Bool
        public var nearDuplicates: Bool
        public var discourseFiller: Bool
        public var partialWordComma: Bool
        public var confidenceScores: [Float]?
        /// 0.0–1.0. Lower = more aggressive (drop more). Default 0.55 is
        /// conservative — only drops when n-gram overlap is clearly high.
        public var nearDuplicateThreshold: Double
        /// When true, the no-cue frame-restart pass runs ("I want pepperoni
        /// pizza / I want hawaiian pizza tonight" -> "I want hawaiian pizza
        /// tonight"). Off-by-default-style false-positive prone, so users can
        /// disable via @AppStorage("voice.aggressiveRestart").
        public var aggressiveRestart: Bool

        public init(
            stutterRemoval: Bool = true,
            phraseRepetition: Bool = true,
            explicitCorrections: Bool = true,
            nearDuplicates: Bool = true,
            discourseFiller: Bool = true,
            partialWordComma: Bool = true,
            confidenceScores: [Float]? = nil,
            nearDuplicateThreshold: Double = 0.55,
            aggressiveRestart: Bool? = nil
        ) {
            self.stutterRemoval = stutterRemoval
            self.phraseRepetition = phraseRepetition
            self.explicitCorrections = explicitCorrections
            self.nearDuplicates = nearDuplicates
            self.discourseFiller = discourseFiller
            self.partialWordComma = partialWordComma
            self.confidenceScores = confidenceScores
            self.nearDuplicateThreshold = nearDuplicateThreshold
            // Resolve from @AppStorage if not explicitly provided. Default true.
            if let v = aggressiveRestart {
                self.aggressiveRestart = v
            } else if UserDefaults.standard.object(forKey: "voice.aggressiveRestart") != nil {
                self.aggressiveRestart = UserDefaults.standard.bool(forKey: "voice.aggressiveRestart")
            } else {
                self.aggressiveRestart = true
            }
        }

        public static let `default` = Options()
        public static let off = Options(
            stutterRemoval: false,
            phraseRepetition: false,
            explicitCorrections: false,
            nearDuplicates: false,
            discourseFiller: false,
            partialWordComma: false,
            aggressiveRestart: false
        )

        /// Light-touch configuration for the CLOUD polish path. The cloud
        /// model is large enough to detect frame-restart and near-duplicate
        /// patterns itself given the full input — running our heuristic
        /// passes first only strips signal it could have used and risks
        /// destroying valid parallel phrasing.
        ///
        /// Kept ON:
        ///   - explicitCorrections — high-precision cue matching ("scratch
        ///     that", "no wait", "i mean") with similarity gating. Low
        ///     false-positive rate, and removes content the cloud model
        ///     would also drop, just at lower latency.
        ///   - stutterRemoval — pure ASR artefact ("the the the"), zero
        ///     semantic value.
        ///   - partialWordComma — narrow ASR artefact pattern ("so I'm tr,
        ///     I got"), the cut-off fragment is never meaningful.
        ///
        /// Turned OFF (cloud model handles natively):
        ///   - phraseRepetition — heuristic-heavy, can collapse intentional
        ///     parallel phrasing.
        ///   - nearDuplicates — adjacent-clause heuristic, false-positive
        ///     prone on lists / parallel constructions.
        ///   - discourseFiller — strips "like" in patterns where the cloud
        ///     model could decide context.
        ///   - aggressiveRestart — disables the `frameSimilarityPass` and
        ///     `noCueFrameRestartPass` entirely (they're gated on this).
        public static let cloudLight = Options(
            stutterRemoval: true,
            phraseRepetition: false,
            explicitCorrections: true,
            nearDuplicates: false,
            discourseFiller: false,
            partialWordComma: true,
            aggressiveRestart: false
        )

        /// Hard-bypass for the raw cloud path. Identical structurally to
        /// `.off`, but named to make the intent obvious at the call site:
        /// "do not touch the text — the cloud model is the editor." When
        /// passed, `process()` short-circuits and returns the input
        /// unchanged with no applied rules.
        public static let skip = Options(
            stutterRemoval: false,
            phraseRepetition: false,
            explicitCorrections: false,
            nearDuplicates: false,
            discourseFiller: false,
            partialWordComma: false,
            aggressiveRestart: false
        )
    }

    public struct Result: Sendable {
        public var cleaned: String
        public var droppedSpans: [DroppedSpan]
        public var appliedRules: [String]
    }

    public struct DroppedSpan: Sendable {
        public var reason: String
        public var dropped: String
        public var keptInstead: String
    }

    /// Run the four passes over `text` and return the cleaned output
    /// along with a log of what was dropped (for debugging / telemetry).
    public static func process(_ text: String, options: Options = .default) -> Result {
        var current = text
        var dropped: [DroppedSpan] = []
        var rules: [String] = []

        if options.stutterRemoval {
            let r = stutterPass(current)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("stutter-removal")
            }
            current = r.cleaned
        }

        if options.phraseRepetition {
            let r = phraseRepetitionPass(current)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("phrase-repetition")
            }
            current = r.cleaned
        }

        if options.partialWordComma {
            let r = partialWordCommaPass(current)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("partial-word-comma")
            }
            current = r.cleaned
        }

        if options.explicitCorrections {
            let r = explicitCorrectionPass(current)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("explicit-correction")
            }
            current = r.cleaned
        }

        if options.nearDuplicates {
            let r = nearDuplicatePass(current, threshold: options.nearDuplicateThreshold, confidence: options.confidenceScores)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("near-duplicate")
            }
            current = r.cleaned

            // Frame-similarity restart pass — catches "I went to the store /
            // I went to the market" style corrections that share the entire
            // frame except the final content word. Gated by aggressiveRestart
            // because it can false-positive on intentional parallel phrasing.
            if options.aggressiveRestart {
                let fs = frameSimilarityPass(current)
                if fs.cleaned != current {
                    dropped.append(contentsOf: fs.dropped)
                    rules.append("frame-similarity")
                }
                current = fs.cleaned

                // No-cue frame restart — looser variant for cases where the
                // speaker restarts with a different inner noun phrase and a
                // different token count ("I want pepperoni pizza / I want
                // hawaiian pizza tonight" -> drops first).
                let nf = noCueFrameRestartPass(current)
                if nf.cleaned != current {
                    dropped.append(contentsOf: nf.dropped)
                    rules.append("no-cue-frame-restart")
                }
                current = nf.cleaned
            }
        }

        if options.discourseFiller {
            let r = discourseFillerPass(current)
            if r.cleaned != current {
                dropped.append(contentsOf: r.dropped)
                rules.append("discourse-filler")
            }
            current = r.cleaned
        }

        // Always run punctuation cleanup if any pass mutated the text.
        if !rules.isEmpty {
            current = punctuationCleanup(current)
        }

        return Result(cleaned: current, droppedSpans: dropped, appliedRules: rules)
    }

    // MARK: - Pass 1: Stutter removal
    //
    // Two sub-cases:
    //   (a) Whole-word repetition of short function words:
    //         "the the the cat" -> "the cat"
    //         "I I I went"      -> "I went"
    //       Limited to a closed list (the, a, an, I, that, this, it, is, was,
    //       and, but, or, so, to, of, in, on, at) to avoid breaking emphatic
    //       repetition that carries meaning ("no, no, no").
    //
    //   (b) Partial-word stutter where 1-2 letters of a word leak as a
    //       separate token immediately before the full word:
    //         "ke keep falling"  -> "keep falling"
    //         "ja just leave"    -> "just leave"
    //       Trigger: 1-2 lowercase letters, then whitespace, then a word
    //       that starts with the same letters AND is >= 3 chars total.

    static func stutterPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        var dropped: [DroppedSpan] = []
        var result = text

        // Sub-case (a): whole-word function-word stutter.
        let stutterableWords = Set([
            "the", "a", "an", "i", "that", "this", "it",
            "is", "was", "are", "am",
            "and", "but", "or", "so",
            "to", "of", "in", "on", "at",
            "we", "you", "they", "he", "she",
            "do", "did", "does"
        ])

        // Match (word)(\s+word)+ where word is in stutterable list.
        let wordPattern = #"\b([A-Za-z]+)(\s+\1)+\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern, options: [.caseInsensitive]) {
            let ns = result as NSString
            var collapsed = result
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            // Process in reverse so ranges stay valid.
            for m in matches.reversed() {
                let full = ns.substring(with: m.range)
                let firstWord = ns.substring(with: m.range(at: 1))
                if stutterableWords.contains(firstWord.lowercased()) {
                    dropped.append(DroppedSpan(
                        reason: "stutter-whole-word",
                        dropped: full,
                        keptInstead: firstWord
                    ))
                    let nsCollapsed = collapsed as NSString
                    if m.range.location + m.range.length <= nsCollapsed.length {
                        collapsed = nsCollapsed.replacingCharacters(in: m.range, with: firstWord)
                    }
                }
            }
            result = collapsed
        }

        // Sub-case (b): partial-letter prefix stutter.
        //   ke keep -> keep
        //   ja just -> just
        // Pattern: lowercase 1-2 letters, whitespace, lowercase word starting
        // with those same letters and >= 3 chars total.
        // We require lowercase to avoid wiping "ME members" -> "members".
        let partialPattern = #"\b([a-z]{1,2})\s+([a-z]{3,})\b"#
        if let regex = try? NSRegularExpression(pattern: partialPattern, options: []) {
            let ns = result as NSString
            var collapsed = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let prefix = ns.substring(with: m.range(at: 1))
                let fullWord = ns.substring(with: m.range(at: 2))
                guard fullWord.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                // Skip if the prefix is itself a real English short word that
                // could be meaningful here ("to keep", "be back", "in case",
                // "if it", "is at", "on it", "by us", "of us", "we ate").
                let realShortWords: Set<String> = [
                    "to", "be", "in", "if", "is", "on", "by", "of", "we",
                    "do", "go", "no", "so", "or", "up", "am", "an", "as", "at",
                    "he", "it", "me", "my", "us", "im", "ok"
                ]
                if realShortWords.contains(prefix.lowercased()) { continue }
                let dropSpan = ns.substring(with: m.range)
                dropped.append(DroppedSpan(
                    reason: "stutter-letter-prefix",
                    dropped: dropSpan,
                    keptInstead: fullWord
                ))
                collapsed = collapsed.replacingCharacters(in: m.range, with: fullWord) as NSString
            }
            result = collapsed as String
        }

        return (result, dropped)
    }

    // MARK: - Pass 1b: Phrase-level adjacent repetition
    //
    // Catches WITHIN-clause phrase repetition that the near-duplicate pass
    // (which works at clause granularity) cannot see. Example:
    //   "I do notice with the skin with the niche skin there's clipping"
    //     -> "I do notice with the niche skin there's clipping"
    //
    // Algorithm:
    //   - Tokenize on whitespace, preserving each token's punctuation.
    //   - For each position i, try window sizes N from 2..5. The candidate
    //     repetition spans tokens[i..<i+N] and tokens[i+N..<i+2N].
    //   - The pair must NOT cross a clause boundary (`.,;?!` token contains
    //     one of these characters anywhere -> abort that window).
    //   - Pair is "matching" when:
    //       (a) exact token match for short windows (N == 2), OR
    //       (b) trigram-or-unigram overlap >= 0.80 for N >= 3, OR
    //       (c) both windows begin with the same preposition (with/from/to/
    //           on/at/in/for/by/about) AND the overlap of the remaining
    //           tokens is high (>= 0.5) — the speaker's restart with an
    //           added qualifier. In that case we keep the LONGER side.
    //   - Default kept side: the SECOND window (the speaker's final attempt).
    //   - Min window 2, max 5. To avoid emphatic-adjective stutter ("very
    //     very important"), N == 2 exact-match requires at least one CONTENT
    //     word in the window — function-word-only windows are skipped.
    //
    // Conservative: only fires on adjacent windows (zero intervening tokens).
    // Single-token repetition is left to the stutter pass.

    private static let prepositionRestartSet: Set<String> = [
        "with", "from", "to", "on", "at", "in", "for", "by", "about"
    ]

    private static let phraseRepFunctionWords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "at", "for", "by",
        "with", "from", "and", "or", "but", "so", "as", "is", "was",
        "are", "be", "this", "that", "it", "i", "you", "we", "they",
        "he", "she", "very", "really", "quite", "just", "also"
    ]

    static func phraseRepetitionPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        // Tokenize on whitespace, preserving punctuation glued to tokens.
        // Track each token's character range so we can rebuild precisely.
        struct Tok { let raw: String; let start: Int; let end: Int }
        let chars = Array(text)
        var toks: [Tok] = []
        var i = 0
        while i < chars.count {
            // Skip whitespace
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            let s = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            toks.append(Tok(raw: String(chars[s..<i]), start: s, end: i))
        }
        guard toks.count >= 4 else { return (text, []) }

        // Helper: does a token contain a clause boundary char?
        func hasBoundary(_ t: Tok) -> Bool {
            for c in t.raw where ".,;?!".contains(c) { return true }
            return false
        }
        // Helper: strip surrounding punctuation, lowercase.
        func norm(_ s: String) -> String {
            let strip = CharacterSet.punctuationCharacters
            return s.lowercased().trimmingCharacters(in: strip)
        }
        func normWindow(_ range: Range<Int>) -> [String] {
            return toks[range].map { norm($0.raw) }.filter { !$0.isEmpty }
        }
        func windowHasContentWord(_ words: [String]) -> Bool {
            for w in words where !phraseRepFunctionWords.contains(w) && w.count >= 2 {
                return true
            }
            return false
        }
        func unigramJaccard(_ a: [String], _ b: [String]) -> Double {
            let sa = Set(a), sb = Set(b)
            if sa.isEmpty || sb.isEmpty { return 0 }
            return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        }

        // Build a "skip" array; we drop the FIRST window's tokens by default.
        var skip = Array(repeating: false, count: toks.count)
        var dropped: [DroppedSpan] = []
        var idx = 0
        while idx < toks.count {
            if skip[idx] { idx += 1; continue }
            var matched = false

            // Asymmetric case: shorter-then-longer restart with shared head
            // token and the shorter window's content tokens are a subset
            // of the longer window's. Example:
            //   "the apple the red apple" — short="the apple", long="the red apple"
            //   speaker abandons the short form for the qualified long form.
            // Try Na in 2..4 immediately followed by Nb in (Na+1)..min(Na+3, 5).
            for Na in 2...4 {
                if matched { break }
                let nbMax = min(Na + 3, 5)
                for Nb in (Na + 1)...nbMax {
                    if idx + Na + Nb > toks.count { continue }
                    var boundaryHit = false
                    for k in 0..<(Na + Nb) {
                        if hasBoundary(toks[idx + k]) { boundaryHit = true; break }
                    }
                    if boundaryHit { continue }
                    let aRange = idx..<(idx + Na)
                    let bRange = (idx + Na)..<(idx + Na + Nb)
                    let aWords = normWindow(aRange)
                    let bWords = normWindow(bRange)
                    if aWords.count != Na || bWords.count != Nb { continue }
                    // Heads must match.
                    guard aWords.first == bWords.first else { continue }
                    // Every non-head token in aWords must appear somewhere in bWords.
                    let aSet = Set(aWords)
                    let bSet = Set(bWords)
                    if !aSet.isSubset(of: bSet) { continue }
                    // The longer window must add at least one CONTENT token
                    // (a non-function word not already in aWords).
                    let bExtra = bSet.subtracting(aSet)
                    let hasContentAddition = bExtra.contains(where: { !phraseRepFunctionWords.contains($0) && $0.count >= 2 })
                    guard hasContentAddition else { continue }
                    // Drop the shorter (abandoned) window.
                    for k in aRange { skip[k] = true }
                    dropped.append(DroppedSpan(
                        reason: "phrase-repetition-asym",
                        dropped: toks[aRange].map { $0.raw }.joined(separator: " "),
                        keptInstead: toks[bRange].map { $0.raw }.joined(separator: " ")
                    ))
                    idx += Na + Nb
                    matched = true
                    break
                }
            }
            if matched { continue }

            // Prefer LARGER N first so "with the skin with the niche skin" (N=3)
            // matches as a whole rather than reducing to N=2.
            for N in stride(from: 5, through: 2, by: -1) {
                if idx + 2 * N > toks.count { continue }
                // No clause boundary inside either window (last token of either
                // window may carry a boundary — that means the window straddles
                // a clause boundary).
                var boundaryHit = false
                for k in 0..<(2 * N) {
                    if hasBoundary(toks[idx + k]) { boundaryHit = true; break }
                }
                if boundaryHit { continue }

                let aRange = idx..<(idx + N)
                let bRange = (idx + N)..<(idx + 2 * N)
                let aWords = normWindow(aRange)
                let bWords = normWindow(bRange)
                if aWords.count != N || bWords.count != N { continue }

                // Special case: preposition-led restart with optional qualifier.
                if let aHead = aWords.first, let bHead = bWords.first,
                   aHead == bHead, prepositionRestartSet.contains(aHead) {
                    let aRest = Array(aWords.dropFirst())
                    let bRest = Array(bWords.dropFirst())
                    let restOverlap = unigramJaccard(aRest, bRest)
                    if restOverlap >= 0.5 {
                        // Keep the side with MORE distinct content words.
                        let aContent = aRest.filter { !phraseRepFunctionWords.contains($0) }.count
                        let bContent = bRest.filter { !phraseRepFunctionWords.contains($0) }.count
                        let dropFirst = bContent >= aContent
                        let dropRange = dropFirst ? aRange : bRange
                        let keepRange = dropFirst ? bRange : aRange
                        for k in dropRange { skip[k] = true }
                        dropped.append(DroppedSpan(
                            reason: "phrase-repetition-prep",
                            dropped: toks[dropRange].map { $0.raw }.joined(separator: " "),
                            keptInstead: toks[keepRange].map { $0.raw }.joined(separator: " ")
                        ))
                        idx += 2 * N
                        matched = true
                        break
                    }
                }

                // Exact match path.
                if aWords == bWords {
                    // For N==2, require at least one content word to avoid
                    // collapsing emphatic stutter like "very very important".
                    // (For N>=3 the constraint is weaker since 3+ token exact
                    // repetition is overwhelmingly restart, not emphasis.)
                    if N == 2, !windowHasContentWord(aWords) {
                        continue
                    }
                    for k in aRange { skip[k] = true }
                    dropped.append(DroppedSpan(
                        reason: "phrase-repetition-exact",
                        dropped: toks[aRange].map { $0.raw }.joined(separator: " "),
                        keptInstead: toks[bRange].map { $0.raw }.joined(separator: " ")
                    ))
                    idx += 2 * N
                    matched = true
                    break
                }

                // Near match (N >= 3): unigram overlap >= 0.80.
                if N >= 3 {
                    let overlap = unigramJaccard(aWords, bWords)
                    if overlap >= 0.80 {
                        for k in aRange { skip[k] = true }
                        dropped.append(DroppedSpan(
                            reason: "phrase-repetition-near",
                            dropped: toks[aRange].map { $0.raw }.joined(separator: " "),
                            keptInstead: toks[bRange].map { $0.raw }.joined(separator: " ")
                        ))
                        idx += 2 * N
                        matched = true
                        break
                    }
                }
            }
            if !matched { idx += 1 }
        }

        if dropped.isEmpty { return (text, []) }

        // Rebuild text preserving the original whitespace between surviving
        // tokens. Simplest correct approach: join surviving tokens by single
        // space; punctuation cleanup pass will fix doubled spaces.
        let kept = toks.enumerated().compactMap { skip[$0.offset] ? nil : $0.element.raw }
        return (kept.joined(separator: " "), dropped)
    }

    // MARK: - Pass 2: Explicit correction markers
    //
    // Patterns we recognize as the speaker explicitly correcting themselves:
    //   "X. No wait Y"      -> Y (when Y is a rephrase of X)
    //   "X. Actually Y"     -> Y (when Y is a rephrase of X)
    //   "X, I mean Y"       -> Y
    //   "X. Scratch that Y" -> Y
    //
    // The correction marker is the trigger; we then look BACK to find the
    // abandoned attempt. The abandoned attempt is the most recent sentence
    // or clause (whichever is shorter) before the marker.
    //
    // Conservative: we only drop the prior clause if it is detectably similar
    // (>= 40% token overlap) to what follows the marker. This protects
    // legitimate uses like "she said no, wait until tomorrow."

    static func explicitCorrectionPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        // Markers must be standalone (word-boundary on both sides). We allow
        // optional leading punctuation/whitespace.
        // Expanded cue list. Each entry is a regex matching a self-correction
        // marker. Includes common ASR misfires:
        //   - "scratch out" — Whisper sometimes hears "scratch that" as
        //     "scratch out".
        //   - "no way" — Whisper sometimes hears "no wait" as "no way".
        //     This will produce some false positives on emphatic "no way!"
        //     but the similarity gate below (≥0.20 stemmed overlap with the
        //     replacement clause) suppresses most of them.
        let markers: [String] = [
            #"\bno\s+wait\b"#,
            #"\bno\s+way\b"#,                // ASR misfire of "no wait"
            #"\bwait\s+no\b"#,
            #"\bwait\s+actually\b"#,
            #"\bactually\s+no\b"#,
            #"\bactually\s+wait\b"#,
            #"\bno\s+actually\b"#,
            #"\bscratch\s+that\b"#,
            #"\bscratch\s+out\b"#,           // ASR misfire of "scratch that"
            #"\bscratch\s+all\s+that\b"#,
            #"\bignore\s+that\b"#,
            #"\bignore\s+all\s+that\b"#,
            #"\bdelete\s+that\b"#,
            #"\bnever\s*mind\b"#,
            #"\bforget\s+(?:that|it)\b"#,
            #"\blet\s+me\s+start\s+over\b"#,
            #"\bi\s+meant\b"#,
            #"\bi\s+mean\b"#,
            #"\bor\s+rather\b"#,
            #"\blet\s+me\s+rephrase\b"#
        ]

        var working = text
        var dropped: [DroppedSpan] = []

        for markerPattern in markers {
            guard let rx = try? NSRegularExpression(pattern: markerPattern, options: [.caseInsensitive]) else { continue }
            var loops = 0
            while loops < 12 {
                loops += 1
                let ns = working as NSString
                let range = NSRange(location: 0, length: ns.length)
                guard let match = rx.firstMatch(in: working, options: [], range: range) else { break }

                let markerStart = match.range.location
                let markerEnd = match.range.location + match.range.length

                // Find the abandoned clause: walk backward to find the previous
                // clause boundary (. ? ! \n or start of string). If no boundary
                // found within 20 words, give up — too risky.
                let priorTextRange = NSRange(location: 0, length: markerStart)
                let priorText = ns.substring(with: priorTextRange)
                guard let initialAbandonedStart = findClauseStart(in: priorText) else { break }

                // The "replacement" is the next clause after the marker.
                let afterMarker = ns.substring(with: NSRange(location: markerEnd, length: ns.length - markerEnd))
                let replacement = firstClause(of: afterMarker)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Tighten the abandoned span: find the shortest suffix of
                // priorText[initialAbandonedStart...] whose stemmed-overlap
                // with `replacement` peaks. This protects against gobbling up
                // a legitimate prefix when the speaker corrects only the tail
                // of a sentence (e.g. "send a message to alice saying I'll be
                // there at three. Scratch out I'll be there at four." — we
                // want to drop only "I'll be there at three", not the whole
                // sentence).
                let abandonedStart = tightenAbandonedStart(
                    priorText: priorText,
                    initialStart: initialAbandonedStart,
                    replacement: replacement
                )

                // Extract the abandoned attempt for the similarity check.
                let abandoned = (priorText as NSString)
                    .substring(with: NSRange(location: abandonedStart, length: priorText.count - abandonedStart))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Similarity gate — without similarity we cannot tell whether
                // this is a real correction or legitimate "I mean..." prose.
                // Use STEMMED tokens so "cardons"/"cardon" and "loaded"/"loading"
                // count as matches. Threshold is intentionally low (0.20) for
                // explicit markers — the marker itself is strong evidence that
                // a correction is happening; we just need any structural
                // similarity to confirm the speaker is restating the same idea.
                let sim = stemmedPhraseOverlap(abandoned, replacement)
                guard sim >= 0.20 else { break } // not a real correction here

                // Drop range = [abandonedStart in priorText, markerEnd in full text].
                let absoluteDropStart = abandonedStart
                let absoluteDropEnd = markerEnd
                let dropLen = absoluteDropEnd - absoluteDropStart
                guard dropLen > 0, dropLen <= ns.length else { break }

                let droppedText = ns.substring(with: NSRange(location: absoluteDropStart, length: dropLen))
                dropped.append(DroppedSpan(
                    reason: "explicit-correction",
                    dropped: droppedText,
                    keptInstead: replacement
                ))
                print("[VOICE-RESTART] explicit-cue matched pattern=\(markerPattern) dropped=\"\(droppedText)\" kept=\"\(replacement)\" sim=\(String(format: "%.2f", sim))")
                working = ns.replacingCharacters(in: NSRange(location: absoluteDropStart, length: dropLen), with: "")
                // Loop continues — there may be more correction markers further in.
            }
        }

        return (working, dropped)
    }

    /// Walk backward from end of `prior` to find the previous clause start.
    /// Returns the offset (in `prior`) where the abandoned clause begins.
    /// Boundary characters: `.`, `?`, `!`, `\n`. Returns 0 if no boundary
    /// found AND prior has fewer than 25 words; returns nil otherwise
    /// (too risky to drop without a known boundary).
    static func findClauseStart(in prior: String) -> Int? {
        let chars = Array(prior)
        var i = chars.count - 1
        // Skip trailing whitespace/punctuation that's clearly attached to the marker.
        while i >= 0, chars[i] == " " || chars[i] == "," || chars[i] == "\t" {
            i -= 1
        }
        var lastBoundary: Int? = nil
        while i >= 0 {
            let c = chars[i]
            if c == "." || c == "?" || c == "!" || c == "\n" {
                // boundary at i; the clause starts at i+1 after skipping whitespace.
                var start = i + 1
                while start < chars.count, chars[start] == " " || chars[start] == "\t" {
                    start += 1
                }
                lastBoundary = start
                break
            }
            i -= 1
        }
        if let lb = lastBoundary { return lb }
        // No boundary found — only safe if prior is short (< 25 words).
        let wordCount = prior.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 25 { return 0 }
        return nil
    }

    /// Given the abandoned-clause start chosen by `findClauseStart`, try to
    /// tighten it so we only drop the tokens that actually overlap with the
    /// replacement clause. Walks the candidate start forward by token,
    /// computing stemmed overlap with `replacement` at each step, and picks
    /// the shortest suffix whose overlap is within 90% of the maximum.
    /// Returns the new start offset (always >= initialStart).
    static func tightenAbandonedStart(
        priorText: String,
        initialStart: Int,
        replacement: String
    ) -> Int {
        guard !replacement.isEmpty else { return initialStart }
        let chars = Array(priorText)
        guard initialStart < chars.count else { return initialStart }

        // Compute token boundaries (character offsets where a token starts)
        // within the candidate abandoned span.
        var tokenStarts: [Int] = []
        var inToken = false
        for k in initialStart..<chars.count {
            if chars[k].isWhitespace {
                inToken = false
            } else {
                if !inToken { tokenStarts.append(k); inToken = true }
            }
        }
        guard tokenStarts.count > 1 else { return initialStart }

        // Try each candidate start, find the one that maximizes overlap.
        // Prefer shorter spans on ties (tighter is safer).
        var best: (start: Int, sim: Double) = (initialStart, -1.0)
        for start in tokenStarts {
            let span = String(chars[start..<chars.count])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if span.isEmpty { continue }
            let sim = stemmedPhraseOverlap(span, replacement)
            // Prefer shorter spans within 0.05 of the best score so far.
            if sim > best.sim + 0.001 {
                best = (start, sim)
            } else if abs(sim - best.sim) <= 0.05 && start > best.start {
                // Same-quality but shorter: prefer it.
                best = (start, sim)
            }
        }
        // Only accept the tightened start if it improves the score over the
        // initial one by a meaningful margin; otherwise fall back.
        let initialSpan = String(chars[initialStart..<chars.count])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialSim = stemmedPhraseOverlap(initialSpan, replacement)
        if best.sim >= initialSim {
            return best.start
        }
        return initialStart
    }

    /// Take the first clause of `text` up to the next `. ? ! , \n` boundary
    /// (or full text if none). Used for similarity comparison.
    static func firstClause(of text: String) -> String {
        if let idx = text.firstIndex(where: { ".?!\n,".contains($0) }) {
            return String(text[..<idx])
        }
        return text
    }

    // MARK: - Pass 3: Near-duplicate clause detection
    //
    // Long-distance restarts where the speaker rephrased without an explicit
    // correction marker. Algorithm:
    //   1. Split text into "clause units" using sentence-end punctuation.
    //   2. For each adjacent pair of clauses, compute token-3gram overlap.
    //   3. If overlap >= threshold AND clauses are within 12 words of each
    //      other, drop the FIRST clause (the abandoned attempt).
    //   4. If confidence scores are supplied, also weight by avg confidence:
    //      the clause with lower confidence is more likely the abandoned one.

    static func nearDuplicatePass(
        _ text: String,
        threshold: Double,
        confidence: [Float]?
    ) -> (cleaned: String, dropped: [DroppedSpan]) {
        // Split into (clause text, start offset, end offset) tuples.
        let clauses = splitIntoClauses(text)
        guard clauses.count >= 2 else { return (text, []) }

        var keepFlags = Array(repeating: true, count: clauses.count)
        var dropped: [DroppedSpan] = []

        // Compare each clause with the NEXT clause only (restarts are local).
        for i in 0..<(clauses.count - 1) {
            guard keepFlags[i] else { continue }
            let a = clauses[i].text
            let b = clauses[i + 1].text
            // Skip very short clauses (< 3 words) — too noisy.
            let aWords = a.split(whereSeparator: { $0.isWhitespace })
            let bWords = b.split(whereSeparator: { $0.isWhitespace })
            guard aWords.count >= 3, bWords.count >= 3 else { continue }
            // Limit by gap: clauses within 20 words of each other.
            guard aWords.count + bWords.count <= 50 else { continue }

            let sim = trigramOverlap(a, b)
            guard sim >= threshold else { continue }

            // Decide which to drop. Default: drop the first (older attempt).
            // If confidence is available, drop whichever clause has lower
            // average confidence over its token range.
            var dropFirst = true
            if let conf = confidence {
                let avgA = avgConfidence(in: clauses[i], fullText: text, confidence: conf)
                let avgB = avgConfidence(in: clauses[i + 1], fullText: text, confidence: conf)
                if let a = avgA, let b = avgB, a > b + 0.05 {
                    dropFirst = false // first clause has higher confidence — drop second
                }
            }

            if dropFirst {
                keepFlags[i] = false
                dropped.append(DroppedSpan(
                    reason: "near-duplicate-first",
                    dropped: a,
                    keptInstead: b
                ))
            } else {
                keepFlags[i + 1] = false
                dropped.append(DroppedSpan(
                    reason: "near-duplicate-second",
                    dropped: b,
                    keptInstead: a
                ))
            }
        }

        // Rebuild text from kept clauses.
        let kept = zip(clauses, keepFlags).compactMap { $1 ? $0.text : nil }
        let rebuilt = kept.joined(separator: " ")
        return (rebuilt, dropped)
    }

    // MARK: - Pass 3b: Frame-similarity restart detection
    //
    // Catches adjacent clauses that share the entire frame except the final
    // content word ("I went to the store" / "I went to the market"). When
    // the prefix matches and only the tail content word differs, the second
    // clause is treated as the speaker's correction and the first is dropped.
    //
    //   - Adjacent clauses only, within a 6-token gap.
    //   - Both clauses must have the same token count (frame match).
    //   - Every token except the final content word must match (case-insens).
    //   - Skip if either clause ends with a question word or starts with an
    //     imperative-style verb — those are likely intentional, not restarts.

    private static let frameSimilarityQuestionWords: Set<String> = [
        "what", "where", "when", "why", "how", "who", "which", "whose"
    ]
    private static let frameSimilarityImperativeVerbs: Set<String> = [
        "go", "stop", "wait", "listen", "look", "come", "give", "take",
        "make", "do", "let", "tell", "send", "open", "close", "try",
        "check", "find", "put", "get", "use", "call", "run", "show",
        "please"
    ]

    static func frameSimilarityPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        let clauses = splitIntoClauses(text)
        guard clauses.count >= 2 else { return (text, []) }

        var keepFlags = Array(repeating: true, count: clauses.count)
        var dropped: [DroppedSpan] = []

        for i in 0..<(clauses.count - 1) {
            guard keepFlags[i] else { continue }
            let a = clauses[i].text
            let b = clauses[i + 1].text

            // Tokenize. Keep only alphanumeric word tokens for comparison.
            let aTokens = a.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
            let bTokens = b.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }

            // Frame match requires equal token count, and within a 6-token gap.
            guard aTokens.count == bTokens.count else { continue }
            guard aTokens.count >= 2, aTokens.count <= 6 else { continue }

            // Skip imperative-style openings.
            if let firstA = aTokens.first?.lowercased(),
               frameSimilarityImperativeVerbs.contains(firstA) { continue }
            if let firstB = bTokens.first?.lowercased(),
               frameSimilarityImperativeVerbs.contains(firstB) { continue }

            // Skip if either clause ends with a question word (suggests a real
            // question, not a restart).
            if let lastA = aTokens.last?.lowercased(),
               frameSimilarityQuestionWords.contains(lastA) { continue }
            if let lastB = bTokens.last?.lowercased(),
               frameSimilarityQuestionWords.contains(lastB) { continue }

            // Compare every token except the last. They must all match
            // case-insensitively. The last tokens must DIFFER (otherwise this
            // is a literal repeat, handled elsewhere).
            var framesMatch = true
            for idx in 0..<(aTokens.count - 1) {
                if aTokens[idx].lowercased() != bTokens[idx].lowercased() {
                    framesMatch = false
                    break
                }
            }
            guard framesMatch else { continue }
            guard aTokens.last?.lowercased() != bTokens.last?.lowercased() else { continue }

            // Drop the first clause — the speaker corrected themselves.
            keepFlags[i] = false
            dropped.append(DroppedSpan(
                reason: "frame-similarity",
                dropped: a,
                keptInstead: b
            ))
            print("[VOICE-RESTART] frame-similarity matched dropped=\"\(a)\" kept=\"\(b)\"")
        }

        let kept = zip(clauses, keepFlags).compactMap { $1 ? $0.text : nil }
        let rebuilt = kept.joined(separator: " ")
        return (rebuilt, dropped)
    }

    // MARK: - Pass 3c: No-cue frame restart
    //
    // Catches "I want pepperoni pizza / I want hawaiian pizza tonight" style
    // restarts where the speaker re-uses the same frame ("I want ___ pizza")
    // with a different inner noun phrase, and may extend the second clause.
    // The frameSimilarityPass above requires equal token counts AND identical
    // prefixes — too strict. This looser variant:
    //
    //   - Operates on adjacent clauses (no sentence boundary between them).
    //   - Requires ≥3 of the first 4 tokens to match case-insensitively.
    //   - Requires at least one inner token to differ (otherwise it's a
    //     duplicate, handled by nearDuplicatePass).
    //   - Skips imperative openings and very short clauses (< 3 tokens).
    //   - Logs every decision under [VOICE-RESTART].
    //
    // Drops the FIRST clause (the speaker's abandoned attempt).
    static func noCueFrameRestartPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        // Use a looser splitter that also breaks on commas — the speaker's
        // pause between abandoned and replacement clauses is often only a
        // comma in the ASR transcript. Sentence boundaries (`.?!\n`) are
        // honored as well.
        let clauses = splitOnClauseAndComma(text)
        guard clauses.count >= 2 else { return (text, []) }

        var keepFlags = Array(repeating: true, count: clauses.count)
        var dropped: [DroppedSpan] = []

        for i in 0..<(clauses.count - 1) {
            guard keepFlags[i] else { continue }
            let a = clauses[i].text
            let b = clauses[i + 1].text

            // Reject if there's a hard sentence terminator inside `a` (other
            // than the trailing one). The clause splitter already separates
            // on `.?!\n`, so adjacent clauses ARE sentence-separated. We treat
            // a trailing `.` as a soft boundary here — speakers typically pause
            // mid-restart and ASR inserts a period. Allow it.

            let aTokens = a.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0) }
            let bTokens = b.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0) }

            guard aTokens.count >= 3, bTokens.count >= 3 else { continue }
            // Cap absolute length — long clauses are unlikely to be a true
            // restart and false positives here are costly.
            guard aTokens.count <= 12, bTokens.count <= 14 else { continue }

            // Skip imperative-style openings to avoid wiping legitimate
            // parallel commands ("send a message to alice / send a message
            // to bob" — those are intentional, not restarts).
            if let firstA = aTokens.first?.lowercased(),
               frameSimilarityImperativeVerbs.contains(firstA) { continue }
            if let firstB = bTokens.first?.lowercased(),
               frameSimilarityImperativeVerbs.contains(firstB) { continue }

            // First-4-token overlap. Need ≥3 of the first min(4, len) tokens
            // to match case-insensitively, in order.
            let headLen = min(4, min(aTokens.count, bTokens.count))
            var matches = 0
            for k in 0..<headLen {
                if aTokens[k].lowercased() == bTokens[k].lowercased() {
                    matches += 1
                }
            }
            guard matches >= 3 else { continue }

            // Require that the clauses differ overall — otherwise this is a
            // literal repeat (handled by nearDuplicatePass).
            let aLower = aTokens.map { $0.lowercased() }
            let bLower = bTokens.map { $0.lowercased() }
            guard aLower != bLower else { continue }

            // Require at least one inner token (positions 1..<aTokens.count-1)
            // to differ — protects against pure suffix-extension which is
            // usually a continuation, not a restart.
            // Compare the smallest common inner window.
            let innerLen = min(aTokens.count, bTokens.count) - 1
            var innerDiffers = false
            if innerLen > 1 {
                for k in 1..<innerLen {
                    if aLower[k] != bLower[k] { innerDiffers = true; break }
                }
            }
            guard innerDiffers else { continue }

            keepFlags[i] = false
            dropped.append(DroppedSpan(
                reason: "no-cue-frame-restart",
                dropped: a,
                keptInstead: b
            ))
            print("[VOICE-RESTART] no-cue-frame-restart matched dropped=\"\(a)\" kept=\"\(b)\" headMatches=\(matches)/\(headLen)")
        }

        let kept = zip(clauses, keepFlags).compactMap { $1 ? $0.text : nil }
        let rebuilt = kept.joined(separator: " ")
        return (rebuilt, dropped)
    }

    struct Clause {
        let text: String
        let startOffset: Int
        let endOffset: Int
    }

    /// Like `splitIntoClauses` but also breaks on commas. Used by the no-cue
    /// frame-restart pass — the speaker's pause between abandoned and
    /// replacement clauses is often only a comma in the ASR transcript.
    static func splitOnClauseAndComma(_ text: String) -> [Clause] {
        var clauses: [Clause] = []
        var current = ""
        var startOffset = 0
        var i = 0
        let chars = Array(text)
        while i < chars.count {
            current.append(chars[i])
            let c = chars[i]
            if c == "." || c == "?" || c == "!" || c == "\n" || c == "," {
                while i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                    i += 1
                    current.append(chars[i])
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    clauses.append(Clause(text: trimmed, startOffset: startOffset, endOffset: i))
                }
                current = ""
                startOffset = i + 1
            }
            i += 1
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            clauses.append(Clause(text: trailing, startOffset: startOffset, endOffset: chars.count - 1))
        }
        return clauses
    }

    static func splitIntoClauses(_ text: String) -> [Clause] {
        // Split on . ? ! and newline boundaries, but keep the clauses with their
        // terminators attached so the reassembled text reads naturally.
        var clauses: [Clause] = []
        var current = ""
        var startOffset = 0
        var i = 0
        let chars = Array(text)
        while i < chars.count {
            current.append(chars[i])
            let c = chars[i]
            if c == "." || c == "?" || c == "!" || c == "\n" {
                // Consume trailing whitespace into this clause.
                while i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                    i += 1
                    current.append(chars[i])
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    clauses.append(Clause(text: trimmed, startOffset: startOffset, endOffset: i))
                }
                current = ""
                startOffset = i + 1
            }
            i += 1
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            clauses.append(Clause(text: trailing, startOffset: startOffset, endOffset: chars.count - 1))
        }
        return clauses
    }

    // MARK: - Similarity scoring

    /// Trigram overlap (Jaccard over word 3-grams).
    static func trigramOverlap(_ a: String, _ b: String) -> Double {
        let aTokens = normalizedTokens(a)
        let bTokens = normalizedTokens(b)
        guard aTokens.count >= 3, bTokens.count >= 3 else {
            return phraseOverlap(a, b) // fall back to unigram for short clauses
        }
        let aGrams = Set(trigrams(aTokens))
        let bGrams = Set(trigrams(bTokens))
        let intersect = aGrams.intersection(bGrams).count
        let union = aGrams.union(bGrams).count
        guard union > 0 else { return 0 }
        return Double(intersect) / Double(union)
    }

    /// Unigram Jaccard for shorter clauses.
    static func phraseOverlap(_ a: String, _ b: String) -> Double {
        let aTokens = Set(normalizedTokens(a))
        let bTokens = Set(normalizedTokens(b))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }
        let intersect = aTokens.intersection(bTokens).count
        let union = aTokens.union(bTokens).count
        guard union > 0 else { return 0 }
        return Double(intersect) / Double(union)
    }

    /// Stemmed unigram Jaccard. Lops common suffixes (-s, -es, -ed, -ing) so
    /// "cardons" and "cardon" / "loaded" and "loading" hash to the same key.
    /// This is intentionally minimal — we are not implementing Porter
    /// stemmer; we just need cheap inflection-tolerance for the explicit
    /// correction similarity check.
    static func stemmedPhraseOverlap(_ a: String, _ b: String) -> Double {
        let aTokens = Set(normalizedTokens(a).map(simpleStem))
        let bTokens = Set(normalizedTokens(b).map(simpleStem))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }
        let intersect = aTokens.intersection(bTokens).count
        let union = aTokens.union(bTokens).count
        guard union > 0 else { return 0 }
        return Double(intersect) / Double(union)
    }

    static func simpleStem(_ s: String) -> String {
        let lower = s.lowercased()
        guard lower.count > 3 else { return lower }
        if lower.hasSuffix("ies") { return String(lower.dropLast(3)) + "y" }
        if lower.hasSuffix("ing") { return String(lower.dropLast(3)) }
        if lower.hasSuffix("ed")  { return String(lower.dropLast(2)) }
        if lower.hasSuffix("es")  { return String(lower.dropLast(2)) }
        if lower.hasSuffix("s") && !lower.hasSuffix("ss") {
            return String(lower.dropLast())
        }
        return lower
    }

    static func normalizedTokens(_ s: String) -> [String] {
        let stripChars = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        return s.lowercased()
            .components(separatedBy: stripChars)
            .filter { !$0.isEmpty }
    }

    static func trigrams(_ tokens: [String]) -> [String] {
        guard tokens.count >= 3 else { return [] }
        var grams: [String] = []
        for i in 0...(tokens.count - 3) {
            grams.append("\(tokens[i]) \(tokens[i + 1]) \(tokens[i + 2])")
        }
        return grams
    }

    static func avgConfidence(in clause: Clause, fullText: String, confidence: [Float]) -> Float? {
        // Map clause offsets to confidence-array indices. We assume the
        // confidence array is indexed by token position; we approximate
        // token position from character offset by counting words in the
        // full text up to the clause's start offset.
        let prefixEndIndex = fullText.index(
            fullText.startIndex,
            offsetBy: min(clause.startOffset, fullText.count)
        )
        let prefixTokens = fullText[..<prefixEndIndex]
            .split(whereSeparator: { $0.isWhitespace }).count
        let clauseTokens = clause.text.split(whereSeparator: { $0.isWhitespace }).count
        let endIdx = min(prefixTokens + clauseTokens, confidence.count)
        let startIdx = min(prefixTokens, endIdx)
        guard endIdx > startIdx else { return nil }
        let slice = confidence[startIdx..<endIdx]
        return slice.reduce(0, +) / Float(slice.count)
    }

    // MARK: - Pass 5: Discourse-marker `like` filler removal
    //
    // Speaker uses `like` as a filler/discourse marker, not as comparison or
    // approximation. We drop `like` ONLY in the safe patterns below. Anything
    // not matching a safe pattern is left alone.
    //
    // Safe patterns:
    //   1. have/has/had/got/need/want + like + a/an/the/some/<num>/that/this/...
    //   2. is/are/was/were/am + like + preposition (for/to/in/on/at/with/by/about)
    //   3. it's/that's/this is + like + preposition
    //   4. pronoun + verbing + like + intensifier (quite/so/really/...)
    //   5. pronoun-contraction + verbing + like + intensifier
    //
    // Hard NO-TOUCH list (legitimate `like`): feel(s|t) like, look(s|ed) like,
    // sound(s|ed) like, something like, thing(s) like.

    static func discourseFillerPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        var dropped: [DroppedSpan] = []
        var result = text

        // Patterns: each captures groups around `like`. We replace the full match
        // with the captured groups joined by a single space (dropping `like`).
        // Each pattern uses (?i) for case-insensitive matching.
        let patterns: [(String, String)] = [
            // 1. have/has/had/got/need/want + like + det/num/demonstrative
            (
                #"(?i)\b(have|has|had|got|need|want)\s+like\s+(a|an|the|some|\d+|that|this|these|those)\b"#,
                "$1 $2"
            ),
            // 2. is/are/was/were/am + like + preposition
            (
                #"(?i)\b(is|are|was|were|am)\s+like\s+(for|to|in|on|at|with|by|about)\b"#,
                "$1 $2"
            ),
            // 3. it's/that's/this is + like + preposition
            (
                #"(?i)\b(it's|that's|this is)\s+like\s+(for|to|in|on|at|with|by|about)\b"#,
                "$1 $2"
            ),
            // 4. pronoun + verb-ing + like + intensifier (kind of / sort of handled)
            (
                #"(?i)\b(I|you|we|they|he|she)\s+(\w+ing)\s+like\s+(quite|so|kind of|sort of|really|pretty|very|super|extremely)\b"#,
                "$1 $2 $3"
            ),
            // 5. pronoun-contraction + verb-ing + like + intensifier
            (
                #"(?i)\b(I'm|you're|we're|they're|he's|she's)\s+(\w+ing)\s+like\s+(quite|so|kind of|sort of|really|pretty|very|super|extremely)\b"#,
                "$1 $2 $3"
            )
        ]

        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            // Record dropped spans (forward order) before mutating.
            for m in matches {
                let span = ns.substring(with: m.range)
                dropped.append(DroppedSpan(
                    reason: "discourse-filler-like",
                    dropped: span,
                    keptInstead: span.replacingOccurrences(
                        of: #"\s+like\s+"#,
                        with: " ",
                        options: [.regularExpression, .caseInsensitive]
                    )
                ))
            }
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: ns.length),
                withTemplate: template
            )
        }

        return (result, dropped)
    }

    // MARK: - Pass 1c: Partial-word stutter with comma cutoff
    //
    // ASR sometimes produces a partial-word fragment cut off by a comma before
    // the speaker restarts the phrase. Examples:
    //   "so I'm tr, I got a whoop"          -> "so I got a whoop"
    //   "let me che, let me check that"     -> "let me check that"
    //   "I want to ge, I want to get coffee" -> "I want to get coffee"
    //
    // Precise heuristic (intentionally narrow to avoid false positives):
    //   Split text by commas. For each adjacent pair (prev, next):
    //   - prev's LAST token must be a 1–3 character word that is NOT in the
    //     common-short-word lookup (i.e. it's a probable cut-off fragment).
    //   - next's FIRST token must be a subject pronoun / contraction
    //     (I, I'm, we, we're, you, you're, they, they're, he, he's, she,
    //      she's, it, let, so).
    //   - Drop prev entirely (it's an abandoned restart attempt).
    // We process by splitting on commas at the top level (no clause re-entry
    // logic) — keep the heuristic dumb and predictable.

    private static let partialWordCommaShortWords: Set<String> = [
        // Top common 1–3 letter English words. If the prior segment's last
        // token is in this set, it is a real word, not a stutter fragment,
        // and we must NOT drop the segment.
        "a", "an", "as", "at", "am", "and",
        "be", "by", "but", "bus", "boy", "buy", "bee", "bed", "big", "bit", "box", "bag",
        "can", "cat", "car", "cup", "cow", "cry",
        "do", "did", "day", "dad", "die", "dog", "dry",
        "eat", "eye", "end", "egg", "ear",
        "for", "far", "few", "fat", "fix", "fly", "fun", "fit",
        "go", "got", "get", "gas", "guy", "gym",
        "he", "hi", "his", "her", "him", "had", "has", "how", "hot", "hat", "hit", "hop", "hug",
        "i", "if", "is", "in", "it", "its", "ill",
        "jam", "job", "joy", "jog",
        "key", "kid",
        "let", "lay", "lie", "low", "leg", "lip", "lot",
        "me", "my", "man", "men", "mom", "mad", "map", "may", "mix",
        "no", "not", "now", "new", "net", "nod", "nor",
        "of", "or", "on", "off", "out", "own", "one", "our", "old",
        "put", "pet", "pen", "pop", "pay", "pie", "pig", "pin", "pot",
        "ran", "red", "row", "rub", "run",
        "so", "saw", "sat", "see", "she", "sit", "sky", "son", "sun", "say", "set", "sad",
        "to", "too", "the", "two", "ten", "top", "try", "toy", "tea",
        "up", "us", "use",
        "van",
        // additional common 3-letter nouns / verbs / adjectives
        "ago", "air", "all", "any", "arm", "art", "ask", "bad", "bar", "bay",
        "bid", "boy", "bra", "bun", "cab", "cap", "cot", "cub", "cue",
        "dim", "dip", "dog", "due", "dye", "ego", "elf", "elm", "era", "fan",
        "fee", "fig", "fin", "fog", "foo", "fox", "fur", "gap", "gem", "gut",
        "ham", "hen", "hop", "hub", "ice", "ink", "inn", "ion", "ivy", "jab",
        "jar", "jaw", "jet", "kit", "lab", "lad", "lap", "law", "led", "lid",
        "log", "mat", "mud", "nap", "nut", "oak", "odd", "off", "oil", "orb",
        "pad", "pal", "paw", "pew", "pit", "pub", "pun", "rag", "rat", "ray",
        "rib", "rid", "rim", "rip", "rod", "roe", "rot", "rug", "rye", "sap",
        "ski", "tag", "tan", "tap", "tax", "tip", "tub", "vat", "veg", "wig",
        "win", "yes",
        "we", "way", "war", "win", "was", "wet", "who", "why", "wow",
        "yes", "yet", "you", "yep",
        // contractions
        "im", "id", "ya"
    ]

    private static let partialWordCommaSubjectStarters: Set<String> = [
        "i", "i'm", "we", "we're", "you", "you're", "they", "they're",
        "he", "he's", "she", "she's", "it", "let", "so"
    ]

    static func partialWordCommaPass(_ text: String) -> (cleaned: String, dropped: [DroppedSpan]) {
        // Split on commas while preserving them — but we only need segment text.
        var segments = text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard segments.count >= 2 else { return (text, []) }

        var keep = Array(repeating: true, count: segments.count)
        var dropped: [DroppedSpan] = []

        for i in 0..<(segments.count - 1) {
            let prev = segments[i]
            let next = segments[i + 1]
            // Tokenize.
            let prevTokens = prev.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let nextTokens = next.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let prevLastRaw = prevTokens.last,
                  let nextFirstRaw = nextTokens.first else { continue }
            let prevLast = prevLastRaw
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            let nextFirst = nextFirstRaw
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            // Fragment check: 1–3 chars, all letters/apostrophe, NOT a real word.
            guard prevLast.count >= 1, prevLast.count <= 3 else { continue }
            guard prevLast.allSatisfy({ $0.isLetter || $0 == "'" }) else { continue }
            if partialWordCommaShortWords.contains(prevLast) { continue }
            // Restart anchor: next segment begins with subject pronoun / starter.
            guard partialWordCommaSubjectStarters.contains(nextFirst) else { continue }
            // Preserve a leading discourse opener (so/well/okay/actually/...)
            // if prev has more than 2 tokens — these stand outside the restart.
            let discourseOpeners: Set<String> = ["so", "well", "okay", "ok", "actually", "anyway", "alright", "right"]
            let prevFirstNorm = prevTokens.first!
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if prevTokens.count > 2, discourseOpeners.contains(prevFirstNorm) {
                segments[i] = prevTokens[0]
                dropped.append(DroppedSpan(
                    reason: "partial-word-comma",
                    dropped: prevTokens.dropFirst().joined(separator: " "),
                    keptInstead: prevTokens[0]
                ))
                // We don't fully drop the segment; we shrink it. Glue it onto
                // next by joining with a space instead of ", ".
                segments[i + 1] = "\(prevTokens[0]) \(next)"
                keep[i] = false
            } else {
                // Drop prev entirely.
                keep[i] = false
                dropped.append(DroppedSpan(
                    reason: "partial-word-comma",
                    dropped: prev,
                    keptInstead: next
                ))
            }
        }

        if dropped.isEmpty { return (text, []) }

        // Rebuild: join kept segments with ", " preserving original separator.
        let rebuilt = segments.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
            .joined(separator: ", ")
        return (rebuilt, dropped)
    }

    // MARK: - Pass 4: Punctuation cleanup

    static func punctuationCleanup(_ text: String) -> String {
        var s = text

        // Collapse repeated terminators.
        s = s.replacingOccurrences(of: ".. ", with: ". ")
        s = s.replacingOccurrences(of: " . ", with: ". ")
        s = s.replacingOccurrences(of: " , ", with: ", ")
        s = s.replacingOccurrences(of: ",,", with: ",")
        // ", ." -> "."
        if let regex = try? NSRegularExpression(pattern: #",\s*\."#) {
            let r = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: ".")
        }
        // ". ." -> "."
        if let regex = try? NSRegularExpression(pattern: #"\.\s+\."#) {
            let r = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: ".")
        }
        // Multiple spaces -> single.
        if let regex = try? NSRegularExpression(pattern: #" {2,}"#) {
            let r = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: " ")
        }
        // Trim leading whitespace on each line.
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
