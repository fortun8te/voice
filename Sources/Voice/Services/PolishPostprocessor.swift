// PolishPostprocessor.swift
// ============================================================
// Deterministic post-pass that runs after the LLM polish.
//
// Purpose:
//   The LLM applies rules inconsistently on long inputs (capitalization
//   drops on some sentences but not others, compound words occasionally
//   stay unhyphenated, etc.). This module enforces the rules that don't
//   require semantic understanding so the LLM doesn't have to.
//
// Five passes (each independent, each toggleable):
//   1. Sentence-start capitalization     — ". so we did" -> ". So we did"
//   2. Random mid-clause caps reducer    — "the Back option" -> "the back option"
//                                          (preserves proper nouns + acronyms)
//   3. Compound-word reformer            — "paraben free" -> "paraben-free"
//   4. Trailing-cutoff period killer     — "we have like." -> "we have like"
//   5. Whitespace normalization          — collapse doubles, strip trailing
//
// Conservative principle (same as the pre-processor):
//   False negatives are better than false positives. A skipped cap fix
//   beats a corrupted proper noun. The compound-word list is curated, not
//   inferred. The mid-clause caps reducer only fires on words that are
//   NOT in our proper-noun or acronym lookup.
// ============================================================

import Foundation

public enum PolishPostprocessor {

    /// How aggressively the deterministic list passes are allowed to fire.
    /// Maps directly onto the dictation cleanup level so prose is only
    /// reorganized into lists when the user's chosen level actually wants it.
    ///
    ///   - `.none`        : never produce a list. Verbatim-ish output.
    ///   - `.explicitOnly`: only restructure enumeration the speaker made
    ///                      UNMISTAKABLY explicit ("number one … number two …",
    ///                      "first, … second, …", inline "1. 2. 3."). A rambling
    ///                      monologue stays as prose.
    ///   - `.clear`       : the above PLUS reasonably-clear colon enumerations
    ///                      ("a few things: X, Y, Z, and W" with 4+ short items).
    ///                      Still does NOT force a list out of an ambiguous rant.
    ///   - `.aggressive`  : the above PLUS implicit/non-explicit enumeration in a
    ///                      rambling monologue (cue-phrase comma runs). This is
    ///                      the only mode that turns a rant into a clean list.
    public enum ListFormattingMode: Sendable {
        case none
        case explicitOnly
        case clear
        case aggressive

        /// Map a dictation cleanup level string onto a list mode.
        ///   none   → .none          (never list)
        ///   light  → .explicitOnly  (only unmistakable enumeration)
        ///   medium → .clear         (clear enumeration, incl. colon lists)
        ///   high   → .aggressive    (detect implied enumeration in rants)
        public init(cleanupLevel: String?) {
            switch cleanupLevel?.lowercased() {
            case "none":   self = .none
            case "light":  self = .explicitOnly
            case "high":   self = .aggressive
            default:       self = .clear   // "medium" / nil / unrecognized
            }
        }

        /// Explicit numbered enumeration ("number one…", "first/second/third",
        /// inline "1. 2. 3."). Allowed everywhere except `.none`.
        var allowsExplicitNumbered: Bool { self != .none }

        /// Colon enumeration ("intro: a, b, c, d" with 4+ short items). Clear
        /// but not labeled by the speaker — allowed at `.clear` and above.
        var allowsColonList: Bool { self == .clear || self == .aggressive }

        /// Implicit cue-phrase enumeration (a comma run after "I need", "things
        /// to get", etc.). Can be ambiguous, so only `.aggressive` runs it.
        var allowsImplicitList: Bool { self == .aggressive }
    }

    public struct Options: Sendable {
        public var sentenceStartCaps: Bool
        public var midClauseCapsReducer: Bool
        public var compoundWords: Bool
        public var trailingCutoffPeriod: Bool
        public var whitespace: Bool
        public var standaloneICaps: Bool
        public var brandCaps: Bool
        public var filenameDot: Bool
        public var trailingForeignStrip: Bool
        public var trailingQuestionSanity: Bool
        public var numberSpellout: Bool
        public var unitAbbreviation: Bool
        public var timeFormat: Bool
        public var quarterAbbreviation: Bool
        public var spokenUrlReconstruction: Bool
        /// Convert spoken punctuation/line commands ("period", "comma",
        /// "question mark", "new line", "new paragraph", "slash", …) into the
        /// real symbol/break. This is the DETERMINISTIC safety net that makes
        /// dictated commands work even when the LLM is unavailable, rejected,
        /// or skipped (e.g. the triple-ASR merge path). Mirrors TextFormatter's
        /// voice-command table so the behavior is identical whether or not the
        /// model ran.
        public var spokenPunctuation: Bool
        /// Normalize spacing AROUND punctuation: no space before `.,;:!?`, one
        /// space after sentence punctuation, collapse double spaces, fix
        /// missing space after a comma/period. Runs last so it cleans up any
        /// spacing introduced by earlier passes or by unfreezing entities.
        public var punctuationSpacing: Bool
        /// Extra proper nouns from user vocabulary that should never be
        /// lower-cased by the mid-clause caps pass.
        public var userProperNouns: Set<String>
        /// How aggressively the list passes (numbered / colon / implicit) may
        /// fire. Gated by the dictation cleanup level so lighter levels never
        /// impose list structure on prose. Defaults to `.aggressive` to keep
        /// the historical behavior for any caller that doesn't set it; the
        /// polisher passes the correct mode per cleanup level.
        public var listMode: ListFormattingMode

        public init(
            sentenceStartCaps: Bool = true,
            midClauseCapsReducer: Bool = true,
            compoundWords: Bool = true,
            trailingCutoffPeriod: Bool = true,
            whitespace: Bool = true,
            standaloneICaps: Bool = true,
            brandCaps: Bool = true,
            filenameDot: Bool = true,
            trailingForeignStrip: Bool = true,
            trailingQuestionSanity: Bool = true,
            numberSpellout: Bool = true,
            unitAbbreviation: Bool = true,
            timeFormat: Bool = true,
            quarterAbbreviation: Bool = true,
            spokenUrlReconstruction: Bool = true,
            spokenPunctuation: Bool = true,
            punctuationSpacing: Bool = true,
            userProperNouns: Set<String> = [],
            listMode: ListFormattingMode = .aggressive
        ) {
            self.sentenceStartCaps = sentenceStartCaps
            self.midClauseCapsReducer = midClauseCapsReducer
            self.compoundWords = compoundWords
            self.trailingCutoffPeriod = trailingCutoffPeriod
            self.whitespace = whitespace
            self.standaloneICaps = standaloneICaps
            self.brandCaps = brandCaps
            self.filenameDot = filenameDot
            self.trailingForeignStrip = trailingForeignStrip
            self.trailingQuestionSanity = trailingQuestionSanity
            self.numberSpellout = numberSpellout
            self.unitAbbreviation = unitAbbreviation
            self.timeFormat = timeFormat
            self.quarterAbbreviation = quarterAbbreviation
            self.spokenUrlReconstruction = spokenUrlReconstruction
            self.spokenPunctuation = spokenPunctuation
            self.punctuationSpacing = punctuationSpacing
            self.userProperNouns = userProperNouns
            self.listMode = listMode
        }

        public static let `default` = Options()
        public static let off = Options(
            sentenceStartCaps: false,
            midClauseCapsReducer: false,
            compoundWords: false,
            trailingCutoffPeriod: false,
            whitespace: false,
            standaloneICaps: false,
            brandCaps: false,
            filenameDot: false,
            trailingForeignStrip: false,
            trailingQuestionSanity: false,
            numberSpellout: false,
            unitAbbreviation: false,
            timeFormat: false,
            quarterAbbreviation: false,
            spokenUrlReconstruction: false,
            spokenPunctuation: false,
            punctuationSpacing: false,
            listMode: .none
        )
    }

    public struct Result: Sendable {
        public var cleaned: String
        public var changes: [Change]
    }

    public struct Change: Sendable {
        public var rule: String
        public var before: String
        public var after: String
    }

    /// Validate a polish via the new relaxed-cloud `Sanitizer`, then run the
    /// deterministic post-pass. Returns the polished output on accept, or the
    /// `originalForFallback` (typically the frozen raw input) when the
    /// sanitizer rejects.
    ///
    /// This is the hook the cloud (Cerebras / Groq) branch in Qwen3Polisher
    /// should call instead of skipping straight to `process(_:options:)`.
    /// `Sanitizer.run` honors `UserDefaults.standard.bool(forKey:
    /// "voice.disableSanitizer")` for the emergency override.
    ///
    /// - Parameters:
    ///   - polish: The model output to validate + format.
    ///   - originalForFallback: The pre-polish frozen text. Returned (after
    ///     a post-pass) when sanitizer rejects, so the caller's downstream
    ///     unfreeze + paste path is unchanged.
    ///   - mode: `.relaxed` for cloud, `.strict` for the local 1.7B path.
    ///   - cleanupLevel: forwarded to sanitizer + post-pass list gating.
    ///   - userVocabulary: forwarded for proper-noun safelist + sanitizer.
    public static func validateAndProcess(
        polish: String,
        originalForFallback: String,
        mode: Sanitizer.Mode,
        cleanupLevel: String? = "medium",
        userVocabulary: [String]? = nil
    ) -> Result {
        let userNouns: Set<String> = Set((userVocabulary ?? []).map { $0.lowercased() })
        let options = Options(
            userProperNouns: userNouns,
            listMode: ListFormattingMode(cleanupLevel: cleanupLevel)
        )
        let accepted = Sanitizer.run(
            polish: polish,
            original: originalForFallback,
            mode: mode,
            cleanupLevel: cleanupLevel,
            userVocabulary: userVocabulary
        )
        let textToProcess = accepted ?? originalForFallback
        if accepted == nil {
            print("[VOICE-SANITIZE] FALLBACK → using raw frozen input (mode=\(mode))")
        } else {
            print("[VOICE-SANITIZE] accepted polish (mode=\(mode), \(originalForFallback.count)→\(textToProcess.count) chars)")
        }
        return process(textToProcess, options: options)
    }

    public static func process(_ text: String, options: Options = .default) -> Result {
        var current = text
        var changes: [Change] = []

        // Pass 0: Spoken punctuation / line commands. Runs FIRST so the real
        // symbols and \n / \n\n breaks it produces are visible to every
        // downstream pass (sentence-start caps, lists, spacing). This is the
        // deterministic safety net: dictated commands like "period", "comma",
        // "question mark", "new line", "new paragraph", and "slash" convert
        // here REGARDLESS of whether the LLM ran. The LLM (when it runs) has
        // usually already done this via TextFormatter pre-pass + the system
        // prompt; this pass is idempotent on already-converted text.
        if options.spokenPunctuation {
            let r = spokenPunctuationPass(current)
            recordIfChanged(current, r, rule: "spoken-punctuation", into: &changes)
            current = r
        }

        if options.compoundWords {
            let r = compoundWordPass(current)
            recordIfChanged(current, r, rule: "compound-words", into: &changes)
            current = r
        }

        if options.numberSpellout {
            let r = numberSpelloutPass(current)
            recordIfChanged(current, r, rule: "number-spellout", into: &changes)
            current = r
        }

        if options.unitAbbreviation {
            // Word-form first ("five milliseconds" → "5 ms"), then digit-form
            // mop-up ("5 milliseconds" → "5 ms"). Order matters because the
            // word-form pass produces output the digit-form pass can re-normalize.
            let wf = Self.wordFormUnitPass(current)
            recordIfChanged(current, wf, rule: "word-form-units", into: &changes)
            current = wf

            let r = unitAbbreviationPass(current)
            recordIfChanged(current, r, rule: "unit-abbreviation", into: &changes)
            current = r
        }

        if options.quarterAbbreviation {
            let r = quarterAbbreviationPass(current)
            recordIfChanged(current, r, rule: "quarter-abbreviation", into: &changes)
            current = r
        }

        if options.spokenUrlReconstruction {
            let r = spokenUrlReconstructionPass(current)
            recordIfChanged(current, r, rule: "spoken-url-reconstruction", into: &changes)
            current = r

            // File paths run alongside URL reconstruction — same use case
            // (the user spelled out a structural identifier and we want
            // it stitched back together).
            let fp = Self.spokenFilePathPass(current)
            recordIfChanged(current, fp, rule: "spoken-file-path", into: &changes)
            current = fp
        }

        // Spoken hashtags: "hashtag X" → "#X" (lowercase, no spaces)
        let ht = Self.spokenHashtagPass(current)
        recordIfChanged(current, ht, rule: "spoken-hashtag", into: &changes)
        current = ht

        // Spoken math operators: "5 plus 3" → "5 + 3" (only in clear math contexts)
        let mt = Self.spokenMathOperatorPass(current)
        recordIfChanged(current, mt, rule: "spoken-math", into: &changes)
        current = mt

        // Section sign: "section 3" → "§ 3" — niche, off by default. Skipped.

        // Spoken currency: "200 dollars" → "$200", "five hundred euros" → "€500"
        let cur = Self.spokenCurrencyPass(current)
        recordIfChanged(current, cur, rule: "spoken-currency", into: &changes)
        current = cur

        // Date normalization: "March 15th 2026" → "March 15, 2026"
        let dt = Self.spokenDatePass(current)
        recordIfChanged(current, dt, rule: "spoken-date", into: &changes)
        current = dt

        // Dotfiles: "dot gitignore" → ".gitignore", "dot env local" → ".env.local"
        let df = Self.spokenDotfilePass(current)
        recordIfChanged(current, df, rule: "spoken-dotfile", into: &changes)
        current = df

        // Negative numbers: "negative 5" / "minus 5" → "-5"
        let neg = Self.negativeNumberPass(current)
        recordIfChanged(current, neg, rule: "negative-number", into: &changes)
        current = neg

        // Fractions: "half a cup" → "½ cup", "two thirds" → "2/3"
        let fr = Self.spokenFractionPass(current)
        recordIfChanged(current, fr, rule: "spoken-fraction", into: &changes)
        current = fr

        // Numbered list detection — handles three patterns:
        //   "number one X number two Y number three Z"
        //   "first X second Y third Z"
        //   "1. X 2. Y 3. Z" (model already emitted ordinals but inline)
        // This is the UNMISTAKABLY-EXPLICIT case (the speaker literally
        // enumerated), so it runs at every level except `.none`. Lighter
        // levels still honor an explicit "first… second… third…" but never
        // invent structure the speaker didn't signal.
        if options.listMode.allowsExplicitNumbered {
            let nl = Self.numberedListPass(current)
            recordIfChanged(current, nl, rule: "numbered-list", into: &changes)
            current = nl
        }

        // Em-dash strip — Qwen 3 keeps emitting em-dashes despite the prompt
        // rule. Hard-strip post-LLM: every `\u{2014}` / `\u{2013}` / `\u{2015}`
        // becomes `. ` + capitalized next word. Belt-and-suspenders so the user
        // never sees a dash even when the prompt fails.
        let de = Self.stripDashesPass(current)
        recordIfChanged(current, de, rule: "strip-dashes", into: &changes)
        current = de

        // (Emoji strip moved to the ABSOLUTE FINAL PASS at the end of
        // process() so every other normalization has happened first and we
        // catch any emoji that any other pass might have accidentally
        // preserved or introduced. See `stripEmojis` below.)

        // European-style decimals → US format inside currency amounts:
        // €2.300 → €2,300 (only when 3 digits follow, i.e. thousands separator
        // pattern). Two-digit cases like €2.50 stay as real decimals.
        let euro = Self.europeanDecimalPass(current)
        recordIfChanged(current, euro, rule: "european-decimal", into: &changes)
        current = euro

        // European-style decimal-magnitude mis-renderings: "4.5.000.000" →
        // "4.5 million". The model sometimes treats "four point five million"
        // as a single number with European thousand separators. Catastrophic
        // readability failure. Catch and fix.
        let enm = Self.normalizeEuropeanNumberMistakes(current)
        recordIfChanged(current, enm, rule: "european-number-mistakes", into: &changes)
        current = enm

        // "at <number>" is NEVER the @ symbol. Some models mis-render clock
        // times "at 3:00" or "at 6" as "@3:00" / "@6". Undo it.
        let atTime = Self.normalizeAtTime(current)
        recordIfChanged(current, atTime, rule: "at-time", into: &changes)
        current = atTime

        // Colon-list detection — "X: a, b, c, d" with 4+ short items becomes
        // a bullet list. Catches the "pull up some numbers: 5am, €2,300, ..."
        // pattern that the implicit-list pass misses (no cue verb). Reasonably
        // clear enumeration, so it runs at `.clear` (medium) and `.aggressive`
        // (high) — NOT at light/none.
        if options.listMode.allowsColonList {
            let cl = Self.colonListPass(current)
            recordIfChanged(current, cl, rule: "colon-list", into: &changes)
            current = cl
        }

        // Implicit list detection — "I have to get X, Y, Z, and W" with
        // 3+ short items becomes a bullet list. Runs near the end so
        // earlier passes have already normalized punctuation. This is the
        // ambiguous / non-explicit detector that turns a rambling enumeration
        // into a list, so it ONLY runs at `.aggressive` (high). Below high we
        // never force a list out of prose.
        if options.listMode.allowsImplicitList {
            let lr = Self.implicitListPass(current)
            recordIfChanged(current, lr, rule: "implicit-list", into: &changes)
            current = lr
        }

        // Oxford comma — runs after the list-restructuring passes so any
        // inline tails of bulleted lists ("X, Y, Z and W" → "X, Y, Z, and W")
        // and pure inline lists in prose get the serial comma. Always on:
        // the regex requires a leading ", " so it can't trip on bare "A and B".
        let ox = Self.ensureOxfordComma(current)
        recordIfChanged(current, ox, rule: "oxford-comma", into: &changes)
        current = ox

        // Capitalize first letter of each bullet/numbered item. Runs
        // unconditionally — only mutates lines that already look like list
        // items, so prose is never touched.
        let cli = Self.capitalizeListItems(current)
        recordIfChanged(current, cli, rule: "list-item-caps", into: &changes)
        current = cli

        // Common homophones and grammar fixes that ASR mishears constantly.
        let hp = Self.homophonePass(current)
        recordIfChanged(current, hp, rule: "homophones", into: &changes)
        current = hp

        // Honorifics — "Doctor Smith" → "Dr. Smith", "Mister Johnson" → "Mr. Johnson".
        let ho = Self.honorificPass(current)
        recordIfChanged(current, ho, rule: "honorifics", into: &changes)
        current = ho

        // Thousands separator — "14000" → "14,000". Skips years (1900-2100),
        // 4-digit IDs in URL/code contexts, and anything already comma-separated.
        let ts = Self.thousandsSeparatorPass(current)
        recordIfChanged(current, ts, rule: "thousands-separator", into: &changes)
        current = ts

        // Fix double-dollar artifacts: "$$200" → "$200". Occasionally an
        // upstream pass duplicates the symbol.
        let dd = Self.deduplicateCurrencySymbols(current)
        recordIfChanged(current, dd, rule: "dedup-currency", into: &changes)
        current = dd

        // Email salutation normalizer — if the output starts with "Hi <Name>,"
        // or any salutation form but the comma is followed by a space instead
        // of a paragraph break, inject `\n\n`. Belt-and-suspenders for the
        // cloud prompt: model is told to put the salutation on its own line,
        // but it occasionally produces an inline form. Runs before
        // force-paragraph-breaks so the newline counter sees it.
        let es = Self.normalizeEmailSalutation(current)
        recordIfChanged(current, es, rule: "email-salutation", into: &changes)
        current = es

        // Force paragraph breaks on long outputs. If the result is >80 words
        // and contains fewer than 2 newlines, insert breaks at the strongest
        // available topic-shift markers (period + capital letter starting a
        // new clause). The LLM keeps emitting walls of text despite the prompt
        // telling it not to — this is the safety net.
        let pb = Self.forceParagraphBreaks(current)
        recordIfChanged(current, pb, rule: "force-paragraph-breaks", into: &changes)
        current = pb

        if options.timeFormat {
            let r = timeFormatPass(current)
            recordIfChanged(current, r, rule: "time-format", into: &changes)
            current = r
        }

        if options.midClauseCapsReducer {
            let r = midClauseCapsPass(current, userProperNouns: options.userProperNouns)
            recordIfChanged(current, r, rule: "mid-clause-caps", into: &changes)
            current = r
        }

        if options.sentenceStartCaps {
            let r = sentenceStartCapsPass(current)
            recordIfChanged(current, r, rule: "sentence-start-caps", into: &changes)
            current = r
        }

        if options.standaloneICaps {
            let r = standaloneIPass(current)
            recordIfChanged(current, r, rule: "standalone-i-caps", into: &changes)
            current = r
        }

        if options.brandCaps {
            let r = brandCapsPass(current)
            recordIfChanged(current, r, rule: "brand-caps", into: &changes)
            current = r
        }

        if options.filenameDot {
            let r = filenameDotPass(current)
            recordIfChanged(current, r, rule: "filename-dot", into: &changes)
            current = r
        }

        if options.trailingCutoffPeriod {
            let r = trailingCutoffPeriodPass(current)
            recordIfChanged(current, r, rule: "trailing-cutoff-period", into: &changes)
            current = r
        }

        if options.trailingQuestionSanity {
            let r = trailingQuestionSanityPass(current)
            recordIfChanged(current, r, rule: "trailing-question-sanity", into: &changes)
            current = r
        }

        if options.trailingForeignStrip {
            let r = trailingForeignStripPass(current)
            recordIfChanged(current, r, rule: "trailing-foreign-strip", into: &changes)
            current = r
        }

        if options.whitespace {
            let r = whitespacePass(current)
            recordIfChanged(current, r, rule: "whitespace", into: &changes)
            current = r
        }

        // Code-fencing pass: wrap dictated identifiers ("the variable foo bar")
        // in backticks and snake_case them ("the variable `foo_bar`"). Runs
        // after whitespace normalization but before punctuation spacing so the
        // final spacing pass cleans up any artifacts.
        let cf = Self.applyCodeFencing(current)
        recordIfChanged(current, cf, rule: "code-fencing", into: &changes)
        current = cf

        // Backtick-discipline safety net: if the cloud model ever wraps a
        // multi-word phrase in single-backticks (e.g. `username should be`),
        // strip the backticks rather than ship a broken polish. Real code
        // identifiers don't contain spaces. Triple-backtick code blocks are
        // preserved (legitimate for multi-line code dictation).
        let bd = Self.enforceBacktickDiscipline(current)
        recordIfChanged(current, bd, rule: "backtick-discipline", into: &changes)
        current = bd

        // Punctuation spacing pass. Repairs any spacing artifacts left by
        // entity-unfreezing or earlier passes: space-before-punctuation,
        // missing-space-after-punctuation, and stray double spaces.
        if options.punctuationSpacing {
            let r = punctuationSpacingPass(current)
            recordIfChanged(current, r, rule: "punctuation-spacing", into: &changes)
            current = r
        }

        // ABSOLUTE FINAL PASS: hard-line emoji strip. Polish output is forbidden
        // to contain emojis (prompt + sanitizer enforce this), but the cloud
        // model still leaks them through on conversational dictations — the
        // "Excited" personality and emoji-evoking phrases ("thumbs up",
        // "smiley") are the most common culprits. This pass is the LAST line
        // of defense: after every normalization, including punctuation spacing,
        // strip any surviving emoji codepoint. Runs unconditionally so a
        // caller's Options toggles can never accidentally leave the door open.
        // Tidies up any spacing the strip introduces (e.g. " ." → ".").
        let finalStrip = Self.stripEmojis(current)
        recordIfChanged(current, finalStrip, rule: "final-strip-emojis", into: &changes)
        current = finalStrip

        return Result(cleaned: current, changes: changes)
    }

