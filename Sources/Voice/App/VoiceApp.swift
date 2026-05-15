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

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
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
}

/// Persisted history of the last dictations. Capped at 5.
/// Lives here (not in a service) because it's UI-shaped state for the menu.
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
    static func add(raw: String?, polished: String) {
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
            RecentDictation(text: trimmed, timestamp: Date(), rawText: rawForStorage),
            at: 0
        )
        if items.count > limit { items = Array(items.prefix(limit)) }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
    private var pendingFinishTask: Task<Void, Never>?
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

    // Permission-prompt throttling. macOS shows the system "grant access"
    // dialog every time AXIsProcessTrustedWithOptions(prompt: true) is called
    // — pressing the hotkey 40 times yields 40 dialogs. Track per-session so
    // we ask exactly once, then route the user to System Settings.
    private var didShowAXPrompt = false
    private var didShowMicPrompt = false
    private var permissionWatcherTimer: Timer?
    private var lastObservedAXTrusted: Bool = AXIsProcessTrusted()

    // Polished-app extras
    private var errorToastWindow: NSPanel?
    private var errorDismissTask: Task<Void, Never>?
    private var onboardingWindow: NSPanel?
    private var errorObserver: NSObjectProtocol?

    // (Previously used to swallow a deactivate after lock-exit, but the new
    // state machine doesn't fire deactivate on lock exit, so the flag was a
    // footgun — once set on lock exit, it stayed true and silently killed
    // every subsequent PTT release. Removed.)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show in the Dock and Cmd-Tab switcher.
        NSApp.setActivationPolicy(.regular)

        // Set the app icon explicitly — used in About panel, alerts, etc.
        // (no dock icon to paint in accessory mode, but About / alerts still
        // use applicationIconImage)
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
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

        // First-run onboarding — non-blocking. The pill works without it.
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }

        // Update check fires once at launch, debounced internally to 24h.
        UpdateChecker.checkInBackground { [weak self] info in
            guard let self else { return }
            // Wiring TODO: replace with a real toast once we have a shipped
            // download URL. For now, surface via the standard error/info toast.
            self.showToast("VOICE \(info.version) is available.")
        }

        Telemetry.log("app.launched", properties: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ])
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
        permissionWatcherTimer?.invalidate()
        permissionWatcherTimer = nil
        if let observer = errorObserver {
            NotificationCenter.default.removeObserver(observer)
            errorObserver = nil
        }
        // Best-effort: if a recording is still in flight, stop it so the
        // file isn't left half-flushed. We don't await — terminate doesn't
        // give us time, but stopRecording's writer will close synchronously.
        if recordingState.isRecording || recordingState.isLocked {
            Task { @MainActor in _ = await coordinator.stopRecording() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Confirm before quitting if a recording is active. Users have
        // lost dictations to accidental cmd-Q exactly once and that's enough.
        if recordingState.isRecording || recordingState.isLocked {
            let alert = NSAlert()
            alert.messageText = "Recording in progress"
            alert.informativeText = "Quit anyway? Your in-progress dictation will be discarded."
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
        menu.delegate = self  // rebuild Recent submenu lazily on open

        let openItem = NSMenuItem(title: "Open VOICE…", action: #selector(openBigMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentItem.submenu = buildRecentMenu()
        recentItem.tag = MenuTag.recent.rawValue
        menu.addItem(recentItem)

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
    private enum MenuTag: Int {
        case recent = 1001
        case launchAtLogin = 1002
    }

    /// Build (or rebuild) the "Recent Dictations" submenu from UserDefaults.
    private func buildRecentMenu() -> NSMenu {
        let sub = NSMenu()
        let recents = RecentDictations.all()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No recent dictations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            return sub
        }
        for (idx, item) in recents.enumerated() {
            let preview = String(item.text.prefix(60))
                .replacingOccurrences(of: "\n", with: " ")
            let title = preview.count < item.text.count ? preview + "…" : preview
            // Parent item: clicking it directly still copies the polished text.
            let mi = NSMenuItem(title: title, action: #selector(copyRecentDictation(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = idx
            mi.toolTip = item.text
            // Attach a submenu with more granular copy actions.
            mi.submenu = buildRecentItemSubmenu(for: item, index: idx)
            sub.addItem(mi)
        }
        return sub
    }

    /// Build the per-item submenu: Copy (polished), optionally Copy Raw, separator, Copy Timestamp.
    private func buildRecentItemSubmenu(for item: RecentDictation, index idx: Int) -> NSMenu {
        let sub = NSMenu()

        // "Copy" — copies the final polished text (existing behaviour).
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyRecentDictation(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.tag = idx
        sub.addItem(copyItem)

        // "Copy Raw" — only shown when a pre-polish version was captured.
        if item.hasRawText {
            let rawItem = NSMenuItem(title: "Copy Raw", action: #selector(copyRecentRaw(_:)), keyEquivalent: "")
            rawItem.target = self
            rawItem.tag = idx
            sub.addItem(rawItem)
        }

        sub.addItem(NSMenuItem.separator())

        // "Copy Timestamp" — ISO-8601-ish readable form.
        let tsItem = NSMenuItem(title: "Copy Timestamp", action: #selector(copyRecentTimestamp(_:)), keyEquivalent: "")
        tsItem.target = self
        tsItem.tag = idx
        sub.addItem(tsItem)

        return sub
    }

    @objc private func copyRecentDictation(_ sender: NSMenuItem) {
        let recents = RecentDictations.all()
        guard sender.tag >= 0, sender.tag < recents.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recents[sender.tag].text, forType: .string)
        Telemetry.log("recent.copied")
    }

    @objc private func copyRecentRaw(_ sender: NSMenuItem) {
        let recents = RecentDictations.all()
        guard sender.tag >= 0, sender.tag < recents.count else { return }
        let item = recents[sender.tag]
        guard let raw = item.rawText, !raw.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(raw, forType: .string)
        Telemetry.log("recent.copied_raw")
    }

    @objc private func copyRecentTimestamp(_ sender: NSMenuItem) {
        let recents = RecentDictations.all()
        guard sender.tag >= 0, sender.tag < recents.count else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let ts = formatter.string(from: recents[sender.tag].timestamp)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ts, forType: .string)
        Telemetry.log("recent.copied_timestamp")
    }

    @objc private func toggleLaunchAtLogin() {
        let next = !LaunchAtLoginService.isEnabled
        let ok = LaunchAtLoginService.setEnabled(next)
        if !ok {
            showToast("Couldn't change Launch at Login.")
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
            lines.append("  - \(r.text.count) chars, \(age)s ago: \(r.text.prefix(40))…")
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
    @objc private func openBigMenu() {
        if let win = bigMenuWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = BigMenuWindow(recordingState: recordingState)
        let host = NSHostingController(rootView: view)
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        win.title = "VOICE"
        win.contentViewController = host
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self  // listen for windowWillClose
        bigMenuWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil as Any?)
    }
}

// MARK: - NSMenuDelegate (refresh dynamic items on open)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            switch item.tag {
            case MenuTag.recent.rawValue:
                item.submenu = buildRecentMenu()
            case MenuTag.launchAtLogin.rawValue:
                item.state = LaunchAtLoginService.isEnabled ? .on : .off
            default:
                break
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
        NotificationCenter.default.addObserver(
            forName: .voiceOpenBigMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            self?.openBigMenu()
        }

        // (The Meetings tab used to post cancel/commit notifications observed
        // here. That tab was removed in favor of a future browser-extension
        // sourced meetings view — observers gone too.)
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
                let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
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

    /// Capture the frontmost app at the moment dictation begins, so we can
    /// re-activate it before paste. Skips capturing if VOICE itself happens
    /// to be frontmost (the pill, BigMenu, or Settings) — in that case the
    /// target is whatever was previous; leaving `targetAppBundleID` nil
    /// just means paste goes wherever focus lands naturally.
    fileprivate func captureTargetApp() {
        let ownID = Bundle.main.bundleIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else {
            targetAppBundleID = nil
            return
        }
        if let id = front.bundleIdentifier, id != ownID {
            targetAppBundleID = id
        }
        // else: VOICE was frontmost — keep whatever `targetAppBundleID` we
        // captured previously (might still be valid from the last session)
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
        coordinator.audioCapture.onSilenceTimeout = { [weak self] in
            guard let self, self.recordingState.isLocked else { return }
            DispatchQueue.main.async { self.finishRecording() }
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
            SoundEffects.playStart()
            coordinator.startRecording()
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
        exitLockMode()
        Task { @MainActor in
            _ = await coordinator.stopRecording()
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
    /// Cancels any in-flight previous finishRecording so back-to-back recordings
    /// don't trample each other's transcripts.
    private func finishRecording() {
        let wasRecording = recordingState.isRecording
        let started = recordingStartedAt
        print("[VOICE-HK] finishRecording: wasRecording=\(wasRecording)  started=\(started?.description ?? "nil")")

        // === ATOMIC STATE TRANSITION: recording → transcribing ===
        // Flip transcribing ON before we await stopRecording() — the phase
        // computed property checks isTranscribing first so the pill stays
        // in the transcribing state and never lapses to .idle for a frame.
        if wasRecording {
            recordingState.isTranscribing = true
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
            Task { @MainActor in _ = await coordinator.stopRecording() }
            recordingState.isTranscribing = false
            recordingState.currentTranscript = []
            return
        }

        // Cancel any prior in-flight finishRecording before starting the new one.
        pendingFinishTask?.cancel()

        pendingFinishTask = Task { @MainActor in
            // GUARANTEED CLEAR: no matter how the task ends — empty
            // transcript, error, cancellation, hung Ollama — isTranscribing
            // resets to false. The pill never gets stuck on the loading state.
            defer {
                recordingState.isTranscribing = false
                // Ensure live partials are always cleaned up regardless of
                // which code path triggered finishRecording (silence timeout,
                // hotkey, or confirm button — all paths end here).
                coordinator.stopLivePartials()
            }

            // Drain the streaming engine. Race against a hard 25s ceiling
            // as belt-and-suspenders against any pathological hang.
            let segments: [TranscriptSegment] = await withTaskGroup(
                of: [TranscriptSegment]?.self
            ) { group in
                group.addTask { await self.coordinator.stopRecording() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? []
            }
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
            let formatted = textFormatter.formatSegments(segmentsForFormat)
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

            // LLM polish runs only if enabled+available; otherwise returns
            // `formatted` unchanged after a near-zero check. 800ms hard
            // timeout inside the polisher guards paste latency (warm
            // Qwen3-0.6B-4bit on M2 typically completes in ~80–150ms).
            // Insertion-context hint lets the model bias for chat / email and
            // skip entirely in code editors.
            print("[VOICE] Starting polish... (formatted=\(formatted.count) chars)")
            let polishContext = cursorPaster.currentPolishContext()
            // Aggregate suspect words across segments — the polisher gets one
            // flat list. Combined dictionary (starter + user) is also surfaced
            // so the model knows e.g. "GitHub" not "get hub".
            let suspectWords = Array(
                Set(segments.compactMap { $0.suspectWords }.flatMap { $0 })
            )
            let userVocab = CombinedDictionary.terms()
            let polishStart = Date()
            // Short-utterance bypass: when RecordingCoordinator flagged the
            // current clip as 16-36KB ("ok"/"yeah"/"no" territory), skip the
            // LLM polish pass and keep the rule-based formatted text. Polish
            // on a single word costs ~100ms and sometimes mangles it.
            let skipPolish = recordingState.skipPolishForCurrent
            recordingState.skipPolishForCurrent = false  // consume the flag
            let finalText: String
            if skipPolish {
                print("[VOICE] Short clip — skipping LLM polish (rule-based only)")
                finalText = formatted
            } else {
                finalText = await Qwen3Polisher.shared.polish(
                    formatted,
                    context: polishContext,
                    suspectWords: suspectWords.isEmpty ? nil : suspectWords,
                    userVocabulary: userVocab.isEmpty ? nil : userVocab
                )
            }
            let polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
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
            if autoCopy {
                print("[VOICE] Copying to clipboard...")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(finalText, forType: .string)
                print("[VOICE] Copied to clipboard successfully")
            }

            if autoPaste {
                print("[VOICE] Auto-pasting (\(finalText.prefix(60))…)")
                print("[VOICE] targetAppBundleID=\(targetAppBundleID ?? "nil")")
                // Re-activate the user's target app first — handles the
                // common case where the user used System Settings (e.g.,
                // to grant Accessibility) and System Settings is still
                // technically frontmost when the dictation lands.
                print("[VOICE] Calling restoreTargetApp()...")
                restoreTargetApp()
                print("[VOICE] Target app restored, settling for 80ms...")
                // Tiny delay so the activation settles before the CGEvent.
                try? await Task.sleep(nanoseconds: 80_000_000)
                print("[VOICE] Calling pasteAtCursor...")
                print("[VOICE-FUNNEL] STAGE 4 PASTE text=\"\(finalText)\" chars=\(finalText.count) target=\(targetAppBundleID ?? "nil")")
                cursorPaster.pasteAtCursor(finalText, restoreClipboard: !autoCopy)
                print("[VOICE] pasteAtCursor completed")
            } else {
                print("[VOICE] Auto-paste disabled — transcript copied to clipboard only")
            }

            // Record for the Recent Dictations submenu. We persist BOTH the
            // pre-polish formatted text and the final polished text so the
            // BigMenu's History view can show a before/after compare. When
            // polish was a no-op (disabled / unavailable / didn't change
            // anything) the storage helper drops `raw` to avoid duplication.
            RecentDictations.add(raw: formatted, polished: finalText)
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
        guard coordinator.transcription.isReady else {
            print("[VOICE-HK] hotkeyDidActivate: model NOT ready state=\(recordingState.modelState) — aborting")
            switch recordingState.modelState {
            case .downloading(let p):
                showToast("Loading model… \(Int(p * 100))%")
            case .loading:
                showToast("Loading model…")
            case .error(let e):
                showToast("Model error — restart VOICE")
                print("[VOICE] hotkeyDidActivate: model error: \(e)")
            default:
                showToast("Model loading, please wait…")
            }
            return
        }

        // === Path 1: third tap exits lock + transcribes ===
        if recordingState.isLocked {
            print("[VOICE-HK] Path 1: Hotkey in lock → commit")
            exitLockMode()
            finishRecording()
            return
        }

        // === Path 2: re-press while transcribing — cancel + start fresh ===
        // Synchronous: cancel the prior finish task and call startRecording()
        // immediately. By the time this returns isRecording == true so any
        // subsequent keyUp/deactivate sees a live session. The prior task,
        // even mid-await, has already locally captured its own audio URL
        // (see RecordingCoordinator.stopRecording line ~167), so a new
        // startRecording() can safely overwrite currentAudioFileURL.
        if recordingState.isTranscribing {
            print("[VOICE-HK] Path 2: Hotkey during transcribing → cancel + start new")
            pendingFinishTask?.cancel()
            pendingFinishTask = nil
            recordingState.isTranscribing = false
            recordingState.currentTranscript = []
            if recordingState.showingCancelledToast { dismissCancelledToast() }
            recordingState.cancelledTranscript = []
            recordingStartedAt = hotkeyService.pressDownAt ?? Date()
            captureTargetApp()
            SoundEffects.playStart()
            coordinator.startRecording()
            print("[VOICE-HK] Path 2: post-startRecording isRecording=\(recordingState.isRecording)")
            return
        }

        // === Path 3: normal fresh press ===
        if recordingState.showingCancelledToast { dismissCancelledToast() }
        print("[VOICE-HK] Path 3: Hotkey down → start recording (fresh)")
        recordingStartedAt = hotkeyService.pressDownAt ?? Date()
        captureTargetApp()
        recordingState.cancelledTranscript = []
        SoundEffects.playStart()
        coordinator.startRecording()
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
        finishRecording()
    }

    /// Double-tap window expired without a second tap. The recording that
    /// started on the first keyDown has been running this whole time —
    /// discard it silently.
    func hotkeyDidQuickRelease() {
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
        Task { @MainActor in
            _ = await coordinator.stopRecording()
            recordingState.currentTranscript = []
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
    var isTranscribing = false            // post-recording processing
    var showingCancelledToast = false     // "Transcript cancelled" with Undo
    var cancelToastShownAt: Date?
    var cancelledTranscript: [TranscriptSegment] = []
    var elapsedSeconds: Int = 0
    var currentTranscript: [TranscriptSegment] = []
    var audioLevels: [Float] = Array(repeating: 0, count: 32)
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

    // Tick to nudge SwiftUI redraws when persisted recent-dictations list changes.
    var recentDictationsTick: Int = 0

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
