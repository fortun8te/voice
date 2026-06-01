// VOICE — Global Hotkey Service
// ============================================================
// Behavior contract (user spec, non-negotiable):
//
//   QUICK TAP (press + release before threshold, no follow-up)
//     → silent discard, nothing transcribed
//
//   HOLD (press + hold past threshold + release)
//     → push-to-talk, transcribe on release
//
//   DOUBLE TAP (two presses within window, second one need not be held)
//     → enter LOCK MODE, recording continues until next press
//
//   THIRD TAP while locked (any duration)
//     → exit lock + transcribe
//
//   HANDS-FREE HOTKEY TAP (a distinct binding role)
//     → toggles lock immediately on press (no double-tap required)
//
// === Architecture ===
//
// All hotkey behavior is a deterministic state machine. Every NSEvent
// (keyDown/keyUp) and every timer expiry is funneled through
// `transition(event:)`. Delegate callbacks are dispatched SYNCHRONOUSLY
// on the main queue — never async — so by the time the next event fires,
// the prior callback's side-effects (e.g. flipping `state.isRecording`)
// are already committed.
//
// `pressDownAt` is captured on the event-monitor thread at the EXACT
// moment of keyDown. The delegate uses this — not its own Date() — to
// compute hold duration, so dispatch latency never makes a real hold
// look like a quick tap.
//
// === Multi-binding role model ===
//
// Two ROLES exist: .pushToTalk and .handsFree. Each role can have any
// number of CapturedHotkey bindings (user-captured via the settings UI).
// An incoming NSEvent is tested against every binding of every role;
// the first matching role becomes the `activeRole` for that press. PTT
// events flow through the existing state machine. Hands-free events
// fire a single `.handsFreeTap` toggle (no double-tap window, no
// quick-tap discard) so the user gets the classic "tap on / tap off"
// Wispr-style flow.
// ============================================================

import Foundation
import AppKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the menu when the user picks a different hotkey.
    /// HotkeyService listens and re-binds monitors.
    static let voiceHotkeyChanged = Notification.Name("voiceHotkeyChanged")
    /// Posted when the user presses the Escape key globally. The AppDelegate
    /// decides whether to act on it (only when a dictation is past the
    /// recording stage — idle ESC is a no-op so we don't shadow system Esc).
    static let voiceEscapePressed = Notification.Name("voice.escapePressed")
}

// MARK: - Captured Hotkey

/// A user-captured key binding. Can represent either a modifier-only hold
/// (keyCode == nil, e.g. "Right ⌥") or a combo (keyCode + modifiers, e.g.
/// fn + Space). Stored as JSON in UserDefaults via `HotkeyRole`.
struct CapturedHotkey: Codable, Hashable, Identifiable {
    /// Stable id for SwiftUI ForEach (UUID, persisted).
    var id: UUID = UUID()
    /// Virtual key code (e.g. 49 for Space). nil = modifier-only binding.
    var keyCode: UInt16?
    /// Raw modifier bitmask using NSEvent.ModifierFlags.rawValue.
    /// Includes left/right distinction via device-dependent bits (0x40 for right-option, 0x20 for left-option, etc.).
    var modifiersRaw: UInt

    /// Human-readable name, e.g. "Right ⌥", "fn + Space", "⌃⌘ K".
    var displayName: String { CapturedHotkey.describe(keyCode: keyCode, modifiersRaw: modifiersRaw) }

    /// Chips for the settings UI rendering, e.g. ["fn", "Space"].
    var displayChips: [String] { CapturedHotkey.chips(keyCode: keyCode, modifiersRaw: modifiersRaw) }

    /// True iff binding is just a held modifier (no character key).
    var isModifierOnly: Bool { keyCode == nil }

    /// True iff binding has no key and no modifiers (sentinel/unset).
    var isEmpty: Bool { keyCode == nil && modifiersRaw == 0 }

    static func describe(keyCode: UInt16?, modifiersRaw: UInt) -> String {
        chips(keyCode: keyCode, modifiersRaw: modifiersRaw).joined(separator: " + ")
    }

    static func chips(keyCode: UInt16?, modifiersRaw: UInt) -> [String] {
        var parts: [String] = []
        let rightOptionMask: UInt = 0x40
        let leftOptionMask:  UInt = 0x20
        let rightCommandMask: UInt = 0x10
        let leftCommandMask:  UInt = 0x8
        let rightControlMask: UInt = 0x2000
        let leftControlMask:  UInt = 0x1
        let rightShiftMask:   UInt = 0x4
        let leftShiftMask:    UInt = 0x2
        let fnMask: UInt = 0x800000  // NSEvent.ModifierFlags.function

        if (modifiersRaw & fnMask) != 0 { parts.append("fn") }
        if (modifiersRaw & leftControlMask) != 0   { parts.append("Left ⌃") }
        if (modifiersRaw & rightControlMask) != 0  { parts.append("Right ⌃") }
        if (modifiersRaw & leftShiftMask) != 0     { parts.append("Left ⇧") }
        if (modifiersRaw & rightShiftMask) != 0    { parts.append("Right ⇧") }
        if (modifiersRaw & leftOptionMask) != 0    { parts.append("Left ⌥") }
        if (modifiersRaw & rightOptionMask) != 0   { parts.append("Right ⌥") }
        if (modifiersRaw & leftCommandMask) != 0   { parts.append("Left ⌘") }
        if (modifiersRaw & rightCommandMask) != 0  { parts.append("Right ⌘") }

        if let kc = keyCode, let name = keyName(for: kc) {
            parts.append(name)
        }
        return parts.isEmpty ? ["—"] : parts
    }

