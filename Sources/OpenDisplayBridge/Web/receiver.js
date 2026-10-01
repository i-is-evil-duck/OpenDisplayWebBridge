/* OpenDisplay Web Receiver — pv 3 client over the WebSocket binding.
 * Implements PROTOCOL.md: hello-first, §4 demux heuristic, §5 Annex B video
 * with WebCodecs decode, §6 control messages, §7 coordinate spaces, §8 time
 * & liveness. Unknown message types and unknown fields are ignored (normative).
 */
'use strict';

// ---------- tiny DOM helpers ----------
const $ = id => document.getElementById(id);
const pairView = $('pair-view'), displayView = $('display-view');
const canvas = $('screen'), statsEl = $('stats'), banner = $('status-banner');
const cursorEl = $('cursor'), stage = $('stage');

const S = {
  ws: null,
  intentionalClose: false,
  reconnectDelay: 1000,
  reconnectTimer: null,
  pingTimer: null,
  watchdog: null,
  lastBytesAt: 0,
  decoder: null,
  decoderMode: null,          // 'annexb' | 'avcc'
  sps: null, pps: null,
  videoW: 0, videoH: 0,       // from SPS (authoritative, §5.2)
  chunkTs: 0,                 // synthetic monotonic timestamps (no PTS on wire)
  // Keyframe-recovery state. See `pollKeyframeRecovery`.
  sawVideo: false,            // any video bytes have arrived at all
  lastVideoAt: 0,             // when video bytes last arrived (not: decoded)
  lastFrameAt: 0,             // when a frame was last decoded
  lastKfRequestAt: 0,         // rate limit on `kf` requests
  kfRequests: 0,              // how many we have asked for this session
  // Cumulative, unlike `stats.frames` which is zeroed every second to compute a
  // rate. "Has this session ever decoded a frame?" needs the opposite.
  totalFrames: 0,
  clockSamples: [],           // {rtt, offset}
  clockOffset: null,          // sender-clock - receiver-clock (ms)
  pendingTouch: null,
  sendingMoves: false,
  cursorImgReady: false,
  touchSent: 0,            // touch messages actually sent to the bridge
  lastTouch: null,         // the most recent one, for the diag report
  cursorVisible: false,     // is the sender currently drawing a cursor
  hideChrome: false,       // native iOS video player is up; overlays cannot draw
  fsMode: null,            // 'page' | 'video' | null
  caps: null,
  fatal: null,
  rtc: null,
  // Live video path and decoder, as reported by the bridge in `bridgeStatus`.
  // Both are null until the bridge says something, which is itself informative:
  // a session that never receives one is a session that never got going.
  bridgeMode: null,
  bridgeDecoder: null,
  bridgeReason: null,
  senderConnected: null,
  // WebRTC counters. `rtcPrev*` hold the previous `getStats()` reading so a
  // delta can be computed; both are cumulative over one peer connection's life.
  rtcPrevFrames: 0,
  rtcPrevBytes: 0,
  rtcSize: null,
  rtcStatsSeen: null,      // null = not polled yet, false = unsupported here
  displayedFrames: 0,       // frames the <video> actually presented
  stats: { bytes: 0, frames: 0, t0: 0, fps: 0, mbps: 0, e2e: [], stalls: 0, drops: 0 },
  wakeLock: null,
  streamInfo: null,
  hideTimer: null,
};

const nowMs = () => Date.now();
const senderNow = () => nowMs() + (S.clockOffset || 0);

// ---------- pairing ----------
async function submitPair() {
  const code = $('code-input').value.trim();
  $('pair-error').textContent = '';
  if (!/^\d{6}$/.test(code)) { $('pair-error').textContent = 'Enter the 6-digit code.'; return; }
  $('pair-btn').disabled = true;
  try {
    const r = await fetch('/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code }),
    });
    if (!r.ok) { $('pair-error').textContent = 'Wrong code.'; $('pair-btn').disabled = false; return; }
    pairView.style.display = 'none';
    displayView.style.display = 'block';
    connect();
  } catch (e) {
    $('pair-error').textContent = 'Cannot reach the Mac. Same WiFi?';
    $('pair-btn').disabled = false;
  }
}
$('pair-btn').addEventListener('click', submitPair);
$('code-input').addEventListener('keydown', e => { if (e.key === 'Enter') submitPair(); });

