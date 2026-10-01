import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// What a decoder backend did with one access unit.
///
/// The two available backends differ in *when* the picture appears, and that
/// difference is the whole reason this is an enum rather than a callback: a
/// caller that assumed synchrony would either stall the relay behind a
/// software decoder or drop every frame from an asynchronous one.
enum H264DecodeOutcome {
    /// Decoded inline; the picture is ready now.
    case delivered(CVPixelBuffer)
    /// Accepted; the picture will arrive via `onFrame` later. VideoToolbox
    /// queues internally, so this is the normal hardware case.
    case accepted
    /// Nothing to show, and nothing wrong. An access unit carrying only
    /// parameter sets, or a non-reference frame, legitimately produces no
    /// picture — treating that as an error is what made a healthy stream look
    /// broken.
    case noPicture
    /// The access unit was rejected. Carries a reason for the status log.
    case rejected(String)
}

/// A decoder for the relayed H.264 stream.
///
/// Not thread-safe; `H264Transcoder` serialises access.
///
/// Why there is more than one: macOS gates VideoToolbox's hardware media path
/// behind a real Developer ID signature, and this process is unsigned. A
/// hardware decoder then returns `noErr` and simply never calls back, which
/// looks identical to a dead stream. `OpenH264` software decoding is not gated,
/// so the WebRTC path works without a paid Apple Developer account. See
/// `OpenH264Decoder` for the measurements.
protocol H264Decoding: AnyObject {
    /// Short name for the status log and the receiver's `stats` message, so a
    /// black screen is attributable to a backend rather than mysterious.
    var name: String { get }

    /// Called with each decoded picture. For a synchronous backend this fires
    /// inside `decode`; for VideoToolbox it fires on a decoder-internal queue.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }

    func decode(_ au: AnnexBStream.AccessUnit,
                format: CMVideoFormatDescription?) -> H264DecodeOutcome

    /// True while pictures may still be outstanding, so a watchdog can tell
    /// "slow" from "never going to happen".
    var hasOutstandingFrames: Bool { get }

    /// Drops all decoder state. The next access unit must be a keyframe.
    func reset()
}

// MARK: - VideoToolbox

/// Hardware decode via `VTDecompressionSession`. The default and the only
/// option on a properly signed build.
///
/// ## Why this needs two locks, and why neither is held across VideoToolbox
///
/// `H264Transcoder` guards its *pointer* to this object, which is not the same
/// thing as serialising calls into it. The transcoder deliberately calls
/// `decode` and `reset` with its own lock released — a `VTDecompressionSession`
/// call can block waiting for a callback that needs that lock, so holding it is
/// a deadlock. The consequence is that a `reset` on the teardown thread can run
/// concurrently with a `decode` on the ingest thread, with
/// `VTDecompressionSessionInvalidate` racing `VTDecompressionSessionDecodeFrame`
/// on the same session.
///
/// That is not hypothetical: `detach()` runs from the WebSocket close observer
/// while the hub's read loop may be mid-`ingest`, so it happens on every
/// receiver disconnect while a sender is streaming.
///
/// A single lock cannot fix that, because VideoToolbox makes it a trap from both
/// sides: whichever lock is held across `DecodeFrame` is the one `deliver` needs
/// from the callback queue, and whichever is held across `Invalidate` is the one
/// `deliver` needs while the invalidation drains. So the two concerns are split:
///
/// * `sessionLock` guards the `session` pointer. Held only long enough to read,
///   replace or clear it — never across a VideoToolbox call that waits on
///   callbacks.
/// * `stateLock` guards the in-flight counter, the frame index and the frame
///   handler. `deliver` takes only this one, and it is always free while
///   VideoToolbox is draining.
final class VideoToolboxH264Decoder: H264Decoding {
    var name: String { "VideoToolbox" }

    /// Guards `session` and `format` only. Never held across a VideoToolbox call
    /// that can block on a callback.
    private let sessionLock = NSLock()

    /// Guards `inFlight`, `frameIndex` and `onFrame`. Taken by `deliver` from
    /// VideoToolbox's callback queue, so it must never be held while calling into
    /// VideoToolbox.
    private let stateLock = NSLock()

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var inFlight = 0

