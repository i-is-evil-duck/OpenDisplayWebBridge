# WebRTC Fallback — Plan & Roadmap

## Problem

The web receiver decodes with WebCodecs `VideoDecoder`, which needs **iOS/iPadOS
16.4+**. A real iPad Air on **iOS 12.5** has neither WebCodecs nor MSE (MSE
landed in iOS 13), so it cannot render video at all. Its only in-browser path is
WebRTC, which works from **iOS 11** — and the maintainer's own older project
(`working-ipad-tracking`) already proved it: that server relays
`offer`/`answer`/`ice-candidate`, i.e. WebRTC signaling, with media peer-to-peer.

## Research findings

### W0.1 — Is WebRTC viable on the Mac side? **Yes**

macOS ships no WebRTC framework, and WebRTC mandates DTLS, which is not in the
SDK either. So a binary dependency is unavoidable. `stasel/WebRTC` M153:

| Question | Answer |
|---|---|
| License | **BSD-3-Clause** (upstream WebRTC). No GPL contamination. |
| Distribution | 43 MB checksum-pinned SwiftPM `binaryTarget`, arm64+x86_64 macOS |
| Frame injection | `capturer:didCaptureVideoFrame:` — *not* `didReceiveVideoFrame` |
| Frame type | callback takes `RTCVideoFrame`; wrap `RTCCVPixelBuffer` in it |
| Concrete source | `-[RTCPeerConnectionFactory videoSource]`; `RTCVideoSource.init` is `NS_UNAVAILABLE` and no subclass is exported |
| Transport | libwebrtc provides DTLS, SRTP, ICE, congestion control. **We write none of it.** |
| Build | needs `@executable_path/Frameworks` rpath + a staging step, or every launch dies in dyld |

### W0.2 — Do we need ffmpeg? **No**

libwebrtc **statically links libvpx**. Verified in the binary:

```
OBJC_CLASS_$_RTCVideoEncoderH264
OBJC_CLASS_$_RTCVideoEncoderVP8      <- libvpx, bundled
OBJC_CLASS_$_RTCVideoEncoderVP9      <- libvpx, bundled
OBJC_CLASS_$_RTCVideoEncoderAV1
```

VP8 and VP9 encoders therefore ship inside the dependency already accepted, at
**zero extra bytes**, and VP8 is the mandatory-to-implement WebRTC codec — every
receiver supports it, iOS 12 included.

**This changes the design: use VP8 for the WebRTC path, not H.264.**

- VP8 is universally supported; H.264-inside-WebRTC is notoriously finicky
  (`profile-level-id` and `packetization-mode` negotiation).
- VP8 needs no hardware encoder, so it sidesteps the local encoding gap below.
- H.264 stays on the WebCodecs path, where it is forwarded as bytes and never
  encoded by us. The two live on different transports, so little is lost.

FFmpeg, libx264 and OpenH264 are all unnecessary.

### The host encoding gap (local, not a product bug)

`EncoderReport` reports the host's real capability from inside the running app.
An unsigned, non-bundled SwiftPM binary sees **zero H.264 encoders** and gets
`OSStatus -12902` (`kVTParameterErr`) from `VTCompressionSessionEncodeFrame`.
This reproduces identically when launched through `open`/LaunchServices, so it
is not the launch context — it is the missing bundle/signature.

**The hardware is fine**: `OpenDisplay.app` streamed real H.264 to this bridge
for 21 seconds. So `DemoSender` cannot encode under `swift run`, and will in a
signed `.app` bundle — which is already required for Screen Recording TCC.

Consequences: the WebRTC path is unaffected (VP8 is software, inside libwebrtc).
Any future claim that "this host cannot encode" must be qualified — it is a
packaging fact about the process, not a property of the machine.

## The key structural fact

**This bridge is a relay, not a capture agent.** `OpenDisplay.app` sends us H.264
over TCP and we forward it untouched. We never hold pixels.

So every non-WebCodecs output mode requires a **decode + re-encode** round trip:

```
OpenDisplay.app ─H.264/TCP:9000─▶ VTDecompressionSession ─▶ CVPixelBuffer ─┬─▶ WebCodecs (forward bytes, zero work)
                                                                            ├─▶ WebRTC  (zero-copy → libvpx VP8)
                                                                            └─▶ JPEG    (ImageIO encode)
```

The **JPEG fallback falls out almost free** once this front-end exists — same
decode, different last hop.

## Mode selection

The bridge parses relayed control frames, so it sees the receiver's `hello`
before choosing a sink. The receiver advertises what it can do; the bridge
picks: `VideoDecoder` → forward H.264; `RTCPeerConnection` → WebRTC; neither →
JPEG. Per-session, re-evaluated on reconnect. The H.264 path is untouched.

---

## Roadmap

### W0.3 — Prove frames reach a browser  ✅ **DONE, verified**

