# VOICE — Personal Writing Style Feature
## Architecture Document

---

## What It Is

A new mode alongside "casual" / "formal" — but personal. The user uploads examples of their own writing and gets a spectrum:

- **Raw You** — barely touched, just ASR cleanup, reads like you on a lazy Tuesday
- **Polished You** — full editorial pass, still unmistakably you, just on your best day

Cloud-only. Local model can't do reliable style matching.

---

## Core Architecture: Style Card

**Not full example injection. Not RAG (yet). A compressed Style Card.**

The user uploads writing samples once. A one-time cloud call (Qwen3-235B) analyzes them and extracts a ~300-token Style Card — a compact structured description of how they write. That card gets injected into every cloud polish call.

| Approach | Token overhead | Latency | Quality | Verdict |
|---|---|---|---|---|
| Full example injection (paste samples in prompt) | 800–2000 tokens | Slow | High | Too expensive per-call |
| **Style Card (extracted descriptor)** | **280–320 tokens** | **Fast** | **Good** | **Use this** |
| RAG (vector search for similar examples) | 400–800 tokens + roundtrip | +200ms | Higher | v2 upgrade |
| Fine-tuning | 0 tokens | Zero | Best | Not viable on Cerebras |

---

## Style Card Contents

Extracted once, cached on-device. ~300 tokens when rendered as prompt text.

```json
{
  "surface": {
    "sentence_length": "short-to-medium",
    "avg_words_per_sentence": 14,
    "punctuation_habits": ["em dashes for asides", "ellipses to trail off"],
    "contraction_usage": "high"
  },
  "structural": {
    "paragraph_length": "short (1-3 sentences)",
    "opening_style": "jumps in directly, no preamble",
    "closing_style": "blunt, often a fragment",
    "transition_style": "abrupt or 'anyway'/'so' connectors",
    "list_tendency": "rarely lists, prefers inline"
  },
  "lexical": {
    "vocabulary_level": "conversational-to-moderate",
    "characteristic_phrases": ["honestly", "makes sense", "to be fair", "solid"],
    "avoid_phrases": ["delve", "it's worth noting", "touch base", "synergy"],
    "register": "casual-professional"
  },
  "exemplars": [
    "Yeah I think the issue is less about X and more about Y — at least that's how I read it.",
    "Anyway, let me know. No rush."
  ]
}
```

**What never leaves the device:** raw writing samples.
**What goes to cloud:** only the derived Style Card, embedded in the system prompt.

---

## Minimum Viable Data

| Tier | Samples | Words | Unlocks |
|---|---|---|---|
| Minimal | 5 samples | 800+ words | Basic card (sentence length, vocab level, formality) |
| Good | 10–15 samples | 3,000+ words | Full card + 2 sentence exemplars |
| Rich | 20+ samples | 8,000+ words | Card + context sub-profiles (messages vs emails vs notes) |

**Diversity beats volume.** 10 Slack messages < 5 messages + 3 emails + 2 notes.

---

## The Spectrum: 5 Levels

Not a continuous slider — LLMs don't interpolate between prompts cleanly. 5 named positions that map to a dual-axis instruction block:

- **Cleanup aggressiveness** (how much to fix)
- **Style fidelity** (how closely to follow the card)

| Level | Name | Cleanup | Style Fidelity |
|---|---|---|---|
| 1 | **Raw You** | Dysfluencies only (um, uh, false starts) | Exact — preserve even unconventional quirks |
| 2 | **Light Touch** | Grammar + run-ons, light punctuation | Close — smooth only what's unclear |
| 3 | **Natural Polish** | Full cleanup, grammar, flow, concision | Primary voice guide, mild elevation OK |
| 4 | **Best Self** | Structural improvements, tighter prose | Card informs voice, elevate where it strengthens |
| 5 | **Polished You** | Full editorial pass | Card informs character; quality and precision first |

### Injected into prompt as:
```
CLEANUP LEVEL: Light Touch
Fix grammar errors and run-ons. Light punctuation cleanup. Do not restructure thoughts.

STYLE FIDELITY: High
The STYLE CARD below defines this user's voice. Match their sentence length,
punctuation habits, vocabulary level, and characteristic phrases.
Preserve idiosyncrasies even when unconventional.
```

**Temperature:** Fixed at 0.4 across all levels. The spectrum is controlled through instructions, not sampling randomness. High temperature with style mimicry causes hallucinated quirks.

---

## Token Budget at Polish Time

Target: under 700 tokens total. Cerebras at 1,500 tokens/sec is fast — the bottleneck is network roundtrip, not generation.

| Component | Tokens |
|---|---|
| System prompt (base rules) | 80–100 |
| Style Card injection | 280–320 |
| Spectrum instruction | 40–60 |
| User transcript (30–150 words) | 40–200 |
| **Total** | **440–680** |

