// VOICE — Compact Dictation Pill
// Phases: idle / recording / locked / transcribing / cancelled.
//
// POSITIONING ARCHITECTURE (v2):
// 1. ACTIVE SCREEN = newest of three signals (mouse, frontmost-app window,
//    NSApp.keyWindow). 2s sticky grace period to avoid jitter.
// 2. CVDisplayLink (vsync) replaces 0.15s Timer; only setFrame when delta>0.5pt.
// 3. Dock-aware: AX API for Dock's actual top edge, fallback to visibleFrame.
// 4. Fullscreen + space-change notifications force reposition + 100ms settle.
// 5. @AppStorage("voicePillDebug") paints red border + logs target frames.

import SwiftUI
import AppKit
import CoreVideo
import ApplicationServices

class OverlayPanel: NSPanel {
    private let recordingState: RecordingState

    var onTap: (() -> Void)?
    /// Polish closure carries the cleanup level: "light" / "medium" / "heavy".
    var onPolish: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?
    var onUndoPaste: (() -> Void)?
    /// Called when the companion meeting dot is tapped during dictation,
    /// or when any meeting-stop affordance in the pill fires.
    var onStopMeeting: (() -> Void)?

    // NOTE: We no longer install `.mouseMoved` or `.keyDown/.flagsChanged` global
    // monitors. They fired at 60–200Hz on the main thread, dwarfing every other
    // source of latency. Active-screen detection now polls NSEvent.mouseLocation
    // on demand in resolveActiveScreen(), which is O(1) and virtually free.

    /// User pref: hide pill from screen capture / screen recording.
    @objc dynamic private var hidePillFromScreenCapture: Bool {
        UserDefaults.standard.bool(forKey: "hidePillFromScreenCapture")
    }

    /// User pref: when idle, allow clicks to pass through to the app underneath.
    private var clickThroughIdle: Bool {
        UserDefaults.standard.bool(forKey: "clickThroughIdle")
    }

