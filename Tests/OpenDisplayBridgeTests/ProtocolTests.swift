import XCTest
@testable import OpenDisplayBridge

final class ODControlTests: XCTestCase {

    func testEncodeParseRoundTrip() throws {
        let obj: [String: Any] = ["type": "hello", "pixelsWide": 1170, "pv": 3]
        let parsed = try XCTUnwrap(ODControl.parse(ODControl.encode(obj)))
        XCTAssertEqual(parsed["type"] as? String, "hello")
        XCTAssertEqual(parsed["pixelsWide"] as? Int, 1170)
    }

    /// Unknown message types must be ignored, never fatal (§6). parse has to
    /// be total.
    func testParseIsTotal() {
        XCTAssertNil(ODControl.parse(Data()), "empty payload")
        XCTAssertNil(ODControl.parse(Data("not json".utf8)), "garbage")
        XCTAssertNil(ODControl.parse(Data("[1,2,3]".utf8)), "JSON array is not a control message")
        XCTAssertNil(ODControl.parse(Data("42".utf8)), "JSON scalar is not a control message")
        XCTAssertNil(ODControl.parse(Data([0x00, 0x01, 0x02])), "binary video frame")
    }

    /// Forward compatibility: a field this build has never heard of must not
    /// prevent the message from being understood.
    func testUnknownFieldsAreIgnored() throws {
        let parsed = try XCTUnwrap(ODControl.parse(Data(#"{"type":"ping","t":1,"future":true}"#.utf8)))
        XCTAssertEqual(parsed["type"] as? String, "ping")
        XCTAssertEqual(parsed["future"] as? Bool, true)
    }

    /// §3: receiver->sender payloads are 1..2^20-1 bytes.
    func testOversizedPayloadIsRefused() {
        let tooBig = Data(count: ODControl.maxPayloadBytes + 1)
        XCTAssertNil(ODControl.parse(tooBig))
    }

    func testPayloadAtMaxIsAccepted() throws {
        // Exactly at the cap: valid JSON of the maximum permitted length.
        let prefix = #"{"t":1,"pad":""#
        let suffix = #""}"#
        let filler = String(repeating: " ",
                            count: ODControl.maxPayloadBytes - prefix.utf8.count - suffix.utf8.count)
        let atMax = Data("\(prefix)\(filler)\(suffix)".utf8)
        XCTAssertEqual(atMax.count, ODControl.maxPayloadBytes)
        XCTAssertNotNil(ODControl.parse(atMax))
    }

    /// §7: timestamps are ms since the Unix epoch.
    func testNowMsIsEpochMilliseconds() {
        let now = ODControl.nowMs()
        XCTAssertGreaterThan(now, 1_600_000_000_000, "should be epoch ms, not a monotonic clock")
        XCTAssertLessThan(now, 4_000_000_000_000)
    }

    /// A non-serialisable object must not tear down the stream.
    ///
    /// Note: JSONSerialization raises an ObjC *exception* (not a Swift error) for
    /// some invalid types, which `try?` cannot catch. ODControl.encode therefore
    /// validates before serialising rather than relying on `try?` alone.
    func testEncodeFailureIsEmptyNotFatal() {
        let bad: [String: Any] = ["type": "x", "bad": Data()]   // Data is not JSON
        XCTAssertEqual(ODControl.encode(bad), Data())
    }

    /// `bridge` must survive one client abandoning a live connection while a
    /// second is already adopted. The old code called `close()` on the
    /// incumbent while holding its own NSLock, and the incumbent's close
    /// observer re-acquired that same non-recursive lock — a guaranteed
    /// deadlock on the one path the protocol requires (newcomer replaces
    /// incumbent).
    func testNewcomerReplacesIncumbentWithoutDeadlocking() {
        var built: [RecordingPipeline] = []
        let bridge = Bridge {
            let p = RecordingPipeline()
            built.append(p)
            return p
        }

        let first = FakeConnection()
        let second = FakeConnection()
        bridge.adoptPairedConnection(first)
        bridge.adoptPairedConnection(second)

        XCTAssertEqual(built.count, 2, "a pipeline per adopted connection")
        XCTAssertTrue(first.isClosed, "incumbent must be closed")
        XCTAssertFalse(second.isClosed, "newcomer must stay open")
        XCTAssertEqual(built[0].detachCount, 1, "incumbent pipeline must be detached")
        XCTAssertEqual(built[1].detachCount, 0, "live pipeline must not be detached")
        XCTAssertNil(built[0].transport, "detached pipeline must drop its transport")
    }

    /// PROTOCOL.md §1: newcomer replaces incumbent. After the swap, a close
    /// notification from the OLD connection must not clear the NEW session.
    func testStaleCloseDoesNotClearLiveSession() {
        let bridge = Bridge { RecordingPipeline() }
        let first = FakeConnection()
        let second = FakeConnection()
        bridge.adoptPairedConnection(first)
        bridge.adoptPairedConnection(second)

        // The incumbent is already closed by the swap; a late/duplicate close
        // from it must not disturb the newcomer.
        first.simulateRemoteClose()
        bridge.dropSession()
        XCTAssertTrue(second.isClosed, "the live session is the one dropSession must close")
    }

    func testDropSessionClosesAndDetaches() {
        var built: [RecordingPipeline] = []
        let bridge = Bridge {
            let p = RecordingPipeline(); built.append(p); return p
        }
        let conn = FakeConnection()
        bridge.adoptPairedConnection(conn)
        XCTAssertTrue(conn.isRunning)

        bridge.dropSession()
        XCTAssertTrue(conn.isClosed)
        XCTAssertEqual(built[0].detachCount, 1)
    }

    /// Binding rule: one binary message = one OD frame. Text frames are not
    /// control or video on this binding and must not reach the pipeline.
    func testOnlyBinaryFramesReachThePipeline() {
        var built: [RecordingPipeline] = []
        let bridge = Bridge {
            let p = RecordingPipeline(); built.append(p); return p
        }
        let conn = FakeConnection()
        bridge.adoptPairedConnection(conn)

        let binary = Data(#"{"type":"hello"}"#.utf8)
        conn.emit(.binary(binary))
        conn.emit(.text(#"{"type":"hello"}"#))

        XCTAssertEqual(built[0].receivedFrames, [binary], "text frames must be dropped")
    }

    /// `lanIPv4` fed `inet_ntop` a `sockaddr*`, but that function reads a bare
    /// 4-byte `in_addr` on Darwin. It therefore returned the sa_len/sa_family
    /// header bytes — "16.2.0.0" — for EVERY interface, so the URL shown in the
    /// window was never dialable. Guard the interpretation directly.
    func testSockaddrInAddrIsReadFromTheCorrectOffset() {
        // Build a sockaddr_in the way the kernel does: len, family, port, addr.
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = 0
        // s_addr is in NETWORK byte order, so the literal is byte-swapped:
        // 0x7001A8C0 stores as c0 a8 01 70 == 192.168.1.112.
        sin.sin_addr = in_addr(s_addr: 0x7001_A8C0)

        let raw = withUnsafePointer(to: &sin) {
            UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr_in.self)
        }
        // The address lives at offset 4 (after len/family/port), not at 0.
        XCTAssertEqual(MemoryLayout<sockaddr_in>.size, 16)
        XCTAssertEqual(MemoryLayout<UInt32>.size, 4)

        var addr = raw.pointee.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        XCTAssertNotNil(inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)))
        XCTAssertEqual(String(cString: buf), "192.168.1.112")
    }
}

final class PairingTests: XCTestCase {

    func testRollProducesSixDigits() {
        let store = PairingStore()
        for _ in 0..<50 {
            let code = store.roll()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber), "got \(code)")
        }
    }

    func testVerifyAndTokenLifecycle() {
        let store = PairingStore()
        let code = store.roll()
        XCTAssertTrue(store.verify(code))
        // A wrong code must be rejected. Compare against a value that is
        // guaranteed different from the rolled one.
        let wrong = code == "000000" ? "111111" : "000000"
        XCTAssertFalse(store.verify(wrong))
        XCTAssertFalse(store.verify(""))
        XCTAssertFalse(store.verify("abcdef"))

        let token = store.issueToken()
        XCTAssertTrue(store.isValid(token))
        XCTAssertFalse(store.isValid("bogus"))
    }

    /// Rolling invalidates outstanding tokens: a session authorised under the
    /// old code must not survive a regenerate.
    func testRollInvalidatesTokens() {
        let store = PairingStore()
        _ = store.roll()
        let token = store.issueToken()
        XCTAssertTrue(store.isValid(token))
        _ = store.roll()
        XCTAssertFalse(store.isValid(token), "tokens must not survive a code change")
    }

    func testSetCodePinsAndClearsTokens() {
        let store = PairingStore()
        _ = store.roll()
        let token = store.issueToken()
        XCTAssertEqual(store.setCode("424242"), "424242")
        XCTAssertTrue(store.verify("424242"))
        XCTAssertFalse(store.verify("999999"))
        XCTAssertFalse(store.isValid(token))
    }

    func testTokenParsingFromCookieHeader() {
        XCTAssertEqual(PairingStore.token(from: "odpair=abc123"), "abc123")
        XCTAssertEqual(PairingStore.token(from: "a=1; odpair=abc123; b=2"), "abc123")
        XCTAssertEqual(PairingStore.token(from: "odpair=abc123; Path=/"), "abc123")
        XCTAssertNil(PairingStore.token(from: "a=1; b=2"))
        XCTAssertNil(PairingStore.token(from: nil))
        // A cookie merely NAMED od-something must not match.
        XCTAssertNil(PairingStore.token(from: "odpairx=abc"))
    }

    // MARK: - Brute-force protection
    //
    // The pairing gate is the only thing between a LAN-reachable port and a
    // mirrored screen. A 6-digit code is a million candidates, so without a
    // limit on attempts it is an exhaustive search that costs the attacker
    // seconds and the server nothing.

    /// An unrolled store must reject everything, including the empty string.
    /// `code` is "" between construction and the first `roll()`, and
    /// `attempt == code` would otherwise be true for a client posting nothing.
    func testUnrolledStoreRejectsEverything() {
        let fresh = PairingStore()
        XCTAssertFalse(fresh.verify(""), "an unrolled store must not accept an empty attempt")
        XCTAssertFalse(fresh.verify("000000"))
    }

    /// Repeated failures must close the door rather than merely count.
    func testRepeatedFailuresLockTheDoor() {
        let store = PairingStore()
        store.setCode("424242")
        for _ in 0..<PairingStore.maxFailedAttempts {
            XCTAssertFalse(store.verify("000000"), "a wrong code must be refused")
        }
        XCTAssertTrue(store.isLockedOut,
                      "after \(PairingStore.maxFailedAttempts) failures the door must close")
    }

    /// The point of the lockout: *wrong* guesses stop working, so the search
    /// rate is bounded however many attempts are made.
    ///
    /// The real code is deliberately still accepted — see the next test. What
    /// must be impossible is brute force, and that is measured here: 500 further
    /// wrong guesses are all refused.
    func testWrongGuessingIsRefusedWhileLockedOut() {
        let store = PairingStore()
        store.setCode("424242")
        for _ in 0..<PairingStore.maxFailedAttempts { _ = store.verify("000000") }
        XCTAssertTrue(store.isLockedOut)

        var accepted = 0
        for _ in 0..<500 {
            if store.verify("000000") { accepted += 1 }
        }
        XCTAssertEqual(accepted, 0, "a locked-out store must accept no wrong codes")
    }

    /// Locking the owner out of their own display would be worse than the bug
    /// being fixed: the code is on screen in front of them, so a correct entry
    /// must always work — lockout or not. This is why `verify` checks the code
    /// before it checks the lockout.
    func testCorrectCodeStillWorksWhileLockedOut() {
        let store = PairingStore()
        store.setCode("424242")
        for _ in 0..<PairingStore.maxFailedAttempts { _ = store.verify("000000") }
        XCTAssertTrue(store.isLockedOut)
        XCTAssertTrue(store.verify("424242"),
                      "a correct code must be accepted even during a lockout")
    }

    /// A success clears the count, so someone who fumbles twice and then types it
    /// right is not one typo away from being locked out.
    func testSuccessClearsTheFailureCount() {
        let store = PairingStore()
        store.setCode("424242")
        for _ in 0..<(PairingStore.maxFailedAttempts - 1) { _ = store.verify("000000") }
        XCTAssertTrue(store.verify("424242"))
        XCTAssertFalse(store.isLockedOut, "a success must clear the lockout")

        // The full allowance must therefore still be available after a success.
        for _ in 0..<PairingStore.maxFailedAttempts { _ = store.verify("000000") }
        XCTAssertTrue(store.isLockedOut, "the allowance is per-run, not cumulative")
    }

    /// The lockout must expire, or a few typos would brick pairing until restart.
    /// Time is not injectable here, so assert the window is real, finite and
    /// bounded rather than permanent.
    func testLockoutExpires() {
        let store = PairingStore()
        store.setCode("424242")
        for _ in 0..<PairingStore.maxFailedAttempts { _ = store.verify("000000") }
        XCTAssertGreaterThan(store.lockoutRemaining, 0, "must report time remaining")
        XCTAssertLessThanOrEqual(store.lockoutRemaining, PairingStore.lockoutDuration)
    }
}

/// The hub outlives every browser session, so anything a session registers with
/// it has to be unregistered on the way out.
final class HubObserverLifetimeTests: XCTestCase {

