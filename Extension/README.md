# Voice Meet Bridge — Chrome Extension

Automatically starts/stops Voice meeting capture when you join or leave a Google Meet.

## How to install (takes 30 seconds)

1. Open Chrome and go to `chrome://extensions`
2. Enable **Developer mode** (toggle, top-right corner)
3. Click **Load unpacked**
4. Select this folder: `/Users/mk/Downloads/Voice/Extension`
5. Done — the extension installs instantly, no restart needed

## How it works

- The extension's content script runs on every `meet.google.com` tab
- When you join a meeting (URL becomes `meet.google.com/abc-defg-hij`) it sends a signal to Voice
- Voice starts recording the meeting audio automatically
- Tap the red pill to stop when the meeting ends

## Troubleshooting

- **Nothing happens when joining a Meet:** Make sure Voice.app is running (check menu bar)
- **Extension shows an error:** Re-load it from `chrome://extensions` after rebuilding Voice
- Voice listens on `localhost:59423` — no internet connection required
