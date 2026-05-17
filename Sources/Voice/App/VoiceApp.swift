// VOICE — App Entry Point
// ============================================================
// Menu bar only. No main window, no dashboard.
// The ENTIRE UI is the floating dictation pill at bottom-center.
//
// fn hold       = push-to-talk (record while held, transcribe on release)
// fn double-tap = lock recording (stays on; press fn again to transcribe)
// Tap pill      = same as double-tap (enter lock mode)
// ============================================================

import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Top-level entry point. Branches on CLI args:
///   --polish-harness [dir]   → run the headless golden-case polish harness
///   (anything else)          → boot the SwiftUI app as normal
///
/// Lives here (rather than as a separate target) because the polish pipeline
/// (`Qwen3Polisher`, `RestartCorrectionPreprocessor`, `PolishPostprocessor`,
/// `LLMPolisher`) uses internal access across `Sources/Voice/Services/` and
/// is referenced extensively from the rest of the Voice target. Splitting it
/// out would mean making dozens of types public — too invasive for what is
/// a read-only test harness. See PolishHarness.swift.
@main
struct VoiceEntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--polish-harness" {
            let dir = args.count > 2 ? args[2] : "Sources/Voice/Resources/GoldenCases"
            // Use RunLoop.main so the @MainActor task actually gets to run.
            // sema.wait() would deadlock because it blocks the very thread
            // the main actor needs to schedule work on.
            Task { @MainActor in
                await PolishHarness.run(goldenCasesDir: dir)
                exit(0)
            }
            RunLoop.main.run()   // spins until exit(0) above fires
            return
        }
        VoiceApp.main()
    }
}

// MARK: - Global notification names

extension Notification.Name {
    /// Posted by services with userInfo["message": String] when something
    /// goes wrong the user should see (mic denied, paste failed, etc.).
    /// Surfaced as a top-right toast — independent of the dictation pill.
    static let voiceError = Notification.Name("voice.error")
    /// Posted from the idle pill's context menu to bring up the BigMenu window.
    static let voiceOpenBigMenu = Notification.Name("voice.openBigMenu")
    /// Posted by the BigMenu toolbar's "…" → Settings… item. The SwiftUI root
    /// view observes this and flips its `showSettings` state to present the
    /// sheet, since AppKit can't reach SwiftUI @State directly.
    static let voiceOpenBigMenuSettings = Notification.Name("voice.openBigMenuSettings")
    /// Posted when the cloud polish path failed (timeout / rate-limit / network)
    /// and we silently fell back to the local model. `userInfo["reason"]`
    /// carries a short human-readable cause.
    static let voiceCloudFellBackToLocal = Notification.Name("voice.cloudFellBackToLocal")
}

/// Persisted history of the last dictations. Capped at 100 (see
/// `RecentDictations.limit`). Lives here (not in a service) because it's
/// UI-shaped state for the menu.
///
/// `text` is the polished (final) version that was actually pasted at the cursor.
/// `rawText` is the pre-polish formatted version (optional for backward compat —
/// older persisted entries didn't capture it). When both are present the UI can
/// show a before/after compare.
struct RecentDictation: Codable, Identifiable {
    let text: String
    let timestamp: Date
    /// Pre-polish formatted text. Optional so we don't break decoding of older
    /// entries written before this field existed.
    var rawText: String? = nil
    /// Bundle ID of the app text was pasted into (e.g. "com.tinyspeck.slackmacgap").
    var pasteTargetBundleID: String? = nil
    /// Milliseconds the Qwen3 polish stage took. Nil if polish was skipped/disabled.
    var polishMs: Int? = nil
    /// Raw transcript from Granite 4.0 1B (second ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var graniteText: String? = nil
    /// Raw transcript from Moonshine Tiny (third ASR), captured at the moment
    /// of dictation. Optional for backward compat with older entries.
    var moonshineText: String? = nil
    /// Raw Parakeet ASR before TextFormatter ran — the actual speech recognizer output.
    /// Stored to let the pipeline view show all 3 stages: ASR → Formatter → Polish.
    var parakeetRawText: String? = nil
    /// Low-confidence words flagged by Parakeet's per-token confidence scoring.
    /// Passed to Qwen3 as hints; shown in the pipeline view.
    var parakeetSuspects: [String]? = nil
    /// Recording duration in seconds. Optional for back-compat with older entries
    /// captured before this field existed. Used by the BigMenu stats row to
    /// compute words-per-minute over recent dictations.
    var durationSeconds: Int? = nil
    /// Number of spoken punctuation/formatting commands the TextFormatter
    /// converted to characters (period, comma, new line, exclamation, etc.).
    /// Surfaced as "fixes made by voice" in the BigMenu stats row.
    // NOTE: BigMenuWindow's computeStats() should sum `polishFixCount` (not
    // `voiceCommandCount`) for the "fixes by voice" stat card. Keep this field
    // around for back-compat but the UI now prefers polishFixCount.
    var voiceCommandCount: Int? = nil
    /// Number of fix-events the polish stage applied (spelling/capitalization/grammar/filler).
    /// Computed by diffing raw → polished at finishRecording time.
    var polishFixCount: Int? = nil
    /// Cleanup level the polish stage was running on when this dictation was captured.
    /// Optional for back-compat with older entries. Display value: "None" / "Light" / "Medium" / "High".
    var cleanupLevelUsed: String? = nil
    /// Personality preset in effect when the polish ran. "Neutral" / "Formal" / "Casual" / "Excited".
    var personalityStyleUsed: String? = nil
    /// Engine that actually polished this dictation. Tagged by Qwen3Polisher
    /// during polish so the history view can show "Cloud (Qwen 235B)" vs
    /// "Local (Qwen3 4B)". Optional for back-compat with older entries.
    /// Format: "cloud:qwen-3-235b" / "local:qwen3-4b" / "local:qwen3-1.7b" / "rules-only"
    var polishEngine: String? = nil
    var id: String { "\(timestamp.timeIntervalSince1970)-\(text.hashValue)" }

    /// True when raw differs meaningfully from polished — i.e. polish actually
    /// changed something. Used by the UI to decide whether to show a compare
    /// affordance.
    var hasPolishDiff: Bool {
        guard let raw = rawText else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when we have a raw transcript to show, regardless of whether
    /// polish changed anything. Used to enable the "show raw" affordance
    /// on every entry that has the pre-polish text available.
    var hasRawText: Bool {
        guard let raw = rawText else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

fileprivate extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

enum RecentDictations {
    private static let key = "recentDictations"
    private static let limit = 100

    static func all() -> [RecentDictation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([RecentDictation].self, from: data) else {
            return []
        }
        return items
    }

    /// Back-compat single-text add — used by code paths that don't know the
    /// pre-polish version. Newer callers should use `add(raw:polished:)`.
    static func add(_ text: String) {
        add(raw: nil, polished: text)
    }

    /// Add a dictation with both the pre-polish formatted text and the final
    /// polished text. `raw` is optional — pass nil if polish was skipped /
    /// disabled / unchanged, and only the polished version will be stored.
    static func delete(id: String) {
        var items = all()
        items.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func add(raw: String?, polished: String, pasteTargetBundleID: String? = nil, polishMs: Int? = nil,
                    granite: String? = nil, moonshine: String? = nil,
                    parakeetRaw: String? = nil, suspects: [String]? = nil,
                    durationSeconds: Int? = nil, voiceCommandCount: Int? = nil,
                    cleanupLevelUsed: String? = nil,
                    personalityStyleUsed: String? = nil,
                    polishFixCount: Int? = nil,
                    polishEngine: String? = nil) {
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always persist `rawText` when it's non-empty (even when identical to
        // the polished version). The History UI uses `hasPolishDiff` to gate
        // the compare button — keeping `rawText` populated lets us surface
        // "polish was a no-op for this one" cleanly, and means users who want
        // to see the raw transcript always can.
        let rawForStorage: String? = {
            guard let r = trimmedRaw, !r.isEmpty else { return nil }
            return r
        }()
        var items = all()
        items.insert(
            RecentDictation(text: trimmed, timestamp: Date(), rawText: rawForStorage,
                            pasteTargetBundleID: pasteTargetBundleID, polishMs: polishMs,
                            graniteText: granite?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            moonshineText: moonshine?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetRawText: parakeetRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                            parakeetSuspects: (suspects?.isEmpty == false) ? suspects : nil,
                            durationSeconds: durationSeconds,
                            voiceCommandCount: voiceCommandCount,
                            polishFixCount: polishFixCount,
                            cleanupLevelUsed: cleanupLevelUsed,
                            personalityStyleUsed: personalityStyleUsed,
                            polishEngine: polishEngine),
            at: 0
        )
        if items.count > limit { items = Array(items.prefix(limit)) }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Count distinct fix events between raw and polished text. A "fix event" is
    /// any contiguous run of words that differs between the two. This collapses
    /// e.g. "i think" → "I think" + "yeah" → "" into 2 fixes, not 2.5.
    static func countFixes(raw: String, polished: String) -> Int {
        let rawTokens = raw.lowercased().split(separator: " ").map(String.init)
        let polTokens = polished.lowercased().split(separator: " ").map(String.init)

        // Myers-lite: count edit runs via 2D LCS-style backtrack.
        let m = rawTokens.count
        let n = polTokens.count
        if m == 0 { return n > 0 ? 1 : 0 }
        if n == 0 { return 1 }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if rawTokens[i] == polTokens[j] {
                    dp[i+1][j+1] = dp[i][j] + 1
                } else {
                    dp[i+1][j+1] = max(dp[i][j+1], dp[i+1][j])
                }
            }
        }

        // Backtrack to count edit runs (contiguous mismatch streaks).
        var i = m, j = n
        var runs = 0
        var inMismatch = false
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && rawTokens[i-1] == polTokens[j-1] {
                if inMismatch { runs += 1; inMismatch = false }
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                inMismatch = true; j -= 1
            } else {
                inMismatch = true; i -= 1
            }
        }
        if inMismatch { runs += 1 }
        return runs
    }
}

// MARK: - Cleanup Level

enum CleanupLevel: String, CaseIterable, Identifiable {
    case none   = "none"
    case light  = "light"
    case medium = "medium"
    case high   = "high"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:   return "None"
        case .light:  return "Light"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    var settingsDescription: String {
        switch self {
        case .none:   return "No AI — spoken punctuation commands only"
        case .light:  return "Remove fillers, fix capitalization"
        case .medium: return "Full polish — clarity, punctuation, proper nouns"
        case .high:   return "Aggressive — rewrite for professional clarity"
        }
    }

    var tagline: String {
        switch self {
        case .none:    return "Transcribes exactly what you said, including mistakes"
        case .light:   return "Cleans up filler words and grammar"
        case .medium:  return "Edits for clarity and conciseness"
        case .high:    return "Rewrites for brevity and polish"
        }
    }

    var example: (before: String, after: String) {
        let before = "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want"
        switch self {
        case .none:
            return (before, "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want")
        case .light:
            return (before, "So I was thinking maybe we could grab coffee tomorrow if you're free.")
        case .medium:
            return (before, "I was thinking we could grab coffee tomorrow if you're free.")
        case .high:
            return (before, "Want to grab coffee tomorrow if you're free?")
        }
    }

    static var current: CleanupLevel {
        get {
            if let raw = UserDefaults.standard.string(forKey: "cleanupLevel"),
               let level = CleanupLevel(rawValue: raw) { return level }
            // Migration: old llmPolishEnabled bool (default was ON → medium)
            let wasEnabled = UserDefaults.standard.object(forKey: "llmPolishEnabled") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "llmPolishEnabled")
            return wasEnabled ? .medium : .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel") }
    }
}

// MARK: - Personality Style

enum PersonalityStyle: String, CaseIterable, Identifiable {
    case neutral = "neutral"
    case formal  = "formal"
    case casual  = "casual"
    case excited = "excited"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .formal:  return "Formal"
        case .casual:  return "Casual"
        case .excited: return "Excited"
        }
    }

    var settingsDescription: String {
        switch self {
        case .neutral: return "Balanced, professional"
        case .formal:  return "Elevated, no contractions"
        case .casual:  return "Natural, conversational"
        case .excited: return "Energetic, enthusiastic"
        }
    }

    var tagline: String {
        switch self {
        case .neutral: return "Balanced everyday voice"
        case .formal:  return "Caps and full punctuation"
        case .casual:  return "Light caps, light punctuation"
        case .excited: return "Energetic and punchy"
        }
    }

    var bubbleTint: Color {
        switch self {
        case .neutral: return Color.gray.opacity(0.12)
        case .formal:  return Color.purple.opacity(0.10)
        case .casual:  return Color.pink.opacity(0.10)
        case .excited: return Color.orange.opacity(0.12)
        }
    }

    var avatarTint: Color {
        switch self {
        case .neutral: return Color.gray
        case .formal:  return Color(red: 0.62, green: 0.55, blue: 0.95)
        case .casual:  return Color(red: 0.95, green: 0.65, blue: 0.78)
        case .excited: return Color(red: 0.95, green: 0.6,  blue: 0.35)
        }
    }

    var example: (before: String, after: String) {
        let before = "hey can u send maya a msg saying we're running late"
        switch self {
        case .neutral:
            return (before, "Hey, can you send Maya a message saying we're running late?")
        case .formal:
            return (before, "Please send Maya a message that we are running late.")
        case .casual:
            return (before, "yo send maya a msg, we're running late")
        case .excited:
            return (before, "Send Maya a quick message! We're running late!")
        }
    }

    static var current: PersonalityStyle {
        get {
            let raw = UserDefaults.standard.string(forKey: "personalityStyle") ?? "neutral"
            return PersonalityStyle(rawValue: raw) ?? .neutral
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "personalityStyle") }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayPanel: OverlayPanel?
    let recordingState = RecordingState()
    lazy var coordinator: RecordingCoordinator = RecordingCoordinator(state: recordingState)
    private let hotkeyService = HotkeyService()
    private let textFormatter = TextFormatter()
    private let cursorPaster = CursorPaster()

