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
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?

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

    // Cached dock top edge — re-read at most every 3s (AX call is expensive at vsync rate).
    private var cachedDockTopEdge: CGFloat? = nil
    private var dockEdgeCachedAt: TimeInterval = 0
    private let dockEdgeCacheTTL: TimeInterval = 3.0

    /// Periodic re-assert of front-most order while recording. Other apps
    /// occasionally push panels back even at high window levels — a cheap
    /// 5s tick keeps the pill on top without burning cycles when idle.
    private var topmostReassertTimer: Timer?

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
        case .idle, .recording, .transcribing, .polishingSelection:
            ignoresMouseEvents = true
        case .locked, .cancelled:
            // .locked has X/✓ buttons; .cancelled has an Undo button.
            // Both need to capture clicks. .contentShape(Capsule()) on the
            // pill view keeps the surrounding panel padding click-through.
            ignoresMouseEvents = false
        }

        switch phase {
        case .recording, .locked:
            beginTopmostReassert()
        case .idle, .transcribing, .polishingSelection, .cancelled:
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
            self?.cachedDockTopEdge = nil  // force re-read after screen change
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
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let screen = screenForFrontmostWindow(of: app) {
            lastAppActivationScreen = screen
            lastAppActivationAt = now
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
    private func currentMouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
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
            let primary = NSScreen.screens.first?.frame ?? .zero
            let nsY = primary.maxY - (y + height)
            let center = CGPoint(x: x + width / 2, y: nsY + height / 2)
            if let s = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
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

        // Drop nils / disconnected screens.
        let attached = NSScreen.screens
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

        let chosen = freshest ?? NSScreen.main ?? NSScreen.screens.first!
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

        let x = screen.frame.midX - panelWidth / 2

        if debugEnabled, lastDockHiddenLogged != dockHidden {
            print("[VOICE/dbg] screen=\(screen.localizedName) dockHidden=\(dockHidden) y=\(Int(y))")
            lastDockHiddenLogged = dockHidden
        }

        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    /// Immediate reposition — used for notifications. Bypasses display-link
    /// throttle and animates if requested.
    private func repositionImmediate(animated: Bool) {
        let target = computeTargetFrame()

        let intersectsAnyScreen = NSScreen.screens.contains { $0.frame.intersects(target) }
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
        let target = computeTargetFrame()
        let cur = self.frame
        let dx = abs(target.minX - cur.minX)
        let dy = abs(target.minY - cur.minY)
        let dh = abs(target.height - cur.height)
        if dx < 0.5 && dy < 0.5 && dh < 0.5 { return }

        let intersectsAnyScreen = NSScreen.screens.contains { $0.frame.intersects(target) }
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
                onCancel: { [weak self] in self?.onCancel?() },
                onConfirm: { [weak self] in self?.onConfirm?() },
                onUndoCancel: { [weak self] in self?.onUndoCancel?() },
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
    private let visibleBandWidth: CGFloat = 170

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
        let bandX = (bounds.width - visibleBandWidth) / 2
        let bandY: CGFloat = (bounds.height > visibleBandHeight + 6) ? 4 : 0
        let bandHeight = max(visibleBandHeight, bounds.height - bandY)
        let band = NSRect(x: bandX, y: bandY, width: visibleBandWidth, height: bandHeight)
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
    case cancelled        // toast
}

// MARK: - Pill View

struct OverlayPillView: View {
    @Bindable var state: RecordingState

    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onUndoCancel: (() -> Void)?
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
        if state.showingCancelledToast { return .cancelled }
        return .idle
    }

    @State private var displayPhase: PillPhase = .idle
    @State private var lastLoggedPhase: PillPhase = .idle
    @State private var settlingTask: Task<Void, Never>?

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
    private let phaseSpring          = Animation.spring(response: 0.22, dampingFraction: 0.88)
    private let recordingToLocked    = Animation.spring(response: 0.32, dampingFraction: 0.78)
    private let recordingToTranscribe = Animation.spring(response: 0.28, dampingFraction: 0.82)
    private let transcribeToIdle     = Animation.easeOut(duration: 0.25)
    private let cancelledToIdle      = Animation.easeOut(duration: 0.35)

    var body: some View {
        ZStack(alignment: .bottom) {
            switch displayPhase {
            case .idle:
                IdlePill(onTap: { onTap?() })
                    .transition(growFromBottom)
            case .recording:
                // NO transition into recording — the user pressed the hotkey
                // and needs visual confirmation on the SAME frame. Any spring
                // or fade here reads as "the app is slow". Removal still uses
                // the standard transition (handled by the outgoing phase).
                // BUGFIX: removed `.id(displayPhase)` — it forced SwiftUI to
                // tear down and rebuild the RecordingPill on every parent
                // re-render that touched displayPhase, which manifested as
                // the occasional gradient "glitch" (AuroraBackground inside
                // GlassCapsule remounted, re-running its onAppear and
                // re-seeding the TimelineView phase). The switch case itself
                // already provides correct identity per phase.
                RecordingPill(state: state)
                    .transition(.identity)
            case .locked:
                LockedPill(
                    state: state,
                    onCancel: { onCancel?() },
                    onConfirm: { onConfirm?() }
                )
                .transition(growFromBottom)
            case .transcribing:
                TranscribingPill()
                    .transition(growFromBottom)
            case .polishingSelection:
                PolishingSelectionPill()
                    .transition(growFromBottom)
            case .cancelled:
                CancelledToast(
                    shownAt: state.cancelToastShownAt ?? Date(),
                    onUndo: { onUndoCancel?() }
                )
                .transition(crossFade)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
        // Subtle scale: idle state contracts slightly (0.96) so transitions
        // INTO active states feel like a physical "pop". The scale animates
        // implicitly as part of the explicit `withAnimation` block driving
        // `displayPhase` in applyPhase — no `.animation(_:value:)` modifier
        // here, which would otherwise compete with that block and produce
        // double-animation jank on every phase commit.
        .scaleEffect(displayPhase == .idle ? 0.96 : 1.0)
        // Constrain hit-testing to the visible capsule. The 180x56 panel has
        // ~60pt of empty space around the actual pill; without this, that
        // padding still captures clicks when ignoresMouseEvents=false.
        .contentShape(Capsule())
        // No static `.animation` modifier here — each phase commit drives its
        // own withAnimation block so we can choose snap vs. spring per direction.
        .onAppear { applyPhase(rawPhase, immediate: true) }
        .onChange(of: rawPhase) { _, newPhase in applyPhase(newPhase, immediate: false) }
        .onChange(of: displayPhase) { old, new in
            // Debug-gated. The pill ticks through many phase transitions per
            // recording and the firehose drowns out real signal at runtime.
            if UserDefaults.standard.bool(forKey: "voicePillDebug") {
                print("[VOICE-PILL/dbg] \(old) -> \(new) @ \(Date().timeIntervalSinceReferenceDate)")
            }
        }
    }

    private func applyPhase(_ next: PillPhase, immediate: Bool) {
        settlingTask?.cancel()
        settlingTask = nil

        let commit: (PillPhase, Animation?) -> Void = { newValue, anim in
            if newValue != lastLoggedPhase {
                if UserDefaults.standard.bool(forKey: "voicePillDebug") {
                    print("[VOICE/dbg] Pill phase: \(lastLoggedPhase) -> \(newValue)")
                }
                lastLoggedPhase = newValue
            }
            if let anim {
                withAnimation(anim) {
                    displayPhase = newValue
                }
            } else {
                displayPhase = newValue
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
            case .cancelled:    idleAnim = cancelledToIdle
            case .transcribing: idleAnim = transcribeToIdle
            default:            idleAnim = phaseSpring
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

    private var growFromBottom: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.88, anchor: .bottom)
                .combined(with: .opacity),
            removal: .scale(scale: 1.06, anchor: .bottom)
                .combined(with: .opacity)
        )
    }

    private var crossFade: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .opacity
        )
    }
}

// MARK: - Shared glass surface

private struct GlassCapsule: View {
    var fillOpacity: Double = 0.55
    var glowLevel: CGFloat = 0

    @AppStorage("pillSkin") private var pillSkin: String = "default"

    private var glowRadius: CGFloat { min(glowLevel * 12, 9) }
    private var glowOpacity: Double { min(Double(glowLevel) * 0.40, 0.16) }

    var body: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Group {
                    if pillSkin == "niche" {
                        // The aurora mesh control points oscillate (amp 0.14 mid,
                        // 0.06 edge) AND the corner points sit at -0.05 / 1.05.
                        // Combined, the leftmost middle control point can swing
                        // to ~-0.16 — outside the unit square. Add a generous
                        // overscan via NEGATIVE padding so the gradient is laid
                        // out in a frame ~8pt larger on each side than the
                        // visible capsule. Then scale 1.35× (keeps the
                        // off-center indigo blob inside the thin visible band)
                        // and clip AFTER both — so the visible capsule is the
                        // only mask, never the gradient's own frame. Order is
                        // critical: padding (grow) → scaleEffect → clipShape.
                        AuroraBackground()
                            .padding(-8)
                            .scaleEffect(1.35)
                            .clipShape(Capsule(style: .continuous))
                            .allowsHitTesting(false)
                    } else {
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(fillOpacity))
                    }
                }
            )
            .overlay(
                // Niche-only top sheen: subtle white highlight band across
                // the top of the capsule sells the "glass over color" read.
                Group {
                    if pillSkin == "niche" {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.22), location: 0.0),
                                        .init(color: Color.white.opacity(0.0),  location: 0.45)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: pillSkin == "niche"
                                ? [Color.white.opacity(0.55), Color.white.opacity(0.12)]
                                : [Color.white.opacity(0.36), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: pillSkin == "niche" ? 0.75 : 0.6
                    )
            )
            .shadow(color: .white.opacity(glowOpacity), radius: glowRadius, y: 0)
            .animation(.easeOut(duration: 0.06), value: glowRadius)
            .animation(.easeOut(duration: 0.06), value: glowOpacity)
    }
}

