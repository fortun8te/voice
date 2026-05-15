// VOICE — Cursor Paster
// ============================================================
// Pastes transcribed text at the current cursor position,
// Superwhisper-style. Works in any app that supports Cmd+V.
//
// UNDO GUARANTEE
//   After VOICE pastes, the user can hit Cmd+Z (or the target app's
//   undo equivalent) to remove the pasted text in one step.
//
//   How this works:
//     * The paste is delivered as a real Cmd+V key event via
//       CGEvent.post(tap: .cghidEventTap), which target apps register
//       in their undo stack exactly the same as a user-typed Cmd+V.
//     * Only ONE paste method fires per call (CGEvent OR AppleScript,
//       never both) — so the target app sees a single undoable paste.
//     * Clipboard restoration (when enabled) is deferred 0.6s AFTER
//       the paste, so it cannot race with the target app reading the
//       clipboard. The restore only mutates clipboard contents — it
//       does NOT affect the target app's internal undo stack, which
//       was recorded the moment Cmd+V was delivered.
//     * The AppleScript fallback uses `keystroke "v" using command down`
//       which is also a real synthesized keystroke → also undoable.
//
//   If you change paste mechanics, preserve these invariants or the
//   single-press undo will silently break.
//
// Flow:
//   1. Read cursor context (up to 3 chars before insertion point)
//   2. Adjust formatted text for context (space, case, trailing period)
//   3. Save current clipboard contents
//   4. Write adjusted text to clipboard
//   5. Simulate Cmd+V via CGEvent (if Accessibility granted)
//      OR AppleScript / System Events (if not)
//   6. Restore original clipboard after a delay
//
// Insertion context rules (Wispr Flow / SuperWhisper approach):
//   fresh / startOfLine  → no leading space, keep capitalization
//   afterTerminal (.!?)  → add space, keep capitalization, keep period
//   midSentence          → add space, lowercase first word (not "I"),
//                          strip formatter's trailing period
//   Messaging apps       → strip trailing period in all contexts
//   Code editors         → strip trailing period, lowercase first char after .!?
//                          (matches `foo.bar` natural code patterns)
//
// WHY NOT changeCount:
//   NSPasteboard.changeCount only increments on WRITES — it does NOT
//   increment when an app READS the clipboard to paste. The old code
//   misread it as a "was the paste received" signal → AppleScript always
//   fired on top of CGEvent → double paste in Terminal, Chrome, VS Code,
//   Slack, and every Electron app.
//
// Requires Accessibility permission (System Settings → Privacy
// → Accessibility) for the CGEvent path. Falls back to AppleScript
// (System Events → Automation permission) automatically.
// ============================================================

import Foundation
import AppKit
import Carbon

class CursorPaster {
    // TWEAK: Delay before simulating paste (seconds).
    // 0.2s covers Electron apps (VS Code, Slack, Discord, Notion) that need
    // slightly longer to regain focus after the hotkey releases.
    // Kept as a documented fallback; live value comes from currentPrePasteDelay().
    private let prePasteDelay: TimeInterval = 0.2

    // Bundle-ID substrings for apps that genuinely need ~200ms before paste.
    // Mostly Electron / Chromium-based shells whose focus restoration after a
    // global hotkey release is sluggish. Everyone else gets ~80ms.
    private static let slowPasteAppHints: [String] = [
        "slack", "discord", "notion", "vscode", "code", "figma", "obsidian",
        "linear", "chrome", "safari", "firefox", "arc", "electron",
        "whatsapp", "telegram", "teams", "cursor", "atom", "spotify"
    ]

    // RAPID-FIRE CACHE: When the user rapidly toggles the hotkey, we cache
    // the last paste's ending context to avoid re-reading the field (which
    // would see our own text and misinterpret it as user input). Cache expires
    // after 1 second of inactivity — long enough for natural rapid presses
    // but short enough to reset between intentional pauses.
    private var lastPasteEndingContext: InsertionContext? = nil
    private var lastPasteTime: Date? = nil
    private let rapidFireCacheTTL: TimeInterval = 1.0

