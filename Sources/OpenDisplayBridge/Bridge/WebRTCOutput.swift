import CoreVideo
import Foundation
import WebRTC

/// WebRTC output path (WEBRTC_PLAN.md).
///
/// A browser cannot decode H.264 below iOS 16.4 (no WebCodecs) or below iOS 13
/// (no MSE), so an old iPad has exactly one in-browser route: WebRTC, which
/// works from iOS 11. libwebrtc supplies DTLS, SRTP, ICE and congestion
/// control, so this type only moves pixels into it.
///
/// The bridge is a *relay*: `OpenDisplay.app` sends us H.264 and we forward it
/// untouched, so this path is a decode/re-encode round trip
/// (`VTDecompressionSession` -> `CVPixelBuffer` -> encoder). Frames are handed
/// over zero-copy via `RTCCVPixelBuffer`.
///
/// Codec is **VP8**, not H.264. libwebrtc statically links libvpx, so VP8 ships
/// inside the dependency already being accepted at zero extra bytes, and VP8 is
/// the mandatory-to-implement WebRTC codec — every receiver supports it. H.264
/// inside WebRTC is finicky (`profile-level-id`, `packetization-mode`) and
/// would need a hardware encoder this process cannot currently reach. H.264
/// remains on the WebCodecs path, where it is forwarded as bytes, never encoded.
final class WebRTCOutput: NSObject, RTCPeerConnectionDelegate {
    enum WebRTCError: Error, CustomStringConvertible {
        case notStarted
        case badRemoteDescription(String)
        case createAnswerFailed(String)
        case timedOutWaitingForGathering
        /// A newer `rtcOffer` replaced this one before the answer was ready.
        case supersededByNewOffer

        var description: String {
            switch self {
            case .notStarted: return "WebRTC not started"
            case .badRemoteDescription(let m): return "setRemoteDescription failed: \(m)"
            case .createAnswerFailed(let m): return "answer(for:) failed: \(m)"
            case .timedOutWaitingForGathering: return "timed out waiting for ICE gathering"
            case .supersededByNewOffer: return "replaced by a newer offer"
            }
        }
    }

    /// VP8 payload type 96 in the SDP; libwebrtc picks its own encoder.
    private static let mediaStreamId = "od"

    private let lock = NSLock()
    private var factory: RTCPeerConnectionFactory?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var connection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var configuration: RTCConfiguration?

    // Non-trickle ICE: the answer is returned only once gathering completes, so
    // both SDPs carry their full candidate lists. There is no STUN/TURN — both
    // peers are on the same LAN and host candidates are reachable directly.
    /// The in-flight `handleOffer` completion, tagged with the peer connection
    /// it belongs to.
    ///
    /// A single unnamed slot was a real bug: a second offer overwrote it while
    /// the first offer's `awaitGathering` poll was still running, so the first
    /// request's `withCheckedContinuation` was never resumed and hung until the
    /// HTTP timeout, while the second request was answered with the *first*
    /// peer's SDP. Tagging it means a stale poll can tell that it is stale and
    /// drop out, and a superseded request is failed rather than orphaned.
    private var answerPending: (pc: RTCPeerConnection,
                                completion: (Result<String, Error>) -> Void)?
    private(set) var gatheringComplete = false

    var onStatus: ((String) -> Void)?

    /// How many decoded frames have been handed to libwebrtc, and how many were
    /// dropped for want of a source/capturer.
    ///
    /// Purely diagnostic, but it closes a gap that made this bug undiagnosable:
    /// the bridge logs "decoded 150 frames", which proves H.264 decode worked and
    /// says *nothing* about whether any of those frames reached the encoder. A
    /// silent failure in `submit` looks identical from the log to a healthy
    /// session, because the only visible number is the decode count.
    private(set) var submittedFrames = 0
    private(set) var droppedFrames = 0
    private(set) var lastSubmitError: String?