    /// Swift prefers VideoToolbox's newer Swift-native overloads, which are
    /// macOS 14/15+ only. This package supports macOS 13, so the C entry points
    /// are selected explicitly by coercing them to their C function types.
    private typealias CreateFn = (
        CFAllocator?, CMVideoFormatDescription, CFDictionary?, CFDictionary?,
        UnsafePointer<VTDecompressionOutputCallbackRecord>?,
        UnsafeMutablePointer<VTDecompressionSession?>
    ) -> OSStatus

    private typealias DecodeFn = (
        VTDecompressionSession, CMSampleBuffer, VTDecodeFrameFlags,
        UnsafeMutableRawPointer?, UnsafeMutablePointer<VTDecodeInfoFlags>?
    ) -> OSStatus

    private static let createSession: CreateFn = VTDecompressionSessionCreate
    private static let decodeFrame: DecodeFn = VTDecompressionSessionDecodeFrame

    /// The output callback must be a C function pointer installed at session
    /// creation (the modern closure form is macOS 14+, and this package targets
    /// 13), so the instance is recovered through refcon.
    private static let outputCallback: VTDecompressionOutputCallback = {
        refCon, _, status, _, imageBuffer, _, _ in
        guard let refCon else { return }
        let box = Unmanaged<VideoToolboxH264Decoder>.fromOpaque(refCon)
            .takeUnretainedValue()
        box.deliver(status: status, imageBuffer: imageBuffer)
    }

    private var callbackRecord: VTDecompressionOutputCallbackRecord {
        VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
    }

    private var frameIndex: Int64 = 0

    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onFrame }
        set { stateLock.lock(); _onFrame = newValue; stateLock.unlock() }
    }
    private var _onFrame: ((CVPixelBuffer) -> Void)?

    var hasOutstandingFrames: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return inFlight > 0
    }

    func decode(_ au: AnnexBStream.AccessUnit,
                format newFormat: CMVideoFormatDescription?) -> H264DecodeOutcome {
        guard let newFormat else { return .rejected("no video format description") }

        // A format change retires the old session. It is cleared here and
        // invalidated after the lock is released, so a concurrent `reset` or
        // `decode` can never find a session that is mid-teardown.
        sessionLock.lock()
        var stale: VTDecompressionSession?
        if newFormat != format {
            stale = session
            session = nil
            format = newFormat
        }
        var current = session
        if current == nil {
            var record = callbackRecord
            var created: VTDecompressionSession?
            let status = Self.createSession(kCFAllocatorDefault, newFormat, nil, nil,
                                            &record, &created)
            current = (status == noErr) ? created : nil
            session = current
        }
        sessionLock.unlock()

        // Nothing left to do, and the old session still needs invalidating.
        if current == nil {
            if let stale { VTDecompressionSessionInvalidate(stale) }
            return .rejected("VTDecompressionSessionCreate failed")
        }
        guard let active = current else {
            if let stale { VTDecompressionSessionInvalidate(stale) }
            return .rejected("no decompression session")
        }

        guard let sample = makeSampleBuffer(avcc: au.data, format: newFormat) else {
            if let stale { VTDecompressionSessionInvalidate(stale) }
            return .rejected("could not build a CMSampleBuffer")
        }

        stateLock.lock()
        inFlight += 1
        frameIndex += 1
        stateLock.unlock()

        // Async decode so the relay's read loop is not serialised behind the
        // decoder. kVTDecodeFrame_EnableAsynchronousDecompression is not
        // surfaced to Swift in this SDK, so it is spelled out: 0x1.
        //
        // No lock is held here on purpose. This call can block internally waiting
        // for `deliver` on the callback queue, and `deliver` needs `stateLock`.
        // Holding `stateLock` across it would be the same deadlock one level
        // below the one it was fixed at.
        let status = Self.decodeFrame(active, sample,
                                      VTDecodeFrameFlags(rawValue: 0x1), nil, nil)

        if let stale { VTDecompressionSessionInvalidate(stale) }

        guard status == noErr else {
            stateLock.lock()
            inFlight = max(0, inFlight - 1)
            stateLock.unlock()
            return .rejected("VTDecompressionSessionDecodeFrame -> \(status)")
        }
        return .accepted
    }

    private func deliver(status: OSStatus, imageBuffer: CVImageBuffer?) {
        // Only `stateLock`, never `sessionLock`: a `reset` racing this may be
        // holding that one while it retires a session.
        stateLock.lock()
        inFlight = max(0, inFlight - 1)
        // Copied out and invoked after unlocking: `onFrame` is wired to the
        // transcoder, which takes its own lock, and calling out while holding
        // another is how the inversions in this file started.
        let handler = _onFrame
        let image = imageBuffer
        stateLock.unlock()
        guard status == noErr, let image else { return }
        handler?(image)
    }

    /// Builds a `CMSampleBuffer` for one access unit. Pure: no shared state, so
    /// it is safe to call with no lock held.
    private func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
            flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = CMBlockBufferAssureBlockMemory(block)
        guard status == kCMBlockBufferNoErr else { return nil }
        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // No PTS crosses the wire (PROTOCOL.md 5.1), so timing is generated
        // locally from arrival order.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr else { return nil }
        return sample
    }

    func reset() {
        // Retire under `sessionLock`, invalidate with nothing held.
        //
        // `VTDecompressionSessionInvalidate` blocks until pending output
        // callbacks have run, and each of those arrives on the callback queue and
        // needs `stateLock`. Clearing `session` first is what makes this safe: a
        // `decode` racing in from another thread finds nil and is rejected, so
        // nothing can enter VideoToolbox with a session being torn down under it.
        sessionLock.lock()
        let doomed = session
        session = nil
        format = nil
        sessionLock.unlock()

        stateLock.lock()
        inFlight = 0
        frameIndex = 0
        stateLock.unlock()

        if let doomed { VTDecompressionSessionInvalidate(doomed) }
    }
}