    private static func recordIfChanged(_ before: String, _ after: String, rule: String, into list: inout [Change]) {
        if before != after {
            list.append(Change(rule: rule, before: before, after: after))
        }
    }

    // MARK: - Pass 1: Sentence-start caps

    /// Capitalize the first letter after a sentence terminator. Handles
    /// `. `, `! `, `? `, `\n`, and the start of the string. Skips lines
    /// that begin with markdown structure ("- ", "* ", "1. ", etc.)
    /// because those are list items, not prose sentences.
    static func sentenceStartCapsPass(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var capitalizeNext = true
        var prevChar: Character = " "
        for ch in text {
            if capitalizeNext, ch.isLetter, ch.isLowercase {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch.isLetter || ch.isNumber {
                    capitalizeNext = false
                }
            }
            // Update the "should capitalize next non-whitespace char" state.
            if ch == "." || ch == "!" || ch == "?" {
                capitalizeNext = true
            } else if ch == "\n" {
                capitalizeNext = true
            } else if ch == " " || ch == "\t" {
                // whitespace doesn't reset, just preserve state
            } else if prevChar == "\n", ch == "-" || ch == "*" {
                // bullet marker — DON'T capitalize the next letter
                // automatically (the bullet content can start with a
                // lowercase fragment).
                capitalizeNext = false
            }
            prevChar = ch
        }
        return result
    }

    // MARK: - Pass 2: Mid-clause caps reducer

    /// Lowercases capitalized words that appear mid-sentence and are NOT
    /// in our proper-noun / acronym safelist. Catches the "Back" and
    /// "Probably" mid-clause failures we see from the LLM on long inputs.
    static func midClauseCapsPass(_ text: String, userProperNouns: Set<String>) -> String {
        // Build the allowed set from both the built-in list and user nouns.
        // Multi-word entries like "new york" or "san francisco" are expanded
        // so each individual word is also protected (otherwise "New" in
        // "New York" would be lowercased because "new" ≠ "new york").
        var allowed = Set<String>()
        for entry in builtInProperNouns.union(userProperNouns.map { $0.lowercased() }) {
            allowed.insert(entry)
            // Expand multi-word entries word-by-word.
            if entry.contains(" ") {
                for word in entry.split(separator: " ") {
                    allowed.insert(String(word))
                }
            }
        }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)

        // The state we actually need: "is the next word the start of a
        // clause?" Initialized true (string start), set true again after
        // every sentence terminator, set false after any word emits.
        var atClauseStart = true
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            let firstLetter = word.first!
            let upperRun = word.prefix(while: { $0.isUppercase })
            let isAllCapsAcronym = (word.count >= 2 && word.count <= 6 &&
                                    upperRun.count == word.count &&
                                    word.allSatisfy { $0.isLetter })
            let isStandaloneI = (word == "I")
            let lower = word.lowercased()
            // Strip possessive suffix ('s / 's) before safelist lookup so
            // "Apple's" is protected the same way "Apple" is.
            let lowerBase: String
            if lower.hasSuffix("'s") || lower.hasSuffix("\u{2019}s") {
                lowerBase = String(lower.dropLast(2))
            } else {
                lowerBase = lower
            }
            let isSafelisted = allowed.contains(lower) || allowed.contains(lowerBase)

