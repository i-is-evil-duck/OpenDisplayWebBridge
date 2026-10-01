import Foundation
import Network

/// Embedded HTTP server: serves the web receiver app, handles POST /pair,
/// and upgrades paired GET /od requests to WebSocket (the bridge binding).
final class HTTPServer: @unchecked Sendable {
    /// WebRTC diagnostic surface (WEBRTC_PLAN.md W0.3). Off unless
    /// OD_RTC_PROBE=1: `POST /rtc/offer` negotiates a peer connection and
    /// answers with an SDP. Not part of the receiver binding, so it must not be
    /// reachable on a LAN port by default.
    var rtcProbe: WebRTCOutput?
    let rtcProbeEnabled: Bool

    private let listener: NWListener
    private let pairing: PairingStore
    private let onWSConnection: (WebSocketConnection) -> Void
    private let onConnectionClosed: () -> Void
    /// Injected into the pair page so the browser's `hello.id` matches the
    /// advertised Bonjour TXT record (PROTOCOL.md s.2.1).
    var advertisedID: String = ""
    var onClientCount: (@Sendable (Int) -> Void)?
    /// Fires only when an *upgraded receiver* goes away. `onConnectionClosed`
    /// fires for every TCP connection including plain page loads, so it must not
    /// be used to decide whether a receiver is attached.
    var onReceiverClosed: (() -> Void)?

    private let lock = NSLock()
    private var clientCount = 0

