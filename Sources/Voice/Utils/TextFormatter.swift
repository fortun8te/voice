// VOICE — Text Formatter
// ============================================================
// Post-processing for transcribed text before pasting.
//
// PHILOSOPHY:
//   We never paraphrase. We never rewrite. We only fix surface
//   formatting — capitalization, punctuation, contractions,
//   numbers, smart quotes, paragraph breaks. Every word the
//   speaker said stays in, in order. Surface only.
//
// PERFORMANCE:
//   Synchronous `format()` runs after every transcription, so
//   it must stay fast. Target: <50ms for 1000 words. All regex
//   compilations happen once and are cached.
//
// CONSTRAINTS:
//   - No em dashes. Ever. Strip on input AND on Gemma output.
//   - Never reorder words.
//   - Idempotent: format(format(x)) == format(x).
// ============================================================

import Foundation

// MARK: - Configuration

/// Controls which formatting features are active.
struct TextFormatterConfig {
    var autoCapitalize: Bool = true
    var smartPunctuation: Bool = true
    var removeFillers: Bool = true
    var interpretVoiceCommands: Bool = true
    var formatNumbers: Bool = true
    var reconstructEmailsAndURLs: Bool = true
    var fixContractions: Bool = true
    var convertCurrency: Bool = true
    var detectParagraphs: Bool = true
    var paragraphPauseThreshold: TimeInterval = 2.0
    /// If true, sequences of spoken list markers ("point one... point two...",
    /// "first... second... third...") are reformatted into numbered lines.
    var detectLists: Bool = true
    /// If true, "first/second/third..." sequences without "point/number/step"
    /// prefix become `- ` bullets instead of `1. 2. 3.` numbers.
    var preferBulletsForOrdinalOnly: Bool = false
    /// Segment-gap (seconds) at or above which `formatSegments` inserts a
    /// `\n\n` paragraph break. The user requested 1.5s as the threshold.
    var paragraphGapThreshold: TimeInterval = 1.5

    /// Load config from UserDefaults (BigMenu / Settings UI binds toggles here).
    static func fromDefaults() -> TextFormatterConfig {
        let defaults = UserDefaults.standard
        var config = TextFormatterConfig()
        if defaults.object(forKey: "fmt_capitalize") != nil {
            config.autoCapitalize = defaults.bool(forKey: "fmt_capitalize")
        }
        if defaults.object(forKey: "fmt_smartPunctuation") != nil {
            config.smartPunctuation = defaults.bool(forKey: "fmt_smartPunctuation")
        }
        if defaults.object(forKey: "fmt_removeFillers") != nil {
            config.removeFillers = defaults.bool(forKey: "fmt_removeFillers")
        }
        if defaults.object(forKey: "fmt_voiceCommands") != nil {
            config.interpretVoiceCommands = defaults.bool(forKey: "fmt_voiceCommands")
        }
        if defaults.object(forKey: "fmt_formatNumbers") != nil {
            config.formatNumbers = defaults.bool(forKey: "fmt_formatNumbers")
        }
        if defaults.object(forKey: "fmt_detectLists") != nil {
            config.detectLists = defaults.bool(forKey: "fmt_detectLists")
        }
        if defaults.object(forKey: "fmt_preferBullets") != nil {
            config.preferBulletsForOrdinalOnly = defaults.bool(forKey: "fmt_preferBullets")
        }
        return config
    }
}

// MARK: - TextFormatter

class TextFormatter {
    var config: TextFormatterConfig

    init(config: TextFormatterConfig = .fromDefaults()) {
        self.config = config
    }

    // MARK: - ASR confusables (Parakeet/Granite mis-hearings)

    /// Words Parakeet frequently mis-transcribes. Surfaced to Qwen3 as
    /// vocabulary hints when polish runs, so the LLM can correct in context.
    /// Add new entries here as they're discovered.
    // BUGFIX: Expanded ASR confusables — user has flagged "yo"→"yeah" multiple
    // times. Added more yo/yote/yoat tokens, "test"/"tests", "house"/"host"
    // pairs called out in the audit brief.
    static let asrConfusables: [String: [String]] = [
        "yeah": ["yo"],          // Parakeet often hears "yo" as "yeah"
        "your": ["yo"],          // and sometimes as "your"
        "you": ["yo"],
        "yo": ["yo"],            // BUGFIX: surface "yo" itself so polish prompt knows it's intentional, not a Parakeet hallucination to "correct"
        "yoat": ["yo"],          // "yoat houst" → "yo, quick test"
        "yote": ["yo"],          // BUGFIX: another Parakeet "yo" mishear
        "yoda": ["yo"],          // BUGFIX: seen in logs
        "houst": ["host"],
        "house": ["host"],       // BUGFIX: confusable pair
        "host":  ["house"],
        "tests": ["test"],       // BUGFIX: Parakeet pluralizes/depluralizes
        "test":  ["tests"],
        // BUGFIX (handle protection): Qwen3 polish keeps "correcting"
        // "fortun8te" → "fortunate". Surface the pair to the LLM so it
        // sees them as a known confusable and leaves usernames alone.
        "fortunate":  ["fortun8te"],
        // BUGFIX (handle protection): extra fortun8te confusables observed
        // in the wild — sentence-ending punctuation ("fortunate.") and the
        // letter-by-letter spellings Parakeet falls back to when it can't
        // resolve the leetspeak digit ("forge net" / "forgenet").
        "fortunate.": ["fortun8te"],
        "forge net":  ["fortun8te"],
        "forgenet":   ["fortun8te"],
    ]

    /// Per-utterance suspects — returns words from the transcript that have known
    /// confusables. The polish prompt receives these via `suspectWords:` so the LLM
    /// can disambiguate from context.
    static func suspectsForPolish(_ text: String) -> [String] {
        let lower = text.lowercased()
        var hits: [String] = []
        for (word, _) in asrConfusables {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil {
                hits.append(word)
            }
        }
        // BUGFIX (handle protection): also surface any letter+digit identifier
        // (fortun8te, gr8, 4ever, ChatGPT3, m8) so the polisher treats them as
        // "do not change". These are almost always usernames or shorthand the
        // LLM tries to "correct" into dictionary words.
        for handle in extractHandleShapes(text) {
            hits.append(handle)
        }
        return Array(Set(hits))
    }