            if firstLetter.isUppercase,
               !atClauseStart,
               !isAllCapsAcronym,
               !isStandaloneI,
               !isSafelisted {
                out += String(firstLetter.lowercased()) + word.dropFirst()
            } else {
                out += word
            }
            atClauseStart = false
            word = ""
        }

        for ch in chars {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" {
                word.append(ch)
                continue
            }
            // Non-word character — flush any pending word first.
            flushWord()
            out.append(ch)
            // Update clause-start state based on this character.
            switch ch {
            case ".", "!", "?", "\n", ":":
                atClauseStart = true
            default:
                // Whitespace and other punctuation keep the prior state.
                break
            }
        }
        flushWord()
        return out
    }

    // MARK: - Pass 3: Compound-word reformer

    /// Hyphenate common multi-word compounds that should be one hyphenated
    /// term. Curated list — adding pairs is cheap, but we don't infer from
    /// context.
    static let compoundPairs: [(String, String)] = [
        // Adjective compounds
        ("paraben free", "paraben-free"),
        ("paraben\u{2010}free", "paraben-free"),
        ("sulfate free", "sulfate-free"),
        ("gluten free", "gluten-free"),
        ("nut free", "nut-free"),
        ("oil free", "oil-free"),
        ("long term", "long-term"),
        ("short term", "short-term"),
        ("one time", "one-time"),
        ("real time", "real-time"),
        ("full time", "full-time"),
        ("part time", "part-time"),
        ("up to date", "up-to-date"),
        // Verb-particle that's hyphenated as adjective
        ("hard delete", "hard-delete"),
        ("hard coded", "hard-coded"),
        ("soft delete", "soft-delete"),
        // Tech
        ("usb c", "USB-C"),
        ("type c", "type-C"),
        ("wi fi", "Wi-Fi"),
        ("wi-fi", "Wi-Fi"),
        ("wifi", "Wi-Fi"),
        // Unambiguous compound adjectives / nouns. The verb-phrase cases
        // ("work hard", "play hard") are intentionally omitted unless they
        // appear before a specific noun (handled separately below).
        ("hard hitting", "hard-hitting"),
        ("well known", "well-known"),
        ("high level", "high-level"),
        ("low level", "low-level"),
        ("state of the art", "state-of-the-art"),
        ("out of date", "out-of-date"),
        ("face to face", "face-to-face"),
        ("day to day", "day-to-day"),
        ("step by step", "step-by-step"),
        ("know how", "know-how"),
        ("co worker", "coworker")
    ]

    /// Verb-phrase compounds ("work hard", "play hard") only convert when
    /// followed by one of these adjective-context nouns. Otherwise they're
    /// verb uses ("we work hard") and must NOT be hyphenated.
    static let adjectiveContextNouns: Set<String> = [
        "mentality", "attitude", "approach", "policy", "culture",
        "lifestyle", "routine", "philosophy", "mindset", "ethic"
    ]

    /// Inch-suffix compounds: "13 inch model" -> "13-inch model".
    static func compoundWordPass(_ text: String) -> String {
        var s = text
        for (from, to) in compoundPairs {
            s = caseInsensitiveReplace(s, from: from, to: to)
        }
        // N-inch / N-foot / N-pound compound (adjective form before a noun).
        if let rx = try? NSRegularExpression(pattern: #"\b(\d+)\s+(inch|foot|feet|pound|gallon)\s+(model|screen|display|laptop|tv|bag|box|jar|jug)"#, options: [.caseInsensitive]) {
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "$1-$2 $3")
        }
        // "work hard" / "play hard" + adjective-context noun -> hyphenate.
        let adjNouns = adjectiveContextNouns.joined(separator: "|")
        let verbPhrasePattern = #"\b(work|play)\s+hard\s+("# + adjNouns + #")\b"#
        if let rx = try? NSRegularExpression(pattern: verbPhrasePattern, options: [.caseInsensitive]) {
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "$1-hard $2")
        }
        return s
    }

    private static func caseInsensitiveReplace(_ source: String, from: String, to: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b", options: [.caseInsensitive]) else {
            return source
        }
        let ns = source as NSString
        return rx.stringByReplacingMatches(in: source, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: to)
    }

    // MARK: - Pass 4: Trailing cutoff period killer

    /// Strip a trailing period that follows a clearly cut-off word.
    /// Only fires on `.` — `!` and `?` are intentional sentence endings.
    /// "we have like." -> "we have like"
    /// "send it to the." -> "send it to the"
    static let cutoffWords: Set<String> = [
        "like", "and", "or", "but", "the", "a", "an", "to",
        "for", "with", "of", "at", "in", "on", "by", "as",
        "from", "into", "about", "after", "before", "than",
        "i", "we", "you", "they", "it"
    ]

    static func trailingCutoffPeriodPass(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Only fires if input ends in `<word>.` or `<word>!`.
        guard let lastDot = trimmed.lastIndex(of: ".") else { return text }
        guard lastDot == trimmed.index(before: trimmed.endIndex) else { return text }
        // Extract last word before the period.
        let beforeDot = trimmed[..<lastDot]
        let words = beforeDot.split(whereSeparator: { $0.isWhitespace })
        guard let lastWord = words.last else { return text }
        let cleanLast = lastWord.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
        guard cutoffWords.contains(cleanLast) else { return text }
        // Strip the trailing period (and any whitespace after).
        let stripped = String(trimmed[..<lastDot])
        // Preserve original trailing whitespace pattern if present.
        if text.hasSuffix("\n") {
            return stripped + "\n"
        }
        return stripped
    }

    // MARK: - Pass 5: Whitespace normalization

    static func whitespacePass(_ text: String) -> String {
        var s = text
        // Collapse multiple spaces into one (but preserve newlines).
        if let rx = try? NSRegularExpression(pattern: "[ \t]{2,}") {
            let r = NSRange(location: 0, length: (s as NSString).length)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: " ")
        }
        // Trim trailing whitespace on each line.
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Collapse 3+ newlines to 2 (preserve paragraph breaks).
        if let rx = try? NSRegularExpression(pattern: "\n{3,}") {
            let r = NSRange(location: 0, length: (s as NSString).length)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Code fencing for dictated identifiers
    //
    // Wraps an identifier dictated after a code keyword ("variable", "function",
    // "method", "field", "column", "prop", "property", "key", "parameter",
    // "argument", "class") in backticks and snake_cases it. Preserves the
    // keyword and any "the "/"a " prefix.
    //   "the variable foo bar" → "the variable `foo_bar`"
    //   "function get user id" → "function `get_user_id`"

    static func applyCodeFencing(_ text: String) -> String {
        let pattern = #"\b(the |a )?(variable|function|method|field|column|prop|property|key|parameter|argument|class) ([a-z]+( [a-z]+){0,2})\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            let prefix: String = {
                let pr = m.range(at: 1)
                return pr.location == NSNotFound ? "" : ns.substring(with: pr)
            }()
            let keyword = ns.substring(with: m.range(at: 2))
            let identifierRaw = ns.substring(with: m.range(at: 3))
            // Snake-case: lowercase + spaces → underscores. Identifier capture
            // is already lowercase-only, but lowercase defensively.
            let snake = identifierRaw.lowercased().replacingOccurrences(of: " ", with: "_")
            out += "\(prefix)\(keyword) `\(snake)`"
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Backtick discipline (safety net)
    //
    // Detects suspicious multi-word backtick spans and breaks them.
    // A legitimate code-identifier token contains no spaces and uses
    // alphanumerics, underscore, dot, slash, hyphen, or colon.
    // Multi-word phrases inside backticks (e.g., `username should be`)
    // almost certainly indicate the model over-applied code formatting
    // (the canonical failure: "the variable userName should be camelCase
    // not snakeCase" → "`username_should_be` camelCase, not snakeCase").
    //
    // Triple-backtick code blocks are preserved — those are legit for
    // multi-line code dictation.

    /// Detects suspicious multi-word backtick spans and breaks them.
    /// A legitimate code-identifier token contains no spaces and uses
    /// alphanumerics, underscore, dot, slash, hyphen, or colon.
    /// Multi-word phrases inside backticks (e.g., `username should be`)
    /// almost certainly indicate the model over-applied code formatting.
    public static func enforceBacktickDiscipline(_ text: String) -> String {
        // Catch single-backtick spans containing spaces. Strip ONLY when the
        // content looks like English prose (lowercase words + stopwords).
        // KEEP backticks when the content shows code/shell/SQL signatures:
        //   - any of `:` `=` `/` `&` `--` (shell/SQL/path)
        //   - any ALL_CAPS token of len ≥2 (SQL keywords, env vars)
        //   - first token is a known shell/CLI command name
        //   - tokens contain `_` (snake_case identifiers in a phrase)
        // This protects `bundle exec rake db:migrate`, `TRUNCATE users CASCADE`,
        // `cd ~/Downloads && pwd` while still stripping
        // `username should be camelCase`.
        let pattern = #"`([^`\n]*\s[^`\n]*)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // Common English stopwords that strongly signal prose, not code.
        let prose: Set<String> = [
            "should", "the", "a", "an", "is", "are", "be", "to", "of", "in", "on", "at",
            "and", "or", "but", "not", "this", "that", "with", "for", "from", "by",
            "it", "its", "as", "if", "when", "where", "how", "why", "we", "you", "they"
        ]
        // Recognized shell / SQL command leading tokens.
        let cmds: Set<String> = [
            "bundle", "git", "npm", "yarn", "pnpm", "cd", "ls", "cat", "grep", "find",
            "sed", "awk", "curl", "wget", "ssh", "scp", "make", "cargo", "swift", "node",
            "python", "python3", "ruby", "rails", "rake", "go", "docker", "kubectl",
            "psql", "mysql", "redis-cli", "sudo", "brew", "pip", "pip3", "apt", "apt-get",
            "tail", "head", "tar", "zip", "unzip", "rsync", "mv", "cp", "rm", "mkdir",
            "touch", "echo", "export", "set", "unset",
            "select", "insert", "update", "delete", "truncate", "alter", "create", "drop",
            "grant", "revoke", "begin", "commit", "rollback"
        ]

        var result = text
        // Walk matches in reverse so range replacements don't shift indices.
        for m in matches.reversed() {
            let fullRange = m.range
            let contentRange = m.range(at: 1)
            let content = nsText.substring(with: contentRange)
            let tokens = content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { continue }

            let firstLower = tokens[0].lowercased()
            let hasCodeChar = content.contains(":") || content.contains("=")
                || content.contains("/") || content.contains("&")
                || content.contains("--") || content.contains("_")
            let hasAllCapsToken = tokens.contains { tok in
                tok.count >= 2 && tok.allSatisfy { $0.isUppercase || !$0.isLetter }
                    && tok.contains(where: { $0.isLetter })
            }
            let startsWithCmd = cmds.contains(firstLower)
            let looksLikeCode = hasCodeChar || hasAllCapsToken || startsWithCmd
            if looksLikeCode { continue }  // keep backticks

            // Otherwise: check if it's prose (contains stopwords).
            let lowerTokens = Set(tokens.map { $0.lowercased() })
            let looksLikeProse = !lowerTokens.isDisjoint(with: prose)
            if !looksLikeProse { continue }  // ambiguous — keep backticks to be safe

            // Strip backticks: replace `<content>` with <content>.
            if let swiftRange = Range(fullRange, in: result) {
                result.replaceSubrange(swiftRange, with: content)
            }
        }
        return result
    }

    // MARK: - Pass 0: Spoken punctuation & line commands (deterministic)
    //
    // Converts dictated punctuation/structure commands into the real symbol or
    // line break. This is the DETERMINISTIC mirror of TextFormatter's voice-
    // command table, living in the shared postprocessor so it fires on every
    // polish path — including the triple-ASR merge path and any LLM-rejected /
    // model-unavailable fallback. The user's #1 reported bug ("can't recognize
    // slash commands") is fixed here: bare "slash" / "X slash Y" now converts
    // even when no URL context is present.
    //
    // Design:
    //   - UNAMBIGUOUS commands ("question mark", "new paragraph", "open paren",
    //     "exclamation point", symbol names) convert anywhere they appear as a
    //     whole word/phrase — they essentially never occur as literal prose.
    //   - AMBIGUOUS single words ("period", "comma", "colon", "semicolon",
    //     "dash") only convert in a command-shaped context: end-of-utterance,
    //     OR followed by another word (capital OR lowercase — dictation is
    //     lowercase, so we MUST accept lowercase, unlike the old TextFormatter
    //     rule that required a capital). A short denylist of real prose
    //     collocations ("period drama", "comma splice", "colon cancer") is
    //     excluded so they survive.
    //   - SLASH: "X slash Y" → "X/Y" (no surrounding spaces) for the common
    //     path/handle case. Already-formed "a/b" is untouched. URLs/emails are
    //     further reconstructed by the dedicated spoken-URL pass that runs
    //     after this.
    //
    // No emojis, no em-dashes: spoken "dash" becomes a hyphen with surrounding
    // spaces (" - "); the strip-dashes pass downstream still removes any real
    // em/en dashes per the app rule.

    /// Prose collocations where an ambiguous command word is NOT a command.
    /// Matched as "<word> <command>" or "<command> <word>"; if the command
    /// participates in one of these, we leave it as prose.
    private static let ambiguousCommandProseGuards: [String: Set<String>] = [
        "period": ["drama", "dramas", "piece", "costume", "grace", "time", "of"],
        "comma": ["splice", "splices"],
        "colon": ["cancer", "cleanse", "rectal", "polyp", "polyps"],
        "dash": ["board", "boards", "cam", "line", "lines", "of"],
    ]

    static func spokenPunctuationPass(_ text: String) -> String {
        var s = text

        // --- Structural commands (always convert; multi-word first) ---
        // Order matters: "new paragraph" before "new line"/"line", etc.
        // Consume surrounding horizontal whitespace so we get "a\n\nb", not
        // "a \n\n b" (the latter leaves stray leading spaces on each line).
        let structural: [(String, String)] = [
            (#"[^\S\n]*\bnew\s+paragraph\b[^\S\n]*"#, "\n\n"),
            (#"[^\S\n]*\bnext\s+paragraph\b[^\S\n]*"#, "\n\n"),
            (#"[^\S\n]*\bnew\s+line\b[^\S\n]*"#, "\n"),
            (#"[^\S\n]*\bnext\s+line\b[^\S\n]*"#, "\n"),
            (#"[^\S\n]*\bline\s+break\b[^\S\n]*"#, "\n"),
        ]
        for (pat, rep) in structural {
            s = replaceRegex(s, pattern: pat, options: [.caseInsensitive]) { _ in rep }
        }

        // --- Glue symbols: consume surrounding spaces so they bind to
        // neighboring tokens ("user underscore id" → "user_id", "a forward
        // slash b" → "a/b"). These NEVER take surrounding spaces in real text.
        let glueSymbols: [(String, String)] = [
            (#"[^\S\n]*\bunderscore\b[^\S\n]*"#, "_"),
            (#"[^\S\n]*\bforward\s+slash\b[^\S\n]*"#, "/"),
            (#"[^\S\n]*\bback\s*slash\b[^\S\n]*"#, "\\"),
        ]
        for (pat, rep) in glueSymbols {
            s = replaceRegex(s, pattern: pat, options: [.caseInsensitive]) { _ in rep }
        }

        // --- Unambiguous punctuation phrases (multi-word first) ---
        let unambiguous: [(String, String)] = [
            (#"\bexclamation\s+point\b"#, "!"),
            (#"\bexclamation\s+mark\b"#, "!"),
            (#"\bexplanation\s+point\b"#, "!"),  // common ASR mishear of "exclamation"
            (#"\bexplanation\s+mark\b"#, "!"),
            (#"\bquestion\s+mark\b"#, "?"),
            (#"\bfull\s+stop\b"#, "."),
            (#"\bopen\s+paren(?:thesis)?\b"#, "("),
            (#"\bclose\s+paren(?:thesis)?\b"#, ")"),
            (#"\bopen\s+bracket\b"#, "["),
            (#"\bclose\s+bracket\b"#, "]"),
            (#"\bopen\s+brace\b"#, "{"),
            (#"\bclose\s+brace\b"#, "}"),
            (#"\bat\s+sign\b"#, "@"),
            (#"\bat\s+symbol\b"#, "@"),
            (#"\bpound\s+sign\b"#, "#"),
            (#"\bhash\s+sign\b"#, "#"),
            (#"\bdollar\s+sign\b"#, "$"),
            (#"\bpercent\s+sign\b"#, "%"),
            (#"\bplus\s+sign\b"#, "+"),
            (#"\bequals\s+sign\b"#, "="),
            (#"\bequal\s+sign\b"#, "="),
            (#"\bdot\s+dot\s+dot\b"#, "\u{2026}"),
            (#"\bellipsis\b"#, "\u{2026}"),
            (#"\bampersand\b"#, "&"),
            (#"\basterisk\b"#, "*"),
            (#"\btilde\b"#, "~"),
            (#"\bcaret\b"#, "^"),
        ]
        for (pat, rep) in unambiguous {
            s = replaceRegex(s, pattern: pat, options: [.caseInsensitive]) { _ in rep }
        }

        // --- Slash: "X slash Y" → "X/Y" (path/handle), bare "slash" → "/" ---
        // Both sides word-chars → glue without spaces. This is the dominant
        // dictation intent ("github slash repo slash readme" → github/repo/readme).
        // Apply repeatedly so chained slashes ("a slash b slash c") all collapse.
        var prevSlash: String
        repeat {
            prevSlash = s
            s = replaceRegex(
                s,
                pattern: #"([A-Za-z0-9_.\-]+)\s+slash\s+([A-Za-z0-9_.\-]+)"#,
                options: [.caseInsensitive]
            ) { g in "\(g[1])/\(g[2])" }
        } while s != prevSlash
        // Any remaining standalone "slash" (start/end of clause) → "/".
        s = replaceRegex(s, pattern: #"\bslash\b"#, options: [.caseInsensitive]) { _ in "/" }

        // --- Ambiguous single-word commands (period/comma/colon/semicolon) ---
        // Convert when: end-of-string, OR followed by whitespace + a word
        // (lowercase OR capital) + we are NOT in a known prose collocation.
        // Replacement carries the natural following space for word-then-word
        // cases so "store comma then" → "store, then".
        s = applyAmbiguousCommand(s, word: "period", symbol: ".")
        s = applyAmbiguousCommand(s, word: "comma", symbol: ",")
        s = applyAmbiguousCommand(s, word: "colon", symbol: ":")
        s = applyAmbiguousCommand(s, word: "semicolon", symbol: ";")

        // --- Spoken "dash" / "hyphen" → " - " (ambiguous-guarded) ---
        // CLI flags first: "dash dash" / "double dash" → "--". Keep it as a
        // space-separated token ("npm install --save"), so we do NOT consume
        // surrounding whitespace here (unlike the glue symbols).
        s = replaceRegex(s, pattern: #"\b(?:dash\s+dash|double\s+dash|double\s+hyphen)\b"#, options: [.caseInsensitive]) { _ in "--" }
        s = applyAmbiguousCommand(s, word: "hyphen", symbol: "-", spaced: true)
        s = applyAmbiguousCommand(s, word: "dash", symbol: "-", spaced: true)

        return s
    }

    /// Convert an ambiguous single-word spoken command to its symbol, but only
    /// in a command-shaped context and not inside a known prose collocation.
    ///
    /// - Parameters:
    ///   - spaced: when true (dash/hyphen) the symbol is wrapped with spaces
    ///     (" - ") and we DON'T glue it to the next word; when false (period/
    ///     comma/etc.) the symbol attaches to the preceding word and a single
    ///     space precedes the following word ("store, then").
    private static func applyAmbiguousCommand(
        _ text: String,
        word: String,
        symbol: String,
        spaced: Bool = false
    ) -> String {
        let proseGuard = ambiguousCommandProseGuards[word] ?? []
        let escaped = NSRegularExpression.escapedPattern(for: word)
        // Capture the optional following word so we can (a) check the prose
        // guard and (b) preserve it. Group 1 = following word (may be empty at
        // end-of-utterance). We require the command word to be preceded by a
        // boundary and followed by: HORIZONTAL-whitespace + word, OR
        // end-of-string, OR a newline. The following-word separator is
        // [^\S\n]+ (NOT \s+) so a newline does NOT get swallowed into the
        // word branch — "period\nbye" must yield "." + a preserved newline,
        // not "period. bye" with the line break eaten. Also guard the
        // PRECEDING word against prose collocations.
        let pattern = #"(?:^|(?<=\s))"# + "\(escaped)" + #"\b(?:[^\S\n]+([A-Za-z][A-Za-z'\-]*)|(?=\s*$)|(?=\s*\n))"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        for m in matches {
            let mRange = m.range
            // Preceding word (for prose-guard): the token immediately before the match.
            let precedingWord: String = {
                let pre = ns.substring(to: mRange.location)
                guard let last = pre.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).last else { return "" }
                return String(last).lowercased().trimmingCharacters(in: .punctuationCharacters)
            }()
            let followingWord: String = {
                let r = m.range(at: 1)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }()
            // Prose-guard: skip conversion if either neighbor marks this as prose.
            let isProse = proseGuard.contains(precedingWord)
                || (!followingWord.isEmpty && proseGuard.contains(followingWord.lowercased()))
            // Copy text before the match verbatim.
            if mRange.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: mRange.location - cursor))
            }
            if isProse {
                out += ns.substring(with: mRange)  // leave prose untouched
            } else if followingWord.isEmpty {
                // End-of-utterance command: just the symbol (no trailing space).
                out += spaced ? " \(symbol)" : symbol
            } else if spaced {
                out += " \(symbol) \(followingWord)"
            } else {
                out += "\(symbol) \(followingWord)"
            }
            cursor = mRange.location + mRange.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Final pass: punctuation spacing (deterministic)
    //
    // Repairs spacing AROUND punctuation, the user's "spacing is sometimes off"
    // complaint. Runs last so it cleans up whatever earlier passes / entity
    // unfreezing produced. Conservative: only touches spaces, never content.
    // Preserves \n and \n\n (paragraph structure), decimals (3.5), ellipses
    // (…), and numeric/clock colons (3:30).

    static func punctuationSpacingPass(_ text: String) -> String {
        var s = text

        // 1. Remove space(s) BEFORE , ; : ! ? . — but not inside a newline run.
        //    "word ," → "word,". Negative: don't pull a period off a decimal
        //    (there's never a space before a decimal point anyway).
        s = replaceRegex(s, pattern: #"[^\S\n]+([,;:!?])"#, options: []) { g in g[1] }
        // Period: same, but guard ellipsis (handled as its own char) — a lone
        // "." preceded by space collapses.
        s = replaceRegex(s, pattern: #"[^\S\n]+(\.)(?!\.)"#, options: []) { g in g[1] }

        // 2. Ensure ONE space after sentence punctuation . ! ? when a sentence
        //    clearly ended and the next one starts. To avoid mangling dotted
        //    identifiers (Foo.Bar, U.S.A, README.MD, v1.2) the period rule
        //    requires: a full lowercase WORD before the dot whose FIRST letter
        //    is also lowercase (so "home.She" splits but "Foo.Bar" — leading
        //    cap — does not), the dot, then an uppercase+lowercase start. This
        //    leaves CamelCase/acronym/file/version dotted tokens intact while
        //    still fixing run-together sentences. `!`/`?` are unambiguous
        //    sentence terminals, so they only need a lowercase letter before.
        s = replaceRegex(s, pattern: #"(?<![A-Za-z])([a-z][a-z]+)\.([A-Z][a-z])"#, options: []) { g in "\(g[1]). \(g[2])" }
        s = replaceRegex(s, pattern: #"([a-z])([!?])([A-Z])"#, options: []) { g in "\(g[1])\(g[2]) \(g[3])" }
        // 3. Ensure ONE space after a comma/semicolon/colon when followed by a
        //    letter (missing-space-after-comma: "a,b" → "a, b"). Skip when
        //    followed by a digit (could be "3,500" thousands or "3:30" time).
        s = replaceRegex(s, pattern: #"([,;])([A-Za-z])"#, options: []) { g in "\(g[1]) \(g[2])" }

        // 4. Collapse any horizontal double-spaces introduced above (NOT \n).
        s = replaceRegex(s, pattern: #"[^\S\n]{2,}"#, options: []) { _ in " " }

        // 5. No space before a closing paren/bracket; no space after an opening one.
        s = replaceRegex(s, pattern: #"\(\s+"#, options: []) { _ in "(" }
        s = replaceRegex(s, pattern: #"[^\S\n]+\)"#, options: []) { _ in ")" }

        // 6. Trim trailing horizontal whitespace on each line + overall ends.
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                while l.hasSuffix(" ") || l.hasSuffix("\t") { l.removeLast() }
                while l.hasPrefix(" ") || l.hasPrefix("\t") { l.removeFirst() }
                return l
            }
            .joined(separator: "\n")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pass 6: Standalone i capitalization

    /// Uppercases standalone lowercase `i` and its contractions
    /// (`i'm`, `i've`, `i'll`, `i'd`). Word-boundary matched so words
    /// like `inside`, `idea`, `since`, `liking` are untouched.
    /// Handles both straight `'` and curly `\u{2019}` apostrophes.
    static func standaloneIPass(_ text: String) -> String {
        // Only match lowercase `i` (NOT case-insensitive); capture so
        // we can rebuild the replacement preserving the apostrophe and
        // suffix.
        guard let rx = try? NSRegularExpression(
            pattern: "\\b(i)(['\u{2019}])?(m|ve|ll|d)?\\b",
            options: []
        ) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            // Rebuild: I + (apostrophe?) + (suffix?)
            var replacement = "I"
            if m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound {
                replacement += ns.substring(with: m.range(at: 2))
            }
            if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound {
                replacement += ns.substring(with: m.range(at: 3))
            }
            out += replacement
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Pass 7: Brand-name capitalization

    /// Curated brand list. Order matters: multi-word entries first so
    /// "macOS Tahoe" is replaced before "macOS".
    static let brandReplacements: [(pattern: String, replacement: String)] = [
        // Common mangles first.
        ("meg os tahoe",       "macOS Tahoe"),
        ("meg os sequoia",     "macOS Sequoia"),
        ("meg os sonoma",      "macOS Sonoma"),
        ("meg os ventura",     "macOS Ventura"),
        ("meg os",             "macOS"),
        ("mac os tahoe",       "macOS Tahoe"),
        ("mac os sequoia",     "macOS Sequoia"),
        ("mac os sonoma",      "macOS Sonoma"),
        ("mac os ventura",     "macOS Ventura"),
        ("mac os",             "macOS"),
        // Multi-word brands
        ("macos tahoe",        "macOS Tahoe"),
        ("macos sequoia",      "macOS Sequoia"),
        ("macos sonoma",       "macOS Sonoma"),
        ("macos ventura",      "macOS Ventura"),
        ("macbook pro",        "MacBook Pro"),
        ("macbook air",        "MacBook Air"),
        ("mac studio",         "Mac Studio"),
        ("mac pro",            "Mac Pro"),
        ("mac mini",           "Mac Mini"),
        ("system settings",    "System Settings"),
        ("control panel",      "Control Panel"),
        ("apple watch",        "Apple Watch"),
        ("apple tv",           "Apple TV"),
        // Single-word brands
        ("macos",              "macOS"),
        ("ios",                "iOS"),
        ("ipados",             "iPadOS"),
        ("watchos",            "watchOS"),
        ("tvos",               "tvOS"),
        ("visionos",           "visionOS"),
        ("iphone",             "iPhone"),
        ("ipad",               "iPad"),
        ("macbook",            "MacBook"),
        ("airpods",            "AirPods"),
        ("slack",              "Slack"),
        ("spotify",            "Spotify"),
        ("discord",            "Discord"),
        ("zoom",               "Zoom"),
        ("telegram",           "Telegram"),
        ("notion",             "Notion"),
        ("linear",             "Linear"),
        ("figma",              "Figma"),
        ("github",             "GitHub"),
        ("gitlab",             "GitLab"),
        ("chatgpt",            "ChatGPT"),
        ("claude",             "Claude"),
        ("openai",             "OpenAI"),
        ("anthropic",          "Anthropic"),
        ("usb-c",              "USB-C"),
        ("usb c",              "USB-C"),
        ("wi-fi",              "Wi-Fi"),
        ("wi fi",              "Wi-Fi"),
        ("wifi",               "Wi-Fi"),
        ("bluetooth",          "Bluetooth"),
        ("youtube",            "YouTube"),
        ("reddit",             "Reddit"),
        ("twitter",            "Twitter"),
        ("instagram",          "Instagram"),
        ("tiktok",             "TikTok"),
        ("linkedin",           "LinkedIn"),
        ("facebook",           "Facebook"),
        // Note: "Mac" alone is intentionally last among single-words
        // and we don't include it as it collides with names like "Mac"
        // the person and is too generic for case-insensitive replace.
    ]

    static func brandCapsPass(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in brandReplacements {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            // Word boundaries on both sides. `\b` doesn't fire next to `-`,
            // so for patterns containing `-` we use a lookaround.
            let bounded = "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
            guard let rx = try? NSRegularExpression(pattern: bounded, options: [.caseInsensitive]) else { continue }
            let ns = s as NSString
            let r = NSRange(location: 0, length: ns.length)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return s
    }

    // MARK: - Pass 8: Filename .Dot. pattern + extension lowercase

    static let knownExtensions: [String] = [
        "txt", "png", "pdf", "csv", "json", "md", "doc", "docx",
        "xls", "xlsx", "mp3", "mp4", "mov", "zip", "js", "ts",
        "py", "swift", "rs", "jpg", "jpeg", "gif", "html", "css"
    ]

    static func filenameDotPass(_ text: String) -> String {
        var s = text
        // Replace ".Dot." (case-insensitive) sandwiched between
        // alphanumeric characters with a literal ".".
        if let rx = try? NSRegularExpression(
            pattern: "(?<=[A-Za-z0-9])\\.?dot\\.(?=[A-Za-z0-9])",
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: ".")
        }
        // Lowercase known extensions when they appear after a `.` and
        // preceded by an alphanumeric (filename) char.
        for ext in knownExtensions {
            let pattern = "(?<=[A-Za-z0-9])\\.(" + ext + ")(?![A-Za-z0-9])"
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = s as NSString
            let r = NSRange(location: 0, length: ns.length)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "." + ext)
        }
        return s
    }

    // MARK: - Pass 9: Trailing foreign / hallucination strip

    /// Common English stop-words; if NONE of the last-sentence words
    /// match this set AND the sentence is short, strip it.
    static let englishMarkers: Set<String> = [
        "the", "a", "an", "and", "or", "is", "are", "was", "were",
        "i", "you", "we", "they", "this", "that", "it", "to", "for",
        "with", "of", "on", "in", "at", "from", "be", "have", "has",
        "had", "do", "does", "did", "will", "would", "can", "could",
        "should", "not", "no", "yes", "so", "but", "if", "as", "by",
        "me", "my", "your", "our", "their", "his", "her"
    ]

    static func trailingForeignStripPass(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Find the start of the last sentence by walking back to the
        // previous terminator.
        let terminators: Set<Character> = [".", "!", "?"]
        // Drop a trailing terminator for splitting purposes.
        var endIdx = trimmed.endIndex
        var trailing = ""
        if let last = trimmed.last, terminators.contains(last) {
            trailing = String(last)
            endIdx = trimmed.index(before: trimmed.endIndex)
        }
        let body = trimmed[..<endIdx]
        // Find the most recent terminator inside body.
        var startIdx = body.startIndex
        var hadPrior = false
        for i in body.indices.reversed() {
            if terminators.contains(body[i]) {
                startIdx = body.index(after: i)
                hadPrior = true
                break
            }
        }
        let lastSentence = String(body[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastSentence.isEmpty else { return text }
        // Tokenize into words.
        let words = lastSentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
        guard !words.isEmpty, words.count <= 8 else { return text }
        // Count non-ASCII-letter words and English-marker words.
        var nonAsciiCount = 0
        var englishMatchCount = 0
        for w in words {
            let lower = w.lowercased()
            if englishMarkers.contains(lower) { englishMatchCount += 1 }
            if w.unicodeScalars.contains(where: { $0.value > 127 }) { nonAsciiCount += 1 }
        }
        let nonAsciiRatio = Double(nonAsciiCount) / Double(words.count)
        // Conservative: require non-ASCII characters present. Either
        // a clear majority non-ASCII, OR any non-ASCII at all plus zero
        // English markers. Pure-ASCII English-looking fragments are
        // never stripped (false-positive cost too high).
        let shouldStrip = (nonAsciiRatio >= 0.5) ||
                          (nonAsciiCount > 0 && englishMatchCount == 0)
        guard shouldStrip else { return text }
        // Only strip if we had a prior sentence — never delete the only
        // sentence (too risky).
        guard hadPrior else { return text }
        _ = trailing
        // Trim trailing-of-prior, then strip the last sentence (and any
        // preceding whitespace).
        var result = String(trimmed[..<startIdx])
        // Drop trailing whitespace from result.
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        // Preserve the prior sentence's terminator (already in result).
        return result
    }

    // MARK: - Proper noun safelist

    /// Built-in proper nouns and brand names that should always stay
    /// capitalized mid-sentence. Intentionally curated — we are not
    /// trying to be a general NER system.
    static let builtInProperNouns: Set<String> = [
        // Days / months
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        // Major brand / product names
        "iphone", "ipad", "ipod", "macos", "ios", "ebay", "openai", "anthropic",
        "claude", "chatgpt", "gpt", "nordvpn", "tailscale", "github", "gitlab",
        "google", "apple", "microsoft", "amazon", "facebook", "meta", "twitter",
        "instagram", "tiktok", "linkedin", "reddit", "youtube", "netflix",
        "spotify", "uber", "lyft", "doordash", "stripe", "square", "venmo",
        "paypal", "cashapp", "telegram", "discord", "slack", "zoom",
        // Cities
        "seoul", "tokyo", "osaka", "kyoto", "lisbon", "madrid", "barcelona",
        "london", "paris", "berlin", "rome", "milan", "vienna", "prague",
        "amsterdam", "copenhagen", "stockholm", "oslo", "helsinki",
        "new york", "san francisco", "los angeles", "chicago", "boston",
        "seattle", "austin", "miami", "denver", "atlanta",
        "mexico city", "buenos aires", "rio", "sao paulo", "lima",
        "beijing", "shanghai", "hong kong", "singapore", "bangkok", "manila",
        "mumbai", "delhi", "dubai", "istanbul", "cairo", "lagos", "nairobi",
        // Common languages
        "english", "spanish", "french", "german", "japanese", "chinese",
        "korean", "italian", "russian", "arabic", "hindi", "portuguese",
        // Common acronyms (will also be caught by all-caps detection but
        // having them here covers the case where they're typed as "Sql")
        "sql", "html", "css", "api", "url", "uri", "ssh", "ftp", "http",
        "https", "json", "xml", "yaml", "csv", "pdf", "jpg", "png", "gif",
        "fbi", "cia", "nsa", "irs", "fda", "epa", "doj", "dod", "ceo", "cto",
        "cfo", "coo", "vp", "hr", "pr", "it", "qa", "ui", "ux",
        "lax", "jfk", "lhr", "sfo", "ord", "atl", "dxb",
        // Common male/female first names that show up in dictation
        "alice", "bob", "carol", "dave", "eve", "frank", "grace", "heidi",
        "ivan", "judy", "kevin", "lisa", "mike", "nina", "oscar", "peggy",
        "quinn", "rachel", "sam", "trent", "uma", "victor", "wendy", "xena",
        "yves", "zoe",
        "alex", "amy", "andrew", "anna", "ben", "chris", "claire", "daniel",
        "david", "ellen", "emma", "ethan", "george", "hannah", "henry",
        "isabella", "jack", "james", "jane", "john", "julia", "kate", "leo",
        "linda", "lucas", "luke", "maria", "mark", "mary", "matt", "matthew",
        "maya", "michael", "michelle", "natalie", "nick", "noah", "olivia",
        "paul", "peter", "rachel", "rob", "robert", "ruth", "ryan", "sarah",
        "scott", "sean", "sophia", "steve", "susan", "tim", "tom", "vicky",
        "william",
        // Streets / freeway commons (avoid lowercasing "Sunset" mid-sentence)
        "sunset", "wilshire", "hollywood", "broadway", "main"
    ]

    // MARK: - Pass 10: Trailing question-mark sanity

    /// The closed-form list of orphan discourse-tag words that the model
    /// occasionally suffixes with a spurious `?`. We ONLY consider these
    /// exact tokens — anything else stays untouched.
    private static let questionTagWords: Set<String> = [
        "yeah", "okay", "ok", "right", "sure", "alright", "huh"
    ]

    /// Question-marker words. If a "Yeah?" follows a sentence whose prior
    /// sentence is clearly declarative (no `?`, no wh-fronted start, no
    /// auxiliary inversion), we treat the trailing `?` as hallucinated and
    /// flip it to `.`. When ambiguous, do nothing.
    /// Note: "which" is intentionally excluded — it's far more often a
    /// relative pronoun ("which is odd") than a wh-question fronting
    /// ("Which one?"). True wh-questions already contain a `?` which is
    /// caught by the earlier check.
    private static let whWords: Set<String> = [
        "who", "what", "where", "when", "why", "how", "whose", "whom"
    ]

    private static let inversionAuxes: [String] = [
        "is", "are", "was", "were", "am",
        "do", "does", "did",
        "can", "could", "will", "would", "should", "shall",
        "have", "has", "had", "may", "might", "must"
    ]

    static func trailingQuestionSanityPass(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Must end with "?" optionally followed by "." (tolerant of model
        // double-terminator quirks).
        var endIdx = trimmed.endIndex
        if trimmed.last == "." {
            endIdx = trimmed.index(before: endIdx)
        }
        guard endIdx > trimmed.startIndex, trimmed[trimmed.index(before: endIdx)] == "?" else {
            return text
        }
        let qMarkPos = trimmed.index(before: endIdx)
        // Find start of the trailing tag sentence — walk back from qMarkPos
        // until a sentence terminator. Need a prior sentence for this to fire.
        let body = trimmed[..<qMarkPos]
        var sentStart = body.startIndex
        var hadPrior = false
        for i in body.indices.reversed() {
            let c = body[i]
            if c == "." || c == "!" || c == "?" || c == "\n" {
                sentStart = body.index(after: i)
                hadPrior = true
                break
            }
        }
        guard hadPrior else { return text }
        let tagSentence = String(body[sentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract the single tag word (lowercased, stripped of punctuation).
        let tagWords = tagSentence.split(whereSeparator: { !$0.isLetter }).map { String($0).lowercased() }
        // Accept either:
        //   - single word that's a question-tag word ("Yeah?")
        //   - connector + question-tag word ("But yeah?", "So yeah?")
        let tagConnectors: Set<String> = ["but", "and", "so", "well", "oh", "yeah", "ok", "okay"]
        let acceptableTag: Bool = {
            if tagWords.count == 1, let t = tagWords.first, questionTagWords.contains(t) {
                return true
            }
            if tagWords.count == 2, tagConnectors.contains(tagWords[0]),
               questionTagWords.contains(tagWords[1]) {
                return true
            }
            return false
        }()
        guard acceptableTag else { return text }
        // Locate the prior sentence. sentStart is right after the
        // terminator of the prior sentence. Walk back past whitespace and
        // any terminator chars to find the END of the prior sentence's
        // content; then walk back to its START.
        var contentEnd = body.index(before: sentStart) // position of the terminator
        // Move past trailing whitespace just in case.
        while contentEnd > body.startIndex, body[contentEnd].isWhitespace {
            contentEnd = body.index(before: contentEnd)
        }
        // Skip the terminator(s) themselves to land on the last content char.
        while contentEnd > body.startIndex,
              body[contentEnd] == "." || body[contentEnd] == "!" || body[contentEnd] == "?" {
            contentEnd = body.index(before: contentEnd)
        }
        // contentEnd now indexes the last content character of prior.
        // Walk back to start of prior sentence (one past previous terminator, or body.startIndex).
        var priorStart = body.startIndex
        if contentEnd > body.startIndex {
            var j = contentEnd
            while j > body.startIndex {
                j = body.index(before: j)
                let c = body[j]
                if c == "." || c == "!" || c == "?" || c == "\n" {
                    priorStart = body.index(after: j)
                    break
                }
            }
        }
        let priorEnd = body.index(after: contentEnd)
        guard priorStart <= priorEnd else { return text }
        let prior = String(body[priorStart..<priorEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prior.isEmpty else { return text }
        // Is prior clearly a question?
        if prior.contains("?") { return text }
        let priorWords = prior.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0).lowercased() }
        guard !priorWords.isEmpty else { return text }
        // Wh-fronted (first 3 words contain a wh-word).
        let firstThree = priorWords.prefix(3)
        for w in firstThree where whWords.contains(w) { return text }
        // Auxiliary inversion: aux followed by pronoun in first two tokens.
        let pronouns: Set<String> = ["you", "i", "we", "they", "he", "she", "it"]
        if priorWords.count >= 2,
           inversionAuxes.contains(priorWords[0]),
           pronouns.contains(priorWords[1]) {
            return text
        }
        // Prior is declarative — flip the trailing `?` to `.`.
        var result = String(trimmed[..<qMarkPos]) + "."
        // Preserve any trailing `.` that originally followed the `?`.
        if trimmed.last == "." {
            // The trimmed text ended with "?." — collapse to a single ".".
        }
        // Preserve trailing whitespace pattern from the original.
        let originalTail = text[text.index(text.startIndex, offsetBy: text.distance(from: text.startIndex, to: text.endIndex))..<text.endIndex]
        _ = originalTail
        if text.hasSuffix("\n") { result += "\n" }
        return result
    }

    // MARK: - Pass 11: Number spellout normalization

    /// Convert spelled-out number patterns into digits in conservative,
    /// pattern-bounded ways. We never touch already-digit numbers, decimals,
    /// version strings, dollar amounts, etc.
    private static let digitWordMap: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    private static let teensMap: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    static func numberSpelloutPass(_ text: String) -> String {
        var s = text

        // 1) "<digit> point <digit> k" -> "<N>.<M>K"
        s = replaceRegex(s, pattern: #"\b(one|two|three|four|five|six|seven|eight|nine)\s+point\s+(one|two|three|four|five|six|seven|eight|nine)\s+k\b"#) { groups in
            guard let n = digitWordMap[groups[1].lowercased()],
                  let m = digitWordMap[groups[2].lowercased()] else { return groups[0] }
            return "\(n).\(m)K"
        }

        // 2) "<digit> point <digit> (euros|dollars|pounds)"
        s = replaceRegex(s, pattern: #"\b(one|two|three|four|five|six|seven|eight|nine)\s+point\s+(one|two|three|four|five|six|seven|eight|nine)\s+(euros|dollars|pounds)\b"#) { groups in
            guard let n = digitWordMap[groups[1].lowercased()],
                  let m = digitWordMap[groups[2].lowercased()] else { return groups[0] }
            return "\(n).\(m) \(groups[3].lowercased())"
        }

        // 3) Countdown sequences: 3+ descending digit-words in order
        //    "five four three two one" / "three two one" / "ten nine eight seven six five four three two one"
        //    We accept any descending run of digit-words (0-9) of length >= 3.
        s = replaceCountdownSequences(s)

        // 4) "<teen|tens|hundred> degrees (celsius|fahrenheit)"
        //    Accept patterns: "fourteen", "twenty five", "one hundred".
        s = replaceRegex(s, pattern: #"\b((?:one\s+hundred)|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[\s-](?:one|two|three|four|five|six|seven|eight|nine))?|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|hundred)\s+degrees\s+(celsius|fahrenheit)\b"#, options: [.caseInsensitive]) { groups in
            let numStr = groups[1]
            let scale = groups[2].lowercased() == "celsius" ? "Celsius" : "Fahrenheit"
            guard let n = parseSpelledNumber(numStr) else { return groups[0] }
            return "\(n) degrees \(scale)"
        }

        // 5) "<spelled> percent" -> "<N>%"
        //    Cover: "one hundred", "fifty", "twenty five", "ten"..."nineteen", "one"..."nine".
        s = replaceRegex(s, pattern: #"\b((?:one\s+hundred)|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[\s-](?:one|two|three|four|five|six|seven|eight|nine))?|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|one|two|three|four|five|six|seven|eight|nine)\s+percent\b"#, options: [.caseInsensitive]) { groups in
            guard let n = parseSpelledNumber(groups[1]) else { return groups[0] }
            return "\(n)%"
        }

        return s
    }

    /// Parse "twenty five", "one hundred", "fourteen", "five" -> Int.
    private static func parseSpelledNumber(_ raw: String) -> Int? {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard !normalized.isEmpty else { return nil }
        // "one hundred"
        if normalized == ["one", "hundred"] { return 100 }
        if normalized == ["hundred"] { return 100 }
        // teens
        if normalized.count == 1, let v = teensMap[normalized[0]] { return v }
        // single digit
        if normalized.count == 1, let v = digitWordMap[normalized[0]] { return v }
        // tens (single token)
        if normalized.count == 1, let v = tensMap[normalized[0]] { return v }
        // tens + digit
        if normalized.count == 2, let tens = tensMap[normalized[0]], let ones = digitWordMap[normalized[1]] {
            return tens + ones
        }
        return nil
    }

    /// Replace any descending run of 3+ digit-word tokens (0-9), strictly
    /// decreasing by 1 each step, with comma-separated digits.
    /// "three two one"          -> "3, 2, 1"
    /// "the three two one go"   -> "the 3, 2, 1 go"
    /// "hello three"            -> unchanged (single digit, not a sequence)
    private static func replaceCountdownSequences(_ text: String) -> String {
        // Tokenize on whitespace, retaining character ranges via NSRegularExpression.
        // Use a regex matching 3 or more digit-words separated by single spaces.
        let digitWordAlt = "(?:zero|one|two|three|four|five|six|seven|eight|nine)"
        let pattern = "\\b(" + digitWordAlt + "(?:\\s+" + digitWordAlt + "){2,})\\b"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            let r = m.range
            let chunk = ns.substring(with: r)
            let words = chunk.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() }
            let nums = words.compactMap { digitWordMap[$0] }
            // Require strictly descending by 1.
            var isDescending = nums.count >= 3
            if isDescending {
                for i in 1..<nums.count where nums[i] != nums[i - 1] - 1 {
                    isDescending = false
                    break
                }
            }
            if r.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            if isDescending {
                out += nums.map(String.init).joined(separator: ", ")
            } else {
                out += chunk
            }
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// Regex find-and-replace with a block that takes capture groups
    /// (groups[0] = whole match, groups[1..] = capture groups).
    private static func replaceRegex(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive],
        _ transform: ([String]) -> String
    ) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let gr = m.range(at: i)
                if gr.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(ns.substring(with: gr))
                }
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // MARK: - Pass 12: Unit abbreviation

    /// `(\d+)\s+<unit-word>` -> `\1 <abbrev>` for common scientific units.
    /// Skips ambiguous single-letter units (`meters` -> `m`, `seconds` -> `s`).
    static let unitAbbreviations: [(pattern: String, replacement: String)] = [
        (#"(\d+)\s+milligrams?\b"#,    "$1 mg"),
        (#"(\d+)\s+micrograms?\b"#,    "$1 mcg"),
        (#"(\d+)\s+kilograms?\b"#,     "$1 kg"),
        (#"(\d+)\s+kilos\b"#,          "$1 kg"),
        (#"(\d+)\s+kilometers?\b"#,    "$1 km"),
        (#"(\d+)\s+millimeters?\b"#,   "$1 mm"),
        (#"(\d+)\s+centimeters?\b"#,   "$1 cm"),
        (#"(\d+)\s+milliliters?\b"#,   "$1 ml"),
        (#"(\d+)\s+liters?\b"#,        "$1 L"),
        (#"(\d+)\s+gigabytes?\b"#,     "$1 GB"),
        (#"(\d+)\s+megabytes?\b"#,     "$1 MB"),
        (#"(\d+)\s+kilobytes?\b"#,     "$1 KB"),
        (#"(\d+)\s+terabytes?\b"#,     "$1 TB"),
        (#"(\d+)\s+petabytes?\b"#,     "$1 PB"),
        (#"(\d+)\s+gigahertz\b"#,      "$1 GHz"),
        (#"(\d+)\s+megahertz\b"#,      "$1 MHz"),
        (#"(\d+)\s+kilohertz\b"#,      "$1 kHz"),
        (#"(\d+)\s+grams?\b"#,         "$1 g"),
        // Time units — ms / ns / μs were missing. These are extremely common
        // in technical dictation ("5 milliseconds", "200 nanoseconds").
        (#"(\d+)\s+milliseconds?\b"#,  "$1 ms"),
        (#"(\d+)\s+nanoseconds?\b"#,   "$1 ns"),
        (#"(\d+)\s+microseconds?\b"#,  "$1 μs"),
        (#"(\d+)\s+picoseconds?\b"#,   "$1 ps"),
        // Big-O / model scale — "4 billion parameter model" → "4B parameter model",
        // "1 trillion" → "1T", "300 million users" → "300M users". Keeps the
        // user's natural phrasing instead of expanding to "4,000,000,000".
        // Trailing word boundary required so we don't eat "billion dollar".
        (#"(\d+)\s+billion\b"#,        "$1B"),
        (#"(\d+)\s+trillion\b"#,       "$1T"),
        (#"(\d+(?:\.\d+)?)\s+million\b"#, "$1M"),
        // Computing speeds.
        (#"(\d+)\s+megabits?\s+per\s+second\b"#,  "$1 Mbps"),
        (#"(\d+)\s+gigabits?\s+per\s+second\b"#,  "$1 Gbps"),
        (#"(\d+)\s+kilobits?\s+per\s+second\b"#,  "$1 kbps"),
        (#"(\d+)\s+watts?\b"#,                    "$1 W"),
        (#"(\d+)\s+kilowatts?\b"#,                "$1 kW"),
        // Frames per second.
        (#"(\d+)\s+frames\s+per\s+second\b"#,     "$1 fps"),
        (#"(\d+)\s+fps\b"#,                       "$1 fps"),

        // ── Time ────────────────────────────────────────────────────
        (#"(\d+)\s+hours?\b"#,                    "$1h"),
        (#"(\d+)\s+minutes?\b"#,                  "$1 min"),
        (#"(\d+)\s+mins?\b"#,                     "$1 min"),
        (#"(\d+)\s+seconds?\b"#,                  "$1s"),
        (#"(\d+)\s+secs?\b"#,                     "$1s"),

        // ── Distance imperial ──────────────────────────────────────
        (#"(\d+)\s+miles?\b"#,                    "$1 mi"),
        (#"(\d+)\s+feet\b"#,                      "$1 ft"),
        (#"(\d+)\s+yards?\b"#,                    "$1 yd"),
        (#"(\d+)\s+inches\b"#,                    "$1 in"),

        // ── Weight imperial ────────────────────────────────────────
        (#"(\d+(?:\.\d+)?)\s+pounds?\b"#,         "$1 lb"),
        (#"(\d+(?:\.\d+)?)\s+ounces?\b"#,         "$1 oz"),

        // ── Volume imperial ────────────────────────────────────────
        (#"(\d+(?:\.\d+)?)\s+gallons?\b"#,        "$1 gal"),
        (#"(\d+(?:\.\d+)?)\s+pints?\b"#,          "$1 pt"),
        (#"(\d+(?:\.\d+)?)\s+quarts?\b"#,         "$1 qt"),
        (#"(\d+(?:\.\d+)?)\s+cups?\b"#,           "$1 cup"),
        (#"(\d+(?:\.\d+)?)\s+tablespoons?\b"#,    "$1 tbsp"),
        (#"(\d+(?:\.\d+)?)\s+teaspoons?\b"#,      "$1 tsp"),

        // ── Speed ──────────────────────────────────────────────────
        (#"(\d+)\s+miles?\s+per\s+hour\b"#,       "$1 mph"),
        (#"(\d+)\s+kilometers?\s+per\s+hour\b"#,  "$1 km/h"),
        (#"(\d+)\s+meters?\s+per\s+second\b"#,    "$1 m/s"),
        (#"(\d+)\s+knots?\b"#,                    "$1 kn"),

        // ── Temperature ────────────────────────────────────────────
        (#"(\d+)\s+degrees?\s+celsius\b"#,        "$1°C"),
        (#"(\d+)\s+degrees?\s+fahrenheit\b"#,     "$1°F"),
        (#"(\d+)\s+degrees?\s+kelvin\b"#,         "$1 K"),

        // ── Pressure ───────────────────────────────────────────────
        (#"(\d+)\s+psi\b"#,                       "$1 psi"),
        (#"(\d+)\s+bars?\b"#,                     "$1 bar"),
        (#"(\d+)\s+pascals?\b"#,                  "$1 Pa"),
        (#"(\d+)\s+atmospheres?\b"#,              "$1 atm"),

        // ── Energy / Power ─────────────────────────────────────────
        (#"(\d+(?:\.\d+)?)\s+kilowatt[\- ]hours?\b"#, "$1 kWh"),
        (#"(\d+(?:\.\d+)?)\s+kilocalories\b"#,    "$1 kcal"),
        (#"(\d+(?:\.\d+)?)\s+calories\b"#,        "$1 cal"),
        (#"(\d+(?:\.\d+)?)\s+joules?\b"#,         "$1 J"),

        // ── Battery / Electric ─────────────────────────────────────
        (#"(\d+)\s+volts?\b"#,                    "$1 V"),
        (#"(\d+)\s+amps?\b"#,                     "$1 A"),
        (#"(\d+)\s+amperes?\b"#,                  "$1 A"),
        (#"(\d+)\s+milliamps?\b"#,                "$1 mA"),
        (#"(\d+)\s+milliamp\s+hours\b"#,          "$1 mAh"),
        (#"(\d+)\s+mAh\b"#,                       "$1 mAh"),

        // ── Frequency / rotation ───────────────────────────────────
        (#"(\d+)\s+hertz\b"#,                     "$1 Hz"),
        (#"(\d+)\s+rpm\b"#,                       "$1 rpm"),
        (#"(\d+)\s+revolutions?\s+per\s+minute\b"#, "$1 rpm"),

        // ── Resolution / quality ───────────────────────────────────
        (#"(\d+)\s*p\s+resolution\b"#,            "$1p"),
        (#"\b720\s+p\b"#,                         "720p"),
        (#"\b1080\s+p\b"#,                        "1080p"),
        (#"\b1440\s+p\b"#,                        "1440p"),
        (#"\b4\s*k\s+resolution\b"#,              "4K"),
        (#"\b4\s*k\s+video\b"#,                   "4K video"),
        (#"\b8\s*k\s+resolution\b"#,              "8K"),

        // ── Common spoken file-size shortcuts ──────────────────────
        (#"(\d+(?:\.\d+)?)\s+gigs?\b"#,           "$1 GB"),
        (#"(\d+(?:\.\d+)?)\s+megs?\b"#,           "$1 MB"),
        (#"(\d+(?:\.\d+)?)\s+kilobytes?\b"#,      "$1 KB"),
        (#"(\d+(?:\.\d+)?)\s+terabytes?\b"#,      "$1 TB"),

        // ── Percentage (when not caught earlier) ───────────────────
        (#"(\d+(?:\.\d+)?)\s+percent\b"#,         "$1%"),

        // ── Ratios / versions ──────────────────────────────────────
        (#"\bv\s+(\d+)\s+point\s+(\d+)\s+point\s+(\d+)\b"#, "v$1.$2.$3"),
        (#"\bv\s+(\d+)\s+point\s+(\d+)\b"#,       "v$1.$2"),
        (#"\bversion\s+(\d+)\s+point\s+(\d+)\b"#, "v$1.$2"),
    ]

    /// Convert word-form numbers attached to common units directly to the
    /// abbreviated form, regardless of what the LLM or upstream conversion
    /// did. "five milliseconds" → "5ms", "four billion parameters" → "4B
    /// parameters", "three million users" → "3M users".
    ///
    /// Single-digit numbers (1-12) only — larger word-form numbers are rare
    /// adjacent to these units in real dictation.
    static func wordFormUnitPass(_ text: String) -> String {
        let wordToDigit: [String: String] = [
            "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
            "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
            "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
            "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
            "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80",
            "ninety": "90", "hundred": "100",
        ]
        let unitMap: [(unit: String, abbr: String, spaced: Bool)] = [
            // Time
            ("milliseconds?",  "ms",  true),
            ("microseconds?",  "μs",  true),
            ("nanoseconds?",   "ns",  true),
            ("hours?",         "h",   false),
            ("minutes?",       " min", false),
            ("seconds?",       "s",   false),
            // Scale suffixes
            ("billion",        "B",   false),
            ("trillion",       "T",   false),
            ("million",        "M",   false),
            ("thousand",       "K",   false),
            // Mass
            ("kilograms?",     "kg",  true),
            ("kilos",          "kg",  true),
            ("grams?",         "g",   true),
            ("pounds?",        "lb",  true),
            ("ounces?",        "oz",  true),
            // Bytes
            ("megabytes?",     "MB",  true),
            ("gigabytes?",     "GB",  true),
            ("kilobytes?",     "KB",  true),
            ("terabytes?",     "TB",  true),
            ("gigs",           "GB",  true),
            ("megs",           "MB",  true),
            // Distance
            ("kilometers?",    "km",  true),
            ("meters?",        "m",   true),
            ("centimeters?",   "cm",  true),
            ("millimeters?",   "mm",  true),
            ("miles?",         "mi",  true),
            ("feet",           "ft",  true),
            ("inches",         "in",  true),
            // Temperature
            ("degrees?\\s+celsius",     "°C",  false),
            ("degrees?\\s+fahrenheit",  "°F",  false),
            // Percentage
            ("percent",        "%",   false),
            // Frequency
            ("hertz",          " Hz", false),
            ("gigahertz",      " GHz",false),
            ("megahertz",      " MHz",false),
        ]
        let wordsAlt = wordToDigit.keys.sorted().joined(separator: "|")
        var s = text
        for (unit, abbr, spaced) in unitMap {
            let pattern = #"\b("# + wordsAlt + #")\s+"# + unit + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let word = ns.substring(with: match.range(at: 1)).lowercased()
                guard let digit = wordToDigit[word] else { continue }
                let replacement = spaced ? "\(digit) \(abbr)" : "\(digit)\(abbr)"
                s = (s as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return s
    }

    static func unitAbbreviationPass(_ text: String) -> String {
        var s = text
        for (pattern, replacement) in unitAbbreviations {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = s as NSString
            let r = NSRange(location: 0, length: ns.length)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: replacement)
        }
        return s
    }

    // MARK: - Pass 12b: Quarter abbreviation ("q one" → "Q1")

    static func quarterAbbreviationPass(_ text: String) -> String {
        let map: [(pattern: String, replacement: String)] = [
            (#"(?i)\bq(?:uarter)?\s+one\b"#, "Q1"),
            (#"(?i)\bq(?:uarter)?\s+two\b"#, "Q2"),
            (#"(?i)\bq(?:uarter)?\s+three\b"#, "Q3"),
            (#"(?i)\bq(?:uarter)?\s+four\b"#, "Q4"),
            (#"(?i)\bfirst\s+quarter\b"#, "Q1"),
            (#"(?i)\bsecond\s+quarter\b"#, "Q2"),
            (#"(?i)\bthird\s+quarter\b"#, "Q3"),
            (#"(?i)\bfourth\s+quarter\b"#, "Q4"),
        ]
        var s = text
        for (pattern, replacement) in map {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            let r = NSRange(s.startIndex..., in: s)
            s = rx.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: replacement)
        }
        return s
    }

    // MARK: - Pass 12c: Spoken URL/email reconstruction
    //
    // Converts verbally spelled-out URLs and emails into proper format.
    // "admin at example dot com" → "admin@example.com"
    // "postgres slash slash admin at db dot staging dot example dot com slash myapp underscore staging"
    //   → "postgres://admin@db.staging.example.com/myapp_staging"
    //
    // Conservative: requires email local-parts to be 4+ chars to avoid matching
    // English prepositions ("is at", "lives at") as email addresses.

    static func spokenUrlReconstructionPass(_ text: String) -> String {
        var s = text

        // Stage 1: Email addresses — "localpart at domain.tld"
        // Require localpart ≥4 chars to avoid "is at …", "it at …", "in at …" false positives.
        s = replaceRegex(
            s,
            pattern: #"(?<![/@.\w])([A-Za-z0-9][A-Za-z0-9.+\-]{3,})\s+at\s+([A-Za-z0-9]+(?:\s+dot\s+[A-Za-z0-9]+)+)\b"#,
            options: []
        ) { groups in
            let local = groups[1]
            let domainParts = groups[2]
                .components(separatedBy: " dot ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return "\(local)@\(domainParts.joined(separator: "."))"
        }

        // Stage 2: URL schemes — "scheme colon slash [slash]" → "scheme://"
        s = replaceRegex(
            s,
            pattern: #"\b(https?|postgres|ftp|ssh|mongodb|redis|file|sftp|smb|ws|wss)\s+colon\s+slash(?:\s+slash)?\s*"#
        ) { groups in "\(groups[1].lowercased())://" }

        // Stage 2b: postgres/mongodb bare slash (model sometimes drops "colon")
        s = replaceRegex(
            s,
            pattern: #"\b(postgres|mongodb|redis|file|sftp|smb|ws|wss)\s+slash(?:\s+slash)?\s+"#
        ) { groups in "\(groups[1].lowercased())://" }

        // Stage 2c: "scheme double point slash" or "scheme double dot slash"
        // — speaker pronouncing "://" as "double point/" or "double dot/"
        s = replaceRegex(
            s,
            pattern: #"\b(https?|http|postgres|ftp|ssh|file)\s+double\s+(?:point|dot|colon)\s*/?"#
        ) { groups in "\(groups[1].lowercased())://" }

        // Stage 2d: standalone "double point" or "double dot" inside a URL-like
        // span → just "." (speaker emphasizing two dots, e.g. "github double dot com")
        s = replaceRegex(s, pattern: #"\bdouble\s+(?:point|dot)\b"#) { _ in "." }

        // Stage 2e: spoken query strings — "question mark X equals Y"
        // → "?X=Y". Handles "?s=46" type tracking params.
        s = replaceRegex(
            s,
            pattern: #"\bquestion\s+mark\s+([a-zA-Z]+)\s+equals\s+(\w+)\b"#
        ) { groups in "?\(groups[1])=\(groups[2])" }

        // Stage 2f: spoken ampersand-separated extra params — "ampersand X equals Y"
        s = replaceRegex(
            s,
            pattern: #"\bampersand\s+([a-zA-Z]+)\s+equals\s+(\w+)\b"#
        ) { groups in "&\(groups[1])=\(groups[2])" }

        // Stage 3–5: iteratively resolve dot / slash / underscore within URL spans
        let urlBodyChars = #"[A-Za-z0-9@.\-/_~%&?=+]"#
        for _ in 0..<10 {
            let before = s
            // dot inside URL
            s = replaceRegex(s,
                pattern: "(://\(urlBodyChars)+)\\s+dot\\s+([A-Za-z0-9\\-]+)",
                options: []
            ) { g in "\(g[1]).\(g[2])" }
            // slash inside URL
            s = replaceRegex(s,
                pattern: "(://\(urlBodyChars)+)\\s+slash\\s+([A-Za-z0-9\\-]+)",
                options: []
            ) { g in "\(g[1])/\(g[2])" }
            // underscore inside URL
            s = replaceRegex(s,
                pattern: "(://\(urlBodyChars)+[A-Za-z0-9])\\s+underscore\\s+([A-Za-z0-9]+)",
                options: []
            ) { g in "\(g[1])_\(g[2])" }
            if s == before { break }
        }

        // Stage 6: "v one/two/.../nine" → "v1/v2/.." in path/version context
        let numWords = ["one":"1","two":"2","three":"3","four":"4",
                        "five":"5","six":"6","seven":"7","eight":"8","nine":"9"]
        s = replaceRegex(s,
            pattern: #"(?<=[/. ])v\s+(one|two|three|four|five|six|seven|eight|nine)\b"#
        ) { g in "v\(numWords[g[1].lowercased()] ?? g[1])" }

        // Stage 7: Standalone spoken domains ending in a known TLD
        // "staging dot example dot com" → "staging.example.com"
        let knownTLDs = "com|org|net|io|dev|co|ai|app|edu|gov|uk|de|fr|nl"
        s = replaceRegex(s,
            pattern: "\\b([A-Za-z0-9][A-Za-z0-9\\-]*(?:\\s+dot\\s+[A-Za-z0-9][A-Za-z0-9\\-]*)+)\\s+dot\\s+(\(knownTLDs))\\b",
            options: []
        ) { g in
            let parts = g[1].components(separatedBy: " dot ").map { $0.trimmingCharacters(in: .whitespaces) }
            return (parts + [g[2]]).joined(separator: ".")
        }

        return s
    }

    // MARK: - Pass 13: Time format (HHMM -> HH:MM)

    /// Convert a 4-digit number to HH:MM when surrounding context makes it
    /// clearly a clock time. Requires HH<24 and MM<60 AND a context marker.
    /// Conservative — bare 4-digit numbers (years, area codes, dollar
    /// amounts, etc.) are left alone.
    static func timeFormatPass(_ text: String) -> String {
        var s = text

        // Helper: apply a regex that has one captured 4-digit group, validating
        // HH<24 and MM<60. The template is built per-match.
        func applyPattern(_ pattern: String, digitGroupIndex: Int, buildReplacement: (String, [String]) -> String?) -> String {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
            let ns = s as NSString
            let matches = rx.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return s }
            var out = ""
            var cursor = 0
            for m in matches {
                var groups: [String] = []
                for i in 0..<m.numberOfRanges {
                    let r = m.range(at: i)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
                let r = m.range
                if r.location > cursor {
                    out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                }
                let digits = groups[digitGroupIndex]
                if digits.count == 4,
                   let hh = Int(digits.prefix(2)),
                   let mm = Int(digits.suffix(2)),
                   hh < 24, mm < 60,
                   let rep = buildReplacement(String(format: "%02d:%02d", hh, mm), groups) {
                    out += rep
                } else {
                    out += groups[0]
                }
                cursor = r.location + r.length
            }
            if cursor < ns.length {
                out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            }
            return out
        }

        // Pattern A: pre-marker + 4 digits, NOT preceded by digit/colon/$/.
        // and not followed by a digit or colon.
        let preMarkerPattern = #"(?<![\d:$.])\b(at about|at|around|by)\s+(\d{4})(?![\d:])"#
        s = applyPattern(preMarkerPattern, digitGroupIndex: 2) { time, groups in
            return groups[1] + " " + time
        }

        // Pattern B: 4 digits + post-marker.
        let postMarkerPattern = #"(?<![\d:$.])(\d{4})(\s+(?:on\s+|am\b|pm\b|a\.m\.|p\.m\.|o'clock\b|o\u{2019}clock\b))"#
        s = applyPattern(postMarkerPattern, digitGroupIndex: 1) { time, groups in
            return time + groups[2]
        }

        return s
    }

    // MARK: - Spoken file paths and extensions

    /// Reconstruct spoken file paths and file extensions:
    ///   "downloads slash project slash readme dot md"
    ///     → "Downloads/project/readme.md"
    ///   "save it as report dot pdf"
    ///     → "save it as report.pdf"
    ///   "config dot json"
    ///     → "config.json"
    /// Conservative — only fires when the word adjacent to "dot" looks like
    /// a filename token (lowercase alphanumeric) and the extension is in
    /// the allowlist below. Avoids mangling "config dot js says..." into
    /// "config.js says...".
    static func spokenFilePathPass(_ text: String) -> String {
        // Known file extensions worth reconstructing. Keep conservative —
        // missing one is harmless, false-positive matches break prose.
        let extensions = [
            // Documents
            "txt", "md", "mdx", "rtf", "doc", "docx", "pdf", "csv", "tsv",
            "pages", "key", "numbers", "odt", "ods", "odp", "epub", "mobi", "azw",
            // Data / config
            "json", "jsonl", "ndjson", "yaml", "yml", "toml", "xml", "ini", "cfg",
            "conf", "properties", "env", "lock", "log",
            // Markup / web
            "html", "htm", "xhtml", "css", "scss", "sass", "less", "stylus",
            // JS / TS ecosystem
            "js", "mjs", "cjs", "ts", "mts", "cts", "tsx", "jsx", "vue", "svelte", "astro",
            // General programming
            "py", "rb", "go", "rs", "java", "kt", "kts", "swift", "m", "mm",
            "c", "cpp", "cc", "cxx", "h", "hpp", "hh", "hxx", "cs", "fs", "vb",
            "php", "lua", "pl", "erl", "ex", "exs", "clj", "scala", "groovy",
            "sh", "zsh", "bash", "fish", "ps1",
            // Database
            "sql", "db", "sqlite", "sqlite3", "graphql", "proto", "thrift",
            // Image
            "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "avif",
            "tiff", "tif", "heic", "heif", "jxl", "raw", "psd", "ai", "eps",
            // Audio
            "mp3", "wav", "flac", "ogg", "m4a", "aac", "opus", "wma", "aiff",
            // Video
            "mp4", "mov", "avi", "mkv", "webm", "wmv", "flv", "m4v", "3gp",
            // Archives
            "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "dmg", "pkg",
            "deb", "rpm", "iso",
            // Dotfile / data interchange
            "csv", "tsv", "parquet", "avro", "orc", "arrow",
        ]
        let extAlt = extensions.joined(separator: "|")

        var s = text

        // Stage 1: "FILENAME dot EXTENSION" → "FILENAME.EXTENSION"
        // Filename must be lowercase alphanumeric (3+ chars) to avoid
        // matching prose like "I went to the doc dot but..."
        let extPattern = #"\b([a-z][a-z0-9_\-]{1,})\s+dot\s+("# + extAlt + #")\b"#
        s = replaceRegex(s, pattern: extPattern, options: [.caseInsensitive]) { groups in
            return "\(groups[1].lowercased()).\(groups[2].lowercased())"
        }

        // Stage 2: Path segments — "PARENT slash CHILD slash filename.ext"
        // Iterate to absorb 2-4 segment paths. Only fires when the chain
        // ends with a reconstructed extension from Stage 1 (so we don't
        // mangle "five slash ten" as a path).
        for _ in 0..<4 {
            let pathPattern = #"\b([A-Za-z][A-Za-z0-9_\-]*)\s+slash\s+([A-Za-z0-9_\-]+(?:\.[a-z0-9]{1,5})?)\b"#
            let before = s
            s = replaceRegex(s, pattern: pathPattern, options: []) { groups in
                // Capitalize known top-level folder names so "downloads" → "Downloads",
                // "desktop" → "Desktop", "documents" → "Documents", "home" → "~",
                // but leave "src" / "lib" / arbitrary subdirs as-is.
                let parent = groups[1]
                let topLevelCaps: [String: String] = [
                    "downloads": "Downloads",
                    "desktop": "Desktop",
                    "documents": "Documents",
                    "applications": "Applications",
                    "users": "Users",
                    "library": "Library",
                    "movies": "Movies",
                    "music": "Music",
                    "pictures": "Pictures",
                    "public": "Public",
                    "shared": "Shared",
                ]
                let parentOut = topLevelCaps[parent.lowercased()] ?? parent
                return "\(parentOut)/\(groups[2])"
            }
            if s == before { break }
        }

        // Stage 3: Tilde-rooted path — "tilde slash X" → "~/X"
        s = replaceRegex(s, pattern: #"\btilde\s+slash\s+"#, options: [.caseInsensitive]) { _ in "~/" }

        return s
    }

    // MARK: - Implicit list detection
    //
    // When the speaker says "I have to get X, Y, Z, and W" with 3+ short
    // items, render as a bullet list instead of inline prose. This is the
    // pattern Wispr Flow nails and we keep missing.

    /// Detects cue phrase + 3+ short comma-separated items + final "and X"
    /// and converts to a markdown bullet list.
    static func implicitListPass(_ text: String) -> String {
        // Cue phrases that strongly imply a list will follow.
        let cuePhrases = [
            "i need", "i have to get", "i have to do", "i gotta get",
            "i want", "i need to buy", "i need to grab",
            "things to do", "things to get", "things to buy",
            "make a list", "grocery list", "shopping list", "to-do list",
            "the list is", "the list", "the items are", "the ingredients are",
            "i need to remember", "remind me to get", "remind me to buy",
            // Explicit list signaling — speaker literally says "list"
            "bullet point list", "bulleted list", "numbered list",
            "test list", "a list", "list is", "items are",
            // Research / brainstorm contexts
            "research", "research:", "by the way research",
            "look into", "things to research",
        ]

        // Capture: (cue)(separator: colon | "like" | comma)(item list)(. or end)
        // Each item is 1-4 words. List has 3+ items joined by commas and
        // an optional "and" before the last.
        let cueAlt = cuePhrases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let itemPattern = #"[A-Za-z][A-Za-z\s'\-]{1,40}?"#  // non-greedy 1-40 chars
        // sep: optional colon/comma, optional "like", optional "of"
        let sepPattern = #"\s*(?::|,?\s+like|,)\s*"#

        // Full pattern: cue + sep + first item + (, item){2,} + (,? and item)? + terminal punct
        let listPattern = #"(?i)\b("# + cueAlt + #")"# + sepPattern +
            #"("# + itemPattern + #")"# +
            #"(?:,\s*("# + itemPattern + #"))"# +
            #"(?:,\s*("# + itemPattern + #"))"# +
            #"(?:,?\s+and\s+("# + itemPattern + #"))?"# +
            #"(?=[.!?\n]|$)"#

        guard let regex = try? NSRegularExpression(pattern: listPattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        guard !matches.isEmpty else { return text }

        var result = text
        // Apply in reverse so indices stay valid.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 5 else { continue }
            let cueRange = match.range(at: 1)
            guard cueRange.location != NSNotFound else { continue }
            let cue = (result as NSString).substring(with: cueRange)

            var items: [String] = []
            for i in 2..<match.numberOfRanges {
                let r = match.range(at: i)
                if r.location == NSNotFound { continue }
                let item = (result as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip items that are too long (more than ~4 words) — likely
                // prose, not a list item.
                let wordCount = item.split(separator: " ").count
                if wordCount > 4 || item.isEmpty { items = []; break }
                items.append(item)
            }
            // Need at least 3 items for a list to be worth bulleting.
            guard items.count >= 3 else { continue }

            let bulletList = "\(cue):\n" + items.map { "- \($0)" }.joined(separator: "\n")
            result = (result as NSString).replacingCharacters(in: match.range, with: bulletList)
            print("[VOICE-POST] implicit-list: \(items.count) items detected after \"\(cue)\"")
        }
        return result
    }

    // MARK: - Homophone correction
    //
    // ASR routinely produces the wrong homophone. These are context-light
    // substitutions — apply only when the OTHER spelling fits the
    // surrounding grammar better.

    static func homophonePass(_ text: String) -> String {
        var s = text
        // Specific high-confidence patterns. Each one is a phrase
        // substitution to keep false positives low.
        let pairs: [(pattern: String, replacement: String)] = [
            // ── Modal "of" → "have"  (always safe)
            (#"\b(could|should|would|might|must)\s+of\b"#, "$1 have"),

            // ── "your" → "you're"
            (#"\bYour\s+(welcome|right|wrong|going|gonna|coming|here|there|not)\b"#, "You're $1"),
            (#"\byour\s+(welcome|right|wrong|going|gonna|coming|here|there|not)\b"#, "you're $1"),

            // ── "their" → "they're"
            (#"\bTheir\s+(going|gonna|coming|here|there|right|wrong|not)\b"#, "They're $1"),
            (#"\btheir\s+(going|gonna|coming|here|there|right|wrong|not)\b"#, "they're $1"),

            // ── "its" → "it's"
            (#"\bIts\s+(a|an|the|just|going|gonna|been|too|so|really|very|important|fine|okay|ok|good|bad|cool|amazing|terrible|here|there|not|been|always|never)\b"#, "It's $1"),
            (#"\bits\s+(a|an|the|just|going|gonna|been|too|so|really|very|important|fine|okay|ok|good|bad|cool|amazing|terrible|here|there|not|been|always|never)\b"#, "it's $1"),

            // ── "to" → "too" before adjective/adverb
            (#"\bto\s+(many|much|big|small|loud|quiet|fast|slow|hot|cold|expensive|cheap|long|short|hard|easy|early|late|good|bad|tired|busy)\b"#, "too $1"),

            // ── "use to" → "used to" (past habit)
            (#"\b(I|we|they|you|he|she)\s+use\s+to\s+"#, "$1 used to "),

            // ── Compound words that should not be compound
            (#"\balot\b"#, "a lot"),
            (#"\bthankyou\b"#, "thank you"),

            // ── Common phrase corrections (always safe)
            (#"\bfor\s+all\s+intensive\s+purposes\b"#, "for all intents and purposes"),
            (#"\bnip\s+it\s+in\s+the\s+butt\b"#, "nip it in the bud"),
            (#"\bpeek\s+(my|your|his|her|their)\s+interest\b"#, "piqued $1 interest"),
            (#"\bbaited\s+breath\b"#, "bated breath"),
            (#"\bdeep\s+seeded\b"#, "deep-seated"),
            (#"\bwet\s+(my|your|his|her|their|the)\s+appetite\b"#, "whet $1 appetite"),
            (#"\bbeckon\s+call\b"#, "beck and call"),
            (#"\bpass\s+mustard\b"#, "pass muster"),
            (#"\bone\s+in\s+the\s+same\b"#, "one and the same"),
            (#"\bdoggy\s+dog\b"#, "dog-eat-dog"),
            (#"\ba\s+whole\s+nother\b"#, "a whole other"),
            (#"\bthrows\s+of\s+passion\b"#, "throes of passion"),
            (#"\bescape\s+goat\b"#, "scapegoat"),
            (#"\bpiece\s+of\s+mind\b"#, "peace of mind"),

            // ── Common typo / mishearing fixes
            (#"\bexpresso\b"#, "espresso"),
            (#"\bsupposably\b"#, "supposedly"),
            (#"\bExpresso\b"#, "Espresso"),
            (#"\bSupposably\b"#, "Supposedly"),

            // ── "where" → "we're" in clear contexts ("where going" → "we're going")
            (#"\bWhere\s+(going|gonna|coming)\b"#, "We're $1"),
            (#"\bwhere\s+(going|gonna|coming)\b"#, "we're $1"),

            // ── "weather/whether" — only safe in "weather or not" → "whether or not"
            (#"\bweather\s+or\s+not\b"#, "whether or not"),
            (#"\bWeather\s+or\s+not\b"#, "Whether or not"),
        ]
        for (pattern, replacement) in pairs {
            s = replaceRegex(s, pattern: pattern, options: []) { groups in
                // Build replacement using the captured groups
                var result = replacement
                for i in 1..<groups.count {
                    result = result.replacingOccurrences(of: "$\(i)", with: groups[i])
                }
                return result
            }
        }
        return s
    }

    // MARK: - Spoken hashtags
    //
    // "hashtag X" → "#X"
    // "hashtag X Y Z" → "#XYZ"  (combine words into single hashtag)
    // Conservative: requires "hashtag" as the literal cue word.

    static func spokenHashtagPass(_ text: String) -> String {
        var s = text
        // "hashtag word1 word2 word3" (up to 3 words) → "#word1word2word3"
        // Capture up to 3 following words; ASR often runs them together
        // but we should still squash multi-word hashtag intent.
        s = replaceRegex(
            s,
            pattern: #"\bhashtag\s+([a-zA-Z][a-zA-Z0-9]*)(?:\s+([a-zA-Z][a-zA-Z0-9]*))?(?:\s+([a-zA-Z][a-zA-Z0-9]*))?(?=[\s.,;!?]|$)"#,
            options: [.caseInsensitive]
        ) { groups in
            var combined = groups[1].lowercased()
            if groups.count > 2 && !groups[2].isEmpty { combined += groups[2].lowercased() }
            if groups.count > 3 && !groups[3].isEmpty { combined += groups[3].lowercased() }
            return "#\(combined)"
        }
        return s
    }

    // MARK: - Spoken math operators
    //
    // "5 plus 3 equals 8" → "5 + 3 = 8"
    // "10 minus 5" → "10 - 5"
    // "2 times 4" → "2 × 4" (or 2 * 4 if you prefer ASCII)
    // "10 divided by 2" → "10 / 2"
    // Only fires when BOTH sides are digits — avoids mangling "five times faster"
    // (no second digit). Also only triggers between bare numbers.

    static func spokenMathOperatorPass(_ text: String) -> String {
        var s = text
        let ops: [(spoken: String, written: String)] = [
            ("plus",       "+"),
            ("minus",      "-"),
            ("times",      "×"),
            ("multiplied\\s+by", "×"),
            ("divided\\s+by",    "/"),
            ("over",       "/"),   // only between two numbers (denominator implied)
            ("equals",     "="),
            ("equal\\s+to","="),
        ]
        for (spoken, written) in ops {
            let pattern = #"(?<![\w%$])(\d+(?:\.\d+)?)\s+"# + spoken + #"\s+(\d+(?:\.\d+)?)(?![\w%$])"#
            s = replaceRegex(s, pattern: pattern, options: [.caseInsensitive]) { groups in
                return "\(groups[1]) \(written) \(groups[2])"
            }
        }
        return s
    }

    // MARK: - Spoken currency
    //
    // "200 dollars" → "$200"; "five hundred euros" → "€500"; etc.
    // Only fires when the number is already digit-form and followed by a
    // currency word. Avoids matching "dollar value" / "pound cake" / etc.

    static func spokenCurrencyPass(_ text: String) -> String {
        var s = text
        // Pattern: digit-form number, optional decimal, currency word, no
        // preceding currency symbol.
        let map: [(name: String, symbol: String)] = [
            ("us\\s+dollars?",     "$"),
            ("usd",                "$"),
            ("dollars?",           "$"),
            ("euros?",             "€"),
            ("eur",                "€"),
            ("pounds?\\s+sterling","£"),
            ("british\\s+pounds?", "£"),
            ("pounds?",            "£"),
            ("gbp",                "£"),
            ("yen",                "¥"),
            ("jpy",                "¥"),
            ("rupees?",            "₹"),
            ("inr",                "₹"),
            ("francs?",            "CHF "),
            ("yuan",               "¥"),
            ("rmb",                "¥"),
        ]
        for (name, symbol) in map {
            // Pre-condition: number not already preceded by a currency symbol
            let pattern = #"(?<![\$€£¥₹])\b(\d+(?:,\d{3})*(?:\.\d+)?)\s+"# + name + #"\b"#
            s = replaceRegex(s, pattern: pattern, options: [.caseInsensitive]) { groups in
                return "\(symbol)\(groups[1])"
            }
        }
        return s
    }

    // MARK: - Spoken dates
    //
    // "March 15th 2026" → "March 15, 2026"
    // "the 3rd of December" → "December 3"
    // "December the 3rd" → "December 3"
    // Note: standalone ordinals in non-date contexts are left alone — only
    // fires when a month name is adjacent.

    static func spokenDatePass(_ text: String) -> String {
        var s = text
        let months = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec"

        // "March 15th, 2026" or "March 15th 2026" → "March 15, 2026"
        s = replaceRegex(
            s,
            pattern: #"\b("# + months + #")\s+(\d{1,2})(?:st|nd|rd|th)?(?:,\s*|\s+)(\d{4})\b"#,
            options: [.caseInsensitive]
        ) { groups in
            return "\(groups[1]) \(groups[2]), \(groups[3])"
        }

        // "March 15th" → "March 15"  (no year)
        s = replaceRegex(
            s,
            pattern: #"\b("# + months + #")\s+(\d{1,2})(?:st|nd|rd|th)\b"#,
            options: [.caseInsensitive]
        ) { groups in
            return "\(groups[1]) \(groups[2])"
        }

        // "the 3rd of December" → "December 3"
        s = replaceRegex(
            s,
            pattern: #"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+of\s+("# + months + #")\b"#,
            options: [.caseInsensitive]
        ) { groups in
            return "\(groups[2]) \(groups[1])"
        }

        // "December the 3rd" → "December 3"
        s = replaceRegex(
            s,
            pattern: #"\b("# + months + #")\s+the\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
            options: [.caseInsensitive]
        ) { groups in
            return "\(groups[1]) \(groups[2])"
        }

        return s
    }

    // MARK: - Spoken dotfiles
    //
    // "dot gitignore" → ".gitignore"
    // "dot env local" → ".env.local"
    // "dot eslintrc json" → ".eslintrc.json"

    static func spokenDotfilePass(_ text: String) -> String {
        var s = text

        // Compound dotfiles first (need to match before generic "dot WORD")
        let compounds: [(spoken: String, written: String)] = [
            ("dot\\s+env\\s+local",         ".env.local"),
            ("dot\\s+env\\s+test",          ".env.test"),
            ("dot\\s+env\\s+production",    ".env.production"),
            ("dot\\s+env\\s+development",   ".env.development"),
            ("dot\\s+env\\s+staging",       ".env.staging"),
            ("dot\\s+eslintrc\\s+json",     ".eslintrc.json"),
            ("dot\\s+eslintrc\\s+js",       ".eslintrc.js"),
            ("dot\\s+prettierrc\\s+json",   ".prettierrc.json"),
            ("dot\\s+babelrc\\s+json",      ".babelrc.json"),
            ("dot\\s+github\\s+workflows",  ".github/workflows"),
            ("dot\\s+vscode",               ".vscode"),
            ("dot\\s+idea",                 ".idea"),
            ("dot\\s+d\\s+t\\s+s",          ".d.ts"),
            ("dot\\s+d\\s+ts",              ".d.ts"),
        ]
        for (spoken, written) in compounds {
            s = replaceRegex(s, pattern: "\\b" + spoken + "\\b", options: [.caseInsensitive]) { _ in written }
        }

        // Simple dotfiles
        let simple = [
            "gitignore", "env", "eslintrc", "prettierrc", "babelrc",
            "dockerignore", "nvmrc", "editorconfig", "gitattributes",
            "gitmodules", "npmrc", "yarnrc", "ruby-version", "python-version",
            "DS_Store", "htaccess", "tool-versions",
        ]
        for name in simple {
            let pattern = #"\bdot\s+"# + name + #"\b"#
            s = replaceRegex(s, pattern: pattern, options: [.caseInsensitive]) { _ in ".\(name)" }
        }

        return s
    }

    // MARK: - Negative numbers
    //
    // "negative 5" / "minus 5" → "-5". Only when followed by a digit.
    // "minus 12 degrees" → "-12 degrees" (then unit pass handles °)

    static func negativeNumberPass(_ text: String) -> String {
        var s = text
        s = replaceRegex(
            s,
            pattern: #"(?<![\w.])(?:negative|minus)\s+(\d+(?:\.\d+)?)\b"#,
            options: [.caseInsensitive]
        ) { groups in
            return "-\(groups[1])"
        }
        return s
    }

    // MARK: - Spoken fractions
    //
    // "half a cup" → "½ cup", "two thirds" → "2/3", "three quarters" → "3/4"

    static func spokenFractionPass(_ text: String) -> String {
        var s = text
        // Unicode fractions for common ones
        let unicode: [(spoken: String, symbol: String)] = [
            ("one\\s+half",        "½"),
            ("a\\s+half",          "½"),
            ("one\\s+third",       "⅓"),
            ("two\\s+thirds",      "⅔"),
            ("one\\s+quarter",     "¼"),
            ("a\\s+quarter",       "¼"),
            ("three\\s+quarters",  "¾"),
            ("one\\s+eighth",      "⅛"),
            ("three\\s+eighths",   "⅜"),
            ("five\\s+eighths",    "⅝"),
            ("seven\\s+eighths",   "⅞"),
        ]
        // Only fire when followed by a unit/noun word (cup, tablespoon, mile,
        // etc.) to avoid mangling "half the team" / "two thirds of the way".
        let followingContext = #"(?=\s+(?:cup|cups|tablespoon|tsp|teaspoon|tbsp|pound|ounce|gallon|liter|mile|inch|foot|meter|hour|minute|second|day|week|month|year|kilometer|kilogram))"#
        for (spoken, symbol) in unicode {
            let pattern = #"\b"# + spoken + followingContext
            s = replaceRegex(s, pattern: pattern, options: [.caseInsensitive]) { _ in symbol }
        }
        // "half a cup" idiom — "half" without "one"/"a" before, but with "a cup" after
        s = replaceRegex(s, pattern: #"\bhalf\s+a\s+(cup|tablespoon|teaspoon|pound|gallon|liter|mile|hour)\b"#, options: [.caseInsensitive]) { groups in
            "½ \(groups[1])"
        }
        return s
    }

    // MARK: - Dash strip (post-LLM)
    //
    // The LLM keeps emitting em-dashes (—) and en-dashes (–) for dramatic
    // pauses despite the prompt explicitly banning them. We strip every
    // occurrence, converting to comma in most cases and period when the
    // following clause looks like a sentence start (capital + 4+ words).
    //
    // Why comma as default: em-dashes in casual prose are usually appositive
    // ("X — which I think is important — happens"). A comma reads more
    // naturally than a forced period. The period branch only fires when
    // the model used the dash to join two clear sentences.

    static func stripDashesPass(_ text: String) -> String {
        // Belt-and-suspenders enforcement: the prompt bans em-dashes and
        // en-dashes, but Qwen3 still emits them on long inputs. This pass is
        // deterministic and unconditional: every `\u{2014}` / `\u{2013}` /
        // `\u{2015}` / `\u{2012}` becomes ". " + capitalized next word.
        //
        // Why period-and-capital (was: comma, sometimes period): the user's
        // explicit preference. Restarting the sentence reads cleanly across
        // both appositive and clause-joining usages — a comma after "tired"
        // in "I'm tired, I've been working" is a comma splice; the period
        // form ("I'm tired. I've been working.") is correct prose either way.
        //
        // We also LOG every replacement so we know the prompt failed for this
        // input — surfaces prompt regressions in the rolling Console output.
        let dashChars: [Character] = ["\u{2014}", "\u{2013}", "\u{2015}", "\u{2012}"]

        // Fast path: no dashes? skip entirely (single linear scan).
        guard text.contains(where: { dashChars.contains($0) }) else { return text }

        var replacementCount = 0
        var result = ""
        result.reserveCapacity(text.count)

        // Two-state machine: when we see a dash (possibly surrounded by
        // whitespace), emit ". " and flip `capitalizeNext` to true so the
        // first letter character we then encounter gets uppercased.
        let chars = Array(text)
        var i = 0
        var capitalizeNext = false
        while i < chars.count {
            let ch = chars[i]
            if dashChars.contains(ch) {
                // Trim trailing whitespace already emitted (so "tired — I" → "tired. I"
                // not "tired . I"). Walk back over spaces we just wrote.
                while result.last == " " || result.last == "\t" {
                    result.removeLast()
                }
                // Drop the trailing comma if any (e.g. ", —" patterns).
                if result.last == "," {
                    result.removeLast()
                }
                result.append(". ")
                replacementCount += 1
                capitalizeNext = true
                // Skip the dash and any following whitespace.
                i += 1
                while i < chars.count, chars[i].isWhitespace, chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                // If we hit non-letter non-space mid-flight (digit, punctuation),
                // stop trying to capitalize — the "next word" was non-alpha.
                if !ch.isWhitespace { capitalizeNext = false }
            }
            i += 1
        }

        if replacementCount > 0 {
            print("[VOICE-POLISH] stripDashesPass: replaced \(replacementCount) dash(es) with period+capital — prompt failed for this input")
        }

        // Clean up artifacts: double periods (".. "), double commas.
        var s = result
        s = s.replacingOccurrences(of: ".. ", with: ". ")
        s = s.replacingOccurrences(of: ". .", with: ".")
        s = s.replacingOccurrences(of: ", ,", with: ",")
        s = s.replacingOccurrences(of: ",,", with: ",")
        s = s.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return s
    }

    // MARK: - Strip emojis (belt-and-suspenders)
    //
    // The prompt bans emojis, but Qwen3 still emits them on some inputs
    // (especially short conversational dictations). This pass deterministically
    // strips every Unicode scalar in the Extended_Pictographic class, plus
    // common symbol blocks the property test misses (variation selectors,
    // zero-width joiners chained between pictographs, regional indicator pairs).

    /// Strips any emoji or symbol pictograph that survived earlier passes.
    /// Hard rule: polish output must never contain emojis. Cloud model
    /// occasionally leaks them through ("Excited" personality or when the
    /// dictation contains emoji-evoking phrases). This is the last defense
    /// and is wired as the absolute final pass in `process(_:options:)`.
    ///
    /// Implementation note: this is the public API surface for the strip.
    /// It delegates to `stripEmojiPass` which is the well-tested
    /// implementation (handles ZWJ chains, skin-tone modifiers, regional
    /// indicator pairs, variation selectors, and tidies the surrounding
    /// whitespace artifacts). Logs `[VOICE-POLISH-STRIP] removed N emoji
    /// codepoints` when it strips anything so prompt regressions surface
    /// in the Console.
    public static func stripEmojis(_ text: String) -> String {
        let before = text
        let after = stripEmojiPass(text)
        if before != after {
            // Count actually-removed pictographic scalars (not just length
            // delta, since the pass also tidies trailing spaces).
            let beforePictographs = before.unicodeScalars.reduce(0) { acc, s in
                acc + (isPictographicScalar(s) ? 1 : 0)
            }
            let afterPictographs = after.unicodeScalars.reduce(0) { acc, s in
                acc + (isPictographicScalar(s) ? 1 : 0)
            }
            let removed = max(0, beforePictographs - afterPictographs)
            if removed > 0 {
                print("[VOICE-POLISH-STRIP] removed \(removed) emoji codepoints")
            }
        }
        return after
    }
    //
    // Logs every replacement so prompt regressions surface in the Console.

    static func stripEmojiPass(_ text: String) -> String {
        // Fast path: no non-ASCII bytes outside common punctuation? skip.
        var hasCandidate = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmojiPresentation
                || scalar.properties.isEmoji
                || isPictographicScalar(scalar)
                || scalar.value == 0x200D  // ZWJ
                || (scalar.value >= 0xFE00 && scalar.value <= 0xFE0F) // variation selectors
            {
                // Filter false positives: digits, asterisk, hash, copyright,
                // trademark, etc. ARE marked Emoji=Yes by Unicode. We only want
                // to strip pictographs.
                if isPictographicScalar(scalar) {
                    hasCandidate = true
                    break
                }
            }
        }
        guard hasCandidate else { return text }

        var stripped = 0
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if isPictographicScalar(s) {
                stripped += 1
                // Consume the entire emoji sequence: skip following ZWJ-joined
                // pictographs, skin-tone modifiers, variation selectors,
                // keycap sequences, regional indicators (flag pairs).
                i += 1
                while i < scalars.count {
                    let nxt = scalars[i]
                    if nxt.value == 0x200D {
                        // ZWJ: consume and continue (next scalar joined to seq).
                        i += 1
                        continue
                    }
                    if nxt.value >= 0xFE00 && nxt.value <= 0xFE0F {
                        // Variation selector.
                        i += 1
                        continue
                    }
                    if nxt.value >= 0x1F3FB && nxt.value <= 0x1F3FF {
                        // Skin tone modifier.
                        i += 1
                        continue
                    }
                    if nxt.value >= 0x1F1E6 && nxt.value <= 0x1F1FF {
                        // Regional indicator (flag pair). Consume one extra if next is also RI.
                        i += 1
                        continue
                    }
                    if isPictographicScalar(nxt) {
                        // Another pictograph in the same sequence (rare without ZWJ but possible).
                        i += 1
                        continue
                    }
                    break
                }
                continue
            }
            // Stray ZWJ / variation selector outside a pictograph sequence: drop.
            if s.value == 0x200D || (s.value >= 0xFE00 && s.value <= 0xFE0F) {
                i += 1
                continue
            }
            result.append(s)
            i += 1
        }

        // Logging happens in the public `stripEmojis` wrapper as
        // "[VOICE-POLISH-STRIP] removed N emoji codepoints" — single source
        // of truth so consoles aren't double-logged.
        _ = stripped

        var out = String(result)
        // Tidy up double-spaces and a leading/trailing space introduced by the
        // stripped scalars.
        out = out.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        // Strip orphan space-before-punctuation: " ." → ".", " ," → ",".
        out = out.replacingOccurrences(of: " \\.", with: ".", options: .regularExpression)
        out = out.replacingOccurrences(of: " ,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: " !", with: "!", options: .regularExpression)
        out = out.replacingOccurrences(of: " \\?", with: "?", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// True if the scalar is in the Extended_Pictographic class OR in a
    /// well-known emoji block. We can't rely on `properties.isEmoji` alone
    /// because that flags digits, asterisk, hash, and other ASCII symbols.
    private static func isPictographicScalar(_ s: Unicode.Scalar) -> Bool {
        // Swift's UnicodeScalar.Properties exposes `isEmojiPresentation` and
        // (since macOS 11) the Extended_Pictographic property is reachable as
        // `isEmoji` combined with non-ASCII range. We use explicit block ranges
        // because they're stable across OS versions and don't false-positive.
        let v = s.value
        // Emoticons
        if v >= 0x1F600 && v <= 0x1F64F { return true }
        // Misc Symbols & Pictographs
        if v >= 0x1F300 && v <= 0x1F5FF { return true }
        // Transport & Map
        if v >= 0x1F680 && v <= 0x1F6FF { return true }
        // Supplemental Symbols & Pictographs
        if v >= 0x1F900 && v <= 0x1F9FF { return true }
        // Symbols & Pictographs Extended-A
        if v >= 0x1FA70 && v <= 0x1FAFF { return true }
        // Misc Symbols (block-level, contains ☀ ☂ ★ etc.)
        if v >= 0x2600 && v <= 0x26FF { return true }
        // Dingbats (contains ✅ ✈ ✊ etc.)
        if v >= 0x2700 && v <= 0x27BF { return true }
        // Regional Indicator (flags)
        if v >= 0x1F1E6 && v <= 0x1F1FF { return true }
        // Enclosed Alphanumeric Supplement (contains 🅰 🆎 etc.)
        if v >= 0x1F100 && v <= 0x1F1FF { return true }
        // Mahjong/playing card/domino emoji blocks
        if v >= 0x1F000 && v <= 0x1F02F { return true } // mahjong
        if v >= 0x1F0A0 && v <= 0x1F0FF { return true } // playing cards
        // Misc Technical (contains ⌚ ⌛ ⏰ etc.)
        if v >= 0x231A && v <= 0x231B { return true }
        if v == 0x23E9 || v == 0x23EA || v == 0x23EB || v == 0x23EC { return true }
        if v == 0x23F0 || v == 0x23F3 { return true }
        return false
    }

    // MARK: - European decimal normalization
    //
    // "€2.300" → "€2,300" when the dot is followed by exactly 3 digits and
    // no more — the unambiguous thousands-separator case. Two-digit
    // amounts (€2.50, $1.99) stay as real decimals.

    static func europeanDecimalPass(_ text: String) -> String {
        var s = text
        // (currency)(integer)(.)(exactly 3 digits)(not followed by more digits)
        s = replaceRegex(
            s,
            pattern: #"([\$€£¥₹])(\d{1,3})\.(\d{3})(?!\d)"#,
            options: []
        ) { groups in "\(groups[1])\(groups[2]),\(groups[3])" }
        return s
    }

    // MARK: - European-style number mis-renderings ("4.5.000.000" -> "4.5 million")
    //
    // Cloud / local models occasionally render a spoken decimal-magnitude
    // number ("four point five million") with European thousand separators:
    // "4.5.000.000". Catastrophic readability failure. This pass catches the
    // exact pattern and converts it to digit-plus-magnitude form.

    /// Catches European-style mis-renderings like "4.5.000.000" and "4.500.000"
    /// and corrects them. These appear when a small model treats spoken decimals
    /// + magnitude as a single number with European thousand separators.
    public static func normalizeEuropeanNumberMistakes(_ text: String) -> String {
        var result = text
        // Pattern: digit "point" "5.000.000" (where ".000.000" or ".000" was meant to be a magnitude)
        // Specifically catch: "<digit>.<digit>.000.000" -> "<digit>.<digit> million"
        let millionPattern = #"\b(\d+)\.(\d)\.0{3}\.0{3}\b"#
        if let regex = try? NSRegularExpression(pattern: millionPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1.$2 million")
        }
        // "<digit>.<digit>.000" -> "<digit>.<digit> thousand" (less common)
        let thousandPattern = #"\b(\d+)\.(\d)\.0{3}\b"#
        if let regex = try? NSRegularExpression(pattern: thousandPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1.$2 thousand")
        }
        return result
    }

    // MARK: - "at <number>" never becomes "@<number>"
    //
    // The word "at" preceding a clock time is NEVER the @ symbol. Some models
    // mis-render "at 3:00" or "at 6" as "@3:00" / "@6" — an email-handle-style
    // misread. This pass undoes that.

    /// Catches "at-three" or "@three" or "@<number>" — the model mis-reading
    /// "at <number>" as an email handle / mention. Output should never have
    /// @ followed by a digit when the source was a spoken clock time.
    public static func normalizeAtTime(_ text: String) -> String {
        let pattern = #"@(\d+(?::\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "at $1")
    }

    // MARK: - Colon list detection
    //
    // "X: a, b, c, d" where there are 4+ short comma-separated items after
    // the colon becomes a bullet list. Catches the "pull up some numbers:
    // 5am, €2,300, 5000W, 20V voltage, 40mm, ..." pattern that the
    // implicit-list pass (which keys off cue verbs like "I need") misses.

    static func colonListPass(_ text: String) -> String {
        // Find sentences with the pattern:
        //   <something>:<space><short_item>(<comma><space><short_item>){3,}<period or end>
        // Each item is 1-4 words. Threshold of 4+ items so casual prose
        // like "Three colors: red, blue, green" stays inline.
        let pattern = #"([^.!?\n]+?):\s+((?:[A-Za-z0-9][\w\s'\.€$£¥/\-]{0,40}?,\s*){3,}(?:and\s+)?[A-Za-z0-9][\w\s'\.€$£¥/\-]{0,40}?)(?=[.!?\n]|$)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let intro = (result as NSString).substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let itemsStr = (result as NSString).substring(with: match.range(at: 2))

            // Split on commas (keep "and X" as final item).
            let rawItems = itemsStr
                .replacingOccurrences(of: ", and ", with: ", ")
                .replacingOccurrences(of: " and ", with: ", ")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Need 4+ items; each item ≤ 5 words; reject lists where one item
            // is a full sentence ("I went home, I was tired" shouldn't bullet).
            guard rawItems.count >= 4 else { continue }
            let allShort = rawItems.allSatisfy { $0.split(separator: " ").count <= 5 }
            guard allShort else { continue }

            // Capitalize first letter of each item to match list style.
            let items = rawItems.map { item -> String in
                guard let first = item.first else { return item }
                return String(first).uppercased() + item.dropFirst()
            }
            let bulletList = "\(intro):\n" + items.map { "- \($0)" }.joined(separator: "\n")
            result = (result as NSString).replacingCharacters(in: match.range, with: bulletList)
            print("[VOICE-POST] colon-list: \(items.count) items detected after \"\(intro.suffix(30))\"")
        }
        return result
    }

    // MARK: - Numbered list detection
    //
    // "number one X number two Y number three Z" or "first X second Y third Z"
    // → markdown numbered list. Matches 3+ enumeration markers.

    static func numberedListPass(_ text: String) -> String {
        // Three forms of enumeration:
        //   A) "number one", "number two", "number three" …
        //   B) "first", "second", "third", "fourth" …
        //   C) "one. X two. Y three. Z" — model already emitted ordinals
        //
        // For each, capture the items between markers. Require ≥3 markers
        // so we don't false-positive on "first of all" or "second time".
        var s = text

        // Form A: "number one X number two Y number three Z [number four W]?"
        // Each item is captured greedily up to the next marker or terminal punct.
        let patternA = #"(?i)\bnumber\s+one[,\s:]+(.+?)\s+number\s+two[,\s:]+(.+?)\s+number\s+three[,\s:]+(.+?)(?:\s+number\s+four[,\s:]+(.+?))?(?=[.!?\n]|$)"#
        if let rx = try? NSRegularExpression(pattern: patternA) {
            let ns = s as NSString
            let matches = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                var items: [String] = []
                for i in 1..<match.numberOfRanges {
                    let r = match.range(at: i)
                    if r.location == NSNotFound { continue }
                    let item = (s as NSString).substring(with: r)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
                    if !item.isEmpty { items.append(item) }
                }
                guard items.count >= 3 else { continue }
                // Capitalize first letter of each item
                items = items.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                let listBlock = items.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                s = (s as NSString).replacingCharacters(in: match.range, with: listBlock)
                print("[VOICE-POST] numbered-list: \(items.count) items detected via 'number N'")
            }
        }

        // Form A2: Mixed — "number one X. 2. Y. 3. Z"
        // The model sometimes converts only the first marker. Same approach
        // as A but the second/third markers are bare ordinals.
        let patternA2 = #"(?i)\bnumber\s+one[,\s:]+(.+?)\s+2\.\s+(.+?)\s+3\.\s+(.+?)(?:\s+4\.\s+(.+?))?(?=[.!?\n]|$)"#
        if let rx = try? NSRegularExpression(pattern: patternA2) {
            let ns = s as NSString
            let matches = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                var items: [String] = []
                for i in 1..<match.numberOfRanges {
                    let r = match.range(at: i)
                    if r.location == NSNotFound { continue }
                    let item = (s as NSString).substring(with: r)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
                    if !item.isEmpty { items.append(item) }
                }
                guard items.count >= 3 else { continue }
                items = items.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                let listBlock = items.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                s = (s as NSString).replacingCharacters(in: match.range, with: listBlock)
                print("[VOICE-POST] numbered-list: \(items.count) items detected via mixed 'number one + 2. + 3.'")
            }
        }

        // Form A3: Inline already-emitted "1. X 2. Y 3. Z" without paragraph breaks
        let patternA3 = #"\b1\.\s+(.+?)\s+2\.\s+(.+?)\s+3\.\s+(.+?)(?:\s+4\.\s+(.+?))?(?=[.!?\n]|$)"#
        if let rx = try? NSRegularExpression(pattern: patternA3) {
            let ns = s as NSString
            let matches = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                // Skip if this match already starts at a newline (already formatted).
                let start = match.range.location
                if start > 0 {
                    let prevChar = (s as NSString).substring(with: NSRange(location: start - 1, length: 1))
                    if prevChar == "\n" { continue }
                }
                var items: [String] = []
                for i in 1..<match.numberOfRanges {
                    let r = match.range(at: i)
                    if r.location == NSNotFound { continue }
                    let item = (s as NSString).substring(with: r)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
                    if !item.isEmpty { items.append(item) }
                }
                guard items.count >= 3 else { continue }
                items = items.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                let listBlock = items.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                s = (s as NSString).replacingCharacters(in: match.range, with: listBlock)
                print("[VOICE-POST] numbered-list: \(items.count) items detected via inline 1./2./3.")
            }
        }

        // Form B: "first X second Y third Z [fourth W]?"
        let patternB = #"(?i)\bfirst[,\s:]+(.+?)\s+second[,\s:]+(.+?)\s+third[,\s:]+(.+?)(?:\s+fourth[,\s:]+(.+?))?(?=[.!?\n]|$)"#
        if let rx = try? NSRegularExpression(pattern: patternB) {
            let ns = s as NSString
            let matches = rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                var items: [String] = []
                for i in 1..<match.numberOfRanges {
                    let r = match.range(at: i)
                    if r.location == NSNotFound { continue }
                    let item = (s as NSString).substring(with: r)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
                    if !item.isEmpty { items.append(item) }
                }
                guard items.count >= 3 else { continue }
                items = items.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                let listBlock = items.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                s = (s as NSString).replacingCharacters(in: match.range, with: listBlock)
                print("[VOICE-POST] numbered-list: \(items.count) items detected via 'first/second/third'")
            }
        }

        return s
    }

    // MARK: - List structure helpers (Oxford comma + item capitalization)
    //
    // These two passes clean up the surface form of lists AFTER the LLM has
    // produced them and the bullet/numbered passes above have done their
    // restructuring. They are deliberately small and surgical:
    //
    //   - `ensureOxfordComma` walks inline "X, Y and Z" sequences and inserts
    //     the missing serial comma so they read "X, Y, and Z". Some upstream
    //     models still elide the Oxford comma despite the prompt.
    //   - `capitalizeListItems` walks bullet/numbered list lines and uppercases
    //     the first letter of the item, regardless of what the model emitted.
    //
    // Both are idempotent and conservative (no-op when the text already
    // conforms), and both run unconditionally — they have no `listMode`
    // gating because they only mutate text that is already shaped like a
    // list.

    /// Ensures Oxford comma in inline lists of 3+ items.
    /// Detects patterns like "X, Y and Z" and converts to "X, Y, and Z".
    public static func ensureOxfordComma(_ text: String) -> String {
        // Match: ", <word> and <word>" or ", <word> or <word>" → ", <word>, and/or <word>"
        // The leading comma anchors us to genuine lists (≥3 items) — we never
        // touch bare "<word> and <word>" pairs.
        let pattern = #",\s+([A-Za-z][\w'-]*)\s+(and|or)\s+([A-Za-z][\w'-]*)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: ", $1, $2 $3")
    }

    /// Capitalizes the first letter of each line in a bulleted/numbered list.
    /// Matches lines starting with "- ", "* ", "• ", or "N. ".
    public static func capitalizeListItems(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        // Match the bullet/number prefix and the first lowercase letter that
        // follows it. We rebuild the line in code (rather than via regex
        // replacement) so the capitalization is unambiguous and we never
        // accidentally rewrite content past the first character.
        let bulletPrefixPattern = #"^(\s*(?:[-*\u{2022}]|\d+\.)\s+)([a-z])"#
        guard let regex = try? NSRegularExpression(pattern: bulletPrefixPattern) else { return text }
        let updated = lines.map { line -> String in
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = regex.firstMatch(in: line, range: range), m.numberOfRanges >= 3 else {
                return line
            }
            let prefixRange = m.range(at: 1)
            let letterRange = m.range(at: 2)
            let prefix = ns.substring(with: prefixRange)
            let letter = ns.substring(with: letterRange).uppercased()
            let rest = ns.substring(from: letterRange.location + letterRange.length)
            return prefix + letter + rest
        }
        return updated.joined(separator: "\n")
    }

    // MARK: - Thousands separator
    //
    // "14000" → "14,000". Carefully skips:
    //   - Years (1900-2100)
    //   - Numbers immediately preceded by digits, letters, or special chars
    //     (URLs, version numbers, IDs)
    //   - 4-digit numbers that look like times ("0830")

    static func thousandsSeparatorPass(_ text: String) -> String {
        // Match standalone integer of 4+ digits not adjacent to letters/digits/colon/slash/dash.
        let pattern = #"(?<![\w:\-/])(\d{4,})(?![\w:\-/.])"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var s = text
        for match in matches.reversed() {
            let r = match.range
            let numStr = (s as NSString).substring(with: r)
            guard let num = Int(numStr) else { continue }
            // Skip years (1900-2100).
            if numStr.count == 4 && (1900...2100).contains(num) { continue }
            // Format with commas. Pin en_US — the system locale carries a
            // region override (e.g. en_US@rg=nlzzzz) that would emit a PERIOD
            // thousands separator ("820.000"), recreating the exact European-
            // separator corruption the number system exists to prevent.
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            guard let formatted = formatter.string(from: NSNumber(value: num)) else { continue }
            s = (s as NSString).replacingCharacters(in: r, with: formatted)
        }
        return s
    }

    // MARK: - Currency dedup
    //
    // "$$200" → "$200", "€€500" → "€500". Defensive against double-pass artifacts.

    static func deduplicateCurrencySymbols(_ text: String) -> String {
        var s = text
        let symbols = ["$", "€", "£", "¥", "₹"]
        for sym in symbols {
            let escaped = NSRegularExpression.escapedPattern(for: sym)
            s = s.replacingOccurrences(
                of: "(\(escaped)){2,}",
                with: sym,
                options: .regularExpression
            )
        }
        return s
    }

    // MARK: - Forced paragraph breaks
    //
    // Safety net: if the LLM produced one giant paragraph despite the prompt
    // asking for breaks, deterministically split at the strongest available
    // topic boundary. Heuristic:
    //   - >80 words AND <2 \n\n boundaries → must split
    //   - Splits at sentence boundaries (period + space + capital letter)
    //   - Prefers boundaries near 1/3 and 2/3 of the text
    //   - Skips if the text is structured (already has bullets / numbered list)

    static func forceParagraphBreaks(_ text: String) -> String {
        let wordCount = text.split(separator: " ").count
        guard wordCount > 80 else { return text }
        // If already split into ≥2 paragraphs, leave alone.
        let existingBreaks = text.components(separatedBy: "\n\n").count - 1
        if existingBreaks >= 2 { return text }
        // If output is already structured (bullets / numbered list), leave alone.
        if text.contains("\n- ") || text.contains("\n1. ") || text.contains("\n* ") {
            return text
        }
        // Find all sentence boundaries (period + space + capital letter).
        let pattern = #"(?<=[.!?])\s+(?=[A-Z])"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }

        // Pick break points at roughly 1/3 and 2/3 of the text.
        let targets: [Double] = wordCount > 160 ? [0.33, 0.66] : [0.5]
        let totalLen = ns.length
        var breakPoints: [Int] = []
        for target in targets {
            let targetPos = Int(Double(totalLen) * target)
            // Find the match closest to target position.
            let closest = matches.min(by: { abs($0.range.location - targetPos) < abs($1.range.location - targetPos) })
            if let m = closest, !breakPoints.contains(m.range.location) {
                breakPoints.append(m.range.location)
            }
        }
        breakPoints.sort(by: >)
        var s = text
        for loc in breakPoints {
            let nsCurrent = s as NSString
            let r = NSRange(location: loc, length: 1)
            if r.location + r.length <= nsCurrent.length {
                s = nsCurrent.replacingCharacters(in: r, with: "\n\n")
            }
        }
        if !breakPoints.isEmpty {
            print("[VOICE-POST] force-paragraph-breaks: inserted \(breakPoints.count) breaks")
        }
        return s
    }

    // MARK: - Honorifics
    //
    // "Doctor Smith" → "Dr. Smith", "Mister Johnson" → "Mr. Johnson",
    // "Professor Lee" → "Prof. Lee". Only fires before a capitalized name.

    static func honorificPass(_ text: String) -> String {
        var s = text
        let pairs: [(word: String, abbr: String)] = [
            ("Doctor",    "Dr."),
            ("Mister",    "Mr."),
            ("Misses",    "Mrs."),
            ("Missus",    "Mrs."),
            ("Miss",      "Ms."),  // ambiguous; only when followed by a name
            ("Professor", "Prof."),
            ("Senator",   "Sen."),
            ("Representative", "Rep."),
            ("Reverend",  "Rev."),
            ("Junior",    "Jr."),  // when at end of name
            ("Senior",    "Sr."),
        ]
        for (word, abbr) in pairs {
            // Word + space + capitalized name (Last or First Last).
            let pattern = #"\b"# + word + #"\s+([A-Z][a-z]+)\b"#
            s = replaceRegex(s, pattern: pattern, options: []) { groups in
                "\(abbr) \(groups[1])"
            }
        }
        return s
    }

    // MARK: - Email salutation normalizer

    /// Verifies that an output that LOOKS like an email (starts with
    /// Hi/Hello/Hey/Dear + name) has the salutation on its own line. If not,
    /// returns the corrected version with a `\n\n` injected after the
    /// salutation comma.
    ///
    /// Belt-and-suspenders for the cloud prompt: the model is told to put the
    /// salutation on its own line, but it occasionally produces an inline
    /// form like "Hi Sarah, I wanted to follow up...". This pass detects
    /// that shape and rewrites the trailing whitespace after the comma to
    /// `\n\n` so the output is always a properly structured email.
    public static func normalizeEmailSalutation(_ text: String) -> String {
        // If the text starts with "Hi <name>," or "Hello <name>," etc., and
        // the next char is a space (not \n), inject "\n\n" after the comma.
        let pattern = #"^(Hi|Hello|Hey|Dear|Good morning|Good afternoon|Good evening)\s+[A-Z][A-Za-z]+(?:\s+and\s+[A-Z][A-Za-z]+)?,\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return text }
        // Replace the trailing whitespace after the comma with \n\n
        let salutationEnd = match.range.upperBound
        let cleaned = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: salutationEnd)])
            .trimmingCharacters(in: .whitespaces) + "\n\n" + String(text[text.index(text.startIndex, offsetBy: salutationEnd)...])
        return cleaned
    }
}
