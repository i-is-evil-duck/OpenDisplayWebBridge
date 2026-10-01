import Foundation

/// What `Bridge` needs from a receiver connection. Exists so session ownership
/// can be tested without a live socket; `WebSocketConnection` is the real
/// implementation.
/// Carries a close reason through the `Error?` that close observers already
/// receive, so no existing signature had to change.
struct BridgeCloseReason: Error, CustomStringConvertible {
    let description: String
}

protocol BridgeConnection: AnyObject {
    func run()
    func close()

    /// Closes with a stated reason, so a close observer can report *why*.
    ///
    /// `close()` is used for both a local close and a remote one, so without
    /// this a receiver that keeps dropping looks identical whether the browser
    /// hung up or the bridge retired it to make room for another device — and
    /// those have opposite fixes.
    ///
    /// Defaulted to `close()` so conformers that do not care about the reason —
    /// chiefly test doubles — do not have to implement it.
    func close(reason: String)
    func observeClose(_ observer: @escaping (Error?) -> Void)
    /// Registers a handler for complete inbound messages.
    func deliver(_ handler: @escaping (WebSocketMessage) -> Void)
    /// Sends one binary message (one OD frame) to the peer.
    func sendBinary(_ data: Data) async throws
}

extension BridgeConnection {
    func close(reason: String) { close() }
}

/// A message as it arrives from a receiver.
enum WebSocketMessage {
    case binary(Data)
    case text(String)
}

/// Glue: one active receiver session at a time. A newly adopted (paired,
/// upgraded) connection REPLACES the current one — PROTOCOL.md §1 newcomer rule.
final class Bridge: @unchecked Sendable {
    let makePipeline: (@Sendable () -> SenderPipeline)

    private let lock = NSLock()
    private var session: (ws: BridgeConnection, transport: WebSocketTransport, pipeline: SenderPipeline)?

    init(makePipeline: @escaping (@Sendable () -> SenderPipeline)) {
        self.makePipeline = makePipeline
    }

    func adoptPairedConnection(_ ws: BridgeConnection) {
        let pipeline = makePipeline()
        let transport = WebSocketTransport(ws)
        pipeline.attach(transport)

        // Install the newcomer BEFORE retiring the incumbent: the incumbent's
        // close observer re-acquires this same lock, and the identity check
        // below then correctly declines to clear the new session.
        // Closing while still holding the lock self-deadlocks (NSLock is not
        // recursive) — so the close has to happen outside it.
        lock.lock()
        let incumbent = session
        session = (ws, transport, pipeline)
        lock.unlock()

        // Retire the incumbent explicitly. Its close observer will NOT do it:
        // the observer only tears down the session it can still see as current,
        // and by now that is the newcomer, not this one.
        //
        // The reason is carried through so the log distinguishes "a second
        // receiver took over" from "this one went away on its own". Those look
        // identical otherwise, and the fix is opposite: the first is expected
        // and often means something *else* is also connected, the second is a
        // real disconnect to chase.
        incumbent?.pipeline.detach()
        incumbent?.ws.close(reason: "replaced by a newer receiver")

        // Detach only while this connection is still the live session, so a
        // pipeline is never detached twice (once by dropSession, once here).
        ws.observeClose { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let wasCurrent = self.session?.ws === ws
            if wasCurrent { self.session = nil }
            self.lock.unlock()
            if wasCurrent {
                pipeline.detach()
                // Report *why* the session ended, when there is a reason to
                // report. A receiver replaced by a newer one is an expected,
                // self-inflicted event and is worth naming, because it almost
                // always means a second device is competing for the session.
                if let reason = error as? BridgeCloseReason {
                    onSessionRetired?(reason.description)
                }
            }
        }
        ws.run()
    }

    /// Called when the bridge itself ended a live session, with the reason.
    var onSessionRetired: ((String) -> Void)?

    func dropSession() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        // Detach before close: `close` fires the observer, which sees no
        // current session (we just cleared it) and leaves teardown to us.
        s?.pipeline.detach()
        s?.ws.close()
    }
}