    /// Per-app paste delay. Most native apps regain focus in <50ms, so 0.08s
    /// is more than enough. Electron/Chromium apps need the full 0.20s.
    /// Falls back to 0.20s when the frontmost app can't be identified.
    private func currentPrePasteDelay() -> TimeInterval {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else {
            return 0.20  // unknown: be safe
        }
        if Self.slowPasteAppHints.contains(where: { id.contains($0) }) { return 0.20 }
        return 0.08
    }

    // TWEAK: Delay before restoring original clipboard (seconds).
    private let clipboardRestoreDelay: TimeInterval = 0.6

    // TWEAK: Whether to restore the original clipboard after paste.
    private let shouldRestoreClipboard: Bool = false

    // TWEAK: Maximum clipboard content size to save/restore (bytes).
    private let maxClipboardSaveSize: Int = 50_000_000 // 50MB

    // Cache for AXIsProcessTrusted() — re-checked at most every 10s to avoid
    // OS daemon round-trips on every paste while preventing stale reads.
    private var cachedTrust: Bool? = nil
    private var trustCheckedAt: Date? = nil

    // MARK: - Insertion context

    private enum InsertionContext {
        case fresh             // empty field or cursor at position 0
        case startOfLine       // preceding char is newline
        case afterTerminal     // preceding text ends with .!? (no trailing whitespace)
        case afterTerminalWS   // preceding text is .!? then whitespace — don't add space
        case afterWhitespace   // preceding ends in whitespace mid-sentence — don't add space
        case midSentence       // after letter/digit/comma — adds space, lowercases
    }

    // MARK: - Public API

    /// Paste the given text at the current cursor position in any app.
    /// - Parameter restoreClipboard: If true, restores the original clipboard contents after paste.
    func pasteAtCursor(_ text: String, restoreClipboard: Bool = false) {
        guard !text.isEmpty else { return }

        // SECURITY: never paste into a password field. macOS exposes the
        // subrole `AXSecureTextField` on focused secure inputs (1Password,
        // Keychain, login forms, sudo prompts). If we'd be pasting into one,
        // ABORT — write to clipboard only and toast the user. This MUST run
        // before we touch the system pasteboard so we don't poison it on
        // accident (we still write the polished text below so the user can
        // Cmd+V manually if they confirm they actually want it there).
        if isFocusedElementSecure() {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            print("[VOICE] ⚠️ refusing to paste into AXSecureTextField — text copied to clipboard")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Won't paste into password field — text copied to clipboard."]
            )
            return
        }

        // Snapshot the target before paste so we can verify it stayed put.
        // If focus moves between snapshot and paste delivery (target app
        // lost focus, user clicked elsewhere, modal opened) the CGEvent
        // lands in the wrong window. We detect that after-the-fact and
        // surface a toast so the user knows their text is on the clipboard.
        let targetSnapshot = currentPasteTargetSnapshot()

        // Check if this is a rapid-fire paste (within 1 second of the last paste).
        // If so, use the cached context from the previous paste to avoid re-reading
        // the field, which would see our own text and misinterpret formatting.
        let now = Date()
        let isRapidFire = if let lastTime = lastPasteTime {
            now.timeIntervalSince(lastTime) < rapidFireCacheTTL
        } else {
            false
        }

        // Determine insertion context: use cache if rapid-fire, otherwise re-read field.
        let context: InsertionContext
        if isRapidFire, let cached = lastPasteEndingContext {
            // Rapid re-fire: use cached context from the last paste.
            // This avoids re-reading the field, which would see our own text and
            // misinterpret formatting. The cached context represents what the field
            // will look like after the last paste completes.
            context = cached
        } else {
            // Normal paste: read actual field state.
            let preceding = contextStringBeforeCursor(length: 3)
            context = determineContext(preceding)
        }

        let (adjustedText, prependSpace) = adjustForContext(text, context: context)

        // Decide whether the leading space goes into the clipboard payload or
        // is typed as a separate Space keystroke. Some apps (Notion, many
        // web text fields) strip leading whitespace from pasted content, so
        // even when we include " How are you?" on the clipboard the field
        // ends up showing "How are you?". Typing the space as a real key
        // event before Cmd+V bypasses that — the app sees a normal space
        // keypress followed by a paste.
        //
        // CGEvent path  → type the space, don't include it in the clipboard
        // AppleScript    → can't cleanly type a sibling space, prepend instead
        let willUseCGEvent = isAccessibilityTrusted()
        let needsLeadingSpace = prependSpace && !adjustedText.hasPrefix(" ") && !adjustedText.hasPrefix("\n")