    static func keyName(for keyCode: UInt16) -> String? {
        // Common keys — keep this small and good. Unknown codes fall back to "Key \(code)".
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 51: return "Delete"
        case 53: return "Esc"
        case 48: return "Tab"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5";  case 97: return "F6";  case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 0: return "A"; case 11: return "B"; case 8: return "C"; case 2: return "D"
        case 14: return "E"; case 3: return "F"; case 5: return "G"; case 4: return "H"
        case 34: return "I"; case 38: return "J"; case 40: return "K"; case 37: return "L"
        case 46: return "M"; case 45: return "N"; case 31: return "O"; case 35: return "P"
        case 12: return "Q"; case 15: return "R"; case 1: return "S"; case 17: return "T"
        case 32: return "U"; case 9: return "V"; case 13: return "W"; case 7: return "X"
        case 16: return "Y"; case 6: return "Z"
        case 18: return "1"; case 19: return "2"; case 20: return "3"; case 21: return "4"
        case 23: return "5"; case 22: return "6"; case 26: return "7"; case 28: return "8"
        case 25: return "9"; case 29: return "0"
        case 27: return "−"; case 24: return "="; case 33: return "["; case 30: return "]"
        case 41: return ";"; case 39: return "'"; case 43: return ","; case 47: return "."
        case 44: return "/"; case 42: return "\\"; case 50: return "`"
        default: return "Key \(keyCode)"
        }
    }

    /// Mask of all bits we care about when matching modifier flags.
    private static let relevantModifierMask: UInt =
        0x40 | 0x20 | 0x10 | 0x8 | 0x2000 | 0x1 | 0x4 | 0x2 | 0x800000

    /// EXACT modifier match — every relevant bit equal. Used to detect a
    /// FRESH press where we don't want a stray extra modifier to count as
    /// "the hotkey is now down".
    func modifiersMatch(_ event: NSEvent) -> Bool {
        let masked = event.modifierFlags.rawValue & CapturedHotkey.relevantModifierMask
        let want   = modifiersRaw & CapturedHotkey.relevantModifierMask
        return masked == want
    }

    /// SUBSET modifier match — every required bit is present, extras allowed.
    /// Used to keep a hotkey latched as "still down" when the user, while
    /// holding it, taps another modifier (e.g. holds Right Option, then taps
    /// Cmd to switch apps). Without this, the flagsChanged event for the
    /// extra modifier would un-latch the hotkey mid-press, causing a spurious
    /// keyUp → premature transcribe / pill drop. (Real historical bug.)
    func modifiersContain(_ event: NSEvent) -> Bool {
        let masked = event.modifierFlags.rawValue & CapturedHotkey.relevantModifierMask
        let want   = modifiersRaw & CapturedHotkey.relevantModifierMask
        return want != 0 && (masked & want) == want
    }

    /// True if this NSEvent matches this binding.
    /// `hotkeyIsDown` is the service's latch state so we can keep reporting
    /// "still down" between keyDown and keyUp when modifier flagsChanged events fire.
    ///
    /// Match policy:
    ///   - Fresh press (hotkeyIsDown=false): EXACT modifier match — extra
    ///     modifiers disqualify, so we never accidentally latch on a different
    ///     keypress that happens to share bits with our binding.
    ///   - While latched (hotkeyIsDown=true):  SUBSET match — keep reporting
    ///     "down" as long as all required mods are present, even if extras are.
    ///     Fixes the "user tapped Cmd while holding Option → pill dropped" bug.
    func matches(_ event: NSEvent, hotkeyIsDown: Bool) -> Bool {
        if let kc = keyCode {
            // Combo binding: keyDown on the specific key code while modifiers held.
            if event.type == .keyDown && event.keyCode == kc {
                return hotkeyIsDown ? modifiersContain(event) : modifiersMatch(event)
            }
            if event.type == .keyUp && event.keyCode == kc { return false }
            // After keyDown latched, treat the binding as down while modifiers + key are still held.
            // Use subset match so extra modifiers (e.g. user taps Cmd mid-press) don't drop us.
            return hotkeyIsDown && modifiersContain(event)
        } else {
            // Modifier-only binding.
            // Fresh: exact match required. Latched: subset (extras allowed).
            return hotkeyIsDown ? modifiersContain(event) : modifiersMatch(event)
        }
    }
}

// MARK: - Hotkey Roles

enum HotkeyRole: String, CaseIterable {
    case pushToTalk = "ptt"
    case handsFree  = "lock"

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .handsFree:  return "Hands-free mode"
        }
    }
    var subtitle: String {
        switch self {
        case .pushToTalk: return "Hold fn to say something short, release to paste"
        case .handsFree:  return "Double-tap fn to start hands-free, tap fn again to stop"
        }
    }

    /// Sensible defaults so first launch works without setup.
    ///
    /// These match Wispr Flow exactly:
    ///   - Push to talk:  hold `fn` alone (modifier-only, fn bit = 0x800000).
    ///   - Hands-free:    DOUBLE-TAP `fn` (two quick presses) — no separate
    ///                    binding; the PTT state machine latches on double-tap.
    /// On keyboards without an Apple fn key, the user can rebind PTT to
    /// Ctrl+Opt via Settings (double-tapping that then latches hands-free);
    /// the NSEvent fallback monitor handles those non-fn bindings.
    var defaultBindings: [CapturedHotkey] {
        switch self {
        case .pushToTalk:
            // fn alone, modifier-only.
            return [CapturedHotkey(keyCode: nil, modifiersRaw: 0x800000)]
        case .handsFree:
            // Hands-free is entered by DOUBLE-TAPPING the push-to-talk key
            // (two quick fn presses within the double-tap window) — handled
            // natively by the PTT state machine. The double-tap IS the
            // hands-free trigger, so there is intentionally no separate binding.
            return []
        }
    }

    private var udKey: String {
        switch self {
        case .pushToTalk: return "hotkeys.captured.ptt"
        case .handsFree:  return "hotkeys.captured.lock"
        }
    }

    func loadBindings() -> [CapturedHotkey] {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let parsed = try? JSONDecoder().decode([CapturedHotkey].self, from: data),
              !parsed.isEmpty else {
            return defaultBindings
        }
        // PTT bindings must never be Option-key based — Option is not fn, and
        // any Option binding from legacy installs breaks the fn tap. Sanitize
        // on every load (cheap; only writes UserDefaults if a fix is needed).
        if self == .pushToTalk { return Self.sanitizePTTBindings(parsed) }
        return parsed
    }

    /// Remove any Option-key bits (Left⌥ 0x20, Right⌥ 0x40) from PTT bindings.
    /// If all bindings were Option-only, falls back to the fn default.
    /// Runs on every load but only writes UserDefaults when a fix is needed.
    private static func sanitizePTTBindings(_ parsed: [CapturedHotkey]) -> [CapturedHotkey] {
        let optionBits: UInt = 0x20 | 0x40
        let cleaned = parsed.filter { ($0.modifiersRaw & optionBits) == 0 }
        guard cleaned.count != parsed.count else { return parsed }   // nothing to fix

        let result = cleaned.isEmpty ? HotkeyRole.pushToTalk.defaultBindings : cleaned
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: "hotkeys.captured.ptt")
        }
        let names = result.map { $0.displayName }.joined(separator: ", ")
        print("[VOICE-HK] Sanitized Option-key PTT binding(s) → \(names)")
        return result
    }

    func saveBindings(_ bindings: [CapturedHotkey]) {
        if let data = try? JSONEncoder().encode(bindings) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
        NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
    }

    func resetToDefault() { saveBindings(defaultBindings) }
}

