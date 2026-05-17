# VOICE

**Dictation that actually understands what you say.** Press Cmd+Right, speak naturally, watch your words get rewritten with intelligence—not just transcribed. Works offline. No cloud latency. No nonsense.

```
You: "add this to the agenda for tomorrow standup"
VOICE: ✓ "Add this to the agenda for tomorrow's standup." (200ms local)
Wispr Flow: ✓ Same quality (but 2-3s + cloud dependency)
```

---

## Why VOICE Wins

| Feature | VOICE | Wispr Flow | Other Local Clones |
|---------|-------|-----------|-------------------|
| **Latency** | ~200ms local | 2-3s cloud | Inconsistent |
| **Works offline** | ✓ | ✗ | ✓ |
| **Homophones fixed** | Qwen3 LLM + custom vocab (90+ AI models) | Basic dict | Minimal |
| **Personalities** | 4 styles (neutral/formal/casual/excited) | 3 styles | None |
| **Cleanup levels** | 4 (none/light/medium/high) | 2 | None |
| **Context window** | Full conversation memory per session | None | None |
| **Cost** | $0 (or $0.50/mo cloud option) | $4.99/mo | Varies |

**The real difference:** VOICE understands *what you're saying*, not just *sounds*. Qwen3 handles complex homophones (Qwen→"queen"/"coin", DeepSeek→"deep seek"), adds smart formatting (paragraphs, bullets, em-dashes → commas), and learns your lingo.

---

## Quick Start

### Local (Recommended)
```bash
git clone https://github.com/fortun8te/voice.git
cd Voice
make install
```
Press **Cmd+Right**, speak, release. Done.

### Cloud (Optional—Better Quality for Long Inputs)
Use **Qwen3-235B** via Hugging Face or local Ollama for more sophisticated dictation on paragraphs and complex text. See [SETUP.md](./SETUP.md) for configuration.

---

## What It Does

- **On-device speech-to-text** via Parakeet (TDT). Runs locally, ~1s latency.
- **Intelligent rewriting** via Qwen3 (local 1.7B for speed, optional 4B for quality).
- **Homophones + vocab** — recognizes 90+ AI model names, tech terms, brand names out of the box. Add your own vocabulary in settings.
- **4 personalities** — Neutral (match tone), Formal (decontracts), Casual (keeps slang), Excited (adds energy).
- **4 cleanup levels** — None (raw), Light (punctuation), Medium (grammar + formatting), High (aggressive rewrite).
- **Offline-first** — no network dependency. Works in planes, tunnels, Zoom calls with flaky WiFi.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Hotkey Press (Cmd+Right)                           │
└────────────────┬────────────────────────────────────┘
                 │
         ┌───────▼──────────┐
         │  AVAudioEngine   │  Capture your voice
         └────────┬─────────┘
                  │
         ┌────────▼────────┐
         │  Parakeet TDT   │  Local ASR, <1s
         │  (on-device)    │
         └────────┬────────┘
                  │ "github slash repo slash readme"
         ┌────────▼──────────┐
         │  TextFormatter    │  Pre-LLM fixes (slash→/, vocab)
         └────────┬──────────┘
                  │ "github/repo/readme"
         ┌────────▼──────────────┐
         │  Qwen3 (local 1.7B)   │  Grammar, tone, formatting
         │  or 4B (quality mode) │
         │  or 235B (cloud)      │
         └────────┬──────────────┘
                  │ "GitHub repo readme"
         ┌────────▼──────────────┐
         │  PostProcessor        │  Strip em-dashes, format lists
         └────────┬──────────────┘
                  │ "GitHub repo readme" ✓
         ┌────────▼──────────────┐
         │  Clipboard + Paste    │  Into active app
         └──────────────────────┘
