// VOICE — Audio Capture Service
// ============================================================
// Handles all audio input: microphone via AVAudioEngine and
// system audio via ScreenCaptureKit (macOS 14+).
//
// Architecture:
// - Microphone: AVAudioEngine.inputNode tap → 16kHz mono Float32
// - System audio: SCStream with audio-only config → same format
// - Both feed into a shared ring buffer for transcription
// - FFT analysis runs in parallel for the visualizer
//
// TWEAK: sampleRate — 16000 is optimal for Whisper/Parakeet (don't change unless needed)
// TWEAK: bufferSize — 4096 samples = ~256ms chunks. Larger = more latency, less CPU
// TWEAK: fftSize — 32 bins for visualizer. More bins = more detail, more CPU
// TWEAK: silenceThreshold — energy level below which we consider silence
// ============================================================

import AVFoundation
import Accelerate  // vDSP for FFT
import ScreenCaptureKit

// MARK: - AudioCaptureService

@Observable
class AudioCaptureService {
    // TWEAK: Audio format settings
    private let sampleRate: Double = 16000      // Whisper/Parakeet expects 16kHz
    private let bufferSize: AVAudioFrameCount = 4096  // ~256ms per buffer
    private let fftBinCount = 32                // TWEAK: Number of visualizer bars

    // TWEAK: Silence detection
    private let silenceThreshold: Float = 0.01  // RMS below this = silence
    private let silenceTimeoutSeconds: Double = 5.0  // Auto-stop after N seconds silence

    // State
    var isCapturing = false
    var audioLevels: [Float] = Array(repeating: 0, count: 32)
    var currentRMS: Float = 0

    // Internal
    private var audioEngine: AVAudioEngine?
    private var onSamples: (([Float]) -> Void)?    // Callback for each tap buffer
    /// Secondary callback that receives the resampled 16kHz mono PCM buffer
    /// (same buffer written to disk). Used by the live-partials sliding window.
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var silenceTimer: Timer?
    /// Called when silence exceeds `silenceTimeoutSeconds` during lock mode.
    var onSilenceTimeout: (() -> Void)?
    fileprivate var audioConverter: AVAudioConverter?
    fileprivate var targetFormat: AVAudioFormat?
    private var configChangeToken: NSObjectProtocol?

    // Optional passthrough writer — when set (via startWritingToFile), every
    // resampled 16kHz mono Float32 buffer is appended to this file in
    // addition to being delivered to `onSamples`. Used by MeetingRecorder
    // to retain the meeting audio on disk for post-hoc batch re-transcription.
    private var audioFileWriter: AVAudioFile?
    /// Bytes written to the current audio file. Read by MeetingRecorder for
    /// the heartbeat log so we can verify the file is actually growing.
    private(set) var audioFileBytesWritten: Int64 = 0
    /// The on-disk URL currently being written to, if any.
    private(set) var audioFileURL: URL?
    /// Lock guarding `audioFileWriter` since the tap closures fire on a
    /// background queue while start/stop run on the main actor.
    private let writerLock = NSLock()
    /// Settings dict used to re-open the audio file if a write fails
    /// mid-recording (we then create a `-part2` sibling and keep going).
    private var audioFileSettings: [String: Any]?
    /// Monotonic suffix counter for stitched-part files (`-part2`, `-part3`).
    private var audioFilePartIndex: Int = 1
    /// All on-disk audio file URLs that have been written for the current
    /// recording. The first entry is the primary file; subsequent entries
    /// are part-2, part-3, etc. after re-open. Exposed so the caller can
    /// stitch them back together in post-processing.
    private(set) var audioFilePartURLs: [URL] = []
    /// Wall-clock time the engine was started; used to surface a warning
    /// once we cross the 2-hour mark on a single engine instance.
    private var engineStartedAt: Date?
    /// Set to true once we have logged the >2h warning so we don't spam.
    private var engineLongRunningWarningEmitted = false
    /// Driven by the audio tap — used to log a "still writing" heartbeat
    /// roughly every 10 seconds based on frames written, no Timer needed.
    private var framesSinceLastProgressLog: Int = 0