    // MARK: - Cached regexes (compiled once at init time, reused on every format call)
    // Keeping these as lazy statics keeps `format` allocation-free on the hot path.
    private static let rxSpaceBeforePunct   = try! NSRegularExpression(pattern: #"\s+([,.!?;:])"#)
    private static let rxRepeatedDots       = try! NSRegularExpression(pattern: #"\.{2,}"#)
    private static let rxRepeatedCommas     = try! NSRegularExpression(pattern: #",{2,}"#)
    private static let rxPunctSpacing       = try! NSRegularExpression(pattern: #"([.!?,;:])([A-Za-z])"#)
    private static let rxStandaloneI        = try! NSRegularExpression(pattern: #"\bi\b"#)
    private static let rxWord               = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)
    private static let rxEmailLikeAtPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9._%+\-]+)\s+at\s+([A-Za-z0-9.\-]+)"#,
        options: .caseInsensitive
    )
    // Sentence-start: position 0, OR after `.!?` plus optional close-quote/paren and whitespace,
    // OR after a paragraph break.
    // NOTE: Swift `\u{...}` escapes are NOT processed inside raw strings (`#"..."#`),
    // and ICU regex doesn't understand `\u{xxxx}`. Use literal Unicode characters.
    private static let rxSentenceStart = try! NSRegularExpression(
        pattern: #"(^|[.!?…]["”\)\]]?\s+|\n+\s*)([a-z])"#
    )

    // MARK: - Synchronous pipeline

    /// Main entry point: apply all enabled formatting to raw transcript text.
    /// Pipeline is ordered carefully — read the inline comments before
    /// reordering. Designed to produce "edited" output: proper case, polished
    /// punctuation, no doubles, no em dashes, terminal punctuation, contractions
    /// fixed, numbers normalized.
    func format(_ text: String) -> String {
        var result = text

        // BUGFIX (Yo/Yeah specific): normalize known Parakeet quirks BEFORE
        // any other pass. "yoat" / "yote" → "yo", "houst" → "host". Conservative
        // — only unambiguous tokens. Runs before stripLeadingFiller so the
        // normalized "yo" isn't accidentally classified as a leading filler.
        result = Self.normalizeParakeetQuirks(result)

        // 1pre. Normalize known product / brand names BEFORE filler strip and
        // dedup, so "wispr flow", "para keet", "moon shine" get canonicalized
        // early and survive downstream passes intact.
        result = normalizeKnownProductNames(result)

        // 1. Trim and strip leading filler at the very start of the utterance.
        result = stripLeadingFiller(result)

        // 1a. Spoken-list detection ("point one... point two..." / "first... second...").
        //     Runs FIRST (before dedup/voice-commands) for two reasons:
        //     (1) word-dedup collapses "point point" → "point", which destroys
        //         the marker sequence (the speaker says "another point. point three"
        //         and the dedup pass would erase the second "point").
        //     (2) voice commands inject newlines that would confuse the regex.
        //     Requires at least 2 sequential triggers, so single mentions like
        //     "she is my number one fan" stay untouched.
        if config.detectLists {
            result = detectAndFormatLists(result)
        }

        // 1b. Collapse ASR word-repetition artifacts ("I'm I'm I'm" → "I'm").
        //     Runs after list detection so list-marker repetitions survive.
        result = deduplicateRepeatedWords(result)
        // Phrase-level dedup: catch "I noticed I noticed" and "this is just a this is just a"
        result = deduplicateRepeatedPhrases(result, n: 2)
        result = deduplicateRepeatedPhrases(result, n: 3)

        // 1c. Self-correction detection ("scratch that", "actually no wait", "I mean").
        //     Run before voice commands so we see natural speech structure.
        result = applySelfCorrections(result)

        // 1e. Paragraph-break insertion based on transitional phrases.
        //     "...store. So, I went home." → "...store.\n\nSo, I went home."
        //     Segment-gap-based breaks live in `formatSegments` (we don't have
        //     timestamps here).
        result = insertTransitionalParagraphBreaks(result)

        // 1f. Dense-prose paragraph splitter for long dictations (≥120 words).
        //     Fires AFTER transitional breaks so we don't re-split already-broken text.
        result = splitDenseParagraphs(result)

        // 1g. Email/letter salutation detection.
        //     "Dear John I hope you're doing well" → "Dear John,\n\nI hope you're doing well."
        //     Runs BEFORE voice commands so salutation lines don't confuse command detection.
        result = formatSalutation(result)

        // 2a. Special-character phrase formatting — MUST run BEFORE voice commands.
        //     If voice commands fire first, "open quote"/"close quote" become the
        //     unicode quote chars, and `wrapSpokenQuotes`'s "end quote / close quote"
        //     pattern can no longer match. Same logic for paren commands.
        //     Also must run BEFORE number folding so content inside still gets
        //     normalized, and BEFORE percent/currency suffix passes.
        result = wrapSpokenQuotes(result)
        result = wrapSpokenParens(result)

        // 2. Voice commands (they introduce newlines that change structure).
        if config.interpretVoiceCommands {
            result = applyVoiceCommands(result)
        }

        // 3. Filler removal everywhere else.
        if config.removeFillers {
            result = removeFillerWords(result)
        }

        // 4. Smart punctuation (curly quotes, em-dash → spaced-hyphen, ellipsis).
        if config.smartPunctuation {
            result = applySmartPunctuation(result)
        }

        // 4a. PRE-NUMBER passes (deterministic, run BEFORE number-word folding
        //     so multi-word phrases get matched as units instead of being
        //     destroyed by the folder collapsing "nine thirty" → 39).
        //     These fix the known LLM-polish failures: "39am", "12 point $5000000",
        //     "version two point one point seven left verbatim", etc.
        if config.formatNumbers {
            result = normalizeSpokenTimesPrePass(result)           // "nine thirty AM" → "9:30 AM"
            result = normalizeSpokenMoneyMagnitudesPrePass(result) // "twelve point five million dollars" → "$12.5 million"
            result = normalizeVersionNumbers(result)               // "version two point one point seven" → "v2.1.7"
            result = normalizeCountdowns(result)                   // "three two one" → "3, 2, 1"
            result = normalizeDecimalNumbers(result)               // "three point one four" → "3.14"
        }

        // 5. Number-word folding ("twenty three" → 23, "twenty third" → "23rd").
        if config.formatNumbers {
            result = convertOrdinals(result)
            result = convertNumberWords(result)
            result = convertSpokenTimes(result)
            result = normalizeTimesOfDay(result)                   // BUGFIX: "5 30 pm" / "5:30 pm" → "5:30 PM", "5pm" → "5 PM"
            result = normalizeMoneyAndUnits(result)                // NEW: "150 bucks" → "$150", "50 millimeter" → "50mm", "2.5 percent" → "2.5%"
            result = normalizeLatencyDurations(result)             // "300 milliseconds" → "300ms"
        }

        // 5a. Signal-rich structural prep for the polish stage. ORDER MATTERS:
        //     `extractQuotedMessage` first so URLs inside the dictated body
        //     get pulled out before URL protection runs; `detectAndMarkFieldLists`
        //     before `backtickCodeTokens` so the snake_case-converted field
        //     tokens it produces don't get double-wrapped in backticks.
        result = extractQuotedMessage(result)
        result = detectAndMarkFieldLists(result)
        result = backtickCodeTokens(result)

        // 6. Currency ("five dollars" → "$5"). Runs AFTER number folding so it
        // can pick up "$<digits>" produced by the previous step.
        if config.convertCurrency {
            result = convertCurrency(result)
        }

        // 6a. Percent: "20 percent" → "20%", "0.5 percent" → "0.5%".
        //     Also handles "point five percent" via earlier number folding +
        //     a fallback for "point N percent" not folded (rare).
        result = convertPercent(result)

        // 6b. Currency magnitude suffixes: "$5 million" → "$5M", "$10 k" → "$10k".
        //     Only fires when a currency symbol precedes the number, so plain
        //     "5 million users" stays untouched.
        result = applyCurrencyMagnitudes(result)

        // 7. Email/URL reconstruction.
        if config.reconstructEmailsAndURLs {
            result = reconstructEmailsAndURLs(result)
        }

        // 8. Common contractions ("dont" → "don't", "im" stays — context matters).
        if config.fixContractions {
            result = fixContractions(result)
        }

        // 8b. BUGFIX: protect URLs/emails from the capitalization + whitespace
        // passes below, which otherwise insert spaces after the dots inside
        // domains ("youtube.com" → "youtube. Com") and capitalize the TLD.
        // We swap each match for a private-use unicode placeholder, run the
        // pipeline, then restore at the end.
        let (protectedText, urlMap) = protectURLsAndEmails(result)
        result = protectedText

        // 9. Punctuation cleanup BEFORE capitalization so capitalization sees
        // the corrected sentence boundaries.
        result = cleanupPunctuation(result)

        // 10. Capitalization — sentence start + standalone I.
        if config.autoCapitalize {
            result = capitalizeSentences(result)
            result = capitalizeStandaloneI(result)
        }

        // 10b. Acronym joining — "F B I" → "FBI". Runs AFTER capitalize so single
        // letters are uppercase, BEFORE em-dash strip / whitespace pass.
        result = joinAcronyms(result)

        // 10c. Brand-name collapse — "chat GPT" → "ChatGPT", "you tube" → "YouTube".
        // Runs after acronym joining so "C G P T" became "CGPT" already; this
        // dictionary handles mixed-case brand spellings the regex can't catch.
        result = collapseBrandNames(result)

        // 11. Em-dash strip (final defense — applies even if smartPunctuation off).
        result = stripEmDashes(result)

        // 12. Terminal punctuation (most users trail off without saying "period").
        result = ensureTerminalPunctuation(result)

        // 13. Question-mark inference — swap trailing `.` for `?` on sentences
        // that start with an interrogative word. Runs after terminal punctuation
        // so the trailing `.` exists to be swapped.
        result = inferQuestionMarks(result)

        // 13a. NEW: topic-shift paragraph breaks ("Also...", "Oh and...", "Wait...").
        //      Runs AFTER terminal punctuation has been inferred so the `.!?`
        //      boundary the regex matches on is reliably present.
        result = insertTopicShiftBreaks(result)

        // 14. BUGFIX: restore protected URLs / emails. Runs before final whitespace
        // pass so cleanWhitespace can normalize spacing around them, but after all
        // structural passes so the placeholders survive everything that mattered.
        result = restoreURLsAndEmails(result, urlMap)

        // 15. Whitespace pass — LAST. Verified newline/bullet/backtick-safe:
        // only collapses runs of spaces and 3+ newlines, trims outer whitespace,
        // never touches single newlines, leading `-` bullets, or backticks.
        result = cleanWhitespace(result)

        return result
    }

    // MARK: - Segmented (timed) formatting

    /// Format an array of timed segments with paragraph-aware breaking.
    ///   - gap >= `paragraphGapThreshold` (default 1.5s)  → `\n\n` (new paragraph)
    ///     Note: we deliberately DON'T require the previous segment to end in
    ///     `.!?` for a paragraph break — a long pause is itself a strong signal,
    ///     and missing terminal punctuation will be added by `ensureTerminalPunctuation`.
    ///   - gap >= `mediumPauseThreshold` (0.8s) and prev ends in `,;` and next
    ///     starts capitalized → `\n` (line break)
    ///   - otherwise concatenate with a single space.
    /// Each paragraph is then run through `format(_:)` so cleanup applies on
    /// each side of every break.
    func formatSegments(
        _ segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval)],
        longPauseThreshold: TimeInterval? = nil,
        mediumPauseThreshold: TimeInterval = 0.8
    ) -> String {
        guard !segments.isEmpty else { return "" }
        if segments.count == 1 { return format(segments[0].text) }

        let paragraphThreshold = longPauseThreshold ?? config.paragraphGapThreshold
        let lineTerminals: Set<Character> = [",", ";"]

        // We build one long string with `\n\n` and `\n` delimiters in place,
        // then split on `\n\n` for the per-paragraph format pass.
        var current = segments[0].text

        for i in 1..<segments.count {
            let gap = segments[i].startTime - segments[i - 1].endTime
            let prevTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let prevLast = prevTrimmed.last
            let nextFirst = segments[i].text.trimmingCharacters(in: .whitespaces).first

            let endsLine      = prevLast.map { lineTerminals.contains($0) } ?? false
            let nextIsCapped  = nextFirst.map { $0.isUppercase } ?? false

            if gap >= paragraphThreshold {
                current += "\n\n" + segments[i].text
            } else if gap >= mediumPauseThreshold && endsLine && nextIsCapped {
                current += "\n" + segments[i].text
            } else {
                current += " " + segments[i].text
            }
        }

        // Format each paragraph independently so capitalization/cleanup runs
        // bounded by the paragraph break.
        return current
            .components(separatedBy: "\n\n")
            .map { format($0) }
            .joined(separator: "\n\n")
    }

    /// Legacy entry point used by existing call sites. Detects paragraphs by
    /// estimated duration vs gap. Prefer `formatSegments` when end times exist.
    func formatWithParagraphs(_ segments: [(text: String, startTime: TimeInterval)]) -> String {
        guard config.detectParagraphs, segments.count > 1 else {
            return format(segments.map(\.text).joined(separator: " "))
        }

        var paragraphs: [String] = []
        var currentParagraph = segments[0].text

        for i in 1..<segments.count {
            let gap = segments[i].startTime - (segments[i-1].startTime + estimateDuration(segments[i-1].text))
            if gap >= config.paragraphPauseThreshold {
                paragraphs.append(currentParagraph)
                currentParagraph = segments[i].text
            } else {
                currentParagraph += " " + segments[i].text
            }
        }
        paragraphs.append(currentParagraph)

        return paragraphs.map { format($0) }.joined(separator: "\n\n")
    }

    // MARK: - Voice Commands

    /// Spoken phrase → replacement. Order matters (longer phrases first within
    /// a section, otherwise "exclamation" would consume "exclamation point").
    private let voiceCommands: [(pattern: String, replacement: String)] = [
        // Structural — most explicit first.
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("next line", "\n"),

        // Punctuation — multi-word phrases first.
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("explanation point", "!"),
        ("explanation mark", "!"),
        ("question mark", "?"),
        ("full stop", "."),
        ("period", "."),
        ("comma", ","),
        ("colon", ":"),
        ("semicolon", ";"),
        ("open quote", "\u{201C}"),
        ("close quote", "\u{201D}"),
        ("open paren", "("),
        ("close paren", ")"),
        ("ellipsis", "\u{2026}"),
        // CLI flags — must precede bare "dash" or the bare-dash rule fires first.
        ("dash dash", "--"),
        ("double dash", "--"),
        ("double hyphen", "--"),
        // Common symbols used in code/URLs
        ("equals sign", "="),
        ("tilde", "~"),
        ("caret", "^"),
        ("dash", " - "),

        // List formatting.
        ("bullet point", "\n- "),
        ("dash point", "\n- "),
        ("bullet", "\n- "),
        ("numbered list", "\n1. "),

        // Whitespace.
        ("tab", "\t"),
    ]

    /// Spoken commands that have legitimate prose uses ("period drama",
    /// "comma splice", "colon cancer"). For these we ONLY replace when the word
    /// appears in a command-shaped context: at end of utterance, OR followed by
    /// whitespace + (capitalized-word | line-end) — the natural pattern a speaker
    /// uses to say "...sentence. period. Next sentence.".
    private static let ambiguousVoiceCommands: Set<String> = [
        "period", "comma", "colon", "semicolon"
    ]

    /// Replace word-bounded spoken commands with their punctuation/structure.
    /// Word boundaries prevent "exclamation pointing" → "! ing".
    /// BUGFIX: ambiguous single-word commands (period/comma/colon/semicolon)
    /// require a command-shaped context so "the period drama was great" doesn't
    /// become "the . drama was great".
    private func applyVoiceCommands(_ text: String) -> String {
        var result = text
        for command in voiceCommands {
            let escaped = NSRegularExpression.escapedPattern(for: command.pattern)
            // For ambiguous words, require: preceded by space/start AND followed
            // by end-of-string OR whitespace+capitalized OR newline.
            // This catches "...store period next I went..." but not "the period drama".
            let pattern: String
            if Self.ambiguousVoiceCommands.contains(command.pattern) {
                pattern = "\\b\(escaped)\\b(?=\\s*$|\\s+[A-Z]|\\s*\\n)"
            } else {
                pattern = "\\b\(escaped)\\b"
            }
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: command.replacement
                )
            }
        }
        return result
    }

    // MARK: - Filler Word Removal

    /// Filler words removed from the body of the text (the `stripLeadingFiller`
    /// pass handles the start of the utterance separately, since common starters
    /// like "Like, ..." and "I mean, ..." are different from mid-sentence ones).
    ///
    /// CONSERVATIVE LIST ONLY: only pure hesitation sounds that never appear as
    /// legitimate content words. Words like "like", "right", "well", "actually",
    /// "basically" are legitimate English words and get incorrectly stripped from
    /// mid-sentence content ("I like this" → "I this").
    private let fillerWords: [String] = [
        "um", "uh", "umm", "uhh",
    ]

    /// Strip filler words wherever they occur, with optional trailing comma + space.
    private func removeFillerWords(_ text: String) -> String {
        var result = text
        for filler in fillerWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b,?\\s*"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result
    }

    // MARK: - Smart Punctuation

    /// Curly double + single quotes, em-dashes neutralized to spaced hyphen,
    /// triple-period collapsed to ellipsis.
    private func applySmartPunctuation(_ text: String) -> String {
        var result = text

        // Skip curly-quote conversion if input contains backticks — likely code,
        // and curlifying quotes inside code is destructive.
        if !result.contains("`") {
            result = replaceSmartDoubleQuotes(result)
            result = replaceSmartSingleQuotes(result)
        }

        // Em / en dash → spaced hyphen (user has banned em dashes).
        result = result.replacingOccurrences(of: " -- ", with: " - ")
        result = result.replacingOccurrences(of: "--", with: " - ")

        // Triple period → ellipsis character.
        result = result.replacingOccurrences(of: "...", with: "\u{2026}")

        return result
    }

    /// Replace straight double quotes with curly: alternating open/close based
    /// on running count.
    private func replaceSmartDoubleQuotes(_ text: String) -> String {
        var result = ""
        var insideQuote = false
        for char in text {
            if char == "\"" {
                result.append(insideQuote ? "\u{201D}" : "\u{201C}")
                insideQuote.toggle()
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Replace straight apostrophes with curly. Letters on both sides → apostrophe
    /// (don't → don't); leading-space → open quote; otherwise close.
    /// BUGFIX: special-case i == 0 (apostrophe at start of input) — emit OPENING
    /// single quote since there's no preceding letter and we're clearly opening
    /// a quoted span. Old logic fell through to closing-quote branch.
    private func replaceSmartSingleQuotes(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        for i in 0..<chars.count {
            if chars[i] == "'" {
                let prevIsLetter = i > 0 && chars[i-1].isLetter
                let nextIsLetter = i < chars.count - 1 && chars[i+1].isLetter
                if prevIsLetter && nextIsLetter {
                    result.append("\u{2019}")
                } else if i == 0 && nextIsLetter {
                    // Start-of-input + letter follows → opening quote.
                    result.append("\u{2018}")
                } else if prevIsLetter || (i > 0 && chars[i-1] == " ") {
                    result.append("\u{2018}")
                } else {
                    result.append("\u{2019}")
                }
            } else {
                result.append(chars[i])
            }
        }
        return result
    }

    // MARK: - Sentence Capitalization

    /// Capitalize the first letter at: start-of-text, after `.!?\u{2026}`
    /// (with optional closing quote/paren), and after newlines.
    private func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        var capitalizeNext = true
        for char in text {
            if capitalizeNext && char.isLetter {
                result.append(char.uppercased().first!)
                capitalizeNext = false
            } else {
                result.append(char)
            }
            if char == "." || char == "!" || char == "?" || char == "\n" || char == "\u{2026}" {
                capitalizeNext = true
            }
        }
        return result
    }

    /// Capitalize standalone " i " → " I ".
    private func capitalizeStandaloneI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.rxStandaloneI.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
    }

    // MARK: - Question mark inference
    //
    // Replaces trailing `.` with `?` on sentences that start with an interrogative
    // word. Conservative: only fires when the FIRST word is one of these (post-fillers).
    // "Are you free tomorrow." → "Are you free tomorrow?"
    // "I wonder if you're free." stays as-is (first word is "I", not interrogative).
    private static let interrogativeStarters: Set<String> = [
        "are", "is", "am", "was", "were",
        "do", "does", "did",
        "can", "could", "will", "would", "should", "shall", "may", "might",
        "have", "has", "had",
        "who", "what", "when", "where", "why", "how", "which", "whose", "whom",
        "isn't", "aren't", "wasn't", "weren't",
        "don't", "doesn't", "didn't",
        "can't", "couldn't", "won't", "wouldn't", "shouldn't",
        "haven't", "hasn't", "hadn't"
    ]

    // Tag-question endings: if a sentence ends with one of these words + ".",
    // swap to "?". E.g. "That's good, right." → "That's good, right?"
    // Only single-word tags listed here — multi-word ones like "isn't it" are
    // handled by the interrogative-starter pass above when they appear at the
    // sentence start of a short follow-on clause.
    //
    // BUGFIX: "really", "seriously", "honestly" removed — they're adverbs far
    // more often than tag-question markers. "I'll tell you honestly." was being
    // turned into a question. Short-sentence forms ("Really.", "Seriously.",
    // "Honestly.") are still caught by `shortQuestionPhrases` below.
    private static let tagQuestionEnders: Set<String> = [
        "right", "correct", "yeah", "yes", "okay", "ok",
        "huh", "eh", "no",
    ]

    // Short standalone question words: single-word sentences like "Really."
    // or two-word sentences like "Why not." that are clearly questions.
    private static let shortQuestionPhrases: Set<String> = [
        "really", "seriously", "honestly", "why not", "why",
        "how so", "how come", "is it", "is that right",
    ]

    /// Swap trailing `.` for `?` on sentences whose first real word is interrogative.
    /// Walks char by char; tracks sentence start; on terminal punct decides whether
    /// to swap. Idempotent — re-running on a `?`-ended sentence is a no-op.
    ///
    /// Also handles:
    ///   - Tag questions: sentence ends with "right.", "correct.", "yeah." → swaps to "?"
    ///   - Short questions: "Really.", "Why not.", "How so." → swaps to "?"
    private func inferQuestionMarks(_ text: String) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return text }
        var result = chars
        var sentenceStart = 0
        let skip: Set<Character> = [" ", "\t", "\n", "\"", "\u{201C}", "\u{201D}", "'", "\u{2018}", "\u{2019}", "(", "[", "{"]

        // Returns lowercased first "real" word starting at `start`, or nil.
        func firstWord(from start: Int) -> String? {
            var i = start
            while i < result.count, skip.contains(result[i]) { i += 1 }
            guard i < result.count else { return nil }
            var word = ""
            while i < result.count {
                let c = result[i]
                if c.isLetter || c == "'" || c == "\u{2019}" {
                    word.append(c)
                    i += 1
                } else {
                    break
                }
            }
            return word.isEmpty ? nil : word.lowercased()
        }

        // Returns lowercased last "real" word ending at (or before) `end` (exclusive),
        // bounded at `start`. Skips trailing punctuation.
        func lastWord(sentStart: Int, sentEnd: Int) -> String? {
            // sentEnd points at the terminal `.` — scan backward from sentEnd-1
            var i = sentEnd - 1
            while i >= sentStart, skip.contains(result[i]) { i -= 1 }
            guard i >= sentStart else { return nil }
            var wordChars: [Character] = []
            while i >= sentStart {
                let c = result[i]
                if c.isLetter || c == "'" || c == "\u{2019}" {
                    wordChars.insert(c, at: wordChars.startIndex)
                    i -= 1
                } else {
                    break
                }
            }
            return wordChars.isEmpty ? nil : String(wordChars).lowercased()
        }

        // Returns lowercased sentence body from sentStart to sentEnd (exclusive of terminal punct).
        func sentenceBody(sentStart: Int, sentEnd: Int) -> String {
            var i = sentStart
            while i < sentEnd, skip.contains(result[i]) { i += 1 }
            guard i < sentEnd else { return "" }
            return String(result[i..<sentEnd]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func maybeSwap(terminalIndex: Int) {
            guard result[terminalIndex] == "." else { return }
            guard let w = firstWord(from: sentenceStart) else { return }
            // Normalize curly apostrophe to straight for set lookup.
            let normalized = w.replacingOccurrences(of: "\u{2019}", with: "'")

            // Guard: sentences ending with "question" that are long are likely
            // rhetorical statements ("Are you sure this is the question."), not questions.
            if let lastW = lastWord(sentStart: sentenceStart, sentEnd: terminalIndex),
               lastW == "question" {
                // Count words in sentence — long sentences ending "question" are statements.
                let sentBody = sentenceBody(sentStart: sentenceStart, sentEnd: terminalIndex)
                if sentBody.split(separator: " ").count > 6 { return }
            }

            // 1. Interrogative-starter check (existing logic).
            if Self.interrogativeStarters.contains(normalized) {
                result[terminalIndex] = "?"
                return
            }

            // 2. Tag-question ender check: last word of sentence is a tag word.
            if let last = lastWord(sentStart: sentenceStart, sentEnd: terminalIndex) {
                let lastNorm = last.replacingOccurrences(of: "\u{2019}", with: "'")
                if Self.tagQuestionEnders.contains(lastNorm) {
                    result[terminalIndex] = "?"
                    return
                }
            }

            // 3. Short standalone question phrases (whole sentence body matches).
            let body = sentenceBody(sentStart: sentenceStart, sentEnd: terminalIndex)
                .replacingOccurrences(of: "\u{2019}", with: "'")
            if Self.shortQuestionPhrases.contains(body) {
                result[terminalIndex] = "?"
                return
            }
        }

        var i = 0
        while i < result.count {
            let c = result[i]
            if c == "." || c == "!" || c == "?" || c == "\u{2026}" {
                if c == "." {
                    maybeSwap(terminalIndex: i)
                }
                // Advance past this terminal + any closing quote/paren + whitespace
                // to find the next sentence start.
                var j = i + 1
                while j < result.count, result[j] == "\"" || result[j] == "\u{201D}" || result[j] == ")" || result[j] == "]" {
                    j += 1
                }
                while j < result.count, result[j] == " " || result[j] == "\t" || result[j] == "\n" {
                    j += 1
                }
                sentenceStart = j
                i = max(i + 1, j > i + 1 ? j : i + 1)
                continue
            }
            i += 1
        }
        return String(result)
    }

    // MARK: - Contractions

    /// Common contractions the speech model often emits without apostrophes,
    /// plus "i'm/i've/i'll/i'd" → "I'm/..." capitalization.
    /// Note: `were` is intentionally NOT in this list — it's more often the verb
    /// "were" than a missing-apostrophe "we're". Speakers who want the contraction
    /// typically pronounce it clearly enough that the model emits "we're" already.
    private let contractionMap: [(String, String)] = [
        // I-forms (capitalization + apostrophe)
        ("i'm",  "I'm"),
        ("i'll", "I'll"),
        ("i've", "I've"),
        ("i'd",  "I'd"),
        ("im",   "I'm"),      // "im" → "I'm" (single-letter I gets capitalized by fixContractions)
        // Missing-apostrophe negations
        ("dont",     "don't"),
        ("doesnt",   "doesn't"),
        ("didnt",    "didn't"),
        ("isnt",     "isn't"),
        ("arent",    "aren't"),
        ("wasnt",    "wasn't"),
        ("werent",   "weren't"),
        ("cant",     "can't"),
        ("cannot",   "cannot"),  // canonical, leave alone — listed so we don't mis-fire on "can't"
        ("wont",     "won't"),
        ("wouldnt",  "wouldn't"),
        ("couldnt",  "couldn't"),
        ("shouldnt", "shouldn't"),
        ("hasnt",    "hasn't"),
        ("havent",   "haven't"),
        ("hadnt",    "hadn't"),
        ("mustnt",   "mustn't"),
        ("neednt",   "needn't"),
        ("shan't",   "shan't"),  // British form
        ("shant",    "shan't"),
        // Pronoun + are/have
        ("youre",    "you're"),
        ("youve",    "you've"),
        ("youll",    "you'll"),
        ("youd",     "you'd"),
        ("theyre",   "they're"),
        ("theyve",   "they've"),
        ("theyll",   "they'll"),
        ("theyd",    "they'd"),
        ("weve",     "we've"),
        ("well",     "well"),     // intentional no-op (collision with adverb)
        ("were",     "were"),     // intentional: "we're" is pronounced distinctly; keep as "were"
        ("whats",    "what's"),
        ("thats",    "that's"),
        ("hes",      "he's"),
        ("shes",     "she's"),
        ("its",      "it's"),     // CHANGED: Apply it's — Qwen3 prompt says to fix homophones
        ("lets",     "let's"),
    ]

    /// Replace common no-apostrophe contractions with apostrophe'd forms.
    /// Word-boundary matched and case-insensitive on the LHS, but we preserve
    /// the original casing pattern when emitting (DONT → DON'T, Dont → Don't).
    private func fixContractions(_ text: String) -> String {
        var result = text
        for (wrong, right) in contractionMap where wrong != right {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsResult = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            // Apply back-to-front so ranges stay valid.
            for match in matches.reversed() {
                let original = nsResult.substring(with: match.range)
                let replacement: String
                if original == original.uppercased() {
                    replacement = right.uppercased()
                } else if let first = original.first, first.isUppercase {
                    replacement = right.prefix(1).uppercased() + right.dropFirst()
                } else {
                    replacement = right
                }
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Number Formatting

    private static let unitMap: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let scaleMap: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000
    ]

    /// Ordinal-word lookup (single-word ordinals only — multi-word handled by
    /// `convertOrdinals` which folds e.g. "twenty third" → "23rd").
    private static let ordinalSuffixForUnit: [String: (Int, String)] = [
        "first":   (1, "st"), "second":  (2, "nd"), "third":   (3, "rd"),
        "fourth":  (4, "th"), "fifth":   (5, "th"), "sixth":   (6, "th"),
        "seventh": (7, "th"), "eighth":  (8, "th"), "ninth":   (9, "th"),
        "tenth":   (10, "th"), "eleventh": (11, "th"), "twelfth": (12, "th"),
        "thirteenth": (13, "th"), "fourteenth": (14, "th"), "fifteenth": (15, "th"),
        "sixteenth": (16, "th"), "seventeenth": (17, "th"), "eighteenth": (18, "th"),
        "nineteenth": (19, "th"), "twentieth": (20, "th"), "thirtieth": (30, "th"),
        "fortieth": (40, "th"), "fiftieth": (50, "th"), "sixtieth": (60, "th"),
        "seventieth": (70, "th"), "eightieth": (80, "th"), "ninetieth": (90, "th"),
        "hundredth": (100, "th"), "thousandth": (1000, "th"),
    ]

    /// Convert "twenty third" → "23rd", "hundred and first" → "101st", "third"
    /// stays as-is (single-word — readers prefer "third" to "3rd"). Runs BEFORE
    /// number-word folding so "twenty" doesn't get eaten by it first.
    private func convertOrdinals(_ text: String) -> String {
        let nsText = text as NSString
        let matches = Self.rxWord.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var replacements: [(NSRange, String)] = []
        var i = 0
        while i < matches.count {
            let word = nsText.substring(with: matches[i].range).lowercased()
            // Multi-word: tens-word followed by ordinal-word → e.g. "twenty third"
            if let tens = Self.tensMap[word], i + 1 < matches.count {
                let next = nsText.substring(with: matches[i+1].range).lowercased()
                if let (unitVal, suffix) = Self.ordinalSuffixForUnit[next], unitVal < 10 {
                    let runStart = matches[i].range.location
                    let runEnd = matches[i+1].range.location + matches[i+1].range.length
                    let range = NSRange(location: runStart, length: runEnd - runStart)
                    replacements.append((range, "\(tens + unitVal)\(suffix)"))
                    i += 2
                    continue
                }
            }
            i += 1
        }
        var result = text
        for (range, replacement) in replacements.reversed() {
            if let r = Range(range, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
    }

    // MARK: - Pre-number deterministic normalizers
    //
    // These run BEFORE `convertNumberWords` so multi-word number phrases tied
    // to a unit/context (time, money, version) get matched as units before the
    // general folder collapses them into a single integer (which produces
    // garbage like "nine thirty am" → 9+30 = "39am").

    /// Map number-WORDS 0-59 (no digit forms — those are handled by the existing
    /// post-fold `convertSpokenTimes` regex). Covers single units, teens,
    /// bare tens, and "tens unit" pairs.
    private func wordsToMinuteOrHour(_ tokens: [String]) -> Int? {
        guard !tokens.isEmpty, tokens.count <= 2 else { return nil }
        if tokens.count == 1 {
            if let v = Self.unitMap[tokens[0]] { return v }
            if let v = Self.tensMap[tokens[0]] { return v }
            return nil
        }
        // Two tokens: must be tens + unit (1-9).
        guard let tens = Self.tensMap[tokens[0]],
              let unit = Self.unitMap[tokens[1]],
              unit < 10 else { return nil }
        return tens + unit
    }

    /// "nine thirty AM" → "9:30 AM", "ten fifteen pm" → "10:15 PM",
    /// "five AM" → "5 AM", "nine AM" → "9 AM", "nine thirty a m" → "9:30 AM".
    /// CRITICAL: blocks "nine thirty" from being folded to 39 by the general
    /// number-word folder. Single-hour forms (no minutes) defer to the
    /// existing `convertSpokenTimes` regex for "9am" formatting.
    private func normalizeSpokenTimesPrePass(_ text: String) -> String {
        // (hour-words) (optional minute-words) (a.m.|am|p.m.|pm), word-bounded.
        // Hour: 1-2 words. Minute: 0-2 words. AM/PM tolerates spaces and dots.
        let hourWord = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)"
        let minWord  = "(?:oh|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty)"
        // Captures: 1=hour phrase, 2=optional minute phrase, 3=am/pm marker
        let pat = "(?i)\\b(\(hourWord)(?:\\s+\(hourWord))?)(?:\\s+(\(minWord)(?:\\s+\(minWord))?))?\\s+(a\\.?\\s*m\\.?|p\\.?\\s*m\\.?)\\b"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        var result = text
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let hourTokens = ns.substring(with: m.range(at: 1)).lowercased().split(separator: " ").map(String.init)
            guard let hour = wordsToMinuteOrHour(hourTokens), hour >= 0, hour <= 23 else { continue }
            var minute: Int? = nil
            if m.range(at: 2).location != NSNotFound {
                let minTokens = ns.substring(with: m.range(at: 2)).lowercased()
                    .split(separator: " ").map(String.init)
                    .filter { $0 != "oh" }  // "nine oh five" → minute "5"
                if let mv = wordsToMinuteOrHour(minTokens.isEmpty ? ["zero"] : minTokens),
                   mv >= 0, mv < 60 {
                    minute = mv
                } else {
                    continue  // bail — don't half-rewrite
                }
            }
            let suffixRaw = ns.substring(with: m.range(at: 3))
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "")
            let suffix = (suffixRaw == "am") ? "AM" : "PM"
            let formatted: String
            if let mm = minute {
                formatted = String(format: "%d:%02d %@", hour, mm, suffix)
            } else {
                formatted = "\(hour) \(suffix)"  // single-hour: keep simple, convertSpokenTimes turns it into "9am" if desired
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: formatted)
        }
        return result
    }

    /// "twelve point five million dollars" → "$12.5 million" (keeps the word
    /// "million" so the downstream `applyCurrencyMagnitudes` can fold it to
    /// "$12.5M" if desired). Also handles "twenty million dollars" → "$20 million".
    ///
    /// CRITICAL: blocks the general number-folder from seeing the "point" word
    /// (which stops the run, producing "12 point $5000000" garbage when
    /// "five million dollars" then folds to $5,000,000).
    private func normalizeSpokenMoneyMagnitudesPrePass(_ text: String) -> String {
        let intWords = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)"
        let mag      = "(million|billion|thousand|k)"
        let currency = "(?:dollars?|bucks?|euros?|pounds?|yen|usd|gbp|eur)"
        // (1=int phrase) (optional " point " + 2=fractional phrase) ws mag ws currency
        let pat = "(?i)\\b(\(intWords)(?:\\s+(?:and\\s+)?\(intWords))*)(?:\\s+point\\s+(\(intWords)(?:\\s+\(intWords))*))?\\s+\(mag)\\s+\(currency)\\b"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        var result = text
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            // Fold the integer part using the existing convertNumberWords on a
            // tiny substring (cheap and re-uses the proven folder).
            let intPhrase = ns.substring(with: m.range(at: 1))
            let folded = convertNumberWords(intPhrase).trimmingCharacters(in: .whitespaces)
            guard Int(folded) != nil || folded.allSatisfy({ $0.isNumber }) else { continue }

            var numberText = folded
            if m.range(at: 2).location != NSNotFound {
                // Fractional part — each word becomes a single digit in sequence.
                // "five" → "5", "five seven" → "57".
                let fracPhrase = ns.substring(with: m.range(at: 2)).lowercased()
                let digits = fracPhrase.split(separator: " ").compactMap { word -> String? in
                    if let v = Self.unitMap[String(word)], v < 10 { return String(v) }
                    return nil
                }.joined()
                if !digits.isEmpty {
                    numberText += ".\(digits)"
                }
            }
            let magWord = ns.substring(with: m.range(at: 3))
            let replacement = "$\(numberText) \(magWord)"
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    /// "version two point one point seven" → "v2.1.7",
    /// "version 1 2 3" / "version 1.2.3" stays as "v1.2.3".
    /// Triggered ONLY by the leading word "version" or "v" so prose like
    /// "point one is X" doesn't accidentally match.
    private func normalizeVersionNumbers(_ text: String) -> String {
        let comp = "(?:\\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)"
        // "version <comp> (point|dot|.|\s) <comp> ..." — require at least 2 components.
        let pat = "(?i)\\bversion\\s+(\(comp))(?:\\s*(?:point|dot|\\.)\\s*(\(comp)))(?:\\s*(?:point|dot|\\.)\\s*(\(comp)))?(?:\\s*(?:point|dot|\\.)\\s*(\(comp)))?\\b"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        var result = text
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var parts: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                guard r.location != NSNotFound else { continue }
                let raw = ns.substring(with: r).lowercased()
                if let n = Int(raw) {
                    parts.append(String(n))
                } else if let v = Self.unitMap[raw] {
                    parts.append(String(v))
                } else if let v = Self.tensMap[raw] {
                    parts.append(String(v))
                } else if raw == "hundred" {
                    parts.append("100")
                } else {
                    parts = []  // unknown token — bail
                    break
                }
            }
            guard parts.count >= 2 else { continue }
            let replacement = "v" + parts.joined(separator: ".")
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    /// "three two one" / "5 4 3 2 1" / "three, two, one" → "3, 2, 1".
    /// Catches sequential descending small integers (digits OR words) of
    /// length ≥3, all distinct, monotonically decreasing by 1. Conservative:
    /// requires the run to end at 1 OR be followed by "go"/"liftoff"/"blast off"
    /// so casual "one two three testing" doesn't trip it.
    private func normalizeCountdowns(_ text: String) -> String {
        let nWord = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten)"
        let numTok = "(?:\\d{1,2}|\(nWord))"
        // 3-5 number tokens separated by spaces or commas, optionally followed
        // by a launch word.
        let pat = "(?i)\\b(\(numTok))[,\\s]+(\(numTok))[,\\s]+(\(numTok))(?:[,\\s]+(\(numTok)))?(?:[,\\s]+(\(numTok)))?(\\s+(?:go|liftoff|lift\\s*off|blast\\s*off))?"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        func toInt(_ s: String) -> Int? {
            let l = s.lowercased()
            if let n = Int(l) { return n }
            return Self.unitMap[l]
        }
        var result = text
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var nums: [Int] = []
            for i in 1...5 {
                let r = m.range(at: i)
                if r.location == NSNotFound { continue }
                guard let n = toInt(ns.substring(with: r)) else { nums = []; break }
                nums.append(n)
            }
            guard nums.count >= 3 else { continue }
            // Strictly descending by 1.
            var ok = true
            for j in 1..<nums.count where nums[j] != nums[j-1] - 1 { ok = false; break }
            if !ok { continue }
            // Either ends at 1, or trailed by launch word.
            let hasLaunch = m.numberOfRanges > 6 && m.range(at: 6).location != NSNotFound
            guard nums.last == 1 || hasLaunch else { continue }
            var replacement = nums.map(String.init).joined(separator: ", ")
            if hasLaunch {
                replacement += ns.substring(with: m.range(at: 6))
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    /// "three point one four" → "3.14", "zero point five" → "0.5".
    /// Runs BEFORE `convertNumberWords` so "X point Y" survives as a decimal.
    /// Negative lookahead prevents collision with the money-magnitude pre-pass
    /// (which already handled "two point five million dollars").
    private func normalizeDecimalNumbers(_ text: String) -> String {
        let intWord = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)"
        let decWord = "(?:zero|one|two|three|four|five|six|seven|eight|nine)"
        // Don't fire when followed by a scale word — money pre-pass already handled that.
        let pat = "(?i)\\b(\(intWord)(?:\\s+\(intWord))*)\\s+point\\s+(\(decWord)(?:\\s+\(decWord))*)(?!\\s*(?:million|billion|thousand|\\bk\\b|\\bm\\b|\\bb\\b))"
        guard let rx = try? NSRegularExpression(pattern: pat) else { return text }
        var result = text
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let intPhrase = ns.substring(with: m.range(at: 1))
            let decPhrase = ns.substring(with: m.range(at: 2)).lowercased()
            let folded = convertNumberWords(intPhrase).trimmingCharacters(in: .whitespaces)
            guard folded.allSatisfy({ $0.isNumber }) else { continue }
            let decDigits = decPhrase.split(separator: " ").compactMap { word -> String? in
                if let v = Self.unitMap[String(word)], v < 10 { return String(v) }
                return nil
            }.joined()
            guard !decDigits.isEmpty else { continue }
            result = (result as NSString).replacingCharacters(in: m.range, with: "\(folded).\(decDigits)")
        }
        return result
    }

    /// "300 milliseconds" → "300ms", "1.5 seconds" → "1.5s" (decimal only),
    /// "500 nanoseconds" → "500ns", "100 microseconds" → "100µs".
    /// Runs AFTER number-word folding so spoken numbers are already digits.
    private func normalizeLatencyDurations(_ text: String) -> String {
        let subs: [(String, String)] = [
            ("nanoseconds", "ns"), ("nanosecond", "ns"),
            ("microseconds", "µs"), ("microsecond", "µs"),
            ("milliseconds", "ms"), ("millisecond", "ms"),
        ]
        var result = text
        for (unit, abbr) in subs {
            let pat = #"(\d+(?:\.\d+)?)\s+"# + NSRegularExpression.escapedPattern(for: unit) + #"\b"#
            guard let rx = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
            result = rx.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\(abbr)")
        }
        // Seconds: only abbreviate when decimal (2.5s not 3s — "3 seconds" is natural prose).
        if let rx = try? NSRegularExpression(pattern: #"(\d+\.\d+)\s+seconds?\b"#, options: .caseInsensitive) {
            result = rx.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1s")
        }
        return result
    }

    /// "three pm" → "3pm", "eleven am" → "11am", "twelve thirty pm" → "12:30pm".
    /// Conservative: only fires when AM/PM follows a number or number-word.
    private func convertSpokenTimes(_ text: String) -> String {
        var result = text
        // Pattern after number folding ran: digit(s) optionally followed by
        // ":digit(s)" or " thirty/fifteen/etc", then space, then am/pm.
        let pat = #"(\d{1,2})(?:[:\s](\d{1,2}))?\s+(a\.?m\.?|p\.?m\.?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else {
            return result
        }
        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let h = ns.substring(with: m.range(at: 1))
            let mm = m.range(at: 2).location != NSNotFound
                ? ns.substring(with: m.range(at: 2))
                : ""
            let suffix = ns.substring(with: m.range(at: 3))
                .lowercased().replacingOccurrences(of: ".", with: "")
            let formatted = mm.isEmpty ? "\(h)\(suffix)" : "\(h):\(mm.count == 1 ? "0" + mm : mm)\(suffix)"
            result = (result as NSString).replacingCharacters(in: m.range, with: formatted)
        }
        return result
    }

    /// Walk the token stream and fold runs of number words into integers.
    /// "twenty three" → 23, "one hundred and twenty five" → 125,
    /// "two thousand twenty six" → 2026. Stops on any non-number word.
    private func convertNumberWords(_ text: String) -> String {
        let nsText = text as NSString
        let matches = Self.rxWord.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var replacements: [(NSRange, String)] = []
        var i = 0
        while i < matches.count {
            var runEnd = i
            var runValue = 0
            var current = 0
            var sawAny = false

            while runEnd < matches.count {
                let word = nsText.substring(with: matches[runEnd].range).lowercased()
                if word == "and" && sawAny {
                    runEnd += 1
                    continue
                }
                if let v = Self.unitMap[word] {
                    current += v
                    sawAny = true
                } else if let v = Self.tensMap[word] {
                    current += v
                    sawAny = true
                } else if let scale = Self.scaleMap[word] {
                    if current == 0 { current = 1 }
                    if scale == 100 {
                        current *= 100
                    } else {
                        runValue += current * scale
                        current = 0
                    }
                    sawAny = true
                } else {
                    break
                }
                runEnd += 1
            }

            if sawAny && runEnd > i {
                runValue += current
                let runStart = matches[i].range.location
                let runEndLoc = matches[runEnd - 1].range.location + matches[runEnd - 1].range.length
                let runRange = NSRange(location: runStart, length: runEndLoc - runStart)
                let tokenCount = runEnd - i
                // Only emit digits if number is >=10 OR multi-token: "one apple"
                // reads better than "1 apple".
                if runValue >= 10 || tokenCount > 1 {
                    replacements.append((runRange, String(runValue)))
                }
                i = runEnd
            } else {
                i += 1
            }
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    // MARK: - Currency

    private let currencyMap: [(String, String)] = [
        ("dollars", "$"), ("dollar", "$"),
        ("bucks", "$"), ("buck", "$"),
        ("euros", "€"), ("euro", "€"),
        ("pounds", "£"), ("pound", "£"),
        ("gbp", "£"), ("eur", "€"), ("usd", "$"),
        ("yen", "¥"),
    ]

    /// Convert "<digits> <currency-word>" → "<symbol><digits>".
    /// Runs after number folding so "five dollars" → "5 dollars" → "$5".
    private func convertCurrency(_ text: String) -> String {
        var result = text
        for (word, symbol) in currencyMap {
            let pattern = #"(\d+(?:[.,]\d+)?)\s+"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                result = (result as NSString).replacingCharacters(in: m.range, with: "\(symbol)\(digits)")
            }
        }
        return result
    }

    // MARK: - Percent

    /// Convert "<number> percent" → "<number>%".
    /// Examples (verified by inline tests):
    ///   "20 percent"      → "20%"
    ///   "99 percent"      → "99%"
    ///   "0.5 percent"     → "0.5%"
    ///   "15 percent off"  → "15% off"
    ///   "point 5 percent" → "0.5%"   (handles unfolded "point N")
    private func convertPercent(_ text: String) -> String {
        var result = text
        // Pre-pass: "point N" with no leading digit → "0.N"
        if let rx = try? NSRegularExpression(pattern: #"\bpoint\s+(\d+)\s+percent\b"#, options: .caseInsensitive) {
            let r = NSRange(result.startIndex..., in: result)
            result = rx.stringByReplacingMatches(in: result, range: r, withTemplate: "0.$1 percent")
        }
        guard let rx = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s+percent\b"#, options: .caseInsensitive) else {
            return result
        }
        let r = NSRange(result.startIndex..., in: result)
        return rx.stringByReplacingMatches(in: result, range: r, withTemplate: "$1%")
    }

    // MARK: - Currency magnitude suffixes

    /// "<symbol><digits> million|billion|thousand|k|m|b" → "<symbol><digits>M" etc.
    /// Only fires when a currency symbol is already present, so non-monetary
    /// "5 million users" stays as words.
    /// Examples:
    ///   "$2.5 million"  → "$2.5M"
    ///   "$10 k"         → "$10k"
    ///   "$500 thousand" → "$500K"
    ///   "€3 billion"    → "€3B"
    private func applyCurrencyMagnitudes(_ text: String) -> String {
        let mags: [(String, String)] = [
            ("billion", "B"), ("million", "M"), ("thousand", "K"),
            ("bn", "B"), ("mm", "M"), ("mn", "M"),
            ("b", "B"), ("m", "M"), ("k", "k"),
        ]
        var result = text
        for (word, abbr) in mags {
            let pattern = #"([$€£¥])(\d+(?:\.\d+)?)\s+"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
            guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let r = NSRange(result.startIndex..., in: result)
            result = rx.stringByReplacingMatches(in: result, range: r, withTemplate: "$1$2\(abbr)")
        }
        return result
    }

    // MARK: - Spoken quotes ("she said quote ... end quote")

    /// Quote-introducer verbs that signal the next chunk is verbatim speech.
    private static let quoteVerbs: [String] = [
        "said", "says", "saying", "goes", "go", "asked", "replied", "told me",
        "literally said", "was like", "were like", "is like", "are like",
        "i'm like", "she's like", "he's like", "they're like", "we're like",
    ]

    /// Wrap "<verb> quote ... end quote" spans in smart quotes.
    /// Also handles the bare "quote ... end quote" pattern (no preceding verb).
    /// Examples:
    ///   "she said quote I'll be there end quote"
    ///       → 'she said "I'll be there"'
    ///   "he literally said quote we don't have budget end quote"
    ///       → 'he literally said "we don't have budget"'
    ///   "quote ship it end quote was the message"
    ///       → '"ship it" was the message'
    private func wrapSpokenQuotes(_ text: String) -> String {
        var result = text
        // Greedy non-greedy: match "quote ... end quote" / "unquote" / "close quote".
        let pattern = #"(?i)\bquote\s+(.+?)\s+(?:end\s+quote|unquote|close\s+quote)\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let inner = (result as NSString).substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            let replacement = "\u{201C}\(inner)\u{201D}"
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    // MARK: - Spoken parens ("paren ... close paren")

    /// Convert bracketed-aside spoken markers to literal parentheses.
    /// The voice-command pass already handles "open paren" / "close paren";
    /// this catches the bare-"paren" variant and the "in parens X" shorthand.
    /// Examples:
    ///   "I went to the store paren by the way close paren and bought milk"
    ///       → "I went to the store (by the way) and bought milk"
    ///   "the API rate limit paren 100 per second close paren is too low"
    ///       → "the API rate limit (100 per second) is too low"
    ///   "in parens this is an aside"
    ///       → "(this is an aside)"
    private func wrapSpokenParens(_ text: String) -> String {
        var result = text
        // "paren X close paren" / "paren X end paren" / "paren X paren close"
        let pattern = #"(?i)\bparen\s+(.+?)\s+(?:close\s+paren|end\s+paren|paren\s+close)\b"#
        if let rx = try? NSRegularExpression(pattern: pattern) {
            let ns = result as NSString
            let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let inner = (result as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                result = (result as NSString).replacingCharacters(in: m.range, with: "(\(inner))")
            }
        }
        // "in parens X" — wrap the following clause up to sentence-ish terminator.
        if let rx = try? NSRegularExpression(pattern: #"(?i)\bin\s+parens?\s+([^.,;!?\n]+)"#) {
            let ns = result as NSString
            let matches = rx.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let inner = (result as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                result = (result as NSString).replacingCharacters(in: m.range, with: "(\(inner))")
            }
        }
        return result
    }

    // MARK: - Inline verification (compile-time documentation)
    //
    // These cases are exercised by `_debugRunSelfTests()` and inline above:
    //   "twenty percent"         → "20%"
    //   "ninety nine percent"    → "99%"
    //   "point five percent"     → "0.5%"
    //   "fifteen percent off"    → "15% off"
    //   "twenty dollars"         → "$20"
    //   "five hundred bucks"     → "$500"
    //   "two point five million" (money ctx) → "$2.5M"
    //   "ten k"                  (money ctx) → "$10k"
    //   "fifty euros"            → "€50"
    //   "ten pounds"             → "£10"
    //   "paren by the way close paren"            → "(by the way)"
    //   "she said quote I'll be there end quote"  → "she said “I'll be there”"

    // MARK: - Email / URL Reconstruction

    /// Convert spoken email/URL fragments into compact form.
    /// Examples:
    ///   "john at gmail dot com"          → "john@gmail.com"
    ///   "go to example dot com"          → "go to example.com"
    ///   "double you double you double you dot example dot com" → "www.example.com"
    private func reconstructEmailsAndURLs(_ text: String) -> String {
        var result = text

        // www reconstruction first (multiple variants people actually say).
        let wwwPhrases = [
            "double you double you double you",
            "double u double u double u",
            "w w w",
            "triple double u",
            "triple w",
        ]
        for phrase in wwwPhrases {
            result = result.replacingOccurrences(of: phrase, with: "www", options: .caseInsensitive)
        }

        // Phrase substitutions, longest first so ".co.uk" beats ".co".
        let phrases: [(String, String)] = [
            (" at gmail dot com",   "@gmail.com"),
            (" at outlook dot com", "@outlook.com"),
            (" at yahoo dot com",   "@yahoo.com"),
            (" at icloud dot com",  "@icloud.com"),
            (" at hotmail dot com", "@hotmail.com"),
            (" dot co dot uk", ".co.uk"),
            (" dot com",  ".com"),
            (" dot org",  ".org"),
            (" dot net",  ".net"),
            (" dot io",   ".io"),
            (" dot co",   ".co"),
            (" dot dev",  ".dev"),
            (" dot ai",   ".ai"),
            (" dot app",  ".app"),
            (" dot xyz",  ".xyz"),
            (" dot me",   ".me"),
            (" dot gg",   ".gg"),
            (" dot sh",   ".sh"),
            (" dot so",   ".so"),
            (" dot tv",   ".tv"),
            (" dot us",   ".us"),
            (" dot uk",   ".uk"),
            (" dot ca",   ".ca"),
            (" dot de",   ".de"),
            (" dot fr",   ".fr"),
            (" dot au",   ".au"),
            (" dot edu",  ".edu"),
            (" dot gov",  ".gov"),
            (" dot info", ".info"),
            (" dot tech", ".tech"),
            (" dot cloud",".cloud"),
            (" at sign ", "@"),
            (" underscore ", "_"),
            (" forward slash ", "/"),
            (" slash ",   "/"),
            (" colon slash slash ", "://")
        ]
        for (spoken, written) in phrases {
            result = result.replacingOccurrences(of: spoken, with: written, options: .caseInsensitive)
        }

        // Bare " at " → "@" only if right side already has a dot (TLD-ish).
        let nsText = result as NSString
        let matches = Self.rxEmailLikeAtPattern.matches(
            in: result,
            range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches.reversed() {
            let rightSide = nsText.substring(with: match.range(at: 2))
            if rightSide.contains(".") {
                let replacement = "\(nsText.substring(with: match.range(at: 1)))@\(rightSide)"
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        return result
    }

    // MARK: - Whitespace + Punctuation Cleanup

    /// Final whitespace pass — collapse double spaces, fix space-before-punct,
    /// ensure space-after-punct, trim outer whitespace.
    private func cleanWhitespace(_ text: String) -> String {
        var result = text
        // Collapse runs of spaces/tabs to a single space in ONE regex pass.
        // Newlines and bullets/backticks are structural — leave them untouched
        // so the polish stage can honor injected list / paragraph / code
        // markers from earlier passes.
        // BUGFIX (perf): replaced the `while contains("  ")` loop — that was
        // O(n) per pass and O(log n) passes on long inputs, causing repeated
        // allocations on dense whitespace. The regex form is one linear pass.
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        // Collapse 3+ consecutive newlines down to exactly 2 (one blank line
        // separating paragraphs). Allows topic-shift / list / quoted-message
        // passes to safely emit `\n\n` without compounding into walls of blank
        // lines.
        result = result.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        let range = NSRange(result.startIndex..., in: result)
        result = Self.rxPunctSpacing.stringByReplacingMatches(in: result, range: range, withTemplate: "$1 $2")
        // Trim leading/trailing whitespace + newlines of the WHOLE string.
        // Internal newlines, leading `-` bullets and backticks within the
        // text body are preserved.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Pre-capitalization punctuation cleanup — drop space-before-punct, dedupe
    /// repeated periods/commas, dedupe spaces.
    private func cleanupPunctuation(_ text: String) -> String {
        var result = text
        let r1 = NSRange(result.startIndex..., in: result)
        result = Self.rxSpaceBeforePunct.stringByReplacingMatches(in: result, range: r1, withTemplate: "$1")
        let r2 = NSRange(result.startIndex..., in: result)
        result = Self.rxRepeatedDots.stringByReplacingMatches(in: result, range: r2, withTemplate: ".")
        let r3 = NSRange(result.startIndex..., in: result)
        result = Self.rxRepeatedCommas.stringByReplacingMatches(in: result, range: r3, withTemplate: ",")
        // BUGFIX (perf): see `cleanWhitespace` — same loop replaced with regex.
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    // MARK: - Acronym joining
    //
    // "F B I" → "FBI", "U S A" → "USA", "C E O of the company" → "CEO of the company".
    // Requires 2+ consecutive single-letter capitals separated by spaces. Lowercase
    // letters or longer tokens break the run.
    //
    // BUGFIX: trailing negative lookahead `(?!['\u{2019}])` prevents joining when
    // the last single-letter capital is immediately followed by an apostrophe,
    // which would signal a contraction ("I'm" / "I've") rather than an acronym
    // letter. Without this, "F B I I'm" → "FBII'm". The `\b` alone doesn't help
    // because `'` is a non-word char and so `\b` matches between `I` and `'`.
    // We still allow "FBI's" (possessive) to be formed via the polish stage —
    // it would arrive as "F B I's" which this regex declines to touch, but the
    // LLM polish will collapse it correctly. Acceptable trade-off; favouring
    // the false-negative on possessives over the false-positive on contractions.
    // NOTE: This is a Swift raw string (`#"..."#`), so `\u{xxxx}` escapes are NOT
    // processed by Swift — the regex engine would receive them literally and ICU
    // doesn't understand `\u{xxxx}` (it uses `\uXXXX`). Use the literal character.
    private static let rxAcronymRun = try! NSRegularExpression(
        pattern: #"\b([A-Z])(?:\s+([A-Z])){1,}\b(?!['’])"#
    )

    /// Strip internal whitespace from runs of 2+ single uppercase letters.
    private func joinAcronyms(_ text: String) -> String {
        let ns = text as NSString
        let matches = Self.rxAcronymRun.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for m in matches.reversed() {
            let original = (result as NSString).substring(with: m.range)
            let joined = original.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            result = (result as NSString).replacingCharacters(in: m.range, with: joined)
        }
        return result
    }

    // MARK: - Brand-name joining
    //
    // Multi-word brand spellings the all-caps acronym regex can't catch.
    // "chat GPT" / "Chat GPT" / "chat gpt" → "ChatGPT". Matched case-insensitively
    // as whole words; the value is emitted verbatim with the canonical casing.
    private let brandJoinMap: [(String, String)] = [
        // AI products
        ("chat gpt", "ChatGPT"),
        ("chat g p t", "ChatGPT"),
        ("chat gbt", "ChatGPT"),          // ASR mishears "GPT" as "GBT"
        ("chat g b t", "ChatGPT"),
        // Common heavily-garbled ASR variants. Parakeet sometimes hears the
        // breathy "ch-" at the start of "ChatGPT" as a name onset ("Chachi",
        // "Chatchi") and the trailing "-PT" as an isolated word ("Pt",
        // "Petey"). Rule-based catch BEFORE the LLM polisher, so even when
        // polish is disabled / fails / times out, the canonical form lands.
        ("chachi pt", "ChatGPT"),
        ("chachi p t", "ChatGPT"),
        ("chatchi pt", "ChatGPT"),
        ("chatchi petey", "ChatGPT"),
        ("chatchee pt", "ChatGPT"),
        ("chatchi p t", "ChatGPT"),
        ("chatchy pt", "ChatGPT"),
        ("open ai", "OpenAI"),
        ("claude code", "Claude Code"),
        ("claude codework", "Claude Code"),  // ASR run-on
        ("claude clock code", "Claude Code"), // ASR mishears
        ("anthropic", "Anthropic"),
        ("claude", "Claude"),
        ("gemini", "Gemini"),
        ("perplexity", "Perplexity"),
        ("midjourney", "Midjourney"),
        ("co pilot", "Copilot"),
        ("github copilot", "GitHub Copilot"),

        // Voice/dictation competitors
        ("wispr flow", "Wispr Flow"),
        ("whisper flow", "Wispr Flow"),
        ("whisperflow", "Wispr Flow"),
        ("super whisper", "Superwhisper"),
        ("superwhisper", "Superwhisper"),
        ("willow voice", "Willow Voice"),
        ("willow", "Willow"),
        ("voice flow", "Voice Flow"),

        // General tech
        ("microsoft 365", "Microsoft 365"),
        ("git hub", "GitHub"),
        ("github", "GitHub"),
        ("you tube", "YouTube"),
        ("face time", "FaceTime"),
        ("face book", "Facebook"),
        ("instagram", "Instagram"),
        ("whats app", "WhatsApp"),
        ("tik tok", "TikTok"),
        ("x code", "Xcode"),
        ("vs code", "VS Code"),
        ("v s code", "VS Code"),
        ("mac os", "macOS"),
        ("i o s", "iOS"),
        ("api", "API"),
        ("cli", "CLI"),
        ("sdk", "SDK"),
        ("npm", "npm"),
        ("docker", "Docker"),
        ("figma", "Figma"),
        ("notion", "Notion"),
        ("slack", "Slack"),
        ("linear", "Linear"),
        ("zoom", "Zoom"),
        ("airpods", "AirPods"),
        ("iphone", "iPhone"),
        ("ipad", "iPad"),
        ("macbook", "MacBook"),
        ("imac", "iMac"),
    ]

    /// Replace known multi-word brand spellings with their canonical form.
    /// Runs AFTER `joinAcronyms` and AFTER `capitalizeSentences` so brand casing
    /// (e.g. "ChatGPT") overrides any sentence-start capitalization that may
    /// have happened upstream.
    private func collapseBrandNames(_ text: String) -> String {
        var result = text
        for (spoken, written) in brandJoinMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: written
                )
            }
        }
        return result
    }

    // MARK: - Em-dash strip

    /// Em / en dashes never appear in output. Replace with spaced hyphen.
    /// Defense-in-depth: called both from `applySmartPunctuation` (early) and
    /// at the end of `format` (after any other transformation could have
    /// reintroduced one).
    private func stripEmDashes(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: " \u{2014} ", with: " - ")
        result = result.replacingOccurrences(of: "\u{2014}", with: " - ")
        result = result.replacingOccurrences(of: " \u{2013} ", with: " - ")
        result = result.replacingOccurrences(of: "\u{2013}", with: " - ")
        // BUGFIX (perf): see `cleanWhitespace` — same loop replaced with regex.
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    // MARK: - ASR repetition deduplication

    /// Collapse consecutive repeated words.
    /// "I'm I'm I'm talking" → "I'm talking"
    /// "the the cat sat" → "the cat sat"
    /// Splits on spaces, compares tokens case-insensitively after stripping
    /// leading/trailing punctuation, keeps the first occurrence of each run.
    private func deduplicateRepeatedWords(_ text: String) -> String {
        let tokens = text.components(separatedBy: " ")
        var result: [String] = []
        var lastCore = ""
        let strip = CharacterSet(charactersIn: ".,!?;:\"'()[]{}").union(
            CharacterSet(charactersIn: "\u{2018}\u{2019}\u{201C}\u{201D}\u{2014}\u{2013}")
        )
        for token in tokens {
            guard !token.isEmpty else { continue }
            let core = token.trimmingCharacters(in: strip).lowercased()
            if core.isEmpty || core != lastCore {
                result.append(token)
                if !core.isEmpty { lastCore = core }
            }
        }
        return result.joined(separator: " ")
    }

    /// Collapse repeated N-grams ("I noticed I noticed everything" → "I noticed
    /// everything"). Scans a sliding window of 2n tokens and drops the second
    /// occurrence when the first n tokens match the next n tokens (case- and
    /// punctuation-insensitive). Capped at n=3 — 4+ word phrase repetitions are
    /// usually intentional rhetoric and should not be touched.
    private func deduplicateRepeatedPhrases(_ text: String, n: Int) -> String {
        let tokens = text.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 2 * n else { return text }
        let strip = CharacterSet(charactersIn: ".,!?;:\"'()[]{}").union(
            CharacterSet(charactersIn: "\u{2018}\u{2019}\u{201C}\u{201D}\u{2014}\u{2013}")
        )
        func core(_ s: String) -> String { s.trimmingCharacters(in: strip).lowercased() }

        var result: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 2 * n <= tokens.count {
                var matches = true
                for k in 0..<n {
                    if core(tokens[i + k]) != core(tokens[i + n + k]) {
                        matches = false
                        break
                    }
                }
                if matches {
                    for k in 0..<n { result.append(tokens[i + k]) }
                    i += 2 * n
                    continue
                }
            }
            result.append(tokens[i])
            i += 1
        }
        return result.joined(separator: " ")
    }

    // MARK: - Self-correction detection
    //
    // Spoken phrases like "scratch that" or "actually no wait" delete preceding
    // content. We detect multi-word triggers only — single words like "actually"
    // or "wait" are too ambiguous (they appear in normal speech).
    //
    // Cut levels:
    //   - Sentence: back to start-of-utterance or last .!?
    //   - Clause:   back to last , ; or .!?
    //   - Word:     drop preceding 1–3 words, bounded by last , or .!?
    private enum SelfCorrectionCut {
        case sentence
        case clause
        case word
    }

    /// Triggers, longest first so "no scratch that" beats "scratch that".
    /// All matched as whole words, case-insensitive.
    private static let selfCorrectionTriggers: [(phrase: String, cut: SelfCorrectionCut, requiresFollowingContent: Bool)] = [
        // Sentence-cut
        ("let me start over",   .sentence, false),
        ("never mind that",     .sentence, false),
        ("nevermind that",      .sentence, false),
        ("start over",          .sentence, false),
        ("scratch that",        .sentence, false),
        ("delete that",         .sentence, false),
        ("forget that",         .sentence, false),
        // Clause-cut (place "no scratch that" first so it beats "scratch that")
        ("no scratch that",     .clause,   false),
        ("actually no wait",    .clause,   false),
        ("actually wait",       .clause,   false),
        ("wait no",             .clause,   false),
        ("no wait",             .clause,   false),
        // Word-cut
        ("or actually",         .word,     true),
        ("or rather",           .word,     false),
        ("i mean",              .word,     true),
    ]

    /// Apply self-correction trigger phrases iteratively. Idempotent; capped at
    /// 5 passes so degenerate input can't spin.
    private func applySelfCorrections(_ text: String) -> String {
        var result = text
        for _ in 0..<5 {
            guard let next = applySelfCorrectionOnce(result) else { break }
            if next == result { break }
            result = next
        }
        return result
    }

    /// One pass: find the EARLIEST trigger match across all phrases (tie-broken
    /// by longest phrase) and splice. Returns nil if no trigger fires.
    private func applySelfCorrectionOnce(_ text: String) -> String? {
        let ns = text as NSString
        var bestStart = Int.max
        var bestEnd = -1
        var bestCut: SelfCorrectionCut = .word

        for trigger in Self.selfCorrectionTriggers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trigger.phrase))\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let mStart = m.range.location
                let mEnd = m.range.location + m.range.length

                if trigger.requiresFollowingContent {
                    // Need whitespace then at least one letter/digit after the
                    // trigger, before any terminal punctuation.
                    let tail = mEnd < ns.length ? ns.substring(with: NSRange(location: mEnd, length: ns.length - mEnd)) : ""
                    let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
                    guard let firstChar = trimmedTail.first else { continue }
                    if ".!?".contains(firstChar) { continue }
                    if !(firstChar.isLetter || firstChar.isNumber) { continue }
                }

                // Pick earliest start; on tie, longer phrase wins (the triggers
                // list is already longest-first so the first hit at that start
                // is the longest).
                if mStart < bestStart {
                    bestStart = mStart
                    bestEnd = mEnd
                    bestCut = trigger.cut
                }
            }
        }

        guard bestEnd >= 0 else { return nil }

        // Find the cut point in the preceding text.
        let prefix = ns.substring(to: bestStart)
        let suffix = bestEnd < ns.length ? ns.substring(from: bestEnd) : ""
        let cutPoint = findCutPoint(in: prefix, cut: bestCut)
        let kept = String(prefix.prefix(cutPoint))
        // Leave a single space placeholder so downstream regex steps see normal
        // word boundaries. Whitespace cleanup later collapses extras.
        let suffixTrimmed = suffix.drop(while: { $0 == " " || $0 == "\t" })
        let joined: String
        if kept.isEmpty {
            joined = String(suffixTrimmed)
        } else {
            // Trim trailing whitespace off `kept` so we control the join.
            let keptTrimmed = kept.reversed().drop(while: { $0 == " " || $0 == "\t" })
            let rebuilt = String(String(keptTrimmed).reversed())
            joined = rebuilt + " " + String(suffixTrimmed)
        }
        return joined
    }

    /// Scan `prefix` backward for the appropriate cut boundary; return the
    /// index (utf16 offset into prefix as a String count) where kept text ends.
    private func findCutPoint(in prefix: String, cut: SelfCorrectionCut) -> Int {
        let chars = Array(prefix)
        switch cut {
        case .sentence:
            // Find last index of . ! ? (or ellipsis). Keep through that char
            // plus following whitespace.
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                let c = chars[i]
                if c == "." || c == "!" || c == "?" || c == "\u{2026}" {
                    return i + 1
                }
            }
            return 0
        case .clause:
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                let c = chars[i]
                if c == "," || c == ";" || c == "." || c == "!" || c == "?" || c == "\u{2026}" {
                    return i + 1
                }
            }
            return 0
        case .word:
            // Drop preceding 1–3 words, bounded by last , . ! ? ;
            // Walk back, skipping trailing whitespace first, then strip up to 3
            // word tokens, stopping early at a boundary.
            var i = chars.count - 1
            while i >= 0, chars[i].isWhitespace { i -= 1 }
            var wordsDropped = 0
            while i >= 0 && wordsDropped < 3 {
                let c = chars[i]
                if c == "," || c == ";" || c == "." || c == "!" || c == "?" || c == "\u{2026}" {
                    return i + 1
                }
                // Walk through one word
                while i >= 0 {
                    let cc = chars[i]
                    if cc.isWhitespace || cc == "," || cc == ";" || cc == "." || cc == "!" || cc == "?" || cc == "\u{2026}" {
                        break
                    }
                    i -= 1
                }
                wordsDropped += 1
                // Skip whitespace between words
                while i >= 0, chars[i].isWhitespace { i -= 1 }
            }
            return max(0, i + 1)
        }
    }

    // MARK: - Spoken list detection
    //
    // The user dictates lists like:
    //   "point one. this is a test. point two. another point. point three. final point."
    // and expects:
    //   "1. This is a test\n2. Another point\n3. Final point"
    //
    // Triggers:
    //   - "point|number|step" + ordinal-word ("point one", "step three", "number two")
    //   - ordinal-only ("first", "second", "third", ..., "tenth")
    //
    // Rules:
    //   - Require AT LEAST 2 sequential triggers to fire — single mentions stay prose.
    //   - Triggers must sit at a sentence/clause boundary (start of text, or after
    //     `.!?,;` followed by whitespace). This stops "I want to point one out"
    //     and "she is my number one fan" from false-firing.
    //   - Body text between triggers is trimmed, capitalized, and emitted as
    //     `1. ...` / `2. ...` (or `- ...` if `preferBulletsForOrdinalOnly` and
    //     the run is ordinal-only without point/number/step prefix).
    //   - Trailing terminal punctuation on each item is preserved if present.

    private static let listOrdinalWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let listOrdinalOnly: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    private static let listPrefixWords: Set<String> = ["point", "number", "step"]

    /// A located list-marker in the input.
    private struct ListMarker {
        let rangeStart: Int       // utf16 offset where the marker text starts (in original)
        let rangeEnd: Int         // utf16 offset where the marker text ends (exclusive)
        let ordinal: Int          // 1-based ordinal value the speaker used
        let hadPrefix: Bool       // true if "point/number/step <ord>", false if ordinal-only
    }

    /// Find candidate list markers, then emit a reformatted string if a valid
    /// run of >= 2 markers is found. Non-list text outside the run is preserved
    /// verbatim. If multiple runs exist, each is reformatted independently.
    func detectAndFormatLists(_ text: String) -> String {
        // Fast exit: skip expensive regex scan if no trigger words present.
        // This avoids walking 2000-word transcriptions when there is clearly
        // no list structure. Word-boundary check is implicit — we're looking
        // for substrings that will only appear inside trigger words anyway.
        let lower = text.lowercased()
        guard lower.contains("point ") || lower.contains("first") ||
              lower.contains("second") || lower.contains("number ") ||
              lower.contains("step ") else {
            return text
        }

        let markers = findListMarkers(in: text)
        // Filter into "runs" — sequential markers that share consistent style.
        let runs = groupMarkerRuns(markers, in: text)
        guard !runs.isEmpty else { return text }

        // Rebuild from back to front so ranges stay valid.
        var result = text as NSString
        for run in runs.reversed() {
            guard run.count >= 2 else { continue }
            let runStart = run.first!.rangeStart
            // Body goes from end of last marker to either next sentence/end of text.
            // We slice everything from runStart through end-of-text-after-last-item.
            let bodyEnd = findRunEnd(after: run.last!, in: text as NSString)
            let runRange = NSRange(location: runStart, length: bodyEnd - runStart)
            let formatted = formatListRun(run, fullText: text as NSString, bodyEnd: bodyEnd)
            result = result.replacingCharacters(in: runRange, with: formatted) as NSString
        }
        return result as String
    }

    /// Internal candidate before boundary filtering.
    private struct ListMarkerCandidate {
        let rangeStart: Int
        let rangeEnd: Int
        let ordinal: Int
        let hadPrefix: Bool
        let atBoundary: Bool
    }

    /// Scan `text` for every list-marker candidate. A candidate is either:
    ///   (a) "point|number|step" + ordinal-word (e.g. "point one")
    ///   (b) ordinal-only ("first", "second", ...)
    /// We collect ALL candidates first (regardless of boundary), then filter
    /// inside `groupMarkerRuns`: the FIRST marker of any run must sit at a
    /// boundary, but subsequent markers can appear mid-clause as long as the
    /// ordinal sequence is consistent. This handles the speech case where the
    /// dictation arrives with no `.` between items.
    private func findListMarkers(in text: String) -> [ListMarker] {
        let ns = text as NSString
        var candidates: [ListMarkerCandidate] = []
        let wordMatches = Self.rxWord.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var i = 0
        while i < wordMatches.count {
            let m = wordMatches[i]
            let word = ns.substring(with: m.range).lowercased()
            let atBoundary = isAtBoundary(text: ns, before: m.range.location)

            // (a) point/number/step + ordinal-word
            if Self.listPrefixWords.contains(word), i + 1 < wordMatches.count {
                let next = wordMatches[i + 1]
                let nextWord = ns.substring(with: next.range).lowercased()
                if let ord = Self.listOrdinalWords[nextWord] {
                    candidates.append(ListMarkerCandidate(
                        rangeStart: m.range.location,
                        rangeEnd: next.range.location + next.range.length,
                        ordinal: ord,
                        hadPrefix: true,
                        atBoundary: atBoundary
                    ))
                    i += 2
                    continue
                }
            }
            // (b) ordinal-only
            if let ord = Self.listOrdinalOnly[word] {
                candidates.append(ListMarkerCandidate(
                    rangeStart: m.range.location,
                    rangeEnd: m.range.location + m.range.length,
                    ordinal: ord,
                    hadPrefix: false,
                    atBoundary: atBoundary
                ))
            }
            i += 1
        }

        // The downstream grouping needs ListMarker. We convert in-place but
        // stash boundary info as a parallel sidecar via a thread-local-style
        // dictionary — simpler: re-derive boundary at run-build time using
        // the candidate list directly. So we just return mapped markers and
        // re-check boundary inline in groupMarkerRuns via the helper.
        return candidates.map {
            ListMarker(rangeStart: $0.rangeStart, rangeEnd: $0.rangeEnd,
                       ordinal: $0.ordinal, hadPrefix: $0.hadPrefix)
        }
    }

    /// `loc` is the utf16 offset of a candidate first character. Returns true if
    /// the preceding text is empty/whitespace, OR ends in `.!?,;` followed by
    /// whitespace. Conservative — keeps prose triggers like "I want to point one
    /// out" from matching.
    private func isAtBoundary(text: NSString, before loc: Int) -> Bool {
        if loc == 0 { return true }
        // Walk back over whitespace.
        var i = loc - 1
        while i >= 0 {
            let c = text.character(at: i)
            if c == 0x20 || c == 0x09 || c == 0x0A { i -= 1; continue }
            break
        }
        if i < 0 { return true }
        let c = text.character(at: i)
        // ASCII checks for `. ! ? , ;` plus ellipsis U+2026.
        if c == 0x2E /* . */ || c == 0x21 /* ! */ || c == 0x3F /* ? */ ||
           c == 0x2C /* , */ || c == 0x3B /* ; */ || c == 0x2026 {
            return true
        }
        // Also allow start-of-line (preceded by newline only).
        return false
    }

    /// Group markers into runs of >=2 with consistent shape. A run breaks when:
    ///   - ordinal sequence resets unexpectedly (e.g. "first... third... second...")
    ///   - the prefix-style switches mid-run ("point one" then bare "third")
    ///   - the gap between markers exceeds ~600 chars (probably unrelated)
    /// First marker of a run MUST sit at a sentence/clause boundary in the
    /// source text — this is what stops "I want to point one out" from being
    /// treated as the start of a list. Subsequent markers don't require a
    /// boundary; the ordinal-progression itself acts as the signal.
    private func groupMarkerRuns(_ markers: [ListMarker], in text: String) -> [[ListMarker]] {
        guard !markers.isEmpty else { return [] }
        let ns = text as NSString
        var runs: [[ListMarker]] = []
        var current: [ListMarker] = []
        var expectedOrdinal = 1
        var currentHadPrefix: Bool? = nil

        for m in markers {
            let continues = !current.isEmpty &&
                m.ordinal == expectedOrdinal &&
                currentHadPrefix == m.hadPrefix &&
                (m.rangeStart - current.last!.rangeEnd) < 600
            if continues {
                current.append(m)
                expectedOrdinal = m.ordinal + 1
            } else {
                if current.count >= 2 { runs.append(current) }
                // Try starting a new run. First marker MUST sit at a real
                // sentence/clause boundary, and ordinal must be 1 or 2.
                let atBoundary = isAtBoundary(text: ns, before: m.rangeStart)
                if m.ordinal <= 2 && atBoundary {
                    current = [m]
                    expectedOrdinal = m.ordinal + 1
                    currentHadPrefix = m.hadPrefix
                } else {
                    current = []
                    currentHadPrefix = nil
                    expectedOrdinal = 1
                }
            }
        }
        if current.count >= 2 { runs.append(current) }

        // Drop runs where any item has an empty body — protects against
        // "He came first. She came second." style sentences where the
        // ordinal sits at the tail of the clause.
        return runs.filter { run in
            for (idx, m) in run.enumerated() {
                let bodyStart = m.rangeEnd
                let bodyStop: Int
                if idx + 1 < run.count {
                    bodyStop = run[idx + 1].rangeStart
                } else {
                    bodyStop = findRunEnd(after: m, in: ns)
                }
                let raw = bodyStop > bodyStart
                    ? ns.substring(with: NSRange(location: bodyStart, length: bodyStop - bodyStart))
                    : ""
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                    .trimmingCharacters(in: .whitespaces)
                if cleaned.isEmpty { return false }
                // Require at least one word character — a body of just "out"
                // is fine, but a body of just punctuation isn't.
                if cleaned.rangeOfCharacter(from: .letters) == nil { return false }
            }
            return true
        }
    }

    /// Find the end of the body of the LAST list item. Walks forward from
    /// `marker.rangeEnd` until end-of-text or a strong terminator (double
    /// newline). A single sentence end like `.` is NOT a stop — list items
    /// commonly contain mid-sentence punctuation. We stop at `\n\n` or EOF.
    private func findRunEnd(after marker: ListMarker, in text: NSString) -> Int {
        let len = text.length
        var i = marker.rangeEnd
        while i < len - 1 {
            let c = text.character(at: i)
            let n = text.character(at: i + 1)
            if c == 0x0A && n == 0x0A { return i }
            i += 1
        }
        return len
    }

    /// Build the replacement string for a run. The slice we're replacing starts
    /// at the first marker's `rangeStart` and ends at `bodyEnd`. Within that
    /// slice we have (marker, body, marker, body, ..., marker, body). We emit
    /// "1. <body trimmed and capitalized>\n2. <body>\n...".
    private func formatListRun(_ run: [ListMarker], fullText: NSString, bodyEnd: Int) -> String {
        let useBullets = config.preferBulletsForOrdinalOnly && !run[0].hadPrefix
        var lines: [String] = []
        for (idx, marker) in run.enumerated() {
            let bodyStart = marker.rangeEnd
            let bodyStop: Int
            if idx + 1 < run.count {
                bodyStop = run[idx + 1].rangeStart
            } else {
                bodyStop = bodyEnd
            }
            guard bodyStop > bodyStart else { continue }
            let raw = fullText.substring(with: NSRange(location: bodyStart, length: bodyStop - bodyStart))
            var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a leading sentence terminator like ". " or ", " that the
            // speaker may have inserted between the marker and the body.
            while let first = body.first, ".,;:".contains(first) {
                body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Drop a trailing terminator so we don't double-punctuate. The
            // overall format pipeline will re-apply terminals where needed.
            while let last = body.last, ".,;:".contains(last) {
                body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if body.isEmpty { continue }
            // Capitalize first letter.
            let first = body.prefix(1).uppercased()
            body = first + body.dropFirst()
            if useBullets {
                lines.append("- \(body)")
            } else {
                lines.append("\(idx + 1). \(body)")
            }
        }
        // Surround with newlines so the list sits on its own block. Leading
        // newline is suppressed if the run starts at the beginning of the text.
        let joined = lines.joined(separator: "\n")
        let prefix = (run.first!.rangeStart == 0) ? "" : "\n"
        return prefix + joined
    }

    // MARK: - Dense-prose paragraph splitter
    //
    // For long dictations (≥120 words) that arrive as a single block of text
    // with no detected list structure and few transitional breaks, split into
    // ~70-word paragraphs at sentence boundaries. This prevents a 3-minute
    // dictation from pasting as one impenetrable wall of text.
    //
    // Algorithm:
    //   1. If text is < 120 words, return unchanged (short dictation).
    //   2. If text already contains paragraph breaks (\n\n), return unchanged
    //      (transitional-break pass already handled it).
    //   3. Split text into sentences on [.!?] followed by whitespace + uppercase.
    //   4. Accumulate sentences into paragraphs of ~70 words.
    //   5. Join paragraphs with \n\n.

    private func splitDenseParagraphs(_ text: String) -> String {
        // Skip short dictations — natural breaks are enough.
        let words = text.split { $0.isWhitespace }
        guard words.count >= 120 else { return text }

        // If transitional breaks already inserted paragraphs, don't re-split.
        guard !text.contains("\n\n") else { return text }

        // Split into sentences. We find boundaries: a [.!?] followed by one+
        // whitespace characters, followed by an uppercase letter. We keep the
        // terminal punctuation with its sentence (slice up to and including it).
        var sentences: [String] = []

        // Regex: terminal punct + whitespace + uppercase — the uppercase letter
        // starts the NEXT sentence. We split at the whitespace gap.
        guard let rx = try? NSRegularExpression(pattern: #"([.!?])\s+(?=[A-Z])"#) else {
            return text
        }

        let matches = rx.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var cursor = text.startIndex
        for m in matches {
            // The split point is after the punctuation mark (group 1) and its
            // following whitespace — i.e. at the start of the capital letter.
            // m.range(at: 1) is the punctuation char; split after it + whitespace.
            let punctEnd = Range(m.range(at: 1), in: text)!.upperBound
            // Skip whitespace to find where the next sentence starts.
            var nextSentStart = punctEnd
            while nextSentStart < text.endIndex && text[nextSentStart].isWhitespace {
                nextSentStart = text.index(after: nextSentStart)
            }
            let sentenceSlice = String(text[cursor..<punctEnd])
            if !sentenceSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(sentenceSlice)
            }
            cursor = nextSentStart
        }
        // Remainder after the last match.
        let tail = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }

        // If we ended up with 0 or 1 sentences (no sentence boundaries found),
        // nothing to split.
        guard sentences.count > 1 else { return text }

        // Group sentences into ~70-word paragraphs.
        let targetWords = 70
        var paragraphs: [String] = []
        var currentSentences: [String] = []
        var currentWordCount = 0

        for sentence in sentences {
            let sentWordCount = sentence.split { $0.isWhitespace }.count
            currentSentences.append(sentence)
            currentWordCount += sentWordCount
            if currentWordCount >= targetWords {
                paragraphs.append(currentSentences.joined(separator: " "))
                currentSentences = []
                currentWordCount = 0
            }
        }
        // Flush remaining sentences into final paragraph.
        if !currentSentences.isEmpty {
            paragraphs.append(currentSentences.joined(separator: " "))
        }

        // Only insert breaks if we produced at least 2 paragraphs.
        guard paragraphs.count >= 2 else { return text }

        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Salutation detection
    //
    // If text starts with "Dear <Name>" or "Hi <Name>" (email/letter opener),
    // insert a comma after the name and a paragraph break before the body.
    //
    // Examples:
    //   "Dear John I hope you're doing well" → "Dear John,\n\nI hope you're doing well."
    //   "Hi Sarah just wanted to check in"  → "Hi Sarah,\n\nJust wanted to check in."
    //
    // Conservative:
    //   - Only fires at the very start of the text (after leading-filler strip).
    //   - "Dear" or "Hi" must be the first word (case-insensitive).
    //   - The name must be 1–3 capitalized tokens (handles "Dear Dr Smith").
    //   - Requires at least a few words of body text after the salutation.
    //   - Does NOT fire on "Hi there" / "Hi everyone" (lowercase next-word → no name).

    private static let salutationStarters: Set<String> = ["dear", "hi", "hello", "hey"]

    private func formatSalutation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return text }

        // First token must be a salutation word.
        let first = tokens[0].lowercased()
        guard Self.salutationStarters.contains(first) else { return text }

        // Collect name tokens: 1-3 consecutive tokens that start with uppercase.
        // The name starts at tokens[1].
        var nameTokenCount = 0
        var i = 1
        while i < tokens.count && nameTokenCount < 3 {
            let t = tokens[i]
            // Name token: starts with uppercase letter, contains only letters/hyphens/periods
            let stripped = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            guard let fc = stripped.first, fc.isUppercase,
                  stripped.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "." }) else {
                break
            }
            nameTokenCount += 1
            i += 1
        }

        // Need at least 1 name token and at least 1 body token after the name.
        guard nameTokenCount >= 1 else { return text }
        let bodyStart = 1 + nameTokenCount
        guard bodyStart < tokens.count else { return text }

        // Build the salutation line and body.
        let salutation = tokens[0..<bodyStart].joined(separator: " ")
        var body = tokens[bodyStart...].joined(separator: " ")
        // Capitalize first word of body.
        if let firstBodyChar = body.first, firstBodyChar.isLowercase {
            body = firstBodyChar.uppercased() + body.dropFirst()
        }

        // Check if the name already ends with a comma (speaker said "Hi John,").
        let lastNameToken = tokens[bodyStart - 1]
        let nameHasComma = lastNameToken.hasSuffix(",")

        let salutationFormatted = nameHasComma ? salutation : "\(salutation),"
        return "\(salutationFormatted)\n\n\(body)"
    }

    // MARK: - Transitional paragraph breaks
    //
    // After a `.` if the next sentence starts with a known transitional phrase
    // ("So,", "Anyway", "Moving on", "Now,"), insert a paragraph break (`\n\n`).
    // Segment-gap-based breaks are handled separately in `formatSegments`.
    private static let transitionalStarters: [String] = [
        "anyway", "anyways",
        "moving on",
        "so,", "now,",
        "by the way",
        "on another note",
        "in conclusion",
        "to summarize",
        "to sum up",
        "to recap",
        "meanwhile",
        "on a different note",
        "switching topics",
        "next up",
        "speaking of which",
        "that being said",
        "with that said",
        "on that note",
        "in other news",
        "to be clear",
        "going back to",
    ]

    /// Insert `\n\n` between a sentence-ending `.!?` and a following
    /// transitional starter phrase. Conservative — only matches phrases listed
    /// in `transitionalStarters` exactly, case-insensitive.
    private func insertTransitionalParagraphBreaks(_ text: String) -> String {
        var result = text
        for starter in Self.transitionalStarters {
            // Match: terminal punct, whitespace, then the starter phrase. We
            // replace the run of whitespace between with `\n\n`.
            let escaped = NSRegularExpression.escapedPattern(for: starter)
            // Note the starter may itself contain a trailing comma like "so,".
            // We tag a `\b` after the *first character* of the starter to make
            // sure we're at a word boundary, not in the middle of a word.
            let pattern = "([.!?\u{2026}])[ \\t]+(?i:\(escaped))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let terminal = ns.substring(with: m.range(at: 1))
                // Recompute the literal starter substring as-it-appears so we
                // preserve user casing.
                let starterRange = NSRange(
                    location: m.range.location + m.range(at: 1).length,
                    length: m.range.length - m.range(at: 1).length
                )
                // Slice off the whitespace between terminal and starter.
                let starterText = ns.substring(with: starterRange).trimmingCharacters(in: .whitespaces)
                let replacement = "\(terminal)\n\n\(starterText)"
                result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Parakeet-quirk normalization

    /// BUGFIX (Yo/Yeah specific): Heuristic normalizations for common Parakeet
    /// mistranscriptions. Runs after raw ASR but before formatRules / Qwen3.
    /// Conservative — only applies in unambiguous cases where the input token
    /// is not a real English word in any common usage.
    ///
    /// Currently handles:
    ///   - "yoat" / "yote" / "yoda" → "yo" (Parakeet's stuttering "y-yo" collapse)
    ///   - "houst" → "host" (rare Parakeet glitch on "host"/"hoist")
    ///   - "areyou" → "are you" (also caught elsewhere but cheap to dedup here)
    static func normalizeParakeetQuirks(_ text: String) -> String {
        var out = text
        // Case-insensitive replacements at word boundaries. We preserve casing
        // by checking what the original token looked like — if it was capitalized,
        // we keep the replacement capitalized too. Cheaper to just two-pass.
        let pairs: [(String, String)] = [
            (#"\byoat\b"#, "yo"),
            (#"\bYoat\b"#, "Yo"),
            (#"\byote\b"#, "yo"),
            (#"\bYote\b"#, "Yo"),
            (#"\byoda\b"#, "yo"),
            (#"\bYoda\b"#, "Yo"),
            (#"\bhoust\b"#, "host"),
            (#"\bHoust\b"#, "Host"),
        ]
        for (pat, rep) in pairs {
            out = out.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }

        // BUGFIX (uhs / R's): Parakeet sometimes hears the plural filler "uhs"
        // as the letter "R" with a possessive ("R's" / "R.'s"). Restore.
        //
        // Caveat: this WILL clobber a legitimate "R's" (e.g. "the R's were
        // misspelled"). Accepted trade-off: the true-positive rate on "uhs"
        // mishears is meaningfully higher than the false-positive rate on
        // legit single-letter possessives in dictation. If a future user hits
        // the legit case often, lift this into a config flag.
        out = out.replacingOccurrences(
            of: #"\bR's\b"#,
            with: "uhs",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\bR\.?'s\b"#,
            with: "uhs",
            options: .regularExpression
        )
        // BUGFIX (uhs / R's): explicit phrase form. The two patterns above
        // already cover this in isolation, but listing the bigram makes the
        // intent obvious to future maintainers and lets us tighten the word
        // boundaries if the standalone passes ever become too aggressive.
        out = out.replacingOccurrences(
            of: #"\bums and R's\b"#,
            with: "ums and uhs",
            options: .regularExpression
        )

        // BUGFIX (handles): keep known usernames intact downstream. No
        // transform here — this list exists so other helpers (e.g.
        // suspectsForPolish) can surface them to the LLM as "do not change".
        _ = Self.knownHandles

        return out
    }

    /// Letter+digit identifiers that look like usernames but aren't dictionary
    /// words. Surfaced to the polish LLM as protected tokens so it won't
    /// "correct" "fortun8te" → "fortunate". Generic handle-shaped tokens
    /// (e.g. "gr8", "m8") are also detected on the fly via
    /// `containsHandleShape(_:)`.
    static let knownHandles: [String] = [
        "fortun8te",  // user's common username
    ]

    /// Regex matching letter+digit+letter or letter+digit identifiers that
    /// look like screen names (`fortun8te`, `gr8`, `m8`, `ChatGPT3`). Used by
    /// `suspectsForPolish` to surface these as protected tokens.
    private static let rxHandleShape = try! NSRegularExpression(
        pattern: #"\b(?:[A-Za-z]+\d+[A-Za-z]*|[A-Za-z]*\d+[A-Za-z]+)\b"#
    )

    /// True if `text` contains at least one handle-shaped token (letter-digit
    /// mix), e.g. "fortun8te", "gr8", "4ever", "ChatGPT3".
    static func containsHandleShape(_ text: String) -> Bool {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return rxHandleShape.firstMatch(in: text, range: range) != nil
    }

    /// Return all handle-shaped tokens in `text` (preserves original casing).
    static func extractHandleShapes(_ text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = rxHandleShape.matches(in: text, range: range)
        return matches.map { ns.substring(with: $0.range) }
    }

    // MARK: - Leading-filler strip

    /// Strip leading filler tokens at the very start of the utterance only:
    /// "Uh, so what I want to say..." → "So what I want to say...". Removing
    /// fillers in the body is `removeFillerWords`'s job.
    private func stripLeadingFiller(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading: [String] = [
            "uh,", "um,", "uhh,", "umm,",
            "like,", "you know,", "i mean,",
            "uh ", "um ", "uhh ", "umm ",
            "so um,", "so uh,", "so like,",
        ]
        var changed = true
        var iterations = 0
        while changed && iterations < 4 {
            changed = false
            iterations += 1
            for token in leading {
                if s.lowercased().hasPrefix(token) {
                    s = String(s.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        return s
    }

    // MARK: - Terminal punctuation

    /// If the trimmed text doesn't end with terminal punctuation, append a period.
    /// Skips list bullets, closing parens/quotes, and existing terminal marks.
    private func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }
        let terminals: Set<Character> = [".", "!", "?", ":", ";", "\u{2026}"]
        if terminals.contains(last) { return text }
        if last == "-" || last == ")" || last == "\"" || last == "\u{201D}" {
            return text
        }
        if let trimmedRange = text.range(of: trimmed) {
            return text.replacingCharacters(in: trimmedRange, with: trimmed + ".")
        }
        return trimmed + "."
    }

    // MARK: - Time-of-day normalizer (digit forms)
    //
    // Word-form times ("five thirty PM") are handled by
    // `normalizeSpokenTimesPrePass` BEFORE number folding. This pass cleans
    // up DIGIT forms that survive the folder: "5pm", "5 30 pm", "5:30 pm",
    // "5 thirty pm", "5 fifteen pm", "5 forty five pm".
    //
    // Output convention: hours stay as integers; minutes get a colon and are
    // two-digit; suffix is uppercase AM / PM with a space between number and
    // suffix when no minutes, and no space when minutes are present (matches
    // common typography: "5 PM" but "5:30 PM").
    //
    // Bare hours without am/pm (e.g. "at 5") are intentionally left alone.

    /// Single shared regex set, compiled once.
    private static let rxTimeDigitWithSuffix = try! NSRegularExpression(
        // 1=hour, 2=optional colon-or-space minutes, 3=am/pm
        pattern: #"(?i)\b(\d{1,2})(?:\s*[:\s]\s*(\d{2}))?\s*(a\.?\s*m\.?|p\.?\s*m\.?)\b"#
    )
    private static let rxTimeDigitWord = try! NSRegularExpression(
        // 1=hour, 2=minute-word (thirty / fifteen / forty.?five / forty-five), 3=am/pm
        pattern: #"(?i)\b(\d{1,2})\s+(thirty|fifteen|forty[\s\-]?five|forty)\s+(a\.?\s*m\.?|p\.?\s*m\.?)\b"#
    )

    /// Normalize digit-form times of day in the post-fold text.
    ///
    /// Examples:
    ///   "5pm"           → "5 PM"
    ///   "5 pm"          → "5 PM"
    ///   "5 30 pm"       → "5:30 PM"
    ///   "5:30 pm"       → "5:30 PM"
    ///   "5 thirty pm"   → "5:30 PM"
    ///   "5 fifteen am"  → "5:15 AM"
    ///   "5 forty five pm" → "5:45 PM"
    ///   "at 730"        → "at 7:30"  (digit-string form near time preposition)
    ///   "by 1130"       → "by 11:30"
    ///   "at 5"          → "at 5"      (no suffix → unchanged)
    private func normalizeTimesOfDay(_ text: String) -> String {
        var result = text

        // Pass 0: digit-string form near a time preposition. "730" / "1130"
        // dictated as a single number after "at"/"around"/"by"/"about"/"by
        // around" should become 7:30 / 11:30. Only fires in a clear time
        // context to avoid mangling random 3-4 digit numbers (zip codes,
        // amounts, etc.). Run BEFORE the digit+suffix pass so "at 730 pm"
        // becomes "at 7:30 pm" → eventually "7:30 PM".
        let timeContextPrefix = #"(?i)(\b(?:at|around|by|about|near|past|after|before|until|till|approximately|roughly)\s+)"#
        // Hour 1-9 + minutes 00-59 (3 digits): "730", "915", "1030 ambiguous".
        // Use 3-digit then 4-digit; the 4-digit form covers 10xx-12xx.
        let threeDigit = timeContextPrefix + #"([1-9])([0-5]\d)\b(?!\s*(?:am|pm|a\.m|p\.m|st|nd|rd|th|%|dollars|bucks|kg|lb|mph|ml|°|degrees))"#
        let fourDigit  = timeContextPrefix + #"(1[0-2])([0-5]\d)\b(?!\s*(?:am|pm|a\.m|p\.m|st|nd|rd|th|%|dollars|bucks|kg|lb|mph|ml|°|degrees))"#
        for pattern in [fourDigit, threeDigit] {
            if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = result as NSString
                let matches = rx.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches.reversed() {
                    guard m.numberOfRanges >= 4 else { continue }
                    let cur = result as NSString
                    let prep = cur.substring(with: m.range(at: 1))
                    let hour = cur.substring(with: m.range(at: 2))
                    let min  = cur.substring(with: m.range(at: 3))
                    let replacement = "\(prep)\(hour):\(min)"
                    result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
                }
            }
        }

        // Pass 1: digit + minute-WORD + am/pm. Run first because the
        // surface "5 thirty pm" otherwise matches pass 2's "5 ... pm" too.
        let ns1 = result as NSString
        let m1 = Self.rxTimeDigitWord.matches(
            in: result,
            range: NSRange(location: 0, length: ns1.length)
        )
        for m in m1.reversed() {
            let nsCur = result as NSString
            let hour = nsCur.substring(with: m.range(at: 1))
            let minWord = nsCur.substring(with: m.range(at: 2))
                .lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let mm: String
            switch minWord {
            case "thirty":               mm = "30"
            case "fifteen":              mm = "15"
            case "forty":                mm = "40"
            case "forty five",
                 "fortyfive":            mm = "45"
            default:                     continue
            }
            let suffixRaw = nsCur.substring(with: m.range(at: 3))
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "")
            let suffix = (suffixRaw == "am") ? "AM" : "PM"
            let formatted = "\(hour):\(mm) \(suffix)"
            result = (result as NSString).replacingCharacters(in: m.range, with: formatted)
        }

        // Pass 2: digit (+ optional digit minutes) + am/pm.
        let ns2 = result as NSString
        let m2 = Self.rxTimeDigitWithSuffix.matches(
            in: result,
            range: NSRange(location: 0, length: ns2.length)
        )
        for m in m2.reversed() {
            let nsCur = result as NSString
            let hour = nsCur.substring(with: m.range(at: 1))
            let suffixRaw = nsCur.substring(with: m.range(at: 3))
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "")
            let suffix = (suffixRaw == "am") ? "AM" : "PM"

            let formatted: String
            if m.range(at: 2).location != NSNotFound {
                let mm = nsCur.substring(with: m.range(at: 2))
                formatted = "\(hour):\(mm) \(suffix)"
            } else {
                // Bare hour + suffix → "5 PM" (uppercase + single space).
                formatted = "\(hour) \(suffix)"
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: formatted)
        }

        return result
    }

    // MARK: - Known product / brand-name normalizer
    //
    // Canonicalize spelling of products / brands that ASR routinely mangles
    // (Wispr Flow, Parakeet, Moonshine, etc.). Runs EARLY in the pipeline so
    // every downstream pass sees the canonical form. Distinct from
    // `collapseBrandNames` which targets the long-tail of run-together brand
    // words ("chat gpt", "you tube"); the entries here are specifically the
    // ASR mis-hearings we've observed in the wild.
    //
    // Case-insensitive matching, word-bounded; output is the canonical
    // capitalization from the right-hand side of each tuple.
    private let productNameMap: [(String, String)] = [
        // Wispr Flow variants — ASR commonly produces "whisper flow",
        // "whisprflu", "whisper flu", "whisperflu" because of the breathy
        // "wh-" onset and the unfamiliar brand spelling.
        ("wispr flow",   "Wispr Flow"),
        ("whispr flow",  "Wispr Flow"),
        ("whisper flow", "Wispr Flow"),
        ("whisprflu",    "Wispr Flow"),
        ("whisper flu",  "Wispr Flow"),
        ("whisperflu",   "Wispr Flow"),

        // ASR model names.
        ("para keet",    "Parakeet"),
        ("parakeet",     "Parakeet"),
        ("moon shine",   "Moonshine"),
        ("moonshine",    "Moonshine"),

        // IBM Granite — almost always lowercased by ASR even when referring
        // to the LLM. The word is also common as a noun ("granite countertop")
        // so we keep the case-insensitive match but accept the occasional
        // over-capitalization; users dictating about rocks rarely capitalize
        // anyway.
        ("granite",      "Granite"),

        // This app itself.
        ("voice app",    "VOICE app"),

        // BUGFIX (Bug 5): canonical brand/product names that need to land
        // BEFORE URL protection runs, so YouTube / Gmail in bare domains
        // ("youtube.com", "gmail.com") survive intact and so downstream
        // capitalization can't mangle them. `collapseBrandNames` also covers
        // most of these later, but doing them here too means the right form
        // is in place EARLY, before number/time/URL passes run.
        ("wispr",        "Wispr"),
        ("chat gpt",     "ChatGPT"),
        ("chatgpt",      "ChatGPT"),
        ("open ai",      "OpenAI"),
        ("openai",       "OpenAI"),
        ("anthropic",    "Anthropic"),
        ("github",       "GitHub"),
        ("git hub",      "GitHub"),
        ("mac os",       "macOS"),
        ("macos",        "macOS"),
        ("i os",         "iOS"),
        ("ios",          "iOS"),
        ("vs code",      "VS Code"),
        ("vscode",       "VS Code"),
        ("youtube",      "YouTube"),
        ("you tube",     "YouTube"),
        ("gmail",        "Gmail"),
        ("g mail",       "Gmail"),
        ("claude",       "Claude"),
    ]

    /// Replace known product / brand names with their canonical spelling.
    /// Case-insensitive, word-bounded. Called early in `format(_:)` (right
    /// after `normalizeParakeetQuirks`) so every downstream pass sees the
    /// canonical form.
    ///
    /// TRADE-OFF: this is always-replace. If a user dictates the lowercase form
    /// intentionally (e.g. the band "Wispr" rather than the app "Wispr Flow"),
    /// the canonical capitalization wins. We accept this because the dictation
    /// app's audience overwhelmingly references the products, not the
    /// homophones. If/when this becomes a real complaint, switch to a context
    /// heuristic (look for "the band", "song", surrounding verbs of music
    /// listening) before replacing.
    private func normalizeKnownProductNames(_ text: String) -> String {
        var result = text
        for (spoken, written) in productNameMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: written
                )
            }
        }
        return result
    }

    // MARK: - Signal-rich structural hints (for Qwen3 polish stage)
    //
    // The following passes prep complex dictation by injecting structural
    // markers (bullets, backticks, paragraph breaks, quoted spans) BEFORE
    // the polish LLM sees the text. The polish stage is instructed to
    // preserve these markers, so list-style enumerations come out as actual
    // bulleted lists, snake_case identifiers come out as inline-code, etc.
    //
    // Each pass is conservative — only triggers on unambiguous patterns so
    // we don't accidentally backtick prose or break paragraphs mid-clause.

    /// Normalize money + unit phrases so digits land next to their unit.
    /// Examples:
    ///   "150 bucks"          → "$150"
    ///   "50 millimeter"      → "50mm"
    ///   "2.5 percent"        → "2.5%"
    /// Runs AFTER `normalizeTimesOfDay` so "5:30 percent" doesn't show up;
    /// runs BEFORE `extractQuotedMessage` so units inside a dictated message
    /// body still get folded.
    private func normalizeMoneyAndUnits(_ text: String) -> String {
        var t = text
        // "X bucks" / "X dollars" → "$X"
        t = t.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?)\s+(bucks|dollars)\b"#,
            with: "$$$1",
            options: [.regularExpression, .caseInsensitive]
        )
        // "X millimeter" / "X millimeters" / "X mm" → "Xmm"
        t = t.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?)\s+(millimeters?|mm)\b"#,
            with: "$1mm",
            options: [.regularExpression, .caseInsensitive]
        )
        // "X percent" → "X%"
        t = t.replacingOccurrences(
            of: #"\b(\d+(?:\.\d+)?)\s+percent\b"#,
            with: "$1%",
            options: [.regularExpression, .caseInsensitive]
        )
        return t
    }

    /// Detect "tell/send/text/email X saying/that ..." patterns and convert
    /// the quoted body into actual quotes on its own paragraph. This makes
    /// the polish stage see a clear "this is the message body" boundary.
    /// Runs BEFORE URL protection so URLs inside the body still get
    /// extracted later in the pipeline.
    private func extractQuotedMessage(_ text: String) -> String {
        var t = text
        // BUGFIX: original lookahead `(?=$|\.\s+[A-Z])` missed messages ending in
        // `!` or `?`. With the old pattern, "tell John saying are you free? She
        // replied yes." would greedily consume the entire input as the message
        // body. Expanded to include `!?\u{2026}` terminators.
        // Raw string `#"..."#` does NOT process `\u{...}` — use literal char.
        let pattern = #"(?i)\b(send|tell|text|email|message|dm)\s+([A-Z][a-z]+|him|her|them)\s+(?:a\s+message\s+)?(?:saying|that\s+says?|telling\s+them)\s+(.+?)(?=$|[.!?…]\s+[A-Z]|\n)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return t }
        let ns = t as NSString
        let matches = re.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            guard m.numberOfRanges >= 4 else { continue }
            let verb    = ns.substring(with: m.range(at: 1))
            let target  = ns.substring(with: m.range(at: 2))
            var body    = ns.substring(with: m.range(at: 3))
            body = body.trimmingCharacters(in: .whitespaces)
            if !body.isEmpty {
                // Capitalize first letter of body
                body = body.prefix(1).uppercased() + body.dropFirst()
                // Ensure terminal punctuation
                if let last = body.last, !".!?\"'".contains(last) {
                    body += "."
                }
                let replacement = "\(verb.capitalized) \(target) this message:\n\n\"\(body)\""
                t = (t as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        return t
    }

    /// If the speaker enumerates a list of 3+ short identifier-like words,
    /// wrap each candidate in backticks so the polish stage emits inline-code.
    /// Heuristic: a "field list" is a comma-separated run of 3+ tokens, each
    /// 1-3 words, each token alphanumeric+hyphen/underscore, after a trigger
    /// phrase like "with", "fields are", "columns", "table with", "containing".
    ///
    /// TODO: the bare "with" trigger over-fires on prose ("a meeting with John,
    /// Sara, and Bob" → would not match because of the capitalized-name guard,
    /// but "a smoothie with banana, apple, and yogurt" WOULD match and get
    /// backticked). Consider gating "with" behind a stronger schema-like
    /// signal (presence of snake_case / camelCase tokens, "table", "schema",
    /// "object" earlier in the same sentence).
    private func detectAndMarkFieldLists(_ text: String) -> String {
        var t = text
        let triggers = [
            "with",
            "table with",
            "fields are",
            "the fields are",
            "columns are",
            "containing",
            "has",
            "includes",
            "consisting of",
        ]

        // Pattern: <trigger> <token>(,| and)( <token>){2,}
        // For each match, backtick-quote the tokens.
        for trigger in triggers {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b\\s+((?:[a-z][a-z0-9_]*(?:\\s+[a-z][a-z0-9_]*)?\\s*[,]\\s*){2,}(?:[a-z][a-z0-9_]*(?:\\s+[a-z][a-z0-9_]*)?))"
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = t as NSString
            let matches = re.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let triggerRange = NSRange(location: m.range.location, length: trigger.count)
                let listRange = m.range(at: 1)
                guard listRange.location != NSNotFound else { continue }

                let triggerText = ns.substring(with: triggerRange)
                let listText = ns.substring(with: listRange)

                // Tokenize on commas and "and"
                let tokens = listText
                    .components(separatedBy: CharacterSet(charactersIn: ","))
                    .flatMap { $0.components(separatedBy: " and ") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                // Convert spoken "guest id" → "guest_id"
                let snake = tokens.map { token -> String in
                    let parts = token.split(separator: " ").map(String.init)
                    return parts.joined(separator: "_").lowercased()
                }

                // Build replacement: trigger + \n- `t1`\n- `t2`\n- `t3` etc.
                let bulletList = snake.map { "- `\($0)`" }.joined(separator: "\n")
                let replacement = "\(triggerText):\n\(bulletList)"

                t = (t as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        return t
    }

    /// Wrap obviously-code tokens in backticks so the polish stage preserves them
    /// as inline code. Skip tokens already inside backticks or inside URL placeholders.
    private func backtickCodeTokens(_ text: String) -> String {
        var t = text
        // snake_case: 2+ words joined by underscore
        t = t.replacingOccurrences(
            of: #"(?<![\w`])([a-z]+_[a-z0-9_]+)(?![\w`])"#,
            with: "`$1`",
            options: .regularExpression
        )
        // CLI flags
        t = t.replacingOccurrences(
            of: #"(?<![\w`])(--[a-z][a-z0-9-]+)(?![\w`])"#,
            with: "`$1`",
            options: .regularExpression
        )
        // Semantic version
        t = t.replacingOccurrences(
            of: #"(?<![\w`])(v?\d+\.\d+\.\d+(?:-[a-z0-9]+)?)(?![\w`])"#,
            with: "`$1`",
            options: .regularExpression
        )
        return t
    }

    /// Insert paragraph breaks at strong topic-shift signals. These markers are
    /// almost always topic transitions in casual dictation. Runs AFTER terminal
    /// punctuation has been inferred so we have the `.!?` boundary to match on.
    ///
    /// The leading `([.!?])\s+` guard ensures we only fire AFTER a sentence has
    /// ended — mid-sentence uses like "I also like coffee" don't trigger because
    /// "also" isn't preceded by terminal punctuation.
    private func insertTopicShiftBreaks(_ text: String) -> String {
        var t = text
        let shifts = [
            "also ", "oh and ", "wait also ", "and also ",
            "another thing ", "one more thing ", "also also ",
        ]
        for shift in shifts {
            // After a sentence-ending period/!/?/ellipsis, if the shift word starts
            // a new clause, insert a paragraph break.
            // BUGFIX: include `\u{2026}` (ellipsis) in the terminal-punct class so
            // sentences ending with "…" also trigger topic shifts.
            let pattern = "([.!?\u{2026}])\\s+(?i)\(NSRegularExpression.escapedPattern(for: shift))"
            t = t.replacingOccurrences(
                of: pattern,
                with: "$1\n\n" + shift.prefix(1).uppercased() + shift.dropFirst(),
                options: .regularExpression
            )
        }
        return t
    }

    // MARK: - URL / email protection
    //
    // The cleanup pipeline (cleanupPunctuation → capitalizeSentences →
    // cleanWhitespace) treats every `.` as a potential sentence boundary.
    // That's correct for prose, but catastrophic for emails / URLs:
    //
    //   "michael@gmail.com"  →  "michael@gmail. Com"
    //   "youtube.com/foo"    →  "youtube. Com/foo"
    //
    // Strategy: BEFORE those passes, swap every URL / email / bare-domain
    // match for a placeholder built from private-use unicode codepoints
    // (U+E000 … U+E001 sandwich, guaranteed not to collide with any input
    // character). After the cleanup passes run, restore from the map.

    /// Compiled once.
    private static let rxURLEmail: NSRegularExpression = {
        // Order matters within the alternation: longest / most specific first.
        // 1. Email (must match before bare-domain so the `@` is preserved)
        // 2. https?:// scheme URL
        // 3. Bare domain with known TLD, optionally followed by /path
        let tldList = [
            "com","net","org","io","app","co","ai","dev","me","us",
            "uk","tv","nl","de","fr","gov","edu","info","tech","xyz",
            "so","sh","to","gl","ly",
        ]
        let tld = tldList.joined(separator: "|")
        let email   = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        let scheme  = #"https?://\S+"#
        let bare    = "\\b[A-Za-z0-9\\-]+\\.(?:\(tld))(?:/\\S*)?\\b"
        let pattern = "(?:\(email))|(?:\(scheme))|(?:\(bare))"
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Sentinel codepoints in the Unicode Private Use Area (U+E000 … U+F8FF).
    /// Specifically U+E000 (start of BMP PUA) and U+E001. Never appear in
    /// natural text or any prior pass's output, so the placeholders survive
    /// every regex / replace / NSString round-trip cleanly.
    ///
    /// COLLISION RISK: dictation never produces PUA characters (no keyboard
    /// emits them, ASR models don't produce them). If raw paste-augmented input
    /// ever contains PUA chars, swap to a sentinel scheme that's verifiably
    /// out-of-range (e.g. high-plane PUA U+F0000+) or escape any U+E000/U+E001
    /// chars in input BEFORE this pass.
    private static let urlPlaceholderOpen  = "\u{E000}URL"
    private static let urlPlaceholderClose = "\u{E001}"

    /// Replace every URL / email / bare-domain match with an opaque
    /// placeholder; return the rewritten text plus the map used to restore.
    private func protectURLsAndEmails(_ text: String) -> (String, [String: String]) {
        let ns = text as NSString
        let matches = Self.rxURLEmail.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return (text, [:]) }

        var map: [String: String] = [:]
        var result = text
        // Process in reverse so earlier ranges stay valid as we splice in
        // shorter placeholders.
        for (i, m) in matches.enumerated().reversed() {
            let original = (result as NSString).substring(with: m.range)
            let key = "\(Self.urlPlaceholderOpen)\(i)\(Self.urlPlaceholderClose)"
            map[key] = original
            result = (result as NSString).replacingCharacters(in: m.range, with: key)
        }
        return (result, map)
    }

    /// Inverse of `protectURLsAndEmails`. Swaps each placeholder back to its
    /// original text. Safe to call with an empty map.
    private func restoreURLsAndEmails(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var result = text
        for (key, original) in map {
            result = result.replacingOccurrences(of: key, with: original)
        }
        return result
    }

    // MARK: - Helpers

    /// Rough estimate of speech duration for `formatWithParagraphs`.
    /// 2.5 wps is the average conversational rate.
    private func estimateDuration(_ text: String) -> TimeInterval {
        let wordCount = text.split(separator: " ").count
        let wordsPerSecond = 2.5
        return TimeInterval(wordCount) / wordsPerSecond
    }
}

// MARK: - DEBUG self-check

#if DEBUG
extension TextFormatter {
    /// Hand-curated test cases covering each transformation. Not run automatically;
    /// invoke from a debug menu / breakpoint to spot regressions.
    /// Prints "PASS" / "FAIL: input | got | expected" lines.
    func _debugRunSelfTests() {
        let f = TextFormatter()
        let cases: [(String, String, String)] = [
            // (label, input, expected)
            ("leading filler",      "Uh, so I went to the store",                "So I went to the store."),
            ("standalone i",        "i went home and i slept",                   "I went home and I slept."),
            ("contraction dont",    "i dont know what to do",                    "I don't know what to do."),
            ("contraction youre",   "youre going to love this",                  "You're going to love this."),
            ("number compound",     "I have twenty three apples",                "I have 23 apples."),
            ("ordinal compound",    "the twenty third of march",                 "The 23rd of March."),  // note: month not auto-cap'd; close enough
            ("currency",            "it costs five dollars exactly",             "It costs $5 exactly."),
            ("email reconstruction","email me at john at gmail dot com please",  "Email me at john@gmail.com please."),
            ("www reconstruction",  "go to double you double you double you dot example dot com",
                                    "Go to www.example.com."),
            ("em dash strip",       "I went there \u{2014} it was great",        "I went there - it was great."),
            ("smart quotes",        "she said \"hello\" and left",               "She said \u{201C}hello\u{201D} and left."),
            ("dedupe punctuation",  "wait,, what??",                             "Wait, what?"),
            ("trailing period",     "hello world",                               "Hello world."),
            ("voice command period","hello world period",                        "Hello world."),
            ("voice command newpara","first thought new paragraph second thought",
                                    "First thought\n\nSecond thought."),
            ("self-correct scratch",   "I'll be there at five scratch that six pm",   "I'll be there at 6pm."),
            ("self-correct actually",  "send it Monday actually no wait send it Friday", "Send it Friday."),
            ("self-correct I mean",    "the red one I mean the blue one",              "The blue one."),
            ("self-correct start over","hey there start over hi how are you",          "Hi how are you?"),
            ("question mark are",    "are you free tomorrow",         "Are you free tomorrow?"),
            ("question mark how",    "how do I get there",            "How do I get there?"),
            ("question mark plain",  "I wonder if you're free",       "I wonder if you're free."),
            ("acronym FBI",          "the F B I called me",           "The FBI called me."),
            ("acronym CEO",          "she is the C E O now",          "She is the CEO now."),

            // --- Spoken list detection ---
            ("list point N",
             "point one this is a test point two another point point three last one",
             "1. This is a test\n2. Another point\n3. Last one."),
            ("list ordinal-only",
             "first I went to the store second I bought milk third I came home",
             "1. I went to the store\n2. I bought milk\n3. I came home."),
            ("list step N",
             "step one open the file step two save it",
             "1. Open the file\n2. Save it."),
            ("list no false-positive single trigger",
             "I want to point one out that this is wrong",
             "I want to point one out that this is wrong."),
            ("list no false-positive prose number",
             "she is my number one fan",
             "She is my number one fan."),

            // --- Transitional paragraph breaks ---
            ("paragraph break So",
             "I went to the store. So, I bought milk.",
             "I went to the store.\n\nSo, I bought milk."),
            ("paragraph break Anyway",
             "that was strange. Anyway, here's the news.",
             "That was strange.\n\nAnyway, here's the news."),

            // --- Tag question detection ---
            ("tag question right",   "That's the plan, right.",    "That's the plan, right?"),
            ("tag question correct",  "We ship Friday, correct.",   "We ship Friday, correct?"),
            ("short question really", "Really.",                    "Really?"),
            ("short question why not","Why not.",                   "Why not?"),

            // --- Salutation detection ---
            ("salutation Dear",
             "Dear John I hope this finds you well",
             "Dear John,\n\nI hope this finds you well."),
            ("salutation Hi",
             "Hi Sarah just wanted to check in about the meeting",
             "Hi Sarah,\n\nJust wanted to check in about the meeting."),
        ]
        for (label, input, expected) in cases {
            let got = f.format(input)
            // Allow some slack — exact match preferred but report both either way.
            let ok = (got == expected)
            print(ok ? "[FMT-TEST] PASS: \(label)" : "[FMT-TEST] FAIL: \(label)\n  in:  \(input)\n  got: \(got)\n  exp: \(expected)")
        }
        // Em-dash invariant: format output must NEVER contain U+2014 or U+2013.
        let dashSample = f.format("a — b – c —— d")
        assert(!dashSample.contains("\u{2014}") && !dashSample.contains("\u{2013}"),
               "Em-dash escaped formatter: \(dashSample)")
    }
}
#endif