// MARK: - Idle pill

private struct IdlePill: View {
    let onTap: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false
    @State private var faded = false

    var body: some View {
        let dotSize: CGFloat = isHovering ? 18 : (faded ? 10 : 14)
        let bgOpacity: Double = isHovering ? 0.78 : (faded ? 0.32 : 0.62)
        let strokeOpacity: Double = isHovering ? 0.55 : (faded ? 0.20 : 0.35)
        let shadowOpacity: Double = isHovering ? 0.22 : (faded ? 0.12 : 0.22)
        Color.clear
            .frame(width: 40, height: 22)
            .overlay(
                Circle()
                    .fill(Color.black.opacity(bgOpacity))
                    .overlay(
                        Circle()
                            .strokeBorder(
                                Color.white.opacity(strokeOpacity),
                                lineWidth: 0.8
                            )
                    )
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isPressed ? 0.82 : 1.0)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 4, x: 0, y: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in
                        isPressed = false
                        onTap()
                    }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .animation(.spring(response: 0.16, dampingFraction: 0.82), value: isHovering)
            .animation(.spring(response: 0.14, dampingFraction: 0.78), value: isPressed)
            .animation(.easeInOut(duration: 0.6), value: faded)
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !isHovering { faded = true }
                }
            }
            .onChange(of: isHovering) { _, hovering in
                if hovering {
                    faded = false
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if !isHovering { faded = true }
                    }
                }
            }
    }
}

