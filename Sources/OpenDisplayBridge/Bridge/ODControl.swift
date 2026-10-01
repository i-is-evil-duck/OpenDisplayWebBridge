import Foundation

/// Control-plane codec for the pv 3 JSON messages (PROTOCOL.md §6).
///
/// One control message is one JSON object per frame, discriminated by "type".
/// The rules this type exists to enforce:
///   - unknown message types are ignored, never fatal (normative, §6)
///   - unknown fields are ignored
///   - unparseable payloads are ignored, never fatal
/// so every entry point here is total: it returns nil / empty rather than throwing.
///
/// Note this is deliberately *not* a typed model of §6. The protocol is
/// versioned and additive, and a decoder that rejects a field it doesn't know
/// would break forward compatibility on the very first pv bump.
enum ODControl {
    /// PROTOCOL.md §3: receiver->sender payloads are 1..2^20-1 bytes.
    /// Anything larger is not a control message; refuse to parse it rather
    /// than hand a huge blob to JSONSerialization.
    static let maxPayloadBytes = 0xFF_FFFF

    /// Decodes one control payload, or nil if it isn't a usable control message.
    static func parse(_ payload: Data) -> [String: Any]? {
        guard !payload.isEmpty, payload.count <= maxPayloadBytes else { return nil }
        // Only a JSON *object* carries a "type" discriminator; arrays/scalars
        // are well-formed JSON but not control messages.
        guard let obj = try? JSONSerialization.jsonObject(with: payload),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// Encodes one control message. Returns empty Data if the object isn't
    /// JSON-serialisable — a dropped control message beats a torn-down stream.
    ///
    /// `JSONSerialization.isValidJSONObject` is checked first on purpose:
    /// `data(withJSONObject:)` raises an ObjC *exception* (not a Swift `error`)
    /// for an invalid value type, which `try?` cannot intercept, so relying on
    /// `try?` alone would let a bad message abort the process.
    static func encode(_ obj: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// Milliseconds since the Unix epoch — the clock every timestamp field in
    /// §6/§8 is expressed in ("whoever's clock the field says", §7).
    static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}