// MARK: - Delegate

@MainActor
protocol HotkeyServiceDelegate: AnyObject {
    /// Called on a fresh keyDown (idle → pressed) AND on a third tap
    /// (locked → lockedAndPressed). The delegate inspects `isLocked`:
    ///   - locked  → exit lock + transcribe
    ///   - else    → start a recording. MUST complete its start-side work
    ///               (flip `state.isRecording = true`) BEFORE returning,
    ///               because the state machine assumes recording is live
    ///               when subsequent events arrive.
    func hotkeyDidActivate()

    /// Called on keyUp when the held duration was ≥ short-tap threshold.
    /// PTT release. Delegate finalizes + transcribes.
    func hotkeyDidDeactivate()

    /// Called when the double-tap window expires with no second tap.
    /// The first tap was a stray. Delegate discards in-flight audio silently.
    func hotkeyDidQuickRelease()

    /// Called when a second keyDown lands inside the double-tap window
    /// OR when a hands-free hotkey is pressed (explicit lock toggle).
    /// Delegate enters lock mode. The recording from the prior activate
    /// continues — no restart, no duplicate start sound.
    func hotkeyDidDoubleTap()
}

// MARK: - HotkeyService

@Observable
class HotkeyService {

    // MARK: State Machine

    private enum State: Equatable {
        /// Nothing happening.
        case idle

        /// Key is down after a fresh idle keyDown. Recording in progress.
        /// On keyUp we branch: held long → PTT commit; held short → armed.
        case pressed(since: Date)

        /// First tap released quickly. Recording still running (we defer the
        /// quickRelease decision until the double-tap window expires or a
        /// second keyDown arrives). If timer fires first → quickRelease +
        /// drop to idle. If second keyDown → double-tap + lock.
        case armed

        /// Lock mode. Key not currently held. Recording continues.
        /// Next keyDown is the third-tap exit.
        case locked

        /// Lock mode + key held (third tap is mid-press). We've already
        /// fired activate() so the delegate exited lock & started commit.
        /// Wait for keyUp to return to idle.
        case lockedAndPressed
    }

    private enum Event {
        case keyDown
        case keyUp
        case doubleTapWindowExpired
        /// Explicit hands-free hotkey was pressed. Toggles lock immediately
        /// — no double-tap window, no quick-tap discard path.
        case handsFreeTap
    }

    // MARK: Public surface

    @ObservationIgnored
    private var pttBindings:    [CapturedHotkey] { HotkeyRole.pushToTalk.loadBindings() }

    @ObservationIgnored
    private var lockBindings:   [CapturedHotkey] { HotkeyRole.handsFree.loadBindings() }

    /// Whether the hotkey-driven recording session is active (PTT held or
    /// locked). Mirrors transition state for UI binding.
    var isHotkeyActive: Bool = false

    /// Lock mode flag. Externally writable (the UI's lock button toggles it).
    /// The state machine reads it on lock-related transitions.
    var isLocked = false

    weak var delegate: HotkeyServiceDelegate?

    /// Timestamp of the most recent keyDown that began a press. The delegate
    /// reads this to compute REAL hold duration — not Date() inside the
    /// delegate callback, which lags by dispatch latency.
    /// Cleared on transition back to .idle.
    @ObservationIgnored var pressDownAt: Date?

    // MARK: Internal state

    @ObservationIgnored private var state: State = .idle
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    /// Passive global monitor for the Escape key (virtual keycode 53). Used
    /// to cancel an in-flight dictation when the user presses Esc anywhere on
    /// the system. We don't consume the event — Esc continues to dismiss the
    /// active app's UI as usual. The AppDelegate gates the action so idle Esc
    /// is a no-op (no interference with normal Esc semantics).
    @ObservationIgnored private var escapeGlobalMonitor: Any?
    /// Local mirror of escapeGlobalMonitor so the cancel still works while
    /// VOICE itself is frontmost (e.g. BigMenu open, settings sheet shown).
    @ObservationIgnored private var escapeLocalMonitor: Any?
    @ObservationIgnored private var hotkeyChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var hotkeyIsDown = false
    @ObservationIgnored private var doubleTapTimer: Timer?

    // === RELIABILITY: tap health watchdog + system-event re-arm ===
    //
    // CGEventTaps installed at .cghidEventTap can die silently in several
    // well-known ways: callback timeout (tapDisabledByTimeout),
    // Accessibility permission toggle, display sleep/wake, screen lock/unlock.
    // The in-callback re-enable in FnKeyTap.handle() covers the timeout case
    // but cannot recover if the tap CFMachPort itself is invalidated. These
    // belt-and-suspenders mechanisms detect a dead tap and recreate it.
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObservers: [NSObjectProtocol] = []

    /// True while the CURRENT press was initiated by the CGEventTap (fnKeyDown),
    /// false when NSEvent initiated it (handleEvent LATCH ON). Used to prevent
    /// the NSEvent monitor from firing a spurious LATCH OFF while fn is still
    /// physically held — the tap's fnKeyUp() is the only authoritative release
    /// for fn presses. Without this guard, any unmatched NSEvent (e.g. a keyDown
    /// for any character key) would enter the `!isDown && hotkeyIsDown` branch
    /// and prematurely fire transition(.keyUp), dropping the recording.
    @ObservationIgnored private var pressInitiatedByFnTap = false