    /// Debug toggle — painted red border + verbose logging.
    private var debugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "voicePillDebug")
    }

    /// User-selected horizontal anchor: "bottomLeft" | "bottomCenter" | "bottomRight".
    /// Read live from UserDefaults so changes via the settings picker take effect
    /// immediately (we observe didChangeNotification and reposition).
    private var pillAnchor: String {
        UserDefaults.standard.string(forKey: "voice.pillPosition") ?? "bottomCenter"
    }

    /// While the user is dragging the idle dot we snap-as-you-go: the cursor's
    /// X position is bucketed into one of three zones (left/center/right third
    /// of the active screen), and the panel commits to that anchor with a quick
    /// spring as soon as the cursor crosses into a new zone. This anchor wins
    /// over `pillAnchor` in computeTargetFrame() until the drag ends.
    /// Reset to nil when the drag ends.
    private var liveDragAnchor: String? = nil

    /// Hysteresis: once the pill has snapped to an anchor mid-drag, require the
    /// cursor to push this many points PAST the next boundary before snapping
    /// to a neighbouring zone. Prevents flicker when the user hovers near a
    /// zone boundary.
    private let dragSnapHysteresis: CGFloat = 30

    // MARK: - Active-screen tracking

    /// Recent app-activation screen (set when another app activates). Mouse + key-window
    /// signals are polled live in resolveActiveScreen().
    private var lastAppActivationScreen: NSScreen?
    private var lastAppActivationAt: TimeInterval = 0

    /// Sticky target — once chosen, we resist flipping screens for 2s unless
    /// a stronger signal arrives.
    private var stickyScreen: NSScreen?
    private var stickySetAt: TimeInterval = 0
    private let stickyDuration: TimeInterval = 2.0

    // MARK: - DisplayLink

    private var displayLink: CVDisplayLink?
    private var currentTargetFrame: NSRect = .zero
    private var lastDockHiddenLogged: Bool? = nil

    // Display-link frame counter — skip odd frames to cap main-thread dispatches at ~30Hz.
    private var displayLinkFrameCounter: Int = 0

    // Idle throttle: when the pill is idle and nothing is animating, skip all but
    // 1 in 30 frames (≈1Hz at 60Hz vsync, ≈1Hz at 120Hz ProMotion) to minimise
    // main-thread dispatch overhead. This is a 97% reduction vs the raw vsync
    // rate and a 4× reduction vs the prior 4Hz setting. The pill's idle position
    // only needs to track the Dock edge / screen layout, both of which change
    // rarely; 1Hz is more than sufficient latency for that. Reset to 0 whenever
    // the phase leaves idle or a forced reposition is requested.
    private var idleFrameSkipCounter: Int = 0
    private let idleFrameSkipRate: Int = 30  // fire 1 in every 30 eligible frames ≈ 1Hz

    /// Set true by phase-change notifications so the display link does a full
    /// target-frame check on the next tick even while idle. Cleared after the check.
    private var needsReposition: Bool = false

    // Cached dock top edge — re-read at most every 3s (AX call is expensive at vsync rate).
    private var cachedDockTopEdge: CGFloat? = nil
    private var dockEdgeCachedAt: TimeInterval = 0
    private let dockEdgeCacheTTL: TimeInterval = 3.0

    // Cached screen list — refreshed only on NSApplication.didChangeScreenParametersNotification.
    // NSScreen.screens is a property that allocates a new array every call; calling it multiple
    // times per display-link tick at 30 Hz produces measurable churn. One cached copy covers
    // resolveActiveScreen(), computeTargetFrame(), and the intersects-any-screen guard.
    private var cachedScreens: [NSScreen] = NSScreen.screens

    /// Periodic re-assert of front-most order while recording. Other apps
    /// occasionally push panels back even at high window levels — a cheap
    /// 5s tick keeps the pill on top without burning cycles when idle.
    private var topmostReassertTimer: Timer?

    /// Periodic poll (every 3 s) that detects meeting apps even when the user
    /// navigates to Meet/Zoom/Teams inside an already-frontmost browser window.
    /// App-activation notifications only fire on an app switch, so we need this
    /// to catch in-browser navigation (Chrome → new tab → meet.google.com).
    private var meetingPollTimer: Timer?

    init(recordingState: RecordingState) {
        self.recordingState = recordingState

        let contentRect = NSRect(x: 0, y: 0, width: 180, height: 56)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setupContent()
        observeScreenChanges()
        seedActiveScreenSignals()
    }

    private func configure() {
        // CGShieldingWindowLevel sits above .screenSaver and is the highest
        // documented window level — used by the lock screen / shielding UIs.
        // Empirically beats other floating panels in Slack / Notion / VS Code
        // that occasionally render at .screenSaver themselves.
        level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // Default to click-through; applyClickThroughPolicy flips this off
        // only when the pill is in `.locked` (action buttons visible).
        ignoresMouseEvents = true

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        animationBehavior = .utilityWindow

        applyScreenCapturePolicy()
        repositionImmediate(animated: false)
    }

    // MARK: - Topmost re-assert

    /// Start the 5s tick that re-issues orderFrontRegardless. Only ticks while
    /// the pill is in `recording` or `locked` — idle/transcribing/cancelled
    /// don't need the reassert. The tick self-cancels when state leaves
    /// recording/locked, so callers can fire-and-forget on phase change.
    func beginTopmostReassert() {
        guard topmostReassertTimer == nil else { return }
        topmostReassertTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.recordingState.isRecording || self.recordingState.isLocked {
                self.orderFrontRegardless()
            } else {
                timer.invalidate()
                self.topmostReassertTimer = nil
            }
        }
    }

    func endTopmostReassert() {
        topmostReassertTimer?.invalidate()
        topmostReassertTimer = nil
    }

    // MARK: - Meeting detection poll

    /// Start the 5 s poll. Fires immediately so the first detection doesn't
    /// wait a full interval. Called once from `observeScreenChanges()`.
    ///
    /// 5 s vs the previous 3 s: the AX window-title check (used to detect
    /// Google Meet / Zoom inside a browser tab) dispatches to a background
    /// queue so it never blocks the main thread, but the GCD scheduling and
    /// background work still consume CPU + power ~20 times per minute. At 5 s
    /// that drops to 12 times per minute. Detection latency goes from ≤3 s to
    /// ≤5 s — imperceptible for a "you just joined a meeting" trigger.
    private func startMeetingPollTimer() {
        guard meetingPollTimer == nil else { return }
        meetingPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollMeetingDetection()
        }
        // First check right now, don't wait 5 s.
        pollMeetingDetection()
    }

    /// Check the current frontmost app for meeting activity.
    /// Posts `voiceAutoStartMeeting` on a false → true transition only.
    /// We do NOT auto-stop when the user switches windows — if they tab away
    /// from Chrome while still in the meeting we'd kill the capture. The user
    /// taps the pill (or the meeting ends deliberately) to stop.
    ///
    /// LATENCY FIX: The accessibility query inside `checkForMeetingApp` (used to
    /// detect Meet/Zoom/Teams running inside a browser tab) is a synchronous
    /// cross-process call that can take 50–300+ ms when the target app is busy.
    /// Running that on the main thread every 3 s stalls hotkey events and pill
    /// updates. We hop to a background queue for the AX read, then come back to
    /// the main actor only to apply the state delta. The fast path (frontmost
    /// app's bundleID is in the known meeting-app set) needs no AX call.
    private func pollMeetingDetection() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // When Voice's own pill is frontmost, frontmostApplication returns Voice.
        // Don't let that clear a previously-detected meeting app.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        // Capture pid + bundleID off the NSRunningApplication so the background
        // queue doesn't have to touch it (NSRunningApplication is thread-safe
        // for these properties but we avoid races by snapshotting).
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (isMeeting, source) = self.detectMeetingForBundle(bundleID, pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recordingState.isMeetingAppActive = isMeeting
                self.recordingState.meetingSourceBundleID = isMeeting ? source : nil
                // Poll only updates tint state — auto-start is NOT triggered here.
                // No auto-stop: user controls the end of the capture explicitly.
            }
        }
    }

    /// Background-safe meeting detection. Does the bundle-ID match (fast) and,
    /// if `pid` belongs to a known browser, the AX window-title check (slow).
    /// Returns (isMeeting, sourceBundleID).
    nonisolated private func detectMeetingForBundle(_ bundleID: String?, pid: pid_t) -> (Bool, String?) {
        let meetBundleIDs: Set<String> = [
            "com.google.meet",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.apple.FaceTime",
            "com.cisco.webex.meetings",
        ]
        if let bundleID, meetBundleIDs.contains(bundleID) {
            return (true, bundleID)
        }
        let browserBundles: Set<String> = [
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ]
        guard let bundleID, browserBundles.contains(bundleID), AXIsProcessTrusted() else {
            return (false, nil)
        }
        let axApp = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return (false, nil) }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return (false, nil) }
        let meetKeywords = ["Google Meet", "meet.google.com", "Zoom Meeting", "Microsoft Teams"]
        return (meetKeywords.contains(where: { title.contains($0) }) ? (true, bundleID) : (false, nil))
    }

    private func applyScreenCapturePolicy() {
        sharingType = hidePillFromScreenCapture ? .none : .readWrite
    }

    private func applyClickThroughPolicy(phase: PillPhase) {
        // Only the .locked phase shows interactive controls (X / ✓ buttons),
        // so it's the only state that should intercept mouse events. Every
        // other state is pure status display — let clicks fall through to
        // the app underneath. Even when we DO intercept (locked), the pill
        // view uses .contentShape(Capsule()) so only the visible pill area
        // captures hits; the surrounding panel padding stays click-through.
        switch phase {
        case .recording, .transcribing, .polishingSelection:
            // Status-display phases — clicks fall through to the app underneath.
            ignoresMouseEvents = true
        case .idle:
            // IdlePill has a hover bar with Dictate + Polish buttons. Those
            // need to receive click events. The Color.clear wrappers around
            // the dot and inside the bar buttons use contentShape() so only
            // the visible pixels capture hits — surrounding padding still
            // falls through.
            ignoresMouseEvents = false
        case .meetingCapture:
            // meetingCapture pill has a tap target (tap to stop the meeting).
            ignoresMouseEvents = false
        case .locked, .cancelled, .undoPaste:
            // .locked has X/✓ buttons; .cancelled and .undoPaste each have an Undo button.
            // All need to capture clicks. .contentShape(Capsule()) on the
            // pill view keeps the surrounding panel padding click-through.
            ignoresMouseEvents = false
        }

        switch phase {
        case .recording, .locked:
            beginTopmostReassert()
        case .idle, .transcribing, .polishingSelection, .meetingCapture, .cancelled, .undoPaste:
            endTopmostReassert()
        }

        _ = clickThroughIdle // pref retained for future override; idle is always click-through now
    }

    // MARK: - Notifications

    private func observeScreenChanges() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleScreenParametersChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(handleSpaceChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppActivation(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppHideUnhide),
                       name: NSWorkspace.didHideApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(handleAppHideUnhide),
                       name: NSWorkspace.didUnhideApplicationNotification, object: nil)

        // Fullscreen transitions on ANY window.
        nc.addObserver(self, selector: #selector(handleFullscreenChange),
                       name: NSWindow.didEnterFullScreenNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleFullscreenChange),
                       name: NSWindow.didExitFullScreenNotification, object: nil)

        // NO global mouse/key monitors. They previously dispatched 60–200 main-thread
        // closures per second while typing or moving the cursor — the root cause of
        // the perceived pill latency. Active-screen detection now uses NSEvent.mouseLocation
        // on-demand inside resolveActiveScreen(), which is O(1) and free.

        UserDefaults.standard.addObserver(self,
                                          forKeyPath: "hidePillFromScreenCapture",
                                          options: [.new],
                                          context: nil)

        // Start polling for meeting apps (catches in-browser navigation without
        // an app-switch notification, e.g. Chrome → meet.google.com tab).
        startMeetingPollTimer()

        // Reposition when the user changes "voice.pillPosition" in Settings.
        // UserDefaults.didChangeNotification fires for ANY default change — we
        // accept that cost (it's cheap) rather than KVO each individual key.
        nc.addObserver(self,
                       selector: #selector(handlePillAnchorChanged),
                       name: UserDefaults.didChangeNotification,
                       object: nil)

        // Real-time drag updates from the IdlePill DragGesture.
        nc.addObserver(self,
                       selector: #selector(handlePillDrag(_:)),
                       name: Notification.Name("voice.pillDrag"),
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handlePillDragEnd(_:)),
                       name: Notification.Name("voice.pillDragEnd"),
                       object: nil)
    }

    @objc private func handlePillAnchorChanged() {
        // Cheap early-out: only reposition if we're not in the middle of a drag.
        guard liveDragAnchor == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    /// Snap-while-dragging. The cursor X (in global screen coords) is bucketed
    /// into one of three zones on the screen the cursor is currently on. If the
    /// resulting anchor differs from where the pill is right now, commit the
    /// snap immediately with a quick spring + haptic. We do NOT track the
    /// cursor 1:1 — the pill glides between three discrete positions.
    @objc private func handlePillDrag(_ note: Notification) {
        guard let x = note.userInfo?["screenX"] as? CGFloat else { return }

        // Use the screen the cursor is on (handles multi-monitor drags).
        let mouse = NSEvent.mouseLocation
        let cursorScreen = cachedScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? resolveActiveScreen()
        let screenW = cursorScreen.frame.width
        let third = screenW / 3
        let relX = x - cursorScreen.frame.minX

        // Determine which anchor the cursor X maps to. Apply hysteresis: when
        // a live drag anchor exists, widen the current zone by
        // `dragSnapHysteresis` so the user has to push past the boundary to
        // flip zones. Prevents flicker at the zone edges.
        let current = liveDragAnchor ?? pillAnchor
        let h = dragSnapHysteresis
        let target: String
        switch current {
        case "bottomLeft":
            if relX < third + h { target = "bottomLeft" }
            else if relX < third * 2 + h { target = "bottomCenter" }
            else { target = "bottomRight" }
        case "bottomRight":
            if relX >= third * 2 - h { target = "bottomRight" }
            else if relX >= third - h { target = "bottomCenter" }
            else { target = "bottomLeft" }
        default: // bottomCenter — symmetric pull from both sides
            if relX < third - h { target = "bottomLeft" }
            else if relX < third * 2 + h { target = "bottomCenter" }
            else { target = "bottomRight" }
        }

        // Initialise live anchor on first event of this drag. Only animate /
        // commit when the target zone differs from the pill's current zone.
        let priorAnchor = liveDragAnchor ?? pillAnchor
        liveDragAnchor = target

        if target != priorAnchor {
            // Persist immediately so the Settings picker stays in sync.
            UserDefaults.standard.set(target, forKey: "voice.pillPosition")
            // Subtle tactile feedback on each zone snap.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            // Quick spring snap to the new corner.
            DispatchQueue.main.async { [weak self] in
                self?.repositionImmediate(animated: true)
            }
        } else if liveDragAnchor != nil && currentTargetFrame == .zero {
            // First-event seed: ensure the panel frame matches the anchor.
            DispatchQueue.main.async { [weak self] in
                self?.repositionImmediate(animated: false)
            }
        }
    }

    @objc private func handlePillDragEnd(_ note: Notification) {
        // Snap already happened during the drag — just clear transient state.
        // The final anchor was written to UserDefaults on the last zone change.
        liveDragAnchor = nil
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "hidePillFromScreenCapture" {
            applyScreenCapturePolicy()
        }
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.cachedScreens = NSScreen.screens  // refresh screen list cache
            self?.cachedDockTopEdge = nil           // force re-read after screen change
            self?.restartDisplayLink()
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleSpaceChanged() {
        // Settle delay — space transitions animate ~0.5s.
        DispatchQueue.main.async { [weak self] in
            self?.orderFrontRegardless()
            self?.repositionImmediate(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.orderFrontRegardless()
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleFullscreenChange() {
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleAppActivation(_ note: Notification) {
        // Record which screen the activated app sits on.
        let now = CACurrentMediaTime()
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            if let screen = screenForFrontmostWindow(of: app) {
                lastAppActivationScreen = screen
                lastAppActivationAt = now
            }
            // Hop off-main for the AX-touching meeting detection — see
            // pollMeetingDetection() for rationale.
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let (isMeeting, source) = self.detectMeetingForBundle(bundleID, pid: pid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordingState.isMeetingAppActive = isMeeting
                    self.recordingState.meetingSourceBundleID = isMeeting ? source : nil
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    @objc private func handleAppHideUnhide() {
        DispatchQueue.main.async { [weak self] in
            self?.repositionImmediate(animated: true)
        }
    }

    // MARK: - Signal seeding

    /// Polls NSEvent.mouseLocation on demand — cheap, no global monitor needed.
    /// Uses `cachedScreens` to avoid allocating a new array per call.
    private func currentMouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return cachedScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }

    private func seedActiveScreenSignals() {
        // App activation seed — keeps the first computeTargetFrame from picking
        // a stale screen on launch. Mouse + key-window are polled live each tick.
        if let s = NSScreen.main {
            lastAppActivationScreen = s
            lastAppActivationAt = CACurrentMediaTime()
        }
    }

    /// Frontmost window of a given app via CGWindowList (layer 0, ordered).
    private func screenForFrontmostWindow(of app: NSRunningApplication) -> NSScreen? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let pid = app.processIdentifier
        for w in info {
            guard let wpid = w[kCGWindowOwnerPID as String] as? Int32, wpid == pid else { continue }
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            // CG coords are top-left origin in the global display space.
            // Convert to NS coords (bottom-left) by flipping against the
            // total screen-space height.
            let primary = cachedScreens.first?.frame ?? .zero
            let nsY = primary.maxY - (y + height)
            let center = CGPoint(x: x + width / 2, y: nsY + height / 2)
            if let s = cachedScreens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                return s
            }
        }
        return nil
    }

    // MARK: - Active screen resolution

    /// Newest signal wins. Sticky for 2s after a screen is chosen — prevents
    /// thrash when the cursor drifts briefly onto another monitor.
    private func resolveActiveScreen() -> NSScreen {
        let now = CACurrentMediaTime()

        // Build candidate list with (screen, age). All signals are polled live
        // here — no event-monitor side channel, so this is the only cost.
        var candidates: [(screen: NSScreen, age: TimeInterval)] = []
        if let s = currentMouseScreen() { candidates.append((s, 0)) }
        if let s = lastAppActivationScreen { candidates.append((s, now - lastAppActivationAt)) }
        if let dyn = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen {
            candidates.append((dyn, 0))
        }

        // Drop nils / disconnected screens. Use the cached list — NSScreen.screens
        // allocates a new array on every call; at 30 Hz this adds up fast.
        let attached = cachedScreens
        candidates = candidates.filter { c in attached.contains(where: { $0 === c.screen }) }

        // Pick freshest.
        let freshest = candidates.min(by: { $0.age < $1.age })?.screen

        // Sticky: if we have a current sticky and it's < 2s old AND the freshest
        // signal isn't VERY fresh (< 0.5s), keep sticky.
        if let sticky = stickyScreen,
           attached.contains(where: { $0 === sticky }),
           (now - stickySetAt) < stickyDuration {
            if let fresh = freshest, fresh !== sticky {
                let freshAge = candidates.first(where: { $0.screen === fresh })?.age ?? .infinity
                if freshAge < 0.5 {
                    stickyScreen = fresh
                    stickySetAt = now
                    return fresh
                }
            }
            return sticky
        }

        let chosen = freshest ?? NSScreen.main ?? cachedScreens.first ?? NSScreen.screens.first!
        stickyScreen = chosen
        stickySetAt = now
        return chosen
    }

    // MARK: - Dock detection

    /// Try Accessibility API for the Dock's actual frame. Returns the top
    /// edge of the dock in NS coords, or nil if AX denied / Dock hidden.
    private func dockTopEdge(on screen: NSScreen) -> CGFloat? {
        // Find Dock process.
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else { return nil }

        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }

        // Look for the dock list (first child usually).
        for kid in kids {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &posValue) == .success,
                  AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeValue) == .success else {
                continue
            }
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard let pv = posValue, CFGetTypeID(pv) == AXValueGetTypeID(),
                  let sv = sizeValue, CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            let axPos = unsafeBitCast(pv, to: AXValue.self)
            let axSize = unsafeBitCast(sv, to: AXValue.self)
            AXValueGetValue(axPos, .cgPoint, &pos)
            AXValueGetValue(axSize, .cgSize, &size)

            if size.width <= 0 || size.height <= 0 { continue }

            // Convert CG (top-left) → NS (bottom-left) using primary screen height.
            let primaryFrame = NSScreen.screens.first?.frame ?? screen.frame
            let nsBottom = primaryFrame.maxY - (pos.y + size.height)
            let nsTop = nsBottom + size.height

            // Only consider if the dock is on the same screen.
            let dockRect = NSRect(x: pos.x, y: nsBottom, width: size.width, height: size.height)
            if screen.frame.intersects(dockRect) {
                return nsTop
            }
        }
        return nil
    }

    // MARK: - Target frame computation

    private func computeTargetFrame() -> NSRect {
        let screen = resolveActiveScreen()
        let panelWidth: CGFloat = 180
        // Base height is 56px (controls row). When live-partial text is present
        // in lock mode, grow upward by 88px (80px text area + 8px padding/separator).
        // The bottom edge stays anchored so the pill expands toward the top.
        let hasLiveText = recordingState.isLocked && !recordingState.livePartialText.isEmpty
        let panelHeight: CGFloat = hasLiveText ? 144 : 56

        let dockHidden = screen.visibleFrame.size == screen.frame.size

        // Prefer AX-derived dock edge when available; fallback to visibleFrame.
        // Cache the AX result for 3s — dockTopEdge() is an AX round-trip and
        // was previously called at 60Hz from the display link, causing latency.
        let y: CGFloat
        if !dockHidden {
            let now = CACurrentMediaTime()
            if cachedDockTopEdge == nil || (now - dockEdgeCachedAt) > dockEdgeCacheTTL {
                cachedDockTopEdge = dockTopEdge(on: screen)
                dockEdgeCachedAt = now
            }
            if let dockTop = cachedDockTopEdge {
                y = dockTop + 4
            } else {
                y = screen.visibleFrame.minY + 4
            }
        } else {
            cachedDockTopEdge = nil
            y = screen.visibleFrame.minY
        }

        // Horizontal anchor — bottomCenter (default), bottomLeft, bottomRight.
        // While the user is actively dragging the idle dot, `liveDragAnchor`
        // wins (snap-while-dragging — the pill glides between the three
        // discrete corners rather than tracking the cursor 1:1).
        let margin: CGFloat = 40
        let effectiveAnchor = liveDragAnchor ?? pillAnchor
        let x: CGFloat
        switch effectiveAnchor {
        case "bottomLeft":
            x = screen.frame.minX + margin
        case "bottomRight":
            x = screen.frame.maxX - panelWidth - margin
        default:
            x = screen.frame.midX - panelWidth / 2
        }

        if debugEnabled, lastDockHiddenLogged != dockHidden {
            print("[VOICE/dbg] screen=\(screen.localizedName) dockHidden=\(dockHidden) y=\(Int(y))")
            lastDockHiddenLogged = dockHidden
        }

        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    /// True when the pill is in the idle phase — mirrors `rawPhase` from OverlayPillView
    /// but computed directly from RecordingState so the panel can check it without
    /// touching any SwiftUI state. Used to throttle the display link at idle AND
    /// to shrink the hit-test band so the idle dot doesn't intercept clicks
    /// across a wide invisible strip.
    var isIdlePhase: Bool {
        !recordingState.pendingRecordingStart &&
        !recordingState.isTranscribing &&
        !(recordingState.isLocked && recordingState.isRecording) &&
        !recordingState.isRecording &&
        !recordingState.isPolishingSelection &&
        !recordingState.showingCancelledToast &&
        !recordingState.showingUndoPasteToast
    }

    /// Immediate reposition — used for notifications. Bypasses display-link
    /// throttle and animates if requested.
    private func repositionImmediate(animated: Bool) {
        // Signal the display link to do a full frame check on the next tick
        // even if we're currently throttled (idle rate). This covers cases
        // like space-change or screen-parameter-change where the pill needs
        // to snap to a new position even while idle.
        needsReposition = true
        let target = computeTargetFrame()

        let intersectsAnyScreen = cachedScreens.contains { $0.frame.intersects(target) }
        guard intersectsAnyScreen else {
            if debugEnabled { print("[VOICE/dbg] target offscreen, skip: \(target)") }
            return
        }

        currentTargetFrame = target

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }

        // Re-lift window order after every reposition — some apps temporarily
        // push panels back even at .screenSaver level when they activate.
        orderFrontRegardless()
    }

    /// Display-link tick — called on vsync. Compares target to current frame,
    /// animates if delta exceeds 0.5pt.
    ///
    /// Frame mutation is deferred to the next runloop tick to ensure we never
    /// call setFrame from inside a CA transaction commit. The display link
    /// dispatches us to main, but main can land mid-transaction during a
    /// SwiftUI re-render — directly calling setFrame from there crashes with
    /// `_postWindowNeedsUpdateConstraints` on macOS 26.
    fileprivate func displayLinkTick() {
        // IDLE EARLY-EXIT: the CVDisplayLink callback already throttles dispatch
        // to ~4Hz when idle. But if we're here AND idle, do a cheap short-circuit:
        // if the frame hasn't moved, skip all the downstream work immediately.
        // This costs one frame-comparison per 4Hz tick instead of the full
        // resolveActiveScreen + computeTargetFrame path.
        if isIdlePhase {
            needsReposition = false
            let cur = self.frame
            // Only run the full target computation if we don't already know the frame is current.
            // currentTargetFrame is updated by repositionImmediate so it tracks the last known good position.
            let cached = currentTargetFrame
            if cached != .zero &&
               abs(cached.minX - cur.minX) < 0.5 &&
               abs(cached.minY - cur.minY) < 0.5 &&
               abs(cached.height - cur.height) < 0.5 {
                return
            }
        } else {
            needsReposition = false
        }

        let target = computeTargetFrame()
        let cur = self.frame
        let dx = abs(target.minX - cur.minX)
        let dy = abs(target.minY - cur.minY)
        let dh = abs(target.height - cur.height)
        if dx < 0.5 && dy < 0.5 && dh < 0.5 { return }

        let intersectsAnyScreen = cachedScreens.contains { $0.frame.intersects(target) }
        guard intersectsAnyScreen else { return }

        currentTargetFrame = target

        // Defer onto the next runloop pass to escape any active CA transaction.
        // 0.0s asyncAfter is equivalent to "schedule for the next event loop turn"
        // and is the cheapest way to guarantee we're outside layoutSubtreeIfNeeded.
        let duration: TimeInterval = dh > 1 ? 0.20 : 0.008
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            guard let self else { return }
            // Re-check the target — by the time this fires the screen / state
            // may have moved on. Recomputing is cheap (dock edge is cached).
            let now = self.computeTargetFrame()
            let stillNeedsMove =
                abs(now.minX - self.frame.minX) >= 0.5 ||
                abs(now.minY - self.frame.minY) >= 0.5 ||
                abs(now.height - self.frame.height) >= 0.5
            guard stillNeedsMove else { return }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(now, display: true)
            }
        }
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard err == kCVReturnSuccess, let link else {
            print("[VOICE] CVDisplayLinkCreate failed (\(err)) — falling back to Timer")
            startFallbackTimer()
            return
        }
        displayLink = link

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, ctx) -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let panel = Unmanaged<OverlayPanel>.fromOpaque(ctx).takeUnretainedValue()
            // True 30Hz throttle: skip every other vsync frame. Without this,
            // at 60Hz we dispatch 60 main-thread closures/sec — each calling
            // the AX dock-edge API — causing measurable click and audio latency.
            panel.displayLinkFrameCounter &+= 1
            guard panel.displayLinkFrameCounter % 2 == 0 else { return kCVReturnSuccess }
            // Additional idle throttle at the callback level: when the pill is
            // idle and no reposition is pending, skip 7 out of 8 eligible frames
            // (≈4Hz). This avoids even the DispatchQueue.main.async overhead for
            // the skipped frames — the cheapest possible no-op.
            if panel.isIdlePhase && !panel.needsReposition {
                panel.idleFrameSkipCounter &+= 1
                guard panel.idleFrameSkipCounter >= panel.idleFrameSkipRate else { return kCVReturnSuccess }
                panel.idleFrameSkipCounter = 0
            } else {
                panel.idleFrameSkipCounter = 0
            }
            DispatchQueue.main.async { panel.displayLinkTick() }
            return kCVReturnSuccess
        }, opaque)

        // Bind to the current active display.
        if let screen = NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(displayID))
        }

        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    private func restartDisplayLink() {
        stopDisplayLink()
        startDisplayLink()
    }

    /// Fallback only if CVDisplayLink fails to create.
    private var fallbackTimer: Timer?
    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.displayLinkTick()
        }
    }

    // MARK: - Content / lifecycle

    private func setupContent() {
        let hostingView = PillHostingView(
            rootView: OverlayPillView(
                state: recordingState,
                onTap: { [weak self] in self?.onTap?() },
                onPolish: { [weak self] level in self?.onPolish?(level) },
                onCancel: { [weak self] in self?.onCancel?() },
                onConfirm: { [weak self] in self?.onConfirm?() },
                onUndoCancel: { [weak self] in self?.onUndoCancel?() },
                onUndoPaste: { [weak self] in self?.onUndoPaste?() },
                onStopMeeting: { [weak self] in self?.onStopMeeting?() },
                onPhaseChange: { [weak self] phase in
                    self?.applyClickThroughPolicy(phase: phase)
                }
            )
        )

        if debugEnabled {
            hostingView.wantsLayer = true
            hostingView.layer?.borderColor = NSColor.red.cgColor
            hostingView.layer?.borderWidth = 1
        }

        contentView = hostingView
    }

    func showPersistent() {
        repositionImmediate(animated: false)
        orderFrontRegardless()
        startDisplayLink()
        if debugEnabled {
            let f = self.frame
            print("[VOICE/dbg] Pill positioned at x=\(Int(f.minX)) y=\(Int(f.minY)) on \(resolveActiveScreen().localizedName)")
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        stopDisplayLink()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        topmostReassertTimer?.invalidate()
        topmostReassertTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        UserDefaults.standard.removeObserver(self, forKeyPath: "hidePillFromScreenCapture")
    }
}