// MARK: - Recording (push-to-talk)

private struct RecordingPill: View {
    @Bindable var state: RecordingState

    private var audioPeak: Float {
        state.audioLevels.max() ?? 0
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
        .background(GlassCapsule(fillOpacity: 0.85, glowLevel: CGFloat(audioPeak)))
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
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
        .background(GlassCapsule(fillOpacity: 0.85))
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
                Circle().fill(
                    isPressed
                        ? hoverTint.opacity(0.85)
                        : (isHovering ? hoverTint : Color.white.opacity(0.28))
                )
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
        Color.clear
            .frame(width: 40, height: 22)
            .overlay(
                SweepingRing()
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 1)
            )
    }
}

/// Gentle dot pulse — replaces the previous fast sweeping arc.
/// The dot just breathes (scale 0.92 ↔ 1.08, opacity 0.55 ↔ 0.85) over 1.6s.
/// Reads as "thinking" without the chaotic spinning ring vibe.
private struct SweepingRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            // 1.6s cycle, smooth sine
            let t = (phase.truncatingRemainder(dividingBy: 1.6)) / 1.6
            let s = sin(t * 2 * .pi)
            let scale = 1.0 + 0.08 * s        // 0.92 … 1.08
            let opacity = 0.70 + 0.18 * s     // 0.52 … 0.88
            Circle()
                .stroke(Color.white.opacity(opacity), lineWidth: 1.5)
                .scaleEffect(scale)
        }
    }
}

// MARK: - Polishing Selection

/// Shown during the Opt+1 flow while a selected text region is being polished.
/// Click-through (user cannot interact) — same visual weight as TranscribingPill
/// but with a sparkles glyph + label to signal a distinct AI-rewrite action.
private struct PolishingSelectionPill: View {
    var body: some View {
        HStack(spacing: 6) {
            SparklesBreath()
                .frame(width: 16, height: 16)
            Text("Polishing\u{2026}")
                .font(.sans(13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(GlassCapsule(fillOpacity: 0.80))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}

/// Sparkles icon that breathes in sync with the SweepingRing pulse pattern.
private struct SparklesBreath: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
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
    private let totalDuration: TimeInterval = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
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
            .background(
                GlassCapsule(fillOpacity: 0.85)
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
            )
            .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 5)
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
                    if pillSkin == "niche" {
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
