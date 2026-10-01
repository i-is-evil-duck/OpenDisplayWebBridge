import Foundation
import CoreFoundation

/// Stand-in for the OpenDisplay sender session so the scaffold is end-to-end
/// testable today: speaks pv 3 (hello/welcome/streamConfig, ping/pong, kf,
/// touch/scroll logging) and streams an encoded test pattern via VTBox.
///
/// REPLACE THIS with the real sender session in `AppState.start()` (see README).
final class DemoSender: SenderPipeline, @unchecked Sendable {
    private let logger: (String) -> Void
    private weak var transport: ODTransport?
    private var encoder: VTBox?
    private var pumpTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var displaySize = CGSize(width: 1920, height: 1080)
    private var streamSize = CGSize(width: 1280, height: 720)
    private var frameIndex = 0

    init(logger: @escaping (String) -> Void) { self.logger = logger }

    func attach(_ transport: ODTransport) {
        self.transport = transport
        transport.onFrame = { [weak self] in self?.handleFrame($0) }
        transport.onClose = { [weak self] _ in self?.stopStreaming() }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.send(["type": "ping", "capFps": 30])
            }
        }
    }

    func detach() {
        pingTask?.cancel(); pingTask = nil
        stopStreaming()
        transport = nil
    }

    func handleFrame(_ payload: Data) {
        guard let msg = ODControl.parse(payload), let type = msg["type"] as? String else { return }
        switch type {
        case "hello":
            if let w = msg["pixelsWide"] as? NSNumber, let h = msg["pixelsHigh"] as? NSNumber {
                displaySize = CGSize(width: w.doubleValue, height: h.doubleValue)
            }
            streamSize = cappedStreamSize(for: displaySize)
            send(["type": "welcome", "pv": 3, "min": 1])
            send(["type": "streamConfig", "codec": "h264",
                  "width": Int(streamSize.width), "height": Int(streamSize.height),
                  "framesPerSecond": 30])
            logger("hello: panel \(Int(displaySize.width))x\(Int(displaySize.height)), stream \(Int(streamSize.width))x\(Int(streamSize.height))")
            startStreaming()          // idempotent: restart handles rotation re-hello
        case "ping":
            let t = msg["t"] ?? ODControl.nowMs()
            send(["type": "pong", "t": t, "mt": ODControl.nowMs()])
        case "kf":
            encoder?.requestKeyframe()
        case "touch":
            logger("touch \(msg["phase"] as? String ?? "?") x=\(msg["x"] ?? 0) y=\(msg["y"] ?? 0)")
        case "scroll":
            logger("scroll dx=\(msg["dx"] ?? 0) dy=\(msg["dy"] ?? 0)")
        case "sleeping", "closing":
            logger("receiver says \(type)")
        default:
            break  // normative: ignore unknown types (PROTOCOL.md §6)
        }
    }

    private func cappedStreamSize(for panel: CGSize) -> CGSize {
        let maxW: CGFloat = 1280, maxH: CGFloat = 720
        let s = min(maxW / max(panel.width, 1), maxH / max(panel.height, 1), 1)
        func align16(_ v: CGFloat) -> CGFloat { (v / 16).rounded(.down) * 16 }
        return CGSize(width: max(160, align16(panel.width * s)),
                      height: max(90, align16(panel.height * s)))
    }

    private func startStreaming() {
        stopStreaming()
        let size = streamSize
        guard let enc = VTBox(width: Int(size.width), height: Int(size.height), fps: 30, bitrate: 4_000_000) else {
            logger("encoder init failed")
            return
        }
        enc.onError = { [weak self] message in self?.logger(message) }
        encoder = enc
        frameIndex = 0

        // Encoder output -> wire.
        pumpTask = Task { [weak self] in
            for await frame in enc.stream {
                guard !Task.isCancelled else { return }
                self?.transport?.sendFrame(frame)
            }
        }

        // Render/encode loop at 30 fps.
        renderTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let idx = self.frameIndex
                self.frameIndex += 1
                enc.encodeTestPattern(frameIndex: idx, captureMs: ODControl.nowMs())
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }

    private func stopStreaming() {
        pumpTask?.cancel(); pumpTask = nil
        renderTask?.cancel(); renderTask = nil
        encoder = nil
    }

    private func send(_ obj: [String: Any]) {
        transport?.sendFrame(ODControl.encode(obj))
    }
}