Hard cap Style Card at 400 tokens. If extraction goes over, a compression pass trims it.

**Skip Style Card for transcripts under 20 words** — not enough content to express style, card creates noise.

---

## Prompting Technique: Getting the Model to Actually Follow the Card

LLMs default to generic AI voice (transitional phrases, filler openers, faux-formal vocabulary). Two techniques force adherence:

### 1. Negative anchors
Explicitly list what not to do — the `avoid_phrases` list targets the generic AI patterns the user never uses.

Add: *"Do not default to generic AI writing patterns. The STYLE CARD overrides your default voice."*

### 2. Exemplar calibration (positive anchor)
Instruct the model to use the 2 extracted sentences as a calibration check:

```
Before generating output, ask yourself: does this sound like these exemplars?
Exemplar 1: "Yeah I think the issue is less about X..."
Exemplar 2: "Anyway, let me know. No rush."
```

### 3. Authorship test instruction
```
Before outputting, verify: could this sentence appear in the user's own writing samples?
If yes, output it. If no, revise toward the style card.
```

### 4. Thinking mode off
`/no_think` — thinking mode adds latency with no benefit for a well-specified style task.

---

## Style Drift: Keeping the Card Fresh

User style evolves. The card needs to stay current without constant manual work.

**Versioned profiles with decay weighting:**
- Samples from last 6 months → weight 1.0
- 6–18 months → weight 0.6
- Older → weight 0.3

**Auto-regeneration triggers:**
- User uploads 5+ new samples since last generation
- User clicks "Update my style"
- 90 days have passed

**Show a changelog:** "Key changes: sentences are now shorter on average; 'to be fair' added as characteristic phrase."

---

## Storage Architecture

| Data | Storage | Encryption | Notes |
|---|---|---|---|
| Raw writing samples | SwiftData | `NSFileProtectionComplete` | Never leaves device |
| Style Card JSON | SwiftData | `NSFileProtectionComplete` | Injected into cloud prompt |
| Cerebras API key | Keychain | AES-256-GCM | Standard credentials |
| Spectrum slider position | UserDefaults | None | Non-sensitive |
| Style Card version history | SwiftData | `NSFileProtectionComplete` | 3 versions kept for rollback |

```swift
@Model class StyleProfile {
    var id: UUID
    var version: Int
    var createdAt: Date
    var cardJSON: String       // rendered as ~300 tokens for prompt injection
    var sampleCount: Int
    var totalWordCount: Int
    var isActive: Bool
}

@Model class WritingSample {
    var id: UUID
    var uploadedAt: Date
    var contextLabel: String   // "message", "email", "note", "other"
    var wordCount: Int
    var content: String        // raw text — stays local always
    var weightMultiplier: Float
}
```

---

## MVP vs v2

### MVP — ship it
- Single Style Card per user
- Style Card generated on first upload (5+ samples), manually refreshed after
- **3 spectrum positions** (Raw / Balanced / Polished) — fewer options, less confusion
- SwiftData + FileProtection.complete on-device storage
- Style Card injected into Cerebras polish prompt only
- Fallback to local polish (no style card) when cloud unavailable
- ~1-2 sprints: extraction pipeline + prompt changes. UI is the larger effort.

### v2 — after validation
- Context sub-profiles: messages / emails / notes
- RAG: on-device embeddings (Apple's NLEmbedding), pull 1-2 relevant examples per call (+~200 tokens, better accuracy on context-matched output)
- Auto-regeneration with decay weighting
- Editable Style Card for power users
- Per-app style awareness (match Wispr Flow app-context detection)

---

## Key Risks

| Risk | Mitigation |
|---|---|
| Style Card doesn't capture voice well enough | Show 3 "style test" outputs at setup before committing. Expose raw Style Card as editable text. |
| Model ignores card on short transcripts | Skip card injection for transcripts < 20 words. |
| User uploads AI-generated or copied text | Local Qwen3-1.7B classification pass at upload: "Is this original personal writing?" Warn but don't block. |
| Cloud unavailable | Graceful fallback to local polish, no style card. Show "Style matching unavailable" in UI. |
| Style Card token bloat | Hard cap at 400 tokens. Compression pass if extraction exceeds limit. |

---

## Implementation Entry Points in Current Codebase

- `Sources/Voice/Services/Qwen3Polisher.swift` — `buildCloudSystemPrompt()` is where Style Card gets injected
- `Sources/Voice/Services/CerebrasPolisher.swift` — cloud polish path, add style card parameter
- `Sources/Voice/App/VoiceApp.swift` — add `PersonalityStyle.personal` case + style card fetch
- New: `Sources/Voice/Services/StyleCardService.swift` — extraction, storage, regeneration
- New: `Sources/Voice/Views/StyleSetupView.swift` — sample upload, test outputs, spectrum slider