    /// An attach/detach cycle must leave the observer list as it found it.
    ///
    /// `RelayedSender.attach` registers a sender-state observer so the receiver
    /// learns when a sender appears or goes away, and `detach` used to leave that
    /// registration in place. The hub lives for the whole process and a session is
    /// created per receiver connection, so the array grew by one closure on every
    /// connect — and each sender connect/disconnect then walked all of them, each
    /// pushing a status frame to a receiver that no longer existed.
    func testAttachDetachDoesNotAccumulateObservers() {
        let hub = OpenDisplayHub(port: 0)
        let before = hub.senderStateObserverCount

        for _ in 0..<5 {
            let relay = RelayedSender(hub: hub, logger: { _ in })
            relay.attach(FakeTransport())
            relay.detach()
        }

        XCTAssertEqual(hub.senderStateObserverCount, before,
                       "five attach/detach cycles must not leave five registrations on "
                       + "a hub that outlives every session")
    }

    /// While attached the observer is live — the behaviour the leak was hiding
    /// behind, asserted directly rather than only counted.
    func testObserverIsLiveWhileAttached() {
        let hub = OpenDisplayHub(port: 0)
        let before = hub.senderStateObserverCount

        let relay = RelayedSender(hub: hub, logger: { _ in })
        relay.attach(FakeTransport())
        XCTAssertEqual(hub.senderStateObserverCount, before + 1,
                       "attaching must register exactly one observer")

        relay.detach()
        XCTAssertEqual(hub.senderStateObserverCount, before)
    }

