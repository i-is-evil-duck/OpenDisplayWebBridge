================================================================================
OpenDisplay Web Receiver — Implementation Plan (v2, updated after scaffold)
================================================================================
Project:    Turn any old iPad (browser only, no app install) into a second
            display for a Mac, via the OpenDisplay wire protocol (pv 3).
Status:     Scaffold COMPLETE and delivered (OpenDisplayBridge-scaffold.zip).
            Remaining: real-sender integration, MSE fallback, input injection,
            hardening.
Companion:  OpenDisplay PROTOCOL.md (pv 3, normative). Where this plan and
            PROTOCOL.md disagree, PROTOCOL.md wins.
--------------------------------------------------------------------------------

1. LOCKED DESIGN DECISIONS (v1 plan -> v2 as-built)
--------------------------------------------------------------------------------
D1. Connection direction. PROTOCOL.md assigns "receiver listens on TCP 9000,
    sender dials". A browser cannot listen. Solution (unchanged from v1): the
    Mac app hosts a Web Receiver Adapter that listens instead; the browser
    dials in. PROTOCOL.md section 2 explicitly permits new transport bindings
    without touching the wire protocol — ours is the "WebSocket binding".

D2. WebSocket binding rules (as built):
    - Transport: ws://<mac>:8080/od  (wss:// possible later; v1 is plain, LAN).
    - One WebSocket BINARY message carries exactly one OpenDisplay frame,
      payload WITHOUT the 4-byte length prefix. Message boundaries replace
      stream framing. Max message 4 MB (adapter-enforced).
    - Pairing is HTTP-level and happens BEFORE the WS upgrade: POST /pair
      with {code}, response sets cookie odpair=<token>; GET /od upgrade is
      rejected (403) without a valid cookie. No wire-protocol impact, no pv
      bump.
    - Text frames on /od: none in v1.
    - The browser never sends cursorPort, addrs, or pencil (per spec, absent
      cursorPort means cursor rides TCP; pencil degrades to touch).

D3. Latency path. WebSocket + WebCodecs (frame-arrival-order playback, no
    buffering) instead of WebRTC. WebRTC remains a Phase-5 option.

D4. Serve everything embedded: single index.html + receiver.js from bundle
    resources, zero CDNs (the iPad may be offline from the internet).

--------------------------------------------------------------------------------

2. ARCHITECTURE (as built)
--------------------------------------------------------------------------------

Mac app (OpenDisplayBridge Swift package, zero external dependencies)
  App.swift / AppState.swift ....... SwiftUI window: pairing code, URL, log
  Pairing.swift .................... 6-digit code, token issue/validate
  HTTP/HTTPServer.swift ............ NWListener :8080 -> routes:
                                     GET / (page), GET /receiver.js,
                                     POST /pair, GET /od -> WS upgrade
  WS/WebSocket.swift ............... RFC 6455 frame codec + handshake
  WS/WebSocketConnection.swift ..... read loop, fragmentation, ping/pong
  Bridge/ODTransport.swift ......... THE INTEGRATION SEAM
  Bridge/Bridge.swift .............. one active session; newcomer replaces
  Bridge/SenderPipeline.swift ...... sender protocol + Annex B helpers
  Demo/VTBox.swift ................. VideoToolbox H.264 -> Annex B frames
  Demo/DemoSender.swift ............ full pv 3 speaker (REPLACE with real
                                     OpenDisplay sender session)
  Web/index.html, Web/receiver.js .. the iPad client (pure HTML/JS)

iPad Safari (the receiver)
  pair page -> POST /pair -> WS /od -> hello -> video (WebCodecs) -> canvas
  pointer/wheel input -> touch/scroll messages -> Mac

Data flow (matches OpenDisplay "How it works" exactly, demo or real):
  CGVirtualDisplay <- ScreenCaptureKit <- VideoToolbox H.264 (Annex B)
      -> WS binary messages -> iPad: VideoDecoder -> <canvas>
  <- JSON control (hello, touch, scroll) <- CGEvent injection

--------------------------------------------------------------------------------

3. PROTOCOL DIGEST (implementation reference, pv 3)
--------------------------------------------------------------------------------
Framing (official bindings): [4-byte BE length][payload]. Ours elides the
length (see D2). Payloads receiver->sender must be 1..2^20-1 bytes.

