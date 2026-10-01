import Foundation
import Network

/// Async/await face over NWConnection used by both the HTTP server and the WebSocket layer.
final class NWConnectionShim: @unchecked Sendable {
    private let conn: NWConnection
    private let sendLock = NSLock()
    private var pending: [(data: Data, cont: CheckedContinuation<Void, Error>)] = []
    private var sending = false

    init(_ conn: NWConnection) { self.conn = conn }

    var remoteEndpointString: String {
        switch conn.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        default: return "\(conn.endpoint)"
        }
    }

    func start() { conn.start(queue: .global(qos: .userInitiated)) }

    /// Returns Data() on clean EOF.
    func receiveAtLeast(_ minimum: Int, max: Int = 64 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: minimum, maximumLength: max) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return }
                cont.resume(returning: Data())  // treat idle-close as EOF
            }
        }
    }

    /// Ordered async send: queues behind any in-flight write.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { cont in
            sendLock.lock()
            pending.append((data, cont))
            if !sending {
                sending = true
                let next = pending.removeFirst()
                sendLock.unlock()
                conn.send(content: next.data, completion: .contentProcessed { [weak self] error in
                    self?.finishSend(next.cont, error: error)
                })
            } else {
                sendLock.unlock()
            }
        }
    }

    private func finishSend(_ cont: CheckedContinuation<Void, Error>, error: Error?) {
        if let error { cont.resume(throwing: error) } else { cont.resume() }
        sendLock.lock()
        if pending.isEmpty {
            sending = false
            sendLock.unlock()
        } else {
            let next = pending.removeFirst()
            sendLock.unlock()
            conn.send(content: next.data, completion: .contentProcessed { [weak self] error in
                self?.finishSend(next.cont, error: error)
            })
        }
    }

    func close() { conn.cancel() }
}