// ---------- WebSocket binding: 1 binary message = 1 OD frame ----------
function connect() {
  setBanner('Connecting…');
  // Record capabilities now, not lazily in `ensureDecoder`. The overlay's caps
  // line is the thing that answers "why is this machine on that path?", and it
  // was previously only populated once the first video frame arrived — so it was
  // blank for exactly the sessions where the question mattered.
  S.caps = deviceCaps();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/od`);
  S.ws = ws;
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    S.reconnectDelay = 1000;
    sendHello();
    startPing();
    requestWakeLock();
    // No WebCodecs means this device cannot decode the H.264 the bridge
    // forwards, so ask for a WebRTC/VP8 stream instead (WEBRTC_PLAN.md W1/W2).
    // Additive hello fields: PROTOCOL.md 6 requires unknown fields be ignored,
    // so an older bridge simply never switches mode.
    if (hasWebCodecs()) {
      // Surfaced so a stalled session is visible instead of silent: a receiver
      // that paired but never renders shows nothing at all otherwise.
      setBanner('connected — waiting for video…', 4000);
    } else if (rtcCapable()) {
      setBanner('no WebCodecs — requesting a WebRTC stream…', 0);
      startWebRTC();
    } else {
      setBanner('This device can neither WebCodecs nor WebRTC — no video path.', 0);
      S.fatal = 'no-decode-path';
    }
  };
  ws.onmessage = ev => {
    S.lastBytesAt = nowMs();
    const buf = new Uint8Array(ev.data);
    if (isControl(buf)) onControl(buf); else onVideo(buf);
  };
  ws.onclose = () => {
    teardown();
    if (!S.intentionalClose) scheduleReconnect('Connection lost');
  };
  ws.onerror = () => { /* onclose follows */ };
}

function scheduleReconnect(msg) {
  setBanner(`${msg} — retrying in ${Math.round(S.reconnectDelay / 1000)}s`);
  clearTimeout(S.reconnectTimer);
  S.reconnectTimer = setTimeout(connect, S.reconnectDelay);
  S.reconnectDelay = Math.min(S.reconnectDelay * 2, 10000);
}

function teardown() {
  clearInterval(S.pingTimer); S.pingTimer = null;
  clearInterval(S.watchdog); S.watchdog = null;
  clearTimeout(S.reconnectTimer);
  if (S.decoder) { try { S.decoder.close(); } catch (_) {} S.decoder = null; }
  S.clockOffset = null; S.clockSamples = [];
  S.wakeLock = null;

  // The peer connection belongs to the socket that just died, so it goes with
  // it. `startWebRTC` bails on `if (S.rtc) return;`, so leaving this set meant a
  // reconnect kept a dead RTCPeerConnection forever: `onopen` called
  // startWebRTC, it returned immediately, no `rtcOffer` was ever sent again, and
  // the session sat there with a black screen and a healthy-looking WebSocket.
  // The only recovery was a manual reload — on the old iPads, the one device
  // that takes this path, which is also the one that reconnects most (sleep,
  // Wi-Fi roam). Every field below is reset for the same reason.
  if (S.rtc) {
    try { S.rtc.ontrack = null; } catch (_) {}
    try { S.rtc.oniceconnectionstatechange = null; } catch (_) {}
    try { S.rtc.close(); } catch (_) {}
    S.rtc = null;
  }
  rtcEl.srcObject = null;
  S.rtcPrevFrames = 0;
  S.rtcPrevBytes = 0;
  S.rtcSize = null;
  S.rtcStatsSeen = null;
  S.displayedFrames = 0;
  playAttempts = 0;
  if (playRetryTimer) { clearTimeout(playRetryTimer); playRetryTimer = null; }
  // The bridge picks a mode per session and announces it in `bridgeStatus`, so
  // the previous session's answer must not be reported as this one's.
  S.bridgeMode = null;
  S.bridgeDecoder = null;
  S.bridgeReason = null;
  S.senderConnected = null;
  S.totalFrames = 0;
  S.sawVideo = false;
  S.lastFrameAt = 0;
  S.lastVideoAt = 0;
  S.kfRequests = 0;
  S.lastKfRequestAt = 0;
}

// The binding is BINARY-ONLY: one WS binary message carries one OD frame, and
// the server drops text frames outright. `ws.send(string)` would emit a text
// frame, so every control message was silently discarded and the receiver sat
// in a connect/watchdog/reconnect loop. Encode to bytes and send an ArrayBuffer.
function wsSend(obj) {
  if (S.ws && S.ws.readyState === WebSocket.OPEN) {
    S.ws.send(new TextEncoder().encode(JSON.stringify(obj)));
  }
}

// ---------- §6.1 hello ----------
function stableId() {
  // PROTOCOL.md s.2.1: the `id` here MUST equal the Bonjour TXT `id` the
  // adapter advertises, so a sender can recognise the same device across
  // transports and renames. When the Mac injected one, prefer it.
  if (window.OD_ADVERTISED_ID) return window.OD_ADVERTISED_ID;
  let id = localStorage.getItem('od-id');
  if (!id) { id = crypto.randomUUID ? crypto.randomUUID() : String(nowMs()) + Math.random(); localStorage.setItem('od-id', id); }
  return id;
}

function sendHello() {
  const w = Math.round(window.innerWidth * window.devicePixelRatio);
  const h = Math.round(window.innerHeight * window.devicePixelRatio);
  // §6.5: the receiver advertises the largest stream it can actually sustain,
  // and the sender scales down to fit while keeping the desktop at panel size.
  //
  // The ceiling depends on the path. With WebCodecs the pixels never touch the
  // Mac, so a full 1080p stream is fine. On the WebRTC fallback the bridge
  // DECODES H.264 and RE-ENCODES it in software (libvpx VP8) on every frame,
  // so throughput collapses at high resolutions: at 782x1080 the encode
  // stalls the relay's read loop, the browser's 5 s liveness watchdog fires,
  // and the session reconnects in a loop. Cap it, and cap the rate too.
  const base = baseResolution();
  // The settings multiplier scales the per-path default, so "auto" and an
  // explicit choice cannot disagree. Rounding lives in capsWidth/capsHeight.
  const maxW = capsWidth();
  const maxH = capsHeight();
  const maxFps = base.fps;

  wsSend({
    type: 'hello',
    pixelsWide: w, pixelsHigh: h,
    scale: window.devicePixelRatio,
    device: /iPad/.test(navigator.userAgent) ? 'iPad' : (/iPhone/.test(navigator.userAgent) ? 'iPhone' : 'browser'),
    id: stableId(),
    pv: 3,
    displayMaxFrameRate: 60,
    maxEncodeWide: maxW, maxEncodeHigh: maxH,
    videoCaps: [{ codec: 'h264', maxWidth: maxW, maxHeight: maxH, maxFrameRate: maxFps,
                  maxPixelsPerSecond: maxW * maxH * maxFps }],
    // What this device can actually decode. The bridge reads these to choose
    // between forwarding H.264 untouched and transcoding to WebRTC/VP8.
    webcodecs: hasWebCodecs(),
    rtc: rtcCapable(),
  });
}

let helloDebounce = null;
window.addEventListener('resize', () => {
  clearTimeout(helloDebounce);
  helloDebounce = setTimeout(() => { if (S.ws && S.ws.readyState === WebSocket.OPEN) sendHello(); }, 300);
});

// ---------- §4 demux: JSON control iff <32768, starts with '{', no NUL ----------
function isControl(buf) {
  if (buf.length >= 32768 || buf.length === 0 || buf[0] !== 0x7B) return false;
  for (let i = 0; i < buf.length; i++) if (buf[i] === 0) return false;
  return true;
}

// ---------- diagnostics ----------
//
// The receiver is the only place some failures are visible, and on a phone or
// tablet its console is invisible. So it reports its own state to the bridge,
// which logs it alongside the Mac-side view. The two together are what make a
// WebRTC failure diagnosable: the Mac can prove it decoded and sent, and the
// receiver can prove what arrived and what the video element did with it.
//
// A `diag` message is a bridge-only type. PROTOCOL.md 6.1 requires a receiver's
// message types the sender does not know to be ignored, and the bridge consumes
// this one rather than forwarding it, so the sender never sees it.
const diagErrors = [];
window.addEventListener('error', ev => {
  diagErrors.push(`${ev.message} @ ${ev.filename}:${ev.lineno}`);
  if (diagErrors.length > 10) diagErrors.shift();
});
window.addEventListener('unhandledrejection', ev => {
  diagErrors.push('unhandled rejection: ' + (ev.reason && ev.reason.message ? ev.reason.message : ev.reason));
  if (diagErrors.length > 10) diagErrors.shift();
});

function collectDiag() {
  const d = {
    type: 'diag',
    ua: navigator.userAgent.slice(0, 120),
    secure: window.isSecureContext,
    hasVideoDecoder: typeof VideoDecoder !== 'undefined',
    forcedNoCodecs: forceNoCodecs(),
    mode: S.bridgeMode || (S.rtc ? 'webRTC' : 'webcodecs'),
    bridgeDecoder: S.bridgeDecoder || null,
    // The resolution actually being requested, so a settings change is verifiable
    // from the Mac's log rather than something the user has to take on trust.
    resMul: String(S.resMul), maxW: capsWidth(), maxH: capsHeight(),
    // Input side. `touchSent` is the one counter that settles "did my tap even
    // leave the browser", which is otherwise indistinguishable from "the sender
    // ignored it" — both look like nothing happening. `lastTouch` shows the
    // coordinates as they went on the wire, so a null or absurd value is visible
    // without having to attach a debugger to a phone.
    touchSent: S.touchSent, lastTouch: S.lastTouch,
    inputSurface: activeSurface().id,
    inputRect: (r => ({ w: Math.round(r.width), h: Math.round(r.height) }))(
      activeSurface().getBoundingClientRect()),
    // Demux / decode side
    sawVideo: S.sawVideo, totalFrames: S.totalFrames, kfRequests: S.kfRequests,
    decoderMode: S.decoderMode || null,
    decoderState: S.decoder ? S.decoder.state : null,
    decodeQueueSize: S.decoder ? S.decoder.decodeQueueSize : null,
    hasSps: !!S.sps, hasPps: !!S.pps,
    spsLen: S.sps ? S.sps.length : 0,
    videoW: S.videoW, videoH: S.videoH,
    fatal: S.fatal || null,
    senderConnected: S.senderConnected,
    // Liveness
    bytesSinceLast: Math.round((nowMs() - S.lastBytesAt) / 100) / 10,
    videoSinceLast: S.sawVideo ? Math.round((nowMs() - S.lastVideoAt) / 100) / 10 : null,
    frameSinceLast: S.totalFrames ? Math.round((nowMs() - S.lastFrameAt) / 100) / 10 : null,
    errors: diagErrors.slice(),
  };

  // WebRTC: everything needed to tell "no packets arrived" from "packets arrived
  // and the element would not show them".
  if (S.rtc) {
    const pc = S.rtc;
    d.rtc = {
      conn: pc.connectionState, ice: pc.iceConnectionState, sig: pc.signalingState,
      displayedFrames: S.displayedFrames,
      video: {
        readyState: rtcEl.readyState, paused: rtcEl.paused, ended: rtcEl.ended,
        w: rtcEl.videoWidth, h: rtcEl.videoHeight,
        t: Math.round(rtcEl.currentTime * 10) / 10,
        err: rtcEl.error ? { code: rtcEl.error.code, msg: rtcEl.error.message } : null,
        netState: rtcEl.networkState,
        hasSrc: !!rtcEl.srcObject,
      },
    };
    if (rtcEl.srcObject) {
      d.rtc.tracks = rtcEl.srcObject.getTracks().map(t => ({
        kind: t.kind, id: (t.id || '').slice(0, 8), muted: t.muted,
        readyState: t.readyState, enabled: t.enabled,
      }));
    }

    // Is the picture actually *visible*? readyState 4 and an advancing
    // currentTime prove it decoded and is playing, but not that anything is on
    // screen — the element could be zero-sized, hidden behind an overlay, or
    // covered by the cursor layer. This was the one thing the diagnostics could
    // not distinguish: a healthy pipeline showing a black picture, and a healthy
    // pipeline hidden behind something, look identical from the codec side.
    const rect = rtcEl.getBoundingClientRect();
    d.rtc.visible = {
      display: getComputedStyle(rtcEl).display,
      visibility: getComputedStyle(rtcEl).visibility,
      opacity: getComputedStyle(rtcEl).opacity,
      cssW: Math.round(rect.width), cssH: Math.round(rect.height),
      cssLeft: Math.round(rect.left), cssTop: Math.round(rect.top),
      inStage: rtcEl.parentElement ? rtcEl.parentElement.id : null,
      canvasDisplay: getComputedStyle(canvas).display,
    };
    // What is actually painted at the middle of the stage? If this is not the
    // video element, something is covering it.
    const cx = Math.round(rect.left + rect.width / 2);
    const cy = Math.round(rect.top + rect.height / 2);
    const top = (cx >= 0 && cy >= 0)
      ? document.elementFromPoint(cx, cy) : null;
    d.rtc.onTop = top ? ((top.id || '') + (top.tagName || '')) : 'none';
    d.rtc.onTopIsVideo = (top === rtcEl);
    // Spec-compliant getStats, best effort — absent on Safari 12.
    try {
      const p = pc.getStats();
      if (p && typeof p.then === 'function') {
        p.then(r => {
          const v = [];
          r.forEach(s => { if (s && (s.type === 'inbound-rtp' || s.type === 'candidate-pair')) v.push(s); });
          if (v.length) wsSend({ type: 'diag', rtcStats: v.slice(0, 4) });
        }).catch(() => {});
      }
    } catch (_) {}
  }
  return d;
}

let diagCounter = 0;
setInterval(() => {
  if (!S.ws || S.ws.readyState !== WebSocket.OPEN) return;
  // Every 5th one carries the full payload, to keep the log readable.
  diagCounter += 1;
  if (diagCounter % 3 !== 0) return;
  wsSend(collectDiag());
}, 2000);

// ---------- §6 control messages ----------
function onControl(buf) {
  let msg;
  try { msg = JSON.parse(new TextDecoder().decode(buf)); } catch (_) { return; }
  if (!msg || typeof msg.type !== 'string') return;   // unparseable => ignore, not fatal
  switch (msg.type) {
    case 'welcome':
      S.senderPv = msg.pv || 1;
      break;
    case 'streamConfig':
      S.streamInfo = msg;   // informational; SPS remains authoritative (§5.2)
      break;
    case 'pong': {
      const t2 = nowMs();
      const rtt = t2 - msg.t;
      if (rtt >= 0 && rtt < 2000) {
        S.clockSamples.push({ rtt, offset: msg.mt - (msg.t + t2) / 2 });
        if (S.clockSamples.length > 15) S.clockSamples.shift();
        const best = S.clockSamples.reduce((a, b) => (b.rtt < a.rtt ? b : a));
        S.clockOffset = best.offset;
      }
      break;
    }
    case 'ping':   // sender health beat — liveness only, no reply (§6.2)
      break;
    case 'bridgeStatus':
      // Bridge-originated (not part of the sender's protocol): which video path
      // and decoder the bridge actually settled on. Without it a black screen
      // has no cause, because every symptom looks the same from here.
      S.bridgeMode = typeof msg.mode === 'string' ? msg.mode : S.bridgeMode;
      S.bridgeDecoder = typeof msg.decoder === 'string' ? msg.decoder : S.bridgeDecoder;
      S.bridgeReason = typeof msg.reason === 'string' ? msg.reason : S.bridgeReason;
      S.senderConnected = !!msg.senderConnected;

      // Conditions are re-evaluated on every status, not latched, so a banner
      // clears itself when the condition it reports stops being true. A sticky
      // "no sender connected" left up after the sender arrives is worse than no
      // banner: it tells the user the opposite of what is happening.
      if (S.bridgeMode === 'webRTC' && !S.senderConnected) {
        setBanner('bridge: no OpenDisplay sender connected', 0);
      } else if (S.bridgeReason && /unavailable|falling back|no frame/i.test(S.bridgeReason)) {
        setBanner('bridge: ' + S.bridgeReason, 0);
      } else if (/^(bridge: no OpenDisplay sender connected|rtc:)/.test(banner.textContent)) {
        setBanner('');
      }
      break;
    case 'cursor': {
      if (!msg.v) { S.cursorVisible = false; updateCursorVisibility(); break; }
      // Position against whichever element is actually on screen.
      //
      // It used to be the canvas, always. But the WebRTC path hides the canvas
      // (`display: none`) and shows the <video> instead, and a display:none
      // element has an all-zero rect — so every cursor update placed the cursor
      // at 0,0 and it looked like the cursor had stopped rendering entirely.
      // That is why the cursor worked on the passthrough path and vanished on
      // the WebRTC one.
      const r = activeSurface().getBoundingClientRect();
      if (!r.width || !r.height) break;   // not laid out yet; a later update will place it
      S.cursorVisible = true;
      updateCursorVisibility();
      cursorEl.style.left = (msg.x * r.width) + 'px';
      cursorEl.style.top = (msg.y * r.height) + 'px';
      break;
    }
    case 'cursorImg': {
      // Same surface choice as `cursor` above: on the WebRTC path the canvas is
      // hidden and has a zero rect, which would scale the sprite to 0x0 and
      // make the cursor invisible even once it was positioned correctly.
      const r = activeSurface().getBoundingClientRect();
      if (!r.width || !r.height) break;
      cursorEl.src = 'data:image/png;base64,' + msg.png;
      cursorEl.style.width = (msg.nw * r.width) + 'px';
      cursorEl.style.height = (msg.nh * r.height) + 'px';
      cursorEl.style.transform = `translate(${-msg.ax * 100}%, ${-msg.ay * 100}%)`;
      cursorEl.onload = () => { S.cursorImgReady = true; updateCursorVisibility(); };
      break;
    }
    case 'rtcAnswer':
      onRTCAnswer(msg);
      break;
    case 'updateRequired':
      setBanner('Update required: ' + (msg.message || 'please update the Mac app'));
      break;
    default:
      break;  // normative: ignore unknown types
  }
}

// ---------- settings ----------
//
// Persisted in localStorage, because all three of these are things a user
// changes once and then expects to stay changed — and re-discovering that the
// debug overlay is on, or that the resolution is wrong, on every page load would
// be tedious.
//
// The debug overlay is off by default. It was previously always-on, which is
// defensible while developing and wrong in front of a user: a wall of counters
// over the picture is the first thing anyone complains about, and on a tablet it
// covers a quarter of the screen. It is also how every real bug in this project
// was found, so it stays one tap away rather than being removed.
// Resolution multiplier options, and the one used when nothing is stored.
//
// `1` used to be labelled "Auto" because the per-path base is a tuned default
// rather than a measured one. That label was doing no work: `capsWidth()` is
// literally `base × resMul`, so at 1× the cap *is* the base, which is what
// "auto" resolved to anyway. The two were the same number wearing two names, so
// they are one option now and the readout reports the actual resolution.
//
// 2× is the default because 1× is visibly soft on the target iPad: 640×360
// upscaled to a 1024-wide screen is a blurry picture, and that is the path the
// iPad actually takes. 2× lands on 1280×720, which the software VP8 encoder can
// still carry.
const RES_MULS = ['1', '2', '3', '4'];
const DEFAULT_RES_MUL = '2';

const SETTINGS_KEY = 'od.settings.v1';

function loadSettings() {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (raw) {
      const s = Object.assign({ debug: false, resMul: DEFAULT_RES_MUL }, JSON.parse(raw));
      // A stored multiplier from an older build may no longer be offered. Left
      // alone it would apply a scale the settings panel has no button for, so
      // nothing is highlighted and the number is unexplained; and the readouts
      // would render a resolution nobody chose. Fall back to the default and
      // rewrite the stored value so it stops disagreeing with the UI.
      if (RES_MULS.indexOf(String(s.resMul)) < 0) s.resMul = DEFAULT_RES_MUL;
      return s;
    }
  } catch (_) {}
  return { debug: false, resMul: DEFAULT_RES_MUL };
}

function saveSettings(s) {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(s)); } catch (_) {}
}

const settings = loadSettings();
S.showDebug = !!settings.debug;
S.resMul = settings.resMul;

const settingsEl = $('settings');
const gearBtn = $('gear-btn');

function setSettingsOpen(open) {
  settingsEl.style.display = open ? 'block' : 'none';
  S.settingsOpen = !!open;
}

if (gearBtn) {
  gearBtn.addEventListener('click',
    () => setSettingsOpen(settingsEl.style.display !== 'block'));
}
const closeBtn = $('set-close');
if (closeBtn) closeBtn.addEventListener('click', () => setSettingsOpen(false));

// Debug toggle.
function applyDebugVisibility() {
  statsEl.style.display = S.showDebug ? 'block' : 'none';
  const row = $('set-debug');
  if (row) row.classList.toggle('on', S.showDebug);
}
const debugRow = $('set-debug');
if (debugRow) {
  debugRow.addEventListener('click', () => {
    S.showDebug = !S.showDebug;
    settings.debug = S.showDebug;
    saveSettings(settings);
    applyDebugVisibility();
  });
}

// The path's default ceiling, in one place so the settings readout and the
// hello cannot disagree about what "auto" means.
function baseResolution() {
  const webrtcOnly = !hasWebCodecs() && rtcCapable();
  return webrtcOnly
    ? { w: 640, h: 360, fps: 15 }
    : { w: 1920, h: 1080, fps: 30 };
}

// The multiplier applied to that base, rounded per axis to even because H.264
// 4:2:0 requires even dimensions. One implementation, used by the hello, the
// settings readout and the diagnostics, so the three cannot drift apart.
function capsWidth() {
  const b = baseResolution();
  return Math.round(b.w * (Number(S.resMul) || 1) / 2) * 2;
}
function capsHeight() {
  const b = baseResolution();
  return Math.round(b.h * (Number(S.resMul) || 1) / 2) * 2;
}

// Resolution multiplier.
//
// Scales `maxEncodeWide`/`maxEncodeHigh` in the hello, which is what the Mac
// encodes at. It is a *ceiling*, not a target: the sender encodes at the smaller
// of this and its own screen, so a multiplier beyond the Mac's display changes
// nothing rather than asking for an impossible frame. The setting readout always
// shows the resulting resolution, so this is visible rather than inferred.
//
// Changing it re-sends hello, so the Mac re-evaluates on its next capture. It
// does not renegotiate the peer connection — resolution is the sender's choice
// and libwebrtc's encoder adapts to whatever arrives.
//
// RES_MULS and DEFAULT_RES_MUL are declared with the settings block, above
// loadSettings, which needs the list to validate what it reads back.

function applyResButtons() {
  const seg = $('set-res');
  if (seg) {
    seg.querySelectorAll('button').forEach(b => {
      b.classList.toggle('on', b.dataset.m === String(S.resMul));
    });
  }
  const val = $('set-res-val');
  if (!val) return;
  val.textContent = `${capsWidth()}×${capsHeight()}  (${S.resMul}×)`;
}

const resSeg = $('set-res');
if (resSeg) {
  resSeg.addEventListener('click', ev => {
    const btn = ev.target && ev.target.closest ? ev.target.closest('button') : null;
    if (!btn || !btn.dataset || !btn.dataset.m) return;
    if (RES_MULS.indexOf(btn.dataset.m) < 0) return;
    S.resMul = btn.dataset.m;
    settings.resMul = S.resMul;
    saveSettings(settings);
    applyResButtons();
    // The hello carries the caps, so re-sending it is what actually makes the
    // Mac change resolution.
    if (S.ws && S.ws.readyState === WebSocket.OPEN) sendHello();
    setBanner('resolution: ' + btn.dataset.m + '×', 2000);
  });
}

const refreshBtn = $('set-refresh');
if (refreshBtn) {
  refreshBtn.addEventListener('click', () => {
    // A full reload is the honest way to renegotiate: the peer connection, the
    // decoder and the session token are entangled, and rebuilding them piecemeal
    // is how two receivers end up livelocking.
    S.intentionalClose = true;
    location.reload();
  });
}

applyDebugVisibility();
applyResButtons();

// ---------- §8.1/8.2 time & liveness ----------
function startPing() {
  clearInterval(S.pingTimer);
  S.pingTimer = setInterval(() => wsSend({ type: 'ping', t: nowMs() }), 2000);
  clearInterval(S.watchdog);
  S.lastBytesAt = nowMs();
  S.watchdog = setInterval(() => {
    if (nowMs() - S.lastBytesAt > 5000 && S.ws && S.ws.readyState === WebSocket.OPEN) {
      S.ws.close();   // let onclose drive reconnect
    }
  }, 1000);
}

// ---------- device capability probe ----------
// WebCodecs VideoDecoder shipped in Safari/iOS 16.4 (not 15.4 — the earlier
// claim in this file and in implementationplan.md was a full major version
// out). Safari 16.4-18.7 is PARTIAL support: the video interfaces exist but
// annexb H.264 handling is not dependable, so the avcc path below is the one
// that actually carries old iPads. Probe instead of assuming.
//
// `?nocodecs=1` forces the fallback path. Without it the WebRTC route is
// untestable on any modern browser, since nothing else declines WebCodecs.
function forceNoCodecs() {
  return /[?&]nocodecs=1/.test(location.search);
}
function hasWebCodecs() {
  return !forceNoCodecs() && typeof VideoDecoder !== 'undefined';
}
function rtcCapable() {
  return typeof RTCPeerConnection !== 'undefined';
}

function deviceCaps() {
  const ua = navigator.userAgent;
  // The iOS regexes only fire on iOS, so a Mac or a Windows laptop reported
  // "iOS ?" — which is exactly the line someone needs to read to work out why
  // their machine took the WebRTC path, and it told them nothing. Match the
  // platform and report the browser separately.
  const ios = /OS (\d+)[._](\d+)/.exec(ua);
  const macOS = /Mac OS X (\d+)[._](\d+)/.exec(ua);
  const android = /Android (\d+)/.exec(ua);
  const chromium = /Chrome\/(\d+)/.exec(ua);
  const safari = /Version\/(\d+)[.](\d+)/.exec(ua);
  const firefox = /Firefox\/(\d+)/.exec(ua);

  let os;
  if (ios) os = `iOS ${ios[1]}.${ios[2]}`;
  else if (android) os = `Android ${android[1]}`;
  else if (macOS) os = `macOS ${macOS[1]}.${macOS[2]}`;
  else os = 'unknown OS';

  let browser;
  if (firefox) browser = `Firefox ${firefox[1]}`;
  else if (chromium && !safari) browser = `Chrome ${chromium[1]}`;
  else if (safari) browser = `Safari ${safari[1]}.${safari[2]}`;
  else browser = 'unknown browser';

  return {
    os,
    browser,
    webcodecs: hasWebCodecs(),
    forced: forceNoCodecs(),
    rtc: rtcCapable(),
    mse: typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E"'),
    ua: ua.slice(0, 120),
  };
}

function capsText(c) {
  return `iOS ${c.os} · WebCodecs ${c.webcodecs ? 'yes' : 'no'} · MSE ${c.mse ? 'yes' : 'no'}`;
}

// ---------- §5 video ----------
function findStartCode4(buf) {
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 0 && buf[i + 3] === 1) return i;
  }
  return -1;
}

function splitNalus(buf) {
  const starts = [];
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 0 && buf[i + 3] === 1) starts.push(i);
  }
  return starts.map((s, idx) => buf.subarray(s + 4, idx + 1 < starts.length ? starts[idx + 1] : buf.length));
}

// Minimal SPS parser: profile/level for the codec string, dimensions for config.
//
// The dimensions it returns are *display* dimensions in pixels, which is not the
// same as what the bitstream literally stores. Two things were missing before,
// and both were silent:
//
//   1. `pic_width_in_mbs_minus1` / `pic_height_in_map_units_minus1` count
//      MACROBLOCKS, so they must be multiplied by 16. Returning them raw made a
//      992x1088 capture report "62x68" — and those numbers were being used to
//      scale §7 touch coordinates, so every touch landed in the wrong place by a
//      factor of sixteen.
//   2. The frame cropping block, which is how a size that is not a multiple of 16
//      is expressed. Without it the parser reports the coded size, not the size
//      the sender is actually displaying.
//
// The canvas does not use these (it takes each decoded frame's own dimensions),
// so the picture was never wrong — but touch was, silently.
function parseSPS(sps) {
  if (sps.length < 4) return null;
  const profile = sps[1], compat = sps[2], level = sps[3];
  const codec = 'avc1.' + [profile, compat, level].map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
  // Exp-Golomb walk to width/height (handles common cases; falls back to streamConfig).
  try {
    const rbsp = [];
    for (let i = 0; i < sps.length; i++) {   // strip emulation prevention bytes
      if (i >= 2 && sps[i] === 3 && sps[i - 1] === 0 && sps[i - 2] === 0) continue;
      rbsp.push(sps[i]);
    }
    const bits = [];
    for (let i = 0; i < rbsp.length; i++) for (let b = 7; b >= 0; b--) bits.push((rbsp[i] >> b) & 1);
    let pos = 8 + 24;      // NAL header + profile_idc(8) + constraints(8) + level(8)
    const u = n => { let v = 0; for (let i = 0; i < n; i++) v = (v << 1) | bits[pos++]; return v; };
    const ue = () => { let z = 0; while (pos < bits.length && bits[pos] === 0) { z++; pos++; } pos++; return (1 << z) - 1 + u(z); };
    const se = () => { const k = ue(); return k & 1 ? (k + 1) / 2 : -(k / 2); };
    ue();                   // seq_parameter_set_id
    const profileIdc = rbsp[1];
    // chroma_format_idc, needed for the crop units below. Defaults to 1 (4:2:0)
    // when the profile does not carry it explicitly.
    let chromaFormat = 1;
    if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profileIdc)) {
      chromaFormat = ue();
      if (chromaFormat === 3) pos += 1;   // separate_colour_plane_flag
      ue(); ue(); pos += 1;   // bit_depth_luma-8, bit_depth_chroma-8, qpprime
      if (bits[pos++]) {      // seq_scaling_matrix_present
        const n = chromaFormat !== 3 ? 8 : 12;
        for (let i = 0; i < n; i++) if (bits[pos++]) { let s = 8; do { s += se(); } while (s !== 0 && s !== 64); }
      }
    }
    ue();                   // log2_max_frame_num_minus4
    const poc = ue();       // pic_order_cnt_type
    if (poc === 0) ue(); else if (poc === 1) { pos += 1; se(); se(); const c = ue(); for (let i = 0; i < c; i++) se(); }
    ue();                   // max_num_ref_frames
    pos += 1;               // gaps_in_frame_num_value_allowed

    // Macroblock counts -> coded pixel dimensions.
    const mbWidth = ue() + 1;
    const mbHeight = ue() + 1;
    const frameMbsOnly = bits[pos++];
    if (!frameMbsOnly) pos += 1;   // mb_adaptive_frame_field_flag
    let width = mbWidth * 16;
    let height = mbHeight * 16 * (2 - frameMbsOnly);

    // Frame cropping, which is how non-multiple-of-16 display sizes are carried.
    if (bits[pos++]) {
      const left = ue(), right = ue(), top = ue(), bottom = ue();
      const subWidthC = (chromaFormat === 1 || chromaFormat === 2) ? 2 : 1;
      const subHeightC = (chromaFormat === 1) ? 2 : 1;
      width -= subWidthC * (left + right);
      height -= subHeightC * (frameMbsOnly ? 1 : 2) * (top + bottom);
    }
    if (!(width > 0) || !(height > 0)) return { codec, width: 0, height: 0 };
    return { codec, width, height };
  } catch (_) {
    return { codec, width: 0, height: 0 };
  }
}

function buildAvcC(sps, pps) {
  const out = new Uint8Array(5 + 3 + sps.length + 3 + pps.length);
  const v = new DataView(out.buffer);
  out[0] = 1; out[1] = sps[1]; out[2] = sps[2]; out[3] = sps[3];
  out[4] = 0xFF; out[5] = 0xE1;
  v.setUint16(6, sps.length); out.set(sps, 8);
  const p = 8 + sps.length;
  // numOfPictureParameterSets is 3 reserved bits + a 5-bit count, so a single
  // PPS must be 0xE0 | 1 = 0xE1. Writing a bare 1 yields a count of 0 and
  // breaks the avcc fallback configuration on any browser that takes it.
  out[p] = 0xE1; v.setUint16(p + 1, pps.length); out.set(pps, p + 3);
  return out;
}

function annexbToAvccPayload(buf) {
  // Strip SPS/PPS (carried in `description`), length-prefix the rest.
  const nalus = splitNalus(buf).filter(n => { const t = n[0] & 0x1F; return t !== 7 && t !== 8; });
  let total = 0; nalus.forEach(n => total += 4 + n.length);
  const out = new Uint8Array(total);
  const v = new DataView(out.buffer);
  let o = 0;
  nalus.forEach(n => { v.setUint32(o, n.length); out.set(n, o + 4); o += 4 + n.length; });
  return out;
}

async function ensureDecoder() {
  if (S.decoder) return true;
  const caps = S.caps || (S.caps = deviceCaps());
  if (!caps.webcodecs) {
    // Be specific and actionable rather than naming a wrong version floor.
    // `caps.os` is already prefixed ("iOS 12.5"), so do not add "iOS" again.
    setBanner(`This device can't decode video: no WebCodecs (needs iOS 16.4+; `
              + `this one is ${caps.os}).`, 0);
    S.fatal = 'no-webcodecs';
    return false;
  }
  const sps = parseSPS(S.sps) || {};
  const w = sps.width || (S.streamInfo && S.streamInfo.width) || 1280;
  const h = sps.height || (S.streamInfo && S.streamInfo.height) || 720;
  S.videoW = w; S.videoH = h;
  const codec = sps.codec || 'avc1.640028';

  const output = frame => {
    renderFrame(frame);
    frame.close();
    S.lastFrameAt = nowMs();
    S.totalFrames += 1;
  };
  const error = e => {
    S.stats.stalls++;
    wsSend({ type: 'kf' });
    S.decoder = null; S.decoderMode = null;   // reconfigure from next IDR
  };

  // Ask the browser which of the two AVC formats it will actually accept,
  // rather than discovering it by throwing. Safari 16.4-18.7 reports partial
  // WebCodecs support and annexb is the part that is unreliable there, so this
  // probe is what decides between the two paths.
  const base = { codec, codedWidth: w, codedHeight: h, optimizeForLatency: true };
  const wantAnnexB = { ...base, avc: { format: 'annexb' } };
  const wantAvcc = { ...base, description: buildAvcC(S.sps, S.pps), avc: { format: 'avcc' } };

  for (const [mode, cfg] of [['annexb', wantAnnexB], ['avcc', wantAvcc]]) {
    try {
      if (VideoDecoder.isConfigSupported && !(await VideoDecoder.isConfigSupported(cfg)).supported) {
        continue;
      }
      const dec = new VideoDecoder({ output, error });
      dec.configure(cfg);
      S.decoder = dec; S.decoderMode = mode;
      return true;
    } catch (_) { /* try the next format */ }
  }
  setBanner('H.264 decode unsupported by this browser.');
  S.fatal = 'no-h264';
  return false;
}