Demux (sender->receiver, deprecated heuristic, normative for pv<=3):
a frame is JSON control IFF (1) length < 32768, AND (2) first byte is
'{', AND (3) no NUL byte inside. Else video. Annex B start codes guarantee
NULs in video. Isolate this in one function (pv 4 replaces it with a typed
header). Receiver->sender is all JSON, no demux.

Video (section 5): H.264 Annex B, one access unit per frame. Optional
telemetry prefix JSON {"cap":<ms>,"snd":<ms>} before the first start code —
tolerate absence, ignore unknown fields. Start codes always 4 bytes. Every
IDR prefixed with current SPS+PPS. No PTS crosses the wire; display in
arrival order. Stream size comes from the SPS, never from hello. On SPS/PPS
change: rebuild decoder, drop buffered frames. kf message requests an IDR;
sender should also IDR unprompted on (re)connect.

Control messages: JSON, one per frame, "type" discriminator. Normative:
unknown types ignored (log at most once per type), unknown fields ignored,
unparseable payloads ignored. Numbers are JSON numbers (int/float blur).
hello MUST be first (re-sent on rotation; sender debounces 300 ms and
answers each with welcome). ping{t} every ~2s -> pong{t, mt}. touch{phase:
began/moved/ended/cancelled, x,y normalized 0..1, t? in sender clock}.
scroll{dx,dy in VIDEO pixels, natural-scrolling sign}. pencil/proximity
only to pv>=3 senders, else degrade to touch. kf{}. stats free-form.
sleeping/closing are best-effort courtesies — never rely on them.
Sender->receiver: pong{t,mt}; ping (health, no reply expected);
cursor{v,x?,y?} up to 120/s; cursorImg{nw,nh,ax,ay,png base64 <=24000B};
welcome{pv,min}; updateRequired{target,store,message}; streamConfig{codec,
width,height,framesPerSecond} sent before first frame and on reconfigure —
absent means legacy H.264.

Coordinates (section 7 — the unit-mismatch trap): hello pixels = physical
panel px in current orientation; touch/cursor x,y = normalized 0..1 against
the VIDEO, top-left origin; scroll dx,dy = video PIXELS, natural sign;
cursorImg nw,nh normalized to display, ax,ay normalized within sprite;
timestamps = ms since Unix epoch on whoever's clock the field says.

Time & liveness (section 8): clock sync NTP-style: ping t1 -> pong{t1, mt}
-> at t2: rtt = t2-t1, offset = mt - (t1+t2)/2. Keep last 15 samples,
discard rtt<0 or rtt>=2000, use min-rtt sample's offset. Feeds telemetry
latency and touch.t. Liveness: silence > 5s = dead link BOTH ways (a static
screen produces no video!). Send something every ~5s; official cadence is
ping every 2s. Dialer owns reconnect: retry ~1s, 5s connect timeout, ~10s
grace for previously-connected peer; end sooner on closing/refusals. In our
binding the BROWSER is the dialer, so the browser runs this policy.

Lifecycle: hello first; first frame after connect is an IDR; rotation =
re-hello on the LIVE connection (not reconnect); newcomer replaces
incumbent; sleeping/closing best-effort.

Versioning: pv integer, bumped only when the wire changes; current 3; no pv
= pv 1; additive changes free; breaking changes two-phase. Our binding adds
no wire changes: pv stays 3.

--------------------------------------------------------------------------------

4. WHAT IS DONE (scaffold, delivered in OpenDisplayBridge-scaffold.zip)
--------------------------------------------------------------------------------
[x] SPM package, zero dependencies, macOS 13+, swift run works offline
[x] HTTP server: page hosting, POST /pair cookie gate, WS upgrade on /od
[x] RFC 6455 server: masking enforced, fragmentation reassembly, ping/pong,
    close handshake, permessage-deflate rejected, 4 MB message cap
[x] Pairing: 6-digit code in the app window, regenerate button, single
    active session with newcomer-replaces-incumbent
[x] ODTransport seam (the integration point for the real sender)
[x] DemoSender: complete pv 3 control plane — hello/welcome/streamConfig,
    ping/pong clock replies, kf handling, touch/scroll logging, 2s liveness
[x] VTBox: VideoToolbox H.264 encode honoring the section 5 contract
    (4-byte start codes, SPS/PPS on every IDR, real-time, no B-frames,
    telemetry prefix) — doubles as the reference for the real sender