// MARK: - PillHostingView

/// NSHostingView subclass that only captures mouse events inside the actual
/// visible pill region. The 180×56 panel has substantial empty padding around
/// the capsule; without this override, AppKit consumes clicks anywhere in the
/// panel rect (even when SwiftUI's `.contentShape(Capsule())` ignores them),
/// silently swallowing the user's click on whatever app is underneath.
///
/// We approximate the visible region as a horizontally-centered band at the
/// bottom of the panel matching the largest possible pill bounds (160×34).
/// Points outside that band return nil → AppKit forwards the click to the
/// window below.
private final class PillHostingView<Content: View>: NSHostingView<Content> {
    // Bottom-anchored band that contains every pill phase (idle dot, recording
    // capsule, locked capsule, transcribing dot, cancelled toast). Generous
    // enough to never clip a real interactive control, tight enough that all
    // the click-through padding goes to the app below.
    private let visibleBandHeight: CGFloat = 34
    private let visibleBandWidth: CGFloat = 176

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // CRITICAL: disable constraint-based layout for this hosting view. The
        // panel uses explicit setFrame() calls from the display link; without
        // this, NSHostingView's internal constraints fight setFrame during the
        // CA transaction commit phase, triggering an exception in
        // `_postWindowNeedsUpdateConstraints` (observed crash on live-partial
        // expand on macOS 26+).
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    // Pin safe-area insets to zero. SwiftUI's auto safe-area handling on a
    // borderless overlay panel triggers `invalidateSafeAreaInsets` during
    // layout, which schedules `setNeedsUpdateConstraints`, which throws if
    // it lands inside a CA transaction commit. Zeroing eliminates the path.
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let bounds = self.bounds
        // Idle phase: shrink the hit-test band to roughly the dot's frame plus
        // a generous halo. The halo matters for drag UX — once mouseDown lands
        // on the dot, the user immediately moves the cursor sideways to corner-
        // snap, and AppKit re-runs hitTest along the way. Too tight a band and
        // the drag gets interrupted as the cursor exits. Active states keep
        // the full 176×34 band.
        //
        // Halo size: ≥ visibleBandWidth horizontally so a drag spans the full
        // width of the panel, ≥ visibleBandHeight vertically so the hover bar
        // ABOVE the dot is also hittable (Polish buttons live there).
        let isIdle = (self.window as? OverlayPanel)?.isIdlePhase ?? false
        let bandW: CGFloat = visibleBandWidth
        let bandH: CGFloat = visibleBandHeight
        let bandX = (bounds.width - bandW) / 2
        let bandY: CGFloat = (bounds.height > bandH + 6) ? 4 : 0
        let bandHeight = isIdle ? bandH : max(bandH, bounds.height - bandY)
        let band = NSRect(x: bandX, y: bandY, width: bandW, height: bandHeight)
        // Quick reject — point is in the dead padding. AppKit will forward the
        // click to whatever window is underneath.
        guard band.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Phase

enum PillPhase: Equatable {
    case idle
    case recording        // push-to-talk
    case locked           // 2x click mode
    case transcribing
    case polishingSelection  // Opt+1 flow — polishing externally selected text
    case meetingCapture   // Google Meet / Zoom / Teams meeting recording
    case cancelled        // cancelled toast (Undo cancel)
    case undoPaste        // successful-paste toast (Undo paste)
}

// MARK: - Pill View

struct OverlayPillView: View {
    @Bindable var state: RecordingState

    var onTap: (() -> Void)?
    /// Polish closure carries the cleanup level: "light" / "medium" / "heavy".
    var onPolish: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?
    var onUndoPaste: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    var onPhaseChange: ((PillPhase) -> Void)?

    /// Phase priority. Order matters — `transcribing` must win over a stale
    /// `isRecording=false` so the post-recording → transcribing handoff
    /// doesn't lapse to .idle for a frame (visible flicker).
    ///
    /// `pendingRecordingStart` short-circuits BEFORE any async audio-engine
    /// spin-up. The moment the hotkey closure flips that flag the pill should
    /// snap to .recording on the next render — no waiting for AVAudioEngine,
    /// the tap install, or the first sample to arrive. The flag is cleared
    /// when isRecording actually becomes true (or on abort).
    private var rawPhase: PillPhase {
        // pendingRecordingStart MUST be the first check — it's the zero-latency
        // path that flips the moment the hotkey closure fires, before the audio
        // engine has spun up or isRecording has been set true. Anything else
        // checked above this re-introduces the latency we fixed.
        if state.pendingRecordingStart && !state.isLocked { return .recording }
        if state.isTranscribing { return .transcribing }
        if state.isLocked && state.isRecording { return .locked }
        if state.isRecording { return .recording }
        // polishingSelection: added by another agent — check defensively.
        if state.isPolishingSelection { return .polishingSelection }
        // isCapturingMeeting no longer drives .meetingCapture — meeting is shown
        // via MeetingRecordingDot overlay on top of whatever the active phase is.
        if state.showingCancelledToast { return .cancelled }
        if state.showingUndoPasteToast { return .undoPaste }
        return .idle
    }

