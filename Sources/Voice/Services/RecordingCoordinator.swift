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

    /// UUID that names the current recording's audio file AND will be
    /// reused as the Meeting.id on save — so the persisted audio at
    /// `<AppSupport>/Voice/audio/dictation-<id>.caf` is reachable from
    /// the transcript row via `Meeting.audioFilePath`.
    private var currentSessionId: UUID?

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

    init(state: RecordingState) {
        self.state = state
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

            // Crashed-recording recovery: scan for orphan dictation audio
            // (files on disk with no matching Meeting row) and re-transcribe
            // them in the background. If the user starts a new recording
            // before this completes, the recovery loop defers itself.
            orphanRecoveryTask = Task { @MainActor [weak self] in
                await self?.recoverOrphanRecordings()
            }
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

        // PERSISTENCE GUARANTEE: the audio file is named by the same UUID
        // that will become the Meeting's primary key, so the recording's
        // audio lives at a stable, lookup-by-ID path for the lifetime of
        // the transcript. See `stopRecording()` where this ID is used as
        // the Meeting.id and written to Meeting.audioFilePath.
        let sessionId = UUID()
        self.currentSessionId = sessionId
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
        let sessionId = currentSessionId ?? UUID()
        self.currentAudioFileURL = nil
        self.currentSessionId = nil

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
        // with the I/O thread — tap buffers may still land for a short
        // window. Rather than paying a flat 200ms tax on every dictation,
        // poll `audioFileBytesWritten` until it goes quiet for two
        // consecutive samples (or the safety cap fires). On a quiet
        // system this typically completes in <30ms; the cap is 250ms.
        do {
            let pollIntervalNs: UInt64 = 15_000_000   // 15ms
            let maxWaitNs: UInt64 = 250_000_000       // 250ms safety cap
            let stableNeeded = 2                      // consecutive stable samples
            let start = DispatchTime.now().uptimeNanoseconds
            var lastBytes: Int64 = audioCapture.audioFileBytesWritten
            var stableCount = 0
            while DispatchTime.now().uptimeNanoseconds &- start < maxWaitNs {
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                let now = audioCapture.audioFileBytesWritten
                if now == lastBytes {
                    stableCount += 1
                    if stableCount >= stableNeeded { break }
                } else {
                    stableCount = 0
                    lastBytes = now
                }
            }
        }
        audioCapture.stopWritingToFile()

        // Reset transcription session state (stop() no longer transcribes).
        _ = await transcription.stop()

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
            state.skipPolishForCurrent = fileSize < 36_000
            print("[VOICE-RC] WhisperKit/Parakeet transcribe call: \(audioURL.lastPathComponent) (\(fileSize) bytes) skipPolish=\(state.skipPolishForCurrent)")
            do {
                let fileSegments = try await transcription.transcribeFile(url: audioURL)
                print("[VOICE-RC] transcribe returned \(fileSegments.count) segments")
                if !fileSegments.isEmpty {
                    segments = fileSegments
                    // PERSISTENCE: Audio file stays put. The polish stage
                    // (and any future re-transcribe pass) can re-read it
                    // at the same path; the Meeting row will reference it
                    // via `audioFilePath` below. Make the URL available
                    // to in-flight polish via `lastDictationAudioURL`,
                    // but do NOT arm the deletion task.
                    lastDictationCleanupTask?.cancel()
                    lastDictationCleanupTask = nil
                    lastDictationAudioURL = audioURL
                } else {
                    print("[VOICE-RC] transcribeFile returned EMPTY result")
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
                print("[VOICE-RC] transcribeFile FAILED: \(error.localizedDescription)")
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
            print("[VOICE-RC] No audio to transcribe — url=\(audioURL?.lastPathComponent ?? "nil") exists=\(exists) size=\(size)")
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
        print("[VOICE-RC] stopRecording() EXIT — returning \(segments.count) segments")

        // Replace any partial-derived segments with the engine's final view.
        if !segments.isEmpty {
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
        let meeting = Meeting(
            id: sessionId,
            title: generateMeetingTitle(),
            date: recordingStartTime ?? Date(),
            duration: TimeInterval(state.elapsedSeconds),
            segments: state.currentTranscript,
            audioFilePath: audioFilePathToSave
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
            print("[VOICE-RC] released dictation audio early: \(url.lastPathComponent)")
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
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        // Orphan = file on disk, named `dictation-<uuid>.caf`, not referenced
        // by any Meeting row. We deliberately filter on the `dictation-`
        // prefix so we don't accidentally try to re-transcribe meeting
        // recordings whose row was deleted intentionally.
        let orphans: [URL] = entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("dictation-"),
                  url.pathExtension.lowercased() == "caf",
                  !referencedPaths.contains(url.path) else { return false }
            // Skip tiny files — must exceed padding baseline (see stopRecording comment).
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > 20_000
        }

        guard !orphans.isEmpty else {
            print("[VOICE-RC] orphan recovery: none found")
            return
        }
        print("[VOICE-RC] orphan recovery: found \(orphans.count) crashed recording(s) — transcribing")

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
                    print("[VOICE-RC] orphan recovery: \(url.lastPathComponent) → empty transcript, leaving on disk")
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
                print("[VOICE-RC] orphan recovery: saved \(url.lastPathComponent) → '\(title)' (\(segments.count) segments)")
            } catch {
                print("[VOICE-RC] orphan recovery: \(url.lastPathComponent) FAILED: \(error.localizedDescription) — leaving on disk")
            }
        }
        print("[VOICE-RC] orphan recovery: pass complete")
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