    init(port: UInt16,
         pairing: PairingStore,
         onWSConnection: @escaping (WebSocketConnection) -> Void,
         onConnectionClosed: @escaping () -> Void) throws {
        self.rtcProbeEnabled = ProcessInfo.processInfo.environment["OD_RTC_PROBE"] != nil
        self.pairing = pairing
        self.onWSConnection = onWSConnection
        self.onConnectionClosed = onConnectionClosed
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        self.listener = try NWListener(using: .tcp, on: p)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: .global(qos: .userInitiated))
    }

    /// Who owns the socket once `serveHTTP` returns.
    private enum Disposition {
        /// The HTTP conversation is over; the caller may close and unaccount it.
        case finished
        /// Upgraded to WebSocket — the WS layer owns the socket from here. The
        /// caller must NOT close it; unaccounting is wired to the WS close.
        case upgraded
    }

    private func handle(_ nwConn: NWConnection) {
        let shim = NWConnectionShim(nwConn)
        shim.start()
        bumpClients(+1)
        Task { [weak self] in
            guard let self else { shim.close(); return }
            var disposition = Disposition.finished
            do {
                disposition = try await self.serveHTTP(shim)
            } catch {
                // Connection died mid-conversation — normal for browsers.
            }
            // An upgraded socket belongs to the WebSocket layer now. Closing it
            // here (and decrementing) would kill a live receiver and double-count
            // it, so hand back ownership instead of tearing it down.
            guard case .finished = disposition else { return }
            shim.close()
            self.bumpClients(-1)
            self.onConnectionClosed()
        }
    }

    private func bumpClients(_ delta: Int) {
        lock.lock(); clientCount += delta; let n = clientCount; lock.unlock()
        onClientCount?(n)
    }

    private func serveHTTP(_ conn: NWConnectionShim) async throws -> Disposition {
        var keepAlive = true
        while keepAlive {
            // A parse failure is answered where we can, rather than dropped on
            // the floor. `readOne` is the only place that knows *why* a request
            // was refused, and the caller is a browser: a bare TCP close looks
            // like the Mac went away, whereas a 431 says the request was too big
            // and the page can carry on.
            let req: HTTPRequest
            do {
                guard let r = try await HTTPParser.readOne(from: conn) else { return .finished }
                req = r
            } catch HTTPParseError.bodyTooLarge {
                try? await HTTPResponseWriter(conn: conn).status(
                    413, "Payload Too Large",
                    body: Data("request body too large".utf8))
                return .finished
            } catch HTTPParseError.headerTooLarge {
                try? await HTTPResponseWriter(conn: conn).status(
                    431, "Request Header Fields Too Large",
                    body: Data("request headers too large".utf8))
                return .finished
            }
            keepAlive = (req.header("connection")?.lowercased() != "close")

            // Route on the path only. `req.target` carries the query string, so
            // comparing it exactly against "/" 404s every request that has one
            // (a cache-buster, or the ?nocodecs=1 fallback override).
            let path = req.target.split(separator: "?", maxSplits: 1).first
                        .map(String.init) ?? req.target

            if req.method == "GET", path == "/od", isWebSocketUpgrade(req) {
                guard let token = PairingStore.token(from: req.header("cookie")), pairing.isValid(token) else {
                    try await HTTPResponseWriter(conn: conn).status(403, "Forbidden", body: Data("pair first".utf8))
                    continue
                }
                try await performUpgrade(req, conn: conn)
                return .upgraded   // socket ownership transferred; stop the HTTP loop
            }

            let writer = HTTPResponseWriter(conn: conn)
            switch (req.method, path) {
            case ("GET", "/"), ("GET", "/index.html"):
                try await writer.status(200, "OK", headers: Self.webHeaders(
                    contentType: "text/html; charset=utf-8"),
                                        body: webResource("index.html"))
            case ("GET", "/receiver.js"):
                try await writer.status(200, "OK", headers: Self.webHeaders(
                    contentType: "text/javascript; charset=utf-8"),
                                        body: webResource("receiver.js"))
            case ("POST", "/pair"):
                try await handlePair(req, writer: writer)
            case ("POST", "/rtc/offer"):
                guard rtcProbeEnabled, let probe = rtcProbe else {
                    try await writer.status(404, "Not Found", body: Data("rtc probe disabled".utf8))
                    return .finished
                }
                try await handleRTCOffer(req, probe: probe, writer: writer)
            case ("GET", "/rtcprobe"):
                guard rtcProbeEnabled else {
                    try await writer.status(404, "Not Found", body: Data("rtc probe disabled".utf8))
                    return .finished
                }
                try await writer.status(200, "OK",
                                        headers: ["Content-Type": "text/html; charset=utf-8"],
                                        body: webResource("rtcprobe.html"))
            case ("GET", "/favicon.ico"):
                try await writer.status(204, "No Content")
            default:
                try await writer.notFound()
            }
        }
        return .finished   // fell out of the keep-alive loop
    }

    private func handlePair(_ req: HTTPRequest, writer: HTTPResponseWriter) async throws {
        // A locked-out client gets a distinct, honest answer rather than another
        // "invalid code". Telling a legitimate user to wait is actionable; making
        // them think the code they can read off the screen is wrong is not.
        if pairing.isLockedOut {
            try await writer.json(["ok": false,
                                   "error": "too many attempts, try again shortly",
                                   "retryAfter": Int(pairing.lockoutRemaining.rounded())],
                                  code: 429,
                                  extraHeaders: ["Retry-After": "\(Int(pairing.lockoutRemaining.rounded()))"])
            return
        }
        let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
        let code = obj?["code"] as? String ?? ""
        guard pairing.verify(code) else {
            try await writer.json(["ok": false, "error": "invalid code"], code: 403)
            return
        }
        let token = pairing.issueToken()
        try await writer.json(["ok": true],
                              extraHeaders: ["Set-Cookie": "odpair=\(token); Path=/; SameSite=Strict"])
    }

    private func isWebSocketUpgrade(_ req: HTTPRequest) -> Bool {
        (req.header("upgrade")?.lowercased().contains("websocket") ?? false) &&
        req.header("sec-websocket-key") != nil
    }

    private func performUpgrade(_ req: HTTPRequest, conn: NWConnectionShim) async throws {
        let key = req.header("sec-websocket-key")!
        // permessage-deflate is declined by omission: no Sec-WebSocket-Extensions
        // header is echoed, so nothing is negotiated and RFC 6455 clients must
        // not use it. Binary H.264 does not compress and the CPU cost is real.
        // (Deliberately NOT an explicit rejection — do not "fix" this into a
        // negotiation path.)
        let accept = WebSocketHandshake.acceptKey(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        try await conn.send(Data(response.utf8))

        let ws = WebSocketConnection(conn: conn)
        // The HTTP task will not touch this socket again, so unaccount for it
        // here instead — otherwise the client count climbs forever and the
        // "receiver disconnected" callback never fires for a real receiver.
        ws.observeClose { [weak self] _ in
            self?.bumpClients(-1)
            self?.onReceiverClosed?()
        }
        onWSConnection(ws)
    }

    /// Non-trickle offer/answer over HTTP (WEBRTC_PLAN.md W0.3 spike). The
    /// production path moves this onto the receiver's existing WebSocket in W1;
    /// this exists only to prove frames reach a browser.
    private func handleRTCOffer(_ req: HTTPRequest, probe: WebRTCOutput,
                                writer: HTTPResponseWriter) async throws {
        struct OfferBody: Decodable { var sdp: String }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let sdp = obj["sdp"] as? String, !sdp.isEmpty else {
            try await writer.json(["ok": false, "error": "missing sdp"], code: 400)
            return
        }

        // Answering waits for ICE gathering to complete so the SDP carries
        // candidates. Bound it: a browser that never triggers .complete would
        // otherwise hang this request forever.
        let answer: String? = await withCheckedContinuation { cont in
            var resumed = false
            let once = NSLock()
            let finish: (Result<String, Error>) -> Void = { r in
                once.lock(); defer { once.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: (try? r.get()))
            }
            probe.handleOffer(sdp) { result in
                if case .failure(let error) = result { probe.onStatus?("offer failed: \(error)") }
                finish(result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                finish(.failure(WebRTCOutput.WebRTCError.timedOutWaitingForGathering))
            }
        }

        guard let answer else {
            try await writer.json(["ok": false, "error": "no answer (gathering timeout)"], code: 504)
            return
        }
        try await writer.json(["ok": true, "sdp": answer])
    }

    /// Web assets must not be cached. The client is served from the same
    /// bundle as the bridge, so a cached receiver.js keeps running against a
    /// newer bridge after an update — which showed up as a stale page serving a
    /// fixed ReferenceError long after it was corrected on disk.
    private static func webHeaders(contentType: String) -> [String: String] {
        ["Content-Type": contentType, "Cache-Control": "no-store, must-revalidate"]
    }

    private func webResource(_ name: String) -> Data {
        // NOTE: Package.swift declares `.process("Web")`, and `.process`
        // *flattens* the directory — the bundle ends up with
        // Contents/Resources/index.html, not Contents/Resources/Web/index.html.
        // Passing a `subdirectory:` here silently yields nil, so don't.
        guard let url = Bundle.module.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            return Data("missing web resource: \(name)".utf8)
        }
        guard name == "index.html" else { return data }

        // PROTOCOL.md s.2.1: the hello `id` MUST equal the advertised Bonjour
        // TXT `id`. Inject it rather than duplicating id logic in the page.
        let id = advertisedID.replacingOccurrences(of: "<", with: "\\u003c")
        let html = String(decoding: data, as: UTF8.self)
        let patched = html.replacingOccurrences(
            of: "<script src=\"/receiver.js\"></script>",
            with: "<script>window.OD_ADVERTISED_ID=\"\(id)\";</script>"
               + "<script src=\"/receiver.js\"></script>")
        guard patched != html else { return data }   // marker not found; serve as-is
        return Data(patched.utf8)
    }
}