Non-trickle signaling (`POST /rtc/offer` → answer SDP), a synthetic
`CVPixelBuffer` pump, and a probe page gated behind `OD_RTC_PROBE=1`.

Verified in a real browser and **on the iPad (iOS 12.5)**:

```
answer received, 2259 bytes
iceConnectionState: connected
ontrack: video 50fbb3e7-...
FIRST FRAME after 667ms, presented=1
loadedmetadata 480x270      pass: true
```

Two things the spike caught that would otherwise have cost time later:

- **`continualGatheringPolicy = .gatherContinually` never settles on
  `.complete`**, so the non-trickle handshake stalled to its own timeout —
  a flat **6 s added to every connection setup** (first frame 6597 ms).
  `gatherOnce` → **667 ms**. Worth remembering for any future WebRTC work.
- **The assertion must be on decoded frames, not `ontrack`.** A codec
  mismatch or a dead encoder still fires `ontrack` and leaves a permanently
  black `<video>`, so an `ontrack`-only test passes while nothing works. The
  probe counts `requestVideoFrameCallback` frames and requires
  `videoWidth > 0`.

VP8 through bundled libvpx was sufficient — no ffmpeg, and no H.264 encoder.

### W1 — Production signaling  ✅ **DONE, verified**

Signaling moved onto the receiver's existing WebSocket (`rtcOffer` → `rtcAnswer`),
mirroring the proven `working-ipad-tracking` pattern. The `POST /rtc/offer` HTTP
side channel remains only for the W0.3 probe. No separate `rtcIce` is needed:
non-trickle means each SDP carries its own candidates.

Verified in a browser:

```
rtc: signalling: 3 -> 0 (stable)     rtc: gathering: 1 -> 2 (complete)
rtc: ice: 2 (connected)              rtcAnswer applied, ontrack fired
```

### W2 — Real media path  ✅ **built and verified**

`AnnexBStream` (demux, keyframe detection, AVCC, format description) →
`VTDecompressionSession` → `CVPixelBuffer` → libvpx VP8. VideoToolbox decodes
on the main path; `OpenH264H264Decoder` is the software fallback. Backend choice
is reported in the log and readable via `H264Transcoder.backendName`, so a black
screen is attributable rather than mysterious.

**Verified end to end, 40/40 frames:**

```
DIAG backend=VideoToolbox frames=40 firstFrameMs=89
```

and against a real `OpenDisplay.app` capture, replayed from
`Fixtures/real-sender-292x360.264`:

```
REPLAY per-nal: frames=3 backend=VideoToolbox
REPLAY status2: ingest #1 (26B) | ingest #2 (8B) | ingest #3 (148B) |
                stream is 292x360 | decoded first frame
```

**Exit criteria not yet met:** a live moving desktop rendered on the iPad. The
decode half is proven against real sender bytes; delivery over WebRTC to a
browser was proven separately in W0.3 (first frame 667 ms), and the two have not
yet been observed together because this desktop is static. See "The remaining
gap" below.

### Concurrency audit: locks vs. framework callbacks

The three deadlocks fixed above were not bad luck. They are one bug class:
**holding a hand-rolled `NSLock` across a call into a framework that re-enters
the same object.** Once that was named, every lock in the codebase was audited
against it. Eleven findings, of which these are the ones that mattered:

| # | Site | Was | Effect |
|---|---|---|---|
| 1 | `H264Decoders` | transcoder guards the backend *pointer*, not calls into it | `reset()` from the close observer raced `decode()` from the hub read loop, with `VTDecompressionSessionInvalidate` against `VTDecompressionSessionDecodeFrame`. Fires on **every receiver disconnect while streaming**. |
| 2 | `RelayedSender` → `H264Transcoder` | `pushStatus` took `RelayedSender.lock` from a closure the transcoder emitted *under its own lock* | ABBA deadlock. Only triggerable with `OD_H264_DUMP` set, which is exactly the debugging scenario. |
| 3 | `WebRTCOutput.isConnected` | written from libwebrtc's signaling thread with no lock, read under one | Data race. The one lock-escaping field in the file. |
| 4 | `WebRTCOutput.stop` | `connection?.close()` under the lock | Not yet a deadlock — `close()` only posts to the signaling thread. Would have become one the moment (3) was fixed properly. |
| 5 | `OpenDisplayHub.onFrame` | `Bridge` attaches the newcomer then detaches the incumbent; `detach` cleared the slot unconditionally | **The new receiver received nothing from the sender, silently, forever.** Not a race but a deterministic ordering bug. |
| 6 | `WebRTCOutput.answerCompletion` | one unnamed slot | A second `rtcOffer` orphaned the first request's `withCheckedContinuation` (hung to the 8 s HTTP timeout) and answered the second with the first peer's SDP. |
| 7 | `H264Transcoder.dump` | file write + `onStatus` under the lock | Blocked the VideoToolbox callback queue, i.e. decoder back-pressure, while debugging a decoder. |