// ---------- §5.3 keyframe recovery ----------
//
// Why this is needed, since the obvious design is "the sender sends an IDR
// unprompted and the receiver just waits":
//
// A delta NAL is meaningless without its reference frame. A receiver that joins
// mid-GOP — or is simply unlucky enough that the sender's one-shot opening IDR
// went past before the socket was up — receives only deltas forever. WebCodecs
// accepts them, the decoder stays `configured`, the queue drains, and **not one
// frame comes out**. No error is raised, because nothing is malformed.
//
// That failure looks exactly like a dead stream: black screen, 0 fps, no
// complaint. Cursor and touch keep working, because they are a separate control
// channel, which makes it look even more like "the video link is fine but the
// picture is black".
//
// The only previous trigger for asking was the decoder's `error` callback, and
// this situation never produces one. So the receiver asks on a timer instead:
// if video has been arriving but nothing has decoded for a couple of seconds,
// request a keyframe. Rate-limited, so a genuinely idle sender does not get
// hammered.
const KF_IDLE_MS = 2000;      // no decoded frame for this long -> ask
const KF_MIN_INTERVAL = 1500; // but not more often than this

function pollKeyframeRecovery() {
  if (!S.sawVideo) return;                       // nothing has arrived at all
  const t = nowMs();

  // The distinction this exists to get right.
  //
  // A sender watching a static screen is *correct* to stop sending: PROTOCOL.md
  // 5.3 has it replay the last captured frame when the capturer produces nothing.
  // So "no frames arriving" and "frames arriving but not decoding" are opposite
  // situations needing opposite responses.
  //
  // Keying only on the decode gap cannot tell them apart, so an idle desktop
  // looked exactly like a broken decoder: the banner popped over and over and
  // the sender was asked for keyframes indefinitely, for a session that was
  // working perfectly. The bridge's keepalive already covers the idle case —
  // that is what it is for — so here the idle case is simply left alone.
  if (t - S.lastVideoAt > KF_IDLE_MS) return;    // sender idle; nothing to recover

  if (t - S.lastFrameAt < KF_IDLE_MS) return;    // frames are flowing
  if (t - S.lastKfRequestAt < KF_MIN_INTERVAL) return;
  if (!S.ws || S.ws.readyState !== WebSocket.OPEN) return;

  S.lastKfRequestAt = t;
  S.kfRequests += 1;
  wsSend({ type: 'kf' });
  // Non-sticky: the sender may be idle and may never comply, and a permanent
  // banner would then misdescribe a session that is merely waiting.
  setBanner('waiting for a keyframe from the sender…', 2500);
}

