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
import UserNotifications

// MARK: - Verbose logging gate
// `vlog` compiles to a no-op in release builds and is gated by `voiceVerbose`
// in debug. Hot-path code uses this instead of `print` to keep CPU off the
// audio + recording threads. Flip `voiceVerbose` to true when diagnosing.
@inline(__always) func vlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    if voiceVerbose { print(message()) }
    #endif
}
let voiceVerbose: Bool = false

struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Background-activity opt-out flags
    //
    // These @AppStorage flags surface user-facing toggles for every optional
    // background subsystem. Defaults favor OFF for anything non-essential so
    // a fresh install only spins up the core dictation pipeline. AppDelegate
    // reads the same UserDefaults keys directly at startup via the
    // `BackgroundActivityGate` helper (since @AppStorage only resolves inside
    // SwiftUI scope — AppDelegate is AppKit-bound).
    //
    // `privacyMode` is an emergency "all off" master switch. When true it
    // overrides every other flag and forces local-only / minimal-CPU mode.

    /// CallAppDetector polls SCShareableContent + CoreAudio every ~2s to detect
    /// Discord/Zoom/Teams/Slack/FaceTime calls. Off by default — opt-in for
    /// auto meeting capture.
    @AppStorage("voice.enableMeetingDetection") private var enableMeetingDetection: Bool = true
    /// Master kill switch for *automatic* meeting detection. When true, every
    /// auto-start path (CallAppDetector, Chrome MeetBridge, voiceAutoStartMeeting
    /// notification) is short-circuited regardless of the per-detector flags.
    /// Manual meeting capture from the UI still works. AppDelegate reads the
    /// raw key via `kDisableMeetingDetectionKey` so the gate also applies
    /// outside SwiftUI scope. Surfaced here so a settings UI can bind to it.
    @AppStorage("voice.disableMeetingDetection") private var disableMeetingDetection: Bool = false
    /// Core dictation (hotkey + transcription + paste). On by default — this
    /// is the app's primary purpose. Flipping false disables hotkey handling.
    @AppStorage("voice.enableRecording") private var enableRecording: Bool = true
    /// Emergency "all off" master toggle. When true, overrides every other
    /// background flag: wake word OFF, meeting detection OFF, cloud polish
    /// forced OFF (local-only), Aurora animation OFF (static idle pill).
    @AppStorage("voice.privacyMode") private var privacyMode: Bool = false

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Centralized gate for optional background subsystems. AppDelegate consults
/// these helpers at startup (and on UserDefaults-change notifications) to
/// decide whether to call `.start()` / `.enable()` on each service. Single
/// source of truth for "should this subsystem run right now?".
///
/// `privacyMode` is the master kill switch — when on, every helper returns
/// false regardless of the per-feature flags.
enum BackgroundActivityGate {
    static var privacyMode: Bool {
        UserDefaults.standard.bool(forKey: "voice.privacyMode")
    }

    static var wakeWordEnabled: Bool {
        if privacyMode { return false }
        // The Settings Enable toggle (`voice.wakeWordEnabled`) is the master.
        // It must be ON *and* the mode picker must be a non-"off" value.
        // Using AND (not OR) closes the "recording when it shouldn't" bug:
        // when the user turns the Enable toggle OFF, `voice.wakeWordMode` can
        // retain a stale "alwaysOn"/"activatedWindow" value (the picker is
        // merely hidden, not reset), and an OR would keep the mic tap alive.
        // The toggle's onChange also forces mode→"off" on disable as a second
        // line of defense. Privacy mode still kills everything.
        guard UserDefaults.standard.bool(forKey: "voice.wakeWordEnabled") else { return false }
        let mode = UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off"
        return mode != "off"
    }

    /// Activation strategy for the wake word listener. Reads
    /// `voice.wakeWordMode`. Defaults to "off" — a fresh install never
    /// taps the mic from the wake-word path until the user opts in.
    static var wakeWordMode: String {
        if privacyMode { return "off" }
        return UserDefaults.standard.string(forKey: "voice.wakeWordMode") ?? "off"
    }

    static var meetingDetectionEnabled: Bool {
        if privacyMode { return false }
        // Inverted kill switch — explicit OFF wins.
        if UserDefaults.standard.bool(forKey: "voice.disableMeetingDetection") { return false }
        // Default to ON if unset — meeting recording is core product behavior.
        // The defensive guards (whitelist, frontmost-app match, MeetBridge participant
        // check, sustained-presence ticks) prevent false positives.
        if UserDefaults.standard.object(forKey: "voice.enableMeetingDetection") == nil { return true }
        return UserDefaults.standard.bool(forKey: "voice.enableMeetingDetection")
    }

    static var recordingEnabled: Bool {
        if privacyMode { return false }
        // Default to true if unset — core dictation is the product.
        if UserDefaults.standard.object(forKey: "voice.enableRecording") == nil { return true }
        return UserDefaults.standard.bool(forKey: "voice.enableRecording")
    }

    /// Cloud polish (Cerebras/Groq) — forced OFF in privacy mode. Callers
    /// must also check `CerebrasPolisher.isEnabled` for the per-provider flag.
    static var cloudPolishAllowed: Bool { !privacyMode }

    /// Aurora animation on the idle pill. Off in privacy mode for visible
    /// confirmation the app is in minimal-CPU state.
    static var auroraAnimationAllowed: Bool { !privacyMode }
}

/// Top-level entry point. Branches on CLI args:
///   --polish-harness [dir]   → run the headless golden-case polish harness
///   --polish-scripts         → run the 8 Round-2 script assertion harness
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
        if args.dropFirst().first == "--polish-scripts" {
            // Round-2 manual scripts → programmatic assertion harness.
            // See PolishScriptsHarness.swift for the 8 cases. Same
            // RunLoop trick as --polish-harness above.
            Task { @MainActor in
                await PolishScriptsHarness.run()
                exit(0)
            }
            RunLoop.main.run()
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
    /// Posted by OverlayPanel's meeting-poll timer when a meeting app is newly
    /// detected (false → true). AppDelegate observes this and auto-starts capture.
    /// Auto-stop is intentionally NOT done via poll — the user taps the pill to stop
    /// so that tabbing away from Chrome mid-meeting doesn't kill the capture.
    static let voiceAutoStartMeeting = Notification.Name("voice.autoStartMeeting")
    /// Posted by the menu bar's "Stop meeting recording" item. AppDelegate
    /// observes this and calls the existing `stopMeetingCapture()` flow.
    static let voiceStopMeetingRequested = Notification.Name("voice.stopMeetingRequested")
    /// Posted by MeetingCaptureService's audio watchdog when no fresh samples
    /// have arrived for >5s while `isCapturing == true`. AppDelegate observes
    /// this and prints a toast so the user knows recording may be incomplete.
    static let voiceMeetingAudioStalled = Notification.Name("voice.meetingAudioStalled")
    /// Posted by the BigMenu meeting row when the user clicks "Transcribe now".
    /// userInfo: ["meetingId": String]. AppDelegate handles it.
    static let voiceTranscribeMeetingRequested = Notification.Name("voice.transcribeMeetingRequested")
    /// Posted back by AppDelegate when a manual re-transcribe finishes (success
    /// OR failure). userInfo: ["meetingId": String, "success": Bool, "error": String?].
    /// The row observes this to clear its "Transcribing…" state.
    static let voiceTranscribeMeetingFinished = Notification.Name("voice.transcribeMeetingFinished")
    /// Posted by the BigMenu meetings empty-state "Start meeting manually"
    /// button. AppDelegate observes this and runs the same flow as the menu
    /// bar's "Start Meeting Recording" item so there's one code path.
    static let voiceStartMeetingManual = Notification.Name("voice.startMeetingManual")
}

/// Lifecycle of the persisted-meetings fetch. The BigMenuWindow Meetings tab
/// reads this off `RecordingState` to decide between skeleton-loader, the
/// list, the empty state, and an error state with a Retry button.
enum MeetingsLoadState: Equatable {
    /// No load attempt has run yet. Visually identical to `.loading` in the UI
    /// so the very first frame doesn't flash an empty state.
    case initial
    /// A fetch is in flight. Drives the skeleton-row loader.
    case loading
    /// At least one fetch has completed successfully. `recordingState.meetings`
    /// is the source of truth for what to display — this state just lets the
    /// UI know "we tried, and it worked" so empty vs. populated is unambiguous.
    case loaded
    /// The fetch threw. The carried string is a short, human-readable reason
    /// surfaced verbatim in the error view ("Couldn't load meetings — <reason>").
    case error(String)
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
    /// True when this dictation was CANCELLED rather than committed. Cancelled
    /// dictations are retained (audio kept on disk, transcript saved) but were
    /// never pasted at the cursor and were not fully polished. Optional /
    /// defaults false for back-compat with older entries.
    var cancelled: Bool = false
    /// On-disk path to the retained .caf audio for this dictation. Populated for
    /// cancelled dictations so the user can recover / re-process the recording
    /// from History. Optional for back-compat with older entries (committed
    /// dictations don't set this — their audio is referenced via the Meeting row).
    var audioFilePath: String? = nil
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

    /// File at ~/Library/Application Support/Voice/recent_dictations.json.
    /// Mirrors the pattern used by StorageService / Telemetry.
    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        return voiceDir.appendingPathComponent("recent_dictations.json")
    }

    /// Read items from disk. On first run, migrate any legacy UserDefaults
    /// blob to the new file and delete the old key.
    static func all() -> [RecentDictation] {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([RecentDictation].self, from: data)
            } catch {
                NSLog("[VOICE-STORAGE] failed to read recent_dictations.json: \(error)")
                return []
            }
        }
        // No file yet — try migrating from UserDefaults.
        if let legacy = UserDefaults.standard.data(forKey: key),
           let items = try? JSONDecoder().decode([RecentDictation].self, from: legacy) {
            do {
                let encoded = try JSONEncoder().encode(items)
                try encoded.write(to: url, options: .atomic)
                UserDefaults.standard.removeObject(forKey: key)
                NSLog("[VOICE-STORAGE] migrated \(items.count) dictations from UserDefaults to file")
            } catch {
                NSLog("[VOICE-STORAGE] migration write failed: \(error)")
            }
            return items
        }
        return []
    }

    /// Write items to disk, silently swallowing errors after logging.
    private static func save(_ items: [RecentDictation]) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[VOICE-STORAGE] failed to write recent_dictations.json: \(error)")
        }
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
        save(items)
    }

    static func add(raw: String?, polished: String, pasteTargetBundleID: String? = nil, polishMs: Int? = nil,
                    granite: String? = nil, moonshine: String? = nil,
                    parakeetRaw: String? = nil, suspects: [String]? = nil,
                    durationSeconds: Int? = nil, voiceCommandCount: Int? = nil,
                    cleanupLevelUsed: String? = nil,
                    personalityStyleUsed: String? = nil,
                    polishFixCount: Int? = nil,
                    polishEngine: String? = nil,
                    cancelled: Bool = false,
                    audioFilePath: String? = nil) {
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
                            polishEngine: polishEngine,
                            cancelled: cancelled,
                            audioFilePath: audioFilePath),
            at: 0
        )
        if items.count > limit { items = Array(items.prefix(limit)) }
        // Trim heavyweight per-engine transcript fields off items older than
        // 7 days — they bloat the single UserDefaults JSON blob without being
        // surfaced anywhere in the UI for old entries. Keep `text` + `rawText`.
        let now = Date()
        for i in items.indices {
            if now.timeIntervalSince(items[i].timestamp) > 7 * 24 * 3600 {
                items[i].graniteText = nil
                items[i].moonshineText = nil
                items[i].parakeetRawText = nil
            }
        }
        save(items)
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
        // Same raw dictation — shows exactly what each level removes or rewrites.
        let before = "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want"
        switch self {
        case .none:
            // Zero changes — exactly what was said, mistakes and all.
            return (before, "um so like i was thinking maybe we could grab coffee tomorrow if you're free i mean only if you want")
        case .light:
            // Strips um/uh, fixes punctuation. Keeps "like" and "i mean" — those are voice.
            return (before, "So like I was thinking maybe we could grab coffee tomorrow if you're free, I mean only if you want.")
        case .medium:
            // Removes fillers, cleans sentence. Word choice preserved.
            return (before, "I was thinking we could grab coffee tomorrow if you're free.")
        case .high:
            // Full rewrite to the clearest possible form of the intent.
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
        // Same raw dictation for all four — shows exactly what each preset does to it.
        let before = "hey can u send maya a message saying we're running like really late"
        switch self {
        case .neutral:
            // Keeps the speaker's natural voice, just cleans the stumbles.
            return (before, "Hey, can you send Maya a message saying we're running really late?")
        case .formal:
            // Full expansion, professional register, no contractions.
            return (before, "Please send Maya a message informing her that we are running quite late.")
        case .casual:
            // Preserves slang, lowercase rhythm, drops filler.
            return (before, "yo send maya a msg, we're super late")
        case .excited:
            // Short punchy sentences, energy up, exclamation where it fits.
            return (before, "Send Maya a message! We're running really late!")
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

// MARK: - My Style Level
//
// Four positions on the style-fidelity spectrum. Independent of personality
// presets — these control how tightly the model follows the user's Style Card.
// Only visible once a Style Card has been extracted.

enum MyStyleLevel: String, CaseIterable, Identifiable {
    case raw      = "raw"
    case light    = "light"
    case polished = "polished"
    case best     = "best"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw:      return "Raw You"
        case .light:    return "Light You"
        case .polished: return "Polished You"
        case .best:     return "Best You"
        }
    }

    var tagline: String {
        switch self {
        case .raw:      return "Audio cleanup only"
        case .light:    return "Grammar, your voice"
        case .polished: return "Full polish, still you"
        case .best:     return "Your best writing day"
        }
    }

    /// Injected into the cloud system prompt when My Style is active.
    /// Controls how tightly the model matches the Style Card vs. elevating prose.
    var fidelityInstruction: String {
        switch self {
        case .raw:
            return "STYLE FIDELITY: exact. Preserve every quirk, rhythm, and characteristic phrase from the Style Card. Fix only audio artifacts — nothing else."
        case .light:
            return "STYLE FIDELITY: close. Smooth grammar and run-ons only. Keep the speaker's exact cadence, slang, and characteristic phrases from the Style Card."
        case .polished:
            return "STYLE FIDELITY: primary. The Style Card is your main voice guide. Full editorial cleanup allowed. Mild elevation OK where it strengthens clarity."
        case .best:
            return "STYLE FIDELITY: card-informed. Quality and precision first. The Style Card defines character and voice — let the prose be its best possible form."
        }
    }

    var example: (before: String, after: String) {
        let before = "hey so um i was thinking we should probably push that deadline back a little"
        switch self {
        case .raw:
            return (before, "hey so i was thinking we should probably push that deadline back a little")
        case .light:
            return (before, "Hey, I was thinking we should probably push that deadline back a little.")
        case .polished:
            return (before, "Hey, I think we should push that deadline back a bit.")
        case .best:
            return (before, "I think we should push the deadline back — worth flagging now.")
        }
    }

    static var current: MyStyleLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "myStyleLevel") ?? "polished"
            return MyStyleLevel(rawValue: raw) ?? .polished
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "myStyleLevel") }
    }
}

// MARK: - Polish Preset

