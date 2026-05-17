// IntentClassifier.swift
//
// Scaffolding for a 2-pass goal-first polish:
//   1. Split a raw dictation into topic chunks (TopicSplitter).
//   2. Classify each chunk's Intent (kind, register, recipient, topics, etc.)
//      via IntentClassifier.
//
// This file ships the PLUMBING only. The classifier itself is a deterministic
// regex-based heuristic for now — the real 1.7B LLM-backed classifier will
// replace `classifyHeuristically(_:)` once we have a real test script.
//
// Wired into Qwen3Polisher behind the `useGoalFirstPolish` UserDefaults flag.
// When the flag is OFF (default) nothing changes. When ON, the polisher emits
// `[VOICE-INTENT] chunk N: kind=X register=Y recipient=Z` log lines and then
// routes through the existing polish path unchanged.

import Foundation

// MARK: - Intent / Register

public struct Intent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case message        // "message Daniel hey..."
        case email          // longer form, more formal
        case schema         // "make invoices table..."
        case code           // function/class dictation
        case todoList       // multi-topic action items
        case note           // freeform journal/thought
        case searchQuery    // "find me articles about..."
        case instruction    // imperative without target ("book the earliest...")
        case prose          // default / fallback
    }

    public var kind: Kind
    public var register: Register
    public var recipient: String?       // "Daniel" if message/email
    public var topics: [String]         // for multi-topic; otherwise [single topic]
    public var uncertainWords: [String]
    public var confidence: Double       // 0-1, classifier self-confidence

    public init(
        kind: Kind,
        register: Register,
        recipient: String? = nil,
        topics: [String] = [],
        uncertainWords: [String] = [],
        confidence: Double = 0.0
    ) {
        self.kind = kind
        self.register = register
        self.recipient = recipient
        self.topics = topics
        self.uncertainWords = uncertainWords
        self.confidence = confidence
    }
}

public enum Register: String, Codable, Sendable {
    case casual, neutral, formal
}

// MARK: - TopicChunk / TopicSplitter

public struct TopicChunk: Sendable {
    public var text: String
    public var leadConnector: String?   // "also", "and then", "oh and"

    public init(text: String, leadConnector: String? = nil) {
        self.text = text
        self.leadConnector = leadConnector
    }
}

/// Breaks a multi-topic dictation into per-topic chunks before classification.
///
/// Splits on sentence-end boundaries followed by topic-shift markers. Each
/// chunk keeps its leading connector word(s) for context.
public enum TopicSplitter {

    /// Topic-shift markers in priority order. Longer / more specific phrases
    /// listed first so the regex matches them before shorter prefixes.
    /// Matched at the START of a candidate split (after a sentence boundary).
    private static let markers: [String] = [
        "also let me",
        "and then",
        "oh and",
        "and message",
        "also",
        "next",
        "then",
        "oh"
    ]

    public static func split(_ raw: String) -> [TopicChunk] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Build a single regex that matches: (sentence-end punctuation OR
        // start-of-string) followed by one of the markers as a whole word.
        // We anchor against `(?:^|[.!?]\s+|[,;]\s+|\n+)` — anything that feels
        // like a sentence/clause boundary, including bare commas because
        // dictation rarely punctuates.
        let alternation = markers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let pattern = "(?i)(?:^|[.!?]\\s+|[,;]\\s+|\\n+)\\s*(\(alternation))\\b"

        guard let rx = try? NSRegularExpression(pattern: pattern) else {
            return [TopicChunk(text: trimmed, leadConnector: nil)]
        }

        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = rx.matches(in: trimmed, range: fullRange)

        // Filter out the "match starting at position 0" — the leading phrase
        // is the first chunk, not a split point.
        let splitPoints: [NSRange] = matches.compactMap { m in
            // The capture-group (group 1) is the marker itself. We want to
            // split immediately BEFORE the marker.
            guard m.numberOfRanges >= 2 else { return nil }
            let markerRange = m.range(at: 1)
            if markerRange.location == 0 { return nil }
            return markerRange
        }

        if splitPoints.isEmpty {
            return [TopicChunk(text: trimmed, leadConnector: nil)]
        }

        var chunks: [TopicChunk] = []
        var cursor = 0
        var pendingConnector: String? = nil

        for markerRange in splitPoints {
            let chunkLen = markerRange.location - cursor
            if chunkLen > 0 {
                let chunkText = ns.substring(with: NSRange(location: cursor, length: chunkLen))
                let cleaned = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    chunks.append(TopicChunk(text: cleaned, leadConnector: pendingConnector))
                }
            }
            pendingConnector = ns.substring(with: markerRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            cursor = markerRange.location
        }

        // Tail chunk.
        if cursor < ns.length {
            let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                chunks.append(TopicChunk(text: tail, leadConnector: pendingConnector))
            }
        }

