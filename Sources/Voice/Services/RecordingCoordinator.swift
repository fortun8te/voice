// VOICE — Recording Coordinator
// ============================================================
// Orchestrates the dictation pipeline:
//   AudioCapture → ParakeetEngine (streaming) → UI Updates → Storage
//
// FluidAudio's SlidingWindowAsrManager streams transcripts as the user
// speaks, so this file is now just plumbing — no chunk-counting, no
// pendingChunkCount, no awaitPendingTranscriptions. `stop()` returns
// the final segments synchronously (well, async but immediately).
//
// Live partial text is republished onto state.currentTranscript so the
// History/overlay sees text appear in real-time.
//
// ============================================================
// CONCURRENT RECORDING CONTRACT (read this before changing anything)
// ============================================================
// The user can re-press the hotkey BEFORE the prior recording's
// transcribe→polish→paste pipeline has finished. We support up to ~3
// recordings in flight at once (no hard cap here; the practical limit
// is whatever the host can run before Parakeet gets backed up).
//
// Audio capture is SERIALIZED — AVAudioEngine owns a single input
// node, so only one session can be writing to a .caf at a time. But:
//
//   • Each session has a unique audio file: dictation-<UUID>.caf,
//     so a re-press never clobbers the prior file on disk.
//
//   • `claimRecordingSync()` synchronously stops the engine + clears
//     instance state (currentAudioFileURL, currentSessionId) the
//     instant the user releases the hotkey. The NEXT `startRecording()`
//     call can therefore spin up a fresh engine immediately — it doesn't
//     wait for the prior pipeline's transcribe/polish/paste to finish.
//
//   • `stopRecording(claiming:)` runs the drain + transcribe path
//     against the pre-captured (claimed) context. Multiple of these
//     can be in flight concurrently — they share the singleton
//     `batchManager` actor (FluidAudio's AsrManager), which serializes
//     internally. So if session N+1's transcribe arrives before N's
//     has returned, it queues behind it on the model actor — not on
//     the audio engine.
//
//   • Mid-flight state writes inside stopRecording (currentTranscript,
//     skipPolishForCurrent) would clobber each other for concurrent
//     sessions, so we DO NOT
//     write them when our session is no longer the active one. The
//     `currentRecordingSessionId` counter is the gate. Stale sessions
//     still RETURN their segments to the caller — VoiceApp's pasteChain
//     uses those values directly and preserves FIFO paste order.
//
//   • The chronological paste anchor lives in VoiceApp's `pasteChain`
//     (Task<Void, Never>?). Each finish task reserves its slot in the
//     chain at Parakeet-return time, so paste order = finishRecording-
//     call order regardless of how long each polish takes. See the
//     "BUGFIX (Category 4)" block in VoiceApp.finishRecording().
//
// Logging contract: every coordinator log line should include
// `session=<8-char-prefix>` so concurrent flows can be untangled in
// the transcript. The helper `sessTag()` formats this.
// ============================================================

import Foundation
import FluidAudio
import Combine

@MainActor
@Observable
class RecordingCoordinator {
    // Services
    let audioCapture = AudioCaptureService()
    let transcription = TranscriptionService()
    // Made internal (was `private`) so MeetingRecoveryService can use the same
    // DB instance for orphan scan / draft checkpoint / re-transcribe paths.
    let storage = StorageService()

    // State (shared with UI via RecordingState)
    var state: RecordingState

    // Internal
    private var recordingStartTime: Date?
    private var elapsedTimer: Timer?
    private var levelsTimer: Timer?
    private var startupTask: Task<Void, Never>?

    /// URL of the retained audio file for the current recording (if any).
    private var currentAudioFileURL: URL?

    /// UUID that names the current recording's audio file AND will be
    /// reused as the Meeting.id on save — so the persisted audio at
    /// `<AppSupport>/Voice/audio/dictation-<id>.caf` is reachable from
    /// the transcript row via `Meeting.audioFilePath`.
    private var currentSessionId: UUID?

    /// Monotonic counter bumped on each new `startRecording()`. Used to
    /// drop stale async work when the user rapidly re-presses the hotkey
    /// before the previous transcribe → polish → paste pipeline has finished.
    /// Singleton model actors (Granite/Moonshine/Qwen3) serialize internally,
    /// so without this guard a second recording's pipeline would queue behind
    /// the first and could paste out of order. After every `await` in the
    /// pipeline, compare a locally-captured copy against this counter and
    /// bail early on mismatch.
    private var currentRecordingSessionId: UInt64 = 0

    /// Read-only accessor for the session counter so the polish/paste
    /// chain in VoiceApp can perform the same staleness check after its
    /// own awaits.
    var recordingSessionId: UInt64 { currentRecordingSessionId }

    /// Soft cap (bytes) for the total size of retained audio. Once the
    /// directory exceeds this, oldest files are pruned to bring it back
    /// under the cap. 5 GB ≈ ~40 hours @ 16 kHz / Float32 mono.
    private let audioDirectoryByteCap: Int = 5 * 1024 * 1024 * 1024

    /// URL of the most recently completed dictation's audio file.
    /// Persistent: the file stays on disk and its path is written to
    /// `Meeting.audioFilePath` so users can replay/re-process later.
    /// `releaseLastDictationAudio()` still works as an explicit "drop now"
    /// hook (e.g. for a privacy-mode toggle). The `lastDictationCleanupTask`
    /// is retained only so the public release helper can cancel a (now
    /// nonexistent) pending task without compiling differently.
    private(set) var lastDictationAudioURL: URL?
    private var lastDictationCleanupTask: Task<Void, Never>?

    /// Background task that re-transcribes orphan audio files left over from
    /// a crash during transcription. Deferred while a recording is active so
    /// it can't steal model time from the live path. See `recoverOrphanRecordings`.
    private var orphanRecoveryTask: Task<Void, Never>?

    // Live-partials sliding window for lock-mode preview.
    private var slidingWindowManager: SlidingWindowAsrManager?
    private var livePartialsTask: Task<Void, Never>?

    /// Fired when the user speaks the configured stop word (default
    /// "finito") at the trailing edge of a hands-free (locked) recording.
    /// AppDelegate wires this to exitLockMode() + finishRecording() — the
    /// same commit path as a third-tap lock exit. Only ever fires during
    /// lock mode, where live partials run and there's no key to release.
    var onStopWordDetected: (() -> Void)?
    /// Debounce so a stop word can't double-fire across rapid confirmed updates.
    private var lastStopWordFireAt: Date?

