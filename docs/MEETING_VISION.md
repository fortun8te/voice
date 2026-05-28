# Voice — Meeting Product Vision

A brainstorm of what Voice's meeting feature **could be**. Nothing here is
built yet. Ranked roughly by impact × effort. Read top-down, mark which
sections you want to actually ship.

---

## The North Star

Granola is the bar for synthesis. Wispr Flow is the bar for transcription.
Voice already does both on-device + cloud-hybrid. The unique angle to lean
into: **Voice is the only meeting tool that already lives in your menu bar
24/7, captures audio reliably without you having to start it, and outputs
plain text you can paste into anything.** Lean into "you don't think about
it — it's just there afterwards." That's a different product from "open the
app and click record."

---

## Tier 1 — Things every meeting tool has, that we don't

### 1. Inline audio playback with scrubbing

Audio file is on disk. Right now opening it means `NSWorkspace.open` →
external player. Build an embedded player in the expanded meeting row:

- Play/pause button
- Scrub bar with timestamp
- Click any transcript segment → seeks audio to that segment's start
- Click any speaker label → cycles through that speaker's segments
- Optional: 1.5×/2× playback speed

Implementation: `AVAudioPlayer` + a `TimelineView` for the scrub progress.
Probably half a day's work.

### 2. Calendar event linking

`meeting.date` + `meeting.sourceApp` is known. EventKit can give us the
user's calendar events ±5 min from that moment. On import:

- Auto-link if exactly one event matches the window
- If multiple, show a picker
- Once linked: meeting title = event title, attendees = event attendees,
  open-event button in the meeting row

Requires Calendar permission. EventKit API is well-trodden.

### 3. Speaker rename + persist across meetings

Right now diarization gives "Speaker 1", "Speaker 2". The user might know
that "Speaker 1" is always their CTO. Add:

- Right-click any speaker label → "Rename Speaker 1 → Alex"
- Voice remembers the rename in a per-meeting map
- Stretch goal: store voice embeddings so the SAME person gets the SAME
  name across future meetings automatically

### 4. Action item checkbox tracking that actually lives somewhere

We have checkboxes — they save the `isCompleted` flag to the meeting row.
Useful next step: a dedicated "All my action items" view that aggregates
across every meeting, lets you filter by assignee, mark done, snooze.

### 5. Notification deep-link

When the "Transcript ready" notification fires, clicking it should open
BigMenu pre-scrolled to that meeting. Currently it does nothing.

---

## Tier 2 — Things that make Voice meaningfully better than Wispr/Granola

### 6. Local meeting summaries (no API key needed)

Cerebras is currently required for summaries. Voice ships Qwen3-4B
on-device — use it as a fallback summarizer when:
- No Cerebras key
- Cerebras unreachable
- User explicitly opted into local-only

Quality will be lower than Qwen-3-235B but acceptable for personal notes.
And it lets the "meetings just have summaries" promise actually work for
every user, not just paying ones.

### 7. Smart meeting-only trigger

Already designed (waiting for 2+ participants). Also worth: detect when
your CALENDAR says you're in a meeting and pre-warm the recorder. Plus
auto-pause music via Apple Music API / Spotify Connect.

### 8. Templates / prompt presets per meeting type

A 1:1 needs a different summary than a board meeting. Add presets:

- **1:1** → focus on commitments, open questions, blockers
- **Standup** → who's doing what today
- **Customer call** → product asks, objections, sentiment
- **Brainstorm** → ideas with owners, decisions

User picks the preset per meeting (or it auto-detects from calendar
title). The system prompt to the summarizer changes accordingly.

### 9. Pre-meeting briefs

Right before a meeting starts (calendar-triggered), Voice scans your
recent transcripts with the same attendees and produces a one-paragraph
"here's what you discussed last time" brief delivered as a notification.

### 10. Inline transcript editing

Click a transcript word → fix a misrecognition. Saves the edit. Used for:
- Correcting names
- Fixing technical terms
- Building a personal vocabulary that boosts ASR quality on next meeting

---

## Tier 3 — Sharing / output

### 11. One-click share to Slack, email, Notion

"Copy as quote" with timestamp + speaker → paste into chat
"Email summary to attendees" → fills mail compose with the summary block
"Send to Notion" → via the Notion API token

### 12. Markdown export with richer structure

Today's export is decent. Add: front-matter (date, attendees, duration,
calendar event link), table of contents for long meetings, inline audio
references (Voice-only proprietary so they jump back into Voice).

### 13. Public share link

Encrypted upload to your own iCloud / S3 / Cloudflare R2 with a private
URL. Generated once, expires when you say. Reader sees a clean transcript
viewer page with audio playback.

---

## Tier 4 — Truly novel

### 14. Cross-meeting search + retrieval

"What did Alex commit to last quarter?" → searches every transcript with
Alex as a speaker, ranks the action items + decisions, returns answers
with source citations. Embeddings already cheap on-device with MLX.

### 15. Meeting "moments" — emotionally tagged

Identify the moments in a meeting that are different: a decision, a
disagreement, a laugh, a long pause. Show those as chapter markers on
the playback scrub bar. Lets you jump straight to the parts that matter.

### 16. Persona-aware paste

When you paste a meeting quote into a doc, Voice rewrites it for the
destination. Pasting into a board memo: formal tone, fully attributed.
Pasting into Slack: casual, condensed. Pasting into email: full
sentence. The polish pipeline we already have, but with quote context.

### 17. Audio-only meetings (no Chrome ext)

In-person meetings, phone calls, podcast recordings — same flow. The
user starts via menu bar click, Voice captures mic only, runs the same
pipeline. Already works as `kind: .meeting` for any session > 3min, but
we don't surface it as a feature.

---

## Tier 5 — Feel + polish

### 18. The recording surface should be a meeting "room"

Right now the recording UI is the pill — same as dictation. For meetings
we could elevate: a small persistent floating window (NOT the pill) that
shows: who's speaking right now (from speaker timeline), elapsed time,
participant count, live transcript scrolling. Click to expand to full
meeting view; click to minimize to pill.

### 19. Privacy-first defaults visible

A small icon on the pill that confirms "this is local-only" or "cloud
summary, local transcript", so the user always knows where their
conversation went. Especially important since competitors are
universally cloud-only.

### 20. The meeting list shouldn't look like a Mail inbox

Right now it's a list of rows. For 100+ meetings it gets unwieldy. Add:
- Calendar view (month grid, dots on meeting days)
- Speakers view (per-person feed of every meeting with that person)
- Topics view (clustered transcripts, cluster names auto-derived)

---

## Recommendations

**Ship next, in order:**

1. Inline audio playback (#1) — most-requested missing feature
2. Local summary fallback (#6) — unlocks summaries for everyone
3. Calendar linking (#2) — auto-titles + auto-attendees, huge UX win
4. Notification deep-link (#5) — small fix, real frustration
5. Speaker rename (#3) — quality-of-life on top of diarization

**Park for later:**

- Tier 4 features need real research + user signal first
- Tier 3 sharing depends on user demand
- The meeting "room" reframe (#18) is a big commitment

---

Tell me which of these you want built and in what order. I'd default to
shipping 1–5 of the Recommendations list next, then revisit.