    @State private var displayPhase: PillPhase = .idle
    @State private var lastLoggedPhase: PillPhase = .idle
    @State private var settlingTask: Task<Void, Never>?
    /// Independently-animated offset for the meeting dot. Driven by a separate
    /// withAnimation so it always springs even when the pill snaps instantly
    /// (e.g. idle → recording uses nil animation for zero-latency hotkey feel).
    @State private var meetingDotAnimatedOffset: CGFloat = 0

    /// Transient engine toast — captures the engine + latency of the last
    /// polish so the user can SEE which model actually ran on every paste,
    /// not just guess from the cloud/cpu/sparkles glyph during the in-flight
    /// window. Driven by NotificationCenter.voicePolishComplete (posted by
    /// PolishStatus.record) and falls back to .onChange(lastEngine) for the
    /// transitional period before Qwen3Polisher is wired through record().
    @State private var engineToastSnapshot: EngineToastSnapshot?
    @State private var engineToastShownAt: Date?
    @State private var engineToastDismissTask: Task<Void, Never>?
    @State private var engineToastDetailsOpen: Bool = false
    /// Mirror of PolishStatus.lastEngine so .onChange can detect updates even
    /// when the value transitions from nil → "local:..." (Observable bindings
    /// only fire onChange when the new value differs from the previous).
    @State private var lastObservedEngine: String?
    /// Power-user setting: when ON, an always-visible chip displays the last
    /// polish engine + latency in the corner of the pill (and never auto-
    /// dismisses). Default OFF — diagnostic affordance only.
    @AppStorage("voice.showEnginePill") private var showEnginePill: Bool = false

    /// Namespace for Liquid Glass morph between pill phases. Each phase pill
    /// shares the same glassEffectID inside a GlassEffectContainer — when one
    /// pill disappears and another appears, the system interpolates the glass
    /// surface between their shapes instead of cross-fading.
    @Namespace private var pillGlassNamespace

    // Per-edge animation specs. The single-spring approach (one curve for
    // every transition) reads as "the pill is animating" rather than "the
    // pill is reacting to a specific event". Each edge gets the curve that
    // matches its semantic urgency:
    //   - idle → recording:    instant (no animation — see applyPhase)
    //   - recording → locked:  spring 0.32/0.78 — user just double-tapped,
    //                          a mild celebration is OK
    //   - recording → trans.:  spring 0.28/0.82 — tapering off
    //   - transcribing → idle: easeOut 0.25 — non-urgent "done"
    //   - cancelled → idle:    easeOut 0.35 — give user time to register
    //   - everything else:     a calm phaseSpring for ambient transitions
    // Springs tuned for Liquid Glass morph — bouncier than before so the
    // glass surface visibly springs into the new shape. Apple's .bouncy and
    // .snappy curves are what Tahoe uses internally for glass transitions.
    private let phaseSpring          = Animation.spring(response: 0.32, dampingFraction: 0.72)
    private let recordingToLocked    = Animation.spring(response: 0.38, dampingFraction: 0.68)
    private let recordingToTranscribe = Animation.spring(response: 0.34, dampingFraction: 0.74)
    private let transcribeToIdle     = Animation.spring(response: 0.40, dampingFraction: 0.80)
    private let cancelledToIdle      = Animation.spring(response: 0.45, dampingFraction: 0.82)

    var body: some View {
        ZStack(alignment: .bottom) {
            // Side meeting dot removed — user found it visually noisy. Meeting
            // state is already surfaced by the menu bar icon + Meetings tab in
            // BigMenu, so the offset companion dot was redundant ornament.
            // ── Main pill ────────────────────────────────────────────────────
            // Dynamic-Island-style morph: GlassEffectContainer flattens all
            // child glass shapes into one shared surface so the pill morphs
            // between phases — not a cross-fade. The container's `spacing`
            // is the merge distance: anything closer than this pulls toward
            // its neighbor with surface tension during the transition.
            //
            // Per-case `.transition()` modifiers used to fight the morph by
            // specifying their own appear/disappear curves — they're gone.
            // Now each pill is a child of the container with the same
            // glassEffectID, and the container does the morphing.
            GlassEffectContainer(spacing: 36) {
                switch displayPhase {
                case .idle:
                    if !state.isCapturingMeeting {
                        IdlePill(
                            onTap: { onTap?() },
                            onPolish: { level in onPolish?(level) }
                        )
                        .glassEffectID("pill", in: pillGlassNamespace)
                    }
                case .recording:
                    RecordingPill(state: state)
                        .glassEffectID("pill", in: pillGlassNamespace)
                case .locked:
                    LockedPill(
                        state: state,
                        onCancel: { onCancel?() },
                        onConfirm: { onConfirm?() }
                    )
                    .glassEffectID("pill", in: pillGlassNamespace)
                case .transcribing:
                    TranscribingPill()
                        .glassEffectID("pill", in: pillGlassNamespace)
                case .polishingSelection:
                    PolishingSelectionPill()
                        .glassEffectID("pill", in: pillGlassNamespace)
                case .meetingCapture:
                    EmptyView()
                case .cancelled:
                    CancelledToast(
                        shownAt: state.cancelToastShownAt ?? Date(),
                        onUndo: { onUndoCancel?() }
                    )
                    .glassEffectID("pill", in: pillGlassNamespace)
                case .undoPaste:
                    UndoPasteToast(
                        shownAt: state.undoPasteToastShownAt ?? Date(),
                        onUndo: { onUndoPaste?() }
                    )
                    .glassEffectID("pill", in: pillGlassNamespace)
                }
            }
            // Drive every phase change with a single bouncy spring so the
            // glass surface morphs visibly — this is what makes it read as
            // a Dynamic-Island-like pill instead of a generic SwiftUI fade.
            .animation(.bouncy(duration: 0.42, extraBounce: 0.12), value: displayPhase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        .scaleEffect(displayPhase == .idle ? 0.96 : 1.0)
        .contentShape(Capsule())
        // Engine toast — overlays just above the pill, fades in/out after every
        // polish completes. Tappable for details popover. See EnginePolishToast
        // for the layout. Sits in an overlay so it doesn't fight the
        // GlassEffectContainer morph happening below.
        .overlay(alignment: .top) {
            if let snapshot = engineToastSnapshot, let shownAt = engineToastShownAt {
                EnginePolishToast(
                    snapshot: snapshot,
                    shownAt: shownAt,
                    detailsOpen: $engineToastDetailsOpen,
                    onTap: {
                        // Keep the toast alive while details popover is open —
                        // cancel any pending auto-dismiss the moment the user
                        // shows interest.
                        engineToastDismissTask?.cancel()
                        engineToastDismissTask = nil
                        engineToastDetailsOpen.toggle()
                    }
                )
                .offset(y: -34)  // float above the pill body
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
                .zIndex(10)
            }
        }
        // Persistent debug chip — always-visible last-engine indicator gated
        // by the @AppStorage flag. Sits to the right of the pill so it never
        // overlaps the dynamic-island morph.
        .overlay(alignment: .topTrailing) {
            if showEnginePill {
                EnginePolishDebugChip()
                    .offset(x: -8, y: -4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            applyPhase(rawPhase, immediate: true)
            meetingDotAnimatedOffset = meetingDotOffsetX(for: rawPhase)
            // Seed the engine mirror so we don't fire the toast on first launch.
            lastObservedEngine = PolishStatus.shared.lastEngine
        }
        .onChange(of: rawPhase) { _, newPhase in applyPhase(newPhase, immediate: false) }
        .onChange(of: displayPhase) { old, new in
            if UserDefaults.standard.bool(forKey: "voicePillDebug") {
                print("[VOICE-PILL/dbg] \(old) -> \(new) @ \(Date().timeIntervalSinceReferenceDate)")
            }
        }
        // Primary trigger: PolishStatus.record() posts this notification after
        // updating its main-actor state. Includes Qwen3Polisher direct-write
        // updates ONCE the routing agent migrates those sites to record().
        .onReceive(NotificationCenter.default.publisher(for: .voicePolishComplete)) { _ in
            presentEngineToast()
        }
        // Fallback trigger: until every polish path calls PolishStatus.record(),
        // Qwen3Polisher still writes lastEngine directly. Catch those updates
        // by observing the field on the @Observable singleton. Re-firing the
        // toast on the same engine value (e.g. two consecutive local polishes)
        // is fine — we always snapshot a fresh timestamp.
        .onChange(of: PolishStatus.shared.lastEngine) { _, newValue in
            // Skip the first transition from the @State seed so we don't fire
            // a phantom toast right after the view mounts.
            if newValue != lastObservedEngine {
                lastObservedEngine = newValue
                presentEngineToast()
            }
        }
    }

    /// Capture the current PolishStatus snapshot and present the engine toast.
    /// Schedules auto-dismiss after 2s unless the user opens the details popover.
    private func presentEngineToast() {
        let status = PolishStatus.shared
        guard let engine = status.lastEngine, !engine.isEmpty else { return }
        // Resolve latency: prefer the value PolishStatus records, fall back to
        // the per-polisher singleton based on the engine prefix so we still
        // show something honest before Qwen3Polisher is migrated.
        let latencyMs: Int = {
            if status.lastLatencyMs > 0 { return status.lastLatencyMs }
            if engine.hasPrefix("cloud:groq") { return GroqPolisher.shared.lastLatencyMs }
            if engine.hasPrefix("cloud:") { return CerebrasPolisher.shared.lastLatencyMs }
            if engine.hasPrefix("local:") { return Qwen3Polisher.shared.lastLatencyMs }
            return 0
        }()
        let snapshot = EngineToastSnapshot(
            engine: engine,
            latencyMs: latencyMs,
            reason: status.lastReason,
            inputWordCount: status.lastInputWordCount,
            outputWordCount: status.lastOutputWordCount,
            fallbackCount: status.lastFallbackCount,
            sanitizerRejected: status.lastSanitizerRejected
        )
        withAnimation(.easeOut(duration: 0.22)) {
            engineToastSnapshot = snapshot
            engineToastShownAt = Date()
            engineToastDetailsOpen = false
        }
        engineToastDismissTask?.cancel()
        engineToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            // Don't dismiss out from under an open details popover.
            if engineToastDetailsOpen { return }
            withAnimation(.easeIn(duration: 0.30)) {
                engineToastSnapshot = nil
                engineToastShownAt = nil
            }
        }
    }

    private func applyPhase(_ next: PillPhase, immediate: Bool) {
        settlingTask?.cancel()
        settlingTask = nil

        let commit: (PillPhase, Animation?) -> Void = { newValue, _ in
            if newValue != lastLoggedPhase {
                if UserDefaults.standard.bool(forKey: "voicePillDebug") {
                    print("[VOICE/dbg] Pill phase: \(lastLoggedPhase) -> \(newValue)")
                }
                lastLoggedPhase = newValue
            }
            // Just assign — the GlassEffectContainer has a `.animation(.bouncy,
            // value: displayPhase)` modifier that drives the morph. Wrapping
            // the assignment in withAnimation here fought the container's
            // animation and produced a cross-fade instead of a glass morph.
            displayPhase = newValue
            // Meeting dot offset still animates separately so the dot springs
            // even if the pill morph is happening on the container's clock.
            let targetDotOffset = meetingDotOffsetX(for: newValue)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                meetingDotAnimatedOffset = targetDotOffset
            }
            onPhaseChange?(newValue)
        }

        if next == .idle && !immediate && displayPhase != .idle {
            // Delay idle-settle 300ms so a brief transcribing flash doesn't
            // immediately collapse the pill before the user can see it.
            // Curve depends on origin: cancelled→idle wants a longer, calmer
            // fade (gives the user time to register the cancel toast was
            // there); transcribing→idle is a non-urgent "done"; everything
            // else falls back to the ambient phase spring.
            let origin = displayPhase
            let idleAnim: Animation
            switch origin {
            case .cancelled:      idleAnim = cancelledToIdle
            case .undoPaste:      idleAnim = cancelledToIdle
            case .transcribing:   idleAnim = transcribeToIdle
            case .meetingCapture: idleAnim = transcribeToIdle
            default:              idleAnim = phaseSpring
            }
            settlingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                commit(.idle, idleAnim)
            }
        } else if immediate {
            commit(next, nil)
        } else if next == .recording {
            // Recording entry must be INSTANT — no animation, no spring. The
            // user pressed the hotkey and any easing here reads as "the app
            // is slow". Pair this with `.transition(.identity)` on the
            // RecordingPill case so SwiftUI doesn't fade/scale it in.
            commit(next, nil)
        } else if next == .locked && displayPhase == .recording {
            // The user just double-tapped to lock — a mild celebration is OK.
            commit(next, recordingToLocked)
        } else if next == .transcribing && displayPhase == .recording {
            // Tapering off — slightly snappier than the lock celebration.
            commit(next, recordingToTranscribe)
        } else {
            // Ambient transitions (polishingSelection, cancelled entry, etc.)
            // use the calm phase spring.
            commit(next, phaseSpring)
        }
    }

    // MARK: - Meeting dot positioning
    //
    // Half-widths used to compute where the meeting dot sits, just to the
    // right of whatever pill is currently on screen. Values reflect the
    // actual pill structs in this file (not their visible mid-animation
    // sizes — these are the steady-state widths).
    private func pillHalfWidth(for phase: PillPhase) -> CGFloat {
        switch phase {
        case .idle:               return 7    // 14pt idle dot
        case .recording:          return 58   // ~116pt: waveform 88 + h-padding 14*2
        case .locked:
            // The locked pill's controls row is ~144pt steady-state, but when a
            // live-partial preview is showing the VStack's text area pushes the
            // GlassCapsule background wider as the wrapped text fills more of
            // the panel. Eyeballed bump keeps the dot clear of the partial
            // preview's right edge without overlapping it.
            let base: CGFloat = 72
            return state.livePartialText.isEmpty ? base : base + 8
        case .transcribing:       return 20   // 40pt fixed frame
        case .polishingSelection: return 50   // ~100pt: ring + "Polishing" text + padding
        case .meetingCapture:     return 50   // legacy dead case
        case .cancelled:          return 82   // ~164pt: "Cancelled" + Undo capsule + padding
        case .undoPaste:          return 72   // ~144pt: Undo capsule + padding
        }
    }

    /// Where to place the persistent meeting dot horizontally. Centered while
    /// idle (it IS the idle pill); otherwise just right of the visible pill.
    /// Clamped so the visible dot stays inside the 180pt panel band and within
    /// the 170pt hit-test band (PillHostingView.visibleBandWidth). Max safe
    /// center offset = (170 - dotSize) / 2 → ~77pt for the 16pt companion dot.
    /// Parameterised version used by both the computed var and the commit closure.
    private func meetingDotOffsetX(for phase: PillPhase) -> CGFloat {
        if phase == .idle { return 0 }
        let dotSize: CGFloat = 16
        let gap: CGFloat = 8
        let dotHalf: CGFloat = dotSize / 2
        let raw = pillHalfWidth(for: phase) + gap + dotHalf
        let maxOffset: CGFloat = (170 - dotSize) / 2
        return min(raw, maxOffset)
    }

    private var meetingDotOffsetX: CGFloat { meetingDotOffsetX(for: displayPhase) }

    /// Slightly larger as the standalone idle indicator, smaller as a
    /// companion alongside an active pill.
    private var meetingDotSize: CGFloat {
        displayPhase == .idle ? 20 : 16
    }
}

// MARK: - Shared glass surface

/// View-modifier version of GlassCapsule. We expose this as a modifier
/// (not a background view) because GlassEffectContainer needs the .glassEffect
/// to live on the SAME view node as the .glassEffectID. Previously the glass
/// surface was buried inside GlassCapsule.body — the container couldn't see
/// it through the .background() layer and fell back to crossfade between
/// pill phases. Now the glass applies directly to the content view.
private struct GlassCapsuleModifier: ViewModifier {
    var fillOpacity: Double = 0.55
    var glowLevel: CGFloat = 0

