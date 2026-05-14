// VOICE — Qwen3 LLM Polisher
// ============================================================
// On-device polish pass using Qwen3-0.6B-4bit via MLX-Swift.
//
// REPLACES the Apple Foundation Models path in LLMPolisher.swift, which
// observed ~2.5–6s per call. Qwen3-0.6B running on Metal (M2) typically
// finishes a short polish in ~80–150ms warm.
//
// Why MLX-Swift (not Ollama):
//   - Ollama is a separate server process (~120MB resident, slower IPC).
//     Shipping a server inside a packaged Mac app is heavyweight.
//   - MLX-Swift loads a Metal-accelerated model into our own process and
//     runs inference inline. No subprocess, no port, no daemon.
//
// Public API matches LLMPolisher 1:1 so callers (VoiceApp / CursorPaster /
// BigMenuWindow) can swap without further changes:
//   - `shared` singleton
//   - `polish(_:context:timeoutMs:)`
//   - `availabilityStatus` / `isEnabled` / `isAvailable`
//   - `prewarm()` / `lastLatencyMs` / `avgLatencyMs` / `sampleCount`
//
// Pipeline (preserved from LLMPolisher):
//   1. `stripFillers()` — rule-based, ~1ms
//   2. `isCleanEnough()` — rule-based skip-if-clean detector
//   3. Qwen3 polish — only if (1) + (2) say it's needed
// ============================================================

import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon
#endif

@MainActor
final class Qwen3Polisher {
    static let shared = Qwen3Polisher()

    /// Hugging Face id for the 4-bit Qwen3-1.7B build. ~970MB on disk.
    /// First call triggers a Hub download into ~/Documents/huggingface (the
    /// default HubApi cache) — subsequent launches load instantly from disk.
    /// Upgraded from 0.6B: needed for fixing badly garbled ASR (Chachi Pt → ChatGPT).
    private static let modelID = "mlx-community/Qwen3-1.7B-4bit"

    // Reuse the existing PolishContext enum so we don't have to migrate
    // CursorPaster and every other call site.
    typealias PolishContext = LLMPolisher.PolishContext

    // MARK: - Availability

    enum AvailabilityStatus: Equatable {
        case available           // model loaded + ready
        case downloading(Double) // first-run download in progress (0..1)
        case loading             // weights mapping into memory
        case notDownloaded       // never downloaded, not yet attempted
        case error(String)

        var displayLabel: String {
            switch self {
            case .available:               return "Ready"
            case .downloading(let p):
                let pct = Int((p * 100).rounded())
                return "Downloading model… \(pct)%"
            case .loading:                 return "Loading model…"
            case .notDownloaded:           return "Polish model not downloaded"
            case .error(let reason):       return reason
            }
        }

        var isReady: Bool { if case .available = self { return true } else { return false } }

