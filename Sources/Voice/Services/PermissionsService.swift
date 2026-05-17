// VOICE Permissions Service
// ============================================================
// Centralized status + request for the three macOS permissions VOICE
// needs to function:
//
//   * Accessibility    Required. Lets VOICE paste into the active text
//                      field via synthesized CGEvents after a dictation
//                      polish completes.
//   * Microphone       Required. Captures audio for transcription.
//   * Input Monitoring Optional. Improves global hotkey reliability when
//                      another app has focus and is not the system's
//                      key window. VOICE works without it, but a stray
//                      modifier capture can be missed without it.
//
// Inspired by the onboarding flow from iFurySt/open-codex-computer-use
// (PermissionOnboardingApp.swift): a single source of truth that any
// SwiftUI view can observe, with periodic polling so grants made in
// System Settings while VOICE is foreground propagate back into the UI
// without the user clicking a refresh button.
//
// Design notes:
//
//   * `refresh()` is read-only. It never displays the macOS system
//     prompt. The dedicated `requestAccessibility()` /
//     `requestMicrophone()` calls own prompting. This keeps the polling
//     loop free of side effects.
//
//   * Input Monitoring has no first-party query API. We probe it by
//     attempting to create a CGEventTap at the session event tap
//     location for `keyDown` + `flagsChanged`. If `CGEvent.tapCreate`
//     returns nil, the permission is not granted. Otherwise we tear the
//     tap down immediately. This is the technique used by every major
//     hotkey-driven Mac app (Raycast, Karabiner, etc.).
//
//   * Deep-link URLs use the documented `x-apple.systempreferences:`
//     scheme. These work on macOS 13+. The Privacy_ListenEvent pane
//     corresponds to "Input Monitoring" in System Settings.
//
//   * The service is `@MainActor` and `@Observable` so SwiftUI views
//     can observe changes without `@Published` boilerplate.
// ============================================================

import SwiftUI
import AVFoundation
import ApplicationServices
import CoreGraphics
import AppKit