    @AppStorage("pillSkin") private var pillSkin: String = "default"

    private var glowRadius: CGFloat { min(glowLevel * 12, 9) }
    private var glowOpacity: Double { min(Double(glowLevel) * 0.40, 0.16) }

    /// Skin classification — only three. Glass (default), Black, Niche.
    /// - `glass`: native Liquid Glass with a subtle dark tint so the
    ///   waveform and text on top stay readable over any wallpaper
    /// - `black`: solid matte black, no refraction
    /// - `aurora(.iris)`: niche pink/indigo aurora mesh
    private enum SkinKind { case aurora(AuroraPalette), black, glass }
    private var skinKind: SkinKind {
        switch pillSkin {
        case "black":  return .black
        case "niche":  return .aurora(.iris)
        // Default + glass + anything else → Glass. Glass is the new default.
        default:       return .glass
        }
    }

    func body(content: Content) -> some View {
        switch skinKind {
        case .glass:
            // Glass applies DIRECTLY to the content view — this is the
            // critical structural change. GlassEffectContainer + glassEffectID
            // can now see this glass surface at the outer level (same view
            // node as the .glassEffectID modifier on the pill). Previously
            // the glass was inside a .background() and the container couldn't
            // morph between phases.
            //
            // NOTE: No .animation() modifiers here. Attaching per-property
            // .animation() on the glass/capsule level created a second
            // animation context that competed with the GlassEffectContainer's
            // .bouncy morph and caused cross-fade flicker instead of a glass
            // morph between phases. The glow shadow updates (audioPeak-driven)
            // are fast enough that they don't need easing at this layer.
            content
                .glassEffect(
                    .regular.tint(Color.black.opacity(0.35)).interactive(),
                    in: .capsule
                )
                .shadow(color: .white.opacity(max(glowOpacity, 0.10)), radius: max(glowRadius, 4), y: 0)
        case .black:
            // Solid matte black — no refraction. Critical layering: fill via
            // .background, CLIP to capsule (prevents waveform/text from
            // bleeding past the edge), then overlay the stroke on the SAME
            // shape used for clipping so the hairline border sits exactly on
            // the visible edge instead of being cut in half by the bounds.
            content
                .background(Capsule(style: .continuous).fill(Color.black))
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                )
                .shadow(color: .white.opacity(max(glowOpacity, 0.10)), radius: max(glowRadius, 4), y: 0)
        case .aurora(let palette):
            // Aurora skin: colored mesh background + clear Liquid Glass
            // overlay that lenses the aurora at the edges. Glass at the
            // outer level so morph works.
            content
                .background(
                    AuroraBackground(palette: palette)
                        .padding(-4)
                        .clipShape(Capsule(style: .continuous))
                        .drawingGroup(opaque: false)
                        .allowsHitTesting(false)
                )
                .glassEffect(.clear.interactive(), in: .capsule)
                .shadow(color: .white.opacity(max(glowOpacity, 0.10)), radius: max(glowRadius, 4), y: 0)
        }
    }
}

extension View {
    /// Apply Voice's pill surface treatment (glass / black / niche) as a
    /// modifier so the glass effect sits on the SAME view node as any
    /// glassEffectID — required for GlassEffectContainer morphing.
    func glassCapsule(fillOpacity: Double = 0.55, glowLevel: CGFloat = 0) -> some View {
        modifier(GlassCapsuleModifier(fillOpacity: fillOpacity, glowLevel: glowLevel))
    }
}

// MARK: - Idle pill

private struct IdlePill: View {
    let onTap: () -> Void
    let onPolish: (String) -> Void

    // Hover spans pill + bar + a small invisible bridge so the bar stays open
    // while the cursor travels from dot → bar (would otherwise drop hover and
    // flicker the bar shut). The pill stays the trigger; the bar appears ABOVE
    // it because the pill sits at the bottom of the screen.
    @State private var isHoveringRegion = false
    @State private var isHoveringDot = false
    @State private var isPressed = false
    /// Tracks whether the current press has moved far enough to count as a drag
    /// (vs a tap). Threshold: ~4pt — small so the snap-while-dragging UX
    /// engages quickly. When true, the gesture's onEnded posts
    /// `voice.pillDragEnd` instead of firing onTap.
    @State private var isDragging = false
    private let dragThreshold: CGFloat = 4
    /// Namespace for the dot ↔ bar Liquid Glass morph inside the
    /// GlassEffectContainer. Shared between the two children so the system
    /// treats them as a single morphing glass body.
    @Namespace private var pillMorphNS

    private let dotFrameW: CGFloat = 40
    private let dotFrameH: CGFloat = 22
    private let bridgeHeight: CGFloat = 6

    var body: some View {
        let expanded = isHoveringRegion
        // Flat dot — no opacity ramps, no size morph, no fade. The previous
        // shaded variant was visual noise (per user feedback).

        // True Liquid Glass morph (Dynamic-Island style). Three things matter:
        //   1. Each glass child needs BOTH .glassEffect(_:in:) AND
        //      .glassEffectID(_:in:) — Apple's docs are explicit. Without
        //      glassEffect on the child, the container has no surface to
        //      morph. We used to have a plain Circle().fill() here so the
        //      container was inert.
        //   2. spacing must be large enough that the two shapes' edges fall
        //      within `spacing` points of each other when displayed — that's
        //      when surface tension pulls them together with a visible neck.
        //      18pt was way too tight; 32pt makes the merge visible.
        //   3. No .transition() modifier on children. The container uses
        //      .matchedGeometry by default; any explicit transition fights
        //      that and produces a fade.
        GlassEffectContainer(spacing: 32) {
            VStack(spacing: 0) {
                // Action bar above the pill — appears via glass morph from the dot.
                if expanded {
                    HoverActionBar(
                        onDictate: onTap,
                        onPolish: { level in onPolish(level) }
                    )
                    .glassEffectID("bar", in: pillMorphNS)
                    // Invisible bridge so the cursor can travel bar → dot without
                    // dropping hover and dismissing the bar.
                    Color.clear.frame(height: bridgeHeight)
                }

                // Flat dot, fades to ~45% when not hovered so it sits quietly
                // on the screen. Pops to full opacity on hover so the
                // affordance is unmistakable when the user reaches for it.
                Circle()
                    .fill(Color.black.opacity(expanded ? 1.0 : 0.45))
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(expanded ? 0.30 : 0.18), lineWidth: 0.6)
                    )
                    .frame(width: 14, height: 14)
                    .glassEffectID("dot", in: pillMorphNS)
                    .scaleEffect(isPressed ? 0.82 : 1.0)
                    .frame(width: dotFrameW, height: dotFrameH)
                    .contentShape(Rectangle())
                    // .simultaneousGesture (not .gesture) matches every other
                    // press-drag handler in this file (HoverActionButton,
                    // RecordingPill, LockedPill controls). With plain .gesture
                    // the SwiftUI gesture can be cancelled by competing
                    // implicit gestures from .onHover / parent containers,
                    // which manifests as the drag dropping mid-motion. Global
                    // coordinate space keeps the gesture's translation stable
                    // even though the panel's local origin moves under the
                    // cursor each time we snap to a new corner.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                isPressed = true
                                let dist = hypot(value.translation.width, value.translation.height)
                                if dist > dragThreshold {
                                    if !isDragging { isDragging = true }
                                    // Use the gesture's reported global location —
                                    // more reliable than NSEvent.mouseLocation
                                    // (which can lag a frame behind the gesture
                                    // value) and already in the screen coord
                                    // space NSPanel.setFrame uses.
                                    let screenX = value.location.x
                                    NotificationCenter.default.post(
                                        name: Notification.Name("voice.pillDrag"),
                                        object: nil,
                                        userInfo: ["screenX": screenX]
                                    )
                                }
                            }
                            .onEnded { value in
                                isPressed = false
                                if isDragging {
                                    isDragging = false
                                    let screenX = value.location.x
                                    NotificationCenter.default.post(
                                        name: Notification.Name("voice.pillDragEnd"),
                                        object: nil,
                                        userInfo: ["screenX": screenX]
                                    )
                                } else {
                                    onTap()
                                }
                            }
                    )
                    .onHover { hovering in
                        isHoveringDot = hovering
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
            }
        }
        // Bouncy spring drives the morph — extraBounce gives the surface
        // tension snap as the neck collapses. The container reads this when
        // `expanded` changes.
        .animation(.bouncy(duration: 0.42, extraBounce: 0.15), value: expanded)
        .onHover { hovering in
            isHoveringRegion = hovering
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHoveringRegion)
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: isHoveringDot)
        .animation(.spring(response: 0.14, dampingFraction: 0.78), value: isPressed)
        .help("Hover to reveal Dictate + Polish actions.")
    }
}