/// Polish-in-place presets. Independent of dictation cleanup and personality.
/// Used when the user selects existing text and triggers the polish hotkey (or
/// dot-tap). Always routes through Cerebras cloud — the 235B model does the
/// prose editing work.
enum PolishPreset: String, CaseIterable, Identifiable {
    case fix     = "fix"
    case smooth  = "smooth"
    case elevate = "elevate"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fix:     return "Fix"
        case .smooth:  return "Smooth"
        case .elevate: return "Elevate"
        }
    }

    var tagline: String {
        switch self {
        case .fix:     return "Grammar and punctuation only"
        case .smooth:  return "Improve flow, keep your voice"
        case .elevate: return "Tighten and professionalize"
        }
    }

    var example: (before: String, after: String) {
        let before = "hey so i was thinking we should maybe push that meeting to thursday it would be easier"
        switch self {
        case .fix:
            return (before,
                "Hey so I was thinking we should maybe push that meeting to Thursday, it would be easier.")
        case .smooth:
            return (before,
                "I was thinking we should push the meeting to Thursday. It'd be easier.")
        case .elevate:
            return (before,
                "I'd suggest moving the meeting to Thursday. It would work better.")
        }
    }

    static var current: PolishPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: "polishPreset") ?? "smooth"
            return PolishPreset(rawValue: raw) ?? .smooth
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "polishPreset") }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayPanel: OverlayPanel?
    let recordingState = RecordingState()
    lazy var coordinator: RecordingCoordinator = RecordingCoordinator(state: recordingState)
    private lazy var meetingCaptureService: MeetingCaptureService = {
        MeetingCaptureService(transcriptionEngine: coordinator.transcription)
    }()
    // meetingSummarizer removed — meetings are stored as raw transcripts only.
    // Summarization / AI post-processing happens externally when needed.
    /// Local HTTP server on port 59423 that receives signals from the
    /// "Voice Meet Bridge" Chrome extension. Much more reliable than the
    /// AX-based window-title polling which breaks when Voice is frontmost.
    private let meetBridgeServer = MeetBridgeServer()
    /// Native-call-app detector (Discord, Zoom, Teams, Slack huddles, FaceTime,
    /// WhatsApp, Telegram). Polls SCShareableContent + CoreAudio mic-in-use
    /// every 2s and fires `onCallStateChange` with grace-debounced transitions.
    /// Complements the Chrome bridge for users who aren't on Meet/Zoom-web.
    private let callAppDetector = CallAppDetector()

    // MARK: - Meeting auto-detection master kill switch
    //
    // When `voice.disableMeetingDetection` is true in UserDefaults, ALL
    // automated meeting capture paths are torn down: CallAppDetector is never
    // started (no SCShareableContent calls at all), the Chrome bridge's
    // auto-start is short-circuited, and the .voiceAutoStartMeeting
    // notification is ignored. The user can still manually start a meeting
    // capture from the UI; this only disables the *automatic* triggers that
    // were causing the orange screen-recording indicator to light up
    // unexpectedly during plain dictation.
    //
    // Default: false (auto-detection enabled). UI toggle is wired separately
    // in BigMenuWindow.swift; this file only exposes the storage key and the
    // gate logic.
    static let kDisableMeetingDetectionKey = "voice.disableMeetingDetection"
    static var isMeetingDetectionDisabled: Bool {
        UserDefaults.standard.bool(forKey: kDisableMeetingDetectionKey)
    }
    /// Meeting resilience: orphan WAV recovery on launch, per-30s draft
    /// checkpoint during capture, and a re-transcribe-from-audio path that
    /// can rebuild a transcript from any meeting's saved WAV file.
    lazy var meetingRecovery: MeetingRecoveryService = MeetingRecoveryService(
        storage: coordinator.storage,
        transcription: coordinator.transcription
    )
    /// 30-second draft-checkpoint timer for the live meeting. Cancelled in stopMeetingCapture.
    private var meetingDraftCheckpointTask: Task<Void, Never>?
    /// 15-second grace timer that fires when MeetBridge reports the call is
    /// still active but no other participants remain. Cancelled if anyone
    /// re-joins, or in stopMeetingCapture().
    private var meetingParticipantsLeftTask: Task<Void, Never>?
    private let hotkeyService = HotkeyService()
    private let textFormatter = TextFormatter()
    private let cursorPaster = CursorPaster()

    private var cancelDismissTask: Task<Void, Never>?
    private var undoPasteDismissTask: Task<Void, Never>?
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

    /// Hard ceiling on a SINGLE dictation (push-to-talk hold OR hands-free lock
    /// mode). When a recording reaches this, we auto-commit it exactly as if the
    /// user released the hotkey — the words are transcribed + saved, never
    /// dropped. This is also the safety net for a *missed hotkey-up*: if the
    /// release event is ever lost (lock mode never flips, PTT key-up swallowed),
    /// the recording would otherwise run forever; the watchdog guarantees it
    /// commits no later than this cap.
    ///
    /// NOTE: This is the DICTATION cap only. Meeting capture
    /// (`MeetingCaptureService`) has its own independent multi-hour path and is
    /// deliberately untouched by this watchdog.
    private let maxDictationDuration: TimeInterval = 300  // 5 minutes (300s)

    /// Task-based max-duration watchdog. Armed when a dictation recording begins
    /// (keyed off the actual recording start time, NOT hotkey state, so it still
    /// fires on a missed hotkey-up) and cancelled when the recording
    /// finishes/cancels normally so it never double-fires. Mirrors the
    /// `pendingRecordingStart` 2s safety-timer pattern, but as a structured Task
    /// rather than a repeating Timer.
    private var maxDurationWatchdog: Task<Void, Never>?

    /// Bundle identifier of whatever app was frontmost when the user
    /// triggered recording. Re-activated before paste so the transcript
    /// lands where the user expects — even if focus shifted in the interim
    /// (e.g., the user used System Settings to grant Accessibility, then
    /// pressed the hotkey without re-clicking their target app).
    @ObservationIgnored private var targetAppBundleID: String?

    /// Saved personality style from before an auto-personality override.
    /// When `voice.autoPersonality` is on and a frontmost app maps to a
    /// specific personality, we stash the user's real preference here and
    /// restore it after the dictation is pasted so the user's setting is
    /// never permanently changed.
    @ObservationIgnored private var previousPersonality: String? = nil

    /// Text-field context (chars immediately before cursor) sampled at the
    /// moment recording starts. We read at start (not paste) because that's
    /// when the user's target field reliably owns AX focus — by paste time,
    /// toast popups or other UI may have stolen focus and given us a stale
    /// or empty read. The polisher uses this to make smart spacing /
    /// punctuation / number-formatting decisions relative to existing text.
    @ObservationIgnored private var capturedFieldContext: String?

    /// Rich app context (window title, focused element role, placeholder text)
    /// sampled at recording-start alongside `capturedFieldContext`. This becomes
    /// the `appContextLabel` passed to the cloud polisher — it's far richer than
    /// the static bundle-ID→string map (`Qwen3Polisher.appContextLabel`) because
    /// it includes WHICH Slack channel, WHAT email subject, or WHICH file in
    /// Xcode. The cloud model uses this to pick register, length, and format.
    /// Built by `buildEnrichedAppContextLabel(...)` and consumed at polish time.
    @ObservationIgnored private var capturedRichAppContext: String?

    // Permission-prompt throttling. macOS shows the system "grant access"
    // dialog every time AXIsProcessTrustedWithOptions(prompt: true) is called
    // — pressing the hotkey 40 times yields 40 dialogs. Track per-session so
    // we ask exactly once, then route the user to System Settings.
    private var didShowAXPrompt = false
    private var didShowMicPrompt = false
    private var didShowSRPrompt = false
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

    /// Meeting ID handed off from a "Transcript ready" notification click. Picked
    /// up by BigMenuWindow on first appearance (and via .onReceive for the
    /// already-open case) so the row is pre-expanded + scrolled into view.
    static var pendingMeetingIDFromNotification: String? = nil

    // (Previously used to swallow a deactivate after lock-exit, but the new
    // state machine doesn't fire deactivate on lock exit, so the flag was a
    // footgun — once set on lock exit, it stayed true and silently killed
    // every subsequent PTT release. Removed.)

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[VOICE-ICON] startup: bundlePath=\(Bundle.main.bundlePath)")
        print("[VOICE-ICON] startup: bundleId=\(Bundle.main.bundleIdentifier ?? "<nil>")")

        // Seed the user's own name (used to filter "Michael" out of the
        // participant list so meeting titles don't include the local user).
        // No UI yet — power users can override via `defaults write`.
        let existingUserName = UserDefaults.standard.string(forKey: "voice.userName") ?? ""
        if existingUserName.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set("Michael", forKey: "voice.userName")
        }

        // Orphan-meeting recovery: any WAV files on disk whose path isn't
        // referenced from a DB row are crash survivors. Import them as
        // placeholder Meeting rows so the user can find + re-transcribe them
        // instead of silently leaking. Runs after a 1.5s delay so the storage
        // layer has time to finish its own initialize/migrate pass.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            // Purge structurally-corrupt meetings (empty/broken WAVs + DB rows
            // whose audio is missing) BEFORE the orphan scan, so recovery
            // starts from a clean state. See MeetingRecoveryService.purgeCorruptMeetings.
            self.meetingRecovery.purgeCorruptMeetings()
            // Dedup pass: collapse rows that were saved twice for the same
            // call (stop/start race or bridge double-fire). Runs after purge
            // so the corrupt-row dataset is gone first. Save-time dedup
            // (StorageService.saveMeeting) prevents new duplicates; this
            // pass cleans up the ones that already snuck in.
            let dedupedCount = self.meetingRecovery.dedupeMeetings()
            if dedupedCount > 0 {
                self.showToast("Cleaned up \(dedupedCount) duplicate meeting\(dedupedCount == 1 ? "" : "s")")
            }
            let orphans = self.meetingRecovery.discoverOrphanedMeetingAudio()
            // Only auto-import meaningful orphans (>20s) so the listing isn't
            // polluted with one-second test sessions. Anything shorter is left
            // on disk for manual cleanup.
            for orphan in orphans where orphan.durationSeconds >= 300 {
                self.meetingRecovery.importOrphan(orphan)
            }
            let importedCount = orphans.filter { $0.durationSeconds >= 180 }.count
            if importedCount > 0 {
                self.showToast("Recovered \(importedCount) meeting\(importedCount == 1 ? "" : "s") from previous crash")
            }

            // Reclassify short meetings as dictations so the Meetings tab
            // doesn't fill up with 30s drive-by recordings.
            self.reclassifyShortMeetings()

            // Title cleanup: meetings whose row was checkpointed mid-recording
            // but never properly finalized end up titled "Live meeting (in
            // progress) — …" or "Recording — …" forever. Rewrite those to a
            // clean human-readable form derived from the date + duration.
            self.cleanUpStaleMeetingTitles()

            // Try to repair any WAV files whose header is broken (Voice was
            // killed mid-write — the RIFF chunk size is still 0, so the file
            // says "I have 0 bytes of audio" even though the data section is
            // many megabytes). We rewrite a valid header so the audio is
            // actually decodable before the auto-transcribe pass tries it.
            await self.repairBrokenWAVHeaders()

            // Empty-meeting auto-recovery: re-transcribe any meeting where
            // audio is on disk but the segments table is empty. This catches
            // meetings broken by the pre-build-35 worker-respawn bug where
            // chunks 2..N silently dropped. Wait for the transcription engine
            // to be ready before kicking off, so we don't race coordinator.prepare().
            while !self.coordinator.transcription.isReady {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            let allMeetings = self.coordinator.fetchAllMeetings()
            let toFix = allMeetings.filter { m in
                guard m.kind == .meeting,
                      m.duration >= 300,                    // 3-min threshold — anything shorter isn't a meeting
                      m.segments.isEmpty,
                      let p = m.audioFilePath,
                      FileManager.default.fileExists(atPath: p)
                else { return false }
                return true
            }
            guard !toFix.isEmpty else { return }
            print("[VOICE-RECOVERY] auto-retranscribe: \(toFix.count) empty meetings have audio on disk")
            self.showToast("Re-transcribing \(toFix.count) meeting\(toFix.count == 1 ? "" : "s") with missing transcripts…")
            var successCount = 0
            for m in toFix {
                if await self.meetingRecovery.retranscribe(meeting: m) != nil {
                    successCount += 1
                }
            }
            self.fetchMeetingsIntoState()
            self.showToast("Transcript recovery complete (\(toFix.count) meeting\(toFix.count == 1 ? "" : "s")).")
            // System notification for the case where Voice ran the recovery
            // silently in the background and the user hasn't opened BigMenu.
            if successCount > 0 {
                MeetingNotifier.notify(
                    title: "Meeting transcripts ready",
                    body: "\(successCount) meeting\(successCount == 1 ? "" : "s") finished transcribing.",
                    meetingId: nil
                )
            }
        }

        // Stay as a menu-bar-only agent by default — dock icon appears only
        // while BigMenu is open. This lets Voice launch at login silently
        // so meeting capture is always running without user intervention.
        // (LSUIElement=true in Info.plist already starts us as .accessory;
        // we keep it that way and only flip to .regular in openBigMenu.)

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
        // Wrap startup tasks individually so one failure doesn't tank launch.
        runStartupStep("menu_bar") { self.setupMenuBar() }
        runStartupStep("overlay_panel") { self.setupOverlayPanel() }
        runStartupStep("hotkey") { self.setupHotkey() }
        runStartupStep("wake_word") { self.setupWakeWord() }
        runStartupStep("error_observer") { self.setupErrorObserver() }
        runStartupStep("launch_at_login_sync") { LaunchAtLoginService.syncFromStorage() }
        runStartupStep("notification_auth") { MeetingNotifier.requestAuthIfNeeded() }
        // Wire the UN delegate BEFORE any notification can land so taps on
        // "Transcript ready" banners are routed back into BigMenu instead of
        // being silently swallowed.
        runStartupStep("notification_delegate") {
            UNUserNotificationCenter.current().delegate = MeetingNotifier.delegate
        }

        // Run the same throttled permission check at launch so first-time
        // users get the prompt + System Settings deep-link immediately
        // (instead of having to press the hotkey first to discover the
        // gate). Once granted, the watcher rebinds monitors automatically.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()
        // Screen Recording is needed for meeting capture. CGPreflightScreenCaptureAccess
        // is a non-prompting check — pairs with the same handleMissingPermissions
        // chain as mic/AX so the user gets a one-shot toast + privacy pane deep-link.
        let srOk = CGPreflightScreenCaptureAccess()
        if !micOk || !axOk || !srOk {
            handleMissingPermissions(micOk: micOk, axOk: axOk, srOk: srOk, micStatus: micStatus)
        }

        Task {
            await coordinator.prepare()
        }

        // Load persisted meetings into UI state at launch. Goes through the
        // single fetch funnel so `meetingsLoadState` flips loading → loaded
        // (or → .error) and the BigMenuWindow Meetings tab can show a
        // skeleton on first frame instead of momentarily flashing the empty
        // state.
        fetchMeetingsIntoState()

        // Crash recovery — if a meeting was in progress when the app or computer
        // died, its segments were checkpointed to UserDefaults every 5 minutes.
        // Recover them now as an unsummarized meeting so nothing is lost.
        recoverCrashedMeetingIfNeeded()

        // Start the Chrome extension bridge server. The "Voice Meet Bridge"
        // extension POSTs to localhost:59423 when entering/leaving a meeting.
        // This replaces the fragile AX window-title polling approach.
        meetBridgeServer.onMeetActive = { [weak self] active, names in
            guard let self else { return }
            if active {
                // Capture participant names every time we hear "active=true",
                // even if we're already capturing — later notifications often
                // arrive after the participant tiles have rendered, so the
                // second / third message is the one that actually has names.
                if !names.isEmpty {
                    // Merge instead of overwrite: keep any names already seen
                    // this session (e.g. someone who left the call before the
                    // panel refreshed). Filtering of the local user happens
                    // later in `generateMeetingTitle`.
                    let existing = Set(self.recordingState.meetingParticipantNames)
                    let merged = self.recordingState.meetingParticipantNames + names.filter { !existing.contains($0) }
                    self.recordingState.meetingParticipantNames = merged
                    print("[MeetBridge] Captured participant names: \(merged)")
                    // Someone is on the call — cancel any pending participants-left
                    // grace timer.
                    if self.meetingParticipantsLeftTask != nil {
                        print("[MeetBridge] Participants returned — cancelling participants-left grace timer")
                        self.meetingParticipantsLeftTask?.cancel()
                        self.meetingParticipantsLeftTask = nil
                    }
                } else if self.recordingState.isCapturingMeeting,
                          !self.recordingState.meetingParticipantNames.isEmpty,
                          self.meetingParticipantsLeftTask == nil {
                    // Active=true but no other participants visible. If we had
                    // names before, the call has emptied out — schedule a 15s
                    // grace timer to handle brief reconnect blips. If we still
                    // see no one after the grace, stop the capture.
                    print("[MeetBridge] Participants dropped to 0 — scheduling 15s grace stop")
                    self.meetingParticipantsLeftTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        guard self.recordingState.isCapturingMeeting else { return }
                        print("[MeetBridge] 15s grace elapsed with no participants — auto-stopping capture")
                        self.meetingParticipantsLeftTask = nil
                        self.stopMeetingCapture(reason: "participantsLeft")
                    }
                }
                guard !self.recordingState.isCapturingMeeting else { return }
                self.recordingState.isMeetingAppActive = true
                // Smart trigger: only start recording when at least ONE other
                // participant is present. Solo waits in an empty Meet are
                // Participant-count gate REMOVED. The Chrome extension's
                // participant-tile scraping is unreliable across Meet UI
                // refreshes (the tile DOM changes frequently), and solo
                // recordings (rehearsals, lectures, 1-on-1s where the other
                // person hasn't joined yet) were being silently dropped.
                // If the MeetBridge extension says a Meet URL is active,
                // that's the signal — start recording.
                let otherCount = self.recordingState.meetingParticipantNames.count
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] MeetBridge auto-start blocked — voice.disableMeetingDetection is true")
                    return
                }
                // Record the browser bundle as the meeting source. This is
                // the "proof" that lets MeetingCaptureService accept a
                // browser as a legitimate capture target — the bridge POST
                // came from the Voice Meet Bridge extension running in that
                // browser, so a real Meet/Zoom-web/Teams-web tab is active.
                // Without this, the service's proof-required whitelist would
                // refuse any browser-based capture.
                if self.recordingState.meetingSourceBundleID == nil {
                    self.recordingState.meetingSourceBundleID =
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                }
                print("[MeetBridge] Meet joined with \(otherCount) other participant(s) → auto-starting capture")
                print("[VOICE-MEET-START] reason=meetbridge participants=\(otherCount) source=chrome-extension bundle=\(self.recordingState.meetingSourceBundleID ?? "nil")")
                self.startMeetingCapture()
                self.showToast("Meeting detected — capturing audio")
            } else {
                self.recordingState.isMeetingAppActive = false
                // The extension only sends active=false when the meeting URL
                // is actually gone (user left the call or closed the tab) —
                // NOT when they just switch windows. So this is safe to act on.
                guard self.recordingState.isCapturingMeeting else { return }
                print("[MeetBridge] Meet ended → auto-stopping capture")
                self.stopMeetingCapture(reason: "meetEnded")
            }
        }
        // Active-speaker events from the Chrome extension. The MeetingCapture
        // service appends each event to a bounded timeline and, in the next
        // 30-second chunk, replaces the generic "MEETING" label with the
        // speaker name whose tile was lit up at the segment's midpoint.
        meetBridgeServer.onSpeakerEvent = { [weak self] name, active, t in
            self?.meetingCaptureService.recordSpeakerEvent(name: name, active: active, t: t)
        }
        // Gate the Chrome bridge HTTP listener behind the meeting-detection
        // opt-out. When off, the server never binds port 59423 and no auto
        // meeting captures fire from browser-detected calls.
        if BackgroundActivityGate.meetingDetectionEnabled {
            meetBridgeServer.start()
        } else {
            print("[VOICE-GATE] meetBridgeServer.start() skipped — voice.enableMeetingDetection=false (or privacyMode)")
        }

        // Native call-app detector — fires when Discord/Zoom/Teams/Slack/
        // FaceTime/WhatsApp/Telegram are actually on a call (visible in
        // SCShareableContent.applications AND mic is in use). Mirrors the
        // Chrome bridge wiring: starts a meeting capture, with a guard so
        // we don't double-trigger if Chrome already grabbed it.
        callAppDetector.onCallStateChange = { [weak self] active, bundle in
            guard let self else { return }
            if active {
                guard !self.recordingState.isCapturingMeeting else {
                    print("[CallAppDetector] \(bundle ?? "?") active, but capture already running — skipping")
                    return
                }
                // CRITICAL: ignore the detector when a dictation is running.
                // CallAppDetector's heuristic — "known-call app is in the
                // audio producers list AND mic is in use" — false-positives
                // during normal dictation because:
                //   1. The user has Discord/Slack open in the background and
                //      it produces a notification sound while they're
                //      dictating.
                //   2. The mic is hot because of the dictation itself.
                // Result: every dictation kicks off a screen-recording meeting
                // capture. We block it here.
                if self.recordingState.isRecording || self.recordingState.isLocked {
                    print("[CallAppDetector] \(bundle ?? "?") active, but dictation is running — ignoring")
                    return
                }
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] CallAppDetector auto-start blocked — voice.disableMeetingDetection is true")
                    return
                }
                self.recordingState.isMeetingAppActive = true
                self.recordingState.meetingSourceBundleID = bundle
                let label = bundle.flatMap { CallAppDetector.knownCallApps[$0] } ?? "call"
                print("[CallAppDetector] auto-starting capture for \(label) (\(bundle ?? "?"))")
                print("[VOICE-MEET-START] reason=callappdetector app=\(label) bundle=\(bundle ?? "?") frontmost=true mic-in-use=true streak=\(CallAppDetector.knownCallApps[bundle ?? ""] ?? "?")")
                self.startMeetingCapture()
                self.showToast("\(label) call detected — capturing audio")
            } else {
                self.recordingState.isMeetingAppActive = false
                guard self.recordingState.isCapturingMeeting else { return }
                // Only stop if this capture was driven by the native detector
                // (matching bundle). If Chrome bridge took over with a
                // different source, leave it alone.
                if self.recordingState.meetingSourceBundleID == bundle {
                    print("[CallAppDetector] \(bundle ?? "?") call ended — auto-stopping capture")
                    self.stopMeetingCapture(reason: "callAppEnded")
                }
            }
        }
        // Combined gate: must be allowed by both the legacy disable flag and
        // the new opt-in. Defaults result in OFF (opt-in is false by default).
        if BackgroundActivityGate.meetingDetectionEnabled {
            callAppDetector.start()
        } else {
            print("[VOICE-MEET] CallAppDetector NOT started — voice.enableMeetingDetection=false / disable=true / privacyMode")
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
        menuBarIconTimer?.invalidate()
        menuBarIconTimer = nil
        // BUGFIX: cancel in-flight Tasks so they don't try to mutate state
        // during the shutdown window (could race UserDefaults flushes below).
        cancelDismissTask?.cancel(); cancelDismissTask = nil
        errorDismissTask?.cancel(); errorDismissTask = nil
        undoPasteDismissTask?.cancel(); undoPasteDismissTask = nil
        pendingFinishTask?.cancel(); pendingFinishTask = nil
        pasteChain?.cancel(); pasteChain = nil
        maxDurationWatchdog?.cancel(); maxDurationWatchdog = nil
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

        // Status header — disabled item at the top of the menu that shows
        // what Voice is doing right now ("Idle", "Dictating…", "Recording
        // meeting · 03:42"). Refreshed lazily in menuWillOpen.
        let statusHeader = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusHeader.tag = MenuTag.statusHeader.rawValue
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        menu.addItem(NSMenuItem.separator())

        // "Stop Meeting Recording" — hidden unless a meeting capture is active.
        // Sits at the TOP of the menu (above "Open VOICE") so the user can
        // kill an unwanted screen recording with one click, never hunting.
        // Visibility toggled in menuWillOpen so we don't have to observe state.
        // A `stop.circle.fill` SF symbol tinted .systemRed makes the row
        // unmistakable when it appears.
        let stopMeetingItem = NSMenuItem(title: "Stop Meeting Recording",
                                          action: #selector(stopMeetingFromMenu),
                                          keyEquivalent: "")
        stopMeetingItem.target = self
        stopMeetingItem.tag = MenuTag.stopMeeting.rawValue
        stopMeetingItem.isHidden = true
        if let stopImg = NSImage(systemSymbolName: "stop.circle.fill",
                                 accessibilityDescription: "Stop meeting recording") {
            // Draw the symbol into a new image, then re-tint with systemRed
            // via the .sourceIn composite. NSMenuItem.image doesn't honour
            // contentTintColor so we have to bake the tint into the image.
            let size = stopImg.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                stopImg.draw(in: rect)
                NSColor.systemRed.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.isTemplate = false
            stopMeetingItem.image = tinted
        }
        menu.addItem(stopMeetingItem)

        // "Start Meeting Recording" — manual trigger for solo recordings,
        // testing, or when auto-detection doesn't fire (e.g., Discord call
        // that the bundle detector missed). Hidden when a capture is already
        // active. Sits right above Stop so it's the obvious lever to find.
        let startMeetingItem = NSMenuItem(title: "Start Meeting Recording",
                                          action: #selector(startMeetingFromMenu),
                                          keyEquivalent: "")
        startMeetingItem.target = self
        startMeetingItem.tag = MenuTag.startMeeting.rawValue
        startMeetingItem.isHidden = false
        if let startImg = NSImage(systemSymbolName: "record.circle",
                                  accessibilityDescription: "Start meeting recording") {
            let size = startImg.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                startImg.draw(in: rect)
                NSColor.systemRed.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.isTemplate = false
            startMeetingItem.image = tinted
        }
        menu.addItem(startMeetingItem)

        let openItem = NSMenuItem(title: "Open VOICE", action: #selector(openBigMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Activate wake-word listener for the configured window (default 5
        // minutes). Posts a notification picked up by setupWakeWord(). Only
        // useful while `voice.wakeWordMode == "activatedWindow"`, but we
        // surface it unconditionally — pressing it in always-on mode is a
        // harmless no-op (the listener is already running), and in off
        // mode the user has chosen to disable wake-word entirely so it
        // also no-ops in WakeWordService.
        let armWakeItem = NSMenuItem(
            title: "Activate Wake Word for 5 minutes",
            action: #selector(activateWakeWordWindowFromMenu),
            keyEquivalent: ""
        )
        armWakeItem.target = self
        menu.addItem(armWakeItem)

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

        // Adaptive-rate menu bar icon refresh:
        //   • 1Hz while actively recording or capturing a meeting — tooltip
        //     shows a running clock and the state symbol needs to snap quickly.
        //   • 0.2Hz (every 5s) while idle — icon and tooltip are static; no
        //     visual benefit to waking the CPU every second. Saves ~4 timer
        //     firings/sec × every second the user isn't dictating.
        // State-change sites (startMeetingCapture, stopMeetingCapture,
        // hotkeyDidActivate/Deactivate) call refreshMenuBarIcon() directly so
        // the icon always updates immediately on transition regardless of where
        // the adaptive timer currently sits.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
    }

    private var menuBarIconTimer: Timer?
    /// Cache for the menu bar icon so we only allocate a new NSImage when the
    /// displayed state actually changes. The key encodes all inputs that affect
    /// symbol name + tooltip (state combination + meeting duration for the
    /// seconds-ticking tooltip). Re-create only on a key change; skip otherwise.
    private var cachedMenuIcon: (stateKey: String, image: NSImage)?

    /// Schedule (or reschedule) the menu bar icon refresh timer at the
    /// appropriate rate for the current state:
    ///   • 1s  — recording or capturing a meeting (live state visible in icon/tooltip)
    ///   • 5s  — idle (icon is static; tooltip is "fn to dictate")
    /// Call this whenever the app transitions between active and idle so the
    /// interval is always appropriate without needing to poll at 1Hz for no reason.
    func scheduleMenuBarIconTimer() {
        let isActive = recordingState.isRecording
                    || recordingState.isLocked
                    || recordingState.isCapturingMeeting
                    || recordingState.isTranscribing
        let interval: TimeInterval = isActive ? 1.0 : 5.0

        // Avoid tearing down and rebuilding a timer that already has the right
        // interval — RunLoop timer teardown/setup has a small but nonzero cost.
        if let existing = menuBarIconTimer, existing.timeInterval == interval { return }

        menuBarIconTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBarIcon() }
        }
        RunLoop.main.add(t, forMode: .common)
        menuBarIconTimer = t
    }

    /// Tags so we can find specific items in the menu when refreshing.
    /// Recents used to live here (`case recent = 1001`) but were consolidated
    /// into the BigMenu popup, so only the launch-at-login state needs a tag.
    private enum MenuTag: Int {
        case launchAtLogin = 1002
        case recentsSubmenu = 1003
        case stopMeeting = 1004
        case statusHeader = 1005
        case startMeeting = 1006
    }

    /// Refresh the menu bar status icon to reflect current state.
    /// Idle = `waveform`, dictating = `waveform.circle.fill` (accented),
    /// meeting = `record.circle.fill` (red tint via template + accent).
    func refreshMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let tooltip: String
        let meetingActive = recordingState.isCapturingMeeting
        if meetingActive {
            symbolName = "record.circle.fill"
            let mins = recordingState.meetingDurationSeconds / 60
            let secs = recordingState.meetingDurationSeconds % 60
            tooltip = String(format: "VOICE — RECORDING MEETING %d:%02d (click to stop)", mins, secs)
        } else if recordingState.isRecording || recordingState.isLocked {
            symbolName = "waveform.circle.fill"
            tooltip = "VOICE — dictating"
        } else {
            symbolName = "waveform"
            tooltip = "VOICE — fn to dictate"
        }
        // Cache key includes tint mode so we rebuild the NSImage when
        // toggling between template (idle/dictating) and tinted-red (meeting).
        // During meeting capture the icon is rendered as a non-template image
        // with `contentTintColor = .systemRed` so the user can see at a glance
        // that screen recording is active — half of the explicit-visibility
        // fix for the meeting-false-trigger trust bug.
        let stateKey = "\(symbolName)|\(meetingActive ? "red" : "template")"
        if cachedMenuIcon?.stateKey != stateKey {
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VOICE") {
                if meetingActive {
                    // Non-template so the systemRed tint actually paints —
                    // template images get forced to monochrome by AppKit.
                    img.isTemplate = false
                    button.image = img
                    button.contentTintColor = NSColor.systemRed
                } else {
                    img.isTemplate = true
                    button.image = img
                    button.contentTintColor = nil
                }
                cachedMenuIcon = (stateKey: stateKey, image: img)
            }
        }
        button.toolTip = tooltip
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
        // Build number is the app's identity (no marketing version). The build
        // script auto-increments CFBundleVersion on every build-install run, so
        // "Build N" is the single source of truth for which build is running.
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "VOICE",
            .applicationVersion: "Build \(buildNumber)"
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
    /// Menu bar action — arms the wake-word listener for the configured
    /// window. Posts a notification rather than calling the service
    /// directly so any other UI surface (hotkey, future widget) can use
    /// the same entry point.
    @objc func activateWakeWordWindowFromMenu() {
        NotificationCenter.default.post(name: .voiceActivateWakeWordWindow, object: nil)
    }

    @objc func openBigMenu() {
        // Reveal in the Dock + Cmd-Tab while the window is visible.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            assertAppIcon(context: "openBigMenu")
        }
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
        let meetingActive = recordingState.isCapturingMeeting
        // Status header: human-readable summary of current state.
        let statusTitle: String
        if meetingActive {
            let s = recordingState.meetingDurationSeconds
            statusTitle = String(format: "Recording meeting · %d:%02d", s / 60, s % 60)
        } else if recordingState.isRecording || recordingState.isLocked {
            statusTitle = "Dictating…"
        } else if recordingState.isTranscribing {
            statusTitle = "Transcribing…"
        } else {
            statusTitle = "Idle — fn to dictate"
        }
        for item in menu.items {
            if item.tag == MenuTag.launchAtLogin.rawValue {
                item.state = LaunchAtLoginService.isEnabled ? .on : .off
            } else if item.tag == MenuTag.recentsSubmenu.rawValue, let sub = item.submenu {
                refreshRecentsSubmenu(sub)
            } else if item.tag == MenuTag.stopMeeting.rawValue {
                item.isHidden = !meetingActive
            } else if item.tag == MenuTag.startMeeting.rawValue {
                // Start is the inverse of Stop: only visible when no capture is active.
                item.isHidden = meetingActive
            } else if item.tag == MenuTag.statusHeader.rawValue {
                item.title = statusTitle
            }
        }
        // Also refresh the icon when the menu opens — cheap, no timer needed.
        refreshMenuBarIcon()
    }

    /// "Stop meeting recording" menu bar item handler. Posts the same
    /// notification the pill tap uses so the off-limits AppDelegate
    /// meeting-handling code remains the single source of truth.
    @objc fileprivate func stopMeetingFromMenu() {
        NotificationCenter.default.post(name: .voiceStopMeetingRequested, object: nil)
    }

    /// "Start meeting recording" menu bar item handler. Manual override
    /// for solo recordings, testing, and any case where auto-detection
    /// didn't fire. Bypasses the participant-count and frontmost-app
    /// gates because the user is explicitly asking for it.
    @objc fileprivate func startMeetingFromMenu() {
        if recordingState.isCapturingMeeting {
            print("[VOICE-MEET] startMeetingFromMenu — already capturing, ignoring")
            return
        }
        if AppDelegate.isMeetingDetectionDisabled {
            showToast("Meeting detection is disabled in Settings.")
            return
        }
        // Pretend we have a legitimate source so the service whitelist accepts.
        // The user manually clicked — that's the proof.
        if recordingState.meetingSourceBundleID == nil {
            recordingState.meetingSourceBundleID =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                ?? "com.fortun8te.voice"
        }
        print("[VOICE-MEET-START] reason=manual-menu source=\(recordingState.meetingSourceBundleID ?? "self")")
        startMeetingCapture()
        showToast("Meeting recording started — click menu to stop")
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

        // Mic-capture failed at meeting start. Surface a clear warning so the
        // user knows the meeting is being recorded with system audio only —
        // their own voice will be missing from playback. Without this they
        // would discover it hours later.
        let micFailedToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.meetingMicFailed"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?["reason"] as? String) ?? "unknown reason"
            Task { @MainActor in
                self?.showToast("Mic capture failed (\(reason)). Recording system audio only — your voice may not be captured.")
            }
        }
        notificationTokens.append(micFailedToken)

        // Mic dropped mid-meeting. The 10s health log detected zero mic
        // samples while system audio kept flowing. Could be another app
        // grabbing exclusive mic access, device disconnect, etc.
        let micDroppedToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.meetingMicDropped"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showToast("Mic appears to have dropped mid-meeting — your voice may be missing from the recording.")
            }
        }
        notificationTokens.append(micDroppedToken)

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

        // System notification click ("Transcript ready") → open BigMenu pre-
        // scrolled + expanded to that meeting row. The MeetingNotificationDelegate
        // translates the UN tap into this NotificationCenter post; we stash the
        // ID in a static so BigMenuWindow picks it up on first appearance, and
        // BigMenuWindow also listens to this same notification for the
        // already-open case.
        let openMeetingFromNotifToken = NotificationCenter.default.addObserver(
            forName: .voiceOpenMeetingFromNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idStr = (note.userInfo?["meetingId"] as? String) ?? ""
                AppDelegate.pendingMeetingIDFromNotification = idStr.isEmpty ? nil : idStr
                NSApp.activate(ignoringOtherApps: true)
                self.openBigMenu()
            }
        }
        notificationTokens.append(openMeetingFromNotifToken)

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

        // Global Escape → cancel any in-flight dictation work. HotkeyService
        // posts this on every Esc keyDown; cancelInFlightProcessing() gates on
        // the current pipeline phase so idle Esc remains a true no-op (we
        // never shadow system-wide Esc semantics in other apps).
        let escapeToken = NotificationCenter.default.addObserver(
            forName: .voiceEscapePressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInFlightProcessing() }
        }
        notificationTokens.append(escapeToken)

        // Auto-start meeting capture when poll timer detects a meeting app.
        let autoStartMeetingToken = NotificationCenter.default.addObserver(
            forName: .voiceAutoStartMeeting,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.recordingState.isCapturingMeeting else { return }
                if AppDelegate.isMeetingDetectionDisabled {
                    print("[VOICE-MEET] .voiceAutoStartMeeting blocked — voice.disableMeetingDetection is true")
                    return
                }
                print("[VOICE-MEET] Auto-starting meeting capture")
                print("[VOICE-MEET-START] reason=voiceAutoStartMeeting source=notification")
                self.startMeetingCapture()
                self.showToast("Meeting detected — capturing audio")
            }
        }
        notificationTokens.append(autoStartMeetingToken)

        // Menu bar "Stop meeting recording" → call the existing stop flow.
        let stopMeetingToken = NotificationCenter.default.addObserver(
            forName: .voiceStopMeetingRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordingState.isCapturingMeeting else { return }
                self.stopMeetingCapture(reason: "userStopRequested")
            }
        }
        notificationTokens.append(stopMeetingToken)

        // BigMenu meetings empty-state "Start meeting manually" button →
        // same flow as the menu bar's "Start Meeting Recording" item so
        // there's one canonical path for user-initiated meeting captures.
        let startMeetingManualToken = NotificationCenter.default.addObserver(
            forName: .voiceStartMeetingManual,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startMeetingFromMenu()
            }
        }
        notificationTokens.append(startMeetingManualToken)

        // Watchdog: MeetingCaptureService posts this when no fresh audio
        // samples have arrived for >5s while capture is supposedly active.
        // Surface a toast so the user knows the recording may be incomplete.
        let audioStalledToken = NotificationCenter.default.addObserver(
            forName: .voiceMeetingAudioStalled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showToast("Meeting audio stopped unexpectedly — recording may be incomplete.")
            }
        }
        notificationTokens.append(audioStalledToken)

        // BigMenu "Delete meeting" context-menu → resolve meeting by ID,
        // delete the DB row + audio file via StorageService.deleteMeeting,
        // and post a toast confirming. Same notification-driven pattern as
        // transcribe so the view layer never has to reach into AppDelegate.
        let deleteMeetingToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("voice.deleteMeetingRequested"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let idStr = note.userInfo?["meetingId"] as? String,
                      let uuid = UUID(uuidString: idStr) else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try self.coordinator.storage.deleteMeeting(id: uuid)
                        print("[VOICE-MEET] deleted meeting \(idStr)")
                        self.showToast("Meeting deleted.")
                        // Refresh the meeting list in BigMenu.
                        NotificationCenter.default.post(
                            name: Notification.Name("voice.meetingsChanged"),
                            object: nil
                        )
                    } catch {
                        print("[VOICE-MEET] delete failed: \(error.localizedDescription)")
                        self.showToast("Couldn't delete meeting: \(error.localizedDescription)")
                    }
                }
            }
        }
        notificationTokens.append(deleteMeetingToken)

        // BigMenu "Transcribe now" → resolve meeting by ID, run retranscribe,
        // post result back via .voiceTranscribeMeetingFinished. Avoids the
        // fragile NSApp.delegate cast from a SwiftUI view layer.
        let transcribeRequestedToken = NotificationCenter.default.addObserver(
            forName: .voiceTranscribeMeetingRequested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let idStr = note.userInfo?["meetingId"] as? String,
                      let uuid = UUID(uuidString: idStr) else { return }
                let meetings = self.coordinator.fetchAllMeetings()
                guard let meeting = meetings.first(where: { $0.id == uuid }) else {
                    NotificationCenter.default.post(
                        name: .voiceTranscribeMeetingFinished,
                        object: nil,
                        userInfo: [
                            "meetingId": idStr,
                            "success": false,
                            "error": "Meeting not found in DB."
                        ]
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Wait briefly for the engine to load — at most ~10s.
                    var waited: Int = 0
                    while !self.coordinator.transcription.isReady && waited < 20 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        waited += 1
                    }
                    guard self.coordinator.transcription.isReady else {
                        NotificationCenter.default.post(
                            name: .voiceTranscribeMeetingFinished,
                            object: nil,
                            userInfo: [
                                "meetingId": idStr,
                                "success": false,
                                "error": "Transcription model still loading — try again in a moment."
                            ]
                        )
                        return
                    }
                    let result = await self.meetingRecovery.retranscribe(meeting: meeting)
                    if result != nil {
                        self.reloadMeetingsFromDisk()
                    }
                    NotificationCenter.default.post(
                        name: .voiceTranscribeMeetingFinished,
                        object: nil,
                        userInfo: [
                            "meetingId": idStr,
                            "success": result != nil,
                            "error": result == nil ? "Couldn't transcribe. The audio file may be corrupted or empty." : nil as Any?
                        ].compactMapValues { $0 }
                    )
                    // System notification — fires regardless of BigMenu state
                    // so the user knows it's done even while another app is
                    // focused. The in-window toast (.voiceTranscribeMeetingFinished
                    // observer in the row) also fires; users see whichever
                    // surfaces first.
                    if let updated = result {
                        MeetingNotifier.notify(
                            title: "Transcript ready",
                            body: updated.title,
                            meetingId: idStr
                        )
                    } else {
                        MeetingNotifier.notify(
                            title: "Couldn't transcribe meeting",
                            body: "Audio file may be corrupted or empty.",
                            meetingId: idStr
                        )
                    }
                }
            }
        }
        notificationTokens.append(transcribeRequestedToken)

        // (The Meetings tab used to post cancel/commit notifications observed
        // here. That tab was removed in favor of a future browser-extension
        // sourced meetings view — observers gone too.)
    }

    @MainActor
    /// Polish-in-place. Called either from the hotkey monitor (passes nil so we
    /// read selection ourselves) or from handlePillTap (passes the already-read
    /// selection to avoid a second AX round-trip).
    /// Polish the selected text. `levelOverride` lets a caller (the hover bar
    /// level buttons) pick the cleanup level for this single call without
    /// touching the user's persisted preference. Valid values: "light" /
    /// "medium" / "heavy". When nil, the saved `cleanupLevel` is used.
    private func handlePolishSelection(text preReadText: String? = nil, levelOverride: String? = nil) {
        print("[VOICE-POLISH] handlePolishSelection ENTER level=\(levelOverride ?? "default")")
        guard AXIsProcessTrusted() else {
            print("[VOICE-POLISH] BLOCKED: AX not trusted")
            showToast("Accessibility access required for Polish")
            return
        }
        guard !recordingState.isPolishingSelection else {
            print("[VOICE-POLISH] BLOCKED: already polishing")
            return
        }

        // Use pre-read text if available (avoids double AX round-trip from pill tap).
        let text: String
        if let pre = preReadText {
            text = pre
        } else {
            guard let sel = cursorPaster.getSelectedText(),
                  !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showToast("Select text first, then press the Polish hotkey")
                return
            }
            text = sel
        }
        print("[VOICE-POLISH] text: \"\(text.prefix(60))\" (\(text.count) chars)")

        guard CerebrasPolisher.isAvailable else {
            showToast("Polish requires Cerebras. Add your API key in Settings.")
            return
        }

        recordingState.isPolishingSelection = true

        Task { @MainActor in
            defer {
                self.recordingState.isPolishingSelection = false
                print("[VOICE-POLISH] DONE")
            }

            let preset = PolishPreset.current
            print("[VOICE-POLISH] preset=\(preset.rawValue) level=\(levelOverride ?? "<default>")")

            // Per-call cleanup level override: temporarily set the persisted
            // level so the polisher (which reads UserDefaults internally)
            // uses the level the user clicked in the hover bar. Restore the
            // user's saved preference immediately after the call. This avoids
            // plumbing a new parameter through polishInPlace just to thread
            // this one click.
            let savedLevel = UserDefaults.standard.string(forKey: "cleanupLevel")
            if let level = levelOverride {
                UserDefaults.standard.set(level, forKey: "cleanupLevel")
            }
            defer {
                if let savedLevel = savedLevel {
                    UserDefaults.standard.set(savedLevel, forKey: "cleanupLevel")
                } else if levelOverride != nil {
                    UserDefaults.standard.removeObject(forKey: "cleanupLevel")
                }
            }

            let polished = await Qwen3Polisher.shared.polishInPlace(
                text,
                preset: preset.rawValue
            )

            guard let polished,
                  polished.trimmingCharacters(in: .whitespacesAndNewlines)
                    != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                self.showToast("Already looks great")
                return
            }

            self.cursorPaster.replaceSelection(with: polished)
            self.showToast("✓ Polished")
            print("[VOICE-POLISH] replaced: \"\(polished.prefix(80))\"")
        }
    }

    // MARK: - Permission handling

    /// Single permission-miss handler. Throttles the system prompt to once
    /// per session, deep-links to the right Privacy pane, and starts a
    /// background watcher so that as soon as Accessibility flips to granted
    /// we rebind the hotkey monitors (NSEvent monitors registered before
    /// permission was granted don't deliver events retroactively).
    fileprivate func handleMissingPermissions(micOk: Bool, axOk: Bool, srOk: Bool = true, micStatus: AVAuthorizationStatus) {
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
            return
        }

        if !srOk {
            // Screen Recording is required for meeting capture (system audio
            // via ScreenCaptureKit). If it's missing, meetings would fail
            // silently — we surface it now so the user can grant it before
            // their first auto-captured meeting.
            if !didShowSRPrompt {
                didShowSRPrompt = true
                // CGRequestScreenCaptureAccess() pops the system prompt the
                // first time. It returns immediately; the user grants in
                // System Settings (relaunch required to take effect for SCK).
                _ = CGRequestScreenCaptureAccess()
                openPrivacyPane("Privacy_ScreenCapture")
                showToast("Enable VOICE under Privacy → Screen Recording so meetings can auto-capture.")
            } else {
                showToast("Screen Recording access required for meeting capture — open System Settings → Privacy → Screen Recording.")
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

    // MARK: - Per-app personality routing

    /// Map the frontmost app's bundle ID to a personality name.
    /// Returns nil when auto-personality is disabled, the app is unknown,
    /// or VOICE itself is frontmost. A nil return means "use the user's
    /// current setting unchanged".
    fileprivate func personalityForFrontmostApp() -> String? {
        guard UserDefaults.standard.bool(forKey: "voice.autoPersonality") else { return nil }
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        // Don't override when VOICE itself is frontmost (BigMenu, Settings, pill).
        if bundle == Bundle.main.bundleIdentifier { return nil }

        // Communication / chat apps → casual
        let casualApps: Set<String> = [
            "com.tinyspeck.slackmacOS",
            "com.tinyspeck.slackmacgap",
            "com.facebook.Messenger",
            "ru.keepcoder.Telegram",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.discord",
            "com.hnc.Discord",
            "com.apple.MobileSMS",
        ]

        // Email / document apps → formal
        let formalApps: Set<String> = [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "com.apple.Notes",
            "com.microsoft.Word",
            "com.google.Chrome",   // Docs, Gmail, etc.
            "org.mozilla.firefox",
            "com.apple.Safari",
        ]

        // IDE / terminal apps → neutral (safest default for code contexts)
        let codeApps: Set<String> = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
        ]

        if casualApps.contains(bundle) { return "casual" }
        if formalApps.contains(bundle) { return "formal" }
        if codeApps.contains(bundle)   { return "neutral" }
        return nil  // unknown app → keep user's current setting
    }

    // MARK: - Rich app-context capture (for cloud polish)

    /// Read the focused AX element's role + the focused window title +
    /// the focused field's placeholder. All three are best-effort: any may
    /// be nil if AX isn't granted or the app doesn't expose them.
    ///
    /// Roles seen in practice: `AXTextField` (single-line), `AXTextArea`
    /// (multi-line), `AXComboBox` (search), `AXStaticText` (rich
    /// editors that don't expose proper roles). We map these to short
    /// human-readable hints — the cloud model uses them to pick length.
    fileprivate static func readFocusedAXMetadata() -> (role: String?, windowTitle: String?, placeholder: String?) {
        guard AXIsProcessTrusted() else { return (nil, nil, nil) }

        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return (nil, nil, nil) }
        let element = focused as! AXUIElement

        // Role: kAXRoleAttribute → "AXTextField" etc.
        var roleRef: CFTypeRef?
        let role: String? = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? (roleRef as? String) : nil

        // Placeholder: many text fields expose this even when empty, e.g.
        // Slack shows "Message #design", Gmail shows "Subject" etc.
        var placeholderRef: CFTypeRef?
        let placeholder: String? = AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderRef) == .success
            ? (placeholderRef as? String) : nil

        // Window title: walk up to focused window. Title often carries
        // doc name / channel / subject / file — the strongest signal of
        // WHAT the user is writing about.
        var windowTitle: String? = nil
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let win = windowRef {
            let winEl = win as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(winEl, kAXTitleAttribute as CFString, &titleRef) == .success {
                windowTitle = titleRef as? String
            }
        }

        return (role, windowTitle, placeholder)
    }

    /// Map an AX role string to a short human-readable hint, or nil if
    /// the role isn't informative. Goal: ~2-3 words the cloud prompt can
    /// surface as "<app>: <field type>".
    fileprivate static func describeAXRole(_ role: String?) -> String? {
        guard let role else { return nil }
        switch role {
        case "AXTextField":           return "single-line field"
        case "AXTextArea":            return "multi-line field"
        case "AXSearchField":         return "search field"
        case "AXComboBox":            return "combo box"
        case "AXStaticText":          return nil  // not informative
        default:                       return nil
        }
    }

    /// Truncate a window title to keep prompt tokens bounded. Keeps the
    /// "interesting" half (right side after " - " / " — " / " | " when
    /// possible, since macOS apps put doc/channel/subject AFTER the app
    /// name, e.g. "Slack | design | Maya").
    fileprivate static func compactWindowTitle(_ raw: String?, maxLen: Int = 80) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Many app titles look like "App Name — Document" or "Document - App Name".
        // Prefer the side that doesn't match the bundle's marketing name.
        let trimmed = raw.replacingOccurrences(of: "  ", with: " ")
        if trimmed.count <= maxLen { return trimmed }
        // Title is huge — keep the first chunk (doc/subject usually leads).
        return String(trimmed.prefix(maxLen)) + "…"
    }

    /// Build the rich `appContextLabel` passed to the cloud polisher.
    ///
    /// Combines four signals into one short line the cloud model can use
    /// to set register, length, format:
    ///   1. Static app→string map (Slack message, email, code editor, etc.)
    ///   2. Focused window title (channel/subject/file)
    ///   3. Focused element role (single-line vs multi-line)
    ///   4. Focused element placeholder ("Compose a message", "Search…")
    ///
    /// Examples this produces:
    ///   - "Slack message — Slack | design (multi-line field)"
    ///   - "email — Inbox – Re: Q3 roadmap (multi-line field, placeholder: Compose)"
    ///   - "code editor… — VoiceApp.swift — Voice (multi-line field)"
    ///   - "Slack message"  (when AX is denied — degrades cleanly)
    fileprivate static func buildEnrichedAppContextLabel(
        bundleID: String?,
        front: NSRunningApplication?
    ) -> String? {
        // Base label from the static map (Slack message / email / etc.).
        let baseLabel = Qwen3Polisher.appContextLabel(forBundleID: bundleID)
        // Pull live AX metadata. All three may be nil — degrade gracefully.
        let ax = readFocusedAXMetadata()
        let compactedTitle = compactWindowTitle(ax.windowTitle)
        let roleHint = describeAXRole(ax.role)
        let placeholderTrimmed = ax.placeholder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Build the suffix pieces in priority order.
        var pieces: [String] = []
        if let compactedTitle, !compactedTitle.isEmpty {
            pieces.append(compactedTitle)
        }
        // Combine role + placeholder into a single parenthesized hint when
        // either is present. Keeps the label visually clean.
        var hintParts: [String] = []
        if let roleHint { hintParts.append(roleHint) }
        if let p = placeholderTrimmed, !p.isEmpty, p.count <= 60 {
            hintParts.append("placeholder: \(p)")
        }
        if !hintParts.isEmpty {
            pieces.append("(\(hintParts.joined(separator: ", ")))")
        }

        let suffix = pieces.joined(separator: " ")

        // Combine base + suffix. If the static map didn't recognise the
        // bundle, fall back to localised app name from NSRunningApplication
        // so we still send SOMETHING richer than nil.
        let head: String? = baseLabel ?? front?.localizedName.map { $0 }
        switch (head, suffix.isEmpty) {
        case (nil, true):
            return nil
        case (let h?, true):
            return h
        case (nil, false):
            return suffix
        case (let h?, false):
            return "\(h) — \(suffix)"
        }
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

        // Sample RICH app context too (window title, focused element role,
        // placeholder). This becomes the `appContextLabel` passed to the cloud
        // polisher and is much richer than the static bundle→string map.
        // Cheap — same AX session that just read field context, plus an
        // NSWorkspace lookup. Logs both raw signals and the final label.
        capturedRichAppContext = Self.buildEnrichedAppContextLabel(
            bundleID: targetAppBundleID,
            front: front
        )
        print("[VOICE] rich app context @ record-start: \"\(capturedRichAppContext ?? "<nil>")\"")

        // Auto-personality: if enabled and the frontmost app maps to a specific
        // personality, temporarily override the user's setting for this recording
        // session. The previous value is restored by finishRecording()'s defer.
        if let autoName = personalityForFrontmostApp() {
            let current = UserDefaults.standard.string(forKey: "personalityStyle") ?? "neutral"
            if current != autoName {
                previousPersonality = current
                UserDefaults.standard.set(autoName, forKey: "personalityStyle")
                print("[VOICE-PERSONALITY] auto-override: \(current) → \(autoName) for bundle=\(targetAppBundleID ?? "?")")
            } else {
                // Already on the right personality — no override needed.
                previousPersonality = nil
            }
        } else {
            previousPersonality = nil
        }
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
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        // Hide from Dock + Cmd-Tab when the window closes — back to silent agent mode.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Overlay

    private func setupOverlayPanel() {
        overlayPanel = OverlayPanel(recordingState: recordingState)

        overlayPanel?.onTap = { [weak self] in
            self?.handlePillTap()
        }

        // Hover-bar Polish buttons. The hover bar exposes three levels —
        // "light" (spell+punct), "medium" (grammar+fillers), "heavy" (full
        // rewrite) — and we route the click straight through to
        // handlePolishSelection with that level as the cleanup override.
        overlayPanel?.onPolish = { [weak self] level in
            self?.handlePolishSelection(levelOverride: level)
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

        overlayPanel?.onUndoPaste = { [weak self] in
            self?.undoLastPaste()
        }

        overlayPanel?.onStopMeeting = { [weak self] in
            self?.stopMeetingCapture(reason: "userPillTap")
        }

        overlayPanel?.showPersistent()
    }

    /// Tapping the idle pill:
    ///   - If text is selected → trigger polish-in-place (Wispr Flow style).
    ///   - Otherwise → enter lock/hands-free mode.
    ///
    /// The pill is ALWAYS dedicated to dictation, even while a meeting capture
    /// is running. Meeting capture is started exclusively via the Chrome
    /// extension MeetBridgeServer signal, and stopped via the persistent meeting
    /// dot (right of the pill) or the menu bar's "Stop meeting recording" item.
    /// This lets the user dictate inside a Google Meet while the meeting is
    /// being recorded in the background.
    private func handlePillTap() {
        if recordingState.showingCancelledToast {
            dismissCancelledToast()
            return
        }
        if recordingState.showingUndoPasteToast {
            dismissUndoPasteToast()
            return
        }
        guard !recordingState.isLocked   else { return }
        guard !recordingState.isRecording else { return }

        // Polish-on-tap: if AX is trusted and text is selected, polish it
        // instead of entering recording mode.
        if AXIsProcessTrusted(),
           let sel = cursorPaster.getSelectedText(),
           !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handlePolishSelection(text: sel)
            return
        }

        guard coordinator.transcription.isReady else {
            showToast("Model loading, please wait…")
            return
        }
        print("[VOICE] Pill tap → lock recording")
        enterLockMode()
    }

    // MARK: - Meeting Capture

    /// Start a meeting capture session. Called when a known meeting app is
    /// frontmost and the user taps the idle pill.
    private func startMeetingCapture() {
        guard !recordingState.isCapturingMeeting else { return }

        // Master kill switch — backstop for any auto-detection path that
        // managed to reach this function. Manual user taps go through
        // enterLockMode → handlePillTap and never call this.
        if AppDelegate.isMeetingDetectionDisabled {
            print("[VOICE-MEET] startMeetingCapture refused — voice.disableMeetingDetection is true")
            return
        }

        // Secondary gate — the new opt-in flag. Together with the legacy
        // inverted kill switch above, both must allow auto-meeting capture
        // before SCStream is ever instantiated. The orange screen-recording
        // indicator lights up as soon as we touch ScreenCaptureKit, so we
        // refuse here at the central choke point rather than relying on every
        // caller to gate themselves consistently.
        if !BackgroundActivityGate.meetingDetectionEnabled {
            print("[VOICE-MEET] startMeetingCapture refused — BackgroundActivityGate.meetingDetectionEnabled is false (enableMeetingDetection opt-in not granted, or privacy mode)")
            return
        }

        print("[VOICE-MEET-START] startMeetingCapture invoked: sourceBundle=\(recordingState.meetingSourceBundleID ?? "nil") isRecording=\(recordingState.isRecording) isLocked=\(recordingState.isLocked)")

        // (Spotify warning removed — user found it annoying. SCK's
        // excludingApplications: denylist handles media app audio now.)

        Task { @MainActor in
            // Request ScreenCaptureKit permission on first use.
            let granted = await MeetingCaptureService.requestPermission()
            guard granted else {
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Screen recording permission required for meeting capture. Enable in System Settings \u{2192} Privacy \u{2192} Screen Recording."]
                )
                return
            }

            do {
                recordingState.isCapturingMeeting = true
                recordingState.activeMeetingId = UUID()
                // Switch icon timer to 1Hz so the running-clock tooltip ticks.
                scheduleMenuBarIconTimer()
                refreshMenuBarIcon()
                // Pass the source app into the service so it persists on the saved Meeting.
                meetingCaptureService.sourceApp = recordingState.meetingSourceBundleID
                // Pass any participant names already scraped by the Chrome extension.
                // The bridge may also push more names mid-call; we re-sync at stop.
                meetingCaptureService.participantNames = recordingState.meetingParticipantNames
                try await meetingCaptureService.startCapture()
                print("[VOICE-MEETING] Capture started: \(recordingState.activeMeetingId?.uuidString ?? "<no-id>")")

                // EXPLICIT VISIBILITY: post a system-wide banner notification
                // so the user can't miss that screen + audio capture has begun.
                // Carries an actionable "Stop" button (and tapping the body
                // also stops) — both routes post `.voiceStopMeetingRequested`,
                // which the existing observer below converts into the
                // off-limits `stopMeetingCapture()` call.
                self.postMeetingRecordingNotification()

                // LAZY-TRANSCRIBE: no 30s draft checkpoint needed — there's
                // no in-stream transcript to checkpoint. The audio file on disk
                // IS the durable artifact; if Voice crashes mid-meeting, the
                // orphan-WAV recovery on next launch will import the file and
                // transcribe it. Lightweight row-level checkpoint instead: save
                // an empty Meeting row pointing at the live audio path every
                // 30s so the row appears in the UI immediately.
                let meetingIdForCheckpoint = self.recordingState.activeMeetingId ?? UUID()
                let startedAt = Date()
                let sourceForCheckpoint = self.recordingState.meetingSourceBundleID
                self.meetingDraftCheckpointTask?.cancel()
                self.meetingDraftCheckpointTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        guard let self, !Task.isCancelled, self.recordingState.isCapturingMeeting else { break }
                        let snapshot = MeetingDraftSnapshot(
                            meetingId: meetingIdForCheckpoint,
                            title: "Recording — \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                            date: startedAt,
                            durationSeconds: Double(self.meetingCaptureService.durationSeconds),
                            segments: [],
                            audioFilePath: self.meetingCaptureService.audioFileURL?.path,
                            sourceApp: sourceForCheckpoint,
                            participantNames: self.recordingState.meetingParticipantNames
                        )
                        self.meetingRecovery.checkpointDraft(snapshot)
                    }
                }

                // Mirror durationSeconds every 0.5s so the pill counter updates live.
                Task { @MainActor in
                    while self.recordingState.isCapturingMeeting {
                        self.recordingState.meetingDurationSeconds = self.meetingCaptureService.durationSeconds
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    self.recordingState.meetingDurationSeconds = 0
                }

                // LAZY-TRANSCRIBE: meetingLiveTranscript stays empty — no live
                // transcript to mirror. Keep the cleanup task in place so the
                // UI clears any stale value when capture ends.
                Task { @MainActor in
                    while self.recordingState.isCapturingMeeting {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    self.recordingState.meetingLiveTranscript = []
                }

                // Duration warnings (30/60/120 min toasts, 4h hard stop)
                // + crash-safety checkpoint every 5 minutes.
                Task { @MainActor in
                    var warnedAt: Set<Int> = []
                    var lastCheckpointSeconds = 0
                    let warnMinutes = [30, 60, 120]
                    let hardStopSeconds = 4 * 60 * 60   // 4 hours
                    let checkpointInterval = 5 * 60      // checkpoint every 5 min
                    while self.recordingState.isCapturingMeeting {
                        let elapsed = self.meetingCaptureService.durationSeconds
                        // Duration warnings.
                        for minutes in warnMinutes {
                            let threshold = minutes * 60
                            if elapsed >= threshold && !warnedAt.contains(minutes) {
                                warnedAt.insert(minutes)
                                let label = minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
                                self.showToast("Meeting recording: \(label)")
                            }
                        }
                        // Hard stop at 4h.
                        if elapsed >= hardStopSeconds {
                            print("[VOICE-MEETING] Hard stop: 4h limit reached")
                            self.showToast("Meeting recording stopped — 4h limit reached.")
                            self.stopMeetingCapture(reason: "hardLimit4h")
                            break
                        }
                        // Crash-safety: checkpoint segments to UserDefaults every 5 min.
                        if elapsed - lastCheckpointSeconds >= checkpointInterval {
                            lastCheckpointSeconds = elapsed
                            self.checkpointMeetingDraft()
                            print("[VOICE-MEETING] Draft checkpoint: \(elapsed)s elapsed")
                        }
                        try? await Task.sleep(nanoseconds: 30_000_000_000)  // check every 30s
                    }
                }
            } catch {
                recordingState.isCapturingMeeting = false
                recordingState.activeMeetingId = nil
                print("[VOICE-MEETING] startCapture failed: \(error)")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Could not start meeting capture: \(error.localizedDescription)"]
                )
            }
        }
    }

    // MARK: Meeting-active system notification
    //
    // Identifier + category strings used to post / dismiss the persistent
    // banner that shows while meeting capture is live. The category carries
    // a "Stop" action button so the user can kill the recording from the
    // Notification Center without going back to the menu bar.
    static let kMeetingActiveNotifID = "voice.meetingActive"
    static let kMeetingActiveCategory = "VOICE_MEETING_ACTIVE"
    static let kMeetingStopAction = "VOICE_STOP_MEETING"

    /// Register the actionable category once. Idempotent — UN merges by ID.
    /// Also installs a tiny delegate proxy that intercepts taps on the Stop
    /// action and forwards everything else to the existing `MeetingNotifier`
    /// delegate so the "transcript ready" tap routing still works.
    fileprivate func ensureMeetingNotificationCategoryRegistered() {
        let stop = UNNotificationAction(
            identifier: AppDelegate.kMeetingStopAction,
            title: "Stop Recording",
            options: [.destructive, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: AppDelegate.kMeetingActiveCategory,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        // Swap in our proxy delegate the first time we register the category.
        // The proxy forwards every call to MeetingNotifier.delegate by default
        // and only intercepts when it sees our specific Stop action.
        if !(center.delegate is MeetingActiveNotificationDelegate) {
            MeetingActiveNotificationDelegate.shared.fallback = MeetingNotifier.delegate
            center.delegate = MeetingActiveNotificationDelegate.shared
        }
    }

    /// Fire (or refresh) the "Voice is recording your meeting" banner.
    /// Idempotent on the same identifier — UN replaces an existing one with
    /// the same id, so calling this on every start is safe.
    func postMeetingRecordingNotification() {
        ensureMeetingNotificationCategoryRegistered()
        let center = UNUserNotificationCenter.current()

        // Defensive permission check. If the user never saw the auth prompt
        // OR denied it, our notification call would silently fail and they'd
        // wonder why no banner appeared. Re-request on .notDetermined and
        // surface a clear toast on .denied so the user knows to enable it
        // in System Settings.
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    print("[VOICE-NOTIF] re-requested auth at meeting start, granted=\(granted)")
                    if granted {
                        DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
                    }
                }
            case .denied:
                print("[VOICE-NOTIF] notifications DENIED — banner won't show. Toast guidance fired.")
                DispatchQueue.main.async {
                    self?.showToast("Recording started. Enable Notifications in System Settings → Voice to see banners.")
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
            @unknown default:
                DispatchQueue.main.async { self?.actuallyPostMeetingNotification() }
            }
        }
    }

    /// Actual UN post call. Split out so the auth-check path can defer it.
    private func actuallyPostMeetingNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Voice: Recording meeting"
        content.body = "Click to stop."
        content.sound = .default
        content.categoryIdentifier = AppDelegate.kMeetingActiveCategory
        content.userInfo = ["voiceMeetingActiveBanner": true]
        let request = UNNotificationRequest(
            identifier: AppDelegate.kMeetingActiveNotifID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[VOICE-NOTIF] meeting-active post failed: \(error.localizedDescription)")
            } else {
                print("[VOICE-NOTIF] meeting-active banner posted")
            }
        }
    }

    /// Dismiss the meeting-active banner once recording stops, so it doesn't
    /// linger in Notification Center claiming the meeting is still live.
    func dismissMeetingRecordingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [AppDelegate.kMeetingActiveNotifID])
        center.removePendingNotificationRequests(withIdentifiers: [AppDelegate.kMeetingActiveNotifID])
    }

    /// Stop the active meeting capture session. Called when the user taps
    /// Stop the active meeting capture session. Saves raw transcript directly —
    /// no AI summarization. Post-processing happens externally when needed.
    private func stopMeetingCapture(reason: String = "userMenu") {
        guard recordingState.isCapturingMeeting else { return }
        recordingState.isCapturingMeeting = false
        let meetingId = recordingState.activeMeetingId ?? UUID()
        recordingState.activeMeetingId = nil
        // Cancel any pending grace timer for participants-left auto-stop.
        meetingParticipantsLeftTask?.cancel()
        meetingParticipantsLeftTask = nil
        // Capture pre-stop snapshot for the structured end log.
        let stopReason = reason
        let stopElapsed = meetingCaptureService.durationSeconds
        let stopAudioFile = meetingCaptureService.audioFileURL?.lastPathComponent ?? "nil"

        // Tear down the "Recording meeting" system banner so it doesn't
        // hang around in Notification Center claiming we're still live.
        dismissMeetingRecordingNotification()

        // Drop icon timer back to 5s idle rate now that capture has stopped.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()

        // Stop the crash-safety draft checkpoint timer.
        meetingDraftCheckpointTask?.cancel()
        meetingDraftCheckpointTask = nil

        Task { @MainActor in
            // Sync any names the bridge has pushed since startCapture(): the
            // participant tiles often render after the call becomes active, so
            // names that arrived mid-call still need to be threaded in.
            if !recordingState.meetingParticipantNames.isEmpty {
                meetingCaptureService.participantNames = recordingState.meetingParticipantNames
            }
            let (segments, capturedSourceApp, capturedAudioURL, capturedParticipantNames, capturedSpeakerEventsJson) = await meetingCaptureService.stopCapture()

            // Reset the names cache now that this session is over.
            recordingState.meetingParticipantNames = []

            // Clean stop — discard crash-safety checkpoint.
            UserDefaults.standard.removeObject(forKey: crashDraftKey)

            // Save even with no transcript — audio file is still valuable.
            // (Transcription can fail on short/quiet audio without it being an error.)
            if segments.isEmpty {
                print("[VOICE-MEETING] No segments captured — saving audio-only record")
            }

            // Use actual elapsed time from service if available, fall back to
            // segment-estimated duration so even audio-only saves have sane duration.
            let elapsedFromService = Double(meetingCaptureService.durationSeconds)
            let totalDuration: TimeInterval
            if elapsedFromService > 0 {
                totalDuration = elapsedFromService
            } else if let last = segments.last {
                totalDuration = last.startTime + Double(last.text.split(separator: " ").count) / 2.5
            } else {
                totalDuration = 0
            }

            // Anything shorter than 3 minutes isn't really a meeting — it's a
            // quick note / voice memo. Classify it as `.dictation` so it
            // doesn't pollute the Meetings tab with 30-second drive-by
            // recordings. (3-min threshold matches the user's explicit rule.)
            let meetingKind: MeetingKind = totalDuration >= 300 ? .meeting : .dictation

            let meeting = Meeting(
                id: meetingId,
                title: generateMeetingTitle(
                    from: segments,
                    sourceApp: capturedSourceApp,
                    participantNames: capturedParticipantNames
                ),
                date: Date(),
                duration: totalDuration,
                segments: segments,
                audioFilePath: capturedAudioURL?.path,
                kind: meetingKind,
                sourceApp: capturedSourceApp,
                participantNames: capturedParticipantNames,
                speakerEventsJson: capturedSpeakerEventsJson
            )

            saveMeetingToStorage(meeting)
            fetchMeetingsIntoState()
            recordingState.recordMeeting(durationSeconds: Int(totalDuration))
            print("[VOICE-MEETING] Saved \"\(meeting.title)\" — \(segments.count) segments, \(Int(totalDuration))s")
            let durationMinutes = Int(totalDuration) / 60
            print("[VOICE-MEET-END] duration=\(durationMinutes)m elapsedSeconds=\(stopElapsed) audioFile=\(stopAudioFile) segments=\(segments.count) stopReason=\(stopReason)")

            // LAZY-TRANSCRIBE: kick off post-hoc transcription against the
            // saved audio file. Runs in background — user gets a toast when
            // it lands. Only fires when segments are empty (i.e. always under
            // the new lazy path; legacy meetings that already had segments
            // skip this).
            if segments.isEmpty,
               let audioPath = capturedAudioURL?.path,
               FileManager.default.fileExists(atPath: audioPath),
               totalDuration >= 5 {
                self.showToast("Meeting saved — transcribing…")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Wait for the engine to be ready (it's almost certainly
                    // already ready, but the meeting could have ended during a
                    // model reload).
                    while !self.coordinator.transcription.isReady {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { return }
                    }
                    if let updated = await self.meetingRecovery.retranscribe(meeting: meeting) {
                        self.fetchMeetingsIntoState()
                        let preview = updated.segments.first?.text.prefix(40) ?? ""
                        self.showToast("Transcript ready — \(updated.segments.count) segments. \(preview)")
                    } else {
                        self.showToast("Couldn't transcribe — audio saved, try again from the meeting row.")
                    }
                }
            }
        }
    }

    // MARK: - Meeting Capture Helpers

    /// Build a human title like "Night May 20th, Meet with Alice and Bob".
    ///
    /// Title shape:
    ///   `<TimeOfDay> <Month> <DayOrdinal>[, Meet with <Names>]`
    ///
    /// Name priority:
    ///   1. `participantNames` from the Chrome extension (scraped DOM).
    ///   2. Fallback: `extractNamesFromSegments` regex pass over the transcript.
    /// The local user (from `voice.userName` UserDefaults) is filtered out
    /// case-insensitively before names are formatted.
    private func generateMeetingTitle(
        from segments: [TranscriptSegment],
        sourceApp: String? = nil,
        participantNames: [String] = []
    ) -> String {
        // Time-of-day bucket.
        let hour = Calendar.current.component(.hour, from: Date())
        let timeLabel: String
        switch hour {
        case 5..<11:   timeLabel = "Morning"
        case 11..<13:  timeLabel = "Midday"
        case 13..<17:  timeLabel = "Afternoon"
        case 17..<21:  timeLabel = "Evening"
        default:       timeLabel = "Night"
        }

        // "May 20th" — month name + ordinal day.
        let now = Date()
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM"
        let monthStr = monthFmt.string(from: now)
        let day = Calendar.current.component(.day, from: now)
        let dayStr = "\(day)\(Self.ordinalSuffix(for: day))"

        // Filter the local user out of the candidate name list.
        let userName = (UserDefaults.standard.string(forKey: "voice.userName") ?? "").trimmingCharacters(in: .whitespaces)
        func notUser(_ name: String) -> Bool {
            guard !userName.isEmpty else { return true }
            return name.caseInsensitiveCompare(userName) != .orderedSame
        }

        // Resolve names: extension wins if it gave us anything, otherwise
        // fall back to the legacy transcript regex.
        var rawNames: [String]
        if !participantNames.isEmpty {
            rawNames = participantNames
        } else {
            rawNames = extractNamesFromSegments(segments)
        }

        // Dedup (case-insensitive, preserving first-seen casing) + user filter.
        var seen = Set<String>()
        let names: [String] = rawNames.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // Use just the first word ("Alice Smith" → "Alice") to keep titles tight.
            let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            guard notUser(firstWord), notUser(trimmed) else { return nil }
            let key = firstWord.lowercased()
            if seen.contains(key) { return nil }
            seen.insert(key)
            return firstWord
        }

        let base = "\(timeLabel) \(monthStr) \(dayStr)"
        guard !names.isEmpty else {
            // Solo recording: nobody else was ever detected (Chrome extension
            // gave us no names and the transcript regex pulled nothing). The
            // old code dropped "Meet" entirely; explicitly label this as a
            // solo recording so the title reads coherently.
            return "\(base), Solo recording"
        }
        return "\(base), Meet with \(Self.formatNameList(names))"
    }

    /// "1st", "2nd", "3rd", "4th"… English ordinal suffix for the given day.
    private static func ordinalSuffix(for day: Int) -> String {
        let mod100 = day % 100
        if (11...13).contains(mod100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Format participant names for inclusion in the meeting title.
    /// - 1 name:  "Alice"
    /// - 2 names: "Alice and Bob"
    /// - 3 names: "Alice, Bob, and Charlie"
    /// - 4+ names: "Alice, Bob, and 2 others"
    private static func formatNameList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]), and \(names[2])"
        default:
            let extra = names.count - 2
            return "\(names[0]), \(names[1]), and \(extra) others"
        }
    }

    /// Extract up to 3 likely proper names from the transcript text.
    /// Strategy: find capitalized words that are NOT at the start of a sentence
    /// and NOT common non-name words. Rank by frequency and take the top 3.
    private func extractNamesFromSegments(_ segments: [TranscriptSegment]) -> [String] {
        // Case-insensitive stoplist. Anything that looks like a name but is
        // really a common English word, weekday, month, calendar reference, or
        // tool name. Compared lowercase to dodge the regex's capitalization
        // requirement (e.g. "Today", "Tomorrow", "Yeah", "Cool" all start with
        // a capital letter at the start of a sentence and would otherwise be
        // accepted as candidates).
        let skipWordsLC: Set<String> = [
            // Pronouns / articles / determiners
            "i", "the", "a", "an", "this", "that", "these", "those",
            "it", "he", "she", "we", "they", "you", "me", "him", "her", "us", "them",
            // Aux verbs
            "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did",
            "will", "would", "could", "should", "may", "might", "must", "shall",
            "can", "cannot",
            // Conjunctions / prepositions
            "and", "but", "or", "so", "yet", "for", "nor",
            "in", "on", "at", "by", "to", "of", "up", "as", "if",
            "from", "with", "into", "onto", "out", "off", "over", "under",
            // Interjections / fillers / casual
            "ok", "okay", "yes", "no", "hi", "hey", "uh", "um", "oh",
            "yeah", "yep", "nope", "nah", "yo", "cool", "nice", "great",
            "right", "well", "sure", "wait", "stop", "go", "now", "then",
            "really", "actually", "basically", "literally", "honestly", "anyway",
            "alright", "fine", "sorry", "thanks", "thank", "please", "welcome",
            "maybe", "perhaps", "probably", "definitely", "absolutely",
            // Calendar references
            "today", "tomorrow", "yesterday", "tonight",
            "morning", "afternoon", "evening", "night", "noon", "midnight",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
            "minute", "minutes", "hour", "hours", "second", "seconds",
            "week", "weeks", "month", "months", "year", "years",
            // Software / tool names that frequently appear in meeting transcripts
            "google", "meet", "zoom", "teams", "discord", "slack", "facetime",
            "voice", "chrome", "safari", "firefox", "edge", "browser",
            "outlook", "gmail", "notion", "figma", "linear", "github",
            "claude", "chatgpt", "openai", "anthropic",
            "mac", "windows", "linux", "iphone", "android",
            // Generic
            "everyone", "everybody", "someone", "somebody", "anyone", "anybody",
            "nobody", "nothing", "something", "anything",
        ]

        let fullText = segments.map(\.text).joined(separator: " ")
        // Match capitalized words that are preceded by a space (not sentence-start).
        // "sentence start" words are those after . ! ? or at string start — we exclude those.
        let pattern = #"(?<=\s)([A-Z][a-z]{1,14})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(fullText.startIndex..., in: fullText)
        var freq: [String: Int] = [:]
        for match in regex.matches(in: fullText, range: range) {
            if let r = Range(match.range(at: 1), in: fullText) {
                let word = String(fullText[r])
                guard !skipWordsLC.contains(word.lowercased()) else { continue }
                freq[word, default: 0] += 1
            }
        }
        // Require at least 2 occurrences to be confident it's a name.
        // If nothing survives the stoplist + frequency filter, return [] so the
        // caller falls back to "Night May 20th, Meet" instead of e.g.
        // "Night May 20th, Meet with Today and Slack".
        let candidates = freq
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        return Array(candidates)
    }

    // MARK: - Crash Recovery

    private var crashDraftKey: String { "voice.meetingCrashDraft" }

    /// Called every 5 minutes during a capture session. Encodes live segments
    /// to UserDefaults so a crash / power-loss doesn't lose the recording.
    private func checkpointMeetingDraft() {
        let segments = meetingCaptureService.liveTranscript
        guard !segments.isEmpty else { return }
        if let data = try? JSONEncoder().encode(segments) {
            UserDefaults.standard.set(data, forKey: crashDraftKey)
        }
    }

    /// Called on next launch. If a crash draft exists, recover it as a
    /// saved (unsummarized) meeting and clear the draft.
    private func recoverCrashedMeetingIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: crashDraftKey),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data),
              !segments.isEmpty else { return }

        UserDefaults.standard.removeObject(forKey: crashDraftKey)

        let title = generateMeetingTitle(from: segments) + " (recovered)"
        let totalDuration = segments.last.map {
            $0.startTime + Double($0.text.split(separator: " ").count) / 2.5
        } ?? 0

        let meeting = Meeting(
            id: UUID(),
            title: title,
            date: Date(),
            duration: totalDuration,
            segments: segments,
            kind: .meeting
        )
        saveMeetingToStorage(meeting)
        fetchMeetingsIntoState()
        showToast("Recovered \(segments.count) segments from last session.")
        print("[VOICE-MEETING] Crash recovery: saved \(segments.count) segments as \"\(title)\"")
    }

    /// Persist a Meeting via the coordinator's storage layer.
    private func saveMeetingToStorage(_ meeting: Meeting) {
        do {
            try coordinator.saveMeeting(meeting)
        } catch {
            print("[VOICE-MEETING] Storage error: \(error)")
        }
    }

    /// Single funnel for "(re)read meetings from disk and push into UI state".
    ///
    /// Calls the *throwing* `storage.fetchAllMeetings()` directly so it can
    /// distinguish between "read returned zero rows" (.loaded with empty array
    /// → empty-state UI) and "read threw" (.error with the underlying message
    /// → error-state UI with Retry). The error path is what the BigMenuWindow
    /// Meetings tab surfaces — without this, every storage failure would
    /// silently render as "no meetings yet" which is misleading and hides
    /// real DB problems.
    @MainActor
    func fetchMeetingsIntoState() {
        recordingState.meetingsLoadState = .loading
        do {
            let fresh = try coordinator.storage.fetchAllMeetings()
                .sorted { $0.date > $1.date }
            recordingState.meetings = fresh
            recordingState.meetingsLoadState = .loaded
        } catch {
            let reason = (error as NSError).localizedDescription
            print("[VOICE-MEETING] load failed: \(reason)")
            recordingState.meetingsLoadState = .error(reason)
            // Intentionally do NOT clobber `recordingState.meetings` on
            // failure — if a previous load succeeded, the user keeps seeing
            // their existing list while we surface the error banner.
        }
    }

    /// Public reload, callable from UI views that need to refresh after
    /// a manual re-transcribe (BigMenu meeting row "Transcribe now" button).
    @MainActor
    func reloadMeetingsFromDisk() {
        fetchMeetingsIntoState()
    }

    /// Return a friendly name ("Spotify", "Music") if a music app is currently
    /// running with audio likely playing. Heuristic: any of the known media
    /// bundle IDs is in NSWorkspace.runningApplications. We can't tell from
    /// here whether it's *actually* playing (would need AppleScript or
    /// per-app audio APIs), so we err on the side of the warning fires when
    /// the app is open — easy enough for the user to dismiss.
    private func currentlyPlayingMusicApp() -> String? {
        let musicApps: [(bundleID: String, friendly: String)] = [
            ("com.spotify.client", "Spotify"),
            ("com.apple.Music", "Music"),
            ("io.mpv", "mpv"),
            ("org.videolan.vlc", "VLC"),
            ("com.apple.podcasts", "Podcasts"),
            ("com.apple.TV", "TV"),
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for app in musicApps where running.contains(app.bundleID) {
            return app.friendly
        }
        return nil
    }

    /// One-shot pass at launch: any meeting <3 min currently classified as
    /// `.meeting` gets reclassified to `.dictation`. The Meetings tab is for
    /// real meetings; short voice memos shouldn't pollute it.
    @MainActor
    private func reclassifyShortMeetings() {
        let meetings = coordinator.fetchAllMeetings()
        var fixed = 0
        for m in meetings where m.kind == .meeting && m.duration < 300 {
            var updated = m
            updated.kind = .dictation
            do {
                try coordinator.saveMeeting(updated)
                fixed += 1
            } catch {
                print("[VOICE-CLEANUP] reclassify \(m.id) failed: \(error)")
            }
        }
        if fixed > 0 {
            print("[VOICE-CLEANUP] reclassified \(fixed) short meetings as dictations")
            reloadMeetingsFromDisk()
        }
    }

    /// Replace stuck checkpoint titles ("Live meeting (in progress) — …" /
    /// "Recording — …") with a clean derived title. Runs at launch so the
    /// meetings list never shows the in-flight placeholder once a session is
    /// over. Keeps the row's date + source app + duration intact.
    @MainActor
    private func cleanUpStaleMeetingTitles() {
        let stalePrefixes = [
            "Live meeting (in progress)",
            "Recording —",
            "Recording ",
            "Recovered meeting",      // From the orphan auto-importer
            "Untranscribed recording",
            "Afternoon recording",
            "Morning recording",
            "Evening recording",
            "Night recording",
            "Solo recording",
            "Afternoon May",          // Old date-bucket placeholders
            "Morning May",
            "Evening May",
            "Night May",
        ]
        let meetings = coordinator.fetchAllMeetings()
        for m in meetings {
            let hasStaleTitle = stalePrefixes.contains { m.title.hasPrefix($0) }
            guard hasStaleTitle else { continue }
            // Don't touch the row that's CURRENTLY being recorded.
            if recordingState.isCapturingMeeting,
               recordingState.activeMeetingId == m.id { continue }

            // If this meeting has real transcript content, derive a better
            // title from it (first substantive line / participant names).
            // Otherwise fall back to a clean date-based placeholder.
            let newTitle: String
            if !m.segments.isEmpty {
                newTitle = deriveTitleFromTranscript(meeting: m)
            } else {
                newTitle = humanReadableMeetingFallbackTitle(for: m)
            }
            guard newTitle != m.title else { continue }
            var updated = m
            updated.title = newTitle
            do {
                try coordinator.saveMeeting(updated)
                print("[VOICE-CLEANUP] retitled meeting \(m.id) → \"\(newTitle)\"")
            } catch {
                print("[VOICE-CLEANUP] retitle failed for \(m.id): \(error)")
            }
        }
        reloadMeetingsFromDisk()
    }

    /// Build a title from an existing transcript — mirrors the logic in
    /// MeetingRecoveryService.deriveMeetingTitle so retitling a recovered
    /// meeting at launch produces the same title shape as a freshly-
    /// retranscribed one.
    private func deriveTitleFromTranscript(meeting m: Meeting) -> String {
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: m.date)
        }()
        let me = (UserDefaults.standard.string(forKey: "voice.userName") ?? "").trimmingCharacters(in: .whitespaces)
        let others = m.participantNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(me) != .orderedSame }
        if !others.isEmpty {
            let joined: String
            if others.count == 1 { joined = others[0] }
            else if others.count == 2 { joined = "\(others[0]) and \(others[1])" }
            else { joined = "\(others.prefix(2).joined(separator: ", ")) and \(others.count - 2) others" }
            return "Meeting with \(joined) · \(dateStr)"
        }
        if let seg = m.segments.first(where: { $0.text.split(separator: " ").filter({ !$0.isEmpty }).count >= 5 }) {
            let cleaned = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            let shortened: String
            if cleaned.count <= 60 { shortened = cleaned }
            else {
                let cutoff = cleaned.index(cleaned.startIndex, offsetBy: 60)
                shortened = String(cleaned[..<cutoff]) + "…"
            }
            return "\(shortened) · \(dateStr)"
        }
        return humanReadableMeetingFallbackTitle(for: m)
    }

    /// Build a clean fallback title for a meeting that doesn't have one yet.
    /// Examples: "Morning meeting · May 25", "Untranscribed recording · May 25".
    private func humanReadableMeetingFallbackTitle(for m: Meeting) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: m.date)
        let hour = Calendar.current.component(.hour, from: m.date)
        let timeBucket: String = {
            switch hour {
            case 5..<12:  return "Morning"
            case 12..<17: return "Afternoon"
            case 17..<22: return "Evening"
            default:      return "Night"
            }
        }()
        let appLabel: String = {
            switch m.sourceApp {
            case "com.google.meet": return "Meet"
            case "us.zoom.xos":     return "Zoom"
            case "com.microsoft.teams2": return "Teams"
            case "com.cisco.webex.meetings": return "Webex"
            default: return "recording"
            }
        }()
        return "\(timeBucket) \(appLabel) · \(dateStr)"
    }

    /// Walk every meeting's audioFilePath and rewrite a valid WAV header for
    /// any file whose RIFF chunk-size field still says "0 bytes" (the file
    /// was killed mid-write before MeetingCaptureService got to flush the
    /// final header). Without this, AVFoundation refuses to decode the file
    /// and "Couldn't transcribe — audio may be corrupted" fires forever.
    @MainActor
    private func repairBrokenWAVHeaders() async {
        let meetings = coordinator.fetchAllMeetings()
        let candidates = meetings.compactMap { m -> URL? in
            guard let path = m.audioFilePath else { return nil }
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            guard path.hasSuffix(".wav") else { return nil }
            return URL(fileURLWithPath: path)
        }
        for url in candidates {
            do {
                try WAVHeaderRepair.repairIfNeeded(at: url)
            } catch {
                print("[VOICE-WAV-REPAIR] \(url.lastPathComponent): \(error)")
            }
        }
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
            recordingState.sessionCancelled = false
            coordinator.startRecording()
            SoundEffects.playStart()
            // Arm the max-duration cap for this safety-net start. (The far more
            // common double-tap-into-lock path keeps the running recording and
            // its already-armed Path 3 watchdog — same session ID, measured
            // from the true start — so we only arm when WE started fresh here.)
            armMaxDurationWatchdog()
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

    // MARK: - Max-duration watchdog

    /// Arm the max-duration watchdog for the dictation that just started.
    /// Keyed off `recordingStartedAt` (the ACTUAL recording start), so it fires
    /// `maxDictationDuration` after recording began regardless of hotkey state —
    /// this is what makes it a safety net for a missed hotkey-up. Cancels any
    /// prior watchdog first so a fresh recording never inherits a stale timer.
    ///
    /// Call this from every dictation-start site (PTT fresh press, re-press
    /// while transcribing, and the lock-mode safety-net start).
    private func armMaxDurationWatchdog() {
        maxDurationWatchdog?.cancel()
        // Snapshot the session this watchdog belongs to. If a NEW recording
        // starts before we fire, the session ID rotates and we bail rather than
        // committing the wrong (newer) recording.
        let watchedSession = recordingState.recordingSessionID
        let startedAt = recordingStartedAt ?? Date()
        maxDurationWatchdog = Task { @MainActor [weak self] in
            // Sleep until the cap measured from the TRUE start time, not from
            // now — Path 2/3 set recordingStartedAt to hotkeyService.pressDownAt
            // which may already be slightly in the past.
            let remaining = self?.maxDictationDuration ?? 300
            let elapsed = Date().timeIntervalSince(startedAt)
            let sleepFor = max(0, remaining - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only commit if THIS recording is still the active one and still
            // recording. If it already finished/cancelled normally, or a newer
            // session took over, do nothing — the normal path cancelled us, or
            // the new session has its own watchdog.
            guard self.recordingState.isRecording,
                  self.recordingState.recordingSessionID == watchedSession else {
                return
            }
            let mins = Int((self.maxDictationDuration / 60).rounded())
            print("[VOICE-MAXLEN] recording hit \(Int(self.maxDictationDuration))s cap (session=\(watchedSession)) → auto-committing as if hotkey released")
            // Rotate the session ID so any concurrent manual-press snapshot
            // (taken just before this watchdog fired) is invalidated and bails.
            self.recordingState.recordingSessionID = UUID()
            // Mirror exitLockMode()'s teardown so a locked recording commits
            // cleanly (PTT recordings aren't locked, so this is a no-op for them).
            if self.recordingState.isLocked { self.exitLockMode() }
            // Commit down the SAME finish path a hotkey release uses — the
            // dictation is transcribed, polished, pasted and saved. Never dropped.
            self.finishRecording()
            self.showToast("Recording reached \(mins) min limit — saved.")
        }
    }

    /// Cancel the max-duration watchdog. Called from every normal
    /// finish/cancel/discard path so the watchdog can never double-fire after
    /// a recording has already ended.
    private func cancelMaxDurationWatchdog() {
        maxDurationWatchdog?.cancel()
        maxDurationWatchdog = nil
    }

    /// X button — stop transcribing, but RETAIN the recording.
    ///
    /// Cancel no longer throws the user's words away. We stop active
    /// transcription/CPU work (claim the recording synchronously, which tears
    /// down the audio engine) but KEEP the audio file on disk and save a record
    /// to the dictation History marked as cancelled/unpolished — with whatever
    /// partial transcript we already have. The result still shows up in the
    /// BigMenu History (audio retained, recoverable); it just isn't pasted and
    /// isn't fully polished. The "Transcript cancelled / Undo" toast still works
    /// exactly as before for an immediate re-paste.
    private func cancelRecording() {
        // Restore auto-personality override if one was in effect — cancel
        // never pastes so we never enter finishRecording()'s defer.
        if let saved = previousPersonality {
            UserDefaults.standard.set(saved, forKey: "personalityStyle")
            previousPersonality = nil
            print("[VOICE-PERSONALITY] restored on cancel: \(saved)")
        }
        recordingState.sessionCancelled = true
        print("[VOICE] Cancel → stop transcribing, retain recording")
        // Stop the max-duration watchdog — this recording is ending.
        cancelMaxDurationWatchdog()
        // Claim synchronously so we (a) atomically stop the audio engine — no
        // more CPU burned transcribing — and (b) capture the on-disk audio URL.
        // Unlike before, we do NOT delete this file; it's the user's retained
        // recording.
        let claimedForCancel = recordingState.isRecording ? coordinator.claimRecordingSync() : nil
        let retainedAudioURL = claimedForCancel?.audioURL
        // Snapshot the partial transcript we already have RIGHT NOW (sync, on the
        // main actor) as a fallback — showCancelledToast() consumes/clears
        // currentTranscript, and a superseding session could mutate it before our
        // async drain returns. The drain's return value is preferred; this is the
        // safety net.
        let partialSegments = recordingState.currentTranscript
        let partialFromSegments = partialSegments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialLivePreview = recordingState.livePartialText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture paste-target + duration for the History row, same as the
        // commit path does.
        let capturedTargetForCancel = targetAppBundleID
        let startedAtForCancel = recordingStartedAt
        // BUGFIX: clear pendingRecordingStart so the pill doesn't get stuck in
        // the .recording phase if cancel arrived between Path 3 sync mutations.
        recordingState.pendingRecordingStart = false
        recordingStartedAt = nil
        exitLockMode()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drain the engine on the claimed recording. This flushes the final
            // ASR tail AND (crucially) leaves the audio file on disk when there's
            // real speech — RecordingCoordinator only deletes sub-300ms clips.
            // We deliberately do NOT delete the file afterwards.
            let drained = await self.coordinator.stopRecording(claiming: claimedForCancel)
            let drainedText = drained
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Best transcript we can salvage: prefer the freshly-drained final
            // text, then the segments we snapshotted, then the live preview.
            let bestTranscript = !drainedText.isEmpty
                ? drainedText
                : (!partialFromSegments.isEmpty ? partialFromSegments : partialLivePreview)

            // Does a retained audio file actually exist on disk? (If cancel hit
            // during spin-up there may be no URL, or the clip was too short and
            // the coordinator already reaped it — in that case there's nothing
            // meaningful to retain.)
            let audioExists: Bool = {
                guard let url = retainedAudioURL else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }()

            if audioExists || !bestTranscript.isEmpty {
                let duration = startedAtForCancel.map { Int(Date().timeIntervalSince($0)) }
                // Persist to History via the SAME RecentDictations.add API the
                // normal pipeline uses, so the cancelled item renders identically
                // in the BigMenu. Marked unpolished: polished == the partial text,
                // raw == nil, polishMs == nil (polish never ran), and tagged
                // cancelled (with the retained audio path) via the new fields.
                // When there's no transcript at all but we DID keep audio, store a
                // placeholder so the row still appears and the audio is reachable.
                let storedText = bestTranscript.isEmpty ? "(cancelled — audio retained)" : bestTranscript
                RecentDictations.add(
                    raw: nil,
                    polished: storedText,
                    pasteTargetBundleID: capturedTargetForCancel,
                    polishMs: nil,
                    parakeetRaw: bestTranscript.isEmpty ? nil : bestTranscript,
                    durationSeconds: duration,
                    cleanupLevelUsed: nil,
                    personalityStyleUsed: nil,
                    polishFixCount: nil,
                    cancelled: true,
                    audioFilePath: retainedAudioURL?.path
                )
                print("[VOICE-CANCEL] retained: audio=\(retainedAudioURL?.lastPathComponent ?? "none") transcriptChars=\(bestTranscript.count) duration=\(duration.map(String.init) ?? "?")s → saved to History (unpolished, not pasted)")
            } else {
                // Nothing to keep (cancelled during spin-up, no audio, no text).
                print("[VOICE-CANCEL] nothing to retain (no audio file, no partial transcript) — skipping History save")
            }

            self.showCancelledToast()
        }
    }

    /// ESC key handler — cancel any in-flight dictation work.
    ///
    /// Escape semantics by phase:
    ///   * Idle → NO-OP. We never shadow system-wide Esc when there's nothing
    ///     to cancel. (Otherwise an Esc in another app would do weird things.)
    ///   * Recording → routes to the existing `cancelRecording()` path so the
    ///     audio + partial transcript get retained exactly the same way the
    ///     pill's X button does.
    ///   * Transcribing / polishing / pasting (i.e. post-recording stages) →
    ///     hard-cancel everything mid-flight. The streaming task chain is
    ///     killed, `sessionCancelled` is set so any guard that hasn't fired
    ///     yet will bail, and whatever partial transcript exists is persisted
    ///     to History as a cancelled dictation so the user doesn't lose work.
    ///   * Polish-selection (Opt+1 in flight) → cancel that one too.
    ///
    /// Audio is already on disk by the time we get here (every code path
    /// flushes via claimRecordingSync / stopRecording before this point), so
    /// "save it but cancel it" reduces to: don't paste, don't keep spinning
    /// the CPU, but do write the History row.
    fileprivate func cancelInFlightProcessing() {
        // Phase 1: still recording → defer to the existing cancel path.
        // That code already retains audio + writes a cancelled-dictation row.
        if recordingState.isRecording || recordingState.pendingRecordingStart {
            print("[VOICE-CANCEL-INFLIGHT] ESC during recording → routing to cancelRecording()")
            cancelRecording()
            return
        }

        // Phase 2: post-recording pipeline (transcribe / polish / paste).
        // We may also be in polish-selection (Opt+1). Both are addressed below.
        let wasTranscribing = recordingState.transcribingCount > 0
        let wasPolishingSelection = recordingState.isPolishingSelection
        guard wasTranscribing || wasPolishingSelection else {
            // Phase 0: truly idle. Don't touch anything — Esc here belongs to
            // whatever app is frontmost (it should dismiss its menus, sheets, etc.).
            return
        }

        print("[VOICE-CANCEL-INFLIGHT] ESC mid-pipeline: transcribing=\(wasTranscribing) polishingSelection=\(wasPolishingSelection)")

        // 1. Signal "cancelled" to every guard inside the finish Task. Each
        //    `guard !recordingState.sessionCancelled else { return }` checkpoint
        //    along the polish → paste path will now bail.
        recordingState.sessionCancelled = true

        // 2. Salvage whatever partial transcript exists RIGHT NOW (before we
        //    cancel the Task, which may still be appending). Mirrors the
        //    cancelRecording() snapshot path so the rules match exactly.
        let partialSegments = recordingState.currentTranscript
        let partialFromSegments = partialSegments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let partialLivePreview = recordingState.livePartialText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bestTranscript = !partialFromSegments.isEmpty ? partialFromSegments : partialLivePreview
        let capturedTargetForCancel = targetAppBundleID
        let startedAtForCancel = recordingStartedAt

        // 3. Cancel the streaming Task chain. The Task<Void, Never> doesn't
        //    propagate `throw`, but `Task.isCancelled` flips true and the
        //    inline `guard !Task.isCancelled` checks in finishRecording's body
        //    will short-circuit. Cancelling the paste chain prevents any
        //    queued post-polish paste from landing.
        pendingFinishTask?.cancel()
        pasteChain?.cancel()

        // 4. Tear down live UI state. The defer in finishRecording's Task
        //    will run on its way out, but for the worst case (the Task is
        //    blocked on a long Ollama round-trip and won't return for a
        //    while) we want the pill back to idle immediately. Setting
        //    transcribingCount = 0 is safe even if the defer also tries to
        //    decrement it — `max(0, count - 1)` floors it.
        recordingState.transcribingCount = 0
        recordingState.isPolishingSelection = false
        recordingState.livePartialText = ""
        recordingState.currentTranscript = []
        coordinator.stopLivePartials()

        // 5. Persist a cancelled-dictation History row when there's something
        //    worth keeping. Mirrors cancelRecording()'s salvage path. We
        //    intentionally do NOT include an audioFilePath here — the audio
        //    was already finalized/disposed by the upstream stopRecording
        //    drain (the cancellation point is past the audio-claim stage).
        if !bestTranscript.isEmpty {
            let duration = startedAtForCancel.map { Int(Date().timeIntervalSince($0)) }
            RecentDictations.add(
                raw: nil,
                polished: bestTranscript,
                pasteTargetBundleID: capturedTargetForCancel,
                polishMs: nil,
                parakeetRaw: bestTranscript,
                durationSeconds: duration,
                cleanupLevelUsed: nil,
                personalityStyleUsed: nil,
                polishFixCount: nil,
                cancelled: true,
                audioFilePath: nil
            )
            print("[VOICE-CANCEL-INFLIGHT] retained partial transcript: chars=\(bestTranscript.count) duration=\(duration.map(String.init) ?? "?")s → saved to History (cancelled, unpolished)")
        } else {
            print("[VOICE-CANCEL-INFLIGHT] no partial transcript to retain")
        }

        // 6. Surface confirmation to the user. We use the regular toast (not
        //    showCancelledToast) so it doesn't offer Undo — the pipeline was
        //    torn down past the point where Undo could meaningfully restore it.
        showToast("Cancelled. Audio saved.")

        // 7. Refresh the menu bar so its icon + status header reflect idle.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
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
        // The recording is ending — tear down the max-duration watchdog so it
        // can never double-fire. (Safe even when the watchdog itself triggered
        // this call: it's already past its await, so cancelling is a no-op for
        // the remaining synchronous commit work.)
        cancelMaxDurationWatchdog()
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
        let capturedRichAppContextForTask = capturedRichAppContext

        // Each finish gets its OWN Task. We intentionally do NOT cancel the
        // previous pendingFinishTask — if the user re-pressed the hotkey
        // before the prior pipeline finished, the prior transcript still
        // needs to reach the cursor. We just overwrite the reference so the
        // most recent task is reachable for diagnostics.
        // Snapshot the auto-personality override at Task creation time.
        // captureTargetApp() set previousPersonality on the main actor
        // synchronously before this Task is created, so the value is stable.
        let personalityToRestore = previousPersonality
        previousPersonality = nil  // consumed — prevent double-restore on re-press

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
                // Restore the user's saved personality if auto-override applied.
                if let saved = personalityToRestore {
                    UserDefaults.standard.set(saved, forKey: "personalityStyle")
                    print("[VOICE-PERSONALITY] restored: \(saved)")
                }
                // Session ended — drop icon timer back to the 5s idle rate and
                // update the icon once so it reflects the new idle state.
                self.scheduleMenuBarIconTimer()
                self.refreshMenuBarIcon()
            }

            // SESSION OWNERSHIP CHECK: if a fresh recording has started since
            // this Task was scheduled (the user re-pressed the hotkey), the
            // session ID will have rotated and the live/shared UI buffers
            // (currentTranscript, livePartialText, the per-clip polish flags,
            // the "last dictation" stats) now belong to the NEW session B.
            //
            // We do NOT abandon anymore. The earlier "lost first dictation"
            // bug came from returning here and silently discarding A's
            // transcript. A's audio was already claimed synchronously above
            // (via claimRecordingSync) and the coordinator now returns A's OWN
            // segments (see RecordingCoordinator's per-session return), so
            // there is no longer any reason to throw A away.
            //
            // Instead we compute `iOwnLiveState`: true only while THIS task
            // still owns the active session. Every write to shared/live-UI
            // `recordingState` below is gated on it — when false, B owns those
            // fields and we leave them untouched. But the transcribe → polish →
            // paste pipeline runs unconditionally for A's own claimed audio,
            // and A's paste still flows through the pasteChain / pasteOrderAnchor
            // ordering mechanism so A lands before B (chronological order).
            let iOwnLiveState = (self.recordingState.recordingSessionID == mySession)
            if !iOwnLiveState {
                vlog("[VOICE-RACE] proceeding as background session (not live owner) session=\(mySession) current=\(self.recordingState.recordingSessionID)")
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
            // The timeout is a HANG guard, not a happy-path cost: stopRecording
            // wins the race in ~150ms-few-seconds and cancelAll() kills the
            // sleeper, so this never adds latency on a healthy decode. Ceiling
            // tightened 25s → 15s: even a multi-minute dictation decodes via
            // chunked ASR in ~3-5s, so 15s still clears any legitimate workload
            // by a wide margin while recovering from a true ASR deadlock 10s
            // sooner. The fired-log gives evidence before tightening further.
            let asrCeilingNs: UInt64 = 15_000_000_000   // 15s (was 25s)
            let segments: [TranscriptSegment] = await withTaskGroup(
                of: [TranscriptSegment]?.self
            ) { group in
                group.addTask { await self.coordinator.stopRecording(claiming: claimed) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: asrCeilingNs)
                    if !Task.isCancelled {
                        fputs("[LATENCY] WARNING: ASR ceiling (15s) FIRED — drain/decode hung, returning empty\n", stderr)
                    }
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? []
            }
            let parakeetMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
            fputs("[LATENCY] Parakeet (drain+ASR): \(Int(parakeetMs))ms\n", stderr)
            vlog("[VOICE-TIMING] Parakeet returned at \(Date())")
            // [VOICE-RACE] Prove each finish task received ITS OWN session's
            // transcript. Before the coordinator fix, a superseded session's
            // stopRecording returned the shared state.currentTranscript (a newer
            // recording's text), which is what caused the same message to paste
            // twice. This logs what THIS session actually got back to drain.
            vlog("[VOICE-RACE] DRAIN-RETURN session=\(mySession) segments=\(segments.count) text=\"\(segments.map { $0.text }.joined(separator: " ").prefix(60))\"")
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

            // Live-UI clears: only when we still own the active session. If B
            // has taken over, currentTranscript / livePartialText now mirror
            // B's in-flight recording — clearing them here would blank B's live
            // preview. A still pastes its own text via pasteChain below.
            if iOwnLiveState {
                recordingState.currentTranscript = []
                // Final transcript has landed — clear live preview so partial text
                // doesn't linger after the real result is pasted.
                recordingState.livePartialText = ""
            }

            if rawText.isEmpty {
                vlog("[VOICE] Empty transcript → silent")
                return
            }

            // Language gate: VOICE supports English + Dutch (both Latin-script).
            // Parakeet TDT v3 is multilingual and occasionally misidentifies
            // unfamiliar audio as Greek / Russian / Chinese etc. If the result
            // is dominantly non-Latin, treat it as a misrecognition rather
            // than pasting garbage at the cursor.
            if isPredominantlyNonLatin(rawText) {
                vlog("[VOICE] Non-Latin transcript rejected (only English + Dutch supported): '\(rawText.prefix(40))'")
                // Save the raw transcript to clipboard so the user doesn't lose it.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(rawText, forType: .string)
                vlog("[VOICE] Non-Latin transcript saved to clipboard (\(rawText.count) chars)")
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
            vlog("[VOICE-FUNNEL] STAGE 1 PARAKEET raw=\"\(rawText)\" chars=\(rawText.count) segments=\(segments.count)")

            // Run formatter — paragraph-aware, synchronous (no Ollama round-trip).
            let tFormatStart = CFAbsoluteTimeGetCurrent()
            let formatted = textFormatter.formatSegments(segmentsForFormat)
            let formatterMs = (CFAbsoluteTimeGetCurrent() - tFormatStart) * 1000
            fputs("[LATENCY] TextFormatter: \(Int(formatterMs))ms\n", stderr)
            vlog("[VOICE-FUNNEL] STAGE 2 FORMATTER out=\"\(formatted)\" chars=\(formatted.count) diff=\(formatted != rawText)")
            // ESC-cancel checkpoint: if cancelInFlightProcessing() fired while
            // the formatter ran, bail before we sink time into Ollama polish.
            // The `defer` above still runs (transcribingCount decrement, live
            // partial cleanup) so the pill flips back to idle cleanly.
            if Task.isCancelled || recordingState.sessionCancelled {
                print("[VOICE-CANCEL-INFLIGHT] post-formatter cancellation detected — bailing before polish")
                return
            }
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
            vlog("[VOICE] autoPaste setting: \(autoPaste)")

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
            vlog("[VOICE] Starting polish... (formatted=\(formatted.count) chars) polishEnabledByUser=\(polishEnabledByUser)")
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
            // Per-clip polish flags belong to the ACTIVE session. The
            // coordinator only mirrors skipPolishForCurrent / granite /
            // moonshine into shared state for the still-active session (gated
            // by isStillActive() in RecordingCoordinator), so when B has taken
            // over these fields hold B's values — reading them would apply B's
            // polish decision to A, and consuming (clearing) them would rob B's
            // own finish task of its flags. When we don't own live state, fall
            // back to safe defaults: no short-clip skip, no triple-model merge,
            // i.e. run the standard polish() on A's own formatted text. Lossless
            // for A, and B's flags stay intact for B to consume.
            let skipPolish: Bool
            let graniteTranscript: String?
            let moonshineTranscript: String?
            if iOwnLiveState {
                skipPolish = recordingState.skipPolishForCurrent
                recordingState.skipPolishForCurrent = false  // consume the flag
                graniteTranscript = recordingState.graniteTranscript
                recordingState.graniteTranscript = nil        // consume the flag
                moonshineTranscript = recordingState.moonshineTranscript
                recordingState.moonshineTranscript = nil      // consume the flag
            } else {
                skipPolish = false
                graniteTranscript = nil
                moonshineTranscript = nil
            }
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
                    guard !self.recordingState.sessionCancelled else { return }
                    vlog("[VOICE-RACE] PASTE-FIRE site=optimistic session=\(mySession) chars=\(optimisticText.count) text=\"\(optimisticText.prefix(60))\"")
                    vlog("[VOICE] OPTIMISTIC paste START (\(optimisticText.prefix(60))…)")
                    var didReactivate = false
                    if let id = snapshotTarget,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                       !app.isActive {
                        app.activate()
                        didReactivate = true
                    }
                    // LATENCY: only pay the 80ms activation settle when we
                    // actually switched apps (see final-paste path for rationale).
                    if didReactivate { try? await Task.sleep(nanoseconds: 80_000_000) }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(optimisticText, forType: .string)
                    self.cursorPaster.pasteAtCursor(
                        optimisticText,
                        restoreClipboard: false,
                        preFormatted: optimisticPolishOwnedFormatting
                    )
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    vlog("[VOICE] OPTIMISTIC paste DONE")
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
                vlog("[VOICE] Polish skipped (cleanupLevel=none or polishEnabled=false) — rule-based only")
                finalText = formatted
            } else if skipPolish {
                vlog("[VOICE] Short clip — skipping LLM polish (rule-based only)")
                finalText = formatted
            } else if graniteTranscript != nil || moonshineTranscript != nil {
                // Triple-model path: Qwen3 merges Parakeet v2 + Granite 4.0 + Moonshine Tiny outputs.
                let graniteLabel = graniteTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                let moonshineLabel = moonshineTranscript.map { "'\($0.prefix(40))'" } ?? "nil"
                vlog("[VOICE] Triple-model merge: parakeet='\(formatted.prefix(40))' granite=\(graniteLabel) moonshine=\(moonshineLabel)")
                finalText = await Qwen3Polisher.shared.merge(
                    parakeet: formatted,
                    granite: graniteTranscript,
                    moonshine: moonshineTranscript,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab,
                    fieldContext: capturedFieldContextForTask,
                    appContextLabel: capturedRichAppContextForTask ?? Qwen3Polisher.appContextLabel(forBundleID: capturedTargetForTask),
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
                // Surface average confidence to the pill so it can tint its
                // stroke (white >= 0.55, amber 0.40..<0.55, red < 0.40).
                // Already on MainActor (enclosing Task), so set directly.
                if let conf = parakeetAvgConf {
                    self.recordingState.transcriptionConfidence = Double(conf)
                }
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
                guard !recordingState.sessionCancelled else { return }
                finalText = await Qwen3Polisher.shared.polish(
                    formatted,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab,
                    fieldContext: capturedFieldContextForTask,
                    appContextLabel: capturedRichAppContextForTask ?? Qwen3Polisher.appContextLabel(forBundleID: capturedTargetForTask),
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
                vlog("[VOICE] WARNING: polish returned empty — falling back to formatted text")
                Telemetry.log("polish.empty_output", properties: [
                    "input_chars": formatted.count
                ])
                finalText = formatted
            }
            // ESC-cancel checkpoint: if cancelInFlightProcessing() fired
            // during the polish round-trip, don't enqueue the paste step.
            // The cancelled-dictation History row was already written by
            // cancelInFlightProcessing(), so we just exit cleanly here.
            if Task.isCancelled || recordingState.sessionCancelled {
                print("[VOICE-CANCEL-INFLIGHT] post-polish cancellation detected — skipping paste enqueue")
                return
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
            // "Last dictation" snapshot stats drive the live pill / stats UI and
            // represent the MOST RECENT dictation. If B owns the session, B is
            // the most recent — an older background session A must not overwrite
            // these with its stale numbers. Gate on ownership.
            if iOwnLiveState {
                recordingState.lastDictationWordCount = wordCount
                recordingState.lastDictationDurationSeconds = durationSeconds
                recordingState.lastDictationWPM = wpm
            }
            // Cumulative session + lifetime totals: A's dictation genuinely
            // happened, so it must be counted regardless of ownership. These are
            // additive (order-independent) and not live-preview state.
            recordingState.recordDictation(words: wordCount, durationSeconds: durationSeconds)

            // Long-dictation toast: if the result is 80+ words the user may not
            // realise how much landed (it can scroll offscreen or get pasted
            // somewhere they're not looking). A quick count confirmation helps.
            if wordCount >= 80 {
                let mins = durationSeconds >= 60 ? "\(durationSeconds / 60)m \(durationSeconds % 60)s" : "\(durationSeconds)s"
                showToast("\(wordCount) words pasted (\(mins))")
            }

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
                        print("[VOICE-RACE] PASTE-FIRE site=optimistic-swap session=\(mySession) chars=\(finalText.count) text=\"\(finalText.prefix(60))\"")
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
                    var didReactivate = false
                    if let id = capturedTargetForTask,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                       !app.isActive {
                        print("[VOICE] Activating snapshot target app: \(id)")
                        app.activate()
                        didReactivate = true
                    }
                    // LATENCY: the 80ms settle only matters when we just called
                    // activate() and need to wait for the app to come frontmost.
                    // In the common case (target app already focused — user
                    // dictated into it and never switched away) we skip it
                    // entirely. CursorPaster's own pre-paste delay still provides
                    // the keystroke-settle window, so paste reliability is
                    // unchanged. Saves ~80ms on every same-app dictation.
                    if didReactivate {
                        // Reduced settle — Wispr Flow ships Cmd-V without these.
                        print("[VOICE] Target app re-activated, settling for 30ms...")
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    } else {
                        print("[VOICE] Target app already frontmost — skipping settle")
                    }
                    // Cancel-flag guard: if the user cancelled this session between
                    // the audio claim and now (race between finishRecording's async
                    // task and cancelRecording), skip the paste entirely. Audio drain
                    // and cleanup above already ran — only the cursor write is skipped.
                    guard !self.recordingState.sessionCancelled else {
                        print("[VOICE-HK] finishRecording: session was cancelled — skipping paste")
                        return
                    }
                    print("[VOICE] Calling pasteAtCursor...")
                    print("[VOICE-RACE] PASTE-FIRE site=final session=\(mySession) chars=\(finalText.count) text=\"\(finalText.prefix(60))\"")
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
                    showUndoPasteToast(finalText: finalText)
                    // Reduced settle — Wispr Flow ships Cmd-V without these.
                    // (Inter-paste 60ms removed entirely.)
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
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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

    // MARK: - Undo-paste toast

    private func showUndoPasteToast(finalText: String) {
        // User-controllable. The toast was firing after every single paste and
        // got annoying fast. Default OFF — power users can flip it on from
        // settings if they want the undo affordance. Cmd-Z works regardless.
        let showToast = UserDefaults.standard.object(forKey: "voice.showUndoPasteToast") as? Bool ?? false
        guard showToast else { return }
        guard !recordingState.isRecording, !recordingState.pendingRecordingStart else {
            print("[VOICE-PILL] suppressing undo toast — new recording in flight")
            return
        }
        recordingState.lastPastedText = finalText
        recordingState.showingUndoPasteToast = true
        recordingState.undoPasteToastShownAt = Date()
        undoPasteDismissTask?.cancel()
        undoPasteDismissTask = Task { @MainActor [weak self] in
            // Shorter — 3.5s instead of 7s. Long enough to register, not long
            // enough to feel like the app is begging for attention.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissUndoPasteToast()
        }
    }

    func dismissUndoPasteToast() {
        undoPasteDismissTask?.cancel()
        undoPasteDismissTask = nil
        recordingState.showingUndoPasteToast = false
        recordingState.undoPasteToastShownAt = nil
        recordingState.lastPastedText = ""
    }

    func undoLastPaste() {
        guard !recordingState.lastPastedText.isEmpty else { return }
        dismissUndoPasteToast()
        let src = CGEventSource(stateID: .combinedSessionState)
        let zDown = CGEvent(keyboardEventSource: src, virtualKey: 6, keyDown: true)
        zDown?.flags = .maskCommand
        let zUp   = CGEvent(keyboardEventSource: src, virtualKey: 6, keyDown: false)
        zUp?.flags = .maskCommand
        zDown?.post(tap: .cghidEventTap)
        zUp?.post(tap: .cghidEventTap)
        print("[VOICE-UNDO] Sent Cmd+Z to frontmost app to undo paste")
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

    // MARK: - Wake word

    /// Wire the "Hey Voice" listener. Off by default — user toggles it on
    /// from Settings, which sets `voice.wakeWordEnabled = true`. We observe
    /// that flag and start/stop the service accordingly.
    private func setupWakeWord() {
        WakeWordService.shared.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            // Same entry point a hotkey press uses, except we also want to
            // LOCK the recording so the user can keep talking without holding
            // anything — hands-free is the whole point of the wake phrase.
            print("[VOICE-WAKE] phrase detected → starting locked dictation")
            if !self.recordingState.isRecording && !self.recordingState.isLocked {
                self.hotkeyDidActivate()
                // Latch into locked mode after a tick so the recorder is fully up.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self else { return }
                    if self.recordingState.isRecording && !self.recordingState.isLocked {
                        self.enterLockMode()
                    }
                }
            }
        }
        // Mode-aware startup:
        //   • "off"             — never start; service inert.
        //   • "alwaysOn"        — legacy behavior. Mic indicator stays
        //                         on permanently while the listener runs.
        //   • "activatedWindow" — do not auto-start. Wait for a UI
        //                         surface to post
        //                         `.voiceActivateWakeWordWindow`. Then
        //                         the mic is hot only for the window.
        let mode = BackgroundActivityGate.wakeWordMode
        switch mode {
        case "alwaysOn":
            if BackgroundActivityGate.wakeWordEnabled {
                WakeWordService.shared.enable()
            } else {
                print("[VOICE-GATE] WakeWordService NOT enabled — gated OFF by privacyMode / enableWakeWord / wakeWordEnabled")
            }
        case "activatedWindow":
            print("[VOICE-WAKE] mode=activatedWindow — listener dormant until armed")
        default:
            print("[VOICE-WAKE] mode=off — wake word disabled")
        }

        // Wire the activation notification once, regardless of mode — if
        // the user flips into activatedWindow at runtime, the listener is
        // already attached to the notification stream.
        let activateToken = NotificationCenter.default.addObserver(
            forName: .voiceActivateWakeWordWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WakeWordService.shared.activateForWindow()
            }
        }
        notificationTokens.append(activateToken)

        // React to live toggles from Settings without requiring a restart.
        // Same gate applies — privacy mode forces disable regardless.
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let mode = BackgroundActivityGate.wakeWordMode
                switch mode {
                case "alwaysOn":
                    if BackgroundActivityGate.wakeWordEnabled {
                        WakeWordService.shared.enable()
                    } else {
                        WakeWordService.shared.disable()
                    }
                case "activatedWindow":
                    // Don't auto-start. Don't auto-disable either — that
                    // would cancel an active window the user just armed.
                    break
                default:
                    WakeWordService.shared.disable()
                }
            }
        }
        notificationTokens.append(token)
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
        // Pause wake-word listener so it doesn't fight the dictation mic tap.
        WakeWordService.shared.pauseWhileRecording()

        // === Permission gates ===
        // Permissions are checked here AND throttled: we never show the
        // system prompt more than once per app launch (it pops a fresh
        // dialog every call), and we deep-link to the right Privacy pane on
        // the first miss so the user can resolve it without hunting.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOk = micStatus == .authorized
        let axOk = AXIsProcessTrusted()
        // Dictation doesn't need Screen Recording — pass srOk=true so the gate
        // doesn't block hotkey use just because Screen Recording isn't granted.
        if !micOk || !axOk {
            print("[VOICE-HK] hotkeyDidActivate: permission gate FAILED micOk=\(micOk) axOk=\(axOk)")
            handleMissingPermissions(micOk: micOk, axOk: axOk, srOk: true, micStatus: micStatus)
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
            recordingState.pendingRecordingStartAt = Date()
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
            // Clear the cancel flag for the fresh session.
            recordingState.sessionCancelled = false
            dismissUndoPasteToast()
            // Start recording — synchronously flips isRecording=true. pendingRecordingStart
            // will be cleared by finishRecording() when the user releases (not here);
            // the OR in pillPhase keeps the pill in .recording across that handover.
            coordinator.startRecording()
            print("[VOICE-TIMING] startRecording() returned (Path 2) at \(Date())")
            SoundEffects.playStart()
            captureTargetApp()
            // Arm the 5-min cap for this fresh recording (keyed off the new
            // session ID + start time, so it supersedes the prior one).
            armMaxDurationWatchdog()
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
        recordingState.pendingRecordingStartAt = Date()
        print("[VOICE-TIMING] pendingRecordingStart=true (Path 3) at \(Date())")
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Path 3: Hotkey down → start recording (fresh)")
        recordingStartedAt = hotkeyService.pressDownAt ?? Date()
        recordingState.cancelledTranscript = []
        // Rotate the session ID for the fresh recording (see Path 2 for rationale).
        recordingState.recordingSessionID = UUID()
        // Clear the cancel flag for the fresh session.
        recordingState.sessionCancelled = false
        dismissUndoPasteToast()
        // coordinator.startRecording() synchronously flips state.isRecording=true.
        coordinator.startRecording()
        print("[VOICE-TIMING] startRecording() returned (Path 3) at \(Date())")
        // Switch icon timer to 1Hz for the active-recording state, then update
        // the icon immediately so the waveform symbol appears without lag.
        scheduleMenuBarIconTimer()
        refreshMenuBarIcon()
        SoundEffects.playStart()
        captureTargetApp()
        // Arm the 5-min cap the moment the recording begins. Keyed off the
        // actual start time, so it still fires if this press's release is ever
        // missed (PTT key-up swallowed → recording would otherwise never end).
        armMaxDurationWatchdog()
        // Safety timer: if the audio engine never flips isRecording=true within 2s,
        // clear pendingRecordingStart so the pill doesn't latch in .recording forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.recordingState.pendingRecordingStart,
                  !self.recordingState.isRecording else { return }
            print("[VOICE-PILL] safety-clear: pendingRecordingStart stuck >2s without isRecording — force clearing")
            self.recordingState.pendingRecordingStart = false
            self.recordingState.pendingRecordingStartAt = nil
        }
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
        // Resume wake-word listening 2 seconds after release so the user can
        // do back-to-back hotkey presses without the wake-word service
        // fighting for the mic. If they re-press inside 2s, pauseWhileRecording
        // pre-empts it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if !self.recordingState.isRecording && !self.recordingState.isLocked {
                WakeWordService.shared.resume()
            }
        }
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
        // Quick tap discards the recording — cancel its max-duration watchdog
        // so a stale timer can't outlive it.
        cancelMaxDurationWatchdog()
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
    /// Set true the moment cancel fires. Checked by finishRecording() before
    /// pasting — if true, the paste is skipped. Cleared when a new recording starts.
    var sessionCancelled = false
    var showingUndoPasteToast = false
    var undoPasteToastShownAt: Date? = nil
    var lastPastedText: String = ""
    /// Average per-segment ASR confidence (0...1) from the most recent
    /// recording / live partial. Drives the pill's stroke color so the user
    /// gets a passive signal that the model is uncertain about what it heard.
    var transcriptionConfidence: Double = 1.0
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
    /// True while a meeting capture session is active (Google Meet / Zoom / Teams).
    var isCapturingMeeting: Bool = false
    /// The UUID of the current meeting capture session. Set when isCapturingMeeting
    /// flips true; cleared when it flips false.
    var activeMeetingId: UUID? = nil
    /// True when a known meeting app (Google Meet standalone, Zoom, Teams) is frontmost.
    /// Used to tint the idle pill and route a tap to startMeetingCapture() instead
    /// of starting a regular dictation.
    var isMeetingAppActive: Bool = false
    /// Live elapsed seconds of the active meeting capture session, mirrored from
    /// MeetingCaptureService.durationSeconds every 0.5s. Reset to 0 when capture stops.
    var meetingDurationSeconds: Int = 0
    /// Live transcript segments accumulated during the active meeting capture session.
    /// Mirrored from MeetingCaptureService.liveTranscript every 2s. Cleared when capture stops.
    var meetingLiveTranscript: [TranscriptSegment] = []
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

    /// Completed meetings — populated by the meeting capture pipeline.
    var meetings: [Meeting] = []

    /// Tracks the lifecycle of the persisted-meetings fetch so the
    /// Meetings list can show a skeleton during the initial DB read and an
    /// error state with a Retry button if the read throws. Set by
    /// `AppDelegate.fetchMeetingsIntoState()` — the single funnel that all
    /// load/reload call sites now go through.
    var meetingsLoadState: MeetingsLoadState = .initial

    /// Bundle ID of the meeting app that triggered the current capture session.
    /// Set by OverlayPanel's poll when a meeting app is detected frontmost,
    /// then copied into MeetingCaptureService before startCapture() so it can
    /// be persisted on the saved Meeting record. Nil when no meeting is active.
    var meetingSourceBundleID: String? = nil

    /// Participant names scraped from the call platform's DOM by the Chrome
    /// extension (Google Meet, Discord, Teams, Slack huddles). Populated by
    /// `MeetBridgeServer.onMeetActive` and consumed by `generateMeetingTitle`
    /// when stopMeetingCapture() saves the Meeting. Empty when the extension
    /// isn't installed or couldn't scrape names — in that case the title
    /// generator falls back to the transcript-regex name extractor.
    var meetingParticipantNames: [String] = []

    /// Single source of truth for the pill UI state. Always reflects the most
    /// important active state — no impossible combinations.
    var pillPhase: PillPhase {
        if pendingRecordingStart || (isRecording && !isLocked) { return .recording }
        if isRecording && isLocked { return .locked }
        if !isRecording && isLocked { return .locked }
        if isPolishingSelection { return .polishingSelection }
        if isCapturingMeeting { return .meetingCapture }
        if isTranscribing { return .transcribing }
        if showingCancelledToast { return .cancelled }
        if showingUndoPasteToast { return .undoPaste }
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

        // Meeting counters are NOT bumped here. A long dictation is not a
        // meeting. Real meetings (captured via MeetingCaptureService through
        // the Chrome extension / meeting-app detection) flow through
        // recordMeeting(durationSeconds:) below, called from stopMeetingCapture.
        recentDictationsTick &+= 1
    }

    /// Record one ACTUAL meeting capture (system audio + mic from a Meet /
    /// Zoom / Discord / etc. session). Called from AppDelegate.stopMeetingCapture
    /// after the segments are saved. Bumps both session and lifetime counters.
    func recordMeeting(durationSeconds: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        if today != sessionDate {
            sessionDate = today
            sessionMeetingCount = 0
            sessionMeetingTotalDurationSeconds = 0
        }
        sessionMeetingCount += 1
        sessionMeetingTotalDurationSeconds += durationSeconds
        lifetimeMeetingCount += 1
        lifetimeMeetingDurationSeconds += durationSeconds
        UserDefaults.standard.set(lifetimeMeetingCount, forKey: "voice.totalMeetings")
        UserDefaults.standard.set(lifetimeMeetingDurationSeconds, forKey: "voice.totalMeetingDurationSeconds")
    }
}

