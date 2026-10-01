import Foundation

/// The PROTOCOL.md s.4 demux heuristic, applied on the bridge side.
///
/// The browser does this too, but it cannot: when the bridge transcodes, video
/// leaves over WebRTC instead of the socket, so the bridge is the only place
/// that still sees both kinds of frame arriving from the sender. Routing
/// control messages into the decoder swallows them — the receiver then hears
/// nothing, its liveness watchdog fires, and the session reconnects in a loop.
///
/// A frame is control if and only if all three hold:
///   1. length < 32768
///   2. the first byte is '{'
///   3. no NUL byte anywhere
///
/// Annex B start codes guarantee NULs, so video can never satisfy the test —
/// including a keyframe carrying the telemetry prefix, which starts with '{'.
enum ODDemux {
    /// Matches the browser's own threshold. PROTOCOL.md s.4 makes this
    /// normative for pv <= 3; pv 4 replaces it with a typed header.
    static let maxControlBytes = 32768

    static func isControl(_ payload: Data) -> Bool {
        guard !payload.isEmpty, payload.count < maxControlBytes else { return false }
        guard payload[payload.startIndex] == 0x7B else { return false }   // '{'
        return !payload.contains(0)
    }
}