        var pasteText = adjustedText
        if needsLeadingSpace && !willUseCGEvent {
            pasteText = " " + pasteText
        }

        let pasteboard = NSPasteboard.general
        let finalText = pasteText

        // Step 0: Update rapid-fire cache.
        // Cache the context that will exist AFTER this paste completes.
        // This lets the next rapid press (within 1s) know it's following our text.
        lastPasteTime = now
        // After our text is pasted, the field will end with whatever our text ends with.
        // For rapid-fire simplicity: if this paste produces a period, next paste is .afterTerminal.
        // If this paste has trailing space, next paste is .afterTerminalWS.
        // Otherwise, next paste is .afterWhitespace (mid-sentence).
        if adjustedText.hasSuffix(".") || adjustedText.hasSuffix("!") || adjustedText.hasSuffix("?") {
            lastPasteEndingContext = .afterTerminal
        } else if adjustedText.hasSuffix(" ") {
            lastPasteEndingContext = .afterTerminalWS
        } else {
            lastPasteEndingContext = .afterWhitespace
        }

        // Step 1: Save current clipboard (optional).
        let savedContents = restoreClipboard ? saveClipboard(pasteboard) : nil

        // Step 2: Write our text to clipboard.
        pasteboard.clearContents()
        let ok = pasteboard.setString(finalText, forType: .string)
        print("[VOICE] Clipboard write ok=\(ok), len=\(finalText.count), context=\(context), msg=\(isMessagingApp()), code=\(isCodeEditor()), prependSpace=\(prependSpace), typeSpace=\(needsLeadingSpace && willUseCGEvent), rapidFire=\(isRapidFire), leading='\(finalText.prefix(4))'")
        if !ok {
            print("[VOICE] ⚠️ Clipboard write FAILED")
            return
        }

