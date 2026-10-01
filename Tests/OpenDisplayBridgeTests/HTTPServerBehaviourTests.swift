import Foundation
import Network
import XCTest
@testable import OpenDisplayBridge

/// Exercises the HTTP layer over a real loopback socket.
///
/// `HTTPParser.readOne` takes a concrete `NWConnectionShim`, so its buffering
/// and capping decisions cannot be reached with a stub. These drive the real
/// `HTTPServer` and read what a client actually receives, which is the only way
/// to distinguish "the server refused this" from "the server said nothing".
final class HTTPServerBehaviourTests: XCTestCase {

    private var server: HTTPServer?
    private var port: UInt16 = 0

    override func setUp() {
        super.setUp()
        // A port the test does not expect to be in use, so a collision shows up
        // as a connection error rather than as this suite silently talking to
        // some other process.
        let candidate = UInt16.random(in: 20000...60000)
        let s = try? HTTPServer(port: candidate, pairing: PairingStore(),
                                onWSConnection: { _ in }, onConnectionClosed: {})
        // `HTTPServer.start` binds; if the port is taken the listener fails and
        // the test's connect below fails, which is an acceptable outcome to
        // diagnose since the port is reported.
        server = s
        port = candidate
        try? s?.start()
    }

    override func tearDown() {
        server = nil
        super.tearDown()
    }

    // MARK: - Request body cap

    /// An oversized declared body must be refused, not buffered.
    ///
    /// `Content-Length` was obeyed with no ceiling, so a client declaring a
    /// gigabyte made the server append to its buffer until the socket died —
    /// memory exhaustion, unauthenticated, on a LAN-reachable port. The declared
    /// length is the only thing an attacker controls here, so it is the only
    /// thing that has to be checked.
    ///
    /// The assertion is on the STATUS LINE, because that is the observable
    /// difference between "refused" and "accepted then dropped".
    func testOversizedRequestBodyIsRefused() async throws {
        let conn = try await connect()
        defer { conn.cancel() }

        try await send(conn, "POST /pair HTTP/1.1\r\nHost: x\r\n"
                            + "Content-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n")

        let response = await readResponse(conn)
        XCTAssertTrue(response.contains("413") || response.contains("431"),
                      "an oversized body must be refused with a status the client can "
                      + "read; got: \(response.prefix(120))")
    }

    /// The boundary itself must be allowed, or the cap is off by one and
    /// `/pair` stops working. Its body is far below the cap, so this only
    /// exercises the header path.
    func testBodyAtTheLimitIsAccepted() async throws {
        let conn = try await connect()
        defer { conn.cancel() }

        // Exactly at the cap, fully supplied. The parser accepts it and the
        // router answers on its merits (a malformed JSON body, so 403 — but a
        // response, not a 413).
        let body = String(repeating: "x", count: HTTPParser.maxBodyBytes)
        try await send(conn, "POST /pair HTTP/1.1\r\nHost: x\r\n"
                            + "Content-Length: \(HTTPParser.maxBodyBytes)\r\n\r\n\(body)")

        let response = await readResponse(conn)
        XCTAssertFalse(response.contains("413"),
                       "a body exactly at the cap must be accepted; got: "
                       + String(response.prefix(120)))
    }

    /// The ordinary request must be unaffected by the cap — the check is only
    /// worth having if the common path still works.
    func testOrdinaryRequestStillWorks() async throws {
        let conn = try await connect()
        defer { conn.cancel() }

        try await send(conn, "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
        let response = await readResponse(conn)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 204"),
                      "a normal request must still be served; got: "
                      + String(response.prefix(120)))
    }

    // MARK: - Keep-alive

    /// Two requests on one connection must both be answered.
    ///
    /// `serveHTTP` loops on `readOne`, which allocates a fresh buffer per call.
    /// That works for a browser, which waits for each response, but it means the
    /// parser has no memory of a request it did not finish reading — so anything
    /// that arrives in the same TCP segment as a previous request is dropped and
    /// never answered. This pins the behaviour the browser path depends on, so
    /// a future change to the buffering does not quietly break reuse.
    func testTwoSequentialRequestsOnOneConnection() async throws {
        let conn = try await connect()
        defer { conn.cancel() }

        try await send(conn, "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
        let first = await readResponse(conn)
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 204"), "first response missing: \(first.prefix(80))")

        try await send(conn, "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
        let second = await readResponse(conn)
        XCTAssertTrue(second.hasPrefix("HTTP/1.1 204"),
                      "the connection must survive to answer a second request; got: "
                      + String(second.prefix(80)))
    }

    // MARK: - Helpers

    private func connect() async throws -> NWConnection {
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: .global())
        let ready = expectation(description: "connected")
        // Lock-guarded rather than a captured `var`: the state handler runs on
        // the connection's queue, and mutating captured state from there is an
        // error under the Swift 6 language mode.
        let once = NSLock()
        var signalled = false
        conn.stateUpdateHandler = { s in
            guard case .ready = s else { return }
            once.lock()
            let alreadySignalled = signalled
            signalled = true
            once.unlock()
            if !alreadySignalled { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        return conn
    }

    private func send(_ conn: NWConnection, _ s: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    /// Reads one HTTP response: headers up to the blank line, then exactly
    /// Content-Length bytes, so one call yields one response rather than part of
    /// the next.
    ///
    /// Bounded on purpose. Without a cap in the parser, a server that is
    /// (incorrectly) waiting for a body it was never sent simply never answers —
    /// so the unbounded version of this test HANGS rather than fails, which is a
    /// bad regression test: it stalls the suite instead of naming the bug. The
    /// deadline turns "it waited forever" into a readable failure.
    private func readResponse(_ conn: NWConnection, timeout: TimeInterval = 5) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()

        func more() async -> Bool { Date() < deadline }

        // Headers.
        while let range = out.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: out[..<range.lowerBound], as: UTF8.self)
            let length = head
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
                ?? 0
            while out.count < range.upperBound + length, await more() {
                guard let chunk = await receive(conn, timeout: deadline) else { break }
                if chunk.isEmpty { break }
                out.append(chunk)
            }
            return head
        }
        while await more() {
            guard let chunk = await receive(conn, timeout: deadline) else { break }
            if chunk.isEmpty { break }
            out.append(chunk)
            if out.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        if out.range(of: Data("\r\n\r\n".utf8)) == nil {
            return "<no response within \(Int(timeout))s: \(String(decoding: out, as: UTF8.self).prefix(80))>"
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// One receive, abandoned at `deadline` rather than waiting on a peer that
    /// may never speak. The connection is cancelled by the caller either way.
    private func receive(_ conn: NWConnection, timeout deadline: Date) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            let once = NSLock()
            var resumed = false
            let finish: (Data?) -> Void = { value in
                once.lock()
                let alreadyResumed = resumed
                resumed = true
                once.unlock()
                guard !alreadyResumed else { return }
                c.resume(returning: value)
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, isComplete, _ in
                finish((d?.isEmpty ?? true) && isComplete ? nil : d)
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { finish(nil) }
        }
    }
}