        return chunks.isEmpty ? [TopicChunk(text: trimmed, leadConnector: nil)] : chunks
    }
}

// MARK: - ClassifierHint

public struct ClassifierHint: Sendable {
    public var userVocabulary: [String]
    public var lastIntent: Intent.Kind?

    public init(userVocabulary: [String] = [], lastIntent: Intent.Kind? = nil) {
        self.userVocabulary = userVocabulary
        self.lastIntent = lastIntent
    }
}

// MARK: - IntentClassifier

@MainActor
public final class IntentClassifier {
    public static let shared = IntentClassifier()

    private init() {}

    /// Classify a single chunk. Uses 1.7B model with a tight system prompt.
    /// Returns Intent on success, nil on timeout/error (caller falls back to .prose).
    ///
    /// TODO: replace with LLM classification — for now we run a deterministic
    /// regex heuristic so the plumbing works and tests are stable.
    public func classify(_ chunk: String, hint: ClassifierHint = .init()) async -> Intent? {
        // TODO: replace with LLM classification
        return Self.classifyHeuristically(chunk, hint: hint)
    }

    /// Classify all chunks of a multi-topic dictation. Returns one Intent per chunk.
    /// Runs classifications in parallel via TaskGroup.
    public func classifyAll(_ chunks: [TopicChunk]) async -> [Intent] {
        guard !chunks.isEmpty else { return [] }

        let hint = ClassifierHint()

        // Index-preserving parallel classification.
        return await withTaskGroup(of: (Int, Intent).self) { group in
            for (i, chunk) in chunks.enumerated() {
                group.addTask { [weak self] in
                    guard let self else {
                        return (i, Intent(kind: .prose, register: .neutral))
                    }
                    let intent = await self.classify(chunk.text, hint: hint)
                        ?? Intent(kind: .prose, register: .neutral)
                    return (i, intent)
                }
            }

            var results = Array(
                repeating: Intent(kind: .prose, register: .neutral),
                count: chunks.count
            )
            for await (i, intent) in group {
                results[i] = intent
            }
            return results
        }
    }

    // MARK: - Heuristic classifier (deterministic; will be replaced by LLM)

    /// Pure, deterministic heuristic. Exposed `internal` for tests.
    static func classifyHeuristically(_ raw: String, hint: ClassifierHint) -> Intent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // Default register heuristic — formal if long+structured, casual on
        // contractions/exclamations, neutral otherwise.
        let register: Register = inferRegister(text: text, lower: lower)

        // --- message / text / tell / send + person ---
        // "message Daniel hey..." → kind=.message, recipient=Daniel
        if let recipient = extractMessageRecipient(in: text) {
            // Long messages with formal register read as email.
            let words = text.split(separator: " ").count
            let kind: Intent.Kind = (words > 60 && register == .formal) ? .email : .message
            return Intent(
                kind: kind,
                register: register,
                recipient: recipient,
                topics: [],
                uncertainWords: [],
                confidence: 0.75
            )
        }

        // --- schema dictation ---
        // "make X table", "create X table", "schema" + comma-separated identifiers
        let schemaPattern = #"(?i)\b(?:make|create|build|define)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:table|schema|struct|object|model|class|record|type|interface)\b"#
        let hasSchemaWord = text.range(of: schemaPattern, options: .regularExpression) != nil
        let hasSchemaKeyword = lower.contains("schema")
        let commaIdentifiers = countCommaSeparatedIdentifiers(in: text)
        if (hasSchemaWord || hasSchemaKeyword) && commaIdentifiers >= 2 {
            return Intent(
                kind: .schema,
                register: .neutral,
                recipient: nil,
                topics: [],
                uncertainWords: [],
                confidence: 0.7
            )
        }