    /// The CGEventTap that consumes the `fn` key so macOS doesn't pop the
    /// emoji / dictation picker. Drives the SAME state machine as the NSEvent
    /// path. Created lazily in `startMonitoring()`; nil if tap creation failed
    /// (then we rely purely on the passive NSEvent monitor).
    @ObservationIgnored private var fnKeyTap: FnKeyTap?

    /// True when the CGEventTap is live and successfully consuming fn. While
    /// true, the NSEvent monitor must NOT also process fn-based bindings (the
    /// tap already drives them) — otherwise every fn press would fire twice.
    @ObservationIgnored private var fnTapActive = false

    /// fn modifier bit, matching `CapturedHotkey` / NSEvent.ModifierFlags.function.
    @ObservationIgnored private static let fnMask: UInt = 0x800000

    /// One-time guard so we only write the `AppleFnUsageType` default once.
    @ObservationIgnored private static var didWriteFnUsageDefault = false

    /// Which role (PTT vs hands-free) owns the current press. Captured on
    /// keyDown, cleared on keyUp. Lets us route the release correctly
    /// (PTT → state machine; hands-free → no-op on release).
    @ObservationIgnored private var activeRole: HotkeyRole?

    /// PTT vs quick-tap boundary. Hold beyond this → PTT. 200ms is
    /// comfortable: easy to hold while speaking, short enough that a
    /// deliberate double-tap first press (typically 80–150ms) stays under it.
    @ObservationIgnored private let shortTapThreshold: TimeInterval = 0.20

    /// Second-tap acceptance window after the first release.
    @ObservationIgnored private let doubleTapWindow: TimeInterval = 0.40

    // MARK: - Lifecycle