    private var cancelDismissTask: Task<Void, Never>?
    // Each finishRecording() spawns its OWN independent Task. We do NOT cancel
    // prior in-flight finish tasks when a new recording starts — the user's
    // dictation must reach the cursor even if they re-pressed the hotkey
    // before the prior pipeline finished pasting. The only legitimate cancel
    // path is app shutdown (and we just let those drop on the floor).
    private var pendingFinishTask: Task<Void, Never>?
    // Serializes paste tail-segments so back-to-back completed transcripts
    // land at the cursor in chronological arrival order without trampling
    // each other's clipboard / synthesized-keystroke state. Each finish task
    // appends its paste step to this chain.
    private var pasteChain: Task<Void, Never>?
    private var bigMenuWindow: NSWindow?
    // Floor for "this is too short to bother transcribing". The hotkey state
    // machine has its own short-tap gate at 0.35s and only fires deactivate
    // for legitimate holds, so this is purely belt-and-suspenders against
    // tiny lock-exit recordings (lock entered, immediately third-tapped).
    // 0.15s comfortably distinguishes real speech from a button bounce while
    // never rejecting a borderline-threshold PTT release after dispatch jitter.
    private let minRecordingDuration: TimeInterval = 0.15
    private var recordingStartedAt: Date?

    /// Bundle identifier of whatever app was frontmost when the user
    /// triggered recording. Re-activated before paste so the transcript
    /// lands where the user expects — even if focus shifted in the interim
    /// (e.g., the user used System Settings to grant Accessibility, then
    /// pressed the hotkey without re-clicking their target app).
    @ObservationIgnored private var targetAppBundleID: String?

    /// Text-field context (chars immediately before cursor) sampled at the
    /// moment recording starts. We read at start (not paste) because that's
    /// when the user's target field reliably owns AX focus — by paste time,
    /// toast popups or other UI may have stolen focus and given us a stale
    /// or empty read. The polisher uses this to make smart spacing /
    /// punctuation / number-formatting decisions relative to existing text.
    @ObservationIgnored private var capturedFieldContext: String?

    // Permission-prompt throttling. macOS shows the system "grant access"
    // dialog every time AXIsProcessTrustedWithOptions(prompt: true) is called
    // — pressing the hotkey 40 times yields 40 dialogs. Track per-session so
    // we ask exactly once, then route the user to System Settings.
    private var didShowAXPrompt = false
    private var didShowMicPrompt = false
    private var permissionWatcherTimer: Timer?
    /// 0.5Hz safety tick — clears a stuck `pendingRecordingStart` if it sits
    /// true with no corresponding `isRecording` for more than 2 seconds (e.g.
    /// audio engine failed to spin up, or the user released during spin-up
    /// and the release handler somehow missed clearing it). Without this,
    /// the pill latches in .recording forever (see 5.1).
    private var pendingPillSafetyTimer: Timer?
    private var lastObservedAXTrusted: Bool = AXIsProcessTrusted()

    // Polished-app extras
    private var errorToastWindow: NSPanel?

    /// Throttles model-not-ready toasts so a held key doesn't spam.
    private var lastModelReadyToastAt: Date?
    private var errorDismissTask: Task<Void, Never>?
    private var onboardingWindow: NSPanel?
    private var errorObserver: NSObjectProtocol?
    /// All block-based NotificationCenter observers we register. We hold the
    /// tokens so `applicationWillTerminate` can remove every one — previously
    /// only `errorObserver` got cleaned up, leaving the didBecomeActive +
    /// voiceOpenBigMenu + voicePolishSelection observers as zombies if the
    /// process is ever re-spawned in the same address space (tests, hot reload).
    private var notificationTokens: [NSObjectProtocol] = []

    // (Previously used to swallow a deactivate after lock-exit, but the new
    // state machine doesn't fire deactivate on lock exit, so the flag was a
    // footgun — once set on lock exit, it stayed true and silently killed
    // every subsequent PTT release. Removed.)

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[VOICE-ICON] startup: bundlePath=\(Bundle.main.bundlePath)")
        print("[VOICE-ICON] startup: bundleId=\(Bundle.main.bundleIdentifier ?? "<nil>")")

        // Show in the Dock and Cmd-Tab switcher.
        NSApp.setActivationPolicy(.regular)

        let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "<nil>"
        let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "<nil>"
        print("[VOICE-ICON] CFBundleIconFile=\(iconFile)  CFBundleIconName=\(iconName)")

        // Assert the icon immediately at launch.
        assertAppIcon(context: "launch")

