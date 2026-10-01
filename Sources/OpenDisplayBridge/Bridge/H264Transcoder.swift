import CoreMedia
import CoreVideo
import Foundation

/// Demuxes relayed H.264 and drives whichever decoder backend can actually
/// produce pictures (WEBRTC_PLAN.md W2).
///
/// Why this exists: the bridge is a relay, so it holds no pixels. A receiver
/// that can decode H.264 itself gets the sender's bytes forwarded untouched and
/// never touches this class. Only receivers that *cannot* — old iPads with
/// neither WebCodecs (iOS 16.4+) nor MSE (iOS 13+) — force a decode/re-encode,
/// where the pixels are handed to libvpx inside WebRTC.
///
/// ## Backend selection
///
/// VideoToolbox is tried first: it is hardware-accelerated and free. But macOS
/// gates the hardware media path behind a real Developer ID signature, and this
/// process is unsigned, in which case it accepts a frame, returns `noErr`, and
/// never calls back. There is no error to detect and no way to ask in advance,
/// so the only honest signal is time: if nothing has come out after
/// `fallbackDelay`, the backend is switched to OpenH264 for the rest of the
/// session and the switch is reported.
///
/// That delay costs 2s of black screen on an unsigned build, once per session.
/// It is the price of still preferring hardware where hardware exists, and it
/// is far cheaper than a paid Apple Developer account.
final class H264Transcoder: @unchecked Sendable {
    /// Reports decoder problems and mode changes. Silent failure here is
    /// indistinguishable from "the sender stopped sending", so everything is
    /// surfaced.
    var onStatus: ((String) -> Void)?

    /// Called with each decoded frame and a capture timestamp in nanoseconds.
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?

    /// Name of the backend actually in use, for the stats overlay and the
    /// receiver's `stats` message.
    private(set) var backendName: String = "none"

    private let lock = NSLock()
    private var stream = AnnexBStream()
    private var formatDescription: CMVideoFormatDescription?
    private var backend: H264Decoding?

    /// Frames submitted but not yet delivered. VideoToolbox queues internally,
    /// so this bounds how far the relay can run ahead of the encoder.
    private var inFlight = 0
    private var announcedFirstFrame = false
    private var decodeWatchdogArmed = false
    private var fallbackDecided = false
    /// Set after the decoder is rebuilt, cleared by the next keyframe. Inter-
    /// predicted frames arriving before then cannot be decoded.
    private var awaitingKeyframe = false
    private var ingestedFrames = 0
    private var decodedFrames = 0
    private let maxInFlight = 8

    /// How long to wait for a hardware frame before concluding the backend is
    /// unreachable. Long enough that a busy machine does not trip it, short
    /// enough that it is not a noticeable wait.
    private static let fallbackDelay: TimeInterval = 2

    init() {
        // VideoToolbox first, always. On a signed build this is the only backend
        // that ever runs, and the fallback below is never reached.
        setBackend(VideoToolboxH264Decoder(), announce: false)
    }

    // MARK: - Ingest