        // Step 3: Fire exactly ONE paste method.
        //
        // Use CGEvent if Accessibility is granted (fast, reliable, no popup).
        // Fall back to AppleScript / System Events (Automation permission,
        // no Accessibility needed, ~80ms slower).
        //
        // We NEVER fire both. The old changeCount check was supposed to detect
        // whether CGEvent worked, but changeCount only tracks pasteboard WRITES
        // not reads — it was always "no change" → AppleScript always fired →
        // double paste in most apps.
        let delay = currentPrePasteDelay()
        if willUseCGEvent {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if needsLeadingSpace { self?.simulateSpaceKey() }
                self?.simulatePaste()
                print("[VOICE] Pasted via CGEvent (Accessibility granted)")
                self?.verifyPasteLanded(expected: targetSnapshot)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                print("[VOICE] Pasted via AppleScript (no Accessibility)")
                self?.pasteViaSystemEvents()
                self?.verifyPasteLanded(expected: targetSnapshot)
            }
        }

        // Step 4: Restore clipboard.
        if let saved = savedContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + clipboardRestoreDelay) { [weak self] in
                self?.restoreClipboard(pasteboard, from: saved)
            }
        }
    }

    /// Paste with the TextFormatter applied first.
    func pasteFormatted(_ text: String, formatter: TextFormatter, restoreClipboard: Bool = false) {
        let formatted = formatter.format(text)
        pasteAtCursor(formatted, restoreClipboard: restoreClipboard)
    }

    /// Async paste with LLM polish pass. Falls through to sync paste if LLM is
    /// disabled or unavailable. Caller must be in an async context.
    func pasteFormattedWithLLM(_ text: String, formatter: TextFormatter, restoreClipboard: Bool = false) async {
        let formatted = formatter.format(text)
        let polished = await Qwen3Polisher.shared.polish(formatted, context: currentPolishContext())
        pasteAtCursor(polished, restoreClipboard: restoreClipboard)
    }

    /// Async paste of pre-formatted text with LLM polish pass. Returns the
    /// (possibly polished) string actually pasted so the caller can also
    /// stash it on the clipboard / recent list.
    @discardableResult
    func pasteWithLLM(_ formatted: String, restoreClipboard: Bool = false) async -> String {
        let polished = await Qwen3Polisher.shared.polish(formatted, context: currentPolishContext())
        pasteAtCursor(polished, restoreClipboard: restoreClipboard)
        return polished
    }

    // MARK: - Cursor context reading

    /// Read up to `length` characters immediately before the insertion point using
    /// the AX API. Uses the system-wide focused element for reliability across apps.
    /// Two-path: parameterized attr (O(1)) then full-value fallback for Electron/browsers.
    private func contextStringBeforeCursor(length: Int = 3) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef,
              CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }

        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange) else { return nil }

        // Position 0 = empty field or cursor at start.
        guard cfRange.location > 0 else { return "" }

        let readLen = min(length, cfRange.location)

        // Fast path: parameterized attribute reads exactly readLen chars (native controls).
        var beforeRange = CFRange(location: cfRange.location - readLen, length: readLen)
        if let rangeValue = AXValueCreate(.cfRange, &beforeRange) {
            var charRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &charRef
            ) == .success, let str = charRef as? String, !str.isEmpty {
                return str
            }
        }

        // Fallback: full value read (Electron, some other frameworks).
        guard cfRange.location <= 100_000 else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
              let fullText = textRef as? String,
              cfRange.location <= fullText.count else { return nil }

        let endIdx = fullText.index(fullText.startIndex, offsetBy: cfRange.location)
        let startIdx = fullText.index(endIdx, offsetBy: -readLen)
        return String(fullText[startIdx..<endIdx])
    }

    // MARK: - Context determination and text adjustment

    private func determineContext(_ preceding: String?) -> InsertionContext {
        // nil = AX unavailable. Treat as afterTerminalWS: keep capitalization
        // and keep terminal period, but DON'T inject a leading space. We
        // can't tell whether the field already has whitespace, and a
        // double-space is more visually offensive than a missed space the
        // user can type themselves.
        guard let preceding = preceding else { return .afterTerminalWS }
        guard !preceding.isEmpty else { return .fresh }

        let last = preceding.last!
        if last == "\n" { return .startOfLine }

        let terminalPunct: Set<Character> = [".", "!", "?", "\u{2026}"]
        if terminalPunct.contains(last) { return .afterTerminal }

        // Whitespace-aware: don't add a second space when the field already has one.
        // "hello " → afterWhitespace (no space added, lowercase first)
        // "hello. " → afterTerminalWS (no space added, keep capitalization)
        if last.isWhitespace {
            if preceding.count >= 2 {
                let secondLast = preceding[preceding.index(preceding.endIndex, offsetBy: -2)]
                if terminalPunct.contains(secondLast) { return .afterTerminalWS }
                // ".'  " — terminal + close-quote + space
                if (secondLast == "\"" || secondLast == "\u{201D}" || secondLast == ")") && preceding.count >= 3 {
                    let thirdLast = preceding[preceding.index(preceding.endIndex, offsetBy: -3)]
                    if terminalPunct.contains(thirdLast) { return .afterTerminalWS }
                }
            }
            return .afterWhitespace
        }

        // Close-quote directly after terminal: "Hello.\"|"
        if last == "\"" || last == "\u{201D}" || last == ")" || last == "]" {
            if preceding.count >= 2 {
                let secondLast = preceding[preceding.index(preceding.endIndex, offsetBy: -2)]
                if terminalPunct.contains(secondLast) { return .afterTerminal }
            }
        }

        return .midSentence
    }

    /// Adjust formatted text for insertion context.
    /// Returns (adjustedText, shouldPrependSpace).
    /// Smart spacing logic ensures rapid hotkey presses produce clean output without
    /// worrying about manual formatting between presses.
    private func adjustForContext(_ text: String, context: InsertionContext) -> (String, Bool) {
        let messaging = isMessagingApp()
        let codeEditor = isCodeEditor()
        let stripPeriod = messaging || codeEditor

        func stripTrailingPeriod(_ s: String) -> String {
            guard s.hasSuffix("."), !s.hasSuffix(".."), !s.hasSuffix("\u{2026}") else { return s }
            return String(s.dropLast())
        }

        func lowercaseFirstPreservingI(_ s: String) -> String {
            guard let first = s.first, first.isUppercase else { return s }
            let rest = s.dropFirst()
            let lower = first.lowercased()
            let isIPronoun = (lower == "i") &&
                (rest.isEmpty || rest.first == "'" || rest.first == " " || rest.first == ",")
            return isIPronoun ? s : lower + rest
        }

        // Smart spacing: never double-space on rapid presses.
        // If we're about to add a leading space but the text already starts with one,
        // strip the duplicate. Likewise, if the preceding context already has trailing
        // space, we don't need to add another.
        func stripLeadingWhitespace(_ s: String) -> String {
            var result = s
            while result.first?.isWhitespace == true {
                result = String(result.dropFirst())
            }
            return result
        }

        switch context {
        case .fresh, .startOfLine:
            return (stripPeriod ? stripTrailingPeriod(text) : text, false)

        case .afterTerminal:
            var t = stripPeriod ? stripTrailingPeriod(text) : text
            if codeEditor { t = lowercaseFirstPreservingI(t) }  // code: "foo.bar" pattern
            // Add space unless text already begins with whitespace (rapid-fire guard).
            let needsSpace = !(t.first?.isWhitespace ?? false)
            return (t, needsSpace)

        case .afterTerminalWS:
            // Field already has trailing whitespace — keep caps, no extra space.
            // Strip any leading space we might have added to avoid double-space on rapid press.
            var t = stripPeriod ? stripTrailingPeriod(text) : text
            if codeEditor { t = lowercaseFirstPreservingI(t) }
            t = stripLeadingWhitespace(t)  // guard: don't double-space
            return (t, false)

        case .afterWhitespace:
            // Mid-sentence but trailing whitespace exists — lowercase first, no extra space.
            var t = lowercaseFirstPreservingI(stripTrailingPeriod(text))
            t = stripLeadingWhitespace(t)  // guard: don't double-space
            return (t, false)

        case .midSentence:
            var t = lowercaseFirstPreservingI(stripTrailingPeriod(text))
            // Add space unless text already begins with whitespace (rapid-fire guard).
            let needsSpace = !(t.first?.isWhitespace ?? false)
            return (t, needsSpace)
        }
    }

    // MARK: - Messaging app detection

    // Bundle IDs and substrings for apps where trailing periods look wrong
    // (chat bubbles, comments). Keep the list narrow — false positives add
    // periods where they're wanted (email, document editors).
    private static let messagingBundleIds: Set<String> = [
        "com.apple.MobileSMS",          // Messages
        "com.tinyspeck.slackmacgap",    // Slack
        "com.discord.discord",           // Discord
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.whatsapp.desktop",
        "com.facebook.archon",          // Messenger
        "com.telegram.desktop",
        "ru.keepcoder.Telegram",
        "com.linear.app",
    ]

    private func isMessagingApp() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        if Self.messagingBundleIds.contains(id) { return true }
        return id.contains("slack") || id.contains("discord") ||
               id.contains("telegram") || id.contains("whatsapp") ||
               id.contains("teams")
    }

    // Bundle IDs for code editors / terminals where dictation usually goes into
    // comments or shells — neither wants auto-capitalized sentences ending with periods.
    private static let codeEditorBundleIds: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.todesktop.230313mzl4w4u92.cursor",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.AppCode",
        "com.jetbrains.goland",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.github.atom",
        "com.panic.Nova",
        "com.zedindustries.zed",
    ]

    /// Detect the polish context for the frontmost app so the LLM polisher
    /// can bias its cleanup (or skip entirely for code).
    func currentPolishContext() -> LLMPolisher.PolishContext {
        if isCodeEditor() { return .code }
        if isMessagingApp() { return .messaging }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() {
            if id.contains("mail") || id.contains("spark") || id.contains("outlook") {
                return .email
            }
        }
        return .default
    }

    private func isCodeEditor() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        if Self.codeEditorBundleIds.contains(id) { return true }
        let lower = id.lowercased()
        return lower.contains("xcode") || lower.contains("vscode") ||
               lower.contains("cursor") || lower.contains("terminal") ||
               lower.contains("iterm") || lower.contains("jetbrains") ||
               lower.contains("sublime") || lower.contains("zed")
    }

    // MARK: - Accessibility check (cached)

    private func isAccessibilityTrusted() -> Bool {
        let now = Date()
        if let cached = cachedTrust,
           let checkedAt = trustCheckedAt,
           now.timeIntervalSince(checkedAt) < 10 {
            return cached
        }
        let trusted = AXIsProcessTrusted()
        cachedTrust = trusted
        trustCheckedAt = now
        return trusted
    }

    // MARK: - Clipboard Save/Restore

    private struct ClipboardContents {
        var types: [NSPasteboard.PasteboardType: Data]
    }

    private func saveClipboard(_ pasteboard: NSPasteboard) -> ClipboardContents? {
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        let typesToSave: [NSPasteboard.PasteboardType] = [
            .string, .rtf, .html, .png, .tiff, .pdf, .fileURL,
        ]
        for type in typesToSave {
            if let data = pasteboard.data(forType: type), data.count <= maxClipboardSaveSize {
                types[type] = data
            }
        }
        guard !types.isEmpty else { return nil }
        return ClipboardContents(types: types)
    }

    private func restoreClipboard(_ pasteboard: NSPasteboard, from saved: ClipboardContents) {
        pasteboard.clearContents()
        for (type, data) in saved.types {
            pasteboard.setData(data, forType: type)
        }
    }

    // MARK: - Simulate Paste (Cmd+V)

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Synthesize a single Space keystroke. Used before simulatePaste() when
    /// the cursor context calls for a leading space. Typing the space as a
    /// real key event (rather than prepending it to the clipboard payload)
    /// avoids paste-time whitespace stripping in Notion, browser text
    /// fields, and other Electron/web surfaces. Virtual key 49 = Space.
    private func simulateSpaceKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// AppleScript paste — requires Automation permission for System Events.
    private func pasteViaSystemEvents() {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[VOICE] AppleScript paste error: \(error)")
            }
        }
    }

    // MARK: - Accessibility Permission

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Paste verification & secure-field detection

    /// Snapshot of (frontmost app bundle id, focused AX element identity)
    /// taken just before paste, so we can detect mid-flight focus loss.
    private struct PasteTargetSnapshot {
        let bundleId: String?
        let focusedElement: AXUIElement?
    }

    private func currentPasteTargetSnapshot() -> PasteTargetSnapshot {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var focused: AXUIElement? = nil
        if AXIsProcessTrusted() {
            let sys = AXUIElementCreateSystemWide()
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
               let r = ref {
                focused = (r as! AXUIElement)
            }
        }
        return PasteTargetSnapshot(bundleId: bundleId, focusedElement: focused)
    }

    /// After CGEvent / AppleScript paste fires, give the OS a tick to deliver
    /// the event, then check whether the frontmost app and focused element
    /// are still the snapshot we captured before the paste. If not, the
    /// paste either landed in the wrong place or didn't land at all — post
    /// a `voiceError` notification so the user knows the text is still on
    /// the clipboard.
    private func verifyPasteLanded(expected: PasteTargetSnapshot) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let nowBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if nowBundle != expected.bundleId {
                print("[VOICE] ⚠️ paste verify FAIL — frontmost changed \(expected.bundleId ?? "nil") → \(nowBundle ?? "nil")")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Couldn't paste — your text is on the clipboard (Cmd+V to paste manually)"]
                )
                return
            }
            // Compare focused element identity when AX is available.
            if AXIsProcessTrusted(), let before = expected.focusedElement {
                let sys = AXUIElementCreateSystemWide()
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
                   let r = ref {
                    let after = r as! AXUIElement
                    if !CFEqual(before, after) {
                        print("[VOICE] ⚠️ paste verify FAIL — focused element changed")
                        NotificationCenter.default.post(
                            name: .voiceError,
                            object: nil,
                            userInfo: ["message": "Couldn't paste — your text is on the clipboard (Cmd+V to paste manually)"]
                        )
                    }
                }
            }
        }
    }

    /// Returns true when the currently focused AX element is a secure text
    /// input (password field). Uses kAXSubroleAttribute — value
    /// `AXSecureTextField` is the standard macOS marker. When AX isn't
    /// trusted we conservatively return false (can't tell, don't block).
    private func isFocusedElementSecure() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let f = focusedRef else { return false }
        let element = f as! AXUIElement

        // Check subrole first — that's where AXSecureTextField appears.
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        // Some Electron / web apps don't set the subrole; fall through.
        return false
    }
}
