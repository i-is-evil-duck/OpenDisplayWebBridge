# OpenDisplay Web Bridge

<img alt="Stargazers" src="https://img.shields.io/github/stars/i-is-evil-duck/OpenDisplayWebBridge?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41">

## OpenDisplay Web Bridge
Turn a spare iPad into a second display for your Mac, over the network. No client app, no cables — Safari is the receiver.

> Built for devices that cannot decode H.264: an iPad on iOS 12.5 has neither WebCodecs nor MSE. A sender connects here as it would to any receiver, and this forwards the picture to the browser over a WebSocket binding of the OpenDisplay protocol. Receivers that *can* decode H.264 get the bytes untouched, with zero added latency.

## Features

- **Passthrough** — the sender's H.264 reaches the browser untouched
- **WebRTC/VP8 fallback** — for devices that cannot decode H.264 at all; the bridge transcodes in software
- **Input** — touch and scroll, injected into the Mac as real events
- **Remote cursor** — drawn in the sender's sprite, and kept visible in fullscreen
- **Resolution control** — 1x–4x ceiling, persisted in the browser
- **Live diagnostics** — both halves of the pipeline report in, so a black screen is attributable rather than guesswork
- **Auto keyframe recovery** — asks the sender for an IDR when video arrives but nothing decodes

## Downloads

[Releases](https://github.com/i-is-evil-duck/OpenDisplayWebBridge/releases) · requires **macOS 13+** (Apple silicon or Intel)

| File | Notes |
|------|-------|
| `OpenDisplayBridge-v0.4.0.zip` | Self-contained: OpenH264 and libwebrtc bundled, no Homebrew needed |

## Installation

1. Download and unzip the release.
2. Right-click `OpenDisplayBridge.app` → **Open** (Gatekeeper bypass; the app is ad-hoc signed, not notarised).
3. Allow **Local Network** access when prompted. The window shows a 6-digit code and a URL.
4. Start the real `OpenDisplay.app` — it finds the bridge over Bonjour, no configuration.
5. On the iPad, open the URL and enter the code.

<details>
<summary>Building from source</summary>

    git clone https://github.com/i-is-evil-duck/OpenDisplayWebBridge
    cd OpenDisplayWebBridge
    ./tools/build-openh264.sh    # software H.264 decoder, ~1 min
    swift run                    # or ./tools/make-app.sh for a bundle

The OpenH264 step is what keeps the app portable. Homebrew's bottle is built
against a recent macOS (`minos 26.0`), so linking it makes the app macOS-26-only;
building the same source with a 13.0 deployment target does not.
`brew install openh264` also works, if you don't need the older target.
</details>

## Usage

The page is the Mac's screen — tap, drag and scroll all work. The ⚙ button opens settings (debug overlay, resolution, reload session); ⤢ goes fullscreen. Pairing is a one-time 6-digit code, and the session cookie survives reloads.

Resolution is a *ceiling*, not a target: the sender encodes at the smaller of it and the Mac's display, so past the Mac's screen a higher setting changes nothing.

## Configuration

Environment variables for the app:

| Variable | Effect |
|----------|--------|
| `OD_PORT` | listen port (default 8080) |
| `OD_CODE` | pin the 6-digit pairing code |
| `OD_SOURCE` | `auto` (default), `relay`, or `demo` |
| `OD_LOG_STDOUT` | mirror the log to the terminal |
| `OD_RTC_PROBE` | expose `/rtcprobe` for inspecting the WebRTC path |
| `OD_NO_OPENH264` | build without the software decoder |
| `OD_DEPLOYMENT_TARGET` | macOS target for `build-openh264.sh` (default 13.0) |
| `OD_H264_DUMP` | append every relayed access unit as a replayable stream |

## Notes

- **Any browser works**, on the same network as the Mac. There is no app to install on the receiver.
- **VP8 inside WebRTC, not H.264** — it is mandatory-to-implement everywhere, libwebrtc already links libvpx, and H.264 there would need a hardware encoder an unsigned app cannot reach.
- **No telemetry, no analytics, no accounts.**

## Licensing

MIT — see [LICENSE](LICENSE). Third-party attributions and the OpenDisplay GPL-3.0 position are in [NOTICE.md](NOTICE.md).

## Troubleshooting

Turn on the debug overlay in settings. It reports the live video path, active decoder, frame rate, bitrate, latency percentiles, and whether the picture is actually *displayed* rather than merely decoded — and both halves report into the Mac's log, so a black screen is attributable to the sender, the bridge or the receiver.

## Views

<img src="https://count.getloli.com/get/@OpenDisplayWebBridge?theme=rule34" />
