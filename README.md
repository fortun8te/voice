# VOICE

**Offline dictation for macOS with LLM-powered rewriting.** Press Cmd+Right, speak, get intelligent text that understands context—no cloud, no subscription, Wispr-level quality on your Mac.

Dictation that understands. Press Cmd+Right, speak, get intelligent rewriting—locally, offline, no subscription.

```
You: "add this to agenda for tomorrow standup"
VOICE: "Add this to the agenda for tomorrow's standup." (200ms)
```

---

## Features

- **LLM-powered rewriting** — Qwen3 (1.7B–235B) understands context, fixes homophones, grammar, formatting. Not just speech-to-text.
- **Fully offline** — Runs locally on M-series Macs. No cloud dependency, no network latency, no subscription fees.
- **Smart vocabulary** — Recognizes 90+ AI model names (Qwen, DeepSeek, GLM, etc.), technical terms, brand names. Add custom vocabulary in settings.
- **Personality modes** — Formal, casual, neutral, excited. Handles tone transformation, not just transcription.
- **200ms latency** — Fast enough to feel natural. Optional Qwen3-235B cloud mode for longer inputs.

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

## How It Works (Speech-to-Text Pipeline)

1. **Parakeet TDT** (on-device ASR, <1s) → speech recognition
2. **TextFormatter** (regex layer) → fixes Whisper homophones before LLM
3. **Qwen3 LLM** (1.7B local or 235B cloud) → intelligent rewriting (grammar, tone, formatting)
4. **PostProcessor** (deterministic rules) → formatting cleanup (em-dashes, lists, decimals)
5. **Clipboard + Paste** → inserts into active application

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

## Why Qwen3 (Not Claude/GPT/Whisper)?

1. **Runs locally** (1.7B = 530MB, <500ms on M1 Mac)
2. **Homophone-aware** — trained on diverse multilingual text, handles "Qwen"/"queen"/"coin" distinctions
3. **Fast on-device inference** — MLX-Swift GPU acceleration avoids cloud latency
4. **Open source** — fully transparent, can self-host, no vendor lock-in
5. **Optional cloud fallback** — Qwen3-235B for complex dictation (via Hugging Face or local Ollama)

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

---

## Compare to Alternatives

| | VOICE | Wispr Flow | Other Clones |
|---|---|---|---|
| **Type** | Local LLM + cloud option | Cloud-only | Varies |
| **Offline** | ✓ | ✗ | ✓ |
| **LLM quality** | Qwen3 (1.7B–235B) | Proprietary | Tiny/none |
| **Cost** | $0 | $4.99/mo | Varies |
| **Latency** | ~200ms (local) | 2–3s (cloud) | Inconsistent |

---

## Resources

- **[SETUP.md](./SETUP.md)** — Cloud API (Hugging Face/Groq/Ollama), model swapping, code signing, troubleshooting
- **[GitHub](https://github.com/fortun8te/voice)** — Source code, issues
- **License** — MIT (use, fork, sell freely)

**Made by [fortun8te](https://twitter.com/fortun8te).**
