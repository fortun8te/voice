# Polish Quality — Known Issues & Planned Improvements

## Current Problem (Diagnosed vs Wispr)

VOICE is over-optimizing for **readability** instead of **transcript fidelity**.

The rewrite layer treats uncertain tokens with high confidence — it picks a substitution and commits, rather than preserving the ambiguity. Outputs feel AI-edited instead of naturally spoken.

**Wrong priority order (current):**
1. Readability
2. Fluency
3. Rewrite confidence
4. Accuracy ← should be first

**Right priority order:**
1. Semantic accuracy — don't change what was said
2. Speaker voice preservation — cadence, register, rhythm
3. Confidence-aware correction — only fix when confident
4. Readability polish — last, lightest touch

---

## What Needs to Change

### 1. Uncertainty-aware decoding
When ASR confidence is low on a token, **don't substitute — preserve or flag**.
Currently low-confidence audio → high-confidence substitution. That's backwards.

### 2. Conservative rewrite thresholds
Raise the bar for what triggers a rewrite. Right now the model rewrites too eagerly.
Should only touch: clear homophones, obvious punctuation, definite grammar errors.
Should leave alone: ambiguous phrasing, informal constructions, conversational rhythm.

### 3. Preserve raw phrasing on confidence drops
If a span has no strong match in vocabulary or context, output the raw ASR text.
Better to pass through "uhh kinda like the thing" than rewrite it to "something like that."

### 4. Speaker cadence retention
Cadence compression is too strong. Short punchy sentences get merged. Trailing phrases get trimmed.
The speaker's rhythm is part of their identity — don't compress it out.

### 5. Hallucination penalties
The model currently fills in gaps semantically. A low-confidence "uh maybe like" becomes "perhaps."
Need explicit penalty for generating tokens not present in the source ASR output.

### 6. Identity/register preservation
Informal speech ("kinda", "yeah", "like") is being normalized away.
In Neutral/Casual modes this should stay verbatim. Only Formal mode should decontract/normalize.

---

## What Works Well (Keep)

- Sentence segmentation
- Pacing structure
- Formatting (lists, paragraphs)
- Filler density reduction
- Editorial shaping for Formal mode

---

## Implementation Notes (When Ready)

- The fix lives primarily in `Qwen3Polisher.swift` system prompt + `PolishPostprocessor.swift`
- Add an explicit "PRESERVE UNCERTAINTY" rule to the system prompt
- Consider a confidence score threshold gate before any substitution
- The `suspects:` confidence feeding (Section 3.3 in the quality plan) is directly relevant here
- Light/None cleanup modes should enforce near-zero rewrite tolerance
