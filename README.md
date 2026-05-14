# Voice

A macOS dictation app that actually feels fast. Just press Cmd+Right, talk, and your words appear in whatever app you're using—no cloud, no waiting.

## What It Does

Voice sits in your menu bar and gives you on-device speech recognition with a single hotkey. Press Cmd+Right, speak naturally, release. The app transcribes locally using Parakeet (a lightweight ASR model), runs the text through Qwen to clean it up (fixing homophones, adding punctuation), and pastes the result into your active window.

Real example: You're drafting an email. Instead of typing "I think we should reconsider the timeline because the dependencies aren't clear," you just hold Cmd+Right, say it out loud, release, and it's there—formatted, capitalized, ready to send.

## Why This Matters

Latency kills the flow. Cloud APIs have it. Local processing doesn't. Your macOS has the compute power to run a speech model right now—Parakeet handles it in under a second, and it's just smart enough to not butcher technical terms or names you've said a thousand times before.

No network round-trips. No audio leaving your machine. Works offline. Works when the API is down. Works the same way every time.

## How It Works

- **AVAudioEngine** captures your voice
- **Parakeet TDT** (on-device) transcribes
- **Qwen3** cleans up grammar and formatting
- **MLX-Swift** runs inference on your GPU
- **FluidAudio** handles the audio pipeline

## Get Started

Build it in Xcode, configure your hotkey to Cmd+Right (or whatever you prefer), and use it. It just works.
