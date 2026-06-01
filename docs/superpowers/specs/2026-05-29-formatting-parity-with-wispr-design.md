# VOICE — Formatting Parity with Wispr Flow (Design)

Date: 2026-05-29

## Problem

VOICE's polishing/formatting loses to Wispr Flow on perceived quality. Not because
the engine is weak (gpt-oss-120b via NVIDIA, 2,100-word formatting brief, 30+ post
passes, sanitizer) but because:

1. We cannot **measure** where we lose — no head-to-head harness. The prompt is tuned
   against memory of Wispr outputs, not a diff.
2. We are missing 3 specific behaviors Wispr ships.

## Intelligence: how Wispr's formatter actually works

Wispr's formatting LLM runs **server-side** (api.wisprflow.ai) — prompt not in the
bundle. But the Electron client (`app.asar`) + docs reveal the behavior precisely:

- **Lists**: numbers OR sequence words ("one… two…" / "first… second…") → numbered
  list. `"one finish the report two send the presentation"` → `1. Finish the report\n2. Send the presentation`
- **Capitalization is cursor-aware**: lowercase if inserting mid-sentence, capitalized
  after sentence-ending punctuation. Formats relative to surrounding field text.
- **Trailing-period removal is tiered by Writing Style**:
  - Default → strip trailing periods, messaging apps only, ≤2 sentences
  - Casual → any app, ≤10 sentences
  - Very Casual → no sentence limit
  - Formal → preserve all trailing periods
- **App-aware**: `getAppType(bundleID, url) === Email` branches to email formatting;
  special HTML path for Front (`com.frontapp.Front`).
- **Backtrack / self-correction**: triggers on "actually" / "scratch that" requiring
  a >3-word reduction; also infers corrections from restatement without a trigger.
  `"Let's do coffee at 2 actually 3"` → `"Let's do coffee at 3."`
- **Tracked transforms**: client logs `emailFormatted`, `mistakesFixed`,
  `listFormatted` flags and compares ASR length vs formatted length (our sanitizer
  does the equivalent).
- **Custom instructions (command layer)**: agentic tools `set_toggle`,
  `add_custom_toggle` (≤120-char custom instruction), `set_prompt`, `set_name`,
  `set_shortcut`. Users add custom formatting rules by voice. (Roadmap, not v1.)

## Gap analysis (VOICE today)

| Behavior | VOICE status |
|---|---|
| Numbered/colon/implicit lists | Present, gated by cleanup level |
| Sequence-word list trigger ("first/second") | Verify / likely partial |
| Cursor-aware capitalization | MISSING — only sentence-start caps |
| Tiered trailing-period strip by style | MISSING — personality exists but no rule |
| App-type → email branch | Partial (`appContextLabel`) |
| Backtrack / self-correction | MISSING entirely |
| Length-delta sanitizer | Present (relaxed cloud / strict local) |

## Approach

### Foundation already exists — extend, don't rebuild

`Sources/Voice/App/PolishHarness.swift` + `Sources/Voice/Resources/GoldenCases/`
(50 cases) already run raw transcripts through the production polish pipeline.
Invoked via `swift run -c release Voice --polish-harness`. Two weaknesses to fix:

1. **Scorer is trigram-Jaccard similarity to one reference (≥0.5 pass).** Measures
   word overlap, NOT formatting quality. Cannot detect "list formatted?", "backtrack
   applied?", "trailing periods correct for style?". REPLACE/AUGMENT with an LLM-judge
   rubric scorer (keep Jaccard as a cheap secondary signal).
2. **Runs the LOCAL MLX path** (`Qwen3Polisher.shared.polish` → prewarms 1.7B/4B).
   But production primary is now **NVIDIA gpt-oss-120b**. The harness must exercise
   the cloud path so we optimize the engine users actually hit. (Heads-up: a full
   50-case run = ~50 NVIDIA requests; mind the 40 RPM limit and 5000-credit lifetime
   cap.)

### Methodology decision: extend existing harness + LLM-judge rubric

Rejected the BlackHole virtual-audio route (heavy setup, Wispr in the loop every run).
Instead: keep the 50-case corpus, add new cases for missing behaviors, and add an
**LLM-judge** that scores each case on a per-category rubric. Wispr's documented
behavior calibrates the gold `reference` fields.

### Corpus additions (existing 50 + new cases for missing behaviors)

1. List (digit + sequence-word triggers)
2. Email (salutation, body, sign-off; Gmail/Front)
3. Rambling → compression (filler, repetition, tangents)
4. Casual message (iMessage/Slack, trailing-period strip)
5. Code/technical (backtick targets, identifiers)
6. Self-correction / backtrack ("actually", "scratch that", restatement)
7. Mixed / multi-paragraph (topic shifts)

### Rubric (per case, judged)

- Structure correct? (list/email/paragraph as intended)
- Meaning preserved? (no invented content, no dropped facts) — hard gate
- Style correct for setting? (trailing periods per Writing Style tier)
- Compression appropriate? (ramble shortened, not over-cut)
- Backtrack applied where present?
- No em-dashes / no emojis (existing hard rules)

### Implementation order (measured against corpus each step)

1. **Harness** — `voice-polish-evals/`: corpus JSON, runner that feeds raw transcripts
   through the live polish path, LLM judge, score report (per-category pass rate).
2. **Backtrack pass** — new post-processor or prompt rule: trigger words + restatement
   inference, >3-word-reduction guard. Highest-visibility missing feature.
3. **Tiered trailing-period rule** — port Wispr's Writing-Style tiers exactly. Map to
   VOICE personalities (neutral→Default, casual→Casual, excited→?, formal→Formal).
4. **Cursor/context-aware caps** — pass surrounding field text into the formatter;
   capitalize relative to insertion point.
5. **List trigger parity** — ensure sequence words ("first/second/third") trigger
   numbered lists, not just digits.
6. **Prompt slimming** — the 2,100-word brief likely dilutes attention; tighten and
   re-measure. Only cut what the corpus proves is safe to cut.

## Success criteria

- Harness runs and produces a per-category score in one command.
- Backtrack, tiered trailing-period, cursor-aware caps all measurably pass on their
  corpus categories.
- Overall corpus pass-rate beats the pre-change baseline by a clear margin.
- No regression on meaning-preservation (hard gate stays green).

## Out of scope (v1)

- Custom-instruction command layer (agentic toggles) — roadmap.
- Virtual-audio live A/B vs Wispr — optional later calibration.
- Multilingual formatting — Wispr uses one generic non-English prompt; defer.
