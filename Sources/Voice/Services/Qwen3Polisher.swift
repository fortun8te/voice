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
    // TODO(bug-hunt): singleton retains both ModelContainers (`loadTask` and
    // `largeLoadTask`) for the entire process lifetime. On 8GB Macs the
    // combined ~4GB working set never gets released. Consider adding an
    // `unloadIfIdle(after:)` that nils the tasks after N minutes of no
    // polish activity, and a re-load on the next `polish()` call. Out of
    // scope for this surgical bug pass — would touch every call site that
    // assumes "ready means ready forever".
    static let shared = Qwen3Polisher()

    /// Known product/brand names — injected into every polish prompt so the
    /// model preserves them verbatim instead of "correcting" them. Add new
    /// entries here whenever a user-reported brand gets mangled by the
    /// polish pass.
    nonisolated static let knownProductNames: [String] = [
        "Wispr Flow", "Whisper", "Parakeet", "Moonshine", "Granite",
        "ChatGPT", "Claude", "Anthropic", "OpenAI", "Gemini",
        "VOICE", "macOS", "iOS", "iPhone", "iPad",
        "Swift", "Xcode", "MLX", "Metal", "CoreML",
        "GitHub", "Figma", "Slack", "Notion", "Linear",
        "VS Code", "Cursor", "Warp", "Arc",
        "AirPods", "MacBook",
    ]

    /// Hugging Face id for the 4-bit Qwen3-1.7B build. ~970MB on disk.
    /// First call triggers a Hub download into ~/Documents/huggingface (the
    /// default HubApi cache) — subsequent launches load instantly from disk.
    /// Upgraded from 0.6B: needed for fixing badly garbled ASR (Chachi Pt → ChatGPT).
    private static let modelID = "mlx-community/Qwen3-1.7B-4bit"

    /// Hugging Face id for the 4-bit Qwen3-4B-Instruct build. ~2.4GB on disk.
    /// Routed to for longer / structurally-richer dictations where the 1.7B
    /// model under-restructures or fails to follow nested formatting rules.
    /// Loaded lazily behind the small model so first launch isn't blocked.
    private static let largeModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"

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

    /// Cached load task for the 4B prose-quality model. Same sharing semantics
    /// as `loadTask` but for `largeModelID`.
    private var largeLoadTask: Any?  // Task<ModelContainer, Error> when MLX is present

    /// Current download/load status surfaced to UI.
    private(set) var availabilityStatus: AvailabilityStatus = .notDownloaded

    /// Static UI accessor mirroring `LLMPolisher.availabilityStatus`.
    static var availabilityStatus: AvailabilityStatus { shared.availabilityStatus }

    /// Readiness flag for the 4B prose-quality model. Mirrors the role of
    /// `availabilityStatus.isReady` for the 1.7B, but kept separate because
    /// the 4B is a best-effort background upgrade and MUST NOT block the
    /// small-model "ready" state (the UI uses `availabilityStatus` to gate
    /// the hotkey). Flipped to `true` on @MainActor only after a successful
    /// load of the 4B. Stays `false` permanently for the session if the load
    /// fails — we do not infinite-retry; the 1.7B fast path remains active.
    ///
    /// =============== Memory budget (do not implement; document) ===============
    /// macOS unified memory means our resident set competes with the OS plus
    /// the always-resident Parakeet ASR (~250MB) plus whatever Xcode-style
    /// background processes the user has running.
    ///
    ///   Qwen3-1.7B-4bit:           ~1.0GB on disk, ~1.2GB resident
    ///   Qwen3-4B-Instruct-2507-4bit: ~2.4GB on disk, ~2.8GB resident
    ///   Parakeet ASR:                                    ~250MB resident
    ///   Combined working set when both LLMs loaded:        ~4.0GB+
    ///
    /// On 8GB Macs:   expect swap pressure / memory warnings once both are
    ///                paged in. The OS will likely keep them, but background
    ///                apps will get jettisoned.
    /// On 16GB Macs:  comfortable headroom.
    /// On 32GB+ Macs: trivial.
    ///
    /// Future work (NOT this pass): on `ProcessInfo.processInfo.physicalMemory
    /// < 12 * 1024 * 1024 * 1024` we should skip the 4B prewarm entirely and
    /// only load it on-demand when the user actually dictates a long form.
    /// =========================================================================
    ///
    /// TODO(model-ready): `VoiceApp.swift`'s `checkModelsReadyOrToast()`
    /// currently only inspects `availabilityStatus.isReady` (the 1.7B). For
    /// long dictations the hotkey will fire, the polish/merge path will route
    /// to the 4B via `polishWithMLX`, and gracefully fall back to the 1.7B if
    /// the 4B hasn't loaded yet — so this is non-blocking. If we ever want
    /// the toast to surface "large model still downloading" UX (e.g. the
    /// user expects the high-quality model to be available before holding
    /// the hotkey for a long dictation), `checkModelsReadyOrToast()` should:
    ///   1. Read `Qwen3Polisher.isLargeModelReady` (static accessor below).
    ///   2. If `false` AND the hotkey hold has already exceeded ~3s (i.e. the
    ///      user is mid-long-dictation), append " · Large model loading" to
    ///      the existing toast — DO NOT add the 4B as a hard gate (small
    ///      model is functional and the fallback is automatic in polish).
    /// Until then, only the small-model gate is enforced.
    private(set) var isLargeModelReady: Bool = false

    /// Static UI accessor for the 4B readiness flag.
    static var isLargeModelReady: Bool { shared.isLargeModelReady }

    /// Set to `true` the first time `ensureLargeModel()` throws — used to
    /// suppress infinite background retries when the model id is bad or the
    /// network is offline. Stays `true` until app relaunch.
    private var largeModelLoadFailedThisSession: Bool = false

    // Latency tracking — same shape as LLMPolisher (BigMenu pill reads these).
    private(set) var lastLatencyMs: Int = 0
    private(set) var avgLatencyMs: Double = 0
    private(set) var sampleCount: Int = 0

    // Warmup tracking — suppress "warming up" notification after the first
    // successful polish so the message is shown at most once per app launch.
    private(set) var hasWarmedUp: Bool = false

    // MARK: - Rolling context
    // Keeps the last ~60 words pasted in the current session so Qwen3 can
    // use prior utterances to resolve ambiguous / mis-transcribed words.
    // Automatically expires after 90 seconds of silence (user moved on).
    private var rollingContextWords: [String] = []
    private var lastPolishTime: Date? = nil
    private let rollingContextMaxWords = 60
    private let rollingContextExpiry: TimeInterval = 90

    /// Append the most-recent polished output to the rolling context buffer.
    /// Call after a successful paste so the next dictation sees it.
    func updateRollingContext(_ text: String) {
        let now = Date()
        // Expire on long pause (user moved on to something else).
        if let last = lastPolishTime, now.timeIntervalSince(last) > rollingContextExpiry {
            rollingContextWords = []
        }
        lastPolishTime = now
        let words = text.split(separator: " ").map(String.init)
        rollingContextWords.append(contentsOf: words)
        if rollingContextWords.count > rollingContextMaxWords {
            rollingContextWords = Array(rollingContextWords.suffix(rollingContextMaxWords))
        }
    }

    /// Clear rolling context — call when the user starts a new document / topic.
    func clearRollingContext() {
        rollingContextWords = []
        lastPolishTime = nil
    }

    private var currentRollingContext: String? {
        guard !rollingContextWords.isEmpty else { return nil }
        // Don't feed context that has expired.
        if let last = lastPolishTime, Date().timeIntervalSince(last) > rollingContextExpiry {
            return nil
        }
        return rollingContextWords.joined(separator: " ")
    }

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
                // After the 1.7B is warm and the user has fast-path polish,
                // kick off the 4B download/load in the background. Fire-and-
                // forget — we never await this from prewarm; the 4B becomes
                // available whenever it finishes and `polishWithMLX` will
                // start routing to it transparently.
                //
                // Important: `ensureLargeModel()` is @MainActor (the polisher
                // class is @MainActor). We do NOT hop here — Swift will await
                // the actor isolation hop automatically when calling. The
                // outer Task.detached is still useful for priority isolation
                // so the 4B download doesn't compete with the userInitiated
                // priority of the small-model warmup.
                print("[VOICE-LP] 4B prewarm: starting download/load")
                let bigStart = Date()
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    // Guard against infinite-retry if the load failed earlier
                    // this session (bad model id, offline, etc.). Reading
                    // `largeModelLoadFailedThisSession` requires the main
                    // actor; check there before doing any work.
                    let alreadyFailed = await MainActor.run { self.largeModelLoadFailedThisSession }
                    if alreadyFailed {
                        print("[VOICE-LP] 4B prewarm: skipped — prior load failed this session")
                        return
                    }
                    do {
                        _ = try await self.ensureLargeModel()
                        let elapsed = Date().timeIntervalSince(bigStart)
                        print(String(format: "[VOICE-LP] 4B prewarm: ready in %.1fs", elapsed))
                    } catch {
                        print("[VOICE-LP] 4B prewarm: FAILED: \(error.localizedDescription)")
                        // Falls back to 1.7B automatically — see polishWithMLX.
                    }
                }
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
        // Use Task.detached: the surrounding class is @MainActor, so an
        // unstructured `Task { ... }` would inherit MainActor isolation and
        // pin the synchronous slices of `loadModelContainer` (weight mapping,
        // metal kernel JIT) to the main thread, freezing the UI on first run.
        let modelID = Self.modelID
        let task = Task.detached(priority: .userInitiated) { () -> ModelContainer in
            try await loadModelContainer(id: modelID) { progress in
                let frac = progress.fractionCompleted
                // Hop back to MainActor — `loadModelContainer`'s progress
                // handler is `@Sendable` and runs off-actor.
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

    /// Parallel loader for the 4B prose-quality model. Modeled exactly on
    /// `ensureModel()` — same caching, same error handling — but uses
    /// `largeModelID` and does NOT touch `availabilityStatus` because the
    /// 1.7B model defines whether the polisher is "ready". The 4B is a
    /// best-effort background upgrade for long/complex dictations; if it
    /// hasn't finished loading yet, `polishWithMLX` falls back to the 1.7B.
    ///
    /// On the first successful load we flip `isLargeModelReady = true`
    /// (already on the main actor). On failure we set
    /// `largeModelLoadFailedThisSession = true` so the background prewarm
    /// won't infinite-retry a bad model id / offline state. Direct callers
    /// from `polishWithMLX` will still get the throw and fall back to the
    /// small model.
    private func ensureLargeModel() async throws -> ModelContainer {
        if let task = self.largeLoadTask as? Task<ModelContainer, Error> {
            return try await task.value
        }
        // Don't re-attempt if a prior load has already permanently failed
        // this session. The caller will throw → polishWithMLX falls back
        // to the 1.7B silently.
        if largeModelLoadFailedThisSession {
            throw NSError(domain: "Qwen3Polisher", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Large model load previously failed this session"])
        }
        print("[VOICE-LP] 4B prewarm: starting download/load (id=\(Self.largeModelID))")
        let loadStart = Date()
        // Detached for the same reason as `ensureModel()` — the 4B is even
        // heavier and would freeze MainActor on weight-map / JIT slices if
        // we let the unstructured Task inherit isolation from this method.
        let largeID = Self.largeModelID
        let task = Task.detached(priority: .utility) { () -> ModelContainer in
            try await loadModelContainer(id: largeID) { progress in
                let frac = progress.fractionCompleted
                if frac < 1.0 && frac > 0 {
                    // Best-effort progress log; do NOT clobber availabilityStatus
                    // (the 1.7B drives the UI-visible status).
                    print("[VOICE-LP] 4B download: \(Int(frac * 100))%")
                }
            }
        }
        self.largeLoadTask = task
        do {
            let container = try await task.value
            let elapsed = Date().timeIntervalSince(loadStart)
            print(String(format: "[VOICE-LP] 4B prewarm: ready in %.1fs", elapsed))
            // Flip readiness on the main actor (we already are — class is
            // @MainActor — but the assignment is explicit for clarity and so
            // a future refactor that detaches this method can't silently
            // miss the actor hop).
            self.isLargeModelReady = true
            return container
        } catch {
            print("[VOICE-LP] 4B prewarm: FAILED: \(error.localizedDescription)")
            // Permanent failure flag — see `ensureLargeModel` doc comment.
            // We do NOT clear `largeLoadTask` here because the cached task's
            // value will throw the same error on every retry anyway, AND we
            // want the next attempt (from polishWithMLX) to also see the
            // failure and fall back. Setting the permanent flag prevents
            // the background prewarm from re-entering this path.
            self.largeModelLoadFailedThisSession = true
            self.isLargeModelReady = false
            // Clear so direct polish calls can retry (best-effort) but the
            // background prewarm is gated by `largeModelLoadFailedThisSession`.
            self.largeLoadTask = nil
            throw error
        }
    }
    #endif

    // MARK: - Polish

    // MARK: - Language detection

    /// Reorder vocabulary so terms phonetically similar to the suspect words come
    /// first. Keeps the most relevant 30 terms in scope when the prompt is
    /// truncated. Uses a tiny inline Soundex implementation — set-of-letters
    /// intersection (the previous approach) is bag-of-letters voodoo: "Anthropic"
    /// and "antibiotic" score nearly identical, while "ChatGPT" and "Chachi Pt"
    /// share zero letters once tokenized. Soundex maps both halves of an
    /// ASR-shattered proper noun onto the same code sequence.
    nonisolated static func prioritizeVocabulary(_ vocab: [String], suspects: [String]?) -> [String] {
        guard let suspects, !suspects.isEmpty else { return vocab }

        // Section E: in-memory cache keyed on (vocab hash, suspects hash).
        // The polish hot-path can hit this with the same `(vocab, suspects)`
        // tuple multiple times per dictation (polish + merge prompt build),
        // and soundex scoring on a 60-entry vocab against 16 suspects is
        // measurable. FIFO eviction at capacity 16 — small dictation surface,
        // no need for true LRU.
        let cacheKey = "\(vocab.hashValue):\(suspects.joined().hashValue)"
        if let cached = vocabPrioritizationCache.read(cacheKey) {
            return cached
        }

        // Compute soundex codes for every suspect token (whitespace-split so
        // "Chachi Pt" yields ["C200", "P300"] which together cover ChatGPT's
        // code by prefix overlap).
        let suspectCodes: [String] = suspects
            .flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }
            .map { soundex($0) }
            .filter { !$0.isEmpty }
        guard !suspectCodes.isEmpty else { return vocab }

        // Score a vocab term by the best phonetic match across its own tokens
        // vs. any suspect token. Same-code = 4 points, 3-char prefix = 2,
        // first-letter match = 1.
        func score(_ term: String) -> Int {
            let termCodes = term.split(whereSeparator: { !$0.isLetter })
                .map { soundex(String($0)) }
                .filter { !$0.isEmpty }
            var best = 0
            for tc in termCodes {
                for sc in suspectCodes {
                    if tc == sc { best = max(best, 4) }
                    else if tc.prefix(3) == sc.prefix(3) && tc.count >= 3 { best = max(best, 2) }
                    else if tc.first == sc.first { best = max(best, 1) }
                }
            }
            return best
        }
        let result = vocab.sorted { score($0) > score($1) }
        vocabPrioritizationCache.write(cacheKey, value: result)
        return result
    }

    /// Tiny FIFO cache for `prioritizeVocabulary`. NSLock makes it safe to
    /// call from any actor / queue since the surrounding function is
    /// `nonisolated`. Capacity 16 — when full, drop the oldest entry.
    private final class VocabCache: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = []
        private var store: [String: [String]] = [:]
        private let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        func read(_ key: String) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            return store[key]
        }
        func write(_ key: String, value: [String]) {
            lock.lock(); defer { lock.unlock() }
            if store[key] != nil {
                store[key] = value
                return
            }
            if order.count >= capacity, let oldest = order.first {
                order.removeFirst()
                store.removeValue(forKey: oldest)
            }
            order.append(key)
            store[key] = value
        }
    }
    nonisolated private static let vocabPrioritizationCache = VocabCache(capacity: 16)

    /// Tiny Soundex implementation (standard American Soundex):
    ///   1. Keep the first letter (uppercase).
    ///   2. Map consonants: B/F/P/V → 1, C/G/J/K/Q/S/X/Z → 2, D/T → 3,
    ///      L → 4, M/N → 5, R → 6. Vowels (A/E/I/O/U/Y) drop and reset the
    ///      adjacency-dedup chain. H/W are silent: skip without emitting,
    ///      but do not reset dedup (so "Pfister" collapses correctly).
    ///   3. Collapse runs of the same code.
    ///   4. Pad/truncate to 4 chars (letter + 3 digits).
    /// Returns "" for empty/non-alpha input. Examples:
    ///   "ChatGPT" → "C231", "Chachi" → "C200", "Pt" → "P300",
    ///   "Anthropic" → "A536", "Claude" → "C430", "Clore" → "C460".
    nonisolated static func soundex(_ word: String) -> String {
        let letters = word.uppercased().filter { $0.isLetter }
        guard let first = letters.first else { return "" }

        func code(_ ch: Character) -> Character? {
            switch ch {
            case "B", "F", "P", "V": return "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
            case "D", "T": return "3"
            case "L": return "4"
            case "M", "N": return "5"
            case "R": return "6"
            case "H", "W": return "_" // silent: skip emission, keep lastCode
            default: return nil       // vowels reset dedupe
            }
        }

        var result: [Character] = [first]
        var lastCode: Character? = code(first)
        for ch in letters.dropFirst() {
            guard let c = code(ch) else {
                lastCode = nil // vowel: reset dedupe chain
                continue
            }
            if c == "_" { continue } // H/W
            if c != lastCode {
                result.append(c)
                lastCode = c
                if result.count == 4 { break }
            }
        }
        while result.count < 4 { result.append("0") }
        return String(result)
    }

    // MARK: - Language detection
    //
    // Strategy: word-boundary stopword frequency per language. ASR often
    // strips accents, so we match unaccented forms. \b prevents substring
    // false-positives ("est" inside "best", "der" inside "wonder").
    // If ANY non-English language scores >=2 unique hits, skip polish —
    // Qwen3 is English-trained and would otherwise rewrite the dictation
    // into English-shaped slop. English is the default for ambiguous input.

    nonisolated private static func stopwordHits(_ lower: String, _ words: [String]) -> Int {
        var hits = 0
        for w in words {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil { hits += 1 }
        }
        return hits
    }

    nonisolated private static func isDutch(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Word-boundary matching (same as the other language detectors) prevents
        // false positives from substring matches: "eh" inside "the"/"when"/"they",
        // "nou" inside "announce"/"enough", "maar" inside "remark", etc.
        // "eh" and "even" removed from the list: "eh" is a common English
        // interjection (Canadian/British), and "even" is a common English word.
        // "nou" removed: substring of "announce", "enough".
        let dutchMarkers = ["hoor", "toch", "zeg", "eigenlijk", "gewoon", "jullie", "waarbij", "hiervan", "daarna", "waarom"]
        let dutchCount = stopwordHits(lower, dutchMarkers)
        if dutchCount >= 2 { return true }
        if lower.range(of: #"\bhet\s+(\w+)\s+is\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    nonisolated private static func isFrench(_ text: String) -> Bool {
        let markers = ["le", "la", "les", "une", "des", "est", "et", "je", "vous", "nous", "pas", "pour", "avec", "mais", "dans", "sur", "qui", "que", "ce", "ces", "mon", "ton", "son"]
        return stopwordHits(text.lowercased(), markers) >= 2
    }

    nonisolated private static func isGerman(_ text: String) -> Bool {
        let markers = ["der", "die", "das", "und", "ist", "ich", "nicht", "ein", "eine", "mit", "auch", "auf", "von", "den", "dem", "sich", "wir", "ihr", "sie", "aber", "wenn", "weil", "nur", "noch", "schon"]
        return stopwordHits(text.lowercased(), markers) >= 2
    }

    nonisolated private static func isSpanish(_ text: String) -> Bool {
        // Avoid "no" (English too) and bare "a" (English article).
        let markers = ["el", "la", "los", "las", "una", "unos", "unas", "que", "esto", "esta", "esos", "esas", "pero", "porque", "para", "con", "sin", "muy", "tambien", "donde", "cuando", "como", "es", "soy", "eres", "somos"]
        return stopwordHits(text.lowercased(), markers) >= 2
    }

    nonisolated private static func isItalian(_ text: String) -> Bool {
        let markers = ["il", "lo", "la", "gli", "le", "una", "uno", "che", "questo", "questa", "sono", "siamo", "sei", "siete", "non", "anche", "molto", "perche", "quando", "dove", "come", "con", "senza", "del", "della", "dei", "delle", "nel", "nella"]
        return stopwordHits(text.lowercased(), markers) >= 2
    }

    nonisolated private static func isPortuguese(_ text: String) -> Bool {
        let markers = ["nao", "sim", "voce", "esta", "estou", "muito", "obrigado", "obrigada", "por", "para", "com", "sem", "mas", "porque", "quando", "onde", "como", "isto", "isso", "aquele", "aquilo", "tambem", "ainda", "agora", "depois", "antes"]
        return stopwordHits(text.lowercased(), markers) >= 2
    }

    /// True iff input is confidently in a non-English language. Used by the
    /// polish gate to skip Qwen3 (English-trained) entirely for foreign input.
    nonisolated private static func isNonEnglish(_ text: String) -> Bool {
        return isDutch(text)
            || isFrench(text)
            || isGerman(text)
            || isSpanish(text)
            || isItalian(text)
            || isPortuguese(text)
    }

    // MARK: - Spoken punctuation detection

    /// Returns true if the original ASR input contains any literal spoken-
    /// punctuation command. These legitimately compress polished output by
    /// 5-30 chars per occurrence ("comma" → ",", "new paragraph" → "\n\n"),
    /// so the length-drift sanitizer must relax when any are present.
    nonisolated private static func hasSpokenPunctuation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let tokens = ["comma", "period", "full stop", "exclamation point", "exclamation mark", "question mark", "new line", "newline", "new paragraph", "colon", "semicolon", "dash", "ellipsis", "dot dot dot", "open paren", "close paren", "in parens", "paren", "quote", "end quote", "unquote", "close quote"]
        for t in tokens {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: t) + "\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    // MARK: - Multi-model merge

    /// Merge ASR transcripts (Parakeet v2 + Granite 4.0 1B + Moonshine Tiny) into a
    /// single best-of output, then apply the standard polish pipeline.
    ///
    /// Qwen3 compares the transcripts word-by-word and selects the more accurate
    /// reading for each segment (better proper nouns, numbers, etc.). The merged
    /// result is then sanitized the same way a single-transcript polish would be.
    ///
    /// Falls back to `polish(parakeet, ...)` if both granite and moonshine are nil
    /// or empty, or if the model is not ready.
    func merge(
        parakeet: String,
        granite: String?,
        moonshine: String? = nil,
        context: PolishContext = .default,
        timeoutMs: Int = 3500,
        suspectWords: [String]? = nil,
        userVocabulary: [String]? = nil,
        fieldContext: String? = nil,
        cleanupLevel: String = "medium",
        personalityStyle: String = "neutral"
    ) async -> String {
        // If neither Granite nor Moonshine gave us anything useful, fall back to
        // standard single-model polish.
        let graniteClean = granite?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let moonshineClean = moonshine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasGranite = !graniteClean.isEmpty && graniteClean != parakeet
        let hasMoonshine = !moonshineClean.isEmpty && moonshineClean != parakeet
        guard hasGranite || hasMoonshine else {
            return await polish(parakeet, context: context, timeoutMs: timeoutMs,
                                suspectWords: suspectWords, userVocabulary: userVocabulary,
                                fieldContext: fieldContext,
                                cleanupLevel: cleanupLevel, personalityStyle: personalityStyle)
        }

        // When cloud is the active engine, skip the local 3-way merge entirely.
        // The 235B model fixing errors from a single high-quality parakeet
        // transcript beats a 4B doing 3-way voting. Route straight through
        // polish() which handles cloud + fallback.
        if CerebrasPolisher.isAvailable {
            return await polish(parakeet, context: context, timeoutMs: timeoutMs,
                                suspectWords: suspectWords, userVocabulary: userVocabulary,
                                fieldContext: fieldContext,
                                cleanupLevel: cleanupLevel, personalityStyle: personalityStyle)
        }

        guard Self.isEnabled, Self.isAvailable else {
            return await polish(parakeet, context: context, timeoutMs: timeoutMs,
                                suspectWords: suspectWords, userVocabulary: userVocabulary,
                                fieldContext: fieldContext,
                                cleanupLevel: cleanupLevel, personalityStyle: personalityStyle)
        }

        guard !Self.isNonEnglish(parakeet) else {
            return LLMPolisher.stripFillers(parakeet)
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        if !availabilityStatus.isReady {
            return LLMPolisher.stripFillers(parakeet)
        }

        return await mergeWithMLX(
            parakeet: LLMPolisher.stripFillers(parakeet),
            granite: hasGranite ? graniteClean : nil,
            moonshine: hasMoonshine ? moonshineClean : nil,
            context: context,
            timeoutMs: timeoutMs,
            suspectWords: suspectWords,
            userVocabulary: userVocabulary,
            fieldContext: fieldContext,
            cleanupLevel: cleanupLevel,
            personalityStyle: personalityStyle
        )
        #else
        return await polish(parakeet, context: context, timeoutMs: timeoutMs,
                            suspectWords: suspectWords, userVocabulary: userVocabulary,
                            fieldContext: fieldContext,
                            cleanupLevel: cleanupLevel, personalityStyle: personalityStyle)
        #endif
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private func mergeWithMLX(
        parakeet: String,
        granite: String?,
        moonshine: String?,
        context: PolishContext,
        timeoutMs: Int,
        suspectWords: [String]?,
        userVocabulary: [String]?,
        fieldContext: String?,
        cleanupLevel: String = "medium",
        personalityStyle: String = "neutral"
    ) async -> String {
        // Route merge to the same model the single-polish path would have used.
        // Otherwise a triple-transcript High-mode dump on a long input always
        // lands on the 1.7B and ships rule-only-looking output — exactly the
        // "didn't run, it was just parakeet" failure mode.
        let parakeetWordCount = parakeet.split(separator: " ").count
        let parakeetLower = parakeet.lowercased()
        let mergeTopicShiftMarkers = ["also", "and then", "oh and", "then go", "and message",
                                       "next thing", "next up", "and finally", "and also"]
        let mergeTopicHits = mergeTopicShiftMarkers.reduce(0) { acc, marker in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return acc }
            return acc + rx.numberOfMatches(in: parakeetLower, range: NSRange(parakeetLower.startIndex..., in: parakeetLower))
        }
        let mergeIsMultiTopic = mergeTopicHits >= 3
        let mergeSchemaPattern = #"(?i)\b(?:make|create|build|define)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:table|schema|struct|object|model|class|record|type|interface)\b"#
        let mergeHasSchemaSignal = parakeet.range(of: mergeSchemaPattern, options: .regularExpression) != nil
        let mergeIsLongHigh = (cleanupLevel.lowercased() == "high") && parakeetWordCount > 40
        let mergeNeedsLarge = parakeetWordCount > 12 || mergeIsMultiTopic || mergeHasSchemaSignal || mergeIsLongHigh
        var mergeUsedLarge = false
        let container: ModelContainer
        if mergeNeedsLarge {
            do {
                container = try await ensureLargeModel()
                mergeUsedLarge = true
            } catch {
                print("[VOICE-LP] merge: 4B not ready, falling back to 1.7B (\(error.localizedDescription))")
                do {
                    container = try await ensureModel()
                } catch {
                    return parakeet
                }
            }
        } else {
            do {
                container = try await ensureModel()
            } catch {
                return parakeet
            }
        }
        print("[VOICE-LP] merge route=\(mergeUsedLarge ? "4B" : "1.7B") words=\(parakeetWordCount) multiTopic=\(mergeIsMultiTopic) schema=\(mergeHasSchemaSignal) longHigh=\(mergeIsLongHigh)")

        // Build hints (same as single-model polish).
        var hints = ""
        if let fc = fieldContext {
            // Section C: prompt-injection hardening on every untrusted field.
            let s = Self.sanitizeUntrustedField(fc, maxChars: 200)
            hints += "Text field already ends with: \"\(s)\". Your output will be appended directly after this, include a leading space if one is needed. If the existing text ends with whitespace or a newline, do NOT add another. If it ends mid-sentence (a word, comma), lowercase your first word and add a leading space.\n"
        }
        if let priorCtx = currentRollingContext {
            let s = Self.sanitizeUntrustedField(priorCtx, maxChars: 400)
            hints += "Prior dictation in this session (DO NOT OUTPUT, use only to resolve ambiguity): \"\(s)\"\n"
        }
        hints += Self.buildSuspectHints(suspectWords ?? [], userVocabulary: userVocabulary)
        if let vocab = userVocabulary, !vocab.isEmpty {
            let prioritized = Self.prioritizeVocabulary(vocab, suspects: suspectWords)
            let s = prioritized.prefix(60)
                .map { Self.sanitizeUntrustedField($0, maxChars: 80) }
                .joined(separator: ", ")
            hints += "Custom vocabulary: [\(s)].\n"
        }
        // Bug 2: Inject known product names so the model preserves them verbatim
        // instead of "correcting" them into homophone garbage.
        hints += "Known product names (preserve EXACTLY as written, do not 'correct' them): \(Self.knownProductNames.joined(separator: ", ")).\n"

        // Use parakeet as the word-count baseline for the sanitizer.
        // List formatting requires more tokens — give extra room when list
        // markers are present in any of the transcripts. HIGH cleanup gets
        // 3x headroom (vs 2x) so aggressive restructuring isn't truncated.
        // Section E: same profile-tightened budget as the single-model polish.
        // 2× input + 60 buffer for medium/light; 3× + 80 for HIGH (aggressive
        // restructuring) and list hints. Mirrors polishWithMLX budget logic.
        let approxTokens = max(8, parakeet.count / 3)
        let mergeHasListHint = [parakeet, granite ?? "", moonshine ?? ""].joined(separator: " ")
            .range(of: #"(?i)\b(first|second|third|point\s+one|point\s+two|number\s+one|step\s+one|action\s+items?)\b"#, options: .regularExpression) != nil
        // Mirror polishWithMLX: HIGH gets 3× for aggressive restructuring headroom.
        // List hint gets 80 to cover "1.\n2.\n3." prefix overhead.
        let mergeCleanupMultiplier: Int = (cleanupLevel.lowercased() == "high") ? 3 : 2
        let cap = approxTokens * mergeCleanupMultiplier + (mergeHasListHint ? 80 : 60)
        let params = GenerateParameters(temperature: 0.0, topP: 1.0).with(maxTokens: cap)

        // Build transcript lines — always include A (Parakeet), include B and C when available.
        var transcriptLines = "Transcript A (Parakeet v2): \(parakeet)"
        if let g = granite { transcriptLines += "\nTranscript B (Granite 4.0): \(g)" }
        if let m = moonshine { transcriptLines += "\nTranscript C (Moonshine Tiny): \(m)" }

        // Section F (merge correctness): when two transcripts overlap and
        // disagree on a span, the LLM is told to prefer the higher-confidence
        // span. Rationale: segment-level confidence (now aggregated from
        // per-token confidences in TranscriptionService) gives us a real
        // signal of which transcriber was less sure on a given span. Doing
        // strict string-equality merging discards that information and lets
        // a confidently-wrong transcript outweigh a hesitantly-right one.
        // The merge runs on the raw transcript strings here; per-span
        // confidence isn't plumbed to this layer, so we surface it via prompt
        // guidance instead (the underlying TranscriptSegment already carries
        // the aggregated confidence for downstream consumers).
        let hasAllThree = granite != nil && moonshine != nil
        let mergeInstruction: String
        if hasAllThree {
            mergeInstruction = "You have three ASR transcripts of the same spoken audio. They may differ in word choice, proper nouns, numbers, and punctuation. Produce a single best merged transcript: pick the more accurate reading from each, fix any remaining ASR errors, and apply all standard polish rules (capitalization, punctuation, homophones, acronyms, etc.). Where transcripts disagree on a span, prefer the reading that looks higher-confidence (proper nouns spelled coherently, no broken sub-word fragments, no character-class soup) rather than blindly trusting majority vote. If C (Moonshine) is nil, use only A and B. Output ONLY the final text."
        } else {
            mergeInstruction = "You have two ASR transcripts of the same spoken audio. They may differ in word choice, proper nouns, numbers, and punctuation. Produce a single best merged transcript: pick the more accurate reading from each, fix any remaining ASR errors, and apply all standard polish rules (capitalization, punctuation, homophones, acronyms, etc.). Where transcripts disagree on a span, prefer the reading that looks higher-confidence (proper nouns spelled coherently, no broken sub-word fragments, no character-class soup) rather than blindly trusting one source. Output ONLY the final text."
        }

        // Bug 3 + Bug 4: same shared helpers as the single-model polish path.
        // Keeps merge behavior consistent with polish() so user-facing
        // personality/cleanup pickers actually take effect in both call paths.
        let mergeLevelPrefix = """
        === OVERRIDE: CLEANUP MODE (highest priority, overrides any conflicting system rule) ===
        \(Self.cleanupInstruction(cleanupLevel))
        ===

        """

        let mergePersonalityHint = """
        === OVERRIDE: PERSONALITY (highest priority, overrides "preserve register" / "keep slang" rules) ===
        \(Self.personalityInstruction(personalityStyle))
        ===

        """

        // Structural-output hint (same as polish path) — long, complex
        // dictations should be allowed to produce lists, paragraphs, inline
        // code, and quoted message blocks.
        var mergeStructureHint = """
        Use bullets when the speaker enumerates 3+ short items (each 1-4 words) following a cue phrase like "I need", "I have to get", "I want", "make a list", "the list is", "things to do", "grocery list", or a colon. Example: "I have to get monster energy, sea salt spray, curry, and a phone" → bullet list with 4 items. Items in lists should each be a single short noun phrase. For 2 or fewer items, keep as inline prose.
        PARAGRAPH BREAKS (important): If the output is longer than ~50 words, split into 2+ paragraphs at natural topic boundaries. Use a BLANK LINE (\n\n) between paragraphs. Topic boundary signals: change of subject, switch from describing to listing, switch from question to answer, "also", "anyway", "by the way", "okay so", "moving on", "let's say", "speaking of", or any moment the speaker pivots. Default to MORE breaks rather than fewer — a wall of text is the wrong output.
        If it mentions snake_case field names, code identifiers, URLs, file paths, passwords, or version numbers, wrap them in backticks.
        If it dictates a message to someone (e.g., "send Alex running late" or "text Mia saying..."), output the message body in quotation marks. Any qualifying instruction ("except maybe less formal") goes OUTSIDE the quote on its own line in parentheses.
        Email addresses, serial numbers, and tracking numbers MUST be in backticks: `admin-temp@northgate-help.net`, `A9-Q2-7B-44`, `Q479B662`.
        TOPIC ISOLATION: "except/unless/but not" clauses stay in the SAME paragraph as what they qualify. Never start a new paragraph for a trailing qualifier.

        """
        if mergeIsMultiTopic {
            mergeStructureHint += """
            MULTI-TOPIC: If the dictation covers 3+ independent topics signaled by "also", "and then", "oh and", separate them with a BLANK LINE between paragraphs. Do NOT use numbered lists or bullet points unless the speaker is enumerating discrete items (like a list of fields, a list of comments to save, a list of names). Use bullets ONLY for genuine list content.

            GENUINE LIST signals (use bullets):
            - Schema/struct fields explicitly enumerated: "fields should be X, Y, Z"
            - Explicit save/filter criteria: "save the comments about A, B, C"
            - Speaker says "the list is..." or "bullet point X, bullet point Y"
            - Shopping/grocery/to-do enumeration with 3+ short items: "I need monster energy, sea salt spray, curry, and a phone" → bullet list with 4 items, each on its own line
            - Cue phrases: "I have to get", "I need", "things to do", "make a list", "grocery list"

            NOT GENUINE LIST (use prose):
            - 2 or fewer items: "I need milk and eggs" → stays prose
            - Long items (5+ words each) — keep as prose flow
            - Multiple unrelated topics (use paragraph breaks, not bullets)
            - Self-corrections, sub-clauses, asides
            - Causal explanations ("because X, then Y")

            """
        }
        if mergeHasSchemaSignal {
            mergeStructureHint += """
            SCHEMA: The speaker is dictating a database table or struct. Convert spoken field names to snake_case wrapped in backticks. ≤8 fields → inline comma-separated after a colon. ≥9 fields → bullet list. Any "except/unless/where" caveat stays as prose. "X underscore Y" → `x_y`. SHORT EXAMPLE: "create users table user id email password hash created at" → "Create users table: `user_id`, `email`, `password_hash`, `created_at`".

            """
        }

        let prompt = """
        /no_think
        \(mergeLevelPrefix)\(mergePersonalityHint)\(hints)\(mergeStructureHint)Context: \(context.rawValue)
        \(mergeInstruction)

        \(transcriptLines)
        Output:
        """

        let session = ChatSession(container, instructions: Self.systemInstructions, generateParameters: params)
        let start = Date()

        // Adaptive timeout — same logic as polishWithMLX.
        let mergeBaseTimeout: Int
        if mergeUsedLarge {
            mergeBaseTimeout = max(timeoutMs, 3000 + parakeetWordCount * 60)
        } else {
            mergeBaseTimeout = timeoutMs
        }
        let mergeEffectiveTimeout = min(mergeBaseTimeout, 30000)
        print("[VOICE-LP] merge timeout=\(mergeEffectiveTimeout)ms (caller=\(timeoutMs)ms, route=\(mergeUsedLarge ? "4B" : "1.7B"), words=\(parakeetWordCount))")

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("[VOICE] Qwen3 merge (\(ms)ms): \(response.prefix(120))")
                    await MainActor.run { Qwen3Polisher.shared.recordLatency(ms) }
                    let sanitized = Self.sanitize(response, original: parakeet, vocabulary: userVocabulary, suspectWords: suspectWords, cleanupLevel: cleanupLevel)
                    // Bug 1b: post-sanitize em-dash/en-dash scrub.
                    let cleaned = Self.stripDashes(sanitized)
                    if cleaned != sanitized {
                        print("[VOICE-POLISH] dash-strip applied")
                    }
                    return cleaned
                } catch {
                    print("[VOICE] Qwen3 merge error: \(error)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(mergeEffectiveTimeout) * 1_000_000)
                print("[VOICE-LP] merge timeout at \(mergeEffectiveTimeout)ms — returning rule-only output")
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? parakeet
            }
            return parakeet
        }
    }
    #endif

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
        userVocabulary: [String]? = nil,
        fieldContext: String? = nil,
        cleanupLevel: String = "medium",
        personalityStyle: String = "neutral"
    ) async -> String {
        // "none" cleanup: skip the model entirely, just strip fillers.
        if cleanupLevel == "none" {
            return LLMPolisher.stripFillers(text)
        }

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
        let filtered = LLMPolisher.stripFillers(text)

        // Step 1b: Restart-correction pre-processor (rule-based, <1ms).
        // Resolves stutters, explicit "no wait" corrections, and near-duplicate
        // clause restarts BEFORE the LLM sees the text. The 4B model has been
        // observed to keep both versions of a restart in long inputs; doing this
        // deterministically in Swift is more reliable than asking the model.
        let preResult = RestartCorrectionPreprocessor.process(filtered)
        let stripped = preResult.cleaned
        if !preResult.appliedRules.isEmpty {
            print("[VOICE-PRE] restart-correction applied: \(preResult.appliedRules.joined(separator: ",")), dropped \(preResult.droppedSpans.count) spans")
        }

        // Step 2: Skip model if text is in a non-English language (Qwen3 is
        // English-trained and rewrites Dutch/French/German/Spanish/Italian/
        // Portuguese into English-shaped slop). English is the default for
        // ambiguous short utterances.
        if Self.isNonEnglish(stripped) {
            print("[VOICE] Qwen3 polish skipped: non-English detected")
            return Self.applyPostprocessor(stripped, userVocabulary: userVocabulary)
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

        // Step 2b: Freeze fragile spans (emails, URLs, contractions, code,
        // domains) behind sentinel tokens BEFORE the model sees them. The
        // model polishes the surrounding prose but cannot accidentally split
        // "michael@gmail.com" → "michael@gmail. Com" or mangle "let's say"
        // → "let'say". Sentinels look like ⟦E0⟧ ⟦E1⟧ etc — mathematical
        // white square brackets, opaque to Qwen3's tokenizer.
        let frozen = EntityFreezer.freeze(stripped)
        if !frozen.isEmpty {
            print("[VOICE-FREEZE] froze \(frozen.entities.count) entities")
        }

        // Step 2c: Decide between local 4B and Cerebras cloud. Cloud only
        // fires when the user has opted in AND the input is long enough to
        // benefit (short messages don't need a 70B). Cerebras failure falls
        // back to local — never blocks polish.
        let wordCount = frozen.text.split(separator: " ").count
        let useCloud = CerebrasPolisher.isAvailable && wordCount >= CerebrasPolisher.minWordCount

        var polishedFrozen: String?
        if useCloud {
            print("[VOICE-POLISH] routing to Cerebras (wordCount=\(wordCount))")
            // Use the same soundex-prioritized vocab the local path uses, so
            // the top 60 sent to the cloud are phonetically related to suspect
            // tokens. Keeps the prompt budget sane while maximizing relevance.
            let prioritizedVocab = userVocabulary.map {
                Self.prioritizeVocabulary($0, suspects: suspectWords)
            }
            let cloudPrompt = Self.buildCloudSystemPrompt(
                cleanupLevel: cleanupLevel,
                personalityStyle: personalityStyle,
                userVocabulary: prioritizedVocab
            )
            polishedFrozen = await CerebrasPolisher.shared.polish(
                frozen.text,
                systemPrompt: cloudPrompt
            )
            if polishedFrozen == nil {
                let reason = await CerebrasPolisher.shared.lastFailureReason ?? "unknown"
                print("[VOICE-POLISH] Cerebras failed (\(reason)), falling back to local")
                await MainActor.run { Self.maybePostCloudFallbackToast(reason: reason) }
            } else {
                await MainActor.run { PolishStatus.shared.lastEngine = "cloud:qwen-3-235b" }
            }
        }

        if polishedFrozen == nil {
            polishedFrozen = await polishWithMLX(
                frozen.text,
                context: context,
                timeoutMs: timeoutMs,
                suspectWords: suspectWords,
                userVocabulary: userVocabulary,
                fieldContext: fieldContext,
                cleanupLevel: cleanupLevel,
                personalityStyle: personalityStyle
            )
            // Tag engine label based on routing the local path actually took.
            let usedLarge = wordCount > 20 && self.isLargeModelReady
            await MainActor.run {
                PolishStatus.shared.lastEngine = usedLarge ? "local:qwen3-4b" : "local:qwen3-1.7b"
            }
        }
        let polishedFrozenFinal = polishedFrozen ?? frozen.text

        // Hallucination guard: if the model lost or invented frozen
        // sentinels, fall back to the raw frozen input rather than ship
        // garbage. Same safety the critic provided, deterministic.
        let inputSentinels = countSentinels(in: frozen.text)
        let outputSentinels = countSentinels(in: polishedFrozenFinal)
        let safePolished: String = (inputSentinels == outputSentinels) ? polishedFrozenFinal : {
            print("[VOICE-GUARD] sentinel mismatch: in=\(inputSentinels) out=\(outputSentinels), falling back")
            return frozen.text
        }()

        // Unfreeze BEFORE postprocessor so its rules see real text again.
        let polished = EntityFreezer.unfreeze(safePolished, entities: frozen.entities)

        // Step N: Post-processor (rule-based, <1ms). Enforces capitalization,
        // hyphenates known compounds, trims trailing cutoff periods. Runs
        // even on fail-open paths to keep the output consistent.
        return Self.applyPostprocessor(polished, userVocabulary: userVocabulary)
        #else
        return Self.applyPostprocessor(stripped, userVocabulary: userVocabulary)
        #endif
    }

    /// Apply the deterministic post-processor with the current user
    /// vocabulary as proper-noun safelist. Centralizes the call so every
    /// return path goes through the same cleanup.
    nonisolated static func applyPostprocessor(_ text: String, userVocabulary: [String]?) -> String {
        let userNouns: Set<String> = Set((userVocabulary ?? []).map { $0.lowercased() })
        let options = PolishPostprocessor.Options(userProperNouns: userNouns)
        let result = PolishPostprocessor.process(text, options: options)
        if !result.changes.isEmpty {
            let ruleNames = result.changes.map { $0.rule }.joined(separator: ",")
            print("[VOICE-POST] post-processor applied: \(ruleNames)")
        }
        return result.cleaned
    }

    /// Count ⟦E…⟧ sentinels in a string. Used by the hallucination guard
    /// to verify the LLM preserved all frozen entities (and didn't invent any).
    private nonisolated func countSentinels(in s: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"⟦E\d+⟧"#) else { return 0 }
        let ns = s as NSString
        return regex.numberOfMatches(in: s, range: NSRange(location: 0, length: ns.length))
    }

    /// Throttle for the cloud-fallback toast — at most one toast every 30s.
    @MainActor private static var lastCloudFallbackToastAt: Date?

    @MainActor
    fileprivate static func maybePostCloudFallbackToast(reason: String) {
        let now = Date()
        if let last = lastCloudFallbackToastAt, now.timeIntervalSince(last) < 30 {
            return
        }
        lastCloudFallbackToastAt = now
        NotificationCenter.default.post(
            name: .voiceCloudFellBackToLocal,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    /// System prompt for the Cerebras cloud path. Uses the same comprehensive
    /// `systemInstructions` as the local model — Qwen 235B is from the same
    /// family as our local Qwen3-4B, so the same rule format applies, and
    /// the bigger model can fully leverage all the rules + few-shot examples
    /// without getting confused by them.
    nonisolated static func buildCloudSystemPrompt(
        cleanupLevel: String,
        personalityStyle: String,
        userVocabulary: [String]?
    ) -> String {
        // Full base instructions — same as local. Same rules, same examples.
        var prompt = systemInstructions

        // Per-call OVERRIDE block: cleanup level + personality.
        prompt += "\n\n=== OVERRIDE: CLEANUP MODE (highest priority) ===\n"
        prompt += Self.cleanupInstruction(cleanupLevel)

        prompt += "\n\n=== OVERRIDE: PERSONALITY (highest priority) ===\n"
        prompt += Self.personalityInstruction(personalityStyle)

        // Known proper nouns (preserve casing). Top 60 prioritized terms.
        if let vocab = userVocabulary, !vocab.isEmpty {
            let top = vocab.prefix(60).joined(separator: ", ")
            prompt += "\n\nKnown proper nouns (preserve EXACTLY as written, do not 'correct' them): \(top)."
        }
        // Bundled product names (always-on safelist).
        prompt += "\n\nAlso preserve these product names verbatim: \(Self.knownProductNames.joined(separator: ", "))."

        return prompt
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private func polishWithMLX(
        _ text: String,
        context: PolishContext,
        timeoutMs: Int,
        suspectWords: [String]? = nil,
        userVocabulary: [String]? = nil,
        fieldContext: String? = nil,
        cleanupLevel: String = "medium",
        personalityStyle: String = "neutral"
    ) async -> String {
        // Route between the 1.7B fast path and the 4B prose-quality path
        // BEFORE fetching a container. Routing rule:
        //   - >20 words, OR
        //   - blank-line paragraph break ("\n\n"), OR
        //   - bullet-list marker ("\n- "), OR
        //   - backtick (code identifier), OR
        //   - block-quote-style "\"" content
        // ...triggers the 4B model. If the 4B hasn't finished loading yet
        // (background download still in flight), gracefully fall back to the
        // 1.7B so polish never blocks on the larger model.
        let cleanedInput = text
        let wordCount = cleanedInput.split(separator: " ").count

        // Short-utterance fast-path: under 4 words, the LLM truly can't help
        // (and is more likely to mess it up than improve it). Above that,
        // even short utterances get polished — "hey can u send maya a msg"
        // should become "Hey, can you send Maya a message" instead of just
        // the rule-based capitalization.
        // BUGFIX: threshold raised from 4 to 6 words. Ultra-short messages (3-5 words)
        // like "github slash repo slash readme" need LLM polish to convert "slash"→"/".
        // The old 4-word floor was causing "slash" to stay literal in command-like
        // short utterances. 6 words still skips polish for truly trivial messages
        // ("ok" / "yeah" / "got it") while capturing path/URL commands.
        if wordCount < 6 {
            print("[VOICE-LP] ultra-short fast-path, skipping LLM (wordCount=\(wordCount))")
            let formatted = TextFormatter().format(cleanedInput)
            return formatted
        }

        // Benchmark (2026-05): 4B at 40 words = 0.68s (imperceptible), 1.7B at
        // >12 words starts emitting verbatim passthrough or losing entities.
        // Threshold of 12 trades ~300ms of latency for a substantial quality
        // jump on the meat of typical dictation lengths.
        //
        // Multi-topic detection: 3+ topic-shift markers signals a long dump
        // that needs bullet-list restructuring. Schema dictation ("make X
        // table id, name, status") needs backtick-wrapped snake_case output.
        // Both force-route to 4B regardless of word count.
        let lowerInput = cleanedInput.lowercased()
        let topicShiftMarkers = ["also", "and then", "oh and", "then go", "and message",
                                  "next thing", "next up", "and finally", "and also"]
        let topicShiftHits = topicShiftMarkers.reduce(0) { acc, marker in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return acc }
            return acc + rx.numberOfMatches(in: lowerInput, range: NSRange(lowerInput.startIndex..., in: lowerInput))
        }
        let isMultiTopic = topicShiftHits >= 3
        // Schema dictation: "make/create [a] {table|schema|struct|object|model} X
        //                    [with] field1 field2 field3..."
        let schemaPattern = #"(?i)\b(?:make|create|build|define)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:table|schema|struct|object|model|class|record|type|interface)\b"#
        let hasSchemaSignal = cleanedInput.range(of: schemaPattern, options: .regularExpression) != nil
        // High cleanup + >40 words: force 4B (the 1.7B can't restructure long ramble).
        let isLongHigh = (cleanupLevel.lowercased() == "high") && wordCount > 40

        let needsLarge = wordCount > 12
            || cleanedInput.contains("\n\n")
            || cleanedInput.contains("\n- ")
            || cleanedInput.contains("`")
            || cleanedInput.contains("\"")
            || isMultiTopic
            || hasSchemaSignal
            || isLongHigh
        var usedLarge = false
        let container: ModelContainer
        if needsLarge {
            do {
                container = try await ensureLargeModel()
                usedLarge = true
            } catch {
                print("[VOICE-LP] 4B not ready, falling back to 1.7B (\(error.localizedDescription))")
                do {
                    container = try await ensureModel()
                } catch {
                    print("[VOICE] Qwen3 polish: model unavailable (\(error.localizedDescription))")
                    return text
                }
            }
        } else {
            do {
                container = try await ensureModel()
            } catch {
                print("[VOICE] Qwen3 polish: model unavailable (\(error.localizedDescription))")
                return text
            }
        }
        print("[VOICE-LP] route=\(usedLarge ? "4B" : "1.7B") words=\(wordCount) multiTopic=\(isMultiTopic) schema=\(hasSchemaSignal) longHigh=\(isLongHigh)")

        // Cap max tokens at roughly 2x input + a small buffer. Polish is by
        // definition same-length — leaving more room lets a runaway model
        // hang us until timeout fires.
        // List formatting requires more tokens: "1. Item\n2. Item\n3. Item"
        // is longer than raw prose. Detect list markers and give extra room.
        // HIGH cleanup may aggressively restructure long ramble into bullets,
        // paragraph breaks, and quoted-message blocks — give it 3x headroom
        // plus a generous static buffer so it doesn't get truncated mid-list.
        // Section E: profile-tightened token budget. Polish output is rarely
        // 3× input length — even High-cleanup structural rewrites tend to
        // SHORTEN. 2× headroom + 60 token buffer covers list/paragraph
        // expansion without giving a runaway model room to hang us until
        // timeout. Previous 3× + 120 was a safety margin we never used.
        let approxInputTokens = max(8, text.count / 3)
        let hasListHint = text.range(of: #"(?i)\b(first|second|third|point\s+one|point\s+two|number\s+one|step\s+one|action\s+items?)\b"#, options: .regularExpression) != nil
        // HIGH gets 3× to avoid truncating aggressive restructuring (bullet lists,
        // multi-paragraph rewrites). Medium/light stay at 2×. List-hint adds 80
        // tokens instead of 60 — "1.\n2.\n3." prefixes are more expensive than raw prose.
        let cleanupMultiplier: Int = (cleanupLevel.lowercased() == "high") ? 3 : 2
        let cap = approxInputTokens * cleanupMultiplier + (hasListHint ? 80 : 60)
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
        // Field-context: the characters immediately before the cursor in the
        // user's target text field. The model uses this to decide:
        //   - whether to prefix with " " (mid-sentence) or "" (empty / after space / after newline)
        //   - whether to lowercase the first word (continuing a sentence)
        //   - whether to keep a trailing period (sentence end) or strip it (chat / list item)
        //   - whether the user is continuing an enumerated list and should pick up at "3."
        // The output is APPENDED VERBATIM after this context — no further spacing
        // adjustment downstream. So if a leading space is needed, include it.
        if let fc = fieldContext {
            // Section C: prompt-injection hardening — strip control sequences,
            // collapse newlines, cap length.
            let sanitized = Self.sanitizeUntrustedField(fc, maxChars: 200)
            hints += "Text field already ends with: \"\(sanitized)\". Your output will be appended directly after this, include a leading space if one is needed. If the existing text ends with whitespace or a newline, do NOT add another. If it ends mid-sentence (a word, comma), lowercase your first word and add a leading space.\n"
        }
        if let priorCtx = currentRollingContext {
            let sanitized = Self.sanitizeUntrustedField(priorCtx, maxChars: 400)
            hints += "Prior dictation in this session (DO NOT OUTPUT, use only to resolve ambiguity): \"\(sanitized)\"\n"
        }
        // Section D: token-optimal confidence feeding — phonetic alternatives
        // for every low-confidence ASR token. Shared with the merge path via
        // buildSuspectHints() so both paths emit the same ?word→[alt1, alt2]
        // format. Capped at 8 suspects per call.
        hints += Self.buildSuspectHints(suspectWords ?? [], userVocabulary: userVocabulary)
        if let userVocabulary, !userVocabulary.isEmpty {
            // Prioritize vocabulary terms that share letters/sounds with suspect words,
            // so the most relevant canonical spellings come first when the prompt is truncated.
            let prioritized = Self.prioritizeVocabulary(userVocabulary, suspects: suspectWords)
            // SECURITY (Section C): sanitize every vocabulary term to block
            // prompt injection via custom-vocabulary entries the user pasted in.
            let sanitized = prioritized.prefix(60)
                .map { Self.sanitizeUntrustedField($0, maxChars: 80) }
            let joined = sanitized.joined(separator: ", ")
            hints += "Custom vocabulary (canonical spellings, replace phonetically-similar garbled text with these): [\(joined)].\n"
            hints += "Phonetic-match rule: if a multi-word sequence SOUNDS like one of these terms, collapse it. Examples: 'Chachi Pt' to 'ChatGPT', 'Chatchi Petey' to 'ChatGPT', 'antrop pick' to 'Anthropic', 'antropic' to 'Anthropic', 'clore' to 'Claude', 'clod' to 'Claude', 'open A I' to 'OpenAI', 'C E O' to 'CEO', 'A P I' to 'API'. Word count MAY decrease when collapsing spelled-out or garbled forms, this is correct.\n"
        }
        // Bug 2: Inject known product names so the model preserves them verbatim
        // instead of "correcting" them into homophone garbage.
        hints += "Known product names (preserve EXACTLY as written, do not 'correct' them): \(Self.knownProductNames.joined(separator: ", ")).\n"

        // Bug 4: cleanup-mode instruction. Use the shared helper so polish
        // and merge stay in lockstep, and the HIGH branch is unmistakably
        // aggressive.
        let levelPrefix = """
        === OVERRIDE: CLEANUP MODE (highest priority, overrides any conflicting system rule) ===
        \(Self.cleanupInstruction(cleanupLevel))
        ===

        """

        // Bug 3: personality instruction. Single source of truth via helper;
        // dramatic per-style differences so a 1.7B can follow them.
        let personalityHint = """
        === OVERRIDE: PERSONALITY (highest priority, overrides "preserve register" / "keep slang" rules) ===
        \(Self.personalityInstruction(personalityStyle))
        ===

        """

        // Structural-output hint: teach the model to recognize patterns
        // that should produce lists, paragraph breaks, inline code, and
        // quoted message blocks. Applied per-call so it's always in scope
        // for long/complex dictations.
        var structureHint = """
        Use bullets when the speaker enumerates 3+ short items (each 1-4 words) following a cue phrase like "I need", "I have to get", "I want", "make a list", "the list is", "things to do", "grocery list", or a colon. Example: "I have to get monster energy, sea salt spray, curry, and a phone" → bullet list with 4 items. Items in lists should each be a single short noun phrase. For 2 or fewer items, keep as inline prose.
        PARAGRAPH BREAKS (important): If the output is longer than ~50 words, split into 2+ paragraphs at natural topic boundaries. Use a BLANK LINE (\n\n) between paragraphs. Topic boundary signals: change of subject, switch from describing to listing, switch from question to answer, "also", "anyway", "by the way", "okay so", "moving on", "let's say", "speaking of", or any moment the speaker pivots. Default to MORE breaks rather than fewer — a wall of text is the wrong output.
        If it mentions snake_case field names, code identifiers, URLs, file paths, passwords, or version numbers, wrap them in backticks.
        If it dictates a message to someone (e.g., "send Alex running late" or "text Mia saying..."), output the message body in quotation marks. Any qualifying instruction ("except maybe less formal") goes OUTSIDE the quote on its own line in parentheses.
        Email addresses, serial numbers, and tracking numbers MUST be in backticks: `admin-temp@northgate-help.net`, `A9-Q2-7B-44`, `Q479B662`.
        TOPIC ISOLATION: "except/unless/but not" clauses stay in the SAME paragraph as what they qualify. Never start a new paragraph for a trailing qualifier.

        """
        if isMultiTopic {
            structureHint += """
            MULTI-TOPIC: If the dictation covers 3+ independent topics signaled by "also", "and then", "oh and", separate them with a BLANK LINE between paragraphs. Do NOT use numbered lists or bullet points unless the speaker is enumerating discrete items (like a list of fields, a list of comments to save, a list of names). Use bullets ONLY for genuine list content.

            GENUINE LIST signals (use bullets):
            - Schema/struct fields explicitly enumerated: "fields should be X, Y, Z"
            - Explicit save/filter criteria: "save the comments about A, B, C"
            - Speaker says "the list is..." or "bullet point X, bullet point Y"
            - Shopping/grocery/to-do enumeration with 3+ short items: "I need monster energy, sea salt spray, curry, and a phone" → bullet list with 4 items, each on its own line
            - Cue phrases: "I have to get", "I need", "things to do", "make a list", "grocery list"

            NOT GENUINE LIST (use prose):
            - 2 or fewer items: "I need milk and eggs" → stays prose
            - Long items (5+ words each) — keep as prose flow
            - Multiple unrelated topics (use paragraph breaks, not bullets)
            - Self-corrections, sub-clauses, asides
            - Causal explanations ("because X, then Y")

            """
        }
        if hasSchemaSignal {
            structureHint += """
            SCHEMA: The speaker is dictating a database table or struct definition. Convert spoken field names to snake_case wrapped in backticks. Format rules:
            - 8 or fewer fields → INLINE comma-separated list after a colon. Space-separated words → snake_case: "user id" → `user_id`, "created at" → `created_at`, "last login at" → `last_login_at`.
            - 9 or more fields → BULLET LIST, one field per line.
            - Any "except/unless/where" caveat stays as prose (not a bullet).
            - "X underscore Y" \u{2192} `x_y` (spoken underscore → snake_case separator).
            SHORT LIST EXAMPLE (≤8 fields, inline):
            "create users table user id email password hash created at updated at last login at where deleted is null"
            \u{2192}
            Create users table: `user_id`, `email`, `password_hash`, `created_at`, `updated_at`, `last_login_at` where `deleted` is null.
            LONG LIST EXAMPLE (9+ fields, bullets):
            "make invoices table invoice underscore id customer underscore id subtotal tax total paid underscore at status except refunded invoices keep original totals"
            \u{2192}
            Make table `invoices`. Fields:
            - `invoice_id`
            - `customer_id`
            - `subtotal`
            - `tax`
            - `total`
            - `paid_at`
            - `status`

            Refunded invoices keep original totals for reporting.

            """
        }

        // BUGFIX (Category 7 — prompt construction): order matters for Qwen3.
        // `/no_think` MUST be on line 1, THEN the OVERRIDE blocks, THEN the
        // hints block, THEN context, THEN input, THEN Output marker. Block
        // boundaries are preserved via trailing blank lines in each prefix.
        let prompt = """
        /no_think
        \(levelPrefix)\(personalityHint)\(hints)\(structureHint)Context: \(context.rawValue)
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

        // Adaptive timeout. The default 2500ms is fine for short 1.7B polish
        // but starves long 4B runs (250+ word multi-topic dump on High mode
        // takes 5-10s). Scale by route + input size so the polish actually
        // has time to finish rather than silently falling back to rule-only.
        let baseTimeout: Int
        if usedLarge {
            // 4B: ~30ms/word steady-state + 1s warmup overhead.
            baseTimeout = max(timeoutMs, 3000 + wordCount * 60)
        } else {
            baseTimeout = timeoutMs
        }
        let effectiveTimeout = min(baseTimeout, 30000)  // hard cap 30s
        print("[VOICE-LP] timeout=\(effectiveTimeout)ms (caller=\(timeoutMs)ms, route=\(usedLarge ? "4B" : "1.7B"), words=\(wordCount))")

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("[VOICE] Qwen3 raw response (\(ms)ms): \(response.prefix(200))")
                    await MainActor.run { Qwen3Polisher.shared.recordLatency(ms) }
                    let sanitized = Self.sanitize(response, original: text, vocabulary: userVocabulary, suspectWords: suspectWords, cleanupLevel: cleanupLevel)
                    // Bug 1b: post-sanitize em-dash/en-dash scrub. The user HATES em-dashes;
                    // strip any that survive the model + sanitize passes.
                    let cleaned = Self.stripDashes(sanitized)
                    if cleaned != sanitized {
                        print("[VOICE-POLISH] dash-strip applied")
                    }
                    print("[VOICE] Qwen3 polish DONE in \(ms)ms, output=\(cleaned.prefix(120))")
                    return cleaned
                } catch {
                    print("[VOICE] Qwen3 polish error: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000)
                print("[VOICE-LP] polish timeout at \(effectiveTimeout)ms — returning rule-only output")
                return nil
            }
            // On the first-ever polish call, if inference hasn't returned within
            // 1000ms the Metal JIT warmup is still in progress. Post a one-shot
            // toast so the user knows the paste is coming — not that the app is
            // stuck. This is fire-and-forget (detached) so it CANNOT short-
            // circuit the task group's first-result-wins logic. It self-cancels
            // once the polish task completes via `warmupNotifier`.
            let warmupNotifier: Task<Void, Never>?
            if isFirstCall {
                warmupNotifier = Task.detached {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    print("[VOICE] Qwen3 first-polish warmup >1000ms — posting user notification")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .voiceError,
                            object: nil,
                            userInfo: ["message": "Polisher warming up, paste coming in a moment…"]
                        )
                    }
                }
            } else {
                warmupNotifier = nil
            }
            for await result in group {
                group.cancelAll()
                warmupNotifier?.cancel()
                if isFirstCall {
                    await MainActor.run { Qwen3Polisher.shared.hasWarmedUp = true }
                }
                return result ?? text
            }
            warmupNotifier?.cancel()
            return text
        }
    }
    #endif

    // MARK: - Prompt

    /// System prompt for Qwen3 dictation polish.
    /// Comprehensive formatting rules for speech-to-text correction.
    nonisolated private static let systemInstructions: String = """
    /no_think
    You are a speech-to-text formatter. Fix ASR errors and convert spoken commands to formatted text. Output ONLY the corrected text.

    == FEW-SHOT EXAMPLES (the kind of output we want) ==
    These show the target style on hard cases. Match this register: clean prose, paragraph breaks at topic shifts, bullet lists when the speaker enumerates short items, no filler words.

    Example 1 (long rant with filler + list):
    Input: "okay so wispr flow versus voice which one is actually better i'm using a microphone which probably should already help a lot i do very much like the app but i've built it it's just not really there i hope it is there but like yeah let's say you can do my email michael at gmail dot com or make a little grocery list like i have to get monster energy sea salt spray curry and a phone"
    Output: "Wispr Flow versus Voice. Which one is actually better? I'm using a microphone, which probably should already help a lot. I do very much like the app, but I've built it; it's just not really there. I hope it is there.

    Let's say you can do my email, michael@gmail.com. Or make a little grocery list, like I have to get:
    - Monster Energy
    - sea salt spray
    - curry
    - a phone"

    Example 2 (short message, light cleanup):
    Input: "hey can u send maya a msg saying we're running a bit late"
    Output: "Hey, can you send Maya a message saying we're running a bit late?"

    Example 3 (technical with numbers + units):
    Input: "the model is around four billion parameters and inference takes like five hundred milliseconds on the laptop"
    Output: "The model is around 4B parameters and inference takes about 500ms on the laptop."

    Example 4 (correction collapse):
    Input: "remind me to buy milk no wait eggs no actually both milk and eggs no scratch that i just need bread and butter for tomorrow"
    Output: "Remind me to buy bread and butter for tomorrow."

    Example 5 (paragraph break at topic shift):
    Input: "the deploy went fine today no issues with the database migration also we should probably bump the cache TTL it's been stale on the staging environment"
    Output: "The deploy went fine today, no issues with the database migration.

    Also, we should probably bump the cache TTL. It's been stale on the staging environment."

    Example 6 (file paths and extensions):
    Input: "open the readme dot md in the project folder then save the output to downloads slash report dot pdf"
    Output: "Open the `readme.md` in the project folder, then save the output to `Downloads/report.pdf`."

    Example 7 (quotation handling):
    Input: "she said quote we're shipping on friday end quote and i told her quote okay sounds good end quote"
    Output: "She said, "We're shipping on Friday," and I told her, "Okay, sounds good.""

    Example 8 (units and measurements):
    Input: "the laptop has thirty two gigs of ram a two terabyte ssd and runs at three point five gigahertz the battery lasts about twelve hours"
    Output: "The laptop has 32 GB of RAM, a 2 TB SSD, and runs at 3.5 GHz. The battery lasts about 12h."

    Example 9 (currency and percentages):
    Input: "revenue was up twenty three percent year over year hitting forty two point eight million in q three"
    Output: "Revenue was up 23% year over year, hitting $42.8M in Q3."

    Example 10 (date and time):
    Input: "let's meet on march fifteenth at five thirty PM the deadline is march thirty first twenty twenty six"
    Output: "Let's meet on March 15 at 5:30 PM. The deadline is March 31, 2026."

    == ABSOLUTE RULE: FROZEN TOKENS (highest priority, overrides everything) ==
    Tokens of the form ⟦E0⟧ ⟦E1⟧ ⟦E2⟧ ⟦E3⟧ etc. (with mathematical white square brackets) are FROZEN. They represent emails, URLs, code, file paths, domains, and contractions that have been protected from polishing. RULES:
    1. Copy them VERBATIM to your output, character for character.
    2. Do NOT translate, split, capitalize, lowercase, punctuate, or modify them in any way.
    3. Do NOT insert a period, comma, or space INSIDE a frozen token.
    4. Treat each frozen token as a single opaque word — punctuation around it is fine, punctuation INSIDE it is forbidden.
    5. Do NOT invent new ⟦E…⟧ tokens that weren't in the input.
    These tokens will be expanded back to real content after your output is produced; if you damage them, the result is broken.

    == ABSOLUTE RULE: NO DASHES (highest priority, overrides all other formatting instructions) ==
    NEVER use em-dashes (\u{2014}), en-dashes (\u{2013}), or horizontal bars (\u{2015}/\u{2012}) in your output. UNDER ANY CIRCUMSTANCES. They are BANNED. Use a comma for an aside, a period for a sentence break, or restructure the sentence. NEVER use a dash to add dramatic emphasis. NEVER use a dash to connect clauses.

    Wrong: "I'm tired — I've been working all day."
    Right: "I'm tired. I've been working all day."

    Wrong: "The model — which I just installed — is fast."
    Right: "The model, which I just installed, is fast."

    Wrong: "$400 — before tax — then..."
    Right: "$400 (before tax), then..."

    If you find yourself reaching for an em-dash, USE A COMMA. If a comma feels weak, USE A PERIOD. The dash is never the right answer. This rule is absolute and overrides everything else.

    == NUMBER FORMATTING (US English) ==
    Use US English number conventions:
    - Comma as thousands separator: 2,300 (not 2.300)
    - Period as decimal point: 2.50 (not 2,50)
    - Currency formatting: $2,300 / €2,300 / £2,300 (NEVER €2.300 — that's European decimal style which Americans misread as 2.3)
    - "twenty three hundred euros" → "€2,300"
    - "two point five thousand" → "2,500" or "2.5K" depending on context

    == PRESERVE THE SPEAKER'S WORDS (READ FIRST, OVERRIDES EVERYTHING BELOW EXCEPT THE NO DASHES RULE) ==
    DEFAULT IS DO NOTHING. Your job is punctuation, capitalization, paragraph structure, and obvious-error fixes. NOT rewriting.

    If the input word is a real English word that fits the sentence, KEEP IT EXACTLY. Do not swap it for a synonym. Do not change tense. Do not "improve" word choice. Do not condense phrases.

    EXAMPLES OF WHAT NOT TO DO:
    - "I just had an idea" \u{2192} "I have an idea"   (WRONG. Keep "just had".)
    - "I'm gonna go" \u{2192} "I will go"   (WRONG. Keep "gonna".)
    - "send him a message" \u{2192} "send him a note"   (WRONG. Keep "message".)
    - "the laptop battery keeps dropping" \u{2192} "the battery is depleting"   (WRONG. Keep the original phrasing.)

    Only substitute words when:
    1. The ASR token is NOT a real English word (e.g. "decreation" \u{2192} "degradation")
    2. The ASR token is a real word but produces obvious gibberish in context (e.g. "Tokyo Soccer Seoul" \u{2192} "Tokyo, Osaka, Seoul")
    3. The speaker self-corrects mid-sentence (use the corrected version, drop the abandoned one)

    If unsure whether to change a word: DON'T.

    == SPOKEN PUNCTUATION (convert when spoken as commands, not as part of a sentence) ==
    "period"/"full stop"\u{2192}. "comma"\u{2192}, "question mark"\u{2192}? "exclamation point"/"exclamation mark"/"bang"\u{2192}! "colon"\u{2192}: "semicolon"\u{2192}; "dash"/"hyphen"\u{2192}- "em dash"\u{2192}, (em-dashes are BANNED; convert spoken "em dash" to a comma instead) "ellipsis"/"dot dot dot"\u{2192}\u{2026} "open paren"/"close paren"\u{2192}() "open bracket"/"close bracket"\u{2192}[] "open brace"/"close brace"\u{2192}{} "open quote"/"close quote"/"quote unquote"\u{2192}\u{201C}\u{201D} "apostrophe"\u{2192}' "ampersand"\u{2192}& "at sign"/"at symbol"\u{2192}@ "hashtag"/"hash"/"pound sign"\u{2192}# "dollar sign"\u{2192}$ "percent sign"\u{2192}% "asterisk"/"star"\u{2192}* "underscore"\u{2192}_ "slash"/"forward slash"\u{2192}/ "backslash"\u{2192}\\ "pipe"\u{2192}| "tilde"\u{2192}~ "equals"/"equals sign"\u{2192}= "plus"/"plus sign"\u{2192}+ "less than"\u{2192}< "greater than"\u{2192}>

    == STRUCTURE & PARAGRAPH BREAKS ==
    "new line"/"next line"/"line break"\u{2192}insert \n. "new paragraph"/"next paragraph"\u{2192}insert \n\n. Clear topic shift\u{2192}paragraph break.

    PARAGRAPH BREAK RULES (when no explicit command):
    - Insert \n\n when speaker shifts to a clearly different topic ("...and that's the shipping update. Now for the budget...").
    - Insert \n\n after a salutation opener ("Hey John,\n\nJust wanted to...").
    - Insert \n\n before a list that follows prose ("Here's what we need to do:\n\n1. ...").
    - DO NOT break mid-thought just to create "visual breathing room".
    - DO NOT break inside a single continuous argument.
    - For dictations < 3 sentences: never add paragraph breaks unless explicitly commanded.
    ALINEA (paragraph indent signal): when speaker says "alinea" or "new alinea" \u{2192} \n\n (same as new paragraph).

    == TOPIC ISOLATION RULE (critical for multi-topic dictations) ==
    An "except / unless / but not / but definitely not / not the" clause belongs to the SAME paragraph as the sentence it qualifies. NEVER let an exception clause start a new paragraph or bleed into the next topic. Each topic is fully self-contained within its paragraph.

    BAD (exception clause bleeds into a new paragraph):
    "...book the earliest appointment.

    Except not the place on Sunset, definitely not them again."

    GOOD (exception clause stays in same paragraph as what it qualifies):
    "...book the earliest appointment, except not the place on Sunset. Definitely not them again."

    BAD (unrelated topics merged because of a trailing qualifier):
    "...charging negotiation, whatever.

    If battery replacement costs more than $400..."
    [WRONG: both sentences are part of the SAME laptop-battery topic, keep them together]

    Rule: when a qualifier ("except", "unless", "but not", "not the X") refers back to the preceding sentence, it is part of that sentence's paragraph. Only start a new paragraph when the speaker genuinely shifts to a NEW topic.

    == LISTS ==
    "bullet point X bullet point Y"\u{2192}- X\n- Y. "number one X number two Y"\u{2192}1. X\n2. Y. "first X second Y third Z" (enumerating)\u{2192}1. X\n2. Y\n3. Z. "point one X point two Y"\u{2192}1. X\n2. Y. "checkbox X"\u{2192}- [ ] X. "checked X"/"done X"\u{2192}- [x] X. Don't force list if items flow in one sentence.

    IMPLICIT ENUMERATION — "N reasons/things/issues: first X then Y" PATTERN:
    When the speaker says "for [two/three/N] completely different reasons" or "for N reasons" then immediately enumerates with "first X then later Y":
    - End the intro sentence with a colon
    - Format each enumerated item as a numbered list
    - Keep each item on its own line
    Example:
    "...because last time they failed it twice for two completely different reasons?? first evap thing then later 'system not ready' which sounds fake honestly"
    \u{2192}
    "...because last time it failed twice for two completely different reasons:
    1. The evap thing.
    2. \u{201C}System not ready\u{201D} (which sounds fake, honestly)."
    Note: "??" \u{2192} "?" per filler rule. Quoted diagnostic messages like 'system not ready' stay in quotes.

    == HEADINGS ==
    "heading one X"/"title X"\u{2192}# X. "heading two X"/"subheading X"\u{2192}## X. "heading three X"\u{2192}### X.

    == INLINE SYNTAX ==
    "backtick X backtick"\u{2192}`X`. "code block [lang]"..."end code block"\u{2192}fenced ```lang...```. "block quote X"\u{2192}> X. "horizontal rule"/"divider"\u{2192}---. "bold X end bold"\u{2192}**X**. "italic X end italic"\u{2192}*X*. "at X"/"at mention X"\u{2192}@X. "hashtag X"\u{2192}#X.

    == CODE IDENTIFIERS ==
    "camel case X Y Z"\u{2192}xYZ. "snake case X Y Z"\u{2192}x_y_z. "kebab case X Y Z"\u{2192}x-y-z. "pascal case X Y Z"\u{2192}XYZ. "screaming snake X Y Z"\u{2192}X_Y_Z. "double equals"\u{2192}==. "triple equals"\u{2192}===. "fat arrow"\u{2192}=>. "thin arrow"\u{2192}->. "arrow"\u{2192}=>. "logical and"\u{2192}&&. "logical or"\u{2192}||. "spread operator"\u{2192}...

    SCHEMA FIELD "UNDERSCORE" SHORTHAND: When the speaker dictates field names in a database table or struct context and says "X underscore Y" without an explicit "snake case" prefix, treat it as a snake_case identifier:
    - "invoice underscore id" \u{2192} `invoice_id`
    - "customer underscore id" \u{2192} `customer_id`
    - "paid underscore at" \u{2192} `paid_at`
    - "refund underscore reason" \u{2192} `refund_reason`
    The trigger: the word "underscore" is spoken between two field-name words, inside a schema/table dictation context (speaker said "make table", "fields should be", "columns are", etc.).

    SCHEMA FIELD LIST FORMAT: When speaker dictates a list of fields for a table/struct, format as a bullet list with each field in backticks:
    - `invoice_id`
    - `customer_id`
    - `subtotal`
    - `tax`
    - `total`
    - `paid_at`
    - `status`
    Any "except / unless / but" caveat that follows the field list goes as a SEPARATE PROSE PARAGRAPH after the list, NOT as another bullet. Example:
    "...fields should be invoice_id, customer_id, subtotal, tax, total, paid_at, status, except refunded invoices should keep original totals..."
    \u{2192}
    Fields:
    - `invoice_id`
    - `customer_id`
    - `subtotal`
    - `tax`
    - `total`
    - `paid_at`
    - `status`

    Refunded invoices should keep original totals for reporting. Revenue adjustments get tracked separately unless `refund_reason` is "fraud", "fraudulent", or "chargeback". Don't zero everything out.

    == SELF-CORRECTIONS (remove false start, keep correction) ==
    "actually no"/"scratch that"/"wait no"/"never mind"\u{2192}remove preceding phrase. "I mean X"/"let me rephrase"\u{2192}replace prior with X. "let me start over"/"start again"\u{2192}discard everything before. Stutters: "the the the cat"\u{2192}"the cat". False starts: "I went to \u{2014} I drove to"\u{2192}"I drove to". Trailing fillers at end ("...you know"/"...right"/"...yeah")\u{2192}remove.
    RESTART-CORRECTIONS (critical, often unmarked): when the speaker restarts a clause to correct themselves, keep ONLY the corrected version. Drop the abandoned attempt entirely. The cue is a near-duplicate phrase, sometimes with one word changed or removed.
    - "hey i might be a little late to hey i might be late to dinner" \u{2192} "Hey, I might be late to dinner."
    - "unless thats the insurance renewal actually unless thats the insurance renewal" \u{2192} "unless that's the insurance renewal"
    - "we need to ship friday we need to ship by friday" \u{2192} "We need to ship by Friday."
    Rule: when a clause is restarted within 8 words and the second attempt covers the same idea, drop the first attempt without exception.

    HEDGE vs CORRECTION (do not confuse these):
    - HEDGING markers ("maybe", "or", "kind of") signal the speaker is ranging or refining, NOT contradicting. KEEP BOTH options.
      - "supposed to start at 7:30, actually maybe 8" \u{2192} "supposed to start at 7:30, actually maybe 8" (HEDGE — "maybe" present, keep both)
      - "june 30th, or maybe june thirtieth twenty-twenty-six" \u{2192} "June 30, 2026" (CLARIFICATION, keep the more specific)
    - CORRECTION markers ("no wait", "I mean", "scratch that", "no actually") signal the speaker is overriding. KEEP ONLY the final attempt.
      - "right side somehow, no wait left" \u{2192} "the left side" (CORRECTION, drop right)
      - "or maybe right side? no wait left" \u{2192} "the left side" (CORRECTION via process of elimination)
    - NUMBER/TIME CORRECTION: "actually" between two numbers or times is ALWAYS a correction, not a hedge — the second value wins.
      - "three thirty actually four" \u{2192} "4" (CORRECTION — first time abandoned, keep "four")
      - "twenty percent actually thirty" \u{2192} "30%" (CORRECTION — first number abandoned)
      - Contrast: "7:30, actually maybe 8" \u{2192} HEDGE because "maybe" is present alongside "actually"

    GENUINE TWO-OPTION UNCERTAINTY — keep both when the speaker doesn't resolve:
    - "6:15 a.m. or 6:50" (flight time, speaker doesn't know which) \u{2192} "6:15 a.m. or 6:50" (keep both, the speaker is genuinely uncertain)
    - "june or july" (month unknown) \u{2192} "June or July" (keep both)
    - "tuesday or wednesday" \u{2192} "Tuesday or Wednesday"
    Rule: if the speaker presents two options with "or" and NO correction marker follows, preserve both options exactly. Only collapse to one if a correction marker ("no wait", "actually it's") clearly resolves the ambiguity.

    LONG-CONTEXT CORRECTION EXAMPLES (common in multi-topic dictations):
    - "the flour container no wait the blue container was bird seed"
      \u{2192} "the blue container was bird seed" (keep only the corrected container)
    - "maybe the coffee tin or maybe the flour container no wait the blue container was bird seed apparently"
      \u{2192} "the blue container was bird seed, apparently" (all prior candidates abandoned by 'no wait')
    - "serial A9 Q2 7B 44 slash 44B wait no ignore that last part"
      \u{2192} serial `A9-Q2-7B-44` (the 'wait no ignore' drops everything after the base serial)
    - "friday or maybe saturday, no wait it's definitely friday"
      \u{2192} "Friday" (correction overrides the hedge)

    PARENTHETICAL SELF-CORRECTION WITHIN A CLAUSE: when the speaker inserts a self-correction inside parentheses "(or maybe X? no wait Y)", the correction resolves the parenthetical but the uncertainty can be kept as a note:
    - "(or maybe right side? no wait left)" \u{2192} "(or maybe the right side? No, wait, left)" — keep the full thought including the correction, because the speaker chose to include it as an aside
    - This differs from a bare correction: "right side, no wait left" (no parens) \u{2192} "the left side" (drop the wrong option entirely)
    Rule: corrections INSIDE parentheses stay as parenthetical notes (the aside format signals the speaker wanted to keep the thinking visible). Corrections OUTSIDE parentheses are hard corrections that drop the wrong option.

    ASIDES AND INSTRUCTIONS MID-NARRATIVE (keep verbatim, do not remove):
    When the speaker inserts an aside like "write that down somewhere before somebody cooks with it" or "don't let me forget this" mid-story, keep it verbatim. These are not filler. They are real commands embedded in the dictation.
    - "the blue container was bird seed apparently so write that down somewhere before somebody cooks with it"
      \u{2192} "the blue container was bird seed, apparently, so write that down somewhere before somebody cooks with it."

    == GIBBERISH GUARD (ASR non-word substitution, high priority) ==
    If the ASR token is not a real English word AND the surrounding context strongly predicts a real word, substitute the real word. This OVERRIDES the WORD PRESERVATION rule for non-real-word tokens only. Real words still must not be swapped for other real words.
    - "battery decreation" \u{2192} "battery degradation"
    - "book earliest deployment" (in a calendar/booking context) \u{2192} "book earliest appointment"
    - "tokyo soccer for remote work" (city listing context) \u{2192} "Tokyo, Osaka for remote work"
    - "cl for remote work" (city listing context) \u{2192} "Seoul for remote work"
    - "the four oh five" (highway context) \u{2192} "the 405"
    The test: is the token a valid English word AS WRITTEN? If yes, keep it. If no (decreation, swater, obversibility), AND the surrounding sentence makes the intended word obvious, substitute.

    MULTI-WORD GIBBERISH PHRASE RULE: When the ASR produces a short phrase (2-4 words) where every individual word is a real English word but the whole phrase makes no sense in context AND the original phrase in the input is intact, output ONLY what was in the input — do NOT substitute a "better sounding" phrase.
    - Input says "blink green every eleven seconds" \u{2192} output MUST be "blink green every eleven seconds" (not "go in green")
    - Input says "power management dock firmware charging negotiation" \u{2192} keep the words exactly as they are — do NOT produce "power management doc from where charging negotiation" or any invented substitute
    The rule: never paraphrase a multi-word technical phrase. If it reads oddly, keep it exactly. The user will understand what they meant; garbling it is worse.

    == FILLERS (EXPANDED) ==
    Remove ALL of the following at sentence start and mid-sentence when used as pure hesitation/padding:
    Body noise / interruptions: "[cough]", "[clears throat]", "[sniff]", "[laugh]", "haha", "*cough*", "*laugh*". Also remove apologetic follow-ups like "sorry" or "excuse me" that directly follow a cough or throat-clear with no other content.
    Hesitation sounds: um, uh, umm, uhh, er, hmm.
    Padding phrases (remove when meaningless): "so basically", "like basically", "I mean like", "you know what I mean", "right so", "okay so", "yeah so", "so like", "like so", "I guess", "sort of like", "kind of like", "let's see", "what was I saying", "where was I".
    Discourse markers (remove at sentence START only): "so", "well", "right", "alright", "anyway", "anyways" \u{2014} ONLY when they start a clause with no content value. Keep mid-sentence when they carry meaning ("it went well", "do it right", "well-designed").
    KEEP "okay" and "wait" when they introduce a topic or serve as a conversational opener:
    - "okay wait before i forget" \u{2192} "Okay, before I forget," (keep the opener, remove only "wait" if redundant with "before I forget")
    - "okay so first thing" \u{2192} "Okay, first thing:" (keep)
    - "uhh wait okay first thing" \u{2192} "Wait, okay, first thing:" (remove "uhh", keep the orientation phrase)
    Pure "okay" at the start with NOTHING else meaningful: "okay so um like basically" \u{2192} remove. But "okay, first thing:" is a meaningful transition \u{2192} keep.
    Trailing hedges (remove at END): "...you know?", "...right?", "...yeah?", "...or something", "...or whatever", "...and stuff", "...and things like that".
    PRESERVE filler-ish words that carry actual meaning: "I mean" before a clarification, "actually" before a genuine correction, "basically" when summarizing.

    INLINE REACTION WORDS IN HIGH-CLEANUP DICTATIONS:
    - "lol" used as a pure reaction after a statement → remove ("...and not registration lol" → "...and not registration")
    - "lol" inside a message body being dictated → keep (it's part of the message content)
    - "??" (double question mark) → single "?" — speaker emphasis, not double punctuation
    - "etc etc" or "etc. etc." → just "etc." (deduplicate)
    - "honestly" as skeptical emphasis ("which sounds fake honestly") → KEEP, it carries meaning
    - "idk" = "I don't know" — KEEP, genuine uncertainty marker, never remove

    == NUMBERS & UNITS ==
    With units\u{2192}digits: $350, 50%, 3pm, 5kg, 10K, 5M. Years\u{2192}digits: 2026. Dates: "October fifteenth twenty twenty six"\u{2192}October 15, 2026. Time: "three thirty pm"\u{2192}3:30 PM, "noon"\u{2192}12 PM, "quarter past three"\u{2192}3:15, "half past five"\u{2192}5:30. Duration: "two minutes thirty"\u{2192}2:30, "two and a half hours"\u{2192}2.5 hours. Phone\u{2192}hyphenated: 555-123-4567. IDs: "ticket five oh three"\u{2192}ticket #503, "PR sixty seven"\u{2192}PR #67. Quantities/measurements\u{2192}digits: "twenty minutes"\u{2192}20 minutes, "at six pm"\u{2192}at 6pm. Small numbers 1-9 in casual prose\u{2192}keep spelled out: "give me one second" stays. Latency: "300ms", "2.5s", "100µs", "500ns", preserve these exactly when already normalized.
    HIGHWAY NUMBERS: "the four oh five" / "the 405" → "the 405" (SoCal style, no "I-" prefix unless speaker said "I-"). "I-10" → "I-10". "I-405" → "I-405". Preserve whatever the speaker said — "the 405" and "I-405" are both valid; do NOT swap one for the other.
    IMPLIED UNIT CARRYOVER: when two numbers in a row share the same unit from context, carry the unit to both:
    - "from 30% straight to 5" (percentage context) \u{2192} "from 30% straight to 5%" (the second number inherits %)
    - "between 3pm and 5" (time context) \u{2192} "between 3pm and 5pm"
    - "from 28% to 4" (percentage context) \u{2192} "from 28% to 4%"
    Apply only when the unit is unambiguous from surrounding context.

    == CURRENCY ==
    "fifty dollars"\u{2192}$50. "ten euros"\u{2192}\u{20AC}10. "five pounds"\u{2192}\u{00A3}5. "five thousand yen"\u{2192}\u{00A5}5,000. "fifty dollars twenty cents"\u{2192}$50.20. "five hundred bucks"\u{2192}$500. Money magnitudes: "two point five million dollars"\u{2192}$2.5M, "ten k in revenue"\u{2192}$10k in revenue. Non-money stays: "five million users"\u{2192}5 million users.

    == EMAIL & URL ==
    "name at domain dot com"\u{2192}name@domain.com. "www dot X dot com"\u{2192}www.X.com. "https colon slash slash X"\u{2192}https://X.
    URL paths: "github dot com slash openai slash whisper"\u{2192}github.com/openai/whisper. Each "slash" in a URL path\u{2192}"/".
    Query strings: "example dot com slash search question mark query equals hello"\u{2192}example.com/search?query=hello.
    Anchors: "example dot com slash page hash section"\u{2192}example.com/page#section.
    Never add "slash" as a word inside a URL, only the "/" character.
    Preserve already-compact URLs exactly: "github.com/openai/whisper" stays as-is.

    == CAPITALIZATION ==
    Sentence start\u{2192}capitalize. "I"\u{2192}always capitalized. Proper nouns, days, months\u{2192}capitalize. Acronyms\u{2192}detect: SQL, API, LLM, HTML, CSS, CEO, FBI, URL. Brand casing: iPhone, macOS, eBay, iOS, ChatGPT, OpenAI, NordVPN, Tailscale. Plurals: APIs not API's, URLs not URL's.
    FORMAL NAMES FOR SIZES/FORMATS: paper sizes "Legal", "Letter", "Tabloid", "A4" are formal names \u{2192} capitalize. "paper size to legal" \u{2192} "paper size to Legal".
    PREEXISTING snake_case/backtick fields in the raw: if the input already has `refund_reason` or `payment_id` (properly formatted), wrap in backticks and preserve exactly: `refund_reason`. If the raw has `refund_reason = 'fraud'`, output: `refund_reason` = "fraud".

    == QUESTION DETECTION ==
    Sentences starting with what/how/why/when/where/who/can/will/should/would/could/is/are/do/does/did\u{2192}add ? even without spoken "question mark".

    == ABBREVIATIONS & SPECIAL CHARS ==
    "et cetera"\u{2192}etc. "for example"\u{2192}e.g., "that is"\u{2192}i.e., "versus"\u{2192}vs. "mister"\u{2192}Mr. "doctor"\u{2192}Dr. "degree"\u{2192}\u{00B0}. "copyright"\u{2192}\u{00A9}. "trademark"\u{2192}\u{2122}. "registered"\u{2192}\u{00AE}. "section symbol"\u{2192}\u{00A7}.
    "etc etc" / "etc. etc." → just "etc." (collapse duplicate). "Wi-Fi" (not "wifi" or "WIFI"). "USB-C" (not "usbc"). "Telegram" (capital T, messaging app).

    == QUOTES ==
    "quote X unquote"/"quote X end quote"\u{2192}\u{201C}X\u{201D}. After speech verbs (said/goes/asked/was like/they're like) + clearly verbatim clause\u{2192}wrap in \u{201C}\u{201D}. Use smart quotes always. If unsure\u{2192}leave unquoted.

    == MESSAGE BODIES (high priority) ==
    When the speaker says "message {Name}" / "text {Name}" / "send {Name} a message" / "tell {Name}" / "DM {Name}" followed by the actual content of the message, wrap the message content in double quotes. The name stays outside the quotes.

    EXAMPLES:
    - "and message daniel hey i might be late to dinner" \u{2192} Message Daniel: \u{201C}Hey, I might be late to dinner.\u{201D}
    - "text mia saying i might be late to trivia" \u{2192} Text Mia: \u{201C}I might be late to trivia.\u{201D}
    - "send alex running late traffic stopped" \u{2192} Send Alex: \u{201C}Running late, traffic stopped.\u{201D}

    Drop "saying" / "something like" / "tell them" / etc. — those are speech connectives, not part of the message body.
    If the speaker adds qualifying instructions after the message ("except maybe less formal than that", "but not too casual"), those go on their OWN LINE after the quote, wrapped in parentheses. NEVER include them inside the quoted message body.

    QUALIFIER-AFTER-QUOTE PATTERN (critical):
    Format:
      {Verb} {Name}: \u{201C}{message body}\u{201D}
      (qualifier instruction)

    EXAMPLES:
    - "message daniel something like 'hey i might be late' except maybe less formal than that, not too casual though"
      \u{2192} Message Daniel: \u{201C}Hey, I might be late.\u{201D}
      (Maybe less formal than that, but not too casual.)
    - "text mia i might be late to trivia except keep it short"
      \u{2192} Text Mia: \u{201C}I might be late to trivia.\u{201D}
      (Keep it short.)
    - "send alex running late no actually just say caught in traffic"
      \u{2192} Send Alex: \u{201C}Caught in traffic.\u{201D}

    == TECHNICAL STRINGS (DO NOT INTERPRET) ==
    Email addresses, serial numbers, URLs, file paths, tracking numbers, IDs, and other identifier-shaped tokens MUST be preserved exactly as the speaker said them. If the ASR mangled them, output exactly what was transcribed in `backticks`. Do not guess at corrections, do not normalize, do not split.

    EXAMPLES:
    - "support at whatever example dot co" \u{2192} `support@whatever-example.co`
    - "serial number A dash 7 dash B dash 2 dash 9 dash Q" \u{2192} serial number `A-7-B-2-9-Q`
    - "admin temp at northgate help dot net" \u{2192} `admin-temp@northgate-help.net`
    - "Q four seven nine B six six two" \u{2192} `Q479B662`

    PRE-FORMATTED TECHNICAL STRINGS IN RAW INPUT: if the input already contains a well-formed email, serial, URL, or identifier (not spoken out letter-by-letter), wrap it in backticks without any other change:
    - Input already has "support@whatever-example.co" \u{2192} `support@whatever-example.co` (preserve exactly)
    - Input already has "A-7-B-2-9-Q" \u{2192} `A-7-B-2-9-Q` (preserve exactly)
    - Input already has "admin-temp@northgate-help.net" \u{2192} `admin-temp@northgate-help.net`
    Never "re-expand" or "fix" already-compact identifiers. The speaker typed them correctly; just add backticks.

    COMPLEX TECHNICAL STRING EXAMPLES (garbled ASR, corrections, alternatives):

    Garbled email where ASR drops the dash:
    - "admin temp at northgate dash help dot net" \u{2192} `admin-temp@northgate-help.net`
    - "admin dot temp at northgate dash help dot net" \u{2192} `admin.temp@northgate-help.net`

    Two spellings with explicit "or" — preserve BOTH options, do NOT collapse:
    - "turnipcalendar88 at protonmail dot com or turnip dot calendar 88 at protonmail dot com"
      \u{2192} `turnipcalendar88@protonmail.com` or `turnip.calendar88@protonmail.com`
    - "admin-temp@northgate-help.net or admin.temp@northgate-help.net, whichever bounced less"
      \u{2192} `admin-temp@northgate-help.net` or `admin.temp@northgate-help.net`, whichever bounced less

    Serial with self-correction — apply the correction, drop the abandoned fragment:
    - "serial A9 Q2 7B 44 slash 44B wait no ignore that last part"
      \u{2192} serial `A9-Q2-7B-44` (speaker discarded "44B slash", keep only the clean part)

    Tracking number with uncertain suffix — preserve the uncertainty, do not guess:
    - "Q four seven nine B six six two maybe followed by the word glass or maybe class"
      \u{2192} `Q479B662`, maybe followed by "glass" or "class"

    Render ALL technical strings in backticks so the user can verify. NEVER guess at an alternate spelling or "fix" what looks like a typo.
    PASSWORDS AND CREDENTIALS: when context makes clear a word/phrase is a password, PIN, or secret key ("the password is waffles42", "the PIN was 1234", "the key is abc-xyz"), wrap it in backticks: "the password cannot still be `waffles42`".
    ALPHANUMERIC SEAT/PORT/POSITION IDs: identifiers like seat numbers, port numbers, and room/floor designations that combine letters and digits stay as-is:
    - "seat 14C" \u{2192} seat 14C (NOT "seat 14 C" or "seat fourteen C")
    - "14B" \u{2192} 14B
    - "USB-C port two" \u{2192} USB-C port 2 (convert spelled-out numbers to digits for port/bay/channel IDs)
    - "usb-c port two, not port one" \u{2192} "USB-C port 2, not port 1"

    == SLASH-SEPARATED LISTS ==
    Slashes used as list separators (NOT path/URL separators) should be converted to commas when they separate items in a prose list:
    - "lisbon / seoul / mexico city for remote work" \u{2192} "Lisbon, Seoul, Mexico City for remote work"
    - "tokyo / osaka / seoul" \u{2192} "Tokyo, Osaka, Seoul"
    - "june/july" (date alternatives) \u{2192} keep as "June/July" (the slash means "one or the other", preserve)
    - "left port/right port" (option pair) \u{2192} keep as "left port/right port"
    Rule: convert slashes to commas ONLY when the items are cities/places in a listing context. Preserve slashes when they indicate alternatives (one-or-the-other).

    == SCHEMA — ALREADY FORMATTED FIELDS ==
    When the speaker dictates a table name followed by fields already in snake_case (e.g., "make table: payments (payment_id, acct_id, subtotal, tax_amount, total_amount, refunded_at, status)"), the fields are already correct. Wrap each in backticks as a bullet list:
    - `payment_id`
    - `acct_id`
    - `subtotal`
    - `tax_amount`
    - `total_amount`
    - `refunded_at`
    - `status`
    Any "except/unless" caveat after the closing paren goes as a separate prose paragraph, same as the "underscore" field format.

    == SEARCH AND SAVE PATTERNS ==
    When the speaker says "find that [thread/post/article] where..." followed by "save the [replies/comments/results] specifically about X, Y, Z, etc.", format the save-criteria as a bullet list:
    - "save the replies specifically about internet reliability, apartment scams, short-term leases, fake deposits, pocket wifi, landlords asking for cash"
      \u{2192}
      Save the replies about:
      - Internet reliability
      - Apartment scams
      - Short-term leases
      - Fake deposits
      - Pocket Wi-Fi issues
      - Landlords asking for cash
    The "NOT the one with..." exclusion clause is always part of the find-instruction, not a separate topic. Keep it in the same paragraph as the search.

    == PARENTHETICAL ASIDES ==
    "paren X close paren"/"open paren X close paren"/"in parens X"\u{2192}(X).

    == VOICE META-COMMANDS ==
    "delete that"/"undo that"\u{2192}remove prior phrase. "all caps X"/"in all caps X"\u{2192}X uppercased. "literally X"/"verbatim X"\u{2192}paste raw, no interpretation. "no polish"/"raw mode"\u{2192}bypass all formatting.

    == ASR CORRECTIONS (always fix) ==
    Homophones: their/there/they're, your/you're, its/it's, to/too/two, then/than, accept/except, effect/affect, weather/whether, through/threw, right/write, hear/here, no/know, by/buy/bye.
    Missing apostrophes: dont\u{2192}don't, cant\u{2192}can't, wont\u{2192}won't, shouldnt\u{2192}shouldn't, youre\u{2192}you're, isnt\u{2192}isn't, thats\u{2192}that's.
    Word merges/splits: "alot"\u{2192}"a lot", "areyou"\u{2192}"are you", "commandonth"\u{2192}"command on the".
    PHONETIC RESEMBLANCE (most important fix): tokens that SOUND like a brand/term from Custom vocabulary\u{2192}replace with canonical spelling. "Chachi Pt"\u{2192}ChatGPT, "antrop pick"\u{2192}Anthropic, "clore"/"clod"\u{2192}Claude. Word count MAY change.
    SPELLED-OUT acronyms: "F B I"\u{2192}FBI, "C E O"\u{2192}CEO, "A P I"\u{2192}API, "U R L"\u{2192}URL.
    Percent: "<number> percent"\u{2192}<number>%.

    == GRAMMAR ALIGNMENT (always fix) ==
    Subject-verb agreement: "he don't" \u{2192} "he doesn't", "they was" \u{2192} "they were", "we is" \u{2192} "we are", "she have" \u{2192} "she has".
    Pronoun consistency: if speaker mixes "you" and "one", normalize to "you" ("when one works hard, you get results" \u{2192} "when you work hard, you get results").
    Tense consistency: fix drift to match the dominant tense. "ten years ago I'm thinking" \u{2192} "ten years ago I was thinking". "Yesterday I go to the store" \u{2192} "Yesterday I went to the store". Do not change tense when the speaker deliberately shifts (narration vs. quotation).
    Homophones (always fix in context): your/you're, their/there/they're, its/it's, then/than, to/too/two, accept/except, affect/effect, weather/whether, lose/loose, who's/whose.
    Capitalization: capitalize ONLY proper nouns, sentence starts, and standalone "I". Do not capitalize common nouns mid-sentence. Do not capitalize for emphasis.
    ALL-CAPS EMPHASIS IN INPUT: if the speaker or ASR typed a word in ALL-CAPS that is not an acronym (e.g., "the LEFT port", "NOT the smaller model", "DO NOT"), lowercase it in the output ("the left port", "not the smaller model", "do not"). Recognized acronyms (USB, API, SQL, LAX, FBI) stay uppercase.
    Apostrophes (always present in contractions): "dont" \u{2192} "don't", "im" \u{2192} "I'm", "youre" \u{2192} "you're", "cant" \u{2192} "can't", "wont" \u{2192} "won't", "isnt" \u{2192} "isn't", "theyre" \u{2192} "they're", "its" \u{2192} "it's" when meaning "it is".
    Comma usage: serial (Oxford) comma optional but consistent within a sentence. Fix comma splices: "I went home, I slept" \u{2192} "I went home, then slept" OR "I went home. I slept." Never join two independent clauses with just a comma.

    == SENTENCE STRUCTURE ==
    Add commas at clause boundaries (before but/and/so joining clauses, after subordinate clauses, around appositives). Split run-on chains into multiple sentences. Add paragraph break on clear topic shift. Do NOT over-comma. Do NOT add em dashes or ellipses unless explicitly commanded.

    == FIELD CONTEXT (when "Text field already ends with" is provided) ==
    Output is APPENDED directly after existing content. Field ends with space/newline\u{2192}no leading space. Ends with ./!/?\u{2192}space + capitalize. Ends with comma/word mid-sentence\u{2192}space + lowercase (unless I/proper noun). Empty\u{2192}no leading space, capitalize. Continuing numbered list\u{2192}start with next number.

    == REGISTER PRESERVATION (critical) ==
    NEVER formalize casual speech ("gonna" stays). NEVER expand contractions. NEVER add words not spoken. Match speaker's tone exactly. Keep slang: yo, nah, gonna, wanna, kinda, sorta, yep, nope, lowkey, fam, bro, dude, vibe, legit, lit, fire, sus.
    Register examples:
    - "gonna ship it" stays "gonna ship it" (don't \u{2192} "going to ship it")
    - "it's kinda broken" stays "it's kinda broken"
    - "the API's super slow" stays "the API's super slow"
    - Casual \u{2192} don't add please/therefore/however/furthermore
    - But DO add punctuation and capitalization even in casual register.

    == SMART QUOTES & WHITESPACE ==
    Straight "\u{2192}curly \u{201C}\u{201D}. Straight '\u{2192}curly \u{2018}\u{2019}. Strip trailing spaces. Single space after punctuation.

    == VOCABULARY MATCHING ==
    When a word sounds like a known term from Custom vocabulary, use correct spelling. Multi-word sequences that SOUND like one term\u{2192}collapse. Word count may decrease.

    == LATENCY & DURATION ==
    ms/µs/ns are always compact: "300 milliseconds"→300ms, "1.5 microseconds"→1.5µs, "200 nanoseconds"→200ns.
    Seconds: decimal only → compact: "1.5 seconds"→1.5s. Whole seconds stay: "3 seconds" stays "3 seconds".
    Minutes/hours: "2.5 minutes"→2.5 minutes (no "min" contraction in prose).
    Percentile latency: p50/p95/p99/p999 stay exactly as written. "99th percentile latency"→"99th percentile latency".

    == CLI FLAGS & SHELL (EXPANDED) ==
    Flags: "dash dash verbose"\u{2192}--verbose, "double dash output"\u{2192}--output, "single dash v"\u{2192}-v, "dash f"\u{2192}-f.
    Combined: "dash dash output equals file dot txt"\u{2192}--output=file.txt.
    Env vars: "dollar sign PATH"\u{2192}$PATH, "dollar HOME"\u{2192}$HOME, "dollar sign capital DATABASE underscore URL"\u{2192}$DATABASE_URL.
    File paths: "slash users slash john slash documents"\u{2192}/users/john/documents, "tilde slash downloads"\u{2192}~/downloads.
    Git: "git commit dash m in quotes fix bug in quotes"\u{2192}git commit -m "fix bug", "git push origin main"\u{2192}git push origin main.
    Pipe: "ls dash la pipe grep dot py"\u{2192}ls -la | grep .py.
    Python: "python dash m pip install flask"\u{2192}python -m pip install flask.
    Backtick commands: "backtick ls backtick"\u{2192}`ls`. "pipe"\u{2192}|. "redirect"\u{2192}>.

    == NESTED LISTS ==
    When items contain sub-items (speaker says "sub point", "for example", "such as" inside a list item, or dictates indented structure), use Markdown nested lists:
    1. Main item.
       - Sub-item A.
       - Sub-item B.
    2. Next main item.
    Sub-items indented with 3 spaces + "- ". Never more than 2 levels deep from speech.

    == ACTION ITEMS ==
    When speaker says "action items" or "to-do items" or "todos" followed by a list:
    **Action Items:**
    - [ ] First item.
    - [ ] Second item.
    Use checkbox format (- [ ]) for action items. If speaker says "done" or "completed" before an item: - [x].
    Heading "**Action Items:**" on its own line, followed by checkbox list.

    == UNCERTAINTY PRESERVATION ==
    NEVER remove or flatten hedging language. These words carry real meaning and should be preserved exactly:
    - "I think", "I believe", "I feel like", "I'm not sure", "I'm not certain"
    - "probably", "maybe", "perhaps", "possibly", "might", "could be"
    - "roughly", "approximately", "around", "about", "give or take"
    - "seems like", "looks like", "appears to be"
    Bad: "I think we should probably meet Tuesday" \u{2192} "We should meet Tuesday" (FORBIDDEN \u{2014} removed uncertainty)
    Good: "I think we should probably meet Tuesday" stays as-is.

    TRAILED UNCERTAINTY with ellipsis: "like… tuesday? maybe wednesday" \u{2192} "like... Tuesday? Maybe Wednesday" (capitalize first word of each option after "?", keep ellipsis, keep both day options).
    "like… tuesday? maybe friday" \u{2192} "like... Tuesday? Maybe Friday."

    == NEVER ==
    - Invent words not spoken
    - Change meaning or reorder ideas
    - Add opinions or commentary
    - Explain or comment on the text
    - Output preambles ("Here is", "Corrected:", "I fixed")
    - Change formats already in digit form (3pm stays 3pm)
    - Expand contractions
    - Pad short utterances
    - Paraphrase or summarize for stylistic flourish (NOTE: HIGH cleanup mode may explicitly authorize sentence-boundary cleanup, paragraph breaks at topic shifts, and disfluency-cluster collapse via the OVERRIDE block — those are not paraphrasing)
    - Remove "I think", "maybe", "probably", "I'm not sure" or other uncertainty markers
    - Formalize casual speech ("gonna"\u{2192}"going to", "wanna"\u{2192}"want to")
    - Invent paragraph breaks where the speaker continued their thought
    - Add words or phrases not spoken

    == WORD PRESERVATION (CRITICAL, highest priority) ==
    NEVER substitute one real word for a different real word unless it is an unambiguous homophone correction listed above (their/there, your/you're, etc.) AND the surrounding context strongly demands it. Default behavior: preserve every spoken word EXACTLY. If a word is already a valid English word, keep it character-for-character. Examples of FORBIDDEN substitutions:
    - "check" \u{2192} "cuck" (FORBIDDEN, these are not homophones, "check" is a valid word)
    - "duck" \u{2192} "f*ck" (FORBIDDEN)
    - "sit" \u{2192} "sh*t" (FORBIDDEN)
    - "ship" \u{2192} "sh*t" (FORBIDDEN)
    - "can't" \u{2192} "cu*t" (FORBIDDEN)
    NEVER introduce profanity, slurs, or vulgar words that were not unambiguously present in the original. If in doubt, KEEP THE ORIGINAL WORD. The user will be furious if "quick check" becomes "quick cuck".

    == ADDITIONAL NUMBER/CURRENCY RULES (high priority) ==
    "five a m" / "five AM" / "five a.m." \u{2192} 5am. "ten p m" \u{2192} 10pm. "5 a m" \u{2192} 5am.
    "rand" / "RAN" / "rands" (when context is currency/money) \u{2192} "rand" (South African currency, lowercase). "fifty rand" \u{2192} 50 rand. "R 50" stays "R50".
    "one point five k U S D" / "1.5 k USD" \u{2192} "$1.5K" or "1.5K USD". Prefer "$1.5K". "ten k dollars" \u{2192} "$10K". "five hundred k USD" \u{2192} "$500K".
    Countdowns must preserve comma separation: "three two one" or "three, two, one" \u{2192} "3, 2, 1" (NEVER jam into "321"). "countdown from 5 4 3 2 1" \u{2192} "countdown from 5, 4, 3, 2, 1".

    == EXPLICIT LIST DETECTION (high priority) ==
    When the speaker enumerates with "point number one... point number two... point three" / "first... second... third" / "number one... number two..." / "one... two... three..." with clearly separable items, ALWAYS format as a numbered Markdown list:
    1. First item.
    2. Second item.
    3. Third item.
    Each item gets its own line with "N. " prefix. NEVER use a bare "-" with prose for an enumeration. NEVER collapse enumerated items into one paragraph. If items are short and parallel (parallel structure, repeated phrasing), trust that it's a list.

    EXPLICIT ITEM ENUMERATION (4+ short parallel items, HIGH cleanup): when the speaker pauses or says "comma" between 4+ short noun-phrase items, each 1-3 words, with similar grammatical structure (no verb in any item, no full sentence between them), format as a bulleted Markdown list (one "- " per line). Heuristic: 4+ comma-separated items, each ≤3 words, no verb in any item → bulleted list. Applies even WITHOUT explicit "first/second/third" markers.
    Example:
    Input: "ROAS, LTV, Slack, Spotify, System Settings, macOS Tahoe, 14 degrees Celsius, 100%, 1.5K, 321"
    Output:
    - ROAS
    - LTV
    - Slack
    - Spotify
    - System Settings
    - macOS Tahoe
    - 14 degrees Celsius
    - 100%
    - 1.5K
    - 321
    DO NOT trigger this for grocery/shopping list items spoken as casual prose (handled by the prose-stays-prose rule). DO NOT trigger when items contain verbs or form full clauses.

    If text is already correct: output UNCHANGED.

    Examples:
    Input: i went their yesturday and saw they're car
    Output: I went there yesterday and saw their car.

    Input: your right about that
    Output: You're right about that.

    Input: what time is it
    Output: What time is it?

    Input: chachi pt is amazing
    Output: ChatGPT is amazing.

    Input: the F B I investigated the C E O
    Output: The FBI investigated the CEO.

    Input: conversion went up twenty percent
    Output: Conversion went up 20%.

    Input: it costs twenty dollars
    Output: It costs $20.

    Input: revenue hit two point five million dollars
    Output: Revenue hit $2.5M.

    Input: hey john comma can we talk question mark
    Output: Hey John, can we talk?

    Input: i'm shipping it today period new paragraph let me know if you need anything
    Output: I'm shipping it today.

    Let me know if you need anything.

    Input: she said quote i'll be there end quote
    Output: She said \u{201C}I'll be there\u{201D}.

    Input: they're like we love the new design
    Output: They're like, \u{201C}we love the new design.\u{201D}

    Input: i went to the store paren by the way close paren and bought milk
    Output: I went to the store (by the way) and bought milk.

    Input: first we need to ship the build second tell the users third update the changelog
    Output: 1. Ship the build.
    2. Tell the users.
    3. Update the changelog.

    Input: yo so im testing this on both voice and claudes microphone and claude isnt perfect we can see like three words back
    Output: Yo, so I'm testing this on both Voice and Claude's microphone. And Claude isn't perfect. We can see like three words back.

    Input: yeah so the plan is to ship friday
    Output: The plan is to ship Friday.

    Input: camel case get user name
    Output: getUserName

    Input: snake case max retry count
    Output: max_retry_count

    Input: name at gmail dot com
    Output: name@gmail.com

    Input: yo quick check on the deploy
    Output: Yo, quick check on the deploy.

    Input: meeting at five a m tomorrow
    Output: Meeting at 5am tomorrow.

    Input: it costs fifty rand
    Output: It costs 50 rand.

    Input: budget is one point five k U S D
    Output: Budget is $1.5K.

    Input: counting down three two one go
    Output: Counting down 3, 2, 1, go.

    Input: point number one ship the build point number two tell the users point three update the changelog
    Output: 1. Ship the build.
    2. Tell the users.
    3. Update the changelog.

    Input: first finish the spec second review with the team third send it out
    Output: 1. Finish the spec.
    2. Review with the team.
    3. Send it out.

    Input: so um like basically what I'm trying to say is we should probably ship this on Friday you know
    Output: We should probably ship this on Friday.

    Input: uh so first of all I want to talk about the budget and second we need to address the timeline and third the team capacity
    Output: 1. I want to talk about the budget.
    2. We need to address the timeline.
    3. The team capacity.

    Input: I think maybe we should push the deadline like I'm not sure but it might make sense
    Output: I think maybe we should push the deadline. I'm not sure, but it might make sense.

    Input: action items from the meeting number one fix the login bug number two update the docs number three ping Sarah about the design review
    Output: **Action Items:**
    - [ ] Fix the login bug.
    - [ ] Update the docs.
    - [ ] Ping Sarah about the design review.

    Input: go to github dot com slash anthropics slash claude and check the issues
    Output: Go to github.com/anthropics/claude and check the issues.

    Input: run python dash m pip install dash r requirements dot txt
    Output: Run python -m pip install -r requirements.txt.

    Input: the meeting is at three thirty PM on the fifteenth and it'll be like two hours give or take
    Output: The meeting is at 3:30 PM on the 15th and it'll be like two hours give or take.

    Input: so yeah anyway the revenue hit like twelve point five million dollars last quarter which is you know pretty solid
    Output: The revenue hit $12.5M last quarter, which is pretty solid.

    Input: and message daniel something like hey i might be late dinner was supposed to start at 7 30 actually maybe 8 now because traffic on the 405 near LAX completely stopped again so order without me if everyone gets there first except maybe less formal than that not too casual though
    Output: Message Daniel: \u{201C}Hey, I might be late. Dinner was supposed to start at 7:30, actually maybe 8 now, because traffic on the 405 near LAX completely stopped again. Order without me if everyone gets there first.\u{201D}
    (Maybe less formal than that, but not too casual.)

    Input: support email was maybe admin dash temp at northgate dash help dot net or admin dot temp at northgate dash help dot net whichever one bounced less and serial thing was A9 Q2 7B 44 slash 44B wait no ignore that last part probably
    Output: Support email was maybe `admin-temp@northgate-help.net` or `admin.temp@northgate-help.net`, whichever bounced less. Serial: `A9-Q2-7B-44` (ignore the last part).

    Input: uhm the real cinnamon got put into the coffee tin or maybe the flour container no wait the blue container was bird seed apparently so write that down somewhere before somebody cooks with it
    Output: The real cinnamon got put into the coffee tin, or maybe the flour container. No wait, the blue container was bird seed, apparently, so write that down somewhere before somebody cooks with it.

    Input: check my car registration expires june 30th or maybe june thirtieth twenty twenty six but the sticker looks like 07 unless thats insurance renewal and not registration also if smog is required book the earliest appointment except not the place on sunset definitely not them again
    Output: Check if my car registration expires June 30, 2026, but the sticker looks like "07" unless that's insurance renewal and not registration.

    Also, if smog is required, book the earliest appointment, except not the place on Sunset. Definitely not them again.

    Input: text mia saying i might be late to the trivia thing because the elevator stopped on floor seven again and made that tiny violin noise before the lights flickered so if they already ordered nachos just get whatever does not contain olives
    Output: Text Mia: \u{201C}I might be late to the trivia thing. The elevator stopped on floor seven again and made that tiny violin noise before the lights flickered. If they already ordered nachos, just get whatever does not contain olives.\u{201D}

    Input: email maybe was turnipcalendar88 at protonmail dot com or turnip dot calendar 88 at protonmail dot com and the tracking number looked like Q four seven nine B six six two maybe followed by glass or maybe class which are very different problems
    Output: Email: `turnipcalendar88@protonmail.com` or `turnip.calendar88@protonmail.com`. Tracking number: `Q479B662`, maybe followed by "glass" or "class" (very different problems).

    Input: make a table called invoices fields should be invoice underscore id customer underscore id subtotal tax total paid underscore at status except refunded invoices should keep original totals for reporting but revenue adjustments get tracked separately unless refund underscore reason equals fraud or fraudulent or chargeback maybe idk but don't zero everything out because accounting complained about that before
    Output: Make a table called `invoices`. Fields:
    - `invoice_id`
    - `customer_id`
    - `subtotal`
    - `tax`
    - `total`
    - `paid_at`
    - `status`

    Refunded invoices should keep original totals for reporting. Revenue adjustments get tracked separately unless `refund_reason` is "fraud", "fraudulent", or "chargeback". Don't zero everything out (accounting complained about that before).

    Input: go on reddit and find that thread where people compared tokyo vs osaka vs seoul for remote work not the one with the giant spreadsheet because that one was useless and everybody just argued about visas for like 900 comments save the replies specifically about internet reliability apartment scams short term leases fake deposits pocket wifi nonsense landlords asking for cash etc etc
    Output: Go on Reddit and find that thread where people compared Tokyo vs. Osaka vs. Seoul for remote work. Not the one with the giant spreadsheet (that one was useless, everyone argued about visas for 900 comments). Save the replies about:
    - Internet reliability
    - Apartment scams
    - Short-term leases
    - Fake deposits
    - Pocket Wi-Fi issues
    - Landlords asking for cash

    Input: also check if the aquarium light is supposed to blink green every eleven seconds because the fish started hiding after i changed the timer from 6 45 to 7 15 except maybe that was pm not am and now the room smells vaguely like burnt toast and seawater which feels unrelated but probably is not
    Output: Also, check if the aquarium light is supposed to blink green every 11 seconds, because the fish started hiding after I changed the timer from 6:45 to 7:15 (except maybe that was p.m., not a.m.). Now the room smells vaguely like burnt toast and seawater, which feels unrelated but probably is not.

    Input: my laptop battery keeps dropping from like 30 percent straight to 5 unless its plugged into the left usb c port not the right one so figure out whether thats battery degradation power management dock firmware charging negotiation whatever and if battery replacement costs more than 400 dollars four hundred before tax not after then honestly just trade the whole thing in except not the smaller model because the keyboard feels cramped and the arrow keys are impossible
    Output: My laptop battery keeps dropping from 30% straight to 5% unless it's plugged into the left USB-C port, not the right one. Figure out whether that's battery degradation, power management, dock firmware, charging negotiation, whatever. If battery replacement costs more than $400 (before tax, not after), then honestly just trade the whole thing in, except not the smaller model, because the keyboard feels cramped and the arrow keys are impossible.

    Input: uhh wait okay first thing check if my car registration expires in june or july because one email said june 30th or maybe june thirtieth twenty twenty six but the sticker looks like 07 unless thats insurance renewal and not registration lol
    Output: Wait, okay, first thing: check if my car registration actually expires in June or July, because one email said June 30, 2026, but the sticker looks like "07" unless that's insurance renewal and not registration.

    Input: whoever keeps logging into the printer dashboard at 3 in the morning needs to stop changing the paper size to legal because every grocery list now prints microscopic in the corner like a haunted receipt from 2004 and the password cannot still be waffles42 because that was supposed to change after the router incident
    Output: Whoever keeps logging into the printer dashboard at 3 in the morning needs to stop changing the paper size to Legal, because every grocery list now prints microscopic in the corner like a haunted receipt from 2004. The password cannot still be `waffles42`, because that was supposed to change after the router incident.

    Input: for database stuff make table payments payment_id acct_id subtotal tax_amount total_amount refunded_at status except refunds should preserve original totals for reporting unless refund_reason equals fraud or duplicate charge and dont hard delete anything because finance got mad about that like tuesday maybe wednesday
    Output: Make table `payments`. Fields:
    - `payment_id`
    - `acct_id`
    - `subtotal`
    - `tax_amount`
    - `total_amount`
    - `refunded_at`
    - `status`

    Refunds should preserve original totals for reporting unless `refund_reason` is "fraud" or "duplicate_charge". Don't hard-delete anything (finance got mad about that, like... Tuesday? Maybe Wednesday).

    Input: okay wait before i forget check whether my flight is friday at 6 15 am or 6 50 because the calendar says one thing but the confirmation email says another unless that was the boarding time actually
    Output: Okay, before I forget, check whether my flight is Friday at 6:15 a.m. or 6:50, because the calendar says one thing but the confirmation email says another. Unless that was the boarding time, actually.

    Input: if seat 14C is still available grab it not 14B because last time the charger only worked on the left side somehow or maybe right side no wait left
    Output: If seat 14C is still available, grab it, not 14B, because last time the charger only worked on the left side somehow (or maybe the right side? No, wait, left).

    Input: they failed it twice for two completely different reasons first evap thing then later system not ready which sounds fake honestly
    Output: It failed twice for two completely different reasons:
    1. The evap thing.
    2. \u{201C}System not ready\u{201D} (which sounds fake, honestly).

    Input: also check if the aquarium light is supposed to blink green every eleven seconds because the fish started hiding after i changed the timer from 6 45 to 7 15 except maybe that was pm not am
    Output: Also, check if the aquarium light is supposed to blink green every 11 seconds, because the fish started hiding after I changed the timer from 6:45 to 7:15 (except maybe that was p.m., not a.m.).

    Input: laptop battery dropped from twenty eight percent straight to four again while exporting video unless it stays plugged into usb c port two not port one which sounds backwards honestly
    Output: Laptop battery dropped from 28% straight to 4% again while exporting video, unless it stays plugged into USB-C port 2, not port 1, which sounds backwards, honestly.

    Input: for database stuff make table payments payment underscore id acct underscore id subtotal tax amount total amount refunded at status except refunds should preserve original totals for reporting unless refund reason equals fraud or duplicate charge and dont hard delete anything because finance got mad about that like tuesday maybe wednesday
    Output: Make table `payments`. Fields:
    - `payment_id`
    - `acct_id`
    - `subtotal`
    - `tax_amount`
    - `total_amount`
    - `refunded_at`
    - `status`

    Refunds should preserve original totals for reporting unless `refund_reason` is "fraud" or "duplicate_charge". Don't hard-delete anything (finance got mad about that, like Tuesday, maybe Wednesday).

    Input: find that reddit thread comparing lisbon slash seoul slash mexico city for remote work not the giant spreadsheet one save comments about internet outages fake apartment listings deposits paid over telegram and landlords asking for cash only
    Output: Find that Reddit thread comparing Lisbon, Seoul, Mexico City for remote work. Not the giant spreadsheet one. Save comments about:
    - Internet outages
    - Fake apartment listings
    - Deposits paid over Telegram
    - Landlords asking for cash only

    Input: also laptop battery dropped from twenty eight percent straight to four again while exporting video unless it stays plugged into usb c port two not port one which sounds backwards honestly so figure out whether thats battery wear firmware dock issue or power settings and if repair estimate is over 350 before tax just replace the whole thing but not the 13 inch model because the keyboard feels tiny and the slash key keeps moving around
    Output: Laptop battery dropped from 28% straight to 4% again while exporting video, unless it stays plugged into USB-C port 2, not port 1, which sounds backwards, honestly. Figure out whether that's battery wear, firmware, dock issue, or power settings. If the repair estimate is over $350 before tax, just replace the whole thing, but not the 13-inch model, because the keyboard feels tiny and the slash key keeps moving around.

    Input: oh and find that reddit thread comparing lisbon slash seoul slash mexico city for remote work not the giant spreadsheet one save comments about internet outages fake apartment listings deposits paid over telegram and landlords asking for cash only
    Output: Find that Reddit thread comparing Lisbon, Seoul, Mexico City for remote work. Not the giant spreadsheet one. Save comments about:
    - Internet outages
    - Fake apartment listings
    - Deposits paid over Telegram
    - Landlords asking for cash only

    Input: send alex running late traffic near I-10 completely stopped again might be there 7 40 ish so order without me if everybody already sat down
    Output: Send Alex: \u{201C}Running late, traffic near I-10 completely stopped again. Might be there around 7:40-ish, so order without me if everybody already sat down.\u{201D}

    Input: support email was maybe admin dash temp at northgate dash help dot net or admin dot temp at northgate dash help dot net whichever one bounced less and serial thing was A9 Q2 7B 44 slash 44B wait no ignore that last part probably
    Output: Support email was maybe `admin-temp@northgate-help.net` or `admin.temp@northgate-help.net`, whichever bounced less. Serial: `A9-Q2-7B-44` (ignore the last part).

    == HALLUCINATION BAN (CRITICAL) ==
    NEVER invent or substitute a word that wasn't in the input. If a token looks like a valid English word, KEEP IT EXACTLY. The model has been observed to invent garbage like "observability" → "obversibility", "let's" → "lots", or to mangle proper nouns it doesn't recognize. Default rule: when in doubt, leave the spelling alone.
    - "observability" stays "observability", NEVER "obversibility" / "observibility"
    - "Claude" stays "Claude", NEVER "clot" / "cloud" / "Clyde"
    - "Snow Strippers" stays "Snow Strippers", NEVER "Snowstrippers" / "Snowstrip"
    - "Netspend" stays "Netspend", NEVER "Net spent" / "Net spend"
    - "Sleigh Bells" stays "Sleigh Bells", NEVER "Jago" / "Slay Bells"
    Proper nouns and artist/band names from the input must be preserved character-for-character. Do not "correct" capitalization on multi-word band names ("Snow Strippers" is two words; do not glue them).

    == URL PRESERVATION (CRITICAL) ==
    URLs already in compact form (github.com/owner/repo, example.com/path) must be preserved EXACTLY. Never add stray words, slashes, or spaces inside a URL. If the input has "github.com/openai/whisper" or even "github.com slash openai slash whisper", output a clean URL. Never duplicate the word "slash" inside the path.
    - Input: github.com slash openai slash whisper  →  Output: github.com/openai/whisper
    - Input: github.com/openai/whisper              →  Output: github.com/openai/whisper (unchanged)
    NEVER produce "github.com/slash openai/slash whisper". The word "slash" must be replaced by the character, not duplicated.

    == NUMBER PRESERVATION (CRITICAL) ==
    Numbers and money phrases that are ALREADY normalized (e.g. "$12.5 million", "9:30 AM", "v2.1.7", "3, 2, 1") must be preserved EXACTLY. Never re-expand them. Never inflate "$12.5 million" into "$12500000". Million / billion / k stay as words or letters (M / B / K), never as raw zeros.
    - "$12.5 million" stays "$12.5 million", NEVER "$12500000" / "12 point $5000000"
    - "9:30 AM" stays "9:30 AM", NEVER "39am" / "930 AM"
    - "v2.1.7" stays "v2.1.7", NEVER "version 2 1 7"
    - "3, 2, 1" stays "3, 2, 1", NEVER "321"

    == PARAGRAPH BREAKS ==
    - If the dictation shifts topic, finishes a thought before starting a new one, or runs longer than ~3 sentences, insert a blank line ("\\n\\n") between paragraphs.
    - Do not force breaks where the speaker stays on one topic.
    - Preserve any "\\n\\n" already in the input — they came from the rule-based pre-processor and represent real topic shifts.

    == Structural formatting (when content warrants it) ==
    - You MAY use paragraph breaks (\n\n) when the speaker clearly transitions topics.
    - You MAY use bullet lists (single newline + "- " prefix) when the speaker enumerates items.
    - You MAY use inline code (backticks) for technical identifiers, field names, snake_case names, URLs, file paths, version numbers, and code-style tokens.
    - You MAY use quote marks for messages-within-messages the speaker is dictating (e.g., "send Maya: <quoted text>").
    - Default is plain prose. Use structural markup ONLY when the content actually warrants it.
    - Inline code candidates: snake_case (foo_bar), URLs (github.com/...), file paths (/Users/...), version numbers (v1.2.3), CLI flags (--verbose).
    - LIST-EMIT SIGNAL: when the speaker says "with X, Y, Z" or "with: X, Y, Z, A" after introducing a structure (table, schema, form, list, config), emit each item as its own bulleted line with the identifier in backticks.
    - PARAGRAPH-EMIT SIGNAL: when the speaker shifts topic ("also", "next", "and then", or a clearly new subject), emit a blank line (\n\n) before continuing.
    - QUOTED-MESSAGE SIGNAL: when the speaker dictates a message to someone ("send Maya this: ...", "tell him: ...", "the message is: ..."), emit the quoted text in straight or curly quotes on its own paragraph.
    - For LONG ramble (>150 words) with multiple distinct topics, RESTRUCTURE aggressively: break into paragraphs by topic, extract enumerations as bullets, wrap technical tokens in backticks. The output may be much shorter and visually richer than the input.

    == ABSOLUTE RULE: Punctuation (highest priority) ==
    - NEVER use em-dashes (\u{2014}) or en-dashes (\u{2013}).
    - If the spoken input had a pause that would warrant a dash, use a comma, period, or parentheses instead.
    - This rule overrides all other style guidance. Output containing \u{2014} or \u{2013} will be rejected.

    Output ONLY the corrected text. No explanation, no preamble, no quotes around output, no thinking.
    """


    nonisolated private static let warmupPrompt: String = """
    /no_think
    Context: general prose
    Input: hello world
    Output:
    """

    // MARK: - Style / cleanup instruction helpers (Bug 3 + Bug 4)

    /// Per-style personality instruction block. Injected into BOTH the single-
    /// model polish prompt and the merge prompt so user-facing style pickers
    /// take effect on every code path.
    ///
    /// Bug 3: rewrites are intentionally dramatic so a 1.7B model can actually
    /// follow them. The previous "be casual" style instruction was too weak
    /// to overcome the system block's "match speaker register" default.
    nonisolated private static func personalityInstruction(_ style: String?) -> String {
        // Section H: sharper, more differentiated prompts. Every personality
        // ends with the same absolute-rules tail so the 1.7B / 4B model gets
        // hammered with no-emoji / no-dash / no-fabrication on every call.
        //
        // Phase 11: context-aware + anti-AI-tell. Every preset now reads the
        // emotional weight of the content (somber vs. upbeat) and bans the
        // dead-giveaway AI phrasings ("I'd be happy to", "delve into", meta
        // commentary, hedging openers, sign-offs). Output must sound like a
        // human typed it, not like an assistant cleaned it up.
        let absoluteTail = " ABSOLUTE: no emojis, no em-dashes (\u{2014}), no en-dashes (\u{2013}), no invented content."

        // Shared anti-AI-tell block. Compact form so every preset fits the
        // ~800-char budget. The model gets the same ban list every call,
        // which compounds the signal across paragraphs.
        let antiAI = " BAN AI-tells: no 'I'd be happy to' / 'Certainly,' / 'Of course,' / 'I hope this helps' / 'Feel free to' / 'delve' / 'leverage' / 'facilitate' / 'utilize' / 'It seems' / 'Here is the'. No opener 'So,'/'Well,'/'To summarize,'. No sign-off 'Let me know'/'Hope that helps'/'Thanks'. Never paraphrase."

        switch style?.lowercased() {
        case "neutral", nil:
            return "Style: NEUTRAL. Copy the speaker's register exactly — same word choices, same contractions, same energy. Fix errors silently. Do not formalize, casualize, or editorialize. Output reads like the speaker typed it themselves. Preserve `!` exclamation marks when the speaker's energy clearly warranted them in the raw input (e.g., \"Ew!\", \"It's annoying!\")." + antiAI + absoluteTail

        case "formal":
            return "Style: FORMAL. Professional register throughout. Expand every contraction (don't→do not, I'm→I am, we'll→we will). Replace slang (yeah→yes, gonna→going to, wanna→want to, kinda→rather). Full grammatical sentences. No exclamation marks unless quoting someone. If content is clearly a casual text to a friend, keep full sentences but drop the stiffest formality." + antiAI + absoluteTail

        case "casual":
            return "Style: CASUAL. Keep the speaker's raw voice. Preserve their contractions, slang, short sentences. 'yo', 'yeah', 'gonna', 'kinda', 'tbh', 'ngl' are fine — keep them if the speaker used them. Short punchy clauses over long compound ones. Drop 'um/uh' but keep the rhythm. If content is serious (medical, professional, bad news), soften slang ('yo'→'hey') but keep the casual structure." + antiAI + absoluteTail

        case "excited":
            return "Style: EXCITED. Bring energy to good news, plans, ideas, wins. Punchy sentences. Keep exclamation marks where they fit. HARD STOP: if content is somber, factual, medical, or emotionally heavy — no exclamation marks, no amplification, flat professional tone. Never fake excitement. Never add energy that wasn't in the source." + antiAI + absoluteTail

        default:
            return "Style: NEUTRAL. Match the speaker's register exactly." + antiAI + absoluteTail
        }
    }

    /// Per-level cleanup instruction block. Injected into BOTH polish and
    /// merge prompts.
    ///
    /// Bug 4: HIGH mode is now unmistakably aggressive so the model actually
    /// restructures instead of doing surface-only edits.
    nonisolated private static func cleanupInstruction(_ level: String?) -> String {
        switch level?.lowercased() {
        case "none":
            return "Cleanup mode: NONE. Output the input text verbatim. Do not edit, polish, or change anything except trivial whitespace fixes."

        case "light":
            return "Cleanup mode: LIGHT. Strip obvious fillers (um, uh, like, you know) at clause boundaries. Capitalize sentence starts. Add basic punctuation. Do not restructure sentences. Do not change word choice."

        case "high":
            return """
            Cleanup mode: HIGH (deep rewrite, prose-grade output).
            Target: reads like the speaker wrote it down deliberately, not dictated.

            REQUIRED transformations:
            - OPENER FILLERS: Strip ONLY these exact discourse openers at the very start: "okay so", "okay hey", "hey so", "alright so", "so basically", "i mean", "you know". Do NOT strip "I think", "I want", "I need", "We should", "maybe", "probably" — those are content. Example: "okay hey i mean send john a message" → "Send John a message." NEVER: "i think we should push the deadline" → keep as is (not an opener, it's the content).
            - CHAINED SELF-CORRECTIONS: Follow the ENTIRE correction chain to the final intent. Each "no wait", "no actually", "no he knows", "scratch that", "never mind", "forget that", "I meant", "actually" replaces everything before it ONLY WHEN it is a clear restatement, not mere doubt. The LAST thing the speaker says is the ONLY thing that counts — ALL prior attempts are discarded completely. EXAMPLE: "send maya a message no wait actually message john saying we're running late no he already knows say we're already at the restaurant" → "Send John a message saying we're already at the restaurant." (three layers, only final kept). EXAMPLE: "call sarah no wait email sarah no actually slack sarah" → "Slack Sarah." EXAMPLE: "remind me to buy milk no wait eggs no actually both milk and eggs no scratch that i just need to buy bread and butter for tomorrow morning" → "Remind me to buy bread and butter for tomorrow morning." (four layers — 'scratch that' resets to bread and butter, ALL earlier items gone). CRITICAL: even if an intermediate step adds something ("both milk and eggs"), a subsequent "scratch that" or "no" wipes the entire slate clean and ONLY the final intent survives.
              CRITICAL EXCEPTION — UNCERTAINTY LANGUAGE IS NOT A CORRECTION: "I'm not sure", "I think", "maybe", "probably", "I'm not confident" express doubt — they do NOT override or erase the statement they follow. "push the deadline, I'm not sure" → "push the deadline. I'm not sure." (BOTH preserved, not collapsed to either one). "we should go left, I think" → "We should go left, I think." NEVER strip uncertainty markers.
            - NUMBER CORRECTIONS: When the speaker gives a number/quantity then corrects it with "actually", "no wait", "no", or "I mean" + a DIFFERENT number, ALWAYS collapse to the final value. The second number wins. Apply to inline corrections too — not just at clause boundaries.
              Examples: "three thirty actually four" → "4". "eighty kilos no wait seventy five" → "75 kg". "four hundred milligrams no six hundred milligrams" → "600mg". "two thousand four hundred no two thousand three hundred and fifty" → "$2,350". "at eighty, no wait seventy-five" → "75". "fourteen percent no twelve point five percent" → "12.5%". "sixty no sixty-five kilos" → "65 kg". Drop the abandoned value entirely — do not keep both or write "X to Y".
            - NUMERIC FORMATTING: Convert ALL spoken numbers to digits. This includes workout stats, currency, measurements, counts, percentages. "four sets of eight" → "4 sets of 8". "seventy-five kilos" → "75 kg". "thirty three point five million" → "$33.5 million". "eight hundred k" → "$800K". "twelve thousand" → "12,000". "one thirty to one forty-five" → "130–145". Never leave a measurement or quantity as a spelled-out word when it could be a digit.
            - TECHNICAL IDENTIFIERS (URL/EMAIL/PATH RECONSTRUCTION): When the speaker spells out a URL, email address, or file path verbally, reconstruct the proper format. Signals: "slash slash"→"//", "colon slash slash"→"://", "dot" between domain parts→".", "at" between username and domain→"@", "underscore" in identifiers→"_", "dash"→"-". Examples: "postgres slash slash admin at db dot staging dot example dot com slash myapp underscore staging" → "postgres://admin@db.staging.example.com/myapp_staging". "admin at example dot com" → "admin@example.com". "https colon slash slash api dot example dot com slash v two" → "https://api.example.com/v2". Output each reconstructed identifier in backticks.
            - LIST RECOGNITION: When the speaker enumerates items in two or more categories (e.g. groceries then errands, pros then cons, work items then personal items), format as labeled bullet lists with each category as a plain label ("Groceries:" not "**Groceries:**"). Within each bullet, collapse any corrections ("milk no wait oat milk" → "oat milk"). Each item is a single clean bullet — no correction markers, no "no wait" visible in the output.
            - PARAGRAPHS: Insert a blank line between every topic shift. Topic markers include "but at some point", "and also", "one more thing", "anyway", "speaking of", "on a related note", or any pivot to a new subject. Each paragraph is one coherent thought. Typical multi-topic dictation produces 3-5 paragraphs.
            - STUTTERS & ABANDONED RESTARTS: Collapse all restarts and false starts. "I need to pick up d the dro I need to pick up the" becomes "I need to pick up the". Drop abandoned word fragments entirely. If the speaker re-states a clause, keep only the final attempt.
            - DISFLUENCY CLUSTERS: Collapse repeated/uncertain spans into the final intent. "it's already up? Yeah? Already yeah it's already past that" becomes "it's already past that". Pick the speaker's last clear formulation.
            - TENSE CONSISTENCY: If the speaker is narrating past events ("I woke up", "I forgot"), keep the entire narrative in past tense. Fix accidental tense drift ("I just make coffee" becomes "I just made coffee").
            - SENTENCE BOUNDARIES: Break run-ons at natural clause boundaries. No sentence should exceed ~25 words unless inside a quote. Two independent clauses joined by ZERO punctuation MUST receive a period or comma between them. Example: "like some clipping happening we probably have to fix that" → "like some clipping happening. We probably have to fix that." "X happening we probably" → "X happening. We probably".
            - WEAK CONNECTORS: Replace dangling "and"/"so"/"like" between independent clauses with proper punctuation (period, comma, or paragraph break).
            - COMPOUND WORDS: "cam site" becomes "campsite", "noise cancelling" becomes "noise-cancelling".
            - PROPER NOUNS: Capitalize names, places, months, days, brands (Jake, August, Monday, Apple).
            - SCHEMA FIELDS: When the speaker says "create/make [a] table/schema X [with fields] field1 field2 field3", format each spoken field name as a snake_case identifier wrapped in backticks, listed inline comma-separated after a colon. "create users table user id email password hash created at" → "Create users table: `user_id`, `email`, `password_hash`, `created_at`". Words become snake_case: "user id" → `user_id`, "created at" → `created_at`, "last login at" → `last_login_at`. This overrides word-preservation for field names in schema context.
            - QUARTER ABBREVIATIONS: "q one" → "Q1", "q two" → "Q2", "q three" → "Q3", "q four" → "Q4".

            PROHIBITED:
            - Adding factual claims, opinions, or information not in the source
            - Changing the speaker's intent, conclusion, or emotional register
            - Paraphrasing or summarizing — every concrete detail and qualifier must survive
            - Em-dashes or en-dashes (use periods, commas, or paragraph breaks)
            - Emojis or decorative punctuation
            - Bullet points unless the speaker is explicitly enumerating discrete items

            Preserve verbatim: numbers, names, URLs, emails, quoted phrases.
            Output is measurably tighter than the input, but every meaningful clause survives.
            """

        default:
            // "medium" / nil / unrecognized → moderate cleanup with light restructuring.
            return """
            Cleanup mode: MEDIUM.
            REQUIRED:
            - Strip fillers (um, uh, like, you know) at clause boundaries
            - Normalize capitalization and punctuation
            - Fix obvious grammar errors, proper nouns, and homophones from context
            - Break run-on sentences into separate sentences
            - Drop filler clauses that add no content
            PROHIBITED:
            - Adding factual claims or changing speaker intent
            - Em-dashes or en-dashes (use periods or commas)
            - Paraphrasing — every meaningful clause survives
            Output is cleaner than the input but preserves the speaker's voice and rhythm.
            """
        }
    }

    // MARK: - Sentence boundary counting (Section B)

    /// Count `.`/`!`/`?` characters that represent real sentence boundaries.
    /// Excludes:
    ///   - dots inside known abbreviations (Dr., Mr., Inc., e.g., i.e., U.S., etc.)
    ///   - ellipses (runs of 2+ dots collapse to one boundary, not three)
    ///   - decimals (e.g. 3.14, $2.5M)
    ///   - dots adjacent to private-use placeholder characters (U+E000..U+F8FF)
    ///     which the rule-based pre-processor uses to mask URLs/emails
    nonisolated private static func countSentenceBoundaries(in text: String) -> Int {
        // 1. Pre-process: scrub out things that LOOK like sentence boundaries
        //    but aren't, then count what remains.
        var t = text

        // Abbreviation patterns — strip the trailing dot so it doesn't count.
        // \\b(Dr|Mr|Mrs|Ms|Jr|Sr|St|Prof|Inc|Ltd|Co|Corp|U\\.S|U\\.K|e\\.g|i\\.e|etc|vs)\\.
        let abbrPattern = #"\b(Dr|Mr|Mrs|Ms|Jr|Sr|St|Prof|Inc|Ltd|Co|Corp|U\.S|U\.K|e\.g|i\.e|etc|vs)\."#
        if let rx = try? NSRegularExpression(pattern: abbrPattern, options: .caseInsensitive) {
            let range = NSRange(t.startIndex..., in: t)
            t = rx.stringByReplacingMatches(in: t, range: range, withTemplate: "$1")
        }

        // Ellipsis: collapse runs of 2+ dots to a single dot (one boundary).
        t = t.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
        // Bang/question runs: "hello!!!" / "really???" = 1 boundary, not 3.
        t = t.replacingOccurrences(of: #"!{2,}"#, with: "!", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\?{2,}"#, with: "?", options: .regularExpression)
        // Mixed punctuation runs like "?!" / "!?" = 1 boundary.
        t = t.replacingOccurrences(of: #"[!?]{2,}"#, with: "!", options: .regularExpression)

        // Numeric decimals: 3.14, $2.5 — strip the dot.
        t = t.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1$2", options: .regularExpression)

        // 2. Count remaining sentence enders, skipping any dot/!/? that is
        //    immediately preceded or followed by a private-use placeholder
        //    character (the pre-processor masks URLs/emails into these so
        //    their internal dots survive polish).
        //    Also skip any dot whose adjacent characters are BOTH letters
        //    (e.g. "U.S", "e.g", "api.openai.com", residual internal dots
        //    inside multi-letter abbreviations not covered by the pattern
        //    above, hostnames, and code-style identifiers). These were the
        //    silent source of off-by-N drift in word-budget math.
        let privateUseRange: ClosedRange<Unicode.Scalar> = "\u{E000}"..."\u{F8FF}"
        let scalars = Array(t.unicodeScalars)
        var count = 0
        for (i, scalar) in scalars.enumerated() {
            guard scalar == "." || scalar == "!" || scalar == "?" else { continue }
            let prev = i > 0 ? scalars[i - 1] : nil
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if let p = prev, privateUseRange.contains(p) { continue }
            if let n = next, privateUseRange.contains(n) { continue }
            // Dot sandwiched between letters → not a sentence boundary
            // ("api.openai.com", "U.S", "e.g" residuals). Bangs / question
            // marks DO end sentences even between letters, so only apply
            // the letter-sandwich exclusion to `.`.
            if scalar == "." {
                let prevIsLetter = prev.map { CharacterSet.letters.contains($0) } ?? false
                let nextIsLetter = next.map { CharacterSet.letters.contains($0) } ?? false
                if prevIsLetter && nextIsLetter { continue }
            }
            count += 1
        }
        return count
    }

    // MARK: - Prompt-injection sanitizer (Section C)

    /// Strip control sequences a malicious or accidental input could use to
    /// hijack the prompt, collapse newlines to a single space, and truncate.
    /// Applied to every untrusted string interpolated into the LLM prompt
    /// (fieldContext, vocabulary terms, suspect words, rolling context).
    nonisolated private static func sanitizeUntrustedField(_ s: String, maxChars: Int = 200) -> String {
        var out = s
        let tokens = [
            "<|", "|>", "<<<", ">>>",
            "<think>", "</think>",
            "<system>", "</system>",
            "<|im_start|>", "<|im_end|>",
        ]
        for t in tokens {
            out = out.replacingOccurrences(of: t, with: "")
        }
        // Collapse all newline/CR runs to a single space.
        out = out.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
        // Collapse runs of internal whitespace.
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if out.count > maxChars {
            out = String(out.prefix(maxChars))
        }
        return out
    }

    // MARK: - Dash stripping (Bug 1b)

    /// Post-polish hard scrub of em-dashes (U+2014) and en-dashes (U+2013).
    /// Even with the system-prompt ABSOLUTE RULE, Qwen3 occasionally still
    /// emits a stray dash. This is the last line of defense before the text
    /// reaches the user. Surrounding-space variants are normalized first so
    /// "word \u{2014} word" collapses to "word, word" without doubled commas.
    nonisolated private static func stripDashes(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: " \u{2014} ", with: ", ")
        t = t.replacingOccurrences(of: " \u{2013} ", with: ", ")
        t = t.replacingOccurrences(of: "\u{2014}", with: ", ")
        t = t.replacingOccurrences(of: "\u{2013}", with: "-")
        // Collapse comma-spam from the substitution.
        t = t.replacingOccurrences(of: ", ,", with: ",")
        t = t.replacingOccurrences(of: ",,", with: ",")
        t = t.replacingOccurrences(of: " ,", with: ",")
        return t
    }

    // MARK: - Sanitizer (ported from LLMPolisher)

    // BUGFIX (Category 1 — sanitizer over-rejection): suspect-words signal
    // that ASR misheard tokens. The polish is EXPECTED to drift more (e.g.
    // "Yoat Houst" 2 words → "Yo, quick test" 3 words). We pass suspectWords
    // through to sanitize so it can relax word/length budgets when a known
    // confusable is present and the polish produces a reasonable English
    // sentence. Default arg keeps existing call sites compiling.
    //
    // Bug 5: `cleanupLevel` now threads through so drift tolerance scales
    // with how aggressive the rewrite is allowed to be:
    //   none:   ±5%   (essentially identity)
    //   light:  ±15%
    //   medium: ±30%  (previous default)
    //   high:   ±60%
    // NOTE: Long, structurally-rich dictations exceed what Qwen3-1.7B handles
    // reliably. For dictations >300 words with list/code/quote signals, consider
    // routing to a larger model (Qwen3-4B-4bit) or chunking by paragraph.
    // Current behavior: best-effort with the local 1.7B.
    nonisolated private static func sanitize(_ output: String, original: String, vocabulary: [String]? = nil, suspectWords: [String]? = nil, cleanupLevel: String? = "medium") -> String {
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
        // Collapse double-dollar runs ($$ or longer) to a single $. Pre-formatter
        // emits "$400" but the model occasionally prepends another "$" because
        // it sees "dollars" / "bucks" in the source and inserts a sign of its
        // own. Always collapse — there is no legitimate "$$" token in dictation.
        if cleaned.contains("$$") {
            cleaned = cleaned.replacingOccurrences(of: #"\${2,}"#, with: "$", options: .regularExpression)
            print("[VOICE-LP] collapsed $$ to $")
        }
        // Trailing hallucination guard. Qwen3 sometimes appends " yeah?" / " right?"
        // / " ok?" to a polished sentence even when the raw transcript had no such
        // trailing token. Strip them when the original's last ~6 words don't contain
        // the token in question. Cheap, conservative, log every action.
        let trailingHallucinations: [String] = [
            " yeah?", " yeah?\"", " right?", " ok?", " okay?", " yeah.", " right.",
            " yeah", " right",
        ]
        let origTailLower = original
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(6)
            .joined(separator: " ")
        for token in trailingHallucinations {
            let trimToken = token.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "?", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "\"", with: "")
            // Only consider stripping if the token is NOT in the original tail.
            if origTailLower.contains(trimToken) { continue }
            // Compare with a flexible suffix match (handles smart-quote / dot variants).
            let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedLowerTrim = cleanedTrimmed.lowercased()
            if cleanedLowerTrim.hasSuffix(token.trimmingCharacters(in: .whitespaces).lowercased()) {
                let cutoff = cleanedTrimmed.count - token.trimmingCharacters(in: .whitespaces).count
                if cutoff > 0 {
                    var newTail = String(cleanedTrimmed.prefix(cutoff))
                        .trimmingCharacters(in: .whitespaces)
                    if newTail.hasSuffix(",") {
                        newTail = String(newTail.dropLast()).trimmingCharacters(in: .whitespaces)
                    }
                    // Ensure terminal punctuation.
                    if let last = newTail.last, !".!?\u{201D}\"'".contains(last) {
                        newTail += "."
                    }
                    print("[VOICE-LP] trimmed trailing hallucination: \(token)")
                    cleaned = newTail
                    break
                }
            }
        }
        // Strip a leading "Output:" echo (model occasionally repeats the prompt marker).
        // Also handle variants with spacing like "Output :" or extra whitespace.
        let outputPrefixPattern = #"^output\s*:\s*"#
        if let regex = try? NSRegularExpression(pattern: outputPrefixPattern, options: .caseInsensitive) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // If the model continued past the first answer into a new "Input:" / "Output:"
        // turn, truncate at the boundary. Cheap and prevents runaway echo.
        if let cutRange = cleaned.range(of: #"\n\s*(Input|Output):"#, options: .regularExpression) {
            cleaned = String(cleaned[..<cutRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Shared lowercased original — used by both list-marker detection and
        // filler budget below. Define once here to avoid repeated work.
        let origLower = original.lowercased()

        // List-marker detection: if the original contains ≥2 sequential list
        // trigger words, the model should be producing a formatted list with
        // newlines. Allow those newlines through (don't strip them in the
        // newline-collapse step below) and grant extra word budget for list
        // prefixes like "1." "2." "3.".
        let listTriggers: [String] = [
            "first", "second", "third", "fourth", "fifth",
            "point one", "point two", "point three",
            "number one", "number two", "number three",
            "step one", "step two", "step three",
            "action item", "action items",
            "bullet point",
        ]
        var listTriggerHits = 0
        for trigger in listTriggers {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: trigger) + "\\b"
            if let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               rx.firstMatch(in: origLower, range: NSRange(origLower.startIndex..., in: origLower)) != nil {
                listTriggerHits += 1
            }
        }
        let hasListMarkers = listTriggerHits >= 2

        // Structural newline preservation: the model is now allowed to emit
        // bullet lists, paragraph breaks, and inline code (backticks) when
        // the content warrants it. We NO LONGER strip all newlines — instead
        // we collapse runs of 3+ newlines down to 2 (max one blank line
        // between paragraphs) and trim trailing whitespace on each line.
        // Single newlines are preserved so bullet lists survive.
        let originalLineCount = original.components(separatedBy: .newlines).count
        let hadSpokenNewlines = hasSpokenPunctuation(original)
        let cleanedHasStructure = cleaned.contains("\n- ") ||
                                  cleaned.contains("\n* ") ||
                                  cleaned.contains("\n\n") ||
                                  cleaned.contains("`")
        // Collapse runs of 3+ newlines down to 2 (max one blank line between paragraphs)
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        // Collapse runs of horizontal whitespace (NOT including \n) to single space
        cleaned = cleaned.replacingOccurrences(of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = (originalLineCount, hadSpokenNewlines, cleanedHasStructure) // referenced for diagnostic clarity

        // Structure-aware + long-input drift multipliers. When the polished
        // output contains real structural reorganization (bullet lists,
        // paragraph breaks, inline code) the legitimate word/char delta is
        // larger because the model is doing structural work, not just polish.
        // Long inputs (>200 words) also tend to drop large filler sections
        // when restructured. Both multipliers compose multiplicatively.
        //
        // Detect structural output: if the polished text contains bullet lists,
        // multiple paragraphs, or code-style backticks, drift tolerance is more
        // generous because the model is doing structural work, not just polishing.
        let hasStructure = cleaned.contains("\n- ") ||
                           cleaned.contains("\n* ") ||
                           cleaned.contains("\n\n") ||
                           cleaned.contains("`")
        let structureMultiplier: Double = hasStructure ? 1.5 : 1.0
        let inputWordCount = original.split(separator: " ").count
        let longInputMultiplier: Double = inputWordCount > 200 ? 1.5 : 1.0
        let driftMultiplier: Double = structureMultiplier * longInputMultiplier

        // Word-count drift check. Default budget = ±3 (covers ordinary
        // merges/splits like "commandonth" → "command on the"). When the cleaned
        // output introduces a canonical vocabulary term that was not present in
        // the original (i.e. the model collapsed a phonetic match like
        // "Chachi Pt" → "ChatGPT"), the legitimate delta can be larger — every
        // compressed term may save 1-2 words. Grant +2 extra budget per such hit.
        //
        // Bug 5: level-aware base word budget. HIGH lets the model rewrite,
        // so allow much larger word deltas; NONE is essentially identity.
        let originalWords = original.split { $0.isWhitespace }.count
        let cleanedWords = cleaned.split { $0.isWhitespace }.count
        let wordDelta = abs(originalWords - cleanedWords)
        var wordBudget: Int
        switch cleanupLevel?.lowercased() {
        case "none":   wordBudget = max(1, originalWords / 20)         // ±5%
        case "light":  wordBudget = max(2, originalWords * 15 / 100)   // ±15%
        case "high":   wordBudget = max(6, originalWords * 60 / 100)   // ±60%
        default:       wordBudget = max(3, originalWords * 30 / 100)   // medium / nil: ±30%
        }
        if let vocabulary, !vocabulary.isEmpty {
            let cleanedLower = cleaned.lowercased()
            let introducedTerms = vocabulary.filter { term in
                let lower = term.lowercased()
                return !lower.isEmpty
                    && cleanedLower.contains(lower)
                    && !origLower.contains(lower)
            }
            wordBudget += introducedTerms.count * 2
            if !introducedTerms.isEmpty {
                print("[VOICE] Qwen3 sanitizer: vocab terms introduced \(introducedTerms) — wordBudget extended to \(wordBudget)")
            }
        }
        // BUGFIX (Category 1 — sanitizer over-rejection): if the original had
        // any flagged suspect words (Parakeet confusables), the polish has
        // license to drift more than usual. A 2-word "Yoat Houst" → 3-word
        // "Yo quick test" correction is exactly the kind of legitimate fix
        // that previously got rejected. Grant +3 word budget and a 60%
        // length floor when suspects are present and the original is short.
        if let suspectWords, !suspectWords.isEmpty, originalWords <= 6 {
            wordBudget += 3
            print("[VOICE] Qwen3 sanitizer: suspect-word budget +3 (short utterance with \(suspectWords.count) suspects) → wordBudget=\(wordBudget)")
        }

        // Group 3a — Contraction expansion budget: "don't" → "do not" adds 1 word.
        // Section B: use a single word-boundary regex instead of substring
        // `contains`. The previous approach over-counted: "i'm" matched
        // "i'mport" / "i'ma" and other accidental substrings. \b around the
        // whole alternation gives exactly one count per legitimate contraction
        // occurrence.
        let contractionPattern = #"\b(don't|can't|won't|isn't|aren't|wasn't|weren't|hasn't|haven't|hadn't|doesn't|didn't|shouldn't|wouldn't|couldn't|i'm|i've|i'd|i'll|you're|you've|you'd|you'll|we're|we've|we'd|we'll|they're|they've|they'd|they'll|he's|she's|it's|that's|what's|let's|here's|there's)\b"#
        var contractionCount = 0
        if let rx = try? NSRegularExpression(pattern: contractionPattern, options: .caseInsensitive) {
            contractionCount = rx.numberOfMatches(in: origLower, range: NSRange(origLower.startIndex..., in: origLower))
        }
        wordBudget += contractionCount

        // Group 3b — Sentence-split budget: if polished has more sentences than original
        // (run-on → split), grant +1 word per new sentence boundary.
        // Section B: exclude abbreviation dots, ellipses, decimals, and dots
        // inside private-use placeholder runs (e.g. emails/URLs masked by the
        // pre-processor) so the counts reflect real sentence boundaries.
        let origSentenceCount = Self.countSentenceBoundaries(in: original)
        let cleanedSentenceCount = Self.countSentenceBoundaries(in: cleaned)
        if cleanedSentenceCount > origSentenceCount {
            wordBudget += (cleanedSentenceCount - origSentenceCount)
        }

        // Filler-removal budget: each filler word legitimately removed shrinks
        // the output. Grant +1 word slack per filler type detected, capped at
        // +10, so heavy filler removal doesn't trigger a false rejection.
        //
        // Section B: tightened set focused on the canonical fillers called
        // out in the spec. Word-boundary regex prevents "like" matching
        // "alike" / "likely", "literally" matching "literal", etc.
        let fillerTokens: Set<String> = [
            "you know", "like", "basically", "literally", "actually",
            "um", "uh", "i mean", "kind of", "sort of",
        ]
        var fillerHits = 0
        for f in fillerTokens {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: f) + "\\b"
            if let rx = try? NSRegularExpression(pattern: pattern),
               rx.firstMatch(in: origLower, range: NSRange(origLower.startIndex..., in: origLower)) != nil {
                fillerHits += 1
            }
        }
        let fillerBudget = min(fillerHits, 10)
        wordBudget += fillerBudget
        if fillerBudget > 0 {
            print("[VOICE] Qwen3 sanitizer: filler budget +\(fillerBudget) (detected \(fillerHits) filler types) → wordBudget=\(wordBudget)")
        }
        // List-marker budget: "1." "2." prefixes add extra words vs. prose.
        if hasListMarkers {
            let listBudget = min(listTriggerHits * 2, 12)
            wordBudget += listBudget
            print("[VOICE] Qwen3 sanitizer: list-marker budget +\(listBudget) (detected \(listTriggerHits) triggers) → wordBudget=\(wordBudget)")
        }
        // Spoken-punctuation expansions ("comma" → ",", "new paragraph" → "\n\n",
        // "period" → ".") legitimately remove a 4-15 char token per occurrence
        // without introducing vocab terms. Count the tokens in the original
        // and widen the word-delta budget accordingly so legitimate compressions
        // aren't rejected.
        let spokenPunct = hasSpokenPunctuation(original)
        if spokenPunct {
            // Conservative: +2 per likely punctuation expansion, capped at +10.
            let lower = original.lowercased()
            let tokens = ["comma", "period", "full stop", "exclamation point", "exclamation mark", "question mark", "new line", "newline", "new paragraph", "colon", "semicolon", "dash", "ellipsis", "dot dot dot", "open paren", "close paren", "in parens", "paren", "quote", "end quote", "unquote", "close quote"]
            var occurrences = 0
            for t in tokens {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: t) + "\\b"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    occurrences += regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
                }
            }
            let extra = min(occurrences * 2, 10)
            wordBudget += extra
            print("[VOICE] Qwen3 sanitizer: spoken-punctuation detected (\(occurrences) tokens) — wordBudget extended by \(extra) to \(wordBudget)")
        }
        // Apply structure + long-input drift multipliers to the word budget.
        let wordBudgetFinal = Int((Double(wordBudget) * driftMultiplier).rounded(.up))
        if wordBudgetFinal != wordBudget {
            print("[VOICE] Qwen3 sanitizer: drift multiplier \(driftMultiplier) (structure=\(hasStructure), longInput=\(inputWordCount>200)) → wordBudget \(wordBudget) -> \(wordBudgetFinal)")
        }
        guard wordDelta <= wordBudgetFinal else {
            print("[VOICE] Qwen3 polish rejected: word count drift \(originalWords)->\(cleanedWords) (delta \(wordDelta), budget \(wordBudgetFinal))")
            return original
        }

        // Length drift check — same vocabulary-aware relaxation.
        // Default 35%; expanded to 60% when a canonical term replaced garbled text,
        // because legit replacements can compress substantially ("Chachi Pt" → "ChatGPT").
        //
        // Bug 5: level-aware base length threshold mirrors the word budget.
        let lenDelta = abs(cleaned.count - original.count)
        let basePct: Int
        switch cleanupLevel?.lowercased() {
        case "none":   basePct = 5
        case "light":  basePct = 15
        case "high":   basePct = 75  // aggressive correction-chain collapsing can cut text by 70%+
        default:       basePct = 35  // medium or nil — preserves previous behavior
        }
        let baseThreshold = max(original.count * basePct / 100, 10)
        var lenThreshold = baseThreshold
        // Vocab-substitution or other expansion bumps allow ≥60% drift even
        // at medium/light levels (legitimate compressions). We detect this
        // via vocabulary presence; bumps from Bug 5 base scaling shouldn't
        // re-trigger this.
        if let vocabulary, !vocabulary.isEmpty, basePct < 60 {
            let cleanedLowerForLen = cleaned.lowercased()
            let hasVocabIntro = vocabulary.contains { term in
                let lower = term.lowercased()
                return !lower.isEmpty && cleanedLowerForLen.contains(lower) && !origLower.contains(lower)
            }
            if hasVocabIntro {
                lenThreshold = max(original.count * 60 / 100, 20)
            }
        }
        // BUGFIX (Category 1): short utterances with suspect words can legitimately
        // double in length after correction (e.g. "Yoat Houst" → "Yo, quick test.").
        if let suspectWords, !suspectWords.isEmpty, originalWords <= 6 {
            lenThreshold = max(lenThreshold, original.count + 20)
        }
        // Spoken-punctuation expansions can compress more aggressively than
        // vocab substitutions (a single "new paragraph" → "\n\n" removes 11
        // chars). Drop the threshold floor to 70% of original so the polish
        // isn't rejected for legitimate punctuation compression.
        if spokenPunct {
            lenThreshold = max(lenThreshold, original.count * 70 / 100, 20)
        }
        // List formatting legitimately changes char count more (added "1. \n2. \n" etc.).
        if hasListMarkers {
            lenThreshold = max(lenThreshold, original.count * 80 / 100, 30)
        }
        // Apply structure + long-input drift multipliers to the length threshold.
        let lenThresholdFinal = Int((Double(lenThreshold) * driftMultiplier).rounded(.up))
        if lenThresholdFinal != lenThreshold {
            print("[VOICE] Qwen3 sanitizer: drift multiplier \(driftMultiplier) applied to length threshold \(lenThreshold) -> \(lenThresholdFinal)")
        }
        guard lenDelta <= lenThresholdFinal else {
            print("[VOICE] Qwen3 polish rejected: length drift \(original.count)->\(cleaned.count) (threshold \(lenThresholdFinal))")
            return original
        }

        // Shared lowercased cleaned — used by Groups 1 and 2 below.
        let cleanedLower = cleaned.lowercased()

        // ── Group 1: Semantic flip detection ──────────────────────────────────
        // Catch cases where a negation was flipped (catastrophic, always reject).
        let criticalFlips: [(neg: String, pos: String)] = [
            ("don't think", "think"),
            ("do not think", "think"),
            ("shouldn't", "should"),
            ("should not", "should"),
            ("won't", "will"),
            ("will not", "will"),
            ("can't", "can"),
            ("cannot", "can"),
        ]
        for flip in criticalFlips {
            let origHasNeg = origLower.contains(flip.neg)
            let cleanedLostNeg = !cleanedLower.contains(flip.neg) && cleanedLower.contains(flip.pos)
            if origHasNeg && cleanedLostNeg {
                print("[VOICE] Qwen3: rejected — semantic flip '\(flip.neg)' → '\(flip.pos)'")
                return original
            }
        }

        // Negation collapse: if original has 3+ negation words and polished drops more than half.
        let negationWords = ["not", "no", "never", "don't", "doesn't", "didn't", "won't", "can't", "couldn't", "shouldn't", "wouldn't", "isn't", "aren't", "wasn't", "weren't"]
        let origNegCount = negationWords.filter { origLower.contains($0) }.count
        let cleanedNegCount = negationWords.filter { cleanedLower.contains($0) }.count
        if origNegCount >= 3 && cleanedNegCount < origNegCount / 2 {
            print("[VOICE] Qwen3: rejected — negation collapse (\(origNegCount) → \(cleanedNegCount))")
            return original
        }

        // ── Group 2: Injected content detection ──────────────────────────────
        // 2a. Stereotyped closing phrases injected by the model.
        let injectedClosings = ["let me know", "feel free to", "hope this helps", "best regards", "kind regards", "thanks for", "thank you for", "please don't hesitate", "i'm here to help", "happy to help"]
        for phrase in injectedClosings {
            if cleanedLower.contains(phrase) && !origLower.contains(phrase) {
                print("[VOICE] Qwen3: rejected — injected closing phrase '\(phrase)'")
                return original
            }
        }

        // 2b. Proper noun loss: extract capitalized words (≥4 chars, mixed case) from
        // original. If more than 2 disappear from cleaned, reject.
        // Section B: when a proper noun is ALSO a suspect word (low ASR
        // confidence), losing it is legitimate — the polish just substituted
        // a more plausible canonical spelling. Exclude suspect words from
        // the "lost" tally.
        let suspectSet: Set<String> = Set(
            (suspectWords ?? []).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        )
        let origWords = original.components(separatedBy: .whitespaces)
        let properNouns = origWords.filter { word in
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            return stripped.count >= 4 &&
                   stripped.first?.isUppercase == true &&
                   stripped.dropFirst().contains(where: { $0.isLowercase })
        }
        if properNouns.count >= 2 {
            let lost = properNouns.filter { noun in
                let stripped = noun.trimmingCharacters(in: .punctuationCharacters).lowercased()
                // Real-word substitution exception: if this token was flagged
                // as low-confidence by the ASR, the model is ALLOWED to
                // replace it. Skip such tokens in the lost-count.
                if suspectSet.contains(stripped) { return false }
                return !cleanedLower.contains(stripped)
            }
            if lost.count > 2 {
                print("[VOICE] Qwen3: rejected — lost \(lost.count) proper nouns: \(lost)")
                return original
            }
        }

        // 2c. Injected URLs or emails not present in original.
        // Match BOTH http(s):// URLs AND bare-domain paths like example.com/path
        // (TextFormatter's reconstructEmailsAndURLs emits bare domains without a scheme.)
        let urlPattern = try? NSRegularExpression(pattern: #"(?:https?://\S+|\b[a-zA-Z0-9.-]+\.(?:com|org|net|io|app|dev|co|me|gov|edu|us|uk|de|fr|ai|tech|xyz)(?:/\S*)?)"#, options: [])
        let emailPattern = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)
        func hasMatch(_ pattern: NSRegularExpression?, in text: String) -> Bool {
            guard let p = pattern else { return false }
            return p.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        // Safety net: if the original contains spoken-URL tokens, the user clearly
        // dictated a URL, so skip the injection check (Qwen3 may legitimately add scheme).
        let spokenUrlIndicators = ["dot com", "dot org", "dot net", "dot io", "dot app", "dot dev", "dot co", "dot ai", " slash "]
        let originalHasSpokenURL = spokenUrlIndicators.contains { origLower.contains($0) }
        if !originalHasSpokenURL {
            if hasMatch(urlPattern, in: cleaned) && !hasMatch(urlPattern, in: original) {
                print("[VOICE] Qwen3: rejected — injected URL")
                return original
            }
        }
        if hasMatch(emailPattern, in: cleaned) && !hasMatch(emailPattern, in: original) {
            print("[VOICE] Qwen3: rejected — injected email")
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

        // Number-degradation check. If the original already contained a clean
        // money/time/version form (produced by TextFormatter's pre-passes),
        // reject any polish that "re-expands" it into raw-zero garbage like
        // "$12500000" or stray "$5000000" tokens. The pre-pass output is the
        // canonical form — the model has no business rewriting it.
        //
        // Triggers:
        //   1. Original contains "$N[.N] million|billion|thousand|M|B|K" but
        //      cleaned introduces "$" followed by 5+ digits (raw zero blob).
        //   2. Original contains "H:MM AM|PM" but cleaned drops the colon and
        //      jams it into a single integer (e.g. "9:30 AM" → "930 AM" / "39am").
        //   3. Original contains "vN.N[.N]" but cleaned re-expands it to
        //      "version N N N" or similar.
        let bigZeroBlob = #"\$\d{5,}"#
        let originalHadMoneyMag = original.range(
            of: #"\$\d+(\.\d+)?\s*(million|billion|thousand|[MBK])\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if originalHadMoneyMag,
           cleaned.range(of: bigZeroBlob, options: .regularExpression) != nil,
           original.range(of: bigZeroBlob, options: .regularExpression) == nil {
            print("[VOICE] Qwen3 polish REJECTED: degraded money phrase (raw-zero blob introduced)")
            return original
        }
        let originalHadColonTime = original.range(
            of: #"\b\d{1,2}:\d{2}\s*(?i:AM|PM)\b"#,
            options: .regularExpression
        ) != nil
        if originalHadColonTime,
           cleaned.range(of: #"\b\d{1,2}:\d{2}\s*(?i:AM|PM)\b"#, options: .regularExpression) == nil {
            print("[VOICE] Qwen3 polish REJECTED: dropped colon from H:MM AM/PM time")
            return original
        }
        let versionPat = #"\bv\d+(\.\d+){1,3}\b"#
        if original.range(of: versionPat, options: .regularExpression) != nil,
           cleaned.range(of: versionPat, options: .regularExpression) == nil {
            print("[VOICE] Qwen3 polish REJECTED: re-expanded vN.N.N version number")
            return original
        }

        // Vulgarity-injection check (CRITICAL — Qwen3 has been observed to
        // substitute innocuous words like "check" with the vulgar "cuck",
        // which the user reasonably considers worse than no polish at all).
        // If the polished output contains a vulgar/slur word that was NOT
        // present in the original (case-insensitive, word-boundary match),
        // reject the polish entirely and return the raw stripped input.
        //
        // The list is intentionally narrow — common vulgar/slur tokens that
        // an ASR transcriber would never produce from clean speech and that
        // would never legitimately be inserted by a polish pass. We compare
        // by whole word so that legitimate substrings (e.g. "Scunthorpe")
        // don't trip the check.
        let vulgarWords: Set<String> = [
            "cuck", "fuck", "fucking", "fucked", "fucker",
            "shit", "shitty", "shitting",
            "cunt", "bitch", "bastard",
            "nigger", "nigga", "faggot", "fag", "retard", "retarded",
            "asshole", "dick", "cock", "pussy", "twat", "whore", "slut"
        ]
        func wordSet(_ s: String) -> Set<String> {
            return Set(s.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init))
        }
        let originalWordSet = wordSet(original)
        let cleanedWordSet = wordSet(cleaned)
        let introducedVulgar = vulgarWords.intersection(cleanedWordSet).subtracting(originalWordSet)
        if !introducedVulgar.isEmpty {
            print("[VOICE] Qwen3 polish REJECTED: introduced vulgar word(s) not in original: \(introducedVulgar). raw=\(original.prefix(80)) polish=\(cleaned.prefix(80))")
            return original
        }

        return cleaned
    }

    // MARK: - Confidence hint builder (shared by polish and merge paths)

    /// Build the `?word→[alt1, alt2, alt3]` confidence block from a list of
    /// low-confidence ASR tokens. Called by both `polishWithMLX` and the merge
    /// path so both use the same phonetic-alternatives format.
    nonisolated static func buildSuspectHints(_ suspects: [String], userVocabulary: [String]?) -> String {
        guard !suspects.isEmpty else { return "" }
        let candidateVocab = (userVocabulary ?? []) + Self.knownProductNames
        let vocabCodes: [(term: String, codes: [String])] = candidateVocab.map { term in
            let codes = term.split(whereSeparator: { !$0.isLetter })
                .map { Self.soundex(String($0)) }
                .filter { !$0.isEmpty }
            return (term, codes)
        }
        struct Scored { let term: String; let score: Int }
        var lines: [String] = []
        for raw in suspects.prefix(8) {
            let cleanWord = Self.sanitizeUntrustedField(raw, maxChars: 60)
            guard !cleanWord.isEmpty else { continue }
            let suspectCode = Self.soundex(cleanWord)
            var scored: [Scored] = []
            for v in vocabCodes {
                var best = 0
                for vc in v.codes {
                    if vc == suspectCode { best = max(best, 4) }
                    else if vc.prefix(3) == suspectCode.prefix(3) && vc.count >= 3 { best = max(best, 2) }
                    else if vc.first == suspectCode.first { best = max(best, 1) }
                }
                if best > 0 { scored.append(Scored(term: v.term, score: best)) }
            }
            let top = scored.sorted { $0.score > $1.score }.prefix(3).map(\.term)
            var seen = Set<String>()
            var ordered: [String] = []
            for c in ([cleanWord] + top) where seen.insert(c.lowercased()).inserted { ordered.append(c) }
            lines.append("?\(cleanWord)→[\(Array(ordered.prefix(3)).joined(separator: ", "))]")
        }
        guard !lines.isEmpty else { return "" }
        var out = "Uncertain words (low ASR confidence. first is what was heard, brackets list phonetically similar canonical spellings, pick the right one or keep as-is):\n"
        out += lines.joined(separator: "\n") + "\n"
        if lines.count >= 3 {
            out += "NOTE: This dictation has multiple low-confidence words. The speaker may be mumbling or speaking softly. Prioritize semantic coherence over verbatim preservation when a suspect word does not fit the sentence. If a candidate from the [alt1, alt2, alt3] list makes the sentence parse cleanly, prefer it.\n"
        }
        return out
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
