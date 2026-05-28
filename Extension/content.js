// Voice Meet Bridge — content script
// Detects active calls on: Google Meet, Discord web, MS Teams, Slack web.
// When a call becomes active, also scrapes participant names from the DOM
// and forwards them to background.js so the macOS app can build a title
// like "Night May 20th, Meet with Alice and Bob".

let inMeeting = false;

function detectCallActive() {
  const h = location.hostname;

  // Google Meet: meeting URL is meet.google.com/abc-defg-hij
  if (h === 'meet.google.com') {
    return /^\/[a-z]+-[a-z]+-[a-z]+/.test(location.pathname);
  }

  // Discord: voice/video call active = "Disconnect" button in DOM
  if (h === 'discord.com') {
    return !!(
      document.querySelector('[aria-label="Disconnect"]') ||
      document.querySelector('[class*="leaveButton"]') ||
      document.querySelector('button[class*="disconnect"]')
    );
  }

  // Microsoft Teams: in-call = hangup button visible
  if (h === 'teams.microsoft.com' || h === 'teams.live.com') {
    return !!(
      document.querySelector('[data-tid="hangup-button"]') ||
      document.querySelector('[aria-label*="Leave"]') ||
      document.querySelector('[id*="hangup"]')
    );
  }

  // Slack: huddle active = leave-huddle control visible
  if (h === 'app.slack.com') {
    return !!(
      document.querySelector('[data-qa="leave-huddle"]') ||
      document.querySelector('[aria-label*="Leave huddle"]')
    );
  }

  // WhatsApp Web: group video calls launched from the calls tab.
  // In-call = end-call button visible in the call UI.
  if (h === 'web.whatsapp.com') {
    return !!(
      document.querySelector('[data-testid="end-call-button"]') ||
      document.querySelector('[aria-label*="End call" i]') ||
      document.querySelector('[aria-label*="Leave call" i]')
    );
  }

  return false;
}

// ---------------------------------------------------------------------------
// Participant-name scraping. Each platform has its own selectors. All extractors
// are defensive: if Google/Discord/Teams/Slack changes their DOM, we just
// return an empty list and the macOS side falls back to transcript regex.
// ---------------------------------------------------------------------------

const SELF_MARKERS = [
  '(you)', '(You)', '(YOU)', 'you', 'You',
  '(host)', '(Host)', '(Me)', '(me)',
];

function looksLikeName(raw) {
  if (!raw) return false;
  const trimmed = String(raw).trim();
  if (trimmed.length < 2 || trimmed.length > 60) return false;
  // Reject things that are obviously not names.
  if (/^\d/.test(trimmed)) return false;
  if (/[@<>{}\[\]\\\/]/.test(trimmed)) return false;
  // Must contain at least one letter.
  if (!/[A-Za-zÀ-ÿ]/.test(trimmed)) return false;
  return true;
}

function cleanName(raw) {
  if (!raw) return '';
  let s = String(raw).trim();
  // Strip trailing self markers like "Michael (You)" → "Michael".
  for (const marker of SELF_MARKERS) {
    if (s.endsWith(marker)) s = s.slice(0, -marker.length).trim();
  }
  // Strip parenthetical role tags: "Alice (Host)" → "Alice".
  s = s.replace(/\s*\([^)]*\)\s*$/, '').trim();
  // Collapse internal whitespace.
  s = s.replace(/\s+/g, ' ');
  return s;
}

function isSelfMarker(raw) {
  if (!raw) return false;
  const s = String(raw).toLowerCase();
  return s.includes('(you)') || s.endsWith(' you') || s === 'you';
}