setInterval(pollKeyframeRecovery, 1000);

function decoderNeedsReconfig(nalus) {
  const sps = nalus.find(n => (n[0] & 0x1F) === 7);
  const pps = nalus.find(n => (n[0] & 0x1F) === 8);
  let changed = false;
  if (sps && (!S.sps || S.sps.length !== sps.length || S.sps.some((b, i) => b !== sps[i]))) { S.sps = sps.slice(); changed = true; }
  if (pps && (!S.pps || S.pps.length !== pps.length || S.pps.some((b, i) => b !== pps[i]))) { S.pps = pps.slice(); changed = true; }
  return changed;
}

function onVideo(buf) {
  S.stats.bytes += buf.length;
  S.sawVideo = true;
  S.lastVideoAt = nowMs();
  if (!S.lastFrameAt) S.lastFrameAt = nowMs();   // so the first gap is measured from here

  // §5.1 telemetry prefix: JSON before the first start code.
  let meta = null;
  const sc = findStartCode4(buf);
  if (sc > 0) {
    try { meta = JSON.parse(new TextDecoder().decode(buf.subarray(0, sc))); } catch (_) {}
    buf = buf.subarray(sc);
  }

  const nalus = splitNalus(buf);
  if (nalus.length === 0) return;
  // Keyframe = the frame CONTAINS an IDR slice (type 5). It is not enough to
  // test nalus[0]: per PROTOCOL.md 5.1 every IDR is prefixed with SPS+PPS, so
  // nalus[0] is the SPS (type 7) and the old check classified every keyframe as
  // a delta. That silently broke the section 5.3 kf-recovery loop, because the
  // re-requested IDR was fed to the decoder as a delta and never applied.
  const isKey = nalus.some(n => (n[0] & 0x1F) === 5);

  if (decoderNeedsReconfig(nalus)) {        // §5.2 stream change
    if (S.decoder) { try { S.decoder.close(); } catch (_) {} S.decoder = null; S.decoderMode = null; }
    const dim = S.sps && parseSPS(S.sps);
    if (dim && dim.width) { S.videoW = dim.width; S.videoH = dim.height; }
  }
  if (!ensureDecoder()) return;

  // Backpressure: drop deltas when the decode queue backs up (frame-drop
  // recovery is spec-sanctioned — keyframes carry recovery state).
  if (!isKey && S.decoder.decodeQueueSize > 8) { S.stats.drops++; return; }
  if (isKey && S.decoder.decodeQueueSize > 4) { try { S.decoder.reset(); } catch (_) {} }

  const payload = S.decoderMode === 'avcc' ? annexbToAvccPayload(buf) : buf;
  S.decoder.decode(new EncodedVideoChunk({
    type: isKey ? 'key' : 'delta',
    timestamp: S.chunkTs++,
    data: payload,
  }));

  // PROTOCOL.md 5.1: telemetry cap/snd are ms since the Unix epoch on the
  // sender's clock, and clockOffset maps sender-clock -> receiver-clock. So the
  // comparison must be epoch-to-epoch: use nowMs(), NOT performance.now(),
  // which counts from page load. Mixing the two bases produced e2e figures
  // larger than the age of the page.
  if (meta && S.clockOffset !== null && typeof meta.cap === 'number') {
    const e2e = nowMs() - (meta.cap + S.clockOffset);
    S.stats.e2e.push(e2e);
    if (S.stats.e2e.length > 120) S.stats.e2e.shift();
  }
}

