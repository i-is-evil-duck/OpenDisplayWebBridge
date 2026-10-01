import Foundation
import Network

@MainActor
final class AppState: ObservableObject {
    @Published var pairingCode = "------"
    @Published var log: [String] = []
    @Published var clients = 0
    @Published var serverURL = "starting…"
    /// Every reachable LAN address, not just the best guess — a device on a
    /// different interface has no other way in.
    @Published var addresses: [String] = []
    /// An official OpenDisplay sender has dialled in on :9000.
    @Published var senderConnected = false
    /// A browser receiver is attached over the WebSocket.
    @Published var receiverAttached = false

    private let pairing = PairingStore()
    private var server: HTTPServer?
    private var bridge: Bridge?
    private let hub = OpenDisplayHub()
    private var rtc: WebRTCOutput?

    /// Feeds the WebRTC spike. Paces itself off wall-clock and only pushes once
    /// a peer connection exists, so an idle probe costs nothing.
    private static func startRTCProbePump(rtc: WebRTCOutput, log: @escaping (String) -> Void) {
        let source = SyntheticFrameSource()
        var pushed = 0
        Task.detached {
            while !Task.isCancelled {
                if rtc.isConnected, let (buffer, ts) = source.nextFrame() {
                    rtc.submit(buffer, captureTimeNs: ts)
                    pushed += 1
                    if pushed == 1 { log("rtc: pushing synthetic frames") }
                }
                try? await Task.sleep(nanoseconds: 8_000_000)   // ~125 Hz tick
            }
        }
    }

    /// OD_SOURCE: `auto` (default) relays a real sender when one has dialled
    /// in and falls back to the generated pattern otherwise; `relay` always
    /// waits for a sender; `demo` always generates a pattern.
    private static let sourceMode = ProcessInfo.processInfo.environment["OD_SOURCE"] ?? "auto"

    init() { start() }

    func start() {
        // OD_CODE pins the pairing code so tools/smoke-test.sh can run
        // unattended. Unset in normal use, which rolls a fresh random code.
        let pinned = ProcessInfo.processInfo.environment["OD_CODE"]
        if let pinned, pinned.count == 6, pinned.allSatisfy(\.isNumber) {
            pairingCode = pairing.setCode(pinned)
            log("pairing code: \(pairingCode) (pinned via OD_CODE)")
        } else {
            pairingCode = pairing.roll()
            log("pairing code: \(pairingCode)")
        }
        let port = UInt16(ProcessInfo.processInfo.environment["OD_PORT"] ?? "") ?? 8080
        let hosts = lanIPv4s()
        addresses = hosts
        let host = hosts.first ?? "127.0.0.1"
        serverURL = "http://\(host):\(port)"
        bridge = Bridge { [weak self] in
            // Integration point. `RelayedSender` forwards a real OpenDisplay
            // sender's frames to the browser; `DemoSender` generates a pattern
            // so the scaffold works with no sender present.
            let mode = AppState.sourceMode
            let useRelay: Bool
            switch mode {
            case "relay": useRelay = true
            case "demo":  useRelay = false
            default:      useRelay = self?.hub.isSenderConnected ?? false
            }
            if useRelay {
                return RelayedSender(hub: self?.hub ?? OpenDisplayHub(),
                                     logger: { self?.note($0) })
            }
            // The demo pipeline streams a generated test pattern so the
            // scaffold works end-to-end without ScreenCaptureKit /
            // CGVirtualDisplay (and without a host H.264 encoder).
            return DemoSender(logger: { self?.note($0) })
        }
        hub.onStatus = { [weak self] message in self?.note(message) }
        hub.onSenderStateChange = { [weak self] connected in self?.setSender(connected) }
        if AppState.logToStdout {
            // Report the host's real encoder capability from inside the app.
            // A bare `swiftc` probe claimed this M-series Mac had zero H.264
            // encoders, which is not credible; enumerate from the real process.
            let report = EncoderReport.summary() + "\n" + EncoderReport.probeEncode()
            log(report)
            // Also write it to a file: when the app is launched via
            // LaunchServices (`open`) there is no stdout to read.
            if let path = ProcessInfo.processInfo.environment["OD_ENCODER_REPORT"] {
                try? Data(report.utf8).write(to: URL(fileURLWithPath: path))
            }
        }
        do {
            try hub.start()
        } catch {
            log("WARNING: not listening for OpenDisplay senders: \(error)")
        }
        do {
            // Listener construction and bind are the same class of failure
            // (bad port / port in use), so they share one handler.
            let server = try HTTPServer(
                port: port,
                pairing: pairing,
                onWSConnection: { [weak self] conn in
                    self?.bridge?.adoptPairedConnection(conn)
                    self?.setReceiver(true)
                    self?.note("receiver connected: \(conn.remoteEndpointString)")
                },
                onConnectionClosed: { [weak self] in
                    self?.note("connection closed")
                }
            )
            server.onReceiverClosed = { [weak self] in self?.setReceiver(false) }
            server.onClientCount = { [weak self] n in self?.setClients(n) }
            server.advertisedID = self.hub.advertisedID
            if server.rtcProbeEnabled {
                // WebRTC spike (WEBRTC_PLAN.md W0.3). A generated frame source
                // proves pixels reach a browser without depending on a working
                // H.264 *encoder*, which this unsigned process cannot reach;
                // libvpx does the VP8 encode inside WebRTC.
                let rtc = WebRTCOutput()
                rtc.onStatus = { [weak self] m in self?.note("rtc: \(m)") }
                rtc.start()
                server.rtcProbe = rtc
                self.rtc = rtc
                log("rtc probe enabled: open http://\(host):\(port)/rtcprobe")
                Self.startRTCProbePump(rtc: rtc, log: { [weak self] m in self?.note(m) })
            }
            try server.start()
            self.server = server
            log("listening on \(serverURL)")
        } catch {
            log("ERROR: could not bind port \(port): \(error)")
            serverURL = "port \(port) in use?"
        }
    }

