import Foundation

/// Pairing gate (lives OUTSIDE the wire protocol — binding-level auth, no pv impact).
/// The Mac shows a 6-digit code; the web client POSTs it to /pair and gets a
/// session cookie that gates the /od WebSocket upgrade.
final class PairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var code: String = ""
    private var tokens: Set<String> = []

    /// Brute-force protection for `verify`.
    ///
    /// A 6-digit code is a million candidates and the port is reachable from the
    /// whole LAN, so an unthrottled `verify` is an exhaustive search that takes
    /// as long as the attacker cares to spend: a million POSTs is seconds of
    /// work, and the code does not change on failure. Nothing about the pairing
    /// flow needs unlimited attempts — a human types the code once — so failures
    /// are counted and the door is left closed for a cooling-off period.
    ///
    /// The counter is per-store, not per-client, so one client's guessing locks
    /// everyone out for the window. That is a deliberate trade: this is a
    /// single-active-session bridge (PROTOCOL.md §1) on a trusted LAN, where the
    /// realistic threat is a curious device rather than a determined attacker, and
    /// per-client tracking would mean trusting a self-declared address. The cost of
    /// getting it wrong is a second legitimate user waiting 30 s — and since a
    /// *correct* code is always accepted, even that only affects a typo, not the
    /// owner reading the code off the screen.
    private var failedAttempts = 0
    private var lockedUntil: Date?

    /// Failures tolerated before the door closes.
    static let maxFailedAttempts = 5
    /// How long the door stays closed once it does.
    static let lockoutDuration: TimeInterval = 30

    func roll() -> String {
        let c = String(format: "%06d", Int.random(in: 0...999_999))
        lock.lock(); code = c; tokens.removeAll(); lock.unlock()
        return c
    }

    /// Pins a specific code instead of rolling one. Used by OD_CODE so the
    /// smoke test can pair unattended; clears outstanding tokens exactly like
    /// `roll()` does, since old sessions were authorised under the old code.
    @discardableResult
    func setCode(_ c: String) -> String {
        precondition(c.count == 6 && c.allSatisfy(\.isNumber), "pairing code must be 6 digits")
        lock.lock(); code = c; tokens.removeAll(); lock.unlock()
        return c
    }

    func verify(_ attempt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // A correct code is always accepted, even mid-lockout. The lockout exists
        // to slow down search, not to lock the owner out of their own display.
        if attempt == code, !code.isEmpty {
            failedAttempts = 0
            lockedUntil = nil
            return true
        }

        // Rate-limit only the failures, and only for a bounded window, so a
        // user who fumbles the code a few times is not punished for long.
        if let until = lockedUntil, until > Date() { return false }
        lockedUntil = nil
        failedAttempts += 1
        if failedAttempts >= Self.maxFailedAttempts {
            lockedUntil = Date().addingTimeInterval(Self.lockoutDuration)
            failedAttempts = 0
        }
        return false
    }

    /// Whether `verify` would refuse before doing any work, for callers that want
    /// to report the lockout rather than a generic "wrong code".
    var isLockedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = lockedUntil, until > Date() { return true }
        return false
    }

    /// Seconds until the lockout expires, or 0 when not locked out.
    var lockoutRemaining: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let until = lockedUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    func issueToken() -> String {
        let t = UUID().uuidString
        lock.lock(); tokens.insert(t); lock.unlock()
        return t
    }

    func isValid(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens.contains(token)
    }
}

extension PairingStore {
    /// Parses "odpair=<token>" out of a Cookie header value.
    static func token(from cookieHeader: String?) -> String? {
        guard let cookieHeader else { return nil }
        for part in cookieHeader.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "odpair" {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