// MARK: - OpenH264

#if canImport(COpenH264)
/// Software decode via OpenH264. The fallback for an unsigned process, where
/// VideoToolbox accepts a frame and never produces a picture.
final class OpenH264H264Decoder: H264Decoding {
    let name: String

    /// Guards `decoder` and the frame handler.
    ///
    /// Needed for the same reason as the VideoToolbox backend's: the transcoder
    /// calls `decode` and `reset` with its own lock released, so a teardown on
    /// the close observer can race an ingest in progress. Here the race is worse
    /// than a stale read — `reset` calls `od_h264_destroy`, so a concurrent
    /// `decode` would be using a freed handle.
    private let lock = NSLock()

    private var decoder: OpenH264Decoder?
    private var _onFrame: ((CVPixelBuffer) -> Void)?

    /// OpenH264 has no format description to configure; it parses the SPS out of
    /// the bitstream itself, which is exactly why it works where VideoToolbox
    /// does not.
    init?() {
        guard let decoder = OpenH264Decoder() else { return nil }
        self.decoder = decoder
        self.name = "OpenH264 (\(decoder.version))"
    }

    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    /// Synchronous, so a picture is available the moment `decode` returns and
    /// there is nothing outstanding to wait on.
    var hasOutstandingFrames: Bool { false }

    func decode(_ au: AnnexBStream.AccessUnit,
                format: CMVideoFormatDescription?) -> H264DecodeOutcome {
        lock.lock()
        guard let decoder else {
            lock.unlock()
            return .rejected("decoder is gone")
        }
        // Prefer the parameter-set-prefixed form: a self-contained access unit
        // decodes even when the sender is mid-GOP and not repeating them.
        let bitstream = au.annexBWithParameterSets ?? au.annexB
        let buffer = decoder.decode(bitstream)
        let state = decoder.lastState
        let handler = _onFrame
        lock.unlock()

        guard let buffer else {
            // Distinguish "nothing yet" from "the bitstream has no parameter
            // sets", which is a wiring fault rather than a codec one and needs a
            // different fix.
            if state == 0x10 {
                return .rejected("bitstream has no SPS/PPS")
            }
            return .noPicture
        }
        handler?(buffer)
        return .delivered(buffer)
    }

    func reset() {
        // Reset the decoder IN PLACE.
        //
        // This used to detach the decoder and destroy it, which was wrong twice
        // over. It freed the OpenH264 handle underneath a `let`, so the next
        // decode was a use-after-free and the object's own `deinit` was a double
        // free; and because the detached decoder was never recreated, every
        // later `decode` returned `.rejected("decoder is gone")` — so a single
        // resolution change permanently killed the WebRTC path, reporting a
        // wiring fault rather than the stream event that caused it.
        //
        // `OpenH264Decoder.reset` now uninitialises and re-initialises the same
        // instance, so the handle stays valid and decoding resumes at the next
        // keyframe. Only `deinit` destroys.
        //
        // Under the lock, so a concurrent `decode` either runs before the reset
        // or sees a consistent decoder afterwards, never a half-torn one.
        lock.lock()
        decoder?.reset()
        lock.unlock()
    }
}
#endif
