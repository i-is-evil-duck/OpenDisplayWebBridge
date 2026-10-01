import Foundation

/// One upgraded WebSocket connection: read loop with fragmentation reassembly,
/// ping/pong, close handshake. Message boundaries are preserved — the WebSocket
/// binding carries exactly one OpenDisplay frame per binary message.
final class WebSocketConnection: BridgeConnection, @unchecked Sendable {
    private let conn: NWConnectionShim
    private let lock = NSLock()
    private var closed = false
    private var closeObservers: [(Error?) -> Void] = []
    private var messageHandlers: [(WebSocketMessage) -> Void] = []

    init(conn: NWConnectionShim) { self.conn = conn }

    var remoteEndpointString: String { conn.remoteEndpointString }

    /// Registers a close observer. Unlike a settable callback this does not
    /// clobber existing observers — the connection has three independent
    /// interested parties (the transport, the bridge's session bookkeeping,
    /// and the server's client accounting) and a single `var onClose` slot
    /// silently dropped two of them.
    func observeClose(_ observer: @escaping (Error?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Already closed: the observer would never fire, so don't pretend.
        if !closed { closeObservers.append(observer) }
    }

    /// Registers an inbound-message handler. Additive rather than a settable
    /// property, for the same reason as `observeClose`.
    func deliver(_ handler: @escaping (WebSocketMessage) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        messageHandlers.append(handler)
    }

    func run() {
        Task { [weak self] in
            guard let self else { return }
            var buffer = Data()
            var messageParts = Data()
            var messageOpcode: UInt8 = 0
            do {
                while true {
                    let chunk = try await self.conn.receiveAtLeast(1)
                    if chunk.isEmpty { break }              // EOF
                    buffer.append(chunk)
                    while let frame = try WebSocketCodec.consume(from: &buffer) {
                        switch frame.opcode {
                        case 0x0:   // continuation
                            if messageOpcode == 0 { throw WebSocketError.protocolError }
                            // maxMessageBytes bounds a single FRAME, not a
                            // reassembled message. Without this an endless run
                            // of continuation frames grows messageParts without
                            // limit — a trivial memory-exhaustion vector on a
                            // LAN-reachable port. Cap the whole message.
                            guard messageParts.count + frame.payload.count
                                    <= WebSocketCodec.maxMessageBytes else {
                                throw WebSocketError.frameTooLarge
                            }
                            messageParts.append(frame.payload)
                            if frame.fin {
                                self.emit(opcode: messageOpcode, payload: messageParts)
                                messageParts = Data(); messageOpcode = 0
                            }
                        case 0x1, 0x2:   // text / binary
                            if messageOpcode != 0 { throw WebSocketError.protocolError }
                            if frame.fin { self.emit(opcode: frame.opcode, payload: frame.payload) }
                            else { messageOpcode = frame.opcode; messageParts = frame.payload }
                        case 0x8:   // close: echo and terminate
                            try? await self.sendRaw(fin: true, opcode: 0x8, payload: frame.payload)
                            self.finish(nil)
                            return
                        case 0x9:   // ping -> pong
                            try await self.sendRaw(fin: true, opcode: 0xA, payload: frame.payload)
                        case 0xA:   // pong: ignore
                            break
                        default:
                            throw WebSocketError.protocolError
                        }
                    }
                }
                self.finish(nil)
            } catch {
                self.finish(error)
            }
        }
    }

    private func emit(opcode: UInt8, payload: Data) {
        lock.lock()
        let handlers = messageHandlers
        lock.unlock()
        switch opcode {
        case 0x2: handlers.forEach { $0(.binary(payload)) }
        case 0x1: handlers.forEach { $0(.text(String(decoding: payload, as: UTF8.self))) }
        default: break
        }
    }

    func sendBinary(_ data: Data) async throws {
        try await sendRaw(fin: true, opcode: 0x2, payload: data)
    }

    private func sendRaw(fin: Bool, opcode: UInt8, payload: Data) async throws {
        try await conn.send(WebSocketCodec.build(fin: fin, opcode: opcode, payload: payload))
    }

    /// Closes deliberately, without a stated reason.
    func close() { finish(nil) }

    func close(reason: String) { finish(BridgeCloseReason(description: reason)) }

    private func finish(_ error: Error?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let observers = closeObservers
        closeObservers = []
        lock.unlock()
        conn.close()
        for observer in observers { observer(error) }
    }
}
