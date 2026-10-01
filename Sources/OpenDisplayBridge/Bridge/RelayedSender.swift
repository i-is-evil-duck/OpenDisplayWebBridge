import Foundation

/// A `SenderPipeline` that relays a real OpenDisplay sender's frames to the
/// browser instead of generating a test pattern.
///
/// This is the seam working as intended: the browser session's transport is
/// driven by whatever is on the other end, whether that is `DemoSender` or a
/// stock OpenDisplay app dialling the hub. `Bridge` needs no changes to support
/// either.
///
/// Two downstream modes, chosen from the receiver's advertised capabilities in
/// `hello` (WEBRTC_PLAN.md):
///
/// - `.passthrough` — the receiver can decode H.264 itself, so the sender's
///   bytes go across untouched. Zero work, zero latency, and the norm.
/// - `.webRTC` — the receiver cannot (an old iPad with neither WebCodecs nor
///   MSE), so frames are decoded here and re-encoded as VP8 by libvpx inside
///   WebRTC. Costs a decode/re-encode round trip, because the bridge is a relay
///   and holds no pixels of its own.
enum RelayMode: String {
    case passthrough
    case webRTC
}

/// One receiver's view of a real sender, plus the signaling needed to feed it.
final class RelayedSender: SenderPipeline, @unchecked Sendable {
    private let hub: OpenDisplayHub
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var transport: ODTransport?

    /// Bumped on every attach so a stale hub callback cannot deliver into the
    /// next session. The hub outlives individual browser sessions.
    private var generation: UInt64 = 0

    /// Which generation installed the hub's `onFrame` slot. `detach` may only
    /// clear that slot if this still matches `generation` — otherwise a retiring
    /// session would retract the callback a newer one just installed.
    private var hubFrameGeneration: UInt64?

    /// Whether a `bridgeStatus` has been sent this session. Reset on attach, so
    /// every new receiver is told its mode exactly once even when the mode it
    /// selects is the one already in force.
    private var statusAnnounced = false

    /// Registration in the hub's sender-state observer list, released on detach.
    private var senderStateToken: OpenDisplayHub.ObserverToken?

    private var mode: RelayMode = .passthrough
    private var transcoder: H264Transcoder?
    private var rtc: WebRTCOutput?
    private var keepaliveTask: Task<Void, Never>?
    private var sendStatsTask: Task<Void, Never>?
    private var lastForwardAt: Date?

    init(hub: OpenDisplayHub, logger: @escaping (String) -> Void) {
        self.hub = hub
        self.logger = logger
    }

