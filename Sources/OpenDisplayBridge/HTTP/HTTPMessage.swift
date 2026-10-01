import Foundation

struct HTTPRequest {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]   // lowercased keys
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseError: Error { case malformed, headerTooLarge, bodyTooLarge }

/// Minimal HTTP/1.1 request reader: one request per call, keeps no state.
enum HTTPParser {
    static let maxHeaderBytes = 16 * 1024

    /// Cap on a request body.
    ///
    /// The only POST this server serves is `/pair`, whose body is a JSON object
    /// holding a 6-digit code — a few dozen bytes. Nothing legitimate approaches
    /// 1 MiB, but the header limit alone did not cover this: `Content-Length`
    /// was read and then obeyed without a ceiling, so a client declaring a
    /// gigabyte made the server append to `rest` until the socket died. That is
    /// a memory-exhaustion vector on a port reachable from the LAN, and an
    /// unauthenticated one, since the length is declared before anything is
    /// authenticated.
    ///
    /// This is the same reasoning that caps a WebSocket frame at 4 MiB and an
    /// OpenDisplay frame at 16 MiB in this codebase; the HTTP body was the one
    /// path that had been left unbounded.
    static let maxBodyBytes = 1024 * 1024

    /// Reads one request from the connection. Returns nil on clean EOF before any bytes.
    ///
    /// Bytes left over after the request are DISCARDED. That is correct only
    /// because callers treat any pipelined second request as a new conversation
    /// and the browser does not pipeline — see `HTTPServer.serveHTTP`, which
    /// keeps no buffer between calls. A caller that wanted pipelining would have
    /// to thread the remainder out of here.
    static func readOne(from conn: NWConnectionShim) async throws -> HTTPRequest? {
        var buffer = Data()
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: 0..<range.lowerBound)
                var rest = buffer.subdata(in: range.upperBound..<buffer.count)
                let text = String(decoding: head, as: UTF8.self)
                var lines = text.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else { throw HTTPParseError.malformed }
                lines.removeFirst()
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { throw HTTPParseError.malformed }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                var body = Data()
                if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
                    // Reject on the declared length, before buffering a single
                    // byte of it. Checking after the read would already have
                    // spent the memory this is here to avoid.
                    guard len <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
                    while rest.count < len {
                        let chunk = try await conn.receiveAtLeast(1)
                        if chunk.isEmpty { throw HTTPParseError.malformed }  // EOF mid-body
                        rest.append(chunk)
                    }
                    body = rest.subdata(in: 0..<len)
                }
                return HTTPRequest(method: String(parts[0]).uppercased(),
                                   target: String(parts[1]),
                                   version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
                                   headers: headers,
                                   body: body)
            }
            if buffer.count > maxHeaderBytes { throw HTTPParseError.headerTooLarge }
            let chunk = try await conn.receiveAtLeast(1)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }   // clean EOF
                throw HTTPParseError.malformed     // EOF mid-headers
            }
            buffer.append(chunk)
        }
    }
}

struct HTTPResponseWriter {
    let conn: NWConnectionShim

    func status(_ code: Int, _ reason: String, headers: [String: String] = [:], body: Data = Data()) async throws {
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "keep-alive"
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        try await conn.send(payload)
    }

    func json(_ obj: [String: Any], code: Int = 200, extraHeaders: [String: String] = [:]) async throws {
        let body = try JSONSerialization.data(withJSONObject: obj)
        var h = ["Content-Type": "application/json; charset=utf-8"]
        h.merge(extraHeaders) { _, new in new }
        try await status(code, code == 200 ? "OK" : "Error", headers: h, body: body)
    }

    func notFound() async throws { try await status(404, "Not Found", body: Data("not found".utf8)) }
}
