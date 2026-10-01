import Foundation

/// The seam. One "frame" = one OpenDisplay frame payload WITHOUT the 4-byte
/// length prefix (the WebSocket binding replaces stream framing with message
/// boundaries — see implementationplan.md §5.1).
///
/// INTEGRATION: OpenDisplay's existing sender already speaks length-prefixed
/// frames over NWConnection. Conform that session to ODTransport by stripping
/// the length prefix on read and prepending it on write at this boundary, then
/// point `Bridge.makePipeline` at it.
protocol ODTransport: AnyObject {
    func sendFrame(_ payload: Data)
    var onFrame: ((Data) -> Void)? { get set }     // complete OD frames from the peer
    var onClose: ((Error?) -> Void)? { get set }
    func close()
}

final class WebSocketTransport: ODTransport, @unchecked Sendable {
    private let ws: BridgeConnection
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(_ ws: BridgeConnection) {
        self.ws = ws
        ws.deliver { [weak self] message in
            guard case .binary(let data) = message else { return }  // binding rule: binary only
            self?.onFrame?(data)
        }
        ws.observeClose { [weak self] error in self?.onClose?(error) }
    }

    func sendFrame(_ payload: Data) {
        Task { try? await ws.sendBinary(payload) }
    }

    func close() { ws.close() }
}