// MARK: - Hover action bar (Dictate / Polish)

private struct HoverActionBar: View {
    let onDictate: () -> Void
    /// Called with the cleanup level the user picked: "light" / "medium" / "heavy".
    /// Light = spelling + punctuation only. Medium = grammar + fillers. Heavy =
    /// full rewrite (still keeps the speaker's intent, just tightens phrasing).
    let onPolish: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            HoverActionButton(
                icon: "mic.fill",
                label: "Dictate",
                hotkey: "fn",
                action: onDictate
            )

            // Subtle divider between the dictate action and the polish levels.
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            HoverActionButton(
                icon: "text.badge.checkmark",
                label: "Spell",
                hotkey: "⌥1",
                action: { onPolish("light") }
            )
            HoverActionButton(
                icon: "text.badge.star",
                label: "Grammar",
                hotkey: "⌥2",
                action: { onPolish("medium") }
            )
            HoverActionButton(
                icon: "text.badge.xmark",
                label: "Rewrite",
                hotkey: "⌥3",
                action: { onPolish("heavy") }
            )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        // Native Liquid Glass background. Real refraction + specular highlight
        // (no fake shadows). The interactive variant makes the surface deform
        // subtly under cursor movement, which sells the "liquid" feel.
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .fixedSize()
    }
}

private struct HoverActionButton: View {
    let icon: String
    let label: String
    let hotkey: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    private let buttonSize: CGFloat = 28
    private let tooltipDelayNs: UInt64 = 200_000_000

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.bodyMedium)
                .foregroundStyle(.white.opacity(isHovering ? 1.0 : 0.82))
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0.0))
                )
                .scaleEffect(isPressed ? 0.90 : (isHovering ? 1.06 : 1.0))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            // Tooltip sits ABOVE the button. We anchor to the top edge and
            // push UP by buttonSize. `allowsHitTesting(false)` keeps the
            // tooltip from stealing hover from its own button (which would
            // cause a hover-flicker loop).
            if showTooltip {
                TooltipCapsule(label: label, hotkey: hotkey)
                    .fixedSize()
                    .offset(y: -(buttonSize + 2))
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: tooltipDelayNs)
                    if !Task.isCancelled { showTooltip = true }
                }
            } else {
                showTooltip = false
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.spring(response: 0.16, dampingFraction: 0.78), value: isHovering)
        .animation(.spring(response: 0.12, dampingFraction: 0.75), value: isPressed)
        .animation(.easeOut(duration: 0.14), value: showTooltip)
    }
}

private struct TooltipCapsule: View {
    let label: String
    let hotkey: String

    /// Pink/lilac accent for the hotkey hint, matching the reference design.
    private static let hotkeyColor = Color(red: 1.0, green: 0.6, blue: 0.85)

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.sans(11, weight: .semibold))
                .foregroundStyle(.white)
            Text(hotkey)
                .font(.sans(10, weight: .medium))
                .foregroundStyle(Self.hotkeyColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.30), radius: 5, x: 0, y: 2)
        )
    }
}

// MARK: - Recording (push-to-talk)

private struct RecordingPill: View {
    @Bindable var state: RecordingState

    private var audioPeak: Float {
        state.audioLevels.max() ?? 0
    }

    /// Stroke color driven by ASR confidence. White = high confidence,
    /// amber = uncertain, red = low — gives the user a passive signal that
    /// the model is struggling without interrupting the flow.
    private var confidenceStrokeColor: Color {
        let c = state.transcriptionConfidence
        if c < 0.40 {
            return Color(red: 0.95, green: 0.35, blue: 0.30)
        } else if c < 0.55 {
            return Color(red: 0.95, green: 0.65, blue: 0.20)
        } else {
            return Color.white.opacity(0.36)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            // No-input warning: a small pulsing red dot is louder visually
            // than 22 chars of microcopy and never bloats the pill width.
            if state.noInputDetected {
                NoInputDot()
                    .transition(.scale.combined(with: .opacity))
            }

            WaveformView(
                levels: state.audioLevels,
                audioPeak: audioPeak,
                inputLevel: state.inputLevel,
                accent: .neutral
            )
            .frame(width: 88, height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .glassCapsule(fillOpacity: 0.85, glowLevel: CGFloat(audioPeak))
        // Confidence ring — sits on top of the GlassCapsule's own hairline
        // stroke. Same line width as the underlying stroke, only kicks in
        // when confidence dips below the comfortable threshold.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(confidenceStrokeColor, lineWidth: state.transcriptionConfidence < 0.55 ? 1.2 : 0)
                .animation(.easeOut(duration: 0.18), value: state.transcriptionConfidence)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        // BUGFIX: scoping the implicit animation to ONLY noInputDetected
        // prevents it from being applied to every other state change that
        // re-renders this pill (audioPeak updates, livePartial deltas).
        // The previous broad `.animation(...)` was fighting the NoInputDot
        // `.transition(.scale.combined(with: .opacity))` AND animating the
        // background glow re-render — visible as the pill "shimmer" the
        // user reported. Wrapping in `transaction` confines the animation
        // strictly to the no-input toggle event.
        .transaction(value: state.noInputDetected) { tx in
            tx.animation = .spring(response: 0.28, dampingFraction: 0.85)
        }
    }
}

// MARK: - No-input pulsing dot

private struct NoInputDot: View {
    var body: some View {
        // 1.2s breath — 20fps is plenty for a slow sin-driven pulse, and
        // cuts the timeline tick rate by 33% vs. 30fps.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 1.2s breath
            let phase = (t.truncatingRemainder(dividingBy: 1.2)) / 1.2
            let s = sin(phase * 2 * .pi)
            let opacity = 0.55 + 0.35 * s   // 0.20 … 0.90
            let scale = 1.0 + 0.18 * s
            Circle()
                .fill(Color(red: 1.0, green: 0.32, blue: 0.32))
                .frame(width: 6, height: 6)
                .opacity(opacity)
                .scaleEffect(scale)
                .shadow(color: Color.red.opacity(0.45), radius: 3, y: 0)
                .help("No mic input. Check microphone permissions.")
        }
        .frame(width: 8, height: 8)
    }
}

// MARK: - Meeting recording dot

/// Gradient orb that persists while a meeting capture session is running.
/// Uses the same `AuroraBackground` mesh gradient as the dictation pill,
/// clipped to a circle — a static-looking rich field of color that may
/// breathe subtly but does NOT spin.
///
/// The view does NOT impose its own frame — the parent applies
/// `.frame(width:height:)` externally so SwiftUI can interpolate the size
/// when `displayPhase` changes.
private struct MeetingRecordingDot: View {
    var onStop: (() -> Void)? = nil
    @State private var isHovering = false
    @State private var didEnter = false
    @AppStorage("pillSkin") private var pillSkin: String = "default"

    private enum DotSkin { case aurora(AuroraPalette), black, glass }
    private var dotSkin: DotSkin {
        switch pillSkin {
        case "black":  return .black
        case "niche":  return .aurora(.iris)
        default:       return .glass
        }
    }

    /// Per-skin dark base color so the gradient always pops regardless
    /// of wallpaper. Tuned to the skin's anchor hue.
    private var baseColor: Color {
        switch dotSkin {
        case .aurora:  return Color(red: 0.12, green: 0.10, blue: 0.22)  // iris anchor
        case .black:   return Color.black
        case .glass:   return Color.clear
        }
    }

    /// Per-skin outer glow color so the shadow tints match the surface.
    private var glowColor: Color {
        switch dotSkin {
        case .aurora:  return Color(red: 0.302, green: 0.251, blue: 1.0)
        case .black:   return Color.white.opacity(0.08)
        case .glass:   return Color.white.opacity(0.30)
        }
    }

    var body: some View {
        // 4s breath — 20fps cap (same pattern as NoInputDot / TranscribingGlyph).
        // Replaces the `withAnimation(.repeatForever)` on breathPhase that was
        // driving the sentinel ring at display-link rate (60–120 Hz).
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathPhase = CGFloat((t.truncatingRemainder(dividingBy: 4.0)) / 4.0)
            innerBody(breathPhase: breathPhase)
        }
    }

    @ViewBuilder
    private func innerBody(breathPhase: CGFloat) -> some View {
        ZStack {
            // Skin-dependent surface. Aurora skins get the mesh; black is
            // solid; glass is pure Liquid Glass refraction; default is dark
            // frosted glass.
            switch dotSkin {
            case .aurora(let palette):
                Circle().fill(baseColor)
                AuroraBackground(palette: palette)
                    .padding(-3)
                    .clipShape(Circle())
            case .black:
                Circle().fill(Color.black)
            case .glass:
                Circle()
                    .glassEffect(
                        .regular.tint(Color.black.opacity(0.30)).interactive(),
                        in: .circle
                    )
            }

            // Inner top-left sheen for 3-D orb depth.
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.white.opacity(0.50), location: 0.0),
                                .init(color: Color.white.opacity(0.0),  location: 0.55)
                            ]),
                            center: UnitPoint(x: 0.30, y: 0.26),
                            startRadius: 0,
                            endRadius: d * 0.50
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            // Rim vignette — darkens the edge so the orb feels bounded by a
            // curved glass surface rather than a flat disc. Pairs with the
            // top-left sheen: bright-near-pole + falloff-at-horizon = sphere.
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.black.opacity(0.0),  location: 0.55),
                                .init(color: Color.black.opacity(0.18), location: 0.88),
                                .init(color: Color.black.opacity(0.35), location: 1.0)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: d * 0.50
                        )
                    )
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }

            // Crisp edge so the orb pops against any wallpaper.
            Circle()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75)
        }
        // Sentinel ring — slow outward pulse, in phase with the breath. A faint
        // glow-tinted hoop expands and fades every 4s. Hidden on hover so it
        // doesn't fight the click affordance.
        .background(
            Circle()
                .stroke(glowColor.opacity(0.45 * (1 - breathPhase)), lineWidth: 1)
                .scaleEffect(1.0 + 0.45 * breathPhase)
                .opacity(isHovering ? 0 : 1)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.25), value: isHovering)
        )
        // Breath (1.0 → 1.035) composes multiplicatively with hover (1.15) and
        // the entrance scale (0 → 1). Calm 4s sine — below conscious notice but
        // alive in peripheral vision.
        .scaleEffect((isHovering ? 1.15 : 1.0) * (didEnter ? 1.0 + 0.035 * sin(breathPhase * .pi) : 0.0))
        // Tight glow — radius 5 reads as "lit from within" not "blurry blob".
        .shadow(color: glowColor.opacity(0.70), radius: 5, y: 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isHovering)
        .onHover { h in
            isHovering = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture { onStop?() }
        .help(onStop != nil ? "Meeting recording — tap to stop" : "Meeting recording in progress")
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.70)) { didEnter = true }
        }
    }
}

// MARK: - Locked (X | wave | ✓) + optional live-partial preview

private struct LockedPill: View {
    @Bindable var state: RecordingState
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var audioPeak: Float {
        state.audioLevels.max() ?? 0
    }

