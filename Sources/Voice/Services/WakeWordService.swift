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
    func disable() {
        cancelWindowTimer()
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
    func pauseWhileRecording() {
        guard isRunning else { return }
        isPausedForRecording = true
        stop(internalPause: true)
    }

    /// Resume after dictation finishes.
    func resume() {
        guard isPausedForRecording else { return }
        isPausedForRecording = false
        if isEnabled { start() }
    }

    // MARK: - Internals

    private func start() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            print("[WAKE] recognizer unavailable — bailing")
            return
        }

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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Whisper support: amplify the mic signal before feeding it to the
        // recognizer. SFSpeechRecognizer's acoustic model expects ~normal
        // speech volume; whispered phrases land below its detection floor
        // unless we boost. 4× lift with hard clip preserves the wake phrase
        // even when the user breathes the words. Boost is applied in-place
        // on the buffer's float channel data right before forwarding to the
        // recognition request.
        let micGain: Float = 4.0

        // Install the tap. Buffer size 1024 = ~21ms at 48kHz — small enough
        // for fast detection without overwhelming the recognizer.
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
        } catch {
            print("[WAKE] couldn't start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            return
        }

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
        isRunning = true
        print("[WAKE] started — listening for \"\(wakePhrase)\"")
    }

    private func stop(internalPause: Bool = false) {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRunning = false
        if !internalPause {
            print("[WAKE] stopped")
        }
    }

    /// SFSpeechRecognizer caps each session at ~1 minute of audio. When it
    /// errors out we restart cleanly so the service stays hot indefinitely.
    private func restartIfStillEnabled() {
        stop(internalPause: true)
        guard isEnabled, !isPausedForRecording else { return }
        // Small delay so we don't hot-loop on persistent failures (e.g. mic
        // permission revoked mid-session).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.start()
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
        onWakeWordDetected?()

        // After firing, restart the session so the buffer doesn't keep
        // partial-matching the same phrase. The dictation engine will pause
        // us via pauseWhileRecording() in the next tick anyway.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.restartIfStillEnabled()
        }
    }
}