        // --- search query ---
        let searchPattern = #"(?i)^(?:find(?:\s+me)?|search(?:\s+for)?|google|look\s+up)\b"#
        if text.range(of: searchPattern, options: .regularExpression) != nil {
            return Intent(
                kind: .searchQuery,
                register: .neutral,
                confidence: 0.7
            )
        }

        // --- multi-topic todo list ---
        // 3+ topic-shift markers signals a multi-item list.
        let topicMarkers = ["also", "and then", "oh and", "also let me",
                            "next", "then", "and message", "oh"]
        let topicHits = topicMarkers.reduce(0) { acc, marker in
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return acc }
            return acc + rx.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        if topicHits >= 3 {
            return Intent(
                kind: .todoList,
                register: register,
                confidence: 0.65
            )
        }

        // --- imperative instruction ---
        // Starts with an imperative verb without a clear message-recipient target.
        let imperativeVerbs = ["book", "schedule", "order", "buy", "cancel",
                               "remind", "set", "open", "close", "start", "stop",
                               "pay", "call", "email", "play"]
        let firstWord = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .first ?? ""
        if imperativeVerbs.contains(firstWord) {
            return Intent(
                kind: .instruction,
                register: .neutral,
                confidence: 0.6
            )
        }

        // --- code dictation ---
        if text.contains("`") || lower.contains("function ") || lower.contains("class ")
            || lower.contains("def ") || lower.contains("()") {
            return Intent(
                kind: .code,
                register: .neutral,
                confidence: 0.55
            )
        }

        // --- note vs prose ---
        // Short single-sentence reflective utterances read as notes; everything
        // else falls through to prose.
        let words = text.split(separator: " ").count
        if words < 25 && (lower.contains("note ") || lower.hasPrefix("note ")
                          || lower.contains("remember ") || lower.contains("idea")) {
            return Intent(kind: .note, register: register, confidence: 0.5)
        }

        // --- default / fallback ---
        // Apply stickiness from prior chunk if confidence would be very low.
        if let sticky = hint.lastIntent, words < 6 {
            return Intent(kind: sticky, register: register, confidence: 0.4)
        }
        return Intent(kind: .prose, register: register, confidence: 0.5)
    }

    // MARK: - Heuristic helpers

    private static func inferRegister(text: String, lower: String) -> Register {
        if text.contains("!") || lower.contains("hey ") || lower.contains("lol")
            || lower.contains("yo ") || lower.contains("gonna") || lower.contains("wanna") {
            return .casual
        }
        if lower.contains("dear ") || lower.contains("regards") || lower.contains("sincerely")
            || lower.contains("kind regards") || lower.contains("to whom it may concern") {
            return .formal
        }
        return .neutral
    }

    /// Returns the captured recipient name if the chunk starts with one of
    /// {message, text, tell, send} immediately followed by a capitalized word.
    private static func extractMessageRecipient(in text: String) -> String? {
        // Allow the recipient to be lowercase in the raw transcript — dictation
        // rarely capitalizes. We just need it to LOOK like a name (single word,
        // alphabetic, not a stopword).
        let pattern = #"(?i)\b(?:message|text|tell|send|dm)\s+([A-Za-z][A-Za-z'\-]{1,30})\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: text, range: range), m.numberOfRanges >= 2 else {
            return nil
        }
        let name = ns.substring(with: m.range(at: 1))
        let stopwords: Set<String> = [
            "me", "him", "her", "them", "us", "you",
            "it", "this", "that", "the", "a", "an"
        ]
        if stopwords.contains(name.lowercased()) { return nil }
        // Capitalize first letter so downstream consumers see "Daniel" not "daniel".
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func countCommaSeparatedIdentifiers(in text: String) -> Int {
        let pattern = #"(?i)\b[a-z_][a-z0-9_]*\b\s*,\s*\b[a-z_][a-z0-9_]*\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = text as NSString
        return rx.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
    }
}
