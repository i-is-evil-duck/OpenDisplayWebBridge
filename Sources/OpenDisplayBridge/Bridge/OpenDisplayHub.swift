import Foundation
import Network

/// Listens for an official OpenDisplay **sender** on TCP and advertises the
/// `_opensidecar._tcp` Bonjour service so the stock sender app finds us.
///
/// PROTOCOL.md s.1 fixes the roles: the receiver listens on 9000 and the sender
/// dials. This bridge *is* the receiver (it fronts a browser), so impersonating
/// one is the role-correct move — and it means the sender needs no changes at
/// all, rather than being forked and rewired to speak WebSocket.
///
/// One sender at a time (PROTOCOL.md s.1): a new inbound connection replaces
/// the incumbent.
final class OpenDisplayHub: @unchecked Sendable {
    /// Frames arriving from the sender, stripped of their length prefix.
    var onFrame: ((Data) -> Void)?
    /// Human-readable status for the app log.
    var onStatus: ((String) -> Void)?
    /// Fires whenever a sender connects or disconnects, for UI state.
    var onSenderStateChange: ((Bool) -> Void)?

    /// Additional observers of sender connect/disconnect, for the relay.
    ///
    /// A second slot rather than a list because the UI hook and the relay hook
    /// have different jobs and different lifetimes: the UI wants to drive window
    /// state, the relay wants to tell the receiver when a sender appears or goes
    /// away so it can stop or start reporting "no sender connected". Making
    /// `onSenderStateChange` a list would be tidier, but a single extra slot is
    /// the smaller change and keeps the existing UI wiring untouched.
    /// Lock-guarded, like the rest of this type's callbacks.
    ///
    /// Returns a token for `removeSenderStateObserver`, because the hub outlives
    /// every browser session: an `attach`/`detach` cycle per receiver means a
    /// registration per session, and one that is never removed grows the array
    /// for the life of the process while the stale closures keep firing.
    @discardableResult
    func addSenderStateObserver(_ observer: @escaping (Bool) -> Void) -> ObserverToken {
        lock.lock()
        let token = ObserverToken(id: nextObserverID)
        nextObserverID &+= 1
        senderStateObservers.append((token: token, body: observer))
        lock.unlock()
        return token
    }

    /// Drops a previously registered observer. A token that was never registered,
    /// or already removed, is ignored — removal is idempotent by token.
    func removeSenderStateObserver(_ token: ObserverToken) {
        lock.lock()
        senderStateObservers.removeAll { $0.token == token }
        lock.unlock()
    }

    /// Identifies one registration in `addSenderStateObserver`. Equatable by id
    /// so removal does not depend on closure identity.
    struct ObserverToken: Equatable {
        fileprivate let id: UInt64
    }

    private var nextObserverID: UInt64 = 0
    private var senderStateObservers: [(token: ObserverToken, body: (Bool) -> Void)] = []

    private func senderObserversSnapshot() -> [(Bool) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return senderStateObservers.map(\.body)
    }

    /// Test hook: how many sender-state observers are currently registered.
    /// A relay that attaches and detaches must leave this unchanged.
    var senderStateObserverCount: Int {
        lock.lock(); defer { lock.unlock() }
        return senderStateObservers.count
    }

    private let port: UInt16
    private let lock = NSLock()
    private var sender: NWConnection?
    private var senderShim: NWConnectionShim?
    private var framer = LengthPrefixedFramer()
    private var started = false

    /// Stable per-install identity, advertised as the Bonjour TXT `id`. It MUST
    /// equal the `id` the browser later sends in `hello` (PROTOCOL.md s.2.1).
    let advertisedID: String

    init(port: UInt16 = 9000) {
        self.port = port
        if let existing = UserDefaults.standard.string(forKey: "od-bridge-advertised-id") {
            self.advertisedID = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "od-bridge-advertised-id")
            self.advertisedID = fresh
        }
    }

    var isSenderConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return sender != nil
    }

    func start() throws {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: .tcp, on: p)

        // Advertising is what makes the stock sender dial us. TXT keys are
        // normative (PROTOCOL.md s.2.1): `id` must equal the browser's hello id,
        // `pv` lets the sender check compatibility before connecting.
        let txt = NWTXTRecord(["id": advertisedID, "pv": "3"])
        let name = Host.current().localizedName ?? "OpenDisplay Bridge"
        listener.service = NWListener.Service(name: name, type: "_opensidecar._tcp", txtRecord: txt)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("receiving OpenDisplay senders on :\(self.port) as \(name) [\(self.advertisedID)]")
            case .failed(let err):
                self.onStatus?("ERROR: sender listener failed: \(err)")
            case .cancelled:
                self.onStatus?("sender listener stopped")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.adopt(conn) }
        try listener.start(queue: .global(qos: .userInitiated))
    }

    /// PROTOCOL.md s.1: adopt the newcomer, drop the incumbent.
    private func adopt(_ conn: NWConnection) {
        let shim = NWConnectionShim(conn)
        shim.start()

        lock.lock()
        let incumbentShim = senderShim
        sender = conn
        senderShim = shim
        framer = LengthPrefixedFramer()
        lock.unlock()

        incumbentShim?.close()
        onStatus?("sender connected: \(conn.remoteEndpointString)")
        onSenderStateChange?(true)
        // Invoked with the hub lock released, like every other callback here.
        // These land in the relay, which takes its own lock, and a hub callback
        // that fired under the hub lock would complete a lock cycle.
        for observer in senderObserversSnapshot() { observer(true) }

        Task { [weak self] in
            guard let self else { shim.close(); return }
            await self.readLoop(shim)
            self.lock.lock()
            let stillCurrent = self.senderShim === shim
            if stillCurrent { self.sender = nil; self.senderShim = nil }
            self.lock.unlock()
            shim.close()
            if stillCurrent {
                self.onStatus?("sender disconnected")
                self.onSenderStateChange?(false)
                for observer in self.senderObserversSnapshot() { observer(false) }
            }
        }
    }

    private func readLoop(_ shim: NWConnectionShim) async {
        while true {
            let chunk: Data
            do {
                chunk = try await shim.receiveAtLeast(1)
            } catch {
                return
            }
            if chunk.isEmpty { return }   // EOF

            lock.lock()
            let frames: [Data]
            do {
                frames = try framer.append(chunk)
            } catch {
                lock.unlock()
                onStatus?("ERROR: dropping sender: \(error)")
                return
            }
            let handler = onFrame
            lock.unlock()

            for payload in frames { handler?(payload) }
        }
    }

    /// Browser -> sender. Re-adds the length prefix the binding elides.
    /// Returns false when no sender is connected.
    func send(_ payload: Data) -> Bool {
        lock.lock()
        let shim = senderShim
        lock.unlock()
        guard let shim else { return false }
        Task { try? await shim.send(LengthPrefixedFramer.frame(payload)) }
        return true
    }
}