[x] Web receiver (receiver.js, passes node --check):
    - pair form -> POST /pair -> WS connect
    - hello from screen/devicePixelRatio + conservative videoCaps ceiling
      (1920x1080@30, maxPixelsPerSecond) for old hardware
    - demux heuristic, telemetry strip, NALU split
    - minimal SPS parser (profile/level -> codec string, Exp-Golomb width/
      height) — dims ALWAYS from SPS, streamConfig only as fallback
    - WebCodecs VideoDecoder: annexb format preferred, avcc description
      fallback; decoder reset on SPS/PPS change; kf on decode error
    - backpressure: drop deltas when decodeQueueSize > 8; reset on key
    - ping/pong clock sync (15 samples, min-rtt); 5s silence watchdog ->
      browser-side reconnect (1s backoff, capped 10s)
    - input: Pointer Events -> touch (normalized 0..1, rAF-throttled
      moves), wheel -> scroll (converted to VIDEO pixels via video/rect
      scale ratio, natural sign); touch.t stamped in sender clock
    - cursor overlay (cursorImg sprite + cursor position, translate3d)
    - stats overlay + receiver stats every ~5s (fps, Mb/s, e2e p50/p95,
      offset, drops, stalls)
    - pagehide -> closing; visibilitychange -> sleeping; wake lock; fullscreen

--------------------------------------------------------------------------------

5. UPDATED ROADMAP (status per phase)
--------------------------------------------------------------------------------
Phase 0  Baseline & spike .......................... DONE (design+scaffold
          replaced the need to fork first; defer fork until integration)
Phase 1  Transport seam + loopback test ............ DONE (as built above)
Phase 2  Web receiver core ......................... DONE vs DemoSender
          (decoder, demux, clock sync, reconnect all exercised end-to-end)
Phase 3  Input ..................................... DONE (see note)
          The receiver sends touch began/moved/ended/cancelled normalised to
          0..1, and the wheel as video-pixel deltas. CGEvent injection is NOT
          ours: we no longer fork the sender, we impersonate a receiver to the
          real OpenDisplay.app, and that app has its own InputInjector. What it
          needs from us is Accessibility permission on the Mac, which is the
          sender's own prompt, not ours.
Phase 4  Polish & hardening ........................ TODO (see section 6)
Phase 5  Stretch: WebRTC transport, TLS wss, keyboard
          passthrough, multi-receiver, upstream PR .. TODO (unscheduled)

--------------------------------------------------------------------------------

6. REMAINING WORK — IN ORDER
--------------------------------------------------------------------------------
6.1 Integrate the real OpenDisplay sender (the big one)
    a. Fork/clone github.com/peetzweg/opendisplay, build per its README
       (xcodegen, team id, build Mac + iOS targets, verify official pair
       works so you have a known-good reference).
    b. Locate its sender-side receiver connection (the NWConnection dial
       path that speaks length-prefixed frames to port 9000).
    c. Conform that session to ODTransport:
       sendFrame(payload) -> write [4-byte BE length][payload];
       onFrame          -> fire with payload after stripping the length.
    d. Point Bridge.makePipeline at it (replace DemoSender). The existing
       "wait for hello -> create CGVirtualDisplay -> capture -> encode"
       flow then runs unchanged; VTBox shows the exact Annex B + telemetry
       contract the real encoder output must match.
    e. Verify hello-driven display sizing: panel size from hello pixels,
       stream capped by the receiver's videoCaps ceiling (section 6.5
       intersection should already exist on the sender side).
    f. GOTCHAS to verify in the real codebase:
       - virtual display not appearing in SCShareableContent on macOS 15.7
         (known bug; project has a CGDisplayStream fallback — confirm it
         triggers for adapter sessions too)
       - pick display resolution at creation; never CGDisplaySetDisplayMode
         afterward (un-removable-display trap)
       - don't touch display-arrangement restore right after creation
       - Screen Recording TCC prompt; recurring "continue allowing" prompt
         on macOS 15+ is expected
       - App Sandbox must be OFF for CGVirtualDisplay private API
    g. LICENSE: OpenDisplay is GPL-3.0. Copying its code into this project
       makes the combined work GPL-3.0 (keep attribution). Releases up to
       v0.4.x were MIT. Decide before merging codebases.

6.2 CGEvent input injection (finishes Phase 3)
    - touch began/moved/ended -> mouse down/drag/up at normalized coords
      scaled to the virtual display bounds
    - scroll dx,dy -> CGEventCreateScrollWheelEvent with natural sign
    - pencil -> tablet events (optional; degrade to touch)
    - Accessibility permission prompt + denial UX in the app window
    - End-to-end input latency: stamp touch.t (sender clock) and measure
      against CGEvent delivery in the sender log (inp50/inp95 fields)

