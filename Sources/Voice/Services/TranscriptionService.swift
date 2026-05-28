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
                version: .v2,
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

            // Second warmup with the max-samples shape (15s @ 16kHz) so the
            // long-form CoreML graph is also compiled/cached before first use.
            let maxModelSamples = 240_000
            let silenceMax = [Float](repeating: 0.0, count: maxModelSamples)
            var warmupStateMax = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
            _ = try? await batch.transcribe(silenceMax, decoderState: &warmupStateMax)
            print("[VOICE] ANE warmup inference complete (max-samples shape)")

            if wasFirstLoad {
                // On first-ever load the daemon needs ~2s to finalize the cache.
                // Subsequent launches skip this branch (cache already permanent).
                // Run in a detached task so prepare() does NOT block on it —
                // ready state can flip immediately while the daemon finalizes.
                print("[VOICE] First load — scheduling ANE cache finalization (non-blocking)…")
                Task.detached {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    print("[VOICE] ANE cache finalization wait complete")
                }
            }

            isReady = true
            modelState = .ready
            print("[VOICE] Parakeet TDT v2 ready (batch engine pre-warmed, \(batchDecoderLayerCount) decoder layers)")
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
        // Write the raw Float32 PCM chunk to a temp .caf file, then hand it
        // to the existing transcribeFile() path. This is the same approach
        // AudioCaptureService uses — FluidAudio works best with file URLs.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-meeting-chunk-\(UUID().uuidString).caf")

        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.notInitialized
        }

        // Write the [Float] samples into an AVAudioPCMBuffer and save to disk.
        let frameCount = AVAudioFrameCount(audioChunk.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptionError.notInitialized
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            audioChunk.withUnsafeBufferPointer { ptr in
                channelData[0].initialize(from: ptr.baseAddress!, count: audioChunk.count)
            }
        }

        let audioFile = try AVAudioFile(forWriting: tmpURL, settings: format.settings)
        try audioFile.write(from: buffer)

        // Transcribe via the real file path.
        var segments = try await transcribeFile(url: tmpURL)

        // Offset segment timestamps relative to the meeting session start.
        for i in segments.indices {
            segments[i].startTime += chunkStartTime
            segments[i].endTime   += chunkStartTime
        }

        return segments
    }

    // MARK: - File transcription (primary path for dictation + crash recovery)

    /// Transcribe an audio file. For audio that fits in a single Parakeet
    /// decode window (≤15 s @ 16 kHz) we hand the URL to FluidAudio unchanged
    /// — same code path as before. For longer audio we take the chunking
    /// into our own hands to side-step a boundary-merge bug in FluidAudio's
    /// `ChunkProcessor.mergeByMidpoint` (see VOICE-MERGE comment below).
    func transcribeFile(url: URL) async throws -> [TranscriptSegment] {
        guard let manager = batchManager else {
            print("[VOICE-TS] transcribeFile FAILED — batchManager nil")
            throw TranscriptionError.notInitialized
        }

        let t0 = Date()
        print("[VOICE-TS] transcribeFile() ENTER — \(url.lastPathComponent) at \(t0)")

        // ============================================================
        // [VOICE-MERGE] Chunk-boundary fix
        // ------------------------------------------------------------
        // FluidAudio v3's ChunkProcessor splits long audio into ~14.96s
        // windows with 2.0s overlap, decodes each chunk with a FRESH
        // decoder state (state.reset()), then attempts to merge the
        // overlapping token streams. When the two decodings of the same
        // boundary audio disagree (which is common — the chunk whose
        // window has the boundary AT THE EDGE has less acoustic context
        // and tends to mis-decode), the merge falls through to
        // `mergeByMidpoint`, which splits on TIMESTAMP alone and just
        // happens to drop the higher-context decoding. The user-visible
        // failure: tail-of-chunk-N text is *lost* AND the head-of-chunk-
        // (N+1) text appears mutated.
        //
        // Fix (strategy: drive chunking ourselves, prefer higher-
        // confidence decoding at boundaries):
        //   1. Read the audio file into a [Float] at 16 kHz.
        //   2. If the whole recording fits in one ~15s Parakeet window,
        //      ask FluidAudio for a single-shot decode — no chunking, no
        //      boundary at all. This eliminates the bug for typical
        //      dictation lengths.
        //   3. If it's longer, chunk it ourselves into ≤14.5 s windows
        //      with a 2.0 s overlap and call `manager.transcribe(samples)`
        //      on each. Each chunk stays at-or-below maxModelSamples so
        //      FluidAudio routes to its single-decode path internally —
        //      ChunkProcessor.mergeByMidpoint never runs. We then merge
        //      the per-chunk text by suffix/prefix overlap and pick the
        //      higher-confidence span at the seam.
        //
        // Trade-off: this loses FluidAudio's internal token-level dedup
        // and gets a string-level merge instead — but it eliminates the
        // class of bug where a mis-decoded boundary stomps a correct one.
        // ============================================================
        let samples: [Float]
        let tReadStart = CFAbsoluteTimeGetCurrent()
        do {
            samples = try Self.readSamplesAt16kMono(url: url)
        } catch {
            print("[VOICE-TS] readSamplesAt16kMono FAILED: \(error.localizedDescription) — falling back to URL path")
            return try await transcribeFile_legacyURL(url: url, manager: manager, t0: t0)
        }
        let readMs = (CFAbsoluteTimeGetCurrent() - tReadStart) * 1000
        fputs("[LATENCY] ASR file-read→[Float] (\(samples.count) samples): \(Int(readMs))ms\n", stderr)
        let tDecodeStart = CFAbsoluteTimeGetCurrent()

        let maxModelSamples = 240_000              // 15s @ 16kHz (FluidAudio limit)
        let safeChunkSamples = 232_000             // ~14.5s — leaves margin under the model cap
        let overlapSamples   = 32_000              //  2.0s overlap, matches FluidAudio's ChunkProcessor

        let result: ASRResult
        do {
            if samples.count <= maxModelSamples {
                // === Path A: single-shot decode — bug-free by construction ===
                print("[VOICE-MERGE] single-shot decode: \(samples.count) samples (≤ \(maxModelSamples))")
                var decoderState = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
                result = try await manager.transcribe(samples, decoderState: &decoderState, language: .english)
            } else {
                // === Path B: manual chunked decode with text-level merge ===
                print("[VOICE-MERGE] chunked decode: \(samples.count) samples → ~\(samples.count / (safeChunkSamples - overlapSamples) + 1) chunks of \(safeChunkSamples) (overlap \(overlapSamples))")
                result = try await Self.chunkedTranscribe(
                    samples: samples,
                    manager: manager,
                    decoderLayers: batchDecoderLayerCount,
                    chunkSamples: safeChunkSamples,
                    overlapSamples: overlapSamples,
                    sampleRate: 16_000
                )
            }
        } catch {
            print("[VOICE-TS] transcribeFile THREW: \(error)")
            throw error
        }

        let decodeMs = (CFAbsoluteTimeGetCurrent() - tDecodeStart) * 1000
        fputs("[LATENCY] ASR decode (Parakeet inference): \(Int(decodeMs))ms\n", stderr)
        let trimmed = result.text.trimmingCharacters(in: .whitespaces)
        let elapsed = Date().timeIntervalSince(t0)
        print("[VOICE-TS] transcribeFile() OK → '\(trimmed.prefix(80))' (\(trimmed.count) chars) in \(String(format: "%.2f", elapsed))s")

        guard !trimmed.isEmpty else {
            print("[VOICE-TS] transcribeFile → empty text, returning []")
            return []
        }

        // Extract suspect words from per-token confidence. FluidAudio's
        // `ASRResult.tokenTimings` carries per-token confidence (0..1). We
        // surface tokens below 0.65 to the polish layer as "suspect" — the
        // LLM gets to double-check spelling / word choice on those.
        // Tokens are SentencePiece pieces ("▁world", "in", "g") — we coarsen
        // them up to whole words by re-joining adjacent pieces that don't
        // start with the word-start marker. If no timings (older builds),
        // suspectWords is nil and the polisher gets no hint.
        let suspectWords: [String]? = Self.extractSuspectWords(
            from: result.tokenTimings,
            confidenceThreshold: 0.65
        )
        if let suspectWords, !suspectWords.isEmpty {
            print("[VOICE-TS] suspect words (low-confidence): \(suspectWords)")
        }

        // Section F (merge correctness): aggregate per-token confidence into
        // a single segment-level confidence value. Used downstream by
        // Qwen3Polisher.mergeWithMLX to pick the higher-confidence span when
        // two transcripts disagree. Falls back to `result.confidence` (the
        // ASR's own overall score) when token timings are unavailable.
        let segmentConfidence: Float
        if let timings = result.tokenTimings, !timings.isEmpty {
            let total = timings.reduce(Float(0)) { $0 + $1.confidence }
            segmentConfidence = total / Float(timings.count)
        } else {
            segmentConfidence = result.confidence
        }

        return [
            TranscriptSegment(
                speaker: "Speaker 1",
                text: trimmed,
                startTime: 0,
                endTime: result.duration,
                confidence: segmentConfidence,
                suspectWords: suspectWords
            )
        ]
    }

    // MARK: - Boundary-fix helpers (see [VOICE-MERGE] block above)

    /// Legacy fallback path — exactly the pre-fix behaviour. Only invoked
    /// when our own audio-file reader can't decode the file. Keeps Voice
    /// resilient on weird inputs (e.g. orphan recovery on a half-written
    /// .caf where the AVAudioFile path errors out).
    private func transcribeFile_legacyURL(
        url: URL,
        manager: AsrManager,
        t0: Date
    ) async throws -> [TranscriptSegment] {
        var decoderState = TdtDecoderState.make(decoderLayers: batchDecoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &decoderState, language: .english)
        let trimmed = result.text.trimmingCharacters(in: .whitespaces)
        let elapsed = Date().timeIntervalSince(t0)
        print("[VOICE-TS] transcribeFile() OK (legacy URL path) → '\(trimmed.prefix(80))' (\(trimmed.count) chars) in \(String(format: "%.2f", elapsed))s")
        guard !trimmed.isEmpty else { return [] }
        return [TranscriptSegment(
            speaker: "Speaker 1",
            text: trimmed,
            startTime: 0,
            endTime: result.duration,
            confidence: result.confidence,
            suspectWords: nil
        )]
    }

    /// Read an audio file into mono Float32 samples at 16 kHz.
    /// AVAudioConverter handles format / sample-rate conversion. We need a
    /// concrete [Float] (not a URL) so we can split it ourselves and stay
    /// off FluidAudio's buggy ChunkProcessor merge path for long inputs.
    private static func readSamplesAt16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VOICE-TS", code: -1, userInfo: [NSLocalizedDescriptionKey: "failed to build 16k mono format"])
        }

        // Same format already → just read straight through.
        if abs(srcFormat.sampleRate - 16_000) < 0.1 && srcFormat.channelCount == 1 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw NSError(domain: "VOICE-TS", code: -2, userInfo: [NSLocalizedDescriptionKey: "PCM buffer alloc failed"])
            }
            try file.read(into: buf)
            return floatArray(from: buf)
        }

        // Otherwise resample via AVAudioConverter.
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw NSError(domain: "VOICE-TS", code: -3, userInfo: [NSLocalizedDescriptionKey: "converter init failed"])
        }
        let srcCapacity: AVAudioFrameCount = 4096
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcCapacity) else {
            throw NSError(domain: "VOICE-TS", code: -4, userInfo: [NSLocalizedDescriptionKey: "src buffer alloc failed"])
        }

        // Output buffer grows as we go. Estimate capacity from src length.
        let ratio = 16_000.0 / srcFormat.sampleRate
        let estimatedOut = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: estimatedOut) else {
            throw NSError(domain: "VOICE-TS", code: -5, userInfo: [NSLocalizedDescriptionKey: "dst buffer alloc failed"])
        }

        var fileEOF = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fileEOF {
                outStatus.pointee = .endOfStream
                return nil
            }
            srcBuf.frameLength = 0
            do {
                try file.read(into: srcBuf, frameCount: srcCapacity)
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
            if srcBuf.frameLength == 0 {
                fileEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return srcBuf
        }

        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error, withInputFrom: inputBlock)
        if status == .error, let error { throw error }
        return floatArray(from: dstBuf)
    }

    private static func floatArray(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return [] }
        // Array(UnsafeBufferPointer(...)) iterates element-by-element through
        // the buffer protocol. Using unsafeUninitializedCapacity + memcpy is a
        // single raw memory copy, ~10x faster on multi-MB buffers.
        return [Float](unsafeUninitializedCapacity: n) { destBuf, initCount in
            memcpy(destBuf.baseAddress!, ch[0], n * MemoryLayout<Float>.stride)
            initCount = n
        }
    }

    /// Chunk a long sample array into ~14.5 s windows with 2 s overlap,
    /// decode each via the single-shot path (`manager.transcribe(samples)`
    /// stays ≤ maxModelSamples so it bypasses ChunkProcessor entirely),
    /// then string-merge the per-chunk outputs using confidence-weighted
    /// overlap dedup at each seam.
    ///
    /// Each `manager.transcribe(samples:)` call uses a FRESH decoder state.
    /// We accept slight intra-chunk LM context loss (the boundary words get
    /// fresh state) in exchange for not relying on FluidAudio's broken
    /// token-window merger.
    private static func chunkedTranscribe(
        samples: [Float],
        manager: AsrManager,
        decoderLayers: Int,
        chunkSamples: Int,
        overlapSamples: Int,
        sampleRate: Int
    ) async throws -> ASRResult {
        precondition(chunkSamples > overlapSamples * 2, "chunk must be more than 2× overlap")

        struct ChunkOut {
            let index: Int
            let text: String
            let confidence: Float
            let timings: [TokenTiming]?
            let duration: TimeInterval
            let startSec: Double
        }

        var outputs: [ChunkOut] = []
        var chunkStart = 0
        var idx = 0
        let stride = chunkSamples - overlapSamples

        while chunkStart < samples.count {
            let end = min(chunkStart + chunkSamples, samples.count)
            // Array(samples[chunkStart..<end]) goes through the Sequence
            // initialiser — element-by-element copy. unsafeUninitializedCapacity
            // + memcpy is a single bulk copy per chunk. For multi-chunk audio
            // this is hot — every saved alloc matters.
            let sliceCount = end - chunkStart
            let slice: [Float] = samples.withUnsafeBufferPointer { src in
                [Float](unsafeUninitializedCapacity: sliceCount) { dest, initCount in
                    memcpy(dest.baseAddress!, src.baseAddress! + chunkStart, sliceCount * MemoryLayout<Float>.stride)
                    initCount = sliceCount
                }
            }
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            // FluidAudio requires ≥ minimumRequiredSamples; pad final tiny tail.
            let minSamples = sampleRate / 4 // 250ms
            let toDecode: [Float]
            if slice.count < minSamples {
                // Tail too short by itself — fold it into the previous chunk
                // by extending the previous decoder's range. Since we already
                // emitted the previous chunk, just drop this tail; the prior
                // chunk's overlap should already cover it. (overlapSamples ≥
                // this floor.)
                print("[VOICE-MERGE] chunk \(idx) tail <250ms, skipping (covered by prior overlap)")
                break
            } else {
                toDecode = slice
            }

            let r = try await manager.transcribe(toDecode, decoderState: &decoderState, language: .english)
            let txt = r.text.trimmingCharacters(in: .whitespaces)
            print("[VOICE-MERGE] chunk \(idx) start=\(chunkStart) len=\(slice.count) text=\"\(txt.prefix(60))…\" conf=\(String(format: "%.3f", r.confidence))")
            outputs.append(ChunkOut(
                index: idx,
                text: txt,
                confidence: r.confidence,
                timings: r.tokenTimings,
                duration: r.duration,
                startSec: Double(chunkStart) / Double(sampleRate)
            ))
            if end == samples.count { break }
            chunkStart += stride
            idx += 1
        }

        // Merge chunk texts. Strategy: for each adjacent pair (L, R) find
        // the longest word-suffix of L that matches a word-prefix of R, up
        // to ~`overlapSeconds` worth of words. Whichever side has higher
        // segment confidence wins the overlap; the other side's overlap
        // copy is dropped. If no word-overlap is found (rare — two
        // independent decodings of the same audio usually share at least
        // a couple of words), fall back to a confidence-weighted midpoint
        // (keep the higher-confidence chunk's words for the seam).
        guard !outputs.isEmpty else {
            return ASRResult(text: "", confidence: 0, duration: 0, processingTime: 0, tokenTimings: nil)
        }
        if outputs.count == 1 {
            return ASRResult(
                text: outputs[0].text,
                confidence: outputs[0].confidence,
                duration: outputs[0].duration,
                processingTime: 0,
                tokenTimings: outputs[0].timings
            )
        }

        var merged = outputs[0].text
        var mergedConf = outputs[0].confidence
        var allTimings: [TokenTiming] = outputs[0].timings ?? []
        let overlapWordBudget = 10 // 2s overlap ≈ 6-8 words at normal speech; 10 caps false-positive risk

        for i in 1..<outputs.count {
            let prevConf = mergedConf
            let r = outputs[i]
            let (joined, keptSide) = mergeByWordOverlap(
                left: merged,
                right: r.text,
                leftConf: prevConf,
                rightConf: r.confidence,
                maxWords: overlapWordBudget
            )
            merged = joined
            mergedConf = max(prevConf, r.confidence)
            if let t = r.timings { allTimings.append(contentsOf: t) }
            print("[VOICE-MERGE] chunk \(i-1)-\(i) boundary: kept=\(keptSide) confL=\(String(format: "%.3f", prevConf)) confR=\(String(format: "%.3f", r.confidence))")
        }

        let totalDur = TimeInterval(samples.count) / TimeInterval(sampleRate)
        return ASRResult(
            text: merged,
            confidence: mergedConf,
            duration: totalDur,
            processingTime: 0,
            tokenTimings: allTimings.isEmpty ? nil : allTimings
        )
    }

    /// Merge two chunk transcripts by finding the longest word-level overlap
    /// at the L-suffix / R-prefix seam. The higher-confidence side's copy of
    /// the overlap region wins. Returns the merged string and a tag for
    /// which side was preferred ("left", "right", or "none" when no overlap
    /// was detected).
    private static func mergeByWordOverlap(
        left: String,
        right: String,
        leftConf: Float,
        rightConf: Float,
        maxWords: Int
    ) -> (String, String) {
        let lWords = left.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let rWords = right.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !lWords.isEmpty, !rWords.isEmpty else {
            return ((left + " " + right).trimmingCharacters(in: .whitespaces), "none")
        }

        // Look for the longest k such that lWords.suffix(k) ≈ rWords.prefix(k)
        // — case-insensitive, punctuation-stripped match. We scan k from the
        // budget down so the first hit is the longest.
        let maxK = min(maxWords, lWords.count, rWords.count)
        let punct = CharacterSet.punctuationCharacters
        // Pre-normalize the L-tail and R-head ONCE. The previous implementation
        // re-normalized the same words on every k iteration (O(maxK²) string
        // work). One pass is O(maxK).
        let lTailNorm: [String] = lWords.suffix(maxK).map { $0.lowercased().trimmingCharacters(in: punct) }
        let rHeadNorm: [String] = rWords.prefix(maxK).map { $0.lowercased().trimmingCharacters(in: punct) }
        var bestK = 0
        let requireMatches = 2 // at least 2 consecutive matching words to declare overlap
        for k in stride(from: maxK, through: requireMatches, by: -1) {
            // Slice the pre-normalized prefix/suffix without re-normalizing.
            // For the L tail of size k we want the last k entries of lTailNorm.
            let lStart = lTailNorm.count - k
            // Allow a small mismatch tolerance: require ≥ 60 % matches AND
            // first + last token to match. This handles the case where the
            // boundary words mis-decoded ("trade" vs "treat") but the rest
            // of the overlap is intact.
            var hits = 0
            for j in 0..<k where lTailNorm[lStart + j] == rHeadNorm[j] { hits += 1 }
            let ratio = Double(hits) / Double(k)
            // Tighter guard: ≥75% word match AND first AND last word of the
            // window agree. Raising from 60% + first-only prevents false-
            // positive overlaps from eating non-overlap content at the seam.
            if ratio >= 0.75
                && lTailNorm[lStart] == rHeadNorm[0]
                && lTailNorm[lStart + k - 1] == rHeadNorm[k - 1] {
                bestK = k
                break
            }
        }

        if bestK == 0 {
            // No detectable overlap. Just concatenate with a space.
            return ((left + " " + right).trimmingCharacters(in: .whitespaces), "none")
        }

        // Pick the higher-confidence side's copy of the overlap region.
        if leftConf >= rightConf {
            // Keep L's overlap; drop R's prefix-of-bestK and append the rest.
            let rTail = Array(rWords.dropFirst(bestK))
            let merged = (lWords + rTail).joined(separator: " ")
            return (merged, "left")
        } else {
            // Keep R's overlap; drop L's suffix-of-bestK and append R as-is.
            let lHead = Array(lWords.dropLast(bestK))
            let merged = (lHead + rWords).joined(separator: " ")
            return (merged, "right")
        }
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
            // The word-start marker (▁) only ever appears at the very start of
            // the first piece in a group (that's what defines a group start).
            // String.replacingOccurrences scans the whole joined string and
            // allocates a fresh String — pointless when only the leading char
            // can ever match. Strip via prefix-drop instead.
            var joined = currentPieces.joined()
            if joined.hasPrefix(wordStartMarker) {
                joined.removeFirst(wordStartMarker.count)
            }
            let trimmed = joined.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                groups.append((trimmed, currentMin))
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