    /// Polls libwebrtc's own outbound statistics.
    ///
    /// This is the authoritative answer to "is anything actually being sent?".
    /// It reports the codec libwebrtc negotiated, packets sent, bytes sent and
    /// frames encoded — so a VP8 encoder that never started, a track that was
    /// never attached, or a peer that negotiated nothing each have a distinct
    /// signature, where before the only evidence was silence.
    ///
    /// Uses `statistics(completionHandler:)`, the v2 spec-compliant API this SDK
    /// exposes. The older `getStats` does not exist on `RTCPeerConnection` here,
    /// and the v1 form reports legacy keys rather than `outbound-rtp`.
    func logSendStats() {
        lock.lock()
        let pc = connection
        lock.unlock()
        guard let pc else { onStatus?("send-stats: no peer connection"); return }

        pc.statistics { report in
            // `values` is `[String: NSObject]`, so every read needs an explicit
            // coercion — letting one fall through to interpolation infers
            // `String.Stride` and fails to compile.
            func num(_ v: [String: NSObject], _ k: String) -> String {
                (v[k] as? NSNumber).map { "\($0)" } ?? "?"
            }
            func str(_ v: [String: NSObject], _ k: String, _ fallback: String) -> String {
                (v[k] as? String) ?? fallback
            }

            for stat in report.statistics.values {
                let v = stat.values
                switch stat.type {
                case "outbound-rtp":
                    self.onStatus?("send-rtp \(str(v, "kind", str(v, "mediaType", "?"))): "
                                   + "\(num(v, "framesEncoded")) frames, "
                                   + "\(num(v, "packetsSent")) pkts, "
                                   + "\(num(v, "bytesSent")) bytes, "
                                   + "nack=\(num(v, "nackCount")) pli=\(num(v, "pliCount"))")
                case "codec":
                    let mime = str(v, "mimeType", "?")
                    if mime.contains("VP8") || mime.contains("VP9") || mime.contains("H264") {
                        self.onStatus?("codec \(mime) payload=\(num(v, "payloadType"))")
                    }
                case "candidate-pair":
                    self.onStatus?("candidate-pair state=\(str(v, "state", "?")) "
                                   + "nominated=\(num(v, "nominated"))")
                case "local-candidate", "remote-candidate":
                    self.onStatus?("\(stat.type) \(str(v, "address", "?"))"
                                   + ":\(num(v, "port")) type=\(str(v, "candidateType", "?"))")
                default:
                    break
                }
            }
        }
    }