@MainActor
@Observable
final class PermissionsService {
    static let shared = PermissionsService()

    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
    }

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility
        case microphone
        case inputMonitoring

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .microphone: return "Microphone"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var systemPreferencesURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }

        var requirementCopy: String {
            switch self {
            case .accessibility:
                return "Lets VOICE paste polished text into the field you were typing into."
            case .microphone:
                return "Lets VOICE listen so it can transcribe what you say."
            case .inputMonitoring:
                return "Optional. Makes the global hotkey more reliable across all apps."
            }
        }

        var symbolName: String {
            switch self {
            case .accessibility: return "accessibility"
            case .microphone: return "mic.fill"
            case .inputMonitoring: return "keyboard"
            }
        }

        var isRequired: Bool {
            switch self {
            case .accessibility, .microphone: return true
            case .inputMonitoring: return false
            }
        }
    }

    // MARK: Observable state

    var accessibility: Status = .notDetermined
    var microphone: Status = .notDetermined
    var inputMonitoring: Status = .notDetermined

    /// True once every required permission is granted. Input Monitoring
    /// is intentionally excluded; it is optional, and gating onboarding
    /// completion on it would block users who do not want to grant it.
    var allGranted: Bool {
        accessibility == .granted && microphone == .granted
    }

    /// Subset accessor for views that render one row per Kind.
    func status(for kind: Kind) -> Status {
        switch kind {
        case .accessibility: return accessibility
        case .microphone: return microphone
        case .inputMonitoring: return inputMonitoring
        }
    }

    // MARK: Lifecycle

    private init() {}

    // MARK: Polling

    private var monitorTimer: Timer?

    /// Installs a 0.7-second repeating Timer that calls `refresh()`, plus
    /// a NSApplication.didBecomeActive observer that refreshes immediately
    /// when the user returns from System Settings. Views presenting onboarding
    /// should call this in `.task` so out-of-app grants propagate back
    /// without lag.
    func startMonitoring() {
        stopMonitoring()
        // Immediate refresh — UI is correct on first paint.
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer

        // Refresh immediately when the app comes back to focus — the user
        // just granted in System Settings and switched back. Without this,
        // there's up to 0.7s of stale "not granted" before the timer fires.
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
    }

    private var didBecomeActiveObserver: NSObjectProtocol?

    // MARK: Refresh

    /// Re-reads the three permission statuses. Read-only; never shows
    /// the macOS system prompt. Safe to call on a timer.
    func refresh() {
        accessibility = currentAccessibilityStatus()
        microphone = currentMicrophoneStatus()
        inputMonitoring = currentInputMonitoringStatus()
    }

    private func currentAccessibilityStatus() -> Status {
        // AXIsProcessTrusted is the read-only check. The options-dict
        // variant (AXIsProcessTrustedWithOptions with prompt=true) is
        // reserved for explicit user-driven request.
        let granted = AXIsProcessTrusted()
        // Remember the granted state across launches. We use this to detect
        // "permission was granted before, isn't now" — which happens when
        // the unsigned binary's hash changes (every rebuild) and macOS
        // invalidates the TCC binding. The UI uses this signal to show a
        // "permissions reset after update" banner instead of looking like
        // the user never granted in the first place.
        if granted {
            UserDefaults.standard.set(true, forKey: "voice.everGrantedAccessibility")
            return .granted
        }
        let everGranted = UserDefaults.standard.bool(forKey: "voice.everGrantedAccessibility")
        if everGranted {
            return .denied   // treat as "needs re-grant"
        }
        return hasPromptedAccessibility ? .denied : .notDetermined
    }

    /// True when Accessibility was previously granted but currently isn't —
    /// the typical "TCC binding invalidated after update" case. UI uses this
    /// to surface a clearer "re-grant after update" message.
    var accessibilityNeedsReGrant: Bool {
        accessibility != .granted
            && UserDefaults.standard.bool(forKey: "voice.everGrantedAccessibility")
    }

    private var hasPromptedAccessibility = false

    private func currentMicrophoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "voice.everGrantedMicrophone")
            return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func currentInputMonitoringStatus() -> Status {
        // Probe by attempting to create a session-level event tap. If
        // tapCreate returns nil, the kernel refused the tap which on
        // macOS 10.15+ means Input Monitoring is not granted for this
        // process. We immediately invalidate so we do not leak a tap.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )

        guard let tap else {
            // The first time we probe before the user has been prompted,
            // we cannot distinguish "denied" from "not determined". Once
            // we've ever seen it granted (persisted across launches), a
            // current "not granted" is the stale-TCC-after-update case.
            let everGranted = UserDefaults.standard.bool(forKey: "voice.everGrantedInputMonitoring")
            if everGranted { return .denied }
            return hasProbedInputMonitoringDenied ? .denied : .notDetermined
        }

        // We got a tap back; Input Monitoring is granted. Tear it down
        // immediately. We never enable() it because we do not want to
        // start receiving events; we only wanted the creation result.
        CFMachPortInvalidate(tap)
        hasProbedInputMonitoringDenied = true
        UserDefaults.standard.set(true, forKey: "voice.everGrantedInputMonitoring")
        return .granted
    }

    /// True if any required permission was once granted but currently isn't.
    var anyPermissionNeedsReGrant: Bool {
        let mic = microphone != .granted && UserDefaults.standard.bool(forKey: "voice.everGrantedMicrophone")
        let ax = accessibilityNeedsReGrant
        return ax || mic
    }

    private var hasProbedInputMonitoringDenied = false

    // MARK: Requests

    /// Shows the macOS Accessibility consent prompt the first time it
    /// is called. After the user has answered once, subsequent calls
    /// have no visible effect; that is by design from Apple. From then
    /// on the user must change the toggle in System Settings, which is
    /// what `openSettings(for:)` is for.
    func requestAccessibility() {
        hasPromptedAccessibility = true
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
        // The prompt is async; refresh once the system has had a tick
        // to flip the trust flag. The repeating timer will catch later
        // changes if the user takes longer in the dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    /// Triggers the AVFoundation microphone consent prompt. Resolves
    /// when the user dismisses it. Safe to call from `.task` on a view.
    func requestMicrophone() async {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        refresh()
    }

    // MARK: Deep linking

    /// Opens the System Settings pane for the given permission. macOS
    /// 14+ handles the deep-link URL directly; on older macOS this
    /// falls back to opening the top-level Privacy & Security pane.
    func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.systemPreferencesURL)
    }
}

// TODO(integration): from AppDelegate.applicationDidFinishLaunching,
// call `PermissionsService.shared.refresh()` so first-paint UI has the
// correct initial state. The `startMonitoring()` call should live on
// the onboarding view itself, not the AppDelegate, so it stops firing
// once the user finishes the flow.
