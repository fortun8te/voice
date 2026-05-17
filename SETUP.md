# VOICE — Setup & Configuration Guide

Complete guide for building, configuring, and customizing VOICE on macOS.

---

## Table of Contents

1. [Quick Build](#quick-build)
2. [Cloud API Setup (Qwen3-235B)](#cloud-api-setup)
3. [Local Model Configuration](#local-model-configuration)
4. [TCC Permissions & Code Signing](#tcc-permissions--code-signing)
5. [Icon Troubleshooting](#icon-troubleshooting)
6. [Debug & Testing](#debug--testing)

---

## Quick Build

```bash
git clone https://github.com/fortun8te/voice.git
cd Voice
make install
```

This runs `xcodegen` (regenerates project from `project.yml`), builds with `xcodebuild`, installs to `/Applications/VOICE.app`, and launches it.

**First time?** macOS will ask for Microphone and Accessibility permissions. Grant both.

---

## Cloud API Setup

### Why Use Cloud?

**Local (default):** Qwen3 1.7B model → ~150ms latency, works offline, free.

**Cloud (optional):** Qwen3-235B model → ~1.5s latency, better quality on long inputs (paragraphs, complex sentences), no GPU needed.

### Option 1: Hugging Face Inference API

1. **Get API key:**
   - Go to [huggingface.co](https://huggingface.co)
   - Sign up (free)
   - Settings → Access Tokens → Create new token (read-only)
   - Copy your token

2. **Configure VOICE:**
   - Open VOICE settings (gear icon in menu bar)
   - Go to "Advanced" tab
   - Toggle "Use Cloud Model" → ON
   - Paste your Hugging Face token
   - Save

3. **First request:** Will download model (~15GB to Hugging Face's servers, cached after). Subsequent requests use cache.

**Cost:** Free tier covers ~100 requests/day. Paid: $0.50/mo for unlimited.

### Option 2: Local Ollama (Self-Hosted)

For maximum privacy + speed on your own hardware:

```bash
# Install Ollama (https://ollama.ai)
brew install ollama
ollama run qwen:235b

# In VOICE settings:
# Toggle "Use Cloud Model" → ON
# API endpoint: http://localhost:11434 (default)
# Leave token blank
```

Qwen3-235B is 15GB—needs 16GB+ RAM or GPU acceleration.

### Option 3: Groq (Fastest Cloud)

Groq's inference is insanely fast (~50ms). If you want premium speed:

1. Get API key from [groq.com](https://groq.com)
2. In VOICE settings:
   - API provider: Groq
   - Paste API key
   - Save

Cost: Starts at $0.02/million tokens.

---

## Local Model Configuration

### Use Qwen3-4B Instead of 1.7B

For longer inputs, 4B model gives better quality (~800ms latency on M1 Mac):

**File:** `Sources/Voice/Config/ModelConfig.swift`

Find:
```swift
static let modelID = "mlx-community/Qwen3-1.7B-4bit"
```

Replace:
```swift
static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
```

**Trade-off:** ~800ms instead of 150ms, but fewer grammar errors on complex inputs.

Rebuild:
```bash
make install
```

### Automatic Model Selection (Advanced)

VOICE auto-routes based on input length:

- **<6 words**: TextFormatter only (50ms)
- **6-20 words**: Qwen3 1.7B (150ms)
- **>20 words OR structural markers** (e.g., `\n\n`, `- bullet`): Qwen3 4B (800ms)

To change thresholds:

**File:** `Sources/Voice/Services/Qwen3Polisher.swift`

Find lines ~743-760 (polishWithMLX function):
```swift
let wordCount = text.split(separator: " ").count
if wordCount > 20 || hasStructuralMarkers {
  // Use large model
}
```

Adjust `wordCount > 20` to whatever threshold makes sense for your use case.

### Add Your Own Vocabulary

VOICE includes 90+ AI model names, tech terms, and brand names by default. Add more:

**Via UI:**
- Open VOICE → Settings → "Vocabulary Input"
- Paste terms (one per line): `Qwen`, `GraphQL`, `pytorch/lightning`
- Press Save

**Programmatically:**

File: `Sources/Voice/Services/ProperNounVocabulary.swift`

Find `seedTerms` array, add your terms:

```swift
static let seedTerms = [
  // ... existing entries ...
  "YourCompanyName",
  "YourProductName",
  "YourAcronym",
]
```

Rebuild and VOICE will recognize these immediately.

---

## TCC Permissions & Code Signing

### The Problem

macOS remembers which *app binary* you granted Microphone/Accessibility to. If the binary changes (happens on every `make install` with ad-hoc signing), macOS sees a "new" app and re-asks for permission.

### The Solution: Stable Signing

Use a local certificate that stays the same across rebuilds:

```bash
./scripts/setup-stable-cert.sh
```

This creates a local `voice-dev` development certificate and updates `project.yml` to use it.

Then rebuild:
```bash
xcodegen generate
make install
```

Now permissions stick across rebuilds. ✓

**If you have an Apple Development cert** from Xcode, you can use that instead (also stable). Just edit `project.yml`:

```yaml
CODE_SIGN_IDENTITY: "Apple Development: your.name@example.com"
```

### Reset Permissions (Nuclear Option)

If VOICE is stuck asking for permissions repeatedly:

```bash
RESET_TCC=1 make install
```

This removes old VOICE entries from macOS' TCC (privacy) database and re-grants fresh. Only do this if the stable-signing fix doesn't work.

---

## Icon Troubleshooting

### Icon Flickers or Shows Generic Square

This happens when `Assets.car` (bundled icons) and `AppIcon.icns` (loose file) disagree on which pixels to use.

**Fix:**

Replace `Sources/Voice/Resources/IconSource.png` with your new icon (512×512), then:

```bash
make install
```

A post-build script automatically:
1. Regenerates all icon sizes from your source PNG
2. Re-bundles them into `Assets.car`
3. Exports a clean 10-size `.icns` file

**Important:** Do NOT hand-edit files inside `AppIcon.appiconset/`—they're auto-generated and overwritten on every build.

---

## Debug & Testing

### Build Without Installing

```bash
xcodebuild -project Voice.xcodeproj -scheme VOICE -configuration Debug build
```

Output app is in `build/Debug/VOICE.app` (not installed to Applications).

### Build Release (For Distribution)

```bash
xcodebuild -project Voice.xcodeproj -scheme VOICE -configuration Release build
```

### Check Codesign Status

```bash
codesign -v -v /Applications/Voice.app
```

Should show no errors and a stable designated requirement (not `cdhash H"..."` if using stable cert).

### View Console Logs

While VOICE is running:

```bash
log stream --predicate 'eventMessage contains[cd] "VOICE"' --level debug
```

Look for `[VOICE-*]` prefixes in logs:
- `[VOICE-PILL]` — UI state changes
- `[VOICE-RECORD]` — Recording lifecycle
- `[VOICE-POLISH]` — Qwen3 rewriting
- `[VOICE-HOTKEY]` — Hotkey events

### Uninstall Completely

```bash
rm -rf /Applications/VOICE.app
rm -rf ~/Library/Application\ Support/VOICE
```

Then `make install` again for a clean slate.

---

## Performance Tuning

### Faster Startup (Prewarm Models)

VOICE pre-loads the Qwen3 1.7B model on launch so first dictation is instant. To check if prewarming is working:

```bash
log stream --predicate 'eventMessage contains[cd] "prewarm"' --level debug
```

You should see:
```
[VOICE-BOOT] Pre-warming Qwen3 1.7B...
[VOICE-BOOT] Qwen3 1.7B ready (2.4s)
```

If this doesn't appear, model loading happens on first use (adds 2-3s latency to first dictation).

### Memory Usage

Check resident set size:

```bash
ps aux | grep VOICE.app | grep -v grep
```

On M1 Mac with 1.7B model loaded: ~600MB. With 4B model: ~1.2GB.

If memory is tight, stick with 1.7B or use cloud API.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "Microphone permission denied" | Not granted in System Settings | Rm VOICE from Privacy > Microphone, re-grant |
| "Accessibility permission denied" | Not granted in System Settings | Rm VOICE from Privacy > Accessibility, re-grant |
| Hotkey doesn't work | Another app is using Cmd+Right | Change hotkey in VOICE settings or uninstall conflicting app |
| Whispers too quiet | Microphone gain too low | Gain auto-bumps 5× for quiet input. If still quiet, check mic levels in System Settings > Sound |
| "slash" stays literal | Utterance too short | The 4-word fast-path doesn't run LLM. Say it as a phrase: "github slash repo" (4+ words) |
| Cloud API slow | Network/Hugging Face overloaded | Fall back to local (Qwen3 1.7B). Cloud is optional, not required. |
| App crashes at launch | TCC database corrupted | `RESET_TCC=1 make install` |

---

## Next Steps

1. **Rebuild:** `make install`
2. **Test:** Press Cmd+Right, speak, release
3. **Customize:** Add vocabulary, pick personality (VOICE settings gear icon)
4. **Optional: Go cloud** — Add Hugging Face token for Qwen3-235B
5. **Advanced:** Swap models, tweak thresholds, enable debug logging

---

**Questions?** Open an issue on [GitHub](https://github.com/fortun8te/voice).