    /// True once the peer connection reports connected — the point at which
    /// pushing frames is worth doing.
    ///
    /// Lock-guarded on both sides. It is written from libwebrtc's signaling
    /// thread (in the ICE-state delegate) and read from a detached task in
    /// `AppState.startRTCProbePump`, so an unsynchronised read here is a race
    /// even though a `Bool` load will not tear.
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }
    private var _isConnected = false

    /// Finds a codec by name from the encoder factory's supported list.
    ///
    /// The `RTCVideoCodecInfo` values are opaque — there is no public constructor
    /// and no public initialiser taking a name — so the only way to select one is
    /// to find it in `supportedCodecs()`.
    private static func codecInfo(named name: String) -> RTCVideoCodecInfo? {
        for info in RTCDefaultVideoEncoderFactory.supportedCodecs() {
            let n = info.name
            if n.uppercased() == name.uppercased() { return info }
            // `name` is often "VP8" or "VP8/90000"; match either shape.
            if n.uppercased().hasPrefix(name.uppercased() + "/")
                || n.uppercased().hasPrefix(name.uppercased()) {
                return info
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard factory == nil else { return }

        // Required before any peer connection is created.
        RTCInitializeSSL()

        // Force VP8, and say loudly if that fails.
        //
        // libwebrtc's default preference picks H264, whose macOS encoder is
        // VideoToolbox-backed — and VideoToolbox *encode* is exactly what the
        // host gates for unsigned processes. `EncoderReport` demonstrates it: no
        // encoders are enumerated and `EncodeFrame` returns kVTParameterErr
        // (-12902). The result is the worst possible failure: the encoder is
        // created, accepts frames, reports no error, and encodes **zero** of
        // them. The receiver then shows a black screen with a perfectly healthy
        // peer connection.
        //
        // This was invisible until the send statistics were logged, which showed
        // `codec video/H264` alongside `send-rtp video: 0 frames, 0 pkts`. That
        // pair is the signature: frames submitted, none encoded, H264 negotiated.
        //
        // VP8 is libvpx — pure software, statically linked into libwebrtc, and
        // not subject to any of that. It is also the mandatory-to-implement
        // WebRTC codec, so every receiver has it.
        let encFactory = RTCDefaultVideoEncoderFactory()
        if let vp8 = Self.codecInfo(named: "VP8") {
            encFactory.preferredCodec = vp8
            onStatus?("encoder: preferring VP8 (H264 encode is VideoToolbox-gated here)")
        } else {
            onStatus?("encoder: WARNING could not find a VP8 codec; libwebrtc may "
                      + "negotiate H264, whose encoder cannot run unsigned")
        }
        let decFactory = RTCDefaultVideoDecoderFactory()

        let f = RTCPeerConnectionFactory(encoderFactory: encFactory, decoderFactory: decFactory)
        let s = f.videoSource()
        let track = f.videoTrack(with: s, trackId: "video")
        // RTCVideoSource conforms to RTCVideoCapturerDelegate; the capturer is
        // only an identity token for the callback.
        let c = RTCVideoCapturer(delegate: s)

        // Host candidates only. An empty iceServers list means no STUN/TURN,
        // which is correct for a LAN session and avoids leaking traffic to a
        // third-party STUN server.
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        // gatherOnce, NOT gatherContinually: continual gathering never settles
        // on .complete, so a non-trickle handshake waiting for completion stalls
        // until its own timeout (measured: a flat 6 s added to every connection
        // setup). One gather is all a LAN session needs.
        config.continualGatheringPolicy = .gatherOnce
        config.iceCandidatePoolSize = 0

        factory = f
        source = s
        capturer = c
        videoTrack = track
        configuration = config
    }

    // MARK: - Signaling (non-trickle)

    /// Answers a browser offer. Completes once ICE gathering has finished, so
    /// the returned SDP already contains host candidates.
    func handleOffer(_ offerSdp: String,
                     completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        let f = factory, config = configuration, track = videoTrack
        let existing = connection
        lock.unlock()

        guard let f, let config, let track else {
            return completion(.failure(WebRTCError.notStarted))
        }

        // One connection at a time; a new offer replaces the old.
        if let existing { existing.close() }

        // constraints is non-optional in the Swift import; an empty pair means
        // "no m=section constraints", which is what we want.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)
        let pcDelegate = self
        let pc = f.peerConnection(with: config, constraints: constraints, delegate: pcDelegate)
        guard let pc else {
            return completion(.failure(WebRTCError.createAnswerFailed("peerConnection returned nil")))
        }
        pc.add(track, streamIds: [Self.mediaStreamId])

        lock.lock()
        connection = pc
        gatheringComplete = false
        // Fail the previous request rather than dropping it on the floor. Its
        // HTTP caller is parked on a continuation and will sit there until the
        // server's own timeout if nobody resumes it.
        let superseded = answerPending?.completion
        answerPending = (pc, completion)
        lock.unlock()
        superseded?(.failure(WebRTCError.supersededByNewOffer))

        let offer = RTCSessionDescription(type: .offer, sdp: offerSdp)
        pc.setRemoteDescription(offer) { [weak self] (error: Error?) in
            guard let self else { return }
            if let error {
                return self.finishAnswer(pc, .failure(WebRTCError.badRemoteDescription(error.localizedDescription)))
            }
            pc.answer(for: constraints) { answer, error in
                if let error {
                    return self.finishAnswer(pc, .failure(WebRTCError.createAnswerFailed(error.localizedDescription)))
                }
                guard let answer else {
                    return self.finishAnswer(pc, .failure(WebRTCError.createAnswerFailed("nil answer")))
                }
                pc.setLocalDescription(answer) { (error: Error?) in
                    if let error {
                        return self.finishAnswer(pc, .failure(WebRTCError.createAnswerFailed(error.localizedDescription)))
                    }
                    // Wait for ICE gathering to finish so the returned SDP
                    // carries candidates. Polled rather than taken from the
                    // delegate callback: gathering state is authoritative and
                    // this does not depend on the delegate overload being
                    // dispatched, which is easy to get wrong when three
                    // `didChange:` selectors share a Swift name.
                    self.awaitGathering(pc)
                }
            }
        }
    }

    /// Polls to `complete`, then answers with the local SDP.
    private func awaitGathering(_ pc: RTCPeerConnection) {
        let deadline = Date().addingTimeInterval(6)
        func tick() {
            // A newer offer replaced this one while we were polling. Answering
            // now would hand the *new* request this stale connection's SDP.
            lock.lock()
            let stale = (answerPending?.pc !== pc)
            lock.unlock()
            if stale { return }

            let state = pc.iceGatheringState
            if state == .complete {
                lock.lock(); gatheringComplete = true; lock.unlock()
                return finishAnswer(pc, .success(pc.localDescription?.sdp ?? ""))
            }
            if Date() >= deadline {
                // Answer anyway: a LAN session can still connect on whatever
                // candidates gathered so far, and failing closed here would
                // strand a receiver that could have worked.
                lock.lock(); gatheringComplete = true; lock.unlock()
                onStatus?("gathering timed out at \(state.rawValue); answering with partial candidates")
                return finishAnswer(pc, .success(pc.localDescription?.sdp ?? ""))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { tick() }
        }
        tick()
    }

    /// Resumes the pending offer, but only if `pc` is still the one waiting.
    /// A late callback from a superseded connection must not consume the new
    /// request's continuation.
    private func finishAnswer(_ pc: RTCPeerConnection, _ result: Result<String, Error>) {
        lock.lock()
        guard let pending = answerPending, pending.pc === pc else {
            lock.unlock()
            return
        }
        answerPending = nil
        lock.unlock()
        pending.completion(result)
    }

    // MARK: - RTCPeerConnectionDelegate
    //
    // Swift imports every ObjC optional protocol method as a *required* one, so
    // all of these must exist even though most are unused by a send-only peer.

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        onStatus?("signalling: \(stateChanged.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // Runs on libwebrtc's signaling thread. `isConnected` is read by
        // `AppState.startRTCProbePump` from a detached task, and `stop()` writes
        // it under `lock`, so writing it here without the lock left a
        // synchronised field being mutated unsynchronised. Every other accessor
        // in this type takes the lock; this was the one that did not.
        let connected = (newState == .connected || newState == .completed)
        lock.lock()
        _isConnected = connected
        lock.unlock()
        onStatus?("ice: \(newState.rawValue)\(connected ? " (connected)" : "")")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        onStatus?("gathering: \(newState.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - Media

    /// Pushes one decoded frame. `pixelBuffer` is wrapped, not copied, so it
    /// must stay alive until the call returns.
    ///
    /// - Parameter captureTimeNs: monotonically increasing nanoseconds. No PTS
    ///   crosses the OpenDisplay wire (PROTOCOL.md 5.1), so this is generated
    ///   locally from arrival order.
    func submit(_ pixelBuffer: CVPixelBuffer, captureTimeNs: Int64) {
        lock.lock()
        let source = self.source
        let capturer = self.capturer
        lock.unlock()
        guard let source, let capturer else {
            // Counted rather than dropped silently. A missing source or capturer
            // means `start()` never completed, and that used to be invisible:
            // frames decoded, nothing sent, no log line anywhere.
            lock.lock()
            droppedFrames += 1
            let dropped = droppedFrames
            lock.unlock()
            if dropped <= 3 || dropped % 50 == 0 {
                onStatus?("submit: dropped \(dropped) frames (no source/capturer)")
            }
            return
        }
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: ._0,
                                  timeStampNs: captureTimeNs)
        source.capturer(capturer, didCapture: frame)
        lock.lock()
        submittedFrames += 1
        let total = submittedFrames
        lock.unlock()
        if total == 1 || total % 150 == 0 {
            onStatus?("submit: \(total) frames handed to libwebrtc")
        }
    }

    func stop() {
        // Detach under the lock, close outside it.
        //
        // `RTCPeerConnection.close()` drives the signaling state machine, and
        // `RTCPeerConnectionDelegate` methods fire from the signaling thread —
        // including `didChange newState:`, which takes this lock. Closing while
        // holding it is the deadlock this file avoided everywhere else (see
        // `handleOffer`, which already closes outside the lock) and would
        // reintroduce the moment `isConnected` became properly synchronised.
        lock.lock()
        let doomed = connection
        connection = nil
        // Resume rather than drop: an HTTP caller is parked on this
        // continuation and would otherwise hang until its own timeout.
        let abandoned = answerPending?.completion
        answerPending = nil
        videoTrack = nil
        source = nil
        capturer = nil
        factory = nil
        _isConnected = false
        lock.unlock()

        abandoned?(.failure(WebRTCError.supersededByNewOffer))
        doomed?.close()
    }
}