    /// PROTOCOL.md s.8.2 requires each end to transmit *something* every ~5 s,
    /// because silence means a dead link. When no sender has dialled in there
    /// is nothing to forward, so the receiver's watchdog fires and it reconnects
    /// forever — and each reconnect rebuilds the WebRTC session, so the loop
    /// also prevented a sender from ever being adopted.
    ///
    /// A sender->receiver `ping` is exactly the spec's liveness beat and the
    /// receiver already treats it as a no-op, so sending one is protocol-legal
    /// and needs no change on the browser side. Only sent when nothing else has
    /// gone upstream recently, so a live sender's own pings are never doubled.
    private func startKeepalive() {
        // Under the lock, because `detach` cancels and nils this same field from
        // the WebSocket close observer — and `attach` (which calls this) runs from
        // the HTTP upgrade task. Two threads, one side previously synchronised
        // and one not, on a `@unchecked Sendable` type.
        lock.lock()
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.lock.lock()
                let quiet = self.lastForwardAt.map { Date().timeIntervalSince($0) > 1.5 } ?? true
                let t = self.transport
                self.lock.unlock()
                if quiet { t?.sendFrame(ODControl.encode(["type": "ping", "capFps": 0])) }
            }
        }
        lock.unlock()
    }

    private func noteForwarded() {
        lock.lock()
        lastForwardAt = Date()
        lock.unlock()
    }

    func attach(_ transport: ODTransport) {
        lock.lock()
        self.transport = transport
        statusAnnounced = false
        generation &+= 1
        let gen = generation
        lock.unlock()

        // Browser -> bridge. Control messages go to the sender; rtcOffer is
        // consumed here because signaling is between the bridge and the
        // browser, not with the sender.
        transport.onFrame = { [weak self] payload in
            self?.handleFromBrowser(payload)
        }
        transport.onClose = { [weak self] _ in self?.detach() }

        // Sender -> browser.
        lock.lock()
        hubFrameGeneration = gen
        lock.unlock()
        hub.onFrame = { [weak self] payload in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == gen
            let t = self.transport
            let m = self.mode
            self.lock.unlock()
            guard current, let t else { return }
            self.deliver(payload, mode: m, to: t)
        }

        startKeepalive()

        // Tell the receiver when a sender appears or goes away. Without this the
        // browser's "no sender connected" banner is never re-evaluated, because
        // the bridge otherwise only speaks on mode and decoder changes — so it
        // would stay up, telling the user the opposite of what is happening,
        // for as long as the page was open.
        //
        // The token is kept so `detach` can unregister. The hub outlives
        // individual sessions, so a registration that is never removed
        // accumulated one closure per receiver connection for the life of the
        // process, and every sender connect/disconnect then walked all of them.
        lock.lock()
        senderStateToken = hub.addSenderStateObserver { [weak self] connected in
            self?.pushStatus(reason: connected
                             ? "OpenDisplay sender connected"
                             : "OpenDisplay sender disconnected")
        }
        lock.unlock()

        logger(hub.isSenderConnected
               ? "relaying a connected OpenDisplay sender"
               : "relaying; waiting for a sender to dial :9000")
    }

    func detach() {
        lock.lock()
        let wasMine = (hubFrameGeneration == generation)
        let wasAttached = transport
        generation &+= 1                 // invalidate the hub callback
        keepaliveTask?.cancel()
        keepaliveTask = nil
        sendStatsTask?.cancel()
        sendStatsTask = nil
        self.transport = nil
        let r = rtc
        let t = transcoder
        rtc = nil
        transcoder = nil
        let token = senderStateToken
        senderStateToken = nil
        lock.unlock()

        // Outside the lock, because this takes the hub's own lock and the hub
        // calls back into here under it — nesting the two is the inversion this
        // type's comments keep warning about.
        if let token { hub.removeSenderStateObserver(token) }

        // Only retract the hub's frame callback if it is still the one *this*
        // session installed.
        //
        // `Bridge.adoptPairedConnection` attaches the newcomer and then detaches
        // the incumbent, in that order. An unconditional `hub.onFrame = nil`
        // therefore cleared the slot the newcomer had just installed: the new
        // receiver paired, logged "receiver connected", and then received
        // nothing from the sender for the rest of its life — no frames, no
        // error, `isSenderConnected` still true. The stale callback is already
        // inert because of the generation check above, so the only thing that
        // needed doing was *not* removing someone else's.
        if wasMine {
            hub.onFrame = nil
            lock.lock()
            hubFrameGeneration = nil
            lock.unlock()
        }

        // Outside the lock: both tear down libwebrtc/VideoToolbox sessions, and
        // those wait on callbacks that re-enter. See H264Transcoder.stop().
        t?.stop()
        r?.stop()

        // A final status, on the transport captured above. Without it the
        // receiver's last word is a decoder that no longer exists — the socket
        // closes next, but a stale "VideoToolbox" above that is worse than an
        // honest "none".
        pushStatus(reason: "session ended", transport: wasAttached)
    }

    // MARK: - Receiver diagnostics

    /// Logs a `diag` message from the receiver.
    ///
    /// This exists because a black screen on the iPad was undiagnosable from the
    /// Mac: the console was on the other device, and the Mac-side log could only
    /// prove the *bridge's* half. Paired with `WebRTCOutput.logSendStats`, the
    /// two views bracket the failure — the bridge reports what it decoded and
    /// sent, the receiver reports what arrived and what the video element did
    /// with it. Everything between those two points is where a WebRTC failure
    /// lives, and previously nothing was logged in it.
    private func logDiag(_ msg: [String: Any]) {
        // A follow-up with only rtcStats attached; the main payload is separate.
        if msg["rtcStats"] != nil {
            if let stats = msg["rtcStats"] as? [[String: Any]] {
                for s in stats {
                    logger("DIAG rtc \(s["type"] as? String ?? "?") \(summarise(s))")
                }
            }
            return
        }

        func f(_ key: String) -> String {
            (msg[key] as? NSNumber)?.stringValue
                ?? (msg[key] as? String ?? "-")
        }
        var line = "DIAG recv mode=\(f("mode")) ua=\(f("ua"))"
        line += " caps[wdc=\(f("hasVideoDecoder")) forced=\(f("forcedNoCodecs"))"
        // The receiver's resolution setting, so a change made in its settings
        // panel is visible here rather than only in the browser.
        line += " res=\(f("resMul"))->\(f("maxW"))x\(f("maxH"))]"
        line += " bridge[mode=\(f("mode")) dec=\(f("bridgeDecoder")) sender=\(f("senderConnected"))]"
        line += " decode[saw=\(f("sawVideo")) frames=\(f("totalFrames")) kf=\(f("kfRequests"))"
        line += " mode=\(f("decoderMode")) state=\(f("decoderState")) q=\(f("decodeQueueSize"))"
        line += " sps=\(f("hasSps"))/\(f("spsLen")) size=\(f("videoW"))x\(f("videoH"))]"
        line += " live[bytes=\(f("bytesSinceLast"))s video=\(f("videoSinceLast"))s"
        line += " frame=\(f("frameSinceLast"))s]"
        if let fatal = msg["fatal"] as? String { line += " FATAL=\(fatal)" }
        if let errs = msg["errors"] as? [String], !errs.isEmpty {
            line += " ERRORS=\(errs.joined(separator: " ; "))"
        }
        if let rtc = msg["rtc"] as? [String: Any] {
            line += " rtc[conn=\(describe(rtc["connectionState"]))"
            line += " ice=\(describe(rtc["iceConnectionState"]))"
            line += " sig=\(describe(rtc["signalingState"]))"
            line += " shown=\(describe(rtc["displayedFrames"]))]"
            if let v = rtc["video"] as? [String: Any] {
                line += " video[ready=\(describe(v["readyState"])) paused=\(describe(v["paused"]))"
                line += " net=\(describe(v["networkState"])) \(describe(v["w"]))x\(describe(v["h"]))"
                line += " t=\(describe(v["t"])) src=\(describe(v["hasSrc"]))"
                if let e = v["error"] as? [String: Any] {
                    line += " ERROR=\(describe(e["code"])):\(describe(e["msg"]))"
                }
                line += "]"
            }
            if let vis = rtc["visible"] as? [String: Any] {
                line += " visible[display=\(describe(vis["display"]))"
                line += " vis=\(describe(vis["visibility"])) op=\(describe(vis["opacity"]))"
                line += " css=\(describe(vis["cssW"]))x\(describe(vis["cssH"]))"
                line += " stage=\(describe(vis["inStage"])) canvas=\(describe(vis["canvasDisplay"]))"
                line += " top=\(describe(rtc["onTop"])) isVideo=\(describe(rtc["onTopIsVideo"]))]"
            }
            if let tracks = rtc["tracks"] as? [[String: Any]] {
                for t in tracks {
                    line += " track[\(describe(t["kind"])) id=\(describe(t["id"]))"
                    line += " muted=\(describe(t["muted"])) state=\(describe(t["readyState"]))]"
                }
            }
        }
        logger(line)
    }

    private func describe(_ any: Any?) -> String {
        guard let any else { return "-" }
        if let n = any as? NSNumber { return n.stringValue }
        return any as? String ?? "-"
    }

    /// Reduces a stats entry to the handful of numbers that matter, so the log
    /// stays readable. The full object is large and mostly constant.
    private func summarise(_ s: [String: Any]) -> String {
        let keys = ["kind", "mediaType", "bytesReceived", "packetsReceived",
                    "packetsLost", "framesDecoded", "framesDropped", "jitter",
                    "frameWidth", "frameHeight", "state", "nominated",
                    "currentRoundTripTime", "availableOutgoingBitrate"]
        let parts = keys.compactMap { k -> String? in
            guard let v = s[k] else { return nil }
            if let n = v as? NSNumber { return "\(k)=\(n)" }
            if let str = v as? String { return "\(k)=\(str)" }
            return nil
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Mode selection

    /// Picks the downstream mode from what the receiver said it can do.
    ///
    /// `hello` arrives on the same socket, so this runs before any video. A
    /// receiver that can decode H.264 gets the untouched fast path; one that
    /// cannot but can do WebRTC gets the transcode.
    private func handleHello(_ msg: [String: Any]) {
        let webcodecs = (msg["webcodecs"] as? NSNumber)?.boolValue ?? false
        let rtcCapable = (msg["rtc"] as? NSNumber)?.boolValue ?? false
        let newMode: RelayMode = (webcodecs || !rtcCapable) ? .passthrough : .webRTC

        lock.lock()
        // `mode` starts at `.passthrough`, so a WebCodecs-capable receiver's
        // first `hello` selects the mode it is already in and "changed" is false.
        // Without this flag that first session would never be told anything, and
        // an unannounced mode is indistinguishable from a session that never got
        // going at all.
        let changed = (newMode != mode) || !statusAnnounced
        mode = newMode
        statusAnnounced = true
        lock.unlock()

        guard changed else { return }
        if newMode == .webRTC {
            logger("receiver cannot decode H.264 — switching to WebRTC/VP8")
            startWebRTC()
        } else {
            logger("receiver decodes H.264 natively — forwarding bytes untouched")
            stopWebRTC()
        }
        // Sent unlocked, and after the change has been applied, so the receiver
        // learns the mode it is actually in rather than the one being left.
        pushStatus(reason: newMode == .webRTC
                   ? "receiver cannot decode H.264; using WebRTC/VP8"
                   : "receiver decodes H.264 natively; forwarding bytes")
    }

    private func startWebRTC() {
        // Constructed and started *outside* the lock.
        //
        // `H264Transcoder.init` takes its own lock (via `setBackend`) and
        // `WebRTCOutput.start()` takes another while calling into libwebrtc, so
        // building them under `RelayedSender.lock` nests three locks. Worse, the
        // transcoder's `onStatus` closure is wired to `pushStatus`, which takes
        // `RelayedSender.lock` — so any status emitted during construction would
        // be a self-deadlock on this thread.
        lock.lock()
        let alreadyRunning = rtc != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let out = WebRTCOutput()
        out.onStatus = { [weak self] message in
            guard let self else { return }
            self.logger("rtc: \(message)")
            self.pushStatus(reason: "rtc: \(message)")
        }
        out.start()

        let dec = H264Transcoder()
        // The transcoder's status is where "which decoder is actually working"
        // becomes known, so it is both logged and pushed to the browser.
        dec.onStatus = { [weak self] message in
            guard let self else { return }
            self.logger(message)
            self.pushStatus(reason: message)
        }
        // Decoded pixels go straight into libwebrtc; zero copy.
        dec.onFrame = { [weak out] buffer, timestampNs in
            out?.submit(buffer, captureTimeNs: timestampNs)
        }

        // Publish only if nothing else got here first. Two receivers swapping
        // can both reach this point; the loser is torn down rather than left
        // running with nothing referencing it.
        lock.lock()
        let winner = (rtc == nil)
        if winner {
            rtc = out
            transcoder = dec
        }
        lock.unlock()
        guard winner else {
            dec.stop()
            out.stop()
            return
        }

        // Periodic libwebrtc stats.
        //
        // Without this there is no way to tell "decoded 150 frames but never
        // reached the encoder" from "decoded 150 frames and all 150 arrived",
        // because only the decode count is ever logged. That ambiguity is what
        // made an empty iPad screen undiagnosable from the Mac side.
        sendStatsTask?.cancel()
        sendStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.lock.lock()
                let live = self.rtc
                self.lock.unlock()
                live?.logSendStats()
            }
        }

        pushStatus(reason: "webRTC session started")
    }

    private func stopWebRTC() {
        lock.lock()
        let r = rtc, t = transcoder
        rtc = nil
        transcoder = nil
        lock.unlock()
        // Outside the lock: both tear down libwebrtc/VideoToolbox sessions, and
        // those wait on callbacks that re-enter. See H264Transcoder.stop().
        t?.stop()
        r?.stop()
        pushStatus(reason: "webRTC session stopped")
    }

    // MARK: - Telling the browser what the bridge is actually doing

    /// Pushes the bridge's own view of the session to the receiver.
    ///
    /// ## Why this exists
    ///
    /// A black screen is the failure mode of this whole project, and until now
    /// it was indistinguishable from a working session that simply had nothing
    /// to show. The receiver's stats overlay counted frames on the WebCodecs
    /// path only; on the WebRTC path `pc.ontrack` wired up a `<video>` element
    /// and returned, so `frames` stayed at 0 and the overlay read "0 fps 0.0
    /// Mb/s" whether video was flowing or not. On the iPad — the one device this
    /// exists for — that made the overlay actively misleading.
    ///
    /// So the browser now gets two things it did not have: real counters read
    /// from `RTCPeerConnection.getStats()` on the WebRTC path, and a `bridgeStatus`
    /// message naming the active mode and decoder. A user reporting "black
    /// screen" can now be answered with which half is broken instead of a guess.
    ///
    /// This is a bridge-originated control message. PROTOCOL.md s.6 governs the
    /// receiver's messages to the sender and says nothing about the reverse, and
    /// the receiver is explicitly required to ignore message types it does not
    /// know, so adding one is protocol-legal.
    /// - Parameter transport: overrides the attached transport. `detach` passes
    ///   the one it just detached, because by the time it reports the teardown
    ///   the field is already nil and an early return would swallow the message —
    ///   leaving the receiver's last word as a decoder that no longer exists.
    private func pushStatus(reason: String, transport explicit: ODTransport? = nil) {
        lock.lock()
        let transport = explicit ?? self.transport
        let mode = self.mode
        let decoder = self.transcoder?.backendName ?? "none"
        lock.unlock()

        // Built and sent outside the lock. This closure is assigned to
        // `H264Transcoder.onStatus`, and that object emits status from inside
        // its own critical section in at least one path — so if this took
        // `RelayedSender.lock` we would have `RelayedSender.lock` ->
        // `H264Transcoder.lock` (via `H264Transcoder.init` -> `setBackend`) on
        // one path and the exact inverse on the other, and the pair deadlocks.
        // Copying the values out and sending unlocked removes the inverse edge
        // rather than relying on the other half never firing.
        //
        // `hub.isSenderConnected` is also read here, deliberately *before*
        // taking this lock, so `OpenDisplayHub.lock` is never nested inside
        // `RelayedSender.lock`. That direction is safe today only because every
        // hub callback happens to release its own lock first — a property worth
        // not depending on from a hot path.
        guard let transport else { return }
        let senderConnected = hub.isSenderConnected
        let payload: [String: Any] = [
            "type": "bridgeStatus",
            "mode": mode.rawValue,
            "decoder": decoder,
            "reason": reason,
            "senderConnected": senderConnected,
            "t": ODControl.nowMs(),
        ]
        transport.sendFrame(ODControl.encode(payload))
    }

    // MARK: - Frame routing

    private func deliver(_ payload: Data, mode: RelayMode, to transport: ODTransport) {
        switch mode {
        case .passthrough:
            // The browser demuxes for itself.
            noteForwarded()
            transport.sendFrame(payload)
        case .webRTC:
            // Control must still reach the browser over the socket: it carries
            // welcome, streamConfig, the 2 s liveness ping and input. Only video
            // is transcoded. Feeding control into the decoder would starve the
            // receiver's watchdog and loop the session.
            if ODDemux.isControl(payload) {
                noteForwarded()
                transport.sendFrame(payload)
                return
            }
            lock.lock()
            let t = transcoder
            lock.unlock()
            t?.ingest(payload)
        }
    }

    /// A frame from the browser. Control JSON, and possibly an rtcOffer.
    private func handleFromBrowser(_ payload: Data) {
        // Every receiver->sender message is JSON, so no demux is needed
        // (PROTOCOL.md 4). Non-JSON is ignored, not fatal.
        guard let msg = ODControl.parse(payload), let type = msg["type"] as? String else {
            hub.send(payload)
            return
        }

        switch type {
        case "hello":
            handleHello(msg)
            hub.send(payload)          // the sender also needs hello
        case "rtcOffer":
            handleRTCOffer(msg)
        case "diag":
            // Receiver-side diagnostics. Consumed here and never forwarded: the
            // receiver is the only place some failures are visible, and its
            // console is unreachable from the Mac.
            logDiag(msg)
        case "stats", "sleeping", "closing", "kf":
            hub.send(payload)
        default:
            // touch/scroll/stats and anything a newer receiver sends: forward
            // untouched. Unknown types are ignored BY THE SENDER, not here.
            if !hub.send(payload) {
                logger("dropped \(type): no sender connected")
            }
        }
    }

    // MARK: - WebRTC signaling

    /// Non-trickle: the answer carries its own candidates, so there is no
    /// separate rtcIce exchange (PROTOCOL.md's role split does not apply to a
    /// browser that cannot listen for UDP).
    private func handleRTCOffer(_ msg: [String: Any]) {
        guard let sdp = msg["sdp"] as? String, !sdp.isEmpty else {
            logger("rtcOffer with no sdp")
            return
        }
        lock.lock()
        let out = rtc
        let t = transport
        lock.unlock()

        guard let out else {
            // The receiver offered before we chose WebRTC, or after teardown.
            send(["type": "rtcAnswer", "error": "bridge not in WebRTC mode"], to: t)
            return
        }

        out.handleOffer(sdp) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let answer):
                self.send(["type": "rtcAnswer", "sdp": answer], to: t)
            case .failure(let error):
                self.logger("rtcOffer rejected: \(error)")
                self.send(["type": "rtcAnswer", "error": "\(error)"], to: t)
            }
        }
    }

    private func send(_ obj: [String: Any], to transport: ODTransport?) {
        transport?.sendFrame(ODControl.encode(obj))
    }
}