function scrapeGoogleMeetNames() {
  const names = new Set();

  // Strategy 1: dedicated self-name attribute that Meet sometimes exposes.
  document.querySelectorAll('[data-self-name]').forEach(el => {
    const n = cleanName(el.getAttribute('data-self-name'));
    if (looksLikeName(n)) names.add(n);
  });

  // Strategy 2: participant tiles in the video grid. Meet uses
  // [data-participant-id] on each tile; the visible name lives in a nested
  // element. Different Meet versions use different child selectors so we
  // grab the longest text node under the tile that looks like a name.
  document.querySelectorAll('[data-participant-id]').forEach(tile => {
    // Try common name-bearing nodes first.
    const candidates = tile.querySelectorAll(
      '[data-self-name], [class*="ZjFb7c"], [class*="zWGUib"], [jsname], div[role="button"] span'
    );
    let best = '';
    candidates.forEach(c => {
      const t = (c.textContent || '').trim();
      if (looksLikeName(t) && t.length > best.length && t.length < 60) {
        best = t;
      }
    });
    if (!best) {
      // Fallback: tile's own textContent, first non-empty short line.
      const lines = (tile.textContent || '').split('\n').map(s => s.trim()).filter(Boolean);
      for (const line of lines) {
        if (looksLikeName(line) && line.length < 60) { best = line; break; }
      }
    }
    if (!best) return;
    if (isSelfMarker(best)) return;
    const cleaned = cleanName(best);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });

  // Strategy 3: the People panel (right-hand sidebar). When open, each
  // participant row is a [role="listitem"] with the name as the first text node.
  document.querySelectorAll('[role="list"] [role="listitem"]').forEach(row => {
    const raw = (row.textContent || '').split('\n')[0].trim();
    if (!looksLikeName(raw)) return;
    if (isSelfMarker(raw)) return;
    const cleaned = cleanName(raw);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });

  return Array.from(names);
}

function scrapeDiscordNames() {
  const names = new Set();
  // Voice channel members appear in containers tagged with "voiceUser" / "voiceState".
  document.querySelectorAll(
    '[class*="voiceUser"], [class*="voiceState"], [class*="voice-user"], li[class*="member"]'
  ).forEach(el => {
    // Discord typically renders the username in a nested element with
    // "username" / "name" in its class. Fall back to el.textContent.
    const nameEl = el.querySelector('[class*="username"], [class*="name"]') || el;
    const raw = (nameEl.textContent || '').trim();
    if (!looksLikeName(raw)) return;
    if (isSelfMarker(raw)) return;
    const cleaned = cleanName(raw);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });
  return Array.from(names);
}

function scrapeTeamsNames() {
  const names = new Set();
  // Teams participant roster: each row has data-tid or aria attributes.
  document.querySelectorAll(
    '[data-tid="participant-item"], [data-tid*="roster-item"], [role="listitem"][aria-label]'
  ).forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const text = (el.textContent || '').trim();
    const raw = (aria || text).trim();
    if (!looksLikeName(raw)) return;
    if (isSelfMarker(raw)) return;
    const cleaned = cleanName(raw);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });
  return Array.from(names);
}

function scrapeSlackNames() {
  const names = new Set();
  // Slack huddle participants: each tile has data-qa with "huddle_participant"
  // or aria-label like "Alice (active)".
  document.querySelectorAll(
    '[data-qa*="huddle_participant"], [data-qa*="huddle-participant"], [aria-label*="huddle"]'
  ).forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const text = (el.textContent || '').trim();
    const raw = (aria || text).trim();
    if (!looksLikeName(raw)) return;
    if (isSelfMarker(raw)) return;
    const cleaned = cleanName(raw);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });
  return Array.from(names);
}

function scrapeWhatsAppNames() {
  const names = new Set();
  // WhatsApp Web call participant tiles. Selectors here are best-effort —
  // WhatsApp's DOM changes frequently and the test ids drift between releases.
  document.querySelectorAll(
    '[data-testid*="participant"], [data-testid*="call-participant"], [data-testid*="voip-participant"]'
  ).forEach(el => {
    const nameEl = el.querySelector('[data-testid*="name"], [class*="name"]') || el;
    const aria = el.getAttribute('aria-label') || '';
    const text = (nameEl.textContent || '').trim();
    const raw = (text || aria).trim();
    if (!looksLikeName(raw)) return;
    if (isSelfMarker(raw)) return;
    const cleaned = cleanName(raw);
    if (looksLikeName(cleaned)) names.add(cleaned);
  });
  return Array.from(names);
}