        // Re-observe every time the app becomes active (covers "square after
        // switching Spaces / Mission Control" — the Dock resets the cache then).
        // BUGFIX: capture the token so applicationWillTerminate can remove it.
        let didBecomeActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.assertAppIcon(context: "didBecomeActive")
        }
        notificationTokens.append(didBecomeActiveToken)

        // Surface cloud polish failures (timeout / rate-limit / network) so the
        // user knows when we silently fell back to the local model. Toast is
        // throttled inside Qwen3Polisher to avoid spamming on rate-limit bursts.
        let cloudFallbackToken = NotificationCenter.default.addObserver(
            forName: .voiceCloudFellBackToLocal,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?["reason"] as? String) ?? "network issue"
            self?.showToast("Cloud unreachable (\(reason)) — using local model.")
        }
        notificationTokens.append(cloudFallbackToken)

        // Belt-and-suspenders: re-assert at 0.1 s (before Dock finishes its first
        // cache write) and again at 1.5 s (after any post-launch Dock refresh).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.assertAppIcon(context: "0.1s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.assertAppIcon(context: "1.5s")
            // Touch the bundle modification date to nudge Finder + Dock cache.
            let bundlePath = Bundle.main.bundlePath
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: bundlePath
            )
        }

        // Wrap startup tasks individually so one failure doesn't tank launch.
        runStartupStep("menu_bar") { self.setupMenuBar() }
        runStartupStep("overlay_panel") { self.setupOverlayPanel() }
        runStartupStep("hotkey") { self.setupHotkey() }
        runStartupStep("error_observer") { self.setupErrorObserver() }
        runStartupStep("launch_at_login_sync") { LaunchAtLoginService.syncFromStorage() }

        // Run the same throttled permission check at launch so first-time
        // users get the prompt + System Settings deep-link immediately
        // (instead of having to press the hotkey first to discover the
        // gate). Once granted, the watcher rebinds monitors automatically.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()
        if !micOk || !axOk {
            handleMissingPermissions(micOk: micOk, axOk: axOk, micStatus: micStatus)
        }

        Task {
            await coordinator.prepare()
        }

        // POLISH REPLAY AUTO-RUN — kicks the in-app golden-case battery
        // headlessly when `POLISH_REPLAY_AUTORUN=1` is set in the env (or
        // `polishReplayAutorun` UserDefaults bool). Writes the markdown dump
        // to ~/Library/Application Support/Voice/polish_replay_last.md and
        // quits the app. Lets an external driver verify polish quality
        // without needing computer-use clicks.
        let autorunEnv = ProcessInfo.processInfo.environment["POLISH_REPLAY_AUTORUN"] == "1"
        let autorunDefaults = UserDefaults.standard.bool(forKey: "polishReplayAutorun")
        if autorunEnv || autorunDefaults {
            print("[POLISH-REPLAY] autorun: starting batch (env=\(autorunEnv) defaults=\(autorunDefaults))")
            Task { @MainActor in
                // Wait for the 1.7B prewarm to land before running. We
                // poll instead of awaiting the coordinator prewarm because
                // prewarm is fire-and-forget. The 4B may still be loading;
                // routing falls back to 1.7B automatically.
                for i in 0..<120 {
                    if Qwen3Polisher.availabilityStatus.isReady { break }
                    if i == 0 { print("[POLISH-REPLAY] autorun: waiting for 1.7B...") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // Also give the 4B a chance to load — bounded wait so the
                // batch reflects the realistic warm-state behavior, not a
                // cold first-call timeout.
                for _ in 0..<60 {
                    if Qwen3Polisher.shared.isLargeModelReady { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                print("[POLISH-REPLAY] autorun: 1.7B ready=\(Qwen3Polisher.availabilityStatus.isReady) 4B ready=\(Qwen3Polisher.shared.isLargeModelReady)")

                let cases = GoldenCaseLoader.loadAll()
                print("[POLISH-REPLAY] autorun: loaded \(cases.count) cases")
                var lines: [String] = []
                lines.append("| Case | Route | ms | Similarity | Status |")
                lines.append("|------|-------|-----|------------|--------|")
                var dump = "# polish-replay batch \(Date())\n"
                dump += "1.7B-ready=\(Qwen3Polisher.availabilityStatus.isReady) 4B-ready=\(Qwen3Polisher.shared.isLargeModelReady)\n\n"
                for c in cases {
                    let cleanup = c.cleanupLevel ?? "medium"
                    let pers = c.personality ?? "neutral"
                    let route = PolishRouter.predictedRoute(for: c.raw, cleanupLevel: cleanup, forceLarge: false)
                    let (out, ms) = await PolishReplayView.runOnePolish(
                        raw: c.raw,
                        cleanupLevel: cleanup,
                        personality: pers,
                        forceLarge: false
                    )
                    let sim = Similarity.score(out, c.reference)
                    let status: String
                    if sim >= 0.80 { status = "ok" }
                    else if sim >= 0.60 { status = "warn" }
                    else { status = "fail" }
                    lines.append("| \(c.id) | \(route) | \(ms) | \(String(format: "%.2f", sim)) | \(status) |")
                    dump += "## \(c.id)\nroute=\(route) cleanup=\(cleanup) personality=\(pers) ms=\(ms) sim=\(String(format: "%.3f", sim)) status=\(status)\n\n"
                    dump += "RAW:\n\(c.raw)\n\nPOLISHED:\n\(out)\n\nREFERENCE:\n\(c.reference)\n\n---\n\n"
                    print("[POLISH-REPLAY] autorun: \(c.id) route=\(route) ms=\(ms) sim=\(String(format: "%.2f", sim)) status=\(status)")
                }
                let table = lines.joined(separator: "\n")
                let final = dump + "\n\(table)\n"
                let dir = GoldenCaseLoader.userDirectory().deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let outURL = dir.appendingPathComponent("polish_replay_last.md")
                try? final.write(to: outURL, atomically: true, encoding: .utf8)
                print("[POLISH-REPLAY] autorun: dump written to \(outURL.path) — terminating")
                NSApp.terminate(nil)
            }
        }

        // Granite 4.0 + Moonshine subprocess transcribers were disabled —
        // their source files (GraniteTranscriber.swift / MoonshineTranscriber.swift)
        // are not part of the Xcode project target. Parakeet v2 (built-in) is the
        // sole transcriber for this build. Re-enable here once the files are
        // added back to project.pbxproj.

        // First-run onboarding — non-blocking. The pill works without it.
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }

        // Update check fires once at launch, debounced internally to 24h.
        UpdateChecker.checkInBackground { [weak self] info in
            guard let self else { return }
            self.showToast("VOICE \(info.version) is available.")
        }

        Telemetry.log("app.launched", properties: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ])

        // Safety timer (0.5Hz / every 2s) — force-clears a stuck
        // `pendingRecordingStart` flag when it's sat true for more than 2s
        // with no actual recording. Belt-and-suspenders for any code path
        // that fails to clear it (audio engine startup failure, release
        // handler missed, etc.). See 5.1.
        pendingPillSafetyTimer?.invalidate()
        pendingPillSafetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.recordingState
            guard state.pendingRecordingStart,
                  let pendingAt = state.pendingRecordingStartAt,
                  Date().timeIntervalSince(pendingAt) > 2.0,
                  !state.isRecording else {
                return
            }
            print("[VOICE-PILL] safety-clear: pendingRecordingStart stuck for >2s")
            state.pendingRecordingStart = false
            state.pendingRecordingStartAt = nil
        }
        // Keep the timer alive during modal panels / nested run loops.
        if let timer = pendingPillSafetyTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[VOICE] Launched")
    }

    /// Wraps a startup step in do/catch + telemetry. Errors don't stop launch.
    private func runStartupStep(_ name: String, _ block: () throws -> Void) {
        do {
            try block()
        } catch {
            Telemetry.log("startup.failed", properties: ["step": name, "error": "\(error)"])
            print("[VOICE] startup step '\(name)' failed: \(error)")
        }
    }

    // MARK: - App Icon Assertion

    /// Load the bundle's app icon and set it on NSApp so the Dock, Cmd-Tab
    /// switcher, and About panel always show the rounded-rect icon instead of
    /// a scaled-up emoji placeholder.
    ///
    /// Strategy (in priority order):
    ///   1. NSImage(named: "AppIcon")              — Assets.car lookup
    ///   2. NSImage(named: NSImage.applicationIconName) — system alias
    ///   3. Bundle.main.path(forResource:ofType:)  — loose .icns in Resources
    ///   4. Bundle.main.urlForImageResource        — any image named AppIcon
    ///
    /// After loading, validates the image has >= 2 representations at varying
    /// pixel sizes. A single-rep image is a placeholder (the Dock scales it up
    /// to a square). If validation fails, falls back directly to the compiled
    /// AppIcon.icns inside the running bundle's Resources/ directory, bypassing
    /// Assets.car entirely.
    ///
    /// Safe to call multiple times — idempotent on a warm icon cache.
    private func assertAppIcon(context: String) {
        let candidates: [() -> NSImage?] = [
            { NSImage(named: "AppIcon") },
            { NSImage(named: NSImage.applicationIconName) },
            {
                guard let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") else { return nil }
                return NSImage(contentsOfFile: path)
            },
            {
                guard let url = Bundle.main.urlForImageResource("AppIcon") else { return nil }
                return NSImage(contentsOf: url)
            }
        ]

        // Find the first candidate that is at least 64 pt and has representations.
        var loadedIcon: NSImage? = nil
        for loader in candidates {
            if let img = loader(),
               img.size.width >= 64,
               img.size.height >= 64,
               !img.representations.isEmpty {
                loadedIcon = img
                break
            }
        }

        guard let icon = loadedIcon else {
            print("[VOICE-ICON][\(context)] WARNING: could not load AppIcon from any path — leaving Dock default")
            return
        }

        // Validate multi-rep: a proper .icns has representations at 16, 32, 128,
        // 256, 512 px. A single-rep image is a placeholder the Dock scales to a
        // square. Check for >= 2 reps AND at least 2 distinct pixel widths.
        let repSizes = Set(icon.representations.map { Int($0.pixelsWide) })
        let isValid  = icon.representations.count >= 2 && repSizes.count >= 2

        if isValid {
            print("[VOICE-ICON][\(context)] asserting icon size=\(icon.size) reps=\(icon.representations.count) widths=\(repSizes.sorted())")
            NSApp.applicationIconImage = icon
            return
        }

        // Validation failed — single-rep or uniform-size image (placeholder).
        // Bypass Assets.car and load the compiled .icns directly from disk.
        print("[VOICE-ICON][\(context)] WARNING: loaded icon is single-rep or single-size — forcing .icns reload")
        if let resPath = Bundle.main.resourcePath {
            let icnsPath = resPath + "/AppIcon.icns"
            if FileManager.default.fileExists(atPath: icnsPath),
               let icnsImg = NSImage(contentsOfFile: icnsPath) {
                let icnsReps   = icnsImg.representations.count
                let icnsSizes  = Set(icnsImg.representations.map { Int($0.pixelsWide) })
                if icnsReps >= 2 && icnsSizes.count >= 2 {
                    print("[VOICE-ICON][\(context)] reloaded from .icns reps=\(icnsReps) widths=\(icnsSizes.sorted())")
                    NSApp.applicationIconImage = icnsImg
                } else {
                    // .icns itself is degenerate — set whatever we have so the
                    // Dock at least shows something recognisable.
                    print("[VOICE-ICON][\(context)] .icns is also single-rep (reps=\(icnsReps)) — setting anyway")
                    NSApp.applicationIconImage = icnsImg
                }
            } else {
                print("[VOICE-ICON][\(context)] BUNDLED .icns NOT FOUND at \(icnsPath) — setting single-rep icon as fallback")
                NSApp.applicationIconImage = icon
            }
        } else {
            print("[VOICE-ICON][\(context)] could not resolve resourcePath — setting single-rep icon as fallback")
            NSApp.applicationIconImage = icon
        }
    }

    /// Dock-icon click while app is already running. Open the BigMenu so
    /// settings / stats / hotkey config are one click away. Returning false
    /// tells AppKit not to try to spawn a new window for an untitled doc
    /// (we're an LSUIElement-ish app — there's nothing to spawn).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openBigMenu()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Telemetry.log("app.terminate")
        // BUGFIX: invalidate ALL timers, not just the permission watcher.
        // pendingPillSafetyTimer was previously leaked across a restart-in-process.
        permissionWatcherTimer?.invalidate()
        permissionWatcherTimer = nil
        pendingPillSafetyTimer?.invalidate()
        pendingPillSafetyTimer = nil
        // BUGFIX: cancel in-flight Tasks so they don't try to mutate state
        // during the shutdown window (could race UserDefaults flushes below).
        cancelDismissTask?.cancel(); cancelDismissTask = nil
        errorDismissTask?.cancel(); errorDismissTask = nil
        pendingFinishTask?.cancel(); pendingFinishTask = nil
        pasteChain?.cancel(); pasteChain = nil
        if let observer = errorObserver {
            NotificationCenter.default.removeObserver(observer)
            errorObserver = nil
        }
        // BUGFIX: remove every block-based observer we registered.
        // Previously only `errorObserver` got cleaned up; the didBecomeActive
        // and voiceOpenBigMenu / voicePolishSelection observers leaked.
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        // Best-effort: if a recording is still in flight, stop it so the
        // file isn't left half-flushed. We don't await — terminate doesn't
        // give us time, but stopRecording's writer will close synchronously.
        if recordingState.isRecording || recordingState.isLocked {
            Task { @MainActor in _ = await coordinator.stopRecording() }
        }
        // STORAGE AUDIT FIX: force-flush UserDefaults before quit so the
        // most recent RecentDictation isn't lost on quick cmd-Q. AppKit
        // normally flushes on exit, but Task-spawned writes during the
        // tear-down window can race the shutdown. synchronize() is
        // deprecated but still works and is the only synchronous flush.
        UserDefaults.standard.synchronize()
        // (Granite / Moonshine subprocess shutdown removed — see launch comment.)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Confirm before quitting if a recording is active. Users have
        // lost dictations to accidental cmd-Q exactly once and that's enough.
        if recordingState.isRecording || recordingState.isLocked {
            let alert = NSAlert()
            alert.messageText = "Recording in progress"
            alert.informativeText = "Quitting will discard this dictation. Continue?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    private func setupMenuBar() {
        // squareLength reserves a fixed slot — variableLength can collapse
        // to 0 width if the icon fails to load, hiding the menu bar entry.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VOICE") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageOnly
            } else {
                // SF Symbols failed — visible "V" so the slot isn't blank.
                button.title = "V"
            }
            button.toolTip = "VOICE — fn to dictate"
        } else {
            print("[VOICE] WARNING: statusItem.button is nil — menu bar icon will not appear")
        }

        let menu = NSMenu()
        menu.delegate = self  // refresh dynamic items lazily on open

        let openItem = NSMenuItem(title: "Open VOICE", action: #selector(openBigMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Recent Dictations submenu — populated lazily in menuWillOpen so the
        // list always reflects the latest entries from the RecentDictations store.
        let recentsItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentsItem.tag = MenuTag.recentsSubmenu.rawValue
        let recentsSubmenu = NSMenu(title: "Recent Dictations")
        recentsItem.submenu = recentsSubmenu
        menu.addItem(recentsItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLoginService.isEnabled ? .on : .off
        launchItem.tag = MenuTag.launchAtLogin.rawValue
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About VOICE", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let diagItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        menu.addItem(NSMenuItem(title: "Quit VOICE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    /// Tags so we can find specific items in the menu when refreshing.
    /// Recents used to live here (`case recent = 1001`) but were consolidated
    /// into the BigMenu popup, so only the launch-at-login state needs a tag.
    private enum MenuTag: Int {
        case launchAtLogin = 1002
        case recentsSubmenu = 1003
    }

    /// Format an age in seconds as a compact relative string ("2m ago", "1h ago").
    private func relativeTimestamp(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        return "\(d)d ago"
    }

    /// Rebuild the Recent Dictations submenu with the latest 5 entries.
    /// Called from menuWillOpen so the list is always fresh.
    fileprivate func refreshRecentsSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let recents = Array(RecentDictations.all().prefix(5))
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: "No recent dictations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for r in recents {
            let oneLine = r.text.replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ")
            let preview = oneLine.count > 50 ? "\(oneLine.prefix(50))…" : oneLine
            let item = NSMenuItem(title: preview, action: #selector(copyRecentDictation(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = relativeTimestamp(r.timestamp)
            item.representedObject = r.text
            submenu.addItem(item)
        }
    }

    @objc private func copyRecentDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let next = !LaunchAtLoginService.isEnabled
        let ok = LaunchAtLoginService.setEnabled(next)
        if !ok {
            showToast("Failed to update Launch at Login")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "A menu-bar dictation app. Hold fn anywhere to talk.\nBuilt with care, runs entirely on-device.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "VOICE",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        ])
    }

    /// Gather a self-contained diagnostics blob and copy it to the clipboard.
    /// Pulls: app version, model state, current input device, recent dictation
    /// outcomes, and the tail of `events.jsonl` (Telemetry sink — captures the
    /// [VOICE-FUNNEL] equivalents via Telemetry.log calls). When the events
    /// file doesn't exist yet we still copy the metadata so the user has
    /// something useful to paste into a bug report.
    @objc private func copyDiagnostics() {
        var lines: [String] = []
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("VOICE diagnostics")
        lines.append("version: \(version) (build \(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("model state: \(coordinator.state.modelState)")
        lines.append("input device: \(currentInputDeviceName())")
        lines.append("accessibility trusted: \(AXIsProcessTrusted())")
        lines.append("lifetime dictations: \(recordingState.lifetimeDictations) / words: \(recordingState.lifetimeWords)")
        lines.append("session: dictations=\(recordingState.sessionDictationCount) words=\(recordingState.sessionTotalWords)")

        // Last 5 recent dictation outcomes (length + age).
        let recents = RecentDictations.all().prefix(5)
        lines.append("recent dictations (\(recents.count)):")
        for r in recents {
            let age = Int(Date().timeIntervalSince(r.timestamp))
            let preview = r.text.count > 40 ? "\(r.text.prefix(40))…" : r.text
            lines.append("  - \(r.text.count) chars, \(age)s ago: \(preview)")
        }

        // Tail the Telemetry log file — last 100 lines. This is our best
        // proxy for [VOICE-FUNNEL] capture without rewiring every `print`.
        if let url = Telemetry.logURL,
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            let all = raw.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = all.suffix(100)
            lines.append("--- events.jsonl tail (\(tail.count) lines of \(all.count)) ---")
            for line in tail { lines.append(String(line)) }
        } else {
            lines.append("--- events.jsonl: not present yet ---")
        }

        let blob = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(blob, forType: .string)
        NotificationCenter.default.post(
            name: .voiceError,
            object: nil,
            userInfo: ["message": "Diagnostics copied (\(blob.count) chars)"]
        )
        Telemetry.log("diagnostics.copied", properties: ["chars": blob.count])
    }

    /// Best-effort name of the current default input device. Returns "unknown"
    /// when CoreAudio refuses the query (rare).
    private func currentInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "unknown" }
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
              let cf = nameRef?.takeRetainedValue() else {
            return "unknown"
        }
        return cf as String
    }

    /// Show (or reuse) the Big Menu window.
    /// Real titled NSWindow now (no longer a floating borderless panel) — the
    /// system traffic lights handle close/min/zoom and an NSToolbar exposes
    /// the "…" overflow menu (Settings, About, Quit). Not floating; behaves
    /// like a standard app window so Cmd-Tab / Mission Control / minimize work.
    @objc func openBigMenu() {
        if let win = bigMenuWindow {
            // Re-verify the frame is on a visible screen each time we reopen —
            // the user may have disconnected the external display the window was
            // last dragged to, leaving its saved frame offscreen.
            ensureWindowOnScreen(win)
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = BigMenuWindow(recordingState: recordingState, onClose: { [weak self] in
            self?.bigMenuWindow?.performClose(nil)
        })
        let host = NSHostingController(rootView: view)
        // DO NOT set host.sizingOptions = .preferredContentSize — on macOS 26+ beta
        // it calls preferredContentSize inside a constraint layout pass, which fires
        // _postWindowNeedsUpdateConstraints and crashes. Fixed 440×620 initial frame
        // is used instead, restored across launches via setFrameAutosaveName.

        // Titled window with full-size content + transparent titlebar so the
        // vibrancy background flows under the traffic lights for the modern
        // macOS look. Toolbar item on the right gives us the "…" overflow.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 700, height: 500)
        win.title = "VOICE"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.delegate = self
        // Standard window behavior — DO NOT make this floating / all-spaces.
        // It should behave like any normal app window so Cmd-Tab + Mission
        // Control treat it correctly.
        win.collectionBehavior = [.fullScreenAuxiliary, .managed]
        win.hidesOnDeactivate = false

        // Toolbar with a single primary item ("…") on the right, which opens
        // a popup menu (Settings, About, Quit). Identifier matters for the
        // delegate callbacks below.
        let toolbar = NSToolbar(identifier: "VoiceBigMenuToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        toolbar.delegate = self
        win.toolbar = toolbar
        if #available(macOS 11.0, *) {
            win.toolbarStyle = .unifiedCompact
        }

        // Remember where the user dragged it. setFrameAutosaveName both registers
        // future saves AND immediately restores any previously-saved frame, so
        // calling this can move the window before we have a chance to validate
        // that the saved frame is still on a visible screen.
        win.setFrameAutosaveName("VoiceBigMenu")

        // First-launch position: anchored below the menu bar, right-aligned.
        // Subsequent launches restore the user's saved frame via autosave — but
        // only if that frame is still on-screen.
        ensureWindowOnScreen(win, defaultSize: NSSize(width: 760, height: 620))

        // Bump up an old too-small autosaved frame to the new ideal.
        if win.frame.height < 500 || win.frame.width < 700 {
            var f = win.frame
            f.size.width  = max(f.size.width,  760)
            let extraHeight = max(0, 620 - f.size.height)
            f.size.height += extraHeight
            f.origin.y    -= extraHeight
            win.setFrame(f, display: true)
        }

        bigMenuWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Build and show the "…" toolbar overflow menu. Wired to the toolbar item
    /// via target/action in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`.
    @objc fileprivate func showBigMenuOverflow(_ sender: Any?) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openBigMenuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About VOICE", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit VOICE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        // Anchor the popup under the toolbar item.
        if let button = sender as? NSButton {
            let loc = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: loc, in: button)
        } else if let win = bigMenuWindow, let contentView = win.contentView {
            // Fallback — anchor in the top-right of the content view.
            let loc = NSPoint(x: contentView.bounds.maxX - 40, y: contentView.bounds.maxY - 8)
            menu.popUp(positioning: nil, at: loc, in: contentView)
        }
    }

    /// Open the Settings sheet hosted inside the BigMenu. Posts a notification
    /// the SwiftUI view observes (it can't be called directly from AppKit).
    @objc fileprivate func openBigMenuSettings() {
        NotificationCenter.default.post(name: .voiceOpenBigMenuSettings, object: nil)
    }

    /// Verify the window's current frame is on a visible screen. If not, reset
    /// to a default position anchored below the menu bar on the main screen and
    /// purge the bad autosaved frame so we don't restore it again next launch.
    private func ensureWindowOnScreen(_ win: NSWindow, defaultSize: NSSize? = nil) {
        let frame = win.frame
        // A frame is considered visible if it intersects any screen's visibleFrame
        // by at least 40 pts in both dimensions (so a sliver poking onto a screen
        // doesn't count — the user effectively can't see/grab it).
        let minOverlap: CGFloat = 40
        let onScreen = NSScreen.screens.contains { screen in
            let inter = screen.visibleFrame.intersection(frame)
            return inter.width >= minOverlap && inter.height >= minOverlap
        }
        if onScreen { return }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = defaultSize ?? frame.size
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y
        let margin: CGFloat = 12
        let x = screen.frame.maxX - size.width - margin
        let y = screen.frame.maxY - menuBarHeight - size.height - margin
        win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        // Purge the bad autosave so we don't restore the offscreen frame next
        // launch. The autosave key is prefixed with "NSWindow Frame ".
        let name = win.frameAutosaveName
        if !name.isEmpty {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
    }
}