    func startMonitoring() {
        stopMonitoring()

        // Belt-and-suspenders emoji suppression. The CGEventTap consuming the
        // fn flagsChanged is the PRIMARY mechanism; this preference is honored
        // by some macOS versions to make the fn key "Do Nothing". One-time.
        Self.disableFnEmojiSystemBindingIfNeeded()

        // === Primary: CGEventTap for fn / fn+Space (can CONSUME events) ===
        // Only install when at least one fn-based binding exists (the default).
        // If the user rebinds everything off fn (e.g. to Ctrl+Opt on an
        // external keyboard), the tap is unnecessary and the NSEvent monitor
        // below handles it.
        fnTapActive = false
        if anyFnBinding {
            let tap = FnKeyTap()
            tap.delegate = self
            if tap.start() {
                fnKeyTap = tap
                fnTapActive = true
            } else {
                // tapCreate failed (logged inside FnKeyTap) — fall back to the
                // passive NSEvent monitor below. fn suppression won't work, but
                // the hotkey itself still functions.
                fnKeyTap = nil
            }
        }

        // === Fallback / non-fn bindings: passive NSEvent monitor ===
        // Always installed. When the fn tap is active it SKIPS fn-based events
        // (handleEvent guards on fnTapActive) so we never double-fire; it still
        // services any non-fn bindings (e.g. Ctrl+Opt) the user added.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        // === Escape key cancel-in-flight monitor ===
        // Virtual keycode 53 (kVK_Escape) WITHOUT any modifiers. We listen
        // GLOBALLY (events outside VOICE) and LOCALLY (when VOICE is
        // frontmost) so the cancel works regardless of app focus. The
        // monitors do NOT consume the event — Esc continues to dismiss the
        // host app's UI as usual. The AppDelegate decides whether to act on
        // it; idle Esc is a no-op so we never shadow system-wide Esc semantics.
        let escapeKeyCode: UInt16 = 53
        let isPlainEscape: (NSEvent) -> Bool = { event in
            guard event.keyCode == escapeKeyCode else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return mods.isEmpty
        }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard isPlainEscape(event) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .voiceEscapePressed, object: nil)
            }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPlainEscape(event) else { return event }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .voiceEscapePressed, object: nil)
            }
            // Return the event unmodified so first-responder dismissal still works.
            return event
        }

        if hotkeyChangeObserver == nil {
            hotkeyChangeObserver = NotificationCenter.default.addObserver(
                forName: .voiceHotkeyChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                print("[VOICE-HK] Hotkey choice changed — re-binding monitors")
                self?.startMonitoring()
            }
        }

        // === Reliability watchdogs ===
        installHealthTimer()
        installSystemObservers()

        let pttDesc = pttBindings.map { $0.displayName }.joined(separator: ", ")
        let lockDesc = lockBindings.map { $0.displayName }.joined(separator: ", ")
        print("[VOICE-HK] Monitoring started — PTT: \(pttDesc)  Hands-free: \(lockDesc)  fnTap=\(fnTapActive ? "active" : "off")")
    }

    func stopMonitoring() {
        fnKeyTap?.stop()
        fnKeyTap = nil
        fnTapActive = false
        pressInitiatedByFnTap = false
        hotkeyIsDown = false
        activeRole = nil
        // Keep the state machine consistent with the latch. stopMonitoring()
        // force-clears hotkeyIsDown; if `state` were left at .pressed / .armed /
        // .lockedAndPressed the two would desync and the next fresh press would
        // hit a defensive no-op (e.g. (.pressed, .keyDown)), wedging the hotkey.
        // This matters on the recreateTapIfNeeded() → startMonitoring() rebuild
        // path (sleep/wake, AX-permission toggle), which tears down via here.
        // A live .locked recording is owned by the delegate's recordingState, not
        // by `state`, so resetting the FSM doesn't abort it — the user can still
        // tap to stop. The pending double-tap timer is invalidated below, so
        // dropping out of .armed loses no in-flight commit.
        if state != .idle {
            Telemetry.log("hotkey.fsm_reset", properties: ["from": "\(state)"])
            state = .idle
            isHotkeyActive = false
            pressDownAt = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = escapeGlobalMonitor { NSEvent.removeMonitor(m); escapeGlobalMonitor = nil }
        if let m = escapeLocalMonitor { NSEvent.removeMonitor(m); escapeLocalMonitor = nil }
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil

        // Tear down reliability watchdogs. They're reinstalled by every
        // startMonitoring() call (used on first start AND on every re-arm path),
        // so it's safe to release them unconditionally here.
        healthTimer?.invalidate()
        healthTimer = nil
        for obs in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        systemObservers.removeAll()
        for obs in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        distributedObservers.removeAll()
    }

    // MARK: - Reliability: Tap Health Watchdog
    //
    // CGEventTaps at .cghidEventTap die in several well-known ways:
    //   • Callback timeout → tapDisabledByTimeout (handled in-callback in FnKeyTap)
    //   • Accessibility permission toggle → tap silently invalidated
    //   • Display sleep/wake, screen lock/unlock → tap may go inert
    // These watchdogs detect a dead tap and recreate it.

    /// Periodic check that re-enables the fn tap if macOS disabled it.
    /// In-callback re-enable in FnKeyTap.handle() is the primary defense;
    /// this catches cases where the disabled-event never reaches the callback.
    private func installHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func healthCheck() {
        guard fnTapActive, let tap = fnKeyTap else { return }
        if !tap.isAlive() {
            print("[VOICE-HK] health check: fn tap is dead — recreating")
            Telemetry.log("hotkey.eventtap_dead", properties: ["source": "healthCheck"])
            recreateTapIfNeeded()
        }
    }

    /// Subscribes to system events that historically kill CGEventTaps.
    /// Each handler funnels through `recreateTapIfNeeded`, which re-arms
    /// in place when possible and fully rebuilds when necessary.
    private func installSystemObservers() {
        for obs in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        systemObservers.removeAll()
        for obs in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        distributedObservers.removeAll()

        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            let rawName = name.rawValue
            let obs = wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                print("[VOICE-HK] system event \(rawName) — checking tap health")
                self.recreateTapIfNeeded()
                self.resyncModifierLatchAfterSystemEvent()
            }
            systemObservers.append(obs)
        }

        // Distributed notifications: screen unlock + Accessibility permission
        // change. The .cghidEventTap requires Accessibility, so if it was just
        // granted, recreateTapIfNeeded() succeeds here.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsUnlocked", "com.apple.accessibility.api"] {
            let obs = dnc.addObserver(
                forName: NSNotification.Name(name),
                object: nil, queue: .main
            ) { [weak self] _ in
                print("[VOICE-HK] distributed event \(name) — checking tap health")
                self?.recreateTapIfNeeded()
                self?.resyncModifierLatchAfterSystemEvent()
            }
            distributedObservers.append(obs)
        }
    }

    /// If the fn tap should be active but isn't, recreate it. No-op when healthy.
    private func recreateTapIfNeeded() {
        // Case A: tap should be on AND is healthy → nothing to do.
        if fnTapActive, let tap = fnKeyTap, tap.isAlive() {
            return
        }
        // Case B: tap exists but disabled → cheap re-arm first.
        if fnTapActive, let tap = fnKeyTap {
            tap.rearm()
            if tap.isAlive() {
                print("[VOICE-HK] tap rearmed in place")
                Telemetry.log("hotkey.eventtap_reenabled", properties: ["how": "rearm"])
                return
            }
        }
        // Case C: full rebuild. startMonitoring() tears down and reinstalls
        // everything (tap, NSEvent monitors, observers, timer).
        print("[VOICE-HK] recreating event tap from scratch")
        Telemetry.log("hotkey.eventtap_reenabled", properties: ["how": "rebuild"])
        startMonitoring()
    }

    /// Fix 5: modifier-flag desync recovery. If sleep/lock dropped the physical
    /// key-up event for the bound modifier, we'd be stuck in `hotkeyIsDown=true`
    /// forever and the recording would never stop. After every system event,
    /// if no relevant modifier is currently held, force the latch off so the
    /// next press is treated as fresh.
    private func resyncModifierLatchAfterSystemEvent() {
        guard hotkeyIsDown else { return }
        let currentFlags = NSEvent.modifierFlags.rawValue
        let relevantMask: UInt =
            0x40 | 0x20 | 0x10 | 0x8 | 0x2000 | 0x1 | 0x4 | 0x2 | 0x800000
        if (currentFlags & relevantMask) == 0 {
            print("[VOICE-HK] modifier latch desync detected — clearing stale hotkeyIsDown")
            Telemetry.log("hotkey.latch_desync_cleared", properties: ["state": "\(state)"])
            hotkeyIsDown = false
            activeRole = nil
            pressInitiatedByFnTap = false
            // If the state machine thinks a key is still physically held, release
            // it safely. Both .pressed AND .lockedAndPressed are "key-is-down"
            // states whose only exit is a keyUp — if sleep/wake swallowed that
            // keyUp we'd be wedged forever (recording never stops, or the lock
            // exit never completes). Synthesize the keyUp for both.
            switch state {
            case .pressed, .lockedAndPressed:
                transition(event: .keyUp)
            default:
                break
            }
        }
    }

    /// True if any PTT or hands-free binding uses the fn modifier. When true we
    /// install the CGEventTap to suppress the OS emoji popup; otherwise the
    /// passive NSEvent monitor alone is enough.
    @ObservationIgnored
    private var anyFnBinding: Bool {
        let usesFn: (CapturedHotkey) -> Bool = { ($0.modifiersRaw & Self.fnMask) != 0 }
        return pttBindings.contains(where: usesFn) || lockBindings.contains(where: usesFn)
    }

    /// Belt-and-suspenders: write `AppleFnUsageType = 0` ("Do Nothing") to the
    /// global (NSGlobalDomain) preferences so the fn key does not trigger the
    /// emoji picker or dictation. Honored on some macOS versions; the event-tap
    /// consumption in `FnKeyTap` is the primary, reliable mechanism. One-time
    /// per launch, behind a static flag, and logged.
    private static func disableFnEmojiSystemBindingIfNeeded() {
        guard !didWriteFnUsageDefault else { return }
        didWriteFnUsageDefault = true
        // suiteName: nil targets the global (NSGlobalDomain / .GlobalPreferences) domain.
        if let global = UserDefaults(suiteName: nil) {
            global.set(0, forKey: "AppleFnUsageType")
            print("[VOICE-HK] Wrote AppleFnUsageType=0 to global prefs (fn → Do Nothing). Primary suppression is the CGEventTap.")
        } else {
            print("[VOICE-HK] Could not open global prefs to write AppleFnUsageType — relying on CGEventTap only.")
        }
    }

    // MARK: - Raw Event Handling

    private func handleEvent(_ event: NSEvent) {
        let matchedRoleNow = matchedRole(event)
        let isDown = matchedRoleNow != nil

        if isDown && !hotkeyIsDown {
            hotkeyIsDown = true
            pressInitiatedByFnTap = false  // this press came from NSEvent, not the fn tap
            activeRole = matchedRoleNow
            print("[VOICE-HK] LATCH ON  role=\(matchedRoleNow?.rawValue ?? "?") eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=0x\(String(event.modifierFlags.rawValue, radix: 16))")
            if matchedRoleNow == .handsFree {
                // Hands-free: single tap toggles lock immediately.
                transition(event: .handsFreeTap)
            } else {
                transition(event: .keyDown)
            }
        } else if !isDown && hotkeyIsDown {
            // If the CGEventTap owns this press, it — not NSEvent — is authoritative
            // for the release. fnKeyUp() will fire when fn is physically lifted.
            // Letting NSEvent fire LATCH OFF here would prematurely drop the recording:
            // any unmatched event (e.g. pressing a letter key while fn is held) would
            // enter this branch and call transition(.keyUp) while fn is still down.
            if pressInitiatedByFnTap {
                return
            }
            hotkeyIsDown = false
            let prevRole = activeRole
            activeRole = nil
            print("[VOICE-HK] LATCH OFF role=\(prevRole?.rawValue ?? "?") eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=0x\(String(event.modifierFlags.rawValue, radix: 16))")
            if prevRole == .handsFree {
                // No-op on release for hands-free; the toggle happened on press.
                return
            }
            transition(event: .keyUp)
        }
    }

    /// Which role (if any) the event matches. Tested against ALL bindings for each role.
    /// Returns nil if event matches neither role.
    ///
    /// CONFLICT POLICY: PTT wins. If the user has assigned the same hotkey to
    /// both roles (a misconfiguration, but possible from the UI), PTT is checked
    /// first and short-circuits, so PTT semantics win deterministically.
    /// This matters for any single press to behave consistently across launches.
    private func matchedRole(_ event: NSEvent) -> HotkeyRole? {
        // When the CGEventTap is live it owns all fn-based bindings (it both
        // drives the state machine AND consumes the event). The NSEvent monitor
        // must therefore SKIP fn bindings here, or every fn press fires twice.
        // Non-fn bindings (e.g. a user-added Ctrl+Opt) still flow through.
        let skipFn = fnTapActive
        for b in pttBindings {
            if skipFn && (b.modifiersRaw & Self.fnMask) != 0 { continue }
            if b.matches(event, hotkeyIsDown: hotkeyIsDown) { return .pushToTalk }
        }
        for b in lockBindings {
            if skipFn && (b.modifiersRaw & Self.fnMask) != 0 { continue }
            if b.matches(event, hotkeyIsDown: hotkeyIsDown) { return .handsFree }
        }
        return nil
    }

    // MARK: - State Machine
    //
    // ┌────────────────────┬─────────────────────┬──────────────────────────┬────────────────────────────────────────────┐
    // │ from               │ event               │ to                       │ delegate calls (in order)                  │
    // ├────────────────────┼─────────────────────┼──────────────────────────┼────────────────────────────────────────────┤
    // │ idle               │ keyDown             │ pressed(now)             │ hotkeyDidActivate                          │
    // │ idle               │ keyUp               │ idle (no-op)             │ —                                          │
    // │ idle               │ windowExpired       │ idle (no-op, log)        │ —                                          │
    // │ idle               │ handsFreeTap        │ locked                   │ hotkeyDidActivate, hotkeyDidDoubleTap      │
    // │ pressed            │ keyDown             │ pressed (no-op, log)     │ —  (latch in handleEvent prevents this)    │
    // │ pressed (held≥thr) │ keyUp               │ idle                     │ hotkeyDidDeactivate (PTT commit)           │
    // │ pressed (held<thr) │ keyUp               │ armed (start timer)      │ —                                          │
    // │ pressed            │ windowExpired       │ pressed (no-op, log)     │ —                                          │
    // │ pressed            │ handsFreeTap        │ pressed (no-op, log)     │ —                                          │
    // │ armed              │ keyDown             │ locked                   │ hotkeyDidDoubleTap (double-tap confirmed)  │
    // │ armed              │ keyUp               │ armed (no-op, log)       │ —                                          │
    // │ armed              │ windowExpired       │ idle                     │ hotkeyDidQuickRelease (stray, discard)     │
    // │ armed              │ handsFreeTap        │ armed (no-op, log)       │ —                                          │
    // │ locked             │ keyDown             │ lockedAndPressed         │ hotkeyDidActivate (third-tap exit+commit)  │
    // │ locked             │ keyUp               │ locked (no-op)           │ —                                          │
    // │ locked             │ windowExpired       │ locked (no-op, log)      │ —                                          │
    // │ locked             │ handsFreeTap        │ idle                     │ hotkeyDidActivate (exits via path 1)       │
    // │ lockedAndPressed   │ keyDown             │ lockedAndPressed (log)   │ —  (latch in handleEvent prevents this)    │
    // │ lockedAndPressed   │ keyUp               │ idle                     │ —  (delegate already committed on keyDown) │
    // │ lockedAndPressed   │ windowExpired       │ lockedAndPressed (log)   │ —                                          │
    // │ lockedAndPressed   │ handsFreeTap        │ lockedAndPressed (log)   │ —                                          │
    // └────────────────────┴─────────────────────┴──────────────────────────┴────────────────────────────────────────────┘
    //
    // NOTE on (.locked, .handsFreeTap) firing hotkeyDidActivate (not Deactivate):
    //   The delegate's hotkeyDidActivate inspects recordingState.isLocked to
    //   route between "fresh press" and "third-tap exit". recordingState
    //   stays true here (it's only flipped false by the delegate's
    //   exitLockMode call), so the delegate correctly takes the exit path.
    //   hotkeyService.isLocked is a separate hint flag, intentionally
    //   pre-cleared so future events don't see stale lock state.

    /// All state changes pass through here. Delegate callbacks run
    /// synchronously on the main queue — when this function returns, any
    /// delegate side-effects (like flipping recording state) are committed.
    private func transition(event: Event) {
        let before = state

        switch (state, event) {

        // .idle ── keyDown ──▶ .pressed
        case (.idle, .keyDown):
            let now = Date()
            state = .pressed(since: now)
            pressDownAt = now
            isHotkeyActive = true
            Telemetry.log("hotkey.activate", properties: ["from": "idle"])
            fireDelegateSync { $0.hotkeyDidActivate() }

        // .pressed ── keyUp ──▶ .idle (long hold) or .armed (short tap)
        //
        // Long hold (≥ threshold): PTT commit immediately on release.
        //
        // Short tap (< threshold): enter the double-tap window (.armed). The
        // recording from the first tap stays live. If a second fn press arrives
        // within `doubleTapWindow` → lock mode (hands-free). If the timer fires
        // with no second tap → hotkeyDidQuickRelease (silent discard).
        //
        // Safety: the CGEventTap synthesizes fnKeyUp on re-enable after a timeout,
        // and fnKeyUp now always clears hotkeyIsDown, so a dropped fn-up can no
        // longer leave the machine stuck in .pressed.
        case (.pressed(let since), .keyUp):
            let held = Date().timeIntervalSince(since)
            if held < shortTapThreshold {
                state = .armed          // wait for possible second tap
                startDoubleTapTimer()   // fires hotkeyDidQuickRelease if no second tap
                // isHotkeyActive stays true — recording is still live during the window
            } else {
                state = .idle
                isHotkeyActive = false
                pressDownAt = nil
                Telemetry.log("hotkey.deactivate", properties: ["held_ms": Int(held * 1000)])
                fireDelegateSync { $0.hotkeyDidDeactivate() }
            }

        // .armed ── keyDown within window ──▶ .locked (double-tap confirmed)
        case (.armed, .keyDown):
            cancelDoubleTapTimer()
            state = .locked
            isLocked = true
            pressDownAt = Date()
            Telemetry.log("hotkey.doubletap_lock", properties: ["from": "armed"])
            fireDelegateSync { $0.hotkeyDidDoubleTap() }

        // .armed ── window expired ──▶ .idle (no double-tap, discard)
        case (.armed, .doubleTapWindowExpired):
            state = .idle
            isHotkeyActive = false
            pressDownAt = nil
            Telemetry.log("hotkey.quick_release")
            fireDelegateSync { $0.hotkeyDidQuickRelease() }

        // .locked ── keyDown ──▶ .lockedAndPressed (third tap — exit + commit)
        case (.locked, .keyDown):
            state = .lockedAndPressed
            pressDownAt = Date()
            Telemetry.log("hotkey.activate", properties: ["from": "locked"])
            fireDelegateSync { $0.hotkeyDidActivate() }

        // .armed ── keyUp ──▶ ignored
        case (.armed, .keyUp):
            print("[VOICE-HK] keyUp in .armed (unexpected, ignored)")
            return

        // .locked ── keyUp ──▶ .locked (no-op)
        case (.locked, .keyUp):
            return

        // .lockedAndPressed ── keyUp ──▶ .idle (lock exit complete)
        case (.lockedAndPressed, .keyUp):
            state = .idle
            isLocked = false
            isHotkeyActive = false
            pressDownAt = nil

        // === Hands-free tap handling ===

        // .idle ── handsFreeTap ──▶ .locked
        case (.idle, .handsFreeTap):
            state = .locked
            isLocked = true
            isHotkeyActive = true
            pressDownAt = Date()
            Telemetry.log("hotkey.doubletap_lock", properties: ["from": "handsfree"])
            fireDelegateSync { $0.hotkeyDidActivate() }
            fireDelegateSync { $0.hotkeyDidDoubleTap() }

        // .locked ── handsFreeTap ──▶ .idle
        case (.locked, .handsFreeTap):
            state = .idle
            isLocked = false
            isHotkeyActive = false
            pressDownAt = nil
            Telemetry.log("hotkey.deactivate", properties: ["from": "handsfree_unlock"])
            fireDelegateSync { $0.hotkeyDidActivate() }

        // .pressed ── handsFreeTap ──▶ .locked
        // fn + Space: fn alone already fired .keyDown (PTT), so a recording is
        // live and state is .pressed. The Space half then arrives as a
        // handsFreeTap. Promote the in-flight PTT recording to lock mode — same
        // path a double-tap takes from .armed. We do NOT re-activate (recording
        // already started); we only fire hotkeyDidDoubleTap so the delegate
        // calls enterLockMode() and the existing recording continues seamlessly.
        case (.pressed, .handsFreeTap):
            state = .locked
            isLocked = true
            isHotkeyActive = true
            // Keep pressDownAt — the recording that began on the fn .keyDown
            // owns it; lock mode doesn't restart the recording.
            Telemetry.log("hotkey.doubletap_lock", properties: ["from": "pressed"])
            fireDelegateSync { $0.hotkeyDidDoubleTap() }

        // .armed ── handsFreeTap ──▶ .locked
        // Same as above but the fn tap was so brief it already released into
        // .armed before Space landed. Cancel the pending quick-tap discard and
        // lock the still-running recording.
        case (.armed, .handsFreeTap):
            cancelDoubleTapTimer()
            state = .locked
            isLocked = true
            isHotkeyActive = true
            // BUGFIX: clear hotkeyIsDown + pressDownAt so a subsequent fn tap
            // is treated as a fresh press against the lock state, not as a
            // continuation of the prior (already-released) press. Prevents
            // third-tap collision after fn+Space combo.
            hotkeyIsDown = false
            pressDownAt = nil
            Telemetry.log("hotkey.doubletap_lock", properties: ["from": "armed_fnspace"])
            fireDelegateSync { $0.hotkeyDidDoubleTap() }

        // Defensive — handsFreeTap while a lock-exit press is mid-flight: ignore.
        case (.lockedAndPressed, .handsFreeTap):
            print("[VOICE-HK] Unhandled handsFreeTap in state \(state) — ignored")
            return

        // Defensive no-ops.
        case (.idle, .keyUp),
             (.idle, .doubleTapWindowExpired),
             (.pressed, .keyDown),
             (.pressed, .doubleTapWindowExpired),
             (.locked, .doubleTapWindowExpired),
             (.lockedAndPressed, .keyDown),
             (.lockedAndPressed, .doubleTapWindowExpired):
            print("[VOICE-HK] Unhandled event \(event) in state \(before) — ignored")
            return
        }

        print("[VOICE-HK] \(before) ──\(event)──▶ \(state)  (isLocked=\(isLocked) isHotkeyActive=\(isHotkeyActive))")
    }

    // MARK: - Double-tap Window Timer

    private func startDoubleTapTimer() {
        cancelDoubleTapTimer()
        let timer = Timer(timeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
            self?.transition(event: .doubleTapWindowExpired)
        }
        RunLoop.main.add(timer, forMode: .common)
        doubleTapTimer = timer
    }

    private func cancelDoubleTapTimer() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
    }

    // MARK: - Delegate Dispatch

    private func fireDelegateSync(_ block: @MainActor @escaping (HotkeyServiceDelegate) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let d = delegate { block(d) }
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    if let d = self?.delegate { block(d) }
                }
            }
        }
    }

    deinit {
        stopMonitoring()
        // `hotkeyChangeObserver` is intentionally registered once for the
        // lifetime of the service (so .voiceHotkeyChanged re-arms even when
        // monitoring is paused), so it isn't torn down in stopMonitoring().
        // Clean it up here on final teardown to avoid a stranded NotificationCenter
        // token. The observer captures `[weak self]` so this is belt-and-suspenders.
        if let token = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(token)
            hotkeyChangeObserver = nil
        }
    }
}