```

**The magic:** Most "Wispr clones" skip the rewriting step or use a toy model. VOICE runs **Qwen3** (1.7B-235B LLM) locally to *actually understand* what you said—not just transcribe it. Fixes homophones, adds smart punctuation, catches grammar, formats paragraphs. Wispr-level quality on your Mac, offline, no subscription.

---

## Config & Customization

### Change Your Hotkey
**Settings > Hotkeys** → Pick Push-to-Talk (Cmd+Right) or Hands-free (always listening).

### Use Cloud Instead of Local
Edit `Sources/Voice/Config/ModelConfig.swift` or set via environment:
```bash
VOICE_MODEL_TIER=cloud make install
```
This swaps to **Qwen3-235B** (via Hugging Face API or local Ollama). Better quality, ~1.5s latency.

### Add Your Vocabulary
**Settings > Vocabulary Input** → Paste model names, brand terms, or personal jargon. VOICE learns them immediately.

**For code terms**, add with slashes: `graphql-python`, `pytorch/lightning`, `aws-cdk`. VOICE will recognize variations (GraphQL, graph-ql, graphql).

### Tweak Rewrite Intensity
- **None** — Just transcribe, no fixes.
- **Light** — Add punctuation, capitalize sentences.
- **Medium** — Fix grammar, homophones, format lists (recommended for most).
- **High** — Aggressive rewrite, rewording for clarity, formal style.

### Pick a Personality
- **Neutral** — Match your speaking tone exactly.
- **Formal** — Full sentences, decontracts, no em-dashes.
- **Casual** — Lowercase leaning, keeps "yeah"/"yo", rhythmic.
- **Excited** — Exclamation marks where audio energy supports, never fabricated.

---

## Why Qwen3 (Not Claude, GPT, etc.)?

1. **Runs locally** — 1.7B model (530MB) fits in memory, completes in <500ms on M-series Macs.
2. **Excellent homophones** — Trained on diverse text, handles technical terms without hallucination.
3. **Fast inference** — MLX-Swift on GPU gives us sub-second latency for short inputs.
4. **Open source** — Can run offline, no API cost, can self-host.
5. **Optional cloud tier** — Qwen3-235B for long paragraphs (>20 words) when you need depth.

---

## Build & Install

```bash
# Clone and build
git clone https://github.com/fortun8te/voice.git
cd Voice
make install

# Or reset permissions if TCC is stuck
RESET_TCC=1 make install
```

**See [SETUP.md](./SETUP.md) for:**
- Stable code signing (fix TCC permission re-granting)
- Icon troubleshooting
- Cloud API setup (Hugging Face / Ollama)
- Local model swapping
- Debug builds

---

## The Details (If You Care)

- **Speech capture:** AVAudioEngine with adaptive gain (whispers still work)
- **ASR:** Parakeet TDT (on-device, MIT-licensed)
- **Rewriting:** Qwen3 via MLX-Swift (GPU acceleration on M1+)
- **Inference:** 1.7B for latency (<500ms), optional 4B or 235B for quality
- **Post-processing:** Smart em-dash removal, European decimal handling, bullet list detection
- **Offline:** Fully local until you opt into cloud

---

## Known Issues & Fixes

**Icon flickers?** See [Icon Troubleshooting](./SETUP.md#icon-flickering).

**TCC keeps asking for permission?** See [Stable Code Signing](./SETUP.md#tcc-permissions-fix).

**Whispers too quiet?** Microphone was bumped to 5× gain for quiet input. Works now.

**"slash" stays literal?** Fixed—now routes to LLM for 4+ word inputs.

---

## License

MIT. Use it, fork it, sell it. No restrictions.

---

## Next Steps

1. **Build locally** (2 min) — `make install`
2. **Press Cmd+Right** and speak (10 sec)
3. **Customize** — Add vocabulary, pick personality, adjust cleanup level (5 min)
4. **Optional: Enable cloud** — Switch to Qwen3-235B for long-form dictation ([SETUP.md](./SETUP.md))

That's it. No fluff, no account, no waiting.

---

**Made by [fortun8te](https://twitter.com/fortun8te).** Questions? Open an issue.
