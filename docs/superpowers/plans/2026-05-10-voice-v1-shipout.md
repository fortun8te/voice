# Voice v1 Ship-out Implementation Plan

**Goal:** Ship a polished v1 of Voice (macOS dictation pill) with the full feature surface working: dictation loop, BigMenu wired, Meet recording, multi-speaker, summarization.

**Architecture:** Menu-bar app (`LSUIElement: true`). Floating `NSPanel` pill at bottom-center. Hotkey-driven dictation through WhisperKit with auto-paste at cursor. BigMenu (`NavigationSplitView`) for settings/dashboard. Meet recording via `MeetingRecorder` from `/Drafts.disabled/`. Summarization via local Ollama (`gemma3n:e2b`).

**Tech Stack:** SwiftUI, AppKit, WhisperKit, AVAudioEngine, CoreGraphics, Ollama HTTP.

---

## Task 1: Verify core dictation loop works end-to-end

**Files:**
- Verify: `Sources/Voice/App/VoiceApp.swift` (status item, auto-paste path)
- Verify: `Sources/Voice/Views/OverlayPanel.swift` (positioning, focused-window screen detection)
- Verify: `Sources/Voice/Utils/CursorPaster.swift` (paste reliability, Accessibility fallback)

- [ ] Confirm app launches with menu bar icon visible (waveform or "V" fallback)
- [ ] Confirm pill renders at bottom-center of focused-app's screen
- [ ] Confirm pill snaps to other screen when user clicks into a different display
- [ ] Confirm hold-fn → record → release → transcribe → paste works
- [ ] Confirm clipboard contains transcript even if paste fails
- [ ] Inspect logs for `[VOICE] Clipboard write ok=true, len=N` after each transcription

## Task 2: Wire BigMenu Output section (auto-paste toggle UI)

**Files:**
- Modify: `Sources/Voice/Views/BigMenuWindow.swift` (Output section)

- [ ] Add `@AppStorage("autoPaste")` toggle in Output section, default `true`
- [ ] Add `@AppStorage("autoCopy")` toggle (always-on clipboard write), default `true`
- [ ] Wire `@AppStorage("vocab_terms")` editable list in Vocabulary section
- [ ] Add Permissions section showing Accessibility + Microphone status with "Open System Settings" buttons

## Task 3: Wire BigMenu Hotkey + AI sections

**Files:**
- Modify: `Sources/Voice/Views/BigMenuWindow.swift`
- Read-only ref: `Sources/Voice/Services/HotkeyService.swift`
- Read-only ref: `Sources/Voice/Utils/TextFormatter.swift`

- [ ] Hotkey section: dropdown to choose `fn` / `right_option` / `left_option`, persisted via `@AppStorage("hotkey")`
- [ ] HotkeyService respects `@AppStorage("hotkey")` choice
- [ ] AI section: toggle for "Local Gemma cleanup" → `@AppStorage("useGemmaFinalPass")`, default false
- [ ] AI section: model picker (gemma3n:e2b / gemma3:1b / llama3.2:3b), persisted

## Task 4: Integrate Meet recording from Drafts.disabled

**Files:**
- Move: `Drafts.disabled/MeetingRecorder.swift` → `Sources/Voice/Services/`
- Move: `Drafts.disabled/OllamaClient.swift` → `Sources/Voice/Services/`
- Move: `Drafts.disabled/MeetingSummarizer.swift` → `Sources/Voice/Services/`
- Move: `Drafts.disabled/SpeakerDiarizer.swift` → `Sources/Voice/Services/`
- Modify: `Sources/Voice/Views/BigMenuWindow.swift` (Meetings section)
- Modify: `project.yml` (add new files if needed)
- Run: `xcodegen generate`

- [ ] Move drafts back into source tree
- [ ] Resolve any duplicate-symbol or compile errors
- [ ] Wire Meetings section to list saved meetings via `StorageService`
- [ ] Add "Start Meet recording" button that triggers `MeetingRecorder`
- [ ] Verify build succeeds

## Task 5: Wire summarization pipeline

**Files:**
- Modify: `Sources/Voice/Services/MeetingSummarizer.swift`
- Modify: `Sources/Voice/Views/BigMenuWindow.swift` (Meetings detail view)

- [ ] Hook MeetingSummarizer into post-recording flow
- [ ] Show summary in Meetings detail view (collapsible: action items, decisions, full transcript)
- [ ] Graceful fallback when Ollama isn't running

## Task 6: Build, smoke test, ship

- [ ] `xcodegen generate`
- [ ] `xcodebuild -project Voice.xcodeproj -scheme Voice -configuration Release -derivedDataPath build`
- [ ] Smoke test: dictate 30s clip → paste lands → transcript on clipboard
- [ ] Smoke test: open BigMenu → toggles persist across relaunch
- [ ] Smoke test: pill follows focused app between displays
- [ ] Copy `build/Build/Products/Release/Voice.app` to `/Applications/`

---
