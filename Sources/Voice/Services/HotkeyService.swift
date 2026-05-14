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
// === Architecture ===
//
// All hotkey behavior is a deterministic state machine. Every NSEvent
// (keyDown/keyUp) and every timer expiry is funneled through
// `transition(event:)`. Delegate callbacks are dispatched SYNCHRONOUSLY
// on the main queue — never async — so by the time the next event fires,
// the prior callback's side-effects (e.g. flipping `state.isRecording`)
// are already committed. This is the key fix from previous broken
// iterations: async dispatch let keyUp run before keyDown's recording
// actually started, so `wasRecording` reads `false` and the press was
// silently discarded.
//
// `pressDownAt` is captured on the event-monitor thread at the EXACT
// moment of keyDown. The delegate uses this — not its own Date() — to
// compute hold duration, so dispatch latency never makes a real hold
// look like a quick tap.
// ============================================================

import Foundation
import AppKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the menu when the user picks a different hotkey.
    /// HotkeyService listens and re-binds monitors.
    static let voiceHotkeyChanged = Notification.Name("voiceHotkeyChanged")
}

// MARK: - Hotkey Options

enum HotkeyOption: String, CaseIterable, Identifiable {
    case rightOption = "right_option"
    case fn = "fn"
    case optionSpace = "option+space"
    case ctrlSpace = "ctrl+space"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "Right ⌥ (Push-to-Talk)"
        case .fn: return "fn (requires Keyboard setting)"
        case .optionSpace: return "⌥ Space"
        case .ctrlSpace: return "⌃ Space"
        }
    }
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

    /// Called when a second keyDown lands inside the double-tap window.
    /// Delegate enters lock mode. The original recording continues.
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
    }

    // MARK: Public surface

    @ObservationIgnored
    private var selectedHotkey: HotkeyOption {
        let raw = UserDefaults.standard.string(forKey: "hotkey") ?? HotkeyOption.rightOption.rawValue
        return HotkeyOption(rawValue: raw) ?? .rightOption
    }

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
    @ObservationIgnored private var hotkeyChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var hotkeyIsDown = false
    @ObservationIgnored private var doubleTapTimer: Timer?

    /// PTT vs quick-tap boundary. Hold beyond this → PTT. 300ms is
    /// comfortable: easy to hold while speaking, short enough that a
    /// deliberate double-tap first press (typically 100–200ms) stays under it.
    @ObservationIgnored private let shortTapThreshold: TimeInterval = 0.30

    /// Second-tap acceptance window after the first release.
    /// 600ms is generous for natural double-pressing a modifier key.
    @ObservationIgnored private let doubleTapWindow: TimeInterval = 0.60

    // MARK: - Lifecycle

    func startMonitoring() {
        stopMonitoring()

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
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

        print("[VOICE-HK] Monitoring started: \(selectedHotkey.displayName)")
    }

    func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
    }

    func setHotkey(_ option: HotkeyOption) {
        UserDefaults.standard.set(option.rawValue, forKey: "hotkey")
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Raw Event Handling

    private func handleEvent(_ event: NSEvent) {
        let isDown = matchesHotkey(event)

        if isDown && !hotkeyIsDown {
            hotkeyIsDown = true
            transition(event: .keyDown)
        } else if !isDown && hotkeyIsDown {
            hotkeyIsDown = false
            transition(event: .keyUp)
        }
    }

    // MARK: - State Machine

    /// All state changes pass through here. Delegate callbacks run
    /// synchronously on the main queue — when this function returns, any
    /// delegate side-effects (like flipping recording state) are committed.
    private func transition(event: Event) {
        let before = state

        switch (state, event) {

        // .idle ── keyDown ──▶ .pressed
        // Fresh press. Start recording NOW. We commit to the recording even
        // though this might turn out to be the first tap of a double-tap;
        // if so, the recording is co-opted by lock mode (no restart).
        // If the press is a stray quick tap, the .armed branch will discard.
        case (.idle, .keyDown):
            let now = Date()
            state = .pressed(since: now)
            pressDownAt = now
            isHotkeyActive = true
            fireDelegateSync { $0.hotkeyDidActivate() }

        // .pressed ── keyUp ──▶ branch on hold duration
        case (.pressed(let since), .keyUp):
            let held = Date().timeIntervalSince(since)
            if held < shortTapThreshold {
                // Quick release. Recording is still running — we defer the
                // discard decision until either the double-tap window
                // expires (then quickRelease) or a second keyDown arrives
                // (then double-tap → lock).
                state = .armed
                startDoubleTapTimer()
            } else {
                // Genuine PTT hold release. Commit.
                state = .idle
                isHotkeyActive = false
                pressDownAt = nil
                fireDelegateSync { $0.hotkeyDidDeactivate() }
            }

        // .armed ── keyDown within window ──▶ .locked (double-tap confirmed)
        // Recording from the first tap is still running. We seamlessly
        // hand it to lock mode — no restart, no duplicate start sound.
        case (.armed, .keyDown):
            cancelDoubleTapTimer()
            state = .locked
            isLocked = true
            // Update pressDownAt to NOW so the second keyDown's keyUp (if any)
            // is correctly identified as part of the locked-press, not a stale
            // first-tap value. While in locked, keyUp on the second tap is a
            // no-op (key released, lock holds). Recording continues.
            pressDownAt = Date()
            fireDelegateSync { $0.hotkeyDidDoubleTap() }

        // .armed ── window expired ──▶ .idle (no double-tap, discard)
        case (.armed, .doubleTapWindowExpired):
            state = .idle
            isHotkeyActive = false
            pressDownAt = nil
            fireDelegateSync { $0.hotkeyDidQuickRelease() }

        // .locked ── keyDown ──▶ .lockedAndPressed (third tap — exit + commit)
        case (.locked, .keyDown):
            state = .lockedAndPressed
            pressDownAt = Date()
            fireDelegateSync { $0.hotkeyDidActivate() }

        // .armed ── keyUp ──▶ .armed (stray — happens if the user released
        // the second tap while still inside the window; we just stay armed
        // and let the timer or a third keyDown decide).
        // Actually re-thinking: in .armed the key is NOT down (we got here
        // from .pressed → keyUp). So a stray keyUp in armed shouldn't
        // happen. Same logic applies. Treat as ignored.
        case (.armed, .keyUp):
            print("[VOICE-HK] keyUp in .armed (unexpected, ignored)")
            return

        // .locked ── keyUp ──▶ .locked
        // The second tap of a double-tap pattern: keyDown advanced .armed →
        // .locked, and now its matching keyUp arrives. We stay locked.
        // Recording continues. No delegate call.
        case (.locked, .keyUp):
            return

        // .lockedAndPressed ── keyUp ──▶ .idle (lock exit complete)
        case (.lockedAndPressed, .keyUp):
            state = .idle
            isLocked = false
            isHotkeyActive = false
            pressDownAt = nil

        // Defensive no-ops. These can occur if the OS drops a paired event
        // (focus change eating a keyUp) or under exotic event ordering.
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

    /// Fire the delegate callback synchronously on the main actor. NSEvent
    /// monitor callbacks always run on the main thread, so we just assume
    /// main-actor isolation and call directly. The synchronous semantics are
    /// crucial: by the time `transition()` returns, the delegate has already
    /// updated `recordingState.isRecording`, so the next event queued behind
    /// on the same main run-loop iteration sees the correct world.
    ///
    /// If somehow this is invoked off-main (defensive — shouldn't happen for
    /// NSEvent monitors), we fall back to `DispatchQueue.main.sync` to
    /// preserve ordering.
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

    // MARK: - Hotkey Matching

    private func matchesHotkey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        let rightOptionMask: UInt = 0x40
        let leftOptionMask: UInt = 0x20

        switch selectedHotkey {
        case .rightOption:
            let rightOpt = (mods.rawValue & rightOptionMask) != 0
            let leftOpt = (mods.rawValue & leftOptionMask) != 0
            return rightOpt && !leftOpt

        case .fn:
            let fnDown = mods.contains(.function)
            let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let hasOthers = !mods.intersection(others).isEmpty
            return fnDown && !hasOthers

        case .optionSpace:
            let optDown = mods.contains(.option)
            if event.type == .keyDown && event.keyCode == 49 && optDown { return true }
            if event.type == .keyUp && event.keyCode == 49 { return false }
            return hotkeyIsDown && optDown

        case .ctrlSpace:
            let ctrlDown = mods.contains(.control)
            if event.type == .keyDown && event.keyCode == 49 && ctrlDown { return true }
            if event.type == .keyUp && event.keyCode == 49 { return false }
            return hotkeyIsDown && ctrlDown
        }
    }

    deinit {
        stopMonitoring()
    }
}
