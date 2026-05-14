// VOICE — Transcription Service (FluidAudio / Parakeet TDT 0.6B v3)
// ============================================================
// Matches macparakeet's architecture exactly:
//   prepare()       — downloads + pre-warms AsrManager once at launch
//   start()         — instant: just resets state, no model loading
//   feed()          — no-op: audio is captured to file by AudioCaptureService
//   stop()          — resets state only; returns []. Caller must call transcribeFile().
//   transcribeFile() — passes URL directly to FluidAudio (fastest path, no manual
//                     resampling or [Float] intermediate). ~150ms for any length.
//
// WHY URL-based transcription:
//   manager.transcribe(url:) lets FluidAudio handle file reading, format conversion,
//   and chunking internally. Passing [Float] requires manual resampling + a large
//   array copy across the actor boundary. The URL path is what macparakeet uses.
//
// WHY no accumulation in feed():
//   AudioCaptureService already writes captured 16kHz mono PCM to a .caf file
//   (via startWritingToFile). RecordingCoordinator calls transcribeFile(url:) on
//   that file after stop(). No double-buffering needed.
// ============================================================

import Foundation
import AVFoundation
import FluidAudio

@Observable
final class TranscriptionService: TranscriptionEngine {
    // MARK: - Public state

    var modelState: ModelState = .notDownloaded
    var isReady = false
    var lastError: String?

    // MARK: - Partial-text stream

    /// Each emission is the cumulative best-guess transcript so far (not a delta).
    let partialText: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation

    // MARK: - FluidAudio handles

    /// Exposed so RecordingCoordinator can share the already-loaded models
    /// with SlidingWindowAsrManager for the live-partials path. The models
    /// are safe to share — they're read-only after loadModels().
    private(set) var asrModels: AsrModels?

    /// Single pre-warmed batch engine reused for all transcription calls.
    /// loadModels() runs once at prepare() — CoreML compiles once, all subsequent
    /// calls reuse the compiled model cache.
    private var batchManager: AsrManager?
    private var batchDecoderLayerCount: Int = 0

    // MARK: - Session state

    private var sessionStart: Date?

    // MARK: - Init / deinit

    init() {
        var continuation: AsyncStream<String>.Continuation!
        self.partialText = AsyncStream { continuation = $0 }
        self.partialContinuation = continuation
    }