// MARK: - FnKeyTapDelegate
//
// The CGEventTap delivers these on the MAIN thread (its run-loop source is on
// the main run loop). Each one drives the SAME state machine the NSEvent path
// uses, with identical latch bookkeeping (hotkeyIsDown / activeRole), so PTT
// hold/release and the double-tap-to-lock semantics are byte-for-byte the same
// whether they arrive via the tap or the fallback monitor.
//
// Mapping (matches Wispr Flow):
//   fn held alone           → PTT  → .keyDown / .keyUp through the state machine
//   fn + Space              → hands-free toggle → .handsFreeTap (the delegate
//                             routes this to lock via hotkeyDidDoubleTap, i.e.
//                             the same "locked" path double-tap uses)
extension HotkeyService: FnKeyTapDelegate {

    func fnKeyDown() {
        // Fresh PTT press. Mirror handleEvent's LATCH ON.
        // Guard against double-fire if fn generates repeated events while held.
        guard !hotkeyIsDown else { return }
        hotkeyIsDown = true
        pressInitiatedByFnTap = true  // NSEvent must not steal the LATCH OFF
        activeRole = .pushToTalk
        print("[VOICE-HK] LATCH ON  role=ptt source=fnTap (fn down)")
        transition(event: .keyDown)
    }

    func fnKeyUp() {
        // fn lifted. Always clear the fn-tap ownership flag so NSEvent can
        // operate normally again after this point.
        pressInitiatedByFnTap = false

        guard hotkeyIsDown else {
            // Already cleared (e.g. tap re-enabled and synthesized early keyUp).
            activeRole = nil
            return
        }
        let wasOwnedByPTT = (activeRole == .pushToTalk)
        hotkeyIsDown = false
        activeRole = nil

        guard wasOwnedByPTT else {
            // fn went down as part of a non-PTT context; nothing to commit.
            return
        }
        print("[VOICE-HK] LATCH OFF role=ptt source=fnTap (fn up)")
        // The state machine handles all cases correctly:
        //   .pressed + .keyUp  → commit or quickRelease
        //   .locked  + .keyUp  → no-op (lock continues; user must press fn again
        //                        to exit, which now works because hotkeyIsDown=false)
        //   .idle    + .keyUp  → defensive no-op (log)
        transition(event: .keyUp)
    }

