import Foundation
@testable import OpenDisplayBridge

/// A `BridgeConnection` stand-in that never touches a socket, so session
/// ownership and the binding's dispatch rules can be tested deterministically.
final class FakeConnection: BridgeConnection {
    private(set) var isClosed = false
    private(set) var isRunning = false
    private var closeObservers: [(Error?) -> Void] = []
    private var messageHandlers: [(WebSocketMessage) -> Void] = []

    func run() { isRunning = true }
    func close() { fireClose() }
    func deliver(_ handler: @escaping (WebSocketMessage) -> Void) { messageHandlers.append(handler) }
    func observeClose(_ observer: @escaping (Error?) -> Void) { closeObservers.append(observer) }
    func sendBinary(_ data: Data) async throws { sentToPeer.append(data) }

    /// Everything the transport handed to the wire, in order.
    private(set) var sentToPeer: [Data] = []

    /// Simulates the peer going away, as opposed to a local close().
    func simulateRemoteClose() { fireClose() }

    /// Pushes a message to whoever is listening.
    func emit(_ message: WebSocketMessage) {
        messageHandlers.forEach { $0(message) }
    }

    private func fireClose() {
        guard !isClosed else { return }
        isClosed = true
        isRunning = false
        for o in closeObservers { o(nil) }
    }
}

/// A `SenderPipeline` that records its lifecycle so tests can assert the
/// incumbent was retired and the newcomer attached.
final class RecordingPipeline: SenderPipeline, @unchecked Sendable {
    private(set) var attachCount = 0
    private(set) var detachCount = 0
    private(set) var sentFrames: [Data] = []
    private(set) var receivedFrames: [Data] = []
    private(set) var transport: ODTransport?

    func attach(_ transport: ODTransport) {
        attachCount += 1
        self.transport = transport
        // A real pipeline subscribes to inbound frames here (DemoSender does
        // exactly this); without it the transport has nowhere to deliver.
        transport.onFrame = { [weak self] data in self?.receivedFrames.append(data) }
    }

    func detach() {
        detachCount += 1
        transport = nil
    }

    /// Simulates the pipeline emitting an outbound frame.
    func emit(_ data: Data) { sentFrames.append(data); transport?.sendFrame(data) }
}