function scrapeParticipantNames() {
  try {
    const h = location.hostname;
    let names = [];
    if (h === 'meet.google.com') names = scrapeGoogleMeetNames();
    else if (h === 'discord.com') names = scrapeDiscordNames();
    else if (h === 'teams.microsoft.com' || h === 'teams.live.com') names = scrapeTeamsNames();
    else if (h === 'app.slack.com') names = scrapeSlackNames();
    else if (h === 'web.whatsapp.com') names = scrapeWhatsAppNames();

    // Dedupe (case-insensitive on the cleaned form) and cap at 20.
    const seen = new Set();
    const out = [];
    for (const n of names) {
      const key = n.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(n);
      if (out.length >= 20) break;
    }
    return out;
  } catch (e) {
    console.warn('[Voice] name scrape failed', e);
    return [];
  }
}

// ---------------------------------------------------------------------------
// Late-arrival participant poller (ALL platforms).
// On Google Meet, Discord, Teams, Slack, and WhatsApp Web the participant
// tiles often render 5–10 seconds AFTER the call goes "active", so the single
// scrape on the active=true transition usually catches an incomplete list.
// While in a meeting we re-scrape every 5s via scrapeParticipantNames() (which
// routes by hostname), track which names we've already shipped (case-
// insensitive), and only send the deltas.
// ---------------------------------------------------------------------------

const sentNamesLC = new Set();   // lowercase forms of names we've already POSTed
let lateNamesPoller = null;

function startLateNamesPoller() {
  if (lateNamesPoller) return;
  lateNamesPoller = setInterval(() => {
    if (!inMeeting) return;
    let fresh = [];
    try {
      const all = scrapeParticipantNames();
      for (const n of all) {
        const key = n.toLowerCase();
        if (sentNamesLC.has(key)) continue;
        sentNamesLC.add(key);
        fresh.push(n);
      }
    } catch (e) { /* ignore — best effort */ }
    if (fresh.length > 0) {
      chrome.runtime.sendMessage({
        type: 'MEET_NAMES_UPDATE',
        host: location.hostname,
        names: fresh,
      });
      console.log('[Voice]', location.hostname, '→ late participant names', fresh);
    }
  }, 5000);
}

function stopLateNamesPoller() {
  if (lateNamesPoller) {
    clearInterval(lateNamesPoller);
    lateNamesPoller = null;
  }
  sentNamesLC.clear();
}

// ---------------------------------------------------------------------------
// Active-speaker observer (Google Meet only).
// Meet visually highlights whichever tile is currently talking. Reading that
// signal lets us label transcript segments with a speaker name instead of the
// generic "MEETING" label. Heuristics — we look for a few stable signals on
// each [data-participant-id] tile:
//   - data-active-speaker="true" attribute (most reliable when present)
//   - aria-label containing "is speaking" / "is talking"
//   - a class containing "active" / "speaking" / "talking" anywhere in the tile
//   - a visible audio-meter element (jsname r4nke / VfPpkd-RLmnJb) with non-zero
//     height — Meet animates the bar height in proportion to voice level
// We're deliberately aggressive: false positives only mean we attach a name to
// a segment slightly more often than strictly correct; false negatives leave
// "MEETING" in place. Each name is throttled to at most one event per second.
// ---------------------------------------------------------------------------

const lastSpeakerEventAt = new Map(); // name lowercase → unix ms of last event
const SPEAKER_THROTTLE_MS = 1000;
let speakerObserver = null;
let speakerSweepInterval = null;
const activeSpeakerNamesLC = new Set(); // who we currently believe is speaking

function nameForTile(tile) {
  // Reuse the same logic as scrapeGoogleMeetNames but for ONE tile.
  const candidates = tile.querySelectorAll(
    '[data-self-name], [class*="ZjFb7c"], [class*="zWGUib"], [jsname], div[role="button"] span'
  );
  let best = '';
  candidates.forEach(c => {
    const t = (c.textContent || '').trim();
    if (looksLikeName(t) && t.length > best.length && t.length < 60) best = t;
  });
  if (!best) {
    const lines = (tile.textContent || '').split('\n').map(s => s.trim()).filter(Boolean);
    for (const line of lines) {
      if (looksLikeName(line) && line.length < 60) { best = line; break; }
    }
  }
  if (!best) return '';
  if (isSelfMarker(best)) return '';
  const cleaned = cleanName(best);
  return looksLikeName(cleaned) ? cleaned : '';
}