    /// Feeds one wire frame (PROTOCOL.md s.5). Returns false if the frame
    /// produced nothing decodable.
    @discardableResult
    func ingest(_ frame: Data) -> Bool {
        lock.lock()
        ingestedFrames += 1
        let ingested = ingestedFrames
        lock.unlock()
        // Verbose early, then periodic: a steady trickle of "ingesting" with no
        // frame delivered means the backend is not producing pictures, while
        // silence means no video is arriving at all. Those need different fixes,
        // so the distinction has to be visible.
        if ingested <= 3 || ingested % 30 == 0 {
            onStatus?("ingest #\(ingested) (\(frame.count)B)")
        }

        lock.lock()
        var needsReset = false
        var geometryChanged: String?
        var toDump: Data?
        let hadParameterSets = stream.hasParameterSets
        guard let au = stream.consume(frame) else {
            lock.unlock()
            return false
        }
        if Self.dumpPath != nil { toDump = au.annexBWithParameterSets ?? au.annexB }

        // New or changed parameter sets mean a new stream geometry (rotation or
        // a quality change). PROTOCOL.md 5.2: the sender just starts sending new
        // SPS/PPS, and the receiver rebuilds and drops what it has.
        //
        // `lastSPS`/`lastPPS` are primed here, in the same place the format
        // description is set, rather than lazily inside
        // `needsNewFormatDescription`. Priming them lazily meant the *second*
        // access unit always looked like a change — the first is short-circuited
        // by `!hadParameterSets`, so the comparison never ran, and `lastSPS` was
        // still nil when the second one arrived. That tore down a working decoder
        // mid-stream and left every following P-frame undecodable: one frame,
        // then silence, which is indistinguishable from a closed hardware path.
        if stream.hasParameterSets && (!hadParameterSets || needsNewFormatDescription()) {
            if let desc = stream.makeFormatDescription() {
                formatDescription = desc
                lastSPS = stream.sps
                lastPPS = stream.pps
                if let dims = AnnexBStream.dimensions(desc) {
                    geometryChanged = "\(dims.width)x\(dims.height)"
                }
                // A rebuilt decoder holds no reference pictures, so the next
                // inter-predicted frame cannot be decoded. Waiting for a keyframe
                // is the only correct behaviour, not a workaround: feeding the
                // P-frame anyway yields no output and no error. PROTOCOL.md 5.2
                // puts parameter sets on every IDR, so one is already coming.
                awaitingKeyframe = true
                // `backend.reset()` is deliberately *not* called from in here; it
                // runs after the lock is released. See the note by the decode
                // call below — the same reasoning applies.
                needsReset = true
            } else {
                lock.unlock()
                report("parameter sets rejected")
                return false
            }
        }

        guard let backend else {
            lock.unlock()
            return false
        }

        if awaitingKeyframe {
            if au.isKeyframe {
                awaitingKeyframe = false
            } else {
                lock.unlock()
                return false
            }
        }

        guard inFlight < maxInFlight else {
            // Drop rather than queue: a stale frame is worth less than a fresh
            // one, and the next keyframe recovers full fidelity.
            lock.unlock()
            return true
        }

        // The decode call must happen *outside* the lock.
        //
        // Both backends re-enter this object while `decode` is on the stack:
        // OpenH264 delivers its picture inline, and VideoToolbox delivers on its
        // own `vtdecoder-callback-queue` — and may block inside
        // `VTDecompressionSessionDecodeFrame` waiting for that callback, which
        // needs this very lock. Holding the lock across the call is therefore a
        // hard deadlock, and an intermittent one, because it only fires when the
        // callback wins the race. It hung the process during development with no
        // error and no crash, which is the worst possible failure shape.
        //
        // Count the frame as in flight *before* releasing, so a callback that
        // lands first still decrements a counter that is already counting it.
        inFlight += 1
        let format = formatDescription
        lock.unlock()

        if let geometryChanged {
            onStatus?("stream is \(geometryChanged)")
        }
        // Also outside the lock, and for a second reason beyond the deadlock one:
        // this writes a whole access unit to disk (up to hundreds of KB at
        // 1080p) and emits `onStatus` — which in `RelayedSender` takes *its*
        // lock. Holding this lock across either stalls the VideoToolbox callback
        // queue, and a stalled callback queue is decoder back-pressure.
        if let toDump {
            dump(toDump)
        }
        // `backend.reset()` is also outside the lock: invalidating the session
        // blocks until in-flight callbacks have drained, and those callbacks
        // need this lock to deliver.
        if needsReset {
            backend.reset()
        }

        let outcome = backend.decode(au, format: format)

        switch outcome {
        case .accepted:
            // The picture will arrive via the callback, which decrements inFlight.
            armFirstFrameWatchdog()
            return true
        case .delivered:
            // A synchronous backend already called `onFrame` inline, which
            // decremented the count. Touching it again would let a single frame
            // release two slots and let the relay run ahead of the encoder.
            return true
        case .noPicture:
            // Nothing will arrive, so give the slot back.
            lock.lock()
            inFlight = max(0, inFlight - 1)
            lock.unlock()
            return true
        case .rejected(let reason):
            lock.lock()
            inFlight = max(0, inFlight - 1)
            lock.unlock()
            report(reason)
            // A rejected first access unit is just as much a sign that the
            // hardware path is closed as a silent one, and the watchdog is keyed
            // on "no frame yet" so it covers both.
            armFirstFrameWatchdog()
            return false
        }
    }

    private var lastSPS: Data?
    private var lastPPS: Data?

    /// Pure comparison, no side effects. The stored values are updated by the
    /// caller in the same locked region where the format description is built,
    /// so a change can never be observed without the rebuild that answers it.
    private func needsNewFormatDescription() -> Bool {
        stream.sps != lastSPS || stream.pps != lastPPS
    }

    // MARK: - Frame delivery

    /// Installs a backend. Takes the lock because it is called both from `init`
    /// and from the watchdog's background queue, and `ingest` reads both fields
    /// under the lock.
    private func setBackend(_ new: H264Decoding, announce: Bool) {
        new.onFrame = { [weak self] buffer in self?.deliver(buffer) }
        lock.lock()
        backend = new
        backendName = new.name
        lock.unlock()
        if announce {
            onStatus?("decoder backend: \(new.name)")
        }
    }

    private func deliver(_ buffer: CVPixelBuffer) {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        decodedFrames += 1
        let isFirst = !announcedFirstFrame
        announcedFirstFrame = true
        let count = decodedFrames
        lock.unlock()
        if isFirst { onStatus?("decoded first frame") }
        if count % 150 == 0 { onStatus?("decoded \(count) frames") }
        onFrame?(buffer, Int64(CFAbsoluteTimeGetCurrent() * 1_000_000_000))
    }

    // MARK: - Backend fallback

