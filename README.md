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

## Build & Install

```bash
make install                       # standard build + install (preserves TCC perms)
RESET_TCC=1 make install           # force-reset Microphone/Accessibility grants
```

`scripts/build-install.sh` runs `xcodegen` (if you've changed `project.yml`),
builds with `xcodebuild`, installs to `/Applications/Voice.app`, and verifies
both codesign stability and icon coherence before launching.

## Known Gotchas (please read before debugging icons or TCC)

### Icon: source-of-truth is `Sources/Voice/Resources/IconSource.png`

The icon flickering bug ("sometimes wrong, sometimes generic square") was caused
by `Assets.car` (built by actool) and `Contents/Resources/AppIcon.icns` (loose
file) containing *different* pixels. macOS picks one or the other unpredictably
depending on context (Finder, Dock, menu bar, Launchpad).

`scripts/fix_appicon_icns.sh` is a `postBuildScript` that:

1. Regenerates `Sources/Voice/Resources/Assets.xcassets/AppIcon.appiconset/*.png`
   from `IconSource.png`.
2. Re-runs `actool` so `Assets.car` reflects the new pixels.
3. Overwrites `AppIcon.icns` with a full 10-size icns from `IconSource.png`
   (actool itself emits a truncated 4-size icns — known issue).

**To update the icon: replace `IconSource.png` and rebuild.** Do NOT hand-edit
files inside `AppIcon.appiconset/` — they're overwritten on every build.

### TCC permissions: signed identity must be stable

System Settings → Privacy → Microphone / Accessibility pins each grant to the
app's codesign *designated requirement*. With ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`,
the current default), the designated requirement is `cdhash H"..."` — a SHA over
the binary that changes on every build. TCC then sees a brand-new app each
install and the user has to re-grant. Old grants linger as ghostly duplicates
that some tools display as "Voice OLD".

**Fix once with a stable identity:**

```bash
./scripts/setup-stable-cert.sh        # one-time: creates a `voice-dev` cert
# then edit project.yml:
#   CODE_SIGN_IDENTITY: "voice-dev"
# then:
xcodegen generate && ./scripts/build-install.sh
```

After this setup, the designated requirement is stable across rebuilds and TCC
keeps Microphone + Accessibility grants permanently.

If you have an Apple Development cert in your login keychain with its private
key intact (verify with `codesign --force --sign "Apple Development: ..." /bin/ls.copy`
— if it errors with `errSecInternalComponent`, the private key is missing),
you can use that instead — it's also stable.