function tileLooksActive(tile) {
  // Stable: explicit attribute.
  if (tile.getAttribute('data-active-speaker') === 'true') return true;
  if (tile.querySelector('[data-active-speaker="true"]')) return true;
  // aria-label clues.
  const aria = tile.getAttribute('aria-label') || '';
  if (/is (speaking|talking)/i.test(aria)) return true;
  // Class-name clues anywhere within the tile subtree.
  const classy = tile.querySelector('[class*="active"], [class*="speaking"], [class*="talking"]');
  if (classy) {
    const cn = classy.className || '';
    if (typeof cn === 'string' && /active|speaking|talking/i.test(cn)) return true;
  }
  // Audio meter: jsname="r4nke" is the bar element Meet animates. If any
  // descendant has a non-zero offsetHeight, we treat the tile as active.
  const meters = tile.querySelectorAll('[jsname="r4nke"], [class*="VfPpkd-RLmnJb"]');
  for (const m of meters) {
    try {
      if (m.offsetHeight && m.offsetHeight > 2) return true;
    } catch { /* ignore */ }
  }
  return false;
}

function emitSpeakerEvent(name, active) {
  if (!name) return;
  const key = name.toLowerCase();
  const now = Date.now();
  const last = lastSpeakerEventAt.get(key) || 0;
  if (now - last < SPEAKER_THROTTLE_MS) return;
  lastSpeakerEventAt.set(key, now);
  chrome.runtime.sendMessage({
    type: 'MEET_SPEAKER',
    host: location.hostname,
    name,
    active,
    t: now,
  });
}

function sweepActiveSpeakers() {
  if (!inMeeting) return;
  if (location.hostname !== 'meet.google.com') return;
  const tiles = document.querySelectorAll('[data-participant-id]');
  const nowActiveLC = new Set();
  tiles.forEach(tile => {
    const name = nameForTile(tile);
    if (!name) return;
    if (tileLooksActive(tile)) nowActiveLC.add(name.toLowerCase());
  });
  // Emit "active=true" for new speakers.
  for (const tile of tiles) {
    const name = nameForTile(tile);
    if (!name) continue;
    const key = name.toLowerCase();
    if (nowActiveLC.has(key) && !activeSpeakerNamesLC.has(key)) {
      emitSpeakerEvent(name, true);
    }
  }
  // Emit "active=false" for speakers who stopped.
  for (const key of activeSpeakerNamesLC) {
    if (!nowActiveLC.has(key)) {
      // We have only the lowercase key — find a matching name from the tile sweep.
      let displayName = key;
      tiles.forEach(tile => {
        const name = nameForTile(tile);
        if (name && name.toLowerCase() === key) displayName = name;
      });
      emitSpeakerEvent(displayName, false);
    }
  }
  // Update the running set.
  activeSpeakerNamesLC.clear();
  for (const k of nowActiveLC) activeSpeakerNamesLC.add(k);
}

function startSpeakerObserver() {
  if (location.hostname !== 'meet.google.com') return;
  if (speakerObserver || speakerSweepInterval) return;
  try {
    speakerObserver = new MutationObserver(() => {
      // Throttle implicitly via the per-name 1s gate in emitSpeakerEvent.
      sweepActiveSpeakers();
    });
    speakerObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ['class', 'data-active-speaker', 'aria-label', 'style'],
      childList: true,
      subtree: true,
    });
  } catch (e) {
    console.warn('[Voice] speaker observer failed to attach', e);
  }
  // Belt + suspenders: poll every 750ms for the audio-meter case where the
  // bar height changes without a class/attribute change firing the observer.
  speakerSweepInterval = setInterval(sweepActiveSpeakers, 750);
}

function stopSpeakerObserver() {
  if (speakerObserver) {
    try { speakerObserver.disconnect(); } catch { /* ignore */ }
    speakerObserver = null;
  }
  if (speakerSweepInterval) {
    clearInterval(speakerSweepInterval);
    speakerSweepInterval = null;
  }
  // Make sure any still-active speakers get an "off" event so the Swift side
  // doesn't leave anyone "talking" after the meeting ends.
  for (const key of activeSpeakerNamesLC) emitSpeakerEvent(key, false);
  activeSpeakerNamesLC.clear();
  lastSpeakerEventAt.clear();
}