    /// Wall-clock of the last tap buffer we received. Watchdog uses this to
    /// detect a silently-stalled mic (permission revoked mid-record, device
    /// unplugged, kernel input HAL wedged). Initialised lazily in
    /// startMicrophoneCapture.
    private var lastAudioReceivedAt: Date = Date()
    /// Periodic timer that fires `.voiceError` if no audio has arrived in
    /// >3s while we should be capturing. Created in startMicrophoneCapture,
    /// invalidated in stopCapture.
    private var silenceWatchdog: Timer?

    // MARK: - Public API

    /// Pre-warm the audio graph so the first `startMicrophoneCapture` call
    /// doesn't pay AVAudioEngine cold-start cost (~50–100ms on first record).
    ///
    /// We build a throwaway engine, touch its inputNode (resolves the audio
    /// graph and the input HAL unit), call `prepare()` to pre-allocate
    /// buffers, and discard it. We do NOT install a tap or call `start()` —
    /// the goal is to warm the OS-side audio subsystem, not to actually
    /// record. Safe to call from any thread; failures are swallowed.
    func warmup() {
        // Building an AVAudioEngine alone triggers HAL/AU initialization the
        // first time it happens in-process. We just need the side effects.
        let warmEngine = AVAudioEngine()
        _ = warmEngine.inputNode.inputFormat(forBus: 0)  // resolve input format
        warmEngine.prepare()                              // pre-alloc buffers
        // warmEngine deinits at scope exit — nothing else to clean up.
    }

