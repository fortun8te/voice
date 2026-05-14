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

    /// Token returned by `NSEvent.addGlobalMonitorForEvents` — must be passed
    /// to `NSEvent.removeMonitor(_:)` in deinit or it leaks the closure.
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?

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

    /// Three signal sources, each with a timestamp. Newest wins.
    private var lastMouseScreen: NSScreen?
    private var lastMouseSignalAt: TimeInterval = 0
    private var lastKeyWindowScreen: NSScreen?
    private var lastKeyWindowSignalAt: TimeInterval = 0
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
        case .idle, .recording, .transcribing:
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
        case .idle, .transcribing, .cancelled:
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

        // Mouse + key signals — light, just timestamp + screen.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.recordMouseSignal()
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            self?.recordKeySignal()
        }

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

    // MARK: - Signal recording

    private func recordMouseSignal() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        lastMouseScreen = screen
        lastMouseSignalAt = CACurrentMediaTime()
    }

    private func recordKeySignal() {
        // Treat keyboard activity as "user is here" — bump key-window signal.
        if let s = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen {
            lastKeyWindowScreen = s
            lastKeyWindowSignalAt = CACurrentMediaTime()
        }
    }

    private func seedActiveScreenSignals() {
        recordMouseSignal()
        if let s = NSScreen.main {
            lastKeyWindowScreen = s
            lastKeyWindowSignalAt = CACurrentMediaTime()
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

        // Build candidate list with (screen, age).
        var candidates: [(screen: NSScreen, age: TimeInterval)] = []
        if let s = lastMouseScreen { candidates.append((s, now - lastMouseSignalAt)) }
        if let s = lastKeyWindowScreen { candidates.append((s, now - lastKeyWindowSignalAt)) }
        if let s = lastAppActivationScreen { candidates.append((s, now - lastAppActivationAt)) }

        // Fresh-key-window also dynamically computed (covers app's window moves).
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
        let y: CGFloat
        if !dockHidden, let dockTop = dockTopEdge(on: screen) {
            y = dockTop + 4
        } else {
            y = screen.visibleFrame.minY + (dockHidden ? 0 : 4)
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
    fileprivate func displayLinkTick() {
        let target = computeTargetFrame()
        let cur = self.frame
        let dx = abs(target.minX - cur.minX)
        let dy = abs(target.minY - cur.minY)
        let dh = abs(target.height - cur.height)
        if dx < 0.5 && dy < 0.5 && dh < 0.5 { return }

        currentTargetFrame = target

        let intersectsAnyScreen = NSScreen.screens.contains { $0.frame.intersects(target) }
        guard intersectsAnyScreen else { return }

        // Height changes (live-partial text appearing/disappearing) use a
        // longer spring animation so the pill expansion reads as intentional.
        // Position-only changes use the fast 8ms dock-follow animation.
        let duration: TimeInterval = dh > 1 ? 0.20 : 0.008
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(target, display: true)
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
            // Throttle to ~30Hz to be polite — recording-state UI runs on
            // SwiftUI's own TimelineView, this is just the panel-frame chase.
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
        let hostingView = NSHostingView(
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
        let f = self.frame
        print("[VOICE] Pill positioned at x=\(Int(f.minX)) y=\(Int(f.minY)) on \(resolveActiveScreen().localizedName)")
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
        if let token = globalMouseMonitor { NSEvent.removeMonitor(token) }
        if let token = globalKeyMonitor { NSEvent.removeMonitor(token) }
        globalMouseMonitor = nil
        globalKeyMonitor = nil
        UserDefaults.standard.removeObserver(self, forKeyPath: "hidePillFromScreenCapture")
    }
}

// MARK: - Phase

enum PillPhase: Equatable {
    case idle
    case recording        // push-to-talk
    case locked           // 2x click mode
    case transcribing
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
    private var rawPhase: PillPhase {
        if state.isTranscribing { return .transcribing }
        if state.isLocked && state.isRecording { return .locked }
        if state.isRecording { return .recording }
        if state.showingCancelledToast { return .cancelled }
        return .idle
    }

    @State private var displayPhase: PillPhase = .idle
    @State private var lastLoggedPhase: PillPhase = .idle
    @State private var settlingTask: Task<Void, Never>?

    private let phaseSpring = Animation.spring(response: 0.22, dampingFraction: 0.88)

    var body: some View {
        ZStack(alignment: .bottom) {
            switch displayPhase {
            case .idle:
                IdlePill(onTap: { onTap?() })
                    .transition(growFromBottom)
            case .recording:
                RecordingPill(state: state)
                    .transition(growFromBottom)
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
        // Constrain hit-testing to the visible capsule. The 180x56 panel has
        // ~60pt of empty space around the actual pill; without this, that
        // padding still captures clicks when ignoresMouseEvents=false.
        .contentShape(Capsule())
        .animation(phaseSpring, value: displayPhase)
        .onAppear { applyPhase(rawPhase, immediate: true) }
        .onChange(of: rawPhase) { _, newPhase in applyPhase(newPhase, immediate: false) }
    }

    private func applyPhase(_ next: PillPhase, immediate: Bool) {
        settlingTask?.cancel()
        settlingTask = nil

        let commit: (PillPhase) -> Void = { newValue in
            if newValue != lastLoggedPhase {
                print("[VOICE] Pill phase: \(lastLoggedPhase) → \(newValue)")
                lastLoggedPhase = newValue
            }
            displayPhase = newValue
            onPhaseChange?(newValue)
        }

        if next == .idle && !immediate && displayPhase != .idle {
            settlingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                commit(.idle)
            }
        } else {
            commit(next)
        }
    }

    private var growFromBottom: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.82, anchor: .bottom)
                .combined(with: .opacity),
            removal: .scale(scale: 0.82, anchor: .bottom)
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

    private var glowRadius: CGFloat { min(glowLevel * 12, 9) }
    private var glowOpacity: Double { min(Double(glowLevel) * 0.40, 0.16) }

    var body: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(fillOpacity))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.36),
                                Color.white.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
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
        WaveformView(
            levels: state.audioLevels,
            audioPeak: audioPeak
        )
        .frame(width: 68, height: 16)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(GlassCapsule(fillOpacity: 0.85, glowLevel: 0))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
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
            // Live-partial preview — only when text is available.
            if !state.livePartialText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(state.livePartialText)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(
                                state.livePartialIsVolatile
                                    ? Color.white.opacity(0.55)
                                    : Color.white.opacity(1.0)
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

                // Thin separator
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 0.5)
            }

            // Controls row: X | waveform | ✓
            HStack(spacing: 6) {
                ActionButton(systemName: "xmark", hoverTint: Color.red.opacity(0.55), action: onCancel)

                WaveformView(
                    levels: state.audioLevels,
                    audioPeak: audioPeak
                )
                .frame(width: 56, height: 16)
                .padding(.horizontal, 3)

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

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isHovering ? hoverTint : Color.white.opacity(0.28))
                )
                .scaleEffect(isHovering ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isHovering)
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

