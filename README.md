# OpenDisplay Web Bridge

<img alt="Stargazers" src="https://img.shields.io/github/stars/i-is-evil-duck/OpenDisplayWebBridge?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41">

## OpenDisplay Web Bridge
Turn a spare iPad into a second display for your Mac, over the network. No client app, no cables — Safari is the receiver.

> **Any device with a browser works.** The original target is an old iPad (iOS 12.5, Safari 12.1) that has neither WebCodecs nor MSE, and therefore cannot decode the H.264 a display sender normally streams. This bridge sits in between: the real `OpenDisplay.app` connects to it as it would to any receiver, and it forwards the picture to the browser over a WebSocket binding of the OpenDisplay protocol. Receivers that *can* decode H.264 natively get the bytes untouched, with zero added latency.

## Features

- **Passthrough** — the sender's H.264 goes to the browser untouched, for anything with WebCodecs
- **WebRTC/VP8 fallback** — for devices that cannot decode H.264 at all; the bridge decodes and re-encodes in software
- **Input** — touch (`began`/`moved`/`ended`/`cancelled`, normalised) and scroll, injected into the Mac as real events
- **Remote cursor** — drawn at the sender's position, in the sender's own sprite
- **Resolution control** — 1x–4x ceiling, persisted in the browser
- **Live diagnostics** — the receiver reports what *it* can see, so a black screen is attributable to one half of the pipeline or the other
- **Cursor survives fullscreen** — page fullscreen is preferred, because the native iOS player cannot draw an overlay
- **Auto keyframe recovery** — asks the sender for an IDR when video arrives but nothing decodes

## Downloads

Download the pre-built app from the [releases](https://github.com/i-is-evil-duck/OpenDisplayWebBridge/releases) page, or build from source.

| Platform | File | Runs on |
|----------|------|---------|
| macOS (Apple silicon or Intel) | `OpenDisplayBridge-v0.4.0.zip` | macOS 13+ |
| Any receiver | — | any browser, iOS 11+ |

The app is ad-hoc signed, so macOS will object on first open: right-click → **Open**, or `xattr -dr com.apple.quarantine OpenDisplayBridge.app`.

## Installation

**Pre-built app**

1. Download `OpenDisplayBridge-v0.4.0.zip` from the [releases](https://github.com/i-is-evil-duck/OpenDisplayWebBridge/releases) page and unzip it.
2. Right-click `OpenDisplayBridge.app` → **Open** (this is the Gatekeeper bypass; the app is not notarised).
3. The window shows a 6-digit code and a URL. Allow **Local Network** access when prompted.
4. On the iPad, open the URL in Safari and enter the code.

**From source**

1. `git clone` this repository and `cd` into it.
2. `./tools/build-openh264.sh` — builds the software H.264 decoder, ~1 minute, no Homebrew needed.
3. `swift run`, or `./tools/make-app.sh` for a bundle.

> **Why the extra build step?** The software decoder is the fallback for machines where VideoToolbox will not decode. Homebrew's OpenH264 bottle is built against a recent macOS (`minos 26.0`), so linking it would make the app macOS-26-only. `tools/build-openh264.sh` builds the same source with a 13.0 deployment target. `brew install openh264` also works, but the resulting build will only run on macOS 26.

## Usage

The bridge is the receiver side of the OpenDisplay protocol, so it needs a sender. Start the real `OpenDisplay.app` — it discovers the bridge over Bonjour and dials in on port 9000, no configuration.

Then, on the iPad:

- Enter the 6-digit code once; the session cookie survives reloads.
- Tap the ⚙ button for the **settings panel**: debug overlay, resolution, and a full session reload.
- Tap ⤢ for **fullscreen**. Page fullscreen is used where available so the remote cursor stays visible; the native iOS player is the fallback and genuinely cannot draw one.
- Everything else on the page is the Mac's screen: tap, drag, and scroll are injected as real input.

Resolution is a *ceiling*, not a target — the sender encodes at the smaller of it and the Mac's display, so past the Mac's screen a higher setting changes nothing.

## Configuration

The settings panel persists to `localStorage`: the debug overlay (off by default) and the resolution multiplier (2x by default, 1x–4x).

The app itself is configured by environment variable:

| Variable | Effect |
|----------|--------|
| `OD_PORT` | listen port (default 8080) |
| `OD_CODE` | pin the 6-digit pairing code, for unattended testing |
| `OD_SOURCE` | `auto` (default), `relay` (wait for a real sender), or `demo` |
| `OD_LOG_STDOUT` | mirror the log to the terminal |
| `OD_RTC_PROBE` | expose `/rtcprobe` for inspecting the WebRTC path |
| `OD_NO_OPENH264` | build without the software decoder |
| `OD_DEPLOYMENT_TARGET` | macOS target for `tools/build-openh264.sh` (default 13.0) |
| `OD_H264_DUMP` | append every relayed access unit as a replayable elementary stream |

## Notes

- **The receiver needs no app.** Safari, or any browser, over the LAN.
- **The iPad must be on the same network as the Mac.** The bridge advertises itself over Bonjour, so most senders find it without configuration.
- **VP8, not H.264, inside WebRTC.** libwebrtc statically links libvpx at no extra size, and VP8 is the mandatory-to-implement WebRTC codec. H.264 inside WebRTC would need a hardware encoder this app cannot reach unsigned.
- **Signing.** Ad-hoc signed, so Gatekeeper objects once. A Developer ID signature and notarisation remove that step and require a paid Apple Developer account — a free one cannot notarise, and its certificates expire after 7 days.
- No telemetry, no analytics, no accounts. Pairing is a local 6-digit code and a session cookie.

## Licensing

MIT — see [LICENSE](LICENSE).

This is an **independent implementation** of the OpenDisplay wire protocol, not a fork. OpenDisplay itself is GPL-3.0 and none of its code or documentation is included here; see [NOTICE.md](NOTICE.md) for the third-party attributions and for the one place that would change this.

## Troubleshooting

Turn on the debug overlay in the settings panel. It reports the live video path, the active decoder, frame rate, bitrate, end-to-end latency percentiles, clock offset, and whether the picture is actually being *displayed* — not merely decoded. Both halves of the pipeline report into the Mac's log, so a black screen is attributable to the sender, the bridge, or the receiver rather than guesswork.
