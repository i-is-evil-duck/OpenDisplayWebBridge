# Third-party notices

This project links or bundles the following third-party software. None of it is
covered by this project's MIT licence; each retains its own.

## OpenH264 — BSD-2-Clause

Cisco Systems, <https://github.com/cisco/openh264>. Fetched and built by
`tools/build-openh264.sh`, then bundled into the `.app` as
`libopenh264.8.dylib`.

BSD-2-Clause permits redistribution in binary form **provided the copyright
notice and disclaimer are reproduced**. `tools/make-app.sh` therefore copies
`LICENSE.openh264` into `Contents/Resources/` of every bundle it produces, and
warns loudly if it cannot find one. Do not remove that step — a bundle built
without the notice is not a lawful redistribution.

Full text: <https://github.com/cisco/openh264/blob/master/LICENSE>

## WebRTC (libwebrtc) — BSD-3-Clause

Google WebRTC, redistributed as a SwiftPM `binaryTarget` via
<https://github.com/stasel/WebRTC>. Staged into the bundle as
`WebRTC.framework` by `tools/stage-frameworks.sh` and `tools/make-app.sh`.

Full text: <https://webrtc.googlesource.com/src/+/master/LICENSE>

## OpenDisplay — GPL-3.0, *not* included

OpenDisplay is the upstream protocol this project interoperates with, and it is
GPL-3.0. **None of its code or documentation is in this repository.** This is an
independent implementation of the wire protocol, not a fork: no upstream source
file was copied, `PROTOCOL.md` was never committed, and no OpenDisplay code is
vendored.

Two things are worth stating precisely, because both could be mistaken for
included code:

- **`Tests/.../Fixtures/real-sender-292x360.264`** is a 336-byte H.264
  elementary stream captured from a running sender. It is encoded video *output*
  used as a test fixture — not source code, and not a copy of anything. It exists
  because two demux bugs were only reproducible against real sender bytes.
- **This project is a separate work** that interoperates over a documented wire
  protocol. Should OpenDisplay's code ever be merged in, that merge — and only
  that merge — would make the combined work GPL-3.0, and the licence here would
  have to change. See the note in `implementationplan.md` §6.1g.