    func regenerateCode() {
        pairingCode = pairing.roll()
        bridge?.dropSession()  // old sessions used the old code; force re-pair
        log("new pairing code: \(pairingCode)")
    }

    /// Main-actor hop for callbacks that arrive on background queues — the HTTP
    /// task, the WebSocket read loop, the encoder callback. Every one of those
    /// touches `@Published` state, which SwiftUI only reads safely on the main
    /// actor. Call these instead of `log`/`clients =` from any non-isolated site.
    nonisolated func note(_ s: String) {
        Task { @MainActor [weak self] in self?.log(s) }
    }

    nonisolated func setClients(_ n: Int) {
        Task { @MainActor [weak self] in self?.clients = n }
    }

    nonisolated func setSender(_ connected: Bool) {
        Task { @MainActor [weak self] in self?.senderConnected = connected }
    }

    nonisolated func setReceiver(_ attached: Bool) {
        Task { @MainActor [weak self] in self?.receiverAttached = attached }
    }

    /// All URLs a receiver could use, best first.
    var receiverURLs: [String] {
        let port = serverURL.split(separator: ":").last.map(String.init) ?? "8080"
        let hosts = addresses.isEmpty ? ["127.0.0.1"] : addresses
        return hosts.map { "http://\($0):\(port)" }
    }

    func log(_ s: String) {
        let t = DateFormatter.logStamp.string(from: Date())
        let line = "[\(t)] \(s)"
        // OD_LOG_STDOUT mirrors the log to the terminal. Without it the only
        // copy lives in the app window, which makes headless/CI diagnosis of a
        // silent sender (e.g. a host with no H.264 encoder backend) painful.
        if AppState.logToStdout { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private static let logToStdout = ProcessInfo.processInfo.environment["OD_LOG_STDOUT"] != nil
}

extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Every usable LAN IPv4 address, best first.
///
/// Showing all of them matters: the window used to display exactly one, so a
/// device on a different interface (or after the Mac picked up a second
/// address) had no way to reach the page except by guessing.
///
/// Excludes loopback, link-local (169.254/16) and unspecified addresses, and
/// anything that is not administratively up.
func lanIPv4s() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }

    var result: [(name: String, ip: String)] = []
    var p = list
    while let addr = p {
        let iface = addr.pointee
        defer { p = iface.ifa_next }
        let name = String(cString: iface.ifa_name)

        // ifa_addr is NULL on addressless interfaces, so it must be unwrapped
        // before sa_family is read — dereferencing first crashes.
        guard let sa = iface.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let flags = Int(iface.ifa_flags)
        guard flags & Int(IFF_UP) != 0, flags & Int(IFF_LOOPBACK) == 0 else { continue }

        let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self)
        var sinAddr = sin.pointee.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        // inet_ntop must be handed a bare in_addr, NOT the sockaddr*: its
        // AF_INET path reads 4 bytes at the pointer, so passing the sockaddr
        // yields the sa_len/sa_family header ("16.2.0.0" on every interface).
        guard inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: buf)
        guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254."), ip != "0.0.0.0" else { continue }
        result.append((name, ip))
    }
    // en0 is the usual Wi-Fi/Ethernet LAN on a Mac; put it first, then the rest
    // in interface order.
    return (result.filter { $0.name == "en0" } + result.filter { $0.name != "en0" }).map(\.ip)
}

func lanIPv4() -> String? { lanIPv4s().first }

extension NWConnection {
    var remoteEndpointString: String {
        switch self.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        default: return "\(self.endpoint)"
        }
    }
}