    deinit {
        partialContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Download (if needed) and load Parakeet TDT 0.6B v3. Called once at launch.
    func prepare() async throws {
        guard !isReady else { return }
        modelState = .downloading(progress: 0)

        do {
            // Time downloadAndLoad to detect first-ever launch (CoreML compile).
            let downloadStart = Date()
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.modelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )
            let wasFirstLoad = Date().timeIntervalSince(downloadStart) > 5.0
            self.asrModels = models
            modelState = .loading

            // Pre-warm once. CoreML compiles the model here —
            // all subsequent transcribe() calls reuse the compiled model.
            let batch = AsrManager(config: .default)
            try await batch.loadModels(models)
            batchDecoderLayerCount = await batch.decoderLayerCount
            self.batchManager = batch

            // Run a silent 300ms inference to trigger ANE cache finalization.
            // The ANE daemon renames .tmp compiled bundles → permanent cache
            // entries only after the first inference executes. Without this,
            // every launch recompiles the Encoder from MIL (~50s) because
            // the daemon never sees an inference before the process exits.
            let silence = [Float](repeating: 0.0, count: 4800)
            var warmupState = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
            _ = try? await batch.transcribe(silence, decoderState: &warmupState)
            print("[VOICE] ANE warmup inference complete")

            if wasFirstLoad {
                // On first-ever load the daemon needs ~2s to finalize the cache.
                // Subsequent launches skip this branch (cache already permanent).
                print("[VOICE] First load — waiting for ANE cache finalization…")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            isReady = true
            modelState = .ready
            print("[VOICE] Parakeet TDT v3 ready (batch engine pre-warmed, \(batchDecoderLayerCount) decoder layers)")
        } catch {
            let msg = error.localizedDescription
            modelState = .error(msg)
            lastError = msg
            print("[VOICE] Parakeet init failed: \(msg)")
            throw error
        }
    }

    // MARK: - Dictation surface

    /// Begin a new dictation session. Returns immediately — no model loading.
    func start() async throws {
        guard batchManager != nil else {
            print("[VOICE-TS] start() FAILED — batchManager nil (model not loaded)")
            throw TranscriptionError.notInitialized
        }
        sessionStart = Date()
        print("[VOICE-TS] start() OK — session marked at \(sessionStart!) (isReady=\(isReady))")
    }

    /// No-op. Audio is captured to file by AudioCaptureService; call transcribeFile() at stop.
    func feed(samples: [Float]) async { }

    /// Resets session state. Actual transcription happens in transcribeFile(url:).
    /// RecordingCoordinator calls transcribeFile on the retained audio file after this.
    func stop() async -> [TranscriptSegment] {
        print("[VOICE] stop() — session ended, caller will transcribeFile()")
        sessionStart = nil
        return []
    }

    // MARK: - Speaker state (no-op — single-speaker app)

    func resetSpeakerState() { }

    // MARK: - Batch surface (unused — MeetingRecorder not wired)

    func transcribe(
        audioChunk: [Float],
        chunkStartTime: TimeInterval
    ) async throws -> [TranscriptSegment] {
        return []
    }

    // MARK: - File transcription (primary path for dictation + crash recovery)

    /// Transcribe an audio file by passing its URL directly to FluidAudio.
    /// FluidAudio handles format detection, resampling, and chunking internally.
    /// This is the macparakeet approach — no manual AVAudioFile reading needed.
    func transcribeFile(url: URL) async throws -> [TranscriptSegment] {
        guard let manager = batchManager else {
            print("[VOICE-TS] transcribeFile FAILED — batchManager nil")
            throw TranscriptionError.notInitialized
        }

        let t0 = Date()
        print("[VOICE-TS] transcribeFile() ENTER — \(url.lastPathComponent) at \(t0)")

        var decoderState = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
        let result: ASRResult
        do {
            // Pass `language: .english` so Parakeet TDT v3's script-aware top-K
            // filter rejects non-Latin candidate tokens. Without this the
            // decoder occasionally substitutes Cyrillic/Greek lookalikes
            // (e.g. "ChatGPT" → "Сhatgpt") because the multilingual v3 model
            // shares output vocab across scripts. v3-only — silently ignored
            // on v2 / tdtCtc110m. Free accuracy win for an English-only app.
            result = try await manager.transcribe(url, decoderState: &decoderState, language: .english)
        } catch {
            print("[VOICE-TS] transcribeFile THREW: \(error)")
            throw error
        }

        let trimmed = result.text.trimmingCharacters(in: .whitespaces)
        let elapsed = Date().timeIntervalSince(t0)
        print("[VOICE-TS] transcribeFile() OK → '\(trimmed.prefix(80))' (\(trimmed.count) chars) in \(String(format: "%.2f", elapsed))s")

        guard !trimmed.isEmpty else {
            print("[VOICE-TS] transcribeFile → empty text, returning []")
            return []
        }

        // Extract suspect words from per-token confidence. FluidAudio's
        // `ASRResult.tokenTimings` carries per-token confidence (0..1). We
        // surface tokens below 0.6 to the polish layer as "suspect" — the
        // LLM gets to double-check spelling / word choice on those.
        // Tokens are SentencePiece pieces ("▁world", "in", "g") — we coarsen
        // them up to whole words by re-joining adjacent pieces that don't
        // start with the word-start marker. If no timings (older builds),
        // suspectWords is nil and the polisher gets no hint.
        let suspectWords: [String]? = Self.extractSuspectWords(
            from: result.tokenTimings,
            confidenceThreshold: 0.6
        )
        if let suspectWords, !suspectWords.isEmpty {
            print("[VOICE-TS] suspect words (low-confidence): \(suspectWords)")
        }

        return [
            TranscriptSegment(
                speaker: "Speaker 1",
                text: trimmed,
                startTime: 0,
                endTime: result.duration,
                confidence: result.confidence,
                suspectWords: suspectWords
            )
        ]
    }

    /// Group adjacent SentencePiece tokens into whole words and return the
    /// distinct whole words whose minimum per-piece confidence falls below
    /// the threshold. Capped at 16 words to keep the polish prompt sane.
    private static func extractSuspectWords(
        from timings: [TokenTiming]?,
        confidenceThreshold: Float
    ) -> [String]? {
        guard let timings, !timings.isEmpty else { return nil }

        // SentencePiece marks word boundaries with "▁" (U+2581). Group pieces
        // until the next "▁"-prefixed piece (or end). Compute the min
        // confidence across the group; flag the joined word if min < threshold.
        let wordStartMarker = "\u{2581}"
        var groups: [(word: String, minConf: Float)] = []
        var currentPieces: [String] = []
        var currentMin: Float = .greatestFiniteMagnitude

        func flush() {
            guard !currentPieces.isEmpty else { return }
            let joined = currentPieces.joined()
                .replacingOccurrences(of: wordStartMarker, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                groups.append((joined, currentMin))
            }
            currentPieces.removeAll(keepingCapacity: true)
            currentMin = .greatestFiniteMagnitude
        }

        for timing in timings {
            // Skip blank/empty pieces — they carry no text and would bias min.
            let piece = timing.token
            if piece.isEmpty { continue }
            if piece.hasPrefix(wordStartMarker) {
                // New word starts here — flush the previous group first.
                flush()
            }
            currentPieces.append(piece)
            if timing.confidence < currentMin { currentMin = timing.confidence }
        }
        flush()

        // Filter to suspect words; dedupe; cap.
        var seen = Set<String>()
        var suspect: [String] = []
        for g in groups where g.minConf < confidenceThreshold {
            let lower = g.word.lowercased()
            if seen.insert(lower).inserted {
                suspect.append(g.word)
                if suspect.count >= 16 { break }
            }
        }
        return suspect.isEmpty ? nil : suspect
    }
}
