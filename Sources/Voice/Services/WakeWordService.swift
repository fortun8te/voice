// WakeWordService.swift
// ============================================================
// Always-on "Hey Voice" keyword spotter using Apple's SFSpeechRecognizer
// in continuous on-device recognition mode.
//
// Why SFSpeechRecognizer and not Porcupine / OpenWakeWord:
//   • Zero new dependencies — ships with macOS.
//   • Native on-device recognition (requiresOnDeviceRecognition = true) means
//     audio never leaves the user's machine.
//   • Same mic pipeline AVAudioEngine the dictation engine already owns,
//     so we share the input device.
//
// Tradeoffs:
//   • Battery — running a recognizer continuously costs ~3-5% CPU on M-series.
//     Off by default; user opts in from Settings.
//   • Latency to detect — typically 200-500ms from end of phrase. Fine for a
//     conversational trigger; not a low-latency hotkey replacement.
//
// Behavior contract:
//   • `enable()` requests permission (idempotent), starts a recognition task.
//   • `disable()` tears down the task and releases the mic.
//   • On detection of the configured wake phrase (case-insensitive, fuzzy),
//     fires `onWakeWordDetected` on the main queue. Caller starts dictation
//     the same way it would for a hotkey press.
//   • While the dictation engine is active, the service should be paused —
//     SFSpeechRecognizer fights AVAudioEngine for the input tap. Caller is
//     responsible for calling `pauseWhileRecording()` / `resume()` around
//     dictation captures.
// ============================================================

import Foundation
import Speech
import AVFoundation

// MARK: - Wake word mode
// ============================================================
// Research summary — lighter wake word options (May 2026, macOS 26, Apple Silicon)
// ============================================================
//
// 1. Picovoice Porcupine
//    • Native Swift SDK, dedicated KWS model, ~1-2% CPU sustained.
//    • Custom "Hey Voice" via Picovoice Console — generates .ppn file
//      bundled into the app, no audio leaves device.
//    • Owns its own short-frame audio tap (typically 16kHz, 512-sample
//      frames). Mic indicator behavior: same constraints as anyone
//      tapping the input — macOS will show the orange indicator
//      whenever input is hot. There is no public API on macOS to
//      tap the mic without triggering the privacy indicator.
//    • Commercial license required for shipped apps; free for dev.
//    • Pros: lowest CPU, lowest memory, fast to integrate.
//    • Cons: license fee, still triggers the orange indicator.
//
// 2. Apple SpeechDetector (SpeechAnalyzer, macOS 26)
//    • Native VAD module added in the new SpeechAnalyzer pipeline.
//    • Gates SpeechTranscriber so the recognizer is dormant until
//      voice is present, dropping idle CPU substantially vs raw
//      SFSpeechRecognizer.
//    • KNOWN BUG (early 26.0/26.1 betas): SpeechDetector module
//      conformance crash when added to an SpeechAnalyzer with a
//      transcriber on the same locale — reported on Apple developer
//      forums Jan-Mar 2026. Apple's release notes for 26.2 say
//      "fixed" but third-party reports remain mixed. Risk too high
//      to adopt as the default path right now.
//    • Mic indicator: same — any input tap shows it.
//
// 3. OpenWakeWord
//    • Python/ONNX. No native Swift path. We would have to embed
//      ONNX Runtime + write Swift bindings + ship a model. Not
//      worth the engineering vs Porcupine or Apple-native.
//
// 4. Custom MLX wake word
//    • Highest control, weeks of work to train + tune. Out of scope
//      for a 1-2 day improvement.
//
// 5. Stay with SFSpeechRecognizer, optimized
//    • Lower mic gain (we currently 4× pre-amp every buffer), drop
//      the contextual-strings list (large list re-uploaded on every
//      restart), longer restart spacing, smaller buffer. Probably
//      shaves 1-2% CPU but doesn't change the fundamental "always-on
//      recognizer" cost.
//
// IMPORTANT — mic indicator reality:
//    On macOS 14+ the orange mic indicator is shown whenever ANY
//    process has an active input stream. None of the above options
//    let us tap the mic invisibly. The only way to make the
//    indicator turn off when idle is to NOT TAP THE MIC when idle.
//    That is exactly what Improvement B (activated-window mode)
//    delivers — press once, mic hot for N minutes, then released.
//
// RECOMMENDATION:
//    For the 1-2 day budget, the highest ROI is Improvement B
//    (activated-window mode) layered on top of the existing
//    SFSpeechRecognizer engine. That gives the user direct control
//    over when the mic is hot — the orange dot only shows when
//    they've armed the window, which is the UX they actually want.
//    Engine swap (Porcupine) can come later as a separate change;
//    it reduces CPU but doesn't change the mic-indicator UX.
//
// Implemented here: Improvement B only. Engine swap deferred.
// ============================================================