6.3 MSE fallback spike for Safari < 16.4 (Phase 4.5 — go/no-go)
    - jmuxer muxes Annex B -> fragmented MP4 in JS -> Media Source
      Extensions on a <video> element; expect +300-800 ms buffer latency
    - Test on the ACTUAL oldest iPad early; old WebKit MSE is the riskiest
      compatibility item in the project
    - If it fails: minimum iOS version becomes 16.4 (document on pair page)

6.4 Rotation & quality adaptation
    - resize/orientationchange -> debounced re-hello (receiver side done;
      confirm sender rebuild debounce + fresh welcome per section 6.1)
    - adaptive quality: sender reads receiver stats (drops, stalls, e2e95)
      and steps stream size/bitrate down/up within the advertised videoCaps

6.5 Hardening & packaging
    - Reconnect torture: Mac app restart mid-session, iPad lock/wake,
      WiFi drop, two iPads competing (newcomer adoption)
    - Idle CPU when no client: adapter listens but encoder only spins up
      after hello (already true in scaffold)
    - Optional: wss:// with self-signed cert; HTTP Basic as a stopgap
    - Distribution: notarized DMG or brew cask (private API = no App Store);
      add to app window: copy-URL button, permissions checklist panel

--------------------------------------------------------------------------------

7. TESTING & MEASUREMENT (carried forward, still applies)
--------------------------------------------------------------------------------
- Latency ground truth: telemetry cap/snd + clock offset vs render time;
  cross-check by filming both screens.
- Demux fuzz: replay captured sessions incl. frame starting with '{' and
  control near 32768 bytes.
- Congested WiFi (iperf): sender frame-drop backpressure + kf recovery;
  silence must never exceed ~5s on a healthy session.
- Rotation flurry: exactly one display rebuild.
- Permissions matrix: Screen Recording, Accessibility, Local Network —
  every denial = visible hint, never silent.
- Device matrix: iOS 16.4+ WebCodecs path (16.4-18.7 is PARTIAL: annexb is
  unreliable there, so the avcc path is the one that carries old iPads);
  iOS 12-16.3 MSE path if 6.3 ships.

--------------------------------------------------------------------------------

8. RISKS (updated)
--------------------------------------------------------------------------------
Old Safari without WebCodecs .......... MSE fallback (6.3) or floor at 16.4
Old-WebKit MSE quirks ................. early spike; else same floor
Decoder limits on old iPad ............ conservative videoCaps; sender
                                        scales stream, desktop stays full-size
WiFi head-of-line blocking ............ v1 accepts (UDP side channel is
                                        cursor-only and browser can't UDP)
CGVirtualDisplay private-API break .... runtime capability checks; pin OS
                                        updates; shared risk with all rivals
SCShareableContent missing display .... confirm CGDisplayStream fallback
High@L5.2 encoder limits .............. sender enforces internally; our
                                        advertised ceilings sit under them
GPL-3.0 contamination ................. decide license posture before 6.1g

--------------------------------------------------------------------------------

9. FILE-BY-FILE MAP (scaffold -> where each plan piece lives)
--------------------------------------------------------------------------------
plan s.5.2 binding rules ............... WS/WebSocket.swift (4MB cap),
                                         WebSocketConnection.swift
plan s.5.3 pairing gate ................ HTTP/HTTPServer.swift, Pairing.swift
plan s.4.1 transport seam .............. Bridge/ODTransport.swift
plan s.4 newcomer adoption ............. Bridge/Bridge.swift
plan receiver decode path .............. Web/receiver.js (ensureDecoder,
                                         onVideo, parseSPS, buildAvcC)
plan input path ........................ Web/receiver.js (pointer/wheel
                                         handlers) + TODO 6.2 on Mac side
plan clock sync & liveness ............. receiver.js (startPing, watchdog,
                                         onControl pong) + DemoSender replies
plan encode contract reference ......... Demo/VTBox.swift (AnnexB helpers in
                                         Bridge/SenderPipeline.swift)
plan stats overlay ..................... receiver.js stats interval block

--------------------------------------------------------------------------------
Sources: OpenDisplay PROTOCOL.md (pv 3, 2026-08-19, cursor-channel rev
2026-08-26) and project README. Wire-behavior claims trace to the spec;
where simplified here, the spec is authoritative.
================================================================================