// ---------------------------------------------------------------------------
// Generic active-speaker observer for Discord, Teams, Slack, WhatsApp Web.
// Meet has its own bespoke observer (above) because of the audio-meter signal.
// For the other platforms the "is speaking" marker is purely a CSS class /
// aria-label flip on the participant tile, which a MutationObserver catches.
//
// setupActiveSpeakerObserver(speakingSelector, nameExtractor):
//   - speakingSelector: CSS selector matching elements that exist ONLY while a
//     participant is currently speaking. May match the tile itself or an inner
//     marker (we walk upward to find the nearest tile with a username).
//   - nameExtractor(speakingEl): given the matched element, return a cleaned
//     display name (or '' to skip).
//
// Each platform's setup returns a {disconnect} handle. We track currently
// speaking names in a Set per platform observer and emit active=false when
// the speaking marker disappears on the next sweep.
// ---------------------------------------------------------------------------

const genericObservers = []; // [{ disconnect, activeLC: Set }]

function setupActiveSpeakerObserver(speakingSelector, nameExtractor, platformLabel) {
  const activeLC = new Set();

  function sweep() {
    if (!inMeeting) return;
    let speakingEls = [];
    try {
      speakingEls = Array.from(document.querySelectorAll(speakingSelector));
    } catch (e) {
      console.warn('[Voice]', platformLabel, 'speaker selector failed', e);
      return;
    }
    const nowActiveLC = new Set();
    const nameByKey = new Map();
    for (const el of speakingEls) {
      let name = '';
      try { name = nameExtractor(el) || ''; } catch (e) { /* ignore one bad tile */ }
      if (!name) continue;
      const key = name.toLowerCase();
      nowActiveLC.add(key);
      if (!nameByKey.has(key)) nameByKey.set(key, name);
    }
    // Emit start events.
    for (const key of nowActiveLC) {
      if (!activeLC.has(key)) emitSpeakerEvent(nameByKey.get(key), true);
    }
    // Emit stop events for anyone who fell off.
    for (const key of activeLC) {
      if (!nowActiveLC.has(key)) emitSpeakerEvent(key, false);
    }
    activeLC.clear();
    for (const k of nowActiveLC) activeLC.add(k);

    // Warn (once-ish) if the platform appears in a call but the selector
    // returns nothing — likely the DOM changed and the selector broke.
    if (inMeeting && speakingEls.length === 0 && Math.random() < 0.02) {
      // ~2% sample rate to avoid spamming DevTools; user still sees it.
      console.warn('[Voice]', platformLabel, 'active-speaker selector matched zero elements');
    }
  }

  let observer = null;
  let sweepInterval = null;
  try {
    observer = new MutationObserver(sweep);
    observer.observe(document.body, {
      attributes: true,
      attributeFilter: ['class', 'aria-label', 'style', 'data-tid', 'data-cid', 'data-qa'],
      childList: true,
      subtree: true,
    });
  } catch (e) {
    console.warn('[Voice]', platformLabel, 'speaker observer failed to attach', e);
  }
  sweepInterval = setInterval(sweep, 750);

  return {
    disconnect() {
      if (observer) { try { observer.disconnect(); } catch { /* ignore */ } }
      if (sweepInterval) clearInterval(sweepInterval);
      // Emit off events for anyone still marked active so we don't strand them.
      for (const key of activeLC) emitSpeakerEvent(key, false);
      activeLC.clear();
    },
  };
}

// Walks up from a marker element to find the nearest "tile" container,
// then plucks a name out of [class*="username"] / [class*="name"] / aria-label.
function extractNearestName(el, tileSelector) {
  if (!el) return '';
  const tile = tileSelector ? (el.closest(tileSelector) || el) : el;
  // Prefer username/name child nodes.
  const nameEl = tile.querySelector('[class*="username"], [class*="name"], [data-testid*="name"]');
  let raw = '';
  if (nameEl) raw = (nameEl.textContent || '').trim();
  if (!raw) raw = (tile.getAttribute('aria-label') || '').trim();
  if (!raw) raw = (tile.textContent || '').trim();
  if (!raw) return '';
  if (isSelfMarker(raw)) return '';
  const cleaned = cleanName(raw);
  return looksLikeName(cleaned) ? cleaned : '';
}