/// Activation strategy for the wake word listener.
enum WakeWordMode: String {
    /// Service is inert. Mic never tapped by the wake-word path. Default.
    case off
    /// Legacy behavior — recognizer runs whenever the user has the feature
    /// toggled on in Settings. Mic indicator stays on permanently.
    case alwaysOn
    /// Press-once-then-listen-for-N-minutes. The recognizer is dormant
    /// until `activateForWindow()` is called; after N minutes with no
    /// re-arm, it tears down automatically. Mic indicator only lit during
    /// the active window.
    case activatedWindow

    static func current() -> WakeWordMode {
        let raw = UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off"
        return WakeWordMode(rawValue: raw) ?? .off
    }
}

extension Notification.Name {
    /// Posted by any UI surface (menu bar item, hotkey handler, etc.) to
    /// arm the activated-window mode for the configured duration.
    static let voiceActivateWakeWordWindow = Notification.Name("voiceActivateWakeWordWindow")
}

@MainActor
final class WakeWordService: NSObject {
    static let shared = WakeWordService()

    /// Fires when the wake phrase is detected. Posted on main queue.
    var onWakeWordDetected: (() -> Void)?

    /// Timer that disables the listener at the end of an activation window.
    /// Re-armed on every `activateForWindow()` call.
    private var windowTimer: Timer?
    /// When the current window is scheduled to expire — surfaced for UI.
    private(set) var windowExpiresAt: Date?