// MARK: - FloatingMenuPanel (legacy — kept for source compatibility)
// Was used for the borderless BigMenu popup. The BigMenu now uses a real
// titled NSWindow, so this class isn't constructed anymore. Left in place so
// any stray reference (e.g. old build output, downstream tooling) still
// compiles. Safe to delete once we're sure nothing references it.
final class FloatingMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - NSToolbarDelegate (BigMenu "…" overflow)

extension AppDelegate: NSToolbarDelegate {
    private static let bigMenuOverflowID = NSToolbarItem.Identifier("VoiceBigMenuOverflow")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bigMenuOverflowID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bigMenuOverflowID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.bigMenuOverflowID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "More"
        item.paletteLabel = "More"
        item.toolTip = "More options"
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.title = ""
        let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        button.image = img
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showBigMenuOverflow(_:))
        item.view = button
        return item
    }
}

// MARK: - NSMenuDelegate (refresh dynamic items on open)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == MenuTag.launchAtLogin.rawValue {
                item.state = LaunchAtLoginService.isEnabled ? .on : .off
            } else if item.tag == MenuTag.recentsSubmenu.rawValue, let sub = item.submenu {
                refreshRecentsSubmenu(sub)
            }
        }
    }
}

// MARK: - Toast + Onboarding + Error surfacing

extension AppDelegate {

    fileprivate func setupErrorObserver() {
        errorObserver = NotificationCenter.default.addObserver(
            forName: .voiceError,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?["message"] as? String) ?? "Something went wrong."
            Telemetry.log("error.surface", properties: ["message": message])
            Task { @MainActor in self?.showToast(message) }
        }

        // Idle-pill context menu → "Open VOICE…"
        // BUGFIX: capture the token so applicationWillTerminate can remove it.
        let openBigMenuToken = NotificationCenter.default.addObserver(
            forName: .voiceOpenBigMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            MainActor.assumeIsolated { self?.openBigMenu() }
        }
        notificationTokens.append(openBigMenuToken)

        // Opt+1 → polish selected text in any field.
        // BUGFIX: capture the token so applicationWillTerminate can remove it.
        let polishSelectionToken = NotificationCenter.default.addObserver(
            forName: .voicePolishSelection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[VOICE-OPT1] notification received")
            MainActor.assumeIsolated { self?.handlePolishSelection() }
        }
        notificationTokens.append(polishSelectionToken)

        // (The Meetings tab used to post cancel/commit notifications observed
        // here. That tab was removed in favor of a future browser-extension
        // sourced meetings view — observers gone too.)
    }

    @MainActor
    private func handlePolishSelection() {
        print("[VOICE-OPT1] handlePolishSelection ENTER")
        guard AXIsProcessTrusted() else {
            print("[VOICE-OPT1] BLOCKED: AX not trusted")
            showToast("Accessibility access required for polish selection")
            return
        }
        guard !recordingState.isPolishingSelection else {
            print("[VOICE-OPT1] BLOCKED: already polishing")
            return
        }

        let selectedText = cursorPaster.getSelectedText()
        print("[VOICE-OPT1] getSelectedText → \(selectedText.map { "\"\($0.prefix(40))\" (\($0.count) chars)" } ?? "nil")")

        guard let text = selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("No text selected — select text first, then press ⌥1")
            return
        }

        recordingState.isPolishingSelection = true

        Task { @MainActor in
            defer {
                self.recordingState.isPolishingSelection = false
                print("[VOICE-OPT1] DONE — isPolishingSelection cleared")
            }

            print("[VOICE-OPT1] Calling Qwen3Polisher.polish() …")
            let polished = await Qwen3Polisher.shared.polish(
                text,
                context: .default,
                cleanupLevel: CleanupLevel.current.rawValue,
                personalityStyle: PersonalityStyle.current.rawValue
            )
            print("[VOICE-OPT1] polish returned: \"\(polished.prefix(80))\"")

            guard polished.trimmingCharacters(in: .whitespacesAndNewlines)
                    != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                self.showToast("Already polished")
                return
            }

            self.cursorPaster.replaceSelection(with: polished)
            self.showToast("✓ Polished")
        }
    }

    // MARK: - Permission handling

    /// Single permission-miss handler. Throttles the system prompt to once
    /// per session, deep-links to the right Privacy pane, and starts a
    /// background watcher so that as soon as Accessibility flips to granted
    /// we rebind the hotkey monitors (NSEvent monitors registered before
    /// permission was granted don't deliver events retroactively).
    fileprivate func handleMissingPermissions(micOk: Bool, axOk: Bool, micStatus: AVAuthorizationStatus) {
        if !micOk {
            if micStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if !didShowMicPrompt {
                didShowMicPrompt = true
                openPrivacyPane("Privacy_Microphone")
                showToast("Enable VOICE under Privacy → Microphone, then try again.")
            } else {
                showToast("Microphone access required — open System Settings → Privacy → Microphone.")
            }
            return
        }

        if !axOk {
            if !didShowAXPrompt {
                didShowAXPrompt = true
                // Fire the one-time system prompt + jump the user straight
                // to the Accessibility pane.
                // BUGFIX: kAXTrustedCheckOptionPrompt is a global CFString
                // constant. Using takeRetainedValue here over-retains it (the
                // framework never released it for us to claim). Switch to
                // takeUnretainedValue — Apple's documented pattern.
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                openPrivacyPane("Privacy_Accessibility")
                startPermissionWatcher()
                showToast("Enable VOICE under Privacy → Accessibility — the app will rebind automatically.")
            } else {
                showToast("Accessibility access required — open System Settings → Privacy → Accessibility.")
            }
        }
    }

    /// Open the System Settings → Privacy → <pane> directly. The
    /// `x-apple.systempreferences:` URL scheme handles both legacy and
    /// modern (System Settings) variants — macOS picks the right one.
    fileprivate func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Detect transcripts that landed in a non-Latin script (Greek, Cyrillic,
    /// CJK, Arabic, Hebrew, Thai, Devanagari etc.). Returns true if >30% of
    /// the letter characters are outside the Basic Latin / Latin-1 /
    /// Latin-Extended ranges. English and Dutch both live entirely inside
    /// Latin script, so a high non-Latin ratio is a reliable sign that the
    /// multilingual ASR mis-identified the language.
    fileprivate func isPredominantlyNonLatin(_ text: String) -> Bool {
        var latin = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars {
            // Only score letters — punctuation and digits are script-neutral.
            guard scalar.properties.generalCategory == .uppercaseLetter
               || scalar.properties.generalCategory == .lowercaseLetter
               || scalar.properties.generalCategory == .titlecaseLetter
               || scalar.properties.generalCategory == .modifierLetter
               || scalar.properties.generalCategory == .otherLetter else { continue }
            let v = scalar.value
            // Basic Latin (U+0041–U+005A, U+0061–U+007A), Latin-1 Supplement
            // letters (U+00C0–U+00FF), Latin Extended-A (U+0100–U+017F),
            // Latin Extended-B (U+0180–U+024F).
            let isLatin = (v >= 0x0041 && v <= 0x005A)
                       || (v >= 0x0061 && v <= 0x007A)
                       || (v >= 0x00C0 && v <= 0x00FF)
                       || (v >= 0x0100 && v <= 0x024F)
            if isLatin { latin += 1 } else { nonLatin += 1 }
        }
        let total = latin + nonLatin
        guard total >= 4 else { return false }  // too few chars to judge
        return Double(nonLatin) / Double(total) > 0.30
    }

    /// Count the spoken punctuation / structural commands the TextFormatter
    /// will turn into characters. Conservative substring count over the raw
    /// Parakeet transcript — matches the same vocabulary the formatter checks
    /// (period, comma, new line, exclamation, etc.). Used by the BigMenu
    /// stats row to populate "fixes made by voice".
    fileprivate func countVoiceCommands(in raw: String) -> Int {
        let lowered = " " + raw.lowercased() + " "
        // Multi-word phrases first so "exclamation point" isn't counted twice
        // (once as the long phrase, once as "point" — but we don't track that
        // anyway). Order mirrors TextFormatter.voiceCommands intent.
        let phrases: [String] = [
            "new paragraph", "new line", "next line",
            "exclamation point", "exclamation mark", "explanation point", "explanation mark",
            "question mark", "full stop", "open quote", "close quote",
            "open paren", "close paren", "bullet point", "dash point", "numbered list",
            "dash dash", "double dash", "double hyphen", "equals sign",
            "period", "comma", "colon", "semicolon", "ellipsis",
            "tilde", "caret", "dash", "bullet", "tab"
        ]
        // Strip multi-word phrases by length first to avoid double-count.
        var scratch = lowered
        var total = 0
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let needle = " " + phrase + " "
            var searchRange = scratch.startIndex..<scratch.endIndex
            while let r = scratch.range(of: needle, range: searchRange) {
                total += 1
                scratch.replaceSubrange(r, with: " ")
                searchRange = r.lowerBound..<scratch.endIndex
            }
        }
        return total
    }

    /// Capture the frontmost app at the moment dictation begins, so we can
    /// re-activate it before paste. Skips capturing if VOICE itself happens
    /// to be frontmost (the pill, BigMenu, or Settings) — in that case the
    /// target is whatever was previous; leaving `targetAppBundleID` nil
    /// just means paste goes wherever focus lands naturally.
    fileprivate func captureTargetApp() {
        let ownID = Bundle.main.bundleIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else {
            targetAppBundleID = nil
            capturedFieldContext = nil
            return
        }
        if let id = front.bundleIdentifier, id != ownID {
            targetAppBundleID = id
        }
        // else: VOICE was frontmost — keep whatever `targetAppBundleID` we
        // captured previously (might still be valid from the last session)

        // Sample the text-field context NOW (recording start), not at paste.
        // At this moment the target field reliably owns AX focus. We read up
        // to 24 chars before the cursor — enough for the polisher to detect
        // "ends mid-sentence", "ends with period+space", "ends with bullet 2.",
        // etc. without burning prompt tokens.
        capturedFieldContext = cursorPaster.sampleFieldContextBeforeCursor(length: 24)
        print("[VOICE] field context @ record-start: \"\(capturedFieldContext ?? "<nil>")\"")
    }

    /// Bring the target app back to the foreground before pasting. No-op if
    /// it's already frontmost or if we never captured one.
    fileprivate func restoreTargetApp() {
        guard let id = targetAppBundleID else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != id else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        }
    }

    /// Poll AXIsProcessTrusted() every 1.5s. When it flips from false → true
    /// (user just granted access), restart the hotkey monitors so events
    /// start flowing without the user having to relaunch the app.
    fileprivate func startPermissionWatcher() {
        guard permissionWatcherTimer == nil else { return }
        lastObservedAXTrusted = AXIsProcessTrusted()
        permissionWatcherTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            MainActor.assumeIsolated {
                if now && !self.lastObservedAXTrusted {
                    print("[VOICE] Accessibility flipped: false → true. Rebinding monitors.")
                    self.hotkeyService.startMonitoring()
                    self.showToast("VOICE is ready. Try the hotkey now.")
                    self.permissionWatcherTimer?.invalidate()
                    self.permissionWatcherTimer = nil
                }
                self.lastObservedAXTrusted = now
            }
        }
    }

    /// Top-right NSPanel toast. Independent of the dictation pill so we
    /// never interfere with the user's primary UI.
    fileprivate func showToast(_ message: String) {
        errorDismissTask?.cancel()

        // Reuse if already on screen — just update the text.
        if let panel = errorToastWindow,
           let host = panel.contentViewController as? NSHostingController<ToastView> {
            host.rootView = ToastView(message: message)
        } else {
            let host = NSHostingController(rootView: ToastView(message: message))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentViewController = host
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = panel.frame.size
                let origin = NSPoint(
                    x: frame.maxX - size.width - 16,
                    y: frame.maxY - size.height - 16
                )
                panel.setFrameOrigin(origin)
            }
            errorToastWindow = panel
        }

        errorToastWindow?.orderFrontRegardless()

        errorDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.errorToastWindow?.orderOut(nil)
        }
    }

    fileprivate func showOnboarding() {
        guard onboardingWindow == nil else { return }
        let host = NSHostingController(rootView: OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
            self?.onboardingWindow?.orderOut(nil)
            self?.onboardingWindow = nil
            Telemetry.log("onboarding.completed")
        })
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to VOICE"
        panel.contentViewController = host
        panel.center()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        onboardingWindow = panel
        panel.makeKeyAndOrderFront(nil)
        Telemetry.log("onboarding.shown")
    }
}

// MARK: - Toast + Onboarding views

private struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, body: String)] = [
        ("Welcome to VOICE", "Hold Right Option (⌥) anywhere on your Mac and start talking. Release to paste the transcript at your cursor."),
        ("Two permissions, then you're set", "VOICE needs Microphone (to hear you) and Accessibility (to paste text). macOS will ask the first time."),
        ("You're set", "The waveform icon lives in your menu bar. Click it any time for settings or recent dictations.")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text(pages[page].title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(pages[page].body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                Text("\(page + 1) / \(pages.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get started", action: onFinish)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === bigMenuWindow else { return }
        // App always stays in the dock (.regular policy), nothing to revert.
    }

    // MARK: - Overlay

    private func setupOverlayPanel() {
        overlayPanel = OverlayPanel(recordingState: recordingState)

        overlayPanel?.onTap = { [weak self] in
            self?.handlePillTap()
        }

        overlayPanel?.onCancel = { [weak self] in
            self?.cancelRecording()
        }

        overlayPanel?.onConfirm = { [weak self] in
            self?.commitRecording()
        }

        overlayPanel?.onUndoCancel = { [weak self] in
            self?.undoCancel()
        }

        overlayPanel?.showPersistent()
    }

    /// Tapping the idle pill enters lock mode (same as double-tapping the hotkey).
    private func handlePillTap() {
        if recordingState.showingCancelledToast {
            dismissCancelledToast()
            return
        }
        guard !recordingState.isLocked else { return }
        guard !recordingState.isRecording else { return }
        guard coordinator.transcription.isReady else {
            showToast("Model loading, please wait…")
            return
        }
        print("[VOICE] Pill tap → lock recording")
        enterLockMode()
    }

    private func enterLockMode() {
        recordingState.isLocked = true
        hotkeyService.isLocked = true
        // Auto-commit after silence in lock mode.
        // TODO(bug-hunt): the isLocked check runs before the async-dispatch,
        // so a user-tapped Cancel between the check and the runloop turn
        // could let a stale silence-timeout finishRecording() fire after
        // cancel. Low-likelihood (one runloop iteration) but the right fix
        // is re-checking isLocked inside the dispatched block.
        coordinator.audioCapture.onSilenceTimeout = { [weak self] in
            guard let self, self.recordingState.isLocked else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingState.isLocked else { return }
                self.finishRecording()
            }
        }
        // With the deferred-quickRelease state machine, double-tap entry
        // happens WHILE the first tap's recording is still running. Do not
        // restart it — that would race a fresh start against a pending stop
        // AND play a duplicate start sound. Just flip the lock flags.
        // If somehow no recording is active (e.g. UI-button-triggered lock),
        // start one as a safety net.
        if !recordingState.isRecording {
            recordingStartedAt = Date()
            recordingState.cancelledTranscript = []
            // BUGFIX: rotate the session ID for this safety-net fresh start so
            // any prior in-flight finishRecording Task can detect the new
            // session and bail (matches Path 2/3 in hotkeyDidActivate).
            recordingState.recordingSessionID = UUID()
            coordinator.startRecording()
            SoundEffects.playStart()
        }
        // Start live preview — only meaningful for long recordings; short PTT
        // sessions never see a partial before stop, so this is a no-op for them.
        coordinator.startLivePartials()
    }

    private func exitLockMode() {
        recordingState.isLocked = false
        hotkeyService.isLocked = false
        coordinator.audioCapture.onSilenceTimeout = nil
        coordinator.stopLivePartials()
    }

    /// X button — discard recording, show cancelled toast with Undo.
    private func cancelRecording() {
        print("[VOICE] Cancel → discard")
        // BUGFIX (Category 8): claim the recording synchronously so we capture the
        // audio URL, then explicitly delete the file on disk after stop completes.
        // Without this, cancelling left the .caf orphaned on disk until the size
        // pruner reaped it (could be days). User intent on cancel is "throw it away".
        let claimedForCancel = recordingState.isRecording ? coordinator.claimRecordingSync() : nil
        let urlToDelete = claimedForCancel?.audioURL
        // BUGFIX: clear pendingRecordingStart so the pill doesn't get stuck in
        // the .recording phase if cancel arrived between Path 3 sync mutations.
        recordingState.pendingRecordingStart = false
        exitLockMode()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.coordinator.stopRecording(claiming: claimedForCancel)
            if let url = urlToDelete {
                try? FileManager.default.removeItem(at: url)
                print("[VOICE] Cancel → deleted audio file \(url.lastPathComponent)")
            }
            self.showCancelledToast()
        }
    }

    /// ✓ button — finalize recording and paste at cursor.
    private func commitRecording() {
        print("[VOICE] Confirm → transcribe + paste")
        exitLockMode()
        finishRecording()
    }

    /// End recording, drain the streaming engine, then copy + paste at cursor.
    /// Each invocation runs to completion independently — if the user re-presses
    /// the hotkey while a prior finish is mid-flight, the prior task keeps going
    /// and its transcript still lands at the cursor (queued via pasteChain so it
    /// arrives in chronological order behind the older one).
    private func finishRecording() {
        print("[VOICE-TIMING] finishRecording entered at \(Date())")
        let wasRecording = recordingState.isRecording
        let started = recordingStartedAt
        // Snapshot the session ID at entry. Task A below uses this to detect
        // whether a NEW recording has started in the meantime — if so, the
        // stale finish bails out before it can mutate state belonging to the
        // new session (see 5.2 "race between finishRecording and re-press").
        let mySession = recordingState.recordingSessionID
        print("[VOICE-HK] finishRecording: wasRecording=\(wasRecording)  started=\(started?.description ?? "nil")  session=\(mySession)")

        // === ATOMIC CLAIM: synchronously stop audio capture and snapshot the
        // current recording's resources BEFORE we return from this function.
        //
        // The bug this fixes: finishRecording() creates a Task (Task A) and
        // returns. Between that return and Task A's body running, the main
        // actor's run-loop can process the next keyDown event. If the user
        // re-pressed the hotkey, hotkeyDidActivate Path 2 calls
        // coordinator.startRecording() — setting isRecording = true for the
        // NEW recording. Task A then calls coordinator.stopRecording(), sees
        // isRecording = true, and stops the NEW recording instead of recording 1.
        // The prior transcript is lost; recording 2 is also corrupted.
        //
        // By calling claimRecordingSync() here — on the main actor, synchronously,
        // before returning — we atomically flip isRecording = false and capture
        // the audio URL. startRecording() for the new recording can only start
        // AFTER this function returns, so it always gets a fresh URL. Task A
        // then calls stopRecording(claiming:) with the pre-captured context and
        // transcribes the right audio file regardless of what the new recording is doing.
        let claimed: RecordingCoordinator.ClaimedRecording? = wasRecording ? coordinator.claimRecordingSync() : nil
        print("[VOICE-TIMING] claimRecordingSync done at \(Date()) (claimed=\(claimed != nil))")

        // === ATOMIC STATE TRANSITION: recording → transcribing ===
        // Flip transcribing ON now that we've claimed the recording.
        recordingState.pendingRecordingStart = false
        if wasRecording {
            recordingState.transcribingCount += 1
            SoundEffects.playStop()
        }

        recordingStartedAt = nil
        guard wasRecording else {
            // No active recording — nothing to drain. Make sure we still
            // tell the engine to stop in case a streaming session is open.
            print("[VOICE-HK] finishRecording: wasRecording=false, bailing (this is the silent-discard bug if it fires after a real hold)")
            Task { @MainActor in _ = await coordinator.stopRecording() }
            return
        }

        let duration = started.map { Date().timeIntervalSince($0) } ?? 0
        print("[VOICE-HK] finishRecording: duration=\(duration)s")
        if duration < minRecordingDuration {
            print("[VOICE] Too short (\(duration)s) → silent discard")
            // Pass the claim through so stopRecording() still does its drain+cleanup,
            // but the result is discarded since duration is too short.
            Task { @MainActor in _ = await coordinator.stopRecording(claiming: claimed) }
            recordingState.transcribingCount = max(0, recordingState.transcribingCount - 1)
            recordingState.currentTranscript = []
            return
        }

        // Snapshot the paste-destination state RIGHT NOW (synchronously on the
        // main actor) so a later Path 2 re-press that calls captureTargetApp()
        // can't repoint this task's paste at the wrong field. Each finish task
        // owns its own copy of where its transcript belongs.
        let capturedTargetForTask = targetAppBundleID
        let capturedFieldContextForTask = capturedFieldContext

        // Each finish gets its OWN Task. We intentionally do NOT cancel the
        // previous pendingFinishTask — if the user re-pressed the hotkey
        // before the prior pipeline finished, the prior transcript still
        // needs to reach the cursor. We just overwrite the reference so the
        // most recent task is reachable for diagnostics.
        pendingFinishTask = Task { @MainActor in
            // GUARANTEED CLEAR: no matter how the task ends — empty
            // transcript, error, cancellation, hung Ollama — isTranscribing
            // resets to false. The pill never gets stuck on the loading state.
            defer {
                self.recordingState.transcribingCount = max(0, self.recordingState.transcribingCount - 1)
                // Ensure live partials are always cleaned up regardless of
                // which code path triggered finishRecording (silence timeout,
                // hotkey, or confirm button — all paths end here).
                coordinator.stopLivePartials()
            }

            // SESSION RACE GUARD: if a fresh recording has started since this
            // Task was scheduled (the user re-pressed the hotkey), the session
            // ID will have rotated. Abandon now — before any state mutation —
            // so we don't stopRecording on the NEW session or stomp on its
            // currentTranscript / livePartialText buffers. The already-claimed
            // audio for this stale session was captured synchronously above
            // (via claimRecordingSync), so dropping it on the floor is safe.
            guard self.recordingState.recordingSessionID == mySession else {
                print("[VOICE-RACE] session changed, abandoning stale finishRecording (mine=\(mySession) current=\(self.recordingState.recordingSessionID))")
                return
            }

            // ============================================================
            // LATENCY PROFILING — captures per-stage wall time so we can prove
            // where the pipeline is spending its budget. Single source of
            // truth: every stage logs from t0; the final TOTAL is t_now - t0.
            // Also forwarded to Telemetry so the JSONL log can be diffed by
            // build / model / app target.
            // ============================================================
            let tPipelineStart = CFAbsoluteTimeGetCurrent()
            // Drain the streaming engine using the pre-claimed recording context.
            // The claim was captured synchronously above (before this Task was
            // created), so stopRecording(claiming:) works on recording 1's audio
            // file even if recording 2 has already started. Race against a hard
            // 25s ceiling as belt-and-suspenders against any pathological hang.
            let segments: [TranscriptSegment] = await withTaskGroup(
                of: [TranscriptSegment]?.self
            ) { group in
                group.addTask { await self.coordinator.stopRecording(claiming: claimed) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? []
            }
            let parakeetMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
            fputs("[LATENCY] Parakeet (drain+ASR): \(Int(parakeetMs))ms\n", stderr)
            print("[VOICE-TIMING] Parakeet returned at \(Date())")
            // BUGFIX (Category 4): reserve our slot in pasteChain RIGHT NOW (right after
            // Parakeet returns) so paste order = finishRecording-call order, NOT
            // polish-completion order. Previously pasteChain was assigned AFTER polish
            // completed — if recording A's polish ran slower than recording B's, B's
            // paste could land first, scrambling chronological order at the cursor.
            // The reserved anchor task simply awaits the prior chain link; the real
            // paste task (assigned below after polish) awaits this anchor.
            let priorChainAtParakeetReturn: Task<Void, Never>? = pasteChain
            let pasteOrderAnchor: Task<Void, Never> = Task { @MainActor in
                _ = await priorChainAtParakeetReturn?.value
            }
            pasteChain = pasteOrderAnchor
            if Task.isCancelled { return }

            // Preserve segment timing so the formatter can insert paragraph
            // breaks on long pauses for natural-looking long-form output.
            let segmentsForFormat = segments.map {
                (text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
            }
            let rawText = segmentsForFormat
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            recordingState.currentTranscript = []
            // Final transcript has landed — clear live preview so partial text
            // doesn't linger after the real result is pasted.
            recordingState.livePartialText = ""

            if rawText.isEmpty {
                print("[VOICE] Empty transcript → silent")
                return
            }

            // Language gate: VOICE supports English + Dutch (both Latin-script).
            // Parakeet TDT v3 is multilingual and occasionally misidentifies
            // unfamiliar audio as Greek / Russian / Chinese etc. If the result
            // is dominantly non-Latin, treat it as a misrecognition rather
            // than pasting garbage at the cursor.
            if isPredominantlyNonLatin(rawText) {
                print("[VOICE] Non-Latin transcript rejected (only English + Dutch supported): '\(rawText.prefix(40))'")
                // Save the raw transcript to clipboard so the user doesn't lose it.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(rawText, forType: .string)
                print("[VOICE] Non-Latin transcript saved to clipboard (\(rawText.count) chars)")
                // STORAGE AUDIT FIX: Also persist to RecentDictations so the user can
                // recover the rejected transcript from the History menu (BigMenu).
                // Without this, a rejected dictation is invisible after the toast dismisses.
                // We mark the polish stage as "skipped" (polishMs = nil, no fix count)
                // since the language gate ran before polish.
                RecentDictations.add(
                    raw: nil,
                    polished: rawText,
                    pasteTargetBundleID: capturedTargetForTask,
                    polishMs: nil,
                    granite: nil,
                    moonshine: nil,
                    parakeetRaw: rawText,
                    suspects: nil,
                    durationSeconds: Int(duration),
                    voiceCommandCount: nil,
                    cleanupLevelUsed: nil,
                    personalityStyleUsed: nil,
                    polishFixCount: nil
                )
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Transcript saved to clipboard — mixed script detected"]
                )
                return
            }

            // ============================================================
            // FUNNEL OBSERVABILITY — every stage logged with [VOICE-FUNNEL]
            // so the user can grep one prefix to see exactly what each layer
            // produced. Non-optional: this is how we diagnose "Chachi Pt"-
            // class bugs (something landed at paste that shouldn't have).
            // ============================================================
            print("[VOICE-FUNNEL] STAGE 1 PARAKEET raw=\"\(rawText)\" chars=\(rawText.count) segments=\(segments.count)")

            // Run formatter — paragraph-aware, synchronous (no Ollama round-trip).
            let tFormatStart = CFAbsoluteTimeGetCurrent()
            let formatted = textFormatter.formatSegments(segmentsForFormat)
            let formatterMs = (CFAbsoluteTimeGetCurrent() - tFormatStart) * 1000
            fputs("[LATENCY] TextFormatter: \(Int(formatterMs))ms\n", stderr)
            print("[VOICE-FUNNEL] STAGE 2 FORMATTER out=\"\(formatted)\" chars=\(formatted.count) diff=\(formatted != rawText)")
            // isTranscribing flips false in `defer` after this block returns —
            // pill exits the transcribing state right before paste happens.

            // Auto-copy is on by default — clipboard is the safety net for
            // when paste fails. Toggle in BigMenu → Output.
            let autoCopy: Bool = {
                if UserDefaults.standard.object(forKey: "autoCopy") == nil { return true }
                return UserDefaults.standard.bool(forKey: "autoCopy")
            }()

            // Auto-paste at cursor — default ON. Transcript also lands on
            // the clipboard. Toggle in BigMenu → Output if you want OFF.
            let autoPaste: Bool = {
                if UserDefaults.standard.object(forKey: "autoPaste") == nil { return true }
                return UserDefaults.standard.bool(forKey: "autoPaste")
            }()
            print("[VOICE] autoPaste setting: \(autoPaste)")

            // ============================================================
            // POLISH ENABLE TOGGLE — UI-facing kill switch.
            // Storage key `polishEnabled` (defaults to true). When false we
            // skip Qwen3 entirely and paste TextFormatter output directly.
            // This is the single biggest perceived-latency win on a hot mic
            // (sub-second paste vs. multi-second wait for the LLM).
            //
            // Distinct from `llmPolishEnabled` (the old internal flag the
            // polisher itself reads) — that one stays for backward compat,
            // this one is the new user-visible setting wired into the UI.
            // ============================================================
            let polishEnabledByUser: Bool = {
                if UserDefaults.standard.object(forKey: "polishEnabled") == nil { return true }
                return UserDefaults.standard.bool(forKey: "polishEnabled")
            }()
            // ============================================================
            // OPTIMISTIC PASTE — "type now, refine after".
            // Storage key `optimisticPaste` (defaults to false). When true
            // AND polish is enabled AND polish hasn't been short-circuited
            // for any reason, paste the TextFormatter output IMMEDIATELY,
            // then run Qwen3 in background and try to swap. Swap only
            // happens when the pasteboard fingerprint hasn't changed since
            // our optimistic write (a rough "user hasn't typed over us" gate)
            // — otherwise the polished text is dropped and the unpolished
            // text remains. Opt-in because the swap involves Cmd+Z which
            // can feel disruptive if the user is fast-typing.
            // ============================================================
            let optimisticPasteEnabled: Bool = {
                if UserDefaults.standard.object(forKey: "optimisticPaste") == nil { return false }
                return UserDefaults.standard.bool(forKey: "optimisticPaste")
            }()
            // LLM polish runs only if enabled+available; otherwise returns
            // `formatted` unchanged after a near-zero check. 800ms hard
            // timeout inside the polisher guards paste latency (warm
            // Qwen3-0.6B-4bit on M2 typically completes in ~80–150ms).
            // Insertion-context hint lets the model bias for chat / email and
            // skip entirely in code editors.
            print("[VOICE] Starting polish... (formatted=\(formatted.count) chars) polishEnabledByUser=\(polishEnabledByUser)")
            let polishContext = cursorPaster.currentPolishContext()
            // Aggregate suspect words across segments — the polisher gets one
            // flat list. Combined dictionary (starter + user) is also surfaced
            // so the model knows e.g. "GitHub" not "get hub".
            let parakeetSuspectsAgg = segments.compactMap { $0.suspectWords }.flatMap { $0 }
            let formatterSuspects = TextFormatter.suspectsForPolish(formatted)
            let suspectWords = Array(Set(parakeetSuspectsAgg + formatterSuspects))
            // Merge built-in dictionary terms with the user's auto-learned
            // proper nouns (brand names, frequent contacts). Auto-learned
            // first so they take priority in any de-duplication.
            let userVocab = Array(Set(ProperNounVocabulary.current() + CombinedDictionary.terms()))
            let polishStart = Date()
            // Short-utterance bypass: when RecordingCoordinator flagged the
            // current clip as 16-36KB ("ok"/"yeah"/"no" territory), skip the
            // LLM polish pass and keep the rule-based formatted text. Polish
            // on a single word costs ~100ms and sometimes mangles it.
            let skipPolish = recordingState.skipPolishForCurrent
            recordingState.skipPolishForCurrent = false  // consume the flag
            let graniteTranscript = recordingState.graniteTranscript
            recordingState.graniteTranscript = nil        // consume the flag
            let moonshineTranscript = recordingState.moonshineTranscript
            recordingState.moonshineTranscript = nil      // consume the flag
            // Decide up-front whether this dictation will actually hit the LLM.
            // Used to gate optimistic paste: there's no point doing the
            // "paste-now, replace-after" dance if polish was going to be a
            // no-op anyway (short clip, polish disabled, non-English, etc.).
            let polishWillRun = CleanupLevel.current != .none && polishEnabledByUser && !skipPolish

            // Optimistic paste: paste TextFormatter output immediately, BEFORE
            // the LLM round trip. The post-polish replace is best-effort.
            //
            // We push the optimistic paste onto pasteChain so it serializes
            // with any in-flight prior dictation's paste — we don't want two
            // pastes racing the clipboard. The swap task is fired LATER after
            // polish completes.
            //
            // `optimisticPasteSnapshot` is the SHA-like fingerprint we use to
            // verify the field hasn't changed before we attempt Cmd+Z + repaste.
            // (Plain string equality on the pasteboard contents is good enough
            // — if anything else clobbered our paste, we abort the swap.)
            let optimisticActive = optimisticPasteEnabled && polishWillRun && autoPaste
            var optimisticPasteboardSig: String? = nil
            // BUGFIX: hold our own optimistic-paste task locally. The Qwen3
            // polish below has an `await` and during that await another
            // finishRecording can overwrite `pasteChain`. If we read
            // `pasteChain` after the await, we may pick up a NEWER session's
            // chain link and lose serialization with our own optimistic write.
            // Capturing it here keeps the swap correctly ordered behind our
            // own pre-polish paste.
            var ourOptimisticTask: Task<Void, Never>? = nil
            if optimisticActive {
                // BUGFIX (Category 4): chain off the anchor reserved at Parakeet-return,
                // not pasteChain-now. Otherwise a faster recording B could overwrite
                // pasteChain between Parakeet and here, and our optimistic paste would
                // skip past it. The anchor preserves enqueue (chronological) order.
                let priorChain = pasteOrderAnchor
                let snapshotTarget = capturedTargetForTask
                let optimisticText = formatted
                let optimisticPolishOwnedFormatting = false  // pre-polish — paster runs its rule-based adjuster
                let optimisticTask: Task<Void, Never> = Task { @MainActor in
                    _ = await priorChain.value
                    print("[VOICE] OPTIMISTIC paste START (\(optimisticText.prefix(60))…)")
                    if let id = snapshotTarget,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                       !app.isActive {
                        app.activate()
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(optimisticText, forType: .string)
                    self.cursorPaster.pasteAtCursor(
                        optimisticText,
                        restoreClipboard: false,
                        preFormatted: optimisticPolishOwnedFormatting
                    )
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    print("[VOICE] OPTIMISTIC paste DONE")
                }
                pasteChain = optimisticTask
                ourOptimisticTask = optimisticTask
                // Snapshot the pasteboard once the optimistic write has landed,
                // so the post-polish swap can detect "user typed over our paste".
                optimisticPasteboardSig = optimisticText
            }
            // var (not let) — see the empty-polish guard below that may
            // fall back to `formatted` if Qwen3 returns whitespace/empty.
            var finalText: String
            if CleanupLevel.current == .none || !polishEnabledByUser {
                print("[VOICE] Polish skipped (cleanupLevel=none or polishEnabled=false) — rule-based only")
                finalText = formatted
            } else if skipPolish {
                print("[VOICE] Short clip — skipping LLM polish (rule-based only)")
                finalText = formatted
            } else if graniteTranscript != nil || moonshineTranscript != nil {
                // Triple-model path: Qwen3 merges Parakeet v2 + Granite 4.0 + Moonshine Tiny outputs.
                let graniteLabel = graniteTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                let moonshineLabel = moonshineTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                print("[VOICE] Triple-model merge: parakeet='\(formatted.prefix(40))' granite=\(graniteLabel) moonshine=\(moonshineLabel)")
                finalText = await Qwen3Polisher.shared.merge(
                    parakeet: formatted,
                    granite: graniteTranscript,
                    moonshine: moonshineTranscript,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab,
                    fieldContext: capturedFieldContextForTask,
                    cleanupLevel: CleanupLevel.current.rawValue,
                    personalityStyle: PersonalityStyle.current.rawValue
                )
                // Triple-ASR capture for the Polish Replay debug panel. Pure
                // observer — runs AFTER the merge has produced `finalText`,
                // never blocks the paste path, persists best-effort. We
                // intentionally take the post-formatter Parakeet text here
                // (matches what the merge actually saw); raw segments-joined
                // text is logged elsewhere via [VOICE-FUNNEL] STAGE 1.
                let parakeetConfs = segments.compactMap { $0.confidence }
                let parakeetAvgConf: Float? = parakeetConfs.isEmpty
                    ? nil
                    : parakeetConfs.reduce(0, +) / Float(parakeetConfs.count)
                let capture = TripleASRCapture(
                    parakeet: formatted,
                    granite: graniteTranscript,
                    moonshine: moonshineTranscript,
                    merged: finalText,
                    polished: finalText,
                    parakeetConfidence: parakeetAvgConf,
                    graniteConfidence: nil,
                    moonshineConfidence: nil,
                    source: "live dictation"
                )
                Task.detached(priority: .utility) {
                    TripleASRStore.save(capture)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .tripleASRCaptured, object: nil)
                    }
                }
            } else {
                finalText = await Qwen3Polisher.shared.polish(
                    formatted,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab,
                    fieldContext: capturedFieldContextForTask,
                    cleanupLevel: CleanupLevel.current.rawValue,
                    personalityStyle: PersonalityStyle.current.rawValue
                )
            }
            let polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
            fputs("[LATENCY] Qwen3 polish: \(polishMs)ms (enabled=\(polishEnabledByUser), skipShort=\(skipPolish))\n", stderr)
            // BUGFIX: guard against polish returning empty/whitespace. If
            // Qwen3 ever returns "" we'd paste nothing at the cursor while
            // the user thinks their dictation succeeded. Fall back to the
            // pre-polish formatted text — same data the optimistic-paste
            // path would have written.
            if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               && !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[VOICE] WARNING: polish returned empty — falling back to formatted text")
                Telemetry.log("polish.empty_output", properties: [
                    "input_chars": formatted.count
                ])
                finalText = formatted
            }
            let polishChanged = finalText != formatted
            // Classify the polish outcome from the call-site's perspective.
            // The Polisher itself logs the granular reason ("rejected: word
            // drift", "TIMEOUT", "skipped: disabled", etc.); we tag the
            // observable outcome here so telemetry has a single source of truth.
            let polishOutcome: String
            if !Qwen3Polisher.isEnabled {
                polishOutcome = "disabled"
            } else if !polishChanged {
                // Either no-op (input clean) or rejected/timed-out — both
                // surface as "input unchanged". The Polisher log line above
                // disambiguates for humans; for telemetry "unchanged" is fine.
                polishOutcome = "unchanged"
            } else {
                polishOutcome = "succeeded"
            }
            print("[VOICE-FUNNEL] STAGE 3 POLISH out=\"\(finalText)\" chars=\(finalText.count) outcome=\(polishOutcome) elapsedMs=\(polishMs) context=\(polishContext.rawValue) suspects=\(suspectWords.count) vocab=\(userVocab.count)")
            Telemetry.log("polish.\(polishOutcome)", properties: [
                "elapsed_ms": polishMs,
                "input_chars": formatted.count,
                "output_chars": finalText.count,
                "context": polishContext.rawValue,
                "suspect_count": suspectWords.count,
                "vocab_count": userVocab.count
            ])

            // Calculate statistics
            let wordCount = finalText.split(separator: " ").count
            let durationSeconds = Int(duration)
            let wpm = durationSeconds > 0 ? (wordCount * 60) / durationSeconds : 0
            recordingState.lastDictationWordCount = wordCount
            recordingState.lastDictationDurationSeconds = durationSeconds
            recordingState.lastDictationWPM = wpm
            recordingState.recordDictation(words: wordCount, durationSeconds: durationSeconds)

            print("[VOICE] About to handle copy/paste... autoCopy=\(autoCopy), autoPaste=\(autoPaste)")

            // Hand the clipboard + paste step off to the serial pasteChain.
            // Doing it inline would let two completed pipelines race the
            // clipboard and synthesized-keystroke state — instead each finish
            // task awaits the prior chain link, then takes its turn. No
            // staleness gate: older transcripts MUST reach the cursor even
            // if the user already started a new recording. Order = arrival
            // order (older finishes first → pastes first).
            let polishOwnedFormatting = !skipPolish && polishChanged && capturedFieldContextForTask != nil
            // BUGFIX (Category 4): if we ran optimistic paste, chain off THAT task
            // (most-recent pasteChain) so our final paste serializes after our own
            // optimistic write. Otherwise chain off the parakeet-return anchor so
            // paste order = finish-call order, not polish-completion order.
            // BUGFIX: reading `pasteChain` here was racy — during the polish
            // await another session can mutate it. Use the local snapshot of
            // our own optimistic task instead so we always serialize behind
            // our own pre-polish write.
            let prior: Task<Void, Never>? = optimisticActive
                ? (ourOptimisticTask ?? pasteOrderAnchor)
                : pasteOrderAnchor
            print("[VOICE-TIMING] polish returned at \(Date()) chars=\(finalText.count)")
            // OPTIMISTIC SWAP PATH: optimistic paste already wrote `formatted`
            // to the field above. If polish completed and produced something
            // genuinely different, attempt a Cmd+Z then paste the polished
            // version. Bail out and leave the unpolished text in place when:
            //   - polish didn't change anything (no swap needed)
            //   - polish was disabled / short / non-English (finalText==formatted)
            //   - the system pasteboard contents differ from what we wrote
            //     (something else clobbered it — could be the user typing
            //     manually, another paste source, etc.)
            //
            // The Cmd+Z + repaste is best-effort: if Cmd+Z can't undo (the
            // app doesn't support it) the user ends up with both versions
            // visible, which is a less bad outcome than losing their text.
            let optimisticSwapNeeded = optimisticActive && polishChanged
            let optimisticSig = optimisticPasteboardSig
            pasteChain = Task { @MainActor in
                _ = await prior?.value
                let tPasteStart = CFAbsoluteTimeGetCurrent()
                if optimisticSwapNeeded, let sig = optimisticSig {
                    // SWAP PATH — optimistic paste already ran, try to replace.
                    let pb = NSPasteboard.general
                    let currentClipboard = pb.string(forType: .string) ?? ""
                    if currentClipboard != sig {
                        print("[VOICE] OPTIMISTIC swap SKIPPED — clipboard changed since paste (current!=sig)")
                        if autoCopy {
                            pb.clearContents()
                            pb.setString(finalText, forType: .string)
                        }
                    } else {
                        print("[VOICE] OPTIMISTIC swap: Cmd+Z then repaste polished (\(finalText.prefix(60))…)")
                        if let id = capturedTargetForTask,
                           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                           !app.isActive {
                            app.activate()
                        }
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        self.cursorPaster.undoLastPaste()
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        if autoCopy {
                            pb.clearContents()
                            pb.setString(finalText, forType: .string)
                        }
                        self.cursorPaster.pasteAtCursor(
                            finalText,
                            restoreClipboard: !autoCopy,
                            preFormatted: polishOwnedFormatting
                        )
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                    Qwen3Polisher.shared.updateRollingContext(finalText)
                    let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                    let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                    fputs("[LATENCY] Paste (optimistic-swap branch): \(Int(pasteMs))ms\n", stderr)
                    fputs("[LATENCY] TOTAL pipeline (optimistic): \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                    Telemetry.log("latency.pipeline", properties: [
                        "total_ms": Int(totalMs),
                        "parakeet_ms": Int(parakeetMs),
                        "formatter_ms": Int(formatterMs),
                        "polish_ms": polishMs,
                        "paste_ms": Int(pasteMs),
                        "polish_enabled": polishEnabledByUser,
                        "polish_skipped_short": skipPolish,
                        "input_chars": formatted.count,
                        "output_chars": finalText.count,
                        "optimistic_paste": true
                    ])
                    return
                }
                if optimisticActive && !optimisticSwapNeeded {
                    // Optimistic paste already landed the right text — nothing to do.
                    print("[VOICE] OPTIMISTIC paste was sufficient — polish unchanged")
                    if autoCopy {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(finalText, forType: .string)
                    }
                    Qwen3Polisher.shared.updateRollingContext(finalText)
                    let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                    let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                    fputs("[LATENCY] Paste (optimistic-noop branch): \(Int(pasteMs))ms\n", stderr)
                    fputs("[LATENCY] TOTAL pipeline (optimistic-noop): \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                    Telemetry.log("latency.pipeline", properties: [
                        "total_ms": Int(totalMs),
                        "parakeet_ms": Int(parakeetMs),
                        "formatter_ms": Int(formatterMs),
                        "polish_ms": polishMs,
                        "paste_ms": Int(pasteMs),
                        "polish_enabled": polishEnabledByUser,
                        "polish_skipped_short": skipPolish,
                        "input_chars": formatted.count,
                        "output_chars": finalText.count,
                        "optimistic_paste": true,
                        "optimistic_noop": true
                    ])
                    return
                }
                if autoCopy {
                    print("[VOICE] Copying to clipboard...")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(finalText, forType: .string)
                    print("[VOICE] Copied to clipboard successfully")
                }
                if autoPaste {
                    print("[VOICE] Auto-pasting (\(finalText.prefix(60))…)")
                    print("[VOICE] capturedTargetForTask=\(capturedTargetForTask ?? "nil")")
                    // Re-activate the SNAPSHOT target app (not the live
                    // instance var) so a newer recording that re-pointed
                    // targetAppBundleID elsewhere can't steal this older
                    // transcript's destination.
                    if let id = capturedTargetForTask,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                       !app.isActive {
                        print("[VOICE] Activating snapshot target app: \(id)")
                        app.activate()
                    }
                    print("[VOICE] Target app restored, settling for 80ms...")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    print("[VOICE] Calling pasteAtCursor...")
                    print("[VOICE-TIMING] paste fired at \(Date()) chars=\(finalText.count)")
                    print("[VOICE-FUNNEL] STAGE 4 PASTE text=\"\(finalText)\" chars=\(finalText.count) target=\(capturedTargetForTask ?? "nil")")
                    // preFormatted=true when polish ran with the field-context hint:
                    // the LLM already chose the right leading space / casing / list
                    // numbering relative to existing text. Pasting verbatim avoids
                    // the legacy rule-based adjuster from re-mangling the output.
                    cursorPaster.pasteAtCursor(
                        finalText,
                        restoreClipboard: !autoCopy,
                        preFormatted: polishOwnedFormatting
                    )
                    print("[VOICE] pasteAtCursor completed preFormatted=\(polishOwnedFormatting)")
                    // Update rolling context so next dictation can resolve
                    // ambiguous words using what was just said.
                    Qwen3Polisher.shared.updateRollingContext(finalText)
                    // Tiny inter-paste settle so the next chained paste's
                    // synthesized keystrokes can't collide with this one's tail.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                } else {
                    print("[VOICE] Auto-paste disabled — transcript copied to clipboard only")
                }
                let pasteMs = (CFAbsoluteTimeGetCurrent() - tPasteStart) * 1000
                let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
                fputs("[LATENCY] Paste (incl. queue + settle): \(Int(pasteMs))ms\n", stderr)
                fputs("[LATENCY] TOTAL pipeline: \(Int(totalMs))ms (parakeet=\(Int(parakeetMs)) formatter=\(Int(formatterMs)) polish=\(polishMs) paste=\(Int(pasteMs)))\n", stderr)
                Telemetry.log("latency.pipeline", properties: [
                    "total_ms": Int(totalMs),
                    "parakeet_ms": Int(parakeetMs),
                    "formatter_ms": Int(formatterMs),
                    "polish_ms": polishMs,
                    "paste_ms": Int(pasteMs),
                    "polish_enabled": polishEnabledByUser,
                    "polish_skipped_short": skipPolish,
                    "input_chars": formatted.count,
                    "output_chars": finalText.count
                ])
            }

            // Record for the Recent Dictations submenu. We persist BOTH the
            // pre-polish formatted text and the final polished text so the
            // BigMenu's History view can show a before/after compare. When
            // polish was a no-op (disabled / unavailable / didn't change
            // anything) the storage helper drops `raw` to avoid duplication.
            // Count how many spoken voice-commands the formatter turned into
            // actual punctuation/formatting. Heuristic: count standalone-word
            // matches in the raw Parakeet text. Conservative — keeps it cheap
            // and predictable. Drives the "fixes made by voice" stats card.
            let commandCount = countVoiceCommands(in: rawText)
            // Diff the pre-polish formatted text against the polished output to
            // count real fix-events (spelling, capitalization, grammar, filler
            // removal). Zero when polish was a no-op / disabled / skipped.
            // Drives the BigMenu "fixes by voice" stat card.
            let fixCount: Int? = {
                let trimmedPol = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedRaw = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPol.isEmpty, !trimmedRaw.isEmpty,
                      trimmedPol.lowercased() != trimmedRaw.lowercased() else { return 0 }
                return RecentDictations.countFixes(raw: trimmedRaw, polished: trimmedPol)
            }()
            RecentDictations.add(raw: formatted, polished: finalText,
                                  pasteTargetBundleID: capturedTargetForTask,
                                  polishMs: polishChanged ? polishMs : nil,
                                  granite: graniteTranscript,
                                  moonshine: moonshineTranscript,
                                  parakeetRaw: rawText,
                                  suspects: suspectWords.isEmpty ? nil : suspectWords,
                                  durationSeconds: durationSeconds,
                                  voiceCommandCount: commandCount,
                                  cleanupLevelUsed: CleanupLevel.current.displayName,
                                  personalityStyleUsed: PersonalityStyle.current.displayName,
                                  polishFixCount: fixCount,
                                  polishEngine: PolishStatus.shared.lastEngine)

            // Auto-learn proper nouns from the polished text. Looks at the
            // user's last 50 dictations and promotes capitalized terms that
            // appear ≥2 times into the proper-noun vocabulary — so the next
            // polish pass treats them as fixed brand/contact names instead
            // of "correcting" their spelling.
            let priorDictations = RecentDictations.all().prefix(50).map(\.text)
            ProperNounVocabulary.learnFrom(finalText, previousDictations: Array(priorDictations))
            Telemetry.log("dictation.completed", properties: [
                "chars": formatted.count,
                "duration_s": durationSeconds,
                "words": wordCount,
                "wpm": wpm
            ])
        }
    }

    /// Show "Transcript cancelled" toast with Undo button. Auto-dismiss in 4s.
    /// NOTE: The transcript is preserved indefinitely so late Undo clicks still work.
    private func showCancelledToast() {
        recordingState.cancelledTranscript = recordingState.currentTranscript
        recordingState.currentTranscript = []
        recordingState.showingCancelledToast = true
        recordingState.cancelToastShownAt = Date()

        cancelDismissTask?.cancel()
        cancelDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                // Only dismiss the UI, don't clear the transcript yet.
                // User may click Undo after timeout and it should still work.
                recordingState.showingCancelledToast = false
            }
        }
    }

    private func dismissCancelledToast() {
        cancelDismissTask?.cancel()
        recordingState.showingCancelledToast = false
        // Clear the transcript only when explicitly dismissed (Undo clicked or app action).
        recordingState.cancelledTranscript = []
    }

    /// Undo button on the cancelled toast — paste the discarded transcript.
    /// This works even if the UI toast has auto-dismissed, as long as the user
    /// hasn't recorded a new session.
    private func undoCancel() {
        let segments = recordingState.cancelledTranscript
        dismissCancelledToast()

        let fullText = segments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullText.isEmpty else {
            print("[VOICE] Undo → cancelled transcript empty, nothing to paste")
            return
        }
        print("[VOICE] Undo → pasting recovered: \(fullText.prefix(50))…")
        cursorPaster.pasteFormatted(fullText, formatter: textFormatter)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyService.delegate = self
        hotkeyService.startMonitoring()
    }

    // MARK: - Model readiness gate

    /// Returns true iff BOTH Parakeet ASR and Qwen3 polish are loaded.
    /// If either is still loading/downloading, surfaces a one-shot toast with
    /// the current progress and returns false. Throttled to one toast per 2s.
    private func checkModelsReadyOrToast() -> Bool {
        let parakeetReady: Bool
        switch coordinator.state.modelState {
        case .ready: parakeetReady = true
        default:     parakeetReady = false
        }

        let qwenReady = Qwen3Polisher.shared.availabilityStatus.isReady

        if parakeetReady && qwenReady { return true }

        // Throttle toasts.
        let now = Date()
        if let last = lastModelReadyToastAt, now.timeIntervalSince(last) < 2.0 {
            return false
        }
        lastModelReadyToastAt = now

        var parts: [String] = []
        if !parakeetReady {
            switch coordinator.state.modelState {
            case .downloading(let p): parts.append("ASR \(Int(p * 100))%")
            case .loading:            parts.append("ASR loading")
            case .notDownloaded:      parts.append("ASR pending")
            case .error(let e):       parts.append("ASR error: \(e)")
            case .ready:              break
            }
        }
        if !qwenReady {
            switch Qwen3Polisher.shared.availabilityStatus {
            case .downloading(let p): parts.append("Polish \(Int(p * 100))%")
            case .loading:            parts.append("Polish loading")
            case .notDownloaded:      parts.append("Polish pending")
            case .error(let e):       parts.append("Polish error: \(e)")
            case .available:          break
            }
        }
        let msg = "Models still loading: " + parts.joined(separator: " · ")
        showToast(msg)
        return false
    }

}