const ctx = canvas.getContext('2d', { alpha: false });
function renderFrame(frame) {
  const vw = frame.displayWidth || frame.codedWidth, vh = frame.displayHeight || frame.codedHeight;
  if (canvas.width !== vw || canvas.height !== vh) { canvas.width = vw; canvas.height = vh; }
  ctx.drawImage(frame, 0, 0);
  S.stats.frames++;
}

// ---------- §7 input: touch (normalized) + scroll (video pixels, natural sign) ----------
//
// The element that is actually on screen. On the WebRTC path the canvas is
// hidden with `display: none` and the <video> is shown instead; on the
// WebCodecs path it is the other way round.
//
// This has to be a single named function rather than an expression repeated at
// each site. Three sites had the correct inline form and one (`normPoint`, the
// touch path) did not, and the failure is invisible: a `display: none` element
// has an all-zero rect, so dividing by its width yields `Infinity`, which
// `JSON.stringify` serialises as `null`. The sender receives a touch with no
// coordinates and ignores it, so the symptom is "touch does nothing" with no
// error on either side. Same trap as the cursor, which was already fixed here
// once — so it gets a helper rather than another chance to be forgotten.
function activeSurface() {
  return (S.rtc && rtcEl.srcObject) ? rtcEl : canvas;
}