    /// Two live sessions each register, so both would be told about a sender.
    /// Newcomer-replaces-incumbent is enforced by `Bridge`, not here; this is
    /// about the list not collapsing entries.
    func testDistinctSessionsGetDistinctRegistrations() {
        let hub = OpenDisplayHub(port: 0)
        let before = hub.senderStateObserverCount

        let a = RelayedSender(hub: hub, logger: { _ in })
        let b = RelayedSender(hub: hub, logger: { _ in })
        a.attach(FakeTransport())
        b.attach(FakeTransport())
        XCTAssertEqual(hub.senderStateObserverCount, before + 2)

        a.detach()
        b.detach()
        XCTAssertEqual(hub.senderStateObserverCount, before)
    }
}

/// Minimal transport so a relay can be attached without a socket.
private final class FakeTransport: ODTransport {
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    func sendFrame(_ payload: Data) {}
    func close() {}
}

final class AnnexBTests: XCTestCase {

    /// One access unit per frame, 4-byte start codes, parameter sets on IDR.
    func testAvccToAnnexB() {
        // AVCC: [len=2]['A','B'][len=1]['C']
        let avcc = Data([0, 0, 0, 2, 0x41, 0x42, 0, 0, 0, 1, 0x43])
        let out = AnnexB.avccToAnnexB(avcc)
        XCTAssertEqual(out, Data([0, 0, 0, 1, 0x41, 0x42, 0, 0, 0, 1, 0x43]))
    }

    func testAvccToAnnexBTruncatesCleanlyOnGarbage() {
        // Declares 99 bytes but only supplies 2: must not crash or over-read.
        let avcc = Data([0, 0, 0, 99, 0x41, 0x42])
        let out = AnnexB.avccToAnnexB(avcc)
        XCTAssertTrue(out.isEmpty, "a truncated length prefix yields nothing")
    }

    func testNaluSplitting() {
        let a = AnnexB.startCode + Data([0x67, 0x11])          // SPS
        let b = AnnexB.startCode + Data([0x68, 0x22])          // PPS
        let c = AnnexB.startCode + Data([0x65, 0x33, 0x44])    // IDR slice
        let nalus = AnnexB.nalus(a + b + c)
        XCTAssertEqual(nalus.count, 3)
        XCTAssertEqual(AnnexB.nalType(nalus[0]), 7)
        XCTAssertEqual(AnnexB.nalType(nalus[1]), 8)
        XCTAssertEqual(AnnexB.nalType(nalus[2]), 5)
    }

    func testNalTypeOnEmpty() {
        XCTAssertEqual(AnnexB.nalType(Data()), 0)
    }
}