    init(state: RecordingState) {
        self.state = state
    }

    /// Short tag for logs: `session=<first-8-of-uuid>`. Pass the persistent
    /// session UUID (the one that names the audio file) so concurrent flows
    /// can be untangled from the transcript. Returns empty when nil.
    private func sessTag(_ id: UUID?) -> String {
        guard let id else { return "session=—" }
        return "session=\(id.uuidString.prefix(8))"
    }

    // MARK: - Lifecycle

    /// Call once at app launch to load models and prepare services.
    func prepare() async {
        do {
            try storage.initialize()

            // Disk safety: prune audio folder if it's over the 5GB cap.
            // Non-blocking background pass on the main actor (storage is
            // not Sendable; the prune itself is cheap I/O).
            Task { @MainActor [weak self] in
                _ = self?.storage.pruneAudioBySize()
            }

            // Sync model state to UI as Parakeet downloads/loads.
            state.modelState = .downloading(progress: 0)

            // Parallelize the three independent preloads. Parakeet/NeMo init
            // is the long pole (model download + load); audio HAL warmup and
            // Qwen3 LLM prewarm are cheap-ish but were paying serial cost.
            // None of these touch shared state, so running concurrently is safe.
            let prewarmStart = Date()
            async let txReady: Void = {
                try await transcription.prepare()
            }()
            async let audioReady: Void = Task.detached(priority: .userInitiated) { [audioCapture] in
                audioCapture.warmup()
            }.value
            async let qwenReady: Void = Qwen3Polisher.shared.prewarm()

            // Fire-and-forget CTC streaming model prewarm — downloads/loads
            // the ~110MB vocabulary-boosting model in the background so the
            // first streaming session doesn't pay the cold-start cost.
            Task {
                vlog("[VOICE-PREWARM] CTC streaming models — kicking off background prewarm")
                try? await CtcModels.downloadAndLoad()
                vlog("[VOICE-PREWARM] CTC streaming models — ready")
            }

            // Await transcription (throwing) first; the other two are Void and
            // can be awaited unconditionally afterwards.
            try await txReady
            _ = await (audioReady, qwenReady)
            vlog("[VOICE TIMINGS] prewarm-parallel: \(Int(Date().timeIntervalSince(prewarmStart) * 1000))ms")
            state.modelState = transcription.modelState

            // Granite/Moonshine subprocess transcribers are not in the current
            // Xcode build target; Parakeet v2 is the sole transcriber. Add the
            // *Transcriber.swift files back to the project to re-enable.

            // Force lazy init of the SoundEffects engine so the first
            // playStart() earcon doesn't pay ~20ms engine.start() cost.
            _ = SoundEffects.self

            // Crashed-recording recovery: scan for orphan dictation audio
            // (files on disk with no matching Meeting row) and re-transcribe
            // them in the background. If the user starts a new recording
            // before this completes, the recovery loop defers itself.
            // Run at .background priority so it never competes with the hotkey
            // listener or live transcription. The body still hops to the main
            // actor for storage/transcription calls, but awaits yield freely.
            orphanRecoveryTask = Task(priority: .background) { @MainActor [weak self] in
                await self?.recoverOrphanRecordings()
            }
        } catch {
            state.modelState = .error(error.localizedDescription)
            vlog("[VOICE] Initialization error: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording Control

    /// Start recording from the configured audio source.
    func startRecording() {
        let enterTime = Date()
        vlog("[VOICE-RC] startRecording() ENTER at \(enterTime) (already recording: \(state.isRecording))")
        guard !state.isRecording else {
            vlog("[VOICE-RC] startRecording() EARLY-EXIT — already recording")
            return
        }

        vlog("[VOICE-RC] isRecording: false → true at \(Date()) (SYNC, before any Task)")
        state.isRecording = true
        state.isPaused = false
        state.elapsedSeconds = 0
        state.currentTranscript = []
        recordingStartTime = Date()

        // PERSISTENCE GUARANTEE: the audio file is named by the same UUID
        // that will become the Meeting's primary key, so the recording's
        // audio lives at a stable, lookup-by-ID path for the lifetime of
        // the transcript. See `stopRecording()` where this ID is used as
        // the Meeting.id and written to Meeting.audioFilePath.
        let sessionId = UUID()
        self.currentSessionId = sessionId
        // Bump the staleness counter so any in-flight pipeline from a
        // previous recording can detect it's been superseded and bail.
        currentRecordingSessionId &+= 1
        vlog("[VOICE-RC] \(sessTag(sessionId)) phase=record-begin counter=\(currentRecordingSessionId)")
        // The audio file is named by `sessionId` (a fresh UUID per call),
        // guaranteeing no collision with a still-transcribing prior recording.
        // Even if two `startRecording()` calls overlap conceptually, each gets
        // its own .caf path. Audio capture itself remains serialized at the
        // engine layer — that's a HW constraint, not a state contract.
        let audioURL = makeDictationAudioURL(id: sessionId)
        do {
            try audioCapture.startWritingToFile(url: audioURL)
            // Only record the URL after the writer is open. If
            // startWritingToFile threw, no file was created, so there is
            // nothing to track or leak.
            self.currentAudioFileURL = audioURL
            vlog("[VOICE-RC] \(sessTag(sessionId)) phase=writer-open → \(audioURL.lastPathComponent)")
        } catch {
            // Not fatal — dictation can run without retained audio,
            // we just won't be able to re-transcribe on recovery.
            vlog("[VOICE-RC] \(sessTag(sessionId)) phase=writer-open-FAILED: \(error.localizedDescription)")
        }

        // Start elapsed timer
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPaused else { return }
                self.state.elapsedSeconds += 1
            }
        }

        // Update visualizer levels from audio capture at 30fps. We also track
        // a perceptual `inputLevel` (0..1) and flip `noInputDetected` once we
        // see >2s of effectively-zero input — that's the user-visible "mic
        // isn't picking anything up" hint on the pill.
        levelsTimer?.invalidate()
        var quietTicks = 0
        let quietThreshold: Float = 0.01  // perceptual scale
        let quietTicksLimit = 60          // 60 ticks @ 30fps ≈ 2s
        state.noInputDetected = false
        levelsTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.state.isRecording else {
                    timer.invalidate()
                    return
                }
                self.state.audioLevels = self.audioCapture.audioLevels
                let lvl = self.audioCapture.currentInputLevel
                self.state.inputLevel = lvl
                if lvl < quietThreshold {
                    quietTicks &+= 1
                    if quietTicks == quietTicksLimit && !self.state.noInputDetected {
                        vlog("[VOICE-RC] no input detected for ~2s — surfacing mic hint")
                        self.state.noInputDetected = true
                    }
                } else {
                    quietTicks = 0
                    if self.state.noInputDetected { self.state.noInputDetected = false }
                }
            }
        }