// MARK: - HotkeyServiceDelegate
//
// HotkeyService dispatches delegate callbacks SYNCHRONOUSLY on the main
// actor. By the time the state machine's transition() returns, all
// side-effects we make here (flipping recordingState.isRecording,
// kicking off startRecording, etc.) are committed. Any next event the
// monitor processes sees the new world. This is the critical fix from
// prior attempts where async dispatch let keyUp run before keyDown's
// recording had actually started — `wasRecording` then read false and
// the press silently transcribed nothing.
//
// We use `hotkeyService.pressDownAt` (captured on the NSEvent thread at
// the exact keyDown instant) instead of recording our own Date() inside
// activate(). Dispatch latency never makes a real hold look short.

extension AppDelegate: HotkeyServiceDelegate {

    /// Called on a fresh keyDown OR a third-tap (lock-exit) keyDown. Must
    /// complete start-side work synchronously: when this returns, if a new
    /// recording is intended, recordingState.isRecording must already be true.
    func hotkeyDidActivate() {
        print("[VOICE-HK] >>> hotkeyDidActivate ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)  isTranscribing=\(recordingState.isTranscribing)")
        defer { print("[VOICE-HK] <<< hotkeyDidActivate EXIT  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)") }

        // === Permission gates ===
        // Permissions are checked here AND throttled: we never show the
        // system prompt more than once per app launch (it pops a fresh
        // dialog every call), and we deep-link to the right Privacy pane on
        // the first miss so the user can resolve it without hunting.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()

        if !micOk || !axOk {
            print("[VOICE-HK] hotkeyDidActivate: permission gate FAILED micOk=\(micOk) axOk=\(axOk)")
            handleMissingPermissions(micOk: micOk, axOk: axOk, micStatus: micStatus)
            return
        }

        // === Model readiness gate ===
        // Block recording until BOTH Parakeet ASR and Qwen3 polish are loaded.
        // Throttled toast informs the user of current progress.
        guard checkModelsReadyOrToast() else { return }

        // === Path 1: third tap exits lock + transcribes ===
        if recordingState.isLocked {
            print("[VOICE-HK] Path 1: Hotkey in lock → commit")
            exitLockMode()
            finishRecording()
            return
        }

        // [VOICE-TIMING] hotkey press received at the gate-passed boundary
        print("[VOICE-TIMING] hotkey press received at \(Date())")
        // === Path 2: re-press while transcribing — start fresh alongside ===
        // The prior finishRecording() task keeps running to completion: its
        // transcript will still polish and paste at the cursor via pasteChain.
        // We just need to start a NEW recording immediately so PTT stays
        // responsive. The prior pipeline already snapshotted its own target
        // app + field context inside its Task, so re-pointing those instance
        // vars below is safe. The prior task also locally captured its audio
        // URL (see RecordingCoordinator.stopRecording ~line 167) before any
        // await, so a new startRecording() can safely overwrite
        // currentAudioFileURL without corrupting the prior pipeline.
        if recordingState.isTranscribing {
            // BUGFIX: set pendingRecordingStart=true FIRST as a single mutation so SwiftUI
            // commits a render BEFORE any other work runs. Previously this was set true
            // and then immediately cleared after startRecording() returned, which meant
            // observers never saw the .recording phase originate from the pending flag.
            recordingState.pendingRecordingStart = true
            print("[VOICE-TIMING] pendingRecordingStart=true (Path 2) at \(Date())")
            print("[VOICE-HK] Path 2: Hotkey during transcribing → start NEW alongside in-flight prior (prior will still paste)")
            // Do NOT cancel pendingFinishTask. Do NOT clear isTranscribing or
            // currentTranscript — that prior task owns those until it returns.
            // isTranscribing will flip false in its `defer` block, and our
            // own finishRecording() will set it true again when the user
            // releases this new press. Brief overlap is fine — the pill UI
            // prioritizes isRecording over isTranscribing during overlap.
            if recordingState.showingCancelledToast { dismissCancelledToast() }
            recordingState.cancelledTranscript = []
            recordingStartedAt = hotkeyService.pressDownAt ?? Date()
            // Rotate the session ID — a fresh UUID identifies this brand-new
            // recording. Any prior finishRecording Task still in flight (from
            // the press that produced the current transcribing state) captured
            // the OLD sessionID at entry and will bail out the moment it
            // notices the mismatch, preventing it from clobbering this one.
            recordingState.recordingSessionID = UUID()
            // Start recording — synchronously flips isRecording=true. pendingRecordingStart
            // will be cleared by finishRecording() when the user releases (not here);
            // the OR in pillPhase keeps the pill in .recording across that handover.
            coordinator.startRecording()
            print("[VOICE-TIMING] startRecording() returned (Path 2) at \(Date())")
            SoundEffects.playStart()
            captureTargetApp()
            print("[VOICE-HK] Path 2: post-startRecording isRecording=\(recordingState.isRecording)")
            return
        }

        // === Path 3: normal fresh press ===
        // BUGFIX: set pendingRecordingStart=true FIRST (single mutation, before any other
        // work) so SwiftUI renders the .recording pill on the very next frame. Previously
        // this was set true and immediately cleared on the same sync block; observers
        // had no chance to render the pending state. Cleared by finishRecording() at
        // release time, with pillPhase's OR covering the handover via isRecording.
        recordingState.pendingRecordingStart = true
        print("[VOICE-TIMING] pendingRecordingStart=true (Path 3) at \(Date())")
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Path 3: Hotkey down → start recording (fresh)")
        recordingStartedAt = hotkeyService.pressDownAt ?? Date()
        recordingState.cancelledTranscript = []
        // Rotate the session ID for the fresh recording (see Path 2 for rationale).
        recordingState.recordingSessionID = UUID()
        // coordinator.startRecording() synchronously flips state.isRecording=true.
        coordinator.startRecording()
        print("[VOICE-TIMING] startRecording() returned (Path 3) at \(Date())")
        SoundEffects.playStart()
        captureTargetApp()
        // coordinator.startRecording() synchronously flips state.isRecording = true.
        print("[VOICE-HK] Path 3: post-startRecording isRecording=\(recordingState.isRecording) (MUST be true)")
        if !recordingState.isRecording {
            print("[VOICE-HK] !!! CRITICAL: startRecording did NOT set isRecording=true. Next keyUp will fail.")
        }
    }