    /// Split the partial text into a confirmed prefix and a volatile suffix.
    /// When `livePartialIsVolatile` is false the whole string is confirmed.
    private var confirmedText: String {
        guard state.livePartialIsVolatile, !state.livePartialText.isEmpty else {
            return state.livePartialText
        }
        // The confirmed portion is everything except the last word(s) —
        // SlidingWindowAsrManager marks the most-recent chunk volatile.
        // We don't have the exact split point at the UI layer, so we render
        // the entire string at full opacity when confirmed and use a
        // trailing-dim trick only when the latest chunk is volatile.
        // Full approach: treat all but the last space-delimited "word group"
        // appended since the last confirmation as the confirmed prefix.
        // Since we accumulate confirmedSoFar in the coordinator, a simpler
        // heuristic works: the coordinator already sets livePartialIsVolatile
        // to reflect the latest update, and the update.text is the volatile
        // part appended after confirmedSoFar. We don't have the boundary here,
        // so we dim the ENTIRE string when volatile and show full white when
        // confirmed — keeps the UI simple and still communicates the state.
        return ""   // see body — whole string rendered at volatile opacity when volatile
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live-partial preview (only when partial text is available).
            // Literal `Color.white` is intentional here: the pill capsule is
            // always a dark glass surface regardless of system theme, so the
            // text needs to be a fixed light value, not `.primary`.
            if !state.livePartialText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(state.livePartialText)
                            .font(.sans(11, weight: .regular))
                            .foregroundStyle(
                                state.livePartialIsVolatile
                                    ? Color.white.opacity(0.55)
                                    : Color.white
                            )
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .id("bottom")
                    }
                    .frame(maxHeight: 80)
                    .onChange(of: state.livePartialText) { _, _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Hairline separator between partial text and the controls row.
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 0.5)
            }

            // Controls row: X | lock-glyph + waveform | ✓
            // The amber lock glyph + warm-tinted bars give locked mode a
            // distinct visual identity vs. push-to-talk (cool neutral).
            HStack(spacing: 5) {
                ActionButton(systemName: "xmark", hoverTint: Color.red.opacity(0.55), action: onCancel)

                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WaveformAccent.warm.primary.opacity(0.85))

                WaveformView(
                    levels: state.audioLevels,
                    audioPeak: audioPeak,
                    inputLevel: state.inputLevel,
                    accent: .warm
                )
                .frame(width: 68, height: 16)

                ActionButton(systemName: "checkmark", hoverTint: Color.green.opacity(0.55), action: onConfirm)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        // Apply glass surface using the shared glassCapsule modifier so that
        // GlassEffectContainer can see the .glassEffect at the outer level and
        // morph the surface between recording → locked instead of cross-fading.
        // Shape switching for the live-partial tall variant is applied via
        // .clipShape AFTER the glass modifier, which is safe — the glass
        // renders at the capsule shape and the clip trims it to the rounded
        // rect when text is present.
        .glassCapsule(fillOpacity: 0.85)
        .clipShape(
            state.livePartialText.isEmpty
                ? AnyShape(Capsule(style: .continuous))
                : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            Group {
                if state.livePartialText.isEmpty {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                }
            }
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let systemName: String
    let hoverTint: Color
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false
    @AppStorage("pillSkin") private var pillSkin: String = "default"

    /// True when the pill is rendering in glass skin. The cancel/confirm
    /// buttons inside LockedPill ("halt button") used to render as a flat
    /// solid disc regardless of skin, which broke visual consistency with
    /// the glossy capsule around them. When glass skin is active we use
    /// .glassEffect so the buttons inherit the same refraction treatment.
    private var isGlassSkin: Bool {
        pillSkin != "black" && pillSkin != "niche"
    }

    var body: some View {
        // Custom gesture, not Button — SwiftUI's Button on macOS adds a
        // small but perceptible delay before invoking its action (it waits
        // to disambiguate a press from a drag). The X / ✓ buttons in lock
        // mode are the user's "I'm done" affordance; any latency here reads
        // as "the app is slow to respond". DragGesture(minimumDistance: 0)
        // dispatches on first contact and gives us sub-frame response.
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: 22, height: 22)
            .background(
                Group {
                    if isPressed || isHovering {
                        // Active states use the tint colour so the hit-target
                        // is unambiguous regardless of skin.
                        Circle().fill(isPressed ? hoverTint.opacity(0.85) : hoverTint)
                    } else if isGlassSkin {
                        // Glass skin: the resting state is a refractive
                        // glass disc that matches the surrounding capsule.
                        Circle()
                            .glassEffect(.regular.interactive(), in: .circle)
                    } else {
                        // Black / niche skin: flat translucent white disc.
                        Circle().fill(Color.white.opacity(0.28))
                    }
                }
            )
            .scaleEffect(isPressed ? 0.94 : (isHovering ? 1.06 : 1.0))
            // Two animation channels so press and hover don't fight each
            // other — press is faster (the click should feel immediate);
            // hover is slightly slower (an idle ambient cue).
            .animation(.easeOut(duration: 0.10), value: isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .contentShape(Circle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { isPressed = true }
                    }
                    .onEnded { value in
                        isPressed = false
                        // Only fire if the release landed inside the 22×22
                        // hit region. Lets the user "slide off" to cancel
                        // a press — matches native button behavior.
                        let t = value.translation
                        let dist = (t.width * t.width + t.height * t.height).squareRoot()
                        if dist < 22 {
                            action()
                        }
                    }
            )
    }
}

// MARK: - Transcribing (outline + spinner)

private struct TranscribingPill: View {
    var body: some View {
        // No black background slab. The processing state used to render a
        // dark capsule that looked like a stray UI element — user explicitly
        // hated it. Just the glyph on its own, sized to match the idle dot
        // so the morph from recording → transcribing reads as the same body
        // shrinking back. No fill, no shadow.
        TranscribingGlyph()
            .frame(width: 22, height: 22)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
    }
}

/// The glyph inside the transcribing pill. Has two modes:
///
///   - Local mode: a single breathing circle stroke (scale 0.92 ↔ 1.08,
///     opacity 0.52 ↔ 0.88 over 1.6s). Reads as "thinking" without spinning.
///
///   - Cloud mode (`CerebrasPolisher.isAvailable == true`): crossfades
///     between the breathing circle and an SF Symbol cloud over a 3.2s
///     cycle. Both shapes share the same center; opacity interpolates
///     symmetrically so neither ever fully disappears, just trades
///     emphasis. Reads as "this is the cloud engine working".
private struct TranscribingGlyph: View {
    /// Live polish-status observable. The engine glyph crossfades against
    /// the breathing circle ONLY while a polish is actively in flight
    /// (`isCloudPolishing == true`). The symbol shown reflects whether the
    /// last/current polish used the cloud (cloud icon) or a local MLX model
    /// (cpu icon) — previously this always showed the cloud icon, which
    /// was wrong whenever the user ran a fully on-device polish.
    private let status = PolishStatus.shared

    /// Engine kind derived from `PolishStatus.lastEngine`.
    /// Format examples (see PolishStatus.swift): "cloud:cerebras",
    /// "local:qwen3-4b", "rules-only", or nil.
    private enum EngineKind { case cloud, local, unknown }
    private func engineKind(from raw: String?) -> EngineKind {
        guard let raw, !raw.isEmpty else { return .unknown }
        if raw.hasPrefix("cloud:") { return .cloud }
        if raw.hasPrefix("local:") { return .local }
        return .unknown
    }

    var body: some View {
        // 1.6s breath + 3.2s crossfade — slow enough that 20fps is visually
        // identical to 30fps. This view is only mounted while transcribing,
        // but the recording hot-path is sensitive enough that every ms counts.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate

            // Breathing cycle for the circle (1.6s).
            let breathT = (phase.truncatingRemainder(dividingBy: 1.6)) / 1.6
            let breathS = sin(breathT * 2 * .pi)
            let circleScale = 1.0 + 0.08 * breathS
            let circleOpacityBase = 0.70 + 0.18 * breathS

            // Crossfade only when a polish is actually happening (cloud OR
            // local). `isCloudPolishing` is the legacy flag name but the
            // upstream sets it for both engines during the in-flight window.
            let polishActive = status.isCloudPolishing
            let kind = engineKind(from: status.lastEngine)
            let xfadeT = (phase.truncatingRemainder(dividingBy: 3.2)) / 3.2
            let xfade = 0.5 + 0.5 * cos(xfadeT * 2 * .pi)

            // Pick the engine icon. Cloud → cloud.fill. Local → cpu (on-device).
            // Unknown engine while in-flight → neutral "thinking" sparkles
            // so we never claim a cloud round trip happened when it didn't.
            let engineSymbol: String? = {
                guard polishActive else { return nil }
                switch kind {
                case .cloud:   return "cloud.fill"
                case .local:   return "cpu"
                case .unknown: return "sparkles"
                }
            }()

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(circleOpacityBase * (polishActive ? xfade : 1.0)), lineWidth: 1.5)
                    .scaleEffect(circleScale)

                if let symbol = engineSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85 * (1.0 - xfade)))
                        .scaleEffect(0.92 + 0.08 * (1.0 - xfade))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: polishActive)
            .animation(.easeOut(duration: 0.18), value: engineSymbol)
        }
    }
}

// MARK: - Polishing Selection

/// Shown during the Opt+1 flow while a selected text region is being polished.
/// Click-through (user cannot interact) — same visual weight as TranscribingPill
/// Minimal polishing indicator: rotating gear icon, no text. Reads as clean
/// "processing in progress" without clutter.
/// "Window cleaning" pill shown while polishing selected text.
/// The animation is a wiper arc that sweeps the circle — suggests buffing
/// or cleaning the text rather than mere "processing".
private struct PolishingSelectionPill: View {
    @State private var angle: Double = 0
    @State private var shimmer: Double = 0

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.8)
                    .frame(width: 17, height: 17)

                // Wiper arc — tapered sweep, rotates continuously
                Circle()
                    .trim(from: 0.0, to: 0.32)   // ~115° arc = wiper blade
                    .stroke(
                        AngularGradient(
                            stops: [
                                .init(color: Color(nsColor: NSColor.controlAccentColor).opacity(0.9), location: 0.00),
                                .init(color: Color(nsColor: NSColor.controlAccentColor).opacity(0.55), location: 0.16),
                                .init(color: .clear,                                                   location: 0.32),
                                .init(color: .clear,                                                   location: 1.00),
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                    )
                    .frame(width: 17, height: 17)
                    .rotationEffect(.degrees(angle - 90))  // -90 so arc starts at top
            }

            Text("Polishing")
                .font(.sans(11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6 + 0.2 * sin(shimmer * .pi)))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule(fillOpacity: 0.80)
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                angle = 360
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                shimmer = 1
            }
        }
    }
}

// MARK: - Meeting Capture

/// Shown while a meeting capture session is active (Google Meet / Zoom / Teams).
/// Tap the pill to stop the capture session.
private struct MeetingCapturePill: View {
    let onTap: () -> Void
    let durationSeconds: Int
    @State private var pulse: Double = 0

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.red.opacity(0.6 + 0.4 * pulse))
                .frame(width: 7, height: 7)
            Text(durationSeconds > 0 ? "Meeting \u{00B7} \(formatDuration(durationSeconds))" : "Meeting")
                .font(.sans(11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule(fillOpacity: 0.80)
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = 1
            }
        }
    }

    private func formatDuration(_ s: Int) -> String {
        if s < 3600 {
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Sparkles icon that breathes in sync with the SweepingRing pulse pattern.
private struct SparklesBreath: View {
    var body: some View {
        // 1.6s breath — 20fps is visually identical for a slow sin pulse.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
            let s = sin(phase * 2 * .pi)
            let opacity = 0.70 + 0.18 * s     // 0.52 … 0.88 (matches SweepingRing)
            let scale = 1.0 + 0.06 * s        // 0.94 … 1.06
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(opacity))
                .scaleEffect(scale)
        }
    }
}

// MARK: - Cancelled Toast

private struct CancelledToast: View {
    let shownAt: Date
    let onUndo: () -> Void
    @State private var undoHovering = false
    @State private var undoPressed = false
    private let totalDuration: TimeInterval = 3.0

    var body: some View {
        // 10 fps is plenty for a progress bar that drains over 3 seconds.
        // 30fps was unnecessarily waking the main thread 3× more than needed.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(shownAt)
            let remaining = max(0, 1.0 - elapsed / totalDuration)

            HStack(spacing: 8) {
                Text("Cancelled")
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.80))

                // Same low-latency gesture pattern as ActionButton: the
                // 4-second window to undo is tight, every ms of perceived
                // delay matters.
                Text("Undo")
                    .font(.sans(11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(
                                undoPressed ? 0.30 : (undoHovering ? 0.22 : 0.14)
                            ))
                    )
                    .scaleEffect(undoPressed ? 0.96 : 1.0)
                    .animation(.easeOut(duration: 0.10), value: undoPressed)
                    .animation(.easeOut(duration: 0.14), value: undoHovering)
                    .contentShape(Capsule())
                    .onHover { hovering in
                        undoHovering = hovering
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !undoPressed { undoPressed = true }
                            }
                            .onEnded { value in
                                undoPressed = false
                                let t = value.translation
                                let dist = (t.width * t.width + t.height * t.height).squareRoot()
                                if dist < 40 { onUndo() }
                            }
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassCapsule(fillOpacity: 0.85)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(width: geo.size.width * remaining, height: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 3)
            }
            .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 5)
        }
    }
}

// MARK: - Undo Paste Toast