function normPoint(e) {
  const r = activeSurface().getBoundingClientRect();
  if (!r.width || !r.height) return null;   // not laid out; a later event will do
  return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
}
function sendTouch(phase, e) {
  const p = normPoint(e);
  // No usable rect (surface hidden, or not yet laid out). Sending would put
  // `null` in the coordinates; the sender would ignore it anyway.
  if (!p) return;
  // Outside 0..1 means the pointer was off the picture — a drag that started
  // inside and left, or a rect captured mid-resize. Better dropped than sent:
  // the sender would act on a position the user never pointed at.
  if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;
  const msg = { type: 'touch', phase, x: p.x, y: p.y };
  if (S.clockOffset !== null) msg.t = senderNow();
  S.touchSent += 1;
  S.lastTouch = msg;
  wsSend(msg);
}
// The stage is also the touch surface for input injection (§7), so it handles
// every pointer event that reaches it — including those aimed at the controls
// that live *inside* it: the gear button, the fullscreen button, the settings
// panel.
//
// `preventDefault()` on a pointerdown suppresses the compatibility mouse events
// and therefore the `click` the control underneath would have received. An
// unconditional handler here swallows every tap on the UI: the button reacts
// visually, nothing happens, and it looks like the page is ignoring input.
// `setPointerCapture` compounds it by stealing the rest of the gesture.
//
// So every handler below starts by deciding whether the pointer is aimed at the
// *screen* or the *interface*, and stays out of the way when it is the latter.
const UI_SELECTOR = '#settings, #gear-btn, #fs-btn, #stats';

function isUiTarget(target) {
  if (!target) return false;
  // `closest` exists on iOS 12, but be defensive: this runs ahead of every
  // pointer event, and a throw here would take the whole input path with it.
  if (typeof target.closest === 'function') return !!target.closest(UI_SELECTOR);
  return false;
}

stage.addEventListener('pointerdown', e => {
  if (isUiTarget(e.target)) return;
  e.preventDefault();
  stage.setPointerCapture(e.pointerId);
  // A touch on the stage is a real user gesture, and the only thing that
  // reliably satisfies iOS's autoplay policy. If the WebRTC path is waiting on
  // media, or gave up retrying, this is the user's way to un-stick it without
  // reloading — which on the iPad is otherwise the only thing that would help.
  if (S.rtc && rtcEl.srcObject) tryPlay();
  sendTouch('began', e);
});
stage.addEventListener('pointermove', e => {
  if (e.buttons === 0) return;   // only stream moves while a pointer is down
  if (isUiTarget(e.target)) return;
  e.preventDefault();
  S.pendingTouch = e;
  if (S.sendingMoves) return;
  S.sendingMoves = true;
  requestAnimationFrame(() => {
    const ev = S.pendingTouch; S.pendingTouch = null; S.sendingMoves = false;
    if (ev && ev.buttons !== 0 && !isUiTarget(ev.target)) sendTouch('moved', ev);
  });
});
stage.addEventListener('pointerup', e => {
  if (isUiTarget(e.target)) return;
  e.preventDefault();
  sendTouch('ended', e);
});
stage.addEventListener('pointercancel', e => {
  if (isUiTarget(e.target)) return;
  sendTouch('cancelled', e);
});
stage.addEventListener('wheel', e => {
  // Scrolling the settings panel must scroll the panel; a wheel over the UI is
  // not a scroll of the Mac's desktop.
  if (isUiTarget(e.target)) return;
  e.preventDefault();
  // The reference surface is whichever is showing, for the same reason the
  // cursor handler picks it: on the WebRTC path the canvas is hidden and has a
  // zero rect, which would scale every scroll delta to nothing.
  const r = activeSurface().getBoundingClientRect();
  if (!r.width || !r.height) return;
  const sx = S.videoW ? S.videoW / r.width : 1;
  const sy = S.videoH ? S.videoH / r.height : 1;
  wsSend({ type: 'scroll', dx: e.deltaX * sx, dy: e.deltaY * sy });
}, { passive: false });
document.addEventListener('gesturestart', e => e.preventDefault());

// ---------- WebRTC fallback (no WebCodecs) ----------
// A device without VideoDecoder cannot decode the H.264 the bridge forwards,
// so it negotiates its own WebRTC session with the bridge over the socket it
// already has. Non-trickle: the answer carries its candidates, so there is no
// rtcIce exchange. The bridge answers with an `rtcAnswer` control message.
const rtcEl = document.createElement('video');
rtcEl.id = 'rtc-video';
// `playsInline` and `muted` are what let iOS play a MediaStream without a user
// gesture and without hijacking the screen with fullscreen video.
//
// `autoplay` is deliberately NOT set. It is tempting, and it is the documented
// way to play a stream, but combined with the explicit `play()` below it means
// two play attempts race: the autoplay one is started, then `srcObject` is
// reassigned, which aborts it — and Safari surfaces that abort as
// "The operation was aborted". One explicit `play()`, retried, is the reliable
// form.
rtcEl.playsInline = true; rtcEl.muted = true;
rtcEl.style.cssText = 'position:absolute;top:0;right:0;bottom:0;left:0;width:100%;height:100%;object-fit:contain;background:#000';
document.addEventListener('DOMContentLoaded', () => {
  const stage = document.getElementById('stage');
  if (stage) stage.appendChild(rtcEl);
});
// Hidden unless it is the active path.
rtcEl.style.display = 'none';

// ---------- WebRTC playback ----------
//
// `play()` on a MediaStream is not a one-shot operation on iOS. When the track
// carries no media yet — which is the normal state for a second or two after
// `ontrack`, and indefinitely if the sender has nothing to send — Safari
// rejects with `AbortError: The operation was aborted`. Treating that as fatal
// was the bug: one aborted attempt left a sticky error banner over a session
// whose stream was perfectly fine, and nothing ever retried.
//
// So playback is retried, with backoff, and `AbortError`/`NotSupportedError` are
// treated as "not yet" rather than "broken". A real, persistent failure still
// reports — but it reports once, non-sticky, and keeps trying.
const PLAY_RETRY_DELAYS = [250, 500, 1000, 2000, 4000, 8000];
let playAttempts = 0;
let playRetryTimer = null;

function tryPlay() {
  if (!rtcEl.srcObject) return;
  if (playRetryTimer) { clearTimeout(playRetryTimer); playRetryTimer = null; }

  const promise = rtcEl.play();
  if (!promise || typeof promise.catch !== 'function') return;  // very old Safari

  promise.then(() => {
    playAttempts = 0;
    // Playback is the proof that the previous complaint is stale, so clear it.
    if (/^WebRTC play failed/.test(banner.textContent)) setBanner('');
  }).catch(err => {
    // AbortError and NotSupportedError both mean "not playable right now" on
    // Safari. NotAllowedError is a genuine autoplay-policy block and retrying
    // will not help.
    const retryable = err && (err.name === 'AbortError' || err.name === 'NotSupportedError');
    if (!retryable) {
      setBanner('WebRTC play failed: ' + (err && err.message ? err.message : err), 0);
      return;
    }
    playAttempts += 1;
    if (playAttempts > PLAY_RETRY_DELAYS.length) {
      setBanner('WebRTC stream is connected but no media is arriving yet', 0);
      return;
    }
    // Non-sticky, because it is a transient state and the user should not be
    // left with a permanent error over a session that may recover on its own.
    setBanner('WebRTC waiting for media…', 1500);
    playRetryTimer = setTimeout(tryPlay, PLAY_RETRY_DELAYS[playAttempts - 1]);
  });
}