    /// Called ONLY when held duration was ≥ short-tap threshold (state
    /// machine gates this). No need for an additional duration check.
    /// Always commit.
    func hotkeyDidDeactivate() {
        // Unconditional clear FIRST — covers the case where the user releases
        // during audio-engine spin-up. If we wait for any other state check
        // and bail out, the pending flag stays true forever and the pill
        // latches in .recording (see 5.1 "stays on after release").
        recordingState.pendingRecordingStart = false
        recordingState.pendingRecordingStartAt = nil
        print("[VOICE-HK] >>> hotkeyDidDeactivate ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)  isTranscribing=\(recordingState.isTranscribing)")
        defer { print("[VOICE-HK] <<< hotkeyDidDeactivate EXIT") }
        // Defensive: state machine never fires this from .locked, but a
        // future change could regress and start firing it; finishing here
        // would commit a still-running locked recording. Keep the guard.
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidDeactivate: locked, bailing")
            return
        }
        print("[VOICE-HK] Hotkey released (hold >= threshold) → PTT commit, calling finishRecording")
        print("[VOICE-TIMING] hotkey release received at \(Date())")
        finishRecording()
    }

    /// Double-tap window expired without a second tap. The recording that
    /// started on the first keyDown has been running this whole time —
    /// discard it silently.
    func hotkeyDidQuickRelease() {
        // Unconditional clear FIRST — same rationale as hotkeyDidDeactivate.
        // Any early-return path below would otherwise leave the pending flag
        // stuck true and the pill latched in .recording.
        recordingState.pendingRecordingStart = false
        recordingState.pendingRecordingStartAt = nil
        print("[VOICE-HK] >>> hotkeyDidQuickRelease ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)")
        defer { print("[VOICE-HK] <<< hotkeyDidQuickRelease EXIT") }
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidQuickRelease: locked, bailing")
            return
        }
        guard recordingState.isRecording else {
            print("[VOICE-HK] hotkeyDidQuickRelease: NOT recording, bailing (state desync?)")
            return
        }
        print("[VOICE-HK] Quick tap → discard silently")
        recordingStartedAt = nil
        // (pendingRecordingStart was already cleared unconditionally at the
        // top of this handler — see the 5.1 fix.)
        // BUGFIX (Category 8): claim + explicitly delete the tiny audio file so
        // quick taps don't accumulate orphan .caf files on disk.
        let claimedForQuick = coordinator.claimRecordingSync()
        let urlToDeleteQuick = claimedForQuick?.audioURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.coordinator.stopRecording(claiming: claimedForQuick)
            if let url = urlToDeleteQuick {
                try? FileManager.default.removeItem(at: url)
            }
            self.recordingState.currentTranscript = []
        }
    }

    /// Second keyDown landed within the double-tap window — enter lock.
    /// The recording from the first tap is still running; lock mode picks it
    /// up seamlessly (no restart, no duplicate start sound).
    func hotkeyDidDoubleTap() {
        print("[VOICE-HK] >>> hotkeyDidDoubleTap ENTER  thread=\(Thread.isMainThread ? "main" : "BG")  isRecording=\(recordingState.isRecording)  isLocked=\(recordingState.isLocked)")
        defer { print("[VOICE-HK] <<< hotkeyDidDoubleTap EXIT  isLocked=\(recordingState.isLocked)") }
        if recordingState.isLocked {
            print("[VOICE-HK] hotkeyDidDoubleTap: already locked, bailing")
            return
        }
        guard coordinator.transcription.isReady else {
            print("[VOICE-HK] hotkeyDidDoubleTap: model not ready, bailing")
            showToast("Model loading, please wait…")
            return
        }
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Double-tap → enter lock mode")
        enterLockMode()
    }
}

