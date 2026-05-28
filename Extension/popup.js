// Check if Voice app is reachable on port 59423
async function checkVoice() {
  try {
    const res = await fetch('http://127.0.0.1:59423/meet?active=ping', {
      method: 'POST',
      signal: AbortSignal.timeout(1500),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// Check if any Meet tab is currently in an active meeting
async function checkMeeting() {
  return new Promise((resolve) => {
    chrome.tabs.query({ url: 'https://meet.google.com/*' }, (tabs) => {
      const active = tabs.some(t =>
        t.url && /meet\.google\.com\/[a-z]+-[a-z]+-[a-z]+/.test(t.url)
      );
      resolve({ active, count: tabs.length });
    });
  });
}

async function update() {
  const voiceDot   = document.getElementById('voice-dot');
  const voiceLabel = document.getElementById('voice-label');
  const meetDot    = document.getElementById('meet-dot');
  const meetLabel  = document.getElementById('meet-label');
  const hint       = document.getElementById('hint');

  const [voiceOk, meetInfo] = await Promise.all([checkVoice(), checkMeeting()]);

  if (voiceOk) {
    voiceDot.className = 'dot connected';
    voiceLabel.innerHTML = '<b>Voice</b> is running';
  } else {
    voiceDot.className = 'dot disconnected';
    voiceLabel.innerHTML = '<b>Voice</b> not running';
    hint.textContent = 'Launch Voice.app from /Applications first.';
  }

  if (meetInfo.active) {
    meetDot.className = 'dot meeting';
    meetLabel.innerHTML = '<b>Recording</b> meeting now';
    hint.textContent = 'Voice is capturing this meeting. Tap the red pill to stop.';
  } else if (meetInfo.count > 0) {
    meetDot.className = 'dot';
    meetDot.style.background = '#fbbf24';
    meetLabel.innerHTML = `Meet tab open — not in call`;
    hint.textContent = 'Join a meeting to start auto-capture.';
  } else {
    meetDot.style.background = '#555';
    meetLabel.textContent = 'No Meet tab open';
    if (voiceOk) hint.textContent = 'Open meet.google.com to start.';
  }
}

update();