        // Start microphone capture immediately — no need to wait for transcription.start()
        // because feed() is a no-op (we transcribe from the retained file at stop time).
        // Delaying capture inside an async Task caused the first syllable to be clipped.
        let audioSource = UserDefaults.standard.string(forKey: "audioSource") ?? "microphone"
        vlog("[VOICE-RC] audioSource = \(audioSource)")
        if audioSource != "system" {
            do {
                // feed() is a no-op; the capture service writes directly to file.
                vlog("[VOICE-RC] AVAudioEngine.start (mic) at \(Date())")
                try audioCapture.startMicrophoneCapture { _ in }
                vlog("[VOICE-RC] AVAudioEngine.start OK")
                vlog("[VOICE-TIMING] AVAudioEngine.start() done at \(Date())")
            } catch {
                vlog("[VOICE-RC] Microphone capture ERROR: \(error.localizedDescription)")
                Task { @MainActor in _ = await self.stopRecording() }
                return
            }
        }

        // transcription.start() is instant (marks session start) but must precede stop().
        // System audio capture is async so it lives here too.
        vlog("[VOICE-RC] spawning startupTask (async transcription.start)")
        startupTask = Task { @MainActor in
            do {
                try await transcription.start()
                vlog("[VOICE-RC] transcription.start() OK in task")
            } catch {
                vlog("[VOICE-RC] transcription.start FAILED: \(error.localizedDescription)")
                _ = await self.stopRecording()
                return
            }
            guard self.state.isRecording else {
                vlog("[VOICE-RC] startupTask: state.isRecording flipped false during await — aborting")
                _ = await transcription.stop()
                return
            }
            if audioSource == "system" {
                do {
                    try await audioCapture.startSystemAudioCapture { _ in }
                } catch {
                    vlog("[VOICE-RC] System audio capture ERROR: \(error.localizedDescription)")
                    _ = await self.stopRecording()
                }
            }
        }
        vlog("[VOICE-RC] startRecording() EXIT at \(Date()) — isRecording=\(state.isRecording) (elapsed \(Int(Date().timeIntervalSince(enterTime) * 1000))ms)")
    }

    // MARK: - Sync claim (fixes the re-press race)

    /// Context captured synchronously when `finishRecording()` calls
    /// `claimRecordingSync()`. Handed to `stopRecording(claiming:)` so the
    /// async finish Task always drains and transcribes the right audio file —
    /// even if the user re-pressed the hotkey before the Task's body ran.
    struct ClaimedRecording {
        let audioURL: URL?
        let sessionId: UUID
        let recordingStartTime: Date?
        let startupTask: Task<Void, Never>?
    }

    /// Synchronously claim the current recording's resources for an upcoming
    /// `stopRecording(claiming:)` call. Stops the audio capture engine,
    /// invalidates timers, clears `isRecording`, and snapshots + clears the
    /// audio URL / session ID so a subsequent `startRecording()` gets a
    /// completely fresh slate.
    ///
    /// Called from `finishRecording()` on the main actor BEFORE the finish
    /// Task is created. This prevents the race where `hotkeyDidActivate`
    /// Path 2 starts a new recording before Task A's body runs, causing Task A
    /// to call `stopRecording()` and mistakenly stop the NEW recording.
    ///
    /// Returns nil when no recording is active (nothing to claim).
    func claimRecordingSync() -> ClaimedRecording? {
        guard state.isRecording else {
            vlog("[VOICE-RC] claimRecordingSync: not recording — nothing to claim")
            return nil
        }
        let tag = sessTag(currentSessionId)
        vlog("[VOICE-RC] \(tag) phase=claim-begin")

        // Stop audio capture synchronously. This is safe to call here because
        // startRecording() already has a `guard !state.isRecording` guard, so
        // a new recording can only start after we flip isRecording below.
        //
        // CONCURRENT-RECORDING NOTE: stopping the engine here frees the
        // shared AVAudioInputNode immediately. A re-press that lands in the
        // next runloop iteration can call startRecording() and spin a fresh
        // engine without waiting for this session's transcribe to complete.
        //
        // LATENCY: this is a SYNCHRONOUS main-actor call at hotkey-release.
        // AVAudioEngine.stop() can briefly block; this log surfaces how much
        // of the release-to-paste budget is spent tearing the engine down. We
        // keep it synchronous on purpose — the race fix depends on the engine
        // being released before the next startRecording() can run.
        let tStopCapture = CFAbsoluteTimeGetCurrent()
        audioCapture.stopCapture()
        let stopCaptureMs = (CFAbsoluteTimeGetCurrent() - tStopCapture) * 1000
        fputs("[LATENCY] claim: AVAudioEngine teardown (sync, on release): \(Int(stopCaptureMs))ms\n", stderr)

        elapsedTimer?.invalidate(); elapsedTimer = nil
        levelsTimer?.invalidate();  levelsTimer = nil

        vlog("[VOICE-RC] claimRecordingSync: isRecording true → false")
        state.isRecording = false
        state.isPaused = false

        // Snapshot + clear so startRecording() gets a fresh URL/UUID.
        let url       = currentAudioFileURL
        let sid       = currentSessionId ?? UUID()
        let startTime = recordingStartTime
        let task      = startupTask
        currentAudioFileURL = nil
        currentSessionId    = nil
        startupTask         = nil

        vlog("[VOICE-RC] \(sessTag(sid)) phase=claim-done — engine released, transcribe path can run concurrently with next recording")
        return ClaimedRecording(
            audioURL:           url,
            sessionId:          sid,
            recordingStartTime: startTime,
            startupTask:        task
        )
    }

    /// Stop recording and return the final transcript. Awaiting this gives
    /// the streaming engine a chance to flush its right-context tail.
    ///
    /// - Parameter claiming: When non-nil, the caller already synchronously
    ///   claimed the recording via `claimRecordingSync()` — skip the guard /
    ///   sync-stop steps and use the pre-captured context. This prevents the
    ///   race where the hotkey fires a new recording before this Task runs.
    @discardableResult
    func stopRecording(claiming: ClaimedRecording? = nil) async -> [TranscriptSegment] {
        let enterTag = sessTag(claiming?.sessionId ?? currentSessionId)
        vlog("[VOICE-RC] \(enterTag) phase=stop-enter isRecording=\(state.isRecording) claiming=\(claiming != nil)")
        vlog("[VOICE-TIMING] stopRecording entered at \(Date())")

        // Per-stage timing for the [VOICE TIMINGS] greppable summary printed
        // at the end of this method. nil = stage didn't run / didn't land.
        let tStopEntry = Date()
        let audioURL:    URL?
        let sessionId:   UUID
        let tCaptureStart: Date
        var tCaptureEnd:    Date? = nil
        var tParakeetDone:  Date? = nil
        let mySessionId = currentRecordingSessionId  // for log parity

        if let ctx = claiming {
            // === Pre-claimed path ===
            // Audio capture was already stopped synchronously by claimRecordingSync().
            // Just await any in-flight startup task, then fall through to drain+transcribe.
            audioURL      = ctx.audioURL
            sessionId     = ctx.sessionId
            tCaptureStart = ctx.recordingStartTime ?? tStopEntry

            if let task = ctx.startupTask {
                _ = await task.value
            }
            // Audio is already stopped — skip straight to the file drain.
        } else {
            // === Normal path ===
            guard state.isRecording else {
                vlog("[VOICE-RC] stopRecording() EARLY-EXIT — not recording (returning \(state.currentTranscript.count) cached segments)")
                return state.currentTranscript
            }

            tCaptureStart = recordingStartTime ?? tStopEntry

            // Capture file URL locally — `currentAudioFileURL` may be overwritten
            // by a re-press while we're awaiting transcription. After this point
            // the instance property is cleared so a new startRecording() can
            // safely assign a fresh URL without trampling this in-flight session.
            audioURL  = currentAudioFileURL
            sessionId = currentSessionId ?? UUID()
            self.currentAudioFileURL = nil
            self.currentSessionId = nil

            startupTask?.cancel()
            // Await the startup task's completion so a stop initiated while the
            // detached startup is still mid-flight doesn't race with our cleanup.
            if let task = startupTask {
                _ = await task.value
            }
            startupTask = nil

            vlog("[VOICE-RC] isRecording: true → false at \(Date())")
            state.isRecording = false
            state.isPaused = false
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            levelsTimer?.invalidate()
            levelsTimer = nil
            // Stop the audio engine.
            vlog("[VOICE-RC] AVAudioEngine.stop at \(Date())")
            audioCapture.stopCapture()
        }

        // === Shared drain + transcribe path (both claimed and normal converge here) ===
        // Drain in-flight audio I/O callbacks before closing the file.
        // AVAudioEngine.removeTap (inside stopCapture) is not synchronous
        // with the I/O thread — tap buffers may still land for a short
        // window. Rather than paying a flat 200ms tax on every dictation,
        // poll `audioFileBytesWritten` until it goes quiet for two
        // consecutive samples (or the safety cap fires).
        //
        // LATENCY: in the CLAIMED path (every real dictation), stopCapture()
        // already ran synchronously inside claimRecordingSync() — typically
        // several ms before this Task body executes — so the I/O thread is
        // usually already quiet by the time we get here. We sample bytes
        // ONCE up front and, if the very next sample after one poll interval
        // is unchanged, break immediately (1 interval instead of a fixed 2).
        // Poll interval tightened 15ms → 8ms; the 2-stable-sample guarantee
        // is preserved for the rare case where a buffer is still in flight,
        // so the audio tail is never clipped. Floor drops ~30ms → ~8ms.
        do {
            let drainStart = CFAbsoluteTimeGetCurrent()
            let pollIntervalNs: UInt64 = 8_000_000    // 8ms (was 15ms)
            let maxWaitNs: UInt64 = 80_000_000        // 80ms safety cap (trailing pad reduced — long tail unnecessary)
            let stableNeeded = 2                      // consecutive stable samples
            let start = DispatchTime.now().uptimeNanoseconds
            var lastBytes: Int64 = audioCapture.audioFileBytesWritten
            var stableCount = 1                       // count the up-front sample
            var iterations = 0
            while DispatchTime.now().uptimeNanoseconds &- start < maxWaitNs {
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                iterations += 1
                let now = audioCapture.audioFileBytesWritten
                if now == lastBytes {
                    stableCount += 1
                    if stableCount >= stableNeeded { break }
                } else {
                    stableCount = 1                   // reset, keep counting the new baseline
                    lastBytes = now
                }
            }
            let drainMs = (CFAbsoluteTimeGetCurrent() - drainStart) * 1000
            fputs("[LATENCY] Drain (tap-flush wait): \(Int(drainMs))ms (\(iterations) polls, claimed=\(claiming != nil))\n", stderr)
        }
        audioCapture.stopWritingToFile()
        tCaptureEnd = Date()

        // Reset transcription session state (stop() no longer transcribes).
        _ = await transcription.stop()

        // Capture the session-id-at-entry. If a NEW recording starts before
        // our transcribe completes, this lets us avoid clobbering shared
        // `state.*` fields that belong to the new session. We still RETURN
        // our segments so VoiceApp's pasteChain can paste them in FIFO order
        // — only the mid-flight UI/state mirroring is suppressed.
        let entryCounter = currentRecordingSessionId
        let tag = sessTag(sessionId)
        func isStillActive() -> Bool { currentRecordingSessionId == entryCounter }
        vlog("[VOICE-RC] \(tag) phase=drain-done counter=\(entryCounter)")

        // Transcribe from the retained audio file — macparakeet approach.
        // The file is fully written and closed by stopWritingToFile() above.
        // FluidAudio handles format detection and resampling via the URL API.
        var segments: [TranscriptSegment] = []
        // FluidAudio requires ≥ 300ms of audio. Our silence padding alone is
        // ~17,920 bytes (1920-frame lead-in + 2560-frame trailing @ 4 bytes each).
        // A floor of 16KB would pass a file of pure padding with zero real speech
        // — Parakeet would see nothing but silence. Use 20,000 bytes so there must
        // be ≥ ~2 KB of real audio (≈ 32ms at 16kHz/Float32) above the padding.
        // Short replies ("ok"/"yeah"/"no") are ~200–300ms → ~12–19 KB of real
        // speech, comfortably above this floor.
        // The 36KB threshold only flips `skipPolishForCurrent` so the polish
        // stage uses rule-based formatting for very short replies (a single
        // word can get mangled by the LLM polisher).
        let fileSize = audioURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 } ?? 0
        if let audioURL = audioURL,
           FileManager.default.fileExists(atPath: audioURL.path),
           fileSize > 20_000 {
            // Only mirror to shared state when our session is still active.
            // Concurrent stopRecording() calls would otherwise clobber each
            // other's skipPolishForCurrent (consumed downstream by polish).
            let willSkipPolish = fileSize < 36_000
            if isStillActive() {
                state.skipPolishForCurrent = willSkipPolish
            }
            vlog("[VOICE-RC] \(tag) phase=transcribe-begin file=\(audioURL.lastPathComponent) bytes=\(fileSize) skipPolish=\(willSkipPolish) active=\(isStillActive())")
            do {
                let asrStart = Date()
                let fileSegments = try await transcription.transcribeFile(url: audioURL)
                tParakeetDone = Date()
                let parakeetMs = Int(Date().timeIntervalSince(asrStart) * 1000)

                // Note: NO staleness gate here. If the user re-pressed the
                // hotkey while Parakeet was running, the prior transcript
                // MUST still reach the cursor — abandoning the pipeline here
                // is what caused the "lost dictation" bug. Both pipelines
                // run to completion; paste ordering is serialized upstream
                // (VoiceApp.swift pasteChain).
                _ = mySessionId  // intentionally unused — kept for log/debug parity

                let graniteResult: String? = nil
                let moonshineResult: String? = nil

                vlog("[VOICE] ASR timings — parakeet: \(parakeetMs)ms")
                vlog("[VOICE-RC] \(tag) phase=transcribe-done segments=\(fileSegments.count) active=\(isStillActive())")
                if !fileSegments.isEmpty {
                    // Mirror to shared state only when our session is still
                    // the active one. Stale (superseded) sessions still
                    // return their segments to the caller (paste path), but
                    // do not stomp on the new recording's state fields.
                    if isStillActive() {
                        state.graniteTranscript = graniteResult
                        state.moonshineTranscript = moonshineResult
                    }
                    segments = fileSegments
                    // PERSISTENCE: Audio file stays put. The polish stage
                    // (and any future re-transcribe pass) can re-read it
                    // at the same path; the Meeting row will reference it
                    // via `audioFilePath` below. Make the URL available
                    // to in-flight polish via `lastDictationAudioURL`,
                    // but do NOT arm the deletion task. Only update the
                    // singleton lastDictationAudioURL when we're the
                    // active session — otherwise a slow trailing session
                    // would overwrite the most recent recording's URL.
                    if isStillActive() {
                        lastDictationCleanupTask?.cancel()
                        lastDictationCleanupTask = nil
                        lastDictationAudioURL = audioURL
                    }
                } else {
                    vlog("[VOICE-RC] transcribeFile returned EMPTY result")
                    // Empty transcript — KEEP audio on disk so the user
                    // can retry / re-process later. No DB row is written
                    // for the empty case, so the file becomes "orphaned"
                    // until the user reprocesses or the size-pruner reaps it.
                    NotificationCenter.default.post(
                        name: .voiceError,
                        object: nil,
                        userInfo: ["message": "Didn't catch that — try again"]
                    )
                }
            } catch {
                vlog("[VOICE-RC] transcribeFile FAILED: \(error.localizedDescription)")
                // KEEP audio on disk so the user can retry. Size-pruner
                // will eventually reap it if nothing else does.
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Transcription failed — try again"]
                )
            }
        } else {
            let exists = audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let size = audioURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 } ?? 0
            vlog("[VOICE-RC] No audio to transcribe — url=\(audioURL?.lastPathComponent ?? "nil") exists=\(exists) size=\(size)")
            // Too-small clip (sub-300ms). Drop it — there's no meaningful
            // audio to preserve, and these add up fast on accidental taps.
            if let audioURL, exists {
                try? FileManager.default.removeItem(at: audioURL)
            }
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Didn't catch that — hold to record"]
            )
        }
        vlog("[VOICE-RC] \(tag) phase=stopRecording-exit segments=\(segments.count) active=\(isStillActive())")

        // Replace any partial-derived segments with the engine's final view.
        // Only mirror to shared state when our session is still the active
        // one — otherwise a slow trailing transcribe would overwrite the new
        // recording's in-progress live transcript. The caller (VoiceApp) gets
        // the segments via the return value either way.
        if !segments.isEmpty && isStillActive() {
            state.currentTranscript = segments
        }

        // Save meeting record + auto-export.
        // Reuse `sessionId` as the Meeting primary key so the on-disk audio
        // at `audio/dictation-<id>.caf` is reachable via Meeting.audioFilePath.
        // Persist audioFilePath only when there's actually a file on disk
        // we expect to keep (segments produced → file is the canonical audio).
        let audioFilePathToSave: String? = {
            guard !segments.isEmpty, let url = audioURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.path
        }()
        // BUGFIX (double-paste race): persist THIS session's own `segments`,
        // not the shared `state.currentTranscript`. For a superseded session
        // the shared field holds a newer recording's text — saving that under
        // this session's `sessionId` would mislabel the Meeting row.
        let meeting = Meeting(
            id: sessionId,
            title: generateMeetingTitle(),
            date: tCaptureStart,
            duration: TimeInterval(state.elapsedSeconds),
            segments: segments,
            audioFilePath: audioFilePathToSave
        )

        do {
            try storage.saveMeeting(meeting)
        } catch {
            vlog("[VOICE] Storage error: \(error.localizedDescription)")
        }

        // Structured per-stage timing summary (greppable: [VOICE TIMINGS]).
        // merge+polish+paste happen downstream in VoiceApp — they're not
        // reachable from here, so this line covers capture through transcribe.
        func ms(_ a: Date?, _ b: Date?) -> String {
            guard let a, let b else { return "—" }
            return "\(Int(b.timeIntervalSince(a) * 1000))ms"
        }
        let captureMs   = ms(tCaptureStart, tCaptureEnd)
        let parakeetMs2 = ms(tCaptureEnd, tParakeetDone)
        let totalMs     = Int(Date().timeIntervalSince(tCaptureStart) * 1000)
        vlog("[VOICE TIMINGS] capture: \(captureMs) | parakeet: \(parakeetMs2) | TOTAL: \(totalMs)ms")

        // BUGFIX (double-paste race — root cause): return THIS session's own
        // locally-transcribed `segments`, NOT the shared `state.currentTranscript`.
        //
        // The double-paste: with recordings A then B overlapping, A's finish
        // task can pass VoiceApp's session guard (its body started before B's
        // press) and then call stopRecording(claiming: A). A transcribes A's
        // audio into the local `segments`, but if B's stopRecording wrote
        // `state.currentTranscript = segmentsB` first (B is the active session),
        // returning the shared field handed A's finish task B's TEXT. A then
        // pasted B's text and B pasted it again → the same message twice, and
        // A's real transcript was silently dropped ("forgets the first").
        //
        // The local `segments` is always exactly this audio file's transcript,
        // immune to any concurrent session's state mutation. Shared-state
        // mirroring above stays gated on isStillActive() for the live UI; the
        // return value is now decoupled from it.
        if !isStillActive() {
            vlog("[VOICE-RACE] stopRecording returning OWN segments for superseded session=\(sessTag(sessionId)) count=\(segments.count) (shared state.currentTranscript belongs to active session — not used)")
        }
        return segments
    }

    /// Pause/resume recording (keeps audio engine running but stops feeding).
    func togglePause() {
        state.isPaused.toggle()
    }

    // MARK: - Fetch & Search

    func fetchAllMeetings() -> [Meeting] {
        (try? storage.fetchAllMeetings()) ?? []
    }

    func searchMeetings(query: String) -> [Meeting] {
        (try? storage.searchTranscripts(query: query)) ?? []
    }

    /// Persist a Meeting created outside of the coordinator (e.g. from MeetingCaptureService).
    func saveMeeting(_ meeting: Meeting) throws {
        try storage.saveMeeting(meeting)
    }

    // MARK: - Private

    /// Build the on-disk URL for the dictation-side retained audio.
    /// Lives next to meeting audio so the recovery scanner finds it.
    private func makeDictationAudioURL(id: UUID) -> URL {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            appSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }
        let dir = appSupport.appendingPathComponent("Voice/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictation-\(id.uuidString).caf")
    }

    // NOTE: deferred-cleanup helper removed. Audio is now persistent —
    // a successful dictation keeps its file at the path stored on the
    // Meeting row. The size-based pruner (`StorageService.pruneAudioBySize`)
    // handles long-term disk pressure on app launch.

    /// Eagerly drop the retained dictation audio. Optional — the 30s deferred
    /// cleanup catches the common case. Callers (e.g. a privacy-mode toggle)
    /// can call this to delete sooner.
    func releaseLastDictationAudio() {
        lastDictationCleanupTask?.cancel()
        lastDictationCleanupTask = nil
        if let url = lastDictationAudioURL {
            try? FileManager.default.removeItem(at: url)
            lastDictationAudioURL = nil
            vlog("[VOICE-RC] released dictation audio early: \(url.lastPathComponent)")
        }
    }

    /// Auto-generate a meeting title from the first 5 content words of the
    /// transcript. Filler words at the start ("um", "uh", "so", "like", "I",
    /// "you know", "basically", "actually", "okay", "right", "well") are
    /// stripped before picking the first 5 words so recordings don't end up
    /// titled "Um so I was thinking".
    private func generateMeetingTitle() -> String {
        if let firstSegment = state.currentTranscript.first {
            let contentWords = stripFillerPrefix(firstSegment.text)
            let words = contentWords.split(separator: " ").prefix(5)
            if !words.isEmpty {
                return words.joined(separator: " ") + "..."
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Meeting \(formatter.string(from: recordingStartTime ?? Date()))"
    }

    /// Strip leading filler words from a transcript string, returning the
    /// remaining text with those words removed. Case-insensitive. Multi-word
    /// fillers ("you know", "i mean") are matched before single-word ones.
    private func stripFillerPrefix(_ text: String) -> String {
        // Ordered longest-first so multi-word phrases match before their subwords.
        let fillers: [String] = [
            "you know", "i mean", "you know what",
            "um", "uh", "uh so", "um so",
            "so", "like", "basically", "actually",
            "okay", "ok", "right", "well", "anyway",
            "i", "and",
        ]

        var remaining = text.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for filler in fillers {
                let lower = remaining.lowercased()
                let prefix = filler + " "
                if lower.hasPrefix(prefix) {
                    remaining = String(remaining.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }
        return remaining.isEmpty ? text : remaining
    }

    // MARK: - Crash Recovery

    /// Scan the audio directory for `dictation-<uuid>.caf` files whose UUID
    /// has NO matching Meeting row in the database — these are recordings
    /// that crashed during transcription. Re-transcribe them in the
    /// background and save as Meeting rows so the user doesn't lose their
    /// audio. Skips itself while a recording is active so it can't steal
    /// model time from the live path; re-checks every 2s.
    private func recoverOrphanRecordings() async {
        // Defer until any in-flight recording finishes.
        while state.isRecording || state.isTranscribing {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
        }

        // Build the set of audio file paths referenced by existing meetings.
        let referencedPaths: Set<String> = {
            let meetings = (try? storage.fetchAllMeetings()) ?? []
            return Set(meetings.compactMap { $0.audioFilePath })
        }()

        let audioDir = storage.audioDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        // Pre-filter bounds (Fix 1):
        //   minSize: 9 KB  ≈ ~280ms @ 16kHz 16-bit mono — below Parakeet's
        //   ~300ms minimum; transcribeFile would throw `invalidAudioData`.
        //   maxSize: 50 MB — anything bigger is likely corrupt/runaway and
        //   not worth burning model time on at startup.
        let minSize = 9 * 1024
        let maxSize = 50 * 1024 * 1024
        // Quarantine root + age threshold for Fix 2.
        let quarantineRoot = audioDir.appendingPathComponent("quarantine", isDirectory: true)
        let staleThreshold: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        let now = Date()

        // Orphan = file on disk, named `dictation-<uuid>.caf`, not referenced
        // by any Meeting row. We deliberately filter on the `dictation-`
        // prefix so we don't accidentally try to re-transcribe meeting
        // recordings whose row was deleted intentionally.
        struct OrphanCandidate {
            let url: URL
            let mtime: Date
            let size: Int
        }
        var candidates: [OrphanCandidate] = []
        var skippedSize = 0
        var skippedTooBig = 0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("dictation-"),
                  url.pathExtension.lowercased() == "caf",
                  !referencedPaths.contains(url.path) else { continue }
            // Skip writer-rollover siblings like `dictation-<uuid>.part2.caf`.
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.contains(".") { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            // Fix 1: pre-filter by size.
            if size < minSize { skippedSize += 1; continue }
            if size > maxSize { skippedTooBig += 1; continue }
            candidates.append(OrphanCandidate(url: url, mtime: mtime, size: size))
        }

        // Fix 2: sort newest-first, cap at 20. Anything older than 7 days
        // goes to quarantine/<YYYY-MM-DD>/ instead of being re-processed.
        candidates.sort { $0.mtime > $1.mtime }
        let recoveryCap = 20
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        var quarantinedStale = 0
        var quarantinedOverflow = 0
        var orphans: [URL] = []
        for (idx, candidate) in candidates.enumerated() {
            let age = now.timeIntervalSince(candidate.mtime)
            if age > staleThreshold {
                let dayDir = quarantineRoot.appendingPathComponent(dateFormatter.string(from: candidate.mtime), isDirectory: true)
                if moveToQuarantine(candidate.url, dest: dayDir) {
                    quarantinedStale += 1
                }
                continue
            }
            if idx >= recoveryCap {
                let dayDir = quarantineRoot.appendingPathComponent(dateFormatter.string(from: candidate.mtime), isDirectory: true)
                if moveToQuarantine(candidate.url, dest: dayDir) {
                    quarantinedOverflow += 1
                }
                continue
            }
            orphans.append(candidate.url)
        }

        if skippedSize + skippedTooBig + quarantinedStale + quarantinedOverflow > 0 {
            vlog("[VOICE-RC] orphan recovery: pre-filter skipped=\(skippedSize) too-small, \(skippedTooBig) too-big; quarantined=\(quarantinedStale) stale, \(quarantinedOverflow) overflow")
        }

        guard !orphans.isEmpty else {
            vlog("[VOICE-RC] orphan recovery: none found")
            return
        }
        vlog("[VOICE-RC] orphan recovery: found \(orphans.count) crashed recording(s) — transcribing")

        for url in orphans {
            // Defer per-file when the user starts using the app.
            while state.isRecording || state.isTranscribing {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }

            // Parse UUID out of the filename so the recovered Meeting reuses
            // the original session ID (keeps the audio file's name-to-id
            // contract intact).
            let stem = url.deletingPathExtension().lastPathComponent
            let uuidString = String(stem.dropFirst("dictation-".count))
            let recoveredId = UUID(uuidString: uuidString) ?? UUID()

            do {
                let segments = try await transcription.transcribeFile(url: url)
                guard !segments.isEmpty else {
                    // Fix 3: an empty transcript means this file is silence /
                    // unintelligible. Move it to quarantine/empty/ so it
                    // doesn't haunt future launches.
                    let emptyDir = storage.audioDirectoryURL
                        .appendingPathComponent("quarantine", isDirectory: true)
                        .appendingPathComponent("empty", isDirectory: true)
                    if moveToQuarantine(url, dest: emptyDir) {
                        vlog("[VOICE-RC] orphan recovery: \(url.lastPathComponent) → empty transcript, moved to quarantine/empty/")
                    } else {
                        vlog("[VOICE-RC] orphan recovery: \(url.lastPathComponent) → empty transcript, quarantine move FAILED")
                    }
                    continue
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
                let rawFirst = segments.first?.text ?? ""
                let firstWords = stripFillerPrefix(rawFirst).split(separator: " ").prefix(5).joined(separator: " ")
                let title = firstWords.isEmpty ? "Recovered dictation" : firstWords + "…"
                let meeting = Meeting(
                    id: recoveredId,
                    title: title,
                    date: modDate,
                    duration: segments.last?.endTime ?? 0,
                    segments: segments,
                    audioFilePath: url.path
                )
                try storage.saveMeeting(meeting)
                vlog("[VOICE-RC] orphan recovery: saved \(url.lastPathComponent) → '\(title)' (\(segments.count) segments)")
            } catch {
                vlog("[VOICE-RC] orphan recovery: \(url.lastPathComponent) FAILED: \(error.localizedDescription) — leaving on disk")
            }
        }
        vlog("[VOICE-RC] orphan recovery: pass complete")
    }

    /// Move `url` into `dest`, creating `dest` if needed. On filename
    /// collision, appends a numeric suffix. Returns true on success.
    /// Used by orphan recovery to retire stale / empty / overflow files
    /// without deleting them — they remain recoverable from disk.
    private func moveToQuarantine(_ url: URL, dest: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            vlog("[VOICE-RC] quarantine: mkdir failed for \(dest.path): \(error.localizedDescription)")
            return false
        }
        var target = dest.appendingPathComponent(url.lastPathComponent)
        var n = 1
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while fm.fileExists(atPath: target.path) {
            let candidateName = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            target = dest.appendingPathComponent(candidateName)
            n += 1
            if n > 1000 { return false }
        }
        do {
            try fm.moveItem(at: url, to: target)
            return true
        } catch {
            vlog("[VOICE-RC] quarantine: move \(url.lastPathComponent) → \(target.path) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Live Partials (lock mode only)

    /// Start the sliding-window ASR manager for live preview during lock mode.
    /// Reuses already-loaded AsrModels from TranscriptionService — zero extra download.
    /// Audio is delivered via AudioCaptureService's onPCMBuffer secondary callback.
    func startLivePartials() {
        // Idempotent: if a previous sliding-window manager is still alive
        // (e.g. rapid lock-toggle re-entry), tear it down first. Without
        // this the prior manager remains subscribed to PCM buffers via a
        // stale closure capture and leaks until process exit.
        if slidingWindowManager != nil || livePartialsTask != nil {
            stopLivePartials()
        }

        // Clear any stale text from a prior session.
        state.livePartialText = ""
        state.livePartialIsVolatile = true

        // Models must be loaded for this to work. If not ready, fail silently —
        // the final batch transcription is unaffected.
        guard let models = transcription.asrModels else {
            vlog("[VOICE-LP] startLivePartials: asrModels not available, skipping live preview")
            return
        }

        let manager = SlidingWindowAsrManager(config: .streaming)
        slidingWindowManager = manager

        // Subscribe to transcription updates.
        livePartialsTask = Task { [weak self] in
            guard let self else { return }

            // Load models on the actor — uses shared AsrModels (no download).
            do {
                try await manager.loadModels(models)
                // Vocabulary biasing — wire merged starter+user dictionary
                // into CTC rescoring on the streaming path so live partials
                // surface correctly-spelled tech terms (ChatGPT, GitHub,
                // Anthropic, …) instead of phonetic mis-decodes. Requires
                // a separate CTC model (~110MB) that downloads on first use.
                // Failures here are non-fatal (path still works without it).
                do {
                    let ctcModels = try await CtcModels.downloadAndLoad()
                    try await manager.configureVocabularyBoosting(
                        vocabulary: CombinedDictionary.vocabularyContext(),
                        ctcModels: ctcModels
                    )
                    vlog("[VOICE-LP] vocabulary boosting configured (\(CombinedDictionary.terms().count) terms)")
                } catch {
                    vlog("[VOICE-LP] vocabulary boosting unavailable: \(error.localizedDescription)")
                }
                try await manager.startStreaming(source: .microphone)
            } catch {
                vlog("[VOICE-LP] Failed to start sliding window: \(error.localizedDescription)")
                return
            }

            // On each update, read the manager's authoritative confirmed + volatile
            // transcripts directly. This avoids double-counting from manual
            // accumulation — the manager handles the confirmed/volatile boundary.
            for await update in await manager.transcriptionUpdates {
                if Task.isCancelled { break }
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                let isConfirmed = update.isConfirmed
                await MainActor.run {
                    var parts: [String] = []
                    if !confirmed.isEmpty { parts.append(confirmed) }
                    if !volatile.isEmpty && volatile != confirmed { parts.append(volatile) }
                    self.state.livePartialText = parts.joined(separator: " ")
                    self.state.livePartialIsVolatile = !update.isConfirmed

                    // Stop-word detection. Only on the CONFIRMED transcript
                    // (volatile partials churn and mis-decode), only while
                    // hands-free (locked) and recording, and only at the
                    // trailing edge — the phrase must be the last thing said,
                    // so a mid-utterance mention ("...we should definitively...")
                    // never triggers. Debounced to a single fire.
                    if isConfirmed { self.checkStopWord(in: confirmed) }
                }
            }
        }

        // Wire PCM buffers from the capture service into the sliding window.
        audioCapture.onPCMBuffer = { [weak manager] pcmBuffer in
            guard let manager else { return }
            Task { await manager.streamAudio(pcmBuffer) }
        }

        vlog("[VOICE-LP] Live partials started")
    }

    /// Stop the sliding-window live preview and clear partial text.
    func stopLivePartials() {
        audioCapture.onPCMBuffer = nil

        livePartialsTask?.cancel()
        livePartialsTask = nil

        if let manager = slidingWindowManager {
            Task { await manager.cancel() }
            slidingWindowManager = nil
        }

        state.livePartialText = ""
        state.livePartialIsVolatile = true
        lastStopWordFireAt = nil

        vlog("[VOICE-LP] Live partials stopped")
    }

    // MARK: - Stop word

    /// Evaluate the confirmed live transcript for the trailing stop word and
    /// fire `onStopWordDetected` once (debounced). Gated to hands-free
    /// (locked) recordings — PTT stops on key release and needs no stop word.
    @MainActor
    private func checkStopWord(in confirmed: String) {
        guard state.isLocked, state.isRecording else { return }
        let enabled = UserDefaults.standard.object(forKey: "voice.stopWordEnabled") as? Bool ?? true
        guard enabled else { return }
        let stopWord = (UserDefaults.standard.string(forKey: "voice.stopWord") ?? "finito")
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopWord.isEmpty, Self.endsWithStopWord(confirmed, stopWord: stopWord) else { return }
        if let last = lastStopWordFireAt, Date().timeIntervalSince(last) < 1.5 { return }
        lastStopWordFireAt = Date()
        vlog("[VOICE-STOPWORD] trailing stop word \"\(stopWord)\" detected — committing recording")
        onStopWordDetected?()
    }

    /// True if `text`, ignoring trailing whitespace/punctuation, ends with
    /// `stopWord` as a whole word (the char before it is a boundary).
    static func endsWithStopWord(_ text: String, stopWord: String) -> Bool {
        let trimmed = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,!?;:\"'"))
        guard trimmed.hasSuffix(stopWord), trimmed.count >= stopWord.count else { return false }
        let idx = trimmed.index(trimmed.endIndex, offsetBy: -stopWord.count)
        if idx == trimmed.startIndex { return true }
        let before = trimmed[trimmed.index(before: idx)]
        return !before.isLetter && !before.isNumber
    }

    /// Remove a trailing stop-word command token (and any dangling
    /// punctuation/whitespace before it) from a FINAL transcript. Trailing
    /// only — a legitimately-dictated earlier mention is preserved. Returns
    /// the text unchanged when the stop word is disabled or absent at the end.
    static func strippingTrailingStopWord(from text: String) -> String {
        let enabled = UserDefaults.standard.object(forKey: "voice.stopWordEnabled") as? Bool ?? true
        guard enabled else { return text }
        let stopWord = (UserDefaults.standard.string(forKey: "voice.stopWord") ?? "finito")
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopWord.isEmpty, endsWithStopWord(text, stopWord: stopWord),
              let range = text.range(of: stopWord, options: [.caseInsensitive, .backwards])
        else { return text }
        let head = String(text[..<range.lowerBound])
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,!?;:"))
    }
}
