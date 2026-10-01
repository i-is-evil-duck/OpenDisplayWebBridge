import Foundation
import XCTest

@testable import OpenDisplayBridge

/// The bridge must tell the receiver which video path and decoder it settled
/// on.
///
/// ## Why this is tested rather than assumed
///
/// A black screen is the failure mode this project has spent most of its time
/// on, and for most of that time it was indistinguishable from a healthy session
/// with nothing to show. The receiver's overlay counted frames on the WebCodecs
/// path only, so on the WebRTC path it read "0 fps 0.0 Mb/s" whether or not
/// video was flowing — and the WebRTC path is the only one the target iPad
/// takes.
///
/// A diagnostic that is only wired up by hand is a diagnostic that will be
/// missing exactly when it is needed, so the wiring is asserted here.
final class BridgeStatusTests: XCTestCase {

    /// Captures everything the pipeline pushes at a receiver.
    private final class RecordingTransport: ODTransport, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onClose: ((Error?) -> Void)?
        private let lock = NSLock()
        private var frames: [Data] = []
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return frames }
        func sendFrame(_ payload: Data) {
            lock.lock(); frames.append(payload); lock.unlock()
        }
        func close() {}
        /// Parsed `bridgeStatus` messages, in order.
        var statusMessages: [[String: Any]] {
            all.compactMap { ODControl.parse($0) }
                .filter { ($0["type"] as? String) == "bridgeStatus" }
        }
    }

    private func makePipeline() -> (RelayedSender, RecordingTransport) {
        let hub = OpenDisplayHub(port: 0)
        // Port 0 never binds, and nothing here needs a live sender: the point is
        // what the bridge reports, not what it forwards.
        let transport = RecordingTransport()
        let sender = RelayedSender(hub: hub, logger: { _ in })
        sender.attach(transport)
        return (sender, transport)
    }

    /// The `hello` that makes a WebCodecs-capable receiver take the passthrough
    /// path, so mode selection is exercised rather than assumed.
    private func hello(webcodecs: Bool, rtc: Bool) -> Data {
        ODControl.encode(["type": "hello", "id": "test", "pv": 3,
                          "webcodecs": webcodecs, "rtc": rtc])
    }

    func testReportsPassthroughModeForACapableReceiver() throws {
        let (sender, transport) = makePipeline()
        defer { sender.detach() }

        transport.onFrame?(hello(webcodecs: true, rtc: true))

        let statuses = transport.statusMessages
        XCTAssertFalse(statuses.isEmpty,
                       "the bridge must report its mode even on the passthrough path")
        let last = try XCTUnwrap(statuses.last)
        XCTAssertEqual(last["mode"] as? String, "passthrough")
        // Passthrough means the browser decodes, so the bridge has no decoder of
        // its own to name. Reporting "none" rather than a stale name is the point.
        XCTAssertEqual(last["decoder"] as? String, "none")
    }

    func testReportsWebRTCModeAndNamesTheDecoder() throws {
        let (sender, transport) = makePipeline()
        defer { sender.detach() }

        // No WebCodecs, but WebRTC available: the old-iPad case.
        transport.onFrame?(hello(webcodecs: false, rtc: true))

        let statuses = transport.statusMessages
        XCTAssertFalse(statuses.isEmpty, "no status was pushed")
        let last = try XCTUnwrap(statuses.last)
        XCTAssertEqual(last["mode"] as? String, "webRTC")

        // Every message must carry a decoder field, even if it is "none": a
        // missing key and an explicit "none" are different answers to "which
        // decoder is this", and only one of them is honest about not knowing.
        for status in statuses {
            XCTAssertNotNil(status["decoder"],
                            "every bridgeStatus must carry a decoder field: \(status)")
            XCTAssertNotNil(status["senderConnected"],
                            "every bridgeStatus must carry senderConnected: \(status)")
        }
    }

    /// The messages must survive the demux as control, not be mistaken for
    /// video. They arrive as the same `Data` the bridge pushes toward the
    /// receiver, and the receiver's demux is what decides.
    func testStatusMessagesAreNotMistakenForVideo() {
        let (sender, transport) = makePipeline()
        defer { sender.detach() }

        transport.onFrame?(hello(webcodecs: false, rtc: true))
        for frame in transport.all {
            // The bridge's own ODDemux heuristic is what the receiver mirrors, so
            // asserting it here is the same check the browser will make.
            XCTAssertTrue(ODDemux.isControl(frame),
                          "bridgeStatus must classify as control, not video")
        }
    }

    /// Repeated `hello`s must not spam the receiver, but a mode change must be
    /// visible. The sender re-advertises on reconnect, and a bridge that
    /// re-announced identically every time would drown the log.
    func testRepeatedIdenticalHelloDoesNotResendStatus() {
        let (sender, transport) = makePipeline()
        defer { sender.detach() }

        transport.onFrame?(hello(webcodecs: true, rtc: true))
        let afterFirst = transport.statusMessages.count
        transport.onFrame?(hello(webcodecs: true, rtc: true))
        let afterSecond = transport.statusMessages.count

        XCTAssertEqual(afterFirst, afterSecond,
                       "an unchanged mode must not be re-announced")
        XCTAssertGreaterThan(afterFirst, 0, "the first announcement must happen")
    }

    /// Tearing the session down must not leave the receiver believing a decoder
    /// is still live.
    func testStopReportsNoDecoder() {
        let (sender, transport) = makePipeline()
        defer { sender.detach() }

        transport.onFrame?(hello(webcodecs: false, rtc: true))
        sender.detach()

        let last = transport.statusMessages.last
        // detach() clears the session, so either the last message names no
        // decoder or no further message is sent. What must not happen is a
        // final message still advertising a live decoder.
        if let last = last {
            XCTAssertEqual(last["decoder"] as? String, "none",
                           "teardown must not leave a decoder advertised")
        }
    }
}