// MARK: - RecordingState

@Observable
class RecordingState {
    var isRecording = false
    var isPaused = false
    var isLocked = false                  // lock mode (X/✓ buttons or double-tap hotkey)
    /// Number of finish tasks currently in the transcribe/polish phase.
    /// isTranscribing is true when this is > 0.
    var transcribingCount: Int = 0
    var isTranscribing: Bool { transcribingCount > 0 }
    var showingCancelledToast = false     // "Transcript cancelled" with Undo
    var cancelToastShownAt: Date?
    var cancelledTranscript: [TranscriptSegment] = []
    /// Set true by hotkeyDidActivate BEFORE startRecording() is called — lets the
    /// pill react on the very next frame (zero-latency visual feedback).
    /// Always paired with `pendingRecordingStartAt` so a safety timer in
    /// AppDelegate can detect a stuck flag (audio engine failed to start or
    /// user released during spin-up) and force-clear after >2s.
    var pendingRecordingStart: Bool = false {
        didSet {
            if pendingRecordingStart {
                pendingRecordingStartAt = Date()
            } else {
                pendingRecordingStartAt = nil
            }
        }
    }
    /// Timestamp paired with `pendingRecordingStart`. Set automatically when
    /// `pendingRecordingStart` flips true; cleared when it flips false. The
    /// AppDelegate safety timer reads this to detect a stuck pending flag.
    var pendingRecordingStartAt: Date? = nil
    /// Identifies the currently-active recording session. Rotated to a fresh
    /// UUID every time a new recording begins (in hotkeyDidActivate just
    /// before `coordinator.startRecording()`). The `finishRecording` Task
    /// captures this at entry and bails if it changes mid-flight — preventing
    /// a stale finish from a previous session from clobbering a new recording
    /// (e.g., re-pressing the hotkey while the prior pipeline is still draining).
    var recordingSessionID: UUID = UUID()
    /// True while an Opt+1 "polish selected text" operation is in flight.
    var isPolishingSelection: Bool = false
    var elapsedSeconds: Int = 0
    var currentTranscript: [TranscriptSegment] = []
    var audioLevels: [Float] = Array(repeating: 0, count: 32)
    /// Perceptual 0..1 input level. Drives the pill's always-on "I hear you"
    /// breathing so the user gets feedback even when speaking quietly.
    var inputLevel: Float = 0
    /// True after >2s of effectively-zero input during a recording. Surfaces
    /// a one-shot "no input detected" hint on the pill.
    var noInputDetected: Bool = false
    var modelState: ModelState = .notDownloaded

    // Statistics — last dictation
    var lastDictationWordCount: Int = 0
    var lastDictationDurationSeconds: Int = 0
    var lastDictationWPM: Int = 0  // words per minute

    // Statistics — today's session totals (in-memory, date-bucketed)
    // Resets to zero when the calendar day changes (checked on each record).
    var sessionDate: Date = Calendar.current.startOfDay(for: Date())
    var sessionDictationCount: Int = 0
    var sessionTotalWords: Int = 0
    var sessionTotalDurationSeconds: Int = 0
    var sessionAvgWPM: Int {
        guard sessionTotalDurationSeconds > 0 else { return 0 }
        return (sessionTotalWords * 60) / sessionTotalDurationSeconds
    }

    // Statistics — lifetime totals (persisted in UserDefaults)
    // Loaded once at init; incremented on every finishRecording.
    var lifetimeDictations: Int = UserDefaults.standard.integer(forKey: "voice.totalDictations")
    var lifetimeWords: Int = UserDefaults.standard.integer(forKey: "voice.totalWords")
    var lifetimeDurationSeconds: Int = UserDefaults.standard.integer(forKey: "voice.totalDurationSeconds")
    var lifetimeAvgWPM: Int {
        guard lifetimeDurationSeconds > 0 else { return 0 }
        return (lifetimeWords * 60) / lifetimeDurationSeconds
    }

    // Statistics — long-form "meeting" recordings (>= 30s).
    // Subset of the dictation counters above; tracked separately so the
    // Meetings tab can surface a clean view of long-form work.
    static let meetingMinDurationSeconds: Int = 30
    var sessionMeetingCount: Int = 0
    var sessionMeetingTotalDurationSeconds: Int = 0
    var lifetimeMeetingCount: Int = UserDefaults.standard.integer(forKey: "voice.totalMeetings")
    var lifetimeMeetingDurationSeconds: Int = UserDefaults.standard.integer(forKey: "voice.totalMeetingDurationSeconds")
    var lifetimeAvgMeetingDurationSeconds: Int {
        guard lifetimeMeetingCount > 0 else { return 0 }
        return lifetimeMeetingDurationSeconds / lifetimeMeetingCount
    }

    // Live partial transcript for lock-mode preview.
    // Populated by RecordingCoordinator.startLivePartials() during lock mode.
    // Cleared when the final transcript lands or recording is cancelled.
    // The UI shows confirmed text at full opacity; volatile text at 55% opacity.
    var livePartialText: String = ""
    var livePartialIsVolatile: Bool = true

    /// Set by RecordingCoordinator when the captured audio is short (16-36KB
    /// range). Consumed by finishRecording's polish stage to skip the LLM
    /// pass for one-word utterances like "ok"/"yeah"/"no" that polish tends
    /// to mangle. Auto-clears after consumption.
    var skipPolishForCurrent: Bool = false

    /// Raw transcript from IBM Granite 4.0 1B (second ASR model, runs in parallel
    /// with Parakeet v2). When non-nil, the polish stage calls Qwen3.merge()
    /// instead of Qwen3.polish() — giving the LLM both transcripts to pick the
    /// best reading from each. Nil when Granite is unavailable or timed out.
    /// Auto-clears after consumption.
    var graniteTranscript: String? = nil

    /// Raw transcript from Moonshine Tiny (third ASR model, runs in parallel
    /// with Parakeet v2 and Granite). Passed to Qwen3.merge() alongside the
    /// other transcripts when non-nil. Nil when Moonshine is unavailable or
    /// timed out. Auto-clears after consumption.
    var moonshineTranscript: String? = nil

    // Tick to nudge SwiftUI redraws when persisted recent-dictations list changes.
    var recentDictationsTick: Int = 0

    /// Single source of truth for the pill UI state. Always reflects the most
    /// important active state — no impossible combinations.
    var pillPhase: PillPhase {
        if pendingRecordingStart || (isRecording && !isLocked) { return .recording }
        if isRecording && isLocked { return .locked }
        if !isRecording && isLocked { return .locked }
        if isPolishingSelection { return .polishingSelection }
        if isTranscribing { return .transcribing }
        if showingCancelledToast { return .cancelled }
        return .idle
    }

    /// Record one dictation: bump session counters (with day-rollover reset)
    /// AND lifetime UserDefaults counters. Called from finishRecording().
    func recordDictation(words: Int, durationSeconds: Int) {
        // Day rollover — if it's a new day, reset session totals first.
        let today = Calendar.current.startOfDay(for: Date())
        if today != sessionDate {
            sessionDate = today
            sessionDictationCount = 0
            sessionTotalWords = 0
            sessionTotalDurationSeconds = 0
        }
        sessionDictationCount += 1
        sessionTotalWords += words
        sessionTotalDurationSeconds += durationSeconds

        // Lifetime — persist and mirror in-memory.
        lifetimeDictations += 1
        lifetimeWords += words
        lifetimeDurationSeconds += durationSeconds
        UserDefaults.standard.set(lifetimeDictations, forKey: "voice.totalDictations")
        UserDefaults.standard.set(lifetimeWords, forKey: "voice.totalWords")
        UserDefaults.standard.set(lifetimeDurationSeconds, forKey: "voice.totalDurationSeconds")

        // Long-form "meeting" subset — only count recordings >= 30s.
        if durationSeconds >= RecordingState.meetingMinDurationSeconds {
            sessionMeetingCount += 1
            sessionMeetingTotalDurationSeconds += durationSeconds
            lifetimeMeetingCount += 1
            lifetimeMeetingDurationSeconds += durationSeconds
            UserDefaults.standard.set(lifetimeMeetingCount, forKey: "voice.totalMeetings")
            UserDefaults.standard.set(lifetimeMeetingDurationSeconds, forKey: "voice.totalMeetingDurationSeconds")
        }

        recentDictationsTick &+= 1
    }
}