    /// VideoToolbox can accept a frame and then never call back, with no error
    /// to detect. This turns that silence into a decision.
    ///
    /// Keyed on "no frame has been delivered" rather than on "a frame is
    /// outstanding", because the closed hardware path shows up two different
    /// ways — a silent callback *and* a flat rejection of the first access unit
    /// — and both end in the same place: zero pictures. Waiting on an
    /// outstanding-frame count would catch only the first and leave the second
    /// showing a black screen forever.
    private func armFirstFrameWatchdog() {
        lock.lock()
        let alreadyArmed = decodeWatchdogArmed
        decodeWatchdogArmed = true
        lock.unlock()
        guard !alreadyArmed else { return }

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.fallbackDelay) {
            [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.decodeWatchdogArmed = false
            let producedNothing = self.decodedFrames == 0
            let alreadyDecided = self.fallbackDecided
            self.lock.unlock()

            guard producedNothing, !alreadyDecided else { return }
            self.switchToSoftwareBackend()
        }
    }

    /// Replaces the backend after hardware decode went silent.
    ///
    /// Only one switch per session: a decoder that produced nothing once is not
    /// going to start, and re-arming the watchdog on every frame would repeat
    /// the wait for the rest of the stream.
    private func switchToSoftwareBackend() {
        #if canImport(COpenH264)
        lock.lock()
        guard !fallbackDecided else { lock.unlock(); return }
        fallbackDecided = true
        inFlight = 0
        announcedFirstFrame = false
        // A fresh backend holds no reference pictures either, so it has to wait
        // for a keyframe just as a rebuilt one does.
        awaitingKeyframe = true
        let previous = backendName
        let old = backend
        backend = nil
        lock.unlock()

        // Outside the lock: invalidating the abandoned session blocks on its
        // callbacks, and those callbacks take this lock.
        old?.reset()

        onStatus?("no frame from \(previous) in \(Int(Self.fallbackDelay))s — "
                  + "falling back to software decode")

        guard let software = OpenH264H264Decoder() else {
            report("OpenH264 unavailable; install it with `brew install openh264`")
            return
        }
        setBackend(software, announce: true)
        #else
        lock.lock()
        let alreadyDecided = fallbackDecided
        fallbackDecided = true
        let previous = backendName
        lock.unlock()
        guard !alreadyDecided else { return }
        report("no frame from \(previous) in \(Int(Self.fallbackDelay))s and OpenH264 "
               + "is not linked; build with `brew install openh264` for the WebRTC path")
        #endif
    }

    // MARK: - Stream dump
    //
    // OD_H264_DUMP=<path> appends every access unit, Annex B, to one file. The
    // result is a replayable elementary stream, which is the only practical way
    // to reproduce a decode bug: the bytes on the wire can be replayed offline
    // instead of needing the sender, the sender's screen, and a browser all
    // lined up at once.
    private static let dumpPath: String? =
        ProcessInfo.processInfo.environment["OD_H264_DUMP"]
    private var dumpHandle: FileHandle?

    private func dump(_ bytes: Data) {
        guard let path = Self.dumpPath else { return }
        if dumpHandle == nil {
            // Truncate on first use so a stale file from a previous run cannot
            // masquerade as this session's stream. `dumpHandle` is only ever
            // touched from the ingest thread and from `stop()`, which
            // `H264Transcoder` serialises, so no extra guard is needed here.
            FileManager.default.createFile(atPath: path, contents: nil)
            dumpHandle = FileHandle(forWritingAtPath: path)
            onStatus?("dumping H.264 to \(path)")
        }
        dumpHandle?.write(bytes)
    }

    // MARK: - Reporting

    /// Report each distinct failure once. At 30 fps an unthrottled log would
    /// bury everything else — but a single shared flag would hide every *other*
    /// failure behind the first one, so dedupe per message.
    private var reportedMessages: Set<String> = []

    private func report(_ message: String) {
        lock.lock()
        let firstTime = !reportedMessages.contains(message)
        reportedMessages.insert(message)
        lock.unlock()
        guard firstTime else { return }
        onStatus?("h264 decode: \(message)")
    }

    func stop() {
        // Detach the backend under the lock, then tear it down outside it.
        // `reset()` invalidates the VideoToolbox session, which blocks until
        // pending callbacks have run, and every one of those callbacks needs this
        // lock to deliver its frame. Doing it in the other order deadlocks the
        // process on teardown — which is a path the app takes on every
        // disconnect and reconnect.
        lock.lock()
        let old = backend
        backend = nil
        backendName = "none"
        formatDescription = nil
        stream = AnnexBStream()
        inFlight = 0
        announcedFirstFrame = false
        decodedFrames = 0
        fallbackDecided = false
        awaitingKeyframe = false
        lastSPS = nil
        lastPPS = nil
        try? dumpHandle?.close()
        dumpHandle = nil
        lock.unlock()

        old?.reset()
    }
}
