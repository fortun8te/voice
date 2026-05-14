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
    private let storage = StorageService()

    // State (shared with UI via RecordingState)
    var state: RecordingState

    // Internal
    private var recordingStartTime: Date?
    private var elapsedTimer: Timer?
    private var levelsTimer: Timer?
    private var startupTask: Task<Void, Never>?

    /// URL of the retained audio file for the current recording (if any).
    private var currentAudioFileURL: URL?

    /// URL of the most recently completed dictation's audio file. Kept on
    /// disk through the Qwen3 polish stage so a future re-transcribe pass
    /// (or a "redo with vocabulary" feature) can read the same audio
    /// without re-recording. A delayed cleanup task removes the file 30s
    /// after `stopRecording()` returns — well past the polish window
    /// (~80–2500ms) — unless `releaseLastDictationAudio()` is called first.
    private(set) var lastDictationAudioURL: URL?
    private var lastDictationCleanupTask: Task<Void, Never>?

    // Live-partials sliding window for lock-mode preview.
    private var slidingWindowManager: SlidingWindowAsrManager?
    private var livePartialsTask: Task<Void, Never>?

    init(state: RecordingState) {
        self.state = state
    }

    // MARK: - Lifecycle

    /// Call once at app launch to load models and prepare services.
    func prepare() async {
        do {
            try storage.initialize()

            // Sync model state to UI as Parakeet downloads/loads.
            state.modelState = .downloading(progress: 0)
            try await transcription.prepare()
            state.modelState = transcription.modelState

            // Warm audio engine so first record doesn't pay cold-start cost
            // (~50–100ms HAL/AU initialization on first AVAudioEngine instance).
            audioCapture.warmup()

            // Pre-warm LLM polisher so first dictation isn't slow. For Qwen3
            // this also kicks off the one-time ~380MB model download into the
            // Hugging Face cache (no-op on subsequent launches).
            Qwen3Polisher.shared.prewarm()

            // Force lazy init of the SoundEffects engine so the first
            // playStart() earcon doesn't pay ~20ms engine.start() cost.
            _ = SoundEffects.self
        } catch {
            state.modelState = .error(error.localizedDescription)
            print("[VOICE] Initialization error: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording Control

    /// Start recording from the configured audio source.
    func startRecording() {
        let enterTime = Date()
        print("[VOICE-RC] startRecording() ENTER at \(enterTime) (already recording: \(state.isRecording))")
        guard !state.isRecording else {
            print("[VOICE-RC] startRecording() EARLY-EXIT — already recording")
            return
        }

        print("[VOICE-RC] isRecording: false → true at \(Date()) (SYNC, before any Task)")
        state.isRecording = true
        state.isPaused = false
        state.elapsedSeconds = 0
        state.currentTranscript = []
        recordingStartTime = Date()

        let sessionId = UUID()
        let audioURL = makeDictationAudioURL(id: sessionId)
        do {
            try audioCapture.startWritingToFile(url: audioURL)
            // Only record the URL after the writer is open. If
            // startWritingToFile threw, no file was created, so there is
            // nothing to track or leak.
            self.currentAudioFileURL = audioURL
            print("[VOICE-RC] startWritingToFile OK → \(audioURL.lastPathComponent)")
        } catch {
            // Not fatal — dictation can run without retained audio,
            // we just won't be able to re-transcribe on recovery.
            print("[VOICE-RC] dictation audio retention FAILED: \(error.localizedDescription)")
        }

        // Start elapsed timer
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPaused else { return }
                self.state.elapsedSeconds += 1
            }
        }

        // Update visualizer levels from audio capture at 30fps.
        levelsTimer?.invalidate()
        levelsTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.state.isRecording else {
                    timer.invalidate()
                    return
                }
                self.state.audioLevels = self.audioCapture.audioLevels
            }
        }

        // Start microphone capture immediately — no need to wait for transcription.start()
        // because feed() is a no-op (we transcribe from the retained file at stop time).
        // Delaying capture inside an async Task caused the first syllable to be clipped.
        let audioSource = UserDefaults.standard.string(forKey: "audioSource") ?? "microphone"
        print("[VOICE-RC] audioSource = \(audioSource)")
        if audioSource != "system" {
            do {
                // feed() is a no-op; the capture service writes directly to file.
                print("[VOICE-RC] AVAudioEngine.start (mic) at \(Date())")
                try audioCapture.startMicrophoneCapture { _ in }
                print("[VOICE-RC] AVAudioEngine.start OK")
            } catch {
                print("[VOICE-RC] Microphone capture ERROR: \(error.localizedDescription)")
                Task { @MainActor in _ = await self.stopRecording() }
                return
            }
        }

        // transcription.start() is instant (marks session start) but must precede stop().
        // System audio capture is async so it lives here too.
        print("[VOICE-RC] spawning startupTask (async transcription.start)")
        startupTask = Task { @MainActor in
            do {
                try await transcription.start()
                print("[VOICE-RC] transcription.start() OK in task")
            } catch {
                print("[VOICE-RC] transcription.start FAILED: \(error.localizedDescription)")
                _ = await self.stopRecording()
                return
            }
            guard self.state.isRecording else {
                print("[VOICE-RC] startupTask: state.isRecording flipped false during await — aborting")
                _ = await transcription.stop()
                return
            }
            if audioSource == "system" {
                do {
                    try await audioCapture.startSystemAudioCapture { _ in }
                } catch {
                    print("[VOICE-RC] System audio capture ERROR: \(error.localizedDescription)")
                    _ = await self.stopRecording()
                }
            }
        }
        print("[VOICE-RC] startRecording() EXIT at \(Date()) — isRecording=\(state.isRecording) (elapsed \(Int(Date().timeIntervalSince(enterTime) * 1000))ms)")
    }

    /// Stop recording and return the final transcript. Awaiting this gives
    /// the streaming engine a chance to flush its right-context tail.
    @discardableResult
    func stopRecording() async -> [TranscriptSegment] {
        print("[VOICE-RC] stopRecording() ENTER at \(Date()) isRecording=\(state.isRecording)")
        guard state.isRecording else {
            print("[VOICE-RC] stopRecording() EARLY-EXIT — not recording (returning \(state.currentTranscript.count) cached segments)")
            return state.currentTranscript
        }

        // Capture file URL locally — `currentAudioFileURL` may be overwritten
        // by a re-press while we're awaiting transcription. After this point
        // the instance property is cleared so a new startRecording() can
        // safely assign a fresh URL without trampling this in-flight session.
        let audioURL = currentAudioFileURL
        self.currentAudioFileURL = nil

        startupTask?.cancel()
        // Await the startup task's completion so a stop initiated while the
        // detached startup is still mid-flight doesn't race with our cleanup.
        if let task = startupTask {
            _ = await task.value
        }
        startupTask = nil

        print("[VOICE-RC] isRecording: true → false at \(Date())")
        state.isRecording = false
        state.isPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        levelsTimer?.invalidate()
        levelsTimer = nil
        // Stop the audio engine.
        print("[VOICE-RC] AVAudioEngine.stop at \(Date())")
        audioCapture.stopCapture()
        // Drain in-flight audio I/O callbacks before closing the file.
        // AVAudioEngine.removeTap (inside stopCapture) is not synchronous
        // with the I/O thread — tap buffers at 48kHz/4096 frames are ~85ms,
        // so 200ms reliably covers 2+ buffers and prevents clipping the
        // last syllable. The extra ~100ms on stop is worth never losing
        // the final word.
        try? await Task.sleep(nanoseconds: 200_000_000)
        audioCapture.stopWritingToFile()

        // Reset transcription session state (stop() no longer transcribes).
        _ = await transcription.stop()

        // Transcribe from the retained audio file — macparakeet approach.
        // The file is fully written and closed by stopWritingToFile() above.
        // FluidAudio handles format detection and resampling via the URL API.
        var segments: [TranscriptSegment] = []
        // FluidAudio requires ≥ 300ms of audio (ASRError.invalidAudioData
        // otherwise). With our 120ms lead-in + 160ms trailing zero pads in
        // AudioCaptureService that's 280ms of guaranteed silence, so we
        // need at least ~250ms of real speech on top — gate at 36k bytes
        // (~560ms of Float32 mono @ 16kHz) to leave a real-speech margin
        // and route accidental hotkey taps to a friendly "Didn't catch
        // that" instead of swallowing a real .invalidAudioData throw.
        if let audioURL = audioURL,
           FileManager.default.fileExists(atPath: audioURL.path),
           (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0 > 36_000 {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
            print("[VOICE-RC] WhisperKit/Parakeet transcribe call: \(audioURL.lastPathComponent) (\(fileSize) bytes)")
            do {
                let fileSegments = try await transcription.transcribeFile(url: audioURL)
                print("[VOICE-RC] transcribe returned \(fileSegments.count) segments")
                if !fileSegments.isEmpty {
                    segments = fileSegments
                    // Defer deletion — the polish stage (or a future re-
                    // transcribe pass) may want to read the audio again.
                    // Cleanup happens 30s from now unless a new recording
                    // replaces the URL first.
                    scheduleDictationAudioCleanup(audioURL)
                } else {
                    print("[VOICE-RC] transcribeFile returned EMPTY result")
                    // Empty transcript — no polish stage will run, safe to
                    // delete immediately.
                    try? FileManager.default.removeItem(at: audioURL)
                    NotificationCenter.default.post(
                        name: .voiceError,
                        object: nil,
                        userInfo: ["message": "Didn't catch that — try again"]
                    )
                }
            } catch {
                print("[VOICE-RC] transcribeFile FAILED: \(error.localizedDescription)")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Transcription failed — try again"]
                )
            }
        } else {
            let exists = audioURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let size = audioURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 } ?? 0
            print("[VOICE-RC] No audio to transcribe — url=\(audioURL?.lastPathComponent ?? "nil") exists=\(exists) size=\(size)")
            // Clean up the tiny file and surface a friendly hint so the
            // user knows nothing was captured (vs. silently doing nothing).
            if let audioURL, exists {
                try? FileManager.default.removeItem(at: audioURL)
            }
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Didn't catch that — hold to record"]
            )
        }
        print("[VOICE-RC] stopRecording() EXIT — returning \(segments.count) segments")

        // Replace any partial-derived segments with the engine's final view.
        if !segments.isEmpty {
            state.currentTranscript = segments
        }

        // Save meeting record + auto-export.
        let meeting = Meeting(
            title: generateMeetingTitle(),
            date: recordingStartTime ?? Date(),
            duration: TimeInterval(state.elapsedSeconds),
            segments: state.currentTranscript
        )

        do {
            try storage.saveMeeting(meeting)
        } catch {
            print("[VOICE] Storage error: \(error.localizedDescription)")
        }

        return state.currentTranscript
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

    /// Defer deletion of the just-completed dictation audio. Promotes the URL
    /// to `lastDictationAudioURL` so callers (notably the polish stage) can
    /// read it back, then arms a 30s cleanup task. Any prior pending cleanup
    /// is cancelled and its file deleted immediately so we don't leak older
    /// recordings on rapid back-to-back dictations.
    private func scheduleDictationAudioCleanup(_ url: URL) {
        // Cancel + drop any previous deferred cleanup. Delete its file now
        // since the new dictation has superseded it.
        lastDictationCleanupTask?.cancel()
        if let prev = lastDictationAudioURL, prev != url {
            try? FileManager.default.removeItem(at: prev)
        }
        lastDictationAudioURL = url

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.lastDictationAudioURL == url {
                    try? FileManager.default.removeItem(at: url)
                    self.lastDictationAudioURL = nil
                    self.lastDictationCleanupTask = nil
                    print("[VOICE-RC] deferred dictation audio cleanup ran: \(url.lastPathComponent)")
                }
            }
        }
        lastDictationCleanupTask = task
    }

    /// Eagerly drop the retained dictation audio. Optional — the 30s deferred
    /// cleanup catches the common case. Callers (e.g. a privacy-mode toggle)
    /// can call this to delete sooner.
    func releaseLastDictationAudio() {
        lastDictationCleanupTask?.cancel()
        lastDictationCleanupTask = nil
        if let url = lastDictationAudioURL {
            try? FileManager.default.removeItem(at: url)
            lastDictationAudioURL = nil
            print("[VOICE-RC] released dictation audio early: \(url.lastPathComponent)")
        }
    }

    /// TWEAK: Auto-generate meeting title from first few words or calendar event
    private func generateMeetingTitle() -> String {
        if let firstSegment = state.currentTranscript.first {
            let words = firstSegment.text.split(separator: " ").prefix(5)
            if !words.isEmpty {
                return words.joined(separator: " ") + "..."
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Meeting \(formatter.string(from: recordingStartTime ?? Date()))"
    }

    // MARK: - Live Partials (lock mode only)

    /// Start the sliding-window ASR manager for live preview during lock mode.
    /// Reuses already-loaded AsrModels from TranscriptionService — zero extra download.
    /// Audio is delivered via AudioCaptureService's onPCMBuffer secondary callback.
    func startLivePartials() {
        // Clear any stale text from a prior session.
        state.livePartialText = ""
        state.livePartialIsVolatile = true

        // Models must be loaded for this to work. If not ready, fail silently —
        // the final batch transcription is unaffected.
        guard let models = transcription.asrModels else {
            print("[VOICE-LP] startLivePartials: asrModels not available, skipping live preview")
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
                    print("[VOICE-LP] vocabulary boosting configured (\(CombinedDictionary.terms().count) terms)")
                } catch {
                    print("[VOICE-LP] vocabulary boosting unavailable: \(error.localizedDescription)")
                }
                try await manager.startStreaming(source: .microphone)
            } catch {
                print("[VOICE-LP] Failed to start sliding window: \(error.localizedDescription)")
                return
            }

            // On each update, read the manager's authoritative confirmed + volatile
            // transcripts directly. This avoids double-counting from manual
            // accumulation — the manager handles the confirmed/volatile boundary.
            for await update in await manager.transcriptionUpdates {
                if Task.isCancelled { break }
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                await MainActor.run {
                    var parts: [String] = []
                    if !confirmed.isEmpty { parts.append(confirmed) }
                    if !volatile.isEmpty && volatile != confirmed { parts.append(volatile) }
                    self.state.livePartialText = parts.joined(separator: " ")
                    self.state.livePartialIsVolatile = !update.isConfirmed
                }
            }
        }

        // Wire PCM buffers from the capture service into the sliding window.
        audioCapture.onPCMBuffer = { [weak manager] pcmBuffer in
            guard let manager else { return }
            Task { await manager.streamAudio(pcmBuffer) }
        }

        print("[VOICE-LP] Live partials started")
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

        print("[VOICE-LP] Live partials stopped")
    }
}
