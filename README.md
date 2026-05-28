# VOICE

**Offline dictation for macOS. Your audio never leaves your Mac. No subscription.**

Wispr Flow was caught screenshotting your screen every few seconds. VOICE does the opposite: Parakeet ASR runs fully on-device, polish runs on-device via Qwen3, and audio is never transmitted anywhere unless you explicitly route a long input to cloud. Zero telemetry.

```
You: "add this to agenda for tomorrow standup"
VOICE: "Add this to the agenda for tomorrow's standup." (200ms)
```

---

## vs. the alternatives

| | VOICE | Wispr Flow | SuperWhisper |
|---|---|---|---|
| Offline transcription | ✅ On-device Parakeet | ❌ Cloud only | ✅ |
| Offline polish | ✅ On-device Qwen3 | ❌ Cloud only | ✅ (setup required) |
| Meeting notes | ✅ No bot required | ❌ | ❌ |
| Polish in-place | ✅ | ✅ | ❌ |
| Screenshots your screen | ❌ Never | ✅ Every few seconds¹ | ❌ |
| Pricing | Free / open source | $15/mo | $249 one-time |
| App Store | ❌ | ✅ | ✅ |

¹ Wispr Flow's CTO publicly acknowledged the behavior after users discovered it. The app screenshots your screen every few seconds for "context awareness."

---

## Features

**Hotkey dictation**
Hold to push-to-talk. Double-tap to lock hands-free. Floating pill overlay shows recording state.

**On-device ASR**
Parakeet TDT 0.6B handles transcription locally. Whisper-class accuracy, no network hop.

**On-device polish**
Qwen3 1.7B or 4B runs via MLX on Apple Silicon. Complex or long inputs route automatically to Cerebras (Qwen3-235B) in the cloud. You control this threshold.

**Cleanup levels**
None / Light / Medium / High. Medium is the default.

**Personality modes**
Neutral / Formal / Casual / Excited. Neutral matches your tone. Formal decontracts. Casual keeps slang. Excited adds energy without adding fluff.

**My Style**
Paste writing samples. VOICE extracts your stylistic patterns and injects them into every polish call.

**Polish in-place**
Select any text in any app, press ⌥1. Cerebras rewrites it with three presets: Fix (grammar only), Smooth (flow), Elevate (stronger word choice).

**Meeting notes**
Captures Google Meet, Zoom, and Teams audio via ScreenCaptureKit. No bot. No browser extension. No calendar integration required. When the call ends, VOICE transcribes all participants and auto-summarizes with key decisions and action items.

---

## How it works

1. **Parakeet TDT** (on-device ASR, under 1s) — speech recognition
2. **TextFormatter** (regex layer) — fixes common homophones before the LLM sees the text
3. **Qwen3 LLM** (1.7B local or 235B cloud) — grammar, tone, formatting
4. **PostProcessor** (deterministic rules) — formatting cleanup for lists, decimals, punctuation
5. **Clipboard + Paste** — inserts into whatever app is active

---

## Setup

```bash
git clone https://github.com/fortun8te/voice.git
cd Voice
make install
```

Press **Cmd+Right**, speak, release. Done.

For cloud API setup, stable code signing, or model swapping: [SETUP.md](./SETUP.md).

```bash
# Reset permissions if stuck
RESET_TCC=1 make install
```

---

## Why local models

- **Privacy**: audio never leaves your Mac for standard dictation. Cloud only fires on explicit routing or Polish in-place.
- **Latency**: 200ms on M-series. Cloud-only tools add 2-3s round trips.
- **No subscription**: Qwen3 1.7B is 530MB. It runs on the hardware you already own.
- **No account**: nothing to log into, nothing to revoke.
- **Offline**: works on a plane, in a basement, anywhere.

---

## Known issues

- **Icon flickers** -- [Icon Troubleshooting](./SETUP.md#icon-troubleshooting)
- **TCC re-prompts** -- [Stable Code Signing](./SETUP.md#tcc-permissions--code-signing)
- **Quiet input** -- 5x gain boost is applied automatically for low-volume microphones

---

## License

MIT. Use it, fork it, sell it.

---

**Made by [fortun8te](https://twitter.com/fortun8te).**
