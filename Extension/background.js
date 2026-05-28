// Voice Meet Bridge — background service worker
// Receives MEET_STATE messages from content.js and forwards them to the
// Voice macOS app via a POST to http://127.0.0.1:59423/meet.
//
// Why background.js and not content.js directly?
// Content scripts can't fetch to localhost due to CORS restrictions.
// Background service workers in extensions bypass CORS for hosts listed
// in host_permissions — so this is the correct two-hop design.

const VOICE_BRIDGE_URL = 'http://127.0.0.1:59423/meet';
const VOICE_SPEAKER_URL = 'http://127.0.0.1:59423/speaker';

function notifyVoice(active, names) {
  let url = `${VOICE_BRIDGE_URL}?active=${active}`;
  if (active && Array.isArray(names) && names.length > 0) {
    // Encode each name individually (commas separating names are kept literal
    // so the Swift side can split on ',' after URL-decoding each segment).
    const encoded = names.map(n => encodeURIComponent(n)).join(',');
    url += `&names=${encoded}`;
  }
  fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ active, names: names || [] }),
  }).catch(() => {
    // Voice not running — fail silently, never bother the user.
  });
}

// Push an active-speaker change. content.js throttles to <=1/sec per name, but
// we still fire-and-forget so a brief network blip never disturbs the page.
function notifySpeaker(name, active, t) {
  if (!name) return;
  const url = `${VOICE_SPEAKER_URL}?name=${encodeURIComponent(name)}&active=${active}&t=${t}`;
  fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, active, t }),
  }).catch(() => { /* Voice not running — silent. */ });
}

// Messages from content.js (SPA navigation, visibility change).
chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || !msg.type) return;
  if (msg.type === 'MEET_STATE') {
    notifyVoice(msg.active, msg.names || []);
  } else if (msg.type === 'MEET_NAMES_UPDATE') {
    // Late-arrival participant deltas — same endpoint as MEET_STATE so the
    // Swift side merges into recordingState.meetingParticipantNames.
    if (Array.isArray(msg.names) && msg.names.length > 0) {
      notifyVoice(true, msg.names);
    }
  } else if (msg.type === 'MEET_SPEAKER') {
    notifySpeaker(msg.name, msg.active, msg.t || Date.now());
  }
});

// Tab URL changes (full page loads / navigating away from a call platform entirely).
const CALL_HOSTS = ['meet.google.com', 'discord.com', 'teams.microsoft.com', 'teams.live.com', 'app.slack.com', 'web.whatsapp.com'];

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete' || !tab.url) return;
  try {
    if (!CALL_HOSTS.includes(new URL(tab.url).hostname)) return;
  } catch { return; }
  // Google Meet: URL alone tells us the state.
  if (tab.url.includes('meet.google.com')) {
    const active = /meet\.google\.com\/[a-z]+-[a-z]+-[a-z]+/.test(tab.url);
    notifyVoice(active);
  }
  // Other platforms: DOM-based detection in content.js handles state changes.
});

// When a Meet tab is closed while in a meeting, notify Voice to stop.
chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  // We don't know the URL of the removed tab here, but we can check if any
  // remaining meet.google.com tabs are still in a meeting.
  chrome.tabs.query({ url: 'https://meet.google.com/*' }, (tabs) => {
    const anyActive = tabs.some(t =>
      t.url && /meet\.google\.com\/[a-z]+-[a-z]+-[a-z]+/.test(t.url)
    );
    if (!anyActive) notifyVoice(false);
  });
});