    func fnSpacePressed() {
        // fn+Space is no longer the hands-free trigger (double-tap fn replaced it).
        // FnKeyTap no longer calls this — kept as a no-op so the delegate
        // protocol conformance compiles without changes to the protocol itself.
    }
}

// MARK: - Hotkey Capturer

/// Captures the next non-modifier key press AS a binding. The completion fires once
/// with the captured CapturedHotkey, or nil if cancelled/escape pressed.
/// Internally suspends the main hotkey monitors so the capture doesn't fire them.
@MainActor
final class HotkeyCapturer {
    private var keyMonitor: Any?
    private var modMonitor: Any?
    private var completion: ((CapturedHotkey?) -> Void)?
    /// Track latest modifiers seen so a pure-modifier release commits.
    private var lastModifiersRaw: UInt = 0

    private static let relevantMask: UInt =
        0x40 | 0x20 | 0x10 | 0x8 | 0x2000 | 0x1 | 0x4 | 0x2 | 0x800000

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = modMonitor { NSEvent.removeMonitor(m) }
    }

    func startCapture(completion: @escaping (CapturedHotkey?) -> Void) {
        cancel()  // clean any prior
        self.completion = completion
        self.lastModifiersRaw = 0

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                // Escape cancels.
                self.finish(nil)
                return nil
            }
            let masked = event.modifierFlags.rawValue & HotkeyCapturer.relevantMask
            let captured = CapturedHotkey(keyCode: event.keyCode, modifiersRaw: masked)
            self.finish(captured)
            return nil  // swallow the key so it doesn't go to focused field
        }

        modMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let masked = event.modifierFlags.rawValue & HotkeyCapturer.relevantMask
            // If user pressed a modifier (mask grew), record it and wait for more or release.
            // If they release without pressing a key, commit the modifier-only binding.
            if masked > self.lastModifiersRaw {
                self.lastModifiersRaw = masked
            } else if masked < self.lastModifiersRaw && self.lastModifiersRaw != 0 {
                // Release — commit modifier-only binding with what was held.
                let captured = CapturedHotkey(keyCode: nil, modifiersRaw: self.lastModifiersRaw)
                self.finish(captured)
            }
            return event
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ captured: CapturedHotkey?) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = modMonitor { NSEvent.removeMonitor(m); modMonitor = nil }
        let c = completion; completion = nil
        c?(captured)
    }
}