function startDiscordSpeakerObserver() {
  // Discord adds a "speaking" class to the voice user's avatar wrapper.
  // We match either a tile flagged as speaking OR an inner marker.
  const handle = setupActiveSpeakerObserver(
    '[class*="voiceUser"] [class*="speaking"], [class*="voiceState"] [class*="speaking"], [class*="speaking"]:not(html):not(body)',
    (marker) => extractNearestName(marker, '[class*="voiceUser"], [class*="voiceState"], [class*="voice-user"], li[class*="member"]'),
    'discord',
  );
  genericObservers.push(handle);
}

function startTeamsSpeakerObserver() {
  const handle = setupActiveSpeakerObserver(
    '[data-tid*="participant"][class*="speaking"], [data-cid*="participant"][class*="active"], [aria-label*="speaking" i], [data-tid*="participant"][class*="active-speaker"]',
    (marker) => extractNearestName(marker, '[data-tid*="participant"], [data-cid*="participant"], [role="listitem"]'),
    'teams',
  );
  genericObservers.push(handle);
}

function startSlackSpeakerObserver() {
  const handle = setupActiveSpeakerObserver(
    '[class*="huddle_member--speaking"], [data-qa*="huddle_participant"][aria-label*="speaking" i], [data-qa*="huddle"] [class*="active"]',
    (marker) => extractNearestName(marker, '[data-qa*="huddle_participant"], [data-qa*="huddle"]'),
    'slack',
  );
  genericObservers.push(handle);
}

function startWhatsAppSpeakerObserver() {
  const handle = setupActiveSpeakerObserver(
    '[class*="speaking"], [data-testid*="participant"][class*="active"], [aria-label*="speaking" i]',
    (marker) => extractNearestName(marker, '[data-testid*="participant"], [data-testid*="call-participant"], [data-testid*="voip-participant"]'),
    'whatsapp',
  );
  genericObservers.push(handle);
}

function startPlatformSpeakerObservers() {
  try {
    const h = location.hostname;
    if (h === 'meet.google.com') {
      startSpeakerObserver();
    } else if (h === 'discord.com') {
      startDiscordSpeakerObserver();
    } else if (h === 'teams.microsoft.com' || h === 'teams.live.com') {
      startTeamsSpeakerObserver();
    } else if (h === 'app.slack.com') {
      startSlackSpeakerObserver();
    } else if (h === 'web.whatsapp.com') {
      startWhatsAppSpeakerObserver();
    }
  } catch (e) {
    console.warn('[Voice] failed to start platform speaker observer', e);
  }
}

function stopPlatformSpeakerObservers() {
  try {
    if (location.hostname === 'meet.google.com') {
      stopSpeakerObserver();
    }
  } catch { /* ignore */ }
  while (genericObservers.length) {
    const h = genericObservers.pop();
    try { h.disconnect(); } catch { /* ignore */ }
  }
}

function check() {
  const active = detectCallActive();
  if (active !== inMeeting) {
    inMeeting = active;
    const names = active ? scrapeParticipantNames() : [];
    if (active) {
      // Seed sentNamesLC with whatever we already shipped via MEET_STATE so
      // the poller doesn't immediately re-send them as deltas.
      for (const n of names) sentNamesLC.add(n.toLowerCase());
    }
    chrome.runtime.sendMessage({
      type: 'MEET_STATE',
      active,
      host: location.hostname,
      names,
    });
    console.log('[Voice]', location.hostname, active ? '→ call started' : '→ call ended', names.length ? `(participants: ${names.join(', ')})` : '');
    if (active) {
      startLateNamesPoller();
      startPlatformSpeakerObservers();
      // If we just entered an active call but found zero participants, warn so
      // the user can spot a broken scraper in DevTools without opening Voice.
      if (names.length === 0) {
        console.warn('[Voice]', location.hostname, 'call active but zero participants scraped — selectors may have drifted');
      }
    } else {
      stopLateNamesPoller();
      stopPlatformSpeakerObservers();
    }
  }
}

setInterval(check, 1500);
check();
document.addEventListener('visibilitychange', check);