    /// Configured window length. Default 5 minutes. Clamped to [1, 60].
    private var windowMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: "voice.wakeWordWindowMinutes") as? Int ?? 5
        return max(1, min(60, raw))
    }

    /// The phrase the user says to trigger dictation. Lowercased for matching.
    /// Configurable via UserDefaults "voice.wakeWord". Default "hey voice".
    private var wakePhrase: String {
        let raw = (UserDefaults.standard.string(forKey: "voice.wakeWord") ?? "hey voice")
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "hey voice" : raw
    }

    /// Hard on/off switch read from Settings. When false the service is inert.
    /// Mode-aware: in `activatedWindow` we treat the legacy flag as a no-op
    /// and instead require an active window timer to be running. In
    /// `alwaysOn` we keep the legacy gate. In `off` we are always inert.
    var isEnabled: Bool {
        switch WakeWordMode.current() {
        case .off:
            return false
        case .alwaysOn:
            return UserDefaults.standard.bool(forKey: "voice.wakeWordEnabled")
        case .activatedWindow:
            return windowTimer != nil
        }
    }

    // MARK: - State

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isPausedForRecording = false
    private var isRunning = false
    /// True once the AVAudioEngine + input tap are live. We keep the engine
    /// RUNNING across recognizer restarts (see restartIfStillEnabled) and only
    /// recreate the SFSpeechRecognitionRequest/task — see the media-playback
    /// note in `start()`. `isRunning` tracks the *recognition session*;
    /// `isEngineLive` tracks the *audio hardware*.
    private var isEngineLive = false
    /// Wall-clock time we last fired the wake callback. Used to debounce
    /// duplicate detections — the recognizer keeps emitting partial results
    /// containing the phrase for ~1s after it lands.
    private var lastFireAt: Date = .distantPast

    // MARK: - Public API

    /// Request mic + speech-recognition permission, then start listening.
    /// No-op if disabled in Settings or already running.
    func enable() {
        guard isEnabled else {
            print("[WAKE] enable() called but voice.wakeWordEnabled=false")
            return
        }
        guard !isRunning else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    print("[WAKE] speech auth denied (\(status.rawValue)) — wake word disabled")
                    return
                }
                self.start()
            }
        }
    }

    /// Stop the recognizer and release the mic tap.
    ///
    /// IDEMPOTENT / INERT-WHEN-OFF: the `UserDefaults.didChangeNotification`
    /// observer in VoiceApp calls this on EVERY defaults write while the mode
    /// is "off". If the service was never running there is nothing to tear
    /// down — we must not touch audio HW and must not emit a `wakeword.stop`
    /// event. Doing so was the source of the `wakeword.stop internal_pause:false`
    /// bursts in events.jsonl and, on macOS, repeatedly poking the input-unit
    /// teardown path is exactly what can nudge media-remote into resuming the
    /// user's music. So: if we have no live engine and no live recognition
    /// session and no window timer, this is a pure no-op.
    func disable() {
        let hadWindow = windowTimer != nil
        cancelWindowTimer()
        guard isRunning || isEngineLive || hadWindow else {
            // Nothing was ever armed — stay completely inert. No HW poke, no log.
            return
        }
        stop()
    }

    /// Arm the listener for `voice.wakeWordWindowMinutes` (default 5).
    /// If a window is already active, the timer is RESET to full duration —
    /// useful for "I'm still going to use it, give me another 5".
    /// At expiry, fires `disable()` and logs `window expired`.
    func activateForWindow() {
        // Force-enable the listener for the window regardless of the legacy
        // `voice.wakeWordEnabled` toggle — activated-window mode is itself
        // the user's opt-in. We bypass the gate by starting directly after
        // permission check.
        let minutes = windowMinutes
        let duration = TimeInterval(minutes * 60)

        // If already running (whether from a prior window or always-on),
        // just re-arm the timer.
        if isRunning {
            scheduleWindowExpiry(after: duration, minutes: minutes, reArm: true)
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    print("[VOICE-WAKE] window activation failed — speech auth denied (\(status.rawValue))")
                    return
                }
                self.scheduleWindowExpiry(after: duration, minutes: minutes, reArm: false)
                self.start()
            }
        }
    }

    private func scheduleWindowExpiry(after duration: TimeInterval, minutes: Int, reArm: Bool) {
        windowTimer?.invalidate()
        windowExpiresAt = Date().addingTimeInterval(duration)
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                print("[VOICE-WAKE] window expired")
                self.windowTimer = nil
                self.windowExpiresAt = nil
                self.stop()
            }
        }
        windowTimer = timer
        print("[VOICE-WAKE] window \(reArm ? "re-armed" : "started") for \(minutes) minutes")
    }

    private func cancelWindowTimer() {
        windowTimer?.invalidate()
        windowTimer = nil
        windowExpiresAt = nil
    }

    /// Caller invokes this when the dictation engine takes over the mic.
    /// We tear down the wake-word tap so AVAudioEngine inputs don't fight.
    ///
    /// INERT-WHEN-OFF: this fires on EVERY hotkey press / dictation start. When
    /// wake word is disabled (mode "off" or the legacy toggle off) the service
    /// is not running and there is no engine to pause — we early-return and
    /// touch NOTHING. No audio-unit start/stop, no telemetry. This guarantees
    /// the per-dictation pause/resume cycle is a complete no-op while wake word
    /// is off, so it can never participate in the media-resume-on-teardown path.
    func pauseWhileRecording() {
        guard isEnabled else { return }
        guard isRunning || isEngineLive else { return }
        isPausedForRecording = true
        stop(internalPause: true)
    }

    /// Resume after dictation finishes.
    ///
    /// INERT-WHEN-OFF: fired ~2s after every release. Only does anything if we
    /// actually paused an active session AND we're still enabled. While wake
    /// word is off, `isPausedForRecording` is never set, so this is a no-op —
    /// it never starts an engine or installs a tap.
    func resume() {
        guard isPausedForRecording else { return }
        isPausedForRecording = false
        guard isEnabled else { return }
        start()
    }

    // MARK: - Internals

    /// Bring up the AVAudioEngine + input tap ONCE and leave it running for the
    /// whole listen window. Idempotent — a no-op if the engine is already live.
    ///
    /// ============================================================
    /// MEDIA-PLAYBACK REGRESSION FIX (May 2026) — DO NOT cycle the engine.
    /// ============================================================
    /// Symptom: the user's Apple Music / Spotify would spontaneously start
    /// playing (observed overnight). Root cause: this wake-word path stops and
    /// fully restarts the AVAudioEngine roughly once a minute (SFSpeechRecognizer
    /// caps a session at ~1 min, then errors → restartIfStillEnabled()). On
    /// macOS, every start()/stop() of an input audio unit churns the HAL I/O
    /// graph; if the unit is configured as voice-processing (playAndRecord-like)
    /// it registers with the now-playing / media-remote system, and the teardown
    /// on stop() emits a media-remote "play" command that resumes the default
    /// music app.
    ///
    /// The permanent fix has two parts:
    ///   1. Force voice processing OFF on the input node so this is a pure
    ///      INPUT/record-only unit. A record-only unit does not participate in
    ///      the now-playing/media-remote transport, so its lifecycle can never
    ///      emit a "play". (We don't need AEC for keyword spotting anyway.)
    ///   2. Keep this engine RUNNING across recognizer restarts. The per-minute
    ///      SFSpeechRecognizer recycle now only recreates the request/task
    ///      (see startRecognitionSession / restartIfStillEnabled) — the audio
    ///      hardware is never stopped, so nothing nudges media-remote.
    /// Together these guarantee that arming wake word can NEVER trigger system
    /// media playback. If you ever need to stop the engine, do it only from
    /// stop()/disable() (a deliberate teardown), never on the restart path.
    private func startEngineIfNeeded() {
        guard !isEngineLive else { return }

        // DEFENSE IN DEPTH: never bring up the audio HW if the service is not
        // currently enabled. start() already gates on isRunning, but this makes
        // it impossible for any future caller to spin the input unit (and risk
        // the media-resume-on-teardown nudge) while wake word is off.
        guard isEnabled else {
            print("[WAKE] startEngineIfNeeded() refused — not enabled")
            Telemetry.log("wakeword.engine_start_refused", properties: [
                "reason": "not_enabled",
                "mode": WakeWordMode.current().rawValue
            ])
            return
        }

        let inputNode = audioEngine.inputNode

        // (1) Disable voice processing → pure input/record-only unit. Must be
        // set before reading the format / installing the tap. Failures are
        // non-fatal (older HW), but on the typical Mac this is what keeps the
        // unit out of the media-remote transport.
        do {
            if inputNode.isVoiceProcessingEnabled {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            Telemetry.log("wakeword.voice_processing", properties: [
                "enabled": inputNode.isVoiceProcessingEnabled
            ])
        } catch {
            print("[WAKE] could not disable voice processing: \(error.localizedDescription)")
            Telemetry.log("wakeword.voice_processing_error", properties: [
                "error": "\(error.localizedDescription)"
            ])
        }

        let format = inputNode.outputFormat(forBus: 0)

        // Whisper support: amplify the mic signal before feeding it to the
        // recognizer. SFSpeechRecognizer's acoustic model expects ~normal
        // speech volume; whispered phrases land below its detection floor
        // unless we boost. 4× lift with hard clip preserves the wake phrase
        // even when the user breathes the words. Boost is applied in-place
        // on the buffer's float channel data right before forwarding to the
        // recognition request.
        let micGain: Float = 4.0

        // Install the tap ONCE. It forwards to whatever `request` is current,
        // so recreating the request across restarts needs no tap churn.
        // Guard against an invalid (0ch / 0Hz) format — happens when mic
        // permission was revoked or the device vanished.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("[WAKE] invalid input format — mic permission revoked or device missing")
            Telemetry.log("wakeword.start_failed", properties: ["reason": "invalid_format"])
            return
        }

        // Buffer size 1024 = ~21ms at 48kHz — small enough for fast detection.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Pre-amplify so whispers cross the recognizer's detection floor.
            // We mutate the buffer in place — safe because the tap closure
            // owns this buffer for the duration of the call.
            if let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                let channels = Int(buffer.format.channelCount)
                for c in 0..<channels {
                    let ptr = channelData[c]
                    for i in 0..<frameCount {
                        let amplified = ptr[i] * micGain
                        ptr[i] = max(-1.0, min(1.0, amplified))
                    }
                }
            }
            self.request?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isEngineLive = true
            // Focused media-safety telemetry: which engine + why. If music
            // autoplay ever recurs, events.jsonl pinpoints whether the
            // wake-word input unit was the trigger (engine "wakeword",
            // mode, VPIO state) vs the dictation capture engine.
            Telemetry.log("wakeword.engine_start", properties: [
                "engine": "wakeword",
                "reason": WakeWordMode.current() == .activatedWindow ? "window_armed" : "enabled",
                "mode": WakeWordMode.current().rawValue,
                "input_sr": format.sampleRate,
                "input_ch": Int(format.channelCount),
                "voice_processing": inputNode.isVoiceProcessingEnabled
            ])
        } catch {
            print("[WAKE] couldn't start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            Telemetry.log("wakeword.start_failed", properties: [
                "reason": "engine_start_threw",
                "error": "\(error.localizedDescription)"
            ])
        }
    }

    /// Tear down the AVAudioEngine + tap. This is the ONLY place (besides
    /// pauseWhileRecording / disable) that stops the audio hardware. Per the
    /// media-playback note in startEngineIfNeeded, we deliberately keep this
    /// off the recognizer-restart path.
    private func stopEngine(reason: String = "unspecified") {
        guard isEngineLive else { return }
        // Focused media-safety telemetry: the input-unit teardown is the only
        // wake-word operation that can theoretically nudge media-remote. Log
        // every real teardown (engine + why) so it is pinpointable from
        // events.jsonl. Note: a record-only unit (VPIO off — set in
        // startEngineIfNeeded) should not resume media; this log lets us prove
        // it if the bug ever recurs.
        Telemetry.log("wakeword.engine_stop", properties: [
            "engine": "wakeword",
            "reason": reason
        ])
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isEngineLive = false
    }

    /// Create (or recreate) the SFSpeechRecognitionRequest + task. Does NOT
    /// touch the AVAudioEngine — the long-lived tap just starts feeding the
    /// new request. Safe to call repeatedly; cancels any prior task first.
    private func startRecognitionSession() {
        guard let recognizer, recognizer.isAvailable else {
            print("[WAKE] recognizer unavailable — bailing")
            return
        }

        // Cancel any prior request/task so we don't leak or double-append.
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // CRITICAL: on-device only. Without this the recognizer will round-
        // trip audio to Apple's servers. We want zero exfiltration.
        if #available(macOS 13.0, *) {
            req.requiresOnDeviceRecognition = true
        }
        // Contextual-phrases hint — biases the recognizer toward our wake
        // phrase + variants AND the technical vocabulary the user actually
        // dictates. Without these the model phonetically maps "UI" → "you eye"
        // and "API" → "ape eye". Adding common tech terms raises their prior
        // probability so they decode correctly even at low volume.
        req.contextualStrings = [
            wakePhrase, "hey voice", "hi voice", "okay voice",
            // Tech / UI vocabulary the user has been losing
            "UI", "UX", "API", "iOS", "macOS", "Swift", "SwiftUI", "Xcode",
            "GitHub", "ChatGPT", "Claude", "GPT", "LLM", "MLX", "WWDC",
            "Cerebras", "Voice", "Wispr", "Granola", "Liquid Glass",
            "VS Code", "Cursor", "TypeScript", "JavaScript", "Python",
            "Figma", "Tailwind", "React", "Vite", "Next.js",
        ]

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handlePartialResult(result.bestTranscription.formattedString)
            }
            if let error {
                let nsErr = error as NSError
                // Code 203 = recognition was cancelled (we tore down). Code
                // 209 = result limit. Both expected and benign.
                if nsErr.code != 203 && nsErr.code != 209 {
                    print("[WAKE] recognition error: \(error.localizedDescription)")
                }
                Task { @MainActor in self.restartIfStillEnabled() }
            }
        }

        request = req
    }

    private func start() {
        guard !isRunning else { return }
        // Bring up the audio HW (idempotent) then attach a recognition session.
        startEngineIfNeeded()
        guard isEngineLive else {
            // Engine failed to start — don't claim we're running.
            return
        }
        startRecognitionSession()
        guard task != nil else {
            // Recognition couldn't start; tear the engine back down so we don't
            // hold the mic with no consumer.
            stopEngine()
            return
        }
        isRunning = true
        Telemetry.log("wakeword.start", properties: [
            "phrase": wakePhrase,
            "mode": WakeWordMode.current().rawValue
        ])
        print("[WAKE] started — listening for \"\(wakePhrase)\"")
    }

    /// Full teardown — stops the recognition session AND the audio hardware.
    /// This is a deliberate stop (disable / pause-for-dictation / window
    /// expiry), so cycling the engine here is fine: it is not the per-minute
    /// recognizer recycle that nudged media-remote (see startEngineIfNeeded).
    private func stop(internalPause: Bool = false) {
        // IDEMPOTENT: if there is no live recognition session AND no live audio
        // engine, there is genuinely nothing to stop. Return WITHOUT emitting a
        // telemetry event or touching audio HW. This kills the `wakeword.stop`
        // spam (repeated disable() calls from the defaults observer) and ensures
        // we never poke the input-unit teardown path while wake word is off.
        guard isRunning || isEngineLive || request != nil || task != nil else {
            return
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        stopEngine(reason: internalPause ? "pause_for_recording" : "deliberate_stop")
        isRunning = false
        Telemetry.log("wakeword.stop", properties: ["internal_pause": internalPause])
        if !internalPause {
            print("[WAKE] stopped")
        }
    }

    /// SFSpeechRecognizer caps each session at ~1 minute of audio. When it
    /// errors out we recycle ONLY the recognition request/task — the
    /// AVAudioEngine + input tap stay running the whole time. This is the
    /// crux of the media-playback fix: previously this path called stop()
    /// (full engine teardown) then start() (full engine restart) ~once a
    /// minute, and that audio-unit stop is what emitted a media-remote "play".
    /// Now the hardware never cycles, so wake word can't resume the user's music.
    private func restartIfStillEnabled() {
        // Drop the dead recognition session immediately, but leave the engine up.
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        guard isEnabled, !isPausedForRecording, isEngineLive else {
            // We're no longer supposed to be listening (or the engine went
            // away) — make sure we're fully torn down and bail.
            if !isEnabled || isPausedForRecording {
                stop(internalPause: true)
            }
            return
        }
        Telemetry.log("wakeword.restart", properties: ["engine_kept_alive": true])
        // Small delay so we don't hot-loop on persistent failures (e.g. mic
        // permission revoked mid-session), then re-attach a fresh recognition
        // session to the still-running engine.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Re-check guards after the await — state may have changed.
            guard self.isEnabled, !self.isPausedForRecording, self.isEngineLive else { return }
            self.startRecognitionSession()
            self.isRunning = (self.task != nil)
        }
    }

    private func handlePartialResult(_ text: String) {
        let lower = text.lowercased()
        guard lower.contains(wakePhrase) else { return }
        // 1.5s debounce — once we've fired, don't fire again for repeated
        // partial-result matches of the same utterance.
        let now = Date()
        if now.timeIntervalSince(lastFireAt) < 1.5 { return }
        lastFireAt = now

        print("[WAKE] phrase detected in: \"\(text)\" — firing")
        Telemetry.log("wakeword.detected", properties: ["phrase": wakePhrase])
        onWakeWordDetected?()

        // After firing, recycle ONLY the recognition session so the buffer
        // doesn't keep partial-matching the same phrase. The engine stays
        // running (no media-remote nudge). The dictation engine will pause
        // us via pauseWhileRecording() in the next tick anyway.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.restartIfStillEnabled()
        }
    }
}