// MARK: - MeetingActiveNotificationDelegate
//
// UN delegate proxy that owns the "Voice is recording your meeting" banner.
// Installed by AppDelegate the first time meeting capture starts. Everything
// it doesn't handle (transcript-ready taps, etc.) is forwarded to the
// existing `MeetingNotifier.delegate` so legacy routing keeps working.
//
// Intercepts:
//   • Tap on the "Stop Recording" action button (categoryIdentifier ==
//     kMeetingActiveCategory, actionIdentifier == kMeetingStopAction)
//   • Tap on the banner body when userInfo carries `voiceMeetingActiveBanner`
// Both paths post `.voiceStopMeetingRequested`, which the AppDelegate
// observer (see setupErrorObserver below) converts into stopMeetingCapture().
final class MeetingActiveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingActiveNotificationDelegate()
    /// Existing delegate to fall back to for unrelated notifications. Set by
    /// AppDelegate before installing this proxy.
    var fallback: UNUserNotificationCenterDelegate?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show banner + sound for our category. Delegate the rest.
        if notification.request.content.categoryIdentifier == AppDelegate.kMeetingActiveCategory {
            completionHandler([.banner, .sound])
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let isOurBanner = category == AppDelegate.kMeetingActiveCategory
            || (userInfo["voiceMeetingActiveBanner"] as? Bool) == true
        if isOurBanner {
            // Action button OR body tap → both stop the recording. The
            // default-action identifier is UNNotificationDefaultActionIdentifier.
            if action == AppDelegate.kMeetingStopAction
                || action == UNNotificationDefaultActionIdentifier {
                print("[VOICE-NOTIF] meeting-active banner action=\(action) — stopping capture")
                NotificationCenter.default.post(name: .voiceStopMeetingRequested, object: nil)
            }
            completionHandler()
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}