async function startWebRTC() {
  if (S.rtc) return;
  const pc = new RTCPeerConnection({ iceServers: [] });   // LAN only, no STUN
  S.rtc = pc;
  // `getStats()` counters are cumulative per connection, so a new connection
  // has to start the delta chain from zero or the first poll reports the sum of
  // every session so far as a single second's frame count.
  S.rtcPrevFrames = 0;
  S.rtcPrevBytes = 0;
  S.rtcSize = null;

  pc.ontrack = (e) => {
    // `e.streams` is empty when the remote description did not associate the
    // track with a stream id, which is legal and does happen with a plain
    // recvonly transceiver. Assigning `srcObject = undefined` leaves the element
    // with no source, and `play()` on a sourceless element rejects — so fall
    // back to wrapping the track directly, which is equivalent for playback.
    const stream = (e.streams && e.streams[0]) || new MediaStream([e.track]);
    rtcEl.srcObject = stream;
    rtcEl.style.display = 'block';
    document.getElementById('screen').style.display = 'none';

    // Start (or restart) playback. See `tryPlay` for why this retries rather
    // than reporting once.
    countDisplayedFrames();
    tryPlay();

    // The most precise signal that media has actually begun to flow. On iOS a
    // `play()` issued while the track is still empty is routinely aborted, so
    // the moment the track unmutes is exactly when a retry is worth making.
    const track = e.track;
    if (track) {
      const onUnmute = () => { tryPlay(); };
      track.addEventListener('unmute', onUnmute);
      track.addEventListener('mute', onUnmute);
    }
  };
  pc.oniceconnectionstatechange = () => {
    if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
      setBanner('WebRTC ' + pc.iceConnectionState + ' — retrying', 0);
    }
  };

  try {
    pc.addTransceiver('video', { direction: 'recvonly' });
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    // Wait for gathering so the offer carries candidates (non-trickle).
    if (pc.iceGatheringState !== 'complete') {
      await new Promise((res) => {
        const t = setInterval(() => {
          if (pc.iceGatheringState === 'complete') { clearInterval(t); res(); }
        }, 100);
        setTimeout(() => { clearInterval(t); res(); }, 6000);
      });
    }
    wsSend({ type: 'rtcOffer', sdp: pc.localDescription.sdp });
    setBanner('negotiating WebRTC…', 0);
  } catch (err) {
    setBanner('WebRTC setup failed: ' + err.message, 0);
  }
}

// An rtcAnswer is a control message from the bridge.
function onRTCAnswer(msg) {
  if (!S.rtc) return;
  if (msg.error) { setBanner('WebRTC refused: ' + msg.error, 0); return; }
  if (!msg.sdp) return;
  S.rtc.setRemoteDescription({ type: 'answer', sdp: msg.sdp })
    .then(() => setBanner('WebRTC connected — waiting for frames…', 3000))
    .catch(err => setBanner('WebRTC answer rejected: ' + err.message, 0));
}

// ---------- lifecycle courtesy messages (§6.1: best-effort) ----------
window.addEventListener('pagehide', () => wsSend({ type: 'closing' }));
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') {
    wsSend({ type: 'sleeping' });
  } else {
    requestWakeLock();
    if (S.ws && S.ws.readyState === WebSocket.CLOSED && !S.intentionalClose) scheduleReconnect('Reconnecting');
  }
});

// ---------- wake lock & fullscreen ----------
async function requestWakeLock() {
  try {
    if ('wakeLock' in navigator) S.wakeLock = await navigator.wakeLock.request('screen');
  } catch (_) {}
}
// Fullscreen, with the prefixed paths iOS Safari actually has.
//
// `requestFullscreen` is undefined on Safari 12 — the receiver's own diagnostics
// were reporting `TypeError: document.documentElement.requestFullscreen is not a
// function` on every tap. iOS Safari has had `webkitRequestFullscreen` for
// years, and for a <video> it also offers `webkitEnterFullscreen`.
//
// Order matters, and it is the opposite of the obvious one. `webkitEnterFullscreen`
// is what iOS prefers and what most examples reach for, but it makes the video
// element *alone* fullscreen in the native player — the cursor overlay, the
// banner and the controls are simply not in that view, so the cursor vanishes. A
// network display whose cursor disappears in fullscreen is worse than useless, so
// page fullscreen is tried first: it takes the whole document and the cursor
// comes with it. `webkitEnterFullscreen` is the fallback for where page
// fullscreen is unavailable (iPhone), and the banner says what is lost rather
// than leaving the user hunting for a setting that does not exist.
//
// Presence is checked with `typeof` rather than truthiness because iOS 12.2+
// exposes the prefixed and unprefixed names on different elements, and picking
// the wrong one throws.
function fullscreenElement() {
  return document.fullscreenElement || document.webkitFullscreenElement || null;
}

function exitFullscreen() {
  const exit = document.exitFullscreen || document.webkitExitFullscreen;
  if (!exit) return false;
  try { exit.call(document); return true; } catch (_) { return false; }
}

// Returns 'page', 'video', or null.
function enterFullscreen() {
  // 1. The page, so the cursor and the controls come along. The call has to be
  //    bound to the element that covers the screen — fullscreening the stage
  //    would drop the controls all over again.
  const host = $('display-view') || document.documentElement;
  const request = host.requestFullscreen || host.webkitRequestFullscreen
    || document.documentElement.requestFullscreen
    || document.documentElement.webkitRequestFullscreen
    || document.body.requestFullscreen
    || document.body.webkitRequestFullscreen;
  if (request) {
    try { request.call(host); return 'page'; } catch (_) { /* try the next */ }
  }

  // 2. The native video player. Video only — say so, because the cursor really
  //    cannot be drawn there.
  if (rtcEl && rtcEl.srcObject && typeof rtcEl.webkitEnterFullscreen === 'function') {
    try {
      rtcEl.webkitEnterFullscreen();
      setBanner('iOS native player: the remote cursor is not shown here', 4000);
      return 'video';
    } catch (_) { /* try the next */ }
  }
  setBanner('This browser does not support fullscreen', 3000);
  return null;
}

// The single owner of cursor visibility.
//
// Three things feed this and they used to fight over `display` independently:
// the cursor protocol handler (is the sender drawing a cursor at all), whether
// the sprite image has arrived, and whether the native iOS video player has
// swallowed the page — in which case the cursor genuinely cannot be drawn,
// because that view contains only the <video>.
//
// A cursor that appears without a sprite, or survives into a view it is not in,
// are both worse than not showing it.
function updateCursorVisibility() {
  const show = !S.hideChrome && S.cursorVisible && S.cursorImgReady;
  cursorEl.style.display = show ? 'block' : 'none';
}

// Hides the on-screen chrome once the page is fullscreen.
//
// The two corner buttons are the point: the fullscreen button is redundant in
// fullscreen, and the gear opens a panel covering a quarter of the screen
// someone presumably went fullscreen to see.
//
// Exit is not lost. On iOS Safari the native fullscreen control — the X the
// browser draws, which a page can neither remove nor overlay — is the way out,
// and Escape works on the desktop. Hiding our own button is safe precisely
// because that control exists.
//
// The debug overlay is deliberately left alone. It is hidden by default anyway,
// and someone who has turned it on has usually done so because something is
// wrong and they want to watch it while fixing it.
function updateChromeVisibility() {
  const hide = S.hideChrome || !!fullscreenElement();
  const gear = $('gear-btn');
  const fsb = $('fs-btn');
  const panel = $('settings');
  if (gear) gear.style.display = hide ? 'none' : '';
  if (fsb) fsb.style.display = hide ? 'none' : '';
  // A panel left open across a fullscreen transition would cover the picture.
  if (hide && panel && panel.style.display === 'block') setSettingsOpen(false);
}

$('fs-btn').addEventListener('click', () => {
  if (fullscreenElement()) { exitFullscreen(); return; }
  S.fsMode = enterFullscreen();
  S.hideChrome = (S.fsMode === 'video');
  updateCursorVisibility();
  updateChromeVisibility();

  // Confirm the page fullscreen actually took.
  //
  // Chrome's transition is async, so `fullscreenElement()` is still null right
  // after the call and the `fullscreenchange` event is what tells us later. But
  // if that event never arrives — a browser that accepts the request and does
  // nothing, or an iOS build that swallows it — the chrome would be left in
  // whatever state the last event put it, with no way back. So check once after
  // a beat and undo it if nothing happened. Hiding the buttons optimistically
  // instead would risk stranding a user with no controls and no native ✕ to
  // press.
  if (S.fsMode === 'page') {
    setTimeout(() => {
      if (S.fsMode === 'page' && !fullscreenElement()) {
        S.fsMode = null;
        updateChromeVisibility();
      }
    }, 700);
  }
});

if (rtcEl && typeof rtcEl.addEventListener === 'function') {
  // iOS fires these on the *video* element even when the page is what went
  // fullscreen, so the cursor's visibility has to follow them rather than the
  // click alone.
  rtcEl.addEventListener('webkitbeginfullscreen', () => {
    S.hideChrome = true;
    updateCursorVisibility();
    updateChromeVisibility();
  });
  const endFullscreen = () => {
    S.hideChrome = false;
    S.fsMode = null;
    updateCursorVisibility();
    updateChromeVisibility();
  };
  rtcEl.addEventListener('webkitendfullscreen', endFullscreen);
  // Entering *page* fullscreen fires none of the webkit video events, so the
  // chrome is re-evaluated on every fullscreen transition rather than only on
  // exit. `updateChromeVisibility` is idempotent, so running it on both edges is
  // simpler and more reliable than trying to tell them apart.
  const onFsChange = () => {
    if (!fullscreenElement()) endFullscreen();
    updateChromeVisibility();
  };
  document.addEventListener('fullscreenchange', onFsChange);
  document.addEventListener('webkitfullscreenchange', onFsChange);
}

