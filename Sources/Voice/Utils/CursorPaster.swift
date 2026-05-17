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
import ApplicationServices

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
    // after 30 seconds of inactivity — long enough for natural rapid presses
    // while still resetting after a genuine pause between dictation sessions.
    private var lastPasteEndingContext: InsertionContext? = nil
    private var lastPasteTime: Date? = nil
    private let rapidFireCacheTTL: TimeInterval = 30.0

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
    /// - Parameter preFormatted: When true, skip the AX read + spacing/casing adjustment
    ///   entirely. Use this when the upstream polisher (Qwen3) was given the field
    ///   context and already decided on the appropriate leading whitespace, case,
    ///   and punctuation. The text is pasted verbatim.
    func pasteAtCursor(_ text: String, restoreClipboard: Bool = false, preFormatted: Bool = false) {
        guard !text.isEmpty else { return }

        // Standardized paste-lifecycle logging. Grep for `[VOICE-PASTE]` to
        // reconstruct what happened on any given paste.
        let targetBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        print("[VOICE-PASTE] start: textLength=\(text.count) target=\(targetBundle) preFormatted=\(preFormatted)")

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
                userInfo: ["message": "Skipped password field. Text is on your clipboard."]
            )
            return
        }

        // Snapshot the target before paste so we can verify it stayed put.
        // If focus moves between snapshot and paste delivery (target app
        // lost focus, user clicked elsewhere, modal opened) the CGEvent
        // lands in the wrong window. We detect that after-the-fact and
        // surface a toast so the user knows their text is on the clipboard.
        let targetSnapshot = currentPasteTargetSnapshot()

        // Determine whether this is a rapid-fire press (our text is still landing).
        // Cache the result NOW before the dispatch so the next rapid press that
        // fires within the TTL window uses a timestamp relative to THIS call.
        let now = Date()
        let isRapidFire = lastPasteTime.map { now.timeIntervalSince($0) < rapidFireCacheTTL } ?? false
        let cachedContext: InsertionContext? = isRapidFire ? lastPasteEndingContext : nil
        lastPasteTime = now  // stamp before dispatch so rapid-fire TTL is relative to call time

        // Predict what the field will look like AFTER this paste based on the raw
        // text's trailing character, and stamp the cache synchronously. Without
        // this, a second hotkey press arriving during our 80–200ms pre-paste
        // delay reads stale cache (from two pastes ago, or nil) and falls back
        // to a doomed AX read — the back-to-back jam the cache was meant to fix.
        // The dispatch block below can refine this once it knows the adjusted text.
        let predictedTrailing = text.trimmingCharacters(in: .whitespacesAndNewlines).last
        if let last = predictedTrailing, last == "." || last == "!" || last == "?" {
            lastPasteEndingContext = .afterTerminal
        } else if predictedTrailing == nil {
            // Empty/whitespace-only text — preserve whatever the prior paste left.
        } else {
            lastPasteEndingContext = .midSentence
        }

        let willUseCGEvent = isAccessibilityTrusted()
        let delay = currentPrePasteDelay()
        let pasteboard = NSPasteboard.general
        let savedContents = restoreClipboard ? saveClipboard(pasteboard) : nil

        // All context-sensitive work (AX read, text adjustment, clipboard write, keystrokes)
        // happens inside the dispatch block. By the time this fires, the pre-paste delay has
        // elapsed and the target app's focus is settled — so AX reads return valid results.
        // Previously, the AX read ran immediately at call-time (before focus was restored),
        // returning nil and falling back to .afterTerminalWS (no space added). Moving it here
        // fixes back-to-back dictations that were jamming words together without spaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let pasteText: String
            let needsLeadingSpace: Bool

            if preFormatted {
                // Polisher saw the field context and already chose any leading
                // whitespace, casing, and trailing punctuation. Paste verbatim.
                pasteText = text
                // If the text starts with a space and we're on the CGEvent path,
                // type it as a keystroke instead of relying on the clipboard
                // (Chrome / Notion / web textareas strip leading whitespace).
                if text.hasPrefix(" ") && willUseCGEvent {
                    needsLeadingSpace = true
                } else {
                    needsLeadingSpace = false
                }
                // Refresh cache from the actual text the polisher produced.
                if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
                    self.lastPasteEndingContext = .afterTerminal
                } else if text.hasSuffix(" ") || text.hasSuffix("\n") {
                    self.lastPasteEndingContext = .afterWhitespace
                } else {
                    self.lastPasteEndingContext = .midSentence
                }
                print("[VOICE] Clipboard write (preFormatted) len=\(text.count), leading='\(text.prefix(4))'")
            } else {
                // Determine insertion context: use rapid-fire cache if available,
                // otherwise read the live field (focus is settled now).
                let context: InsertionContext
                if let cached = cachedContext {
                    context = cached
                } else {
                    let preceding = self.contextStringBeforeCursor(length: 3)
                    context = self.determineContext(preceding)
                }

                let (adjustedText, prependSpace) = self.adjustForContext(text, context: context)
                needsLeadingSpace = prependSpace && !adjustedText.hasPrefix(" ") && !adjustedText.hasPrefix("\n")

                // Update cache with what the field will look like after this paste.
                if adjustedText.hasSuffix(".") || adjustedText.hasSuffix("!") || adjustedText.hasSuffix("?") {
                    self.lastPasteEndingContext = .afterTerminal
                } else if adjustedText.hasSuffix(" ") || adjustedText.hasSuffix("\n") {
                    self.lastPasteEndingContext = .afterWhitespace
                } else {
                    self.lastPasteEndingContext = .midSentence
                }
                pasteText = adjustedText
                print("[VOICE] Clipboard write len=\(pasteText.count), context=\(context), msg=\(self.isMessagingApp()), code=\(self.isCodeEditor()), prependSpace=\(prependSpace), typeSpace=\(needsLeadingSpace), rapidFire=\(isRapidFire), leading='\(pasteText.prefix(4))'")
            }

            pasteboard.clearContents()
            guard pasteboard.setString(preFormatted && needsLeadingSpace ? String(pasteText.dropFirst()) : pasteText, forType: .string) else {
                print("[VOICE-PASTE] result: failed reason=clipboard-write-failed")
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Paste failed — could not write to clipboard."]
                )
                return
            }

            // Space is always delivered as a real keystroke — never prepended to
            // clipboard content. Many apps (Chrome, Notion, web textareas) silently
            // strip leading whitespace from paste payloads, so prepend would be lost.
            if willUseCGEvent {
                print("[VOICE-PASTE] strategy: cgevent")
                if needsLeadingSpace { self.simulateSpaceKey() }
                self.simulatePaste()
            } else {
                print("[VOICE-PASTE] strategy: applescript")
                self.pasteViaSystemEvents(leadingSpace: needsLeadingSpace)
            }
            self.verifyPasteLanded(expected: targetSnapshot)
        }

        // Restore clipboard after paste + extra breathing room.
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

    // MARK: - Cursor context reading

    /// Read up to `length` characters immediately before the insertion point.
    /// Three-path cascade — each path catches what the previous misses:
    ///
    ///  Path A (native controls): kAXSelectedTextRangeAttribute + kAXStringForRangeParameterizedAttribute
    ///  Path B (Electron/web):    kAXSelectedTextRangeAttribute + kAXValueAttribute full-read
    ///  Path C (anything else):   kAXValueAttribute suffix — assumes cursor is at end,
    ///                             which is always true right after a dictation
    ///
    /// Returns nil only when AX is not trusted or no focused element exists.
    /// Returns "" when the cursor is at position 0 (empty field / beginning of field).
    ///
    /// Public wrapper — callers (VoiceApp) should sample this at recording-START,
    /// because that's when the user's target text field reliably has focus. By
    /// the time we paste, focus may have moved around (toast popups, dropdowns).
    /// We pass the snapshot through to Qwen3 polish so the model can decide
    /// spacing / punctuation / number formatting relative to existing field text.
    func sampleFieldContextBeforeCursor(length: Int = 24) -> String? {
        return contextStringBeforeCursor(length: length)
    }

    private func contextStringBeforeCursor(length: Int = 3) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        // Try to read the cursor position via kAXSelectedTextRangeAttribute.
        var rangeRef: CFTypeRef?
        let rangeOK = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        var cfRange = CFRange(location: -1, length: 0)
        if rangeOK, let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
            AXValueGetValue(rv as! AXValue, .cfRange, &cfRange)
        }

        let cursorKnown = cfRange.location >= 0

        if cursorKnown {
            guard cfRange.location > 0 else { return "" }  // cursor at start → fresh field
            let readLen = min(length, cfRange.location)

            // Path A: parameterized string-for-range (O(1), works in AppKit / UIKit controls).
            var beforeRange = CFRange(location: cfRange.location - readLen, length: readLen)
            if let rangeValue = AXValueCreate(.cfRange, &beforeRange) {
                var charRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &charRef
                ) == .success, let str = charRef as? String, !str.isEmpty {
                    print("[VOICE-AX] Path A: '\(str)'")
                    return str
                }
            }

            // Path B: cursor position known but parameterized attr failed — read full value.
            // Handles Electron and some Qt-based apps that expose the value but not the range attr.
            guard cfRange.location <= 200_000 else { return nil }
            var textRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
               let fullText = textRef as? String, cfRange.location <= fullText.count {
                let endIdx = fullText.index(fullText.startIndex, offsetBy: cfRange.location)
                let startIdx = fullText.index(endIdx, offsetBy: -readLen)
                let result = String(fullText[startIdx..<endIdx])
                print("[VOICE-AX] Path B: '\(result)'")
                return result
            }
        }

        // Path C: cursor position unknown — read the full field value and take the suffix.
        // This assumes the cursor is at the end of the field, which is virtually always
        // true immediately after the user stops dictating. Works in Chrome, Safari, Notion,
        // GitHub, and other web-based text areas that don't expose kAXSelectedTextRangeAttribute.
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef) == .success,
              let fullText = textRef as? String else { return nil }
        guard !fullText.isEmpty else { return "" }
        let suffix = String(fullText.suffix(length))
        print("[VOICE-AX] Path C (suffix): '\(suffix)'")
        return suffix
    }

    // MARK: - Context determination and text adjustment

    private func determineContext(_ preceding: String?) -> InsertionContext {
        // nil = AX read failed (app doesn't expose text, or focus not settled).
        // Fall back to whatever the last paste ended with (cached) — that's
        // almost always correct for back-to-back dictation. If no cache at all
        // (first ever paste), default to .afterTerminal (adds a space). A stray
        // extra space is far less bad than two words smashed together.
        guard let preceding = preceding else {
            return lastPasteEndingContext ?? .afterTerminal
        }
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
            let t = lowercaseFirstPreservingI(stripTrailingPeriod(text))
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

    /// Build a CGEventSource that does NOT inherit the user's currently-held
    /// physical modifier flags. We use `.privateState` (fresh state pool not
    /// shared with the system input state) so when the user is still holding
    /// the hotkey's modifier keys at paste time, our synthesized Cmd+V is
    /// pure Cmd+V — not Cmd+Opt+V / Cmd+Fn+V / Cmd+Space etc. Without this,
    /// the global hotkey's release race produced phantom Cmd+Opt+V combos in
    /// apps like Chrome, Cursor, and any electron shell with a debug shortcut
    /// on those bindings. Also explicitly zero local-mod suppression flags so
    /// the OS doesn't merge held modifiers into our keystrokes.
    private func makeIsolatedEventSource() -> CGEventSource? {
        guard let src = CGEventSource(stateID: .privateState) else { return nil }
        // Suppress ALL local modifiers from being combined with our synthetic
        // events. 0x80000000 (kCGEventFlagMaskNonCoalesced upper bits) + all
        // lower modifier bits = every modifier flag class.
        src.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        // Sources default to a 0.25s suppression interval — long enough that
        // a user re-pressing their hotkey can't disrupt our pending keystrokes.
        return src
    }

    private func simulatePaste() {
        let source = makeIsolatedEventSource()
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Synthesize Cmd+Z to undo the most recent text insertion. Used by the
    /// optimistic-paste swap path: after pasting unpolished TextFormatter
    /// output, we Cmd+Z it and paste the polished version.
    /// Falls back to AppleScript when Accessibility isn't granted.
    /// Virtual key 6 = Z.
    func undoLastPaste() {
        if isAccessibilityTrusted() {
            let source = makeIsolatedEventSource()
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        } else {
            let script = """
            tell application "System Events"
                keystroke "z" using command down
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    print("[VOICE] AppleScript undo error: \(error)")
                }
            }
        }
    }

    /// Synthesize a single Space keystroke. Used before simulatePaste() when
    /// the cursor context calls for a leading space. Typing the space as a
    /// real key event (rather than prepending it to the clipboard payload)
    /// avoids paste-time whitespace stripping in Notion, browser text
    /// fields, and other Electron/web surfaces. Virtual key 49 = Space.
    ///
    /// Uses the isolated event source so a still-held hotkey modifier doesn't
    /// turn this into Cmd-Space (Spotlight) or Opt-Space.
    private func simulateSpaceKey() {
        let source = makeIsolatedEventSource()
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
        // Explicitly clear modifier flags. CGEvent inherits the source's
        // current flags by default; forcing them to [] guarantees a bare space.
        keyDown?.flags = []
        keyUp?.flags   = []
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// AppleScript paste — requires Automation permission for System Events.
    /// When `leadingSpace` is true, types a Space keystroke before the paste
    /// so apps that strip leading clipboard whitespace still receive the space.
    ///
    /// When AppleScript fails (most commonly: user denied Automation
    /// permission for System Events, or Accessibility is also denied),
    /// we surface a `voiceError` toast — otherwise the user has no idea
    /// why their text didn't appear. The polished text is still on the
    /// clipboard, so Cmd+V manually still works.
    private func pasteViaSystemEvents(leadingSpace: Bool = false) {
        let spaceStep = leadingSpace ? "keystroke \" \"\n            " : ""
        let script = """
        tell application "System Events"
            \(spaceStep)keystroke "v" using command down
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            print("[VOICE-PASTE] result: failed reason=applescript-compile-failed")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Paste failed. Text copied — press Cmd+V to paste."]
            )
            return
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error = error {
            print("[VOICE-PASTE] result: failed reason=applescript error=\(error)")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Paste failed (Automation permission missing?). Text copied — press Cmd+V to paste."]
            )
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
        // Tight 40ms window: if the frontmost app changed within this window
        // it's a focus-stealing race (a modal, popup, or another app pulling
        // focus during paste delivery). After 40ms a focus change is most
        // likely the user voluntarily switching apps (Cmd-Tab, click) AFTER
        // the paste already landed — we must NOT toast on that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            // Skip verify entirely when we couldn't snapshot the source bundle
            // (typically: no frontmost app at hotkey time, like Spotlight open).
            // Without a baseline we can't tell good from bad.
            guard let expectedBundle = expected.bundleId else {
                print("[VOICE-PASTE] verify SKIP — no snapshot bundle")
                return
            }
            let nowBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard nowBundle != expectedBundle else {
                print("[VOICE-PASTE] result: success target=\(expectedBundle)")
                return
            }
            // Skip the toast if our own pasteboard contents got consumed —
            // many apps clear the selection / clipboard preview right after
            // accepting a paste, which is also a strong signal that the
            // paste landed even though focus moved.
            let pbStill = NSPasteboard.general.string(forType: .string)
            if pbStill == nil || pbStill?.isEmpty == true {
                print("[VOICE-PASTE] result: success (clipboard consumed) target=\(expectedBundle)")
                return
            }
            // Belt-and-suspenders: if AX is trusted and the *focused element*
            // identity is unchanged, that's a stronger "paste landed" signal
            // than bundle id alone (frontmost can flicker briefly without the
            // user-perceived focus changing — Sonoma sometimes reports the
            // hotkey-emitting helper as briefly frontmost).
            if AXIsProcessTrusted(), let expectedEl = expected.focusedElement {
                let sys = AXUIElementCreateSystemWide()
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
                   let r = ref {
                    let nowEl = r as! AXUIElement
                    if CFEqual(nowEl, expectedEl) {
                        print("[VOICE-PASTE] result: success (focused element stable) target=\(expectedBundle)")
                        return
                    }
                }
            }
            print("[VOICE-PASTE] result: failed reason=focus-changed \(expectedBundle) → \(nowBundle ?? "nil") within 40ms")
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Paste failed. Text copied — press Cmd+V to paste."]
            )
        }
    }

    // MARK: - Selection Read / Replace

    /// Read the currently selected text from the frontmost app via AX API.
    /// Returns nil if nothing is selected, AX is unavailable, or the frontmost
    /// app doesn't expose selected text.
    func getSelectedText() -> String? {
        guard AXIsProcessTrusted() else {
            print("[VOICE-CP] getSelectedText: AX not trusted")
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("[VOICE-CP] getSelectedText: no frontmost app")
            return nil
        }
        print("[VOICE-CP] getSelectedText: app=\(app.bundleIdentifier ?? "?")")

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        let focusRes = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusRes == .success, let focusedRef else {
            print("[VOICE-CP] getSelectedText: no focused element (axErr=\(focusRes.rawValue))")
            return nil
        }
        let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

        var selRef: CFTypeRef?
        let selRes = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selRef)
        if selRes == .success, let txt = selRef as? String, !txt.isEmpty {
            print("[VOICE-CP] getSelectedText AX → \(txt.count) chars")
            return txt
        }
        print("[VOICE-CP] getSelectedText: AX returned empty (axErr=\(selRes.rawValue)) — falling back to copy-via-Cmd+C")

        // Fallback: copy via Cmd+C then read clipboard.
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)
        let priorChangeCount = pb.changeCount

        // Use isolated source so held hotkey modifiers don't pollute Cmd+C.
        let src = makeIsolatedEventSource()
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // C = 8
        let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags   = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update (max 250ms, poll every 15ms).
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            if pb.changeCount != priorChangeCount { break }
            usleep(15_000)
        }

        let copied = pb.string(forType: .string)
        let captured: String? = (copied != prior && copied?.isEmpty == false) ? copied : nil

        // Restore prior clipboard so the user's clipboard isn't trampled.
        pb.clearContents()
        if let p = prior { pb.setString(p, forType: .string) }

        print("[VOICE-CP] getSelectedText Cmd+C fallback → \(captured?.count ?? 0) chars")
        return captured
    }

    /// Replace the current selection in the frontmost app with newText.
    /// Writes newText to the clipboard, sends Cmd+V (paste-over-selection),
    /// then restores the prior clipboard contents after a short delay.
    ///
    /// Assumes the frontmost app has a text selection active — the selection
    /// will be replaced by the paste. If there is no selection the text is
    /// inserted at the cursor instead (standard paste behavior).
    func replaceSelection(with newText: String) {
        print("[VOICE-CP] replaceSelection: \(newText.count) chars")
        let pb = NSPasteboard.general
        let priorString = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(newText, forType: .string)

        // Tiny delay so target app's run loop sees the new pasteboard before Cmd+V.
        usleep(20_000)

        // Use isolated source so held hotkey modifiers don't pollute Cmd+V.
        let src = makeIsolatedEventSource()
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let pb = NSPasteboard.general
            if pb.string(forType: .string) == newText {
                pb.clearContents()
                if let p = priorString { pb.setString(p, forType: .string) }
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
