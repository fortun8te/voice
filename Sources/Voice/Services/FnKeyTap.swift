// VOICE — Fn Key Event Tap
// ============================================================
// THE PROBLEM
//
// `NSEvent.addGlobalMonitorForEvents` is a PASSIVE monitor. It can observe
// events but cannot consume them. So when the user taps the `fn` key alone,
// macOS still fires its built-in "Press fn key to: Show Emoji & Symbols /
// Start Dictation" action. A passive monitor cannot stop that.
//
// THE FIX
//
// A CGEventTap installed at `.cghidEventTap` (the lowest level, before the
// window server interprets fn) CAN consume events. The `fn` key arrives as a
// `.flagsChanged` CGEvent carrying the `CGEventFlags.maskSecondaryFn` bit.
// Returning `nil` from the tap callback for a clean fn-only flagsChanged
// swallows it, so the emoji/dictation picker never sees a clean fn tap.
//
// WHAT THIS WRAPPER DOES
//
//   * Detects fn via `event.flags.contains(.maskSecondaryFn)`.
//   * Detects the Space keyCode (49) for the fn+Space hands-free combo.
//   * Maintains fn-down latch state and emits high-level events through
//     `FnKeyTapDelegate`:
//        - fnPressed / fnReleased  → drives push-to-talk
//        - fnSpacePressed          → drives hands-free toggle
//   * SWALLOWS clean fn-only flagsChanged events (returns nil) so the emoji
//     picker is suppressed. fn+other-key combos that aren't ours pass through
//     unchanged so the rest of the system (and other apps) behave normally.
//   * Re-enables itself if the tap is disabled by timeout / user input.
//   * Falls back gracefully: if `CGEvent.tapCreate` returns nil (e.g. no
//     Accessibility permission), `start()` returns false and the caller can
//     fall back to a passive NSEvent monitor so the app still works.
//
// THREADING
//
// The C callback runs on whatever run loop the tap source is attached to —
// here, the MAIN run loop. We still hop to the main actor explicitly before
// invoking the delegate (the delegate touches RecordingState / UI), matching
// the rest of the hotkey pipeline's main-actor discipline.
// ============================================================

import Foundation
import CoreGraphics
import AppKit

// MARK: - Delegate

/// High-level fn-key events emitted by the tap. All callbacks are delivered on
/// the main thread.
protocol FnKeyTapDelegate: AnyObject {
    /// fn pressed alone (no other modifiers, no key chord). Push-to-talk down.
    func fnKeyDown()
    /// fn released. Push-to-talk up.
    func fnKeyUp()
    /// fn + Space pressed together. Hands-free toggle.
    func fnSpacePressed()
}

// MARK: - FnKeyTap

final class FnKeyTap {

    weak var delegate: FnKeyTapDelegate?

    /// Space virtual key code.
    private static let spaceKeyCode: Int64 = 49

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// True while fn is physically held (after a clean fn-only flagsChanged on).
    private var fnDown = false

    // MARK: Lifecycle

    /// Installs the event tap on the main run loop.
    /// Returns true on success, false if the tap could not be created (caller
    /// should fall back to a passive NSEvent monitor in that case).
    @discardableResult
    func start() -> Bool {
        stop()

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        // Bridge `self` into the C callback via the userInfo pointer.
        // passUnretained: the tap's lifetime is bounded by this object, which
        // calls stop() in deinit, so the raw pointer never outlives `self`.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnKeyTapCallback,
            userInfo: userInfo
        ) else {
            print("[VOICE-HK] CGEventTap creation failed — falling back to passive monitor")
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[VOICE-HK] CGEventTap installed at kCGHIDEventTap — fn suppression active")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        fnDown = false
    }

    deinit { stop() }

    /// True if the tap CFMachPort exists AND macOS still has it enabled.
    /// Used by HotkeyService's health watchdog: if this returns false while
    /// the service believes the tap is active, the tap is recreated.
    func isAlive() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Re-enable the tap in place without tearing it down. Cheap recovery
    /// path for cases where macOS disabled the tap but the CFMachPort is
    /// still valid (the common timeout / brief-disable case).
    func rearm() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: Tap callback (called from the C trampoline below)

    /// Core event handling. Returns the (possibly nil) event to forward.
    /// Returning nil consumes the event; returning the passed event forwards it.
    fileprivate func handle(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if the system disabled it (slow callback or user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[VOICE-HK] CGEventTap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
            // RECOVERY: while the tap was disabled, the physical fn-up may have
            // been dropped. If we still think fn is held, we'd be stuck holding a
            // recording forever. Reconcile by firing the release now — a slightly
            // early commit is far better than a permanently stuck recording.
            if fnDown {
                fnDown = false
                print("[VOICE-HK] tap re-enable while fnDown — synthesizing fnKeyUp to avoid stuck recording")
                dispatchMain { [weak self] in self?.delegate?.fnKeyUp() }
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnBit = flags.contains(.maskSecondaryFn)

        // Other "real" modifiers (cmd/ctrl/alt/shift). fn itself is excluded.
        let otherModifiers: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift,
        ]
        let hasOtherModifier = !flags.intersection(otherModifiers).isEmpty

        switch type {

        case .flagsChanged:
            // We only act on the fn bit transitioning. A *clean* fn-only change
            // (fn bit set, no other modifiers) is the emoji-trigger event we
            // must consume.
            if fnBit && !hasOtherModifier {
                if !fnDown {
                    fnDown = true
                    dispatchMain { [weak self] in self?.delegate?.fnKeyDown() }
                }
                // Swallow — this is the exact event macOS would turn into the
                // emoji / dictation popup on a clean fn tap.
                return nil
            }

            if !fnBit {
                // fn lifted (regardless of other modifiers still held).
                if fnDown {
                    fnDown = false
                    // Always deliver fnKeyUp — no suppression even after fn+Space.
                    // The state machine's (.locked, .keyUp) no-op handles it safely,
                    // and clearing hotkeyIsDown here is essential for the third-tap
                    // lock-exit to work (fnKeyDown guards on !hotkeyIsDown).
                    dispatchMain { [weak self] in self?.delegate?.fnKeyUp() }
                }
                // If the fn-up flagsChanged is otherwise clean, swallow it too so
                // the release half of a clean fn tap never reaches the emoji
                // handler. If other modifiers remain, forward it untouched.
                return hasOtherModifier ? Unmanaged.passUnretained(event) : nil
            }

            // fn is set but combined with another modifier (e.g. user pressed
            // Cmd while holding fn). Keep our latch but DON'T swallow — let the
            // combo flow to the system so app shortcuts keep working.
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // All keys (including Space) pass through freely when fn is held.
            // Hands-free is now entered by double-tapping fn, not fn+Space.
            // Forwarding every key means typing with fn held works normally and
            // no accidental Space presses trigger hands-free mode.
            return Unmanaged.passUnretained(event)

        case .keyUp:
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func dispatchMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

// MARK: - C trampoline

// CGEventTap requires a C function pointer (a closure that captures context is
// not allowed). We recover the FnKeyTap instance from the userInfo pointer.
private func fnKeyTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<FnKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(proxy: proxy, type: type, event: event)
}