// MARK: - Cancelled Toast

private struct CancelledToast: View {
    let shownAt: Date
    let onUndo: () -> Void
    @State private var undoHovering = false
    private let totalDuration: TimeInterval = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(shownAt)
            let remaining = max(0, 1.0 - elapsed / totalDuration)

            HStack(spacing: 8) {
                Text("Cancelled")
                    .font(.sans(10.5, weight: .medium))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.white.opacity(0.80))

                Button(action: onUndo) {
                    Text("Undo")
                        .font(.sans(10, weight: .semibold))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(undoHovering ? 0.22 : 0.14))
                        )
                }
                .buttonStyle(.plain)
                .onHover { undoHovering = $0 }
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: undoHovering)
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

// MARK: - Waveform

/// 5-bar mirror-symmetric meter. Bars 0/4 share band 0, bars 1/3 share band 1,
/// bar 2 is the peak band — gives a centered audio-meter look that reads as
/// "I'm hearing you" without the chaotic shimmer of the older 11-bar wave.
struct WaveformView: View {
    let levels: [Float]
    let audioPeak: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9 + Double(audioPeak) * 0.1))
                    .frame(width: 3, height: max(3, barHeight(for: i)))
                    .animation(.spring(response: 0.14, dampingFraction: 0.65), value: level(for: i))
            }
        }
        .frame(width: 52, height: 22)
    }

    private func level(for index: Int) -> Float {
        // Mirror symmetric: bars 0/4 share band 0, bars 1/3 share band 1, bar 2 is band 2 (peak)
        guard !levels.isEmpty else { return 0 }
        let symmetricIndex = index <= 2 ? index : 4 - index
        let band = symmetricIndex
        let count = levels.count
        let start = (band * count) / 3
        let end = ((band + 1) * count) / 3
        guard end > start else { return 0 }
        let slice = levels[start..<end]
        return slice.reduce(0, +) / Float(slice.count)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let raw = CGFloat(level(for: index))
        // Soft-knee compander: pull quiet audio up so the bars feel
        // responsive even at conversational volume, but cap at the
        // 22px frame so they never clip.
        let boosted = pow(raw, 0.7) * 1.15
        let clipped = min(1.0, boosted)
        return 3 + clipped * 18
    }
}
