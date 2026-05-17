# VOICE

Dictation that understands. Press Cmd+Right, speak, get intelligent rewriting—locally, offline, no subscription.

```
You: "add this to agenda for tomorrow standup"
VOICE: "Add this to the agenda for tomorrow's standup." (200ms)
```

---

## Why It Works

- **Intelligent rewriting** — Qwen3 LLM fixes homophones, grammar, formatting. Not just transcription.
- **Offline** — Runs locally on M-series Macs. No network, no latency, no cost.
- **Wispr-level quality** — Recognizes 90+ AI model names, tech terms, custom vocabulary. Handles personalities (formal/casual/excited).
- **Fast enough** — ~200ms latency. Instant enough to feel natural.

---

## Quick Start

```bash
git clone https://github.com/fortun8te/voice.git
cd Voice
make install
```

Press **Cmd+Right**, speak, release. Done.

**Optional:** Use cloud Qwen3-235B for longer inputs. See [SETUP.md](./SETUP.md).

---

## How It Works

1. **Parakeet TDT** (on-device ASR) → captures your voice
2. **TextFormatter** (pre-LLM) → fixes common Whisper mishears
3. **Qwen3 1.7B** (local LLM) → rewrites for grammar, tone, formatting
4. **PostProcessor** (smart rules) → strips em-dashes, formats lists, fixes decimals
5. **Paste** → into your active app

---

## Customize

### Personality
Settings > **Writing personality** → Neutral (match tone) / Formal (decontracts) / Casual (keeps slang) / Excited (energetic)

### Cleanup Level
Settings > **Rewrite intensity** → None / Light / Medium (recommended) / High

### Vocabulary
Settings > **Vocabulary Input** → Paste terms. VOICE learns them instantly.

### Hotkey
Settings > **Hotkeys** → Pick Cmd+Right or hands-free.

### Use Cloud (Optional)
[SETUP.md](./SETUP.md#cloud-api-setup) → Configure Qwen3-235B for long-form dictation.

---

## Why Qwen3?

1. Runs locally (1.7B = 530MB, <500ms on M1)
2. Excellent homophones (trained on diverse text)
3. Fast inference (MLX-Swift on GPU)
4. Open source (can self-host)
5. Optional cloud tier for quality (235B)

---

## Build & Install

```bash
# Standard build
make install

# Reset permissions if stuck
RESET_TCC=1 make install

# See SETUP.md for stable code signing, cloud API, model swapping, troubleshooting
```

---

## Known Fixes

- **Icon flickers** → [Icon Troubleshooting](./SETUP.md#icon-troubleshooting)
- **TCC re-prompts** → [Stable Code Signing](./SETUP.md#tcc-permissions--code-signing)
- **Whispers quiet** → 5× gain boost fixed it
- **"slash" literal** → Routes to LLM for 4+ word inputs

---

## License

MIT. Use it, fork it, sell it.

---

**[SETUP.md](./SETUP.md)** has everything else: cloud API keys, local model swapping, debug builds, performance tuning, full troubleshooting table.

**Made by [fortun8te](https://twitter.com/fortun8te).**
