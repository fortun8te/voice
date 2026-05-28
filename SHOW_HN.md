Title: Show HN: VOICE -- offline macOS dictation with on-device LLM polish (no subscription)

---

Body:

A few months ago Wispr Flow's CTO acknowledged that the app screenshots your screen every few seconds for "context awareness." That bothered me enough to build an alternative.

VOICE does dictation with two local models: Parakeet TDT 0.6B for ASR (Whisper-class accuracy, runs fully on-device on Apple Silicon) and Qwen3 1.7B/4B via MLX for polish. The pipeline is hold-to-talk or double-tap-to-lock, Parakeet transcribes in under a second, Qwen3 rewrites for grammar and tone in another 200ms, pastes into whatever app is active. Complex or very long inputs route automatically to Cerebras (Qwen3-235B) in the cloud, but that's opt-in behavior. Audio never leaves your Mac for standard dictation. Zero telemetry.

The feature I'm most curious to get feedback on is meeting notes. It captures Google Meet, Zoom, and Teams audio directly via ScreenCaptureKit -- no meeting bot, no browser extension, no calendar permission. When the call ends it auto-summarizes with decisions and action items. I expected this to be the hard part but ScreenCaptureKit made it surprisingly straightforward.

Stack is Swift + MLX for inference, Parakeet TDT for ASR, Qwen3 for polish. MIT licensed. Repo: https://github.com/fortun8te/voice

Curious whether others have found local ASR models good enough for daily use -- Parakeet has been solid for me but I'm interested to hear how it holds up for non-native English speakers or heavy technical vocabulary.