    /// Start capturing from the default microphone.
    /// `onSamples` is called with each tap buffer's worth of 16kHz mono Float32
    /// PCM (every ~100-300ms depending on hardware buffer size). The streaming
    /// transcription engine handles its own internal buffering.
    func startMicrophoneCapture(onSamples: @escaping ([Float]) -> Void) throws {
        // Idempotency guard: a prior capture may still be active if startRecording
        // was called twice in quick succession. Tear it down first so we don't leak
        // a dangling tap + orphaned watchdog + orphaned engine.
        stopCapture()
        self.onSamples = onSamples
        audioEngine = AVAudioEngine()

        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        // Opt into AVAudioEngine voice processing — gives us system-level
        // AEC + automatic gain control + noise suppression on the input.
        // Big quality improvement for ASR in real-world conditions
        // (typing, fans, room reverb, voice too quiet). Must be enabled
        // BEFORE the first call to inputFormat / installTap, otherwise it
        // throws kAudioUnitErr_Initialized. Failures are non-fatal — we
        // fall back to raw mic input.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            print("[VOICE-AC] voice processing enabled (AEC + AGC + NS)")
        } catch {
            print("[VOICE-AC] voice processing unavailable: \(error.localizedDescription)")
        }
        // TWEAK: Install tap with the input node's NATIVE format (avoids AVAudioEngine crash)
        // We resample to 16kHz mono Float32 in processAudioBuffer
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("[VOICE-AC] mic input format: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved)")
        // Guard against the "zero-channel mic" failure mode that happens when
        // mic permission was just revoked or the input device disappeared
        // mid-session. AVAudioEngine will install the tap but the closure
        // never fires — recording silently produces 0 bytes. Surface it.
        if inputFormat.channelCount == 0 || inputFormat.sampleRate <= 0 {
            print("[VOICE-AC] FATAL: invalid mic input format — permission revoked or device missing")
            throw NSError(domain: "AudioCaptureService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable — check permissions and device selection"])
        }

        // TWEAK: Target format Whisper expects — 16kHz mono Float32
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // TWEAK: Audio converter for resampling to 16kHz mono
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioCaptureService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }
        self.audioConverter = converter
        self.targetFormat = targetFormat

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat  // Use native format — required by AVAudioEngine
        ) { [weak self] buffer, _ in
            // Bounce the timestamp update to main — Date is 16 bytes and a
            // direct cross-thread assignment between this audio I/O thread
            // and the watchdog Timer on main is a data race (torn read can
            // produce a garbage timestamp → spurious "mic not responding").
            DispatchQueue.main.async { self?.lastAudioReceivedAt = Date() }
            self?.processAudioBuffer(buffer)
        }

        // Handle audio route changes (headphones plugged/unplugged, AirPods
        // disconnect, etc.) — these would silently kill long recordings if we
        // didn't restart the engine. Without this, a 30-min meeting cuts off
        // the moment someone plugs in headphones.
        configChangeToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }
            print("[VOICE] Audio engine config changed — attempting restart")
            do {
                try self.audioEngine?.start()
                print("[VOICE] Audio engine restarted")
            } catch {
                print("[VOICE] Audio engine restart failed: \(error.localizedDescription)")
            }
        }

        do {
            try engine.start()
            print("[VOICE-AC] AVAudioEngine started at \(Date()) (running=\(engine.isRunning))")
        } catch {
            print("[VOICE-AC] AVAudioEngine.start THREW: \(error.localizedDescription)")
            throw error
        }
        isCapturing = true
        engineStartedAt = Date()
        engineLongRunningWarningEmitted = false

        // Watchdog: if no audio arrives for 3s while we should be capturing,
        // assume the mic died (permission revoked, device disconnected, HAL
        // wedged) and surface a user-visible error so the recording isn't
        // silently empty. Timer fires on the main run loop.
        self.lastAudioReceivedAt = Date()
        self.silenceWatchdog?.invalidate()
        self.silenceWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }
            if Date().timeIntervalSince(self.lastAudioReceivedAt) > 3.0 {
                print("[VOICE] No audio received in 3s — likely permission revoked or device disconnected")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Microphone not responding — check permissions"]
                )
                self.silenceWatchdog?.invalidate()
                self.silenceWatchdog = nil
            }
        }
    }

    /// Start capturing system audio (all apps or specific app).
    /// Requires Screen Recording permission on macOS.
    func startSystemAudioCapture(onSamples: @escaping ([Float]) -> Void) async throws {
        self.onSamples = onSamples

        // TWEAK: To capture a specific app (e.g., Chrome for Google Meet),
        // filter by bundleIdentifier in the SCShareableContent query below.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Capture all audio (system-wide)
        // TWEAK: To filter specific apps, create SCContentFilter with specific windows/apps
        let filter = SCContentFilter(display: content.displays.first!, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Don't capture our own audio
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1

        // TWEAK: We don't need video — set minimum to reduce overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1fps minimum

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let audioHandler = AudioStreamHandler { [weak self] buffer in
            self?.processAudioBuffer(buffer)
        }
        try stream.addStreamOutput(audioHandler, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        isCapturing = true
    }

    /// Begin writing every resampled 16 kHz mono Float32 buffer to a `.caf`
    /// file at `url`, in addition to delivering it to `onSamples`. Idempotent
    /// per `url` — calling again with a new URL closes the previous file
    /// first. Throws if AVAudioFile can't be created (bad path, permissions).
    ///
    /// Format choice: CAF + Float32 mono @ 16 kHz keeps the file losslessly
    /// identical to what the streaming engine sees, which is what we need
    /// for a faithful batch re-transcription pass at meeting end.
    func startWritingToFile(url: URL) throws {
        // Close any previous file first.
        stopWritingToFile()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // .caf settings — Float32, mono, 16 kHz.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false
        ]

        // Make sure the parent directory exists.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        _ = format // appease analyzer; settings dict drives format

        writerLock.lock()
        self.audioFileWriter = file
        self.audioFileURL = url
        self.audioFileBytesWritten = 0
        self.audioFileSettings = settings
        self.audioFilePartIndex = 1
        self.audioFilePartURLs = [url]
        self.framesSinceLastProgressLog = 0
        // Lead-in zero padding (~120ms @ 16kHz). Parakeet decodes a right-
        // context window per token and tends to drop the very first word
        // when the audio starts mid-syllable (hotkey-to-record latency
        // means the user is often already speaking when capture begins).
        // Cheap zeros give the encoder a clean run-up before real audio.
        if let padBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1920) {
            padBuffer.frameLength = 1920  // 120ms at 16kHz
            if let ch = padBuffer.floatChannelData?[0] {
                memset(ch, 0, Int(padBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            try? file.write(from: padBuffer)
            self.audioFileBytesWritten = Int64(1920) * 4
        }
        writerLock.unlock()
    }

    /// All on-disk part URLs for the current/most-recent recording.
    /// Returns the primary URL plus any `-partN` siblings created by
    /// the re-open-on-write-failure path. Caller is responsible for
    /// stitching these together in post-processing.
    func currentAudioFileParts() -> [URL] {
        writerLock.lock(); defer { writerLock.unlock() }
        return audioFilePartURLs
    }

    /// Stop the on-disk passthrough writer. Safe to call when no writer is
    /// active. Subsequent samples will not be persisted until
    /// `startWritingToFile` is called again.
    func stopWritingToFile() {
        // Capture the writer reference before clearing it so that AVAudioFile's
        // deinit (which flushes and closes the file) fires OUTSIDE the lock.
        // If AVAudioFile.deinit ever acquires an internal Core Audio lock, doing
        // so inside writerLock creates a lock-ordering hazard with the audio tap
        // callback (which holds writerLock while calling writer.write(_:)).
        let closing: AVAudioFile?
        writerLock.lock()
        closing = audioFileWriter
        // Trailing zero padding (~160ms @ 16kHz) before close. Symmetric to
        // the lead-in pad in startWritingToFile — gives Parakeet's right-
        // context window enough samples to finalize the last token's
        // duration prediction. Without this the final word can be clipped
        // ("that" → "tha") on tight push-to-talk stops.
        if let writer = closing, let format = targetFormat,
           let padBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2560) {
            padBuffer.frameLength = 2560  // 160ms at 16kHz
            if let ch = padBuffer.floatChannelData?[0] {
                memset(ch, 0, Int(padBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            try? writer.write(from: padBuffer)
            audioFileBytesWritten &+= Int64(2560) * 4
        }
        audioFileWriter = nil
        audioFileURL = nil
        writerLock.unlock()
        _ = closing  // deinit fires here, outside the lock
    }

    /// Stop all audio capture.
    func stopCapture() {
        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
            configChangeToken = nil
        }
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        isCapturing = false
        audioLevels = Array(repeating: 0, count: fftBinCount)
        silenceTimer?.invalidate()
        silenceWatchdog?.invalidate()
        silenceWatchdog = nil
        onSamples = nil
        onPCMBuffer = nil
        engineStartedAt = nil
        engineLongRunningWarningEmitted = false
        // Note: stopWritingToFile() is intentionally NOT called here. The
        // owner (MeetingRecorder) controls the file lifecycle separately so
        // it can finalize the file deterministically after stopCapture()
        // returns, and so a momentary engine restart on
        // AVAudioEngineConfigurationChange doesn't truncate the file.
    }

    // MARK: - Internal Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // TWEAK: Resample input to 16kHz mono Float32 (Whisper format)
        let resampled = resample(buffer) ?? buffer
        guard let channelData = resampled.floatChannelData?[0] else { return }
        let frameCount = Int(resampled.frameLength)
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // 1. Compute RMS for level metering
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))

        // 2. Run FFT for visualizer bars
        let newLevels = computeVisualizerLevels(samples: samples)

        // Update @Observable properties on main thread to avoid data races.
        DispatchQueue.main.async { [weak self] in
            self?.currentRMS = rms
            self?.audioLevels = newLevels
        }

        // 2b. Deliver resampled PCM buffer to secondary subscriber (live partials).
        onPCMBuffer?(resampled)

        // 3. Forward raw samples directly to the transcription engine.
        // FluidAudio's SlidingWindowAsrManager handles its own buffering +
        // sliding-window decode internally — we no longer need to chunk here.
        onSamples?(samples)

        // 3b. Passthrough write to disk if a meeting is retaining audio.
        // We write the SAME `resampled` buffer the streaming engine sees so
        // the on-disk file is byte-faithful to what got transcribed live.
        // Errors here are swallowed — a write failure mid-meeting must not
        // kill the recording. The lock is uncontended in steady state.
        writerLock.lock()
        if let writer = audioFileWriter {
            do {
                try writer.write(from: resampled)
                // Each frame is 1 channel * 4 bytes. Approx — exact size on
                // disk depends on the .caf header but this is fine for a
                // heartbeat sanity check.
                audioFileBytesWritten &+= Int64(frameCount) * 4
                framesSinceLastProgressLog += frameCount
                // Progress heartbeat ~every 10s of audio (16k * 10 = 160k frames).
                if framesSinceLastProgressLog >= 160_000 {
                    let durationSeconds = Double(audioFileBytesWritten / 4) / sampleRate
                    print("[VOICE] audio file progress: bytes=\(audioFileBytesWritten) (~\(Int(durationSeconds))s)")
                    framesSinceLastProgressLog = 0
                }
            } catch {
                print("[VOICE] audio file write failed: \(error.localizedDescription) — attempting reopen")
                // Failure recovery: drop the broken handle, open a new
                // `-partN` file next to the original, and try once more.
                // Stitching across parts is handled in post-processing.
                if let originalURL = audioFileURL, let settings = audioFileSettings {
                    audioFileWriter = nil
                    audioFilePartIndex += 1
                    let partURL = originalURL
                        .deletingPathExtension()
                        .appendingPathExtension("part\(audioFilePartIndex)")
                        .appendingPathExtension(originalURL.pathExtension)
                    do {
                        let newFile = try AVAudioFile(
                            forWriting: partURL,
                            settings: settings,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false
                        )
                        try newFile.write(from: resampled)
                        audioFileWriter = newFile
                        audioFilePartURLs.append(partURL)
                        audioFileBytesWritten &+= Int64(frameCount) * 4
                        print("[VOICE] audio file reopened at \(partURL.lastPathComponent)")
                    } catch {
                        print("[VOICE] audio file reopen failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        writerLock.unlock()

        // Long-running engine sanity check: emit a single warning once
        // we cross 2h on the same AVAudioEngine instance so we can spot
        // potential resource accumulation in the logs. The 4-hour cap in
        // MeetingRecorder still enforces the hard stop.
        if let startedAt = engineStartedAt,
           !engineLongRunningWarningEmitted,
           Date().timeIntervalSince(startedAt) > 2 * 60 * 60 {
            engineLongRunningWarningEmitted = true
            print("[VOICE] WARNING: AVAudioEngine has been running >2h — long-recording territory")
        }

        // 4. Silence detection — must run on main thread (Timer requires run loop)
        let isSilent = rms < silenceThreshold
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isSilent {
                if self.silenceTimer == nil {
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceTimeoutSeconds, repeats: false) { [weak self] _ in
                        print("[VOICE] Silence detected for \(self?.silenceTimeoutSeconds ?? 0)s — auto-committing lock mode")
                        self?.onSilenceTimeout?()
                    }
                }
            } else {
                self.silenceTimer?.invalidate()
                self.silenceTimer = nil
            }
        }
    }

    /// Resample input buffer (any format/rate) to 16kHz mono Float32.
    /// Returns nil if no converter is set up (e.g. system audio path).
    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = audioConverter, let target = targetFormat else {
            return nil
        }

        // Calculate output capacity based on sample rate ratio
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var inputProvided = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return nil
        }
        return outputBuffer
    }

    /// Compute FFT magnitude spectrum for visualizer. Pure computation — no state mutations.
    /// Called on the audio I/O background thread; result is dispatched to main for assignment.
    private func computeVisualizerLevels(samples: [Float]) -> [Float] {
        let fftSize = 512
        guard samples.count >= fftSize else { return audioLevels }

        let window = Array(samples.suffix(fftSize))
        let bandSize = fftSize / fftBinCount
        var rawLevels = [Float](repeating: 0, count: fftBinCount)

        for i in 0..<fftBinCount {
            let start = i * bandSize
            let end = min(start + bandSize, window.count)
            let band = Array(window[start..<end])
            var bandRMS: Float = 0
            vDSP_rmsqv(band, 1, &bandRMS, vDSP_Length(band.count))
            rawLevels[i] = min(1.0, bandRMS * 8.0)
        }

        // TWEAK: Smoothing factor (0.0 = no smoothing, 1.0 = frozen)
        // Reads audioLevels for the previous frame's basis — one-frame lag, imperceptible.
        let smoothing: Float = 0.3
        var result = audioLevels
        for i in 0..<fftBinCount {
            result[i] = audioLevels[i] * smoothing + rawLevels[i] * (1 - smoothing)
        }
        return result
    }
}

// MARK: - SCStream Audio Handler
// Bridges ScreenCaptureKit's CMSampleBuffer output to AVAudioPCMBuffer.

private class AudioStreamHandler: NSObject, SCStreamOutput {
    let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy sample data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)

        if let data = dataPointer, let channelData = pcmBuffer.floatChannelData {
            memcpy(channelData[0], data, length)
        }

        onBuffer(pcmBuffer)
    }
}