        static func == (lhs: AvailabilityStatus, rhs: AvailabilityStatus) -> Bool {
            switch (lhs, rhs) {
            case (.available, .available),
                 (.loading, .loading),
                 (.notDownloaded, .notDownloaded):
                return true
            case let (.downloading(a), .downloading(b)):
                return a == b
            case let (.error(a), .error(b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Toggle

    /// User-facing on/off. Defaults to ON for everyone — Qwen3 is bundled-
    /// downloadable on every Apple Silicon Mac, no Apple Intelligence gate.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "llmPolishEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "llmPolishEnabled")
        }
        return true
    }

    /// True if MLX-Swift is linked. False only on builds where the optional
    /// dep didn't resolve (shouldn't happen in shipped product).
    static var isAvailable: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return true
        #else
        return false
        #endif
    }

    // MARK: - State

    /// Cached load task — concurrent prewarm + first-polish callers all
    /// await the same in-flight load instead of racing to each kick off
    /// their own download.
    private var loadTask: Any?  // Task<ModelContainer, Error> when MLX is present

    /// Current download/load status surfaced to UI.
    private(set) var availabilityStatus: AvailabilityStatus = .notDownloaded

    /// Static UI accessor mirroring `LLMPolisher.availabilityStatus`.
    static var availabilityStatus: AvailabilityStatus { shared.availabilityStatus }

    // Latency tracking — same shape as LLMPolisher (BigMenu pill reads these).
    private(set) var lastLatencyMs: Int = 0
    private(set) var avgLatencyMs: Double = 0
    private(set) var sampleCount: Int = 0

    // Warmup tracking — suppress "warming up" notification after the first
    // successful polish so the message is shown at most once per app launch.
    private(set) var hasWarmedUp: Bool = false

    private func recordLatency(_ ms: Int) {
        lastLatencyMs = ms
        sampleCount += 1
        avgLatencyMs = avgLatencyMs + (Double(ms) - avgLatencyMs) / Double(sampleCount)
    }

    // MARK: - Prewarm

    /// Force the model to download + page in. Eats the cold-start cost
    /// BEFORE the user's first dictation so the first real polish doesn't
    /// pay it. Sends a small realistic prompt to warm the inference path.
    ///
    /// Bumped to `.userInitiated` (was `.utility`) — the first dictation
    /// is gated on this completing, so user-visible latency tracks it
    /// directly. Background priority was leaving the model in `.loading`
    /// state long after app start.
    func prewarm() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard Self.isAvailable else {
            print("[VOICE] Qwen3 prewarm skipped: MLX not linked")
            return
        }
        print("[VOICE] Qwen3 prewarm starting (model: \(Self.modelID))")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let loadStart = Date()
                let container = try await self.ensureModel()
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                print("[VOICE] Qwen3 model loaded in \(loadMs)ms — running warmup gen")
                let session = ChatSession(
                    container,
                    instructions: Self.systemInstructions,
                    generateParameters: Self.warmupParams
                )
                let start = Date()
                _ = try await session.respond(to: Self.warmupPrompt)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("[VOICE] Qwen3 polisher pre-warmed in \(ms)ms (total cold start: \(loadMs + ms)ms)")
            } catch {
                print("[VOICE] Qwen3 prewarm failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.availabilityStatus = .error(error.localizedDescription)
                }
            }
        }
        #endif
    }

    // MARK: - Model load

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private func ensureModel() async throws -> ModelContainer {
        if let task = self.loadTask as? Task<ModelContainer, Error> {
            return try await task.value
        }
        // Kick off a single shared load. UI flips status as the Hub progress
        // handler fires.
        print("[VOICE] Qwen3 ensureModel: starting load (was \(availabilityStatus))")
        self.availabilityStatus = .loading
        let task = Task<ModelContainer, Error> {
            try await loadModelContainer(id: Self.modelID) { progress in
                let frac = progress.fractionCompleted
                // Detached hop back to MainActor — `loadModelContainer`'s
                // progress handler is `@Sendable` and runs off-actor.
                Task { @MainActor in
                    if frac < 1.0 {
                        Qwen3Polisher.shared.availabilityStatus = .downloading(frac)
                    }
                }
            }
        }
        self.loadTask = task
        do {
            let container = try await task.value
            print("[VOICE] Qwen3 ensureModel: load complete, status -> available")
            self.availabilityStatus = .available
            return container
        } catch {
            print("[VOICE] Qwen3 ensureModel: load FAILED: \(error.localizedDescription)")
            self.availabilityStatus = .error(error.localizedDescription)
            // Clear the failed task so the next call retries instead of
            // re-throwing the cached error forever.
            self.loadTask = nil
            throw error
        }
    }
    #endif

    // MARK: - Polish

    // MARK: - Language detection

    /// Reorder vocabulary so terms sharing letters/sounds with the suspect words
    /// come first. Keeps the most relevant 30 terms in scope when the prompt is
    /// truncated. Pure string heuristic — no phonetic library needed.
    nonisolated static func prioritizeVocabulary(_ vocab: [String], suspects: [String]?) -> [String] {
        guard let suspects, !suspects.isEmpty else { return vocab }
        let suspectChars = Set(suspects.joined().lowercased().filter { $0.isLetter })
        guard !suspectChars.isEmpty else { return vocab }
        return vocab.sorted { a, b in
            let aScore = Set(a.lowercased().filter { $0.isLetter }).intersection(suspectChars).count
            let bScore = Set(b.lowercased().filter { $0.isLetter }).intersection(suspectChars).count
            return aScore > bScore
        }
    }

    nonisolated private static func isDutch(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Common Dutch words/particles that rarely appear in English
        let dutchMarkers = ["hoor", "toch", "nou", "zeg", "eens", "even", "maar", "eh", "eigenlijk"]
        let dutchCount = dutchMarkers.filter { lower.contains($0) }.count
        if dutchCount >= 2 { return true }

        // Dutch-specific pattern: "het X is"
        if lower.range(of: #"\bhet\s+(\w+)\s+is\b"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Polish formatted text with a strict timeout. Returns the original
    /// string on any failure path (timeout, model unavailable, error).
    ///
    /// Timeout default raised to 2500ms — short polish on warm Qwen3-0.6B-4bit
    /// is ~80–150ms, but Metal kernel JIT compilation on the first real
    /// inference (post-warmup) can push the first user-visible polish to
    /// 1–2s. We'd rather wait than ship raw text.
    ///
    /// Fails open IMMEDIATELY if the model isn't `.available` yet — we never
    /// block the paste path waiting for download/load. The prewarm task
    /// (kicked from RecordingCoordinator) is responsible for getting us to
    /// ready state. If it hasn't yet, this polish is a no-op and the next
    /// one will pick up once ready.
    func polish(
        _ text: String,
        context: PolishContext = .default,
        timeoutMs: Int = 2500,
        suspectWords: [String]? = nil,
        userVocabulary: [String]? = nil
    ) async -> String {
        guard Self.isEnabled else {
            print("[VOICE] Qwen3 polish skipped: disabled by user")
            return text
        }
        guard Self.isAvailable else {
            print("[VOICE] Qwen3 polish skipped: MLX not linked at build time")
            return text
        }
        guard text.count >= 4 else { return text }
        // Code: skip polish entirely — model rewrites break syntax/identifiers
        if context == .code {
            print("[VOICE] Qwen3 polish skipped: code context")
            return text
        }

        // Step 1: Strip fillers (rule-based, ~1ms) — runs ALWAYS, even if we skip model
        let stripped = LLMPolisher.stripFillers(text)

        // Step 2: Skip model if text is Dutch (Qwen3 is English-trained and breaks Dutch)
        if Self.isDutch(stripped) {
            print("[VOICE] Qwen3 polish skipped: Dutch detected")
            return stripped
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        // Step 3: Fail open immediately if model not ready. We do NOT block
        // the paste path waiting for download/load — that was the
        // user-visible "models don't work" complaint: polish was hanging on
        // ensureModel() until the 380MB Qwen3 download finished. Prewarm
        // continues independently; the *next* polish call will pick up.
        if !availabilityStatus.isReady {
            print("[VOICE] Qwen3 polish fail-open: model not ready (status=\(availabilityStatus.displayLabel))")
            return stripped
        }
        print("[VOICE] Qwen3 polish START (input chars=\(stripped.count))")
        return await polishWithMLX(
            stripped,
            context: context,
            timeoutMs: timeoutMs,
            suspectWords: suspectWords,
            userVocabulary: userVocabulary
        )
        #else
        return stripped
        #endif
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private func polishWithMLX(
        _ text: String,
        context: PolishContext,
        timeoutMs: Int,
        suspectWords: [String]? = nil,
        userVocabulary: [String]? = nil
    ) async -> String {
        // Caller has already verified `availabilityStatus.isReady`, so this
        // is a fast-path container fetch — but we still go through the
        // cached task so concurrent polishes share state.
        let container: ModelContainer
        do {
            container = try await ensureModel()
        } catch {
            print("[VOICE] Qwen3 polish: model unavailable (\(error.localizedDescription))")
            return text
        }

        // Cap max tokens at roughly 2x input + a small buffer. Polish is by
        // definition same-length — leaving more room lets a runaway model
        // hang us until timeout fires.
        let approxInputTokens = max(8, text.count / 3)
        let cap = approxInputTokens * 2 + 16
        let params = GenerateParameters(temperature: 0.0, topP: 1.0)
            .with(maxTokens: cap)

        // Per-call prompt mimics the few-shot examples in `systemInstructions`.
        // `/no_think` is Qwen3's documented switch to suppress the
        // `<think>...</think>` reasoning block. Without it the 0.6B model
        // emits a multi-sentence reasoning preamble that blows past our
        // length/word-count sanitizer and gets every polish rejected. This
        // was THE silent failure causing "models don't work".
        //
        // Optional hints injected when available:
        //   - "Uncertain words": tokens the ASR flagged as low-confidence
        //     (below 0.6). Polisher should double-check these against context.
        //   - "Custom vocabulary": user-provided spellings (capped at 30 to
        //     keep the prompt short — the polisher only needs hints, not
        //     the full dictionary).
        var hints = ""
        if let suspectWords, !suspectWords.isEmpty {
            let joined = suspectWords.prefix(16).joined(separator: ", ")
            hints += "Uncertain words (low ASR confidence): [\(joined)]. These tokens are likely MIS-TRANSCRIBED. Check if each one phonetically resembles a term in the custom vocabulary below. If yes, replace it with the canonical spelling.\n"
        }
        if let userVocabulary, !userVocabulary.isEmpty {
            // Prioritize vocabulary terms that share letters/sounds with suspect words,
            // so the most relevant canonical spellings come first when the prompt is truncated.
            let prioritized = Self.prioritizeVocabulary(userVocabulary, suspects: suspectWords)
            let joined = prioritized.prefix(30).joined(separator: ", ")
            hints += "Custom vocabulary (canonical spellings — replace phonetically-similar garbled text with these): [\(joined)].\n"
            hints += "Phonetic-match rule: if a multi-word sequence SOUNDS like one of these terms, collapse it. Examples: 'Chachi Pt' → 'ChatGPT', 'Chatchi Petey' → 'ChatGPT', 'antrop pick' → 'Anthropic', 'antropic' → 'Anthropic', 'clore' → 'Claude', 'clod' → 'Claude', 'open A I' → 'OpenAI', 'C E O' → 'CEO', 'A P I' → 'API'. Word count MAY decrease when collapsing spelled-out or garbled forms — this is correct.\n"
        }

        let prompt = """
        /no_think
        \(hints)Context: \(context.rawValue)
        Input: \(text)
        Output:
        """

        let session = ChatSession(
            container,
            instructions: Self.systemInstructions,
            generateParameters: params
        )

        let start = Date()
        let isFirstCall = !hasWarmedUp

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("[VOICE] Qwen3 raw response (\(ms)ms): \(response.prefix(200))")
                    await MainActor.run { Qwen3Polisher.shared.recordLatency(ms) }
                    let cleaned = Self.sanitize(response, original: text, vocabulary: userVocabulary)
                    print("[VOICE] Qwen3 polish DONE in \(ms)ms — output=\(cleaned.prefix(120))")
                    return cleaned
                } catch {
                    print("[VOICE] Qwen3 polish error: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                print("[VOICE] Qwen3 polish TIMEOUT (\(timeoutMs)ms) — returning stripped input")
                return nil
            }
            // On the first-ever polish call, if inference hasn't returned within
            // 1000ms the Metal JIT warmup is still in progress. Post a one-shot
            // toast so the user knows the paste is coming — not that the app is
            // stuck. This task cancels immediately once the polish task wins.
            if isFirstCall {
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return nil }
                    print("[VOICE] Qwen3 first-polish warmup >1000ms — posting user notification")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .voiceError,
                            object: nil,
                            userInfo: ["message": "Polisher warming up — paste coming in a moment…"]
                        )
                    }
                    return nil
                }
            }
            for await result in group {
                group.cancelAll()
                if isFirstCall {
                    await MainActor.run { Qwen3Polisher.shared.hasWarmedUp = true }
                }
                return result ?? text
            }
            return text
        }
    }
    #endif

    // MARK: - Prompt

    /// System prompt for Qwen3 dictation polish.
    /// Scope: surface-level ASR correction only — spelling, homophones,
    /// capitalization, missing apostrophes, and merged/split ASR words.
    /// We deliberately do NOT ask it to rewrite, restructure, or rephrase.
    nonisolated private static let systemInstructions: String = """
    /no_think
    You are a speech-to-text corrector. Fix ASR transcription errors in dictated text. Do NOT rewrite or rephrase.

    ALWAYS fix:
    - Homophones (their/there/they're, your/you're, its/it's, to/too/two, by/buy, then/than, would→would've, should→should've, could→could've)
    - Capitalization: sentence starts, "I", proper nouns (names, places, companies), days of week, months
    - Missing apostrophes: dont→don't, cant→can't, wont→won't, shouldnt→shouldn't, youre→you're, thats→that's, whats→what's, havent→haven't, isnt→isn't
    - Clear ASR word merges/splits: "commandonth" is "command on the", "wellcome" is "welcome", "alot" is "a lot", "areyou" is "are you"
    - Obvious wrong-word substitutions: "I'd set" when context makes "I said" clear
    - Sentence-ending punctuation: Add period if text clearly ends a sentence but has no punctuation
    - Question marks: If a sentence is clearly a question (starts with "what", "why", "how", "do you", "can you", "will you", "should"), add ?
    - PHONETIC RESEMBLANCE to known terms: if a sequence of tokens SOUNDS like a brand/product/acronym (especially one in the "Custom vocabulary" hint), replace it with the canonical spelling. ASR frequently splits proper nouns into nonsense words (e.g. "ChatGPT" → "Chachi Pt"). Restore them. This is the single most important class of fix you make. Word count is allowed to change here.
    - SPELLED-OUT acronyms: when the speaker pronounces letters separately ("F B I", "C E O", "A P I", "U R L"), collapse them to the acronym (FBI, CEO, API, URL).

    NEVER:
    - Rephrase, reword, or restructure sentences
    - Add, remove, or reorder words unless fixing a clear merge/split error
    - Change number/time formats (3pm stays 3pm, 5 stays 5)
    - Add em dashes, ellipses, or commas
    - Expand contractions (you're stays you're)
    - Split sentences (one sentence stays one sentence unless separating clear mistakes)
    - Change informal/slang words that are valid user intent: yo, nah, gonna, wanna, kinda, sorta, yep, nope, lowkey, highkey, fam, bro, dude, vibe, hyped, legit, lit, sick, fire, goat, slay, sus — leave these EXACTLY as spoken

    If text is already correct: output it UNCHANGED.

    Examples:
    Input: i went their yesturday and saw they're car
    Output: I went there yesterday and saw their car.

    Input: your right about that
    Output: You're right about that.

    Input: lets ask sarah about the new york trip
    Output: Let's ask Sarah about the New York trip.

    Input: commandonth start the meeting
    Output: Command on the start of the meeting.

    Input: i want too make a dictatoin app
    Output: I want to make a dictation app.

    Input: what time is it
    Output: What time is it?

    Input: i said we should ship friday
    Output: I said we should ship Friday.

    Input: meeting at 3pm tomorrow with john
    Output: Meeting at 3pm tomorrow with John.

    Input: dont worry about that
    Output: Don't worry about that.

    Input: i cant believe it works
    Output: I can't believe it works.

    Input: i use chatgpt and claude every day
    Output: I use ChatGPT and Claude every day.

    Input: she works at google in the chrome team
    Output: She works at Google in the Chrome team.

    Input: download it from the app store on your iphone
    Output: Download it from the App Store on your iPhone.

    Input: the ceo of apple announced the new macbook
    Output: The CEO of Apple announced the new MacBook.

    Examples of GARBLED-ASR fixes (phonetic resemblance — word count changes):
    Input: chachi pt is amazing
    Output: ChatGPT is amazing.

    Input: i asked chachi petey to write it
    Output: I asked ChatGPT to write it.

    Input: i love antrop pick claude
    Output: I love Anthropic Claude.

    Input: open A I just shipped a new model
    Output: OpenAI just shipped a new model.

    Input: the F B I investigated the C E O
    Output: The FBI investigated the CEO.

    Input: i use clore for coding
    Output: I use Claude for coding.

    Input: send the A P I key via U R L
    Output: Send the API key via URL.

    Output ONLY the corrected text. No explanation, no preamble, no quotes, no thinking, no markdown.
    """

    nonisolated private static let warmupPrompt: String = """
    /no_think
    Context: general prose
    Input: hello world
    Output:
    """

    // MARK: - Sanitizer (ported from LLMPolisher)

    nonisolated private static func sanitize(_ output: String, original: String, vocabulary: [String]? = nil) -> String {
        var cleaned = output

        // Strip Qwen3 `<think>...</think>` reasoning blocks. Qwen3 ships with
        // reasoning ON by default; the `/no_think` directive in our prompt
        // *should* suppress it, but the model occasionally still emits an
        // empty `<think></think>` pair or a short reasoning trace. Either
        // way it must come off before length/word-count checks or every
        // polish gets rejected.
        if let thinkRange = cleaned.range(of: #"<think>[\s\S]*?</think>"#, options: .regularExpression) {
            cleaned.removeSubrange(thinkRange)
        }
        // Defensive: if the model produced an unclosed `<think>` (rare —
        // happens if maxTokens cap fires inside the reasoning block), strip
        // everything from `<think>` onward and reject downstream.
        if let openThink = cleaned.range(of: "<think>") {
            cleaned.removeSubrange(openThink.lowerBound..<cleaned.endIndex)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("<<<") { cleaned = String(cleaned.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if cleaned.hasSuffix(">>>") { cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        // Strip a leading "Output:" echo (model occasionally repeats the prompt marker).
        if cleaned.lowercased().hasPrefix("output:") {
            cleaned = String(cleaned.dropFirst("output:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // If the model continued past the first answer into a new "Input:" / "Output:"
        // turn, truncate at the boundary. Cheap and prevents runaway echo.
        if let cutRange = cleaned.range(of: #"\n\s*(Input|Output):"#, options: .regularExpression) {
            cleaned = String(cleaned[..<cutRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If input was a single line, collapse any inserted line breaks.
        let originalLineCount = original.components(separatedBy: .newlines).count
        if originalLineCount == 1 {
            cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
            cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Word-count drift check. Default budget = ±3 (covers ordinary
        // merges/splits like "commandonth" → "command on the"). When the cleaned
        // output introduces a canonical vocabulary term that was not present in
        // the original (i.e. the model collapsed a phonetic match like
        // "Chachi Pt" → "ChatGPT"), the legitimate delta can be larger — every
        // compressed term may save 1-2 words. Grant +2 extra budget per such hit.
        let originalWords = original.split { $0.isWhitespace }.count
        let cleanedWords = cleaned.split { $0.isWhitespace }.count
        let wordDelta = abs(originalWords - cleanedWords)
        var wordBudget = 3
        if let vocabulary, !vocabulary.isEmpty {
            let originalLower = original.lowercased()
            let cleanedLower = cleaned.lowercased()
            let introducedTerms = vocabulary.filter { term in
                let lower = term.lowercased()
                return !lower.isEmpty
                    && cleanedLower.contains(lower)
                    && !originalLower.contains(lower)
            }
            wordBudget += introducedTerms.count * 2
            if !introducedTerms.isEmpty {
                print("[VOICE] Qwen3 sanitizer: vocab terms introduced \(introducedTerms) — wordBudget extended to \(wordBudget)")
            }
        }
        guard wordDelta <= wordBudget else {
            print("[VOICE] Qwen3 polish rejected: word count drift \(originalWords)->\(cleanedWords) (delta \(wordDelta), budget \(wordBudget))")
            return original
        }

        // Length drift check — same vocabulary-aware relaxation.
        // Default 35%; expanded to 60% when a canonical term replaced garbled text,
        // because legit replacements can compress substantially ("Chachi Pt" → "ChatGPT").
        let lenDelta = abs(cleaned.count - original.count)
        let baseThreshold = max(original.count * 35 / 100, 10)
        var lenThreshold = baseThreshold
        if wordBudget > 3 {
            lenThreshold = max(original.count * 60 / 100, 20)
        }
        guard lenDelta <= lenThreshold else {
            print("[VOICE] Qwen3 polish rejected: length drift \(original.count)->\(cleaned.count) (threshold \(lenThreshold))")
            return original
        }

        // Explanation preambles -> reject.
        let lower = cleaned.lowercased()
        for forbidden in ["here is", "here's", "i fixed", "corrected", "cleaned:"] {
            if lower.hasPrefix(forbidden) {
                print("[VOICE] Qwen3 polish rejected: preamble detected")
                return original
            }
        }
        return cleaned
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon)
// MARK: - GenerateParameters convenience

private extension GenerateParameters {
    /// Builder-style maxTokens setter so call sites stay one-liners.
    func with(maxTokens: Int) -> GenerateParameters {
        var copy = self
        copy.maxTokens = maxTokens
        return copy
    }
}

private extension Qwen3Polisher {
    /// Generation params used for the warmup call. Smaller cap, same temp.
    /// `nonisolated` because the prewarm Task.detached body reads this from
    /// outside the main actor — and it's pure value construction with no
    /// shared state, so isolation gains nothing.
    nonisolated static var warmupParams: GenerateParameters {
        GenerateParameters(temperature: 0.0, topP: 1.0).with(maxTokens: 32)
    }
}
#endif