// ---------- stats overlay (receiver `stats` sent every ~5s, §6.1) ----------
//
// Two sources of counters, and which one is live depends on the path:
//
//   * WebCodecs: this page decodes the H.264 itself, so it counts bytes and
//     frames as they arrive off the WebSocket (`S.stats.bytes/frames`).
//   * WebRTC: the bytes never touch this page. `pc.getStats()` is the only
//     honest source, so inbound-rtp counters are read from it.
//
// Before this existed, the WebRTC path incremented neither counter, and the
// overlay read "0 fps 0.0 Mb/s" identically whether video was flowing or not.
// On the old iPad — the only device that takes the WebRTC path — that made the
// one diagnostic on the page useless precisely where it was needed.
setInterval(async () => {
  const s = S.stats, t = nowMs();
  if (S.rtc) readRtcStats();
  if (!s.t0 || t - s.t0 >= 1000) {
    const dt = (t - s.t0) / 1000 || 1;
    s.fps = Math.round(s.frames / dt);
    s.mbps = (s.bytes * 8 / dt / 1e6);
    s.frames = 0; s.bytes = 0; s.t0 = t;
    const e2e = s.e2e.slice().sort((a, b) => a - b);
    const p = q => e2e.length ? Math.round(e2e[Math.floor(q * (e2e.length - 1))]) : 0;
    const capLine = S.caps
      ? `${S.caps.os} · ${S.caps.browser || '?'} · WebCodecs ${S.caps.webcodecs ? 'y' : 'n'}` +
        (S.caps.forced ? ' · FORCED (nocodecs=1)' : '') +
        (S.fatal ? ' · ' + S.fatal : '')
      : '';
    const modeLine = modeDescription();
    statsEl.textContent = `${s.fps} fps  ${s.mbps.toFixed(1)} Mb/s\n` +
      `e2e p50 ${p(0.5)}ms p95 ${p(0.95)}ms\n` +
      `offset ${S.clockOffset !== null ? Math.round(S.clockOffset) : '—'}ms  drops ${s.drops} stalls ${s.stalls}` +
      (S.streamInfo ? `\n${S.streamInfo.width}×${S.streamInfo.height}@${S.streamInfo.framesPerSecond || '?'}` : '') +
      (modeLine ? `\n${modeLine}` : '') +
      (capLine ? `\n${capLine}` : '');
    wsSend({ type: 'stats', transport: 'ws', fps: s.fps, mbps: s.mbps,
             e2e50: p(0.5), e2e95: p(0.95), stalls: s.stalls, drops: s.drops,
             offsetKnown: S.clockOffset !== null,
             os: S.caps ? S.caps.os : null,
             webcodecs: S.caps ? S.caps.webcodecs : null,
             mode: S.bridgeMode || null,
             decoder: S.bridgeDecoder || null,
             fatal: S.fatal || null });
  }
}, 500);

// Reads inbound video counters from the peer connection and folds them into the
// same `S.stats` buckets the WebCodecs path fills, so the overlay has one shape
// of data regardless of path.
//
// Three portability problems, all of which made the WebRTC counters read zero
// while video was in fact playing:
//
//   * `kind` was the only field checked for the media type. Current browsers put
//     it in `mediaType`, so the entry was skipped and every counter stayed 0.
//   * The promise form of `getStats()` does not exist in Safari 12 — only the
//     legacy `getStats(successCb, errorCb)`. `await pc.getStats()` therefore
//     threw on exactly the device this project exists for.
//   * Nothing here is needed to answer "is anything actually displaying?",
//     which the video element can answer on every browser. See
//     `countDisplayedFrames`.
function rtcStatsCallback(report) {
  if (!report || typeof report.forEach !== 'function') return;
  report.forEach(s => {
    if (!s || s.type !== 'inbound-rtp') return;
    // `kind` on older implementations, `mediaType` on current ones.
    const isVideo = (s.kind === 'video') || (s.mediaType === 'video');
    if (!isVideo) return;

    if (typeof s.framesDecoded === 'number') {
      const delta = s.framesDecoded - (S.rtcPrevFrames || 0);
      // A negative delta means the connection was replaced, not that time ran
      // backwards; skip it rather than showing a negative rate.
      if (delta > 0) S.stats.frames += delta;
      S.rtcPrevFrames = s.framesDecoded;
    }
    if (typeof s.bytesReceived === 'number') {
      const delta = s.bytesReceived - (S.rtcPrevBytes || 0);
      if (delta > 0) S.stats.bytes += delta;
      S.rtcPrevBytes = s.bytesReceived;
    }
    if (s.frameWidth) {
      S.rtcSize = `${s.frameWidth}×${s.frameHeight}@${Math.round(s.framesPerSecond || 0)}`;
    }
    S.rtcStatsSeen = true;
  });
}

// Counts frames the <video> element actually DISPLAYS.
//
// This is the only measurement available on every browser, including the old
// iPads this exists for, and it is the one that answers the question that
// matters: is there a picture on the screen? `getStats` describes the transport,
// which can be perfectly healthy while nothing is presented, and it is missing
// entirely on Safari 12.
//
// `requestVideoFrameCallback` is the precise signal where it exists (Chrome,
// Safari 15+). Elsewhere `timeupdate` fires a few times a second, which is
// enough to show that time is advancing at all.
function countDisplayedFrames() {
  if (!rtcEl.srcObject) return;
  if (typeof rtcEl.requestVideoFrameCallback === 'function') {
    const onFrame = () => {
      S.displayedFrames += 1;
      rtcEl.requestVideoFrameCallback(onFrame);
    };
    rtcEl.requestVideoFrameCallback(onFrame);
    return;
  }
  rtcEl.addEventListener('timeupdate', () => { S.displayedFrames += 1; });
}

// Called when playback is genuinely running, so a still image is not mistaken
// for a live one and a dead stream is not mistaken for a slow one.
function rtcIsDisplaying() {
  if (!rtcEl.srcObject) return false;
  if (rtcEl.paused) return false;
  // readyState >= 2 means there is current data; a stalled element drops back to
  // 1 (HAVE_METADATA) once the buffer runs dry.
  return rtcEl.readyState >= 2;
}

function readRtcStats() {
  const pc = S.rtc;
  if (!pc) return;
  let report = null;
  try {
    const maybe = pc.getStats();
    // Safari 12 returns undefined here and wants a callback; current browsers
    // return a promise.
    if (maybe && typeof maybe.then === 'function') {
      maybe.then(rtcStatsCallback).catch(() => {});
    } else if (maybe && typeof maybe.forEach === 'function') {
      rtcStatsCallback(maybe);
    } else {
      pc.getStats(rtcStatsCallback, () => {});
    }
  } catch (_) {
    // `getStats` throws synchronously on some builds. Fall back to the video
    // element's own counters, which always work.
    try { pc.getStats(rtcStatsCallback, () => {}); } catch (__) {}
  }
}

// One line naming the live video path and the decoder behind it, so "black
// screen" is attributable. Reports the bridge's view where it has spoken, and
// this page's own view otherwise.
function modeDescription() {
  const viaWebRTC = !!S.rtc;
  const mode = S.bridgeMode || (viaWebRTC ? 'webRTC' : 'webcodecs');
  const parts = [`mode ${mode}`];
  if (viaWebRTC) {
    if (S.bridgeDecoder && S.bridgeDecoder !== 'none') parts.push(S.bridgeDecoder);
    if (S.rtcSize) parts.push(S.rtcSize);
  }
  // A capable device that is on the WebRTC path is almost always here because
  // of `?nocodecs=1` — a testing override that is trivially left in a
  // bookmarked URL and then looks like a mode-selection bug.
  if (viaWebRTC && !forceNoCodecs() && typeof VideoDecoder !== 'undefined') {
    parts.push('(WebCodecs IS available — override not set)');
  }
  // Video arriving but nothing decoding is a distinct, nameable state. Without
  // it, "waiting for a keyframe" and "the link is dead" both render as
  // "0 fps" and are indistinguishable.
  //
  // Only meaningful while the sender is actually sending: an idle screen is
  // supposed to produce nothing (PROTOCOL.md 5.3), and calling that "NO FRAMES"
  // would report a normal, healthy state as a failure.
  if (!viaWebRTC && S.sawVideo && S.totalFrames === 0
      && (nowMs() - S.lastVideoAt) <= 3000) {
    parts.push(`NO FRAMES from ${S.kfRequests} keyframe request(s)`);
  }
  // Same idea for the WebRTC path, where the transport counters may be
  // unavailable (Safari 12 has no promise-form getStats) or may be healthy
  // while nothing is displayed. The video element is the authority.
  if (viaWebRTC) {
    if (!rtcEl.srcObject) {
      parts.push('no track yet');
    } else if (rtcIsDisplaying()) {
      parts.push(`showing ${rtcEl.videoWidth}×${rtcEl.videoHeight}`);
    } else if (rtcEl.paused) {
      parts.push('PAUSED — tap the screen to resume');
    } else {
      parts.push('track live but no picture (readyState ' + rtcEl.readyState + ')');
    }
    if (S.displayedFrames === 0) {
      // No frame has ever been presented. The transport counters may be
      // reporting perfectly — or may be unsupported entirely, as they are on
      // Safari 12 — so the honest statement is that the *display* has shown
      // nothing, and that the counters above cannot be trusted to say why.
      parts.push('NO FRAMES DISPLAYED');
    }
  }
  return parts.join(' · ');
}

function setBanner(text, holdMs) {
  banner.textContent = text || '';
  banner.style.display = text ? 'block' : 'none';
  clearTimeout(S.hideTimer);
  // holdMs 0 = sticky: a fatal capability failure must not quietly disappear.
  if (text && holdMs !== 0) {
    const ms = holdMs || 6000;
    S.hideTimer = setTimeout(() => { if (banner.textContent === text) setBanner(''); }, ms);
  }
}