Fixed in `713cf88` and the commit after it. The structural change worth noting is
(1): the VideoToolbox decoder now has **two** locks, not one, and that is not
over-engineering. A single lock cannot work, because VideoToolbox traps it from
both sides — whichever lock is held across `DecodeFrame` is the one the output
callback needs, and whichever is held across `Invalidate` is the one the callback
needs while the invalidation drains. So `sessionLock` guards the session pointer
and is never held across a blocking call, while `stateLock` guards the counters
and is what `deliver` takes. The same reasoning is now written down at the class.

**The general rule, now enforced by comment and test rather than by memory:**
never call into VideoToolbox or libwebrtc while holding a lock that a callback
on this object might need. The inverse is equally true: never fire a status
callback from inside a critical section, because the closure is assigned by a
caller you do not control and it may take any lock in the program.

Verified clean, having been read in full: `Bridge`, `Pairing`, `HTTPServer`,
`NWConnectionShim`, `WebSocketConnection`, `OpenDisplayHub`, `VTBox`.
`WebSocketConnection` deserves a note — it releases its lock before both
`conn.close()` and its observer loop, and those observers are exactly what take
`Bridge.lock`, `HTTPServer.lock` and `RelayedSender.lock`. Written the obvious
way it would have been the fourth instance of this bug.

### Bugs found and fixed in W1/W2

- **The bridge fed control messages into the decoder.** In WebRTC mode every
  sender frame went to the transcoder, so `welcome`/`streamConfig`/the 2 s ping
  never reached the browser, its §8.2 watchdog fired, and the session
  reconnected in a loop. The bridge now applies the §4 demux: control goes to
  the browser, only video is transcoded. `ODDemux` + 8 tests.
- **Silence with no sender looped the session.** With nothing upstream the
  bridge forwarded nothing, so the receiver's watchdog fired forever — and each
  reconnect rebuilt the WebRTC session, so a sender could never be adopted.
  `RelayedSender` now fills gaps with a sender→receiver `ping`, which is exactly
  the spec's liveness beat and a no-op for the receiver.
- **Software VP8 cannot keep up at 1080p.** At 782×1080 the encode stalled the
  relay's read loop and the session looped. The receiver now advertises a lower
  `maxEncodeWide/High` and `videoCaps` on the fallback path (640×360@15 instead
  of 1920×1080@30) — §6.5 exists for precisely this. Result: the sender scaled
  to 292×360.
- **Query strings 404'd.** Routing compared `req.target` exactly to `/`, so any
  request with a query 404'd — which also blocked the `?nocodecs=1` override.
- **Stale `receiver.js` was served from cache.** The client ships in the same
  bundle as the bridge, so a cached copy kept running against a newer bridge
  (it served a fixed ReferenceError long after the fix). Web assets are now
  `no-store`.
- **`?nocodecs=1` override** added: without it the WebRTC path cannot be tested
  on any modern browser, since nothing else declines WebCodecs.

### Known: two paired receivers livelock

The bridge serves one session at a time (PROTOCOL.md s.1), so two paired
browsers replace each other in a ~1 s loop — each reconnect installs itself as
the newcomer. Real, but only reachable with two paired receivers. A receiver
that discovers it was replaced should back off rather than redial immediately.

## Why there was no image on the WebRTC path (resolved)

Tracked to root cause, and it is **one** cause, not two.

The chain is fully wired and each link is verified: the bridge receives the
sender's real H.264, demuxes it, builds a format description from the SPS, and
reports the true size —

```
ingest #1 (17588B)
stream is 292x360
```

What fails is the **decode**, and the reason is the host gating the hardware
media path for unsigned, non-bundled processes:

- `EncoderReport` shows `VTCopyVideoEncoderList` returning **empty** and
  `VTCompressionSessionEncodeFrame` returning `kVTParameterErr` (-12902).
- `VTDecompressionSessionCreate` succeeds, `VTDecompressionSessionDecodeFrame`
  returns `noErr` — and the output callback **never fires**. VideoToolbox reports
  no error, so the transcoder detects this itself with a 2 s watchdog and says
  so, rather than failing silently.

This is not the machine. `OpenDisplay.app`, a properly signed app on the same
Mac, encodes H.264 fine and streamed a real desktop to this bridge for 21 s.
It is the *unsigned CLI process* that cannot reach the media path.

### Evaluated and rejected: libwebrtc's own H.264 decoder

The obvious escape — libwebrtc is already a dependency, so use its decoder
instead of VideoToolbox. Checked against the actual M153 binary:

- **There is no software H.264 decoder in it.** `openh264` / `welsdec` symbol
  and string matches: **0**. Only `libvpx` (VP8/VP9) is bundled. On Apple
  platforms libwebrtc's H.264 decoder is VideoToolbox-backed, so it inherits
  exactly the same gate.
- It also cannot be driven standalone in M153: `RTCCodecSpecificInfoH264`
  exposes only `packetizationMode`, with no `data` property, so there is no way
  to hand it the avcC record it needs to configure.

`AnnexBStream.avcCRecord()` and its tests are kept regardless: it is the correct
ISO 14496-15 record, it pins the `0xE1`-not-`1` parameter-set-count trap that
shipped in the JS builder, and it is what any software decoder will need.

### What actually blocked video, and what did not

The previous revision of this file claimed the hardware *decode* path was gated
behind a Developer ID signature for unsigned processes, and that only a software
decoder could fix it. **That was wrong, and it cost a lot of time.** The
distinction that actually holds:

```
                     encoders   encode probe   decode
unsigned SwiftPM     NONE       -12902         works
signed .app (adhoc)  NONE       -12902         works
OpenDisplay.app      ok         ok             ok
```

macOS gates the hardware **encoder** for unsigned processes. `EncoderReport` can
demonstrate this: no encoders are enumerated and `EncodeFrame` returns
`kVTParameterErr` (-12902), on an ad-hoc-signed bundle and a bare binary alike.
`VTDecompressionSession` has no such gate. `OpenDisplay.app` encodes and we do
not, but that is fine — encoding is the *sender's* job.

So the bridge decodes with VideoToolbox, unsigned, at full speed. What was
actually wrong was two bugs in our own code, both of which produce the exact
symptom of a closed hardware path — one frame, then silence, no error:

**1. A spurious mid-stream decoder teardown.** `lastSPS`/`lastPPS` were primed
lazily inside `needsNewFormatDescription()`, which is short-circuited on the
first access unit by `!hadParameterSets`. The comparison therefore never ran on
frame 1, leaving `lastSPS` nil, so frame 2 *always* looked like a parameter-set
change and invalidated a working decoder. Every P-frame after that had no
reference picture and could not be decoded. Reported as
`stream is 292x360` twice; the second one is the tell.

**2. A lock-ordering deadlock.** `ingest` held the transcoder lock across
`VTDecompressionSessionDecodeFrame`, while VideoToolbox delivers on
`vtdecoder-callback-queue` and may block inside that call waiting for the
callback — which needs the same lock. `stop()` and every session rebuild had the
same problem via `VTDecompressionSessionInvalidate`, which blocks until pending
callbacks drain. Intermittent, no crash, no log line: the process simply stopped.

Both reproduce on a real capture and neither on a synthetic one, which is why
`Tests/.../Fixtures/real-sender-292x360.264` is checked in (336 bytes, three
access units) and replayed by `RealSenderStreamTests`.

The general rule, now enforced in the code: **never call into VideoToolbox while
holding the transcoder lock.** Decode, reset and invalidate all happen outside
it.

### OpenH264: kept, but as a fallback rather than the main path

Added as the answer to a question that turned out to be based on the wrong
premise. It stays for three reasons, and it is worth being clear that the first
two are about robustness, not necessity:

- `OpenH264H264Decoder` is a genuine fallback if VideoToolbox is ever
  unavailable — an older macOS, a session that will not start, a stream profile
  it rejects. It is ~1 MB, BSD-2-Clause, and already linked.
- `OD_H264_DUMP=<path>` plus that fixture is what made the two bugs above
  findable at all. Replayable sender bytes beat a live sender every time.
- OpenH264's **encoder** is what lets the test suite produce real H.264 on a
  machine where VideoToolbox encode is gated, and what would drive a synthetic
  demo mode. Nothing else available here can: there is no ffmpeg installed.

Set `OD_NO_OPENH264=1` to build without it. The app compiles, the WebCodecs
passthrough path is unaffected, and only the WebRTC transcode path loses its
fallback — reported at runtime rather than failing silently.

Signing is still worth doing eventually, but for its own reasons: Screen
Recording TCC, distribution, and hardware *encode* (which would let the demo
source run at full resolution). `tools/make-app.sh` takes a signing identity as
its argument so a real certificate drops in without further changes.

### The remaining gap: a static screen

Continuous decode→VP8→browser cannot be exercised on an idle desktop.
PROTOCOL.md s.5.3 has a sender "replay the last captured frame if the screen is
static and the capturer produces nothing", and an idle Mac produces one or two
frames, then nothing. A 336-byte three-access-unit capture is what that looks
like.

Driving it live needs something on screen to change. Animating a full-screen
high-contrast overlay in the receiver tab is enough to get the sender producing
frames, which is how the fixture above was captured — though the sender app
remains reluctant to start on demand, so the reliable verification is a real
desktop with real activity, or the iPad.