private struct UndoPasteToast: View {
    let shownAt: Date
    let onUndo: () -> Void
    @State private var undoHovering = false
    @State private var undoPressed = false
    @State private var toastHovering = false
    /// Accumulated elapsed time NOT counting any periods when the toast was hovered.
    /// We freeze this whenever `toastHovering` is true.
    @State private var frozenElapsed: TimeInterval = 0
    @State private var lastTick: Date? = nil
    private let totalDuration: TimeInterval = 7.0

    var body: some View {
        // 10 fps is plenty for a progress bar that drains over 7 seconds.
        // 30fps was unnecessarily waking the main thread 3× more than needed.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: false)) { context in
            // Compute elapsed time, but PAUSE accumulation while the user is hovering
            // over the toast. We can't mutate state inside `body`, so we read the
            // last computed frozenElapsed and advance it via .onChange of the timeline
            // tick using a side-effect-free derivation:
            //   - if hovering, remaining freezes at last value
            //   - if not hovering, remaining decrements normally
            let now = context.date
            let delta: TimeInterval = {
                guard let last = lastTick else { return 0 }
                return max(0, now.timeIntervalSince(last))
            }()
            let liveElapsed = toastHovering ? frozenElapsed : (frozenElapsed + delta)
            let remaining = max(0, 1.0 - liveElapsed / totalDuration)

            HStack(spacing: 8) {
                // Same low-latency gesture pattern as ActionButton and CancelledToast.
                Text("Undo")
                    .font(.sans(11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(
                                undoPressed ? 0.30 : (undoHovering ? 0.22 : 0.14)
                            ))
                    )
                    .scaleEffect(undoPressed ? 0.96 : 1.0)
                    .animation(.easeOut(duration: 0.10), value: undoPressed)
                    .animation(.easeOut(duration: 0.14), value: undoHovering)
                    .contentShape(Capsule())
                    .onHover { hovering in
                        undoHovering = hovering
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !undoPressed { undoPressed = true }
                            }
                            .onEnded { value in
                                undoPressed = false
                                let t = value.translation
                                let dist = (t.width * t.width + t.height * t.height).squareRoot()
                                if dist < 40 { onUndo() }
                            }
                    )
            }
            .onChange(of: now) { _, newValue in
                // Advance the accumulator only when not hovering. This is the
                // single source of truth for elapsed-time progression and lets
                // hover hold the depleting bar perfectly still.
                if let last = lastTick {
                    let d = max(0, newValue.timeIntervalSince(last))
                    if !toastHovering {
                        frozenElapsed += d
                    }
                }
                lastTick = newValue
            }
            .onAppear {
                // Seed lastTick from shownAt so the first frame doesn't jump.
                lastTick = shownAt
                frozenElapsed = max(0, now.timeIntervalSince(shownAt))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassCapsule(fillOpacity: 0.85)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(width: geo.size.width * remaining, height: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 3)
            }
            .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 5)
            .onHover { hovering in
                // Freeze the depleting bar / dismissal countdown while the
                // user is hovering the toast — gives them time to read or
                // mouse over to Undo without the toast disappearing.
                toastHovering = hovering
            }
        }
    }
}

// MARK: - Waveform accent

/// Color palette for the waveform. `neutral` for push-to-talk (cool white),
/// `warm` for locked-mode (subtle amber so the user can tell the two states
/// apart at a glance). Each accent ships a top→bottom gradient that ties bar
/// height to a slight hue shift — taller = warmer/brighter.
enum WaveformAccent {
    case neutral
    case warm

    var primary: Color {
        switch self {
        case .neutral: return .white
        case .warm:    return Color(red: 1.0, green: 0.78, blue: 0.42)
        }
    }

    var textColor: Color {
        switch self {
        case .neutral: return .white
        case .warm:    return Color(red: 1.0, green: 0.88, blue: 0.65)
        }
    }

    func gradient(forLevel level: Float) -> LinearGradient {
        let intensity = Double(min(max(level, 0), 1))
        switch self {
        case .neutral:
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.95 + intensity * 0.05),
                    Color.white.opacity(0.55 + intensity * 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .warm:
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.84, blue: 0.52).opacity(0.95),
                    Color(red: 0.95, green: 0.65, blue: 0.30).opacity(0.65 + intensity * 0.30)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Glass bar (niche skin)

/// Frosted-glass waveform bar used by the "niche" skin. Layers:
///   1. Vertical white gradient fill (top 95% → bottom 70%) for the
///      translucent glass body.
///   2. Top inner highlight — a 35%-height white gradient fading to clear,
///      drives the "lit from above" optical cue.
///   3. Thin hairline stroke (white@70%, 0.5pt) — refined edge.
///   4. Soft drop shadow (black@15%, 2pt radius, 1pt y) — separates bars
///      from the gradient background.
private struct GlassBar: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color.white.opacity(0.72)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                // Top inner highlight — 35% height white→clear.
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.45), location: 0.0),
                                .init(color: Color.white.opacity(0.0),  location: 0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.70), lineWidth: 0.5)
            )
            .frame(width: width, height: height)
            .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Waveform

/// 7-bar mirror-symmetric meter. Bars are paired around the center
/// (0↔6, 1↔5, 2↔4, 3 = peak) so the meter reads as a single chest-rising
/// "I'm hearing you" rather than a chaotic per-bin spectrum.
///
/// Reactivity model (Wispr-quality):
///   1. Per-bar low-pass filter on the incoming `levels` (α 0.35). Filters
///      single-frame DSP spikes without smearing real onsets.
///   2. Gamma 0.55 perceptual curve — quiet speech (0.05-0.40 band) gets the
///      headroom it deserves. Linear scaling makes bars look dead at normal
///      conversational volume.
///   3. 6% floor — never fully flat at silence so the pill doesn't look
///      broken. 4pt ceiling reservation so peaks have visual breathing room.
///   4. NO additive idle breath. The previous breath was a constant 30Hz
///      TimelineView tick that masked real low-volume input ("you're talking
///      but the bars aren't moving") and kept the pill re-rendering every
///      frame even on silence. With the floor in #3 the pill stays visually
///      alive without faking activity.
///   5. The 60ms ease-out on each bar's height is the only smoothing layer
///      SwiftUI applies — fast enough to feel reactive (one breath cycle of
///      speech is ~250ms), slow enough to bridge per-frame DSP jitter.
struct WaveformView: View {
    let levels: [Float]
    let audioPeak: Float
    /// Perceptual 0..1 RMS-derived input level. Retained on the public API
    /// for callsite stability — no longer drives the bar floor (the bars
    /// now track `levels` directly through the gamma curve).
    var inputLevel: Float = 0
    var accent: WaveformAccent = .neutral
    /// When false, the bar grid is hidden (single idle blob is rendered
    /// instead). Defaults to true since current callsites only mount this
    /// view during active recording / locked phases.
    var isRecording: Bool = true

    @AppStorage("pillSkin") private var pillSkin: String = "default"

    private let barCount = 7
    private let maxBarHeight: CGFloat = 22
    private let minBarHeight: CGFloat = 4

    /// Per-bar exponential moving average. Maintains continuity across
    /// renders so a single-frame DSP spike never dominates the visual.
    @State private var smoothed: [Float] = Array(repeating: 0, count: 7)

    var body: some View {
        Group {
            if isRecording {
                bars
            } else {
                idleBlob
            }
        }
        .frame(height: 22)
    }

    private var bars: some View {
        // No TimelineView — the bars update purely via the reactive path
        // on `levels`. The audio capture service pushes `audioLevels` at
        // 30Hz; SwiftUI invalidates the row only when the array actually
        // changes. Previously a 30Hz TimelineView re-evaluated the entire
        // ForEach every frame regardless of input — measurable main-thread
        // cost during long recordings.
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                let lvl = smoothed.indices.contains(i) ? smoothed[i] : 0
                let h = max(minBarHeight, barHeight(value: lvl, maxHeight: maxBarHeight))
                Group {
                    if pillSkin != "default" {
                        GlassBar(width: 2.5, height: h)
                    } else {
                        Capsule(style: .continuous)
                            .fill(accent.gradient(forLevel: lvl))
                            .frame(width: 2.5, height: h)
                    }
                }
                // 60ms is fast enough to feel reactive, slow enough to
                // filter remaining jitter that survived the EMA. Keyed on
                // the per-bar level so a change in bar i doesn't animate
                // bar j.
                .animation(.easeOut(duration: 0.06), value: lvl)
            }
        }
        .drawingGroup() // composite bars into one Metal layer
        .onAppear { applySmoothing(rebandedLevels()) }
        .onChange(of: levels) { _, _ in applySmoothing(rebandedLevels()) }
    }

    /// Single calm dot — shown when not recording. Replaces the previous
    /// "fake breathing" bars that made the pill look unresponsive when
    /// real input was quiet. The dot is intentionally static (no Timeline
    /// tick); the OverlayPillView's idle state owns idle animation.
    private var idleBlob: some View {
        Circle()
            .fill(accent.primary.opacity(0.45))
            .frame(width: 6, height: 6)
    }

    /// Re-band raw `levels` into the 7-bar mirrored layout BEFORE smoothing,
    /// so the EMA filter operates on the same values that will be rendered.
    private func rebandedLevels() -> [Float] {
        var out = [Float](repeating: 0, count: barCount)
        guard !levels.isEmpty else { return out }
        for i in 0..<barCount {
            out[i] = level(for: i)
        }
        return out
    }

    /// Low-pass filter the freshly-banded levels into `smoothed`.
    /// α = 0.65: fast enough to track speech onsets within ~1 frame at 30Hz (~33ms).
    /// The upstream AudioCaptureService already applies a 0.3 EMA before publishing
    /// audioLevels, so a light secondary filter here just bridges per-frame DSP jitter
    /// without adding noticeable lag. Previously α=0.35 (slow) was stacked on top of
    /// AudioCaptureService's 0.3 EMA, making the combined time constant ~2.5× too slow
    /// and causing bars to look sluggish / barely responsive.
    private func applySmoothing(_ raw: [Float]) {
        let alpha: Float = 0.65
        var out = smoothed
        if out.count != barCount {
            out = Array(repeating: 0, count: barCount)
        }
        let count = min(raw.count, out.count)
        for i in 0..<count {
            out[i] = alpha * raw[i] + (1 - alpha) * out[i]
        }
        smoothed = out
    }

    /// Map bar index → mirrored band index (0..3). 7 bars, 4 unique bands.
    /// 0↔6 → band 0, 1↔5 → band 1, 2↔4 → band 2, bar 3 → band 3 (peak).
    private func level(for index: Int) -> Float {
        guard !levels.isEmpty else { return 0 }
        let mirror = index <= barCount / 2 ? index : (barCount - 1 - index)
        let bandCount = 4
        let band = min(mirror, bandCount - 1)
        let count = levels.count
        let start = (band * count) / bandCount
        let end = ((band + 1) * count) / bandCount
        guard end > start else { return 0 }
        let slice = levels[start..<end]
        return slice.reduce(0, +) / Float(slice.count)
    }

    /// Perceptual mapping from a 0..1 smoothed bar value → pixel height.
    /// Gamma 0.40 (was 0.55) compresses harder so quiet speech maps higher up
    /// the bar; 14% floor keeps the pill visually alive even at silence.
    /// We also apply a recording-active boost: when actively recording, push
    /// any non-zero input above the floor by a fixed offset so bars clearly
    /// rise off the baseline on whispers / quiet input. 4pt ceiling
    /// reservation prevents the tallest bar from kissing the capsule edge.
    private func barHeight(value: Float, maxHeight: CGFloat) -> CGFloat {
        let clamped = max(0.0, min(1.0, Double(value)))
        let amplified = pow(clamped, 0.40)
        // Floor lifted from 0.06 → 0.14 so silence still shows a clear baseline.
        // When recording AND any input is present, add a small visibility boost
        // (clamped to 0.85) so the bars unambiguously animate above floor.
        var normalized = max(0.14, amplified)
        if clamped > 0.005 {
            normalized = min(0.95, normalized + 0.08)
        }
        return CGFloat(normalized) * (maxHeight - 4)
    }
}

// NOTE: EnginePolishToast, EnginePolishDetailsPopover, EnginePolishDebugChip,
// EngineToastSnapshot, EngineFamily, prettyEngineLabel(), and formatLatency()
// all live in Views/EnginePolishToast.swift. The Xcode project already
// references that file path — keeping the polish-toast UI as a sibling file
// matches the project layout and avoids growing OverlayPanel.swift past
// 3000 lines.
